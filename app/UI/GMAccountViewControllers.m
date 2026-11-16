#import "GMAccountViewControllers.h"
#import "GMCore.h"
#import "GMImages.h"
#import "GMLog.h"
#import "GMPasscode.h"
#import "GMPasscodeSettingsViewController.h"
#import "GMTheme.h"
#import <objc/runtime.h>

/// Ô có ô nhập chữ (nhãn bên trái nhỏ).
static UITextField *GMFieldCell(UITableViewCell *c, NSString *placeholder, NSString *text) {
    UITextField *f = [[UITextField alloc] initWithFrame:CGRectInset(c.contentView.bounds, 12, 8)];
    f.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    f.placeholder = placeholder;
    f.text = text;
    f.font = [UIFont systemFontOfSize:17];
    f.textColor = [GMTheme text];
    f.keyboardAppearance = [GMTheme keyboard];
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    f.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    [c.contentView addSubview:f];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    return f;
}

static NSString *GMPrettyPhoneNumber(NSString *p) {
    if (![p isKindOfClass:[NSString class]] || !p.length) return @"";
    NSString *d = [p hasPrefix:@"+"] ? [p substringFromIndex:1] : p;
    if ([d hasPrefix:@"84"] && d.length >= 11) {
        return [NSString stringWithFormat:@"+84 %@ %@ %@", [d substringWithRange:NSMakeRange(2, 3)],
                                          [d substringWithRange:NSMakeRange(5, 3)], [d substringFromIndex:8]];
    }
    return [@"+" stringByAppendingString:d];
}

#pragma mark - Hồ sơ

@interface GMProfileViewController () <UIActionSheetDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate,
                                       UITextFieldDelegate>
@end

@implementation GMProfileViewController {
    NSDictionary *_me;
    UITextField *_first, *_last, *_about;
    UIPopoverController *_popover;
    UIImage *_avatar;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Hồ sơ";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Lưu" style:UIBarButtonItemStyleDone
                                                                             target:self action:@selector(saveTapped)];
    [self reload];
}

- (void)reload {
    [GMCore call:@"account.get" args:nil done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.view];
            return;
        }
        _me = ok;
        // Ô nhập đã tạo (trước khi có dữ liệu) thì điền vào — tải lại bảng giữ chữ của ô cũ
        _first.text = GMVal(ok, @"first");
        _last.text = GMVal(ok, @"last");
        _about.text = GMVal(ok, @"about");
        [self.tableView reloadData];
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return 5;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 1 ? 2 : 1;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == 0 ? 96 : 44;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 1) return @"Tên hiện với mọi người (người đã lưu bạn trong danh bạ thì thấy tên họ lưu).";
    if (s == 2) return @"Vài dòng giới thiệu (tối đa 70 ký tự).";
    if (s == 3) return @"Có @tên thì người khác tìm và nhắn cho bạn mà không cần số điện thoại.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    if (ip.section == 0) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        NSString *name = GMVal(_me, @"name") ?: @"…";
        c.textLabel.text = name;
        c.textLabel.font = [UIFont boldSystemFontOfSize:19];
        c.detailTextLabel.text = @"Chạm để đổi ảnh đại diện";
        c.detailTextLabel.textColor = [GMTheme accent];
        c.imageView.image = _avatar ?: [GMTheme avatarFor:GMVal(_me, @"id") ?: @"0" name:name size:72];
        if (!_avatar && GMVal(_me, @"photo")) {
            __weak UITableViewCell *wc = c;
            [GMImages avatarForPeer:GMVal(_me, @"id") photo:[GMVal(_me, @"photo") description] dc:GMVal(_me, @"photo_dc") size:72
                               done:^(UIImage *img) {
                                   if (img) wc.imageView.image = img;
                                   [wc setNeedsLayout];
                               }];
        }
        return c;
    }
    if (ip.section == 1) {
        UITextField *f = GMFieldCell(c, ip.row == 0 ? @"Tên (bắt buộc)" : @"Họ (không bắt buộc)",
                                     _first || _last ? (ip.row == 0 ? _first.text : _last.text) : GMVal(_me, ip.row == 0 ? @"first" : @"last"));
        if (ip.row == 0) _first = f;
        else _last = f;
        return c;
    }
    if (ip.section == 2) {
        _about = GMFieldCell(c, @"Giới thiệu", _about ? _about.text : GMVal(_me, @"about"));
        _about.delegate = self;
        return c;
    }
    if (ip.section == 3) {
        c.textLabel.text = @"Tên người dùng";
        NSString *u = GMVal(_me, @"username");
        c.detailTextLabel.text = [u isKindOfClass:[NSString class]] && u.length ? [@"@" stringByAppendingString:u] : @"Chưa có";
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    c.textLabel.text = @"Số điện thoại";
    c.detailTextLabel.text = GMPrettyPhoneNumber(GMVal(_me, @"phone"));
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    return c;
}

- (BOOL)textField:(UITextField *)f shouldChangeCharactersInRange:(NSRange)r replacementString:(NSString *)s {
    return f != _about || [f.text stringByReplacingCharactersInRange:r withString:s].length <= 70;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) {
        UIActionSheet *s = [[UIActionSheet alloc] initWithTitle:@"Ảnh đại diện" delegate:self cancelButtonTitle:nil
                                         destructiveButtonTitle:nil otherButtonTitles:nil];
        NSMutableArray *srcs = [NSMutableArray array];
        if ([UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
            [s addButtonWithTitle:@"Chụp ảnh"];
            [srcs addObject:@(UIImagePickerControllerSourceTypeCamera)];
        }
        [s addButtonWithTitle:@"Chọn ảnh có sẵn"];
        [srcs addObject:@(UIImagePickerControllerSourceTypePhotoLibrary)];
        s.cancelButtonIndex = [s addButtonWithTitle:@"Huỷ"];
        objc_setAssociatedObject(s, "srcs", srcs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [s showFromRect:[tv rectForRowAtIndexPath:ip] inView:tv animated:YES];
    } else if (ip.section == 3) {
        [self editUsername];
    }
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)i {
    NSArray *srcs = objc_getAssociatedObject(sheet, "srcs");
    if (i < 0 || i >= (NSInteger)srcs.count) return;
    UIImagePickerController *p = [[UIImagePickerController alloc] init];
    p.sourceType = [[srcs objectAtIndex:i] integerValue];
    p.allowsEditing = YES;  // cắt vuông
    p.delegate = self;
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad && p.sourceType != UIImagePickerControllerSourceTypeCamera) {
        _popover = [[UIPopoverController alloc] initWithContentViewController:p];
        [_popover presentPopoverFromRect:[self.tableView rectForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]]
                                  inView:self.tableView permittedArrowDirections:UIPopoverArrowDirectionAny animated:YES];
    } else {
        [self presentViewController:p animated:YES completion:nil];
    }
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
    UIImage *img = [info objectForKey:UIImagePickerControllerEditedImage] ?: [info objectForKey:UIImagePickerControllerOriginalImage];
    if (_popover) {
        [_popover dismissPopoverAnimated:YES];
        _popover = nil;
    } else {
        [picker dismissViewControllerAnimated:YES completion:nil];
    }
    if (img) [self uploadAvatar:img];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

/// Ảnh vuông 640 px, JPEG 0,85 → `account.setPhoto`.
- (void)uploadAvatar:(UIImage *)img {
    [GMTheme toast:@"Đang đổi ảnh đại diện…" in:self.navigationController.view];
    CGFloat side = MIN(img.size.width, img.size.height), k = MIN(1.0, 640.0 / side);
    CGSize to = CGSizeMake(floor(side * k), floor(side * k));
    UIGraphicsBeginImageContextWithOptions(to, YES, 1);
    [img drawInRect:CGRectMake((to.width - img.size.width * k) / 2, (to.height - img.size.height * k) / 2, img.size.width * k,
                               img.size.height * k)];
    UIImage *sq = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    NSString *dir = [GMDataDir() stringByAppendingPathComponent:@"tmp"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *path = [dir stringByAppendingPathComponent:@"avatar.jpg"];
    [UIImageJPEGRepresentation(sq, 0.85) writeToFile:path atomically:YES];
    [GMCore call:@"account.setPhoto" args:@{@"path": path} done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.navigationController.view];
            return;
        }
        _avatar = [GMTheme roundImage:sq size:72];
        _me = ok;
        [self.tableView reloadData];
        [GMTheme toast:@"Đã đổi ảnh đại diện" in:self.navigationController.view];
    }];
}

- (void)saveTapped {
    [self.view endEditing:YES];
    NSString *first = [_first.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] ?: @"";
    if (!first.length) {
        [GMTheme toast:@"Tên không được để trống." in:self.navigationController.view];
        return;
    }
    NSDictionary *a = @{@"first": first, @"last": _last.text ?: @"", @"about": _about.text ?: @""};
    [GMCore call:@"account.update" args:a done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.navigationController.view];
            return;
        }
        [self.navigationController popViewControllerAnimated:YES];
    }];
}

- (void)editUsername {
    UIAlertView *av = [[UIAlertView alloc] initWithTitle:@"Tên người dùng"
                                                 message:@"5–32 ký tự: chữ cái Latinh, số, dấu gạch dưới. Để trống = bỏ @tên."
                                                delegate:self cancelButtonTitle:@"Huỷ" otherButtonTitles:@"Lưu", nil];
    av.alertViewStyle = UIAlertViewStylePlainTextInput;
    UITextField *f = [av textFieldAtIndex:0];
    f.text = GMVal(_me, @"username");
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.placeholder = @"ten_nguoi_dung";
    [av show];
}

- (void)alertView:(UIAlertView *)av clickedButtonAtIndex:(NSInteger)i {
    if (i != 1) return;
    NSString *u = [[av textFieldAtIndex:0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    void (^set)(void) = ^{
        [GMCore call:@"account.setUsername" args:@{@"username": u} done:^(id ok, NSDictionary *err) {
            if (err) {
                [GMTheme toast:GMErrorText(err) in:self.navigationController.view];
                return;
            }
            [GMTheme toast:u.length ? @"Đã đổi tên người dùng" : @"Đã bỏ tên người dùng" in:self.navigationController.view];
            [self reload];
        }];
    };
    if (!u.length) {
        set();
        return;
    }
    [GMCore call:@"account.checkUsername" args:@{@"username": u} done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.navigationController.view];
            return;
        }
        if (![GMVal(ok, @"free") boolValue]) {
            [GMTheme toast:[NSString stringWithFormat:@"@%@ đã có người dùng.", u] in:self.navigationController.view];
            return;
        }
        set();
    }];
}

@end

#pragma mark - Quyền riêng tư

static NSArray *GMPrivacyKeys(void) {
    return @[@[@"status", @"Lần truy cập"], @[@"phone", @"Số điện thoại"], @[@"photo", @"Ảnh đại diện"],
             @[@"forwards", @"Chuyển tiếp tin nhắn"], @[@"calls", @"Cuộc gọi"], @[@"invites", @"Thêm vào nhóm"]];
}

static NSString *GMPrivacyText(NSString *v) {
    return [v isEqual:@"everybody"] ? @"Mọi người" : [v isEqual:@"contacts"] ? @"Danh bạ" : @"Không ai";
}

@interface GMPrivacyViewController () <UIActionSheetDelegate>
@end

@implementation GMPrivacyViewController {
    NSDictionary *_privacy;
    NSString *_editing;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Quyền riêng tư";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [GMCore call:@"account.privacy" args:nil done:^(id ok, NSDictionary *err) {
        if (ok) _privacy = ok;
        [self.tableView reloadData];
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? GMPrivacyKeys().count : 2;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return s == 0 ? @"Quyền riêng tư" : @"Bảo mật";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (ip.section == 0) {
        NSArray *k = [GMPrivacyKeys() objectAtIndex:ip.row];
        c.textLabel.text = [k objectAtIndex:1];
        NSDictionary *v = [_privacy objectForKey:[k objectAtIndex:0]];
        if (v) {
            NSInteger ex = [GMVal(v, @"allow") integerValue] + [GMVal(v, @"deny") integerValue];
            c.detailTextLabel.text = ex ? [NSString stringWithFormat:@"%@ (+%ld)", GMPrivacyText(GMVal(v, @"value")), (long)ex]
                                        : GMPrivacyText(GMVal(v, @"value"));
        }
        return c;
    }
    if (ip.row == 0) {
        c.textLabel.text = @"Mật mã";
        c.detailTextLabel.text = [GMPasscode enabled] ? @"Đang bật" : @"Tắt";
    } else {
        c.textLabel.text = @"Phiên đăng nhập";
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 1) {
        UIViewController *vc = ip.row == 0 ? [[GMPasscodeSettingsViewController alloc] init] : [[GMSessionsViewController alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    NSArray *k = [GMPrivacyKeys() objectAtIndex:ip.row];
    _editing = [k objectAtIndex:0];
    NSDictionary *v = [_privacy objectForKey:_editing];
    NSInteger ex = [GMVal(v, @"allow") integerValue] + [GMVal(v, @"deny") integerValue];
    NSString *title = ex ? [NSString stringWithFormat:@"%@ — đổi sẽ bỏ %ld ngoại lệ đã đặt", [k objectAtIndex:1], (long)ex]
                         : [k objectAtIndex:1];
    UIActionSheet *s = [[UIActionSheet alloc] initWithTitle:title delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil
                                          otherButtonTitles:@"Mọi người", @"Danh bạ", @"Không ai", nil];
    s.cancelButtonIndex = [s addButtonWithTitle:@"Huỷ"];
    [s showFromRect:[tv rectForRowAtIndexPath:ip] inView:tv animated:YES];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)i {
    if (i < 0 || i > 2 || !_editing) return;
    NSString *value = [@[@"everybody", @"contacts", @"nobody"] objectAtIndex:i];
    NSString *key = _editing;
    [GMCore call:@"account.setPrivacy" args:@{@"key": key, @"value": value} done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.navigationController.view];
            return;
        }
        NSMutableDictionary *p = [_privacy mutableCopy];
        [p setObject:@{@"value": value, @"allow": @0, @"deny": @0} forKey:key];
        _privacy = p;
        [self.tableView reloadData];
    }];
}

@end

#pragma mark - Phiên đăng nhập

@interface GMSessionsViewController () <UIActionSheetDelegate>
@end

@implementation GMSessionsViewController {
    NSArray *_current, *_others;
    NSDictionary *_pending;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Phiên đăng nhập";
    [self reload];
}

- (void)reload {
    [GMCore call:@"account.sessions" args:nil done:^(id ok, NSDictionary *err) {
        if (![ok isKindOfClass:[NSArray class]]) {
            [GMTheme toast:GMErrorText(err) in:self.view];
            return;
        }
        _current = [ok filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"current == YES"]];
        _others = [[ok filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"current == NO"]]
            sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"active" ascending:NO]]];
        [self.tableView reloadData];
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? _current.count : _others.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return s == 0 ? @"Máy này" : (_others.count ? @"Phiên khác" : nil);
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return s == 1 && _others.count ? @"Chạm một phiên để kết thúc (máy đó sẽ bị đăng xuất)." : nil;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return 64;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSDictionary *a = [(ip.section == 0 ? _current : _others) objectAtIndex:ip.row];
    c.textLabel.text = [NSString stringWithFormat:@"%@ · %@", GMVal(a, @"app") ?: @"", GMVal(a, @"device") ?: @""];
    c.textLabel.font = [UIFont boldSystemFontOfSize:15];
    NSMutableArray *parts = [NSMutableArray array];
    NSString *sys = [[NSString stringWithFormat:@"%@ %@", GMVal(a, @"platform") ?: @"", GMVal(a, @"system") ?: @""]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (sys.length) [parts addObject:sys];
    NSMutableArray *place = [NSMutableArray array];
    for (NSString *k in @[@"region", @"country"]) {
        NSString *v = GMVal(a, k);
        if ([v isKindOfClass:[NSString class]] && v.length) [place addObject:v];
    }
    if (place.count) [parts addObject:[place componentsJoinedByString:@", "]];
    [parts addObject:ip.section == 0 ? @"đang dùng" : [GMTheme shortTime:GMVal(a, @"active")]];
    c.detailTextLabel.text = [parts componentsJoinedByString:@" · "];
    c.detailTextLabel.textColor = [GMTheme secondaryText];
    c.detailTextLabel.numberOfLines = 2;
    if (ip.section == 0) c.selectionStyle = UITableViewCellSelectionStyleNone;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) return;
    _pending = [_others objectAtIndex:ip.row];
    UIActionSheet *s = [[UIActionSheet alloc] initWithTitle:[NSString stringWithFormat:@"Kết thúc phiên trên «%@»?", GMVal(_pending, @"device")]
                                                   delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
    s.destructiveButtonIndex = [s addButtonWithTitle:@"Kết thúc phiên"];
    s.cancelButtonIndex = [s addButtonWithTitle:@"Huỷ"];
    [s showFromRect:[tv rectForRowAtIndexPath:ip] inView:tv animated:YES];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)i {
    NSDictionary *a = _pending;
    _pending = nil;
    if (i != sheet.destructiveButtonIndex || !a) return;
    [GMCore call:@"account.terminate" args:@{@"hash": GMVal(a, @"hash")} done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.navigationController.view];
            return;
        }
        [GMTheme toast:@"Đã kết thúc phiên" in:self.navigationController.view];
        [self reload];
    }];
}

@end

#pragma mark - Sửa tên

@implementation GMEditNameViewController {
    UITextField *_f1, *_f2;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Lưu" style:UIBarButtonItemStyleDone
                                                                             target:self action:@selector(saveTapped)];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return 2;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return @"Tên này chỉ mình bạn thấy (lưu trong danh bạ Telegram của bạn).";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    UITextField *f = GMFieldCell(c, ip.row == 0 ? @"Tên" : @"Họ", ip.row == 0 ? (_f1.text ?: self.first) : (_f2.text ?: self.last));
    if (ip.row == 0) _f1 = f;
    else _f2 = f;
    return c;
}

- (void)saveTapped {
    [self.view endEditing:YES];
    NSString *f = [_f1.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] ?: @"";
    if (!f.length) {
        [GMTheme toast:@"Tên không được để trống." in:self.navigationController.view];
        return;
    }
    __weak GMEditNameViewController *ws = self;
    if (self.save) self.save(f, _f2.text ?: @"", ^(NSDictionary *err) {
        if (err) [GMTheme toast:GMErrorText(err) in:ws.navigationController.view];
        else [ws.navigationController popViewControllerAnimated:YES];
    });
}

@end
