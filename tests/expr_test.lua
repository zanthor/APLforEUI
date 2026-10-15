-- Expression parser/compiler unit tests.
-- usage: lua tests/expr_test.lua <addonDir>
local ns = {}
assert(loadfile(arg[1] .. "/Expression.lua"))("APLforEUI", ns)
local vals = { a = 1, b = 0, c = 5 }
local function resolve(path)
  local k = table.concat(path, ".")
  if k == "unknown" then return function() return nil end end
  if vals[k] == nil then error({ msg = "unknown name '" .. k .. "'" }, 0) end
  return function() return vals[k] end
end
local cases = {
  { "a&!b", 1 }, { "a&b|c>4", 1 }, { "!(c<=4)", 1 }, { "c-2*2", 1 }, { "(c-2)*2", 6 },
  { "max(1,3-a-a)", 1 }, { "min(c,2)", 2 }, { "unknown<=10", 0 }, { "!(unknown<10)", 1 },
  { "unknown+1", nil }, { "c/0", nil }, { "c==5", 1 }, { "c!=5", 0 }, { "-c<0", 1 }, { "1.5*2", 3 },
}
local fail = 0
for _, t in ipairs(cases) do
  local fn, e = ns.Expr.Compile(t[1], resolve)
  local v = fn and fn({})
  if v ~= t[2] then fail = fail + 1; print("FAIL", t[1], tostring(v), e) end
end
for _, bad in ipairs({ "a&", "(a", "a b", "a $ b", "nope", "foo(1,2)", "max(1)", "a..b", "" }) do
  local fn, e = ns.Expr.Compile(bad, resolve)
  if fn then fail = fail + 1; print("FAIL accepted", bad) else print("ok error: '" .. bad .. "' -> " .. e) end
end
print(fail == 0 and "ALL PASS" or (fail .. " failures"))
