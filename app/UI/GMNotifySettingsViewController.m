#import "GMNotifySettingsViewController.h"
#import "GMBackground.h"

@implementation GMNotifySettingsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Thông báo";
}

static NSArray *GMNotifyRows(NSInteger section) {
    if (section == 0) return @[@[@"Hiện thông báo", GMPrefNotify], @[@"Xem trước nội dung", GMPrefPreview], @[@"Âm thanh", GMPrefSound]];
    return @[@[@"Số trên biểu tượng app", GMPrefBadge]];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return GMNotifyRows(section).count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"Tin nhắn" : @"Biểu tượng app";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"Chat đã tắt tiếng không báo (trừ khi có người nhắc tới bạn). Tắt «Xem trước» thì thông báo chỉ ghi «Tin nhắn mới».";
    }
    return @"GramMini giữ kết nối với Telegram khi chạy nền (chế độ VoIP của iOS) để báo tin mới. Nếu tắt hẳn app khỏi thanh "
           @"đa nhiệm, có thể không nhận thông báo cho tới khi mở lại app.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    NSArray *row = [GMNotifyRows(ip.section) objectAtIndex:ip.row];
    c.textLabel.text = [row objectAtIndex:0];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = GMPref([row objectAtIndex:1]);
    sw.tag = ip.section * 10 + ip.row;
    [sw addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
    c.accessoryView = sw;
    return c;
}

- (void)toggled:(UISwitch *)sw {
    NSArray *row = [GMNotifyRows(sw.tag / 10) objectAtIndex:sw.tag % 10];
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:[row objectAtIndex:1]];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[GMBackground shared] updateBadge];
}

@end
