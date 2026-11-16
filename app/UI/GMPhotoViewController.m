#import "GMPhotoViewController.h"
#import "GMImages.h"
#import "GMMediaSaver.h"

@interface GMPhotoViewController () <UIActionSheetDelegate>
@end

@implementation GMPhotoViewController {
    UIScrollView *_scroll;
    UIImageView *_image;
    UIActivityIndicatorView *_spin;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.delegate = self;
    _scroll.minimumZoomScale = 1;
    _scroll.maximumZoomScale = 4;
    _scroll.showsHorizontalScrollIndicator = _scroll.showsVerticalScrollIndicator = NO;
    [self.view addSubview:_scroll];
    _image = [[UIImageView alloc] initWithImage:self.preview];
    _image.contentMode = UIViewContentModeScaleAspectFit;
    _image.frame = _scroll.bounds;
    _image.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_scroll addSubview:_image];
    _spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    _spin.center = CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds));
    _spin.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                             UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    _spin.hidesWhenStopped = YES;
    [self.view addSubview:_spin];
    UITapGestureRecognizer *one = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(close)];
    UITapGestureRecognizer *two = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(zoomTap:)];
    two.numberOfTapsRequired = 2;
    [one requireGestureRecognizerToFail:two];
    [_scroll addGestureRecognizer:one];
    [_scroll addGestureRecognizer:two];
    // Nhấn giữ: lưu ảnh vào máy
    [_scroll addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(hold:)]];

    [_spin startAnimating];
    CGFloat px = MAX([UIScreen mainScreen].bounds.size.width, [UIScreen mainScreen].bounds.size.height) * [UIScreen mainScreen].scale;
    [GMImages photoForPeer:self.peer msg:self.msgId big:YES maxPixel:MIN(px, 2048) done:^(UIImage *img) {
        [_spin stopAnimating];
        _image.image = img;
    }];
    // Tải lỗi / không mạng: thôi quay sau 30 giây (vẫn xem được bản nhỏ)
    __weak UIActivityIndicatorView *spin = _spin;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [spin stopAnimating]; });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[UIApplication sharedApplication] setStatusBarHidden:YES withAnimation:UIStatusBarAnimationFade];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [[UIApplication sharedApplication] setStatusBarHidden:NO withAnimation:UIStatusBarAnimationFade];
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return _image;
}

- (void)zoomTap:(UITapGestureRecognizer *)g {
    if (_scroll.zoomScale > 1) {
        [_scroll setZoomScale:1 animated:YES];
    } else {
        CGPoint p = [g locationInView:_image];
        CGSize s = _scroll.bounds.size;
        [_scroll zoomToRect:CGRectMake(p.x - s.width / 6, p.y - s.height / 6, s.width / 3, s.height / 3) animated:YES];
    }
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)hold:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIActionSheet *s = [[UIActionSheet alloc] initWithTitle:nil delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil
                                          otherButtonTitles:@"Lưu vào máy", nil];
    s.cancelButtonIndex = [s addButtonWithTitle:@"Huỷ"];
    CGPoint p = [g locationInView:self.view];
    [s showFromRect:CGRectMake(p.x, p.y, 1, 1) inView:self.view animated:YES];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)i {
    if (i == 0) [GMMediaSaver savePhotoOf:self.peer msg:self.msgId in:self.view];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o {
    return YES;  // iOS 5
}

@end
