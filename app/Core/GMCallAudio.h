#import <Foundation/Foundation.h>

/// Âm thanh cuộc gọi thoại (D38, G3): AudioUnit VoiceProcessingIO (khử vọng + tự chỉnh mức của iOS), 48 kHz 16 bit đơn kênh —
/// như libtgvoip (Telegram cũ, chạy trên iOS 6). Micro → gm_voip_push, gm_voip_pull → loa (lõi Rust: gm_call::tg::io).
@interface GMCallAudio : NSObject
+ (GMCallAudio *)shared;
/// Mở phiên âm thanh gọi thoại (PlayAndRecord / VoiceChat) + chạy AudioUnit. NO nếu lỗi (xem GMLog).
- (BOOL)start;
- (void)stop;
@property (nonatomic, readonly) BOOL running;
/// Loa ngoài (mặc định loa trong — áp tai, bật cảm biến tiệm cận).
@property (nonatomic) BOOL speaker;
/// Tiếng chờ «tút» 425 Hz (1 giây kêu / 4 giây nghỉ) khi máy bên kia đang đổ chuông — phát qua chính đường gọi (loa trong /
/// ngoài) lúc lõi chưa có tiếng.
@property (nonatomic) BOOL ringback;
@end
