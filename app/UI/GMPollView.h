#import <UIKit/UIKit.h>

/// Bình chọn trong bong bóng tin: câu hỏi, loại (ẩn danh / công khai / câu đố, nhiều lựa chọn), các lựa chọn. Chưa bỏ phiếu:
/// vòng tròn — chạm để chọn (nhiều lựa chọn: đánh dấu rồi «Bỏ phiếu»). Đã bỏ phiếu / đã đóng: phần trăm + thanh, ✓ lựa chọn của
/// mình (câu đố: đúng xanh, sai đỏ), số người đã bình chọn, «Rút phiếu».
@interface GMPollView : UIView
/// Bỏ phiếu: mảng mã lựa chọn (hex); mảng rỗng = rút phiếu.
@property (nonatomic, copy) void (^vote)(NSArray *options);
/// Nhiều lựa chọn: chọn / bỏ chọn một lựa chọn trước khi bấm «Bỏ phiếu».
@property (nonatomic, copy) void (^toggle)(NSString *option);
+ (CGFloat)heightFor:(NSDictionary *)poll width:(CGFloat)w;
- (void)showPoll:(NSDictionary *)poll selected:(NSSet *)selected tint:(UIColor *)tint;
@end

/// Đã bỏ phiếu (có lựa chọn của mình trong kết quả).
BOOL GMPollVoted(NSDictionary *poll);
