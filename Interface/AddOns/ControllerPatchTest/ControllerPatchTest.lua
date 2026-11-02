-- ControllerPatchTest - a tiny addon that proves the ControllerPatch DLL's
-- Lua globals work end-to-end. Draws a small frame top-left that updates at
-- ~20 Hz with the live pad state.
--
-- If this frame shows real values that change when you move sticks / press
-- buttons, Phase 4b is validated. If it shows "nil" or doesn't update, the
-- globals aren't reaching the UI's Lua state.

local f = CreateFrame("Frame", "ControllerPatchTestFrame", UIParent)
f:SetSize(260, 160)
f:SetPoint("TOPLEFT", 24, -24)
f:SetFrameStrata("HIGH")

f:SetBackdrop({
    bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true, tileSize = 8, edgeSize = 8,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
})
f:SetBackdropColor(0, 0, 0, 0.75)

local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", f, "TOP", 0, -6)
title:SetText("|cff00ff00ControllerPatch v1c|r")

local body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
body:SetPoint("TOPLEFT",  f, "TOPLEFT",  10, -24)
body:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 8)
body:SetJustifyH("LEFT")
body:SetJustifyV("TOP")

-- Movable - drag with left mouse
f:SetMovable(true)
f:EnableMouse(true)
f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", f.StartMoving)
f:SetScript("OnDragStop",  f.StopMovingOrSizing)

local BUTTONS = { "A","B","X","Y","LB","RB","L3","R3",
                  "START","BACK","DUP","DDOWN","DLEFT","DRIGHT" }

local function has(name)
    return type(_G[name]) == "function"
end

local function fmtAxis(name)
    if not has("GamePadGetAxis") then return "nil" end
    local v = GamePadGetAxis(name)
    if v == nil then return "nil" end
    return string.format("%+.3f", v)
end

local function fmtTrig(name)
    if not has("GamePadGetTrigger") then return "nil" end
    local v = GamePadGetTrigger(name)
    if v == nil then return "nil" end
    return string.format("%.3f", v)
end

local accum = 0
f:SetScript("OnUpdate", function(self, elapsed)
    accum = accum + elapsed
    if accum < 0.05 then return end
    accum = 0

    local lines = {}

    if has("GamePadConnected") then
        local ok = GamePadConnected()
        local col = ok and "|cff00ff00" or "|cffff6060"
        table.insert(lines, "connected: " .. col .. tostring(ok) .. "|r")
    else
        table.insert(lines, "|cffff6060GamePad* globals not registered|r")
    end

    table.insert(lines,
        "L stick:  " .. fmtAxis("LX") .. ", " .. fmtAxis("LY"))
    table.insert(lines,
        "R stick:  " .. fmtAxis("RX") .. ", " .. fmtAxis("RY"))
    table.insert(lines,
        "triggers: LT " .. fmtTrig("LT") .. "   RT " .. fmtTrig("RT"))

    local held = {}
    if has("GamePadGetButton") then
        for _, n in ipairs(BUTTONS) do
            if GamePadGetButton(n) then held[#held+1] = n end
        end
    end
    table.insert(lines,
        "buttons:  " .. ((#held > 0) and table.concat(held, " ") or "(none)"))

    body:SetText(table.concat(lines, "\n"))
end)

print("|cff00ff00[ControllerPatchTest]|r loaded - drag the frame to move it")
