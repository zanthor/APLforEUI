-- Import / export tests: round trip of the built-in APL (text and
-- behaviour), edge cases, and import errors.
-- usage: lua tests/exchange_test.lua <addonDir>
local dir = arg[1]
local S, ns = dofile(dir .. "/tests/mock_wow.lua")(dir)
local Exchange, Engine, Store = ns.Exchange, ns.Engine, ns.Store
math.randomseed(7)

local fails = 0
local function Check(ok, msg)
    if not ok then fails = fails + 1; print_real("FAIL: " .. msg) end
end

-- Deep equality, ignoring id/builtin (an import is a new user APL).
local SKIP = { id = true, builtin = true }
local function Same(a, b, path)
    if type(a) ~= type(b) then return false, path .. ": " .. type(a) .. " vs " .. type(b) end
    if type(a) ~= "table" then
        if a == b then return true end
        return false, path .. ": " .. tostring(a) .. " vs " .. tostring(b)
    end
    for k, v in pairs(a) do
        if not SKIP[k] then
            local ok, why = Same(v, b[k], path .. "." .. tostring(k))
            if not ok then return false, why end
        end
    end
    for k in pairs(b) do
        if not SKIP[k] and a[k] == nil then return false, path .. "." .. tostring(k) .. ": missing" end
    end
    return true
end

-- 1. Round trip of the built-in.
local builtin = Engine.BuiltinForSpec(269)
local text = Exchange.Export(builtin)
local def, errs = Exchange.Import(text)
Check(def ~= nil, "built-in export imports: " .. tostring(errs and errs[1]))
if def then
    Check(Exchange.Export(def) == text, "export is stable through import")
    -- Empty tables the built-in omits are fine; compare what it has.
    local probe = {}
    for k, v in pairs(builtin) do probe[k] = v end
    for _, k in ipairs({ "tts", "options" }) do if def[k] and not probe[k] then probe[k] = {} end end
    for k in pairs(def) do if probe[k] == nil and type(def[k]) == "table" and next(def[k]) == nil then probe[k] = {} end end
    local ok, why = Same(probe, def, "def")
    Check(ok, "imported APL equals the built-in: " .. tostring(why))
    Check(#Engine.GetRuntime(def).errors == 0, "imported APL compiles")

    -- Same suggestions through random states and casts.
    local a, b = Engine.GetRuntime(builtin), Engine.GetRuntime(def)
    local CASTS = { 100780, 113656, 100784, 107428, 152175, 392983, 443028, 123904, 1249625, 1272696, 101546 }
    local diff = 0
    for _ = 1, 3000 do
        S.now = S.now + 0.5 + math.random()
        S.chi = math.random(0, 6)
        for _, id in ipairs(S.ALL_BUFFS) do if math.random() < 0.25 then S.buffs[id] = not S.buffs[id] end end
        for _, id in ipairs({ 113656, 107428, 152175, 392983, 443028, 123904 }) do
            if math.random() < 0.3 then S.cd[id] = not S.cd[id] end
        end
        S.targets = math.random(0, 6)
        Engine.OnAura(a); Engine.OnAura(b)
        local x, lx = Engine.Evaluate(a)
        local y, ly = Engine.Evaluate(b)
        if x ~= y or lx ~= ly then diff = diff + 1 end
        local cast = CASTS[math.random(#CASTS)]
        Engine.OnCast(a, cast); Engine.OnCast(b, cast)
        ns.lastCastSpellID = cast
    end
    Check(diff == 0, "imported APL suggests exactly like the built-in (" .. diff .. " differences)")

    local saved = Store.AddImported(def)
    Check(saved.id:find("^user:") ~= nil, "import gets a user id")
    Check(saved.name ~= builtin.name, "import gets a unique name: " .. saved.name)
end

-- 2. Edge cases survive a round trip.
local edge = {
    name = "Edge, with comma = and equals", specID = 269,
    options = { rangeSpell = "a" },
    names = { a = 1, b_2 = 2 }, tts = { a = "Say # this, too" },
    variables = { { name = "v", expr = "max(1,min(2,3))>=counter.c" } },
    timers = { { name = "t", triggers = {
        { on = "aura_absent", spell = "a", action = "clear" },
        { on = "cast", spell = "b_2", action = "add", value = "max(1,2)", when = "!timer.t.up|(a=b_2)" },
    } } },
    counters = { { name = "c", initial = 0, min = -1, triggers = { { on = "cast", spell = "a", action = "reset" } } } },
    groups = {
        { name = "Burst, = hot", prefix = "BU", when = "!timer.t.up|combat.casts<3", lists = {
            { name = "Single Target", prefix = "S", min = 1, max = 1, entries = {
                { spell = "a" },
                { spell = "b_2", when = "variable.v&prev.a", enabled = false, usable = false },
            } },
        } },
        { name = "Default", prefix = "DF", lists = {
            { name = "Single-Target", prefix = "AOE", min = 2, max = 4, entries = {} },
            { name = "9 Lives", prefix = "L", min = 5, entries = {} },
        } },
    },
}
local edgeText = Exchange.Export(edge)
local back, e2 = Exchange.Import(edgeText:gsub("\n", "\r\n"))
Check(back ~= nil, "edge APL imports (with CRLF): " .. tostring(e2 and e2[1]))
if back then
    Check(Exchange.Export(back) == edgeText, "edge export stable")
    Check(back.name == edge.name, "name with comma and equals kept")
    Check(back.tts.a == "Say # this, too", "tts text kept verbatim")
    Check(back.timers[1].triggers[2].value == "max(1,2)", "comma inside parentheses kept")
    Check(back.timers[1].triggers[2].when == "!timer.t.up|(a=b_2)", "condition with = kept")
    local g1, g2 = back.groups[1], back.groups[2]
    Check(#back.groups == 2 and g1.name == "Burst, = hot" and g2.name == "Default", "groups kept in order")
    Check(g1.when == "!timer.t.up|combat.casts<3" and g2.when == nil, "group conditions kept")
    Check(g1.prefix == "BU" and g2.prefix == "DF", "group prefixes kept")
    Check(g1.lists[1].entries[2].enabled == false and g1.lists[1].entries[1].enabled == nil, "enabled flags")
    Check(g1.lists[1].entries[2].usable == false and g1.lists[1].entries[1].usable == nil, "usable opt-out kept")
    Check(back.counters[1].min == -1 and back.counters[1].max == nil, "counter limits")
    Check(g2.lists[2].min == 5 and g2.lists[2].max == nil, "open-ended range")
    Check(g2.lists[1].min == 2 and g2.lists[1].max == 4, "bounded range")
    Check(#g1.lists == 1 and #g2.lists == 2 and g2.lists[1].name == "Single-Target", "lists stay in their groups")
end

-- 3. Hand-written text: comments, spacing, actions before their list line.
local hand = [[
  # my apl
spec = 269
actions.st+=/a,if=prev.a
name.a=100780   # Tiger Palm
list.st.targets=1
]]
local h, he = Exchange.Import(hand)
Check(h ~= nil, "hand-written import: " .. tostring(he and he[1]))
if h then
    local hl = h.groups[1] and h.groups[1].lists[1]
    Check(#h.groups == 1 and h.groups[1].name == "Default" and h.groups[1].prefix == "DEF",
        "format-1 text becomes one Default group with prefix DEF")
    Check(hl and hl.prefix == "ST" and hl.name == "st" and hl.entries[1].when == "prev.a", "defaults for a bare list")
    Check(h.names.a == 100780, "trailing comment on a name line ignored")
    Check(h.name == "Imported APL", "default name")
end

-- 3b. Pasted through WoW edit boxes: every "|" doubled, maybe twice.
for _, mult in ipairs({ "||", "||||" }) do
    local pasted = text:gsub("|", mult)
    local d, pe = Exchange.Import(pasted)
    Check(d ~= nil and Exchange.Export(d) == text, "import survives pipes doubled to " .. mult .. ": " .. tostring(pe and pe[1]))
    if d then Check(#Engine.GetRuntime(d).errors == 0, "pipe-doubled import compiles cleanly") end
end

-- 4. Errors.
local function Fails(t, needle, label)
    local d, e = Exchange.Import(t)
    local joined = e and table.concat(e, " | ") or ""
    Check(d == nil and joined:find(needle, 1, true) ~= nil, label .. " -> " .. joined)
end
Fails("", "nothing to import", "empty")
Fails("# only a comment\n", "nothing to import", "comments only")
Fails("apl=x\n", "missing spec", "no spec")
Fails("spec=269\nbogus=1\n", "unknown key 'bogus'", "unknown key")
Fails("spec=269\nformat=9\n", "newer version", "newer format")
Fails("spec=269\nactions.st+=a\n", "continue with /", "missing slash")
Fails("spec=269\ntimer.t+=/cast=a\n", "no action", "trigger without action")
Fails("spec=269\ntimer.t+=/cast=a,sub=1\n", "unknown timer field 'sub'", "counter action on a timer")
Fails("spec=269\ntimer.t+=/when=a,set=1\n", "starts with cast=", "bad event")
Fails("spec=269\ncounter.c=initial=x\n", "counter fields", "bad counter field")
Fails("spec=269\nlist.st.targets=lots\n", "targets is like", "bad targets")
Fails("spec=269\nname.a=Tiger Palm\n", "needs a spell ID", "name without id")
Fails("this is not an apl\n", "expected key=value", "garbage")

print_real(fails == 0 and "ALL PASS" or (fails .. " failures"))
