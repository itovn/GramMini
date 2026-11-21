#import "GMCallAudio.h"
#import "GMCompat.h"
#import "GMLog.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>

extern void gm_voip_push(const int16_t *pcm, int n);
extern int gm_voip_pull(int16_t *out, int n);

#define kOutputBus 0
#define kInputBus 1
/// Bộ đệm thu (mẫu): iOS gọi callback mỗi ~20–23 ms (1024 mẫu ở 44,1 / 48 kHz); để dư.
#define kInBufSamples 8192

@implementation GMCallAudio {
    AudioUnit _unit;
    int16_t *_inBuf;
    @public
    volatile BOOL _tone;
    uint32_t _tonePos;
}

+ (GMCallAudio *)shared {
    static GMCallAudio *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [GMCallAudio new]; });
    return s;
}

static OSStatus GMRender(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus, UInt32 frames,
                         AudioBufferList *io) {
    GMCallAudio *self = (__bridge GMCallAudio *)ref;
    // Loa: lấy tiếng đã giải từ lõi (thiếu thì lõi bù im lặng)
    for (UInt32 i = 0; i < io->mNumberBuffers; i++) {
        AudioBuffer *b = &io->mBuffers[i];
        int16_t *p = (int16_t *)b->mData;
        int n = (int)(b->mDataByteSize / 2);
        int got = gm_voip_pull(p, n);
        if (self->_tone && got == 0) {
            // Tiếng chờ: 425 Hz, 1 giây kêu / 4 giây nghỉ (48 kHz)
            for (int k = 0; k < n; k++) {
                uint32_t t = self->_tonePos++ % (48000 * 5);
                p[k] = t < 48000 ? (int16_t)(sinf(2.0f * (float)M_PI * 425.0f * (float)t / 48000.0f) * 5000.0f) : 0;
            }
        }
    }
    return noErr;
}

static OSStatus GMInput(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus, UInt32 frames,
                        AudioBufferList *unused) {
    GMCallAudio *self = (__bridge GMCallAudio *)ref;
    if (frames > kInBufSamples) return noErr;
    AudioBufferList list;
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = 1;
    list.mBuffers[0].mDataByteSize = frames * 2;
    list.mBuffers[0].mData = self->_inBuf;
    OSStatus st = AudioUnitRender(self->_unit, flags, ts, kInputBus, frames, &list);
    if (st == noErr) gm_voip_push(self->_inBuf, (int)frames);
    return noErr;
}

static BOOL GMCheck(OSStatus st, NSString *what) {
    if (st == noErr) return YES;
    GMLog(@"[gọi] %@ lỗi OSStatus %d", what, (int)st);
    return NO;
}

- (void)configureSession {
    AVAudioSession *s = [AVAudioSession sharedInstance];
    NSError *err = nil;
    [s setCategory:AVAudioSessionCategoryPlayAndRecord error:&err];
    if (err) GMLog(@"[gọi] setCategory: %@", err);
    // VoiceChat (iOS 5+): đường âm thanh tối ưu cho đàm thoại
    [s setMode:AVAudioSessionModeVoiceChat error:NULL];
    [s setPreferredIOBufferDuration:0.02 error:NULL];
    GM_IOS6_BEGIN
    if ([s respondsToSelector:@selector(setPreferredSampleRate:error:)]) {
        [s setPreferredSampleRate:48000.0 error:NULL];
    } else {
        // iOS 5: API C
        AudioSessionInitialize(NULL, NULL, NULL, NULL);
        Float64 rate = 48000.0;
        AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareSampleRate, sizeof(rate), &rate);
    }
    GM_IOS6_END
    [s setActive:YES error:&err];
    if (err) GMLog(@"[gọi] setActive: %@", err);
}

- (BOOL)start {
    if (_running) return YES;
    [self configureSession];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!GMOldIOS()) {
            // iOS 6: thông báo AVAudioSessionInterruptionNotification (tên = chính chuỗi này)
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(interruption:)
                                                         name:@"AVAudioSessionInterruptionNotification" object:nil];
        } else {
            [AVAudioSession sharedInstance].delegate = (id)self;
        }
    });
    if (!_inBuf) _inBuf = calloc(kInBufSamples, sizeof(int16_t));

    AudioComponentDescription desc = {0};
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_VoiceProcessingIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (!comp || !GMCheck(AudioComponentInstanceNew(comp, &_unit), @"tạo VoiceProcessingIO")) return NO;

    UInt32 one = 1;
    BOOL ok = GMCheck(AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, kOutputBus, &one,
                                           sizeof(one)), @"bật loa")
        && GMCheck(AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, kInputBus, &one,
                                        sizeof(one)), @"bật micro");
    // Tự chỉnh mức micro (AGC) — libtgvoip bật mặc định trên iOS
    AudioUnitSetProperty(_unit, kAUVoiceIOProperty_VoiceProcessingEnableAGC, kAudioUnitScope_Global, kInputBus, &one, sizeof(one));

    AudioStreamBasicDescription f = {0};
    f.mSampleRate = 48000;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
    f.mBitsPerChannel = 16;
    f.mBytesPerPacket = 2;
    f.mBytesPerFrame = 2;
    f.mFramesPerPacket = 1;
    f.mChannelsPerFrame = 1;
    ok = ok && GMCheck(AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kOutputBus, &f, sizeof(f)),
                       @"định dạng loa")
        && GMCheck(AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, kInputBus, &f, sizeof(f)),
                   @"định dạng micro");

    AURenderCallbackStruct out = {GMRender, (__bridge void *)self};
    AURenderCallbackStruct in = {GMInput, (__bridge void *)self};
    ok = ok && GMCheck(AudioUnitSetProperty(_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, kOutputBus, &out,
                                            sizeof(out)), @"callback loa")
        && GMCheck(AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, kInputBus, &in,
                                        sizeof(in)), @"callback micro")
        && GMCheck(AudioUnitInitialize(_unit), @"khởi tạo AudioUnit") && GMCheck(AudioOutputUnitStart(_unit), @"chạy AudioUnit");
    if (!ok) {
        AudioComponentInstanceDispose(_unit);
        _unit = NULL;
        return NO;
    }
    _running = YES;
    [self applyRoute];
    AVAudioSession *s = [AVAudioSession sharedInstance];
    GM_IOS6_BEGIN
    if ([s respondsToSelector:@selector(sampleRate)]) {
        GMLog(@"[gọi] âm thanh chạy: %.0f Hz, bộ đệm %.1f ms", s.sampleRate, s.IOBufferDuration * 1000);
    } else {
        GMLog(@"[gọi] âm thanh chạy (iOS 5)");
    }
    GM_IOS6_END
    return YES;
}

- (void)stop {
    if (_unit) {
        AudioOutputUnitStop(_unit);
        AudioUnitUninitialize(_unit);
        AudioComponentInstanceDispose(_unit);
        _unit = NULL;
    }
    if (_running) {
        _running = NO;
        [UIDevice currentDevice].proximityMonitoringEnabled = NO;
        [[AVAudioSession sharedInstance] setActive:NO error:NULL];
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:NULL];
        GMLog(@"[gọi] âm thanh dừng");
    }
}

- (void)setRingback:(BOOL)ringback {
    _ringback = ringback;
    if (ringback && !_tone) _tonePos = 0;
    _tone = ringback;
}

/// Bị ngắt (cuộc gọi điện thoại thường, báo thức…): iOS tự dừng AudioUnit; hết ngắt thì mở lại phiên và chạy lại.
- (void)interruption:(NSNotification *)n {
    // Chuỗi thay cho hằng AVAudioSessionInterruptionTypeKey (iOS 6 — liên kết hằng thì iOS 5 thiếu ký hiệu)
    NSUInteger type = [[n.userInfo objectForKey:@"AVAudioSessionInterruptionTypeKey"] unsignedIntegerValue];
    if (type == 1) {
        GMLog(@"[gọi] âm thanh bị ngắt");
    } else if (_running && _unit) {
        GMLog(@"[gọi] hết ngắt — chạy lại âm thanh");
        [[AVAudioSession sharedInstance] setActive:YES error:NULL];
        AudioOutputUnitStart(_unit);
        [self applyRoute];
    }
}

// iOS 5: AVAudioSessionDelegate (iOS 6 dùng thông báo ở trên)
- (void)beginInterruption {
    GMLog(@"[gọi] âm thanh bị ngắt (iOS 5)");
}

- (void)endInterruption {
    if (_running && _unit) {
        [[AVAudioSession sharedInstance] setActive:YES error:NULL];
        AudioOutputUnitStart(_unit);
        [self applyRoute];
    }
}

- (void)setSpeaker:(BOOL)speaker {
    _speaker = speaker;
    if (_running) [self applyRoute];
}

/// Loa ngoài / loa trong (áp tai: cảm biến tiệm cận tắt màn hình). API C của AudioSession chạy cả iOS 5 và 6.
- (void)applyRoute {
    AudioSessionInitialize(NULL, NULL, NULL, NULL);
    UInt32 route = _speaker ? kAudioSessionOverrideAudioRoute_Speaker : kAudioSessionOverrideAudioRoute_None;
    AudioSessionSetProperty(kAudioSessionProperty_OverrideAudioRoute, sizeof(route), &route);
    [UIDevice currentDevice].proximityMonitoringEnabled = !_speaker;
    CFStringRef now = NULL;
    UInt32 sz = sizeof(now);
    if (AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, &sz, &now) == noErr && now) {
        GMLog(@"[gọi] đường âm thanh: %@ (%@)", (__bridge NSString *)now, _speaker ? @"loa ngoài" : @"loa trong");
        CFRelease(now);
    }
}

@end
