//! Gọi thoại thử (D38) — engine tgcalls V2 (`gm_call::tg`): báo hiệu qua phone.sendSignalingData, ICE + máy chủ chuyển tiếp,
//! DTLS-SRTP, Opus. Âm thanh thử: phát tiếng bíp (660 Hz, 0,25 giây bật / tắt), ghi tiếng nhận được ra `<thư mục>/recv.wav`.
//!
//! - `gm-cli call <tên> [giây giữ máy] [thư mục ghi]` — gọi một người trong danh sách chat, chờ nghe, trao khoá DH (bên gọi).
//! - `gm-cli answer [giây chờ] [giây giữ máy] [thư mục ghi]` — chờ cuộc gọi đến, nghe máy (bên nghe).
//!
//! Giữ máy [giây] (mặc định 30) kể từ lúc thông thì gác. Thư mục ghi (tuỳ chọn): khoá chung + g_a + gói báo hiệu của bên kia
//! (để gỡ lỗi bằng `calldump`) + recv.wav + opus.bin (gói Opus nhận, giải lại bằng `opusdump`).

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use gm_call::tg::{self, audio, engine};
use grammers_client::peer::Peer;
use grammers_client::tl;
use grammers_session::updates::UpdatesLike;
use tokio::sync::mpsc::Receiver;

use super::Conn;

/// Giao thức đề nghị: tgcalls V2 (9.0.0, 8.0.0) — máy chủ chọn bản chung với bên kia. min / max layer cố định 65 / 92.
fn protocol() -> tl::enums::PhoneCallProtocol {
    tl::enums::PhoneCallProtocol::Protocol(tl::types::PhoneCallProtocol {
        udp_p2p: true,
        udp_reflector: true,
        min_layer: 65,
        max_layer: 92,
        library_versions: vec!["9.0.0".into(), "8.0.0".into()],
    })
}

/// Các cập nhật trong một gói thô. Cập nhật cuộc gọi đọc thẳng ở đây, không qua bộ xử lý thứ tự (MessageBox) của grammers:
/// phiên lệch `seq` → nó coi là hổng, bỏ gói đang tới để lấy bù bằng getDifference — mà cập nhật cuộc gọi không có trong phần lấy
/// bù → mất «bên kia đã nghe» (lần gọi thử đầu 21/11/2026: app iOS đứng ở «Đang kết nối», không emoji).
fn raw_updates(u: UpdatesLike) -> Vec<tl::enums::Update> {
    match u {
        UpdatesLike::Updates(tl::enums::Updates::Updates(x)) => x.updates,
        UpdatesLike::Updates(tl::enums::Updates::Combined(x)) => x.updates,
        UpdatesLike::Updates(tl::enums::Updates::UpdateShort(x)) => vec![x.update],
        _ => Vec::new(),
    }
}

fn versions(p: &tl::enums::PhoneCallProtocol) -> String {
    let tl::enums::PhoneCallProtocol::Protocol(p) = p;
    p.library_versions.join(", ")
}

fn now_s() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() % 1000).unwrap_or(0)
}

/// Khung tiếng thử thứ `n` (20 ms): bíp 660 Hz 0,25 giây rồi lặng 0,25 giây.
fn beep(n: u64, phase: &mut f32) -> Vec<i16> {
    let on = (n / 12) % 2 == 0;
    let step = 2.0 * std::f32::consts::PI * 660.0 / audio::RATE as f32;
    (0..audio::FRAME)
        .map(|_| {
            *phase = (*phase + step) % (2.0 * std::f32::consts::PI);
            if on { (phase.sin() * 9000.0) as i16 } else { 0 }
        })
        .collect()
}

/// WAV PCM 16 bit đơn kênh.
pub fn wav(pcm: &[i16], rate: u32) -> Vec<u8> {
    let data = pcm.len() as u32 * 2;
    let mut v = Vec::with_capacity(44 + data as usize);
    v.extend_from_slice(b"RIFF");
    v.extend_from_slice(&(36 + data).to_le_bytes());
    v.extend_from_slice(b"WAVEfmt ");
    v.extend_from_slice(&16u32.to_le_bytes());
    v.extend_from_slice(&1u16.to_le_bytes());
    v.extend_from_slice(&1u16.to_le_bytes());
    v.extend_from_slice(&rate.to_le_bytes());
    v.extend_from_slice(&(rate * 2).to_le_bytes());
    v.extend_from_slice(&2u16.to_le_bytes());
    v.extend_from_slice(&16u16.to_le_bytes());
    v.extend_from_slice(b"data");
    v.extend_from_slice(&data.to_le_bytes());
    for s in pcm {
        v.extend_from_slice(&s.to_le_bytes());
    }
    v
}

/// Nhật ký của engine (ICE / DTLS / SRTP): GM_TRACE=debug (hoặc info, hoặc «info,ice=debug») — mặc định chỉ cảnh báo.
fn init_tracing() {
    let filter = std::env::var("GM_TRACE").unwrap_or_else(|_| "warn".into());
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::new(format!("warn,gm_call={filter}")))
        .with_target(false)
        .with_ansi(false)
        .try_init();
}

/// Một cuộc gọi đang có: id + access_hash.
#[derive(Clone, Copy)]
struct CallRef {
    id: i64,
    hash: i64,
}

impl CallRef {
    fn input(self) -> tl::enums::InputPhoneCall {
        tl::enums::InputPhoneCall::Call(tl::types::InputPhoneCall { id: self.id, access_hash: self.hash })
    }
}

async fn discard(c: &Conn, call: CallRef, duration: i32) -> Result<(), String> {
    c.client
        .invoke(&tl::functions::phone::DiscardCall {
            video: false,
            peer: call.input(),
            duration,
            reason: tl::enums::PhoneCallDiscardReason::Hangup,
            connection_id: 0,
        })
        .await
        .map(drop)
        .map_err(|e| format!("discardCall: {e}"))
}

/// Cuộc gọi đã trao khoá xong, sẵn sàng chạy engine.
struct Ready {
    call: CallRef,
    key: [u8; 256],
    /// g_a của BÊN GỌI (emoji khoá tính từ nó, ở cả hai vai).
    g_a: Vec<u8>,
    pc: tl::types::PhoneCall,
    outgoing: bool,
}

pub async fn call(c: &mut Conn, who: &str, hold: u64, dump: Option<&str>) -> Result<(), String> {
    c.need_login().await?;
    init_tracing();
    // Người trong danh sách chat có tên chứa `who` (không phân biệt hoa thường)
    let want = who.to_lowercase();
    let mut it = c.client.iter_dialogs();
    let mut target = None;
    while let Some(d) = it.next().await.map_err(|e| e.to_string())? {
        if let Peer::User(u) = d.peer() {
            let name = u.full_name();
            if let (true, tl::enums::User::User(raw)) = (name.to_lowercase().contains(&want), &u.raw) {
                target = Some((raw.id, raw.access_hash.unwrap_or(0), name));
                break;
            }
        }
    }
    let (user_id, access_hash, name) = target.ok_or(format!("không thấy người dùng «{who}» trong danh sách chat"))?;
    let mut rx = c.updates.take().ok_or("đã nghe rồi")?;
    if let Some(d) = dump {
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }

    let (dh, random) = dh_config(c).await?;
    let kp = gm_call::KeyPair::new(&dh, &random)?;
    let random_id = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.subsec_nanos() as i32).unwrap_or(1);
    let res = c
        .client
        .invoke(&tl::functions::phone::RequestCall {
            video: false,
            user_id: tl::enums::InputUser::User(tl::types::InputUser { user_id, access_hash }),
            random_id,
            g_a_hash: kp.g_a_hash().to_vec(),
            protocol: protocol(),
        })
        .await
        .map_err(|e| format!("requestCall: {e}"))?;
    let tl::enums::phone::PhoneCall::Call(res) = res;
    let call = match &res.phone_call {
        tl::enums::PhoneCall::Waiting(w) => CallRef { id: w.id, hash: w.access_hash },
        other => return Err(format!("requestCall trả về lạ: {other:?}")),
    };
    println!("[{}] Đang gọi {name} (cuộc gọi {}) — nghe máy trên app Telegram của bên kia…", now_s(), call.id);

    // Chờ bên kia nghe máy (phoneCallAccepted + g_b) → phone.confirmCall (g_a) → phoneCall
    let mut early_sig = Vec::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    let mut rang = false;
    let ready = 'wait: loop {
        tokio::select! {
            _ = tokio::time::sleep_until(deadline) => {
                println!("[{}] Không ai nghe sau 60 giây — gác.", now_s());
                discard(c, call, 0).await?;
                return Ok(());
            }
            u = rx.recv() => {
                let Some(u) = u else { return Err("kết nối đóng".into()) };
                for raw in raw_updates(u) {
                    match raw {
                        tl::enums::Update::PhoneCall(u) => match u.phone_call {
                            tl::enums::PhoneCall::Waiting(w) if w.id == call.id && w.receive_date.is_some() && !rang => {
                                rang = true;
                                println!("[{}] Máy bên kia đang đổ chuông…", now_s());
                            }
                            tl::enums::PhoneCall::Accepted(a) if a.id == call.id => {
                                println!("[{}] Bên kia đã nghe (giao thức: {}) — trao khoá…", now_s(), versions(&a.protocol));
                                let key = kp.shared_key(&dh, &a.g_b)?;
                                let conf = c
                                    .client
                                    .invoke(&tl::functions::phone::ConfirmCall {
                                        peer: call.input(),
                                        g_a: kp.g_a.to_vec(),
                                        key_fingerprint: gm_call::key_fingerprint(&key),
                                        protocol: protocol(),
                                    })
                                    .await
                                    .map_err(|e| format!("confirmCall: {e}"))?;
                                let tl::enums::phone::PhoneCall::Call(conf) = conf;
                                let tl::enums::PhoneCall::Call(pc) = conf.phone_call else {
                                    return Err(format!("confirmCall trả về lạ: {:?}", conf.phone_call));
                                };
                                break 'wait Ready { call, key, g_a: kp.g_a.to_vec(), pc, outgoing: true };
                            }
                            tl::enums::PhoneCall::Discarded(d) if d.id == call.id => {
                                println!("[{}] Bên kia từ chối / kết thúc (lý do {:?})", now_s(), d.reason);
                                return Ok(());
                            }
                            _ => {}
                        },
                        tl::enums::Update::PhoneCallSignalingData(s) if s.phone_call_id == call.id => early_sig.push(s.data),
                        _ => {}
                    }
                }
            }
        }
    };
    media(c, &mut rx, ready, early_sig, hold, dump).await
}

pub async fn answer(c: &mut Conn, wait: u64, hold: u64, dump: Option<&str>) -> Result<(), String> {
    c.need_login().await?;
    init_tracing();
    let mut rx = c.updates.take().ok_or("đã nghe rồi")?;
    if let Some(d) = dump {
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }
    // Máy chủ chỉ đẩy cập nhật (kể cả updatePhoneCall «có cuộc gọi đến») cho phiên đã hỏi trạng thái cập nhật; báo đang
    // trực tuyến để được đổ chuông như một máy đang mở app
    c.client.invoke(&tl::functions::updates::GetState {}).await.map_err(|e| format!("updates.getState: {e}"))?;
    let _ = c.client.invoke(&tl::functions::account::UpdateStatus { offline: false }).await;
    println!("[{}] Chờ cuộc gọi đến trong {wait} giây — gọi tài khoản này từ app Telegram…", now_s());

    // Chờ phoneCallRequested (bên gọi gửi g_a_hash)
    let deadline = tokio::time::Instant::now() + Duration::from_secs(wait);
    // Gỡ lỗi: đếm gói cập nhật nhận trong lúc chờ (0 = máy chủ không đẩy gì cho phiên này)
    let (mut n_packets, mut n_updates) = (0u32, 0u32);
    let req = 'wait: loop {
        tokio::select! {
            _ = tokio::time::sleep_until(deadline) => {
                return Err(format!("không có cuộc gọi đến sau {wait} giây ({n_packets} gói cập nhật, {n_updates} cập nhật)"))
            }
            u = rx.recv() => {
                let Some(u) = u else { return Err("kết nối đóng".into()) };
                n_packets += 1;
                for raw in raw_updates(u) {
                    n_updates += 1;
                    if let tl::enums::Update::PhoneCall(u) = raw {
                        match u.phone_call {
                            tl::enums::PhoneCall::Requested(r) => break 'wait r,
                            other => println!("[{}] cập nhật cuộc gọi khác: {other:?}", now_s()),
                        }
                    }
                }
            }
        }
    };
    let call = CallRef { id: req.id, hash: req.access_hash };
    println!(
        "[{}] Có cuộc gọi đến{} từ người dùng {} (cuộc gọi {}, giao thức: {}) — báo đổ chuông, nghe máy…",
        now_s(),
        if req.video { " (video — nghe như cuộc gọi thoại)" } else { "" },
        req.admin_id,
        call.id,
        versions(&req.protocol)
    );
    c.client
        .invoke(&tl::functions::phone::ReceivedCall { peer: call.input() })
        .await
        .map_err(|e| format!("receivedCall: {e}"))?;
    let (dh, random) = dh_config(c).await?;
    let kp = gm_call::KeyPair::new(&dh, &random)?;
    c.client
        .invoke(&tl::functions::phone::AcceptCall { peer: call.input(), g_b: kp.g_a.to_vec(), protocol: protocol() })
        .await
        .map_err(|e| format!("acceptCall: {e}"))?;

    // Chờ bên gọi xác nhận: phoneCall với g_a (phải khớp g_a_hash) + key_fingerprint
    let mut early_sig = Vec::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    let pc = 'conf: loop {
        tokio::select! {
            _ = tokio::time::sleep_until(deadline) => {
                println!("[{}] Bên gọi không xác nhận sau 30 giây — gác.", now_s());
                discard(c, call, 0).await?;
                return Ok(());
            }
            u = rx.recv() => {
                let Some(u) = u else { return Err("kết nối đóng".into()) };
                for raw in raw_updates(u) {
                    match raw {
                        tl::enums::Update::PhoneCall(u) => match u.phone_call {
                            tl::enums::PhoneCall::Call(pc) if pc.id == call.id => break 'conf pc,
                            tl::enums::PhoneCall::Discarded(d) if d.id == call.id => {
                                println!("[{}] Bên gọi đã huỷ (lý do {:?})", now_s(), d.reason);
                                return Ok(());
                            }
                            _ => {}
                        },
                        tl::enums::Update::PhoneCallSignalingData(s) if s.phone_call_id == call.id => early_sig.push(s.data),
                        _ => {}
                    }
                }
            }
        }
    };
    if !gm_call::g_a_matches_hash(&pc.g_a_or_b, &req.g_a_hash) {
        discard(c, call, 0).await?;
        return Err("g_a của bên gọi không khớp g_a_hash — huỷ cuộc gọi".into());
    }
    let key = kp.shared_key(&dh, &pc.g_a_or_b)?;
    if gm_call::key_fingerprint(&key) != pc.key_fingerprint {
        discard(c, call, 0).await?;
        return Err("key_fingerprint không khớp — huỷ cuộc gọi".into());
    }
    println!("[{}] Bên gọi đã xác nhận khoá (giao thức: {})", now_s(), versions(&pc.protocol));
    let g_a = pc.g_a_or_b.clone();
    media(c, &mut rx, Ready { call, key, g_a, pc, outgoing: false }, early_sig, hold, dump).await
}

/// getDhConfig → (p, g đã kiểm, random của máy chủ).
async fn dh_config(c: &Conn) -> Result<(gm_call::DhConfig, Vec<u8>), String> {
    match c
        .client
        .invoke(&tl::functions::messages::GetDhConfig { version: 0, random_length: 256 })
        .await
        .map_err(|e| format!("getDhConfig: {e}"))?
    {
        tl::enums::messages::DhConfig::Config(x) => Ok((gm_call::DhConfig::new(&x.p, x.g)?, x.random)),
        tl::enums::messages::DhConfig::NotModified(_) => Err("getDhConfig: NotModified".into()),
    }
}

/// Phần chung hai vai: in emoji + đường kết nối, chạy engine, chuyển báo hiệu hai chiều, phát bíp / ghi tiếng nhận, gác.
async fn media(
    c: &mut Conn,
    rx: &mut Receiver<UpdatesLike>,
    r: Ready,
    early_sig: Vec<Vec<u8>>,
    hold: u64,
    dump: Option<&str>,
) -> Result<(), String> {
    let Ready { call, key, g_a, pc, outgoing } = r;
    let e = gm_call::emoji_fingerprint(&key, &g_a);
    println!("\n  EMOJI KHOÁ:  {}  {}  {}  {}\n", e[0], e[1], e[2], e[3]);
    let mut refl = Vec::new();
    for cn in &pc.connections {
        match cn {
            tl::enums::PhoneConnection::Connection(x) => {
                println!("  chuyển tiếp {}:{}{} (id {})", x.ip, x.port, if x.tcp { " tcp" } else { "" }, x.id);
                refl.push(tg::Reflector { id: x.id, ip: x.ip.clone(), port: x.port, peer_tag: x.peer_tag.clone(), tcp: x.tcp });
            }
            tl::enums::PhoneConnection::Webrtc(x) => {
                println!("  {} {}:{} (chưa dùng)", if x.turn { "TURN" } else { "STUN" }, x.ip, x.port)
            }
        }
    }
    let custom = match &pc.custom_parameters {
        Some(tl::enums::DataJson::Json(j)) => Some(j.data.clone()),
        None => None,
    };
    if let Some(s) = &custom {
        println!("  custom_parameters: {s}");
    }
    let mut nsig = 0;
    if let Some(d) = dump {
        std::fs::write(format!("{d}/key.bin"), key).map_err(|e| e.to_string())?;
        std::fs::write(format!("{d}/g_a.bin"), &g_a).map_err(|e| e.to_string())?;
        for s in &early_sig {
            nsig += 1;
            std::fs::write(format!("{d}/sig-{nsig:03}.bin"), s).map_err(|e| e.to_string())?;
        }
    }
    let shared = audio::Shared::new();
    let (frame_tx, frame_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(64);
    let ecfg = engine::EngineConfig {
        key: tg::CallKey(key),
        outgoing,
        reflectors: tg::reflectors(&refl),
        standalone_reflectors: tg::custom_flag(custom.as_deref(), "network_standalone_reflectors"),
        // GM_RELAY_ONLY=1: không mở socket host — ép tiếng đi qua máy chủ chuyển tiếp của Telegram (thử đường này)
        p2p: pc.p2p_allowed && std::env::var_os("GM_RELAY_ONLY").is_none(),
        loopback: false,
        connect_timeout: Duration::from_secs(30),
        packet_timeout: Duration::from_secs(10),
    };
    println!(
        "[{}] Chạy engine ({}): {} máy chủ chuyển tiếp, p2p {}",
        now_s(),
        if outgoing { "bên gọi" } else { "bên nghe" },
        ecfg.reflectors.len(),
        ecfg.p2p
    );
    let h = engine::start(ecfg, shared.clone(), frame_rx);
    let mut events = h.take_events();
    nsig = nsig.max(early_sig.len());
    for s in early_sig {
        h.signaling(s);
    }

    let mut enc = audio::OpusEncoder::new().ok_or("không tạo được bộ mã Opus")?;
    let mut dec = audio::OpusDecoder::new().ok_or("không tạo được bộ giải Opus")?;
    let (mut recv_pcm, mut sent, mut phase) = (Vec::<i16>::new(), 0u64, 0f32);
    // Tiếng nhận đã giải mà chưa «phát» (khung bên kia dài 60 ms, nhịp phát 20 ms)
    let mut recv_q: std::collections::VecDeque<i16> = Default::default();
    let mut opus_dump: Vec<u8> = Vec::new();
    let mut tick = tokio::time::interval(Duration::from_millis(20));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut deadline = tokio::time::Instant::now() + Duration::from_secs(45);
    let mut end_reason = "Không thông tiếng sau 45 giây — gác.".to_string();
    let mut connected_at = None::<tokio::time::Instant>;
    'run: loop {
        tokio::select! {
            _ = tokio::time::sleep_until(deadline) => {
                println!("[{}] {end_reason}", now_s());
                break 'run;
            }
            u = rx.recv() => {
                let Some(u) = u else { return Err("kết nối đóng".into()) };
                for raw in raw_updates(u) {
                    match raw {
                        tl::enums::Update::PhoneCall(u) => {
                            if let tl::enums::PhoneCall::Discarded(d) = u.phone_call {
                                if d.id != call.id {
                                    continue;
                                }
                                println!("[{}] Bên kia kết thúc cuộc gọi (lý do {:?}, {:?} giây)", now_s(), d.reason, d.duration);
                                end_reason.clear();
                                break 'run;
                            }
                        }
                        tl::enums::Update::PhoneCallSignalingData(s) if s.phone_call_id == call.id => {
                            nsig += 1;
                            if let Some(d) = dump {
                                std::fs::write(format!("{d}/sig-{nsig:03}.bin"), &s.data).map_err(|e| e.to_string())?;
                            }
                            h.signaling(s.data);
                        }
                        _ => {}
                    }
                }
            }
            ev = async {
                match events.as_mut() {
                    Some(e) => e.recv().await,
                    None => std::future::pending().await,
                }
            } => {
                match ev {
                    Some(engine::EngineEvent::Signaling(data)) => {
                        c.client
                            .invoke(&tl::functions::phone::SendSignalingData { peer: call.input(), data })
                            .await
                            .map_err(|e| format!("sendSignalingData: {e}"))?;
                    }
                    Some(engine::EngineEvent::State(s)) => {
                        println!("[{}] Trạng thái đường truyền: {s:?}", now_s());
                        if matches!(s, engine::LinkState::Connected { .. }) && connected_at.is_none() {
                            connected_at = Some(tokio::time::Instant::now());
                            println!("[{}] ĐÃ THÔNG — phát tiếng bíp, giữ máy {hold} giây", now_s());
                            deadline = tokio::time::Instant::now() + Duration::from_secs(hold);
                            end_reason = "Hết giờ giữ máy — gác.".into();
                        }
                    }
                    Some(engine::EngineEvent::Quality(q)) => println!("[{}] chất lượng {q}/4 — {}", now_s(), engine::counters::line()),
                    Some(engine::EngineEvent::Failed(e)) => {
                        println!("[{}] Engine dừng: {e}", now_s());
                        break 'run;
                    }
                    None => events = None,
                }
            }
            _ = tick.tick() => {
                // Phát: một khung bíp mỗi 20 ms; thu: lấy một khung khỏi bộ đệm chống rung
                if let Some(p) = enc.encode(&beep(sent, &mut phase)) {
                    let _ = frame_tx.try_send(p);
                    sent += 1;
                }
                while recv_q.len() < audio::FRAME {
                    let Some(f) = shared.jitter.lock().ok().map(|mut j| j.pop()) else { break };
                    let silent = matches!(f, gm_call::tg::jitter::Frame::Silence);
                    if let (gm_call::tg::jitter::Frame::Packet(p), true) = (&f, opus_dump.len() < 4_000_000) {
                        // Gỡ lỗi: lưu gói Opus nhận (u16 độ dài + byte) để giải lại ngoại tuyến (gm-cli opusdump)
                        opus_dump.extend_from_slice(&(p.len() as u16).to_be_bytes());
                        opus_dump.extend_from_slice(p);
                    }
                    recv_q.extend(dec.decode(&f));
                    if silent {
                        break;
                    }
                }
                let n = audio::FRAME.min(recv_q.len());
                recv_pcm.extend(recv_q.drain(..n));
            }
        }
    }
    drop(h);
    let duration = connected_at.map(|t| t.elapsed().as_secs() as i32).unwrap_or(0);
    if !end_reason.is_empty() {
        discard(c, call, duration).await?;
        println!("Đã gác máy.");
    }
    println!("Engine: {}", engine::counters::line());
    let peak = recv_pcm.iter().map(|s| s.unsigned_abs()).max().unwrap_or(0);
    let loud = recv_pcm.chunks(audio::FRAME).filter(|f| f.iter().any(|s| s.unsigned_abs() > 600)).count();
    println!(
        "Âm thanh: gửi {sent} khung; nhận {:.1} giây, {loud} khung có tiếng, đỉnh {peak}; {nsig} gói báo hiệu từ bên kia",
        recv_pcm.len() as f64 / audio::RATE as f64
    );
    println!(
        "Bộ giải: {} gói giải được, {} gói lỗi, {} ô mất (bù), {} ô im lặng (đang đệm)",
        dec.packets, dec.errors, dec.lost, dec.silence
    );
    if let Some(d) = dump {
        std::fs::write(format!("{d}/recv.wav"), wav(&recv_pcm, audio::RATE)).map_err(|e| e.to_string())?;
        std::fs::write(format!("{d}/opus.bin"), &opus_dump).map_err(|e| e.to_string())?;
        println!("Ghi {d}/recv.wav, {d}/opus.bin");
    }
    Ok(())
}

/// Thời gian CPU của tiến trình (giây, user + sys) — đo tải của engine trên máy thật.
fn cpu_seconds() -> Option<f64> {
    #[cfg(unix)]
    {
        let mut u: libc::rusage = unsafe { std::mem::zeroed() };
        if unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut u) } != 0 {
            return None;
        }
        let t = |v: libc::timeval| v.tv_sec as f64 + v.tv_usec as f64 / 1e6;
        Some(t(u.ru_utime) + t(u.ru_stime))
    }
    #[cfg(not(unix))]
    {
        None
    }
}

/// `gm-cli callselftest [giây]` — không cần tài khoản: hai engine (bên gọi + bên nghe) trong cùng tiến trình, nối qua 127.0.0.1,
/// chuyển báo hiệu cho nhau. Mỗi bên phát bíp (660 / 440 Hz) và giải tiếng bên kia → thử đủ ICE, DTLS, SRTP, Opus trên máy
/// (G3: iPhone 5 / iPad iOS 5–6) và đo CPU. CPU in ra là của CẢ HAI bên — một cuộc gọi thật chỉ khoảng một nửa.
pub async fn selftest(secs: u64, complexity: i32, bandwidth: u32, signal: &str) -> Result<(), String> {
    let voice = signal != "tone";
    // «none»: gửi một gói Opus cố định, không mã / giải — đo riêng phần engine (mạng, SRTP, vòng lặp)
    let no_audio = signal == "none";
    init_tracing();
    let mut key = [0u8; 256];
    for (i, b) in key.iter_mut().enumerate() {
        *b = (SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.subsec_nanos()).unwrap_or(7) as usize)
            .wrapping_mul(i + 1)
            .wrapping_add(i * 131) as u8;
    }
    let cfg = |outgoing| engine::EngineConfig {
        key: tg::CallKey(key),
        outgoing,
        reflectors: Vec::new(),
        standalone_reflectors: false,
        p2p: true,
        loopback: true,
        connect_timeout: Duration::from_secs(20),
        packet_timeout: Duration::from_secs(10),
    };
    let wall0 = std::time::Instant::now();
    let cpu0 = cpu_seconds();
    let (sa, sb) = (audio::Shared::new(), audio::Shared::new());
    let (ta, ra) = tokio::sync::mpsc::channel::<Vec<u8>>(64);
    let (tb, rb) = tokio::sync::mpsc::channel::<Vec<u8>>(64);
    let ha = engine::start(cfg(true), sa.clone(), ra);
    let hb = engine::start(cfg(false), sb.clone(), rb);
    let (mut ea, mut eb) = (ha.take_events().ok_or("engine A")?, hb.take_events().ok_or("engine B")?);
    let mut enc = (
        audio::OpusEncoder::with_settings(complexity, bandwidth).ok_or("Opus")?,
        audio::OpusEncoder::with_settings(complexity, bandwidth).ok_or("Opus")?,
    );
    let mut rng = 0x1234_5678u32;
    let mut modes = [0u64; 9];
    let mut dec = (audio::OpusDecoder::new().ok_or("Opus")?, audio::OpusDecoder::new().ok_or("Opus")?);
    let (mut pa, mut pb, mut n) = (0f32, 0f32, 0u64);
    // Tiếng mỗi bên nhận: số khung có tiếng + số lần qua 0 (ước tần số — 660 Hz là của A, 440 Hz là của B)
    let mut got = [(0u64, 0u64, 0u64); 2];
    let mut tick = tokio::time::interval(Duration::from_millis(20));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut connected = [None::<std::time::Instant>; 2];
    let deadline = tokio::time::Instant::now() + Duration::from_secs(secs + 20);
    let mut cpu_connected = None;
    println!(
        "[{}] Tự kiểm: 2 engine qua 127.0.0.1, {secs} giây sau khi thông; Opus độ phức tạp {complexity}, băng thông {bandwidth} Hz, tiếng {}",
        now_s(),
        if no_audio { "không (gói cố định)" } else if voice { "giả giọng nói" } else { "bíp" }
    );
    loop {
        tokio::select! {
            _ = tokio::time::sleep_until(deadline) => break,
            e = ea.recv() => match e {
                Some(engine::EngineEvent::Signaling(d)) => hb.signaling(d),
                Some(engine::EngineEvent::State(s)) => {
                    println!("[{}] A (bên gọi): {s:?} sau {} ms", now_s(), wall0.elapsed().as_millis());
                    if matches!(s, engine::LinkState::Connected { .. }) && connected[0].is_none() {
                        connected[0] = Some(std::time::Instant::now());
                    }
                }
                Some(engine::EngineEvent::Failed(e)) => return Err(format!("A dừng: {e}")),
                Some(_) => {}
                None => return Err("A đóng".into()),
            },
            e = eb.recv() => match e {
                Some(engine::EngineEvent::Signaling(d)) => ha.signaling(d),
                Some(engine::EngineEvent::State(s)) => {
                    println!("[{}] B (bên nghe): {s:?} sau {} ms", now_s(), wall0.elapsed().as_millis());
                    if matches!(s, engine::LinkState::Connected { .. }) && connected[1].is_none() {
                        connected[1] = Some(std::time::Instant::now());
                    }
                }
                Some(engine::EngineEvent::Failed(e)) => return Err(format!("B dừng: {e}")),
                Some(_) => {}
                None => return Err("B đóng".into()),
            },
            _ = tick.tick() => {
                if no_audio {
                    let _ = ta.try_send(vec![0xf8, 0xff, 0xfe]);
                    let _ = tb.try_send(vec![0xf8, 0xff, 0xfe]);
                    n += 1;
                    for shared in [&sa, &sb] {
                        if let Some(f) = shared.jitter.lock().ok().map(|mut j| j.pop()) {
                            if matches!(f, gm_call::tg::jitter::Frame::Packet(_)) {
                                got[0].0 += 1;
                            }
                        }
                    }
                    if let (Some(a), Some(_)) = (connected[0], connected[1]) {
                        if cpu_connected.is_none() {
                            cpu_connected = Some((std::time::Instant::now(), cpu_seconds()));
                        }
                        if a.elapsed() >= Duration::from_secs(secs) {
                            break;
                        }
                    }
                    continue;
                }
                let (fa, fb) = if voice {
                    (fake_voice(n, 660.0, &mut pa, &mut rng), fake_voice(n, 440.0, &mut pb, &mut rng))
                } else {
                    (tone(n, 660.0, &mut pa), tone(n, 440.0, &mut pb))
                };
                if let Some(p) = enc.0.encode(&fa) {
                    // Chế độ Opus đã chọn (TOC config: 0–11 SILK, 12–15 Hybrid, 16–31 CELT)
                    if let Some(t) = p.first() { modes[usize::from(*t >> 3) / 4 + usize::from(*t >> 3 >= 12)] += 1; }
                    let _ = ta.try_send(p);
                }
                if let Some(p) = enc.1.encode(&fb) { let _ = tb.try_send(p); }
                n += 1;
                for (i, (shared, d)) in [(&sb, &mut dec.0), (&sa, &mut dec.1)].into_iter().enumerate() {
                    // i = 0: tiếng B nhận (của A); i = 1: tiếng A nhận (của B)
                    let f = shared.jitter.lock().ok().map(|mut j| j.pop());
                    if let Some(f) = f {
                        let pcm = d.decode(&f);
                        if pcm.iter().any(|s| s.unsigned_abs() > 2000) {
                            got[i].0 += 1;
                            got[i].1 += pcm.windows(2).filter(|w| (w[0] < 0) != (w[1] < 0)).count() as u64;
                            got[i].2 += pcm.len() as u64;
                        }
                    }
                }
                if let (Some(a), Some(_)) = (connected[0], connected[1]) {
                    if cpu_connected.is_none() {
                        cpu_connected = Some((std::time::Instant::now(), cpu_seconds()));
                    }
                    if a.elapsed() >= Duration::from_secs(secs) {
                        break;
                    }
                }
            }
        }
    }
    let (Some(_), Some(_)) = (connected[0], connected[1]) else {
        return Err(format!("không thông — {}", engine::counters::line()));
    };
    let freq = |g: (u64, u64, u64)| if g.2 == 0 { 0.0 } else { g.1 as f64 / 2.0 / (g.2 as f64 / audio::RATE as f64) };
    println!("Engine (cả hai bên): {}", engine::counters::line());
    let silk: u64 = modes[..3].iter().sum();
    println!("Opus của A: SILK {silk} gói, Hybrid {} gói, CELT {} gói", modes[3] + modes[4], modes[5..].iter().sum::<u64>());
    println!("B nhận tiếng A: {} khung có tiếng, ~{:.0} Hz (A phát 660 Hz)", got[0].0, freq(got[0]));
    println!("A nhận tiếng B: {} khung có tiếng, ~{:.0} Hz (B phát 440 Hz)", got[1].0, freq(got[1]));
    if let (Some(c0), Some((t1, Some(c1))), Some(c2)) = (cpu0, cpu_connected, cpu_seconds()) {
        let setup = c1 - c0;
        let talk = (c2 - c1) / t1.elapsed().as_secs_f64() * 100.0;
        println!(
            "CPU: dựng cuộc gọi (khoá DTLS + bắt tay, 2 bên) {setup:.2} giây; lúc nói chuyện {talk:.1}% một nhân cho 2 bên (~{:.1}% mỗi cuộc gọi)",
            talk / 2.0
        );
    }
    drop((ha, hb));
    Ok(())
}

/// Khung 20 ms «giả giọng nói» để đo CPU đúng chế độ thoại của Opus (SILK / Hybrid — app iOS gửi Hybrid): sóng răng cưa
/// (đủ hoạ âm như dây thanh) cao độ `hz` / 4 dao động ±6% theo 5 Hz, lọc thông thấp một cực, thêm nhiễu, ngắt theo nhịp âm
/// tiết 4 Hz. Rẻ để sinh (không tốn CPU như cộng nhiều sin). Âm thuần (bíp) làm Opus chọn CELT — rẻ hơn, không đại diện.
fn fake_voice(n: u64, hz: f32, phase: &mut f32, rng: &mut u32) -> Vec<i16> {
    let mut out = Vec::with_capacity(audio::FRAME);
    let mut lp = 0f32;
    for i in 0..audio::FRAME {
        let t = (n as f32 * audio::FRAME as f32 + i as f32) / audio::RATE as f32;
        let f0 = hz / 4.0 * (1.0 + 0.06 * (2.0 * std::f32::consts::PI * 5.0 * t).sin());
        *phase = (*phase + f0 / audio::RATE as f32) % 1.0;
        let saw = 2.0 * *phase - 1.0;
        *rng ^= *rng << 13;
        *rng ^= *rng >> 17;
        *rng ^= *rng << 5;
        let noise = (*rng as f32 / u32::MAX as f32) * 2.0 - 1.0;
        lp += 0.25 * (saw + 0.15 * noise - lp);
        let env = (2.0 * std::f32::consts::PI * 4.0 * t).sin().max(0.0).sqrt();
        out.push((lp * env * 12000.0) as i16);
    }
    out
}

/// Khung tiếng thử 20 ms tần số `hz`, bật 0,25 giây / tắt 0,25 giây.
fn tone(n: u64, hz: f32, phase: &mut f32) -> Vec<i16> {
    let on = (n / 12) % 2 == 0;
    let step = 2.0 * std::f32::consts::PI * hz / audio::RATE as f32;
    (0..audio::FRAME)
        .map(|_| {
            *phase = (*phase + step) % (2.0 * std::f32::consts::PI);
            if on { (phase.sin() * 9000.0) as i16 } else { 0 }
        })
        .collect()
}

/// `gm-cli opusbench [giây] [độ phức tạp] [băng thông Hz]` — đo riêng CPU bộ mã / bộ giải Opus của cuộc gọi trên máy (tiếng giả
/// giọng nói sinh sẵn, không tính vào thời gian đo). In % một nhân so với thời gian thực của một luồng tiếng.
pub fn opusbench(secs: u64, complexity: i32, bandwidth: u32, peer_dump: Option<&str>) -> Result<(), String> {
    let frames = (secs * 50) as usize;
    let (mut phase, mut rng) = (0f32, 0x2468_ace1u32);
    let pcm: Vec<Vec<i16>> = (0..frames as u64).map(|n| fake_voice(n, 520.0, &mut phase, &mut rng)).collect();
    let mut enc = audio::OpusEncoder::with_settings(complexity, bandwidth).ok_or("Opus")?;
    let (w0, c0) = (std::time::Instant::now(), cpu_seconds());
    let packets: Vec<Vec<u8>> = pcm.iter().filter_map(|f| enc.encode(f)).collect();
    let (w1, c1) = (std::time::Instant::now(), cpu_seconds());
    let mut dec = audio::OpusDecoder::new().ok_or("Opus")?;
    let mut samples = 0usize;
    for p in &packets {
        samples += dec.decode(&gm_call::tg::jitter::Frame::Packet(p.clone())).len();
    }
    let (w2, c2) = (std::time::Instant::now(), cpu_seconds());
    let bytes: usize = packets.iter().map(Vec::len).sum();
    let pct = |a: Option<f64>, b: Option<f64>, w: std::time::Duration| match (a, b) {
        (Some(a), Some(b)) => (b - a) / secs as f64 * 100.0,
        _ => w.as_secs_f64() / secs as f64 * 100.0,
    };
    println!(
        "Opus độ phức tạp {complexity}, băng thông {bandwidth} Hz: {} gói, {:.1} kbps; mã {:.1}% một nhân, giải {:.1}% ({} mẫu)",
        packets.len(),
        bytes as f64 * 8.0 / secs as f64 / 1000.0,
        pct(c0, c1, w1 - w0),
        pct(c1, c2, w2 - w1),
        samples
    );
    // Giải luồng thật của app Telegram (opus.bin do `call` ghi: u16 độ dài + gói) — app gửi Hybrid toàn dải, 60 ms / gói
    if let Some(path) = peer_dump {
        let data = std::fs::read(path).map_err(|e| e.to_string())?;
        let mut pk = Vec::new();
        let mut i = 0;
        while i + 2 <= data.len() {
            let n = u16::from_be_bytes([data[i], data[i + 1]]) as usize;
            let Some(p) = data.get(i + 2..i + 2 + n) else { break };
            pk.push(p.to_vec());
            i += 2 + n;
        }
        let mut dec = audio::OpusDecoder::new().ok_or("Opus")?;
        let (w0, c0) = (std::time::Instant::now(), cpu_seconds());
        let mut samples = 0usize;
        for p in pk.iter().cycle().take(pk.len() * 3) {
            samples += dec.decode(&gm_call::tg::jitter::Frame::Packet(p.clone())).len();
        }
        let dur = samples as f64 / audio::RATE as f64;
        let used = match (c0, cpu_seconds()) {
            (Some(a), Some(b)) => b - a,
            _ => w0.elapsed().as_secs_f64(),
        };
        println!("Giải luồng app ({} gói × 3, {dur:.1} giây tiếng): {:.1}% một nhân", pk.len(), used / dur * 100.0);
    }
    Ok(())
}
