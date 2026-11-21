#import <Foundation/Foundation.h>

/// Điều phối cuộc gọi thoại phía app (D38): nghe sự kiện `call.state` / `call.quality` của lõi, hiện màn cuộc gọi
/// (GMCallViewController), bật / tắt âm thanh (GMCallAudio), chuông + rung khi có cuộc gọi đến, tiếng chờ khi máy bên kia đổ
/// chuông, thông báo khi app ở nền (cuộc gọi đến / nhỡ).
@interface GMCallManager : NSObject
+ (GMCallManager *)shared;
/// Gắn vào sự kiện lõi (gọi một lần lúc mở app).
- (void)attach;
/// Gọi một người: `chat` = hội thoại riêng trong danh sách chat (peer, name, photo…).
- (void)callChat:(NSDictionary *)chat;
/// Gọi theo khoá peer (tên / ảnh tra trong danh sách chat).
- (void)callPeer:(NSString *)peer;
- (void)accept;
/// Từ chối cuộc gọi đến (báo «bận»).
- (void)decline;
- (void)hangup;
- (void)setMuted:(BOOL)muted;
- (void)setSpeaker:(BOOL)speaker;
/// Đang có cuộc gọi (chưa kết thúc).
@property (nonatomic, readonly) BOOL active;
/// Trạng thái gần nhất (userInfo của sự kiện `call.state`) hoặc nil.
@property (nonatomic, readonly) NSDictionary *state;
@end
