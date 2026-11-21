#import <UIKit/UIKit.h>

/// Loại đính kèm chọn ở bảng (GMAttachSheet).
typedef NS_ENUM(NSInteger, GMAttachKind) {
    GMAttachCamera,    // chụp ảnh
    GMAttachLibrary,   // thư viện ảnh / video của iOS (UIImagePickerController)
    GMAttachFile,      // tệp trên máy
    GMAttachLocation,  // vị trí
    GMAttachQR,        // mã QR chuyển khoản
    GMAttachContact,   // danh thiếp
};

/// Bảng đính kèm kiểu iOS 26 / Telegram (D37): nền màn làm mờ, tấm kính nổi ở đáy — «Gần đây ▾» (chạm: thư viện đủ của iOS),
/// lưới ảnh gần đây trong máy (ALAssetsLibrary; ô đầu là máy ảnh), chạm một ảnh → chọn, nút «Gửi ảnh»; thanh dưới viên kính:
/// Thư viện · Tệp · Vị trí · Mã QR · Danh thiếp. iOS 6 hỏi quyền truy cập Ảnh lần đầu — không cho thì lưới báo cách bật.
@interface GMAttachSheet : UIView
+ (GMAttachSheet *)showIn:(UIView *)host camera:(BOOL)camera pick:(void (^)(GMAttachKind kind))pick
                    photo:(void (^)(UIImage *image))photo;
- (void)dismiss;
/// Gỡ lỗi: chọn ảnh thứ `i` của lưới (đếm từ 0, không tính ô máy ảnh); bấm «Gửi ảnh».
- (void)debugSelect:(NSInteger)i;
- (void)debugSend;
@end
