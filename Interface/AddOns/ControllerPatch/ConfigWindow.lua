-- ConfigWindow.lua - key binding dialog for all 14 pad inputs
--
-- Scrollable list, click [Base] or [LT] to capture a key. ESC cancels an
-- active capture. Reset button restores defaults.

local CP = ControllerPatch
if not CP or not CP.DLL_READY then return end

local BUTTON_META = {
    { btn = "A",      label = "A button",          group = "Face buttons" },
    { btn = "B",      label = "B button",          group = "Face buttons" },
    { btn = "X",      label = "X button",          group = "Face buttons" },
    { btn = "Y",      label = "Y button",          group = "Face buttons" },
    { btn = "LB",     label = "Left shoulder",     group = "Shoulders" },
    { btn = "RB",     label = "Right shoulder",    group = "Shoulders" },
    { btn = "DUP",    label = "D-pad up",          group = "D-pad" },
    { btn = "DDOWN",  label = "D-pad down",        group = "D-pad" },
    { btn = "DLEFT",  label = "D-pad left",        group = "D-pad" },
    { btn = "DRIGHT", label = "D-pad right",       group = "D-pad" },
    { btn = "START",  label = "Start / Menu",      group = "Center" },
    { btn = "BACK",   label = "Back / View",       group = "Center" },
    { btn = "L3",     label = "Left stick click",  group = "Sticks" },
    { btn = "R3",     label = "Right stick click", group = "Sticks" },
}

local cfg = CreateFrame("Frame", "ControllerPatchConfig", UIParent)
cfg:SetSize(560, 540)
cfg:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
cfg:SetFrameStrata("DIALOG"); cfg:Hide()
cfg:EnableMouse(true); cfg:SetMovable(true); cfg:RegisterForDrag("LeftButton")
cfg:SetScript("OnDragStart", cfg.StartMoving); cfg:SetScript("OnDragStop", cfg.StopMovingOrSizing)

-- Themed backdrop
cfg:SetBackdrop({
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets   = { left = 11, right = 11, top = 12, bottom = 11 },
})
cfg:SetBackdropColor(0.10, 0.05, 0.14, 1.0)
cfg:SetBackdropBorderColor(1.0, 0.85, 0.55, 1.0)

-- Decorative corner gems (same as ability pad)
local function cornerGem(point, dx, dy)
    local core = cfg:CreateTexture(nil, "OVERLAY")
    core:SetTexture(CP.ART_FANCY .. "gem_core")
    core:SetSize(26, 26); core:SetPoint(point, cfg, point, dx, dy)
    core:SetVertexColor(1, 0.85, 0.45); core:SetBlendMode("ADD")
    local frame = cfg:CreateTexture(nil, "OVERLAY", nil, 1)
    frame:SetTexture(CP.ART_FANCY .. "gem_frame")
    frame:SetSize(26, 26); frame:SetPoint(point, cfg, point, dx, dy)
    frame:SetVertexColor(0.9, 0.75, 0.4)
end
cornerGem("TOPLEFT",     22, -16)
cornerGem("TOPRIGHT",   -22, -16)
cornerGem("BOTTOMLEFT",  22,  12)
cornerGem("BOTTOMRIGHT",-22,  12)

local title = cfg:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -22); title:SetTextColor(1, 0.85, 0.95)
title:SetText("ControllerPatch - Key Bindings")

local help = cfg:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
help:SetPoint("TOP", 0, -46); help:SetJustifyH("CENTER")
help:SetTextColor(0.95, 0.80, 0.85)
help:SetText("Click [Base] or [LT] on a row, then press a keyboard key. ESC cancels.")

-- Close button
local close = CreateFrame("Button", nil, cfg, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -6, -6)
close:SetScript("OnClick", function() cfg:Hide() end)

-- Scroll frame
local scroll = CreateFrame("ScrollFrame", "ControllerPatchConfigScroll", cfg, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT",     22, -70)
scroll:SetPoint("BOTTOMRIGHT", -38, 48)

local content = CreateFrame("Frame", nil, scroll)
content:SetSize(500, 10)  -- height set after we know row count
scroll:SetScrollChild(content)

-- Capture state (which row+slot is waiting for a keystroke)
cfg:EnableKeyboard(false)
cfg.capturing = nil
cfg:SetScript("OnKeyDown", function(self, key)
    if not self.capturing then return end
    if key == "ESCAPE" then
        self.capturing.btn_frame:UnlockHighlight()
        self.capturing.txt:SetText("|cffaaaaaa" .. (self.capturing.oldLabel or "") .. "|r")
        self.capturing = nil
        self:EnableKeyboard(false)
        return
    end
    if CP.KEY_TO_VK[key] then
        local meta = self.capturing
        local btn, slot = meta.btn, meta.slot
        CP.DB.keymap[btn] = CP.DB.keymap[btn] or {}
        CP.DB.keymap[btn][slot] = key
        CP.pushToDLL(btn)
        meta.txt:SetText("|cffffffa0" .. key .. "|r")
        meta.btn_frame:UnlockHighlight()
        self.capturing = nil
        self:EnableKeyboard(false)
    end
end)

local function startCapture(btn, slot, oldLabel, txt, btn_frame)
    cfg.capturing = { btn = btn, slot = slot, oldLabel = oldLabel, txt = txt, btn_frame = btn_frame }
    btn_frame:LockHighlight()
    txt:SetText("|cffff80ff(press a key, ESC to cancel)|r")
    cfg:EnableKeyboard(true)
end

-- Row builder
local function makeRow(parent, index, meta)
    local y = -(index - 1) * 38
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(500, 36); row:SetPoint("TOPLEFT", 0, y)

    -- Soft alternating-row background
    if index % 2 == 1 then
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetTexture(0.15, 0.08, 0.17, 0.3); bg:SetAllPoints(row)
    end

    local glyph = row:CreateTexture(nil, "ARTWORK")
    glyph:SetSize(26, 26); glyph:SetPoint("LEFT", 10, 0)
    glyph:SetTexture(CP.ART_GLYPHS .. CP.GLYPH[meta.btn])

    local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    name:SetPoint("LEFT", glyph, "RIGHT", 10, 0); name:SetWidth(140); name:SetJustifyH("LEFT")
    name:SetText(meta.label); name:SetTextColor(1, 0.9, 0.95)

    local baseLbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    baseLbl:SetPoint("LEFT", name, "RIGHT", 6, 0); baseLbl:SetText("|cffaa88a0Base:|r")

    local baseBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    baseBtn:SetSize(78, 22); baseBtn:SetPoint("LEFT", baseLbl, "RIGHT", 4, 0)
    local baseTxt = baseBtn:GetFontString()

    local modLbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    modLbl:SetPoint("LEFT", baseBtn, "RIGHT", 10, 0); modLbl:SetText("|cffaa88a0LT:|r")

    local modBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    modBtn:SetSize(78, 22); modBtn:SetPoint("LEFT", modLbl, "RIGHT", 4, 0)
    local modTxt = modBtn:GetFontString()

    local function refresh()
        local b, m = CP.getMapping(meta.btn)
        baseTxt:SetText((b == "" and "(none)") or b)
        modTxt :SetText((m == "" and "(none)") or m)
    end
    refresh()

    baseBtn:SetScript("OnClick", function()
        startCapture(meta.btn, "base", baseTxt:GetText(), baseTxt, baseBtn)
    end)
    modBtn:SetScript("OnClick", function()
        startCapture(meta.btn, "mod", modTxt:GetText(), modTxt, modBtn)
    end)
    row.refresh = refresh
    return row
end

local rows = {}
for i, meta in ipairs(BUTTON_META) do
    rows[i] = makeRow(content, i, meta)
end
content:SetHeight(#BUTTON_META * 38 + 8)

-- Reset + Apply buttons at the bottom
local resetBtn = CreateFrame("Button", nil, cfg, "UIPanelButtonTemplate")
resetBtn:SetSize(150, 24); resetBtn:SetPoint("BOTTOMLEFT", 24, 14)
resetBtn:SetText("Reset to defaults")
resetBtn:SetScript("OnClick", function()
    CP.DB.keymap = {}; CP.applyAll()
    for _, r in ipairs(rows) do r.refresh() end
end)

local applyBtn = CreateFrame("Button", nil, cfg, "UIPanelButtonTemplate")
applyBtn:SetSize(130, 24); applyBtn:SetPoint("BOTTOMRIGHT", -42, 14)
applyBtn:SetText("Push to DLL")
applyBtn:SetScript("OnClick", function()
    CP.applyAll()
    DEFAULT_CHAT_FRAME:AddMessage("|cffff80ff[ControllerPatch]|r key map sent to DLL.")
end)

cfg:SetScript("OnShow", function()
    for _, r in ipairs(rows) do r.refresh() end
end)

function CP.ToggleConfig()
    if cfg:IsShown() then cfg:Hide() else cfg:Show() end
end
