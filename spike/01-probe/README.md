# Spike 01 — lõi Rust trên máy iOS (công cụ dòng lệnh)

`gm-probe` = crate `gm-cli` (thư viện tĩnh armv7) + `main.c` + `app/Core/GMShims.c`, chạy qua SSH trên máy jailbreak:
mở kết nối tới DC (đi thẳng / MTProxy / SOCKS5), tạo auth key, ping. Mục đích: kiểm grammers + tokio + gm-net chạy trên
iOS 5 / 6 trước khi làm app.

```sh
bash spike/01-probe/build.sh                 # trên máy dựng → ../target-ios/gm-probe
# chép lên máy (vd /var/root/gm-probe), rồi:
./gm-probe probe --dc 2
./gm-probe probe --proxy "tg://proxy?server=…&port=…&secret=…"
```
