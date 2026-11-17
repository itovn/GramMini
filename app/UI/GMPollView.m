#import "GMPollView.h"
#import "GMTheme.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kRowMin = 36, kTextX = 40;

BOOL GMPollVoted(NSDictionary *poll) {
    for (NSDictionary *v in GMVal(GMVal(poll, @"results"), @"voters")) {
        if ([GMVal(v, @"chosen") boolValue]) return YES;
    }
    return NO;
}

static BOOL GMShowResults(NSDictionary *poll) {
    return GMPollVoted(poll) || [GMVal(poll, @"closed") boolValue];
}

static BOOL GMHasVoteButton(NSDictionary *poll) {
    return [GMVal(poll, @"multi") boolValue] && !GMShowResults(poll);
}

static UIFont *GMQFont(void) {
    return [UIFont boldSystemFontOfSize:15];
}

static UIFont *GMAFont(void) {
    return [UIFont systemFontOfSize:15];
}

static CGFloat GMTextH(NSString *t, UIFont *f, CGFloat w) {
    return ceil([(t ?: @"") sizeWithFont:f constrainedToSize:CGSizeMake(MAX(w, 10), 1000) lineBreakMode:GMWordWrap].height);
}

/// Cao một hàng lựa chọn (như nhau khi chưa / đã bỏ phiếu: chữ luôn lùi vào kTextX).
static CGFloat GMRowH(NSString *t, CGFloat w) {
    return MAX(kRowMin, GMTextH(t, GMAFont(), w - kTextX) + 16);
}

@implementation GMPollView {
    NSDictionary *_poll;
    NSSet *_selected;
}

+ (CGFloat)heightFor:(NSDictionary *)poll width:(CGFloat)w {
    CGFloat h = GMTextH(GMVal(poll, @"q"), GMQFont(), w) + 24;
    for (NSDictionary *a in GMVal(poll, @"answers")) h += GMRowH(GMVal(a, @"t"), w);
    h += 24;  // dòng «… người đã bình chọn»
    if (GMHasVoteButton(poll)) h += 34;
    return h;
}

- (UILabel *)label:(UIFont *)f color:(UIColor *)c frame:(CGRect)r {
    UILabel *l = [[UILabel alloc] initWithFrame:r];
    l.font = f;
    l.textColor = c;
    l.backgroundColor = [UIColor clearColor];
    l.numberOfLines = 0;
    [self addSubview:l];
    return l;
}

- (void)showPoll:(NSDictionary *)poll selected:(NSSet *)selected tint:(UIColor *)tint {
    for (UIView *v in [self.subviews copy]) [v removeFromSuperview];
    _poll = poll;
    _selected = selected;
    CGFloat w = self.bounds.size.width, y = 0;
    BOOL quiz = [GMVal(poll, @"quiz") boolValue], multi = [GMVal(poll, @"multi") boolValue];
    BOOL closed = [GMVal(poll, @"closed") boolValue], results = GMShowResults(poll), voted = GMPollVoted(poll);
    CGFloat qh = GMTextH(GMVal(poll, @"q"), GMQFont(), w);
    [self label:GMQFont() color:[GMTheme text] frame:CGRectMake(0, 0, w, qh)].text = GMVal(poll, @"q");
    y = qh + 2;
    NSString *kind = quiz ? @"Câu đố" : ([GMVal(poll, @"public") boolValue] ? @"Bình chọn công khai" : @"Bình chọn ẩn danh");
    if (multi) kind = [kind stringByAppendingString:@" · nhiều lựa chọn"];
    if (closed) kind = [kind stringByAppendingString:@" · đã đóng"];
    UILabel *sub = [self label:[UIFont systemFontOfSize:12] color:tint frame:CGRectMake(0, y, w, 16)];
    sub.numberOfLines = 1;
    sub.text = kind;
    y += 22;

    NSMutableDictionary *byOption = [NSMutableDictionary dictionary];
    for (NSDictionary *v in GMVal(GMVal(poll, @"results"), @"voters")) {
        if (GMVal(v, @"o")) [byOption setObject:v forKey:GMVal(v, @"o")];
    }
    long long total = [GMVal(GMVal(poll, @"results"), @"total") longLongValue];
    UIColor *green = [UIColor colorWithRed:0.25 green:0.64 blue:0.3 alpha:1];
    UIColor *red = [UIColor colorWithRed:0.86 green:0.26 blue:0.2 alpha:1];
    NSArray *answers = GMVal(poll, @"answers");
    for (NSUInteger i = 0; i < answers.count; i++) {
        NSDictionary *a = [answers objectAtIndex:i];
        NSString *o = GMVal(a, @"o");
        CGFloat rh = GMRowH(GMVal(a, @"t"), w);
        CGFloat th = GMTextH(GMVal(a, @"t"), GMAFont(), w - kTextX);
        if (!results) {
            BOOL on = multi && [selected containsObject:o];
            UILabel *circle = [self label:[UIFont boldSystemFontOfSize:13] color:[UIColor whiteColor]
                                    frame:CGRectMake(4, y + floor((rh - 22) / 2), 22, 22)];
            circle.numberOfLines = 1;
            circle.textAlignment = GMAlignCenter;
            circle.layer.cornerRadius = 11;
            circle.layer.borderWidth = 1.5;
            circle.layer.borderColor = (on ? tint : [GMTheme secondaryText]).CGColor;
            circle.backgroundColor = on ? tint : [UIColor clearColor];
            circle.text = on ? @"✓" : nil;
            [self label:GMAFont() color:[GMTheme text] frame:CGRectMake(kTextX, y + 8, w - kTextX, th)].text = GMVal(a, @"t");
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.frame = CGRectMake(0, y, w, rh);
            b.tag = (NSInteger)i;
            [b addTarget:self action:@selector(answerTapped:) forControlEvents:UIControlEventTouchUpInside];
            [self addSubview:b];
        } else {
            NSDictionary *v = [byOption objectForKey:o];
            long long n = [GMVal(v, @"n") longLongValue];
            BOOL chosen = [GMVal(v, @"chosen") boolValue], correct = [GMVal(v, @"correct") boolValue];
            int pct = total > 0 ? (int)llround(n * 100.0 / total) : 0;
            UILabel *pl = [self label:[UIFont boldSystemFontOfSize:13] color:[GMTheme text] frame:CGRectMake(0, y + 8, kTextX - 6, 18)];
            pl.numberOfLines = 1;
            pl.textAlignment = GMAlignRight;
            pl.text = [NSString stringWithFormat:@"%d%%", pct];
            NSString *t = GMVal(a, @"t") ?: @"";
            if (chosen) t = [@"✓ " stringByAppendingString:t];
            [self label:GMAFont() color:[GMTheme text] frame:CGRectMake(kTextX, y + 8, w - kTextX, th)].text = t;
            UIColor *bc = quiz ? (correct ? green : (chosen ? red : [GMTheme secondaryText])) : tint;
            UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(kTextX, y + rh - 6, MAX(4, floor((w - kTextX) * (total > 0 ? n / (double)total : 0))), 4)];
            bar.backgroundColor = bc;
            bar.layer.cornerRadius = 2;
            [self addSubview:bar];
        }
        y += rh;
    }
    y += 4;
    UILabel *foot = [self label:[UIFont systemFontOfSize:12] color:[GMTheme secondaryText] frame:CGRectMake(0, y, w, 18)];
    foot.numberOfLines = 1;
    foot.text = total > 0 ? [NSString stringWithFormat:@"%lld người đã bình chọn", total] : @"Chưa có ai bình chọn";
    if (voted && !closed && !quiz) {
        UIButton *r = [UIButton buttonWithType:UIButtonTypeCustom];
        r.frame = CGRectMake(w - 80, y - 4, 80, 26);
        r.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        r.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
        [r setTitle:@"Rút phiếu" forState:UIControlStateNormal];
        [r setTitleColor:tint forState:UIControlStateNormal];
        [r addTarget:self action:@selector(retractTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:r];
    }
    y += 20;
    if (GMHasVoteButton(poll)) {
        UIButton *v = [UIButton buttonWithType:UIButtonTypeCustom];
        v.frame = CGRectMake(0, y + 2, w, 30);
        v.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        [v setTitle:@"Bỏ phiếu" forState:UIControlStateNormal];
        [v setTitleColor:tint forState:UIControlStateNormal];
        [v setTitleColor:[GMTheme secondaryText] forState:UIControlStateDisabled];
        v.enabled = selected.count > 0;
        [v addTarget:self action:@selector(voteTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:v];
    }
}

- (void)answerTapped:(UIButton *)b {
    NSArray *answers = GMVal(_poll, @"answers");
    if (b.tag < 0 || b.tag >= (NSInteger)answers.count) return;
    NSString *o = GMVal([answers objectAtIndex:b.tag], @"o");
    if (!o) return;
    if ([GMVal(_poll, @"multi") boolValue]) {
        if (self.toggle) self.toggle(o);
    } else if (self.vote) {
        self.vote(@[o]);
    }
}

- (void)voteTapped {
    if (_selected.count && self.vote) self.vote(_selected.allObjects);
}

- (void)retractTapped {
    if (self.vote) self.vote(@[]);
}

@end
