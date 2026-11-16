#import <UIKit/UIKit.h>

/// «Dữ liệu và bộ nhớ» (kiểu màn Storage Usage của Telegram): dung lượng đệm theo loại / theo chat, chỗ trống của máy,
/// hạn giữ media, giới hạn bộ nhớ đệm, xoá đệm (tất cả / một loại / một chat). Lõi tự dọn theo chính sách (xem cache.rs).
@interface GMStorageViewController : UITableViewController
/// Gỡ lỗi: chạm hàng (mở bảng chọn tương ứng).
- (void)debugTapSection:(NSInteger)section row:(NSInteger)row;
@end
