-- TargetHUD.lua - prominent current-target card + party selector row
-- Shows under the top-center of the screen. Reads live from UnitExists /
-- UnitHealth / UnitHealthMax etc.
-- Fresh implementation, not a port.

local CP = ControllerPatch
if not CP or not CP.DLL_READY then return end

local ART = CP.ART_GLYPHS
local SHAPES = CP.ART_SHAPES

local CLASS_COLORS = {
    DEATHKNIGHT = { 0.77, 0.12, 0.23 }, DRUID     = { 1.00, 0.49, 0.04 },
    HUNTER      = { 0.67, 0.83, 0.45 }, MAGE      = { 0.41, 0.80, 0.94 },
    PALADIN     = { 0.96, 0.55, 0.73 }, PRIEST    = { 1.00, 1.00, 1.00 },
    ROGUE       = { 1.00, 0.96, 0.41 }, SHAMAN    = { 0.00, 0.44, 0.87 },
    WARLOCK     = { 0.58, 0.51, 0.79 }, WARRIOR   = { 0.78, 0.61, 0.43 },
}
local function colorFor(cls)
    local c = CLASS_COLORS[cls or ""]; if c then return c[1], c[2], c[3] end
    return 1, 0.85, 0.95
end

-- ============================================================
-- Big current-target card
-- ============================================================
local card = CreateFrame("Frame", "ControllerPatchTargetCard", UIParent)
card:SetSize(380, 72)
card:SetPoint("TOP", UIParent, "TOP", 0, -18)
card:SetFrameStrata("MEDIUM")
card:SetBackdrop({
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 10,
    insets   = { left = 3, right = 3, top = 3, bottom = 3 },
})
card:SetBackdropColor(0.08, 0.03, 0.10, 0.85)
card:SetBackdropBorderColor(1, 0.85, 0.55, 1)
card:SetMovable(true); card:EnableMouse(true); card:RegisterForDrag("LeftButton")
card:SetScript("OnDragStart", card.StartMoving)
card:SetScript("OnDragStop",  card.StopMovingOrSizing)
card:Hide()

local portrait = card:CreateTexture(nil, "ARTWORK")
portrait:SetSize(56, 56); portrait:SetPoint("LEFT", card, "LEFT", 8, 0)
SetPortraitTexture(portrait, "target")

local nameT = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
nameT:SetPoint("TOPLEFT", portrait, "TOPRIGHT", 10, -2)

local levelT = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
levelT:SetPoint("TOPLEFT", nameT, "BOTTOMLEFT", 0, -2)

local hpBg = card:CreateTexture(nil, "ARTWORK")
hpBg:SetTexture(0.15, 0.05, 0.07, 0.9)
hpBg:SetPoint("TOPLEFT", portrait, "TOPRIGHT", 10, -32)
hpBg:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -10, 10)

local hpFill = card:CreateTexture(nil, "ARTWORK", nil, 1)
hpFill:SetTexture(0.3, 0.9, 0.4, 1)
hpFill:SetPoint("TOPLEFT", hpBg, "TOPLEFT", 0, 0)
hpFill:SetPoint("BOTTOMLEFT", hpBg, "BOTTOMLEFT", 0, 0)

local hpTxt = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
hpTxt:SetPoint("CENTER", hpBg, "CENTER", 0, 0)
hpTxt:SetShadowOffset(1, -1)

local function refreshCard()
    if not UnitExists("target") then card:Hide(); return end
    card:Show()
    SetPortraitTexture(portrait, "target")
    local n = UnitName("target") or "?"
    local _, cls = UnitClass("target")
    local r, g, b = colorFor(cls)
    nameT:SetText(n); nameT:SetTextColor(r, g, b)
    local lvl = UnitLevel("target"); local lvltxt = (lvl and lvl > 0) and tostring(lvl) or "??"
    local isPlayer = UnitIsPlayer("target")
    levelT:SetText(("|cffaaaaaaLevel|r %s %s"):format(lvltxt, isPlayer and (UnitRace("target") or "") or (UnitCreatureType("target") or "")))

    local hp, hpMax = UnitHealth("target"), UnitHealthMax("target")
    if (hpMax or 0) > 0 then
        local w = hpBg:GetWidth() or 0
        hpFill:SetPoint("BOTTOMRIGHT", hpBg, "BOTTOMLEFT", w * (hp / hpMax), 0)
        hpTxt:SetText(("%d / %d  (%d%%)"):format(hp, hpMax, math.floor(100 * hp / hpMax)))
    else
        hpTxt:SetText("")
    end
end

-- ============================================================
-- Party selector row (self + party1..4)
-- ============================================================
local party = CreateFrame("Frame", "ControllerPatchParty", UIParent)
party:SetSize(540, 72)
party:SetPoint("TOP", card, "BOTTOM", 0, -6)
party:SetMovable(true); party:EnableMouse(true); party:RegisterForDrag("LeftButton")
party:SetScript("OnDragStart", party.StartMoving)
party:SetScript("OnDragStop",  party.StopMovingOrSizing)

-- Each slot: pad glyph badge, portrait, name, HP bar
local SLOT_SIZE = 102
local SLOTS = {
    { unit = "player", glyph = "DPad_Up",    label = "self"   },
    { unit = "party1", glyph = "DPad_Down",  label = "party1" },
    { unit = "party2", glyph = "DPad_Left",  label = "party2" },
    { unit = "party3", glyph = "DPad_Right", label = "party3" },
    { unit = "party4", glyph = nil,          label = "party4" },
}

local slotFrames = {}
for i, s in ipairs(SLOTS) do
    local f = CreateFrame("Frame", nil, party)
    f:SetSize(SLOT_SIZE, 72)
    f:SetPoint("LEFT", party, "LEFT", (i - 1) * (SLOT_SIZE + 4), 0)
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    f:SetBackdropColor(0.06, 0.02, 0.08, 0.85)
    f:SetBackdropBorderColor(0.65, 0.45, 0.65, 0.9)

    f.portrait = f:CreateTexture(nil, "ARTWORK")
    f.portrait:SetSize(36, 36); f.portrait:SetPoint("TOPLEFT", 6, -6)

    if s.glyph then
        f.glyph = f:CreateTexture(nil, "OVERLAY")
        f.glyph:SetTexture(ART .. s.glyph)
        f.glyph:SetSize(22, 22)
        f.glyph:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", -3, -3)
    end

    f.name = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.name:SetPoint("TOPLEFT", f.portrait, "TOPRIGHT", 4, 0)
    f.name:SetJustifyH("LEFT"); f.name:SetWidth(SLOT_SIZE - 50)

    f.hpBg = f:CreateTexture(nil, "ARTWORK")
    f.hpBg:SetTexture(0.15, 0.04, 0.07, 0.9)
    f.hpBg:SetPoint("TOPLEFT", f.portrait, "TOPRIGHT", 4, -16)
    f.hpBg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 24)

    f.hpFill = f:CreateTexture(nil, "ARTWORK", nil, 1)
    f.hpFill:SetTexture(0.3, 0.9, 0.4, 1)
    f.hpFill:SetPoint("TOPLEFT", f.hpBg, "TOPLEFT", 0, 0)
    f.hpFill:SetPoint("BOTTOMLEFT", f.hpBg, "BOTTOMLEFT", 0, 0)

    f.hpTxt = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.hpTxt:SetPoint("CENTER", f.hpBg, "CENTER", 0, 0)

    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.hint:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 6)
    f.hint:SetTextColor(1, 0.85, 0.5)
    f.hint:SetText(s.label)

    slotFrames[i] = f
end

local function refreshParty()
    local hasParty = GetNumPartyMembers and (GetNumPartyMembers() or 0) > 0
    party:SetAlpha(hasParty and 1 or 0.55)
    for i, s in ipairs(SLOTS) do
        local f = slotFrames[i]
        if UnitExists(s.unit) then
            f:Show()
            SetPortraitTexture(f.portrait, s.unit)
            local n = UnitName(s.unit) or ""
            local _, cls = UnitClass(s.unit)
            local r, g, b = colorFor(cls)
            f.name:SetText(n); f.name:SetTextColor(r, g, b)
            local hp, hpMax = UnitHealth(s.unit), UnitHealthMax(s.unit)
            if (hpMax or 0) > 0 then
                local w = f.hpBg:GetWidth() or 0
                f.hpFill:SetPoint("BOTTOMRIGHT", f.hpBg, "BOTTOMLEFT", w * (hp / hpMax), 0)
                f.hpTxt:SetText(("%d%%"):format(math.floor(100 * hp / hpMax)))
            else
                f.hpTxt:SetText("")
            end
            local targeted = UnitIsUnit(s.unit, "target")
            if targeted then f:SetBackdropBorderColor(1, 0.85, 0.3, 1)
            else             f:SetBackdropBorderColor(0.65, 0.45, 0.65, 0.9) end
        else
            f.name:SetText("|cff666666(empty)|r")
            f.portrait:SetTexture("Interface\\CharacterFrame\\TempPortrait")
            f.portrait:SetVertexColor(0.3, 0.3, 0.3)
            f.hpFill:SetPoint("BOTTOMRIGHT", f.hpBg, "BOTTOMLEFT", 0, 0)
            f.hpTxt:SetText("")
            f:SetBackdropBorderColor(0.3, 0.3, 0.35, 0.7)
        end
    end
end

-- ============================================================
-- Drive loop (~15 Hz, cheap)
-- ============================================================
local tick = CreateFrame("Frame")
tick.accum = 0
tick:SetScript("OnUpdate", function(self, elapsed)
    self.accum = self.accum + elapsed
    if self.accum < 0.07 then return end
    self.accum = 0
    refreshCard()
    refreshParty()
end)
