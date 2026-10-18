-- Built-in Elemental Shaman (Farseer) APLs, Raid and M+: compile, and
-- suggest what the Method guide says in representative situations.
-- usage: lua tests/elemental_test.lua <addonDir>
local dir = arg[1]
local S, ns = dofile(dir .. "/tests/mock_wow.lua")(dir)
local Engine = ns.Engine

local fails = 0
local function Check(ok, msg)
    if not ok then fails = fails + 1; print_real("FAIL: " .. msg) end
end

GetSpecializationInfo = function() return 262 end
local SK, NS, AS, ASC, FS, VB = 191634, 378081, 443454, 114050, 470411, 470057
local LVB, LB, CL, EB, EQ = 51505, 188196, 188443, 117014, 61882
local FS_DOT, MOTE, ANCESTORS, PF, SURGE = 188389, 260734, 447244, 1259491, 77762
local KICK = 57994

S.overrides[NS] = AS                           -- Ancestral Swiftness replaces Nature's Swiftness
for _, id in ipairs({ FS, FS_DOT, MOTE, SK, ANCESTORS, PF, SURGE }) do S.ALL_BUFFS[#S.ALL_BUFFS + 1] = id end

local raid = Engine.FindDefByID("builtin:shaman_elemental_farseer_raid")
local mplus = Engine.FindDefByID("builtin:shaman_elemental_farseer_mplus")
Check(raid and mplus, "Raid and M+ built-ins registered")
Check(Engine.BuiltinForSpec(262) == raid, "Raid is the spec's default")
local rt = ns.GetActiveAPL()
Check(rt and rt.def == raid and #rt.errors == 0, "Raid compiles: " .. tostring(rt and rt.errors[1]))
Check(#Engine.GetRuntime(mplus).errors == 0, "M+ compiles: " .. tostring(Engine.GetRuntime(mplus).errors[1]))
Check(Engine.IsFreeCast(rt, KICK), "Wind Shear is a free cast")

local function Suggest() return Engine.Evaluate(rt) end
local function Fight(casts, seconds)
    if casts == nil then ns.combatStart, ns.combatCasts = nil, nil
    else ns.combatStart, ns.combatCasts = S.now - seconds, casts end
end
local function Expect(spell, label, msg)
    local id, l = Suggest()
    Check(id == spell and l == label, msg .. ": want " .. spell .. " " .. label .. ", got " .. tostring(id) .. " (" .. tostring(l) .. ")")
end

-- Single-target opener: Stormkeeper, Lava Burst before the pull, Ancestral
-- Swiftness, Ascendance, Lightning Bolt, Lava Burst.
S.targets = 1
wipe(S.buffs); wipe(S.cd)
ns.lastCastSpellID = nil
Fight(nil)
Expect(SK, "OST1", "pre-pull Stormkeeper")
S.cd[SK] = true; S.buffs[SK] = true; ns.lastCastSpellID = SK
Expect(LVB, "OST2", "pre-pull Lava Burst")
ns.lastCastSpellID = LVB; S.buffs[MOTE] = true
Fight(0, 0.5)
Expect(AS, "OST3", "Ancestral Swiftness")
S.cd[AS] = true; ns.lastCastSpellID = AS; Fight(1, 2)
Expect(ASC, "OST4", "Ascendance")
S.cd[ASC] = true; ns.lastCastSpellID = ASC; Fight(2, 3)
Expect(LB, "OST5", "Stormkeeper Lightning Bolt")
ns.lastCastSpellID = LB; Fight(3, 5)
Expect(LVB, "OST6", "Lava Burst")

-- AoE opener: Stormkeeper, Ancestral Swiftness, Voltaic Blaze, Ascendance.
S.targets = 4
wipe(S.cd); ns.lastCastSpellID = nil; Fight(nil)
Expect(SK, "OAO1", "AoE pre-pull Stormkeeper")
S.cd[SK] = true; S.cd[AS] = true; Fight(1, 2)
Expect(VB, "OAO3", "AoE Voltaic Blaze")

-- Raid single target: Flame Shock refresh, Maelstrom cap, Master of the
-- Elements alternation.
S.targets = 1
wipe(S.cd); wipe(S.buffs)
S.cd[SK] = true; S.cd[AS] = true; S.cd[ASC] = true; S.cd[VB] = true
Fight(10, 20); ns.lastCastSpellID = LB
Expect(FS, "ST5", "no Flame Shock on the target: Flame Shock (raid)")
Engine.OnCast(rt, FS); S.buffs[FS_DOT] = true; ns.lastCastSpellID = FS
Expect(LVB, "ST6", "no Master of the Elements: Lava Burst")
S.buffs[MOTE] = true; ns.lastCastSpellID = LVB
Expect(EB, "ST8", "Master of the Elements: Elemental Blast")
S.buffs[SK] = true
Expect(LB, "ST7", "Stormkeeper + Master of the Elements: Lightning Bolt")
S.buffs[SK] = nil; S.buffs[MOTE] = nil
S.now = S.now + 13                             -- Flame Shock under 6s
ns.lastCastSpellID = LB
Expect(FS, "ST5", "Flame Shock under 6s: refresh")
Engine.OnCast(rt, FS); S.buffs[FS_DOT] = nil; S.buffs[FS] = true; ns.lastCastSpellID = LB
Check(Suggest() ~= FS, "Flame Shock seen through its other icon ID")
S.buffs[FS] = nil; S.buffs[FS_DOT] = true

-- Ascendance follows Stormkeeper: not while Stormkeeper is held (no buff),
-- right after it (buff up).
S.cd[ASC] = nil
local sid, slabel = Suggest()
Check(sid ~= ASC, "Ascendance ready, no Stormkeeper buff: not suggested (got " .. tostring(slabel) .. ")")
S.cd[SK] = nil
rt.holds[SK] = { count = 3, held = true }
Check(Suggest() ~= ASC and Suggest() ~= SK, "Stormkeeper held: neither Stormkeeper nor Ascendance")
rt.holds[SK] = nil
Expect(SK, "ST1", "Stormkeeper ready: Stormkeeper (hold line)")
Check(select(4, Suggest()).hold == 3, "Stormkeeper is holdable (hold 3)")
S.cd[SK] = true; S.buffs[SK] = true
Expect(ASC, "ST3", "Stormkeeper just cast: Ascendance")
S.cd[ASC] = true; S.buffs[SK] = nil

-- Raid 2 targets: Voltaic Blaze on cooldown, Chain Lightning filler.
S.targets = 2
S.cd[VB] = nil
Expect(VB, "T24", "2 targets: Voltaic Blaze on cooldown")
S.cd[VB] = true; Engine.OnCast(rt, FS); S.cd[LVB] = true
Expect(CL, "T210", "2 targets: Chain Lightning filler")
S.cd[LVB] = nil

-- Raid 3 targets: no Lava Burst.
S.targets = 3
Expect(EQ, "T36", "raid 3 targets: Earthquake, never Lava Burst")
-- Raid 4+: Lava Burst with Purging Flames (Lava Surge first), Earthquake.
S.targets = 5
S.buffs[PF] = true
Expect(LVB, "AOE6", "Lava Burst with Purging Flames")
S.buffs[SURGE] = true
Expect(LVB, "AOE5", "Lava Burst with Purging Flames on a Lava Surge")
S.buffs[PF] = nil; S.buffs[SURGE] = nil
Expect(EQ, "AOE7", "4+ targets: Earthquake")

-- M+: Earthquake with the Ancestors, Elemental Blast without (3-4), always
-- Earthquake at 5+; no Flame Shock line in single target.
ns.Store.SetActive(262, mplus.id)
rt = ns.GetActiveAPL()
Check(rt.def == mplus, "M+ selectable")
S.targets = 3
Expect(EB, "AOE8", "M+ 3 targets, no Ancestors: Elemental Blast")
S.buffs[ANCESTORS] = true
Expect(EQ, "AOE7", "M+ 3 targets, Ancestors up: Earthquake")
S.buffs[ANCESTORS] = nil
S.targets = 5
Expect(EQ, "BIG7", "M+ 5+ targets: always Earthquake")
S.targets = 1
wipe(S.buffs); Engine.OnCast(rt, VB); S.buffs[FS_DOT] = true
S.cd[VB] = nil; ns.lastCastSpellID = LB
Expect(LVB, "ST5", "M+ single target: Lava Burst (no Flame Shock line)")
ns.Store.SetActive(262, nil)

print_real(fails == 0 and "ALL PASS" or (fails .. " failures"))
