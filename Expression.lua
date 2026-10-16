local _, ns = ...

-------------------------------------------------------------------------------
--  SimC-style condition expressions: text -> AST -> closure. Compiled once
--  (load or edit), never parsed in combat. Values are numbers (true = 1,
--  false = 0) or nil for "unknown": comparisons against nil are false and
--  arithmetic with nil stays nil, so a clock that never started can't read
--  as 0. See design.md "Expressions".
-------------------------------------------------------------------------------
local Expr = {}
ns.Expr = Expr

local function Truthy(v) return v ~= nil and v ~= 0 end
Expr.Truthy = Truthy

local TWO_CHAR = { ["<="] = true, [">="] = true, ["!="] = true, ["=="] = "=" }
local ONE_CHAR = "^[&|!=<>+%-*/(),.]"

local function Tokenize(src)
    local toks, i, n = {}, 1, #src
    while i <= n do
        local c = src:sub(i, i)
        if c:match("%s") then
            i = i + 1
        elseif c:match("%d") then
            local s, e = src:find("^%d+%.?%d*", i)
            toks[#toks + 1] = { t = "num", v = tonumber(src:sub(s, e)), pos = i }
            i = e + 1
        elseif c:match("[%a_]") then
            local s, e = src:find("^[%w_]+", i)
            toks[#toks + 1] = { t = "id", v = src:sub(s, e):lower(), pos = i }
            i = e + 1
        else
            local two = TWO_CHAR[src:sub(i, i + 1)]
            if two then
                toks[#toks + 1] = { t = two == true and src:sub(i, i + 1) or two, pos = i }
                i = i + 2
            elseif c:match(ONE_CHAR) then
                toks[#toks + 1] = { t = c, pos = i }
                i = i + 1
            else
                return nil, "unexpected '" .. c .. "' at " .. i
            end
        end
    end
    toks[#toks + 1] = { t = "eof", pos = n + 1 }
    return toks
end

-- Parse errors are thrown as { msg = ... } tables so they can be told apart
-- from real bugs inside the parser itself.
function Expr.Parse(src)
    local toks, err = Tokenize(src or "")
    if not toks then return nil, err end
    local pos = 1

    local function Fail(msg)
        error({ msg = msg .. " at " .. toks[pos].pos }, 0)
    end
    local function Shown(tk)
        return tostring(tk.v or tk.t)
    end
    local function Accept(t)
        if toks[pos].t == t then pos = pos + 1; return true end
        return false
    end
    local function Expect(t)
        if not Accept(t) then Fail("expected '" .. t .. "'") end
    end

    local ParseOr

    local function ParsePrimary()
        local tk = toks[pos]
        if tk.t == "num" then
            pos = pos + 1
            return { k = "num", v = tk.v }
        end
        if tk.t == "(" then
            pos = pos + 1
            local e = ParseOr()
            Expect(")")
            return e
        end
        if tk.t == "id" then
            pos = pos + 1
            if Accept("(") then
                local args = {}
                if not Accept(")") then
                    repeat args[#args + 1] = ParseOr() until not Accept(",")
                    Expect(")")
                end
                return { k = "call", name = tk.v, args = args }
            end
            local path = { tk.v }
            while Accept(".") do
                local seg = toks[pos]
                if seg.t ~= "id" then Fail("expected a name after '.'") end
                pos = pos + 1
                path[#path + 1] = seg.v
            end
            return { k = "ref", path = path }
        end
        if tk.t == "eof" then Fail("unexpected end of expression") end
        Fail("unexpected '" .. Shown(tk) .. "'")
    end

    local function ParseUnary()
        if Accept("!") then return { k = "not", a = ParseUnary() } end
        if Accept("-") then return { k = "neg", a = ParseUnary() } end
        return ParsePrimary()
    end

    local function ParseBinary(nextFn, ops, kind)
        return function()
            local a = nextFn()
            while ops[toks[pos].t] do
                local op = toks[pos].t
                pos = pos + 1
                a = { k = kind, op = op, a = a, b = nextFn() }
            end
            return a
        end
    end

    local ParseMul = ParseBinary(ParseUnary, { ["*"] = true, ["/"] = true }, "arith")
    local ParseAdd = ParseBinary(ParseMul, { ["+"] = true, ["-"] = true }, "arith")

    local CMP_OPS = { ["="] = true, ["!="] = true, ["<"] = true, ["<="] = true, [">"] = true, [">="] = true }
    local function ParseCmp()
        local a = ParseAdd()
        local op = toks[pos].t
        if CMP_OPS[op] then
            pos = pos + 1
            return { k = "cmp", op = op, a = a, b = ParseAdd() }
        end
        return a
    end

    local ParseAnd = ParseBinary(ParseCmp, { ["&"] = true }, "and")
    ParseOr = ParseBinary(ParseAnd, { ["|"] = true }, "or")

    local ok, res = pcall(function()
        local e = ParseOr()
        if toks[pos].t ~= "eof" then Fail("unexpected '" .. Shown(toks[pos]) .. "'") end
        return e
    end)
    if ok then return res end
    if type(res) == "table" then return nil, res.msg end
    error(res, 0)
end

local CMP = {
    ["="]  = function(x, y) return x == y end,
    ["!="] = function(x, y) return x ~= y end,
    ["<"]  = function(x, y) return x < y end,
    ["<="] = function(x, y) return x <= y end,
    [">"]  = function(x, y) return x > y end,
    [">="] = function(x, y) return x >= y end,
}

local ARITH = {
    ["+"] = function(x, y) return x + y end,
    ["-"] = function(x, y) return x - y end,
    ["*"] = function(x, y) return x * y end,
    ["/"] = function(x, y) if y == 0 then return nil end return x / y end,
}

local CALLS = { max = math.max, min = math.min }

-- resolve(path) returns a closure (ctx) -> value for a dotted name, or
-- throws { msg = ... } for an unknown one.
local function CompileNode(node, resolve)
    local k = node.k
    if k == "num" then
        local v = node.v
        return function() return v end
    elseif k == "ref" then
        return resolve(node.path)
    elseif k == "not" then
        local a = CompileNode(node.a, resolve)
        return function(c) if Truthy(a(c)) then return 0 end return 1 end
    elseif k == "neg" then
        local a = CompileNode(node.a, resolve)
        return function(c) local v = a(c); return v and -v end
    elseif k == "and" then
        local a, b = CompileNode(node.a, resolve), CompileNode(node.b, resolve)
        return function(c) if Truthy(a(c)) and Truthy(b(c)) then return 1 end return 0 end
    elseif k == "or" then
        local a, b = CompileNode(node.a, resolve), CompileNode(node.b, resolve)
        return function(c) if Truthy(a(c)) or Truthy(b(c)) then return 1 end return 0 end
    elseif k == "cmp" then
        local a, b, f = CompileNode(node.a, resolve), CompileNode(node.b, resolve), CMP[node.op]
        return function(c)
            local x, y = a(c), b(c)
            if x == nil or y == nil then return 0 end
            return f(x, y) and 1 or 0
        end
    elseif k == "arith" then
        local a, b, f = CompileNode(node.a, resolve), CompileNode(node.b, resolve), ARITH[node.op]
        return function(c)
            local x, y = a(c), b(c)
            if x == nil or y == nil then return nil end
            return f(x, y)
        end
    elseif k == "call" then
        local f = CALLS[node.name]
        if not f then error({ msg = "unknown function '" .. node.name .. "'" }, 0) end
        if #node.args ~= 2 then error({ msg = node.name .. "() takes 2 arguments" }, 0) end
        local a, b = CompileNode(node.args[1], resolve), CompileNode(node.args[2], resolve)
        return function(c)
            local x, y = a(c), b(c)
            if x == nil or y == nil then return nil end
            return f(x, y)
        end
    end
    error("unknown node kind " .. tostring(k))
end

-- Text -> closure, or nil plus an error message.
function Expr.Compile(src, resolve)
    local ast, err = Expr.Parse(src)
    if not ast then return nil, err end
    local ok, res = pcall(CompileNode, ast, resolve)
    if ok then return res end
    if type(res) == "table" then return nil, res.msg end
    error(res, 0)
end

-------------------------------------------------------------------------------
--  AST -> text, with only the parentheses precedence needs. Compact like the
--  built-in APLs ("a&!b"), so builder output and hand-written text match.
-------------------------------------------------------------------------------
local function Prec(node)
    local k = node.k
    if k == "or" then return 1 end
    if k == "and" then return 2 end
    if k == "cmp" then return 3 end
    if k == "arith" then return (node.op == "+" or node.op == "-") and 4 or 5 end
    if k == "not" or k == "neg" then return 6 end
    return 7
end

local function FormatNumber(v)
    if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
    return tostring(v)
end

local function Format(node)
    local k = node.k
    if k == "num" then return FormatNumber(node.v) end
    if k == "ref" then return table.concat(node.path, ".") end
    if k == "call" then
        local args = {}
        for i, a in ipairs(node.args) do args[i] = Format(a) end
        return node.name .. "(" .. table.concat(args, ",") .. ")"
    end
    if k == "not" or k == "neg" then
        local inner = Format(node.a)
        if Prec(node.a) < 6 then inner = "(" .. inner .. ")" end
        return (k == "not" and "!" or "-") .. inner
    end
    local p = Prec(node)
    local op = (k == "and" and "&") or (k == "or" and "|") or node.op
    local l, r = Format(node.a), Format(node.b)
    local lp, rp = Prec(node.a), Prec(node.b)
    -- & and | are associative; everything else needs the right side wrapped
    -- at equal precedence, and comparisons don't chain at all.
    if lp < p or (k == "cmp" and lp == p) then l = "(" .. l .. ")" end
    if rp < p or (rp == p and k ~= "and" and k ~= "or") then r = "(" .. r .. ")" end
    return l .. op .. r
end

function Expr.Format(ast) return Format(ast) end

-------------------------------------------------------------------------------
--  Builder form: what the point-and-click builder edits. A form is a group
--    { k = "group", op = "and"|"or", neg = bool, items = { item, ... } }
--  and an item is a nested group or a row
--    { k = "cond", neg = bool, ref = "buff.hotjs.up", op = "<="|nil, value = "2"|nil }
--  Text that doesn't fit (arithmetic, functions, a number on the left of a
--  comparison) has no form; the editor then keeps it text-only.
-------------------------------------------------------------------------------
local function IsValue(n)
    return n.k == "num" or n.k == "ref" or (n.k == "neg" and n.a.k == "num")
end

local ToItem

local function Flatten(node, op, items)
    if node.k == op then
        return Flatten(node.a, op, items) and Flatten(node.b, op, items)
    end
    local item = ToItem(node)
    if not item then return false end
    items[#items + 1] = item
    return true
end

ToItem = function(node)
    local k = node.k
    if k == "and" or k == "or" then
        local g = { k = "group", op = k, neg = false, items = {} }
        if not Flatten(node, k, g.items) then return nil end
        return g
    elseif k == "not" then
        local item = ToItem(node.a)
        if not item then return nil end
        item.neg = not item.neg
        return item
    elseif k == "ref" then
        return { k = "cond", neg = false, ref = Format(node) }
    elseif k == "cmp" and node.a.k == "ref" and IsValue(node.b) then
        return { k = "cond", neg = false, ref = Format(node.a), op = node.op, value = Format(node.b) }
    end
    return nil
end

-- Text -> form. Returns nil plus a reason when the text has no form
-- (parse error, or a shape the builder can't show).
function Expr.ToForm(src)
    if not src or src:match("^%s*$") then
        return { k = "group", op = "and", neg = false, items = {} }
    end
    local ast, err = Expr.Parse(src)
    if not ast then return nil, err end
    local item = ToItem(ast)
    if not item then return nil, "uses arithmetic or functions; edit it as text" end
    if item.k == "group" and not item.neg then return item end
    return { k = "group", op = "and", neg = false, items = { item } }
end

-- Returns text and its precedence (for the parent's parenthesis choice).
-- Incomplete rows (no read picked) and empty groups are left out.
local function ItemText(item)
    local text, prec
    if item.k == "cond" then
        if not item.ref or item.ref == "" then return nil end
        if item.op and item.value and item.value ~= "" then
            text, prec = item.ref .. item.op .. item.value, 3
        else
            text, prec = item.ref, 7
        end
    else
        local parts, partPrec = {}, 7
        local myPrec = item.op == "or" and 1 or 2
        for _, child in ipairs(item.items or {}) do
            local t, p = ItemText(child)
            if t then
                if p < myPrec then t, p = "(" .. t .. ")", 7 end
                parts[#parts + 1] = t
                partPrec = p
            end
        end
        if #parts == 0 then return nil end
        if #parts == 1 then
            text, prec = parts[1], partPrec
        else
            text, prec = table.concat(parts, item.op == "or" and "|" or "&"), myPrec
        end
    end
    if item.neg then
        if prec < 6 then text = "(" .. text .. ")" end
        text, prec = "!" .. text, 6
    end
    return text, prec
end

-- Form -> text ("" for an empty form, meaning "always").
function Expr.FromForm(form)
    return (ItemText(form)) or ""
end
