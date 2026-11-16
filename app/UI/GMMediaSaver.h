#import <UIKit/UIKit.h>

/// Lưu ảnh / video của tin vào Thư viện ảnh của máy (nhấn giữ → «Lưu», màn xem ảnh). Lần đầu iOS 6 hỏi quyền truy cập Ảnh.
/// Báo kết quả bằng thông báo nhỏ trong `view`.
@interface GMMediaSaver : NSObject
/// Ảnh của tin (bản gốc lớn nhất).
+ (void)savePhotoOf:(NSString *)peer msg:(NSNumber *)msgId in:(UIView *)view;
/// Tệp của tin: video / GIF / video tròn → video; ảnh gửi dạng tệp → ảnh.
+ (void)saveFileOf:(NSString *)peer msg:(NSNumber *)msgId in:(UIView *)view;
@end
