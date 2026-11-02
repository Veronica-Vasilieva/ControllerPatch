-- ControllerPatch 0.5 - bootstrap + shared state + slash commands
-- Modular; AbilityPad.lua + ConfigWindow.lua load after this.

local ADDON = "ControllerPatch"
ControllerPatch = ControllerPatch or {}
local CP = ControllerPatch

CP.ADDON       = ADDON
CP.ART         = "Interface\\AddOns\\" .. ADDON .. "\\Assets\\"
CP.ART_GLYPHS  = CP.ART .. "GlyphsHD\\"
CP.ART_SHAPES  = CP.ART .. "Shapes\\"
CP.ART_BORDERS = CP.ART .. "Borders\\"
CP.ART_FANCY   = CP.ART .. "Fancy\\"
CP.ART_ICONS   = CP.ART .. "IconsHD\\"

local function HAS(n) return type(_G[n]) == "function" end
CP.HAS = HAS

if not HAS("GamePadConnected") then
    DEFAULT_CHAT_FRAME:AddMessage("|cffff6060[" .. ADDON .. "]|r DLL is not injected - no GamePad* globals. Launch Wow via Launch_WoW.exe.")
    CP.DLL_READY = false
    return
end
CP.DLL_READY   = true
CP.DLL_REMAP_OK = HAS("GamePadSetKeyMapping")

-- ------------------------------------------------------------
-- Button registry (14 pad inputs, each has a base and an LT-held variant)
-- ------------------------------------------------------------
CP.BUTTON_ORDER = {
    "A","B","X","Y",
    "LB","RB",
    "DUP","DDOWN","DLEFT","DRIGHT",
    "START","BACK","L3","R3",
}

CP.GLYPH = {
    A      = "Xbox_A",       B      = "Xbox_B",
    X      = "Xbox_X",       Y      = "Xbox_Y",
    LB     = "Xbox_LB",      RB     = "Xbox_RB",
    LT     = "Xbox_LT",      RT     = "Xbox_RT",
    L3     = "Xbox_LSTICK",  R3     = "Xbox_RSTICK",
    START  = "Xbox_START",   BACK   = "Xbox_SELECT",
    DUP    = "DPad_Up",      DDOWN  = "DPad_Down",
    DLEFT  = "DPad_Left",    DRIGHT = "DPad_Right",
}

-- Default binds mirror the DLL's defaults so round-trip is a no-op first run.
CP.DEFAULTS = {
    A      = { base = "1",  mod = "7" },
    B      = { base = "2",  mod = "8" },
    X      = { base = "3",  mod = "9" },
    Y      = { base = "4",  mod = "0" },
    LB     = { base = "5",  mod = "-" },
    RB     = { base = "6",  mod = "=" },
    DUP    = { base = "F1", mod = "F1" },
    DDOWN  = { base = "F2", mod = "F2" },
    DLEFT  = { base = "F3", mod = "F3" },
    DRIGHT = { base = "F4", mod = "F4" },
    START  = { base = "ESCAPE", mod = "ESCAPE" },
    BACK   = { base = "M",      mod = "M" },
    L3     = { base = "",       mod = "" },
    R3     = { base = "",       mod = "" },
}

-- ------------------------------------------------------------
-- Windows virtual-key tables
-- ------------------------------------------------------------
local KEY_TO_VK = {}
for i = 0, 25 do KEY_TO_VK[string.char(65 + i)] = 0x41 + i end
for i = 0, 9  do KEY_TO_VK[tostring(i)] = 0x30 + i end
for i = 1, 12 do KEY_TO_VK["F" .. i] = 0x6F + i end
KEY_TO_VK.LEFT=0x25; KEY_TO_VK.UP=0x26; KEY_TO_VK.RIGHT=0x27; KEY_TO_VK.DOWN=0x28
KEY_TO_VK.SPACE=0x20; KEY_TO_VK.TAB=0x09; KEY_TO_VK.ENTER=0x0D
KEY_TO_VK.ESCAPE=0x1B; KEY_TO_VK.BACKSPACE=0x08
KEY_TO_VK.INSERT=0x2D; KEY_TO_VK.DELETE=0x2E
KEY_TO_VK.HOME=0x24; KEY_TO_VK["END"]=0x23
KEY_TO_VK.PAGEUP=0x21; KEY_TO_VK.PAGEDOWN=0x22
KEY_TO_VK["-"]=0xBD; KEY_TO_VK["="]=0xBB
KEY_TO_VK["["]=0xDB; KEY_TO_VK["]"]=0xDD
KEY_TO_VK[";"]=0xBA; KEY_TO_VK["'"]=0xDE
KEY_TO_VK[","]=0xBC; KEY_TO_VK["."]=0xBE
KEY_TO_VK["/"]=0xBF; KEY_TO_VK["`"]=0xC0
KEY_TO_VK["\\"]=0xDC
for i = 0, 9 do KEY_TO_VK["NUMPAD" .. i] = 0x60 + i end
CP.KEY_TO_VK = KEY_TO_VK

-- ------------------------------------------------------------
-- Saved variables + DLL sync
-- ------------------------------------------------------------
ControllerPatchDB = ControllerPatchDB or {}
local DB = ControllerPatchDB
DB.keymap = DB.keymap or {}
DB.showAbilityPad = (DB.showAbilityPad == nil) and true or DB.showAbilityPad
DB.showSimpleHUD  = (DB.showSimpleHUD  == nil) and false or DB.showSimpleHUD
CP.DB = DB

function CP.getMapping(btn)
    local saved = DB.keymap[btn]
    local def   = CP.DEFAULTS[btn] or { base="", mod="" }
    local b = (saved and saved.base) or def.base
    local m = (saved and saved.mod)  or def.mod
    return b, m
end

function CP.setMapping(btn, baseName, modName)
    DB.keymap[btn] = { base = baseName or "", mod = modName or "" }
    CP.pushToDLL(btn)
end

local function vkOf(name)
    if not name or name == "" then return 0 end
    return KEY_TO_VK[string.upper(name)] or 0
end

function CP.pushToDLL(btn)
    if not CP.DLL_REMAP_OK then return end
    local b, m = CP.getMapping(btn)
    GamePadSetKeyMapping(btn, vkOf(b), vkOf(m))
end

function CP.applyAll()
    for _, btn in ipairs(CP.BUTTON_ORDER) do CP.pushToDLL(btn) end
end

-- Apply after game systems are up
local bootstrap = CreateFrame("Frame")
bootstrap:RegisterEvent("PLAYER_LOGIN")
bootstrap:SetScript("OnEvent", function()
    CP.applyAll()
    DEFAULT_CHAT_FRAME:AddMessage("|cffff80ff[" .. ADDON .. " 0.5]|r ready. |cffaaaaaa/cp|r for help.")
end)

-- ------------------------------------------------------------
-- UI mode detector
-- When a Blizzard modal frame is open the DLL swaps to UI cursor mode:
--   right stick -> move mouse (no RMB mouselook)
--   A -> left click
--   B -> ESCAPE
-- Everything else keeps its configured mapping.
-- ------------------------------------------------------------
local MODAL_FRAMES = {
    "GameMenuFrame", "WorldMapFrame", "MerchantFrame", "QuestFrame",
    "QuestLogFrame", "QuestLogDetailFrame",
    "CharacterFrame", "PaperDollFrame",
    "SpellBookFrame", "TalentFrame", "PlayerTalentFrame",
    "InterfaceOptionsFrame", "VideoOptionsFrame", "AudioOptionsFrame",
    "OptionsFrame", "ChatConfigFrame", "KeyBindingFrame", "MacroFrame",
    "ContainerFrame1","ContainerFrame2","ContainerFrame3","ContainerFrame4","ContainerFrame5",
    "AuctionFrame", "MailFrame", "BankFrame",
    "FriendsFrame", "WorldStateScoreFrame", "RaidFrame",
    "ReadyCheckFrame", "StackSplitFrame", "DressUpFrame",
    "AchievementFrame", "CalendarFrame", "LFDParentFrame",
    "TradeFrame", "GossipFrame", "PetitionFrame",
    "TaxiFrame", "BarberShopFrame", "GuildBankFrame",
    "ItemSocketingFrame", "ItemTextFrame",
    "ControllerPatchConfig",   -- our own config window counts too
}

local function anyModalOpen()
    for _, name in ipairs(MODAL_FRAMES) do
        local f = _G[name]
        if f and f.IsShown and f:IsShown() then return true end
    end
    -- StaticPopups (confirmation dialogs)
    for i = 1, 4 do
        local f = _G["StaticPopup" .. i]
        if f and f.IsShown and f:IsShown() then return true end
    end
    return false
end

local lastMode
local modeChecker = CreateFrame("Frame")
modeChecker.accum = 0
modeChecker:SetScript("OnUpdate", function(self, elapsed)
    self.accum = self.accum + elapsed
    if self.accum < 0.1 then return end
    self.accum = 0
    if not HAS("GamePadSetMode") then return end
    local mode = anyModalOpen() and "ui" or "game"
    if mode ~= lastMode then
        GamePadSetMode(mode)
        lastMode = mode
    end
end)

-- ------------------------------------------------------------
-- Right stick -> mouselook (addon-side). Toggles MouselookStart /
-- MouselookStop based on stick magnitude so WoW's native camera system
-- consumes the mouse-delta the DLL is sending. Not using RMB-held means
-- keyboard presses (SPACE/Jump, action-bar keys) aren't blocked.
-- ------------------------------------------------------------
local LOOK_DZ = 0.24    -- normalised deadzone (matches DLL's 8000/32767)
local looking = false
local lookDriver = CreateFrame("Frame")
lookDriver.accum = 0
lookDriver:SetScript("OnUpdate", function(self, elapsed)
    self.accum = self.accum + elapsed
    if self.accum < 0.03 then return end
    self.accum = 0

    -- In UI mode we want the cursor visible (so A left-click lands on real
    -- buttons), so suppress mouselook even if the stick is deflected.
    if lastMode == "ui" then
        if looking then MouselookStop(); looking = false end
        return
    end

    local rx = GamePadGetAxis("RX") or 0
    local ry = GamePadGetAxis("RY") or 0
    local mag = math.sqrt(rx*rx + ry*ry)
    local want = mag > LOOK_DZ

    if want and not looking then
        MouselookStart(); looking = true
    elseif not want and looking then
        MouselookStop();  looking = false
    end
end)

-- ------------------------------------------------------------
-- Slash commands
-- ------------------------------------------------------------
SLASH_CONTROLLERPATCH1 = "/cp"
SLASH_CONTROLLERPATCH2 = "/controllerpatch"
SlashCmdList.CONTROLLERPATCH = function(msg)
    msg = (msg or ""):lower():gsub("^%s+",""):gsub("%s+$","")
    if msg == "" or msg == "config" or msg == "bind" or msg == "keys" then
        if CP.ToggleConfig then CP.ToggleConfig() end
    elseif msg == "pad" then
        DB.showAbilityPad = not DB.showAbilityPad
        if CP.RefreshAbilityPad then CP.RefreshAbilityPad() end
    elseif msg == "reset" then
        DB.keymap = {}; CP.applyAll()
        DEFAULT_CHAT_FRAME:AddMessage("|cffff80ff[" .. ADDON .. "]|r key map reset to defaults")
    elseif msg == "apply" then
        CP.applyAll()
    elseif msg == "help" then
        local msgs = {
            "|cffff80ff" .. ADDON .. "|r commands:",
            "  |cffffffa0/cp config|r  - open key binding window",
            "  |cffffffa0/cp pad|r     - toggle the big ability pad",
            "  |cffffffa0/cp apply|r   - re-send the key map to the DLL",
            "  |cffffffa0/cp reset|r   - restore default key map",
        }
        for _, m in ipairs(msgs) do DEFAULT_CHAT_FRAME:AddMessage(m) end
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffff80ff[" .. ADDON .. "]|r unknown. Try /cp help")
    end
end
