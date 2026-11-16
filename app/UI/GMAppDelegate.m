#import "GMAppDelegate.h"
#import "GMBackground.h"
#import "GMPasscode.h"
#import "GMChatListViewController.h"
#import "GMContactsViewController.h"
#import "GMCompat.h"
#import "GMCore.h"
#import "GMLog.h"
#import "GMLoginViewController.h"
#import "GMSettingsViewController.h"
#import "GMTheme.h"
#import "GMUpdate.h"
#ifdef DEBUG
#import "GMDebug.h"
#endif

@interface GMAppDelegate () <UIAlertViewDelegate>
@end

@implementation GMAppDelegate {
    BOOL _loginShown, _deadShown;
    BOOL _resuming;  // đang từ nền ra trước (willEnterForeground → didBecomeActive) — chạm thông báo
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
    // Hình nền sau cùng: lộ ra dưới thanh trên / thanh dưới kính
    GMWallpaperView *wall = [[GMWallpaperView alloc] initWithFrame:self.tabs.view.bounds];
    [self.tabs.view insertSubview:wall atIndex:0];
    self.window.rootViewController = self.tabs;
    [GMBackground shared].list = self.list;
}

- (void)reloadTheme {
    [GMTheme apply];
    [self buildUI];
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

- (void)applicationWillTerminate:(UIApplication *)application {
    [GMCore call:@"app.flush" args:nil done:nil];
}

@end
