#import "GMChatViewController.h"
#import "GMPasscode.h"
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
#import "GMLinks.h"
#import "GMWebAppViewController.h"
#import "GMReactionPicker.h"
#import "GMPollView.h"
#import "GMScheduledViewController.h"
#import "GMMap.h"
#import "GMSuggestView.h"
#import "GMQuickReplies.h"
#import "GMQuickRepliesViewController.h"
#import "GMVietQRViewController.h"
#import "GMContactsViewController.h"
#import "GMAlert.h"
#import "GMAppDelegate.h"
#import "GMChatListViewController.h"
#import "GMContextMenu.h"
#import "GMAttachSheet.h"
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
static const CGFloat kChipH = 24;  // viên cảm xúc dưới tin
static const CGFloat kKbBtnH = 34;  // nút dưới tin của bot
static const CGFloat kPinH = 44;    // thanh «Tin đã ghim» trên đầu màn
static const CGFloat kSchedH = 30;  // thanh «… tin hẹn giờ» trên ô nhập

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
/// Các viên cảm xúc (trong bong bóng; tin sticker: dưới sticker).
@property (nonatomic, strong) UIView *reacts;
/// Nút dưới tin của bot (ngoài bong bóng).
@property (nonatomic, strong) UIView *kbd;
/// Bình chọn trong bong bóng.
@property (nonatomic, strong) GMPollView *poll;
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
        _stickerTime.textColor = [GMTheme pillText];
        _stickerTime.textAlignment = GMAlignCenter;
        _stickerTime.backgroundColor = [GMTheme pillBackground];
        _stickerTime.layer.cornerRadius = 8;
        _stickerTime.clipsToBounds = YES;
        _reacts = [[UIView alloc] init];
        _reacts.hidden = YES;
        [_bubble addSubview:_reacts];
        _kbd = [[UIView alloc] init];
        _kbd.hidden = YES;
        [self.contentView addSubview:_kbd];
        _poll = [[GMPollView alloc] init];
        _poll.hidden = YES;
        [_bubble addSubview:_poll];
        _pill = [self label:[UIFont boldSystemFontOfSize:13] in:self.contentView];
        _pill.textColor = [GMTheme pillText];
        _pill.textAlignment = GMAlignCenter;
        _pill.numberOfLines = 0;
        _pill.backgroundColor = [GMTheme pillBackground];
        _pill.layer.cornerRadius = 11;
        _pill.layer.borderWidth = 0.5;
        _pill.layer.borderColor = ([GMTheme dark] ? [UIColor colorWithWhite:1 alpha:0.14] : [UIColor colorWithWhite:1 alpha:0.9]).CGColor;
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

#pragma mark - Viên cảm xúc

/// Nút có khối xử lý (viên cảm xúc).
@interface GMChip : UIButton
@property (nonatomic, copy) void (^tap)(void);
- (void)fire;
@end

@implementation GMChip
- (void)fire {
    if (self.tap) self.tap();
}
@end

/// Emoji Telegram cho thả (reactions.available) — tải một lần mỗi lần mở app.
static NSArray *gReactChoices;

/// Số gọn như Telegram: 950, 1,2K, 78K, 1,5M (dấu phẩy thập phân).
static NSString *GMCountText(long long n) {
    if (n < 1000) return [NSString stringWithFormat:@"%lld", n];
    double v = n < 1000000 ? n / 1000.0 : n / 1000000.0;
    NSString *unit = n < 1000000 ? @"K" : @"M";
    NSString *s = v < 10 ? [NSString stringWithFormat:@"%.1f", floor(v * 10) / 10] : [NSString stringWithFormat:@"%.0f", floor(v)];
    if ([s hasSuffix:@".0"]) s = [s substringToIndex:s.length - 2];
    return [[s stringByReplacingOccurrencesOfString:@"." withString:@","] stringByAppendingString:unit];
}

static NSString *GMChipTitle(NSDictionary *r) {
    return [NSString stringWithFormat:@"%@ %@", [GMTheme reactionGlyph:GMVal(r, @"e")],
                                      GMCountText([GMVal(r, @"n") longLongValue] ?: 1)];
}

/// Xếp các viên cảm xúc thành dòng trong bề ngang `maxW`; `frames` (có thể nil) nhận khung từng viên. Trả cỡ cả khối.
static CGSize GMLayoutChips(NSArray *reacts, CGFloat maxW, NSMutableArray *frames) {
    if (![reacts isKindOfClass:[NSArray class]] || !reacts.count) return CGSizeZero;
    UIFont *f = [UIFont systemFontOfSize:13];
    CGFloat x = 0, y = 0, w = 0;
    for (NSDictionary *r in reacts) {
        CGFloat cw = MIN(maxW, ceil([GMChipTitle(r) sizeWithFont:f].width) + 18);
        if (x > 0 && x + cw > maxW) {
            x = 0;
            y += kChipH + 4;
        }
        [frames addObject:[NSValue valueWithCGRect:CGRectMake(x, y, cw, kChipH)]];
        x += cw + 4;
        w = MAX(w, x - 4);
    }
    return CGSizeMake(w, y + kChipH);
}

#pragma mark - Màn chat

@interface GMChatViewController () <UIGestureRecognizerDelegate>
@end

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
    NSNumber *_topicNext;            // màn chủ đề: offset_id cho trang tin cũ tiếp theo
    id _allowedReacts;               // cảm xúc chat cho thả (chat.status): @"all" | @"none" | mảng emoji
    UIView *_joinBar;                // thanh nút lớn thay ô nhập: «Tham gia nhóm / kênh», «Bắt đầu» (bot)
    UIButton *_joinBtn;
    BOOL _bigBarOn;
    NSDictionary *_kbdMarkup;        // bàn phím trả lời của bot đang dùng (tin gần nhất có bàn phím)
    UIButton *_kbdBtn;               // nút bật / tắt bàn phím của bot trong ô nhập
    BOOL _kbdOn;
    NSDictionary *_oldKbd;           // bàn phím bot tìm thấy ở tin cũ hơn trang đã tải (bots.keyboard)
    BOOL _oldKbdAsked, _kbdAutoShown;
    BOOL _historyLoaded;
    UIView *_botCard;                // chat bot trống: thẻ «Bot này làm được gì?»
    NSMutableDictionary *_pollSel;   // bình chọn nhiều lựa chọn: mã tin → các lựa chọn đã đánh dấu (chưa bấm «Bỏ phiếu»)
    UIView *_pinBar;                 // thanh «Tin đã ghim»
    UILabel *_pinTitle, *_pinText;
    NSArray *_pins;                  // tin đang ghim, mới → cũ
    NSInteger _pinIdx;               // tin ghim đang hiện trên thanh (chạm → nhảy tới, rồi sang tin cũ hơn)
    BOOL _pinHidden;                 // đã bấm ✕ (ẩn tới lần mở chat sau)
    UIButton *_schedBar;             // «🕓 N tin hẹn giờ ›» (Tin nhắn đã lưu: lời nhắc)
    NSInteger _schedCount;
    GMSuggestView *_suggest;         // gõ «/»: lệnh của bot + tin nhắn nhanh
    NSArray *_commands;              // lệnh của bot (chat bot / các bot trong nhóm): [{c, d}]
    NSDictionary *_botMenu;          // nút «Menu» của bot bên trái ô nhập: {k: commands} | {k: web, t, u}
    UIButton *_menuBtn;
    BOOL _menuOpen;                  // khung gợi ý đang là danh sách lệnh mở từ nút «Menu»
    BOOL _menuCompact;               // đang gõ: nút «Menu» thu lại thành biểu tượng
    UIView *_datePanel;              // chọn ngày giờ hẹn gửi
    UIDatePicker *_datePicker;
    UIButton *_backBtn;              // quay lại + số chưa đọc (viên kính)
    GMContextMenu *_ctxMenu;         // menu giữ tin đang mở
    GMAttachSheet *_attachSheet;     // bảng đính kèm đang mở
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
    // D37: thanh trong suốt — ba viên kính nổi trên hình nền (ghim giấy · ô chữ · mic / gửi)
    // Nút đính kèm (ảnh)
    _attach = [UIButton buttonWithType:UIButtonTypeCustom];
    [_attach setBackgroundImage:[GMTheme glassButton:40 pressed:NO] forState:UIControlStateNormal];
    [_attach setBackgroundImage:[GMTheme glassButton:40 pressed:YES] forState:UIControlStateHighlighted];
    _attach.adjustsImageWhenHighlighted = NO;
    _attach.imageEdgeInsets = UIEdgeInsetsMake(-2, 0, 0, 0);
    [_attach setImage:[GMTheme icon:@"clip" color:[GMTheme text]] forState:UIControlStateNormal];
    [_attach addTarget:self action:@selector(attachTapped) forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:_attach];
    // Ô nhập nhiều dòng (tự giãn tới ~5 dòng, Return xuống dòng — gửi bằng nút «Gửi», như Telegram)
    _barH = kBarH;
    _inputBox = [[UIView alloc] initWithFrame:CGRectMake(8, 6, b.size.width - 76, kInputMinH)];
    _inputBox.backgroundColor = [UIColor clearColor];
    _inputBox.clipsToBounds = YES;
    UIImageView *fbg = [[UIImageView alloc] initWithFrame:_inputBox.bounds];
    fbg.image = [GMTheme fieldImage];  // viên kính bo tròn
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
    [_stickerBtn setImage:[GMTheme icon:@"sticker" color:[GMTheme secondaryText]] forState:UIControlStateNormal];
    [_stickerBtn addTarget:self action:@selector(stickerTapped) forControlEvents:UIControlEventTouchUpInside];
    [_inputBox addSubview:_stickerBtn];
    _send = [UIButton buttonWithType:UIButtonTypeCustom];
    _send.frame = CGRectMake(b.size.width - 44, 4, 40, 40);
    _send.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    // Gửi: tròn xanh mũi tên trắng; ô trống: viên kính có mic (ảnh đặt ở updateSendButton)
    _send.adjustsImageWhenHighlighted = NO;
    // Ô nhập trống: nút thành mic — giữ để ghi âm, thả để gửi, kéo ra ngoài để huỷ
    [_send addTarget:self action:@selector(sendTapped) forControlEvents:UIControlEventTouchUpInside];
    [_send addTarget:self action:@selector(sendDown) forControlEvents:UIControlEventTouchDown];
    [_send addTarget:self action:@selector(sendCancel) forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [_send addTarget:self action:@selector(sendDragExit) forControlEvents:UIControlEventTouchDragExit];
    [_send addTarget:self action:@selector(sendDragEnter) forControlEvents:UIControlEventTouchDragEnter];
    // Có chữ: nhấn giữ «Gửi» → hẹn giờ gửi / nhắc tôi / gửi không âm báo (ô trống thì nút là mic — cử chỉ không bắt đầu)
    UILongPressGestureRecognizer *slp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(sendLongPress:)];
    slp.minimumPressDuration = 0.5;
    slp.delegate = self;
    [_send addGestureRecognizer:slp];
    [_bar addSubview:_send];
    _recLabel = [[UILabel alloc] init];
    _recLabel.font = [UIFont systemFontOfSize:15];
    _recLabel.textColor = [UIColor colorWithRed:0.85 green:0.15 blue:0.12 alpha:1];
    _recLabel.backgroundColor = [UIColor clearColor];  // trên viên kính của ô nhập (ô trống lúc ghi âm)
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
    if (self.left) [self setJoinBar:YES];

    // Nút quay lại viên kính kèm số chưa đọc của các chat khác (bản mẫu D37); iPad: chat là gốc của bên phải — không có
    if (self.navigationController.viewControllers.count > 1 && [self.navigationController.viewControllers objectAtIndex:0] != self) {
        _backBtn = [GMTheme backButton:self action:@selector(gmBack)];
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:_backBtn];
    }
    _titleView = [[GMTitleView alloc] init];
    _titleView.title = self.title;
    _titleView.glass = YES;
    self.navigationItem.titleView = _titleView;
    _titleView.userInteractionEnabled = YES;
    [_titleView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showInfo)]];
    // Ảnh đại diện bên phải thanh trên (như Telegram 4.9): chạm → thông tin chat
    UIButton *av = [UIButton buttonWithType:UIButtonTypeCustom];
    av.frame = CGRectMake(0, 0, 36, 36);
    BOOL saved = [self.peer isEqual:self.myId];
    [av setImage:self.topic ? [GMTheme topicIcon:self.title color:self.topicColor size:36]
                            : [GMTheme avatarFor:self.peer name:saved ? @"★" : (self.title ?: @"") size:36]
        forState:UIControlStateNormal];
    [av addTarget:self action:@selector(showInfo) forControlEvents:UIControlEventTouchUpInside];
    if (!saved && self.photo && !self.topic) {
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
    [nc addObserver:self selector:@selector(becameActive) name:GMPasscodeUnlockedNotification object:nil];
    [nc addObserver:self selector:@selector(keyboard:) name:UIKeyboardWillShowNotification object:nil];
    [nc addObserver:self selector:@selector(keyboard:) name:UIKeyboardWillHideNotification object:nil];
    [nc addObserver:self selector:@selector(menuHidden) name:UIMenuControllerDidHideMenuNotification object:nil];
    [nc addObserver:self selector:@selector(voiceChanged) name:GMVoiceStateNotification object:nil];
    [nc addObserver:self selector:@selector(filesChanged) name:GMFileStateNotification object:nil];
    [self loadOlder];
    [self performSelector:@selector(loadOutbox) withObject:nil afterDelay:0.5];
    [self loadPins];
    [self loadScheduled];
    if (!gReactChoices) {
        [GMCore call:@"reactions.available" args:nil done:^(id ok, NSDictionary *err) {
            if ([ok isKindOfClass:[NSArray class]] && [ok count]) gReactChoices = ok;
        }];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

/// Khung các phần theo kích thước thật của màn (viewDidLoad còn là khổ dọc; iPad nằm ngang / xoay máy đổi sau).
- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    // Xoay máy: lát hình nền thanh trên theo bề ngang mới — chỉ khi màn chat đang ở trên (màn đẩy lên trên nó có nền riêng)
    if (self.navigationController.topViewController == self) [GMTheme styleBarsFor:self animated:NO];
    [self layoutBars:NO];
    // Xoay máy / iPad nằm ngang: xếp lại bong bóng theo bề ngang mới (so với bề ngang đã xếp, không phải bề ngang bảng —
    // co giãn tự động có thể đã đổi bảng trước khi tới đây)
    if (_layoutW != _table.bounds.size.width) {
        _layoutW = _table.bounds.size.width;
        [_table reloadData];
    }
}

/// Số chưa đọc trên nút quay lại: tổng của danh sách (chat đang mở đã về 0).
- (void)updateBackCount {
    if (!_backBtn) return;
    GMAppDelegate *app = (GMAppDelegate *)[UIApplication sharedApplication].delegate;
    [GMTheme setBackButton:_backBtn count:[app.list unreadTotal]];
}

- (void)gmBack {
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateBackCount];
    if (_rows.count) [_table reloadData];  // GIF dừng lúc rời màn → chạy lại
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    for (GMBubbleCell *c in _table.visibleCells) {
        if ([c isKindOfClass:[GMBubbleCell class]]) [c stopGif];
    }
    [_input resignFirstResponder];
    [[UIMenuController sharedMenuController] setMenuVisible:NO animated:NO];  // menu nhấn giữ không theo sang màn khác
    [_ctxMenu dismiss];
    _ctxMenu = nil;
    [_attachSheet dismiss];
    _attachSheet = nil;
}

/// Đặt khung trả lời / ô nhập / bảng theo bàn phím và chế độ soạn.
- (void)layoutBars:(BOOL)keepBottom {
    CGRect b = self.view.bounds;
    BOOL bottom = keepBottom && [self nearBottom];
    CGFloat barH = !_bar.hidden ? _barH : (_bigBarOn ? kBarH : 0);
    CGFloat panelH = (_compose != GMComposeNormal) ? kPanelH : 0;
    CGFloat y = b.size.height - _kbBottom - barH;
    _bar.frame = CGRectMake(0, y, b.size.width, _barH);
    [self updateMenuButton];
    CGFloat mw = [self menuWidth], lx = mw ? mw + 6 : 0;
    _menuBtn.frame = CGRectMake(6, _barH - 39, mw, 30);
    _attach.frame = CGRectMake(4 + lx, _barH - 44, kAttachW, 40);
    _inputBox.frame = CGRectMake(kAttachW + 8 + lx, 6, b.size.width - kAttachW - 56 - lx, _barH - 12);
    _input.frame = CGRectMake(4, 0, _inputBox.bounds.size.width - (_kbdMarkup ? 68 : 36), _inputBox.bounds.size.height);
    _kbdBtn.hidden = !_kbdMarkup;
    _placeholder.frame = CGRectMake(13, 0, MAX(40, _input.frame.size.width - 14), kInputMinH);
    _kbdBtn.frame = CGRectMake(_inputBox.bounds.size.width - 66, _inputBox.bounds.size.height - kInputMinH, 32, kInputMinH);
    _botCard.center = CGPointMake(floor(b.size.width / 2), floor((y - panelH) / 2));
    _stickerBtn.frame = CGRectMake(_inputBox.bounds.size.width - 34, _inputBox.bounds.size.height - kInputMinH, 32, kInputMinH);
    if (_stickersOpen) _stickers.frame = CGRectMake(0, b.size.height - kGMStickerPanelH, b.size.width, kGMStickerPanelH);
    _recLabel.frame = CGRectInset(_inputBox.frame, 10, 2);
    _send.frame = CGRectMake(b.size.width - 44, _barH - 44, 40, 40);
    _panel.hidden = panelH == 0;
    _panel.frame = CGRectMake(0, y - panelH, b.size.width, kPanelH);
    CGFloat pinH = (_pinBar && !_pinBar.hidden) ? kPinH : 0;
    CGFloat schedH = (_schedCount > 0 && !_bar.hidden) ? kSchedH : 0;
    _schedBar.hidden = schedH == 0;
    _schedBar.frame = CGRectMake(0, y - panelH - kSchedH, b.size.width, kSchedH);
    _pinBar.frame = CGRectMake(0, 0, b.size.width, kPinH);
    _table.frame = CGRectMake(0, pinH, b.size.width, y - panelH - pinH - schedH);
    _upBar.frame = CGRectMake(0, pinH, b.size.width, 34);
    if (_suggest && !_suggest.hidden) {
        CGFloat sh = [_suggest wantedHeight];
        _suggest.frame = CGRectMake(0, y - panelH - sh, b.size.width, sh);
    }
    _joinBar.frame = CGRectMake(0, b.size.height - kBarH, b.size.width, kBarH);
    if (bottom) [self scrollToBottom:NO];
}

#pragma mark Tham gia nhóm / kênh

/// Chưa vào nhóm / kênh (mở từ link t.me, kết quả tìm): thanh «Tham gia nhóm / kênh» ở chỗ ô nhập.
- (void)setJoinBar:(BOOL)on {
    self.left = on;
    if (on) [self showBigBar:[self.kind isEqual:@"channel"] ? @"Tham gia kênh" : @"Tham gia nhóm" action:@selector(joinTapped)];
    else [self hideBigBar];
}

/// Thanh một nút lớn ở chỗ ô nhập (Tham gia / Bắt đầu).
- (void)showBigBar:(NSString *)title action:(SEL)action {
    if (!_joinBar) {
        // Khung ban đầu đúng cỡ nút (co giãn tự động tính theo khung này — khung 0 làm nút cao gấp đôi, chữ lệch xuống)
        _joinBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, kBarH)];
        _joinBar.backgroundColor = [UIColor clearColor];
        UIImageView *bg = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 320, kBarH)];
        bg.image = [GMTheme glassBar];
        bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_joinBar addSubview:bg];
        _joinBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        _joinBtn.frame = CGRectMake(0, 0, 320, kBarH);
        _joinBtn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _joinBtn.titleLabel.font = [UIFont boldSystemFontOfSize:17];
        [_joinBtn setTitleColor:[GMTheme accent] forState:UIControlStateNormal];
        [_joinBtn setTitleColor:[GMTheme secondaryText] forState:UIControlStateDisabled];
        [_joinBar addSubview:_joinBtn];
        [self.view addSubview:_joinBar];
    }
    [_joinBtn removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [_joinBtn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [_joinBtn setTitle:title forState:UIControlStateNormal];
    _bigBarOn = YES;
    _joinBar.hidden = NO;
    _bar.hidden = YES;
    [_input resignFirstResponder];
    [self layoutBars:YES];
}

- (void)hideBigBar {
    _bigBarOn = NO;
    _joinBar.hidden = YES;
    _bar.hidden = [self.kind isEqual:@"channel"];
    [self layoutBars:YES];
}

#pragma mark Bot

/// Chat riêng với bot chưa có tin: thẻ mô tả «Bot này làm được gì?» + nút «Bắt đầu» (gửi /start).
- (void)checkBotStart {
    BOOL bot = [GMVal(_status, @"bot") boolValue] && [self.kind isEqual:@"user"];
    if (!bot || !_historyLoaded) return;
    if (_msgs.count) {
        _botCard.hidden = YES;
        return;
    }
    NSString *desc = GMVal(GMVal(_status, @"bot_info"), @"description");
    if (desc.length && !_botCard) {
        UILabel *l = [[UILabel alloc] init];
        l.numberOfLines = 0;
        l.font = [UIFont systemFontOfSize:14];
        l.textColor = [UIColor whiteColor];
        l.backgroundColor = [UIColor clearColor];
        l.textAlignment = GMAlignCenter;
        NSString *t = [NSString stringWithFormat:@"Bot này làm được gì?\n\n%@", desc];
        CGFloat w = MIN(300, self.view.bounds.size.width - 40);
        CGSize s = [t sizeWithFont:l.font constrainedToSize:CGSizeMake(w - 28, 400) lineBreakMode:GMWordWrap];
        l.text = t;
        l.frame = CGRectMake(14, 12, w - 28, ceil(s.height));
        _botCard = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, ceil(s.height) + 24)];
        _botCard.backgroundColor = [GMTheme pillBackground];
        _botCard.layer.cornerRadius = 12;
        [_botCard addSubview:l];
        [self.view insertSubview:_botCard aboveSubview:_table];
    }
    _botCard.hidden = NO;
    if (!_bigBarOn && !self.left) [self showBigBar:@"Bắt đầu" action:@selector(startTapped)];
    [self layoutBars:NO];
}

- (void)startTapped {
    [self hideBigBar];
    _botCard.hidden = YES;
    [self sendText:@"/start" reply:nil];
}

/// Bàn phím trả lời của bot đang dùng: tin gần nhất có bàn phím (bot gỡ bàn phím → không; bàn phím dùng một lần mà mình đã
/// nhắn sau đó → không). Có bàn phím mới từ tin mới nhất → tự hiện (thay bàn phím máy).
- (void)updateBotKeyboard {
    NSDictionary *mk = nil;
    BOOL sawOut = NO, newest = YES, decided = NO;
    BOOL fromNewest = NO;
    for (NSInteger i = (NSInteger)_msgs.count - 1; i >= 0; i--) {
        NSDictionary *m = [_msgs objectAtIndex:i];
        if ([self outgoing:m]) {
            sawOut = YES;
            newest = NO;
            continue;
        }
        NSDictionary *k = GMVal(m, @"keyboard");
        if (![k isKindOfClass:[NSDictionary class]]) {
            newest = NO;
            continue;
        }
        decided = YES;
        if ([GMVal(k, @"hide") boolValue] || ([GMVal(k, @"single") boolValue] && sawOut)) break;
        mk = k;
        fromNewest = newest;
        break;
    }
    // Trang đã tải không có bàn phím nào: chat bot thì dò tin cũ hơn (bot gửi bàn phím một lần rồi gửi nhiều tin báo)
    if (!decided) {
        if (_oldKbd) mk = _oldKbd;
        else if (!_oldKbdAsked && _msgs.count && [GMVal(_status, @"bot") boolValue]) [self findOldKeyboard:sawOut];
    }
    if ((mk == nil && _kbdMarkup == nil) || [mk isEqual:_kbdMarkup]) return;
    _kbdMarkup = mk;
    NSString *ph = GMVal(mk, @"placeholder");
    _placeholder.text = [ph isKindOfClass:[NSString class]] && ph.length ? [GMTheme dropMissingEmoji:ph] : @"Tin nhắn";
    if (!_kbdBtn) {
        _kbdBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        [_kbdBtn addTarget:self action:@selector(toggleBotKeyboard) forControlEvents:UIControlEventTouchUpInside];
        [_inputBox addSubview:_kbdBtn];
    }
    [self layoutBars:NO];
    if (!mk) {
        if (_kbdOn) [self setBotKeyboard:NO];
        return;
    }
    // Bàn phím «luôn hiện» (persistent): tự hiện một lần khi mở chat, như Telegram
    BOOL persistent = [GMVal(mk, @"persistent") boolValue] && !_kbdAutoShown && !_input.text.length;
    BOOL visible = !_bar.hidden && self.navigationController.topViewController == self;
    if (_kbdOn) [self setBotKeyboard:YES];  // bàn phím mới thay bàn phím cũ đang mở
    else if ((fromNewest || persistent) && visible) {
        _kbdAutoShown = YES;
        [self setBotKeyboard:YES];
    } else [_kbdBtn setImage:[GMTheme icon:@"botkeys"] forState:UIControlStateNormal];
}

/// Dò bàn phím bot ở tin cũ hơn trang đã tải (lõi đọc lùi tối đa 400 tin; mỗi lần mở chat dò một lần).
- (void)findOldKeyboard:(BOOL)sawOut {
    _oldKbdAsked = YES;
    NSDictionary *oldest = [_msgs objectAtIndex:0];
    [GMCore call:@"bots.keyboard" args:@{@"peer": self.peer, @"before": GMVal(oldest, @"id") ?: @0, @"out": @(sawOut)}
            done:^(id ok, NSDictionary *err) {
                NSDictionary *k = GMVal(ok, @"keyboard");
                GMLog(@"bàn phím bot ở tin cũ: %@", [k isKindOfClass:[NSDictionary class]] ? GMVal(ok, @"id") : (err ? @"lỗi" : @"không có"));
                if (![k isKindOfClass:[NSDictionary class]]) return;
                _oldKbd = k;
                [self updateBotKeyboard];
            }];
}

- (void)toggleBotKeyboard {
    [self setBotKeyboard:!_kbdOn];
}

- (void)setBotKeyboard:(BOOL)on {
    if (on && !_kbdMarkup) on = NO;
    if (on && _stickersOpen) [self closeStickers:NO];
    _kbdOn = on;
    _input.inputView = on ? [self botKeyboardView] : nil;
    [_kbdBtn setImage:[GMTheme icon:on ? @"keyboard" : @"botkeys"] forState:UIControlStateNormal];
    if ([_input isFirstResponder]) [_input reloadInputViews];
    else if (on) [_input becomeFirstResponder];
}

/// Bàn phím của bot (đặt làm inputView của ô nhập — hiện đúng chỗ bàn phím máy): các hàng phím, cuộn nếu nhiều.
- (UIView *)botKeyboardView {
    NSArray *rows = GMVal(_kbdMarkup, @"rows");
    CGFloat W = self.view.bounds.size.width, rowH = 46;
    CGFloat contentH = rows.count * rowH + 8;
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, MIN(MAX(contentH, 100), 216))];
    v.backgroundColor = [GMTheme dark] ? [UIColor colorWithRed:0.11 green:0.14 blue:0.18 alpha:1]
                                       : [UIColor colorWithRed:0.82 green:0.84 blue:0.87 alpha:1];
    UIScrollView *sc = [[UIScrollView alloc] initWithFrame:v.bounds];
    sc.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    sc.contentSize = CGSizeMake(W, contentH);
    [v addSubview:sc];
    __weak GMChatViewController *ws = self;
    for (NSUInteger r = 0; r < rows.count; r++) {
        NSArray *row = [rows objectAtIndex:r];
        if (![row isKindOfClass:[NSArray class]] || !row.count) continue;
        CGFloat bw = floor((W - 8 - 6 * (row.count - 1)) / row.count);
        for (NSUInteger i = 0; i < row.count; i++) {
            NSDictionary *b = [row objectAtIndex:i];
            GMChip *k = [GMChip buttonWithType:UIButtonTypeCustom];
            k.frame = CGRectMake(4 + i * (bw + 6), 6 + r * rowH, bw, rowH - 8);
            k.backgroundColor = [GMTheme dark] ? [UIColor colorWithRed:0.2 green:0.25 blue:0.31 alpha:1] : [UIColor whiteColor];
            k.layer.cornerRadius = 6;
            k.layer.shadowColor = [UIColor blackColor].CGColor;
            k.layer.shadowOpacity = 0.25;
            k.layer.shadowRadius = 0.5;
            k.layer.shadowOffset = CGSizeMake(0, 1);
            k.titleLabel.font = [UIFont systemFontOfSize:15];
            k.titleLabel.lineBreakMode = GMTailTruncation;
            k.titleEdgeInsets = UIEdgeInsetsMake(0, 4, 0, 4);
            [k setTitle:[GMTheme dropMissingEmoji:GMVal(b, @"t")] forState:UIControlStateNormal];
            [k setTitleColor:[GMTheme text] forState:UIControlStateNormal];
            k.tap = ^{ [ws botKey:b]; };
            [k addTarget:k action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
            [sc addSubview:k];
        }
    }
    return v;
}

/// Chạm phím của bàn phím bot: phím chữ → gửi chữ đó (bàn phím dùng một lần thì đóng).
- (void)botKey:(NSDictionary *)b {
    NSString *k = GMVal(b, @"k");
    if ([k isEqual:@"phone"]) {
        // Phím «gửi số điện thoại» của bot: hỏi trước rồi gửi danh thiếp của mình
        __weak GMChatViewController *ws = self;
        GMAlertShow(@"Chia sẻ số điện thoại?", @"Bot sẽ thấy số điện thoại của bạn.", @"Huỷ", @"Chia sẻ", ^(NSInteger i) {
            if (i == 1) [ws sendMyContact];
        });
        return;
    }
    if ([k isEqual:@"geo"]) {
        [_input resignFirstResponder];
        [self pickLocation];  // phím «gửi vị trí»: chọn vị trí trên bản đồ rồi gửi
        return;
    }
    if ([k isEqual:@"web"]) {
        [self openWebApp:GMVal(b, @"u") bot:nil simple:YES menu:NO title:GMVal(b, @"t")];
        return;
    }
    if (![k isEqual:@"text"]) {
        [GMTheme toast:@"GramMini chưa gửi được loại phím này." in:self.view];
        return;
    }
    if ([GMVal(_kbdMarkup, @"single") boolValue]) {
        [self setBotKeyboard:NO];
        [_input resignFirstResponder];
    }
    [self sendText:GMVal(b, @"t") reply:nil];
}

#pragma mark Nút «Menu» của bot

/// Chat với bot có lệnh / mini app: nút «Menu» bên trái ô nhập (như Telegram): có chữ («Menu» / chữ bot đặt), đang gõ thì thu
/// lại thành biểu tượng ba vạch.
- (void)setBotMenu:(NSDictionary *)menu {
    if (![self.kind isEqual:@"user"]) menu = nil;
    if ((!menu && !_botMenu) || [menu isEqual:_botMenu]) return;
    _botMenu = menu;
    if (menu && !_menuBtn) {
        _menuBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        _menuBtn.backgroundColor = [GMTheme accent];
        _menuBtn.layer.cornerRadius = 15;
        _menuBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        _menuBtn.titleLabel.lineBreakMode = GMTailTruncation;
        _menuBtn.titleEdgeInsets = UIEdgeInsetsMake(0, 2, 0, 2);
        [_menuBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [_menuBtn setTitleColor:[UIColor colorWithWhite:1 alpha:0.55] forState:UIControlStateHighlighted];
        [_menuBtn addTarget:self action:@selector(menuTapped) forControlEvents:UIControlEventTouchUpInside];
        [_bar addSubview:_menuBtn];
    }
    _menuBtn.hidden = menu == nil;
    if (!menu) [self closeBotMenu];
    if (menu) [self drawMenuButton:[self menuShouldCompact]];
    [self layoutBars:NO];
}

/// Thu gọn khi có chữ hoặc đang mở bàn phím máy (như Telegram); bàn phím của bot đang mở thì vẫn đủ chữ.
- (BOOL)menuShouldCompact {
    return _input.text.length > 0 || (_kbBottom > 0 && !_kbdOn && !_stickersOpen);
}

/// Thu gọn / bung nút «Menu» khi cần → YES nếu đổi (bề ngang đổi, cần xếp lại).
- (BOOL)updateMenuButton {
    BOOL compact = [self menuShouldCompact];
    if (!_botMenu || compact == _menuCompact) return NO;
    [self drawMenuButton:compact];
    return YES;
}

- (void)drawMenuButton:(BOOL)compact {
    _menuCompact = compact;
    BOOL web = [GMVal(_botMenu, @"k") isEqual:@"web"];
    NSString *t = compact ? nil : (web ? ([GMTheme dropMissingEmoji:GMVal(_botMenu, @"t")] ?: @"Mở") : @"Menu");
    [_menuBtn setTitle:t forState:UIControlStateNormal];
    [_menuBtn setImage:compact ? [GMTheme icon:@"menu" color:[UIColor whiteColor]] : nil forState:UIControlStateNormal];
}

/// Bề ngang nút «Menu» (0 = không có nút).
- (CGFloat)menuWidth {
    if (!_botMenu || !_menuBtn || _menuBtn.hidden) return 0;
    NSString *t = [_menuBtn titleForState:UIControlStateNormal];
    if (!t.length) return 34;
    CGFloat w = ceil([t sizeWithFont:_menuBtn.titleLabel.font].width) + 22;
    return MAX(34, MIN(w, self.view.bounds.size.width > 400 ? 160 : 96));
}

- (void)menuTapped {
    if ([GMVal(_botMenu, @"k") isEqual:@"web"]) {
        [self openWebApp:GMVal(_botMenu, @"u") bot:nil simple:NO menu:YES title:GMVal(_botMenu, @"t")];
        return;
    }
    if (_menuOpen) {
        [self closeBotMenu];
        return;
    }
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *c in _commands) {
        NSString *cmd = GMVal(c, @"c");
        if (cmd.length < 2) continue;
        [items addObject:@{@"t": cmd, @"d": GMVal(c, @"d") ?: @"", @"kind": @"cmd", @"v": cmd}];
    }
    if (!items.count) {
        [GMTheme toast:@"Bot này chưa có lệnh nào." in:self.view];
        return;
    }
    [self showSuggest:items];
    _menuOpen = YES;
}

- (void)closeBotMenu {
    if (!_menuOpen) return;
    _menuOpen = NO;
    _suggest.hidden = YES;
    [self layoutBars:NO];
}

/// Mini app của bot: xin Telegram link có dữ liệu đăng nhập rồi mở NGAY TRONG APP (GMWebAppViewController — không ra Safari:
/// link có dữ liệu đăng nhập không nằm lại trong lịch sử Safari; kiểm bảo mật 17/11/2026). Lần đầu với mỗi bot: hỏi trước (bot
/// nhận tên + ID Telegram). `bot`: bot gửi tin có nút (nhóm) — nil = chat này.
- (void)openWebApp:(NSString *)url bot:(NSString *)bot simple:(BOOL)simple menu:(BOOL)menu title:(NSString *)title {
    if (![url isKindOfClass:[NSString class]] || !url.length) return;
    NSString *who = [bot isKindOfClass:[NSString class]] && bot.length ? bot : self.peer;
    NSArray *allowed = [[NSUserDefaults standardUserDefaults] arrayForKey:@"webapp.allowed"];
    if (![allowed containsObject:who]) {
        __weak GMChatViewController *ws = self;
        GMAlertShow(@"Mở ứng dụng của bot?",
                    @"Ứng dụng của bot nhận tên và ID Telegram của bạn. Trang viết cho máy mới có thể không chạy trên iOS cũ.",
                    @"Huỷ", @"Mở", ^(NSInteger i) {
                        if (i != 1) return;
                        NSMutableArray *m = [NSMutableArray arrayWithArray:[[NSUserDefaults standardUserDefaults] arrayForKey:@"webapp.allowed"] ?: @[]];
                        if (![m containsObject:who]) [m addObject:who];
                        [[NSUserDefaults standardUserDefaults] setObject:m forKey:@"webapp.allowed"];
                        [ws requestWebApp:url bot:bot simple:simple menu:menu title:title];
                    });
        return;
    }
    [self requestWebApp:url bot:bot simple:simple menu:menu title:title];
}

- (void)requestWebApp:(NSString *)url bot:(NSString *)bot simple:(BOOL)simple menu:(BOOL)menu title:(NSString *)title {
    NSMutableDictionary *a = [@{@"peer": self.peer, @"url": url, @"simple": @(simple), @"menu": @(menu)} mutableCopy];
    if ([bot isKindOfClass:[NSString class]] && bot.length) [a setObject:bot forKey:@"bot"];
    [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
    [GMCore call:@"bots.webview" args:a done:^(id ok, NSDictionary *err) {
        [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
        NSString *u = GMVal(ok, @"url");
        GMLog(@"mini app của bot: %@", u.length ? @"có link" : (err ? [err objectForKey:@"code"] : @"không link"));
        if (![u isKindOfClass:[NSString class]] || !u.length) {
            [GMTheme toast:err ? GMErrorText(err) : @"Không mở được ứng dụng của bot." in:self.view];
            return;
        }
        NSURL *link = [NSURL URLWithString:u];
        if (!link) {
            [GMTheme toast:@"Không mở được ứng dụng của bot." in:self.view];
            return;
        }
        [_input resignFirstResponder];
        [GMWebAppViewController present:link title:[GMTheme dropMissingEmoji:title] from:self];
    }];
}

- (void)debugMenu {
    GMLog(@"[thử] nút Menu: %@ (%@, %.0f pt), %lu lệnh", _botMenu ? GMVal(_botMenu, @"k") : @"không có",
          [_menuBtn titleForState:UIControlStateNormal] ?: @"biểu tượng", [self menuWidth], (unsigned long)_commands.count);
    if (_botMenu) [self menuTapped];
    if (_menuOpen) GMLog(@"[thử] danh sách lệnh: %lu mục", (unsigned long)_suggest.items.count);
}

/// Cao thêm cho hàng có nút dưới tin.
- (CGFloat)kbHeight:(NSDictionary *)m {
    NSArray *rows = GMVal(m, @"buttons");
    if (![rows isKindOfClass:[NSArray class]] || !rows.count) return 0;
    return rows.count * (kKbBtnH + 4) + 2;
}

/// Đặt các nút dưới tin của bot vào vùng `area` (toạ độ trong ô).
- (void)fillButtons:(GMBubbleCell *)c msg:(NSDictionary *)m area:(CGRect)area {
    for (UIView *v in [c.kbd.subviews copy]) [v removeFromSuperview];
    NSArray *rows = GMVal(m, @"buttons");
    c.kbd.hidden = ![rows isKindOfClass:[NSArray class]] || !rows.count;
    if (c.kbd.hidden) return;
    c.kbd.frame = area;
    __weak GMChatViewController *ws = self;
    for (NSUInteger r = 0; r < rows.count; r++) {
        NSArray *row = [rows objectAtIndex:r];
        if (![row isKindOfClass:[NSArray class]] || !row.count) continue;
        CGFloat bw = (area.size.width - 4 * (row.count - 1)) / row.count;
        for (NSUInteger i = 0; i < row.count; i++) {
            NSDictionary *b = [row objectAtIndex:i];
            GMChip *btn = [GMChip buttonWithType:UIButtonTypeCustom];
            btn.frame = CGRectMake(floor(i * (bw + 4)), r * (kKbBtnH + 4), floor(bw), kKbBtnH);
            btn.backgroundColor = [GMTheme pillBackground];
            btn.layer.cornerRadius = 8;
            btn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
            btn.titleLabel.lineBreakMode = GMTailTruncation;
            btn.titleEdgeInsets = UIEdgeInsetsMake(0, 6, 0, 6);
            NSString *t = [GMTheme dropMissingEmoji:GMVal(b, @"t")] ?: @"";
            if ([GMVal(b, @"k") isEqual:@"url"] || [GMVal(b, @"k") isEqual:@"web"]) t = [t stringByAppendingString:@" ↗"];
            [btn setTitle:t forState:UIControlStateNormal];
            [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            btn.tap = ^{ [ws inlineButton:b msg:m]; };
            [btn addTarget:btn action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
            [c.kbd addSubview:btn];
        }
    }
}

/// Chạm nút dưới tin: link → mở (t.me trong app); callback → hỏi bot, hiện câu trả lời; sao chép; hồ sơ người.
- (void)inlineButton:(NSDictionary *)b msg:(NSDictionary *)m {
    NSString *k = GMVal(b, @"k");
    if ([k isEqual:@"url"]) {
        [GMLinks open:GMVal(b, @"u") in:self.view];
    } else if ([k isEqual:@"web"]) {
        [self openWebApp:GMVal(b, @"u") bot:GMVal(m, @"from_id") simple:NO menu:NO title:GMVal(b, @"t")];
    } else if ([k isEqual:@"copy"]) {
        [UIPasteboard generalPasteboard].string = GMVal(b, @"c") ?: @"";
        [GMTheme toast:@"Đã sao chép" in:self.view];
    } else if ([k isEqual:@"user"]) {
        [GMLinks open:[NSString stringWithFormat:@"tg://user?id=%@", GMVal(b, @"id")] in:self.view];
    } else if ([k isEqual:@"cb"]) {
        [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
        [GMCore call:@"messages.botCallback" args:@{@"peer": self.peer, @"id": GMVal(m, @"id"), @"data": GMVal(b, @"d") ?: @""}
                done:^(id ok, NSDictionary *err) {
                    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
                    if (err) {
                        [GMTheme toast:GMErrorText(err) in:self.view];
                        return;
                    }
                    NSString *text = GMVal(ok, @"message"), *url = GMVal(ok, @"url");
                    GMLog(@"nút bot: trả lời %@%@", text.length ? @"có chữ" : @"không chữ", url.length ? @" + link" : @"");
                    if (text.length) {
                        if ([GMVal(ok, @"alert") boolValue]) GMAlertShow(nil, text, @"OK", nil, nil);
                        else [GMTheme toast:text in:self.view];
                    }
                    if (url.length) [GMLinks open:url in:self.view];
                }];
    } else {
        [GMTheme toast:@"GramMini chưa làm được nút này." in:self.view];
    }
}

- (void)debugInlineButtonFromBottom:(NSInteger)k row:(NSInteger)r col:(NSInteger)c {
    NSInteger row = [self rowFromBottom:k];
    if (row == NSNotFound) return;
    NSDictionary *m = [[_rows objectAtIndex:row] objectForKey:@"msg"];
    NSArray *rows = GMVal(m, @"buttons");
    if (r < 0 || r >= (NSInteger)rows.count || c < 0 || c >= (NSInteger)[[rows objectAtIndex:r] count]) {
        GMLog(@"[thử] không có nút %ld/%ld (tin có %lu hàng nút)", (long)r, (long)c, (unsigned long)rows.count);
        return;
    }
    [self inlineButton:[[rows objectAtIndex:r] objectAtIndex:c] msg:m];
}

- (void)debugBotKey:(NSInteger)i {
    NSInteger n = 0;
    for (NSArray *row in GMVal(_kbdMarkup, @"rows")) {
        for (NSDictionary *b in row) {
            if (n++ == i) {
                [self botKey:b];
                return;
            }
        }
    }
    GMLog(@"[thử] bàn phím bot: không có phím %ld (%@)", (long)i, _kbdMarkup ? @"có bàn phím" : @"không có bàn phím");
}

- (void)debugToggleBotKeyboard {
    [self toggleBotKeyboard];
}

#pragma mark Hẹn giờ gửi / nhắc tôi

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (g.view == _send) {
        NSString *t = [_input.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        return t.length > 0 && !_recorder && _compose != GMComposeEdit && ![self micMode];
    }
    return YES;
}

- (void)sendLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) [self showScheduleSheet];
}

/// Mốc giờ hôm nay + `days` ngày, lúc `hour`:00 (giờ máy).
- (NSTimeInterval)dayOffset:(NSInteger)days hour:(NSInteger)hour {
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *c = [cal components:NSYearCalendarUnit | NSMonthCalendarUnit | NSDayCalendarUnit fromDate:[NSDate date]];
    c.day += days;
    c.hour = hour;
    return [[cal dateFromComponents:c] timeIntervalSince1970];
}

/// Nhấn giữ «Gửi»: hẹn giờ gửi tin đang soạn (Tin nhắn đã lưu: «Nhắc tôi» — tới giờ Telegram gửi tin, máy báo như tin mới) hoặc gửi
/// không âm báo.
- (void)showScheduleSheet {
    NSString *t = [_input.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!t.length) return;
    BOOL saved = [self isSaved];
    NSMutableArray *times = [NSMutableArray array];  // giờ Unix; -1 = chọn ngày giờ; -2 = gửi không âm báo
    UIActionSheet *s = [[UIActionSheet alloc] initWithTitle:saved ? @"Nhắc tôi" : @"Hẹn giờ gửi" delegate:self cancelButtonTitle:nil
                                     destructiveButtonTitle:nil otherButtonTitles:nil];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSArray *quick = @[@[@"Sau 30 phút", @(now + 1800)], @[@"Sau 1 giờ", @(now + 3600)], @[@"Sau 3 giờ", @(now + 3 * 3600)]];
    for (NSArray *q in quick) {
        [s addButtonWithTitle:[q objectAtIndex:0]];
        [times addObject:[q objectAtIndex:1]];
    }
    NSTimeInterval tonight = [self dayOffset:0 hour:20];
    if (tonight > now + 600) {
        [s addButtonWithTitle:@"Tối nay lúc 20:00"];
        [times addObject:@(tonight)];
    }
    [s addButtonWithTitle:@"Sáng mai lúc 8:00"];
    [times addObject:@([self dayOffset:1 hour:8])];
    [s addButtonWithTitle:@"Chọn ngày giờ…"];
    [times addObject:@(-1)];
    if (!saved) {
        [s addButtonWithTitle:@"Gửi không âm báo"];
        [times addObject:@(-2)];
    }
    s.cancelButtonIndex = [s addButtonWithTitle:@"Huỷ"];
    objc_setAssociatedObject(s, "sched", times, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [s showInView:self.view];
}

/// Gửi chữ đang soạn: `at` > 0 → hẹn giờ (máy chủ giữ tin, tới giờ mới gửi); `silent` → gửi không âm báo.
- (void)sendComposed:(NSTimeInterval)at silent:(BOOL)silent {
    NSString *t = [_input.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!t.length) return;
    NSNumber *reply = _compose == GMComposeReply ? GMVal(_target, @"id") : nil;
    _input.text = @"";
    [self textViewDidChange:_input];
    [self setCompose:GMComposeNormal target:nil];
    if (at <= 0) {
        [self sendText:t reply:reply silent:silent];
        return;
    }
    NSMutableDictionary *args = [@{@"peer": self.peer, @"text": t, @"schedule": @((long long)at)} mutableCopy];
    if (reply) [args setObject:reply forKey:@"reply_to"];
    if (self.topic) [args setObject:self.topic forKey:@"topic"];
    [GMCore call:@"messages.send" args:args done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.view];
            if (!_input.text.length) {
                _input.text = t;
                [self textViewDidChange:_input];
            }
            return;
        }
        GMLog(@"đã hẹn giờ một tin");
        [GMTheme toast:[NSString stringWithFormat:@"%@ %@", [self isSaved] ? @"Sẽ nhắc lúc" : @"Sẽ gửi lúc", GMScheduleText(at)]
                    in:self.view];
        [self loadScheduled];
    }];
}

- (void)showDatePicker {
    [_input resignFirstResponder];
    [_datePanel removeFromSuperview];
    CGRect b = self.view.bounds;
    UIView *dim = [[UIView alloc] initWithFrame:b];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.3];
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(0, b.size.height - 260, b.size.width, 260)];
    panel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    panel.backgroundColor = [GMTheme dark] ? [UIColor colorWithWhite:0.12 alpha:1] : [UIColor whiteColor];
    [dim addSubview:panel];
    UIToolbar *tb = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, b.size.width, 44)];
    tb.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    if ([GMTheme dark]) tb.barStyle = UIBarStyleBlack;
    tb.items = @[
        [[UIBarButtonItem alloc] initWithTitle:@"Huỷ" style:UIBarButtonItemStyleBordered target:self action:@selector(dismissDatePicker)],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:NULL],
        [[UIBarButtonItem alloc] initWithTitle:[self isSaved] ? @"Đặt lời nhắc" : @"Hẹn giờ" style:UIBarButtonItemStyleDone target:self
                                        action:@selector(confirmDatePicker)],
    ];
    [panel addSubview:tb];
    UIDatePicker *dp = [[UIDatePicker alloc] initWithFrame:CGRectMake(floor((b.size.width - 320) / 2), 44, 320, 216)];
    dp.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    dp.datePickerMode = UIDatePickerModeDateAndTime;
    dp.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"vi_VN"];
    dp.minimumDate = [NSDate dateWithTimeIntervalSinceNow:60];
    dp.maximumDate = [NSDate dateWithTimeIntervalSinceNow:364 * 86400];
    dp.date = [NSDate dateWithTimeIntervalSinceNow:3600];
    [panel addSubview:dp];
    [self.view addSubview:dim];
    _datePanel = dim;
    _datePicker = dp;
}

- (void)dismissDatePicker {
    [_datePanel removeFromSuperview];
    _datePanel = nil;
    _datePicker = nil;
}

- (void)confirmDatePicker {
    NSTimeInterval at = _datePicker.date.timeIntervalSince1970;
    [self dismissDatePicker];
    [self sendComposed:at silent:NO];
}

/// Số tin hẹn giờ của chat → thanh «🕓 N tin hẹn giờ ›» trên ô nhập.
- (void)loadScheduled {
    if ([self.kind isEqual:@"channel"] || self.left) return;
    [GMCore call:@"messages.scheduled" args:@{@"peer": self.peer} done:^(id ok, NSDictionary *err) {
        if (![ok isKindOfClass:[NSArray class]]) return;
        NSInteger n = 0;
        for (NSDictionary *m in ok) {
            if ([self inTopic:m]) n++;
        }
        [self setScheduledCount:n];
    }];
}

- (void)setScheduledCount:(NSInteger)n {
    if (n > 0 && !_schedBar) {
        _schedBar = [UIButton buttonWithType:UIButtonTypeCustom];
        [_schedBar setBackgroundImage:[GMTheme glassBar] forState:UIControlStateNormal];
        _schedBar.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        [_schedBar setTitleColor:[GMTheme accent] forState:UIControlStateNormal];
        [_schedBar addTarget:self action:@selector(openScheduled) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:_schedBar];
    }
    BOOL changed = (n > 0) != (_schedCount > 0);
    _schedCount = n;
    [_schedBar setTitle:[NSString stringWithFormat:@"🕓 %ld %@ ›", (long)n, [self isSaved] ? @"lời nhắc" : @"tin hẹn giờ"]
               forState:UIControlStateNormal];
    if (changed) [self layoutBars:YES];
}

- (void)openScheduled {
    GMScheduledViewController *s = [[GMScheduledViewController alloc] init];
    s.peer = self.peer;
    s.saved = [self isSaved];
    __weak GMChatViewController *ws = self;
    s.changed = ^(NSInteger count) { [ws setScheduledCount:count]; };
    [self.navigationController pushViewController:s animated:YES];
}

- (void)debugScheduleSheet {
    [self showScheduleSheet];
}

- (void)debugOpenScheduled {
    [self openScheduled];
}

#pragma mark Danh thiếp

- (NSString *)contactName:(NSDictionary *)card {
    return [[NSString stringWithFormat:@"%@ %@", GMVal(card, @"first") ?: @"", GMVal(card, @"last") ?: @""]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

/// Chạm danh thiếp: nhắn tin (người có Telegram), gọi (iPhone), chép số.
- (void)contactTapped:(NSDictionary *)card {
    NSString *name = [self contactName:card];
    NSString *phone = [GMVal(card, @"phone") length] ? [@"+" stringByAppendingString:[GMVal(card, @"phone") stringByReplacingOccurrencesOfString:@"+" withString:@""]] : @"";
    UIActionSheet *s = [[UIActionSheet alloc] initWithTitle:[NSString stringWithFormat:@"%@\n%@", name, phone] delegate:self
                                          cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
    NSMutableArray *acts = [NSMutableArray array];
    if (GMVal(card, @"user")) {
        [s addButtonWithTitle:@"Nhắn tin"];
        [acts addObject:@"chat"];
    }
    if (phone.length && [[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"tel:0"]]) {
        [s addButtonWithTitle:@"Gọi"];
        [acts addObject:@"call"];
    }
    if (phone.length) {
        [s addButtonWithTitle:@"Chép số"];
        [acts addObject:@"copy"];
    }
    s.cancelButtonIndex = [s addButtonWithTitle:@"Huỷ"];
    objc_setAssociatedObject(s, "card", acts, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(s, "cardData", card, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [s showInView:self.view];
}

/// Đính kèm → «Danh thiếp»: chọn một người trong danh bạ → gửi tên + số của họ.
- (void)pickContactCard {
    GMContactsViewController *c = [[GMContactsViewController alloc] initWithStyle:UITableViewStylePlain];
    c.myId = self.myId;
    c.title = @"Gửi danh thiếp";
    __weak GMChatViewController *ws = self;
    c.pick = ^(NSDictionary *p) {
        GMChatViewController *s = ws;
        if (!s) return;
        [s.navigationController popToViewController:s animated:YES];
        if (![GMVal(p, @"kind") ?: @"user" isEqual:@"user"]) return;
        if (![GMVal(p, @"phone") length]) {
            [GMTheme toast:@"Người này ẩn số điện thoại — không gửi danh thiếp được." in:s.view];
            return;
        }
        NSString *name = GMVal(p, @"name") ?: @"";
        [s sendContactPhone:GMVal(p, @"phone") first:name last:nil];
    };
    [self.navigationController pushViewController:c animated:YES];
}

- (void)sendContactPhone:(NSString *)phone first:(NSString *)first last:(NSString *)last {
    NSMutableDictionary *args = [@{@"peer": self.peer, @"phone": phone ?: @"", @"first": first ?: @"", @"last": last ?: @""} mutableCopy];
    if (self.topic) [args setObject:self.topic forKey:@"topic"];
    [GMCore call:@"messages.sendContact" args:args done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.view];
            return;
        }
        GMLog(@"đã gửi danh thiếp %@", GMVal(ok, @"id"));
        [self append:ok];
    }];
}

/// Danh thiếp của chính mình (phím «gửi số điện thoại» của bot).
- (void)sendMyContact {
    [GMCore call:@"account.get" args:nil done:^(id ok, NSDictionary *err) {
        if (![GMVal(ok, @"phone") length]) {
            [GMTheme toast:err ? GMErrorText(err) : @"Không đọc được số của bạn." in:self.view];
            return;
        }
        [self sendContactPhone:GMVal(ok, @"phone") first:GMVal(ok, @"first") last:GMVal(ok, @"last")];
    }];
}

- (void)debugSendContact:(NSString *)arg {
    NSRange sp = [arg rangeOfString:@" "];
    if (sp.location == NSNotFound) return;
    [self sendContactPhone:[arg substringToIndex:sp.location] first:[arg substringFromIndex:sp.location + 1] last:nil];
}

#pragma mark Mã QR chuyển khoản

- (void)openVietQR {
    GMVietQRViewController *q = [[GMVietQRViewController alloc] init];
    __weak GMChatViewController *ws = self;
    q.send = ^(UIImage *card, NSString *caption) { [ws sendImage:card caption:caption]; };
    [self.navigationController pushViewController:q animated:YES];
}

- (void)debugOpenVietQR {
    [self openVietQR];
}

#pragma mark Vị trí

/// Đính kèm → «Vị trí»: màn bản đồ chọn chỗ (định vị máy / kéo bản đồ) → gửi tin vị trí.
- (void)pickLocation {
    __weak GMChatViewController *ws = self;
    GMMapViewController *m = [[GMMapViewController alloc] initPickerWithDone:^(double lat, double lng) { [ws sendGeoLat:lat lng:lng]; }];
    [self.navigationController pushViewController:m animated:YES];
}

- (void)sendGeoLat:(double)lat lng:(double)lng {
    NSNumber *reply = _compose == GMComposeReply ? GMVal(_target, @"id") : nil;
    if (reply) [self setCompose:GMComposeNormal target:nil];
    NSMutableDictionary *args = [@{@"peer": self.peer, @"lat": @(lat), @"lng": @(lng)} mutableCopy];
    if (reply) [args setObject:reply forKey:@"reply_to"];
    if (self.topic) [args setObject:self.topic forKey:@"topic"];
    [GMCore call:@"messages.sendGeo" args:args done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.view];
            return;
        }
        GMLog(@"đã gửi vị trí %@", GMVal(ok, @"id"));
        [self append:ok];
    }];
}

- (void)debugSendGeo:(NSString *)arg {
    NSArray *p = [arg componentsSeparatedByString:@" "];
    if (p.count == 2) [self sendGeoLat:[[p objectAtIndex:0] doubleValue] lng:[[p objectAtIndex:1] doubleValue]];
}

#pragma mark Tin ghim

/// Tải các tin đang ghim (màn chủ đề: chỉ tin của chủ đề này) rồi hiện thanh trên đầu.
- (void)loadPins {
    [GMCore call:@"messages.pinned" args:@{@"peer": self.peer} done:^(id ok, NSDictionary *err) {
        if (![ok isKindOfClass:[NSArray class]]) return;
        NSMutableArray *pins = [NSMutableArray array];
        for (NSDictionary *m in ok) {
            if ([self inTopic:m]) [pins addObject:m];
        }
        NSNumber *cur = _pinIdx < (NSInteger)_pins.count ? GMVal([_pins objectAtIndex:_pinIdx], @"id") : nil;
        _pins = pins;
        _pinIdx = 0;
        for (NSUInteger i = 0; cur && i < pins.count; i++) {
            if ([GMVal([pins objectAtIndex:i], @"id") isEqual:cur]) _pinIdx = (NSInteger)i;
        }
        GMLog(@"tin ghim: %lu", (unsigned long)pins.count);
        [self updatePinBar];
    }];
}

- (void)updatePinBar {
    BOOL show = _pins.count > 0 && !_pinHidden;
    if (show && !_pinBar) {
        _pinBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, kPinH)];
        _pinBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        UIImageView *bg = [[UIImageView alloc] initWithFrame:_pinBar.bounds];
        bg.image = [GMTheme glassBar];
        bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_pinBar addSubview:bg];
        UIView *line = [[UIView alloc] initWithFrame:CGRectMake(10, 7, 2, kPinH - 14)];
        line.backgroundColor = [GMTheme accent];
        [_pinBar addSubview:line];
        _pinTitle = [[UILabel alloc] initWithFrame:CGRectMake(20, 5, _pinBar.bounds.size.width - 64, 17)];
        _pinTitle.font = [UIFont boldSystemFontOfSize:14];
        _pinTitle.textColor = [GMTheme accent];
        _pinTitle.backgroundColor = [UIColor clearColor];
        _pinTitle.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [_pinBar addSubview:_pinTitle];
        _pinText = [[UILabel alloc] initWithFrame:CGRectMake(20, 22, _pinBar.bounds.size.width - 64, 17)];
        _pinText.font = [UIFont systemFontOfSize:14];
        _pinText.textColor = [GMTheme text];
        _pinText.backgroundColor = [UIColor clearColor];
        _pinText.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [_pinBar addSubview:_pinText];
        UIButton *tap = [UIButton buttonWithType:UIButtonTypeCustom];
        tap.frame = CGRectMake(0, 0, _pinBar.bounds.size.width - 44, kPinH);
        tap.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [tap addTarget:self action:@selector(pinTapped) forControlEvents:UIControlEventTouchUpInside];
        [_pinBar addSubview:tap];
        UIButton *x = [UIButton buttonWithType:UIButtonTypeCustom];
        x.frame = CGRectMake(_pinBar.bounds.size.width - 44, 0, 44, kPinH);
        x.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [x setTitle:@"✕" forState:UIControlStateNormal];
        [x setTitleColor:[GMTheme secondaryText] forState:UIControlStateNormal];
        x.titleLabel.font = [UIFont systemFontOfSize:18];
        [x addTarget:self action:@selector(pinClosed) forControlEvents:UIControlEventTouchUpInside];
        [_pinBar addSubview:x];
        [self.view insertSubview:_pinBar aboveSubview:_table];
    }
    BOOL wasShown = _pinBar && !_pinBar.hidden;
    _pinBar.hidden = !show;
    if (show) {
        NSDictionary *m = [_pins objectAtIndex:MIN(_pinIdx, (NSInteger)_pins.count - 1)];
        _pinTitle.text = _pins.count > 1 ? [NSString stringWithFormat:@"Tin đã ghim %ld/%lu", (long)_pinIdx + 1, (unsigned long)_pins.count]
                                         : @"Tin đã ghim";
        _pinText.text = [[GMTheme preview:m] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    }
    if (wasShown != show) [self layoutBars:YES];
}

/// Chạm thanh ghim: nhảy tới tin đang hiện, rồi chuyển thanh sang tin ghim cũ hơn (hết thì quay về tin mới nhất).
- (void)pinTapped {
    if (!_pins.count) return;
    NSDictionary *m = [_pins objectAtIndex:MIN(_pinIdx, (NSInteger)_pins.count - 1)];
    self.jumpTo = GMVal(m, @"id");
    [self tryJump];
    _pinIdx = (_pinIdx + 1) % (NSInteger)_pins.count;
    [self updatePinBar];
}

- (void)pinClosed {
    _pinHidden = YES;
    [self updatePinBar];
}

/// Đánh dấu ghim / bỏ ghim trên các tin đã tải (menu «Ghim / Bỏ ghim» đúng chữ).
- (void)markPinned:(NSArray *)ids on:(BOOL)on {
    for (NSUInteger i = 0; i < _msgs.count; i++) {
        NSDictionary *m = [_msgs objectAtIndex:i];
        if (![ids containsObject:GMVal(m, @"id")]) continue;
        NSMutableDictionary *x = [m mutableCopy];
        [x setObject:@(on) forKey:@"pinned"];
        [_msgs replaceObjectAtIndex:i withObject:x];
    }
    [self rebuildRows];
}

- (void)gmPin:(id)sender {
    [self pinMessage:_menuMsg];
}

- (void)pinMessage:(NSDictionary *)m {
    BOOL unpin = [GMVal(m, @"pinned") boolValue];
    NSNumber *mid = GMVal(m, @"id");
    [GMCore call:@"messages.pin" args:@{@"peer": self.peer, @"id": mid, @"unpin": @(unpin)} done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.view];
            return;
        }
        GMLog(@"%@ tin %@", unpin ? @"đã bỏ ghim" : @"đã ghim", mid);
        [GMTheme toast:unpin ? @"Đã bỏ ghim" : @"Đã ghim" in:self.view];
        [self markPinned:@[mid] on:!unpin];
        _pinHidden = NO;
        [self loadPins];
    }];
}

- (void)debugPinFromBottom:(NSInteger)k {
    NSInteger r = [self rowFromBottom:k];
    if (r != NSNotFound) [self pinMessage:[[_rows objectAtIndex:r] objectForKey:@"msg"]];
}

- (void)debugPinTap {
    [self pinTapped];
}

#pragma mark Bình chọn

- (CGFloat)pollW {
    return MIN([self maxBubbleW] - 2 * kPadX - [GMTheme tailWidth], 260);
}

- (NSString *)pollSig:(NSDictionary *)m {
    NSDictionary *p = GMVal(m, @"poll");
    if (!p) return @"";
    NSMutableString *s = [NSMutableString stringWithFormat:@"%@%@", GMVal(GMVal(p, @"results"), @"total"), GMVal(p, @"closed")];
    for (NSDictionary *v in GMVal(GMVal(p, @"results"), @"voters")) {
        if ([GMVal(v, @"chosen") boolValue]) [s appendString:GMVal(v, @"o") ?: @""];
    }
    return s;
}

/// Bỏ phiếu (mảng mã lựa chọn; rỗng = rút phiếu) rồi cập nhật kết quả từ phản hồi.
- (void)vote:(NSArray *)options msg:(NSNumber *)msgId {
    [_pollSel removeObjectForKey:msgId];
    NSString *pid = GMVal(GMVal([self msgWithId:msgId], @"poll"), @"id");
    [GMCore call:@"messages.vote" args:@{@"peer": self.peer, @"id": msgId, @"options": options ?: @[]} done:^(id ok, NSDictionary *err) {
        if (err) {
            [GMTheme toast:GMErrorText(err) in:self.view];
            [self reloadTable];
            return;
        }
        GMLog(@"bình chọn: %@", options.count ? @"đã bỏ phiếu" : @"đã rút phiếu");
        NSMutableDictionary *u = [ok isKindOfClass:[NSDictionary class]] ? [ok mutableCopy] : [NSMutableDictionary dictionary];
        if (!GMVal(u, @"poll_id") && pid) [u setObject:pid forKey:@"poll_id"];
        if (GMVal(u, @"results")) [self applyPollUpdate:u];
    }];
}

- (void)togglePollOption:(NSString *)o msg:(NSNumber *)msgId {
    if (!_pollSel) _pollSel = [NSMutableDictionary dictionary];
    NSMutableSet *s = [_pollSel objectForKey:msgId] ?: [NSMutableSet set];
    if ([s containsObject:o]) [s removeObject:o];
    else [s addObject:o];
    [_pollSel setObject:s forKey:msgId];
    [_table reloadData];
}

/// Cập nhật bình chọn (sự kiện msg.poll hoặc phản hồi bỏ phiếu): tìm tin theo mã bình chọn, thay kết quả. Kết quả «min» (người
/// khác vừa bỏ phiếu) không kèm lựa chọn của mình → giữ dấu ✓ cũ.
- (void)applyPollUpdate:(NSDictionary *)u {
    NSString *pid = [GMVal(u, @"poll_id") description];
    for (NSUInteger i = 0; i < _msgs.count; i++) {
        NSDictionary *m = [_msgs objectAtIndex:i];
        NSDictionary *p = GMVal(m, @"poll");
        if (!p || ![[GMVal(p, @"id") description] isEqual:pid]) continue;
        NSMutableDictionary *np = [(GMVal(u, @"poll") ?: p) mutableCopy];
        NSDictionary *res = GMVal(u, @"results");
        if (res) {
            NSMutableDictionary *nr = [res mutableCopy];
            if ([GMVal(res, @"min") boolValue]) {
                NSMutableSet *mine = [NSMutableSet set];
                for (NSDictionary *v in GMVal(GMVal(p, @"results"), @"voters")) {
                    if ([GMVal(v, @"chosen") boolValue] && GMVal(v, @"o")) [mine addObject:GMVal(v, @"o")];
                }
                NSMutableArray *vs = [NSMutableArray array];
                for (NSDictionary *v in GMVal(res, @"voters")) {
                    NSMutableDictionary *x = [v mutableCopy];
                    if ([mine containsObject:GMVal(v, @"o")]) [x setObject:@YES forKey:@"chosen"];
                    [vs addObject:x];
                }
                [nr setObject:vs forKey:@"voters"];
            }
            [np setObject:nr forKey:@"results"];
        }
        NSMutableDictionary *nm = [m mutableCopy];
        [nm setObject:np forKey:@"poll"];
        [_msgs replaceObjectAtIndex:i withObject:nm];
        BOOL bottom = [self nearBottom];
        [self reloadTable];
        if (bottom) [self scrollToBottom:NO];
        return;
    }
}

/// Công cụ thử: gửi bình chọn «câu hỏi|lựa chọn 1|lựa chọn 2…» (thêm «|*» ở cuối = nhiều lựa chọn).
- (void)debugSendPoll:(NSString *)spec {
    NSMutableArray *parts = [[spec componentsSeparatedByString:@"|"] mutableCopy];
    BOOL multi = [parts.lastObject isEqual:@"*"];
    if (multi) [parts removeLastObject];
    if (parts.count < 3) return;
    NSString *q = [parts objectAtIndex:0];
    [parts removeObjectAtIndex:0];
    [GMCore call:@"messages.sendPoll" args:@{@"peer": self.peer, @"q": q, @"answers": parts, @"multi": @(multi)}
            done:^(id ok, NSDictionary *err) {
                if (err) {
                    GMLog(@"[thử] gửi bình chọn lỗi: %@", GMVal(err, @"code"));
                    return;
                }
                GMLog(@"[thử] đã gửi bình chọn %@", GMVal(ok, @"id"));
                [self append:ok];
            }];
}

/// Công cụ thử: bỏ phiếu ở tin thứ k từ dưới lên — `idx`: số thứ tự lựa chọn cách nhau bởi dấu phẩy («0», «0,2»); «-» = rút phiếu.
- (void)debugVoteFromBottom:(NSInteger)k options:(NSString *)idx {
    NSInteger r = [self rowFromBottom:k];
    if (r == NSNotFound) return;
    NSDictionary *m = [[_rows objectAtIndex:r] objectForKey:@"msg"];
    NSArray *answers = GMVal(GMVal(m, @"poll"), @"answers");
    if (!answers) {
        GMLog(@"[thử] tin này không phải bình chọn");
        return;
    }
    NSMutableArray *opts = [NSMutableArray array];
    if (![idx isEqual:@"-"]) {
        for (NSString *x in [idx componentsSeparatedByString:@","]) {
            NSInteger j = x.integerValue;
            if (j >= 0 && j < (NSInteger)answers.count) [opts addObject:GMVal([answers objectAtIndex:j], @"o")];
        }
    }
    [self vote:opts msg:GMVal(m, @"id")];
}

- (void)joinTapped {
    _joinBtn.enabled = NO;
    NSDictionary *args = self.joinHash ? @{@"hash": self.joinHash} : @{@"peer": self.peer};
    [GMCore call:@"chats.join" args:args done:^(id ok, NSDictionary *err) {
        _joinBtn.enabled = YES;
        if (err) {
            GMAlertShow(@"Chưa vào được", GMErrorText(err), @"OK", nil, nil);
            return;
        }
        self.joinHash = nil;
        [self setJoinBar:NO];
        [GMTheme toast:[self.kind isEqual:@"channel"] ? @"Đã tham gia kênh" : @"Đã tham gia nhóm" in:self.view];
        [((GMAppDelegate *)[UIApplication sharedApplication].delegate).list reload];
        [self loadStatus];
    }];
}

#pragma mark Trạng thái (dòng phụ dưới tên chat)

- (void)showInfo {
    GMChatInfoViewController *i = [[GMChatInfoViewController alloc] init];
    i.peer = self.peer;
    i.kind = self.kind;
    i.myId = self.myId;
    i.name = self.topic ? self.groupName : self.title;
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
    if (self.topic) [a setObject:self.topic forKey:@"topic"];
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
    if (self.topic) {
        _titleView.subtitle = self.groupName;  // chủ đề: dòng phụ là tên nhóm
        return;
    }
    [GMCore call:@"chat.status" args:@{@"peer": self.peer} done:^(id ok, NSDictionary *err) {
        if (!ok) return;
        _status = ok;
        _allowedReacts = GMVal(ok, @"reactions");
        _commands = GMVal(GMVal(ok, @"bot_info"), @"commands") ?: GMVal(ok, @"commands");
        NSDictionary *menu = GMVal(GMVal(ok, @"bot_info"), @"menu");
        [self setBotMenu:[menu isKindOfClass:[NSDictionary class]] ? menu : nil];
        if (_historyLoaded && [GMVal(ok, @"bot") boolValue]) [self updateBotKeyboard];
        [self checkBotStart];
        // Chưa vào (mở từ link, kết quả tìm): thanh «Tham gia» — nhóm thường đã rời thì không vào lại được (cần link mời)
        BOOL left = [GMVal(ok, @"left") boolValue] && ([self.peer hasPrefix:@"-100"] || self.joinHash);
        if (left != self.left) [self setJoinBar:left];
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
    if (self.navigationController.topViewController == self) [self markRead];
}

- (BOOL)isSaved {
    return [self.peer isEqual:self.myId];
}

static BOOL gDebugNoRead;

+ (void)setDebugNoRead:(BOOL)on {
    gDebugNoRead = on;
}

/// Đánh dấu đã đọc: cả chat; ở một chủ đề diễn đàn thì chỉ chủ đề đó, tới tin mới nhất đã tải.
- (void)markRead {
    if (gDebugNoRead) return;
    // Màn khoá mật mã đang che: chưa ai đọc (mở khoá → `unlocked` đánh dấu lại)
    if ([GMPasscode isLocked]) return;
    if (!self.topic) {
        [GMCore call:@"messages.read" args:@{@"peer": self.peer} done:nil];
        return;
    }
    long long max = 0;
    for (NSDictionary *m in _msgs) max = MAX(max, [GMVal(m, @"id") longLongValue]);
    if (max <= 0) return;
    [GMCore call:@"messages.read" args:@{@"peer": self.peer, @"topic": self.topic, @"max_id": @(max)} done:nil];
}

/// Tin thuộc màn này: mọi tin của chat, hoặc ở màn một chủ đề thì chỉ tin của chủ đề đó (không thuộc chủ đề nào = General, 1).
- (BOOL)inTopic:(NSDictionary *)m {
    return !self.topic || [(GMVal(m, @"topic") ?: @1) isEqual:self.topic];
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
    if (self.topic) {
        // Chủ đề: lõi trả {msgs, more, next} — `next` là mốc trang sau (General lọc từ lịch sử nhóm: mốc có thể không phải tin đã hiện)
        [args setObject:self.topic forKey:@"topic"];
        if (_topicNext) [args setObject:_topicNext forKey:@"offset_id"];
    } else if (oldest) {
        [args setObject:GMVal(oldest, @"id") forKey:@"offset_id"];
    }
    long long t = GMNowMs();
    [GMCore call:@"messages.history" args:args done:^(id ok, NSDictionary *err) {
        _loading = NO;
        [_spin stopAnimating];
        if (err) {
            GMLog(@"tải tin lỗi: %@", GMVal(err, @"code"));
            return;
        }
        NSArray *page = self.topic ? GMVal(ok, @"msgs") : ok;  // mới → cũ
        GMLog(@"tải %lu tin, %lld ms", (unsigned long)page.count, GMNowMs() - t);
        if (self.topic) {
            if (![GMVal(ok, @"more") boolValue] || !GMVal(ok, @"next")) _noMore = YES;
            _topicNext = GMVal(ok, @"next");
            // General lọc từ lịch sử: trang có thể trống mà vẫn còn tin cũ hơn → tải tiếp
            if (!page.count && !_noMore) {
                dispatch_async(dispatch_get_main_queue(), ^{ [self loadOlder]; });
                return;
            }
        } else if (page.count < 40) {
            _noMore = YES;
        }
        BOOL wasLoaded = _historyLoaded;
        _historyLoaded = YES;
        if (!page.count) {
            if (!wasLoaded) [self checkBotStart];  // chat trống: bot → «Bắt đầu»
            return;
        }
        BOOL first = _msgs.count == 0;
        CGFloat before = _table.contentSize.height;
        CGFloat offset = _table.contentOffset.y;
        for (NSDictionary *m in page) [_msgs insertObject:m atIndex:0];
        [self reloadTable];
        [self updateBotKeyboard];
        if (self.jumpTo) {
            [self tryJump];
            return;
        }
        if (first) {
            [self scrollToBottom:NO];
            // App ở nền (vd mở chat từ thông báo chưa xong): chưa tính là đã đọc — quay lại app mới đánh dấu
            if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) [self markRead];
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
    _botCard.hidden = YES;
    [self updateBotKeyboard];
}

- (void)event:(NSNotification *)n {
    NSDictionary *ev = n.userInfo;
    NSString *e = GMVal(ev, @"e");
    NSDictionary *m = GMVal(ev, @"msg");
    if ([e isEqual:@"msg.new"] && _backBtn) {
        // Danh sách chat cũng nghe sự kiện này (thứ tự không chắc) — đếm lại sau khi nó cập nhật
        dispatch_async(dispatch_get_main_queue(), ^{ [self updateBackCount]; });
    }
    if ([e isEqual:@"typing"] && [GMVal(ev, @"peer") isEqual:self.peer] && ![GMVal(ev, @"from") isEqual:self.myId]) {
        if (self.topic) return;  // không biết đang gõ ở chủ đề nào — dòng phụ giữ tên nhóm
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
    if ([e isEqual:@"msg.new"] && [GMVal(m, @"peer") isEqual:self.peer] && [self inTopic:m]) {
        [self append:m];
        if ([GMVal(m, @"scheduled") boolValue]) [self loadScheduled];  // tin hẹn giờ vừa tới giờ
        // Ở nền (đang mở chat này rồi bấm Home): chưa tính là đã đọc — quay lại app mới đánh dấu
        if (![GMVal(m, @"out") boolValue] && [UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
            [self markRead];
        }
    } else if ([e isEqual:@"msg.edit"] && [GMVal(m, @"peer") isEqual:self.peer]) {
        NSInteger i = [self indexOf:GMVal(m, @"id")];
        if (i != NSNotFound) {
            [_msgs replaceObjectAtIndex:i withObject:m];
            [self reloadTable];
            [self updateBotKeyboard];
        }
    } else if ([e isEqual:@"msg.delete"]) {
        NSString *channel = GMVal(ev, @"channel");
        // Xoá ở kênh / siêu nhóm có kèm kênh; còn lại (chat riêng, nhóm thường) id là chung của tài khoản
        if (channel && ![channel isEqual:self.peer]) return;
        if (!channel && [self.peer hasPrefix:@"-100"]) return;
        [self removeIds:GMVal(ev, @"ids")];
    } else if ([e isEqual:@"net.state"]) {
        _titleView.connecting = ![GMVal(ev, @"ok") boolValue];
    } else if ([e isEqual:@"msg.poll"]) {
        [self applyPollUpdate:ev];
    } else if ([e isEqual:@"msg.pinned"] && [GMVal(ev, @"peer") isEqual:self.peer]) {
        [self markPinned:GMVal(ev, @"ids") on:[GMVal(ev, @"pinned") boolValue]];
        [self loadPins];
    } else if ([e isEqual:@"msg.reactions"] && [GMVal(ev, @"peer") isEqual:self.peer]) {
        [self setReactions:GMVal(ev, @"reactions") forMsg:GMVal(ev, @"id")];
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

#pragma mark Gợi ý «/»: lệnh bot, tin nhắn nhanh

/// Ô nhập bắt đầu bằng «/» (chưa có khoảng trắng): gợi ý lệnh của bot và tin nhắn nhanh khớp; không khớp gì → «+ Thêm tin nhắn
/// nhanh».
- (void)updateSuggestions {
    _menuOpen = NO;  // gõ phím: danh sách lệnh mở từ nút «Menu» đóng lại (hoặc thành gợi ý «/»)
    NSString *t = _input.text;
    NSMutableArray *items = [NSMutableArray array];
    BOOL slash = [t hasPrefix:@"/"] && _compose != GMComposeEdit &&
                 [t rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location == NSNotFound;
    if (slash) {
        NSString *q = [[t substringFromIndex:1] lowercaseString];
        for (NSDictionary *c in _commands) {
            NSString *cmd = GMVal(c, @"c");
            if (cmd.length < 2 || (q.length && ![[[cmd substringFromIndex:1] lowercaseString] hasPrefix:q])) continue;
            [items addObject:@{@"t": cmd, @"d": GMVal(c, @"d") ?: @"", @"kind": @"cmd", @"v": cmd}];
        }
        for (NSDictionary *r in [GMQuickReplies all]) {
            NSString *k = [r objectForKey:@"k"];
            if (q.length && ![k hasPrefix:q]) continue;
            [items addObject:@{@"t": [@"/" stringByAppendingString:k], @"d": [r objectForKey:@"t"], @"kind": @"quick",
                               @"v": [r objectForKey:@"t"]}];
        }
        if (!items.count) {
            [items addObject:@{@"t": @"+ Thêm tin nhắn nhanh", @"kind": @"add", @"v": q,
                               @"d": q.length ? [NSString stringWithFormat:@"Lưu mẫu câu với từ khoá /%@", q]
                                              : @"Mẫu câu tự đặt — gõ «/từ khoá» để chèn"}];
        }
    }
    if (!items.count) {
        if (_suggest && !_suggest.hidden) {
            _suggest.hidden = YES;
            [self layoutBars:NO];
        }
        return;
    }
    [self showSuggest:items];
}

- (void)showSuggest:(NSArray *)items {
    if (!_suggest) {
        _suggest = [[GMSuggestView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
        __weak GMChatViewController *ws = self;
        _suggest.pick = ^(NSDictionary *it) { [ws suggestPicked:it]; };
        [self.view addSubview:_suggest];
    }
    _suggest.items = items;
    _suggest.hidden = NO;
    [self.view bringSubviewToFront:_suggest];
    [self layoutBars:NO];
}

- (void)suggestPicked:(NSDictionary *)it {
    NSString *kind = GMVal(it, @"kind"), *v = GMVal(it, @"v") ?: @"";
    if ([kind isEqual:@"cmd"]) {
        if (_menuOpen) {
            [self closeBotMenu];  // từ nút «Menu»: giữ nguyên chữ đang soạn
        } else {
            _input.text = @"";
            [self textViewDidChange:_input];
        }
        [self sendText:v reply:nil];
    } else if ([kind isEqual:@"quick"]) {
        _input.text = v;
        [self textViewDidChange:_input];
    } else {
        _input.text = @"";
        [self textViewDidChange:_input];
        [_input resignFirstResponder];
        GMQuickRepliesViewController *q = [[GMQuickRepliesViewController alloc] init];
        q.prefillKeyword = v.length ? v : nil;
        [self.navigationController pushViewController:q animated:YES];
    }
}

- (void)debugSuggest:(NSInteger)i {
    if (_suggest.hidden || i < 0 || i >= (NSInteger)_suggest.items.count) {
        GMLog(@"[thử] gợi ý: không có mục %ld (%lu mục)", (long)i, (unsigned long)(_suggest.hidden ? 0 : _suggest.items.count));
        return;
    }
    GMLog(@"[thử] gợi ý: %lu mục, chọn «%@»", (unsigned long)_suggest.items.count, GMVal([_suggest.items objectAtIndex:i], @"t"));
    [self suggestPicked:[_suggest.items objectAtIndex:i]];
}

- (void)textViewDidChange:(UITextView *)tv {
    if (tv.text.length && _compose != GMComposeEdit) [self sendTyping:@"typing"];
    _placeholder.hidden = tv.text.length > 0;
    [self updateSendButton];
    CGFloat content = tv.contentSize.height;
    CGFloat h = MIN(kInputMaxH, MAX(kInputMinH, content));
    tv.scrollEnabled = content > kInputMaxH;
    CGFloat barH = h + 12;
    BOOL menuChanged = [self updateMenuButton];
    if (barH != _barH || menuChanged) {
        _barH = barH;
        [UIView animateWithDuration:0.15 animations:^{ [self layoutBars:YES]; }];
    }
    [self updateSuggestions];
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
    [_send setTitle:nil forState:UIControlStateNormal];
    [_send setImage:mic ? [GMTheme icon:@"mic" color:[GMTheme text]] : nil forState:UIControlStateNormal];
    _send.imageEdgeInsets = UIEdgeInsetsMake(-2, 0, 0, 0);
    [_send setBackgroundImage:mic ? [GMTheme glassButton:40 pressed:NO] : [GMTheme sendCircle:NO] forState:UIControlStateNormal];
    [_send setBackgroundImage:mic ? [GMTheme glassButton:40 pressed:YES] : [GMTheme sendCircle:YES] forState:UIControlStateHighlighted];
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
    if (self.topic) [args setObject:self.topic forKey:@"topic"];
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
    [self sendText:text reply:reply silent:NO];
}

- (void)sendText:(NSString *)text reply:(NSNumber *)reply silent:(BOOL)silent {
    long long t0 = GMNowMs();
    NSNumber *tmp = @(-(t0 % 1000000000) - 1);
    NSMutableDictionary *pending = [@{@"id": tmp, @"peer": self.peer, @"text": text, @"out": @YES, @"pending": @YES,
                                      @"date": @((long long)[[NSDate date] timeIntervalSince1970])} mutableCopy];
    if (reply) [pending setObject:reply forKey:@"reply_to"];
    if (self.topic) [pending setObject:self.topic forKey:@"topic"];
    [self append:pending];
    NSMutableDictionary *args = [@{@"peer": self.peer, @"text": text, @"queue": @YES} mutableCopy];
    if (reply) [args setObject:reply forKey:@"reply_to"];
    if (silent) [args setObject:@YES forKey:@"silent"];
    if (self.topic) [args setObject:self.topic forKey:@"topic"];
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
            if (![self inTopic:it]) continue;
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
    void (^open)(NSString *, BOOL) = ^(NSString *path, BOOL hevc) {
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
    };
    // Video: lõi chọn bản H.264; tệp gốc H.265 (iOS 5 / 6 chỉ có tiếng) mà không có bản H.264 → chuyển trên máy rồi phát
    if ([kind isEqual:@"video"] || [kind isEqual:@"round"]) {
        GMFiles *f = [GMFiles shared];
        if ([f isConverting:self.peer msg:GMVal(m, @"id")]) {
            [GMTheme toast:[NSString stringWithFormat:@"Đang chuyển video cho máy phát được hình — %.0f%%",
                                                      MAX(0, [f progressOf:self.peer msg:GMVal(m, @"id")]) * 100] in:self.view];
            return;
        }
        [f fetchVideo:self.peer msg:GMVal(m, @"id") done:^(NSString *path, BOOL hevc) {
            if (path && hevc) [ws convertVideo:m path:path then:^(NSString *p) { open(p, NO); }];
            else open(path, NO);
        }];
    } else {
        [[GMFiles shared] fetch:self.peer msg:GMVal(m, @"id") done:^(NSString *path) { open(path, NO); }];
    }
}

/// Video H.265: chuyển sang H.264 trên máy (chỉ lần đầu — xong thì thay tệp trong bộ đệm), xong mà còn ở màn này thì phát.
- (void)convertVideo:(NSDictionary *)m path:(NSString *)path then:(void (^)(NSString *path))play {
    [GMTheme toast:@"Video mã H.265: đang chuyển để máy phát được hình (chỉ lần đầu; video dài mất vài phút)" in:self.view];
    __weak GMChatViewController *ws = self;
    [[GMFiles shared] convertVideo:path peer:self.peer msg:GMVal(m, @"id") done:^(NSString *np, NSString *err) {
        GMChatViewController *s = ws;
        if (!s) return;
        if (!np) {
            [GMTheme toast:[@"Không chuyển được video: " stringByAppendingString:err ?: @""] in:s.view];
            return;
        }
        if (s.navigationController.topViewController == s &&
            [UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
            play(np);
        } else {
            [GMTheme toast:@"Đã chuyển xong video — chạm để xem" in:s.view];
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

/// Ghim giấy: bảng đính kèm kính (D37) — ảnh gần đây + các loại khác.
- (void)attachTapped {
    [_input resignFirstResponder];
    __weak GMChatViewController *ws = self;
    UIView *host = self.navigationController.view ?: self.view;
    [_attachSheet dismiss];
    _attachSheet = [GMAttachSheet showIn:host
        camera:[UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]
        pick:^(GMAttachKind k) {
            GMChatViewController *me = ws;
            switch (k) {
                case GMAttachCamera: [me pickFrom:UIImagePickerControllerSourceTypeCamera]; break;
                case GMAttachLibrary: [me pickFrom:UIImagePickerControllerSourceTypePhotoLibrary]; break;
                case GMAttachFile: [me openFileBrowser]; break;
                case GMAttachLocation: [me pickLocation]; break;
                case GMAttachQR: [me openVietQR]; break;
                case GMAttachContact: [me pickContactCard]; break;
            }
        }
        photo:^(UIImage *img) { [ws sendImage:img]; }];
}

- (void)debugAttach:(NSString *)arg {
    if ([arg isEqual:@"open"]) [self attachTapped];
    else if ([arg hasPrefix:@"sel "]) [_attachSheet debugSelect:[[arg substringFromIndex:4] integerValue]];
    else if ([arg isEqual:@"close"]) [_attachSheet dismiss];
    else if ([arg isEqual:@"send"]) [_attachSheet debugSend];
}

/// Bảng chọn cũ (UIActionSheet) — giữ cho gỡ lỗi / máy không mở được bảng mới.
- (void)attachTappedOld {
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
    [s addButtonWithTitle:@"Vị trí"];
    [kinds addObject:@(-2)];
    [s addButtonWithTitle:@"Mã QR chuyển khoản"];
    [kinds addObject:@(-3)];
    [s addButtonWithTitle:@"Danh thiếp"];
    [kinds addObject:@(-4)];
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
    [self sendImage:img caption:nil];
}

- (void)sendImage:(UIImage *)img caption:(NSString *)caption {
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
        dispatch_async(dispatch_get_main_queue(), ^{ [self sendPhotoFile:path caption:caption]; });
    });
}

- (void)sendPhotoFile:(NSString *)path {
    [self sendPhotoFile:path caption:nil];
}

- (void)sendPhotoFile:(NSString *)path caption:(NSString *)caption {
    NSNumber *reply = _compose == GMComposeReply ? GMVal(_target, @"id") : nil;
    if (reply) [self setCompose:GMComposeNormal target:nil];
    NSMutableDictionary *args = [@{@"peer": self.peer, @"path": path} mutableCopy];
    if (caption.length) [args setObject:caption forKey:@"caption"];
    if (reply) [args setObject:reply forKey:@"reply_to"];
    if (self.topic) [args setObject:self.topic forKey:@"topic"];
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
    if (self.topic) [a setObject:self.topic forKey:@"topic"];
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
    if (action == @selector(gmReact:)) return [self canReact:_menuMsg];
    if (action == @selector(gmPin:)) return ![GMVal(_menuMsg, @"service") boolValue] && !self.left;
    if (action == @selector(gmCopy:)) return [GMVal(_menuMsg, @"text") length] > 0;
    if (action == @selector(gmForward:)) return ![GMVal(_menuMsg, @"service") boolValue];
    if (action == @selector(gmSave:)) return [self canSave:_menuMsg];
    if (action == @selector(gmEdit:)) return [self canEdit:_menuMsg];
    if (action == @selector(gmDelete:)) return ![self.kind isEqual:@"channel"] || [self outgoing:_menuMsg];
    return NO;
}

/// Nhấn giữ tin: menu kính (D37) — nền mờ, tin nhấc lên, hàng cảm xúc, các mục chia nhóm (thay UIMenuController của iOS 6).
- (void)showMenuForRow:(NSInteger)row {
    NSDictionary *r = [_rows objectAtIndex:row];
    if (![[r objectForKey:@"type"] isEqual:@"msg"]) return;
    NSDictionary *m = [r objectForKey:@"msg"];
    _menuMsg = m;
    [_input resignFirstResponder];
    GMBubbleCell *c = (GMBubbleCell *)[_table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
    if (!c) return;
    UIView *src = !c.bubble.hidden ? c.bubble : (!c.sticker.hidden ? c.sticker : c.contentView);
    __weak GMChatViewController *ws = self;
    NSMutableArray *items = [NSMutableArray array];
    __block BOOL newGroup = NO;
    void (^add)(NSString *, NSString *, SEL, BOOL) = ^(NSString *title, NSString *icon, SEL sel, BOOL red) {
        if (![ws canPerformAction:sel withSender:nil]) return;
        GMMenuItem *it = [GMMenuItem title:title icon:icon action:^{
            GMChatViewController *me = ws;
            if (!me) return;
            me->_menuMsg = m;
            ((void (*)(id, SEL, id))[me methodForSelector:sel])(me, sel, nil);
        }];
        it.destructive = red;
        it.startsGroup = newGroup && items.count > 0;
        newGroup = NO;
        [items addObject:it];
    };
    add(@"Trả lời", @"reply", @selector(gmReply:), NO);
    add(@"Sao chép", @"copy", @selector(gmCopy:), NO);
    add(@"Chuyển tiếp", @"forward", @selector(gmForward:), NO);
    add(@"Lưu vào máy", @"save", @selector(gmSave:), NO);
    add([GMVal(m, @"pinned") boolValue] ? @"Bỏ ghim" : @"Ghim", @"pin", @selector(gmPin:), NO);
    newGroup = YES;
    add(@"Sửa", @"edit", @selector(gmEdit:), NO);
    newGroup = YES;
    add(@"Xoá", @"trash", @selector(gmDelete:), YES);
    BOOL canReact = [self canReact:m];
    if (!items.count && !canReact) return;
    NSString *mine = [self myReaction:m];
    NSNumber *mid = GMVal(m, @"id");
    UIView *host = self.navigationController.view ?: self.view;
    [_ctxMenu dismiss];
    _ctxMenu = [GMContextMenu showIn:host source:src outgoing:[self outgoing:m] emojis:canReact ? [self pickerEmojis] : @[]
                              chosen:mine items:items
                               react:^(NSString *emoji) { [ws react:mid emoji:[emoji isEqual:mine] ? nil : emoji]; }
                                more:canReact ? ^{ [ws showReactPickerFor:m]; } : nil];
}

- (void)debugMenuTap:(NSInteger)i {
    [_ctxMenu debugTap:i];
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

#pragma mark Cảm xúc

/// Thả cảm xúc được: tin đã gửi xong, không phải tin hệ thống; Tin nhắn đã lưu thì không (ở đó cảm xúc = thẻ, chỉ Premium);
/// chat tắt cảm xúc thì không.
- (BOOL)canReact:(NSDictionary *)m {
    if (!m || [GMVal(m, @"id") integerValue] <= 0 || [GMVal(m, @"service") boolValue] || [self isSaved]) return NO;
    return ![_allowedReacts isEqual:@"none"] && (![_allowedReacts isKindOfClass:[NSArray class]] || [_allowedReacts count]);
}

/// Emoji cho bảng chọn: chat chỉ cho một số → theo danh sách đó; không thì danh sách của Telegram — chỉ giữ emoji máy vẽ được.
- (NSArray *)pickerEmojis {
    NSArray *base = [_allowedReacts isKindOfClass:[NSArray class]] ? _allowedReacts : gReactChoices;
    if (!base.count) base = @[@"👍", @"👎", @"❤", @"🔥", @"😍", @"👏", @"😁", @"😱", @"😢", @"🎉", @"💩", @"🙏", @"👌", @"💯",
                              @"😭", @"😘", @"😎", @"😈", @"🏆", @"💔"];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *e in base) {
        if ([GMTheme emojiRenders:e] && ![out containsObject:e]) [out addObject:e];
    }
    return out;
}

- (NSString *)myReaction:(NSDictionary *)m {
    for (NSDictionary *r in GMVal(m, @"reactions")) {
        if ([GMVal(r, @"me") boolValue]) return GMVal(r, @"e");
    }
    return nil;
}

- (void)gmReact:(id)sender {
    [self showReactPickerFor:_menuMsg];
}

- (GMReactionPicker *)showReactPickerFor:(NSDictionary *)m {
    if (![self canReact:m]) return nil;
    CGRect anchor = CGRectMake(self.view.bounds.size.width / 2, 120, 1, 1);
    for (NSInteger r = 0; r < (NSInteger)_rows.count; r++) {
        if ([[_rows objectAtIndex:r] objectForKey:@"msg"] == m) {
            GMBubbleCell *c = (GMBubbleCell *)[_table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:r inSection:0]];
            UIView *v = (c && !c.bubble.hidden) ? c.bubble : (c ? c.sticker : nil);
            if (v) anchor = [v convertRect:v.bounds toView:self.view];
            break;
        }
    }
    NSNumber *mid = GMVal(m, @"id");
    __weak GMChatViewController *ws = self;
    return [GMReactionPicker showIn:self.view near:anchor emojis:[self pickerEmojis] chosen:[self myReaction:m]
                               pick:^(NSString *emoji) { [ws react:mid emoji:emoji]; }];
}

/// Thả `emoji` (thay cảm xúc cũ của mình), nil → gỡ. Hiện ngay trên máy, rồi lấy danh sách thật từ phản hồi.
- (void)react:(NSNumber *)msgId emoji:(NSString *)emoji {
    NSDictionary *m = [self msgWithId:msgId];
    if (!m) return;
    NSArray *before = GMVal(m, @"reactions");
    [self setReactions:[self reactions:before withMine:emoji] forMsg:msgId];
    NSMutableDictionary *args = [@{@"peer": self.peer, @"id": msgId} mutableCopy];
    if (emoji) [args setObject:emoji forKey:@"emoji"];
    [GMCore call:@"messages.react" args:args done:^(id ok, NSDictionary *err) {
        if (err) {
            [self setReactions:before forMsg:msgId];
            [GMTheme toast:GMErrorText(err) in:self.view];
            return;
        }
        GMLog(@"cảm xúc: %@", emoji ? @"đã thả" : @"đã gỡ");
        if ([GMVal(ok, @"reactions") isKindOfClass:[NSArray class]]) [self setReactions:GMVal(ok, @"reactions") forMsg:msgId];
    }];
}

/// Danh sách cảm xúc sau khi mình đổi: bỏ cảm xúc cũ của mình (bớt 1), thêm `emoji` (cộng 1 hoặc viên mới ở cuối).
- (NSArray *)reactions:(NSArray *)list withMine:(NSString *)emoji {
    NSMutableArray *out = [NSMutableArray array];
    BOOL added = NO;
    for (NSDictionary *r in ([list isKindOfClass:[NSArray class]] ? list : @[])) {
        NSMutableDictionary *x = [r mutableCopy];
        NSInteger n = [GMVal(r, @"n") integerValue];
        if ([GMVal(r, @"me") boolValue]) {
            n--;
            [x setObject:@NO forKey:@"me"];
        }
        if (emoji && [GMVal(r, @"e") isEqual:emoji]) {
            n++;
            [x setObject:@YES forKey:@"me"];
            added = YES;
        }
        [x setObject:@(n) forKey:@"n"];
        if (n > 0) [out addObject:x];
    }
    if (emoji && !added) [out addObject:@{@"e": emoji, @"n": @1, @"me": @YES}];
    return out;
}

- (void)setReactions:(NSArray *)rs forMsg:(NSNumber *)msgId {
    NSInteger i = [self indexOf:msgId];
    if (i == NSNotFound) return;
    NSMutableDictionary *m = [[_msgs objectAtIndex:i] mutableCopy];
    if ([rs isKindOfClass:[NSArray class]] && rs.count) [m setObject:rs forKey:@"reactions"];
    else [m removeObjectForKey:@"reactions"];
    [_msgs replaceObjectAtIndex:i withObject:m];
    BOOL bottom = [self nearBottom];
    [self reloadTable];
    if (bottom) [self scrollToBottom:NO];
}

/// Khoá ngắn của các cảm xúc (bộ đệm chiều cao hàng).
- (NSString *)reactSig:(NSDictionary *)m {
    NSMutableString *s = [NSMutableString string];
    for (NSDictionary *r in GMVal(m, @"reactions")) [s appendFormat:@"%@%@%@,", GMVal(r, @"e"), GMVal(r, @"n"), GMVal(r, @"me")];
    return s;
}

/// Cao thêm cho hàng có cảm xúc (khối viên + lề trên).
- (CGFloat)reactHeight:(NSDictionary *)m {
    CGSize s = GMLayoutChips(GMVal(m, @"reactions"), [self maxBubbleW] - 2 * kPadX - [GMTheme tailWidth], nil);
    return s.height > 0 ? s.height + 6 : 0;
}

/// Đặt các viên cảm xúc của tin vào ô: gốc `o` trong `parent` (bong bóng, hoặc ô — tin sticker). Chạm viên: thả / gỡ cảm xúc đó.
- (CGSize)fillChips:(GMBubbleCell *)c msg:(NSDictionary *)m tint:(UIColor *)tint plain:(BOOL)plain at:(CGPoint)o in:(UIView *)parent {
    for (UIView *v in [c.reacts.subviews copy]) [v removeFromSuperview];
    NSArray *rs = GMVal(m, @"reactions");
    NSMutableArray *frames = [NSMutableArray array];
    CGSize sz = GMLayoutChips(rs, [self maxBubbleW] - 2 * kPadX - [GMTheme tailWidth], frames);
    c.reacts.hidden = sz.height <= 0;
    if (c.reacts.hidden) return CGSizeZero;
    if (c.reacts.superview != parent) [parent addSubview:c.reacts];
    c.reacts.frame = CGRectMake(o.x, o.y, sz.width, sz.height);
    NSNumber *mid = GMVal(m, @"id");
    BOOL can = [self canReact:m];
    __weak GMChatViewController *ws = self;
    for (NSUInteger i = 0; i < rs.count; i++) {
        NSDictionary *r = [rs objectAtIndex:i];
        BOOL me = [GMVal(r, @"me") boolValue];
        GMChip *b = [GMChip buttonWithType:UIButtonTypeCustom];
        b.frame = [[frames objectAtIndex:i] CGRectValue];
        b.titleLabel.font = [UIFont systemFontOfSize:13];
        [b setTitle:GMChipTitle(r) forState:UIControlStateNormal];
        [b setTitleColor:me ? [UIColor whiteColor] : (plain ? [UIColor whiteColor] : tint) forState:UIControlStateNormal];
        b.backgroundColor = me ? tint : (plain ? [GMTheme pillBackground] : [tint colorWithAlphaComponent:0.15]);
        b.layer.cornerRadius = kChipH / 2;
        NSString *e = GMVal(r, @"e");
        if (can && ![GMVal(r, @"custom") boolValue] && ![GMVal(r, @"paid") boolValue]) {
            b.tap = ^{ [ws react:mid emoji:me ? nil : e]; };
            [b addTarget:b action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
        }
        [c.reacts addSubview:b];
    }
    return sz;
}

- (void)debugReactFromBottom:(NSInteger)k emoji:(NSString *)emoji {
    NSInteger r = [self rowFromBottom:k];
    if (r == NSNotFound) return;
    NSDictionary *m = [[_rows objectAtIndex:r] objectForKey:@"msg"];
    if (![self canReact:m]) {
        GMLog(@"[thử] tin này không thả cảm xúc được");
        return;
    }
    [self react:GMVal(m, @"id") emoji:emoji.length && ![emoji isEqual:@"-"] ? emoji : nil];
}

- (void)debugReactPickerFromBottom:(NSInteger)k pick:(NSInteger)i {
    NSInteger r = [self rowFromBottom:k];
    if (r == NSNotFound) return;
    GMReactionPicker *p = [self showReactPickerFor:[[_rows objectAtIndex:r] objectForKey:@"msg"]];
    GMLog(@"[thử] bảng cảm xúc: %lu emoji vẽ được / %lu", (unsigned long)[self pickerEmojis].count,
          (unsigned long)(gReactChoices.count ?: 0));
    if (p && i >= 0) [p tapIndex:i];
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

/// Link chạm mở được: link web + link Telegram (t.me, @tên, tg://resolve…) — bỏ link proxy (nút riêng), tg:// khác, email.
- (NSArray *)openableLinksOf:(NSDictionary *)m {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *l in GMVal(m, @"links")) {
        NSString *low = l.lowercaseString;
        if ([l isEqual:GMVal(m, @"proxy")]) continue;
        if ([GMLinks isTelegramLink:l]) {
            [out addObject:l];
            continue;
        }
        if ([low hasPrefix:@"tg://"] || [low hasPrefix:@"@"]) continue;
        if ([low rangeOfString:@"://"].location == NSNotFound && [l rangeOfString:@"@"].location != NSNotFound) continue;  // email
        [out addObject:l];
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
    if ([GMVal(m, @"contact") isKindOfClass:[NSDictionary class]]) {
        [self contactTapped:GMVal(m, @"contact")];
        return;
    }
    NSDictionary *geo = GMVal(m, @"geo");
    if (geo) {
        GMMapViewController *mv = [[GMMapViewController alloc] initWithLat:[GMVal(geo, @"lat") doubleValue] lng:[GMVal(geo, @"lng") doubleValue]
                                                                      title:GMVal(geo, @"title") address:GMVal(geo, @"address")];
        [self.navigationController pushViewController:mv animated:YES];
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
    NSArray *web = [self openableLinksOf:m];
    if (web.count == 1) {
        NSString *link = web.firstObject, *text = GMVal(m, @"text");
        if (![text isKindOfClass:[NSString class]] || [text rangeOfString:link options:NSCaseInsensitiveSearch].location == NSNotFound) {
            // Link ẩn sau chữ khác (chữ ghi «telegram.org» mà link thật đi chỗ khác): hiện link thật trước khi mở, như Telegram
            // (kiểm bảo mật 17/11/2026)
            __weak GMChatViewController *ws = self;
            GMAlertShow(@"Mở link này?", link, @"Huỷ", @"Mở", ^(NSInteger i) {
                if (i == 1 && ws) [GMLinks open:link in:ws.view];
            });
            return;
        }
        [GMLinks open:link in:self.view];
    } else if (web.count > 1) {
        UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:@"Mở link" delegate:self cancelButtonTitle:nil
                                             destructiveButtonTitle:nil otherButtonTitles:nil];
        for (NSString *u in web) [sheet addButtonWithTitle:u];
        sheet.cancelButtonIndex = [sheet addButtonWithTitle:@"Huỷ"];
        objc_setAssociatedObject(sheet, "links", web, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sheet showInView:self.view];
    }
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)i {
    NSArray *cardActs = objc_getAssociatedObject(sheet, "card");
    if (cardActs) {
        NSDictionary *card = objc_getAssociatedObject(sheet, "cardData");
        if (i < 0 || i >= (NSInteger)cardActs.count) return;
        NSString *act = [cardActs objectAtIndex:i];
        NSString *phone = [@"+" stringByAppendingString:[GMVal(card, @"phone") ?: @"" stringByReplacingOccurrencesOfString:@"+" withString:@""]];
        if ([act isEqual:@"chat"]) {
            [GMLinks open:[NSString stringWithFormat:@"tg://user?id=%@", GMVal(card, @"user")] in:self.view];
        } else if ([act isEqual:@"call"]) {
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:[@"tel:" stringByAppendingString:phone]]];
        } else if ([act isEqual:@"copy"]) {
            [UIPasteboard generalPasteboard].string = phone;
            [GMTheme toast:@"Đã chép số" in:self.view];
        }
        return;
    }
    NSArray *sched = objc_getAssociatedObject(sheet, "sched");
    if (sched) {
        if (i < 0 || i >= (NSInteger)sched.count) return;
        double at = [[sched objectAtIndex:i] doubleValue];
        if (at == -1) [self showDatePicker];
        else if (at == -2) [self sendComposed:0 silent:YES];
        else [self sendComposed:at silent:NO];
        return;
    }
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
            if (k == -4) [self pickContactCard];
            else if (k == -3) [self openVietQR];
            else if (k == -2) [self pickLocation];
            else if (k < 0) [self openFileBrowser];
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
    if (i >= 0 && i < (NSInteger)web.count) [GMLinks open:[web objectAtIndex:i] in:self.view];
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
    if (!p && GMVal(m, @"geo")) return CGSizeMake(MIN(240, [self maxBubbleW] - 6 - [GMTheme tailWidth]), 150);  // bản đồ nhỏ
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
    // Tin bot sửa nhiều lần (bấm nút): chữ / số hàng nút đổi mà cờ «đã sửa» vẫn vậy → khoá gồm cả độ dài chữ, số hàng nút
    NSString *key = [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%.0f|%d|%@|%lu|%.0f|%@", type, GMVal(m, @"id"), GMVal(m, @"edited"),
                                               [r objectForKey:@"first"], [r objectForKey:@"tail"], _table.bounds.size.width,
                                               (int)self.readOut, [self reactSig:m], (unsigned long)[GMVal(m, @"text") length],
                                               [self kbHeight:m], [self pollSig:m]];
    NSNumber *cached = [_heights objectForKey:key];
    if (cached) return cached.floatValue;
    CGFloat h;
    if ([type isEqual:@"service"]) {
        CGSize s = [GMVal(m, @"text") sizeWithFont:[UIFont boldSystemFontOfSize:13]
                                 constrainedToSize:CGSizeMake(_table.bounds.size.width * 0.8 - 20, 1000)
                                     lineBreakMode:GMWordWrap];
        h = ceil(s.height) + 8 + 10;
    } else if (GMVal(m, @"sticker")) {
        h = [self stickerSize:m].height + 10 + [self reactHeight:m] + [self kbHeight:m];
    } else if (GMVal(m, @"voice")) {
        h = kVoiceH + 2 * kPadY + ([self showName:r] ? kNameH : 0) + (GMVal(m, @"reply_to") ? kReplyH : 0) +
            (GMVal(m, @"fwd") ? kFwdH : 0) + ([[r objectForKey:@"tail"] boolValue] ? 6 : 2) + [self reactHeight:m] +
            [self kbHeight:m];
    } else {
        BOOL visual = GMVal(m, @"photo") || [self isVideo:m] || GMVal(m, @"geo");
        BOOL caption = (!visual && ![self isFile:m]) || [GMVal(m, @"text") length] > 0;
        CGFloat photoH = visual ? [self photoSize:m].height + (caption ? 4 : 0) - (caption ? 0 : 2 * kPadY - 6) : 0;
        if ([self isFile:m]) photoH = kDocH + (caption ? 4 : kDocTimeH);
        NSDictionary *poll = GMVal(m, @"poll");
        if (poll) {
            caption = NO;
            photoH = [GMPollView heightFor:poll width:[self pollW]] + 2 + kDocTimeH + 4;  // + dòng giờ
        }
        if ([GMVal(m, @"contact") isKindOfClass:[NSDictionary class]]) {
            caption = NO;
            photoH = kDocH + kDocTimeH;  // danh thiếp: như bong bóng tệp
        }
        h = (caption ? [self bodySize:m].height : 0) + photoH + 2 * kPadY + ([self showName:r] ? kNameH : 0) +
            (GMVal(m, @"reply_to") ? kReplyH : 0) +
            (GMVal(m, @"fwd") ? kFwdH : 0) +
            (GMVal(m, @"proxy") ? kProxyH : 0) + ([[r objectForKey:@"tail"] boolValue] ? 6 : 2) + [self reactHeight:m] +
            [self kbHeight:m];
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
        c.reacts.hidden = YES;
        c.kbd.hidden = YES;
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
        CGSize rs = GMLayoutChips(GMVal(m, @"reactions"), [self maxBubbleW] - 2 * kPadX - [GMTheme tailWidth], nil);
        [self fillChips:c msg:m tint:[GMTheme accent] plain:YES
                     at:CGPointMake(sout ? W - rs.width - 8 : 8, CGRectGetMaxY(c.sticker.frame) + 6) in:c.contentView];
        CGFloat kw = MIN([self maxBubbleW], 260);
        [self fillButtons:c msg:m area:CGRectMake(sout ? W - kw - 8 : 8, CGRectGetMaxY(c.sticker.frame) + 6 + [self reactHeight:m] + 2,
                                                  kw, [self kbHeight:m] - 4)];
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
    CGSize chips = GMLayoutChips(GMVal(m, @"reactions"), [self maxBubbleW] - 2 * kPadX - t, nil);
    inner = MAX(inner, chips.width);
    CGFloat rh = chips.height > 0 ? chips.height + 6 : 0;
    BOOL isVideo = [self isVideo:m], isFile = [self isFile:m];
    NSDictionary *photo = GMVal(m, @"photo") ?: (isVideo ? GMVal(m, @"doc") : nil);
    NSDictionary *geo = photo ? nil : GMVal(m, @"geo");  // tin vị trí: bản đồ nhỏ ở chỗ ảnh
    if (geo) photo = geo;
    BOOL caption = (!photo && !isFile) || [GMVal(m, @"text") length] > 0;
    CGSize ps = [self photoSize:m];
    if (isFile) inner = MAX(caption ? inner : 0, kDocW);
    if (photo) inner = MAX(caption ? inner : 0, ps.width - 2 * kPadX + 6);
    NSDictionary *poll = GMVal(m, @"poll");
    if (poll) {
        caption = NO;
        inner = MAX(inner, [self pollW]);
    }
    NSDictionary *card = [GMVal(m, @"contact") isKindOfClass:[NSDictionary class]] ? GMVal(m, @"contact") : nil;
    if (card) {
        caption = NO;
        inner = MAX(inner, kDocW);
    }
    NSDictionary *voice = GMVal(m, @"voice");
    if (voice) {
        caption = NO;
        inner = MAX(kVoiceW, name ? inner : 0);
    }
    CGFloat w = inner + 2 * kPadX + t;
    CGFloat kh = [self kbHeight:m];
    CGFloat h = [self heightOfRow:r] - (tail ? 6 : 2) - kh;
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
        c.fwd.textColor = out ? [GMTheme bubbleTime:YES] : [GMTheme accent];
        c.fwd.frame = CGRectMake(cx, cy - 1, inner, kFwdH);
        cy += kFwdH;
    }
    c.replyBar.hidden = c.replyName.hidden = c.replyText.hidden = !hasReply;
    if (hasReply) {
        UIColor *rc = out ? [GMTheme bubbleTime:YES] : [GMTheme accent];
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
        UIImage *cached = geo ? GMMapSnapshotCached([GMVal(geo, @"lat") doubleValue], [GMVal(geo, @"lng") doubleValue], ps)
                        : isVideo ? [GMImages cachedThumbForPeer:self.peer msg:GMVal(m, @"id")]
                                  : [GMImages cachedPhotoForPeer:self.peer msg:GMVal(m, @"id") big:NO];
        c.photo.image = cached ?: (geo ? nil : [GMImages imageFromBase64:GMVal(photo, @"thumb")]);
        if (!cached && geo) {
            __weak GMBubbleCell *wc = c;
            GMMapSnapshot([GMVal(geo, @"lat") doubleValue], [GMVal(geo, @"lng") doubleValue], GMVal(geo, @"hash"), ps, GMVal(geo, @"title"),
                          ^(UIImage *img) {
                if ([wc.photoKey isEqual:pkey]) wc.photo.image = img;
            });
        } else if (!cached) {
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
    c.docIcon.hidden = c.docName.hidden = c.docInfo.hidden = !isFile && !card;
    c.docIcon.layer.cornerRadius = card ? 22 : 8;
    if (card) {
        // Danh thiếp: vòng chữ cái đầu + tên + số điện thoại
        NSString *cn = [self contactName:card];
        NSString *initial = cn.length ? [[cn substringWithRange:[cn rangeOfComposedCharacterSequenceAtIndex:0]] uppercaseString] : @"?";
        c.docIcon.text = initial;
        c.docIcon.backgroundColor = [GMTheme colorFor:GMVal(card, @"user") ?: GMVal(card, @"phone") ?: @"0"];
        c.docIcon.frame = CGRectMake(cx, cy, 44, 44);
        c.docName.text = cn.length ? cn : @"Danh thiếp";
        c.docName.frame = CGRectMake(cx + 52, cy + 3, inner - 52, 19);
        c.docInfo.text = [GMVal(card, @"phone") length] ? [@"+" stringByAppendingString:[GMVal(card, @"phone") stringByReplacingOccurrencesOfString:@"+" withString:@""]]
                                                         : @"Không có số";
        c.docInfo.textColor = out ? [GMTheme bubbleTime:YES] : [GMTheme secondaryText];
        c.docInfo.frame = CGRectMake(cx + 52, cy + 23, inner - 52, 17);
        cy += kDocH + kDocTimeH;
    }
    if (isFile) {
        NSDictionary *d = GMVal(m, @"doc");
        NSString *name = [GMVal(d, @"name") length] ? GMVal(d, @"name") : @"Tệp";
        NSString *ext = name.pathExtension.length ? name.pathExtension.uppercaseString : @"TỆP";
        c.docIcon.text = ext.length > 4 ? [ext substringToIndex:4] : ext;
        c.docIcon.backgroundColor = out ? [GMTheme bubbleTime:YES] : [GMTheme accent];
        c.docIcon.frame = CGRectMake(cx, cy, 44, 44);
        c.docName.text = name;
        c.docName.frame = CGRectMake(cx + 52, cy + 3, inner - 52, 19);
        c.docInfo.textColor = out ? [GMTheme bubbleTime:YES] : [GMTheme secondaryText];
        c.docInfo.frame = CGRectMake(cx + 52, cy + 23, inner - 52, 17);
        cy += kDocH + (caption ? 4 : kDocTimeH);
    }
    c.poll.hidden = poll == nil;
    if (poll) {
        CGFloat ph = [GMPollView heightFor:poll width:[self pollW]];
        c.poll.frame = CGRectMake(cx, cy + 2, [self pollW], ph);
        NSNumber *mid = GMVal(m, @"id");
        __weak GMChatViewController *wp = self;
        c.poll.vote = ^(NSArray *o) { [wp vote:o msg:mid]; };
        c.poll.toggle = ^(NSString *o) { [wp togglePollOption:o msg:mid]; };
        [c.poll showPoll:poll selected:[_pollSel objectForKey:mid] tint:out ? [GMTheme bubbleTime:YES] : [GMTheme accent]];
        cy += ph + 2;
    }
    [self refreshDoc:c];
    [self gifFor:c msg:m on:gif];
    c.play.hidden = c.wave.hidden = c.voiceTime.hidden = voice == nil;
    if (voice) {
        UIColor *vc = out ? [GMTheme bubbleTime:YES] : [GMTheme accent];
        c.play.backgroundColor = vc;
        c.play.frame = CGRectMake(cx, cy + 2, 40, 40);
        c.wave.played = vc;
        c.wave.rest = [vc colorWithAlphaComponent:0.3];
        c.wave.levels = GMVal(voice, @"waveform");
        c.wave.frame = CGRectMake(cx + 48, cy + 4, inner - 52, 22);
        c.voiceTime.textColor = out ? [GMTheme bubbleTime:YES] : [GMTheme secondaryText];
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
    c.time.textColor = out ? [GMTheme bubbleTime:YES] : [GMTheme secondaryText];
    c.time.frame = CGRectMake(cx + inner - tw, h - kPadY - 13 - rh, tw, 13);
    [self fillChips:c msg:m tint:out ? [GMTheme bubbleTime:YES] : [GMTheme accent] plain:NO
                 at:CGPointMake(cx, h - kPadY - chips.height) in:c.bubble];
    // Nút dưới tin của bot: ngay dưới bong bóng, rộng ít nhất ~260 điểm
    CGFloat aw = MAX(w - t, MIN([self maxBubbleW] - t, 260));
    [self fillButtons:c msg:m area:CGRectMake(out ? x + w - t - aw : x + t, 1 + h + 4, aw, kh - 4)];
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
