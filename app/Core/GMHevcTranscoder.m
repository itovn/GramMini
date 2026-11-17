#import "GMHevcTranscoder.h"
#import "GMCompat.h"
#import "GMLog.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <UIKit/UIKit.h>

typedef struct {
    int width, height, out_width, out_height, frames, timescale;
    double duration, a, b, c, d;
} GmH265Info;

extern void *gm_h265_open(const char *path, int max_short, int fast, char *err, int err_len);
extern int gm_h265_info(const void *video, GmH265Info *out);
extern int gm_h265_next(void *video, uint8_t *y, size_t y_stride, uint8_t *uv, size_t uv_stride, int64_t *pts);
extern void gm_h265_close(void *video);

static const int kMaxShort = 480;

@implementation GMHevcTranscoder {
    volatile BOOL _cancelled;
}

+ (instancetype)transcode:(NSString *)src to:(NSString *)dst progress:(void (^)(double))progress
                     done:(void (^)(BOOL, NSString *))done {
    GMHevcTranscoder *t = [[GMHevcTranscoder alloc] init];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        // Rời app giữa chừng: xin thêm thời gian chạy nền (bộ mã phần cứng có thể bị iOS dừng — khi đó báo lỗi, chạm lại để làm lại)
        UIApplication *app = [UIApplication sharedApplication];
        __block UIBackgroundTaskIdentifier bg = [app beginBackgroundTaskWithExpirationHandler:^{
            [app endBackgroundTask:bg];
            bg = UIBackgroundTaskInvalid;
        }];
        NSString *err = [t run:src to:dst progress:progress];
        dispatch_async(dispatch_get_main_queue(), ^{
            done(err == nil, err);
            if (bg != UIBackgroundTaskInvalid) [app endBackgroundTask:bg];
        });
    });
    return t;
}

- (void)cancel {
    _cancelled = YES;
}

/// Thiết lập tiếng: đọc PCM 16 bit xen kẽ từ rãnh tiếng của tệp gốc, mã lại AAC (iOS 5 chưa ghi thẳng AAC sang tệp mới được —
/// thiếu sourceFormatHint). Không có tiếng → nil.
- (AVAssetReaderTrackOutput *)audioFrom:(AVURLAsset *)asset reader:(AVAssetReader **)readerOut
                                  input:(AVAssetWriterInput **)inputOut writer:(AVAssetWriter *)w {
    NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (!tracks.count) return nil;
    AVAssetTrack *track = [tracks objectAtIndex:0];
    double rate = 44100;
    int channels = 2;
    NSArray *descs = track.formatDescriptions;
    if (descs.count) {
        const AudioStreamBasicDescription *asbd =
            CMAudioFormatDescriptionGetStreamBasicDescription((__bridge CMAudioFormatDescriptionRef)[descs objectAtIndex:0]);
        if (asbd && asbd->mSampleRate > 0) rate = asbd->mSampleRate;
        if (asbd && asbd->mChannelsPerFrame == 1) channels = 1;
    }
    NSError *e = nil;
    AVAssetReader *r = [AVAssetReader assetReaderWithAsset:asset error:&e];
    if (!r) return nil;
    NSDictionary *pcm = @{AVFormatIDKey: @(kAudioFormatLinearPCM), AVLinearPCMBitDepthKey: @16, AVLinearPCMIsFloatKey: @NO,
                          AVLinearPCMIsBigEndianKey: @NO, AVLinearPCMIsNonInterleaved: @NO};
    AVAssetReaderTrackOutput *out = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:pcm];
    if (![r canAddOutput:out]) return nil;
    [r addOutput:out];
    AudioChannelLayout layout = {0};
    layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo;
    NSDictionary *aac = @{AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVNumberOfChannelsKey: @(channels), AVSampleRateKey: @(rate),
                          AVEncoderBitRateKey: @(channels == 1 ? 64000 : 96000),
                          AVChannelLayoutKey: [NSData dataWithBytes:&layout length:sizeof(layout)]};
    AVAssetWriterInput *in = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:aac];
    in.expectsMediaDataInRealTime = NO;
    if (![w canAddInput:in]) return nil;
    [w addInput:in];
    *readerOut = r;
    *inputOut = in;
    return out;
}

/// Chạy cả quá trình (luồng nền). nil = xong, còn lại là câu lỗi.
- (NSString *)run:(NSString *)src to:(NSString *)dst progress:(void (^)(double))progress {
    char cerr[256] = {0};
    // Máy một nhân (A4: iPhone 4, iPad 1): bỏ khung không làm tham chiếu — nhanh ~1,7 lần, video ra ít khung / giây hơn, không nhoè
    BOOL fast = [NSProcessInfo processInfo].processorCount < 2;
    void *v = gm_h265_open(src.fileSystemRepresentation, kMaxShort, fast, cerr, sizeof(cerr));
    if (!v) return [NSString stringWithFormat:@"Không đọc được video: %s", cerr];
    GmH265Info info;
    gm_h265_info(v, &info);
    GMLog(@"chuyển H.265: %dx%d → %dx%d, %d khung, %.0f giây%@", info.width, info.height, info.out_width, info.out_height,
          info.frames, info.duration, fast ? @" (máy một nhân: bỏ khung không tham chiếu)" : @"");
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"gm-h264-%u.mp4", (unsigned)arc4random()]];
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
    NSError *e = nil;
    AVAssetWriter *w = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:tmp] fileType:AVFileTypeMPEG4 error:&e];
    if (!w) {
        gm_h265_close(v);
        return [NSString stringWithFormat:@"Không tạo được tệp video: %@", e.localizedDescription];
    }
    // Hình: H.264 phần cứng, ~1,2 Mbit/giây cho 480p
    double px = (double)info.out_width * info.out_height;
    NSDictionary *vs = @{AVVideoCodecKey: AVVideoCodecH264, AVVideoWidthKey: @(info.out_width), AVVideoHeightKey: @(info.out_height),
                         AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @((int)(px * 3)),
                                                            AVVideoMaxKeyFrameIntervalKey: @60}};
    AVAssetWriterInput *vin = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:vs];
    vin.expectsMediaDataInRealTime = NO;
    vin.transform = CGAffineTransformMake(info.a, info.b, info.c, info.d, 0, 0);
    NSDictionary *pbAttrs = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                              (id)kCVPixelBufferWidthKey: @(info.out_width), (id)kCVPixelBufferHeightKey: @(info.out_height)};
    AVAssetWriterInputPixelBufferAdaptor *adaptor =
        [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:vin sourcePixelBufferAttributes:pbAttrs];
    [w addInput:vin];
    // Tiếng
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:src] options:nil];
    AVAssetReader *reader = nil;
    AVAssetWriterInput *ain = nil;
    AVAssetReaderTrackOutput *aout = [self audioFrom:asset reader:&reader input:&ain writer:w];
    if (![w startWriting]) {
        gm_h265_close(v);
        return [NSString stringWithFormat:@"Không bắt đầu ghi được: %@", w.error.localizedDescription];
    }
    [w startSessionAtSourceTime:kCMTimeZero];
    BOOL audioOn = aout && [reader startReading];
    if (aout && !audioOn) {
        GMLog(@"chuyển H.265: không đọc được tiếng (%@) — chỉ có hình", reader.error.localizedDescription);
        [ain markAsFinished];
    }
    BOOL videoDone = NO, audioDone = !audioOn;
    NSString *fail = nil;
    int n = 0;
    double t0 = CFAbsoluteTimeGetCurrent(), lastReport = 0;
    // Ghi xen kẽ hình / tiếng: writer chỉ nhận tiếp một rãnh khi rãnh kia theo kịp — chờ một rãnh mãi sẽ kẹt
    while (!(videoDone && audioDone) && !fail) {
        if (_cancelled) {
            fail = @"Đã dừng";
            break;
        }
        BOOL moved = NO;
        if (!videoDone && vin.readyForMoreMediaData) {
            CVPixelBufferRef pb = NULL;
            if (!adaptor.pixelBufferPool || CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &pb) != kCVReturnSuccess) {
                fail = @"Không cấp được bộ đệm khung";
                break;
            }
            CVPixelBufferLockBaseAddress(pb, 0);
            int64_t pts = 0;
            int r = gm_h265_next(v, CVPixelBufferGetBaseAddressOfPlane(pb, 0), CVPixelBufferGetBytesPerRowOfPlane(pb, 0),
                                 CVPixelBufferGetBaseAddressOfPlane(pb, 1), CVPixelBufferGetBytesPerRowOfPlane(pb, 1), &pts);
            CVPixelBufferUnlockBaseAddress(pb, 0);
            if (r == 0) {
                if (![adaptor appendPixelBuffer:pb withPresentationTime:CMTimeMake(pts, info.timescale)]) {
                    fail = [NSString stringWithFormat:@"Mã hình lỗi: %@", w.error.localizedDescription];
                }
                n++;
            } else if (r == 1) {
                videoDone = YES;
                [vin markAsFinished];
            } else {
                fail = @"Giải mã H.265 lỗi";
            }
            CVPixelBufferRelease(pb);
            moved = YES;
            double now = CFAbsoluteTimeGetCurrent();
            if (progress && info.frames > 0 && now - lastReport > 0.5) {
                lastReport = now;
                double f = MIN(1.0, (double)n / info.frames);
                dispatch_async(dispatch_get_main_queue(), ^{ progress(f); });
            }
        }
        if (!audioDone && ain.readyForMoreMediaData) {
            CMSampleBufferRef sb = [aout copyNextSampleBuffer];
            if (sb) {
                if (![ain appendSampleBuffer:sb]) GMLog(@"chuyển H.265: ghi tiếng lỗi %@", w.error.localizedDescription);
                CFRelease(sb);
            } else {
                audioDone = YES;
                [ain markAsFinished];
            }
            moved = YES;
        }
        if (!moved) usleep(2000);
    }
    gm_h265_close(v);
    [reader cancelReading];
    double secs = CFAbsoluteTimeGetCurrent() - t0;
    if (fail) {
        [w cancelWriting];
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
        GMLog(@"chuyển H.265: dừng sau %d khung, %.0f giây — %@", n, secs, fail);
        return fail;
    }
    // iOS 6: finishWritingWithCompletionHandler; iOS 5: finishWriting (đồng bộ)
    if ([w respondsToSelector:@selector(finishWritingWithCompletionHandler:)]) {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        GM_IOS6_BEGIN
        [w finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
        GM_IOS6_END
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [w finishWriting];
#pragma clang diagnostic pop
    }
    if (w.status != AVAssetWriterStatusCompleted) {
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
        return [NSString stringWithFormat:@"Ghi video lỗi: %@", w.error.localizedDescription];
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:dst error:NULL];
    if (![fm moveItemAtPath:tmp toPath:dst error:&e]) {
        [fm removeItemAtPath:tmp error:NULL];
        return [NSString stringWithFormat:@"Không lưu được video: %@", e.localizedDescription];
    }
    GMLog(@"chuyển H.265 xong: %d khung trong %.0f giây (%.1f khung / giây)", n, secs, n / MAX(secs, 0.001));
    return nil;
}

@end
