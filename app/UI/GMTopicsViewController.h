#import <UIKit/UIKit.h>

/// Danh sách chủ đề của nhóm diễn đàn (siêu nhóm bật «Chủ đề»), như Telegram gốc: biểu tượng chủ đề (chữ cái trên nền màu),
/// tên (🔒 đã đóng, 🔇 tắt tiếng), tin cuối (người gửi + xem trước), giờ, số chưa đọc / ghim. Chạm → màn chat chỉ tin của chủ
/// đề đó; «Tất cả» → tin của mọi chủ đề như nhóm thường. Tin mới cập nhật trực tiếp; cuộn xuống cuối thì tải thêm chủ đề.
@interface GMTopicsViewController : UITableViewController
@property (nonatomic, copy) NSString *peer, *name, *myId;
/// Ảnh đại diện của nhóm (khoá ảnh + DC, từ danh sách chat) — cho màn «Tất cả».
@property (nonatomic, strong) id photo;
@property (nonatomic, strong) NSNumber *photoDc;
/// Tổng tin chưa đọc của các chủ đề (không tính chủ đề tắt tiếng) đổi — danh sách chat cập nhật số của nhóm.
@property (nonatomic, copy) void (^unreadChanged)(NSInteger total);
/// Công cụ thử: mở chủ đề ở hàng `row` / màn «Tất cả».
- (void)openTopicAt:(NSInteger)row;
- (void)openAll;
@end
