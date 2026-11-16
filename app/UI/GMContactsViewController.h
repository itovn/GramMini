#import <UIKit/UIKit.h>

/// «Tin nhắn mới» (nút ✎ ở danh sách chat): danh bạ Telegram (theo tên, kèm trạng thái), ô tìm — lọc danh bạ + tìm người /
/// nhóm / kênh trên Telegram theo tên, @tên. Chạm → `pick`.
@interface GMContactsViewController : UITableViewController
@property (nonatomic, copy) NSString *myId;
@property (nonatomic, copy) void (^pick)(NSDictionary *peer);
/// Gốc của mục «Danh bạ» trên thanh dưới (tiêu đề «Danh bạ»; mặc định: «Tin nhắn mới» mở từ nút soạn tin).
@property (nonatomic) BOOL tabRoot;
- (void)debugSearch:(NSString *)q;
- (void)debugTapSection:(NSInteger)s row:(NSInteger)r;
@end
