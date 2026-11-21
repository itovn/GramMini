#import <UIKit/UIKit.h>

/// Màn cuộc gọi thoại (D38, G4): nền màu theo người bên kia, ảnh đại diện, tên, trạng thái / đồng hồ + vạch sóng, 4 emoji khoá
/// trong viên kính. Đang gọi / đang nói: Loa ngoài · Tắt micro · Kết thúc. Cuộc gọi đến: Từ chối · Nghe.
@interface GMCallViewController : UIViewController
/// `chat`: hội thoại của người bên kia trong danh sách chat (tên, ảnh) — có thể nil.
- (instancetype)initWithChat:(NSDictionary *)chat;
/// Sự kiện `call.state` mới nhất.
- (void)update:(NSDictionary *)state;
/// Vạch sóng 0…4 (sự kiện `call.quality`).
- (void)setBars:(NSInteger)bars;
@end
