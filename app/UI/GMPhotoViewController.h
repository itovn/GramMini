#import <UIKit/UIKit.h>

/// Xem ảnh toàn màn hình (nền đen): ảnh nhỏ hiện ngay, ảnh lớn tải sau; chụm để phóng, chạm hai lần phóng / thu, chạm một
/// lần để đóng.
@interface GMPhotoViewController : UIViewController <UIScrollViewDelegate>
@property (nonatomic, copy) NSString *peer;
@property (nonatomic, strong) NSNumber *msgId;
/// Ảnh đang có (bản nhỏ trong bong bóng) — hiện trong lúc tải bản lớn.
@property (nonatomic, strong) UIImage *preview;
@end
