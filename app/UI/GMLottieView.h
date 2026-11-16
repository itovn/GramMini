#import <UIKit/UIKit.h>

/// Phát sticker động TGS (Lottie): lõi Rust vẽ từng khung (gm_lottie_render, crate gm-lottie) ở một hàng đợi nền dùng chung,
/// ảnh khung đặt vào layer.contents. Lặp liên tục khi đang hiện trên màn hình và app đang mở; tạm dừng khi cuộn (đồng hồ chỉ chạy
/// ở chế độ mặc định của run loop), khi rời cửa sổ. Tối đa 30 khung / giây, cỡ vẽ = cỡ view × độ phân giải màn, tối đa 256 px.
@interface GMLottieView : UIView
/// Mở tệp .tgs và phát. Gọi lại với tệp khác thì đổi hoạt hình.
- (void)playFile:(NSString *)path;
/// Dừng, bỏ hoạt hình (ô dùng lại).
- (void)stop;
/// Gọi một lần khi khung đầu đã hiện (để ẩn ảnh tĩnh phía dưới).
@property (nonatomic, copy) void (^firstFrame)(void);
/// Tệp đang phát (nil nếu chưa).
@property (nonatomic, readonly, copy) NSString *path;
@end
