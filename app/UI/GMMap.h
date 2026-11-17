#import <UIKit/UIKit.h>

// Bản đồ: MapKit trên iOS 5 / 6 không còn máy chủ ô (chỉ hiện lưới trống) → ảnh bản đồ do Telegram vẽ (lõi: map.static qua
// upload.getWebFile — máy chủ bản đồ bên thứ ba không thấy IP / chỗ đang xem, như app chính thức; một ảnh vừa khung mỗi lần
// dừng tay). Địa chỉ: chỉ khi người dùng chạm dòng địa chỉ (Nominatim của OSM — map.address; Telegram không có dịch vụ tra địa
// chỉ). Chuyển từ Roza.

/// Màn bản đồ: xem một vị trí (kéo / phóng, «Mở…»: chép toạ độ, mở Google Maps) hoặc chọn vị trí để gửi (định vị máy, kéo để
/// chọn chỗ khác, «Gửi vị trí này»).
@interface GMMapViewController : UIViewController <UIActionSheetDelegate>
- (instancetype)initWithLat:(double)lat lng:(double)lng title:(NSString *)title;
/// `address`: địa chỉ có sẵn trong tin địa điểm (khỏi tra).
- (instancetype)initWithLat:(double)lat lng:(double)lng title:(NSString *)title address:(NSString *)address;
- (instancetype)initPickerWithDone:(void (^)(double lat, double lng))done;
/// Công cụ thử: như chạm dòng địa chỉ (tra địa chỉ của điểm giữa); phóng to / nhỏ `d` mức.
- (void)debugAddress;
- (void)debugZoom:(NSInteger)d;
- (void)debugPanX:(CGFloat)x y:(CGFloat)y end:(BOOL)end;
@end

/// Ảnh bản đồ nhỏ (Telegram vẽ — `hash` = access_hash của điểm trong tin, ghim ở giữa, tên địa điểm ở dưới nếu có) cho bong
/// bóng tin vị trí — có bộ đệm trong bộ nhớ.
UIImage *GMMapSnapshotCached(double lat, double lng, CGSize size);
void GMMapSnapshot(double lat, double lng, NSString *hash, CGSize size, NSString *title, void (^done)(UIImage *img));
