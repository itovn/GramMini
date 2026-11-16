#import "GMLottieView.h"
#import "GMLog.h"

extern void *gm_lottie_open(const char *path);
extern int gm_lottie_info(const void *anim, double *fps, int *frames, int *w, int *h);
extern int gm_lottie_render(const void *anim, int frame, unsigned char *buf, int width, int height);
extern void gm_lottie_close(void *anim);

/// Hàng đợi vẽ dùng chung (nối tiếp): đóng hoạt hình cũng xếp vào đây → không đóng lúc đang vẽ.
static dispatch_queue_t GMLottieQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("vn.grammini.lottie", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

@implementation GMLottieView {
    void *_anim;
    int _frames, _w, _h;
    double _fps;
    double _pos;        // khung hiện tại (số thực — bước theo fps gốc / fps phát)
    double _step;
    NSTimer *_timer;
    BOOL _busy, _shown;
    NSUInteger _gen;    // đổi tệp / dừng → bỏ khung vẽ dở của tệp cũ
    int _loops;         // số lượt đã chạy (đủ kGMMaxLoops thì dừng ở khung cuối — đỡ hao pin)
}

/// Chạy bấy nhiêu lượt rồi dừng (vẽ một khung 256 px tốn ~15 ms trên iPhone 5 — chạy mãi thì nóng máy, hao pin).
static const int kGMMaxLoops = 5;

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.layer.contentsGravity = kCAGravityResizeAspect;
    }
    return self;
}

- (void)dealloc {
    [_timer invalidate];
    [self closeAnim];
}

- (void)closeAnim {
    void *a = _anim;
    _anim = NULL;
    if (a) dispatch_async(GMLottieQueue(), ^{ gm_lottie_close(a); });
}

- (void)stop {
    _gen++;
    [_timer invalidate];
    _timer = nil;
    [self closeAnim];
    _path = nil;
    _shown = NO;
    _busy = NO;
    self.layer.contents = nil;
}

- (void)playFile:(NSString *)path {
    if ([path isEqual:_path] && _anim) {
        [self updateTimer];
        return;
    }
    [self stop];
    _path = [path copy];
    NSUInteger gen = _gen;
    // Đọc + giải nén JSON ở nền (vài chục ms trên máy cũ)
    dispatch_async(GMLottieQueue(), ^{
        void *a = gm_lottie_open(path.fileSystemRepresentation);
        double fps = 0;
        int frames = 0, w = 0, h = 0;
        if (a) gm_lottie_info(a, &fps, &frames, &w, &h);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != _gen) {
                if (a) dispatch_async(GMLottieQueue(), ^{ gm_lottie_close(a); });
                return;
            }
            if (!a || frames <= 0) {
                GMLog(@"sticker động: không đọc được %@", path.lastPathComponent);
                if (a) dispatch_async(GMLottieQueue(), ^{ gm_lottie_close(a); });
                return;
            }
            _anim = a;
            _fps = fps > 0 ? fps : 30;
            _frames = frames;
            _w = w;
            _h = h;
            double play = MIN(_fps, 30);
            _step = _fps / play;
            _pos = 0;
            _loops = 0;
            [self renderNext];  // khung đầu ngay
            [self updateTimer];
        });
    });
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) _loops = 0;  // hiện lại (cuộn tới, quay lại màn chat) → chạy tiếp
    [self updateTimer];
}

- (void)updateTimer {
    BOOL want = _anim && self.window && !self.hidden && _loops < kGMMaxLoops;
    if (want && !_timer) {
        double play = _step > 0 ? _fps / _step : 30;
        // Chế độ mặc định của run loop: đứng khi đang cuộn bảng (cuộn mượt hơn trên máy cũ)
        _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / play target:self selector:@selector(tick) userInfo:nil repeats:YES];
    } else if (!want && _timer) {
        [_timer invalidate];
        _timer = nil;
    }
}

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    [self updateTimer];
}

- (void)tick {
    if (!self.window || [UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
    [self renderNext];
}

/// Vẽ khung kế tiếp ở nền rồi đặt lên layer. Khung trước chưa vẽ xong thì bỏ lượt này (máy chậm: tự giảm khung / giây).
- (void)renderNext {
    if (!_anim || _busy) return;
    CGFloat scale = [UIScreen mainScreen].scale;
    CGSize b = self.bounds.size;
    int pw = (int)MIN(256, ceil(b.width * scale)), ph = (int)MIN(256, ceil(b.height * scale));
    if (pw < 8 || ph < 8) return;
    _busy = YES;
    void *a = _anim;
    int frame = (int)floor(_pos) % MAX(_frames, 1);
    _pos += _step;
    if (_pos >= _frames) {
        _pos -= _frames;
        if (++_loops >= kGMMaxLoops) {
            _pos = _frames - 1;  // dừng ở khung cuối (khung này vẫn vẽ)
            dispatch_async(dispatch_get_main_queue(), ^{ [self updateTimer]; });
        }
    }
    NSUInteger gen = _gen;
    dispatch_async(GMLottieQueue(), ^{
        size_t len = (size_t)pw * ph * 4;
        unsigned char *buf = malloc(len);
        CGImageRef img = NULL;
#ifdef DEBUG
        long long t0 = GMNowMs();
#endif
        int rc = buf ? gm_lottie_render(a, frame, buf, pw, ph) : -1;
#ifdef DEBUG
        // Bản thử: ghi thời gian vẽ trung bình mỗi 150 khung (mọi sticker cộng chung)
        static long long sum, n;
        sum += GMNowMs() - t0;
        if (++n % 150 == 0) GMLog(@"sticker động: vẽ %dx%d trung bình %.1f ms / khung", pw, ph, (double)sum / 150), sum = 0;
#endif
        if (rc == 0) {
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            // RGBA đã nhân alpha (tiny-skia) — đúng thứ tự byte của kCGImageAlphaPremultipliedLast | 32Big
            CGContextRef ctx = CGBitmapContextCreate(buf, pw, ph, 8, pw * 4, cs,
                                                     kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
            if (ctx) {
                img = CGBitmapContextCreateImage(ctx);
                CGContextRelease(ctx);
            }
            CGColorSpaceRelease(cs);
        }
        free(buf);
        dispatch_async(dispatch_get_main_queue(), ^{
            _busy = NO;
            if (gen == _gen && img) {
                self.layer.contents = (__bridge id)img;
                if (!_shown) {
                    _shown = YES;
                    if (self.firstFrame) self.firstFrame();
                }
            }
            if (img) CGImageRelease(img);
        });
    });
}

@end
