#import <UIKit/UIKit.h>

@class GMChatListViewController;

/// Tin mới khi app ở nền (D17):
/// - Mức 1: xuống nền thì xin thêm thời gian chạy (~10 phút) — kết nối vẫn mở, tin mới thành thông báo.
/// - Mức 2: chế độ nền «voip» — mỗi socket lõi mở tới Telegram (sự kiện `net.socket`) được bọc CFStream + đánh dấu VoIP; app
///   đã bị treo thì iOS đánh thức khi có dữ liệu về. Cứ 10 phút (`setKeepAliveTimeout`) hỏi máy chủ một lần cho kết nối khỏi
///   chết; iOS tự mở lại app ở nền sau khi khởi động máy.
/// - Thông báo: tên chat (nhóm: «người gửi @ nhóm»), nội dung (tắt xem trước thì «Tin nhắn mới»), âm thanh, số chưa đọc trên
///   biểu tượng. Bỏ qua chat tắt tiếng (trừ khi nhắc tới mình), tin của mình (trừ lời nhắc hẹn giờ ở Tin nhắn đã lưu).
@interface GMBackground : NSObject
+ (instancetype)shared;
@property (nonatomic, weak) GMChatListViewController *list;
- (void)start;
- (void)didEnterBackground;
- (void)willEnterForeground;
/// Số trên biểu tượng = tổng chưa đọc của chat không tắt tiếng (tắt trong Cài đặt → Thông báo thì 0).
- (void)updateBadge;
/// Gỡ lỗi: xuống nền mà không xin thêm thời gian (app bị treo ngay — thử đánh thức bằng socket VoIP).
@property (nonatomic) BOOL debugNoBackgroundTask;
@end

/// Khoá cài đặt (NSUserDefaults, mặc định bật).
extern NSString *const GMPrefNotify, *const GMPrefPreview, *const GMPrefSound, *const GMPrefBadge;
BOOL GMPref(NSString *key);
