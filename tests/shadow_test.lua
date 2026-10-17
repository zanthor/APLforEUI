-- Built-in Shadow Priest (Archon) APL: compiles, and suggests what the
-- Method guide says in representative situations.
-- usage: lua tests/shadow_test.lua <addonDir>
local dir = arg[1]
local S, ns = dofile(dir .. "/tests/mock_wow.lua")(dir)
local Engine = ns.Engine

local fails = 0
local function Check(ok, msg)
    if not ok then fails = fails + 1; print_real("FAIL: " .. msg) end
end

GetSpecializationInfo = function() return 258 end
local SHADOWFORM, VT, TS, HALO, VF, PI = 232698, 34914, 1227280, 120644, 228260, 10060
local SWM, MB, MF, VF_BUFF, MFI = 335467, 8092, 15407, 194249, 391401
local KICK = 15487

-- Tentacle Slam has 2 charges: S.charges[id] = 0 / 1 / 2.
S.charges = { [TS] = 2 }
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
local realPower = UnitPower
S.insanity = 0
UnitPower = function(u, pt) if pt == 13 then return S.insanity end return realPower(u, pt) end
-- Buff reads go through the CDM mock: only these IDs exist there.
for _, id in ipairs({ SHADOWFORM, VT, SWM, VF_BUFF, MFI }) do S.ALL_BUFFS[#S.ALL_BUFFS + 1] = id end

local rt = ns.GetActiveAPL()
Check(rt and rt.name == "Shadow - Archon (default)", "Shadow spec runs the Archon built-in")
Check(rt and #rt.errors == 0, "compiles: " .. tostring(rt and rt.errors[1]))
Check(Engine.IsFreeCast(rt, KICK), "Silence is a free cast")

local function Suggest() return Engine.Evaluate(rt) end
local function Fight(casts, seconds)
    if casts == nil then ns.combatStart, ns.combatCasts = nil, nil
    else ns.combatStart, ns.combatCasts = S.now - seconds, casts end
end
S.targets = 1
wipe(S.buffs); wipe(S.cd)
ns.lastCastSpellID = nil

-- Out of combat without Shadowform: Shadowform first.
Fight(nil)
local id, label = Suggest()
Check(id == SHADOWFORM and label == "O1", "pre-pull: Shadowform (" .. tostring(label) .. ")")
S.buffs[SHADOWFORM] = true

-- Opener: Tentacle Slam, Halo, Voidform, Power Infusion, Madness, Void Volley.
id, label = Suggest()
Check(id == TS and label == "O2", "opener: Tentacle Slam (" .. tostring(label) .. ")")
local function Step(spell, expectLabel, after)
    Fight((ns.combatCasts or 0) + 1, 2)
    local sid, l = Suggest()
    Check(sid == spell and l == expectLabel, "opener: " .. expectLabel .. " " .. spell .. " got " .. tostring(sid) .. " (" .. tostring(l) .. ")")
    if after then after() end
end
Fight(0, 0)
S.charges[TS] = 1; Engine.OnCast(rt, TS); S.buffs[VT] = true
Step(HALO, "O3", function() S.cd[HALO] = true end)
Step(VF, "O4", function() S.buffs[VF_BUFF] = true end)
Step(PI, "O5", function() S.cd[PI] = true end)
Step(SWM, "O6", function() Engine.OnCast(rt, SWM) end)
Step(VF, "O7")                                -- Void Volley

-- Default: VT refresh at < 6.3s, via Tentacle Slam first.
Fight(10, 20)
S.cd[VF] = true
local _, rem = Engine.EvalText(rt, "timer.vt.remains")
Check(rem and rem > 20, "VT timer set by Tentacle Slam: " .. tostring(rem))
S.now = S.now + 16                            -- ~5s left
id, label = Suggest()
Check(id == TS and label == "P2", "VT in pandemic: Tentacle Slam (" .. tostring(label) .. ")")
S.charges[TS] = 0
id, label = Suggest()
Check(id == VT and label == "P3", "no Slam charge: Vampiric Touch (" .. tostring(label) .. ")")
Engine.OnCast(rt, VT)

-- Madness: recast with a GCD or less left, or when Insanity is near capping.
Engine.OnCast(rt, SWM)
Check(Suggest() ~= SWM, "Madness fresh (6s): not recast")
S.insanity = 90
id, label = Suggest()
Check(id == SWM and label == "P7", "Insanity capping: Madness (" .. tostring(label) .. ")")
S.insanity = 20
S.now = S.now + 4.6
id, label = Suggest()
Check(id == SWM and label == "P7", "Madness about to expire: recast (" .. tostring(label) .. ")")
Engine.OnCast(rt, SWM)
-- Then Mind Blast, Mind Flay: Insanity, Void Volley, Mind Flay.
id = Suggest()
Check(id == MB, "Mind Blast")
S.cd[MB] = true
S.buffs[MFI] = true
id, label = Suggest()
Check(id == MF and label == "P11", "Mind Flay: Insanity during Madness (" .. tostring(label) .. ")")
S.buffs[MFI] = nil
S.cd[VF] = nil
id, label = Suggest()
Check(id == VF and label == "P12", "Void Volley in Voidform (" .. tostring(label) .. ")")
S.cd[VF] = true
id, label = Suggest()
Check(id == MF and label == "P13", "Mind Flay filler (" .. tostring(label) .. ")")
-- Two Slam charges: spend before capping (above Mind Blast).
S.charges[TS] = 2; S.cd[MB] = nil
id, label = Suggest()
Check(id == TS and label == "P8", "Slam at 2 charges before Mind Blast (" .. tostring(label) .. ")")

-- Target switch: the Cooldown Manager shows Vampiric Touch only for the
-- current target; a fresh timer doesn't hide a missing dot.
S.charges[TS] = 0
Engine.OnCast(rt, VT)                          -- timer: 21s
ns.lastCastSpellID = VT
S.buffs[VT] = nil                              -- icon not updated yet
Check(Suggest() ~= VT, "just cast Vampiric Touch: icon lag isn't 'missing'")
ns.lastCastSpellID = MB                        -- later, new target, no dot
id, label = Suggest()
Check(id == VT and label == "P3", "switched to an undotted target: Vampiric Touch (" .. tostring(label) .. ")")
S.buffs[VT] = true
Check(Suggest() ~= VT, "dotted target, fresh timer: no Vampiric Touch")

print_real(fails == 0 and "ALL PASS" or (fails .. " failures"))
