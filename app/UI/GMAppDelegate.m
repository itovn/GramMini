#import "GMAppDelegate.h"
#import <QuartzCore/QuartzCore.h>
#import "GMBackground.h"
#import "GMPasscode.h"
#import "GMChatListViewController.h"
#import "GMChatViewController.h"
#import "GMTopicsViewController.h"
#import "GMContactsViewController.h"
#import "GMCompat.h"
#import "GMCore.h"
#import "GMLog.h"
#import "GMLoginViewController.h"
#import "GMSettingsViewController.h"
#import "GMTheme.h"
#import "GMUpdate.h"
#import "GMLinks.h"
#import "GMProxyViewController.h"
#ifdef DEBUG
#import "GMDebug.h"
#endif

NSString *const GMOpenChatChangedNotification = @"GMOpenChatChanged";

@implementation GMEmptyDetailViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [GMTheme background];
    [self.view addSubview:[[GMWallpaperView alloc] initWithFrame:self.view.bounds]];
    CGRect b = self.view.bounds;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(floor((b.size.width - 300) / 2), floor((b.size.height - 90) / 2) - 20, 300, 90)];
    box.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                           UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    // Viên kính (D37) trên hình nền
    UIImageView *glass = [[UIImageView alloc] initWithFrame:CGRectInset(box.bounds, -1, -1)];
    glass.image = [GMTheme glassImage:44];
    [box addSubview:glass];
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(10, 14, 280, 24)];
    t.text = @"Chọn một cuộc trò chuyện";
    t.font = [UIFont boldSystemFontOfSize:18];
    t.textColor = [GMTheme text];
    t.textAlignment = GMAlignCenter;
    t.backgroundColor = [UIColor clearColor];
    [box addSubview:t];
    UILabel *s = [[UILabel alloc] initWithFrame:CGRectMake(10, 40, 280, 40)];
    s.text = @"Chạm một chat ở bên trái, hoặc nút soạn tin để nhắn cho người mới.";
    s.font = [UIFont systemFontOfSize:14];
    s.textColor = [GMTheme secondaryText];
    s.numberOfLines = 2;
    s.textAlignment = GMAlignCenter;
    s.backgroundColor = [UIColor clearColor];
    [box addSubview:s];
    [self.view addSubview:box];
}

@end

@interface GMAppDelegate () <UIAlertViewDelegate, UISplitViewControllerDelegate>
@end

@implementation GMAppDelegate {
    BOOL _loginShown, _deadShown;
    BOOL _resuming;  // đang từ nền ra trước (willEnterForeground → didBecomeActive) — chạm thông báo
    NSString *_pendingURL;  // link tg:// tới lúc màn khoá đang hiện — mở sau khi nhập đúng mật mã
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    GMLog(@"=== GramMini %@ — iOS %@%@, RAM %.0f MB", version, [UIDevice currentDevice].systemVersion,
          GMOldIOS() ? @" (kiểu iOS 5)" : @"", [NSProcessInfo processInfo].physicalMemory / 1048576.0);
    [GMTheme apply];
    [[GMBackground shared] start];  // trước khi lõi mở socket (sự kiện net.socket)
    BOOL started = [GMCore start];

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    [self buildUI];
    [self.window makeKeyAndVisible];
    [GMBackground shared].list = self.list;
    [GMPasscode lockAtLaunch];  // có mật mã: khoá ngay từ lúc mở
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(unlocked) name:GMPasscodeUnlockedNotification object:nil];
    // Mở app bằng cách chạm thông báo (app đã bị tắt): mở chat đó khi danh sách tải xong
    UILocalNotification *ln = [launchOptions objectForKey:UIApplicationLaunchOptionsLocalNotificationKey];
    if (ln) [self.list openPeer:[ln.userInfo objectForKey:@"peer"]];
    if (application.applicationState == UIApplicationStateBackground) GMLog(@"iOS mở app ở nền (chế độ VoIP)");

    if (!started) {
        [[[UIAlertView alloc] initWithTitle:@"Không mở được lõi" message:@"Xem app.log trong ~/Library/GramMini." delegate:nil
                          cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
        return YES;
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(event:) name:GMCoreEventNotification object:nil];
    [self checkAuth];
    [GMUpdate start];  // kiểm bản mới (OTA) sau 10 giây, khi quay lại app tối đa 6 giờ một lần
#ifdef DEBUG
    [GMDebug start];
#endif
    return YES;
}

- (void)checkAuth {
    [GMCore call:@"auth.state" args:nil done:^(id ok, NSDictionary *err) {
        if (err) {
            GMLog(@"auth.state lỗi: %@", GMErrorText(err));
            // Mạng lỗi (bị chặn?): vẫn cho vào danh sách; nút làm mới / Cài đặt → Proxy
            [self.list reload];
            return;
        }
        if ([GMVal(ok, @"authorized") boolValue]) {
            self.list.myId = self.contacts.myId = GMVal(GMVal(ok, @"me"), @"id");
            [self.list reload];
        } else if ([GMVal(ok, @"dead") boolValue]) {
            [self showDead];
        } else {
            [self showLogin];
        }
    }];
}

- (void)loginClosed {
    _loginShown = NO;
    self.list.loggedOut = YES;
}

- (void)showLogin {
    if (_loginShown) return;
    _loginShown = YES;
    self.list.loggedOut = YES;
    UINavigationController *n = [[UINavigationController alloc] initWithRootViewController:[[GMLoginViewController alloc] init]];
    [self.tabs presentViewController:n animated:YES completion:nil];
}

/// Telegram huỷ phiên (auth key dùng trùng ở hai nơi / bị thu hồi): lõi đã dời tệp phiên; auth key cũ còn trong lõi đang chạy
/// không dùng được nữa → mở lại app (lõi mới, phiên trống) rồi đăng nhập.
- (void)showDead {
    if (_deadShown) return;
    _deadShown = YES;
    GMLog(@"phiên bị Telegram huỷ — chờ mở lại app để đăng nhập");
    [[[UIAlertView alloc] initWithTitle:@"Cần đăng nhập lại"
                                message:@"Telegram đã huỷ phiên đăng nhập của GramMini trên máy này (cùng một phiên bị dùng ở hai nơi "
                                        @"một lúc). Tài khoản của bạn vẫn bình thường. Bấm «Mở lại» rồi chạm biểu tượng "
                                        @"GramMini để đăng nhập."
                               delegate:self cancelButtonTitle:nil otherButtonTitles:@"Mở lại", nil] show];
}

- (void)alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex {
    if (_deadShown) exit(0);  // lần mở sau: lõi mới, chưa có phiên → màn đăng nhập
}

- (void)event:(NSNotification *)n {
    if ([GMVal(n.userInfo, @"e") isEqual:@"auth.dead"]) {
        [self showDead];
        return;
    }
    if (![GMVal(n.userInfo, @"e") isEqual:@"auth.state"]) return;
    if ([GMVal(n.userInfo, @"dead") boolValue]) return;  // đã báo qua auth.dead
    if ([GMVal(n.userInfo, @"authorized") boolValue]) {
        // Lúc mở app lõi cũng báo «đã đăng nhập» — checkAuth đã lo; chỉ tải lại khi vừa đăng nhập xong
        if (!_loginShown) return;
        _loginShown = NO;
        self.list.loggedOut = NO;
        [GMCore call:@"auth.state" args:nil done:^(id ok, NSDictionary *err) {
            self.list.myId = self.contacts.myId = GMVal(GMVal(ok, @"me"), @"id");
            [self.list reload];
        }];
    } else {
        [self showLogin];
    }
}

- (void)buildUI {
    self.window.backgroundColor = [GMTheme background];
    NSString *myId = self.list.myId;
    NSUInteger tab = self.tabs ? self.tabs.selectedIndex : 1;
    self.list = [[GMChatListViewController alloc] initWithStyle:UITableViewStylePlain];
    self.list.myId = myId;
    self.nav = [[UINavigationController alloc] initWithRootViewController:self.list];
    self.nav.tabBarItem = [GMTheme tabItem:@"Chat" icon:@"chats"];
    // Danh bạ: chạm một người → mở chat bên mục Chat
    self.contacts = [[GMContactsViewController alloc] initWithStyle:UITableViewStylePlain];
    self.contacts.tabRoot = YES;
    self.contacts.myId = myId;
    __weak GMAppDelegate *ws = self;
    self.contacts.pick = ^(NSDictionary *p) {
        [ws.list openChat:p jumpTo:nil];
        [ws.contacts.navigationController popToRootViewControllerAnimated:NO];  // vừa tạo nhóm: về lại danh bạ
    };
    UINavigationController *cn = [[UINavigationController alloc] initWithRootViewController:self.contacts];
    cn.tabBarItem = [GMTheme tabItem:@"Danh bạ" icon:@"contacts"];
    UINavigationController *sn = [[UINavigationController alloc]
        initWithRootViewController:[[GMSettingsViewController alloc] initWithStyle:UITableViewStyleGrouped]];
    sn.tabBarItem = [GMTheme tabItem:@"Cài đặt" icon:@"settings"];
    self.tabs = [[UITabBarController alloc] init];
    self.tabs.viewControllers = @[cn, self.nav, sn];
    self.tabs.selectedIndex = tab;
    // Hai bên viên kính của thanh dưới lộ màu trang (màn gốc của mục đổi màu này — GMTheme styleBarsFor:)
    self.tabs.view.backgroundColor = [GMTheme background];
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        // iPad: chia đôi như app Tin nhắn — bên trái thanh dưới (rộng 320 như iPhone), bên phải cuộc trò chuyện; luôn hiện cả
        // hai theo cả chiều dọc (delegate không cho ẩn bên trái)
        self.detail = [[UINavigationController alloc] initWithRootViewController:[[GMEmptyDetailViewController alloc] init]];
        self.split = [[UISplitViewController alloc] init];
        self.split.delegate = self;
        self.split.viewControllers = @[self.tabs, self.detail];
        self.window.rootViewController = self.split;
        [self fixRotation];
    } else {
        self.window.rootViewController = self.tabs;
    }
    [GMBackground shared].list = self.list;
}

- (BOOL)splitViewController:(UISplitViewController *)svc shouldHideViewController:(UIViewController *)vc
              inOrientation:(UIInterfaceOrientation)orientation {
    return NO;
}

/// iOS 5: thay rootViewController lúc máy nằm ngang thì view mới giữ khung dọc (Roza D20, iPad 1) → xoay lại theo máy.
- (void)fixRotation {
    [UIViewController attemptRotationToDeviceOrientation];
    UIView *v = self.window.rootViewController.view;
    UIInterfaceOrientation o = [UIApplication sharedApplication].statusBarOrientation;
    CGRect b = [UIScreen mainScreen].applicationFrame;
    if (UIInterfaceOrientationIsLandscape(o) && v.bounds.size.width < v.bounds.size.height) {
        v.bounds = CGRectMake(0, 0, b.size.height, b.size.width);
        [v setNeedsLayout];
    }
}

- (BOOL)showDetail:(UIViewController *)vc {
    if (!self.detail) return NO;
    [self.detail setViewControllers:@[vc] animated:NO];
    [[NSNotificationCenter defaultCenter] postNotificationName:GMOpenChatChangedNotification object:nil];
    return YES;
}

- (NSString *)openPeer {
    UIViewController *root = self.detail.viewControllers.count ? [self.detail.viewControllers objectAtIndex:0] : nil;
    if ([root isKindOfClass:[GMEmptyDetailViewController class]] || ![root respondsToSelector:@selector(peer)]) return nil;
    return [(id)root peer];
}

- (void)closeDetailFor:(NSString *)peer {
    if (!self.detail || !peer || ![[self openPeer] isEqual:peer]) return;
    [self.detail setViewControllers:@[[[GMEmptyDetailViewController alloc] init]] animated:NO];
    [[NSNotificationCenter defaultCenter] postNotificationName:GMOpenChatChangedNotification object:nil];
}

- (void)reloadTheme {
    [GMTheme apply];
    // iPad: dựng lại thì mở lại chat đang mở bên phải
    UIViewController *open = self.detail.viewControllers.count ? [self.detail.viewControllers objectAtIndex:0] : nil;
    NSDictionary *reopen = nil;
    if ([open respondsToSelector:@selector(peer)] && [(id)open peer]) {
        reopen = @{@"peer": [(id)open peer], @"name": open.title ?: @"", @"kind": [open respondsToSelector:@selector(kind)] ? ([(id)open kind] ?: @"group") : @"group"};
    }
    [self buildUI];
    if (reopen) [self.list openChat:reopen jumpTo:nil];
    [self.list reload];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    _resuming = NO;
    // Giao diện «Tự động»: qua 19:00 / 6:00 lúc app ở nền → đổi
    if ([GMTheme wantsDark] != [GMTheme dark]) [self reloadTheme];
    // Nằm nền lâu: kết nối có thể đã đứt — hỏi lại ngay (thanh tiêu đề báo «Đang kết nối…» nếu chưa được)
    [GMCore call:@"net.check" args:nil done:nil];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [GMCore call:@"app.flush" args:nil done:nil];
    [[GMBackground shared] didEnterBackground];
    [GMPasscode didEnterBackground];
}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)token {
    GMLog(@"đăng ký thông báo với iOS: được");
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
    GMLog(@"đăng ký thông báo với iOS lỗi: %@", error.localizedDescription);
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    _resuming = YES;
    [[GMBackground shared] willEnterForeground];
    [GMPasscode willEnterForeground];
}

/// Chạm thông báo khi app còn chạy ở nền → iOS gọi lúc app đang chuyển ra trước (Inactive) → mở chat. iOS cũng có thể gọi
/// hàm này khi app còn ở nền (Background) ngay lúc phát thông báo — khi đó KHÔNG mở chat (mở chat = đánh dấu đã đọc).
- (void)application:(UIApplication *)application didReceiveLocalNotification:(UILocalNotification *)notification {
    GMLog(@"didReceiveLocalNotification, trạng thái app %d", (int)application.applicationState);
    // Chỉ khi đang từ nền ra (người dùng chạm thông báo) — Inactive vì hộp hệ thống đang hiện thì không mở
    if (application.applicationState != UIApplicationStateInactive || !_resuming) return;
    [self.list openPeer:[notification.userInfo objectForKey:@"peer"]];
}

/// Link tg:// từ Safari / app khác (nút «Mở trong Telegram» của trang t.me): mở chat / hỏi tham gia; link proxy → màn Proxy.
/// Đang khoá bằng mật mã: chưa làm gì (hộp «Tham gia» của link mời nằm trên màn khoá — người cầm máy không biết mật mã vẫn
/// cho tài khoản vào nhóm được; kiểm bảo mật 17/11/2026) → mở sau khi mở khoá.
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)source annotation:(id)annotation {
    NSString *s = url.absoluteString;
    if (!s.length) return NO;
    if ([GMPasscode isLocked]) {
        GMLog(@"mở link tg:// từ app khác: đợi mở khoá");
        _pendingURL = s;
        return YES;
    }
    [self openExternalLink:s];
    return YES;
}

- (void)unlocked {
    NSString *s = _pendingURL;
    _pendingURL = nil;
    if (s) [self openExternalLink:s];
}

- (void)openExternalLink:(NSString *)s {
    NSString *low = s.lowercaseString;
    GMLog(@"mở link tg:// từ app khác");
    if ([low hasPrefix:@"tg://proxy"] || [low hasPrefix:@"tg://socks"]) {
        GMProxyViewController *p = [[GMProxyViewController alloc] init];
        p.initialLink = s;
        [(UINavigationController *)self.tabs.selectedViewController pushViewController:p animated:YES];
    } else {
        [GMLinks open:s in:self.tabs.view];
    }
}

- (void)applicationWillTerminate:(UIApplication *)application {
    [GMCore call:@"app.flush" args:nil done:nil];
}

@end
