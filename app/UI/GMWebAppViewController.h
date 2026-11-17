#import <UIKit/UIKit.h>

/// Mini app của bot mở ngay trong app (UIWebView), không ra Safari: link có dữ liệu đăng nhập Telegram (`#tgWebAppData=…`)
/// không nằm lại trong lịch sử / tab của Safari mà ở sau khoá mật mã của app (kiểm bảo mật 17/11/2026). Trình duyệt của iOS 5 / 6
/// cũ — trang viết cho máy mới có thể không chạy.
@interface GMWebAppViewController : UIViewController <UIWebViewDelegate>
- (instancetype)initWithURL:(NSURL *)url title:(NSString *)title;
/// Mở trong khung bật lên (iPad: khung giữa màn) từ `from`.
+ (void)present:(NSURL *)url title:(NSString *)title from:(UIViewController *)from;
@end
