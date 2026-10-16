-- Offline parity harness: mocks the WoW API, loads the addon in TOC order,
-- and compares the frozen legacy Lua APL (tests/legacy_Monk_Windwalker.lua)
-- against the data APL (Defaults/) on random states and cast sequences.
-- usage: lua tests/parity_sim.lua <addonDir> [runs] [steps] [seed]
-- env:   EAGER=1  start the legacy proc clocks every step, removing its one
--                 known quirk (lazy start); expect 0 mismatches with it.
--        DBG="expr;expr"  print these expressions at each new mismatch.
local dir, RUNS, STEPS, SEED = arg[1], tonumber(arg[2] or 200), tonumber(arg[3] or 300), tonumber(arg[4] or 12345)
math.randomseed(SEED)

local S, ns, printed = dofile(dir .. "/tests/mock_wow.lua")(dir)
local ZENITH = 1249625
local ALL_BUFFS = S.ALL_BUFFS

local spec
ns.RegisterSpec = function(s) spec = s end
assert(loadfile(dir .. "/tests/legacy_Monk_Windwalker.lua"))("APLforEUI", ns)
for _, p in ipairs(printed) do print_real("addon printed: " .. p) end

local rt = ns.GetActiveAPL()
assert(spec and rt, "spec or apl missing")
assert(#rt.errors == 0, "compile errors")

local T = {
    tiger_palm = 100780, fists_of_fury = 113656, blackout_kick = 100784, rising_sun_kick = 107428,
    rushing_wind_kick = 467307, wdp = 152175, sotw = 392983, conduit = 443028, xuen = 123904,
    zenith = ZENITH, stomp = 1272696, sck = 101546, slicing_winds = 1217413,
}
local CD_SPELLS = { T.fists_of_fury, T.rising_sun_kick, T.rushing_wind_kick, T.wdp, T.sotw, T.conduit, T.xuen, T.slicing_winds }
local TALENTS = { 152175, 392983, 1249832, 1250041, 442719, 292986, 392982, 1261849, 1217413 }
local CASTS = { T.tiger_palm, T.fists_of_fury, T.blackout_kick, T.rising_sun_kick, T.wdp, T.sotw, T.conduit,
    T.xuen, T.zenith, T.stomp, T.sck, T.slicing_winds }

DEBUG_EXPRS = os.getenv('DBG') and {} or nil
if DEBUG_EXPRS then for e in os.getenv('DBG'):gmatch('[^;]+') do DEBUG_EXPRS[#DEBUG_EXPRS+1]=e end end
local mism, samples, byKey, examples = 0, 0, {}, {}
local function R(p) return math.random() < p end

for run = 1, RUNS do
    -- fresh session
    ns.StopTracking(); ns.StartTracking(); spec.OnReset()
    -- Same known start for both engines: the old one never resets its
    -- Zenith/Stomp/Xuen clocks, so cast both, then let everything expire.
    for _, c in ipairs({ T.zenith, T.xuen }) do spec.OnCast(c); ns.Engine.OnCast(rt, c) end
    S.now = S.now + 1000
    ns.lastCastSpellID = nil
    wipe(S.buffs); wipe(S.cd); wipe(S.talents); wipe(S.overrides)
    for _, t in ipairs(TALENTS) do S.talents[t] = R(0.5) end
    if R(0.5) then S.overrides[T.rising_sun_kick] = T.rushing_wind_kick end
    S.zenCharges = 2
    for step = 1, STEPS do
        S.now = S.now + 0.5 + math.random() * 1.5
        S.chi = math.random(0, 6)
        for _, id in ipairs(ALL_BUFFS) do
            if R(0.25) then S.buffs[id] = not S.buffs[id] end
        end
        for _, id in ipairs(CD_SPELLS) do
            if R(0.3) then S.cd[id] = not S.cd[id] end
        end
        if R(0.1) then S.zenCharges = math.random(0, 2) end
        S.overrides[T.xuen] = S.cd[T.xuen] and R(0.7) and T.conduit or nil
        S.targets = math.random(0, 6)
        ns.currentChannelSpellID = R(0.1) and T.conduit or nil

        spec.OnAura(); ns.Engine.OnAura(rt)
        if os.getenv("EAGER") then ns.slashCommands.stacks() end

        local oldID, oldStep = spec.Evaluate()
        local newID, newLabel = ns.Engine.Evaluate(rt)
        local a = oldID and ns.ResolveOverride(oldID)
        samples = samples + 1
        if a ~= newID then
            mism = mism + 1
            local key = "old " .. tostring(oldStep) .. " " .. tostring(a) .. " / new " .. tostring(newLabel) .. " " .. tostring(newID)
            byKey[key] = (byKey[key] or 0) + 1
            if not examples[key] and DEBUG_EXPRS then
                for _, e in ipairs(DEBUG_EXPRS) do
                    local ok, v = ns.Engine.EvalText(rt, e)
                    print_real("   [" .. key .. "] " .. e .. " = " .. tostring(v))
                end
            end
            if not examples[key] then
                examples[key] = string.format("chi=%d targets=%d last=%s zenCharges=%d buffs[hotjs=%s zen=%s cb=%s dcj=%s ur=%s lust=%s]",
                    S.chi, S.targets, tostring(ns.lastCastSpellID), S.zenCharges,
                    tostring(S.buffs[443294]), tostring(S.buffs[ZENITH]), tostring(S.buffs[137384]),
                    tostring(S.buffs[325202]), tostring(S.buffs[1297033]), tostring(S.buffs[2825]))
            end
        end

        local cast = (R(0.7) and a) or CASTS[math.random(#CASTS)]
        spec.OnCast(cast); ns.Engine.OnCast(rt, cast)
        ns.lastCastSpellID = cast
    end
end

print_real(string.format("samples=%d mismatches=%d (%.2f%%)", samples, mism, mism / samples * 100))
local keys = {}
for k in pairs(byKey) do keys[#keys + 1] = k end
table.sort(keys, function(x, y) return byKey[x] > byKey[y] end)
for i = 1, math.min(20, #keys) do
    print_real(byKey[keys[i]] .. "x  " .. keys[i])
    print_real("      e.g. " .. examples[keys[i]])
end
