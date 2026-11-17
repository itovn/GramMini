#import "GMMap.h"
#import <CoreLocation/CoreLocation.h>
#import "GMCompat.h"
#import "GMCore.h"
#import "GMTheme.h"
#import "GMLog.h"

static UIColor *GMHexColor(unsigned rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0 green:((rgb >> 8) & 0xFF) / 255.0 blue:(rgb & 0xFF) / 255.0 alpha:1];
}

/// Ghim đỏ; mũi ghim ở giữa cạnh dưới ảnh.
static UIImage *GMPinImage(void) {
    static UIImage *img;
    if (img) return img;
    CGSize s = CGSizeMake(24, 40);
    UIGraphicsBeginImageContextWithOptions(s, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, 1), 2, [UIColor colorWithWhite:0 alpha:0.4].CGColor);
    [GMHexColor(0x5A6670) set];
    CGContextFillRect(ctx, CGRectMake(11, 14, 2, 24));
    [GMHexColor(0xE0352B) set];
    CGContextFillEllipseInRect(ctx, CGRectMake(3, 1, 18, 18));
    [[UIColor colorWithWhite:1 alpha:0.6] set];
    CGContextFillEllipseInRect(ctx, CGRectMake(8, 5, 6, 6));
    img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

static double GMWorld(NSInteger z) {
    return 256.0 * (double)(1 << z);
}

/// Toạ độ điểm trên «bản đồ thế giới» mức phóng z (Web Mercator, đơn vị = điểm ảnh của ô 256).
static CGPoint GMWorldPoint(double lat, double lng, NSInteger z) {
    double w = GMWorld(z);
    double r = MAX(-85, MIN(85, lat)) * M_PI / 180;
    return CGPointMake((lng + 180) / 360 * w, (1 - log(tan(r) + 1 / cos(r)) / M_PI) / 2 * w);
}

#pragma mark - Ảnh bản đồ nhỏ (bong bóng)

static NSCache *GMSnapCache(void) {
    static NSCache *c;
    if (!c) {
        c = [[NSCache alloc] init];
        c.countLimit = 40;
    }
    return c;
}

static NSString *GMSnapKey(double lat, double lng, CGSize size) {
    return [NSString stringWithFormat:@"%.5f,%.5f,%.0fx%.0f", lat, lng, size.width, size.height];
}

UIImage *GMMapSnapshotCached(double lat, double lng, CGSize size) {
    return [GMSnapCache() objectForKey:GMSnapKey(lat, lng, size)];
}

void GMMapSnapshot(double lat, double lng, CGSize size, NSString *title, void (^done)(UIImage *)) {
    NSString *key = GMSnapKey(lat, lng, size);
    UIImage *hit = [GMSnapCache() objectForKey:key];
    if (hit) {
        done(hit);
        return;
    }
    const NSInteger z = 15;
    CGPoint c = GMWorldPoint(lat, lng, z);
    double left = c.x - size.width / 2, top = c.y - size.height / 2;
    NSInteger n = 1 << z;
    NSMutableArray *tiles = [NSMutableArray array];  // @[x, y, wx]
    for (NSInteger ty = (NSInteger)floor(top / 256); ty * 256 < top + size.height; ty++) {
        if (ty < 0 || ty >= n) continue;
        for (NSInteger tx = (NSInteger)floor(left / 256); tx * 256 < left + size.width; tx++) {
            [tiles addObject:@[@(tx), @(ty), @(((tx % n) + n) % n)]];
        }
    }
    NSMutableDictionary *got = [NSMutableDictionary dictionary];
    __block NSUInteger pending = tiles.count;
    void (^finish)(void) = ^{
        UIGraphicsBeginImageContextWithOptions(size, YES, 0);
        [GMHexColor(0xE8E4DC) setFill];
        UIRectFill(CGRectMake(0, 0, size.width, size.height));
        for (NSArray *t in tiles) {
            UIImage *img = [got objectForKey:[NSString stringWithFormat:@"%@/%@", [t objectAtIndex:0], [t objectAtIndex:1]]];
            [img drawInRect:CGRectMake(floor([[t objectAtIndex:0] integerValue] * 256 - left),
                                       floor([[t objectAtIndex:1] integerValue] * 256 - top), 256, 256)];
        }
        UIImage *pin = GMPinImage();
        [pin drawAtPoint:CGPointMake(floor(size.width / 2 - pin.size.width / 2), floor(size.height / 2 - pin.size.height + 2))];
        if (title.length) {
            UIFont *f = [UIFont boldSystemFontOfSize:13];
            [[UIColor colorWithWhite:1 alpha:0.85] setFill];
            UIRectFill(CGRectMake(0, size.height - 24, size.width, 24));
            [[UIColor colorWithWhite:0.15 alpha:1] set];
            [title drawInRect:CGRectMake(8, size.height - 20, size.width - 16, 18) withFont:f lineBreakMode:GMTailTruncation];
        }
        UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        if (got.count == tiles.count) [GMSnapCache() setObject:out forKey:key];  // thiếu ô (mất mạng) thì không đệm
        done(out);
    };
    if (!tiles.count) {
        finish();
        return;
    }
    for (NSArray *t in tiles) {
        [GMCore call:@"map.tile" args:@{@"z": @(z), @"x": [t objectAtIndex:2], @"y": [t objectAtIndex:1]} done:^(id ok, NSDictionary *err) {
            UIImage *img = GMVal(ok, @"path") ? [UIImage imageWithContentsOfFile:GMVal(ok, @"path")] : nil;
            if (img) [got setObject:img forKey:[NSString stringWithFormat:@"%@/%@", [t objectAtIndex:0], [t objectAtIndex:1]]];
            if (--pending == 0) finish();
        }];
    }
}

#pragma mark - Bản đồ ô OpenStreetMap

/// Bản đồ ô OSM: tâm (vĩ độ, kinh độ), mức phóng 3–18, kéo để di chuyển. Ghim cố định ở giữa.
@interface GMOSMView : UIView
@property (nonatomic, assign) double lat, lng;
@property (nonatomic, assign) NSInteger zoom;
@property (nonatomic, copy) void (^onMove)(double lat, double lng);  // sau khi kéo / phóng xong
- (void)centerLat:(double)lat lng:(double)lng;
@end

@implementation GMOSMView {
    NSMutableDictionary *_tiles;  // "z/x/y/tx" → UIImageView
    UIView *_layer0;
    UIImageView *_pin;
    UILabel *_credit;
}

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.clipsToBounds = YES;
        self.backgroundColor = GMHexColor(0xE8E4DC);
        _zoom = 16;
        _tiles = [NSMutableDictionary dictionary];
        _layer0 = [[UIView alloc] initWithFrame:self.bounds];
        _layer0.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_layer0];
        _pin = [[UIImageView alloc] initWithImage:GMPinImage()];
        [self addSubview:_pin];
        _credit = [[UILabel alloc] init];
        _credit.font = [UIFont systemFontOfSize:10];
        _credit.textColor = GMHexColor(0x333333);
        _credit.text = @" © OpenStreetMap ";
        _credit.backgroundColor = [UIColor colorWithWhite:1 alpha:0.75];
        [_credit sizeToFit];
        [self addSubview:_credit];
        for (int i = 0; i < 2; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeRoundedRect];
            [b setTitle:i == 0 ? @"+" : @"−" forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont boldSystemFontOfSize:22];
            b.tag = i == 0 ? 1 : -1;
            [b addTarget:self action:@selector(zoomTap:) forControlEvents:UIControlEventTouchUpInside];
            [self addSubview:b];
        }
        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
    }
    return self;
}

- (void)centerLat:(double)lat lng:(double)lng {
    self.lat = MAX(-85, MIN(85, lat));
    self.lng = lng;
    [self setNeedsLayout];
}

- (void)setWorldPoint:(CGPoint)p {
    double w = GMWorld(self.zoom);
    double x = fmod(fmod(p.x, w) + w, w), y = MAX(0, MIN(w, p.y));
    self.lng = x / w * 360 - 180;
    self.lat = atan(sinh(M_PI * (1 - 2 * y / w))) * 180 / M_PI;
}

- (void)zoomTap:(UIButton *)b {
    NSInteger z = MAX(3, MIN(18, self.zoom + b.tag));
    if (z == self.zoom) return;
    self.zoom = z;
    [self setNeedsLayout];
    if (self.onMove) self.onMove(self.lat, self.lng);
}

- (void)pan:(UIPanGestureRecognizer *)g {
    CGPoint d = [g translationInView:self];
    [g setTranslation:CGPointZero inView:self];
    CGPoint p = GMWorldPoint(self.lat, self.lng, self.zoom);
    [self setWorldPoint:CGPointMake(p.x - d.x, p.y - d.y)];
    [self setNeedsLayout];
    if (g.state == UIGestureRecognizerStateEnded && self.onMove) self.onMove(self.lat, self.lng);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize s = self.bounds.size;
    CGPoint c = GMWorldPoint(self.lat, self.lng, self.zoom);
    double left = c.x - s.width / 2, top = c.y - s.height / 2;
    NSInteger n = 1 << self.zoom;
    NSMutableSet *want = [NSMutableSet set];
    for (NSInteger ty = (NSInteger)floor(top / 256); ty * 256 < top + s.height; ty++) {
        if (ty < 0 || ty >= n) continue;
        for (NSInteger tx = (NSInteger)floor(left / 256); tx * 256 < left + s.width; tx++) {
            NSInteger wx = ((tx % n) + n) % n;  // vòng qua kinh tuyến 180
            NSString *key = [NSString stringWithFormat:@"%ld/%ld/%ld/%ld", (long)self.zoom, (long)wx, (long)ty, (long)tx];
            [want addObject:key];
            UIImageView *iv = [_tiles objectForKey:key];
            if (!iv) {
                iv = [[UIImageView alloc] init];
                [_tiles setObject:iv forKey:key];
                [_layer0 addSubview:iv];
                [self loadTile:iv z:self.zoom x:wx y:ty key:key];
            }
            iv.frame = CGRectMake(floor(tx * 256 - left), floor(ty * 256 - top), 256, 256);
        }
    }
    for (NSString *key in _tiles.allKeys) {
        if (![want containsObject:key]) {
            [[_tiles objectForKey:key] removeFromSuperview];
            [_tiles removeObjectForKey:key];
        }
    }
    _pin.center = CGPointMake(floorf(s.width / 2), floorf(s.height / 2) - _pin.bounds.size.height / 2 + 2);
    _credit.frame = CGRectMake(s.width - _credit.bounds.size.width - 4, s.height - _credit.bounds.size.height - 4,
                               _credit.bounds.size.width, _credit.bounds.size.height);
    CGFloat by = 10;
    for (UIView *v in self.subviews) {
        if ([v isKindOfClass:[UIButton class]]) {
            v.frame = CGRectMake(s.width - 52, by, 42, 42);
            by += 50;
        }
    }
}

- (void)loadTile:(UIImageView *)iv z:(NSInteger)z x:(NSInteger)x y:(NSInteger)y key:(NSString *)key {
    __weak GMOSMView *ws = self;
    [GMCore call:@"map.tile" args:@{@"z": @(z), @"x": @(x), @"y": @(y)} done:^(id ok, NSDictionary *err) {
        NSString *path = GMVal(ok, @"path");
        GMOSMView *s = ws;
        if (!path.length || !s || [s->_tiles objectForKey:key] != iv) return;
        UIImage *img = [UIImage imageWithContentsOfFile:path];
        if (img) iv.image = img;
    }];
}

@end

#pragma mark - Màn bản đồ

@interface GMMapViewController () <CLLocationManagerDelegate>
@end

@implementation GMMapViewController {
    GMOSMView *_map;
    CLLocationManager *_lm;
    UIView *_panel;
    UILabel *_titleLabel, *_addrLabel;
    double _lat, _lng;
    NSString *_placeTitle;
    void (^_done)(double, double);
    BOOL _picker, _located;
    NSUInteger _lookupGen;
}

- (instancetype)initWithLat:(double)lat lng:(double)lng title:(NSString *)title {
    if ((self = [super init])) {
        _lat = lat;
        _lng = lng;
        _placeTitle = [title copy];
        self.title = @"Vị trí";
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}

- (instancetype)initPickerWithDone:(void (^)(double, double))done {
    if ((self = [super init])) {
        _picker = YES;
        _done = [done copy];
        _lat = 21.0285;  // chờ định vị: Hà Nội
        _lng = 105.8542;
        self.title = @"Gửi vị trí";
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}

- (UILabel *)label:(CGFloat)size bold:(BOOL)bold color:(UIColor *)c {
    UILabel *l = [[UILabel alloc] init];
    l.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    l.textColor = c;
    l.backgroundColor = [UIColor clearColor];
    return l;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [GMTheme background];
    CGRect b = self.view.bounds;
    CGFloat panelH = _picker ? 116 : 70;
    _map = [[GMOSMView alloc] initWithFrame:CGRectMake(0, 0, b.size.width, b.size.height - panelH)];
    _map.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _map.zoom = _picker ? 15 : 16;
    [_map centerLat:_lat lng:_lng];
    [self.view addSubview:_map];
    _panel = [[UIView alloc] initWithFrame:CGRectMake(0, b.size.height - panelH, b.size.width, panelH)];
    _panel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    _panel.backgroundColor = [GMTheme cellBackground];
    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, 0, b.size.width, 1)];
    line.backgroundColor = [GMTheme separator];
    line.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_panel addSubview:line];
    _titleLabel = [self label:16 bold:YES color:[GMTheme text]];
    _titleLabel.frame = CGRectMake(14, 10, b.size.width - 28, 20);
    _titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_panel addSubview:_titleLabel];
    _addrLabel = [self label:13 bold:NO color:[GMTheme secondaryText]];
    _addrLabel.numberOfLines = 2;
    _addrLabel.frame = CGRectMake(14, 31, b.size.width - 28, 34);
    _addrLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_panel addSubview:_addrLabel];
    [self.view addSubview:_panel];
    __weak GMMapViewController *ws = self;
    if (_picker) {
        _titleLabel.text = @"Kéo bản đồ để chọn chỗ khác";
        _addrLabel.text = @"Đang tìm vị trí của bạn…";
        UIButton *send = [GMTheme button:@"Gửi vị trí này"];
        send.frame = CGRectMake(14, 68, b.size.width - 28, 40);
        send.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [send addTarget:self action:@selector(send) forControlEvents:UIControlEventTouchUpInside];
        [_panel addSubview:send];
        _map.onMove = ^(double lat, double lng) {
            GMMapViewController *s = ws;
            if (!s) return;
            s->_lat = lat;
            s->_lng = lng;
            s->_located = YES;  // người dùng đã tự chọn chỗ → không nhảy về vị trí GPS nữa
            [s lookup];
        };
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Vị trí tôi" style:UIBarButtonItemStyleBordered
                                                                                 target:self action:@selector(locateMe)];
        [self locateMe];
    } else {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Mở…" style:UIBarButtonItemStyleBordered
                                                                                 target:self action:@selector(openSheet)];
        _titleLabel.text = _placeTitle.length ? _placeTitle : @"Vị trí được chia sẻ";
        [self lookup];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_lm stopUpdatingLocation];
}

- (void)dealloc {
    _lm.delegate = nil;
}

- (void)locateMe {
    if (!_lm) {
        _lm = [[CLLocationManager alloc] init];
        _lm.delegate = self;
        _lm.desiredAccuracy = kCLLocationAccuracyBest;
    }
    _located = NO;
    [_lm startUpdatingLocation];
}

/// Địa chỉ của điểm giữa bản đồ (chờ 0,8 giây sau lần kéo cuối — Nominatim chỉ cho ~1 lần / giây).
- (void)lookup {
    _addrLabel.text = [NSString stringWithFormat:@"%.5f, %.5f", _lat, _lng];
    NSUInteger gen = ++_lookupGen;
    double lat = _lat, lng = _lng;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen != _lookupGen) return;
        [GMCore call:@"map.address" args:@{@"lat": @(lat), @"lng": @(lng)} done:^(id ok, NSDictionary *err) {
            NSString *a = GMVal(ok, @"address");
            if (gen != _lookupGen || !a.length) return;
            _addrLabel.text = a;
        }];
    });
}

- (void)gotLocation:(CLLocation *)loc {
    if (_located || !loc) return;
    _located = YES;
    [_lm stopUpdatingLocation];
    _lat = loc.coordinate.latitude;
    _lng = loc.coordinate.longitude;
    _map.zoom = 16;
    [_map centerLat:_lat lng:_lng];
    [self lookup];
}

- (void)locationManager:(CLLocationManager *)m didUpdateLocations:(NSArray *)locations {
    [self gotLocation:[locations lastObject]];
}

- (void)locationManager:(CLLocationManager *)m didUpdateToLocation:(CLLocation *)loc fromLocation:(CLLocation *)old {
    [self gotLocation:loc];  // iOS 5
}

- (void)locationManager:(CLLocationManager *)m didFailWithError:(NSError *)err {
    if (err.code == kCLErrorDenied) {
        _addrLabel.text = @"GramMini chưa được dùng định vị: bật trong Cài đặt → Quyền riêng tư → Dịch vụ định vị, hoặc kéo bản đồ để chọn.";
    }
}

- (void)send {
    void (^done)(double, double) = _done;
    double lat = _lat, lng = _lng;
    [self.navigationController popViewControllerAnimated:YES];
    if (done) done(lat, lng);
}

- (void)openSheet {
    UIActionSheet *s = [[UIActionSheet alloc] initWithTitle:[NSString stringWithFormat:@"%.6f, %.6f", _lat, _lng] delegate:self
                                          cancelButtonTitle:nil destructiveButtonTitle:nil
                                          otherButtonTitles:@"Chép toạ độ", @"Chép đường dẫn Google Maps", @"Mở bằng app Bản đồ", nil];
    s.cancelButtonIndex = [s addButtonWithTitle:@"Huỷ"];
    [s showInView:self.view];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)i {
    if (i == 0) {
        [UIPasteboard generalPasteboard].string = [NSString stringWithFormat:@"%.6f, %.6f", _lat, _lng];
    } else if (i == 1) {
        [UIPasteboard generalPasteboard].string = [NSString stringWithFormat:@"https://maps.google.com/maps?q=%.6f,%.6f", _lat, _lng];
    } else if (i == 2) {
        NSString *q = [(_placeTitle.length ? _placeTitle : @"Vị trí") stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        NSString *u = GMOldIOS() ? [NSString stringWithFormat:@"http://maps.google.com/maps?q=%.6f,%.6f", _lat, _lng]
                                 : [NSString stringWithFormat:@"http://maps.apple.com/?ll=%.6f,%.6f&q=%@", _lat, _lng, q];
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:u]];
    }
}

@end
