//! Cảm xúc (reactions) trên tin nhắn: đọc kèm tin, cập nhật trực tiếp, thả / gỡ.

use super::*;
use grammers_client::tl::{enums, functions, types};

/// Cảm xúc của một tin cho app: `[{e, n, me, custom?, paid?}]` (theo thứ tự Telegram trả). Emoji riêng (Premium) → «✨»,
/// sao trả phí → «⭐» — app chỉ hiện, không thả được hai loại này.
pub(super) fn reactions_json(r: &enums::MessageReactions) -> Value {
    let enums::MessageReactions::Reactions(r) = r;
    let mut out = Vec::new();
    for enums::ReactionCount::Count(c) in &r.results {
        let (e, kind) = match &c.reaction {
            enums::Reaction::Emoji(x) => (x.emoticon.clone(), None),
            enums::Reaction::CustomEmoji(_) => ("✨".to_string(), Some("custom")),
            enums::Reaction::Paid => ("⭐".to_string(), Some("paid")),
            enums::Reaction::Empty => continue,
        };
        let mut v = json!({"e": e, "n": c.count, "me": c.chosen_order.is_some()});
        if let Some(k) = kind {
            v[k] = json!(true);
        }
        out.push(v);
    }
    Value::Array(out)
}

/// Cảm xúc của tin (không có → null).
pub(super) fn msg_reactions(m: &Message) -> Value {
    match &m.raw {
        enums::Message::Message(x) => match x.reactions.as_ref().map(reactions_json) {
            Some(Value::Array(a)) if !a.is_empty() => Value::Array(a),
            _ => Value::Null,
        },
        _ => Value::Null,
    }
}

/// Cảm xúc chat cho thả: "all" | ["👍", …] | "none".
pub(super) fn allowed_json(r: Option<&enums::ChatReactions>) -> Value {
    match r {
        None | Some(enums::ChatReactions::All(_)) => json!("all"),
        Some(enums::ChatReactions::None) => json!("none"),
        Some(enums::ChatReactions::Some(x)) => Value::Array(
            x.reactions
                .iter()
                .filter_map(|r| match r {
                    enums::Reaction::Emoji(e) => Some(json!(e.emoticon)),
                    _ => None,
                })
                .collect(),
        ),
    }
}

/// Các cập nhật trong phản hồi của một lệnh (lệnh gọi thô — không đi qua luồng cập nhật của grammers).
pub(super) fn updates_of(u: enums::Updates) -> Vec<enums::Update> {
    match u {
        enums::Updates::Updates(x) => x.updates,
        enums::Updates::Combined(x) => x.updates,
        enums::Updates::UpdateShort(x) => vec![x.update],
        _ => Vec::new(),
    }
}

impl Core {
    /// `messages.react` {peer, id, emoji?}: thả cảm xúc `emoji` (thay cảm xúc cũ của mình), không có / rỗng → gỡ. Trả
    /// `{reactions}` mới của tin (nếu phản hồi có).
    pub(super) async fn react(&self, a: &Value) -> Res {
        let pr = self.peer_ref(a).await?;
        let id = a.get("id").and_then(Value::as_i64).ok_or_else(|| CoreError::new("BAD_ARGS", "thiếu «id»"))? as i32;
        let reaction = match a.get("emoji").and_then(Value::as_str).filter(|s| !s.is_empty()) {
            Some(e) => vec![enums::Reaction::Emoji(types::ReactionEmoji { emoticon: e.to_string() })],
            None => Vec::new(),
        };
        let u = self
            .client
            .invoke(&functions::messages::SendReaction {
                big: false,
                add_to_recent: true,
                peer: pr.into(),
                msg_id: id,
                reaction: Some(reaction),
            })
            .await?;
        for up in updates_of(u) {
            if let enums::Update::MessageReactions(x) = up {
                if x.msg_id == id {
                    return Ok(json!({"reactions": reactions_json(&x.reactions)}));
                }
            }
        }
        Ok(json!({}))
    }

    /// `reactions.available`: emoji Telegram cho thả (bỏ loại ngừng dùng / chỉ cho Premium) — app lọc tiếp loại iOS 5 / 6 vẽ được.
    pub(super) async fn reactions_available(&self) -> Res {
        match self.client.invoke(&functions::messages::GetAvailableReactions { hash: 0 }).await? {
            enums::messages::AvailableReactions::Reactions(x) => Ok(Value::Array(
                x.reactions
                    .iter()
                    .filter_map(|r| {
                        let enums::AvailableReaction::Reaction(r) = r;
                        (!r.inactive && !r.premium).then(|| json!(r.reaction))
                    })
                    .collect(),
            )),
            _ => Ok(json!([])),
        }
    }

    /// Cập nhật thô ngoài tin mới / sửa / xoá: cảm xúc đổi → `msg.reactions`.
    pub(super) fn emit_extra(&self, raw: &enums::Update) {
        if let enums::Update::MessageReactions(x) = raw {
            if let Some(id) = tl_peer_id(&x.peer) {
                (self.emit)(json!({
                    "e": "msg.reactions",
                    "peer": peer_key(id),
                    "id": x.msg_id,
                    "reactions": reactions_json(&x.reactions),
                }));
            }
        }
    }
}
