#import "GMCallViewController.h"
#import "GMCallAudio.h"
#import "GMCallManager.h"
#import "GMImages.h"
#import "GMTheme.h"
#import <QuartzCore/QuartzCore.h>

static UIImage *GMCallDraw(CGSize size, void (^draw)(CGContextRef ctx)) {
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    draw(UIGraphicsGetCurrentContext());
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

/// Nút tròn: kính trắng trong mờ trên nền màu (`fill` nil) hoặc màu đặc (đỏ / xanh); `on` = đang bật (nền trắng đặc).
static UIImage *GMCallCircle(CGFloat d, UIColor *fill, BOOL pressed, BOOL on) {
    return GMCallDraw(CGSizeMake(d, d), ^(CGContextRef ctx) {
        CGRect r = CGRectMake(1, 1, d - 2, d - 2);
        UIColor *c = fill ?: [UIColor colorWithWhite:1 alpha:on ? 0.92 : 0.2];
        if (pressed) c = fill ? [fill colorWithAlphaComponent:0.7] : [UIColor colorWithWhite:1 alpha:on ? 0.7 : 0.36];
        [c setFill];
        CGContextFillEllipseInRect(ctx, r);
        if (!fill && !on) {
            // Viền sáng phía trên như mặt kính
            [[UIColor colorWithWhite:1 alpha:0.35] setStroke];
            CGContextSetLineWidth(ctx, 1);
            CGContextStrokeEllipseInRect(ctx, CGRectInset(r, 0.5, 0.5));
        }
    });
}

/// Biểu tượng 32 điểm: phone (ống nghe), speaker, mic, micoff.
static UIImage *GMCallIcon(NSString *name, UIColor *color, CGFloat angle) {
    return GMCallDraw(CGSizeMake(32, 32), ^(CGContextRef ctx) {
        [color setFill];
        [color setStroke];
        CGContextSetLineCap(ctx, kCGLineCapRound);
        CGContextSetLineJoin(ctx, kCGLineJoinRound);
        CGContextTranslateCTM(ctx, 16, 16);
        CGContextRotateCTM(ctx, angle);
        CGContextTranslateCTM(ctx, -16, -16);
        if ([name isEqual:@"phone"]) {
            // Ống nghe: hai đầu tròn nối bằng cung
            UIBezierPath *p = [UIBezierPath bezierPath];
            [p moveToPoint:CGPointMake(7, 9)];
            [p addCurveToPoint:CGPointMake(23, 25) controlPoint1:CGPointMake(7, 18) controlPoint2:CGPointMake(14, 25)];
            p.lineWidth = 4.2;
            [p stroke];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(4.5, 4, 6.5, 8) cornerRadius:2.2] fill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(20, 21.5, 8, 6.5) cornerRadius:2.2] fill];
        } else if ([name isEqual:@"speaker"]) {
            UIBezierPath *p = [UIBezierPath bezierPath];
            [p moveToPoint:CGPointMake(5, 12.5)];
            [p addLineToPoint:CGPointMake(10, 12.5)];
            [p addLineToPoint:CGPointMake(16, 7)];
            [p addLineToPoint:CGPointMake(16, 25)];
            [p addLineToPoint:CGPointMake(10, 19.5)];
            [p addLineToPoint:CGPointMake(5, 19.5)];
            [p closePath];
            [p fill];
            CGContextSetLineWidth(ctx, 2);
            CGContextAddArc(ctx, 16, 16, 5.5, -0.8, 0.8, 0);
            CGContextStrokePath(ctx);
            CGContextAddArc(ctx, 16, 16, 10, -0.85, 0.85, 0);
            CGContextStrokePath(ctx);
        } else if ([name isEqual:@"mic"] || [name isEqual:@"micoff"]) {
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(12, 4, 8, 15) cornerRadius:4] fill];
            CGContextSetLineWidth(ctx, 2);
            CGContextAddArc(ctx, 16, 13.5, 8, 0.15, M_PI - 0.15, 0);
            CGContextStrokePath(ctx);
            CGContextMoveToPoint(ctx, 16, 21.5);
            CGContextAddLineToPoint(ctx, 16, 27);
            CGContextMoveToPoint(ctx, 11.5, 27.5);
            CGContextAddLineToPoint(ctx, 20.5, 27.5);
            CGContextStrokePath(ctx);
            if ([name isEqual:@"micoff"]) {
                CGContextSetLineWidth(ctx, 2.4);
                CGContextMoveToPoint(ctx, 6, 5);
                CGContextAddLineToPoint(ctx, 26, 27);
                CGContextStrokePath(ctx);
            }
        }
    });
}

/// Vạch sóng nhỏ cạnh đồng hồ.
static UIImage *GMCallBars(NSInteger bars) {
    return GMCallDraw(CGSizeMake(16, 12), ^(CGContextRef ctx) {
        for (int i = 0; i < 4; i++) {
            [[UIColor colorWithWhite:1 alpha:i < bars ? 1 : 0.35] setFill];
            CGFloat h = 3 + i * 3;
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(i * 4, 12 - h, 3, h) cornerRadius:1] fill];
        }
    });
}

@implementation GMCallViewController {
    NSDictionary *_chat, *_state;
    UIImageView *_bg, *_avatar, *_barsView;
    UIButton *_emojiBtn;
    UILabel *_hint, *_name, *_status;
    UIView *_activeRow, *_incomingRow;
    UIButton *_speakerBtn, *_muteBtn;
    NSTimer *_clock;
    NSDate *_connectedAt;
    NSInteger _bars;
    BOOL _muted;
}

- (instancetype)initWithChat:(NSDictionary *)chat {
    if ((self = [super init])) {
        _chat = chat;
        _bars = 4;
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (NSString *)peer {
    return [GMVal(_state, @"peer") description] ?: [GMVal(_chat, @"peer") description];
}

- (NSString *)nameText {
    NSString *n = GMVal(_chat, @"name");
    return n.length ? n : @"Cuộc gọi thoại";
}

/// Nền: hai sắc của màu người bên kia, tối dần xuống dưới (chữ trắng luôn đọc được).
- (UIImage *)backgroundImage:(CGSize)size {
    UIColor *base = [GMTheme colorFor:[self peer] ?: @"0"];
    CGFloat h = 0, s = 0, b = 0, a = 1;
    if (![base getHue:&h saturation:&s brightness:&b alpha:&a]) h = 0.58;
    UIColor *top = [UIColor colorWithHue:h saturation:MIN(0.55, s) brightness:0.62 alpha:1];
    UIColor *bottom = [UIColor colorWithHue:fmod(h + 0.08, 1) saturation:MIN(0.65, s + 0.1) brightness:0.28 alpha:1];
    return GMCallDraw(size, ^(CGContextRef ctx) {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGColorRef cols[2] = {top.CGColor, bottom.CGColor};
        CFArrayRef arr = CFArrayCreate(NULL, (const void **)cols, 2, &kCFTypeArrayCallBacks);
        CGGradientRef g = CGGradientCreateWithColors(cs, arr, NULL);
        CGContextDrawLinearGradient(ctx, g, CGPointZero, CGPointMake(size.width * 0.3, size.height),
                                    kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
        // Vầng sáng mềm sau ảnh đại diện
        CGColorRef glow[2] = {[UIColor colorWithWhite:1 alpha:0.16].CGColor, [UIColor colorWithWhite:1 alpha:0].CGColor};
        CFArrayRef arr2 = CFArrayCreate(NULL, (const void **)glow, 2, &kCFTypeArrayCallBacks);
        CGGradientRef g2 = CGGradientCreateWithColors(cs, arr2, NULL);
        CGPoint c = CGPointMake(size.width / 2, size.height * 0.36);
        CGContextDrawRadialGradient(ctx, g2, c, 0, c, size.width * 0.7, 0);
        CGGradientRelease(g);
        CGGradientRelease(g2);
        CFRelease(arr);
        CFRelease(arr2);
        CGColorSpaceRelease(cs);
    });
}

- (UIButton *)roundButton:(NSString *)icon fill:(UIColor *)fill size:(CGFloat)d title:(NSString *)title action:(SEL)action
                       in:(UIView *)row x:(CGFloat)x {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(x, 0, d, d);
    [b setBackgroundImage:GMCallCircle(d, fill, NO, NO) forState:UIControlStateNormal];
    [b setBackgroundImage:GMCallCircle(d, fill, YES, NO) forState:UIControlStateHighlighted];
    CGFloat angle = [icon isEqual:@"hangup"] ? (CGFloat)(M_PI * 0.75) : 0;
    [b setImage:GMCallIcon([icon isEqual:@"hangup"] ? @"phone" : icon, [UIColor whiteColor], angle) forState:UIControlStateNormal];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [row addSubview:b];
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(x - 20, d + 6, d + 40, 18)];
    l.text = title;
    l.font = [UIFont systemFontOfSize:13];
    l.textColor = [UIColor colorWithWhite:1 alpha:0.9];
    l.backgroundColor = [UIColor clearColor];
    l.textAlignment = GMAlignCenter;
    l.tag = 0x6c62;
    [row addSubview:l];
    return b;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UIView *v = self.view;
    v.backgroundColor = [UIColor blackColor];
    _bg = [[UIImageView alloc] initWithFrame:v.bounds];
    _bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _bg.contentMode = UIViewContentModeScaleToFill;
    [v addSubview:_bg];

    _emojiBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _emojiBtn.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
    _emojiBtn.layer.cornerRadius = 18;
    _emojiBtn.titleLabel.font = [UIFont systemFontOfSize:22];
    _emojiBtn.hidden = YES;
    [_emojiBtn addTarget:self action:@selector(emojiTapped) forControlEvents:UIControlEventTouchUpInside];
    [v addSubview:_emojiBtn];
    _hint = [[UILabel alloc] init];
    _hint.numberOfLines = 0;
    _hint.font = [UIFont systemFontOfSize:14];
    _hint.textColor = [UIColor whiteColor];
    _hint.backgroundColor = [UIColor colorWithWhite:0 alpha:0.28];
    _hint.layer.cornerRadius = 12;
    _hint.textAlignment = GMAlignCenter;
    _hint.hidden = YES;
    [v addSubview:_hint];

    _avatar = [[UIImageView alloc] init];
    _avatar.image = [GMTheme avatarFor:[self peer] name:[self nameText] size:128];
    [v addSubview:_avatar];
    NSString *photo = [GMVal(_chat, @"photo") description];
    if (photo.length) {
        __weak UIImageView *wa = _avatar;
        [GMImages avatarForPeer:[self peer] photo:photo dc:GMVal(_chat, @"photo_dc") size:128 done:^(UIImage *img) {
            if (img) wa.image = img;
        }];
    }
    _name = [[UILabel alloc] init];
    _name.text = [self nameText];
    _name.font = [UIFont fontWithName:@"HelveticaNeue-Light" size:30] ?: [UIFont systemFontOfSize:30];
    _name.textColor = [UIColor whiteColor];
    _name.backgroundColor = [UIColor clearColor];
    _name.textAlignment = GMAlignCenter;
    _name.adjustsFontSizeToFitWidth = YES;
    [v addSubview:_name];
    _status = [[UILabel alloc] init];
    _status.font = [UIFont systemFontOfSize:17];
    _status.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    _status.backgroundColor = [UIColor clearColor];
    _status.textAlignment = GMAlignCenter;
    [v addSubview:_status];
    _barsView = [[UIImageView alloc] initWithImage:GMCallBars(4)];
    _barsView.hidden = YES;
    [v addSubview:_barsView];

    _activeRow = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 276, 96)];
    _speakerBtn = [self roundButton:@"speaker" fill:nil size:72 title:@"Loa ngoài" action:@selector(speakerTapped) in:_activeRow x:0];
    _muteBtn = [self roundButton:@"mic" fill:nil size:72 title:@"Tắt micro" action:@selector(muteTapped) in:_activeRow x:102];
    [self roundButton:@"hangup" fill:[UIColor colorWithRed:0.95 green:0.23 blue:0.23 alpha:1] size:72 title:@"Kết thúc"
               action:@selector(hangupTapped) in:_activeRow x:204];
    [v addSubview:_activeRow];
    _incomingRow = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 236, 100)];
    [self roundButton:@"hangup" fill:[UIColor colorWithRed:0.95 green:0.23 blue:0.23 alpha:1] size:76 title:@"Từ chối"
               action:@selector(declineTapped) in:_incomingRow x:0];
    [self roundButton:@"phone" fill:[UIColor colorWithRed:0.2 green:0.78 blue:0.35 alpha:1] size:76 title:@"Nghe"
               action:@selector(acceptTapped) in:_incomingRow x:160];
    [v addSubview:_incomingRow];
    [self apply];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    CGSize s = self.view.bounds.size;
    if (!CGSizeEqualToSize(_bg.image.size, s)) _bg.image = [self backgroundImage:s];
    CGFloat w = s.width, top = 20;
    CGFloat emojiW = 190;
    _emojiBtn.frame = CGRectMake(floor((w - emojiW) / 2), top + 18, emojiW, 36);
    CGFloat hintW = MIN(w - 40, 320);
    CGSize hs = [_hint.text sizeWithFont:_hint.font constrainedToSize:CGSizeMake(hintW - 24, 200) lineBreakMode:GMWordWrap];
    _hint.frame = CGRectMake(floor((w - hintW) / 2), CGRectGetMaxY(_emojiBtn.frame) + 10, hintW, hs.height + 20);
    CGFloat avTop = MAX(top + 84, floor(s.height * 0.2));
    if (!_hint.hidden) avTop = MAX(avTop, CGRectGetMaxY(_hint.frame) + 16);  // chú thích emoji đang mở: ảnh lùi xuống
    _avatar.frame = CGRectMake(floor((w - 128) / 2), avTop, 128, 128);
    _name.frame = CGRectMake(20, CGRectGetMaxY(_avatar.frame) + 22, w - 40, 38);
    _status.frame = CGRectMake(20, CGRectGetMaxY(_name.frame) + 4, w - 40, 22);
    [self layoutBars];
    CGFloat bottom = s.height - (s.height > 500 ? 60 : 36);
    _activeRow.frame = CGRectMake(floor((w - 276) / 2), bottom - 96, 276, 96);
    _incomingRow.frame = CGRectMake(floor((w - 236) / 2), bottom - 100, 236, 100);
}

- (void)layoutBars {
    CGSize ts = [_status.text ?: @"" sizeWithFont:_status.font];
    CGRect f = _status.frame;
    _barsView.frame = CGRectMake(floor(f.origin.x + (f.size.width - ts.width) / 2 - 22), f.origin.y + 5, 16, 12);
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad ? UIInterfaceOrientationMaskAll : UIInterfaceOrientationMaskPortrait;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o {
    return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad || o == UIInterfaceOrientationPortrait;
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [_clock invalidate];
    _clock = nil;
}

#pragma mark Trạng thái

- (void)update:(NSDictionary *)state {
    _state = state;
    if ([self isViewLoaded]) [self apply];
}

- (void)setBars:(NSInteger)bars {
    _bars = bars;
    _barsView.image = GMCallBars(bars);
}

- (void)apply {
    NSString *st = GMVal(_state, @"state");
    BOOL incoming = [st isEqual:@"incoming"];
    BOOL ended = [st isEqual:@"ended"];
    _incomingRow.hidden = !incoming;
    _activeRow.hidden = incoming;
    _activeRow.userInteractionEnabled = !ended;
    _activeRow.alpha = ended ? 0.5 : 1;
    _muted = [GMVal(_state, @"muted") boolValue];
    [self refreshToggles];

    NSArray *emoji = GMVal(_state, @"emoji");
    if ([emoji isKindOfClass:[NSArray class]] && emoji.count == 4) {
        // iOS 5 thiếu 3 emoji của bảng khoá (Unicode 6.1, có từ iOS 6 — đo bằng emojicheck 21/11/2026) → hiện «?» và tả
        // bằng chữ trong chú thích để vẫn đối chiếu được
        NSDictionary *words = @{@"😛": @"mặt lè lưỡi", @"😴": @"mặt đang ngủ", @"😬": @"mặt nhăn răng"};
        NSMutableArray *shown = [NSMutableArray array], *missing = [NSMutableArray array];
        for (NSString *e in emoji) {
            BOOL ok = [GMTheme emojiRenders:e];
            [shown addObject:ok ? e : @"?"];
            if (!ok) [missing addObject:[words objectForKey:e] ?: @"hình máy này không vẽ được"];
        }
        [_emojiBtn setTitle:[shown componentsJoinedByString:@"  "] forState:UIControlStateNormal];
        _emojiBtn.hidden = NO;
        NSString *hint = [NSString stringWithFormat:@"Cuộc gọi được mã hoá đầu-cuối. Nếu 4 hình này giống trên máy của %@, "
                                                     "không ai nghe lén được.",
                                                    [self nameText]];
        if (missing.count) hint = [hint stringByAppendingFormat:@"\n«?» là: %@.", [missing componentsJoinedByString:@", "]];
        _hint.text = hint;
    }
    if ([st isEqual:@"connected"] && !_connectedAt) {
        int d = [GMVal(_state, @"duration") intValue];
        _connectedAt = [NSDate dateWithTimeIntervalSinceNow:-d];
        if (!_clock) _clock = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    }
    _barsView.hidden = ![st isEqual:@"connected"];
    [self tick];
    [self.view setNeedsLayout];
}

- (void)tick {
    NSString *st = GMVal(_state, @"state");
    NSString *text;
    if ([st isEqual:@"connected"] && _connectedAt) {
        int s = (int)-[_connectedAt timeIntervalSinceNow];
        text = [NSString stringWithFormat:@"%d:%02d", s / 60, s % 60];
        if ([GMVal(_state, @"relay") boolValue]) text = [text stringByAppendingString:@" · qua máy chủ"];
    } else if ([st isEqual:@"incoming"]) {
        text = @"Cuộc gọi thoại đến";
    } else if ([st isEqual:@"requesting"]) {
        text = @"Đang gọi…";
    } else if ([st isEqual:@"ringing"]) {
        text = @"Đang đổ chuông…";
    } else if ([st isEqual:@"exchanging"]) {
        text = @"Đang trao khoá…";
    } else if ([st isEqual:@"reconnecting"]) {
        text = @"Đang kết nối lại…";
    } else if ([st isEqual:@"ended"]) {
        NSString *r = GMVal(_state, @"reason");
        text = [r isEqual:@"busy"] ? @"Máy bận" : [r isEqual:@"missed"] ? @"Không trả lời" : [r isEqual:@"disconnect"] ? @"Mất kết nối"
            : [r isEqual:@"error"] ? @"Lỗi kết nối" : [r isEqual:@"elsewhere"] ? @"Đã xử lý trên máy khác" : @"Cuộc gọi kết thúc";
    } else {
        text = @"Đang kết nối…";
    }
    _status.text = text;
    [self layoutBars];
}

- (void)refreshToggles {
    BOOL spk = [GMCallAudio shared].speaker;
    [_speakerBtn setBackgroundImage:GMCallCircle(72, nil, NO, spk) forState:UIControlStateNormal];
    [_speakerBtn setBackgroundImage:GMCallCircle(72, nil, YES, spk) forState:UIControlStateHighlighted];
    [_speakerBtn setImage:GMCallIcon(@"speaker", spk ? [UIColor colorWithWhite:0.15 alpha:1] : [UIColor whiteColor], 0)
                 forState:UIControlStateNormal];
    [_muteBtn setBackgroundImage:GMCallCircle(72, nil, NO, _muted) forState:UIControlStateNormal];
    [_muteBtn setBackgroundImage:GMCallCircle(72, nil, YES, _muted) forState:UIControlStateHighlighted];
    [_muteBtn setImage:GMCallIcon(_muted ? @"micoff" : @"mic", _muted ? [UIColor colorWithWhite:0.15 alpha:1] : [UIColor whiteColor], 0)
              forState:UIControlStateNormal];
}

#pragma mark Nút

- (void)emojiTapped {
    _hint.hidden = !_hint.hidden;
    [self.view setNeedsLayout];
}

- (void)speakerTapped {
    [[GMCallManager shared] setSpeaker:![GMCallAudio shared].speaker];
    [self refreshToggles];
}

- (void)muteTapped {
    _muted = !_muted;
    [[GMCallManager shared] setMuted:_muted];
    [self refreshToggles];
}

- (void)hangupTapped {
    [[GMCallManager shared] hangup];
}

- (void)declineTapped {
    [[GMCallManager shared] decline];
}

- (void)acceptTapped {
    [[GMCallManager shared] accept];
}

@end
