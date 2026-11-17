//! Tin hẹn giờ (nhắc hẹn ở Tin nhắn đã lưu): danh sách tin đã hẹn của chat, gửi ngay, xoá.

use super::*;
use grammers_client::tl::{enums, functions};

fn ids_arg(a: &Value) -> Result<Vec<i32>, CoreError> {
    let ids: Vec<i32> = a
        .get("ids")
        .and_then(Value::as_array)
        .map(|v| v.iter().filter_map(Value::as_i64).map(|x| x as i32).collect())
        .unwrap_or_default();
    if ids.is_empty() { Err(CoreError::new("BAD_ARGS", "thiếu «ids»")) } else { Ok(ids) }
}

impl Core {
    /// `messages.scheduled` {peer}: tin đã hẹn giờ của chat (`date` = giờ sẽ gửi), sớm → muộn.
    pub(super) async fn scheduled_list(&self, a: &Value) -> Res {
        let pr = self.peer_ref(a).await?;
        let r = self.client.invoke(&functions::messages::GetScheduledHistory { peer: pr.into(), hash: 0 }).await?;
        let (msgs, users, chats) = match r {
            enums::messages::Messages::Messages(x) => (x.messages, x.users, x.chats),
            enums::messages::Messages::Slice(x) => (x.messages, x.users, x.chats),
            enums::messages::Messages::ChannelMessages(x) => (x.messages, x.users, x.chats),
            enums::messages::Messages::NotModified(_) => (Vec::new(), Vec::new(), Vec::new()),
        };
        let peers = self.client.build_peer_map(users, chats).await;
        let mut out: Vec<Value> =
            msgs.into_iter().map(|m| msg_json(&Message::from_raw(&self.client, m, Some(pr), peers.handle()))).collect();
        out.sort_by_key(|v| v["date"].as_i64().unwrap_or(0));
        Ok(Value::Array(out))
    }

    /// `messages.scheduledSend` {peer, ids}: gửi ngay các tin đã hẹn; `messages.scheduledDelete` {peer, ids}: huỷ.
    pub(super) async fn scheduled_act(&self, method: &str, a: &Value) -> Res {
        let pr = self.peer_ref(a).await?;
        let id = ids_arg(a)?;
        if method == "messages.scheduledSend" {
            self.client.invoke(&functions::messages::SendScheduledMessages { peer: pr.into(), id }).await?;
        } else {
            self.client.invoke(&functions::messages::DeleteScheduledMessages { peer: pr.into(), id }).await?;
        }
        Ok(json!({}))
    }
}
