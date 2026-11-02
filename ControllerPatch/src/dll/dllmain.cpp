// ControllerPatch - DLL entry (v1c: SignalEvent hook + Lua GamePad* globals)
//
// What v1c adds over v1b:
//   - Four Lua C functions registered as globals (via lua_pushstring +
//     lua_pushcclosure + lua_rawset(LUA_GLOBALSINDEX)):
//
//         GamePadConnected()          -> bool
//         GamePadGetButton("A")       -> bool    ("A","B","X","Y","LB","RB",
//                                                 "L3","R3","START","BACK",
//                                                 "DUP","DDOWN","DLEFT","DRIGHT")
//         GamePadGetAxis("LX")        -> number  -1.0..1.0 ("LX","LY","RX","RY")
//         GamePadGetTrigger("LT")     -> number   0.0..1.0 ("LT","RT")
//
//   - Pad state globals (atomic<> primitives) updated by the XInput poll
//     thread, read by the Lua C functions above.
//
//   - Removes the event-queue firing path from v1b. v1c is polling-only; event
//     dispatch comes back in v1d when we need named GAMEPAD_* events for
//     addons that prefer OnEvent over OnUpdate polling.
//
// Addresses pinned to Wow.exe 3.3.5a 12340
// SHA-256 aa63a5750d60ef16746c686b3d5e26876d98953eab08b1c026cd0faf78e88cb8.

#include <windows.h>
#include <xinput.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <atomic>
#include <thread>

#pragma comment(lib, "xinput.lib")
#pragma comment(lib, "user32.lib")

// ---------------------------------------------------------------------------
// Target offsets (relative to image base 0x400000)
// ---------------------------------------------------------------------------
namespace game {
    constexpr uintptr_t SignalEvent       = 0x0081B530;
    constexpr size_t    SignalEvent_patch = 6;
    constexpr uintptr_t SignalEvent_cont  = SignalEvent + SignalEvent_patch;

    // Validator: `if (fn < DAT_D415B8 || fn >= DAT_D415BC) fatal(...)` -
    // range-checks a function pointer against Wow.exe's .text bounds. Called
    // on every lua_CFunction invocation. Our DLL functions live outside the
    // range, so we patch byte 0 of this function to 0xC3 (RET) to disable it.
    constexpr uintptr_t FnPtrCheck = 0x0086B5A0;

    // Lua C API (observed in-binary - see RECON.md section 3 for provenance)
    constexpr uintptr_t L_STATE_PTR   = 0x00D3F78C;   // void** -> lua_State*
    constexpr uintptr_t lua_pushnil      = 0x0084E280;
    constexpr uintptr_t lua_pushnumber   = 0x0084E2A0;
    constexpr uintptr_t lua_pushstring   = 0x0084E350;
    constexpr uintptr_t lua_pushcclosure = 0x0084E400;
    constexpr uintptr_t lua_pushboolean  = 0x0084E4D0;
    constexpr uintptr_t lua_rawset       = 0x0084E970;
    constexpr uintptr_t lua_tolstring    = 0x0084E0E0;

    constexpr int LUA_GLOBALSINDEX = -10002;
}

// Lua C function signature (same across the whole binary - see Script_SetBinding).
typedef int (__cdecl *lua_CFunction_t)(void* L);

// Thin typed trampolines for the Lua C API addresses above.
typedef void        (__cdecl *fn_pushnil_t)      (void* L);
typedef void        (__cdecl *fn_pushnumber_t)   (void* L, double n);
typedef void        (__cdecl *fn_pushstring_t)   (void* L, const char* s);
typedef void        (__cdecl *fn_pushcclosure_t) (void* L, lua_CFunction_t f, int n);
typedef void        (__cdecl *fn_pushboolean_t)  (void* L, int b);
typedef void        (__cdecl *fn_rawset_t)       (void* L, int idx);
typedef const char* (__cdecl *fn_tolstring_t)    (void* L, int idx, size_t* len);
typedef double      (__cdecl *fn_tonumber_t)     (void* L, int idx);

#define L_PUSHNIL      ((fn_pushnil_t)      game::lua_pushnil)
#define L_PUSHNUMBER   ((fn_pushnumber_t)   game::lua_pushnumber)
#define L_PUSHSTRING   ((fn_pushstring_t)   game::lua_pushstring)
#define L_PUSHCCLOSURE ((fn_pushcclosure_t) game::lua_pushcclosure)
#define L_PUSHBOOLEAN  ((fn_pushboolean_t)  game::lua_pushboolean)
#define L_RAWSET       ((fn_rawset_t)       game::lua_rawset)
#define L_TOLSTRING    ((fn_tolstring_t)    game::lua_tolstring)
#define L_TONUMBER     ((fn_tonumber_t)     0x0084E030)   /* lua_tonumber */

// ---------------------------------------------------------------------------
// Diagnostic log (same as v0..v1b)
// ---------------------------------------------------------------------------
namespace {
    std::atomic<bool> g_running{false};
    HANDLE            g_log = INVALID_HANDLE_VALUE;
    CRITICAL_SECTION  g_log_cs;

    void log_line(const char* fmt, ...) {
        if (g_log == INVALID_HANDLE_VALUE) return;
        char buf[768];
        SYSTEMTIME st; GetLocalTime(&st);
        int head = _snprintf_s(buf, sizeof(buf), _TRUNCATE,
            "%02u:%02u:%02u.%03u ", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
        if (head < 0) head = 0;
        va_list ap;
        va_start(ap, fmt);
        int body = _vsnprintf_s(buf + head, sizeof(buf) - head - 1, _TRUNCATE, fmt, ap);
        va_end(ap);
        int n = head + (body < 0 ? 0 : body);
        buf[n++] = '\r'; buf[n++] = '\n';
        EnterCriticalSection(&g_log_cs);
        DWORD w; WriteFile(g_log, buf, (DWORD)n, &w, nullptr);
        FlushFileBuffers(g_log);
        LeaveCriticalSection(&g_log_cs);
    }

    void open_log_next_to_exe() {
        char path[MAX_PATH];
        DWORD n = GetModuleFileNameA(nullptr, path, MAX_PATH);
        if (n == 0 || n >= MAX_PATH) { strcpy_s(path, "ControllerPatch.log"); }
        else {
            char* last = strrchr(path, '\\');
            if (!last) last = strrchr(path, '/');
            if (last) { *(last + 1) = '\0'; strcat_s(path, "ControllerPatch.log"); }
            else      { strcpy_s(path, "ControllerPatch.log"); }
        }
        g_log = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_DELETE,
                            nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    }
}

// ---------------------------------------------------------------------------
// Pad state (poll thread writes; Lua C functions read)
// ---------------------------------------------------------------------------
namespace pad {
    std::atomic<bool>  connected{false};
    std::atomic<WORD>  buttons{0};
    std::atomic<BYTE>  lt{0}, rt{0};
    std::atomic<SHORT> lx{0}, ly{0}, rx{0}, ry{0};
}

// ---------------------------------------------------------------------------
// Writable key map (poll thread reads, Lua addon writes via GamePadSetKeyMapping)
// ---------------------------------------------------------------------------
namespace {
    // 8-byte packed: guarantees std::atomic<BtnKey> stays lock-free on x86.
    struct BtnKey { WORD base; WORD lt; WORD rt; WORD _reserved; };
    constexpr int BTN_COUNT = 14;
    const char* const BTN_NAMES[BTN_COUNT] = {
        "A", "B", "X", "Y",
        "LB", "RB",
        "DUP", "DDOWN", "DLEFT", "DRIGHT",
        "START", "BACK", "L3", "R3"
    };
    const WORD BTN_MASKS[BTN_COUNT] = {
        XINPUT_GAMEPAD_A,
        XINPUT_GAMEPAD_B,
        XINPUT_GAMEPAD_X,
        XINPUT_GAMEPAD_Y,
        XINPUT_GAMEPAD_LEFT_SHOULDER,
        XINPUT_GAMEPAD_RIGHT_SHOULDER,
        XINPUT_GAMEPAD_DPAD_UP,
        XINPUT_GAMEPAD_DPAD_DOWN,
        XINPUT_GAMEPAD_DPAD_LEFT,
        XINPUT_GAMEPAD_DPAD_RIGHT,
        XINPUT_GAMEPAD_START,
        XINPUT_GAMEPAD_BACK,
        XINPUT_GAMEPAD_LEFT_THUMB,
        XINPUT_GAMEPAD_RIGHT_THUMB,
    };
    // Pad mode. 0 = gameplay (current behavior), 1 = UI cursor (right stick
    // moves mouse, A = left-click, B = ESCAPE). The addon flips this based
    // on whether a Blizzard modal frame is open.
    std::atomic<int> g_pad_mode{0};

    std::atomic<BtnKey> g_btn_keys[BTN_COUNT] = {
        { BtnKey{ '1',          '7',          VK_F5,  0 } },  // A
        { BtnKey{ '2',          '8',          VK_F6,  0 } },  // B
        { BtnKey{ '3',          '9',          VK_F7,  0 } },  // X
        { BtnKey{ '4',          '0',          VK_F8,  0 } },  // Y
        { BtnKey{ '5',          VK_OEM_MINUS, VK_F9,  0 } },  // LB
        { BtnKey{ '6',          VK_OEM_PLUS,  VK_F10, 0 } },  // RB
        { BtnKey{ VK_F1,        VK_F1,        VK_F1,  0 } },  // DUP
        { BtnKey{ VK_F2,        VK_F2,        VK_F2,  0 } },  // DDOWN
        { BtnKey{ VK_F3,        VK_F3,        VK_F3,  0 } },  // DLEFT
        { BtnKey{ VK_F4,        VK_F4,        VK_F4,  0 } },  // DRIGHT
        { BtnKey{ VK_ESCAPE,    VK_ESCAPE,    0,      0 } },  // START
        { BtnKey{ 'M',          'M',          0,      0 } },  // BACK
        { BtnKey{ 0, 0, 0, 0 } },                             // L3 (reserved for action ring)
        { BtnKey{ 0, 0, 0, 0 } },                             // R3
    };
    int button_mask_to_index(WORD mask) {
        for (int i = 0; i < BTN_COUNT; ++i) {
            if (BTN_MASKS[i] == mask) return i;
        }
        return -1;
    }
    int button_name_to_index(const char* name) {
        if (!name) return -1;
        for (int i = 0; i < BTN_COUNT; ++i) {
            if (strcmp(BTN_NAMES[i], name) == 0) return i;
        }
        return -1;
    }
}

// ---------------------------------------------------------------------------
// Lua C functions (called from Wow's Lua VM on the main thread)
// ---------------------------------------------------------------------------
int __cdecl Script_GamePadConnected(void* L) {
    L_PUSHBOOLEAN(L, pad::connected.load() ? 1 : 0);
    return 1;
}

static int lua_str_eq(const char* a, const char* b) {
    while (*a && *b && *a == *b) { ++a; ++b; }
    return *a == 0 && *b == 0;
}

int __cdecl Script_GamePadGetButton(void* L) {
    const char* name = L_TOLSTRING(L, 1, nullptr);
    if (!name) { L_PUSHBOOLEAN(L, 0); return 1; }
    WORD mask = 0;
    if      (lua_str_eq(name, "A"))      mask = XINPUT_GAMEPAD_A;
    else if (lua_str_eq(name, "B"))      mask = XINPUT_GAMEPAD_B;
    else if (lua_str_eq(name, "X"))      mask = XINPUT_GAMEPAD_X;
    else if (lua_str_eq(name, "Y"))      mask = XINPUT_GAMEPAD_Y;
    else if (lua_str_eq(name, "LB"))     mask = XINPUT_GAMEPAD_LEFT_SHOULDER;
    else if (lua_str_eq(name, "RB"))     mask = XINPUT_GAMEPAD_RIGHT_SHOULDER;
    else if (lua_str_eq(name, "L3"))     mask = XINPUT_GAMEPAD_LEFT_THUMB;
    else if (lua_str_eq(name, "R3"))     mask = XINPUT_GAMEPAD_RIGHT_THUMB;
    else if (lua_str_eq(name, "START"))  mask = XINPUT_GAMEPAD_START;
    else if (lua_str_eq(name, "BACK"))   mask = XINPUT_GAMEPAD_BACK;
    else if (lua_str_eq(name, "DUP"))    mask = XINPUT_GAMEPAD_DPAD_UP;
    else if (lua_str_eq(name, "DDOWN"))  mask = XINPUT_GAMEPAD_DPAD_DOWN;
    else if (lua_str_eq(name, "DLEFT"))  mask = XINPUT_GAMEPAD_DPAD_LEFT;
    else if (lua_str_eq(name, "DRIGHT")) mask = XINPUT_GAMEPAD_DPAD_RIGHT;
    L_PUSHBOOLEAN(L, (pad::buttons.load() & mask) ? 1 : 0);
    return 1;
}

int __cdecl Script_GamePadGetAxis(void* L) {
    const char* name = L_TOLSTRING(L, 1, nullptr);
    double v = 0.0;
    if (name) {
        SHORT raw = 0;
        if      (lua_str_eq(name, "LX")) raw = pad::lx.load();
        else if (lua_str_eq(name, "LY")) raw = pad::ly.load();
        else if (lua_str_eq(name, "RX")) raw = pad::rx.load();
        else if (lua_str_eq(name, "RY")) raw = pad::ry.load();
        // XInput range: -32768..32767. Normalize to -1.0..1.0.
        v = raw < 0 ? (double)raw / 32768.0 : (double)raw / 32767.0;
    }
    L_PUSHNUMBER(L, v);
    return 1;
}

int __cdecl Script_GamePadSetMode(void* L) {
    // Lua signature: GamePadSetMode("game" | "ui") -> bool
    const char* mode = L_TOLSTRING(L, 1, nullptr);
    int new_mode = 0;
    if (mode && strcmp(mode, "ui") == 0) new_mode = 1;
    g_pad_mode.store(new_mode, std::memory_order_relaxed);
    L_PUSHBOOLEAN(L, 1);
    return 1;
}

int __cdecl Script_GamePadSetKeyMapping(void* L) {
    // Lua: GamePadSetKeyMapping(buttonName, baseVk, ltVk, rtVk) -> bool
    const char* name = L_TOLSTRING(L, 1, nullptr);
    double base_d = L_TONUMBER(L, 2);
    double lt_d   = L_TONUMBER(L, 3);
    double rt_d   = L_TONUMBER(L, 4);
    int idx = button_name_to_index(name);
    if (idx < 0) { L_PUSHBOOLEAN(L, 0); return 1; }
    BtnKey bk;
    bk.base      = static_cast<WORD>(static_cast<int>(base_d) & 0xFFFF);
    bk.lt        = static_cast<WORD>(static_cast<int>(lt_d)   & 0xFFFF);
    bk.rt        = static_cast<WORD>(static_cast<int>(rt_d)   & 0xFFFF);
    bk._reserved = 0;
    g_btn_keys[idx].store(bk, std::memory_order_relaxed);
    L_PUSHBOOLEAN(L, 1);
    return 1;
}

int __cdecl Script_GamePadGetTrigger(void* L) {
    const char* name = L_TOLSTRING(L, 1, nullptr);
    double v = 0.0;
    if (name) {
        BYTE raw = 0;
        if      (lua_str_eq(name, "LT")) raw = pad::lt.load();
        else if (lua_str_eq(name, "RT")) raw = pad::rt.load();
        v = (double)raw / 255.0;
    }
    L_PUSHNUMBER(L, v);
    return 1;
}

// ---------------------------------------------------------------------------
// Lua registration (called ONCE from on_signalevent_entry on main thread)
// ---------------------------------------------------------------------------
struct LuaFunc { const char* name; lua_CFunction_t func; };
static const LuaFunc kGamePadFuncs[] = {
    { "GamePadConnected",     &Script_GamePadConnected     },
    { "GamePadGetButton",     &Script_GamePadGetButton     },
    { "GamePadGetAxis",       &Script_GamePadGetAxis       },
    { "GamePadGetTrigger",    &Script_GamePadGetTrigger    },
    { "GamePadSetKeyMapping", &Script_GamePadSetKeyMapping },
    { "GamePadSetMode",       &Script_GamePadSetMode       },
    { nullptr, nullptr }
};

static void register_gamepad_globals() {
    void* L = *reinterpret_cast<void**>(game::L_STATE_PTR);
    if (!L) {
        log_line("[lua] L still null at 0x%08x - cannot register yet",
                 (unsigned)game::L_STATE_PTR);
        return;
    }
    log_line("[lua] registering GamePad* globals, L=0x%p", L);

    for (const LuaFunc* r = kGamePadFuncs; r->name; ++r) {
        // Lua stack recipe for _G[name] = closure:
        //   lua_pushstring(L, name)      -- key
        //   lua_pushcclosure(L, fn, 0)   -- value
        //   lua_rawset(L, LUA_GLOBALSINDEX)   -- pops both, sets _G[key]=value
        L_PUSHSTRING(L, r->name);
        L_PUSHCCLOSURE(L, r->func, 0);
        L_RAWSET(L, game::LUA_GLOBALSINDEX);
        log_line("[lua]   registered %s -> 0x%p", r->name, r->func);
    }
}

// ---------------------------------------------------------------------------
// Inline hook on FrameScript_SignalEvent (unchanged from v1a/b, minus the
// event-queue drain path - we now only need the hook as a one-shot main-thread
// trigger for Lua registration + future event dispatch).
// ---------------------------------------------------------------------------
typedef void (__cdecl *SignalEvent_t)(int, const char*, ...);
static SignalEvent_t g_trampoline = nullptr;

extern "C" void __cdecl on_signalevent_entry(int eventId, const char* fmt);

// Re-register whenever the game's active Lua state changes. 3.3.5a uses one
// state for the login/glue screens and a separate state for the in-world UI;
// `/reload` also builds a fresh state. Comparing the current L* against the
// one we last registered to catches all those transitions.
static void*            g_last_registered_L = nullptr;
static CRITICAL_SECTION g_reg_cs;

void __cdecl on_signalevent_entry(int eventId, const char* /*fmt*/) {
    void* L = *reinterpret_cast<void**>(game::L_STATE_PTR);
    if (L && L != g_last_registered_L) {
        EnterCriticalSection(&g_reg_cs);
        if (L != g_last_registered_L) {
            void* prev = g_last_registered_L;
            log_line("[lua] state change: 0x%p -> 0x%p (re-registering)",
                     prev, L);
            register_gamepad_globals();
            g_last_registered_L = L;
        }
        LeaveCriticalSection(&g_reg_cs);
    }
    (void)eventId;
}

__declspec(naked) void SignalEvent_hook() {
    __asm {
        pushad
        pushfd
        mov eax, [esp+44]       // fmt
        push eax
        mov eax, [esp+44]       // eventId
        push eax
        call on_signalevent_entry
        add esp, 8
        popfd
        popad
        jmp dword ptr [g_trampoline]
    }
}

static bool patch_fnptr_check() {
    void* target = reinterpret_cast<void*>(game::FnPtrCheck);
    DWORD oldProt;
    if (!VirtualProtect(target, 1, PAGE_EXECUTE_READWRITE, &oldProt)) {
        log_line("[patch] VirtualProtect on 0x%08x failed: %lu",
                 (unsigned)game::FnPtrCheck, GetLastError());
        return false;
    }
    uint8_t original = *reinterpret_cast<uint8_t*>(target);
    *reinterpret_cast<uint8_t*>(target) = 0xC3;  // RET
    DWORD tmp;
    VirtualProtect(target, 1, oldProt, &tmp);
    FlushInstructionCache(GetCurrentProcess(), target, 1);
    log_line("[patch] fnptr-check at 0x%08x: 0x%02x -> 0xC3 (disabled)",
             (unsigned)game::FnPtrCheck, original);
    return true;
}

static bool install_signalevent_hook() {
    uint8_t* target = reinterpret_cast<uint8_t*>(game::SignalEvent);

    g_trampoline = reinterpret_cast<SignalEvent_t>(
        VirtualAlloc(nullptr, 32, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE));
    if (!g_trampoline) {
        log_line("[hook] VirtualAlloc failed: %lu", GetLastError());
        return false;
    }
    uint8_t* t = reinterpret_cast<uint8_t*>(g_trampoline);
    memcpy(t, target, game::SignalEvent_patch);
    t[game::SignalEvent_patch] = 0xE9;
    int32_t rel = static_cast<int32_t>(game::SignalEvent_cont -
        (reinterpret_cast<uintptr_t>(t) + game::SignalEvent_patch + 5));
    memcpy(t + game::SignalEvent_patch + 1, &rel, 4);
    for (size_t i = game::SignalEvent_patch + 5; i < 32; ++i) t[i] = 0xCC;

    DWORD oldProt;
    if (!VirtualProtect(target, game::SignalEvent_patch,
                        PAGE_EXECUTE_READWRITE, &oldProt)) {
        log_line("[hook] VirtualProtect(RWX) failed: %lu", GetLastError());
        return false;
    }
    uint8_t patch[6];
    patch[0] = 0xE9;
    int32_t rel2 = static_cast<int32_t>(reinterpret_cast<uintptr_t>(SignalEvent_hook) -
        (game::SignalEvent + 5));
    memcpy(patch + 1, &rel2, 4);
    patch[5] = 0x90;
    memcpy(target, patch, game::SignalEvent_patch);

    DWORD tmp;
    VirtualProtect(target, game::SignalEvent_patch, oldProt, &tmp);
    FlushInstructionCache(GetCurrentProcess(), target, game::SignalEvent_patch);

    log_line("[hook] installed at 0x%08x -> hook=0x%p trampoline=0x%p",
             (unsigned)game::SignalEvent,
             (void*)&SignalEvent_hook, (void*)g_trampoline);
    return true;
}

// ---------------------------------------------------------------------------
// XInput poll thread - now also updates pad::* globals
// ---------------------------------------------------------------------------
namespace {
    const char* button_name(WORD mask) {
        switch (mask) {
        case XINPUT_GAMEPAD_DPAD_UP:        return "DUP";
        case XINPUT_GAMEPAD_DPAD_DOWN:      return "DDOWN";
        case XINPUT_GAMEPAD_DPAD_LEFT:      return "DLEFT";
        case XINPUT_GAMEPAD_DPAD_RIGHT:     return "DRIGHT";
        case XINPUT_GAMEPAD_START:          return "START";
        case XINPUT_GAMEPAD_BACK:           return "BACK";
        case XINPUT_GAMEPAD_LEFT_THUMB:     return "L3";
        case XINPUT_GAMEPAD_RIGHT_THUMB:    return "R3";
        case XINPUT_GAMEPAD_LEFT_SHOULDER:  return "LB";
        case XINPUT_GAMEPAD_RIGHT_SHOULDER: return "RB";
        case XINPUT_GAMEPAD_A:              return "A";
        case XINPUT_GAMEPAD_B:              return "B";
        case XINPUT_GAMEPAD_X:              return "X";
        case XINPUT_GAMEPAD_Y:              return "Y";
        default:                            return "?";
        }
    }
    constexpr SHORT STICK_DZ = 8000;
    constexpr BYTE  TRIG_DZ  = 30;
    bool stick_notable(SHORT prev, SHORT now, SHORT dz) {
        bool was_in = (prev > -dz && prev < dz);
        bool is_in  = (now  > -dz && now  < dz);
        return was_in != is_in || (!is_in && (abs(now - prev) > 2000));
    }

    bool wow_window_has_focus() {
        HWND fg = GetForegroundWindow();
        if (!fg) return false;
        DWORD fgPid = 0;
        GetWindowThreadProcessId(fg, &fgPid);
        return fgPid == GetCurrentProcessId();
    }

    void send_vk(WORD vk, bool down) {
        // Send BOTH scancode and VK: some games key off scancodes (DirectInput
        // / raw input), others off VK (Windows message loop). Setting both
        // keeps the event compatible with either path.
        INPUT in{};
        in.type = INPUT_KEYBOARD;
        in.ki.wVk    = vk;
        in.ki.wScan  = (WORD)MapVirtualKeyW(vk, MAPVK_VK_TO_VSC);
        // Extended-key flag for certain keys (arrows, Insert, Delete, Home,
        // End, PageUp/PageDown, numpad slash, Right Alt/Ctrl) so WoW parses
        // them correctly. Without it, scancodes alias to numpad versions.
        DWORD extended = 0;
        switch (vk) {
            case VK_LEFT: case VK_UP: case VK_RIGHT: case VK_DOWN:
            case VK_INSERT: case VK_DELETE:
            case VK_HOME: case VK_END:
            case VK_PRIOR: case VK_NEXT:
            case VK_DIVIDE:
            case VK_RCONTROL: case VK_RMENU:
                extended = KEYEVENTF_EXTENDEDKEY;
                break;
            default: break;
        }
        in.ki.dwFlags = extended | (down ? 0 : KEYEVENTF_KEYUP);
        SendInput(1, &in, sizeof(INPUT));
    }

    // Forward decl - defined later in this same namespace with the camera-
    // look helpers. on_button_edges needs it for the UI-mode A -> left-click
    // override.
    void send_mouse_event(DWORD flags, LONG dx = 0, LONG dy = 0);

    void on_button_edges(WORD prev, WORD now, bool lt_held, bool rt_held) {
        WORD edges = prev ^ now;
        bool focused = wow_window_has_focus();
        bool is_ui   = (g_pad_mode.load(std::memory_order_relaxed) == 1);
        for (WORD bit = 1; bit; bit <<= 1) {
            if (!(edges & bit)) continue;
            bool down = (now & bit) != 0;
            log_line("[pad0] button %s %s", down ? "DOWN" : "UP  ", button_name(bit));
            if (!focused) continue;

            // UI mode: suppress ABXY and D-pad entirely so the addon-side
            // UICursor module can handle them (D-pad -> move focus between
            // clickable widgets, A -> button:Click(), B -> close). LB/RB,
            // triggers, START, BACK, L3/R3 all keep their configured key
            // mapping so the user can still open bags, chat etc.
            if (is_ui) {
                switch (bit) {
                case XINPUT_GAMEPAD_A:
                case XINPUT_GAMEPAD_B:
                case XINPUT_GAMEPAD_X:
                case XINPUT_GAMEPAD_Y:
                case XINPUT_GAMEPAD_DPAD_UP:
                case XINPUT_GAMEPAD_DPAD_DOWN:
                case XINPUT_GAMEPAD_DPAD_LEFT:
                case XINPUT_GAMEPAD_DPAD_RIGHT:
                    continue;
                default: break;
                }
            }

            int idx = button_mask_to_index(bit);
            if (idx < 0) continue;
            BtnKey bk = g_btn_keys[idx].load(std::memory_order_relaxed);
            // RT takes precedence over LT if both held (user picks one layer).
            WORD vk = rt_held ? bk.rt : (lt_held ? bk.lt : bk.base);
            if (!vk) vk = bk.base;      // layer not configured -> fall back
            if (!vk) continue;
            send_vk(vk, down);
            if (down) log_line("[pad0] -> key 0x%02X (%s)",
                               vk, rt_held ? "RT+" : (lt_held ? "LT+" : "base"));
        }
    }

    // Left stick -> WASD. Hold-based: when the stick axis crosses the
    // deadzone we send the key down; when it returns inside we send it up.
    // The user can be moving diagonally so up to two keys may be held at once.
    static bool g_mv_w = false, g_mv_s = false, g_mv_a = false, g_mv_d = false;
    void drive_stick_movement(SHORT lx, SHORT ly, bool focused) {
        if (!focused) {
            // Release anything we were holding so WoW doesn't walk forever
            // into a background window after Alt-Tab.
            if (g_mv_w) { send_vk('W', false); g_mv_w = false; }
            if (g_mv_s) { send_vk('S', false); g_mv_s = false; }
            if (g_mv_a) { send_vk('A', false); g_mv_a = false; }
            if (g_mv_d) { send_vk('D', false); g_mv_d = false; }
            return;
        }
        bool want_w = ly >  STICK_DZ;
        bool want_s = ly < -STICK_DZ;
        bool want_a = lx < -STICK_DZ;
        bool want_d = lx >  STICK_DZ;
        if (want_w != g_mv_w) { send_vk('W', want_w); g_mv_w = want_w; }
        if (want_s != g_mv_s) { send_vk('S', want_s); g_mv_s = want_s; }
        if (want_a != g_mv_a) { send_vk('A', want_a); g_mv_a = want_a; }
        if (want_d != g_mv_d) { send_vk('D', want_d); g_mv_d = want_d; }
    }

    // Right stick -> mouse delta (fed through WoW's own mouselook, enabled
    // by the addon via MouselookStart/Stop).
    constexpr float LOOK_SENSITIVITY_X = 18.0f;
    constexpr float LOOK_SENSITIVITY_Y = 14.0f;

    void send_mouse_event(DWORD flags, LONG dx, LONG dy) {
        INPUT in{};
        in.type = INPUT_MOUSE;
        in.mi.dx = dx;
        in.mi.dy = dy;
        in.mi.dwFlags = flags;
        SendInput(1, &in, sizeof(INPUT));
    }

    static float apply_deadzone_and_curve(SHORT raw) {
        if (raw > STICK_DZ) {
            float t = (float)(raw - STICK_DZ) / (float)(32767 - STICK_DZ);
            return t * t;    // quadratic: slow near center, fast at edges
        }
        if (raw < -STICK_DZ) {
            float t = (float)(raw + STICK_DZ) / (float)(32767 - STICK_DZ);
            return -t * t;   // preserve sign
        }
        return 0.0f;
    }

    // Right stick -> mouse delta. The addon toggles WoW's native mouselook
    // (MouselookStart/MouselookStop) based on the same stick deflection, so
    // our mouse-move events feed WoW's camera system without the RMB-held
    // trick that was interfering with keyboard events like SPACE / Jump.
    void drive_camera_look(SHORT rx, SHORT ry, bool focused) {
        if (!focused) return;
        float fx = apply_deadzone_and_curve(rx);
        float fy = apply_deadzone_and_curve(ry);
        if (fx == 0.0f && fy == 0.0f) return;
        LONG dx = (LONG)(fx * LOOK_SENSITIVITY_X);
        LONG dy = (LONG)(-fy * LOOK_SENSITIVITY_Y);
        if (dx != 0 || dy != 0) send_mouse_event(MOUSEEVENTF_MOVE, dx, dy);
    }

    void poller_thread() {
        log_line("[poller] started tid=%lu", GetCurrentThreadId());
        XINPUT_STATE prev{};
        DWORD prev_rc = ERROR_DEVICE_NOT_CONNECTED;

        while (g_running.load(std::memory_order_relaxed)) {
            XINPUT_STATE now{};
            DWORD rc = XInputGetState(0, &now);

            // Update pad::connected on every call so Lua side sees fresh state
            // even without a packet-number change.
            pad::connected.store(rc == ERROR_SUCCESS, std::memory_order_relaxed);

            if (rc != prev_rc) {
                if (rc == ERROR_SUCCESS)                       log_line("[pad0] connected");
                else if (rc == ERROR_DEVICE_NOT_CONNECTED)     log_line("[pad0] disconnected");
                else                                           log_line("[pad0] rc=%lu", rc);
                prev_rc = rc;
            }

            if (rc == ERROR_SUCCESS && now.dwPacketNumber != prev.dwPacketNumber) {
                const XINPUT_GAMEPAD& p = now.Gamepad;
                const XINPUT_GAMEPAD& q = prev.Gamepad;

                // Mirror to atomics
                pad::buttons.store(p.wButtons, std::memory_order_relaxed);
                pad::lt.store(p.bLeftTrigger,  std::memory_order_relaxed);
                pad::rt.store(p.bRightTrigger, std::memory_order_relaxed);
                pad::lx.store(p.sThumbLX, std::memory_order_relaxed);
                pad::ly.store(p.sThumbLY, std::memory_order_relaxed);
                pad::rx.store(p.sThumbRX, std::memory_order_relaxed);
                pad::ry.store(p.sThumbRY, std::memory_order_relaxed);

                on_button_edges(q.wButtons, p.wButtons,
                                p.bLeftTrigger > 128,
                                p.bRightTrigger > 128);
                bool focused = wow_window_has_focus();
                drive_stick_movement(p.sThumbLX, p.sThumbLY, focused);
                drive_camera_look   (p.sThumbRX, p.sThumbRY, focused);
                if (abs((int)p.bLeftTrigger  - (int)q.bLeftTrigger)  > TRIG_DZ)
                    log_line("[pad0] LT=%u", p.bLeftTrigger);
                if (abs((int)p.bRightTrigger - (int)q.bRightTrigger) > TRIG_DZ)
                    log_line("[pad0] RT=%u", p.bRightTrigger);
                if (stick_notable(q.sThumbLX, p.sThumbLX, STICK_DZ) ||
                    stick_notable(q.sThumbLY, p.sThumbLY, STICK_DZ))
                    log_line("[pad0] L stick (%d, %d)", p.sThumbLX, p.sThumbLY);
                if (stick_notable(q.sThumbRX, p.sThumbRX, STICK_DZ) ||
                    stick_notable(q.sThumbRY, p.sThumbRY, STICK_DZ))
                    log_line("[pad0] R stick (%d, %d)", p.sThumbRX, p.sThumbRY);

                prev = now;
            } else if (rc != ERROR_SUCCESS) {
                // When disconnected, clear downstream state so Lua reads see neutral.
                pad::buttons.store(0, std::memory_order_relaxed);
                pad::lt.store(0, std::memory_order_relaxed);
                pad::rt.store(0, std::memory_order_relaxed);
                pad::lx.store(0, std::memory_order_relaxed);
                pad::ly.store(0, std::memory_order_relaxed);
                pad::rx.store(0, std::memory_order_relaxed);
                pad::ry.store(0, std::memory_order_relaxed);
            }
            Sleep(16);
        }
        log_line("[poller] stopped");
    }
}

// ---------------------------------------------------------------------------
// DLL entry
// ---------------------------------------------------------------------------
BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID) {
    switch (reason) {
    case DLL_PROCESS_ATTACH: {
        DisableThreadLibraryCalls(hModule);
        InitializeCriticalSection(&g_log_cs);
        InitializeCriticalSection(&g_reg_cs);
        open_log_next_to_exe();
        log_line("ControllerPatch v1c attached (pid=%lu, built %s %s)",
                 GetCurrentProcessId(), __DATE__, __TIME__);
        patch_fnptr_check();
        if (!install_signalevent_hook()) {
            log_line("[hook] install FAILED - Lua registration will not happen");
        }
        g_running = true;
        std::thread(poller_thread).detach();
        break;
    }
    case DLL_PROCESS_DETACH:
        g_running = false;
        Sleep(32);
        log_line("ControllerPatch v1c detaching");
        if (g_log != INVALID_HANDLE_VALUE) { CloseHandle(g_log); g_log = INVALID_HANDLE_VALUE; }
        DeleteCriticalSection(&g_log_cs);
        DeleteCriticalSection(&g_reg_cs);
        break;
    }
    return TRUE;
}
