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
            { spell = "xuen", hold = 2 },
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
Cast(TP)
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

-- 2. Second ignore in a row: held, entry skipped, both casts forgiven.
Cast(TP)
Check(Holding("holding") == 1 and Holding("holding.xuen") == 1 and Holding("holding.fof") == 0, "two ignores: xuen held")
Check(Suggest() == TP, "held entry skipped")
total, pct = Stats()
Check(total == 2 and pct == 100, "ignored casts forgiven once held: " .. total .. "/" .. pct)
Check(Mark() == "|cff40ff40*|r", "held: green marker")

-- 3. Following the APL while holding keeps the hold.
Cast(TP)
Check(Holding("holding.xuen") == 1, "hold persists while following the APL")

-- 4. Casting the held spell clears it.
Cast(XUEN)
Check(Holding("holding") == 0 and Suggest() == XUEN, "casting the held spell clears the hold")

-- 5. Consecutive only: a cast while Xuen isn't the suggestion resets.
Cast(TP)                       -- ignore 1
S.cd[XUEN] = true              -- xuen on cooldown: tp is the suggestion
Cast(TP)                       -- not an ignore of xuen: resets the count
S.cd[XUEN] = nil
Cast(TP)                       -- ignore 1 again
Check(Holding("holding") == 0, "count reset by a cast while xuen wasn't suggested")
Cast(TP)                       -- ignore 2 in a row
Check(Holding("holding.xuen") == 1, "two in a row after the reset: held")

-- 6. Leaving combat clears holds.
combat:GetScript("OnEvent")(combat, "PLAYER_REGEN_ENABLED")
Check(Holding("holding") == 0 and Suggest() == XUEN, "combat end clears the hold")
Check(Mark() == "", "combat end clears the marker")

-- 6b. With hold 3: the 2nd ignore shows the yellow warning marker.
combat:GetScript("OnEvent")(combat, "PLAYER_REGEN_DISABLED")
def.groups[1].lists[1].entries[1].hold = 3
Store.Changed(def)
rt = ns.GetActiveAPL()
Cast(TP)
Check(Mark() == "", "hold 3, one ignore: no marker")
Cast(TP)
Check(Mark() == "|cffffd000*|r", "hold 3, two ignores: yellow marker")
Cast(TP)
Check(Mark() == "|cff40ff40*|r", "hold 3, three ignores: green marker")
combat:GetScript("OnEvent")(combat, "PLAYER_REGEN_ENABLED")
def.groups[1].lists[1].entries[1].hold = 2
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
Check(#errs == 1 and errs[1]:find("hold must be"), "hold 0 reported: " .. tostring(errs[1]))
def.groups[1].lists[1].entries[1].hold = 2
Store.Changed(def)

-- 9. Export/import keeps hold.
local back = ns.Exchange.Import(ns.Exchange.Export(def))
Check(back and back.groups[1].lists[1].entries[1].hold == 2 and back.groups[1].lists[1].entries[2].hold == nil,
    "hold survives export/import")

-- 10. Renaming a short name rewrites holding.<name>.
def.groups[1].lists[1].entries[2].when = "!holding.xuen"
Store.RenameBlock(def, "name", "xuen", "white_tiger")
Check(def.groups[1].lists[1].entries[2].when == "!holding.white_tiger", "rename rewrites holding.<name>")

print_real(fails == 0 and "ALL PASS" or (fails .. " failures"))
