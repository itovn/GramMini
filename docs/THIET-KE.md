# GramMini — Phương án thiết kế (bản nháp 16/11/2026)

App nhắn tin Telegram (client không chính thức) cho **iOS 5 / iOS 6 đã jailbreak**, lõi viết bằng **Rust**, vỏ
**Objective-C / UIKit**. Một gói `.deb` chạy cả iOS 5 và 6 — cùng cách làm đã chạy được ở Côn Bằng TV Legacy.

Tài liệu tham khảo (`Tai_Lieu/text.txt`):

| Nguồn | Lấy gì |
| --- | --- |
| [mpgram-web](https://github.com/Circling5714/mpgram-web) (fork của shinovon/mpgram-web) | Danh sách tính năng tối thiểu cho máy yếu, và API.md: bộ hàm JSON mà client J2ME / máy cũ dùng. Hợp đồng FFI của GramMini (mục 6) dựa theo bộ hàm này. |
| `E:\DEV_CODE\ConBangTV_Legacy` | Bộ dựng Rust cho armv7 iOS 5 / 6 đã chạy thật (target JSON, build-std, shim, ring vá), cầu FFI JSON, bẫy iOS 5 / 6, công cụ thử qua SSH, OTA bằng `cbupdate`, nguồn Cydia |
| `E:\DEV_CODE\TubeMini` | Mô hình server Rust + app mỏng, máy chủ HTTP nội bộ cho AVPlayer, giao diện sáng / tối tự quản, chặn API iOS 7+ lúc build, phát nền, ghi nhận «iOS 6 không vào được t.me (SSL -1200)» |

---

## 0. Tóm tắt các quyết định

1. **Client dày, không cần server.** Lõi Rust chạy **ngay trên máy** và nói chuyện thẳng với Telegram bằng **MTProto 2.0** qua
   TCP. MTProto tự mã hoá (AES-256-IGE, DH, RSA), không đi qua TLS của iOS, nên **lỗi TLS của iOS 6 không ảnh hưởng**. Khoá
   đăng nhập chỉ nằm trên máy.
2. **Thư viện MTProto: [grammers](https://codeberg.org/Lonami/grammers)** (Rust, MIT / Apache-2.0, có 2FA, có `proxy` = SOCKS5).
   Ghim một phiên bản, chép mã vào `core/vendor/`, sửa bằng `patches/` như cách Côn Bằng TV làm với lõi chung. Repo GitHub của
   grammers đã lưu trữ từ 10/02/2026 và chuyển sang Codeberg, nên không phụ thuộc vào GitHub.
3. **Dùng lại nguyên bộ dựng của Côn Bằng TV Legacy**: Theos + SDK 9.3 đã vá, Rust nightly + `-Z build-std`, target
   `armv7-apple-ios6.json` (Cortex-A8, chạy cả A4), shim C cho hàm iOS 5 / 6 thiếu, `symcheck`, `ldid -Hsha1`, dựng cho iOS 5.0.
4. **Cầu nối ObjC ↔ Rust bằng JSON qua vài hàm C** (`gm_init` / `gm_call` / `gm_call_sync` / `gm_free` + kênh sự kiện), giống
   `cbtv_*` của Côn Bằng TV. `NSJSONSerialization` có từ iOS 5.
5. **Offline trước**: mọi màn đọc từ bộ nhớ đệm SQLite của lõi trước, mạng về thì lõi đẩy sự kiện cập nhật.
6. **Proxy là tính năng bắt buộc ngay từ màn đăng nhập**. Ở Việt Nam, nhà mạng chặn Telegram lúc có lúc không, nên
   **MTProxy làm ngay từ đầu** (anh chốt 16/11/2026). Có thêm SOCKS5 và Shadowsocks, dùng lại từ lõi chung ChimToTV.
7. **Không làm**: gọi thoại / video, chat bí mật, Stories, Mini App / WebApp của bot, thanh toán, Premium.

---

## 1. Mục tiêu và máy đích

| Máy thử (sẵn có từ Côn Bằng TV) | Chip / RAM | Vai trò |
| --- | --- | --- |
| iPad 1 — iOS 5.1.1 | A4 một nhân, **256 MB** | Máy yếu nhất: đặt ngân sách hiệu năng theo máy này |
| iPhone 5 — iOS 6.1.4 | A6, 1 GB | Máy chính iPhone |
| iPad mini 1 — iOS 6.1.3 | A5, 512 MB | Máy chính iPad |

Ngân sách hiệu năng (đo trên iPad 1):

- Mở app tới danh sách chat (đọc từ bộ đệm): ≤ 2 giây. Mở một chat (40 tin từ bộ đệm): ≤ 300 ms.
- RAM app: ≤ 40 MB khi nhắn tin, ≤ 80 MB khi xem video. Cuộn danh sách không giật.
- Không treo luồng chính quá 20 giây lúc mở app (iOS tắt app với mã 0x8badf00d — Côn Bằng TV đã gặp trên A4).

---

## 2. Bài học từ tài liệu tham khảo

**mpgram-web** (PHP + MadelineProto, chạy trên server). Server giữ phiên đăng nhập Telegram của người dùng, rồi trả HTML cho
trình duyệt cũ (IE6, Opera Mini, Symbian…) hoặc trả JSON qua `api.php` cho client riêng. API.md của nó cho thấy một client
gọn cần những gì:

- đăng nhập: số điện thoại → mã → mật khẩu 2FA, đăng nhập bằng mã QR;
- `getDialogs`, `getHistory`, `sendMessage`, `sendMedia`, `editMessage`, `deleteMessage`, `readMessages`, `setTyping`;
- `updates`: chờ dài (long-poll) để nhận tin mới; `notifications`: hỏi theo nhịp;
- `file.php`: server thu nhỏ ảnh, đổi sticker TGS sang PNG / GIF; `voice.php`: đổi tin nhắn thoại sang MP3.

Hai việc đổi định dạng này là phần nặng mà máy yếu không làm được. GramMini làm nhẹ hơn ngay trên máy (mục 8).

**Côn Bằng TV Legacy** đã chứng minh trên máy thật: Rust std + tokio + reqwest / rustls + HTTP/2 chạy trên iOS 5.1.1 và 6.1.4;
lõi gọi qua JSON; libwebp vá cho iOS cũ; tự cập nhật OTA. Các bẫy đã gặp và cách xử lý (GramMini dùng lại):

- Rust chỉ hỗ trợ iOS 10+ → target tự định nghĩa, `has-thread-local: false`, `panic = abort`, build-std.
- Hàm iOS 5 / 6 không có → shim: `clock_gettime`, `CCRandomGenerateBytes`, `fclonefileat`, `__exp10`, `dirfd` (iOS 5).
- tokio trên armv7 iOS 6: việc đẩy vào từ ngoài có lúc không đánh thức luồng nào → nhịp 50 ms.
- iOS 5: `LC_MAIN` → phải dựng cho 5.0; `NSObject` ở Foundation; subscripting `a[i]` cần shim; không có
  `UICollectionView`, `UIRefreshControl`; `viewDidUnload` khi thiếu bộ nhớ; ký tự `▶` thành emoji.
- A4: giải mã nhiều ảnh cùng lúc làm treo luồng chính → hàng giải mã tuần tự ưu tiên thấp, bỏ ảnh của ô đã khuất.

**TubeMini** cần server vì việc lấy link YouTube (yt-dlp) quá nặng cho máy. Telegram thì khác: MTProto đủ nhẹ để chạy trên
máy, nên không cần server. TubeMini còn để lại: máy chủ HTTP nội bộ `127.0.0.1` có Range cho AVPlayer, `TMTheme` sáng / tối,
`-Werror=unguarded-availability`, cách giữ tiếng phát ở nền.

---

## 3. Chọn kiến trúc

| | A. Client dày (**chọn**) | B. Client mỏng + server (kiểu mpgram / TubeMini) | C. TDLib trên máy |
| --- | --- | --- | --- |
| Ai nói MTProto | Lõi Rust trên máy | Server (grammers hoặc MadelineProto) | TDLib (C++) trên máy |
| Phiên đăng nhập | Chỉ trên máy | **Nằm trên server**: ai giữ server là đọc được tin nhắn | Trên máy |
| Cần máy chạy suốt | Không | Có (PC / VPS), phải có VPN hoặc mạng LAN | Không |
| TLS của iOS 6 | Không dùng (MTProto qua TCP) | Server HTTPS bằng Let's Encrypt không chạy trên iOS 6 → phải dùng HTTP trong LAN hoặc gói rustls trong app | Không dùng |
| Đổi định dạng media | Trên máy (Opus, WebP) — sticker động thì bị giới hạn | Server làm hết (như `voice.php`, `file.php`) | Trên máy |
| Rủi ro dựng | Vừa: grammers chưa từng dựng cho armv7 iOS 6 | Thấp | **Cao**: C++17, libc++ trên iOS 5, RAM lớn, bộ dựng Theos |

**Chọn A.** Nếu spike S1 (mục 13) thất bại, đường lùi là B: lõi có một lớp `Backend` trừu tượng (hàm `dialogs`, `history`,
`send`…), nên có thể thêm `MpgramBackend` gọi `api.php` của một server mpgram mà không phải viết lại giao diện. Chỉ làm khi
cần.

---

## 4. Kiến trúc tổng thể

```text
┌──────────────────────────────────────────────────────────────────┐
│ App Objective-C / UIKit  (Theos, armv7, dựng cho iOS 5.0)          │
│  Đăng nhập · Danh sách chat · Màn chat (CoreText) · Xem ảnh/video   │
│  Cài đặt · Proxy · AVPlayer · AudioQueue / AVAudioPlayer · QuickLook │
└───────────┬───────────────────────────────────────▲──────────────┘
  gm_call (JSON, bất đồng bộ) / gm_call_sync          │ sự kiện JSON (gộp ~100 ms)
┌───────────▼───────────────────────────────────────┴──────────────┐
│ libgrammini_core.a  (Rust, armv7 Cortex-A8, build-std, panic=abort) │
│  gm-ffi ─► gm-core: Auth · Dialogs · Messages · Updates · Outbox     │
│                     Store (SQLite) · MediaManager · Proxy · Settings │
│            gm-media: Opus/OGG · ảnh mờ dựng sẵn · cổng phát 127.0.0.1 │
│            grammers: client · mtsender · mtproto · tl-types · crypto │
└───────────┬──────────────────────────────────────────────────────┘
            │ MTProto 2.0 trên TCP (tuỳ chọn qua SOCKS5 / MTProxy)
            ▼
     Máy chủ Telegram (DC 1–5)
```

Nguyên tắc chia việc:

- **Rust**: mọi thứ không phải giao diện. Gồm mạng, giao thức, lưu trữ, xử lý cập nhật, hàng tải / gửi, giải mã Opus, thực thể
  định dạng (entity) chữ, chuẩn hoá emoji.
- **ObjC**: vẽ giao diện, bố cục chữ (CoreText), giải mã ảnh JPEG / PNG (ImageIO), phát (AVPlayer), ghi âm, thông báo.
- Lõi trả **dữ liệu đã sẵn để hiển thị**: tên người gửi, xem trước tin cuối, trạng thái đã đọc… App không phải ráp từ kiểu TL.

---

## 5. Lõi Rust

### 5.1 Các crate (workspace `core/`)

| Crate | Việc |
| --- | --- |
| `gm-core` | Logic: `Session` (một tài khoản), máy trạng thái đăng nhập, hàng lệnh, xử lý cập nhật, Store, MediaManager, Outbox, chuyển kiểu TL sang DTO cho giao diện |
| `gm-net` | Đường ra mạng: đi thẳng / SOCKS5 / MTProxy (`dd`, `ee` fake-TLS), luôn bọc obfuscated2; cắm vào grammers qua bản vá `connector` (mục 5.5, D5) |
| `gm-media` | Giải mã / mã hoá Opus + OGG (libopus dựng bằng clang của Theos), dựng ảnh mờ từ stripped thumb (`PhotoStrippedSize` → JPEG), giải nén dạng sóng 5-bit, cổng phát HTTP nội bộ |
| `gm-ffi` | API C (`staticlib`), sinh `gm.h` bằng cbindgen, định tuyến JSON → hàm của `gm-core` |
| `gm-cli` | Chạy lõi trên Windows / Linux bằng dòng lệnh (đăng nhập, liệt kê chat, gửi tin, tải tệp). Phần lớn logic thử ở đây, không cần iPad. |

### 5.2 Runtime và luồng

- Một runtime tokio riêng của lõi. Bắt đầu với cấu hình Côn Bằng TV đã chạy được (kèm vá nhịp 50 ms), rồi đo thử
  `current_thread` trên một luồng riêng: A4 chỉ có một nhân, ít luồng hơn thì đỡ tốn.
- `gm_call` đẩy lệnh vào kênh rồi trả ngay. Kết quả gọi callback trên luồng của lõi, phía ObjC tự chuyển về main queue.
- Sự kiện (tin mới, sửa, xoá, đã đọc, đang gõ, trạng thái kết nối, tiến độ tải) được **gộp theo lô ~100 ms**, để luồng chính
  của A4 không bị dội.

### 5.3 Lưu trữ

App cài vào `/Applications` (không sandbox) nên dữ liệu ở `~/Library/GramMini/` (`/var/mobile/Library/GramMini`), quyền 0600.
Bộ đệm ở `~/Library/Caches/GramMini/`.

| Tệp / bảng | Nội dung |
| --- | --- |
| `session.db` | auth key theo DC, DC chính, trạng thái cập nhật (pts / qts / date / seq + pts của từng kênh) |
| `cache.db` → `peers` | user / nhóm / kênh: id, access_hash, tên, username, ảnh đại diện, cờ |
| `cache.db` → `dialogs` | peer, tin cuối, chưa đọc, ghim, thư mục, read inbox / outbox max id, tắt tiếng |
| `cache.db` → `messages` | ~200 tin gần nhất mỗi chat (giữ theo cửa sổ): id, ngày, người gửi, chữ, entity, media (JSON), trả lời, chuyển tiếp, sửa |
| `cache.db` → `outbox` | tin đang gửi (random_id, trạng thái); mất mạng thì gửi lại khi có mạng |
| `cache.db` → `files` | khoá tệp → đường dẫn, kích thước, đã xong chưa, lần dùng cuối (dọn kiểu LRU, mặc định 300 MB, đổi trong Cài đặt) |
| `cache.db` → `kv` | cài đặt, nháp tin nhắn |

SQLite dùng `rusqlite` với `bundled` (dựng mã C bằng clang của Theos, như ring). Không dùng sqlite của hệ thống, vì iOS 5 / 6
mang bản 3.7 cũ.

### 5.4 Cập nhật (updates)

- Dựa vào bộ xử lý khoảng hở của grammers (`getDifference`, `getChannelDifference`). Trạng thái được lưu xuống `session.db`, nên
  mở lại app thì lấy bù tin đã lỡ. Nếu Telegram trả `differenceTooLong`, lõi tải lại danh sách chat.
- Gửi tin: app hiện ngay với id tạm (đồng hồ ⏱). Lõi gọi `messages.sendMessage` kèm `random_id`. Khi nhận `updateMessageID`, lõi
  đổi sang id thật và phát `msg.sent` (✓). Khi bên kia đọc (`read_outbox_max_id`) thì phát `✓✓`.
- Lỗi `FLOOD_WAIT_X`: lõi tự chờ rồi thử lại; nếu phải chờ lâu thì báo lên giao diện. Không hỏi dồn liên tục.

### 5.5 Mạng và proxy

Tất cả kết nối ra mạng đi qua module `gm-net`, chia hai lớp:

- **Lớp đường đi**: trả về một luồng hai chiều (`Duplex`). Có các kiểu: đi thẳng, SOCKS5, Shadowsocks. SOCKS5 và Shadowsocks
  chép từ lõi chung ChimToTV (`linux/core/src/net.rs`, `shadowsocks.rs`, cùng tác giả). MTProxy cũng là một đường đi: máy chủ
  MTProxy là đích TCP, đi thẳng hoặc qua SOCKS5.
- **Lớp vỏ MTProto**: bọc luồng đó bằng **obfuscated2** (AES-256-CTR hai chiều, khoá suy từ 64 byte ngẫu nhiên đầu luồng, có
  secret MTProxy thì trộn thêm bằng SHA-256), bên trong là intermediate có đệm (padded intermediate, `0xdddddddd`). Đi thẳng tới
  DC cũng bọc obfuscated2 như app chính thức, để máy lọc gói (DPI) không nhận ra MTProto.
- **Secret MTProxy**: `<16 byte>` thì obfuscated2 thường; `dd<16 byte>` thì obfuscated2 + intermediate có đệm; `ee<16 byte><tên
  miền>` thì **fake-TLS**: gửi ClientHello giả TLS 1.3 có SNI là tên miền đó, ô random ký HMAC-SHA256 bằng secret, kiểm
  ServerHello trả về; sau đó mọi dữ liệu nằm trong bản ghi TLS application data (`17 03 03 <len>`). **Làm cả ba kiểu ngay.**
- Nhận dán link `tg://proxy?server=…&port=…&secret=…` và `https://t.me/proxy?…` (secret dạng hex hoặc base64url),
  `tg://socks?…`, `ss://…`.
- grammers chỉ có SOCKS5 (tính năng `proxy`). Lõi cắm transport riêng vào grammers ở chỗ mở kết nối; nếu grammers không cho
  cắm thì vá trong `patches/`.
- Có màn **Proxy ngay ở màn đăng nhập**, có nút «Thử kết nối». Nhận dán link `tg://proxy?…` / `https://t.me/proxy?…` và
  `tg://socks?…`.
- Báo trạng thái kết nối lên thanh tiêu đề: «Đang kết nối…», «Đang cập nhật…», «Đợi mạng…», «Proxy lỗi».

---

## 6. Cầu nối FFI (hợp đồng)

```c
// gm.h — sinh bằng cbindgen
typedef void (*gm_cb)(const char *json, void *ctx);
int   gm_init(const char *config_json);                  // data_dir, cache_dir, api_id, api_hash, device, system, app_version, lang
void  gm_set_event_handler(gm_cb cb, void *ctx);         // sự kiện đẩy từ lõi
void  gm_call(const char *req_json, gm_cb cb, void *ctx);// bất đồng bộ
char *gm_call_sync(const char *req_json);                // chỉ cho việc đọc bộ đệm, nhanh
void  gm_free(char *p);
```

Ví dụ:

```json
→ {"m":"messages.history","peer":"u123456","from":0,"limit":40}
← {"ok":true,"r":{"messages":[{"id":5012,"peer":"u123456","from":"u777","out":false,"date":1763270000,
     "text":"Chào anh","ent":[{"t":"bold","o":0,"l":4}],"media":null,"reply":null}],
     "peers":{"u777":{"name":"Minh","photo":"p:777:1"}}}}
← {"ok":false,"err":{"code":"FLOOD_WAIT","wait":31,"msg":"…"}}
sự kiện ← {"e":"msg.new","peer":"u123456","msg":{…}}
```

- **Khoá peer là chuỗi**: `u<id>` (người), `g<id>` (nhóm thường), `c<id>` (kênh / siêu nhóm). id của Telegram là số 64-bit, để
  dạng chuỗi thì không lo sai số khi qua JSON và không lẫn quy ước `-100…`.
- **Offset của entity là đơn vị UTF-16**, trùng với `NSString`, nên chuyển thẳng qua, không phải đổi.

| Nhóm | Lệnh |
| --- | --- |
| Đăng nhập | `auth.state`, `auth.sendCode`, `auth.resendCode`, `auth.signIn`, `auth.checkPassword`, `auth.qrStart` (sự kiện `auth.qr` khi mã QR đổi), `auth.logout` |
| Kết nối | `net.state`, `proxy.get` / `proxy.set` / `proxy.test` / `proxy.parseLink` |
| Chat | `dialogs.list` (offset, limit, archived, folder), `dialogs.pin`, `dialogs.mute`, `dialogs.markRead` |
| Tin nhắn | `messages.history`, `messages.around` (nhảy tới tin chưa đọc), `messages.send`, `messages.edit`, `messages.delete`, `messages.forward`, `messages.read`, `messages.typing`, `messages.search`, `messages.vote`, `messages.botCallback` |
| Người / nhóm | `peers.get`, `peers.full`, `contacts.list`, `search.global`, `chats.join` / `chats.leave`, `invite.check` / `invite.join` |
| Media | `media.download` (ưu tiên, huỷ được; sự kiện `media.progress` / `media.done`), `media.streamUrl` (→ `http://127.0.0.1:<cổng>/…`), `media.upload`, `voice.decode`, `voice.encode`, `stickers.sets`, `stickers.set` |
| Khác | `settings.get` / `settings.set`, `cache.usage` / `cache.clear`, `app.update.check` |

Sự kiện: `net.state`, `auth.state`, `auth.qr`, `dialogs.upsert`, `msg.new`, `msg.edit`, `msg.delete`, `msg.sent`,
`msg.readOutbox`, `typing`, `user.status`, `media.progress`, `media.done`.

---

## 7. App iOS (Objective-C)

### 7.1 Màn hình

| Màn | Có gì |
| --- | --- |
| Đăng nhập | số điện thoại (chọn mã nước), mã, mật khẩu 2FA; **đăng nhập bằng mã QR** (quét bằng Telegram trên điện thoại khác, đỡ gõ); nút Proxy |
| Danh sách chat | ảnh đại diện, tên, xem trước tin cuối, giờ, số chưa đọc, đã tắt tiếng, ghim, «đang gõ…»; Lưu trữ; tìm kiếm; kéo xuống để tải lại (iOS 5 tự vẽ) |
| Màn chat | bong bóng tin, gom theo người gửi, dải ngày, trả lời / chuyển tiếp, media, tin dịch vụ, ✓ / ✓✓; ô nhập tự giãn; đính kèm ảnh; giữ để ghi âm; giữ trên tin → `UIMenuController` (Trả lời, Sao chép, Chuyển tiếp, Sửa, Xoá); cuộn lên thì tải tin cũ; nút «↓ chưa đọc» |
| Thông tin chat / người | ảnh, tên, username, giới thiệu, tắt tiếng, rời nhóm; về sau có media đã chia sẻ |
| Danh bạ, Tìm toàn cục | |
| Xem ảnh / video | phóng to bằng `UIScrollView`; video qua AVPlayer; tệp qua `QLPreviewController` (iOS 4+) |
| Cài đặt | tài khoản, **Proxy**, dữ liệu và bộ đệm, thông báo, giao diện sáng / tối, ngôn ngữ (vi / en), khoá app bằng mã, phiên bản / cập nhật, giới thiệu (ghi rõ «ứng dụng không chính thức») |

**iPad**: `UISplitViewController` (có từ iOS 3.2), danh sách chat bên trái và màn chat bên phải. Lưới media dùng
`CBCollectionView` của Côn Bằng TV, vì iOS 5 không có `UICollectionView`.

### 7.2 Hiển thị tin nhắn

- **Vẽ chữ bằng CoreText** (`CTFramesetter`), dùng chung cho iOS 5 và 6. `UILabel.attributedText` chỉ có từ iOS 6, và
  CoreText vẽ nhanh hơn.
- Tính bố cục và chiều cao bong bóng ở **hàng nền**, rồi lưu đệm theo (id tin, ngày sửa, bề rộng). `heightForRowAtIndexPath`
  chỉ việc đọc lại.
- Ô của danh sách chat vẽ gọn trong một `drawRect:` (kiểu «fast cell» thời iOS 5), không chồng nhiều subview.
- Link, @mention, #hashtag bấm được. `t.me/…` thì mở trong app (resolve username). Link ngoài mở Safari (nhiều trang HTTPS không
  mở được trên iOS 6).
- **Emoji**: phông của iOS 5 / 6 chỉ có emoji Unicode 6.0. Lõi có hàm hạ cấp: bỏ màu da, chuỗi ZWJ thì lấy emoji đầu, custom
  emoji thì dùng ký tự thay thế. Về sau có thể kèm bộ ảnh PNG cho các emoji phổ biến bị thiếu.
- Giờ / ngày: `NSDateFormatter` tạo một lần rồi dùng lại (tạo mới rất tốn trên A4).

### 7.3 Tương thích iOS 5 (chép từ Côn Bằng TV, đổi tiền tố `CB` → `GM`)

`GMCompat.m` (subscripting, `NSIndexPath.item`, `minimumScaleFactor`, xoay màn iOS 5, giữ view khi thiếu bộ nhớ), `GMShims.c`,
`GMImages` (ImageIO thu nhỏ đúng cỡ hiển thị, hàng giải mã tuần tự, bộ đệm 8 MB trên máy < 300 MB RAM), `GMTheme`, và
`GMDebug` + `GMTouch` (lệnh thử qua tệp trong Documents, chạm giả).

---

## 8. Media: định dạng nào, làm thế nào

| Loại | Telegram gửi | iOS 5 / 6 | Cách làm |
| --- | --- | --- | --- |
| Ảnh | JPEG nhiều cỡ (`s`/`m`/`x`/`y`/`w`) + stripped thumb | đọc được | Ô tin lấy cỡ `m` (320); trình xem lấy `x` (800) / `y` (1280) theo màn hình. Ảnh mờ dựng tức thì từ stripped thumb. |
| Gửi ảnh | | | `UIImagePickerController` → thu về ≤ 1280 px, JPEG 0,8 → lõi gửi từng phần 512 KB (`upload.saveFilePart`) → `sendMedia` |
| Video, GIF (MP4 H.264) | MP4 | AVPlayer phát được (A4 tới 720p, A5 / A6 tới 1080p) | **Cổng phát nội bộ** của lõi: Range → `upload.getFile` (offset chia hết cho 4 KB, limit ≤ 1 MB, không vượt ranh giới 1 MB), lưu đệm phần đã tải xuống đĩa. Không bật `cdn_supported`, để server không chuyển sang CDN. GIF: lặp, không tiếng, mỗi lúc chỉ tự phát một cái. |
| Video HEVC / VP9 | ít gặp | không phát được | Báo «Máy không phát được định dạng này», cho tải về |
| Tin thoại | OGG / Opus | **không đọc được** | Lõi giải mã Opus (libopus) → WAV trong bộ đệm → `AVAudioPlayer`. Dạng sóng lấy từ thuộc tính của tệp. |
| Gửi tin thoại | | | `AVAudioRecorder` PCM 16 kHz mono → lõi mã hoá Opus, đóng gói OGG, tính dạng sóng → gửi dạng voice |
| Video tròn | MP4 H.264 | phát được | `AVPlayerLayer` cắt tròn |
| Nhạc | mp3 / m4a (đôi khi ogg / flac) | mp3 / m4a phát được | AVPlayer qua cổng phát nội bộ; các định dạng khác chỉ cho tải |
| Tệp | bất kỳ | | Tải về → `QLPreviewController` (pdf, doc, xls…) |
| Sticker tĩnh | WebP | **không đọc được** | libwebp (vendor như Côn Bằng TV) |
| Sticker động | TGS (Lottie) | — | Giai đoạn đầu: hiện ảnh thu nhỏ WebP tĩnh kèm theo. Về sau thử rlottie, vẽ fps thấp và lưu đệm khung. |
| Sticker video | WebM VP9 | — | Hiện ảnh thu nhỏ |
| Xem trước link | webpage | | tiêu đề, mô tả, ảnh |
| Vị trí | geo | | toạ độ + mở bản đồ bằng URL `maps.google.com/?q=` (iOS 5: Google Maps, iOS 6: Apple Maps) |
| Bình chọn, danh bạ, nút bot | | | hiện và bấm được (`sendVote`, `getBotCallbackAnswer`); nút URL thì mở Safari |
| Reaction | | | chỉ hiện số đếm (giai đoạn đầu) |

---

## 9. Thông báo khi app ở nền

iOS 5 / 6 chưa có background fetch. Push của Telegram lại đi qua chứng chỉ APNs của app chính thức, nên app tự dựng không nhận
được. Có ba mức:

1. **Mức 1 (chắc chắn làm được)**: còn kết nối khi app đang mở. Khi xuống nền, `beginBackgroundTask` giữ kết nối thêm ~10 phút,
   và tin mới hiện thành `UILocalNotification` + số trên biểu tượng.
2. **Mức 2 (spike S5)**: chế độ nền `voip`. Bọc socket MTProto của lõi bằng `CFStreamCreatePairWithSocket` và đặt
   `kCFStreamNetworkServiceTypeVoIP`; iOS sẽ đánh thức app khi có dữ liệu về. `setKeepAliveTimeout:600` gửi ping định kỳ. Cần
   đo xem Telegram có đóng kết nối im lặng sớm hơn 10 phút không, và tốn pin bao nhiêu.
3. **Mức 3 (chỉ máy jailbreak, làm nếu Mức 2 không được)**: một LaunchDaemon chạy lõi không giao diện, kèm một tweak
   MobileSubstrate trong SpringBoard để hiện banner (giống `cbwake` của Côn Bằng TV). Chắc chắn nhất, nhưng phụ thuộc phần bên
   trong của từng bản iOS.

---

## 10. Bảo mật và điều khoản của Telegram

- **api_id / api_hash riêng**: anh tạo ở <https://my.telegram.org/apps>. Không dùng của app chính thức.
- Tên và biểu tượng **không giống Telegram**. Tên «GramMini» không chứa chữ Telegram, dùng được. Màn Giới thiệu ghi «ứng dụng
  không chính thức, dùng Telegram API».
- **Thử bằng tài khoản phụ** trước: Telegram đôi khi hạn chế lần đăng nhập mới từ client không chính thức. Khai đúng
  `device_model` / `system_version`, và tôn trọng `FLOOD_WAIT`.
- Tệp phiên 0600 và `NSFileProtectionComplete` (có từ iOS 4, có tác dụng khi máy đặt mã khoá). Có tuỳ chọn khoá app bằng mã.
  Đăng xuất thì gọi `auth.logOut` rồi xoá tệp phiên.
- Bản phát hành **không ghi nội dung tin nhắn hay số điện thoại** vào log.
- Giấy phép: grammers là MIT / Apache, dùng thoải mái. **Không chép mã hay ảnh** từ Telegram-iOS / tdesktop (GPL), trừ khi
  GramMini cũng ra GPL. Với mpgram-web, chỉ tham khảo hành vi, không chép mã PHP.

---

## 11. Dựng, kiểm thử, phát hành

Chép từ Côn Bằng TV Legacy sang `tools/` (đổi tên cho GramMini):

| Việc | Công cụ |
| --- | --- |
| Bộ dựng | `setup-theos.sh` (Theos + clang 11 + ld64 + SDK 9.3 đã vá cho iOS 5 / 6), Rust nightly + `rust-src` |
| Dựng lõi | `tools/rust/armv7-apple-ios6.json`, `cargo-ios6.sh` (build-std), `vendor-ring.sh` (chỉ cần nếu lõi dùng rustls cho HTTPS, ví dụ kiểm bản mới trên GitHub), `build-core.sh` → `libgrammini_core.a` |
| Thư viện C | `vendor-libwebp.sh`, thêm `vendor-libopus.sh` (cùng kiểu) |
| Chặn API mới | `-Werror=unguarded-availability -Werror=partial-availability`, cùng danh sách API iOS 7+ mà SDK không ghi chú (TubeMini D24) |
| Tra ký hiệu | `symcheck` + `symlist.py` trên **cả máy iOS 5 và iOS 6** trước mỗi bản phát hành |
| Ký | `ldid -Hsha1` (nhân iOS 6 chỉ hiểu SHA-1) |
| Thử tự động | bản thử đọc lệnh từ `Documents/GramMini-cmd.txt` (`login`, `open <peer>`, `send <peer> <chữ>`, `shot`, `touch`, `drag`, `memwarn`…); chụp màn hình bằng `cbscreen`; mở / mở khoá máy bằng `cblaunch` |
| Thử lõi trên PC | `gm-cli` + unit test (entity, hạ cấp emoji, ánh xạ Range → getFile, Opus, ảnh mờ dựng sẵn) |
| Phát hành | `.deb` (`Depends: firmware (>= 5.0)`), OTA qua GitHub Releases + `gmupdate` setuid (như `cbupdate`), nguồn Cydia trên GitHub Pages |

---

## 12. Cấu trúc thư mục

```text
GramMini/
├─ core/                    # workspace Rust
│  ├─ crates/gm-core/  gm-net/  gm-media/  gm-ffi/  gm-cli/
│  ├─ vendor/               # grammers (ghim phiên bản), libopus, libwebp
│  └─ patches/              # bản vá cho mã đã vendor (grammers…)
├─ app/                     # app Theos
│  ├─ Makefile  control  main.m
│  ├─ Core/                 # GMCore (cầu FFI), GMCompat, GMShims.c, GMImages, GMAudio, GMUpdate, GMLog
│  ├─ UI/                   # GMLogin…, GMChatList…, GMChat…, GMMessageCell, GMTextLayout (CoreText), GMInputBar,
│  │                        # GMMediaViewer, GMSettings…, GMProxy…, GMTheme, GMCollectionView
│  ├─ Debug/                # GMDebug, GMTouch
│  ├─ Helper/gmupdate.c
│  └─ Resources/
├─ spike/                   # S1–S5 (mục 13)
├─ tools/                   # chép từ Côn Bằng TV + công cụ riêng
├─ docs/                    # THIET-KE.md (tệp này), FFI.md, DECISIONS.md, PROGRESS.md
└─ Tai_Lieu/
```

---

## 13. Lộ trình

### Giai đoạn 0 — Spike: quyết định làm tiếp hay đổi hướng

| # | Thử gì | Đạt khi |
| --- | --- | --- |
| **S1** | grammers dựng được cho `armv7-apple-ios6`, gắn vào một app Theos nhỏ | Trên iPad 1 (iOS 5.1.1) và iPhone 5 (iOS 6): tạo auth key, đăng nhập (mã + 2FA + QR), lấy 20 chat, gửi tin, nhận tin mới qua cập nhật. Ghi lại kích thước tệp chạy, RAM, thời gian tạo auth key trên A4. |
| **S2** | `gm-net`: obfuscated2, MTProxy (`dd` / `ee` fake-TLS), SOCKS5 — thử trước bằng `gm-cli` trên Windows, rồi trên máy iOS | Tạo được auth key và gọi được RPC qua từng đường: thẳng, MTProxy `dd`, MTProxy `ee`, SOCKS5 |
| **S3** | libopus trên A4: giải mã tin thoại 1 phút; ghi âm + mã hoá | Giải mã ≤ 1 giây; tin thoại gửi đi phát được trên Telegram điện thoại |
| **S4** | Cổng phát nội bộ + AVPlayer phát video 720p từ `upload.getFile` | Mở ≤ 3 giây, tua được |
| **S5** | Socket VoIP ở nền | Biết Mức 2 (mục 9) có làm được không |

S1 và S2 là bắt buộc: không đạt thì chuyển sang phương án B (mục 3). S3–S5 chỉ thay đổi phạm vi tính năng.

### Giai đoạn 1 — Nhắn tin chữ (MVP)

Đăng nhập (mã, 2FA, QR), Proxy, danh sách chat (bộ đệm + cập nhật trực tiếp), màn chat chữ có entity, gửi / nhận, trả lời,
sửa, xoá, đã đọc, đang gõ, hàng gửi khi mất mạng, ảnh đại diện. Chạy được trên cả 3 máy thử.

### Giai đoạn 2 — Media

Ảnh (xem, gửi), tệp + QuickLook, tin thoại (nghe, ghi), video / GIF / video tròn, sticker tĩnh và ảnh thu nhỏ của sticker
động, xem trước link.

### Giai đoạn 3 — Hoàn thiện

Tìm kiếm (trong chat, toàn cục), danh bạ, thông tin chat, Lưu trữ / thư mục, ghim, chuyển tiếp, bình chọn, nút bot, giao diện
tối, tiếng Anh, chia đôi màn hình trên iPad, tối ưu cho iPad 1.

### Giai đoạn 4 — Phát hành 1.0

Thông báo nền (Mức 1 + Mức 2 / 3 theo kết quả S5), khoá app bằng mã, OTA, nguồn Cydia, trang giới thiệu chạy được trên
Safari iOS 6.

### Sau 1.0

Sticker động (rlottie), nhiều tài khoản, chủ đề diễn đàn (forum topics), bình luận kênh, media đã chia sẻ, emoji bằng ảnh.
Đã làm: sticker động TGS + video WebM (D26, D27), chủ đề diễn đàn (D28), media đã chia sẻ.
Đã làm thêm (D31, D32): link t.me trong app, cảm xúc, nút / bàn phím bot, bình chọn, tin ghim, nhắc hẹn, vị trí (bản đồ qua Telegram), iPad chia
đôi, tin nhắn nhanh «/», VietQR, danh thiếp. Còn lại: nhiều tài khoản, bình luận kênh, tạo bình chọn, gọi điện.

---

## 14. Rủi ro

| Rủi ro | Giảm thế nào |
| --- | --- |
| grammers lỗi trên 32-bit / iOS 6, hoặc thiếu tính năng (MTProxy, cập nhật ổn định) | Vendor + `patches/`; S1 làm sớm; nếu cần thì tự viết lớp trên bằng các crate thấp hơn (`grammers-mtproto`, `tl-types`, `crypto`) |
| `grammers-tl-types` sinh rất nhiều mã: tệp chạy to, dựng lâu | LTO, `opt-level = "s"` riêng cho crate này, `codegen-units = 1`; đo ở S1 |
| Telegram bị chặn ở Việt Nam | Proxy là tính năng bắt buộc (S2) |
| Tài khoản bị hạn chế vì dùng client không chính thức | Dùng tài khoản phụ, api_id riêng, tôn trọng FLOOD_WAIT, không hỏi dồn |
| RAM 256 MB của iPad 1 | Giới hạn cửa sổ tin, bộ đệm ảnh 8 MB, bỏ ảnh của màn khuất khi phát video, đo bằng `cblaunch mem` |
| tokio không thức trên armv7 iOS 6 | Dùng lại vá nhịp 50 ms; thử `current_thread` |
| Định dạng media mới (HEVC, VP9, TGS, Opus) | Bảng ở mục 8; định dạng không làm được thì báo rõ và cho tải về |
| API iOS 7+ lọt vào bản dựng | `-Werror=unguarded-availability` + danh sách thủ công + `symcheck` trên máy iOS 5 |

---

## 15. Đã quyết (16/11/2026) và còn mở

Đã quyết (chi tiết ở [DECISIONS.md](DECISIONS.md)):

1. **Kiến trúc**: client dày, lõi Rust nói MTProto ngay trên máy, không server.
2. **Phân phối**: chỉ máy jailbreak: `.deb`, nguồn Cydia, cập nhật OTA như Côn Bằng TV / TubeMini.
3. **Bundle id**: `vn.grammini.app`.
4. **api_id / api_hash**: anh tạo ở my.telegram.org. Đặt trong `keys/telegram.txt` (không lên git); lúc dựng thì đóng vào tệp
   chạy, như `keys/nextdns.txt` của ChimToTV. Thử bằng tài khoản phụ.
5. **Mạng**: nhà mạng chặn lúc có lúc không → MTProxy (`dd` + `ee`) làm ngay ở S2.

Còn mở:

- **Ưu tiên tính năng** trong MVP (ví dụ tin thoại có cần ngay Giai đoạn 1 không).
- **Giấy phép**: đề xuất GPL-3.0 giống TubeMini / ChimToTV, vì dùng lại mã proxy của ChimToTV (GPL-3.0). grammers (MIT /
  Apache) dùng chung với GPL được.
- Tổ chức GitHub / trang giới thiệu / nguồn Cydia.
