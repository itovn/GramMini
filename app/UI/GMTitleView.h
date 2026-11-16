#import <UIKit/UIKit.h>

/// Tiêu đề hai dòng trên thanh điều hướng (tên + dòng phụ: «đang kết nối…»), kèm vòng quay khi đang kết nối.
@interface GMTitleView : UIView
@property (nonatomic, copy) NSString *title;
/// Dòng phụ (nil = không có, tên nằm giữa).
@property (nonatomic, copy) NSString *subtitle;
/// Đang kết nối: hiện vòng quay + «Đang kết nối…» thay cho tiêu đề (danh sách chat) hoặc dòng phụ (màn chat).
@property (nonatomic) BOOL connecting;
/// YES: «Đang kết nối…» thay cho tiêu đề (kiểu danh sách chat của Telegram); NO: thay dòng phụ.
@property (nonatomic) BOOL replaceTitle;
@end
