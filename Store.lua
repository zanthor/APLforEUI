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
    if ns.OnAPLChanged then ns.OnAPLChanged(def) end
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
        lists = {
            { name = "ST", prefix = "ST", min = 1, max = 1, entries = {} },
            { name = "AOE", prefix = "AOE", min = 2, entries = {} },
        },
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
    targets = true, bloodlust = true, max = true, min = true,
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
--  Lists and entries
-------------------------------------------------------------------------------

-- Target ranges may not overlap. Returns nil or a message naming the clash.
function Store.RangeConflict(def, list, min, max)
    local hi = max or math.huge
    for _, other in ipairs(def.lists) do
        if other ~= list then
            local oHi = other.max or math.huge
            if min <= oHi and other.min <= hi then
                return "overlaps list '" .. tostring(other.name) .. "'"
            end
        end
    end
    return nil
end

-- Lowest free target count, for a new list's default range.
local function NextFreeMin(def)
    local n = 1
    local moved = true
    while moved do
        moved = false
        for _, l in ipairs(def.lists) do
            if n >= l.min and (not l.max or n <= l.max) then
                if not l.max then return nil end
                n = l.max + 1
                moved = true
            end
        end
    end
    return n
end

function Store.AddList(def)
    local min = NextFreeMin(def)
    if not min then return nil, "every target count already has a list" end
    local list = { name = "List " .. (#def.lists + 1), prefix = "L" .. (#def.lists + 1), min = min, max = min, entries = {} }
    def.lists[#def.lists + 1] = list
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
