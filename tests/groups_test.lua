-- List groups (phase 5): priority order, fall-through, per-group target
-- ranges, opener combat reads, broken conditions, migration, labels.
-- usage: lua tests/groups_test.lua <addonDir>
local dir = arg[1]
local S, ns = dofile(dir .. "/tests/mock_wow.lua")(dir)
local Engine, Store = ns.Engine, ns.Store

local fails = 0
local function Check(ok, msg)
    if not ok then fails = fails + 1; print_real("FAIL: " .. msg) end
end

-- Spells: 1 tiger palm (no cd), 2 fists (cd-able), 3 rsk (cd-able), buff 50.
local TP, FOF, RSK, BUFF = 100780, 113656, 107428, 443294
local function APL()
    return {
        name = "t", specID = 269,
        options = { rangeSpell = "tp" },
        names = { tp = TP, fof = FOF, rsk = RSK, burst = BUFF },
        groups = {
            { name = "Opener", prefix = "OP", when = "combat.casts<2&combat.time<8", lists = {
                { name = "ST", prefix = "OST", min = 1, max = 1, entries = { { spell = "rsk" } } },
            } },
            { name = "Burst", prefix = "BU", when = "buff.burst.up", lists = {
                { name = "ST", prefix = "BST", min = 1, max = 1, entries = { { spell = "fof" } } },
            } },
            { name = "Default", prefix = "DEF", lists = {
                { name = "ST", prefix = "ST", min = 1, max = 1, entries = { { spell = "tp" } } },
                { name = "AOE", prefix = "AOE", min = 2, entries = { { spell = "fof" }, { spell = "tp" } } },
            } },
        },
    }
end

local def = APL()
local rt = Engine.GetRuntime(def)
Check(#rt.errors == 0, "compiles: " .. tostring(rt.errors[1]))
local function Eval()
    local id, label, list = Engine.Evaluate(rt)
    return id, label, list
end
local function InCombat(casts, seconds)
    ns.combatStart, ns.combatCasts = S.now - seconds, casts
end
local function OutOfCombat() ns.combatStart, ns.combatCasts = nil, nil end

S.targets = 1
wipe(S.cd); wipe(S.buffs)

-- Before the pull, combat reads are 0: the opener already shows.
OutOfCombat()
local id, label, list = Eval()
Check(id == RSK and label == "OST1" and list == "OP-OST", "opener shows before the pull: " .. tostring(list))
Check(Engine.CurrentListName(rt) == "OP-OST", "status label is group prefix-list prefix")

-- In the opener window.
InCombat(1, 2)
Check(Eval() == RSK, "opener during its first casts")
-- Opener's only entry on cooldown: falls through past Burst (inactive) to Default.
S.cd[RSK] = true
id, label = Eval()
Check(id == TP and label == "ST1", "opener with nothing to suggest falls through: " .. tostring(label))
S.cd[RSK] = nil
-- Opener over by casts, and by time.
InCombat(2, 2)
Check(Eval() == TP, "opener ends after its casts")
InCombat(0, 9)
Check(Eval() == TP, "opener ends after its time")

-- Burst takes priority over Default while its condition holds.
InCombat(5, 20)
S.buffs[BUFF] = true
id, label, list = Eval()
Check(id == FOF and label == "BST1" and list == "BU-BST", "burst group wins while its buff is up")
-- Burst entry on cooldown: falls through to Default.
S.cd[FOF] = true
Check(Eval() == TP, "burst falls through when its list has nothing")
S.cd[FOF] = nil
-- Burst has no AOE list: 3 targets go to Default's AOE list.
S.targets = 3
id, label, list = Eval()
Check(id == FOF and label == "AOE1" and list == "DEF-AOE", "group without a list for the count is skipped")
S.targets = 1
S.buffs[BUFF] = nil
Check(Eval() == TP, "default when nothing else applies")

-- No list at all for the count in any group: nothing.
local def2 = APL()
def2.groups[3].lists[2] = nil
local rt2 = Engine.GetRuntime(def2)
S.targets = 4
Check(Engine.Evaluate(rt2) == nil and Engine.CurrentListName(rt2) == nil, "no list anywhere: nothing suggested")
S.targets = 1

-- Ranges may overlap across groups, not within one.
local def3 = APL()
def3.groups[3].lists[1].max = 3
local errs = Engine.GetRuntime(def3).errors
Check(#errs == 1 and errs[1]:find("overlap"), "overlap within a group reported: " .. tostring(errs[1]))
Check(#rt.errors == 0, "same ranges in different groups are fine")

-- A group prefix is required (1-3 characters).
local def8 = APL()
def8.groups[2].prefix = ""
errs = Engine.GetRuntime(def8).errors
Check(#errs == 0 and def8.groups[2].prefix == "BUR", "missing group prefix filled from its name: " .. tostring(def8.groups[2].prefix))
local def7 = APL()
def7.groups[1].prefix = "OPEN"
errs = Engine.GetRuntime(def7).errors
Check(#errs == 1 and errs[1]:find("group Opener"), "4-character group prefix reported: " .. tostring(errs[1]))

-- Duplicate prefixes across groups would make labels ambiguous.
local def4 = APL()
def4.groups[2].lists[1].prefix = "ST"
errs = Engine.GetRuntime(def4).errors
Check(#errs == 1 and errs[1]:find("prefix 'ST'"), "duplicate prefix reported: " .. tostring(errs[1]))

-- A broken group condition never acts as "always".
local def5 = APL()
def5.groups[2].when = "buff.nope.up"
local rt5 = Engine.GetRuntime(def5)
InCombat(5, 20)
Check(#rt5.errors == 1 and Engine.Evaluate(rt5) == TP, "broken group condition skips the group")

-- Migration of a pre-group APL.
local old = { name = "old", specID = 269, names = { tp = TP }, lists = {
    { name = "ST", prefix = "ST", min = 1, max = 1, entries = { { spell = "tp" } } },
} }
Engine.Migrate(old)
Check(old.lists == nil and #old.groups == 1 and old.groups[1].name == "Default" and old.groups[1].when == nil
    and old.groups[1].prefix == "DEF", "flat lists migrate to one Default group with prefix DEF")
Check(Engine.Migrate(old) == old and #old.groups == 1, "migration is idempotent")
Check(#Engine.GetRuntime(old).errors == 0, "migrated APL compiles")

-- Store: groups, ranges per group, prefixes.
local user = Store.New(269)
Check(#user.groups == 1 and user.groups[1].name == "Default", "new APL has a Default group")
local g = Store.AddGroup(user)
Check(user.groups[1] == g and g.lists[1].prefix ~= "ST" and g.prefix == "G2", "AddGroup goes on top with fresh prefixes")
Check(Store.RangeConflict(user, g.lists[1], 1, 5) == nil, "range check only looks within the group")
Check(Store.RangeConflict(user, user.groups[2].lists[1], 1, 3) ~= nil, "range clash within a group still caught")
local extra = Store.AddList(user, g)
Check(extra and extra.min == 2, "AddList uses the group's next free count")
Check(#Engine.GetRuntime(user).errors == 0, "store-built groups compile: " .. tostring(Engine.GetRuntime(user).errors[1]))
-- Renames reach group conditions.
user.names.burst = BUFF
g.when = "buff.burst.up"
Check(Store.RenameBlock(user, "name", "burst", "cwt") and g.when == "buff.cwt.up", "rename rewrites group conditions")

-- Entries are skipped while the game says their spell can't be cast,
-- unless the entry opts out with usable = false.
OutOfCombat()
local def6 = APL()
def6.groups = { def6.groups[3] }
local rt6 = Engine.GetRuntime(def6)
local stList = def6.groups[1].lists[1]
table.insert(stList.entries, 1, { spell = "rsk" })
rt6 = (Engine.Invalidate(def6) or Engine.GetRuntime(def6))
Check(Engine.Evaluate(rt6) == RSK, "usable entry suggested")
S.unusable[RSK] = true
Check(Engine.Evaluate(rt6) == TP, "unusable entry skipped by default")
stList.entries[1].usable = false
Engine.Invalidate(def6)
rt6 = Engine.GetRuntime(def6)
Check(Engine.Evaluate(rt6) == RSK, "usable = false opts out")
S.unusable[RSK] = nil

print_real(fails == 0 and "ALL PASS" or (fails .. " failures"))
