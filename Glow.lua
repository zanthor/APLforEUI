local _, ns = ...

-------------------------------------------------------------------------------
--  CDM glow: glows the suggested spell's icon in the Cooldown Manager, on
--  stock EllesmereUI (no custom build). EUI's CDM shows Blizzard's own
--  Essential/Utility viewer item frames, restyled and anchored onto its bars
--  (EllesmereUICdmHooks.lua), so the icon is found through Blizzard's public
--  GetSpellID/GetBaseSpellID, and drawn with EUI's shared glow engine
--  (EllesmereUI.Glows). Following EUI's rules for those frames: never
--  reparent, rescale, hide or show them and never write keys onto them; our
--  glow is our own overlay frame, tracked in a weak table, faded via alpha
--  (StartGlow/StopGlow) rather than shown/hidden.
--  Runs in combat only, on a 0.2s poll, and only while enabled.
-------------------------------------------------------------------------------
local DB = ns.DB

local POLL = 0.2
local VIEWERS = { "EssentialCooldownViewer", "UtilityCooldownViewer" }

-- Styles that keep animating in restricted combat: FlipBook glows and
-- Blackout. The Lua-driven ones (Pixel, Action Button, Auto-Cast, Shape)
-- freeze there (RestrictionSafeStyle in EllesmereUI_Glows.lua).
ns.CDM_GLOW_STYLES = { 5, 6, 7, 8 }
local DEFAULT_STYLE = 6  -- Modern WoW Glow

local overlays = setmetatable({}, { __mode = "k" })
local current = {}  -- item, overlay, spellID, w, h of the glow now shown
local dirty = false
local ticker
local inCombat = false

local function Glows() return EllesmereUI and EllesmereUI.Glows end

function ns.CDMGlowEnabled() return DB().cdmGlow ~= false end

local function Settings()
    local db = DB()
    local style = db.cdmGlowStyle or DEFAULT_STYLE
    local entry = Glows() and Glows().STYLES[style]
    local c = db.cdmGlowColor
    return style, entry, c, db.cdmGlowAlpha or 0.5
end

-- Blizzard frame values are read defensively: nil for errors or secrets.
local function Read(item, method)
    local fn = item[method]
    if not fn then return nil end
    local ok, v = pcall(fn, item)
    if not ok or v == nil or (issecretvalue and issecretvalue(v)) then return nil end
    return v
end

local function Matches(id, spellID, base)
    if type(id) ~= "number" then return false end
    return id == spellID or id == base or ns.ResolveOverride(id) == spellID
end

-- The shown viewer item that displays spellID (or its base / override).
local function FindItem(spellID)
    local base = C_Spell.GetBaseSpell and C_Spell.GetBaseSpell(spellID) or spellID
    for _, name in ipairs(VIEWERS) do
        local viewer = _G[name]
        local items = viewer and viewer.GetItemFrames and viewer:GetItemFrames()
        if items then
            for _, item in ipairs(items) do
                if item:IsShown() and (Matches(Read(item, "GetSpellID"), spellID, base)
                    or Matches(Read(item, "GetBaseSpellID"), spellID, base)) then
                    return item
                end
            end
        end
    end
    return nil
end

local function Overlay(item, solid)
    local ov = overlays[item]
    if not ov then
        ov = CreateFrame("Frame", nil, item)
        ov:SetAllPoints(item)
        ov:EnableMouse(false)
        ov:SetAlpha(0)
        overlays[item] = ov
    end
    -- Blackout stays under the cooldown swipe/text so they stay readable;
    -- other styles go on top (same levels as EUI's own CDM glows).
    ov:SetFrameLevel(item:GetFrameLevel() + (solid and 12 or 17))
    return ov
end

local function Stop()
    local G = Glows()
    if current.overlay and G then G.StopGlow(current.overlay) end
    current.item, current.overlay, current.spellID, current.w, current.h = nil, nil, nil, nil, nil
end

local function Tick()
    local G = Glows()
    if not G then return end
    local spellID = inCombat and ns.CDMGlowEnabled() and ns.EvaluateExpected() or nil
    local item = spellID and FindItem(spellID)
    local w, h = item and item:GetWidth(), item and item:GetHeight()
    if not dirty and item == current.item and spellID == current.spellID
        and w == current.w and h == current.h then
        return
    end
    dirty = false
    Stop()
    if not item then return end
    local style, entry, c, alpha = Settings()
    local solid = entry and entry.solidFill
    local ov = Overlay(item, solid)
    -- A fresh opts table each start: the engine may keep it by reference.
    local opts = { untinted = c == nil, alpha = solid and alpha or nil }
    G.StartGlow(ov, style, w, c and c.r, c and c.g, c and c.b, opts, h)
    current.item, current.overlay, current.spellID, current.w, current.h = item, ov, spellID, w, h
end

local function Sync()
    if inCombat and ns.CDMGlowEnabled() and Glows() then
        if not ticker then ticker = C_Timer.NewTicker(POLL, Tick) end
        Tick()
    else
        if ticker then ticker:Cancel(); ticker = nil end
        Stop()
    end
end

-- Settings changed (Widgets tab): restart the glow with the new look.
function ns.ApplyCDMGlow()
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

-- Status of each link in the chain: engine, enabled, combat, suggestion,
-- icon found, glow shown.
ns.slashCommands.glow = function()
    local expected = ns.EvaluateExpected()
    local item = expected and FindItem(expected)
    local style = Settings()
    print(string.format(
        "APL glow: engine=%s enabled=%s style=%s inCombat=%s ticker=%s suggestion=%s iconFound=%s glowing=%s",
        tostring(Glows() ~= nil), tostring(ns.CDMGlowEnabled()), tostring(style), tostring(inCombat),
        tostring(ticker ~= nil), expected and (ns.SpellName(expected) .. " (" .. expected .. ")") or "none",
        tostring(item ~= nil), current.spellID and ns.SpellName(current.spellID) or "nothing"))
end
