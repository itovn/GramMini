#import <Foundation/Foundation.h>

/// Chuyển video H.265 (HEVC — iOS 5 / 6 chỉ phát được tiếng) sang H.264 ngay trên máy: lõi (gm-hevc: FFmpeg giải mã, NEON, giải
/// song song theo khung) đưa từng khung NV12 đã thu nhỏ (cạnh ngắn ≤ 480) → AVAssetWriter mã H.264 bằng phần cứng; tiếng đọc
/// bằng AVAssetReader (PCM) rồi mã lại AAC. Giữ ma trận xoay (video dọc). Chạy ở hàng đợi nền; xong mới thay tệp đích.
@interface GMHevcTranscoder : NSObject
/// Bắt đầu chuyển `src` → `dst` (ghi tệp tạm, xong thì chuyển vào `dst`, ghi đè). `progress` 0…1 và `done` chạy ở luồng chính;
/// `done(NO, câu lỗi)` khi lỗi / bị dừng.
+ (instancetype)transcode:(NSString *)src to:(NSString *)dst progress:(void (^)(double fraction))progress
                     done:(void (^)(BOOL ok, NSString *error))done;
/// Dừng (xoá tệp tạm, `done(NO, @"Đã dừng")`).
- (void)cancel;
@end
