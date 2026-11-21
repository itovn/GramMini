#import "GMCallManager.h"
#import "GMAlert.h"
#import "GMAppDelegate.h"
#import "GMCallAudio.h"
#import "GMCallViewController.h"
#import "GMChatListViewController.h"
#import "GMCore.h"
#import "GMLog.h"
#import "GMTheme.h"
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>

@implementation GMCallManager {
    GMCallViewController *_screen;
    NSDictionary *_chat;
    NSString *_callId;
    NSTimer *_ringTimer, *_statsTimer;
    SystemSoundID _ringSound;
    UILocalNotification *_note;
}

+ (GMCallManager *)shared {
    static GMCallManager *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [GMCallManager new]; });
    return s;
}

- (void)attach {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(event:) name:GMCoreEventNotification object:nil];
    [nc addObserver:self selector:@selector(becameActive) name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (BOOL)active {
    return _state && ![GMVal(_state, @"state") isEqual:@"ended"];
}

/// Hội thoại riêng của `peer` trong danh sách chat (tên, ảnh) — nil nếu không thấy.
- (NSDictionary *)chatForPeer:(id)peer {
    GMChatListViewController *list = ((GMAppDelegate *)[UIApplication sharedApplication].delegate).list;
    NSString *key = [peer description];
    for (NSInteger r = 0; key && r < 2000; r++) {
        NSDictionary *d = [list debugDialogAt:r];
        if (!d) break;
        if ([[GMVal(d, @"peer") description] isEqual:key]) return d;
    }
    return key ? @{@"peer": key} : nil;
}

- (NSString *)nameText {
    NSString *n = GMVal(_chat, @"name");
    return n.length ? n : @"Cuộc gọi thoại";
}

- (BOOL)inBackground {
    return [UIApplication sharedApplication].applicationState == UIApplicationStateBackground;
}

#pragma mark Sự kiện lõi

- (void)event:(NSNotification *)n {
    NSDictionary *ev = n.userInfo;
    NSString *e = GMVal(ev, @"e");
    if ([e isEqual:@"call.quality"]) {
        if ([[GMVal(ev, @"call_id") description] isEqual:_callId]) [_screen setBars:[GMVal(ev, @"bars") integerValue]];
        return;
    }
    if (![e isEqual:@"call.state"]) return;
    NSString *st = GMVal(ev, @"state");
    NSString *cid = [GMVal(ev, @"call_id") description];
    if (_callId && ![cid isEqual:_callId] && self.active) return;  // sự kiện của cuộc gọi khác (lõi đã báo bận)
    if (![cid isEqual:_callId]) {
        _callId = cid;
        _chat = [self chatForPeer:GMVal(ev, @"peer")];
    }
    NSString *prev = GMVal(_state, @"state");
    _state = ev;
    NSArray *emoji = GMVal(ev, @"emoji");
    GMLog(@"[gọi] %@%@%@", st,
          [emoji isKindOfClass:[NSArray class]] ? [@" " stringByAppendingString:[emoji componentsJoinedByString:@" "]] : @"",
          GMVal(ev, @"reason") ? [@" — " stringByAppendingString:GMVal(ev, @"reason")] : @"");

    if ([st isEqual:@"incoming"]) {
        [self startRinging];
    } else {
        [self stopRinging];
    }
    // Âm thanh: bên gọi bật ngay (tiếng chờ qua đường gọi), bên nghe bật lúc nghe máy (accept)
    if ([st isEqual:@"requesting"] || [st isEqual:@"ringing"] || [st isEqual:@"exchanging"] || [st isEqual:@"connecting"]) {
        if (![GMCallAudio shared].running && ![[GMCallAudio shared] start]) {
            GMAlertShow(@"Không mở được micro / loa", nil, @"OK", nil, nil);
        }
    }
    [GMCallAudio shared].ringback = [st isEqual:@"ringing"];
    if ([st isEqual:@"connected"] && !_statsTimer) {
#ifdef DEBUG
        _statsTimer = [NSTimer scheduledTimerWithTimeInterval:5 target:self selector:@selector(statsTick) userInfo:nil repeats:YES];
#endif
    }

    if ([st isEqual:@"ended"]) {
        [self ended:ev previous:prev];
        return;
    }
    [self showScreen];
    [_screen update:ev];
}

- (void)ended:(NSDictionary *)ev previous:(NSString *)prev {
    [[GMCallAudio shared] stop];
    [GMCallAudio shared].ringback = NO;
    [GMCallAudio shared].speaker = NO;
    [_statsTimer invalidate];
    _statsTimer = nil;
    [self cancelNote];
    NSString *r = GMVal(ev, @"reason");
    // Cuộc gọi đến chưa nghe mà người gọi huỷ (máy chủ báo Missed; máy khác nghe / từ chối thì «elsewhere»)
    BOOL missedIncoming = ![GMVal(ev, @"outgoing") boolValue] && [prev isEqual:@"incoming"] && [r isEqual:@"missed"];
    if (missedIncoming && [self inBackground]) {
        UILocalNotification *ln = [[UILocalNotification alloc] init];
        ln.alertBody = [NSString stringWithFormat:@"Cuộc gọi nhỡ — %@", [self nameText]];
        ln.userInfo = @{@"peer": GMVal(_chat, @"peer") ?: @""};
        [[UIApplication sharedApplication] presentLocalNotificationNow:ln];
        GMLog(@"[gọi] app ở nền: thông báo cuộc gọi nhỡ");
    }
    if (_screen) {
        [_screen update:ev];
        GMCallViewController *s = _screen;
        _screen = nil;
        // Để người dùng thấy «Cuộc gọi kết thúc» / lý do một chút rồi đóng
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [s.presentingViewController dismissViewControllerAnimated:YES completion:nil];
        });
    }
}

#pragma mark Màn cuộc gọi

/// Màn trên cùng để hiện màn cuộc gọi lên.
- (UIViewController *)topController {
    UIViewController *vc = [UIApplication sharedApplication].keyWindow.rootViewController
        ?: ((GMAppDelegate *)[UIApplication sharedApplication].delegate).window.rootViewController;
    while (vc.presentedViewController && vc.presentedViewController != _screen) vc = vc.presentedViewController;
    return vc;
}

- (void)showScreen {
    if (_screen) return;
    _screen = [[GMCallViewController alloc] initWithChat:_chat];
    [_screen update:_state];
    UIViewController *top = [self topController];
    [top presentViewController:_screen animated:![self inBackground] completion:nil];
}

- (void)becameActive {
    // Mở app từ thông báo cuộc gọi đến: màn cuộc gọi đã có thì thôi
    if (self.active && !_screen) [self showScreen];
}

#pragma mark Chuông

- (void)startRinging {
    if ([self inBackground]) {
        // App ở nền: thông báo kèm chuông dài (≤ 30 giây — giới hạn của iOS cho âm thanh thông báo)
        if (!_note) {
            _note = [[UILocalNotification alloc] init];
            _note.alertBody = [NSString stringWithFormat:@"%@ đang gọi…", [self nameText]];
            _note.alertAction = @"Nghe";
            _note.soundName = @"call-ring-long.wav";
            _note.userInfo = @{@"call": @YES};
            [[UIApplication sharedApplication] presentLocalNotificationNow:_note];
            GMLog(@"[gọi] app ở nền: thông báo cuộc gọi đến + chuông dài");
        }
        return;
    }
    if (_ringTimer) return;
    if (!_ringSound) {
        NSURL *u = [[NSBundle mainBundle] URLForResource:@"call-ring" withExtension:@"wav"];
        if (u) AudioServicesCreateSystemSoundID((__bridge CFURLRef)u, &_ringSound);
    }
    [self ringOnce];
    _ringTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(ringOnce) userInfo:nil repeats:YES];
}

/// Một hồi chuông: AudioServicesPlayAlertSound tự rung, và theo công tắc im lặng của máy (im lặng → chỉ rung).
- (void)ringOnce {
    if (_ringSound) AudioServicesPlayAlertSound(_ringSound);
    else AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
}

- (void)stopRinging {
    [_ringTimer invalidate];
    _ringTimer = nil;
    [self cancelNote];
}

- (void)cancelNote {
    if (_note) {
        [[UIApplication sharedApplication] cancelLocalNotification:_note];
        _note = nil;
    }
}

#pragma mark Lệnh

- (void)callChat:(NSDictionary *)chat {
    if (self.active) {
        [self showScreen];
        return;
    }
    NSString *peer = [GMVal(chat, @"peer") description];
    if (!peer.length) return;
    _chat = chat;
    _callId = nil;
    [GMCore call:@"call.request" args:@{@"peer": peer} done:^(id ok, NSDictionary *err) {
        if (err) GMAlertShow(@"Không gọi được", GMErrorText(err), @"OK", nil, nil);
    }];
}

- (void)callPeer:(NSString *)peer {
    [self callChat:[self chatForPeer:peer]];
}

- (void)accept {
    // Chỉ khi đang có cuộc gọi đến (lệnh thử / bấm trễ sau khi bên kia huỷ: không bật micro vô cớ)
    if (![GMVal(_state, @"state") isEqual:@"incoming"]) return;
    [self stopRinging];
    [[GMCallAudio shared] start];
    [GMCore call:@"call.accept" args:@{} done:^(id ok, NSDictionary *err) {
        if (err) {
            if (!self.active || [GMVal(_state, @"state") isEqual:@"incoming"]) [[GMCallAudio shared] stop];
            GMAlertShow(@"Không nghe được", GMErrorText(err), @"OK", nil, nil);
        }
    }];
}

- (void)decline {
    if (![GMVal(_state, @"state") isEqual:@"incoming"]) return;
    [self stopRinging];
    [GMCore call:@"call.hangup" args:@{@"reason": @"busy"} done:nil];
}

- (void)hangup {
    if (!self.active) {
        [[GMCallAudio shared] stop];  // không còn cuộc gọi: tắt âm thanh còn sót (nếu có)
        return;
    }
    [GMCore call:@"call.hangup" args:@{} done:nil];
}

- (void)setMuted:(BOOL)muted {
    [GMCore call:@"call.mute" args:@{@"on": @(muted)} done:nil];
}

- (void)setSpeaker:(BOOL)speaker {
    [GMCallAudio shared].speaker = speaker;
    if (_state) [_screen update:_state];  // vẽ lại nút loa (đổi từ lệnh / tai nghe, không chỉ từ nút trên màn)
}

/// Gỡ lỗi: mỗi 5 giây ghi số liệu cuộc gọi vào app.log (gói đi / đến, mức micro, loa thiếu mẫu).
- (void)statsTick {
    [GMCore call:@"call.state" args:@{} done:^(id ok, NSDictionary *err) {
        if ([ok isKindOfClass:[NSDictionary class]] && GMVal(ok, @"stats")) GMLog(@"[gọi] %@ — %@", GMVal(ok, @"state"), GMVal(ok, @"stats"));
    }];
}

@end
