#import <Foundation/Foundation.h>

/// Chỉ có trong bản thử (DEBUG): đọc lệnh từ /var/mobile/Documents/GramMini-cmd.txt (mỗi dòng một lệnh, đọc xong xoá
/// tệp) để thử app qua SSH — kèm `cbscreen` chụp màn hình. Lệnh:
///   open <hàng>        mở chat ở hàng thứ n (0 = đầu)
///   back               quay lại màn trước
///   send <chữ>         gửi tin trong chat đang mở
///   tapmsg <k>         chạm tin thứ k tính từ dưới (0 = mới nhất) — mở link / proxy
///   copymsg <k>        sao chép tin thứ k tính từ dưới
///   menumsg <k>        hiện menu nhấn giữ của tin thứ k
///   replymsg <k>       trả lời tin thứ k (hiện khung trả lời)
///   forward <k> <peer> chuyển tiếp tin thứ k tới peer
///   type <chữ>         gõ vào ô nhập (\n = xuống dòng)
///   reload             tải lại danh sách chat
///   dump               ghi khung các view của màn đang mở vào app.log
///   sendphotofile <p>  gửi ảnh JPEG có sẵn trên máy vào chat đang mở
///   sendvoicefile <p>  gửi tin thoại từ tệp WAV có sẵn
///   playvoice <k>      phát / dừng tin thoại thứ k tính từ dưới
///   dismiss            đóng màn đang phủ (trình xem ảnh…)
///   sendfile <p> [mime] gửi tệp có sẵn (mp4 → video)
///   opendoc <k>        mở tệp / video thứ k tính từ dưới
///   recstart | recstop ghi âm như giữ / thả nút mic (thả = gửi)
///   settings | proxy   mở Cài đặt / Proxy
///   scroll top|bottom  cuộn bảng đang hiện
/// Kết quả ghi vào app.log («[thử] …»).
@interface GMDebug : NSObject
+ (void)start;
@end
