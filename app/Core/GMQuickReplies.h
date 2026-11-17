#import <Foundation/Foundation.h>

/// Tin nhắn nhanh (mẫu câu tự đặt, như Roza / Zalo): gõ «/từ khoá» trong ô nhập → chọn → chữ mẫu thay vào ô nhập. Lưu trên máy
/// (NSUserDefaults) — Telegram chỉ đồng bộ tin nhắn nhanh cho tài khoản doanh nghiệp (Premium).
@interface GMQuickReplies : NSObject
/// [{k: từ khoá (không có «/»), t: chữ}] theo thứ tự từ khoá.
+ (NSArray *)all;
/// Thêm / sửa (cùng từ khoá thì thay). Từ khoá: chữ thường, bỏ «/» và khoảng trắng.
+ (void)save:(NSString *)keyword text:(NSString *)text;
+ (void)remove:(NSString *)keyword;
+ (NSString *)normalize:(NSString *)keyword;
@end
