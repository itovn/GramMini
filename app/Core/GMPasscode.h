#import <UIKit/UIKit.h>

/// Khoá app bằng mật mã 4 số (kiểu Telegram 4.9). Lưu băm SHA-256 + muối trong `<dữ liệu>/passcode.plist` (0600) — không lưu
/// mật mã. Màn khoá nằm trên một UIWindow riêng (view controller gốc riêng → xoay đúng trên iPad iOS 5 / 6, che cả màn bật lên).
@interface GMPasscode : NSObject
+ (BOOL)enabled;
+ (BOOL)check:(NSString *)code;
/// nil = tắt mật mã.
+ (void)setCode:(NSString *)code;
/// Tự khoá sau khi rời app bao lâu (giây; 0 = ngay).
+ (NSInteger)autolock;
+ (void)setAutolock:(NSInteger)seconds;
+ (NSString *)autolockText:(NSInteger)seconds;

/// Mở app / quay lại app: khoá nếu đã bật (và đã quá thời gian tự khoá kể từ lúc rời app).
+ (void)lockAtLaunch;
+ (void)didEnterBackground;
+ (void)willEnterForeground;
+ (BOOL)isLocked;
/// Gỡ lỗi: nhập mật mã vào màn khoá đang hiện.
+ (void)debugEnter:(NSString *)code;
@end

typedef NS_ENUM(NSInteger, GMLockMode) {
    GMLockUnlock,   // mở khoá app
    GMLockSetNew,   // đặt mật mã mới (nhập 2 lần)
    GMLockVerify,   // xác nhận mật mã hiện tại (đổi / tắt mật mã)
};

/// Màn nhập mật mã: chữ hướng dẫn, 4 chấm, bàn phím số tự vẽ. Rung khi sai.
@interface GMLockViewController : UIViewController
- (instancetype)initWithMode:(GMLockMode)mode;
/// Xong: mở khoá / xác nhận đúng → code là mật mã đã nhập; huỷ (nút Huỷ, chế độ đặt / xác nhận) → nil.
@property (nonatomic, copy) void (^done)(NSString *code);
- (void)enterDigits:(NSString *)digits;
@end
