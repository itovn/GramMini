//! Gọi thoại 1-1 (D38, G3): trao khoá DH (bên gọi / bên nghe), engine tgcalls V2 (`gm_call::tg::engine`), cầu âm thanh cho
//! app (`gm_call::tg::io` — app nối AudioUnit VoiceProcessingIO qua `gm_voip_push` / `gm_voip_pull` của gm-ffi). Luồng xử lý
//! như `gm-cli call` / `gm-cli answer` (đã thông với Telegram iOS 18, 21/11/2026).
//!
//! Lệnh: `call.request` {peer} · `call.accept` · `call.hangup` {reason?: "busy"} · `call.mute` {on} · `call.state`.
//! Sự kiện `call.state` {call_id, peer, outgoing, state, emoji?, relay, duration, muted, reason?} — state: requesting (đang gọi)
//! · ringing (máy bên kia đổ chuông) · incoming (có cuộc gọi đến) · exchanging (trao khoá) · connecting · connected ·
//! reconnecting · ended (reason: hangup / busy / missed / disconnect / error / elsewhere — đã nghe trên máy khác).
//!
//! Cập nhật cuộc gọi đọc ở luồng thô (`tap_phone`, trước MessageBox của grammers): MessageBox bỏ cả gói khi lệch `seq` rồi lấy
//! bù bằng getDifference — mà phần lấy bù không có `updatePhoneCall` (lần gọi thử đầu: mất «bên kia đã nghe»).

use super::*;
use gm_call::tg::{self, audio, engine, io as voip};
use grammers_client::tl::{enums, functions, types};

/// tgcalls V2 — máy chủ chọn bản chung với bên kia (app chính thức hiện chọn 8.0.0). Layer cố định 65 / 92.
fn protocol() -> enums::PhoneCallProtocol {
    enums::PhoneCallProtocol::Protocol(types::PhoneCallProtocol {
        udp_p2p: true,
        udp_reflector: true,
        min_layer: 65,
        max_layer: 92,
        library_versions: vec!["9.0.0".into(), "8.0.0".into()],
    })
}

fn call_err(e: impl std::fmt::Display) -> CoreError {
    CoreError::new("CALL", e.to_string())
}

/// Cuộc gọi đang có (một cuộc một lúc).
pub(super) struct Active {
    id: i64,
    hash: i64,
    outgoing: bool,
    /// Người bên kia.
    user: i64,
    state: &'static str,
    dh: Option<Arc<gm_call::DhConfig>>,
    kp: Option<Arc<gm_call::KeyPair>>,
    /// Bên nghe: SHA256(g_a) bên gọi gửi trước — kiểm khi bên gọi lộ g_a.
    g_a_hash: Vec<u8>,
    engine: Option<engine::EngineHandle>,
    io: Option<Arc<voip::VoipIo>>,
    /// Gói báo hiệu đến trước khi engine chạy.
    early: Vec<Vec<u8>>,
    connected_at: Option<Instant>,
    emoji: Option<[&'static str; 4]>,
    relay: bool,
}

impl Active {
    fn new(id: i64, hash: i64, outgoing: bool, user: i64, state: &'static str) -> Self {
        Self {
            id,
            hash,
            outgoing,
            user,
            state,
            dh: None,
            kp: None,
            g_a_hash: Vec::new(),
            engine: None,
            io: None,
            early: Vec::new(),
            connected_at: None,
            emoji: None,
            relay: false,
        }
    }

    fn input(&self) -> enums::InputPhoneCall {
        enums::InputPhoneCall::Call(types::InputPhoneCall { id: self.id, access_hash: self.hash })
    }

    fn duration(&self) -> i32 {
        self.connected_at.map(|t| t.elapsed().as_secs() as i32).unwrap_or(0)
    }

    fn json(&self) -> Value {
        json!({
            "call_id": self.id.to_string(),
            "peer": PeerId::user(self.user).map(peer_key),
            "outgoing": self.outgoing,
            "state": self.state,
            "emoji": self.emoji,
            "relay": self.relay,
            "duration": self.duration(),
            "muted": self.io.as_ref().is_some_and(|io| io.is_muted()),
        })
    }

    /// Dừng engine + cầu âm thanh.
    fn stop_media(&mut self) {
        if let Some(io) = self.io.take() {
            io.stop();
        }
        voip::install(None);
        self.engine = None;
    }
}

/// % một nhân CPU cả tiến trình (app) kể từ lần hỏi trước — số liệu gỡ lỗi `call.state` (đo tải cuộc gọi trên máy thật).
fn cpu_since_last() -> Option<f64> {
    #[cfg(unix)]
    {
        static LAST: Mutex<Option<(Instant, f64)>> = Mutex::new(None);
        let mut u: libc::rusage = unsafe { std::mem::zeroed() };
        if unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut u) } != 0 {
            return None;
        }
        let t = |v: libc::timeval| v.tv_sec as f64 + v.tv_usec as f64 / 1e6;
        let cpu = t(u.ru_utime) + t(u.ru_stime);
        let now = Instant::now();
        let mut last = lock(&LAST);
        let r = last.map(|(t0, c0)| (cpu - c0) / now.duration_since(t0).as_secs_f64().max(0.001) * 100.0);
        *last = Some((now, cpu));
        r
    }
    #[cfg(not(unix))]
    {
        None
    }
}

fn reason_str(r: &Option<enums::PhoneCallDiscardReason>) -> &'static str {
    match r {
        Some(enums::PhoneCallDiscardReason::Busy) => "busy",
        Some(enums::PhoneCallDiscardReason::Missed) => "missed",
        Some(enums::PhoneCallDiscardReason::Disconnect) => "disconnect",
        Some(enums::PhoneCallDiscardReason::Hangup) => "hangup",
        _ => "hangup",
    }
}

impl Core {
    fn emit_call(&self, a: &Active) {
        let mut v = a.json();
        v["e"] = json!("call.state");
        (self.emit)(v);
    }

    fn emit_call_ended(&self, a: &Active, reason: &str) {
        let mut v = a.json();
        v["e"] = json!("call.state");
        v["state"] = json!("ended");
        v["reason"] = json!(reason);
        (self.emit)(v);
    }

    /// getDhConfig → (p, g đã kiểm, random của máy chủ).
    async fn dh_config(&self) -> Result<(gm_call::DhConfig, Vec<u8>), CoreError> {
        match self.client.invoke(&functions::messages::GetDhConfig { version: 0, random_length: 256 }).await? {
            enums::messages::DhConfig::Config(x) => Ok((gm_call::DhConfig::new(&x.p, x.g).map_err(call_err)?, x.random)),
            enums::messages::DhConfig::NotModified(_) => Err(call_err("getDhConfig: NotModified")),
        }
    }

    /// `call.request` {peer}: gọi một người (chat riêng).
    pub(super) async fn call_request(self: &Arc<Self>, a: &Value) -> Res {
        if lock(&self.calls).is_some() {
            return Err(CoreError::new("CALL_BUSY", "Đang có cuộc gọi khác."));
        }
        let pr = self.peer_ref(a).await?;
        let user = enums::InputUser::from(pr);
        if matches!(user, enums::InputUser::Empty) {
            return Err(CoreError::new("BAD_ARGS", "Chỉ gọi được người dùng (chat riêng)."));
        }
        let (dh, random) = self.dh_config().await?;
        let kp = gm_call::KeyPair::new(&dh, &random).map_err(call_err)?;
        let random_id = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.subsec_nanos() as i32)
            .unwrap_or(1);
        let enums::phone::PhoneCall::Call(res) = self
            .client
            .invoke(&functions::phone::RequestCall {
                video: false,
                user_id: user,
                random_id,
                g_a_hash: kp.g_a_hash().to_vec(),
                protocol: protocol(),
            })
            .await?;
        let enums::PhoneCall::Waiting(w) = res.phone_call else {
            return Err(call_err(format!("requestCall trả về lạ: {:?}", res.phone_call)));
        };
        let mut act = Active::new(w.id, w.access_hash, true, w.participant_id, "requesting");
        act.dh = Some(Arc::new(dh));
        act.kp = Some(Arc::new(kp));
        let out = act.json();
        self.emit_call(&act);
        *lock(&self.calls) = Some(act);
        self.log(&format!("gọi thoại: đang gọi (cuộc gọi {})", w.id));
        Ok(out)
    }

    /// `call.accept`: nghe cuộc gọi đến — gửi g_b; bên gọi xác nhận bằng phoneCall (g_a) → engine chạy.
    pub(super) async fn call_accept(self: &Arc<Self>) -> Res {
        let input = {
            let g = lock(&self.calls);
            let a = g.as_ref().filter(|a| !a.outgoing && a.state == "incoming");
            a.ok_or_else(|| CoreError::new("CALL_NONE", "Không có cuộc gọi đến."))?.input()
        };
        let (dh, random) = self.dh_config().await?;
        let kp = gm_call::KeyPair::new(&dh, &random).map_err(call_err)?;
        let g_b = kp.g_a.to_vec();
        let out = {
            let mut g = lock(&self.calls);
            let Some(a) = g.as_mut().filter(|a| !a.outgoing && a.state == "incoming") else {
                return Err(CoreError::new("CALL_NONE", "Cuộc gọi đã kết thúc."));
            };
            a.dh = Some(Arc::new(dh));
            a.kp = Some(Arc::new(kp));
            a.state = "exchanging";
            self.emit_call(a);
            a.json()
        };
        if let Err(e) = self.client.invoke(&functions::phone::AcceptCall { peer: input, g_b, protocol: protocol() }).await {
            self.end_call(Some("error"), false).await;
            return Err(e.into());
        }
        Ok(out)
    }

    /// `call.hangup` {reason?}: gác / từ chối ("busy") / huỷ khi đang gọi.
    pub(super) async fn call_hangup(self: &Arc<Self>, a: &Value) -> Res {
        let busy = a.get("reason").and_then(Value::as_str) == Some("busy");
        self.end_call(Some(if busy { "busy" } else { "hangup" }), true).await;
        Ok(json!({}))
    }

    /// `call.mute` {on}: tắt / mở micro (không gửi tiếng).
    pub(super) fn call_mute(&self, a: &Value) -> Res {
        let on = a.get("on").and_then(Value::as_bool).unwrap_or(true);
        let g = lock(&self.calls);
        let act = g.as_ref().ok_or_else(|| CoreError::new("CALL_NONE", "Không có cuộc gọi."))?;
        if let Some(io) = &act.io {
            io.set_muted(on);
        }
        self.emit_call(act);
        Ok(act.json())
    }

    /// `calls.recent` {missed?, offset_id?, limit?}: cuộc gọi gần đây ở mọi chat riêng, mới → cũ (như mục «Cuộc gọi gần đây» của
    /// Telegram). Mỗi mục: {id, peer, name, photo, photo_dc, date, out, duration, reason (missed / busy / hangup / disconnect /
    /// ""), video}. `missed`: chỉ cuộc gọi nhỡ. Tải tiếp: `offset_id` = `id` của mục cuối.
    pub(super) async fn calls_recent(&self, a: &Value) -> Res {
        let missed = a.get("missed").and_then(Value::as_bool).unwrap_or(false);
        let offset_id = a.get("offset_id").and_then(Value::as_i64).unwrap_or(0) as i32;
        let limit = a.get("limit").and_then(Value::as_i64).unwrap_or(50).clamp(1, 100) as i32;
        let r = self
            .client
            .invoke(&functions::messages::Search {
                peer: enums::InputPeer::Empty,
                q: String::new(),
                from_id: None,
                saved_peer_id: None,
                saved_reaction: None,
                top_msg_id: None,
                filter: enums::MessagesFilter::InputMessagesFilterPhoneCalls(types::InputMessagesFilterPhoneCalls { missed }),
                min_date: 0,
                max_date: 0,
                offset_id,
                add_offset: 0,
                limit,
                max_id: 0,
                min_id: 0,
                hash: 0,
            })
            .await?;
        let (msgs, users, chats) = match r {
            enums::messages::Messages::Messages(x) => (x.messages, x.users, x.chats),
            enums::messages::Messages::Slice(x) => (x.messages, x.users, x.chats),
            enums::messages::Messages::ChannelMessages(x) => (x.messages, x.users, x.chats),
            enums::messages::Messages::NotModified(_) => (Vec::new(), Vec::new(), Vec::new()),
        };
        let peers = self.client.build_peer_map(users, chats).await;
        let mut out = Vec::new();
        for raw in msgs {
            let m = grammers_client::message::Message::from_raw(&self.client, raw, None, peers.handle());
            let Some(enums::MessageAction::PhoneCall(x)) = m.action() else { continue };
            let (photo, photo_dc) = m.peer().map(peer_photo).unwrap_or((Value::Null, Value::Null));
            out.push(json!({
                "id": m.id(),
                "peer": peer_key(m.peer_id()),
                "name": m.peer().map(peer_name),
                "photo": photo,
                "photo_dc": photo_dc,
                "date": m.date().as_second(),
                "out": m.outgoing(),
                "duration": x.duration.unwrap_or(0),
                "reason": if x.reason.is_some() { reason_str(&x.reason) } else { "" },
                "video": x.video,
            }));
        }
        Ok(Value::Array(out))
    }

    /// `call.state`: cuộc gọi hiện có (null nếu không), kèm số liệu gỡ lỗi (`stats`: gói đi / đến của engine, mức micro, số lượt
    /// callback bỏ qua, số mẫu loa phải bù im lặng).
    pub(super) fn call_state(&self) -> Res {
        let g = lock(&self.calls);
        let Some(a) = g.as_ref() else { return Ok(Value::Null) };
        let mut v = a.json();
        if let Some(io) = &a.io {
            use std::sync::atomic::Ordering::Relaxed;
            v["stats"] = json!(format!(
                "{}; micro {} · bỏ lượt {} · loa thiếu {} mẫu · CPU app {}",
                engine::counters::line(),
                io.mic_level.load(Relaxed),
                io.skipped.load(Relaxed),
                io.underrun.load(Relaxed),
                cpu_since_last().map(|p| format!("{p:.1}%")).unwrap_or_else(|| "?".into())
            ));
        }
        Ok(v)
    }

    /// Kết thúc cuộc gọi hiện có: dừng engine, (tuỳ) báo máy chủ discardCall, phát `call.state` ended.
    async fn end_call(self: &Arc<Self>, reason: Option<&str>, notify_server: bool) {
        let Some(mut act) = lock(&self.calls).take() else { return };
        act.stop_media();
        let r = reason.unwrap_or("hangup");
        if notify_server {
            let tl_reason = match r {
                "busy" => enums::PhoneCallDiscardReason::Busy,
                "disconnect" | "error" => enums::PhoneCallDiscardReason::Disconnect,
                "missed" => enums::PhoneCallDiscardReason::Missed,
                _ => enums::PhoneCallDiscardReason::Hangup,
            };
            let req = functions::phone::DiscardCall {
                video: false,
                peer: act.input(),
                duration: act.duration(),
                reason: tl_reason,
                connection_id: 0,
            };
            if let Err(e) = self.client.invoke(&req).await {
                self.log(&format!("gọi thoại: discardCall lỗi {e}"));
            }
        }
        self.log(&format!("gọi thoại: kết thúc ({r}, {} giây)", act.duration()));
        self.emit_call_ended(&act, r);
    }

    /// Tách cập nhật cuộc gọi khỏi một gói cập nhật thô (gọi ở tầng chia luồng trước MessageBox).
    pub(super) fn tap_phone(self: &Arc<Self>, u: &UpdatesLike) {
        let list: &[enums::Update] = match u {
            UpdatesLike::Updates(enums::Updates::Updates(x)) => &x.updates,
            UpdatesLike::Updates(enums::Updates::Combined(x)) => &x.updates,
            UpdatesLike::Updates(enums::Updates::UpdateShort(x)) => std::slice::from_ref(&x.update),
            _ => return,
        };
        for up in list {
            match up {
                enums::Update::PhoneCall(x) => self.on_phone_call(x.phone_call.clone()),
                enums::Update::PhoneCallSignalingData(s) => self.on_call_signaling(s.phone_call_id, s.data.clone()),
                _ => {}
            }
        }
    }

    fn on_call_signaling(&self, call_id: i64, data: Vec<u8>) {
        let mut g = lock(&self.calls);
        let Some(a) = g.as_mut().filter(|a| a.id == call_id) else { return };
        match &a.engine {
            Some(h) => h.signaling(data),
            None if a.early.len() < 64 => a.early.push(data),
            None => {}
        }
    }

    fn on_phone_call(self: &Arc<Self>, pc: enums::PhoneCall) {
        let (kind, id) = match &pc {
            enums::PhoneCall::Empty(x) => ("empty", x.id),
            enums::PhoneCall::Waiting(x) => ("waiting", x.id),
            enums::PhoneCall::Requested(x) => ("requested", x.id),
            enums::PhoneCall::Accepted(x) => ("accepted", x.id),
            enums::PhoneCall::Call(x) => ("call", x.id),
            enums::PhoneCall::Discarded(x) => ("discarded", x.id),
        };
        let extra = match &pc {
            enums::PhoneCall::Discarded(x) => format!(" lý do {:?}, {:?} giây", x.reason, x.duration),
            _ => String::new(),
        };
        self.log(&format!("gọi thoại: cập nhật {kind} (cuộc gọi {id}){extra}"));
        match pc {
            enums::PhoneCall::Requested(r) => {
                let mut g = lock(&self.calls);
                if let Some(cur) = g.as_ref() {
                    if cur.id != r.id {
                        // Đang bận cuộc khác: báo bận
                        let c = Arc::clone(self);
                        let input = enums::InputPhoneCall::Call(types::InputPhoneCall { id: r.id, access_hash: r.access_hash });
                        tokio::spawn(async move {
                            let req = functions::phone::DiscardCall {
                                video: false,
                                peer: input,
                                duration: 0,
                                reason: enums::PhoneCallDiscardReason::Busy,
                                connection_id: 0,
                            };
                            let _ = c.client.invoke(&req).await;
                        });
                    }
                    return;
                }
                let mut act = Active::new(r.id, r.access_hash, false, r.admin_id, "incoming");
                act.g_a_hash = r.g_a_hash;
                let input = act.input();
                self.emit_call(&act);
                *g = Some(act);
                drop(g);
                self.log(&format!("gọi thoại: có cuộc gọi đến (cuộc gọi {})", r.id));
                // Báo máy chủ «đã đổ chuông» (bên gọi thấy «Đang đổ chuông»)
                let c = Arc::clone(self);
                tokio::spawn(async move {
                    let _ = c.client.invoke(&functions::phone::ReceivedCall { peer: input }).await;
                });
            }
            enums::PhoneCall::Accepted(_) | enums::PhoneCall::Call(_) if self.answered_elsewhere(&pc) =>
            {
                // Cuộc gọi đến đã được nghe trên máy khác cùng tài khoản: thôi đổ chuông (không báo máy chủ)
                self.log("gọi thoại: đã nghe trên máy khác");
                let c = Arc::clone(self);
                tokio::spawn(async move { c.end_call(Some("elsewhere"), false).await });
            }
            enums::PhoneCall::Waiting(w) => {
                let mut g = lock(&self.calls);
                if let Some(a) = g.as_mut().filter(|a| a.id == w.id && a.outgoing && a.state == "requesting") {
                    if w.receive_date.is_some() {
                        a.state = "ringing";
                        self.emit_call(a);
                    }
                }
            }
            enums::PhoneCall::Accepted(x) => {
                // Bên gọi: bên kia đã nghe (g_b) → khoá chung → confirmCall (g_a) → phoneCall
                let (input, dh, kp) = {
                    let mut g = lock(&self.calls);
                    let Some(a) = g.as_mut().filter(|a| a.id == x.id && a.outgoing && a.state != "exchanging") else {
                        return;
                    };
                    let (Some(dh), Some(kp)) = (a.dh.clone(), a.kp.clone()) else { return };
                    a.state = "exchanging";
                    self.emit_call(a);
                    (a.input(), dh, kp)
                };
                let c = Arc::clone(self);
                tokio::spawn(async move {
                    let key = match kp.shared_key(&dh, &x.g_b) {
                        Ok(k) => k,
                        Err(e) => {
                            c.log(&format!("gọi thoại: g_b sai ({e})"));
                            c.end_call(Some("error"), true).await;
                            return;
                        }
                    };
                    let req = functions::phone::ConfirmCall {
                        peer: input,
                        g_a: kp.g_a.to_vec(),
                        key_fingerprint: gm_call::key_fingerprint(&key),
                        protocol: protocol(),
                    };
                    match c.client.invoke(&req).await {
                        Ok(enums::phone::PhoneCall::Call(res)) => match res.phone_call {
                            enums::PhoneCall::Call(pc) => c.start_media(pc, key, kp.g_a.to_vec()),
                            enums::PhoneCall::Discarded(d) => {
                                c.log("gọi thoại: confirmCall → cuộc gọi đã huỷ");
                                c.end_call(Some(reason_str(&d.reason)), false).await;
                            }
                            other => c.log(&format!("gọi thoại: confirmCall trả về lạ {other:?}")),
                        },
                        Err(e) => {
                            c.log(&format!("gọi thoại: confirmCall lỗi {e}"));
                            c.end_call(Some("error"), true).await;
                        }
                    }
                });
            }
            enums::PhoneCall::Call(pc) => {
                // Bên nghe: bên gọi đã lộ g_a — kiểm khớp g_a_hash, khoá chung, key_fingerprint
                let (dh, kp, g_a_hash) = {
                    let g = lock(&self.calls);
                    let Some(a) = g.as_ref().filter(|a| a.id == pc.id && !a.outgoing && a.state == "exchanging") else {
                        return;
                    };
                    let (Some(dh), Some(kp)) = (a.dh.clone(), a.kp.clone()) else { return };
                    (dh, kp, a.g_a_hash.clone())
                };
                let ok = gm_call::g_a_matches_hash(&pc.g_a_or_b, &g_a_hash)
                    .then(|| kp.shared_key(&dh, &pc.g_a_or_b).ok())
                    .flatten()
                    .filter(|k| gm_call::key_fingerprint(k) == pc.key_fingerprint);
                match ok {
                    Some(key) => {
                        let g_a = pc.g_a_or_b.clone();
                        self.start_media(pc, key, g_a);
                    }
                    None => {
                        self.log("gọi thoại: khoá của bên gọi không khớp — huỷ");
                        let c = Arc::clone(self);
                        tokio::spawn(async move { c.end_call(Some("error"), true).await });
                    }
                }
            }
            enums::PhoneCall::Discarded(d) => {
                let state = lock(&self.calls).as_ref().filter(|a| a.id == d.id).map(|a| a.state);
                if let Some(st) = state {
                    // Đang đổ chuông mà máy chủ kết thúc không kèm lý do: máy khác cùng tài khoản đã nghe / từ chối (thử thật
                    // 21/11/2026 — người gọi huỷ thì lý do là Missed)
                    let reason = if st == "incoming" && d.reason.is_none() { "elsewhere" } else { reason_str(&d.reason) };
                    let c = Arc::clone(self);
                    tokio::spawn(async move { c.end_call(Some(reason), false).await });
                }
            }
            enums::PhoneCall::Empty(_) => {}
        }
    }

    /// Cuộc gọi đến (chưa nghe ở máy này) mà máy chủ báo đã sang bước sau — máy khác cùng tài khoản đã nghe.
    fn answered_elsewhere(&self, pc: &enums::PhoneCall) -> bool {
        let id = match pc {
            enums::PhoneCall::Accepted(a) => a.id,
            enums::PhoneCall::Call(c) => c.id,
            _ => return false,
        };
        lock(&self.calls).as_ref().is_some_and(|a| a.id == id && !a.outgoing && a.state == "incoming")
    }

    /// Khoá xong: in emoji, chạy engine + cầu âm thanh, chuyển báo hiệu và trạng thái đường truyền cho app.
    fn start_media(self: &Arc<Self>, pc: types::PhoneCall, key: [u8; 256], g_a: Vec<u8>) {
        let emoji = gm_call::emoji_fingerprint(&key, &g_a);
        let mut refl = Vec::new();
        for cn in &pc.connections {
            if let enums::PhoneConnection::Connection(x) = cn {
                refl.push(tg::Reflector { id: x.id, ip: x.ip.clone(), port: x.port, peer_tag: x.peer_tag.clone(), tcp: x.tcp });
            }
        }
        let custom = match &pc.custom_parameters {
            Some(enums::DataJson::Json(j)) => Some(j.data.clone()),
            None => None,
        };
        let shared = audio::Shared::new();
        let (frames_tx, frames_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(64);
        let (input, early) = {
            let mut g = lock(&self.calls);
            let Some(a) = g.as_mut().filter(|a| a.id == pc.id) else { return };
            let cfg = engine::EngineConfig {
                key: tg::CallKey(key),
                outgoing: a.outgoing,
                reflectors: tg::reflectors(&refl),
                standalone_reflectors: tg::custom_flag(custom.as_deref(), "network_standalone_reflectors"),
                p2p: pc.p2p_allowed,
                loopback: false,
                connect_timeout: Duration::from_secs(30),
                packet_timeout: Duration::from_secs(10),
            };
            engine::counters::reset();
            let h = engine::start(cfg, Arc::clone(&shared), frames_rx);
            let events = h.take_events();
            let io = voip::VoipIo::start(Arc::clone(&shared), frames_tx);
            voip::install(io.clone());
            a.io = io;
            a.emoji = Some(emoji);
            a.state = "connecting";
            let early = std::mem::take(&mut a.early);
            for s in &early {
                h.signaling(s.clone());
            }
            a.engine = Some(h);
            self.emit_call(a);
            (a.input(), events)
        };
        self.log(&format!("gọi thoại: engine chạy ({} máy chủ chuyển tiếp, p2p {})", refl.len(), pc.p2p_allowed));
        let Some(mut events) = early else { return };
        let c = Arc::clone(self);
        let call_id = pc.id;
        tokio::spawn(async move {
            while let Some(ev) = events.recv().await {
                match ev {
                    engine::EngineEvent::Signaling(data) => {
                        if let Err(e) =
                            c.client.invoke(&functions::phone::SendSignalingData { peer: input.clone(), data }).await
                        {
                            c.log(&format!("gọi thoại: sendSignalingData lỗi {e}"));
                        }
                    }
                    engine::EngineEvent::State(s) => {
                        let mut g = lock(&c.calls);
                        let Some(a) = g.as_mut().filter(|a| a.id == call_id) else { break };
                        match s {
                            engine::LinkState::Connected { relay } => {
                                a.state = "connected";
                                a.relay = relay;
                                a.connected_at.get_or_insert_with(Instant::now);
                            }
                            engine::LinkState::Reconnecting => a.state = "reconnecting",
                            engine::LinkState::Connecting => a.state = "connecting",
                        }
                        c.emit_call(a);
                    }
                    engine::EngineEvent::Quality(q) => (c.emit)(json!({"e": "call.quality", "call_id": call_id.to_string(), "bars": q})),
                    engine::EngineEvent::Failed(e) => {
                        c.log(&format!("gọi thoại: engine dừng — {e}"));
                        c.end_call(Some("disconnect"), true).await;
                        break;
                    }
                }
            }
        });
    }
}
