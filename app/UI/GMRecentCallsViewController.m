#import "GMRecentCallsViewController.h"
#import "GMAppDelegate.h"
#import "GMCallManager.h"
#import "GMChatListViewController.h"
#import "GMCore.h"
#import "GMSearchController.h"
#import "GMTheme.h"

@implementation GMRecentCallsViewController {
    NSMutableArray *_rows;
    UISegmentedControl *_filter;
    BOOL _loading, _end;
    UILabel *_empty;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Cuộc gọi gần đây";
    self.tableView.rowHeight = 60;
    _rows = [NSMutableArray array];
    _filter = [[UISegmentedControl alloc] initWithItems:@[@"Tất cả", @"Nhỡ"]];
    _filter.selectedSegmentIndex = 0;
    _filter.frame = CGRectMake(0, 0, 160, 30);
    [_filter addTarget:self action:@selector(filterChanged) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = _filter;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];  // vừa gọi xong quay lại: thấy ngay cuộc gọi mới
}

- (void)filterChanged {
    [self reload];
}

- (void)reload {
    _end = NO;
    [_rows removeAllObjects];
    [self.tableView reloadData];
    [self loadMore];
}

- (void)loadMore {
    if (_loading || _end) return;
    _loading = YES;
    NSMutableDictionary *a = [NSMutableDictionary dictionaryWithObject:@(_filter.selectedSegmentIndex == 1) forKey:@"missed"];
    [a setObject:@50 forKey:@"limit"];
    if (_rows.count) [a setObject:GMVal([_rows lastObject], @"id") forKey:@"offset_id"];
    NSInteger want = _filter.selectedSegmentIndex;
    [GMCore call:@"calls.recent" args:a done:^(id ok, NSDictionary *err) {
        _loading = NO;
        if (want != _filter.selectedSegmentIndex) return;  // đã đổi bộ lọc trong lúc tải
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.view];
            return;
        }
        NSArray *more = [ok isKindOfClass:[NSArray class]] ? ok : @[];
        if (more.count < 50) _end = YES;
        [_rows addObjectsFromArray:more];
        [self.tableView reloadData];
        [self showEmpty];
    }];
}

- (void)showEmpty {
    if (_rows.count || !_end) {
        _empty.hidden = YES;
        return;
    }
    if (!_empty) {
        _empty = [[UILabel alloc] initWithFrame:CGRectMake(20, 120, self.view.bounds.size.width - 40, 60)];
        _empty.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        _empty.numberOfLines = 0;
        _empty.textAlignment = GMAlignCenter;
        _empty.backgroundColor = [UIColor clearColor];
        _empty.textColor = [GMTheme secondaryText];
        _empty.font = [UIFont systemFontOfSize:16];
        [self.tableView addSubview:_empty];
    }
    _empty.text = _filter.selectedSegmentIndex == 1 ? @"Không có cuộc gọi nhỡ" : @"Chưa có cuộc gọi nào.\nGọi bằng nút ống nghe ở đầu chat riêng.";
    _empty.hidden = NO;
}

/// Cuộc gọi đến không thời lượng mà không phải mình từ chối: nhỡ (tên đỏ như Telegram).
static BOOL GMCallMissed(NSDictionary *r) {
    return ![GMVal(r, @"out") boolValue] && [GMVal(r, @"duration") intValue] == 0 && ![GMVal(r, @"reason") isEqual:@"busy"];
}

/// Dòng phụ ngắn (vừa ô cạnh giờ trên iPhone): «Gọi đến · 0:40», «Gọi đi · không thông», «Gọi nhỡ»… — không dùng mũi tên ↙ ↗
/// (iOS 6 vẽ thành emoji ô vuông).
static NSString *GMCallDetail(NSDictionary *r) {
    BOOL out = [GMVal(r, @"out") boolValue];
    int d = [GMVal(r, @"duration") intValue];
    NSString *kind = [GMVal(r, @"video") boolValue] ? @"Video" : @"Gọi";
    if (d > 0) return [NSString stringWithFormat:@"%@ %@ · %d:%02d", kind, out ? @"đi" : @"đến", d / 60, d % 60];
    if (out) return [NSString stringWithFormat:@"%@ đi · không thông", kind];
    if ([GMVal(r, @"reason") isEqual:@"busy"]) return [NSString stringWithFormat:@"%@ đến · đã từ chối", kind];
    return [NSString stringWithFormat:@"%@ nhỡ", kind];
}

#pragma mark Bảng

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return _rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *r = [_rows objectAtIndex:ip.row];
    UITableViewCell *c = GMPeerCell(tv, r, GMCallDetail(r), nil);
    c.textLabel.textColor = GMCallMissed(r) ? [UIColor colorWithRed:0.9 green:0.22 blue:0.21 alpha:1] : [GMTheme text];
    UILabel *t = (UILabel *)c.accessoryView;
    if (![t isKindOfClass:[UILabel class]]) {
        t = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 70, 20)];
        t.font = [UIFont systemFontOfSize:13];
        t.textAlignment = GMAlignRight;
        t.backgroundColor = [UIColor clearColor];
        t.textColor = [GMTheme secondaryText];
        c.accessoryView = t;
    }
    t.text = [GMTheme shortTime:GMVal(r, @"date")];
    if (ip.row >= (NSInteger)_rows.count - 5) [self loadMore];
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *r = [_rows objectAtIndex:ip.row];
    NSMutableDictionary *chat = [NSMutableDictionary dictionary];
    for (NSString *k in @[@"peer", @"name", @"photo", @"photo_dc"]) {
        id v = GMVal(r, k);
        if (v) [chat setObject:[k isEqual:@"peer"] ? [v description] : v forKey:k];
    }
    [[GMCallManager shared] callChat:chat];
}

@end
