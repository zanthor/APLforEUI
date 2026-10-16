local _, ns = ...

-------------------------------------------------------------------------------
--  APL store: user APLs in saved variables (APLforEUIDB.apls), plus the
--  operations the editor performs on them. Built-ins (Defaults/*.lua) are
--  never written; editing one means duplicating it first. Every change goes
--  through Changed() so the engine recompiles. No UI code here.
-------------------------------------------------------------------------------
local Engine = ns.Engine
local Store = {}
ns.Store = Store

local function DB()
    local db = ns.DB()
    db.apls = db.apls or {}
    db.activeAPL = db.activeAPL or {}
    return db
end

local function DeepCopy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = DeepCopy(x) end
    return t
end

function Store.Changed(def)
    Engine.Invalidate(def)
end

function Store.Get(id)
    return Engine.FindDefByID(id)
end

function Store.IsEditable(def)
    return def ~= nil and not def.builtin
end

-- Built-ins first, then the user's own, by name.
function Store.ListForSpec(specID)
    local out = {}
    for _, def in pairs(Engine.Builtins()) do
        if def.specID == specID then out[#out + 1] = def end
    end
    local user = {}
    for _, def in pairs(DB().apls) do
        if def.specID == specID then user[#user + 1] = def end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    table.sort(user, function(a, b) return a.name:lower() < b.name:lower() end)
    for _, def in ipairs(user) do out[#out + 1] = def end
    return out
end

-- Every specID that has at least one APL (built-in or user).
function Store.SpecsWithAPLs()
    local seen, out = {}, {}
    local function Add(specID)
        if specID and not seen[specID] then seen[specID] = true; out[#out + 1] = specID end
    end
    for _, def in pairs(Engine.Builtins()) do Add(def.specID) end
    for _, def in pairs(DB().apls) do Add(def.specID) end
    table.sort(out)
    return out
end

function Store.ActiveID(specID)
    local def = Engine.ActiveDef(specID)
    return def and def.id
end

function Store.SetActive(specID, id)
    DB().activeAPL[specID] = id
    local def = Store.Get(id)
    if def then Store.Changed(def) end
end

local function NewID()
    local db = DB()
    db.nextAPLId = (db.nextAPLId or 0) + 1
    return "user:" .. db.nextAPLId
end

-- Names stay unique per spec so the picker never shows two the same.
local function UniqueName(specID, base)
    local taken = {}
    for _, def in ipairs(Store.ListForSpec(specID)) do taken[def.name] = true end
    if not taken[base] then return base end
    local n = 2
    while taken[base .. " " .. n] do n = n + 1 end
    return base .. " " .. n
end

function Store.Duplicate(def)
    local copy = DeepCopy(def)
    copy.id = NewID()
    copy.builtin = nil
    copy.name = UniqueName(def.specID, def.name:gsub(" %(default%)$", "") .. " (copy)")
    DB().apls[copy.id] = copy
    return copy
end

function Store.New(specID)
    local def = {
        id = NewID(),
        name = UniqueName(specID, "New APL"),
        specID = specID,
        options = { noRepeatLastCast = false },
        names = {}, tts = {}, variables = {}, timers = {}, counters = {},
        groups = { {
            name = "Default",
            prefix = "DEF",
            lists = {
                { name = "ST", prefix = "ST", min = 1, max = 1, entries = {} },
                { name = "AOE", prefix = "AOE", min = 2, entries = {} },
            },
        } },
    }
    DB().apls[def.id] = def
    return def
end

function Store.Rename(def, name)
    name = name and name:match("^%s*(.-)%s*$") or ""
    if name == "" or name == def.name then return false end
    def.name = UniqueName(def.specID, name)
    Store.Changed(def)
    return true
end

-- Deleting the running APL falls back to the spec's built-in.
function Store.Delete(def)
    local db = DB()
    if not Store.IsEditable(def) then return false end
    db.apls[def.id] = nil
    if db.activeAPL[def.specID] == def.id then db.activeAPL[def.specID] = nil end
    Store.Changed(def)
    return true
end

-------------------------------------------------------------------------------
--  Spell short names
-------------------------------------------------------------------------------

-- "Fists of Fury" -> "fists_of_fury"; never starts with a digit, so it is
-- always a valid expression name.
function Store.MakeShortName(text)
    local s = (text or ""):lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    if s == "" then s = "spell" end
    if s:match("^%d") then s = "s_" .. s end
    return s
end

-- Reserved words of the expression vocabulary can't be names.
local RESERVED = {
    cooldown = true, charges = true, usable = true, spell = true, buff = true,
    talent = true, override = true, prev = true, channeling = true,
    resource = true, timer = true, counter = true, variable = true,
    targets = true, bloodlust = true, max = true, min = true, holding = true, combat = true,
}

-- Resolves typed text (a spell ID, or a name the client knows) to a spell.
function Store.LookupSpell(text)
    text = text and text:match("^%s*(.-)%s*$") or ""
    if text == "" then return nil end
    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(tonumber(text) or text)
    if not info or not info.spellID then return nil end
    return info.spellID, info.name, info.iconID
end

-- Short name for spellID in def, creating one from the spell's name if the
-- APL doesn't have it yet.
function Store.EnsureName(def, spellID, spellName)
    def.names = def.names or {}
    for name, id in pairs(def.names) do
        if id == spellID then return name end
    end
    local base = Store.MakeShortName(spellName or ("spell " .. spellID))
    if RESERVED[base] then base = base .. "_spell" end
    local name, n = base, 2
    while def.names[name] do name = base .. "_" .. n; n = n + 1 end
    def.names[name] = spellID
    Store.Changed(def)
    return name
end

-------------------------------------------------------------------------------
--  Groups, lists and entries
-------------------------------------------------------------------------------

-- Calls fn(list, group) for every list in def, groups in order.
function Store.EachList(def, fn)
    for _, group in ipairs(def.groups or {}) do
        for _, list in ipairs(group.lists or {}) do fn(list, group) end
    end
end

function Store.GroupOf(def, list)
    for _, group in ipairs(def.groups or {}) do
        for _, l in ipairs(group.lists or {}) do if l == list then return group end end
    end
    return nil
end

-- Prefix not used by any list yet, from a preferred one ("BST", "BS2", ...).
local function FreePrefix(def, want)
    local used = {}
    Store.EachList(def, function(l) used[l.prefix or ""] = true end)
    want = (want or "L"):sub(1, 3)
    if not used[want] then return want end
    for n = 2, 99 do
        local p = want:sub(1, 3 - #tostring(n)) .. n
        if not used[p] then return p end
    end
    return want
end

-- New group at the top (highest priority), with an ST list, since new
-- groups are usually openers or burst windows layered over the default.
function Store.AddGroup(def)
    def.groups = def.groups or {}
    local n = #def.groups + 1
    local used = {}
    for _, g in ipairs(def.groups) do used[g.prefix or ""] = true end
    local k = n
    while used["G" .. k] do k = k + 1 end
    local group = { name = "Group " .. n, prefix = "G" .. k, when = "", lists = {} }
    group.lists[1] = { name = "ST", prefix = FreePrefix(def, "G" .. n .. "S"), min = 1, max = 1, entries = {} }
    table.insert(def.groups, 1, group)
    Store.Changed(def)
    return group
end

-- Fills a group's condition with the opener preset: the first N casts or S
-- seconds of combat (and before the pull, where both read 0).
Store.OPENER_PRESET = "combat.casts<5&combat.time<8"

-- Target ranges may not overlap within a group. Returns nil or a message
-- naming the clash.
function Store.RangeConflict(def, list, min, max)
    local hi = max or math.huge
    local group = Store.GroupOf(def, list)
    for _, other in ipairs(group and group.lists or {}) do
        if other ~= list then
            local oHi = other.max or math.huge
            if min <= oHi and other.min <= hi then
                return "overlaps list '" .. tostring(other.name) .. "'"
            end
        end
    end
    return nil
end

-- Lowest free target count in a group, for a new list's default range.
local function NextFreeMin(group)
    local n = 1
    local moved = true
    while moved do
        moved = false
        for _, l in ipairs(group.lists) do
            if n >= l.min and (not l.max or n <= l.max) then
                if not l.max then return nil end
                n = l.max + 1
                moved = true
            end
        end
    end
    return n
end

function Store.AddList(def, group)
    local min = NextFreeMin(group)
    if not min then return nil, "every target count in this group already has a list" end
    local n = #group.lists + 1
    local list = { name = "List " .. n, prefix = FreePrefix(def, "L" .. n), min = min, max = min, entries = {} }
    group.lists[n] = list
    Store.Changed(def)
    return list
end

function Store.AddEntry(def, list, spellName)
    local entry = { spell = spellName, when = "" }
    list.entries[#list.entries + 1] = entry
    Store.Changed(def)
    return entry
end

-- Generic helpers for the editor's ordered lists (entries, triggers, ...).
function Store.Move(def, array, i, delta)
    local j = i + delta
    if j < 1 or j > #array then return end
    array[i], array[j] = array[j], array[i]
    Store.Changed(def)
end

function Store.Remove(def, array, i)
    table.remove(array, i)
    Store.Changed(def)
end

-------------------------------------------------------------------------------
--  Renaming building blocks
-------------------------------------------------------------------------------

-- A valid timer / counter / variable / short name: letters, digits, "_",
-- not starting with a digit.
function Store.ValidIdent(name)
    return type(name) == "string" and name:match("^[%a_][%w_]*$") ~= nil
end

-- Every expression string in def, as (table, key) pairs, for rewriting.
local function EachExpr(def, fn)
    for _, v in ipairs(def.variables or {}) do fn(v, "expr") end
    for _, group in ipairs({ def.timers or {}, def.counters or {} }) do
        for _, t in ipairs(group) do
            for _, trig in ipairs(t.triggers or {}) do
                fn(trig, "when"); fn(trig, "value")
            end
        end
    end
    for _, group in ipairs(def.groups or {}) do
        fn(group, "when")
        for _, l in ipairs(group.lists or {}) do
            for _, e in ipairs(l.entries or {}) do fn(e, "when") end
        end
    end
end

-- Reads whose second segment is a spell short name (buff.<name>.up, ...).
local SPELL_HEADS = {
    cooldown = true, charges = true, usable = true, spell = true, buff = true,
    talent = true, override = true, prev = true, channeling = true, holding = true,
}

-- Rewrites references to a renamed building block in every expression,
-- path by path, so separate namespaces never collide (renaming the spell
-- name "zenith" leaves timer.zenith alone). kind: "timer" | "counter" |
-- "variable" (written kind.name), or "name" (a spell short name: the
-- second segment of a spell read, or a bare word such as a comparison value).
local function RewriteRefs(def, kind, old, new)
    local function Path(path)
        local seg = {}
        for part in path:gmatch("[^%.]+") do seg[#seg + 1] = part end
        if kind == "name" then
            if #seg == 1 and seg[1] == old then return new end
            if SPELL_HEADS[seg[1]] and seg[2] == old then seg[2] = new; return table.concat(seg, ".") end
        elseif seg[1] == kind and seg[2] == old then
            seg[2] = new
            return table.concat(seg, ".")
        end
        return nil
    end
    EachExpr(def, function(t, key)
        if type(t[key]) == "string" then t[key] = t[key]:gsub("[%a_][%w_%.]*", Path) end
    end)
end
Store.RewriteRefs = RewriteRefs

-- Renames a timer / counter / variable (array element with .name) or a
-- spell short name, updating every reference. Returns false, reason on a
-- bad or taken name.
function Store.RenameBlock(def, kind, item, new)
    new = new and new:match("^%s*(.-)%s*$") or ""
    local old = kind == "name" and item or item.name
    if new == old then return true end
    if not Store.ValidIdent(new) then return false, "use letters, digits and _ (not starting with a digit)" end
    if kind == "name" then
        if def.names[new] then return false, "that name is already used" end
        def.names[new] = def.names[old]
        def.names[old] = nil
        if def.tts and def.tts[old] then def.tts[new], def.tts[old] = def.tts[old], nil end
        Store.EachList(def, function(l)
            for _, e in ipairs(l.entries or {}) do if e.spell == old then e.spell = new end end
        end)
        for _, group in ipairs({ def.timers or {}, def.counters or {} }) do
            for _, t in ipairs(group) do
                for _, trig in ipairs(t.triggers or {}) do if trig.spell == old then trig.spell = new end end
            end
        end
        if def.options and def.options.rangeSpell == old then def.options.rangeSpell = new end
    else
        local arrayKey = kind == "timer" and "timers" or kind == "counter" and "counters" or "variables"
        for _, other in ipairs(def[arrayKey] or {}) do
            if other ~= item and other.name == new then return false, "that name is already used" end
        end
        item.name = new
    end
    RewriteRefs(def, kind, old, new)
    Store.Changed(def)
    return true
end

-- New uniquely named timer / counter / variable appended to its array.
function Store.AddBlock(def, kind)
    local arrayKey = kind == "timer" and "timers" or kind == "counter" and "counters" or "variables"
    def[arrayKey] = def[arrayKey] or {}
    local taken = {}
    for _, x in ipairs(def[arrayKey]) do taken[x.name] = true end
    local n, name = 1, nil
    repeat name = kind .. "_" .. n; n = n + 1 until not taken[name]
    local item = { name = name }
    if kind == "variable" then item.expr = "" else item.triggers = {} end
    if kind == "counter" then item.initial, item.min = 0, 0 end
    def[arrayKey][#def[arrayKey] + 1] = item
    Store.Changed(def)
    return item
end

-- Saves an imported APL (Exchange.Import) as a new user APL. Never
-- overwrites: the name is made unique within its spec.
function Store.AddImported(def)
    def.id = NewID()
    def.builtin = nil
    def.name = UniqueName(def.specID, def.name)
    DB().apls[def.id] = def
    Store.Changed(def)
    return def
end
