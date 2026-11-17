# GramMini — Các quyết định kỹ thuật

Thiết kế đầy đủ: [THIET-KE.md](THIET-KE.md).

## D1. Client dày: lõi Rust nói MTProto ngay trên máy — 16/11/2026

- Anh chốt. Không có server; phiên đăng nhập chỉ nằm trên máy.
- MTProto chạy trên TCP và tự mã hoá, không dùng TLS của iOS 6 (iOS 6 không vào được `t.me` / `telegram.org` bằng
  NSURLConnection — lỗi SSL -1200, TubeMini D33).
- Thư viện MTProto: grammers (MIT / Apache-2.0), ghim phiên bản, chép vào `core/vendor/` (GitHub của grammers đã lưu trữ
  10/02/2026, mã chuyển sang Codeberg).

## D2. Chỉ máy jailbreak — 16/11/2026

- Anh chốt. Gói `.deb`, nguồn Cydia, cập nhật OTA bằng công cụ setuid (như `cbupdate` của Côn Bằng TV, `tmupdate` của TubeMini).
- Bundle id: `vn.grammini.app`.

## D3. api_id riêng — 16/11/2026

- Anh tạo ở my.telegram.org. Đặt ở `keys/telegram.txt` (không lên git), đóng vào tệp chạy lúc dựng.
- Thử bằng tài khoản phụ trước.

## D4. MTProxy làm ngay từ đầu — 16/11/2026

- Anh: nhà mạng ở VN chặn Telegram lúc có lúc không → làm MTProxy luôn, không đợi spike.
- `gm-net` làm cả ba kiểu secret: thường, `dd` (intermediate có đệm), `ee` (fake-TLS). Đi thẳng tới DC cũng bọc obfuscated2.
- SOCKS5 và Shadowsocks chép từ lõi chung ChimToTV (`linux/core/src/net.rs`, `shadowsocks.rs`).

## D5. Vá grammers-mtsender để lõi tự mở kết nối; tự viết transport intermediate — 16/11/2026

- grammers 0.12 cho đổi transport (`ConnectionParams::transport`) nhưng luôn mở TCP thẳng tới địa chỉ DC, và hàm tạo
  transport không biết số DC. MTProxy cần cả hai (đích là máy chủ proxy; số DC nằm trong 64 byte đầu obfuscated2).
- Bản vá nhỏ (`core/patches/0001-grammers-mtsender-connector.patch`): thêm `ConnectionParams::connector` (trait `Connector`,
  nhận số DC + địa chỉ, trả luồng byte bất kỳ). Mọi thứ còn lại (obfuscated2, fake-TLS, SOCKS5) ở `crates/gm-net`, ở mức
  luồng byte: lớp vỏ lấy 4 byte thẻ đầu tiên mà transport ghi ra để đưa vào phần đầu obfuscated2.
- **Lỗi của grammers (0.12):** `Intermediate::unpack` kiểm `buffer.len() < len` thay vì `< len + 4` → khi một lần đọc dừng
  giữa 4 byte cuối của gói thì cắt lát ngoài bộ đệm → panic (trên iOS `panic = abort` là tắt app). `gm-net` tự viết
  transport intermediate (có đệm `dddddddd` cho MTProxy `dd` / `ee`, không đệm `eeeeeeee`), có phép thử cắt dở ở mọi vị trí.
- Đệm phía khách: 0–3 byte (MTProxy bỏ đệm bằng cách làm tròn xuống bội 4). Đệm máy chủ gửi (tới 15 byte) bỏ theo nội dung:
  gói mã hoá dài ≡ 8 (mod 16), gói chưa mã hoá ghi sẵn độ dài.

## D6. Đi thẳng tới DC cũng bọc obfuscated2 — 16/11/2026

- Như app chính thức: máy lọc gói không thấy dấu hiệu MTProto ở đầu luồng.
- Thử trên PC, mạng VN (16/11 ~09:30): DC2 / DC4 / DC5 tạo auth key 1,5–3,3 s, ping 78–280 ms. Lúc thử, đi thẳng không bị
  chặn; khi nhà mạng chặn thì dùng MTProxy.

## D7. Lõi Rust (grammers + gm-net) chạy trên iPhone 5 iOS 6.1.4 — 16/11/2026

- Thử bằng công cụ dòng lệnh trước khi làm app (`spike/01-probe`): ít thứ dính vào nhất, chạy và đọc kết quả qua SSH.
- Bộ dựng của Côn Bằng TV dùng lại nguyên: target `armv7-apple-ios6.json`, `-Z build-std`, shim (`app/Core/GMShims.c`, chép
  từ `CBShims.c`). Không cần vá ring (lõi không dùng rustls). Dựng cho iOS 5.0 nên cùng tệp chạy được iOS 5.
- Kết quả: thiếu 0 / 73 ký hiệu; auth key + ping qua obfuscated2 tới DC2 / DC4 / DC5 đạt; 0,34 s CPU cho cả lần chạy.
- Repo: https://github.com/Circling5714/GramMini (riêng tư; đổi công khai khi phát hành — OTA tải từ GitHub Releases).

## D8. tokio trên iOS 6 armv7: có lúc không thức — tạm dùng nhịp 50 ms — 16/11/2026

- Gặp lại đúng lỗi Côn Bằng TV đã ghi: việc xong ở luồng khác (ở đây: tra DNS tên MTProxy chạy ở `spawn_blocking`) không
  đánh thức runtime; runtime ngủ tới khi một bộ hẹn giờ khác hết hạn. Đo trên iPhone 5: auth key qua MTProxy 10,4–11,8 s
  (= hẹn giờ kết nối 10 s), lệnh tra DNS không có hẹn giờ thì treo mãi. PC không bị.
- Tạm: tác vụ nhịp 50 ms trên iOS (như ChimToTV `linux/ffi`), tắt được bằng `GM_NO_TICK=1`. Sau khi có nhịp: DNS 3 ms, auth
  key 2,1–3,7 s.
- **Đã tìm ra nguyên nhân gốc và bỏ nhịp — xem D12.**

## D9. MTProxy fake-TLS chạy với proxy thật — 16/11/2026

- Proxy riêng của anh (secret `ee`, tên miền giả www.cloudflare.com): PC và iPhone 5 tạo auth key + ping qua DC2 / DC5. Kiểm
  được cả ClientHello / HMAC / giờ, bản ghi TLS, obfuscated2 có secret, intermediate có đệm. `dd` chưa có proxy để thử.

## D10. Phiên lưu ra tệp; không dùng `ConnectionParams::default()` — 16/11/2026

- `SqliteSession` của grammers dùng libsql (C, nặng) — chưa đưa lên armv7. Bản thử dùng `gm-core::FileSession` (JSON, 0600,
  ghi tệp tạm rồi đổi tên); app thật sẽ dùng SQLite (`rusqlite` bundled) như thiết kế.
- `ConnectionParams::default()` gọi `locate-locale` (Objective-C trên Apple) và `os_info` → thiếu ký hiệu objc khi nối trên
  iOS. `GmConnector::connection_params(ClientInfo)` dựng đủ từng trường; app tự báo tên máy / phiên bản / ngôn ngữ.

## D11. Fake-TLS ký bằng giờ đo qua NTP, không tin giờ máy — 16/11/2026

- MTProxy kiểm giờ Unix khách ký trong ClientHello, chỉ cho lệch vài giây. Đo so với PC: iPad 1 nhanh +5,0 / +5,5 s →
  **bị proxy từ chối** (proxy chuyển tiếp sang trang www.cloudflare.com thật → sai HMAC); iPhone 5 chậm −2,2 s → qua.
- Máy iOS cũ hay trôi giờ, người dùng không biết phải chỉnh → `gm-net::clock`: hỏi SNTP (UDP 123: time.google.com,
  time.cloudflare.com, pool.ntp.org, time.apple.com; 1,5 s mỗi máy) một lần trước lần bắt tay fake-TLS đầu tiên, đo lại sau
  6 giờ (hỏng thì 10 phút sau mới thử lại, khỏi chậm mọi lần kết nối khi mạng chặn UDP 123). Giờ hệ thống giữ nguyên.
- Kết quả: iPad 1 lệch +6,6 s so với NTP, có chỉnh thì bắt tay qua (15 ms); iPhone 5 −0,9 s; PC +0,9 s.
- Câu báo lỗi khi proxy vẫn từ chối ghi rõ đã chỉnh giờ hay chưa đo được.

## D12. Nguyên nhân gốc của D8: mio đánh thức bằng `EVFILT_USER` kiểu iOS 5 / 6 không hiểu → dùng pipe — 16/11/2026

- `spike/02-kqueue/kqtest2.c` trên iPhone 5 (iOS 6.1.4) và iPad 1 (iOS 5.1.1): một lệnh kevent `EV_ADD|EV_ONESHOT` +
  `NOTE_TRIGGER` (cách mio 1.x đánh thức trên Apple — không đăng ký trước) **không đánh thức** luồng đang chờ, cũng không để
  lại sự kiện; đăng ký trước rồi kích, hoặc pipe, thì thức sau ~300 ms. `tools/kqtest` của Côn Bằng TV chỉ thử cách «đăng
  ký trước» nên kết luận nhầm là kqueue chạy đúng.
- Sửa: `tools/rust/cargo-ios6.sh` đặt `RUSTFLAGS=--cfg mio_unsupported_force_waker_pipe` (công tắc có sẵn của mio). Đã bỏ
  nhịp 50 ms. Thử không nhịp: DNS qua `spawn_blocking` 4–10 ms (trước: treo), auth key qua MTProxy 3,3 s, `dialogs` 111–217 ms
  trên cả hai máy.
- Côn Bằng TV Legacy / ChimToTV (`linux/ffi`, nhịp 50 ms) cũng bỏ được nhịp bằng cùng công tắc này.

## D13. App Giai đoạn 1: cách dựng — 16/11/2026

- Cầu ObjC ↔ Rust: hai hàm C, JSON hai chiều, kết quả về luồng chính bằng GCD (như `cbtv_*` của Côn Bằng TV, gọn hơn:
  không có `call_sync`). Runtime tokio nhiều luồng nhưng **một** luồng làm việc (A4 một nhân).
- `-Werror=unguarded-availability`: SDK 9.3 gắn nhãn «iOS 6» cho cả `NSTextAlignment` / `NSLineBreakMode` (kể cả tên kiểu) →
  dùng số (`GMAlignCenter`…, giá trị trùng hằng `UITextAlignment` của iOS 5); API iOS 6 thật (UIRefreshControl…) thì hỏi lúc
  chạy và bao bằng `GM_IOS6_BEGIN` / `GM_IOS6_END`.
- Thư viện lõi chỉ `staticlib`: thêm `rlib` thì cargo tắt LTO (86 MB → 3,9 MB khi bỏ).
- Dữ liệu ở `~/Library/GramMini` (app ở /Applications không có sandbox); bản thử chép phiên đã đăng nhập từ PC
  (`deploy.sh --session`) để khỏi đăng nhập lại khi thử.

## D14. Giao diện theo bố cục Telegram 4.9, ảnh / biểu tượng tự vẽ — 16/11/2026

- Anh chốt: bố cục và cách dùng giống Telegram 4.9.2 cho quen tay (bong bóng, danh sách chat, menu tin nhắn, cài đặt);
  ảnh, biểu tượng tự vẽ (CoreGraphics lúc chạy); tên GramMini; không dùng logo / nhận diện của Telegram (điều khoản API,
  tránh người dùng tưởng là app chính thức).
- Gói `Tai_Lieu/Telegram_Messenger_4.9.2` (+ `.ipa`): app Telegram đời Objective-C (armv7, iOS 6.0, đã gỡ mã hoá — bản
  «BagOnBlue»). Chỉ dùng tham khảo bố cục / danh sách tính năng; không chép mã / ảnh; **không lên git** (có
  `iTunesMetadata.plist` = thông tin Apple ID người mua, tệp chạy có bản quyền).

## D15. Bộ nhớ đệm: giới hạn, hạn giữ, chống đầy máy — 16/11/2026

- Anh yêu cầu: có xoá bộ nhớ đệm, tự xoá, dung lượng đệm tối đa; đầy thì tự xoá và ghi đè như Telegram, chống đầy máy.
- Lõi quản lý (`gm-core/src/cache.rs`) vì lõi ghi tệp; app chỉ hiện và gửi lệnh. Đệm = `media/`, `avatars/`, `tmp/`; phiên,
  cài đặt, nhật ký nằm ngoài → không bao giờ bị xoá.
- «Lần dùng cuối» = thời điểm sửa của tệp; lõi (`touch`) và app (`GMTouchFile`) đánh dấu khi dùng lại tệp có sẵn (tối đa
  1 lần / giờ / tệp — đỡ ghi đĩa). Không dựa vào atime (không chắc iOS cập nhật).
- Tự dọn: tệp quá hạn giữ (mặc định 1 tháng) → xoá; tổng > giới hạn (mặc định 1 GB — máy 16 GB đời cũ) → xoá tệp lâu không
  dùng nhất tới 90 % giới hạn; máy còn < 300 MB → xoá tiếp tới khi còn ≥ 500 MB; tệp tạm quá 1 giờ → xoá. Tệp vừa dùng /
  đang ghi trong 10 phút được giữ. Chạy ở luồng blocking: 20 s sau khi mở, 30 phút một lần, sau mỗi lần tải (cách nhau
  ≥ 1 phút), khi đổi chính sách.
- Tên tệp đệm mang khoá peer → thống kê / xoá theo chat không cần cơ sở dữ liệu riêng.
- `core.log` quá 1 MB thì bắt đầu lại (app.log vốn đã vậy).
- Bài học iOS 5 / 6: `DirEntry::metadata()` của std gọi `fstatat` (iOS 8) → app crash lúc chạy; dùng `std::fs::metadata`.
  Thêm `tools-local/symcheck.sh` để kiểm ký hiệu sau mỗi lần dựng.

## D16. Gửi tệp từ bộ nhớ máy, nén video — 16/11/2026

- Anh yêu cầu gửi tệp từ bộ nhớ điện thoại. iOS 5 / 6 không có app Tệp / UIDocumentPicker (iOS 8) → trình chọn tệp riêng
  (`GMFileBrowserViewController`); app ở /Applications không có sandbox nên đọc được `/var/mobile/…`. Trang đầu: Tài liệu,
  Tải về, DCIM, Ghi âm, «Tài liệu của các app» (đọc `Info.plist` để hiện tên app thay mã UUID), thư mục người dùng, toàn máy.
  Tệp gửi dạng tệp đính kèm (giữ nguyên, như mục «Tệp» của Telegram), tối đa 2 GB.
- Mime theo bảng đuôi tệp tự viết: MobileCoreServices (UTType) không dùng được — Theos có thư mục header riêng trùng tên
  (`vendor/include/MobileCoreServices`) làm hỏng module của SDK.
- Tải lên có tiến độ: lõi bọc tệp bằng `AsyncRead` đếm byte rồi đưa vào `upload_stream` của grammers (khỏi vá grammers).
- Video từ thư viện: tự nén bằng AVAssetReader / AVAssetWriter (`GMVideoCompressor`: H.264 Baseline cạnh dài ≤ 640,
  ~1,2 Mbit/s, AAC 64 kbit/s / kênh, «moov» ở đầu). **AVAssetExportSession không dùng được**: preset 640×480 / Medium báo
  -11800 / OSStatus -12780 ngay (~60 ms) với mọi video có tiếng (không tiếng thì được; preset Low được nhưng 192×144); đã thử
  đổi chỗ ghi (/var/tmp), tiếng stereo, bật phiên âm thanh, ký kèm `application-identifier` — đều không ăn thua.
  Nén lỗi / bản nén không nhỏ hơn 10 % → gửi bản gốc. Gửi xong chuyển bản nén vào bộ đệm (`media/d<peer>_<id>.mp4`) → mở
  lại khỏi tải; tệp gửi từ bộ nhớ máy thì nhớ đường dẫn gốc (không chép).

## D17. Tin mới khi app ở nền — 16/11/2026

- Mức 1 (THIET-KE mục 9): xuống nền → `beginBackgroundTask` (~10 phút còn kết nối); tin mới → `UILocalNotification` (tên chat /
  «người @ nhóm», nội dung — tắt xem trước thì «Tin nhắn mới»), âm thanh, số chưa đọc (chat không tắt tiếng) trên biểu tượng.
  Bỏ qua: chat tắt tiếng (trừ khi nhắc tới mình), tin của mình (trừ lời nhắc hẹn giờ), tin cũ hơn 6 giờ (lấy bù).
- Mức 2: `UIBackgroundModes = voip`. Lõi báo mỗi socket TCP mới (`net.socket`, móc trong gm-net); app bọc bằng
  `CFStreamCreatePairWithSocket` + `kCFStreamNetworkServiceTypeVoIP` (không đóng socket của lõi). CFStream chỉ báo «có dữ liệu»
  một lần rồi chờ chính nó đọc (mà tokio đọc thẳng socket) → mỗi lần báo, sau 1 giây bọc lại bằng cặp mới — thiếu bước này iOS
  không đánh thức app. `setKeepAliveTimeout:600` hỏi máy chủ 10 phút một lần. iOS tự mở app ở nền sau khi khởi động / respring.
  Thử trên iPhone 5: app đã treo (không xin thêm giờ nền) vẫn được đánh thức khi có tin, phát thông báo.
- iOS 5 / 6 chỉ hiện thông báo của app đã «đăng ký thông báo»: app gọi `registerForRemoteNotificationTypes:` (ký kèm
  entitlement `aps-environment`; không dùng push của Apple — mã thiết bị bỏ đi) → iOS hỏi quyền một lần.
- Chạm thông báo mới mở chat (app ở trạng thái Inactive). iOS có thể gọi `didReceiveLocalNotification` lúc app còn ở nền — khi đó
  không mở chat (mở chat = đánh dấu đã đọc; anh phát hiện app «tự vào chat»). Màn chat chỉ đánh dấu đã đọc khi app đang mở.
- Cài đặt → Thông báo (của app): hiện thông báo, xem trước, âm thanh, số trên biểu tượng.
- Lệnh thử `schedule <giây> <chữ>` (tin hẹn giờ — Tin nhắn đã lưu thành lời nhắc) để tự thử không cần người nhắn. **Chỉ gửi vào
  Tin nhắn đã lưu** (`opensaved`): «open 0» là chat đầu danh sách — 16/11 em lỡ gửi 5 tin thử vào chat thật của anh.
- Bản thử: có `/var/mobile/Documents/gm-noregister` thì chưa đăng ký (hộp hỏi quyền khỏi che màn khi thử giao diện máy khác).
- `deploy.sh`: tắt app SAU khi `dpkg -i` — app VoIP bị tắt là iOS mở lại ngay, tắt trước thì chạy lại bản cũ.

## D18. Tweak GMNotify trong SpringBoard (anh đồng ý 16/11/2026) — 16/11/2026

- Đã đăng ký và được cho phép (`SBSettingsEnabledTypes = 7`) mà GramMini vẫn không có trong Cài đặt → Thông báo, thông báo bị
  bỏ (SpringBoard có nhận: `SBApplicationLocalNotificationsLastFireDate` cập nhật). Đọc chuỗi trong tệp chạy SpringBoard iOS 6:
  danh sách app có mục thông báo lập từ `-[SBRemoteNotificationServer _allPushRegisteredThirdPartyBundleIDs]`,
  `-[SBPushStore allLocalNotificationEnabledBundleIDs]` / `allNotificationEnabledBundleIDs` — chỉ app **bên thứ ba**
  (/var/mobile/Applications). GramMini là gói Cydia ở /Applications → bị coi là app hệ thống. Không có khoá Info.plist nào bật
  được (`SBAppUsesLocalNotifications` không tồn tại ở iOS 6).
- Chọn tweak (THIET-KE mục 9, Mức 3) thay vì cài như app App Store (sandbox → mất duyệt tệp trong máy; Cydia / OTA khó cài
  vào container). `tweak/GMNotify`: móc ba hàm trên (tra lúc chạy), thêm `vn.grammini.app`. Không đổi quyền — người dùng vẫn cho /
  không cho phép, chỉnh trong Cài đặt → Thông báo. Đi kèm gói GramMini (`SUBPROJECTS`), gói phụ thuộc `mobilesubstrate`; lần đầu
  cần khởi động lại SpringBoard (việc phát hành — mục 2 — sẽ xử lý nút «Khởi động lại» của Cydia).
- iPhone 5: sau respring, thông báo hiện trên màn hình khoá («GramMini — <tên chat>: …»); anh xác nhận.
- Các thao tác tự bấm hộp xin quyền hệ thống bị lớp an toàn chặn (kể cả khi anh cho phép trong chat) → anh bấm tay.

## D19. Hàng chờ gửi khi mất mạng — 16/11/2026

- Lõi (`outbox.json`): `messages.send` + `queue` gặp lỗi mạng (NETWORK / TIMEOUT 20 s) → lưu tin chữ, trả mã tạm âm. Có mạng lại
  (lệnh thành công, vòng 10 s) → gửi lần lượt; xong → `outbox.sent`, máy chủ từ chối → `outbox.failed`, lỗi mạng → dừng chờ lượt
  sau. Tắt app vẫn còn (tệp).
- App: bong bóng 🕓 hiện ngay khi bấm Gửi (grammers thử lại ~9 s mới báo lỗi mạng); gửi được → thay bằng tin thật; ⚠️ → chạm để
  gửi lại / xoá; mở chat → nạp tin còn chờ. Menu nhấn giữ của tin chưa gửi: chỉ Sao chép.
- Rủi ro đã biết: hết 20 s mà máy chủ thật ra đã nhận → gửi lại thành 2 tin (grammers sinh random_id mới mỗi lần gửi).

## D20. Lõi: `dispatch` để trên heap — 16/11/2026

- Thêm các lệnh có kiểu TL lớn (ChatFull…) làm khối trạng thái của `async fn dispatch` phình → tràn ngăn xếp luồng chính 1 MB
  của Windows (gm-cli). Luồng tokio trên iOS chỉ 2 MB → `call` dùng `Box::pin(self.dispatch(…))`, các lệnh lớn tách hàm riêng
  (`chat_status`, `chat_info`, …) cũng `Box::pin`.
- Không chạy `cargo fmt` cho cả crate: mã không theo định dạng mặc định của rustfmt (lần lỡ chạy đổi 120 chỗ — đã trả lại).

## D21. Mật mã: cửa sổ riêng, băm có muối — 16/11/2026

- Màn khoá là `GMLockViewController` làm view controller gốc của một UIWindow riêng (mức StatusBar − 1): thêm thẳng vào cửa sổ
  chính thì iOS 5 / 6 không xoay theo máy (iPad) và bị màn bật lên (xem ảnh, QuickLook) che.
- Xuống nền → phủ màn khoá ngay (iOS chụp màn cho thanh đa nhiệm); quay lại trước thời gian tự khoá → tự gỡ.
- Không ghi đè `supportedInterfaceOrientations` (kiểu `UIInterfaceOrientationMask` chỉ có từ iOS 6 → lỗi khi dựng); mặc định đã
  đúng.
- Lưu `SHA-256(muối ‖ mã)` (muối 16 byte ngẫu nhiên) trong tệp 0600 — 4 số thì băm không chống được dò thử ngoại tuyến; mục tiêu
  là người cầm máy, không phải người có quyền root.

## D22. Chế độ tối — 16/11/2026

- iOS 5 / 6 không có chế độ tối hệ thống → tự làm: chế độ chốt lúc `GMTheme apply`; đổi chế độ thì dựng lại cây màn
  (`GMAppDelegate reloadTheme` — appearance proxy / ảnh tự vẽ chỉ vào view tạo sau). Ảnh tự vẽ (bong bóng, biểu tượng) đệm theo
  chế độ.
- Màu bảng / ô dùng chung cho mọi màn: đổi cách gọi `-[UITableView didMoveToWindow]` / `-[UITableViewCell layoutSubviews]`
  (chỉ khi tối): nền, vạch kẻ, nền ô; chữ **màu mặc định** (đen / xám / xanh xám — tối và ít bão hoà) → màu chữ tối; chữ đã đặt
  màu riêng (xanh chủ đạo, đỏ) giữ nguyên. Không dùng appearance cho UILabel (iOS 5 / 6 đè cả màu đặt trong mã).
- Bong bóng chat (GMBubbleCell) không đụng tới (nền trong suốt để thấy nền chat).

## D23. Giao diện iOS 6 + kính trong (anh duyệt bản mẫu) — 16/11/2026

- Anh yêu cầu làm lại giao diện «đậm chất iOS 6» kết hợp hiệu ứng trong suốt kiểu macOS Tahoe; em vẽ 4 màn mẫu (danh sách chat,
  chat, Cài đặt, chat tối), anh duyệt. Thêm **thanh dưới** Danh bạ / Chat / Cài đặt (UITabBarController — mỗi mục một thanh điều
  hướng; màn chat ẩn thanh dưới; số chưa đọc thành huy hiệu đỏ ở mục Chat); nút trái danh sách chat thành «Sửa» (chế độ xoá).
- iOS 5 / 6 không có làm mờ thời gian thực (UIVisualEffectView từ iOS 8; tự chụp + làm mờ từng khung quá nặng cho A4 / A5) →
  «kính» = lớp bán trong suốt + vệt bóng + viền sáng **trên hình nền tĩnh** loang màu (vẽ một lần, lưu JPEG ở `~/Library/GramMini/ui`:
  iPad 1 vẽ 0,57 s, đọc lại nhanh hơn nhiều). Thanh trên / thanh dưới / ô nhập chỉ lộ hình nền (nội dung không chạy dưới thanh) →
  trông như kính mờ thật.
- `GMWallpaperView`: ảnh vuông cạnh = cạnh dài màn (phủ cả ngang lẫn dọc), canh theo **view của màn + chiều cao thanh trên** (không
  theo cửa sổ: lúc màn đang trượt vào / iPad xoay thì toạ độ cửa sổ sai) → nền sau thanh trên kính liền với nền của màn. Bảng của
  app tự nhận nền này làm `backgroundView` (bảng nhóm phủ thêm sọc dọc iOS 6 bán trong); màn chat đặt nền ở view của màn
  (`GMTagNoWallpaper` cho bảng tin) để nền lộ cả dưới ô nhập kính.
- Chỉ đụng **bảng / ô của app** (nguồn dữ liệu là lớp `GM…`): bảng của hệ thống (chọn ảnh, QuickLook) giữ nguyên. Ô: nền kính
  (`glassFill` / `glassGrouped`), chữ nền trong suốt — UIKit iOS 5 / 6 đặt nền chữ = nền ô, với nền bán trong thành hai lớp chồng
  → đặt lại sau `layoutSubviews`, `setHighlighted:animated:`, `setSelected:animated:`. Ô tự lo nền (danh sách chat — thẻ kính lề
  8 pt, hàng đầu / cuối bo góc) đánh `GMTagOwnBackground`.
- Nút thanh trên: ảnh nền viền nổi + nút quay lại hình mũi tên (appearance chỉ trong `UINavigationBar` / `UISearchBar` — thanh
  công cụ của hệ thống không bị đổi); nút biểu tượng (soạn tin, làm mới) dùng chung ảnh nền đó. Thanh dưới: kính khói (cả hai chế
  độ), ảnh mục tự vẽ, đặt bằng `setFinishedSelectedImage:withFinishedUnselectedImage:` (iOS 5) để iOS khỏi tô màu xanh mặc định.
- Bong bóng: dải màu + vệt bóng nằm trong phần mũ trên của ảnh co giãn (không bị kéo dài khi tin nhiều dòng), viền 1 pt.
- Biểu tượng app (anh yêu cầu: tròn, viền trong suốt, cách điệu chữ G): đĩa xanh bóng có màu loang như hình nền, chữ G trắng thành
  bong bóng chat (đuôi góc dưới trái), vòng kính bán trong bao ngoài, góc ngoài trong suốt (SpringBoard iOS 5 / 6 giữ kênh alpha;
  `UIPrerenderedIcon` = có để iOS không phủ vệt bóng vuông). Vẽ bằng `tools/icon/make_icon.py` (Pillow, vẽ 1024 rồi thu nhỏ). Đổi
  biểu tượng trên máy cần respring (SpringBoard giữ ảnh cũ trong bộ nhớ; `uicache` không đủ).

## D24. Phiên bị huỷ (AUTH_KEY_DUPLICATED) — 16/11/2026

- Sự cố: em chạy `gm-cli svc` trên PC bằng bản sao phiên trong lúc 3 máy thử (vốn được chép cùng một phiên bằng
  `deploy.sh --session`) đang chạy → Telegram trả 406 AUTH_KEY_DUPLICATED cho mọi kết nối, phiên chết hẳn; app kẹt ở dòng lỗi,
  đăng xuất / đăng nhập lại vẫn 406 (auth key cũ còn trong lõi đang chạy).
- Sửa: lõi gặp AUTH_KEY_DUPLICATED / SESSION_REVOKED / USER_DEACTIVATED(_BAN) (lúc hỏi trạng thái, vòng cập nhật) → dời
  `session.json` thành `session.dead-<giờ>.json`, dừng vòng cập nhật, báo `auth.dead`; app báo «Cần đăng nhập lại» → «Mở lại»
  thoát app (lõi giữ auth key trong bộ nhớ, `OnceLock` không thay được) → lần mở sau phiên trống → màn đăng nhập, auth key mới.
  AUTH_KEY_UNREGISTERED không tính (có thể chỉ là DC phụ chưa xuất quyền).
- Quy tắc: một phiên chỉ dùng ở một nơi — mỗi máy tự đăng nhập; `deploy.sh --session` đã chặn; muốn thử lõi trên PC thì đăng
  nhập phiên riêng cho PC.

## D25. Bộ sticker, thư mục chat, lưu ảnh / video — 16/11/2026

- Sticker như Telegram gốc: chạm sticker trong chat / link t.me/addstickers/… → xem cả bộ (Thêm / Gỡ, chạm sticker để gửi);
  màn «Sticker» (Cài đặt, nút + của bảng sticker): bộ của bạn (vuốt để gỡ), bộ nổi bật, tìm bộ. Tự tải sticker lên = qua bot
  @Stickers như app gốc (API tạo bộ chỉ dành cho bot) → lối tắt «Tạo bộ sticker riêng» mở chat với bot.
- Thư mục chat = dialog filters của Telegram (đồng bộ tài khoản). Lõi chỉ đọc / ghi thư mục; **app tự lọc** danh sách chat theo
  luật của Telegram (ghim / đưa vào riêng → có; bỏ riêng → không; loại trừ tắt tiếng / đã đọc / lưu trữ; loại chat) — lõi trả
  thêm `contact`, `bot`, `archived`, `marked_unread` cho mỗi chat. Dải thẻ là đầu mục 0 của bảng thường (dính dưới thanh trên khi
  cuộn, iOS 5 không có cách khác gọn hơn với UITableViewController). Danh sách chat tải 100 chat (thư mục có chat cũ hơn thì chưa
  hiện chat đó).
- Lưu ảnh / video: `UIImageWriteToSavedPhotosAlbum` / `UISaveVideoAtPathToSavedPhotosAlbum` (bản gốc lớn nhất; video kiểm tra
  `UIVideoAtPathIsCompatibleWithSavedPhotosAlbum`); bị từ chối quyền Ảnh (-3310 / -3311) thì chỉ đường bật trong Cài đặt.

## D26. Sticker động TGS — bộ vẽ Lottie viết bằng Rust (gm-lottie) — 16/11/2026 (bản 1.1)

- TGS = Lottie (JSON) nén gzip. Không dùng rlottie (C++ — thêm libc++ / bộ dựng C++ cho iOS 5 / 6, nhiều rủi ro ký hiệu): tự viết
  crate `gm-lottie` (serde_json + tiny-skia + flate2, Rust thuần) phủ phần Lottie mà sticker Telegram được dùng (lớp hình / rỗng
  / lồng / màu, cha — con, nhóm, đường cong biến hình, chữ nhật, elip, tô màu, viền + nét đứt, dải màu thẳng / tròn, cắt nét,
  khung chính có làm mượt / giữ, đường đi cong của vị trí). Không có mask / matte / merge (sticker Telegram không được dùng).
  Kiểm bằng `gm-cli lottie <tệp> <thư mục>` trên 7 tệp TGS mẫu (repo Telegram-iOS) — hình đúng.
- Bản phát hành dựng `panic = abort` → bộ vẽ không panic: đọc JSON bằng `get`, lọc NaN, gặp lạ thì bỏ qua.
- App: `gm_lottie_open / info / render / close` (FFI đồng bộ) gọi trên một hàng đợi nền nối tiếp dùng chung (đóng hoạt hình cũng
  xếp vào đó → không đóng lúc đang vẽ); `GMLottieView` đặt ảnh khung vào layer.contents, ≤ 30 khung / giây, cỡ ≤ 256 px, đồng
  hồ ở chế độ mặc định của run loop (dừng lúc cuộn), chạy 5 lượt rồi dừng ở khung cuối (hiện lại thì chạy tiếp). iPhone 5:
  256 × 256 mất ~15 ms / khung.
- Lõi `media.stickerfile` tải nguyên tệp TGS → `media/s<peer>_<id>_a.tgs`, kiểm gzip. Lỗi gặp khi thử: tên `s<peer>_<id>.tgs`
  trùng tệp tạm `.part` với ảnh tĩnh của cùng tin (`media.sticker` tải song song) → tệp TGS bị ghi đè bằng WebP → đổi tên.
- LLVM gộp sin + cos (tiny-skia xoay hình) thành `__sincosf_stret` — iOS 7+, iOS 5 / 6 không có → dyld dừng app ở lần vẽ đầu.
  Vá trong `app/Core/GMShims.c` như `__exp10` (kiểu trả về riêng cùng bố cục — SDK 9.3 không khai báo cho armv7).

## D27. Xoá cho cả hai bên, tin tự xoá, sticker video WebM — 16/11/2026 (bản 1.2)

- **Xoá tin**: như app gốc — chat riêng: «Xoá cho cả hai bên» (tin của mình lẫn của bên kia) hoặc «Xoá chỉ ở máy tôi»
  (`messages.deleteMessages revoke:false`); nhóm thường: tin của mình xoá được cho mọi người, tin người khác chỉ xoá ở máy mình;
  kênh / siêu nhóm: luôn xoá cho mọi người. Xoá cả chat riêng: thêm «Xoá cho cả hai bên» (`messages.deleteHistory revoke`, lặp
  theo `offset` tới hết). Bot: vẫn hiện hai lựa chọn (máy chủ tự xử).
- **Tin tự xoá**: thông tin chat → «Tự xoá tin nhắn» (Tắt / 1 ngày / 1 tuần / 1 tháng — `messages.setHistoryTTL`, áp cho tin gửi
  từ lúc đặt, hai bên); Quyền riêng tư → «Tự xoá tin nhắn» = mức mặc định cho chat mới (`messages.setDefaultHistoryTTL`). Tin hết
  hạn: máy chủ xoá, app nhận `msg.delete` như thường. Tin nhắn đã lưu không có (máy chủ báo `PEER_ID_INVALID`).
- **Sticker video**: iOS 5 / 6 không giải VP9 → libvpx (BSD) vendor ở `core/vendor/libvpx` — chỉ bộ giải mã VP9, cấu hình
  lấy từ bản dựng sẵn của Chromium (không chạy `configure` / perl của libvpx), dựng bằng `cc` như libopus. armv7: NEON
  intrinsics (bỏ phần hợp ngữ .asm cú pháp ARM; `HAVE_NEON_ASM 0`), PC: C thuần. `CONFIG_OS_SUPPORT 0` (vpx_timer.h dùng
  `CLOCK_MONOTONIC` — SDK 9.3 không có), một luồng, 8 bit, khung ≤ 1024.
- Crate `gm-webm`: đọc WebM (EBML: Tracks, Cluster, SimpleBlock / BlockGroup, BlockAdditional id 1 = luồng VP9 của kênh trong
  suốt — kiểu ffmpeg / Telegram), giải hai luồng song song, đổi YUV (BT.601 / 709, dải studio / đầy) + alpha → RGBA nhân alpha
  thu nhỏ song tuyến (thu 2 lần = trung bình khối 2 × 2). Không panic (đọc có kiểm giới hạn, tệp ≤ 4 MB, ≤ 2000 khung).
- Đo (sticker 512 px có kênh trong suốt, vẽ ra 256 px): iPhone 5 — C thuần 28,5 ms / khung, **NEON 11 ms** (sticker thật 13,6 ms);
  iPad 1 (A4, iOS 5, vẽ 160 px) — NEON 19 ms. Hai hàng đợi vẽ (TGS + WebM chung): máy hai nhân vẽ hai sticker song song.
- Lỗi gặp khi thử: (1) `Client::download_media` của grammers ghi bằng `tokio::fs::File` không flush → lần ghi cuối chạy nền sau
  khi hàm trả về; đọc ngay sau đó thấy tệp 0 byte (TGS 15 KB thoát, WebM 200 KB dính) → `download()` tự ghi + flush.
  (2) Hai lệnh cùng tải một tệp (ô chat vẽ lại khi tin vừa gửi) chung tệp tạm `.part` → tệp tạm riêng `.<số>.part`.
  (3) Ô chat dùng lại từ sticker cho dòng ngày / tin hệ thống còn giữ nhãn giờ của sticker → ẩn.

## D28. Chủ đề diễn đàn (forum topics); vá grammers-client — 17/11/2026

- Siêu nhóm bật «Chủ đề»: trước đây app hiện tin của mọi chủ đề lẫn nhau, mỗi tin trong chủ đề còn kèm trích dẫn giả
  «Tin nhắn …» (grammers `reply_to_message_id()` trả mã chủ đề — tin thường trong chủ đề là «trả lời» tin tạo chủ đề).
- Lõi: `msg_json` đọc `messageReplyHeader` — cờ `forum_topic`: có `reply_to_top_id` → đó là chủ đề, `reply_to_msg_id` là tin
  được trả lời thật; không có → `reply_to_msg_id` là chủ đề, KHÔNG phải trả lời. Tin tạo chủ đề: chủ đề = chính nó; không có
  chủ đề → General (id 1). `topics.list` = `messages.getForumTopics` (+ tin cuối mỗi chủ đề); tin của chủ đề =
  `messages.getReplies(msg_id = chủ đề)` — General (1) máy chủ cũng nhận (đo: 126 ms; lỗi thì lõi lọc lịch sử cả nhóm);
  đánh dấu đã đọc theo chủ đề = `messages.readDiscussion` (không đánh dấu cả nhóm); gửi vào chủ đề = trả lời tin tạo chủ đề
  (`reply_to_msg_id` = chủ đề, theo tài liệu Telegram; General gửi như nhóm thường; trả lời một tin trong chủ đề thì máy chủ
  tự xếp). Tin hệ thống sửa chủ đề (đổi tên / đóng / mở / ẩn / đổi biểu tượng); tin hệ thống không có người gửi (quản trị viên
  ẩn danh) lấy tên chat như app gốc.
- Dựng `Message` của grammers từ phản hồi thô cần `PeerMap` — grammers 0.12 không cho dựng từ ngoài → vendor
  `grammers-client` 0.12.0 (`core/vendor/grammers-client`), bản vá một chữ: `Client::build_peer_map` công khai
  (`core/patches/0002-grammers-client-build-peer-map.patch`). Cách khác (getReplies lấy mã rồi `get_messages_by_id`) tốn hai
  lượt mạng mỗi trang.
- App: nhóm có chủ đề mở màn danh sách chủ đề (`GMTopicsViewController`, ô giống danh sách chat: biểu tượng chữ cái trên nền
  `icon_color` — emoji riêng của chủ đề chưa vẽ; 📌 ghim, 🔒 đóng, 🔇 tắt tiếng; tin mới cập nhật trực tiếp, cuộn tới cuối tải
  thêm); chạm chủ đề → màn chat chỉ tin chủ đề đó (tiêu đề = tên chủ đề, dòng phụ = tên nhóm); «Tất cả» → mọi tin như nhóm
  thường. Số chưa đọc của nhóm = tổng các chủ đề. Không theo cờ «xem dạng tin nhắn» của tài khoản (app chưa có chỗ đổi lại —
  dùng «Tất cả»).
- Thử (iPhone 5, nhóm anh cho phép, chỉ xem, công cụ thử `noread` tắt đánh dấu đã đọc): 17 chủ đề, ghim / đóng / màu đúng;
  chủ đề thường, General, «Tất cả» đúng tin, không còn trích dẫn giả. Chưa gửi tin vào chủ đề (tài khoản chính — chỉ thử
  trong Tin nhắn đã lưu).

## D29. Video H.265 — 17/11/2026

- iOS 5 / 6 chỉ giải hình H.264; video quay bằng máy mới (H.265 / HEVC) phát lên chỉ có tiếng. Telegram tự chuyển nhiều
  video sang vài mức chất lượng (`messageMediaDocument.alt_documents`, `documentAttributeVideo.video_codec`).
- `media.document` + `video: true` (app gọi khi phát video / video tròn): tệp gốc không ghi H.264 mà có bản H.264 → tải bản có
  cạnh ngắn cao nhất ≤ 720 (không có thì bản nhỏ nhất) vào chỗ tệp gốc; tệp H.265 đã tải từ trước (nhận bằng `hvc1` / `hev1`
  trong hộp `moov`) thì xoá, tải bản H.264. Không có bản H.264 → trả `hevc: true`, app báo «Video mã H.265 — iOS 5 / 6 chỉ phát
  được tiếng» (nhật ký lõi ghi mã / cỡ của tệp gốc và các bản khác).
- Video anh gặp (một nhóm của anh, 12,7 MB): tệp gốc H.265, không có thuộc tính video, không có bản nào khác → chỉ báo được.
  Giải H.265 bằng phần mềm (libde265 / ffmpeg) trên A5 / A6 chưa làm — nặng, chưa chắc kịp thời gian thực.

## D30. Giải H.265 bằng phần mềm: chuyển sang H.264 trên máy — 17/11/2026 (bản 1.3)

- Video H.265 không có bản H.264 trên máy chủ (D29): phát thẳng H.265 theo thời gian thực bằng phần mềm không kịp trên A4 / A5
  (1080p) → **chuyển một lần** sang H.264 rồi phát bằng trình phát của iOS (tua, toàn màn hình, tiếng chuẩn), tệp H.264 thay
  tệp gốc trong bộ đệm (lần sau mở là phát ngay).
- Giải mã: FFmpeg 7.1.5 (LGPL 2.1+), chỉ bộ giải HEVC, vendor ở `core/vendor/ffmpeg` bằng `tools/ffmpeg/vendor-ffmpeg.py`:
  chép tệp cần + dây chuyền `#include`, tự sinh `config.h` (quét macro → mặc định 0, bật phần cần) — không chạy `configure`.
  armv7: hợp ngữ NEON của FFmpeg (clang của Theos hợp dịch được, `HAVE_AS_FUNC 0`, `HAVE_VFP_ARGS 0` — ABI softfp), giải song
  song theo khung (`FF_THREAD_FRAME`, số nhân). Không `clock_gettime` (iOS 10+). Đã kiểm ký hiệu iOS 5 / 6: thiếu 0.
- Crate `gm-hevc`: đọc MP4 bằng Rust (`moov/trak/stbl`, hvcC, ma trận xoay, ctts — khung B), gọi FFmpeg qua lớp bọc C mỏng,
  thu nhỏ song tuyến ra NV12 dải video (cạnh ngắn ≤ 480; 10 bit → 8 bit; dải đầy → dải video). Windows / MSVC: bản rỗng.
- App (`GMHevcTranscoder`): khung NV12 → `AVAssetWriter` H.264 phần cứng (~3 bit / điểm ảnh / giây — 480p ≈ 1,2 Mbit/s), giữ
  ma trận xoay; tiếng: `AVAssetReader` ra PCM → mã lại AAC (iOS 5 chưa chép thẳng AAC sang tệp mới được — thiếu
  `sourceFormatHint`); ghi xen kẽ hình / tiếng (writer chỉ nhận tiếp một rãnh khi rãnh kia theo kịp). Máy một nhân: bỏ khung
  không làm tham chiếu (`AVDISCARD_NONREF` — không khung nào dựa vào → không nhoè; nhanh ~1,7 lần, ít khung / giây hơn).
- Đo (1080 × 1920, 30 khung / giây, 200 giây): iPhone 5 **27 khung / giây** (222 giây cho 200 giây video); iPad 1: 1019 giây
  (5,9 khung / giây) → bật bỏ khung không làm tham chiếu: **537 giây** (video ra 3032 khung ≈ 15 khung / giây, hình sạch). Bong bóng video hiện % trong lúc chuyển; xong mà còn ở màn chat thì phát luôn.

## D31. Tính năng Telegram còn thiếu: link t.me, cảm xúc, nút bot, bình chọn, tin ghim — 17/11/2026

- Anh hỏi còn thiếu gì cấp thiết (tham khảo Roza); anh chọn làm lần lượt 11 mục (bản 1.4.0). Thử trên iPad 1 (iOS 5, chỉ xem
  chat / kênh công khai, gửi chỉ trong Tin nhắn đã lưu); gửi thật ở chat khác (cảm xúc, bình chọn, ghim, vị trí, danh thiếp, ảnh
  QR) và bấm «Tham gia» / nút callback của bot chưa thử — anh cho phát hành trước.
- **Link t.me mở trong app** (`service/links.rs`, `GMLinks`): iOS 5 / 6 không có app Telegram → mở Safari là ngõ cụt. Lõi đọc
  t.me/<tên>[/<chủ đề>]/<tin>, t.me/s/…, t.me/+<mã> / joinchat (mã phân biệt hoa thường; t.me/+84… là số điện thoại → bỏ),
  t.me/c/<kênh>/<tin>, tg://resolve / join / privatepost / user, @tên (thực thể Mention đưa vào `links`). Lời mời chưa vào:
  `messages.checkChatInvite` → hộp «Tham gia nhóm / kênh» (nhóm cần duyệt: «Gửi yêu cầu»); nhóm riêng cho xem trước (Peek): mở
  như chat chưa vào, tham gia bằng mã. Chat chưa vào (`left` từ `chat.status`): thanh «Tham gia nhóm / kênh» thay ô nhập
  (`channels.joinChannel` / `messages.importChatInvite` — lớp mới trả `ChatInviteJoinResult`). App đăng ký giao thức `tg://`
  (nút «Mở trong Telegram» của trang t.me trong Safari mở vào GramMini; link proxy → màn Proxy). Hộp thoại có khối xử lý tách
  ra `Core/GMAlert`.
- **Cảm xúc** (`service/react.rs`): đọc `message.reactions` kèm tin, cập nhật `updateMessageReactions` → `msg.reactions`;
  `messages.sendReaction` (một cảm xúc — tài khoản thường), phản hồi có danh sách mới. App: viên «👍 3» dưới chữ trong bong bóng
  (sticker: dưới sticker), viên của mình tô màu; chạm viên = thả / gỡ; nhấn giữ → «Cảm xúc» → bảng emoji nổi trên bong bóng.
  iOS 5 / 6 thiếu emoji mới (🥰 🤔 🤯 … vẽ ra ô trống): dò bằng CoreText (`CTFontGetGlyphsForCharacters` trên Apple Color
  Emoji; chuỗi ZWJ coi như không vẽ được) — bảng chọn chỉ có emoji vẽ được (iPad 1: 44 / 73 loại Telegram cho), viên nhận
  được thì đổi emoji gần nghĩa (🥰 → 😍, 🤔 → 😕…), không có thì «•». Emoji riêng Premium → «✨», sao trả phí → «⭐» (chỉ hiện).
  Số lớn gọn như Telegram (8,8K, 1,5M). Tin nhắn đã lưu không cho (ở đó cảm xúc là thẻ — Premium); chat chỉ cho một số emoji →
  bảng theo danh sách đó (kênh Durov chỉ cho emoji riêng → không mở bảng).
- **Bot** (`service/bots.rs`): nút dưới tin (`replyInlineMarkup` — lớp mới: `keyboardInlineButton` + `InlineButtonType`) hiện
  thành hàng nút dưới bong bóng: link (↗, t.me mở trong app), callback (`messages.getBotCallbackAnswer`, dữ liệu hex; câu trả lời
  → thông báo / hộp, có `url` thì mở; bot không trả lời kịp 20 giây → im lặng), sao chép, hồ sơ người; loại khác (trò chơi, thanh
  toán, inline…) báo chưa làm. Bàn phím trả lời (`replyKeyboardMarkup`) = `inputView` của ô nhập (hiện đúng chỗ bàn phím máy),
  nút ▦ trong ô nhập để đổi qua lại; tự hiện khi tin mới nhất của bot có bàn phím; dùng một lần → đóng sau khi bấm; phím «gửi số»
  → hỏi rồi gửi danh thiếp của mình, «gửi vị trí» → màn chọn vị trí. Chat bot trống: thẻ «Bot này làm được gì?» (mô tả từ
  `users.getFullUser`) + nút «Bắt đầu» (gửi /start). Khoá bộ đệm chiều cao hàng thêm độ dài chữ + số hàng nút (bot sửa tin nhiều
  lần mà cờ «đã sửa» không đổi → trước đây chiều cao cũ).
- **Bình chọn** (`service/poll.rs`, `GMPollView`): câu hỏi, loại (ẩn danh / công khai / câu đố, nhiều lựa chọn, đã đóng); chưa
  bỏ phiếu: chạm lựa chọn (nhiều lựa chọn: đánh dấu rồi «Bỏ phiếu»); đã bỏ / đã đóng: % + thanh, ✓ của mình, câu đố đúng xanh /
  sai đỏ, «Rút phiếu». `messages.sendVote`; `updateMessagePoll` → `msg.poll` (kết quả `min` không kèm lựa chọn của mình → giữ ✓
  cũ). Lõi có `messages.sendPoll` (lớp mới: `inputPollAnswer`) — chưa có màn tạo bình chọn, dùng cho lệnh thử.
- **Tin ghim** (`service/pins.rs`): `messages.search` lọc `inputMessagesFilterPinned` (≤ 50, màn chủ đề lọc theo chủ đề) →
  thanh «Tin đã ghim 1/3» trên đầu màn chat; chạm = nhảy tới tin rồi chuyển sang tin ghim cũ hơn; ✕ ẩn tới lần mở sau.
  `updatePinnedMessages` / `updatePinnedChannelMessages` → `msg.pinned` (tải lại). Nhấn giữ → «Ghim / Bỏ ghim»
  (`messages.updatePinnedMessage`, không báo cho mọi người; nhóm cần quyền quản trị).

## D32. Tiện ích lấy từ Roza: nhắc hẹn, vị trí, iPad chia đôi, tin nhắn nhanh, VietQR, danh thiếp — 17/11/2026

- **Nhắc hẹn / hẹn giờ gửi**: lõi đã có `schedule` (D17, chỉ lệnh thử) → nhấn giữ «Gửi» khi có chữ (cử chỉ chỉ bắt đầu khi ô
  nhập có chữ — ô trống nút là mic, không được huỷ ghi âm): «Sau 30 phút / 1 giờ / 3 giờ / Tối nay 20:00 / Sáng mai 8:00 / Chọn
  ngày giờ… (UIDatePicker) / Gửi không âm báo». Ở Tin nhắn đã lưu gọi là «Nhắc tôi» — tới giờ Telegram gửi tin, máy báo như tin
  mới (GMBackground báo cả tin của mình nếu là tin hẹn giờ). Thanh «🕓 N lời nhắc / tin hẹn giờ ›» trên ô nhập → danh sách
  (`messages.getScheduledHistory`): gửi ngay / huỷ. Telegram tự đồng bộ với app trên điện thoại — khác Roza (nhắc hẹn của Zalo).
- **Vị trí** (`service/geo.rs`, `GMMap` — từ Roza `RZLocation`): MapKit iOS 5 / 6 chỉ còn lưới trống → ghép ô OpenStreetMap
  (lõi tải `map.tile` vì TLS iOS 6 không vào được, đệm ở `maps/` — bộ đệm tính vào «khác», tự dọn), User-Agent nêu tên app
  (quy định OSM), ghi «© OpenStreetMap»; địa chỉ bằng Nominatim tiếng Việt (chờ 0,8 giây sau lần kéo cuối). Tin vị trí /
  địa điểm / vị trí trực tiếp: bản đồ nhỏ 240 × 150 trong bong bóng (ghép ô mức 15 + ghim, đệm trong bộ nhớ), chạm → màn bản
  đồ (kéo, + / −, «Mở…»: chép toạ độ, Google Maps). Gửi: đính kèm → «Vị trí» → định vị máy (CoreLocation; iOS 6 hỏi quyền với
  `NSLocationUsageDescription`) hoặc kéo bản đồ → `inputMediaGeoPoint` (tin vị trí thật — khác Roza phải gửi chữ + link).
- **iPad chia đôi** (như Roza D20): gốc cửa sổ là `UISplitViewController` (iOS 5 / 6 bắt buộc), bên trái thanh dưới như iPhone
  (320), bên phải `detail` (chat / danh sách chủ đề); `shouldHideViewController` → NO (luôn hai cột cả chiều dọc); chưa mở chat:
  «Chọn một cuộc trò chuyện». Mọi chỗ mở chat (danh sách, danh bạ, tìm, link, thông báo, Tin nhắn đã lưu trong Cài đặt) đi qua
  `GMAppDelegate showDetail:`; hàng chat đang mở được tô; đổi giao diện sáng / tối mở lại chat đang mở. Lệnh thử nhắm vào bên
  phải nếu có (`L <lệnh>` = bên trái).
- **Tin nhắn nhanh** (`GMQuickReplies`, Cài đặt → Tin nhắn nhanh): mẫu câu tự đặt, lưu trên máy (Telegram chỉ đồng bộ «quick
  replies» cho tài khoản doanh nghiệp). Gõ «/» đầu ô nhập → khung gợi ý trên ô nhập: lệnh của bot (chat bot: `bot_info`, nhóm:
  `bot_info` của các bot trong nhóm — chạm = gửi luôn) + tin nhắn nhanh khớp (chạm = chữ mẫu thay vào ô nhập, sửa rồi gửi);
  không khớp gì → «+ Thêm tin nhắn nhanh» (mở hộp thêm, điền sẵn từ khoá).
- **Mã QR chuyển khoản VietQR** (`service/vietqr.rs` — chuyển từ Roza, crate `qrcode`): chuỗi EMVCo / NAPAS (CRC-16/CCITT-FALSE),
  nội dung bỏ dấu (≤ 50 ký tự). Danh sách ngân hàng nhúng sẵn (mã BIN đối chiếu api.vietqr.io ngày 17/11/2026 — Telegram không có
  API ngân hàng như Zalo). Màn «Mã QR chuyển khoản» (đính kèm): ngân hàng, số TK, chủ TK, số tiền, nội dung → thẻ 600 điểm ảnh
  (tên ngân hàng, QR, STK, chủ TK, số tiền) → gửi như ảnh, chú thích có STK để người nhận chép. Nhớ tài khoản dùng lần trước.
- **Danh thiếp** (`service/contact.rs`): tin danh bạ → thẻ như bong bóng tệp (vòng chữ cái, tên, số); chạm → «Nhắn tin» (số có
  Telegram), «Gọi» (máy gọi được), «Chép số». Gửi: đính kèm → «Danh thiếp» → chọn trong danh bạ (người ẩn số → báo).
- Toast nhiều dòng (câu trả lời của bot dài) — trước đây cắt còn một dòng.
- Kiểm ký hiệu bản debug: 502 / 502 trên iOS 5 (iPad 1) và iOS 6 (iPad mini 1), thiếu 0.
