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
  listen [giây] [catchup]  in tin mới (mặc định 60 giây; catchup = lấy bù tin đã lỡ)
  call <tên> [giây] [thư mục]  gọi thoại thử: gọi đi, in 4 emoji khoá, giữ máy [giây] (mặc định 30) rồi gác
  answer [chờ] [giây] [thư mục]  gọi thoại thử: chờ cuộc gọi đến [chờ] giây (120), nghe máy, giữ [giây] rồi gác
  callselftest [giây] [độ phức tạp] [băng thông Hz] [voice|tone|none]  tự kiểm engine gọi thoại (2 engine qua 127.0.0.1), đo CPU"
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
        if cmd == "calldump" {
            // calldump <thư mục> [caller|callee] — giải mã các gói báo hiệu đã ghi bởi `call` (key.bin + sig-*.bin)
            let [dir, more @ ..] = rest.as_slice() else { return Err("calldump <thư mục> [caller|callee]".into()) };
            let key: [u8; 256] = std::fs::read(format!("{dir}/key.bin")).map_err(|e| e.to_string())?.try_into()
                .map_err(|_| "key.bin phải 256 byte".to_string())?;
            // Gói trong thư mục là của bên kia: mình gọi → bên kia là bên nghe (mặc định)
            let sender_is_caller = more.first().map(|s| s == "caller").unwrap_or(false);
            let x = gm_call::crypt::x_for(sender_is_caller, gm_call::crypt::Channel::Signaling);
            let mut files: Vec<_> = std::fs::read_dir(dir).map_err(|e| e.to_string())?.filter_map(|e| e.ok())
                .map(|e| e.path()).filter(|p| p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with("sig-"))).collect();
            files.sort();
            for f in files {
                let pkt = std::fs::read(&f).map_err(|e| e.to_string())?;
                let name = f.file_name().unwrap().to_string_lossy().to_string();
                match gm_call::crypt::decrypt(&key, x, &pkt) {
                    None => println!("{name}: {} byte — msg_key SAI (x = {x})", pkt.len()),
                    Some(b) => {
                        std::fs::write(f.with_extension("dec"), &b).map_err(|e| e.to_string())?;
                        let hex: String = b.iter().take(24).map(|c| format!("{c:02x}")).collect();
                        let text: String = b.iter().take(160).map(|&c| if (32..127).contains(&c) { c as char } else { '.' }).collect();
                        println!("{name}: {} byte → {} byte  {hex}
    {text}", pkt.len(), b.len());
                    }
                }
            }
            return Ok(());
        }
        if cmd == "opusbench" {
            // opusbench [giây = 20] [độ phức tạp] [băng thông Hz] — CPU bộ mã / bộ giải Opus của cuộc gọi
            let secs = rest.first().and_then(|s| s.parse().ok()).unwrap_or(20);
            let cx = rest.get(1).and_then(|s| s.parse().ok()).unwrap_or(gm_call::tg::audio::DEFAULT_COMPLEXITY);
            let bw = rest.get(2).and_then(|s| s.parse().ok()).unwrap_or(gm_call::tg::audio::DEFAULT_BANDWIDTH);
            return account::call::opusbench(secs, cx, bw, rest.get(3).map(String::as_str));
        }
        if cmd == "callselftest" {
            // callselftest [giây] — tự kiểm engine gọi thoại không cần tài khoản (2 engine qua 127.0.0.1), đo CPU
            // callselftest [giây = 20] [độ phức tạp Opus] [băng thông Hz] [voice|tone = voice] — mặc định = thiết lập cuộc gọi
            let secs = rest.first().and_then(|s| s.parse().ok()).unwrap_or(20);
            let cx = rest.get(1).and_then(|s| s.parse().ok()).unwrap_or(gm_call::tg::audio::DEFAULT_COMPLEXITY);
            let bw = rest.get(2).and_then(|s| s.parse().ok()).unwrap_or(gm_call::tg::audio::DEFAULT_BANDWIDTH);
            let signal = rest.get(3).map(String::as_str).unwrap_or("voice");
            return account::call::selftest(secs, cx, bw, signal).await;
        }
        if cmd == "opusdump" {
            // opusdump <opus.bin> [ra.wav] — giải lại các gói Opus đã lưu bởi `call` (u16 độ dài + byte), in TOC / cỡ / đỉnh
            let [src, more @ ..] = rest.as_slice() else { return Err("opusdump <opus.bin> [ra.wav]".into()) };
            let data = std::fs::read(src).map_err(|e| e.to_string())?;
            let mut dec = gm_opus::Decoder::new(48_000, 1).map_err(|e| e.to_string())?;
            let (mut i, mut k, mut pcm) = (0usize, 0usize, Vec::<i16>::new());
            let mut tocs = std::collections::BTreeMap::<u8, usize>::new();
            let mut out = vec![0i16; 5760];
            while i + 2 <= data.len() {
                let n = u16::from_be_bytes([data[i], data[i + 1]]) as usize;
                let Some(p) = data.get(i + 2..i + 2 + n) else { break };
                i += 2 + n;
                *tocs.entry(p.first().copied().unwrap_or(0)).or_default() += 1;
                let r = dec.decode(p, &mut out);
                let (samples, peak) = match &r {
                    Ok(s) => (*s, out[..*s].iter().map(|x| x.unsigned_abs()).max().unwrap_or(0)),
                    Err(_) => (0, 0),
                };
                if let Ok(s) = r {
                    pcm.extend_from_slice(&out[..s]);
                }
                if k < 40 || k % 50 == 0 {
                    let hex: String = p.iter().take(10).map(|c| format!("{c:02x}")).collect();
                    println!("#{k:4} {n:4} byte toc {:02x} (config {:2}, stereo {}, code {}) → {samples} mẫu, đỉnh {peak}  {hex}",
                        p.first().copied().unwrap_or(0), p.first().map(|t| t >> 3).unwrap_or(0),
                        p.first().map(|t| (t >> 2) & 1).unwrap_or(0), p.first().map(|t| t & 3).unwrap_or(0));
                }
                k += 1;
            }
            println!("{k} gói; TOC: {tocs:02x?}; {:.1} giây; đỉnh {}", pcm.len() as f64 / 48_000.0,
                pcm.iter().map(|x| x.unsigned_abs()).max().unwrap_or(0));
            if let Some(dst) = more.first() {
                std::fs::write(dst, account::call::wav(&pcm, 48_000)).map_err(|e| e.to_string())?;
                println!("Ghi {dst}");
            }
            return Ok(());
        }
        if cmd == "callreplay" {
            // callreplay <thư mục> — đưa lại các gói báo hiệu đã ghi vào Channel (vai bên gọi), giải mã gói trả lời của mình
            let [dir, ..] = rest.as_slice() else { return Err("callreplay <thư mục>".into()) };
            let key: [u8; 256] = std::fs::read(format!("{dir}/key.bin")).map_err(|e| e.to_string())?.try_into()
                .map_err(|_| "key.bin phải 256 byte".to_string())?;
            let mut ch = gm_call::tg::signaling::Channel::new(gm_call::tg::CallKey(key), true);
            let x_ours = gm_call::crypt::x_for(true, gm_call::crypt::Channel::Signaling);
            let hex = |b: &[u8]| b.iter().take(120).map(|c| format!("{c:02x}")).collect::<String>();
            let mut files: Vec<_> = std::fs::read_dir(dir).map_err(|e| e.to_string())?.filter_map(|e| e.ok())
                .map(|e| e.path()).filter(|p| p.extension().is_some_and(|e| e == "bin")
                    && p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with("sig-"))).collect();
            files.sort();
            let now = std::time::Instant::now();
            for f in files {
                let pkt = std::fs::read(&f).map_err(|e| e.to_string())?;
                let (msgs, reply) = ch.receive(&pkt, now);
                println!("{}: {} tin", f.file_name().unwrap().to_string_lossy(), msgs.len());
                if let Some(r) = reply {
                    match gm_call::crypt::decrypt(&key, x_ours, &r) {
                        Some(p) => println!("   trả lời: {}", hex(&p)),
                        None => println!("   trả lời: không giải được ({} byte)", r.len()),
                    }
                }
            }
            return Ok(());
        }
        if cmd == "svc" {
            return svc(&rest).await;
        }
        if cmd == "lottie" {
            // lottie <tệp .tgs / .json> <thư mục ra> [cỡ px] [số khung] — vẽ thử sticker động ra PNG (+ bảng tổng hợp sheet.png)
            let [src, dir, more @ ..] = rest.as_slice() else { return Err("lottie <tệp> <thư mục> [cỡ] [số khung]".into()) };
            let size: u32 = more.first().and_then(|s| s.parse().ok()).unwrap_or(256);
            let want: u32 = more.get(1).and_then(|s| s.parse().ok()).unwrap_or(8);
            let data = std::fs::read(src).map_err(|e| e.to_string())?;
            let t = Instant::now();
            let a = gm_lottie::Animation::parse(&data)?;
            let parse_ms = t.elapsed().as_millis();
            let frames = a.frames();
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
            let n = want.min(frames).max(1);
            let cols = n.min(4);
            let rows = n.div_ceil(cols);
            let mut sheet = vec![255u8; (cols * size * rows * size * 4) as usize];
            let mut buf = vec![0u8; (size * size * 4) as usize];
            let t = Instant::now();
            for k in 0..n {
                let f = (k * frames / n) as f32;
                a.render(f, &mut buf, size, size);
                let (cx, cy) = ((k % cols) * size, (k / cols) * size);
                for y in 0..size {
                    for x in 0..size {
                        let s = ((y * size + x) * 4) as usize;
                        let d = (((cy + y) * cols * size + cx + x) * 4) as usize;
                        // Trộn lên nền trắng (bộ đệm đã nhân alpha)
                        let al = buf[s + 3] as u32;
                        for c in 0..3 {
                            sheet[d + c] = (buf[s + c] as u32 + (255 - al) * 255 / 255).min(255) as u8;
                        }
                        sheet[d + 3] = 255;
                    }
                }
            }
            let ms = t.elapsed().as_millis();
            let file = std::fs::File::create(format!("{dir}/sheet.png")).map_err(|e| e.to_string())?;
            let mut enc = png::Encoder::new(std::io::BufWriter::new(file), cols * size, rows * size);
            enc.set_color(png::ColorType::Rgba);
            enc.set_depth(png::BitDepth::Eight);
            enc.write_header().map_err(|e| e.to_string())?.write_image_data(&sheet).map_err(|e| e.to_string())?;
            let (w, h) = a.size();
            println!("{src}: {w}x{h}, {} fps, {frames} khung; đọc {parse_ms} ms; vẽ {n} khung {size}px: {ms} ms ({:.1} ms/khung)",
                     a.frame_rate(), ms as f64 / n as f64);
            return Ok(());
        }
        if cmd == "webm" {
            // webm <tệp .webm> <thư mục ra> [cỡ px] [số khung] [số lượt] — giải mã thử sticker video (mọi khung, tuần tự như app,
            // lặp [số lượt] lần để đo cả lúc quay về đầu) → sheet.png (nền ô cờ để thấy kênh trong suốt)
            let [src, dir, more @ ..] = rest.as_slice() else { return Err("webm <tệp> <thư mục> [cỡ] [số khung] [số lượt]".into()) };
            let size: usize = more.first().and_then(|s| s.parse().ok()).unwrap_or(256);
            let want: usize = more.get(1).and_then(|s| s.parse().ok()).unwrap_or(8);
            let loops: usize = more.get(2).and_then(|s| s.parse().ok()).unwrap_or(1).max(1);
            let data = std::fs::read(src).map_err(|e| e.to_string())?;
            let t = Instant::now();
            let mut v = gm_webm::Video::parse(data).ok_or("không đọc được WebM (VP9)")?;
            let parse_ms = t.elapsed().as_secs_f64() * 1000.0;
            let frames = v.frame_count();
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
            let n = want.min(frames).max(1);
            let pick: Vec<usize> = (0..n).map(|k| k * frames / n).collect();
            let cols = n.min(4);
            let rows = n.div_ceil(cols);
            let mut sheet = vec![255u8; cols * size * rows * size * 4];
            let mut buf = vec![0u8; size * size * 4];
            let mut fails = 0;
            let t = Instant::now();
            for lp in 0..loops {
                for f in 0..frames {
                    if !v.render(f, &mut buf, size, size) {
                        fails += 1;
                        continue;
                    }
                    let Some(k) = pick.iter().position(|&p| p == f) else { continue };
                    if lp != 0 {
                        continue;
                    }
                    let (cx, cy) = ((k % cols) * size, (k / cols) * size);
                    for y in 0..size {
                        for x in 0..size {
                            let s = (y * size + x) * 4;
                            let d = ((cy + y) * cols * size + cx + x) * 4;
                            // Trộn lên nền ô cờ (bộ đệm đã nhân alpha)
                            let bg: u32 = if ((x / 16) + (y / 16)) % 2 == 0 { 255 } else { 200 };
                            let al = buf[s + 3] as u32;
                            for c in 0..3 {
                                sheet[d + c] = (buf[s + c] as u32 + (255 - al) * bg / 255).min(255) as u8;
                            }
                            sheet[d + 3] = 255;
                        }
                    }
                }
            }
            let ms = t.elapsed().as_secs_f64() * 1000.0;
            let file = std::fs::File::create(format!("{dir}/sheet.png")).map_err(|e| e.to_string())?;
            let mut enc = png::Encoder::new(std::io::BufWriter::new(file), (cols * size) as u32, (rows * size) as u32);
            enc.set_color(png::ColorType::Rgba);
            enc.set_depth(png::BitDepth::Eight);
            enc.write_header().map_err(|e| e.to_string())?.write_image_data(&sheet).map_err(|e| e.to_string())?;
            let (w, h) = v.size();
            println!("{src}: {w}x{h}, {:.2} fps, {frames} khung, alpha: {}; đọc {parse_ms:.1} ms; giải + vẽ {} khung {size}px: {ms:.0} ms ({:.2} ms/khung), lỗi {fails}",
                     v.frame_rate(), v.has_alpha(), frames * loops, ms / (frames * loops) as f64);
            return Ok(());
        }
        if cmd == "hevc" {
            // hevc <tệp .mp4 H.265> <thư mục ra> [cạnh ngắn tối đa] [số khung] [fast] — giải mã thử (như app chuyển sang H.264): đo
            // tốc độ, ghi vài khung NV12 → PNG (frame-<i>.png); «fast» = bỏ khung không làm tham chiếu (như máy một nhân)
            let [src, dir, more @ ..] = rest.as_slice() else { return Err("hevc <tệp> <thư mục> [cạnh ngắn] [số khung] [fast]".into()) };
            let short: u32 = more.first().and_then(|s| s.parse().ok()).unwrap_or(480);
            let want: usize = more.get(1).and_then(|s| s.parse().ok()).unwrap_or(usize::MAX);
            let fast = more.get(2).map(|s| s == "fast").unwrap_or(false);
            let mut v = gm_hevc::Video::open(std::path::Path::new(src), short, fast)?;
            let i = v.info();
            println!("{src}: {}x{} → {}x{}, {} khung, thang {} , {:.1} giây, ma trận {:?}", i.width, i.height, i.out_width,
                     i.out_height, i.frames, i.timescale, i.duration as f64 / i.timescale as f64, i.matrix);
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
            let (ow, oh) = (i.out_width as usize, i.out_height as usize);
            let (mut y, mut uv) = (vec![0u8; ow * oh], vec![0u8; ow * oh / 2]);
            let t = Instant::now();
            let (mut n, mut last) = (0usize, -1i64);
            while n < want {
                let Some(pts) = v.next(&mut y, ow, &mut uv, ow)? else { break };
                if pts <= last {
                    println!("khung {n}: pts {pts} không tăng (trước {last})");
                }
                last = pts;
                if n % 60 == 0 && n / 60 < 4 {
                    // NV12 dải video → RGB (BT.709)
                    let mut rgb = vec![0u8; ow * oh * 3];
                    for yy in 0..oh {
                        for xx in 0..ow {
                            let l = (y[yy * ow + xx] as f32 - 16.0) * 1.164;
                            let u = uv[(yy / 2) * ow + (xx / 2) * 2] as f32 - 128.0;
                            let vv = uv[(yy / 2) * ow + (xx / 2) * 2 + 1] as f32 - 128.0;
                            let p = (yy * ow + xx) * 3;
                            rgb[p] = (l + 1.793 * vv).clamp(0.0, 255.0) as u8;
                            rgb[p + 1] = (l - 0.213 * u - 0.533 * vv).clamp(0.0, 255.0) as u8;
                            rgb[p + 2] = (l + 2.112 * u).clamp(0.0, 255.0) as u8;
                        }
                    }
                    let file = std::fs::File::create(format!("{dir}/frame-{n}.png")).map_err(|e| e.to_string())?;
                    let mut enc = png::Encoder::new(std::io::BufWriter::new(file), ow as u32, oh as u32);
                    enc.set_color(png::ColorType::Rgb);
                    enc.set_depth(png::BitDepth::Eight);
                    enc.write_header().map_err(|e| e.to_string())?.write_image_data(&rgb).map_err(|e| e.to_string())?;
                }
                n += 1;
            }
            let s = t.elapsed().as_secs_f64();
            println!("giải {n} khung trong {s:.1} giây: {:.1} khung / giây (pts cuối {last})", n as f64 / s);
            return Ok(());
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
            ("call", [who, more @ ..]) => {
                let hold = more.first().and_then(|s| s.parse().ok()).unwrap_or(30);
                account::call::call(&mut c, who, hold, more.get(1).map(String::as_str)).await
            }
            ("answer", more) if more.len() <= 3 => {
                // answer [giây chờ = 120] [giây giữ máy = 30] [thư mục ghi]
                let wait = more.first().and_then(|s| s.parse().ok()).unwrap_or(120);
                let hold = more.get(1).and_then(|s| s.parse().ok()).unwrap_or(30);
                account::call::answer(&mut c, wait, hold, more.get(2).map(String::as_str)).await
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
