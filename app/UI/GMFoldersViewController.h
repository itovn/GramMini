#import <UIKit/UIKit.h>

/// Thư mục chat vừa tạo / sửa / xoá / đổi thứ tự — danh sách chat tải lại thư mục.
extern NSString *const GMFoldersChangedNotification;

/// Cài đặt → Thư mục chat (như Telegram gốc, đồng bộ với tài khoản): danh sách thư mục (chạm để sửa; Sửa → xoá, kéo đổi thứ
/// tự), «Tạo thư mục mới», thư mục gợi ý của Telegram (Thêm ngay).
@interface GMFoldersViewController : UITableViewController
@end

/// Tạo / sửa một thư mục: tên; đưa vào theo loại chat (danh bạ, không trong danh bạ, nhóm, kênh, bot) + từng chat; loại trừ (đã
/// tắt tiếng, đã đọc, lưu trữ) + từng chat; xoá thư mục.
@interface GMFolderEditViewController : UITableViewController
/// Thư mục đang sửa (nil = tạo mới).
@property (nonatomic, copy) NSDictionary *folder;
@end
