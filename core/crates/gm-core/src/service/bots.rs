//! Bot: nút dưới tin (inline keyboard), bàn phím trả lời (reply keyboard), bấm nút callback, mô tả + lệnh của bot.

use super::*;
use grammers_client::tl::{enums, functions};

pub(super) fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

pub(super) fn unhex(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(s.get(i..i + 2)?, 16).ok()).collect()
}

/// Nút dưới tin: mảng hàng, mỗi nút `{t, k, …}` — k: `url` (+u), `cb` (+d: dữ liệu hex), `copy` (+c), `user` (+id: khoá peer),
/// `other` (chưa làm được: trò chơi, thanh toán, chọn chat inline…).
pub(super) fn inline_buttons(m: &Message) -> Value {
    let Some(enums::ReplyMarkup::ReplyInlineMarkup(mk)) = m.reply_markup() else { return Value::Null };
    let rows: Vec<Value> = mk
        .rows
        .into_iter()
        .map(|enums::KeyboardInlineButtonRow::Row(row)| {
            Value::Array(
                row.buttons
                    .into_iter()
                    .map(|enums::KeyboardInlineButton::Button(b)| {
                        let mut v = json!({"t": b.text});
                        match b.r#type {
                            enums::InlineButtonType::Url(u) => {
                                v["k"] = json!("url");
                                v["u"] = json!(u.url);
                            }
                            enums::InlineButtonType::UrlAuth(u) => {
                                v["k"] = json!("url");
                                v["u"] = json!(u.url);
                            }
                            // Mini app: mở trang bằng Safari (không có dữ liệu đăng nhập của Telegram — trang có thể không chạy)
                            enums::InlineButtonType::WebView(u) => {
                                v["k"] = json!("url");
                                v["u"] = json!(u.url);
                            }
                            enums::InlineButtonType::Callback(c) if !c.requires_password => {
                                v["k"] = json!("cb");
                                v["d"] = json!(hex(&c.data));
                            }
                            enums::InlineButtonType::Copy(c) => {
                                v["k"] = json!("copy");
                                v["c"] = json!(c.copy_text);
                            }
                            enums::InlineButtonType::UserProfile(u) => {
                                v["k"] = json!("user");
                                v["id"] = json!(PeerId::user(u.user_id).map(peer_key));
                            }
                            _ => v["k"] = json!("other"),
                        }
                        v
                    })
                    .collect(),
            )
        })
        .collect();
    if rows.is_empty() { Value::Null } else { Value::Array(rows) }
}

/// Bàn phím trả lời của bot (thay bàn phím máy): `{rows: [[{t, k}]], single, placeholder}` — k: `text` (chạm = gửi chữ),
/// `phone` / `geo` (gửi số / vị trí — chưa làm), `other`; bot gỡ bàn phím → `{hide: true}`.
pub(super) fn reply_keyboard(m: &Message) -> Value {
    match m.reply_markup() {
        Some(enums::ReplyMarkup::ReplyKeyboardMarkup(k)) => {
            let rows: Vec<Value> = k
                .rows
                .into_iter()
                .map(|enums::KeyboardButtonRow::Row(r)| {
                    Value::Array(
                        r.buttons
                            .into_iter()
                            .map(|enums::KeyboardButton::Button(b)| {
                                let kind = match b.r#type {
                                    enums::ButtonType::Default => "text",
                                    enums::ButtonType::RequestPhone => "phone",
                                    enums::ButtonType::RequestGeoLocation => "geo",
                                    _ => "other",
                                };
                                json!({"t": b.text, "k": kind})
                            })
                            .collect(),
                    )
                })
                .collect();
            json!({"rows": rows, "single": k.single_use, "placeholder": k.placeholder})
        }
        Some(enums::ReplyMarkup::ReplyKeyboardHide(_)) => json!({"hide": true}),
        _ => Value::Null,
    }
}

/// Lệnh của bot: `[{c: "/lệnh", d: mô tả}]`.
fn commands_json(info: &enums::BotInfo, out: &mut Vec<Value>) {
    let enums::BotInfo::Info(x) = info;
    for enums::BotCommand::Command(c) in x.commands.iter().flatten() {
        let cmd = format!("/{}", c.command);
        if !out.iter().any(|v| v["c"] == cmd) {
            out.push(json!({"c": cmd, "d": c.description}));
        }
    }
}

/// Lệnh của các bot trong nhóm (ChatFull.bot_info).
pub(super) fn group_commands(infos: &[enums::BotInfo]) -> Value {
    let mut out = Vec::new();
    for i in infos {
        commands_json(i, &mut out);
    }
    Value::Array(out)
}

impl Core {
    /// Mô tả («Bot này làm được gì?») + lệnh của một bot.
    pub(super) async fn bot_info(&self, pr: PeerRef) -> Result<Value, CoreError> {
        let enums::users::UserFull::Full(f) = self.client.invoke(&functions::users::GetFullUser { id: pr.into() }).await?;
        let enums::UserFull::Full(u) = f.full_user;
        let Some(info) = u.bot_info else { return Ok(json!({})) };
        let mut cmds = Vec::new();
        commands_json(&info, &mut cmds);
        let enums::BotInfo::Info(x) = &info;
        Ok(json!({"description": x.description, "commands": cmds}))
    }

    /// `messages.botCallback` {peer, id, data}: bấm nút callback dưới tin của bot → câu trả lời `{message?, alert, url?}`
    /// (bot không trả lời kịp → `{}` — bot thường vẫn làm, tin sửa / tin mới tự về).
    pub(super) async fn bot_callback(&self, a: &Value) -> Res {
        let pr = self.peer_ref(a).await?;
        let id = a.get("id").and_then(Value::as_i64).ok_or_else(|| CoreError::new("BAD_ARGS", "thiếu «id»"))? as i32;
        let data = unhex(arg_str(a, "data")?).ok_or_else(|| CoreError::new("BAD_ARGS", "«data» sai"))?;
        let req = functions::messages::GetBotCallbackAnswer { game: false, peer: pr.into(), msg_id: id, data: Some(data), password: None };
        match tokio::time::timeout(Duration::from_secs(20), self.client.invoke(&req)).await {
            Err(_) => Ok(json!({})),
            Ok(Ok(enums::messages::BotCallbackAnswer::Answer(x))) => {
                Ok(json!({"message": x.message, "alert": x.alert, "url": x.url}))
            }
            Ok(Err(InvocationError::Rpc(e))) if e.name == "BOT_RESPONSE_TIMEOUT" => Ok(json!({})),
            Ok(Err(e)) => Err(e.into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_roundtrip() {
        let d = vec![0u8, 1, 0xab, 0xff, 0x10];
        assert_eq!(hex(&d), "0001abff10");
        assert_eq!(unhex("0001abff10"), Some(d));
        assert_eq!(unhex("abc"), None);
        assert_eq!(unhex("zz"), None);
    }
}
