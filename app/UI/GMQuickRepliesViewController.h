#import <UIKit/UIKit.h>

/// Cài đặt → Tin nhắn nhanh: danh sách mẫu câu (từ khoá + chữ), thêm / sửa (chạm), xoá (vuốt). Dùng: gõ «/từ khoá» khi soạn tin.
@interface GMQuickRepliesViewController : UITableViewController
/// Mở thẳng hộp thêm mới với từ khoá điền sẵn (từ khung gợi ý trong chat).
@property (nonatomic, copy) NSString *prefillKeyword;
@end
