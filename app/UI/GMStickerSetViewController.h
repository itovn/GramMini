#import <UIKit/UIKit.h>

/// Bộ sticker vừa thêm / gỡ (userInfo: `set`) — bảng sticker, màn Sticker tải lại.
extern NSString *const GMStickersChangedNotification;

/// Xem một bộ sticker (như app Telegram gốc): lưới sticker + nút «Thêm N sticker» / «Gỡ bộ sticker». Mở từ: chạm sticker trong
/// chat, link t.me/addstickers/…, màn Sticker. `pick` (có khi mở từ một chat): chạm sticker để gửi vào chat đó.
@interface GMStickerSetViewController : UIViewController
/// Bộ cần mở: @{id, access_hash} hoặc @{short_name}.
@property (nonatomic, copy) NSDictionary *set;
@property (nonatomic, copy) void (^pick)(NSDictionary *doc);
/// Bật lên trong thanh điều hướng riêng (iPad: khung giữa màn).
+ (void)present:(NSDictionary *)set from:(UIViewController *)vc pick:(void (^)(NSDictionary *doc))pick;
@end

/// Màn «Sticker» (Cài đặt → Sticker, nút + của bảng sticker): bộ của bạn (chạm để xem, Sửa / vuốt để gỡ), tạo bộ riêng (bot
/// @Stickers — cách Telegram gốc cho tự tải sticker lên), bộ nổi bật (Thêm ngay), ô tìm bộ sticker theo tên.
@interface GMStickersViewController : UITableViewController
/// Mở từ một chat: chạm sticker trong bộ đang xem để gửi.
@property (nonatomic, copy) void (^pick)(NSDictionary *doc);
@end
