//! Vị trí: tin vị trí / địa điểm / vị trí trực tiếp, ảnh bản đồ, tra địa chỉ (Nominatim — chỉ khi người dùng chạm), gửi vị trí.
//!
//! Ảnh bản đồ do Telegram vẽ (`upload.getWebFile` + `inputWebFileGeoPointLocation`, gửi tới DC web `config.webfile_dc_id`) như
//! app chính thức: máy chủ bản đồ bên thứ ba không thấy IP / chỗ đang xem (trước 1.4.3: ô OpenStreetMap tải thẳng). MapKit của
//! iOS 5 / 6 không còn máy chủ ô. Telegram giới hạn tốc độ: dồn hơn ~2 ảnh một lúc thì các ảnh sau chờ 15–30 giây → không ghép
//! ô; app xin một ảnh vừa khung mỗi lần dừng tay, tối đa 2 ảnh cùng lúc (hàng chờ riêng, không chen với tải media).

use std::path::Path;
use std::sync::atomic::{AtomicI32, Ordering};

use super::*;
use grammers_client::tl::{enums, functions, types};

/// DC phục vụ `upload.getWebFile` (`config.webfile_dc_id`) — hỏi `help.getConfig` một lần.
static WEBFILE_DC: AtomicI32 = AtomicI32::new(0);
/// Mỗi lần `upload.getWebFile` lấy tối đa 512 KB (bội của 4 KB, 1 MB chia hết).
const WEBFILE_CHUNK: i32 = 512 * 1024;
/// Ảnh bản đồ lớn nhất nhận về (1024 × 1024 × 3 nén PNG / JPEG còn xa mới tới).
const MAX_MAP_BYTES: usize = 4 << 20;
/// Mức phóng Telegram nhận (`inputWebFileGeoPointLocation`: 13–20).
const TG_ZOOM: std::ops::RangeInclusive<i64> = 13..=20;
/// Ảnh bản đồ tải cùng lúc (Telegram trả nhanh ~2 ảnh, dồn thêm thì chờ lâu).
static MAP_SLOTS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(2);
/// Số thứ tự tệp tạm (hai lượt tải cùng một ảnh không ghi chung một tệp).
static TMP_SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Ảnh đã đệm (`<gốc>.png` hoặc `<gốc>.jpg` — đuôi theo loại Telegram trả).
fn cached_map(core: &Core, base: &Path) -> Option<PathBuf> {
    ["png", "jpg"].iter().map(|e| base.with_extension(e)).find(|p| core.cache.hit(p))
}

/// Vị trí trong tin: `{lat, lng, hash, title?, address?, live?}` (không phải → null; `hash` = access_hash của điểm, cho `map.static`).
pub(super) fn msg_geo(m: &Message) -> Value {
    let point = |g: &grammers_client::media::Geo| (g.raw.lat, g.raw.long);
    match m.media() {
        Some(Media::Geo(g)) => {
            let (lat, lng) = point(&g);
            json!({"lat": lat, "lng": lng, "hash": g.raw.access_hash.to_string()})
        }
        Some(Media::Venue(v)) => match v.geo.as_ref() {
            Some(g) => {
                let (lat, lng) = point(g);
                json!({"lat": lat, "lng": lng, "hash": g.raw.access_hash.to_string(), "title": v.raw_venue.title,
                       "address": v.raw_venue.address})
            }
            None => Value::Null,
        },
        Some(Media::GeoLive(l)) => match l.geo.as_ref() {
            Some(g) => {
                let (lat, lng) = point(g);
                json!({"lat": lat, "lng": lng, "hash": g.raw.access_hash.to_string(), "live": true})
            }
            None => Value::Null,
        },
        _ => Value::Null,
    }
}

/// HTTP cho Nominatim (tra địa chỉ khi người dùng chạm): User-Agent nêu tên app theo quy định của OSM.
fn osm_client() -> &'static reqwest::Client {
    static CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .user_agent(concat!("GramMini/", env!("CARGO_PKG_VERSION"), " (Telegram client for iOS 5/6; +https://github.com/itovn/GramMini)"))
            .connect_timeout(Duration::from_secs(15))
            .timeout(Duration::from_secs(30))
            .build()
            .unwrap_or_default()
    })
}

impl Core {
    /// DC web của Telegram (`config.webfile_dc_id`).
    async fn webfile_dc(&self) -> Result<i32, CoreError> {
        let dc = WEBFILE_DC.load(Ordering::Relaxed);
        if dc > 0 {
            return Ok(dc);
        }
        let enums::Config::Config(c) = self.client.invoke(&functions::help::GetConfig {}).await?;
        WEBFILE_DC.store(c.webfile_dc_id, Ordering::Relaxed);
        Ok(c.webfile_dc_id)
    }

    /// Ảnh bản đồ do Telegram vẽ, tâm (lat, lng), `w` × `h` điểm (× `scale`), mức phóng `zoom` → ghi `<base>.png|jpg`.
    /// `hash` = access_hash của điểm trong tin (0 cho điểm tự chọn).
    #[allow(clippy::too_many_arguments)]
    async fn tg_map(&self, lat: f64, lng: f64, hash: i64, w: i32, h: i32, zoom: i32, scale: i32, base: &Path) -> Res {
        if let Some(p) = cached_map(self, base) {
            return Ok(json!({"path": p}));
        }
        let _permit = MAP_SLOTS.acquire().await.map_err(|_| CoreError::new("BUSY", "hàng tải đã đóng"))?;
        if let Some(p) = cached_map(self, base) {
            return Ok(json!({"path": p})); // lượt khác vừa tải xong
        }
        let dc = self.webfile_dc().await?;
        let mut req = functions::upload::GetWebFile {
            location: enums::InputWebFileLocation::InputWebFileGeoPointLocation(types::InputWebFileGeoPointLocation {
                geo_point: enums::InputGeoPoint::Point(types::InputGeoPoint { lat, long: lng, accuracy_radius: None }),
                access_hash: hash,
                w,
                h,
                zoom,
                scale,
            }),
            offset: 0,
            limit: WEBFILE_CHUNK,
        };
        let mut data = Vec::new();
        let mut mime;
        let mut copied = false;
        loop {
            // Telegram bị dồn yêu cầu có thể trả sau 15–30 giây
            let r = tokio::time::timeout(Duration::from_secs(30), self.client.invoke_in_dc(dc, &req))
                .await
                .map_err(|_| CoreError::new("TIMEOUT", "Tải bản đồ quá lâu."))?;
            let f = match r {
                Ok(enums::upload::WebFile::File(f)) => f,
                // DC web khác DC nhà: chép quyền đăng nhập sang (một lần) rồi hỏi lại
                Err(InvocationError::Rpc(e)) if e.name == "AUTH_KEY_UNREGISTERED" && !copied => {
                    copied = true;
                    self.client.copy_auth_to_dc(dc).await?;
                    continue;
                }
                Err(e) => return Err(e.into()),
            };
            mime = f.mime_type;
            let got = f.bytes.len();
            data.extend_from_slice(&f.bytes);
            if data.len() > MAX_MAP_BYTES {
                return Err(CoreError::new("NETWORK", "Ảnh bản đồ quá lớn"));
            }
            if got < WEBFILE_CHUNK as usize || (f.size > 0 && data.len() >= f.size as usize) {
                break;
            }
            req.offset += WEBFILE_CHUNK;
        }
        if data.is_empty() {
            return Err(CoreError::new("NETWORK", "Bản đồ trống"));
        }
        let path = base.with_extension(if mime.contains("jpeg") || mime.contains("jpg") { "jpg" } else { "png" });
        let io = |e: std::io::Error| CoreError::new("IO", e.to_string());
        if let Some(d) = path.parent() {
            std::fs::create_dir_all(d).map_err(io)?;
        }
        let tmp = path.with_extension(format!("{}.tmp", TMP_SEQ.fetch_add(1, Ordering::Relaxed)));
        std::fs::write(&tmp, &data).and_then(|_| std::fs::rename(&tmp, &path)).map_err(io)?;
        Ok(json!({"path": path}))
    }

    /// `map.static` {lat, lng, hash?, w, h, zoom?, scale?}: ảnh bản đồ tâm (lat, lng) — bong bóng tin vị trí (kèm `hash` của
    /// điểm) và màn bản đồ (một ảnh vừa khung, `hash` 0) (w, h 16–1024 điểm, zoom 13–20, mặc định 15; scale 1–3) → `{path}`
    /// (đệm ở `maps/`, dọn như bộ đệm khác).
    pub(super) async fn map_static(&self, a: &Value) -> Res {
        let lat = a.get("lat").and_then(Value::as_f64).unwrap_or(999.0);
        let lng = a.get("lng").and_then(Value::as_f64).unwrap_or(999.0);
        if !(-90.0..=90.0).contains(&lat) || !(-180.0..=180.0).contains(&lng) {
            return Err(CoreError::new("BAD_ARGS", "Toạ độ không hợp lệ"));
        }
        let hash = a.get("hash").and_then(Value::as_str).and_then(|h| h.parse::<i64>().ok()).unwrap_or(0);
        let int = |k: &str, d: i64, lo: i64, hi: i64| a.get(k).and_then(Value::as_i64).unwrap_or(d).clamp(lo, hi) as i32;
        let (w, h) = (int("w", 200, 16, 1024), int("h", 150, 16, 1024));
        let zoom = int("zoom", 15, *TG_ZOOM.start(), *TG_ZOOM.end());
        let scale = int("scale", 1, 1, 3);
        // toạ độ theo phần triệu độ (số nguyên): tên tệp không có dấu chấm — `with_extension` cắt sau dấu chấm cuối
        let (ulat, ulng) = ((lat * 1e6).round() as i64, (lng * 1e6).round() as i64);
        let base = self.cfg.data_dir.join("maps").join(format!("s{scale}_{zoom}_{w}x{h}_{ulat}_{ulng}"));
        self.tg_map(lat, lng, hash, w, h, zoom, scale, &base).await
    }

    /// `map.address` {lat, lng}: địa chỉ (Nominatim của OSM, tiếng Việt, 4 phần đầu) → `{address}` (rỗng nếu không có). App chỉ
    /// gọi khi người dùng chạm «Tra địa chỉ» (gửi toạ độ cho OSM — Telegram không có dịch vụ tra địa chỉ).
    pub(super) async fn map_address(&self, a: &Value) -> Res {
        let lat = a.get("lat").and_then(Value::as_f64).unwrap_or(999.0);
        let lng = a.get("lng").and_then(Value::as_f64).unwrap_or(999.0);
        if !(-90.0..=90.0).contains(&lat) || !(-180.0..=180.0).contains(&lng) {
            return Err(CoreError::new("BAD_ARGS", "Toạ độ không hợp lệ"));
        }
        let url = format!("https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat={lat:.6}&lon={lng:.6}&zoom=18&accept-language=vi");
        let v: Value = osm_client()
            .get(url)
            .send()
            .await
            .map_err(|e| CoreError::new("NETWORK", format!("Không tra được địa chỉ: {e}")))?
            .text()
            .await
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .ok_or_else(|| CoreError::new("NETWORK", "Địa chỉ: dữ liệu lạ"))?;
        let full = v.get("display_name").and_then(Value::as_str).unwrap_or("");
        let short: Vec<&str> = full.split(", ").filter(|p| *p != "Việt Nam").take(4).collect();
        Ok(json!({"address": short.join(", ")}))
    }

    /// `messages.sendGeo` {peer, lat, lng, reply_to?, topic?}: gửi vị trí (tin vị trí thật của Telegram — mọi app mở được bản đồ).
    pub(super) async fn send_geo(&self, a: &Value) -> Res {
        let pr = self.peer_ref(a).await?;
        let lat = a.get("lat").and_then(Value::as_f64).ok_or_else(|| CoreError::new("BAD_ARGS", "thiếu «lat»"))?;
        let lng = a.get("lng").and_then(Value::as_f64).ok_or_else(|| CoreError::new("BAD_ARGS", "thiếu «lng»"))?;
        let media = enums::InputMedia::GeoPoint(types::InputMediaGeoPoint {
            geo_point: enums::InputGeoPoint::Point(types::InputGeoPoint { lat, long: lng, accuracy_radius: None }),
        });
        let msg = grammers_client::message::InputMessage::new().text("").media(media).reply_to(reply_arg(a));
        let m = self.client.send_message(pr, msg).await?;
        Ok(msg_json(&m))
    }
}

