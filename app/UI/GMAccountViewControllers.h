#import <UIKit/UIKit.h>

/// Sửa hồ sơ (chạm phần đầu Cài đặt): ảnh đại diện (chụp / chọn), tên, họ, giới thiệu, @tên (kiểm tra còn trống), số điện
/// thoại (chỉ xem). «Lưu» đổi tên / họ / giới thiệu (lõi `account.update`).
@interface GMProfileViewController : UITableViewController
@end

/// Quyền riêng tư và bảo mật: ai thấy lần truy cập / số điện thoại / ảnh đại diện, ai chuyển tiếp được tin, ai gọi được, ai
/// thêm mình vào nhóm (Mọi người / Danh bạ / Không ai); Mật mã; Phiên đăng nhập.
@interface GMPrivacyViewController : UITableViewController
@end

/// Phiên đăng nhập: máy này + các máy khác (thiết bị, app, nơi, lần dùng cuối); chạm một phiên khác → kết thúc phiên đó.
@interface GMSessionsViewController : UITableViewController
@end

/// Sửa hai ô tên (tên, họ) — dùng cho «Sửa tên liên hệ» (lõi `contacts.rename`).
@interface GMEditNameViewController : UITableViewController
@property (nonatomic, copy) NSString *first, *last;
@property (nonatomic, copy) void (^save)(NSString *first, NSString *last, void (^finish)(NSDictionary *err));
@end
