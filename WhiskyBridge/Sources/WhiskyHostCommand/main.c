// SPDX-License-Identifier: GPL-3.0-or-later
// A Linux supervisor ties an owned process group to its Swift bridge parent.
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <unistd.h>

static void terminate_group(int signal_number) {
    (void)signal_number;
    // This process remains the group's leader, preventing group-ID reuse.
    kill(-getpid(), SIGKILL);
    _exit(128 + SIGTERM);
}

int main(int argc, char **argv) {
    if (argc < 3) return 2;
    char *end = NULL;
    long expected_parent = strtol(argv[1], &end, 10);
    if (!end || *end || expected_parent <= 1 || getppid() != expected_parent) return 2;
    if (setpgid(0, 0) != 0 || getpgrp() != getpid()) return 2;
    struct sigaction action = {0};
    action.sa_handler = terminate_group;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, NULL) != 0 || sigaction(SIGINT, &action, NULL) != 0 ||
        sigaction(SIGHUP, &action, NULL) != 0 || prctl(PR_SET_PDEATHSIG, SIGTERM) != 0) return 2;
    if (getppid() != expected_parent) terminate_group(SIGTERM);
    pid_t supervisor = getpid();
    pid_t child = fork();
    if (child < 0) return 2;
    if (child == 0) {
        signal(SIGTERM, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() != supervisor) _exit(2);
        execv(argv[2], argv + 2);
        _exit(127);
    }
    int status = 0;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) terminate_group(SIGTERM);
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
