#import <UIKit/UIKit.h>

/// Khung gợi ý trên ô nhập khi gõ «/»: lệnh của bot («/start — Bắt đầu») và tin nhắn nhanh («/chao — Chào anh…»). Mỗi mục
/// `{t: dòng chính, d: dòng phụ, kind: cmd | quick | add, v: giá trị}`.
@interface GMSuggestView : UIView <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSArray *items;
@property (nonatomic, copy) void (^pick)(NSDictionary *item);
/// Cao vừa đủ (tối đa 4 dòng).
- (CGFloat)wantedHeight;
@end
