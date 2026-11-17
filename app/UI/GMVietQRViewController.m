#import "GMVietQRViewController.h"
#import "GMCore.h"
#import "GMTheme.h"
#import "GMLog.h"
#import <QuartzCore/QuartzCore.h>

static NSString *const kLast = @"vietqr.last";

/// Ngân hàng / ví nhận VietQR: [tên ngắn, mã BIN] — theo danh sách của VietQR (api.vietqr.io), loại phổ biến trước.
static NSArray *GMBanks(void) {
    return @[
        @[@"Vietcombank", @"970436"], @[@"VietinBank", @"970415"], @[@"BIDV", @"970418"], @[@"Agribank", @"970405"],
        @[@"MBBank", @"970422"], @[@"Techcombank", @"970407"], @[@"ACB", @"970416"], @[@"VPBank", @"970432"],
        @[@"TPBank", @"970423"], @[@"Sacombank", @"970403"], @[@"HDBank", @"970437"], @[@"VIB", @"970441"],
        @[@"SHB", @"970443"], @[@"Eximbank", @"970431"], @[@"MSB", @"970426"], @[@"OCB", @"970448"],
        @[@"SeABank", @"970440"], @[@"LPBank", @"970449"], @[@"VietCapitalBank", @"970454"], @[@"SCB", @"970429"],
        @[@"NamABank", @"970428"], @[@"BacABank", @"970409"], @[@"ABBANK", @"970425"], @[@"VietABank", @"970427"],
        @[@"PVcomBank", @"970412"], @[@"KienLongBank", @"970452"], @[@"NCB", @"970419"], @[@"SaigonBank", @"970400"],
        @[@"PGBank", @"970430"], @[@"BaoVietBank", @"970438"], @[@"VietBank", @"970433"], @[@"GPBank", @"970408"],
        @[@"MBV", @"970414"], @[@"Vikki", @"970406"], @[@"COOPBANK", @"970446"], @[@"CBBank", @"970444"],
        @[@"ShinhanBank", @"970424"], @[@"Woori", @"970457"], @[@"UnitedOverseas", @"970458"], @[@"PublicBank", @"970439"],
        @[@"HongLeong", @"970442"], @[@"IndovinaBank", @"970434"], @[@"StandardChartered", @"970410"], @[@"HSBC", @"458761"],
        @[@"CIMB", @"422589"], @[@"VRB", @"970421"], @[@"CAKE", @"546034"], @[@"Ubank", @"546035"], @[@"Timo", @"963388"],
        @[@"TNEX", @"963326"], @[@"ViettelMoney", @"971005"], @[@"VNPTMoney", @"971011"], @[@"MoMo", @"971025"],
        @[@"ZaloPay", @"971101"],
    ];
}

/// «150.000 đ».
static NSString *GMMoney(long long v) {
    NSNumberFormatter *f = [[NSNumberFormatter alloc] init];
    f.numberStyle = NSNumberFormatterDecimalStyle;
    f.groupingSeparator = @".";
    f.usesGroupingSeparator = YES;
    return [[f stringFromNumber:@(v)] stringByAppendingString:@" đ"];
}

#pragma mark - Chọn ngân hàng

@interface GMBankPickerViewController : UITableViewController
@property (nonatomic, copy) void (^picked)(NSArray *bank);
@end

@implementation GMBankPickerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Ngân hàng";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return GMBanks().count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"b"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"b"];
    NSArray *b = [GMBanks() objectAtIndex:ip.row];
    c.textLabel.text = [b objectAtIndex:0];
    c.detailTextLabel.text = [b objectAtIndex:1];
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (self.picked) self.picked([GMBanks() objectAtIndex:ip.row]);
    [self.navigationController popViewControllerAnimated:YES];
}

@end

#pragma mark - Màn mã QR

@implementation GMVietQRViewController {
    UIScrollView *_scroll;
    UIButton *_bankBtn;
    UITextField *_account, *_holder, *_amount, *_note;
    UIImageView *_preview;
    NSArray *_bank;       // [tên, BIN]
    NSDictionary *_qr;    // {payload, size, bits} của lần dựng gần nhất
    UIImage *_card;
    NSUInteger _gen;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Mã QR chuyển khoản";
    self.view.backgroundColor = [GMTheme background];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Gửi" style:UIBarButtonItemStyleDone target:self
                                                                             action:@selector(sendTapped)];
    CGFloat W = self.view.bounds.size.width;
    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.alwaysBounceVertical = YES;
    [self.view addSubview:_scroll];
    CGFloat x = 12, w = MIN(W, 480) - 24, y = 12;
    if (W > 480) x = floor((W - w) / 2);
    _bankBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _bankBtn.frame = CGRectMake(x, y, w, 44);
    _bankBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    _bankBtn.backgroundColor = [GMTheme fieldBackground];
    _bankBtn.layer.cornerRadius = 8;
    _bankBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    _bankBtn.titleEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
    _bankBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [_bankBtn setTitleColor:[GMTheme accent] forState:UIControlStateNormal];
    [_bankBtn addTarget:self action:@selector(pickBank) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:_bankBtn];
    y += 52;
    _account = [self field:@"Số tài khoản" y:&y x:x w:w];
    _account.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    _holder = [self field:@"Tên chủ tài khoản (tuỳ chọn)" y:&y x:x w:w];
    _holder.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    _amount = [self field:@"Số tiền, đồng (tuỳ chọn)" y:&y x:x w:w];
    _amount.keyboardType = UIKeyboardTypeNumberPad;
    _note = [self field:@"Nội dung chuyển khoản (tuỳ chọn)" y:&y x:x w:w];
    _preview = [[UIImageView alloc] initWithFrame:CGRectMake(x, y + 4, w, w * 1.3)];
    _preview.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    _preview.contentMode = UIViewContentModeScaleAspectFit;
    [_scroll addSubview:_preview];
    _scroll.contentSize = CGSizeMake(W, CGRectGetMaxY(_preview.frame) + 20);
    NSDictionary *last = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kLast];
    if (last) {
        _bank = @[[last objectForKey:@"bank"] ?: @"", [last objectForKey:@"bin"] ?: @""];
        _account.text = [last objectForKey:@"account"];
        _holder.text = [last objectForKey:@"holder"];
    }
    [self updateBankTitle];
    [self rebuild];
}

/// Xếp các ô theo bề ngang thật của màn (iPad: cột phải 448 / 703 — viewDidLoad chưa biết), rộng tối đa 480, căn giữa.
- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    CGFloat W = self.view.bounds.size.width, w = MIN(W, 480) - 24, x = floor((W - w) / 2), y = 12;
    for (UIView *v in @[_bankBtn, _account, _holder, _amount, _note]) {
        v.frame = CGRectMake(x, y, w, v == _bankBtn ? 44 : 40);
        y += v == _bankBtn ? 52 : 48;
    }
    _preview.frame = CGRectMake(x, y + 4, w, w * 1.3);
    _scroll.contentSize = CGSizeMake(W, CGRectGetMaxY(_preview.frame) + 20);
}

- (UITextField *)field:(NSString *)placeholder y:(CGFloat *)y x:(CGFloat)x w:(CGFloat)w {
    UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(x, *y, w, 40)];
    f.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.placeholder = placeholder;
    f.font = [UIFont systemFontOfSize:16];
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.returnKeyType = UIReturnKeyDone;
    f.keyboardAppearance = [GMTheme keyboard];
    f.delegate = self;
    [f addTarget:self action:@selector(changed) forControlEvents:UIControlEventEditingChanged];
    [_scroll addSubview:f];
    *y += 48;
    return f;
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    return YES;
}

- (void)updateBankTitle {
    NSString *name = [_bank objectAtIndex:0];
    [_bankBtn setTitle:name.length ? [NSString stringWithFormat:@"Ngân hàng: %@  ›", name] : @"Chọn ngân hàng  ›"
              forState:UIControlStateNormal];
}

- (void)pickBank {
    [self.view endEditing:YES];
    GMBankPickerViewController *p = [[GMBankPickerViewController alloc] initWithStyle:UITableViewStylePlain];
    __weak GMVietQRViewController *ws = self;
    p.picked = ^(NSArray *bank) { [ws setBank:bank]; };
    [self.navigationController pushViewController:p animated:YES];
}

- (void)setBank:(NSArray *)bank {
    _bank = bank;
    [self updateBankTitle];
    [self rebuild];
}

- (void)changed {
    // Dựng lại sau 0,3 giây kể từ lần gõ cuối
    NSUInteger gen = ++_gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen == _gen) [self rebuild];
    });
}

- (NSString *)accountText {
    return [[_account.text componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] componentsJoinedByString:@""];
}

- (long long)amountValue {
    NSString *digits = [[_amount.text componentsSeparatedByCharactersInSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]]
                        componentsJoinedByString:@""];
    return digits.longLongValue;
}

- (void)rebuild {
    NSString *bin = [_bank objectAtIndex:1];
    if (bin.length != 6 || [self accountText].length < 4) {
        _qr = nil;
        _card = nil;
        _preview.image = nil;
        return;
    }
    NSMutableDictionary *args = [@{@"bin": bin, @"account": [self accountText]} mutableCopy];
    if ([self amountValue] > 0) [args setObject:@([self amountValue]) forKey:@"amount"];
    if (_note.text.length) [args setObject:_note.text forKey:@"note"];
    [GMCore call:@"vietqr.make" args:args done:^(id ok, NSDictionary *err) {
        if (err) {
            _qr = nil;
            _card = nil;
            _preview.image = nil;
            return;
        }
        _qr = ok;
        _card = [self drawCard];
        _preview.image = _card;
    }];
}

/// Thẻ chuyển khoản (ảnh 600 điểm ảnh ngang): tên ngân hàng, mã QR, số tài khoản, chủ tài khoản, số tiền, nội dung.
- (UIImage *)drawCard {
    NSInteger n = [GMVal(_qr, @"size") integerValue];
    NSString *bits = GMVal(_qr, @"bits");
    if (n <= 0 || bits.length != (NSUInteger)(n * n)) return nil;
    const CGFloat W = 600, pad = 40;
    CGFloat module = floor(440.0 / (n + 8));
    CGFloat qr = module * (n + 8);
    NSString *holder = [_holder.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *note = [_note.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    long long amount = [self amountValue];
    CGFloat H = pad + 40 + 16 + qr + 20 + 40 + (holder.length ? 36 : 0) + (amount > 0 ? 40 : 0) + (note.length ? 34 : 0) + 30 + pad;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(W, H), YES, 1);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[UIColor whiteColor] setFill];
    UIRectFill(CGRectMake(0, 0, W, H));
    UIColor *dark = [UIColor colorWithRed:0.1 green:0.15 blue:0.22 alpha:1];
    UIColor *gray = [UIColor colorWithWhite:0.45 alpha:1];
    UIColor *accent = [UIColor colorWithRed:0.0 green:0.42 blue:0.75 alpha:1];
    CGFloat y = pad;
    [dark set];
    [[_bank objectAtIndex:0] drawInRect:CGRectMake(pad, y, W - 2 * pad, 40) withFont:[UIFont boldSystemFontOfSize:32]
                          lineBreakMode:GMTailTruncation alignment:GMAlignCenter];
    y += 56;
    CGFloat qx = floor((W - qr) / 2);
    [[UIColor blackColor] setFill];
    for (NSInteger r = 0; r < n; r++) {
        for (NSInteger c = 0; c < n; c++) {
            if ([bits characterAtIndex:r * n + c] == '1') {
                CGContextFillRect(ctx, CGRectMake(qx + (c + 4) * module, y + (r + 4) * module, module, module));
            }
        }
    }
    y += qr + 20;
    [dark set];
    [[NSString stringWithFormat:@"STK: %@", [self accountText]] drawInRect:CGRectMake(pad, y, W - 2 * pad, 40)
                                                                  withFont:[UIFont boldSystemFontOfSize:30]
                                                             lineBreakMode:GMTailTruncation alignment:GMAlignCenter];
    y += 40;
    if (holder.length) {
        [holder.uppercaseString drawInRect:CGRectMake(pad, y, W - 2 * pad, 34) withFont:[UIFont systemFontOfSize:26]
                             lineBreakMode:GMTailTruncation alignment:GMAlignCenter];
        y += 36;
    }
    if (amount > 0) {
        [accent set];
        [[@"Số tiền: " stringByAppendingString:GMMoney(amount)] drawInRect:CGRectMake(pad, y, W - 2 * pad, 38)
                                                                   withFont:[UIFont boldSystemFontOfSize:28]
                                                              lineBreakMode:GMTailTruncation alignment:GMAlignCenter];
        y += 40;
    }
    if (note.length) {
        [gray set];
        [note drawInRect:CGRectMake(pad, y, W - 2 * pad, 32) withFont:[UIFont systemFontOfSize:24] lineBreakMode:GMTailTruncation
               alignment:GMAlignCenter];
        y += 34;
    }
    [gray set];
    [@"Quét bằng app ngân hàng bất kỳ (VietQR)" drawInRect:CGRectMake(pad, y + 4, W - 2 * pad, 26) withFont:[UIFont systemFontOfSize:20]
                                             lineBreakMode:GMTailTruncation alignment:GMAlignCenter];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (NSString *)caption {
    NSMutableString *s = [NSMutableString stringWithFormat:@"🏦 %@\nSTK: %@", [_bank objectAtIndex:0], [self accountText]];
    NSString *holder = [_holder.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (holder.length) [s appendFormat:@"\nChủ TK: %@", holder.uppercaseString];
    if ([self amountValue] > 0) [s appendFormat:@"\nSố tiền: %@", GMMoney([self amountValue])];
    NSString *note = [_note.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (note.length) [s appendFormat:@"\nNội dung: %@", note];
    return s;
}

- (void)sendTapped {
    [self.view endEditing:YES];
    if (!_card) {
        [GMTheme toast:[_bank objectAtIndex:1] ? @"Nhập số tài khoản (4–19 chữ số)." : @"Chọn ngân hàng trước." in:self.view];
        return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:@{@"bank": [_bank objectAtIndex:0], @"bin": [_bank objectAtIndex:1],
                                                       @"account": [self accountText], @"holder": _holder.text ?: @""}
                                              forKey:kLast];
    [[NSUserDefaults standardUserDefaults] synchronize];
    UIImage *card = _card;
    NSString *caption = [self caption];
    void (^send)(UIImage *, NSString *) = self.send;
    [self.navigationController popViewControllerAnimated:YES];
    if (send) send(card, caption);
}

/// Công cụ thử: «bin|số TK|chủ TK|số tiền|nội dung» điền sẵn (không gửi).
- (void)debugFill:(NSString *)spec {
    NSArray *p = [spec componentsSeparatedByString:@"|"];
    NSString *bin = p.count > 0 ? [p objectAtIndex:0] : @"";
    for (NSArray *b in GMBanks()) {
        if ([[b objectAtIndex:1] isEqual:bin]) _bank = b;
    }
    [self updateBankTitle];
    _account.text = p.count > 1 ? [p objectAtIndex:1] : @"";
    _holder.text = p.count > 2 ? [p objectAtIndex:2] : @"";
    _amount.text = p.count > 3 ? [p objectAtIndex:3] : @"";
    _note.text = p.count > 4 ? [p objectAtIndex:4] : @"";
    [self rebuild];
}

@end
