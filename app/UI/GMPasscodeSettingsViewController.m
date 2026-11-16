#import "GMPasscodeSettingsViewController.h"
#import "GMPasscode.h"
#import "GMTheme.h"

@interface GMPasscodeSettingsViewController () <UIActionSheetDelegate>
@end

@implementation GMPasscodeSettingsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Mật mã";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return [GMPasscode enabled] ? 3 : 1;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return 1;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s != 0) return nil;
    return @"Có mật mã thì mở GramMini phải nhập 4 số; thanh đa nhiệm cũng không lộ tin nhắn. Quên mật mã thì phải xoá app "
           @"và đăng nhập lại.";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    BOOL on = [GMPasscode enabled];
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    if (ip.section == 0) {
        c.textLabel.text = on ? @"Tắt mật mã" : @"Bật mật mã";
        c.textLabel.textColor = on ? [UIColor colorWithRed:0.86 green:0.2 blue:0.16 alpha:1] : [GMTheme accent];
    } else if (ip.section == 1) {
        c.textLabel.text = @"Đổi mật mã";
        c.textLabel.textColor = [GMTheme accent];
    } else {
        c.textLabel.text = @"Tự khoá";
        c.detailTextLabel.text = [GMPasscode autolockText:[GMPasscode autolock]];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return c;
}

/// Hiện màn nhập mật mã (bật lên toàn màn), `done(mật mã | nil)`.
- (void)ask:(GMLockMode)mode done:(void (^)(NSString *code))done {
    GMLockViewController *vc = [[GMLockViewController alloc] initWithMode:mode];
    __weak GMPasscodeSettingsViewController *ws = self;
    vc.done = ^(NSString *code) {
        [ws dismissViewControllerAnimated:YES completion:^{ done(code); }];
    };
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    __weak GMPasscodeSettingsViewController *ws = self;
    if (ip.section == 0 && ![GMPasscode enabled]) {
        [self ask:GMLockSetNew done:^(NSString *code) {
            if (!code) return;
            [GMPasscode setCode:code];
            [ws.tableView reloadData];
            [GMTheme toast:@"Đã bật mật mã" in:ws.navigationController.view];
        }];
    } else if (ip.section == 0) {
        [self ask:GMLockVerify done:^(NSString *code) {
            if (!code) return;
            [GMPasscode setCode:nil];
            [ws.tableView reloadData];
            [GMTheme toast:@"Đã tắt mật mã" in:ws.navigationController.view];
        }];
    } else if (ip.section == 1) {
        [self ask:GMLockVerify done:^(NSString *old) {
            if (!old) return;
            [ws ask:GMLockSetNew done:^(NSString *code) {
                if (!code) return;
                NSInteger keep = [GMPasscode autolock];
                [GMPasscode setCode:code];
                [GMPasscode setAutolock:keep];
                [GMTheme toast:@"Đã đổi mật mã" in:ws.navigationController.view];
            }];
        }];
    } else {
        UIActionSheet *s = [[UIActionSheet alloc] initWithTitle:@"Tự khoá khi rời app" delegate:self cancelButtonTitle:nil
                                         destructiveButtonTitle:nil otherButtonTitles:nil];
        for (NSNumber *n in [self autolockOptions]) [s addButtonWithTitle:[GMPasscode autolockText:n.integerValue]];
        s.cancelButtonIndex = [s addButtonWithTitle:@"Huỷ"];
        [s showFromRect:[tv rectForRowAtIndexPath:ip] inView:tv animated:YES];
    }
}

- (NSArray *)autolockOptions {
    return @[@0, @60, @300, @3600, @18000];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)i {
    NSArray *o = [self autolockOptions];
    if (i < 0 || i >= (NSInteger)o.count) return;
    [GMPasscode setAutolock:[[o objectAtIndex:i] integerValue]];
    [self.tableView reloadData];
}

@end
