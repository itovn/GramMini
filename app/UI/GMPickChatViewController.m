#import "GMPickChatViewController.h"
#import "GMCore.h"
#import "GMTheme.h"

@implementation GMPickChatViewController {
    NSArray *_dialogs;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.pickTitle ?: @"Chuyển tiếp tới…";
    self.tableView.rowHeight = 56;
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Huỷ" style:UIBarButtonItemStylePlain target:self action:@selector(cancel)];
    [GMCore call:@"dialogs.list" args:@{@"limit": @100} done:^(id ok, NSDictionary *err) {
        // Kênh mình không quản trị thì không gửi được — bản đầu bỏ hẳn kênh khỏi danh sách
        NSMutableArray *a = [NSMutableArray array];
        for (NSDictionary *d in ok) {
            if (self.allowChannels || ![GMVal(d, @"kind") isEqual:@"channel"]) [a addObject:d];
        }
        _dialogs = a;
        [self.tableView reloadData];
    }];
}

- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _dialogs.count;
}

- (NSString *)nameOf:(NSDictionary *)d {
    return [GMVal(d, @"peer") isEqual:self.myId] ? @"Tin nhắn đã lưu" : (GMVal(d, @"name") ?: @"");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"p"];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"p"];
        c.textLabel.font = [UIFont boldSystemFontOfSize:16];
    }
    NSDictionary *d = [_dialogs objectAtIndex:indexPath.row];
    BOOL saved = [GMVal(d, @"peer") isEqual:self.myId];
    c.textLabel.text = [self nameOf:d];
    c.imageView.image = [GMTheme avatarFor:GMVal(d, @"peer") name:saved ? @"★" : [self nameOf:d] size:40];
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *d = [_dialogs objectAtIndex:indexPath.row];
    void (^cb)(NSString *, NSString *) = self.picked;
    NSString *peer = GMVal(d, @"peer"), *name = [self nameOf:d];
    [self dismissViewControllerAnimated:YES completion:^{
        if (cb) cb(peer, name);
    }];
}

@end
