#import "GMChatListViewController.h"
#import "GMChatViewController.h"
#import "GMContactsViewController.h"
#import "GMChatInfoViewController.h"
#import "GMSearchController.h"
#import "GMBackground.h"
#import "GMCompat.h"
#import "GMCore.h"
#import "GMImages.h"
#import "GMLog.h"
#import "GMTheme.h"
#import "GMTitleView.h"
#import "GMFoldersViewController.h"
#import "GMAppDelegate.h"
#import "GMTopicsViewController.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kRowH = GMDialogRowH, kAvatar = GMDialogAvatar, kCard = 8;

@implementation GMDialogCell

- (UILabel *)label:(UIFont *)f color:(UIColor *)c {
    UILabel *l = [[UILabel alloc] init];
    l.font = f;
    l.textColor = c;
    l.backgroundColor = [UIColor clearColor];
    l.highlightedTextColor = c;
    [self.contentView addSubview:l];
    return l;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    if ((self = [super initWithStyle:style reuseIdentifier:rid])) {
        self.tag = GMTagOwnBackground;
        self.backgroundColor = [UIColor clearColor];
        self.backgroundView = [[UIImageView alloc] init];
        self.selectedBackgroundView = [[UIImageView alloc] init];
        _avatar = [[UIImageView alloc] init];
        [self.contentView addSubview:_avatar];
        _name = [self label:[UIFont boldSystemFontOfSize:16] color:[GMTheme text]];
        _time = [self label:[UIFont systemFontOfSize:13] color:[GMTheme secondaryText]];
        _time.textAlignment = GMAlignRight;
        _check = [self label:[UIFont boldSystemFontOfSize:12] color:[GMTheme checkColor]];
        _check.textAlignment = GMAlignRight;
        _sender = [self label:[UIFont systemFontOfSize:15] color:[GMTheme text]];
        _preview = [self label:[UIFont systemFontOfSize:15] color:[GMTheme secondaryText]];
        _badgeBg = [[UIImageView alloc] init];
        [self.contentView addSubview:_badgeBg];
        _badge = [self label:[UIFont boldSystemFontOfSize:13] color:[UIColor whiteColor]];
        _badge.textAlignment = GMAlignCenter;
        _badge.shadowColor = [UIColor colorWithWhite:0 alpha:0.3];
        _badge.shadowOffset = CGSizeMake(0, -1);
        _pin = [self label:[UIFont systemFontOfSize:13] color:[GMTheme secondaryText]];
        _pin.text = @"📌";
        _line = [[UIView alloc] init];
        _line.backgroundColor = [GMTheme glassLine];
        [self.contentView addSubview:_line];
    }
    return self;
}

/// Hàng đầu / cuối của thẻ (bo góc trên / dưới).
- (void)setFirst:(BOOL)first last:(BOOL)last {
    _first = first;
    _last = last;
    ((UIImageView *)self.backgroundView).image = [GMTheme cardRow:first last:last selected:NO];
    ((UIImageView *)self.selectedBackgroundView).image = [GMTheme cardRow:first last:last selected:YES];
    _line.hidden = last;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // Toạ độ trong thẻ: lề thẻ 8 + lề trong 10
    CGFloat w = self.contentView.bounds.size.width - kCard, x0 = kCard + 10, x = x0 + kAvatar + 10;
    _avatar.frame = CGRectMake(x0, (kRowH - kAvatar) / 2, kAvatar, kAvatar);
    CGFloat tw = [_time.text sizeWithFont:_time.font].width;
    _time.frame = CGRectMake(w - 10 - tw, 10, tw, 18);
    CGFloat cw = _check.hidden ? 0 : [_check.text sizeWithFont:_check.font].width + 3;
    _check.frame = CGRectMake(w - 10 - tw - cw, 10, cw, 18);
    _name.frame = CGRectMake(x, 8, w - x - tw - cw - 16, 21);
    CGFloat right = 10;
    _badgeBg.hidden = _badge.hidden;
    if (!_badge.hidden) {
        CGFloat bw = MAX(22, [_badge.text sizeWithFont:_badge.font].width + 14);
        _badge.frame = CGRectMake(w - 10 - bw, 38, bw, 21);
        _badgeBg.frame = CGRectMake(w - 10 - bw, 37, bw, 22);
        right += bw + 6;
    } else if (!_pin.hidden) {
        _pin.frame = CGRectMake(w - 10 - 18, 38, 18, 20);
        right += 24;
    }
    if (_sender.hidden) {
        _preview.numberOfLines = 2;
        _preview.frame = CGRectMake(x, 30, w - x - right, 38);
    } else {
        _sender.frame = CGRectMake(x, 30, w - x - right, 19);
        _preview.numberOfLines = 1;
        _preview.frame = CGRectMake(x, 49, w - x - right, 19);
    }
    _line.frame = CGRectMake(x, kRowH - 1, w - x - 1, 1);
}

@end

@interface GMChatListViewController () <UIActionSheetDelegate>
@end

@implementation GMChatListViewController {
    NSMutableArray *_dialogs;  // NSMutableDictionary: peer, name, kind, unread, pinned, muted, read_out, last
    BOOL _loading;
    id _refresh;  // UIRefreshControl (iOS 6) — iOS 5 dùng nút làm mới
    UILabel *_empty;
    GMTitleView *_titleView;
    NSString *_pendingPeer;  // chạm thông báo lúc danh sách chưa tải xong
    NSMutableDictionary *_typing;  // peer → @{text, until} — «đang gõ…» thay dòng tin cuối
    GMSearchController *_search;
    NSString *_actionPeer;   // chat đang mở bảng chọn (nhấn giữ / vuốt xoá)
    NSArray *_actions;       // khối việc theo nút của bảng chọn
    NSArray *_folders;       // thư mục chat (folders.list)
    NSInteger _folder;       // thẻ đang chọn: 0 = Tất cả, i = _folders[i - 1]
    NSArray *_shown;         // chat của thẻ đang chọn (cùng đối tượng với _dialogs)
    UIView *_folderBar;      // dải thẻ thư mục (đầu mục 0 — dính dưới thanh trên khi cuộn)
    UIScrollView *_folderScroll;
    UIButton *_login;        // «Đăng nhập» khi chưa đăng nhập
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Chat";
    _titleView = [[GMTitleView alloc] init];
    _titleView.title = @"Chat";
    _titleView.replaceTitle = YES;
    self.navigationItem.titleView = _titleView;
    _dialogs = [NSMutableArray array];
    self.tableView.rowHeight = kRowH;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    // «Sửa»: bật / tắt chế độ xoá (nút đỏ bên trái mỗi chat); Cài đặt nằm ở thanh dưới
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Sửa" style:UIBarButtonItemStyleBordered target:self action:@selector(toggleEdit)];
    // Nút biểu tượng tự vẽ (ảnh của nút hệ thống iOS 5 / 6 bị tô trắng)
    UIBarButtonItem *compose = [GMTheme barButtonIcon:@"compose" target:self action:@selector(compose)];
    self.navigationItem.backBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Chat" style:UIBarButtonItemStylePlain target:nil action:nil];
    Class rc = NSClassFromString(@"UIRefreshControl");
    if (rc) {
        _refresh = [[rc alloc] init];
        [_refresh addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
        [self setValue:_refresh forKey:@"refreshControl"];
        self.navigationItem.rightBarButtonItem = compose;
    } else {
        // iOS 5: không có kéo để làm mới → thêm nút
        UIBarButtonItem *reload = [GMTheme barButtonIcon:@"refresh" target:self action:@selector(reload)];
        self.navigationItem.rightBarButtonItems = @[compose, reload];
    }
    // Ô tìm kiếm (kéo xuống mới thấy, như Telegram 4.9): chat đã có + trên Telegram + tin nhắn
    UISearchBar *bar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.tableView.tableHeaderView = bar;
    self.tableView.contentOffset = CGPointMake(0, 44);
    _search = [[GMSearchController alloc] initWithSearchBar:bar contents:self];
    _search.messages = YES;
    __weak GMChatListViewController *ws = self;
    _search.local = ^NSArray *(NSString *q) {
        GMChatListViewController *s = ws;
        if (!q.length || !s) return @[];
        s->_search.myId = s.myId;  // biết lúc tải xong tài khoản — «Tin nhắn đã lưu» thay tên mình
        NSMutableArray *out = [NSMutableArray array];
        for (NSDictionary *d in s->_dialogs) {
            BOOL saved = [GMVal(d, @"peer") isEqual:s.myId];
            if (GMMatches(saved ? @"Tin nhắn đã lưu" : GMVal(d, @"name"), q)) [out addObject:d];
        }
        return out;
    };
    _search.pick = ^(NSDictionary *it, NSNumber *msg) {
        [ws openChat:it jumpTo:msg];
    };
    // Nhấn giữ một chat: ghim, tắt tiếng, đánh dấu đã đọc, xoá
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPress:)];
    [self.tableView addGestureRecognizer:lp];
    _empty = [[UILabel alloc] initWithFrame:CGRectMake(0, 80, self.view.bounds.size.width, 60)];
    _empty.textAlignment = GMAlignCenter;
    _empty.textColor = [GMTheme secondaryText];
    _empty.numberOfLines = 2;
    _empty.backgroundColor = [UIColor clearColor];
    _empty.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.tableView addSubview:_empty];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(event:) name:GMCoreEventNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(becameActive)
                                                 name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(muted:) name:GMChatMutedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(loadFolders) name:GMFoldersChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadRows) name:GMOpenChatChangedNotification object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadRows];
}

- (void)reload {
    // Dựng màn trước (mảng chat / nhãn tạo ở viewDidLoad): đổi giao diện lúc đang ở mục khác của thanh dưới thì màn chưa dựng
    (void)self.view;
    if (_loading) return;
    _loading = YES;
    if (!_dialogs.count) _empty.text = @"Đang tải…";
    long long t = GMNowMs();
    [self loadFolders];
    [GMCore call:@"dialogs.list" args:@{@"limit": @100} done:^(id ok, NSDictionary *err) {
        _loading = NO;
        GM_IOS6_BEGIN
        [_refresh endRefreshing];
        GM_IOS6_END
        if (err) {
            _empty.text = _dialogs.count ? @"" : GMErrorText(err);
            return;
        }
        GMLog(@"danh sách chat: %lu chat, %lld ms", (unsigned long)[ok count], GMNowMs() - t);
        [_dialogs removeAllObjects];
        for (NSDictionary *d in ok) [_dialogs addObject:[d mutableCopy]];
        _empty.text = _dialogs.count ? @"" : @"Chưa có chat nào.";
        [self reloadRows];
        [[GMBackground shared] updateBadge];
        if (_pendingPeer) [self openPeer:_pendingPeer];
    }];
}

- (void)toggleEdit {
    BOOL on = !self.tableView.editing;
    [self.tableView setEditing:on animated:YES];
    self.navigationItem.leftBarButtonItem.title = on ? @"Xong" : @"Sửa";
}

- (void)compose {
    GMContactsViewController *c = [[GMContactsViewController alloc] initWithStyle:UITableViewStylePlain];
    c.myId = self.myId;
    __weak GMChatListViewController *ws = self;
    c.pick = ^(NSDictionary *p) {
        [ws openChat:p jumpTo:nil];
    };
    [self.navigationController pushViewController:c animated:YES];
}

/// Mở chat (có trong danh sách hay chưa — người mới tìm được, chạm thông báo, kết quả tìm tin); `msgId`: nhảy tới tin đó.
- (void)openChat:(NSDictionary *)item jumpTo:(NSNumber *)msgId {
    NSString *peer = [GMVal(item, @"peer") description];
    if (!peer.length) return;
    NSUInteger i = 0;
    NSMutableDictionary *d = [self dialogFor:peer index:&i];
    // Chưa vào nhóm / kênh (link t.me, kết quả tìm): màn chat có thanh «Tham gia»
    BOOL left = !d && [GMVal(item, @"left") boolValue];
    // Nhóm có chủ đề: danh sách chủ đề (nhảy tới một tin — kết quả tìm — hoặc chưa vào nhóm thì mở màn mọi tin như cũ)
    if ([(GMVal(d, @"forum") ?: GMVal(item, @"forum")) boolValue] && !msgId && !left) {
        [self openTopics:peer item:item dialog:d];
        return;
    }
    GMAppDelegate *app = (GMAppDelegate *)[UIApplication sharedApplication].delegate;
    if (app.detail && !msgId && [[app openPeer] isEqual:peer]) {
        [app.detail popToRootViewControllerAnimated:YES];  // iPad: chat này đang mở bên phải → về màn chat
        return;
    }
    if (d) {
        [d setObject:@0 forKey:@"unread"];
        [[GMBackground shared] updateBadge];
    }
    GMChatViewController *c = [[GMChatViewController alloc] init];
    c.peer = peer;
    c.kind = GMVal(d, @"kind") ?: GMVal(item, @"kind") ?: @"user";
    c.myId = self.myId;
    c.readOut = [GMVal(d, @"read_out") integerValue];
    c.title = [peer isEqual:self.myId] ? @"Tin nhắn đã lưu" : (GMVal(d, @"name") ?: GMVal(item, @"name") ?: GMVal(item, @"chat_name") ?: @"");
    c.jumpTo = msgId;
    c.left = left;
    c.joinHash = d ? nil : GMVal(item, @"hash");
    c.photo = GMVal(d, @"photo") ?: GMVal(item, @"photo");
    c.photoDc = GMVal(d, @"photo_dc") ?: GMVal(item, @"photo_dc");
    if ([app showDetail:c]) return;  // iPad: mở bên phải, bên trái giữ nguyên
    // Mở từ mục khác của thanh dưới (Danh bạ, Cài đặt…): chuyển sang mục Chat
    if (self.tabBarController.selectedViewController != self.navigationController) {
        self.tabBarController.selectedViewController = self.navigationController;
    }
    [self.navigationController popToRootViewControllerAnimated:NO];
    [self.navigationController pushViewController:c animated:YES];
}

- (void)openTopics:(NSString *)peer item:(NSDictionary *)item dialog:(NSMutableDictionary *)d {
    GMTopicsViewController *t = [[GMTopicsViewController alloc] initWithStyle:UITableViewStylePlain];
    t.peer = peer;
    t.name = GMVal(d, @"name") ?: GMVal(item, @"name") ?: GMVal(item, @"chat_name") ?: @"";
    t.myId = self.myId;
    t.photo = GMVal(d, @"photo") ?: GMVal(item, @"photo");
    t.photoDc = GMVal(d, @"photo_dc") ?: GMVal(item, @"photo_dc");
    // Số chưa đọc của nhóm = tổng các chủ đề (đọc theo từng chủ đề)
    __weak GMChatListViewController *ws = self;
    t.unreadChanged = ^(NSInteger total) {
        NSMutableDictionary *dd = [ws dialogFor:peer index:NULL];
        if (!dd || [GMVal(dd, @"unread") integerValue] == total) return;
        [dd setObject:@(total) forKey:@"unread"];
        [ws reloadRows];
        [[GMBackground shared] updateBadge];
    };
    if ([(GMAppDelegate *)[UIApplication sharedApplication].delegate showDetail:t]) return;  // iPad: danh sách chủ đề bên phải
    if (self.tabBarController.selectedViewController != self.navigationController) {
        self.tabBarController.selectedViewController = self.navigationController;
    }
    [self.navigationController popToRootViewControllerAnimated:NO];
    [self.navigationController pushViewController:t animated:YES];
}

/// Đang mở danh sách chủ đề của nhóm này (màn đó tự đếm chưa đọc — danh sách chat không cộng thêm).
- (BOOL)topicsOpenFor:(NSString *)peer {
    for (UIViewController *vc in self.navigationController.viewControllers) {
        if ([vc isKindOfClass:[GMTopicsViewController class]] && [((GMTopicsViewController *)vc).peer isEqual:peer]) return YES;
    }
    return NO;
}

- (void)debugSearch:(NSString *)q {
    [_search debugSearch:q];
}

- (void)debugSearchTap:(NSInteger)s row:(NSInteger)r {
    [_search debugTapSection:s row:r];
}

#pragma mark - Sự kiện

- (NSMutableDictionary *)dialogFor:(NSString *)peer index:(NSUInteger *)index {
    for (NSUInteger i = 0; i < _dialogs.count; i++) {
        NSMutableDictionary *d = [_dialogs objectAtIndex:i];
        if ([[d objectForKey:@"peer"] isEqual:peer]) {
            if (index) *index = i;
            return d;
        }
    }
    return nil;
}

- (void)event:(NSNotification *)n {
    NSDictionary *ev = n.userInfo;
    NSString *e = GMVal(ev, @"e");
    if ([e isEqual:@"net.state"]) {
        BOOL ok = [GMVal(ev, @"ok") boolValue];
        _titleView.connecting = !ok;
        if (ok && !_dialogs.count) [self reload];
        return;
    }
    if ([e isEqual:@"msg.readOutbox"]) {
        NSMutableDictionary *d = [self dialogFor:GMVal(ev, @"peer") index:NULL];
        if (d) {
            [d setObject:GMVal(ev, @"max_id") ?: @0 forKey:@"read_out"];
            [self reloadRows];
        }
        return;
    }
    if ([e isEqual:@"typing"]) {
        [self typing:ev];
        return;
    }
    if (![e isEqual:@"msg.new"] && ![e isEqual:@"msg.edit"]) return;
    NSDictionary *m = GMVal(ev, @"msg");
    if ([e isEqual:@"msg.new"]) [_typing removeObjectForKey:GMVal(m, @"peer")];
    NSString *peer = GMVal(m, @"peer");
    NSUInteger idx = 0;
    NSMutableDictionary *d = [self dialogFor:peer index:&idx];
    if (!d) {
        if ([e isEqual:@"msg.new"]) [self reload];  // chat mới chưa có trong danh sách
        return;
    }
    if ([e isEqual:@"msg.edit"]) {
        if ([GMVal(GMVal(d, @"last"), @"id") isEqual:GMVal(m, @"id")]) [d setObject:m forKey:@"last"];
        [self reloadRows];
        return;
    }
    [d setObject:m forKey:@"last"];
    GMChatViewController *top = (id)self.navigationController.topViewController;
    BOOL open = [top isKindOfClass:[GMChatViewController class]] && [top.peer isEqual:peer] &&
                [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
    if (![GMVal(m, @"out") boolValue] && !open && ![self topicsOpenFor:peer]) {
        [d setObject:@([GMVal(d, @"unread") intValue] + 1) forKey:@"unread"];
    }
    // Đưa lên đầu (sau các chat ghim)
    [_dialogs removeObjectAtIndex:idx];
    NSUInteger to = 0;
    while (to < _dialogs.count && [GMVal([_dialogs objectAtIndex:to], @"pinned") boolValue]) to++;
    if ([GMVal(d, @"pinned") boolValue]) to = MIN(idx, to);
    [_dialogs insertObject:d atIndex:to];
    [self reloadRows];
    [[GMBackground shared] updateBadge];
}

- (void)typing:(NSDictionary *)ev {
    NSString *peer = GMVal(ev, @"peer");
    if (!peer || [GMVal(ev, @"from") isEqual:self.myId]) return;
    NSDictionary *d = [self dialogFor:peer index:NULL];
    if (!d) return;
    if (!_typing) _typing = [NSMutableDictionary dictionary];
    if ([GMVal(ev, @"action") isEqual:@"cancel"]) {
        [_typing removeObjectForKey:peer];
    } else {
        BOOL group = ![GMVal(d, @"kind") isEqual:@"user"];
        NSString *t = [GMTheme typingText:GMVal(ev, @"action") name:group ? GMVal(ev, @"name") : nil];
        [_typing setObject:@{@"text": t, @"until": @(GMNowMs() + 6000)} forKey:peer];
        [self performSelector:@selector(typingExpired) withObject:nil afterDelay:6.1];
    }
    [self reloadRows];
}

#pragma mark - Thao tác nhanh

- (void)longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    NSIndexPath *ip = [self.tableView indexPathForRowAtPoint:[g locationInView:self.tableView]];
    if (ip) [self actionsForRow:ip.row];
}

- (void)actionsForRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_shown.count) return;
    NSDictionary *d = [_shown objectAtIndex:row];
    NSString *peer = GMVal(d, @"peer");
    BOOL saved = [self isSaved:d], pinned = [GMVal(d, @"pinned") boolValue], muted = [GMVal(d, @"muted") boolValue];
    BOOL unread = [GMVal(d, @"unread") intValue] > 0;
    NSString *title = saved ? @"Tin nhắn đã lưu" : GMVal(d, @"name");
    UIActionSheet *s = [[UIActionSheet alloc] initWithTitle:title delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil
                                          otherButtonTitles:nil];
    NSMutableArray *acts = [NSMutableArray array];
    __weak GMChatListViewController *ws = self;
    [s addButtonWithTitle:pinned ? @"Bỏ ghim" : @"Ghim lên đầu"];
    [acts addObject:^{ [ws setPinned:!pinned peer:peer]; }];
    if (!saved) {
        [s addButtonWithTitle:muted ? @"Bật thông báo" : @"Tắt thông báo"];
        [acts addObject:^{ [ws setMuted:!muted peer:peer]; }];
    }
    if (unread) {
        [s addButtonWithTitle:@"Đánh dấu đã đọc"];
        [acts addObject:^{ [ws markRead:peer]; }];
    }
    // Thư mục: thêm vào một thư mục / bỏ khỏi thư mục đang xem
    if ([self editableFolders].count) {
        [s addButtonWithTitle:@"Thêm vào thư mục…"];
        [acts addObject:^{ [ws chooseFolderFor:peer]; }];
    }
    NSDictionary *cur = [self currentFolder];
    if (cur && ![GMVal(cur, @"chatlist") boolValue]) {
        [s addButtonWithTitle:[NSString stringWithFormat:@"Bỏ khỏi «%@»", GMVal(cur, @"title")]];
        [acts addObject:^{ [ws removePeer:peer fromFolder:cur]; }];
    }
    s.destructiveButtonIndex = [s addButtonWithTitle:[self deleteTitle:d]];
    [acts addObject:^{ [ws confirmDelete:peer]; }];
    s.cancelButtonIndex = [s addButtonWithTitle:@"Huỷ"];
    _actionPeer = peer;
    _actions = acts;
    NSIndexPath *ip = [NSIndexPath indexPathForRow:row inSection:0];
    [s showFromRect:[self.tableView rectForRowAtIndexPath:ip] inView:self.tableView animated:YES];
}

- (NSString *)deleteTitle:(NSDictionary *)d {
    NSString *k = GMVal(d, @"kind");
    if ([self isSaved:d]) return @"Xoá lịch sử";
    return [k isEqual:@"channel"] ? @"Rời kênh" : [k isEqual:@"group"] ? @"Xoá và rời nhóm" : @"Xoá chat";
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)i {
    NSArray *acts = _actions;
    _actions = nil;
    if (i >= 0 && i < (NSInteger)acts.count) ((void (^)(void))[acts objectAtIndex:i])();
}

- (void)setPinned:(BOOL)pin peer:(NSString *)peer {
    [GMCore call:@"dialogs.pin" args:@{@"peer": peer, @"pin": @(pin)} done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.navigationController.view];
            return;
        }
        [self reload];  // thứ tự chat ghim do máy chủ quyết
    }];
}

- (void)setMuted:(BOOL)mute peer:(NSString *)peer {
    [GMCore call:@"chat.mute" args:@{@"peer": peer, @"mute": @(mute)} done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.navigationController.view];
            return;
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:GMChatMutedNotification object:nil
                                                          userInfo:@{@"peer": peer, @"muted": @(mute)}];
    }];
}

- (void)markRead:(NSString *)peer {
    NSMutableDictionary *d = [self dialogFor:peer index:NULL];
    [d setObject:@0 forKey:@"unread"];
    [self reloadRows];
    [[GMBackground shared] updateBadge];
    [GMCore call:@"messages.read" args:@{@"peer": peer} done:nil];
}

- (void)confirmDelete:(NSString *)peer {
    NSUInteger i = 0;
    NSDictionary *d = [self dialogFor:peer index:&i];
    if (!d) return;
    NSString *k = GMVal(d, @"kind");
    // Chat riêng (không phải bot): như app gốc — xoá cho cả hai bên hoặc chỉ ở máy mình
    BOOL both = [k isEqual:@"user"] && ![self isSaved:d] && ![GMVal(d, @"bot") boolValue];
    NSString *msg = [self isSaved:d] ? @"Xoá mọi tin trong Tin nhắn đã lưu?"
                    : [k isEqual:@"channel"] ? @"Rời kênh này?"
                    : [k isEqual:@"group"] ? @"Rời nhóm và xoá chat này?"
                    : both ? @"Xoá chat này?"
                           : @"Xoá chat này khỏi máy bạn?";
    UIActionSheet *s = [[UIActionSheet alloc] initWithTitle:msg delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil
                                          otherButtonTitles:nil];
    __weak GMChatListViewController *ws = self;
    if (both) {
        s.destructiveButtonIndex = [s addButtonWithTitle:@"Xoá cho cả hai bên"];
        [s addButtonWithTitle:@"Xoá chỉ ở máy tôi"];
        _actions = @[^{ [ws deletePeer:peer revoke:YES]; }, ^{ [ws deletePeer:peer revoke:NO]; }];
    } else {
        s.destructiveButtonIndex = [s addButtonWithTitle:[self deleteTitle:d]];
        _actions = @[^{ [ws deletePeer:peer revoke:NO]; }];
    }
    s.cancelButtonIndex = [s addButtonWithTitle:@"Huỷ"];
    NSUInteger row = [_shown indexOfObject:d];
    CGRect from = row == NSNotFound ? CGRectMake(0, self.tableView.contentOffset.y, self.tableView.bounds.size.width, 44)
                                    : [self.tableView rectForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
    [s showFromRect:from inView:self.tableView animated:YES];
}

- (void)deletePeer:(NSString *)peer revoke:(BOOL)revoke {
    [GMCore call:@"dialogs.delete" args:@{@"peer": peer, @"revoke": @(revoke)} done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.navigationController.view];
            return;
        }
        NSUInteger i = 0;
        if ([self dialogFor:peer index:&i]) {
            [_dialogs removeObjectAtIndex:i];
            [self reloadRows];
        }
        [[GMBackground shared] updateBadge];
    }];
}

/// Vuốt sang trái trên một chat → nút «Xoá» (hỏi lại trước khi xoá).
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    return tv == self.tableView;
}

- (NSString *)tableView:(UITableView *)tv titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)ip {
    return @"Xoá";
}

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete || ip.row >= (NSInteger)_shown.count) return;
    [tv setEditing:NO animated:YES];
    [self confirmDelete:GMVal([_shown objectAtIndex:ip.row], @"peer")];
}

- (void)debugActions:(NSInteger)row {
    [self actionsForRow:row];
}

- (void)muted:(NSNotification *)n {
    NSMutableDictionary *d = [self dialogFor:[n.userInfo objectForKey:@"peer"] index:NULL];
    if (!d) return;
    [d setObject:[n.userInfo objectForKey:@"muted"] forKey:@"muted"];
    [self reloadRows];
    [[GMBackground shared] updateBadge];
}

- (void)typingExpired {
    long long now = GMNowMs();
    for (NSString *p in _typing.allKeys) {
        if ([[[_typing objectForKey:p] objectForKey:@"until"] longLongValue] <= now) [_typing removeObjectForKey:p];
    }
    [self reloadRows];
}

- (NSDictionary *)dialogForPeer:(NSString *)peer {
    return peer ? [self dialogFor:peer index:NULL] : nil;
}

- (NSInteger)unreadTotal {
    NSInteger n = 0;
    for (NSDictionary *d in _dialogs) {
        if (![GMVal(d, @"muted") boolValue]) n += [GMVal(d, @"unread") integerValue];
    }
    return n;
}

- (void)openPeer:(NSString *)peer {
    if (!peer.length) return;
    NSDictionary *d = [self dialogFor:peer index:NULL];
    if (!d) {
        _pendingPeer = peer;  // chưa tải danh sách: mở sau
        return;
    }
    _pendingPeer = nil;
    GMChatViewController *top = (id)self.navigationController.topViewController;
    if ([top isKindOfClass:[GMChatViewController class]] && [top.peer isEqual:peer]) return;
    [self openChat:d jumpTo:nil];
}

/// Quay lại app khi đang mở một chat: tin về lúc ở nền coi như đã xem.
- (void)becameActive {
    GMChatViewController *top = (id)self.navigationController.topViewController;
    if ([top isKindOfClass:[GMChatViewController class]] && !top.topic) {
        NSMutableDictionary *d = [self dialogFor:top.peer index:NULL];
        if ([GMVal(d, @"unread") intValue]) {
            [d setObject:@0 forKey:@"unread"];
            [self reloadRows];
        }
    }
    [[GMBackground shared] updateBadge];
}

#pragma mark - Bảng

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _shown.count;
}

#pragma mark - Thư mục

- (void)loadFolders {
    [GMCore call:@"folders.list" args:nil done:^(id ok, NSDictionary *err) {
        if (![ok isKindOfClass:[NSArray class]]) return;
        NSNumber *curId = GMVal([self currentFolder], @"id");
        _folders = ok;
        // Giữ thẻ đang chọn theo id (thư mục có thể đổi thứ tự / bị xoá)
        _folder = 0;
        for (NSUInteger i = 0; curId && i < _folders.count; i++) {
            if ([GMVal([_folders objectAtIndex:i], @"id") isEqual:curId]) _folder = i + 1;
        }
        [self reloadRows];
    }];
}

- (NSDictionary *)currentFolder {
    return _folder > 0 && _folder <= (NSInteger)_folders.count ? [_folders objectAtIndex:_folder - 1] : nil;
}

- (NSArray *)folders {
    return _folders ?: @[];
}

/// Thư mục tự tạo (thư mục chia sẻ qua link — chatlist — không sửa ở đây).
- (NSArray *)editableFolders {
    NSMutableArray *a = [NSMutableArray array];
    for (NSDictionary *f in _folders) {
        if (![GMVal(f, @"chatlist") boolValue]) [a addObject:f];
    }
    return a;
}

/// Chat thuộc thư mục `f` (như Telegram gốc): ghim / đưa vào riêng → có; bỏ riêng → không; rồi các cờ loại trừ (tắt tiếng, đã
/// đọc, lưu trữ); cuối cùng loại chat (danh bạ, không trong danh bạ, nhóm, kênh, bot).
- (BOOL)dialog:(NSDictionary *)d inFolder:(NSDictionary *)f {
    NSString *p = GMVal(d, @"peer");
    BOOL saved = [self isSaved:d];
    BOOL (^has)(NSArray *) = ^BOOL(NSArray *a) {
        return [a containsObject:p] || (saved && [a containsObject:@"self"]);
    };
    if (has(GMVal(f, @"pinned")) || has(GMVal(f, @"include"))) return YES;
    if (has(GMVal(f, @"exclude"))) return NO;
    if ([GMVal(f, @"exclude_archived") boolValue] && [GMVal(d, @"archived") boolValue]) return NO;
    if ([GMVal(f, @"exclude_muted") boolValue] && [GMVal(d, @"muted") boolValue]) return NO;
    if ([GMVal(f, @"exclude_read") boolValue] && [GMVal(d, @"unread") intValue] == 0 && ![GMVal(d, @"marked_unread") boolValue]) return NO;
    NSString *k = GMVal(d, @"kind");
    if ([k isEqual:@"group"]) return [GMVal(f, @"groups") boolValue];
    if ([k isEqual:@"channel"]) return [GMVal(f, @"broadcasts") boolValue];
    if ([GMVal(d, @"bot") boolValue]) return [GMVal(f, @"bots") boolValue];
    if (saved || [GMVal(d, @"contact") boolValue]) return [GMVal(f, @"contacts") boolValue];
    return [GMVal(f, @"non_contacts") boolValue];
}

/// Chat của thư mục `f` theo thứ tự: chat ghim trong thư mục (đúng thứ tự ghim) rồi các chat khác theo danh sách chung.
- (NSArray *)dialogsInFolder:(NSDictionary *)f {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *k in GMVal(f, @"pinned")) {
        NSDictionary *d = [k isEqual:@"self"] ? [self dialogFor:self.myId index:NULL] : [self dialogFor:k index:NULL];
        if (d && ![out containsObject:d]) [out addObject:d];
    }
    NSUInteger nPinned = out.count;
    for (NSDictionary *d in _dialogs) {
        if ([out indexOfObjectIdenticalTo:d] < nPinned) continue;
        if ([self dialog:d inFolder:f]) [out addObject:d];
    }
    return out;
}

- (NSInteger)countInFolder:(NSDictionary *)f {
    return [self dialogsInFolder:f].count;
}

/// Số chat chưa đọc (không tắt tiếng) của một thẻ — hiện cạnh tên thẻ.
- (NSInteger)unreadChatsIn:(NSArray *)list {
    NSInteger n = 0;
    for (NSDictionary *d in list) {
        if (![GMVal(d, @"muted") boolValue] && ([GMVal(d, @"unread") intValue] > 0 || [GMVal(d, @"marked_unread") boolValue])) n++;
    }
    return n;
}

/// Lọc lại theo thẻ đang chọn, dựng lại dải thẻ (số chưa đọc), vẽ lại bảng.
- (void)reloadRows {
    NSDictionary *f = [self currentFolder];
    if (!f) _folder = 0;
    _shown = f ? [self dialogsInFolder:f] : [_dialogs copy];
    [self buildFolderBar];
    if (_dialogs.count) _empty.text = _shown.count ? @"" : @"Thư mục này chưa có chat nào.";
    [self.tableView reloadData];
}

- (void)buildFolderBar {
    if (!_folders.count) return;
    if (!_folderBar) {
        _folderBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 40)];
        _folderBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        UIImageView *bg = [[UIImageView alloc] initWithFrame:_folderBar.bounds];
        bg.image = [GMTheme glassBar];
        bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_folderBar addSubview:bg];
        _folderScroll = [[UIScrollView alloc] initWithFrame:_folderBar.bounds];
        _folderScroll.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        _folderScroll.showsHorizontalScrollIndicator = NO;
        _folderScroll.scrollsToTop = NO;
        [_folderBar addSubview:_folderScroll];
    }
    for (UIView *v in _folderScroll.subviews) [v removeFromSuperview];
    CGFloat x = 8;
    for (NSInteger i = 0; i <= (NSInteger)_folders.count; i++) {
        NSDictionary *f = i ? [_folders objectAtIndex:i - 1] : nil;
        NSString *title = f ? GMVal(f, @"title") : @"Tất cả";
        NSInteger unread = [self unreadChatsIn:f ? [self dialogsInFolder:f] : _dialogs];
        if (unread) title = [NSString stringWithFormat:@"%@  %ld", title, (long)unread];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.tag = 100 + i;
        b.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [b setTitle:title forState:UIControlStateNormal];
        BOOL sel = i == _folder;
        [b setTitleColor:sel ? [GMTheme accent] : [GMTheme secondaryText] forState:UIControlStateNormal];
        CGFloat w = [title sizeWithFont:b.titleLabel.font].width + 24;
        b.frame = CGRectMake(x, 6, w, 28);
        b.layer.cornerRadius = 14;
        if (sel) {
            b.backgroundColor = [GMTheme glassGrouped];
            b.layer.borderWidth = 1;
            b.layer.borderColor = [GMTheme glassLine].CGColor;
        }
        [b addTarget:self action:@selector(folderTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_folderScroll addSubview:b];
        x += w + 4;
    }
    _folderScroll.contentSize = CGSizeMake(x + 8, 40);
}

- (void)folderTapped:(UIButton *)b {
    [self selectFolder:b.tag - 100];
}

- (void)selectFolder:(NSInteger)i {
    if (i < 0 || i > (NSInteger)_folders.count || i == _folder) return;
    _folder = i;
    [self reloadRows];
    if (_shown.count) [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]
                                            atScrollPosition:UITableViewScrollPositionTop animated:NO];
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)section {
    return _folders.count ? _folderBar : nil;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)section {
    return _folders.count ? 40 : 0;
}

/// Nhấn giữ → «Thêm vào thư mục…»: chọn thư mục rồi đưa chat vào (bỏ khỏi danh sách loại trừ nếu có).
- (void)chooseFolderFor:(NSString *)peer {
    NSArray *fs = [self editableFolders];
    UIActionSheet *s = [[UIActionSheet alloc] initWithTitle:@"Thêm vào thư mục" delegate:self cancelButtonTitle:nil
                                     destructiveButtonTitle:nil otherButtonTitles:nil];
    NSMutableArray *acts = [NSMutableArray array];
    __weak GMChatListViewController *ws = self;
    NSString *key = [peer isEqual:self.myId] ? @"self" : peer;
    for (NSDictionary *f in fs) {
        BOOL already = [GMVal(f, @"include") containsObject:key] || [GMVal(f, @"pinned") containsObject:key];
        [s addButtonWithTitle:already ? [NSString stringWithFormat:@"%@ ✓", GMVal(f, @"title")] : GMVal(f, @"title")];
        [acts addObject:^{
            if (already) return;
            NSMutableDictionary *m = [f mutableCopy];
            NSMutableArray *inc = [GMVal(f, @"include") mutableCopy] ?: [NSMutableArray array];
            NSMutableArray *exc = [GMVal(f, @"exclude") mutableCopy] ?: [NSMutableArray array];
            [inc addObject:key];
            [exc removeObject:key];
            [m setObject:inc forKey:@"include"];
            [m setObject:exc forKey:@"exclude"];
            [ws saveFolder:m done:[NSString stringWithFormat:@"Đã thêm vào «%@»", GMVal(f, @"title")]];
        }];
    }
    s.cancelButtonIndex = [s addButtonWithTitle:@"Huỷ"];
    _actions = acts;
    [s showInView:self.navigationController.view];
}

/// «Bỏ khỏi thư mục»: chat được đưa vào riêng → gỡ khỏi danh sách đó; chat vào theo loại → thêm vào danh sách loại trừ.
- (void)removePeer:(NSString *)peer fromFolder:(NSDictionary *)f {
    NSString *key = [peer isEqual:self.myId] ? @"self" : peer;
    NSMutableDictionary *m = [f mutableCopy];
    NSMutableArray *inc = [GMVal(f, @"include") mutableCopy] ?: [NSMutableArray array];
    NSMutableArray *pin = [GMVal(f, @"pinned") mutableCopy] ?: [NSMutableArray array];
    NSMutableArray *exc = [GMVal(f, @"exclude") mutableCopy] ?: [NSMutableArray array];
    BOOL explicitly = [inc containsObject:key] || [pin containsObject:key];
    [inc removeObject:key];
    [pin removeObject:key];
    [m setObject:inc forKey:@"include"];
    [m setObject:pin forKey:@"pinned"];
    if (!explicitly && ![exc containsObject:key]) [exc addObject:key];
    [m setObject:exc forKey:@"exclude"];
    [self saveFolder:m done:[NSString stringWithFormat:@"Đã bỏ khỏi «%@»", GMVal(f, @"title")]];
}

- (void)saveFolder:(NSDictionary *)f done:(NSString *)msg {
    [GMCore call:@"folders.save" args:f done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.navigationController.view];
            return;
        }
        [GMTheme toast:msg in:self.navigationController.view];
        [[NSNotificationCenter defaultCenter] postNotificationName:GMFoldersChangedNotification object:nil];
    }];
}

- (void)setLoggedOut:(BOOL)loggedOut {
    _loggedOut = loggedOut;
    (void)self.view;
    if (loggedOut) {
        [_dialogs removeAllObjects];
        [_typing removeAllObjects];
        _folders = nil;
        _folder = 0;
        [self reloadRows];
        _empty.text = @"Chưa đăng nhập Telegram.";
        if (!_login) {
            _login = [UIButton buttonWithType:UIButtonTypeCustom];
            [_login setBackgroundImage:[GMTheme sendButtonImage:NO] forState:UIControlStateNormal];
            [_login setBackgroundImage:[GMTheme sendButtonImage:YES] forState:UIControlStateHighlighted];
            [_login setTitle:@"Đăng nhập" forState:UIControlStateNormal];
            [_login setTitleShadowColor:[UIColor colorWithWhite:0 alpha:0.35] forState:UIControlStateNormal];
            _login.titleLabel.shadowOffset = CGSizeMake(0, -1);
            _login.titleLabel.font = [UIFont boldSystemFontOfSize:16];
            _login.adjustsImageWhenHighlighted = NO;
            _login.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
            [_login addTarget:self action:@selector(loginTapped) forControlEvents:UIControlEventTouchUpInside];
            [self.tableView addSubview:_login];
        }
        _login.frame = CGRectMake(floor((self.tableView.bounds.size.width - 200) / 2), 150, 200, 44);
    } else {
        _empty.text = @"";
    }
    _login.hidden = !loggedOut;
}

- (void)loginTapped {
    [(GMAppDelegate *)[UIApplication sharedApplication].delegate showLogin];
}

- (void)debugFolder:(NSInteger)i {
    [self selectFolder:i];
}

- (BOOL)isSaved:(NSDictionary *)d {
    return [GMVal(d, @"peer") isEqual:self.myId];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    GMDialogCell *c = [tableView dequeueReusableCellWithIdentifier:@"d"];
    if (!c) c = [[GMDialogCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"d"];
    NSDictionary *d = [_shown objectAtIndex:indexPath.row];
    NSDictionary *last = GMVal(d, @"last");
    BOOL saved = [self isSaved:d];
    NSString *name = saved ? @"Tin nhắn đã lưu" : (GMVal(d, @"name") ?: @"");
    NSString *peer = GMVal(d, @"peer");
    c.peerKey = peer;
    c.avatar.image = [GMTheme avatarFor:peer name:saved ? @"★" : name size:kAvatar];
    if (!saved && GMVal(d, @"photo")) {
        __weak GMDialogCell *wc = c;
        [GMImages avatarForPeer:peer photo:GMVal(d, @"photo") dc:GMVal(d, @"photo_dc") size:kAvatar done:^(UIImage *img) {
            if ([wc.peerKey isEqual:peer]) wc.avatar.image = img;
        }];
    }
    c.name.text = [GMVal(d, @"muted") boolValue] ? [name stringByAppendingString:@" 🔇"] : name;
    c.time.text = [GMTheme shortTime:GMVal(last, @"date")];
    // ✓ đã gửi, ✓✓ đã đọc (tin cuối là của mình, không phải Tin nhắn đã lưu / tin hệ thống)
    BOOL mine = [GMVal(last, @"out") boolValue] && !saved && ![GMVal(last, @"service") boolValue];
    c.check.hidden = !mine;
    c.check.text = [GMVal(last, @"id") intValue] <= [GMVal(d, @"read_out") intValue] ? @"✓✓" : @"✓";
    NSString *from = GMVal(last, @"from");
    BOOL group = ![GMVal(d, @"kind") isEqual:@"user"];
    BOOL showSender = group && !saved && last && ![GMVal(last, @"service") boolValue] && (mine || from.length);
    c.sender.hidden = !showSender;
    c.sender.text = mine ? @"Bạn" : from;
    NSString *typing = [[_typing objectForKey:peer] objectForKey:@"text"];
    c.preview.text = typing ?: [GMTheme preview:last];
    c.preview.textColor = typing ? [GMTheme accent] : [GMTheme secondaryText];
    if (typing) c.sender.hidden = YES;
    int unread = [GMVal(d, @"unread") intValue];
    c.badge.hidden = unread == 0;
    c.badge.text = unread > 999 ? @"999+" : [NSString stringWithFormat:@"%d", unread];
    c.badgeBg.image = [GMTheme badgeImage:[GMVal(d, @"muted") boolValue]];
    NSDictionary *cur = [self currentFolder];
    BOOL pinned = cur ? ([GMVal(cur, @"pinned") containsObject:peer] || (saved && [GMVal(cur, @"pinned") containsObject:@"self"]))
                      : [GMVal(d, @"pinned") boolValue];
    c.pin.hidden = unread > 0 || !pinned;
    [c setFirst:indexPath.row == 0 last:indexPath.row == (NSInteger)_shown.count - 1];
    // iPad: tô hàng của chat đang mở bên phải
    NSString *open = [(GMAppDelegate *)[UIApplication sharedApplication].delegate openPeer];
    if (open && [[GMVal(d, @"peer") description] isEqual:open]) {
        ((UIImageView *)c.backgroundView).image = [GMTheme cardRow:c.first last:c.last selected:YES];
    }
    [c setNeedsLayout];
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self openRow:indexPath.row];
}

- (NSDictionary *)debugDialogAt:(NSInteger)row {
    return row >= 0 && row < (NSInteger)_shown.count ? [_shown objectAtIndex:row] : nil;
}

- (void)openRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_shown.count) return;
    [self openChat:[_shown objectAtIndex:row] jumpTo:nil];
}

@end
