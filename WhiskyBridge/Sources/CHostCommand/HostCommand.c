// SPDX-License-Identifier: GPL-3.0-or-later
#include "HostCommand.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

int whisky_host_spawn(const char *executable, char *const arguments[], char *const environment[], whisky_host_child *child) {
    int descriptors[2];
    if (pipe(descriptors) != 0) return errno;
    int error = 0;
    if (fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(descriptors[0], F_SETFL, O_NONBLOCK) < 0) {
        error = errno;
        goto cleanup;
    }
    posix_spawn_file_actions_t actions;
    error = posix_spawn_file_actions_init(&actions);
    if (error) goto cleanup;
    error = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO);
    if (!error) error = posix_spawn_file_actions_addclose(&actions, descriptors[0]);
    if (!error) error = posix_spawn_file_actions_addclose(&actions, descriptors[1]);
    if (!error) error = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    // Swift executor threads can block termination signals. Give the host tool
    // its own normal mask and dispositions, including parent-death SIGTERM.
    posix_spawnattr_t attributes;
    int attribute_error = posix_spawnattr_init(&attributes);
    if (!error) error = attribute_error;
    if (!attribute_error) {
        sigset_t mask, defaults;
        sigemptyset(&mask);
        sigemptyset(&defaults);
        sigaddset(&defaults, SIGTERM);
        sigaddset(&defaults, SIGINT);
        sigaddset(&defaults, SIGHUP);
        sigaddset(&defaults, SIGPIPE);
        if (!error) error = posix_spawnattr_setsigmask(&attributes, &mask);
        if (!error) error = posix_spawnattr_setsigdefault(&attributes, &defaults);
        if (!error) error = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
    }
    pid_t pid = 0;
    if (!error) error = posix_spawn(&pid, executable, &actions, &attributes, arguments, environment);
    if (!attribute_error) posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    if (!error) {
        close(descriptors[1]);
        child->pid = pid;
        child->output = descriptors[0];
        return 0;
    }
cleanup:
    close(descriptors[0]);
    close(descriptors[1]);
    return error;
}

int whisky_host_poll(pid_t pid, int *status, int *signalled) {
    int value = 0;
    pid_t result = waitpid(pid, &value, WNOHANG);
    if (result == 0 || (result < 0 && errno == EINTR)) return 0;
    if (result < 0) return -errno;
    *signalled = WIFSIGNALED(value);
    *status = *signalled ? WTERMSIG(value) : WEXITSTATUS(value);
    return 1;
}

void whisky_host_stop(pid_t pid) {
    int status = 0, signalled = 0;
    if (pid <= 0 || whisky_host_poll(pid, &status, &signalled) != 0) return;
    kill(pid, SIGTERM);
    const struct timespec delay = {0, 10000000};
    for (int count = 0; count < 50; count++) {
        if (whisky_host_poll(pid, &status, &signalled) != 0) return;
        nanosleep(&delay, NULL);
    }
    kill(pid, SIGKILL);
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
}

#if defined(__linux__)
#include <sys/syscall.h>
#include <linux/fs.h>
#elif defined(__APPLE__)
#include <stdio.h>
#endif

int whisky_host_move(const char *source, const char *destination) {
#if defined(__linux__)
    if (syscall(SYS_renameat2, AT_FDCWD, source, AT_FDCWD, destination, RENAME_NOREPLACE) == 0) return 0;
#elif defined(__APPLE__)
    if (renamex_np(source, destination, RENAME_EXCL) == 0) return 0;
#else
    return ENOTSUP;
#endif
    return errno;
}

#include <sys/stat.h>
int whisky_host_identity(const char *path, uint64_t *device, uint64_t *inode, int *kind) {
    struct stat info;
    if (lstat(path, &info) != 0) return errno;
    *device = (uint64_t)info.st_dev;
    *inode = (uint64_t)info.st_ino;
    *kind = S_ISDIR(info.st_mode) ? 1 : S_ISREG(info.st_mode) ? 2 : 0;
    return 0;
}
