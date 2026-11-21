# GramMini — Phương án gọi thoại qua Telegram (21/11/2026 — anh chốt làm sau bản 1.5.0, D38)

## 0. Kết luận ngắn

- **Gọi thoại 1-1 với app Telegram chính thức: làm được, nhưng phải tự viết phần âm thanh trong lõi Rust.** Không có thư viện
  dựng sẵn nào vừa chạy được trên iOS 5 / 6 vừa còn gọi được với Telegram hiện nay.
- Chọn giao thức **tgcalls «V2» (phiên bản 8.0.0 / 9.0.0)**: Android, iOS, Desktop chính thức đều còn hỗ trợ.
- **Không làm**: gọi video, gọi nhóm (voice chat), gọi với người dùng Telegram Web.
- Đề nghị **thử trên PC trước** (gm-cli): khi gọi được hai chiều với app chính thức mới đưa lên máy. Nếu không được thì dừng ở
  đó, chưa đụng tới app.
- Đây là việc lớn nhất từ trước tới nay: bản Rust tham khảo (Ferrogram) có khoảng 6–8 nghìn dòng cho phần gọi.
- Thay mục «Không làm: gọi thoại / video» ở THIET-KE §0.7 nếu anh duyệt.

## 1. Vì sao không dùng thư viện cũ libtgvoip

libtgvoip (C++, public domain) là thư viện gọi của Telegram đời cũ. Nó từng chạy trên iOS 6 armv7 (dự án Xcode đặt iOS 6.0),
thu / phát bằng AudioUnit VoiceProcessingIO, và dễ dựng bằng bộ dựng của GramMini. Nhưng giao thức của nó (**2.4.4**) đã bị bỏ:

| App chính thức | Bỏ 2.4.4 từ |
| --- | --- |
| Telegram iOS | 02/2025 (bản ~11.8; xoá luôn `libtgvoip` khỏi mã) |
| Telegram Desktop | 5.14.0 (05/2025) |
| Telegram Android | 12.10.2 (09/2026) |

Khi gọi, mỗi bên gửi danh sách phiên bản mình hỗ trợ; **máy chủ chọn một phiên bản chung**. Không có phiên bản chung thì cuộc
gọi hỏng ngay với lỗi `406 CALL_PROTOCOL_COMPAT_LAYER_INVALID`. Ngày 17/11/2026 telega.el (Telegram cho Emacs) cũng báo mất
gọi thoại đúng vì lý do này.

Thư viện mới **tgcalls** dựa trên libwebrtc của Google (C++17, Telegram iOS hiện đòi iOS 15). Không dựng được cho iOS 5 / 6.

## 2. Các phiên bản hiện có

| Phiên bản | Kiểu | Android / iOS / Desktop | Web A |
| --- | --- | --- | --- |
| 2.4.4 | libtgvoip | không | không |
| 2.7.7, 5.0.0 | tgcalls V1: ICE + mã hoá kiểu MTProto, không DTLS | có | không |
| **8.0.0, 9.0.0** | **tgcalls V2: ICE + DTLS-SRTP, báo hiệu JSON** | **có** (tg2sip — cầu nối SIP dùng ntgcalls — gọi được với cả ba app bằng 9.0.0) | không |
| 12.0.0, 13.0.0 | V3: thêm SCTP | có | chỉ 13.0.0 |
| 10, 11, 14, 18, 19 | biến thể riêng của từng app | tuỳ app | — |

**Chọn V2** vì:

- Đã có bản C++ (ntgcalls) gọi được với app chính thức để đối chiếu gói tin.
- Đã có bản Rust (Ferrogram, giấy phép MIT, **cùng grammers 0.12 như GramMini**) để tham khảo cách viết.

V1 nhẹ hơn (không DTLS) nhưng không có bản nào để đối chiếu, và là bản dễ bị bỏ tiếp theo.

## 3. Cách làm

| Phần | Làm gì | Ở đâu |
| --- | --- | --- |
| Báo hiệu | `phone.requestCall` / `acceptCall` / `confirmCall` / `discardCall`, `updatePhoneCall`, `phone.sendSignalingData`. **grammers 0.12 (layer 233) đã có đủ** — chỉ cần gọi thẳng. Trao khoá DH 2048 bit (`messages.getDhConfig`, kiểm số nguyên tố an toàn), 4 emoji khoá để hai bên so | Lõi Rust |
| Đường truyền | ICE tự viết, gọn: máy chủ chuyển tiếp của Telegram (`phoneConnection`, dùng như TURN) + STUN / TURN (`phoneConnectionWebrtc`), UDP trước, TCP dự phòng | Lõi (gm-net) |
| Mã hoá | DTLS 1.2 + SRTP (AES_CM_128_HMAC_SHA1_80). ring đã chạy trên iOS 5 / 6 (Côn Bằng TV). Crate `webrtc-dtls` kéo thêm rustls / rcgen — phải thử dựng; nặng quá thì tự viết DTLS tối giản (một bộ mã) | Lõi |
| Âm thanh | Opus 48 kHz mono, khung 20 ms (libopus 1.4 **đã có trong gm-media** cho tin thoại), bộ đệm chống rung tự viết | Lõi (gm-media) |
| Thu / phát | AudioUnit **VoiceProcessingIO** (có từ iOS 3: khử tiếng vọng, giảm ồn, tự chỉnh mức thu — libtgvoip cũng dùng cách này), AVAudioSession PlayAndRecord, loa trong / loa ngoài, cảm biến tiệm cận tắt màn khi áp tai | ObjC |
| Gọi đến khi app ở nền | Dùng lại D17: socket VoIP đánh thức app → `updatePhoneCall` → `phone.receivedCall` + thông báo có nhạc chuông (tối đa 30 giây, lặp lại) «Lan Anh đang gọi…», nút «Trả lời». Sau đó có thể làm màn cuộc gọi đến toàn màn hình trên màn khoá qua tweak GMNotify (D18) | ObjC + tweak |
| Giữ cuộc gọi khi tắt màn | Thêm `audio` vào `UIBackgroundModes` (đang có `voip`) | Info.plist |
| Giao diện | Màn cuộc gọi kiểu kính (theo bộ mẫu mới); nút gọi trong màn chat và hồ sơ; mục «Cuộc gọi» ở thanh dưới + lịch sử (lọc tin `messageActionPhoneCall`) | ObjC |

CPU: Opus (độ phức tạp 5) cộng SRTP cho 50 gói mỗi giây là việc nhẹ cả với A4. DTLS chỉ bắt tay một lần. Sẽ đo thật ở bước G3.

## 4. Không làm

- **Gọi video**: phải mã hoá / giải mã VP8 / H.264 thời gian thực qua WebRTC — quá sức A4 / A5, mà iOS 5 / 6 không có
  VideoToolbox.
- **Gọi nhóm / voice chat**: cùng nền ICE + DTLS-SRTP nhưng thêm máy chủ SFU và nhiều luồng. Để sau, nếu gọi 1-1 chạy tốt.
  Riêng việc chỉ nghe các buổi phát trực tiếp (RTMP) thì tải từng đoạn qua `upload.getFile` được — có thể làm riêng.
- **Gọi với Telegram Web** (chỉ có 13.0.0): app báo «Người này dùng bản Telegram không gọi được với GramMini».

## 5. Rủi ro

| # | Rủi ro | Cách đỡ |
| --- | --- | --- |
| 1 | Telegram bỏ tiếp 8.0.0 / 9.0.0, như đã bỏ 2.4.4 trong 2025–2026 | Viết phần truyền tách khỏi phần báo hiệu để thêm V3 (13.0.0) sau; theo dõi tgcalls |
| 2 | **Chưa có bản Rust nào được xác nhận gọi được với app chính thức** (Ferrogram và tgcalls-rs đều tự ghi chưa thử với máy thật) | Bước G2 trên PC là mốc quyết định, làm trước khi đụng app |
| 3 | Máy chủ đổi kiểu truyền theo từng cuộc (`custom_parameters`: `network_use_mtproto`…) | Ghi lại tham số nhận được khi thử; làm thêm kiểu nào gặp thật |
| 4 | Dựng DTLS (`webrtc-dtls` / rustls / rcgen) cho armv7 iOS 6 | Thử dựng ngay ở G1; không được thì tự viết DTLS tối giản |
| 5 | **Nhà mạng chặn Telegram**: cuộc gọi đi bằng UDP tới máy chủ chuyển tiếp; MTProxy **không chở được** cuộc gọi | Thử qua SOCKS5 có UDP và Shadowsocks UDP (lõi chung ChimToTV); không được thì báo rõ «Cuộc gọi không đi qua MTProxy» |
| 6 | Thử nghiệm cần **tài khoản Telegram thứ hai**: máy chính chỉ thử trong Tin nhắn đã lưu, không gọi người thật; không chép phiên sang PC (D24) | gm-cli đăng nhập phiên riêng bằng tài khoản thứ hai; gọi tới app chính thức trên máy khác |

## 6. Các bước

| Bước | Việc | Xong khi |
| --- | --- | --- |
| G0 | Anh chốt có làm không; chuẩn bị tài khoản thứ hai (SIM phụ) đăng nhập Telegram chính thức trên một máy khác | — |
| G1 | gm-cli (PC, phiên riêng): báo hiệu + trao khoá + 4 emoji, chưa có tiếng. Thử dựng `webrtc-dtls` cho armv7 iOS 6 | 4 emoji trùng với app chính thức |
| G2 | gm-cli: ICE + DTLS-SRTP + Opus (micro / loa PC) theo V2. Gọi đi và nhận cuộc gọi với Telegram Desktop / Android / iOS. **Mốc quyết định** — **XONG 21/11/2026**: gọi đi + gọi đến với iOS 18, emoji trùng, tiếng hai chiều, Wi-Fi / 5G, p2p / chuyển tiếp, 5 phút | Nghe rõ hai chiều ≥ 5 phút, qua Wi-Fi và 4G |
| G3 | Đưa lên iOS 5 / 6: ký hiệu thiếu = 0, cầu AudioUnit VoiceProcessingIO ↔ lõi, loa trong / ngoài, cảm biến tiệm cận, đo CPU | iPad mini, iPhone 5, iPad 1 |
| G4 | Giao diện: màn cuộc gọi, nút gọi, mục «Cuộc gọi» + lịch sử, đánh giá cuộc gọi | — |
| G5 | Gọi đến khi app ở nền / màn khoá, giữ cuộc gọi khi tắt màn, đổi Wi-Fi ↔ 3G giữa cuộc, thử qua proxy | Phát hành |

Thứ tự anh đã nói: làm giao diện mới (PHUONG-AN-GIAO-DIEN-26.md) trước, gọi thoại sau. G1–G2 chỉ chạy trên PC nên có thể làm
song song nếu anh muốn biết sớm có khả thi không.

## Nguồn

- Cách máy chủ chọn phiên bản: [phoneCallProtocol](https://core.telegram.org/constructor/phoneCallProtocol), lỗi
  [phone.acceptCall](https://core.telegram.org/method/phone.acceptCall), luồng gọi [Calls](https://core.telegram.org/api/calls),
  mã hoá [video-calls](https://core.telegram.org/api/end-to-end/video-calls), gọi nhóm [Group calls](https://core.telegram.org/api/group-calls).
- Mã các app (đã đọc tận dòng): [tgcalls](https://github.com/TelegramMessenger/tgcalls) (`Instance.cpp`, `InstanceImpl.cpp`,
  `v2/InstanceV2Impl.cpp`; commit «Remove legacy» 79d6b6612b),
  [Telegram Android](https://github.com/DrKLO/Telegram) (`jni/voip/org_telegram_messenger_voip_Instance.cpp`),
  [Telegram iOS](https://github.com/TelegramMessenger/Telegram-iOS) (`TelegramVoip/Sources/OngoingCallContext.swift`,
  `TgVoipWebrtc/Sources/OngoingCallThreadLocalContext.mm`),
  [Telegram Desktop](https://github.com/telegramdesktop/tdesktop) (`calls/calls_call.cpp`; commit 98d71308a8).
- [libtgvoip](https://github.com/grishka/libtgvoip), [ntgcalls](https://github.com/pytgcalls/ntgcalls),
  [Ferrogram](https://github.com/Dasemu/Ferrogram) (`docs/calls-feasibility.md`),
  [telega.el #631](https://github.com/zevlg/telega.el/issues/631).
- Chạy nền iOS 4–8: `UIApplication setKeepAliveTimeout:handler:`, `kCFStreamNetworkServiceTypeVoIP` (tài liệu Apple).
