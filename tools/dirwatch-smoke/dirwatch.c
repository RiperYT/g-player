// File change notification smoke test: watches a new folder with ReadDirectoryChangesW (overlapped, as launchers do),
// creates a file in it and expects to hear about it within five seconds. Prints one line per step and exits 0 when the
// notification came. Checks an engine's wineserver (it needs libinotify on macOS) without a launcher:
//   x86_64-w64-mingw32-gcc -O1 -o dirwatch.exe dirwatch.c   (and i686-…)
//   WINEPREFIX=… arch -x86_64 wine 'C:\t\dirwatch.exe'
#include <windows.h>
#include <stdio.h>

static int fail(const char *step) { printf("FAIL %s (error %lu)\n", step, GetLastError()); fflush(stdout); return 1; }

int main(void) {
    char dir[MAX_PATH], file[MAX_PATH];
    GetTempPathA(MAX_PATH, dir);
    lstrcatA(dir, "gplayer-dirwatch");
    CreateDirectoryA(dir, NULL);
    HANDLE h = CreateFileA(dir, FILE_LIST_DIRECTORY, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                           OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, NULL);
    if (h == INVALID_HANDLE_VALUE) return fail("open folder");
    printf("OK   watching %s\n", dir); fflush(stdout);

    DWORD buffer[1024];
    OVERLAPPED ov = {0};
    ov.hEvent = CreateEventA(NULL, TRUE, FALSE, NULL);
    if (!ReadDirectoryChangesW(h, buffer, sizeof(buffer), FALSE, FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_LAST_WRITE,
                               NULL, &ov, NULL)) return fail("ReadDirectoryChangesW");

    wsprintfA(file, "%s\\file-%lu.txt", dir, GetTickCount());
    HANDLE f = CreateFileA(file, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    if (f == INVALID_HANDLE_VALUE) return fail("create file");
    DWORD written;
    WriteFile(f, "x", 1, &written, NULL);
    CloseHandle(f);
    printf("OK   created a file\n"); fflush(stdout);

    if (WaitForSingleObject(ov.hEvent, 5000) != WAIT_OBJECT_0) {
        printf("FAIL no notification within 5 s\n"); fflush(stdout);
        DeleteFileA(file);
        return 1;
    }
    DWORD got = 0;
    if (!GetOverlappedResult(h, &ov, &got, FALSE)) return fail("GetOverlappedResult");
    FILE_NOTIFY_INFORMATION *n = (FILE_NOTIFY_INFORMATION *)buffer;
    printf("OK   notified: action %lu, %lu bytes\n", n->Action, got); fflush(stdout);
    DeleteFileA(file);
    CloseHandle(h);
    return 0;
}
