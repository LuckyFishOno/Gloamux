#include "LocalPTY.h"
#include <util.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <pthread.h>
static void *reap(void *value) { int pid = (int)(long)value; while (waitpid(pid, 0, 0) < 0 && errno == EINTR) {} return 0; }
int gloamux_spawn(const char *shell, const char *directory, int rows, int columns, int *descriptor) {
    struct winsize size = { .ws_row = rows, .ws_col = columns };
    int pid = forkpty(descriptor, 0, 0, &size);
    if (pid == 0) {
        chdir(directory);
        setenv("TERM", "xterm-256color", 1);
        setenv("COLORTERM", "truecolor", 1);
        execl(shell, shell, "-l", "-i", (char *)0);
        _exit(127);
    }
    if (pid > 0) { fcntl(*descriptor, F_SETFD, FD_CLOEXEC); pthread_t thread; if (pthread_create(&thread, 0, reap, (void *)(long)pid) == 0) pthread_detach(thread); }
    return pid;
}
/// Runs `path` with `arguments` (argv, NULL-terminated) on a new PTY in `directory`, after setting each
/// `KEY=VALUE` in `environment` (NULL-terminated). Used for login shells with shell integration and for
/// container sessions started through the user's shell.
int gloamux_spawn_command(const char *path, char *const arguments[], const char *directory, char *const environment[],
                         int rows, int columns, int *descriptor) {
    struct winsize size = { .ws_row = rows, .ws_col = columns };
    int pid = forkpty(descriptor, 0, 0, &size);
    if (pid == 0) {
        if (chdir(directory) != 0) chdir("/");
        setenv("TERM", "xterm-256color", 1);
        setenv("COLORTERM", "truecolor", 1);
        for (int i = 0; environment && environment[i]; i++) putenv(environment[i]);
        execv(path, arguments);
        _exit(127);
    }
    if (pid > 0) { fcntl(*descriptor, F_SETFD, FD_CLOEXEC); pthread_t thread; if (pthread_create(&thread, 0, reap, (void *)(long)pid) == 0) pthread_detach(thread); }
    return pid;
}
void gloamux_resize(int descriptor, int rows, int columns) {
    struct winsize size = { .ws_row = rows, .ws_col = columns };
    ioctl(descriptor, TIOCSWINSZ, &size);
}
void gloamux_stop(int pid) { if (pid > 0) { kill(-pid, SIGHUP); kill(pid, SIGHUP); } }
