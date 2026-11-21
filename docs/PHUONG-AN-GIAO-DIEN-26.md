# GramMini — Phương án giao diện «kính lỏng» kiểu iOS 26 / Telegram 12 (21/11/2026 — anh duyệt «như ảnh», D37)

Mục tiêu: GramMini trông như Telegram mới nhất trên iOS 26 (Liquid Glass), nhưng **vẫn chạy iOS 5.1.1 (iPad 1, A4, 256 MB)
tới iOS 6.1.4**, cuộn không giật. Thay hướng «iOS 6 + kính trong» của D23; giữ nguyên bố cục, tính năng và cách dùng quen
tay của D14.

Bản mẫu (7 màn, cỡ thật iPhone 5 320 × 568 pt, bấm qua lại được):
<https://claude.ai/artifact/8GnRqDkVB6Ft9wJksXceAV> — danh sách chat, màn chat, menu giữ tin, bảng đính kèm, Cài đặt; danh
sách chat và màn chat bản tối. Màn nào cũng đổi Sáng / Tối được trong Tweaks › dark.

---

## 1. Telegram mới làm gì

| Thời điểm | Nội dung (nguồn: blog Telegram, 9to5Mac) |
| --- | --- |
| 10/2025 (Telegram iOS 12.1) | Kính lỏng **tự viết**, không cần iOS 26: thanh dưới, bàn phím, bảng sticker… trong suốt, có hiệu ứng khúc xạ khi cuộn |
| 01/2026 | «Kính lỏng trên toàn app»; thêm chỗ giảm hiệu ứng trong Settings › Power Saving để đỡ tốn pin |
| 02/2026 | Kính lỏng cho màn xem ảnh / video, bảng xem trước bộ sticker / emoji, menu ngữ cảnh trong hồ sơ và khi chọn tin |

Telegram tự vẽ hiệu ứng chứ không dùng API của iOS 26, giống hướng của GramMini (iOS 5 / 6 không có API nào). Bài viết chính
thức không tả chi tiết từng màn, nên bản mẫu dựng theo quy ước iOS 26 (thanh dưới nổi, nút tròn kính, nội dung mờ dần ở mép)
cộng bố cục Telegram (thư mục chat, bong bóng có đuôi, ô nhập ba phần). Nếu anh có ảnh chụp Telegram bản mới (thư mục
`Tai_Lieu/ipa tele new` đang trống), em chỉnh mẫu cho khớp hơn.

## 2. Thay đổi theo từng thành phần

| Thành phần | Hiện tại (D23) | Mới |
| --- | --- | --- |
| Thanh trên | UINavigationBar bóng kiểu iOS 6, nút viền nổi, nút quay lại hình mũi tên | Không còn nền thanh; nút là **viên kính** (tròn cho biểu tượng, dài cho chữ); tiêu đề đậm ở giữa |
| Thanh trên màn chat | Tiêu đề + trạng thái trên thanh bóng | Nút quay lại tròn có **số chưa đọc**; tên + trạng thái trong viên kính giữa; ảnh đại diện bên phải |
| Thanh dưới | UITabBar kính khói, rộng hết màn | **Viên kính nổi** cách mép 22 pt, cao 58; mục đang chọn có viên nền trượt; huy hiệu đỏ |
| Danh sách chat | Thẻ kính lề 8 pt trên hình nền loang | Nền trơn (trắng / đen) như Telegram; hàng phẳng 72 pt, ảnh đại diện 54 pt; ô tìm kiếm + thư mục dạng viên |
| Màn chat | Hình nền loang, bong bóng dải màu bóng | Giữ hình nền loang; bong bóng **phẳng** bo 17 pt, đuôi cong; tin thoại có dạng sóng |
| Ô nhập | Một thanh kính rộng hết màn | **Ba viên tách rời**: ghim giấy · ô chữ (có nút sticker) · mic / gửi |
| Menu giữ tin | UIMenuController (bong bóng đen của iOS) | Nền chat làm mờ, tin được nhấc lên, **hàng cảm xúc** viên kính, menu kính chia nhóm (Xoá màu đỏ ở nhóm riêng) |
| Đính kèm | UIActionSheet | Bảng kính nổi bo 30 pt: lưới ảnh gần đây, ô máy ảnh, thanh Ảnh / Tệp / Vị trí / Bình chọn / Danh thiếp |
| Bảng nhóm (Cài đặt…) | Sọc dọc iOS 6 bán trong | Nền xám phẳng, nhóm bo 22 pt, biểu tượng ô vuông màu 30 pt, hồ sơ ở đầu (ảnh 84 pt) |
| Chữ | Helvetica Neue | Vẫn Helvetica Neue (iOS 5 / 6 không có phông SF, và giấy phép không cho kèm SF trong app) — cỡ 16–17, đậm hơn |
| Chế độ tối | Bảng màu đêm xanh xám | Nền đen thuần, kính khói, bong bóng gửi xanh đậm (như Telegram bản đêm) |

## 3. Cách làm trên iOS 5 / 6

iOS 5 / 6 không có làm mờ thời gian thực (UIVisualEffectView có từ iOS 8). Chụp + làm mờ vùng dưới thanh ở mỗi khung hình
quá nặng cho A4 / A5 (D23 đã kết luận). Cách làm dưới đây **không làm mờ gì khi cuộn**:

1. **Vật liệu kính (`GMGlass`)**: ảnh co giãn vẽ một lần cho mỗi cỡ và mỗi chế độ: lớp nền bán trong, viền sáng 0,5 pt, vệt
   sáng chéo phía trên, bóng đổ mềm vẽ sẵn vào ảnh (không dùng `layer.shadow` động). Trên hình nền loang: cắt đúng lát hình nền
   sau viên kính, làm mờ **một lần** bằng vImage rồi lưu đệm → trông như kính mờ thật. Lưu ở `~/Library/GramMini/ui` (như D23).
2. **Mép mờ thay cho «scroll edge effect»**: giữa nội dung và thanh nổi đặt một dải ảnh tĩnh: nền trơn thì dải màu nền chuyển
   dần sang trong suốt; nền loang thì lát hình nền có độ trong chuyển dần. Nội dung chạy tới mép thì tan vào nền, nên thanh nổi
   luôn nằm trên nền tĩnh, kính tĩnh không bị lộ. Không dùng `layer.mask` (tốn trên A4).
3. **Nội dung chạy dưới thanh**: `contentInset` / `scrollIndicatorInsets` của bảng (có từ iOS 2) chừa chỗ cho thanh trên 64 pt
   và thanh dưới 76 pt.
4. **Thanh dưới tự vẽ (`GMTabBar`)**: giữ UITabBarController (giữ cách chuyển mục, bộ nhớ của từng nhánh) nhưng ẩn `tabBar`,
   kéo view con phủ hết màn, đặt `GMTabBar` lên trên. Viên chọn trượt bằng `UIView animateWithDuration:` + nảy nhẹ bằng
   `CAKeyframeAnimation` (iOS 5 / 6 không có `usingSpringWithDamping`). Màn chat ẩn thanh dưới như bây giờ.
5. **Thanh trên**: giữ UINavigationController (giữ hiệu ứng đẩy màn). `setBackgroundImage:` ảnh trong suốt (iOS 5+),
   `setShadowImage:` rỗng (iOS 6+, kiểm `respondsToSelector:`), `translucent = YES` để nội dung chạy dưới thanh. Nút là
   `UIBarButtonItem` có `customView` = viên kính; tiêu đề màn chat bọc `GMTitleView` sẵn có trong viên kính.
6. **Menu giữ tin, bảng đính kèm, hộp xác nhận**: chụp màn **một lần** (`renderInContext:` ở cỡ 1/4), `vImageBoxConvolve`
   ba lượt (gần như Gauss), phóng lên làm nền; tin được chọn vẽ lại sắc nét phía trên. Cần thêm `Accelerate.framework`
   (vImage có từ iOS 5.0). Mục tiêu: dưới 120 ms trên iPad 1. Bảng đính kèm lấy ảnh gần đây qua ALAssetsLibrary (iOS 4+); iOS 6 sẽ hỏi quyền
   truy cập Ảnh một lần (anh bấm tay trên máy thử).
7. **Chế độ «Tiết kiệm»** (giống Settings › Power Saving của Telegram): bỏ bóng đổ, bỏ nền mờ của menu (thay bằng nền tối
   40 %), bỏ hoạt ảnh nảy. **Mặc định bật trên iPad 1.**
8. **Thanh trạng thái**: iOS 5 / 6 không cho thanh trạng thái trong suốt kiểu iOS 7+; mẫu vẽ màu đen. iPhone iOS 6 tô màu thanh
   trạng thái theo thanh điều hướng, nên thanh trên trong suốt có thể cho ra màu lạ — phải thử trên máy, nếu xấu thì dùng
   `UIStatusBarStyleBlackOpaque`.
9. **iPad** (iPad mini, iPad 1, chia đôi của D32): cùng thành phần; thanh dưới nổi canh giữa cột trái rộng 320; mỗi cột có mép
   mờ riêng.

Ngân sách hiệu năng giữ như THIET-KE §1: không làm mờ khi cuộn; trên vùng cuộn tối đa hai lớp bán trong chồng nhau; viên kính
tĩnh bật `shouldRasterize`; đo khung hình bằng bộ đếm CADisplayLink trong GMDebug trên cả ba máy.

## 4. Các bước làm

| Bước | Việc | Thử trên máy |
| --- | --- | --- |
| G1 | Khung chung: `GMGlass`, mép mờ, `GMTabBar`, thanh trên trong suốt, thanh trạng thái | Cuộn danh sách 300 chat trên iPad 1, đo khung hình |
| G2 | Danh sách chat: hàng phẳng, ô tìm kiếm, thanh thư mục dạng viên, chế độ «Sửa» | iPhone 5, iPad mini |
| G3 | Màn chat: thanh trên ba phần, ô nhập ba viên, bong bóng phẳng có đuôi, nút cuộn xuống | Tin dài, tin thoại, trả lời, cảm xúc |
| G4 | Menu giữ tin (chụp + làm mờ), hàng cảm xúc, bảng đính kèm, hộp xác nhận thay UIActionSheet | Đo thời gian mở menu trên iPad 1 |
| G5 | Cài đặt + các màn bảng nhóm còn lại (Proxy, Thông báo, Bộ nhớ…), Danh bạ, Đăng nhập | Cả ba máy |
| G6 | Chế độ tối, chế độ Tiết kiệm, iPad chia đôi, rà iOS 5 (`cbsymcheck`), phát hành **1.5.0** | OTA như các bản trước |

Chỉ thử gửi / sửa trong Tin nhắn đã lưu trên iPhone 5 (tài khoản chính).

## 5. Cần anh chọn

1. **Nền danh sách chat**: trơn như Telegram (như mẫu) hay giữ hình nền loang + thẻ kính của D23?
2. **Bong bóng gửi**: xanh lá nhạt (như mẫu, giống Telegram cổ điển) hay xanh dương?
3. **Ô tìm kiếm**: ở đầu danh sách như Telegram (như mẫu) hay thành nút tròn cạnh thanh dưới (kiểu iOS 26)?
4. **Thanh dưới**: 3 mục như hiện nay; nếu làm gọi thoại thì thêm mục «Cuộc gọi» (xem `PHUONG-AN-GOI-THOAI.md`).
5. Màn nào cần thêm mẫu trước khi làm (Danh bạ, Đăng nhập, Proxy, xem ảnh, bảng sticker, iPad)?

Nguồn:
[Telegram — AI Summaries, New Design and More (01/2026)](https://telegram.org/blog/new-design-ai-summaries),
[Telegram — Android Redesign… (02/2026)](https://www.telegram.org/blog/crafting-android-design-and-more?setln=en),
[9to5Mac — Telegram adopts a Liquid Glass-like design, no iOS 26 required (10/2025)](https://9to5mac.com/2025/10/13/telegram-adopts-a-liquid-glass-like-design-no-ios-26-required/).
