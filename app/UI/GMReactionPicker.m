#import "GMReactionPicker.h"
#import "GMTheme.h"
#import <QuartzCore/QuartzCore.h>

static __weak GMReactionPicker *gShown;

@implementation GMReactionPicker {
    void (^_pick)(NSString *);
    NSArray *_emojis;
    NSString *_chosen;
    UIView *_panel;
}

+ (GMReactionPicker *)showIn:(UIView *)view near:(CGRect)anchor emojis:(NSArray *)emojis chosen:(NSString *)chosen
                        pick:(void (^)(NSString *))pick {
    [gShown dismiss];
    if (!emojis.count) return nil;
    GMReactionPicker *p = [[GMReactionPicker alloc] initWithFrame:view.bounds];
    p.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    p->_pick = [pick copy];
    p->_chosen = chosen;
    p.backgroundColor = [UIColor colorWithWhite:0 alpha:0.12];
    // Nền trong suốt bắt chạm ra ngoài (nút thay cử chỉ: iOS 5 cử chỉ trên view cha nuốt cả chạm vào nút emoji)
    UIButton *bg = [UIButton buttonWithType:UIButtonTypeCustom];
    bg.frame = p.bounds;
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [bg addTarget:p action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [p addSubview:bg];

    const CGFloat cell = 44, pad = 8;
    CGFloat W = view.bounds.size.width, H = view.bounds.size.height;
    NSUInteger perRow = (NSUInteger)floor((MIN(W - 20, 8 * cell + 2 * pad) - 2 * pad) / cell);
    perRow = MAX(1, MIN(perRow, emojis.count));
    NSUInteger rows = MIN((NSUInteger)4, (emojis.count + perRow - 1) / perRow);
    p->_emojis = [emojis subarrayWithRange:NSMakeRange(0, MIN(emojis.count, perRow * rows))];
    CGFloat pw = perRow * cell + 2 * pad, ph = rows * cell + 2 * pad;
    CGFloat px = MIN(MAX(10, CGRectGetMidX(anchor) - pw / 2), W - pw - 10);
    CGFloat py = anchor.origin.y - ph - 6;
    if (py < 10) py = MIN(CGRectGetMaxY(anchor) + 6, H - ph - 10);
    if (py < 10) py = 10;
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(px, py, pw, ph)];
    panel.backgroundColor = [GMTheme dark] ? [UIColor colorWithWhite:0.16 alpha:0.96] : [UIColor colorWithWhite:1 alpha:0.96];
    panel.layer.cornerRadius = 18;
    panel.layer.borderWidth = 1;
    panel.layer.borderColor = [GMTheme separator].CGColor;
    panel.layer.shadowColor = [UIColor blackColor].CGColor;
    panel.layer.shadowOpacity = 0.25;
    panel.layer.shadowRadius = 8;
    panel.layer.shadowOffset = CGSizeMake(0, 3);
    [p addSubview:panel];
    p->_panel = panel;
    for (NSUInteger i = 0; i < p->_emojis.count; i++) {
        NSString *e = [p->_emojis objectAtIndex:i];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(pad + (i % perRow) * cell, pad + (i / perRow) * cell, cell, cell);
        b.titleLabel.font = [UIFont systemFontOfSize:27];
        [b setTitle:e forState:UIControlStateNormal];
        if ([e isEqual:chosen]) {
            b.backgroundColor = [[GMTheme accent] colorWithAlphaComponent:0.25];
            b.layer.cornerRadius = cell / 2;
        }
        b.tag = (NSInteger)i;
        [b addTarget:p action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
        [panel addSubview:b];
    }
    p.alpha = 0;
    panel.transform = CGAffineTransformMakeScale(0.85, 0.85);
    [view addSubview:p];
    [UIView animateWithDuration:0.15 animations:^{
        p.alpha = 1;
        panel.transform = CGAffineTransformIdentity;
    }];
    gShown = p;
    return p;
}

+ (void)dismissShown {
    [gShown dismiss];
}

- (void)tapped:(UIButton *)b {
    [self tapIndex:b.tag];
}

- (void)tapIndex:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)_emojis.count) return;
    NSString *e = [_emojis objectAtIndex:i];
    void (^pick)(NSString *) = _pick;
    _pick = nil;
    [self dismiss];
    if (pick) pick([e isEqual:_chosen] ? nil : e);
}

- (void)dismiss {
    _pick = nil;
    [UIView animateWithDuration:0.12 animations:^{ self.alpha = 0; } completion:^(BOOL f) { [self removeFromSuperview]; }];
}

@end
