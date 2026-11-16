# GramMini — Hợp đồng giữa app (Objective-C) và lõi Rust

Lõi: `core/crates/gm-ffi` → `libgm_ffi.a` (dịch vụ ở `core/crates/gm-core/src/service.rs`). App: `app/Core/GMCore.m`.

## Hàm C

```c
typedef void (*gm_cb)(const char *json, void *ctx);
int  gm_init(const char *config_json, gm_cb on_event, void *ctx);
void gm_call(const char *request_json, gm_cb on_result, void *ctx);
```

- `gm_init` — một lần lúc mở app. `config_json`: `{"data_dir", "device_model", "system_version", "app_version", "lang"}`.
  Trả 0 = được; 1 = cấu hình sai; 2 = bản dựng thiếu api_id (`keys/telegram.txt`); 3 = không mở được dữ liệu; 4 = đã mở.
  Không đụng mạng; lõi tự hỏi trạng thái đăng nhập ở nền rồi đẩy sự kiện `auth.state`.
- `gm_call` — chạy nền. `request_json`: `{"m": "<nhóm.lệnh>", "a": {…}}`. `on_result` được gọi **đúng một lần** với
  `{"ok": <kết quả>}` hoặc `{"err": {"code", "msg", …}}`.
- Callback chạy trên luồng của lõi; chuỗi chỉ dùng được trong lúc gọi (app phân tích ngay rồi chuyển về luồng chính).
- Dữ liệu ở `data_dir` (`~/Library/GramMini`): `session.json` (phiên, 0600), `settings.json` (proxy), `core.log`; app ghi
  thêm `app.log`.

## Khoá peer

Chuỗi số kiểu Bot API: người dùng `"123456"`, nhóm thường `"-123456"`, kênh / siêu nhóm `"-100123456"`. Lõi chỉ nhận peer đã
biết (có trong danh sách chat / tin đã tải — access_hash lưu trong phiên), không thì lỗi `PEER_UNKNOWN`.

## Lệnh

| Lệnh | Tham số | Kết quả |
| --- | --- | --- |
| `auth.state` | — | `{"authorized": bool, "me"?: User, "dead"?: true}` — `dead`: Telegram đã huỷ phiên (AUTH_KEY_DUPLICATED…), tệp phiên đã dời; mở lại app để đăng nhập |
| `auth.sendCode` | `phone` (+84…) | `{}` |
| `auth.signIn` | `code` | `{"me": User}`; lỗi `PASSWORD_NEEDED` (kèm `hint`), `PHONE_CODE_INVALID`, `SIGN_UP_REQUIRED` |
| `auth.checkPassword` | `password` | `{"me": User}`; lỗi `PASSWORD_INVALID` |
| `auth.logout` | — | `{}` + sự kiện `auth.state` |
| `proxy.get` | — | `{"link": string \| null}` |
| `proxy.set` | `link` (null = đi thẳng) | `{}` — lưu, ngắt kết nối cũ, kết nối mới đi đường mới |
| `proxy.test` | `link` | `{"ms"}` — tạo auth key qua đường đó tới DC2; lỗi `PROXY_LINK`, `PROXY_FAIL`, `TIMEOUT` |
| `dialogs.list` | `limit` (50) | `[Dialog]` |
| `messages.history` | `peer`, `limit` (40), `offset_id`? | `[Message]` mới → cũ |
| `messages.send` | `peer`, `text`, `reply_to`?, `schedule`? (Unix giây — hẹn giờ), `queue`? | `Message`; hẹn giờ → `{"scheduled": true}`; `queue` + lỗi mạng → `{"queued": true, "local_id", …}` (hàng chờ, xem `outbox.*`) |
| `messages.typing` | `peer`, `action`: typing \| recording \| voice \| photo \| video \| file \| cancel | `{}` — báo «đang …» |
| `messages.search` | `q`, `peer`? (không có = mọi chat), `limit` (30) | `[Message + chat_name]` |
| `messages.media` | `peer`, `kind`: photo (ảnh + video) \| file \| voice \| link \| music, `limit` (60), `offset_id`? | `[Message]` mới → cũ |
| `chat.status` | `peer` | người: `{kind: user, bot, status: online\|offline\|recently\|week\|month\|hidden, was_online?, expires?}`; nhóm / kênh: `{kind, members, online}` |
| `chat.info` | `peer` | `Peer` + `about`, `muted`, `ttl` (giây tin tự xoá, 0 = tắt); người: `blocked`, `common_chats`; nhóm / kênh: `members`, `online`, `can_view_members` |
| `chat.ttl` | `peer`, `period` (giây; 0 = tắt) | `{ttl}` — tin mới trong chat tự xoá sau `period` (cả hai bên / mọi người); nhóm / kênh cần quyền quản trị; Tin nhắn đã lưu: `PEER_ID_INVALID` |
| `account.defaultTtl` | `period`? | `{ttl}` — không có `period`: đọc; có: đặt mức tự xoá mặc định cho chat mới |
| `chat.members` | `peer`, `limit` (200) | `[Peer + role: creator\|admin\|member]` |
| `chat.mute` | `peer`, `mute` | `{muted}` |
| `dialogs.pin` | `peer`, `pin` | `{pinned}` |
| `dialogs.delete` | `peer`, `revoke`? | `{}` — chat riêng: xoá lịch sử phía mình (`revoke`: cho cả hai bên — messages.deleteHistory lặp tới hết); nhóm thường: rời; kênh / siêu nhóm: rời |
| `contacts.list` | — | `[Peer]` theo tên |
| `contacts.search` | `q` (≥ 2 ký tự), `limit` (20) | `[Peer + mine]` — người / nhóm / kênh theo tên, @tên (lưu vào phiên → mở chat được) |
| `contacts.resolve` | `username` | `Peer`; lỗi `USERNAME_NOT_OCCUPIED` |
| `outbox.list` | `peer`? | tin chờ gửi `[{local_id, peer, text, reply_to, date}]` |
| `outbox.cancel` | `local_id` | `{}` |
| `stickers.sets` | — | `[{id, access_hash, title, count}]` — bộ sticker đã cài (mã là chuỗi) |
| `stickers.set` | `id`, `access_hash` | `[DocRef]` |
| `stickers.recent` | — | `[DocRef]` sticker dùng gần đây |
| `stickers.setInfo` | `id` + `access_hash`, hoặc `short_name` | `{set: StickerSet, items: [DocRef]}` — xem một bộ |
| `stickers.install` / `stickers.uninstall` | như trên | `{}` — thêm / gỡ bộ khỏi tài khoản |
| `stickers.featured` | — | `[StickerSet + cover: DocRef]` bộ nổi bật |
| `stickers.search` | `q` | `[StickerSet + cover]` tìm bộ theo tên |
| `folders.list` | — | `[Folder]` thư mục chat (bỏ «Tất cả») |
| `folders.suggested` | — | `[Folder + description]` gợi ý của Telegram |
| `folders.save` | `Folder` (không `id` = tạo mới) | `{id}` |
| `folders.delete` | `id` | `{}` |
| `folders.order` | `order`: [id] | `{}` |
| `gifs.saved` | — | `[DocRef]` GIF đã lưu |
| `media.docpreview` | `doc` | `{"path"}` — PNG xem trước (sticker tĩnh: cả tệp; sticker động / GIF: ảnh thu nhỏ), đệm `media/k<mã>.png` |
| `messages.sendDoc` | `peer`, `doc`, `reply_to`? | `Message` — gửi lại sticker / GIF đã lấy về |
| `account.get` | — | `User` + `first`, `last`, `about` |
| `account.update` | `first`?, `last`?, `about`? | `{}` |
| `account.checkUsername` | `username` | `{free}` |
| `account.setUsername` | `username` (rỗng = bỏ) | `{}` |
| `account.setPhoto` | `path` (JPEG) | `User` |
| `account.sessions` | — | `[{hash, current, official, device, platform, system, app, created, active, ip, country, region}]` |
| `account.terminate` | `hash` | `{}` — kết thúc một phiên khác |
| `account.privacy` | — | `{status\|phone\|photo\|forwards\|calls\|invites: {value: everybody\|contacts\|nobody, allow, deny}}` |
| `account.setPrivacy` | `key`, `value` | `{}` — bỏ các ngoại lệ đã đặt |
| `contacts.rename` | `peer`, `first`, `last`? | `{}` — tên mình lưu cho người này |
| `groups.create` | `title`, `users` [khoá peer] | `Peer` của nhóm mới + `missing` (số người không thêm được vì quyền riêng tư) |
| `groups.delete` | `peer` | `{}` — xoá hẳn nhóm thường (người tạo) |
| `debug.offline` | `on` | `{offline}` — thử: tạm đi qua proxy chết (không lưu cài đặt) |
| `messages.edit` | `peer`, `id`, `text` | `{}` |
| `messages.delete` | `peer`, `ids`, `revoke`? (mặc định true) | `{"deleted"}` — `revoke`: xoá cho cả hai bên / mọi người; false: chỉ phía mình (chat riêng, nhóm thường); kênh / siêu nhóm luôn xoá cho mọi người |
| `messages.forward` | `from`, `to`, `ids` | `[Message]` (tin mới ở chat đích) |
| `messages.read` | `peer` | `{}` |
| `media.avatar` | `peer`, `photo`, `dc` | `{"path"}` — ảnh đại diện nhỏ (JPEG, có đệm trên đĩa) |
| `media.photo` | `peer`, `id`, `big` | `{"path"}` — ảnh trong tin, cỡ vừa / lớn |
| `media.sticker` | `peer`, `id` | `{"path"}` — PNG (WebP đổi sang; sticker động: ảnh thu nhỏ) |
| `media.stickerfile` | `peer`, `id`, `kind`? (`tgs` mặc định \| `webm`) | `{"path"}` — tệp gốc sticker động (`media/s<peer>_<id>_a.tgs`, kiểm gzip) hoặc sticker video (`…_v.webm`, kiểm EBML); lỗi `NOT_ANIMATED`, `DECODE` |
| `media.voice` | `peer`, `id` | `{"path", "duration"}` — WAV 24 kHz đơn kênh |
| `media.document` | `peer`, `id` | `{"path"}` — tệp / video gốc (`media/d<peer>_<id>.<đuôi>`); tải có sự kiện `media.progress` |
| `media.thumb` | `peer`, `id` | `{"path"}` — ảnh xem trước JPEG của video / tệp |
| `messages.sendPhoto` | `peer`, `path` (JPEG), `caption`?, `reply_to`? | `Message` |
| `messages.sendVoice` | `peer`, `path` (WAV 16 bit đơn kênh), `reply_to`? | `Message` (Opus + dạng sóng) |
| `messages.sendFile` | `peer`, `path`, `name`?, `mime`?, `video`? `{duration, w, h}`, `caption`?, `reply_to`?, `tag`? | `Message`; có `tag` thì báo tiến độ bằng `upload.progress`; lỗi `EMPTY_FILE`, `FILE_TOO_BIG` (> 2 GB), `UPLOAD` |
| `net.state` | — | `{"ok"}` — trạng thái mạng lõi đang biết |
| `net.check` | — | `{"ok"}` — hỏi thử máy chủ ngay |
| `cache.stats` | — | `{"total", "files", "kinds": {photo, video, file, music, voice, sticker, avatar, other → byte}, "chats": [{"peer", "name", "bytes"}] (50 chat nặng nhất), "limit_mb", "keep_days", "free", "disk"}` |
| `cache.clear` | `kinds`? [loại], `peer`? | `{"freed", "files"}` — không tham số = xoá hết; + sự kiện `cache.cleared` |
| `cache.set` | `limit_mb`? (0 = không giới hạn), `keep_days`? (0 = mãi mãi) | `{}` — lưu `settings.json`, dọn ngay |
| `app.flush` | — | `{}` — ghi phiên ra đĩa (gọi khi app xuống nền) |

- `User`: `{"id", "name", "username", "phone", "photo", "photo_dc"}`
- `Peer` (tìm, danh bạ, thông tin): `{"peer", "name", "kind", "username", "photo", "photo_dc"}` + người: `"phone", "bot", "status"` (như `chat.status`)
- `DocRef` (sticker / GIF): `{"doc" (chuỗi), "emoji", "mime", "w", "h", "duration", "animated"}` — lõi giữ tài liệu theo mã để gửi lại.
- `Message` còn có `"scheduled"` (tin hẹn giờ vừa tới giờ), `"silent"`, `"mentioned"`.
- Tên người trong danh bạ là **tên mình lưu** (máy chủ Telegram thay tên hồ sơ bằng tên trong danh bạ).
- `Dialog`: `{"peer", "name", "kind": "user"|"group"|"channel", "unread", "pinned", "muted", "read_in", "read_out", "photo", "photo_dc", "contact", "bot", "archived", "marked_unread", "last": Message | null}`
- `StickerSet`: `{"id", "access_hash", "title", "short_name", "count", "installed", "archived", "masks", "emojis"}` (mã là chuỗi). Tin sticker: `sticker.set` = `{id, access_hash}` hoặc `{short_name}`.
- `Folder`: `{"id", "title", "emoticon", "contacts", "non_contacts", "groups", "broadcasts", "bots", "exclude_muted", "exclude_read", "exclude_archived", "include": [peer], "exclude": [peer], "pinned": [peer], "chatlist"?: true}` — peer của mình là `"self"`; app tự lọc danh sách chat (như Telegram gốc).
- `Message`: `{"id", "peer", "date" (Unix), "out", "text", "from", "media": null|"photo"|"video"|"voice"|"audio"|"sticker"|"file"|"image"|"contact"|"poll"|"geo"|"dice"|"media", "service", "reply_to", "edited", "from_id", "links": [string], "proxy": string | null, "fwd": string | null, "photo": {"w", "h", "thumb"} | null, "sticker": {"emoji", "w", "h", "animated", "mime"} | null, "voice": {"duration", "waveform": [0–31]} | null, "doc": {"name", "size", "mime", "kind": "gif"|"round"|"video"|"audio"|"file", "duration", "w", "h", "thumb", "has_thumb"} | null}` — tin hệ thống: `text` là câu mô tả tiếng Việt

Lỗi chung: `FLOOD_WAIT` (kèm `value` giây), `NETWORK`, `NOT_STARTED`, `BAD_ARGS`, `NO_METHOD`, hoặc tên lỗi RPC của Telegram.

## Sự kiện (`on_event`)

| `e` | Trường |
| --- | --- |
| `auth.state` | `authorized`, `dead`? |
| `auth.dead` | `code` — phiên bị Telegram huỷ (dùng trùng ở hai nơi / thu hồi / tài khoản khoá) |
| `msg.new` | `msg` |
| `msg.edit` | `msg` |
| `msg.delete` | `ids`, `channel` (khoá peer kênh, hoặc null với chat riêng / nhóm thường) |
| `msg.readOutbox` | `peer`, `max_id` — bên kia đã đọc tới tin này |
| `net.state` | `ok` — kết nối được / mất kết nối (chỉ khi đổi) |
| `media.progress` | `peer`, `id`, `done`, `total` (byte) — đang tải tệp (~ mỗi 256 KB) |
| `upload.progress` | `tag`, `done`, `total` (byte) — đang tải tệp lên (~ mỗi 256 KB) |
| `net.socket` | `fd`, `dc` — lõi vừa mở socket TCP tới Telegram (app iOS bọc thành socket VoIP — D17) |
| `typing` | `peer` (chat), `from`, `name`, `action` (như `messages.typing`) |
| `user.status` | `peer` + trường như `chat.status` của người |
| `outbox.sent` | `local_id`, `peer`, `msg` — tin trong hàng chờ đã gửi |
| `outbox.failed` | `local_id`, `peer`, `code`, `message` — máy chủ từ chối tin trong hàng chờ |
| `cache.cleared` | — lõi vừa xoá tệp đệm (tự dọn / `cache.clear`): app quên đường dẫn cũ |

## Sticker động / video (đồng bộ, gọi ở hàng đợi nền)

- `gm_lottie_open(path) → anim`, `gm_lottie_info(anim, &fps, &frames, &w, &h)`, `gm_lottie_render(anim, frame, buf, w, h)`,
  `gm_lottie_close(anim)` — TGS (crate gm-lottie, D26); hoạt hình bất biến, vẽ khung nào cũng được, luồng nào cũng được.
- `gm_webm_open(path) → video`, `gm_webm_info(…)`, `gm_webm_render(video, frame, buf, w, h)`, `gm_webm_close(video)` — sticker
  video WebM / VP9 (crate gm-webm + libvpx, D27); cùng cách gọi nhưng có trạng thái (giải mã tuần tự): mỗi video chỉ dùng trên
  một luồng tại một lúc, đi tới thì nhanh, lùi lại thì giải lại từ khung khoá.
- `buf`: RGBA đã nhân alpha, `w × h × 4` byte (`kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big`), hình thu vừa khung,
  giữ tỉ lệ, căn giữa. Trả 0 nếu vẽ được.
