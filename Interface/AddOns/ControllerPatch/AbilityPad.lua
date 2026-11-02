-- AbilityPad.lua - the big central hex-icon cluster
-- Shows ABXY + LB + RB as hex-framed buttons displaying real action-bar
-- icons. Palette is a soft gold-and-blush theme ("girly"), tinted via
-- SetVertexColor on the ring and glow textures so no new asset is needed
-- per color.

local CP = ControllerPatch
if not CP or not CP.DLL_READY then return end

local BG_TOP    = { 0.08, 0.03, 0.10, 0.70 }   -- dark lavender
local BG_BOTTOM = { 0.02, 0.00, 0.03, 0.90 }
local RING_IDLE = { 1.00, 0.84, 0.40, 1.00 }   -- warm gold
local RING_PRESS= { 1.00, 0.50, 0.80, 1.00 }   -- pink
local GLOW_IDLE = { 0.60, 0.30, 0.80, 0.40 }   -- soft purple
local GLOW_PRESS= { 1.00, 0.70, 0.95, 0.95 }   -- bright pink
local TRIM_GEM  = { 1.00, 0.84, 0.45, 1.00 }   -- gold accent gems

-- ------------------------------------------------------------
-- Hex button constructor
-- ------------------------------------------------------------
-- Each button is a stack of textures:
--   bg   : hexagon_inner (dark fill)
--   icon : the ability texture from GetActionTexture(slot)
--   mask : (we SetTexture on icon and overlay the hex ring to fake a mask;
--          3.3.5a UI doesn't expose SetTexCoord-based masks cleanly, so we
--          crop the icon with SetTexCoord and let the ring frame it.)
--   ring : hexagon_ring (tinted gold / pink)
--   glow : hexagon_glow (tinted purple / pink)
--   glyph: Xbox_A/B/X/Y badge in corner
--   cd   : Blizzard Cooldown frame drawn over
local function createHexButton(parent, size, glyphName)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)

    -- Soft purple halo behind the whole thing (always drawn)
    f.halo = f:CreateTexture(nil, "BACKGROUND")
    f.halo:SetTexture(CP.ART_SHAPES .. "shape_hexagon_glow")
    f.halo:SetSize(size * 1.35, size * 1.35)
    f.halo:SetPoint("CENTER", f, "CENTER", 0, 0)
    f.halo:SetVertexColor(unpack(GLOW_IDLE))
    f.halo:SetBlendMode("ADD")

    -- Dark fill
    f.bg = f:CreateTexture(nil, "BORDER")
    f.bg:SetTexture(CP.ART_SHAPES .. "shape_hexagon_inner")
    f.bg:SetAllPoints(f)
    f.bg:SetVertexColor(0.08, 0.02, 0.12, 0.95)

    -- Ability icon (cropped to a slightly smaller area)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetPoint("TOPLEFT", f, "TOPLEFT", size*0.14, -size*0.14)
    f.icon:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -size*0.14, size*0.14)
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    f.icon:SetDesaturated(nil)

    -- Hex ring (gold, pulses pink on press)
    f.ring = f:CreateTexture(nil, "OVERLAY")
    f.ring:SetTexture(CP.ART_SHAPES .. "shape_hexagon_ring")
    f.ring:SetAllPoints(f)
    f.ring:SetVertexColor(unpack(RING_IDLE))

    -- Press-state ring (bright version shown while pad button is held)
    f.ringPressed = f:CreateTexture(nil, "OVERLAY")
    f.ringPressed:SetTexture(CP.ART_SHAPES .. "shape_hexagon_ringpressed")
    f.ringPressed:SetAllPoints(f)
    f.ringPressed:SetVertexColor(unpack(RING_PRESS))
    f.ringPressed:Hide()

    -- Pad glyph badge in the top-left corner
    if glyphName then
        f.glyph = f:CreateTexture(nil, "OVERLAY", nil, 2)
        f.glyph:SetTexture(CP.ART_GLYPHS .. glyphName)
        f.glyph:SetSize(size * 0.42, size * 0.42)
        f.glyph:SetPoint("TOPLEFT", f, "TOPLEFT", -size*0.06, size*0.06)
    end

    -- Cooldown sweep (standard Blizzard template)
    f.cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
    f.cd:SetAllPoints(f.icon)
    f.cd:SetDrawEdge(false)

    -- Slot number label (small, under the icon)
    f.slotLabel = f:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    f.slotLabel:SetPoint("BOTTOM", f, "BOTTOM", 0, -size*0.18)
    f.slotLabel:SetTextColor(1, 0.9, 0.6)

    f.setPressed = function(self, pressed)
        if pressed then
            self.ring:Hide();       self.ringPressed:Show()
            self.halo:SetVertexColor(unpack(GLOW_PRESS))
        else
            self.ring:Show();       self.ringPressed:Hide()
            self.halo:SetVertexColor(unpack(GLOW_IDLE))
        end
    end
    return f
end

-- ------------------------------------------------------------
-- Main cluster frame
-- ------------------------------------------------------------
local pad = CreateFrame("Frame", "ControllerPatchAbilityPad", UIParent)
pad:SetSize(540, 260)
pad:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 170)
pad:SetFrameStrata("MEDIUM")

-- Soft gradient background (gold-edged lavender)
pad:SetBackdrop({
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets   = { left = 4, right = 4, top = 4, bottom = 4 },
})
pad:SetBackdropColor(0.08, 0.03, 0.10, 0.75)
pad:SetBackdropBorderColor(1.0, 0.82, 0.6, 1.0)

-- Decorative gem accents (just visual flair)
local function makeGem(point, dx, dy)
    local t = pad:CreateTexture(nil, "OVERLAY")
    t:SetTexture(CP.ART_FANCY .. "gem_core")
    t:SetSize(28, 28); t:SetPoint(point, pad, point, dx, dy)
    t:SetVertexColor(unpack(TRIM_GEM))
    t:SetBlendMode("ADD")
    local f = pad:CreateTexture(nil, "OVERLAY", nil, 1)
    f:SetTexture(CP.ART_FANCY .. "gem_frame")
    f:SetSize(28, 28); f:SetPoint(point, pad, point, dx, dy)
    f:SetVertexColor(0.9, 0.75, 0.4)
end
makeGem("TOPLEFT",     8,  -8)
makeGem("TOPRIGHT",   -8,  -8)
makeGem("BOTTOMLEFT",  8,   8)
makeGem("BOTTOMRIGHT",-8,   8)

-- Title
local title = pad:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", pad, "TOP", 0, -4)
title:SetTextColor(1, 0.85, 0.95)
title:SetText("ControllerPatch")

local layerLabel = pad:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
layerLabel:SetPoint("TOP", title, "BOTTOM", 0, -2)

local BIG = 72    -- large face-button size
local SHOULDER = 64

-- Diamond: Y top, A bottom, X left, B right
local btnY = createHexButton(pad, BIG, "Xbox_Y"); btnY:SetPoint("CENTER", pad, "CENTER",   0, 50)
local btnA = createHexButton(pad, BIG, "Xbox_A"); btnA:SetPoint("CENTER", pad, "CENTER",   0, -70)
local btnX = createHexButton(pad, BIG, "Xbox_X"); btnX:SetPoint("CENTER", pad, "CENTER", -75, -10)
local btnB = createHexButton(pad, BIG, "Xbox_B"); btnB:SetPoint("CENTER", pad, "CENTER",  75, -10)

-- Shoulder flanks: LB left, RB right
local btnLB = createHexButton(pad, SHOULDER, "Xbox_LB"); btnLB:SetPoint("CENTER", pad, "CENTER", -175, 30)
local btnRB = createHexButton(pad, SHOULDER, "Xbox_RB"); btnRB:SetPoint("CENTER", pad, "CENTER",  175, 30)

-- Trigger pips (status only - LT lights up when held as modifier)
local function makeTrigger(glyphName)
    local f = CreateFrame("Frame", nil, pad)
    f:SetSize(42, 42)
    local tex = f:CreateTexture(nil, "ARTWORK"); tex:SetAllPoints(f)
    tex:SetTexture(CP.ART_GLYPHS .. glyphName)
    f.tex = tex
    f.setPressed = function(self, p)
        self.tex:SetVertexColor(p and 1 or 0.55, p and 1 or 0.55, p and 1 or 0.55, 0.95)
    end
    f:setPressed(false)
    return f
end
local trigLT = makeTrigger("Xbox_LT"); trigLT:SetPoint("CENTER", pad, "CENTER", -175, 95)
local trigRT = makeTrigger("Xbox_RT"); trigRT:SetPoint("CENTER", pad, "CENTER",  175, 95)

-- Small D-pad cluster at far left
local dpad = CreateFrame("Frame", nil, pad); dpad:SetSize(80, 80)
dpad:SetPoint("CENTER", pad, "CENTER", -220, -90)
local function dpadGlyph(parent, g)
    local f = CreateFrame("Frame", nil, parent); f:SetSize(26, 26)
    local t = f:CreateTexture(nil, "ARTWORK"); t:SetAllPoints(f)
    t:SetTexture(CP.ART_GLYPHS .. CP.GLYPH[g])
    f.tex = t
    f.setPressed = function(self, p) self.tex:SetVertexColor(p and 1 or 0.6, p and 1 or 0.6, p and 1 or 0.6, 0.95) end
    f:setPressed(false)
    return f
end
local dpU = dpadGlyph(dpad, "DUP");    dpU:SetPoint("TOP",    dpad, "TOP",    0,  0)
local dpD = dpadGlyph(dpad, "DDOWN");  dpD:SetPoint("BOTTOM", dpad, "BOTTOM", 0,  0)
local dpL = dpadGlyph(dpad, "DLEFT");  dpL:SetPoint("LEFT",   dpad, "LEFT",   0,  0)
local dpR = dpadGlyph(dpad, "DRIGHT"); dpR:SetPoint("RIGHT",  dpad, "RIGHT",  0,  0)

-- Secondary buttons (START/BACK/L3/R3) as small pips on the right
local function miniGlyph(parent, g)
    local f = CreateFrame("Frame", nil, parent); f:SetSize(24, 24)
    local t = f:CreateTexture(nil, "ARTWORK"); t:SetAllPoints(f)
    t:SetTexture(CP.ART_GLYPHS .. CP.GLYPH[g])
    f.tex = t
    f.setPressed = function(self, p) self.tex:SetVertexColor(p and 1 or 0.55, p and 1 or 0.55, p and 1 or 0.55, 0.95) end
    f:setPressed(false)
    return f
end
local miniSTART = miniGlyph(pad, "START"); miniSTART:SetPoint("CENTER", pad, "CENTER",  220, -70)
local miniBACK  = miniGlyph(pad, "BACK");  miniBACK:SetPoint( "CENTER", pad, "CENTER",  220, -98)
local miniL3    = miniGlyph(pad, "L3");    miniL3:SetPoint(   "CENTER", pad, "CENTER", -220, -45)
local miniR3    = miniGlyph(pad, "R3");    miniR3:SetPoint(   "CENTER", pad, "CENTER",  248, -70)

-- Drag by any part of the backdrop (so icons stay clickable later)
pad:SetMovable(true); pad:EnableMouse(true); pad:RegisterForDrag("LeftButton")
pad:SetScript("OnDragStart", pad.StartMoving); pad:SetScript("OnDragStop", pad.StopMovingOrSizing)

-- ------------------------------------------------------------
-- Dynamic action-bar linkage
-- ------------------------------------------------------------
-- Map pad face/shoulder button -> action slot number per layer
local SLOT = {
    [1] = { A=1, B=2, X=3, Y=4, LB=5,  RB=6  },
    [2] = { A=7, B=8, X=9, Y=10, LB=11, RB=12 },
}

local faceWidget = { A = btnA, B = btnB, X = btnX, Y = btnY, LB = btnLB, RB = btnRB }
local function slotFor(btn, layer) return SLOT[layer][btn] end

local function updateIcon(btn, widget, layer)
    local slot = slotFor(btn, layer)
    widget.slotLabel:SetText(tostring(slot))
    if HasAction and HasAction(slot) and GetActionTexture then
        local tex = GetActionTexture(slot)
        if tex then
            widget.icon:SetTexture(tex)
            widget.icon:SetVertexColor(1, 1, 1, 1)
        else
            widget.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
            widget.icon:SetVertexColor(0.5, 0.5, 0.5, 0.7)
        end
    else
        widget.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        widget.icon:SetVertexColor(0.4, 0.4, 0.4, 0.6)
    end
    -- Cooldown sweep
    if GetActionCooldown then
        local start, duration = GetActionCooldown(slot)
        if start and duration and duration > 1.5 then
            widget.cd:SetCooldown(start, duration)
        else
            widget.cd:Hide(); widget.cd:Show()  -- clear
        end
    end
end

-- ------------------------------------------------------------
-- OnUpdate - polls pad state, updates everything at ~20 Hz
-- ------------------------------------------------------------
local accum = 0
local last_lt_held = false
pad:SetScript("OnUpdate", function(self, elapsed)
    accum = accum + elapsed
    if accum < 0.08 then return end
    accum = 0

    local lt = GamePadGetTrigger("LT") or 0
    local rt = GamePadGetTrigger("RT") or 0
    local lt_held = (lt > 0.5)
    local layer = lt_held and 2 or 1

    layerLabel:SetTextColor(lt_held and 1 or 0.75, lt_held and 0.65 or 0.75, lt_held and 0.85 or 0.75)
    layerLabel:SetText(lt_held and "|cffff80ffLayer 2 (LT held)|r" or "Layer 1")

    -- Update face/shoulder slots (only on layer change or every ~1s to keep cheap)
    if lt_held ~= last_lt_held or (math.random() < 0.15) then
        for btn, w in pairs(faceWidget) do updateIcon(btn, w, layer) end
        last_lt_held = lt_held
    end

    -- Press feedback
    for btn, w in pairs(faceWidget) do
        w:setPressed(GamePadGetButton(btn) and true or false)
    end
    trigLT:setPressed(lt > 0.3)
    trigRT:setPressed(rt > 0.3)
    dpU:setPressed(GamePadGetButton("DUP")    or false)
    dpD:setPressed(GamePadGetButton("DDOWN")  or false)
    dpL:setPressed(GamePadGetButton("DLEFT")  or false)
    dpR:setPressed(GamePadGetButton("DRIGHT") or false)
    miniSTART:setPressed(GamePadGetButton("START") or false)
    miniBACK :setPressed(GamePadGetButton("BACK")  or false)
    miniL3   :setPressed(GamePadGetButton("L3")    or false)
    miniR3   :setPressed(GamePadGetButton("R3")    or false)
end)

function CP.RefreshAbilityPad()
    if CP.DB.showAbilityPad then pad:Show() else pad:Hide() end
end
CP.RefreshAbilityPad()
