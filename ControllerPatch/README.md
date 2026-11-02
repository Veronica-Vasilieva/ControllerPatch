# ControllerPatch

Native controller support for World of Warcraft 3.3.5a (build 12340). Fan project — check with your server's rules before using on anything other than your own private server.

> **Status**: v0 prototype. Validates injection + XInput polling. No gameplay/Lua integration yet.

## Prerequisites

- Windows 10/11 x64
- Visual Studio 2022 Community or Build Tools with the "C++ x86/x64 build tools" workload
- Windows 10 SDK 10.0.22621.0 (newer SDKs may be missing x86 libs — the build pins to this version)
- An XInput-compatible controller (Xbox pad or clone)
- A WotLK 3.3.5a 12340 client with SHA-256 `aa63a5750d60ef16746c686b3d5e26876d98953eab08b1c026cd0faf78e88cb8`

## Build

```powershell
.\build.ps1
```

Produces `build\ControllerPatch.dll` and `build\ControllerPatchLoader.exe` (both x86).

## Run (prototype test)

From this folder:

```powershell
.\build\ControllerPatchLoader.exe .\build\ControllerPatch.dll "E:\Documents\TheShrineWOW\Wow.exe"
```

The loader:
1. Starts `Wow.exe` suspended
2. Injects `ControllerPatch.dll` via `CreateRemoteThread` → `LoadLibraryA`
3. Resumes the game

The game runs normally. Everything the DLL does happens in the background.

### What to expect

1. `Wow.exe` starts normally, you reach the login screen
2. A `ControllerPatch.log` file appears next to `Wow.exe`
3. Press buttons on your Xbox controller — each press/release shows up as a line in the log
4. Nudge the sticks past the deadzone — those show up too

Example log output:

```
20:14:03.511 ControllerPatch DLL attached (pid=24680, built Oct 31 2026 ...)
20:14:03.513 [poller] started tid=18292
20:14:03.515 [pad0] connected
20:14:07.922 [pad0] button DOWN A
20:14:08.014 [pad0] button UP   A
20:14:09.188 [pad0] L stick (-28134, 7812)
20:14:11.302 [pad0] LT=174
20:14:11.330 [pad0] LT=255
```

If you see those lines, injection works and we can move on to the Lua integration phase.

### Troubleshooting

- **`DLL not found`** — pass an absolute path to the DLL, or run the loader from this folder so the relative path works.
- **`LoadLibraryA returned NULL`** — the DLL has an unresolved import. Open `ControllerPatch.dll` with Dependencies (`https://github.com/lucasg/Dependencies`) to see which. Prebuilt x86 Windows runtimes should be enough; the DLL is `/MT`-linked so no VC++ runtime is required in the target.
- **Log file never appears** — the DLL loaded but `CreateFileA` failed (permissions). Check the game dir is writable; try moving `Wow.exe` out of `Program Files`.
- **Log appears but no controller events** — `XInputGetState` returns `ERROR_DEVICE_NOT_CONNECTED` for pad 0. Plug the pad in BEFORE launching, or press the Xbox button to wake it. If still nothing, we try `XInputGetStateEx` (undocumented, exposes the Xbox Guide button) in the next iteration.

## File layout

```
ControllerPatch/
├── README.md              This file
├── RECON.md               Binary analysis notes with hook-site addresses
├── wow-12340.ghidra-snapshot   REA/Ghidra analysis snapshot (resumable)
├── build.ps1              Build driver
├── build/                 (gitignored) build output
└── src/
    ├── dll/dllmain.cpp    The injected DLL
    ├── loader/inject.cpp  CreateRemoteThread injector
    └── include/           (reserved for shared headers)
```

## What's next

See `RECON.md` section 9 — the proximate steps are the main-loop hook (so we can run on the game's main thread) and the Lua registration (so an addon can bind to `GAMEPAD_*` events). The current DLL only validates that injection + XInput polling works end-to-end.
