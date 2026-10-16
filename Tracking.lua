local _, ns = ...

-------------------------------------------------------------------------------
--  Cast tracking and compliance stats. Reports EVERY successful player cast
--  against the active APL's current top pick. Event handling mirrors
--  EllesmereUIDamageMeters_SpellHistory.lua (EUI's own cast tracker, already
--  proven accurate) instead of reinventing it.
-------------------------------------------------------------------------------
local ResolveOverride = ns.ResolveOverride
local SpellName = ns.SpellName
local SpellResolvable = ns.SpellResolvable

-- specID and APL runtime that were active when tracking started.
local _trackedSpecID, _trackedRT

-- EvaluateExpected returns (spellID, step); wrap both into one value so it can
-- be stored/passed through the castGUID-keyed tables below without a second
-- parallel table.
local function SnapshotExpected()
    local spellID, step = ns.EvaluateExpected()
    return { spellID = spellID, step = step }
end

-- Echo guard state for ReportCast (see comment there). Declared before the
-- function so it closes over these locals, not nil globals of the same name.
local _lastReportedSpellID, _lastReportedTime = nil, 0
local ECHO_WINDOW = 0.3

-- Rolling 60s window of report outcomes, for the stats prefix (actions,
-- compliance %, mastery breaks). Pruned to the window on every record.
local _recentReports = {}
local STATS_WINDOW = 60

local function ComputeStats()
    local total, matchedCount, mastery = #_recentReports, 0, 0
    for _, e in ipairs(_recentReports) do
        if e.matched then matchedCount = matchedCount + 1 end
        if e.brokeMastery then mastery = mastery + 1 end
    end
    local pct = total > 0 and math.floor((matchedCount / total) * 100 + 0.5) or 0
    return total, pct, mastery
end

-- Shared by the broker feed and the standalone display: (label, total, pct,
-- mastery, compliant) where compliant is true/false/nil (nil = no casts yet).
function ns.BuildStatsSummary()
    local total, pct, mastery = ComputeStats()
    local rt = ns.GetActiveAPL()
    local label = rt and ns.Engine.CurrentListName(rt) or "-"
    local lastEntry = _recentReports[#_recentReports]
    local compliant = lastEntry and lastEntry.matched
    return label, total, pct, mastery, compliant
end

-- Optional LibDataBroker-1.1 feed: a standard, third-party shared library
-- (NOT an EUI internal) that EUI's own DataBars already reads generically via
-- its built-in "Broker Plugin" block type -- lets the user add these stats to
-- an existing DataBar with zero EUI-specific code on either side.
local _ldb = LibStub and LibStub:GetLibrary("LibDataBroker-1.1", true)
local _brokerObj = _ldb and _ldb:NewDataObject("APLforEUI", {
    type = "data source",
    text = "ST: 0/0%/0",
    icon = "Interface\\Icons\\INV_Misc_QuestionMark",
    OnTooltipShow = function(tooltip)
        tooltip:AddLine("APL for EUI")
        tooltip:AddLine("Actions / Compliance % / Mastery Breaks (last 60s)", 1, 1, 1)
    end,
})

local function UpdateBrokerText()
    if not _brokerObj then return end
    local label, total, pct, mastery, compliant = ns.BuildStatsSummary()
    -- White until the first cast is recorded; green/red by the LAST cast's
    -- compliance after that. Note: EUI's Broker Plugin block strips embedded
    -- color codes unless "Strip Colors" is turned off on that block.
    local colorCode = "|cffffffff"
    if compliant == true then colorCode = "|cff00ff00"
    elseif compliant == false then colorCode = "|cffff0000" end
    _brokerObj.text = label .. ": " .. total .. "/" .. colorCode .. pct .. "%|r/" .. mastery
end

local function RecordStatsEntry(matched, brokeMastery)
    local now = GetTime()
    _recentReports[#_recentReports + 1] = { time = now, matched = matched, brokeMastery = brokeMastery }
    while _recentReports[1] and (now - _recentReports[1].time) > STATS_WINDOW do
        table.remove(_recentReports, 1)
    end
    UpdateBrokerText()
    ns.UpdateStandaloneText()
end

local function BuildStatsPrefix()
    local total, pct, mastery = ComputeStats()
    -- "/" not "|": WoW chat treats a literal "|" as the start of an escape
    -- sequence (|cFFxxxxxx, |r, |H..|h..|h, |T..|t), corrupting the line.
    return "[" .. total .. "/" .. pct .. "%/" .. mastery .. "]"
end

local function ReportCast(spellID, expected)
    -- Echo guard: some spells (Fists of Fury, Spinning Crane Kick) fire their
    -- start/succeeded events twice per real cast, each on its own castGUID,
    -- from every reporting path below (CHANNEL_START, direct castGUID match,
    -- and the spellID-fallback scan) -- the GCD alone (~1.5s) is far longer
    -- than any such echo, so a sub-GCD repeat of the identical spellID here
    -- is the echo, not a real second cast. Centralized here so it applies no
    -- matter which path led to the call, in or out of combat.
    if spellID == _lastReportedSpellID and (GetTime() - _lastReportedTime) < ECHO_WINDOW then
        return
    end
    _lastReportedSpellID, _lastReportedTime = spellID, GetTime()
    ns.OnCastSuppressSuggest(_lastReportedTime)

    local rt = ns.GetActiveAPL()
    if rt then ns.Engine.OnCast(rt, spellID) end

    -- TEMP DEBUG: unconditional (not combat-gated) so the exact resolved
    -- spellID a cast reports as is visible even for precasts/dummy testing --
    -- remove once the Zenith cast-detection mismatch is confirmed/fixed.
    if ns.chatOutput then
        print("APL debug: cast detected spellID=" .. spellID .. " (" .. SpellName(spellID) .. ")")
    end

    -- Only real rotation casts matter for compliance/mastery tracking --
    -- world/downtime casts between pulls would otherwise pollute the stats.
    local expectedSpellID = expected and expected.spellID
    local expectedStep = expected and expected.step
    local brokeMastery = spellID == ns.lastCastSpellID
    if InCombatLockdown() then
        local matched = not brokeMastery and spellID == expectedSpellID
        RecordStatsEntry(matched, brokeMastery)
        if ns.chatOutput then
            local prefix = "APL: " .. BuildStatsPrefix() .. " "
            if brokeMastery then
                print(prefix .. SpellName(spellID) .. " (Broke Mastery)")
            elseif spellID == expectedSpellID then
                print(prefix .. SpellName(spellID) .. " (step " .. tostring(expectedStep) .. ")")
            else
                print(prefix .. SpellName(spellID) .. " (Expected " .. SpellName(expectedSpellID)
                    .. ", step " .. tostring(expectedStep) .. ")")
            end
        end
    end
    ns.lastCastSpellID = spellID
end

-- castGUID -> expected spellID, snapshotted at cast-sent (before the cast
-- resolves) so the comparison reflects state at decision time, not after.
local pendingExpected = {}
-- castGUID -> true, once that cast's SUCCEEDED has been reported. Several
-- spells (true channels, and apparently periodic-tick abilities like Spinning
-- Crane Kick) refire SUCCEEDED repeatedly for the SAME underlying cast --
-- report once per castGUID, not once per event.
local _reportedCastGUID = {}
-- spellID -> true, caches IsSpellKnownOrOverridesKnown results (that API is
-- flaky on repeated calls) -- mirrors EUI's SpellHistory tracker exactly.
local _knownOverrides = {}
-- castGUID -> spellID, for any NON-INSTANT cast (hard-cast via START,
-- channel via CHANNEL_START) still in progress. Kept alive for the cast's
-- whole real lifecycle (cleared only at its matching STOP/CHANNEL_STOP/
-- FAILED/INTERRUPTED), NOT cleared the moment it's first reported, so a
-- trailing echo SUCCEEDED with a brand-new castGUID can still be matched by
-- spellID and swallowed via _reportedCastGUID instead of re-reported.
local _pendingCastSpellID = {}

local eventFrame = CreateFrame("Frame")
local active = false

local function OnEvent(_, event, unit, ...)
    if unit ~= "player" then return end

    if event == "UNIT_AURA" then
        local rt = ns.GetActiveAPL()
        if rt then ns.Engine.OnAura(rt) end
        return
    end

    -- UNIT_SPELLCAST_SENT has unique args: unit, target, castGUID, spellID
    if event == "UNIT_SPELLCAST_SENT" then
        local _, castGUID = ...
        if castGUID then pendingExpected[castGUID] = SnapshotExpected() end
        return
    end

    local castGUID, spellID = ...

    if event == "UNIT_SPELLCAST_START" then
        if not castGUID then return end
        local _, _, _, _, _, _, _, castSpellID = UnitCastingInfo("player")
        local sid = ResolveOverride(castSpellID or spellID)
        if sid then _pendingCastSpellID[castGUID] = sid end

    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
        if castGUID and _reportedCastGUID[castGUID] then return end
        local _, _, _, _, _, _, _, chanSpellID = UnitChannelInfo("player")
        local sid = ResolveOverride(chanSpellID or spellID)
        if not sid then return end
        ns.currentChannelSpellID = sid
        local expected = (castGUID and pendingExpected[castGUID]) or SnapshotExpected()
        if castGUID then
            pendingExpected[castGUID] = nil
            _reportedCastGUID[castGUID] = true
            _pendingCastSpellID[castGUID] = sid
        end
        ReportCast(sid, expected)

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if not spellID then return end
        local rawSpellID = spellID

        -- Direct castGUID match against a pending hard cast: finish it as-is,
        -- no filtering needed (UNIT_SPELLCAST_START already resolved it via
        -- the official UnitCastingInfo API, not a raw event spellID).
        if castGUID and _pendingCastSpellID[castGUID] and not _reportedCastGUID[castGUID] then
            local resolvedSid = _pendingCastSpellID[castGUID]
            local expected = pendingExpected[castGUID] or SnapshotExpected()
            pendingExpected[castGUID] = nil
            _reportedCastGUID[castGUID] = true
            ReportCast(resolvedSid, expected)
            return
        end

        if castGUID and _reportedCastGUID[castGUID] then return end

        -- Filters out non-ability "echo"/tick sub-casts (internal periodic-tick
        -- IDs distinct from the real ability) and system spells (LOGINEFFECT,
        -- DND, etc.) -- mirrors EUI's own cast tracker exactly; this is what
        -- keeps Spinning Crane Kick/Fists of Fury/Unity Within from reporting
        -- once per internal tick instead of once per actual cast.
        if not IsPlayerSpell(spellID) then
            if not _knownOverrides[spellID] then
                if IsSpellKnownOrOverridesKnown and IsSpellKnownOrOverridesKnown(spellID) then
                    _knownOverrides[spellID] = true
                else
                    return
                end
            end
        end

        spellID = ResolveOverride(spellID)
        if not SpellResolvable(spellID) then return end

        -- TEMP DEBUG: raw event spellID vs. after ResolveOverride, to catch a
        -- same-instant override flip (e.g. a buff-granting cast whose own
        -- override condition becomes true before this handler runs).
        if ns.chatOutput and rawSpellID ~= spellID then
            print("APL debug: raw spellID=" .. rawSpellID .. " resolved to " .. spellID)
        end

        -- Same non-instant cast, but this repeat/tick event arrived on a
        -- different (or nil) castGUID -- find it by spellID instead. If it
        -- was already reported (a channel already announced at CHANNEL_START,
        -- or an earlier echo already handled), swallow this one silently
        -- instead of double-reporting it.
        local pendingGUID
        for gid, pendingSid in pairs(_pendingCastSpellID) do
            if pendingSid == spellID then pendingGUID = gid; break end
        end
        if pendingGUID and _reportedCastGUID[pendingGUID] then
            if castGUID then _reportedCastGUID[castGUID] = true end
            return
        end

        local expected = (pendingGUID and pendingExpected[pendingGUID])
            or (castGUID and pendingExpected[castGUID])
            or SnapshotExpected()
        if pendingGUID then
            pendingExpected[pendingGUID] = nil
            _reportedCastGUID[pendingGUID] = true
        end
        if castGUID then
            pendingExpected[castGUID] = nil
            _reportedCastGUID[castGUID] = true
        end
        ReportCast(spellID, expected)

    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        ns.currentChannelSpellID = nil
        if castGUID then
            pendingExpected[castGUID] = nil
            _reportedCastGUID[castGUID] = nil
            _pendingCastSpellID[castGUID] = nil
        end

    elseif castGUID then
        -- UNIT_SPELLCAST_FAILED / FAILED_QUIET / INTERRUPTED / STOP: the cast's
        -- real lifecycle has ended, drop every snapshot for it without reporting.
        pendingExpected[castGUID] = nil
        _reportedCastGUID[castGUID] = nil
        _pendingCastSpellID[castGUID] = nil
    end
end
eventFrame:SetScript("OnEvent", OnEvent)

function ns.IsTracking() return active end

function ns.StartTracking()
    if active then return end
    active = true
    _trackedSpecID = ns.GetSpecID()
    _trackedRT = ns.GetActiveAPL()
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_FAILED_QUIET", "player")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player")
    eventFrame:RegisterUnitEvent("UNIT_AURA", "player")
end

function ns.StopTracking()
    if not active then return end
    active = false
    eventFrame:UnregisterAllEvents()
    wipe(pendingExpected)
    wipe(_reportedCastGUID)
    wipe(_pendingCastSpellID)
    wipe(_recentReports)
    UpdateBrokerText()
    ns.UpdateStandaloneText()
    _lastReportedSpellID, _lastReportedTime = nil, 0
    ns.lastCastSpellID = nil
    if _trackedRT then ns.Engine.Reset(_trackedRT) end
    _trackedSpecID, _trackedRT = nil, nil
end

local specFrame = CreateFrame("Frame")
specFrame:RegisterEvent("PLAYER_LOGIN")
specFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
specFrame:SetScript("OnEvent", function(_, event, unit)
    if event == "PLAYER_SPECIALIZATION_CHANGED" and unit ~= "player" then return end
    if event == "PLAYER_LOGIN" then
        ns.ApplyStandalone()
        ns.ApplySuggest()
    end
    -- Only restart on a real spec change (this event also fires on talent
    -- swaps), so one spec's tracked state never carries into another.
    local specID = ns.GetSpecID()
    if specID ~= _trackedSpecID or not active then
        ns.StopTracking()
        if ns.IsSpecSupported() then ns.StartTracking() end
    end
    ns.ApplyStandaloneVisibility()
    ns.ApplySuggestVisibility()
end)

ns.slashCommands.chat = function()
    ns.chatOutput = not ns.chatOutput
    print("APL for EUI: chat output " .. (ns.chatOutput and "enabled" or "disabled") .. ".")
end
