//! Bình chọn (poll / câu đố): đọc kèm tin, bỏ phiếu / rút phiếu, cập nhật kết quả trực tiếp.

use super::bots::{hex, unhex};
use super::*;
use grammers_client::tl::{enums, functions, types};

/// Kết quả: `{total, voters: [{o, n, chosen, correct}], solution?}` (o = mã lựa chọn, hex).
pub(super) fn results_json(r: &types::PollResults) -> Value {
    let voters: Vec<Value> = r
        .results
        .iter()
        .flatten()
        .map(|enums::PollAnswerVoters::Voters(v)| {
            json!({"o": hex(&v.option), "n": v.voters.unwrap_or(0), "chosen": v.chosen, "correct": v.correct})
        })
        .collect();
    // min: kết quả không kèm lựa chọn của mình (cập nhật do người khác bỏ phiếu) — app giữ dấu ✓ cũ
    json!({"total": r.total_voters.unwrap_or(0), "voters": voters, "solution": r.solution, "min": r.min})
}

fn text_of(t: &enums::TextWithEntities) -> String {
    let enums::TextWithEntities::Entities(x) = t;
    x.text.clone()
}

/// Bình chọn: `{id, q, answers: [{t, o}], closed, multi, quiz, public, results}`.
pub(super) fn poll_json(p: &types::Poll, r: &types::PollResults) -> Value {
    let answers: Vec<Value> = p
        .answers
        .iter()
        .filter_map(|a| match a {
            enums::PollAnswer::Answer(a) => Some(json!({"t": text_of(&a.text), "o": hex(&a.option)})),
            _ => None,
        })
        .collect();
    json!({
        "id": p.id.to_string(),
        "q": text_of(&p.question),
        "answers": answers,
        "closed": p.closed,
        "multi": p.multiple_choice,
        "quiz": p.quiz,
        "public": p.public_voters,
        "results": results_json(r),
    })
}

/// Bình chọn trong tin (không phải → null).
pub(super) fn msg_poll(m: &Message) -> Value {
    match m.media() {
        Some(Media::Poll(p)) => poll_json(&p.raw, &p.raw_results),
        _ => Value::Null,
    }
}

/// Cập nhật bình chọn (thô) → `{poll_id, peer?, id?, poll?, results}` (máy chủ có thể chỉ gửi kết quả — app gộp vào bình chọn
/// đang có theo `poll_id`).
fn update_json(x: &types::UpdateMessagePoll) -> Value {
    let enums::PollResults::Results(res) = &x.results;
    let poll = x.poll.as_ref().map(|p| {
        let enums::Poll::Poll(p) = p;
        poll_json(p, res)
    });
    json!({
        "poll_id": x.poll_id.to_string(),
        "peer": x.peer.as_ref().and_then(tl_peer_id).map(peer_key),
        "id": x.msg_id,
        "poll": poll,
        "results": results_json(res),
    })
}

impl Core {
    /// `messages.vote` {peer, id, options: [mã hex]} — rỗng = rút phiếu. Trả `{poll?, results}` mới (nếu phản hồi có).
    pub(super) async fn vote(&self, a: &Value) -> Res {
        let pr = self.peer_ref(a).await?;
        let id = a.get("id").and_then(Value::as_i64).ok_or_else(|| CoreError::new("BAD_ARGS", "thiếu «id»"))? as i32;
        let options: Vec<Vec<u8>> = a
            .get("options")
            .and_then(Value::as_array)
            .map(|v| v.iter().filter_map(Value::as_str).filter_map(unhex).collect())
            .unwrap_or_default();
        let u = self.client.invoke(&functions::messages::SendVote { peer: pr.into(), msg_id: id, options }).await?;
        for up in react::updates_of(u) {
            if let enums::Update::MessagePoll(x) = up {
                return Ok(update_json(&x));
            }
        }
        Ok(json!({}))
    }

    /// Cập nhật thô: bình chọn đổi → `msg.poll`.
    pub(super) fn emit_poll(&self, raw: &enums::Update) {
        if let enums::Update::MessagePoll(x) = raw {
            let mut v = update_json(x);
            v["e"] = json!("msg.poll");
            (self.emit)(v);
        }
    }
}

impl Core {
    /// `messages.sendPoll` {peer, q, answers: [chữ], multi?, public?}: gửi bình chọn (2–12 lựa chọn).
    pub(super) async fn send_poll(&self, a: &Value) -> Res {
        let pr = self.peer_ref(a).await?;
        let q = arg_str(a, "q")?.trim().to_string();
        let answers: Vec<String> = a
            .get("answers")
            .and_then(Value::as_array)
            .map(|v| v.iter().filter_map(Value::as_str).map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect())
            .unwrap_or_default();
        if q.is_empty() || answers.len() < 2 || answers.len() > 12 {
            return Err(CoreError::new("BAD_ARGS", "Cần câu hỏi và 2–12 lựa chọn."));
        }
        let twe = |t: String| enums::TextWithEntities::Entities(types::TextWithEntities { text: t, entities: Vec::new() });
        let poll = types::Poll {
            id: 0,
            closed: false,
            public_voters: a.get("public").and_then(Value::as_bool).unwrap_or(false),
            multiple_choice: a.get("multi").and_then(Value::as_bool).unwrap_or(false),
            quiz: false,
            open_answers: false,
            revoting_disabled: false,
            shuffle_answers: false,
            hide_results_until_close: false,
            creator: false,
            subscribers_only: false,
            question: twe(q),
            answers: answers
                .into_iter()
                .map(|t| enums::PollAnswer::InputPollAnswer(types::InputPollAnswer { text: twe(t), media: None }))
                .collect(),
            close_period: None,
            close_date: None,
            countries_iso2: None,
            hash: 0,
        };
        let media = enums::InputMedia::Poll(Box::new(types::InputMediaPoll {
            poll: enums::Poll::Poll(poll),
            correct_answers: None,
            attached_media: None,
            solution: None,
            solution_entities: None,
            solution_media: None,
        }));
        let msg = grammers_client::message::InputMessage::new().text("").media(media).reply_to(reply_arg(a));
        let m = self.client.send_message(pr, msg).await?;
        Ok(msg_json(&m))
    }
}
