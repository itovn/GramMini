#import <UIKit/UIKit.h>

/// Đính kèm → «Mã QR chuyển khoản» (như Roza): chọn ngân hàng, số tài khoản, chủ tài khoản, số tiền / nội dung (tuỳ chọn) → thẻ
/// có mã VietQR (app ngân hàng nào ở Việt Nam cũng quét được) → gửi như ảnh, kèm chú thích có số tài khoản để người nhận chép.
/// Tài khoản dùng lần trước được nhớ trên máy.
@interface GMVietQRViewController : UIViewController <UITextFieldDelegate>
@property (nonatomic, copy) void (^send)(UIImage *card, NSString *caption);
@end
