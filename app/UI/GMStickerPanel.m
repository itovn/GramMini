#import "GMStickerPanel.h"
#import "GMCore.h"
#import "GMImages.h"
#import "GMTheme.h"
#import "GMStickerSetViewController.h"
#import <QuartzCore/QuartzCore.h>

const CGFloat kGMStickerPanelH = 216;
static const CGFloat kTabH = 38;

@implementation GMStickerPanel {
    UIScrollView *_tabBar, *_grid;
    UILabel *_empty;
    NSMutableArray *_tabs;          // @{title, kind: recent|gif|set, id?, access_hash?}
    NSMutableDictionary *_items;    // chỉ số thẻ → [mục]
    NSInteger _current;
    BOOL _loaded, _loading;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [GMTheme background];
        // Dải thẻ: kính như thanh nhập tin (vạch sáng mép trên)
        UIImageView *tbg = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, kTabH)];
        tbg.image = [GMTheme glassBar];
        tbg.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self addSubview:tbg];
        _tabBar = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width - kTabH, kTabH)];
        _tabBar.showsHorizontalScrollIndicator = NO;
        _tabBar.backgroundColor = [UIColor clearColor];
        _tabBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        _tabBar.scrollsToTop = NO;
        [self addSubview:_tabBar];
        // «+»: thêm bộ sticker (như Telegram gốc)
        UIButton *add = [UIButton buttonWithType:UIButtonTypeCustom];
        add.frame = CGRectMake(frame.size.width - kTabH, 0, kTabH, kTabH);
        add.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [add setTitle:@"+" forState:UIControlStateNormal];
        [add setTitleColor:[GMTheme accent] forState:UIControlStateNormal];
        [add setTitleColor:[[GMTheme accent] colorWithAlphaComponent:0.4] forState:UIControlStateHighlighted];
        add.titleLabel.font = [UIFont boldSystemFontOfSize:28];
        add.contentEdgeInsets = UIEdgeInsetsMake(0, 0, 3, 0);
        [add addTarget:self action:@selector(addTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:add];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(setsChanged) name:GMStickersChangedNotification object:nil];
        _grid = [[UIScrollView alloc] initWithFrame:CGRectMake(0, kTabH, frame.size.width, frame.size.height - kTabH)];
        _grid.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _grid.scrollsToTop = NO;
        [self addSubview:_grid];
        _empty = [[UILabel alloc] initWithFrame:CGRectInset(_grid.frame, 20, 40)];
        _empty.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        _empty.textAlignment = GMAlignCenter;
        _empty.numberOfLines = 0;
        _empty.textColor = [GMTheme secondaryText];
        _empty.backgroundColor = [UIColor clearColor];
        [self addSubview:_empty];
        _tabs = [NSMutableArray array];
        _items = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)addTapped {
    if (self.manage) self.manage();
}

/// Thêm / gỡ bộ ở màn khác: tải lại dải thẻ.
- (void)setsChanged {
    if (_loading) return;
    _loaded = NO;
    [self reloadIfNeeded];
}

#pragma mark Tải

- (void)reloadIfNeeded {
    if (_loaded || _loading) return;
    _loading = YES;
    _empty.text = @"Đang tải sticker…";
    __block NSInteger pending = 3;
    __block NSArray *recent = @[], *gifs = @[], *sets = @[];
    void (^finish)(void) = ^{
        if (--pending) return;
        _loading = NO;
        _loaded = YES;
        [_tabs removeAllObjects];
        [_items removeAllObjects];
        if (recent.count) {
            [_items setObject:recent forKey:@(_tabs.count)];
            [_tabs addObject:@{@"title": @"Gần đây", @"kind": @"recent"}];
        }
        if (gifs.count) {
            [_items setObject:gifs forKey:@(_tabs.count)];
            [_tabs addObject:@{@"title": @"GIF", @"kind": @"gif"}];
        }
        for (NSDictionary *s in sets) {
            NSMutableDictionary *t = [s mutableCopy];
            [t setObject:@"set" forKey:@"kind"];
            [_tabs addObject:t];
        }
        [self buildTabs];
        if (_tabs.count) [self selectTab:0];
        else _empty.text = @"Chưa có sticker nào.\nCài bộ sticker trong app Telegram trên máy khác — sẽ hiện ở đây.";
    };
    [GMCore call:@"stickers.recent" args:nil done:^(id ok, NSDictionary *err) {
        if ([ok isKindOfClass:[NSArray class]]) recent = ok;
        finish();
    }];
    [GMCore call:@"gifs.saved" args:nil done:^(id ok, NSDictionary *err) {
        if ([ok isKindOfClass:[NSArray class]]) gifs = ok;
        finish();
    }];
    [GMCore call:@"stickers.sets" args:nil done:^(id ok, NSDictionary *err) {
        if ([ok isKindOfClass:[NSArray class]]) sets = ok;
        finish();
    }];
}

- (void)buildTabs {
    for (UIView *v in _tabBar.subviews) [v removeFromSuperview];
    CGFloat x = 6;
    for (NSUInteger i = 0; i < _tabs.count; i++) {
        NSString *t = [[_tabs objectAtIndex:i] objectForKey:@"title"];
        if (t.length > 14) t = [[t substringToIndex:13] stringByAppendingString:@"…"];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.tag = 100 + i;
        b.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [b setTitle:t forState:UIControlStateNormal];
        [b setTitleColor:[GMTheme secondaryText] forState:UIControlStateNormal];
        [b setTitleColor:[GMTheme accent] forState:UIControlStateSelected];
        CGFloat w = [t sizeWithFont:b.titleLabel.font].width + 20;
        b.frame = CGRectMake(x, 4, w, kTabH - 8);
        b.layer.cornerRadius = (kTabH - 8) / 2;
        [b addTarget:self action:@selector(tabTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_tabBar addSubview:b];
        x += w + 4;
    }
    _tabBar.contentSize = CGSizeMake(x + 6, kTabH);
}

- (void)tabTapped:(UIButton *)b {
    [self selectTab:b.tag - 100];
}

- (void)selectTab:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)_tabs.count) return;
    _current = i;
    for (UIView *v in _tabBar.subviews) {
        if (![v isKindOfClass:[UIButton class]]) continue;
        UIButton *b = (UIButton *)v;
        b.selected = b.tag == 100 + i;
        b.backgroundColor = b.selected ? [GMTheme glassGrouped] : [UIColor clearColor];
        b.layer.borderWidth = b.selected ? 1 : 0;
        b.layer.borderColor = [GMTheme glassLine].CGColor;
    }
    NSArray *items = [_items objectForKey:@(i)];
    if (items) {
        [self layoutGrid:items];
        return;
    }
    NSDictionary *t = [_tabs objectAtIndex:i];
    for (UIView *v in _grid.subviews) [v removeFromSuperview];
    _empty.text = @"Đang tải…";
    _empty.hidden = NO;
    [GMCore call:@"stickers.set" args:@{@"id": [t objectForKey:@"id"], @"access_hash": [t objectForKey:@"access_hash"]}
            done:^(id ok, NSDictionary *err) {
                if (![ok isKindOfClass:[NSArray class]]) {
                    _empty.text = GMErrorText(err);
                    return;
                }
                [_items setObject:ok forKey:@(i)];
                if (_current == i) [self layoutGrid:ok];
            }];
}

- (void)layoutGrid:(NSArray *)items {
    for (UIView *v in _grid.subviews) [v removeFromSuperview];
    _empty.hidden = items.count > 0;
    _empty.text = items.count ? @"" : @"Trống.";
    BOOL gif = [[[_tabs objectAtIndex:_current] objectForKey:@"kind"] isEqual:@"gif"];
    CGFloat W = _grid.bounds.size.width;
    NSInteger cols = gif ? 3 : MAX(4, (NSInteger)(W / 64));
    CGFloat cw = floor((W - 8) / cols), ch = gif ? floor(cw * 0.75) : cw;
    CGFloat scale = [UIScreen mainScreen].scale;
    for (NSUInteger i = 0; i < items.count; i++) {
        NSDictionary *it = [items objectAtIndex:i];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.tag = i;
        b.frame = CGRectMake(4 + (i % cols) * cw, 4 + (i / cols) * ch, cw, ch);
        b.imageView.contentMode = gif ? UIViewContentModeScaleAspectFill : UIViewContentModeScaleAspectFit;
        b.imageEdgeInsets = gif ? UIEdgeInsetsMake(2, 2, 2, 2) : UIEdgeInsetsMake(5, 5, 5, 5);
        b.clipsToBounds = YES;
        b.adjustsImageWhenHighlighted = NO;
        b.showsTouchWhenHighlighted = YES;
        NSString *emoji = [it objectForKey:@"emoji"];
        if ([emoji isKindOfClass:[NSString class]]) {
            [b setTitle:emoji forState:UIControlStateNormal];  // hiện trong lúc tải ảnh
            b.titleLabel.font = [UIFont systemFontOfSize:26];
        }
        if (gif) b.backgroundColor = [GMTheme placeholderFill];
        [b addTarget:self action:@selector(itemTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_grid addSubview:b];
        __weak UIButton *wb = b;
        [GMImages docPreview:[it objectForKey:@"doc"] maxPixel:MAX(cw, ch) * scale done:^(UIImage *img) {
            if (!img) return;
            [wb setTitle:nil forState:UIControlStateNormal];
            [wb setImage:img forState:UIControlStateNormal];
        }];
    }
    NSInteger rows = (items.count + cols - 1) / cols;
    _grid.contentSize = CGSizeMake(W, 8 + rows * ch);
    _grid.contentOffset = CGPointZero;
}

- (void)itemTapped:(UIButton *)b {
    NSArray *items = [_items objectForKey:@(_current)];
    if (b.tag < (NSInteger)items.count && self.pick) self.pick([items objectAtIndex:b.tag]);
}

- (void)debugTab:(NSInteger)i {
    [self selectTab:i];
}

- (void)debugPick:(NSInteger)i {
    NSArray *items = [_items objectForKey:@(_current)];
    if (i >= 0 && i < (NSInteger)items.count && self.pick) self.pick([items objectAtIndex:i]);
}

@end
