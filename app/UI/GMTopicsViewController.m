#import "GMTopicsViewController.h"
#import "GMChatListViewController.h"
#import "GMChatViewController.h"
#import "GMChatInfoViewController.h"
#import "GMCompat.h"
#import "GMCore.h"
#import "GMLog.h"
#import "GMTheme.h"
#import "GMTitleView.h"

static const NSInteger kPage = 50;

@implementation GMTopicsViewController {
    NSMutableArray *_topics;  // NSMutableDictionary: id, title, color, closed, pinned, hidden, muted, unread, read_out, date, top, last
    NSInteger _count;         // số chủ đề máy chủ báo
    BOOL _loading, _more;
    id _refresh;              // UIRefreshControl (iOS 6) — iOS 5 dùng nút làm mới
    UILabel *_empty;
    GMTitleView *_titleView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _topics = [NSMutableArray array];
    self.title = self.name;
    _titleView = [[GMTitleView alloc] init];
    _titleView.title = self.name;
    _titleView.subtitle = @"chủ đề";
    self.navigationItem.titleView = _titleView;
    _titleView.userInteractionEnabled = YES;
    [_titleView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showInfo)]];
    self.tableView.rowHeight = GMDialogRowH;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.navigationItem.backBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Chủ đề" style:UIBarButtonItemStylePlain target:nil action:nil];
    // «Tất cả»: tin của mọi chủ đề trong một màn (như «Xem dạng tin nhắn» của Telegram gốc)
    UIBarButtonItem *all =
        [[UIBarButtonItem alloc] initWithTitle:@"Tất cả" style:UIBarButtonItemStyleBordered target:self action:@selector(openAll)];
    Class rc = NSClassFromString(@"UIRefreshControl");
    if (rc) {
        _refresh = [[rc alloc] init];
        [_refresh addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
        [self setValue:_refresh forKey:@"refreshControl"];
        self.navigationItem.rightBarButtonItem = all;
    } else {
        UIBarButtonItem *reload = [GMTheme barButtonIcon:@"refresh" target:self action:@selector(reload)];
        self.navigationItem.rightBarButtonItems = @[all, reload];
    }
    _empty = [[UILabel alloc] initWithFrame:CGRectMake(0, 80, self.view.bounds.size.width, 60)];
    _empty.textAlignment = GMAlignCenter;
    _empty.textColor = [GMTheme secondaryText];
    _empty.numberOfLines = 2;
    _empty.backgroundColor = [UIColor clearColor];
    _empty.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _empty.text = @"Đang tải…";
    [self.tableView addSubview:_empty];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(event:) name:GMCoreEventNotification object:nil];
    [self reload];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];  // quay về từ một chủ đề: số chưa đọc đã về 0
}

#pragma mark Dữ liệu

/// Chủ đề hiện trong danh sách (bỏ chủ đề bị ẩn — chỉ General ẩn được).
- (NSArray *)visible:(NSArray *)page {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *t in page) {
        if (![GMVal(t, @"hidden") boolValue]) [out addObject:[t mutableCopy]];
    }
    return out;
}

- (void)reload {
    if (_loading) return;
    _loading = YES;
    long long t0 = GMNowMs();
    [GMCore call:@"topics.list" args:@{@"peer": self.peer, @"limit": @(kPage)} done:^(id ok, NSDictionary *err) {
        _loading = NO;
        GM_IOS6_BEGIN
        [_refresh endRefreshing];
        GM_IOS6_END
        if (err) {
            GMLog(@"chủ đề: tải lỗi %@", GMVal(err, @"code"));
            _empty.text = _topics.count ? @"" : GMErrorText(err);
            return;
        }
        NSArray *page = GMVal(ok, @"topics");
        NSUInteger general = [page indexOfObjectPassingTest:^BOOL(id t, NSUInteger i, BOOL *stop) {
            return [GMVal(t, @"id") intValue] == 1;
        }];
        GMLog(@"chủ đề: %lu / %@, %lld ms (General: %@)", (unsigned long)page.count, GMVal(ok, @"count"), GMNowMs() - t0,
              general == NSNotFound ? @"không có" : [NSString stringWithFormat:@"hàng %lu", (unsigned long)general]);
        [_topics setArray:[self visible:page]];
        _count = [GMVal(ok, @"count") integerValue];
        _more = page.count >= kPage && _topics.count < _count;
        _empty.text = _topics.count ? @"" : @"Chưa có chủ đề nào.";
        _titleView.subtitle = [NSString stringWithFormat:@"%ld chủ đề", (long)MAX(_count, (NSInteger)_topics.count)];
        [self.tableView reloadData];
        [self unreadDidChange];
    }];
}

/// Tải tiếp (cuộn tới cuối): mốc là chủ đề cuối trang trước — ngày + mã tin cuối, mã chủ đề.
- (void)loadMore {
    if (_loading || !_more) return;
    NSDictionary *t = _topics.lastObject;
    if (!t) return;
    _loading = YES;
    NSDictionary *off = @{@"date": GMVal(GMVal(t, @"last"), @"date") ?: GMVal(t, @"date") ?: @0,
                          @"id": GMVal(t, @"top") ?: @0, @"topic": GMVal(t, @"id") ?: @0};
    [GMCore call:@"topics.list" args:@{@"peer": self.peer, @"limit": @(kPage), @"offset": off} done:^(id ok, NSDictionary *err) {
        _loading = NO;
        if (err) {
            GMLog(@"chủ đề: tải thêm lỗi %@", GMVal(err, @"code"));
            return;
        }
        NSArray *page = GMVal(ok, @"topics");
        NSMutableSet *have = [NSMutableSet set];
        for (NSDictionary *x in _topics) [have addObject:GMVal(x, @"id")];
        for (NSMutableDictionary *x in [self visible:page]) {
            if (![have containsObject:GMVal(x, @"id")]) [_topics addObject:x];
        }
        _more = page.count >= kPage && _topics.count < _count;
        [self.tableView reloadData];
        [self unreadDidChange];
    }];
}

- (NSInteger)unreadTotal {
    NSInteger n = 0;
    for (NSDictionary *t in _topics) {
        if (![GMVal(t, @"muted") boolValue]) n += [GMVal(t, @"unread") integerValue];
    }
    return n;
}

- (void)unreadDidChange {
    if (self.unreadChanged) self.unreadChanged([self unreadTotal]);
}

/// Chủ đề của tin (tin không thuộc chủ đề nào: General, id 1).
static NSNumber *GMTopicOf(NSDictionary *m) {
    return GMVal(m, @"topic") ?: @1;
}

- (NSUInteger)indexOfTopic:(NSNumber *)tid {
    for (NSUInteger i = 0; i < _topics.count; i++) {
        if ([GMVal([_topics objectAtIndex:i], @"id") isEqual:tid]) return i;
    }
    return NSNotFound;
}

- (void)event:(NSNotification *)n {
    NSDictionary *ev = n.userInfo;
    NSString *e = GMVal(ev, @"e");
    if (![e isEqual:@"msg.new"] && ![e isEqual:@"msg.edit"]) return;
    NSDictionary *m = GMVal(ev, @"msg");
    if (![GMVal(m, @"peer") isEqual:self.peer]) return;
    NSUInteger i = [self indexOfTopic:GMTopicOf(m)];
    if (i == NSNotFound) {
        // Chủ đề mới (tin «Chủ đề … đã được tạo») hoặc chưa tải tới: tải lại đầu danh sách
        if ([e isEqual:@"msg.new"]) [self reload];
        return;
    }
    NSMutableDictionary *t = [_topics objectAtIndex:i];
    if ([e isEqual:@"msg.edit"]) {
        if ([GMVal(GMVal(t, @"last"), @"id") isEqual:GMVal(m, @"id")]) [t setObject:m forKey:@"last"];
        [self.tableView reloadData];
        return;
    }
    [t setObject:m forKey:@"last"];
    [t setObject:GMVal(m, @"id") ?: @0 forKey:@"top"];
    // Đang mở đúng chủ đề này (và app ở trước): tin coi như đã đọc
    GMChatViewController *top = (id)self.navigationController.topViewController;
    BOOL open = [top isKindOfClass:[GMChatViewController class]] && [top.peer isEqual:self.peer] &&
                [top.topic isEqual:GMVal(t, @"id")] &&
                [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
    if (![GMVal(m, @"out") boolValue] && !open) {
        [t setObject:@([GMVal(t, @"unread") intValue] + 1) forKey:@"unread"];
    }
    // Đưa lên đầu (sau các chủ đề ghim)
    if (![GMVal(t, @"pinned") boolValue]) {
        [_topics removeObjectAtIndex:i];
        NSUInteger to = 0;
        while (to < _topics.count && [GMVal([_topics objectAtIndex:to], @"pinned") boolValue]) to++;
        [_topics insertObject:t atIndex:to];
    }
    [self.tableView reloadData];
    [self unreadDidChange];
}

#pragma mark Mở

- (void)showInfo {
    GMChatInfoViewController *i = [[GMChatInfoViewController alloc] init];
    i.peer = self.peer;
    i.kind = @"group";
    i.myId = self.myId;
    i.name = self.name;
    [self.navigationController pushViewController:i animated:YES];
}

- (GMChatViewController *)chatController {
    GMChatViewController *c = [[GMChatViewController alloc] init];
    c.peer = self.peer;
    c.kind = @"group";
    c.myId = self.myId;
    c.photo = self.photo;
    c.photoDc = self.photoDc;
    return c;
}

- (void)openAll {
    GMChatViewController *c = [self chatController];
    c.title = self.name;
    [self.navigationController pushViewController:c animated:YES];
}

- (void)openTopicAt:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_topics.count) return;
    NSMutableDictionary *t = [_topics objectAtIndex:row];
    GMChatViewController *c = [self chatController];
    c.topic = GMVal(t, @"id");
    c.topicColor = [GMVal(t, @"color") integerValue];
    c.groupName = self.name;
    c.title = GMVal(t, @"title") ?: @"";
    c.readOut = [GMVal(t, @"read_out") integerValue];
    [t setObject:@0 forKey:@"unread"];
    [self unreadDidChange];
    [self.navigationController pushViewController:c animated:YES];
}

#pragma mark Bảng

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _topics.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    GMDialogCell *c = [tableView dequeueReusableCellWithIdentifier:@"t"];
    if (!c) c = [[GMDialogCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"t"];
    NSDictionary *t = [_topics objectAtIndex:indexPath.row];
    NSDictionary *last = GMVal(t, @"last");
    NSString *title = GMVal(t, @"title") ?: @"";
    c.avatar.image = [GMTheme topicIcon:title color:[GMVal(t, @"color") integerValue] size:GMDialogAvatar];
    NSMutableString *name = [title mutableCopy];
    if ([GMVal(t, @"closed") boolValue]) [name appendString:@" 🔒"];
    if ([GMVal(t, @"muted") boolValue]) [name appendString:@" 🔇"];
    c.name.text = name;
    c.time.text = [GMTheme shortTime:GMVal(last, @"date") ?: GMVal(t, @"date")];
    BOOL mine = [GMVal(last, @"out") boolValue] && ![GMVal(last, @"service") boolValue];
    c.check.hidden = !mine;
    c.check.text = [GMVal(last, @"id") intValue] <= [GMVal(t, @"read_out") intValue] ? @"✓✓" : @"✓";
    NSString *from = GMVal(last, @"from");
    c.sender.hidden = !(last && ![GMVal(last, @"service") boolValue] && (mine || from.length));
    c.sender.text = mine ? @"Bạn" : from;
    c.preview.text = last ? [GMTheme preview:last] : @"";
    c.preview.textColor = [GMTheme secondaryText];
    int unread = [GMVal(t, @"unread") intValue];
    c.badge.hidden = unread == 0;
    c.badge.text = unread > 999 ? @"999+" : [NSString stringWithFormat:@"%d", unread];
    c.badgeBg.image = [GMTheme badgeImage:[GMVal(t, @"muted") boolValue]];
    c.pin.hidden = unread > 0 || ![GMVal(t, @"pinned") boolValue];
    [c setFirst:indexPath.row == 0 last:indexPath.row == (NSInteger)_topics.count - 1];
    [c setNeedsLayout];
    return c;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= (NSInteger)_topics.count - 5) [self loadMore];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self openTopicAt:indexPath.row];
}

@end
