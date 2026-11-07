// Crashes on purpose under the SDK's handlers, for test-crash-handler.sh.
// Usage: crash_probe <report path> <segv|abort|trap|thread|overflow|chained|muted> <mach 0|1>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "ScruterCrash.h"

static void previous_reporter(int sig) {
    (void)sig;
    int fd = 3;
    if (write(fd, "chained\n", 8) < 0) _exit(9);
    signal(SIGSEGV, SIG_DFL);
}

__attribute__((noinline)) static void segv(void) {
    volatile int *p = (volatile int *)8;
    *p = 1;
}

__attribute__((noinline)) static int overflow(int n) {
    volatile char pad[4096];
    memset((void *)pad, n, sizeof(pad));
    return overflow(n + 1) + pad[n % 4096];
}

static void *on_thread(void *arg) {
    (void)arg;
    segv();
    return NULL;
}

static void *overflow_thread(void *arg) {
    (void)arg;
    overflow(1);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 4) return 2;
    const char *mode = argv[2];
    if (strcmp(mode, "chained") == 0) signal(SIGSEGV, previous_reporter);
    if (scruter_crash_install(argv[1], atoi(argv[3])) != 0) return 3;
    const char *ctx = "{\"s\":\"0123456789abcdef\",\"scr\":\"Payment\",\"fg\":1,\"bc\":[],\"lt\":1000}";
    scruter_crash_set_context(ctx, strlen(ctx));
    if (strcmp(mode, "muted") == 0) scruter_crash_mute(60000);
    if (strcmp(mode, "abort") == 0) abort();
    if (strcmp(mode, "trap") == 0) __builtin_trap();
    pthread_t t;
    if (strcmp(mode, "thread") == 0) {
        pthread_create(&t, NULL, on_thread, NULL);
        pthread_join(t, NULL);
    }
    if (strcmp(mode, "overflow") == 0) {
        pthread_create(&t, NULL, overflow_thread, NULL);
        pthread_join(t, NULL);
    }
    segv();
    return 0;
}
