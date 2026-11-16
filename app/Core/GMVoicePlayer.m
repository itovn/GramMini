#import "GMVoicePlayer.h"
#import "GMCore.h"
#import "GMLog.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

NSString *const GMVoiceStateNotification = @"GMVoiceState";

@interface GMVoicePlayer () <AVAudioPlayerDelegate>
@end

@implementation GMVoicePlayer {
    AVAudioPlayer *_player;
    NSString *_key;     // tin hiện tại «peer|id»
    BOOL _loading;
    NSTimer *_timer;
}

+ (instancetype)shared {
    static GMVoicePlayer *p;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ p = [[GMVoicePlayer alloc] init]; });
    return p;
}

static NSString *GMKey(NSString *peer, NSNumber *msgId) {
    return [NSString stringWithFormat:@"%@|%@", peer, msgId];
}

- (void)notify {
    [[NSNotificationCenter defaultCenter] postNotificationName:GMVoiceStateNotification object:self];
}

- (void)stopTimer {
    [_timer invalidate];
    _timer = nil;
}

- (void)stop {
    [_player stop];
    _player = nil;
    _key = nil;
    _loading = NO;
    [self stopTimer];
    [self notify];
}

- (void)toggle:(NSString *)peer msg:(NSNumber *)msgId {
    NSString *key = GMKey(peer, msgId);
    if ([key isEqual:_key]) {
        if (_loading) return;
        if (_player.playing) {
            [_player pause];
            [self stopTimer];
        } else {
            [_player play];
            [self startTimer];
        }
        [self notify];
        return;
    }
    [self stop];
    _key = key;
    _loading = YES;
    [self notify];
    long long t = GMNowMs();
    [GMCore call:@"media.voice" args:@{@"peer": peer, @"id": msgId} done:^(id ok, NSDictionary *err) {
        if (![key isEqual:_key]) return;  // đã chuyển sang tin khác
        _loading = NO;
        if (err) {
            GMLog(@"tin thoại lỗi: %@", [err objectForKey:@"code"]);
            [self stop];
            [[[UIAlertView alloc] initWithTitle:@"Không phát được" message:GMErrorText(err) delegate:nil cancelButtonTitle:@"OK"
                              otherButtonTitles:nil] show];
            return;
        }
        GMLog(@"tin thoại sẵn sàng sau %lld ms", GMNowMs() - t);
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:NULL];
        [[AVAudioSession sharedInstance] setActive:YES error:NULL];
        NSError *e = nil;
        _player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:[ok objectForKey:@"path"]] error:&e];
        if (!_player) {
            GMLog(@"AVAudioPlayer lỗi: %@", e);
            [self stop];
            return;
        }
        _player.delegate = self;
        [_player play];
        [self startTimer];
        [self notify];
    }];
}

- (void)startTimer {
    [self stopTimer];
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(notify) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    [self stop];
}

- (NSInteger)stateOf:(NSString *)peer msg:(NSNumber *)msgId {
    if (![GMKey(peer, msgId) isEqual:_key]) return 0;
    if (_loading) return 1;
    return _player.playing ? 2 : 3;
}

- (double)progressOf:(NSString *)peer msg:(NSNumber *)msgId {
    if (![GMKey(peer, msgId) isEqual:_key] || !_player || _player.duration <= 0) return 0;
    return _player.currentTime / _player.duration;
}

- (double)timeOf:(NSString *)peer msg:(NSNumber *)msgId {
    if (![GMKey(peer, msgId) isEqual:_key] || !_player) return 0;
    return _player.currentTime;
}

@end
