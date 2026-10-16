-- Editor logic tests (no UI): expression formatting, builder form round
-- trips, and the APL store.
-- usage: lua tests/editor_logic_test.lua <addonDir>
local dir = arg[1]
local S, ns = dofile(dir .. "/tests/mock_wow.lua")(dir)
local Expr, Store, Engine = ns.Expr, ns.Store, ns.Engine
math.randomseed(42)

local fails = 0
local function Check(ok, msg)
    if not ok then fails = fails + 1; print_real("FAIL: " .. msg) end
end

-- Resolver giving every name a random value (sometimes unknown), read from
-- ctx so two compiled expressions can be compared on identical inputs.
local function RandomResolver(path)
    local key = table.concat(path, ".")
    return function(ctx)
        local v = ctx[key]
        if v == nil then
            local r = math.random()
            v = r < 0.15 and "nil" or (r < 0.5 and math.random(0, 1) or math.random(0, 25))
            ctx[key] = v
        end
        if v == "nil" then return nil end
        return v
    end
end

-- truthOnly: compare as conditions (true/false), which is all the builder
-- edits; otherwise exact values (the formatter must keep numbers intact).
local function SameMeaning(a, b, label, truthOnly)
    local fa, ea = Expr.Compile(a, RandomResolver)
    local fb, eb = Expr.Compile(b, RandomResolver)
    if not fa or not fb then
        Check(false, label .. ": compile failed: " .. tostring(ea or eb) .. "  [" .. a .. "] vs [" .. b .. "]")
        return
    end
    for _ = 1, 300 do
        local ctx = {}
        local x, y = fa(ctx), fb(ctx)
        if truthOnly then x, y = Expr.Truthy(x), Expr.Truthy(y) end
        if x ~= y then
            Check(false, label .. ": differs  [" .. a .. "] = " .. tostring(x) .. "  vs  [" .. b .. "] = " .. tostring(y))
            return
        end
    end
end

-- Every condition text in the built-in APL.
local builtin = Engine.BuiltinForSpec(269)
local texts = {}
for _, v in ipairs(builtin.variables) do texts[#texts + 1] = v.expr end
for _, group in ipairs({ builtin.timers, builtin.counters }) do
    for _, t in ipairs(group) do
        for _, trig in ipairs(t.triggers) do
            if trig.when then texts[#texts + 1] = trig.when end
            if trig.value then texts[#texts + 1] = trig.value end
        end
    end
end
for _, l in ipairs(builtin.lists) do
    for _, e in ipairs(l.entries) do if e.when then texts[#texts + 1] = e.when end end
end

-- Format: idempotent and meaning-preserving.
for _, t in ipairs(texts) do
    local ast = assert(Expr.Parse(t))
    local f1 = Expr.Format(ast)
    local f2 = Expr.Format(assert(Expr.Parse(f1)))
    Check(f1 == f2, "format not idempotent: " .. f1 .. " -> " .. f2)
    SameMeaning(t, f1, "format")
end
local extra = { "a-(b-c)", "a/(b*c)", "(a<b)=1", "!(a&b)|c", "-(a+b)*c", "a|b&c", "(a|b)&c", "max(a,b-1)<=c" }
for _, t in ipairs(extra) do SameMeaning(t, Expr.Format(assert(Expr.Parse(t))), "format extra") end

-- Builder forms: round trip keeps the meaning; count what fits.
local fit, total = 0, 0
for _, t in ipairs(texts) do
    total = total + 1
    local form = Expr.ToForm(t)
    if form then
        fit = fit + 1
        SameMeaning(t, Expr.FromForm(form), "form", true)
    end
end
print_real(string.format("builder fits %d of %d built-in condition texts", fit, total))
for _, t in ipairs({ "a", "!a", "a&b|c", "!(a<=2)", "a&(b|c)", "!(a|b)&!c", "a<=-1", "a=b", "!!a" }) do
    local form = Expr.ToForm(t)
    Check(form ~= nil, "should fit builder: " .. t)
    if form then SameMeaning(t, Expr.FromForm(form), "form case", true) end
end
for _, t in ipairs({ "a*3<=b", "max(a,b)", "1<a", "a+1" }) do
    Check(Expr.ToForm(t) == nil, "should not fit builder: " .. t)
end
Check(Expr.FromForm(Expr.ToForm("")) == "", "empty form -> empty text")
local incomplete = { k = "group", op = "and", items = { { k = "cond", ref = "" }, { k = "cond", ref = "a" } } }
Check(Expr.FromForm(incomplete) == "a", "incomplete rows are left out")

-- Store.
local copy = Store.Duplicate(builtin)
Check(copy.id == "user:1" and not copy.builtin, "duplicate gets a user id")
Check(copy.name == "Windwalker (copy)", "duplicate name: " .. copy.name)
copy.names.tiger_palm = 1
Check(builtin.names.tiger_palm == 100780, "duplicate is a deep copy")
copy.names.tiger_palm = 100780
local rtCopy = Engine.GetRuntime(copy)
Check(#rtCopy.errors == 0, "copy compiles cleanly")

Store.SetActive(269, copy.id)
Check(ns.GetActiveAPL() == Engine.GetRuntime(copy), "SetActive switches the running APL")
local rtBuiltin = Engine.GetRuntime(builtin)
for _ = 1, 200 do
    S.chi = math.random(0, 6)
    for _, id in ipairs(S.ALL_BUFFS) do S.buffs[id] = math.random() < 0.4 end
    S.targets = math.random(0, 6)
    local a, la = Engine.Evaluate(rtBuiltin)
    local b, lb = Engine.Evaluate(Engine.GetRuntime(copy))
    if a ~= b or la ~= lb then Check(false, "copy evaluates like the built-in"); break end
end

Check(Store.EnsureName(copy, 113656, "Fists of Fury") == "fists_of_fury", "existing name reused")
Check(Store.EnsureName(copy, 999001, "Mystic Touch") == "mystic_touch", "new name created")
Check(Store.EnsureName(copy, 999002, "Buff") == "buff_spell", "reserved word avoided")
Check(Store.EnsureName(copy, 999003, "Mystic Touch!") == "mystic_touch_2", "clashing name numbered")
Check(Store.MakeShortName("3 Combo Points") == "s_3_combo_points", "leading digit")
Check(Store.LookupSpell("fists of fury") == 113656, "lookup by name")
Check(Store.LookupSpell("113656") == 113656, "lookup by id")
Check(Store.LookupSpell("No Such Spell") == nil, "unknown spell")

Check(Store.CheckExpr == nil, "CheckExpr lives on Engine")
Check(Engine.CheckExpr(copy, "buff.hotjs.up&!variable.xuen_soon") == true, "valid expression")
local ok, err = Engine.CheckExpr(copy, "buff.hotjs.up&")
Check(not ok and err ~= nil, "syntax error reported")
ok, err = Engine.CheckExpr(copy, "buff.nope.up")
Check(not ok and err and err:find("nope"), "unknown name reported: " .. tostring(err))
Check(Engine.CheckExpr(copy, "") == true, "empty condition is valid")

Check(Engine.ValidPrefix("ST") and Engine.ValidPrefix("AOE") and not Engine.ValidPrefix("ABCD")
    and not Engine.ValidPrefix("") and not Engine.ValidPrefix(nil), "prefix validation")

local st, aoe = copy.lists[1], copy.lists[2]
Check(Store.RangeConflict(copy, st, 1, 3) ~= nil, "1-3 overlaps AOE 2+")
Check(Store.RangeConflict(copy, st, 1, 1) == nil, "1-1 is fine")
local l, why = Store.AddList(copy)
Check(l == nil and why ~= nil, "no free target count with an unbounded list")
aoe.max = 4
l = Store.AddList(copy)
Check(l and l.min == 5 and l.max == 5, "new list takes the next free count")
Check(#Engine.GetRuntime(copy).errors == 0, "copy still compiles after edits")

local blank = Store.New(269)
Check(#Engine.GetRuntime(blank).errors == 0, "new APL compiles")
Check(Engine.Evaluate(Engine.GetRuntime(blank)) == nil, "new APL suggests nothing")
Check(Store.Rename(blank, "Windwalker (copy)") and blank.name == "Windwalker (copy) 2", "rename keeps names unique")

Check(Store.Delete(copy), "delete user APL")
Check(Engine.ActiveDef(269) == builtin, "deleting the active APL falls back to the built-in")
Check(not Store.Delete(builtin), "built-ins can't be deleted")
Check(#Store.ListForSpec(269) == 2 and Store.ListForSpec(269)[1] == builtin, "list: built-in first")

print_real(fails == 0 and "ALL PASS" or (fails .. " failures"))
