//! Link Telegram mở ngay trong app (t.me/…, tg://…, @tên) và tham gia nhóm / kênh — máy iOS 5 / 6 không có app Telegram, mở
//! bằng Safari là ngõ cụt.

use super::*;

/// Link Telegram đọc được.
#[derive(Debug, PartialEq)]
pub(crate) enum TgLink {
    /// t.me/<tên>[/<chủ đề>]/<tin>, t.me/s/<tên>, tg://resolve?domain=…&post=…, @tên
    Username { name: String, msg: Option<i32> },
    /// t.me/+<mã>, t.me/joinchat/<mã>, tg://join?invite=<mã> (mã phân biệt hoa / thường)
    Invite(String),
    /// t.me/c/<id kênh>/<tin>, tg://privatepost?channel=…&post=… — nhóm / kênh riêng, chỉ mở được khi đã ở trong
    Private { channel: i64, msg: Option<i32> },
    /// tg://user?id=…
    User(i64),
}

/// @tên hợp lệ: 3–32 ký tự chữ / số / gạch dưới, bắt đầu bằng chữ.
fn valid_username(s: &str) -> bool {
    (3..=32).contains(&s.len())
        && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        && s.chars().next().is_some_and(|c| c.is_ascii_alphabetic())
}

fn query<'a>(q: &'a str, key: &str) -> Option<&'a str> {
    q.split('&').find_map(|kv| {
        let (k, v) = kv.split_once('=')?;
        k.eq_ignore_ascii_case(key).then_some(v)
    })
}

fn strip_prefix_ci<'a>(s: &'a str, p: &str) -> Option<&'a str> {
    (s.len() >= p.len() && s.is_char_boundary(p.len()) && s[..p.len()].eq_ignore_ascii_case(p)).then(|| &s[p.len()..])
}

/// Đọc link Telegram; link khác (web thường, t.me/proxy, t.me/addstickers… — app tự lo) → None.
pub(crate) fn parse(url: &str) -> Option<TgLink> {
    let u = url.trim();
    if let Some(name) = u.strip_prefix('@') {
        return valid_username(name).then(|| TgLink::Username { name: name.into(), msg: None });
    }
    if let Some(rest) = strip_prefix_ci(u, "tg://") {
        let (action, q) = rest.split_once('?').unwrap_or((rest, ""));
        let num = |k: &str| query(q, k).and_then(|v| v.parse::<i64>().ok());
        return match action.trim_end_matches('/').to_ascii_lowercase().as_str() {
            "resolve" => {
                let name = query(q, "domain")?;
                valid_username(name).then(|| TgLink::Username { name: name.into(), msg: num("post").map(|x| x as i32) })
            }
            "join" => query(q, "invite").filter(|h| !h.is_empty()).map(|h| TgLink::Invite(h.into())),
            "privatepost" => Some(TgLink::Private { channel: num("channel")?, msg: num("post").map(|x| x as i32) }),
            "user" => num("id").map(TgLink::User),
            _ => None,
        };
    }
    let mut s = u;
    for p in ["https://", "http://"] {
        if let Some(r) = strip_prefix_ci(s, p) {
            s = r;
            break;
        }
    }
    if let Some(r) = strip_prefix_ci(s, "www.") {
        s = r;
    }
    let (host, path) = s.split_once('/')?;
    if !["t.me", "telegram.me", "telegram.dog"].iter().any(|h| host.eq_ignore_ascii_case(h)) {
        return None;
    }
    let path = path.split(['?', '#']).next().unwrap_or("");
    let seg: Vec<&str> = path.split('/').filter(|x| !x.is_empty()).collect();
    let first = *seg.first()?;
    if let Some(h) = first.strip_prefix('+') {
        // t.me/+84… là số điện thoại, không phải link mời
        return (!h.is_empty() && !h.chars().all(|c| c.is_ascii_digit())).then(|| TgLink::Invite(h.into()));
    }
    let last_num = |from: usize| seg.get(from..).unwrap_or(&[]).iter().rev().find_map(|x| x.parse::<i32>().ok());
    match first.to_ascii_lowercase().as_str() {
        "joinchat" => seg.get(1).map(|h| TgLink::Invite((*h).into())),
        "c" => Some(TgLink::Private { channel: seg.get(1)?.parse().ok()?, msg: last_num(2) }),
        "s" => {
            let name = *seg.get(1)?;
            valid_username(name).then(|| TgLink::Username { name: name.into(), msg: last_num(2) })
        }
        // Do app lo (proxy, bộ sticker) hoặc chưa hỗ trợ
        "addstickers" | "addemoji" | "proxy" | "socks" | "share" | "setlanguage" | "login" | "invoice" | "addtheme" | "bg"
        | "boost" | "m" | "addlist" | "contact" | "iv" | "giftcode" | "nft" => None,
        _ => valid_username(first).then(|| TgLink::Username { name: first.into(), msg: last_num(1) }),
    }
}

/// Đã rời / chưa vào nhóm, kênh (người: luôn false).
pub(super) fn is_left(p: &Peer) -> bool {
    use grammers_client::tl::enums::Chat;
    let raw = match p {
        Peer::Group(g) => &g.raw,
        Peer::Channel(c) => return c.raw.left,
        _ => return false,
    };
    match raw {
        Chat::Chat(c) => c.left || c.deactivated,
        Chat::Channel(c) => c.left,
        Chat::Forbidden(_) | Chat::ChannelForbidden(_) => true,
        _ => false,
    }
}

impl Core {
    /// Peer từ một chat thô trong phản hồi (lưu luôn vào phiên để mở được).
    async fn chat_peer(&self, chats: Vec<grammers_client::tl::enums::Chat>, want: Option<PeerId>) -> Option<Peer> {
        let peers = self.client.build_peer_map(Vec::new(), chats).await;
        let p = match want {
            Some(id) => peers.get(id).cloned(),
            None => peers.iter_peers().next().cloned(),
        };
        if let Some(p) = &p {
            remember(p);
        }
        self.save_session();
        p
    }

    async fn known_peer(&self, id: Option<PeerId>, msg: &str) -> Result<Peer, CoreError> {
        let id = id.ok_or_else(|| CoreError::new("BAD_ARGS", "link sai"))?;
        let pr = self.session.peer_ref(id).await.ok().flatten().ok_or_else(|| CoreError::new("PEER_UNKNOWN", msg))?;
        let p = self.client.resolve_peer(pr).await?;
        remember(&p);
        Ok(p)
    }

    /// `link.resolve` {url}: link Telegram → chat để mở (`type: "peer"`, `peer` như peer_json + `left`, `msg` để nhảy tới,
    /// `hash` khi xem trước nhóm riêng qua link mời) hoặc lời mời chưa vào (`type: "invite"`); link khác → `type: "web"`.
    pub(super) async fn link_resolve(&self, a: &Value) -> Res {
        use grammers_client::tl::{enums, functions};
        let url = arg_str(a, "url")?;
        let Some(link) = parse(url) else { return Ok(json!({"type": "web"})) };
        match link {
            TgLink::Username { name, msg } => match self.client.resolve_username(&name).await {
                Ok(Some(p)) => {
                    remember(&p);
                    self.save_session();
                    Ok(json!({"type": "peer", "peer": peer_json(&p), "msg": msg}))
                }
                Ok(None) => Err(CoreError::new("USERNAME_NOT_OCCUPIED", format!("Không có ai dùng tên @{name}."))),
                Err(InvocationError::Rpc(r)) if r.name == "USERNAME_NOT_OCCUPIED" || r.name == "USERNAME_INVALID" => {
                    Err(CoreError::new("USERNAME_NOT_OCCUPIED", format!("Không có ai dùng tên @{name}.")))
                }
                Err(e) => Err(e.into()),
            },
            TgLink::Private { channel, msg } => {
                let p = self.known_peer(PeerId::channel(channel), "Bạn chưa ở trong nhóm / kênh này — cần link mời.").await?;
                Ok(json!({"type": "peer", "peer": peer_json(&p), "msg": msg}))
            }
            TgLink::User(id) => {
                let p = self.known_peer(PeerId::user(id), "Chưa biết người này — tìm theo tên hoặc @tên.").await?;
                Ok(json!({"type": "peer", "peer": peer_json(&p)}))
            }
            TgLink::Invite(hash) => match self.client.invoke(&functions::messages::CheckChatInvite { hash: hash.clone() }).await? {
                enums::ChatInvite::Already(x) => {
                    let p = self.chat_peer(vec![x.chat], None).await.ok_or_else(|| CoreError::new("NO_CHAT", "Không đọc được nhóm."))?;
                    Ok(json!({"type": "peer", "peer": peer_json(&p)}))
                }
                // Xem trước (nhóm riêng cho xem trước khi vào): mở như chat chưa vào, tham gia bằng mã mời
                enums::ChatInvite::Peek(x) => {
                    let p = self.chat_peer(vec![x.chat], None).await.ok_or_else(|| CoreError::new("NO_CHAT", "Không đọc được nhóm."))?;
                    let mut v = peer_json(&p);
                    v["left"] = json!(true);
                    v["hash"] = json!(hash);
                    Ok(json!({"type": "peer", "peer": v}))
                }
                enums::ChatInvite::Invite(x) => Ok(json!({
                    "type": "invite",
                    "hash": hash,
                    "title": x.title,
                    "about": x.about,
                    "members": x.participants_count,
                    "channel": x.broadcast,
                    "request": x.request_needed,
                })),
            },
        }
    }

    /// `chats.join` {peer} (nhóm / kênh công khai) hoặc {hash} (link mời) → chat vừa vào (peer_json). Nhóm cần duyệt → lỗi
    /// INVITE_REQUEST_SENT (đã gửi yêu cầu).
    pub(super) async fn chat_join(&self, a: &Value) -> Res {
        use grammers_client::tl::{enums, functions};
        let (r, want) = if let Some(hash) = a.get("hash").and_then(Value::as_str) {
            match self.client.invoke(&functions::messages::ImportChatInvite { hash: hash.into() }).await {
                // Đã ở trong rồi: trả chat như link.resolve
                Err(InvocationError::Rpc(e)) if e.name == "USER_ALREADY_PARTICIPANT" => {
                    let v = Box::pin(self.link_resolve(&json!({"url": format!("tg://join?invite={hash}")}))).await?;
                    return Ok(v["peer"].clone());
                }
                r => (r?, None),
            }
        } else {
            let pr = self.peer_ref(a).await?;
            match self.client.invoke(&functions::channels::JoinChannel { channel: pr.into() }).await {
                Err(InvocationError::Rpc(e)) if e.name == "USER_ALREADY_PARTICIPANT" => {
                    let p = self.client.resolve_peer(pr).await?;
                    return Ok(peer_json(&p));
                }
                r => (r?, Some(pr.id)),
            }
        };
        let updates = match r {
            enums::messages::ChatInviteJoinResult::Ok(x) => x.updates,
            _ => return Err(CoreError::new("WEBVIEW", "Nhóm này cần xác nhận qua bot — chưa làm được trong GramMini.")),
        };
        let chats = match updates {
            enums::Updates::Updates(u) => u.chats,
            enums::Updates::Combined(u) => u.chats,
            _ => Vec::new(),
        };
        let p = self.chat_peer(chats, want).await;
        let p = match (p, want) {
            (Some(p), _) => p,
            (None, Some(id)) => self.known_peer(Some(id), "Đã vào nhưng chưa đọc được chat — tải lại danh sách chat.").await?,
            (None, None) => return Err(CoreError::new("NO_CHAT", "Đã vào nhóm — tải lại danh sách chat.")),
        };
        self.log(&format!("đã tham gia {}", peer_kind(&p)));
        Ok(peer_json(&p))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn user(n: &str, m: Option<i32>) -> Option<TgLink> {
        Some(TgLink::Username { name: n.into(), msg: m })
    }

    #[test]
    fn parses_links() {
        assert_eq!(parse("https://t.me/tivikit"), user("tivikit", None));
        assert_eq!(parse("t.me/tivikit/123"), user("tivikit", Some(123)));
        assert_eq!(parse("http://www.telegram.me/s/durov/45?single"), user("durov", Some(45)));
        assert_eq!(parse("https://t.me/somegroup/7/890"), user("somegroup", Some(890)));
        assert_eq!(parse("@gramtest_bot"), user("gramtest_bot", None));
        assert_eq!(parse("tg://resolve?domain=tivikit&post=9"), user("tivikit", Some(9)));
        assert_eq!(parse("https://t.me/+AbCdEf_12"), Some(TgLink::Invite("AbCdEf_12".into())));
        assert_eq!(parse("t.me/joinchat/XyZ"), Some(TgLink::Invite("XyZ".into())));
        assert_eq!(parse("tg://join?invite=QwE"), Some(TgLink::Invite("QwE".into())));
        assert_eq!(parse("https://t.me/c/1234567/89"), Some(TgLink::Private { channel: 1234567, msg: Some(89) }));
        assert_eq!(parse("tg://user?id=42"), Some(TgLink::User(42)));
        // Không phải link mở chat
        assert_eq!(parse("https://t.me/+84901234567"), None);
        assert_eq!(parse("https://t.me/addstickers/Abc"), None);
        assert_eq!(parse("https://t.me/proxy?server=a&port=1&secret=dd"), None);
        assert_eq!(parse("tg://proxy?server=a"), None);
        assert_eq!(parse("https://example.com/t.me/x"), None);
        assert_eq!(parse("https://vnexpress.net"), None);
        assert_eq!(parse("@a"), None);
    }
}
