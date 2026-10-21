/*
 * WhiskyProcessSnapshot: Unicode Windows process names for Wine lifecycle observation.
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * This file is part of Whisky. See LICENSE for the GNU General Public License.
 */
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <tlhelp32.h>

static BOOL write_bytes(HANDLE output, const char *bytes, DWORD count)
{
    while (count) {
        DWORD written = 0;
        if (!WriteFile(output, bytes, count, &written, NULL) || !written) return FALSE;
        bytes += written;
        count -= written;
    }
    return TRUE;
}

static BOOL write_name(HANDLE output, const WCHAR *name)
{
    int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, name, -1, NULL, 0, NULL, NULL);
    if (count <= 0) return FALSE;
    char *text = HeapAlloc(GetProcessHeap(), 0, (SIZE_T)count);
    if (!text) return FALSE;
    char *escaped = HeapAlloc(GetProcessHeap(), 0, (SIZE_T)count * 2);
    if (!escaped) { HeapFree(GetProcessHeap(), 0, text); return FALSE; }
    BOOL success = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, name, -1, text, count, NULL, NULL) > 0;
    DWORD length = 0;
    for (int index = 0; success && index < count - 1; ++index) {
        escaped[length++] = text[index];
        if (text[index] == '"') escaped[length++] = '"';
    }
    if (success) success = write_bytes(output, escaped, length);
    HeapFree(GetProcessHeap(), 0, escaped);
    HeapFree(GetProcessHeap(), 0, text);
    return success;
}

static BOOL write_pid(HANDLE output, DWORD pid)
{
    char reversed[16], digits[16];
    unsigned int count = 0;
    do { reversed[count++] = (char)('0' + pid % 10); pid /= 10; } while (pid);
    for (unsigned int index = 0; index < count; ++index) digits[index] = reversed[count - index - 1];
    return write_bytes(output, digits, count);
}

static int snapshot_main(void)
{
    HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return 2;
    PROCESSENTRY32W entry;
    entry.dwSize = sizeof(entry);
    if (!Process32FirstW(snapshot, &entry)) { CloseHandle(snapshot); return 3; }
    BOOL success = TRUE;
    do {
        success = write_bytes(output, "\"", 1)
            && write_name(output, entry.szExeFile)
            && write_bytes(output, "\",\"", 3)
            && write_pid(output, entry.th32ProcessID)
            && write_bytes(output, "\",\"\",\"\",\"0 K\"\r\n", 15);
        if (!success) break;
    } while (Process32NextW(snapshot, &entry));
    DWORD error = GetLastError();
    CloseHandle(snapshot);
    return success && error == ERROR_NO_MORE_FILES ? 0 : 4;
}

/* A Win32-only entry point keeps the observer independent of a game's CRT overrides. */
void mainCRTStartup(void)
{
    ExitProcess((UINT)snapshot_main());
}
