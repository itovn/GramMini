#import <UIKit/UIKit.h>

/// Chọn một chat (chuyển tiếp tin tới…). Hiện dạng modal; picked(peer, name) gọi khi chọn, rồi tự đóng.
@interface GMPickChatViewController : UITableViewController
@property (nonatomic, copy) NSString *myId;
@property (nonatomic, copy) void (^picked)(NSString *peer, NSString *name);
/// Tiêu đề (mặc định «Chuyển tiếp tới…»); cho chọn cả kênh (mặc định bỏ kênh — không gửi được).
@property (nonatomic, copy) NSString *pickTitle;
@property (nonatomic) BOOL allowChannels;
@end
