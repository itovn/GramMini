#import <UIKit/UIKit.h>

// Bản đồ: MapKit trên iOS 5 / 6 không còn máy chủ ô (chỉ hiện lưới trống) → tự ghép ô OpenStreetMap do lõi tải (map.tile),
// địa chỉ tra bằng Nominatim của OSM (map.address). Chuyển từ Roza (RZLocation).

/// Màn bản đồ: xem một vị trí (kéo / phóng, «Mở…»: chép toạ độ, mở Google Maps) hoặc chọn vị trí để gửi (định vị máy, kéo để
/// chọn chỗ khác, «Gửi vị trí này»).
@interface GMMapViewController : UIViewController <UIActionSheetDelegate>
- (instancetype)initWithLat:(double)lat lng:(double)lng title:(NSString *)title;
- (instancetype)initPickerWithDone:(void (^)(double lat, double lng))done;
@end

/// Ảnh bản đồ nhỏ (ghép ô OSM, ghim ở giữa, tên địa điểm ở dưới nếu có) cho bong bóng tin vị trí — có bộ đệm trong bộ nhớ.
UIImage *GMMapSnapshotCached(double lat, double lng, CGSize size);
void GMMapSnapshot(double lat, double lng, CGSize size, NSString *title, void (^done)(UIImage *img));
