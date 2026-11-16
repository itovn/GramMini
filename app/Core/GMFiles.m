#import "GMFiles.h"
#import "GMCore.h"
#import "GMLog.h"

NSString *const GMFileStateNotification = @"GMFileState";

@implementation GMFiles {
    NSMutableDictionary *_paths;     // khoá → đường dẫn
    NSMutableDictionary *_progress;  // khoá → tiến độ (đang tải)
}

+ (instancetype)shared {
    static GMFiles *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [[GMFiles alloc] init]; });
    return f;
}

- (instancetype)init {
    if ((self = [super init])) {
        _paths = [NSMutableDictionary dictionary];
        _progress = [NSMutableDictionary dictionary];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(event:) name:GMCoreEventNotification object:nil];
        // Tệp đã tải ở lần mở app trước: d<peer>_<id>.<đuôi> trong thư mục media
        NSString *dir = [GMDataDir() stringByAppendingPathComponent:@"media"];
        for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL]) {
            if (![f hasPrefix:@"d"] || [f hasSuffix:@".part"]) continue;
            NSString *base = [[f substringFromIndex:1] stringByDeletingPathExtension];
            [_paths setObject:[dir stringByAppendingPathComponent:f] forKey:base];
        }
    }
    return self;
}

static NSString *GMFileKey(NSString *peer, id msgId) {
    return [NSString stringWithFormat:@"%@_%@", peer, msgId];
}

- (void)notify {
    [[NSNotificationCenter defaultCenter] postNotificationName:GMFileStateNotification object:self];
}

- (void)event:(NSNotification *)n {
    NSDictionary *ev = n.userInfo;
    if ([[ev objectForKey:@"e"] isEqual:@"cache.cleared"]) {
        // Lõi vừa dọn / xoá đệm: quên tệp không còn
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *k in _paths.allKeys) {
            if (![fm fileExistsAtPath:[_paths objectForKey:k]]) [_paths removeObjectForKey:k];
        }
        [self notify];
        return;
    }
    if (![[ev objectForKey:@"e"] isEqual:@"media.progress"]) return;
    double total = [[ev objectForKey:@"total"] doubleValue];
    if (total <= 0) return;
    [_progress setObject:@([[ev objectForKey:@"done"] doubleValue] / total)
                  forKey:GMFileKey([ev objectForKey:@"peer"], [ev objectForKey:@"id"])];
    [self notify];
}

- (NSString *)pathFor:(NSString *)peer msg:(NSNumber *)msgId {
    NSString *key = GMFileKey(peer, msgId);
    NSString *p = [_paths objectForKey:key];
    if (p && ![[NSFileManager defaultManager] fileExistsAtPath:p]) {
        [_paths removeObjectForKey:key];  // lõi đã dọn
        p = nil;
    }
    return p;
}

- (double)progressOf:(NSString *)peer msg:(NSNumber *)msgId {
    NSNumber *p = [_progress objectForKey:GMFileKey(peer, msgId)];
    return p ? p.doubleValue : -1;
}

- (void)adopt:(NSString *)file peer:(NSString *)peer msg:(NSNumber *)msgId {
    if (!file || !peer || !msgId) return;
    NSString *dir = [GMDataDir() stringByAppendingPathComponent:@"media"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *ext = file.pathExtension.length ? file.pathExtension.lowercaseString : @"bin";
    NSString *to = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"d%@_%@.%@", peer, msgId, ext]];
    if ([[NSFileManager defaultManager] moveItemAtPath:file toPath:to error:NULL]) {
        [_paths setObject:to forKey:GMFileKey(peer, msgId)];
        [self notify];
    }
}

- (void)remember:(NSString *)file peer:(NSString *)peer msg:(NSNumber *)msgId {
    if (!file || !peer || !msgId) return;
    [_paths setObject:file forKey:GMFileKey(peer, msgId)];
    [self notify];
}

- (void)fetch:(NSString *)peer msg:(NSNumber *)msgId done:(void (^)(NSString *))done {
    NSString *key = GMFileKey(peer, msgId);
    NSString *have = [self pathFor:peer msg:msgId];
    if (have) {
        GMTouchFile(have);
        done(have);
        return;
    }
    if ([_progress objectForKey:key]) return;  // đang tải
    [_progress setObject:@0 forKey:key];
    [self notify];
    long long t = GMNowMs();
    [GMCore call:@"media.document" args:@{@"peer": peer, @"id": msgId} done:^(id ok, NSDictionary *err) {
        [_progress removeObjectForKey:key];
        NSString *path = err ? nil : [ok objectForKey:@"path"];
        if (path) {
            [_paths setObject:path forKey:key];
            GMLog(@"tải tệp xong sau %lld ms", GMNowMs() - t);
        } else {
            GMLog(@"tải tệp lỗi: %@", [err objectForKey:@"code"]);
        }
        [self notify];
        done(path);
    }];
}

@end
