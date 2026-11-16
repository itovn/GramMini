#import "GMStickerSetViewController.h"
#import "GMAppDelegate.h"
#import "GMChatListViewController.h"
#import "GMCore.h"
#import "GMImages.h"
#import "GMTheme.h"
#import <objc/runtime.h>

NSString *const GMStickersChangedNotification = @"GMStickersChanged";

static const CGFloat kBarH = 60;

/// Khoá bộ (gửi cho lõi): id + access_hash, hoặc short_name.
static NSDictionary *GMSetKey(NSDictionary *s) {
    if (GMVal(s, @"id") && GMVal(s, @"access_hash")) return @{@"id": GMVal(s, @"id"), @"access_hash": GMVal(s, @"access_hash")};
    return @{@"short_name": GMVal(s, @"short_name") ?: @""};
}

#pragma mark - Xem một bộ

@implementation GMStickerSetViewController {
    UIScrollView *_grid;
    UILabel *_status;
    UIView *_bar;
    UIButton *_action;
    NSDictionary *_info;
    NSArray *_items;
    CGFloat _layoutW;
    BOOL _busy;
}

+ (void)present:(NSDictionary *)set from:(UIViewController *)vc pick:(void (^)(NSDictionary *))pick {
    GMStickerSetViewController *s = [[GMStickerSetViewController alloc] init];
    s.set = set;
    s.pick = pick;
    UINavigationController *n = [[UINavigationController alloc] initWithRootViewController:s];
    n.modalPresentationStyle = UIModalPresentationFormSheet;
    [vc presentViewController:n animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = GMVal(self.set, @"title") ?: @"Bộ sticker";
    self.view.backgroundColor = [GMTheme background];
    [self.view addSubview:[[GMWallpaperView alloc] initWithFrame:self.view.bounds]];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Đóng" style:UIBarButtonItemStyleBordered target:self action:@selector(close)];
    CGRect b = self.view.bounds;
    _grid = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, b.size.width, b.size.height - kBarH)];
    _grid.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _grid.alwaysBounceVertical = YES;
    [self.view addSubview:_grid];
    _status = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, b.size.width - 40, 60)];
    _status.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _status.textAlignment = GMAlignCenter;
    _status.numberOfLines = 0;
    _status.backgroundColor = [UIColor clearColor];
    _status.textColor = [GMTheme secondaryText];
    _status.text = @"Đang tải bộ sticker…";
    [self.view addSubview:_status];
    // Thanh dưới kính: nút Thêm (xanh bóng) / Gỡ (chữ đỏ)
    _bar = [[UIView alloc] initWithFrame:CGRectMake(0, b.size.height - kBarH, b.size.width, kBarH)];
    _bar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    UIImageView *bg = [[UIImageView alloc] initWithFrame:_bar.bounds];
    bg.image = [GMTheme glassBar];
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_bar addSubview:bg];
    _action = [UIButton buttonWithType:UIButtonTypeCustom];
    _action.frame = CGRectMake(12, (kBarH - 44) / 2, b.size.width - 24, 44);
    _action.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _action.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    _action.titleLabel.shadowOffset = CGSizeMake(0, -1);
    _action.adjustsImageWhenHighlighted = NO;
    [_action addTarget:self action:@selector(actionTapped) forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:_action];
    _bar.hidden = YES;
    [self.view addSubview:_bar];
    [self load];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)load {
    [GMCore call:@"stickers.setInfo" args:GMSetKey(self.set) done:^(id ok, NSDictionary *err) {
        if (err) {
            _status.text = GMErrorText(err);
            return;
        }
        _info = GMVal(ok, @"set");
        _items = GMVal(ok, @"items");
        self.title = GMVal(_info, @"title");
        _status.hidden = YES;
        _layoutW = 0;
        [self.view setNeedsLayout];
        [self updateAction];
    }];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    if (_items && _layoutW != _grid.bounds.size.width) [self layoutGrid];
}

- (void)layoutGrid {
    _layoutW = _grid.bounds.size.width;
    for (UIView *v in _grid.subviews) {
        if ([v isKindOfClass:[UIButton class]]) [v removeFromSuperview];
    }
    CGFloat W = _layoutW;
    NSInteger cols = MAX(4, (NSInteger)(W / 80));
    CGFloat cw = floor((W - 16) / cols), scale = [UIScreen mainScreen].scale;
    for (NSUInteger i = 0; i < _items.count; i++) {
        NSDictionary *it = [_items objectAtIndex:i];
        UIButton *bt = [UIButton buttonWithType:UIButtonTypeCustom];
        bt.tag = i;
        bt.frame = CGRectMake(8 + (i % cols) * cw, 10 + (i / cols) * cw, cw, cw);
        bt.imageView.contentMode = UIViewContentModeScaleAspectFit;
        bt.imageEdgeInsets = UIEdgeInsetsMake(6, 6, 6, 6);
        bt.adjustsImageWhenHighlighted = NO;
        bt.showsTouchWhenHighlighted = self.pick != nil;
        NSString *emoji = GMVal(it, @"emoji");
        if (emoji.length) {
            [bt setTitle:emoji forState:UIControlStateNormal];  // trong lúc tải ảnh
            bt.titleLabel.font = [UIFont systemFontOfSize:28];
        }
        [bt addTarget:self action:@selector(itemTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_grid addSubview:bt];
        __weak UIButton *wb = bt;
        [GMImages docPreview:GMVal(it, @"doc") maxPixel:cw * scale done:^(UIImage *img) {
            if (!img) return;
            [wb setTitle:nil forState:UIControlStateNormal];
            [wb setImage:img forState:UIControlStateNormal];
        }];
    }
    NSInteger rows = (_items.count + cols - 1) / cols;
    _grid.contentSize = CGSizeMake(W, 20 + rows * cw);
}

- (void)itemTapped:(UIButton *)b {
    if (!self.pick || b.tag >= (NSInteger)_items.count) return;
    NSDictionary *it = [_items objectAtIndex:b.tag];
    void (^pick)(NSDictionary *) = self.pick;
    [self dismissViewControllerAnimated:YES completion:nil];
    pick(it);
}

- (void)updateAction {
    BOOL inst = [GMVal(_info, @"installed") boolValue];
    NSString *t = inst ? @"Gỡ bộ sticker này" : [NSString stringWithFormat:@"Thêm %@ sticker", GMVal(_info, @"count") ?: @""];
    [_action setTitle:t forState:UIControlStateNormal];
    if (inst) {
        [_action setBackgroundImage:nil forState:UIControlStateNormal];
        [_action setBackgroundImage:nil forState:UIControlStateHighlighted];
        [_action setTitleColor:[UIColor colorWithRed:0.86 green:0.2 blue:0.16 alpha:1] forState:UIControlStateNormal];
        [_action setTitleColor:[UIColor colorWithRed:0.86 green:0.2 blue:0.16 alpha:0.4] forState:UIControlStateHighlighted];
        [_action setTitleShadowColor:[UIColor clearColor] forState:UIControlStateNormal];
    } else {
        [_action setBackgroundImage:[GMTheme sendButtonImage:NO] forState:UIControlStateNormal];
        [_action setBackgroundImage:[GMTheme sendButtonImage:YES] forState:UIControlStateHighlighted];
        [_action setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [_action setTitleColor:[UIColor whiteColor] forState:UIControlStateHighlighted];
        [_action setTitleShadowColor:[UIColor colorWithWhite:0 alpha:0.35] forState:UIControlStateNormal];
    }
    _bar.hidden = NO;
}

- (void)actionTapped {
    if (_busy || !_info) return;
    _busy = YES;
    BOOL inst = [GMVal(_info, @"installed") boolValue];
    [GMCore call:inst ? @"stickers.uninstall" : @"stickers.install" args:GMSetKey(_info) done:^(id ok, NSDictionary *err) {
        _busy = NO;
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.view];
            return;
        }
        NSMutableDictionary *m = [_info mutableCopy];
        [m setObject:@(!inst) forKey:@"installed"];
        _info = m;
        [self updateAction];
        [[NSNotificationCenter defaultCenter] postNotificationName:GMStickersChangedNotification object:nil userInfo:@{@"set": _info}];
        [GMTheme toast:inst ? @"Đã gỡ bộ sticker" : @"Đã thêm vào sticker của bạn" in:self.view];
    }];
}

- (void)debugAction {
    [self actionTapped];
}

@end

#pragma mark - Màn Sticker

typedef NS_ENUM(NSInteger, GMStickerSection) { GMSecMine, GMSecCreate, GMSecFeatured, GMSecCount };

static const char kCoverKey;

@interface GMStickersViewController () <UISearchBarDelegate>
@end

@implementation GMStickersViewController {
    NSMutableArray *_mine;      // bộ đã cài
    NSArray *_featured;         // bộ nổi bật
    NSArray *_results;          // kết quả tìm (nil = không tìm)
    NSString *_query;
    UISearchBar *_bar;
    UIImage *_blank;            // chỗ trống 40 × 40 cho ảnh bìa đang tải
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Sticker";
    _mine = [NSMutableArray array];
    _featured = @[];
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(40, 40), NO, 0);
    _blank = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    _bar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    _bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _bar.placeholder = @"Tìm bộ sticker";
    _bar.delegate = self;
    _bar.autocorrectionType = UITextAutocorrectionTypeNo;
    _bar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    for (UIView *v in _bar.subviews) {
        if (![v isKindOfClass:[UITextField class]]) continue;
        ((UITextField *)v).textColor = [GMTheme text];
        ((UITextField *)v).keyboardAppearance = [GMTheme keyboard];
    }
    self.tableView.tableHeaderView = _bar;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Sửa" style:UIBarButtonItemStyleBordered target:self action:@selector(toggleEdit)];
    if (self.presentingViewController && self.navigationController.viewControllers.count == 1) {
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"Đóng" style:UIBarButtonItemStyleBordered target:self action:@selector(close)];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(changed:) name:GMStickersChangedNotification object:nil];
    [self loadMine];
    [GMCore call:@"stickers.featured" args:nil done:^(id ok, NSDictionary *err) {
        if ([ok isKindOfClass:[NSArray class]]) _featured = ok;
        [self.tableView reloadData];
    }];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)toggleEdit {
    BOOL on = !self.tableView.editing;
    [self.tableView setEditing:on animated:YES];
    self.navigationItem.rightBarButtonItem.title = on ? @"Xong" : @"Sửa";
}

- (void)loadMine {
    [GMCore call:@"stickers.sets" args:nil done:^(id ok, NSDictionary *err) {
        if (![ok isKindOfClass:[NSArray class]]) return;
        [_mine setArray:ok];
        [self.tableView reloadData];
    }];
}

/// Thêm / gỡ ở màn xem bộ: tải lại bộ của bạn, đổi trạng thái «Đã thêm» trong danh sách nổi bật / kết quả tìm.
- (void)changed:(NSNotification *)n {
    NSDictionary *s = [n.userInfo objectForKey:@"set"];
    _featured = [self mark:_featured with:s];
    _results = _results ? [self mark:_results with:s] : nil;
    [self loadMine];
}

- (NSArray *)mark:(NSArray *)list with:(NSDictionary *)s {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:list.count];
    for (NSDictionary *d in list) {
        if ([GMVal(d, @"id") isEqual:GMVal(s, @"id")]) {
            NSMutableDictionary *m = [d mutableCopy];
            [m setObject:GMVal(s, @"installed") ?: @NO forKey:@"installed"];
            [out addObject:m];
        } else {
            [out addObject:d];
        }
    }
    return out;
}

#pragma mark Tìm bộ sticker

- (void)searchBar:(UISearchBar *)bar textDidChange:(NSString *)text {
    _query = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(search) object:nil];
    if (!_query.length) {
        _results = nil;
        [self.tableView reloadData];
        return;
    }
    [self performSelector:@selector(search) withObject:nil afterDelay:0.4];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)bar {
    [bar resignFirstResponder];
}

- (void)search {
    NSString *q = _query;
    [GMCore call:@"stickers.search" args:@{@"q": q} done:^(id ok, NSDictionary *err) {
        if (![q isEqual:_query]) return;  // đã gõ tiếp
        _results = [ok isKindOfClass:[NSArray class]] ? ok : @[];
        [self.tableView reloadData];
    }];
}

- (void)debugSearch:(NSString *)q {
    _bar.text = q;
    [self searchBar:_bar textDidChange:q];
}

#pragma mark Bảng

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return _results ? 1 : GMSecCount;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (_results) return MAX(1, (NSInteger)_results.count);
    if (s == GMSecMine) return MAX(1, (NSInteger)_mine.count);
    if (s == GMSecCreate) return 1;
    return _featured.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (_results) return @"Kết quả";
    return s == GMSecMine ? @"Sticker của bạn" : s == GMSecFeatured ? (_featured.count ? @"Bộ nổi bật" : nil) : nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (_results || s != GMSecCreate) return nil;
    return @"Gửi ảnh cho bot @Stickers của Telegram để tự làm bộ sticker — làm xong, bộ hiện ở đây như các bộ khác.";
}

- (NSArray *)listFor:(NSInteger)s {
    if (_results) return _results;
    return s == GMSecMine ? _mine : s == GMSecFeatured ? _featured : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSArray *list = [self listFor:ip.section];
    if (!_results && ip.section == GMSecCreate) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.textLabel.text = @"Tạo bộ sticker riêng";
        c.textLabel.textColor = [GMTheme accent];
        c.imageView.image = [GMTheme settingsIcon:@"stickers"];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    if (!list.count) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.textLabel.text = _results ? (_query.length ? @"Không thấy bộ nào." : @"") : @"Chưa có bộ nào — thêm từ «Bộ nổi bật» bên dưới.";
        c.textLabel.font = [UIFont systemFontOfSize:14];
        c.textLabel.textColor = [GMTheme secondaryText];
        c.textLabel.numberOfLines = 2;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    NSDictionary *s = [list objectAtIndex:ip.row];
    BOOL mine = !_results && ip.section == GMSecMine;
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:mine ? @"m" : @"f"];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:mine ? UITableViewCellStyleValue1 : UITableViewCellStyleSubtitle
                                   reuseIdentifier:mine ? @"m" : @"f"];
    }
    c.textLabel.text = GMVal(s, @"title");
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@ sticker", GMVal(s, @"count") ?: @0];
    if (mine) {
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    // Ảnh bìa (sticker đại diện) + nút Thêm / «Đã thêm»
    NSString *doc = GMVal(GMVal(s, @"cover"), @"doc");
    c.imageView.image = _blank;
    objc_setAssociatedObject(c, &kCoverKey, doc, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (doc) {
        __weak UITableViewCell *wc = c;
        [GMImages docPreview:doc maxPixel:40 * [UIScreen mainScreen].scale done:^(UIImage *img) {
            if (!img || ![objc_getAssociatedObject(wc, &kCoverKey) isEqual:doc]) return;
            UIGraphicsBeginImageContextWithOptions(CGSizeMake(40, 40), NO, 0);
            CGFloat k = MIN(40 / img.size.width, 40 / img.size.height);
            CGSize sz = CGSizeMake(img.size.width * k, img.size.height * k);
            [img drawInRect:CGRectMake((40 - sz.width) / 2, (40 - sz.height) / 2, sz.width, sz.height)];
            wc.imageView.image = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
        }];
    }
    if ([GMVal(s, @"installed") boolValue]) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 70, 30)];
        l.text = @"Đã thêm";
        l.font = [UIFont systemFontOfSize:13];
        l.textColor = [GMTheme secondaryText];
        l.backgroundColor = [UIColor clearColor];
        l.textAlignment = GMAlignRight;
        c.accessoryView = l;
    } else {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(0, 0, 64, 44);
        [b setBackgroundImage:[GMTheme sendButtonImage:NO] forState:UIControlStateNormal];
        [b setBackgroundImage:[GMTheme sendButtonImage:YES] forState:UIControlStateHighlighted];
        [b setTitle:@"Thêm" forState:UIControlStateNormal];
        [b setTitleShadowColor:[UIColor colorWithWhite:0 alpha:0.35] forState:UIControlStateNormal];
        b.titleLabel.shadowOffset = CGSizeMake(0, -1);
        b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        b.adjustsImageWhenHighlighted = NO;
        objc_setAssociatedObject(b, &kCoverKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [b addTarget:self action:@selector(addTapped:) forControlEvents:UIControlEventTouchUpInside];
        c.accessoryView = b;
    }
    return c;
}

- (void)addTapped:(UIButton *)b {
    NSDictionary *s = objc_getAssociatedObject(b, &kCoverKey);
    if (!s) return;
    b.enabled = NO;
    [GMCore call:@"stickers.install" args:GMSetKey(s) done:^(id ok, NSDictionary *err) {
        b.enabled = YES;
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.view];
            return;
        }
        NSMutableDictionary *m = [s mutableCopy];
        [m setObject:@YES forKey:@"installed"];
        [[NSNotificationCenter defaultCenter] postNotificationName:GMStickersChangedNotification object:nil userInfo:@{@"set": m}];
        [GMTheme toast:[NSString stringWithFormat:@"Đã thêm «%@»", GMVal(s, @"title")] in:self.view];
    }];
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    return !_results && ip.section == GMSecMine && _mine.count > 0;
}

- (NSString *)tableView:(UITableView *)tv titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)ip {
    return @"Gỡ";
}

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete || ip.row >= (NSInteger)_mine.count) return;
    NSDictionary *s = [_mine objectAtIndex:ip.row];
    [GMCore call:@"stickers.uninstall" args:GMSetKey(s) done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.view];
            return;
        }
        NSMutableDictionary *m = [s mutableCopy];
        [m setObject:@NO forKey:@"installed"];
        [[NSNotificationCenter defaultCenter] postNotificationName:GMStickersChangedNotification object:nil userInfo:@{@"set": m}];
    }];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (!_results && ip.section == GMSecCreate) {
        [self openStickersBot];
        return;
    }
    NSArray *list = [self listFor:ip.section];
    if (ip.row >= (NSInteger)list.count) return;
    [GMStickerSetViewController present:[list objectAtIndex:ip.row] from:self pick:self.pick];
}

/// Mở chat với bot @Stickers (Telegram gốc tự tải sticker lên qua bot này: /newpack → tên → gửi ảnh PNG 512 px + emoji).
- (void)openStickersBot {
    [GMCore call:@"contacts.resolve" args:@{@"username": @"Stickers"} done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.view];
            return;
        }
        GMChatListViewController *list = ((GMAppDelegate *)[UIApplication sharedApplication].delegate).list;
        void (^open)(void) = ^{
            [list openChat:ok jumpTo:nil];
        };
        if (self.presentingViewController) [self dismissViewControllerAnimated:YES completion:open];
        else open();
    }];
}

@end
