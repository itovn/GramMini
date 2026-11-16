#import "GMNewGroupViewController.h"
#import "GMCore.h"
#import "GMSearchController.h"
#import "GMTheme.h"

@interface GMNewGroupViewController () <UISearchBarDelegate, UIAlertViewDelegate>
@end

@implementation GMNewGroupViewController {
    NSArray *_contacts, *_shown;
    NSMutableOrderedSet *_picked;  // khoá peer
    UISearchBar *_bar;
    BOOL _creating;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Nhóm mới";
    self.tableView.rowHeight = 56;
    _picked = [NSMutableOrderedSet orderedSet];
    _bar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    _bar.placeholder = @"Tìm trong danh bạ";
    _bar.delegate = self;
    _bar.autocorrectionType = UITextAutocorrectionTypeNo;
    _bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.tableView.tableHeaderView = _bar;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Tiếp" style:UIBarButtonItemStyleDone
                                                                             target:self action:@selector(next)];
    [self updateNext];
    [GMCore call:@"contacts.list" args:nil done:^(id ok, NSDictionary *err) {
        _contacts = [ok isKindOfClass:[NSArray class]] ? ok : @[];
        _shown = _contacts;
        if (err) [GMTheme toast:GMErrorText(err) in:self.view];
        [self.tableView reloadData];
    }];
}

- (void)updateNext {
    self.navigationItem.rightBarButtonItem.enabled = _picked.count > 0 && !_creating;
    self.navigationItem.rightBarButtonItem.title = _picked.count ? [NSString stringWithFormat:@"Tiếp (%lu)", (unsigned long)_picked.count] : @"Tiếp";
}

- (void)searchBar:(UISearchBar *)bar textDidChange:(NSString *)q {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *p in _contacts) {
        if (!q.length || GMMatches(GMVal(p, @"name"), q) || GMMatches(GMVal(p, @"username"), q)) [out addObject:p];
    }
    _shown = out;
    [self.tableView reloadData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)bar {
    [bar resignFirstResponder];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return _shown.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return _picked.count ? [NSString stringWithFormat:@"Đã chọn %lu người", (unsigned long)_picked.count] : @"Chọn người vào nhóm";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *p = [_shown objectAtIndex:ip.row];
    NSDictionary *st = GMVal(p, @"status");
    UITableViewCell *c = GMPeerCell(tv, p, [st isKindOfClass:[NSDictionary class]] ? [GMTheme statusText:st] : @"", self.myId);
    c.accessoryType = [_picked containsObject:GMVal(p, @"peer")] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *peer = GMVal([_shown objectAtIndex:ip.row], @"peer");
    if ([_picked containsObject:peer]) [_picked removeObject:peer];
    else [_picked addObject:peer];
    [tv reloadData];
    [self updateNext];
}

- (void)next {
    [_bar resignFirstResponder];
    UIAlertView *av = [[UIAlertView alloc] initWithTitle:@"Tên nhóm" message:nil delegate:self cancelButtonTitle:@"Huỷ"
                                       otherButtonTitles:@"Tạo", nil];
    av.alertViewStyle = UIAlertViewStylePlainTextInput;
    [av textFieldAtIndex:0].placeholder = @"Tên nhóm";
    [av textFieldAtIndex:0].autocapitalizationType = UITextAutocapitalizationTypeSentences;
    [av show];
}

- (void)alertView:(UIAlertView *)av clickedButtonAtIndex:(NSInteger)i {
    if (i != 1) return;
    [self create:[[av textFieldAtIndex:0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
}

- (void)create:(NSString *)title {
    if (!title.length) {
        [GMTheme toast:@"Chưa đặt tên nhóm." in:self.navigationController.view];
        return;
    }
    _creating = YES;
    [self updateNext];
    [GMTheme toast:@"Đang tạo nhóm…" in:self.navigationController.view];
    [GMCore call:@"groups.create" args:@{@"title": title, @"users": _picked.array} done:^(id ok, NSDictionary *err) {
        _creating = NO;
        [self updateNext];
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.navigationController.view];
            return;
        }
        NSInteger missing = [GMVal(ok, @"missing") integerValue];
        if (missing) {
            [GMTheme toast:[NSString stringWithFormat:@"%ld người không thêm được (quyền riêng tư của họ)", (long)missing]
                        in:self.navigationController.view];
        }
        if (self.created) self.created(ok);
    }];
}

- (void)debugToggle:(NSInteger)row {
    if (row >= 0 && row < (NSInteger)_shown.count) [self tableView:self.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
}

- (void)debugCreate:(NSString *)title {
    [self create:title];
}

@end
