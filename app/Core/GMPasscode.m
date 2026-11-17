#import "GMPasscode.h"
#import "GMCompat.h"
#import "GMLog.h"
#import "GMTheme.h"
#import <CommonCrypto/CommonDigest.h>
#import <QuartzCore/QuartzCore.h>
#include <sys/stat.h>

static NSString *GMPasscodePath(void) {
    return [GMDataDir() stringByAppendingPathComponent:@"passcode.plist"];
}

static NSDictionary *GMPasscodeData(void) {
    return [NSDictionary dictionaryWithContentsOfFile:GMPasscodePath()];
}

static NSString *GMHash(NSString *salt, NSString *code) {
    NSData *d = [[salt stringByAppendingString:code ?: @""] dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char md[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes, (CC_LONG)d.length, md);
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", md[i]];
    return s;
}

NSString *const GMPasscodeUnlockedNotification = @"GMPasscodeUnlocked";

static UIWindow *gLockWindow;
static NSDate *gLeftAt;

// Số lần nhập sai liên tiếp + khoá tới lúc nào: lưu lại (kiểm bảo mật 17/11/2026 — trước chỉ nằm trong bộ nhớ, tắt app mở lại
// là đếm lại từ đầu → thử hết 10 000 mã trong vài giờ). Sai từ lần thứ 5: chờ 30 giây, rồi 1, 5, 15 phút, 1 giờ.
static NSString *const kFailsKey = @"passcode.fails", *const kUntilKey = @"passcode.until";

static NSTimeInterval GMLockRemaining(void) {
    double until = [[NSUserDefaults standardUserDefaults] doubleForKey:kUntilKey];
    double left = until - [[NSDate date] timeIntervalSince1970];
    return left > 3600 ? 3600 : left;  // đồng hồ máy bị chỉnh lùi: không chờ quá 1 giờ
}

static void GMLockFailed(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSInteger fails = [d integerForKey:kFailsKey] + 1;
    [d setInteger:fails forKey:kFailsKey];
    if (fails >= 5) {
        static const int waits[] = {30, 60, 300, 900, 3600};
        int w = waits[MIN(fails - 5, 4)];
        [d setDouble:[[NSDate date] timeIntervalSince1970] + w forKey:kUntilKey];
    }
    [d synchronize];
}

static void GMLockSucceeded(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d removeObjectForKey:kFailsKey];
    [d removeObjectForKey:kUntilKey];
}

@interface GMLockViewController ()
/// Nằm trên cửa sổ khoá riêng (iOS 5: tự xoay theo thanh trạng thái — cửa sổ phụ không được iOS 5 xoay khi hiện lúc máy đã nằm ngang).
@property (nonatomic) BOOL inLockWindow;
@end

@implementation GMPasscode

/// iOS 5: xoay màn khoá theo hướng thanh trạng thái (iOS 6 tự xoay cửa sổ có view controller gốc).
+ (void)orientLock {
    if (!gLockWindow || !GMOldIOS()) return;
    UIView *v = gLockWindow.rootViewController.view;
    UIInterfaceOrientation o = [UIApplication sharedApplication].statusBarOrientation;
    CGRect s = [UIScreen mainScreen].bounds;
    CGFloat a = o == UIInterfaceOrientationLandscapeLeft ? -M_PI_2
                : o == UIInterfaceOrientationLandscapeRight ? M_PI_2
                : o == UIInterfaceOrientationPortraitUpsideDown ? M_PI
                                                                : 0;
    v.transform = CGAffineTransformMakeRotation(a);
    v.bounds = UIInterfaceOrientationIsLandscape(o) ? CGRectMake(0, 0, s.size.height, s.size.width) : CGRectMake(0, 0, s.size.width, s.size.height);
    v.center = CGPointMake(CGRectGetMidX(s), CGRectGetMidY(s));
    [v setNeedsLayout];
}

+ (BOOL)enabled {
    return [GMPasscodeData() objectForKey:@"hash"] != nil;
}

+ (BOOL)check:(NSString *)code {
    NSDictionary *d = GMPasscodeData();
    NSString *h = [d objectForKey:@"hash"];
    return h && [h isEqualToString:GMHash([d objectForKey:@"salt"] ?: @"", code)];
}

+ (void)save:(NSDictionary *)d {
    if (!d) {
        [[NSFileManager defaultManager] removeItemAtPath:GMPasscodePath() error:NULL];
        return;
    }
    [d writeToFile:GMPasscodePath() atomically:YES];
    chmod(GMPasscodePath().fileSystemRepresentation, 0600);
}

+ (void)setCode:(NSString *)code {
    if (!code) {
        [self save:nil];
        return;
    }
    uint8_t r[16];
    arc4random_buf(r, sizeof(r));
    NSMutableString *salt = [NSMutableString string];
    for (int i = 0; i < 16; i++) [salt appendFormat:@"%02x", r[i]];
    [self save:@{@"salt": salt, @"hash": GMHash(salt, code), @"autolock": @([self autolock])}];
}

+ (NSInteger)autolock {
    NSNumber *n = [GMPasscodeData() objectForKey:@"autolock"];
    return n ? n.integerValue : 60;
}

+ (void)setAutolock:(NSInteger)seconds {
    NSMutableDictionary *d = [GMPasscodeData() mutableCopy];
    if (!d) return;
    [d setObject:@(seconds) forKey:@"autolock"];
    [self save:d];
}

+ (NSString *)autolockText:(NSInteger)s {
    if (s <= 0) return @"Ngay lập tức";
    if (s < 3600) return [NSString stringWithFormat:@"Sau %ld phút", (long)(s / 60)];
    return [NSString stringWithFormat:@"Sau %ld giờ", (long)(s / 3600)];
}

#pragma mark Khoá / mở

+ (BOOL)isLocked {
    return gLockWindow != nil;
}

+ (void)showLock {
    if (gLockWindow || ![self enabled]) return;
    [[UIApplication sharedApplication].keyWindow endEditing:YES];  // bàn phím của app khỏi nổi trên màn khoá
    GMLockViewController *vc = [[GMLockViewController alloc] initWithMode:GMLockUnlock];
    vc.inLockWindow = YES;
    UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.windowLevel = UIWindowLevelStatusBar - 1;  // trên app và hộp thoại của app
    w.rootViewController = vc;
    vc.done = ^(NSString *code) {
        [UIView animateWithDuration:0.2 animations:^{ gLockWindow.alpha = 0; }
                         completion:^(BOOL f) {
                             gLockWindow.hidden = YES;
                             gLockWindow = nil;
                             [[[UIApplication sharedApplication].delegate window] makeKeyWindow];
                             [[NSNotificationCenter defaultCenter] postNotificationName:GMPasscodeUnlockedNotification object:nil];
                         }];
    };
    gLockWindow = w;
    [w makeKeyAndVisible];
    if (GMOldIOS()) {
        [self orientLock];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(orientLock)
                                                         name:UIApplicationDidChangeStatusBarOrientationNotification object:nil];
        });
    }
}

+ (void)lockAtLaunch {
    [self showLock];
}

+ (void)didEnterBackground {
    gLeftAt = [NSDate date];
    // Phủ ngay (ảnh chụp ở thanh đa nhiệm không lộ tin nhắn); quay lại sớm hơn thời gian tự khoá thì tự gỡ
    [self showLock];
}

+ (void)willEnterForeground {
    if (!gLockWindow || !gLeftAt) return;
    if ([[NSDate date] timeIntervalSinceDate:gLeftAt] < [self autolock]) {
        gLockWindow.hidden = YES;
        gLockWindow = nil;
        [[[UIApplication sharedApplication].delegate window] makeKeyWindow];
    }
}

+ (void)debugEnter:(NSString *)code {
    UIViewController *vc = gLockWindow.rootViewController;
    if (!vc) {  // màn đặt / xác nhận mật mã bật lên từ Cài đặt
        vc = [[UIApplication sharedApplication].delegate window].rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
    }
    if ([vc isKindOfClass:[GMLockViewController class]]) [(GMLockViewController *)vc enterDigits:code];
}

@end

#pragma mark - Màn nhập mật mã

@implementation GMLockViewController {
    GMLockMode _mode;
    UILabel *_title, *_hint;
    NSMutableArray *_dots;
    UIView *_dotBox, *_pad;
    NSMutableString *_entry;
    NSString *_first;  // đặt mới: lần nhập thứ nhất
}

- (instancetype)initWithMode:(GMLockMode)mode {
    if ((self = [super init])) {
        _mode = mode;
        _entry = [NSMutableString string];
    }
    return self;
}

- (void)loadView {
    UIView *v = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    v.backgroundColor = [UIColor colorWithRed:0.16 green:0.45 blue:0.78 alpha:1];
    self.view = v;
    _title = [[UILabel alloc] init];
    _title.textColor = [UIColor whiteColor];
    _title.font = [UIFont systemFontOfSize:20];
    _title.textAlignment = GMAlignCenter;
    _title.backgroundColor = [UIColor clearColor];
    [v addSubview:_title];
    _hint = [[UILabel alloc] init];
    _hint.textColor = [UIColor colorWithWhite:1 alpha:0.8];
    _hint.font = [UIFont systemFontOfSize:14];
    _hint.textAlignment = GMAlignCenter;
    _hint.numberOfLines = 2;
    _hint.backgroundColor = [UIColor clearColor];
    [v addSubview:_hint];
    _dotBox = [[UIView alloc] init];
    [v addSubview:_dotBox];
    _dots = [NSMutableArray array];
    for (int i = 0; i < 4; i++) {
        UIView *d = [[UIView alloc] initWithFrame:CGRectMake(i * 30, 0, 14, 14)];
        d.layer.cornerRadius = 7;
        d.layer.borderColor = [UIColor whiteColor].CGColor;
        d.layer.borderWidth = 1.5;
        [_dotBox addSubview:d];
        [_dots addObject:d];
    }
    _pad = [[UIView alloc] init];
    [v addSubview:_pad];
    NSArray *keys = @[@"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9", @"", @"0", @"⌫"];
    for (NSUInteger i = 0; i < keys.count; i++) {
        NSString *k = [keys objectAtIndex:i];
        if (!k.length) continue;
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.tag = i;
        [b setTitle:k forState:UIControlStateNormal];
        b.titleLabel.font = [k isEqual:@"⌫"] ? [UIFont systemFontOfSize:24] : [UIFont systemFontOfSize:32];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        if (![k isEqual:@"⌫"]) {
            b.layer.cornerRadius = 36;
            b.layer.borderWidth = 1.5;
            b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.7].CGColor;
        }
        [b addTarget:self action:@selector(keyDown:) forControlEvents:UIControlEventTouchDown];
        [b addTarget:self action:@selector(keyUp:) forControlEvents:UIControlEventTouchUpInside];
        [b addTarget:self action:@selector(keyCancel:) forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        [_pad addSubview:b];
    }
    if (_mode != GMLockUnlock) {
        UIButton *cancel = [UIButton buttonWithType:UIButtonTypeCustom];
        cancel.tag = 999;
        [cancel setTitle:@"Huỷ" forState:UIControlStateNormal];
        cancel.titleLabel.font = [UIFont systemFontOfSize:17];
        [cancel addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];
        [v addSubview:cancel];
    }
    [self reset:nil];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    CGRect b = self.view.bounds;
    CGFloat key = 72, gap = 20;
    CGFloat padW = key * 3 + gap * 2, padH = key * 4 + 14 * 3;
    BOOL wide = b.size.width > b.size.height && b.size.height < 500;  // iPhone nằm ngang: chữ bên trái, bàn phím bên phải
    CGFloat top = MAX(20, (b.size.height - padH - 150) / 2);
    if (wide) {
        _title.frame = CGRectMake(0, b.size.height / 2 - 60, b.size.width / 2, 26);
        _hint.frame = CGRectMake(10, b.size.height / 2 + 30, b.size.width / 2 - 20, 40);
        _dotBox.frame = CGRectMake(b.size.width / 4 - 52, b.size.height / 2 - 10, 104, 14);
        _pad.frame = CGRectMake(b.size.width * 0.75 - padW / 2, (b.size.height - padH) / 2, padW, padH);
    } else {
        _title.frame = CGRectMake(0, top, b.size.width, 26);
        _dotBox.frame = CGRectMake((b.size.width - 104) / 2, top + 42, 104, 14);
        _hint.frame = CGRectMake(20, top + 62, b.size.width - 40, 40);
        _pad.frame = CGRectMake((b.size.width - padW) / 2, top + 110, padW, padH);
    }
    for (UIView *k in _pad.subviews) {
        NSInteger i = k.tag;
        k.frame = CGRectMake((i % 3) * (key + gap), (i / 3) * (key + 14), key, key);
    }
    [self.view viewWithTag:999].frame = CGRectMake(b.size.width - 80, b.size.height - 50, 70, 40);
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o {
    if (self.inLockWindow && GMOldIOS()) return o == UIInterfaceOrientationPortrait;  // iOS 5: tự xoay (orientLock)
    return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad || o != UIInterfaceOrientationPortraitUpsideDown;
}

// iOS 6: mặc định đã đúng (iPad mọi hướng, iPhone trừ lộn ngược) — không ghi đè (kiểu UIInterfaceOrientationMask chỉ có từ iOS 6)

- (void)reset:(NSString *)hint {
    [_entry setString:@""];
    [self updateDots];
    switch (_mode) {
        case GMLockUnlock: _title.text = @"Nhập mật mã"; break;
        case GMLockVerify: _title.text = @"Nhập mật mã hiện tại"; break;
        case GMLockSetNew: _title.text = _first ? @"Nhập lại mật mã" : @"Nhập mật mã mới"; break;
    }
    _hint.text = hint ?: (_mode == GMLockUnlock ? @"GramMini" : @"");
}

- (void)updateDots {
    for (NSUInteger i = 0; i < _dots.count; i++) {
        UIView *d = [_dots objectAtIndex:i];
        d.backgroundColor = i < _entry.length ? [UIColor whiteColor] : [UIColor clearColor];
    }
}

- (void)keyDown:(UIButton *)b {
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.3];
}

- (void)keyCancel:(UIButton *)b {
    b.backgroundColor = [UIColor clearColor];
}

- (void)keyUp:(UIButton *)b {
    b.backgroundColor = [UIColor clearColor];
    NSString *k = [b titleForState:UIControlStateNormal];
    if ([k isEqual:@"⌫"]) {
        if (_entry.length) [_entry deleteCharactersInRange:NSMakeRange(_entry.length - 1, 1)];
        [self updateDots];
        return;
    }
    [self enterDigits:k];
}

- (void)enterDigits:(NSString *)digits {
    for (NSUInteger i = 0; i < digits.length && _entry.length < 4; i++) {
        unichar c = [digits characterAtIndex:i];
        if (c >= '0' && c <= '9') [_entry appendFormat:@"%C", c];
    }
    [self updateDots];
    if (_entry.length == 4) [self performSelector:@selector(complete) withObject:nil afterDelay:0.1];
}

- (void)complete {
    NSString *code = [_entry copy];
    if (_mode == GMLockSetNew) {
        if (!_first) {
            _first = code;
            [self reset:nil];
            return;
        }
        if ([_first isEqual:code]) {
            if (self.done) self.done(code);
            return;
        }
        _first = nil;
        [self shake:@"Hai lần nhập không khớp — nhập lại."];
        return;
    }
    NSTimeInterval wait = GMLockRemaining();
    if (wait > 0) {
        [self shake:wait > 90 ? [NSString stringWithFormat:@"Sai nhiều lần — thử lại sau %.0f phút.", ceil(wait / 60)]
                              : [NSString stringWithFormat:@"Sai nhiều lần — thử lại sau %.0f giây.", ceil(wait)]];
        return;
    }
    if ([GMPasscode check:code]) {
        GMLockSucceeded();
        if (self.done) self.done(code);
        return;
    }
    GMLockFailed();
    if (GMLockRemaining() > 0) GMLog(@"mật mã sai nhiều lần — khoá %.0f giây", GMLockRemaining());
    [self shake:@"Sai mật mã."];
}

- (void)shake:(NSString *)hint {
    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    a.values = @[@0, @(-14), @14, @(-10), @10, @(-5), @5, @0];
    a.duration = 0.4;
    [_dotBox.layer addAnimation:a forKey:@"shake"];
    [self reset:hint];
}

- (void)cancel {
    if (self.done) self.done(nil);
}

@end
