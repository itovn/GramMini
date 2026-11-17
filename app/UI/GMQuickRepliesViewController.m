#import "GMQuickRepliesViewController.h"
#import "GMQuickReplies.h"
#import "GMTheme.h"
#import "GMAlert.h"

@implementation GMQuickRepliesViewController {
    NSArray *_items;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Tin nhắn nhanh";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self
                                                                                           action:@selector(add)];
    _items = [GMQuickReplies all];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.prefillKeyword) {
        NSString *k = self.prefillKeyword;
        self.prefillKeyword = nil;
        [self editKeyword:k text:nil];
    }
}

- (void)add {
    [self editKeyword:nil text:nil];
}

/// Hộp nhập hai ô: từ khoá + chữ (UIAlertView kiểu đăng nhập, ô thứ hai bỏ che chữ — iOS 5 / 6 chưa có hộp tuỳ biến).
- (void)editKeyword:(NSString *)k text:(NSString *)t {
    BOOL editing = k.length && t.length;
    GMBlockAlert *a = [[GMBlockAlert alloc] initWithTitle:editing ? @"Sửa tin nhắn nhanh" : @"Tin nhắn nhanh mới"
                                                  message:@"Khi soạn tin, gõ «/» + từ khoá rồi chọn để chèn chữ." delegate:nil
                                        cancelButtonTitle:@"Huỷ" otherButtonTitles:@"Lưu", nil];
    a.alertViewStyle = UIAlertViewStyleLoginAndPasswordInput;
    UITextField *kf = [a textFieldAtIndex:0], *tf = [a textFieldAtIndex:1];
    kf.placeholder = @"Từ khoá, vd: chao";
    kf.text = k;
    kf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    kf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.placeholder = @"Nội dung tin nhắn";
    tf.secureTextEntry = NO;
    tf.text = t;
    tf.autocapitalizationType = UITextAutocapitalizationTypeSentences;
    __weak GMQuickRepliesViewController *ws = self;
    __weak GMBlockAlert *wa = a;
    a.delegate = a;
    a.done = ^(NSInteger i) {
        if (i != 1) return;
        NSString *key = [GMQuickReplies normalize:[wa textFieldAtIndex:0].text];
        NSString *text = [[wa textFieldAtIndex:1].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!key.length || !text.length) {
            [GMTheme toast:@"Cần cả từ khoá và nội dung." in:ws.view];
            return;
        }
        if (k.length && ![k isEqual:key]) [GMQuickReplies remove:k];
        [GMQuickReplies save:key text:text];
        [ws reload];
    };
    [a show];
}

- (void)reload {
    _items = [GMQuickReplies all];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _items.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return _items.count ? @"Chạm để sửa, vuốt sang trái để xoá. Tin nhắn nhanh chỉ lưu trên máy này."
                        : @"Chưa có tin nhắn nhanh nào. Bấm + để thêm, rồi khi soạn tin gõ «/» + từ khoá để chèn.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"q"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"q"];
    NSDictionary *d = [_items objectAtIndex:ip.row];
    c.textLabel.text = [@"/" stringByAppendingString:[d objectForKey:@"k"]];
    c.detailTextLabel.text = [d objectForKey:@"t"];
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *d = [_items objectAtIndex:ip.row];
    [self editKeyword:[d objectForKey:@"k"] text:[d objectForKey:@"t"]];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete) return;
    [GMQuickReplies remove:[[_items objectAtIndex:ip.row] objectForKey:@"k"]];
    _items = [GMQuickReplies all];
    [tableView deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)ip {
    return @"Xoá";
}

@end
