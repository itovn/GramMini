// Phỏng theo Ferrogram — github.com/Dasemu/Ferrogram, src/net/calls/ice.rs
// Copyright (c) 2026 Darío Sevilla Muñoz. Giấy phép MIT (crates/gm-call/LICENSE-FERROGRAM).
// GramMini sửa: đường dẫn module (CallKey ở tg/mod.rs), âm thanh qua gm-opus.

//! A small sans-IO ICE agent (RFC 8445 subset) with Telegram's reflector
//! relay. The engine owns the sockets; this module decides what to send
//! where and which path carries media.
//!
//! * Local candidates: one host candidate per bound UDP socket, plus one relay
//!   candidate per Telegram reflector (`phoneConnection`) once it answered.
//! * Reflector framing (tgcalls `ReflectorPort`): every datagram to a
//!   reflector starts with a 16-byte tag; the first 12 bytes identify the call
//!   (from `peer_tag`), the last 4 the endpoint (a random tag of ours or the
//!   peer's, little-endian). Data packets carry `sender tag (4, LE) || length
//!   (4, BE) || payload`, padded to 4 bytes. Relay candidates are announced as
//!   host names `reflector-<server>-<tag>.reflector`.
//! * The caller is controlling and nominates aggressively (USE-CANDIDATE on
//!   every check); the callee follows the peer's nomination.

use std::collections::VecDeque;
use std::net::{IpAddr, SocketAddr};
use std::time::{Duration, Instant};

use rand::{Rng, RngCore};

use super::stun::{self, Message};
use tracing::debug;

/// Gỡ lỗi (GramMini): mô tả ngắn một đường (cục bộ → đích) cho log STUN.
fn path_str(local: LocalRef, target: Target) -> String {
    let l = match local {
        LocalRef::Host(i) => format!("host{i}"),
        LocalRef::Reflector(i) => format!("refl{i}"),
    };
    let t = match target {
        Target::Addr(a) => format!("{}:{}", if a.is_ipv4() { "v4" } else { "v6" }, a.port()),
        Target::Reflector { server, tag } => format!("refl{server}/{tag}"),
    };
    format!("{l}->{t}")
}

/// Pacing between new checks.
const TA: Duration = Duration::from_millis(25);
const RTO: Duration = Duration::from_millis(250);
const MAX_ATTEMPTS: u32 = 7;
/// Failed pairs are retried this often while nothing works.
const RETRY_FAILED: Duration = Duration::from_secs(2);
const KEEPALIVE: Duration = Duration::from_millis(2000);
/// Nothing received on the selected path for this long: disconnected.
const RX_TIMEOUT: Duration = Duration::from_secs(8);
const HELLO_FAST: Duration = Duration::from_millis(500);
const HELLO_SLOW: Duration = Duration::from_secs(10);
const MAX_REMOTE: usize = 64;
const MAX_PAIRS: usize = 256;
const MAX_DATAGRAM: usize = 64 * 1024;

const TYPE_HOST: u32 = 126;
const TYPE_PRFLX: u32 = 110;
const TYPE_RELAY: u32 = 2;

/// Who we send to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Target {
    Addr(SocketAddr),
    /// The peer's endpoint `tag` on reflector `server`.
    Reflector {
        server: u8,
        tag: u32,
    },
}

/// A datagram for the engine to send.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Transmit {
    pub socket: usize,
    pub dest: SocketAddr,
    pub data: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// A local candidate (SDP `candidate:` line) to signal to the peer.
    Candidate(String),
    /// A path is selected: media can flow.
    Connected,
    /// The selected path went silent.
    Disconnected,
}

/// A Telegram reflector (`phoneConnection`, UDP).
#[derive(Debug, Clone)]
pub struct ReflectorConfig {
    /// 1-based position of the connection id among all ids, sorted.
    pub server: u8,
    pub addr: SocketAddr,
    pub peer_tag: [u8; 16],
}

#[derive(Debug)]
struct Reflector {
    cfg: ReflectorConfig,
    socket: usize,
    tag: u32,
    ready: bool,
    last_hello: Option<Instant>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LocalRef {
    Host(usize),
    Reflector(usize),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PairState {
    Waiting,
    InProgress,
    Succeeded,
    Failed,
}

#[derive(Debug)]
struct Pair {
    local: LocalRef,
    target: Target,
    priority: u64,
    state: PairState,
    txid: [u8; 12],
    attempts: u32,
    last_sent: Option<Instant>,
    nominated: bool,
}

pub struct Agent {
    controlling: bool,
    tie_breaker: u64,
    ufrag: String,
    pwd: String,
    remote_creds: Option<(String, String)>,
    hosts: Vec<SocketAddr>,
    reflectors: Vec<Reflector>,
    standalone: bool,
    remotes: Vec<Target>,
    pairs: Vec<Pair>,
    selected: Option<usize>,
    /// Where data came from last, used before a pair is selected.
    last_data_path: Option<(LocalRef, Target)>,
    last_rx: Option<Instant>,
    last_check: Option<Instant>,
    last_keepalive: Option<Instant>,
    connected: bool,
    transmits: VecDeque<Transmit>,
    events: VecDeque<Event>,
}

impl std::fmt::Debug for Agent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ice::Agent")
            .field("controlling", &self.controlling)
            .field("pairs", &self.pairs.len())
            .field("connected", &self.connected)
            .finish_non_exhaustive()
    }
}

/// Random ICE credential string (ufrag 4+, pwd 22+ chars of `ice-char`).
pub fn random_ice_string(len: usize) -> String {
    const CHARS: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/";
    let mut rng = rand::rng();
    (0..len)
        .map(|_| char::from(CHARS[rng.random_range(0..CHARS.len())]))
        .collect()
}

fn candidate_priority(type_pref: u32, local_pref: u32) -> u32 {
    (type_pref << 24) | ((local_pref & 0xffff) << 8) | 255
}

fn pair_priority(controlling: u32, controlled: u32) -> u64 {
    let (g, d) = (u64::from(controlling), u64::from(controlled));
    (1u64 << 32) * g.min(d) + 2 * g.max(d) + u64::from(g > d)
}

/// What a remote `candidate:` line says.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedCandidate {
    pub target: Target,
    pub priority: u32,
    pub kind: String,
}

/// Parse an SDP candidate line (`candidate:` prefix and `a=` optional). UDP
/// only; reflector host names map to [`Target::Reflector`].
pub fn parse_candidate(line: &str) -> Option<ParsedCandidate> {
    let line = line.trim();
    let line = line.strip_prefix("a=").unwrap_or(line);
    let line = line.strip_prefix("candidate:")?;
    if line.len() > 1024 {
        return None;
    }
    let f: Vec<&str> = line.split_ascii_whitespace().take(32).collect();
    if f.len() < 8 || f[6] != "typ" {
        return None;
    }
    if f[1] != "1" || !f[2].eq_ignore_ascii_case("udp") {
        return None;
    }
    let priority: u32 = f[3].parse().ok()?;
    let port: u16 = f[5].parse().ok()?;
    let kind = f[7].to_owned();
    let target = if let Ok(ip) = f[4].parse::<IpAddr>() {
        if port == 0 {
            return None;
        }
        Target::Addr(SocketAddr::new(ip, port))
    } else {
        let rest = f[4]
            .strip_prefix("reflector-")?
            .strip_suffix(".reflector")?;
        let (server, tag) = rest.split_once('-')?;
        Target::Reflector {
            server: server.parse().ok()?,
            tag: tag.parse().ok()?,
        }
    };
    Some(ParsedCandidate {
        target,
        priority,
        kind,
    })
}

impl Agent {
    /// `hosts`: the bound address of each host socket (index = socket id).
    /// Reflector `i` uses socket `hosts.len() + i`.
    pub fn new(
        controlling: bool,
        hosts: Vec<SocketAddr>,
        reflectors: Vec<ReflectorConfig>,
        standalone: bool,
    ) -> Self {
        let mut rng = rand::rng();
        let base = hosts.len();
        let reflectors = reflectors
            .into_iter()
            .enumerate()
            .map(|(i, cfg)| Reflector {
                cfg,
                socket: base + i,
                tag: if standalone {
                    if controlling { 1 } else { 2 }
                } else {
                    loop {
                        let t = rng.next_u32();
                        if t != 0 {
                            break t;
                        }
                    }
                },
                ready: false,
                last_hello: None,
            })
            .collect();
        Self {
            controlling,
            tie_breaker: rng.next_u64(),
            ufrag: random_ice_string(4),
            pwd: random_ice_string(24),
            remote_creds: None,
            hosts,
            reflectors,
            standalone,
            remotes: Vec::new(),
            pairs: Vec::new(),
            selected: None,
            last_data_path: None,
            last_rx: None,
            last_check: None,
            last_keepalive: None,
            connected: false,
            transmits: VecDeque::new(),
            events: VecDeque::new(),
        }
    }

    pub fn ufrag(&self) -> &str {
        &self.ufrag
    }

    pub fn pwd(&self) -> &str {
        &self.pwd
    }

    pub fn is_connected(&self) -> bool {
        self.connected
    }

    /// Short description of the selected path ("p2p" / "relay").
    pub fn route(&self) -> Option<&'static str> {
        let p = self.pairs.get(self.selected?)?;
        Some(match p.local {
            LocalRef::Host(_) => "p2p",
            LocalRef::Reflector(_) => "relay",
        })
    }

    /// Host candidates, available right away.
    pub fn host_candidates(&self) -> Vec<String> {
        self.hosts
            .iter()
            .enumerate()
            .map(|(i, a)| {
                let local_pref = 65535 - u32::try_from(i).unwrap_or(0).min(1000);
                format!(
                    "candidate:{} 1 udp {} {} {} typ host generation 0 ufrag {} network-id {} network-cost 10",
                    1000 + i,
                    candidate_priority(TYPE_HOST, local_pref),
                    a.ip(),
                    a.port(),
                    self.ufrag,
                    i + 1
                )
            })
            .collect()
    }

    fn reflector_candidate(&self, r: &Reflector) -> String {
        format!(
            "candidate:{} 1 udp {} reflector-{}-{}.reflector {} typ relay raddr 0.0.0.0 rport 0 generation 0 ufrag {} network-id 1 network-cost 10",
            2000 + u32::from(r.cfg.server),
            candidate_priority(TYPE_RELAY, 65535 - u32::from(r.cfg.server)),
            r.cfg.server,
            r.tag,
            r.cfg.addr.port(),
            self.ufrag
        )
    }

    pub fn set_remote_credentials(&mut self, ufrag: &str, pwd: &str) {
        if ufrag.len() > 256 || pwd.len() > 256 {
            return;
        }
        self.remote_creds = Some((ufrag.to_owned(), pwd.to_owned()));
        if self.standalone {
            // Standalone reflectors: the peer's relay candidate on each of our
            // reflectors is implied by its role tag.
            let peer_tag = if self.controlling { 2 } else { 1 };
            let servers: Vec<u8> = self.reflectors.iter().map(|r| r.cfg.server).collect();
            for server in servers {
                self.add_remote(
                    Target::Reflector {
                        server,
                        tag: peer_tag,
                    },
                    candidate_priority(TYPE_RELAY, 1),
                );
            }
        }
    }

    pub fn add_remote_candidate(&mut self, line: &str) {
        let Some(c) = parse_candidate(line) else {
            return;
        };
        if self.standalone && matches!(c.target, Target::Reflector { .. }) {
            return;
        }
        self.add_remote(c.target, c.priority);
    }

    fn add_remote(&mut self, target: Target, priority: u32) {
        if self.remotes.len() >= MAX_REMOTE || self.remotes.contains(&target) {
            return;
        }
        self.remotes.push(target);
        self.make_pairs(target, priority);
    }

    fn local_priority(&self, l: LocalRef) -> u32 {
        match l {
            LocalRef::Host(i) => {
                candidate_priority(TYPE_HOST, 65535 - u32::try_from(i).unwrap_or(0).min(1000))
            }
            LocalRef::Reflector(i) => candidate_priority(
                TYPE_RELAY,
                65535 - u32::from(self.reflectors.get(i).map_or(0, |r| r.cfg.server)),
            ),
        }
    }

    fn make_pairs(&mut self, target: Target, remote_priority: u32) {
        let mut locals = Vec::new();
        match target {
            Target::Addr(a) => {
                for (i, h) in self.hosts.iter().enumerate() {
                    if h.is_ipv4() == a.is_ipv4() && h.ip().is_loopback() == a.ip().is_loopback() {
                        locals.push(LocalRef::Host(i));
                    }
                }
            }
            Target::Reflector { server, .. } => {
                for (i, r) in self.reflectors.iter().enumerate() {
                    if r.cfg.server == server {
                        locals.push(LocalRef::Reflector(i));
                    }
                }
            }
        }
        for local in locals {
            if self.pairs.len() >= MAX_PAIRS {
                return;
            }
            if self
                .pairs
                .iter()
                .any(|p| p.local == local && p.target == target)
            {
                continue;
            }
            let lp = self.local_priority(local);
            let priority = if self.controlling {
                pair_priority(lp, remote_priority)
            } else {
                pair_priority(remote_priority, lp)
            };
            self.pairs.push(Pair {
                local,
                target,
                priority,
                state: PairState::Waiting,
                txid: [0; 12],
                attempts: 0,
                last_sent: None,
                nominated: false,
            });
        }
        self.sort_pairs();
    }

    /// Sort by priority, keeping `selected` pointing at the same pair.
    fn sort_pairs(&mut self) {
        let sel = self
            .selected
            .and_then(|i| self.pairs.get(i))
            .map(|p| (p.local, p.target));
        self.pairs.sort_by_key(|p| std::cmp::Reverse(p.priority));
        self.selected = sel.and_then(|(l, t)| {
            self.pairs
                .iter()
                .position(|p| p.local == l && p.target == t)
        });
    }

    /// Wrap `data` for `target` from `local` into a datagram.
    fn transmit_to(&self, local: LocalRef, target: Target, data: Vec<u8>) -> Option<Transmit> {
        match (local, target) {
            (LocalRef::Host(i), Target::Addr(dest)) => Some(Transmit {
                socket: i,
                dest,
                data,
            }),
            (LocalRef::Reflector(i), Target::Reflector { tag, .. }) => {
                let r = self.reflectors.get(i)?;
                let mut out = Vec::with_capacity(data.len() + 28);
                out.extend_from_slice(&r.cfg.peer_tag[..12]);
                out.extend_from_slice(&tag.to_le_bytes());
                out.extend_from_slice(&r.tag.to_le_bytes());
                out.extend_from_slice(&u32::try_from(data.len()).ok()?.to_be_bytes());
                out.extend_from_slice(&data);
                while !out.len().is_multiple_of(4) {
                    out.push(0);
                }
                Some(Transmit {
                    socket: r.socket,
                    dest: r.cfg.addr,
                    data: out,
                })
            }
            _ => None,
        }
    }

    fn hello(&self, r: &Reflector) -> Transmit {
        let mut out = Vec::with_capacity(40);
        out.extend_from_slice(&r.cfg.peer_tag[..12]);
        out.extend_from_slice(&r.tag.to_le_bytes());
        out.extend_from_slice(&[0xff; 12]);
        out.push(0xfe);
        out.extend_from_slice(&[0xff; 3]);
        out.extend_from_slice(&123u64.to_be_bytes());
        Transmit {
            socket: r.socket,
            dest: r.cfg.addr,
            data: out,
        }
    }

    /// Queue `data` (DTLS, SRTP) on the selected path, or on the path the
    /// peer last used before one is selected.
    pub fn send(&mut self, data: Vec<u8>) -> bool {
        let path = self
            .selected
            .and_then(|i| self.pairs.get(i))
            .map(|p| (p.local, p.target))
            .or(self.last_data_path);
        let Some((local, target)) = path else {
            return false;
        };
        match self.transmit_to(local, target, data) {
            Some(t) => {
                self.transmits.push_back(t);
                true
            }
            None => false,
        }
    }

    pub fn poll_transmit(&mut self) -> Option<Transmit> {
        self.transmits.pop_front()
    }

    pub fn poll_event(&mut self) -> Option<Event> {
        self.events.pop_front()
    }

    fn check_request(&self, pair: &Pair) -> Option<Vec<u8>> {
        let (rufrag, rpwd) = self.remote_creds.as_ref()?;
        let mut m = Message::new(stun::BINDING_REQUEST, pair.txid);
        m.push(
            stun::ATTR_USERNAME,
            format!("{rufrag}:{}", self.ufrag).into_bytes(),
        )
        .push(
            stun::ATTR_PRIORITY,
            candidate_priority(TYPE_PRFLX, 65535).to_be_bytes().to_vec(),
        );
        if self.controlling {
            m.push(
                stun::ATTR_CONTROLLING,
                self.tie_breaker.to_be_bytes().to_vec(),
            );
            m.push(stun::ATTR_USE_CANDIDATE, Vec::new());
        } else {
            m.push(
                stun::ATTR_CONTROLLED,
                self.tie_breaker.to_be_bytes().to_vec(),
            );
        }
        Some(m.encode(Some(rpwd.as_bytes()), true))
    }

    fn send_check(&mut self, idx: usize, now: Instant) {
        let mut txid = [0u8; 12];
        rand::rng().fill_bytes(&mut txid);
        let Some(pair) = self.pairs.get_mut(idx) else {
            return;
        };
        if pair.state != PairState::InProgress {
            pair.attempts = 0;
        }
        pair.txid = txid;
        pair.state = PairState::InProgress;
        pair.attempts += 1;
        pair.last_sent = Some(now);
        let Some(pair) = self.pairs.get(idx) else {
            return;
        };
        if let Some(req) = self.check_request(pair)
            && let Some(t) = self.transmit_to(pair.local, pair.target, req)
        {
            debug!(target: "ice", path = %path_str(pair.local, pair.target), attempt = pair.attempts, state = ?pair.state, "check out");
            self.transmits.push_back(t);
        }
    }

    /// Drive timers. Call at least every 20 ms.
    pub fn tick(&mut self, now: Instant) {
        // Reflector hellos.
        let mut hellos = Vec::new();
        for r in &mut self.reflectors {
            let every = if r.ready { HELLO_SLOW } else { HELLO_FAST };
            if r.last_hello.is_none_or(|t| now >= t + every) {
                r.last_hello = Some(now);
                hellos.push(r.socket);
            }
        }
        for s in hellos {
            if let Some(r) = self.reflectors.iter().find(|r| r.socket == s) {
                let t = self.hello(r);
                self.transmits.push_back(t);
            }
        }
        if self.remote_creds.is_none() {
            return;
        }
        // Retransmit / fail checks in progress.
        let mut resend = Vec::new();
        for (i, p) in self.pairs.iter_mut().enumerate() {
            if p.state == PairState::InProgress
                && let Some(t) = p.last_sent
            {
                let rto = RTO * 2u32.saturating_pow(p.attempts.saturating_sub(1).min(4));
                if now >= t + rto {
                    if p.attempts >= MAX_ATTEMPTS {
                        p.state = PairState::Failed;
                    } else {
                        resend.push(i);
                    }
                }
            }
        }
        for i in resend {
            self.send_check(i, now);
        }
        // One new check per Ta.
        if self.last_check.is_none_or(|t| now >= t + TA) {
            let next = self
                .pairs
                .iter()
                .position(|p| p.state == PairState::Waiting)
                .or_else(|| {
                    (!self.connected)
                        .then(|| {
                            self.pairs.iter().position(|p| {
                                p.state == PairState::Failed
                                    && p.last_sent.is_none_or(|t| now >= t + RETRY_FAILED)
                            })
                        })
                        .flatten()
                });
            if let Some(i) = next {
                self.last_check = Some(now);
                self.send_check(i, now);
            }
        }
        // Keepalive / consent on the selected pair.
        if let Some(i) = self.selected
            && self.last_keepalive.is_none_or(|t| now >= t + KEEPALIVE)
            && self
                .pairs
                .get(i)
                .is_some_and(|p| p.state != PairState::InProgress)
        {
            self.last_keepalive = Some(now);
            self.send_check(i, now);
        }
        // Liveness.
        if self.connected && self.last_rx.is_none_or(|t| now >= t + RX_TIMEOUT) {
            self.connected = false;
            self.selected = None;
            for p in &mut self.pairs {
                if p.state == PairState::Succeeded {
                    p.state = PairState::Waiting;
                }
                p.nominated = false;
            }
            self.events.push_back(Event::Disconnected);
        }
    }

    fn select(&mut self, idx: usize) {
        let better = match self.selected {
            None => true,
            Some(cur) => {
                cur != idx
                    && self.pairs.get(idx).map(|p| p.priority)
                        > self.pairs.get(cur).map(|p| p.priority)
            }
        };
        if !better {
            return;
        }
        if let Some(p) = self.pairs.get_mut(idx) {
            p.nominated = true;
        }
        debug!(target: "ice", pair = %self.pairs.get(idx).map(|p| path_str(p.local, p.target)).unwrap_or_default(), "selected");
        self.selected = Some(idx);
        if !self.connected {
            self.connected = true;
            self.events.push_back(Event::Connected);
        }
    }

    fn pair_index(&mut self, local: LocalRef, target: Target) -> Option<usize> {
        if let Some(i) = self
            .pairs
            .iter()
            .position(|p| p.local == local && p.target == target)
        {
            return Some(i);
        }
        // Peer-reflexive: learn the address from the check.
        if self.remotes.len() >= MAX_REMOTE || self.pairs.len() >= MAX_PAIRS {
            return None;
        }
        self.remotes.push(target);
        let lp = self.local_priority(local);
        let rp = candidate_priority(TYPE_PRFLX, 1);
        self.pairs.push(Pair {
            local,
            target,
            priority: if self.controlling {
                pair_priority(lp, rp)
            } else {
                pair_priority(rp, lp)
            },
            state: PairState::Waiting,
            txid: [0; 12],
            attempts: 0,
            last_sent: None,
            nominated: false,
        });
        self.sort_pairs();
        self.pairs
            .iter()
            .position(|p| p.local == local && p.target == target)
    }

    /// Feed a datagram received on `socket` from `from`. Returns application
    /// data (DTLS / SRTP) to hand to the upper layers.
    pub fn handle(
        &mut self,
        socket: usize,
        from: SocketAddr,
        data: &[u8],
        now: Instant,
    ) -> Option<Vec<u8>> {
        if data.len() > MAX_DATAGRAM {
            return None;
        }
        let (local, target, payload) = if socket < self.hosts.len() {
            (LocalRef::Host(socket), Target::Addr(from), data)
        } else {
            let ri = self.reflectors.iter().position(|r| r.socket == socket)?;
            let r = &mut self.reflectors[ri];
            if from != r.cfg.addr || data.len() < 16 || data[..12] != r.cfg.peer_tag[..12] {
                return None;
            }
            if !r.ready {
                r.ready = true;
                if !self.standalone {
                    let line = self.reflector_candidate(&self.reflectors[ri]);
                    self.events.push_back(Event::Candidate(line));
                }
            }
            if data.len() <= 24 || data[16..data.len().min(28)].iter().all(|&b| b == 0xff) {
                return None; // hello reply / special packet
            }
            let sender = u32::from_le_bytes(data[16..20].try_into().ok()?);
            let len = usize::try_from(u32::from_be_bytes(data[20..24].try_into().ok()?)).ok()?;
            let payload = data.get(24..24 + len)?;
            let server = self.reflectors[ri].cfg.server;
            (
                LocalRef::Reflector(ri),
                Target::Reflector {
                    server,
                    tag: sender,
                },
                payload,
            )
        };
        if stun::looks_like_stun(payload) {
            self.handle_stun(local, target, from, payload, now);
            return None;
        }
        // Only accept data from a path that proved itself with STUN.
        let known = self.pairs.iter().any(|p| {
            p.local == local
                && p.target == target
                && (p.state == PairState::Succeeded || p.nominated)
        });
        let peer_seen = self.last_data_path == Some((local, target));
        if !known && !peer_seen {
            return None;
        }
        self.last_rx = Some(now);
        if self.selected.is_none() {
            self.last_data_path = Some((local, target));
        }
        Some(payload.to_vec())
    }

    fn handle_stun(
        &mut self,
        local: LocalRef,
        target: Target,
        from: SocketAddr,
        raw: &[u8],
        now: Instant,
    ) {
        let Some(msg) = Message::decode(raw) else {
            return;
        };
        if !stun::verify_fingerprint(raw) {
            return;
        }
        match msg.kind {
            stun::BINDING_REQUEST => {
                if !stun::verify_integrity(raw, self.pwd.as_bytes()) {
                    debug!(target: "ice", path = %path_str(local, target), "request in: integrity FAIL");
                    return;
                }
                let Some(user) = msg.username() else { return };
                let Some((ours, _theirs)) = user.split_once(':') else {
                    return;
                };
                if ours != self.ufrag {
                    debug!(target: "ice", path = %path_str(local, target), user, "request in: wrong ufrag");
                    return;
                }
                let mut resp = Message::new(stun::BINDING_SUCCESS, msg.txid);
                resp.push(
                    stun::ATTR_XOR_MAPPED,
                    stun::encode_xor_addr(from, &msg.txid),
                );
                let resp = resp.encode(Some(self.pwd.as_bytes()), true);
                if let Some(t) = self.transmit_to(local, target, resp) {
                    self.transmits.push_back(t);
                }
                self.last_rx = Some(now);
                let Some(idx) = self.pair_index(local, target) else {
                    return;
                };
                let use_candidate = msg.has(stun::ATTR_USE_CANDIDATE) || msg.has(0xc001);
                debug!(
                    target: "ice",
                    path = %path_str(local, target),
                    use_candidate = msg.has(stun::ATTR_USE_CANDIDATE),
                    nomination = ?msg.attr(0xc001).map(|v| v.iter().fold(0u32, |a, b| (a << 8) | u32::from(*b))),
                    controlling = msg.has(stun::ATTR_CONTROLLING),
                    controlled = msg.has(stun::ATTR_CONTROLLED),
                    attrs = ?msg.attr_types(),
                    pair_state = ?self.pairs.get(idx).map(|p| p.state),
                    "request in (answered)"
                );
                // Triggered check for pairs we have not validated yet.
                if self
                    .pairs
                    .get(idx)
                    .is_some_and(|p| p.state == PairState::Waiting || p.state == PairState::Failed)
                {
                    self.send_check(idx, now);
                }
                if !self.controlling && use_candidate {
                    self.select(idx);
                }
            }
            stun::BINDING_SUCCESS | stun::BINDING_ERROR => {
                let Some(idx) = self
                    .pairs
                    .iter()
                    .position(|p| p.txid == msg.txid && p.state == PairState::InProgress)
                else {
                    debug!(target: "ice", path = %path_str(local, target), kind = msg.kind, "response in: no matching check");
                    return;
                };
                debug!(
                    target: "ice",
                    path = %path_str(local, target),
                    pair = %self.pairs.get(idx).map(|p| path_str(p.local, p.target)).unwrap_or_default(),
                    kind = msg.kind,
                    error = ?msg.error_code(),
                    mapped = ?msg.xor_mapped().map(|a| a.port()),
                    "response in"
                );
                let Some((_, rpwd)) = self.remote_creds.as_ref() else {
                    return;
                };
                if !stun::verify_integrity(raw, rpwd.as_bytes()) {
                    return;
                }
                self.last_rx = Some(now);
                if msg.kind == stun::BINDING_ERROR {
                    // 487 role conflict cannot happen with fixed roles; give up on the pair.
                    if let Some(p) = self.pairs.get_mut(idx) {
                        p.state = PairState::Failed;
                    }
                    return;
                }
                if let Some(p) = self.pairs.get_mut(idx) {
                    p.state = PairState::Succeeded;
                }
                if self.controlling || self.pairs.get(idx).is_some_and(|p| p.nominated) {
                    self.select(idx);
                }
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn addr(s: &str) -> SocketAddr {
        s.parse().unwrap()
    }

    #[test]
    fn candidate_lines() {
        let c = parse_candidate("candidate:842163049 1 udp 1677729535 203.0.113.7 46154 typ srflx raddr 10.0.0.2 rport 46154 generation 0 ufrag EsAw network-id 1 network-cost 10").unwrap();
        assert_eq!(c.target, Target::Addr(addr("203.0.113.7:46154")));
        assert_eq!(c.kind, "srflx");
        let c = parse_candidate("a=candidate:1 1 UDP 2 reflector-3-4000000000.reflector 599 typ relay raddr 0.0.0.0 rport 0").unwrap();
        assert_eq!(
            c.target,
            Target::Reflector {
                server: 3,
                tag: 4_000_000_000
            }
        );
        let c = parse_candidate("candidate:1 1 udp 5 2001:db8::1 9 typ host").unwrap();
        assert_eq!(c.target, Target::Addr(addr("[2001:db8::1]:9")));
        for bad in [
            "",
            "candidate:",
            "candidate:1 1 tcp 1 1.2.3.4 5 typ host",
            "candidate:1 2 udp 1 1.2.3.4 5 typ host",
            "candidate:1 1 udp x 1.2.3.4 5 typ host",
            "candidate:1 1 udp 1 1.2.3.4 0 typ host",
            "candidate:1 1 udp 1 example.com 5 typ host",
            "candidate:1 1 udp 1 reflector-x-1.reflector 5 typ relay",
            "candidate:1 1 udp 1 reflector-1-99999999999.reflector 5 typ relay",
            "candidate:1 1 udp 1 1.2.3.4 5 nottyp host",
        ] {
            assert_eq!(parse_candidate(bad), None, "{bad}");
        }
        let a = Agent::new(true, vec![addr("10.0.0.1:5000")], vec![], false);
        let line = &a.host_candidates()[0];
        assert_eq!(
            parse_candidate(line).unwrap().target,
            Target::Addr(addr("10.0.0.1:5000"))
        );
    }

    /// Shuttle datagrams between two agents (and an in-memory reflector).
    struct Net {
        a: Agent,
        b: Agent,
        a_addrs: Vec<SocketAddr>,
        b_addrs: Vec<SocketAddr>,
        reflector: Option<SocketAddr>,
        drop_direct: bool,
    }

    impl Net {
        fn run(&mut self, now: &mut Instant, steps: usize) -> (Vec<Vec<u8>>, Vec<Vec<u8>>) {
            let mut got_a = Vec::new();
            let mut got_b = Vec::new();
            for _ in 0..steps {
                *now += Duration::from_millis(10);
                self.a.tick(*now);
                self.b.tick(*now);
                for _ in 0..64 {
                    let ta = self.a.poll_transmit();
                    let tb = self.b.poll_transmit();
                    if ta.is_none() && tb.is_none() {
                        break;
                    }
                    if let Some(t) = ta
                        && let Some(d) = Self::deliver(
                            &self.a_addrs,
                            &self.b_addrs,
                            self.reflector,
                            self.drop_direct,
                            &mut self.b,
                            t,
                            *now,
                        )
                    {
                        got_b.push(d);
                    }
                    if let Some(t) = tb
                        && let Some(d) = Self::deliver(
                            &self.b_addrs,
                            &self.a_addrs,
                            self.reflector,
                            self.drop_direct,
                            &mut self.a,
                            t,
                            *now,
                        )
                    {
                        got_a.push(d);
                    }
                }
            }
            (got_a, got_b)
        }

        /// Route a datagram. Reflector: answer hellos, forward data packets
        /// to the endpoint whose tag is in bytes 12..16.
        fn deliver(
            from_addrs: &[SocketAddr],
            to_addrs: &[SocketAddr],
            reflector: Option<SocketAddr>,
            drop_direct: bool,
            to: &mut Agent,
            t: Transmit,
            now: Instant,
        ) -> Option<Vec<u8>> {
            if Some(t.dest) == reflector {
                let refl = reflector?;
                let n = to.hosts.len();
                if t.data[16..28].iter().all(|&b| b == 0xff) {
                    return None; // hellos are answered by `answer_hellos`
                }
                // Forward: rewrite nothing (tags already address the peer).
                return to.handle(n, refl, &t.data, now);
            }
            if drop_direct {
                return None;
            }
            let src = *from_addrs.get(t.socket)?;
            let sock = to_addrs.iter().position(|a| *a == t.dest)?;
            to.handle(sock, src, &t.data, now)
        }
    }

    fn connect(mut net: Net) -> Net {
        let a_c = net.a.host_candidates();
        let b_c = net.b.host_candidates();
        let (au, ap) = (net.a.ufrag().to_owned(), net.a.pwd().to_owned());
        let (bu, bp) = (net.b.ufrag().to_owned(), net.b.pwd().to_owned());
        net.a.set_remote_credentials(&bu, &bp);
        net.b.set_remote_credentials(&au, &ap);
        for c in b_c {
            net.a.add_remote_candidate(&c);
        }
        for c in a_c {
            net.b.add_remote_candidate(&c);
        }
        net
    }

    #[test]
    fn direct_path_connects_and_carries_data() {
        let a_addrs = vec![addr("10.0.0.1:1000")];
        let b_addrs = vec![addr("10.0.0.2:2000")];
        let mut net = connect(Net {
            a: Agent::new(true, a_addrs.clone(), vec![], false),
            b: Agent::new(false, b_addrs.clone(), vec![], false),
            a_addrs,
            b_addrs,
            reflector: None,
            drop_direct: false,
        });
        let mut now = Instant::now();
        net.run(&mut now, 30);
        assert!(net.a.is_connected());
        assert!(net.b.is_connected());
        assert_eq!(net.a.route(), Some("p2p"));
        assert_eq!(net.a.poll_event(), Some(Event::Connected));
        assert!(net.a.send(vec![22, 1, 2, 3]));
        assert!(net.b.send(vec![128, 9]));
        let (got_a, got_b) = net.run(&mut now, 2);
        assert_eq!(got_b, vec![vec![22, 1, 2, 3]]);
        assert_eq!(got_a, vec![vec![128, 9]]);
        // Keepalives keep it alive; silence disconnects.
        net.run(&mut now, 1500);
        assert!(net.a.is_connected());
        let mut later = now + Duration::from_secs(30);
        net.a.tick(later);
        assert!(!net.a.is_connected());
        later += Duration::from_millis(1);
        net.a.tick(later);
    }

    #[test]
    fn reflector_path_when_direct_is_blocked() {
        let refl = addr("149.154.1.1:599");
        let tag = [7u8; 16];
        let cfg = |_: ()| ReflectorConfig {
            server: 1,
            addr: refl,
            peer_tag: tag,
        };
        let a_addrs = vec![addr("10.0.0.1:1000")];
        let b_addrs = vec![addr("10.0.0.2:2000")];
        let mut net = connect(Net {
            a: Agent::new(true, a_addrs.clone(), vec![cfg(())], false),
            b: Agent::new(false, b_addrs.clone(), vec![cfg(())], false),
            a_addrs,
            b_addrs,
            reflector: Some(refl),
            drop_direct: true,
        });
        // The reflector answers hellos: emulate with an echo of the tag.
        let mut now = Instant::now();
        for agent in [&mut net.a, &mut net.b] {
            agent.tick(now);
            let hello = agent.poll_transmit().unwrap();
            assert_eq!(hello.dest, refl);
            assert_eq!(hello.data.len(), 40);
            let n = agent.hosts.len();
            assert_eq!(agent.handle(n, refl, &hello.data, now), None);
        }
        // Both announced a relay candidate; exchange them.
        let mut ca = Vec::new();
        while let Some(Event::Candidate(c)) = net.a.poll_event() {
            ca.push(c);
        }
        let mut cb = Vec::new();
        while let Some(Event::Candidate(c)) = net.b.poll_event() {
            cb.push(c);
        }
        assert_eq!(ca.len(), 1);
        assert!(ca[0].contains(".reflector"));
        for c in ca {
            net.b.add_remote_candidate(&c);
        }
        for c in cb {
            net.a.add_remote_candidate(&c);
        }
        now += Duration::from_millis(1);
        net.run(&mut now, 200);
        assert!(net.a.is_connected(), "{:?}", net.a.pairs);
        assert!(net.b.is_connected());
        assert_eq!(net.a.route(), Some("relay"));
        net.a.send(vec![23; 5]);
        let (_, got_b) = net.run(&mut now, 1);
        assert_eq!(got_b, vec![vec![23; 5]]);
    }

    #[test]
    fn standalone_reflectors_need_no_candidates() {
        let refl = addr("149.154.1.1:599");
        let cfg = ReflectorConfig {
            server: 2,
            addr: refl,
            peer_tag: [3; 16],
        };
        let a_addrs = vec![addr("10.0.0.1:1000")];
        let b_addrs = vec![addr("10.0.0.2:2000")];
        let mut net = Net {
            a: Agent::new(true, a_addrs.clone(), vec![cfg.clone()], true),
            b: Agent::new(false, b_addrs.clone(), vec![cfg], true),
            a_addrs,
            b_addrs,
            reflector: Some(refl),
            drop_direct: true,
        };
        let (au, ap) = (net.a.ufrag().to_owned(), net.a.pwd().to_owned());
        let (bu, bp) = (net.b.ufrag().to_owned(), net.b.pwd().to_owned());
        net.a.set_remote_credentials(&bu, &bp);
        net.b.set_remote_credentials(&au, &ap);
        let mut now = Instant::now();
        net.run(&mut now, 200);
        assert!(net.a.is_connected());
        assert!(net.b.is_connected());
    }

    #[test]
    fn rejects_unauthenticated_traffic() {
        let a_addrs = vec![addr("10.0.0.1:1000")];
        let mut a = Agent::new(false, a_addrs, vec![], false);
        a.set_remote_credentials("peer", "peerpasswordpeerpassword");
        let now = Instant::now();
        // Data from an unknown path is dropped.
        assert_eq!(a.handle(0, addr("10.9.9.9:1"), &[0x80; 30], now), None);
        // A request signed with the wrong password gets no answer.
        let mut m = Message::new(stun::BINDING_REQUEST, [1; 12]);
        m.push(
            stun::ATTR_USERNAME,
            format!("{}:peer", a.ufrag()).into_bytes(),
        );
        let raw = m.encode(Some(b"wrong"), true);
        a.handle(0, addr("10.9.9.9:1"), &raw, now);
        assert!(a.poll_transmit().is_none());
        // Signed with ours: answered.
        let raw = m.encode(Some(a.pwd().to_owned().as_bytes()), true);
        a.handle(0, addr("10.9.9.9:1"), &raw, now);
        let t = a.poll_transmit().unwrap();
        assert!(stun::verify_integrity(&t.data, a.pwd().as_bytes()));
        // Junk on sockets that do not exist / from wrong reflectors.
        assert_eq!(a.handle(5, addr("1.1.1.1:1"), &[1, 2, 3], now), None);
        for n in 0..200u32 {
            let junk: Vec<u8> = (0..(n % 90)).map(|i| (i * 7 + n) as u8).collect();
            let _ = a.handle(0, addr("10.9.9.9:1"), &junk, now);
        }
    }
}
