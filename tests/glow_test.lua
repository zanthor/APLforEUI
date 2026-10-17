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
local cbDD
function EllesmereUI.BuildVisOptsCBDropdown(parent, w, level, items, get, set, _, _, _, _, _, opts)
    cbDD = { items = items, get = get, set = set, opts = opts }
    return CreateFrame("Frame", nil, parent), function() end
end
local cogs = {}
function EllesmereUI.BuildInlineCog(_, opts) cogs[#cogs + 1] = opts end
function EllesmereUI.Widgets:SectionHeader() return CreateFrame("Frame"), 30 end
function EllesmereUI.Widgets:DualRow(_, _, l, r)
    for _, cfg in ipairs({ l or false, r or false }) do if cfg then rows[#rows + 1] = cfg end end
    return CreateFrame("Frame"), 50
end

local S, ns = dofile(dir .. "/tests/mock_wow.lua")(dir)
-- These checks cover plain glows; the built-in Windwalker's Xuen holds
-- (hold fork) are tested in their own section further down. Its Opener
-- group is dropped so Xuen leads from the first cast.
table.remove(ns.Engine.BuiltinForSpec(269).groups, 1)
for _, l in ipairs(ns.Engine.BuiltinForSpec(269).groups[1].lists) do
    for _, e in ipairs(l.entries) do e.hold = nil end
end
ns.Engine.Invalidate(ns.Engine.BuiltinForSpec(269))

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
ns.ApplyGlows()
Check(Last().op == "start" and Last().style == 8 and Last().opts.alpha == 0.5, "Blackout with default opacity")
ns.DB().cdmGlowColor = { r = 0.2, g = 0.4, b = 0.6 }
ns.ApplyGlows()
Check(Last().r == 0.2 and not Last().opts.untinted, "custom color passed")

-- Disabled: glow stops and the ticker ends.
ns.DB().cdmGlow = false
ns.ApplyGlows()
Check(Last().op == "stop" and tickFn == nil, "disabled: glow off, no ticker")
ns.DB().cdmGlow = nil
ns.ApplyGlows()
Check(Last().op == "start" and tickFn ~= nil, "re-enabled in combat: glow back")

-- Leaving combat stops it.
Fire("PLAYER_REGEN_ENABLED")
Check(Last().op == "stop" and tickFn == nil, "combat end: glow off, no ticker")

-- Show: Always glows out of combat too; back to Combat Only stops it.
ns.SetGlowShow("cdmGlow", "always")
Check(ns.DB().cdmGlowShow == "always" and Last().op == "start" and tickFn ~= nil, "always: glows out of combat")
ns.SetGlowShow("cdmGlow", "combat")
Check(ns.DB().cdmGlowShow == nil and Last().op == "stop" and tickFn == nil, "combat only (default, stored as nil): off out of combat")

-- No glow engine (older or missing EUI): nothing happens, nothing errors.
local saved = EllesmereUI.Glows
EllesmereUI.Glows = nil
local before = #calls
Fire("PLAYER_REGEN_DISABLED")
Check(#calls == before and tickFn == nil, "without EllesmereUI.Glows the driver stays off")
Fire("PLAYER_REGEN_ENABLED")
EllesmereUI.Glows = saved

-- Action bar glow: off by default; buttons found by slot and by macro.
local BAR = {}
local function Button(slot)
    local b = CreateFrame("Button")
    b.GetAttribute = function(_, k) if k == "action" then return slot end end
    b.IsVisible = function() return true end
    b.GetWidth = function() return 36 end
    b.GetHeight = function() return 36 end
    return b
end
EABButton1 = Button(1)                  -- Bar 1: Xuen
EABButton3 = Button(3)                  -- Bar 1: Tiger Palm
EABButton62 = Button(62)                -- Bar 2: a macro casting Xuen
EABButton63 = Button(63)                -- Bar 2: an item macro (#showtooltip item:...)
MultiBarBottomLeftButton1 = Button(61)  -- Bar 2 (Blizzard): Xuen
ActionButton12 = Button(12)             -- Bar 1: the assisted-combat button
C_ActionBar = {
    FindSpellActionButtons = function(id)
        if id == XUEN then return { 1, 61, 12 } end
        if id == TP then return { 3 } end
        return {}
    end,
    IsAssistedCombatAction = function(slot) return slot == 12 end,
}
GetActionInfo = function(slot)
    if slot == 62 then return "macro", XUEN, "spell" end
    if slot == 63 then return "macro", 241289, "item" end
    return "spell", 0
end
-- Would match anything if an item macro's ID were wrongly used as an index.
GetMacroSpell = function() return XUEN end
local function GlowingOn()
    local parents = {}
    for _, c in ipairs(calls) do
        local p = c.wrapper:GetParent()
        if c.op == "start" then parents[p] = true elseif c.op == "stop" then parents[p] = nil end
    end
    return parents
end
ns.DB().cdmGlowStyle, ns.DB().cdmGlowColor = nil, nil
wipe(S.cd)
Fire("PLAYER_REGEN_DISABLED")
local on = GlowingOn()
Check(on[xuenItem] and not on[EABButton1], "action bar glow off by default (CDM still on)")
ns.SetGlowEnabled("barGlow", true)
Check(ns.DB().barGlow == true, "bar glow on stored")
on = GlowingOn()
Check(on[EABButton1] and on[MultiBarBottomLeftButton1], "Xuen glows on EUI and Blizzard bar buttons")
Check(on[EABButton62], "macro casting Xuen glows")
Check(not on[EABButton63], "item macro never glows")
Check(not on[ActionButton12], "assisted-combat button never glows")
Check(not on[EABButton3], "other spells' buttons don't glow")
Check(on[xuenItem], "CDM icon still glows alongside")
-- Separate style per target.
ns.DB().barGlowStyle = 7
ns.ApplyGlows()
local barStyle, cdmStyle
for _, c in ipairs(calls) do
    if c.op == "start" and c.wrapper:GetParent() == EABButton1 then barStyle = c.style end
    if c.op == "start" and c.wrapper:GetParent() == xuenItem then cdmStyle = c.style end
end
Check(barStyle == 7 and cdmStyle == 6, "bar and CDM glows keep their own style: " .. tostring(barStyle) .. "/" .. tostring(cdmStyle))
-- Per-bar filter: Bar 1 off leaves the Bar 2 buttons glowing.
ns.SetGlowBarEnabled(1, false)
on = GlowingOn()
Check(not on[EABButton1] and on[MultiBarBottomLeftButton1] and on[EABButton62], "Bar 1 off: only Bar 2 glows")
Check(ns.DB().barGlowBars[1] == false, "bar off stored")
ns.SetGlowBarEnabled(1, true)
Check(ns.DB().barGlowBars == nil, "all bars on stored as default")
on = GlowingOn()
Check(on[EABButton1], "Bar 1 back")

-- CDM off, bars on: only bars glow.
ns.SetGlowEnabled("cdmGlow", false)
on = GlowingOn()
Check(on[EABButton1] and not on[xuenItem], "CDM off, bars on")
Check(ns.DB().cdmGlow == false, "CDM off stored")
ns.SetGlowEnabled("cdmGlow", true)
Check(ns.DB().cdmGlow == nil, "CDM back on stored as default")
ns.SetGlowEnabled("barGlow", false)
Check(ns.DB().barGlow == nil, "bar off stored as default")
on = GlowingOn()
Check(not on[EABButton1], "bar glow off again")
Fire("PLAYER_REGEN_ENABLED")

-- Hold fork: the hold spell glows in Hold Color, the alternative normally.
local wwDef = ns.Engine.BuiltinForSpec(269)
wwDef.groups[1].lists[1].entries[1].hold = 3   -- O1 Invoke Xuen
ns.Engine.Invalidate(wwDef)
ns.DB().cdmGlowStyle, ns.DB().cdmGlowColor, ns.DB().cdmGlowHoldColor = nil, nil, nil
wipe(S.cd)
local fid, _, _, fentry, falt = ns.EvaluateExpected()
Check(fid == XUEN and fentry.hold == 3 and falt ~= nil, "fork on the built-in: Xuen with an alternative")
-- The alternative (Zenith here) already has an icon from earlier.
local firstNew = #calls + 1
Fire("PLAYER_REGEN_DISABLED")
local xuenStart, altStart
for i = firstNew, #calls do
    local c = calls[i]
    local p = c.wrapper:GetParent()
    if c.op == "start" and p == xuenItem then xuenStart = c end
    if c.op == "start" and p.GetSpellID and p:GetSpellID() == falt then altStart = c end
end
Check(xuenStart and xuenStart.r == 0.25 and not xuenStart.opts.untinted, "hold spell in Hold Color (default)")
Check(altStart and altStart.r == nil and altStart.opts.untinted, "alternative in the normal glow")
-- Xuen held: without Persistent Hold its glow goes; with it, it stays in
-- Hold Color for as long as it's held.
local function XuenGlow()
    local last
    for _, c in ipairs(calls) do
        if c.wrapper:GetParent() == xuenItem then last = c end
    end
    return last and last.op == "start" and last or nil
end
local wwRT = ns.GetActiveAPL()
wwRT.holds[XUEN] = { count = 2, held = true }
tickFn()
Check(XuenGlow() == nil, "held, Persistent Hold off: no glow on Xuen")
ns.SetGlowPersistentHold("cdmGlow", true)
Check(ns.DB().cdmGlowPersistentHold == true, "Persistent Hold stored")
local pg = XuenGlow()
Check(pg and pg.r == 0.25 and not pg.opts.untinted, "held, Persistent Hold on: Xuen glows in Hold Color")
wwRT.holds[XUEN] = nil
tickFn()
Check(XuenGlow() and XuenGlow().r == 0.25, "hold over (cast): back to the fork's hold glow")
ns.SetGlowPersistentHold("cdmGlow", false)
Check(ns.DB().cdmGlowPersistentHold == nil, "Persistent Hold off stored as default")
Fire("PLAYER_REGEN_ENABLED")
wwDef.groups[1].lists[1].entries[1].hold = nil
ns.Engine.Invalidate(wwDef)

-- Glows page: its own module between APL and Widgets, one section per target.
local mod
for _, m in ipairs(plugin.modules) do if m.key == "Glows" then mod = m end end
Check(mod and mod.pages[1] == "Glows", "Glows module")
for _, m in ipairs(plugin.modules) do
    if m.key == "Widgets" then
        for _, pg in ipairs(m.pages) do Check(pg ~= "CDM Glow", "CDM Glow tab gone from Widgets") end
    end
end
local function Build()
    rows = {}
    return mod.buildPage("Glows", CreateFrame("Frame"), -10)
end
-- Rows of the first (CDM) section come first; the second section's follow.
local function Row(text, nth)
    nth = nth or 1
    for _, r in ipairs(rows) do
        if r.text == text then
            nth = nth - 1
            if nth == 0 then return r end
        end
    end
end
Check(Build() > 0, "page builds")
Check(Row("Enabled", 1).getValue() == true and Row("Enabled", 2).getValue() == false,
    "CDM on, action bars off by default")
Row("Enabled", 2).setValue(true)
Check(ns.GlowEnabled("barGlow"), "action bars switch on from the page")
Check(Row("Glow On Bars") ~= nil and cbDD and #cbDD.items == 10 and cbDD.items[10].label == "Bar 10", "bar picker lists Bar 1-10")
Check(cbDD.get(3) == true and cbDD.opts.disabled() == false, "bars on by default; picker unlocked while enabled")
cbDD.set(3, false)
Check(ns.GlowBarEnabled(3) == false and cbDD.get(3) == false, "unchecking a bar switches it off")
cbDD.set(3, true)
Row("Enabled", 2).setValue(false)
Check(cbDD.opts.disabled() == true, "picker locked while the action bar glow is off")
local styleRow = Row("Glow Style")
local offered = {}
for _, v in ipairs(styleRow.order) do offered[#offered + 1] = styleRow.values[v] end
Check(table.concat(offered, ",") == "GCD,Modern WoW Glow,Classic WoW Glow,Blackout", "only restriction-safe styles offered: " .. table.concat(offered, ","))
Check(Row("Blackout Opacity") and Row("Blackout Opacity").disabled() == true, "opacity slider shown but locked unless Blackout")
-- Per section: the Show cog (Enabled row), then the Hold Glow cog (color row).
Check(#cogs == 4 and cogs[1].title == "Glow Settings" and cogs[1].rows[1].label == "Show"
    and cogs[3].title == "Glow Settings", "a Glow Settings cog per section")
Check(cogs[1].rows[1].get() == "combat" and cogs[1].rows[1].order[1] == "always", "Show: Always / Combat Only, combat by default")
cogs[3].rows[1].set("always")
Check(ns.GlowShow("barGlow") == "always" and ns.GlowShow("cdmGlow") == "combat", "each section has its own Show")
cogs[3].rows[1].set("combat")
Check(cogs[2].title == "Hold Glow Settings" and cogs[2].rows[1].label == "Persistent Hold"
    and cogs[4].title == "Hold Glow Settings", "a Hold Glow Settings cog on each color row")
Check(cogs[2].rows[1].get() == false, "Persistent Hold off by default")
cogs[2].rows[1].set(true)
Check(ns.GlowPersistentHold("cdmGlow") and not ns.GlowPersistentHold("barGlow"), "Persistent Hold per section")
cogs[2].rows[1].set(false)
Check(cogs[3].disabled() == true and cogs[4].disabled() == true and cogs[1].disabled() == false, "cogs locked while their glow is off")
Row("Enabled").setValue(false)
Check(ns.DB().cdmGlow == false, "Enabled off stored")
Row("Enabled").setValue(true)
Check(ns.DB().cdmGlow == nil, "Enabled on stored as default")
Build()
local colors = Row("Glow Color")
Check(colors.type == "multiSwatch" and colors.swatches[1].tooltip == "Glow Color" and colors.swatches[2].tooltip == "Hold Color",
    "Glow Color and Hold Color swatches")
Check(colors.swatches[1].disabled() == true and colors.swatches[2].disabled == nil, "glow color locked until Custom Color; hold color always usable")
local hr, hg, hb = colors.swatches[2].getValue()
Check(hr == 0.25 and hg == 0.6 and hb == 1, "hold color default")
colors.swatches[2].setValue(0.9, 0.1, 0.9)
Check(ns.DB().cdmGlowHoldColor.r == 0.9, "hold color stored")
Row("Custom Color").setValue(true)
Build()
Check(ns.DB().cdmGlowColor ~= nil and Row("Glow Color").swatches[1].disabled() == false, "custom color unlocks the glow color")
Row("Glow Style").setValue(8)
Check(Row("Blackout Opacity").disabled() == false, "Blackout unlocks the slider without a rebuild")
Row("Glow Style").setValue(6)
Check(Row("Blackout Opacity").disabled() == true, "switching away locks it again")

print_real(fails == 0 and "ALL PASS" or (fails .. " failures"))
