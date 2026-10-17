local _, ns = ...

-------------------------------------------------------------------------------
--  Shared helpers. Nothing here or elsewhere checks for a class/spec
--  directly: everything asks for the active APL (Engine.lua).
-------------------------------------------------------------------------------

APLforEUIDB = APLforEUIDB or {}
function ns.DB()
    return APLforEUIDB
end

-- Squashed for now (more debug coming later) -- stats/TTS/broker keep running
-- regardless, this only silences the chat print lines. /apl chat toggles it.
ns.chatOutput = false

-- Resolved spell ID of the last successful cast, set by Tracking after every
-- report.
ns.lastCastSpellID = nil

-- Lightweight "what are we channeling right now" state, decoupled from the
-- cast-report dedup machinery -- just an on/off flag per active channel.
ns.currentChannelSpellID = nil
function ns.IsChanneling(spellID) return ns.currentChannelSpellID == spellID end

-- Auto-attacks fire a "cast" event every swing/shot (Auto Shot every few
-- seconds for Hunters). They are not player decisions: never tracked as
-- casts, counted in stats/combat.casts, or used as a buff's cause.
ns.AUTO_ATTACKS = { [75] = true, [6603] = true }  -- Auto Shot, Auto Attack

-- /apl <cmd> handlers, registered by whichever file owns the state they read.
ns.slashCommands = {}

function ns.GetSpecID()
    local spec = GetSpecialization and GetSpecialization()
    return spec and GetSpecializationInfo(spec) or nil
end

-- True when the current spec has an APL to run (Engine.lua).
function ns.IsSpecSupported()
    return ns.GetActiveAPL() ~= nil
end

-------------------------------------------------------------------------------
--  Spell helpers
-------------------------------------------------------------------------------

-- Resolve a base spell to its currently active override (e.g. Rising Sun Kick
-- -> Rushing Wind Kick when the replacing talent is active).
function ns.ResolveOverride(spellID)
    if C_Spell and C_Spell.GetOverrideSpell then
        local ov = C_Spell.GetOverrideSpell(spellID)
        if ov and ov ~= 0 and ov ~= spellID then return ov end
    end
    return spellID
end

local _spellNameCache = {}
function ns.SpellName(spellID)
    local name = _spellNameCache[spellID]
    if name then return name end
    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
    name = (info and info.name) or ("Spell " .. spellID)
    _spellNameCache[spellID] = name
    return name
end

-- A resolvable spell has real info behind it; an echo/tick id that slips past
-- the known-spell filter still won't resolve, matching EUI's own skip.
function ns.SpellResolvable(spellID)
    return (C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)) ~= nil
end

-- startTime/duration on the cooldown table go secret during real M+/raid
-- combat and cannot be compared at all; isActive/isOnGCD (and GetSpellCharges's
-- isActive) stay clean bools even then, per EUI's own CDM (CdReadyIsReady in
-- EUI_CDM_HookIconWatch.lua) -- mirror that instead of touching the numbers.
function ns.IsOffCooldown(spellID)
    local ci = C_Spell and C_Spell.GetSpellCharges and C_Spell.GetSpellCharges(spellID)
    if ci and (ci.maxCharges or 0) > 1 then
        return not ci.isActive
    end
    local cd = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(spellID)
    if not cd then return true end
    return not (cd.isActive and not cd.isOnGCD)
end

function ns.IsTalented(spellID)
    if C_SpellBook and C_SpellBook.IsSpellKnown then return C_SpellBook.IsSpellKnown(spellID) == true end
    return IsPlayerSpell(spellID) == true
end

-- No direct "enemies in range" API exists, so this infers it the same way
-- EUI's own EllesmereUI_Range.lua does for single-target range: per-nameplate
-- IsSpellInRange against a range spell (default: the active APL's),
-- counted up. Only enemies in combat count (UnitAffectingCombat, not
-- secret), so idle mobs and unattacked dummies in range don't turn single
-- target into AOE -- which matters most for ranged range spells. Plain
-- booleans the whole way, never secret.
-- /apl targets N: a fixed target count for testing (training dummies drop
-- out of combat between hits, so nameplate counting undercounts them).
-- Session only: a reload goes back to counting nameplates.
ns.targetOverride = nil

function ns.GetTargetCount(rangeSpellID)
    if ns.targetOverride then return ns.targetOverride end
    local count = 0
    if not rangeSpellID then
        local apl = ns.GetActiveAPL()
        rangeSpellID = apl and apl.rangeSpellID
    end
    if not rangeSpellID then return count end
    local plates = C_NamePlate and C_NamePlate.GetNamePlates and C_NamePlate.GetNamePlates(issecure())
    if not plates then return count end
    for _, plate in ipairs(plates) do
        local unit = plate.namePlateUnitToken or plate.unitToken
        if unit and UnitCanAttack("player", unit) and not UnitIsDead(unit) and UnitAffectingCombat(unit) then
            local inRange = C_Spell and C_Spell.IsSpellInRange and C_Spell.IsSpellInRange(rangeSpellID, unit)
            if inRange then count = count + 1 end
        end
    end
    return count
end

-------------------------------------------------------------------------------
--  Aura helpers
-------------------------------------------------------------------------------

-- Blizzard's own Cooldown Viewer (Blizzard_CooldownViewer) item frames expose
-- a derived "is this aura present" signal (auraInstanceID) as a plain field,
-- stamped on by Blizzard's own privileged code -- never the raw secret aura
-- itself. This is the exact mechanism EUI's own Cooldown Manager relies on
-- for buff-bar glows, used here for any buff whose aura data goes dark to
-- regular addon code in real combat.
-- A buff can be on an icon under its own ID or as one of the icon's linked
-- spells (Beast Cleave's buff 268877 shows on the 115939 entry). Linked
-- IDs come from the item's static cooldown info (CooldownViewerItemData.lua
-- GetCooldownInfo); with several linked buffs the icon only says "one of
-- them is up".
local function ItemShowsSpell(item, spellID)
    if item.GetBaseSpellID and item:GetBaseSpellID() == spellID then return true end
    local info = item.GetCooldownInfo and item:GetCooldownInfo()
    if not info then return false end
    if info.overrideSpellID == spellID then return true end
    for _, linked in ipairs(info.linkedSpellIDs or {}) do
        if linked == spellID then return true end
    end
    return false
end

function ns.FindCooldownViewerItemForSpell(spellID)
    for _, viewerName in ipairs({ "BuffIconCooldownViewer", "BuffBarCooldownViewer" }) do
        local viewer = _G[viewerName]
        if viewer and viewer.GetItemFrames then
            for _, item in ipairs(viewer:GetItemFrames()) do
                if ItemShowsSpell(item, spellID) then return item end
            end
        end
    end
    return nil
end

-- True if any icon showing spellID (own or linked) has its aura up; a buff
-- can match more than one icon.
function ns.IsCooldownViewerAuraActive(spellID)
    for _, viewerName in ipairs({ "BuffIconCooldownViewer", "BuffBarCooldownViewer" }) do
        local viewer = _G[viewerName]
        if viewer and viewer.GetItemFrames then
            for _, item in ipairs(viewer:GetItemFrames()) do
                if ItemShowsSpell(item, spellID) and item:IsShown() and item.GetAuraSpellInstanceID
                    and item:GetAuraSpellInstanceID() ~= nil then
                    return true
                end
            end
        end
    end
    return false
end

-- Tries the Cooldown Viewer signal first (reliable in real combat, but only
-- covers spells in the spec's tracked-buff set); falls back to the direct
-- aura read (fine outside restricted combat, or for untracked buffs).
function ns.HasBuff(spellID)
    if ns.IsCooldownViewerAuraActive(spellID) then return true end
    return C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID
        and C_UnitAuras.GetPlayerAuraBySpellID(spellID) ~= nil
end

-- Player-castable lust spells (mirrors EllesmereUIQoL_Bloodlust.lua's
-- LUST_SPELLS) -- checked as buffs on the player, not the sated lockout.
local LUST_BUFFS = {
    2825,    -- Bloodlust
    32182,   -- Heroism
    80353,   -- Time Warp
    390386,  -- Fury of the Aspects
    272678,  -- Primal Rage
}

function ns.HasBloodlust()
    for _, sid in ipairs(LUST_BUFFS) do
        if ns.HasBuff(sid) then return true end
    end
    return false
end

-------------------------------------------------------------------------------
--  Misc helpers
-------------------------------------------------------------------------------

-- Text-to-speech, local-only playback. Argument order on live clients is
-- (voiceID, text, destination, volume, interrupt); destination 1 = local.
-- Silently no-ops if TTS isn't available (mirrors EllesmereUIQoL_MovementAlert.lua).
function ns.SpeakAlertText(text)
    if not (C_VoiceChat and C_VoiceChat.SpeakText) then return end
    pcall(C_VoiceChat.SpeakText, 0, text, 1, 100, true)
end

-- Truncates a single-line FontString's text (font size stays fixed at
-- whatever the caller already set) so it never overflows a given max width
-- -- cuts from the end and appends "..." once the full text no longer fits.
-- fullText is the UNtruncated intended text, stored by the caller, so a
-- later width/style change can always re-truncate from the real text
-- instead of compounding truncation on an already-cut string.
function ns.TruncateFontStringText(fs, fullText, maxWidth)
    fs:SetText(fullText)
    if not maxWidth or maxWidth <= 0 then return end
    if fs:GetStringWidth() <= maxWidth then return end
    local lo, hi = 0, #fullText
    while lo < hi do
        local mid = math.ceil((lo + hi + 1) / 2)
        fs:SetText(fullText:sub(1, mid) .. "...")
        if fs:GetStringWidth() <= maxWidth then
            lo = mid
        else
            hi = mid - 1
        end
    end
    fs:SetText(lo > 0 and (fullText:sub(1, lo) .. "...") or "...")
end

function ns.ColorHex(c)
    local r = math.floor((c and c.r or 1) * 255 + 0.5)
    local g = math.floor((c and c.g or 1) * 255 + 0.5)
    local b = math.floor((c and c.b or 1) * 255 + 0.5)
    return string.format("|cff%02x%02x%02x", r, g, b)
end
