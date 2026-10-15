local _, ns = ...

-------------------------------------------------------------------------------
--  Plugin Glows: registers the APL's next-up spell as a glow source with the
--  EUI Cooldown Manager (EllesmereUI.PluginGlows). The player picks a Glow
--  Style / Glow Color for it in the icon right-click menu. Nothing runs until
--  they do (onInUse); then a poll runs in combat only.
-------------------------------------------------------------------------------
local GLOW_POLL_INTERVAL = 0.2
local _glowHandle, _glowTicker, _glowFrame
local _glowInCombat = false
local _glowLastSpellID, _glowPushes = nil, 0

local function GlowTick()
    local spellID
    if _glowInCombat then spellID = ns.EvaluateExpected() end
    if spellID == _glowLastSpellID then return end
    _glowLastSpellID = spellID
    _glowPushes = _glowPushes + 1
    _glowHandle:SetSpells(spellID)
end

-- Combat state comes from the event itself: InCombatLockdown() is not reliable at the exact moment PLAYER_REGEN_DISABLED fires.
local function GlowSync(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
        _glowInCombat = true
    elseif event == "PLAYER_REGEN_ENABLED" then
        _glowInCombat = false
    else
        _glowInCombat = InCombatLockdown() and true or false
    end
    if _glowInCombat then
        if not _glowTicker then
            _glowTicker = C_Timer.NewTicker(GLOW_POLL_INTERVAL, GlowTick)
        end
        GlowTick()
    else
        if _glowTicker then _glowTicker:Cancel(); _glowTicker = nil end
        _glowLastSpellID = nil
        _glowHandle:Clear()
    end
end

local function StartGlowDriver(handle)
    _glowHandle = handle
    if _glowFrame then return end
    _glowFrame = CreateFrame("Frame")
    _glowFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    _glowFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    _glowFrame:SetScript("OnEvent", GlowSync)
    GlowSync()
end

if EllesmereUI and EllesmereUI.PluginGlows then
    EllesmereUI.PluginGlows.Register("APLforEUI-NextSpell", {
        name = "APLforEUI: Next Spell",
        onInUse = StartGlowDriver,
    })
end

-- Plugin Glows status: shows which link in the chain (registered -> in use ->
-- driver -> push) is missing.
ns.slashCommands.glow = function()
    local pg = EllesmereUI and EllesmereUI.PluginGlows
    local expected = ns.EvaluateExpected()
    print(string.format(
        "APL glow: PluginGlows=%s registered=%s inUse=%s driver=%s ticker=%s inCombat=%s pushes=%d lastPushed=%s evaluatesTo=%s",
        tostring(pg ~= nil), tostring(pg and pg.IsRegistered("APLforEUI-NextSpell") or false),
        tostring(_glowHandle and _glowHandle:IsInUse() or false), tostring(_glowFrame ~= nil),
        tostring(_glowTicker ~= nil), tostring(_glowInCombat), _glowPushes,
        tostring(_glowLastSpellID), tostring(expected)))
end
