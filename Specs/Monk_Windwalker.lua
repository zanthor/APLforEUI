local _, ns = ...

-------------------------------------------------------------------------------
--  Windwalker Monk spec module: the simplified test APL (NOT a real rotation)
--  and every self-tracked clock it depends on. Design notes: monkapl.md.
-------------------------------------------------------------------------------
local ResolveOverride = ns.ResolveOverride
local IsOffCooldown = ns.IsOffCooldown
local IsTalented = ns.IsTalented
local HasBuff = ns.HasBuff
local HasBloodlust = ns.HasBloodlust
local FindCooldownViewerItemForSpell = ns.FindCooldownViewerItemForSpell
local IsChanneling = ns.IsChanneling
local SpeakAlertText = ns.SpeakAlertText

local TIGER_PALM             = 100780
local FISTS_OF_FURY          = 113656
local BLACKOUT_KICK          = 100784
local RISING_SUN_KICK        = 107428
local RUSHING_WIND_KICK      = 467307
local WHIRLING_DRAGON_PUNCH  = 152175
local CELESTIAL_CONDUIT      = 443028
local INVOKE_XUEN            = 123904
local ZENITH_STOMP           = 1272696
local ZENITH_BUFF            = 1249625  -- same id casts the cooldown and tags the buff
local OBSIDIAN_SPIRAL_TALENT = 1249832
local HARMONIC_COMBO_TALENT  = 1250041
local SPINNING_CRANE_KICK    = 101546
local COMBO_BREAKER_BUFF     = 137384
local HEART_OF_JADE_SERPENT_BUFF = 443294
local DANCE_OF_CHI_JI_BUFF   = 325202
local UNBROKEN_RHYTHM_BUFF   = 1297033
local RESTORE_BALANCE_TALENT = 442719  -- Invoke Xuen: 2 min cooldown
local XUENS_BOND_TALENT      = 292986  -- Invoke Xuen: 90 sec cooldown
local STRIKE_OF_THE_WINDLORD = 392983
local SLICING_WINDS          = 1217413
local SHADOWBOXING_TREADS_TALENT = 392982
local ZENITH_STOMP_TALENT    = 1261849  -- grants Zenith Stomp itself; without it Stomp isn't a valid action at all
local WINDWALKER_SPEC_ID     = 269

local ZENITH_STOMP_CAST_TIME = 3  -- seconds per charge, for "almost over" (see IsZenithAlmostOver)
local ZENITH_BUFF_DURATION = 20  -- seconds; the buff window, NOT the 90s charge recharge

local function GetChi()
    return UnitPower("player", Enum.PowerType.Chi) or 0
end

-- Self-tracked cooldown clock, scoped ONLY to spells whose exact remaining
-- time gates a decision (just Invoke Xuen, for the WDP rule below) -- every
-- other spell only ever needs ready/not-ready, which the cheap boolean
-- IsOffCooldown already answers for free. GetSpellBaseCooldown is STATIC
-- spell data (the design value), never live cooldown state, so it is never
-- secret even in real combat; seeded once per spellID and cached.
local _selfTrackedBaseDuration = {}
local _selfTrackedReadyAt = {}

local function GetBaseDuration(spellID)
    -- Invoke Xuen's cooldown is talent-gated (90s or 120s), and
    -- GetSpellBaseCooldown only ever reports the untalented baseline, not
    -- whichever of the two is actually chosen -- resolve it directly instead.
    if spellID == INVOKE_XUEN then
        if IsTalented(XUENS_BOND_TALENT) then return 90 end
        if IsTalented(RESTORE_BALANCE_TALENT) then return 120 end
    end
    local dur = _selfTrackedBaseDuration[spellID]
    if dur then return dur end
    local ms = GetSpellBaseCooldown and GetSpellBaseCooldown(spellID)
    dur = (type(ms) == "number" and ms > 0) and (ms / 1000) or 0
    _selfTrackedBaseDuration[spellID] = dur
    return dur
end

-- Called from ReportCast for every self-tracked spellID actually cast.
local function RecordSelfTrackedCast(spellID)
    local base = GetBaseDuration(spellID)
    if base > 0 then _selfTrackedReadyAt[spellID] = GetTime() + base end
end

-- Seconds until ready, or nil if we have never seen this spell cast this
-- session (no baseline to count down from yet).
local function TimeUntilReady(spellID)
    local readyAt = _selfTrackedReadyAt[spellID]
    if not readyAt then return nil end
    return math.max(0, readyAt - GetTime())
end

-- Zenith's exact charge COUNT (0/1/2) is fully knowable live, no self-
-- tracking or guessing needed: GetSpellCharges().isActive is the clean "not
-- at max" bool (Max Stacks Glow's own signal), and GetSpellCooldown()
-- .isActive-and-not-isOnGCD means "0 charges" for a charge spell -- confirmed
-- by EUI's own Hide-CD-Text-(Charges) logic (EUI_CDM_HookIconWatch.lua:
-- "charges > 0" <=> NOT on a real, non-GCD cooldown). Neither signal ever
-- touches the secret currentCharges field.
local ZENITH_MAX_CHARGES = 2

local function GetZenithChargesAvailable()
    local ci = C_Spell and C_Spell.GetSpellCharges and C_Spell.GetSpellCharges(ZENITH_BUFF)
    if not (ci and (ci.maxCharges or 0) > 1) then return ZENITH_MAX_CHARGES end
    if not ci.isActive then return ZENITH_MAX_CHARGES end
    local cd = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(ZENITH_BUFF)
    local onRealCd = cd and cd.isActive and not cd.isOnGCD
    return onRealCd and 0 or 1
end

-- Exact seconds remaining on a recharge IS secret (startTime/duration), so
-- with exactly 1 charge in hand the only safe reserve check is against the
-- one piece of data that's never secret -- the static base recharge
-- duration -- rather than a timing guess: hold the charge back if Xuen is
-- due sooner than a full recharge could possibly complete, otherwise spend
-- freely. Always safe to spend from 2 (one charge remains either way).
local function SafeToSpendZenithCharge(xuenRemaining)
    local charges = GetZenithChargesAvailable()
    if charges >= 2 then return true end
    if charges <= 0 then return false end
    return xuenRemaining == nil or xuenRemaining >= GetBaseDuration(ZENITH_BUFF)
end


local function HasHeartOfJadeSerpent() return HasBuff(HEART_OF_JADE_SERPENT_BUFF) end
local function HasZenith() return HasBuff(ZENITH_BUFF) end
local function HasUnbrokenRhythm() return HasBuff(UNBROKEN_RHYTHM_BUFF) end

-- Combo Breaker and Dance of Chi-Ji are RNG procs (secret stack counts in
-- real combat, same class of problem as Zenith Stomp's charges), capped at
-- 2 stacks, 15s duration each. CONFIRMED via a live crash log: under real
-- secret-value restriction, EVERY per-aura field on the Cooldown Viewer
-- item -- instance ID, applications, even the updatedAuraInstanceIDs list
-- contents from the UNIT_AURA event itself -- reads as a secret value, and
-- comparing/indexing them (even `==` against another secret, or iterating
-- the list) hard-errors. Only a nil-check (`~= nil`, used for presence) is
-- safe on a secret value -- equality/ordering between two non-nil values is
-- not. So a stack gain while the buff is ALREADY active is undetectable
-- under restriction: the only safe signal is IsShown() (on/off), which
-- doesn't change between 1 and 2 stacks. The real applications count is
-- still tried (ReadProcApplications) for whatever content isn't secret-
-- restricted, but there is no fallback for when it is. Consuming a stack
-- (Blackout Kick / Spinning Crane Kick) is tracked from the actual cast
-- instead, in ReportCast -- that part is unaffected by any of this.
local PROC_STACK_MAX = 2
local PROC_STACK_DURATION = 15
local PROC_ALMOST_OVER_THRESHOLD = 3

local function NewProcStackState()
    return { stacks = 0, expiresAt = nil }
end
local _comboBreakerState = NewProcStackState()
local _danceOfChiJiState = NewProcStackState()

-- Reads the real applications (stack) count off the Cooldown Viewer item,
-- same technique as EllesmereUI's ReadBuffApplications: GetAuraDataByAuraInstanceID
-- (pcall-wrapped -- hard-errors under secrecy) first, then the raw cached
-- field as a fallback (plain table read, never a method call that can
-- re-trigger a scan). Deliberately NEVER calls item:GetAuraData() -- that
-- goes through C_UnitAuras.GetUnitAuras(), which hard-errors with "Auras
-- cannot be accessed when secret while tainted by 'APLforEUI'" when called
-- from our addon's stack (confirmed via live error log).
local function ReadProcApplications(item)
    local iid = item.auraInstanceID
    if iid and not (issecretvalue and issecretvalue(iid)) then
        local unit = item.auraDataUnit
        if unit and not (issecretvalue and issecretvalue(unit)) then
            local ok, data = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, iid)
            if ok and data and data.applications ~= nil then
                if issecretvalue and issecretvalue(data.applications) then return nil end
                return data.applications
            end
        end
    end
    local ad = item.auraDataCached
    local apps = ad and ad.applications
    if apps == nil then return nil end
    if issecretvalue and issecretvalue(apps) then return nil end
    return apps
end

-- Called on UNIT_AURA: resyncs presence/stacks against the live Cooldown
-- Viewer signal. Deliberately does NOT touch state.expiresAt on gain --
-- under combat secrecy there's no reliable way to know the exact moment
-- of application (see block comment above), so the expiry clock is owned
-- entirely by EnsureProcTimer below, lazily, at APL evaluation time
-- instead of here.
local function UpdateProcStacks(spellID, state)
    local item = FindCooldownViewerItemForSpell(spellID)
    local active = item ~= nil and item:IsShown() and item.GetAuraSpellInstanceID
        and item:GetAuraSpellInstanceID() ~= nil
    if not active then
        state.stacks, state.expiresAt = 0, nil
        return
    end
    if state.stacks == 0 then
        state.stacks = 1
    end
    -- Real applications count, when it happens to be readable (non-
    -- restricted content) -- see ReadProcApplications. In combat this is
    -- almost always nil; stacks then just stays at "at least 1 present".
    local apps = ReadProcApplications(item)
    if apps ~= nil then
        state.stacks = math.min(apps, PROC_STACK_MAX)
    end
end

-- Called from ReportCast for every observed Blackout Kick/Spinning Crane
-- Kick cast -- the game consumes a stack automatically whenever the
-- matching finisher is cast while stacks > 0.
local function ConsumeProcStack(state)
    if state.stacks <= 0 then return end
    state.stacks = state.stacks - 1
    if state.stacks <= 0 then
        state.stacks, state.expiresAt = 0, nil
    end
end

local function HasComboBreaker() return _comboBreakerState.stacks > 0 end
local function HasDanceOfChiJi() return _danceOfChiJiState.stacks > 0 end

-- We can't catch the exact moment of application under combat secrecy, so
-- the clock starts (duration - this) seconds instead of a full fresh
-- window -- biases toward flagging "almost over" a bit EARLY rather than
-- risking missing the real window entirely.
local PROC_TIMER_START_DISCOUNT = 2

-- Lazily (re)starts a proc's expiry clock the first time evaluation sees
-- it present with no clock already running -- called from IsProcDumpReady,
-- i.e. at APL evaluation time, not event-driven.
local function EnsureProcTimer(state)
    if state.stacks <= 0 then
        state.expiresAt = nil
        return
    end
    if state.expiresAt == nil then
        state.expiresAt = GetTime() + PROC_STACK_DURATION - PROC_TIMER_START_DISCOUNT
    end
end

-- Time-only: "almost out of time" -- dump it now rather than waste whatever
-- is left before the buff disappears. NOT stack-count-based: there is no
-- meaningful way to count stacks under combat secrecy (see block comment
-- above), so a 2nd-stack-cap trigger was removed -- PROC_STACK_MAX/stacks
-- stay as infrastructure for if a stack-gain detection method is found.
local function IsProcDumpReady(state)
    EnsureProcTimer(state)
    if state.stacks <= 0 then return false end
    return state.expiresAt ~= nil and (state.expiresAt - GetTime()) <= PROC_ALMOST_OVER_THRESHOLD
end
local function IsComboBreakerDumpReady() return IsProcDumpReady(_comboBreakerState) end
local function IsDanceOfChiJiDumpReady() return IsProcDumpReady(_danceOfChiJiState) end

-- Heart of the Jade Serpent's remaining time is secret even through
-- Blizzard's own linked-aura resolution (CooldownViewerItemData.lua's
-- GetSpellID()/GetAuraSpellID() read secret while any of its 3 source auras
-- is active), so monkapl.md's "<2s left" Fists of Fury condition is entirely
-- self-tracked off observed casts, not the live aura. Whirling Dragon Punch
-- and Celestial Conduit each grant a flat 6s window, always overwriting
-- whatever was there; Zenith grants 4s, extending (adding its 4s) a
-- currently active WDP/Conduit window but otherwise starting fresh.
local HOTJS_ALMOST_OVER_THRESHOLD = 2
local HOTJS_ZENITH_DURATION = 4
local HOTJS_WDP_CONDUIT_DURATION = 6
local _hotJSExpiresAt
local _hotJSSource

-- Called from ReportCast for every observed Whirling Dragon Punch/Celestial
-- Conduit cast.
local function RecordHotJSFromWdpOrConduit()
    _hotJSExpiresAt = GetTime() + HOTJS_WDP_CONDUIT_DURATION
    _hotJSSource = "wdp_conduit"
end

-- Called from ReportCast for every observed Zenith cast.
local function RecordHotJSFromZenith()
    local now = GetTime()
    if _hotJSSource == "wdp_conduit" and _hotJSExpiresAt and _hotJSExpiresAt > now then
        _hotJSExpiresAt = _hotJSExpiresAt + HOTJS_ZENITH_DURATION
    else
        _hotJSExpiresAt = now + HOTJS_ZENITH_DURATION
    end
    _hotJSSource = "zenith"
end

-- Unknown timing (no cast observed yet this session) defaults to "not ending
-- soon" rather than guessing.
local function IsHeartOfJadeSerpentEndingSoon()
    if not HasHeartOfJadeSerpent() then return false end
    if not _hotJSExpiresAt then return false end
    return (_hotJSExpiresAt - GetTime()) <= HOTJS_ALMOST_OVER_THRESHOLD
end

-- Fists of Fury's base 3 Chi cost drops 1 while the Zenith buff is active and
-- another 1 with the Harmonic Combo talent -- both can apply at once, never
-- below a floor of 1.
local function GetFistsOfFuryCost()
    local cost = 3
    if HasZenith() then cost = cost - 1 end
    if IsTalented(HARMONIC_COMBO_TALENT) then cost = cost - 1 end
    return math.max(1, cost)
end


-- Zenith's BUFF lasts a flat 20s, entirely separate from the 90s recharge on
-- the charges that cast it (GetBaseDuration(ZENITH_BUFF)/TimeUntilReady track
-- THAT recharge, for the opener reserve logic -- conflating the two is the
-- bug this replaced) -- self-tracked off the same observed casts since live
-- aura remaining-time is secret in real combat, same as cooldowns.
local _zenithBuffExpiresAt

-- Called from ReportCast for every observed Zenith cast.
local function RecordZenithBuffCast()
    _zenithBuffExpiresAt = GetTime() + ZENITH_BUFF_DURATION
end

-- Zenith Stomp's 2 charges are tied to the Zenith buff window itself, not a
-- real recharge timer -- GetSpellCharges().isActive never goes true for it
-- (matching "no cooldown"), so IsOffCooldown always reports "ready" even at
-- 0 charges left. No live signal distinguishes that, so it's self-tracked
-- purely off observed casts: reset to full whenever Zenith is (re)cast,
-- spent on each observed Zenith Stomp.
local ZENITH_STOMP_MAX_CHARGES = 2
local _zenithStompChargesRemaining = ZENITH_STOMP_MAX_CHARGES

-- Called from ReportCast for every observed Zenith cast.
local function ResetZenithStompCharges()
    _zenithStompChargesRemaining = ZENITH_STOMP_MAX_CHARGES
end

-- Called from ReportCast for every observed Zenith Stomp cast.
local function RecordZenithStompCast()
    _zenithStompChargesRemaining = math.max(0, _zenithStompChargesRemaining - 1)
end

local function HasZenithStompCharge()
    return IsTalented(ZENITH_STOMP_TALENT) and _zenithStompChargesRemaining > 0
end

-- Zenith (the builder) and Zenith Stomp (the spender) share ONE action --
-- every press reports the same spellID (ZENITH_STOMP) once talented into
-- Stomp's charges, confirmed live (the builder's own id never appears in
-- the combat log at all in that build). The game itself still treats the
-- press differently depending on the buff's state at the moment it lands:
--  * buff fully down -> a real build: starts a fresh 20s window AND refills
--    Stomp's own 2 charges.
--  * buff up with <= 2s left -> a recast-to-extend: refreshes the window
--    back to 20s but grants NO new Stomp charges (existing count carries
--    over unchanged) -- confirmed, you cannot double up on charges this way.
--  * buff up with more than 2s left -> a genuine Stomp spend.
-- All three are distinguished from our OWN prior tracked expiry, read
-- BEFORE this call updates it, not the live buff bool (which already
-- reads "up" immediately after any of the three, build included).
local ZENITH_RECAST_EXTEND_WINDOW = 2

local function RecordZenithOrStompCast()
    local now = GetTime()
    local hadActiveWindow = _zenithBuffExpiresAt and _zenithBuffExpiresAt > now
    if not hadActiveWindow then
        RecordZenithBuffCast()
        ResetZenithStompCharges()
        RecordHotJSFromZenith()
    elseif (_zenithBuffExpiresAt - now) <= ZENITH_RECAST_EXTEND_WINDOW then
        RecordZenithBuffCast()
        RecordHotJSFromZenith()
    else
        RecordZenithStompCast()
    end
end

-- "Almost over" means "not enough time left to spend every remaining Zenith
-- Stomp charge" (~3s per cast/GCD), not a flat threshold -- 1 charge left
-- needs 3s, 2 charges need 6s, so this scales with HasZenithStompCharge's
-- own counter instead of a fixed number.
local function IsZenithAlmostOver()
    if not HasZenith() then return false end
    if not _zenithBuffExpiresAt then return false end
    local remaining = _zenithBuffExpiresAt - GetTime()
    local neededTime = _zenithStompChargesRemaining * ZENITH_STOMP_CAST_TIME
    return remaining <= neededTime
end

-- Matches monkapl.md's "Single Target APL" list (19 steps); step numbers in
-- the reported tag match that doc exactly. The opener's O1/O2 rules (Invoke
-- Xuen, Zenith-if-missing-reserve-1-for-Xuen) run on every evaluation, not
-- just pre-pull, so they double as doc step 5 ("Zenith if no Zenith Buff")
-- with no separate numbered check needed here.
--  1. Fists of Fury while Heart of the Jade Serpent is up (approximated as
--     "any time it's up" -- the doc's precise "<2s left" needs a buff's
--     exact remaining time, which risks the same secret-value crash as live
--     cooldowns; pending a self-tracked HotJS clock, same pattern as
--     Zenith's buff timer, once its duration/trigger are confirmed).
--  2. Whirling Dragon Punch, unless Xuen is due within 10s or Heart of the
--     Jade Serpent is already up (self-tracked Xuen clock, see above).
--  3. Strike of the Windlord, same gate as Whirling Dragon Punch.
--  4. Celestial Conduit, unless Heart of the Jade Serpent is already up.
--  5. (Zenith if no Zenith Buff -- see O2 above, runs every evaluation.)
--  6. Zenith Stomp if low on Chi, Zenith is almost over, or mid-channel on
--     Celestial Conduit.
--  7. Tiger Palm with no Zenith Buff, Bloodlust up, and Chi <= 4.
--  8. Tiger Palm if there isn't enough Chi to cast Fists of Fury.
--  9. Fists of Fury (plain).
--  10. Rushing Wind Kick (only when it's actually the live override -- NOT
--     interchangeable with Rising Sun Kick, which has its own slot at 14).
--  11. Blackout Kick with <3s left on Combo Breaker (stack count not
--     currently trackable under combat secrecy -- time-only trigger).
--  12. Spinning Crane Kick with <3s left on Dance of Chi-Ji (same caveat).
--  13. Spinning Crane Kick with Unbroken Rhythm.
--  14. Rising Sun Kick (only when Rushing Wind Kick is NOT the live
--     override, and Unbroken Rhythm didn't already claim this slot at 13).
--  15. Blackout Kick with Combo Breaker, or during Zenith while talented
--     into Obsidian Spiral.
--  16. Spinning Crane Kick during Zenith with >4 Chi or Dance of Chi-Ji.
--  17. Tiger Palm if Chi < 2.
--  18. Tiger Palm if Chi <= 4 and no Zenith Buff.
--  19. Tiger Palm/Blackout Kick filler, alternated so the filler itself
--     never recommends repeating the last cast.
local function EvaluateExpectedST()
    local risingSunKick = ResolveOverride(RISING_SUN_KICK)
    -- Celestial Conduit is Invoke Xuen's own override -- the same action bar
    -- slot, only castable in place of Xuen while Xuen is on cooldown.
    local xuenOrConduit = ResolveOverride(INVOKE_XUEN)
    local chi = GetChi()
    local jadeSerpentUp = HasHeartOfJadeSerpent()
    local zenithUp = HasZenith()
    local fofCost = GetFistsOfFuryCost()

    -- Combo Strikes punishes repeating the same ability back-to-back, so the
    -- APL must never recommend a repeat of the last cast.
    local function Pick(spellID)
        if spellID == ns.lastCastSpellID then return nil end
        return spellID
    end

    -- Whirling Dragon Punch/Strike of the Windlord are only usable once
    -- Fists of Fury and Rising Sun Kick (WDP) are on cooldown, or Xuen isn't
    -- due soon (both) -- cooldown/usability flags don't reflect that gate,
    -- so cooldown state is checked directly instead of trusting readiness
    -- alone. Unknown Xuen timing == treat as not-soon, no evidence otherwise.
    local xuenRemaining = TimeUntilReady(INVOKE_XUEN)
    local xuenSoon = xuenRemaining ~= nil and xuenRemaining <= 10

    -- Opener/burst: cast Xuen on cooldown (O1), and spend Zenith charges
    -- whenever the buff is down EXCEPT hold back the last charge if using it
    -- now would leave none banked by the time Xuen is next ready -- Xuen's
    -- burst window always wants at least 1 Zenith charge available with it.
    -- Shared verbatim with the AOE list.
    if xuenOrConduit == INVOKE_XUEN and IsOffCooldown(INVOKE_XUEN) then
        local pick = Pick(INVOKE_XUEN)
        if pick then return pick, "O1" end
    end
    if not zenithUp and SafeToSpendZenithCharge(xuenRemaining) then
        local pick = Pick(ZENITH_BUFF)
        if pick then return pick, "O2" end
    end

    if IsHeartOfJadeSerpentEndingSoon() and IsOffCooldown(FISTS_OF_FURY) and chi >= fofCost then
        local pick = Pick(FISTS_OF_FURY)
        if pick then return pick, 1 end
    end
    local wdpUsable = IsTalented(WHIRLING_DRAGON_PUNCH) and not IsOffCooldown(FISTS_OF_FURY)
        and not IsOffCooldown(risingSunKick) and IsOffCooldown(WHIRLING_DRAGON_PUNCH) and not xuenSoon
    if not jadeSerpentUp and wdpUsable then
        local pick = Pick(WHIRLING_DRAGON_PUNCH)
        if pick then return pick, 2 end
    end
    if not jadeSerpentUp and IsTalented(STRIKE_OF_THE_WINDLORD)
        and IsOffCooldown(STRIKE_OF_THE_WINDLORD) and not xuenSoon then
        local pick = Pick(STRIKE_OF_THE_WINDLORD)
        if pick then return pick, 3 end
    end
    if not jadeSerpentUp and xuenOrConduit == CELESTIAL_CONDUIT and IsOffCooldown(xuenOrConduit) then
        local pick = Pick(xuenOrConduit)
        if pick then return pick, 4 end
    end
    if zenithUp and HasZenithStompCharge()
        and (chi <= 4 or IsZenithAlmostOver() or IsChanneling(CELESTIAL_CONDUIT)) then
        local pick = Pick(ZENITH_STOMP)
        if pick then return pick, 6 end
    end
    if not zenithUp and HasBloodlust() and chi <= 4 then
        local pick = Pick(TIGER_PALM)
        if pick then return pick, 7 end
    end
    -- Real APL also dumps Tiger Palm to avoid capping Energy outside Zenith/
    -- Bloodlust, but Energy's exact value is secret in the real M+/raid combat
    -- this addon targets, with no derived-value escape hatch (even ColorCurve
    -- output stays uncomparable) -- a check that only works where it isn't
    -- needed is pointless, so that half of the rule is left out entirely.
    if chi < fofCost then
        local pick = Pick(TIGER_PALM)
        if pick then return pick, 8 end
    end
    if IsOffCooldown(FISTS_OF_FURY) and chi >= fofCost then
        local pick = Pick(FISTS_OF_FURY)
        if pick then return pick, 9 end
    end
    if IsOffCooldown(risingSunKick) and risingSunKick == RUSHING_WIND_KICK then
        local pick = Pick(risingSunKick)
        if pick then return pick, 10 end
    end
    if IsComboBreakerDumpReady() then
        local pick = Pick(BLACKOUT_KICK)
        if pick then return pick, 11 end
    end
    if IsDanceOfChiJiDumpReady() then
        local pick = Pick(SPINNING_CRANE_KICK)
        if pick then return pick, 12 end
    end
    if HasUnbrokenRhythm() then
        local pick = Pick(SPINNING_CRANE_KICK)
        if pick then return pick, 13 end
    end
    if IsOffCooldown(risingSunKick) and risingSunKick == RISING_SUN_KICK and not HasUnbrokenRhythm() then
        local pick = Pick(risingSunKick)
        if pick then return pick, 14 end
    end
    if HasComboBreaker() or (zenithUp and IsTalented(OBSIDIAN_SPIRAL_TALENT)) then
        local pick = Pick(BLACKOUT_KICK)
        if pick then return pick, 15 end
    end
    if zenithUp and (chi > 4 or HasDanceOfChiJi()) then
        local pick = Pick(SPINNING_CRANE_KICK)
        if pick then return pick, 16 end
    end
    if chi < 2 then
        local pick = Pick(TIGER_PALM)
        if pick then return pick, 17 end
    end
    if chi <= 4 and not zenithUp then
        local pick = Pick(TIGER_PALM)
        if pick then return pick, 18 end
    end
    if ns.lastCastSpellID == BLACKOUT_KICK then return TIGER_PALM, 19 end
    return BLACKOUT_KICK, 19
end

-- AOE variant (more than 1 melee target), a separate 24-step priority list.
-- Matches monkapl.md's "AOE APL" list (24 steps); step numbers match that
-- doc exactly, tagged "A" in the reported step to distinguish them from the
-- ST list's own numbering. Opener O1/O2 (Invoke Xuen, Zenith reserve) run on
-- every evaluation, doubling as doc step 5 ("Zenith if no Zenith Buff") with
-- no separate numbered check needed here, same as the ST list.
--  1. Fists of Fury if Heart of the Jade Serpent has <2s left (self-tracked,
--     see IsHeartOfJadeSerpentEndingSoon above).
--  2. Whirling Dragon Punch if Invoke Xuen's cooldown is longer than 10s.
--  3. Strike of the Windlord if no Heart of the Jade Serpent and Invoke
--     Xuen's cooldown is longer than 10s.
--  4. Celestial Conduit if no Heart of the Jade Serpent.
--  5. (Zenith if no Zenith Buff -- see O2 above, runs every evaluation.)
--  6. Zenith Stomp if low on Chi, Zenith is almost over, or mid-channel on
--     Celestial Conduit.
--  7. Tiger Palm if missing the Chi to cast Fists of Fury.
--  8. Fists of Fury (plain).
--  9. Spinning Crane Kick with Unbroken Rhythm.
--  10. Rising Sun Kick/Rushing Wind Kick, to enable Whirling Dragon Punch
--     (Fists of Fury down, the kick still up).
--  11. Rushing Wind Kick without Unbroken Rhythm.
--  12. Rising Sun Kick with Heart of the Jade Serpent active and without
--     Unbroken Rhythm.
--  13. Blackout Kick with <3s left on Combo Breaker (stack count not
--     currently trackable under combat secrecy -- time-only trigger).
--  14. Spinning Crane Kick with <3s left on Dance of Chi-Ji (same caveat).
--  15. Spinning Crane Kick during Zenith with at least 5 melee targets.
--  16. Rising Sun Kick with Bloodlust or Zenith, but without Unbroken Rhythm.
--  17. Blackout Kick with Obsidian Spiral talented, during Zenith, with
--     Rising Sun Kick on cooldown.
--  18. Spinning Crane Kick (plain).
--  19. Slicing Winds if talented.
--  20. Blackout Kick with Combo Breaker.
--  21. Tiger Palm with Chi <= 4 and no Zenith active.
--  22. Blackout Kick with Shadowboxing Treads talented.
--  23. Rising Sun Kick/Rushing Wind Kick (plain).
--  24. Blackout Kick/Tiger Palm filler, alternated like the ST list's.
local function EvaluateExpectedAOE(meleeCount)
    local risingSunKick = ResolveOverride(RISING_SUN_KICK)
    local xuenOrConduit = ResolveOverride(INVOKE_XUEN)
    local chi = GetChi()
    local jadeSerpentUp = HasHeartOfJadeSerpent()
    local zenithUp = HasZenith()
    local fofCost = GetFistsOfFuryCost()

    local function Pick(spellID)
        if spellID == ns.lastCastSpellID then return nil end
        return spellID
    end

    local xuenRemaining = TimeUntilReady(INVOKE_XUEN)
    local xuenCdLong = xuenRemaining == nil or xuenRemaining > 10

    -- Opener/burst: same rules as the ST list, verbatim.
    if xuenOrConduit == INVOKE_XUEN and IsOffCooldown(INVOKE_XUEN) then
        local pick = Pick(INVOKE_XUEN)
        if pick then return pick, "O1" end
    end
    if not zenithUp and SafeToSpendZenithCharge(xuenRemaining) then
        local pick = Pick(ZENITH_BUFF)
        if pick then return pick, "O2" end
    end

    if IsHeartOfJadeSerpentEndingSoon() and IsOffCooldown(FISTS_OF_FURY) and chi >= fofCost then
        local pick = Pick(FISTS_OF_FURY)
        if pick then return pick, "A1" end
    end
    -- Same combo-finisher gate as the ST list's Whirling Dragon Punch rule --
    -- it only works once both Fists of Fury and the kick are on cooldown.
    local wdpUsable = IsTalented(WHIRLING_DRAGON_PUNCH) and not IsOffCooldown(FISTS_OF_FURY)
        and not IsOffCooldown(risingSunKick) and IsOffCooldown(WHIRLING_DRAGON_PUNCH) and xuenCdLong
    if not jadeSerpentUp and wdpUsable then
        local pick = Pick(WHIRLING_DRAGON_PUNCH)
        if pick then return pick, "A2" end
    end
    if not jadeSerpentUp and IsTalented(STRIKE_OF_THE_WINDLORD)
        and IsOffCooldown(STRIKE_OF_THE_WINDLORD) and xuenCdLong then
        local pick = Pick(STRIKE_OF_THE_WINDLORD)
        if pick then return pick, "A3" end
    end
    if not jadeSerpentUp and xuenOrConduit == CELESTIAL_CONDUIT and IsOffCooldown(xuenOrConduit) then
        local pick = Pick(xuenOrConduit)
        if pick then return pick, "A4" end
    end
    if zenithUp and HasZenithStompCharge()
        and (chi <= 4 or IsZenithAlmostOver() or IsChanneling(CELESTIAL_CONDUIT)) then
        local pick = Pick(ZENITH_STOMP)
        if pick then return pick, "A6" end
    end
    if chi < fofCost then
        local pick = Pick(TIGER_PALM)
        if pick then return pick, "A7" end
    end
    if IsOffCooldown(FISTS_OF_FURY) and chi >= fofCost then
        local pick = Pick(FISTS_OF_FURY)
        if pick then return pick, "A8" end
    end
    if HasUnbrokenRhythm() then
        local pick = Pick(SPINNING_CRANE_KICK)
        if pick then return pick, "A9" end
    end
    if not IsOffCooldown(FISTS_OF_FURY) and IsOffCooldown(risingSunKick) then
        local pick = Pick(risingSunKick)
        if pick then return pick, "A10" end
    end
    if risingSunKick == RUSHING_WIND_KICK and IsOffCooldown(risingSunKick) and not HasUnbrokenRhythm() then
        local pick = Pick(risingSunKick)
        if pick then return pick, "A11" end
    end
    if risingSunKick == RISING_SUN_KICK and IsOffCooldown(risingSunKick)
        and jadeSerpentUp and not HasUnbrokenRhythm() then
        local pick = Pick(risingSunKick)
        if pick then return pick, "A12" end
    end
    if IsComboBreakerDumpReady() then
        local pick = Pick(BLACKOUT_KICK)
        if pick then return pick, "A13" end
    end
    if IsDanceOfChiJiDumpReady() then
        local pick = Pick(SPINNING_CRANE_KICK)
        if pick then return pick, "A14" end
    end
    if zenithUp and meleeCount >= 5 then
        local pick = Pick(SPINNING_CRANE_KICK)
        if pick then return pick, "A15" end
    end
    if risingSunKick == RISING_SUN_KICK and IsOffCooldown(risingSunKick)
        and (HasBloodlust() or zenithUp) and not HasUnbrokenRhythm() then
        local pick = Pick(risingSunKick)
        if pick then return pick, "A16" end
    end
    if IsTalented(OBSIDIAN_SPIRAL_TALENT) and zenithUp and not IsOffCooldown(risingSunKick) then
        local pick = Pick(BLACKOUT_KICK)
        if pick then return pick, "A17" end
    end
    do
        local pick = Pick(SPINNING_CRANE_KICK)
        if pick then return pick, "A18" end
    end
    if IsTalented(SLICING_WINDS) and IsOffCooldown(SLICING_WINDS) then
        local pick = Pick(SLICING_WINDS)
        if pick then return pick, "A19" end
    end
    if HasComboBreaker() then
        local pick = Pick(BLACKOUT_KICK)
        if pick then return pick, "A20" end
    end
    if chi <= 4 and not zenithUp then
        local pick = Pick(TIGER_PALM)
        if pick then return pick, "A21" end
    end
    if IsTalented(SHADOWBOXING_TREADS_TALENT) then
        local pick = Pick(BLACKOUT_KICK)
        if pick then return pick, "A22" end
    end
    if IsOffCooldown(risingSunKick) then
        local pick = Pick(risingSunKick)
        if pick then return pick, "A23" end
    end
    if ns.lastCastSpellID == BLACKOUT_KICK then return TIGER_PALM, "A24" end
    return BLACKOUT_KICK, "A24"
end

-- Dispatcher: more than 1 melee target routes to the AOE list, else ST.
-- Computed once and threaded through so the AOE list never re-scans plates.
local function EvaluateExpected()
    local meleeCount = ns.GetTargetCount()
    if meleeCount > 1 then return EvaluateExpectedAOE(meleeCount) end
    return EvaluateExpectedST()
end

-- Speaks every report while Chi stays at/below the threshold, not just once.
-- Skipped for Tiger Palm itself -- that cast is already generating Chi.
-- Muted for now -- /apl chi toggles it back on.
local CHI_ALERT_ENABLED = false
local function CheckChiAlert(spellID)
    if CHI_ALERT_ENABLED and spellID ~= TIGER_PALM and GetChi() <= 2 then SpeakAlertText("Chi") end
end

-- TTS alias map for the Suggestion Widget: short spoken name per spell.
-- Spells without an entry stay silent for now -- per-spell alias config
-- (enable/disable, custom text) comes later.
local SUGGEST_TTS_ALIAS = {
    [TIGER_PALM] = "Palm",
    [FISTS_OF_FURY] = "Fists",
    [INVOKE_XUEN] = "Xeun",
    [CELESTIAL_CONDUIT] = "Conduit",
    [BLACKOUT_KICK] = "Kick",
    [SPINNING_CRANE_KICK] = "Spin",
    [RISING_SUN_KICK] = "Sun",
    [RUSHING_WIND_KICK] = "Wind",
    [WHIRLING_DRAGON_PUNCH] = "Dragon",
    [ZENITH_BUFF] = "Zenith",
    [ZENITH_STOMP] = "Stomp",
}

-- Debug prefix: [U]nbroken Rhythm, current [Chi], [X]uen due <10s, [H]eart of
-- the Jade Serpent, [Z]enith active -- all brackets always shown, empty when false.
local function BuildDebugPrefix()
    local xuenRemaining = TimeUntilReady(INVOKE_XUEN)
    local xuenSoon = xuenRemaining ~= nil and xuenRemaining <= 10
    return "[" .. (HasUnbrokenRhythm() and "U" or "") .. "]"
        .. "[" .. GetChi() .. "]"
        .. "[" .. (xuenSoon and "X" or "") .. "]"
        .. "[" .. (HasHeartOfJadeSerpent() and "H" or "") .. "]"
        .. "[" .. (HasZenith() and "Z" or "") .. "]"
end

-- Self-tracked clocks (Xuen/Zenith/HotJS) reflect real game state the
-- instant a cast lands, regardless of combat -- precasting Xuen/Zenith/Tiger
-- Palm right before a pull is a normal opener, and gating these behind
-- InCombatLockdown() left every self-tracked clock wrong (no baseline) for
-- the fight's entire opening window whenever that happened.
local function OnCast(spellID)
    if spellID == INVOKE_XUEN then RecordSelfTrackedCast(spellID) end
    -- ZENITH_BUFF (1249625) only ever fires without the Stomp-charges talent
    -- (no ambiguity possible there, since Stomp doesn't exist to share the
    -- id); ZENITH_STOMP (1272696) covers every press once that talent is
    -- active, build and spend alike -- see RecordZenithOrStompCast.
    if spellID == ZENITH_BUFF then RecordZenithBuffCast(); ResetZenithStompCharges(); RecordHotJSFromZenith() end
    if spellID == ZENITH_STOMP then RecordZenithOrStompCast() end
    if spellID == WHIRLING_DRAGON_PUNCH or spellID == CELESTIAL_CONDUIT then RecordHotJSFromWdpOrConduit() end
    if spellID == BLACKOUT_KICK then ConsumeProcStack(_comboBreakerState) end
    if spellID == SPINNING_CRANE_KICK then ConsumeProcStack(_danceOfChiJiState) end
end

-- The only event-driven moment a new proc stack (or a fully-dropped buff)
-- can be noticed, since there's no cast to hook for an RNG proc landing.
local function OnAura()
    UpdateProcStacks(COMBO_BREAKER_BUFF, _comboBreakerState)
    UpdateProcStacks(DANCE_OF_CHI_JI_BUFF, _danceOfChiJiState)
end

local function OnReset()
    _comboBreakerState.stacks, _comboBreakerState.expiresAt = 0, nil
    _danceOfChiJiState.stacks, _danceOfChiJiState.expiresAt = 0, nil
end

ns.RegisterSpec({
    specID = WINDWALKER_SPEC_ID,
    rangeSpellID = TIGER_PALM,
    Evaluate = EvaluateExpected,
    OnCast = OnCast,
    OnCombatCast = CheckChiAlert,
    OnAura = OnAura,
    OnReset = OnReset,
    DebugPrefix = BuildDebugPrefix,
    ttsAlias = SUGGEST_TTS_ALIAS,
})

-------------------------------------------------------------------------------
--  Debug slash commands
-------------------------------------------------------------------------------
ns.slashCommands.chi = function()
    CHI_ALERT_ENABLED = not CHI_ALERT_ENABLED
    print("APL for EUI: Chi TTS alert " .. (CHI_ALERT_ENABLED and "enabled" or "disabled") .. ".")
end

-- Dumps the self-tracked Zenith/Zenith Stomp state so a live mismatch
-- against reality is directly visible, not guessed at.
ns.slashCommands.zenith = function()
    local expiresIn = _zenithBuffExpiresAt and (_zenithBuffExpiresAt - GetTime())
    print(string.format(
        "APL debug: HasZenith()=%s chargesRemaining=%d buffExpiresIn=%s almostOver=%s chi=%d",
        tostring(HasZenith()), _zenithStompChargesRemaining,
        expiresIn and string.format("%.1f", expiresIn) or "nil",
        tostring(IsZenithAlmostOver()), GetChi()))
    print("APL debug: Zenith (builder) chargesAvailable=" .. GetZenithChargesAvailable())
end

-- Dumps the self-tracked Combo Breaker/Dance of Chi-Ji proc-stack state and
-- a full breakdown of the applications read (every step: raw fields,
-- secrecy, pcall outcome), all on ONE line per buff so nothing gets lost
-- copying from a scrolled chat frame.
ns.slashCommands.stacks = function()
    local function Dump(name, spellID, state)
        local item = FindCooldownViewerItemForSpell(spellID)
        local apps = item and ReadProcApplications(item)
        local dumpReady = IsProcDumpReady(state) -- runs EnsureProcTimer first
        local expiresIn = state.expiresAt and (state.expiresAt - GetTime())
        local iid, unit, ad, iidSecret, ok, data
        if item then
            iid, unit, ad = item.auraInstanceID, item.auraDataUnit, item.auraDataCached
            iidSecret = issecretvalue and iid ~= nil and issecretvalue(iid)
            if iid and unit and not iidSecret then
                ok, data = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, iid)
            end
        end
        print(string.format(
            "APL debug: %s stacks=%d rawApplications=%s expiresIn=%s dumpReady=%s | "
            .. "iid=%s(secret=%s) unit=%s cachedAd=%s cachedApps=%s pcallOk=%s pcallData=%s pcallApps=%s",
            name, state.stacks, tostring(apps),
            expiresIn and string.format("%.1f", expiresIn) or "nil",
            tostring(dumpReady),
            tostring(iid), tostring(iidSecret), tostring(unit),
            tostring(ad ~= nil), tostring(ad and ad.applications),
            tostring(ok), tostring(data ~= nil), tostring(data and data.applications)))
    end
    Dump("ComboBreaker", COMBO_BREAKER_BUFF, _comboBreakerState)
    Dump("DanceOfChiJi", DANCE_OF_CHI_JI_BUFF, _danceOfChiJiState)
end
