#import "GMImages.h"
#import "GMCore.h"
#import "GMLog.h"
#import <ImageIO/ImageIO.h>

static NSCache *gCache;
static dispatch_queue_t gQueue;
static NSMutableDictionary *gWaiting;  // khoá → [done…] (gộp yêu cầu trùng)

@implementation GMImages

+ (void)initialize {
    if (self != [GMImages class]) return;
    gCache = [[NSCache alloc] init];
    BOOL lowRam = [NSProcessInfo processInfo].physicalMemory < 300ull * 1024 * 1024;
    gCache.totalCostLimit = (lowRam ? 8 : 24) * 1024 * 1024;
    gQueue = dispatch_queue_create("gm.images", DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(gQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0));
    gWaiting = [NSMutableDictionary dictionary];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(purge)
                                                 name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
}

+ (void)purge {
    [gCache removeAllObjects];
}

/// Giải mã + thu nhỏ (ImageIO), tuỳ chọn cắt tròn. Chạy ở hàng nền.
static UIImage *GMDecode(NSString *path, CGFloat maxPixel, BOOL round, BOOL alpha) {
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return nil;
    NSDictionary *opt = @{
        (__bridge id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge id)kCGImageSourceThumbnailMaxPixelSize: @((int)maxPixel),
    };
    CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opt);
    CFRelease(src);
    if (!cg) return nil;
    CGFloat scale = [UIScreen mainScreen].scale;
    UIImage *img = [UIImage imageWithCGImage:cg scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    if (round) {
        CGFloat s = MIN(img.size.width, img.size.height);
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(s, s), NO, scale);
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, s, s)] addClip];
        [img drawInRect:CGRectMake((s - img.size.width) / 2, (s - img.size.height) / 2, img.size.width, img.size.height)];
        img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    } else {
        // Vẽ sẵn ra bitmap (khỏi giải mã lần nữa trên luồng chính khi hiện)
        UIGraphicsBeginImageContextWithOptions(img.size, !alpha, scale);
        [img drawAtPoint:CGPointZero];
        img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    }
    return img;
}

static NSUInteger GMCost(UIImage *img) {
    return (NSUInteger)(img.size.width * img.size.height * img.scale * img.scale * 4);
}

/// Tải tệp (nếu chưa có) rồi giải mã; gộp các yêu cầu cùng khoá.
+ (void)key:(NSString *)key file:(NSString *)file fetch:(void (^)(void (^got)(NSString *path)))fetch maxPixel:(CGFloat)px
      round:(BOOL)round done:(void (^)(UIImage *))done {
    [self key:key file:file fetch:fetch maxPixel:px round:round alpha:NO done:done];
}

+ (void)key:(NSString *)key file:(NSString *)file fetch:(void (^)(void (^got)(NSString *path)))fetch maxPixel:(CGFloat)px
      round:(BOOL)round alpha:(BOOL)alpha done:(void (^)(UIImage *))done {
    UIImage *hit = [gCache objectForKey:key];
    if (hit) {
        done(hit);
        return;
    }
    NSMutableArray *waiting = [gWaiting objectForKey:key];
    if (waiting) {
        [waiting addObject:[done copy]];
        return;
    }
    [gWaiting setObject:[NSMutableArray arrayWithObject:[done copy]] forKey:key];
    void (^decode)(NSString *) = ^(NSString *path) {
        if (!path) {
            [gWaiting removeObjectForKey:key];
            return;
        }
        dispatch_async(gQueue, ^{
            UIImage *img = GMDecode(path, px, round, alpha);
            dispatch_async(dispatch_get_main_queue(), ^{
                NSArray *cbs = [gWaiting objectForKey:key];
                [gWaiting removeObjectForKey:key];
                if (!img) return;
                [gCache setObject:img forKey:key cost:GMCost(img)];
                for (void (^cb)(UIImage *) in cbs) cb(img);
            });
        });
    };
    if (file && [[NSFileManager defaultManager] fileExistsAtPath:file]) {
        GMTouchFile(file);
        decode(file);
    }
    else fetch(decode);
}

+ (void)avatarForPeer:(NSString *)peer photo:(NSString *)photo dc:(NSNumber *)dc size:(CGFloat)size done:(void (^)(UIImage *))done {
    if (!peer || !photo) return;
    NSString *key = [NSString stringWithFormat:@"a|%@|%@|%.0f", peer, photo, size];
    NSString *file = [GMDataDir() stringByAppendingFormat:@"/avatars/%@_%@.jpg", peer, photo];
    [self key:key file:file
        fetch:^(void (^got)(NSString *)) {
            [GMCore call:@"media.avatar" args:@{@"peer": peer, @"photo": photo, @"dc": dc ?: @0} done:^(id ok, NSDictionary *err) {
                got(err ? nil : [ok objectForKey:@"path"]);
            }];
        }
        maxPixel:size * [UIScreen mainScreen].scale round:YES done:done];
}

+ (NSString *)photoKey:(NSString *)peer msg:(NSNumber *)msgId big:(BOOL)big {
    return [NSString stringWithFormat:@"p|%@|%@|%d", peer, msgId, big];
}

+ (UIImage *)cachedPhotoForPeer:(NSString *)peer msg:(NSNumber *)msgId big:(BOOL)big {
    return [gCache objectForKey:[self photoKey:peer msg:msgId big:big]];
}

+ (void)photoForPeer:(NSString *)peer msg:(NSNumber *)msgId big:(BOOL)big maxPixel:(CGFloat)maxPixel
                done:(void (^)(UIImage *))done {
    NSString *file = [GMDataDir() stringByAppendingFormat:@"/media/p%@_%@_%@.jpg", peer, msgId, big ? @"y" : @"m"];
    [self key:[self photoKey:peer msg:msgId big:big] file:file
        fetch:^(void (^got)(NSString *)) {
            [GMCore call:@"media.photo" args:@{@"peer": peer, @"id": msgId, @"big": @(big)} done:^(id ok, NSDictionary *err) {
                if (err) GMLog(@"tải ảnh lỗi: %@", [err objectForKey:@"code"]);
                got(err ? nil : [ok objectForKey:@"path"]);
            }];
        }
        maxPixel:maxPixel round:NO done:done];
}

+ (void)docPreview:(NSString *)doc maxPixel:(CGFloat)maxPixel done:(void (^)(UIImage *))done {
    if (!doc) return;
    NSString *file = [GMDataDir() stringByAppendingFormat:@"/media/k%@.png", doc];
    [self key:[NSString stringWithFormat:@"k|%@|%.0f", doc, maxPixel] file:file
        fetch:^(void (^got)(NSString *)) {
            [GMCore call:@"media.docpreview" args:@{@"doc": doc} done:^(id ok, NSDictionary *err) {
                got(err ? nil : [ok objectForKey:@"path"]);
            }];
        }
        maxPixel:maxPixel round:NO alpha:YES done:done];
}

+ (UIImage *)cachedStickerForPeer:(NSString *)peer msg:(NSNumber *)msgId {
    return [gCache objectForKey:[NSString stringWithFormat:@"s|%@|%@", peer, msgId]];
}

+ (void)stickerForPeer:(NSString *)peer msg:(NSNumber *)msgId maxPixel:(CGFloat)maxPixel done:(void (^)(UIImage *))done {
    NSString *file = [GMDataDir() stringByAppendingFormat:@"/media/s%@_%@.png", peer, msgId];
    [self key:[NSString stringWithFormat:@"s|%@|%@", peer, msgId] file:file
        fetch:^(void (^got)(NSString *)) {
            [GMCore call:@"media.sticker" args:@{@"peer": peer, @"id": msgId} done:^(id ok, NSDictionary *err) {
                if (err) GMLog(@"tải sticker lỗi: %@", [err objectForKey:@"code"]);
                got(err ? nil : [ok objectForKey:@"path"]);
            }];
        }
        maxPixel:maxPixel round:NO alpha:YES done:done];
}

+ (UIImage *)cachedThumbForPeer:(NSString *)peer msg:(NSNumber *)msgId {
    return [gCache objectForKey:[NSString stringWithFormat:@"t|%@|%@", peer, msgId]];
}

+ (void)thumbForPeer:(NSString *)peer msg:(NSNumber *)msgId maxPixel:(CGFloat)maxPixel done:(void (^)(UIImage *))done {
    NSString *file = [GMDataDir() stringByAppendingFormat:@"/media/t%@_%@.jpg", peer, msgId];
    [self key:[NSString stringWithFormat:@"t|%@|%@", peer, msgId] file:file
        fetch:^(void (^got)(NSString *)) {
            [GMCore call:@"media.thumb" args:@{@"peer": peer, @"id": msgId} done:^(id ok, NSDictionary *err) {
                got(err ? nil : [ok objectForKey:@"path"]);
            }];
        }
        maxPixel:maxPixel round:NO done:done];
}

+ (UIImage *)imageFromBase64:(NSString *)b64 {
    if (![b64 isKindOfClass:[NSString class]] || !b64.length) return nil;
    // NSData initWithBase64EncodedString có từ iOS 7 → tự giải mã
    static int8_t table[256];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        memset(table, -1, sizeof(table));
        const char *abc = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        for (int i = 0; i < 64; i++) table[(unsigned char)abc[i]] = (int8_t)i;
    });
    const char *s = b64.UTF8String;
    NSMutableData *d = [NSMutableData dataWithCapacity:strlen(s) * 3 / 4];
    unsigned int acc = 0, bits = 0;
    for (const char *p = s; *p; p++) {
        int8_t v = table[(unsigned char)*p];
        if (v < 0) continue;
        acc = (acc << 6) | (unsigned int)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            uint8_t byte = (uint8_t)(acc >> bits);
            [d appendBytes:&byte length:1];
        }
    }
    return [UIImage imageWithData:d];
}

@end
