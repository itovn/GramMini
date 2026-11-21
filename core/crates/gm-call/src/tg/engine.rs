// Phỏng theo Ferrogram — github.com/Dasemu/Ferrogram, src/net/calls/engine.rs
// Copyright (c) 2026 Darío Sevilla Muñoz. Giấy phép MIT (crates/gm-call/LICENSE-FERROGRAM).
// GramMini sửa: đường dẫn module (CallKey ở tg/mod.rs), âm thanh qua gm-opus.

//! The per-call media engine: one tokio task that owns the UDP sockets and
//! runs signaling, ICE, DTLS and SRTP; audio comes and goes through
//! [`audio::Shared`] and a channel of encoded Opus frames.
//!
//! Flow (tgcalls `InstanceV2Impl`, signaling V2):
//! 1. The caller sends `InitialSetup` (ICE ufrag/pwd, DTLS fingerprint,
//!    `setup = actpass`), a `NegotiateChannels` offer for its audio stream and
//!    its candidates. The callee answers with its own `InitialSetup`
//!    (`setup = passive`), answers the offer, then offers its own stream.
//! 2. ICE finds a path (host or reflector); the caller is the DTLS client.
//! 3. DTLS-SRTP keys protect Opus RTP packets in both directions.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use rand::RngCore;
use sha2::Digest;
use tokio::net::UdpSocket;
use tokio::sync::{mpsc, oneshot};
use tracing::{debug, info, warn};

use super::audio::Shared;
use super::CallKey;
use super::ice::{self, Agent, ReflectorConfig};
use super::rtp;
use super::signaling::{Channel, DtlsFingerprint, MediaContent, MediaKind, Message, PayloadType};
use super::srtp;

const OPUS_PT: u32 = 111;

/// Bộ đếm gỡ lỗi (GramMini): gói RTP đến / giải SRTP hỏng / lọt bộ lọc SSRC-PT / vào bộ đệm; khung gửi / bỏ vì chưa có PT.
pub mod counters {
    use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
    pub static RTP_IN: AtomicU64 = AtomicU64::new(0);
    pub static SRTP_FAIL: AtomicU64 = AtomicU64::new(0);
    pub static RTCP_IN: AtomicU64 = AtomicU64::new(0);
    pub static RTCP_OK: AtomicU64 = AtomicU64::new(0);
    pub static FILTERED: AtomicU64 = AtomicU64::new(0);
    pub static RTP_OK: AtomicU64 = AtomicU64::new(0);
    pub static SENT: AtomicU64 = AtomicU64::new(0);
    pub static NO_PT: AtomicU64 = AtomicU64::new(0);
    /// Số gói bên kia tự báo đã gửi (báo cáo SR gần nhất) — so với RTP_OK để biết bên kia không phát hay gói bị mất.
    pub static PEER_SENT: AtomicU64 = AtomicU64::new(0);
    /// Về 0 khi bắt đầu cuộc gọi mới (bộ đếm dùng chung cả tiến trình).
    pub fn reset() {
        for c in [&RTP_IN, &SRTP_FAIL, &RTCP_IN, &RTCP_OK, &FILTERED, &RTP_OK, &SENT, &NO_PT, &PEER_SENT] {
            c.store(0, Relaxed);
        }
    }
    pub fn line() -> String {
        format!(
            "RTP đến {} (SRTP hỏng {}, lọc bỏ {}, vào bộ đệm {}), RTCP đến {} (giải được {}); gửi {} khung, bỏ {} khung vì chưa có PT; bên kia báo đã gửi {} gói",
            RTP_IN.load(Relaxed), SRTP_FAIL.load(Relaxed), FILTERED.load(Relaxed), RTP_OK.load(Relaxed),
            RTCP_IN.load(Relaxed), RTCP_OK.load(Relaxed), SENT.load(Relaxed), NO_PT.load(Relaxed), PEER_SENT.load(Relaxed)
        )
    }
}
use std::sync::atomic::Ordering::Relaxed;
const TICK: Duration = Duration::from_millis(10);
const DTLS_TIMEOUT: Duration = Duration::from_secs(20);
const RTCP_EVERY: Duration = Duration::from_secs(5);
const MAX_EARLY_DTLS: usize = 32;
const SOCKET_QUEUE: usize = 1024;

/// Everything the engine needs to know about one call.
#[derive(Clone)]
pub struct EngineConfig {
    pub key: CallKey,
    pub outgoing: bool,
    pub reflectors: Vec<ReflectorConfig>,
    pub standalone_reflectors: bool,
    /// `phoneCall.p2p_allowed`: offer host candidates.
    pub p2p: bool,
    /// Tests: host candidates on 127.0.0.1 instead of the default route.
    pub loopback: bool,
    pub connect_timeout: Duration,
    pub packet_timeout: Duration,
}

impl std::fmt::Debug for EngineConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EngineConfig")
            .field("outgoing", &self.outgoing)
            .field("reflectors", &self.reflectors.len())
            .field("p2p", &self.p2p)
            .finish_non_exhaustive()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LinkState {
    Connecting,
    /// Media flows; `relay` = through a Telegram reflector.
    Connected {
        relay: bool,
    },
    Reconnecting,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EngineEvent {
    /// Send through `phone.sendSignalingData`.
    Signaling(Vec<u8>),
    State(LinkState),
    /// Connection quality, 0..=4 bars.
    Quality(u8),
    /// The call cannot continue (the reason is safe to log).
    Failed(String),
}

#[derive(Debug)]
pub enum Command {
    /// Data from `updatePhoneCallSignalingData`.
    Signaling(Vec<u8>),
    Stop,
}

/// Owner side of a running engine. Dropping it stops the engine.
pub struct EngineHandle {
    cmd: mpsc::UnboundedSender<Command>,
    pub events: Arc<Mutex<Option<mpsc::UnboundedReceiver<EngineEvent>>>>,
    pub shared: Arc<Shared>,
}

impl std::fmt::Debug for EngineHandle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("EngineHandle")
    }
}

impl EngineHandle {
    pub fn signaling(&self, data: Vec<u8>) {
        let _ = self.cmd.send(Command::Signaling(data));
    }

    pub fn stop(&self) {
        let _ = self.cmd.send(Command::Stop);
    }

    pub fn take_events(&self) -> Option<mpsc::UnboundedReceiver<EngineEvent>> {
        self.events.lock().ok()?.take()
    }
}

impl Drop for EngineHandle {
    fn drop(&mut self) {
        let _ = self.cmd.send(Command::Stop);
    }
}

/// Start an engine on the current tokio runtime. `frames` delivers encoded
/// Opus frames from the capture side; received audio goes to
/// `shared.jitter`.
pub fn start(
    cfg: EngineConfig,
    shared: Arc<Shared>,
    frames: mpsc::Receiver<Vec<u8>>,
) -> EngineHandle {
    let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();
    let (ev_tx, ev_rx) = mpsc::unbounded_channel();
    let task_shared = Arc::clone(&shared);
    tokio::spawn(async move {
        let fail_tx = ev_tx.clone();
        if let Err(e) = run(cfg, task_shared, frames, cmd_rx, ev_tx).await {
            warn!(error = %e, "call engine stopped");
            let _ = fail_tx.send(EngineEvent::Failed(e));
        }
    });
    EngineHandle {
        cmd: cmd_tx,
        events: Arc::new(Mutex::new(Some(ev_rx))),
        shared,
    }
}

/// The address the OS would use to reach the internet (no packet is sent).
fn default_route(v6: bool) -> Option<IpAddr> {
    let (bind, probe): (SocketAddr, SocketAddr) = if v6 {
        (
            SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), 0),
            "[2001:4860:4860::8888]:80".parse().ok()?,
        )
    } else {
        (
            SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0),
            "8.8.8.8:80".parse().ok()?,
        )
    };
    let s = std::net::UdpSocket::bind(bind).ok()?;
    s.connect(probe).ok()?;
    let ip = s.local_addr().ok()?.ip();
    (!ip.is_unspecified()).then_some(ip)
}

async fn bind_sockets(
    cfg: &EngineConfig,
) -> Result<(Vec<Arc<UdpSocket>>, Vec<SocketAddr>), String> {
    let mut sockets = Vec::new();
    let mut hosts = Vec::new();
    if cfg.p2p {
        let ips: Vec<IpAddr> = if cfg.loopback {
            vec![IpAddr::V4(Ipv4Addr::LOCALHOST)]
        } else {
            [default_route(false), default_route(true)]
                .into_iter()
                .flatten()
                .collect()
        };
        for ip in ips {
            if let Ok(s) = UdpSocket::bind(SocketAddr::new(ip, 0)).await
                && let Ok(a) = s.local_addr()
            {
                hosts.push(a);
                sockets.push(Arc::new(s));
            }
        }
    }
    for r in &cfg.reflectors {
        let any = if r.addr.is_ipv4() {
            SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0)
        } else {
            SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), 0)
        };
        let s = UdpSocket::bind(any)
            .await
            .map_err(|e| format!("bind: {}", e.kind()))?;
        sockets.push(Arc::new(s));
    }
    if sockets.is_empty() {
        return Err("no usable network path".into());
    }
    Ok((sockets, hosts))
}

/// RFC 4572 fingerprint ("AB:CD:..") of a DER certificate.
pub fn fingerprint(der: &[u8]) -> String {
    sha2::Sha256::digest(der)
        .iter()
        .map(|b| format!("{b:02X}"))
        .collect::<Vec<_>>()
        .join(":")
}

fn fingerprint_matches(a: &str, b: &str) -> bool {
    a.eq_ignore_ascii_case(b)
}

/// DTLS sees the selected ICE path through this pipe.
struct PipeConn {
    rx: tokio::sync::Mutex<mpsc::UnboundedReceiver<Vec<u8>>>,
    tx: mpsc::UnboundedSender<Vec<u8>>,
}

#[async_trait::async_trait]
impl webrtc_util::Conn for PipeConn {
    async fn connect(&self, _addr: SocketAddr) -> webrtc_util::Result<()> {
        Ok(())
    }
    async fn recv(&self, buf: &mut [u8]) -> webrtc_util::Result<usize> {
        let mut rx = self.rx.lock().await;
        match rx.recv().await {
            Some(p) => {
                let n = p.len().min(buf.len());
                buf[..n].copy_from_slice(&p[..n]);
                Ok(n)
            }
            None => Err(webrtc_util::Error::ErrClosedListener),
        }
    }
    async fn recv_from(&self, buf: &mut [u8]) -> webrtc_util::Result<(usize, SocketAddr)> {
        let n = self.recv(buf).await?;
        Ok((n, SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0)))
    }
    async fn send(&self, buf: &[u8]) -> webrtc_util::Result<usize> {
        self.tx
            .send(buf.to_vec())
            .map_err(|_| webrtc_util::Error::ErrClosedListener)?;
        Ok(buf.len())
    }
    async fn send_to(&self, buf: &[u8], _target: SocketAddr) -> webrtc_util::Result<usize> {
        self.send(buf).await
    }
    fn local_addr(&self) -> webrtc_util::Result<SocketAddr> {
        Ok(SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0))
    }
    fn remote_addr(&self) -> Option<SocketAddr> {
        None
    }
    async fn close(&self) -> webrtc_util::Result<()> {
        Ok(())
    }
    fn as_any(&self) -> &(dyn std::any::Any + Send + Sync) {
        self
    }
}

type DtlsResult = Result<(Vec<u8>, Arc<webrtc_dtls::conn::DTLSConn>), String>;

async fn dtls_handshake(
    cert: webrtc_dtls::crypto::Certificate,
    remote_fp: String,
    is_client: bool,
    rx: mpsc::UnboundedReceiver<Vec<u8>>,
    tx: mpsc::UnboundedSender<Vec<u8>>,
) -> DtlsResult {
    use webrtc_dtls::config::{ClientAuthType, Config, ExtendedMasterSecretType};
    use webrtc_dtls::extension::extension_use_srtp::SrtpProtectionProfile;
    use webrtc_util::KeyingMaterialExporter;

    let conn = Arc::new(PipeConn {
        rx: tokio::sync::Mutex::new(rx),
        tx,
    });
    let expected = remote_fp.clone();
    let config = Config {
        certificates: vec![cert],
        srtp_protection_profiles: vec![SrtpProtectionProfile::Srtp_Aes128_Cm_Hmac_Sha1_80],
        extended_master_secret: ExtendedMasterSecretType::Request,
        client_auth: ClientAuthType::RequireAnyClientCert,
        insecure_skip_verify: true,
        verify_peer_certificate: Some(Arc::new(move |certs: &[Vec<u8>], _| match certs.first() {
            Some(c) if fingerprint_matches(&fingerprint(c), &expected) => Ok(()),
            _ => Err(webrtc_dtls::Error::ErrVerifyDataMismatch),
        })),
        ..Default::default()
    };
    let dtls = tokio::time::timeout(
        DTLS_TIMEOUT,
        webrtc_dtls::conn::DTLSConn::new(conn, config, is_client, None),
    )
    .await
    .map_err(|_| "dtls timeout".to_string())?
    .map_err(|e| format!("dtls: {e}"))?;
    if dtls.selected_srtpprotection_profile() != SrtpProtectionProfile::Srtp_Aes128_Cm_Hmac_Sha1_80
    {
        return Err("no common SRTP profile".into());
    }
    let state = dtls.connection_state().await;
    let material = state
        .export_keying_material("EXTRACTOR-dtls_srtp", &[], srtp::EXPORT_LEN)
        .await
        .map_err(|e| format!("export: {e}"))?;
    Ok((material, Arc::new(dtls)))
}

fn opus_payload(id: u32) -> PayloadType {
    PayloadType {
        id,
        name: "opus".into(),
        clockrate: 48_000,
        channels: 2,
        feedback: Vec::new(),
        parameters: vec![
            ("minptime".into(), "10".into()),
            ("useinbandfec".into(), "1".into()),
        ],
    }
}

fn find_opus(c: &MediaContent) -> Option<&PayloadType> {
    c.payload_types
        .iter()
        .find(|p| p.name.eq_ignore_ascii_case("opus") && p.clockrate == 48_000)
}

/// Content negotiation (tgcalls `ContentNegotiationContext`, audio only).
#[derive(Debug)]
pub struct Negotiation {
    pub outgoing: bool,
    pub our_ssrc: u32,
    pending_offer: Option<u32>,
    offered: bool,
    /// Payload type the peer accepted for our stream.
    pub send_pt: Option<u8>,
    /// The peer's stream.
    pub recv: Option<(u32, u8)>,
}

impl Negotiation {
    pub fn new(outgoing: bool) -> Self {
        let mut ssrc = 0;
        while ssrc == 0 {
            ssrc = rand::rng().next_u32();
        }
        Self {
            outgoing,
            our_ssrc: ssrc,
            pending_offer: None,
            offered: false,
            send_pt: None,
            recv: None,
        }
    }

    /// Our offer (once; again after a lost race).
    pub fn offer(&mut self) -> Option<Message> {
        if self.offered || self.pending_offer.is_some() {
            return None;
        }
        let mut id = 0;
        while id == 0 {
            id = rand::rng().next_u32();
        }
        self.pending_offer = Some(id);
        Some(Message::NegotiateChannels {
            exchange_id: id,
            contents: vec![MediaContent {
                kind: MediaKind::Audio,
                ssrc: self.our_ssrc,
                ssrc_groups: Vec::new(),
                payload_types: vec![opus_payload(OPUS_PT)],
                rtp_extensions: Vec::new(),
            }],
        })
    }

    /// Handle a `NegotiateChannels` message; returns our answer if it was an
    /// offer.
    pub fn on_message(&mut self, exchange_id: u32, contents: &[MediaContent]) -> Option<Message> {
        if self.pending_offer == Some(exchange_id) {
            // The answer to our offer.
            self.pending_offer = None;
            self.offered = true;
            self.send_pt = contents
                .iter()
                .find(|c| c.kind == MediaKind::Audio && c.ssrc == self.our_ssrc)
                .and_then(find_opus)
                .and_then(|p| u8::try_from(p.id).ok())
                .filter(|p| *p < 128);
            return None;
        }
        if self.pending_offer.is_some() {
            if self.outgoing {
                // Race: the call initiator wins, the peer will answer ours.
                return None;
            }
            self.pending_offer = None;
        }
        let mut answer = Vec::new();
        for c in contents.iter().filter(|c| c.kind == MediaKind::Audio) {
            if let Some(p) = find_opus(c)
                && let Ok(pt) = u8::try_from(p.id)
                && pt < 128
            {
                self.recv = Some((c.ssrc, pt));
                answer.push(MediaContent {
                    kind: MediaKind::Audio,
                    ssrc: c.ssrc,
                    ssrc_groups: c.ssrc_groups.clone(),
                    payload_types: vec![p.clone()],
                    rtp_extensions: Vec::new(),
                });
            }
        }
        Some(Message::NegotiateChannels {
            exchange_id,
            contents: answer,
        })
    }
}

struct Media {
    tx: srtp::Context,
    rx: srtp::Context,
    seq: u16,
    ts: u32,
    _dtls: Arc<webrtc_dtls::conn::DTLSConn>,
}

struct Run {
    cfg: EngineConfig,
    shared: Arc<Shared>,
    events: mpsc::UnboundedSender<EngineEvent>,
    channel: Channel,
    agent: Agent,
    sockets: Vec<Arc<UdpSocket>>,
    neg: Negotiation,
    cert: Option<webrtc_dtls::crypto::Certificate>,
    local_fp: String,
    remote_setup: Option<(String, String)>,
    dtls_in: Option<mpsc::UnboundedSender<Vec<u8>>>,
    early_dtls: Vec<Vec<u8>>,
    dtls_out_tx: mpsc::UnboundedSender<Vec<u8>>,
    dtls_done_tx: Option<oneshot::Sender<DtlsResult>>,
    media: Option<Media>,
    sent_setup: bool,
    last_rtp_rx: Option<Instant>,
    last_rtcp: Option<Instant>,
    state: LinkState,
    lost_since: Option<Instant>,
    last_quality: (Instant, u64, u64, u8),
}

impl Run {
    fn emit(&self, e: EngineEvent) {
        let _ = self.events.send(e);
    }

    fn signal(&mut self, m: &Message) {
        info!(msg = %String::from_utf8_lossy(&m.to_json()).chars().take(160).collect::<String>(), "signal out");
        if let Some(p) = self.channel.send(m, Instant::now()) {
            self.emit(EngineEvent::Signaling(p));
        }
    }

    fn send_setup(&mut self) {
        if self.sent_setup {
            return;
        }
        self.sent_setup = true;
        let setup = if self.cfg.outgoing {
            "actpass"
        } else {
            "passive"
        };
        let m = Message::InitialSetup {
            ufrag: self.agent.ufrag().to_owned(),
            pwd: self.agent.pwd().to_owned(),
            renomination: false,
            fingerprints: vec![DtlsFingerprint {
                hash: "sha-256".into(),
                setup: setup.into(),
                fingerprint: self.local_fp.clone(),
            }],
        };
        self.signal(&m);
        let hosts = self.agent.host_candidates();
        if !hosts.is_empty() {
            self.signal(&Message::Candidates(hosts));
        }
    }

    fn on_signaling(&mut self, data: &[u8]) {
        let (msgs, reply) = self.channel.receive(data, Instant::now());
        if let Some(r) = reply {
            self.emit(EngineEvent::Signaling(r));
        }
        for m in msgs {
            match m {
                Message::InitialSetup {
                    ufrag,
                    pwd,
                    fingerprints,
                    ..
                } => {
                    info!(setups = ?fingerprints.iter().map(|f| f.setup.clone()).collect::<Vec<_>>(), "initial setup in");
                    let Some(fp) = fingerprints
                        .into_iter()
                        .find(|f| f.hash.eq_ignore_ascii_case("sha-256"))
                    else {
                        self.emit(EngineEvent::Failed(
                            "peer sent no sha-256 fingerprint".into(),
                        ));
                        continue;
                    };
                    if self.remote_setup.is_some() {
                        continue;
                    }
                    self.agent.set_remote_credentials(&ufrag, &pwd);
                    self.remote_setup = Some((fp.fingerprint, fp.setup));
                    if !self.cfg.outgoing {
                        self.send_setup();
                    }
                    self.maybe_start_dtls();
                }
                Message::NegotiateChannels {
                    exchange_id,
                    contents,
                } => {
                    info!(
                        exchange_id,
                        contents = ?contents.iter().map(|c| (c.ssrc, c.payload_types.iter().map(|p| (p.id, p.name.clone())).collect::<Vec<_>>())).collect::<Vec<_>>(),
                        "negotiate in"
                    );
                    if let Some(answer) = self.neg.on_message(exchange_id, &contents) {
                        self.signal(&answer);
                    }
                    if let Some(offer) = self.neg.offer() {
                        self.signal(&offer);
                    }
                    info!(send_pt = ?self.neg.send_pt, recv = ?self.neg.recv, our_ssrc = self.neg.our_ssrc, "negotiation state");
                }
                Message::Candidates(list) => {
                    for c in list {
                        self.agent.add_remote_candidate(&c);
                    }
                }
                Message::MediaState { .. } => {}
            }
        }
    }

    fn is_dtls_client(&self) -> bool {
        match self.remote_setup.as_ref().map(|(_, s)| s.as_str()) {
            Some("active") => false,
            Some("passive") => true,
            _ => self.cfg.outgoing,
        }
    }

    fn maybe_start_dtls(&mut self) {
        if self.dtls_in.is_some() || !self.agent.is_connected() {
            return;
        }
        let Some((fp, _)) = self.remote_setup.clone() else {
            return;
        };
        let Some(cert) = self.cert.take() else {
            return;
        };
        let Some(done) = self.dtls_done_tx.take() else {
            return;
        };
        let (in_tx, in_rx) = mpsc::unbounded_channel();
        for p in self.early_dtls.drain(..) {
            let _ = in_tx.send(p);
        }
        self.dtls_in = Some(in_tx);
        let is_client = self.is_dtls_client();
        let out = self.dtls_out_tx.clone();
        debug!(is_client, "starting dtls");
        tokio::spawn(async move {
            let r = dtls_handshake(cert, fp, is_client, in_rx, out).await;
            let _ = done.send(r);
        });
    }

    fn on_datagram(&mut self, socket: usize, from: SocketAddr, data: &[u8]) {
        let now = Instant::now();
        let Some(payload) = self.agent.handle(socket, from, data, now) else {
            return;
        };
        match payload.first() {
            Some(20..=63) => match &self.dtls_in {
                Some(tx) => {
                    let _ = tx.send(payload);
                }
                None if self.early_dtls.len() < MAX_EARLY_DTLS => self.early_dtls.push(payload),
                None => {}
            },
            Some(128..=191) => self.on_rtp(&payload, now),
            _ => {}
        }
    }

    fn on_rtp(&mut self, packet: &[u8], now: Instant) {
        let Some(media) = self.media.as_mut() else {
            return;
        };
        if rtp::is_rtcp(packet) {
            let n_rtcp = counters::RTCP_IN.fetch_add(1, Relaxed);
            let plain = media.rx.unprotect_rtcp(packet);
            if n_rtcp < 40 && packet.len() >= 8 {
                // Gỡ lỗi (GramMini): tiêu đề RTCP (SSRC người gửi để rõ — kể cả khi giải SRTCP hỏng)
                info!(
                    pt = packet[1],
                    sender_ssrc = u32::from_be_bytes([packet[4], packet[5], packet[6], packet[7]]),
                    len = packet.len(),
                    ok = plain.is_some(),
                    "rtcp in"
                );
            }
            // Gỡ lỗi (GramMini): báo cáo nhận (RR / SR) của bên kia về luồng của mình — bên kia có nhận được tiếng không
            if let Some(p) = &plain {
                let mut i = 0;
                while i + 8 <= p.len() {
                    let (rc, pt) = ((p[i] & 0x1f) as usize, p[i + 1]);
                    let len = (u16::from_be_bytes([p[i + 2], p[i + 3]]) as usize + 1) * 4;
                    // Chỉ SR (200) / RR (201) có khối báo cáo; loại khác (SDES, phản hồi 205/206…) dùng 5 bit đầu cho việc
                    // khác — bỏ qua (gọi thử 9: đọc nhầm phản hồi transport-cc → tràn chỉ số, gm-cli dừng giữa cuộc gọi)
                    let (first, rc) = match pt { 200 => (i + 28, rc), 201 => (i + 8, rc), _ => (0, 0) };
                    if pt == 200 && i + 28 <= p.len() {
                        // SR: số gói / byte bên kia đã gửi — bên kia có thật sự phát tiếng không
                        let ssrc = u32::from_be_bytes([p[i + 4], p[i + 5], p[i + 6], p[i + 7]]);
                        let packets = u32::from_be_bytes([p[i + 20], p[i + 21], p[i + 22], p[i + 23]]);
                        let octets = u32::from_be_bytes([p[i + 24], p[i + 25], p[i + 26], p[i + 27]]);
                        info!(ssrc, packets, octets, "rtcp sender report from peer");
                        counters::PEER_SENT.store(u64::from(packets), Relaxed);
                    }
                    for k in 0..rc {
                        let b = first.saturating_add(k * 24);
                        if b + 24 > p.len().min(i + len) {
                            break;
                        }
                        let ssrc = u32::from_be_bytes([p[b], p[b + 1], p[b + 2], p[b + 3]]);
                        let lost = u32::from_be_bytes([0, p[b + 5], p[b + 6], p[b + 7]]);
                        let high = u32::from_be_bytes([p[b + 8], p[b + 9], p[b + 10], p[b + 11]]);
                        info!(ssrc, ours = ssrc == self.neg.our_ssrc, fraction_lost = p[b + 4], lost, highest_seq = high, "rtcp report from peer");
                    }
                    if len == 0 {
                        break;
                    }
                    i += len;
                }
                counters::RTCP_OK.fetch_add(1, Relaxed);
            }
            if plain.is_some() {
                self.last_rtp_rx = Some(now);
            }
            return;
        }
        counters::RTP_IN.fetch_add(1, Relaxed);
        let Some(plain) = media.rx.unprotect_rtp(packet) else {
            if counters::SRTP_FAIL.fetch_add(1, Relaxed) < 3 {
                warn!(len = packet.len(), "srtp unprotect failed");
            }
            return;
        };
        let Some((h, range)) = rtp::parse(&plain) else {
            return;
        };
        if let Some((ssrc, pt)) = self.neg.recv
            && (h.ssrc != ssrc || h.payload_type != pt)
        {
            if counters::FILTERED.fetch_add(1, Relaxed) < 3 {
                warn!(got_ssrc = h.ssrc, got_pt = h.payload_type, want_ssrc = ssrc, want_pt = pt, "rtp filtered");
            }
            return;
        }
        counters::RTP_OK.fetch_add(1, Relaxed);
        self.last_rtp_rx = Some(now);
        if let Ok(mut j) = self.shared.jitter.lock() {
            j.push(h.seq, plain[range].to_vec());
        }
    }

    fn on_frame(&mut self, opus: Vec<u8>) {
        let Some(pt) = self.neg.send_pt else {
            counters::NO_PT.fetch_add(1, Relaxed);
            return;
        };
        let ssrc = self.neg.our_ssrc;
        let Some(media) = self.media.as_mut() else {
            return;
        };
        let h = rtp::Header {
            marker: false,
            payload_type: pt,
            seq: media.seq,
            timestamp: media.ts,
            ssrc,
        };
        media.seq = media.seq.wrapping_add(1);
        media.ts = media.ts.wrapping_add(960);
        if let Some(p) = media.tx.protect_rtp(&h.packet(&opus)) {
            counters::SENT.fetch_add(1, Relaxed);
            self.agent.send(p);
        }
    }

    fn on_dtls_done(&mut self, r: DtlsResult) -> Result<(), String> {
        let (material, dtls) = r?;
        let is_client = self.is_dtls_client();
        let (tx, rx) = srtp::Context::pair_from_export(&material, is_client)
            .ok_or_else(|| "bad keying material".to_string())?;
        let mut seq = [0u8; 2];
        rand::rng().fill_bytes(&mut seq);
        self.media = Some(Media {
            tx,
            rx,
            seq: u16::from_be_bytes(seq) & 0x7fff,
            ts: rand::rng().next_u32(),
            _dtls: dtls,
        });
        info!(
            route = self.agent.route().unwrap_or("?"),
            "call media connected"
        );
        self.set_state(LinkState::Connected {
            relay: self.agent.route() == Some("relay"),
        });
        Ok(())
    }

    fn set_state(&mut self, s: LinkState) {
        if self.state != s {
            self.state = s;
            self.emit(EngineEvent::State(s));
        }
    }

    fn flush(&mut self) {
        while let Some(t) = self.agent.poll_transmit() {
            if let Some(s) = self.sockets.get(t.socket) {
                let _ = s.try_send_to(&t.data, t.dest);
            }
        }
    }

    fn tick(&mut self, started: Instant) -> Result<(), String> {
        let now = Instant::now();
        self.agent.tick(now);
        if let Some(p) = self.channel.service(now) {
            self.emit(EngineEvent::Signaling(p));
        }
        while let Some(ev) = self.agent.poll_event() {
            match ev {
                ice::Event::Candidate(c) => self.signal(&Message::Candidates(vec![c])),
                ice::Event::Connected => {
                    self.lost_since = None;
                    if self.media.is_some() {
                        self.set_state(LinkState::Connected {
                            relay: self.agent.route() == Some("relay"),
                        });
                    }
                    self.maybe_start_dtls();
                }
                ice::Event::Disconnected => {
                    self.lost_since = Some(now);
                    if self.media.is_some() {
                        self.set_state(LinkState::Reconnecting);
                    }
                }
            }
        }
        if self.media.is_none() && now >= started + self.cfg.connect_timeout {
            return Err("connection timeout".into());
        }
        if let Some(t) = self.lost_since
            && now >= t + self.cfg.packet_timeout
        {
            return Err("connection lost".into());
        }
        if self.media.is_some() {
            if self.last_rtcp.is_none_or(|t| now >= t + RTCP_EVERY) {
                self.last_rtcp = Some(now);
                let rr = rtp::empty_receiver_report(self.neg.our_ssrc);
                if let Some(p) = self.media.as_mut().and_then(|m| m.tx.protect_rtcp(&rr)) {
                    self.agent.send(p);
                }
            }
            self.update_quality(now);
        }
        Ok(())
    }

    fn update_quality(&mut self, now: Instant) {
        let (t, rx0, lost0, last) = self.last_quality;
        if now < t + Duration::from_secs(1) {
            return;
        }
        let (rx, lost) = self
            .shared
            .jitter
            .lock()
            .map(|j| (j.stats.received, j.stats.lost))
            .unwrap_or((0, 0));
        let (drx, dlost) = (rx.saturating_sub(rx0), lost.saturating_sub(lost0));
        let silent = self
            .last_rtp_rx
            .is_none_or(|t| now >= t + Duration::from_secs(2));
        let bars = if silent || !self.agent.is_connected() {
            0
        } else {
            let loss = dlost as f32 / (drx + dlost).max(1) as f32;
            match loss {
                l if l < 0.02 => 4,
                l if l < 0.05 => 3,
                l if l < 0.12 => 2,
                _ => 1,
            }
        };
        self.last_quality = (now, rx, lost, bars);
        if bars != last {
            self.emit(EngineEvent::Quality(bars));
        }
    }
}

async fn run(
    cfg: EngineConfig,
    shared: Arc<Shared>,
    mut frames: mpsc::Receiver<Vec<u8>>,
    mut cmd: mpsc::UnboundedReceiver<Command>,
    events: mpsc::UnboundedSender<EngineEvent>,
) -> Result<(), String> {
    let (sockets, hosts) = bind_sockets(&cfg).await?;
    let cert = webrtc_dtls::crypto::Certificate::generate_self_signed(vec!["ferrogram".to_owned()])
        .map_err(|e| format!("certificate: {e}"))?;
    let local_fp = cert
        .certificate
        .first()
        .map(|c| fingerprint(c.as_ref()))
        .ok_or("certificate")?;
    let agent = Agent::new(
        cfg.outgoing,
        hosts,
        cfg.reflectors.clone(),
        cfg.standalone_reflectors,
    );
    let (net_tx, mut net_rx) = mpsc::channel::<(usize, SocketAddr, Vec<u8>)>(SOCKET_QUEUE);
    let mut readers = Vec::new();
    for (i, s) in sockets.iter().enumerate() {
        let s = Arc::clone(s);
        let tx = net_tx.clone();
        readers.push(tokio::spawn(async move {
            let mut buf = vec![0u8; 2048];
            loop {
                match s.recv_from(&mut buf).await {
                    Ok((n, from)) => {
                        if tx.try_send((i, from, buf[..n].to_vec())).is_err() && tx.is_closed() {
                            return;
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::ConnectionRefused => {}
                    Err(_) => return,
                }
            }
        }));
    }
    let (dtls_out_tx, mut dtls_out_rx) = mpsc::unbounded_channel();
    let (dtls_done_tx, mut dtls_done_rx) = oneshot::channel();
    let outgoing = cfg.outgoing;
    let key = cfg.key.clone();
    let mut r = Run {
        neg: Negotiation::new(outgoing),
        channel: Channel::new(key, outgoing),
        cfg,
        shared,
        events,
        agent,
        sockets,
        cert: Some(cert),
        local_fp,
        remote_setup: None,
        dtls_in: None,
        early_dtls: Vec::new(),
        dtls_out_tx,
        dtls_done_tx: Some(dtls_done_tx),
        media: None,
        sent_setup: false,
        last_rtp_rx: None,
        last_rtcp: None,
        state: LinkState::Connecting,
        lost_since: None,
        last_quality: (Instant::now(), 0, 0, 255),
    };
    r.emit(EngineEvent::State(LinkState::Connecting));
    if outgoing {
        r.send_setup();
        if let Some(offer) = r.neg.offer() {
            r.signal(&offer);
        }
    }
    let started = Instant::now();
    let mut ticker = tokio::time::interval(TICK);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut dtls_pending = true;
    let result = loop {
        tokio::select! {
            c = cmd.recv() => match c {
                Some(Command::Signaling(d)) => r.on_signaling(&d),
                Some(Command::Stop) | None => break Ok(()),
            },
            Some((i, from, d)) = net_rx.recv() => r.on_datagram(i, from, &d),
            Some(f) = frames.recv() => r.on_frame(f),
            Some(p) = dtls_out_rx.recv() => { r.agent.send(p); }
            d = &mut dtls_done_rx, if dtls_pending => {
                dtls_pending = false;
                match d {
                    Ok(res) => if let Err(e) = r.on_dtls_done(res) { break Err(e) },
                    Err(_) => break Err("dtls task ended".into()),
                }
            }
            _ = ticker.tick() => if let Err(e) = r.tick(started) { break Err(e) },
        }
        r.flush();
    };
    for h in readers {
        h.abort();
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn opus_content(ssrc: u32, pt: u32) -> MediaContent {
        MediaContent {
            kind: MediaKind::Audio,
            ssrc,
            ssrc_groups: Vec::new(),
            payload_types: vec![opus_payload(pt)],
            rtp_extensions: Vec::new(),
        }
    }

    #[test]
    fn negotiation_offer_answer() {
        let mut caller = Negotiation::new(true);
        let mut callee = Negotiation::new(false);
        let Some(Message::NegotiateChannels {
            exchange_id,
            contents,
        }) = caller.offer()
        else {
            panic!()
        };
        assert!(caller.offer().is_none(), "one offer at a time");
        let Some(Message::NegotiateChannels {
            exchange_id: ax,
            contents: ac,
        }) = callee.on_message(exchange_id, &contents)
        else {
            panic!()
        };
        assert_eq!(callee.recv, Some((caller.our_ssrc, 111)));
        assert!(caller.on_message(ax, &ac).is_none());
        assert_eq!(caller.send_pt, Some(111));
        // Then the callee offers its stream.
        let Some(Message::NegotiateChannels {
            exchange_id: e2,
            contents: c2,
        }) = callee.offer()
        else {
            panic!()
        };
        let Some(Message::NegotiateChannels {
            exchange_id: a2,
            contents: ac2,
        }) = caller.on_message(e2, &c2)
        else {
            panic!()
        };
        callee.on_message(a2, &ac2);
        assert_eq!(callee.send_pt, Some(111));
        assert_eq!(caller.recv, Some((callee.our_ssrc, 111)));
    }

    #[test]
    fn negotiation_race_initiator_wins() {
        let mut caller = Negotiation::new(true);
        let mut callee = Negotiation::new(false);
        let _ = caller.offer();
        let _ = callee.offer();
        // Caller ignores the callee's offer while its own is pending.
        assert!(caller.on_message(42, &[opus_content(5, 120)]).is_none());
        // Callee drops its own and answers.
        assert!(callee.on_message(43, &[opus_content(6, 111)]).is_some());
        assert!(callee.offer().is_some(), "re-offers after losing");
    }

    #[test]
    fn negotiation_ignores_unusable_contents() {
        let mut n = Negotiation::new(false);
        let mut video = opus_content(1, 96);
        video.kind = MediaKind::Video;
        let mut g722 = opus_content(2, 9);
        g722.payload_types[0].name = "G722".into();
        let Some(Message::NegotiateChannels { contents, .. }) =
            n.on_message(9, &[video, g722, opus_content(3, 200)])
        else {
            panic!()
        };
        assert!(contents.is_empty());
        assert_eq!(n.recv, None);
    }

    #[test]
    fn fingerprint_format() {
        let fp = fingerprint(b"abc");
        assert_eq!(fp.len(), 32 * 3 - 1);
        assert!(fp.starts_with("BA:78:16:BF"));
        assert!(fingerprint_matches(&fp, &fp.to_lowercase()));
    }
}
