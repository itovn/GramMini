#import "GMContextMenu.h"
#import "GMTheme.h"
#import "GMLog.h"
#import <QuartzCore/QuartzCore.h>
#import <Accelerate/Accelerate.h>

@implementation GMMenuItem

+ (instancetype)title:(NSString *)title icon:(NSString *)icon action:(void (^)(void))action {
    GMMenuItem *it = [[self alloc] init];
    it.title = title;
    it.icon = icon;
    it.action = action;
    return it;
}

@end

static const CGFloat kRowH = 44, kGroupGap = 8, kGap = 8, kReactH = 48, kEdge = 10;

/// Ảnh chụp `v` cỡ điểm × `scale` (`retina`: theo màn hình).
static UIImage *GMSnap(UIView *v, CGFloat scale, BOOL retina) {
    CGSize s = v.bounds.size;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(ceil(s.width * scale), ceil(s.height * scale)), NO, retina ? 0 : 1);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextScaleCTM(ctx, scale, scale);
    [v.layer renderInContext:ctx];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

/// Ảnh chụp sắc nét của bong bóng: iOS 5 / 6 `renderInContext:` bỏ qua vùng co giãn (contentsCenter) của ảnh nền → góc bo / đuôi
/// bị kéo méo. Vẽ ảnh nền bằng drawInRect: (đúng cap insets), rồi chụp từng view con lên trên.
static UIImage *GMSnapBubble(UIView *v) {
    if (![v isKindOfClass:[UIImageView class]] || !((UIImageView *)v).image) return GMSnap(v, 1, YES);
    CGSize s = v.bounds.size;
    UIGraphicsBeginImageContextWithOptions(s, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [((UIImageView *)v).image drawInRect:v.bounds];
    for (UIView *sub in v.subviews) {
        if (sub.hidden || sub.alpha < 0.01) continue;
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, sub.frame.origin.x, sub.frame.origin.y);
        [sub.layer renderInContext:ctx];
        CGContextRestoreGState(ctx);
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

/// Làm mờ ảnh nhỏ bằng ba lượt hộp (gần như Gauss) — vImage có từ iOS 5. Ảnh 1/4 cỡ màn: vài chục ms cả trên A5.
static UIImage *GMBlur(UIImage *img, uint32_t radius) {
    CGImageRef cg = img.CGImage;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg), rb = w * 4;
    if (!w || !h) return img;
    void *a = calloc(rb * h, 1), *b = calloc(rb * h, 1);
    if (!a || !b) {
        free(a);
        free(b);
        return img;
    }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo info = kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;
    CGContextRef ca = CGBitmapContextCreate(a, w, h, 8, rb, cs, info);
    CGContextDrawImage(ca, CGRectMake(0, 0, w, h), cg);
    vImage_Buffer src = {a, h, w, rb}, dst = {b, h, w, rb};
    uint32_t k = radius * 2 + 1;
    vImageBoxConvolve_ARGB8888(&src, &dst, NULL, 0, 0, k, k, NULL, kvImageEdgeExtend);
    vImageBoxConvolve_ARGB8888(&dst, &src, NULL, 0, 0, k, k, NULL, kvImageEdgeExtend);
    vImageBoxConvolve_ARGB8888(&src, &dst, NULL, 0, 0, k, k, NULL, kvImageEdgeExtend);
    CGContextRef cb = CGBitmapContextCreate(b, w, h, 8, rb, cs, info);
    CGImageRef out = CGBitmapContextCreateImage(cb);
    UIImage *r = [UIImage imageWithCGImage:out];
    CGImageRelease(out);
    CGContextRelease(ca);
    CGContextRelease(cb);
    CGColorSpaceRelease(cs);
    free(a);
    free(b);
    return r;
}

/// Máy yếu (iPad 1 — 256 MB, A4): bỏ làm mờ, chỉ phủ tối.
static BOOL GMWeakDevice(void) {
    return [NSProcessInfo processInfo].physicalMemory < 300ull * 1024 * 1024;
}

@implementation GMContextMenu {
    UIView *_host, *_source;
    CGRect _from, _liftTo;
    UIImageView *_blur;
    UIView *_dim, *_liftBox, *_menu, *_reacts;
    UIImageView *_lift;
    NSArray *_items;
    void (^_react)(NSString *);
    void (^_more)(void);
    NSArray *_emojis;
    BOOL _closing;
}

+ (UIImage *)blurredSnapshot:(UIView *)host {
    if (GMWeakDevice()) return nil;
    return GMBlur(GMSnap(host, 0.25, NO), 4);
}

+ (GMContextMenu *)showIn:(UIView *)host source:(UIView *)source outgoing:(BOOL)outgoing emojis:(NSArray *)emojis
                   chosen:(NSString *)chosen items:(NSArray *)items react:(void (^)(NSString *))react
                     more:(void (^)(void))more {
    long long t0 = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
    GMContextMenu *m = [[GMContextMenu alloc] initWithFrame:host.bounds];
    m->_host = host;
    m->_source = source;
    m->_items = items;
    m->_react = [react copy];
    m->_more = [more copy];
    m->_emojis = emojis;
    [m buildOutgoing:outgoing chosen:chosen];
    [host addSubview:m];
    [m animateIn];
    GMLog(@"menu giữ tin: %lld ms%@", (long long)([[NSDate date] timeIntervalSince1970] * 1000) - t0,
          GMWeakDevice() ? @" (không làm mờ)" : @"");
    return m;
}

- (void)buildOutgoing:(BOOL)outgoing chosen:(NSString *)chosen {
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    CGRect bounds = self.bounds;
    CGFloat W = bounds.size.width, H = bounds.size.height;
    BOOL dark = [GMTheme dark];

    // Nền: màn chụp một lần (1/4 cỡ) rồi làm mờ, phóng lên — không làm mờ theo khung hình
    UIImage *blurred = [GMContextMenu blurredSnapshot:_host];
    if (blurred) {
        _blur = [[UIImageView alloc] initWithFrame:bounds];
        _blur.image = blurred;
        _blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_blur];
    }
    UIButton *bg = [UIButton buttonWithType:UIButtonTypeCustom];
    bg.frame = bounds;
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    bg.accessibilityLabel = @"Đóng menu";
    [bg addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:bg];
    _dim = bg;
    CGFloat dimA = _blur ? (dark ? 0.4 : 0.12) : (dark ? 0.55 : 0.35);
    bg.backgroundColor = [UIColor colorWithWhite:0 alpha:dimA];

    // Tin được nhấc lên: ảnh chụp sắc nét của bong bóng
    _from = [_source convertRect:_source.bounds toView:_host];
    _liftBox = [[UIView alloc] initWithFrame:_from];
    _liftBox.clipsToBounds = YES;
    _lift = [[UIImageView alloc] initWithImage:GMSnapBubble(_source)];
    _lift.frame = CGRectMake(0, 0, _from.size.width, _from.size.height);
    [_liftBox addSubview:_lift];
    [self addSubview:_liftBox];

    // Hàng cảm xúc
    CGFloat reactH = 0;
    if (_emojis.count) {
        NSArray *list = _emojis.count > 6 ? [_emojis subarrayWithRange:NSMakeRange(0, 6)] : _emojis;
        CGFloat rw = list.count * 40 + (_more ? 34 : 0) + 12;
        _reacts = [[UIView alloc] initWithFrame:CGRectMake(0, 0, rw, kReactH)];
        UIImageView *g = [[UIImageView alloc] initWithFrame:CGRectInset(_reacts.bounds, -1, 0)];
        g.image = [GMTheme glassImage:kReactH];
        g.frame = CGRectMake(-1, -0.5, rw + 2, kReactH + 3);
        [_reacts addSubview:g];
        CGFloat x = 6;
        for (NSUInteger i = 0; i < list.count; i++) {
            NSString *e = [list objectAtIndex:i];
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.frame = CGRectMake(x, 5, 40, 38);
            b.tag = 500 + i;
            [b setTitle:e forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont systemFontOfSize:25];
            b.accessibilityLabel = [@"Thả " stringByAppendingString:e];
            if ([e isEqual:chosen]) {
                b.backgroundColor = dark ? [UIColor colorWithWhite:1 alpha:0.16] : [UIColor colorWithWhite:0 alpha:0.08];
                b.layer.cornerRadius = 19;
            }
            [b addTarget:self action:@selector(emojiTapped:) forControlEvents:UIControlEventTouchUpInside];
            [_reacts addSubview:b];
            x += 40;
        }
        if (_more) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.frame = CGRectMake(x, 5, 34, 38);
            [b setImage:[GMTheme icon:@"down" color:[GMTheme secondaryText]] forState:UIControlStateNormal];
            b.accessibilityLabel = @"Thêm cảm xúc";
            [b addTarget:self action:@selector(moreTapped) forControlEvents:UIControlEventTouchUpInside];
            [_reacts addSubview:b];
        }
        [self addSubview:_reacts];
        reactH = kReactH + kGap;
    }

    // Menu kính: các nhóm cách nhau một dải mờ, «Xoá» đỏ
    CGFloat menuW = MIN(240, W - 2 * kEdge);
    NSInteger groups = 0;
    for (NSUInteger i = 0; i < _items.count; i++) {
        if (i > 0 && ((GMMenuItem *)[_items objectAtIndex:i]).startsGroup) groups++;
    }
    CGFloat menuH = _items.count * kRowH + groups * kGroupGap;
    _menu = [[UIView alloc] initWithFrame:CGRectMake(0, 0, menuW, menuH)];
    UIImageView *panel = [[UIImageView alloc] initWithFrame:CGRectMake(-1, -0.5, menuW + 2, menuH + 3)];
    panel.image = [GMTheme glassPanel];
    [_menu addSubview:panel];
    UIView *rows = [[UIView alloc] initWithFrame:_menu.bounds];
    rows.clipsToBounds = YES;
    rows.layer.cornerRadius = 14;
    [_menu addSubview:rows];
    CGFloat y = 0, px = 1 / [UIScreen mainScreen].scale;
    UIImage *hl = nil;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(1, 1), NO, 0);
    [(dark ? [UIColor colorWithWhite:1 alpha:0.12] : [UIColor colorWithWhite:0 alpha:0.08]) setFill];
    UIRectFill(CGRectMake(0, 0, 1, 1));
    hl = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    for (NSUInteger i = 0; i < _items.count; i++) {
        GMMenuItem *it = [_items objectAtIndex:i];
        if (i > 0 && it.startsGroup) {
            UIView *gap = [[UIView alloc] initWithFrame:CGRectMake(0, y, menuW, kGroupGap)];
            gap.backgroundColor = dark ? [UIColor colorWithWhite:0 alpha:0.3] : [UIColor colorWithWhite:0 alpha:0.06];
            [rows addSubview:gap];
            y += kGroupGap;
        } else if (i > 0) {
            UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, y - px, menuW, px)];
            line.backgroundColor = [GMTheme separator];
            [rows addSubview:line];
        }
        UIColor *c = it.destructive ? (dark ? [UIColor colorWithRed:1 green:0.35 blue:0.37 alpha:1]
                                            : [UIColor colorWithRed:0.84 green:0 blue:0.08 alpha:1])
                                    : [GMTheme text];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(0, y, menuW, kRowH);
        b.tag = 600 + i;
        [b setBackgroundImage:hl forState:UIControlStateHighlighted];
        [b setTitle:it.title forState:UIControlStateNormal];
        [b setTitleColor:c forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:16];
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        b.titleEdgeInsets = UIEdgeInsetsMake(0, 16, 0, 44);
        if (it.icon) {
            UIImageView *ic = [[UIImageView alloc] initWithImage:[GMTheme icon:it.icon color:c]];
            ic.frame = CGRectMake(menuW - 14 - 26, (kRowH - 26) / 2, 26, 26);
            [b addSubview:ic];
        }
        [b addTarget:self action:@selector(itemTapped:) forControlEvents:UIControlEventTouchUpInside];
        [rows addSubview:b];
        y += kRowH;
    }
    [self addSubview:_menu];

    // Xếp: giữ tin ở chỗ cũ nếu vừa, không thì dời cả cụm cho lọt màn; tin quá cao thì chỉ hiện phần đầu
    CGFloat top = kEdge, bottom = H - kEdge;
    CGFloat liftH = MIN(_from.size.height, MAX(60, bottom - top - reactH - kGap - menuH));
    CGFloat total = reactH + liftH + kGap + menuH;
    CGFloat y0 = MAX(top, MIN(_from.origin.y - reactH, bottom - total));
    CGRect liftTo = CGRectMake(_from.origin.x, y0 + reactH, _from.size.width, liftH);
    CGFloat (^alignX)(CGFloat) = ^CGFloat(CGFloat w) {
        CGFloat x = outgoing ? CGRectGetMaxX(_from) - w : _from.origin.x;
        return MAX(kEdge, MIN(x, W - kEdge - w));
    };
    if (_reacts) _reacts.frame = CGRectMake(alignX(_reacts.bounds.size.width), y0, _reacts.bounds.size.width, kReactH);
    _menu.frame = CGRectMake(alignX(menuW), CGRectGetMaxY(liftTo) + kGap, menuW, menuH);
    _liftTo = liftTo;
}

- (void)animateIn {
    CGRect liftTo = _liftTo;
    _blur.alpha = 0;
    _dim.alpha = 0;
    _menu.alpha = _reacts.alpha = 0;
    _menu.transform = _reacts.transform = CGAffineTransformMakeScale(0.85, 0.85);
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        _blur.alpha = 1;
        _dim.alpha = 1;
        _liftBox.frame = liftTo;
        _menu.alpha = _reacts.alpha = 1;
        _menu.transform = _reacts.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)closeThen:(void (^)(void))then {
    if (_closing) return;
    _closing = YES;
    [UIView animateWithDuration:0.16 animations:^{
        self.alpha = 0;
    } completion:^(BOOL finished) {
        [self removeFromSuperview];
        if (then) then();
    }];
}

- (void)dismiss {
    [self closeThen:nil];
}

- (void)itemTapped:(UIButton *)b {
    NSInteger i = b.tag - 600;
    if (i < 0 || i >= (NSInteger)_items.count) return;
    void (^a)(void) = ((GMMenuItem *)[_items objectAtIndex:i]).action;
    [self closeThen:a];
}

- (void)emojiTapped:(UIButton *)b {
    NSInteger i = b.tag - 500;
    if (i < 0 || i >= (NSInteger)_emojis.count) return;
    NSString *e = [_emojis objectAtIndex:i];
    void (^r)(NSString *) = _react;
    [self closeThen:^{
        if (r) r(e);
    }];
}

- (void)moreTapped {
    [self closeThen:_more];
}

- (void)debugTap:(NSInteger)i {
    UIButton *b = (UIButton *)[_menu viewWithTag:600 + i];
    if (b) [self itemTapped:b];
}

@end
