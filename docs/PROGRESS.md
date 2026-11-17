# GramMini — Tiến độ

## 16/11/2026

- Thiết kế: [THIET-KE.md](THIET-KE.md); quyết định: [DECISIONS.md](DECISIONS.md) (D1–D6).
- `core/` (workspace Rust): `gm-net` + `gm-cli`; grammers 0.12, `grammers-mtsender` chép vào `vendor/` và vá (`patches/0001`).
- **`gm-net`** — đường ra mạng:
  - obfuscated2 ở mức luồng byte (`obfs.rs`), có secret MTProxy, số DC trong phần đầu;
  - fake-TLS (`faketls.rs`): ClientHello 517 byte giống Chrome (GREASE, SNI, key_share X25519 nằm trên đường cong),
    ký HMAC + giờ, kiểm ServerHello, dữ liệu trong bản ghi TLS ≤ 2878 byte;
  - transport intermediate có / không đệm (`transport.rs`) — thay bản của grammers bị panic khi gói cắt dở (D5);
  - SOCKS5 (`socks5.rs`, từ ChimToTV), đọc link `tg://proxy`, `t.me/proxy`, `tg://socks` (`link.rs`);
  - `GmConnector` cắm vào grammers (`connection_params`).
  - 15 phép thử đơn vị: đạt.
- **Thử thật trên PC (Windows, mạng VN, 16/11 ~09:30), đi thẳng + obfuscated2:** DC2, DC4, DC5 tạo được auth key
  (1,5–3,3 giây) và ping (78–280 ms) — `gm-cli probe --dc N`.

- **Lõi chạy trên iPhone 5 (iOS 6.1.4, 10B350)** — `spike/01-probe`: crate `gm-cli` dựng thành thư viện tĩnh armv7
  (`tools/rust/cargo-ios6.sh`, target `armv7-apple-ios6.json` của Côn Bằng TV) + `main.c` + `app/Core/GMShims.c`, ký
  `ldid -Hsha1`, chạy qua SSH:
  - dựng trên máy Ubuntu 1 phút 51 giây (lần đầu, có build-std); `libgm_cli.a` 2,4 MB, tệp chạy `gm-probe` 1,5 MB;
  - `cbsymcheck`: 73 ký hiệu (đều ở libSystem), **thiếu 0**;
  - đi thẳng + obfuscated2: DC2 / DC4 / DC5 tạo auth key 2,0–3,2 s, ping 78–400 ms; cả lần chạy (auth key + 3 ping)
    chỉ tốn **0,34 s CPU** — còn lại là chờ mạng.

- **MTProxy thật (proxy riêng của anh, secret `ee` fake-TLS, tên miền www.cloudflare.com):** PC và iPhone 5 đều tạo
  được auth key + ping qua DC2 / DC5. Trên iPhone: DNS 3 ms, TCP 2 ms, bắt tay fake-TLS 6–10 ms, auth key 2,1–3,7 s.
- **Lỗi tokio không thức trên iOS 6** (D8): lần đầu auth key qua MTProxy mất 10–12 s (chờ đúng bộ hẹn giờ 10 s), lệnh tra
  DNS không có hẹn giờ thì treo luôn. Thêm nhịp 50 ms (như ChimToTV) → hết.
- **api_id** của anh (my.telegram.org) — `keys/telegram.txt`, đóng vào tệp chạy lúc dựng (`gm-cli/build.rs`).
- **`gm-core`**: `FileSession` — phiên lưu ra tệp JSON (0600), bọc `MemorySession` của grammers (D10).
- **`gm-cli`**: thêm `login` (mã + 2FA), `me`, `dialogs`, `send <me|@user>`, `listen`. Thử với phiên trống trên PC và
  iPhone 5: Telegram nhận api_id, tạo auth key, báo «chưa đăng nhập» như mong đợi. Tệp chạy iOS 2,6 MB, 79 ký hiệu, thiếu 0.

- **iPad 1 (iOS 5.1.1, A4, 256 MB):** cùng tệp `gm-probe` (dựng cho iOS 5.0), 81 ký hiệu thiếu 0. Đi thẳng: auth key
  2,3–2,9 s, CPU 0,6–0,7 s. `me` với phiên trống: đúng. MTProxy fake-TLS lúc đầu **bị từ chối vì giờ iPad nhanh ~5–6 s**
  (D11) → `gm-net::clock` đo giờ qua NTP rồi ký bằng giờ đã chỉnh: qua, auth key 3,1 s, CPU 1,05 s.

- **Đăng nhập thật** (anh chạy `gm-cli login` trên PC, phiên ở `keys/gm-session.json`, chép lên máy thử 0600):
  - PC: `me` đúng, 6 chat trong 99 ms;
  - iPhone 5 / iPad 1: `me` 0,6–0,9 s cả lần chạy (đã có auth key, không phải tạo lại), `dialogs` 112–143 ms, gửi vào Tin
    nhắn đã lưu 102–139 ms; CPU 0,03–0,05 s;
  - nhận cập nhật: tin gửi từ máy dùng **cùng auth key** không được đẩy sang máy kia (cả PC lẫn iPhone) — Telegram không đẩy
    cập nhật về các kết nối khác của chính phiên đã gửi; `listen catchup` (getDifference) trên iPhone 5 lấy đủ 4 tin đã lỡ.
  - **Tin đẩy trực tiếp từ phiên khác: đạt** — anh gửi từ Telegram trên điện thoại, iPhone 5 đang `listen` in ra ngay
    (10:42:47). Tin gửi lúc iPhone không nghe thì `listen catchup` lấy bù được.

### Còn lại của S1 / S2

- [x] Thử MTProxy thật `ee` (fake-TLS) — PC + iPhone 5.
- [ ] MTProxy `dd` (chưa có proxy `dd` để thử).
- [ ] Thử SOCKS5 thật.
- [ ] Shadowsocks (chép `shadowsocks.rs` của ChimToTV) — khi cần.
- [x] Dựng `gm-net` + grammers cho `armv7-apple-ios6`, chạy `probe` trên iPhone 5.
- [x] iPad 1 (iOS 5.1.1): probe đi thẳng + MTProxy, `me`.
- [x] Đăng nhập (mã + 2FA trên PC), `me`, `dialogs`, `send me`, `listen catchup` trên iPhone 5 / iPad 1.
- [x] Tin đẩy trực tiếp từ phiên khác (điện thoại của anh) trên iPhone 5.
- [ ] Đăng nhập bằng mã QR.
- [x] Nguyên nhân gốc lỗi tokio không thức: mio dùng `EVFILT_USER` kiểu iOS 5 / 6 không hiểu → dựng với
  `--cfg mio_unsupported_force_waker_pipe`, bỏ nhịp 50 ms (D12, `spike/02-kqueue`).

## Giai đoạn 1 — app UIKit (bắt đầu 16/11/2026)

- **Lõi cho app:** `gm-core::Core` (`service.rs`, lệnh JSON + sự kiện), `gm-ffi` (`gm_init` / `gm_call`, thư viện tĩnh
  3,9 MB — chỉ `staticlib` để có LTO). Hợp đồng: [FFI.md](FFI.md). Thử trên PC bằng `gm-cli svc` (in kết quả đã che tên / chữ).
- **App** (`app/`, Theos, dựng cho iOS 5.0): `GMCore` (cầu JSON), `GMCompat` (bù iOS 5, từ Côn Bằng TV), màn Đăng nhập (số
  điện thoại → mã → mật khẩu 2 lớp, nút Proxy), Proxy (dán link, thử, lưu, đi thẳng), Danh sách chat (tin cuối, giờ, số chưa
  đọc, ghim; iOS 6 kéo để tải lại), Chat (bong bóng, tải thêm khi cuộn lên, gửi, tin mới / sửa / xoá trực tiếp, đánh dấu
  đã đọc), Cài đặt (tài khoản, proxy, đăng xuất). Bản thử có `GMDebug` (lệnh qua `/var/mobile/Documents/GramMini-cmd.txt`).
- Dựng: `tools/build-app.sh` (máy dựng); cài: `tools-local/deploy.sh <máy> [--session]`. `.deb` 1,4 MB, tệp chạy 3,0 MB,
  174 ký hiệu — thiếu 0 trên iOS 6.1.4 và iOS 5.1.1. Biểu tượng / ảnh khởi động tạm: `tools/make-images.py`.
- **iPhone 5:** mở lõi 8 ms, danh sách chat 141 ms, mở chat 219 ms, gửi tin 438 ms (chụp màn hình bằng `cbscreen`).
- **iPad 1:** mở lõi 99 ms, danh sách chat 136 ms, mở chat 143 ms.

### Còn lại của Giai đoạn 1

- [ ] Anh thử bằng tay: chạm, bàn phím, cuộn, đăng xuất → đăng nhập lại, đổi proxy trong app.
- [ ] Nhận tin trực tiếp trong app (cần tin từ phiên khác — điện thoại của anh).
- [ ] Tin hệ thống hiện rõ nội dung (vào nhóm, đổi tên…) thay cho «(tin hệ thống)».
- [ ] Chữ có định dạng (entity: đậm, nghiêng, link) — vẽ bằng CoreText.
- [ ] Ảnh đại diện; gửi khi mất mạng (hàng chờ); trạng thái kết nối trên thanh tiêu đề.

### Giao diện kiểu Telegram 4.9 (16/11/2026, anh chốt hướng — D14)

- Thanh tiêu đề phẳng (nền trắng, nút chữ xanh, mũi tên «‹» tự vẽ) — chạy cả iOS 5 / 6 bằng appearance proxy.
- Danh sách chat: ảnh đại diện tròn chữ cái (màu theo peer), tên, giờ (hôm nay / thứ / ngày), ✓ / ✓✓ cho tin cuối của
  mình (`read_out`), nhóm thì dòng 1 là người gửi, số chưa đọc (xám khi tắt tiếng), ghim, vạch kẻ thụt.
- Chat: bong bóng có đuôi tự vẽ (tin ra xanh lá nhạt, tin vào trắng), gom cụm theo người gửi (≤ 5 phút, đuôi ở tin cuối),
  giờ + ✓✓ nằm trong dòng cuối, tên người gửi màu trong nhóm, trích dẫn tin được trả lời, vạch ngày, tin hệ thống dạng
  viên thuốc (lõi dịch: «… đã vào nhóm», «… đã tham gia Telegram»…).
- Nhấn giữ: menu Trả lời / Sao chép / Sửa (tin của mình, ≤ 48 giờ) / Xoá; khung trả lời / sửa trên ô nhập.
- Lõi: `read_in` / `read_out` / `muted` trong danh sách chat, sự kiện `msg.readOutbox`, `messages.send` có `reply_to`,
  `messages.edit`, `messages.delete`, `from_id`, chữ tin hệ thống.
- Thử trên iPad mini 1 (iOS 6.1.3, nằm ngang): danh sách, chat, khung trả lời, menu — đạt. Sửa: ô nhập mất khi iPad nằm
  ngang (khung đặt lúc viewDidLoad) → đặt lại ở viewWillLayoutSubviews.
- Telegram 4.9.2 (gói anh gửi) cài trên iPad mini để đối chiếu — chỉ tới màn chào (không đăng nhập được nữa).

### Hoàn thiện Giai đoạn 1 — đợt 2 (16/11/2026)

- Chuyển tiếp: menu «Chuyển tiếp» → chọn chat (`GMPickChatViewController`) → `messages.forward`; tin chuyển tiếp hiện
  «Chuyển tiếp từ …» (tên lấy từ bộ nhớ tên peer của lõi; người gốc ẩn danh tính thì Telegram gửi sẵn tên).
- Ô nhập nhiều dòng (UITextView, tự giãn tới ~5 dòng, Return xuống dòng, gửi bằng nút «Gửi»).
- Trạng thái kết nối: lõi đẩy `net.state` khi đổi, mất kết nối thì 10 giây hỏi lại (`updates.getState`), app quay lại thì
  `net.check`; thanh tiêu đề hiện «Đang kết nối…» + vòng quay (`GMTitleView`).
- Cài đặt kiểu 4.9: đầu trang (ảnh, tên, số điện thoại, @tên), mục có biểu tượng ô vuông màu tự vẽ, Đăng xuất đỏ.
- Anh báo trên iPad mini → đã sửa: (1) mất nút Gửi / ô nhập quá khổ — thanh nhập tạo với khung rộng 0 nên co giãn tự động
  đẩy nút ra ngoài màn; (2) lẹm khung khi xoay máy — so bề ngang đã xếp thay vì bề ngang bảng (co giãn tự động đổi bảng
  trước); (3) sửa tin không đổi chữ → `MESSAGE_NOT_MODIFIED` — app bỏ qua, lõi coi là xong; (4) menu nhấn giữ còn nổi khi
  sang màn khác.

## Giai đoạn 2 — media (bắt đầu 16/11/2026)

- Lõi (`gm-core/src/media.rs`): `media.avatar` (ảnh đại diện nhỏ của peer — `InputPeerPhotoFileLocation` + DC của ảnh),
  `media.photo` (ảnh trong tin: cỡ vừa «m» cho bong bóng, cỡ lớn «y» cho trình xem). Tệp đệm ở `~/Library/GramMini/avatars`,
  `…/media`, tải qua tệp `.part` rồi đổi tên; tối đa 3 lượt tải cùng lúc. `PhotoSize` của grammers không mang DC → bọc
  `Loc { vị trí, DC }` (không thì ảnh ở DC khác tải lỗi). Danh sách chat / tài khoản có `photo` + `photo_dc`; tin có ảnh
  có `photo: {w, h, thumb}` (ảnh mờ thu nhỏ base64).
- App: `GMImages` (ImageIO thu nhỏ đúng cỡ, hàng nền ưu tiên thấp, bộ đệm 8 / 24 MB, gộp yêu cầu trùng), ảnh đại diện tròn
  trong danh sách chat / Cài đặt, bong bóng ảnh (đúng tỉ lệ, ảnh mờ trước, giờ đè lên ảnh khi không có chú thích),
  `GMPhotoViewController` (toàn màn, phóng to, chạm hai lần).
- Thử trên iPad mini: ảnh đại diện thật — DC chính ~140 ms, DC khác 3–4 s lần đầu (kết nối + chép quyền đăng nhập sang DC).
  252 ký hiệu, thiếu 0 trên iOS 6 và iOS 5. **Chưa thử bong bóng ảnh**: tài khoản thử chưa có tin ảnh nào.

### Sticker, tin thoại, gửi ảnh (16/11/2026 — anh giao iPhone 5 để em tự thử)

- **Sticker:** WebP → PNG bằng `image-webp` + `png` (Rust thuần, khỏi vendor libwebp); sticker động (TGS — grammers không
  đánh dấu là «động», nhận theo mime `application/x-tgsticker`) / video (WebM) → ảnh thu nhỏ. Hiện không bong bóng, giờ nằm
  trong viên thuốc. iPhone 5: sticker trong một chat thật hiện đúng (lần đầu 2,1 s — DC khác).
- **Tin thoại:** crate `gm-opus` = libopus 1.4 (bản phát hành xiph.org, SHA-256 khớp `SHA256SUMS.txt`, `core/vendor/opus-1.4`,
  dựng bằng `cc` — PC: MSVC, iOS: clang của Theos) + đọc / ghi OGG tự viết (CRC OGG). `media.voice`: OGG/Opus → WAV 24 kHz đơn
  kênh (AVAudioPlayer phát); `messages.sendVoice`: WAV ghi âm (16 kHz) → Opus 24 kbit/s, khung 20 ms + dạng sóng 100 điểm.
  Kiểm chéo với ffmpeg: đọc được tệp ffmpeg/libopus tạo (4,01 s, 9 ms trên PC); ffmpeg đọc được tệp của mình (Opus đơn kênh, 3,0 s).
- **App:** `GMVoicePlayer` (một tin một lúc, tiến độ 0,1 s), bong bóng tin thoại (nút ►/❚❚, dạng sóng tô theo tiến độ, thời
  gian), nút mic khi ô nhập trống (giữ để ghi — AVAudioRecorder PCM 16 kHz, thả để gửi, kéo ra ngoài để huỷ), nút đính kèm
  📎 (chụp / chọn ảnh; iPad: popover — iOS 5 / 6 bắt buộc), ảnh thu về ≤ 1280 px JPEG 0,8 → `messages.sendPhoto`.
- **Thử trên iPhone 5:** gửi ảnh 742 ms, tải ảnh vừa 369 ms, trình xem ảnh lớn 408 ms; gửi tin thoại từ WAV 578 ms; phát:
  tải + giải mã 432 ms; ghi âm bằng mic thật 3 s → gửi 850 ms (dạng sóng đúng tiếng ồn ghi được). 281 ký hiệu, thiếu 0 trên
  iOS 6 và iOS 5.

### Video, tệp (16/11/2026)

- Lõi: `media.document` (tải tệp gốc theo phần, sự kiện `media.progress`, có rồi thì trả ngay), `media.thumb` (ảnh xem trước
  của video / tệp), `messages.sendFile` (tên, mime, thuộc tính video). Tin có `doc` (tên, cỡ, mime, loại gif / round / video /
  audio / file, thời lượng, kích thước, ảnh mờ).
- App: `GMFiles` (nhớ tệp đã tải, tiến độ), bong bóng video (ảnh xem trước, ► hoặc %, thời lượng), bong bóng tệp (biểu tượng
  đuôi tệp, tên, «cỡ · chạm để tải / mở»). Video / GIF / âm thanh mở bằng `MPMoviePlayerViewController`, tệp khác bằng
  QuickLook (tiêu đề là tên thật của tệp; tệp chữ UTF-8 không BOM thì xem bản sao có BOM — QuickLook iOS 6 đọc nhầm Latin-1).
- iPhone 5: gửi video 1,4 s, tải 0,98 s, phát được; gửi tệp chữ 0,5 s, tải 0,38 s, QuickLook hiện đúng tiếng Việt.

### Bộ nhớ đệm (16/11/2026 — anh yêu cầu)

- Lõi `cache.rs` + lệnh `cache.stats` / `cache.clear` / `cache.set`, sự kiện `cache.cleared` (xem D15). 4 bài thử đơn vị
  (phân loại tên tệp, dọn theo LRU + hạn giữ, xoá theo loại / chat, đánh dấu vừa dùng).
- App: Cài đặt → «Dữ liệu và bộ nhớ» (`GMStorageViewController`): dung lượng theo loại (chạm để xoá riêng), tổng, máy còn
  trống; «Giữ media» (3 ngày / 1 tuần / 1 tháng / mãi mãi), «Giới hạn bộ nhớ đệm» (256 MB … 5 GB / không giới hạn);
  «Xoá bộ nhớ đệm»; theo chat (chạm để xoá media của chat đó).
- iPhone 5: thống kê 3–4 ms (19 tệp, 20,5 MB); đặt giới hạn 10 MB (lệnh thử) → tự dọn 15 tệp / 20,5 MB trong 3 ms, theo thứ
  tự lâu không dùng trước; bong bóng tệp về «chạm để tải», video tải lại 1,1 s và phát được; ảnh / ảnh đại diện tự tải lại.
  290 ký hiệu, thiếu 0 trên iOS 6.

### Gửi tệp từ bộ nhớ máy, video từ thư viện (16/11/2026 — anh yêu cầu)

- 📎 → «Chụp ảnh» / «Ảnh / video có sẵn» / «Tệp trên máy». Trình chọn tệp (D16), hỏi lại trước khi gửi; thanh «Đang gửi … %»
  dưới thanh điều hướng (sự kiện `upload.progress`); video thư viện nén rồi gửi (cũng có % lúc nén).
- iPhone 5 (qua MTProxy): tệp chữ tên tiếng Việt có dấu cách 0,46 s; tệp 12 MB 9,0 s (~1,4 MB/s, thanh tiến độ chạy đều);
  video 720p 8 Mbit/s 10 s: nén 9,7 MB → 1,5 MB (640×360) trong 2,8 s, gửi 2,7 s, mở lại phát ngay từ bộ đệm; video vốn nhẹ
  → gửi bản gốc. Tệp nén: H.264 Baseline + AAC-LC, moov trước mdat (ffprobe). 330 ký hiệu, thiếu 0 trên iOS 6.
- Chưa thử được bằng tay: bộ chọn ảnh / video của hệ thống (cần chạm màn hình thật) — đường nén / gửi phía sau đã thử bằng
  lệnh `sendvideo`.

### Tiếp tục theo thứ tự anh giao: 1 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 (16/11/2026)

- **1. Tin mới khi app ở nền** (D17, D18) — iPhone 5: lời nhắc hẹn giờ / tin thật → thông báo trên màn hình khoá, số chưa đọc;
  app đã treo vẫn được socket VoIP đánh thức; iOS tự mở app ở nền sau respring. Cài đặt → Thông báo (của app).
- **3. Trạng thái dưới tên chat** — «trực tuyến / vừa truy cập / truy cập lúc … / N thành viên, M trực tuyến / N người theo
  dõi», «đang gõ… / đang ghi âm…» (danh sách chat cũng hiện), mình gõ thì báo bên kia (≤ 5 s một lần). iPhone 5: thấy «vừa truy
  cập». Lõi thử trên PC: trạng thái mình, kênh 2.794.110 người theo dõi.
- **4. Tìm kiếm, danh bạ** — ô tìm ở đầu danh sách chat (chat đã có — không phân biệt dấu; trên Telegram; tin nhắn — chạm thì mở
  chat và nhảy tới tin, tô sáng), nút ✎ «Tin nhắn mới» (danh bạ + tìm). iPhone 5: tìm theo tên không dấu → đúng chat + kênh trên Telegram; tìm
  tin → nhảy đúng tin. PC: danh bạ 156 người, tìm 10 kết quả.
- **5. Màn thông tin chat** (chạm tên): ảnh, trạng thái, điện thoại / @tên / giới thiệu (chạm để chép), công tắc thông báo, đã chia
  sẻ (ảnh + video lưới 4 cột, tệp, tin thoại, liên kết), thành viên nhóm. PC: chat.info, messages.media (19 ảnh / video, 3 tệp,
  2 tin thoại). iPhone 5: màn thông tin «Tin nhắn đã lưu», lưới ảnh / video, danh sách tệp — đạt.
- **6. Thao tác nhanh ở danh sách chat**: nhấn giữ → ghim / tắt tiếng / đánh dấu đã đọc / xoá; vuốt trái → Xoá (hỏi lại).
  iPhone 5: bảng nhấn giữ, ghim / bỏ ghim «Tin nhắn đã lưu» — đạt.
- **7. Hàng chờ gửi khi mất mạng** (D19): PC — mất mạng → vào hàng chờ, có mạng → tự gửi, `outbox.sent`. **Chưa thử giao diện
  trên máy.** → iPhone 5 (giả mất mạng bằng `debug.offline`): tin hiện 🕓 ngay, vào hàng chờ, có mạng lại tự gửi — đạt.
- Anh góp ý: nút ✎ khó thấy (ảnh nút hệ thống iOS 5 / 6 bị tô trắng, lẫn vào thanh trắng phẳng) → nút tự vẽ màu chủ đạo
  (`UIButton` trong `UIBarButtonItem`), cả nút làm mới của iOS 5.
- Anh yêu cầu thêm chế độ tối (dark mode) — làm sau mục 11 (tô một lượt cho mọi màn).
- iPad 1 (iOS 5.1.1): 358 ký hiệu, thiếu 0; chưa thử giao diện (máy đang được dùng thử Côn Bằng TV).
- **8. Sticker, GIF** — nút mặt cười trong ô nhập mở bảng sticker ở chỗ bàn phím (Gần đây, GIF đã lưu, từng bộ đã cài; lưới
  tự vẽ — iOS 5 chưa có UICollectionView), chạm để gửi (`messages.sendDoc`); GIF trong chat tự chạy lặp trong bong bóng
  (AVPlayerLayer; GIF < 3 MB tự tải). iPhone 5: gửi sticker 0,23–0,4 s, gửi GIF 0,35 s, GIF chạy trong bong bóng — đạt. Sticker
  động (TGS — Lottie) vẫn hiện ảnh tĩnh: cần thư viện rlottie (C++) — để sau.
- **9. Khoá app bằng mật mã** — Cài đặt → Mật mã: bật (4 số, nhập 2 lần), đổi / tắt (cần mã cũ), tự khoá (ngay / 1 phút / 5 phút /
  1 giờ / 5 giờ). Màn khoá trên UIWindow riêng (xoay đúng iPad iOS 5 / 6, che cả màn bật lên), phủ ngay khi xuống nền (thanh đa
  nhiệm không lộ tin), sai 5 lần khoá 30 giây; lưu SHA-256 + muối (`passcode.plist`, 0600). iPhone 5: bật, tự khoá ngay, mở
  lại app → màn khoá, sai → rung «Sai mật mã», đúng → vào app, tắt — đạt (đã tắt sau khi thử).
- **10. Thiết lập tài khoản** — chạm phần đầu Cài đặt → Hồ sơ (ảnh: chụp / chọn, cắt vuông 640 px; tên, họ, giới thiệu ≤ 70 ký tự;
  @tên — kiểm tra còn trống; số điện thoại chỉ xem); «Quyền riêng tư và bảo mật» (lần truy cập, số điện thoại, ảnh đại diện,
  chuyển tiếp, cuộc gọi, thêm vào nhóm: Mọi người / Danh bạ / Không ai — đổi thì báo trước nếu bỏ ngoại lệ; Mật mã; Phiên đăng nhập
  — chạm để kết thúc); «Sửa tên liên hệ» trong thông tin chat (anh hỏi vì sao thông báo ghi tên khác — tên lưu trong danh
  bạ). iPhone 5: các màn hiện đúng dữ liệu (chỉ xem — không đổi hồ sơ / quyền / phiên của anh khi thử). PC: account.get, 3 phiên,
  quyền riêng tư, kiểm tra @tên.
- **Tạo nhóm** (anh hỏi) — «Tin nhắn mới» → «Nhóm mới»: chọn người (ô tìm lọc ngay, ✓), «Tiếp (n)», đặt tên → nhóm thường
  (`messages.createChat`) → mở chat nhóm. iPhone 5: tạo «GramMini thử nhóm» với tài khoản phụ của anh → chat nhóm «2 thành viên»,
  tin «… đã tạo nhóm…» — đạt; đã xoá nhóm thử (`groups.delete`).
- **Dark mode** (anh yêu cầu) — Cài đặt → Giao diện: Sáng / Tối / Tự động (tối 19:00–6:00, đổi khi quay lại app). Bảng màu đêm kiểu
  Telegram (nền 0x18222D, chat 0x0E1621, bong bóng ra 0x2B5278), thanh trên / thanh tìm / thanh trạng thái tối, bàn phím tối.
  iPhone 5: Cài đặt, danh sách chat, chat (bong bóng chữ, GIF, sticker), bảng sticker, màn thông tin — đạt. Lỗi gặp khi thử: ô kiểu
  Default không có `detailTextLabel` (nil) → cho vào mảng là crash — đã sửa.
- **11. iPad 1 (iOS 5.1.1, RAM 247 MB)** — 374 ký hiệu, thiếu 0. Khổ ngang: danh sách chat (nút soạn + làm mới của iOS 5), chat +
  bảng sticker, thông tin, Cài đặt, tìm kiếm, trình chọn tệp (khung giữa màn), chế độ tối — đạt. GIF: trình phát chạy và lặp
  (3,08 s → 2,00 s → 3,94 s) — ảnh chụp màn của iOS 5 không bắt được lớp video nên trông như đứng. Lỗi đã sửa: màn khoá mật mã bị
  xoay sai khi iPad nằm ngang (iOS 5 không xoay cửa sổ phụ hiện lúc máy đã ngang → tự xoay theo thanh trạng thái). Thông báo:
  GMNotify móc đủ 3 hàm trên SpringBoard iOS 5, app đăng ký được; quyền thông báo trên iPad 1 đang tắt (hộp hỏi đã hiện, chưa cho
  phép) — bật trong Cài đặt → Thông báo → GramMini.

### Giao diện iOS 6 + kính trong (16/11/2026 — anh duyệt bản mẫu, D23)

- Bản mẫu 4 màn (danh sách chat, chat, Cài đặt, chat tối) → anh duyệt. Làm: hình nền loang màu + vân chéo; thanh trên kính bóng,
  nút viền nổi, nút quay lại hình mũi tên, tiêu đề chữ nổi; **thanh dưới** Danh bạ / Chat / Cài đặt (kính khói, huy hiệu chưa đọc
  ở mục Chat); danh sách chat thành thẻ kính (ảnh đại diện chữ cái có vệt bóng, số chưa đọc viên bóng viền trắng, nút «Sửa»);
  Cài đặt sọc dọc iOS 6 + ô kính, biểu tượng ô vuông bóng; màn chat: nền chung, ảnh đại diện bên phải thanh trên, bong bóng bóng
  kính, ô nhập kính + ô lõm, nút «Gửi» xanh bóng, khung trả lời kính, bảng sticker kính; chế độ tối = kính khói.
- iPhone 5 (iOS 6.1.4): sáng + tối — danh sách chat, chế độ Sửa, chat (tin ra / vào, tệp, tin thoại, GIF, sticker, trả lời), bảng
  sticker, thông tin chat, Danh bạ + tìm, tìm trong danh sách chat, Cài đặt và các màn con — đạt. Lỗi gặp khi thử: đổi giao diện
  lúc đang ở mục Cài đặt → danh sách chat trống (tải xong trước khi màn được dựng) — đã sửa.
- iPad 1 (iOS 5.1.1): sáng + tối — danh sách chat, chat, Danh bạ, Cài đặt — đạt. Hình nền 1024 × 1024 vẽ 0,57 s → lưu JPEG.
- iPad mini 1 (iOS 6.1.3): đã cài; đang chờ anh bấm hộp «GramMini muốn gửi thông báo Push» rồi mới thử tiếp.

### Phát hành 1.0.0 (16/11/2026 — anh chốt: 1.0 ngay, TGS ở 1.1; repo itovn/GramMini công khai GPL-3.0; OTA + tự respring)

- **OTA**: lõi có HTTPS (reqwest + rustls + bộ gốc Mozilla; ring vá cho armv7 Apple như Côn Bằng TV), app đọc GitHub Releases
  (`GMUpdateURL`), tải qua lõi (sự kiện `http.progress`), kiểm kích thước + SHA-256, gọi `/usr/libexec/grammini/gmupdate` (setuid
  root): dpkg -i → **luôn** khởi động lại SpringBoard → mở lại app. iPad mini: 0.1.0 → 0.1.1 qua nguồn thử trong LAN — tải 0,6 s,
  respring, app mở lại sau 14 s. iPad 1 (iOS 5): đọc GitHub thật qua rustls → «bản mới nhất 1.0.0».
- Bản 1.0.0 (`tools/build-release.sh`, không có Debug/): 410 ký hiệu, thiếu 0 trên iOS 5 và iOS 6; cài thử iPad 1 — chạy.
- Repo công khai **itovn/GramMini**: ảnh chụp mã sạch (không lịch sử, bỏ `Tai_Lieu/`, đã bỏ tên chat / danh bạ riêng khỏi
  tài liệu), LICENSE GPL-3.0, README; Release v1.0.0 kèm .deb (GitHub ghi digest SHA-256).
- Trang giới thiệu + nguồn Cydia (`E:\DEV_CODE\GramMini-site`, `tools/update-cydia-repo.sh`): kiểu iOS 6 (thanh trên bóng,
  nền sọc, bảng nhóm, nút bóng), ảnh minh hoạ vẽ lại từ bản mẫu (dữ liệu mẫu — ảnh chụp thật có tên chat của anh / nút
  AssistiveTouch); thử trên Safari iPhone 5 (iOS 6) và iPad 1 (iOS 5) — hiện đúng. Anh chọn đặt trang ở nhánh gh-pages của
  itovn/GramMini: https://itovn.github.io/GramMini/ (nguồn Cydia …/cydia/).
- App: Cài đặt → «Nhóm Telegram GramMini» (t.me/tivikit, mở ngay trong app), chú thích mã nguồn mở; chạm «Phiên bản» = kiểm bản mới.

### Bản 1.1.0 — sticker động TGS (16/11/2026 — anh giao: tự kiểm, tự phát hành, thử trên iPhone 5)

- Crate `gm-lottie` (D26) + `GMLottieView`: sticker động trong chat chạy thật (thay ảnh tĩnh). iPhone 5: gửi «Hot Cherry» vào Tin
  nhắn đã lưu → chạy mượt, 15,4 ms / khung 256 px, 5 lượt rồi dừng. Hai lỗi gặp khi thử đã sửa: thiếu `__sincosf_stret` trên
  iOS 6 (crash), tệp TGS bị ghi đè bởi ảnh tĩnh (trùng tệp tạm).
- Sticker video (WebM) chưa chạy (hiện ảnh tĩnh) — iOS 5 / 6 không giải mã VP9.

### Bản 1.2.0 — sticker video, xoá cho cả hai bên, tin tự xoá (16/11/2026 — anh giao: tự kiểm, tự phát hành)

- Xoá tin «cho cả hai bên» / «chỉ ở máy tôi», xoá chat riêng cho cả hai bên, tin tự xoá theo chat + mặc định (D27). iPhone 5: xoá
  hai tin thử trong Tin nhắn đã lưu (cả hai đường revoke) — đạt; bảng chọn, dòng «Tự xoá tin nhắn» ở thông tin chat / kênh và
  Quyền riêng tư hiện đúng; đọc mức mặc định được. Chưa đặt tự xoá ở chat thật (sẽ hiện thông báo cho người khác).
- Sticker video WebM (D27): crate `gm-webm` + libvpx NEON. iPhone 5: sticker video thật trong Tin nhắn đã lưu chạy 13,6 ms / khung;
  iPad 1 (iOS 5): 19 ms / khung. Tin thử đã xoá.

### Bản 1.2.1 — sửa giờ đè lên tin tệp (17/11/2026)

- Tin tệp không chú thích: giờ (+ dấu đã đọc) đè lên dòng «cỡ · chạm để mở» trên iPhone (bong bóng tệp 220 điểm không đủ chỗ
  cho cả hai trên một hàng) → giờ xuống dòng riêng dưới dòng đó (bong bóng cao thêm 10 điểm). iPhone 5: kiểm trên tin tệp có sẵn
  trong Tin nhắn đã lưu — đạt.

### Sau 1.2.1 — chủ đề diễn đàn, video H.265 (17/11/2026)

- Nhóm có chủ đề (D28): danh sách chủ đề, màn từng chủ đề, «Tất cả»; bỏ trích dẫn giả «Tin nhắn …» ở tin trong chủ đề; tin
  sửa chủ đề. iPhone 5 (nhóm anh cho phép, chỉ xem, không đánh dấu đã đọc): 17 chủ đề tải 280–560 ms, chủ đề 20 tin 167 ms,
  General 126 ms — đạt. Chưa gửi tin vào chủ đề trên tài khoản chính.
- Video H.265 (D29): có bản H.264 Telegram đã chuyển thì phát bản đó; không có thì báo chỉ phát được tiếng. Video anh gặp:
  không có bản H.264 → app báo.

### Bản 1.3.0 — chủ đề diễn đàn, video H.265 có hình (17/11/2026)

- Video H.265 không có bản H.264 trên máy chủ (D30): chuyển sang H.264 trên máy bằng FFmpeg (NEON) + bộ mã H.264 phần cứng.
  iPhone 5: video 1080 × 1920, 200 giây (video anh gặp ở một nhóm của anh) chuyển trong 222 giây (27 khung / giây), tệp ra
  H.264 + AAC 480 × 854; iPad 1: 1019 giây → bật bỏ khung không làm tham chiếu (máy một nhân) 537 giây, video ra ~15 khung / giây,
  phát có hình. Ký hiệu iOS 5 / iOS 6: 485, thiếu 0.

### Bản 1.4.0 — 11 tính năng: link t.me, cảm xúc, bot, bình chọn, ghim, nhắc hẹn, vị trí, iPad chia đôi, «/», VietQR, danh thiếp (17/11/2026)

Anh hỏi còn thiếu gì cấp thiết (tham khảo Roza), chọn làm lần lượt 11 mục rồi cho phát hành (D31, D32). Lõi: 9 mô-đun mới trong
`gm-core/src/service/` (links, react, bots, poll, pins, sched, geo, vietqr, contact), 6 phép thử mới (đọc link t.me, hex dữ liệu
nút bot, VietQR: CRC / cấu trúc mã / ma trận / bỏ dấu) — `cargo test -p gm-core`: 14 / 14.

| # | Tính năng | Đã thử (iPad 1, iOS 5.1.1, bản debug) | Chưa thử |
| --- | --- | --- | --- |
| 1 | Link t.me / @tên mở trong app, tham gia nhóm / kênh, `tg://` từ Safari | t.me/<tên> (nhóm cộng đồng → danh sách chủ đề), kênh chưa theo dõi → thanh «Tham gia kênh», chạm @tên trong tin → chat bot, link mời sai mã → «Link mời đã hết hạn hoặc không đúng» | bấm «Tham gia» nhóm thật, link mời thật, `tg://` từ Safari |
| 2 | Cảm xúc | viên cảm xúc + số gọn (8,8K, 51K), emoji riêng ✨ / sao ⭐, bảng chọn 44 / 73 emoji iOS 5 vẽ được, kênh chỉ cho emoji riêng → không mở bảng | thả / gỡ thật |
| 3 | Nút / bàn phím bot | chat bot trống: thẻ «Bot này làm được gì?» + «Bắt đầu» | bấm nút callback, bàn phím bot, «Bắt đầu» |
| 4 | Bình chọn | — (không có bình chọn ở chat xem được) | xem, bỏ / rút phiếu |
| 5 | Tin ghim | thanh «Tin đã ghim» ở nhóm cộng đồng, chạm → nhảy tới tin | ghim / bỏ ghim |
| 6 | Nhắc hẹn / hẹn giờ gửi | Tin nhắn đã lưu: «Nhắc tôi» → «Sau 1 giờ» → thanh «🕓 1 lời nhắc» → danh sách «Nhắc lúc 20:25 hôm nay» → huỷ (không để lại tin) | gửi không âm báo, chọn ngày giờ, lời nhắc tới giờ |
| 7 | Vị trí (OSM) | màn bản đồ (15 ô, ~1,3 giây), địa chỉ tiếng Việt | bản đồ nhỏ trong bong bóng, gửi vị trí, định vị máy |
| 8 | iPad chia đôi | iOS 5: «Chọn một cuộc trò chuyện», chat bên phải, mở từ link / Tin nhắn đã lưu | chiều ngang, đổi sáng / tối khi đang mở chat |
| 9 | Tin nhắn nhanh «/» | gõ «/ch» → gợi ý «/chao» → chữ mẫu vào ô nhập (đã xoá mẫu thử) | gợi ý lệnh bot |
| 10 | VietQR | thẻ QR (ngân hàng, STK, chủ TK, số tiền, nội dung bỏ dấu); mã BIN đối chiếu api.vietqr.io | gửi ảnh QR, quét bằng app ngân hàng |
| 11 | Danh thiếp | — | thẻ danh thiếp trong bong bóng, gửi danh thiếp |

- Thử trên iPad 1 chỉ xem chat / kênh công khai, gửi chỉ trong Tin nhắn đã lưu (tài khoản trên iPad 1 khác máy chính — không có
  chat anh chỉ định để thử gửi). Máy chính (iPhone 5) anh đang dùng suốt lúc thử → chưa thử gửi thật; anh cho phát hành trước.
- Bản phát hành 1.4.0: 4 053 136 byte, SHA-256 `f325b959d2a21d28e90cf5981e2482554988d07478dc8821fc32eb5494cf8ae7`; ký hiệu iOS 5
  (iPad 1) / iOS 6 (iPad mini 1): 501, thiếu 0; cài lên iPad 1 khởi động được (ở nền, VoIP). Chưa mở được ở màn trước và chưa
  thử OTA 1.3.x → 1.4.0: cả hai iPad đang có app khác (GramMusic của phiên khác) ở trước.
- Đã phát hành: GitHub Release v1.4.0 (bản mới nhất — OTA), nguồn Cydia (1.2.1 / 1.3.0 / 1.4.0, mô tả không dấu), trang mô tả,
  trang giới thiệu, repo công khai 4d5ac33 (thẻ v1.4.0 trỏ vào đây). Tải lại gói từ GitHub và nguồn Cydia: cùng SHA-256.
- `update-cydia-repo.sh` bỏ dấu cả `Packages` (iconv): các .deb cũ còn mô tả có dấu (Cydia 1.1.30 trên iOS 5 / 6 hiện «?» —
  e8cbc80), chạy lại script đã làm mô tả cũ có dấu trở lại.
- Công cụ: `tools-local/ios.sh` khớp đúng cả tên máy (anh thêm «iPhone 5 - đen», đổi máy chính thành «- trắng» — tên cũ khớp
  nhầm phần đầu → trỏ sai máy).

#### Việc tiếp theo

1. Anh cập nhật máy chính lên 1.4.0 (app tự hỏi) rồi dùng thử các mục «Chưa thử» ở bảng trên; hoặc cho em thử gửi trong chat anh
   chỉ định khi máy rảnh (tin thử xoá cho cả hai bên sau đó).
2. Thử OTA 1.3.x → 1.4.0 và bản phát hành ở màn trước khi một iPad rảnh.
3. Còn lại sau 1.4.0: màn tạo bình chọn (lõi đã có `messages.sendPoll`), bình luận kênh, nhiều tài khoản.

### Bản 1.4.1 — nút «Menu» của bot, sửa bảo mật (18/11/2026)

Anh báo chat với bot không bật được menu như Telegram mới, rồi nhờ kiểm tra bảo mật, sửa và phát hành chung (D33).

- Menu bot — thử trên iPhone 5 (bản thử, chat bot điều khiển TV của anh, chỉ xem, không gửi, không đánh dấu đã đọc): nút
  «Menu» → 9 lệnh của bot; bàn phím bot «luôn hiện» tự bật khi mở chat; chữ gợi ý của bot trong ô nhập; nút có emoji iOS 6
  thiếu không còn ô vuông; đang gõ thì «Menu» thu thành nút tròn. `bots.keyboard` tìm đúng tin có bàn phím (gọi tay). Mini app:
  chưa có bot nào để thử.
- Kiểm tra bảo mật: 26 lỗi (1 nghiêm trọng — `gmupdate` cài được gói tuỳ ý bằng root; 4 cao; 10 trung bình; 11 thấp), sửa 24,
  còn: ký nguồn Cydia (chưa làm), link mini app nằm trong lịch sử Safari (chỉ hỏi trước). Chi tiết: `vbsec-reports/` (máy anh).
- Chữ ký OTA thử trên máy thật bằng `gmupdate --verify` (root, không cài): iPad 1 iOS 5.1.1 và iPhone 5 iOS 6 — gói ký đúng →
  qua; chữ ký ngẫu nhiên / gói sửa 1 byte → mã 72.
- `cargo test`: gm-core 14 / 14, gm-lottie 3 (thêm `hostile_files`), gm-webm 3 (thêm `hostile_header_no_panic`), gm-opus 2,
  gm-hevc 4.
- Phát hành 1.4.1: ký hiệu iOS 5 (iPad 1) / iOS 6 (iPhone 5): 548 (gồm `gmupdate`), thiếu 0; cài gói phát hành lên iPad 1 khởi
  động được (ở nền — GramMusic của phiên khác đang ở trước). Gói ký bằng `tools/sign-release.sh`, `.sig` đính kèm Release.
- Đã phát hành: GitHub Release v1.4.1 (bản mới nhất — OTA; gói 4 076 374 byte, SHA-256 `cea1888b19af267e00619c8851fe6027`
  `0783f55b10f60774907d80b19462dc75`, kèm `.deb.sig`), nguồn Cydia (1.3.0 / 1.4.0 / 1.4.1, mô tả không dấu), trang mô tả, trang
  giới thiệu, repo công khai 2f31fc8 (thẻ v1.4.1). Tải lại từ GitHub và nguồn Cydia: cùng SHA-256; chữ ký tải về kiểm đúng.
- Máy đang chạy 1.4.0 lên 1.4.1 qua `gmupdate` cũ (chưa cần chữ ký) — từ 1.4.1 lên các bản sau mới dùng `gmupdate` mới.

#### Việc tiếp theo

1. ~~Thử trọn luồng OTA với `gmupdate` mới~~ — đạt ở bản 1.4.2 (xem dưới).
2. Thử trên máy các phần sửa giao diện chưa thử: hỏi trước khi mở link lạ / link ẩn, khoá mật mã + link `tg://`, màn proxy.
3. Sao lưu `keys/ota-sign.key` ra ngoài máy (mất khoá → máy chạy 1.4.1 phải cập nhật qua Cydia một lần).

### Bản 1.4.2 — ký nguồn Cydia, mini app mở trong app (18/11/2026)

Anh nhờ làm nốt hai lỗi thấp còn lại của lần kiểm tra bảo mật (D33).

- Nguồn Cydia ký GPG (`tools/sign-cydia-repo.sh`, khoá trong `keys/cydia-gnupg`); gói cài khoá công khai vào
  `/etc/apt/trusted.gpg.d/vn.grammini.gpg`. Thử trên iPhone 5 (apt 0.7.25.3, gpgv 1.4.9, danh sách riêng trong /tmp — không đụng
  dữ liệu Cydia): có khoá → nhận chữ ký; `Release` sửa một chữ → `BADSIG`; chưa có khoá → `NO_PUBKEY` (cảnh báo, vẫn làm mới
  được). Bản thử cài lên iPhone 5: khoá có trong `trusted.gpg.d`.
- Mini app: màn trong app (UIWebView) thay Safari. Thử trên iPhone 5 bằng lệnh thử `webapp <link>` với trang giới thiệu
  GramMini (không qua bot): trang hiện đúng, «Đóng» / tải lại chạy. Chưa thử với mini app thật của bot (cần anh cho bấm nút
  bot — tài khoản chính).
- Đã phát hành: GitHub Release v1.4.2 (gói 4 081 048 byte, SHA-256 `4f4ec90f08bba70d3735cd9ccdd3deedd93259759dbd147143ad33647e267c02`
  + `.deb.sig`), nguồn Cydia đã ký (1.4.0 / 1.4.1 / 1.4.2 + `Release.gpg`, `InRelease`, `vn.grammini.gpg`), trang mô tả, trang
  giới thiệu, repo công khai aaa9ce9 (thẻ v1.4.2). Ký hiệu iOS 5 / iOS 6: 551, thiếu 0. Tải lại: GitHub = Cydia (cùng SHA-256),
  chữ ký OTA đúng, `gpgv` kiểm `Release.gpg` trên trang đúng.
- **OTA trọn vẹn với `gmupdate` mới — đạt** (iPhone 5, iOS 6.1.4: bản thử 1.4.1 → 1.4.2): `updatecheck` → «Có bản mới 1.4.2» →
  «Cập nhật» → tải gói + chữ ký 9 giây → `gmupdate → 0` → `dpkg -i` bản chép trong /var/root → 0 → respring → app tự mở lại
  1.4.2; thư mục tải của mobile được app dọn. Máy chính giờ chạy bản phát hành 1.4.2.

### Bản 1.4.3 — ảnh bản đồ lấy qua Telegram (18/11/2026)

Anh bảo sửa nốt phần bản đồ tin vị trí tải thẳng từ OpenStreetMap (D33 để ngỏ) — D34.

- Lõi: `map.static` (`upload.getWebFile` + `inputWebFileGeoPointLocation`, DC web 4 — chép quyền đăng nhập sang), bỏ `map.tile`;
  `msg.geo.hash`. App: bong bóng tin vị trí = một ảnh Telegram vẽ (access_hash của tin); màn bản đồ / chọn vị trí = một ảnh vừa
  khung mỗi lần dừng tay; tra địa chỉ chỉ khi chạm; chữ «Bản đồ qua Telegram».
- Thử trên iPad 1 (iOS 5.1.1, bản thử): ô 256 ghép khít (cả Retina scale 2) nhưng Telegram giới hạn tốc độ (12 ô dồn → 10 ô chờ
  15–30 giây / `RPC_CALL_FAIL`) → đổi sang một ảnh: mở / phóng to / phóng nhỏ / kéo mỗi lần 1,1–2,4 giây; kéo dở thì ảnh cũ trượt
  theo, thả tay → ảnh mới. Tin vị trí thử trong Tin nhắn đã lưu: bong bóng hiện ảnh Telegram vẽ, ghim đúng chỗ (rồi xoá tin).
  Tra địa chỉ khi chạm: «Phố Đinh Tiên Hoàng, Tràng Tiền» (đúng). Màn chọn vị trí để gửi chưa thử trên máy (iOS sẽ hỏi quyền định
  vị — em không bấm hộp xin quyền); dùng chung khung bản đồ với màn xem.
- Lỗi phụ tìm thấy khi thử: ảnh bản đồ treo làm lõi báo mất mạng; tiêu đề chat kẹt «đang kết nối…» (thứ tự sự kiện / câu trả lời
  của `net.state`) — đã sửa.
- Sự cố khi thử: lệnh thử `delmsg` đếm từ 0 — «delmsg 1» xoá nhầm tin thứ hai từ dưới lên trong Tin nhắn đã lưu của iPad 1: ảnh
  thử `gm-test.jpg` (logo GramMini) em gửi lúc thử gửi ảnh 16/11 19:09 (cùng ảnh, cùng giờ — không phải tin của anh). Rồi
  «delmsg 0» xoá tin vị trí thử.

