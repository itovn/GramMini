#import "GMScheduledViewController.h"
#import "GMCore.h"
#import "GMTheme.h"
#import "GMLog.h"

NSString *GMScheduleText(NSTimeInterval unix) {
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:unix];
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *c = [cal components:NSYearCalendarUnit | NSMonthCalendarUnit | NSDayCalendarUnit | NSHourCalendarUnit |
                                          NSMinuteCalendarUnit fromDate:d];
    NSDateComponents *t = [cal components:NSYearCalendarUnit | NSMonthCalendarUnit | NSDayCalendarUnit fromDate:[NSDate date]];
    NSDate *today = [cal dateFromComponents:t];
    NSInteger days = (NSInteger)floor([d timeIntervalSinceDate:today] / 86400);
    NSString *clock = [NSString stringWithFormat:@"%02ld:%02ld", (long)c.hour, (long)c.minute];
    if (days == 0) return [clock stringByAppendingString:@" hôm nay"];
    if (days == 1) return [clock stringByAppendingString:@" mai"];
    if (c.year == t.year) return [NSString stringWithFormat:@"%@ %02ld/%02ld", clock, (long)c.day, (long)c.month];
    return [NSString stringWithFormat:@"%@ %02ld/%02ld/%ld", clock, (long)c.day, (long)c.month, (long)c.year];
}

@implementation GMScheduledViewController {
    NSMutableArray *_msgs;
    NSDictionary *_picked;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStylePlain];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.saved ? @"Lời nhắc" : @"Tin hẹn giờ";
    _msgs = [NSMutableArray array];
    [self load];
}

- (void)load {
    [GMCore call:@"messages.scheduled" args:@{@"peer": self.peer} done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.view];
            return;
        }
        [_msgs removeAllObjects];
        if ([ok isKindOfClass:[NSArray class]]) [_msgs addObjectsFromArray:ok];
        [self.tableView reloadData];
        if (self.changed) self.changed((NSInteger)_msgs.count);
    }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _msgs.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (_msgs.count) return nil;
    return self.saved ? @"Chưa có lời nhắc nào. Nhấn giữ nút «Gửi» khi soạn tin để đặt lời nhắc."
                      : @"Chưa có tin hẹn giờ. Nhấn giữ nút «Gửi» khi soạn tin để hẹn giờ gửi.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"s"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"s"];
    NSDictionary *m = [_msgs objectAtIndex:ip.row];
    c.textLabel.text = [[GMTheme preview:m] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    c.textLabel.textColor = [GMTheme text];
    c.textLabel.backgroundColor = [UIColor clearColor];
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@ %@", self.saved ? @"Nhắc lúc" : @"Gửi lúc",
                                                        GMScheduleText([GMVal(m, @"date") doubleValue])];
    c.detailTextLabel.textColor = [GMTheme accent];
    c.detailTextLabel.backgroundColor = [UIColor clearColor];
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    _picked = [_msgs objectAtIndex:ip.row];
    UIActionSheet *s = [[UIActionSheet alloc] initWithTitle:nil delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil
                                          otherButtonTitles:@"Gửi ngay", nil];
    s.destructiveButtonIndex = [s addButtonWithTitle:self.saved ? @"Xoá lời nhắc" : @"Huỷ hẹn giờ"];
    s.cancelButtonIndex = [s addButtonWithTitle:@"Đóng"];
    [s showInView:self.view];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)i {
    if (!_picked || i == sheet.cancelButtonIndex || i < 0) return;
    [self act:i == 0 ? @"messages.scheduledSend" : @"messages.scheduledDelete" on:_picked];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style == UITableViewCellEditingStyleDelete) [self act:@"messages.scheduledDelete" on:[_msgs objectAtIndex:ip.row]];
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)ip {
    return @"Huỷ";
}

- (void)act:(NSString *)method on:(NSDictionary *)m {
    [GMCore call:method args:@{@"peer": self.peer, @"ids": @[GMVal(m, @"id")]} done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.view];
            return;
        }
        GMLog(@"tin hẹn giờ: %@", [method hasSuffix:@"Send"] ? @"đã gửi ngay" : @"đã huỷ");
        [self load];
    }];
}

/// Công cụ thử: «0 send» / «0 delete».
- (void)debugAct:(NSString *)arg {
    NSArray *p = [arg componentsSeparatedByString:@" "];
    NSInteger i = [[p objectAtIndex:0] integerValue];
    if (i < 0 || i >= (NSInteger)_msgs.count || p.count < 2) return;
    [self act:[[p objectAtIndex:1] isEqual:@"send"] ? @"messages.scheduledSend" : @"messages.scheduledDelete" on:[_msgs objectAtIndex:i]];
}

@end
