// Phỏng theo Ferrogram — github.com/Dasemu/Ferrogram, src/net/calls/signaling.rs
// Copyright (c) 2026 Darío Sevilla Muñoz. Giấy phép MIT (crates/gm-call/LICENSE-FERROGRAM).
// GramMini sửa: đường dẫn module (CallKey ở tg/mod.rs), âm thanh qua gm-opus.

//! tgcalls signaling, protocol "V2" (library versions 8.0.0 / 9.0.0).
//!
//! Messages are JSON objects tagged with `@type`. They travel through
//! `phone.sendSignalingData` inside an encrypted packet (see [`super::crypto`])
//! whose plaintext is a small reliable framing:
//!
//! ```text
//! packet  = seq:u32 first entry*
//! first   = 0x7f len:u32 bytes        (a message)
//!         | 0xfe                      (empty: only acks/resends follow)
//! entry   = seq:u32 ( 0xff            (ack of seq)
//!                   | 0x7f len:u32 bytes )
//! seq     = counter | 1<<31 (single-message packet) | 1<<30 (needs ack)
//! ```
//!
//! Every message we send needs an ack; unacked messages are resent (inside
//! later packets) until acked. Everything parsed here comes from the network:
//! all lengths are bounded and nothing panics.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use super::crypto::{self, Direction};
use super::CallKey;

const SINGLE_BIT: u32 = 1 << 31;
const ACK_BIT: u32 = 1 << 30;
const MAX_COUNTER: u32 = !(SINGLE_BIT | ACK_BIT);
const ID_ACK: u8 = 0xff;
const ID_EMPTY: u8 = 0xfe;
const ID_CUSTOM: u8 = 0x7f;
/// Largest encrypted signaling packet (msg_key included).
const MAX_SIGNALING_PACKET: usize = 16 * 1024;
/// Largest single message we accept.
const MAX_MESSAGE: usize = 1024 * 1024;
const MAX_UNACKED: usize = 256;
const KEEP_COUNTERS: u32 = 64;
const MIN_RESEND: Duration = Duration::from_millis(3000);
/// Most messages a single packet may carry (hostile-input bound).
const MAX_ENTRIES: usize = 512;

fn counter(seq: u32) -> u32 {
    seq & MAX_COUNTER
}

// ---------------------------------------------------------------------------
// Messages

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DtlsFingerprint {
    pub hash: String,
    pub setup: String,
    pub fingerprint: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PayloadType {
    pub id: u32,
    pub name: String,
    pub clockrate: u32,
    pub channels: u32,
    pub feedback: Vec<(String, String)>,
    pub parameters: Vec<(String, String)>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RtpExtension {
    pub id: u32,
    pub uri: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaKind {
    Audio,
    Video,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MediaContent {
    pub kind: MediaKind,
    pub ssrc: u32,
    pub ssrc_groups: Vec<(String, Vec<u32>)>,
    pub payload_types: Vec<PayloadType>,
    pub rtp_extensions: Vec<RtpExtension>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Message {
    InitialSetup {
        ufrag: String,
        pwd: String,
        renomination: bool,
        fingerprints: Vec<DtlsFingerprint>,
    },
    NegotiateChannels {
        exchange_id: u32,
        contents: Vec<MediaContent>,
    },
    /// SDP `candidate:` lines.
    Candidates(Vec<String>),
    MediaState {
        muted: bool,
        low_battery: bool,
    },
}

fn num(v: &Value) -> Option<u64> {
    match v {
        Value::Number(n) => n.as_u64(),
        Value::String(s) => s.parse().ok(),
        _ => None,
    }
}

fn num32(v: Option<&Value>) -> Option<u32> {
    v.and_then(num).and_then(|n| u32::try_from(n).ok())
}

fn string(v: Option<&Value>) -> Option<String> {
    v.and_then(Value::as_str).map(str::to_owned)
}

fn array(v: Option<&Value>) -> &[Value] {
    v.and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[])
}

/// Hostile-input bounds for list lengths inside a message.
const MAX_LIST: usize = 64;

fn payload_from(o: &Map<String, Value>) -> Option<PayloadType> {
    let feedback = array(o.get("feedbackTypes"))
        .iter()
        .take(MAX_LIST)
        .filter_map(|f| {
            Some((
                string(f.get("type"))?,
                string(f.get("subtype")).unwrap_or_default(),
            ))
        })
        .collect();
    let parameters = o
        .get("parameters")
        .and_then(Value::as_object)
        .map(|m| {
            m.iter()
                .take(MAX_LIST)
                .filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_owned())))
                .collect()
        })
        .unwrap_or_default();
    Some(PayloadType {
        id: num32(o.get("id"))?,
        name: string(o.get("name"))?,
        clockrate: num32(o.get("clockrate")).unwrap_or(0),
        channels: num32(o.get("channels")).unwrap_or(0),
        feedback,
        parameters,
    })
}

fn content_from(o: &Map<String, Value>) -> Option<MediaContent> {
    let kind = match o.get("type")?.as_str()? {
        "audio" => MediaKind::Audio,
        "video" => MediaKind::Video,
        _ => return None,
    };
    let ssrc_groups = array(o.get("ssrcGroups"))
        .iter()
        .take(MAX_LIST)
        .filter_map(|g| {
            let ssrcs = array(g.get("ssrcs"))
                .iter()
                .take(MAX_LIST)
                .filter_map(|s| num(s).and_then(|n| u32::try_from(n).ok()))
                .collect();
            Some((string(g.get("semantics"))?, ssrcs))
        })
        .collect();
    let payload_types = array(o.get("payloadTypes"))
        .iter()
        .take(MAX_LIST)
        .filter_map(|p| payload_from(p.as_object()?))
        .collect();
    let rtp_extensions = array(o.get("rtpExtensions"))
        .iter()
        .take(MAX_LIST)
        .filter_map(|e| {
            Some(RtpExtension {
                id: num32(e.get("id"))?,
                uri: string(e.get("uri"))?,
            })
        })
        .collect();
    Some(MediaContent {
        kind,
        ssrc: num32(o.get("ssrc"))?,
        ssrc_groups,
        payload_types,
        rtp_extensions,
    })
}

fn content_to(c: &MediaContent) -> Value {
    let mut o = Map::new();
    o.insert(
        "type".into(),
        match c.kind {
            MediaKind::Audio => "audio",
            MediaKind::Video => "video",
        }
        .into(),
    );
    o.insert("ssrc".into(), c.ssrc.to_string().into());
    if !c.ssrc_groups.is_empty() {
        let groups: Vec<Value> = c
            .ssrc_groups
            .iter()
            .map(|(sem, ssrcs)| {
                serde_json::json!({
                    "semantics": sem,
                    "ssrcs": ssrcs.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
                })
            })
            .collect();
        o.insert("ssrcGroups".into(), groups.into());
    }
    if !c.payload_types.is_empty() {
        let pts: Vec<Value> = c
            .payload_types
            .iter()
            .map(|p| {
                let fb: Vec<Value> = p
                    .feedback
                    .iter()
                    .map(|(t, s)| serde_json::json!({"type": t, "subtype": s}))
                    .collect();
                let params: Map<String, Value> = p
                    .parameters
                    .iter()
                    .map(|(k, v)| (k.clone(), Value::String(v.clone())))
                    .collect();
                serde_json::json!({
                    "id": p.id,
                    "name": p.name,
                    "clockrate": p.clockrate,
                    "channels": p.channels,
                    "feedbackTypes": fb,
                    "parameters": params,
                })
            })
            .collect();
        o.insert("payloadTypes".into(), pts.into());
    }
    let exts: Vec<Value> = c
        .rtp_extensions
        .iter()
        .map(|e| serde_json::json!({"id": e.id, "uri": e.uri}))
        .collect();
    o.insert("rtpExtensions".into(), exts.into());
    Value::Object(o)
}

impl Message {
    pub fn to_json(&self) -> Vec<u8> {
        let v = match self {
            Self::InitialSetup {
                ufrag,
                pwd,
                renomination,
                fingerprints,
            } => serde_json::json!({
                "@type": "InitialSetup",
                "ufrag": ufrag,
                "pwd": pwd,
                "renomination": renomination,
                "fingerprints": fingerprints,
            }),
            Self::NegotiateChannels {
                exchange_id,
                contents,
            } => serde_json::json!({
                "@type": "NegotiateChannels",
                "exchangeId": exchange_id.to_string(),
                "contents": contents.iter().map(content_to).collect::<Vec<_>>(),
            }),
            Self::Candidates(list) => serde_json::json!({
                "@type": "Candidates",
                "candidates": list.iter().map(|s| serde_json::json!({"sdpString": s})).collect::<Vec<_>>(),
            }),
            Self::MediaState { muted, low_battery } => serde_json::json!({
                "@type": "MediaState",
                "muted": muted,
                "lowBattery": low_battery,
                "videoState": "inactive",
                "videoRotation": 0,
                "screencastState": "inactive",
            }),
        };
        serde_json::to_vec(&v).unwrap_or_default()
    }

    /// Parse one message; `None` for unknown types or malformed JSON.
    pub fn parse(data: &[u8]) -> Option<Self> {
        if data.len() > MAX_MESSAGE {
            return None;
        }
        let v: Value = serde_json::from_slice(data).ok()?;
        let o = v.as_object()?;
        match o.get("@type")?.as_str()? {
            "InitialSetup" => Some(Self::InitialSetup {
                ufrag: string(o.get("ufrag"))?,
                pwd: string(o.get("pwd"))?,
                renomination: o
                    .get("renomination")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                fingerprints: array(o.get("fingerprints"))
                    .iter()
                    .take(MAX_LIST)
                    .map(|f| serde_json::from_value(f.clone()).ok())
                    .collect::<Option<Vec<_>>>()?,
            }),
            "NegotiateChannels" => Some(Self::NegotiateChannels {
                exchange_id: num32(o.get("exchangeId"))?,
                contents: array(o.get("contents"))
                    .iter()
                    .take(MAX_LIST)
                    .filter_map(|c| content_from(c.as_object()?))
                    .collect(),
            }),
            "Candidates" => Some(Self::Candidates(
                array(o.get("candidates"))
                    .iter()
                    .take(MAX_LIST)
                    .map(|c| string(c.get("sdpString")))
                    .collect::<Option<Vec<_>>>()?,
            )),
            "MediaState" => Some(Self::MediaState {
                muted: o.get("muted").and_then(Value::as_bool).unwrap_or(false),
                low_battery: o
                    .get("lowBattery")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
            }),
            _ => None,
        }
    }
}

// ---------------------------------------------------------------------------
// Reliable encrypted framing

struct Unacked {
    seq: u32,
    /// `seq || 0x7f || len || bytes`.
    serialized: Vec<u8>,
    last_sent: Option<Instant>,
}

/// One side of the encrypted signaling channel (sans-IO).
pub struct Channel {
    key: CallKey,
    dir: Direction,
    counter: u32,
    unacked: VecDeque<Unacked>,
    acks_to_send: Vec<u32>,
    /// Packet counters seen recently (replay window).
    incoming: Vec<u32>,
    /// Counters of ack-requiring messages already delivered.
    delivered: Vec<u32>,
}

impl std::fmt::Debug for Channel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Channel")
            .field("outgoing", &self.dir.outgoing)
            .field("unacked", &self.unacked.len())
            .finish_non_exhaustive()
    }
}

fn put_u32(v: &mut Vec<u8>, x: u32) {
    v.extend_from_slice(&x.to_be_bytes());
}

struct Reader<'a> {
    b: &'a [u8],
}

impl<'a> Reader<'a> {
    fn u8(&mut self) -> Option<u8> {
        let (&x, rest) = self.b.split_first()?;
        self.b = rest;
        Some(x)
    }
    fn u32(&mut self) -> Option<u32> {
        if self.b.len() < 4 {
            return None;
        }
        let (h, rest) = self.b.split_at(4);
        self.b = rest;
        Some(u32::from_be_bytes([h[0], h[1], h[2], h[3]]))
    }
    fn bytes(&mut self, n: usize) -> Option<&'a [u8]> {
        if self.b.len() < n {
            return None;
        }
        let (h, rest) = self.b.split_at(n);
        self.b = rest;
        Some(h)
    }
}

impl Channel {
    pub fn new(key: CallKey, outgoing: bool) -> Self {
        Self {
            key,
            dir: Direction { outgoing },
            counter: 0,
            unacked: VecDeque::new(),
            acks_to_send: Vec::new(),
            incoming: Vec::new(),
            delivered: Vec::new(),
        }
    }

    fn next_seq(&mut self, needs_ack: bool, single: bool) -> Option<u32> {
        if self.counter >= MAX_COUNTER {
            return None;
        }
        self.counter += 1;
        Some(
            self.counter
                | if single { SINGLE_BIT } else { 0 }
                | if needs_ack { ACK_BIT } else { 0 },
        )
    }

    fn fits(buf: &[u8], extra: usize) -> bool {
        16 + buf.len() + extra <= MAX_SIGNALING_PACKET
    }

    fn append_extras(&mut self, buf: &mut Vec<u8>, now: Instant) {
        let mut sent = 0;
        for &seq in &self.acks_to_send {
            if !Self::fits(buf, 5) {
                break;
            }
            put_u32(buf, seq);
            buf.push(ID_ACK);
            sent += 1;
        }
        self.acks_to_send.drain(..sent);
        for m in &mut self.unacked {
            let due = m.last_sent.is_none_or(|t| now >= t + MIN_RESEND);
            if !due || !Self::fits(buf, m.serialized.len()) {
                break;
            }
            buf.extend_from_slice(&m.serialized);
            m.last_sent = Some(now);
        }
    }

    /// Queue a message and return the packet to send now.
    pub fn send(&mut self, msg: &Message, now: Instant) -> Option<Vec<u8>> {
        let body = msg.to_json();
        if self.unacked.len() >= MAX_UNACKED || body.len() + 64 > MAX_SIGNALING_PACKET {
            return None;
        }
        let seq = self.next_seq(true, false)?;
        let mut ser = Vec::with_capacity(body.len() + 9);
        put_u32(&mut ser, seq);
        ser.push(ID_CUSTOM);
        put_u32(&mut ser, u32::try_from(body.len()).ok()?);
        ser.extend_from_slice(&body);
        if self.unacked.is_empty() {
            let mut packet = ser.clone();
            self.unacked.push_back(Unacked {
                seq,
                serialized: ser,
                last_sent: Some(now),
            });
            // Acks only: the message itself is already in the packet.
            let mut tail = Vec::new();
            let acks = std::mem::take(&mut self.acks_to_send);
            for a in &acks {
                if Self::fits(&packet, tail.len() + 5) {
                    put_u32(&mut tail, *a);
                    tail.push(ID_ACK);
                }
            }
            packet.extend_from_slice(&tail);
            Some(crypto::encrypt(&self.key, self.dir, &packet))
        } else {
            self.unacked.push_back(Unacked {
                seq,
                serialized: ser,
                last_sent: None,
            });
            for m in &mut self.unacked {
                m.last_sent = None;
            }
            self.service(now)
        }
    }

    /// An "empty" packet carrying pending acks and due resends, if any.
    pub fn service(&mut self, now: Instant) -> Option<Vec<u8>> {
        let due = self
            .unacked
            .iter()
            .any(|m| m.last_sent.is_none_or(|t| now >= t + MIN_RESEND));
        if self.acks_to_send.is_empty() && !due {
            return None;
        }
        let seq = self.next_seq(false, false)?;
        let mut buf = Vec::new();
        put_u32(&mut buf, seq);
        buf.push(ID_EMPTY);
        self.append_extras(&mut buf, now);
        Some(crypto::encrypt(&self.key, self.dir, &buf))
    }

    /// Number of our messages still waiting for an ack.
    pub fn pending(&self) -> usize {
        self.unacked.len()
    }

    fn register_incoming(&mut self, c: u32) -> bool {
        let largest = self.incoming.last().copied().unwrap_or(0);
        if self.incoming.binary_search(&c).is_ok() || c.saturating_add(KEEP_COUNTERS) <= largest {
            return false;
        }
        self.incoming.retain(|&x| x + KEEP_COUNTERS > c);
        let pos = self.incoming.partition_point(|&x| x < c);
        self.incoming.insert(pos, c);
        true
    }

    fn register_delivered(&mut self, c: u32) -> bool {
        if self.delivered.binary_search(&c).is_ok() {
            return false;
        }
        if self.delivered.len() >= 4096 {
            self.delivered.drain(..1024);
        }
        let pos = self.delivered.partition_point(|&x| x < c);
        self.delivered.insert(pos, c);
        true
    }

    fn ack_mine(&mut self, seq: u32) {
        self.unacked.retain(|m| m.seq != seq);
    }

    /// Handle an incoming packet. Returns the decoded messages (in order) and
    /// a packet to send right away (acks), if one is due.
    pub fn receive(&mut self, packet: &[u8], now: Instant) -> (Vec<Message>, Option<Vec<u8>>) {
        let Some(plain) = crypto::decrypt(&self.key, self.dir, packet) else {
            return (Vec::new(), None);
        };
        let raw = self.parse_plain(&plain);
        let reply = if self.acks_to_send.is_empty() {
            None
        } else {
            self.service(now)
        };
        (
            raw.iter().filter_map(|m| Message::parse(m)).collect(),
            reply,
        )
    }

    /// Parse a decrypted packet (seq + entries). Malformed packets stop at the
    /// first bad entry and keep what was valid before it.
    fn parse_plain(&mut self, plain: &[u8]) -> Vec<Vec<u8>> {
        let mut r = Reader { b: plain };
        let mut out = Vec::new();
        let Some(packet_seq) = r.u32() else {
            return out;
        };
        let packet_counter = counter(packet_seq);
        if !self.register_incoming(packet_counter) {
            return out;
        }
        let mut seq = packet_seq;
        let mut additional = false;
        for _ in 0..MAX_ENTRIES {
            let single = seq & SINGLE_BIT != 0;
            if single && additional {
                break;
            }
            let Some(kind) = r.u8() else { break };
            match kind {
                ID_EMPTY if !additional => {}
                ID_ACK if additional => self.ack_mine(seq),
                ID_CUSTOM => {
                    let Some(len) = r.u32() else { break };
                    let len = len as usize;
                    if len > MAX_MESSAGE {
                        break;
                    }
                    let Some(body) = r.bytes(len) else { break };
                    let c = counter(seq);
                    let skip = if seq & ACK_BIT != 0 {
                        let fresh = self.register_delivered(c);
                        if !self.acks_to_send.contains(&seq) && self.acks_to_send.len() < 1024 {
                            self.acks_to_send.push(seq);
                        }
                        !fresh
                    } else {
                        additional && (c > packet_counter || !self.register_incoming(c))
                    };
                    if !skip {
                        out.push(body.to_vec());
                    }
                }
                _ => break,
            }
            if r.b.is_empty() || single || r.b.len() < 5 {
                break;
            }
            let Some(next) = r.u32() else { break };
            seq = next;
            additional = true;
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key() -> CallKey {
        CallKey(core::array::from_fn(|i| (i * 31 + 5) as u8))
    }

    fn setup() -> Message {
        Message::InitialSetup {
            ufrag: "abcd".into(),
            pwd: "0123456789012345678901".into(),
            renomination: true,
            fingerprints: vec![DtlsFingerprint {
                hash: "sha-256".into(),
                setup: "actpass".into(),
                fingerprint: "AB:CD".into(),
            }],
        }
    }

    fn opus_offer() -> Message {
        Message::NegotiateChannels {
            exchange_id: 4_000_000_001,
            contents: vec![MediaContent {
                kind: MediaKind::Audio,
                ssrc: 3_000_000_000,
                ssrc_groups: vec![],
                payload_types: vec![PayloadType {
                    id: 111,
                    name: "opus".into(),
                    clockrate: 48000,
                    channels: 2,
                    feedback: vec![("transport-cc".into(), String::new())],
                    parameters: vec![
                        ("minptime".into(), "10".into()),
                        ("useinbandfec".into(), "1".into()),
                    ],
                }],
                rtp_extensions: vec![RtpExtension {
                    id: 2,
                    uri: "http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time".into(),
                }],
            }],
        }
    }

    #[test]
    fn json_round_trips() {
        for m in [
            setup(),
            opus_offer(),
            Message::Candidates(vec![
                "candidate:1 1 udp 2122260223 192.168.1.2 50000 typ host generation 0".into(),
            ]),
            Message::MediaState {
                muted: true,
                low_battery: false,
            },
        ] {
            assert_eq!(Message::parse(&m.to_json()), Some(m));
        }
    }

    /// The JSON shape the reference implementation produces (numbers for
    /// payload ids, strings for ssrc / exchangeId).
    #[test]
    fn parses_reference_json() {
        let raw = br#"{"@type":"NegotiateChannels","contents":[{"payloadTypes":[{"channels":2,"clockrate":48000,"feedbackTypes":[{"subtype":"","type":"transport-cc"}],"id":111,"name":"opus","parameters":{"minptime":"10","useinbandfec":"1"}}],"rtpExtensions":[{"id":2,"uri":"http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time"},{"id":3,"uri":"http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01"}],"ssrc":"2826457600","type":"audio"}],"exchangeId":"1234"}"#;
        let Some(Message::NegotiateChannels {
            exchange_id,
            contents,
        }) = Message::parse(raw)
        else {
            panic!("not parsed");
        };
        assert_eq!(exchange_id, 1234);
        assert_eq!(contents[0].ssrc, 2_826_457_600);
        assert_eq!(contents[0].payload_types[0].name, "opus");
        assert_eq!(contents[0].rtp_extensions.len(), 2);
    }

    #[test]
    fn hostile_json_is_rejected_quietly() {
        for raw in [
            &b""[..],
            b"[]",
            b"{}",
            b"{\"@type\":5}",
            b"{\"@type\":\"InitialSetup\"}",
            b"{\"@type\":\"Candidates\",\"candidates\":[{\"x\":1}]}",
            b"{\"@type\":\"NegotiateChannels\",\"exchangeId\":\"-1\",\"contents\":[]}",
            b"{\"@type\":\"Whatever\"}",
            b"\xff\xfe",
        ] {
            assert_eq!(Message::parse(raw), None);
        }
        // Unknown contents are dropped, the message survives.
        let m = Message::parse(
            br#"{"@type":"NegotiateChannels","exchangeId":7,"contents":[{"type":"data","ssrc":"1"},{"type":"audio","ssrc":"9"}]}"#,
        );
        assert!(
            matches!(m, Some(Message::NegotiateChannels { ref contents, .. }) if contents.len() == 1)
        );
    }

    #[test]
    fn delivery_and_acks() {
        let now = Instant::now();
        let mut a = Channel::new(key(), true);
        let mut b = Channel::new(key(), false);
        let p1 = a.send(&setup(), now).unwrap();
        assert_eq!(a.pending(), 1);
        let (msgs, ack) = b.receive(&p1, now);
        assert_eq!(msgs, vec![setup()]);
        let ack = ack.expect("ack packet");
        // A duplicate is not delivered twice but is acked again.
        let (dup, _) = b.receive(&p1, now);
        assert!(dup.is_empty());
        let (none, _) = a.receive(&ack, now);
        assert!(none.is_empty());
        assert_eq!(a.pending(), 0);
    }

    #[test]
    fn lost_messages_are_resent_in_order() {
        let t0 = Instant::now();
        let mut a = Channel::new(key(), true);
        let mut b = Channel::new(key(), false);
        let _lost1 = a.send(&setup(), t0).unwrap();
        let p2 = a.send(&opus_offer(), t0).unwrap();
        // The second packet carries both (in order) because #1 is unacked.
        let (msgs, _) = b.receive(&p2, t0);
        assert_eq!(msgs, vec![setup(), opus_offer()]);
        // Nothing due before the resend interval...
        let mut c = Channel::new(key(), true);
        let _ = c.send(&setup(), t0);
        assert!(c.service(t0 + Duration::from_millis(100)).is_none());
        // ...then a resend.
        let r = c.service(t0 + MIN_RESEND).expect("resend");
        let mut d = Channel::new(key(), false);
        assert_eq!(d.receive(&r, t0).0, vec![setup()]);
    }

    #[test]
    fn fuzzed_plaintext_never_panics() {
        let mut seed = 0x1234_5678u32;
        let mut rnd = || {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            seed
        };
        let mut ch = Channel::new(key(), false);
        let base = {
            let mut v = Vec::new();
            put_u32(&mut v, 1 | ACK_BIT);
            v.push(ID_CUSTOM);
            put_u32(&mut v, 3);
            v.extend_from_slice(b"{} ");
            put_u32(&mut v, 2);
            v.push(ID_ACK);
            v
        };
        for i in 0..5000u32 {
            let mut p = base.clone();
            let n = (rnd() % 4) as usize;
            for _ in 0..n {
                let at = rnd() as usize % p.len();
                p[at] = rnd() as u8;
            }
            if rnd().is_multiple_of(3) {
                p.truncate(rnd() as usize % (p.len() + 1));
            }
            if rnd().is_multiple_of(5) {
                p.extend((0..rnd() % 40).map(|_| rnd() as u8));
            }
            if p.len() < 4 {
                continue;
            }
            p[0..4].copy_from_slice(&(i + 10).to_be_bytes());
            let _ = ch.parse_plain(&p);
            let enc = crypto::encrypt(&key(), Direction { outgoing: true }, &p);
            let _ = ch.receive(&enc, Instant::now());
        }
        // Random ciphertext.
        for _ in 0..500 {
            let p: Vec<u8> = (0..rnd() % 200).map(|_| rnd() as u8).collect();
            let _ = ch.receive(&p, Instant::now());
        }
    }

    #[test]
    fn replay_window() {
        let mut ch = Channel::new(key(), false);
        assert!(ch.register_incoming(100));
        assert!(!ch.register_incoming(100));
        assert!(ch.register_incoming(99));
        assert!(!ch.register_incoming(36)); // too old
        assert!(ch.register_incoming(200));
        assert!(ch.incoming.len() <= KEEP_COUNTERS as usize);
    }
}
