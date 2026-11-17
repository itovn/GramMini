#import <UIKit/UIKit.h>

@class GMChatListViewController, GMContactsViewController;

/// Bên phải (iPad) khi chưa mở cuộc trò chuyện nào: «Chọn một cuộc trò chuyện».
@interface GMEmptyDetailViewController : UIViewController
@end

/// Chat mở bên phải đổi (danh sách tô hàng đang mở).
extern NSString *const GMOpenChatChangedNotification;

@interface GMAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
/// Thanh dưới: Danh bạ / Chat / Cài đặt (mỗi mục một thanh điều hướng). `nav` = thanh điều hướng của mục Chat.
@property (nonatomic, strong) UITabBarController *tabs;
@property (nonatomic, strong) UINavigationController *nav;
@property (nonatomic, strong) GMContactsViewController *contacts;
@property (nonatomic, strong) GMChatListViewController *list;
/// iPad: màn chia đôi (gốc cửa sổ — iOS 5 / 6 bắt buộc) — bên trái thanh dưới như iPhone, bên phải `detail` (cuộc trò chuyện
/// đang mở). iPhone: nil.
@property (nonatomic, strong) UISplitViewController *split;
@property (nonatomic, strong) UINavigationController *detail;
/// iPad: đặt màn (chat, danh sách chủ đề) vào bên phải → YES; iPhone → NO (nơi gọi tự đẩy vào thanh điều hướng của mình).
- (BOOL)showDetail:(UIViewController *)vc;
/// iPad: khoá peer của chat đang mở bên phải (nil nếu chưa mở).
- (NSString *)openPeer;
/// iPad: chat `peer` đang mở bên phải (vd vừa rời / xoá) → về màn trống.
- (void)closeDetailFor:(NSString *)peer;
/// Đổi chế độ sáng / tối: áp lại giao diện, dựng lại màn (giữ mục đang chọn của thanh dưới).
- (void)reloadTheme;
/// Hiện màn đăng nhập (nút «Đăng nhập» của danh sách chat khi chưa đăng nhập).
- (void)showLogin;
/// Người dùng đóng màn đăng nhập (đăng nhập sau).
- (void)loginClosed;
@end
