#import <UIKit/UIKit.h>

/// Ảnh: tải qua lõi (media.photo / media.avatar → tệp đệm trên đĩa), giải mã + thu nhỏ đúng cỡ hiển thị bằng ImageIO ở hàng
/// nền ưu tiên thấp (A4 một nhân: giải mã nhiều ảnh cùng lúc làm treo luồng chính — bài học Côn Bằng TV), bộ đệm RAM nhỏ
/// (8 MB khi máy < 300 MB RAM). done() luôn trên luồng chính; ảnh đã có trong bộ đệm thì gọi ngay.
@interface GMImages : NSObject
/// Ảnh đại diện tròn (cỡ `size` điểm). Không có ảnh (photo nil) hoặc tải lỗi thì không gọi done.
+ (void)avatarForPeer:(NSString *)peer photo:(NSString *)photo dc:(NSNumber *)dc size:(CGFloat)size done:(void (^)(UIImage *img))done;
/// Ảnh trong tin: cỡ vừa (bong bóng) hoặc cỡ lớn (trình xem); maxPixel = cạnh dài nhất sau khi thu nhỏ (pixel).
+ (void)photoForPeer:(NSString *)peer msg:(NSNumber *)msgId big:(BOOL)big maxPixel:(CGFloat)maxPixel
                done:(void (^)(UIImage *img))done;
/// Sticker (PNG lõi đổi từ WebP; sticker động: ảnh thu nhỏ).
+ (void)stickerForPeer:(NSString *)peer msg:(NSNumber *)msgId maxPixel:(CGFloat)maxPixel done:(void (^)(UIImage *img))done;
+ (UIImage *)cachedStickerForPeer:(NSString *)peer msg:(NSNumber *)msgId;
/// Ảnh xem trước sticker / GIF trong bảng sticker (lõi `media.docpreview`, đệm `media/k<mã>.png`).
+ (void)docPreview:(NSString *)doc maxPixel:(CGFloat)maxPixel done:(void (^)(UIImage *))done;
/// Ảnh xem trước của video / tệp (media.thumb).
+ (void)thumbForPeer:(NSString *)peer msg:(NSNumber *)msgId maxPixel:(CGFloat)maxPixel done:(void (^)(UIImage *img))done;
+ (UIImage *)cachedThumbForPeer:(NSString *)peer msg:(NSNumber *)msgId;
/// Ảnh đã có trong bộ đệm RAM (nil nếu chưa).
+ (UIImage *)cachedPhotoForPeer:(NSString *)peer msg:(NSNumber *)msgId big:(BOOL)big;
/// Ảnh mờ thu nhỏ (JPEG base64 lõi gửi kèm tin).
+ (UIImage *)imageFromBase64:(NSString *)b64;
/// Thiếu bộ nhớ: xoá bộ đệm RAM.
+ (void)purge;
@end
