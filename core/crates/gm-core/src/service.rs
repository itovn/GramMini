//! Dịch vụ lõi cho app: một tài khoản, lệnh dạng JSON (`call`), sự kiện đẩy lên app (`Emit`). Chạy trong runtime tokio
//! của `gm-ffi`. Dữ liệu ở `data_dir`: `session.json` (phiên, xem `session.rs`), `settings.json` (proxy, chính sách
//! bộ nhớ đệm), `core.log`; tệp đệm ở `media/`, `avatars/`, `tmp/` (xem `cache.rs`).
//!
//! Khoá peer là chuỗi số kiểu Bot API (`bot_api_dialog_id`: người > 0, nhóm < 0, kênh / siêu nhóm -100…) — xem
//! docs/FFI.md.

use std::io::Write as _;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use gm_net::{ClientInfo, GmConnector, ProxyConfig};
use grammers_client::client::{LoginToken, PasswordToken, SignInError};
use grammers_client::media::Media;
use grammers_client::message::Message;
use grammers_client::peer::Peer;
use grammers_client::update::Update;
use grammers_client::{Client, InvocationError};
use grammers_mtsender::{SenderPool, SenderPoolFatHandle, ServerAddr, UpdatesConfiguration};
use grammers_session::Session as _;
use grammers_session::types::{PeerId, PeerRef};
use grammers_session::updates::UpdatesLike;
use serde_json::{Value, json};
use tokio::sync::mpsc;

use crate::FileSession;

/// Hàm đẩy sự kiện lên app (gọi từ luồng của lõi).
pub type Emit = Arc<dyn Fn(Value) + Send + Sync>;

/// Thông tin lúc mở lõi.
pub struct Config {
    pub data_dir: PathBuf,
    pub api_id: i32,
    pub api_hash: String,
    pub client: ClientInfo,
}

/// Lỗi trả cho app: `code` máy đọc (vd `PHONE_CODE_INVALID`, `FLOOD_WAIT`), `msg` câu báo tiếng Việt.
#[derive(Debug)]
pub struct CoreError {
    pub code: String,
    pub msg: String,
    pub extra: Value,
}

impl CoreError {
    pub fn new(code: &str, msg: impl Into<String>) -> Self {
        Self { code: code.into(), msg: msg.into(), extra: Value::Null }
    }

    pub fn to_json(&self) -> Value {
        let mut v = json!({"code": self.code, "msg": self.msg});
        if let (Value::Object(m), Value::Object(x)) = (&mut v, &self.extra) {
            m.extend(x.clone());
        }
        v
    }
}

impl From<InvocationError> for CoreError {
    fn from(e: InvocationError) -> Self {
        match &e {
            InvocationError::Rpc(r) => {
                let msg = match r.name.as_str() {
                    "FLOOD_WAIT" => format!("Telegram bảo chờ {} giây rồi thử lại.", r.value.unwrap_or(0)),
                    "PHONE_NUMBER_INVALID" => "Số điện thoại không đúng.".into(),
                    "PHONE_CODE_INVALID" => "Mã không đúng.".into(),
                    "PHONE_CODE_EXPIRED" => "Mã đã hết hạn — gửi mã mới.".into(),
                    "PHONE_NUMBER_BANNED" => "Số điện thoại này bị Telegram khoá.".into(),
                    "AUTH_KEY_UNREGISTERED" | "SESSION_REVOKED" => "Phiên đăng nhập đã hết — đăng nhập lại.".into(),
                    "SRP_ID_INVALID" => "Phiên kiểm tra mật khẩu đã hết — nhập lại mật khẩu.".into(),
                    "AUTH_KEY_DUPLICATED" => "Phiên đăng nhập bị Telegram huỷ (dùng cùng lúc ở hai nơi) — đăng nhập lại.".into(),
                    "INVITE_HASH_EXPIRED" | "INVITE_HASH_INVALID" | "INVITE_HASH_EMPTY" => "Link mời đã hết hạn hoặc không đúng.".into(),
                    "INVITE_REQUEST_SENT" => "Đã gửi yêu cầu tham gia — chờ quản trị viên duyệt.".into(),
                    "CHANNELS_TOO_MUCH" => "Bạn đã ở quá nhiều nhóm / kênh — rời bớt rồi thử lại.".into(),
                    "USERS_TOO_MUCH" => "Nhóm đã đủ người.".into(),
                    "CHANNEL_PRIVATE" => "Nhóm / kênh này là riêng tư, hoặc bạn đã bị chặn khỏi đó.".into(),
                    "CHAT_WRITE_FORBIDDEN" => "Bạn không được gửi tin trong chat này.".into(),
                    "REACTION_INVALID" | "REACTION_EMPTY" => "Chat này không cho thả cảm xúc này.".into(),
                    "REACTIONS_TOO_MANY" => "Tin này đã đủ số loại cảm xúc.".into(),
                    "CHAT_ADMIN_REQUIRED" => "Cần quyền quản trị viên để làm việc này.".into(),
                    "MESSAGE_POLL_CLOSED" => "Bình chọn đã đóng.".into(),
                    "REVOTE_NOT_ALLOWED" => "Bình chọn này không cho đổi phiếu.".into(),
                    _ => format!("Telegram báo lỗi {} ({})", r.name, r.code),
                };
                let mut ce = CoreError::new(&r.name, msg);
                if let Some(v) = r.value {
                    ce.extra = json!({"value": v});
                }
                ce
            }
            _ => CoreError::new("NETWORK", format!("Lỗi mạng: {e}")),
        }
    }
}

type Res = Result<Value, CoreError>;

fn arg_str<'a>(a: &'a Value, k: &str) -> Result<&'a str, CoreError> {
    a.get(k).and_then(Value::as_str).ok_or_else(|| CoreError::new("BAD_ARGS", format!("thiếu «{k}»")))
}

pub struct Core {
    cfg: Config,
    client: Client,
    session: Arc<FileSession>,
    conn: Arc<GmConnector>,
    emit: Emit,
    handle: SenderPoolFatHandle,
    login: Mutex<Option<LoginToken>>,
    password: Mutex<Option<PasswordToken>>,
    updates: Mutex<Option<mpsc::Receiver<UpdatesLike>>>,
    log: Mutex<Option<std::fs::File>>,
    /// Mạng: 0 chưa biết, 1 kết nối được, 2 mất kết nối (sự kiện `net.state` khi đổi).
    net: std::sync::atomic::AtomicU8,
    /// Phiên đã bị Telegram huỷ (auth key dùng trùng / bị thu hồi) — tệp phiên đã dời đi, chờ app mở lại để đăng nhập mới.
    dead: std::sync::atomic::AtomicBool,
    /// Tải media: tối đa 3 tệp cùng lúc (máy A4 một nhân).
    dl: tokio::sync::Semaphore,
    /// Bộ nhớ đệm: chính sách tự dọn, lượt dọn.
    cache: crate::cache::Cache,
    /// Tin chữ chờ gửi lúc mất mạng (`outbox.json`), đang gửi dần hay không.
    outbox: Mutex<Vec<Value>>,
    flushing: std::sync::atomic::AtomicBool,
    /// Sticker / GIF đã lấy về (bộ sticker, gần đây, GIF đã lưu) theo mã tài liệu — để gửi lại, tải ảnh xem trước.
    docs: Mutex<std::collections::HashMap<i64, grammers_client::tl::types::Document>>,
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl Core {
    /// Mở lõi (không đụng mạng). Phải gọi trong runtime tokio.
    pub fn start(cfg: Config, emit: Emit) -> Result<Arc<Core>, CoreError> {
        std::fs::create_dir_all(&cfg.data_dir).map_err(|e| CoreError::new("IO", format!("tạo thư mục dữ liệu: {e}")))?;
        let session = Arc::new(
            FileSession::open(cfg.data_dir.join("session.json")).map_err(|e| CoreError::new("IO", e.to_string()))?,
        );
        let proxy = Self::load_proxy(&cfg.data_dir);
        let policy = Self::load_policy(&cfg.data_dir);
        let conn = GmConnector::new(proxy);
        // Socket mới → app (iOS: bọc thành socket VoIP — iOS đánh thức app khi có tin về lúc app đang treo ở nền)
        let hook_emit = Arc::clone(&emit);
        conn.set_socket_hook(Arc::new(move |fd, dc| hook_emit(json!({"e": "net.socket", "fd": fd, "dc": dc}))));
        let params = conn.connection_params(cfg.client.clone());
        let SenderPool { runner, updates, handle } = SenderPool::with_configuration(Arc::clone(&session), cfg.api_id, params);
        let client = Client::new(handle.clone());
        tokio::spawn(runner.run());
        let log_path = cfg.data_dir.join("core.log");
        if std::fs::metadata(&log_path).map(|m| m.len() > 1 << 20).unwrap_or(false) {
            let _ = std::fs::remove_file(&log_path); // nhật ký quá 1 MB: bắt đầu lại
        }
        let log = std::fs::OpenOptions::new().create(true).append(true).open(&log_path).ok();
        let core = Arc::new(Core {
            cfg,
            client,
            session,
            conn,
            emit,
            handle,
            login: Mutex::new(None),
            password: Mutex::new(None),
            updates: Mutex::new(Some(updates)),
            log: Mutex::new(log),
            net: std::sync::atomic::AtomicU8::new(0),
            dead: std::sync::atomic::AtomicBool::new(false),
            dl: tokio::sync::Semaphore::new(3),
            cache: crate::cache::Cache::new(policy),
            outbox: Mutex::new(Vec::new()),
            flushing: std::sync::atomic::AtomicBool::new(false),
            docs: Mutex::new(Default::default()),
        });
        *lock(&core.outbox) = std::fs::read(core.cfg.data_dir.join("outbox.json"))
            .ok()
            .and_then(|b| serde_json::from_slice::<Vec<Value>>(&b).ok())
            .unwrap_or_default();
        core.log(&format!("mở lõi, proxy: {:?}", core.conn.config()));
        // Mất kết nối thì 10 giây hỏi lại một lần (updates.getState — rẻ) tới khi được
        let h = Arc::clone(&core);
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(10)).await;
                if h.net.load(std::sync::atomic::Ordering::Relaxed) != 1 {
                    h.check_net().await;
                }
                if h.net.load(std::sync::atomic::Ordering::Relaxed) == 1 && !lock(&h.outbox).is_empty() {
                    h.flush_outbox();
                }
            }
        });
        // Tự dọn bộ nhớ đệm: 20 giây sau khi mở (đỡ tranh lúc khởi động), rồi 30 phút một lần
        let h = Arc::clone(&core);
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(20)).await;
            loop {
                h.trim_soon(true);
                tokio::time::sleep(Duration::from_secs(30 * 60)).await;
            }
        });
        // Đã đăng nhập thì nghe cập nhật luôn (lấy bù tin đã lỡ)
        let c = Arc::clone(&core);
        tokio::spawn(async move {
            match c.client.is_authorized().await {
                Ok(true) => {
                    (c.emit)(json!({"e": "auth.state", "authorized": true}));
                    c.start_updates();
                }
                Ok(false) => (c.emit)(json!({"e": "auth.state", "authorized": false})),
                Err(e) => {
                    c.log(&format!("is_authorized: {e}"));
                    let ce = CoreError::from(e);
                    c.check_dead(&ce.code);
                }
            }
        });
        Ok(core)
    }

    /// Thông số mật khẩu 2 lớp mới (account.getPassword — mỗi lần kiểm tra mật khẩu cần một srp_id mới).
    async fn password_token(&self) -> Result<PasswordToken, CoreError> {
        let p: grammers_client::tl::types::account::Password =
            self.client.invoke(&grammers_client::tl::functions::account::GetPassword {}).await?.into();
        Ok(PasswordToken::new(p))
    }

    /// Lỗi `code` nghĩa là phiên đã chết (Telegram huỷ auth key: dùng trùng ở hai nơi, bị thu hồi, tài khoản bị khoá) → dời
    /// `session.json` thành `session.dead-<giờ>.json` (một lần), báo app `auth.dead` + `auth.state` (chưa đăng nhập). Auth key
    /// cũ còn trong bộ nhớ không dùng lại được → app phải mở lại (lõi mới, phiên trống) để đăng nhập. Trả có / không.
    fn check_dead(&self, code: &str) -> bool {
        if !matches!(code, "AUTH_KEY_DUPLICATED" | "SESSION_REVOKED" | "USER_DEACTIVATED" | "USER_DEACTIVATED_BAN") {
            return false;
        }
        if self.dead.swap(true, std::sync::atomic::Ordering::SeqCst) {
            return true;
        }
        let from = self.cfg.data_dir.join("session.json");
        let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let to = self.cfg.data_dir.join(format!("session.dead-{secs}.json"));
        let moved = std::fs::rename(&from, &to).is_ok();
        self.log(&format!("phiên chết ({code}) — dời tệp phiên: {moved}"));
        (self.emit)(json!({"e": "auth.dead", "code": code}));
        (self.emit)(json!({"e": "auth.state", "authorized": false, "dead": true}));
        true
    }

    /// Tải về `path` (qua tệp tạm `.<số>.part` riêng của lần tải, xong mới đổi tên).
    async fn download(self: &Arc<Self>, loc: &crate::media::Loc, path: &std::path::Path) -> Result<(), CoreError> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| CoreError::new("IO", e.to_string()))?;
        }
        let tmp = part_path(path);
        // Tự ghi tệp (không dùng Client::download_media): grammers ghi bằng tokio::fs::File mà không flush → lần ghi cuối còn
        // chạy nền sau khi hàm trả về; đọc ngay sau đó (sticker video ~200 KB) thấy tệp 0 byte (16/11/2026)
        let fetch = async {
            use tokio::io::AsyncWriteExt;
            let io = |e: std::io::Error| CoreError::new("IO", e.to_string());
            let mut f = tokio::fs::File::create(&tmp).await.map_err(io)?;
            let mut it = self.client.iter_download(loc);
            while let Some(chunk) = it.next().await? {
                f.write_all(&chunk).await.map_err(io)?;
            }
            f.flush().await.map_err(io)?;
            Ok::<(), CoreError>(())
        };
        let r = tokio::time::timeout(Duration::from_secs(120), fetch).await;
        match r {
            Ok(Ok(())) => {
                std::fs::rename(&tmp, path).map_err(|e| CoreError::new("IO", e.to_string()))?;
                self.trim_soon(false);
                Ok(())
            }
            Ok(Err(e)) => {
                let _ = std::fs::remove_file(&tmp);
                Err(e.into())
            }
            Err(_) => {
                let _ = std::fs::remove_file(&tmp);
                Err(CoreError::new("TIMEOUT", "Tải quá lâu."))
            }
        }
    }

    /// Tải tệp lớn theo từng phần (512 KB), đẩy sự kiện `media.progress` (~ mỗi 256 KB) để app vẽ tiến độ.
    async fn download_progress(self: &Arc<Self>, loc: &crate::media::Loc, path: &std::path::Path, peer: &str, id: i64) -> Result<(), CoreError> {
        use tokio::io::AsyncWriteExt;
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| CoreError::new("IO", e.to_string()))?;
        }
        let tmp = part_path(path);
        let mut f = tokio::fs::File::create(&tmp).await.map_err(|e| CoreError::new("IO", e.to_string()))?;
        let total = loc.size.unwrap_or(0);
        let mut it = self.client.iter_download(loc);
        let (mut done, mut last) = (0usize, 0usize);
        loop {
            let chunk = match tokio::time::timeout(Duration::from_secs(60), it.next()).await {
                Ok(Ok(Some(c))) => c,
                Ok(Ok(None)) => break,
                Ok(Err(e)) => {
                    let _ = tokio::fs::remove_file(&tmp).await;
                    return Err(e.into());
                }
                Err(_) => {
                    let _ = tokio::fs::remove_file(&tmp).await;
                    return Err(CoreError::new("TIMEOUT", "Tải quá lâu."));
                }
            };
            f.write_all(&chunk).await.map_err(|e| CoreError::new("IO", e.to_string()))?;
            done += chunk.len();
            if done - last >= 256 * 1024 {
                last = done;
                (self.emit)(json!({"e": "media.progress", "peer": peer, "id": id, "done": done, "total": total}));
            }
        }
        f.flush().await.map_err(|e| CoreError::new("IO", e.to_string()))?;
        drop(f);
        std::fs::rename(&tmp, path).map_err(|e| CoreError::new("IO", e.to_string()))?;
        self.trim_soon(false);
        Ok(())
    }

    /// Tải tệp lên (grammers chia phần 512 KB; tệp > 10 MB: nhiều lượt song song). Có `tag` thì đẩy sự kiện
    /// `upload.progress` (~ mỗi 256 KB đọc được) để app vẽ tiến độ.
    async fn upload(&self, path: &str, name: Option<&str>, tag: Option<&str>) -> Result<grammers_client::media::Uploaded, CoreError> {
        let f = tokio::fs::File::open(path).await.map_err(|e| CoreError::new("IO", format!("Không đọc được tệp: {e}")))?;
        let size = f.metadata().await.map_err(|e| CoreError::new("IO", e.to_string()))?.len();
        if size == 0 {
            return Err(CoreError::new("EMPTY_FILE", "Tệp rỗng."));
        }
        if size > 2000 << 20 {
            return Err(CoreError::new("FILE_TOO_BIG", "Tệp quá 2 GB — Telegram không nhận."));
        }
        let name = name
            .map(str::to_string)
            .unwrap_or_else(|| std::path::Path::new(path).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default());
        let mut r = Counting { inner: f, done: 0, last: 0, total: size, tag: tag.map(str::to_string), emit: Arc::clone(&self.emit) };
        self.client
            .upload_stream(&mut r, size as usize, name)
            .await
            .map_err(|e| CoreError::new("UPLOAD", format!("Tải lên lỗi: {e}")))
    }

    /// Gửi tin chữ (`peer`, `text`, `reply_to`?, `schedule`?).
    async fn send_text(&self, a: &Value) -> Res {
        let peer = self.peer_ref(a).await?;
        let text = arg_str(a, "text")?;
        let reply = reply_arg(a);
        let mut msg = grammers_client::message::InputMessage::new()
            .text(text)
            .reply_to(reply)
            .silent(a.get("silent").and_then(Value::as_bool).unwrap_or(false));
        // Hẹn giờ (Unix giây): máy chủ giữ tin, tới giờ mới gửi (Tin nhắn đã lưu: thành lời nhắc)
        let schedule = a.get("schedule").and_then(Value::as_i64);
        if let Some(t) = schedule {
            msg = msg.schedule_date(Some(std::time::UNIX_EPOCH + Duration::from_secs(t.clamp(0, i32::MAX as i64) as u64)));
        }
        let m = tokio::time::timeout(Duration::from_secs(20), self.client.send_message(peer, msg))
            .await
            .map_err(|_| CoreError::new("TIMEOUT", "Gửi quá lâu."))??;
        if schedule.is_some() {
            return Ok(json!({"scheduled": true}));
        }
        Ok(msg_json(&m))
    }

    /// Đưa tin vào hàng chờ (mã tạm âm), trả như tin «đang chờ».
    fn enqueue(&self, a: &Value) -> Res {
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
        let item = json!({
            "local_id": -((now.as_millis() % 1_000_000_000) as i64) - 1,
            "peer": arg_str(a, "peer")?,
            "text": arg_str(a, "text")?,
            "reply_to": a.get("reply_to").cloned().unwrap_or(Value::Null),
            "topic": a.get("topic").cloned().unwrap_or(Value::Null),
            "date": now.as_secs(),
        });
        lock(&self.outbox).push(item.clone());
        self.save_outbox();
        self.log("mất mạng: tin vào hàng chờ");
        let mut v = item;
        v["queued"] = json!(true);
        Ok(v)
    }

    fn save_outbox(&self) {
        let v = Value::Array(lock(&self.outbox).clone());
        if let Err(e) = crate::session::write_private(&self.cfg.data_dir.join("outbox.json"), "json.part", v.to_string().as_bytes()) {
            self.log(&format!("ghi hàng chờ: {e}"));
        }
    }

    /// Gửi dần hàng chờ (một lượt một lúc, đúng thứ tự). Lỗi mạng → dừng, thử lại sau; máy chủ từ chối → bỏ tin, báo app.
    fn flush_outbox(self: &Arc<Self>) {
        if self.flushing.swap(true, std::sync::atomic::Ordering::AcqRel) {
            return;
        }
        let c = Arc::clone(self);
        tokio::spawn(async move {
            loop {
                let Some(item) = lock(&c.outbox).first().cloned() else { break };
                let id = item["local_id"].as_i64();
                match Box::pin(c.send_text(&item)).await {
                    Ok(msg) => {
                        lock(&c.outbox).retain(|i| i["local_id"].as_i64() != id);
                        c.save_outbox();
                        (c.emit)(json!({"e": "outbox.sent", "local_id": id, "peer": item["peer"], "msg": msg}));
                    }
                    Err(e) if is_net_error(&e) => break,
                    Err(e) => {
                        lock(&c.outbox).retain(|i| i["local_id"].as_i64() != id);
                        c.save_outbox();
                        (c.emit)(json!({"e": "outbox.failed", "local_id": id, "peer": item["peer"], "code": e.code, "message": e.msg}));
                    }
                }
            }
            c.flushing.store(false, std::sync::atomic::Ordering::Release);
        });
    }

    /// `chat.status`: dòng phụ dưới tên chat — người: trực tuyến / truy cập lúc…; nhóm: thành viên, đang trực tuyến; kênh:
    /// người theo dõi.
    async fn chat_status(&self, a: &Value) -> Res {
        use grammers_client::tl::{enums, functions};
        let pr = self.peer_ref(a).await?;
        let p = match self.client.resolve_peer(pr).await? {
            Peer::User(u) => {
                let mut v = status_json(u.status());
                v["kind"] = json!("user");
                v["bot"] = json!(u.is_bot());
                // Bot: mô tả (chat trống — trước «Bắt đầu») + lệnh (gợi ý khi gõ «/»)
                if u.is_bot() {
                    if let Ok(i) = Box::pin(self.bot_info(pr)).await {
                        v["bot_info"] = i;
                    }
                }
                return Ok(v);
            }
            p => p,
        };
        let channel = matches!(p, Peer::Channel(_));
        let full = if p.id().kind() == grammers_session::types::PeerKind::Chat {
            self.client.invoke(&functions::messages::GetFullChat { chat_id: p.id().bare_id_unchecked() }).await?
        } else {
            self.client.invoke(&functions::channels::GetFullChannel { channel: pr.into() }).await?
        };
        let enums::messages::ChatFull::Full(f) = full;
        // Thành viên; cảm xúc chat cho thả (app chỉ đưa các emoji này vào bảng chọn)
        // + lệnh của các bot trong nhóm (gợi ý khi gõ «/»)
        let (members, allowed, commands) = match f.full_chat {
            enums::ChatFull::Full(c) => (
                match c.participants {
                    enums::ChatParticipants::Participants(x) => Some(x.participants.len() as i64),
                    _ => None,
                },
                react::allowed_json(c.available_reactions.as_ref()),
                bots::group_commands(c.bot_info.as_deref().unwrap_or(&[])),
            ),
            enums::ChatFull::ChannelFull(c) => (
                c.participants_count.map(i64::from),
                react::allowed_json(c.available_reactions.as_ref()),
                bots::group_commands(&c.bot_info),
            ),
            _ => (None, json!("all"), json!([])),
        };
        let online = if channel {
            None
        } else {
            match self.client.invoke(&functions::messages::GetOnlines { peer: pr.into() }).await {
                Ok(enums::ChatOnlines::Onlines(o)) => Some(o.onlines),
                Err(_) => None,
            }
        };
        Ok(json!({"kind": if channel { "channel" } else { "group" }, "members": members, "online": online,
                  "left": links::is_left(&p), "reactions": allowed, "commands": commands}))
    }

    /// Đang gõ / ghi âm / gửi ảnh… (chat riêng: người gõ = chính chat đó) → `typing`; người đổi trạng thái → `user.status`.
    fn emit_presence(&self, raw: &grammers_client::tl::enums::Update) {
        use grammers_client::tl::enums::Update as U;
        let typing = match raw {
            U::UserTyping(x) => PeerId::user(x.user_id).map(|id| (id, id, &x.action)),
            U::ChatUserTyping(x) => PeerId::chat(x.chat_id).zip(tl_peer_id(&x.from_id)).map(|(c, f)| (c, f, &x.action)),
            U::ChannelUserTyping(x) => PeerId::channel(x.channel_id).zip(tl_peer_id(&x.from_id)).map(|(c, f)| (c, f, &x.action)),
            _ => None,
        };
        if let Some((chat, from, action)) = typing {
            let from_key = peer_key(from);
            let name = lock(NAMES.get_or_init(Default::default)).get(&from_key).cloned();
            (self.emit)(json!({
                "e": "typing",
                "peer": peer_key(chat),
                "from": from_key,
                "name": name,
                "action": typing_action(action),
            }));
        }
        if let U::UserStatus(x) = raw {
            if let Some(id) = PeerId::user(x.user_id) {
                let mut v = status_json(&x.status);
                v["e"] = json!("user.status");
                v["peer"] = json!(peer_key(id));
                (self.emit)(v);
            }
        }
    }

    /// Người / nhóm / kênh từ phản hồi API thô: lưu vào phiên (có mã truy cập → mở chat được), nhớ tên.
    async fn adopt_peers(
        &self,
        users: Vec<grammers_client::tl::enums::User>,
        chats: Vec<grammers_client::tl::enums::Chat>,
    ) -> Vec<Peer> {
        use grammers_session::types::PeerInfo;
        let peers: Vec<Peer> = users
            .into_iter()
            .map(|u| Peer::User(grammers_client::peer::User::from_raw(&self.client, u)))
            .chain(chats.into_iter().map(|c| Peer::from_raw(&self.client, c)))
            .collect();
        let infos: Vec<PeerInfo> = peers
            .iter()
            .map(PeerInfo::from)
            .filter(|i| !matches!(i, PeerInfo::User { auth: None, .. } | PeerInfo::Channel { auth: None, .. }))
            .collect();
        if let Err(e) = self.session.cache_peers(infos).await {
            self.log(&format!("lưu peer: {e}"));
        }
        peers.iter().for_each(remember);
        peers
    }

    /// `contacts.list`: danh bạ Telegram, theo tên.
    async fn contacts_list(&self) -> Res {
        use grammers_client::tl::{enums, functions};
        let enums::contacts::Contacts::Contacts(c) = self.client.invoke(&functions::contacts::GetContacts { hash: 0 }).await? else {
            return Ok(json!([]));
        };
        let mut peers = self.adopt_peers(c.users, vec![]).await;
        peers.sort_by_key(|p| peer_name(p).to_lowercase());
        Ok(Value::Array(peers.iter().map(peer_json).collect()))
    }

    /// `contacts.search`: tìm người / nhóm / kênh trên Telegram theo tên, @tên (danh bạ của mình trước, `mine` = true).
    async fn contacts_search(&self, a: &Value) -> Res {
        use grammers_client::tl::{enums, functions};
        let q = arg_str(a, "q")?.trim().trim_start_matches('@').to_string();
        if q.chars().count() < 2 {
            return Ok(json!([]));
        }
        let limit = a.get("limit").and_then(Value::as_i64).unwrap_or(20) as i32;
        let enums::contacts::Found::Found(f) = self.client.invoke(&functions::contacts::Search { q, limit, bots: true, broadcasts: true }).await?;
        let peers = self.adopt_peers(f.users, f.chats).await;
        let mut out = Vec::new();
        for (mine, list) in [(true, &f.my_results), (false, &f.results)] {
            for tp in list {
                let Some(id) = tl_peer_id(tp) else { continue };
                if let Some(p) = peers.iter().find(|p| p.id() == id) {
                    let mut v = peer_json(p);
                    v["mine"] = json!(mine);
                    out.push(v);
                }
            }
        }
        Ok(Value::Array(out))
    }

    /// `messages.search`: tìm tin theo chữ — trong một chat (`peer`) hoặc mọi chat; mỗi tin kèm `chat_name`.
    async fn messages_search(&self, a: &Value) -> Res {
        let q = arg_str(a, "q")?.trim().to_string();
        if q.is_empty() {
            return Ok(json!([]));
        }
        let limit = a.get("limit").and_then(Value::as_u64).unwrap_or(30) as usize;
        let mut msgs = Vec::new();
        if a.get("peer").and_then(Value::as_str).is_some() {
            let pr = self.peer_ref(a).await?;
            let mut it = self.client.search_messages(pr).query(&q).limit(limit);
            while let Some(m) = it.next().await? {
                msgs.push(m);
            }
        } else {
            let mut it = self.client.search_all_messages().query(&q).limit(limit);
            while let Some(m) = it.next().await? {
                msgs.push(m);
            }
        }
        let out: Vec<Value> = msgs.iter().map(msg_json).collect();
        let names = lock(NAMES.get_or_init(Default::default));
        Ok(Value::Array(
            out.into_iter()
                .map(|mut v| {
                    let chat = v["peer"].as_str().and_then(|p| names.get(p)).cloned();
                    v["chat_name"] = json!(chat);
                    v
                })
                .collect(),
        ))
    }

    /// `chat.info`: màn thông tin chat — như `peer_json` + giới thiệu, tắt tiếng; người: chặn, số nhóm chung; nhóm / kênh:
    /// số thành viên, số đang trực tuyến.
    /// `topics.list`: chủ đề của nhóm diễn đàn theo thứ tự máy chủ (ghim trước, rồi tin mới nhất) — `q` tìm theo tên; `offset`
    /// ({date, id, topic} của chủ đề cuối trang trước: ngày tin cuối, mã tin cuối, mã chủ đề) để tải tiếp.
    async fn topics_list(&self, a: &Value) -> Res {
        use grammers_client::tl::{enums, functions};
        let pr = self.peer_ref(a).await?;
        let limit = a.get("limit").and_then(Value::as_i64).unwrap_or(50).clamp(1, 100) as i32;
        let off = |k: &str| a.get("offset").and_then(|o| o.get(k)).and_then(Value::as_i64).unwrap_or(0) as i32;
        let enums::messages::ForumTopics::Topics(r) = self
            .client
            .invoke(&functions::messages::GetForumTopics {
                peer: pr.into(),
                q: a.get("q").and_then(Value::as_str).filter(|q| !q.is_empty()).map(str::to_string),
                offset_date: off("date"),
                offset_id: off("id"),
                offset_topic: off("topic"),
                limit,
            })
            .await?;
        let peers = self.client.build_peer_map(r.users, r.chats).await;
        let last: std::collections::HashMap<i32, Value> = r
            .messages
            .into_iter()
            .map(|m| Message::from_raw(&self.client, m, Some(pr), peers.handle()))
            .map(|m| (m.id(), msg_json(&m)))
            .collect();
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
        let topics: Vec<Value> = r
            .topics
            .into_iter()
            .filter_map(|t| match t {
                enums::ForumTopic::Topic(t) => {
                    let enums::PeerNotifySettings::Settings(ns) = &t.notify_settings;
                    Some(json!({
                        "id": t.id,
                        "title": t.title,
                        "color": t.icon_color,
                        "emoji": t.icon_emoji_id.is_some(),
                        "closed": t.closed,
                        "pinned": t.pinned,
                        "hidden": t.hidden,
                        "date": t.date,
                        "top": t.top_message,
                        "unread": t.unread_count,
                        "mentions": t.unread_mentions_count,
                        "read_in": t.read_inbox_max_id,
                        "read_out": t.read_outbox_max_id,
                        "muted": ns.mute_until.map(|x| x as i64 > now).unwrap_or(false),
                        "last": last.get(&t.top_message).cloned().unwrap_or(Value::Null),
                    }))
                }
                enums::ForumTopic::Deleted(_) => None,
            })
            .collect();
        self.save_session();
        Ok(json!({"count": r.count, "topics": topics}))
    }

    /// Tin của một chủ đề (mới → cũ) bằng `messages.getReplies` (chủ đề = luồng trả lời tin tạo chủ đề; General id 1). Máy chủ không
    /// nhận General qua getReplies → đọc lịch sử cả nhóm rồi lọc tin không thuộc chủ đề nào (tối đa 5 trang một lần).
    /// Trả {msgs, more, next}: `next` = offset_id cho trang sau (tin cũ nhất đã xét, có thể không nằm trong `msgs`).
    async fn topic_history(&self, pr: PeerRef, topic: i32, offset_id: i32, limit: i32) -> Res {
        use grammers_client::tl::{enums, functions};
        let r = self
            .client
            .invoke(&functions::messages::GetReplies {
                peer: pr.into(),
                msg_id: topic,
                offset_id,
                offset_date: 0,
                add_offset: 0,
                limit,
                max_id: 0,
                min_id: 0,
                hash: 0,
            })
            .await;
        let r = match r {
            Ok(r) => r,
            Err(InvocationError::Rpc(e)) if topic == 1 => {
                self.log(&format!("chủ đề General: getReplies lỗi {} — đọc lịch sử rồi lọc", e.name));
                return Box::pin(self.general_history(pr, offset_id, limit)).await;
            }
            Err(e) => return Err(e.into()),
        };
        let (msgs, users, chats) = match r {
            enums::messages::Messages::Messages(x) => (x.messages, x.users, x.chats),
            enums::messages::Messages::Slice(x) => (x.messages, x.users, x.chats),
            enums::messages::Messages::ChannelMessages(x) => (x.messages, x.users, x.chats),
            enums::messages::Messages::NotModified(_) => (Vec::new(), Vec::new(), Vec::new()),
        };
        let peers = self.client.build_peer_map(users, chats).await;
        let out: Vec<Message> = msgs.into_iter().map(|m| Message::from_raw(&self.client, m, Some(pr), peers.handle())).collect();
        let next = out.iter().map(Message::id).min();
        self.save_session();
        Ok(json!({
            "msgs": out.iter().map(msg_json).collect::<Vec<_>>(),
            "more": out.len() as i32 >= limit,
            "next": next,
        }))
    }

    /// Chủ đề General khi getReplies không nhận: lịch sử cả nhóm, giữ tin không thuộc chủ đề nào (xét tối đa 5 × `limit` tin).
    async fn general_history(&self, pr: PeerRef, offset_id: i32, limit: i32) -> Res {
        let mut it = self.client.iter_messages(pr).limit(limit as usize * 5);
        if offset_id > 0 {
            it = it.offset_id(offset_id);
        }
        let (mut out, mut seen, mut next) = (Vec::new(), 0, None);
        while let Some(m) = it.next().await? {
            seen += 1;
            next = Some(m.id());
            let v = msg_json(&m);
            if v["topic"].is_null() {
                out.push(v);
                if out.len() as i32 >= limit {
                    break;
                }
            }
        }
        Ok(json!({"msgs": out, "more": seen >= limit, "next": next}))
    }

    async fn chat_info(&self, a: &Value) -> Res {
        use grammers_client::tl::{enums, functions};
        let pr = self.peer_ref(a).await?;
        let p = self.client.resolve_peer(pr).await?;
        remember(&p);
        let mut v = peer_json(&p);
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
        let muted = |ns: &enums::PeerNotifySettings| {
            let enums::PeerNotifySettings::Settings(s) = ns;
            s.mute_until.map(|t| t as i64 > now).unwrap_or(false)
        };
        if let Peer::User(_) = &p {
            let enums::users::UserFull::Full(f) = self.client.invoke(&functions::users::GetFullUser { id: pr.into() }).await?;
            let enums::UserFull::Full(u) = f.full_user;
            v["about"] = json!(u.about);
            v["muted"] = json!(muted(&u.notify_settings));
            v["blocked"] = json!(u.blocked);
            v["common_chats"] = json!(u.common_chats_count);
            v["ttl"] = json!(u.ttl_period.unwrap_or(0));
            return Ok(v);
        }
        let full = if p.id().kind() == grammers_session::types::PeerKind::Chat {
            self.client.invoke(&functions::messages::GetFullChat { chat_id: p.id().bare_id_unchecked() }).await?
        } else {
            self.client.invoke(&functions::channels::GetFullChannel { channel: pr.into() }).await?
        };
        let enums::messages::ChatFull::Full(f) = full;
        match f.full_chat {
            enums::ChatFull::Full(c) => {
                v["about"] = json!(c.about);
                v["muted"] = json!(muted(&c.notify_settings));
                v["ttl"] = json!(c.ttl_period.unwrap_or(0));
                if let enums::ChatParticipants::Participants(x) = c.participants {
                    v["members"] = json!(x.participants.len());
                }
            }
            enums::ChatFull::ChannelFull(c) => {
                v["about"] = json!(c.about);
                v["muted"] = json!(muted(&c.notify_settings));
                v["ttl"] = json!(c.ttl_period.unwrap_or(0));
                v["members"] = json!(c.participants_count);
                v["online"] = json!(c.online_count);
                v["can_view_members"] = json!(c.can_view_participants);
            }
            _ => {}
        }
        Ok(v)
    }

    /// `chat.members`: thành viên nhóm (tối đa `limit`, mặc định 200) — kèm `role`: creator | admin | member.
    async fn chat_members(&self, a: &Value) -> Res {
        use grammers_client::peer::Role;
        let pr = self.peer_ref(a).await?;
        let limit = a.get("limit").and_then(Value::as_u64).unwrap_or(200) as usize;
        let mut it = self.client.iter_participants(pr);
        let mut out = Vec::new();
        while out.len() < limit {
            let Some(m) = it.next().await? else { break };
            let p = Peer::User(m.user.clone());
            remember(&p);
            let mut v = peer_json(&p);
            v["role"] = json!(match m.role {
                Role::Creator(_) => "creator",
                Role::Admin(_) => "admin",
                _ => "member",
            });
            out.push(v);
        }
        Ok(Value::Array(out))
    }

    /// `messages.media`: tin đã chia sẻ theo loại — `kind` = photo (ảnh + video) | file | voice | link | music; mới → cũ,
    /// `offset_id` để tải tiếp.
    async fn messages_media(&self, a: &Value) -> Res {
        use grammers_client::tl::enums::MessagesFilter as F;
        let pr = self.peer_ref(a).await?;
        let filter = match a.get("kind").and_then(Value::as_str).unwrap_or("photo") {
            "file" => F::InputMessagesFilterDocument,
            "voice" => F::InputMessagesFilterRoundVoice,
            "link" => F::InputMessagesFilterUrl,
            "music" => F::InputMessagesFilterMusic,
            _ => F::InputMessagesFilterPhotoVideo,
        };
        let limit = a.get("limit").and_then(Value::as_u64).unwrap_or(60) as usize;
        let mut it = self.client.search_messages(pr).filter(filter).limit(limit);
        if let Some(o) = a.get("offset_id").and_then(Value::as_i64) {
            it = it.offset_id(o as i32);
        }
        let mut out = Vec::new();
        while let Some(m) = it.next().await? {
            out.push(msg_json(&m));
        }
        Ok(Value::Array(out))
    }

    /// Bộ sticker (như app Telegram gốc): `stickers.setInfo` (theo id + access_hash hoặc short_name — xem trước một bộ: thông tin +
    /// các sticker), `stickers.install` / `stickers.uninstall`, `stickers.featured` (bộ nổi bật), `stickers.search` (`q` — tìm bộ
    /// theo tên). Bộ trả về kèm `cover` (sticker đại diện, dùng `media.docpreview`).
    async fn sticker_sets(self: &Arc<Self>, method: &str, a: &Value) -> Res {
        use grammers_client::tl::{enums, functions};
        match method {
            "stickers.setInfo" => {
                let set = sticker_set_arg(a)?;
                let enums::messages::StickerSet::Set(s) = self.client.invoke(&functions::messages::GetStickerSet { stickerset: set, hash: 0 }).await? else {
                    return Err(CoreError::new("NOT_FOUND", "Không tìm thấy bộ sticker."));
                };
                let info = set_json(&s.set);
                let items = self.adopt_docs(s.documents);
                Ok(json!({"set": info, "items": items}))
            }
            "stickers.install" => {
                let set = sticker_set_arg(a)?;
                self.client.invoke(&functions::messages::InstallStickerSet { stickerset: set, archived: false }).await?;
                Ok(json!({}))
            }
            "stickers.uninstall" => {
                let set = sticker_set_arg(a)?;
                self.client.invoke(&functions::messages::UninstallStickerSet { stickerset: set }).await?;
                Ok(json!({}))
            }
            "stickers.featured" => {
                let enums::messages::FeaturedStickers::Stickers(f) =
                    self.client.invoke(&functions::messages::GetFeaturedStickers { hash: 0 }).await?
                else {
                    return Ok(json!([]));
                };
                Ok(Value::Array(f.sets.into_iter().map(|c| self.covered_json(c)).collect()))
            }
            _ => {
                let q = a.get("q").and_then(Value::as_str).unwrap_or("").trim().to_string();
                if q.is_empty() {
                    return Ok(json!([]));
                }
                let enums::messages::FoundStickerSets::Sets(f) =
                    self.client.invoke(&functions::messages::SearchStickerSets { exclude_featured: false, q, hash: 0 }).await?
                else {
                    return Ok(json!([]));
                };
                Ok(Value::Array(f.sets.into_iter().map(|c| self.covered_json(c)).collect()))
            }
        }
    }

    /// HTTPS (cập nhật OTA): `http.get` (`url`, `headers`?) → `{code, text}`; `http.download` (`url`, `path`) → tải vào `path`
    /// (qua tệp `.part`), sự kiện `http.progress` {url, done, total} ~3 lần / giây → `{path, size, sha256}`.
    async fn http(self: &Arc<Self>, method: &str, a: &Value) -> Res {
        use sha2::Digest;
        use std::io::Write;
        static CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
        // Chỉ HTTPS, chuyển hướng cũng phải HTTPS (GitHub chuyển tệp phát hành sang máy chủ tệp của nó) — kiểm bảo mật 17/11/2026
        let client = CLIENT.get_or_init(|| {
            reqwest::Client::builder()
                .user_agent(concat!("GramMini/", env!("CARGO_PKG_VERSION")))
                .connect_timeout(Duration::from_secs(20))
                .redirect(reqwest::redirect::Policy::custom(|at| {
                    if at.url().scheme() != "https" {
                        at.error("chuyển hướng sang link không phải https")
                    } else if at.previous().len() > 5 {
                        at.stop()
                    } else {
                        at.follow()
                    }
                }))
                .build()
                .unwrap_or_default()
        });
        let net = |e: reqwest::Error| CoreError::new("NETWORK", format!("Không tải được: {e}"));
        let url = arg_str(a, "url")?.to_string();
        if !url.starts_with("https://") {
            return Err(CoreError::new("BAD_ARGS", "chỉ tải được link https"));
        }
        let mut req = client.get(&url);
        if let Some(h) = a.get("headers").and_then(Value::as_object) {
            for (k, v) in h {
                if let Some(v) = v.as_str() {
                    req = req.header(k.as_str(), v);
                }
            }
        }
        if method == "http.get" {
            let mut resp = req.timeout(Duration::from_secs(40)).send().await.map_err(net)?;
            let code = resp.status().as_u16();
            let mut body = Vec::new();
            while let Some(c) = resp.chunk().await.map_err(net)? {
                body.extend_from_slice(&c);
                if body.len() > MAX_HTTP_TEXT {
                    return Err(CoreError::new("HTTP", "Trả lời quá lớn."));
                }
            }
            return Ok(json!({"code": code, "text": String::from_utf8_lossy(&body)}));
        }
        let path = std::path::PathBuf::from(arg_str(a, "path")?);
        let mut resp = req.send().await.map_err(net)?;
        if !resp.status().is_success() {
            return Err(CoreError::new("HTTP", format!("Máy chủ trả HTTP {}", resp.status().as_u16())));
        }
        let total = resp.content_length().unwrap_or(0);
        let io = |e: std::io::Error| CoreError::new("IO", e.to_string());
        if total > MAX_HTTP_DOWNLOAD {
            return Err(CoreError::new("HTTP", "Tệp quá lớn."));
        }
        // Tệp tạm tạo mới, chỉ app đọc ghi (không theo liên kết tượng trưng có sẵn ở tên đoán trước được)
        let tmp = path.with_extension("part");
        let _ = std::fs::remove_file(&tmp);
        let mut f = {
            let mut o = std::fs::OpenOptions::new();
            o.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                o.mode(0o600);
            }
            o.open(&tmp).map_err(io)?
        };
        let mut hasher = sha2::Sha256::new();
        let (mut done, mut last) = (0u64, Instant::now());
        loop {
            let chunk = tokio::time::timeout(Duration::from_secs(60), resp.chunk())
                .await
                .map_err(|_| CoreError::new("TIMEOUT", "Tải bị treo quá 60 giây."))?
                .map_err(net)?;
            let Some(chunk) = chunk else { break };
            f.write_all(&chunk).map_err(io)?;
            hasher.update(&chunk);
            done += chunk.len() as u64;
            if done > MAX_HTTP_DOWNLOAD {
                drop(f);
                let _ = std::fs::remove_file(&tmp);
                return Err(CoreError::new("HTTP", "Tệp quá lớn."));
            }
            if last.elapsed() > Duration::from_millis(300) {
                (self.emit)(json!({"e": "http.progress", "url": url, "done": done, "total": total}));
                last = Instant::now();
            }
        }
        drop(f);
        std::fs::rename(&tmp, &path).map_err(io)?;
        let sha: String = hasher.finalize().iter().map(|b| format!("{b:02x}")).collect();
        Ok(json!({"path": path, "size": done, "sha256": sha}))
    }

    /// Thư mục chat (dialog filters — đồng bộ với tài khoản như app Telegram gốc): `folders.list`, `folders.suggested` (gợi ý của
    /// Telegram), `folders.save` (tạo / sửa — không có `id` thì tạo mới), `folders.delete` (`id`), `folders.order` (`order`: [id]).
    /// Chat trong thư mục: `include` / `exclude` / `pinned` là khoá peer (của mình: "self"); app tự lọc danh sách chat theo các
    /// cờ loại chat + loại trừ (như Telegram gốc).
    async fn folders(self: &Arc<Self>, method: &str, a: &Value) -> Res {
        use grammers_client::tl::{enums, functions, types};
        match method {
            "folders.list" => {
                let enums::messages::DialogFilters::Filters(f) = self.client.invoke(&functions::messages::GetDialogFilters {}).await?;
                Ok(Value::Array(f.filters.iter().filter_map(folder_json).collect()))
            }
            "folders.suggested" => {
                let list = self.client.invoke(&functions::messages::GetSuggestedDialogFilters {}).await?;
                Ok(Value::Array(
                    list.into_iter()
                        .filter_map(|s| {
                            let enums::DialogFilterSuggested::Suggested(s) = s;
                            let mut v = folder_json(&s.filter)?;
                            v["description"] = json!(s.description);
                            Some(v)
                        })
                        .collect(),
                ))
            }
            "folders.delete" => {
                let id = a.get("id").and_then(Value::as_i64).ok_or_else(|| CoreError::new("BAD_ARGS", "thiếu «id»"))? as i32;
                self.client.invoke(&functions::messages::UpdateDialogFilter { id, filter: None }).await?;
                Ok(json!({}))
            }
            "folders.order" => {
                let order: Vec<i32> = a.get("order").and_then(Value::as_array).map(|v| v.iter().filter_map(Value::as_i64).map(|x| x as i32).collect()).unwrap_or_default();
                self.client.invoke(&functions::messages::UpdateDialogFiltersOrder { order }).await?;
                Ok(json!({}))
            }
            _ => {
                // folders.save: id mới = lớn nhất + 1 (Telegram dùng 2…255; 0 / 1 dành cho «Tất cả» / lưu trữ)
                let id = match a.get("id").and_then(Value::as_i64) {
                    Some(id) => id as i32,
                    None => {
                        let enums::messages::DialogFilters::Filters(f) = self.client.invoke(&functions::messages::GetDialogFilters {}).await?;
                        let max = f.filters.iter().filter_map(|x| folder_json(x)?.get("id")?.as_i64()).max().unwrap_or(1);
                        (max + 1).max(2) as i32
                    }
                };
                let title = a.get("title").and_then(Value::as_str).unwrap_or("").trim().to_string();
                if title.is_empty() {
                    return Err(CoreError::new("BAD_ARGS", "Thư mục cần có tên."));
                }
                let flag = |k: &str| a.get(k).and_then(Value::as_bool).unwrap_or(false);
                let peers = |k: &str| {
                    let keys: Vec<String> = a.get(k).and_then(Value::as_array).map(|v| v.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
                    keys
                };
                let (inc, exc, pin) = (peers("include"), peers("exclude"), peers("pinned"));
                let include_peers = self.input_peers(&inc).await?;
                let exclude_peers = self.input_peers(&exc).await?;
                let pinned_peers = self.input_peers(&pin).await?;
                let (contacts, non_contacts, groups, broadcasts, bots) = (flag("contacts"), flag("non_contacts"), flag("groups"), flag("broadcasts"), flag("bots"));
                if !(contacts || non_contacts || groups || broadcasts || bots) && include_peers.is_empty() && pinned_peers.is_empty() {
                    return Err(CoreError::new("FILTER_EMPTY", "Chọn ít nhất một loại chat hoặc thêm một chat vào thư mục."));
                }
                let filter = types::DialogFilter {
                    contacts,
                    non_contacts,
                    groups,
                    broadcasts,
                    bots,
                    exclude_muted: flag("exclude_muted"),
                    exclude_read: flag("exclude_read"),
                    exclude_archived: flag("exclude_archived"),
                    title_noanimate: false,
                    id,
                    title: enums::TextWithEntities::Entities(types::TextWithEntities { text: title, entities: vec![] }),
                    emoticon: a.get("emoticon").and_then(Value::as_str).filter(|s| !s.is_empty()).map(String::from),
                    color: None,
                    pinned_peers,
                    include_peers,
                    exclude_peers,
                };
                self.client.invoke(&functions::messages::UpdateDialogFilter { id, filter: Some(filter.into()) }).await?;
                Ok(json!({"id": id}))
            }
        }
    }

    /// Khoá peer → InputPeer (peer phải đã gặp — có trong danh sách chat). "self" = mình.
    async fn input_peers(&self, keys: &[String]) -> Result<Vec<grammers_client::tl::enums::InputPeer>, CoreError> {
        let mut out = Vec::new();
        for k in keys {
            if k == "self" {
                out.push(grammers_client::tl::enums::InputPeer::PeerSelf);
                continue;
            }
            let pr = self.peer_ref(&json!({"peer": k})).await?;
            out.push(pr.into());
        }
        Ok(out)
    }

    /// Bộ sticker kèm sticker đại diện (`cover`, giữ tài liệu để tải ảnh xem trước).
    fn covered_json(&self, c: grammers_client::tl::enums::StickerSetCovered) -> Value {
        use grammers_client::tl::enums::StickerSetCovered as K;
        let (set, cover) = match c {
            K::Covered(c) => (c.set, Some(c.cover)),
            K::StickerSetMultiCovered(c) => (c.set, c.covers.into_iter().next()),
            K::StickerSetFullCovered(c) => (c.set, c.documents.into_iter().next()),
            K::StickerSetNoCovered(c) => (c.set, None),
        };
        let mut v = set_json(&set);
        if let Some(d) = cover {
            if let Some(r) = self.adopt_docs(vec![d]).as_array().and_then(|x| x.first()).cloned() {
                v["cover"] = r;
            }
        }
        v
    }

    /// Giữ tài liệu sticker / GIF (để gửi lại, tải ảnh xem trước), trả danh sách cho app.
    fn adopt_docs(&self, docs: Vec<grammers_client::tl::enums::Document>) -> Value {
        use grammers_client::tl::enums;
        let mut map = lock(&self.docs);
        let mut out = Vec::new();
        for d in docs {
            let enums::Document::Document(d) = d else { continue };
            out.push(doc_ref_json(&d));
            map.insert(d.id, d);
        }
        Value::Array(out)
    }

    /// `media.docpreview`: ảnh xem trước của sticker / GIF (`doc`) — sticker tĩnh WebP: cả tệp → PNG; sticker động (TGS / WebM),
    /// GIF (MP4): ảnh thu nhỏ lớn nhất. Đệm ở `media/k<mã>.png`.
    async fn doc_preview(self: &Arc<Self>, a: &Value) -> Res {
        use grammers_client::tl::{enums, types};
        let id = doc_id_arg(a)?;
        let path = self.cfg.data_dir.join("media").join(format!("k{id}.png"));
        if self.cache.hit(&path) {
            return Ok(json!({"path": path}));
        }
        let d = lock(&self.docs).get(&id).cloned().ok_or_else(|| CoreError::new("NO_DOC", "Không còn sticker này."))?;
        let full = d.mime_type == "image/webp";
        let thumb = if full {
            String::new()
        } else {
            let best = d.thumbs.iter().flatten().filter_map(|t| match t {
                enums::PhotoSize::Size(s) => Some((s.r#type.clone(), s.w * s.h)),
                enums::PhotoSize::Progressive(s) => Some((s.r#type.clone(), s.w * s.h)),
                _ => None,
            });
            best.max_by_key(|x| x.1).map(|x| x.0).ok_or_else(|| CoreError::new("NO_MEDIA", "Không có ảnh xem trước."))?
        };
        let loc = crate::media::Loc {
            loc: types::InputDocumentFileLocation { id: d.id, access_hash: d.access_hash, file_reference: d.file_reference.clone(), thumb_size: thumb }
                .into(),
            dc: Some(d.dc_id),
            size: if full { Some(d.size as usize) } else { None },
        };
        let _permit = self.dl.acquire().await.map_err(|_| CoreError::new("BUSY", "hàng tải đã đóng"))?;
        let raw = path.with_extension("bin");
        self.download(&loc, &raw).await?;
        let data = std::fs::read(&raw).map_err(|e| CoreError::new("IO", e.to_string()))?;
        let _ = std::fs::remove_file(&raw);
        crate::media::to_png(&data, &path).map_err(|e| CoreError::new("DECODE", format!("Không đọc được ảnh sticker: {e}")))?;
        Ok(json!({"path": path}))
    }

    /// `account.privacy`: ai thấy / làm được gì — mỗi khoá: `value` (everybody | contacts | nobody), số ngoại lệ cho phép / chặn.
    async fn privacy_get(&self) -> Res {
        use grammers_client::tl::{enums, functions};
        let mut out = serde_json::Map::new();
        for key in ["status", "phone", "photo", "forwards", "calls", "invites"] {
            let Some(k) = privacy_key(key) else { continue };
            let enums::account::PrivacyRules::Rules(r) = self.client.invoke(&functions::account::GetPrivacy { key: k }).await?;
            let (mut value, mut allow, mut deny) = ("nobody", 0usize, 0usize);
            for rule in &r.rules {
                use enums::PrivacyRule as P;
                match rule {
                    P::PrivacyValueAllowAll => value = "everybody",
                    P::PrivacyValueAllowContacts if value != "everybody" => value = "contacts",
                    P::PrivacyValueAllowUsers(u) => allow += u.users.len(),
                    P::PrivacyValueDisallowUsers(u) => deny += u.users.len(),
                    P::PrivacyValueAllowChatParticipants(c) => allow += c.chats.len(),
                    P::PrivacyValueDisallowChatParticipants(c) => deny += c.chats.len(),
                    _ => {}
                }
            }
            out.insert(key.to_string(), json!({"value": value, "allow": allow, "deny": deny}));
        }
        Ok(Value::Object(out))
    }

    /// `groups.create`: nhóm thường (`title`, `users`: khoá peer người dùng) — trả `{peer, name, kind, missing}` (missing: người
    /// không thêm được vì quyền riêng tư của họ).
    async fn group_create(&self, a: &Value) -> Res {
        use grammers_client::tl::{enums, functions};
        let title = arg_str(a, "title")?.trim().to_string();
        if title.is_empty() {
            return Err(CoreError::new("BAD_ARGS", "Chưa đặt tên nhóm."));
        }
        let keys: Vec<String> =
            a.get("users").and_then(Value::as_array).map(|v| v.iter().filter_map(Value::as_str).map(str::to_string).collect()).unwrap_or_default();
        if keys.is_empty() {
            return Err(CoreError::new("BAD_ARGS", "Chọn ít nhất một người."));
        }
        let mut users = Vec::new();
        for k in &keys {
            let pr = self.peer_ref_of(&json!({"peer": k}), "peer").await?;
            users.push(enums::InputUser::from(pr));
        }
        let enums::messages::InvitedUsers::Users(r) =
            self.client.invoke(&functions::messages::CreateChat { users, title: title.clone(), ttl_period: None }).await?;
        let chats = match r.updates {
            enums::Updates::Updates(u) => u.chats,
            enums::Updates::Combined(u) => u.chats,
            _ => Vec::new(),
        };
        let peers = self.adopt_peers(Vec::new(), chats).await;
        let p = peers.first().ok_or_else(|| CoreError::new("NO_CHAT", "Đã tạo nhóm nhưng không đọc được — tải lại danh sách chat."))?;
        let mut v = peer_json(p);
        v["missing"] = json!(r.missing_invitees.len());
        self.log(&format!("tạo nhóm: {} người", keys.len()));
        Ok(v)
    }

    /// Tự dọn bộ nhớ đệm ở luồng blocking (một lượt một lúc; không `force` thì cách lượt trước ≥ 1 phút). Có xoá thì báo
    /// app (`cache.cleared`) để quên đường dẫn cũ.
    fn trim_soon(self: &Arc<Self>, force: bool) {
        if !self.cache.begin(force) {
            return;
        }
        let c = Arc::clone(self);
        tokio::task::spawn_blocking(move || {
            let t = Instant::now();
            let r = crate::cache::trim(&c.cfg.data_dir, c.cache.policy());
            c.cache.end();
            if r.files > 0 {
                c.log(&format!(
                    "dọn đệm: xoá {} tệp ({} KB), còn {} KB, {} ms",
                    r.files,
                    r.freed >> 10,
                    r.total >> 10,
                    t.elapsed().as_millis()
                ));
                (c.emit)(json!({"e": "cache.cleared"}));
            }
        });
    }

    /// Đổi trạng thái mạng; đẩy sự kiện `net.state` khi đổi.
    fn set_net(&self, ok: bool) {
        let new = if ok { 1 } else { 2 };
        if self.net.swap(new, std::sync::atomic::Ordering::Relaxed) != new {
            self.log(if ok { "mạng: kết nối được" } else { "mạng: mất kết nối" });
            (self.emit)(json!({"e": "net.state", "ok": ok}));
        }
    }

    /// Hỏi thử máy chủ (lỗi RPC vẫn là kết nối được).
    async fn check_net(&self) -> bool {
        let r = tokio::time::timeout(
            Duration::from_secs(8),
            self.client.invoke(&grammers_client::tl::functions::updates::GetState {}),
        )
        .await;
        let ok = matches!(r, Ok(Ok(_)) | Ok(Err(InvocationError::Rpc(_))));
        self.set_net(ok);
        ok
    }

    /// Ghi nhật ký lõi (không ghi nội dung tin nhắn / số điện thoại).
    pub fn log(&self, line: &str) {
        if let Some(f) = lock(&self.log).as_mut() {
            let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
            let _ = writeln!(f, "{t} {line}");
        }
    }

    /// `settings.json` (đối tượng JSON; hỏng / chưa có thì rỗng).
    fn settings(dir: &std::path::Path) -> serde_json::Map<String, Value> {
        std::fs::read(dir.join("settings.json"))
            .ok()
            .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
            .and_then(|v| match v {
                Value::Object(m) => Some(m),
                _ => None,
            })
            .unwrap_or_default()
    }

    /// Ghi các khoá vào `settings.json` (giữ khoá khác; ghi tệp tạm rồi đổi tên).
    fn save_settings(&self, kv: &[(&str, Value)]) -> Result<(), CoreError> {
        let mut m = Self::settings(&self.cfg.data_dir);
        for (k, v) in kv {
            m.insert(k.to_string(), v.clone());
        }
        crate::session::write_private(&self.cfg.data_dir.join("settings.json"), "json.part", Value::Object(m).to_string().as_bytes())
            .map_err(|e| CoreError::new("IO", format!("ghi cài đặt: {e}")))
    }

    fn load_proxy(dir: &std::path::Path) -> ProxyConfig {
        Self::settings(dir)
            .get("proxy")
            .and_then(Value::as_str)
            .and_then(|l| gm_net::parse_link(l).ok())
            .unwrap_or_default()
    }

    fn load_policy(dir: &std::path::Path) -> crate::cache::Policy {
        let m = Self::settings(dir);
        let d = crate::cache::Policy::default();
        crate::cache::Policy {
            limit_mb: m.get("cache_limit_mb").and_then(Value::as_u64).unwrap_or(d.limit_mb),
            keep_days: m.get("cache_keep_days").and_then(Value::as_u64).unwrap_or(d.keep_days),
        }
    }

    fn save_proxy(&self, link: Option<&str>) -> Result<(), CoreError> {
        self.save_settings(&[("proxy", json!(link))])
    }

    fn save_session(&self) {
        if let Err(e) = self.session.save() {
            self.log(&format!("ghi phiên: {e}"));
        }
    }

    /// Nghe cập nhật (một lần): đẩy tin mới / sửa / xoá lên app.
    fn start_updates(self: &Arc<Self>) {
        let Some(rx) = lock(&self.updates).take() else { return };
        let c = Arc::clone(self);
        tokio::spawn(async move {
            let mut stream = match c.client.stream_updates(rx, UpdatesConfiguration { catch_up: true }).await {
                Ok(s) => s,
                Err(e) => {
                    c.log(&format!("stream_updates: {e}"));
                    return;
                }
            };
            c.log("bắt đầu nghe cập nhật");
            let mut last_save = Instant::now();
            loop {
                match tokio::time::timeout(Duration::from_secs(30), stream.next()).await {
                    Ok(Ok(u)) => match u {
                        Update::NewMessage(m) => (c.emit)(json!({"e": "msg.new", "msg": msg_json(&m)})),
                        Update::MessageEdited(m) => (c.emit)(json!({"e": "msg.edit", "msg": msg_json(&m)})),
                        Update::MessageDeleted(d) => (c.emit)(json!({
                            "e": "msg.delete",
                            "ids": d.messages(),
                            "channel": d.channel_id().and_then(|id| PeerId::channel(id)).and_then(|p| p.bot_api_dialog_id()).map(|i| i.to_string()),
                        })),
                        Update::Raw(r) => {
                            use grammers_client::tl::enums::{Peer as TlPeer, Update as U};
                            let read = match &r.raw {
                                U::ReadHistoryOutbox(x) => {
                                    let id = match &x.peer {
                                        TlPeer::User(p) => PeerId::user(p.user_id),
                                        TlPeer::Chat(p) => PeerId::chat(p.chat_id),
                                        TlPeer::Channel(p) => PeerId::channel(p.channel_id),
                                    };
                                    id.map(|id| (peer_key(id), x.max_id))
                                }
                                U::ReadChannelOutbox(x) => PeerId::channel(x.channel_id).map(|id| (peer_key(id), x.max_id)),
                                _ => None,
                            };
                            if let Some((peer, max_id)) = read {
                                (c.emit)(json!({"e": "msg.readOutbox", "peer": peer, "max_id": max_id}));
                            }
                            c.emit_presence(&r.raw);
                            c.emit_extra(&r.raw);
                            c.emit_poll(&r.raw);
                            c.emit_pins(&r.raw);
                        }
                        _ => {}
                    },
                    Ok(Err(e)) => {
                        c.log(&format!("cập nhật lỗi: {e}"));
                        if c.check_dead(&CoreError::from(e).code) {
                            break;  // phiên chết: thôi nghe cập nhật (khỏi hỏi lại máy chủ mãi)
                        }
                        c.set_net(false);
                        tokio::time::sleep(Duration::from_secs(2)).await;
                    }
                    Err(_) => {}
                }
                if last_save.elapsed() > Duration::from_secs(30) {
                    let _ = stream.sync_update_state().await;
                    c.save_session();
                    last_save = Instant::now();
                }
            }
        });
    }

    async fn peer_ref(&self, a: &Value) -> Result<PeerRef, CoreError> {
        self.peer_ref_of(a, "peer").await
    }

    async fn peer_ref_of(&self, a: &Value, field: &str) -> Result<PeerRef, CoreError> {
        let key = arg_str(a, field)?;
        let id = key
            .parse::<i64>()
            .ok()
            .and_then(PeerId::from_bot_api_dialog_id)
            .ok_or_else(|| CoreError::new("BAD_ARGS", "khoá peer sai"))?;
        self.session
            .peer_ref(id)
            .await
            .ok()
            .flatten()
            .ok_or_else(|| CoreError::new("PEER_UNKNOWN", "Chưa biết chat này — tải lại danh sách chat."))
    }

    /// Gọi một lệnh. Xem docs/FFI.md.
    pub async fn call(self: &Arc<Self>, method: &str, a: Value) -> Res {
        let t = Instant::now();
        // Trạng thái của `dispatch` gộp mọi nhánh (kiểu TL to) — để trên heap, khỏi tràn ngăn xếp luồng (Windows 1 MB, tokio 2 MB)
        let r = Box::pin(self.dispatch(method, &a)).await;
        let ms = t.elapsed().as_millis();
        // Không nói gì về kết nối chính tới Telegram: bản đồ (DC web / OpenStreetMap — một ô treo không phải mất mạng) và
        // `net.state` (chỉ đọc; đổi trạng thái sau khi đọc → app nhận sự kiện «được» trước câu trả lời «mất», kẹt «đang kết nối…»)
        let side = method == "net.state" || method.starts_with("map.");
        match &r {
            _ if side => {}
            Ok(_) => {
                self.set_net(true);
                if !lock(&self.outbox).is_empty() {
                    self.flush_outbox();
                }
            }
            Err(e) if e.code == "NETWORK" || e.code == "TIMEOUT" => self.set_net(false),
            Err(_) => {}
        }
        match &r {
            Ok(_) => self.log(&format!("{method}: xong {ms} ms")),
            Err(e) => self.log(&format!("{method}: lỗi {} sau {ms} ms", e.code)),
        }
        r
    }

    async fn dispatch(self: &Arc<Self>, method: &str, a: &Value) -> Res {
        match method {
            "auth.state" => {
                if self.dead.load(std::sync::atomic::Ordering::Relaxed) {
                    return Ok(json!({"authorized": false, "dead": true}));
                }
                let ok = match self.client.is_authorized().await {
                    Ok(v) => v,
                    Err(e) => {
                        let ce = CoreError::from(e);
                        if self.check_dead(&ce.code) {
                            return Ok(json!({"authorized": false, "dead": true}));
                        }
                        return Err(ce);
                    }
                };
                if !ok {
                    return Ok(json!({"authorized": false}));
                }
                let me = self.client.get_me().await?;
                Ok(json!({"authorized": true, "me": user_json(&me)}))
            }
            "auth.sendCode" => {
                let phone = arg_str(a, "phone")?;
                let token = self.client.request_login_code(phone, &self.cfg.api_hash).await?;
                *lock(&self.login) = Some(token);
                Ok(json!({}))
            }
            "auth.signIn" => {
                let code = arg_str(a, "code")?;
                let token = lock(&self.login).take().ok_or_else(|| CoreError::new("NO_CODE", "Chưa gửi mã."))?;
                match self.client.sign_in(&token, code).await {
                    Ok(me) => self.signed_in(&me),
                    Err(SignInError::PasswordRequired(p)) => {
                        let hint = p.hint().unwrap_or("").to_string();
                        *lock(&self.password) = Some(p);
                        let mut e = CoreError::new("PASSWORD_NEEDED", "Tài khoản có mật khẩu 2 lớp.");
                        e.extra = json!({"hint": hint});
                        Err(e)
                    }
                    Err(SignInError::InvalidCode) => {
                        *lock(&self.login) = Some(token); // cho nhập lại
                        Err(CoreError::new("PHONE_CODE_INVALID", "Mã không đúng."))
                    }
                    Err(SignInError::SignUpRequired) => Err(CoreError::new(
                        "SIGN_UP_REQUIRED",
                        "Số này chưa có tài khoản Telegram — đăng ký bằng app Telegram chính thức trước.",
                    )),
                    Err(SignInError::Other(e)) => Err(e.into()),
                    Err(e) => Err(CoreError::new("SIGN_IN", e.to_string())),
                }
            }
            "auth.checkPassword" => {
                let pw = arg_str(a, "password")?;
                let token = lock(&self.password).take().ok_or_else(|| CoreError::new("NO_PASSWORD", "Không cần mật khẩu."))?;
                // Thông số SRP (srp_id) chỉ dùng được một lần: sai mật khẩu / SRP_ID_INVALID → xin thông số mới
                // (grammers trả lại đúng token cũ khi sai mật khẩu — dùng lại thì lần sau dù đúng vẫn bị SRP_ID_INVALID)
                let mut r = self.client.check_password(token, pw).await;
                if matches!(&r, Err(SignInError::Other(e)) if e.is("SRP_ID_INVALID")) {
                    let fresh = self.password_token().await?;
                    r = self.client.check_password(fresh, pw).await;
                }
                match r {
                    Ok(me) => self.signed_in(&me),
                    Err(SignInError::InvalidPassword(t)) => {
                        *lock(&self.password) = Some(self.password_token().await.unwrap_or(t));
                        Err(CoreError::new("PASSWORD_INVALID", "Mật khẩu không đúng."))
                    }
                    Err(SignInError::Other(e)) => {
                        if let Ok(t) = self.password_token().await {
                            *lock(&self.password) = Some(t);  // cho nhập lại
                        }
                        Err(e.into())
                    }
                    Err(e) => Err(CoreError::new("SIGN_IN", e.to_string())),
                }
            }
            "auth.logout" => {
                let _ = self.client.sign_out().await;
                self.save_session();
                (self.emit)(json!({"e": "auth.state", "authorized": false}));
                Ok(json!({}))
            }
            "proxy.get" => {
                let link = Self::settings(&self.cfg.data_dir).get("proxy").cloned().unwrap_or(Value::Null);
                Ok(json!({"link": link}))
            }
            "proxy.set" => {
                let link = a.get("link").and_then(Value::as_str).filter(|s| !s.trim().is_empty());
                let cfg = match link {
                    Some(l) => gm_net::parse_link(l).map_err(|e| CoreError::new("PROXY_LINK", e))?,
                    None => ProxyConfig::Direct,
                };
                self.save_proxy(link)?;
                self.conn.set(cfg);
                // Kết nối cũ đi đường cũ: ngắt để mở lại theo cấu hình mới
                for dc in 1..=5 {
                    self.handle.disconnect_from_dc(dc);
                }
                Ok(json!({}))
            }
            "proxy.test" => {
                let cfg = match a.get("link").and_then(Value::as_str).filter(|s| !s.trim().is_empty()) {
                    Some(l) => gm_net::parse_link(l).map_err(|e| CoreError::new("PROXY_LINK", e))?,
                    None => ProxyConfig::Direct,
                };
                let conn = GmConnector::new(cfg);
                let t = Instant::now();
                let addr = ServerAddr::Custom { dc_id: 2, address: "149.154.167.41:443".parse().unwrap(), connector: conn.clone() };
                tokio::time::timeout(Duration::from_secs(25), grammers_mtsender::connect(conn.transport(), addr))
                    .await
                    .map_err(|_| CoreError::new("TIMEOUT", "Quá 25 giây không kết nối được."))?
                    .map_err(|e| CoreError::new("PROXY_FAIL", e.to_string()))?;
                Ok(json!({"ms": t.elapsed().as_millis() as u64}))
            }
            "dialogs.list" => {
                let limit = a.get("limit").and_then(Value::as_u64).unwrap_or(50) as usize;
                let mut it = self.client.iter_dialogs();
                let mut out = Vec::new();
                while out.len() < limit {
                    let Some(d) = it.next().await? else { break };
                    let now = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.as_secs() as i64)
                        .unwrap_or(0);
                    let (unread, pinned, read_in, read_out, muted, archived, marked) = match &d.raw {
                        grammers_client::tl::enums::Dialog::Dialog(x) => {
                            let grammers_client::tl::enums::PeerNotifySettings::Settings(ns) = &x.notify_settings;
                            let muted = ns.mute_until.map(|t| t as i64 > now).unwrap_or(false);
                            (x.unread_count, x.pinned, x.read_inbox_max_id, x.read_outbox_max_id, muted, x.folder_id == Some(1), x.unread_mark)
                        }
                        _ => (0, false, 0, 0, false, false, false),
                    };
                    let (contact, bot) = match d.peer() {
                        Peer::User(u) => (u.contact(), u.is_bot()),
                        _ => (false, false),
                    };
                    remember(d.peer());
                    let (photo, photo_dc) = peer_photo(d.peer());
                    out.push(json!({
                        "photo": photo,
                        "photo_dc": photo_dc,
                        "peer": peer_key(d.peer().id()),
                        "name": peer_name(d.peer()),
                        "kind": peer_kind(d.peer()),
                        "unread": unread,
                        "pinned": pinned,
                        "muted": muted,
                        "read_in": read_in,
                        "read_out": read_out,
                        "contact": contact,
                        "bot": bot,
                        "archived": archived,
                        "marked_unread": marked,
                        // Nhóm có chủ đề (diễn đàn): app mở danh sách chủ đề («Tất cả» = xem mọi tin như nhóm thường)
                        "forum": is_forum(d.peer()),
                        "last": d.last_message.as_ref().map(msg_json),
                    }));
                }
                self.save_session();
                Ok(Value::Array(out))
            }
            "messages.history" => {
                let peer = self.peer_ref(a).await?;
                let limit = a.get("limit").and_then(Value::as_u64).unwrap_or(40) as usize;
                if let Some(topic) = a.get("topic").and_then(Value::as_i64) {
                    let off = a.get("offset_id").and_then(Value::as_i64).unwrap_or(0) as i32;
                    return Box::pin(self.topic_history(peer, topic as i32, off, limit as i32)).await;
                }
                let mut it = self.client.iter_messages(peer).limit(limit);
                if let Some(off) = a.get("offset_id").and_then(Value::as_i64).filter(|x| *x > 0) {
                    it = it.offset_id(off as i32);
                }
                let mut out = Vec::new();
                while let Some(m) = it.next().await? {
                    out.push(msg_json(&m));
                }
                self.save_session();
                Ok(Value::Array(out))
            }
            "messages.send" => {
                // `queue`: mất mạng thì để vào hàng chờ, có mạng tự gửi (sự kiện outbox.sent / outbox.failed)
                let queue = a.get("queue").and_then(Value::as_bool).unwrap_or(false) && a.get("schedule").is_none();
                match Box::pin(self.send_text(a)).await {
                    Err(e) if queue && is_net_error(&e) => self.enqueue(a),
                    r => r,
                }
            }
            "debug.offline" => {
                // Thử hàng chờ: tạm đi qua proxy chết (không lưu cài đặt); on=false → trở lại cấu hình đã lưu
                let on = a.get("on").and_then(Value::as_bool).unwrap_or(true);
                let cfg = if on {
                    gm_net::parse_link("tg://socks?server=127.0.0.1&port=9").map_err(|e| CoreError::new("PROXY_LINK", e))?
                } else {
                    Self::load_proxy(&self.cfg.data_dir)
                };
                self.conn.set(cfg);
                for dc in 1..=5 {
                    self.handle.disconnect_from_dc(dc);
                }
                Ok(json!({"offline": on}))
            }
            "outbox.list" => {
                let peer = a.get("peer").and_then(Value::as_str);
                let items: Vec<Value> =
                    lock(&self.outbox).iter().filter(|i| peer.is_none_or(|p| i["peer"].as_str() == Some(p))).cloned().collect();
                Ok(Value::Array(items))
            }
            "outbox.cancel" => {
                let id = a.get("local_id").and_then(Value::as_i64).ok_or_else(|| CoreError::new("BAD_ARGS", "thiếu «local_id»"))?;
                lock(&self.outbox).retain(|i| i["local_id"].as_i64() != Some(id));
                self.save_outbox();
                Ok(json!({}))
            }
            "messages.edit" => {
                let peer = self.peer_ref(a).await?;
                let id = a.get("id").and_then(Value::as_i64).ok_or_else(|| CoreError::new("BAD_ARGS", "thiếu «id»"))?;
                let text = arg_str(a, "text")?;
                match self.client.edit_message(peer, id as i32, text).await {
                    Ok(()) => Ok(json!({})),
                    // Chữ mới giống chữ cũ: coi như đã sửa
                    Err(InvocationError::Rpc(r)) if r.name == "MESSAGE_NOT_MODIFIED" => Ok(json!({})),
                    Err(e) => Err(e.into()),
                }
            }
            "messages.delete" => {
                let peer = self.peer_ref(a).await?;
                let ids: Vec<i32> = a
                    .get("ids")
                    .and_then(Value::as_array)
                    .map(|v| v.iter().filter_map(Value::as_i64).map(|x| x as i32).collect())
                    .unwrap_or_default();
                if ids.is_empty() {
                    return Err(CoreError::new("BAD_ARGS", "thiếu «ids»"));
                }
                // revoke (mặc định có): xoá cho cả hai bên / mọi người; không: chỉ xoá phía mình (chat riêng, nhóm thường — kênh /
                // siêu nhóm thì luôn xoá cho mọi người)
                let revoke = a.get("revoke").and_then(Value::as_bool).unwrap_or(true);
                if !revoke && peer.id.kind() != grammers_session::types::PeerKind::Channel {
                    use grammers_client::tl::{enums, functions};
                    let enums::messages::AffectedMessages::Messages(r) =
                        self.client.invoke(&functions::messages::DeleteMessages { revoke: false, id: ids }).await?;
                    return Ok(json!({"deleted": r.pts_count}));
                }
                let n = self.client.delete_messages(peer, &ids).await?;
                Ok(json!({"deleted": n}))
            }
            "media.photo" => {
                let peer = self.peer_ref(a).await?;
                let id = a.get("id").and_then(Value::as_i64).ok_or_else(|| CoreError::new("BAD_ARGS", "thiếu «id»"))?;
                let big = a.get("big").and_then(Value::as_bool).unwrap_or(false);
                let dir = self.cfg.data_dir.join("media");
                let path = dir.join(format!("p{}_{}_{}.jpg", arg_str(a, "peer")?, id, if big { "y" } else { "m" }));
                if self.cache.hit(&path) {
                    return Ok(json!({"path": path}));
                }
                let _permit = self.dl.acquire().await.map_err(|_| CoreError::new("BUSY", "hàng tải đã đóng"))?;
                let msg = self.client.get_messages_by_id(peer, &[id as i32]).await?.into_iter().flatten().next();
                let Some(Media::Photo(p)) = msg.as_ref().and_then(|m| m.media()) else {
                    return Err(CoreError::new("NO_MEDIA", "Tin này không còn ảnh."));
                };
                let loc = crate::media::pick(&p, big).ok_or_else(|| CoreError::new("NO_MEDIA", "Ảnh không có cỡ tải được."))?;
                self.download(&loc, &path).await?;
                Ok(json!({"path": path}))
            }
            "media.sticker" => {
                let peer = self.peer_ref(a).await?;
                let id = a.get("id").and_then(Value::as_i64).ok_or_else(|| CoreError::new("BAD_ARGS", "thiếu «id»"))?;
                let path = self.cfg.data_dir.join("media").join(format!("s{}_{}.png", arg_str(a, "peer")?, id));
                if self.cache.hit(&path) {
                    return Ok(json!({"path": path}));
                }
                let _permit = self.dl.acquire().await.map_err(|_| CoreError::new("BUSY", "hàng tải đã đóng"))?;
                let msg = self.client.get_messages_by_id(peer, &[id as i32]).await?.into_iter().flatten().next();
                let Some(Media::Sticker(s)) = msg.as_ref().and_then(|m| m.media()) else {
                    return Err(CoreError::new("NO_MEDIA", "Tin này không còn sticker."));
                };
                let loc = crate::media::sticker_loc(&s).ok_or_else(|| CoreError::new("NO_MEDIA", "Sticker không tải được."))?;
                let raw = path.with_extension("bin");
                self.download(&loc, &raw).await?;
                let data = std::fs::read(&raw).map_err(|e| CoreError::new("IO", e.to_string()))?;
                let _ = std::fs::remove_file(&raw);
                crate::media::to_png(&data, &path).map_err(|e| CoreError::new("DECODE", format!("Không đọc được sticker: {e}")))?;
                Ok(json!({"path": path}))
            }
            "media.stickerfile" => {
                // Sticker động: TGS (Lottie nén gzip → media/s<peer>_<id>_a.tgs, app vẽ bằng gm_lottie_*) hoặc sticker video
                // (`kind: "webm"`: WebM / VP9 → media/s<peer>_<id>_v.webm, app giải mã bằng gm_webm_*) — tải nguyên tệp
                let peer = self.peer_ref(a).await?;
                let id = a.get("id").and_then(Value::as_i64).ok_or_else(|| CoreError::new("BAD_ARGS", "thiếu «id»"))?;
                let webm = a.get("kind").and_then(Value::as_str) == Some("webm");
                let (suffix, mime, magic): (&str, &str, &[u8]) = if webm {
                    ("v.webm", "video/webm", &[0x1a, 0x45, 0xdf, 0xa3])
                } else {
                    ("a.tgs", "application/x-tgsticker", &[0x1f, 0x8b])
                };
                // Tên riêng «…_a.tgs» / «…_v.webm»: tệp tạm «.part» không trùng với ảnh tĩnh của cùng tin (media.sticker tải song song)
                let path = self.cfg.data_dir.join("media").join(format!("s{}_{}_{suffix}", arg_str(a, "peer")?, id));
                if self.cache.hit(&path) {
                    return Ok(json!({"path": path}));
                }
                let _permit = self.dl.acquire().await.map_err(|_| CoreError::new("BUSY", "hàng tải đã đóng"))?;
                let msg = self.client.get_messages_by_id(peer, &[id as i32]).await?.into_iter().flatten().next();
                let Some(Media::Sticker(s)) = msg.as_ref().and_then(|m| m.media()) else {
                    return Err(CoreError::new("NO_MEDIA", "Tin này không còn sticker."));
                };
                if s.document.mime_type() != Some(mime) {
                    return Err(CoreError::new("NOT_ANIMATED", "Không phải sticker động / video."));
                }
                let loc = crate::media::document_loc(&s.document).ok_or_else(|| CoreError::new("NO_MEDIA", "Sticker không tải được."))?;
                self.download(&loc, &path).await?;
                // TGS = gzip, WebM = EBML: nhận nhầm tệp khác thì xoá (khỏi đệm sai)
                let (data, rerr) = match std::fs::read(&path) {
                    Ok(d) => (d, String::new()),
                    Err(e) => (Vec::new(), format!(", đọc lỗi: {e}")),
                };
                if data.get(..magic.len()) != Some(magic) {
                    let _ = std::fs::remove_file(&path);
                    let head: Vec<String> = data.iter().take(8).map(|b| format!("{b:02x}")).collect();
                    return Err(CoreError::new("DECODE", format!("Tệp sticker động hỏng ({} / {:?} byte, đầu {}{rerr}).",
                                                                data.len(), loc.size, head.join(" "))));
                }
                Ok(json!({"path": path}))
            }
            "media.document" => {
                let peer = self.peer_ref(a).await?;
                let id = a.get("id").and_then(Value::as_i64).ok_or_else(|| CoreError::new("BAD_ARGS", "thiếu «id»"))?;
                let key = arg_str(a, "peer")?.to_string();
                // `video`: để phát — tệp H.265 (iOS 5 / 6 chỉ phát tiếng) thì đổi sang bản H.264 Telegram đã chuyển nếu có;
                // không có thì trả kèm `hevc` để app báo
                let video = a.get("video").and_then(Value::as_bool).unwrap_or(false);
                let prefix = format!("d{key}_{id}.");
                let mut stale_hevc = None;
                if let Ok(rd) = std::fs::read_dir(self.cfg.data_dir.join("media")) {
                    for e in rd.flatten() {
                        let n = e.file_name().to_string_lossy().to_string();
                        if n.starts_with(&prefix) && !n.ends_with(".part") {
                            crate::cache::touch(&e.path());
                            if video && crate::media::is_hevc_file(&e.path()) {
                                stale_hevc = Some(e.path());
                                break;
                            }
                            return Ok(json!({"path": e.path()}));
                        }
                    }
                }
                let msg = self.client.get_messages_by_id(peer, &[id as i32]).await?.into_iter().flatten().next();
                let Some(Media::Document(d)) = msg.as_ref().and_then(|m| m.media()) else {
                    return Err(CoreError::new("NO_MEDIA", "Tin này không còn tệp."));
                };
                let path = self.cfg.data_dir.join("media").join(format!("d{}_{}.{}", key, id, crate::media::file_ext(&d)));
                if video {
                    if let Some((alt, w, h)) = crate::media::h264_alt(&d, 720) {
                        let alt_path = path.with_extension("mp4");
                        if let Some(p) = &stale_hevc {
                            let _ = std::fs::remove_file(p);
                        }
                        self.log(&format!("video {id}: phát bản H.264 {w}×{h} (tệp gốc không phải H.264)"));
                        let _permit = self.dl.acquire().await.map_err(|_| CoreError::new("BUSY", "hàng tải đã đóng"))?;
                        self.download_progress(&alt, &alt_path, &key, id).await?;
                        return Ok(json!({"path": alt_path}));
                    }
                    if let Some(p) = stale_hevc {
                        self.log(&format!("video {id}: H.265, không có bản H.264 — {}", crate::media::video_variants(&d)));
                        return Ok(json!({"path": p, "hevc": true}));
                    }
                }
                if self.cache.hit(&path) {
                    return Ok(json!({"path": path}));
                }
                let loc = crate::media::document_loc(&d).ok_or_else(|| CoreError::new("NO_MEDIA", "Tệp không tải được."))?;
                let _permit = self.dl.acquire().await.map_err(|_| CoreError::new("BUSY", "hàng tải đã đóng"))?;
                self.download_progress(&loc, &path, &key, id).await?;
                let hevc = video && crate::media::is_hevc_file(&path);
                if hevc {
                    self.log(&format!("video {id}: H.265, không có bản H.264 — {}", crate::media::video_variants(&d)));
                }
                Ok(json!({"path": path, "hevc": hevc}))
            }
            "media.thumb" => {
                let peer = self.peer_ref(a).await?;
                let id = a.get("id").and_then(Value::as_i64).ok_or_else(|| CoreError::new("BAD_ARGS", "thiếu «id»"))?;
                let path = self.cfg.data_dir.join("media").join(format!("t{}_{}.jpg", arg_str(a, "peer")?, id));
                if self.cache.hit(&path) {
                    return Ok(json!({"path": path}));
                }
                let _permit = self.dl.acquire().await.map_err(|_| CoreError::new("BUSY", "hàng tải đã đóng"))?;
                let msg = self.client.get_messages_by_id(peer, &[id as i32]).await?.into_iter().flatten().next();
                let Some(Media::Document(d)) = msg.as_ref().and_then(|m| m.media()) else {
                    return Err(CoreError::new("NO_MEDIA", "Tin này không còn tệp."));
                };
                let loc = crate::media::doc_thumb_loc(&d).ok_or_else(|| CoreError::new("NO_MEDIA", "Tệp không có ảnh xem trước."))?;
                self.download(&loc, &path).await?;
                Ok(json!({"path": path}))
            }
            "messages.sendFile" => {
                let peer = self.peer_ref(a).await?;
                let file = arg_str(a, "path")?;
                let name = a.get("name").and_then(Value::as_str);
                let up = self.upload(file, name, a.get("tag").and_then(Value::as_str)).await?;
                let reply = reply_arg(a);
                let mut msg = grammers_client::message::InputMessage::new()
                    .text(a.get("caption").and_then(Value::as_str).unwrap_or(""))
                    .document(up)
                    .reply_to(reply);
                if let Some(mime) = a.get("mime").and_then(Value::as_str) {
                    msg = msg.mime_type(mime);
                }
                if let Some(v) = a.get("video") {
                    msg = msg.attribute(grammers_client::media::Attribute::Video {
                        round_message: false,
                        supports_streaming: true,
                        duration: Duration::try_from_secs_f64(v.get("duration").and_then(Value::as_f64).unwrap_or(0.0)).unwrap_or_default(),
                        w: v.get("w").and_then(Value::as_i64).unwrap_or(0) as i32,
                        h: v.get("h").and_then(Value::as_i64).unwrap_or(0) as i32,
                    });
                }
                if let Some(n) = a.get("name").and_then(Value::as_str) {
                    msg = msg.attribute(grammers_client::media::Attribute::FileName(n.to_string()));
                }
                let m = self.client.send_message(peer, msg).await?;
                Ok(msg_json(&m))
            }
            "media.voice" => {
                let peer = self.peer_ref(a).await?;
                let id = a.get("id").and_then(Value::as_i64).ok_or_else(|| CoreError::new("BAD_ARGS", "thiếu «id»"))?;
                let path = self.cfg.data_dir.join("media").join(format!("v{}_{}.wav", arg_str(a, "peer")?, id));
                if self.cache.hit(&path) {
                    return Ok(json!({"path": path}));
                }
                let _permit = self.dl.acquire().await.map_err(|_| CoreError::new("BUSY", "hàng tải đã đóng"))?;
                let msg = self.client.get_messages_by_id(peer, &[id as i32]).await?.into_iter().flatten().next();
                let Some(Media::Document(d)) = msg.as_ref().and_then(|m| m.media()) else {
                    return Err(CoreError::new("NO_MEDIA", "Tin này không còn tin thoại."));
                };
                let loc = crate::media::document_loc(&d).ok_or_else(|| CoreError::new("NO_MEDIA", "Tin thoại không tải được."))?;
                // Tệp lạ: tin thoại thật cỡ vài MB (gm_opus còn giới hạn thời lượng khi giải mã)
                if d.size() > Some(32 << 20) {
                    return Err(CoreError::new("DECODE", "Tin thoại quá lớn."));
                }
                let ogg = path.with_extension("ogg");
                self.download(&loc, &ogg).await?;
                let data = std::fs::read(&ogg).map_err(|e| CoreError::new("IO", e.to_string()))?;
                let _ = std::fs::remove_file(&ogg);
                // Giải mã ở luồng blocking (A4: tin dài vài phút mất cỡ giây)
                let (wav, dur) = tokio::task::spawn_blocking(move || gm_opus::ogg_to_wav(&data, 24000))
                    .await
                    .map_err(|e| CoreError::new("DECODE", e.to_string()))?
                    .map_err(|e| CoreError::new("DECODE", format!("Không giải mã được tin thoại: {e}")))?;
                let tmp = part_path(&path);
                std::fs::write(&tmp, wav).and_then(|_| std::fs::rename(&tmp, &path)).map_err(|e| CoreError::new("IO", e.to_string()))?;
                Ok(json!({"path": path, "duration": dur}))
            }
            "messages.sendVoice" => {
                let peer = self.peer_ref(a).await?;
                let wav_path = arg_str(a, "path")?.to_string();
                let data = std::fs::read(&wav_path).map_err(|e| CoreError::new("IO", format!("Không đọc được bản ghi âm: {e}")))?;
                let (ogg, dur, wave) = tokio::task::spawn_blocking(move || -> std::io::Result<(Vec<u8>, f64, Vec<u8>)> {
                    let (pcm, rate) = gm_opus::read_wav(&data)?;
                    let (ogg, dur) = gm_opus::encode_ogg(&pcm, rate)?;
                    Ok((ogg, dur, gm_opus::waveform(&pcm)))
                })
                .await
                .map_err(|e| CoreError::new("ENCODE", e.to_string()))?
                .map_err(|e| CoreError::new("ENCODE", format!("Không mã hoá được tin thoại: {e}")))?;
                if dur < 0.5 {
                    return Err(CoreError::new("TOO_SHORT", "Tin thoại quá ngắn."));
                }
                let ogg_path = std::path::Path::new(&wav_path).with_extension("ogg");
                std::fs::write(&ogg_path, &ogg).map_err(|e| CoreError::new("IO", e.to_string()))?;
                let up = self.client.upload_file(&ogg_path).await.map_err(|e| CoreError::new("IO", e.to_string()))?;
                let _ = std::fs::remove_file(&ogg_path);
                let reply = reply_arg(a);
                let msg = grammers_client::message::InputMessage::new()
                    .text("")
                    .document(up)
                    .mime_type("audio/ogg")
                    .attribute(grammers_client::media::Attribute::Voice {
                        duration: Duration::from_secs_f64(dur.round().max(1.0)),
                        waveform: Some(wave),
                    })
                    .reply_to(reply);
                let m = self.client.send_message(peer, msg).await?;
                Ok(msg_json(&m))
            }
            "messages.sendPhoto" => {
                let peer = self.peer_ref(a).await?;
                let file = arg_str(a, "path")?;
                let up = self.client.upload_file(file).await.map_err(|e| CoreError::new("IO", format!("Không đọc được ảnh: {e}")))?;
                let reply = reply_arg(a);
                let caption = a.get("caption").and_then(Value::as_str).unwrap_or("");
                let msg = grammers_client::message::InputMessage::new().text(caption).photo(up).reply_to(reply);
                let m = self.client.send_message(peer, msg).await?;
                Ok(msg_json(&m))
            }
            "media.avatar" => {
                let peer = self.peer_ref(a).await?;
                let photo: i64 = arg_str(a, "photo")?.parse().map_err(|_| CoreError::new("BAD_ARGS", "«photo» sai"))?;
                let dc = a.get("dc").and_then(Value::as_i64).unwrap_or(0) as i32;
                let path = self.cfg.data_dir.join("avatars").join(format!("{}_{}.jpg", arg_str(a, "peer")?, photo));
                if self.cache.hit(&path) {
                    return Ok(json!({"path": path}));
                }
                let _permit = self.dl.acquire().await.map_err(|_| CoreError::new("BUSY", "hàng tải đã đóng"))?;
                self.download(&crate::media::avatar_loc(&peer, photo, dc), &path).await?;
                Ok(json!({"path": path}))
            }
            "net.state" => Ok(json!({"ok": self.net.load(std::sync::atomic::Ordering::Relaxed) != 2})),
            "net.check" => Ok(json!({"ok": self.check_net().await})),
            "messages.forward" => {
                let src = self.peer_ref_of(a, "from").await?;
                let dst = self.peer_ref_of(a, "to").await?;
                let ids: Vec<i32> = a
                    .get("ids")
                    .and_then(Value::as_array)
                    .map(|v| v.iter().filter_map(Value::as_i64).map(|x| x as i32).collect())
                    .unwrap_or_default();
                if ids.is_empty() {
                    return Err(CoreError::new("BAD_ARGS", "thiếu «ids»"));
                }
                let out = self.client.forward_messages(dst, &ids, src).await?;
                Ok(Value::Array(out.iter().flatten().map(msg_json).collect()))
            }
            "messages.read" => {
                let peer = self.peer_ref(a).await?;
                if let Some(topic) = a.get("topic").and_then(Value::as_i64) {
                    // Chủ đề diễn đàn: đọc tới `max_id` trong chủ đề (không đánh dấu cả nhóm)
                    let max = a.get("max_id").and_then(Value::as_i64).unwrap_or(0) as i32;
                    use grammers_client::tl::functions::messages::ReadDiscussion;
                    self.client.invoke(&ReadDiscussion { peer: peer.into(), msg_id: topic as i32, read_max_id: max }).await?;
                    return Ok(json!({}));
                }
                self.client.mark_as_read(peer).await?;
                Ok(json!({}))
            }
            "cache.stats" => {
                let dir = self.cfg.data_dir.clone();
                let entries = tokio::task::spawn_blocking(move || crate::cache::scan(&dir))
                    .await
                    .map_err(|e| CoreError::new("IO", e.to_string()))?;
                let mut kinds: std::collections::BTreeMap<&str, u64> = crate::cache::KINDS.iter().map(|k| (*k, 0)).collect();
                let mut chats: std::collections::HashMap<String, u64> = Default::default();
                let mut total = 0u64;
                for e in &entries {
                    total += e.size;
                    *kinds.entry(e.kind).or_default() += e.size;
                    if let (Some(p), false) = (&e.peer, e.kind == "avatar") {
                        *chats.entry(p.clone()).or_default() += e.size;
                    }
                }
                let mut chats: Vec<(String, u64)> = chats.into_iter().collect();
                chats.sort_by(|a, b| b.1.cmp(&a.1));
                chats.truncate(50);
                let chats: Vec<Value> = {
                    let names = lock(NAMES.get_or_init(Default::default));
                    chats.iter().map(|(p, b)| json!({"peer": p, "name": names.get(p), "bytes": b})).collect()
                };
                let p = self.cache.policy();
                let disk = crate::cache::disk_space(&self.cfg.data_dir);
                Ok(json!({
                    "total": total,
                    "files": entries.len(),
                    "kinds": kinds,
                    "chats": chats,
                    "limit_mb": p.limit_mb,
                    "keep_days": p.keep_days,
                    "free": disk.map(|d| d.0),
                    "disk": disk.map(|d| d.1),
                }))
            }
            "cache.clear" => {
                let kinds: Option<Vec<String>> = a
                    .get("kinds")
                    .and_then(Value::as_array)
                    .map(|v| v.iter().filter_map(Value::as_str).map(str::to_string).collect());
                let peer = a.get("peer").and_then(Value::as_str).map(str::to_string);
                let dir = self.cfg.data_dir.clone();
                let (freed, n) =
                    tokio::task::spawn_blocking(move || crate::cache::clear(&dir, kinds.as_deref(), peer.as_deref()))
                        .await
                        .map_err(|e| CoreError::new("IO", e.to_string()))?;
                self.log(&format!("xoá đệm: {n} tệp ({} KB)", freed >> 10));
                (self.emit)(json!({"e": "cache.cleared"}));
                Ok(json!({"freed": freed, "files": n}))
            }
            "cache.set" => {
                let mut p = self.cache.policy();
                if let Some(v) = a.get("limit_mb").and_then(Value::as_u64) {
                    p.limit_mb = v;
                }
                if let Some(v) = a.get("keep_days").and_then(Value::as_u64) {
                    p.keep_days = v;
                }
                self.save_settings(&[("cache_limit_mb", json!(p.limit_mb)), ("cache_keep_days", json!(p.keep_days))])?;
                self.cache.set_policy(p);
                self.trim_soon(true);
                Ok(json!({}))
            }
            "chat.status" => Box::pin(self.chat_status(a)).await,
            "contacts.list" => Box::pin(self.contacts_list()).await,
            "contacts.search" => Box::pin(self.contacts_search(a)).await,
            "contacts.resolve" => {
                let name = arg_str(a, "username")?.trim().trim_start_matches('@');
                match self.client.resolve_username(name).await {
                    Ok(Some(p)) => {
                        remember(&p);
                        Ok(peer_json(&p))
                    }
                    Ok(None) => Err(CoreError::new("USERNAME_NOT_OCCUPIED", "Không có ai dùng tên này.")),
                    Err(e) => Err(e.into()),
                }
            }
            "messages.search" => Box::pin(self.messages_search(a)).await,
            "link.resolve" => Box::pin(self.link_resolve(a)).await,
            "chats.join" => Box::pin(self.chat_join(a)).await,
            "messages.react" => Box::pin(self.react(a)).await,
            "reactions.available" => Box::pin(self.reactions_available()).await,
            "messages.botCallback" => Box::pin(self.bot_callback(a)).await,
            "bots.webview" => Box::pin(self.bot_webview(a)).await,
            "bots.keyboard" => Box::pin(self.bot_keyboard(a)).await,
            "messages.vote" => Box::pin(self.vote(a)).await,
            "messages.sendPoll" => Box::pin(self.send_poll(a)).await,
            "messages.pinned" => Box::pin(self.pinned_list(a)).await,
            "map.static" => Box::pin(self.map_static(a)).await,
            "map.address" => Box::pin(self.map_address(a)).await,
            "messages.sendGeo" => Box::pin(self.send_geo(a)).await,
            "vietqr.make" => self.vietqr_make(a),
            "messages.sendContact" => Box::pin(self.send_contact(a)).await,
            "messages.pin" => Box::pin(self.pin(a)).await,
            "messages.scheduled" => Box::pin(self.scheduled_list(a)).await,
            "messages.scheduledSend" | "messages.scheduledDelete" => Box::pin(self.scheduled_act(method, a)).await,
            "chat.info" => Box::pin(self.chat_info(a)).await,
            "topics.list" => Box::pin(self.topics_list(a)).await,
            "groups.create" => Box::pin(self.group_create(a)).await,
            "groups.delete" => {
                // Xoá hẳn nhóm thường (chỉ người tạo) — mọi thành viên mất nhóm
                use grammers_client::tl::functions;
                let pr = self.peer_ref(a).await?;
                if pr.id.kind() != grammers_session::types::PeerKind::Chat {
                    return Err(CoreError::new("BAD_ARGS", "Chỉ xoá được nhóm thường."));
                }
                self.client.invoke(&functions::messages::DeleteChat { chat_id: pr.id.bare_id_unchecked() }).await?;
                Ok(json!({}))
            }
            "account.get" => {
                use grammers_client::tl::{enums, functions};
                let me = self.client.get_me().await?;
                let enums::users::UserFull::Full(f) =
                    self.client.invoke(&functions::users::GetFullUser { id: enums::InputUser::UserSelf }).await?;
                let enums::UserFull::Full(u) = f.full_user;
                let mut v = user_json(&me);
                v["first"] = json!(me.first_name());
                v["last"] = json!(me.last_name());
                v["about"] = json!(u.about);
                Ok(v)
            }
            "account.update" => {
                // Tên / họ / giới thiệu (trường nào có thì đổi)
                use grammers_client::tl::functions;
                let s = |k: &str| a.get(k).and_then(Value::as_str).map(str::to_string);
                self.client
                    .invoke(&functions::account::UpdateProfile { first_name: s("first"), last_name: s("last"), about: s("about") })
                    .await?;
                Ok(json!({}))
            }
            "account.checkUsername" => {
                use grammers_client::tl::functions;
                let u = arg_str(a, "username")?.trim().trim_start_matches('@').to_string();
                let free = self.client.invoke(&functions::account::CheckUsername { username: u }).await?;
                Ok(json!({"free": free}))
            }
            "account.setUsername" => {
                use grammers_client::tl::functions;
                let u = arg_str(a, "username")?.trim().trim_start_matches('@').to_string();
                self.client.invoke(&functions::account::UpdateUsername { username: u }).await?;
                Ok(json!({}))
            }
            "account.setPhoto" => {
                use grammers_client::tl::functions;
                let up = self.upload(arg_str(a, "path")?, None, None).await?;
                self.client
                    .invoke(&functions::photos::UploadProfilePhoto {
                        fallback: false,
                        bot: None,
                        file: Some(up.raw),
                        video: None,
                        video_start_ts: None,
                        video_emoji_markup: None,
                    })
                    .await?;
                let me = self.client.get_me().await?;
                Ok(user_json(&me))
            }
            "account.sessions" => {
                // Các máy đang đăng nhập tài khoản (máy này: current)
                use grammers_client::tl::{enums, functions};
                let enums::account::Authorizations::Authorizations(x) = self.client.invoke(&functions::account::GetAuthorizations {}).await?;
                let list: Vec<Value> = x
                    .authorizations
                    .iter()
                    .map(|a| {
                        let enums::Authorization::Authorization(a) = a;
                        json!({
                            "hash": a.hash.to_string(),
                            "current": a.current,
                            "official": a.official_app,
                            "device": a.device_model,
                            "platform": a.platform,
                            "system": a.system_version,
                            // app_version của GramMini đã có tên app («GramMini 0.1.0») — khỏi lặp
                            "app": if a.app_version.starts_with(&a.app_name) {
                                a.app_version.clone()
                            } else {
                                format!("{} {}", a.app_name, a.app_version)
                            },
                            "created": a.date_created,
                            "active": a.date_active,
                            "ip": a.ip,
                            "country": a.country,
                            "region": a.region,
                        })
                    })
                    .collect();
                Ok(Value::Array(list))
            }
            "account.terminate" => {
                use grammers_client::tl::functions;
                let hash: i64 = arg_str(a, "hash")?.parse().map_err(|_| CoreError::new("BAD_ARGS", "«hash» sai"))?;
                self.client.invoke(&functions::account::ResetAuthorization { hash }).await?;
                Ok(json!({}))
            }
            "account.privacy" => Box::pin(self.privacy_get()).await,
            "account.setPrivacy" => {
                // value: everybody | contacts | nobody (bỏ các ngoại lệ đã có — app báo trước)
                use grammers_client::tl::{enums, functions, types};
                let key = privacy_key(arg_str(a, "key")?).ok_or_else(|| CoreError::new("BAD_ARGS", "«key» sai"))?;
                let rules: Vec<enums::InputPrivacyRule> = match arg_str(a, "value")? {
                    "everybody" => vec![types::InputPrivacyValueAllowAll {}.into()],
                    "contacts" => vec![types::InputPrivacyValueAllowContacts {}.into(), types::InputPrivacyValueDisallowAll {}.into()],
                    _ => vec![types::InputPrivacyValueDisallowAll {}.into()],
                };
                self.client.invoke(&functions::account::SetPrivacy { key, rules }).await?;
                Ok(json!({}))
            }
            "contacts.rename" => {
                // Tên mình lưu cho người này (danh bạ) — Telegram hiện tên này thay tên họ tự đặt
                use grammers_client::tl::functions;
                let pr = self.peer_ref(a).await?;
                let first = arg_str(a, "first")?.to_string();
                let last = a.get("last").and_then(Value::as_str).unwrap_or("").to_string();
                self.client
                    .invoke(&functions::contacts::AddContact {
                        add_phone_privacy_exception: false,
                        id: pr.into(),
                        first_name: first,
                        last_name: last,
                        phone: String::new(),
                        note: None,
                    })
                    .await?;
                Ok(json!({}))
            }
            "stickers.sets" => {
                use grammers_client::tl::{enums, functions};
                let enums::messages::AllStickers::Stickers(all) = self.client.invoke(&functions::messages::GetAllStickers { hash: 0 }).await? else {
                    return Ok(json!([]));
                };
                let sets: Vec<Value> = all
                    .sets
                    .iter()
                    .map(|s| {
                        let enums::StickerSet::Set(s) = s;
                        json!({"id": s.id.to_string(), "access_hash": s.access_hash.to_string(), "title": s.title, "count": s.count,
                               "short_name": s.short_name})
                    })
                    .collect();
                Ok(Value::Array(sets))
            }
            "stickers.set" => {
                use grammers_client::tl::{enums, functions, types};
                let num = |k: &str| -> Result<i64, CoreError> {
                    a.get(k).and_then(|v| v.as_str().and_then(|s| s.parse().ok()).or(v.as_i64())).ok_or_else(|| CoreError::new("BAD_ARGS", format!("thiếu «{k}»")))
                };
                let set = enums::InputStickerSet::Id(types::InputStickerSetId { id: num("id")?, access_hash: num("access_hash")? });
                let enums::messages::StickerSet::Set(s) = self.client.invoke(&functions::messages::GetStickerSet { stickerset: set, hash: 0 }).await? else {
                    return Ok(json!([]));
                };
                Ok(self.adopt_docs(s.documents))
            }
            "http.get" | "http.download" => Box::pin(self.http(method, a)).await,
            "chat.ttl" => {
                // Tin tự xoá: `period` giây (0 = tắt; app dùng 1 ngày / 1 tuần / 1 tháng) — áp cho tin gửi từ giờ, cả hai bên
                use grammers_client::tl::functions;
                let pr = self.peer_ref(a).await?;
                let period = a.get("period").and_then(Value::as_i64).unwrap_or(0).max(0) as i32;
                self.client.invoke(&functions::messages::SetHistoryTtl { peer: pr.into(), period }).await?;
                Ok(json!({"ttl": period}))
            }
            "account.defaultTtl" => {
                // Mặc định cho chat mới: có `period` thì đặt, không thì đọc
                use grammers_client::tl::{enums, functions};
                if let Some(period) = a.get("period").and_then(Value::as_i64) {
                    self.client.invoke(&functions::messages::SetDefaultHistoryTtl { period: period.max(0) as i32 }).await?;
                    return Ok(json!({"ttl": period.max(0)}));
                }
                let enums::DefaultHistoryTtl::Ttl(t) = self.client.invoke(&functions::messages::GetDefaultHistoryTtl {}).await?;
                Ok(json!({"ttl": t.period}))
            }
            "folders.list" | "folders.suggested" | "folders.save" | "folders.delete" | "folders.order" => {
                Box::pin(self.folders(method, a)).await
            }
            "stickers.setInfo" | "stickers.install" | "stickers.uninstall" | "stickers.featured" | "stickers.search" => {
                Box::pin(self.sticker_sets(method, a)).await
            }
            "stickers.recent" => {
                use grammers_client::tl::{enums, functions};
                let enums::messages::RecentStickers::Stickers(r) =
                    self.client.invoke(&functions::messages::GetRecentStickers { attached: false, hash: 0 }).await?
                else {
                    return Ok(json!([]));
                };
                Ok(self.adopt_docs(r.stickers))
            }
            "gifs.saved" => {
                use grammers_client::tl::{enums, functions};
                let enums::messages::SavedGifs::Gifs(g) = self.client.invoke(&functions::messages::GetSavedGifs { hash: 0 }).await? else {
                    return Ok(json!([]));
                };
                Ok(self.adopt_docs(g.gifs))
            }
            "media.docpreview" => Box::pin(self.doc_preview(a)).await,
            "messages.sendDoc" => {
                // Gửi lại sticker / GIF đã có trên máy chủ (theo mã tài liệu đã lấy về)
                use grammers_client::tl::{enums, types};
                let pr = self.peer_ref(a).await?;
                let id = doc_id_arg(a)?;
                let d = lock(&self.docs).get(&id).cloned().ok_or_else(|| CoreError::new("NO_DOC", "Không còn sticker này — tải lại bảng sticker."))?;
                let media = types::InputMediaDocument {
                    spoiler: false,
                    id: enums::InputDocument::Document(types::InputDocument { id: d.id, access_hash: d.access_hash, file_reference: d.file_reference }),
                    video_cover: None,
                    video_timestamp: None,
                    ttl_seconds: None,
                    query: None,
                };
                let reply = reply_arg(a);
                let m = self.client.send_message(pr, grammers_client::message::InputMessage::new().text("").media(media).reply_to(reply)).await?;
                Ok(msg_json(&m))
            }
            "dialogs.delete" => {
                // Chat riêng: xoá lịch sử phía mình; nhóm thường: rời nhóm; kênh / siêu nhóm: rời
                let pr = self.peer_ref(a).await?;
                // Chat riêng + revoke: xoá lịch sử cho cả hai bên (messages.deleteHistory lặp tới khi hết)
                if a.get("revoke").and_then(Value::as_bool).unwrap_or(false) && pr.id.kind() == grammers_session::types::PeerKind::User {
                    use grammers_client::tl::{enums, functions};
                    for _ in 0..50 {
                        let enums::messages::AffectedHistory::History(r) = self
                            .client
                            .invoke(&functions::messages::DeleteHistory {
                                just_clear: false,
                                revoke: true,
                                peer: pr.into(),
                                max_id: 0,
                                min_date: None,
                                max_date: None,
                            })
                            .await?;
                        if r.offset <= 0 {
                            break;
                        }
                    }
                    return Ok(json!({}));
                }
                self.client.delete_dialog(pr).await?;
                Ok(json!({}))
            }
            "dialogs.pin" => {
                use grammers_client::tl::{enums, functions, types};
                let pr = self.peer_ref(a).await?;
                let pinned = a.get("pin").and_then(Value::as_bool).unwrap_or(true);
                self.client
                    .invoke(&functions::messages::ToggleDialogPin {
                        pinned,
                        peer: enums::InputDialogPeer::Peer(types::InputDialogPeer { peer: pr.into() }),
                    })
                    .await?;
                Ok(json!({"pinned": pinned}))
            }
            "chat.members" => Box::pin(self.chat_members(a)).await,
            "messages.media" => Box::pin(self.messages_media(a)).await,
            "chat.mute" => {
                use grammers_client::tl::{enums, functions, types};
                let pr = self.peer_ref(a).await?;
                let mute = a.get("mute").and_then(Value::as_bool).unwrap_or(true);
                let settings = types::InputPeerNotifySettings {
                    show_previews: None,
                    silent: None,
                    mute_until: Some(if mute { i32::MAX } else { 0 }),
                    sound: None,
                    stories_muted: None,
                    stories_hide_sender: None,
                    stories_sound: None,
                };
                self.client
                    .invoke(&functions::account::UpdateNotifySettings {
                        peer: enums::InputNotifyPeer::Peer(types::InputNotifyPeer { peer: pr.into() }),
                        settings: settings.into(),
                    })
                    .await?;
                Ok(json!({"muted": mute}))
            }
            "messages.typing" => {
                // Báo bên kia mình đang gõ / ghi âm… (Telegram tự tắt sau ~6 giây; "cancel" = thôi)
                use grammers_client::tl::{enums, functions, types};
                let pr = self.peer_ref(a).await?;
                let action: enums::SendMessageAction = match a.get("action").and_then(Value::as_str).unwrap_or("typing") {
                    "cancel" => types::SendMessageCancelAction {}.into(),
                    "recording" => types::SendMessageRecordAudioAction {}.into(),
                    "voice" => types::SendMessageUploadAudioAction { progress: 0 }.into(),
                    "photo" => types::SendMessageUploadPhotoAction { progress: 0 }.into(),
                    "video" => types::SendMessageUploadVideoAction { progress: 0 }.into(),
                    "file" => types::SendMessageUploadDocumentAction { progress: 0 }.into(),
                    _ => types::SendMessageTypingAction {}.into(),
                };
                self.client.invoke(&functions::messages::SetTyping { peer: pr.into(), top_msg_id: None, action }).await?;
                Ok(json!({}))
            }
            "app.flush" => {
                self.save_session();
                Ok(json!({}))
            }
            _ => Err(CoreError::new("NO_METHOD", format!("không có lệnh {method}"))),
        }
    }

    fn signed_in(self: &Arc<Self>, me: &grammers_client::peer::User) -> Res {
        self.save_session();
        (self.emit)(json!({"e": "auth.state", "authorized": true}));
        self.start_updates();
        Ok(json!({"me": user_json(me)}))
    }
}

/// Bọc tệp đang tải lên: đếm byte đã đọc, báo `upload.progress`.
struct Counting<R> {
    inner: R,
    done: u64,
    last: u64,
    total: u64,
    tag: Option<String>,
    emit: Emit,
}

impl<R: tokio::io::AsyncRead + Unpin> tokio::io::AsyncRead for Counting<R> {
    fn poll_read(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        let before = buf.filled().len();
        let r = std::pin::Pin::new(&mut self.inner).poll_read(cx, buf);
        if let std::task::Poll::Ready(Ok(())) = &r {
            let me = &mut *self;
            me.done += (buf.filled().len() - before) as u64;
            if let Some(tag) = &me.tag {
                if me.done - me.last >= 256 * 1024 || me.done >= me.total {
                    me.last = me.done;
                    (me.emit)(json!({"e": "upload.progress", "tag": tag, "done": me.done, "total": me.total}));
                }
            }
        }
        r
    }
}

/// Khoá quyền riêng tư theo tên app dùng.
fn privacy_key(k: &str) -> Option<grammers_client::tl::enums::InputPrivacyKey> {
    use grammers_client::tl::enums::InputPrivacyKey as K;
    Some(match k {
        "status" => K::StatusTimestamp,
        "phone" => K::PhoneNumber,
        "photo" => K::ProfilePhoto,
        "forwards" => K::Forwards,
        "calls" => K::PhoneCall,
        "invites" => K::ChatInvite,
        _ => return None,
    })
}

/// Thư mục → JSON cho app (bỏ «Tất cả» — dialogFilterDefault). Thư mục chia sẻ (chatlist) chỉ có danh sách chat.
fn folder_json(f: &grammers_client::tl::enums::DialogFilter) -> Option<Value> {
    use grammers_client::tl::enums::{DialogFilter as F, InputPeer as I, TextWithEntities as T};
    fn keys(v: &[I]) -> Vec<String> {
        v.iter()
            .filter_map(|p| match p {
                I::PeerSelf => Some("self".to_string()),
                I::User(x) => PeerId::user(x.user_id).map(peer_key),
                I::UserFromMessage(x) => PeerId::user(x.user_id).map(peer_key),
                I::Chat(x) => PeerId::chat(x.chat_id).map(peer_key),
                I::Channel(x) => PeerId::channel(x.channel_id).map(peer_key),
                I::ChannelFromMessage(x) => PeerId::channel(x.channel_id).map(peer_key),
                _ => None,
            })
            .collect()
    }
    let text = |t: &T| match t {
        T::Entities(t) => t.text.clone(),
    };
    match f {
        F::Filter(f) => Some(json!({
            "id": f.id, "title": text(&f.title), "emoticon": f.emoticon,
            "contacts": f.contacts, "non_contacts": f.non_contacts, "groups": f.groups, "broadcasts": f.broadcasts, "bots": f.bots,
            "exclude_muted": f.exclude_muted, "exclude_read": f.exclude_read, "exclude_archived": f.exclude_archived,
            "include": keys(&f.include_peers), "exclude": keys(&f.exclude_peers), "pinned": keys(&f.pinned_peers),
        })),
        F::Chatlist(f) => Some(json!({
            "id": f.id, "title": text(&f.title), "emoticon": f.emoticon, "chatlist": true,
            "include": keys(&f.include_peers), "exclude": [], "pinned": keys(&f.pinned_peers),
        })),
        _ => None,
    }
}

/// Bộ sticker theo `short_name` (link t.me/addstickers/…) hoặc `id` + `access_hash` (chuỗi hoặc số).
fn sticker_set_arg(a: &Value) -> Result<grammers_client::tl::enums::InputStickerSet, CoreError> {
    use grammers_client::tl::{enums, types};
    if let Some(n) = a.get("short_name").and_then(Value::as_str).filter(|s| !s.is_empty()) {
        return Ok(enums::InputStickerSet::ShortName(types::InputStickerSetShortName { short_name: n.to_string() }));
    }
    let num = |k: &str| -> Result<i64, CoreError> {
        a.get(k).and_then(|v| v.as_str().and_then(|s| s.parse().ok()).or(v.as_i64())).ok_or_else(|| CoreError::new("BAD_ARGS", format!("thiếu «{k}»")))
    };
    Ok(enums::InputStickerSet::Id(types::InputStickerSetId { id: num("id")?, access_hash: num("access_hash")? }))
}

/// Thông tin một bộ sticker: mã, tên, tên ngắn (link), số sticker, đã cài / lưu trữ.
fn set_json(s: &grammers_client::tl::enums::StickerSet) -> Value {
    let grammers_client::tl::enums::StickerSet::Set(s) = s;
    json!({
        "id": s.id.to_string(),
        "access_hash": s.access_hash.to_string(),
        "title": s.title,
        "short_name": s.short_name,
        "count": s.count,
        "installed": s.installed_date.is_some() && !s.archived,
        "archived": s.archived,
        "masks": s.masks,
        "emojis": s.emojis,
    })
}

/// Mã tài liệu (`doc`) — chuỗi (i64 vượt 2^53) hoặc số.
fn doc_id_arg(a: &Value) -> Result<i64, CoreError> {
    a.get("doc")
        .and_then(|v| v.as_str().and_then(|s| s.parse().ok()).or(v.as_i64()))
        .ok_or_else(|| CoreError::new("BAD_ARGS", "thiếu «doc»"))
}

/// Sticker / GIF cho bảng chọn: mã (chuỗi), emoji, mime, kích thước, thời lượng, động hay không.
fn doc_ref_json(d: &grammers_client::tl::types::Document) -> Value {
    use grammers_client::tl::enums::DocumentAttribute as A;
    let (mut emoji, mut w, mut h, mut dur) = (None, 0, 0, 0.0);
    for at in &d.attributes {
        match at {
            A::Sticker(s) => emoji = Some(s.alt.clone()),
            A::ImageSize(s) => (w, h) = (s.w, s.h),
            A::Video(v) => (w, h, dur) = (v.w, v.h, v.duration),
            _ => {}
        }
    }
    json!({
        "doc": d.id.to_string(),
        "emoji": emoji,
        "mime": d.mime_type,
        "w": w,
        "h": h,
        "duration": dur,
        "animated": d.mime_type != "image/webp" && emoji.is_some(),
    })
}

/// Lỗi do mạng (đáng thử lại sau), không phải máy chủ từ chối.
fn is_net_error(e: &CoreError) -> bool {
    matches!(e.code.as_str(), "NETWORK" | "TIMEOUT")
}

/// `Peer` của TL → `PeerId`.
fn tl_peer_id(p: &grammers_client::tl::enums::Peer) -> Option<PeerId> {
    use grammers_client::tl::enums::Peer as TlPeer;
    match p {
        TlPeer::User(p) => PeerId::user(p.user_id),
        TlPeer::Chat(p) => PeerId::chat(p.chat_id),
        TlPeer::Channel(p) => PeerId::channel(p.channel_id),
    }
}

/// Loại hành động «đang …» gửi lên app.
fn typing_action(a: &grammers_client::tl::enums::SendMessageAction) -> &'static str {
    use grammers_client::tl::enums::SendMessageAction as A;
    match a {
        A::SendMessageCancelAction => "cancel",
        A::SendMessageRecordAudioAction => "recording",
        A::SendMessageUploadAudioAction(_) => "voice",
        A::SendMessageUploadPhotoAction(_) => "photo",
        A::SendMessageRecordVideoAction | A::SendMessageUploadVideoAction(_) => "video",
        A::SendMessageRecordRoundAction | A::SendMessageUploadRoundAction(_) => "round",
        A::SendMessageUploadDocumentAction(_) => "file",
        A::SendMessageChooseStickerAction => "sticker",
        A::SendMessageGamePlayAction => "game",
        _ => "typing",
    }
}

/// Trạng thái người dùng: `status` = online | offline (kèm `was_online`) | recently | week | month | hidden.
fn status_json(s: &grammers_client::tl::enums::UserStatus) -> Value {
    use grammers_client::tl::enums::UserStatus as S;
    match s {
        S::Online(x) => json!({"status": "online", "expires": x.expires}),
        S::Offline(x) => json!({"status": "offline", "was_online": x.was_online}),
        S::Recently(_) => json!({"status": "recently"}),
        S::LastWeek(_) => json!({"status": "week"}),
        S::LastMonth(_) => json!({"status": "month"}),
        S::Empty => json!({"status": "hidden"}),
    }
}

/// Tên các peer đã gặp (người gửi, chat) — để ghi «Chuyển tiếp từ …» (grammers không mở danh bạ peer của tin ra ngoài).
static NAMES: std::sync::OnceLock<Mutex<std::collections::HashMap<String, String>>> = std::sync::OnceLock::new();

fn remember(p: &Peer) {
    let names = NAMES.get_or_init(Default::default);
    lock(names).insert(peer_key(p.id()), peer_name(p));
}

/// Tên người / kênh gốc của tin chuyển tiếp.
fn fwd_name(m: &Message) -> Option<String> {
    use grammers_client::tl::enums::{MessageFwdHeader, Peer as TlPeer};
    let MessageFwdHeader::Header(h) = m.forward_header()?;
    if let Some(n) = h.from_name.filter(|n| !n.is_empty()) {
        return Some(n);
    }
    let id = match h.from_id? {
        TlPeer::User(p) => PeerId::user(p.user_id),
        TlPeer::Chat(p) => PeerId::chat(p.chat_id),
        TlPeer::Channel(p) => PeerId::channel(p.channel_id),
    }?;
    let names = NAMES.get_or_init(Default::default);
    Some(lock(names).get(&peer_key(id)).cloned().unwrap_or_else(|| "người khác".into()))
}

/// Ảnh đại diện của peer: (photo_id dạng chuỗi, DC), không có thì (null, null).
fn peer_photo(p: &Peer) -> (Value, Value) {
    let (id, dc) = match p {
        Peer::User(u) => match u.photo() {
            Some(x) => (x.photo_id, x.dc_id),
            None => return (Value::Null, Value::Null),
        },
        Peer::Group(g) => match g.photo() {
            Some(x) => (x.photo_id, x.dc_id),
            None => return (Value::Null, Value::Null),
        },
        Peer::Channel(c) => match c.photo() {
            Some(x) => (x.photo_id, x.dc_id),
            None => return (Value::Null, Value::Null),
        },
        Peer::Community(c) => match c.photo() {
            Some(x) => (x.photo_id, x.dc_id),
            None => return (Value::Null, Value::Null),
        },
    };
    (json!(id.to_string()), json!(dc))
}

fn peer_key(id: PeerId) -> String {
    id.bot_api_dialog_id().map(|i| i.to_string()).unwrap_or_default()
}

fn peer_name(p: &Peer) -> String {
    match p {
        Peer::User(u) => {
            let n = u.full_name();
            if n.trim().is_empty() { "Tài khoản đã xoá".into() } else { n }
        }
        _ => p.name().unwrap_or("").to_string(),
    }
}

/// Tệp tạm riêng cho mỗi lần tải / ghi (`<tên>.<số>.part`): hai lệnh cùng tải một tệp (ô chat vẽ lại khi tin vừa gửi xong…)
/// không ghi chồng lên nhau — trước đây cùng tên `.part` → tệp hỏng (sticker video báo DECODE) và lệnh sau đổi tên lỗi IO.
fn part_path(path: &std::path::Path) -> std::path::PathBuf {
    static N: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    path.with_extension(format!("{}.part", N.fetch_add(1, std::sync::atomic::Ordering::Relaxed)))
}

/// Tin gửi trả lời `reply_to`; không có mà đang ở chủ đề diễn đàn `topic` (≠ General) → trả lời tin tạo chủ đề = gửi vào chủ đề.
/// Trả lời một tin trong chủ đề thì máy chủ tự xếp vào chủ đề của tin đó.
fn reply_arg(a: &Value) -> Option<i32> {
    a.get("reply_to").and_then(Value::as_i64).or_else(|| a.get("topic").and_then(Value::as_i64).filter(|t| *t > 1)).map(|x| x as i32)
}

fn peer_kind(p: &Peer) -> &'static str {
    match p {
        Peer::User(_) => "user",
        Peer::Group(_) => "group",
        Peer::Channel(_) => "channel",
        Peer::Community(_) => "group",
    }
}

/// Người / nhóm / kênh cho kết quả tìm, danh bạ: khoá, tên, loại, @tên, ảnh (+ trạng thái, số điện thoại, bot với người).
fn peer_json(p: &Peer) -> Value {
    let (photo, photo_dc) = peer_photo(p);
    let mut v = json!({
        "peer": peer_key(p.id()),
        "name": peer_name(p),
        "kind": peer_kind(p),
        "forum": is_forum(p),
        "left": links::is_left(p),
        "username": p.username(),
        "photo": photo,
        "photo_dc": photo_dc,
    });
    if let Peer::User(u) = p {
        v["phone"] = json!(u.phone());
        v["bot"] = json!(u.is_bot());
        v["status"] = status_json(u.status());
    }
    v
}

fn user_json(u: &grammers_client::peer::User) -> Value {
    let (photo, photo_dc) = peer_photo(&Peer::User(u.clone()));
    json!({"id": peer_key(u.id()), "name": u.full_name(), "username": u.username(), "phone": u.phone(),
           "photo": photo, "photo_dc": photo_dc})
}

fn media_kind(m: &Media) -> &'static str {
    match m {
        Media::Photo(_) => "photo",
        Media::Sticker(_) => "sticker",
        Media::Document(d) => {
            let mime = d.mime_type().unwrap_or("");
            if mime == "audio/ogg" {
                "voice"
            } else if mime.starts_with("video/") {
                "video"
            } else if mime.starts_with("audio/") {
                "audio"
            } else if mime.starts_with("image/") {
                "image"
            } else {
                "file"
            }
        }
        Media::Contact(_) => "contact",
        Media::Poll(_) => "poll",
        Media::Geo(_) | Media::GeoLive(_) | Media::Venue(_) => "geo",
        Media::Dice(_) => "dice",
        Media::WebPage(_) => "webpage",
        _ => "media",
    }
}

/// Các link trong tin: link trong chữ (thực thể Url — vị trí tính theo UTF-16), link ẩn sau chữ (TextUrl), nút URL dưới
/// tin. App dùng để mở link / nhận link proxy (tg://proxy, t.me/proxy…) kể cả khi link nằm sau chữ «Connect».
fn links(m: &Message) -> Vec<String> {
    use grammers_client::tl::enums::{InlineButtonType, KeyboardInlineButton, KeyboardInlineButtonRow, MessageEntity, ReplyMarkup};
    let mut out: Vec<String> = Vec::new();
    let mut push = |u: String| {
        if !u.is_empty() && !out.contains(&u) {
            out.push(u);
        }
    };
    if let Some(ents) = m.fmt_entities() {
        let utf16: Vec<u16> = m.text().encode_utf16().collect();
        for e in ents {
            match e {
                MessageEntity::Url(u) => {
                    let (a, b) = (u.offset.max(0) as usize, (u.offset + u.length).max(0) as usize);
                    if a < b && b <= utf16.len() {
                        push(String::from_utf16_lossy(&utf16[a..b]));
                    }
                }
                MessageEntity::TextUrl(u) => push(u.url.clone()),
                // @tên trong chữ: chạm tin → mở chat / kênh đó ngay trong app
                MessageEntity::Mention(u) => {
                    let (a, b) = (u.offset.max(0) as usize, (u.offset + u.length).max(0) as usize);
                    if a < b && b <= utf16.len() {
                        push(String::from_utf16_lossy(&utf16[a..b]));
                    }
                }
                _ => {}
            }
        }
    }
    // Link dạng chữ không có thực thể (Telegram không gắn thực thể cho tg://…, hoặc tin gửi từ app không tự dò link)
    for l in text_links(m.text()) {
        push(l);
    }
    if let Some(ReplyMarkup::ReplyInlineMarkup(mk)) = m.reply_markup() {
        for KeyboardInlineButtonRow::Row(row) in mk.rows {
            for KeyboardInlineButton::Button(b) in row.buttons {
                if let InlineButtonType::Url(u) = b.r#type {
                    push(u.url);
                }
            }
        }
    }
    out
}

/// Dò link trong chữ: cụm (cách nhau bởi khoảng trắng) bắt đầu bằng `tg://`, `http://`, `https://`, hoặc có `t.me/` /
/// `telegram.me/`; bỏ dấu câu dính ở cuối.
pub fn text_links(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    for tok in text.split_whitespace() {
        let t = tok.trim_start_matches(['(', '[', '«', '"', '\'', '<']).trim_end_matches([
            ')', ']', '»', '"', '\'', '>', '.', ',', ';', ':', '!', '?',
        ]);
        let l = t.to_ascii_lowercase();
        let hit = l.starts_with("tg://")
            || l.starts_with("http://")
            || l.starts_with("https://")
            || l.starts_with("t.me/")
            || l.starts_with("telegram.me/")
            || l.starts_with("www.");
        if hit && t.len() > 6 && !out.iter().any(|x: &String| x == t) {
            out.push(t.to_string());
        }
    }
    out
}

/// Link proxy đầu tiên đọc được (MTProxy / SOCKS5) trong các link của tin.
fn proxy_link(links: &[String]) -> Option<String> {
    links.iter().find(|l| gm_net::parse_link(l).is_ok()).cloned()
}

/// Câu mô tả tin hệ thống (vào nhóm, đổi tên, ghim…).
fn action_text(m: &Message) -> Option<String> {
    use grammers_client::tl::enums::MessageAction as A;
    let a = m.action()?;
    // Không có người gửi (quản trị viên ẩn danh, tin của kênh / nhóm): tên chat — như Telegram gốc
    let who = m.sender().or(m.peer()).map(peer_name).unwrap_or_else(|| "Ai đó".into());
    let sender_id = m.sender().and_then(|p| p.id().bare_id());
    Some(match a {
        A::ChatCreate(x) => format!("{who} đã tạo nhóm «{}»", x.title),
        A::ChannelCreate(x) => format!("Kênh «{}» đã được tạo", x.title),
        A::ChatEditTitle(x) => format!("{who} đã đổi tên nhóm thành «{}»", x.title),
        A::ChatEditPhoto(_) => format!("{who} đã đổi ảnh nhóm"),
        A::ChatDeletePhoto => format!("{who} đã xoá ảnh nhóm"),
        A::ChatAddUser(x) if x.users.len() == 1 && Some(x.users[0]) == sender_id => format!("{who} đã vào nhóm"),
        A::ChatAddUser(x) => format!("{who} đã thêm {} thành viên", x.users.len()),
        A::ChatDeleteUser(x) if Some(x.user_id) == sender_id => format!("{who} đã rời nhóm"),
        A::ChatDeleteUser(_) => format!("{who} đã xoá một thành viên"),
        A::ChatJoinedByLink(_) | A::ChatJoinedByRequest => format!("{who} đã vào nhóm qua link mời"),
        A::ChatMigrateTo(_) | A::ChannelMigrateFrom(_) => "Nhóm đã chuyển thành siêu nhóm".into(),
        A::PinMessage => format!("{who} đã ghim một tin nhắn"),
        A::HistoryClear => "Lịch sử chat đã được xoá".into(),
        A::ContactSignUp => format!("{who} đã tham gia Telegram"),
        A::ScreenshotTaken => format!("{who} đã chụp màn hình"),
        A::PhoneCall(x) => {
            let kind = if x.video { "Cuộc gọi video" } else { "Cuộc gọi" };
            match x.duration {
                Some(s) if s > 0 => format!("{kind} ({}:{:02})", s / 60, s % 60),
                _ => format!("{kind} nhỡ / bị từ chối"),
            }
        }
        A::GroupCall(_) | A::GroupCallScheduled(_) => "Cuộc gọi nhóm".into(),
        A::SetMessagesTtl(x) if x.period > 0 => format!("{who} đã bật tự xoá tin"),
        A::SetMessagesTtl(_) => format!("{who} đã tắt tự xoá tin"),
        A::TopicCreate(x) => format!("Chủ đề «{}» đã được tạo", x.title),
        // Sửa chủ đề: đổi tên / đóng / mở lại / ẩn (General) / đổi biểu tượng
        A::TopicEdit(x) => match (&x.title, x.closed, x.hidden) {
            (Some(t), _, _) => format!("{who} đã đổi tên chủ đề thành «{t}»"),
            (None, Some(true), _) => format!("{who} đã đóng chủ đề"),
            (None, Some(false), _) => format!("{who} đã mở lại chủ đề"),
            (None, None, Some(true)) => format!("{who} đã ẩn chủ đề"),
            (None, None, Some(false)) => format!("{who} đã hiện lại chủ đề"),
            (None, None, None) => format!("{who} đã đổi biểu tượng chủ đề"),
        },
        A::CustomAction(x) => x.message.clone(),
        _ => "Tin hệ thống".into(),
    })
}

/// Ảnh trong tin: kích thước gốc + ảnh mờ thu nhỏ (base64) để app vẽ khung đúng tỉ lệ trước khi tải.
fn photo_json(m: &Message) -> Value {
    let Some(Media::Photo(p)) = m.media() else { return Value::Null };
    let (w, h) = crate::media::photo_dims(&p).unwrap_or((320, 320));
    json!({"w": w, "h": h, "thumb": crate::media::stripped(&p).map(|b| crate::media::base64(&b))})
}

/// Sticker: emoji thay thế, kích thước, động hay không.
fn sticker_json(m: &Message) -> Value {
    let Some(Media::Sticker(s)) = m.media() else { return Value::Null };
    let (w, h) = s.document.resolution().unwrap_or((512, 512));
    let mime = s.document.mime_type().unwrap_or("");
    let animated = s.is_animated() || mime.starts_with("video/") || mime == "application/x-tgsticker";
    use grammers_client::tl::enums::InputStickerSet as I;
    let set = match &s.raw_attrs.stickerset {
        I::Id(x) => json!({"id": x.id.to_string(), "access_hash": x.access_hash.to_string()}),
        I::ShortName(x) => json!({"short_name": x.short_name}),
        _ => Value::Null,
    };
    json!({"emoji": s.emoji(), "w": w, "h": h, "animated": animated, "mime": mime, "set": set})
}

/// Tệp / video / GIF (không phải tin thoại, sticker): tên, cỡ, mime, loại, thời lượng, kích thước, ảnh mờ thu nhỏ.
fn doc_json(m: &Message) -> Value {
    let Some(Media::Document(d)) = m.media() else { return Value::Null };
    if crate::media::audio_attr(&d).map(|a| a.voice).unwrap_or(false) {
        return Value::Null;
    }
    let mime = d.mime_type().unwrap_or("").to_string();
    let video = crate::media::video_attr(&d);
    let kind = if crate::media::is_gif(&d) {
        "gif"
    } else if video.as_ref().map(|v| v.round_message).unwrap_or(false) {
        "round"
    } else if video.is_some() || mime.starts_with("video/") {
        "video"
    } else if mime.starts_with("audio/") {
        "audio"
    } else {
        "file"
    };
    let (w, h) = d.resolution().unwrap_or((0, 0));
    json!({
        "name": d.name().unwrap_or(""),
        "size": d.size(),
        "mime": mime,
        "kind": kind,
        "duration": d.duration(),
        "w": w,
        "h": h,
        "thumb": crate::media::doc_stripped(&d).map(|b| crate::media::base64(&b)),
        "has_thumb": crate::media::doc_thumb_loc(&d).is_some(),
    })
}

/// Tin thoại: thời lượng (giây) + dạng sóng (0–31).
fn voice_json(m: &Message) -> Value {
    let Some(Media::Document(d)) = m.media() else { return Value::Null };
    let Some(a) = crate::media::audio_attr(&d) else { return Value::Null };
    if !a.voice {
        return Value::Null;
    }
    json!({"duration": a.duration, "waveform": a.waveform.as_deref().map(crate::media::unpack_waveform)})
}

/// Tin được trả lời + chủ đề diễn đàn. Tin trong chủ đề có cờ `forum_topic`: có `reply_to_top_id` → đó là chủ đề, còn
/// `reply_to_msg_id` là tin được trả lời; không có → `reply_to_msg_id` chính là chủ đề (tin thường trong chủ đề, KHÔNG phải trả
/// lời — trước đây app hiện thành trích dẫn «Tin nhắn …»). Tin tạo chủ đề: chủ đề = chính nó. Không thuộc chủ đề nào → None
/// (nhóm diễn đàn: chủ đề General, id 1).
fn reply_topic(m: &Message) -> (Option<i32>, Option<i32>) {
    use grammers_client::tl::enums;
    let (header, service) = match &m.raw {
        enums::Message::Message(x) => (x.reply_to.as_ref(), false),
        enums::Message::Service(x) => {
            if matches!(x.action, enums::MessageAction::TopicCreate(_)) {
                return (None, Some(x.id));
            }
            (x.reply_to.as_ref(), true)
        }
        enums::Message::Empty(_) => (None, false),
    };
    let Some(enums::MessageReplyHeader::Header(h)) = header else { return (None, None) };
    let (reply, topic) = match (h.forum_topic, h.reply_to_top_id) {
        (true, Some(top)) => (h.reply_to_msg_id, Some(top)),
        (true, None) => (None, h.reply_to_msg_id),
        (false, _) => (h.reply_to_msg_id, None),
    };
    (if service { None } else { reply }, topic)
}

/// Nhóm có chủ đề (siêu nhóm bật «Chủ đề»).
fn is_forum(p: &Peer) -> bool {
    match p {
        Peer::Group(g) => matches!(&g.raw, grammers_client::tl::enums::Chat::Channel(c) if c.forum),
        _ => false,
    }
}

/// Tin nhắn dạng JSON cho app.
pub fn msg_json(m: &Message) -> Value {
    if let Some(p) = m.sender() {
        remember(p);
    }
    if let Some(p) = m.peer() {
        remember(p);
    }
    let links = links(m);
    let action = action_text(m);
    let media = m.media().map(|x| media_kind(&x)).filter(|k| *k != "webpage");
    let (reply_to, topic) = reply_topic(m);
    json!({
        "id": m.id(),
        "peer": peer_key(m.peer_id()),
        "date": m.date().as_second(),
        "out": m.outgoing(),
        "text": action.as_deref().unwrap_or(m.text()),
        "from": m.sender().map(peer_name),
        "from_id": m.sender().map(|p| peer_key(p.id())),
        "media": media,
        "service": action.is_some(),
        "reply_to": reply_to,
        "topic": topic,
        "edited": m.edit_date().is_some(),
        "scheduled": m.from_scheduled(),
        "silent": m.silent(),
        "mentioned": m.mentioned(),
        "proxy": proxy_link(&links),
        "fwd": fwd_name(m),
        "photo": photo_json(m),
        "sticker": sticker_json(m),
        "voice": voice_json(m),
        "doc": doc_json(m),
        "links": links,
        "reactions": react::msg_reactions(m),
        "buttons": bots::inline_buttons(m),
        "keyboard": bots::reply_keyboard(m),
        "poll": poll::msg_poll(m),
        "pinned": m.pinned(),
        "geo": geo::msg_geo(m),
        "contact": contact::msg_contact(m),
    })
}

mod bots;
mod contact;
mod geo;
mod links;
mod pins;
mod poll;
mod react;
mod sched;
mod vietqr;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_links_in_text() {
        let t = "Proxy nè: tg://proxy?port=443&secret=ee11&server=a.b, còn web (https://example.com/x). t.me/proxy?server=x&port=1&secret=dd00 www.vnexpress.net!";
        assert_eq!(
            text_links(t),
            vec![
                "tg://proxy?port=443&secret=ee11&server=a.b",
                "https://example.com/x",
                "t.me/proxy?server=x&port=1&secret=dd00",
                "www.vnexpress.net",
            ]
        );
        assert!(text_links("không có link nào ở đây").is_empty());
    }

    #[test]
    fn picks_proxy() {
        let links = vec![
            "https://example.com".to_string(),
            "tg://proxy?port=10443&secret=ee112233445566778899aabbccddeeff00676f6f676c652e636f6d&server=syn01.example.org".to_string(),
        ];
        assert_eq!(proxy_link(&links).as_deref(), Some(links[1].as_str()));
        assert_eq!(proxy_link(&links[..1]), None);
    }
}

/// Giới hạn `http.get` (danh sách bản phát hành GitHub cỡ vài chục KB) và `http.download` (gói .deb cỡ vài MB)
const MAX_HTTP_TEXT: usize = 2 << 20;
const MAX_HTTP_DOWNLOAD: u64 = 128 << 20;
