local _, ns = ...

-------------------------------------------------------------------------------
--  Import / export as SimC-style text: one record per line, readable and
--  diffable. Conditions are stored text already, so they are written as-is.
--
--    # comment                         (ignored, as are blank lines)
--    format=1
--    apl=<name>                        spec=<specID>
--    option.no_repeat_last_cast=1      option.range_spell=<short name>
--    name.<short name>=<spell ID>      tts.<short name>=<spoken text>
--    variable.<name>=<expression>      (in order)
--    timer.<name>=                     (declares; triggers follow)
--    counter.<name>=initial=2,min=0,max=2
--    timer|counter.<name>+=/<event>=<spell>,<action>[=<value>][,if=<cond>]
--        event: cast | aura_present | aura_absent
--        action: set | start | add | clear (timers); set | add | sub | reset
--    group.<gkey>=<name>               group.<gkey>.if=<cond>   (in priority order)
--    group.<gkey>.prefix=<1-3 chars>   (made from the name if missing)
--    list.<key>=<display name>         list.<key>.prefix=ST     list.<key>.group=<gkey>
--    list.<key>.targets=1 | 2-4 | 5+
--    actions.<key>+=/<spell>[,if=<cond>][,enabled=0][,usable=0]
--  Format 1 had no groups: its lists import as one "Default" group.
--
--  Fields split on commas outside parentheses, so max(a,b) stays intact.
--  No UI code here.
-------------------------------------------------------------------------------
local Exchange = {}
ns.Exchange = Exchange

local FORMAT = 2
local NO_VALUE = { clear = true, reset = true }
local EVENTS = { cast = true, aura_present = true, aura_absent = true }
local TIMER_ACTIONS = { set = true, start = true, add = true, clear = true }
local COUNTER_ACTIONS = { set = true, add = true, sub = true, reset = true }

-------------------------------------------------------------------------------
--  Export
-------------------------------------------------------------------------------

-- "ST" / "Single Target" -> "st" / "single_target", unique among taken.
local function ListKey(name, taken)
    local base = (name or ""):lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    if base == "" or base:match("^%d") then base = "list" .. (base ~= "" and ("_" .. base) or "") end
    local key, n = base, 2
    while taken[key] do key = base .. "_" .. n; n = n + 1 end
    taken[key] = true
    return key
end

local function Targets(list)
    if not list.max then return list.min .. "+" end
    if list.max == list.min then return tostring(list.min) end
    return list.min .. "-" .. list.max
end

local function TriggerLine(kind, name, trig)
    local parts = { tostring(trig.on) .. "=" .. tostring(trig.spell) }
    if NO_VALUE[trig.action] then
        parts[#parts + 1] = tostring(trig.action)
    else
        parts[#parts + 1] = tostring(trig.action) .. "=" .. tostring(trig.value or "")
    end
    if trig.when and trig.when ~= "" then parts[#parts + 1] = "if=" .. trig.when end
    return kind .. "." .. name .. "+=/" .. table.concat(parts, ",")
end

function Exchange.Export(def)
    local out = {}
    local function L(s) out[#out + 1] = s end
    L("# APL for EUI export (format " .. FORMAT .. "). Lines starting with # are ignored.")
    if GetSpecializationInfoByID then
        local _, specName, _, _, _, _, className = GetSpecializationInfoByID(def.specID)
        if specName then L("# " .. specName .. " " .. (className or "")) end
    end
    L("format=" .. FORMAT)
    L("apl=" .. def.name)
    L("spec=" .. def.specID)

    local opt = def.options or {}
    if opt.noRepeatLastCast then L("option.no_repeat_last_cast=1") end
    if opt.rangeSpell then L("option.range_spell=" .. opt.rangeSpell) end

    local names = {}
    for name in pairs(def.names or {}) do names[#names + 1] = name end
    table.sort(names)
    L("")
    for _, name in ipairs(names) do
        local id = def.names[name]
        L("name." .. name .. "=" .. id .. "   # " .. (ns.SpellName and ns.SpellName(id) or ""))
    end
    for _, name in ipairs(names) do
        local text = def.tts and def.tts[name]
        if text then L("tts." .. name .. "=" .. text) end
    end

    if def.variables and #def.variables > 0 then L("") end
    for _, v in ipairs(def.variables or {}) do L("variable." .. v.name .. "=" .. (v.expr or "")) end

    for _, t in ipairs(def.timers or {}) do
        L("")
        L("timer." .. t.name .. "=")
        for _, trig in ipairs(t.triggers or {}) do L(TriggerLine("timer", t.name, trig)) end
    end
    for _, c in ipairs(def.counters or {}) do
        L("")
        local params = "initial=" .. (c.initial or 0) .. ",min=" .. (c.min or 0)
        if c.max then params = params .. ",max=" .. c.max end
        L("counter." .. c.name .. "=" .. params)
        for _, trig in ipairs(c.triggers or {}) do L(TriggerLine("counter", c.name, trig)) end
    end

    local taken, groupTaken = {}, {}
    for _, group in ipairs(def.groups or {}) do
        local gkey = ListKey(group.name, groupTaken)
        L("")
        L("group." .. gkey .. "=" .. group.name)
        L("group." .. gkey .. ".prefix=" .. tostring(group.prefix))
        if group.when and group.when ~= "" then L("group." .. gkey .. ".if=" .. group.when) end
        for _, list in ipairs(group.lists or {}) do
            local key = ListKey(list.name, taken)
            L("")
            L("list." .. key .. "=" .. list.name)
            L("list." .. key .. ".group=" .. gkey)
            L("list." .. key .. ".prefix=" .. tostring(list.prefix))
            L("list." .. key .. ".targets=" .. Targets(list))
            for _, e in ipairs(list.entries or {}) do
                local line = "actions." .. key .. "+=/" .. tostring(e.spell)
                if e.when and e.when ~= "" then line = line .. ",if=" .. e.when end
                if e.enabled == false then line = line .. ",enabled=0" end
                if e.usable == false then line = line .. ",usable=0" end
                L(line)
            end
        end
    end
    return table.concat(out, "\n") .. "\n"
end

-------------------------------------------------------------------------------
--  Import
-------------------------------------------------------------------------------

-- Splits on commas outside parentheses.
local function SplitTop(s)
    local parts, depth, start = {}, 0, 1
    for i = 1, #s do
        local c = s:sub(i, i)
        if c == "(" then depth = depth + 1
        elseif c == ")" then depth = depth - 1
        elseif c == "," and depth == 0 then
            parts[#parts + 1] = s:sub(start, i - 1)
            start = i + 1
        end
    end
    parts[#parts + 1] = s:sub(start)
    return parts
end

-- "key=value" -> key, value (value may itself contain "="); "key" -> key, nil.
local function KV(part)
    local k, v = part:match("^%s*([%w_]+)%s*=(.*)$")
    if k then return k, (v:match("^%s*(.-)%s*$")) end
    return (part:match("^%s*(.-)%s*$")), nil
end

local function Trim(s) return (s:match("^%s*(.-)%s*$")) end

-- A trailing "   # comment" on a value (names are exported with the spell's
-- name that way). Only on lines whose value can't contain "#".
local function StripComment(v) return Trim((v:gsub("%s+#.*$", ""))) end

local function ParseTargets(v)
    local a = v:match("^(%d+)%+$")
    if a then return tonumber(a), nil end
    local lo, hi = v:match("^(%d+)%-(%d+)$")
    if lo then return tonumber(lo), tonumber(hi) end
    a = v:match("^(%d+)$")
    if a then return tonumber(a), tonumber(a) end
    return nil
end

-- Returns def (a new user APL table, without an id yet) or nil, errors.
-- Problems inside conditions (unknown names, ...) are not import errors:
-- the editor's Problems list shows them once imported.
function Exchange.Import(text)
    -- WoW edit boxes and chat double "|" (an escape character), possibly
    -- more than once on the way here; the format never contains "||".
    text = (text or ""):gsub("|+", "|")
    local def = {
        name = "Imported APL", options = {}, names = {}, tts = {},
        variables = {}, timers = {}, counters = {}, groups = {},
    }
    local errors = {}
    local blocks = { timer = {}, counter = {} }
    local lists, listOrder = {}, {}
    local groups, groupOrder = {}, {}

    local function Group(key)
        local g = groups[key]
        if not g then
            g = { name = key, lists = {} }
            groups[key] = g
            groupOrder[#groupOrder + 1] = g
        end
        return g
    end
    local sawAny = false

    local function Err(n, msg) errors[#errors + 1] = "line " .. n .. ": " .. msg end

    local function Block(kind, name)
        local b = blocks[kind][name]
        if not b then
            b = { name = name, triggers = {} }
            if kind == "counter" then b.initial, b.min = 0, 0 end
            blocks[kind][name] = b
            local arr = kind == "timer" and def.timers or def.counters
            arr[#arr + 1] = b
        end
        return b
    end

    local function List(key)
        local l = lists[key]
        if not l then
            l = { name = key, prefix = key:sub(1, 3):upper(), min = 1, max = 1, entries = {} }
            lists[key] = l
            listOrder[#listOrder + 1] = l
        end
        return l
    end

    local function Trigger(n, kind, b, val)
        local parts = SplitTop(val)
        local ev, spell = KV(parts[1] or "")
        if not EVENTS[ev] or not spell or spell == "" then
            Err(n, "a trigger starts with cast=, aura_present= or aura_absent= and a spell name")
            return
        end
        local trig = { on = ev, spell = spell }
        local actions = kind == "timer" and TIMER_ACTIONS or COUNTER_ACTIONS
        for i = 2, #parts do
            local k, v = KV(parts[i])
            if k == "if" then
                trig.when = v
            elseif actions[k] then
                if trig.action then Err(n, "more than one action") return end
                trig.action = k
                if not NO_VALUE[k] then
                    if not v or v == "" then Err(n, "'" .. k .. "' needs a value") return end
                    trig.value = v
                end
            else
                Err(n, "unknown " .. kind .. " field '" .. tostring(k) .. "'")
                return
            end
        end
        if not trig.action then Err(n, "trigger has no action") return end
        b.triggers[#b.triggers + 1] = trig
    end

    local n = 0
    for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
        n = n + 1
        local line = Trim(raw:gsub("\r", ""))
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local key, op, val = line:match("^([%w_%.]+)%s*(%+?=)%s*(.*)$")
            if not key then
                Err(n, "expected key=value")
            else
                sawAny = true
                local head, a, b = key:match("^([%w_]+)%.?([%w_]*)%.?([%w_]*)$")
                if op == "+=" then
                    if val:sub(1, 1) ~= "/" then Err(n, "'+=' lines continue with /") val = nil
                    else val = val:sub(2) end
                end
                if not head then
                    Err(n, "bad key '" .. key .. "'")
                elseif val == nil then
                    -- already reported
                elseif key == "format" then
                    local f = tonumber(val)
                    if not f then Err(n, "format must be a number")
                    elseif f > FORMAT then Err(n, "made by a newer version of APL for EUI (format " .. f .. ")") end
                elseif key == "apl" then
                    if val ~= "" then def.name = val end
                elseif key == "spec" then
                    def.specID = tonumber(StripComment(val))
                    if not def.specID then Err(n, "spec must be a spec ID number") end
                elseif key == "option.no_repeat_last_cast" then
                    def.options.noRepeatLastCast = StripComment(val) == "1" or nil
                elseif key == "option.range_spell" then
                    def.options.rangeSpell = StripComment(val)
                elseif head == "name" and a ~= "" and b == "" then
                    local id = tonumber(StripComment(val))
                    if not id then Err(n, "name." .. a .. " needs a spell ID")
                    elseif not a:match("^[%a_][%w_]*$") then Err(n, "bad short name '" .. a .. "'")
                    else def.names[a] = id end
                elseif head == "tts" and a ~= "" and b == "" then
                    if val ~= "" then def.tts[a] = val end
                elseif head == "variable" and a ~= "" and b == "" then
                    def.variables[#def.variables + 1] = { name = a, expr = val }
                elseif (head == "timer" or head == "counter") and a ~= "" and b == "" then
                    local blk = Block(head, a)
                    if op == "+=" then
                        Trigger(n, head, blk, val)
                    elseif head == "counter" and val ~= "" then
                        for _, part in ipairs(SplitTop(val)) do
                            local k, v = KV(part)
                            local num = tonumber(v)
                            if (k == "initial" or k == "min" or k == "max") and num then blk[k] = num
                            else Err(n, "counter fields are initial=, min= and max= numbers") end
                        end
                    end
                elseif head == "group" and a ~= "" then
                    local g = Group(a)
                    if b == "" then
                        if val ~= "" then g.name = val end
                    elseif b == "if" then
                        g.when = val ~= "" and val or nil
                    elseif b == "prefix" then
                        g.prefix = val ~= "" and val or nil
                    else
                        Err(n, "unknown group field '" .. b .. "'")
                    end
                elseif head == "list" and a ~= "" then
                    local l = List(a)
                    if b == "" then
                        if val ~= "" then l.name = val end
                    elseif b == "group" then
                        l.groupKey = val
                    elseif b == "prefix" then
                        l.prefix = val
                    elseif b == "targets" then
                        local lo, hi = ParseTargets(val)
                        if not lo then Err(n, "targets is like 1, 2-4 or 5+")
                        else l.min, l.max = lo, hi end
                    else
                        Err(n, "unknown list field '" .. b .. "'")
                    end
                elseif head == "actions" and a ~= "" and b == "" and op == "+=" then
                    local parts = SplitTop(val)
                    local entry = { spell = Trim(parts[1] or "") }
                    if entry.spell == "" then Err(n, "an action starts with a spell name") end
                    for i = 2, #parts do
                        local k, v = KV(parts[i])
                        if k == "if" then entry.when = v ~= "" and v or nil
                        elseif k == "usable" then
                            if v == "0" then entry.usable = false end
                        elseif k == "enabled" then
                            if v == "0" then entry.enabled = false end
                        else Err(n, "unknown action field '" .. tostring(k) .. "'") end
                    end
                    local l = List(a)
                    l.entries[#l.entries + 1] = entry
                else
                    Err(n, "unknown key '" .. key .. "'")
                end
            end
        end
    end

    -- Lists join their group (in the order lists first appeared); lists
    -- without one (format 1 text) go to a "Default" group at the bottom.
    for _, l in ipairs(listOrder) do
        local key = l.groupKey
        l.groupKey = nil
        local g
        if key then
            g = Group(key)
        else
            g = groups["\0default"]
            if not g then
                g = { name = "Default", lists = {} }
                groups["\0default"] = g
            end
        end
        g.lists[#g.lists + 1] = l
    end
    for _, g in ipairs(groupOrder) do def.groups[#def.groups + 1] = g end
    if groups["\0default"] then def.groups[#def.groups + 1] = groups["\0default"] end
    ns.Engine.Migrate(def)  -- fills any missing group prefix

    if not sawAny then errors[#errors + 1] = "nothing to import" end
    if not def.specID and sawAny then errors[#errors + 1] = "missing spec= line" end
    if #errors > 0 then return nil, errors end
    return def
end
