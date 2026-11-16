#import <UIKit/UIKit.h>

/// Tìm kiếm dùng chung (UISearchDisplayController — có từ iOS 3): ba nhóm kết quả
///   1. trên máy (`local`: lọc ngay — chat đã có / danh bạ, không phân biệt dấu),
///   2. «Trên Telegram» (lõi `contacts.search`: người / nhóm / kênh theo tên, @tên — bỏ trùng nhóm 1),
///   3. «Tin nhắn» (lõi `messages.search`, khi `messages` = YES).
/// Nhóm 2, 3 hỏi máy chủ sau 0,4 giây ngừng gõ. Chạm kết quả → `pick(mục, id tin hoặc nil)`.
@interface GMSearchController : NSObject <UISearchDisplayDelegate, UITableViewDataSource, UITableViewDelegate>
- (instancetype)initWithSearchBar:(UISearchBar *)bar contents:(UIViewController *)vc;
@property (nonatomic, readonly) UISearchDisplayController *display;
@property (nonatomic, copy) NSArray *(^local)(NSString *query);
@property (nonatomic, copy) NSString *localTitle;
@property (nonatomic) BOOL messages;
@property (nonatomic, copy) NSString *myId;
@property (nonatomic, copy) void (^pick)(NSDictionary *item, NSNumber *msgId);
/// Gỡ lỗi: tìm `q` (hiện bảng kết quả); chạm hàng.
- (void)debugSearch:(NSString *)q;
- (void)debugTapSection:(NSInteger)s row:(NSInteger)r;
@end

/// Chuỗi khớp `q` không phân biệt hoa / thường, dấu tiếng Việt («lan» khớp «Lan», «co lan» khớp «Cô Lan»).
BOOL GMMatches(NSString *text, NSString *q);
/// Ô kiểu danh sách người (ảnh tròn 40, tên, dòng phụ) — dùng chung cho tìm kiếm / danh bạ.
UITableViewCell *GMPeerCell(UITableView *tv, NSDictionary *item, NSString *detail, NSString *myId);
