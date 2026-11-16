#import "GMStorageViewController.h"
#import "GMCore.h"
#import "GMTheme.h"

typedef NS_ENUM(NSInteger, GMStoreSection) { GMStoreUsage, GMStoreAuto, GMStoreClear, GMStoreChats, GMStoreCount };

static NSString *GMKeepText(long long days) {
    if (days <= 0) return @"Mãi mãi";
    if (days == 7) return @"1 tuần";
    if (days == 30) return @"1 tháng";
    return [NSString stringWithFormat:@"%lld ngày", days];
}

static NSString *GMLimitText(long long mb) {
    if (mb <= 0) return @"Không giới hạn";
    if (mb >= 1024) return [NSString stringWithFormat:@"%lld GB", mb / 1024];
    return [NSString stringWithFormat:@"%lld MB", mb];
}

static NSString *GMKindTitle(NSString *k) {
    NSDictionary *t = @{@"photo": @"Ảnh", @"video": @"Video", @"file": @"Tệp", @"music": @"Nhạc", @"voice": @"Tin thoại",
                        @"sticker": @"Sticker", @"avatar": @"Ảnh đại diện", @"other": @"Tệp tạm"};
    return [t objectForKey:k] ?: k;
}

@interface GMStorageViewController () <UIActionSheetDelegate>
@end

@implementation GMStorageViewController {
    NSDictionary *_stats;
    NSArray *_kinds;          // loại có dung lượng > 0, theo thứ tự của lõi
    NSArray *_sheetActions;   // việc ứng với từng nút của bảng chọn đang mở
    NSString *_myId;          // chat với chính mình = «Tin nhắn đã lưu»
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Dữ liệu và bộ nhớ";
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(coreEvent:) name:GMCoreEventNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)coreEvent:(NSNotification *)n {
    if ([[n.userInfo objectForKey:@"e"] isEqual:@"cache.cleared"]) [self reload];
}

- (void)reload {
    if (!_myId) {
        [GMCore call:@"auth.state" args:nil done:^(id ok, NSDictionary *err) {
            _myId = [GMVal(GMVal(ok, @"me"), @"id") description];
            if (_myId) [self.tableView reloadData];
        }];
    }
    [GMCore call:@"cache.stats" args:nil done:^(id ok, NSDictionary *err) {
        if (!ok) return;
        _stats = ok;
        NSMutableArray *ks = [NSMutableArray array];
        for (NSString *k in @[@"photo", @"video", @"file", @"music", @"voice", @"sticker", @"avatar", @"other"]) {
            if ([GMVal(GMVal(ok, @"kinds"), k) longLongValue] > 0) [ks addObject:k];
        }
        _kinds = ks;
        [self.tableView reloadData];
    }];
}

- (double)total {
    return [GMVal(_stats, @"total") doubleValue];
}

- (NSArray *)chats {
    NSArray *c = GMVal(_stats, @"chats");
    return [c isKindOfClass:[NSArray class]] ? c : @[];
}

#pragma mark Bảng

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return GMStoreCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)s {
    switch (s) {
        case GMStoreUsage: return _kinds.count + 1;
        case GMStoreAuto: return 2;
        case GMStoreClear: return 1;
        default: return [self chats].count;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)s {
    if (s == GMStoreUsage) return @"Bộ nhớ đệm";
    if (s == GMStoreAuto) return @"Tự động dọn";
    if (s == GMStoreChats && [self chats].count) return @"Theo chat";
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)s {
    if (s == GMStoreUsage) {
        id free = GMVal(_stats, @"free"), disk = GMVal(_stats, @"disk");
        NSString *f = free ? [NSString stringWithFormat:@"Máy còn trống %@ / %@. ", [GMTheme sizeText:[free doubleValue]],
                                                       [GMTheme sizeText:[disk doubleValue]]]
                           : @"";
        return [f stringByAppendingString:@"Chạm một loại để xoá riêng loại đó."];
    }
    if (s == GMStoreAuto) {
        return @"Ảnh, video, tệp không mở lại trong thời gian giữ sẽ tự xoá khỏi máy. Bộ nhớ đệm đầy thì tệp lâu không dùng "
               @"nhất bị xoá trước để nhường chỗ cho tệp mới; máy sắp hết chỗ (còn dưới 300 MB) thì tự dọn thêm. "
               @"Mọi thứ vẫn còn trên Telegram, cần thì tải lại.";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    if (ip.section == GMStoreUsage) {
        if (ip.row < (NSInteger)_kinds.count) {
            NSString *k = [_kinds objectAtIndex:ip.row];
            c.textLabel.text = GMKindTitle(k);
            c.detailTextLabel.text = [GMTheme sizeText:[GMVal(GMVal(_stats, @"kinds"), k) doubleValue]];
        } else {
            c.textLabel.text = @"Tổng";
            c.textLabel.font = [UIFont boldSystemFontOfSize:17];
            c.detailTextLabel.text = _stats ? [GMTheme sizeText:[self total]] : @"Đang tính…";
            c.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    } else if (ip.section == GMStoreAuto) {
        c.textLabel.text = ip.row == 0 ? @"Giữ media" : @"Giới hạn bộ nhớ đệm";
        if (_stats) {
            long long v = [GMVal(_stats, ip.row == 0 ? @"keep_days" : @"limit_mb") longLongValue];
            c.detailTextLabel.text = ip.row == 0 ? GMKeepText(v) : GMLimitText(v);
        }
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (ip.section == GMStoreClear) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.textLabel.text = @"Xoá bộ nhớ đệm";
        c.textLabel.textAlignment = GMAlignCenter;
        BOOL any = [self total] > 0;
        c.textLabel.textColor = any ? [UIColor colorWithRed:0.86 green:0.2 blue:0.16 alpha:1] : [GMTheme secondaryText];
        c.selectionStyle = any ? UITableViewCellSelectionStyleBlue : UITableViewCellSelectionStyleNone;
    } else {
        NSDictionary *ch = [[self chats] objectAtIndex:ip.row];
        NSString *name = GMVal(ch, @"name");
        NSString *peer = [GMVal(ch, @"peer") description];
        if (_myId && [peer isEqual:_myId]) name = @"Tin nhắn đã lưu";
        c.textLabel.text = name.length ? name : [NSString stringWithFormat:@"Chat %@", peer];
        c.detailTextLabel.text = [GMTheme sizeText:[GMVal(ch, @"bytes") doubleValue]];
    }
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (!_stats) return;
    __weak GMStorageViewController *ws = self;
    if (ip.section == GMStoreUsage && ip.row < (NSInteger)_kinds.count) {
        NSString *k = [_kinds objectAtIndex:ip.row];
        NSString *size = [GMTheme sizeText:[GMVal(GMVal(_stats, @"kinds"), k) doubleValue]];
        [self sheet:nil
            buttons:@[[NSString stringWithFormat:@"Xoá %@ (%@)", GMKindTitle(k).lowercaseString, size]]
        destructive:YES
                 at:ip
            actions:@[^{ [ws clear:@{@"kinds": @[k]}]; }]];
    } else if (ip.section == GMStoreAuto && ip.row == 0) {
        NSArray *opts = @[@3, @7, @30, @0];
        NSMutableArray *titles = [NSMutableArray array], *acts = [NSMutableArray array];
        for (NSNumber *d in opts) {
            [titles addObject:GMKeepText(d.longLongValue)];
            [acts addObject:^{ [ws setPolicy:@{@"keep_days": d}]; }];
        }
        [self sheet:@"Giữ media trên máy (tính từ lần mở cuối)" buttons:titles destructive:NO at:ip actions:acts];
    } else if (ip.section == GMStoreAuto) {
        NSArray *opts = @[@256, @512, @1024, @2048, @5120, @0];
        NSMutableArray *titles = [NSMutableArray array], *acts = [NSMutableArray array];
        for (NSNumber *mb in opts) {
            [titles addObject:GMLimitText(mb.longLongValue)];
            [acts addObject:^{ [ws setPolicy:@{@"limit_mb": mb}]; }];
        }
        [self sheet:@"Bộ nhớ đệm tối đa" buttons:titles destructive:NO at:ip actions:acts];
    } else if (ip.section == GMStoreClear && [self total] > 0) {
        NSString *t = [NSString stringWithFormat:@"Xoá toàn bộ bộ nhớ đệm (%@)? Tin nhắn không mất, media cần thì tải lại.",
                                                 [GMTheme sizeText:[self total]]];
        [self sheet:t buttons:@[@"Xoá tất cả"] destructive:YES at:ip actions:@[^{ [ws clear:@{}]; }]];
    } else if (ip.section == GMStoreChats) {
        NSDictionary *ch = [[self chats] objectAtIndex:ip.row];
        NSString *peer = GMVal(ch, @"peer");
        NSString *b = [NSString stringWithFormat:@"Xoá media của chat này (%@)", [GMTheme sizeText:[GMVal(ch, @"bytes") doubleValue]]];
        [self sheet:nil buttons:@[b] destructive:YES at:ip actions:@[^{ [ws clear:@{@"peer": peer}]; }]];
    }
}

/// Bảng chọn từ hàng `ip` (iPad: bong bóng chỉ vào hàng). `actions[i]` chạy khi chọn nút `i`.
- (void)sheet:(NSString *)title buttons:(NSArray *)titles destructive:(BOOL)destructive at:(NSIndexPath *)ip
      actions:(NSArray *)actions {
    UIActionSheet *s = [[UIActionSheet alloc] initWithTitle:title delegate:self cancelButtonTitle:nil
                                     destructiveButtonTitle:nil otherButtonTitles:nil];
    for (NSString *t in titles) [s addButtonWithTitle:t];
    if (destructive) s.destructiveButtonIndex = 0;
    s.cancelButtonIndex = [s addButtonWithTitle:@"Huỷ"];
    _sheetActions = actions;
    [s showFromRect:[self.tableView rectForRowAtIndexPath:ip] inView:self.tableView animated:YES];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)i {
    NSArray *acts = _sheetActions;
    _sheetActions = nil;
    if (i >= 0 && i < (NSInteger)acts.count) ((void (^)(void))[acts objectAtIndex:i])();
}

- (void)clear:(NSDictionary *)args {
    [GMCore call:@"cache.clear" args:args done:^(id ok, NSDictionary *err) {
        if (ok) {
            [GMTheme toast:[NSString stringWithFormat:@"Đã xoá %@", [GMTheme sizeText:[GMVal(ok, @"freed") doubleValue]]]
                        in:self.navigationController.view];
        }
        [self reload];
    }];
}

- (void)setPolicy:(NSDictionary *)args {
    [GMCore call:@"cache.set" args:args done:^(id ok, NSDictionary *err) {
        [self reload];
    }];
}

- (void)debugTapSection:(NSInteger)section row:(NSInteger)row {
    NSIndexPath *ip = [NSIndexPath indexPathForRow:row inSection:section];
    [self tableView:self.tableView didSelectRowAtIndexPath:ip];
}

@end
