//! Truyền âm thanh tgcalls V2 (8.0.0 / 9.0.0): báo hiệu có ack, ICE (bên gọi điều khiển) + máy chủ chuyển tiếp của Telegram,
//! DTLS 1.2 (bên gọi là khách) + SRTP, RTP Opus, bộ đệm chống rung.
//!
//! Phần lớn phỏng theo Ferrogram (github.com/Dasemu/Ferrogram, src/net/calls/, giấy phép MIT — `LICENSE-FERROGRAM`); mỗi tệp
//! ghi nguồn ở đầu. GramMini thêm: kiểu khoá dùng chung với trao khoá của mình (`crate::KeyPair`), âm thanh qua gm-opus (libopus
//! đã dựng cho iOS 5 / 6), đầu vào là danh sách đường kết nối thô (gm-cli / gm-core đổi từ TL).

pub mod audio;
pub mod crypto;
pub mod engine;
pub mod ice;
pub mod io;
pub mod jitter;
pub mod rtp;
pub mod signaling;
pub mod srtp;
pub mod stun;

/// Khoá chung 256 byte của cuộc gọi.
#[derive(Clone)]
pub struct CallKey(pub [u8; 256]);

impl std::fmt::Debug for CallKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("CallKey(..)")
    }
}

/// Một máy chủ chuyển tiếp (`phoneConnection`).
#[derive(Clone, Debug)]
pub struct Reflector {
    pub id: i64,
    pub ip: String,
    pub port: i32,
    pub peer_tag: Vec<u8>,
    pub tcp: bool,
}

/// Cấu hình máy chủ chuyển tiếp cho ICE: đánh số theo vị trí của id trong các id đã sắp xếp (1, 2, …) như app chính thức; bỏ
/// TCP (chưa làm), peer_tag phải 16 byte, chỉ IPv4.
pub fn reflectors(list: &[Reflector]) -> Vec<ice::ReflectorConfig> {
    let mut ids: Vec<i64> = list.iter().map(|r| r.id).collect();
    ids.sort_unstable();
    ids.dedup();
    let mut out = Vec::new();
    for r in list {
        if r.tcp || r.peer_tag.len() != 16 {
            continue;
        }
        let (Ok(port), Ok(ip)) = (u16::try_from(r.port), r.ip.parse::<std::net::Ipv4Addr>()) else { continue };
        let Some(pos) = ids.iter().position(|x| *x == r.id) else { continue };
        let Ok(server) = u8::try_from(pos + 1) else { continue };
        let mut tag = [0u8; 16];
        tag.copy_from_slice(&r.peer_tag);
        out.push(ice::ReflectorConfig { server, addr: std::net::SocketAddr::new(ip.into(), port), peer_tag: tag });
    }
    out
}

/// Cờ bật trong `custom_parameters` (JSON) của phoneCall: `true` hoặc `1`.
pub fn custom_flag(custom: Option<&str>, name: &str) -> bool {
    custom
        .and_then(|s| serde_json::from_str::<serde_json::Value>(s).ok())
        .and_then(|v| v.get(name).cloned())
        .is_some_and(|v| v.as_bool().unwrap_or(false) || v.as_i64() == Some(1))
}
