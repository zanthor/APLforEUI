local _, ns = ...

-------------------------------------------------------------------------------
--  Data-driven APL engine: compiles an APL definition (Defaults/*.lua or
--  saved variables) into a runtime with timers, counters, variables and
--  priority lists, then evaluates it. See design.md "Conditions: building
--  blocks" for the vocabulary. tests/ covers the parser and checks the
--  built-in Windwalker APL against its original Lua version.
-------------------------------------------------------------------------------
local Expr = ns.Expr
local Truthy = Expr.Truthy
local ResolveOverride = ns.ResolveOverride
local IsOffCooldown = ns.IsOffCooldown
local IsTalented = ns.IsTalented
local HasBuff = ns.HasBuff

local Engine = {}
ns.Engine = Engine

local NIL = {}  -- variable memo sentinel for "computed, and unknown"

local function Fail(msg) error({ msg = msg }, 0) end

local function Bool(v) return v and 1 or 0 end

-- Never compare/do arithmetic on a secret value: report it as unknown.
local function Clean(v)
    if v == nil or (issecretvalue and issecretvalue(v)) then return nil end
    return v
end

local _baseCdCache = {}
local function BaseCooldown(spellID)
    local dur = _baseCdCache[spellID]
    if dur then return dur end
    local ms = GetSpellBaseCooldown and GetSpellBaseCooldown(spellID)
    dur = (type(ms) == "number" and ms > 0) and (ms / 1000) or 0
    _baseCdCache[spellID] = dur
    return dur
end

-- 0 / 1 / max from non-secret flags only: GetSpellCharges().isActive is
-- "not at max", and a real (non-GCD) cooldown on a charge spell means 0
-- charges (EUI_CDM_HookIconWatch.lua's Hide-CD-Text-(Charges) logic).
-- Exact for spells with up to 2 charges; above that, 1 means "some".
local function Charges(spellID)
    local ci = C_Spell and C_Spell.GetSpellCharges and C_Spell.GetSpellCharges(spellID)
    if ci and (ci.maxCharges or 0) > 1 then
        if not ci.isActive then return ci.maxCharges end
        local cd = C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(spellID)
        local onRealCd = cd and cd.isActive and not cd.isOnGCD
        return onRealCd and 0 or 1
    end
    return Bool(IsOffCooldown(spellID))
end

-- "Can I press it": a charge spell is ready with any charge left. Not
-- ns.IsOffCooldown, which reads a charge spell as ready only at max charges.
local function Ready(spellID)
    local ci = C_Spell and C_Spell.GetSpellCharges and C_Spell.GetSpellCharges(spellID)
    if ci and (ci.maxCharges or 0) > 1 then return Charges(spellID) > 0 end
    return IsOffCooldown(spellID)
end

local function ChargesFull(spellID)
    local ci = C_Spell and C_Spell.GetSpellCharges and C_Spell.GetSpellCharges(spellID)
    if ci and (ci.maxCharges or 0) > 1 then return Bool(not ci.isActive) end
    return Bool(IsOffCooldown(spellID))
end

local function Usable(spellID)
    if not (C_Spell and C_Spell.IsSpellUsable) then return nil end
    local usable = Clean(C_Spell.IsSpellUsable(spellID))
    if usable == nil then return nil end
    return Bool(usable)
end

-- "chi" / "combo_points" -> Enum.PowerType value, matched loosely against
-- the enum's own keys so every power type works without a table here.
local function PowerTypeFor(name)
    local want = name:gsub("_", "")
    for key, value in pairs(Enum.PowerType) do
        if key:lower() == want then return value end
    end
    return nil
end

-------------------------------------------------------------------------------
--  Name resolution: dotted names -> closures (ctx) -> value
-------------------------------------------------------------------------------
local function MakeResolver(rt)
    local function SpellID(name)
        local id = rt.names[name]
        if not id then Fail("unknown name '" .. name .. "'") end
        return id
    end
    local function Want(path, n, what)
        if #path ~= n then Fail("expected " .. what) end
    end

    return function(path)
        local head, a, b = path[1], path[2], path[3]

        if head == "cooldown" then
            Want(path, 3, "cooldown.<name>.ready")
            if b ~= "ready" then Fail("unknown cooldown field '" .. b .. "'") end
            local id = SpellID(a)
            return function() return Bool(Ready(ResolveOverride(id))) end
        elseif head == "charges" then
            local id = SpellID(a or "")
            if #path == 2 then return function() return Charges(id) end end
            Want(path, 3, "charges.<name> or charges.<name>.full")
            if b ~= "full" then Fail("unknown charges field '" .. b .. "'") end
            return function() return ChargesFull(id) end
        elseif head == "usable" then
            Want(path, 2, "usable.<name>")
            local id = SpellID(a)
            return function() return Usable(ResolveOverride(id)) end
        elseif head == "spell" then
            Want(path, 3, "spell.<name>.base_cd")
            if b ~= "base_cd" then Fail("unknown spell field '" .. b .. "'") end
            local id = SpellID(a)
            return function() return BaseCooldown(id) end
        elseif head == "buff" then
            Want(path, 3, "buff.<name>.up")
            if b ~= "up" then Fail("unknown buff field '" .. b .. "'") end
            local id = SpellID(a)
            return function() return Bool(HasBuff(id)) end
        elseif head == "talent" then
            Want(path, 2, "talent.<name>")
            local id = SpellID(a)
            return function() return Bool(IsTalented(id)) end
        elseif head == "override" then
            Want(path, 2, "override.<name>")
            local id = SpellID(a)
            return function() return ResolveOverride(id) end
        elseif head == "prev" then
            Want(path, 2, "prev.<name>")
            local id = SpellID(a)
            return function()
                local last = ns.lastCastSpellID
                return Bool(last ~= nil and (last == id or last == ResolveOverride(id)))
            end
        elseif head == "channeling" then
            Want(path, 2, "channeling.<name>")
            local id = SpellID(a)
            return function()
                return Bool(ns.IsChanneling(id) or ns.IsChanneling(ResolveOverride(id)))
            end
        elseif head == "resource" then
            Want(path, 2, "resource.<power>")
            local powerType = PowerTypeFor(a)
            if not powerType then Fail("unknown resource '" .. a .. "'") end
            return function() return Clean(UnitPower("player", powerType)) end
        elseif head == "timer" then
            Want(path, 3, "timer.<name>.up or timer.<name>.remains")
            local t = rt.timers[a]
            if not t then Fail("unknown timer '" .. a .. "'") end
            if b == "up" then
                return function() return Bool(t.expiresAt ~= nil and t.expiresAt > GetTime()) end
            elseif b == "remains" then
                return function()
                    if t.expiresAt == nil then return nil end
                    return math.max(0, t.expiresAt - GetTime())
                end
            end
            Fail("unknown timer field '" .. b .. "'")
        elseif head == "counter" then
            Want(path, 2, "counter.<name>")
            local c = rt.counters[a]
            if not c then Fail("unknown counter '" .. a .. "'") end
            return function() return c.value end
        elseif head == "variable" then
            Want(path, 2, "variable.<name>")
            local fn = rt.varFns[a]
            if not fn then Fail("unknown variable '" .. a .. "' (define it above where it is used)") end
            return function(ctx)
                local v = ctx.vars[a]
                if v == nil then
                    v = fn(ctx)
                    ctx.vars[a] = v == nil and NIL or v
                    return v
                end
                if v == NIL then return nil end
                return v
            end
        elseif head == "combat" then
            -- Since entering combat; 0 out of combat, so an opener group
            -- is already showing before the pull.
            Want(path, 2, "combat.time or combat.casts")
            if a == "time" then
                return function() return ns.combatStart and (GetTime() - ns.combatStart) or 0 end
            elseif a == "casts" then
                return function() return ns.combatCasts or 0 end
            end
            Fail("unknown combat field '" .. a .. "'")
        elseif head == "targets" then
            Want(path, 1, "targets")
            return function(ctx)
                if not ctx.targets then ctx.targets = ns.GetTargetCount(rt.rangeSpellID) end
                return ctx.targets
            end
        elseif head == "bloodlust" then
            Want(path, 1, "bloodlust")
            return function() return Bool(ns.HasBloodlust()) end
        elseif #path == 1 and rt.names[head] then
            local id = rt.names[head]
            return function() return id end
        end
        Fail("unknown name '" .. table.concat(path, ".") .. "'")
    end
end

-------------------------------------------------------------------------------
--  Compile
-------------------------------------------------------------------------------
local TIMER_ACTIONS = { set = true, start = true, add = true, clear = true }
local COUNTER_ACTIONS = { set = true, add = true, sub = true, reset = true }
local TRIGGER_EVENTS = { cast = true, aura_present = true, aura_absent = true }

local function CompileTracker(rt, def, kind, resolve, err)
    local tracker = { kind = kind, name = def.name, cast = {}, aura = {} }
    local actions = kind == "timer" and TIMER_ACTIONS or COUNTER_ACTIONS
    if kind == "counter" then
        tracker.initial = def.initial or 0
        tracker.min = def.min or 0
        tracker.max = def.max
        tracker.value = tracker.initial
    end
    for i, tdef in ipairs(def.triggers or {}) do
        local where = kind .. " " .. def.name .. " trigger " .. i
        local id = rt.names[tdef.spell or ""]
        local trig = { action = tdef.action }
        local ok = true
        if not TRIGGER_EVENTS[tdef.on] then
            err(where, "unknown event '" .. tostring(tdef.on) .. "'"); ok = false
        elseif not id then
            err(where, "unknown name '" .. tostring(tdef.spell) .. "'"); ok = false
        elseif not actions[tdef.action] then
            err(where, "action '" .. tostring(tdef.action) .. "' is not valid for a " .. kind); ok = false
        end
        if ok and tdef.when then
            local fn, e = Expr.Compile(tdef.when, resolve)
            if fn then trig.when = fn else err(where, e); ok = false end
        end
        if ok and tdef.value then
            local fn, e = Expr.Compile(tdef.value, resolve)
            if fn then trig.value = fn else err(where, e); ok = false end
        end
        if ok then
            if tdef.on == "cast" then
                local list = tracker.cast[id]
                if not list then list = {}; tracker.cast[id] = list end
                list[#list + 1] = trig
            else
                trig.spellID = id
                trig.present = tdef.on == "aura_present"
                tracker.aura[#tracker.aura + 1] = trig
            end
        end
    end
    return tracker
end

-- Ranges may not overlap (design.md); a list with no max runs to infinity.
local function CheckRanges(lists, err)
    for i = 1, #lists do
        for j = i + 1, #lists do
            local x, y = lists[i], lists[j]
            local xMax, yMax = x.max or math.huge, y.max or math.huge
            if x.min <= yMax and y.min <= xMax then
                err("lists", "'" .. x.name .. "' and '" .. y.name .. "' target ranges overlap")
            end
        end
    end
end

function Engine.Compile(def)
    local rt = {
        def = def, name = def.name, specID = def.specID,
        names = def.names or {},
        timers = {}, counters = {}, trackers = {},
        varFns = {}, groups = {}, errors = {}, tts = {},
        ctx = { vars = {} },
    }
    local options = def.options or {}
    rt.noRepeat = options.noRepeatLastCast == true
    rt.rangeSpellID = options.rangeSpell and rt.names[options.rangeSpell]

    local function err(where, msg) rt.errors[#rt.errors + 1] = where .. ": " .. tostring(msg) end
    local resolve = MakeResolver(rt)

    -- Keyed by spell ID so the widget can look up whatever it is showing.
    for name, text in pairs(def.tts or {}) do
        local id = rt.names[name]
        if id then rt.tts[id] = text else err("tts", "unknown name '" .. name .. "'") end
    end

    -- Trackers first (state tables must exist before anything references
    -- them), then their triggers, which may read any tracker or variable.
    for _, t in ipairs(def.timers or {}) do rt.timers[t.name] = { expiresAt = nil } end
    for _, c in ipairs(def.counters or {}) do rt.counters[c.name] = { value = c.initial or 0 } end

    for _, v in ipairs(def.variables or {}) do
        local fn, e
        if not v.expr or v.expr:match("^%s*$") then e = "has no expression yet"
        else fn, e = Expr.Compile(v.expr, resolve) end
        if fn then rt.varFns[v.name] = fn else err("variable " .. v.name, e) end
    end

    for _, t in ipairs(def.timers or {}) do
        local tracker = CompileTracker(rt, t, "timer", resolve, err)
        tracker.state = rt.timers[t.name]
        rt.trackers[#rt.trackers + 1] = tracker
    end
    for _, c in ipairs(def.counters or {}) do
        local tracker = CompileTracker(rt, c, "counter", resolve, err)
        tracker.state = rt.counters[c.name]
        tracker.state.value = tracker.initial
        rt.trackers[#rt.trackers + 1] = tracker
    end

    Engine.Migrate(def)
    local prefixUsedBy = {}
    for _, gdef in ipairs(def.groups or {}) do
        local group = { name = gdef.name, lists = {} }
        -- Prefixes are what the widgets show; names are only for the editor.
        local gshort = gdef.prefix
        if not Engine.ValidPrefix(gshort) then
            err("group " .. tostring(gdef.name), "prefix must be 1-3 characters")
            gshort = "?"
        end
        if gdef.when and gdef.when ~= "" then
            local fn, e = Expr.Compile(gdef.when, resolve)
            -- A broken condition must not read as "always": skip the group.
            if fn then group.when = fn else err("group " .. tostring(gdef.name), e); group.broken = true end
        end
        for _, ldef in ipairs(gdef.lists or {}) do
            -- Status widget label: "<group prefix>-<list prefix>".
            local display = gshort .. "-" .. tostring(ldef.prefix)
            local list = { name = display, min = ldef.min or 1, max = ldef.max, entries = {} }
            local prefix = ldef.prefix
            if not Engine.ValidPrefix(prefix) then
                err("list " .. tostring(ldef.name), "prefix must be 1-3 characters")
                prefix = "?"
            elseif prefixUsedBy[prefix] then
                err("list " .. tostring(ldef.name), "prefix '" .. prefix .. "' is also used by list '"
                    .. tostring(prefixUsedBy[prefix]) .. "'; labels would be ambiguous")
            else
                prefixUsedBy[prefix] = ldef.name
            end
            for i, edef in ipairs(ldef.entries or {}) do
                -- Label = list prefix + position; disabled entries keep their
                -- number so toggling one doesn't renumber the rest.
                local label = prefix .. i
                local where = "list " .. tostring(ldef.name) .. " entry " .. label
                local id = rt.names[edef.spell or ""]
                if not id then
                    err(where, "unknown name '" .. tostring(edef.spell) .. "'")
                elseif edef.enabled ~= false then
                    -- usable = false opts an entry out of the default
                    -- "only when usable" check (design.md, Entry rules).
                    local entry = { spellID = id, label = label, checkUsable = edef.usable ~= false }
                    local ok = true
                    if edef.when and edef.when ~= "" then
                        local fn, e = Expr.Compile(edef.when, resolve)
                        if fn then entry.when = fn else err(where, e); ok = false end
                    end
                    if ok then list.entries[#list.entries + 1] = entry end
                end
            end
            group.lists[#group.lists + 1] = list
        end
        CheckRanges(group.lists, err)
        rt.groups[#rt.groups + 1] = group
    end
    return rt
end

-- Short prefix from a name: "Burst Window" -> "BUR", "Default" -> "DEF".
function Engine.PrefixFromName(name, fallback)
    local p = tostring(name or ""):gsub("[^%w]", ""):sub(1, 3):upper()
    return p ~= "" and p or fallback
end

-- Pre-group APLs had one flat "lists" array: it becomes a single
-- unconditional "Default" group. Groups saved before prefixes were
-- required get one from their name. Safe to call repeatedly.
function Engine.Migrate(def)
    if def.lists and not def.groups then
        def.groups = { { name = "Default", prefix = "DEF", lists = def.lists } }
        def.lists = nil
    end
    for i, group in ipairs(def.groups or {}) do
        if group.prefix == nil or group.prefix == "" then
            group.prefix = Engine.PrefixFromName(group.name, "G" .. i)
        end
    end
    return def
end

function Engine.ValidPrefix(prefix)
    if type(prefix) ~= "string" or prefix == "" then return false end
    local len = strlenutf8 and strlenutf8(prefix) or #prefix
    return len <= 3
end

-------------------------------------------------------------------------------
--  Evaluate
-------------------------------------------------------------------------------
local function PickList(group, targets)
    local n = targets < 1 and 1 or targets
    for _, list in ipairs(group.lists) do
        if n >= list.min and (not list.max or n <= list.max) then return list end
    end
    return nil
end

-- Name of the list that produced the last suggestion (the status widget's
-- label), or nil when nothing was suggested.
function Engine.CurrentListName(rt)
    return rt.lastListName
end

-- Groups top to bottom: the first whose condition holds and that has a
-- list for the target count gets to suggest; if that list has nothing, the
-- next group gets a turn (design.md, phase 5). Returns (spellID, label,
-- listName), or nil when nothing applies.
function Engine.Evaluate(rt)
    local ctx = rt.ctx
    wipe(ctx.vars)
    ctx.targets = ns.GetTargetCount(rt.rangeSpellID)
    local last = ns.lastCastSpellID
    for _, group in ipairs(rt.groups) do
        if not group.broken and (not group.when or Truthy(group.when(ctx))) then
            local list = PickList(group, ctx.targets)
            if list then
                for _, entry in ipairs(list.entries) do
                    local sid = ResolveOverride(entry.spellID)
                    if not (rt.noRepeat and sid == last) and Ready(sid)
                        and (not entry.checkUsable or Usable(sid) ~= 0)
                        and (not entry.when or Truthy(entry.when(ctx))) then
                        rt.lastListName = list.name
                        return sid, entry.label, list.name
                    end
                end
            end
        end
    end
    rt.lastListName = nil
    return nil
end

-------------------------------------------------------------------------------
--  Triggers: every tracker picks its first matching trigger, with guards and
--  values all evaluated against pre-event state, then all picks apply.
-------------------------------------------------------------------------------
local _pickTracker, _pickTrig, _pickValue = {}, {}, {}

local function Apply(tracker, action, v, now)
    local s = tracker.state
    if tracker.kind == "timer" then
        if action == "clear" then
            s.expiresAt = nil
        elseif v == nil then
            return
        elseif action == "set" then
            s.expiresAt = now + v
        elseif action == "start" then
            if s.expiresAt == nil then s.expiresAt = now + v end
        elseif action == "add" then
            if s.expiresAt and s.expiresAt > now then s.expiresAt = s.expiresAt + v
            else s.expiresAt = now + v end
        end
    else
        local value = s.value
        if action == "reset" then
            value = tracker.initial
        elseif v == nil then
            return
        elseif action == "set" then
            value = v
        elseif action == "add" then
            value = value + v
        elseif action == "sub" then
            value = value - v
        end
        if value < tracker.min then value = tracker.min end
        if tracker.max and value > tracker.max then value = tracker.max end
        s.value = value
    end
end

local function RunPicks(rt, n)
    local now = GetTime()
    for i = 1, n do
        Apply(_pickTracker[i], _pickTrig[i].action, _pickValue[i], now)
        _pickTracker[i], _pickTrig[i], _pickValue[i] = nil, nil, nil
    end
end

local function Matches(trig, ctx)
    return not trig.when or Truthy(trig.when(ctx))
end

function Engine.OnCast(rt, spellID)
    local ctx = rt.ctx
    wipe(ctx.vars)
    ctx.targets = nil
    local n = 0
    for _, tracker in ipairs(rt.trackers) do
        local list = tracker.cast[spellID]
        if list then
            for _, trig in ipairs(list) do
                if Matches(trig, ctx) then
                    n = n + 1
                    _pickTracker[n], _pickTrig[n] = tracker, trig
                    _pickValue[n] = trig.value and trig.value(ctx)
                    break
                end
            end
        end
    end
    RunPicks(rt, n)
end

function Engine.OnAura(rt)
    local ctx = rt.ctx
    wipe(ctx.vars)
    ctx.targets = nil
    local n = 0
    for _, tracker in ipairs(rt.trackers) do
        for _, trig in ipairs(tracker.aura) do
            if (HasBuff(trig.spellID) and true or false) == trig.present and Matches(trig, ctx) then
                n = n + 1
                _pickTracker[n], _pickTrig[n] = tracker, trig
                _pickValue[n] = trig.value and trig.value(ctx)
                break
            end
        end
    end
    RunPicks(rt, n)
end

function Engine.Reset(rt)
    for _, tracker in ipairs(rt.trackers) do
        if tracker.kind == "timer" then tracker.state.expiresAt = nil
        else tracker.state.value = tracker.initial end
    end
end

-- Runs an expression against a runtime's current state (for /apl expr).
function Engine.EvalText(rt, text)
    local fn, e = Expr.Compile(text, MakeResolver(rt))
    if not fn then return nil, e end
    wipe(rt.ctx.vars)
    rt.ctx.targets = nil
    return true, fn(rt.ctx)
end

-------------------------------------------------------------------------------
--  APL selection: user APLs (saved variables) and built-ins (Defaults/*.lua)
-------------------------------------------------------------------------------
-- Saved APLs from before groups existed are converted as soon as the saved
-- variables are available.
local migrateFrame = CreateFrame("Frame")
migrateFrame:RegisterEvent("ADDON_LOADED")
migrateFrame:SetScript("OnEvent", function(self, _, addon)
    if addon ~= "APLforEUI" then return end
    self:UnregisterEvent("ADDON_LOADED")
    for _, def in pairs(ns.DB().apls or {}) do Engine.Migrate(def) end
end)

local _builtins, _builtinBySpec = {}, {}
local _runtimes = setmetatable({}, { __mode = "k" })

function ns.RegisterBuiltinAPL(def)
    _builtins[def.id] = def
    if not _builtinBySpec[def.specID] then _builtinBySpec[def.specID] = def end
end

function Engine.Builtins() return _builtins end
function Engine.BuiltinForSpec(specID) return _builtinBySpec[specID] end

function Engine.FindDefByID(id)
    local db = ns.DB()
    return (db.apls and db.apls[id]) or _builtins[id]
end

-- The APL that runs for specID: the chosen one, else the spec's built-in.
function Engine.ActiveDef(specID)
    local db = ns.DB()
    local id = db.activeAPL and db.activeAPL[specID]
    local def = id and Engine.FindDefByID(id)
    if def and def.specID == specID then return def end
    return _builtinBySpec[specID]
end

-- Compiled runtime for a definition, cached until Invalidate (any edit).
function Engine.GetRuntime(def)
    local rt = _runtimes[def]
    if not rt then
        rt = Engine.Compile(def)
        _runtimes[def] = rt
    end
    return rt
end

function Engine.Invalidate(def)
    _runtimes[def] = nil
end

-- Live validation for the editor: does this text compile against def's
-- current names, timers, counters and variables?
function Engine.CheckExpr(def, text)
    if not text or text:match("^%s*$") then return true end
    local fn, e = Expr.Compile(text, MakeResolver(Engine.GetRuntime(def)))
    if fn then return true end
    return false, e
end

-- Errors are shown live in the editor; chat only hears about them once per
-- APL per session, when it first becomes the running APL.
local _reportedErrors = setmetatable({}, { __mode = "k" })

function ns.GetActiveAPL()
    local specID = ns.GetSpecID()
    if not specID then return nil end
    local def = Engine.ActiveDef(specID)
    if not def then return nil end
    local rt = Engine.GetRuntime(def)
    if not _reportedErrors[def] then
        _reportedErrors[def] = true
        for _, e in ipairs(rt.errors) do
            print("|cffff6060APL for EUI|r: " .. tostring(rt.name) .. ": " .. e)
        end
    end
    return rt
end

function ns.EvaluateExpected()
    local rt = ns.GetActiveAPL()
    if not rt then return nil end
    return Engine.Evaluate(rt)
end

ns.slashCommands.expr = function(rest)
    local rt = ns.GetActiveAPL()
    if not rt then print("APL for EUI: no APL for this spec."); return end
    local ok, v = Engine.EvalText(rt, rest)
    if not ok then print("APL expr error: " .. tostring(v)); return end
    print("APL expr: " .. rest .. " = " .. tostring(v))
end
