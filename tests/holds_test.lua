-- Holding cooldowns (phase 6), driven through Tracking's real event handler:
-- consecutive ignores, held entries skipped, holding reads, forgiveness in
-- the compliance stats, clearing on cast and on leaving combat.
-- usage: lua tests/holds_test.lua <addonDir>
local dir = arg[1]
local S, ns = dofile(dir .. "/tests/mock_wow.lua")(dir)
local Engine, Store = ns.Engine, ns.Store

local fails = 0
local function Check(ok, msg)
    if not ok then fails = fails + 1; print_real("FAIL: " .. msg) end
end

local function FrameFor(event)
    for _, f in ipairs(S.frames) do
        if f._events and f._events[event] then return f end
    end
end

local TP, XUEN, FOF = 100780, 123904, 113656
local def = Store.AddImported({
    name = "holds", specID = 269,
    options = { rangeSpell = "tp" },
    names = { tp = TP, xuen = XUEN, fof = FOF },
    groups = { { name = "Default", prefix = "DEF", lists = {
        { name = "ST", prefix = "ST", min = 1, max = 1, entries = {
            { spell = "xuen", hold = 3 },
            { spell = "tp" },
        } },
    } } },
})
Store.SetActive(269, def.id)
local rt = ns.GetActiveAPL()
Check(rt == Engine.GetRuntime(def) and #rt.errors == 0, "test APL active and compiles: " .. tostring(rt.errors[1]))

-- Tracking must be running for its event frame.
ns.StopTracking(); ns.StartTracking()
local track = FrameFor("UNIT_SPELLCAST_SUCCEEDED")
local combat = FrameFor("PLAYER_REGEN_ENABLED")
Check(track ~= nil and combat ~= nil, "found tracking and combat frames")
local onEvent = track:GetScript("OnEvent")

local guid = 0
local function Cast(spellID)
    S.now = S.now + 1.5
    guid = guid + 1
    local g = "cast-" .. guid
    onEvent(track, "UNIT_SPELLCAST_SENT", "player", "target", g, spellID)
    onEvent(track, "UNIT_SPELLCAST_SUCCEEDED", "player", g, spellID)
end
local function Suggest() return (Engine.Evaluate(rt)) end
local function Holding(text) local _, v = Engine.EvalText(rt, text); return v end
local function Stats() local _, total, pct = ns.BuildStatsSummary(); return total, pct end
local function Mark() return select(6, ns.BuildStatsSummary()) end

S.targets = 1
wipe(S.cd)
combat:GetScript("OnEvent")(combat, "PLAYER_REGEN_DISABLED")

-- 1. Ignore Xuen once: counted, not held, the cast is a miss for now.
Check(Suggest() == XUEN, "xuen suggested")
Cast(FOF)
Check(Suggest() == XUEN and Holding("holding") == 0, "one ignore: not held yet")
local total, pct = Stats()
Check(total == 1 and pct == 0, "first ignore counts as a miss for now: " .. total .. "/" .. pct)
Check(Mark() == "", "one ignore: no marker")

-- Auto Shot fires cast events constantly: never a cast, an ignore or combat.casts.
local castsBefore = ns.combatCasts
Cast(75)
Cast(75)
total = Stats()
Check(total == 1 and ns.combatCasts == castsBefore and Holding("holding") == 0, "Auto Shot ignored by tracking")

-- 2. Third ignore in a row: held, entry skipped, all three casts forgiven.
Cast(FOF)
Check(Holding("holding") == 0, "two ignores: not held yet")
Cast(FOF)
Check(Holding("holding") == 1 and Holding("holding.xuen") == 1 and Holding("holding.fof") == 0, "three ignores: xuen held")
Check(Suggest() == TP, "held entry skipped")
total, pct = Stats()
Check(total == 3 and pct == 100, "ignored casts forgiven once held: " .. total .. "/" .. pct)
Check(Mark() == "|cff40ff40*|r", "held: green marker")

-- 3. Following the APL while holding keeps the hold.
Cast(TP)
Check(Holding("holding.xuen") == 1, "hold persists while following the APL")

-- 4. Casting the held spell clears it.
Cast(XUEN)
Check(Holding("holding") == 0 and Suggest() == XUEN, "casting the held spell clears the hold")

-- 5. Consecutive only: a cast while Xuen isn't the suggestion resets.
Cast(FOF)                      -- ignore 1
S.cd[XUEN] = true              -- xuen on cooldown: tp is the suggestion
Cast(TP)                       -- not an ignore of xuen: resets the count
S.cd[XUEN] = nil
Cast(FOF)                      -- ignore 1 again
Cast(FOF)                      -- ignore 2 in a row
Check(Holding("holding") == 0, "count reset by a cast while xuen wasn't suggested")
Cast(FOF)                      -- ignore 3 in a row
Check(Holding("holding.xuen") == 1, "three in a row after the reset: held")

-- 6. Leaving combat clears holds.
combat:GetScript("OnEvent")(combat, "PLAYER_REGEN_ENABLED")
Check(Holding("holding") == 0 and Suggest() == XUEN, "combat end clears the hold")
Check(Mark() == "", "combat end clears the marker")

-- 6b. The 2nd ignore shows the yellow warning marker.
combat:GetScript("OnEvent")(combat, "PLAYER_REGEN_DISABLED")
Cast(FOF)
Check(Mark() == "", "hold 3, one ignore: no marker")
Cast(FOF)
Check(Mark() == "|cffffd000*|r", "hold 3, two ignores: yellow marker")
Cast(FOF)
Check(Mark() == "|cff40ff40*|r", "hold 3, three ignores: green marker")
combat:GetScript("OnEvent")(combat, "PLAYER_REGEN_ENABLED")

-- 6c. Hold fork: a hold line on top also offers the next valid action;
-- casting that alternative holds the spell from the second cast on the
-- hold line (the first may already be in flight when the hold spell came
-- up), and counts as compliant.
combat:GetScript("OnEvent")(combat, "PLAYER_REGEN_DISABLED")
local fid, _, _, fentry, falt = ns.EvaluateExpected()
Check(fid == XUEN and fentry and fentry.hold == 3 and falt == TP, "fork: Xuen (hold) with Tiger Palm as the alternative")
Cast(TP)
Check(Holding("holding") == 0, "first alternative cast: not held (may be a press in flight)")
Cast(TP)
Check(Holding("holding.xuen") == 1, "second alternative cast in a row: held")
Check(select(5, ns.BuildStatsSummary()) == true, "the alternative cast counts as compliant")
local nid, _, _, nentry, nalt = ns.EvaluateExpected()
Check(nid == TP and nalt == nil, "once held: no fork, Tiger Palm suggested")
combat:GetScript("OnEvent")(combat, "PLAYER_REGEN_ENABLED")
-- An ignore streak, then the alternative: held, both forgiven.
combat:GetScript("OnEvent")(combat, "PLAYER_REGEN_DISABLED")
Cast(FOF)
Check(Holding("holding") == 0, "one ignore: not held")
Cast(TP)
Check(Holding("holding.xuen") == 1, "ignore then alternative: held")
combat:GetScript("OnEvent")(combat, "PLAYER_REGEN_ENABLED")
-- The edge case: Tiger Palm already on its way as Xuen comes up, then Xuen.
combat:GetScript("OnEvent")(combat, "PLAYER_REGEN_DISABLED")
Cast(TP)
Cast(XUEN)
Check(Holding("holding") == 0, "alternative once, then the hold spell: never held")
combat:GetScript("OnEvent")(combat, "PLAYER_REGEN_ENABLED")
-- No hold set: no fork.
def.groups[1].lists[1].entries[1].hold = nil
Store.Changed(def)
rt = ns.GetActiveAPL()
local _, _, _, _, noAlt = ns.EvaluateExpected()
Check(noAlt == nil, "no hold setting: no fork")
def.groups[1].lists[1].entries[1].hold = 3
Store.Changed(def)
rt = ns.GetActiveAPL()

-- 7. Entries without hold never become held.
combat:GetScript("OnEvent")(combat, "PLAYER_REGEN_DISABLED")
def.groups[1].lists[1].entries[1].hold = nil
Store.Changed(def)
rt = ns.GetActiveAPL()
for _ = 1, 5 do Cast(TP) end
Check(Holding("holding") == 0 and Suggest() == XUEN, "no hold setting: never held")

-- 8. Invalid hold values are reported.
def.groups[1].lists[1].entries[1].hold = 0
Store.Changed(def)
local errs = Engine.GetRuntime(def).errors
Check(#errs == 1 and errs[1]:find("hold must be a whole number of 3"), "hold 0 reported: " .. tostring(errs[1]))
-- Holds of 1 and 2 (saved before the minimum) are raised to 3.
def.groups[1].lists[1].entries[1].hold = 2
Store.Changed(def)
errs = Engine.GetRuntime(def).errors
Check(#errs == 0 and def.groups[1].lists[1].entries[1].hold == 3, "saved hold 2 raised to 3")
def.groups[1].lists[1].entries[1].hold = 1
Store.Changed(def)
Engine.GetRuntime(def)
Check(def.groups[1].lists[1].entries[1].hold == 3, "saved hold 1 raised to 3")

-- 9. Export/import keeps hold.
local back = ns.Exchange.Import(ns.Exchange.Export(def))
Check(back and back.groups[1].lists[1].entries[1].hold == 3 and back.groups[1].lists[1].entries[2].hold == nil,
    "hold survives export/import")

-- 10. Renaming a short name rewrites holding.<name>.
def.groups[1].lists[1].entries[2].when = "!holding.xuen"
Store.RenameBlock(def, "name", "xuen", "white_tiger")
Check(def.groups[1].lists[1].entries[2].when == "!holding.white_tiger", "rename rewrites holding.<name>")

-- 11. Free casts: no stats entry, no hold ignore, no cast count, not the
-- last cast; renames and export/import keep them; unknown names reported.
local KICK = 116705
def.names.kick = KICK
Check(Store.AddFreeCast(def, "kick") and not Store.AddFreeCast(def, "kick"), "free cast added once")
rt = ns.GetActiveAPL()
Check(#rt.errors == 0 and Engine.IsFreeCast(rt, KICK) and not Engine.IsFreeCast(rt, TP), "free cast compiled")
def.groups[1].lists[1].entries[2].when = nil
Store.Changed(def)
rt = ns.GetActiveAPL()
combat:GetScript("OnEvent")(combat, "PLAYER_REGEN_DISABLED")
wipe(S.cd)
Check(Suggest() == XUEN, "Xuen suggested")
Cast(FOF)                                  -- ignore 1
local total0 = Stats()
local casts0, last0 = ns.combatCasts, ns.lastCastSpellID
Cast(KICK)
Cast(KICK)
Cast(KICK)                                 -- would be ignore 3 (held) if counted
Check(Stats() == total0, "free casts add no stats entries")
Check(Holding("holding") == 0, "free casts don't count as ignoring a hold line")
Check(ns.combatCasts == casts0 and ns.lastCastSpellID == last0, "free casts don't count as casts or the last cast")
Cast(FOF)                                  -- ignore 2: the streak survived the kicks
Check(Holding("holding") == 0, "two real ignores: not held yet")
Cast(FOF)                                  -- ignore 3
Check(Holding("holding.white_tiger") == 1, "ignore streak continues across free casts")
combat:GetScript("OnEvent")(combat, "PLAYER_REGEN_ENABLED")
Store.RenameBlock(def, "name", "kick", "spear_hand")
Check(def.freeCasts[1] == "spear_hand", "rename rewrites free casts")
back = ns.Exchange.Import(ns.Exchange.Export(def))
Check(back and back.freeCasts and back.freeCasts[1] == "spear_hand", "free casts survive export/import")
def.freeCasts[2] = "nope"
Store.Changed(def)
rt = ns.GetActiveAPL()
Check(rt.errors[1] and rt.errors[1]:find("free casts", 1, true), "unknown free cast reported: " .. tostring(rt.errors[1]))
def.freeCasts[2] = nil
Store.Changed(def)

-- 12. A hard cast that can't be interrupted: UnitCastingInfo's 8th return
-- is notInterruptible (true), the spellID is the 9th. Reported by its ID.
do
    local saved = UnitCastingInfo
    UnitCastingInfo = function() return "Mind Blast", "", 1, 0, 1500, false, "cg", true, TP end
    combat:GetScript("OnEvent")(combat, "PLAYER_REGEN_DISABLED")
    S.now = S.now + 1.5
    local before = Stats()
    onEvent(track, "UNIT_SPELLCAST_SENT", "player", "target", "hard-1", TP)
    local ok, err = pcall(onEvent, track, "UNIT_SPELLCAST_START", "player", "hard-1", TP)
    Check(ok, "uninterruptible hard cast doesn't error: " .. tostring(err))
    onEvent(track, "UNIT_SPELLCAST_SUCCEEDED", "player", "hard-1", TP)
    Check(Stats() == before + 1 and ns.lastCastSpellID == TP, "hard cast reported once, by its spellID")
    combat:GetScript("OnEvent")(combat, "PLAYER_REGEN_ENABLED")
    UnitCastingInfo = saved
end

print_real(fails == 0 and "ALL PASS" or (fails .. " failures"))
