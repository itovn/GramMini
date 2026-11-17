#import <UIKit/UIKit.h>

#define GMDialogRowH 72
#define GMDialogAvatar 54

/// Ô một chat (kiểu Telegram 4.9): ảnh đại diện tròn, tên, giờ + dấu đã đọc, xem trước, số chưa đọc / ghim, vạch kẻ thụt.
/// Các ô ghép thành một thẻ kính lề 8 pt (hàng đầu / cuối bo góc). Cao GMDialogRowH, ảnh GMDialogAvatar. Dùng cả cho danh sách
/// chủ đề của nhóm diễn đàn.
@interface GMDialogCell : UITableViewCell
@property (nonatomic, strong) UIImageView *avatar, *badgeBg;
@property (nonatomic) BOOL first, last;
@property (nonatomic, strong) UILabel *name, *time, *check, *sender, *preview, *badge, *pin;
@property (nonatomic, strong) UIView *line;
@property (nonatomic, copy) NSString *peerKey;  // ô đang hiện chat nào (ô dùng lại)
/// Hàng đầu / cuối của thẻ (bo góc trên / dưới).
- (void)setFirst:(BOOL)first last:(BOOL)last;
@end

/// Danh sách chat: tên, tin cuối, giờ, số chưa đọc. Chạm → màn chat (nhóm có chủ đề → danh sách chủ đề).
@interface GMChatListViewController : UITableViewController
@property (nonatomic, copy) NSString *myId;
/// Chưa đăng nhập (đóng màn đăng nhập): hiện «Chưa đăng nhập» + nút «Đăng nhập».
@property (nonatomic) BOOL loggedOut;
- (void)reload;
/// Mở chat ở hàng thứ `row` (công cụ thử).
- (void)openRow:(NSInteger)row;
/// Công cụ thử: chat ở dòng `row` (không mở chat — không đánh dấu đã đọc).
- (NSDictionary *)debugDialogAt:(NSInteger)row;
/// Chat theo khoá peer (nil nếu chưa có trong danh sách).
- (NSDictionary *)dialogForPeer:(NSString *)peer;
/// Tổng tin chưa đọc của các chat không tắt tiếng.
- (NSInteger)unreadTotal;
/// Mở chat (chạm thông báo). Danh sách chưa tải xong thì mở sau khi tải.
- (void)openPeer:(NSString *)peer;
/// Mở chat theo mục (khoá peer, tên, loại) — có thể chưa có trong danh sách; `msgId`: nhảy tới tin.
- (void)openChat:(NSDictionary *)item jumpTo:(NSNumber *)msgId;
/// Gỡ lỗi: tìm ở ô tìm kiếm; chạm kết quả.
- (void)debugSearch:(NSString *)q;
- (void)debugSearchTap:(NSInteger)s row:(NSInteger)r;
/// Thư mục chat đã tải (folders.list); số chat của một thư mục (lọc như Telegram gốc).
- (NSArray *)folders;
- (NSInteger)countInFolder:(NSDictionary *)folder;
/// Gỡ lỗi: chọn thẻ thư mục (0 = Tất cả).
- (void)debugFolder:(NSInteger)i;
/// Gỡ lỗi: mở bảng thao tác nhanh (như nhấn giữ) của hàng `row`.
- (void)debugActions:(NSInteger)row;
@end
