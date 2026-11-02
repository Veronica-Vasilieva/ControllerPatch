// ControllerPatch - loader / injector
//
// Two modes:
//   loader.exe <dll> <wow.exe>   -- start Wow.exe suspended, inject, resume
//   loader.exe <dll>             -- find a running Wow.exe and inject
//
// Both loader and target must be x86. kernel32.dll's LoadLibraryA address is
// resolved via a same-bitness GetModuleHandle in this process (OK because
// Windows loads kernel32 at a session-stable base across x86 processes).

#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <string.h>

static int fail(const char* step, DWORD err) {
    fprintf(stderr, "%s failed: %lu (0x%08lx)\n", step, err, err);
    return 1;
}

static DWORD find_pid_by_name(const char* name) {
    DWORD pid = 0;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;
    PROCESSENTRY32 pe{ sizeof(pe) };
    if (Process32First(snap, &pe)) {
        do {
            if (_stricmp(pe.szExeFile, name) == 0) {
                pid = pe.th32ProcessID;
                break;
            }
        } while (Process32Next(snap, &pe));
    }
    CloseHandle(snap);
    return pid;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr,
            "Usage:\n"
            "  %s <ControllerPatch.dll> <path\\to\\Wow.exe>   # launch and inject\n"
            "  %s <ControllerPatch.dll>                        # inject into running Wow.exe\n",
            argv[0], argv[0]);
        return 2;
    }

    char dll_abs[MAX_PATH];
    if (!GetFullPathNameA(argv[1], MAX_PATH, dll_abs, nullptr))
        return fail("GetFullPathNameA(dll)", GetLastError());
    if (GetFileAttributesA(dll_abs) == INVALID_FILE_ATTRIBUTES) {
        fprintf(stderr, "DLL not found: %s\n", dll_abs);
        return 3;
    }
    printf("DLL: %s\n", dll_abs);

    HANDLE hProc = nullptr;
    HANDLE hResumeThread = nullptr;
    DWORD  pid = 0;

    if (argc >= 3) {
        char exe_abs[MAX_PATH];
        if (!GetFullPathNameA(argv[2], MAX_PATH, exe_abs, nullptr))
            return fail("GetFullPathNameA(exe)", GetLastError());

        char exe_dir[MAX_PATH];
        strcpy_s(exe_dir, exe_abs);
        char* last = strrchr(exe_dir, '\\');
        if (last) *last = '\0';

        STARTUPINFOA si{ sizeof(si) };
        PROCESS_INFORMATION pi{};
        if (!CreateProcessA(exe_abs, nullptr, nullptr, nullptr, FALSE,
                            CREATE_SUSPENDED, nullptr, exe_dir, &si, &pi))
            return fail("CreateProcessA", GetLastError());
        hProc = pi.hProcess;
        hResumeThread = pi.hThread;
        pid = pi.dwProcessId;
        printf("Started %s (pid=%lu, suspended)\n", exe_abs, pid);
    } else {
        pid = find_pid_by_name("Wow.exe");
        if (pid == 0) {
            fprintf(stderr, "No running Wow.exe found; pass the exe path to launch one.\n");
            return 4;
        }
        hProc = OpenProcess(
            PROCESS_CREATE_THREAD | PROCESS_VM_OPERATION |
            PROCESS_VM_WRITE | PROCESS_VM_READ | PROCESS_QUERY_INFORMATION,
            FALSE, pid);
        if (!hProc) return fail("OpenProcess", GetLastError());
        printf("Attaching to running Wow.exe (pid=%lu)\n", pid);
    }

    const SIZE_T path_bytes = strlen(dll_abs) + 1;
    LPVOID remote = VirtualAllocEx(hProc, nullptr, path_bytes,
                                   MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!remote) {
        DWORD e = GetLastError();
        if (hResumeThread) TerminateProcess(hProc, 1);
        return fail("VirtualAllocEx", e);
    }
    if (!WriteProcessMemory(hProc, remote, dll_abs, path_bytes, nullptr)) {
        DWORD e = GetLastError();
        if (hResumeThread) TerminateProcess(hProc, 1);
        return fail("WriteProcessMemory", e);
    }

    HMODULE k32 = GetModuleHandleA("kernel32.dll");
    FARPROC loadLib = k32 ? GetProcAddress(k32, "LoadLibraryA") : nullptr;
    if (!loadLib) {
        if (hResumeThread) TerminateProcess(hProc, 1);
        return fail("GetProcAddress(LoadLibraryA)", GetLastError());
    }

    HANDLE hRemote = CreateRemoteThread(
        hProc, nullptr, 0, (LPTHREAD_START_ROUTINE)loadLib, remote, 0, nullptr);
    if (!hRemote) {
        DWORD e = GetLastError();
        if (hResumeThread) TerminateProcess(hProc, 1);
        return fail("CreateRemoteThread", e);
    }

    WaitForSingleObject(hRemote, 10000);
    DWORD exitCode = 0;
    GetExitCodeThread(hRemote, &exitCode);
    CloseHandle(hRemote);
    VirtualFreeEx(hProc, remote, 0, MEM_RELEASE);

    if (exitCode == 0) {
        fprintf(stderr, "LoadLibraryA returned NULL in target process.\n");
        if (hResumeThread) TerminateProcess(hProc, 1);
        return 5;
    }
    printf("DLL injected (HMODULE 0x%08lx in pid %lu)\n", exitCode, pid);

    if (hResumeThread) {
        ResumeThread(hResumeThread);
        CloseHandle(hResumeThread);
        printf("Target resumed.\n");
    }
    CloseHandle(hProc);
    return 0;
}
