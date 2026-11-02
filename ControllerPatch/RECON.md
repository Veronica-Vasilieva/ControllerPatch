# ControllerPatch — Wow.exe 3.3.5a Recon

Reverse-engineering recon pass for the native controller support patch on WoW 3.3.5a (WotLK, build 12340). All addresses are **virtual addresses in the loaded image** (image base 0x400000), observed in Ghidra 12.1.4 via REA.

## 1. Target identification

| Field | Value |
|---|---|
| Path | `E:\Documents\TheShrineWOW\Wow.exe` |
| Size | 7,704,216 bytes (7.35 MB) |
| SHA-256 | `aa63a5750d60ef16746c686b3d5e26876d98953eab08b1c026cd0faf78e88cb8` |
| Format | PE32 (Windows x86 executable) |
| File version | 3.3.5.12340 |
| File description | "World of Warcraft Retail" (Blizzard build string) |
| PDB reference | `Wow.pdb` — GUID `8805d059-f6a3-4565-a646-aa69736d4efe`, age 1 (NOT loaded; symbols stripped) |
| Compiler | MSVC (Microsoft RTTI present, standard CRT) |
| Compressed? | No — code is directly disassemblable; `.zdata` section (RWX, 0x1000 bytes) is the one anomaly, consistent with Blizzard's known runtime-decrypt stub |

**Patch target is pinned to this exact SHA-256.** The installer must refuse any other hash to avoid corrupting modded client installs.

## 2. Memory layout

| Section | Range | Size | Perms | Notes |
|---|---|---|---|---|
| Headers | 0x400000 – 0x400400 | 1 KB | R | PE header; needs touch-up to add our new section |
| `.text` | 0x401000 – 0x9DE400 | 6.00 MB | R-X | Code |
| `.rdata` | 0x9DF000 – 0xAB5800 | 858 KB | R-- | Read-only data, strings, vtables, RTTI |
| `.data` | 0xAB6000 – 0xDD0508 | 3.10 MB | RW- | Globals including the Lua reg table |
| `.zdata` | 0xDD1000 – 0xDD2000 | 4 KB | RWX | Blizzard decrypt stub target; AVOID hooking inside |
| `.tls` | 0xDD2000 – 0xDD2200 | 512 B | RW- | TLS slot |
| `.rsrc` | 0xDD3000 – 0xDFCC00 | 167 KB | R-- | Icons, version info |

**Insertion point for new section**: after `.rsrc`, at ~0xDFD000 (next 0x1000-aligned RVA). The physical PE grows at EOF; headers are rewritten to append a `.ctrl` section header. Standard binary-patching technique, mature on this binary.

## 3. Confirmed subsystem addresses

### Lua C API (located via Script_SetBinding decompilation)

Blizzard embeds a Lua 5.1-based scripting layer. The internal API functions cluster around 0x84Dxxx–0x84Fxxx:

| Function | Address | Notes |
|---|---|---|
| `lua_isstring(L, idx)` | `0x84DF60` | Returns int; checks arg type at stack index |
| `lua_isnumber(L, idx)` | `0x84DF20` | Same pattern |
| `lua_tonumber(L, idx)` | `0x84E030` | 2-arg form; third-param overload used elsewhere |
| `lua_tolstring(L, idx, &len)` | `0x84E0E0` | Blizzard's main string-pop helper |
| `lua_pushnumber(L, double)` | `0x84E2A0` | Called with raw double bits as arg |
| `lua_pushnil(L)` | `0x84E280` | — |
| `luaL_error(L, fmt, ...)` | `0x84F280` | Pushes and raises error |

These are all we need to implement new C functions registered as Lua globals (e.g., `GamePadSetDeadzone`, `GamePadGetAxis`, etc.).

### Framework glue (located via Script_SetBinding call graph)

| Function | Address | Signature | Role |
|---|---|---|---|
| `FrameScript_SignalEvent` | `0x81B530` | `(event_id, format, ...)` | Fires a game event onto the Lua event bus — **this is how we trigger `GAMEPAD_BUTTON_PRESSED` etc.** |
| `SetBinding_internal` | `0x562ED0` | `(mode, submode, key, command)` | Programmatic binding injection; mode=3 is the "runtime" mode SetBinding Lua uses |
| `CSimpleFrameScript::GetOrCreate` | `0x49E630` | `(owner)` | Lazily constructs the FrameScript object on an owner at `owner->field_0xA8`; initializes Lua state on first call |

### Lua function registration table (`.data`)

A packed C array of `luaL_Reg`-style entries: `struct { const char* name; lua_CFunction func; }`, 8 bytes each. Confirmed entries so far (the table spans at least ~0x4A00 bytes based on observed usage):

| Entry addr | Name string | Lua name | C function |
|---|---|---|---|
| 0xACDE44 | 0xA0ECF0 | (prior) | 0x55E8D0 |
| 0xACDE4C | 0xA0ECE4 | `SetBinding` | **0x563520** |
| 0xACDE54 | 0xA0ECD4 | `SetBindingSpell` | 0x5635E0 |
| 0xACDE5C | 0xA0ECC4 | `SetBindingItem` | 0x563700 |
| 0xACDE64 | 0xA0ECB4 | `SetBindingMacro` | 0x563820 |
| 0xACDE6C | 0xA0ECA4 | `SetBindingClick` | 0x563940 |
| 0xAD1A18 | 0xA1DC44 | `MouselookStart` | **0x5FCC10** |
| 0xAD1A20 | 0xA1DC34 | (likely `MouselookStop`) | 0x5FC890 |
| 0xAD2100 | 0xA1E084 | (prior to FlipCameraYaw) | 0x6018A0 |
| 0xAD20F8 | 0xA1E098 | `FlipCameraYaw` | 0x5FF2C0 |

### Camera subsystem (located via Script_MouselookStart raw bytes)

- **`CGCamera* g_CGCamera = *(CGCamera**)0xC24954`** — camera singleton pointer in `.data`
- `0xB499A4` — nearby global (likely player/world context, next to the FrameScript counter cluster at `0xB49984` / `0xD3F778`)
- Script_MouselookStart prologue: `56 8B 35 54 49 C2 00  57  8B 3D A4 99 B4 00  57  6A 01  8B CE  C7 46 18 00 00`
  = `push esi; mov esi, [0xC24954]; push edi; mov edi, [0xB499A4]; push edi; push 1; mov ecx, esi; mov [esi+0x18], 0x0000...`

The camera object's method dispatch happens through ecx (thiscall). Field `+0x18` on the camera is the "mouselook active" state. There are **many** camera CVars nearby in `.rdata`:

| CVar / Lua name | Address |
|---|---|
| `FlipCameraYaw` | 0xA1E098 |
| `cameraYawSmoothMax` | 0xA1E3FC |
| `cameraYawSmoothMin` | 0xA1E410 |
| `cameraYawSmoothSpeed` | 0xA1E6BC |
| `cameraYawMoveSpeed` | 0xA1E794 |

## 4. Structure layouts (inferred)

### `CSimpleFrameScript` (sizeof = 0xA0 bytes)

```c
struct CSimpleFrameScript {
    void*       vtable;            // +0x00 = 0x9EB2B0
    uint32_t    initialized;       // +0x04 — 0 until FUN_00819880 runs
    lua_State*  L;                 // +0x08 — the Lua state pointer
    // ... fields +0x0C through +0x1F unobserved
    void*       vtable2;           // +0x20 — secondary interface vtable @ 0x9EA788
    // ...
    // sizeof = 0xA0
};
```

Allocation: `FUN_0076E540(size=0xA0, ".\\CSimpleFrameScript.cpp", lineno=0x38, flags=0)` — that is Blizzard's `SMemAlloc`-equivalent, which also accepts a source-file / line for diagnostic logging. **Alloc = `0x76E540`** (useful if we need to allocate in the game's own heap).

Owners store the FrameScript at `owner->field_0xA8` (observed in `CSimpleFrameScript::GetOrCreate` at `FUN_0049E630`).

### Lua registration table entries

```c
typedef struct {
    const char*    name;
    lua_CFunction  func;    // int (__cdecl *)(lua_State* L)
} luaL_Reg;
```

Blizzard uses the standard calling convention. All Lua C functions take exactly one argument (the state) and return int (number of results pushed).

### Script_SetBinding reference implementation

Decompiled, cleaned up for readability:

```c
int Script_SetBinding(lua_State* L) {
    if (!lua_isstring(L, 1)) {
        luaL_error(L, "Usage: SetBinding(\"KEY\"[, \"COMMAND\"][, mode])");
        return 0;  // never reached — luaL_error longjmps
    }
    uint32_t mode_arg = 0;
    if (lua_isnumber(L, 3)) {
        double n = lua_tonumber(L, 3);
        int    m = /* FUN_0088b9c0 */ truncate_to_int(n);
        if ((uint32_t)(m - 1) < 4) {
            mode_arg = m - 1;
        }
    }
    const char* command = lua_tolstring(L, 2, NULL);
    const char* key     = lua_tolstring(L, 1, NULL);
    int ok = SetBinding_internal(/*mode=*/3, mode_arg, key, command);
    if (ok) {
        FrameScript_SignalEvent(0x177 /* UPDATE_BINDINGS */, NULL);
        lua_pushnumber(L, 1.0);
        return 1;
    }
    lua_pushnil(L);
    return 1;
}
```

**This is a template for every `GamePad*` Lua C function we'll add.**

## 5. Open items (patch-site decisions still TBD)

1. **Lua state init site** — `FUN_00819880` is called by `CSimpleFrameScript::GetOrCreate` when `initialized == 0`. Need to confirm this is `luaL_newstate`-adjacent, and identify its caller (where to tail-hook so our `luaL_register(L, "GamePad", ...)` runs **after** Blizzard has registered its own globals).
2. **Main-loop tick** — `PeekMessageA/W` and `DispatchMessageA/W` are not name-resolved in Ghidra (import names stripped). Alternative anchors: (a) find the function that calls both `GetTickCount` and `D3D9::Present`, (b) hunt the window-class string `"GxWindowClassD3d"`, (c) use the `.zdata` entry trampoline. The main-loop hook is where we poll XInput each frame.
3. **lua_State global accessor** — likely a function like `FrameScript_GetContext(script_id)` that reads from `0xD3F778` / `0xB49984` and returns the FrameScript object. Need to locate and expose it or inline the dereference in our patch.
4. **Direct input dispatch** — the function that fires `KEY_PRESSED` events given a key constant. Two options:
   - Call it directly from our XInput poll (clean, but need the function address).
   - Synthesize `WM_KEYDOWN` into the game's own message pump (fragile, platform-dependent).
   - A third option: use `FrameScript_SignalEvent(0x177 UPDATE_BINDINGS, ...)` after programmatically calling `SetBinding_internal` with pad buttons mapped to synthetic key names, so existing bindings fire naturally.
5. **Warden-safe hook sites** — Not critical for own-server use, but if we ship this: identify ranges Warden CRCs (public knowledge, maps exist) and keep our trampolines outside those. Our `.ctrl` new section is safe by construction; the only concern is overwriting hook bytes inside existing functions.

## 6. Proposed patch architecture

```
┌─────────────────────────────────────────────────────────────┐
│                   wow.exe (patched)                         │
│                                                             │
│   ┌─────────────┐          ┌──────────────────────────┐    │
│   │   .text     │  trampo  │  .ctrl  (new PE section) │    │
│   │  (original) │ ─jmp──▶  │                          │    │
│   │             │          │  ┌────────────────────┐  │    │
│   │  main loop  │ ◀─ret──  │  │ XInput poller      │  │    │
│   │  tick       │          │  │ (per-frame)        │  │    │
│   │             │          │  └────────┬───────────┘  │    │
│   │  Lua init   │  tail    │           │              │    │
│   │  (post-     │  hook    │  ┌────────▼───────────┐  │    │
│   │   newstate) │ ─────▶   │  │ GamePad* reg table │  │    │
│   │             │          │  │ (new luaL_Reg[])   │  │    │
│   └─────────────┘          │  └────────┬───────────┘  │    │
│                            │           │              │    │
│                            │  ┌────────▼───────────┐  │    │
│                            │  │ Event dispatch:    │  │    │
│                            │  │ FrameScript_       │  │    │
│                            │  │   SignalEvent(     │  │    │
│                            │  │   GAMEPAD_*)       │  │    │
│                            │  └────────────────────┘  │    │
│                            └──────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

### What the patch adds (minimal viable version)

1. **New PE section `.ctrl`** at ~0xDFD000 (RWX, 0x8000 bytes initial — 32KB, overestimate; refined after prototype)
2. **DllMain-equivalent init**: hooked into Lua state ready point, runs once:
   - Opens XInput1_4.dll (shipped with Windows 10/11)
   - Opens dinput8.dll (optional, for legacy HOTAS)
   - Registers Lua table `GamePad = { ... }` with ~15 functions
3. **Per-frame tick**: hooked into main loop, runs each frame:
   - Polls XInput for pad 0 (configurable later for multi-player)
   - Diffs state against previous frame
   - For each button edge, calls `FrameScript_SignalEvent(GAMEPAD_BUTTON_DOWN|UP, "s", button_name)`
   - For axis deltas, calls `FrameScript_SignalEvent(GAMEPAD_AXIS_CHANGED, "sff", axis_name, value, delta)`
4. **Camera direct-drive**: on each tick, if right-stick is deflected and in-combat/mouselook state is active, apply yaw/pitch directly to the camera singleton `g_CGCamera` (bypasses mouse synthesis entirely — this is the biggest quality-of-life win over Steam Input)
5. **No gameplay semantics in the patch** — all binding, UI, and accessibility logic lives in a paired Lua addon that consumes `GAMEPAD_*` events. The patch is just the input bridge.

### What the paired Lua addon adds

- Party/raid soft-targeting via D-pad
- UI cursor mode (right stick → virtual mouse with snap)
- Pad-glyph overlay on action bars
- Action-layer modifier handling (LT / LB / LT+LB)
- Voice chat trigger integration
- Role-specific layout templates (healer, tank, melee, caster)

## 7. Risk register

| Risk | Mitigation |
|---|---|
| Hooked bytes conflict with Warden scans | Pick hook sites in .text that are outside Warden's published ranges; new .ctrl section is immune |
| User installs patch on a modded Wow.exe we didn't anticipate | SHA-256 gate in the installer; refuse unknown hashes with clear error |
| XInput controller is unplugged / wrong device index | Fall back silently to no-input mode; raise `GAMEPAD_DISCONNECTED` event |
| Camera drive glitches during cinematic / loading screens | Suspend camera drive while `g_CGCamera->field_0x?` indicates non-interactive state (TBD field offset) |
| Game version drift (12304, 12213, etc.) | v1 pins to 12340 only; other builds get a `"not supported"` prompt |

## 8. Session artifacts

- Ghidra project is ephemeral (REA imports fresh each session). Save a snapshot with `close_binary(snapshot_path=...)` before ending the session; next session reuses it via `open_binary(snapshot_path=...)` to skip the ~5-minute auto-analysis.
- Suggested snapshot path: `E:\Documents\TheShrineWOW\ControllerPatch\wow-12340.ghidra-snapshot`.

## 9. Next steps

1. **Close the Open Items (section 5)** — focused reversal pass for main-loop tick, Lua state accessor, direct input dispatch. ~2-3 hours of session time.
2. **Design `GamePad` Lua API surface** — enumerate the ~15 functions the addon will call. Shape them like retail's for forward portability (`GetBindingKey("GAMEPADBUTTONA")`, `GamePadStick(axis)`, etc.).
3. **Prototype in a DLL first, then promote to patched exe** — faster iteration cycle: build an injected DLL that does the main-loop hook and Lua reg (no PE surgery), prove the design on your friend's actual gameplay, then do the binary patch for distribution.
4. **Companion addon scaffolding** — start the Lua addon under `.\Interface\AddOns\ControllerPatch\` with no API dependency yet (so you can iterate on soft-targeting + UI-cursor logic using the Phase-1 Steam Input flow while the C-side is being built).

## 10. Provenance

Every address and offset in this document was observed in Ghidra 12.1.4 analysis of the exact binary with SHA-256 `aa63a5750d60ef16746c686b3d5e26876d98953eab08b1c026cd0faf78e88cb8`. Ghidra may misname un-analyzed procedures (prefix `FUN_`) and does not expose Blizzard's original symbol names — this binary ships without an accessible PDB companion. Field offsets inside `CSimpleFrameScript` are inferred from the decompiled accessor at `0x49E630` and have not yet been independently verified by cross-referencing. Treat them as "high-confidence working hypothesis" until the patch prototype exercises them.
