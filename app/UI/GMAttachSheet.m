#import "GMAttachSheet.h"
#import "GMContextMenu.h"
#import "GMTheme.h"
#import "GMLog.h"
#import <AssetsLibrary/AssetsLibrary.h>
#import <QuartzCore/QuartzCore.h>

static const NSInteger kMaxRecent = 60;
static const CGFloat kTabsH = 62, kHeadH = 54, kPad = 8;

@implementation GMAttachSheet {
    UIView *_host, *_panel, *_tabs;
    UIButton *_dim, *_sendBtn;
    UIImageView *_blur;
    UIScrollView *_grid;
    UILabel *_note;
    ALAssetsLibrary *_lib;  // giữ sống: ALAsset chỉ dùng được khi thư viện còn
    NSMutableArray *_assets;
    NSInteger _sel;
    BOOL _camera, _closing;
    void (^_pick)(GMAttachKind);
    void (^_photo)(UIImage *);
}

+ (GMAttachSheet *)showIn:(UIView *)host camera:(BOOL)camera pick:(void (^)(GMAttachKind))pick photo:(void (^)(UIImage *))photo {
    GMAttachSheet *s = [[GMAttachSheet alloc] initWithFrame:host.bounds];
    s->_host = host;
    s->_camera = camera;
    s->_pick = [pick copy];
    s->_photo = [photo copy];
    s->_sel = -1;
    [s build];
    [host addSubview:s];
    [s animateIn];
    [s loadAssets];
    return s;
}

- (void)build {
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    CGRect b = self.bounds;
    CGFloat W = b.size.width, H = b.size.height;
    BOOL dark = [GMTheme dark];
    UIImage *bl = [GMContextMenu blurredSnapshot:_host];
    if (bl) {
        _blur = [[UIImageView alloc] initWithFrame:b];
        _blur.image = bl;
        _blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_blur];
    }
    _dim = [UIButton buttonWithType:UIButtonTypeCustom];
    _dim.frame = b;
    _dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _dim.backgroundColor = [UIColor colorWithWhite:0 alpha:bl ? (dark ? 0.4 : 0.12) : (dark ? 0.55 : 0.35)];
    _dim.accessibilityLabel = @"Đóng";
    [_dim addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_dim];

    // Tấm kính nổi ở đáy, bo lớn
    CGFloat pw = MIN(W - 12, 500), ph = MIN(430, floor(H * 0.74));
    _panel = [[UIView alloc] initWithFrame:CGRectMake(floor((W - pw) / 2), H - ph - 6, pw, ph)];
    _panel.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleLeftMargin |
                              UIViewAutoresizingFlexibleRightMargin;
    UIImageView *glass = [[UIImageView alloc] initWithFrame:CGRectMake(-1, -0.5, pw + 2, ph + 3)];
    glass.image = [GMTheme glassSheet];
    [_panel addSubview:glass];
    UIView *clip = [[UIView alloc] initWithFrame:_panel.bounds];
    clip.clipsToBounds = YES;
    clip.layer.cornerRadius = 26;
    [_panel addSubview:clip];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake(10, 10, 34, 34);
    close.layer.cornerRadius = 17;
    close.backgroundColor = dark ? [UIColor colorWithWhite:1 alpha:0.14] : [UIColor colorWithWhite:0 alpha:0.075];
    [close setImage:[GMTheme icon:@"x" color:[GMTheme text]] forState:UIControlStateNormal];
    close.accessibilityLabel = @"Đóng";
    [close addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [clip addSubview:close];
    UIButton *title = [UIButton buttonWithType:UIButtonTypeCustom];
    title.frame = CGRectMake(54, 10, pw - 108, 34);
    [title setTitle:@"Gần đây" forState:UIControlStateNormal];
    [title setTitleColor:[GMTheme text] forState:UIControlStateNormal];
    title.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [title setImage:[GMTheme icon:@"down" color:[GMTheme text]] forState:UIControlStateNormal];
    // Chữ trước, mũi tên sau
    CGFloat tw = [@"Gần đây" sizeWithFont:title.titleLabel.font].width;
    title.titleEdgeInsets = UIEdgeInsetsMake(0, -26, 0, 26);
    title.imageEdgeInsets = UIEdgeInsetsMake(0, tw + 2, 0, -tw - 2);
    title.accessibilityLabel = @"Mọi ảnh và video";
    [title addTarget:self action:@selector(libraryTapped) forControlEvents:UIControlEventTouchUpInside];
    [clip addSubview:title];

    _grid = [[UIScrollView alloc] initWithFrame:CGRectMake(kPad, kHeadH, pw - 2 * kPad, ph - kHeadH)];
    _grid.contentInset = UIEdgeInsetsMake(0, 0, kTabsH + 2 * kPad, 0);
    _grid.scrollIndicatorInsets = _grid.contentInset;
    _grid.alwaysBounceVertical = YES;
    [clip addSubview:_grid];
    _note = [[UILabel alloc] initWithFrame:CGRectMake(20, 40, _grid.bounds.size.width - 40, 60)];
    _note.numberOfLines = 3;
    _note.textAlignment = GMAlignCenter;
    _note.font = [UIFont systemFontOfSize:15];
    _note.textColor = [GMTheme secondaryText];
    _note.backgroundColor = [UIColor clearColor];
    _note.text = @"Đang tải ảnh…";
    [_grid addSubview:_note];

    // Thanh dưới viên kính: các loại đính kèm khác
    _tabs = [[UIView alloc] initWithFrame:CGRectMake(kPad, ph - kPad - kTabsH, pw - 2 * kPad, kTabsH)];
    UIImageView *tg = [[UIImageView alloc] initWithFrame:CGRectMake(-1, -0.5, _tabs.bounds.size.width + 2, kTabsH + 3)];
    tg.image = [GMTheme glassImage:kTabsH + 3];
    [_tabs addSubview:tg];
    NSArray *tabs = @[@[@"photo", @"Thư viện"], @[@"file", @"Tệp"], @[@"location", @"Vị trí"], @[@"qr", @"Mã QR"],
                      @[@"card", @"Danh thiếp"]];
    CGFloat iw = (_tabs.bounds.size.width - 8) / tabs.count;
    for (NSUInteger i = 0; i < tabs.count; i++) {
        UIButton *t = [UIButton buttonWithType:UIButtonTypeCustom];
        t.frame = CGRectMake(4 + i * iw, 4, iw, kTabsH - 8);
        t.tag = 300 + i;
        UIImageView *ic = [[UIImageView alloc] initWithImage:[GMTheme icon:[[tabs objectAtIndex:i] objectAtIndex:0] color:[GMTheme text]]];
        ic.frame = CGRectMake(floor((iw - 26) / 2), 5, 26, 26);
        [t addSubview:ic];
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 33, iw, 14)];
        l.text = [[tabs objectAtIndex:i] objectAtIndex:1];
        l.font = [UIFont boldSystemFontOfSize:10];
        l.textColor = [GMTheme text];
        l.textAlignment = GMAlignCenter;
        l.backgroundColor = [UIColor clearColor];
        l.adjustsFontSizeToFitWidth = YES;
        [t addSubview:l];
        t.accessibilityLabel = l.text;
        [t addTarget:self action:@selector(tabTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_tabs addSubview:t];
    }
    [clip addSubview:_tabs];
    _sendBtn = [GMTheme button:@"Gửi ảnh"];
    _sendBtn.frame = CGRectMake(kPad + 20, ph - kPad - kTabsH + 9, pw - 2 * kPad - 40, 44);
    _sendBtn.hidden = YES;
    [_sendBtn addTarget:self action:@selector(debugSend) forControlEvents:UIControlEventTouchUpInside];
    [clip addSubview:_sendBtn];
    [self addSubview:_panel];
}

#pragma mark Ảnh gần đây

- (void)loadAssets {
    _assets = [NSMutableArray array];
    _lib = [[ALAssetsLibrary alloc] init];
    __weak GMAttachSheet *ws = self;
    NSMutableArray *found = _assets;
    [_lib enumerateGroupsWithTypes:ALAssetsGroupSavedPhotos usingBlock:^(ALAssetsGroup *group, BOOL *stop) {
        if (!group) {
            [ws layoutGrid];
            return;
        }
        [group setAssetsFilter:[ALAssetsFilter allPhotos]];
        NSInteger n = group.numberOfAssets;
        if (n <= 0) return;
        NSInteger from = MAX(0, n - kMaxRecent);
        [group enumerateAssetsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(from, n - from)]
                                options:NSEnumerationReverse
                             usingBlock:^(ALAsset *a, NSUInteger i, BOOL *st) {
                                 if (a) [found addObject:a];
                             }];
    } failureBlock:^(NSError *err) {
        GMLog(@"đính kèm: không đọc được Ảnh (%ld)", (long)err.code);
        [ws showNote:@"GramMini chưa được xem Ảnh.\nBật trong Cài đặt › Quyền riêng tư › Ảnh."];
    }];
}

- (void)showNote:(NSString *)text {
    _note.text = text;
    _note.hidden = NO;
    [self layoutGrid];
}

- (void)layoutGrid {
    for (UIView *v in _grid.subviews) {
        if (v != _note) [v removeFromSuperview];
    }
    CGFloat gw = _grid.bounds.size.width, gap = 3, c = floor((gw - 2 * gap) / 3);
    NSInteger n = (_camera ? 1 : 0) + _assets.count;
    if (_assets.count) _note.hidden = YES;
    else if ([_note.text isEqual:@"Đang tải ảnh…"]) _note.text = @"Chưa có ảnh nào trong máy.";
    for (NSInteger k = 0; k < n; k++) {
        CGRect f = CGRectMake((k % 3) * (c + gap), (k / 3) * (c + gap), c, c);
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = f;
        b.layer.cornerRadius = 6;
        b.clipsToBounds = YES;
        b.adjustsImageWhenHighlighted = NO;
        if (_camera && k == 0) {
            b.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1];
            UIImageView *ic = [[UIImageView alloc] initWithImage:[GMTheme icon:@"camera" color:[UIColor whiteColor]]];
            ic.frame = CGRectMake(floor((c - 26) / 2), floor(c / 2) - 22, 26, 26);
            [b addSubview:ic];
            UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, floor(c / 2) + 8, c, 16)];
            l.text = @"Máy ảnh";
            l.font = [UIFont boldSystemFontOfSize:12];
            l.textColor = [UIColor whiteColor];
            l.textAlignment = GMAlignCenter;
            l.backgroundColor = [UIColor clearColor];
            [b addSubview:l];
            b.accessibilityLabel = @"Chụp ảnh";
            [b addTarget:self action:@selector(cameraTapped) forControlEvents:UIControlEventTouchUpInside];
        } else {
            NSInteger i = k - (_camera ? 1 : 0);
            ALAsset *a = [_assets objectAtIndex:i];
            b.tag = 1000 + i;
            [b setBackgroundImage:[UIImage imageWithCGImage:a.thumbnail] forState:UIControlStateNormal];
            b.backgroundColor = [GMTheme placeholderFill];
            UILabel *mark = [[UILabel alloc] initWithFrame:CGRectMake(c - 27, 5, 22, 22)];
            mark.tag = 7;
            mark.layer.cornerRadius = 11;
            mark.layer.borderWidth = 1.5;
            mark.layer.borderColor = [UIColor whiteColor].CGColor;
            mark.font = [UIFont boldSystemFontOfSize:12];
            mark.textColor = [UIColor whiteColor];
            mark.textAlignment = GMAlignCenter;
            [b addSubview:mark];
            b.accessibilityLabel = @"Ảnh";
            [b addTarget:self action:@selector(photoTapped:) forControlEvents:UIControlEventTouchUpInside];
        }
        [_grid addSubview:b];
    }
    _grid.contentSize = CGSizeMake(gw, ceil(n / 3.0) * (c + gap));
    [self updateMarks];
}

- (void)updateMarks {
    for (UIView *b in _grid.subviews) {
        if (b.tag < 1000) continue;
        UILabel *mark = (UILabel *)[b viewWithTag:7];
        BOOL on = b.tag - 1000 == _sel;
        mark.text = on ? @"1" : nil;
        mark.backgroundColor = on ? [GMTheme accent] : [UIColor colorWithWhite:0 alpha:0.18];
    }
    _sendBtn.hidden = _sel < 0;
    _tabs.hidden = _sel >= 0;
}

- (void)photoTapped:(UIButton *)b {
    NSInteger i = b.tag - 1000;
    _sel = _sel == i ? -1 : i;
    [self updateMarks];
}

#pragma mark Chạm

- (void)closeThen:(void (^)(void))then {
    if (_closing) return;
    _closing = YES;
    CGRect f = _panel.frame;
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        _panel.frame = CGRectMake(f.origin.x, self.bounds.size.height + 4, f.size.width, f.size.height);
        _blur.alpha = 0;
        _dim.alpha = 0;
    } completion:^(BOOL finished) {
        [self removeFromSuperview];
        if (then) then();
    }];
}

- (void)dismiss {
    [self closeThen:nil];
}

- (void)choose:(GMAttachKind)k {
    void (^p)(GMAttachKind) = _pick;
    [self closeThen:^{
        if (p) p(k);
    }];
}

- (void)cameraTapped {
    [self choose:GMAttachCamera];
}

- (void)libraryTapped {
    [self choose:GMAttachLibrary];
}

- (void)tabTapped:(UIButton *)b {
    static const GMAttachKind kinds[] = {GMAttachLibrary, GMAttachFile, GMAttachLocation, GMAttachQR, GMAttachContact};
    NSInteger i = b.tag - 300;
    if (i >= 0 && i < 5) [self choose:kinds[i]];
}

- (void)debugSelect:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)_assets.count) return;
    _sel = i;
    [self updateMarks];
}

- (void)debugSend {
    if (_sel < 0 || _sel >= (NSInteger)_assets.count) return;
    ALAsset *a = [_assets objectAtIndex:_sel];
    // Ảnh cỡ màn hình (đã xoay đúng chiều) — chat thu về cạnh dài ≤ 1280 khi gửi
    CGImageRef cg = a.defaultRepresentation.fullScreenImage;
    UIImage *img = cg ? [UIImage imageWithCGImage:cg] : nil;
    void (^send)(UIImage *) = _photo;
    [self closeThen:^{
        if (img && send) send(img);
    }];
}

- (void)animateIn {
    CGRect f = _panel.frame;
    _panel.frame = CGRectMake(f.origin.x, self.bounds.size.height + 4, f.size.width, f.size.height);
    _blur.alpha = 0;
    _dim.alpha = 0;
    [UIView animateWithDuration:0.26 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        _panel.frame = f;
        _blur.alpha = 1;
        _dim.alpha = 1;
    } completion:nil];
}

@end
