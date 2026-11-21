#import "GMBackground.h"
#import "GMChatListViewController.h"
#import "GMCore.h"
#import "GMLog.h"
#import "GMTheme.h"
#import <CFNetwork/CFNetwork.h>
#include <fcntl.h>

NSString *const GMPrefNotify = @"notify.on", *const GMPrefPreview = @"notify.preview", *const GMPrefSound = @"notify.sound",
                *const GMPrefBadge = @"notify.badge";

BOOL GMPref(NSString *key) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return v ? [v boolValue] : YES;
}

/// Cặp CFStream bọc một socket của lõi (không tự đóng socket — lõi đóng).
@interface GMVoipSocket : NSObject {
@public
    CFReadStreamRef r;
    CFWriteStreamRef w;
}
@property (nonatomic, strong) NSNumber *dc;
@end

@implementation GMVoipSocket
- (void)dealloc {
    if (r) {
        CFReadStreamSetClient(r, kCFStreamEventNone, NULL, NULL);
        CFReadStreamUnscheduleFromRunLoop(r, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        CFReadStreamClose(r);
        CFRelease(r);
    }
    if (w) {
        CFWriteStreamClose(w);
        CFRelease(w);
    }
}
@end

@interface GMBackground ()
- (void)rearm:(int)fd;
@end

static void GMVoipReadable(CFReadStreamRef stream, CFStreamEventType type, void *info) {
    // Không đọc ở đây (lõi đọc socket bằng tokio). CFStream chỉ báo «có dữ liệu» một lần rồi chờ chính nó đọc → bọc lại
    // socket bằng cặp CFStream mới (sau khi lõi đọc hết) để luôn có bộ theo dõi VoIP đang chờ — iOS đánh thức app qua đó.
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        GMLog(@"socket VoIP: có dữ liệu (app ở nền)");
    }
    [[GMBackground shared] rearm:(int)(intptr_t)info];
}

@implementation GMBackground {
    NSMutableDictionary *_sockets;  // fd → GMVoipSocket
    NSMutableSet *_rearming;        // fd đang chờ bọc lại
    UIBackgroundTaskIdentifier _task;
}

+ (instancetype)shared {
    static GMBackground *b;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ b = [[GMBackground alloc] init]; });
    return b;
}

- (void)start {
    _sockets = [NSMutableDictionary dictionary];
    _rearming = [NSMutableSet set];
    _task = UIBackgroundTaskInvalid;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(event:) name:GMCoreEventNotification object:nil];
    // iOS 5 / 6 chỉ hiện thông báo của app đã «đăng ký thông báo» (có mục trong Cài đặt → Thông báo); lần đầu iOS hỏi quyền.
    // Mã thiết bị APNs nhận về không dùng (thông báo là UILocalNotification do app tự phát).
#ifdef DEBUG
    // Bản thử: có tệp này thì chưa đăng ký (hộp hỏi quyền khỏi che màn khi tự thử giao diện trên máy khác)
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Documents/gm-noregister"]) return;
#endif
    [[UIApplication sharedApplication] registerForRemoteNotificationTypes:UIRemoteNotificationTypeAlert | UIRemoteNotificationTypeBadge |
                                                                          UIRemoteNotificationTypeSound];
}

#pragma mark Socket VoIP

- (void)rearm:(int)fd {
    NSNumber *key = @(fd);
    if ([_rearming containsObject:key]) return;
    [_rearming addObject:key];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [_rearming removeObject:key];
        GMVoipSocket *old = [_sockets objectForKey:key];
        if (old) [self adoptSocket:fd dc:old.dc quiet:YES];
    });
}

- (void)adoptSocket:(int)fd dc:(NSNumber *)dc {
    [self adoptSocket:fd dc:dc quiet:NO];
}

- (void)adoptSocket:(int)fd dc:(NSNumber *)dc quiet:(BOOL)quiet {
    NSNumber *key = @(fd);
    [_sockets removeObjectForKey:key];  // fd dùng lại = socket cũ đã đóng
    // Bỏ cặp của socket đã đóng
    for (NSNumber *k in _sockets.allKeys) {
        if (fcntl(k.intValue, F_GETFD) == -1) [_sockets removeObjectForKey:k];
    }
    if (fcntl(fd, F_GETFD) == -1) return;
    GMVoipSocket *s = [[GMVoipSocket alloc] init];
    s.dc = dc;
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, fd, &s->r, &s->w);
    if (!s->r || !s->w) {
        GMLog(@"socket VoIP: không bọc được fd %d", fd);
        return;
    }
    CFReadStreamSetProperty(s->r, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanFalse);
    CFWriteStreamSetProperty(s->w, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanFalse);
    BOOL voip = CFReadStreamSetProperty(s->r, kCFStreamNetworkServiceType, kCFStreamNetworkServiceTypeVoIP) &&
                CFWriteStreamSetProperty(s->w, kCFStreamNetworkServiceType, kCFStreamNetworkServiceTypeVoIP);
    CFStreamClientContext ctx = {0, (void *)(intptr_t)fd, NULL, NULL, NULL};
    CFReadStreamSetClient(s->r, kCFStreamEventHasBytesAvailable, GMVoipReadable, &ctx);
    CFReadStreamScheduleWithRunLoop(s->r, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    BOOL open = CFReadStreamOpen(s->r) && CFWriteStreamOpen(s->w);
    [_sockets setObject:s forKey:key];
    if (!quiet || !voip || !open) {
        GMLog(@"socket VoIP: fd %d (DC %@) %@%@", fd, dc, voip ? @"đã đánh dấu" : @"KHÔNG đánh dấu được", open ? @"" : @", mở lỗi");
    }
}

#pragma mark Nền

- (void)didEnterBackground {
    UIApplication *app = [UIApplication sharedApplication];
    if (!self.debugNoBackgroundTask && _task == UIBackgroundTaskInvalid) {
        _task = [app beginBackgroundTaskWithExpirationHandler:^{
            GMLog(@"hết thời gian chạy nền — app sẽ bị treo (socket VoIP đánh thức khi có tin)");
            [GMCore call:@"app.flush" args:nil done:nil];
            [app endBackgroundTask:_task];
            _task = UIBackgroundTaskInvalid;
        }];
    }
    self.debugNoBackgroundTask = NO;
    BOOL ka = [app setKeepAliveTimeout:600 handler:^{
        // iOS cho ~10 giây: hỏi máy chủ (kết nối chết thì lõi mở lại, lấy bù tin đã lỡ → thông báo)
        GMLog(@"giữ kết nối (10 phút một lần)");
        [GMCore call:@"net.check" args:nil done:nil];
    }];
    if (!ka) GMLog(@"setKeepAliveTimeout lỗi (thiếu UIBackgroundModes voip?)");
    [self updateBadge];
}

- (void)willEnterForeground {
    UIApplication *app = [UIApplication sharedApplication];
    if (_task != UIBackgroundTaskInvalid) {
        [app endBackgroundTask:_task];
        _task = UIBackgroundTaskInvalid;
    }
    [app cancelAllLocalNotifications];  // thông báo cũ trong Trung tâm thông báo
}

- (void)updateBadge {
    NSInteger n = [self.list unreadTotal];
    [UIApplication sharedApplication].applicationIconBadgeNumber = GMPref(GMPrefBadge) ? n : 0;
    // Mục «Chat» của thanh dưới: huy hiệu đỏ của iOS
    self.list.navigationController.tabBarItem.badgeValue = n > 0 ? (n > 999 ? @"999+" : [NSString stringWithFormat:@"%ld", (long)n]) : nil;
}

#pragma mark Tin mới

- (void)event:(NSNotification *)n {
    NSDictionary *ev = n.userInfo;
    NSString *e = GMVal(ev, @"e");
    if ([e isEqual:@"net.socket"]) {
        [self adoptSocket:[GMVal(ev, @"fd") intValue] dc:GMVal(ev, @"dc")];
        return;
    }
    if (![e isEqual:@"msg.new"]) return;
    // Chỉ khi app ở nền thật — app «không hoạt động» vì đang có hộp hệ thống (hỏi quyền Ảnh…) thì không thông báo: iOS giao
    // thông báo ngay cho app ở trạng thái Inactive, trông như người dùng vừa chạm vào → mở nhầm chat
    UIApplication *app = [UIApplication sharedApplication];
    if (app.applicationState != UIApplicationStateBackground) return;
    NSDictionary *m = GMVal(ev, @"msg");
    // Danh sách chat cập nhật số chưa đọc trước (cùng thông báo) — đợi lượt chạy sau rồi mới đọc
    dispatch_async(dispatch_get_main_queue(), ^{ [self notifyFor:m]; });
}

- (void)notifyFor:(NSDictionary *)m {
    [self updateBadge];
    if (!GMPref(GMPrefNotify)) return;
    NSString *peer = GMVal(m, @"peer");
    BOOL out = [GMVal(m, @"out") boolValue], scheduled = [GMVal(m, @"scheduled") boolValue];
    if (out && !scheduled) return;  // tin của mình (gửi từ máy khác) — trừ lời nhắc hẹn giờ
    if ([GMVal(m, @"silent") boolValue] && !scheduled) return;
    NSDictionary *d = [self.list dialogForPeer:peer];
    if ([GMVal(d, @"muted") boolValue] && ![GMVal(m, @"mentioned") boolValue]) return;
    // Tin cũ lấy bù sau khi mất kết nối lâu: không báo nữa
    if ([[NSDate date] timeIntervalSince1970] - [GMVal(m, @"date") doubleValue] > 6 * 3600) return;

    BOOL saved = [peer isEqual:self.list.myId];
    NSString *chat = saved ? @"Tin nhắn đã lưu" : (GMVal(d, @"name") ?: GMVal(m, @"from") ?: @"GramMini");
    NSString *from = GMVal(m, @"from");
    BOOL group = d ? ![GMVal(d, @"kind") isEqual:@"user"] : NO;
    NSString *title = scheduled ? [@"📅 " stringByAppendingString:chat]
                      : (group && from.length && ![from isEqual:chat]) ? [NSString stringWithFormat:@"%@ @ %@", from, chat]
                                                                       : chat;
    NSString *body = GMPref(GMPrefPreview) ? [GMTheme preview:m] : @"Tin nhắn mới";
    body = [GMTheme cut:body max:180];

    UILocalNotification *ln = [[UILocalNotification alloc] init];
    // Chữ thông báo phải đổi được sang UTF-8: SpringBoard iOS 6 gọi UTF8String không kiểm NULL → sập, máy vào safe mode (D36)
    ln.alertBody = [GMTheme validUTF16:[NSString stringWithFormat:@"%@: %@", title, body]];
    ln.alertAction = @"Xem";
    ln.userInfo = @{@"peer": peer ?: @""};
    if (GMPref(GMPrefSound)) ln.soundName = UILocalNotificationDefaultSoundName;
    if (GMPref(GMPrefBadge)) ln.applicationIconBadgeNumber = [self.list unreadTotal];
    [[UIApplication sharedApplication] presentLocalNotificationNow:ln];
    GMLog(@"thông báo tin %@ (chat %@, app %d)", GMVal(m, @"id"), saved ? @"đã lưu" : @"khác",
          (int)[UIApplication sharedApplication].applicationState);
}

@end
