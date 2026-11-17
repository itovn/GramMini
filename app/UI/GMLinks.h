#import <UIKit/UIKit.h>

/// Link Telegram mở ngay trong app — máy iOS 5 / 6 không có app Telegram, mở bằng Safari là ngõ cụt:
/// t.me/<tên> (+ /<tin>: nhảy tới tin), @tên, t.me/c/<kênh>/<tin>, link mời t.me/+… / joinchat (hỏi «Tham gia»), tg://resolve,
/// tg://join, tg://user. Link proxy / bộ sticker do màn chat tự lo; link khác → Safari.
@interface GMLinks : NSObject
/// Link mở chat được (không gồm proxy, bộ sticker).
+ (BOOL)isTelegramLink:(NSString *)link;
/// Mở link: Telegram → chat / hỏi tham gia; khác → Safari. `view`: chỗ hiện thông báo lỗi.
+ (void)open:(NSString *)link in:(UIView *)view;
/// Mở link web bằng Safari (thêm http:// nếu thiếu).
+ (void)openWeb:(NSString *)link;
@end
