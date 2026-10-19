#include <windows.h>
#include <stdio.h>
#include <string.h>

/* Stay alive so the Manager job object owns the HTTP process. */
int main(void) {
    wchar_t dir[MAX_PATH];
    wchar_t ps1[MAX_PATH];
    wchar_t cmd[32768];
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    int argc = 0;
    int i;
    int n;
    DWORD code = 1;
    LPWSTR *argv;

    if (!GetModuleFileNameW(NULL, dir, MAX_PATH)) return 1;
    {
        wchar_t *slash = wcsrchr(dir, L'\\');
        if (slash) *slash = 0;
    }
    _snwprintf(ps1, MAX_PATH, L"%s\\rk_flash_server.ps1", dir);

    {
        wchar_t root[MAX_PATH];
        if (!GetEnvironmentVariableW(L"SystemRoot", root, MAX_PATH))
            wcscpy(root, L"C:\\Windows");
        n = _snwprintf(cmd, 32768,
                       L"\"%s\\System32\\WindowsPowerShell\\v1.0\\powershell.exe\" "
                       L"-NoProfile -ExecutionPolicy Bypass -File \"%s\"",
                       root, ps1);
    }
    argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (argv) {
        for (i = 1; i < argc && n > 0 && n < 32000; i++)
            n += _snwprintf(cmd + n, (size_t)(32768 - n), L" \"%s\"", argv[i]);
        LocalFree(argv);
    }

    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));
    if (!CreateProcessW(NULL, cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, dir, &si, &pi))
        return 1;
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return (int)code;
}
