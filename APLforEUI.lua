local ADDON_NAME, ns = ...

-------------------------------------------------------------------------------
--  Proof of concept: simplified Windwalker Monk test APL (NOT a real rotation).
--  Reports EVERY successful player cast against the APL's current top pick --
--  anything outside the test APL's 4 spells is unexpected by definition, so
--  nothing is filtered by "is this spell in the APL". Event handling mirrors
--  EllesmereUIDamageMeters_SpellHistory.lua (EUI's own cast tracker, already
--  proven accurate) instead of reinventing it.
-------------------------------------------------------------------------------
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

-- Player-castable lust spells (mirrors EllesmereUIQoL_Bloodlust.lua's
-- LUST_SPELLS) -- checked as buffs on the player, not the sated lockout.
local LUST_BUFFS = {
    2825,    -- Bloodlust
    32182,   -- Heroism
    80353,   -- Time Warp
    390386,  -- Fury of the Aspects
    272678,  -- Primal Rage
}

local ZENITH_STOMP_CAST_TIME = 3  -- seconds per charge, for "almost over" (see IsZenithAlmostOver)
local ZENITH_BUFF_DURATION = 20  -- seconds; the buff window, NOT the 90s charge recharge

-- Squashed for now (more debug coming later) -- stats/TTS/broker keep running
-- regardless, this only silences the chat print lines. /apl chat toggles it.
local CHAT_OUTPUT_ENABLED = false

-- Resolve a base spell to its currently active override (e.g. Rising Sun Kick
-- -> Rushing Wind Kick when the replacing talent is active).
local function ResolveOverride(spellID)
    if C_Spell and C_Spell.GetOverrideSpell then
        local ov = C_Spell.GetOverrideSpell(spellID)
        if ov and ov ~= 0 and ov ~= spellID then return ov end
    end
    return spellID
end

local _spellNameCache = {}
local function SpellName(spellID)
    local name = _spellNameCache[spellID]
    if name then return name end
    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
    name = (info and info.name) or ("Spell " .. spellID)
    _spellNameCache[spellID] = name
    return name
end

-- A resolvable spell has real info behind it; an echo/tick id that slips past
-- the known-spell filter still won't resolve, matching EUI's own skip.
local function SpellResolvable(spellID)
    return (C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)) ~= nil
end

-- startTime/duration on the cooldown table go secret during real M+/raid
-- combat and cannot be compared at all; isActive/isOnGCD (and GetSpellCharges's
-- isActive) stay clean bools even then, per EUI's own CDM (CdReadyIsReady in
-- EUI_CDM_HookIconWatch.lua) -- mirror that instead of touching the numbers.
local function IsOffCooldown(spellID)
    local ci = C_Spell and C_Spell.GetSpellCharges and C_Spell.GetSpellCharges(spellID)
    if ci and (ci.maxCharges or 0) > 1 then
        return not ci.isActive
    end
    local cd = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(spellID)
    if not cd then return true end
    return not (cd.isActive and not cd.isOnGCD)
end

local function GetChi()
    return UnitPower("player", Enum.PowerType.Chi) or 0
end

local function IsTalented(spellID)
    if C_SpellBook and C_SpellBook.IsSpellKnown then return C_SpellBook.IsSpellKnown(spellID) == true end
    return IsPlayerSpell(spellID) == true
end

-- No direct "enemies in range" API exists, so this infers it the same way
-- EUI's own EllesmereUI_Range.lua does for single-target range: per-nameplate
-- IsSpellInRange against a known melee-range spell, counted up. Plain booleans
-- the whole way, never secret.
local function GetMeleeTargetCount()
    local count = 0
    local plates = C_NamePlate and C_NamePlate.GetNamePlates and C_NamePlate.GetNamePlates(issecure())
    if not plates then return count end
    for _, plate in ipairs(plates) do
        local unit = plate.namePlateUnitToken or plate.unitToken
        if unit and UnitCanAttack("player", unit) and not UnitIsDead(unit) then
            local inRange = C_Spell and C_Spell.IsSpellInRange and C_Spell.IsSpellInRange(TIGER_PALM, unit)
            if inRange then count = count + 1 end
        end
    end
    return count
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

-- Blizzard's own Cooldown Viewer (Blizzard_CooldownViewer) item frames expose
-- a derived "is this aura present" signal (auraInstanceID) as a plain field,
-- stamped on by Blizzard's own privileged code -- never the raw secret aura
-- itself. This is the exact mechanism EUI's own Cooldown Manager relies on
-- for buff-bar glows, used here for any buff whose aura data goes dark to
-- regular addon code in real combat.
local function FindCooldownViewerItemForSpell(spellID)
    for _, viewerName in ipairs({ "BuffIconCooldownViewer", "BuffBarCooldownViewer" }) do
        local viewer = _G[viewerName]
        if viewer and viewer.GetItemFrames then
            for _, item in ipairs(viewer:GetItemFrames()) do
                if item.GetBaseSpellID and item:GetBaseSpellID() == spellID then
                    return item
                end
            end
        end
    end
    return nil
end

local function IsCooldownViewerAuraActive(spellID)
    local item = FindCooldownViewerItemForSpell(spellID)
    return item ~= nil and item:IsShown() and item.GetAuraSpellInstanceID
        and item:GetAuraSpellInstanceID() ~= nil
end

-- Tries the Cooldown Viewer signal first (reliable in real combat, but only
-- covers spells in the spec's tracked-buff set); falls back to the direct
-- aura read (fine outside restricted combat, or for untracked buffs).
local function HasBuff(spellID)
    if IsCooldownViewerAuraActive(spellID) then return true end
    return C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID
        and C_UnitAuras.GetPlayerAuraBySpellID(spellID) ~= nil
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

local function HasBloodlust()
    for _, sid in ipairs(LUST_BUFFS) do
        if HasBuff(sid) then return true end
    end
    return false
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

-- Lightweight "what are we channeling right now" state, decoupled from the
-- cast-report dedup machinery below -- just an on/off flag per active channel.
local _currentChannelSpellID
local function IsChanneling(spellID) return _currentChannelSpellID == spellID end

-- Resolved spell ID of the last successful cast. Combo Strikes punishes
-- repeating the same ability back-to-back, so the APL must never recommend
-- a repeat of this -- set after every report, never inside EvaluateExpected.
local lastCastSpellID

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

    local function Pick(spellID)
        if spellID == lastCastSpellID then return nil end
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
    if lastCastSpellID == BLACKOUT_KICK then return TIGER_PALM, 19 end
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
        if spellID == lastCastSpellID then return nil end
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
    if lastCastSpellID == BLACKOUT_KICK then return TIGER_PALM, "A24" end
    return BLACKOUT_KICK, "A24"
end

-- Dispatcher: more than 1 melee target routes to the AOE list, else ST.
-- Computed once and threaded through so the AOE list never re-scans plates.
local function EvaluateExpected()
    local meleeCount = GetMeleeTargetCount()
    if meleeCount > 1 then return EvaluateExpectedAOE(meleeCount) end
    return EvaluateExpectedST()
end

-- EvaluateExpected returns (spellID, step); wrap both into one value so it can
-- be stored/passed through the castGUID-keyed tables below without a second
-- parallel table.
local function SnapshotExpected()
    local spellID, step = EvaluateExpected()
    return { spellID = spellID, step = step }
end

local function IsWindwalker()
    local spec = GetSpecialization and GetSpecialization()
    local specID = spec and GetSpecializationInfo(spec)
    return specID == WINDWALKER_SPEC_ID
end

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
    if _glowInCombat and IsWindwalker() then spellID = EvaluateExpected() end
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

-- Echo guard state for ReportCast (see comment there). Declared before the
-- function so it closes over these locals, not nil globals of the same name.
local _lastReportedSpellID, _lastReportedTime = nil, 0
local ECHO_WINDOW = 0.3

-- Text-to-speech, local-only playback. Argument order on live clients is
-- (voiceID, text, destination, volume, interrupt); destination 1 = local.
-- Silently no-ops if TTS isn't available (mirrors EllesmereUIQoL_MovementAlert.lua).
local function SpeakAlertText(text)
    if not (C_VoiceChat and C_VoiceChat.SpeakText) then return end
    pcall(C_VoiceChat.SpeakText, 0, text, 1, 100, true)
end

-- Speaks every report while Chi stays at/below the threshold, not just once.
-- Skipped for Tiger Palm itself -- that cast is already generating Chi.
-- Muted for now -- /apl chi toggles it back on.
local CHI_ALERT_ENABLED = false
local function CheckChiAlert(spellID)
    if CHI_ALERT_ENABLED and spellID ~= TIGER_PALM and GetChi() <= 2 then SpeakAlertText("Chi") end
end

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
local function BuildStatsSummary()
    local total, pct, mastery = ComputeStats()
    local label = GetMeleeTargetCount() > 1 and "AOE" or "ST"
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
    local label, total, pct, mastery, compliant = BuildStatsSummary()
    -- White until the first cast is recorded; green/red by the LAST cast's
    -- compliance after that. Note: EUI's Broker Plugin block strips embedded
    -- color codes unless "Strip Colors" is turned off on that block.
    local colorCode = "|cffffffff"
    if compliant == true then colorCode = "|cff00ff00"
    elseif compliant == false then colorCode = "|cffff0000" end
    _brokerObj.text = label .. ": " .. total .. "/" .. colorCode .. pct .. "%|r/" .. mastery
end

-------------------------------------------------------------------------------
--  Standalone on-screen display: a small movable/lockable text frame showing
--  the same ST/AOE stats, mirroring EUI's own Standalone Combat Timer UX
--  (shift+click to drag, Lock Position & Disable Click, Show Out of Combat).
-------------------------------------------------------------------------------
APLforEUIDB = APLforEUIDB or {}
local function DB()
    return APLforEUIDB
end

local _standaloneFrame, _standaloneFS, _standaloneBG, _standaloneBorder

-- Font path resolution mirrors GetSATimerFontOverride in EllesmereUIDamageMeters.lua:
-- "__global"/nil falls back to EUI's own current global font; a specific picked font
-- resolves through the same public EllesmereUI.ResolveFontName used there.
local function GetStandaloneFontPath()
    local key = DB().standaloneFont
    if key and key ~= "__global" and EllesmereUI and EllesmereUI.ResolveFontName then
        local path = EllesmereUI.ResolveFontName(key)
        if path and path ~= "" then return path end
    end
    if EllesmereUI and EllesmereUI.GetFontPath then return EllesmereUI.GetFontPath() end
    return STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
end

local function GetStandaloneOutlineFlag()
    local outline = DB().standaloneOutline or "INHERIT"
    if outline == "NONE" or outline == "INHERIT" then return "" end
    if outline == "THICKOUTLINE" then return "THICKOUTLINE" end
    return "OUTLINE"
end

-- Shrinks a single-line FontString's font size (down to a floor) so its
-- rendered text never overflows a given max width -- restores the
-- configured base size first, so a later shorter string isn't stuck shrunk
-- from an earlier long one.
-- Truncates a single-line FontString's text (font size stays fixed at
-- whatever the caller already set) so it never overflows a given max width
-- -- cuts from the end and appends "..." once the full text no longer fits.
-- fullText is the UNtruncated intended text, stored by the caller, so a
-- later width/style change can always re-truncate from the real text
-- instead of compounding truncation on an already-cut string.
local function TruncateFontStringText(fs, fullText, maxWidth)
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

local function ApplyStandaloneStyle()
    if not _standaloneFrame or not _standaloneFS then return end
    local db = DB()
    _standaloneFrame:SetFrameStrata(db.standaloneStrata or "HIGH")
    _standaloneFrame:SetSize(math.max(60, db.standaloneWidth or 160), math.max(16, db.standaloneHeight or 20))

    _standaloneFS:SetFont(GetStandaloneFontPath(), db.standaloneSize or 14, GetStandaloneOutlineFlag())
    local c = db.standaloneColor or { r = 1, g = 1, b = 1 }
    _standaloneFS:SetTextColor(c.r or 1, c.g or 1, c.b or 1, 1)
    _standaloneFS:SetJustifyH(db.standaloneAlign or "CENTER")

    if _standaloneBG then
        local bg = db.standaloneBackgroundColor or { r = 0, g = 0, b = 0, a = 0 }
        _standaloneBG:SetColorTexture(bg.r or 0, bg.g or 0, bg.b or 0, bg.a or 0)
    end
    if _standaloneBorder then
        local PP = EllesmereUI and EllesmereUI.PP
        local bc = db.standaloneBorderColor or { r = 0, g = 0, b = 0, a = 1 }
        local borderSize = math.max(0, math.floor((db.standaloneBorderSize or 0) + 0.5))
        if borderSize > 0 and PP and PP.UpdateBorder then
            PP.UpdateBorder(_standaloneBorder, borderSize, bc.r or 0, bc.g or 0, bc.b or 0, bc.a == nil and 1 or bc.a)
            _standaloneBorder:Show()
        else
            _standaloneBorder:Hide()
        end
    end
end

local function RepositionStandalone()
    if not _standaloneFrame then return end
    local db = DB()
    _standaloneFrame:ClearAllPoints()
    local pos = db.standalonePos
    if pos and pos.x and pos.y then
        _standaloneFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos.x, pos.y)
    else
        _standaloneFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 150)
    end
    local locked = db.standaloneLocked == true
    _standaloneFrame:SetMovable(not locked)
    _standaloneFrame:EnableMouse(not locked)
end

local function ColorHex(c)
    local r = math.floor((c and c.r or 1) * 255 + 0.5)
    local g = math.floor((c and c.g or 1) * 255 + 0.5)
    local b = math.floor((c and c.b or 1) * 255 + 0.5)
    return string.format("|cff%02x%02x%02x", r, g, b)
end

local function UpdateStandaloneText()
    if not _standaloneFS then return end
    local label, total, pct, mastery, compliant = BuildStatsSummary()
    local db = DB()
    -- The percentage reflects the LAST cast's compliance: Fail Color when it
    -- missed, Text Color (Pass Color) otherwise -- including before any cast
    -- has been recorded yet.
    local color = compliant == false and (db.standaloneFailColor or { r = 1, g = 0, b = 0 })
        or (db.standaloneColor or { r = 1, g = 1, b = 1 })
    -- Not truncated like the suggestion widget: this string embeds a color
    -- escape code (|cff.../|r) that a naive character-cut could slice
    -- mid-sequence and corrupt. It's short enough in practice not to need it.
    _standaloneFS:SetText(label .. ": " .. total .. "/" .. ColorHex(color) .. pct .. "%|r/" .. mastery)
end

-- Visible while in combat; out of combat it honors Show Out of Combat
-- (keeping the last computed stats on screen instead of clearing them).
local function ApplyStandaloneVisibility()
    if not _standaloneFrame then return end
    local db = DB()
    if not db.standaloneEnabled or not IsWindwalker() then
        _standaloneFrame:Hide()
        return
    end
    if InCombatLockdown() or db.standaloneShowOOC then
        _standaloneFrame:Show()
    else
        _standaloneFrame:Hide()
    end
end

local function CreateStandaloneFrame()
    if _standaloneFrame then return end
    _standaloneFrame = CreateFrame("Frame", "APLforEUIStandaloneDisplay", UIParent)
    _standaloneFrame:SetSize(160, 20)
    _standaloneFrame:SetClampedToScreen(true)
    _standaloneFrame:SetFrameStrata("HIGH")
    _standaloneFrame:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" and IsShiftKeyDown() and not DB().standaloneLocked then
            self:StartMoving()
        end
    end)
    _standaloneFrame:SetScript("OnMouseUp", function(self)
        self:StopMovingOrSizing()
        local left, top = self:GetLeft(), self:GetTop()
        if left and top then DB().standalonePos = { x = left, y = top } end
    end)

    _standaloneBG = _standaloneFrame:CreateTexture(nil, "BACKGROUND")
    _standaloneBG:SetAllPoints()

    _standaloneBorder = CreateFrame("Frame", nil, _standaloneFrame)
    _standaloneBorder:SetAllPoints(_standaloneFrame)
    _standaloneBorder:SetFrameLevel(_standaloneFrame:GetFrameLevel() + 5)
    local PP = EllesmereUI and EllesmereUI.PP
    if PP and PP.CreateBorder then PP.CreateBorder(_standaloneBorder, 0, 0, 0, 1, 1) end

    _standaloneFS = _standaloneFrame:CreateFontString(nil, "OVERLAY")
    _standaloneFS:SetAllPoints()
    ApplyStandaloneStyle()
    RepositionStandalone()
    UpdateStandaloneText()
    _standaloneFrame:Hide()
end

local function ApplyStandalone()
    local db = DB()
    if db.standaloneEnabled then
        if not _standaloneFrame then CreateStandaloneFrame() end
        ApplyStandaloneStyle()
        RepositionStandalone()
        UpdateStandaloneText()
    end
    ApplyStandaloneVisibility()
end

-------------------------------------------------------------------------------
--  Suggestion widget: a second movable/lockable display showing the LIVE
--  suggested spell (icon + name), re-evaluated on a ticker so it follows
--  cooldowns/resources/auras changing between casts, not just at cast time.
-------------------------------------------------------------------------------
local _suggestFrame, _suggestIcon, _suggestFS, _suggestBG, _suggestBorder
local _suggestTicker
local _lastSuggestedSpellID, _lastSuggestedStep
-- One shared deadline covers both suppression windows: a cast resets it to
-- now + half of Global Suppression (never stacking -- a later cast always
-- wins, it doesn't extend on top of an existing one), and the full Global
-- Suppression value resets it again every time the displayed suggestion
-- actually changes, holding a newly shown pick stable before the next one
-- is allowed to replace it. Declared here, ahead of ReportCast, purely so
-- UpdateSuggestWidget's closure can see it without a forward-reference (Lua
-- locals are only visible to closures defined AFTER their declaration).
local _suggestSuppressUntil = 0
local SUGGEST_GLOBAL_SUPPRESSION_DEFAULT = 0.3
local SUGGEST_POST_CAST_FRACTION = 0.5

local function GetSuggestGlobalSuppression()
    return DB().suggestGlobalSuppression or SUGGEST_GLOBAL_SUPPRESSION_DEFAULT
end

local function GetSuggestFontPath()
    local key = DB().suggestFont
    if key and key ~= "__global" and EllesmereUI and EllesmereUI.ResolveFontName then
        local path = EllesmereUI.ResolveFontName(key)
        if path and path ~= "" then return path end
    end
    if EllesmereUI and EllesmereUI.GetFontPath then return EllesmereUI.GetFontPath() end
    return STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
end

local function GetSuggestOutlineFlag()
    local outline = DB().suggestOutline or "INHERIT"
    if outline == "NONE" or outline == "INHERIT" then return "" end
    if outline == "THICKOUTLINE" then return "THICKOUTLINE" end
    return "OUTLINE"
end

-- Icon renders at its full configured size, unclamped -- it sits OUTSIDE the
-- bordered text box (see LayoutSuggestWidget), so it never competes with the
-- frame/border for space.
local function GetSuggestIconSize()
    return math.max(8, DB().suggestIconSize or 24)
end

-- Icon anchored OUTSIDE the text's bordered frame, on whichever side is
-- configured -- re-anchored from scratch since the side (and whether the
-- icon shows at all) can change live.
local function LayoutSuggestWidget()
    if not _suggestFrame then return end
    local db = DB()
    local showIcon = db.suggestShowIcon ~= false
    _suggestIcon:ClearAllPoints()
    if not showIcon then
        _suggestIcon:Hide()
        return
    end
    local iconSize = GetSuggestIconSize()
    _suggestIcon:Show()
    _suggestIcon:SetSize(iconSize, iconSize)
    local anchor = db.suggestIconAnchor or "LEFT"
    local gap = 4
    if anchor == "RIGHT" then
        _suggestIcon:SetPoint("LEFT", _suggestFrame, "RIGHT", gap, 0)
    elseif anchor == "TOP" then
        _suggestIcon:SetPoint("BOTTOM", _suggestFrame, "TOP", 0, gap)
    elseif anchor == "BOTTOM" then
        _suggestIcon:SetPoint("TOP", _suggestFrame, "BOTTOM", 0, -gap)
    else -- LEFT
        _suggestIcon:SetPoint("RIGHT", _suggestFrame, "LEFT", -gap, 0)
    end
end

-- Available width for the suggestion text -- the icon no longer shares the
-- frame's space (it's anchored outside it), so this is just the frame width.
local function GetSuggestTextMaxWidth()
    if not _suggestFrame then return nil end
    return _suggestFrame:GetWidth() - 6
end

local function ApplySuggestStyle()
    if not _suggestFrame or not _suggestFS then return end
    local db = DB()
    _suggestFrame:SetFrameStrata(db.suggestStrata or "HIGH")
    _suggestFrame:SetSize(math.max(40, db.suggestWidth or 160), math.max(16, db.suggestHeight or 32))

    _suggestFS:SetFont(GetSuggestFontPath(), db.suggestSize or 14, GetSuggestOutlineFlag())
    TruncateFontStringText(_suggestFS, _suggestFS._fullText or "", GetSuggestTextMaxWidth())
    local c = db.suggestTextColor or { r = 1, g = 1, b = 1 }
    _suggestFS:SetTextColor(c.r or 1, c.g or 1, c.b or 1, 1)

    if _suggestBG then
        local bg = db.suggestBackgroundColor or { r = 0, g = 0, b = 0, a = 0 }
        _suggestBG:SetColorTexture(bg.r or 0, bg.g or 0, bg.b or 0, bg.a or 0)
    end
    if _suggestBorder then
        local PP = EllesmereUI and EllesmereUI.PP
        local bc = db.suggestBorderColor or { r = 0, g = 0, b = 0, a = 1 }
        local borderSize = math.max(0, math.floor((db.suggestBorderSize or 0) + 0.5))
        if borderSize > 0 and PP and PP.UpdateBorder then
            PP.UpdateBorder(_suggestBorder, borderSize, bc.r or 0, bc.g or 0, bc.b or 0, bc.a == nil and 1 or bc.a)
            _suggestBorder:Show()
        else
            _suggestBorder:Hide()
        end
    end
    LayoutSuggestWidget()
end

local function RepositionSuggest()
    if not _suggestFrame then return end
    local db = DB()
    _suggestFrame:ClearAllPoints()
    local pos = db.suggestPos
    if pos and pos.x and pos.y then
        _suggestFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos.x, pos.y)
    else
        _suggestFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
    end
    local locked = db.suggestLocked == true
    _suggestFrame:SetMovable(not locked)
    _suggestFrame:EnableMouse(not locked)
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

-- /apl debug <step> watch list: TTS-announces whenever one of these specific
-- APL steps gets suggested, independent of the normal suggestion TTS alias
-- toggle -- for isolating exactly when a given rule fires without staring at
-- the widget. Keyed by the step's string form ("A13", "13", "O1") so ST's
-- plain-number steps and AOE's "A"-prefixed strings compare the same way.
local _debugWatchSteps = {}
local function NormalizeStepKey(step)
    if step == nil then return nil end
    return tostring(step):upper()
end

-- Pulls the live pick straight from the evaluator (not from cast reports), so
-- it tracks cooldowns/resources/auras changing between casts too.
local function UpdateSuggestWidget()
    if not _suggestFS or not _suggestIcon then return end
    if not IsWindwalker() then return end
    if GetTime() < _suggestSuppressUntil then return end
    local spellID, step = EvaluateExpected()
    if spellID == _lastSuggestedSpellID and step == _lastSuggestedStep then return end
    _lastSuggestedSpellID, _lastSuggestedStep = spellID, step
    _suggestSuppressUntil = GetTime() + GetSuggestGlobalSuppression()
    _suggestFS._fullText = (step and (step .. ": ") or "") .. SpellName(spellID)
    TruncateFontStringText(_suggestFS, _suggestFS._fullText, GetSuggestTextMaxWidth())
    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
    _suggestIcon:SetTexture(info and info.iconID)
    if DB().suggestTTSEnabled then
        local alias = SUGGEST_TTS_ALIAS[spellID]
        if alias then SpeakAlertText(alias) end
    end
    local stepKey = NormalizeStepKey(step)
    if stepKey and _debugWatchSteps[stepKey] then
        SpeakAlertText(stepKey)
    end
end

-- Visible while in combat; out of combat it honors Show Out of Combat. The
-- ticker only runs while shown, so there is zero background cost otherwise.
local function ApplySuggestVisibility()
    if not _suggestFrame then return end
    local db = DB()
    if not db.suggestEnabled or not IsWindwalker() then
        _suggestFrame:Hide()
        if _suggestTicker then _suggestTicker:Cancel(); _suggestTicker = nil end
        return
    end
    if InCombatLockdown() or db.suggestShowOOC then
        _suggestFrame:Show()
        if not _suggestTicker then
            _lastSuggestedSpellID, _lastSuggestedStep = nil, nil
            UpdateSuggestWidget()
            _suggestTicker = C_Timer.NewTicker(0.2, UpdateSuggestWidget)
        end
    else
        _suggestFrame:Hide()
        if _suggestTicker then _suggestTicker:Cancel(); _suggestTicker = nil end
    end
end

local function CreateSuggestFrame()
    if _suggestFrame then return end
    _suggestFrame = CreateFrame("Frame", "APLforEUISuggestionWidget", UIParent)
    _suggestFrame:SetSize(160, 32)
    _suggestFrame:SetClampedToScreen(true)
    _suggestFrame:SetFrameStrata("HIGH")
    _suggestFrame:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" and IsShiftKeyDown() and not DB().suggestLocked then
            self:StartMoving()
        end
    end)
    _suggestFrame:SetScript("OnMouseUp", function(self)
        self:StopMovingOrSizing()
        local left, top = self:GetLeft(), self:GetTop()
        if left and top then DB().suggestPos = { x = left, y = top } end
    end)

    _suggestBG = _suggestFrame:CreateTexture(nil, "BACKGROUND")
    _suggestBG:SetAllPoints()

    _suggestBorder = CreateFrame("Frame", nil, _suggestFrame)
    _suggestBorder:SetAllPoints(_suggestFrame)
    _suggestBorder:SetFrameLevel(_suggestFrame:GetFrameLevel() + 5)
    local PP = EllesmereUI and EllesmereUI.PP
    if PP and PP.CreateBorder then PP.CreateBorder(_suggestBorder, 0, 0, 0, 1, 1) end

    _suggestIcon = _suggestFrame:CreateTexture(nil, "ARTWORK")
    _suggestFS = _suggestFrame:CreateFontString(nil, "OVERLAY")
    _suggestFS:SetPoint("CENTER", _suggestFrame, "CENTER", 0, 0)

    ApplySuggestStyle()
    RepositionSuggest()
    _suggestFrame:Hide()
end

local function ApplySuggest()
    local db = DB()
    if db.suggestEnabled then
        if not _suggestFrame then CreateSuggestFrame() end
        ApplySuggestStyle()
        RepositionSuggest()
    end
    ApplySuggestVisibility()
end

local _standaloneCombatFrame = CreateFrame("Frame")
_standaloneCombatFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
_standaloneCombatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
_standaloneCombatFrame:SetScript("OnEvent", function()
    ApplyStandaloneVisibility()
    ApplySuggestVisibility()
end)

-- Registers our own section via EUI's sanctioned plugin API (PLUGINS_API.md)
-- -- never EUI internals. Runs standalone (OptionalDeps) if EUI isn't loaded.
local function BuildStatusWidgetPage(parent, yOffset)
    local W = EllesmereUI.Widgets
    local y = yOffset
    local _, h

    _, h = W:SectionHeader(parent, "STATUS WIDGET", y); y = y - h

    local function Cfg(k) return DB()[k] end
    local function Set(k, v) DB()[k] = v end

    -- Enabled (+ inline cog: font/size/outline/alignment/frame/
    -- background/border/strata) | Text Color (Pass/Fail swatches)
    local enabledRow
    enabledRow, h = W:DualRow(parent, y,
        { type = "toggle", text = "Enabled",
          getValue = function() return Cfg("standaloneEnabled") == true end,
          setValue = function(v)
              Set("standaloneEnabled", v)
              ApplyStandalone()
              EllesmereUI:RefreshPage()
          end },
        { type = "multiSwatch", text = "Text Color",
          disabled = function() return not Cfg("standaloneEnabled") end,
          disabledTooltip = "Enabled",
          swatches = {
              { tooltip = "Pass Color", hasAlpha = false,
                getValue = function()
                    local c = Cfg("standaloneColor") or { r = 1, g = 1, b = 1 }
                    return c.r, c.g, c.b
                end,
                setValue = function(r, g, b)
                    Set("standaloneColor", { r = r, g = g, b = b })
                    ApplyStandaloneStyle(); UpdateStandaloneText()
                end },
              { tooltip = "Fail Color", hasAlpha = false,
                getValue = function()
                    local c = Cfg("standaloneFailColor") or { r = 1, g = 0, b = 0 }
                    return c.r, c.g, c.b
                end,
                setValue = function(r, g, b)
                    Set("standaloneFailColor", { r = r, g = g, b = b })
                    UpdateStandaloneText()
                end },
          } })
    if not EllesmereUI._prebuilding then
        local rgn = enabledRow._leftRegion
        local fontValues, fontOrder = EllesmereUI.BuildFontDropdownData()
        EllesmereUI.BuildInlineCog(rgn, {
            title = "Status Widget Settings",
            minWidth = 300,
            rows = {
                { type = "dropdown", label = "Font",
                  values = fontValues, order = fontOrder,
                  get = function() return Cfg("standaloneFont") or "__global" end,
                  set = function(v) Set("standaloneFont", v); ApplyStandaloneStyle() end },
                { type = "slider", label = "Font Size", min = 8, max = 40, step = 1,
                  get = function() return Cfg("standaloneSize") or 14 end,
                  set = function(v) Set("standaloneSize", v); ApplyStandaloneStyle() end },
                { type = "dropdown", label = "Font Outline",
                  values = { INHERIT = "Default", NONE = "None", OUTLINE = "Thin", THICKOUTLINE = "Thick" },
                  order = { "INHERIT", "NONE", "OUTLINE", "THICKOUTLINE" },
                  get = function() return Cfg("standaloneOutline") or "INHERIT" end,
                  set = function(v) Set("standaloneOutline", v); ApplyStandaloneStyle() end },
                { type = "dropdown", label = "Alignment",
                  values = { LEFT = "Left", CENTER = "Center", RIGHT = "Right" },
                  order = { "LEFT", "CENTER", "RIGHT" },
                  get = function() return Cfg("standaloneAlign") or "CENTER" end,
                  set = function(v) Set("standaloneAlign", v); ApplyStandaloneStyle() end },
                { type = "slider", label = "Frame Width", min = 60, max = 300, step = 1,
                  get = function() return Cfg("standaloneWidth") or 160 end,
                  set = function(v) Set("standaloneWidth", v); ApplyStandaloneStyle() end },
                { type = "slider", label = "Frame Height", min = 16, max = 60, step = 1,
                  get = function() return Cfg("standaloneHeight") or 20 end,
                  set = function(v) Set("standaloneHeight", v); ApplyStandaloneStyle() end },
                { type = "colorpicker", label = "Background Color", hasAlpha = true,
                  get = function()
                      local c = Cfg("standaloneBackgroundColor") or { r = 0, g = 0, b = 0, a = 0 }
                      return c.r, c.g, c.b, c.a
                  end,
                  set = function(r, g, b, a)
                      Set("standaloneBackgroundColor", { r = r, g = g, b = b, a = a }); ApplyStandaloneStyle()
                  end },
                { type = "colorpicker", label = "Border Color", hasAlpha = true,
                  get = function()
                      local c = Cfg("standaloneBorderColor") or { r = 0, g = 0, b = 0, a = 1 }
                      return c.r, c.g, c.b, c.a
                  end,
                  set = function(r, g, b, a)
                      Set("standaloneBorderColor", { r = r, g = g, b = b, a = a }); ApplyStandaloneStyle()
                  end },
                { type = "slider", label = "Border Size", min = 0, max = 4, step = 1,
                  get = function() return Cfg("standaloneBorderSize") or 0 end,
                  set = function(v) Set("standaloneBorderSize", v); ApplyStandaloneStyle() end },
                { type = "dropdown", label = "Frame Strata",
                  values = EllesmereUI.FRAME_STRATA_LABELS,
                  order = EllesmereUI.FRAME_STRATA_ORDER_BASE,
                  get = function() return Cfg("standaloneStrata") or "HIGH" end,
                  set = function(v) Set("standaloneStrata", v); ApplyStandaloneStyle() end },
            },
            icon = EllesmereUI.RESIZE_ICON,
        })
    end
    y = y - h

    -- Lock Position & Disable Click | Show Out of Combat
    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Lock Position & Disable Click",
          disabled = function() return not Cfg("standaloneEnabled") end,
          disabledTooltip = "Enabled",
          tooltip = "Lock the display in place and make it click-through; no dragging and no mouse interaction until unlocked.",
          getValue = function() return Cfg("standaloneLocked") == true end,
          setValue = function(v)
              Set("standaloneLocked", v)
              RepositionStandalone()
          end },
        { type = "toggle", text = "Show Out of Combat",
          disabled = function() return not Cfg("standaloneEnabled") end,
          disabledTooltip = "Enabled",
          tooltip = "Keep the display visible out of combat, showing the last computed stats.",
          getValue = function() return Cfg("standaloneShowOOC") == true end,
          setValue = function(v)
              Set("standaloneShowOOC", v)
              ApplyStandaloneVisibility()
          end })
    y = y - h

    -- "Hold Shift+Click..." label, alone on its row.
    _, h = W:DualRow(parent, y,
        { type = "label", text = "Hold Shift+Click to Freely Move" },
        { type = "spacer" })
    y = y - h

    return math.abs(y)
end

local function BuildSuggestionWidgetPage(parent, yOffset)
    local W = EllesmereUI.Widgets
    local y = yOffset
    local _, h

    _, h = W:SectionHeader(parent, "SUGGESTION WIDGET", y); y = y - h

    local function Cfg(k) return DB()[k] end
    local function Set(k, v) DB()[k] = v end

    -- Enabled (+ inline cog: font/size/outline, icon show/size/anchor, frame,
    -- background/border/strata) | Text Color
    local enabledRow
    enabledRow, h = W:DualRow(parent, y,
        { type = "toggle", text = "Enabled",
          getValue = function() return Cfg("suggestEnabled") == true end,
          setValue = function(v)
              Set("suggestEnabled", v)
              ApplySuggest()
              EllesmereUI:RefreshPage()
          end },
        { type = "colorpicker", text = "Text Color", hasAlpha = false,
          disabled = function() return not Cfg("suggestEnabled") end,
          disabledTooltip = "Enabled",
          getValue = function()
              local c = Cfg("suggestTextColor") or { r = 1, g = 1, b = 1 }
              return c.r, c.g, c.b
          end,
          setValue = function(r, g, b)
              Set("suggestTextColor", { r = r, g = g, b = b })
              ApplySuggestStyle()
          end })
    if not EllesmereUI._prebuilding then
        local rgn = enabledRow._leftRegion
        local fontValues, fontOrder = EllesmereUI.BuildFontDropdownData()
        EllesmereUI.BuildInlineCog(rgn, {
            title = "Suggestion Widget Settings",
            minWidth = 300,
            rows = {
                { type = "dropdown", label = "Font",
                  values = fontValues, order = fontOrder,
                  get = function() return Cfg("suggestFont") or "__global" end,
                  set = function(v) Set("suggestFont", v); ApplySuggestStyle() end },
                { type = "slider", label = "Font Size", min = 8, max = 40, step = 1,
                  get = function() return Cfg("suggestSize") or 14 end,
                  set = function(v) Set("suggestSize", v); ApplySuggestStyle() end },
                { type = "dropdown", label = "Font Outline",
                  values = { INHERIT = "Default", NONE = "None", OUTLINE = "Thin", THICKOUTLINE = "Thick" },
                  order = { "INHERIT", "NONE", "OUTLINE", "THICKOUTLINE" },
                  get = function() return Cfg("suggestOutline") or "INHERIT" end,
                  set = function(v) Set("suggestOutline", v); ApplySuggestStyle() end },
                { type = "toggle", label = "Show Spell Icon",
                  get = function() return Cfg("suggestShowIcon") ~= false end,
                  set = function(v) Set("suggestShowIcon", v); ApplySuggestStyle() end },
                { type = "slider", label = "Icon Size", min = 8, max = 64, step = 1,
                  disabled = function() return Cfg("suggestShowIcon") == false end,
                  disabledTooltip = "Show Spell Icon",
                  get = function() return Cfg("suggestIconSize") or 24 end,
                  set = function(v) Set("suggestIconSize", v); ApplySuggestStyle() end },
                { type = "dropdown", label = "Icon Anchor",
                  disabled = function() return Cfg("suggestShowIcon") == false end,
                  disabledTooltip = "Show Spell Icon",
                  values = { LEFT = "Left", RIGHT = "Right", TOP = "Top", BOTTOM = "Bottom" },
                  order = { "LEFT", "RIGHT", "TOP", "BOTTOM" },
                  get = function() return Cfg("suggestIconAnchor") or "LEFT" end,
                  set = function(v) Set("suggestIconAnchor", v); ApplySuggestStyle() end },
                { type = "slider", label = "Frame Width", min = 40, max = 300, step = 1,
                  get = function() return Cfg("suggestWidth") or 160 end,
                  set = function(v) Set("suggestWidth", v); ApplySuggestStyle() end },
                { type = "slider", label = "Frame Height", min = 16, max = 80, step = 1,
                  get = function() return Cfg("suggestHeight") or 32 end,
                  set = function(v) Set("suggestHeight", v); ApplySuggestStyle() end },
                { type = "colorpicker", label = "Background Color", hasAlpha = true,
                  get = function()
                      local c = Cfg("suggestBackgroundColor") or { r = 0, g = 0, b = 0, a = 0 }
                      return c.r, c.g, c.b, c.a
                  end,
                  set = function(r, g, b, a)
                      Set("suggestBackgroundColor", { r = r, g = g, b = b, a = a }); ApplySuggestStyle()
                  end },
                { type = "colorpicker", label = "Border Color", hasAlpha = true,
                  get = function()
                      local c = Cfg("suggestBorderColor") or { r = 0, g = 0, b = 0, a = 1 }
                      return c.r, c.g, c.b, c.a
                  end,
                  set = function(r, g, b, a)
                      Set("suggestBorderColor", { r = r, g = g, b = b, a = a }); ApplySuggestStyle()
                  end },
                { type = "slider", label = "Border Size", min = 0, max = 4, step = 1,
                  get = function() return Cfg("suggestBorderSize") or 0 end,
                  set = function(v) Set("suggestBorderSize", v); ApplySuggestStyle() end },
                { type = "dropdown", label = "Frame Strata",
                  values = EllesmereUI.FRAME_STRATA_LABELS,
                  order = EllesmereUI.FRAME_STRATA_ORDER_BASE,
                  get = function() return Cfg("suggestStrata") or "HIGH" end,
                  set = function(v) Set("suggestStrata", v); ApplySuggestStyle() end },
            },
            icon = EllesmereUI.RESIZE_ICON,
        })
    end
    y = y - h

    -- Lock Position & Disable Click | Show Out of Combat
    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Lock Position & Disable Click",
          disabled = function() return not Cfg("suggestEnabled") end,
          disabledTooltip = "Enabled",
          tooltip = "Lock the display in place and make it click-through; no dragging and no mouse interaction until unlocked.",
          getValue = function() return Cfg("suggestLocked") == true end,
          setValue = function(v)
              Set("suggestLocked", v)
              RepositionSuggest()
          end },
        { type = "toggle", text = "Show Out of Combat",
          disabled = function() return not Cfg("suggestEnabled") end,
          disabledTooltip = "Enabled",
          tooltip = "Keep the display visible out of combat, showing the current live suggestion.",
          getValue = function() return Cfg("suggestShowOOC") == true end,
          setValue = function(v)
              Set("suggestShowOOC", v)
              ApplySuggestVisibility()
          end })
    y = y - h

    -- "Hold Shift+Click..." label | Enable TTS
    _, h = W:DualRow(parent, y,
        { type = "label", text = "Hold Shift+Click to Freely Move" },
        { type = "toggle", text = "Enable TTS",
          disabled = function() return not Cfg("suggestEnabled") end,
          disabledTooltip = "Enabled",
          tooltip = "Speaks a short name for the suggested spell whenever it changes. Only spells with a configured alias are spoken for now.",
          getValue = function() return Cfg("suggestTTSEnabled") == true end,
          setValue = function(v) Set("suggestTTSEnabled", v) end })
    y = y - h

    -- Global Suppression
    _, h = W:DualRow(parent, y,
        { type = "slider", text = "Global Suppression", min = 0.1, max = 1.0, step = 0.1,
          disabled = function() return not Cfg("suggestEnabled") end,
          disabledTooltip = "Enabled",
          tooltip = "Seconds the suggestion holds steady after a cast, and again after it changes -- a new cast always restarts the hold fresh rather than stacking.",
          getValue = function() return Cfg("suggestGlobalSuppression") or SUGGEST_GLOBAL_SUPPRESSION_DEFAULT end,
          setValue = function(v) Set("suggestGlobalSuppression", v) end },
        { type = "spacer" })
    y = y - h

    return math.abs(y)
end

if EllesmereUI and EllesmereUI.RegisterPlugin then
    EllesmereUI.RegisterPlugin("APLforEUI", {
        label = "APL for EUI",
        modules = {
            {
                key = "General",
                title = "Settings",
                description = "Standalone on-screen displays for the ST/AOE compliance stats and the live APL suggestion.",
                pages = { "Status Widget", "Suggestion Widget" },
                buildPage = function(pageName, parent, yOffset)
                    if pageName == "Suggestion Widget" then
                        return BuildSuggestionWidgetPage(parent, yOffset)
                    end
                    return BuildStatusWidgetPage(parent, yOffset)
                end,
            },
        },
    })
end

local function RecordStatsEntry(matched, brokeMastery)
    local now = GetTime()
    _recentReports[#_recentReports + 1] = { time = now, matched = matched, brokeMastery = brokeMastery }
    while _recentReports[1] and (now - _recentReports[1].time) > STATS_WINDOW do
        table.remove(_recentReports, 1)
    end
    UpdateBrokerText()
    UpdateStandaloneText()
end

local function BuildStatsPrefix()
    local total, pct, mastery = ComputeStats()
    -- "/" not "|": WoW chat treats a literal "|" as the start of an escape
    -- sequence (|cFFxxxxxx, |r, |H..|h..|h, |T..|t), corrupting the line.
    return "[" .. total .. "/" .. pct .. "%/" .. mastery .. "]"
end

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
    _suggestSuppressUntil = _lastReportedTime + GetSuggestGlobalSuppression() * SUGGEST_POST_CAST_FRACTION

    -- Self-tracked clocks (Xuen/Zenith/HotJS) and the Combo Strikes repeat
    -- guard (lastCastSpellID) reflect real game state the instant a cast
    -- lands, regardless of combat -- precasting Xuen/Zenith/Tiger Palm right
    -- before a pull is a normal opener, and gating these behind
    -- InCombatLockdown() left every self-tracked clock wrong (no baseline)
    -- for the fight's entire opening window whenever that happened.
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

    -- TEMP DEBUG: unconditional (not combat-gated) so the exact resolved
    -- spellID a cast reports as is visible even for precasts/dummy testing --
    -- remove once the Zenith cast-detection mismatch is confirmed/fixed.
    if CHAT_OUTPUT_ENABLED then
        print("APL debug: cast detected spellID=" .. spellID .. " (" .. SpellName(spellID) .. ")")
    end

    -- Only real rotation casts matter for compliance/mastery/Chi-alert
    -- tracking -- world/downtime casts between pulls would otherwise pollute
    -- the stats.
    local expectedSpellID = expected and expected.spellID
    local expectedStep = expected and expected.step
    local brokeMastery = spellID == lastCastSpellID
    if InCombatLockdown() then
        local matched = not brokeMastery and spellID == expectedSpellID
        RecordStatsEntry(matched, brokeMastery)
        CheckChiAlert(spellID)
        local prefix = "APL: " .. BuildStatsPrefix() .. " " .. BuildDebugPrefix() .. " "
        if CHAT_OUTPUT_ENABLED then
            if spellID == lastCastSpellID then
                print(prefix .. SpellName(spellID) .. " (Broke Mastery)")
            elseif spellID == expectedSpellID then
                print(prefix .. SpellName(spellID) .. " (step " .. tostring(expectedStep) .. ")")
            else
                print(prefix .. SpellName(spellID) .. " (Expected " .. SpellName(expectedSpellID)
                    .. ", step " .. tostring(expectedStep) .. ")")
            end
        end
    end
    lastCastSpellID = spellID
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

    -- Resyncs the proc-stack self-tracking against the live Cooldown
    -- Viewer signal -- the only event-driven moment a new stack (or a
    -- fully-dropped buff) can be noticed, since there's no cast to hook for
    -- an RNG proc landing.
    if event == "UNIT_AURA" then
        local updateInfo = ...
        UpdateProcStacks(COMBO_BREAKER_BUFF, _comboBreakerState, updateInfo)
        UpdateProcStacks(DANCE_OF_CHI_JI_BUFF, _danceOfChiJiState, updateInfo)
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
        _currentChannelSpellID = sid
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
        if CHAT_OUTPUT_ENABLED and rawSpellID ~= spellID then
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
        _currentChannelSpellID = nil
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

local function StartTracking()
    if active then return end
    active = true
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

local function StopTracking()
    if not active then return end
    active = false
    eventFrame:UnregisterAllEvents()
    wipe(pendingExpected)
    wipe(_reportedCastGUID)
    wipe(_pendingCastSpellID)
    wipe(_recentReports)
    UpdateBrokerText()
    UpdateStandaloneText()
    _lastReportedSpellID, _lastReportedTime = nil, 0
    lastCastSpellID = nil
    _comboBreakerState.stacks, _comboBreakerState.expiresAt, _comboBreakerState.instanceID = 0, nil, nil
    _danceOfChiJiState.stacks, _danceOfChiJiState.expiresAt, _danceOfChiJiState.instanceID = 0, nil, nil
end

local specFrame = CreateFrame("Frame")
specFrame:RegisterEvent("PLAYER_LOGIN")
specFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
specFrame:SetScript("OnEvent", function(_, event, unit)
    if event == "PLAYER_SPECIALIZATION_CHANGED" and unit ~= "player" then return end
    if event == "PLAYER_LOGIN" then
        ApplyStandalone()
        ApplySuggest()
    end
    if IsWindwalker() then
        StartTracking()
    else
        StopTracking()
    end
    ApplyStandaloneVisibility()
    ApplySuggestVisibility()
end)

SLASH_APLFOREUI1 = "/apl"
SlashCmdList.APLFOREUI = function(msg)
    local cmd, rest = msg:match("^(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()

    if cmd == "options" then
        if EllesmereUI and EllesmereUI.OpenPlugin then EllesmereUI.OpenPlugin("APLforEUI") end
        return
    end
    if cmd == "debug" then
        if rest == "" then
            local keys = {}
            for key in pairs(_debugWatchSteps) do keys[#keys + 1] = key end
            table.sort(keys)
            print("APL debug watch: " .. (#keys > 0 and table.concat(keys, ", ") or "(none)"))
            return
        end
        if rest:lower() == "clear" then
            wipe(_debugWatchSteps)
            print("APL debug watch: cleared.")
            return
        end
        local key = NormalizeStepKey(rest)
        if _debugWatchSteps[key] then
            _debugWatchSteps[key] = nil
            print("APL debug watch: stopped watching step " .. key .. ".")
        else
            _debugWatchSteps[key] = true
            print("APL debug watch: now watching step " .. key .. " (TTS announces when it's suggested).")
        end
        return
    end
    if cmd == "glow" then
        -- Plugin Glows status: shows which link in the chain (registered -> in use -> driver -> push) is missing.
        local pg = EllesmereUI and EllesmereUI.PluginGlows
        local expected = IsWindwalker() and EvaluateExpected() or nil
        print(string.format(
            "APL glow: PluginGlows=%s registered=%s inUse=%s driver=%s ticker=%s inCombat=%s pushes=%d lastPushed=%s evaluatesTo=%s",
            tostring(pg ~= nil), tostring(pg and pg.IsRegistered("APLforEUI-NextSpell") or false),
            tostring(_glowHandle and _glowHandle:IsInUse() or false), tostring(_glowFrame ~= nil),
            tostring(_glowTicker ~= nil), tostring(_glowInCombat), _glowPushes,
            tostring(_glowLastSpellID), tostring(expected)))
        return
    end
    if cmd == "chat" then
        CHAT_OUTPUT_ENABLED = not CHAT_OUTPUT_ENABLED
        print("APL for EUI: chat output " .. (CHAT_OUTPUT_ENABLED and "enabled" or "disabled") .. ".")
        return
    end
    if cmd == "chi" then
        CHI_ALERT_ENABLED = not CHI_ALERT_ENABLED
        print("APL for EUI: Chi TTS alert " .. (CHI_ALERT_ENABLED and "enabled" or "disabled") .. ".")
        return
    end
    if cmd == "zenith" then
        -- TEMP DEBUG: dumps the self-tracked Zenith/Zenith Stomp state so a
        -- live mismatch against reality is directly visible, not guessed at.
        local expiresIn = _zenithBuffExpiresAt and (_zenithBuffExpiresAt - GetTime())
        print(string.format(
            "APL debug: HasZenith()=%s chargesRemaining=%d buffExpiresIn=%s almostOver=%s chi=%d",
            tostring(HasZenith()), _zenithStompChargesRemaining,
            expiresIn and string.format("%.1f", expiresIn) or "nil",
            tostring(IsZenithAlmostOver()), GetChi()))
        print("APL debug: Zenith (builder) chargesAvailable=" .. GetZenithChargesAvailable())
        return
    end
    if cmd == "stacks" then
        -- TEMP DEBUG: dumps the self-tracked Combo Breaker/Dance of Chi-Ji
        -- proc-stack state and a full breakdown of the applications read
        -- (every step: raw fields, secrecy, pcall outcome), all on ONE line
        -- per buff so nothing gets lost copying from a scrolled chat frame.
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
        return
    end
    if cmd == "melee" then
        -- TEMP DEBUG: per-nameplate dump, remove once melee count is confirmed fixed.
        local plates = C_NamePlate and C_NamePlate.GetNamePlates and C_NamePlate.GetNamePlates(issecure())
        print("APL debug: " .. (plates and #plates or 0) .. " nameplate(s)")
        if plates then
            for _, plate in ipairs(plates) do
                local unit = plate.namePlateUnitToken or plate.unitToken
                if unit then
                    local canAttack = UnitCanAttack("player", unit)
                    local dead = UnitIsDead(unit)
                    local inRange = C_Spell and C_Spell.IsSpellInRange and C_Spell.IsSpellInRange(TIGER_PALM, unit)
                    print("APL debug: " .. unit .. " canAttack=" .. tostring(canAttack)
                        .. " dead=" .. tostring(dead) .. " inRange=" .. tostring(inRange))
                else
                    -- Neither known field name resolved -- dump every key on this
                    -- plate so we can find the real one instead of guessing again.
                    local keys = {}
                    for k in pairs(plate) do keys[#keys + 1] = tostring(k) end
                    print("APL debug: plate with no unit token, keys: " .. table.concat(keys, ", "))
                end
            end
        end
        print("APL debug: GetMeleeTargetCount() = " .. GetMeleeTargetCount())
        return
    end
    if active then
        StopTracking()
        print("APL for EUI: tracking stopped.")
    elseif IsWindwalker() then
        StartTracking()
        print("APL for EUI: tracking started.")
    else
        print("APL for EUI: requires Windwalker Monk spec.")
    end
end
