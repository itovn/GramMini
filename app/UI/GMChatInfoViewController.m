#import "GMChatInfoViewController.h"
#import "GMAppDelegate.h"
#import "GMChatListViewController.h"
#import "GMCore.h"
#import "GMImages.h"
#import "GMSearchController.h"
#import "GMSharedMediaViewController.h"
#import "GMAccountViewControllers.h"
#import "GMTheme.h"

NSString *const GMChatMutedNotification = @"GMChatMuted";

typedef NS_ENUM(NSInteger, GMInfoSection) { GMInfoHead, GMInfoRows, GMInfoNotify, GMInfoShared, GMInfoMembers, GMInfoCount };

@implementation GMChatInfoViewController {
    NSDictionary *_info;
    NSArray *_rows;     // @[tiêu đề, giá trị]
    NSArray *_members;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (BOOL)isSaved {
    return [self.peer isEqual:self.myId];
}

- (BOOL)isUser {
    return [self.kind isEqual:@"user"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self isUser] ? @"Thông tin" : [self.kind isEqual:@"channel"] ? @"Thông tin kênh" : @"Thông tin nhóm";
    _rows = @[];
    [GMCore call:@"chat.info" args:@{@"peer": self.peer} done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.view];
            return;
        }
        _info = ok;
        [self buildRows];
        [self.tableView reloadData];
        if (![self isUser] && ([self.kind isEqual:@"group"] || [GMVal(ok, @"can_view_members") boolValue])) [self loadMembers];
    }];
}

static NSString *GMPrettyPhone(NSString *p) {
    if (![p isKindOfClass:[NSString class]] || !p.length) return nil;
    NSString *d = [p hasPrefix:@"+"] ? [p substringFromIndex:1] : p;
    if ([d hasPrefix:@"84"] && d.length >= 11) {
        return [NSString stringWithFormat:@"+84 %@ %@ %@", [d substringWithRange:NSMakeRange(2, 3)],
                                          [d substringWithRange:NSMakeRange(5, 3)], [d substringFromIndex:8]];
    }
    return [@"+" stringByAppendingString:d];
}

- (void)buildRows {
    NSMutableArray *r = [NSMutableArray array];
    NSString *phone = GMPrettyPhone(GMVal(_info, @"phone"));
    if (phone) [r addObject:@[@"điện thoại", phone]];
    NSString *u = GMVal(_info, @"username");
    if ([u isKindOfClass:[NSString class]] && u.length) {
        [r addObject:@[[self isUser] ? @"tên người dùng" : @"liên kết", [self isUser] ? [@"@" stringByAppendingString:u]
                                                                                      : [@"t.me/" stringByAppendingString:u]]];
    }
    NSString *about = GMVal(_info, @"about");
    if ([about isKindOfClass:[NSString class]] && about.length) [r addObject:@[[self isUser] ? @"giới thiệu" : @"mô tả", about]];
    _rows = r;
}

- (void)loadMembers {
    [GMCore call:@"chat.members" args:@{@"peer": self.peer, @"limit": @200} done:^(id ok, NSDictionary *err) {
        if (![ok isKindOfClass:[NSArray class]]) return;
        // Trực tuyến lên trước
        _members = [ok sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            BOOL oa = [GMVal(GMVal(a, @"status"), @"status") isEqual:@"online"], ob = [GMVal(GMVal(b, @"status"), @"status") isEqual:@"online"];
            return oa == ob ? NSOrderedSame : oa ? NSOrderedAscending : NSOrderedDescending;
        }];
        [self.tableView reloadData];
    }];
}

#pragma mark Bảng

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return GMInfoCount;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
        case GMInfoHead: return 1;
        case GMInfoRows: return [self isSaved] ? 0 : _rows.count;
        case GMInfoNotify: return [self isSaved] || !_info ? 0 : ([self canRename] ? 2 : 1);
        case GMInfoShared: return 4;
        default: return _members.count;
    }
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == GMInfoShared) return @"Đã chia sẻ";
    if (s == GMInfoMembers && _members.count) {
        id n = GMVal(_info, @"members");
        return [NSString stringWithFormat:@"%@ thành viên", n ?: @(_members.count)];
    }
    return nil;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == GMInfoHead) return 96;
    if (ip.section == GMInfoMembers) return 56;
    if (ip.section == GMInfoRows) {
        NSString *v = [[_rows objectAtIndex:ip.row] objectAtIndex:1];
        CGFloat w = tv.bounds.size.width - 60;
        CGSize s = [v sizeWithFont:[UIFont systemFontOfSize:16] constrainedToSize:CGSizeMake(w, 2000) lineBreakMode:GMWordWrap];
        return MAX(56, s.height + 34);
    }
    return 44;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == GMInfoHead) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        NSString *name = [self isSaved] ? @"Tin nhắn đã lưu" : (GMVal(_info, @"name") ?: self.name ?: @"");
        c.textLabel.text = name;
        c.textLabel.font = [UIFont boldSystemFontOfSize:19];
        c.textLabel.numberOfLines = 2;
        c.detailTextLabel.textColor = [GMTheme secondaryText];
        if (_info && ![self isSaved]) {
            NSMutableDictionary *st = [([self isUser] ? GMVal(_info, @"status") : _info) mutableCopy] ?: [NSMutableDictionary dictionary];
            [st setObject:self.kind ?: @"user" forKey:@"kind"];
            if ([GMVal(_info, @"bot") boolValue]) [st setObject:@YES forKey:@"bot"];
            c.detailTextLabel.text = [GMTheme statusText:st];
        }
        c.imageView.image = [GMTheme avatarFor:self.peer name:[self isSaved] ? @"★" : name size:72];
        if (![self isSaved] && GMVal(_info, @"photo")) {
            __weak UITableViewCell *wc = c;
            [GMImages avatarForPeer:self.peer photo:[GMVal(_info, @"photo") description] dc:GMVal(_info, @"photo_dc") size:72
                               done:^(UIImage *img) {
                                   if (img) wc.imageView.image = img;
                                   [wc setNeedsLayout];
                               }];
        }
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    if (ip.section == GMInfoRows) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        NSArray *row = [_rows objectAtIndex:ip.row];
        c.textLabel.text = [row objectAtIndex:0];
        c.textLabel.font = [UIFont systemFontOfSize:13];
        c.textLabel.textColor = [GMTheme accent];
        c.detailTextLabel.text = [row objectAtIndex:1];
        c.detailTextLabel.font = [UIFont systemFontOfSize:16];
        c.detailTextLabel.textColor = [UIColor blackColor];
        c.detailTextLabel.numberOfLines = 0;
        return c;
    }
    if (ip.section == GMInfoNotify && ip.row == 1) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.textLabel.text = @"Sửa tên liên hệ";
        c.textLabel.textColor = [GMTheme accent];
        return c;
    }
    if (ip.section == GMInfoNotify) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.textLabel.text = @"Thông báo";
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = ![GMVal(_info, @"muted") boolValue];
        [sw addTarget:self action:@selector(muteChanged:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        return c;
    }
    if (ip.section == GMInfoShared) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.textLabel.text = [@[@"Ảnh và video", @"Tệp", @"Tin thoại", @"Liên kết"] objectAtIndex:ip.row];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    NSDictionary *m = [_members objectAtIndex:ip.row];
    NSDictionary *st = GMVal(m, @"status");
    NSString *role = [GMVal(m, @"role") isEqual:@"creator"] ? @"người tạo" : [GMVal(m, @"role") isEqual:@"admin"] ? @"quản trị viên" : nil;
    NSString *s = [GMVal(m, @"bot") boolValue] ? @"bot" : [st isKindOfClass:[NSDictionary class]] ? [GMTheme statusText:st] : @"";
    UITableViewCell *c = GMPeerCell(tv, m, role ? [NSString stringWithFormat:@"%@ · %@", s, role] : s, self.myId);
    c.detailTextLabel.textColor = [GMVal(st, @"status") isEqual:@"online"] ? [GMTheme accent] : [GMTheme secondaryText];
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == GMInfoRows) {
        NSArray *row = [_rows objectAtIndex:ip.row];
        NSString *v = [row objectAtIndex:1];
        if ([[row objectAtIndex:0] isEqual:@"điện thoại"]) v = [v stringByReplacingOccurrencesOfString:@" " withString:@""];
        [UIPasteboard generalPasteboard].string = v;
        [GMTheme toast:@"Đã sao chép" in:self.navigationController.view];
    } else if (ip.section == GMInfoNotify && ip.row == 1) {
        [self renameContact];
    } else if (ip.section == GMInfoShared) {
        GMSharedMediaViewController *m = [[GMSharedMediaViewController alloc] init];
        m.peer = self.peer;
        m.kind = [@[@"photo", @"file", @"voice", @"link"] objectAtIndex:ip.row];
        m.myId = self.myId;
        m.chatName = [self isSaved] ? @"Tin nhắn đã lưu" : (GMVal(_info, @"name") ?: self.name);
        [self.navigationController pushViewController:m animated:YES];
    } else if (ip.section == GMInfoMembers) {
        NSDictionary *m = [_members objectAtIndex:ip.row];
        GMAppDelegate *app = (GMAppDelegate *)[UIApplication sharedApplication].delegate;
        [app.list openChat:m jumpTo:nil];
    }
}

- (BOOL)canRename {
    return [self isUser] && ![self isSaved] && ![GMVal(_info, @"bot") boolValue];
}

/// Tên mình lưu cho người này (Telegram hiện tên này thay tên họ tự đặt — vd thông báo hiện tên đã lưu thay tên người đó tự đặt).
- (void)renameContact {
    GMEditNameViewController *e = [[GMEditNameViewController alloc] init];
    e.title = @"Sửa tên liên hệ";
    e.first = GMVal(_info, @"name") ?: self.name;
    e.last = @"";
    NSString *peer = self.peer;
    __weak GMChatInfoViewController *ws = self;
    e.save = ^(NSString *first, NSString *last, void (^finish)(NSDictionary *err)) {
        [GMCore call:@"contacts.rename" args:@{@"peer": peer, @"first": first, @"last": last} done:^(id ok, NSDictionary *err) {
            finish(err);
            if (err) return;
            GMChatInfoViewController *s = ws;
            NSMutableDictionary *i = [s->_info mutableCopy];
            [i setObject:last.length ? [NSString stringWithFormat:@"%@ %@", first, last] : first forKey:@"name"];
            s->_info = i;
            [s.tableView reloadData];
            GMAppDelegate *app = (GMAppDelegate *)[UIApplication sharedApplication].delegate;
            [app.list reload];  // tên chat trong danh sách
        }];
    };
    [self.navigationController pushViewController:e animated:YES];
}

- (void)muteChanged:(UISwitch *)sw {
    BOOL mute = !sw.on;
    [GMCore call:@"chat.mute" args:@{@"peer": self.peer, @"mute": @(mute)} done:^(id ok, NSDictionary *err) {
        if (err) {
            sw.on = mute;  // trả lại
            [GMTheme toast:GMErrorText(err) in:self.view];
            return;
        }
        NSMutableDictionary *i = [_info mutableCopy];
        [i setObject:@(mute) forKey:@"muted"];
        _info = i;
        [[NSNotificationCenter defaultCenter] postNotificationName:GMChatMutedNotification object:nil
                                                          userInfo:@{@"peer": self.peer, @"muted": @(mute)}];
    }];
}

@end
