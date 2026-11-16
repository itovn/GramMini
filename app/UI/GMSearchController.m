#import "GMSearchController.h"
#import "GMCore.h"
#import "GMImages.h"
#import "GMTheme.h"
#import <objc/runtime.h>

BOOL GMMatches(NSString *text, NSString *q) {
    if (!q.length) return YES;
    if (![text isKindOfClass:[NSString class]]) return NO;
    NSStringCompareOptions o = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    // «đ» không bị bỏ dấu theo Unicode → đổi tay
    NSString *t = [[text stringByReplacingOccurrencesOfString:@"đ" withString:@"d"] stringByReplacingOccurrencesOfString:@"Đ" withString:@"D"];
    NSString *k = [[q stringByReplacingOccurrencesOfString:@"đ" withString:@"d"] stringByReplacingOccurrencesOfString:@"Đ" withString:@"D"];
    return [t rangeOfString:k options:o].location != NSNotFound;
}

static const char kPeerKey;

UITableViewCell *GMPeerCell(UITableView *tv, NSDictionary *item, NSString *detail, NSString *myId) {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"gmpeer"];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"gmpeer"];
        c.detailTextLabel.textColor = [GMTheme secondaryText];
        c.textLabel.font = [UIFont boldSystemFontOfSize:16];
    }
    NSString *peer = [GMVal(item, @"peer") description];
    BOOL saved = myId && [peer isEqual:myId];
    NSString *name = saved ? @"Tin nhắn đã lưu" : (GMVal(item, @"name") ?: GMVal(item, @"chat_name") ?: @"");
    c.textLabel.text = name;
    c.detailTextLabel.text = detail;
    c.imageView.image = [GMTheme avatarFor:peer ?: @"0" name:saved ? @"★" : name size:40];
    objc_setAssociatedObject(c, &kPeerKey, peer, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (!saved && GMVal(item, @"photo")) {
        __weak UITableViewCell *wc = c;
        [GMImages avatarForPeer:peer photo:[GMVal(item, @"photo") description] dc:GMVal(item, @"photo_dc") size:40 done:^(UIImage *img) {
            if (img && [objc_getAssociatedObject(wc, &kPeerKey) isEqual:peer]) {
                wc.imageView.image = img;
                [wc setNeedsLayout];
            }
        }];
    }
    return c;
}

@implementation GMSearchController {
    UISearchDisplayController *_display;
    NSString *_query;
    NSArray *_localRows, *_globalRows, *_msgRows;
    BOOL _busy;
}

- (instancetype)initWithSearchBar:(UISearchBar *)bar contents:(UIViewController *)vc {
    if ((self = [super init])) {
        bar.placeholder = @"Tìm kiếm";
        bar.autocorrectionType = UITextAutocorrectionTypeNo;
        bar.autocapitalizationType = UITextAutocapitalizationTypeNone;
        // Ô nhập của thanh tìm (iOS 5 / 6: con trực tiếp): chữ / bàn phím theo chế độ (ô tối ở chế độ tối)
        for (UIView *v in bar.subviews) {
            if (![v isKindOfClass:[UITextField class]]) continue;
            ((UITextField *)v).textColor = [GMTheme text];
            ((UITextField *)v).keyboardAppearance = [GMTheme keyboard];
        }
        _display = [[UISearchDisplayController alloc] initWithSearchBar:bar contentsController:vc];
        _display.delegate = self;
        _display.searchResultsDataSource = self;
        _display.searchResultsDelegate = self;
        _localTitle = @"Chat";
        _localRows = _globalRows = _msgRows = @[];
    }
    return self;
}

- (UISearchDisplayController *)display {
    return _display;
}

#pragma mark Tìm

- (BOOL)searchDisplayController:(UISearchDisplayController *)c shouldReloadTableForSearchString:(NSString *)q {
    _query = [q stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    _localRows = self.local ? self.local(_query) : @[];
    _globalRows = @[];
    _msgRows = @[];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(remote) object:nil];
    if (_query.length >= 2) [self performSelector:@selector(remote) withObject:nil afterDelay:0.4];
    return YES;
}

- (void)remote {
    NSString *q = _query;
    NSSet *have = [NSSet setWithArray:[_localRows valueForKey:@"peer"]];
    [GMCore call:@"contacts.search" args:@{@"q": q} done:^(id ok, NSDictionary *err) {
        if (![q isEqual:_query] || ![ok isKindOfClass:[NSArray class]]) return;
        NSMutableArray *g = [NSMutableArray array];
        for (NSDictionary *p in ok) {
            if (![have containsObject:GMVal(p, @"peer")]) [g addObject:p];
        }
        _globalRows = g;
        [_display.searchResultsTableView reloadData];
    }];
    if (!self.messages) return;
    [GMCore call:@"messages.search" args:@{@"q": q, @"limit": @30} done:^(id ok, NSDictionary *err) {
        if (![q isEqual:_query] || ![ok isKindOfClass:[NSArray class]]) return;
        _msgRows = ok;
        [_display.searchResultsTableView reloadData];
    }];
}

#pragma mark Bảng kết quả

- (NSArray *)rowsIn:(NSInteger)s {
    return s == 0 ? _localRows : s == 1 ? _globalRows : _msgRows;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return [self rowsIn:s].count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (![self rowsIn:s].count) return nil;
    return s == 0 ? self.localTitle : s == 1 ? @"Trên Telegram" : @"Tin nhắn";
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return 56;
}

- (NSString *)detailFor:(NSDictionary *)p {
    NSString *kind = GMVal(p, @"kind");
    NSString *u = GMVal(p, @"username");
    NSString *at = [u isKindOfClass:[NSString class]] && u.length ? [@"@" stringByAppendingString:u] : nil;
    if ([kind isEqual:@"user"] || !kind) {
        NSDictionary *st = GMVal(p, @"status");
        if ([GMVal(p, @"bot") boolValue]) return at ? [at stringByAppendingString:@" · bot"] : @"bot";
        NSString *s = [st isKindOfClass:[NSDictionary class]] ? [GMTheme statusText:st] : nil;
        if (at && s) return [NSString stringWithFormat:@"%@ · %@", at, s];
        if (at || s) return at ?: s;
        NSDictionary *last = GMVal(p, @"last");
        return last ? [GMTheme preview:last] : @"";
    }
    NSString *k = [kind isEqual:@"channel"] ? @"kênh" : @"nhóm";
    return at ? [NSString stringWithFormat:@"%@ · %@", at, k] : k;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *it = [[self rowsIn:ip.section] objectAtIndex:ip.row];
    if (ip.section < 2) return GMPeerCell(tv, it, [self detailFor:it], self.myId);
    NSString *from = GMVal(it, @"from");
    NSString *text = [GMTheme preview:it];
    BOOL group = from.length && ![from isEqual:GMVal(it, @"chat_name")];
    NSString *detail = [NSString stringWithFormat:@"%@ · %@%@", [GMTheme shortTime:GMVal(it, @"date")],
                                                  [GMVal(it, @"out") boolValue] ? @"Bạn: " : group ? [from stringByAppendingString:@": "] : @"", text];
    return GMPeerCell(tv, @{@"peer": GMVal(it, @"peer") ?: @"", @"name": GMVal(it, @"chat_name") ?: @""}, detail, self.myId);
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *it = [[self rowsIn:ip.section] objectAtIndex:ip.row];
    NSNumber *msg = ip.section == 2 ? GMVal(it, @"id") : nil;
    void (^pick)(NSDictionary *, NSNumber *) = self.pick;
    [_display setActive:NO animated:YES];
    if (pick) pick(it, msg);
}

#pragma mark Gỡ lỗi

- (void)debugSearch:(NSString *)q {
    [_display setActive:YES animated:NO];
    _display.searchBar.text = q;  // gọi shouldReloadTableForSearchString
}

- (void)debugTapSection:(NSInteger)s row:(NSInteger)r {
    if (s < 0 || s > 2 || r < 0 || r >= (NSInteger)[self rowsIn:s].count) return;
    [self tableView:_display.searchResultsTableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:r inSection:s]];
}

@end
