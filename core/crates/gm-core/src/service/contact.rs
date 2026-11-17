//! Danh thiếp: tin danh bạ (tên + số điện thoại, người dùng Telegram nếu có), gửi danh thiếp.

use super::*;
use grammers_client::tl::{enums, types};

/// Danh thiếp trong tin: `{phone, first, last, user?}` (user = khoá peer nếu số này có tài khoản Telegram) — không phải → null.
pub(super) fn msg_contact(m: &Message) -> Value {
    match m.media() {
        Some(Media::Contact(c)) => {
            let r = &c.raw;
            let user = if r.user_id != 0 { PeerId::user(r.user_id).map(peer_key) } else { None };
            json!({"phone": r.phone_number, "first": r.first_name, "last": r.last_name, "user": user})
        }
        _ => Value::Null,
    }
}

impl Core {
    /// `messages.sendContact` {peer, phone, first, last?, reply_to?, topic?}: gửi danh thiếp.
    pub(super) async fn send_contact(&self, a: &Value) -> Res {
        let pr = self.peer_ref(a).await?;
        let phone = arg_str(a, "phone")?.trim().to_string();
        if phone.is_empty() {
            return Err(CoreError::new("BAD_ARGS", "Người này không có số điện thoại để gửi danh thiếp."));
        }
        let s = |k: &str| a.get(k).and_then(Value::as_str).unwrap_or("").trim().to_string();
        let media = enums::InputMedia::Contact(types::InputMediaContact {
            phone_number: phone,
            first_name: s("first"),
            last_name: s("last"),
            vcard: String::new(),
        });
        let msg = grammers_client::message::InputMessage::new().text("").media(media).reply_to(reply_arg(a));
        let m = self.client.send_message(pr, msg).await?;
        Ok(msg_json(&m))
    }
}
