#import <UIKit/UIKit.h>

/// Bảng sticker / GIF ở chỗ bàn phím (cao 216): hàng thẻ (Gần đây, GIF, từng bộ sticker đã cài) + lưới (sticker 5 cột trên
/// iPhone, GIF 3 cột). Chạm → `pick(mục)` (mục: doc, mime, emoji…; gửi bằng lõi `messages.sendDoc`). Tải lần đầu khi mở.
@interface GMStickerPanel : UIView
@property (nonatomic, copy) void (^pick)(NSDictionary *doc);
/// Nút «+» cuối dải thẻ: mở màn Sticker (thêm / gỡ bộ).
@property (nonatomic, copy) void (^manage)(void);
- (void)reloadIfNeeded;
/// Gỡ lỗi: chọn thẻ / chạm sticker thứ i của thẻ đang mở.
- (void)debugTab:(NSInteger)i;
- (void)debugPick:(NSInteger)i;
@end

extern const CGFloat kGMStickerPanelH;
