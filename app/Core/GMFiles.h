#import <Foundation/Foundation.h>

/// Tải tệp / video về máy (lõi: media.document, có sự kiện media.progress) — nhớ tệp đã tải, tiến độ đang tải. Đổi trạng
/// thái thì phát GMFileStateNotification (luồng chính).
@interface GMFiles : NSObject
+ (instancetype)shared;
/// Đường dẫn tệp đã tải (nil nếu chưa).
- (NSString *)pathFor:(NSString *)peer msg:(NSNumber *)msgId;
/// Tiến độ đang tải 0…1; -1 = không tải.
- (double)progressOf:(NSString *)peer msg:(NSNumber *)msgId;
/// Tải (nếu chưa có) rồi gọi done(path) — lỗi thì done(nil) và báo lỗi.
- (void)fetch:(NSString *)peer msg:(NSNumber *)msgId done:(void (^)(NSString *path))done;
/// Tệp mình vừa gửi (video đã nén…): chuyển vào bộ đệm dưới tên lõi dùng (`media/d<peer>_<id>.<đuôi>`) → mở lại khỏi tải.
- (void)adopt:(NSString *)file peer:(NSString *)peer msg:(NSNumber *)msgId;
/// Tệp mình vừa gửi từ bộ nhớ máy: nhớ đường dẫn gốc (không chép) — mở lại khỏi tải, tới khi tắt app / tệp gốc mất.
- (void)remember:(NSString *)file peer:(NSString *)peer msg:(NSNumber *)msgId;
@end

extern NSString *const GMFileStateNotification;
