-- ActionRing.lua - 8-slice radial action menu
--
-- Hold L3 (left stick click) to open the ring. While it's up, deflect the
-- RIGHT stick in a direction to highlight the matching slice. Release L3
-- to fire the highlighted slice (or center = cancel).
--
-- Each slice sends a configurable keystroke; the user binds those keys
-- to spells / macros / items in WoW's own Keybindings UI. Default binds
-- target 8 unused keys (CTRL+F1..CTRL+F8) so there's no collision with
-- the stock action bar layer.
--
-- Fresh implementation; algorithm is a simple atan2 sector lookup.

local CP = ControllerPatch
if not CP or not CP.DLL_READY then return end

local SHAPES = CP.ART_SHAPES
local GLYPHS = CP.ART_GLYPHS

-- 8 slices in order: starting at 12 o'clock, clockwise
local DEFAULT_SLICES = {
    { label = "Mount",      icon = "Interface\\Icons\\Ability_Mount_RidingHorse" },
    { label = "Potion",     icon = "Interface\\Icons\\INV_Potion_54"              },
    { label = "Hearth",     icon = "Interface\\Icons\\INV_Misc_Rune_01"           },
    { label = "Bags",       icon = "Interface\\Icons\\INV_Misc_Bag_09"            },
    { label = "Logout",     icon = "Interface\\Icons\\Spell_Shadow_Twilight"      },
    { label = "Target self",icon = "Interface\\Icons\\Spell_Nature_FaerieFire"   },
    { label = "Macro 7",    icon = "Interface\\Icons\\INV_Misc_QuestionMark"      },
    { label = "Macro 8",    icon = "Interface\\Icons\\INV_Misc_QuestionMark"      },
}

CP.DB.ring = CP.DB.ring or {}
local DB = CP.DB.ring

-- ============================================================
-- Frame
-- ============================================================
local ring = CreateFrame("Frame", "ControllerPatchActionRing", UIParent)
ring:SetSize(300, 300)
ring:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
ring:SetFrameStrata("DIALOG")
ring:Hide()

local halo = ring:CreateTexture(nil, "BACKGROUND")
halo:SetTexture(SHAPES .. "shape_hexagon_glow")
halo:SetAllPoints(ring)
halo:SetVertexColor(0.6, 0.3, 0.8, 0.5)
halo:SetBlendMode("ADD")

local centerPip = ring:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
centerPip:SetPoint("CENTER", ring, "CENTER", 0, 0)
centerPip:SetText("|cffffff80Action Ring|r")

-- Slice frames arranged around a circle
local slices = {}
local R = 110  -- slice radius from center
for i = 1, 8 do
    local angle = (i - 1) * (math.pi / 4)  -- 12 o'clock = 0, clockwise
    local x =  math.sin(angle) * R
    local y =  math.cos(angle) * R
    local s = CreateFrame("Frame", nil, ring)
    s:SetSize(60, 60)
    s:SetPoint("CENTER", ring, "CENTER", x, y)

    s.bg = s:CreateTexture(nil, "BORDER")
    s.bg:SetTexture(SHAPES .. "shape_hexagon_inner")
    s.bg:SetAllPoints(s)
    s.bg:SetVertexColor(0.07, 0.02, 0.10, 0.95)

    s.icon = s:CreateTexture(nil, "ARTWORK")
    s.icon:SetPoint("TOPLEFT", 6, -6); s.icon:SetPoint("BOTTOMRIGHT", -6, 6)
    s.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    s.ring = s:CreateTexture(nil, "OVERLAY")
    s.ring:SetTexture(SHAPES .. "shape_hexagon_ring")
    s.ring:SetAllPoints(s)
    s.ring:SetVertexColor(1, 0.85, 0.4, 1)

    s.highlight = s:CreateTexture(nil, "OVERLAY", nil, 1)
    s.highlight:SetTexture(SHAPES .. "shape_hexagon_ringpressed")
    s.highlight:SetAllPoints(s)
    s.highlight:SetVertexColor(1, 0.6, 0.9, 1)
    s.highlight:Hide()

    s.label = s:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    s.label:SetPoint("TOP", s, "BOTTOM", 0, -2)

    slices[i] = s
end

local function paintSlices()
    for i, s in ipairs(slices) do
        local def = DEFAULT_SLICES[i]
        s.icon:SetTexture(def.icon)
        s.label:SetText(def.label)
    end
end
paintSlices()

-- Center-screen label of the currently-selected slice
local selLabel = ring:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
selLabel:SetPoint("CENTER", ring, "CENTER", 0, -4)
selLabel:SetTextColor(1, 0.85, 0.95)

-- ============================================================
-- Direction -> slice index (atan2 lookup)
-- ============================================================
local function stickToSlice(rx, ry)
    local mag = math.sqrt(rx*rx + ry*ry)
    if mag < 0.35 then return nil end       -- centered -> no selection
    -- WoW/XInput: positive ry = up. We want slice 1 at "up".
    local angle = math.atan2(rx, ry)        -- 0 = up, +pi/2 = right
    if angle < 0 then angle = angle + 2 * math.pi end
    local slice = math.floor(angle / (math.pi / 4) + 0.5)
    if slice >= 8 then slice = slice - 8 end
    return slice + 1   -- 1..8
end

-- ============================================================
-- Key-press glue: slices send CTRL+F1..CTRL+F8 by default. User binds
-- those in Keybindings. We fire them via SetBinding + ClearBinding of
-- temporary bindings; simpler to just RunMacroText("/click") on a secure
-- button, but we try the RunBinding path first.
-- ============================================================
local SLICE_BINDS = { "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12" }

local function fireSlice(idx)
    local keyname = SLICE_BINDS[idx]
    if not keyname then return end
    local cmd = GetBindingAction(keyname)
    if cmd and cmd ~= "" then
        RunBinding(cmd)
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffffaaaa[CP ring]|r slot " .. idx .. " ("
            .. (DEFAULT_SLICES[idx].label or "?") .. ") - key "
            .. keyname .. " is unbound. Bind it in Keybindings.")
    end
end

-- ============================================================
-- Driver: watch L3 held / released; while held, read R stick, highlight,
-- fire on release.
-- ============================================================
local active = false
local lastSelected = nil
local lastL3 = false

local driver = CreateFrame("Frame")
driver.accum = 0
driver:SetScript("OnUpdate", function(self, elapsed)
    self.accum = self.accum + elapsed
    if self.accum < 0.03 then return end
    self.accum = 0

    local l3 = GamePadGetButton("L3") and true or false

    if l3 and not lastL3 then
        active = true; ring:Show(); lastSelected = nil
    end
    if not l3 and lastL3 then
        if active then
            if lastSelected then fireSlice(lastSelected) end
            active = false; ring:Hide()
        end
    end
    lastL3 = l3

    if active then
        local rx = GamePadGetAxis("RX") or 0
        local ry = GamePadGetAxis("RY") or 0
        local sel = stickToSlice(rx, ry)
        if sel ~= lastSelected then
            for i, s in ipairs(slices) do
                if i == sel then s.highlight:Show() else s.highlight:Hide() end
            end
            selLabel:SetText(sel and ("|cffffff80" .. DEFAULT_SLICES[sel].label .. "|r") or "|cff888888(center = cancel)|r")
            lastSelected = sel
        end
    end
end)
