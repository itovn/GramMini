#import <UIKit/UIKit.h>
#import <QuickLook/QuickLook.h>

/// Màn chat kiểu Telegram 4.9: bong bóng có đuôi (gom theo người gửi), giờ + ✓✓ trong bong bóng, vạch ngày, tin hệ thống,
/// trích dẫn tin được trả lời. Nhấn giữ: Trả lời / Sao chép / Chuyển tiếp / Sửa / Xoá. Chạm tin có link: link proxy → màn Proxy (điền
/// sẵn, tự thử); link web → Safari. Tải thêm tin cũ khi cuộn lên; tin mới / sửa / xoá / đã đọc cập nhật trực tiếp.
@interface GMChatViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextViewDelegate,
                                                    UIActionSheetDelegate, UIImagePickerControllerDelegate,
                                                    UINavigationControllerDelegate, QLPreviewControllerDataSource>
@property (nonatomic, copy) NSString *peer;
@property (nonatomic, copy) NSString *kind;  // user / group / channel
@property (nonatomic, copy) NSString *myId;
/// Tin của mình có id ≤ số này: bên kia đã đọc (✓✓).
@property (nonatomic) NSInteger readOut;
/// Mở chat rồi nhảy tới tin này (kết quả tìm tin): tải dần tin cũ tới khi gặp, cuộn tới, tô sáng.
@property (nonatomic, strong) NSNumber *jumpTo;
/// Ảnh đại diện (khoá ảnh + DC, từ danh sách chat) — hiện bên phải thanh trên; không có thì ảnh chữ cái.
@property (nonatomic, strong) id photo;
@property (nonatomic, strong) NSNumber *photoDc;
/// Nhóm diễn đàn: chỉ hiện / gửi tin của chủ đề này (General = 1); nil = mọi tin của chat. Tiêu đề = tên chủ đề, dòng phụ =
/// tên nhóm (`groupName`), ảnh bên phải = biểu tượng chủ đề (màu `topicColor`).
@property (nonatomic, strong) NSNumber *topic;
@property (nonatomic) NSInteger topicColor;
@property (nonatomic, copy) NSString *groupName;
/// Công cụ thử: không đánh dấu đã đọc (xem chat thật mà không đổi trạng thái đọc của tài khoản).
+ (void)setDebugNoRead:(BOOL)on;
/// Tệp đang xem bằng QuickLook.
@property (nonatomic, strong) id<QLPreviewItem> previewItem;
/// Gửi tin (công cụ thử).
- (void)sendText:(NSString *)text;
/// Công cụ thử: chạm / sao chép / mở menu tin thứ k tính từ dưới lên (0 = tin mới nhất).
- (void)debugTapFromBottom:(NSInteger)k;
- (void)debugCopyFromBottom:(NSInteger)k;
- (void)debugMenuFromBottom:(NSInteger)k;
- (void)debugReplyFromBottom:(NSInteger)k;
- (void)debugForwardFromBottom:(NSInteger)k to:(NSString *)peer;
- (void)debugPlayVoiceFromBottom:(NSInteger)k;
- (void)debugOpenDocFromBottom:(NSInteger)k;
- (void)debugSaveFromBottom:(NSInteger)k;
/// Công cụ thử: xoá tin thứ k từ dưới lên — revoke NO = chỉ ở máy tôi.
- (void)debugDeleteFromBottom:(NSInteger)k revoke:(BOOL)revoke;
/// Công cụ thử: xoá tin hệ thống thứ k từ dưới lên (vd «… đã tắt tự xoá tin» do lệnh thử tạo).
- (void)debugDeleteServiceFromBottom:(NSInteger)k;
/// Gửi ảnh (JPEG) / tin thoại (WAV) từ tệp có sẵn.
- (void)sendPhotoFile:(NSString *)path;
- (void)sendVoiceFile:(NSString *)path;
/// Công cụ thử: mở trình chọn tệp; gửi video có sẵn (qua bước nén như video từ thư viện).
- (void)debugOpenFiles;
- (void)debugSendVideo:(NSString *)path;
/// Mở màn thông tin chat (như chạm tên ở đầu màn).
- (void)showInfo;
/// Gỡ lỗi: «» mở / đóng bảng sticker; «tab i»; «pick i» (gửi sticker thứ i của thẻ đang mở).
- (void)debugStickers:(NSString *)arg;
/// Gỡ lỗi: ghi trạng thái các GIF đang chạy.
- (void)debugGifs;
@end
