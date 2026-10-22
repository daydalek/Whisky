// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <sys/types.h>
#include <stdint.h>

typedef struct {
    pid_t pid;
    int output;
} whisky_host_child;

int whisky_host_spawn(const char *executable, char *const arguments[], char *const environment[], whisky_host_child *child);
int whisky_host_poll(pid_t pid, int *status, int *signalled);
void whisky_host_stop(pid_t pid);

// Moves a path only when the destination is absent; returns an errno value.
int whisky_host_move(const char *source, const char *destination);

// lstat identity: kind is 1 for a directory, 2 for a regular file, 0 otherwise.
int whisky_host_identity(const char *path, uint64_t *device, uint64_t *inode, int *kind);
