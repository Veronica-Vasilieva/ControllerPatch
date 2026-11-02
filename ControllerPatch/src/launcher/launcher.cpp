// ControllerPatch - WoW launcher (GUI subsystem, zero-arg)
//
// For non-technical users: double-click. Finds Wow.exe and
// ControllerPatch.dll in its own folder, launches Wow suspended, injects
// the DLL, resumes. No command line. No console. On error, shows a message
// box.
//
// Must be built x86 (same bitness as Wow.exe 3.3.5a) so our kernel32
// addresses line up.

#include <windows.h>
#include <stdio.h>
#include <string.h>

static void die(const char* step, DWORD err, HANDLE hToKill = nullptr) {
    char buf[512];
    if (err) {
        _snprintf_s(buf, sizeof(buf), _TRUNCATE,
            "ControllerPatch launcher could not start World of Warcraft.\n\n"
            "Step: %s\n"
            "Windows error: %lu (0x%08lx)",
            step, err, err);
    } else {
        _snprintf_s(buf, sizeof(buf), _TRUNCATE,
            "ControllerPatch launcher could not start World of Warcraft.\n\n"
            "%s", step);
    }
    if (hToKill) TerminateProcess(hToKill, 1);
    MessageBoxA(nullptr, buf, "ControllerPatch - Launch Failed",
                MB_OK | MB_ICONERROR);
}

// Replace the trailing filename in `path` with `name` (in-place).
static void swap_filename(char* path, const char* name) {
    char* last = strrchr(path, '\\');
    if (!last) last = strrchr(path, '/');
    if (last) *(last + 1) = '\0';
    strcat_s(path, MAX_PATH, name);
}

int WINAPI WinMain(HINSTANCE, HINSTANCE, LPSTR, int) {
    char self[MAX_PATH];
    if (!GetModuleFileNameA(nullptr, self, MAX_PATH)) {
        die("GetModuleFileNameA(self)", GetLastError());
        return 1;
    }

    char dll[MAX_PATH], wow[MAX_PATH], exeDir[MAX_PATH];
    strcpy_s(dll, self); swap_filename(dll, "ControllerPatch.dll");
    strcpy_s(wow, self); swap_filename(wow, "Wow.exe");

    if (GetFileAttributesA(dll) == INVALID_FILE_ATTRIBUTES) {
        char msg[768];
        _snprintf_s(msg, sizeof(msg), _TRUNCATE,
            "ControllerPatch.dll was not found next to this launcher.\n\n"
            "Expected at:\n%s\n\n"
            "Please make sure ControllerPatch.dll is in the same folder as\n"
            "this launcher.", dll);
        die(msg, 0);
        return 2;
    }
    if (GetFileAttributesA(wow) == INVALID_FILE_ATTRIBUTES) {
        char msg[768];
        _snprintf_s(msg, sizeof(msg), _TRUNCATE,
            "Wow.exe was not found next to this launcher.\n\n"
            "Expected at:\n%s\n\n"
            "Place this launcher in your WoW folder (where Wow.exe lives)\n"
            "and try again.", wow);
        die(msg, 0);
        return 3;
    }

    // Working directory = Wow.exe's folder (so patch files, Data, Interface
    // etc. resolve relative to it).
    strcpy_s(exeDir, wow);
    char* lastSlash = strrchr(exeDir, '\\');
    if (lastSlash) *lastSlash = '\0';

    STARTUPINFOA si{ sizeof(si) };
    PROCESS_INFORMATION pi{};
    if (!CreateProcessA(wow, nullptr, nullptr, nullptr, FALSE,
                        CREATE_SUSPENDED, nullptr, exeDir, &si, &pi)) {
        die("CreateProcessA(Wow.exe)", GetLastError());
        return 4;
    }

    SIZE_T dllPathBytes = strlen(dll) + 1;
    LPVOID remote = VirtualAllocEx(pi.hProcess, nullptr, dllPathBytes,
                                   MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!remote) {
        die("VirtualAllocEx (writing DLL path into Wow)",
            GetLastError(), pi.hProcess);
        return 5;
    }
    if (!WriteProcessMemory(pi.hProcess, remote, dll, dllPathBytes, nullptr)) {
        die("WriteProcessMemory (writing DLL path into Wow)",
            GetLastError(), pi.hProcess);
        return 6;
    }

    HMODULE k32 = GetModuleHandleA("kernel32.dll");
    FARPROC loadLib = k32 ? GetProcAddress(k32, "LoadLibraryA") : nullptr;
    if (!loadLib) {
        die("GetProcAddress(LoadLibraryA)", GetLastError(), pi.hProcess);
        return 7;
    }

    HANDLE hRemote = CreateRemoteThread(
        pi.hProcess, nullptr, 0, (LPTHREAD_START_ROUTINE)loadLib,
        remote, 0, nullptr);
    if (!hRemote) {
        die("CreateRemoteThread (injecting ControllerPatch.dll)",
            GetLastError(), pi.hProcess);
        return 8;
    }

    WaitForSingleObject(hRemote, 10000);
    DWORD injectResult = 0;
    GetExitCodeThread(hRemote, &injectResult);
    CloseHandle(hRemote);
    VirtualFreeEx(pi.hProcess, remote, 0, MEM_RELEASE);

    if (injectResult == 0) {
        die("LoadLibraryA inside Wow.exe returned NULL\n(the DLL loaded "
            "but reported failure - check for errors in ControllerPatch.log)",
            0, pi.hProcess);
        return 9;
    }

    ResumeThread(pi.hThread);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return 0;
}
