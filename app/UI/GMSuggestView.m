#import "GMSuggestView.h"
#import "GMTheme.h"

static const CGFloat kRow = 44;

@implementation GMSuggestView {
    UITableView *_t;
}

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = [GMTheme cellBackground];
        _t = [[UITableView alloc] initWithFrame:self.bounds style:UITableViewStylePlain];
        _t.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _t.dataSource = self;
        _t.delegate = self;
        _t.rowHeight = kRow;
        _t.backgroundColor = [UIColor clearColor];
        _t.tag = GMTagNoWallpaper;
        [self addSubview:_t];
        UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, 0, f.size.width, 1)];
        line.backgroundColor = [GMTheme separator];
        line.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self addSubview:line];
    }
    return self;
}

- (void)setItems:(NSArray *)items {
    _items = [items copy];
    [_t reloadData];
    [_t setContentOffset:CGPointZero animated:NO];
}

- (CGFloat)wantedHeight {
    return MIN(4, self.items.count) * kRow;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"g"];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"g"];
        c.backgroundColor = [UIColor clearColor];
        c.textLabel.font = [UIFont boldSystemFontOfSize:15];
        c.detailTextLabel.font = [UIFont systemFontOfSize:13];
    }
    NSDictionary *it = [self.items objectAtIndex:ip.row];
    c.textLabel.text = [it objectForKey:@"t"];
    c.textLabel.textColor = [[it objectForKey:@"kind"] isEqual:@"add"] ? [GMTheme accent] : [GMTheme text];
    c.textLabel.backgroundColor = [UIColor clearColor];
    c.detailTextLabel.text = [it objectForKey:@"d"];
    c.detailTextLabel.textColor = [GMTheme secondaryText];
    c.detailTextLabel.backgroundColor = [UIColor clearColor];
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:NO];
    if (self.pick) self.pick([self.items objectAtIndex:ip.row]);
}

@end
