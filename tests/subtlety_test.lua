-- Built-in Subtlety Rogue (Trickster) APL: compiles, and suggests what the
-- Method guide says in representative situations.
-- usage: lua tests/subtlety_test.lua <addonDir>
local dir = arg[1]
local S, ns = dofile(dir .. "/tests/mock_wow.lua")(dir)
local Engine = ns.Engine

local fails = 0
local function Check(ok, msg)
    if not ok then fails = fails + 1; print_real("FAIL: " .. msg) end
end

GetSpecializationInfo = function() return 261 end
local STEALTH, BS, EVIS, STORM, POWDER, DANCE = 1784, 53, 196819, 197835, 319175, 185313
local BLADES, ST, BITE, VANISH = 121471, 280719, 426591, 1856
local SHADOWSTRIKE, CDG = 185438, 999102       -- CDG: test stand-in for the override ID
local DANCE_BUFF, SUBTERFUGE, STEALTH2 = 185422, 115192, 158185
local KICK = 1766

local realPower = UnitPower
S.cp = 0
UnitPower = function(u, pt) if pt == 4 then return S.cp end return realPower(u, pt) end
for _, id in ipairs({ STEALTH, STEALTH2, SUBTERFUGE, DANCE_BUFF }) do S.ALL_BUFFS[#S.ALL_BUFFS + 1] = id end

-- In a party with someone fighting, so Vanish is allowed (solo is tested below).
S.group = "party"; S.members = { party1 = true }
local rt = ns.GetActiveAPL()
Check(rt and rt.name == "Subtlety - Trickster (default)", "Subtlety runs the Trickster built-in")
Check(rt and #rt.errors == 0, "compiles: " .. tostring(rt and rt.errors[1]))
Check(Engine.IsFreeCast(rt, KICK), "Kick is a free cast")

local function Suggest() return Engine.Evaluate(rt) end
local function Fight(casts, seconds)
    if casts == nil then ns.combatStart, ns.combatCasts = nil, nil
    else ns.combatStart, ns.combatCasts = S.now - seconds, casts end
end
local function Expect(spell, label, msg)
    local id, l = Suggest()
    Check(id == spell and l == label, msg .. ": want " .. spell .. " " .. label .. ", got " .. tostring(id) .. " (" .. tostring(l) .. ")")
end

-- Single-target opener: Stealth, then by cast number.
S.targets = 1
wipe(S.buffs); wipe(S.cd)
ns.lastCastSpellID = nil
Fight(nil)
Expect(STEALTH, "OST1", "out of combat: Stealth")
S.buffs[STEALTH] = true
Expect(SHADOWSTRIKE, "OST2", "stealthed opener: Shadowstrike")
local seq = { [1] = EVIS, [2] = VANISH, [3] = SHADOWSTRIKE, [4] = BITE, [5] = EVIS, [6] = DANCE, [7] = BLADES, [8] = STORM, [9] = ST }
for n, spell in pairs(seq) do
    Fight(n, n)
    ns.lastCastSpellID = nil
    Check(Suggest() == spell, "opener cast " .. n .. ": " .. spell .. " got " .. tostring(Suggest()))
end
-- AoE opener.
S.targets = 3
Fight(0, 0)
Expect(STORM, "OAO2", "AoE opener: Shuriken Storm")
Fight(2, 2)
Expect(DANCE, "OAO4", "AoE opener: Shadow Dance")

-- Default single target.
S.targets = 1
wipe(S.buffs)
Fight(20, 30)
S.cd[BITE] = true; S.cd[VANISH] = true
S.cp = 3
Expect(BS, "ST10", "outside Dance, low combo points: Backstab")
S.cd[VANISH] = nil; S.cp = 1
Expect(VANISH, "ST8", "low combo points, outside Dance, group fighting: Vanish")
S.members.party1 = false
Expect(BS, "ST10", "group member out of combat: no Vanish (it would drop the fight)")
S.group, S.members = nil, {}
Expect(BS, "ST10", "solo: no Vanish")
local _, solo = Engine.EvalText(rt, "group")
Check(solo == 0, "group reads 0 solo")
S.group, S.members, S.playerUnit = "raid", { raid1 = true, raid2 = false }, "raid1"
local _, gc = Engine.EvalText(rt, "group.combat")
Check(gc == 0, "raid: the player's own raid slot doesn't count")
S.members.raid2 = true
_, gc = Engine.EvalText(rt, "group.combat")
Check(gc == 1, "raid: another member in combat")
S.group, S.members, S.playerUnit = "party", { party1 = true }, nil
S.cd[VANISH] = true
S.overrides[EVIS] = CDG
Expect(CDG, "ST3", "Coup de Grace up (Eviscerate's button): consume it")
S.overrides[EVIS] = nil
S.cp = 6
Expect(DANCE, "ST4", "6 combo points + Secret Technique ready: Shadow Dance")
-- Shadow Blades 10s away: save Dance.
Engine.OnCast(rt, BLADES); S.cd[BLADES] = true
S.now = S.now + 82
Expect(EVIS, "ST7", "Shadow Blades within 10s: no Dance, Eviscerate")
S.now = S.now + 10                             -- Blades back
S.cd[BLADES] = nil
Expect(DANCE, "ST4", "Shadow Blades ready: Dance")
-- In Dance: Blades, Secret Technique, Shadowstrike.
S.buffs[DANCE_BUFF] = true; S.cd[DANCE] = true
Expect(BLADES, "ST5", "in Dance: Shadow Blades (hold line)")
Check(select(4, Suggest()).hold == 3, "Shadow Blades is holdable")
S.cd[BLADES] = true
Expect(ST, "ST6", "in Dance at 6+: Secret Technique")
S.cd[ST] = true; S.cp = 2
Expect(SHADOWSTRIKE, "ST9", "in Dance, low combo points: Shadowstrike (no Vanish)")

-- Shadow Blades held: Dance only from 2 charges (one kept back).
S.buffs[DANCE_BUFF] = nil
S.cd[ST] = nil; S.cd[BLADES] = nil; S.cd[DANCE] = nil; S.cp = 6
S.charges = { [DANCE] = 1 }
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
Expect(DANCE, "ST4", "1 Dance charge, Blades not held: Dance")
rt.holds[BLADES] = { count = 3, held = true }
Expect(EVIS, "ST7", "1 Dance charge, Blades held: keep it, Eviscerate")
S.charges[DANCE] = 2
Expect(DANCE, "ST4", "2 Dance charges, Blades held: Dance (one stays back)")
rt.holds[BLADES] = nil
C_Spell.GetSpellCharges, C_Spell.GetSpellCooldown = realCharges, realCooldown

-- AoE: Black Powder finisher, Shuriken Storm generator.
S.targets = 4
S.buffs[DANCE_BUFF] = true; S.cd[DANCE] = true; S.cd[BLADES] = true; S.cd[ST] = true
S.cp = 6
Expect(POWDER, "AOE7", "AoE 6+: Black Powder")
S.cp = 2
Expect(STORM, "AOE9", "AoE builder: Shuriken Storm")

print_real(fails == 0 and "ALL PASS" or (fails .. " failures"))
