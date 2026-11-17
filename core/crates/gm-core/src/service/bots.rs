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

/// Nút dưới tin: mảng hàng, mỗi nút `{t, k, …}` — k: `url` (+u), `web` (+u: mini app), `cb` (+d: dữ liệu hex), `copy` (+c),
/// `user` (+id: khoá peer), `other` (chưa làm được: trò chơi, thanh toán, chọn chat inline…).
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
                            // Mini app: app xin link có dữ liệu đăng nhập (`bots.webview`) rồi mở bằng Safari
                            enums::InlineButtonType::WebView(u) => {
                                v["k"] = json!("web");
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
/// `phone` / `geo` (gửi số / vị trí), `web` (+u: mini app), `other`; `persistent`: bot muốn bàn phím luôn hiện (thay bàn phím
/// máy khi không gõ); bot gỡ bàn phím → `{hide: true}`.
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
                                let (kind, url) = match b.r#type {
                                    enums::ButtonType::Default => ("text", None),
                                    enums::ButtonType::RequestPhone => ("phone", None),
                                    enums::ButtonType::RequestGeoLocation => ("geo", None),
                                    enums::ButtonType::SimpleWebView(w) => ("web", Some(w.url)),
                                    _ => ("other", None),
                                };
                                let mut v = json!({"t": b.text, "k": kind});
                                if let Some(u) = url {
                                    v["u"] = json!(u);
                                }
                                v
                            })
                            .collect(),
                    )
                })
                .collect();
            json!({"rows": rows, "single": k.single_use, "persistent": k.persistent, "placeholder": k.placeholder})
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
    /// Mô tả («Bot này làm được gì?») + lệnh + nút «Menu» cạnh ô nhập của một bot. `menu`: `{k: "commands"}` (danh sách lệnh)
    /// | `{k: "web", t: chữ trên nút, u: link mini app}` | null (bot không có lệnh, không đặt nút).
    pub(super) async fn bot_info(&self, pr: PeerRef) -> Result<Value, CoreError> {
        let enums::users::UserFull::Full(f) = self.client.invoke(&functions::users::GetFullUser { id: pr.into() }).await?;
        let enums::UserFull::Full(u) = f.full_user;
        let Some(info) = u.bot_info else { return Ok(json!({})) };
        let mut cmds = Vec::new();
        commands_json(&info, &mut cmds);
        let enums::BotInfo::Info(x) = &info;
        let menu = match &x.menu_button {
            Some(enums::BotMenuButton::Button(b)) if !b.url.is_empty() => json!({"k": "web", "t": b.text, "u": b.url}),
            _ if !cmds.is_empty() => json!({"k": "commands"}),
            _ => Value::Null,
        };
        Ok(json!({"description": x.description, "commands": cmds, "menu": menu}))
    }

    /// `bots.webview` {peer, url, bot?, menu?, simple?}: link mở mini app của bot (nút «Menu», nút dưới tin, phím mini app trên
    /// bàn phím bot) — Telegram gắn thêm dữ liệu đăng nhập (`#tgWebAppData=…`, có ký của Telegram) để trang biết ai đang mở →
    /// `{url}`. `bot`: bot gửi tin có nút (trong nhóm); mặc định = `peer` (chat riêng với bot). Chỉ nhận link http(s).
    pub(super) async fn bot_webview(&self, a: &Value) -> Res {
        let pr = self.peer_ref(a).await?;
        let bot = if a.get("bot").and_then(Value::as_str).is_some() { self.peer_ref_of(a, "bot").await? } else { pr };
        let url = arg_str(a, "url")?;
        if !(url.starts_with("https://") || url.starts_with("http://")) {
            return Err(CoreError::new("BAD_ARGS", "link mini app không phải http(s)"));
        }
        // Phím mini app trên bàn phím của bot → requestSimpleWebView; nút «Menu» / nút dưới tin → requestWebView
        let res = if a.get("simple").and_then(Value::as_bool).unwrap_or(false) {
            self.client
                .invoke(&functions::messages::RequestSimpleWebView {
                    from_switch_webview: false,
                    from_side_menu: false,
                    compact: false,
                    fullscreen: false,
                    bot: bot.into(),
                    url: Some(url.to_string()),
                    start_param: None,
                    theme_params: None,
                    platform: "ios".into(),
                })
                .await?
        } else {
            self.client
                .invoke(&functions::messages::RequestWebView {
                    from_bot_menu: a.get("menu").and_then(Value::as_bool).unwrap_or(false),
                    silent: false,
                    compact: false,
                    fullscreen: false,
                    peer: pr.into(),
                    bot: bot.into(),
                    url: Some(url.to_string()),
                    start_param: None,
                    theme_params: None,
                    platform: "ios".into(),
                    reply_to: None,
                    send_as: None,
                })
                .await?
        };
        let enums::WebViewResult::Url(r) = res;
        if !(r.url.starts_with("https://") || r.url.starts_with("http://")) {
            return Err(CoreError::new("BAD_REPLY", "link mini app lạ"));
        }
        Ok(json!({"url": r.url}))
    }

    /// `bots.keyboard` {peer, before, out}: bàn phím bot còn hiệu lực nằm ở tin cũ hơn trang app đã tải (bot hay gửi bàn phím
    /// một lần rồi gửi rất nhiều tin báo không kèm bàn phím — bàn phím vẫn còn). Dò lùi từ tin `before` tối đa 400 tin → `{id,
    /// keyboard}` | null (bot đã gỡ, bàn phím dùng một lần mà mình đã nhắn sau đó, hoặc không thấy). `out`: trang đã tải có tin
    /// của mình.
    pub(super) async fn bot_keyboard(&self, a: &Value) -> Res {
        let pr = self.peer_ref(a).await?;
        let before = a.get("before").and_then(Value::as_i64).unwrap_or(0) as i32;
        let mut saw_out = a.get("out").and_then(Value::as_bool).unwrap_or(false);
        let mut it = self.client.iter_messages(pr).limit(400);
        if before > 0 {
            it = it.offset_id(before);
        }
        while let Some(m) = it.next().await? {
            if m.outgoing() {
                saw_out = true;
                continue;
            }
            let k = reply_keyboard(&m);
            if k.is_null() {
                continue;
            }
            if k["hide"] == json!(true) || (k["single"] == json!(true) && saw_out) {
                return Ok(Value::Null);
            }
            return Ok(json!({"id": m.id(), "keyboard": k}));
        }
        Ok(Value::Null)
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
