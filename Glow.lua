local _, ns = ...

-------------------------------------------------------------------------------
--  Glows: the suggested spell glows on the Cooldown Manager icon and/or its
--  action bar buttons, on stock EllesmereUI (no custom build), drawn with
--  EUI's shared glow engine (EllesmereUI.Glows) on our own overlay frames.
--
--  Cooldown Manager: EUI's CDM shows Blizzard's own Essential/Utility viewer
--  item frames, restyled and anchored onto its bars (EllesmereUICdmHooks.lua),
--  found through Blizzard's public GetSpellID/GetBaseSpellID.
--  Action bars: C_ActionBar.FindSpellActionButtons gives the slots holding a
--  spell; each slot's button is EUI's EABButton<slot> or a Blizzard bar
--  button (same lookup as EUI's Bar Glows, EllesmereUICdmBarGlows.lua);
--  macros match through their current spell. Action buttons are secure: the
--  overlay is a plain child frame, and the button itself is never touched.
--
--  Following EUI's rules for Blizzard frames: never reparent, rescale, hide or
--  show them and never write keys onto them; overlays live in a weak table and
--  are faded via alpha (StartGlow/StopGlow) rather than shown/hidden.
--  Runs in combat only, on a 0.2s poll, and only while a glow is enabled.
-------------------------------------------------------------------------------
local DB = ns.DB

local POLL = 0.2

-- Styles that keep animating in restricted combat: FlipBook glows and
-- Blackout. The Lua-driven ones (Pixel, Action Button, Auto-Cast, Shape)
-- freeze there (RestrictionSafeStyle in EllesmereUI_Glows.lua).
ns.GLOW_STYLES_SAFE = { 5, 6, 7, 8 }
local DEFAULT_STYLE = 6  -- Modern WoW Glow

local function Glows() return EllesmereUI and EllesmereUI.Glows end

-- Blizzard frame values are read defensively: nil for errors or secrets.
local function Read(obj, method, ...)
    local fn = obj and obj[method]
    if not fn then return nil end
    local ok, v = pcall(fn, obj, ...)
    if not ok or v == nil or (issecretvalue and issecretvalue(v)) then return nil end
    return v
end

local function Call(fn, ...)
    if not fn then return nil end
    local ok, a, b, c = pcall(fn, ...)
    if not ok then return nil end
    if issecretvalue and (issecretvalue(a) or issecretvalue(b) or issecretvalue(c)) then return nil end
    return a, b, c
end

local function Matches(id, spellID, base)
    if type(id) ~= "number" then return false end
    return id == spellID or id == base or ns.ResolveOverride(id) == spellID
end

local function BaseOf(spellID)
    return (C_Spell.GetBaseSpell and C_Spell.GetBaseSpell(spellID)) or spellID
end

-------------------------------------------------------------------------------
--  Targets
-------------------------------------------------------------------------------

-- Cooldown Manager: the shown viewer item for the spell (one icon).
local CDM_VIEWERS = { "EssentialCooldownViewer", "UtilityCooldownViewer" }
local function FindCDM(spellID, out)
    local base = BaseOf(spellID)
    for _, name in ipairs(CDM_VIEWERS) do
        local viewer = _G[name]
        local items = viewer and viewer.GetItemFrames and viewer:GetItemFrames()
        for _, item in ipairs(items or {}) do
            if item:IsShown() and (Matches(Read(item, "GetSpellID"), spellID, base)
                or Matches(Read(item, "GetBaseSpellID"), spellID, base)) then
                out[#out + 1] = item
                return
            end
        end
    end
end

-- Action bars: every visible button holding the spell (or a macro casting it)
-- on an enabled bar. A button belongs to a bar by its name, never its current
-- slot (Bar 1 pages with forms/stances): EUI names each EABButton<slot> by its
-- home slot (BAR_SLOT_OFFSETS in EllesmereUIActionBars.lua); without EUI the
-- Blizzard bar buttons are used. Bars 9-10 exist only in EUI.
ns.GLOW_BARS = {
    { n = 1, offset = 0, blizz = "ActionButton" },
    { n = 2, offset = 60, blizz = "MultiBarBottomLeftButton" },
    { n = 3, offset = 48, blizz = "MultiBarBottomRightButton" },
    { n = 4, offset = 24, blizz = "MultiBarRightButton" },
    { n = 5, offset = 36, blizz = "MultiBarLeftButton" },
    { n = 6, offset = 144, blizz = "MultiBar5Button" },
    { n = 7, offset = 156, blizz = "MultiBar6Button" },
    { n = 8, offset = 168, blizz = "MultiBar7Button" },
    { n = 9, offset = 12 },
    { n = 10, offset = 108 },
}

-- Every bar glows unless switched off (stored as barGlowBars[n] = false).
function ns.GlowBarEnabled(n)
    local t = DB().barGlowBars
    return not (t and t[n] == false)
end

function ns.SetGlowBarEnabled(n, on)
    local db = DB()
    db.barGlowBars = db.barGlowBars or {}
    if on then db.barGlowBars[n] = nil else db.barGlowBars[n] = false end
    if not next(db.barGlowBars) then db.barGlowBars = nil end
    ns.ApplyGlows()
end

local slotSet = {}

local function ButtonSlot(btn)
    return Read(btn, "GetAttribute", "action") or (type(btn.action) == "number" and btn.action) or nil
end

-- A macro slot reports its current spell (subType "spell") or item
-- (subType "item") directly; otherwise look the macro up by name and skip
-- item macros. Mirrors SlotSpellID in EUI_CDM_HookPressMirror.lua.
local function MacroSpell(slot)
    local actionType, id, subType = Call(GetActionInfo, slot)
    if actionType ~= "macro" then return nil end
    if subType == "spell" then return id end
    if subType == "item" then return nil end
    local name = Call(GetActionText, slot)
    local index = name and GetMacroIndexByName and Call(GetMacroIndexByName, name)
    if not index or index <= 0 then return nil end
    if GetMacroItem and Call(GetMacroItem, index) then return nil end
    return GetMacroSpell and Call(GetMacroSpell, index) or nil
end

local function SlotCasts(slot, spellID, base)
    if slotSet[slot] then return true end
    return Matches(MacroSpell(slot), spellID, base)
end

local function ConsiderButton(btn, spellID, base, out, seen)
    if not btn or seen[btn] or not btn:IsVisible() then return end
    local slot = ButtonSlot(btn)
    if not slot then return end
    -- Blizzard's assisted-combat button shows whatever it suggests, not a spell.
    if C_ActionBar and C_ActionBar.IsAssistedCombatAction and Call(C_ActionBar.IsAssistedCombatAction, slot) then return end
    if SlotCasts(slot, spellID, base) then
        seen[btn] = true
        out[#out + 1] = btn
    end
end

local seenButtons = {}
local function FindBars(spellID, out)
    wipe(slotSet)
    wipe(seenButtons)
    local base = BaseOf(spellID)
    local find = C_ActionBar and C_ActionBar.FindSpellActionButtons
    for _, id in ipairs({ base, spellID }) do
        for _, slot in ipairs(Call(find, id) or {}) do slotSet[slot] = true end
    end
    for _, bar in ipairs(ns.GLOW_BARS) do
        if ns.GlowBarEnabled(bar.n) then
            for i = 1, 12 do
                ConsiderButton(_G["EABButton" .. (bar.offset + i)], spellID, base, out, seenButtons)
                if bar.blizz then ConsiderButton(_G[bar.blizz .. i], spellID, base, out, seenButtons) end
            end
        end
    end
end

-- key: DB prefix; on: enabled when the DB flag is nil (default) or not.
local TARGETS = {
    { key = "cdmGlow", defaultOn = true, find = FindCDM, label = "Cooldown Manager" },
    { key = "barGlow", defaultOn = false, find = FindBars, label = "Action Bars" },
}

function ns.GlowEnabled(key)
    local v = DB()[key]
    for _, t in ipairs(TARGETS) do
        if t.key == key then
            if t.defaultOn then return v ~= false end
            return v == true
        end
    end
    return false
end

function ns.SetGlowEnabled(key, on)
    for _, t in ipairs(TARGETS) do
        if t.key == key then
            -- Store only what differs from the default.
            if on == t.defaultOn then DB()[key] = nil
            elseif on then DB()[key] = true
            else DB()[key] = false end
        end
    end
    ns.ApplyGlows()
end

-- When a target glows: "combat" (default, stored as nil) or "always".
function ns.GlowShow(key)
    return DB()[key .. "Show"] or "combat"
end

function ns.SetGlowShow(key, v)
    if v == "combat" then DB()[key .. "Show"] = nil else DB()[key .. "Show"] = v end
    ns.ApplyGlows()
end

-- Persistent Hold: a held spell keeps glowing in Hold Color for as long as
-- it's held, not just while the hold fork shows it. Off by default.
function ns.GlowPersistentHold(key)
    return DB()[key .. "PersistentHold"] == true
end

function ns.SetGlowPersistentHold(key, on)
    if on then DB()[key .. "PersistentHold"] = true else DB()[key .. "PersistentHold"] = nil end
    ns.ApplyGlows()
end

local function Settings(key)
    local db = DB()
    local style = db[key .. "Style"] or DEFAULT_STYLE
    local entry = Glows() and Glows().STYLES[style]
    return style, entry, db[key .. "Color"], db[key .. "Alpha"] or 0.5
end
ns.GlowSettings = Settings

-- Hold Color: the hold fork's hold spell. Always used for it, whether or not
-- Custom Color is on for the normal glow.
ns.HOLD_COLOR_DEFAULT = { r = 0.25, g = 0.6, b = 1 }
function ns.GlowHoldColor(key)
    return DB()[key .. "HoldColor"] or ns.HOLD_COLOR_DEFAULT
end

-------------------------------------------------------------------------------
--  Driver
-------------------------------------------------------------------------------
local overlays = setmetatable({}, { __mode = "k" })   -- [frame] = our overlay
local shown = {}       -- [target key] = { [frame] = { ov, w, h } }
local found = {}       -- scratch list per target
local dirty = false
local ticker
local inCombat = false
local want = {}         -- scratch: [frame] = "hold" | "normal" wanted this tick
local held = {}         -- scratch: held spellIDs this tick (Persistent Hold)

for _, t in ipairs(TARGETS) do shown[t.key] = {} end

local function Overlay(frame, solid, levelSolid, levelTop)
    local ov = overlays[frame]
    if not ov then
        ov = CreateFrame("Frame", nil, frame)
        ov:SetAllPoints(frame)
        ov:EnableMouse(false)
        ov:SetAlpha(0)
        overlays[frame] = ov
    end
    ov:SetFrameLevel(frame:GetFrameLevel() + (solid and levelSolid or levelTop))
    return ov
end

local function StopAll(key)
    local G = Glows()
    for frame, st in pairs(shown[key]) do
        if G then G.StopGlow(st.ov) end
        shown[key][frame] = nil
    end
end

local function Start(target, frame, w, h, kind)
    local G = Glows()
    local style, entry, c, alpha = Settings(target.key)
    if kind == "hold" then c = ns.GlowHoldColor(target.key) end
    local solid = entry and entry.solidFill
    -- CDM: Blackout under the swipe/text, others on top (EUI's own CDM glow
    -- levels). Action buttons: just above the button's own art.
    local ov = target.key == "cdmGlow" and Overlay(frame, solid, 12, 17) or Overlay(frame, solid, 1, 5)
    -- A fresh opts table each start: the engine may keep it by reference.
    local opts = { untinted = c == nil, alpha = solid and alpha or nil }
    G.StartGlow(ov, style, w, c and c.r, c and c.g, c and c.b, opts, h)
    return ov
end

-- spellID glows normally, or in Hold Color when it's a hold line (isHold);
-- alt (the hold fork's next valid action) glows normally beside it. With
-- Persistent Hold, every held spell glows in Hold Color too.
local function TickTarget(target, spellID, isHold, alt, persist)
    local set = shown[target.key]
    wipe(found)
    wipe(want)
    if ns.GlowEnabled(target.key) then
        if spellID then
            target.find(spellID, found)
            for i = 1, #found do want[found[i]] = isHold and "hold" or "normal" end
        end
        if alt then
            local n = #found
            target.find(alt, found)
            for i = n + 1, #found do want[found[i]] = want[found[i]] or "normal" end
        end
        if persist and ns.GlowPersistentHold(target.key) then
            for _, id in ipairs(held) do
                local n = #found
                target.find(id, found)
                for i = n + 1, #found do want[found[i]] = want[found[i]] or "hold" end
            end
        end
    end
    local G = Glows()
    -- Stop frames no longer wanted, or wanted in the other color.
    for frame, st in pairs(set) do
        if dirty or want[frame] ~= st.kind then
            G.StopGlow(st.ov)
            set[frame] = nil
        end
    end
    -- Start new ones, or restart on a size change.
    for frame, kind in pairs(want) do
        local w, h = frame:GetWidth(), frame:GetHeight()
        local st = set[frame]
        if not st or st.w ~= w or st.h ~= h then
            if st then G.StopGlow(st.ov) end
            set[frame] = { ov = Start(target, frame, w, h, kind), w = w, h = h, kind = kind }
        end
    end
end

-- Glowing now: enabled, and in combat unless set to show always.
local function Active(t)
    return ns.GlowEnabled(t.key) and (inCombat or ns.GlowShow(t.key) == "always")
end

local function AnyActive()
    for _, t in ipairs(TARGETS) do if Active(t) then return true end end
    return false
end

local function Tick()
    if not Glows() then return end
    local spellID, entry, alt
    wipe(held)
    if AnyActive() then
        spellID, _, _, entry, alt = ns.EvaluateExpected()
        local rt = ns.GetActiveAPL()
        if rt then ns.Engine.HeldSpells(rt, held) end
    end
    local isHold = entry ~= nil and entry.hold ~= nil
    for _, t in ipairs(TARGETS) do
        if Active(t) then TickTarget(t, spellID, isHold, alt, true) else TickTarget(t, nil) end
    end
    dirty = false
end

local function Sync()
    if AnyActive() and Glows() then
        if not ticker then ticker = C_Timer.NewTicker(POLL, Tick) end
        Tick()
    else
        if ticker then ticker:Cancel(); ticker = nil end
        for _, t in ipairs(TARGETS) do StopAll(t.key) end
    end
end

-- Settings changed (Glows page): restart every glow with the new look.
function ns.ApplyGlows()
    dirty = true
    Sync()
end

-- Combat state comes from the event itself: InCombatLockdown() is not
-- reliable at the exact moment PLAYER_REGEN_DISABLED fires.
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then inCombat = true
    elseif event == "PLAYER_REGEN_ENABLED" then inCombat = false
    else inCombat = InCombatLockdown() and true or false end
    Sync()
end)

-- Status of each link in the chain, per target.
ns.slashCommands.glow = function()
    local expected = ns.EvaluateExpected()
    print(string.format("APL glow: engine=%s inCombat=%s ticker=%s suggestion=%s",
        tostring(Glows() ~= nil), tostring(inCombat), tostring(ticker ~= nil),
        expected and (ns.SpellName(expected) .. " (" .. expected .. ")") or "none"))
    for _, t in ipairs(TARGETS) do
        local list = {}
        if expected then t.find(expected, list) end
        local n = 0
        for _ in pairs(shown[t.key]) do n = n + 1 end
        print(string.format("  %s: enabled=%s show=%s style=%s framesFound=%d glowing=%d",
            t.label, tostring(ns.GlowEnabled(t.key)), ns.GlowShow(t.key), tostring((Settings(t.key))), #list, n))
    end
end
