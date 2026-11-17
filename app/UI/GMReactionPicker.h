#import <UIKit/UIKit.h>

/// Bảng chọn cảm xúc nổi trên màn chat (nhấn giữ tin → «Cảm xúc»): lưới emoji trên nền kính bo tròn, ngay trên (hoặc dưới)
/// bong bóng; chạm ra ngoài để đóng. Emoji mình đang thả có nền màu — chạm lại = gỡ (`pick(nil)`).
@interface GMReactionPicker : UIView
+ (GMReactionPicker *)showIn:(UIView *)view near:(CGRect)anchor emojis:(NSArray *)emojis chosen:(NSString *)chosen
                        pick:(void (^)(NSString *emoji))pick;
/// Công cụ thử: chạm emoji thứ i.
- (void)tapIndex:(NSInteger)i;
- (void)dismiss;
/// Đóng bảng đang mở (nếu có).
+ (void)dismissShown;
@end
