#import "GMSharedMediaViewController.h"
#import "GMAppDelegate.h"
#import "GMChatListViewController.h"
#import "GMCore.h"
#import "GMFiles.h"
#import "GMImages.h"
#import "GMPhotoViewController.h"
#import "GMTheme.h"
#import <MediaPlayer/MediaPlayer.h>

static const NSInteger kCols = 4;

@implementation GMSharedMediaViewController {
    NSMutableArray *_items;
    BOOL _loading, _noMore;
    UILabel *_empty;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStylePlain];
}

- (BOOL)grid {
    return [self.kind isEqual:@"photo"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    NSDictionary *titles = @{@"photo": @"Ảnh và video", @"file": @"Tệp", @"voice": @"Tin thoại", @"link": @"Liên kết"};
    self.title = [titles objectForKey:self.kind] ?: @"Đã chia sẻ";
    _items = [NSMutableArray array];
    if ([self grid]) self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _empty = [[UILabel alloc] initWithFrame:CGRectMake(0, 100, self.view.bounds.size.width, 40)];
    _empty.textAlignment = GMAlignCenter;
    _empty.textColor = [GMTheme secondaryText];
    _empty.backgroundColor = [UIColor clearColor];
    _empty.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.tableView addSubview:_empty];
    [self loadMore];
}

- (void)loadMore {
    if (_loading || _noMore) return;
    _loading = YES;
    if (!_items.count) _empty.text = @"Đang tải…";
    NSMutableDictionary *a = [@{@"peer": self.peer, @"kind": self.kind, @"limit": @60} mutableCopy];
    if (_items.count) [a setObject:GMVal(_items.lastObject, @"id") forKey:@"offset_id"];
    [GMCore call:@"messages.media" args:a done:^(id ok, NSDictionary *err) {
        _loading = NO;
        if (![ok isKindOfClass:[NSArray class]]) {
            _empty.text = _items.count ? @"" : GMErrorText(err);
            return;
        }
        if ([ok count] < 60) _noMore = YES;
        [_items addObjectsFromArray:ok];
        _empty.text = _items.count ? @"" : @"Chưa có gì.";
        [self.tableView reloadData];
    }];
}

- (void)scrollViewDidScroll:(UIScrollView *)sv {
    if (sv.contentOffset.y + sv.bounds.size.height > sv.contentSize.height - 200) [self loadMore];
}

#pragma mark Bảng

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return [self grid] ? (_items.count + kCols - 1) / kCols : _items.count;
}

- (CGFloat)side {
    return floor((self.tableView.bounds.size.width - (kCols + 1) * 2) / kCols);
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return [self grid] ? [self side] + 2 : 60;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (![self grid]) return [self listCell:tv at:ip];
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"g"];
    CGFloat side = [self side];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"g"];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        for (NSInteger i = 0; i < kCols; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.tag = 100 + i;
            b.imageView.contentMode = UIViewContentModeScaleAspectFill;
            b.adjustsImageWhenHighlighted = NO;
            b.clipsToBounds = YES;
            b.backgroundColor = [GMTheme placeholderFill];
            [b addTarget:self action:@selector(gridTapped:) forControlEvents:UIControlEventTouchUpInside];
            UILabel *badge = [[UILabel alloc] init];
            badge.tag = 200;
            badge.font = [UIFont boldSystemFontOfSize:11];
            badge.textColor = [UIColor whiteColor];
            badge.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
            badge.textAlignment = GMAlignCenter;
            [b addSubview:badge];
            [c.contentView addSubview:b];
        }
    }
    for (NSInteger i = 0; i < kCols; i++) {
        UIButton *b = (UIButton *)[c.contentView viewWithTag:100 + i];
        b.frame = CGRectMake(2 + i * (side + 2), 2, side, side);
        NSInteger idx = ip.row * kCols + i;
        b.hidden = idx >= (NSInteger)_items.count;
        if (b.hidden) continue;
        NSDictionary *m = [_items objectAtIndex:idx];
        b.accessibilityLabel = [NSString stringWithFormat:@"%ld", (long)idx];
        UILabel *badge = (UILabel *)[b viewWithTag:200];
        NSDictionary *doc = GMVal(m, @"doc");
        BOOL video = doc != nil;
        badge.hidden = !video;
        if (video) {
            int d = [GMVal(doc, @"duration") intValue];
            badge.text = [NSString stringWithFormat:@"► %d:%02d", d / 60, d % 60];
            badge.frame = CGRectMake(0, side - 16, side, 16);
        }
        NSNumber *mid = GMVal(m, @"id");
        UIImage *ph = video ? [GMImages imageFromBase64:GMVal(doc, @"thumb")] : [GMImages imageFromBase64:GMVal(GMVal(m, @"photo"), @"thumb")];
        if (!ph && video && ![GMVal(doc, @"has_thumb") boolValue]) ph = [GMTheme fileIcon:@"mp4"];  // video không có ảnh xem trước
        [b setImage:ph forState:UIControlStateNormal];
        __weak UIButton *wb = b;
        void (^set)(UIImage *) = ^(UIImage *img) {
            if (img && [wb.accessibilityLabel isEqual:[NSString stringWithFormat:@"%ld", (long)idx]]) [wb setImage:img forState:UIControlStateNormal];
        };
        CGFloat px = side * [UIScreen mainScreen].scale;
        if (video) {
            if ([GMVal(doc, @"has_thumb") boolValue]) [GMImages thumbForPeer:self.peer msg:mid maxPixel:px done:set];
        } else {
            [GMImages photoForPeer:self.peer msg:mid big:NO maxPixel:px done:set];
        }
    }
    return c;
}

- (UITableViewCell *)listCell:(UITableView *)tv at:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"l"];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"l"];
        c.detailTextLabel.textColor = [GMTheme secondaryText];
    }
    NSDictionary *m = [_items objectAtIndex:ip.row];
    NSString *when = [GMTheme shortTime:GMVal(m, @"date")];
    if ([self.kind isEqual:@"file"]) {
        NSDictionary *doc = GMVal(m, @"doc");
        NSString *name = GMVal(doc, @"name");
        c.textLabel.text = name.length ? name : @"Tệp";
        c.imageView.image = [GMTheme fileIcon:name.pathExtension];
        c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", [GMTheme sizeText:[GMVal(doc, @"size") doubleValue]], when];
    } else if ([self.kind isEqual:@"voice"]) {
        int d = [GMVal(GMVal(m, @"voice"), @"duration") intValue] ?: [GMVal(GMVal(m, @"doc"), @"duration") intValue];
        c.textLabel.text = [NSString stringWithFormat:@"%@ · %d:%02d", [GMVal(m, @"out") boolValue] ? @"Bạn" : (GMVal(m, @"from") ?: @"Tin thoại"), d / 60, d % 60];
        c.imageView.image = [GMTheme fileIcon:@"ogg"];
        c.detailTextLabel.text = when;
    } else {
        NSArray *links = GMVal(m, @"links");
        c.textLabel.text = [links isKindOfClass:[NSArray class]] && links.count ? [links objectAtIndex:0] : [GMTheme preview:m];
        c.imageView.image = [GMTheme fileIcon:@"url"];
        c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", when, [GMTheme preview:m]];
    }
    return c;
}

#pragma mark Chạm

- (void)gridTapped:(UIButton *)b {
    NSInteger idx = b.accessibilityLabel.integerValue;
    if (idx < 0 || idx >= (NSInteger)_items.count) return;
    NSDictionary *m = [_items objectAtIndex:idx];
    if (GMVal(m, @"photo")) {
        GMPhotoViewController *p = [[GMPhotoViewController alloc] init];
        p.peer = self.peer;
        p.msgId = GMVal(m, @"id");
        p.preview = [b imageForState:UIControlStateNormal];
        p.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        [self presentViewController:p animated:YES completion:nil];
        return;
    }
    // Video: tải (có rồi thì mở ngay) rồi phát
    [GMTheme toast:@"Đang mở video…" in:self.navigationController.view];
    [[GMFiles shared] fetch:self.peer msg:GMVal(m, @"id") done:^(NSString *path) {
        if (!path) return;
        MPMoviePlayerViewController *mp = [[MPMoviePlayerViewController alloc] initWithContentURL:[NSURL fileURLWithPath:path]];
        [self presentMoviePlayerViewControllerAnimated:mp];
    }];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if ([self grid]) return;
    NSDictionary *m = [_items objectAtIndex:ip.row];
    NSArray *links = GMVal(m, @"links");
    if ([self.kind isEqual:@"link"] && [links isKindOfClass:[NSArray class]] && links.count) {
        NSString *l = [links objectAtIndex:0];
        if (![l hasPrefix:@"http"]) l = [@"http://" stringByAppendingString:l];
        NSURL *u = [NSURL URLWithString:l];
        if (u) [[UIApplication sharedApplication] openURL:u];
        return;
    }
    GMAppDelegate *app = (GMAppDelegate *)[UIApplication sharedApplication].delegate;
    [app.list openChat:@{@"peer": self.peer, @"name": self.chatName ?: @""} jumpTo:GMVal(m, @"id")];
}

@end
