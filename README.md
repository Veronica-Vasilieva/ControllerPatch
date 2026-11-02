# ControllerPatch

Native Xbox-controller support for World of Warcraft 3.3.5a (WotLK, build 12340). An accessibility project: lets players who cannot use a keyboard and mouse play the game with a standard pad.

Built around a small injected DLL that reverse-engineers Blizzard's own Lua layer to expose a `GamePad*` API and synthesize keyboard / mouse events at the OS level, plus a companion addon that renders a hex-framed ability pad and remappable bindings.

## What's in this repo

```
├── ControllerPatch/            C++ source for the DLL, loader, launcher
│   ├── src/dll/                   ControllerPatch.dll - injected into Wow.exe
│   ├── src/loader/                ControllerPatchLoader.exe - CLI injector
│   ├── src/launcher/              Launch_WoW.exe - double-click launcher
│   ├── RECON.md                   Binary analysis notes (addresses, structures)
│   └── build.ps1                  MSVC build script (x86)
│
├── Interface/AddOns/
│   ├── ControllerPatch/         The real addon (visual HUD + config window)
│   └── ControllerPatchTest/     Diagnostic addon showing raw pad state
│
├── Launch_WoW.exe              [DEPLOYED] The friendly one-click launcher
├── ControllerPatch.dll         [DEPLOYED] The injected library
├── Wow.exe                     [NOT TRACKED] The game client itself
└── Interface/AddOns/*          [NOT TRACKED] Other addons / Blizzard UI
```

## Features

- Zero-command launcher — double-click `Launch_WoW.exe` and go
- 14 configurable pad inputs (A/B/X/Y, LB/RB, D-pad, START/BACK, L3/R3)
- Each input has a base and an LT-held modifier mapping
- Left stick → WASD with analog hysteresis
- Right stick → smooth analog mouselook (via WoW's native `MouselookStart`)
- Auto-switching UI cursor mode when a menu is open (A = click, B = ESC)
- HD glyph HUD with pad-colored A/B/X/Y, hex-shaped ability icons, cooldown sweeps
- Scrollable config GUI (`/cp config`) with click-to-rebind for every button
- SavedVariables persistence per character

## Build

Requires Visual Studio 2022 with the C++ workload and Windows 10 SDK 10.0.22621.

```
.\ControllerPatch\build.ps1
```

Produces `ControllerPatch.dll`, `ControllerPatchLoader.exe`, and `Launch_WoW.exe` in `ControllerPatch\build\`.

## Install

Copy `ControllerPatch.dll` and `Launch_WoW.exe` into the folder that holds `Wow.exe`. Copy `Interface/AddOns/ControllerPatch` into `Interface/AddOns/`. Launch with `Launch_WoW.exe`.

## Target binary

Pinned to `Wow.exe` build **12340** with SHA-256 `aa63a5750d60ef16746c686b3d5e26876d98953eab08b1c026cd0faf78e88cb8`. Other 3.3.5a builds have different offsets and are not currently supported.

## Credits

Artwork (Xbox glyphs, hex shape textures, decorative gems) is derived from [ConsolePort](https://github.com/seblindfors/ConsolePort) by Sebastian Lindfors, redistributed under the Artistic License 2.0. See `Interface/AddOns/ControllerPatch/Assets/LICENSE-ConsolePort.md` and `ATTRIBUTION.md` for the full chain.

The reverse-engineering notes, DLL, launcher, and addon logic are original to this project and released under the MIT License (see `LICENSE`).
