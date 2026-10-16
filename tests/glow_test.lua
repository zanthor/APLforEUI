-- CDM glow on stock EUI (Glow.lua): finds the suggested spell's Blizzard
-- viewer icon and drives EllesmereUI.Glows on our own overlay. Also the
-- Widgets > CDM Glow settings page.
-- usage: lua tests/glow_test.lua <addonDir>
local dir = arg[1]

local calls = {}
local plugin
local rows = {}
local STYLES = {
    { name = "Pixel Glow", procedural = true }, { name = "Action Button Glow", buttonGlow = true },
    { name = "Auto-Cast Shine", autocast = true }, { name = "Shape Glow", shapeGlow = true },
    { name = "GCD" }, { name = "Modern WoW Glow" }, { name = "Classic WoW Glow" },
    { name = "Blackout", solidFill = true },
}
EllesmereUI = {
    Glows = {
        STYLES = STYLES,
        StartGlow = function(wrapper, style, w, r, g, b, opts, h)
            calls[#calls + 1] = { op = "start", wrapper = wrapper, style = style, w = w, h = h, r = r, opts = opts }
            wrapper._on = true
        end,
        StopGlow = function(wrapper)
            calls[#calls + 1] = { op = "stop", wrapper = wrapper }
            wrapper._on = false
        end,
    },
    RegisterPlugin = function(_, spec) plugin = spec; return true end,
    Widgets = {},
}
function EllesmereUI:RefreshPage() end
function EllesmereUI.Widgets:SectionHeader() return CreateFrame("Frame"), 30 end
function EllesmereUI.Widgets:DualRow(_, _, l, r)
    for _, cfg in ipairs({ l or false, r or false }) do if cfg then rows[#rows + 1] = cfg end end
    return CreateFrame("Frame"), 50
end

local S, ns = dofile(dir .. "/tests/mock_wow.lua")(dir)

local fails = 0
local function Check(ok, msg)
    if not ok then fails = fails + 1; print_real("FAIL: " .. msg) end
end

local tickFn
C_Timer.NewTicker = function(_, fn)
    tickFn = fn
    return { Cancel = function() tickFn = nil end }
end
local SECRET = {}
issecretvalue = function(v) return v == SECRET end

local XUEN, TP, ZENITH = 123904, 100780, 1249625
local function Item(id, width)
    local f = CreateFrame("Frame")
    f.GetSpellID = function() return id end
    f.GetBaseSpellID = function() return id end
    f.IsShown = function() return true end
    f.GetWidth = function() return width or 40 end
    f.GetHeight = function() return width or 40 end
    return f
end
local xuenItem, tpItem = Item(XUEN), Item(TP)
local items = { tpItem, xuenItem }
EssentialCooldownViewer = { GetItemFrames = function() return items end }
UtilityCooldownViewer = { GetItemFrames = function() return {} end }

local function Fire(event)
    for _, f in ipairs(S.frames) do
        if f._events and f._events[event] then f:GetScript("OnEvent")(f, event) end
    end
end
local function Last() return calls[#calls] end
local function Starts()
    local n = 0
    for _, c in ipairs(calls) do if c.op == "start" then n = n + 1 end end
    return n
end

S.targets = 1
wipe(S.cd)

-- Out of combat: nothing. (Combat state comes from the REGEN events; at
-- login it's read from InCombatLockdown.)
InCombatLockdown = function() return false end
Fire("PLAYER_LOGIN")
Check(#calls == 0 and tickFn == nil, "no glow and no ticker out of combat")

-- Combat: the suggestion (Xuen) gets the default Modern WoW Glow.
Fire("PLAYER_REGEN_DISABLED")
Check(tickFn ~= nil, "ticker runs in combat")
local c = Last()
Check(c and c.op == "start" and c.wrapper:GetParent() == xuenItem, "glow starts on the Xuen icon's overlay")
Check(c and c.style == 6 and c.w == 40 and c.h == 40, "default style 6 at the icon's size")
Check(c and c.r == nil and c.opts.untinted, "no custom color: style's own look")
local xuenOverlay = c and c.wrapper
local n = #calls
tickFn()
Check(#calls == n, "same suggestion and icon: nothing restarted")

-- Suggestion moves to a spell without an icon: glow stops.
S.cd[XUEN] = true
tickFn()
Check(Last().op == "stop" and Last().wrapper == xuenOverlay, "glow stops when the suggestion has no icon")
Check(not xuenOverlay._on, "xuen overlay off")

-- An icon for the new suggestion appears: glow moves there.
local zenithItem = Item(ZENITH)
items[#items + 1] = zenithItem
tickFn()
Check(Last().op == "start" and Last().wrapper:GetParent() == zenithItem, "glow follows the suggestion: " .. tostring(ns.EvaluateExpected()))

-- Icon resized by the CDM: restart at the new size.
zenithItem.GetWidth = function() return 52 end
zenithItem.GetHeight = function() return 52 end
tickFn()
Check(Last().op == "start" and Last().w == 52, "resized icon: glow restarted at the new size")

-- Secret IDs never match (and never error).
S.cd[XUEN] = nil
xuenItem.GetSpellID = function() return SECRET end
xuenItem.GetBaseSpellID = function() return SECRET end
tickFn()
Check(Last().op == "stop", "icon with secret IDs is not matched")
xuenItem.GetSpellID = function() return XUEN end
xuenItem.GetBaseSpellID = function() return XUEN end
tickFn()
Check(Last().op == "start" and Last().wrapper == xuenOverlay, "same overlay reused for the same icon")

-- Settings: style change restarts; Blackout passes its opacity.
ns.DB().cdmGlowStyle = 8
ns.ApplyCDMGlow()
Check(Last().op == "start" and Last().style == 8 and Last().opts.alpha == 0.5, "Blackout with default opacity")
ns.DB().cdmGlowColor = { r = 0.2, g = 0.4, b = 0.6 }
ns.ApplyCDMGlow()
Check(Last().r == 0.2 and not Last().opts.untinted, "custom color passed")

-- Disabled: glow stops and the ticker ends.
ns.DB().cdmGlow = false
ns.ApplyCDMGlow()
Check(Last().op == "stop" and tickFn == nil, "disabled: glow off, no ticker")
ns.DB().cdmGlow = nil
ns.ApplyCDMGlow()
Check(Last().op == "start" and tickFn ~= nil, "re-enabled in combat: glow back")

-- Leaving combat stops it.
Fire("PLAYER_REGEN_ENABLED")
Check(Last().op == "stop" and tickFn == nil, "combat end: glow off, no ticker")

-- No glow engine (older or missing EUI): nothing happens, nothing errors.
local saved = EllesmereUI.Glows
EllesmereUI.Glows = nil
local before = #calls
Fire("PLAYER_REGEN_DISABLED")
Check(#calls == before and tickFn == nil, "without EllesmereUI.Glows the driver stays off")
Fire("PLAYER_REGEN_ENABLED")
EllesmereUI.Glows = saved

-- Widgets > CDM Glow page.
local mod
for _, m in ipairs(plugin.modules) do if m.key == "Widgets" then mod = m end end
Check(mod and mod.pages[3] == "CDM Glow", "CDM Glow tab on the Widgets module")
local function Build()
    rows = {}
    return mod.buildPage("CDM Glow", CreateFrame("Frame"), -10)
end
local function Row(text) for _, r in ipairs(rows) do if r.text == text then return r end end end
ns.DB().cdmGlowStyle, ns.DB().cdmGlowColor = nil, nil
Check(Build() > 0, "page builds")
local styleRow = Row("Glow Style")
local offered = {}
for _, v in ipairs(styleRow.order) do offered[#offered + 1] = styleRow.values[v] end
Check(table.concat(offered, ",") == "GCD,Modern WoW Glow,Classic WoW Glow,Blackout", "only restriction-safe styles offered: " .. table.concat(offered, ","))
Check(Row("Blackout Opacity") and Row("Blackout Opacity").disabled() == true, "opacity slider shown but locked unless Blackout")
Row("Enabled").setValue(false)
Check(ns.DB().cdmGlow == false, "Enabled off stored")
Row("Enabled").setValue(true)
Check(ns.DB().cdmGlow == nil, "Enabled on stored as default")
Build()
Check(Row("Glow Color").disabled() == true, "color locked until Custom Color")
Row("Custom Color").setValue(true)
Build()
Check(ns.DB().cdmGlowColor ~= nil and Row("Glow Color").disabled() == false, "custom color unlocks the picker")
Row("Glow Style").setValue(8)
Check(Row("Blackout Opacity").disabled() == false, "Blackout unlocks the slider without a rebuild")
Row("Glow Style").setValue(6)
Check(Row("Blackout Opacity").disabled() == true, "switching away locks it again")

print_real(fails == 0 and "ALL PASS" or (fails .. " failures"))
