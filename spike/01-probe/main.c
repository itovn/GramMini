// gm-probe — chạy thử lõi GramMini trên iOS 5 / 6 qua SSH (công cụ dòng lệnh, chưa có giao diện):
//   gm-probe probe [--dc 1-5] [--proxy "tg://proxy?server=…&port=…&secret=…"]
// Lõi Rust (crate gm-cli, dựng thành thư viện tĩnh) làm hết; tệp này chỉ chuyển đối số.
#include <stdio.h>

extern int gm_cli_main(int argc, const char *const *argv);

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);  // in từng dòng khi chạy qua SSH
    return gm_cli_main(argc, (const char *const *)argv);
}
