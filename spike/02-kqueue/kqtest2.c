// kqtest2 — tìm nguyên nhân tokio «không thức» trên iOS 5 / 6 (D8). So các cách đánh thức một luồng đang chờ kevent():
//   A. đăng ký EVFILT_USER trước (EV_ADD|EV_CLEAR), luồng khác kích NOTE_TRIGGER — cách kqtest của Côn Bằng TV đã thử
//   B. cách của mio 1.x trên Apple: KHÔNG đăng ký trước; luồng khác gọi một lần EV_ADD|EV_ONESHOT + NOTE_TRIGGER
//   C. như B nhưng kích TRƯỚC khi chờ (sự kiện đã có sẵn khi gọi kevent)
//   D. pipe (EVFILT_READ) — cách mio dùng khi dựng với --cfg mio_unsupported_force_waker_pipe
// Mỗi cách một kqueue mới; chờ tối đa 3 giây. Luồng kích chờ 300 ms rồi mới kích.
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/event.h>
#include <sys/time.h>
#include <unistd.h>

static int kq;
static int pipefd[2];
static int mode;

static double now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
}

static void trigger(void) {
    struct kevent ev;
    int r;
    if (mode == 'A') {
        EV_SET(&ev, 0, EVFILT_USER, 0, NOTE_TRIGGER, 0, NULL);
        r = kevent(kq, &ev, 1, NULL, 0, NULL);
    } else if (mode == 'B' || mode == 'C') {
        EV_SET(&ev, 0, EVFILT_USER, EV_ADD | EV_ONESHOT, NOTE_TRIGGER, 0, NULL);
        r = kevent(kq, &ev, 1, NULL, 0, NULL);
    } else {
        char c = 1;
        r = (int)write(pipefd[1], &c, 1);
    }
    printf("  kích → %d%s%s\n", r, r < 0 ? " lỗi " : "", r < 0 ? strerror(errno) : "");
}

static void *later(void *arg) {
    (void)arg;
    usleep(300 * 1000);
    trigger();
    return NULL;
}

static void run(int m, const char *name) {
    mode = m;
    kq = kqueue();
    struct kevent ev;
    if (m == 'A') {
        EV_SET(&ev, 0, EVFILT_USER, EV_ADD | EV_CLEAR, 0, 0, NULL);
        kevent(kq, &ev, 1, NULL, 0, NULL);
    } else if (m == 'D') {
        pipe(pipefd);
        EV_SET(&ev, pipefd[0], EVFILT_READ, EV_ADD | EV_CLEAR, 0, 0, NULL);
        kevent(kq, &ev, 1, NULL, 0, NULL);
    }
    printf("%s\n", name);
    pthread_t th;
    if (m == 'C') {
        trigger();
    } else {
        pthread_create(&th, NULL, later, NULL);
    }
    struct kevent out;
    struct timespec ts = {3, 0};
    double t0 = now_ms();
    int n = kevent(kq, NULL, 0, &out, 1, &ts);
    printf("  kevent trả %d sau %.0f ms%s\n\n", n, now_ms() - t0,
           n > 0 ? (out.filter == EVFILT_USER ? " (EVFILT_USER)" : " (EVFILT_READ)") : "  ← KHÔNG THỨC");
    if (m != 'C') pthread_join(th, NULL);
    close(kq);
    if (m == 'D') {
        close(pipefd[0]);
        close(pipefd[1]);
    }
}

int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    run('A', "A. đăng ký trước, kích sau (Côn Bằng TV kqtest)");
    run('B', "B. mio 1.x: EV_ADD|EV_ONESHOT + NOTE_TRIGGER từ luồng khác, lúc đang chờ");
    run('C', "C. mio 1.x: EV_ADD|EV_ONESHOT + NOTE_TRIGGER trước khi chờ");
    run('D', "D. pipe (mio_unsupported_force_waker_pipe)");
    return 0;
}
