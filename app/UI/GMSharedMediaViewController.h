#import <UIKit/UIKit.h>

/// Đã chia sẻ trong một chat (lõi `messages.media`): ảnh / video dạng lưới 4 cột (iOS 5 chưa có UICollectionView — ghép bằng
/// bảng), tệp / tin thoại / liên kết dạng danh sách. Cuộn tới cuối thì tải thêm. Chạm ảnh → xem ảnh; video → phát; tệp, tin
/// thoại → mở chat ở tin đó; liên kết → Safari.
@interface GMSharedMediaViewController : UITableViewController
@property (nonatomic, copy) NSString *peer, *kind, *myId, *chatName;
@end
