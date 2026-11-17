#import "GMWebAppViewController.h"
#import "GMLinks.h"
#import "GMLog.h"
#import "GMTheme.h"

@implementation GMWebAppViewController {
    NSURL *_url;
    UIWebView *_web;
    UIActivityIndicatorView *_spin;
    UILabel *_error;
}

+ (void)present:(NSURL *)url title:(NSString *)title from:(UIViewController *)from {
    if (!url || !from) return;
    GMWebAppViewController *w = [[GMWebAppViewController alloc] initWithURL:url title:title];
    UINavigationController *n = [[UINavigationController alloc] initWithRootViewController:w];
    n.modalPresentationStyle = UIModalPresentationFormSheet;  // iPad: khung giữa màn cỡ điện thoại
    [from presentViewController:n animated:YES completion:nil];
}

- (instancetype)initWithURL:(NSURL *)url title:(NSString *)title {
    if ((self = [super init])) {
        _url = url;
        self.title = title.length ? title : @"Ứng dụng của bot";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Đóng" style:UIBarButtonItemStyleBordered
                                                                            target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                            target:self action:@selector(reload)];
    _web = [[UIWebView alloc] initWithFrame:self.view.bounds];
    _web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _web.delegate = self;
    _web.scalesPageToFit = YES;  // trang không đặt viewport vẫn vừa màn
    _web.dataDetectorTypes = UIDataDetectorTypeNone;
    _web.allowsInlineMediaPlayback = YES;
    [self.view addSubview:_web];
    _spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    _spin.center = CGPointMake(self.view.bounds.size.width / 2, 60);
    _spin.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    _spin.hidesWhenStopped = YES;
    [self.view addSubview:_spin];
    [_web loadRequest:[NSURLRequest requestWithURL:_url]];
}

- (void)dealloc {
    _web.delegate = nil;  // UIWebView giữ delegate kiểu assign
    [_web stopLoading];
}

- (void)close {
    _web.delegate = nil;
    [_web stopLoading];
    [_web loadHTMLString:@"" baseURL:nil];  // bỏ trang (và link có dữ liệu đăng nhập) khỏi bộ nhớ ngay
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)reload {
    _error.hidden = YES;
    if (_web.request.URL.absoluteString.length && ![_web.request.URL.absoluteString isEqual:@"about:blank"]) [_web reload];
    else [_web loadRequest:[NSURLRequest requestWithURL:_url]];
}

#pragma mark UIWebViewDelegate

/// Trong khung chỉ đi http / https (và about: của khung con). Link Telegram → đóng khung, mở chat trong app; kiểu khác (tel:,
/// mailto:…) → qua GMLinks (hỏi trước khi mở).
- (BOOL)webView:(UIWebView *)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(UIWebViewNavigationType)type {
    NSURL *u = request.URL;
    NSString *scheme = u.scheme.lowercaseString;
    NSString *s = u.absoluteString;
    BOOL main = [request.mainDocumentURL isEqual:u];
    BOOL web = [scheme isEqual:@"http"] || [scheme isEqual:@"https"];
    if (web && !(main && type == UIWebViewNavigationTypeLinkClicked && [GMLinks isTelegramLink:s])) return YES;
    if (!main) {
        // Khung con: about: / data: / blob: của trang thì được, kiểu khác chặn lặng lẽ
        return [scheme isEqual:@"about"] || [scheme isEqual:@"data"] || [scheme isEqual:@"blob"];
    }
    if ([scheme isEqual:@"about"]) return YES;
    GMLog(@"mini app: mở link ngoài khung (%@)", scheme ?: @"?");
    UIViewController *from = self.presentingViewController;
    [self dismissViewControllerAnimated:YES completion:^{
        [GMLinks open:s in:from.view];
    }];
    _web.delegate = nil;
    return NO;
}

- (void)webViewDidStartLoad:(UIWebView *)webView {
    [_spin startAnimating];
}

- (void)webViewDidFinishLoad:(UIWebView *)webView {
    if (!webView.isLoading) [_spin stopAnimating];
}

- (void)webView:(UIWebView *)webView didFailLoadWithError:(NSError *)error {
    [_spin stopAnimating];
    // Huỷ / chặn chuyển trang (link mở ngoài khung) không phải lỗi
    if ([error.domain isEqual:NSURLErrorDomain] && error.code == NSURLErrorCancelled) return;
    if ([error.domain isEqual:@"WebKitErrorDomain"] && error.code == 102) return;
    GMLog(@"mini app: lỗi tải %@ %ld", error.domain, (long)error.code);
    if (!_error) {
        _error = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 20, 80)];
        _error.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _error.numberOfLines = 0;
        _error.textAlignment = GMAlignCenter;
        _error.textColor = [UIColor darkGrayColor];
        _error.backgroundColor = [UIColor clearColor];
        _error.font = [UIFont systemFontOfSize:15];
        [self.view addSubview:_error];
    }
    _error.text = [NSString stringWithFormat:@"Không tải được ứng dụng của bot.\n\n%@", error.localizedDescription ?: @""];
    _error.hidden = NO;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAll;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o {
    return YES;
}

@end
