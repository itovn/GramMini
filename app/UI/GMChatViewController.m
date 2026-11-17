#import "GMChatViewController.h"
#import "GMCore.h"
#import "GMImages.h"
#import "GMPhotoViewController.h"
#import "GMVoicePlayer.h"
#import "GMFiles.h"
#import "GMFileBrowserViewController.h"
#import "GMChatInfoViewController.h"
#import "GMVideoCompressor.h"
#import "GMStickerPanel.h"
#import "GMStickerSetViewController.h"
#import "GMMediaSaver.h"
#import "GMLottieView.h"
#import <MediaPlayer/MediaPlayer.h>
#import <QuickLook/QuickLook.h>
#import <AVFoundation/AVFoundation.h>
#import "GMLog.h"
#import "GMPickChatViewController.h"
#import "GMProxyViewController.h"
#import "GMTitleView.h"
#import "GMTheme.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// UTI của ảnh / video (khỏi MobileCoreServices: header riêng của Theos trùng tên làm hỏng module của SDK)
static NSString *const GMUTImage = @"public.image";
static NSString *const GMUTMovie = @"public.movie";

static const CGFloat kPadX = 9, kPadY = 6, kBarH = 48, kPanelH = 44, kNameH = 18, kReplyH = 38, kProxyH = 34, kFwdH = 18;
static const CGFloat kInputMinH = 36, kInputMaxH = 112;  // ô nhập: 1 dòng … ~5 dòng
static const CGFloat kVoiceH = 44, kVoiceW = 210, kStickerMax = 150, kAttachW = 40, kDocH = 46, kDocW = 220;
// Tệp không chú thích: giờ xuống một dòng riêng dưới dòng «cỡ · chạm để mở» (bong bóng tệp 220 điểm không đủ chỗ cho cả hai)
static const CGFloat kDocTimeH = 10;
static const CGFloat kTimeW0 = 6;  // khoảng trống trước giờ

#pragma mark - Mục xem bằng QuickLook (tên thật của tệp làm tiêu đề)

@interface GMPreviewItem : NSObject <QLPreviewItem>
@property (nonatomic, strong) NSURL *previewItemURL;
@property (nonatomic, strong) NSString *previewItemTitle;
@end

@implementation GMPreviewItem
@end

#pragma mark - Dạng sóng tin thoại

/// Các cột dạng sóng (0–31); phần đã phát tô màu đậm.
@interface GMWaveView : UIView
@property (nonatomic, copy) NSArray *levels;
@property (nonatomic) double progress;
@property (nonatomic, strong) UIColor *played, *rest;
@end

@implementation GMWaveView
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}
- (void)drawRect:(CGRect)rect {
    NSUInteger n = self.levels.count ?: 1;
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    NSUInteger bars = MIN((NSUInteger)floor(w / 3), 60);
    for (NSUInteger i = 0; i < bars; i++) {
        NSUInteger k = i * n / bars;
        CGFloat v = self.levels.count ? [[self.levels objectAtIndex:MIN(k, self.levels.count - 1)] floatValue] / 31.0 : 0.15;
        CGFloat bh = MAX(2, round(v * h));
        [((double)i / bars < self.progress ? self.played : self.rest) setFill];
        UIRectFill(CGRectMake(i * 3, h - bh, 2, bh));
    }
}
@end

#pragma mark - Ô

/// Một hàng: bong bóng tin (nền ảnh co giãn) với tên / trích dẫn / chữ / nút proxy / giờ; hoặc viên thuốc (ngày, tin hệ thống).
@interface GMBubbleCell : UITableViewCell
@property (nonatomic, strong) UIImageView *bubble;
@property (nonatomic, strong) UILabel *name, *body, *time, *pill, *fwd;
@property (nonatomic, strong) UIView *replyBar;
@property (nonatomic, strong) UILabel *replyName, *replyText;
@property (nonatomic, strong) UIButton *proxy;
@property (nonatomic, copy) void (^onProxy)(void);
@property (nonatomic, strong) UIImageView *photo;
@property (nonatomic, strong) UILabel *photoTime;
@property (nonatomic, copy) NSString *photoKey;  // ô đang hiện ảnh nào (ô dùng lại)
@property (nonatomic, strong) UIButton *play;
@property (nonatomic, strong) GMWaveView *wave;
@property (nonatomic, strong) UILabel *voiceTime;
@property (nonatomic, copy) void (^onPlay)(void);
@property (nonatomic, strong) UIImageView *sticker;
/// Sticker động TGS: phát đè lên ảnh tĩnh (ảnh tĩnh ẩn khi khung đầu đã hiện).
@property (nonatomic, strong) GMLottieView *lottie;
@property (nonatomic, strong) UILabel *stickerTime;
@property (nonatomic, strong) NSDictionary *voiceMsg;
@property (nonatomic, strong) NSDictionary *docMsg;
@property (nonatomic, strong) UILabel *docIcon, *docName, *docInfo, *playBadge, *videoLen;
/// GIF đang chạy trong bong bóng (AVPlayer lặp, đè lên ảnh) — khoá «peer|id».
@property (nonatomic, strong) AVPlayer *gifPlayer;
@property (nonatomic, strong) AVPlayerLayer *gifLayer;
@property (nonatomic, copy) NSString *gifKey;
- (void)playGif:(NSString *)path;
- (void)stopGif;
@end

@implementation GMBubbleCell

- (void)playGif:(NSString *)path {
    [self stopGifPlayer];
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:path]];
    AVPlayer *p = [AVPlayer playerWithPlayerItem:item];
    p.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(gifEnded:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    AVPlayerLayer *l = [AVPlayerLayer playerLayerWithPlayer:p];
    l.videoGravity = AVLayerVideoGravityResizeAspectFill;
    l.frame = self.photo.bounds;
    [self.photo.layer addSublayer:l];
    self.gifPlayer = p;
    self.gifLayer = l;
    [p play];
}

- (void)gifEnded:(NSNotification *)n {
    [self.gifPlayer seekToTime:kCMTimeZero];
    [self.gifPlayer play];
}

- (void)stopGifPlayer {
    if (self.gifPlayer) {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
        [self.gifPlayer pause];
    }
    [self.gifLayer removeFromSuperlayer];
    self.gifLayer = nil;
    self.gifPlayer = nil;
}

- (void)stopGif {
    [self stopGifPlayer];
    self.gifKey = nil;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self stopGif];
    [self.lottie stop];
    self.lottie.hidden = YES;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (UILabel *)label:(UIFont *)f in:(UIView *)v {
    UILabel *l = [[UILabel alloc] init];
    l.font = f;
    l.textColor = [GMTheme text];
    l.backgroundColor = [UIColor clearColor];
    [v addSubview:l];
    return l;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    if ((self = [super initWithStyle:style reuseIdentifier:rid])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [UIColor clearColor];
        _bubble = [[UIImageView alloc] init];
        _bubble.userInteractionEnabled = YES;
        [self.contentView addSubview:_bubble];
        _name = [self label:[UIFont boldSystemFontOfSize:14] in:_bubble];
        _fwd = [self label:[UIFont systemFontOfSize:13] in:_bubble];
        _replyBar = [[UIView alloc] init];
        [_bubble addSubview:_replyBar];
        _replyName = [self label:[UIFont boldSystemFontOfSize:13] in:_bubble];
        _replyText = [self label:[UIFont systemFontOfSize:13] in:_bubble];
        _body = [self label:[UIFont systemFontOfSize:16] in:_bubble];
        _body.numberOfLines = 0;
        _time = [self label:[UIFont systemFontOfSize:11] in:_bubble];
        _time.textAlignment = GMAlignRight;
        _proxy = [GMTheme button:@"🔗 Dùng proxy này"];
        _proxy.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [_proxy addTarget:self action:@selector(proxyTapped) forControlEvents:UIControlEventTouchUpInside];
        [_bubble addSubview:_proxy];
        _photo = [[UIImageView alloc] init];
        _photo.contentMode = UIViewContentModeScaleAspectFill;
        _photo.clipsToBounds = YES;
        _photo.layer.cornerRadius = 12;
        _photo.backgroundColor = [GMTheme placeholderFill];
        [_bubble addSubview:_photo];
        _photoTime = [self label:[UIFont systemFontOfSize:11] in:_bubble];
        _photoTime.textColor = [UIColor whiteColor];
        _photoTime.textAlignment = GMAlignCenter;
        _photoTime.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
        _photoTime.layer.cornerRadius = 8;
        _photoTime.clipsToBounds = YES;
        _play = [UIButton buttonWithType:UIButtonTypeCustom];
        _play.layer.cornerRadius = 20;
        _play.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        [_play setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [_play addTarget:self action:@selector(playTapped) forControlEvents:UIControlEventTouchUpInside];
        [_bubble addSubview:_play];
        _wave = [[GMWaveView alloc] init];
        [_bubble addSubview:_wave];
        _voiceTime = [self label:[UIFont systemFontOfSize:12] in:_bubble];
        _docIcon = [self label:[UIFont boldSystemFontOfSize:12] in:_bubble];
        _docIcon.textColor = [UIColor whiteColor];
        _docIcon.textAlignment = GMAlignCenter;
        _docIcon.layer.cornerRadius = 8;
        _docIcon.clipsToBounds = YES;
        _docName = [self label:[UIFont boldSystemFontOfSize:15] in:_bubble];
        _docName.lineBreakMode = GMTailTruncation;
        _docInfo = [self label:[UIFont systemFontOfSize:13] in:_bubble];
        _playBadge = [self label:[UIFont boldSystemFontOfSize:16] in:_bubble];
        _playBadge.textColor = [UIColor whiteColor];
        _playBadge.textAlignment = GMAlignCenter;
        _playBadge.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
        _playBadge.layer.cornerRadius = 22;
        _playBadge.clipsToBounds = YES;
        _videoLen = [self label:[UIFont systemFontOfSize:11] in:_bubble];
        _videoLen.textColor = [UIColor whiteColor];
        _videoLen.textAlignment = GMAlignCenter;
        _videoLen.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
        _videoLen.layer.cornerRadius = 8;
        _videoLen.clipsToBounds = YES;
        _sticker = [[UIImageView alloc] init];
        _sticker.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentView addSubview:_sticker];
        _lottie = [[GMLottieView alloc] init];
        _lottie.hidden = YES;
        [self.contentView addSubview:_lottie];
        _stickerTime = [self label:[UIFont systemFontOfSize:11] in:self.contentView];
        _stickerTime.textColor = [UIColor whiteColor];
        _stickerTime.textAlignment = GMAlignCenter;
        _stickerTime.backgroundColor = [GMTheme pillBackground];
        _stickerTime.layer.cornerRadius = 8;
        _stickerTime.clipsToBounds = YES;
        _pill = [self label:[UIFont boldSystemFontOfSize:13] in:self.contentView];
        _pill.textColor = [UIColor whiteColor];
        _pill.textAlignment = GMAlignCenter;
        _pill.numberOfLines = 0;
        _pill.backgroundColor = [GMTheme pillBackground];
        _pill.layer.cornerRadius = 10;
        _pill.clipsToBounds = YES;
    }
    return self;
}

- (void)proxyTapped {
    if (self.onProxy) self.onProxy();
}

- (void)playTapped {
    if (self.onPlay) self.onPlay();
}

@end

#pragma mark - Màn chat

typedef NS_ENUM(NSInteger, GMCompose) { GMComposeNormal, GMComposeReply, GMComposeEdit };

@implementation GMChatViewController {
    UITableView *_table;
    UIView *_bar, *_panel;
    UILabel *_panelTitle, *_panelText;
    UITextView *_input;
    UILabel *_placeholder;
    UIView *_inputBox;
    CGFloat _barH;
    GMTitleView *_titleView;
    CGFloat _layoutW;  // bề ngang đã dùng để xếp bong bóng
    UIButton *_attach;
    AVAudioRecorder *_recorder;
    UILabel *_recLabel;
    NSTimer *_recTimer;
    UIPopoverController *_popover;
    UIView *_upBar;          // thanh «đang gửi tệp» dưới thanh điều hướng
    UILabel *_upLabel;
    UIProgressView *_upProgress;
    NSString *_upTag, *_upName;
    UIButton *_stickerBtn;          // mặt cười trong ô nhập: mở / đóng bảng sticker
    GMStickerPanel *_stickers;      // bảng sticker (nil = chưa mở lần nào)
    BOOL _stickersOpen;
    NSDictionary *_status;      // chat.status / user.status gần nhất
    NSTimer *_typingTimer;      // hết «đang gõ…» của bên kia
    long long _typingSentMs;    // lần cuối mình báo «đang gõ»
    UIButton *_send;
    UIActivityIndicatorView *_spin;
    NSMutableArray *_msgs;   // cũ → mới
    NSMutableArray *_rows;   // @{type: day|msg|service, msg, tail, first}
    NSMutableDictionary *_heights;
    BOOL _loading, _noMore;
    CGFloat _kbBottom;
    GMCompose _compose;
    NSDictionary *_target;   // tin đang trả lời / sửa
    NSDictionary *_menuMsg;  // tin vừa nhấn giữ
    NSMutableDictionary *_tgsPaths;  // sticker động: khoá ô → tệp .tgs đã tải
}

#pragma mark Dựng

- (instancetype)initWithNibName:(NSString *)nib bundle:(NSBundle *)bundle {
    if ((self = [super initWithNibName:nib bundle:bundle])) {
        self.hidesBottomBarWhenPushed = YES;  // màn chat: ô nhập ở đáy, ẩn thanh dưới
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _msgs = [NSMutableArray array];
    _rows = [NSMutableArray array];
    _heights = [NSMutableDictionary dictionary];
    self.view.backgroundColor = [GMTheme background];
    [self.view addSubview:[[GMWallpaperView alloc] initWithFrame:self.view.bounds]];  // nền chung, nằm dưới mọi thứ
    CGRect b = self.view.bounds;
    _table = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, b.size.width, b.size.height - kBarH) style:UITableViewStylePlain];
    _table.dataSource = self;
    _table.delegate = self;
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.backgroundColor = [UIColor clearColor];
    _table.tag = GMTagNoWallpaper;  // nền nằm ở view của màn (lộ cả dưới ô nhập kính)
    [self.view addSubview:_table];  // khung đặt tay ở layoutBars (không co giãn tự động)
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPress:)];
    [_table addGestureRecognizer:lp];

    // Khung trả lời / sửa (trên ô nhập)
    _panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, b.size.width, kPanelH)];
    _panel.backgroundColor = [UIColor clearColor];
    _panel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UIImageView *pbg = [[UIImageView alloc] initWithFrame:_panel.bounds];
    pbg.image = [GMTheme glassBar];
    pbg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_panel addSubview:pbg];
    UIView *pbar = [[UIView alloc] initWithFrame:CGRectMake(10, 6, 2, kPanelH - 12)];
    pbar.backgroundColor = [GMTheme accent];
    [_panel addSubview:pbar];
    _panelTitle = [[UILabel alloc] initWithFrame:CGRectMake(20, 5, b.size.width - 64, 17)];
    _panelTitle.font = [UIFont boldSystemFontOfSize:14];
    _panelTitle.textColor = [GMTheme accent];
    _panelTitle.backgroundColor = [UIColor clearColor];
    _panelTitle.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_panel addSubview:_panelTitle];
    _panelText = [[UILabel alloc] initWithFrame:CGRectMake(20, 22, b.size.width - 64, 17)];
    _panelText.font = [UIFont systemFontOfSize:14];
    _panelText.backgroundColor = [UIColor clearColor];
    _panelText.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_panel addSubview:_panelText];
    UIButton *x = [UIButton buttonWithType:UIButtonTypeCustom];
    x.frame = CGRectMake(b.size.width - 44, 0, 44, kPanelH);
    x.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [x setTitle:@"✕" forState:UIControlStateNormal];
    [x setTitleColor:[GMTheme secondaryText] forState:UIControlStateNormal];
    x.titleLabel.font = [UIFont systemFontOfSize:20];
    [x addTarget:self action:@selector(cancelCompose) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:x];
    _panel.hidden = YES;
    [self.view addSubview:_panel];

    _bar = [[UIView alloc] initWithFrame:CGRectMake(0, b.size.height - kBarH, b.size.width, kBarH)];
    _bar.backgroundColor = [UIColor clearColor];
    _bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UIImageView *bbg = [[UIImageView alloc] initWithFrame:_bar.bounds];
    bbg.image = [GMTheme glassBar];  // kính, vạch sáng mép trên
    bbg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_bar addSubview:bbg];
    // Nút đính kèm (ảnh)
    _attach = [UIButton buttonWithType:UIButtonTypeCustom];
    [_attach setImage:[GMTheme icon:@"clip"] forState:UIControlStateNormal];
    [_attach addTarget:self action:@selector(attachTapped) forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:_attach];
    // Ô nhập nhiều dòng (tự giãn tới ~5 dòng, Return xuống dòng — gửi bằng nút «Gửi», như Telegram)
    _barH = kBarH;
    _inputBox = [[UIView alloc] initWithFrame:CGRectMake(8, 6, b.size.width - 76, kInputMinH)];
    _inputBox.backgroundColor = [UIColor clearColor];
    _inputBox.clipsToBounds = YES;
    UIImageView *fbg = [[UIImageView alloc] initWithFrame:_inputBox.bounds];
    fbg.image = [GMTheme fieldImage];  // ô lõm bo tròn
    fbg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_inputBox addSubview:fbg];
    [_bar addSubview:_inputBox];
    _input = [[UITextView alloc] initWithFrame:CGRectMake(4, 0, _inputBox.bounds.size.width - 8, kInputMinH)];
    _input.font = [UIFont systemFontOfSize:16];
    _input.textColor = [GMTheme text];
    _input.keyboardAppearance = [GMTheme keyboard];
    _input.backgroundColor = [UIColor clearColor];
    _input.delegate = self;
    _input.scrollsToTop = NO;
    _input.scrollEnabled = NO;
    _input.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_inputBox addSubview:_input];
    _placeholder = [[UILabel alloc] initWithFrame:CGRectMake(13, 0, 200, kInputMinH)];
    _placeholder.text = @"Tin nhắn";
    _placeholder.font = [UIFont systemFontOfSize:16];
    _placeholder.textColor = [GMTheme secondaryText];
    _placeholder.backgroundColor = [UIColor clearColor];
    _placeholder.userInteractionEnabled = NO;
    [_inputBox addSubview:_placeholder];
    _stickerBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    [_stickerBtn setImage:[GMTheme icon:@"sticker"] forState:UIControlStateNormal];
    [_stickerBtn addTarget:self action:@selector(stickerTapped) forControlEvents:UIControlEventTouchUpInside];
    [_inputBox addSubview:_stickerBtn];
    _send = [UIButton buttonWithType:UIButtonTypeCustom];
    _send.frame = CGRectMake(b.size.width - 66, 0, 62, kBarH);
    _send.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [_send setTitle:@"Gửi" forState:UIControlStateNormal];
    // «Gửi»: nút xanh bóng kiểu iOS 6 (ảnh nền đặt ở updateSendButton — chế độ mic thì không có nền)
    [_send setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_send setTitleShadowColor:[UIColor colorWithWhite:0 alpha:0.35] forState:UIControlStateNormal];
    _send.titleLabel.shadowOffset = CGSizeMake(0, -1);
    _send.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    _send.adjustsImageWhenHighlighted = NO;
    // Ô nhập trống: nút thành mic — giữ để ghi âm, thả để gửi, kéo ra ngoài để huỷ
    [_send addTarget:self action:@selector(sendTapped) forControlEvents:UIControlEventTouchUpInside];
    [_send addTarget:self action:@selector(sendDown) forControlEvents:UIControlEventTouchDown];
    [_send addTarget:self action:@selector(sendCancel) forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [_send addTarget:self action:@selector(sendDragExit) forControlEvents:UIControlEventTouchDragExit];
    [_send addTarget:self action:@selector(sendDragEnter) forControlEvents:UIControlEventTouchDragEnter];
    [_bar addSubview:_send];
    _recLabel = [[UILabel alloc] init];
    _recLabel.font = [UIFont systemFontOfSize:15];
    _recLabel.textColor = [UIColor colorWithRed:0.85 green:0.15 blue:0.12 alpha:1];
    _recLabel.backgroundColor = [GMTheme fieldBackground];
    _recLabel.hidden = YES;
    [_bar addSubview:_recLabel];
    [self updateSendButton];
    [self.view addSubview:_bar];
    _bar.hidden = [self.kind isEqual:@"channel"];  // kênh: chỉ quản trị viên gửi được — bản đầu ẩn ô nhập

    _spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    _spin.center = CGPointMake(b.size.width / 2, 24);
    _spin.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    _spin.hidesWhenStopped = YES;
    [self.view addSubview:_spin];
    [self layoutBars:NO];

    _titleView = [[GMTitleView alloc] init];
    _titleView.title = self.title;
    self.navigationItem.titleView = _titleView;
    _titleView.userInteractionEnabled = YES;
    [_titleView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showInfo)]];
    // Ảnh đại diện bên phải thanh trên (như Telegram 4.9): chạm → thông tin chat
    UIButton *av = [UIButton buttonWithType:UIButtonTypeCustom];
    av.frame = CGRectMake(0, 0, 36, 36);
    BOOL saved = [self.peer isEqual:self.myId];
    [av setImage:[GMTheme avatarFor:self.peer name:saved ? @"★" : (self.title ?: @"") size:36] forState:UIControlStateNormal];
    [av addTarget:self action:@selector(showInfo) forControlEvents:UIControlEventTouchUpInside];
    if (!saved && self.photo) {
        __weak UIButton *wb = av;
        [GMImages avatarForPeer:self.peer photo:[self.photo description] dc:self.photoDc size:36 done:^(UIImage *img) {
            if (img) [wb setImage:img forState:UIControlStateNormal];
        }];
    }
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:av];
    [GMCore call:@"net.state" args:nil done:^(id ok, NSDictionary *err) {
        _titleView.connecting = ok && ![GMVal(ok, @"ok") boolValue];
    }];
    [self loadStatus];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(event:) name:GMCoreEventNotification object:nil];
    [nc addObserver:self selector:@selector(becameActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(keyboard:) name:UIKeyboardWillShowNotification object:nil];
    [nc addObserver:self selector:@selector(keyboard:) name:UIKeyboardWillHideNotification object:nil];
    [nc addObserver:self selector:@selector(menuHidden) name:UIMenuControllerDidHideMenuNotification object:nil];
    [nc addObserver:self selector:@selector(voiceChanged) name:GMVoiceStateNotification object:nil];
    [nc addObserver:self selector:@selector(filesChanged) name:GMFileStateNotification object:nil];
    [self loadOlder];
    [self performSelector:@selector(loadOutbox) withObject:nil afterDelay:0.5];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

/// Khung các phần theo kích thước thật của màn (viewDidLoad còn là khổ dọc; iPad nằm ngang / xoay máy đổi sau).
- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    [self layoutBars:NO];
    // Xoay máy / iPad nằm ngang: xếp lại bong bóng theo bề ngang mới (so với bề ngang đã xếp, không phải bề ngang bảng —
    // co giãn tự động có thể đã đổi bảng trước khi tới đây)
    if (_layoutW != _table.bounds.size.width) {
        _layoutW = _table.bounds.size.width;
        [_table reloadData];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (_rows.count) [_table reloadData];  // GIF dừng lúc rời màn → chạy lại
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    for (GMBubbleCell *c in _table.visibleCells) {
        if ([c isKindOfClass:[GMBubbleCell class]]) [c stopGif];
    }
    [_input resignFirstResponder];
    [[UIMenuController sharedMenuController] setMenuVisible:NO animated:NO];  // menu nhấn giữ không theo sang màn khác
}

/// Đặt khung trả lời / ô nhập / bảng theo bàn phím và chế độ soạn.
- (void)layoutBars:(BOOL)keepBottom {
    CGRect b = self.view.bounds;
    BOOL bottom = keepBottom && [self nearBottom];
    CGFloat barH = _bar.hidden ? 0 : _barH;
    CGFloat panelH = (_compose != GMComposeNormal) ? kPanelH : 0;
    CGFloat y = b.size.height - _kbBottom - barH;
    _bar.frame = CGRectMake(0, y, b.size.width, _barH);
    _attach.frame = CGRectMake(2, _barH - 46, kAttachW, 44);
    _inputBox.frame = CGRectMake(kAttachW + 4, 6, b.size.width - kAttachW - 72, _barH - 12);
    _input.frame = CGRectMake(4, 0, _inputBox.bounds.size.width - 36, _inputBox.bounds.size.height);
    _stickerBtn.frame = CGRectMake(_inputBox.bounds.size.width - 34, _inputBox.bounds.size.height - kInputMinH, 32, kInputMinH);
    if (_stickersOpen) _stickers.frame = CGRectMake(0, b.size.height - kGMStickerPanelH, b.size.width, kGMStickerPanelH);
    _recLabel.frame = CGRectInset(_inputBox.frame, 10, 2);
    _send.frame = CGRectMake(b.size.width - 66, _barH - 46, 62, 44);
    _panel.hidden = panelH == 0;
    _panel.frame = CGRectMake(0, y - panelH, b.size.width, kPanelH);
    _table.frame = CGRectMake(0, 0, b.size.width, y - panelH);
    _upBar.frame = CGRectMake(0, 0, b.size.width, 34);
    if (bottom) [self scrollToBottom:NO];
}

#pragma mark Trạng thái (dòng phụ dưới tên chat)

- (void)showInfo {
    GMChatInfoViewController *i = [[GMChatInfoViewController alloc] init];
    i.peer = self.peer;
    i.kind = self.kind;
    i.myId = self.myId;
    i.name = self.title;
    [self.navigationController pushViewController:i animated:YES];
}

#pragma mark Sticker / GIF

- (void)stickerTapped {
    if (_stickersOpen) {
        [self closeStickers:YES];
        [_input becomeFirstResponder];
        return;
    }
    if (!_stickers) {
        _stickers = [[GMStickerPanel alloc] initWithFrame:CGRectMake(0, self.view.bounds.size.height, self.view.bounds.size.width, kGMStickerPanelH)];
        _stickers.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        __weak GMChatViewController *ws = self;
        _stickers.manage = ^{
            [ws openStickerManager];
        };
        _stickers.pick = ^(NSDictionary *doc) {
            [ws sendDoc:doc];
        };
        [self.view addSubview:_stickers];
    }
    _stickersOpen = YES;
    _stickers.hidden = NO;
    [_stickerBtn setImage:[GMTheme icon:@"keyboard"] forState:UIControlStateNormal];
    [_input resignFirstResponder];
    _kbBottom = kGMStickerPanelH;
    BOOL wasBottom = [self nearBottom];
    [UIView animateWithDuration:0.25 animations:^{ [self layoutBars:NO]; }
                     completion:^(BOOL f) {
                         if (wasBottom) [self scrollToBottom:YES];
                     }];
    [_stickers reloadIfNeeded];
}

- (void)closeStickers:(BOOL)animated {
    if (!_stickersOpen) return;
    _stickersOpen = NO;
    _stickers.hidden = YES;
    [_stickerBtn setImage:[GMTheme icon:@"sticker"] forState:UIControlStateNormal];
    _kbBottom = 0;
    if (animated) [UIView animateWithDuration:0.25 animations:^{ [self layoutBars:NO]; }];
    else [self layoutBars:NO];
}

/// Gửi sticker / GIF đã có trên máy chủ.
- (void)sendDoc:(NSDictionary *)doc {
    NSNumber *reply = _compose == GMComposeReply ? GMVal(_target, @"id") : nil;
    if (reply) [self setCompose:GMComposeNormal target:nil];
    NSMutableDictionary *a = [@{@"peer": self.peer, @"doc": GMVal(doc, @"doc")} mutableCopy];
    if (reply) [a setObject:reply forKey:@"reply_to"];
    long long t0 = GMNowMs();
    [GMCore call:@"messages.sendDoc" args:a done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.view];
            return;
        }
        GMLog(@"đã gửi sticker / GIF %@ sau %lld ms", GMVal(ok, @"id"), GMNowMs() - t0);
        NSMutableDictionary *m = [ok mutableCopy];
        [m setObject:@YES forKey:@"out"];
        [self append:m];
    }];
}

- (void)debugGifs {
    for (GMBubbleCell *c in _table.visibleCells) {
        if (![c isKindOfClass:[GMBubbleCell class]] || !c.gifPlayer) continue;
        AVPlayerItem *it = c.gifPlayer.currentItem;
        GMLog(@"[thử] GIF %@: %.2f s, tốc độ %.1f, trạng thái %d, lỗi %@", c.gifKey, CMTimeGetSeconds(it.currentTime),
              c.gifPlayer.rate, (int)it.status, it.error.localizedDescription ?: @"-");
    }
}

- (void)debugStickers:(NSString *)arg {
    NSArray *p = [arg componentsSeparatedByString:@" "];
    NSString *what = p.count ? [p objectAtIndex:0] : @"";
    NSInteger i = p.count > 1 ? [[p objectAtIndex:1] integerValue] : 0;
    if ([what isEqual:@"tab"]) [_stickers debugTab:i];
    else if ([what isEqual:@"pick"]) [_stickers debugPick:i];
    else [self stickerTapped];
}

- (void)loadStatus {
    if ([self isSaved]) return;  // Tin nhắn đã lưu: không có dòng phụ
    [GMCore call:@"chat.status" args:@{@"peer": self.peer} done:^(id ok, NSDictionary *err) {
        if (!ok) return;
        _status = ok;
        if (!_typingTimer) [self showStatus];
    }];
}

- (void)showStatus {
    _titleView.subtitle = _status ? [GMTheme statusText:_status] : nil;
}

/// Bên kia đang gõ / ghi âm… — Telegram gửi lại ~5 giây một lần khi còn gõ; 6 giây không có thì về dòng trạng thái.
- (void)showTyping:(NSDictionary *)ev {
    [_typingTimer invalidate];
    _typingTimer = nil;
    if ([GMVal(ev, @"action") isEqual:@"cancel"]) {
        [self showStatus];
        return;
    }
    BOOL group = ![self.kind isEqual:@"user"];
    _titleView.subtitle = [GMTheme typingText:GMVal(ev, @"action") name:group ? GMVal(ev, @"name") : nil];
    _typingTimer = [NSTimer scheduledTimerWithTimeInterval:6 target:self selector:@selector(typingEnded) userInfo:nil repeats:NO];
}

- (void)typingEnded {
    _typingTimer = nil;
    [self showStatus];
}

/// Báo bên kia mình đang gõ / ghi âm (tối đa 5 giây một lần).
- (void)sendTyping:(NSString *)action {
    if ([self isSaved] || [self.kind isEqual:@"channel"]) return;
    long long now = GMNowMs();
    if (now - _typingSentMs < 5000) return;
    _typingSentMs = now;
    [GMCore call:@"messages.typing" args:@{@"peer": self.peer, @"action": action} done:nil];
}

#pragma mark Dữ liệu

- (void)becameActive {
    if (self.navigationController.topViewController == self) {
        [GMCore call:@"messages.read" args:@{@"peer": self.peer} done:nil];
    }
}

- (BOOL)isSaved {
    return [self.peer isEqual:self.myId];
}

- (BOOL)outgoing:(NSDictionary *)m {
    return [self isSaved] || [GMVal(m, @"out") boolValue];
}

/// Dựng hàng hiển thị từ danh sách tin: vạch ngày, gom tin liền nhau của cùng người gửi (≤ 5 phút) — tin cuối cụm có đuôi.
- (void)rebuildRows {
    [_rows removeAllObjects];
    NSDictionary *prev = nil;
    NSNumber *lastDay = nil;
    for (NSUInteger i = 0; i < _msgs.count; i++) {
        NSDictionary *m = [_msgs objectAtIndex:i];
        if (!lastDay || ![GMTheme sameDay:lastDay as:GMVal(m, @"date")]) {
            lastDay = GMVal(m, @"date") ?: @0;
            [_rows addObject:@{@"type": @"day", @"date": lastDay}];
            prev = nil;
        }
        if ([GMVal(m, @"service") boolValue]) {
            [_rows addObject:@{@"type": @"service", @"msg": m}];
            prev = nil;
            continue;
        }
        NSDictionary *next = i + 1 < _msgs.count ? [_msgs objectAtIndex:i + 1] : nil;
        BOOL first = ![self sameGroup:prev as:m];
        BOOL tail = ![self sameGroup:m as:next];
        [_rows addObject:@{@"type": @"msg", @"msg": m, @"first": @(first), @"tail": @(tail)}];
        prev = m;
    }
}

- (BOOL)sameGroup:(NSDictionary *)a as:(NSDictionary *)b {
    if (!a || !b || [GMVal(b, @"service") boolValue] || [GMVal(a, @"service") boolValue]) return NO;
    if ([self outgoing:a] != [self outgoing:b]) return NO;
    id fa = GMVal(a, @"from_id"), fb = GMVal(b, @"from_id");
    if (fa && fb && ![fa isEqual:fb]) return NO;
    if (![GMTheme sameDay:GMVal(a, @"date") as:GMVal(b, @"date")]) return NO;
    return [GMVal(b, @"date") doubleValue] - [GMVal(a, @"date") doubleValue] < 300;
}

- (void)reloadTable {
    [self rebuildRows];
    [_table reloadData];
}

- (void)loadOlder {
    if (_loading || _noMore) return;
    _loading = YES;
    [_spin startAnimating];
    NSDictionary *oldest = _msgs.firstObject;
    NSMutableDictionary *args = [@{@"peer": self.peer, @"limit": @40} mutableCopy];
    if (oldest) [args setObject:GMVal(oldest, @"id") forKey:@"offset_id"];
    long long t = GMNowMs();
    [GMCore call:@"messages.history" args:args done:^(id ok, NSDictionary *err) {
        _loading = NO;
        [_spin stopAnimating];
        if (err) {
            GMLog(@"tải tin lỗi: %@", GMVal(err, @"code"));
            return;
        }
        NSArray *page = ok;  // mới → cũ
        GMLog(@"tải %lu tin, %lld ms", (unsigned long)page.count, GMNowMs() - t);
        if (page.count < 40) _noMore = YES;
        if (!page.count) return;
        BOOL first = _msgs.count == 0;
        CGFloat before = _table.contentSize.height;
        CGFloat offset = _table.contentOffset.y;
        for (NSDictionary *m in page) [_msgs insertObject:m atIndex:0];
        [self reloadTable];
        if (self.jumpTo) {
            [self tryJump];
            return;
        }
        if (first) {
            [self scrollToBottom:NO];
            // App ở nền (vd mở chat từ thông báo chưa xong): chưa tính là đã đọc — quay lại app mới đánh dấu
            if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
                [GMCore call:@"messages.read" args:@{@"peer": self.peer} done:nil];
            }
        } else {
            // Giữ nguyên chỗ đang xem khi chèn tin cũ lên đầu
            [_table layoutIfNeeded];
            _table.contentOffset = CGPointMake(0, offset + _table.contentSize.height - before);
        }
    }];
}

/// Nhảy tới `jumpTo`: có trong tin đã tải thì cuộn + tô sáng; chưa thì tải tiếp tin cũ (tối đa ~600 tin).
- (void)tryJump {
    NSNumber *target = self.jumpTo;
    NSInteger row = NSNotFound;
    for (NSInteger r = 0; r < (NSInteger)_rows.count; r++) {
        if ([GMVal([[_rows objectAtIndex:r] objectForKey:@"msg"], @"id") isEqual:target]) {
            row = r;
            break;
        }
    }
    if (row == NSNotFound) {
        if (_noMore || _msgs.count > 600) {
            self.jumpTo = nil;
            [self scrollToBottom:NO];
            [GMTheme toast:@"Không tìm thấy tin này." in:self.view];
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [self loadOlder]; });
        return;
    }
    self.jumpTo = nil;
    NSIndexPath *ip = [NSIndexPath indexPathForRow:row inSection:0];
    [_table scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
    UITableViewCell *c = [_table cellForRowAtIndexPath:ip];
    UIView *flash = [[UIView alloc] initWithFrame:c.bounds];
    flash.backgroundColor = [UIColor colorWithRed:1 green:0.9 blue:0.4 alpha:0.45];
    flash.userInteractionEnabled = NO;
    [c addSubview:flash];
    [UIView animateWithDuration:1.2 delay:0.8 options:0 animations:^{ flash.alpha = 0; } completion:^(BOOL f) { [flash removeFromSuperview]; }];
}

- (void)scrollToBottom:(BOOL)animated {
    if (!_rows.count) return;
    [_table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:_rows.count - 1 inSection:0]
                  atScrollPosition:UITableViewScrollPositionBottom
                          animated:animated];
}

- (BOOL)nearBottom {
    return _table.contentOffset.y + _table.bounds.size.height >= _table.contentSize.height - 80;
}

- (NSInteger)indexOf:(id)msgId {
    for (NSInteger i = _msgs.count - 1; i >= 0; i--) {
        if ([GMVal([_msgs objectAtIndex:i], @"id") isEqual:msgId]) return i;
    }
    return NSNotFound;
}

- (NSDictionary *)msgWithId:(id)msgId {
    NSInteger i = msgId ? [self indexOf:msgId] : NSNotFound;
    return i == NSNotFound ? nil : [_msgs objectAtIndex:i];
}

- (void)append:(NSDictionary *)m {
    if ([self indexOf:GMVal(m, @"id")] != NSNotFound) return;
    BOOL bottom = [self nearBottom] || [GMVal(m, @"out") boolValue];
    [_msgs addObject:m];
    [self reloadTable];
    if (bottom) [self scrollToBottom:YES];
}

- (void)event:(NSNotification *)n {
    NSDictionary *ev = n.userInfo;
    NSString *e = GMVal(ev, @"e");
    NSDictionary *m = GMVal(ev, @"msg");
    if ([e isEqual:@"typing"] && [GMVal(ev, @"peer") isEqual:self.peer] && ![GMVal(ev, @"from") isEqual:self.myId]) {
        [self showTyping:ev];
        return;
    }
    if ([e isEqual:@"user.status"] && [GMVal(ev, @"peer") isEqual:self.peer]) {
        NSMutableDictionary *st = [ev mutableCopy];
        [st setObject:@"user" forKey:@"kind"];
        _status = st;
        if (!_typingTimer) [self showStatus];
        return;
    }
    if ([e isEqual:@"outbox.sent"] && [GMVal(ev, @"peer") isEqual:self.peer]) {
        [self replacePending:GMVal(ev, @"local_id") with:GMVal(ev, @"msg") newId:nil];
        return;
    }
    if ([e isEqual:@"outbox.failed"] && [GMVal(ev, @"peer") isEqual:self.peer]) {
        [self markFailed:GMVal(ev, @"local_id") error:@{@"code": GMVal(ev, @"code") ?: @"", @"message": GMVal(ev, @"message") ?: @""}];
        return;
    }
    if ([e isEqual:@"upload.progress"]) {
        if (_upTag && [GMVal(ev, @"tag") isEqual:_upTag]) {
            double total = [GMVal(ev, @"total") doubleValue], done = [GMVal(ev, @"done") doubleValue];
            [self showUpload:[NSString stringWithFormat:@"Đang gửi %@ — %.0f%%", _upName, total > 0 ? done * 100 / total : 0]
                    progress:total > 0 ? done / total : 0];
        }
        return;
    }
    if ([e isEqual:@"msg.new"] && [GMVal(m, @"peer") isEqual:self.peer]) {
        [self append:m];
        // Ở nền (đang mở chat này rồi bấm Home): chưa tính là đã đọc — quay lại app mới đánh dấu
        if (![GMVal(m, @"out") boolValue] && [UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
            [GMCore call:@"messages.read" args:@{@"peer": self.peer} done:nil];
        }
    } else if ([e isEqual:@"msg.edit"] && [GMVal(m, @"peer") isEqual:self.peer]) {
        NSInteger i = [self indexOf:GMVal(m, @"id")];
        if (i != NSNotFound) {
            [_msgs replaceObjectAtIndex:i withObject:m];
            [self reloadTable];
        }
    } else if ([e isEqual:@"msg.delete"]) {
        NSString *channel = GMVal(ev, @"channel");
        // Xoá ở kênh / siêu nhóm có kèm kênh; còn lại (chat riêng, nhóm thường) id là chung của tài khoản
        if (channel && ![channel isEqual:self.peer]) return;
        if (!channel && [self.peer hasPrefix:@"-100"]) return;
        [self removeIds:GMVal(ev, @"ids")];
    } else if ([e isEqual:@"net.state"]) {
        _titleView.connecting = ![GMVal(ev, @"ok") boolValue];
    } else if ([e isEqual:@"msg.readOutbox"] && [GMVal(ev, @"peer") isEqual:self.peer]) {
        self.readOut = MAX(self.readOut, [GMVal(ev, @"max_id") integerValue]);
        [_table reloadData];
    }
}

- (void)removeIds:(NSArray *)ids {
    NSIndexSet *gone = [_msgs indexesOfObjectsPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
        return [ids containsObject:GMVal(obj, @"id")];
    }];
    if (gone.count) {
        [_msgs removeObjectsAtIndexes:gone];
        [self reloadTable];
    }
}

#pragma mark Soạn / gửi

- (void)textViewDidChange:(UITextView *)tv {
    if (tv.text.length && _compose != GMComposeEdit) [self sendTyping:@"typing"];
    _placeholder.hidden = tv.text.length > 0;
    [self updateSendButton];
    CGFloat content = tv.contentSize.height;
    CGFloat h = MIN(kInputMaxH, MAX(kInputMinH, content));
    tv.scrollEnabled = content > kInputMaxH;
    CGFloat barH = h + 12;
    if (barH != _barH) {
        _barH = barH;
        [UIView animateWithDuration:0.15 animations:^{ [self layoutBars:YES]; }];
    }
}

- (void)setCompose:(GMCompose)mode target:(NSDictionary *)m {
    _compose = mode;
    _target = m;
    if (mode == GMComposeReply) {
        _panelTitle.text = [NSString stringWithFormat:@"Trả lời %@", [self outgoing:m] ? @"chính bạn" : (GMVal(m, @"from") ?: @"")];
        _panelText.text = [GMTheme preview:m];
    } else if (mode == GMComposeEdit) {
        _panelTitle.text = @"Sửa tin nhắn";
        _panelText.text = [GMTheme preview:m];
        _input.text = GMVal(m, @"text");
        [self textViewDidChange:_input];
    }
    [UIView animateWithDuration:0.2 animations:^{ [self layoutBars:YES]; }];
    if (mode != GMComposeNormal) [_input becomeFirstResponder];
}

- (void)cancelCompose {
    if (_compose == GMComposeEdit) {
        _input.text = @"";
        [self textViewDidChange:_input];
    }
    [self setCompose:GMComposeNormal target:nil];
}

#pragma mark Ghi âm (nút mic khi ô nhập trống)

- (BOOL)micMode {
    return _input.text.length == 0 && _compose != GMComposeEdit;
}

- (void)updateSendButton {
    BOOL mic = [self micMode];
    [_send setTitle:mic ? nil : @"Gửi" forState:UIControlStateNormal];
    [_send setImage:mic ? [GMTheme icon:@"mic"] : nil forState:UIControlStateNormal];
    [_send setBackgroundImage:mic ? nil : [GMTheme sendButtonImage:NO] forState:UIControlStateNormal];
    [_send setBackgroundImage:mic ? nil : [GMTheme sendButtonImage:YES] forState:UIControlStateHighlighted];
}

- (NSString *)recPath {
    NSString *dir = [GMDataDir() stringByAppendingPathComponent:@"tmp"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return [dir stringByAppendingPathComponent:@"rec.wav"];
}

- (void)sendDown {
    if (![self micMode] || _recorder) return;
    _typingSentMs = 0;
    [self sendTyping:@"recording"];
    [[GMVoicePlayer shared] stop];
    AVAudioSession *as = [AVAudioSession sharedInstance];
    [as setCategory:AVAudioSessionCategoryPlayAndRecord error:NULL];
    [as setActive:YES error:NULL];
    NSDictionary *settings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @16000.0, AVNumberOfChannelsKey: @1,
        AVLinearPCMBitDepthKey: @16, AVLinearPCMIsBigEndianKey: @NO, AVLinearPCMIsFloatKey: @NO,
    };
    NSError *e = nil;
    _recorder = [[AVAudioRecorder alloc] initWithURL:[NSURL fileURLWithPath:[self recPath]] settings:settings error:&e];
    if (!_recorder || ![_recorder record]) {
        GMLog(@"ghi âm lỗi: %@", e);
        _recorder = nil;
        [GMTheme toast:@"Không ghi âm được" in:self.view];
        return;
    }
    GMLog(@"bắt đầu ghi âm");
    _recLabel.hidden = NO;
    [self recTick];
    _recTimer = [NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(recTick) userInfo:nil repeats:YES];
}

- (void)recTick {
    int s = (int)_recorder.currentTime;
    BOOL outside = _send.state == UIControlStateNormal && !_send.highlighted;
    _recLabel.text = [NSString stringWithFormat:@"● %d:%02d   %@", s / 60, s % 60,
                                                 outside ? @"Thả tay để huỷ" : @"Thả tay để gửi · kéo ra ngoài để huỷ"];
}

- (void)sendDragExit {
    if (_recorder) _recLabel.text = @"● Thả tay để huỷ";
}

- (void)sendDragEnter {
    if (_recorder) [self recTick];
}

- (NSTimeInterval)stopRecording {
    NSTimeInterval d = _recorder.currentTime;
    [_recorder stop];
    _recorder = nil;
    [_recTimer invalidate];
    _recTimer = nil;
    _recLabel.hidden = YES;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:NULL];
    return d;
}

- (void)sendCancel {
    if (!_recorder) return;
    [self stopRecording];
    [[NSFileManager defaultManager] removeItemAtPath:[self recPath] error:NULL];
    GMLog(@"huỷ ghi âm");
}

/// Gửi tin thoại từ tệp WAV (ghi âm của app, hoặc công cụ thử).
- (void)sendVoiceFile:(NSString *)path {
    NSNumber *reply = _compose == GMComposeReply ? GMVal(_target, @"id") : nil;
    if (reply) [self setCompose:GMComposeNormal target:nil];
    NSMutableDictionary *args = [@{@"peer": self.peer, @"path": path} mutableCopy];
    if (reply) [args setObject:reply forKey:@"reply_to"];
    long long t0 = GMNowMs();
    [GMCore call:@"messages.sendVoice" args:args done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.view];
            return;
        }
        GMLog(@"đã gửi tin thoại %@ sau %lld ms", GMVal(ok, @"id"), GMNowMs() - t0);
        [self append:ok];
    }];
}

- (void)sendTapped {
    _typingSentMs = 0;
    if (_recorder) {
        NSTimeInterval d = [self stopRecording];
        if (d < 0.7) {
            [GMTheme toast:@"Giữ nút mic để ghi âm" in:self.view];
            return;
        }
        [self sendVoiceFile:[self recPath]];
        return;
    }
    if ([self micMode]) return;
    NSString *t = [_input.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!t.length) return;
    _input.text = @"";
    [self textViewDidChange:_input];
    if (_compose == GMComposeEdit) {
        NSDictionary *m = _target;
        [self setCompose:GMComposeNormal target:nil];
        [self editMessage:m text:t];
        return;
    }
    NSNumber *reply = _compose == GMComposeReply ? GMVal(_target, @"id") : nil;
    [self setCompose:GMComposeNormal target:nil];
    [self sendText:t reply:reply];
}

- (void)sendText:(NSString *)text {
    [self sendText:text reply:nil];
}

/// Gửi tin chữ: bong bóng «🕓 đang gửi» hiện ngay (mã tạm âm); gửi được → thay bằng tin thật; mất mạng → lõi giữ trong hàng
/// chờ, có mạng tự gửi (sự kiện outbox.sent); máy chủ từ chối → ⚠️, chạm để gửi lại / xoá.
- (void)sendText:(NSString *)text reply:(NSNumber *)reply {
    long long t0 = GMNowMs();
    NSNumber *tmp = @(-(t0 % 1000000000) - 1);
    NSMutableDictionary *pending = [@{@"id": tmp, @"peer": self.peer, @"text": text, @"out": @YES, @"pending": @YES,
                                      @"date": @((long long)[[NSDate date] timeIntervalSince1970])} mutableCopy];
    if (reply) [pending setObject:reply forKey:@"reply_to"];
    [self append:pending];
    NSMutableDictionary *args = [@{@"peer": self.peer, @"text": text, @"queue": @YES} mutableCopy];
    if (reply) [args setObject:reply forKey:@"reply_to"];
    [GMCore call:@"messages.send" args:args done:^(id ok, NSDictionary *err) {
        if (err) {
            GMLog(@"gửi tin lỗi: %@", GMVal(err, @"code"));
            [self markFailed:tmp error:err];
            return;
        }
        if ([GMVal(ok, @"queued") boolValue]) {
            GMLog(@"mất mạng: tin vào hàng chờ");
            [self replacePending:tmp with:nil newId:GMVal(ok, @"local_id")];
            return;
        }
        GMLog(@"đã gửi tin %@ sau %lld ms", GMVal(ok, @"id"), GMNowMs() - t0);
        [self replacePending:tmp with:ok newId:nil];
    }];
}

/// Thay bong bóng chờ `tmp`: bằng tin thật `msg` (đã có thì chỉ bỏ bong bóng chờ), hoặc đổi mã tạm thành `newId`.
- (void)replacePending:(NSNumber *)tmp with:(NSDictionary *)msg newId:(NSNumber *)newId {
    NSInteger i = [self indexOf:tmp];
    if (i == NSNotFound) {
        if (msg) [self append:msg];
        return;
    }
    if (msg) {
        if ([self indexOf:GMVal(msg, @"id")] != NSNotFound) {
            [_msgs removeObjectAtIndex:i];
        } else {
            NSMutableDictionary *m = [msg mutableCopy];
            [m setObject:@YES forKey:@"out"];
            [_msgs replaceObjectAtIndex:i withObject:m];
        }
    } else if (newId) {
        NSMutableDictionary *m = [[_msgs objectAtIndex:i] mutableCopy];
        [m setObject:newId forKey:@"id"];
        [_msgs replaceObjectAtIndex:i withObject:m];
    }
    [self reloadTable];
}

- (void)markFailed:(NSNumber *)tmp error:(NSDictionary *)err {
    NSInteger i = [self indexOf:tmp];
    if (i == NSNotFound) return;
    NSMutableDictionary *m = [[_msgs objectAtIndex:i] mutableCopy];
    [m removeObjectForKey:@"pending"];
    [m setObject:@YES forKey:@"failed"];
    [m setObject:GMErrorText(err) ?: @"" forKey:@"error"];
    [_msgs replaceObjectAtIndex:i withObject:m];
    [self reloadTable];
}

/// Tin trong hàng chờ của lõi (mở chat sau khi tắt app lúc còn tin chưa gửi).
- (void)loadOutbox {
    [GMCore call:@"outbox.list" args:@{@"peer": self.peer} done:^(id ok, NSDictionary *err) {
        if (![ok isKindOfClass:[NSArray class]]) return;
        for (NSDictionary *it in ok) {
            NSMutableDictionary *m = [it mutableCopy];
            [m setObject:GMVal(it, @"local_id") forKey:@"id"];
            [m setObject:@YES forKey:@"out"];
            [m setObject:@YES forKey:@"pending"];
            [self append:m];
        }
    }];
}

/// Chạm tin gửi lỗi → gửi lại / xoá.
- (void)failedTapped:(NSDictionary *)m {
    UIActionSheet *s = [[UIActionSheet alloc] initWithTitle:[NSString stringWithFormat:@"Không gửi được: %@", GMVal(m, @"error") ?: @""]
                                                   delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
    [s addButtonWithTitle:@"Gửi lại"];
    s.destructiveButtonIndex = [s addButtonWithTitle:@"Xoá"];
    s.cancelButtonIndex = [s addButtonWithTitle:@"Huỷ"];
    objc_setAssociatedObject(s, "failed", m, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [s showInView:self.view];
}

- (void)editMessage:(NSDictionary *)m text:(NSString *)text {
    if ([text isEqualToString:GMVal(m, @"text") ?: @""]) return;  // không đổi gì
    [GMCore call:@"messages.edit" args:@{@"peer": self.peer, @"id": GMVal(m, @"id"), @"text": text} done:^(id ok, NSDictionary *err) {
        if (err) {
            [[[UIAlertView alloc] initWithTitle:@"Không sửa được" message:GMErrorText(err) delegate:nil cancelButtonTitle:@"OK"
                              otherButtonTitles:nil] show];
            return;
        }
        NSInteger i = [self indexOf:GMVal(m, @"id")];
        if (i == NSNotFound) return;
        NSMutableDictionary *e = [[_msgs objectAtIndex:i] mutableCopy];
        [e setObject:text forKey:@"text"];
        [e setObject:@YES forKey:@"edited"];
        [_msgs replaceObjectAtIndex:i withObject:e];
        [self reloadTable];
    }];
}

#pragma mark Tin thoại

- (void)refreshVoice:(GMBubbleCell *)c {
    NSDictionary *m = c.voiceMsg;
    if (!m) return;
    GMVoicePlayer *vp = [GMVoicePlayer shared];
    NSInteger st = [vp stateOf:self.peer msg:GMVal(m, @"id")];
    [c.play setTitle:st == 2 ? @"❚❚" : st == 1 ? @"…" : @"►" forState:UIControlStateNormal];
    c.wave.progress = [vp progressOf:self.peer msg:GMVal(m, @"id")];
    [c.wave setNeedsDisplay];
    int secs = st >= 2 ? (int)[vp timeOf:self.peer msg:GMVal(m, @"id")] : [GMVal(GMVal(m, @"voice"), @"duration") intValue];
    c.voiceTime.text = [NSString stringWithFormat:@"%d:%02d", secs / 60, secs % 60];
}

- (void)voiceChanged {
    for (GMBubbleCell *c in _table.visibleCells) {
        if ([c isKindOfClass:[GMBubbleCell class]]) [self refreshVoice:c];
    }
}

- (void)debugPlayVoiceFromBottom:(NSInteger)k {
    NSInteger seen = -1;
    for (NSInteger r = _rows.count - 1; r >= 0; r--) {
        NSDictionary *m = [[_rows objectAtIndex:r] objectForKey:@"msg"];
        if (GMVal(m, @"voice") && ++seen == k) {
            [[GMVoicePlayer shared] toggle:self.peer msg:GMVal(m, @"id")];
            return;
        }
    }
}

#pragma mark Tệp, video

static NSString *GMSize(double b) {
    return [GMTheme sizeText:b];
}

/// GIF tự chạy trong bong bóng (lặp, không tiếng — GIF của Telegram là MP4 không có tiếng). Chưa có tệp: GIF < 3 MB thì tự tải.
- (void)gifFor:(GMBubbleCell *)c msg:(NSDictionary *)m on:(BOOL)on {
    NSString *key = on ? [NSString stringWithFormat:@"%@|%@", self.peer, GMVal(m, @"id")] : nil;
    if (key && [c.gifKey isEqual:key]) {
        c.gifLayer.frame = c.photo.bounds;
        c.playBadge.hidden = c.gifPlayer != nil;
        return;
    }
    [c stopGif];
    if (!on) return;
    c.gifKey = key;
    NSString *path = [[GMFiles shared] pathFor:self.peer msg:GMVal(m, @"id")];
    if (path) {
        c.playBadge.hidden = YES;
        [c playGif:path];
        return;
    }
    double size = [GMVal(GMVal(m, @"doc"), @"size") doubleValue];
    if (size <= 0 || size > 3 * 1048576) return;
    __weak GMBubbleCell *wc = c;
    [[GMFiles shared] fetch:self.peer msg:GMVal(m, @"id") done:^(NSString *p) {
        if (!p || ![wc.gifKey isEqual:key]) return;
        wc.playBadge.hidden = YES;
        [wc playGif:p];
    }];
}

- (void)refreshDoc:(GMBubbleCell *)c {
    NSDictionary *m = c.docMsg;
    if (!m) return;
    GMFiles *f = [GMFiles shared];
    double p = [f progressOf:self.peer msg:GMVal(m, @"id")];
    BOOL have = [f pathFor:self.peer msg:GMVal(m, @"id")] != nil;
    double size = [GMVal(GMVal(m, @"doc"), @"size") doubleValue];
    if ([self isVideo:m]) {
        c.playBadge.text = p >= 0 ? [NSString stringWithFormat:@"%.0f%%", p * 100] : @"►";
        c.playBadge.font = p >= 0 ? [UIFont boldSystemFontOfSize:13] : [UIFont boldSystemFontOfSize:18];
    } else {
        c.docInfo.text = p >= 0 ? [NSString stringWithFormat:@"Đang tải %.0f%% · %@", p * 100, GMSize(size)]
                                : [NSString stringWithFormat:@"%@ · %@", GMSize(size), have ? @"chạm để mở" : @"chạm để tải"];
    }
}

- (void)filesChanged {
    for (GMBubbleCell *c in _table.visibleCells) {
        if ([c isKindOfClass:[GMBubbleCell class]]) [self refreshDoc:c];
    }
}

- (void)openDoc:(NSDictionary *)m {
    NSString *kind = GMVal(GMVal(m, @"doc"), @"kind");
    __weak GMChatViewController *ws = self;
    [[GMFiles shared] fetch:self.peer msg:GMVal(m, @"id") done:^(NSString *path) {
        if (!path) {
            [GMTheme toast:@"Không tải được tệp" in:ws.view];
            return;
        }
        NSURL *url = [NSURL fileURLWithPath:path];
        if ([kind isEqual:@"video"] || [kind isEqual:@"gif"] || [kind isEqual:@"round"] || [kind isEqual:@"audio"]) {
            [[GMVoicePlayer shared] stop];
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:NULL];
            MPMoviePlayerViewController *mp = [[MPMoviePlayerViewController alloc] initWithContentURL:url];
            if ([kind isEqual:@"gif"]) mp.moviePlayer.repeatMode = MPMovieRepeatModeOne;
            [ws presentMoviePlayerViewControllerAnimated:mp];
        } else {
            GMPreviewItem *item = [[GMPreviewItem alloc] init];
            item.previewItemURL = [ws previewableURL:url];
            NSString *name = GMVal(GMVal(m, @"doc"), @"name");
            item.previewItemTitle = name.length ? name : url.lastPathComponent;
            ws.previewItem = item;
            QLPreviewController *q = [[QLPreviewController alloc] init];
            q.dataSource = ws;
            [ws presentViewController:q animated:YES completion:nil];
        }
    }];
}

- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)controller {
    return self.previewItem ? 1 : 0;
}

- (id<QLPreviewItem>)previewController:(QLPreviewController *)controller previewItemAtIndex:(NSInteger)index {
    return self.previewItem;
}

/// QuickLook iOS 5 / 6 đọc tệp chữ không có BOM theo bảng mã Latin (tiếng Việt vỡ) → tệp chữ UTF-8 thiếu BOM thì xem bản sao
/// có BOM (tệp gốc giữ nguyên).
static const unsigned char kGMBOM[3] = {0xEF, 0xBB, 0xBF};

- (NSURL *)previewableURL:(NSURL *)url {
    NSString *ext = url.pathExtension.lowercaseString;
    if (![@[@"txt", @"csv", @"log", @"md", @"json", @"xml", @"srt"] containsObject:ext]) return url;
    NSData *d = [NSData dataWithContentsOfURL:url];
    if (d.length >= 3 && memcmp(d.bytes, kGMBOM, 3) == 0) return url;
    if (![[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]) return url;  // không phải UTF-8: để nguyên
    NSString *dir = [GMDataDir() stringByAppendingPathComponent:@"tmp"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *copy = [dir stringByAppendingPathComponent:[@"bom-" stringByAppendingString:url.lastPathComponent]];
    NSMutableData *out = [NSMutableData dataWithBytes:kGMBOM length:3];
    [out appendData:d];
    [out writeToFile:copy atomically:YES];
    return [NSURL fileURLWithPath:copy];
}

- (void)debugOpenDocFromBottom:(NSInteger)k {
    for (NSInteger r = _rows.count - 1, seen = -1; r >= 0; r--) {
        NSDictionary *m = [[_rows objectAtIndex:r] objectForKey:@"msg"];
        if (GMVal(m, @"doc") && ++seen == k) {
            [self openDoc:m];
            return;
        }
    }
}

#pragma mark Đính kèm ảnh

- (void)attachTapped {
    [_input resignFirstResponder];
    UIActionSheet *s = [[UIActionSheet alloc] initWithTitle:nil delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil
                                          otherButtonTitles:nil];
    NSMutableArray *kinds = [NSMutableArray array];
    if ([UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
        [s addButtonWithTitle:@"Chụp ảnh"];
        [kinds addObject:@(UIImagePickerControllerSourceTypeCamera)];
    }
    [s addButtonWithTitle:@"Ảnh / video có sẵn"];
    [kinds addObject:@(UIImagePickerControllerSourceTypePhotoLibrary)];
    [s addButtonWithTitle:@"Tệp trên máy"];
    [kinds addObject:@(-1)];
    s.cancelButtonIndex = [s addButtonWithTitle:@"Huỷ"];
    objc_setAssociatedObject(s, "attach", kinds, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [s showInView:self.view];
}

- (void)pickFrom:(UIImagePickerControllerSourceType)src {
    UIImagePickerController *p = [[UIImagePickerController alloc] init];
    p.sourceType = src;
    p.delegate = self;
    if (src == UIImagePickerControllerSourceTypePhotoLibrary) {
        // Ảnh và video; video lấy bản gốc (tự nén sang MP4 640×480 lúc gửi)
        p.mediaTypes = @[GMUTImage, GMUTMovie];
        p.videoQuality = UIImagePickerControllerQualityTypeHigh;
    }
    // iPad (iOS 5 / 6): thư viện ảnh phải hiện trong popover, không thì văng app
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad && src != UIImagePickerControllerSourceTypeCamera) {
        _popover = [[UIPopoverController alloc] initWithContentViewController:p];
        [_popover presentPopoverFromRect:_attach.bounds inView:_attach permittedArrowDirections:UIPopoverArrowDirectionAny
                                animated:YES];
    } else {
        [self presentViewController:p animated:YES completion:nil];
    }
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
    UIImage *img = [info objectForKey:UIImagePickerControllerOriginalImage];
    NSURL *movie = [[info objectForKey:UIImagePickerControllerMediaType] isEqual:GMUTMovie]
                       ? [info objectForKey:UIImagePickerControllerMediaURL]
                       : nil;
    if (_popover) {
        [_popover dismissPopoverAnimated:YES];
        _popover = nil;
    } else {
        [picker dismissViewControllerAnimated:YES completion:nil];
    }
    if (movie) [self sendVideoURL:movie];
    else if (img) [self sendImage:img];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

/// Thu ảnh về cạnh dài ≤ 1280, JPEG 0,8, rồi gửi (ở hàng nền — ảnh 8 MP trên A4 mất cỡ giây).
- (void)sendImage:(UIImage *)img {
    [GMTheme toast:@"Đang gửi ảnh…" in:self.view];
    NSString *path = [[GMDataDir() stringByAppendingPathComponent:@"tmp"] stringByAppendingPathComponent:@"photo.jpg"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CGSize s = img.size;
        CGFloat k = MIN(1.0, 1280.0 / MAX(s.width, s.height));
        CGSize to = CGSizeMake(floor(s.width * k), floor(s.height * k));
        UIGraphicsBeginImageContextWithOptions(to, YES, 1);
        [img drawInRect:CGRectMake(0, 0, to.width, to.height)];
        UIImage *small = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        [UIImageJPEGRepresentation(small, 0.8) writeToFile:path atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{ [self sendPhotoFile:path]; });
    });
}

- (void)sendPhotoFile:(NSString *)path {
    NSNumber *reply = _compose == GMComposeReply ? GMVal(_target, @"id") : nil;
    if (reply) [self setCompose:GMComposeNormal target:nil];
    NSMutableDictionary *args = [@{@"peer": self.peer, @"path": path} mutableCopy];
    if (reply) [args setObject:reply forKey:@"reply_to"];
    long long t0 = GMNowMs();
    [GMCore call:@"messages.sendPhoto" args:args done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.view];
            return;
        }
        GMLog(@"đã gửi ảnh %@ sau %lld ms", GMVal(ok, @"id"), GMNowMs() - t0);
        [self append:ok];
    }];
}

#pragma mark Gửi tệp, video

/// Mime theo đuôi tệp (đủ cho tệp hay gửi; lạ thì application/octet-stream — Telegram vẫn nhận).
static NSString *GMMimeFor(NSString *path) {
    static NSDictionary *map;
    if (!map) {
        map = @{
            @"txt": @"text/plain", @"csv": @"text/csv", @"html": @"text/html", @"htm": @"text/html", @"xml": @"text/xml",
            @"json": @"application/json", @"pdf": @"application/pdf", @"rtf": @"application/rtf",
            @"doc": @"application/msword", @"xls": @"application/vnd.ms-excel", @"ppt": @"application/vnd.ms-powerpoint",
            @"docx": @"application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            @"xlsx": @"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            @"pptx": @"application/vnd.openxmlformats-officedocument.presentationml.presentation",
            @"zip": @"application/zip", @"rar": @"application/x-rar-compressed", @"7z": @"application/x-7z-compressed",
            @"gz": @"application/gzip", @"tar": @"application/x-tar", @"deb": @"application/vnd.debian.binary-package",
            @"ipa": @"application/octet-stream", @"apk": @"application/vnd.android.package-archive",
            @"jpg": @"image/jpeg", @"jpeg": @"image/jpeg", @"png": @"image/png", @"gif": @"image/gif", @"bmp": @"image/bmp",
            @"tif": @"image/tiff", @"tiff": @"image/tiff", @"heic": @"image/heic", @"webp": @"image/webp",
            @"mp4": @"video/mp4", @"m4v": @"video/x-m4v", @"mov": @"video/quicktime", @"3gp": @"video/3gpp",
            @"avi": @"video/x-msvideo", @"mkv": @"video/x-matroska", @"webm": @"video/webm",
            @"mp3": @"audio/mpeg", @"m4a": @"audio/mp4", @"aac": @"audio/aac", @"wav": @"audio/wav", @"ogg": @"audio/ogg",
            @"flac": @"audio/flac", @"amr": @"audio/amr",
        };
    }
    return [map objectForKey:path.pathExtension.lowercaseString] ?: @"application/octet-stream";
}

- (void)openFileBrowser {
    __weak GMChatViewController *ws = self;
    GMFileBrowserViewController *b = [[GMFileBrowserViewController alloc] initWithPath:nil title:nil];
    b.onPick = ^(NSString *path) {
        [ws sendFileAt:path name:path.lastPathComponent mime:GMMimeFor(path) video:nil adopt:NO];
    };
    UINavigationController *n = [[UINavigationController alloc] initWithRootViewController:b];
    n.modalPresentationStyle = UIModalPresentationFormSheet;  // iPad: khung giữa màn; iPhone: toàn màn
    [self presentViewController:n animated:YES completion:nil];
}

/// Thanh «đang gửi» dưới thanh điều hướng (nil = ẩn).
- (void)showUpload:(NSString *)text progress:(double)p {
    if (!text) {
        _upBar.hidden = YES;
        return;
    }
    if (!_upBar) {
        _upBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 34)];
        _upBar.backgroundColor = [[GMTheme barBackground] colorWithAlphaComponent:0.94];
        _upBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        _upLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 3, _upBar.bounds.size.width - 20, 18)];
        _upLabel.font = [UIFont systemFontOfSize:13];
        _upLabel.textColor = [GMTheme secondaryText];
        _upLabel.backgroundColor = [UIColor clearColor];
        _upLabel.lineBreakMode = GMMiddleTruncation;
        _upLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [_upBar addSubview:_upLabel];
        _upProgress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
        _upProgress.frame = CGRectMake(10, 24, _upBar.bounds.size.width - 20, 6);
        _upProgress.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        if ([_upProgress respondsToSelector:@selector(setProgressTintColor:)]) _upProgress.progressTintColor = [GMTheme accent];
        [_upBar addSubview:_upProgress];
        [self.view addSubview:_upBar];
    }
    _upBar.hidden = NO;
    [self.view bringSubviewToFront:_upBar];
    _upLabel.text = text;
    _upProgress.progress = p;
}

/// Gửi tệp có sẵn (tệp đính kèm, hoặc video nếu có `video`). `adopt`: tệp tạm của mình → chuyển vào bộ đệm sau khi gửi.
- (void)sendFileAt:(NSString *)path name:(NSString *)name mime:(NSString *)mime video:(NSDictionary *)video adopt:(BOOL)adopt {
    NSNumber *reply = _compose == GMComposeReply ? GMVal(_target, @"id") : nil;
    if (reply) [self setCompose:GMComposeNormal target:nil];
    NSString *tag = [NSString stringWithFormat:@"up%lld", GMNowMs()];
    NSMutableDictionary *a = [@{@"peer": self.peer, @"path": path, @"name": name, @"tag": tag} mutableCopy];
    if (mime) [a setObject:mime forKey:@"mime"];
    if (video) [a setObject:video forKey:@"video"];
    if (reply) [a setObject:reply forKey:@"reply_to"];
    _upTag = tag;
    _upName = video ? @"video" : [NSString stringWithFormat:@"«%@»", name];
    [self showUpload:[NSString stringWithFormat:@"Đang gửi %@…", _upName] progress:0];
    long long t0 = GMNowMs();
    NSString *peer = self.peer;
    __weak GMChatViewController *ws = self;
    [GMCore call:@"messages.sendFile" args:a done:^(id ok, NSDictionary *err) {
        GMChatViewController *s = ws;
        if (s && [s->_upTag isEqual:tag]) {
            s->_upTag = nil;
            [s showUpload:nil progress:0];
        }
        if (err) {
            [GMTheme toast:GMErrorText(err) in:s.view];
            return;
        }
        GMLog(@"đã gửi tệp %@ (%@) sau %lld ms", GMVal(ok, @"id"), [GMTheme sizeText:[GMVal(GMVal(ok, @"doc"), @"size") doubleValue]],
              GMNowMs() - t0);
        if (adopt) [[GMFiles shared] adopt:path peer:peer msg:GMVal(ok, @"id")];
        else [[GMFiles shared] remember:path peer:peer msg:GMVal(ok, @"id")];  // mở lại từ tệp gốc, khỏi tải
        [s append:ok];
    }];
}

/// Thời lượng + kích thước hiển thị (đã tính xoay) của video.
static NSDictionary *GMVideoInfo(NSURL *url) {
    AVURLAsset *a = [AVURLAsset URLAssetWithURL:url options:nil];
    double dur = CMTimeGetSeconds(a.duration);
    CGSize sz = CGSizeZero;
    NSArray *tracks = [a tracksWithMediaType:AVMediaTypeVideo];
    if (tracks.count) {
        AVAssetTrack *t = [tracks objectAtIndex:0];
        CGRect r = CGRectApplyAffineTransform(CGRectMake(0, 0, t.naturalSize.width, t.naturalSize.height), t.preferredTransform);
        sz = CGSizeMake(fabs(r.size.width), fabs(r.size.height));
    }
    return @{@"duration": @(isnan(dur) ? 0 : dur), @"w": @((int)sz.width), @"h": @((int)sz.height)};
}

/// Video từ thư viện (hoặc tệp video có sẵn): nén sang MP4 (GMVideoCompressor) rồi gửi dạng video kèm thời lượng / kích
/// thước; nén lỗi mà tệp gốc là MP4 / MOV thì gửi nguyên bản.
- (void)sendVideoURL:(NSURL *)url {
    _upTag = nil;
    NSString *out = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"gm-video-%lld.mp4", GMNowMs()]];
    [self showUpload:@"Đang nén video…" progress:0];
    long long t0 = GMNowMs();
    __weak GMChatViewController *ws = self;
    [GMVideoCompressor compress:url to:out
        progress:^(double p) {
            [ws showUpload:[NSString stringWithFormat:@"Đang nén video — %.0f%%", p * 100] progress:p];
        }
        done:^(NSError *err) {
            GMChatViewController *s = ws;
            if (!s) return;
            if (err) {
                GMLog(@"nén video lỗi: %@ %ld — %@", err.domain, (long)err.code,
                      [err.userInfo objectForKey:NSUnderlyingErrorKey] ?: err.localizedDescription);
                [[NSFileManager defaultManager] removeItemAtPath:out error:NULL];
                NSString *ext = url.pathExtension.lowercaseString;
                if ([@[@"mp4", @"m4v", @"mov"] containsObject:ext]) {
                    [s sendFileAt:url.path name:[@"video." stringByAppendingString:ext] mime:GMMimeFor(url.path)
                            video:GMVideoInfo(url) adopt:NO];
                } else {
                    [s showUpload:nil progress:0];
                    [GMTheme toast:@"Không nén được video." in:s.view];
                }
                return;
            }
            NSDictionary *info = GMVideoInfo([NSURL fileURLWithPath:out]);
            double inSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:NULL] fileSize];
            double outSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:out error:NULL] fileSize];
            GMLog(@"nén video %.1f s → %@×%@, %@ → %@ sau %lld ms", [[info objectForKey:@"duration"] doubleValue],
                  [info objectForKey:@"w"], [info objectForKey:@"h"], [GMTheme sizeText:inSize], [GMTheme sizeText:outSize],
                  GMNowMs() - t0);
            NSString *ext = url.pathExtension.lowercaseString;
            if (outSize > inSize * 0.9 && [@[@"mp4", @"m4v", @"mov"] containsObject:ext]) {
                // Video gốc vốn đã nhẹ: gửi bản gốc (nén lại chỉ to ra / mờ đi)
                [[NSFileManager defaultManager] removeItemAtPath:out error:NULL];
                [s sendFileAt:url.path name:[@"video." stringByAppendingString:ext] mime:GMMimeFor(url.path)
                        video:GMVideoInfo(url) adopt:NO];
                return;
            }
            [s sendFileAt:out name:@"video.mp4" mime:@"video/mp4" video:info adopt:YES];
        }];
}

- (void)debugOpenFiles {
    [self openFileBrowser];
}

- (void)debugSendVideo:(NSString *)path {
    [self sendVideoURL:[NSURL fileURLWithPath:path]];
}

#pragma mark Menu khi nhấn giữ

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (BOOL)canEdit:(NSDictionary *)m {
    if (![self outgoing:m] || [GMVal(m, @"service") boolValue] || GMVal(m, @"media")) return NO;
    if ([self.kind isEqual:@"channel"]) return NO;
    return [[NSDate date] timeIntervalSince1970] - [GMVal(m, @"date") doubleValue] < 48 * 3600 || [self isSaved];
}

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    if (!_menuMsg) return NO;
    if ([GMVal(_menuMsg, @"id") integerValue] < 0) return action == @selector(gmCopy:);  // chưa gửi xong
    if (action == @selector(gmReply:)) return !_bar.hidden;
    if (action == @selector(gmCopy:)) return [GMVal(_menuMsg, @"text") length] > 0;
    if (action == @selector(gmForward:)) return ![GMVal(_menuMsg, @"service") boolValue];
    if (action == @selector(gmSave:)) return [self canSave:_menuMsg];
    if (action == @selector(gmEdit:)) return [self canEdit:_menuMsg];
    if (action == @selector(gmDelete:)) return ![self.kind isEqual:@"channel"] || [self outgoing:_menuMsg];
    return NO;
}

- (void)showMenuForRow:(NSInteger)row {
    NSDictionary *r = [_rows objectAtIndex:row];
    if (![[r objectForKey:@"type"] isEqual:@"msg"]) return;
    _menuMsg = [r objectForKey:@"msg"];
    [_input resignFirstResponder];
    [self becomeFirstResponder];
    UIMenuController *mc = [UIMenuController sharedMenuController];
    mc.menuItems = @[
        [[UIMenuItem alloc] initWithTitle:@"Trả lời" action:@selector(gmReply:)],
        [[UIMenuItem alloc] initWithTitle:@"Sao chép" action:@selector(gmCopy:)],
        [[UIMenuItem alloc] initWithTitle:@"Chuyển tiếp" action:@selector(gmForward:)],
        [[UIMenuItem alloc] initWithTitle:@"Lưu vào máy" action:@selector(gmSave:)],
        [[UIMenuItem alloc] initWithTitle:@"Sửa" action:@selector(gmEdit:)],
        [[UIMenuItem alloc] initWithTitle:@"Xoá" action:@selector(gmDelete:)],
    ];
    GMBubbleCell *c = (GMBubbleCell *)[_table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
    CGRect target = c ? [c.bubble convertRect:c.bubble.bounds toView:self.view] : CGRectMake(self.view.bounds.size.width / 2, 100, 1, 1);
    [mc setTargetRect:target inView:self.view];
    [mc setMenuVisible:YES animated:YES];
}

- (void)longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    NSIndexPath *ip = [_table indexPathForRowAtPoint:[g locationInView:_table]];
    if (ip) [self showMenuForRow:ip.row];
}

- (void)menuHidden {
    [UIMenuController sharedMenuController].menuItems = nil;
}

- (void)gmReply:(id)sender {
    [self setCompose:GMComposeReply target:_menuMsg];
}

- (void)gmCopy:(id)sender {
    NSString *text = GMVal(_menuMsg, @"text");
    if (!text.length) return;
    [UIPasteboard generalPasteboard].string = text;
    GMLog(@"đã sao chép tin (%lu ký tự)", (unsigned long)text.length);
}

/// Ảnh, video, GIF, video tròn, ảnh gửi dạng tệp → lưu được vào Thư viện ảnh.
- (BOOL)canSave:(NSDictionary *)m {
    if (GMVal(m, @"photo")) return YES;
    NSDictionary *d = GMVal(m, @"doc");
    if (!d) return NO;
    NSString *kind = GMVal(d, @"kind"), *mime = GMVal(d, @"mime");
    return [@[@"video", @"gif", @"round"] containsObject:kind] || [mime hasPrefix:@"image/"];
}

- (void)gmSave:(id)sender {
    NSDictionary *m = _menuMsg;
    if (GMVal(m, @"photo")) [GMMediaSaver savePhotoOf:self.peer msg:GMVal(m, @"id") in:self.view];
    else [GMMediaSaver saveFileOf:self.peer msg:GMVal(m, @"id") in:self.view];
}

- (void)debugSaveFromBottom:(NSInteger)k {
    NSInteger row = [self rowFromBottom:k];
    if (row < 0) return;
    _menuMsg = [[_rows objectAtIndex:row] objectForKey:@"msg"];
    if ([self canSave:_menuMsg]) [self gmSave:nil];
    else GMLog(@"[thử] tin này không lưu được");
}

- (void)gmForward:(id)sender {
    NSDictionary *m = _menuMsg;
    GMPickChatViewController *p = [[GMPickChatViewController alloc] initWithStyle:UITableViewStylePlain];
    p.myId = self.myId;
    __weak GMChatViewController *weakSelf = self;
    p.picked = ^(NSString *peer, NSString *name) { [weakSelf forward:m to:peer name:name]; };
    [self presentViewController:[[UINavigationController alloc] initWithRootViewController:p] animated:YES completion:nil];
}

- (void)forward:(NSDictionary *)m to:(NSString *)peer name:(NSString *)name {
    [GMCore call:@"messages.forward" args:@{@"from": self.peer, @"to": peer, @"ids": @[GMVal(m, @"id")]}
            done:^(id ok, NSDictionary *err) {
                if (err) {
                    [[[UIAlertView alloc] initWithTitle:@"Không chuyển tiếp được" message:GMErrorText(err) delegate:nil
                                      cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
                    return;
                }
                GMLog(@"đã chuyển tiếp %lu tin", (unsigned long)[ok count]);
                [GMTheme toast:[NSString stringWithFormat:@"Đã chuyển tiếp tới %@", name] in:self.view];
                if ([peer isEqual:self.peer]) {
                    for (NSDictionary *x in ok) [self append:x];
                }
            }];
}

- (void)debugForwardFromBottom:(NSInteger)k to:(NSString *)peer {
    NSInteger r = [self rowFromBottom:k];
    if (r != NSNotFound) [self forward:[[_rows objectAtIndex:r] objectForKey:@"msg"] to:peer name:@"(thử)"];
}

- (void)gmEdit:(id)sender {
    [self setCompose:GMComposeEdit target:_menuMsg];
}

/// Xoá tin: chat riêng → «cho cả hai bên» (tin của mình lẫn của bên kia, như app gốc) hoặc «chỉ ở máy tôi»; nhóm thường → tin
/// của mình xoá được cho mọi người, tin người khác chỉ xoá ở máy mình; kênh / siêu nhóm (-100…) → luôn xoá cho mọi người.
- (void)gmDelete:(id)sender {
    NSDictionary *m = _menuMsg;
    NSMutableArray *revoke = [NSMutableArray array];  // mỗi nút: @YES xoá cho mọi người / @NO chỉ ở máy tôi
    UIActionSheet *s = [[UIActionSheet alloc] initWithTitle:nil delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil
                                          otherButtonTitles:nil];
    if ([self isSaved]) {
        s.destructiveButtonIndex = [s addButtonWithTitle:@"Xoá tin nhắn"];
        [revoke addObject:@YES];
    } else if ([self.peer hasPrefix:@"-100"]) {
        s.destructiveButtonIndex = [s addButtonWithTitle:[self.kind isEqual:@"channel"] ? @"Xoá tin nhắn" : @"Xoá cho mọi người"];
        [revoke addObject:@YES];
    } else if ([self.kind isEqual:@"user"]) {
        s.title = @"Xoá tin nhắn này?";
        s.destructiveButtonIndex = [s addButtonWithTitle:@"Xoá cho cả hai bên"];
        [revoke addObject:@YES];
        [s addButtonWithTitle:@"Xoá chỉ ở máy tôi"];
        [revoke addObject:@NO];
    } else {
        if ([self outgoing:m]) {
            s.destructiveButtonIndex = [s addButtonWithTitle:@"Xoá cho mọi người"];
            [revoke addObject:@YES];
        }
        [s addButtonWithTitle:@"Xoá chỉ ở máy tôi"];
        [revoke addObject:@NO];
    }
    if (s.destructiveButtonIndex < 0 && revoke.count == 1) s.destructiveButtonIndex = 0;
    s.cancelButtonIndex = [s addButtonWithTitle:@"Huỷ"];
    objc_setAssociatedObject(s, "delete", m, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(s, "revoke", revoke, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [s showInView:self.view];
}

- (void)deleteMessage:(NSDictionary *)m revoke:(BOOL)revoke {
    NSNumber *mid = GMVal(m, @"id");
    [GMCore call:@"messages.delete" args:@{@"peer": self.peer, @"ids": @[mid], @"revoke": @(revoke)}
            done:^(id ok, NSDictionary *err) {
        if (err) {
            [[[UIAlertView alloc] initWithTitle:@"Không xoá được" message:GMErrorText(err) delegate:nil cancelButtonTitle:@"OK"
                              otherButtonTitles:nil] show];
            return;
        }
        [self removeIds:@[mid]];
    }];
}

#pragma mark Link, proxy

- (NSArray *)webLinksOf:(NSDictionary *)m {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *link in GMVal(m, @"links")) {
        NSString *l = link;
        NSString *low = l.lowercaseString;
        if ([low hasPrefix:@"tg://"] || [l isEqual:GMVal(m, @"proxy")]) continue;
        if ([low rangeOfString:@"://"].location == NSNotFound) {
            if ([l rangeOfString:@"@"].location != NSNotFound) continue;  // địa chỉ email
            l = [@"http://" stringByAppendingString:l];
        }
        NSURL *u = [NSURL URLWithString:l];
        if (u) [out addObject:u];
    }
    return out;
}

- (void)openProxy:(NSString *)link {
    GMLog(@"mở proxy từ tin nhắn");
    GMProxyViewController *p = [[GMProxyViewController alloc] init];
    p.initialLink = link;
    [self.navigationController pushViewController:p animated:YES];
}

/// Màn Sticker (nút + của bảng sticker): thêm / gỡ bộ; chạm sticker trong bộ đang xem → gửi vào chat này.
- (void)openStickerManager {
    GMStickersViewController *s = [[GMStickersViewController alloc] init];
    __weak GMChatViewController *ws = self;
    s.pick = ^(NSDictionary *doc) {
        [ws dismissViewControllerAnimated:YES completion:nil];
        [ws sendDoc:doc];
    };
    UINavigationController *n = [[UINavigationController alloc] initWithRootViewController:s];
    n.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:n animated:YES completion:nil];
}

/// Xem bộ sticker (chạm sticker trong chat, link t.me/addstickers/…): thêm / gỡ; chạm sticker để gửi vào chat này.
- (void)openStickerSet:(NSDictionary *)set {
    __weak GMChatViewController *ws = self;
    [GMStickerSetViewController present:set from:self pick:_bar.hidden ? nil : ^(NSDictionary *doc) {
        [ws sendDoc:doc];
    }];
}

/// Tên bộ trong link t.me/addstickers/<tên> (hoặc tg://addstickers?set=<tên>), nil nếu không có.
- (NSString *)stickerSetLinkIn:(NSString *)text {
    if (!text.length) return nil;
    static NSRegularExpression *re;
    if (!re) {
        re = [NSRegularExpression regularExpressionWithPattern:@"(?:t(?:elegram)?\\.me/addstickers/|tg://addstickers\\?set=)([A-Za-z0-9_]+)"
                                                       options:NSRegularExpressionCaseInsensitive error:NULL];
    }
    NSTextCheckingResult *r = [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    return r ? [text substringWithRange:[r rangeAtIndex:1]] : nil;
}

- (void)openLinksOf:(NSDictionary *)m {
    NSDictionary *sticker = GMVal(m, @"sticker");
    if ([GMVal(sticker, @"set") isKindOfClass:[NSDictionary class]]) {
        [self openStickerSet:GMVal(sticker, @"set")];
        return;
    }
    NSString *setName = [self stickerSetLinkIn:GMVal(m, @"text")];
    if (setName) {
        [self openStickerSet:@{@"short_name": setName}];
        return;
    }
    if (GMVal(m, @"doc")) {
        [self openDoc:m];
        return;
    }
    if (GMVal(m, @"voice")) {
        [[GMVoicePlayer shared] toggle:self.peer msg:GMVal(m, @"id")];
        return;
    }
    if (GMVal(m, @"photo")) {
        GMPhotoViewController *p = [[GMPhotoViewController alloc] init];
        p.peer = self.peer;
        p.msgId = GMVal(m, @"id");
        p.preview = [GMImages cachedPhotoForPeer:self.peer msg:GMVal(m, @"id") big:NO] ?:
                    [GMImages imageFromBase64:GMVal(GMVal(m, @"photo"), @"thumb")];
        p.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        [self presentViewController:p animated:YES completion:nil];
        return;
    }
    NSString *proxy = GMVal(m, @"proxy");
    if (proxy) {
        [self openProxy:proxy];
        return;
    }
    NSArray *web = [self webLinksOf:m];
    if (web.count == 1) {
        [[UIApplication sharedApplication] openURL:web.firstObject];
    } else if (web.count > 1) {
        UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:@"Mở link" delegate:self cancelButtonTitle:nil
                                             destructiveButtonTitle:nil otherButtonTitles:nil];
        for (NSURL *u in web) [sheet addButtonWithTitle:u.absoluteString];
        sheet.cancelButtonIndex = [sheet addButtonWithTitle:@"Huỷ"];
        objc_setAssociatedObject(sheet, "links", web, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sheet showInView:self.view];
    }
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)i {
    NSDictionary *failed = objc_getAssociatedObject(sheet, "failed");
    if (failed) {
        if (i == sheet.cancelButtonIndex) return;
        NSInteger at = [self indexOf:GMVal(failed, @"id")];
        if (at != NSNotFound) {
            [_msgs removeObjectAtIndex:at];
            [self reloadTable];
        }
        if (i == 0) [self sendText:GMVal(failed, @"text") reply:GMVal(failed, @"reply_to")];
        return;
    }
    NSArray *kinds = objc_getAssociatedObject(sheet, "attach");
    if (kinds) {
        if (i >= 0 && i < (NSInteger)kinds.count) {
            NSInteger k = [[kinds objectAtIndex:i] integerValue];
            if (k < 0) [self openFileBrowser];
            else [self pickFrom:k];
        }
        return;
    }
    NSDictionary *del = objc_getAssociatedObject(sheet, "delete");
    if (del) {
        NSArray *revoke = objc_getAssociatedObject(sheet, "revoke");
        if (i >= 0 && i < (NSInteger)revoke.count) [self deleteMessage:del revoke:[[revoke objectAtIndex:i] boolValue]];
        return;
    }
    NSArray *web = objc_getAssociatedObject(sheet, "links");
    if (i >= 0 && i < (NSInteger)web.count) [[UIApplication sharedApplication] openURL:[web objectAtIndex:i]];
}

#pragma mark Công cụ thử

- (NSInteger)rowFromBottom:(NSInteger)k {
    NSInteger seen = -1;
    for (NSInteger r = _rows.count - 1; r >= 0; r--) {
        if ([[[_rows objectAtIndex:r] objectForKey:@"type"] isEqual:@"msg"] && ++seen == k) return r;
    }
    return NSNotFound;
}

- (void)debugTapFromBottom:(NSInteger)k {
    NSInteger r = [self rowFromBottom:k];
    if (r != NSNotFound) [self openLinksOf:[[_rows objectAtIndex:r] objectForKey:@"msg"]];
}

- (void)debugCopyFromBottom:(NSInteger)k {
    NSInteger r = [self rowFromBottom:k];
    if (r == NSNotFound) return;
    _menuMsg = [[_rows objectAtIndex:r] objectForKey:@"msg"];
    [self gmCopy:nil];
}

- (void)debugDeleteServiceFromBottom:(NSInteger)k {
    NSInteger seen = -1;
    for (NSInteger r = _rows.count - 1; r >= 0; r--) {
        if ([[[_rows objectAtIndex:r] objectForKey:@"type"] isEqual:@"service"] && ++seen == k) {
            [self deleteMessage:[[_rows objectAtIndex:r] objectForKey:@"msg"] revoke:YES];
            return;
        }
    }
}

- (void)debugDeleteFromBottom:(NSInteger)k revoke:(BOOL)revoke {
    NSInteger r = [self rowFromBottom:k];
    if (r != NSNotFound) [self deleteMessage:[[_rows objectAtIndex:r] objectForKey:@"msg"] revoke:revoke];
}

- (void)debugMenuFromBottom:(NSInteger)k {
    NSInteger r = [self rowFromBottom:k];
    if (r != NSNotFound) [self showMenuForRow:r];
}

- (void)debugReplyFromBottom:(NSInteger)k {
    NSInteger r = [self rowFromBottom:k];
    if (r == NSNotFound) return;
    _menuMsg = [[_rows objectAtIndex:r] objectForKey:@"msg"];
    [self gmReply:nil];
}

#pragma mark Bàn phím

- (void)keyboard:(NSNotification *)n {
    NSDictionary *info = n.userInfo;
    CGRect kb = [self.view convertRect:[[info objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue] fromView:nil];
    BOOL show = [n.name isEqual:UIKeyboardWillShowNotification];
    if (show && _stickersOpen) [self closeStickers:NO];  // bàn phím thay chỗ bảng sticker
    if (!show && _stickersOpen) return;                  // bàn phím ẩn vì mở bảng sticker: giữ chỗ cho bảng
    _kbBottom = show ? MAX(0, self.view.bounds.size.height - kb.origin.y) : 0;
    double dur = [[info objectForKey:UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    BOOL wasBottom = [self nearBottom];
    [UIView animateWithDuration:dur animations:^{ [self layoutBars:NO]; }
                     completion:^(BOOL finished) {
                         if (show && wasBottom) [self scrollToBottom:YES];
                     }];
}

#pragma mark Bố cục bong bóng

- (CGFloat)maxBubbleW {
    return floor(_table.bounds.size.width * 0.78);
}

- (NSString *)timeText:(NSDictionary *)m {
    NSString *t = [GMTheme clock:GMVal(m, @"date")];
    if ([GMVal(m, @"edited") boolValue]) t = [@"đã sửa " stringByAppendingString:t];
    if ([GMVal(m, @"failed") boolValue]) return [t stringByAppendingString:@" ⚠️"];
    if ([GMVal(m, @"pending") boolValue]) return [t stringByAppendingString:@" 🕓"];
    if ([GMVal(m, @"out") boolValue] && ![self isSaved]) {
        t = [t stringByAppendingString:[GMVal(m, @"id") integerValue] <= self.readOut ? @" ✓✓" : @" ✓"];
    }
    return t;
}

/// Chữ trong bong bóng + khoảng trống (dấu cách không ngắt) ở cuối để giờ nằm gọn trong dòng cuối, như Telegram.
- (NSString *)bodyText:(NSDictionary *)m font:(UIFont *)f {
    NSString *t = (GMVal(m, @"photo") || GMVal(m, @"doc")) ? GMVal(m, @"text") : [GMTheme preview:m];
    if (!t.length) t = @" ";
    CGFloat tw = [[self timeText:m] sizeWithFont:[UIFont systemFontOfSize:11]].width + kTimeW0;
    CGFloat sp = [@" " sizeWithFont:f].width;
    NSUInteger n = (NSUInteger)ceil(tw / MAX(sp, 1));
    return [NSString stringWithFormat:@"%@ %@", t, [@"" stringByPaddingToLength:n withString:@" " startingAtIndex:0]];
}

/// Cỡ ảnh trong bong bóng: theo tỉ lệ gốc, rộng tối đa ~260 điểm, cao tối đa 320, nhỏ nhất 120.
- (BOOL)isVideo:(NSDictionary *)m {
    NSString *k = GMVal(GMVal(m, @"doc"), @"kind");
    return [k isEqual:@"video"] || [k isEqual:@"gif"] || [k isEqual:@"round"];
}

- (BOOL)isFile:(NSDictionary *)m {
    return GMVal(m, @"doc") && ![self isVideo:m];
}

- (CGSize)photoSize:(NSDictionary *)m {
    NSDictionary *p = GMVal(m, @"photo");
    if (!p && [self isVideo:m]) {
        NSDictionary *d = GMVal(m, @"doc");
        p = @{@"w": [GMVal(d, @"w") intValue] > 0 ? GMVal(d, @"w") : @320, @"h": [GMVal(d, @"h") intValue] > 0 ? GMVal(d, @"h") : @180};
    }
    if (!p) return CGSizeZero;
    CGFloat w = MAX(1, [GMVal(p, @"w") floatValue]), h = MAX(1, [GMVal(p, @"h") floatValue]);
    CGFloat maxW = MIN(260, [self maxBubbleW] - 6 - [GMTheme tailWidth]), maxH = 320;
    CGFloat s = MIN(maxW / w, maxH / h);
    CGFloat dw = MAX(120, floor(w * s)), dh = MAX(80, floor(h * s));
    return CGSizeMake(MIN(dw, maxW), dh);
}

/// Cỡ sticker: tối đa 150 điểm, theo tỉ lệ.
- (CGSize)stickerSize:(NSDictionary *)m {
    NSDictionary *s = GMVal(m, @"sticker");
    CGFloat w = MAX(1, [GMVal(s, @"w") floatValue]), h = MAX(1, [GMVal(s, @"h") floatValue]);
    CGFloat k = MIN(kStickerMax / w, kStickerMax / h);
    return CGSizeMake(floor(w * k), floor(h * k));
}

- (BOOL)showName:(NSDictionary *)r {
    NSDictionary *m = [r objectForKey:@"msg"];
    return [[r objectForKey:@"first"] boolValue] && ![self outgoing:m] && ![self.kind isEqual:@"user"] && [GMVal(m, @"from") length];
}

/// Kích thước chữ trong bong bóng.
- (CGSize)bodySize:(NSDictionary *)m {
    UIFont *f = [UIFont systemFontOfSize:16];
    CGFloat maxW = [self maxBubbleW] - 2 * kPadX - [GMTheme tailWidth];
    CGSize s = [[self bodyText:m font:f] sizeWithFont:f constrainedToSize:CGSizeMake(maxW, 10000) lineBreakMode:GMWordWrap];
    return CGSizeMake(ceil(s.width), ceil(s.height));
}

- (CGFloat)heightOfRow:(NSDictionary *)r {
    NSString *type = [r objectForKey:@"type"];
    if ([type isEqual:@"day"]) return 34;
    NSDictionary *m = [r objectForKey:@"msg"];
    NSString *key = [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%.0f|%d", type, GMVal(m, @"id"), GMVal(m, @"edited"),
                                               [r objectForKey:@"first"], [r objectForKey:@"tail"], _table.bounds.size.width,
                                               (int)self.readOut];
    NSNumber *cached = [_heights objectForKey:key];
    if (cached) return cached.floatValue;
    CGFloat h;
    if ([type isEqual:@"service"]) {
        CGSize s = [GMVal(m, @"text") sizeWithFont:[UIFont boldSystemFontOfSize:13]
                                 constrainedToSize:CGSizeMake(_table.bounds.size.width * 0.8 - 20, 1000)
                                     lineBreakMode:GMWordWrap];
        h = ceil(s.height) + 8 + 10;
    } else if (GMVal(m, @"sticker")) {
        h = [self stickerSize:m].height + 10;
    } else if (GMVal(m, @"voice")) {
        h = kVoiceH + 2 * kPadY + ([self showName:r] ? kNameH : 0) + (GMVal(m, @"reply_to") ? kReplyH : 0) +
            (GMVal(m, @"fwd") ? kFwdH : 0) + ([[r objectForKey:@"tail"] boolValue] ? 6 : 2);
    } else {
        BOOL visual = GMVal(m, @"photo") || [self isVideo:m];
        BOOL caption = (!visual && ![self isFile:m]) || [GMVal(m, @"text") length] > 0;
        CGFloat photoH = visual ? [self photoSize:m].height + (caption ? 4 : 0) - (caption ? 0 : 2 * kPadY - 6) : 0;
        if ([self isFile:m]) photoH = kDocH + (caption ? 4 : kDocTimeH);
        h = (caption ? [self bodySize:m].height : 0) + photoH + 2 * kPadY + ([self showName:r] ? kNameH : 0) +
            (GMVal(m, @"reply_to") ? kReplyH : 0) +
            (GMVal(m, @"fwd") ? kFwdH : 0) +
            (GMVal(m, @"proxy") ? kProxyH : 0) + ([[r objectForKey:@"tail"] boolValue] ? 6 : 2);
    }
    [_heights setObject:@(h) forKey:key];
    return h;
}

#pragma mark Bảng

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _rows.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self heightOfRow:[_rows objectAtIndex:indexPath.row]];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    GMBubbleCell *c = [tableView dequeueReusableCellWithIdentifier:@"m"];
    if (!c) c = [[GMBubbleCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"m"];
    NSDictionary *r = [_rows objectAtIndex:indexPath.row];
    NSString *type = [r objectForKey:@"type"];
    CGFloat W = tableView.bounds.size.width;
    if (![type isEqual:@"msg"]) {
        // Ô dùng lại từ tin sticker: ẩn cả ảnh sticker, giờ của nó và hoạt hình (không thì «giờ» cũ còn nổi trên dòng ngày / tin hệ thống)
        c.bubble.hidden = YES;
        c.sticker.hidden = c.stickerTime.hidden = YES;
        [c.lottie stop];
        c.lottie.hidden = YES;
        c.pill.hidden = NO;
        UIFont *f = c.pill.font;
        NSString *text = [type isEqual:@"day"] ? [GMTheme dayTitle:[r objectForKey:@"date"]] : GMVal([r objectForKey:@"msg"], @"text");
        CGSize s = [text sizeWithFont:f constrainedToSize:CGSizeMake(W * 0.8 - 20, 1000) lineBreakMode:GMWordWrap];
        c.pill.text = text;
        c.pill.frame = CGRectMake(floor((W - s.width - 20) / 2), 6, ceil(s.width) + 20, ceil(s.height) + 8);
        return c;
    }
    c.pill.hidden = YES;
    NSDictionary *m = [r objectForKey:@"msg"];
    c.voiceMsg = GMVal(m, @"voice") ? m : nil;
    NSDictionary *stk = GMVal(m, @"sticker");
    c.sticker.hidden = c.stickerTime.hidden = stk == nil;
    if (stk) {
        c.bubble.hidden = YES;
        CGSize ss = [self stickerSize:m];
        BOOL sout = [self outgoing:m];
        c.sticker.frame = CGRectMake(sout ? W - ss.width - 8 : 8, 4, ss.width, ss.height);
        NSString *skey = [NSString stringWithFormat:@"s%@|%@", self.peer, GMVal(m, @"id")];
        c.photoKey = skey;
        UIImage *cached = [GMImages cachedStickerForPeer:self.peer msg:GMVal(m, @"id")];
        c.sticker.image = cached;
        if (!cached) {
            __weak GMBubbleCell *wc = c;
            [GMImages stickerForPeer:self.peer msg:GMVal(m, @"id") maxPixel:kStickerMax * [UIScreen mainScreen].scale
                                done:^(UIImage *img) {
                                    if ([wc.photoKey isEqual:skey]) wc.sticker.image = img;
                                }];
        }
        [self playTgs:stk msg:m cell:c key:skey];
        NSString *st = [self timeText:m];
        CGFloat stw = [st sizeWithFont:c.stickerTime.font].width + 10;
        c.stickerTime.text = st;
        c.stickerTime.frame = CGRectMake(CGRectGetMaxX(c.sticker.frame) - stw, CGRectGetMaxY(c.sticker.frame) - 17, stw, 17);
        return c;
    }
    c.bubble.hidden = NO;
    BOOL out = [self outgoing:m];
    BOOL tail = [[r objectForKey:@"tail"] boolValue];
    BOOL name = [self showName:r];
    BOOL hasReply = GMVal(m, @"reply_to") != nil;
    NSDictionary *reply = hasReply ? [self msgWithId:GMVal(m, @"reply_to")] : nil;
    NSString *proxy = GMVal(m, @"proxy");
    UIFont *f = c.body.font;
    CGSize s = [self bodySize:m];
    CGFloat t = [GMTheme tailWidth];
    // Bề rộng bong bóng: chữ, tên, trích dẫn, nút proxy
    CGFloat inner = s.width;
    if (name) inner = MAX(inner, MIN([GMVal(m, @"from") sizeWithFont:c.name.font].width, [self maxBubbleW] - 2 * kPadX - t));
    if (hasReply) inner = MAX(inner, MIN(160, [self maxBubbleW] - 2 * kPadX - t));
    NSString *fwd = GMVal(m, @"fwd");
    NSString *fwdText = fwd ? [@"Chuyển tiếp từ " stringByAppendingString:fwd] : nil;
    if (fwd) inner = MAX(inner, MIN([fwdText sizeWithFont:c.fwd.font].width, [self maxBubbleW] - 2 * kPadX - t));
    if (proxy) inner = MAX(inner, 170);
    BOOL isVideo = [self isVideo:m], isFile = [self isFile:m];
    NSDictionary *photo = GMVal(m, @"photo") ?: (isVideo ? GMVal(m, @"doc") : nil);
    BOOL caption = (!photo && !isFile) || [GMVal(m, @"text") length] > 0;
    CGSize ps = [self photoSize:m];
    if (isFile) inner = MAX(caption ? inner : 0, kDocW);
    if (photo) inner = MAX(caption ? inner : 0, ps.width - 2 * kPadX + 6);
    NSDictionary *voice = GMVal(m, @"voice");
    if (voice) {
        caption = NO;
        inner = MAX(kVoiceW, name ? inner : 0);
    }
    CGFloat w = inner + 2 * kPadX + t;
    CGFloat h = [self heightOfRow:r] - (tail ? 6 : 2);
    CGFloat x = out ? W - w - 4 : 4;
    c.bubble.frame = CGRectMake(x, 1, w, h);
    c.bubble.image = [GMTheme bubbleOut:out tail:tail];
    CGFloat cx = kPadX + (out ? 0 : t), cy = kPadY;
    c.name.hidden = !name;
    if (name) {
        c.name.text = GMVal(m, @"from");
        c.name.textColor = [GMTheme colorFor:GMVal(m, @"from_id") ?: @"0"];
        c.name.frame = CGRectMake(cx, cy - 1, inner, kNameH);
        cy += kNameH;
    }
    c.fwd.hidden = fwd == nil;
    if (fwd) {
        c.fwd.text = fwdText;
        c.fwd.textColor = out ? [GMTheme checkColor] : [GMTheme accent];
        c.fwd.frame = CGRectMake(cx, cy - 1, inner, kFwdH);
        cy += kFwdH;
    }
    c.replyBar.hidden = c.replyName.hidden = c.replyText.hidden = !hasReply;
    if (hasReply) {
        UIColor *rc = out ? [GMTheme checkColor] : [GMTheme accent];
        c.replyBar.backgroundColor = rc;
        c.replyBar.frame = CGRectMake(cx, cy + 2, 2, kReplyH - 6);
        c.replyName.textColor = rc;
        c.replyName.text = reply ? ([self outgoing:reply] ? @"Bạn" : (GMVal(reply, @"from") ?: @"Tin nhắn")) : @"Tin nhắn";
        c.replyName.frame = CGRectMake(cx + 8, cy, inner - 8, 17);
        c.replyText.text = reply ? [GMTheme preview:reply] : @"…";
        c.replyText.frame = CGRectMake(cx + 8, cy + 16, inner - 8, 17);
        cy += kReplyH;
    }
    c.photo.hidden = c.photoTime.hidden = photo == nil;
    if (photo) {
        // Ảnh sát mép bong bóng (lề 3), trên cùng nếu không có tên / trích dẫn
        CGFloat px = (out ? 3 : 3 + t), py = (cy == kPadY) ? 3 : cy;
        c.photo.frame = CGRectMake(px, py, ps.width, ps.height);
        NSString *pkey = [NSString stringWithFormat:@"%@|%@", self.peer, GMVal(m, @"id")];
        c.photoKey = pkey;
        UIImage *cached = isVideo ? [GMImages cachedThumbForPeer:self.peer msg:GMVal(m, @"id")]
                                  : [GMImages cachedPhotoForPeer:self.peer msg:GMVal(m, @"id") big:NO];
        c.photo.image = cached ?: [GMImages imageFromBase64:GMVal(photo, @"thumb")];
        if (!cached) {
            __weak GMBubbleCell *wc = c;
            CGFloat maxPx = MAX(ps.width, ps.height) * [UIScreen mainScreen].scale;
            void (^got)(UIImage *) = ^(UIImage *img) {
                if ([wc.photoKey isEqual:pkey]) wc.photo.image = img;
            };
            if (!isVideo) [GMImages photoForPeer:self.peer msg:GMVal(m, @"id") big:NO maxPixel:maxPx done:got];
            else if ([GMVal(photo, @"has_thumb") boolValue]) [GMImages thumbForPeer:self.peer msg:GMVal(m, @"id") maxPixel:maxPx done:got];
        }
        cy = py + ps.height + (caption ? 4 : 0);
    } else {
        c.photoKey = nil;
    }
    c.docMsg = (isVideo || isFile) ? m : nil;
    c.playBadge.hidden = c.videoLen.hidden = !isVideo;
    BOOL gif = isVideo && [GMVal(GMVal(m, @"doc"), @"kind") isEqual:@"gif"];
    if (isVideo) {
        c.playBadge.frame = CGRectMake(CGRectGetMidX(c.photo.frame) - 22, CGRectGetMidY(c.photo.frame) - 22, 44, 44);
        int d = [GMVal(GMVal(m, @"doc"), @"duration") intValue];
        c.videoLen.text = gif ? @"GIF" : [NSString stringWithFormat:@"%d:%02d", d / 60, d % 60];
        CGFloat vw = [c.videoLen.text sizeWithFont:c.videoLen.font].width + 10;
        c.videoLen.frame = CGRectMake(CGRectGetMinX(c.photo.frame) + 6, CGRectGetMinY(c.photo.frame) + 6, vw, 17);
    }
    c.docIcon.hidden = c.docName.hidden = c.docInfo.hidden = !isFile;
    if (isFile) {
        NSDictionary *d = GMVal(m, @"doc");
        NSString *name = [GMVal(d, @"name") length] ? GMVal(d, @"name") : @"Tệp";
        NSString *ext = name.pathExtension.length ? name.pathExtension.uppercaseString : @"TỆP";
        c.docIcon.text = ext.length > 4 ? [ext substringToIndex:4] : ext;
        c.docIcon.backgroundColor = out ? [GMTheme checkColor] : [GMTheme accent];
        c.docIcon.frame = CGRectMake(cx, cy, 44, 44);
        c.docName.text = name;
        c.docName.frame = CGRectMake(cx + 52, cy + 3, inner - 52, 19);
        c.docInfo.textColor = out ? [GMTheme checkColor] : [GMTheme secondaryText];
        c.docInfo.frame = CGRectMake(cx + 52, cy + 23, inner - 52, 17);
        cy += kDocH + (caption ? 4 : kDocTimeH);
    }
    [self refreshDoc:c];
    [self gifFor:c msg:m on:gif];
    c.play.hidden = c.wave.hidden = c.voiceTime.hidden = voice == nil;
    if (voice) {
        UIColor *vc = out ? [GMTheme checkColor] : [GMTheme accent];
        c.play.backgroundColor = vc;
        c.play.frame = CGRectMake(cx, cy + 2, 40, 40);
        c.wave.played = vc;
        c.wave.rest = [vc colorWithAlphaComponent:0.3];
        c.wave.levels = GMVal(voice, @"waveform");
        c.wave.frame = CGRectMake(cx + 48, cy + 4, inner - 52, 22);
        c.voiceTime.textColor = out ? [GMTheme checkColor] : [GMTheme secondaryText];
        c.voiceTime.frame = CGRectMake(cx + 48, cy + 28, 60, 14);
        __weak GMChatViewController *ws = self;
        NSNumber *vid = GMVal(m, @"id");
        c.onPlay = ^{ [[GMVoicePlayer shared] toggle:ws.peer msg:vid]; };
        [self refreshVoice:c];
        cy += kVoiceH;
    } else {
        c.onPlay = nil;
    }
    c.body.hidden = !caption;
    c.body.text = caption ? [self bodyText:m font:f] : nil;
    c.body.textColor = [GMTheme text];
    c.body.frame = CGRectMake(cx, cy, s.width, caption ? s.height : 0);
    if (caption) cy += s.height;
    c.proxy.hidden = proxy == nil;
    __weak GMChatViewController *weakSelf = self;
    c.onProxy = proxy ? ^{ [weakSelf openProxy:proxy]; } : nil;
    if (proxy) c.proxy.frame = CGRectMake(cx, cy + 4, inner, kProxyH - 6);
    // Giờ (+ dấu đã đọc) ở góc dưới phải, trong dòng cuối của chữ (hoặc dưới nút proxy)
    NSString *time = [self timeText:m];
    CGFloat tw = [time sizeWithFont:c.time.font].width;
    c.time.text = time;
    c.time.textColor = out ? [GMTheme checkColor] : [GMTheme secondaryText];
    c.time.frame = CGRectMake(cx + inner - tw, h - kPadY - 13, tw, 13);
    c.time.hidden = photo && !caption && !voice;
    if (photo && !caption) {
        c.photoTime.text = time;
        c.photoTime.frame = CGRectMake(CGRectGetMaxX(c.photo.frame) - tw - 14, CGRectGetMaxY(c.photo.frame) - 22, tw + 10, 17);
    }
    return c;
}

/// Sticker động TGS (mime application/x-tgsticker) và sticker video (video/webm): tải tệp (lõi media.stickerfile, đệm ở
/// media/) rồi phát bằng GMLottieView đè lên ảnh tĩnh; khung đầu hiện thì ẩn ảnh tĩnh. Sticker khác: dừng.
- (void)playTgs:(NSDictionary *)stk msg:(NSDictionary *)m cell:(GMBubbleCell *)c key:(NSString *)skey {
    BOOL tgs = [GMVal(stk, @"mime") isEqual:@"application/x-tgsticker"];
    BOOL webm = [GMVal(stk, @"mime") isEqual:@"video/webm"];
    if (!tgs && !webm) {
        [c.lottie stop];
        c.lottie.hidden = YES;
        return;
    }
    if (!_tgsPaths) _tgsPaths = [NSMutableDictionary dictionary];
    c.lottie.frame = c.sticker.frame;
    c.lottie.hidden = NO;
    __weak GMBubbleCell *wc = c;
    void (^play)(NSString *) = ^(NSString *path) {
        if (![wc.photoKey isEqual:skey]) return;
        wc.lottie.firstFrame = ^{
            if ([wc.photoKey isEqual:skey]) wc.sticker.hidden = YES;
        };
        [wc.lottie playFile:path];
    };
    NSString *path = [_tgsPaths objectForKey:skey];
    if (path) {
        play(path);
        return;
    }
    [c.lottie stop];
    [GMCore call:@"media.stickerfile" args:@{@"peer": self.peer, @"id": GMVal(m, @"id"), @"kind": webm ? @"webm" : @"tgs"}
            done:^(id ok, NSDictionary *err) {
        NSString *p = GMVal(ok, @"path");
        if (!p) {
            GMLog(@"sticker động: không tải được (%@)", GMErrorText(err));
            return;
        }
        [_tgsPaths setObject:p forKey:skey];
        play(p);
    }];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [_input resignFirstResponder];
    NSDictionary *r = [_rows objectAtIndex:indexPath.row];
    if (![[r objectForKey:@"type"] isEqual:@"msg"]) return;
    NSDictionary *m = [r objectForKey:@"msg"];
    if ([GMVal(m, @"failed") boolValue]) [self failedTapped:m];
    else [self openLinksOf:m];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView.contentOffset.y < 60 && _msgs.count) [self loadOlder];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    [_input resignFirstResponder];
}

@end
