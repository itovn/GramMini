//! Lõi GramMini (phần không dính giao diện): phiên đăng nhập lưu ra tệp (`session`), dịch vụ cho app (`service`).

pub mod cache;
pub mod media;
pub mod service;
pub mod session;

pub use service::{Config, Core, CoreError, Emit};
pub use session::FileSession;
