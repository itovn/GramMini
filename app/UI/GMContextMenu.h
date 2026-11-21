#import <UIKit/UIKit.h>

/// Một mục menu: tên, biểu tượng (tên trong +[GMTheme icon:color:]), chữ đỏ (xoá), mục đầu một nhóm mới, việc khi chạm.
@interface GMMenuItem : NSObject
@property (nonatomic, copy) NSString *title, *icon;
@property (nonatomic) BOOL destructive, startsGroup;
@property (nonatomic, copy) void (^action)(void);
+ (instancetype)title:(NSString *)title icon:(NSString *)icon action:(void (^)(void))action;
@end

/// Menu giữ tin kiểu iOS 26 / Telegram (D37): nền màn chụp một lần rồi làm mờ (vImage — iOS 5 có; máy RAM ≤ 256 MB chỉ phủ tối),
/// tin được nhấc lên (ảnh chụp của bong bóng), hàng cảm xúc viên kính phía trên, menu kính chia nhóm phía dưới. Chạm ngoài → đóng.
@interface GMContextMenu : UIView
/// `host`: view phủ lên (thanh điều hướng của màn chat — phủ cả thanh trên); `source`: bong bóng / sticker được nhấc; `outgoing`:
/// canh menu theo mép phải. `emojis` rỗng = không có hàng cảm xúc; `more`: nút mở bảng đủ cảm xúc (nil = không có).
+ (GMContextMenu *)showIn:(UIView *)host source:(UIView *)source outgoing:(BOOL)outgoing emojis:(NSArray *)emojis
                   chosen:(NSString *)chosen items:(NSArray *)items react:(void (^)(NSString *emoji))react
                     more:(void (^)(void))more;
- (void)dismiss;
/// Ảnh nền mờ của `host` (chụp 1/4 cỡ, làm mờ vImage) — nil trên máy yếu (chỉ phủ tối). Dùng chung cho bảng đính kèm.
+ (UIImage *)blurredSnapshot:(UIView *)host;
/// Gỡ lỗi: chạm mục thứ `i` (đếm từ 0).
- (void)debugTap:(NSInteger)i;
@end
