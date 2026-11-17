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

/// Ảnh do lõi trả cần scale nào: màn Retina → 2.
static NSInteger GMMapScale(void) {
    return [UIScreen mainScreen].scale > 1 ? 2 : 1;
}

void GMMapSnapshot(double lat, double lng, NSString *hash, CGSize size, NSString *title, void (^done)(UIImage *)) {
    NSString *key = GMSnapKey(lat, lng, size);
    UIImage *hit = [GMSnapCache() objectForKey:key];
    if (hit) {
        done(hit);
        return;
    }
    NSMutableDictionary *args = [NSMutableDictionary dictionaryWithDictionary:@{
        @"lat": @(lat), @"lng": @(lng), @"w": @((NSInteger)ceil(size.width)), @"h": @((NSInteger)ceil(size.height)),
        @"zoom": @15, @"scale": @(GMMapScale())}];
    if ([hash isKindOfClass:[NSString class]] && hash.length) [args setObject:hash forKey:@"hash"];
    [GMCore call:@"map.static" args:args done:^(id ok, NSDictionary *err) {
        UIImage *map = GMVal(ok, @"path") ? [UIImage imageWithContentsOfFile:GMVal(ok, @"path")] : nil;
        UIGraphicsBeginImageContextWithOptions(size, YES, 0);
        [GMHexColor(0xE8E4DC) setFill];
        UIRectFill(CGRectMake(0, 0, size.width, size.height));
        [map drawInRect:CGRectMake(0, 0, size.width, size.height)];
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
        if (map) [GMSnapCache() setObject:out forKey:key];  // chưa có ảnh (mất mạng) thì không đệm
        done(out);
    }];
}

#pragma mark - Bản đồ một ảnh (Telegram vẽ)

/// Mức phóng Telegram vẽ được (`inputWebFileGeoPointLocation`: 13–20).
static const NSInteger kMinZoom = 13, kMaxZoom = 20;

/// Bản đồ: mỗi lần dừng tay xin Telegram MỘT ảnh vừa khung (lõi `map.static`) — Telegram giới hạn tốc độ (dồn hơn ~2 ảnh thì
/// chờ 15–30 giây) nên không ghép ô. Kéo / phóng: ảnh đang có trượt / co giãn theo, dừng 0,35 giây → xin ảnh mới. Ghim cố định
/// ở giữa; tâm (vĩ độ, kinh độ), mức phóng 13–20.
@interface GMStaticMapView : UIView
@property (nonatomic, assign) double lat, lng;
@property (nonatomic, assign) NSInteger zoom;
@property (nonatomic, copy) void (^onMove)(double lat, double lng);  // sau khi kéo / phóng xong
- (void)centerLat:(double)lat lng:(double)lng;
- (void)debugPan:(CGPoint)d end:(BOOL)end;
@end

@implementation GMStaticMapView {
    UIImageView *_img;
    double _imgLat, _imgLng;  // tâm, mức phóng, cỡ (điểm) của ảnh đang hiện; _imgZoom 0 = chưa có ảnh
    NSInteger _imgZoom;
    CGSize _imgSize;
    NSString *_want;  // ảnh đang hiện / đang xin (tâm, mức phóng, cỡ)
    NSUInteger _gen;
    NSInteger _fails;
    BOOL _dragging;
    UIImageView *_pin;
    UILabel *_credit;
    UIActivityIndicatorView *_spin;
}

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.clipsToBounds = YES;
        self.backgroundColor = GMHexColor(0xE8E4DC);
        _zoom = 16;
        _img = [[UIImageView alloc] init];
        _img.hidden = YES;
        [self addSubview:_img];
        _pin = [[UIImageView alloc] initWithImage:GMPinImage()];
        [self addSubview:_pin];
        _credit = [[UILabel alloc] init];
        _credit.font = [UIFont systemFontOfSize:10];
        _credit.textColor = GMHexColor(0x333333);
        _credit.text = @" Bản đồ qua Telegram ";
        _credit.backgroundColor = [UIColor colorWithWhite:1 alpha:0.75];
        [_credit sizeToFit];
        [self addSubview:_credit];
        _spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
        _spin.hidesWhenStopped = YES;
        [self addSubview:_spin];
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

- (void)setZoom:(NSInteger)zoom {
    _zoom = MAX(kMinZoom, MIN(kMaxZoom, zoom));
    [self setNeedsLayout];
}

- (void)setWorldPoint:(CGPoint)p {
    double w = GMWorld(self.zoom);
    double x = fmod(fmod(p.x, w) + w, w), y = MAX(0, MIN(w, p.y));
    self.lng = x / w * 360 - 180;
    self.lat = atan(sinh(M_PI * (1 - 2 * y / w))) * 180 / M_PI;
}

- (void)zoomTap:(UIButton *)b {
    NSInteger z = MAX(kMinZoom, MIN(kMaxZoom, self.zoom + b.tag));
    if (z == self.zoom) return;
    self.zoom = z;
    if (self.onMove) self.onMove(self.lat, self.lng);
}

- (void)pan:(UIPanGestureRecognizer *)g {
    CGPoint d = [g translationInView:self];
    [g setTranslation:CGPointZero inView:self];
    CGPoint p = GMWorldPoint(self.lat, self.lng, self.zoom);
    [self setWorldPoint:CGPointMake(p.x - d.x, p.y - d.y)];
    _dragging = g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged;
    [self setNeedsLayout];
    if (g.state == UIGestureRecognizerStateEnded && self.onMove) self.onMove(self.lat, self.lng);
}

/// Công cụ thử: như kéo tay một đoạn `d` (điểm); `end` = thả tay (xin ảnh mới).
- (void)debugPan:(CGPoint)d end:(BOOL)end {
    CGPoint p = GMWorldPoint(self.lat, self.lng, self.zoom);
    [self setWorldPoint:CGPointMake(p.x - d.x, p.y - d.y)];
    _dragging = !end;
    [self setNeedsLayout];
    if (end && self.onMove) self.onMove(self.lat, self.lng);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize s = self.bounds.size;
    _img.hidden = _imgZoom == 0;
    if (_imgZoom) {
        // ảnh đang có đặt theo toạ độ thế giới ở mức phóng hiện tại (kéo: trượt; phóng: co giãn quanh tâm của ảnh)
        double f = pow(2, (double)(self.zoom - _imgZoom)), w = GMWorld(self.zoom);
        CGPoint a = GMWorldPoint(_imgLat, _imgLng, self.zoom), c = GMWorldPoint(self.lat, self.lng, self.zoom);
        double dx = a.x - c.x;
        if (dx > w / 2) dx -= w;  // vòng qua kinh tuyến 180
        else if (dx < -w / 2) dx += w;
        CGSize is = CGSizeMake(_imgSize.width * f, _imgSize.height * f);
        _img.frame = CGRectMake(floor(s.width / 2 + dx - is.width / 2), floor(s.height / 2 + (a.y - c.y) - is.height / 2), is.width, is.height);
    }
    _pin.center = CGPointMake(floorf(s.width / 2), floorf(s.height / 2) - _pin.bounds.size.height / 2 + 2);
    _credit.frame = CGRectMake(s.width - _credit.bounds.size.width - 4, s.height - _credit.bounds.size.height - 4,
                               _credit.bounds.size.width, _credit.bounds.size.height);
    _spin.center = CGPointMake(18, s.height - 18);
    CGFloat by = 10;
    for (UIView *v in self.subviews) {
        if ([v isKindOfClass:[UIButton class]]) {
            v.frame = CGRectMake(s.width - 52, by, 42, 42);
            by += 50;
        }
    }
    if (!_dragging) [self scheduleFetch];
}

/// Cỡ ảnh xin (điểm): vừa khung, Telegram nhận 16–1024.
- (CGSize)wantSize {
    CGSize s = self.bounds.size;
    return CGSizeMake(MAX(16, MIN(1024, ceil(s.width))), MAX(16, MIN(1024, ceil(s.height))));
}

/// Tâm / mức phóng / cỡ đổi (đã dừng tay) → xin ảnh mới sau 0,35 giây (lần đổi sau huỷ lần trước).
- (void)scheduleFetch {
    if (self.bounds.size.width < 16 || self.bounds.size.height < 16) return;
    CGSize ws = [self wantSize];
    NSString *key = [NSString stringWithFormat:@"%.6f,%.6f,%ld,%.0fx%.0f", self.lat, self.lng, (long)self.zoom, ws.width, ws.height];
    if ([key isEqual:_want]) return;
    _want = key;
    _fails = 0;
    NSUInteger gen = ++_gen;
    __weak GMStaticMapView *wv = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        GMStaticMapView *v = wv;
        if (v && v->_gen == gen) [v fetch:gen];
    });
}

- (void)fetch:(NSUInteger)gen {
    double lat = self.lat, lng = self.lng;
    NSInteger z = self.zoom;
    CGSize ws = [self wantSize];
    [_spin startAnimating];
    __weak GMStaticMapView *wv = self;
    NSDictionary *args = @{@"lat": @(lat), @"lng": @(lng), @"w": @((NSInteger)ws.width), @"h": @((NSInteger)ws.height),
                           @"zoom": @(z), @"scale": @(GMMapScale())};
    [GMCore call:@"map.static" args:args done:^(id ok, NSDictionary *err) {
        GMStaticMapView *v = wv;
        if (!v || v->_gen != gen) return;  // đã kéo / phóng tiếp → ảnh mới hơn đang xin
        UIImage *img = GMVal(ok, @"path") ? [UIImage imageWithContentsOfFile:GMVal(ok, @"path")] : nil;
        if (img) {
            [v->_spin stopAnimating];
            v->_img.image = img;
            v->_imgLat = lat;
            v->_imgLng = lng;
            v->_imgZoom = z;
            v->_imgSize = ws;
            [v setNeedsLayout];
        } else if (v->_fails++ < 2) {
            // Telegram chậm / mất mạng: thử lại sau 3 giây (tối đa 2 lần; kéo / phóng tiếp thì xin lại từ đầu)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                GMStaticMapView *v2 = wv;
                if (v2 && v2->_gen == gen) [v2 fetch:gen];
            });
        } else {
            [v->_spin stopAnimating];
        }
    }];
}

@end

#pragma mark - Màn bản đồ

@interface GMMapViewController () <CLLocationManagerDelegate>
@end

@implementation GMMapViewController {
    GMStaticMapView *_map;
    CLLocationManager *_lm;
    UIView *_panel;
    UILabel *_titleLabel, *_addrLabel;
    double _lat, _lng;
    NSString *_placeTitle, *_placeAddress;
    void (^_done)(double, double);
    BOOL _picker, _located;
    NSUInteger _lookupGen;
    NSString *_address;  // địa chỉ đã tra cho điểm hiện tại
}

- (instancetype)initWithLat:(double)lat lng:(double)lng title:(NSString *)title {
    return [self initWithLat:lat lng:lng title:title address:nil];
}

- (instancetype)initWithLat:(double)lat lng:(double)lng title:(NSString *)title address:(NSString *)address {
    if ((self = [super init])) {
        _lat = lat;
        _lng = lng;
        _placeTitle = [title isKindOfClass:[NSString class]] ? [title copy] : nil;
        _placeAddress = [address isKindOfClass:[NSString class]] && [address length] ? [address copy] : nil;
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
    _map = [[GMStaticMapView alloc] initWithFrame:CGRectMake(0, 0, b.size.width, b.size.height - panelH)];
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
    _addrLabel.userInteractionEnabled = YES;  // chạm → tra địa chỉ (chỉ khi người dùng muốn: gửi toạ độ cho OpenStreetMap)
    [_addrLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(addressTapped)]];
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
            [s pointChanged];
        };
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Vị trí tôi" style:UIBarButtonItemStyleBordered
                                                                                 target:self action:@selector(locateMe)];
        [self locateMe];
    } else {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Mở…" style:UIBarButtonItemStyleBordered
                                                                                 target:self action:@selector(openSheet)];
        _titleLabel.text = _placeTitle.length ? _placeTitle : @"Vị trí được chia sẻ";
        _address = _placeAddress;
        [self pointChanged];
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

/// Điểm giữa bản đồ đổi: hiện toạ độ + «chạm để tra địa chỉ» (không tự tra: Nominatim của OSM sẽ biết IP + chỗ đang xem).
- (void)pointChanged {
    ++_lookupGen;
    if (_address.length && !_picker) {
        _addrLabel.text = _address;
        return;
    }
    _address = nil;
    _addrLabel.text = [NSString stringWithFormat:@"%.5f, %.5f · chạm để tra địa chỉ", _lat, _lng];
}

/// Chạm dòng địa chỉ: tra địa chỉ của điểm giữa bản đồ (OpenStreetMap — Telegram không có dịch vụ tra địa chỉ).
- (void)addressTapped {
    if (_address.length) return;
    NSUInteger gen = ++_lookupGen;
    double lat = _lat, lng = _lng;
    _addrLabel.text = @"Đang tra địa chỉ (OpenStreetMap)…";
    [GMCore call:@"map.address" args:@{@"lat": @(lat), @"lng": @(lng)} done:^(id ok, NSDictionary *err) {
        if (gen != _lookupGen) return;
        NSString *a = GMVal(ok, @"address");
        if (a.length) {
            _address = a;
            _addrLabel.text = a;
        } else {
            _addrLabel.text = [NSString stringWithFormat:@"%.5f, %.5f · %@", lat, lng,
                               err ? @"không tra được, chạm để thử lại" : @"không có địa chỉ"];
        }
    }];
}

- (void)debugAddress {
    [self addressTapped];
}

- (void)debugZoom:(NSInteger)d {
    _map.zoom = _map.zoom + d;
}

- (void)debugPanX:(CGFloat)x y:(CGFloat)y end:(BOOL)end {
    [_map debugPan:CGPointMake(x, y) end:end];
}

- (void)gotLocation:(CLLocation *)loc {
    if (_located || !loc) return;
    _located = YES;
    [_lm stopUpdatingLocation];
    _lat = loc.coordinate.latitude;
    _lng = loc.coordinate.longitude;
    _map.zoom = 16;
    [_map centerLat:_lat lng:_lng];
    [self pointChanged];
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
