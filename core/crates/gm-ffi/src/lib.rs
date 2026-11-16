//! API C của lõi GramMini cho app iOS (Objective-C). Mọi thứ đi bằng JSON — xem docs/FFI.md.
//!
//! ```c
//! typedef void (*gm_cb)(const char *json, void *ctx);
//! int  gm_init(const char *config_json, gm_cb on_event, void *ctx);   // 0 = được
//! void gm_call(const char *request_json, gm_cb on_result, void *ctx); // chạy nền, kết quả qua on_result (một lần)
//! ```
//!
//! Callback chạy trên luồng của lõi; chuỗi JSON chỉ dùng được trong lúc gọi (app chép ra rồi chuyển về luồng chính).

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

use gm_core::{Config, Core, CoreError};
use gm_net::ClientInfo;
use serde_json::{Value, json};

pub type Callback = extern "C" fn(json: *const c_char, ctx: *mut c_void);

/// Callback + ngữ cảnh của app (con trỏ app tự quản; chỉ chuyển qua lại).
#[derive(Clone, Copy)]
struct Cb {
    f: Callback,
    ctx: usize,
}

impl Cb {
    fn send(&self, v: &Value) {
        if let Ok(s) = CString::new(v.to_string()) {
            (self.f)(s.as_ptr(), self.ctx as *mut c_void);
        }
    }
}

static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
static CORE: OnceLock<Arc<Core>> = OnceLock::new();

fn cstr(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

/// Mở lõi. `config_json`: `{"data_dir", "device_model", "system_version", "app_version", "lang"}`. Trả 0 nếu được, 1 nếu
/// cấu hình sai, 2 nếu bản dựng thiếu api_id, 3 nếu không mở được dữ liệu, 4 nếu đã mở rồi.
#[unsafe(no_mangle)]
pub extern "C" fn gm_init(config_json: *const c_char, on_event: Callback, ctx: *mut c_void) -> c_int {
    if CORE.get().is_some() {
        return 4;
    }
    let Ok(cfg) = serde_json::from_str::<Value>(&cstr(config_json)) else { return 1 };
    let s = |k: &str, d: &str| cfg.get(k).and_then(Value::as_str).unwrap_or(d).to_string();
    let Some(api_id) = option_env!("GM_API_ID").and_then(|v| v.parse().ok()) else { return 2 };
    let config = Config {
        data_dir: PathBuf::from(s("data_dir", "")),
        api_id,
        api_hash: option_env!("GM_API_HASH").unwrap_or("").to_string(),
        client: ClientInfo {
            device_model: s("device_model", "iOS"),
            system_version: s("system_version", "iOS"),
            app_version: s("app_version", env!("CARGO_PKG_VERSION")),
            lang_code: s("lang", "vi"),
        },
    };
    if config.data_dir.as_os_str().is_empty() {
        return 1;
    }
    let rt = RT.get_or_init(|| {
        // Một luồng làm việc là đủ (A4 một nhân); DNS chạy ở luồng blocking riêng
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .thread_name("gm-core")
            .enable_all()
            .build()
            .expect("tokio runtime")
    });
    let cb = Cb { f: on_event, ctx: ctx as usize };
    let emit: gm_core::Emit = Arc::new(move |v| cb.send(&v));
    let _guard = rt.enter();
    match Core::start(config, emit) {
        Ok(core) => {
            let _ = CORE.set(core);
            0
        }
        Err(_) => 3,
    }
}

/// Gọi một lệnh: `{"m": "<nhóm.lệnh>", "a": {…}}`. Kết quả (một lần, trên luồng của lõi):
/// `{"ok": <giá trị>}` hoặc `{"err": {"code", "msg", …}}`.
#[unsafe(no_mangle)]
pub extern "C" fn gm_call(request_json: *const c_char, on_result: Callback, ctx: *mut c_void) {
    let cb = Cb { f: on_result, ctx: ctx as usize };
    let req = cstr(request_json);
    let (Some(rt), Some(core)) = (RT.get(), CORE.get()) else {
        cb.send(&json!({"err": CoreError::new("NOT_STARTED", "Lõi chưa mở.").to_json()}));
        return;
    };
    let core = Arc::clone(core);
    rt.spawn(async move {
        let v: Value = serde_json::from_str(&req).unwrap_or(Value::Null);
        let method = v.get("m").and_then(Value::as_str).unwrap_or("").to_string();
        let args = v.get("a").cloned().unwrap_or(json!({}));
        let out = match core.call(&method, args).await {
            Ok(r) => json!({"ok": r}),
            Err(e) => json!({"err": e.to_json()}),
        };
        cb.send(&out);
    });
}

// ───── Sticker động (TGS): vẽ đồng bộ từng khung, gọi từ luồng nào cũng được (hoạt hình đã đọc thì bất biến) ─────

/// Mở tệp TGS / Lottie → con trỏ hoạt hình (NULL nếu không đọc được). Đóng bằng `gm_lottie_close`.
#[unsafe(no_mangle)]
pub extern "C" fn gm_lottie_open(path: *const c_char) -> *mut c_void {
    match std::fs::read(cstr(path)).ok().and_then(|d| gm_lottie::Animation::parse(&d).ok()) {
        Some(a) => Box::into_raw(Box::new(a)) as *mut c_void,
        None => std::ptr::null_mut(),
    }
}

/// Thông tin: số khung / giây, số khung, kích thước gốc. Trả 0 nếu được.
#[unsafe(no_mangle)]
pub extern "C" fn gm_lottie_info(anim: *const c_void, fps: *mut f64, frames: *mut c_int, w: *mut c_int, h: *mut c_int) -> c_int {
    let Some(a) = (unsafe { (anim as *const gm_lottie::Animation).as_ref() }) else { return 1 };
    let (aw, ah) = a.size();
    unsafe {
        if !fps.is_null() {
            *fps = a.frame_rate() as f64;
        }
        if !frames.is_null() {
            *frames = a.frames() as c_int;
        }
        if !w.is_null() {
            *w = aw as c_int;
        }
        if !h.is_null() {
            *h = ah as c_int;
        }
    }
    0
}

/// Vẽ khung `frame` (0 … số khung − 1) vào `buf` RGBA đã nhân alpha, `width × height × 4` byte (hàng liền nhau). Trả 0 nếu được.
#[unsafe(no_mangle)]
pub extern "C" fn gm_lottie_render(anim: *const c_void, frame: c_int, buf: *mut u8, width: c_int, height: c_int) -> c_int {
    let Some(a) = (unsafe { (anim as *const gm_lottie::Animation).as_ref() }) else { return 1 };
    if buf.is_null() || width <= 0 || height <= 0 || width > 2048 || height > 2048 {
        return 2;
    }
    let len = width as usize * height as usize * 4;
    let slice = unsafe { std::slice::from_raw_parts_mut(buf, len) };
    if a.render(frame.max(0) as f32, slice, width as u32, height as u32) { 0 } else { 3 }
}

#[unsafe(no_mangle)]
pub extern "C" fn gm_lottie_close(anim: *mut c_void) {
    if !anim.is_null() {
        drop(unsafe { Box::from_raw(anim as *mut gm_lottie::Animation) });
    }
}

