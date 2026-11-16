//! gm-cli — chạy thử lõi GramMini: trên PC (`cargo run -p gm-cli`) và trên máy iOS (thư viện tĩnh + `gm_cli_main`, xem
//! `spike/01-probe`).
//!
//!   gm-cli probe [--dc 2] [--proxy "<link tg://proxy… / tg://socks…>"]
//!
//! `probe`: mở kết nối tới DC theo đường đã chọn, tạo auth key (trao đổi DH với máy chủ), gửi `ping`. Không cần api_id.
//! Có biến môi trường `GM_API_ID` thì gọi thêm `help.getNearestDc` (máy chủ báo quốc gia của IP đi ra).

use std::net::SocketAddr;
use std::time::{Duration, Instant};

use gm_net::{GmConnector, ProxyConfig, parse_link};
use grammers_mtsender::{ServerAddr, connect};
use grammers_tl_types as tl;

/// Địa chỉ tĩnh của các DC (như `grammers-session/src/dc_options.rs`).
const DCS: [(i32, &str); 5] = [
    (1, "149.154.175.53:443"),
    (2, "149.154.167.41:443"),
    (3, "149.154.175.100:443"),
    (4, "149.154.167.92:443"),
    (5, "91.108.56.104:443"),
];

mod account;

fn usage() -> i32 {
    eprintln!(
        "gm-cli <lệnh> [--proxy \"tg://proxy?…\"] [--session gm-session.json] [--dc 1-5]
  probe                 tạo auth key + ping (không cần đăng nhập)
  login                 đăng nhập: số điện thoại → mã → mật khẩu 2 lớp
  me                    tài khoản đang đăng nhập
  dialogs [N]           N chat đầu (mặc định 20)
  send <me|@user> <chữ> gửi tin (me = Tin nhắn đã lưu)
  listen [giây] [catchup]  in tin mới (mặc định 60 giây; catchup = lấy bù tin đã lỡ)"
    );
    2
}

/// Chạy lệnh (đối số không gồm tên chương trình). Trả mã thoát.
pub fn run(args: Vec<String>) -> i32 {
    let Some(cmd) = args.first().cloned() else { return usage() };
    let (mut dc, mut cfg, mut session) = (2, ProxyConfig::Direct, "gm-session.json".to_string());
    let mut rest = Vec::new();
    let mut i = 1;
    while i < args.len() {
        match (args[i].as_str(), args.get(i + 1)) {
            ("--dc", Some(v)) => match v.parse() {
                Ok(n) => dc = n,
                Err(_) => return usage(),
            },
            ("--proxy", Some(v)) => match parse_link(v) {
                Ok(c) => cfg = c,
                Err(e) => {
                    eprintln!("{e}");
                    return 2;
                }
            },
            ("--session", Some(v)) => session = v.clone(),
            (a, _) => {
                rest.push(a.to_string());
                i += 1;
                continue;
            }
        }
        i += 2;
    }
    println!(
        "gm-cli {} — {} {}-bit",
        env!("CARGO_PKG_VERSION"),
        std::env::consts::ARCH,
        usize::BITS
    );
    let rt = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("LỖI: không tạo được runtime tokio: {e}");
            return 1;
        }
    };
    match rt.block_on(async {
        if cmd == "probe" {
            return probe(cfg, dc).await;
        }
        if cmd == "svc" {
            return svc(&rest).await;
        }
        if cmd == "voice" {
            // voice decode <ogg> <wav> | voice encode <wav> <ogg>
            let [op, src, dst] = rest.as_slice() else { return Err("voice decode|encode <vào> <ra>".into()) };
            let data = std::fs::read(src).map_err(|e| e.to_string())?;
            let t = Instant::now();
            let (out, dur) = match op.as_str() {
                "decode" => gm_opus::ogg_to_wav(&data, 24000).map_err(|e| e.to_string())?,
                "encode" => {
                    let (pcm, rate) = gm_opus::read_wav(&data).map_err(|e| e.to_string())?;
                    gm_opus::encode_ogg(&pcm, rate).map_err(|e| e.to_string())?
                }
                _ => return Err("voice decode|encode".into()),
            };
            std::fs::write(dst, &out).map_err(|e| e.to_string())?;
            println!("{op}: {:.2} s âm thanh, {} byte, {} ms", dur, out.len(), t.elapsed().as_millis());
            return Ok(());
        }
        let mut c = account::connect(cfg, &session).await?;
        let r = match (cmd.as_str(), rest.as_slice()) {
            ("login", []) => account::login(&c).await,
            ("me", []) => account::me(&c).await,
            ("dialogs", []) => account::dialogs(&c, 20).await,
            ("dialogs", [n]) => account::dialogs(&c, n.parse().unwrap_or(20)).await,
            ("send", [to, text @ ..]) if !text.is_empty() => account::send(&c, to, &text.join(" ")).await,
            ("listen", args) if args.len() <= 2 => {
                let catch_up = args.iter().any(|a| a == "catchup");
                let secs = args.iter().find_map(|a| a.parse().ok()).unwrap_or(60);
                account::listen(&mut c, secs, catch_up).await
            }
            _ => Err("lệnh / đối số sai — chạy gm-cli không đối số để xem cách dùng".into()),
        };
        c.close().await;
        r
    }) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("LỖI: {e}");
            1
        }
    }
}

/// Điểm vào cho bản iOS (công cụ dòng lệnh: `main.c` gọi hàm này).
///
/// # Safety
/// `argv` phải là mảng `argc` chuỗi C hợp lệ (như đối số của `main`).
#[no_mangle]
pub unsafe extern "C" fn gm_cli_main(argc: std::os::raw::c_int, argv: *const *const std::os::raw::c_char) -> std::os::raw::c_int {
    let args = (1..argc.max(0) as usize)
        .map(|i| unsafe { std::ffi::CStr::from_ptr(*argv.add(i)) }.to_string_lossy().into_owned())
        .collect();
    run(args)
}

/// Che nội dung riêng tư (tên, chữ tin nhắn) khi in kết quả ra màn hình: chỉ giữ độ dài.
fn mask(v: &mut serde_json::Value) {
    match v {
        serde_json::Value::Object(m) => {
            for (k, x) in m.iter_mut() {
                if matches!(k.as_str(), "name" | "from" | "username" | "hint" | "chat_name" | "first" | "last" | "about") || (k == "text" && std::env::var_os("GM_SVC_TEXT").is_none()) {
                    if let Some(s) = x.as_str() {
                        *x = serde_json::Value::String(format!("<{} ký tự>", s.chars().count()));
                    }
                } else {
                    mask(x);
                }
            }
        }
        serde_json::Value::Array(a) => a.iter_mut().for_each(mask),
        _ => {}
    }
}

/// `svc <thư mục dữ liệu> <lệnh> [json tham số] [giây chờ sự kiện]` — gọi thẳng lớp dịch vụ mà app dùng (gm-core::Core).
async fn svc(rest: &[String]) -> Result<(), String> {
    let [dir, method, more @ ..] = rest else {
        return Err("svc <thư mục dữ liệu> <lệnh> [json] [giây]".into());
    };
    let args: serde_json::Value = more.first().map(|s| serde_json::from_str(s).map_err(|e| e.to_string())).transpose()?.unwrap_or(serde_json::json!({}));
    let wait: u64 = more.get(1).and_then(|s| s.parse().ok()).unwrap_or(0);
    let cfg = gm_core::Config {
        data_dir: dir.into(),
        api_id: option_env!("GM_API_ID").and_then(|v| v.parse().ok()).ok_or("chưa có api_id")?,
        api_hash: option_env!("GM_API_HASH").unwrap_or("").into(),
        client: gm_net::ClientInfo {
            device_model: "PC".into(),
            system_version: std::env::consts::OS.into(),
            app_version: format!("GramMini {}", env!("CARGO_PKG_VERSION")),
            lang_code: "vi".into(),
        },
    };
    let emit: gm_core::Emit = std::sync::Arc::new(|mut v| {
        mask(&mut v);
        println!("sự kiện: {v}");
    });
    let core = gm_core::Core::start(cfg, emit).map_err(|e| e.msg)?;
    let t = Instant::now();
    match core.call(method, args).await {
        Ok(mut v) => {
            mask(&mut v);
            let n = v.as_array().map(|a| a.len());
            let s = serde_json::to_string(&v).unwrap_or_default();
            let s: String = if std::env::var_os("GM_SVC_FULL").is_some() { s } else { s.chars().take(700).collect() };
            println!("{method}: xong sau {} ms{} → {s}", t.elapsed().as_millis(), n.map(|n| format!(" ({n} mục)")).unwrap_or_default());
        }
        Err(e) => println!("{method}: LỖI {} sau {} ms", e.to_json(), t.elapsed().as_millis()),
    }
    if wait > 0 {
        tokio::time::sleep(Duration::from_secs(wait)).await;
    }
    let _ = core.call("app.flush", serde_json::json!({})).await;
    Ok(())
}

/// Đo riêng từng bước tới MTProxy (DNS, TCP, bắt tay fake-TLS) — để biết chậm ở đâu.
async fn trace_mtproxy(m: &gm_net::MtProxy) {
    let t = Instant::now();
    match gm_net::clock::ensure_synced().await {
        Some(ms) => println!("  giờ máy lệch {:+.1} s so với NTP (đo trong {} ms)", -ms as f64 / 1000.0, t.elapsed().as_millis()),
        None => println!("  không đo được giờ NTP ({} ms) — ký bằng giờ máy", t.elapsed().as_millis()),
    }
    let t = Instant::now();
    let addrs: Vec<SocketAddr> = match tokio::net::lookup_host((m.host.as_str(), m.port)).await {
        Ok(a) => a.collect(),
        Err(e) => {
            println!("  DNS {}: lỗi {e} sau {} ms", m.host, t.elapsed().as_millis());
            return;
        }
    };
    println!("  DNS {}: {:?} sau {} ms", m.host, addrs, t.elapsed().as_millis());
    for a in addrs.iter().take(2) {
        let t = Instant::now();
        match tokio::time::timeout(Duration::from_secs(10), tokio::net::TcpStream::connect(a)).await {
            Ok(Ok(mut s)) => {
                println!("  TCP {a}: nối sau {} ms", t.elapsed().as_millis());
                if let gm_net::Secret::FakeTls { key, domain } = &m.secret {
                    let t = Instant::now();
                    match gm_net::faketls::handshake(&mut s, key, domain).await {
                        Ok(()) => println!("  fake-TLS: bắt tay xong sau {} ms", t.elapsed().as_millis()),
                        Err(e) => println!("  fake-TLS: lỗi {e} sau {} ms", t.elapsed().as_millis()),
                    }
                }
            }
            Ok(Err(e)) => println!("  TCP {a}: lỗi {e} sau {} ms", t.elapsed().as_millis()),
            Err(_) => println!("  TCP {a}: quá 10 s"),
        }
    }
}

async fn probe(cfg: ProxyConfig, dc: i32) -> Result<(), String> {
    let (_, addr) = DCS.iter().find(|(id, _)| *id == dc).ok_or("DC phải từ 1 tới 5")?;
    let addr: SocketAddr = addr.parse().unwrap();
    println!("đường: {cfg:?} → DC{dc} {addr}");
    if let ProxyConfig::MtProxy(m) = &cfg {
        trace_mtproxy(m).await;
    }
    let conn = GmConnector::new(cfg);
    let t0 = Instant::now();
    let server = ServerAddr::Custom { dc_id: dc, address: addr, connector: conn.clone() };
    let mut sender = tokio::time::timeout(Duration::from_secs(40), connect(conn.transport(), server))
        .await
        .map_err(|_| "tạo auth key quá 40 giây".to_string())?
        .map_err(|e| format!("tạo auth key: {e}"))?;
    println!("auth key: xong sau {} ms", t0.elapsed().as_millis());

    for n in 1..=3 {
        let t = Instant::now();
        let tl::enums::Pong::Pong(p) = sender
            .invoke(&tl::functions::Ping { ping_id: n })
            .await
            .map_err(|e| format!("ping: {e}"))?;
        println!("ping {n}: pong (ping_id {}) sau {} ms", p.ping_id, t.elapsed().as_millis());
    }

    if let Some(api_id) = std::env::var("GM_API_ID").ok().and_then(|v| v.parse::<i32>().ok()) {
        let req = tl::functions::InvokeWithLayer {
            layer: tl::LAYER,
            query: tl::functions::InitConnection {
                api_id,
                device_model: "PC".into(),
                system_version: std::env::consts::OS.into(),
                app_version: env!("CARGO_PKG_VERSION").into(),
                system_lang_code: "vi".into(),
                lang_pack: "".into(),
                lang_code: "vi".into(),
                proxy: None,
                params: None,
                query: tl::functions::help::GetNearestDc {},
            },
        };
        let tl::enums::NearestDc::Dc(d) = sender.invoke(&req).await.map_err(|e| format!("getNearestDc: {e}"))?;
        println!("getNearestDc: quốc gia {}, đang ở DC{}, DC gần nhất DC{} (layer {})", d.country, d.this_dc, d.nearest_dc, tl::LAYER);
    }
    Ok(())
}
