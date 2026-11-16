#import "GMTitleView.h"
#import "GMTheme.h"

@implementation GMTitleView {
    UILabel *_t, *_s;
    UIActivityIndicatorView *_spin;
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
        _s.textColor = [GMTheme dark] ? [GMTheme secondaryText] : [UIColor colorWithRed:0.33 green:0.4 blue:0.48 alpha:1];
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
    // Một dòng: chữ lớn như tiêu đề iOS 6; hai dòng: tên + dòng phụ
    _t.font = [UIFont boldSystemFontOfSize:_s.hidden ? 20 : 17];
    if (_s.hidden) {
        _t.frame = CGRectMake(0, 0, w, h);
    } else {
        _t.frame = CGRectMake(0, 1, w, 21);
        _s.frame = CGRectMake(0, 22, w, 15);
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
