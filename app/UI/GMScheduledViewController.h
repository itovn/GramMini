#import <UIKit/UIKit.h>

/// Tin đã hẹn giờ của một chat (ở Tin nhắn đã lưu: lời nhắc): giờ gửi + nội dung; chạm → «Gửi ngay» / «Huỷ hẹn»; vuốt để huỷ.
@interface GMScheduledViewController : UITableViewController <UIActionSheetDelegate>
@property (nonatomic, copy) NSString *peer;
/// Tin nhắn đã lưu: gọi là «lời nhắc».
@property (nonatomic) BOOL saved;
/// Số tin hẹn giờ còn lại sau khi đổi (màn chat cập nhật thanh «… tin hẹn giờ»).
@property (nonatomic, copy) void (^changed)(NSInteger count);
@end

/// «20:00 hôm nay», «08:00 mai», «08:00 20/11».
NSString *GMScheduleText(NSTimeInterval unix);
