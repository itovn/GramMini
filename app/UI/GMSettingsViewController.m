#import "GMSettingsViewController.h"
#import "GMChatViewController.h"
#import "GMCore.h"
#import "GMImages.h"
#import "GMProxyViewController.h"
#import "GMStorageViewController.h"
#import "GMStickerSetViewController.h"
#import "GMFoldersViewController.h"
#import "GMNotifySettingsViewController.h"
#import "GMPasscode.h"
#import "GMPasscodeSettingsViewController.h"
#import "GMAccountViewControllers.h"
#import "GMAppDelegate.h"
#import "GMQuickRepliesViewController.h"
#import "GMChatListViewController.h"
#import "GMTheme.h"
#import "GMUpdate.h"

/// Cài đặt kiểu Telegram 4.9: đầu trang (ảnh, tên, số điện thoại, @tên), các mục có biểu tượng ô vuông màu, Đăng xuất đỏ.
@interface GMSettingsViewController () <UIActionSheetDelegate>
@end

@implementation GMSettingsViewController {
    NSDictionary *_me;
    NSString *_proxy;
}

typedef NS_ENUM(NSInteger, GMSection) { GMSecProfile, GMSecMain, GMSecAbout, GMSecLogout, GMSecCount };

/// Các mục chính (biểu tượng, tên) — thứ tự như Telegram 4.9.
static NSArray *GMSettingsRows(void) {
    return @[@[@"saved", @"Tin nhắn đã lưu"], @[@"folders", @"Thư mục chat"], @[@"quick", @"Tin nhắn nhanh"], @[@"notify", @"Thông báo"],
             @[@"lock", @"Quyền riêng tư và bảo mật"],
             @[@"storage", @"Dữ liệu và bộ nhớ"], @[@"stickers", @"Sticker"], @[@"theme", @"Giao diện"], @[@"proxy", @"Proxy"]];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Cài đặt";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [GMCore call:@"auth.state" args:nil done:^(id ok, NSDictionary *err) {
        _me = GMVal(ok, @"me");
        [self.tableView reloadData];
    }];
    [GMCore call:@"proxy.get" args:nil done:^(id ok, NSDictionary *err) {
        _proxy = GMVal(ok, @"link");
        [self.tableView reloadData];
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return GMSecCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == GMSecMain ? GMSettingsRows().count : section == GMSecAbout ? 2 : 1;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == GMSecProfile ? 80 : 44;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != GMSecAbout) return nil;
    return @"GramMini là ứng dụng không chính thức, dùng Telegram API. Mã nguồn mở (GPL-3.0): github.com/itovn/GramMini";
}

/// Số điện thoại dễ đọc: +84 912 345 678.
- (NSString *)prettyPhone:(NSString *)p {
    if (!p.length) return @"";
    NSString *d = [p hasPrefix:@"+"] ? [p substringFromIndex:1] : p;
    if ([d hasPrefix:@"84"] && d.length >= 11) {
        return [NSString stringWithFormat:@"+84 %@ %@ %@", [d substringWithRange:NSMakeRange(2, 3)],
                                          [d substringWithRange:NSMakeRange(5, 3)], [d substringFromIndex:8]];
    }
    return [@"+" stringByAppendingString:d];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c;
    if (ip.section == GMSecProfile) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        NSString *name = GMVal(_me, @"name") ?: @"…";
        c.imageView.image = [GMTheme avatarFor:GMVal(_me, @"id") ?: @"0" name:name size:60];
        if (GMVal(_me, @"photo")) {
            __weak UITableViewCell *wc = c;
            [GMImages avatarForPeer:GMVal(_me, @"id") photo:GMVal(_me, @"photo") dc:GMVal(_me, @"photo_dc") size:60
                               done:^(UIImage *img) {
                                   wc.imageView.image = img;
                                   [wc setNeedsLayout];
                               }];
        }
        c.textLabel.text = name;
        c.textLabel.font = [UIFont boldSystemFontOfSize:19];
        NSString *u = GMVal(_me, @"username");
        NSString *phone = [self prettyPhone:GMVal(_me, @"phone")];
        c.detailTextLabel.text = u.length ? [NSString stringWithFormat:@"%@\n@%@", phone, u] : phone;
        c.detailTextLabel.numberOfLines = 2;
        c.detailTextLabel.textColor = [GMTheme secondaryText];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    if (ip.section == GMSecMain) {
        NSArray *row = [GMSettingsRows() objectAtIndex:ip.row];
        c.imageView.image = [GMTheme settingsIcon:[row objectAtIndex:0]];
        c.textLabel.text = [row objectAtIndex:1];
        if ([[row objectAtIndex:0] isEqual:@"proxy"]) c.detailTextLabel.text = _proxy.length ? @"Đang dùng" : @"Đi thẳng";
        if ([[row objectAtIndex:0] isEqual:@"theme"]) c.detailTextLabel.text = [GMTheme modeText:[GMTheme mode]];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (ip.section == GMSecAbout && ip.row == 1) {
        // Nhóm cộng đồng trên Telegram — chạm: mở ngay trong GramMini
        c.imageView.image = [GMTheme settingsIcon:@"community"];
        c.textLabel.text = @"Nhóm Telegram GramMini";
        c.detailTextLabel.text = @"t.me/tivikit";
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (ip.section == GMSecAbout) {
        c.imageView.image = [GMTheme settingsIcon:@"info"];
        c.textLabel.text = @"Phiên bản";
        c.detailTextLabel.text = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;  // chạm: kiểm tra bản mới
    } else {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.textLabel.text = @"Đăng xuất";
        c.textLabel.textAlignment = GMAlignCenter;
        c.textLabel.textColor = [UIColor colorWithRed:0.86 green:0.2 blue:0.16 alpha:1];
    }
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == GMSecProfile) {
        [self.navigationController pushViewController:[[GMProfileViewController alloc] init] animated:YES];
    } else if (ip.section == GMSecMain) {
        NSString *k = [[GMSettingsRows() objectAtIndex:ip.row] objectAtIndex:0];
        UIViewController *vc = nil;
        if ([k isEqual:@"saved"]) {
            if (!GMVal(_me, @"id")) return;
            GMChatViewController *c = [[GMChatViewController alloc] init];
            c.peer = GMVal(_me, @"id");
            c.myId = GMVal(_me, @"id");
            c.kind = @"user";
            c.title = @"Tin nhắn đã lưu";
            if ([(GMAppDelegate *)[UIApplication sharedApplication].delegate showDetail:c]) return;  // iPad: bên phải
            vc = c;
        } else if ([k isEqual:@"notify"]) {
            vc = [[GMNotifySettingsViewController alloc] init];
        } else if ([k isEqual:@"quick"]) {
            vc = [[GMQuickRepliesViewController alloc] init];
        } else if ([k isEqual:@"lock"]) {
            vc = [[GMPrivacyViewController alloc] init];
        } else if ([k isEqual:@"storage"]) {
            vc = [[GMStorageViewController alloc] init];
        } else if ([k isEqual:@"stickers"]) {
            vc = [[GMStickersViewController alloc] init];
        } else if ([k isEqual:@"folders"]) {
            vc = [[GMFoldersViewController alloc] init];
        } else if ([k isEqual:@"theme"]) {
            [self chooseTheme:[tableView rectForRowAtIndexPath:ip]];
            return;
        } else {
            vc = [[GMProxyViewController alloc] init];
        }
        [self.navigationController pushViewController:vc animated:YES];
    } else if (ip.section == GMSecAbout && ip.row == 1) {
        [self openCommunity];
    } else if (ip.section == GMSecAbout) {
        [GMUpdate checkManual];
    } else if (ip.section == GMSecLogout) {
        [[[UIAlertView alloc] initWithTitle:@"Đăng xuất?" message:@"Máy này sẽ thoát khỏi tài khoản Telegram." delegate:self
                          cancelButtonTitle:@"Huỷ" otherButtonTitles:@"Đăng xuất", nil] show];
    }
}

/// Nhóm Telegram của GramMini (t.me/tivikit): tìm theo @tên rồi mở chat ở mục Chat.
- (void)openCommunity {
    [GMCore call:@"contacts.resolve" args:@{@"username": @"tivikit"} done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.view];
            return;
        }
        [((GMAppDelegate *)[UIApplication sharedApplication].delegate).list openChat:ok jumpTo:nil];
    }];
}

- (void)chooseTheme:(CGRect)from {
    UIActionSheet *s = [[UIActionSheet alloc] initWithTitle:@"Giao diện" delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil
                                          otherButtonTitles:@"Sáng", @"Tối", @"Tự động (tối từ 19:00 đến 6:00)", nil];
    s.cancelButtonIndex = [s addButtonWithTitle:@"Huỷ"];
    [s showFromRect:from inView:self.tableView animated:YES];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)i {
    if (i < 0 || i > 2) return;
    [GMTheme setMode:i];  // GMThemeLight / GMThemeDark / GMThemeAuto
    [(GMAppDelegate *)[UIApplication sharedApplication].delegate reloadTheme];
}

- (void)alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex {
    if (buttonIndex != 1) return;
    [GMCore call:@"auth.logout" args:nil done:^(id ok, NSDictionary *err) {
        [self.navigationController popToRootViewControllerAnimated:NO];
    }];
}

@end
