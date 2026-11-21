#import "GMTitleView.h"
#import "GMTheme.h"

@implementation GMTitleView {
    UILabel *_t, *_s;
    UIActivityIndicatorView *_spin;
    UIImageView *_bg;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:CGRectMake(0, 0, 220, 40)])) {
        self.backgroundColor = [UIColor clearColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        _t = [[UILabel alloc] init];
        _t.font = [UIFont boldSystemFontOfSize:17];
        _t.textAlignment = GMAlignCenter;
        _t.backgroundColor = [UIColor clearColor];
        _t.textColor = [GMTheme navTitle];
        _t.shadowColor = [GMTheme navTitleShadow];
        _t.shadowOffset = [GMTheme navShadowOffset];
        _t.lineBreakMode = GMTailTruncation;
        [self addSubview:_t];
        _s = [[UILabel alloc] init];
        _s.font = [UIFont systemFontOfSize:12];
        _s.textColor = [GMTheme secondaryText];
        _s.shadowColor = [[GMTheme navTitleShadow] colorWithAlphaComponent:0.6];
        _s.shadowOffset = [GMTheme navShadowOffset];
        _s.textAlignment = GMAlignCenter;
        _s.backgroundColor = [UIColor clearColor];
        [self addSubview:_s];
        _spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:
                     [GMTheme dark] ? UIActivityIndicatorViewStyleWhite : UIActivityIndicatorViewStyleGray];
        _spin.hidesWhenStopped = YES;
        [self addSubview:_spin];
    }
    return self;
}

- (void)setTitle:(NSString *)title {
    _title = [title copy];
    [self setNeedsLayout];
}

- (void)setSubtitle:(NSString *)subtitle {
    _subtitle = [subtitle copy];
    [self setNeedsLayout];
}

- (void)setGlass:(BOOL)glass {
    _glass = glass;
    if (glass && !_bg) {
        _bg = [[UIImageView alloc] initWithImage:[GMTheme glassImage:40]];
        [self insertSubview:_bg atIndex:0];
    }
    _bg.hidden = !glass;
    [self setNeedsLayout];
}

- (void)setConnecting:(BOOL)connecting {
    _connecting = connecting;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    NSString *title = self.title, *sub = self.subtitle;
    if (self.connecting) {
        if (self.replaceTitle) title = @"Đang kết nối…";
        else sub = @"đang kết nối…";
    }
    _t.text = title;
    _s.text = sub;
    _s.hidden = sub.length == 0;
    // Một dòng: tiêu đề đậm 17 (iOS 26); hai dòng: tên + dòng phụ
    _t.font = [UIFont boldSystemFontOfSize:_s.hidden ? 17 : 15];
    if (_s.hidden) {
        _t.frame = CGRectMake(0, 0, w, h);
    } else {
        _t.frame = CGRectMake(0, 2, w, 19);
        _s.frame = CGRectMake(0, 20, w, 15);
    }
    if (_glass) {
        // Viên kính ôm chữ (dòng dài nhất + lề 18 mỗi bên), chữ dài thì kính rộng hết khung
        CGFloat tw = MAX([_t.text sizeWithFont:_t.font].width, _s.hidden ? 0 : [_s.text sizeWithFont:_s.font].width);
        if (self.connecting) tw += 24;
        CGFloat gw = MIN(w, MAX(80, ceil(tw) + 36));
        _bg.frame = CGRectMake(floor((w - gw) / 2), floor((h - 40) / 2), gw, 40);
        CGRect inner = CGRectInset(_bg.frame, 16, 0);
        _t.frame = CGRectMake(inner.origin.x, _t.frame.origin.y - 1, inner.size.width, _t.frame.size.height);
        _s.frame = CGRectMake(inner.origin.x, _s.frame.origin.y - 1, inner.size.width, _s.frame.size.height);
    }
    // Vòng quay ngay trước chữ «Đang kết nối…»
    if (self.connecting) {
        UILabel *l = self.replaceTitle ? _t : _s;
        CGFloat tw = MIN(w - 30, [l.text sizeWithFont:l.font].width);
        _spin.center = CGPointMake(floor((w - tw) / 2) - 12, CGRectGetMidY(l.frame));
        [_spin startAnimating];
    } else {
        [_spin stopAnimating];
    }
}

@end
