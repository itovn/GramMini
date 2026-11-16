#import "GMMediaSaver.h"
#import "GMCore.h"
#import "GMFiles.h"
#import "GMLog.h"
#import "GMTheme.h"

@implementation GMMediaSaver {
    __weak UIView *_view;  // nơi hiện thông báo kết quả
}

+ (instancetype)shared {
    static GMMediaSaver *s;
    if (!s) s = [[GMMediaSaver alloc] init];
    return s;
}

+ (void)savePhotoOf:(NSString *)peer msg:(NSNumber *)msgId in:(UIView *)view {
    [GMTheme toast:@"Đang lưu ảnh…" in:view];
    [GMCore call:@"media.photo" args:@{@"peer": peer, @"id": msgId, @"big": @YES} done:^(id ok, NSDictionary *err) {
        UIImage *img = err ? nil : [UIImage imageWithContentsOfFile:GMVal(ok, @"path")];
        if (!img) {
            [GMTheme toast:err ? GMErrorText(err) : @"Không đọc được ảnh" in:view];
            return;
        }
        [[self shared] saveImage:img in:view];
    }];
}

+ (void)saveFileOf:(NSString *)peer msg:(NSNumber *)msgId in:(UIView *)view {
    [GMTheme toast:@"Đang tải về để lưu…" in:view];
    [[GMFiles shared] fetch:peer msg:msgId done:^(NSString *path) {
        if (!path) {
            [GMTheme toast:@"Không tải được tệp" in:view];
            return;
        }
        GMMediaSaver *s = [self shared];
        UIImage *img = [@[@"jpg", @"jpeg", @"png", @"gif", @"bmp", @"tif", @"tiff"] containsObject:path.pathExtension.lowercaseString]
                           ? [UIImage imageWithContentsOfFile:path] : nil;
        if (img) {
            [s saveImage:img in:view];
        } else if (UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(path)) {
            s->_view = view;
            UISaveVideoAtPathToSavedPhotosAlbum(path, s, @selector(video:didFinishSavingWithError:contextInfo:), NULL);
        } else {
            [GMTheme toast:@"iOS không lưu được loại video này vào Ảnh" in:view];
        }
    }];
}

- (void)saveImage:(UIImage *)img in:(UIView *)view {
    _view = view;
    UIImageWriteToSavedPhotosAlbum(img, self, @selector(image:didFinishSavingWithError:contextInfo:), NULL);
}

- (void)image:(UIImage *)img didFinishSavingWithError:(NSError *)err contextInfo:(void *)ctx {
    [self report:err what:@"ảnh"];
}

- (void)video:(NSString *)path didFinishSavingWithError:(NSError *)err contextInfo:(void *)ctx {
    [self report:err what:@"video"];
}

- (void)report:(NSError *)err what:(NSString *)what {
    UIView *v = _view;
    if (!err) {
        GMLog(@"đã lưu %@ vào Thư viện ảnh", what);
        [GMTheme toast:[NSString stringWithFormat:@"Đã lưu %@ vào Ảnh", what] in:v];
        return;
    }
    GMLog(@"lưu %@ lỗi: %@ (%ld)", what, err.localizedDescription, (long)err.code);
    // -3310 / -3311: người dùng / máy không cho app truy cập Ảnh (ALAssetsLibrary)
    if (err.code == -3310 || err.code == -3311) {
        [[[UIAlertView alloc] initWithTitle:@"Chưa được phép lưu vào Ảnh"
                                    message:@"Bật trong Cài đặt → Quyền riêng tư → Ảnh → GramMini rồi thử lại."
                                   delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
        return;
    }
    [GMTheme toast:[NSString stringWithFormat:@"Không lưu được %@", what] in:v];
}

@end
