#import <UIKit/UIKit.h>

/// Thông tin chat (chạm tên ở đầu màn chat), kiểu Telegram 4.9: ảnh lớn, tên, trạng thái; số điện thoại, @tên, giới thiệu
/// (chạm để sao chép); công tắc thông báo (tắt tiếng chat); ảnh / video, tệp, tin thoại, liên kết đã chia sẻ; thành viên nhóm
/// (chạm → chat riêng với người đó).
@interface GMChatInfoViewController : UITableViewController
@property (nonatomic, copy) NSString *peer, *kind, *myId, *name;
@end

/// Đã tắt / bật tiếng một chat (userInfo: peer, muted) — danh sách chat cập nhật biểu tượng 🔇.
extern NSString *const GMChatMutedNotification;
