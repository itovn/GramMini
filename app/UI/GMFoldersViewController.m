#import "GMFoldersViewController.h"
#import "GMAppDelegate.h"
#import "GMChatListViewController.h"
#import "GMCore.h"
#import "GMPickChatViewController.h"
#import "GMTheme.h"
#import <objc/runtime.h>

NSString *const GMFoldersChangedNotification = @"GMFoldersChanged";

static GMChatListViewController *GMList(void) {
    return ((GMAppDelegate *)[UIApplication sharedApplication].delegate).list;
}

/// Tên chat theo khoá (lấy từ danh sách chat; «self» / khoá của mình = Tin nhắn đã lưu).
static NSString *GMPeerName(NSString *key) {
    GMChatListViewController *l = GMList();
    if ([key isEqual:@"self"] || [key isEqual:l.myId]) return @"Tin nhắn đã lưu";
    return GMVal([l dialogForPeer:key], @"name") ?: @"Chat chưa tải";
}

/// Mô tả ngắn của thư mục: các loại chat + số chat thêm riêng.
static NSString *GMFolderSummary(NSDictionary *f) {
    NSMutableArray *a = [NSMutableArray array];
    if ([GMVal(f, @"contacts") boolValue]) [a addObject:@"danh bạ"];
    if ([GMVal(f, @"non_contacts") boolValue]) [a addObject:@"ngoài danh bạ"];
    if ([GMVal(f, @"groups") boolValue]) [a addObject:@"nhóm"];
    if ([GMVal(f, @"broadcasts") boolValue]) [a addObject:@"kênh"];
    if ([GMVal(f, @"bots") boolValue]) [a addObject:@"bot"];
    NSUInteger n = [GMVal(f, @"include") count] + [GMVal(f, @"pinned") count];
    if (n) [a addObject:[NSString stringWithFormat:@"%lu chat", (unsigned long)n]];
    NSString *s = [a componentsJoinedByString:@", "];
    return s.length ? [[[s substringToIndex:1] uppercaseString] stringByAppendingString:[s substringFromIndex:1]] : @"";
}

#pragma mark - Danh sách thư mục

typedef NS_ENUM(NSInteger, GMFolderSection) { GMSecFolders, GMSecNew, GMSecSuggested, GMSecCount };

@implementation GMFoldersViewController {
    NSMutableArray *_folders;
    NSArray *_suggested;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Thư mục chat";
    _folders = [NSMutableArray array];
    _suggested = @[];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Sửa" style:UIBarButtonItemStyleBordered target:self action:@selector(toggleEdit)];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(load) name:GMFoldersChangedNotification object:nil];
    [self load];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)load {
    [GMCore call:@"folders.list" args:nil done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.view];
            return;
        }
        [_folders setArray:ok];
        [self.tableView reloadData];
    }];
    [GMCore call:@"folders.suggested" args:nil done:^(id ok, NSDictionary *err) {
        if (![ok isKindOfClass:[NSArray class]]) return;
        // Bỏ gợi ý trùng tên thư mục đã có
        NSMutableArray *a = [NSMutableArray array];
        for (NSDictionary *s in ok) {
            BOOL dup = NO;
            for (NSDictionary *f in _folders) dup |= [GMVal(f, @"title") isEqual:GMVal(s, @"title")];
            if (!dup) [a addObject:s];
        }
        _suggested = a;
        [self.tableView reloadData];
    }];
}

- (void)toggleEdit {
    BOOL on = !self.tableView.editing;
    [self.tableView setEditing:on animated:YES];
    self.navigationItem.rightBarButtonItem.title = on ? @"Xong" : @"Sửa";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return GMSecCount;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == GMSecFolders) return _folders.count;
    if (s == GMSecNew) return 1;
    return _suggested.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == GMSecFolders) return _folders.count ? @"Thư mục của bạn" : nil;
    if (s == GMSecSuggested) return _suggested.count ? @"Gợi ý" : nil;
    return nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s != GMSecNew) return nil;
    return @"Thư mục gom chat theo loại hoặc theo ý bạn, hiện thành thẻ trên danh sách chat. Thư mục đồng bộ với tài khoản — "
           @"app Telegram khác cũng thấy.";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == GMSecNew) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.textLabel.text = @"Tạo thư mục mới";
        c.textLabel.textColor = [GMTheme accent];
        c.imageView.image = [GMTheme settingsIcon:@"folders"];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (ip.section == GMSecFolders) {
        NSDictionary *f = [_folders objectAtIndex:ip.row];
        c.textLabel.text = GMVal(f, @"title");
        NSInteger n = [GMList() countInFolder:f];
        NSString *sum = GMFolderSummary(f);
        c.detailTextLabel.text = sum.length ? [NSString stringWithFormat:@"%ld chat · %@", (long)n, sum]
                                            : [NSString stringWithFormat:@"%ld chat", (long)n];
        c.accessoryType = [GMVal(f, @"chatlist") boolValue] ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    NSDictionary *s = [_suggested objectAtIndex:ip.row];
    c.textLabel.text = GMVal(s, @"title");
    c.detailTextLabel.text = GMVal(s, @"description");
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, 64, 44);
    [b setBackgroundImage:[GMTheme sendButtonImage:NO] forState:UIControlStateNormal];
    [b setBackgroundImage:[GMTheme sendButtonImage:YES] forState:UIControlStateHighlighted];
    [b setTitle:@"Thêm" forState:UIControlStateNormal];
    [b setTitleShadowColor:[UIColor colorWithWhite:0 alpha:0.35] forState:UIControlStateNormal];
    b.titleLabel.shadowOffset = CGSizeMake(0, -1);
    b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    b.adjustsImageWhenHighlighted = NO;
    b.tag = ip.row;
    [b addTarget:self action:@selector(addSuggested:) forControlEvents:UIControlEventTouchUpInside];
    c.accessoryView = b;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    return c;
}

- (void)addSuggested:(UIButton *)b {
    if (b.tag >= (NSInteger)_suggested.count) return;
    NSMutableDictionary *f = [[_suggested objectAtIndex:b.tag] mutableCopy];
    [f removeObjectForKey:@"id"];  // lõi cấp id mới
    [f removeObjectForKey:@"description"];
    b.enabled = NO;
    [GMCore call:@"folders.save" args:f done:^(id ok, NSDictionary *err) {
        b.enabled = YES;
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.view];
            return;
        }
        [GMTheme toast:[NSString stringWithFormat:@"Đã thêm thư mục «%@»", GMVal(f, @"title")] in:self.view];
        [[NSNotificationCenter defaultCenter] postNotificationName:GMFoldersChangedNotification object:nil];
    }];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == GMSecSuggested) return;
    GMFolderEditViewController *e = [[GMFolderEditViewController alloc] initWithStyle:UITableViewStyleGrouped];
    if (ip.section == GMSecFolders) {
        NSDictionary *f = [_folders objectAtIndex:ip.row];
        if ([GMVal(f, @"chatlist") boolValue]) {
            [GMTheme toast:@"Thư mục chia sẻ qua link — sửa trong app Telegram gốc." in:self.view];
            return;
        }
        e.folder = f;
    }
    [self.navigationController pushViewController:e animated:YES];
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == GMSecFolders;
}

- (BOOL)tableView:(UITableView *)tv canMoveRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == GMSecFolders;
}

- (NSIndexPath *)tableView:(UITableView *)tv targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)from
       toProposedIndexPath:(NSIndexPath *)to {
    if (to.section != GMSecFolders) return [NSIndexPath indexPathForRow:to.section < GMSecFolders ? 0 : _folders.count - 1 inSection:GMSecFolders];
    return to;
}

- (void)tableView:(UITableView *)tv moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    id f = [_folders objectAtIndex:from.row];
    [_folders removeObjectAtIndex:from.row];
    [_folders insertObject:f atIndex:to.row];
    NSMutableArray *order = [NSMutableArray array];
    for (NSDictionary *x in _folders) [order addObject:GMVal(x, @"id")];
    [GMCore call:@"folders.order" args:@{@"order": order} done:^(id ok, NSDictionary *err) {
        if (err) [GMTheme toast:GMErrorText(err) in:self.view];
        [[NSNotificationCenter defaultCenter] postNotificationName:GMFoldersChangedNotification object:nil];
    }];
}

- (NSString *)tableView:(UITableView *)tv titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)ip {
    return @"Xoá";
}

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete || ip.row >= (NSInteger)_folders.count) return;
    NSDictionary *f = [_folders objectAtIndex:ip.row];
    [GMCore call:@"folders.delete" args:@{@"id": GMVal(f, @"id")} done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.view];
            return;
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:GMFoldersChangedNotification object:nil];
    }];
}

@end

#pragma mark - Sửa một thư mục

typedef NS_ENUM(NSInteger, GMEditSection) { GMEdName, GMEdInclude, GMEdExclude, GMEdDelete };

static NSArray *GMIncludeTypes(void) {
    return @[@[@"contacts", @"Danh bạ"], @[@"non_contacts", @"Không trong danh bạ"], @[@"groups", @"Nhóm"],
             @[@"broadcasts", @"Kênh"], @[@"bots", @"Bot"]];
}

static NSArray *GMExcludeTypes(void) {
    return @[@[@"exclude_muted", @"Đã tắt tiếng"], @[@"exclude_read", @"Đã đọc"], @[@"exclude_archived", @"Lưu trữ"]];
}

@interface GMFolderEditViewController () <UITextFieldDelegate, UIActionSheetDelegate>
@end

@implementation GMFolderEditViewController {
    NSMutableDictionary *_f;
    NSMutableArray *_include, *_exclude;
    UITextField *_name;
    BOOL _saving;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.folder ? @"Sửa thư mục" : @"Thư mục mới";
    _f = [self.folder mutableCopy] ?: [NSMutableDictionary dictionary];
    // Chat ghim trong thư mục cũng là chat được đưa vào (giữ nguyên danh sách ghim khi lưu)
    _include = [GMVal(_f, @"include") mutableCopy] ?: [NSMutableArray array];
    _exclude = [GMVal(_f, @"exclude") mutableCopy] ?: [NSMutableArray array];
    _name = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 200, 30)];
    _name.placeholder = @"Tên thư mục (vd. Công việc)";
    _name.text = GMVal(_f, @"title");
    _name.font = [UIFont systemFontOfSize:17];
    _name.textColor = [GMTheme text];
    _name.keyboardAppearance = [GMTheme keyboard];
    _name.clearButtonMode = UITextFieldViewModeWhileEditing;
    _name.returnKeyType = UIReturnKeyDone;
    _name.delegate = self;
    _name.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Lưu" style:UIBarButtonItemStyleDone target:self action:@selector(save)];
}

- (BOOL)textFieldShouldReturn:(UITextField *)t {
    [t resignFirstResponder];
    return YES;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return self.folder ? 4 : 3;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == GMEdName || s == GMEdDelete) return 1;
    if (s == GMEdInclude) return GMIncludeTypes().count + _include.count + 1;
    return GMExcludeTypes().count + _exclude.count + 1;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return s == GMEdName ? @"Tên" : s == GMEdInclude ? @"Đưa vào thư mục" : s == GMEdExclude ? @"Loại trừ" : nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == GMEdInclude) return @"Chọn loại chat và / hoặc thêm từng chat.";
    if (s == GMEdExclude) return @"Chat thêm riêng ở trên luôn có trong thư mục.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (ip.section == GMEdName) {
        _name.frame = CGRectMake(12, 7, c.contentView.bounds.size.width - 24, 30);
        _name.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [c.contentView addSubview:_name];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    if (ip.section == GMEdDelete) {
        c.textLabel.text = @"Xoá thư mục";
        c.textLabel.textAlignment = GMAlignCenter;
        c.textLabel.textColor = [UIColor colorWithRed:0.86 green:0.2 blue:0.16 alpha:1];
        return c;
    }
    NSArray *types = ip.section == GMEdInclude ? GMIncludeTypes() : GMExcludeTypes();
    NSMutableArray *list = ip.section == GMEdInclude ? _include : _exclude;
    if (ip.row < (NSInteger)types.count) {
        NSArray *t = [types objectAtIndex:ip.row];
        c.textLabel.text = [t objectAtIndex:1];
        c.accessoryType = [GMVal(_f, [t objectAtIndex:0]) boolValue] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        return c;
    }
    NSInteger i = ip.row - types.count;
    if (i < (NSInteger)list.count) {
        c.textLabel.text = GMPeerName([list objectAtIndex:i]);
        c.textLabel.font = [UIFont systemFontOfSize:16];
        return c;
    }
    c.textLabel.text = ip.section == GMEdInclude ? @"Thêm chat…" : @"Loại một chat…";
    c.textLabel.textColor = [GMTheme accent];
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == GMEdName) return;
    if (ip.section == GMEdDelete) {
        UIActionSheet *s = [[UIActionSheet alloc] initWithTitle:@"Xoá thư mục này? (Chat trong đó vẫn còn.)" delegate:self
                                              cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
        s.destructiveButtonIndex = [s addButtonWithTitle:@"Xoá thư mục"];
        s.cancelButtonIndex = [s addButtonWithTitle:@"Huỷ"];
        [s showFromRect:[tv rectForRowAtIndexPath:ip] inView:tv animated:YES];
        return;
    }
    NSArray *types = ip.section == GMEdInclude ? GMIncludeTypes() : GMExcludeTypes();
    NSMutableArray *list = ip.section == GMEdInclude ? _include : _exclude;
    if (ip.row < (NSInteger)types.count) {
        NSString *k = [[types objectAtIndex:ip.row] objectAtIndex:0];
        [_f setObject:@(![GMVal(_f, k) boolValue]) forKey:k];
        [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
        return;
    }
    if (ip.row - (NSInteger)types.count < (NSInteger)list.count) return;  // chat đã thêm: vuốt để bỏ
    [self pickInto:list];
}

- (void)pickInto:(NSMutableArray *)list {
    GMPickChatViewController *p = [[GMPickChatViewController alloc] initWithStyle:UITableViewStylePlain];
    GMChatListViewController *l = GMList();
    p.myId = l.myId;
    p.allowChannels = YES;
    p.pickTitle = list == _include ? @"Thêm chat" : @"Loại chat";
    __weak GMFolderEditViewController *ws = self;
    NSMutableArray *other = list == _include ? _exclude : _include;
    p.picked = ^(NSString *peer, NSString *name) {
        NSString *key = [peer isEqual:l.myId] ? @"self" : peer;
        if (![list containsObject:key]) [list addObject:key];
        [other removeObject:key];
        [ws.tableView reloadData];
    };
    [self presentViewController:[[UINavigationController alloc] initWithRootViewController:p] animated:YES completion:nil];
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section != GMEdInclude && ip.section != GMEdExclude) return NO;
    NSInteger n = (ip.section == GMEdInclude ? GMIncludeTypes() : GMExcludeTypes()).count;
    NSInteger i = ip.row - n;
    return i >= 0 && i < (NSInteger)(ip.section == GMEdInclude ? _include : _exclude).count;
}

- (NSString *)tableView:(UITableView *)tv titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)ip {
    return @"Bỏ";
}

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete) return;
    NSMutableArray *list = ip.section == GMEdInclude ? _include : _exclude;
    NSInteger i = ip.row - (ip.section == GMEdInclude ? GMIncludeTypes() : GMExcludeTypes()).count;
    if (i < 0 || i >= (NSInteger)list.count) return;
    [list removeObjectAtIndex:i];
    [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationFade];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)i {
    if (i != sheet.destructiveButtonIndex) return;
    [GMCore call:@"folders.delete" args:@{@"id": GMVal(_f, @"id")} done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.view];
            return;
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:GMFoldersChangedNotification object:nil];
        [self.navigationController popViewControllerAnimated:YES];
    }];
}

- (void)save {
    if (_saving) return;
    [_name resignFirstResponder];
    NSString *title = [_name.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!title.length) {
        [GMTheme toast:@"Đặt tên cho thư mục" in:self.view];
        return;
    }
    [_f setObject:title forKey:@"title"];
    [_f setObject:_include forKey:@"include"];
    [_f setObject:_exclude forKey:@"exclude"];
    _saving = YES;
    [GMCore call:@"folders.save" args:_f done:^(id ok, NSDictionary *err) {
        _saving = NO;
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.view];
            return;
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:GMFoldersChangedNotification object:nil];
        [self.navigationController popViewControllerAnimated:YES];
    }];
}

- (void)debugSave:(NSString *)title {
    _name.text = title;
    [self save];
}

@end
