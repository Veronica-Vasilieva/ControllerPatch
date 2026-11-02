-- UICursor.lua - D-pad driven cursor for Blizzard modal frames
--
-- When a modal UI opens the DLL swaps to "ui" mode which suppresses
-- A/B/X/Y and the D-pad. This module then takes over:
--
--   D-pad      move focus to the nearest clickable widget in that direction
--   A          Click() the focused widget
--   B          close the top-most modal (ESCAPE)
--   X, Y       (reserved for later: back / tab navigation)
--
-- The highlight overlay uses the same gold hex ring the ability pad uses,
-- so the look stays consistent.
--
-- Fresh implementation, not a port of any existing addon's code.

local CP = ControllerPatch
if not CP or not CP.DLL_READY then return end

local cursor = { active = false, focused = nil }
CP.UICursor = cursor

-- ------------------------------------------------------------
-- Clickable discovery
-- ------------------------------------------------------------
local function isClickable(obj)
    if not obj or type(obj) ~= "table" then return false end
    if not obj.GetObjectType or not obj.IsVisible then return false end
    local t = obj:GetObjectType()
    if t ~= "Button" and t ~= "CheckButton" then return false end
    if not obj:IsVisible() then return false end
    if obj.IsEnabled and obj:IsEnabled() == 0 then return false end
    local w, h = obj:GetWidth(), obj:GetHeight()
    if (w or 0) < 4 or (h or 0) < 4 then return false end
    return true
end

local function collect(parent, acc, depth)
    if depth > 8 then return end
    if not parent or not parent.GetChildren then return end
    local n = select("#", parent:GetChildren())
    for i = 1, n do
        local child = select(i, parent:GetChildren())
        if child then
            if isClickable(child) then
                table.insert(acc, child)
            end
            if child.GetChildren then collect(child, acc, depth + 1) end
        end
    end
end

function cursor.findAllClickables()
    local acc = {}
    for _, name in ipairs(CP.MODAL_FRAMES or {}) do
        local f = _G[name]
        if f and f.IsShown and f:IsShown() then collect(f, acc, 1) end
    end
    for i = 1, 4 do
        local f = _G["StaticPopup" .. i]
        if f and f.IsShown and f:IsShown() then collect(f, acc, 1) end
    end
    return acc
end

-- ------------------------------------------------------------
-- Highlight overlay (reuses hex-ring art for consistency)
-- ------------------------------------------------------------
local overlay = CreateFrame("Frame", "ControllerPatchCursorOverlay", UIParent)
overlay:SetFrameStrata("TOOLTIP"); overlay:Hide()
local ring = overlay:CreateTexture(nil, "OVERLAY")
ring:SetTexture(CP.ART_SHAPES .. "shape_rounded_ring")
ring:SetAllPoints(overlay)
ring:SetVertexColor(1, 0.85, 0.4, 1)
local glow = overlay:CreateTexture(nil, "ARTWORK")
glow:SetTexture(CP.ART_SHAPES .. "shape_rounded_glow")
glow:SetAllPoints(overlay)
glow:SetVertexColor(1, 0.6, 0.9, 0.5)
glow:SetBlendMode("ADD")

local function pulse(t)
    local a = 0.5 + 0.3 * math.sin(t * 6)
    glow:SetAlpha(a)
end

local function anchorToFocus()
    local b = cursor.focused
    if not b or not b.IsVisible or not b:IsVisible() then
        overlay:Hide(); return
    end
    overlay:ClearAllPoints()
    overlay:SetPoint("TOPLEFT",     b, "TOPLEFT",     -6,  6)
    overlay:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT",  6, -6)
    overlay:Show()
end

function cursor.focus(b)
    cursor.focused = b
    anchorToFocus()
end

-- ------------------------------------------------------------
-- Directional navigation
-- ------------------------------------------------------------
local function scoreCandidate(from, to, dir)
    local fx, fy = from:GetCenter()
    local tx, ty = to:GetCenter()
    if not fx or not tx then return math.huge end
    local dx = tx - fx
    local dy = ty - fy
    local primary, cross
    if dir == "right" then
        if dx <= 1 then return math.huge end
        primary, cross = dx, dy
    elseif dir == "left" then
        if dx >= -1 then return math.huge end
        primary, cross = -dx, dy
    elseif dir == "up" then
        if dy <= 1 then return math.huge end
        primary, cross = dy, dx
    elseif dir == "down" then
        if dy >= -1 then return math.huge end
        primary, cross = -dy, dx
    else
        return math.huge
    end
    return primary + math.abs(cross) * 2.5
end

function cursor.move(dir)
    local all = cursor.findAllClickables()
    if #all == 0 then return end
    if not cursor.focused or not cursor.focused:IsVisible() then
        cursor.focus(all[1]); return
    end
    local best, bestScore = nil, math.huge
    for _, b in ipairs(all) do
        if b ~= cursor.focused then
            local s = scoreCandidate(cursor.focused, b, dir)
            if s < bestScore then best, bestScore = b, s end
        end
    end
    if best then cursor.focus(best) end
end

function cursor.activate()
    local b = cursor.focused
    if b and b:IsVisible() and b.Click then b:Click() end
end

function cursor.close()
    -- Prefer calling the modal's own close function if available,
    -- otherwise fall back to the ESCAPE binding.
    for _, name in ipairs(CP.MODAL_FRAMES or {}) do
        local f = _G[name]
        if f and f.IsShown and f:IsShown() then
            if f.Hide then f:Hide(); return end
        end
    end
end

-- ------------------------------------------------------------
-- Pad input (edge-detected while active)
-- ------------------------------------------------------------
local prev = {}
local function edge(name)
    local now = GamePadGetButton(name) and true or false
    local was = prev[name] or false
    prev[name] = now
    return now and not was
end

local drive = CreateFrame("Frame")
drive.accum = 0
drive:SetScript("OnUpdate", function(self, elapsed)
    self.accum = self.accum + elapsed
    if cursor.active and cursor.focused then pulse(GetTime() or 0) end
    if self.accum < 0.08 then return end
    self.accum = 0

    if not cursor.active then return end

    -- If current focus becomes invisible (dialog closed, button hidden) retarget
    if cursor.focused and not cursor.focused:IsVisible() then
        cursor.focused = nil
        overlay:Hide()
    end

    if edge("DUP")    then cursor.move("up")    end
    if edge("DDOWN")  then cursor.move("down")  end
    if edge("DLEFT")  then cursor.move("left")  end
    if edge("DRIGHT") then cursor.move("right") end
    if edge("A")      then cursor.activate()    end
    if edge("B")      then cursor.close()       end
end)

function cursor.setActive(on)
    cursor.active = on and true or false
    if not on then
        overlay:Hide()
        cursor.focused = nil
        -- Reset edge-detector so a button held through the mode transition
        -- doesn't fire as a fresh press on the way back out.
        for k in pairs(prev) do prev[k] = false end
    else
        -- Seed with first clickable
        local all = cursor.findAllClickables()
        if #all > 0 then cursor.focus(all[1]) end
    end
end
