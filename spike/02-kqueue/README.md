# Spike 02 — vì sao tokio «không thức» trên iOS 5 / 6 (D8 → D12)

`kqtest2.c` so bốn cách đánh thức một luồng đang chờ `kevent()` (mỗi cách một kqueue mới, chờ tối đa 3 giây):

| Cách | iPhone 5 iOS 6.1.4 | iPad 1 iOS 5.1.1 |
| --- | --- | --- |
| A. đăng ký `EVFILT_USER` (EV_ADD\|EV_CLEAR) trước, kích `NOTE_TRIGGER` sau | thức 301 ms | thức 318 ms |
| B. **mio 1.x**: một lệnh `EV_ADD\|EV_ONESHOT` + `NOTE_TRIGGER` từ luồng khác | **không thức** | **không thức** |
| C. như B nhưng kích trước khi chờ | không thức | không thức |
| D. pipe (`EVFILT_READ`) | thức 301 ms | thức 313 ms |

Nhân iOS 5 / 6 không kích sự kiện `EVFILT_USER` được thêm và kích cùng một lệnh. mio 1.x đánh thức tokio trên Apple đúng
bằng cách B → runtime ngủ tới khi có bộ hẹn giờ hết hạn. (`tools/kqtest` của Côn Bằng TV chỉ thử cách A nên tưởng kqueue chạy
đúng.) Sửa: dựng với `--cfg mio_unsupported_force_waker_pipe` (`tools/rust/cargo-ios6.sh`) → mio đánh thức bằng pipe (cách D).

```sh
# trên máy dựng
clang -target armv7-apple-ios5.0 -isysroot $SDK -mcpu=cortex-a8 -O2 spike/02-kqueue/kqtest2.c -o kqtest2 && ldid -S -Hsha1 kqtest2
```
