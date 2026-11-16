#import <Foundation/Foundation.h>

/// Phát tin thoại (lõi giải mã OGG/Opus → WAV — media.voice; AVAudioPlayer phát). Một tin một lúc. Đổi trạng thái / tiến độ
/// thì phát GMVoiceStateNotification (luồng chính).
@interface GMVoicePlayer : NSObject
+ (instancetype)shared;
/// Chạm nút phát của tin (peer, id): đang phát tin đó thì tạm dừng / phát tiếp; tin khác thì tải rồi phát.
- (void)toggle:(NSString *)peer msg:(NSNumber *)msgId;
- (void)stop;
/// Trạng thái của một tin: 0 = dừng, 1 = đang tải / giải mã, 2 = đang phát, 3 = tạm dừng.
- (NSInteger)stateOf:(NSString *)peer msg:(NSNumber *)msgId;
/// Tiến độ (0…1) và thời điểm (giây) của tin đang phát / tạm dừng; tin khác trả 0.
- (double)progressOf:(NSString *)peer msg:(NSNumber *)msgId;
- (double)timeOf:(NSString *)peer msg:(NSNumber *)msgId;
@end

extern NSString *const GMVoiceStateNotification;
