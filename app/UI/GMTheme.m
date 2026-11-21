#import "GMTheme.h"
#import "GMLog.h"
#import "GMCompat.h"
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>

id GMVal(NSDictionary *d, NSString *key) {
    if (![d isKindOfClass:[NSDictionary class]]) return nil;
    id v = [d objectForKey:key];
    return v == [NSNull null] ? nil : v;
}

static UIColor *RGB(int hex) {
    return [UIColor colorWithRed:((hex >> 16) & 255) / 255.0 green:((hex >> 8) & 255) / 255.0 blue:(hex & 255) / 255.0 alpha:1];
}

/// Màu RGB có độ trong (dải màu CoreGraphics cần mọi màu cùng hệ RGB — không dùng colorWithWhite:).
static UIColor *RGBA(int hex, CGFloat a) {
    return [UIColor colorWithRed:((hex >> 16) & 255) / 255.0 green:((hex >> 8) & 255) / 255.0 blue:(hex & 255) / 255.0 alpha:a];
}

/// Chế độ tối đang dùng (chốt lúc `apply` — đổi chế độ thì dựng lại giao diện).
static BOOL gDark;

#pragma mark - Vẽ

static UIImage *GMDraw(CGSize size, void (^draw)(CGContextRef ctx)) {
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    draw(UIGraphicsGetCurrentContext());
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

/// Dải màu dọc phủ dải ngang `r` (các màu RGB; `locs` NULL = chia đều).
static void GMVGradient(CGContextRef ctx, CGRect r, NSArray *colors, const CGFloat *locs) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    NSMutableArray *cg = [NSMutableArray arrayWithCapacity:colors.count];
    for (UIColor *c in colors) [cg addObject:(__bridge id)c.CGColor];
    CGGradientRef g = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)cg, locs);
    CGContextDrawLinearGradient(ctx, g, CGPointMake(0, CGRectGetMinY(r)), CGPointMake(0, CGRectGetMaxY(r)), 0);
    CGGradientRelease(g);
    CGColorSpaceRelease(cs);
}

/// Dải màu dọc chỉ trong đường `p`.
static void GMFillGradient(CGContextRef ctx, UIBezierPath *p, CGRect r, NSArray *colors, const CGFloat *locs) {
    CGContextSaveGState(ctx);
    [p addClip];
    GMVGradient(ctx, r, colors, locs);
    CGContextRestoreGState(ctx);
}

/// Vùng màu loang tròn: đậm `a` ở tâm, nhạt dần tới 0 ở bán kính `rad`.
static void GMBlob(CGContextRef ctx, CGPoint c, CGFloat rad, int hex, CGFloat a) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    NSArray *cols = @[(__bridge id)RGBA(hex, a).CGColor, (__bridge id)RGBA(hex, a * 0.45).CGColor, (__bridge id)RGBA(hex, 0).CGColor];
    CGFloat locs[] = {0, 0.5, 1};
    CGGradientRef g = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)cols, locs);
    CGContextDrawRadialGradient(ctx, g, c, 0, c, rad, 0);
    CGGradientRelease(g);
    CGColorSpaceRelease(cs);
}

static UIImage *GMSolid(UIColor *c, UIColor *line) {
    UIImage *img = GMDraw(CGSizeMake(1, 3), ^(CGContextRef ctx) {
        [c setFill];
        CGContextFillRect(ctx, CGRectMake(0, 0, 1, 3));
        if (line) {
            [line setFill];
            CGContextFillRect(ctx, CGRectMake(0, 2.5, 1, 0.5));
        }
    });
    return [img resizableImageWithCapInsets:UIEdgeInsetsMake(1, 0, 1, 0)];
}

/// Sọc dọc của bảng nhóm iOS 6 (bán trong — màu loang của hình nền ánh qua).
static UIColor *GMStripes(void) {
    static UIColor *cache[2];
    int i = gDark ? 1 : 0;
    if (cache[i]) return cache[i];
    UIColor *a = gDark ? RGBA(0x111A24, 0.8) : RGBA(0xC5CCD3, 0.74);
    UIColor *b = gDark ? RGBA(0x16202B, 0.8) : RGBA(0xCED5DB, 0.74);
    UIImage *t = GMDraw(CGSizeMake(7, 1), ^(CGContextRef ctx) {
        [a setFill];
        CGContextFillRect(ctx, CGRectMake(0, 0, 3, 1));
        [b setFill];
        CGContextFillRect(ctx, CGRectMake(3, 0, 4, 1));
    });
    cache[i] = [UIColor colorWithPatternImage:t];
    return cache[i];
}

#pragma mark - Kính lỏng (D37)

/// Màu nền trang: trơn (danh sách) hay nhóm (Cài đặt…).
static UIColor *GMPage(BOOL grouped) {
    if (gDark) return RGB(0x000000);
    return grouped ? RGB(0xF2F2F7) : RGB(0xFFFFFF);
}

/// Vẽ một viên kính vào khung `g`: bóng đổ mềm phía dưới (không lọt vào trong), mặt bán trong, vệt sáng nửa trên, viền sáng
/// mép trên, viền mảnh 0,5 pt. iOS 5 / 6 không làm mờ được thời gian thực: kính nằm trên nền tĩnh (trang trơn / hình nền), mặt bán
/// trong để lộ màu nền như kính mờ thật.
static void GMGlassDraw(CGContextRef ctx, CGRect g, CGFloat r, BOOL pressed, BOOL shadow) {
    BOOL dark = gDark;
    UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:g cornerRadius:r];
    if (shadow) {
        CGContextSaveGState(ctx);
        CGContextSetShadowWithColor(ctx, CGSizeMake(0, 1), 3, (dark ? RGBA(0x000000, 0.6) : RGBA(0x000000, 0.16)).CGColor);
        [[UIColor blackColor] setFill];
        [p fill];
        CGContextRestoreGState(ctx);
        CGContextSaveGState(ctx);
        CGContextSetBlendMode(ctx, kCGBlendModeClear);
        [p fill];
        CGContextRestoreGState(ctx);
    }
    UIColor *fill = dark ? (pressed ? RGBA(0x4A4A50, 0.9) : RGBA(0x2C2C30, 0.78))
                         : (pressed ? RGBA(0xDADADF, 0.92) : RGBA(0xFFFFFF, 0.8));
    [fill setFill];
    [p fill];
    CGContextSaveGState(ctx);
    [p addClip];
    GMVGradient(ctx, CGRectMake(g.origin.x, g.origin.y, g.size.width, g.size.height * 0.55),
                @[RGBA(0xFFFFFF, dark ? 0.1 : 0.55), RGBA(0xFFFFFF, 0)], NULL);
    // Viền sáng mép trên (ánh sáng chiếu từ trên)
    UIBezierPath *in = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(g, 0.5, 0.5) cornerRadius:MAX(0, r - 0.5)];
    in.lineWidth = 1;
    CGContextClipToRect(ctx, CGRectMake(g.origin.x, g.origin.y, g.size.width, MIN(g.size.height * 0.45, r)));
    [(dark ? RGBA(0xFFFFFF, 0.2) : RGBA(0xFFFFFF, 0.95)) setStroke];
    [in stroke];
    CGContextRestoreGState(ctx);
    UIBezierPath *edge = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(g, 0.25, 0.25) cornerRadius:MAX(0, r - 0.25)];
    edge.lineWidth = 0.5;
    [(dark ? RGBA(0xFFFFFF, 0.14) : RGBA(0x000000, 0.07)) setStroke];
    [edge stroke];
}

/// Ảnh viên kính co giãn: cao `h` (gồm lề: trên `mt`, dưới `mb` cho bóng, hai bên `mx`), bán kính `r`; `chevron` vẽ mũi tên quay
/// lại ở đầu trái (nút quay lại). Mặt kính cao h - mt - mb (≥ 2r — giãn được theo chiều dọc khi cao hơn).
static UIImage *GMGlassImage(CGFloat h, CGFloat r, CGFloat mx, CGFloat mt, CGFloat mb, BOOL pressed, BOOL chevron) {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%d|%.1f|%.1f|%.1f|%.1f|%.1f|%d|%d", gDark, h, r, mx, mt, mb, pressed, chevron];
    UIImage *img = [cache objectForKey:key];
    if (img) return img;
    const CGFloat lead = chevron ? 22 : 0, w = 2 * (mx + r) + lead + 1;
    BOOL dark = gDark;
    img = GMDraw(CGSizeMake(w, h), ^(CGContextRef ctx) {
        CGRect g = CGRectMake(mx, mt, w - 2 * mx, h - mt - mb);
        GMGlassDraw(ctx, g, r, pressed, YES);
        if (chevron) {
            CGFloat cy = CGRectGetMidY(g), cx = mx + 10;
            CGContextSetLineWidth(ctx, 2.2);
            CGContextSetLineCap(ctx, kCGLineCapRound);
            CGContextSetLineJoin(ctx, kCGLineJoinRound);
            [(dark ? RGB(0xFFFFFF) : RGB(0x000000)) setStroke];
            CGContextMoveToPoint(ctx, cx + 5.5, cy - 7);
            CGContextAddLineToPoint(ctx, cx - 1.5, cy);
            CGContextAddLineToPoint(ctx, cx + 5.5, cy + 7);
            CGContextStrokePath(ctx);
        }
    });
    CGFloat capV = MIN(r, floor((h - mt - mb - 1) / 2));
    img = [img resizableImageWithCapInsets:UIEdgeInsetsMake(mt + capV, mx + r + lead, mb + capV, mx + r)];
    [cache setObject:img forKey:key];
    return img;
}

/// Dải mờ dần (thay «scroll edge effect» của iOS 26): màu `c` đặc ở mép `fromTop` (trên / dưới), trong suốt ở mép kia, cao `h`.
static UIImage *GMFade(UIColor *c, CGFloat h, BOOL fromTop) {
    UIImage *img = GMDraw(CGSizeMake(1, h), ^(CGContextRef ctx) {
        NSMutableArray *cols = [NSMutableArray array];
        CGFloat locs[5];
        for (int i = 0; i < 5; i++) {
            CGFloat t = i / 4.0;
            CGFloat a = (1 - t) * (1 - t);  // tan nhanh ở đầu dải
            [cols addObject:[c colorWithAlphaComponent:a]];
            locs[i] = t;
        }
        if (!fromTop) {
            cols = [[[cols reverseObjectEnumerator] allObjects] mutableCopy];
        }
        GMVGradient(ctx, CGRectMake(0, 0, 1, h), cols, locs);
    });
    return [img resizableImageWithCapInsets:UIEdgeInsetsZero];
}

/// Nền thanh dưới: viên kính nổi cách mép 8 pt, cao 44 trong thanh 49 (hai bên trong suốt — lộ màu trang).
static UIImage *GMTabBg(void) {
    const CGFloat mx = 8, mt = 2, r = 22, h = 49;
    return GMGlassImage(h, r, mx, mt, h - mt - 2 * r - 1, NO, NO);
}

/// Viên sáng sau mục đang chọn của thanh dưới (lồng trong viên kính, cách 3 pt).
static UIImage *GMTabSelection(void) {
    const CGFloat w = 84, h = 49;
    BOOL dark = gDark;
    return GMDraw(CGSizeMake(w, h), ^(CGContextRef ctx) {
        [(dark ? RGBA(0xFFFFFF, 0.14) : RGBA(0x000000, 0.075)) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 5, w, 39) cornerRadius:19.5] fill];
    });
}

#pragma mark - Hình nền

@implementation GMWallpaperView {
    UIImageView *_img;
    UIView *_stripes;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.clipsToBounds = YES;
        self.userInteractionEnabled = NO;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.backgroundColor = [GMTheme background];
        _img = [[UIImageView alloc] initWithImage:[GMTheme wallpaper]];
        [self addSubview:_img];
    }
    return self;
}

- (void)setStriped:(BOOL)striped {
    _striped = striped;
    if (striped && !_stripes) {
        _stripes = [[UIView alloc] initWithFrame:self.bounds];
        _stripes.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _stripes.backgroundColor = GMStripes();
        [self addSubview:_stripes];
    }
    _stripes.hidden = !striped;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self setNeedsLayout];
}

/// Canh ảnh theo gốc của màn: vị trí so với view của màn chứa nó (không đổi khi màn đang trượt vào) + chiều cao thanh trên.
- (void)layoutSubviews {
    [super layoutSubviews];
    UIView *v = self;
    UIViewController *vc = nil;
    while (v) {
        id r = v.nextResponder;
        if ([r isKindOfClass:[UIViewController class]]) {
            vc = r;
            break;
        }
        v = v.superview;
    }
    CGPoint o = CGPointZero;
    if (vc && v != self) {
        // Trong hệ toạ độ của view màn (đã xoay theo chiều máy); bảng cuộn: trừ gốc bounds (= vị trí cuộn)
        CGPoint p = [self convertPoint:CGPointZero toView:v];
        o = CGPointMake(p.x - v.bounds.origin.x, p.y - v.bounds.origin.y);
    }
    UINavigationController *nav = vc.navigationController;
    if (nav && !nav.navigationBarHidden && ![vc isKindOfClass:[UINavigationController class]]) {
        o.y += CGRectGetMaxY(nav.navigationBar.frame);
    }
    CGSize s = _img.image.size;
    _img.frame = CGRectMake(-o.x, -o.y, s.width, s.height);
}

@end

@interface UIViewController (GMBack)
- (void)gmBack;
@end

@implementation UIViewController (GMBack)
/// Nút quay lại viên kính (GMTheme styleBarsFor:).
- (void)gmBack {
    [self.navigationController popViewControllerAnimated:YES];
}
@end

@implementation GMTheme

+ (NSInteger)mode {
    return [[NSUserDefaults standardUserDefaults] integerForKey:@"theme.mode"];
}

+ (void)setMode:(NSInteger)mode {
    [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:@"theme.mode"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (BOOL)wantsDark {
    NSInteger m = [self mode];
    if (m == GMThemeDark) return YES;
    if (m != GMThemeAuto) return NO;
    NSInteger h = [[NSCalendar currentCalendar] components:NSHourCalendarUnit fromDate:[NSDate date]].hour;
    return h >= 19 || h < 6;
}

+ (BOOL)dark {
    return gDark;
}

+ (NSString *)modeText:(NSInteger)m {
    return m == GMThemeDark ? @"Tối" : m == GMThemeAuto ? @"Tự động" : @"Sáng";
}

// Bảng màu D37 (theo bản mẫu anh duyệt): trang trơn trắng / đen, chữ phụ đủ tương phản 4,5:1.
+ (UIColor *)accent { return gDark ? RGB(0x4DA3FF) : RGB(0x0B6BDB); }
+ (UIColor *)background { return GMPage(NO); }
+ (UIColor *)groupedBackground { return GMPage(YES); }
+ (UIColor *)chatBackground { return gDark ? RGB(0x0D1420) : RGB(0xD9E6EC); }
+ (UIColor *)secondaryText { return gDark ? RGB(0x9A9AA1) : RGB(0x6C6C70); }
+ (UIColor *)separator { return gDark ? RGB(0x38383A) : RGB(0xD1D1D6); }
+ (UIColor *)checkColor { return [self accent]; }
+ (UIColor *)badgeColor { return gDark ? RGB(0x2F6FD6) : RGB(0x0B6BDB); }
+ (UIColor *)mutedBadge { return gDark ? RGB(0x5C5C62) : RGB(0x77777D); }
+ (UIColor *)text { return gDark ? RGB(0xFFFFFF) : RGB(0x000000); }
+ (UIColor *)cellBackground { return gDark ? RGB(0x1C1C1E) : RGB(0xFFFFFF); }
+ (UIColor *)barBackground { return gDark ? RGB(0x1C1C1E) : RGB(0xF9F9F9); }
+ (UIColor *)fieldBackground { return gDark ? RGB(0x1C1C1E) : RGB(0xEEEEEF); }
+ (UIColor *)placeholderFill { return gDark ? RGB(0x2C2C2E) : RGB(0xE5E5EA); }
+ (UIColor *)pillBackground { return gDark ? RGBA(0x26262A, 0.72) : RGBA(0xFFFFFF, 0.72); }
+ (UIColor *)pillText { return gDark ? RGB(0xFFFFFF) : RGB(0x000000); }
+ (UIColor *)selectedCell { return gDark ? RGB(0x2C2C2E) : RGB(0xE5E5EA); }
+ (UIKeyboardAppearance)keyboard { return gDark ? UIKeyboardAppearanceAlert : UIKeyboardAppearanceDefault; }
// Ô bảng: không còn kính trên hình nền (D37) — mặt ô trơn theo trang
+ (UIColor *)glassFill { return gDark ? RGB(0x000000) : RGB(0xFFFFFF); }
+ (UIColor *)glassGrouped { return [self cellBackground]; }
+ (UIColor *)glassLine { return [self separator]; }
+ (UIColor *)barText { return [self text]; }
+ (UIColor *)navTitle { return [self text]; }
+ (UIColor *)navTitleShadow { return [UIColor clearColor]; }
+ (CGSize)navShadowOffset { return CGSizeZero; }
+ (UIColor *)bubbleTime:(BOOL)outgoing { return outgoing ? (gDark ? RGB(0xC9DDF5) : RGB(0x3D7B3D)) : [self secondaryText]; }

+ (UIColor *)colorFor:(NSString *)peer {
    static int palette[] = {0xE5484D, 0xF0624D, 0x8E5BE8, 0x34A853, 0x1FA597, 0x3A8DDE, 0xE0538F};
    long long v = llabs(peer.longLongValue);
    return RGB(palette[v % 7]);
}

#pragma mark - Ảnh tự vẽ

/// Hình nền: nền xanh xám, bốn vùng màu loang (cam / xanh / lục / tím nhạt; tối: lam / tím / lục lam), vân chéo mảnh.
+ (UIImage *)wallpaper {
    static UIImage *cache[2];
    int i = gDark ? 1 : 0;
    if (cache[i]) return cache[i];
    CGSize scr = [UIScreen mainScreen].bounds.size;
    CGFloat S = MAX(scr.width, scr.height), W = MIN(scr.width, scr.height), scale = [UIScreen mainScreen].scale;
    BOOL dark = gDark;
    // Vẽ mất ~0,4–0,6 s trên iPad (A4 / A5) → lưu JPEG, lần sau chỉ đọc (đổi cách vẽ thì tăng số «v»)
    NSString *dir = [GMDataDir() stringByAppendingPathComponent:@"ui"];
    NSString *path = [dir stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"wallpaper-v2-%@-%.0f-%.0fx.jpg", dark ? @"dark" : @"light", S, scale]];
    UIImage *saved = [UIImage imageWithData:[NSData dataWithContentsOfFile:path]];
    if (saved.CGImage) {
        cache[i] = [UIImage imageWithCGImage:saved.CGImage scale:scale orientation:UIImageOrientationUp];
        return cache[i];
    }
    long long t0 = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
    cache[i] = GMDraw(CGSizeMake(S, S), ^(CGContextRef ctx) {
        // D37: bốn vùng màu loang mềm (sáng: lục bạc hà / lam / tím nhạt / ngọc; tối: lục lam / chàm / tím / ngọc đậm), không vân
        [(dark ? RGB(0x0D1420) : RGB(0xD9E6EC)) setFill];
        CGContextFillRect(ctx, CGRectMake(0, 0, S, S));
        CGFloat R = 0.55 * S;
        if (dark) {
            GMBlob(ctx, CGPointMake(0.08 * W, 0.12 * S), R, 0x1B4A4A, 0.85);
            GMBlob(ctx, CGPointMake(0.96 * W, 0.32 * S), R, 0x1F2C60, 0.85);
            GMBlob(ctx, CGPointMake(0.22 * W, 0.92 * S), R, 0x382456, 0.85);
            GMBlob(ctx, CGPointMake(0.92 * S, 0.88 * S), R, 0x124440, 0.8);
        } else {
            GMBlob(ctx, CGPointMake(0.08 * W, 0.12 * S), R, 0xBFE3C9, 0.95);
            GMBlob(ctx, CGPointMake(0.96 * W, 0.32 * S), R, 0xBBD3F4, 0.95);
            GMBlob(ctx, CGPointMake(0.22 * W, 0.92 * S), R, 0xDCCDF2, 0.95);
            GMBlob(ctx, CGPointMake(0.92 * S, 0.88 * S), R, 0xC3EBDF, 0.9);
        }
    });
    GMLog(@"hình nền %.0fx%.0f (%@): vẽ %lld ms", S, S, dark ? @"tối" : @"sáng", (long long)([[NSDate date] timeIntervalSince1970] * 1000) - t0);
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    [UIImageJPEGRepresentation(cache[i], 0.92) writeToFile:path atomically:YES];
    return cache[i];
}

static UIImage *GMCircleIcon(UIColor *color, NSString *ini, CGFloat size);

+ (UIImage *)avatarFor:(NSString *)peer name:(NSString *)name size:(CGFloat)size {
    static NSCache *cache;
    if (!cache) cache = [[NSCache alloc] init];
    NSString *key = [NSString stringWithFormat:@"%@|%@|%.0f", peer, name, size];
    UIImage *img = [cache objectForKey:key];
    if (img) return img;
    if ([name isEqual:@"★"]) {
        // Tin nhắn đã lưu (chỗ gọi truyền «★»): dấu trang trắng trên tròn xanh như Telegram
        img = GMDraw(CGSizeMake(size, size), ^(CGContextRef ctx) {
            UIBezierPath *circle = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, size, size)];
            GMFillGradient(ctx, circle, CGRectMake(0, 0, size, size), @[RGB(0x5AB0FF), RGB(0x2A7BE4)], NULL);
            CGFloat u = size / 54.0;
            [[UIColor whiteColor] setFill];
            CGContextMoveToPoint(ctx, 19 * u, 15 * u);
            CGContextAddLineToPoint(ctx, 35 * u, 15 * u);
            CGContextAddLineToPoint(ctx, 35 * u, 40 * u);
            CGContextAddLineToPoint(ctx, 27 * u, 34 * u);
            CGContextAddLineToPoint(ctx, 19 * u, 40 * u);
            CGContextClosePath(ctx);
            CGContextFillPath(ctx);
        });
        [cache setObject:img forKey:key];
        return img;
    }
    // Chữ cái đầu của hai từ đầu (bỏ biểu tượng / dấu)
    NSMutableString *ini = [NSMutableString string];
    for (NSString *w in [name componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]) {
        if (!w.length) continue;
        NSRange r = [w rangeOfComposedCharacterSequenceAtIndex:0];
        NSString *c = [w substringWithRange:r];
        if ([c rangeOfCharacterFromSet:[NSCharacterSet alphanumericCharacterSet]].location == NSNotFound) continue;
        [ini appendString:c.uppercaseString];
        if (ini.length >= 2) break;
    }
    if (!ini.length && name.length) [ini appendString:[name substringWithRange:[name rangeOfComposedCharacterSequenceAtIndex:0]]];
    img = GMCircleIcon([self colorFor:peer], ini, size);
    [cache setObject:img forKey:key];
    return img;
}

/// Vòng tròn màu kiểu kính (bóng nửa trên, tối nhẹ phía đáy) + chữ trắng ở giữa — ảnh chữ cái, biểu tượng chủ đề.
static UIImage *GMCircleIcon(UIColor *color, NSString *ini, CGFloat size) {
    return GMDraw(CGSizeMake(size, size), ^(CGContextRef ctx) {
        // D37: tròn phẳng, dải màu dọc nhạt dần lên trên (như ảnh chữ cái của Telegram), chữ trắng không bóng
        UIBezierPath *circle = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, size, size)];
        CGFloat r = 0, g = 0, b = 0, a = 1;
        if (![color getRed:&r green:&g blue:&b alpha:&a]) [color getWhite:&r alpha:&a], g = b = r;
        UIColor *top = [UIColor colorWithRed:r + (1 - r) * 0.3 green:g + (1 - g) * 0.3 blue:b + (1 - b) * 0.3 alpha:1];
        GMFillGradient(ctx, circle, CGRectMake(0, 0, size, size), @[top, color], NULL);
        UIFont *f = [UIFont boldSystemFontOfSize:floor(size * 0.38)];
        CGSize ts = [ini sizeWithFont:f];
        CGPoint at = CGPointMake(floor((size - ts.width) / 2), floor((size - ts.height) / 2));
        [[UIColor whiteColor] set];
        [ini drawAtPoint:at withFont:f];
    });
}

+ (UIImage *)topicIcon:(NSString *)title color:(NSInteger)rgb size:(CGFloat)size {
    static NSCache *cache;
    if (!cache) cache = [[NSCache alloc] init];
    NSString *key = [NSString stringWithFormat:@"%@|%ld|%.0f", title, (long)rgb, size];
    UIImage *img = [cache objectForKey:key];
    if (img) return img;
    // Chữ cái đầu của tên (bỏ biểu tượng / dấu ở đầu); không có thì «#»
    NSString *ini = @"#";
    for (NSUInteger i = 0; i < title.length;) {
        NSRange r = [title rangeOfComposedCharacterSequenceAtIndex:i];
        NSString *c = [title substringWithRange:r];
        if ([c rangeOfCharacterFromSet:[NSCharacterSet alphanumericCharacterSet]].location != NSNotFound) {
            ini = c.uppercaseString;
            break;
        }
        i = NSMaxRange(r);
    }
    img = GMCircleIcon(rgb > 0 ? RGB((int)rgb) : RGB(0x8E9AAB), ini, size);
    [cache setObject:img forKey:key];
    return img;
}

+ (CGFloat)tailWidth {
    return 6;
}

/// Bong bóng phẳng (D37): bo góc 16, đuôi cong ở góc dưới phía người gửi, một màu (vào: trắng / xám đậm; ra: lục nhạt / lam đậm),
/// bóng mảnh 1 pt phía dưới. Ảnh 2 × bán kính + đuôi, co giãn phần giữa.
+ (UIImage *)bubbleOut:(BOOL)outgoing tail:(BOOL)tail {
    static UIImage *cache[8];
    int idx = (gDark ? 4 : 0) + (outgoing ? 2 : 0) + (tail ? 1 : 0);
    if (cache[idx]) return cache[idx];
    const CGFloat r = 16, t = [self tailWidth], w = 2 * r + t + 2, h = 2 * r + 3;
    UIColor *fill = gDark ? (outgoing ? RGB(0x2B5A91) : RGB(0x232327)) : (outgoing ? RGB(0xDDF6C8) : RGB(0xFFFFFF));
    UIColor *shade = gDark ? RGBA(0x000000, 0.35) : RGBA(0x000000, 0.1);
    UIImage *img = GMDraw(CGSizeMake(w, h), ^(CGContextRef ctx) {
        // Vẽ cho tin ra (đuôi bên phải); tin vào thì lật ngang
        if (!outgoing) {
            CGContextTranslateCTM(ctx, w, 0);
            CGContextScaleCTM(ctx, -1, 1);
        }
        CGRect b = CGRectMake(0, 0, w - t, h - 1);
        CGMutablePathRef p = CGPathCreateMutable();
        CGFloat minX = CGRectGetMinX(b), maxX = CGRectGetMaxX(b), minY = CGRectGetMinY(b), maxY = CGRectGetMaxY(b);
        CGPathMoveToPoint(p, NULL, minX + r, minY);
        CGPathAddArcToPoint(p, NULL, maxX, minY, maxX, minY + r, r);
        if (tail) {
            CGPathAddLineToPoint(p, NULL, maxX, maxY - 8);
            CGPathAddQuadCurveToPoint(p, NULL, maxX + 1, maxY - 1, maxX + t, maxY);
            CGPathAddQuadCurveToPoint(p, NULL, maxX - 4, maxY + 0.5, maxX - 9, maxY - 3);
            CGPathAddQuadCurveToPoint(p, NULL, maxX - 12, maxY, maxX - r, maxY);
        } else {
            CGPathAddArcToPoint(p, NULL, maxX, maxY, maxX - r, maxY, r);
        }
        CGPathAddArcToPoint(p, NULL, minX, maxY, minX, maxY - r, r);
        CGPathAddArcToPoint(p, NULL, minX, minY, minX + r, minY, r);
        CGPathCloseSubpath(p);
        // Bóng mảnh: chính hình bong bóng lệch xuống 1 pt
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, 0, 1);
        CGContextAddPath(ctx, p);
        [shade setFill];
        CGContextFillPath(ctx);
        CGContextRestoreGState(ctx);
        CGContextAddPath(ctx, p);
        [fill setFill];
        CGContextFillPath(ctx);
        CGPathRelease(p);
    });
    UIEdgeInsets caps = outgoing ? UIEdgeInsetsMake(r, r, r + 1, r + t + 1) : UIEdgeInsetsMake(r, r + t + 1, r + 1, r);
    cache[idx] = [img resizableImageWithCapInsets:caps];
    return cache[idx];
}

/// Nền thanh phụ (khung trả lời, tin ghim, đang gửi tệp, bảng sticker…): mặt gần đặc theo trang, vạch mảnh mép trên.
+ (UIImage *)glassBar {
    static UIImage *cache[2];
    int i = gDark ? 1 : 0;
    if (cache[i]) return cache[i];
    BOOL dark = gDark;
    UIImage *img = GMDraw(CGSizeMake(1, 8), ^(CGContextRef ctx) {
        [(dark ? RGBA(0x1C1C1E, 0.95) : RGBA(0xF9F9F9, 0.95)) setFill];
        CGContextFillRect(ctx, CGRectMake(0, 0, 1, 8));
        [(dark ? RGBA(0xFFFFFF, 0.12) : RGBA(0x000000, 0.12)) setFill];
        CGContextFillRect(ctx, CGRectMake(0, 0, 1, 0.5));
    });
    cache[i] = [img resizableImageWithCapInsets:UIEdgeInsetsMake(2, 0, 2, 0)];
    return cache[i];
}

/// Ô nhập tin: viên kính (không bóng — khung ô cắt mép), bo tròn 18 (một dòng = viên thuốc), giãn theo số dòng.
+ (UIImage *)fieldImage {
    static UIImage *cache[2];
    int i = gDark ? 1 : 0;
    if (cache[i]) return cache[i];
    const CGFloat r = 18, w = 2 * r + 1, h = 2 * r + 1;
    UIImage *img = GMDraw(CGSizeMake(w, h), ^(CGContextRef ctx) {
        GMGlassDraw(ctx, CGRectMake(0, 0, w, h), r, NO, NO);
    });
    cache[i] = [img resizableImageWithCapInsets:UIEdgeInsetsMake(r, r, r, r)];
    return cache[i];
}

/// Nút chữ xanh phẳng (Đăng nhập, Thêm…): ảnh cao 44, viên giữa cao 32 bo tròn — co giãn theo bề ngang.
+ (UIImage *)sendButtonImage:(BOOL)pressed {
    static UIImage *cache[4];
    int i = (gDark ? 2 : 0) + (pressed ? 1 : 0);
    if (cache[i]) return cache[i];
    UIColor *c = [self accent];
    if (pressed) c = [c colorWithAlphaComponent:0.7];
    const CGFloat m = 3, r = 16, w = 2 * (m + r) + 1, h = 44;
    UIImage *img = GMDraw(CGSizeMake(w, h), ^(CGContextRef ctx) {
        [c setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(m, 6, w - 2 * m, 32) cornerRadius:r] fill];
    });
    cache[i] = [img resizableImageWithCapInsets:UIEdgeInsetsMake(0, m + r, 0, m + r)];
    return cache[i];
}

/// Viên kính tròn đường kính `size` - 4 trong ảnh `size` × `size` (chừa bóng): nút biểu tượng (soạn tin, ghim giấy, mic…).
static UIImage *GMGlassCircle(CGFloat size, BOOL pressed) {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%d|%.0f|%d", gDark, size, pressed];
    UIImage *img = [cache objectForKey:key];
    if (img) return img;
    img = GMDraw(CGSizeMake(size, size), ^(CGContextRef ctx) {
        CGFloat d = size - 4;
        GMGlassDraw(ctx, CGRectMake(2, 1, d, d), d / 2, pressed, YES);
    });
    [cache setObject:img forKey:key];
    return img;
}

+ (UIImage *)glassButton:(CGFloat)size pressed:(BOOL)pressed {
    return GMGlassCircle(size, pressed);
}

+ (UIImage *)glassImage:(CGFloat)h {
    return GMGlassImage(h, floor((h - 3) / 2), 1, 0.5, 2.5, NO, NO);
}

+ (UIImage *)glassPanel {
    return GMGlassImage(34, 14, 1, 0.5, 2.5, NO, NO);
}

+ (UIImage *)glassSheet {
    return GMGlassImage(58, 26, 1, 0.5, 2.5, NO, NO);
}

/// Nút gửi: tròn xanh, mũi tên trắng chỉ lên (như Telegram mới).
+ (UIImage *)sendCircle:(BOOL)pressed {
    static UIImage *cache[4];
    int i = (gDark ? 2 : 0) + (pressed ? 1 : 0);
    if (cache[i]) return cache[i];
    UIColor *c = [self accent];
    if (pressed) c = [c colorWithAlphaComponent:0.7];
    cache[i] = GMDraw(CGSizeMake(40, 40), ^(CGContextRef ctx) {
        [c setFill];
        CGContextFillEllipseInRect(ctx, CGRectMake(3, 3, 34, 34));
        [[UIColor whiteColor] setStroke];
        CGContextSetLineWidth(ctx, 2.6);
        CGContextSetLineCap(ctx, kCGLineCapRound);
        CGContextSetLineJoin(ctx, kCGLineJoinRound);
        CGContextMoveToPoint(ctx, 20, 28);
        CGContextAddLineToPoint(ctx, 20, 12.5);
        CGContextMoveToPoint(ctx, 13.5, 19);
        CGContextAddLineToPoint(ctx, 20, 12.5);
        CGContextAddLineToPoint(ctx, 26.5, 19);
        CGContextStrokePath(ctx);
    });
    return cache[i];
}

/// Nền một hàng danh sách chat (D37: hàng phẳng theo trang — không còn thẻ kính; giữ hàm cho chỗ gọi cũ).
+ (UIImage *)cardRow:(BOOL)first last:(BOOL)last selected:(BOOL)sel {
    static UIImage *cache[4];
    int i = (gDark ? 2 : 0) + (sel ? 1 : 0);
    if (!cache[i]) cache[i] = GMSolid(sel ? [self selectedCell] : GMPage(NO), nil);
    return cache[i];
}

/// Nền số chưa đọc: viên thuốc phẳng xanh (tắt tiếng: xám), cao 22.
+ (UIImage *)badgeImage:(BOOL)muted {
    static UIImage *cache[4];
    int i = (gDark ? 2 : 0) + (muted ? 1 : 0);
    if (cache[i]) return cache[i];
    UIColor *c = muted ? [self mutedBadge] : [self badgeColor];
    const CGFloat h = 22, r = 11, w = 2 * r + 1;
    UIImage *img = GMDraw(CGSizeMake(w, h), ^(CGContextRef ctx) {
        [c setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, w, h) cornerRadius:r] fill];
    });
    cache[i] = [img resizableImageWithCapInsets:UIEdgeInsetsMake(0, r, 0, r)];
    return cache[i];
}

/// Biểu tượng thanh dưới 30 × 30: nét mảnh màu chữ khi không chọn, tô đặc màu chủ đạo khi chọn.
static UIImage *GMTabIcon(NSString *name, BOOL sel) {
    UIColor *c = sel ? [GMTheme accent] : [GMTheme text];
    return GMDraw(CGSizeMake(30, 30), ^(CGContextRef ctx) {
        [c set];
        CGContextSetLineWidth(ctx, 1.8);
        CGContextSetLineCap(ctx, kCGLineCapRound);
        CGContextSetLineJoin(ctx, kCGLineJoinRound);
        if ([name isEqual:@"contacts"]) {
            // Người trong vòng tròn
            CGRect o = CGRectMake(3.5, 3.5, 23, 23);
            if (sel) {
                CGContextFillEllipseInRect(ctx, o);
                CGContextSetBlendMode(ctx, kCGBlendModeClear);
            } else {
                CGContextStrokeEllipseInRect(ctx, o);
            }
            CGContextFillEllipseInRect(ctx, CGRectMake(11, 8, 8, 8));
            CGContextSaveGState(ctx);
            CGContextAddEllipseInRect(ctx, CGRectInset(o, sel ? 0 : 1, sel ? 0 : 1));
            CGContextClip(ctx);
            CGContextFillEllipseInRect(ctx, CGRectMake(6.5, 17.5, 17, 14));
            CGContextRestoreGState(ctx);
        } else if ([name isEqual:@"chats"]) {
            // Bong bóng tròn có đuôi trái dưới
            UIBezierPath *p = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(4, 4, 23, 20.5)];
            [p moveToPoint:CGPointMake(7.5, 19.5)];
            [p addQuadCurveToPoint:CGPointMake(4.5, 26.5) controlPoint:CGPointMake(7, 24.5)];
            [p addQuadCurveToPoint:CGPointMake(12.5, 23.5) controlPoint:CGPointMake(9, 26)];
            if (sel) {
                [p fill];
            } else {
                p.lineWidth = 1.8;
                [p stroke];
            }
        } else {
            // Bánh răng: 8 răng + vành; chọn thì tô đặc chừa lỗ giữa
            CGContextSetLineWidth(ctx, 3.6);
            for (int k = 0; k < 8; k++) {
                CGFloat a = k * M_PI / 4;
                CGContextMoveToPoint(ctx, 15 + 8 * cos(a), 15 + 8 * sin(a));
                CGContextAddLineToPoint(ctx, 15 + 11.5 * cos(a), 15 + 11.5 * sin(a));
            }
            CGContextStrokePath(ctx);
            if (sel) {
                CGContextFillEllipseInRect(ctx, CGRectMake(5.5, 5.5, 19, 19));
                CGContextSetBlendMode(ctx, kCGBlendModeClear);
                CGContextFillEllipseInRect(ctx, CGRectMake(11, 11, 8, 8));
            } else {
                CGContextSetLineWidth(ctx, 1.8);
                CGContextStrokeEllipseInRect(ctx, CGRectMake(6.5, 6.5, 17, 17));
                CGContextStrokeEllipseInRect(ctx, CGRectMake(11.5, 11.5, 7, 7));
            }
        }
    });
}

+ (UITabBarItem *)tabItem:(NSString *)title icon:(NSString *)icon {
    UITabBarItem *it = [[UITabBarItem alloc] initWithTitle:title image:GMTabIcon(icon, NO) tag:0];
    [it setFinishedSelectedImage:GMTabIcon(icon, YES) withFinishedUnselectedImage:GMTabIcon(icon, NO)];
    return it;
}

+ (UIBarButtonItem *)backItem:(NSString *)title target:(id)target action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setBackgroundImage:GMGlassImage(36, 16, 1, 0.5, 2.5, NO, YES) forState:UIControlStateNormal];
    [b setBackgroundImage:GMGlassImage(36, 16, 1, 0.5, 2.5, YES, YES) forState:UIControlStateHighlighted];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[self text] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15];
    b.contentEdgeInsets = UIEdgeInsetsMake(-2, 24, 0, 13);
    CGFloat w = [title sizeWithFont:b.titleLabel.font].width + 37;
    b.frame = CGRectMake(0, 0, w, 36);
    [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return [[UIBarButtonItem alloc] initWithCustomView:b];
}

+ (UIBarButtonItem *)barButtonIcon:(NSString *)icon target:(id)target action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setBackgroundImage:GMGlassCircle(38, NO) forState:UIControlStateNormal];
    [b setBackgroundImage:GMGlassCircle(38, YES) forState:UIControlStateHighlighted];
    [b setImage:[self icon:icon color:[self text]] forState:UIControlStateNormal];
    b.imageEdgeInsets = UIEdgeInsetsMake(-2, 0, 0, 0);  // tâm viên kính cao hơn tâm ảnh 1 pt (chừa bóng)
    b.adjustsImageWhenHighlighted = NO;
    b.frame = CGRectMake(0, 0, 38, 38);
    [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return [[UIBarButtonItem alloc] initWithCustomView:b];
}

+ (UIButton *)barButtonTitle:(NSString *)title target:(id)target action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setBackgroundImage:[self glassImage:38] forState:UIControlStateNormal];
    [b setBackgroundImage:GMGlassImage(38, 17, 1, 0.5, 2.5, YES, NO) forState:UIControlStateHighlighted];
    [b setTitleColor:[self text] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:16];
    b.contentEdgeInsets = UIEdgeInsetsMake(-2, 0, 0, 0);
    [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [self setBarButton:b title:title];
    return b;
}

+ (void)setBarButton:(UIButton *)b title:(NSString *)title {
    [b setTitle:title forState:UIControlStateNormal];
    CGFloat w = MAX(38, ceil([title sizeWithFont:b.titleLabel.font].width) + 32);
    b.frame = CGRectMake(b.frame.origin.x, b.frame.origin.y, w, 38);
}

+ (UIButton *)backButton:(id)target action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setImage:[self icon:@"back" color:[self text]] forState:UIControlStateNormal];
    b.adjustsImageWhenHighlighted = NO;
    b.accessibilityLabel = @"Quay lại";
    UILabel *n = [[UILabel alloc] init];
    n.tag = 77;
    n.font = [UIFont boldSystemFontOfSize:12];
    n.textColor = [UIColor whiteColor];
    n.textAlignment = GMAlignCenter;
    n.backgroundColor = [UIColor clearColor];
    UIImageView *nb = [[UIImageView alloc] initWithImage:[self badgeImage:NO]];
    nb.tag = 78;
    nb.userInteractionEnabled = NO;
    [nb addSubview:n];
    [b addSubview:nb];
    [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [self setBackButton:b count:0];
    return b;
}

+ (void)setBackButton:(UIButton *)b count:(NSInteger)count {
    UIImageView *nb = (UIImageView *)[b viewWithTag:78];
    UILabel *n = (UILabel *)[nb viewWithTag:77];
    if (count <= 0) {
        nb.hidden = YES;
        [b setBackgroundImage:GMGlassCircle(38, NO) forState:UIControlStateNormal];
        [b setBackgroundImage:GMGlassCircle(38, YES) forState:UIControlStateHighlighted];
        b.imageEdgeInsets = UIEdgeInsetsMake(-2, 0, 0, 0);
        b.frame = CGRectMake(b.frame.origin.x, b.frame.origin.y, 38, 38);
        b.accessibilityLabel = @"Quay lại";
        return;
    }
    n.text = count > 999 ? @"999+" : [NSString stringWithFormat:@"%ld", (long)count];
    CGFloat bw = MAX(20, ceil([n.text sizeWithFont:n.font].width) + 12), w = 30 + bw + 10;
    nb.hidden = NO;
    nb.frame = CGRectMake(30, 8.5, bw, 20);
    n.frame = nb.bounds;
    [b setBackgroundImage:[self glassImage:38] forState:UIControlStateNormal];
    [b setBackgroundImage:GMGlassImage(38, 17, 1, 0.5, 2.5, YES, NO) forState:UIControlStateHighlighted];
    b.imageEdgeInsets = UIEdgeInsetsMake(-2, -(w - 26) + 8, 0, 0);  // mũi tên sát trái
    b.frame = CGRectMake(b.frame.origin.x, b.frame.origin.y, w, 38);
    b.accessibilityLabel = [NSString stringWithFormat:@"Quay lại, %@ tin chưa đọc", n.text];
}

#pragma mark - Áp giao diện

/// Bảng / ô của app (nguồn dữ liệu là lớp GM…) — bảng của hệ thống (chọn ảnh, xem tệp) giữ nguyên.
static BOOL GMOurTable(UITableView *tv) {
    id ds = tv.dataSource;
    return ds && [NSStringFromClass([ds class]) hasPrefix:@"GM"];
}

static UITableView *GMTableOf(UIView *v) {
    for (UIView *s = v.superview; s; s = s.superview) {
        if ([s isKindOfClass:[UITableView class]]) return (UITableView *)s;
    }
    return nil;
}

/// Bảng (D37): nền trơn theo trang (bỏ hình nền / sọc nền bảng nhóm của iOS 6); bảng nhóm bỏ vạch kẻ của hệ thống — ô tự vẽ
/// nền bo góc có vạch; bảng thường bỏ vạch của hàng trống. Màn chat (GMTagNoWallpaper): trong suốt để lộ hình nền.
static void GMStyleTable(UITableView *tv) {
    if (!GMOurTable(tv)) return;
    BOOL grouped = tv.style == UITableViewStyleGrouped;
    if (tv.tag == GMTagNoWallpaper) {
        tv.backgroundView = nil;
        tv.backgroundColor = [UIColor clearColor];
        tv.opaque = NO;
    } else {
        if (tv.backgroundView) tv.backgroundView = nil;
        tv.backgroundColor = GMPage(grouped);
    }
    if (grouped) {
        tv.separatorStyle = UITableViewCellSeparatorStyleNone;
    } else if (tv.separatorStyle != UITableViewCellSeparatorStyleNone) {
        tv.separatorColor = [GMTheme separator];
    }
    if (!grouped && !tv.tableFooterView) tv.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
}

/// Chế độ tối: chữ tiêu đề / chú thích nhóm của bảng nhóm (mặc định xám đậm, bóng trắng — chìm trên nền tối).
static void GMRecolorHeader(UIView *v) {
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        if (l.tag == 4243) return;
        l.tag = 4243;
        l.textColor = [GMTheme secondaryText];
        l.shadowColor = [UIColor clearColor];
        return;
    }
    for (UIView *s in v.subviews) GMRecolorHeader(s);
}

static void GMStyleHeaders(UITableView *tv) {
    if (tv.style != UITableViewStyleGrouped || !GMOurTable(tv)) return;
    for (UIView *v in tv.subviews) {
        if ([v isKindOfClass:[UITableViewCell class]] || v == tv.backgroundView || v == tv.tableHeaderView ||
            v == tv.tableFooterView || [v isKindOfClass:[UIImageView class]]) continue;
        GMRecolorHeader(v);
    }
}

/// Màu tối của chữ mặc định (đen / xám / xanh xám của iOS) — chữ đã đặt màu riêng (xanh chủ đạo, đỏ, trắng) giữ nguyên.
static BOOL GMIsDefaultDark(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat w = 0;
        if (![c getWhite:&w alpha:&a]) return NO;
        r = g = b = w;
    }
    CGFloat mx = MAX(r, MAX(g, b)), mn = MIN(r, MIN(g, b));
    return mx < 0.6 && (mx - mn < 0.35);
}

static Class gBubbleCell;

static BOOL GMSkipCell(UITableViewCell *c) {
    if (c.tag == GMTagOwnBackground || [c isKindOfClass:gBubbleCell]) return YES;
    UITableView *tv = GMTableOf(c);
    return !tv || !GMOurTable(tv);
}

/// Chữ trong ô: nền chữ trong suốt (UIKit iOS 5 / 6 đặt nền chữ = nền ô — ô bo góc vẽ bằng ảnh thì thành mảng chữ nhật).
static void GMClearLabels(UITableViewCell *c) {
    if (GMSkipCell(c)) return;
    if (c.textLabel) c.textLabel.backgroundColor = [UIColor clearColor];
    if (c.detailTextLabel) c.detailTextLabel.backgroundColor = [UIColor clearColor];
}

/// Nền ô bảng nhóm theo vị trí trong nhóm (D37): bo góc 12 ở ô đầu / cuối, vạch mảnh thụt 15 pt ở đáy (trừ ô cuối).
static UIImage *GMGroupedCell(BOOL first, BOOL last, BOOL sel) {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%d%d%d%d", gDark, first, last, sel];
    UIImage *img = [cache objectForKey:key];
    if (img) return img;
    const CGFloat r = 12, lc = 16, w = lc + r + 2, h = 2 * r + 2, px = 1 / [UIScreen mainScreen].scale;
    UIColor *fill = sel ? [GMTheme selectedCell] : [GMTheme cellBackground];
    UIColor *line = [GMTheme separator];
    img = GMDraw(CGSizeMake(w, h), ^(CGContextRef ctx) {
        UIRectCorner corners = (first ? (UIRectCornerTopLeft | UIRectCornerTopRight) : 0) |
                               (last ? (UIRectCornerBottomLeft | UIRectCornerBottomRight) : 0);
        [fill setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, w, h) byRoundingCorners:corners cornerRadii:CGSizeMake(r, r)] fill];
        if (!last) {
            [line setFill];
            CGContextFillRect(ctx, CGRectMake(15, h - px, w - 15, px));
        }
    });
    img = [img resizableImageWithCapInsets:UIEdgeInsetsMake(r, lc, r + 1, r)];
    [cache setObject:img forKey:key];
    return img;
}

static void GMStyleCell(UITableViewCell *c) {
    if (GMSkipCell(c)) return;
    UITableView *tv = GMTableOf(c);
    if (tv.style == UITableViewStyleGrouped) {
        NSIndexPath *ip = [tv indexPathForCell:c];
        BOOL first = YES, last = YES;
        if (ip) {
            first = ip.row == 0;
            last = ip.row == [tv numberOfRowsInSection:ip.section] - 1;
        }
        NSInteger tag = 4240 + (first ? 1 : 0) + (last ? 2 : 0) + (gDark ? 4 : 0);
        if (c.backgroundView.tag != tag) {
            UIImageView *bg = [[UIImageView alloc] initWithImage:GMGroupedCell(first, last, NO)];
            bg.tag = tag;
            c.backgroundView = bg;
            c.selectedBackgroundView = [[UIImageView alloc] initWithImage:GMGroupedCell(first, last, YES)];
            [c setNeedsLayout];
        }
        if (![c.backgroundColor isEqual:[UIColor clearColor]]) c.backgroundColor = [UIColor clearColor];
    } else {
        UIColor *fill = GMPage(NO);
        if (![c.backgroundColor isEqual:fill]) c.backgroundColor = fill;
        if (!c.selectedBackgroundView || c.selectedBackgroundView.tag != 4242) {
            UIView *sel = [[UIView alloc] init];
            sel.tag = 4242;
            sel.backgroundColor = [GMTheme selectedCell];
            c.selectedBackgroundView = sel;
        }
    }
    // Ô kiểu Default không có detailTextLabel (nil — không được cho vào mảng)
    if (c.textLabel) {
        c.textLabel.backgroundColor = [UIColor clearColor];
        if (gDark && c.textLabel.text.length && GMIsDefaultDark(c.textLabel.textColor)) c.textLabel.textColor = [GMTheme text];
    }
    if (c.detailTextLabel) {
        c.detailTextLabel.backgroundColor = [UIColor clearColor];
        // Chữ phụ mặc định của iOS 6 (xanh xám) → xám trung tính như iOS 26
        if (c.detailTextLabel.text.length && GMIsDefaultDark(c.detailTextLabel.textColor) &&
            ![c.detailTextLabel.textColor isEqual:[GMTheme secondaryText]]) {
            c.detailTextLabel.textColor = [GMTheme secondaryText];
        }
    }
}

static void GMSwizzle(Class cls, SEL sel, void (^after)(id me)) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    void (*orig)(id, SEL) = (void (*)(id, SEL))method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(id me) {
        orig(me, sel);
        after(me);
    }));
}

/// Như GMSwizzle cho hàm một đối số BOOL (viewWillAppear:).
static void GMSwizzleB(Class cls, SEL sel, void (^after)(id me, BOOL a)) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    void (*orig)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(id me, BOOL a) {
        orig(me, sel, a);
        after(me, a);
    }));
}

/// Như GMSwizzle cho hàm hai đối số BOOL (setHighlighted:animated:, setSelected:animated:).
static void GMSwizzleBB(Class cls, SEL sel, void (^after)(id me)) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    void (*orig)(id, SEL, BOOL, BOOL) = (void (*)(id, SEL, BOOL, BOOL))method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(id me, BOOL a, BOOL b) {
        orig(me, sel, a, b);
        after(me);
    }));
}

#pragma mark Thanh trên / thanh dưới theo từng màn

typedef NS_ENUM(NSInteger, GMBarKind) { GMBarPlain, GMBarGrouped, GMBarWallpaper };

/// Màn này nền gì: bảng nhóm / bảng thường / hình nền (màn chat, đăng nhập…).
static GMBarKind GMBarKindFor(UIViewController *vc) {
    UITableView *tv = nil;
    BOOL wall = NO;
    if ([vc isKindOfClass:[UITableViewController class]]) {
        tv = ((UITableViewController *)vc).tableView;
    } else if ([vc isViewLoaded]) {
        for (UIView *s in vc.view.subviews) {
            if (!tv && [s isKindOfClass:[UITableView class]]) tv = (UITableView *)s;
            if ([s isKindOfClass:[GMWallpaperView class]]) wall = YES;
        }
    }
    if (tv && tv.tag == GMTagNoWallpaper) return GMBarWallpaper;
    if (tv) return tv.style == UITableViewStyleGrouped ? GMBarGrouped : GMBarPlain;
    return wall ? GMBarWallpaper : GMBarPlain;
}

/// Lát hình nền (0, y, w, h) — thanh trên màn chat liền với nền của màn (GMWallpaperView canh theo đáy thanh trên); `fade`: mờ
/// dần xuống dưới (dải dưới thanh — tin cuộn lên tan vào nền).
static UIImage *GMWallSliceDir(CGFloat w, CGFloat y, CGFloat h, BOOL fade, BOOL up) {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%d|%.0f|%.0f|%.0f|%d|%d", gDark, w, y, h, fade, up];
    UIImage *img = [cache objectForKey:key];
    if (img) return img;
    UIImage *wall = [GMTheme wallpaper];
    img = GMDraw(CGSizeMake(w, h), ^(CGContextRef ctx) {
        [wall drawAtPoint:CGPointMake(0, -y)];
        if (fade) {
            CGContextSetBlendMode(ctx, kCGBlendModeDestinationIn);
            NSMutableArray *cols = [NSMutableArray array];
            CGFloat locs[5];
            for (int i = 0; i < 5; i++) {
                CGFloat t = i / 4.0;
                [cols addObject:RGBA(0x000000, (1 - t) * (1 - t))];
                locs[i] = t;
            }
            if (up) cols = [[[cols reverseObjectEnumerator] allObjects] mutableCopy];
            GMVGradient(ctx, CGRectMake(0, 0, w, h), cols, locs);
        }
    });
    [cache setObject:img forKey:key];
    return img;
}

static UIImage *GMWallSlice(CGFloat w, CGFloat y, CGFloat h, BOOL fade) {
    return GMWallSliceDir(w, y, h, fade, NO);
}

static const NSInteger kGMFadeTag = 0x4750, kGMTabWallTag = 0x4751;
static char kGMBarSig;

/// Dải mờ dần sát mép ngoài của thanh (con của thanh, nằm ngoài khung — không nhận chạm): dưới thanh trên / trên thanh dưới.
static UIImageView *GMFadeView(UIView *bar, BOOL below) {
    UIImageView *v = (UIImageView *)[bar viewWithTag:kGMFadeTag];
    if (!v) {
        const CGFloat h = 12, w = bar.bounds.size.width;
        v = [[UIImageView alloc] initWithFrame:below ? CGRectMake(0, bar.bounds.size.height, w, h) : CGRectMake(0, -h, w, h)];
        v.tag = kGMFadeTag;
        v.userInteractionEnabled = NO;
        v.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                             (below ? UIViewAutoresizingFlexibleTopMargin : UIViewAutoresizingFlexibleBottomMargin);
        [bar addSubview:v];
    }
    return v;
}

+ (void)styleBarsFor:(UIViewController *)vc animated:(BOOL)animated {
    if (![NSStringFromClass([vc class]) hasPrefix:@"GM"]) return;
    UINavigationController *nav = vc.navigationController;
    if (!nav || vc.parentViewController != nav) return;
    // Nút quay lại của màn sau: chỉ mũi tên trong viên kính (iOS 26)
    if (![vc.navigationItem.backBarButtonItem.title isEqual:@" "]) {
        vc.navigationItem.backBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@" " style:UIBarButtonItemStyleBordered
                                                                              target:nil action:nil];
    }
    if (nav.viewControllers.count > 1 && [nav.viewControllers objectAtIndex:0] != vc && !vc.navigationItem.leftBarButtonItem &&
        !vc.navigationItem.hidesBackButton) {
        UIBarButtonItem *back = [GMTheme barButtonIcon:@"back" target:vc action:@selector(gmBack)];
        back.accessibilityLabel = @"Quay lại";
        vc.navigationItem.leftBarButtonItem = back;
    }
    GMBarKind kind = GMBarKindFor(vc);
    UINavigationBar *bar = nav.navigationBar;
    CGFloat w = bar.bounds.size.width, h = bar.bounds.size.height;
    NSString *sig = [NSString stringWithFormat:@"%d|%d|%.0f|%.0f", (int)kind, gDark, w, h];
    if (w > 0 && h > 0 && ![objc_getAssociatedObject(bar, &kGMBarSig) isEqual:sig]) {
        objc_setAssociatedObject(bar, &kGMBarSig, sig, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (animated) {
            CATransition *t = [CATransition animation];
            t.type = kCATransitionFade;
            t.duration = 0.25;
            [bar.layer addAnimation:t forKey:@"gmBarBg"];
        }
        UIImage *bg, *fade;
        if (kind == GMBarWallpaper) {
            bg = GMWallSlice(w, 0, h, NO);
            fade = GMWallSlice(w, h, 12, YES);
        } else {
            UIColor *c = GMPage(kind == GMBarGrouped);
            bg = GMSolid(c, nil);
            fade = GMFade(c, 12, YES);
        }
        [bar setBackgroundImage:bg forBarMetrics:UIBarMetricsDefault];
        [bar setBackgroundImage:bg forBarMetrics:UIBarMetricsLandscapePhone];
        GMFadeView(bar, YES).image = fade;
    }
    // Màn đang hiện cùng thanh dưới: hai bên viên kính lộ nền của màn (màu trang / hình nền), dải mờ phía trên thanh
    UITabBarController *tbc = vc.tabBarController;
    if (tbc && !vc.hidesBottomBarWhenPushed && !tbc.tabBar.hidden) {
        UIView *wall = [tbc.view viewWithTag:kGMTabWallTag];
        UITabBar *tb = tbc.tabBar;
        if (kind == GMBarWallpaper) {
            if (!wall) {
                wall = [[GMWallpaperView alloc] initWithFrame:tbc.view.bounds];
                wall.tag = kGMTabWallTag;
                [tbc.view insertSubview:wall atIndex:0];
            }
            wall.hidden = NO;
            GMFadeView(tb, NO).image = GMWallSliceDir(tb.bounds.size.width, tb.frame.origin.y - 12, 12, YES, YES);
        } else {
            wall.hidden = YES;
            UIColor *c = GMPage(kind == GMBarGrouped);
            tbc.view.backgroundColor = c;
            GMFadeView(tb, NO).image = GMFade(c, 12, NO);
        }
    }
}

static UIImage *GMSearchField(void) {
    const CGFloat r = 15, w = 2 * r + 1, h = 2 * r + 1;
    UIColor *c = [GMTheme fieldBackground];
    UIImage *img = GMDraw(CGSizeMake(w, h), ^(CGContextRef ctx) {
        [c setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, w, h) cornerRadius:r] fill];
    });
    return [img resizableImageWithCapInsets:UIEdgeInsetsMake(r, r, r, r)];
}

+ (void)apply {
    gDark = [self wantsDark];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gBubbleCell = NSClassFromString(@"GMBubbleCell");
        GMSwizzle([UITableView class], @selector(didMoveToWindow), ^(id me) { GMStyleTable(me); });
        GMSwizzle([UITableView class], @selector(layoutSubviews), ^(id me) { if (gDark) GMStyleHeaders(me); });
        GMSwizzle([UITableViewCell class], @selector(layoutSubviews), ^(id me) { GMStyleCell(me); });
        GMSwizzleBB([UITableViewCell class], @selector(setHighlighted:animated:), ^(id me) { GMClearLabels(me); });
        GMSwizzleBB([UITableViewCell class], @selector(setSelected:animated:), ^(id me) { GMClearLabels(me); });
        GMSwizzleB([UIViewController class], @selector(viewWillAppear:), ^(id me, BOOL a) { [GMTheme styleBarsFor:me animated:a]; });
    });
    // Thanh trạng thái iOS 5 / 6 không trong suốt được kiểu iOS 7+: đen đặc cả hai chế độ (bản mẫu D37)
    [UIApplication sharedApplication].statusBarStyle = UIStatusBarStyleBlackOpaque;
    NSValue *noOff = [NSValue valueWithUIOffset:UIOffsetZero];

    // Thanh trên: không còn «thanh» — nền theo màu trang (từng màn đặt lại ở styleBarsFor:), tiêu đề đậm không bóng
    UINavigationBar *nb = [UINavigationBar appearance];
    [nb setBackgroundImage:GMSolid(GMPage(NO), nil) forBarMetrics:UIBarMetricsDefault];
    [nb setBackgroundImage:GMSolid(GMPage(NO), nil) forBarMetrics:UIBarMetricsLandscapePhone];
    GM_IOS6_BEGIN
    if ([UINavigationBar instancesRespondToSelector:@selector(setShadowImage:)]) [nb setShadowImage:GMSolid([UIColor clearColor], nil)];
    GM_IOS6_END
    [nb setTitleTextAttributes:@{
        UITextAttributeTextColor: [self text],
        UITextAttributeTextShadowColor: [UIColor clearColor],
        UITextAttributeTextShadowOffset: noOff,
        UITextAttributeFont: [UIFont boldSystemFontOfSize:17],
    }];

    // Nút thanh trên + nút «Huỷ» của ô tìm: viên kính, chữ màu chữ thường; nút quay lại: viên kính có mũi tên
    NSDictionary *normal = @{
        UITextAttributeTextColor: [self text],
        UITextAttributeTextShadowColor: [UIColor clearColor],
        UITextAttributeTextShadowOffset: noOff,
        UITextAttributeFont: [UIFont systemFontOfSize:15],
    };
    NSMutableDictionary *disabled = [normal mutableCopy];
    [disabled setObject:[[self text] colorWithAlphaComponent:0.35] forKey:UITextAttributeTextColor];
    for (UIBarButtonItem *bi in @[[UIBarButtonItem appearanceWhenContainedIn:[UINavigationBar class], nil],
                                  [UIBarButtonItem appearanceWhenContainedIn:[UISearchBar class], nil]]) {
        for (NSNumber *m in @[@(UIBarMetricsDefault), @(UIBarMetricsLandscapePhone)]) {
            BOOL land = m.integerValue != UIBarMetricsDefault;
            CGFloat h = land ? 24 : 30, r = land ? 10 : 13;
            [bi setBackgroundImage:GMGlassImage(h, r, 1, 0.5, 2.5, NO, NO) forState:UIControlStateNormal barMetrics:m.integerValue];
            [bi setBackgroundImage:GMGlassImage(h, r, 1, 0.5, 2.5, YES, NO) forState:UIControlStateHighlighted barMetrics:m.integerValue];
            [bi setBackButtonBackgroundImage:GMGlassImage(h, r, 1, 0.5, 2.5, NO, YES) forState:UIControlStateNormal
                                  barMetrics:m.integerValue];
            [bi setBackButtonBackgroundImage:GMGlassImage(h, r, 1, 0.5, 2.5, YES, YES) forState:UIControlStateHighlighted
                                  barMetrics:m.integerValue];
            [bi setTitlePositionAdjustment:UIOffsetMake(0, -1) forBarMetrics:m.integerValue];
            [bi setBackButtonTitlePositionAdjustment:UIOffsetMake(0, -1) forBarMetrics:m.integerValue];
        }
        [bi setTitleTextAttributes:normal forState:UIControlStateNormal];
        [bi setTitleTextAttributes:normal forState:UIControlStateHighlighted];
        [bi setTitleTextAttributes:disabled forState:UIControlStateDisabled];
    }

    // Ô tìm: nền trong suốt, ô nhập viên thuốc xám nhạt
    UISearchBar *sb = [UISearchBar appearance];
    [sb setBackgroundImage:GMSolid([UIColor clearColor], nil)];
    [sb setSearchFieldBackgroundImage:GMSearchField() forState:UIControlStateNormal];

    // Thanh dưới: viên kính nổi, viên sáng sau mục đang chọn, chữ màu chữ / màu chủ đạo
    UITabBar *tb = [UITabBar appearance];
    [tb setBackgroundImage:GMTabBg()];
    [tb setSelectionIndicatorImage:GMTabSelection()];
    NSDictionary *tabNormal = @{
        UITextAttributeTextColor: [self text],
        UITextAttributeTextShadowColor: [UIColor clearColor],
        UITextAttributeTextShadowOffset: noOff,
        UITextAttributeFont: [UIFont boldSystemFontOfSize:10],
    };
    NSMutableDictionary *tabSel = [tabNormal mutableCopy];
    [tabSel setObject:[self accent] forKey:UITextAttributeTextColor];
    UITabBarItem *ti = [UITabBarItem appearance];
    [ti setTitleTextAttributes:tabNormal forState:UIControlStateNormal];
    [ti setTitleTextAttributes:tabSel forState:UIControlStateSelected];
    [ti setTitleTextAttributes:tabSel forState:UIControlStateHighlighted];
}

#pragma mark - Giờ, ngày

static NSDateFormatter *GMFormatter(NSString *fmt) {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSDateFormatter *f = [cache objectForKey:fmt];
    if (!f) {
        f = [[NSDateFormatter alloc] init];
        f.dateFormat = fmt;
        [cache setObject:f forKey:fmt];
    }
    return f;
}

static NSDateComponents *GMDay(NSDate *d) {
    return [[NSCalendar currentCalendar] components:NSYearCalendarUnit | NSMonthCalendarUnit | NSDayCalendarUnit | NSWeekdayCalendarUnit
                                           fromDate:d];
}

+ (BOOL)sameDay:(NSNumber *)a as:(NSNumber *)b {
    if (!a || !b) return NO;
    NSDateComponents *x = GMDay([NSDate dateWithTimeIntervalSince1970:a.doubleValue]);
    NSDateComponents *y = GMDay([NSDate dateWithTimeIntervalSince1970:b.doubleValue]);
    return x.year == y.year && x.month == y.month && x.day == y.day;
}

+ (NSString *)clock:(NSNumber *)unix {
    if (!unix) return @"";
    return [GMFormatter(@"HH:mm") stringFromDate:[NSDate dateWithTimeIntervalSince1970:unix.doubleValue]];
}

+ (NSString *)shortTime:(NSNumber *)unix {
    if (!unix) return @"";
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:unix.doubleValue];
    NSNumber *now = @([[NSDate date] timeIntervalSince1970]);
    if ([self sameDay:unix as:now]) return [GMFormatter(@"HH:mm") stringFromDate:d];
    NSTimeInterval ago = now.doubleValue - unix.doubleValue;
    if (ago < 6 * 86400) {
        static NSString *days[] = {@"", @"CN", @"T2", @"T3", @"T4", @"T5", @"T6", @"T7"};
        return days[GMDay(d).weekday];
    }
    if (GMDay(d).year == GMDay([NSDate date]).year) return [GMFormatter(@"dd/MM") stringFromDate:d];
    return [GMFormatter(@"dd/MM/yy") stringFromDate:d];
}

+ (NSString *)dayTitle:(NSNumber *)unix {
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:unix.doubleValue];
    NSNumber *now = @([[NSDate date] timeIntervalSince1970]);
    if ([self sameDay:unix as:now]) return @"Hôm nay";
    if ([self sameDay:unix as:@(now.doubleValue - 86400)]) return @"Hôm qua";
    NSDateComponents *c = GMDay(d);
    if (c.year == GMDay([NSDate date]).year) return [NSString stringWithFormat:@"%ld tháng %ld", (long)c.day, (long)c.month];
    return [NSString stringWithFormat:@"%ld tháng %ld, %ld", (long)c.day, (long)c.month, (long)c.year];
}

#pragma mark - Khác

+ (NSString *)cut:(NSString *)s max:(NSUInteger)max {
    if (s.length <= max) return s;
    // Ký tự (ghép) chứa đơn vị thứ `max`: bắt đầu đúng ở `max` → cắt tại đó; vắt qua mốc → lùi về trước nó
    NSUInteger end = [s rangeOfComposedCharacterSequenceAtIndex:max].location;
    return [[self validUTF16:[s substringToIndex:end]] stringByAppendingString:@"…"];
}

+ (NSString *)validUTF16:(NSString *)s {
    if (!s.length || [s UTF8String]) return s;
    NSUInteger n = s.length;
    unichar *buf = malloc(n * sizeof(unichar));
    if (!buf) return @"";
    [s getCharacters:buf range:NSMakeRange(0, n)];
    for (NSUInteger i = 0; i < n; i++) {
        if (CFStringIsSurrogateHighCharacter(buf[i]) && i + 1 < n && CFStringIsSurrogateLowCharacter(buf[i + 1])) {
            i++;
            continue;
        }
        if (CFStringIsSurrogateHighCharacter(buf[i]) || CFStringIsSurrogateLowCharacter(buf[i])) buf[i] = 0xFFFD;
    }
    NSString *r = [[NSString alloc] initWithCharacters:buf length:n];
    free(buf);
    return r;
}

+ (NSString *)preview:(NSDictionary *)msg {
    if (!msg) return @"";
    NSString *text = GMVal(msg, @"text") ?: @"";
    if ([GMVal(msg, @"service") boolValue]) return text.length ? text : @"Tin hệ thống";
    NSString *media = GMVal(msg, @"media");
    NSString *dk = GMVal(GMVal(msg, @"doc"), @"kind");
    if ([dk isEqual:@"gif"]) media = @"gif";
    else if ([dk isEqual:@"round"]) media = @"round";
    if (!media) return text;
    NSDictionary *labels = @{
        @"photo": @"Ảnh", @"video": @"Video", @"voice": @"Tin thoại", @"audio": @"Âm thanh",
        @"sticker": @"Sticker", @"file": @"Tệp", @"image": @"Ảnh", @"contact": @"Danh bạ",
        @"poll": @"Bình chọn", @"geo": @"Vị trí", @"dice": @"Xúc xắc", @"gif": @"GIF", @"round": @"Video tròn",
    };
    NSString *label = [labels objectForKey:media] ?: @"Media";
    NSString *q = GMVal(GMVal(msg, @"poll"), @"q");
    if ([media isEqual:@"poll"] && q.length) label = [@"📊 " stringByAppendingString:q];
    NSDictionary *card = GMVal(msg, @"contact");
    if ([media isEqual:@"contact"] && [card isKindOfClass:[NSDictionary class]]) {
        NSString *n = [[NSString stringWithFormat:@"%@ %@", GMVal(card, @"first") ?: @"", GMVal(card, @"last") ?: @""]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        label = [@"👤 " stringByAppendingString:n.length ? n : @"Danh thiếp"];
    }
    if ([media isEqual:@"geo"]) {
        NSString *place = GMVal(GMVal(msg, @"geo"), @"title");
        label = [@"📍 " stringByAppendingString:place.length ? place : @"Vị trí"];
    }
    NSString *fname = GMVal(GMVal(msg, @"doc"), @"name");
    if ([media isEqual:@"file"] && fname.length) label = [@"📄 " stringByAppendingString:fname];
    return text.length ? [NSString stringWithFormat:@"%@, %@", label, text] : label;
}

+ (void)toast:(NSString *)text in:(UIView *)view {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = [UIFont boldSystemFontOfSize:14];
    l.textColor = [UIColor whiteColor];
    l.textAlignment = GMAlignCenter;
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    l.layer.cornerRadius = 10;
    l.clipsToBounds = YES;
    l.numberOfLines = 0;  // câu dài (trả lời của bot…) xuống dòng thay vì bị cắt
    CGFloat maxW = view.bounds.size.width - 40;
    CGSize s = [(text ?: @"") sizeWithFont:l.font constrainedToSize:CGSizeMake(maxW - 30, 240) lineBreakMode:GMWordWrap];
    CGFloat w = MIN(maxW, ceil(s.width) + 30), h = MAX(36, ceil(s.height) + 16);
    l.frame = CGRectMake(floor((view.bounds.size.width - w) / 2), floor(MIN(view.bounds.size.height * 0.62, view.bounds.size.height - h - 60)), w, h);
    l.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [view addSubview:l];
    [UIView animateWithDuration:0.3 delay:1.6 + MIN(4.0, text.length / 40.0) options:0 animations:^{ l.alpha = 0; }
                     completion:^(BOOL finished) { [l removeFromSuperview]; }];
}

+ (UIImage *)icon:(NSString *)name {
    return [self icon:name color:[self accent]];
}

+ (UIImage *)icon:(NSString *)name color:(UIColor *)c {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *ckey = [NSString stringWithFormat:@"%@|%@", name, c];
    UIImage *img = [cache objectForKey:ckey];
    if (img) return img;
    img = GMDraw(CGSizeMake(26, 26), ^(CGContextRef ctx) {
        [c set];
        CGContextSetLineWidth(ctx, 1.8);
        CGContextSetLineCap(ctx, kCGLineCapRound);
        if ([name isEqual:@"group"]) {
            // Nhóm: hai đầu người
            CGContextSetLineWidth(ctx, 1.8);
            CGContextStrokeEllipseInRect(ctx, CGRectMake(5, 5, 7, 7));
            CGContextAddArc(ctx, 8.5, 21, 6, M_PI, 0, 0);
            CGContextStrokePath(ctx);
            CGContextStrokeEllipseInRect(ctx, CGRectMake(14.5, 7, 6, 6));
            CGContextAddArc(ctx, 17.5, 21.5, 5, M_PI * 1.15, 0, 0);
            CGContextStrokePath(ctx);
        } else if ([name isEqual:@"sticker"]) {
            // Mặt cười: vòng tròn + hai mắt + miệng
            CGContextSetLineWidth(ctx, 1.8);
            CGContextStrokeEllipseInRect(ctx, CGRectMake(3.5, 3.5, 19, 19));
            CGContextFillEllipseInRect(ctx, CGRectMake(9, 9, 2.4, 3));
            CGContextFillEllipseInRect(ctx, CGRectMake(14.6, 9, 2.4, 3));
            CGContextAddArc(ctx, 13, 13.5, 5, 0.35, M_PI - 0.35, 0);
            CGContextStrokePath(ctx);
        } else if ([name isEqual:@"keyboard"]) {
            // Bàn phím: khung bo + các phím nhỏ
            CGContextSetLineWidth(ctx, 1.6);
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(2.5, 6.5, 21, 14) cornerRadius:2.5] stroke];
            for (int r = 0; r < 2; r++) {
                for (int k = 0; k < 5; k++) CGContextFillRect(ctx, CGRectMake(5 + k * 3.6, 9.5 + r * 3.3, 2.2, 2));
            }
            CGContextFillRect(ctx, CGRectMake(8, 16.4, 10, 2));
        } else if ([name isEqual:@"menu"]) {
            // Nút «Menu» của bot: ba vạch ngang
            CGContextSetLineWidth(ctx, 2);
            for (int i = 0; i < 3; i++) {
                CGContextMoveToPoint(ctx, 7, 8 + i * 5);
                CGContextAddLineToPoint(ctx, 19, 8 + i * 5);
            }
            CGContextStrokePath(ctx);
        } else if ([name isEqual:@"botkeys"]) {
            // Bàn phím của bot: bốn ô vuông bo
            CGContextSetLineWidth(ctx, 1.6);
            for (int r = 0; r < 2; r++) {
                for (int k = 0; k < 2; k++) {
                    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(4.5 + k * 9.5, 4.5 + r * 9.5, 7.5, 7.5) cornerRadius:2] stroke];
                }
            }
        } else if ([name isEqual:@"compose"]) {
            // Soạn tin mới: tờ giấy (hở góc trên phải) + bút chì chéo — nét đậm, màu chủ đạo (thanh trắng phẳng)
            CGContextSetLineWidth(ctx, 2);
            CGContextSetLineJoin(ctx, kCGLineJoinRound);
            CGContextMoveToPoint(ctx, 13, 4.5);
            CGContextAddLineToPoint(ctx, 6.5, 4.5);
            CGContextAddQuadCurveToPoint(ctx, 4, 4.5, 4, 7);
            CGContextAddLineToPoint(ctx, 4, 19.5);
            CGContextAddQuadCurveToPoint(ctx, 4, 22, 6.5, 22);
            CGContextAddLineToPoint(ctx, 19, 22);
            CGContextAddQuadCurveToPoint(ctx, 21.5, 22, 21.5, 19.5);
            CGContextAddLineToPoint(ctx, 21.5, 13);
            CGContextStrokePath(ctx);
            CGContextSetLineWidth(ctx, 3.4);
            CGContextMoveToPoint(ctx, 13.2, 12.8);
            CGContextAddLineToPoint(ctx, 21.5, 4.5);
            CGContextStrokePath(ctx);
            CGContextMoveToPoint(ctx, 10.2, 15.8);  // ngòi
            CGContextAddLineToPoint(ctx, 11.4, 12.3);
            CGContextAddLineToPoint(ctx, 13.7, 14.6);
            CGContextClosePath(ctx);
            CGContextFillPath(ctx);
        } else if ([name isEqual:@"refresh"]) {
            // Làm mới: vòng gần kín + đầu mũi tên
            CGContextSetLineWidth(ctx, 2.2);
            CGContextAddArc(ctx, 13, 13.5, 8, -M_PI / 3, M_PI * 1.45, 0);
            CGContextStrokePath(ctx);
            CGFloat ex = 13 + 8 * cos(-M_PI / 3), ey = 13.5 + 8 * sin(-M_PI / 3);
            CGContextMoveToPoint(ctx, ex + 1.5, ey - 5);
            CGContextAddLineToPoint(ctx, ex + 1.8, ey + 1.2);
            CGContextAddLineToPoint(ctx, ex - 4.2, ey + 0.4);
            CGContextClosePath(ctx);
            CGContextFillPath(ctx);
        } else if ([name isEqual:@"phone"]) {
            // Ống nghe (gọi thoại): hai đầu bo nối bằng cung
            UIBezierPath *p = [UIBezierPath bezierPath];
            [p moveToPoint:CGPointMake(6, 7.5)];
            [p addCurveToPoint:CGPointMake(18.5, 20) controlPoint1:CGPointMake(6, 14.5) controlPoint2:CGPointMake(11.5, 20)];
            p.lineWidth = 3.4;
            p.lineCapStyle = kCGLineCapRound;
            [p stroke];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(3.5, 3.5, 5.5, 6.5) cornerRadius:1.8] fill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(16, 17.5, 6.5, 5.5) cornerRadius:1.8] fill];
        } else if ([name isEqual:@"mic"]) {
            UIBezierPath *cap = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(9, 3, 8, 13) cornerRadius:4];
            [cap fill];
            CGContextAddArc(ctx, 13, 11, 7, 0, M_PI, 0);
            CGContextStrokePath(ctx);
            CGContextMoveToPoint(ctx, 13, 18);
            CGContextAddLineToPoint(ctx, 13, 22);
            CGContextMoveToPoint(ctx, 9, 22.5);
            CGContextAddLineToPoint(ctx, 17, 22.5);
            CGContextStrokePath(ctx);
        } else if ([name isEqual:@"pin"]) {
            // Ghim: đinh ghim nghiêng (danh sách chat, D37)
            CGContextSetLineWidth(ctx, 1.8);
            CGContextSetLineJoin(ctx, kCGLineJoinRound);
            CGContextTranslateCTM(ctx, 13, 13);
            CGContextRotateCTM(ctx, M_PI / 4);
            CGContextMoveToPoint(ctx, -3.5, -8);
            CGContextAddLineToPoint(ctx, 3.5, -8);
            CGContextAddLineToPoint(ctx, 2.5, -1.5);
            CGContextAddLineToPoint(ctx, 5.5, 2);
            CGContextAddLineToPoint(ctx, -5.5, 2);
            CGContextAddLineToPoint(ctx, -2.5, -1.5);
            CGContextClosePath(ctx);
            CGContextFillPath(ctx);
            CGContextMoveToPoint(ctx, 0, 2);
            CGContextAddLineToPoint(ctx, 0, 9.5);
            CGContextStrokePath(ctx);
        } else if ([name isEqual:@"muted"]) {
            // Loa gạch chéo
            CGContextSetLineJoin(ctx, kCGLineJoinRound);
            CGContextMoveToPoint(ctx, 4, 10);
            CGContextAddLineToPoint(ctx, 8, 10);
            CGContextAddLineToPoint(ctx, 13.5, 5);
            CGContextAddLineToPoint(ctx, 13.5, 21);
            CGContextAddLineToPoint(ctx, 8, 16);
            CGContextAddLineToPoint(ctx, 4, 16);
            CGContextClosePath(ctx);
            CGContextFillPath(ctx);
            CGContextSetLineWidth(ctx, 2);
            CGContextMoveToPoint(ctx, 16.5, 10);
            CGContextAddLineToPoint(ctx, 22, 16);
            CGContextMoveToPoint(ctx, 22, 10);
            CGContextAddLineToPoint(ctx, 16.5, 16);
            CGContextStrokePath(ctx);
        } else if ([name isEqual:@"read"] || [name isEqual:@"sent"]) {
            // ✓✓ đã đọc / ✓ đã gửi
            CGContextSetLineWidth(ctx, 2);
            CGContextSetLineJoin(ctx, kCGLineJoinRound);
            BOOL two = [name isEqual:@"read"];
            CGFloat dx = two ? -2.5 : 0;
            CGContextMoveToPoint(ctx, 5 + dx, 13.5);
            CGContextAddLineToPoint(ctx, 9 + dx, 17.5);
            CGContextAddLineToPoint(ctx, 17 + dx, 8.5);
            if (two) {
                CGContextMoveToPoint(ctx, 13 + dx, 16.5);
                CGContextAddLineToPoint(ctx, 14 + dx, 17.5);
                CGContextAddLineToPoint(ctx, 22 + dx, 8.5);
            }
            CGContextStrokePath(ctx);
        } else if ([name isEqual:@"reply"] || [name isEqual:@"forward"]) {
            // Mũi tên cong: trả lời (sang trái) / chuyển tiếp (lật ngang)
            if ([name isEqual:@"forward"]) {
                CGContextTranslateCTM(ctx, 26, 0);
                CGContextScaleCTM(ctx, -1, 1);
            }
            CGContextSetLineWidth(ctx, 1.9);
            CGContextSetLineJoin(ctx, kCGLineJoinRound);
            CGContextMoveToPoint(ctx, 10, 6.5);
            CGContextAddLineToPoint(ctx, 4.5, 12);
            CGContextAddLineToPoint(ctx, 10, 17.5);
            CGContextMoveToPoint(ctx, 4.5, 12);
            CGContextAddLineToPoint(ctx, 14, 12);
            CGContextAddQuadCurveToPoint(ctx, 21.5, 12, 21.5, 20.5);
            CGContextStrokePath(ctx);
        } else if ([name isEqual:@"copy"]) {
            CGContextSetLineWidth(ctx, 1.8);
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(9.5, 9.5, 12, 12) cornerRadius:2.5] stroke];
            CGContextMoveToPoint(ctx, 16.5, 6.5);
            CGContextAddLineToPoint(ctx, 16.5, 6);
            CGContextAddQuadCurveToPoint(ctx, 16.5, 4.5, 15, 4.5);
            CGContextAddLineToPoint(ctx, 6, 4.5);
            CGContextAddQuadCurveToPoint(ctx, 4.5, 4.5, 4.5, 6);
            CGContextAddLineToPoint(ctx, 4.5, 15);
            CGContextAddQuadCurveToPoint(ctx, 4.5, 16.5, 6, 16.5);
            CGContextAddLineToPoint(ctx, 6.5, 16.5);
            CGContextStrokePath(ctx);
        } else if ([name isEqual:@"save"]) {
            // Mũi tên xuống khay
            CGContextSetLineWidth(ctx, 1.9);
            CGContextSetLineJoin(ctx, kCGLineJoinRound);
            CGContextMoveToPoint(ctx, 13, 4);
            CGContextAddLineToPoint(ctx, 13, 15.5);
            CGContextMoveToPoint(ctx, 8.5, 11.5);
            CGContextAddLineToPoint(ctx, 13, 16);
            CGContextAddLineToPoint(ctx, 17.5, 11.5);
            CGContextMoveToPoint(ctx, 4.5, 15.5);
            CGContextAddLineToPoint(ctx, 4.5, 21.5);
            CGContextAddLineToPoint(ctx, 21.5, 21.5);
            CGContextAddLineToPoint(ctx, 21.5, 15.5);
            CGContextStrokePath(ctx);
        } else if ([name isEqual:@"edit"]) {
            // Bút chì chéo
            CGContextSetLineWidth(ctx, 1.8);
            CGContextSetLineJoin(ctx, kCGLineJoinRound);
            CGContextMoveToPoint(ctx, 17, 4.5);
            CGContextAddLineToPoint(ctx, 21.5, 9);
            CGContextAddLineToPoint(ctx, 9.5, 21);
            CGContextAddLineToPoint(ctx, 4.5, 21.5);
            CGContextAddLineToPoint(ctx, 5, 16.5);
            CGContextClosePath(ctx);
            CGContextMoveToPoint(ctx, 14.5, 7);
            CGContextAddLineToPoint(ctx, 19, 11.5);
            CGContextStrokePath(ctx);
        } else if ([name isEqual:@"trash"]) {
            CGContextSetLineWidth(ctx, 1.8);
            CGContextSetLineJoin(ctx, kCGLineJoinRound);
            CGContextMoveToPoint(ctx, 4.5, 7);
            CGContextAddLineToPoint(ctx, 21.5, 7);
            CGContextMoveToPoint(ctx, 10, 7);
            CGContextAddLineToPoint(ctx, 10, 4.5);
            CGContextAddLineToPoint(ctx, 16, 4.5);
            CGContextAddLineToPoint(ctx, 16, 7);
            CGContextMoveToPoint(ctx, 6.5, 7);
            CGContextAddLineToPoint(ctx, 7.5, 21.5);
            CGContextAddLineToPoint(ctx, 18.5, 21.5);
            CGContextAddLineToPoint(ctx, 19.5, 7);
            CGContextMoveToPoint(ctx, 11, 11);
            CGContextAddLineToPoint(ctx, 11, 17.5);
            CGContextMoveToPoint(ctx, 15, 11);
            CGContextAddLineToPoint(ctx, 15, 17.5);
            CGContextStrokePath(ctx);
        } else if ([name isEqual:@"x"]) {
            CGContextSetLineWidth(ctx, 2.4);
            CGContextMoveToPoint(ctx, 8, 8);
            CGContextAddLineToPoint(ctx, 18, 18);
            CGContextMoveToPoint(ctx, 18, 8);
            CGContextAddLineToPoint(ctx, 8, 18);
            CGContextStrokePath(ctx);
        } else if ([name isEqual:@"photo"]) {
            CGContextSetLineWidth(ctx, 1.8);
            CGContextSetLineJoin(ctx, kCGLineJoinRound);
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(3.5, 5.5, 19, 15) cornerRadius:2.5] stroke];
            CGContextMoveToPoint(ctx, 3.5, 17.5);
            CGContextAddLineToPoint(ctx, 9, 12);
            CGContextAddLineToPoint(ctx, 13.5, 16.5);
            CGContextAddLineToPoint(ctx, 16.5, 13.5);
            CGContextAddLineToPoint(ctx, 22.5, 19.5);
            CGContextStrokePath(ctx);
            CGContextFillEllipseInRect(ctx, CGRectMake(15.5, 8, 3, 3));
        } else if ([name isEqual:@"file"]) {
            CGContextSetLineWidth(ctx, 1.8);
            CGContextSetLineJoin(ctx, kCGLineJoinRound);
            CGContextMoveToPoint(ctx, 15, 3.5);
            CGContextAddLineToPoint(ctx, 6.5, 3.5);
            CGContextAddLineToPoint(ctx, 6.5, 22.5);
            CGContextAddLineToPoint(ctx, 19.5, 22.5);
            CGContextAddLineToPoint(ctx, 19.5, 8);
            CGContextClosePath(ctx);
            CGContextMoveToPoint(ctx, 15, 3.5);
            CGContextAddLineToPoint(ctx, 15, 8);
            CGContextAddLineToPoint(ctx, 19.5, 8);
            CGContextStrokePath(ctx);
        } else if ([name isEqual:@"location"]) {
            CGContextSetLineWidth(ctx, 1.8);
            CGContextSetLineJoin(ctx, kCGLineJoinRound);
            CGContextMoveToPoint(ctx, 13, 22.5);
            CGContextAddCurveToPoint(ctx, 8.5, 18, 6, 14, 6, 10.5);
            CGContextAddArc(ctx, 13, 10.5, 7, M_PI, 0, 0);
            CGContextAddCurveToPoint(ctx, 20, 14, 17.5, 18, 13, 22.5);
            CGContextStrokePath(ctx);
            CGContextStrokeEllipseInRect(ctx, CGRectMake(10.5, 8, 5, 5));
        } else if ([name isEqual:@"qr"]) {
            CGContextSetLineWidth(ctx, 1.8);
            for (int k = 0; k < 3; k++) {
                CGFloat x = k == 1 ? 14 : 4, y = k == 2 ? 14 : 4;
                CGContextStrokeRect(ctx, CGRectMake(x + 0.5, y + 0.5, 7, 7));
                CGContextFillRect(ctx, CGRectMake(x + 3, y + 3, 2, 2));
            }
            CGContextFillRect(ctx, CGRectMake(14.5, 14.5, 3, 3));
            CGContextFillRect(ctx, CGRectMake(19, 19, 3, 3));
            CGContextFillRect(ctx, CGRectMake(19, 14.5, 3, 3));
            CGContextFillRect(ctx, CGRectMake(14.5, 19, 3, 3));
        } else if ([name isEqual:@"card"]) {
            CGContextSetLineWidth(ctx, 1.8);
            CGContextSetLineJoin(ctx, kCGLineJoinRound);
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(3, 5.5, 20, 15) cornerRadius:2.5] stroke];
            CGContextStrokeEllipseInRect(ctx, CGRectMake(7, 9, 5, 5));
            CGContextMoveToPoint(ctx, 6, 17.5);
            CGContextAddQuadCurveToPoint(ctx, 9.5, 13.5, 13, 17.5);
            CGContextMoveToPoint(ctx, 15.5, 10.5);
            CGContextAddLineToPoint(ctx, 19.5, 10.5);
            CGContextMoveToPoint(ctx, 15.5, 14.5);
            CGContextAddLineToPoint(ctx, 19.5, 14.5);
            CGContextStrokePath(ctx);
        } else if ([name isEqual:@"camera"]) {
            CGContextSetLineWidth(ctx, 1.8);
            CGContextSetLineJoin(ctx, kCGLineJoinRound);
            CGContextMoveToPoint(ctx, 3.5, 9);
            CGContextAddLineToPoint(ctx, 8, 9);
            CGContextAddLineToPoint(ctx, 10, 6);
            CGContextAddLineToPoint(ctx, 16, 6);
            CGContextAddLineToPoint(ctx, 18, 9);
            CGContextAddLineToPoint(ctx, 22.5, 9);
            CGContextAddLineToPoint(ctx, 22.5, 20.5);
            CGContextAddLineToPoint(ctx, 3.5, 20.5);
            CGContextClosePath(ctx);
            CGContextStrokePath(ctx);
            CGContextStrokeEllipseInRect(ctx, CGRectMake(9, 10, 8, 8));
        } else if ([name isEqual:@"back"]) {
            CGContextSetLineWidth(ctx, 2.6);
            CGContextSetLineJoin(ctx, kCGLineJoinRound);
            CGContextMoveToPoint(ctx, 15.5, 5.5);
            CGContextAddLineToPoint(ctx, 8.5, 13);
            CGContextAddLineToPoint(ctx, 15.5, 20.5);
            CGContextStrokePath(ctx);
        } else if ([name isEqual:@"down"]) {
            CGContextSetLineWidth(ctx, 2.4);
            CGContextSetLineJoin(ctx, kCGLineJoinRound);
            CGContextMoveToPoint(ctx, 7, 10);
            CGContextAddLineToPoint(ctx, 13, 16);
            CGContextAddLineToPoint(ctx, 19, 10);
            CGContextStrokePath(ctx);
        } else {
            // Kẹp giấy: hai vòng lồng nhau
            CGContextMoveToPoint(ctx, 16, 7);
            CGContextAddLineToPoint(ctx, 16, 18);
            CGContextAddArc(ctx, 12.5, 18, 3.5, 0, M_PI, 0);
            CGContextAddLineToPoint(ctx, 9, 5.5);
            CGContextAddArc(ctx, 11.5, 5.5, 2.5, M_PI, 0, 0);
            CGContextAddLineToPoint(ctx, 14, 17);
            CGContextAddArc(ctx, 12.5, 17, 1.5, 0, M_PI, 0);
            CGContextAddLineToPoint(ctx, 11, 8);
            CGContextStrokePath(ctx);
        }
    });
    [cache setObject:img forKey:ckey];
    return img;
}

+ (UIImage *)roundImage:(UIImage *)img size:(CGFloat)size {
    return GMDraw(CGSizeMake(size, size), ^(CGContextRef ctx) {
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, size, size)] addClip];
        [img drawInRect:CGRectMake(0, 0, size, size)];
    });
}

+ (UIImage *)settingsIcon:(NSString *)kind {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    UIImage *img = [cache objectForKey:kind];
    if (img) return img;
    // D37: ô vuông bo một màu phẳng (như Cài đặt iOS 26), hình trắng
    int top;
    if ([kind isEqual:@"saved"]) top = 0x2F7DF6;
    else if ([kind isEqual:@"proxy"]) top = 0x0E8F80;
    else if ([kind isEqual:@"storage"]) top = 0x2F9E4F;
    else if ([kind isEqual:@"notify"]) top = 0xE5484D;
    else if ([kind isEqual:@"lock"]) top = 0x6E6E76;
    else if ([kind isEqual:@"theme"]) top = 0x5B5BD6;
    else if ([kind isEqual:@"stickers"]) top = 0xD9437E;
    else if ([kind isEqual:@"folders"]) top = 0x0F9BB0;
    else if ([kind isEqual:@"community"]) top = 0x2F7DF6;
    else if ([kind isEqual:@"quick"]) top = 0xE08600;
    else top = 0x7A7A80;
    img = GMDraw(CGSizeMake(29, 29), ^(CGContextRef ctx) {
        UIBezierPath *sq = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 29, 29) cornerRadius:7.5];
        [RGB(top) setFill];
        [sq fill];
        [[UIColor whiteColor] set];
        if ([kind isEqual:@"saved"]) {
            // Dấu trang: chữ nhật có khía chữ V ở đáy
            CGContextMoveToPoint(ctx, 9.5, 6.5);
            CGContextAddLineToPoint(ctx, 19.5, 6.5);
            CGContextAddLineToPoint(ctx, 19.5, 23);
            CGContextAddLineToPoint(ctx, 14.5, 18.5);
            CGContextAddLineToPoint(ctx, 9.5, 23);
            CGContextClosePath(ctx);
            CGContextFillPath(ctx);
        } else if ([kind isEqual:@"proxy"]) {
            // Khiên
            CGContextMoveToPoint(ctx, 14.5, 5.5);
            CGContextAddLineToPoint(ctx, 22, 8.5);
            CGContextAddCurveToPoint(ctx, 22, 16, 19, 21, 14.5, 23.5);
            CGContextAddCurveToPoint(ctx, 10, 21, 7, 16, 7, 8.5);
            CGContextClosePath(ctx);
            CGContextFillPath(ctx);
        } else if ([kind isEqual:@"theme"]) {
            // Trăng khuyết: tròn trắng trừ đi một tròn lệch (tô chẵn-lẻ trong vùng tròn đầu)
            CGContextSaveGState(ctx);
            CGContextAddEllipseInRect(ctx, CGRectMake(6.5, 6.5, 16, 16));
            CGContextClip(ctx);
            CGContextAddRect(ctx, CGRectMake(0, 0, 29, 29));
            CGContextAddEllipseInRect(ctx, CGRectMake(11.5, 3.5, 14, 14));
            CGContextEOFillPath(ctx);
            CGContextRestoreGState(ctx);
        } else if ([kind isEqual:@"community"]) {
            // Hai bong bóng chat chồng nhau (nhóm trò chuyện)
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(5, 6, 13, 10) cornerRadius:3] fill];
            CGContextMoveToPoint(ctx, 8, 15.5);
            CGContextAddLineToPoint(ctx, 7, 19);
            CGContextAddLineToPoint(ctx, 11.5, 15.5);
            CGContextFillPath(ctx);
            [[UIColor colorWithWhite:1 alpha:0.75] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(11, 11.5, 13, 10) cornerRadius:3] fill];
            CGContextMoveToPoint(ctx, 21, 21);
            CGContextAddLineToPoint(ctx, 22, 24.5);
            CGContextAddLineToPoint(ctx, 17.5, 21);
            CGContextFillPath(ctx);
            [[UIColor whiteColor] set];
        } else if ([kind isEqual:@"folders"]) {
            // Thư mục: tai + thân
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(6, 8, 8, 4) cornerRadius:1.5] fill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(6, 10, 17, 12) cornerRadius:2] fill];
        } else if ([kind isEqual:@"stickers"]) {
            // Mặt cười: tròn trắng, mắt + miệng màu cam đậm
            CGContextFillEllipseInRect(ctx, CGRectMake(6, 6, 17, 17));
            [RGB(top) set];
            CGContextFillEllipseInRect(ctx, CGRectMake(10.2, 10.5, 2.4, 3));
            CGContextFillEllipseInRect(ctx, CGRectMake(16.4, 10.5, 2.4, 3));
            CGContextSetLineWidth(ctx, 1.6);
            CGContextSetLineCap(ctx, kCGLineCapRound);
            CGContextAddArc(ctx, 14.5, 14.5, 4.6, 0.45, M_PI - 0.45, 0);
            CGContextStrokePath(ctx);
            [[UIColor whiteColor] set];
        } else if ([kind isEqual:@"lock"]) {
            // Ổ khoá: quai + thân
            CGContextSetLineWidth(ctx, 2.2);
            CGContextAddArc(ctx, 14.5, 12, 4.5, M_PI, 0, 0);
            CGContextAddLineToPoint(ctx, 19, 14);
            CGContextMoveToPoint(ctx, 10, 12);
            CGContextAddLineToPoint(ctx, 10, 14);
            CGContextStrokePath(ctx);
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(7.5, 13.5, 14, 10) cornerRadius:2] fill];
        } else if ([kind isEqual:@"notify"]) {
            // Chuông: vòm + thân loe + vành + quả lắc
            CGContextFillEllipseInRect(ctx, CGRectMake(9, 6, 11, 12));
            CGContextMoveToPoint(ctx, 9, 12);
            CGContextAddLineToPoint(ctx, 20, 12);
            CGContextAddLineToPoint(ctx, 21.5, 19);
            CGContextAddLineToPoint(ctx, 7.5, 19);
            CGContextClosePath(ctx);
            CGContextFillPath(ctx);
            CGContextFillRect(ctx, CGRectMake(6.5, 18.5, 16, 2));
            CGContextFillEllipseInRect(ctx, CGRectMake(12.5, 20.5, 4, 3.5));
        } else if ([kind isEqual:@"quick"]) {
            // Tin nhắn nhanh: tia chớp
            CGContextMoveToPoint(ctx, 16.5, 4.5);
            CGContextAddLineToPoint(ctx, 8, 16);
            CGContextAddLineToPoint(ctx, 13.5, 16);
            CGContextAddLineToPoint(ctx, 12, 24.5);
            CGContextAddLineToPoint(ctx, 21, 12.5);
            CGContextAddLineToPoint(ctx, 15.5, 12.5);
            CGContextClosePath(ctx);
            CGContextFillPath(ctx);
        } else if ([kind isEqual:@"storage"]) {
            // Biểu đồ tròn: vòng + một múi đặc
            CGContextSetLineWidth(ctx, 1.8);
            CGContextStrokeEllipseInRect(ctx, CGRectMake(6, 6, 17, 17));
            CGContextMoveToPoint(ctx, 14.5, 14.5);
            CGContextAddArc(ctx, 14.5, 14.5, 8.5, -M_PI_2, 0.35, 0);
            CGContextClosePath(ctx);
            CGContextFillPath(ctx);
        } else {
            CGContextSetLineWidth(ctx, 1.6);
            CGContextStrokeEllipseInRect(ctx, CGRectMake(5.5, 5.5, 18, 18));
            CGContextFillEllipseInRect(ctx, CGRectMake(13.4, 9, 2.2, 2.2));
            CGContextFillRect(ctx, CGRectMake(13.5, 12.5, 2, 7));
        }
    });
    [cache setObject:img forKey:kind];
    return img;
}

+ (UIImage *)folderIcon {
    static UIImage *img;
    if (!img) {
        img = GMDraw(CGSizeMake(36, 36), ^(CGContextRef ctx) {
            [RGB(0x5AA9F0) setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 7, 14, 8) cornerRadius:2] fill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 10, 32, 21) cornerRadius:3] fill];
            [RGB(0x8CC4F5) setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 14, 32, 17) cornerRadius:3] fill];
        });
    }
    return img;
}

+ (UIImage *)fileIcon:(NSString *)ext {
    NSString *e = ext.length ? ext.uppercaseString : @"TỆP";
    if (e.length > 4) e = [e substringToIndex:4];
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *ckey = gDark ? [e stringByAppendingString:@"|d"] : e;
    UIImage *img = [cache objectForKey:ckey];
    if (img) return img;
    NSString *l = e.lowercaseString;
    UIColor *bg = [@[@"jpg", @"jpeg", @"png", @"gif", @"heic", @"bmp", @"tif", @"tiff"] containsObject:l] ? RGB(0x37B35D)
                  : [@[@"mp4", @"mov", @"m4v", @"3gp", @"avi", @"mkv", @"webm"] containsObject:l]  ? RGB(0x9B59D0)
                  : [@[@"mp3", @"m4a", @"aac", @"wav", @"ogg", @"flac", @"amr"] containsObject:l]  ? RGB(0xF0A030)
                  : [@[@"pdf"] containsObject:l]                                                   ? RGB(0xE0483E)
                  : [@[@"zip", @"rar", @"7z", @"gz", @"tar", @"deb", @"ipa"] containsObject:l]     ? RGB(0x8E8E93)
                                                                                                   : [self accent];
    img = GMDraw(CGSizeMake(36, 36), ^(CGContextRef ctx) {
        [bg setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 2, 32, 32) cornerRadius:7] fill];
        UIFont *f = [UIFont boldSystemFontOfSize:e.length > 3 ? 9.5 : 11];
        CGSize s = [e sizeWithFont:f];
        [[UIColor whiteColor] set];
        [e drawAtPoint:CGPointMake(18 - s.width / 2, 18 - s.height / 2) withFont:f];
    });
    [cache setObject:img forKey:ckey];
    return img;
}

static NSString *GMGrouped(long long n) {
    // 12.345 (dấu chấm ngăn nghìn kiểu Việt)
    NSString *s = [NSString stringWithFormat:@"%lld", n];
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < s.length; i++) {
        if (i > 0 && (s.length - i) % 3 == 0) [out appendString:@"."];
        [out appendFormat:@"%C", [s characterAtIndex:i]];
    }
    return out;
}

+ (NSString *)statusText:(NSDictionary *)st {
    NSString *kind = GMVal(st, @"kind");
    if ([kind isEqual:@"group"] || [kind isEqual:@"channel"]) {
        long long members = [GMVal(st, @"members") longLongValue], online = [GMVal(st, @"online") longLongValue];
        if (!GMVal(st, @"members")) return [kind isEqual:@"channel"] ? @"kênh" : @"nhóm";
        NSString *m = [NSString stringWithFormat:[kind isEqual:@"channel"] ? @"%@ người theo dõi" : @"%@ thành viên", GMGrouped(members)];
        return online > 1 ? [NSString stringWithFormat:@"%@, %@ trực tuyến", m, GMGrouped(online)] : m;
    }
    if ([GMVal(st, @"bot") boolValue]) return @"bot";
    NSString *s = GMVal(st, @"status");
    if ([s isEqual:@"online"]) return @"trực tuyến";
    if ([s isEqual:@"recently"]) return @"truy cập gần đây";
    if ([s isEqual:@"week"]) return @"truy cập trong tuần";
    if ([s isEqual:@"month"]) return @"truy cập trong tháng";
    if (![s isEqual:@"offline"]) return @"truy cập lâu rồi";
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:[GMVal(st, @"was_online") doubleValue]];
    NSTimeInterval ago = -[d timeIntervalSinceNow];
    if (ago < 60) return @"vừa truy cập";
    if (ago < 3600) return [NSString stringWithFormat:@"truy cập %d phút trước", (int)(ago / 60)];
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *a = [cal components:NSYearCalendarUnit | NSMonthCalendarUnit | NSDayCalendarUnit fromDate:d];
    NSDateComponents *b = [cal components:NSYearCalendarUnit | NSMonthCalendarUnit | NSDayCalendarUnit fromDate:[NSDate date]];
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"HH:mm";
    NSString *hm = [f stringFromDate:d];
    BOOL sameMonth = a.year == b.year && a.month == b.month;
    if (sameMonth && a.day == b.day) return [@"truy cập lúc " stringByAppendingString:hm];
    if (ago < 2 * 86400 && sameMonth && b.day - a.day == 1) return [@"truy cập hôm qua lúc " stringByAppendingString:hm];
    f.dateFormat = @"dd/MM/yy";
    return [@"truy cập " stringByAppendingString:[f stringFromDate:d]];
}

+ (NSString *)typingText:(NSString *)action name:(NSString *)name {
    NSDictionary *t = @{@"recording": @"đang ghi âm…", @"voice": @"đang gửi tin thoại…", @"photo": @"đang gửi ảnh…",
                        @"video": @"đang gửi video…", @"round": @"đang quay video…", @"file": @"đang gửi tệp…",
                        @"sticker": @"đang chọn sticker…", @"game": @"đang chơi game…"};
    NSString *what = [t objectForKey:action] ?: @"đang gõ…";
    if (!name.length) return what;
    NSString *first = [[name componentsSeparatedByString:@" "] objectAtIndex:0];
    return [NSString stringWithFormat:@"%@ %@", first, what];
}

+ (NSString *)sizeText:(double)b {
    NSString *s;
    if (b < 1024) s = [NSString stringWithFormat:@"%.0f B", b];
    else if (b < 1024 * 1024) s = [NSString stringWithFormat:@"%.0f KB", b / 1024];
    else if (b < 1024.0 * 1024 * 1024) s = [NSString stringWithFormat:@"%.1f MB", b / 1048576];
    else s = [NSString stringWithFormat:@"%.2f GB", b / 1073741824.0];
    return [s stringByReplacingOccurrencesOfString:@"." withString:@","];
}

+ (NSString *)ttlText:(NSInteger)s {
    if (s <= 0) return @"Tắt";
    if (s == 86400) return @"1 ngày";
    if (s == 7 * 86400) return @"1 tuần";
    if (s == 31 * 86400) return @"1 tháng";
    if (s % (7 * 86400) == 0) return [NSString stringWithFormat:@"%ld tuần", (long)(s / (7 * 86400))];
    if (s % 86400 == 0) return [NSString stringWithFormat:@"%ld ngày", (long)(s / 86400)];
    if (s % 3600 == 0) return [NSString stringWithFormat:@"%ld giờ", (long)(s / 3600)];
    if (s % 60 == 0) return [NSString stringWithFormat:@"%ld phút", (long)(s / 60)];
    return [NSString stringWithFormat:@"%ld giây", (long)s];
}

+ (NSArray *)ttlChoices {
    return @[@0, @86400, @(7 * 86400), @(31 * 86400)];
}

+ (UIButton *)button:(NSString *)title {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b setTitleColor:[UIColor colorWithWhite:1 alpha:0.5] forState:UIControlStateHighlighted];
    [b setTitleColor:[UIColor colorWithWhite:1 alpha:0.6] forState:UIControlStateDisabled];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    // Nút xanh phẳng (cao 44, viên giữa cao 32 bo tròn)
    [b setBackgroundImage:[self sendButtonImage:NO] forState:UIControlStateNormal];
    [b setBackgroundImage:[self sendButtonImage:YES] forState:UIControlStateHighlighted];
    b.adjustsImageWhenHighlighted = NO;
    return b;
}

+ (BOOL)emojiRenders:(NSString *)emoji {
    static NSMutableDictionary *cache;
    static CTFontRef font;
    static BOOL haveFont;
    if (!cache) {
        cache = [NSMutableDictionary dictionary];
        font = CTFontCreateWithName(CFSTR("AppleColorEmoji"), 20, NULL);
        // Tên sai thì CoreText trả phông khác — khi đó không dò được, coi như vẽ được
        CFStringRef ps = font ? CTFontCopyPostScriptName(font) : NULL;
        haveFont = ps && CFStringCompare(ps, CFSTR("AppleColorEmoji"), 0) == kCFCompareEqualTo;
        if (ps) CFRelease(ps);
    }
    if (!emoji.length) return NO;
    NSNumber *c = [cache objectForKey:emoji];
    if (c) return c.boolValue;
    NSString *s = [emoji stringByReplacingOccurrencesOfString:@"\uFE0F" withString:@""];
    BOOL ok = s.length > 0 && [s rangeOfString:@"\u200D"].location == NSNotFound;
    if (ok && haveFont) {
        NSUInteger n = s.length;
        unichar *chars = malloc(n * sizeof(unichar));
        CGGlyph *glyphs = malloc(n * sizeof(CGGlyph));
        [s getCharacters:chars range:NSMakeRange(0, n)];
        ok = CTFontGetGlyphsForCharacters(font, chars, glyphs, (CFIndex)n);
        free(chars);
        free(glyphs);
    }
    [cache setObject:@(ok) forKey:emoji];
    return ok;
}

+ (NSString *)dropMissingEmoji:(NSString *)s {
    if (![s isKindOfClass:[NSString class]] || !s.length) return s;
    // Nhanh: không có ký tự ngoài BMP (emoji mới đều ở đó) → giữ nguyên
    BOOL astral = NO;
    for (NSUInteger i = 0; i < s.length && !astral; i++) astral = CFStringIsSurrogateHighCharacter([s characterAtIndex:i]);
    if (!astral) return s;
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    __block BOOL dropSpace = NO;
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByComposedCharacterSequences
                       usingBlock:^(NSString *sub, NSRange r, NSRange er, BOOL *stop) {
        if (dropSpace && [sub isEqual:@" "]) {
            dropSpace = NO;
            return;
        }
        dropSpace = NO;
        if (CFStringIsSurrogateHighCharacter([sub characterAtIndex:0]) && ![self emojiRenders:sub]) {
            dropSpace = YES;
            return;
        }
        [out appendString:sub];
    }];
    NSString *t = [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return t.length ? t : s;
}

+ (NSString *)reactionGlyph:(NSString *)emoji {
    if (!emoji.length) return @"•";
    if ([self emojiRenders:emoji]) return emoji;
    static NSDictionary *near;
    if (!near) {
        near = @{@"🥰": @"😍", @"🤩": @"😍", @"🤯": @"😱", @"🤬": @"😡", @"🤮": @"😷", @"🤔": @"😕", @"🤡": @"👹",
                 @"🥱": @"😪", @"🥴": @"😵", @"🤣": @"😂", @"🤨": @"😒", @"🤓": @"😎", @"🤗": @"😊", @"🫡": @"👮",
                 @"🤝": @"👍", @"🤪": @"😜", @"🤷‍♂": @"💁", @"🤷": @"💁", @"🤷‍♀": @"💁", @"🦄": @"🐴", @"🕊": @"🐦",
                 @"🌭": @"🍔", @"❤‍🔥": @"❤", @"👨‍💻": @"💻", @"✍": @"📝", @"🖕": @"👎", @"🫶": @"❤", @"🥹": @"😢",
                 @"🙂": @"😊", @"🙃": @"😜", @"🤭": @"😁", @"🫠": @"😵", @"🥳": @"🎉", @"🤑": @"💰", @"🥺": @"😢"};
    }
    NSString *alt = [near objectForKey:[emoji stringByReplacingOccurrencesOfString:@"\uFE0F" withString:@""]];
    return alt && [self emojiRenders:alt] ? alt : @"•";
}

@end
