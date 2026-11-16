#import <UIKit/UIKit.h>

@class GMChatListViewController, GMContactsViewController;

@interface GMAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
/// Thanh dưới: Danh bạ / Chat / Cài đặt (mỗi mục một thanh điều hướng). `nav` = thanh điều hướng của mục Chat.
@property (nonatomic, strong) UITabBarController *tabs;
@property (nonatomic, strong) UINavigationController *nav;
@property (nonatomic, strong) GMContactsViewController *contacts;
@property (nonatomic, strong) GMChatListViewController *list;
/// Đổi chế độ sáng / tối: áp lại giao diện, dựng lại màn (giữ mục đang chọn của thanh dưới).
- (void)reloadTheme;
/// Hiện màn đăng nhập (nút «Đăng nhập» của danh sách chat khi chưa đăng nhập).
- (void)showLogin;
/// Người dùng đóng màn đăng nhập (đăng nhập sau).
- (void)loginClosed;
@end
