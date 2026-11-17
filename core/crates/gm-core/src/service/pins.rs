//! Tin ghim: các tin đang ghim của chat (thanh trên đầu màn chat), ghim / bỏ ghim, cập nhật trực tiếp.

use super::*;
use grammers_client::tl::{enums, functions};

impl Core {
    /// `messages.pinned` {peer}: các tin đang ghim, mới → cũ (tối đa 50). Màn chủ đề tự lọc theo `topic` của tin.
    pub(super) async fn pinned_list(&self, a: &Value) -> Res {
        let pr = self.peer_ref(a).await?;
        let mut it = self.client.search_messages(pr).filter(enums::MessagesFilter::InputMessagesFilterPinned).limit(50);
        let mut out = Vec::new();
        while let Some(m) = it.next().await? {
            out.push(msg_json(&m));
        }
        Ok(Value::Array(out))
    }

    /// `messages.pin` {peer, id, unpin?, notify?}: ghim / bỏ ghim (mặc định không báo cho mọi người). Nhóm / kênh cần quyền quản
    /// trị → lỗi CHAT_ADMIN_REQUIRED.
    pub(super) async fn pin(&self, a: &Value) -> Res {
        let pr = self.peer_ref(a).await?;
        let id = a.get("id").and_then(Value::as_i64).ok_or_else(|| CoreError::new("BAD_ARGS", "thiếu «id»"))? as i32;
        let unpin = a.get("unpin").and_then(Value::as_bool).unwrap_or(false);
        let notify = a.get("notify").and_then(Value::as_bool).unwrap_or(false);
        self.client
            .invoke(&functions::messages::UpdatePinnedMessage { silent: !notify, unpin, pm_oneside: false, peer: pr.into(), id })
            .await?;
        Ok(json!({}))
    }

    /// Cập nhật thô: ghim / bỏ ghim → `msg.pinned` {peer, ids, pinned}.
    pub(super) fn emit_pins(&self, raw: &enums::Update) {
        let (peer, ids, pinned) = match raw {
            enums::Update::PinnedMessages(x) => (tl_peer_id(&x.peer), &x.messages, x.pinned),
            enums::Update::PinnedChannelMessages(x) => (PeerId::channel(x.channel_id), &x.messages, x.pinned),
            _ => return,
        };
        if let Some(p) = peer {
            (self.emit)(json!({"e": "msg.pinned", "peer": peer_key(p), "ids": ids, "pinned": pinned}));
        }
    }
}
