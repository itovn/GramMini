#import "GMContactsViewController.h"
#import "GMCore.h"
#import "GMSearchController.h"
#import "GMTheme.h"
#import "GMNewGroupViewController.h"

@implementation GMContactsViewController {
    NSArray *_contacts;
    GMSearchController *_search;
    UILabel *_empty;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.tabRoot ? @"Danh bạ" : @"Tin nhắn mới";
    self.tableView.rowHeight = 56;
    UISearchBar *bar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.tableView.tableHeaderView = bar;
    _search = [[GMSearchController alloc] initWithSearchBar:bar contents:self];
    _search.localTitle = @"Danh bạ";
    _search.myId = self.myId;
    __weak GMContactsViewController *ws = self;
    _search.local = ^NSArray *(NSString *q) {
        GMContactsViewController *s = ws;
        if (!q.length || !s) return @[];
        NSMutableArray *out = [NSMutableArray array];
        for (NSDictionary *p in s->_contacts) {
            if (GMMatches(GMVal(p, @"name"), q) || GMMatches(GMVal(p, @"username"), q) || GMMatches(GMVal(p, @"phone"), q)) {
                [out addObject:p];
            }
        }
        return out;
    };
    _search.pick = ^(NSDictionary *it, NSNumber *msg) {
        if (ws.pick) ws.pick(it);
    };
    _empty = [[UILabel alloc] initWithFrame:CGRectMake(0, 120, self.view.bounds.size.width, 40)];
    _empty.textAlignment = GMAlignCenter;
    _empty.textColor = [GMTheme secondaryText];
    _empty.backgroundColor = [UIColor clearColor];
    _empty.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _empty.text = @"Đang tải danh bạ…";
    [self.tableView addSubview:_empty];
    [GMCore call:@"contacts.list" args:nil done:^(id ok, NSDictionary *err) {
        _contacts = [ok isKindOfClass:[NSArray class]] ? ok : @[];
        _empty.text = err ? GMErrorText(err) : _contacts.count ? @"" : @"Danh bạ trống — tìm theo tên hoặc @tên ở ô trên.";
        [self.tableView reloadData];
    }];
}

// Mục 0: «Nhóm mới»; mục 1: danh bạ
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? 1 : _contacts.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.textLabel.text = @"Nhóm mới";
        c.textLabel.textColor = [GMTheme accent];
        c.textLabel.font = [UIFont boldSystemFontOfSize:16];
        c.imageView.image = [GMTheme icon:@"group"];
        return c;
    }
    NSDictionary *p = [_contacts objectAtIndex:ip.row];
    NSDictionary *st = GMVal(p, @"status");
    NSString *detail = [GMVal(p, @"bot") boolValue] ? @"bot" : [st isKindOfClass:[NSDictionary class]] ? [GMTheme statusText:st] : @"";
    UITableViewCell *c = GMPeerCell(tv, p, detail, self.myId);
    c.detailTextLabel.textColor = [GMVal(st, @"status") isEqual:@"online"] ? [GMTheme accent] : [GMTheme secondaryText];
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) {
        [self newGroup];
        return;
    }
    if (self.pick) self.pick([_contacts objectAtIndex:ip.row]);
}

- (void)newGroup {
    GMNewGroupViewController *g = [[GMNewGroupViewController alloc] initWithStyle:UITableViewStylePlain];
    g.myId = self.myId;
    __weak GMContactsViewController *ws = self;
    g.created = ^(NSDictionary *group) {
        if (ws.pick) ws.pick(group);  // mở chat nhóm vừa tạo
    };
    [self.navigationController pushViewController:g animated:YES];
}

- (void)debugSearch:(NSString *)q {
    [_search debugSearch:q];
}

- (void)debugTapSection:(NSInteger)s row:(NSInteger)r {
    if (_search.display.active) [_search debugTapSection:s row:r];
    else if (s == 0) [self newGroup];
    else if (r >= 0 && r < (NSInteger)_contacts.count) [self tableView:self.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:r inSection:1]];
}

@end
