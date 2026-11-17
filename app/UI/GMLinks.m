#import "GMLinks.h"
#import "GMCore.h"
#import "GMTheme.h"
#import "GMAlert.h"
#import "GMLog.h"
#import "GMAppDelegate.h"
#import "GMChatListViewController.h"

@implementation GMLinks

+ (BOOL)isTelegramLink:(NSString *)link {
    NSString *low = link.lowercaseString;
    if ([low hasPrefix:@"@"]) return low.length > 3;
    if ([low hasPrefix:@"tg://"]) {
        for (NSString *k in @[@"resolve", @"join", @"privatepost", @"user"]) {
            if ([low hasPrefix:[@"tg://" stringByAppendingString:k]]) return YES;
        }
        return NO;
    }
    for (NSString *p in @[@"https://", @"http://"]) {
        if ([low hasPrefix:p]) {
            low = [low substringFromIndex:p.length];
            break;
        }
    }
    if ([low hasPrefix:@"www."]) low = [low substringFromIndex:4];
    for (NSString *h in @[@"t.me/", @"telegram.me/", @"telegram.dog/"]) {
        if (![low hasPrefix:h]) continue;
        NSString *rest = [low substringFromIndex:h.length];
        for (NSString *skip in @[@"proxy", @"socks", @"addstickers", @"addemoji", @"share", @"login", @"setlanguage"]) {
            if ([rest hasPrefix:skip]) return NO;
        }
        return rest.length > 0;
    }
    return NO;
}

+ (void)openWeb:(NSString *)link {
    NSString *l = link;
    if ([l rangeOfString:@"://"].location == NSNotFound) l = [@"http://" stringByAppendingString:l];
    NSURL *u = [NSURL URLWithString:l];
    if (u) [[UIApplication sharedApplication] openURL:u];
}

+ (GMChatListViewController *)list {
    return ((GMAppDelegate *)[UIApplication sharedApplication].delegate).list;
}

+ (void)open:(NSString *)link in:(UIView *)view {
    if (![self isTelegramLink:link]) {
        [self openWeb:link];
        return;
    }
    [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
    [GMCore call:@"link.resolve" args:@{@"url": link} done:^(id ok, NSDictionary *err) {
        [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
        if (err) {
            [GMTheme toast:GMErrorText(err) in:view];
            return;
        }
        NSString *type = GMVal(ok, @"type");
        GMLog(@"link Telegram: %@", type);
        if ([type isEqual:@"peer"]) {
            [[self list] openChat:GMVal(ok, @"peer") jumpTo:GMVal(ok, @"msg")];
        } else if ([type isEqual:@"invite"]) {
            [self askJoin:ok in:view];
        } else {
            [self openWeb:link];
        }
    }];
}

/// Lời mời vào nhóm / kênh chưa ở trong: tên, số thành viên, giới thiệu → «Tham gia» (nhóm cần duyệt: «Gửi yêu cầu»).
+ (void)askJoin:(NSDictionary *)inv in:(UIView *)view {
    BOOL channel = [GMVal(inv, @"channel") boolValue], request = [GMVal(inv, @"request") boolValue];
    NSMutableString *msg = [NSMutableString stringWithFormat:@"%@ · %@ %@", channel ? @"Kênh" : @"Nhóm",
                                                             GMVal(inv, @"members") ?: @0, channel ? @"người theo dõi" : @"thành viên"];
    NSString *about = GMVal(inv, @"about");
    if (about.length) [msg appendFormat:@"\n\n%@", about.length > 300 ? [[about substringToIndex:300] stringByAppendingString:@"…"] : about];
    if (request) [msg appendString:@"\n\nNhóm này cần quản trị viên duyệt."];
    NSString *hash = GMVal(inv, @"hash");
    GMAlertShow(GMVal(inv, @"title") ?: @"Lời mời", msg, @"Huỷ", request ? @"Gửi yêu cầu" : (channel ? @"Tham gia kênh" : @"Tham gia nhóm"),
                ^(NSInteger i) {
                    if (i != 1) return;
                    [GMCore call:@"chats.join" args:@{@"hash": hash} done:^(id ok, NSDictionary *err) {
                        if (err) {
                            GMAlertShow(@"Chưa vào được", GMErrorText(err), @"OK", nil, nil);
                            return;
                        }
                        [[self list] reload];
                        [[self list] openChat:ok jumpTo:nil];
                    }];
                });
}

@end
