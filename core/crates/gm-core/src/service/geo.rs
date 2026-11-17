//! Vị trí: tin vị trí / địa điểm / vị trí trực tiếp, ô bản đồ OpenStreetMap (MapKit của iOS 5 / 6 không còn máy chủ ô; TLS của
//! iOS 6 không vào được tile.openstreetmap.org → tải qua lõi), tra địa chỉ (Nominatim), gửi vị trí.

use super::*;
use grammers_client::tl::{enums, types};

/// Vị trí trong tin: `{lat, lng, title?, address?, live?}` (không phải → null).
pub(super) fn msg_geo(m: &Message) -> Value {
    let point = |g: &grammers_client::media::Geo| (g.raw.lat, g.raw.long);
    match m.media() {
        Some(Media::Geo(g)) => {
            let (lat, lng) = point(&g);
            json!({"lat": lat, "lng": lng})
        }
        Some(Media::Venue(v)) => match v.geo.as_ref().map(point) {
            Some((lat, lng)) => json!({"lat": lat, "lng": lng, "title": v.raw_venue.title, "address": v.raw_venue.address}),
            None => Value::Null,
        },
        Some(Media::GeoLive(l)) => match l.geo.as_ref().map(point) {
            Some((lat, lng)) => json!({"lat": lat, "lng": lng, "live": true}),
            None => Value::Null,
        },
        _ => Value::Null,
    }
}

/// HTTP cho OpenStreetMap: User-Agent nêu tên app theo quy định của OSM.
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
    /// `map.tile` {z, x, y}: một ô bản đồ OSM (256 × 256, PNG) → `{path}` (đệm ở `maps/`, dọn như bộ đệm khác).
    pub(super) async fn map_tile(&self, a: &Value) -> Res {
        let n = |k: &str| a.get(k).and_then(Value::as_i64).unwrap_or(-1);
        let (z, x, y) = (n("z"), n("x"), n("y"));
        if !(1..=19).contains(&z) || x < 0 || y < 0 || x >= (1i64 << z) || y >= (1i64 << z) {
            return Err(CoreError::new("BAD_ARGS", "Ô bản đồ không hợp lệ"));
        }
        let path = self.cfg.data_dir.join("maps").join(format!("{z}_{x}_{y}.png"));
        if self.cache.hit(&path) {
            return Ok(json!({"path": path}));
        }
        let _permit = self.dl.acquire().await.map_err(|_| CoreError::new("BUSY", "hàng tải đã đóng"))?;
        let net = |e: reqwest::Error| CoreError::new("NETWORK", format!("Không tải được bản đồ: {e}"));
        let r = osm_client().get(format!("https://tile.openstreetmap.org/{z}/{x}/{y}.png")).send().await.map_err(net)?;
        if !r.status().is_success() {
            return Err(CoreError::new("NETWORK", format!("Bản đồ: HTTP {}", r.status().as_u16())));
        }
        let data = r.bytes().await.map_err(net)?;
        let io = |e: std::io::Error| CoreError::new("IO", e.to_string());
        std::fs::create_dir_all(self.cfg.data_dir.join("maps")).map_err(io)?;
        let tmp = path.with_extension("tmp");
        std::fs::write(&tmp, &data).and_then(|_| std::fs::rename(&tmp, &path)).map_err(io)?;
        Ok(json!({"path": path}))
    }

    /// `map.address` {lat, lng}: địa chỉ (Nominatim của OSM, tiếng Việt, 4 phần đầu) → `{address}` (rỗng nếu không có).
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
