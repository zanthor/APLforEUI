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

-- A charge spell's recharge time. The game's "base cooldown" is not it
-- (Zenith reads 16s for a 90s recharge), and GetSpellCharges'
-- cooldownDuration is secret in restricted combat, so it's read whenever it
-- isn't (out of combat; first at compile) and remembered.
local _rechargeCache = {}
local function Recharge(spellID)
    local ci = C_Spell and C_Spell.GetSpellCharges and C_Spell.GetSpellCharges(spellID)
    local d = ci and Clean(ci.cooldownDuration)
    if type(d) == "number" and d > 0 then _rechargeCache[spellID] = d end
    return _rechargeCache[spellID]
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
            Want(path, 3, "spell.<name>.base_cd or spell.<name>.recharge")
            local id = SpellID(a)
            if b == "base_cd" then return function() return BaseCooldown(id) end end
            if b == "recharge" then
                Recharge(id)  -- cache it now, while it's readable
                return function() return Recharge(id) end
            end
            Fail("unknown spell field '" .. b .. "'")
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
        elseif head == "holding" then
            -- design.md, phase 6: holding (anything held) / holding.<name>.
            if #path == 1 then
                return function()
                    for _, h in pairs(rt.holds) do if h.held then return 1 end end
                    return 0
                end
            end
            Want(path, 2, "holding or holding.<name>")
            local id = SpellID(a)
            return function()
                local h = rt.holds[id]
                return Bool(h ~= nil and h.held)
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
        holds = {},  -- [base spellID] = { count = consecutive ignores, held = bool }
        free = {},   -- free casts: spellIDs that never count against compliance
        ctx = { vars = {} },
    }
    local options = def.options or {}
    rt.noRepeat = options.noRepeatLastCast == true
    rt.rangeSpellID = options.rangeSpell and rt.names[options.rangeSpell]

    local function err(where, msg) rt.errors[#rt.errors + 1] = where .. ": " .. tostring(msg) end
    local resolve = MakeResolver(rt)

    -- Free casts (interrupts, movement, defensives): across every group.
    for _, name in ipairs(def.freeCasts or {}) do
        local id = rt.names[name]
        if id then rt.free[#rt.free + 1] = id else err("free casts", "unknown name '" .. tostring(name) .. "'") end
    end

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
                    if edef.hold ~= nil then
                        local n = tonumber(edef.hold)
                        if n and n >= Engine.MIN_HOLD and n == math.floor(n) then entry.hold = n
                        else err(where, "hold must be a whole number of " .. Engine.MIN_HOLD .. " or more") end
                    end
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

-- Smallest "Hold After Ignored Casts": 1 would hold on any single other
-- press, and 2 is what the hold fork's alternative already does (a hold
-- from the second cast on the hold line), so the setting starts at 3.
Engine.MIN_HOLD = 3

-- Every entry of def, grouped (current) or flat (pre-group APLs).
local function EachEntry(def, fn)
    for _, group in ipairs(def.groups or {}) do
        for _, l in ipairs(group.lists or {}) do
            for _, e in ipairs(l.entries or {}) do fn(e) end
        end
    end
    for _, l in ipairs(def.lists or {}) do
        for _, e in ipairs(l.entries or {}) do fn(e) end
    end
end

-- Pre-group APLs had one flat "lists" array: it becomes a single
-- unconditional "Default" group. Groups saved before prefixes were
-- required get one from their name. Safe to call repeatedly.
function Engine.Migrate(def)
    -- Holds below MIN_HOLD (allowed before the hold fork) are raised to it.
    EachEntry(def, function(e)
        local n = tonumber(e.hold)
        if n and n >= 1 and n < Engine.MIN_HOLD then e.hold = Engine.MIN_HOLD end
    end)
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
-- next group gets a turn (design.md, phase 5). Held entries (phase 6) are
-- skipped. Returns (spellID, label, listName, entry), or nil when nothing
-- applies.
-- The first valid entry, skipping every entry for skipID (a base spellID).
local function Pick(rt, ctx, skipID)
    local last = ns.lastCastSpellID
    for _, group in ipairs(rt.groups) do
        if not group.broken and (not group.when or Truthy(group.when(ctx))) then
            local list = PickList(group, ctx.targets)
            if list then
                for _, entry in ipairs(list.entries) do
                    local sid = ResolveOverride(entry.spellID)
                    local hold = rt.holds[entry.spellID]
                    if entry.spellID ~= skipID and not (hold and hold.held)
                        and not (rt.noRepeat and sid == last) and Ready(sid)
                        and (not entry.checkUsable or Usable(sid) ~= 0)
                        and (not entry.when or Truthy(entry.when(ctx))) then
                        return sid, entry.label, list.name, entry
                    end
                end
            end
        end
    end
    return nil
end

-- Returns (spellID, label, listName, entry, altSpellID), or nil when nothing
-- applies. When the top entry is a hold line (not yet held), altSpellID is
-- the next valid action below it -- the "hold fork": the hold spell shows in
-- Hold Color and the alternative in the normal color, and casting the
-- alternative (from the second cast on the hold line) holds the spell
-- (OnCastResult).
function Engine.Evaluate(rt)
    local ctx = rt.ctx
    wipe(ctx.vars)
    ctx.targets = ns.GetTargetCount(rt.rangeSpellID)
    local sid, label, listName, entry = Pick(rt, ctx, nil)
    rt.lastListName = listName
    local alt
    if entry and entry.hold then alt = (Pick(rt, ctx, entry.spellID)) end
    return sid, label, listName, entry, alt
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
    wipe(rt.holds)
end

-------------------------------------------------------------------------------
--  Holding cooldowns (design.md, phase 6). Called for every in-combat cast
--  with the entry that was the suggestion when it was cast (and the fork's
--  alternative, altID, if that entry was a hold line). Ignoring a
--  holdable entry N times in a row marks its spell held (its entry is then
--  skipped); casting the spell, or a cast while it wasn't the suggestion,
--  resets the count. Returns (resolved spellID, N) on the cast that makes a
--  spell held, so Tracking can forgive those N casts in the stats.
-------------------------------------------------------------------------------
local function IsCastOf(castID, baseID)
    return castID == baseID or castID == ResolveOverride(baseID)
end

-- A cast of one of the APL's free casts: it's left out of compliance, holds,
-- the cast count and "last cast" (Tracking.ReportCast).
function Engine.IsFreeCast(rt, castID)
    local free = rt.free
    for i = 1, #free do
        if IsCastOf(castID, free[i]) then return true end
    end
    return false
end

function Engine.OnCastResult(rt, castID, entry, altID)
    local holds = rt.holds
    local suggested = entry and entry.spellID
    for id, h in pairs(holds) do
        if IsCastOf(castID, id) then
            holds[id] = nil
        elseif not h.held and id ~= suggested then
            h.count = 0
        end
    end
    if not (entry and entry.hold) or IsCastOf(castID, suggested) then return nil end
    local h = holds[suggested]
    if not h then
        h = { count = 0, held = false }
        holds[suggested] = h
    end
    if h.held then return nil end
    -- Casting the fork's alternative (the next valid action shown beside the
    -- hold line) holds the spell, from the second cast while the hold line
    -- is up: the first may be a press already on its way when the hold
    -- spell came off cooldown (often the same spell as the alternative). The
    -- whole ignore streak, this cast included, is forgiven.
    if altID and castID == altID and h.count >= 1 then
        local n = h.count + 1
        h.count, h.held = math.max(n, entry.hold), true
        return ResolveOverride(suggested), n, "alternative"
    end
    h.count = h.count + 1
    if h.count < entry.hold then return nil end
    h.held = true
    return ResolveOverride(suggested), h.count, "ignores"
end

-- For the stats display: "held" when any spell is held, "warning" when a
-- holdable entry has been ignored 2+ times in a row, else nil.
function Engine.HoldState(rt)
    local state
    for _, h in pairs(rt.holds) do
        if h.held then return "held" end
        if h.count >= 2 then state = "warning" end
    end
    return state
end

-- Fills out (wiped first) with the spellID (override-resolved) of every
-- spell currently held; for the Persistent Hold glow.
function Engine.HeldSpells(rt, out)
    wipe(out)
    for id, h in pairs(rt.holds) do
        if h.held then out[#out + 1] = ResolveOverride(id) end
    end
    return out
end

-- Combat ended: every hold and count starts over.
function Engine.ClearHolds(rt)
    wipe(rt.holds)
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
