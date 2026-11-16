#import <UIKit/UIKit.h>

/// Nhóm mới: chọn người trong danh bạ (ô tìm lọc ngay, dấu ✓), «Tiếp (n)» → đặt tên → tạo (lõi `groups.create`) → `created(nhóm)`.
@interface GMNewGroupViewController : UITableViewController
@property (nonatomic, copy) NSString *myId;
@property (nonatomic, copy) void (^created)(NSDictionary *group);
/// Gỡ lỗi: chọn / bỏ chọn hàng; tạo với tên.
- (void)debugToggle:(NSInteger)row;
- (void)debugCreate:(NSString *)title;
@end
