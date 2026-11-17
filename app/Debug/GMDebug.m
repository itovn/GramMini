#include <sys/stat.h>
#import "GMDebug.h"
#import "GMAppDelegate.h"
#import "GMChatListViewController.h"
#import "GMChatViewController.h"
#import "GMTopicsViewController.h"
#import "GMTheme.h"
#import "GMChatInfoViewController.h"
#import "GMLottieView.h"
#import "GMCore.h"
#import "GMLog.h"
#import "GMProxyViewController.h"
#import "GMStorageViewController.h"
#import "GMFileBrowserViewController.h"
#import "GMBackground.h"
#import "GMPasscode.h"
#import "GMContactsViewController.h"
#import "GMNewGroupViewController.h"
#import "GMStickerSetViewController.h"
#import "GMLoginViewController.h"
#import "GMUpdate.h"
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import "GMFiles.h"
#import "GMHevcTranscoder.h"
#import "GMLinks.h"
#import "GMReactionPicker.h"
#import "GMScheduledViewController.h"
#import "GMMap.h"
#import "GMQuickReplies.h"
#import "GMVietQRViewController.h"

static NSString *const kCmdFile = @"/var/mobile/Documents/GramMini-cmd.txt";

@implementation GMDebug

static UIActionSheet *GMFindSheet(UIView *v) {
    if ([v isKindOfClass:[UIActionSheet class]]) return (UIActionSheet *)v;
    for (UIView *s in v.subviews) {
        UIActionSheet *r = GMFindSheet(s);
        if (r) return r;
    }
    return nil;
}

+ (void)start {
    [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    // Bản thử: giữ màn hình sáng để SSH / chụp màn hình không bị mất khi máy tự khoá
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    GMLog(@"[thử] đọc lệnh từ %@", kCmdFile);
}

+ (void)tick {
    struct stat st;
    if (lstat(kCmdFile.fileSystemRepresentation, &st) != 0) return;
    if (!S_ISREG(st.st_mode) || st.st_uid != 0) {
        [[NSFileManager defaultManager] removeItemAtPath:kCmdFile error:NULL];
        return;
    }
    NSString *s = [NSString stringWithContentsOfFile:kCmdFile encoding:NSUTF8StringEncoding error:NULL];
    if (!s) return;
    [[NSFileManager defaultManager] removeItemAtPath:kCmdFile error:NULL];
    for (NSString *raw in [s componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length) [self run:line];
    }
}

static void GMFindText(UIView *v, NSString *text) {
    if ([v isKindOfClass:[UILabel class]] && [((UILabel *)v).text isEqual:text]) {
        NSMutableString *chain = [NSMutableString string];
        for (UIView *p = v; p; p = p.superview) {
            [chain appendFormat:@" ← %@ %@%@%@", NSStringFromClass([p class]), NSStringFromCGRect(p.frame), p.hidden ? @" ẩn" : @"",
                                p.alpha < 0.01 ? @" alpha 0" : @""];
            if ([p isKindOfClass:[UITableViewCell class]]) {
                UITableView *tv = (UITableView *)p.superview;
                while (tv && ![tv isKindOfClass:[UITableView class]]) tv = (UITableView *)tv.superview;
                NSIndexPath *ip = [tv indexPathForCell:(UITableViewCell *)p];
                [chain appendFormat:@" (hàng %@)", ip ? @(ip.row) : @"không thuộc bảng"];
            }
        }
        GMLog(@"[thử] thấy «%@»:%@", text, chain);
    }
    for (UIView *s in v.subviews) GMFindText(s, text);
}

+ (void)run:(NSString *)line {
    GMAppDelegate *app = (GMAppDelegate *)[UIApplication sharedApplication].delegate;
    UINavigationController *nav = (UINavigationController *)app.tabs.selectedViewController;  // thanh điều hướng của mục đang chọn
    // iPad: lệnh nhắm vào bên phải (chat đang mở) nếu có; «L <lệnh>» = bên trái
    if ([line hasPrefix:@"L "]) {
        line = [line substringFromIndex:2];
    } else if (app.detail && ![app.detail.topViewController isKindOfClass:[GMEmptyDetailViewController class]]) {
        nav = app.detail;
    }
    UIViewController *top = nav.topViewController;
    NSRange sp = [line rangeOfString:@" "];
    NSString *cmd = sp.location == NSNotFound ? line : [line substringToIndex:sp.location];
    NSString *arg = sp.location == NSNotFound ? @"" : [line substringFromIndex:sp.location + 1];
    GMLog(@"[thử] %@", cmd);
    if ([cmd isEqual:@"opensaved"]) {
        // Tin nhắn đã lưu (tin thử chỉ gửi vào đây — «open 0» là chat đầu danh sách, có thể là chat thật)
        if (app.list.myId) [app.list openChat:@{@"peer": app.list.myId} jumpTo:nil];
    } else if ([cmd isEqual:@"open"]) {
        [app.list openRow:arg.integerValue];
    } else if ([cmd isEqual:@"forums"]) {
        // Ghi các hàng là nhóm có chủ đề (không mở gì; không ghi tên)
        for (NSInteger r = 0; r < 300; r++) {
            NSDictionary *d = [app.list debugDialogAt:r];
            if (!d) break;
            if ([GMVal(d, @"forum") boolValue]) GMLog(@"[thử] hàng %ld: nhóm có chủ đề %@", (long)r, GMVal(d, @"peer"));
        }
    } else if ([cmd isEqual:@"topic"] && [top isKindOfClass:[GMTopicsViewController class]]) {
        [(GMTopicsViewController *)top openTopicAt:arg.integerValue];
    } else if ([cmd isEqual:@"topicsall"] && [top isKindOfClass:[GMTopicsViewController class]]) {
        [(GMTopicsViewController *)top openAll];
    } else if ([cmd isEqual:@"playvideo"]) {
        // playvideo <peer> <id> — tải video để phát (lõi chọn bản H.264) rồi mở trình phát
        NSArray *p = [arg componentsSeparatedByString:@" "];
        if (p.count == 2) {
            NSNumber *mid = @([[p objectAtIndex:1] longLongValue]);
            NSString *peer = [p objectAtIndex:0];
            void (^play)(NSString *) = ^(NSString *path) {
                MPMoviePlayerViewController *mp = [[MPMoviePlayerViewController alloc] initWithContentURL:[NSURL fileURLWithPath:path]];
                [top presentMoviePlayerViewControllerAnimated:mp];
            };
            [[GMFiles shared] fetchVideo:peer msg:mid done:^(NSString *path, BOOL hevc) {
                GMLog(@"[thử] playvideo → %@ (hevc %d)", path.lastPathComponent, hevc);
                if (!path) return;
                if (!hevc) {
                    play(path);
                    return;
                }
                [[GMFiles shared] convertVideo:path peer:peer msg:mid done:^(NSString *np, NSString *err) {
                    GMLog(@"[thử] playvideo: chuyển xong → %@ %@", np.lastPathComponent, err ?: @"");
                    if (np) play(np);
                }];
            }];
        }
    } else if ([cmd isEqual:@"convertfile"]) {
        // convertfile <nguồn H.265> <đích> — chuyển tệp có sẵn trên máy sang H.264 (không qua Telegram) rồi phát
        NSArray *p = [arg componentsSeparatedByString:@" "];
        if (p.count == 2) {
            [GMHevcTranscoder transcode:[p objectAtIndex:0] to:[p objectAtIndex:1] progress:nil done:^(BOOL ok, NSString *err) {
                GMLog(@"[thử] convertfile → %d %@", ok, err ?: @"");
                if (!ok) return;
                MPMoviePlayerViewController *mp =
                    [[MPMoviePlayerViewController alloc] initWithContentURL:[NSURL fileURLWithPath:[p objectAtIndex:1]]];
                [top presentMoviePlayerViewControllerAnimated:mp];
            }];
        }
    } else if ([cmd isEqual:@"playmovie"]) {
        MPMoviePlayerViewController *mp = [[MPMoviePlayerViewController alloc] initWithContentURL:[NSURL fileURLWithPath:arg]];
        [top presentMoviePlayerViewControllerAnimated:mp];
    } else if ([cmd isEqual:@"noread"]) {
        // noread 1: xem chat thật mà không đánh dấu đã đọc; noread 0: trở lại bình thường
        [GMChatViewController setDebugNoRead:[arg boolValue]];
    } else if ([cmd isEqual:@"back"]) {
        [nav popViewControllerAnimated:YES];
    } else if ([cmd isEqual:@"send"] && [top isKindOfClass:[GMChatViewController class]]) {
        [(GMChatViewController *)top sendText:arg];
    } else if ([cmd isEqual:@"delmsg"] && [top isKindOfClass:[GMChatViewController class]]) {
        // delmsg <k> <0|1> — xoá tin thứ k từ dưới lên; 0 = chỉ ở máy tôi, 1 = cho mọi người
        NSArray *p = [arg componentsSeparatedByString:@" "];
        BOOL revoke = p.count < 2 || [[p objectAtIndex:1] boolValue];
        [(GMChatViewController *)top debugDeleteFromBottom:[[p objectAtIndex:0] integerValue] revoke:revoke];
    } else if ([cmd isEqual:@"playfile"]) {
        // playfile <đường dẫn .tgs / .webm> [số ô] — phát tệp có sẵn trong các ô 160 pt đè lên màn (đo tốc độ); «playfile» trống = gỡ
        static NSMutableArray *views;
        for (UIView *v in views) [v removeFromSuperview];
        views = [NSMutableArray array];
        NSArray *p = [arg componentsSeparatedByString:@" "];
        NSString *path = p.count ? [p objectAtIndex:0] : @"";
        NSInteger count = p.count > 1 ? MAX(1, MIN(4, [[p objectAtIndex:1] integerValue])) : 1;
        UIView *host = app.window;
        for (NSInteger i = 0; path.length && i < count; i++) {
            GMLottieView *lv = [[GMLottieView alloc] initWithFrame:CGRectMake(i % 2 * 160, 80 + i / 2 * 170, 160, 160)];
            lv.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.3];
            [host addSubview:lv];
            [lv playFile:path];
            [views addObject:lv];
        }
    } else if ([cmd isEqual:@"delservice"] && [top isKindOfClass:[GMChatViewController class]]) {
        [(GMChatViewController *)top debugDeleteServiceFromBottom:arg.integerValue];
    } else if ([cmd isEqual:@"findtext"]) {
        // findtext <chữ> — nhãn đang hiện chữ đó: chuỗi view cha (lớp, khung, ẩn) — dò phần tử thừa trên màn
        GMFindText([UIApplication sharedApplication].keyWindow, arg);
    } else if ([cmd isEqual:@"ttlsaved"]) {
        // ttlsaved <giây> — đặt tin tự xoá cho Tin nhắn đã lưu (không cần biết id của mình)
        if (app.list.myId) {
            [GMCore call:@"chat.ttl" args:@{@"peer": app.list.myId, @"period": @(arg.integerValue)} done:^(id ok, NSDictionary *err) {
                GMLog(@"[thử] chat.ttl → %@", err ? [err objectForKey:@"code"] : [ok description]);
            }];
        }
    } else if ([cmd isEqual:@"infopeer"]) {
        // infopeer <dòng> — mở màn thông tin của chat ở dòng đó mà không mở chat (không đánh dấu đã đọc)
        NSDictionary *d = [app.list debugDialogAt:arg.integerValue];
        if (d) {
            GMChatInfoViewController *i = [[GMChatInfoViewController alloc] init];
            i.peer = [d objectForKey:@"peer"];
            i.kind = [d objectForKey:@"kind"];
            i.myId = app.list.myId;
            i.name = [d objectForKey:@"name"];
            [nav pushViewController:i animated:YES];
        }
    } else if ([cmd isEqual:@"tapmsg"] && [top isKindOfClass:[GMChatViewController class]]) {
        [(GMChatViewController *)top debugTapFromBottom:arg.integerValue];
    } else if ([cmd isEqual:@"copymsg"] && [top isKindOfClass:[GMChatViewController class]]) {
        [(GMChatViewController *)top debugCopyFromBottom:arg.integerValue];
        GMLog(@"[thử] bảng tạm: %lu ký tự", (unsigned long)[UIPasteboard generalPasteboard].string.length);
    } else if ([cmd isEqual:@"menumsg"] && [top isKindOfClass:[GMChatViewController class]]) {
        [(GMChatViewController *)top debugMenuFromBottom:arg.integerValue];
    } else if ([cmd isEqual:@"replymsg"] && [top isKindOfClass:[GMChatViewController class]]) {
        [(GMChatViewController *)top debugReplyFromBottom:arg.integerValue];
    } else if ([cmd isEqual:@"react"] && [top isKindOfClass:[GMChatViewController class]]) {
        // react <k> <emoji|-> — thả / gỡ cảm xúc ở tin thứ k từ dưới lên
        NSArray *p = [arg componentsSeparatedByString:@" "];
        [(GMChatViewController *)top debugReactFromBottom:[[p objectAtIndex:0] integerValue] emoji:p.count > 1 ? [p objectAtIndex:1] : @"-"];
    } else if ([cmd isEqual:@"reactpick"] && [top isKindOfClass:[GMChatViewController class]]) {
        // reactpick <k> [i] — mở bảng chọn cảm xúc cho tin thứ k (i: chạm emoji thứ i)
        NSArray *p = [arg componentsSeparatedByString:@" "];
        [(GMChatViewController *)top debugReactPickerFromBottom:[[p objectAtIndex:0] integerValue]
                                                           pick:p.count > 1 ? [[p objectAtIndex:1] integerValue] : -1];
    } else if ([cmd isEqual:@"kbtn"] && [top isKindOfClass:[GMChatViewController class]]) {
        // kbtn <k> <hàng> <cột> — chạm nút dưới tin thứ k từ dưới lên
        NSArray *p = [arg componentsSeparatedByString:@" "];
        if (p.count == 3) {
            [(GMChatViewController *)top debugInlineButtonFromBottom:[[p objectAtIndex:0] integerValue] row:[[p objectAtIndex:1] integerValue]
                                                                 col:[[p objectAtIndex:2] integerValue]];
        }
    } else if ([cmd isEqual:@"sendcontact"] && [top isKindOfClass:[GMChatViewController class]]) {
        // sendcontact <số> <tên> — gửi danh thiếp vào chat đang mở (chỉ chat được phép thử)
        [(GMChatViewController *)top debugSendContact:arg];
    } else if ([cmd isEqual:@"vietqr"] && [top isKindOfClass:[GMChatViewController class]]) {
        // vietqr — mở màn mã QR chuyển khoản; qrfill <bin>|<số TK>|<chủ TK>|<số tiền>|<nội dung> — điền sẵn; qrsend — bấm «Gửi»
        [(GMChatViewController *)top debugOpenVietQR];
    } else if ([cmd isEqual:@"qrfill"] && [top isKindOfClass:[GMVietQRViewController class]]) {
        [(id)top performSelector:@selector(debugFill:) withObject:arg];
    } else if ([cmd isEqual:@"qrsend"] && [top isKindOfClass:[GMVietQRViewController class]]) {
        [(id)top performSelector:@selector(sendTapped)];
    } else if ([cmd isEqual:@"quickadd"]) {
        // quickadd <từ khoá> <chữ> — thêm tin nhắn nhanh; quickdel <từ khoá>; suggest <i> — chọn gợi ý «/»
        NSRange s2 = [arg rangeOfString:@" "];
        if (s2.location != NSNotFound) [GMQuickReplies save:[arg substringToIndex:s2.location] text:[arg substringFromIndex:s2.location + 1]];
    } else if ([cmd isEqual:@"quickdel"]) {
        [GMQuickReplies remove:arg];
    } else if ([cmd isEqual:@"botmenu"] && [top isKindOfClass:[GMChatViewController class]]) {
        // botmenu — chạm nút «Menu» của bot (danh sách lệnh / xin link mini app — không mở Safari)
        [(GMChatViewController *)top debugMenu];
    } else if ([cmd isEqual:@"suggest"] && [top isKindOfClass:[GMChatViewController class]]) {
        [(GMChatViewController *)top debugSuggest:arg.integerValue];
    } else if ([cmd isEqual:@"sendgeo"] && [top isKindOfClass:[GMChatViewController class]]) {
        // sendgeo <vĩ độ> <kinh độ> — gửi vị trí vào chat đang mở (chỉ chat được phép thử)
        [(GMChatViewController *)top debugSendGeo:arg];
    } else if ([cmd isEqual:@"mapview"]) {
        // mapview <vĩ độ> <kinh độ> — mở màn xem bản đồ (không gửi gì)
        NSArray *p = [arg componentsSeparatedByString:@" "];
        if (p.count == 2) {
            [nav pushViewController:[[GMMapViewController alloc] initWithLat:[[p objectAtIndex:0] doubleValue] lng:[[p objectAtIndex:1] doubleValue]
                                                                       title:nil] animated:YES];
        }
    } else if ([cmd isEqual:@"schedsheet"] && [top isKindOfClass:[GMChatViewController class]]) {
        // schedsheet — bảng hẹn giờ cho chữ đang soạn (gõ trước bằng «type»); chọn bằng «sheet <i>»
        [(GMChatViewController *)top debugScheduleSheet];
    } else if ([cmd isEqual:@"schedlist"] && [top isKindOfClass:[GMChatViewController class]]) {
        [(GMChatViewController *)top debugOpenScheduled];
    } else if ([cmd isEqual:@"schedact"] && [top isKindOfClass:[GMScheduledViewController class]]) {
        // schedact <i> send|delete — gửi ngay / huỷ tin hẹn giờ thứ i
        [(id)top performSelector:@selector(debugAct:) withObject:arg];
    } else if ([cmd isEqual:@"pin"] && [top isKindOfClass:[GMChatViewController class]]) {
        // pin <k> — ghim / bỏ ghim tin thứ k từ dưới lên; pintap — chạm thanh tin ghim
        [(GMChatViewController *)top debugPinFromBottom:arg.integerValue];
    } else if ([cmd isEqual:@"pintap"] && [top isKindOfClass:[GMChatViewController class]]) {
        [(GMChatViewController *)top debugPinTap];
    } else if ([cmd isEqual:@"sendpoll"] && [top isKindOfClass:[GMChatViewController class]]) {
        // sendpoll <câu hỏi>|<lựa chọn>|<lựa chọn>[|*] — gửi bình chọn vào chat đang mở (chỉ chat được phép thử)
        [(GMChatViewController *)top debugSendPoll:arg];
    } else if ([cmd isEqual:@"vote"] && [top isKindOfClass:[GMChatViewController class]]) {
        // vote <k> <0|0,2|-> — bỏ phiếu / rút phiếu ở bình chọn thứ k từ dưới lên
        NSArray *p = [arg componentsSeparatedByString:@" "];
        if (p.count == 2) [(GMChatViewController *)top debugVoteFromBottom:[[p objectAtIndex:0] integerValue] options:[p objectAtIndex:1]];
    } else if ([cmd isEqual:@"botkey"] && [top isKindOfClass:[GMChatViewController class]]) {
        [(GMChatViewController *)top debugBotKey:arg.integerValue];
    } else if ([cmd isEqual:@"botkbd"] && [top isKindOfClass:[GMChatViewController class]]) {
        [(GMChatViewController *)top debugToggleBotKeyboard];
    } else if ([cmd isEqual:@"forward"] && [top isKindOfClass:[GMChatViewController class]]) {
        NSArray *p = [arg componentsSeparatedByString:@" "];
        if (p.count == 2) [(GMChatViewController *)top debugForwardFromBottom:[[p objectAtIndex:0] integerValue] to:[p objectAtIndex:1]];
    } else if ([cmd isEqual:@"type"] && [top isKindOfClass:[GMChatViewController class]]) {
        UITextView *tv = [top valueForKey:@"_input"];
        tv.text = [arg stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"];
        [(id<UITextViewDelegate>)top textViewDidChange:tv];
    } else if ([cmd isEqual:@"sendphotofile"] && [top isKindOfClass:[GMChatViewController class]]) {
        [(GMChatViewController *)top sendPhotoFile:arg];
    } else if ([cmd isEqual:@"sendvoicefile"] && [top isKindOfClass:[GMChatViewController class]]) {
        [(GMChatViewController *)top sendVoiceFile:arg];
    } else if ([cmd isEqual:@"playvoice"] && [top isKindOfClass:[GMChatViewController class]]) {
        [(GMChatViewController *)top debugPlayVoiceFromBottom:arg.integerValue];
    } else if ([cmd isEqual:@"sendfile"] && [top isKindOfClass:[GMChatViewController class]]) {
        // sendfile <đường dẫn> [mime] — mp4 thì gửi dạng video (thuộc tính lấy từ tên «…_WxH_Ns.mp4» nếu có)
        NSArray *p = [arg componentsSeparatedByString:@" "];
        NSString *path = [p objectAtIndex:0];
        NSMutableDictionary *a = [@{@"peer": [(GMChatViewController *)top peer], @"path": path, @"name": path.lastPathComponent} mutableCopy];
        if (p.count > 1) [a setObject:[p objectAtIndex:1] forKey:@"mime"];
        if ([path hasSuffix:@".mp4"]) [a setObject:@{@"duration": @6, @"w": @640, @"h": @360} forKey:@"video"];
        [GMCore call:@"messages.sendFile" args:a done:^(id ok, NSDictionary *err) {
            GMLog(@"[thử] sendfile → %@", err ? [err objectForKey:@"code"] : [ok objectForKey:@"id"]);
            if (ok) [[NSNotificationCenter defaultCenter] postNotificationName:GMCoreEventNotification object:nil
                                                                      userInfo:@{@"e": @"msg.new", @"msg": ok}];
        }];
    } else if ([cmd isEqual:@"opendoc"] && [top isKindOfClass:[GMChatViewController class]]) {
        [(GMChatViewController *)top debugOpenDocFromBottom:arg.integerValue];
    } else if ([cmd isEqual:@"dismiss"]) {
        [GMReactionPicker dismissShown];
        [app.tabs dismissViewControllerAnimated:YES completion:nil];
    } else if ([cmd isEqual:@"sel"]) {
        // sel <tên hàm không đối số hoặc một đối số sender> — gọi trên màn trên cùng (toggleEdit, showInfo, gmDelete:…). Luôn
        // truyền nil làm đối số: hàm «x:» gọi không đối số thì sender là rác → bản dựng debug (ARC -O0) giữ nó là sập.
        SEL s = NSSelectorFromString(arg);
        if ([top respondsToSelector:s]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [top performSelector:s withObject:nil];
#pragma clang diagnostic pop
        } else {
            GMLog(@"[thử] %@ không có %@", NSStringFromClass([top class]), arg);
        }
    } else if ([cmd isEqual:@"savemsg"] && [top isKindOfClass:[GMChatViewController class]]) {
        [(id)top debugSaveFromBottom:arg.integerValue];  // lưu ảnh / video của tin thứ k từ dưới lên vào Thư viện ảnh
    } else if ([cmd isEqual:@"folder"] && [top isKindOfClass:[GMChatListViewController class]]) {
        [(GMChatListViewController *)top debugFolder:arg.integerValue];
    } else if ([cmd isEqual:@"updateapi"]) {
        // updateapi <url> — nguồn bản mới để thử (rỗng = dùng Info.plist); updatecheck — kiểm ngay như chạm «Phiên bản»
        if (arg.length) [[NSUserDefaults standardUserDefaults] setObject:arg forKey:@"update.api"];
        else [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"update.api"];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"update.snooze"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    } else if ([cmd isEqual:@"updatecheck"]) {
        [GMUpdate checkManual];
    } else if ([cmd isEqual:@"alertbtn"]) {
        // alertbtn <i> — bấm nút i của hộp thoại của app (UIAlertView của GramMini, không phải hộp hệ thống)
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            for (UIView *v in w.subviews) {
                if (![v isKindOfClass:[UIAlertView class]]) continue;
                UIAlertView *a = (UIAlertView *)v;
                GMLog(@"[thử] hộp «%@»: nút %ld «%@»", a.title, (long)arg.integerValue, [a buttonTitleAtIndex:arg.integerValue]);
                if ([a.delegate respondsToSelector:@selector(alertView:clickedButtonAtIndex:)]) [a.delegate alertView:a clickedButtonAtIndex:arg.integerValue];
                [a dismissWithClickedButtonIndex:arg.integerValue animated:YES];
            }
        }
    } else if ([cmd isEqual:@"loginui"]) {
        // loginui — mở màn đăng nhập để xem (không đăng xuất); loginstep <0|1|2>; loggedin — trả danh sách chat về bình thường
        UINavigationController *n = [[UINavigationController alloc] initWithRootViewController:[[GMLoginViewController alloc] init]];
        [app.tabs presentViewController:n animated:YES completion:nil];
    } else if ([cmd isEqual:@"loginstep"]) {
        UINavigationController *n = (UINavigationController *)app.tabs.presentedViewController;
        id vc = [n isKindOfClass:[UINavigationController class]] ? n.topViewController : nil;
        if ([vc respondsToSelector:@selector(debugStep:)]) [vc debugStep:arg.integerValue];
    } else if ([cmd isEqual:@"loginclose"]) {
        UINavigationController *n = (UINavigationController *)app.tabs.presentedViewController;
        id vc = [n isKindOfClass:[UINavigationController class]] ? n.topViewController : nil;
        if ([vc respondsToSelector:@selector(close)]) [vc performSelector:@selector(close)];
    } else if ([cmd isEqual:@"loggedin"]) {
        app.list.loggedOut = NO;
        [app.list reload];
    } else if ([cmd isEqual:@"stickerset"]) {
        // stickerset <tên ngắn> — xem một bộ sticker (như chạm link t.me/addstickers/…)
        [GMStickerSetViewController present:@{@"short_name": arg} from:top pick:nil];
    } else if ([cmd isEqual:@"stickersearch"]) {
        UIViewController *p = app.tabs.presentedViewController ?: top;
        if ([p isKindOfClass:[UINavigationController class]]) p = [(UINavigationController *)p topViewController];
        if ([p respondsToSelector:@selector(debugSearch:)]) [(id)p debugSearch:arg];
    } else if ([cmd isEqual:@"tab"]) {
        // tab <0|1|2> — Danh bạ / Chat / Cài đặt
        app.tabs.selectedIndex = arg.integerValue;
    } else if ([cmd isEqual:@"recstart"] && [top isKindOfClass:[GMChatViewController class]]) {
        [(id)top performSelector:@selector(sendDown)];
    } else if ([cmd isEqual:@"recstop"] && [top isKindOfClass:[GMChatViewController class]]) {
        [(id)top performSelector:@selector(sendTapped)];
    } else if ([cmd isEqual:@"dump"]) {
        UIWindow *w = [UIApplication sharedApplication].keyWindow;
        GMLog(@"[thử] cửa sổ %@, hướng %d, màn %@ %@", NSStringFromCGRect(w.bounds),
              (int)[UIApplication sharedApplication].statusBarOrientation, NSStringFromClass([top class]),
              NSStringFromCGRect(top.view.bounds));
        for (UIView *v in top.view.subviews) GMLog(@"[thử]   %@ %@", NSStringFromClass([v class]), NSStringFromCGRect(v.frame));
    } else if ([cmd isEqual:@"reload"]) {
        [app.list reload];
    } else if ([cmd isEqual:@"settings"]) {
        app.tabs.selectedIndex = 2;
    } else if ([cmd isEqual:@"files"] && [top isKindOfClass:[GMChatViewController class]]) {
        [(GMChatViewController *)top debugOpenFiles];
    } else if ([cmd isEqual:@"sendvideo"] && [top isKindOfClass:[GMChatViewController class]]) {
        [(GMChatViewController *)top debugSendVideo:arg];
    } else if ([cmd isEqual:@"browse"] || [cmd isEqual:@"browsepath"]) {
        // browse <hàng> — chạm hàng của trình chọn tệp đang mở; browsepath <thư mục> — mở thẳng thư mục
        UINavigationController *pn = (UINavigationController *)(app.tabs.presentedViewController ?: nav.presentedViewController);
        if ([pn isKindOfClass:[UINavigationController class]] &&
            [pn.topViewController isKindOfClass:[GMFileBrowserViewController class]]) {
            GMFileBrowserViewController *b = (GMFileBrowserViewController *)pn.topViewController;
            if ([cmd isEqual:@"browse"]) [b debugTapSection:0 row:arg.integerValue];
            else [b debugOpenPath:arg];
        } else {
            GMLog(@"[thử] không thấy trình chọn tệp");
        }
    } else if ([cmd isEqual:@"search"] && [top isKindOfClass:[GMChatListViewController class]]) {
        [(GMChatListViewController *)top debugSearch:arg];
    } else if ([cmd isEqual:@"searchtap"]) {
        // searchtap <nhóm> <hàng> — chạm kết quả tìm (danh sách chat hoặc màn Tin nhắn mới)
        NSArray *p = [arg componentsSeparatedByString:@" "];
        if (p.count == 2 && [top isKindOfClass:[GMChatListViewController class]]) {
            [(GMChatListViewController *)top debugSearchTap:[[p objectAtIndex:0] integerValue] row:[[p objectAtIndex:1] integerValue]];
        } else if (p.count == 2 && [top isKindOfClass:[GMContactsViewController class]]) {
            [(GMContactsViewController *)top debugTapSection:[[p objectAtIndex:0] integerValue] row:[[p objectAtIndex:1] integerValue]];
        }
    } else if ([cmd isEqual:@"actions"] && [top isKindOfClass:[GMChatListViewController class]]) {
        [(GMChatListViewController *)top debugActions:arg.integerValue];
    } else if ([cmd isEqual:@"compose"] && [top isKindOfClass:[GMChatListViewController class]]) {
        [(id)top performSelector:@selector(compose)];
    } else if ([cmd isEqual:@"ngpick"] && [top isKindOfClass:[GMNewGroupViewController class]]) {
        [(GMNewGroupViewController *)top debugToggle:arg.integerValue];
    } else if ([cmd isEqual:@"ngcreate"] && [top isKindOfClass:[GMNewGroupViewController class]]) {
        [(GMNewGroupViewController *)top debugCreate:arg];
    } else if ([cmd isEqual:@"csearch"] && [top isKindOfClass:[GMContactsViewController class]]) {
        [(GMContactsViewController *)top debugSearch:arg];
    } else if ([cmd isEqual:@"gifs"] && [top isKindOfClass:[GMChatViewController class]]) {
        [(GMChatViewController *)top debugGifs];
    } else if ([cmd isEqual:@"stickers"] && [top isKindOfClass:[GMChatViewController class]]) {
        // stickers | stickers tab <i> | stickers pick <i>
        [(GMChatViewController *)top debugStickers:arg];
    } else if ([cmd isEqual:@"info"] && [top isKindOfClass:[GMChatViewController class]]) {
        [(GMChatViewController *)top showInfo];
    } else if ([cmd isEqual:@"tap"] && [top isKindOfClass:[UITableViewController class]]) {
        // tap <mục> <hàng> — chạm hàng của màn bảng đang ở trên cùng
        NSArray *p = [arg componentsSeparatedByString:@" "];
        UITableViewController *t = (UITableViewController *)top;
        if (p.count == 2) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:[[p objectAtIndex:1] integerValue] inSection:[[p objectAtIndex:0] integerValue]];
            [t.tableView.delegate tableView:t.tableView didSelectRowAtIndexPath:ip];
        }
    } else if ([cmd isEqual:@"unlock"]) {
        [GMPasscode debugEnter:arg];  // unlock <mật mã> — nhập vào màn khoá đang hiện
    } else if ([cmd isEqual:@"suspend"]) {
        // suspend [nobg] — về màn hình chính (nobg: không xin thêm thời gian chạy nền → app bị treo ngay, thử socket VoIP)
        if ([arg isEqual:@"nobg"]) [GMBackground shared].debugNoBackgroundTask = YES;
        [[UIApplication sharedApplication] performSelector:@selector(suspend)];
    } else if ([cmd isEqual:@"schedule"] && [top isKindOfClass:[GMChatViewController class]]) {
        // schedule <giây> <chữ> — hẹn giờ gửi vào chat đang mở
        NSRange s2 = [arg rangeOfString:@" "];
        if (s2.location != NSNotFound) {
            long long at = (long long)[[NSDate date] timeIntervalSince1970] + [[arg substringToIndex:s2.location] longLongValue];
            [GMCore call:@"messages.send"
                    args:@{@"peer": [(GMChatViewController *)top peer], @"text": [arg substringFromIndex:s2.location + 1], @"schedule": @(at)}
                    done:^(id ok, NSDictionary *err) {
                        GMLog(@"[thử] hẹn giờ → %@", err ? [err objectForKey:@"code"] : @"được");
                    }];
        }
    } else if ([cmd isEqual:@"storage"]) {
        [nav pushViewController:[[GMStorageViewController alloc] init] animated:YES];
    } else if ([cmd isEqual:@"storagetap"] && [top isKindOfClass:[GMStorageViewController class]]) {
        // storagetap <mục> <hàng>
        NSArray *p = [arg componentsSeparatedByString:@" "];
        if (p.count == 2) [(GMStorageViewController *)top debugTapSection:[[p objectAtIndex:0] integerValue] row:[[p objectAtIndex:1] integerValue]];
    } else if ([cmd isEqual:@"sheet"]) {
        // sheet <nút> — chọn nút của bảng chọn đang mở
        UIActionSheet *s = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if ((s = GMFindSheet(w))) break;
        }
        NSInteger i = arg.integerValue;
        if (!s) {
            GMLog(@"[thử] không thấy bảng chọn");
        } else {
            GMLog(@"[thử] bảng chọn: nút %ld «%@»", (long)i, [s buttonTitleAtIndex:i]);
            if ([s.delegate respondsToSelector:@selector(actionSheet:clickedButtonAtIndex:)]) {
                [s.delegate actionSheet:s clickedButtonAtIndex:i];
            }
            [s dismissWithClickedButtonIndex:i animated:YES];
        }
    } else if ([cmd isEqual:@"link"]) {
        // link <url> — mở link như chạm trong chat (t.me / @tên → chat, link mời → hỏi tham gia, web → Safari)
        [GMLinks open:arg in:top.view];
    } else if ([cmd isEqual:@"call"]) {
        // call <lệnh lõi> [json] — ghi kết quả vào nhật ký (bỏ trường «chats»: có tên chat)
        NSRange s2 = [arg rangeOfString:@" "];
        NSString *method = s2.location == NSNotFound ? arg : [arg substringToIndex:s2.location];
        NSDictionary *a = nil;
        if (s2.location != NSNotFound) {
            a = [NSJSONSerialization JSONObjectWithData:[[arg substringFromIndex:s2.location + 1] dataUsingEncoding:NSUTF8StringEncoding]
                                                options:0 error:NULL];
        }
        long long t = GMNowMs();
        [GMCore call:method args:a done:^(id ok, NSDictionary *err) {
            id show = ok;
            if ([ok isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *m = [ok mutableCopy];
                if ([m objectForKey:@"chats"]) [m setObject:@([[m objectForKey:@"chats"] count]) forKey:@"chats"];
                show = m;
            }
            NSString *txt = err ? [NSString stringWithFormat:@"lỗi %@", [err objectForKey:@"code"]]
                                : [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:show options:0 error:NULL]
                                                        encoding:NSUTF8StringEncoding];
            GMLog(@"[thử] %@ (%lld ms) → %@", method, GMNowMs() - t, txt);
        }];
    } else if ([cmd isEqual:@"proxy"]) {
        [nav pushViewController:[[GMProxyViewController alloc] init] animated:YES];
    } else if ([cmd isEqual:@"scroll"]) {
        UIScrollView *sv = nil;
        for (UIView *v in top.view.subviews)
            if ([v isKindOfClass:[UIScrollView class]]) sv = (UIScrollView *)v;
        if ([top.view isKindOfClass:[UIScrollView class]]) sv = (UIScrollView *)top.view;
        if ([arg isEqual:@"top"]) [sv setContentOffset:CGPointZero animated:YES];
        else [sv setContentOffset:CGPointMake(0, MAX(0, sv.contentSize.height - sv.bounds.size.height)) animated:YES];
    } else {
        GMLog(@"[thử] lệnh lạ: %@", line);
    }
}

@end
