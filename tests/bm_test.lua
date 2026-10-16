-- Built-in Beast Mastery (Pack Leader) APL: compiles, and suggests what the
-- Method guide says in representative situations.
-- usage: lua tests/bm_test.lua <addonDir>
local dir = arg[1]
local S, ns = dofile(dir .. "/tests/mock_wow.lua")(dir)
local Engine = ns.Engine

local fails = 0
local function Check(ok, msg)
    if not ok then fails = fails + 1; print_real("FAIL: " .. msg) end
end

GetSpecializationInfo = function() return 253 end
local BS, BW, KC, COBRA, THRASH, HM = 217200, 19574, 34026, 193455, 1264359, 257284
local HOWL_BW, NATURES_ALLY, BEAST_CLEAVE, COBRA_FANG = 472325, 1276720, 268877, 1299389

-- Charge spells: S.charges[id] = 0 / 1 / 2.
S.charges = { [BS] = 2, [KC] = 2 }
local realCharges, realCooldown = C_Spell.GetSpellCharges, C_Spell.GetSpellCooldown
C_Spell.GetSpellCharges = function(id)
    local n = S.charges[id]
    if n then return { maxCharges = 2, isActive = n < 2 } end
    return realCharges(id)
end
C_Spell.GetSpellCooldown = function(id)
    local n = S.charges[id]
    if n then return { isActive = n == 0, isOnGCD = false } end
    return realCooldown(id)
end
-- Buff reads go through the CDM mock: only these IDs exist there.
S.ALL_BUFFS[#S.ALL_BUFFS + 1] = HOWL_BW
S.ALL_BUFFS[#S.ALL_BUFFS + 1] = NATURES_ALLY
S.ALL_BUFFS[#S.ALL_BUFFS + 1] = BEAST_CLEAVE
S.ALL_BUFFS[#S.ALL_BUFFS + 1] = COBRA_FANG

local rt = ns.GetActiveAPL()
Check(rt and rt.name == "Beast Mastery - Pack Leader (default)", "BM spec runs the Pack Leader built-in")
Check(rt and #rt.errors == 0, "compiles: " .. tostring(rt and rt.errors[1]))

local function Suggest()
    local id, label = Engine.Evaluate(rt)
    return id, label
end
local function Fight(casts, seconds)
    if casts == nil then ns.combatStart, ns.combatCasts = nil, nil
    else ns.combatStart, ns.combatCasts = S.now - seconds, casts end
end

S.targets = 1
wipe(S.buffs); wipe(S.cd)

-- Before the pull: Hunter's Mark, then the opener's first Barbed Shot.
Fight(nil)
ns.lastCastSpellID = nil
local id, label = Suggest()
Check(id == HM and label == "OST1", "pre-pull: Hunter's Mark (" .. tostring(label) .. ")")
ns.lastCastSpellID = HM
id, label = Suggest()
Check(id == BS and label == "OST2", "after Mark: Barbed Shot (" .. tostring(label) .. ")")

-- Opener sequence by cast count.
local seq = { [0] = BS, [1] = BS, [2] = BW, [3] = KC, [4] = COBRA, [5] = BS, [6] = KC }
for n = 0, 6 do
    Fight(n, 1 + n)
    ns.lastCastSpellID = nil
    Check(Suggest() == seq[n], "opener cast " .. n .. ": " .. tostring(seq[n]) .. " got " .. tostring(Suggest()))
end

-- Default single target.
Fight(10, 20)
S.charges[BS] = 2
id, label = Suggest()
Check(id == BS and label == "ST1", "Barbed Shot at 2 charges (" .. tostring(label) .. ")")
-- Bestial Wrath timer: 30s with The Beast Within.
S.talents[231548] = true
GetSpellBaseCooldown = function(sid) if sid == BW then return 90000 end return 0 end
Engine.OnCast(rt, BW)
local _, rem = Engine.EvalText(rt, "timer.bw_cd.remains")
Check(rem and math.abs(rem - 30) < 0.01, "Bestial Wrath timer 30s with The Beast Within: " .. tostring(rem))
S.talents[231548] = nil
Engine.OnCast(rt, BW)
_, rem = Engine.EvalText(rt, "timer.bw_cd.remains")
Check(rem and math.abs(rem - 90) < 0.01, "and 90s without it: " .. tostring(rem))
S.talents[231548] = true
-- One Barbed Shot charge: only spent when Bestial Wrath is coming up.
S.charges[BS] = 1
S.cd[BW] = true
Engine.OnCast(rt, BW)               -- 30s left
S.buffs[HOWL_BW] = true
id, label = Suggest()
Check(id == KC and label == "ST3", "1 charge, Bestial Wrath far off: Kill Command first (" .. tostring(label) .. ")")
S.now = S.now + 27                   -- 3s left
id, label = Suggest()
Check(id == BS and label == "ST1", "1 charge, Bestial Wrath due in 3s: Barbed Shot (" .. tostring(label) .. ")")
S.buffs[HOWL_BW] = nil
S.cd[BW] = nil
id, label = Suggest()
Check(id == BS and label == "ST1", "Bestial Wrath ready, a charge left: Barbed Shot first")
S.charges[BS] = 2
S.charges[BS] = 0
id, label = Suggest()
Check(id == BW and label == "ST2", "Bestial Wrath with no Barbed Shot charge")
S.cd[BW] = true
Engine.OnCast(rt, BW)               -- Bestial Wrath 30s away: not "coming up"
S.buffs[HOWL_BW] = true
id, label = Suggest()
Check(id == KC and label == "ST3", "Kill Command during Howl")
S.buffs[HOWL_BW] = nil
S.buffs[NATURES_ALLY] = true
Check(Suggest() == KC, "Kill Command during Nature's Ally")
S.buffs[NATURES_ALLY] = nil
S.charges[BS] = 1
S.buffs[COBRA_FANG] = true
id, label = Suggest()
Check(id == COBRA and label == "ST4", "Cobra Shot while Cobra Fang is up (" .. tostring(label) .. ")")
S.buffs[COBRA_FANG] = nil
id, label = Suggest()
Check(id == BS and label == "ST5", "plain Barbed Shot")
S.charges[BS] = 0
id, label = Suggest()
Check(id == COBRA and label == "ST6", "Cobra Shot filler")

-- Default multi-target.
S.targets = 4
S.charges[BS] = 1
id, label = Suggest()
Check(id == THRASH and label == "AOE1", "Wild Thrash to apply Beast Cleave")
S.buffs[BEAST_CLEAVE] = true
S.cd[THRASH] = true
S.cd[BW] = nil
id, label = Suggest()
Check(id == BW and label == "AOE3", "Bestial Wrath while Beast Cleave is up")
S.cd[THRASH] = nil
ns.lastCastSpellID = BW
id, label = Suggest()
Check(id == THRASH and label == "AOE1", "Wild Thrash right after Bestial Wrath")
ns.lastCastSpellID = nil
S.cd[THRASH], S.cd[BW] = true, true
S.buffs[COBRA_FANG] = true
id, label = Suggest()
Check(id == COBRA and label == "AOE6", "AOE: Cobra Shot while Cobra Fang is up (" .. tostring(label) .. ")")
S.buffs[COBRA_FANG] = nil
id, label = Suggest()
Check(id == BS and label == "AOE7", "AOE: plain Barbed Shot (" .. tostring(label) .. ")")

-- Buffs that only show on a CDM icon as a linked spell (Beast Cleave's buff
-- 268877 on the 115939 entry) are read through that icon.
S.ALL_BUFFS[#S.ALL_BUFFS + 1] = 115939
S.linked[115939] = { BEAST_CLEAVE }
S.buffs[BEAST_CLEAVE] = nil
S.buffs[115939] = true
Check(ns.HasBuff(BEAST_CLEAVE), "buff seen through its linked CDM icon")
S.buffs[115939] = nil
Check(not ns.HasBuff(BEAST_CLEAVE), "and gone when the icon is")


-- Target count: enemies out of combat (idle mobs, unattacked dummies) don't count.
S.targets = 4
S.idle = { nameplate2 = true, nameplate3 = true, nameplate4 = true }
Check(ns.GetTargetCount() == 1, "only enemies in combat count: " .. ns.GetTargetCount())
S.idle = {}
Check(ns.GetTargetCount() == 4, "all four once in combat")

-- Auto Shot never advances the opener or counts as a cast.
Check(ns.AUTO_ATTACKS[75], "Auto Shot is an auto-attack")

-- Export / import round trip of the built-in.
local def = Engine.BuiltinForSpec(253)
local back = ns.Exchange.Import(ns.Exchange.Export(def))
Check(back and ns.Exchange.Export(back) == ns.Exchange.Export(def), "built-in survives export/import")

print_real(fails == 0 and "ALL PASS" or (fails .. " failures"))
