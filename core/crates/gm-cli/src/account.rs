//! Các lệnh cần tài khoản: `login`, `me`, `dialogs`, `send`, `listen` — grammers-client + `gm-net` (proxy) + phiên lưu ra
//! tệp (`gm-core::FileSession`). api_id / api_hash đóng vào tệp chạy lúc dựng (`build.rs`, `keys/telegram.txt`).

use std::io::Write as _;
use std::sync::Arc;
use std::time::{Duration, Instant};

use gm_core::FileSession;
use gm_net::{ClientInfo, GmConnector, ProxyConfig};
use grammers_client::update::Update;
use grammers_client::{Client, SignInError};
use grammers_mtsender::{SenderPool, SenderPoolFatHandle, UpdatesConfiguration};
use grammers_session::updates::UpdatesLike;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

pub mod call;

const API_ID: Option<&str> = option_env!("GM_API_ID");
const API_HASH: Option<&str> = option_env!("GM_API_HASH");

pub struct Conn {
    pub client: Client,
    session: Arc<FileSession>,
    updates: Option<mpsc::Receiver<UpdatesLike>>,
    handle: SenderPoolFatHandle,
    task: JoinHandle<()>,
}

/// Tên máy / hệ điều hành báo cho Telegram (hiện trong «Thiết bị» của tài khoản).
fn device() -> (String, String) {
    #[cfg(target_os = "ios")]
    {
        fn sysctl(name: &str) -> String {
            unsafe extern "C" {
                fn sysctlbyname(name: *const std::os::raw::c_char, oldp: *mut u8, oldlenp: *mut usize, newp: *const u8, newlen: usize) -> i32;
            }
            let n = std::ffi::CString::new(name).unwrap();
            let mut buf = [0u8; 128];
            let mut len = buf.len();
            let ok = unsafe { sysctlbyname(n.as_ptr(), buf.as_mut_ptr(), &mut len, std::ptr::null(), 0) } == 0;
            if !ok {
                return "?".into();
            }
            String::from_utf8_lossy(&buf[..len]).trim_end_matches('\0').to_string()
        }
        (sysctl("hw.machine"), format!("iOS (Darwin {})", sysctl("kern.osrelease")))
    }
    #[cfg(not(target_os = "ios"))]
    {
        ("PC".to_string(), std::env::consts::OS.to_string())
    }
}

pub async fn connect(cfg: ProxyConfig, session_path: &str) -> Result<Conn, String> {
    let api_id: i32 = API_ID
        .and_then(|v| v.parse().ok())
        .ok_or("bản dựng này chưa có api_id (keys/telegram.txt lúc dựng)")?;
    let session = Arc::new(FileSession::open(session_path).map_err(|e| format!("mở tệp phiên {session_path}: {e}"))?);
    let (device_model, system_version) = device();
    let conn = GmConnector::new(cfg);
    let params = conn.connection_params(ClientInfo {
        device_model,
        system_version,
        app_version: format!("GramMini {}", env!("CARGO_PKG_VERSION")),
        lang_code: "vi".into(),
    });
    let SenderPool { runner, updates, handle } = SenderPool::with_configuration(Arc::clone(&session), api_id, params);
    let client = Client::new(handle.clone());
    let task = tokio::spawn(runner.run());
    Ok(Conn { client, session, updates: Some(updates), handle, task })
}

impl Conn {
    /// Ghi phiên, đóng kết nối.
    pub async fn close(self) {
        if let Err(e) = self.session.save() {
            eprintln!("không ghi được tệp phiên: {e}");
        }
        self.handle.quit();
        let _ = self.task.await;
    }

    async fn need_login(&self) -> Result<(), String> {
        if self.client.is_authorized().await.map_err(|e| e.to_string())? {
            Ok(())
        } else {
            Err("chưa đăng nhập — chạy `gm-cli login` trước".into())
        }
    }
}

fn prompt(msg: &str) -> Result<String, String> {
    print!("{msg}");
    std::io::stdout().flush().ok();
    let mut s = String::new();
    std::io::stdin().read_line(&mut s).map_err(|e| e.to_string())?;
    Ok(s.trim().to_string())
}

fn password(msg: &str) -> Result<String, String> {
    #[cfg(not(target_os = "ios"))]
    {
        rpassword::prompt_password(msg).map_err(|e| e.to_string())
    }
    #[cfg(target_os = "ios")]
    {
        prompt(msg)
    }
}

fn short(s: &str, n: usize) -> String {
    let one_line = s.replace('\n', " ⏎ ");
    if one_line.chars().count() > n {
        format!("{}…", one_line.chars().take(n).collect::<String>())
    } else {
        one_line
    }
}

/// Đăng nhập bằng số điện thoại + mã (+ mật khẩu 2FA nếu có).
pub async fn login(c: &Conn) -> Result<(), String> {
    let client = &c.client;
    if client.is_authorized().await.map_err(|e| e.to_string())? {
        let me = client.get_me().await.map_err(|e| e.to_string())?;
        println!("Đã đăng nhập sẵn: {} (id {})", me.full_name(), me.id().bare_id().unwrap_or(0));
        return Ok(());
    }
    let api_hash = API_HASH.ok_or("bản dựng này chưa có api_hash")?;
    let phone = prompt("Số điện thoại (dạng quốc tế, vd +84…): ")?;
    let token = client.request_login_code(&phone, api_hash).await.map_err(|e| format!("gửi mã: {e}"))?;
    let code = prompt("Mã Telegram vừa gửi (trong app Telegram trên máy khác): ")?;
    let user = match client.sign_in(&token, &code).await {
        Ok(u) => u,
        Err(SignInError::PasswordRequired(t)) => {
            let hint = t.hint().unwrap_or("").to_string();
            let pw = password(&format!("Mật khẩu 2 lớp (gợi ý: {hint}): "))?;
            client.check_password(t, pw.trim()).await.map_err(|e| format!("mật khẩu 2 lớp: {e}"))?
        }
        Err(e) => return Err(format!("đăng nhập: {e}")),
    };
    println!("Đăng nhập xong: {} (id {})", user.full_name(), user.id().bare_id().unwrap_or(0));
    Ok(())
}

pub async fn me(c: &Conn) -> Result<(), String> {
    c.need_login().await?;
    let me = c.client.get_me().await.map_err(|e| e.to_string())?;
    println!(
        "Tài khoản: {} (id {}{})",
        me.full_name(),
        me.id().bare_id().unwrap_or(0),
        me.username().map(|u| format!(", @{u}")).unwrap_or_default()
    );
    Ok(())
}

pub async fn dialogs(c: &Conn, limit: usize) -> Result<(), String> {
    c.need_login().await?;
    let t = Instant::now();
    let mut it = c.client.iter_dialogs();
    let mut n = 0;
    while n < limit {
        let Some(d) = it.next().await.map_err(|e| e.to_string())? else { break };
        n += 1;
        let unread = match &d.raw {
            grammers_client::tl::enums::Dialog::Dialog(x) => x.unread_count,
            _ => 0,
        };
        let last = d.last_message.as_ref().map(|m| short(m.text(), 50)).unwrap_or_default();
        println!(
            "{n:>3}. {}{}  — {}",
            short(d.peer().name().unwrap_or("(không tên)"), 30),
            if unread > 0 { format!(" [{unread} chưa đọc]") } else { String::new() },
            last
        );
    }
    println!("({n} chat, {} ms)", t.elapsed().as_millis());
    Ok(())
}

/// Gửi tin: đích `me` (Tin nhắn đã lưu) hoặc `@username`.
pub async fn send(c: &Conn, target: &str, text: &str) -> Result<(), String> {
    c.need_login().await?;
    let peer = if target == "me" {
        c.client.get_me().await.map_err(|e| e.to_string())?.to_ref().await.map_err(|e| e.to_string())?
    } else if let Some(u) = target.strip_prefix('@') {
        let p = c.client.resolve_username(u).await.map_err(|e| e.to_string())?.ok_or(format!("không có @{u}"))?;
        p.to_ref().await.map_err(|e| e.to_string())?
    } else {
        return Err("đích phải là `me` hoặc `@username`".into());
    }
    .ok_or("không lấy được peer")?;
    let t = Instant::now();
    let m = c.client.send_message(peer, text).await.map_err(|e| format!("gửi: {e}"))?;
    println!("Đã gửi (id tin {}) sau {} ms", m.id(), t.elapsed().as_millis());
    Ok(())
}

/// Nghe tin mới trong `secs` giây. `catch_up`: lấy bù tin đã lỡ từ lần lưu trạng thái trước (`getDifference`).
pub async fn listen(c: &mut Conn, secs: u64, catch_up: bool) -> Result<(), String> {
    c.need_login().await?;
    let rx = c.updates.take().ok_or("đã nghe rồi")?;
    let mut stream = c
        .client
        .stream_updates(rx, UpdatesConfiguration { catch_up })
        .await
        .map_err(|e| e.to_string())?;
    println!("Đang nghe tin mới trong {secs} giây{}…", if catch_up { " (lấy bù tin đã lỡ)" } else { "" });
    let end = tokio::time::Instant::now() + Duration::from_secs(secs);
    loop {
        match tokio::time::timeout_at(end, stream.next()).await {
            Err(_) => break,
            Ok(Err(e)) => return Err(e.to_string()),
            Ok(Ok(Update::NewMessage(m))) => {
                let chat = m.peer().and_then(|p| p.name().map(str::to_string)).unwrap_or_else(|| "?".into());
                let from = m.sender().and_then(|p| p.name().map(str::to_string)).unwrap_or_default();
                println!(
                    "[{}] {}{}: {}",
                    chat,
                    if m.outgoing() { "(mình) " } else { "" },
                    from,
                    short(m.text(), 120)
                );
            }
            Ok(Ok(Update::MessageEdited(m))) => println!("(sửa tin {}) {}", m.id(), short(m.text(), 80)),
            Ok(Ok(Update::MessageDeleted(_))) => println!("(xoá tin)"),
            Ok(Ok(_)) => {}
        }
    }
    stream.sync_update_state().await.map_err(|e| e.to_string())?;
    Ok(())
}
