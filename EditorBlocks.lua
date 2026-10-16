local _, ns = ...

-------------------------------------------------------------------------------
--  APL editor, Building Blocks tab: variables, timers, counters, spell short
--  names and TTS. Renames go through Store.RenameBlock, which rewrites every
--  reference, so nothing silently breaks.
-------------------------------------------------------------------------------
local Kit = ns.EditorKit
local Store = ns.Store
local Engine = ns.Engine
local Editor = ns.Editor

local function Say(msg) print("|cff60c0ffAPL for EUI|r: " .. msg) end

local EVENT_VALUES = { cast = "Cast of spell", aura_present = "Buff is up", aura_absent = "Buff is down" }
local EVENT_ORDER = { "cast", "aura_present", "aura_absent" }
local TIMER_ACTIONS = { set = "Set to", start = "Start (if not running)", add = "Extend by", clear = "Clear" }
local TIMER_ACTION_ORDER = { "set", "start", "add", "clear" }
local COUNTER_ACTIONS = { set = "Set to", add = "Add", sub = "Subtract", reset = "Reset" }
local COUNTER_ACTION_ORDER = { "set", "add", "sub", "reset" }
local NO_VALUE = { clear = true, reset = true }

local function SpellLabel(def, name)
    local id = def.names and def.names[name]
    if not id then return "|cffff6060" .. tostring(name) .. " (unknown)|r" end
    return ns.SpellName(id)
end

local function Renamer(def, kind, item)
    return function(v)
        local ok, why = Store.RenameBlock(def, kind, item, v)
        if not ok then Say("can't rename: " .. why .. ".") return end
        Kit.Rebuild()
    end
end

local function TriggerSummary(def, trig, actions)
    local what = EVENT_VALUES[trig.on] or "?"
    local s = what .. " " .. SpellLabel(def, trig.spell) .. ": " .. (actions[trig.action] or "?")
    if not NO_VALUE[trig.action] and trig.value then s = s .. " " .. trig.value end
    if trig.when and trig.when ~= "" then s = s .. "  |cff707070if " .. trig.when .. "|r" end
    return s
end

-- Triggers of one timer or counter.
local function BuildTriggers(parent, y, def, item, kind, editable)
    local W = EllesmereUI.Widgets
    local _, h
    local ro = function() return not editable end
    local actions = kind == "timer" and TIMER_ACTIONS or COUNTER_ACTIONS
    local actionOrder = kind == "timer" and TIMER_ACTION_ORDER or COUNTER_ACTION_ORDER
    -- Triggers (and Add Trigger) are the block's children: indented under it.
    local sub = Kit.Child(parent)
    local count = #item.triggers

    if count == 0 then
        y = Kit.Note(sub, y, "No triggers: this " .. kind .. " never changes. For each event, the first matching trigger runs.")
    end
    for k, trig in ipairs(item.triggers) do
        local open = Kit.IsOpen(trig)
        local top = y
        y = Kit.Header(sub, y, {
            title = TriggerSummary(def, trig, actions),
            open = open, editable = editable, index = k, count = count,
            onClick = function() Kit.Toggle(trig) end,
            onMove = function(d) Store.Move(def, item.triggers, k, d); Kit.Rebuild() end,
            onDelete = function() Store.Remove(def, item.triggers, k); Kit.Rebuild() end,
            deleteTip = "Remove trigger",
        })
        if open then
            _, h = W:DualRow(sub, y,
                { type = "dropdown", text = "When", values = EVENT_VALUES, order = EVENT_ORDER,
                  disabled = ro, disabledTooltip = Kit.READ_ONLY_TIP,
                  getValue = function() return trig.on end,
                  setValue = function(v) trig.on = v; Store.Changed(def); Kit.Rebuild() end },
                { type = "input", text = trig.on == "cast" and "Spell" or "Buff", inputWidth = 190, inputStyle = "popup",
                  placeholder = "Spell name or ID",
                  disabled = ro, disabledTooltip = Kit.READ_ONLY_TIP,
                  getValue = function() return trig.spell and SpellLabel(def, trig.spell) or "" end,
                  setValue = function(v)
                      local id, name = Store.LookupSpell(v)
                      if not id then if v:match("%S") then Say("no spell found for \"" .. v .. "\".") end return end
                      trig.spell = Store.EnsureName(def, id, name)
                      Store.Changed(def)
                      Kit.Rebuild()
                  end })
            y = y - h
            _, h = W:DualRow(sub, y,
                { type = "dropdown", text = "Action", values = actions, order = actionOrder,
                  disabled = ro, disabledTooltip = Kit.READ_ONLY_TIP,
                  getValue = function() return trig.action end,
                  setValue = function(v)
                      trig.action = v
                      if NO_VALUE[v] then trig.value = nil elseif not trig.value then trig.value = "1" end
                      Store.Changed(def)
                      Kit.Rebuild()
                  end },
                NO_VALUE[trig.action] and { type = "spacer" } or
                { type = "input", text = kind == "timer" and "Seconds" or "Amount", inputWidth = 190, inputStyle = "popup",
                  tooltip = "A number or an expression, e.g. 6 or spell.invoke_xuen.base_cd.",
                  disabled = ro, disabledTooltip = Kit.READ_ONLY_TIP,
                  getValue = function() return trig.value or "" end,
                  setValue = function(v)
                      v = v:match("^%s*(.-)%s*$")
                      local ok, err = Engine.CheckExpr(def, v)
                      if v == "" or not ok then Say("invalid value: " .. tostring(err or "empty") .. ".") return end
                      trig.value = v
                      Store.Changed(def)
                      Kit.Rebuild()
                  end })
            y = y - h
            y = Kit.Condition(sub, y, def, {
                owner = trig, editable = editable, label = "Only If",
                get = function() return trig.when end,
                set = function(t) trig.when = t ~= "" and t or nil; Store.Changed(def) end,
            })
            Kit.OpenSpan(sub, top, y, 0)
        end
    end
    local _, hh = W:DualRow(sub, y,
        { type = "button", text = "Add Trigger", disabled = ro, disabledTooltip = Kit.READ_ONLY_TIP,
          onClick = function()
              local trig = { on = "cast", action = kind == "timer" and "set" or "add", value = "1" }
              item.triggers[#item.triggers + 1] = trig
              Kit.state.open[trig] = true
              Store.Changed(def)
              Kit.Rebuild()
          end },
        { type = "spacer" })
    return y - hh
end

-- One section of named, ordered blocks (variables / timers / counters).
local function BuildBlockSection(parent, y, def, kind, editable)
    local W = EllesmereUI.Widgets
    local _, h
    local ro = function() return not editable end
    local arrayKey = kind == "timer" and "timers" or kind == "counter" and "counters" or "variables"
    local array = def[arrayKey] or {}
    local titles = { variable = "VARIABLES", timer = "TIMERS", counter = "COUNTERS" }
    local tips = {
        variable = "Named expressions, used as variable.<name>. A variable can only use variables above it.",
        timer = "Clocks you start, extend and clear on events; read as timer.<name>.up / .remains.",
        counter = "Numbers you change on events; read as counter.<name>.",
    }
    _, h = W:SectionHeader(parent, titles[kind], y); y = y - h
    if #array == 0 then y = Kit.Note(parent, y, tips[kind]) end

    for i, item in ipairs(array) do
        local open = Kit.IsOpen(item)
        local top = y
        local title = kind .. "." .. item.name
        if kind == "variable" then
            title = title .. "   |cff707070" .. ((item.expr or "") ~= "" and item.expr or "(empty)") .. "|r"
        else
            title = title .. "   |cff909090" .. #item.triggers .. (#item.triggers == 1 and " trigger" or " triggers") .. "|r"
        end
        y = Kit.Header(parent, y, {
            title = title, tooltip = tips[kind],
            open = open, editable = editable, index = i, count = #array,
            onClick = function() Kit.Toggle(item) end,
            onMove = function(d) Store.Move(def, array, i, d); Kit.Rebuild() end,
            onDelete = function()
                Kit.Confirm("Delete " .. kind .. "." .. item.name .. "? Conditions that use it will show an error.", function()
                    Store.Remove(def, array, i)
                    Kit.Rebuild()
                end)
            end,
        })
        if open then
            local right = { type = "spacer" }
            if kind == "counter" then
                right = { type = "input", text = "Start / Min / Max", inputWidth = 120, inputStyle = "popup",
                    tooltip = "Starting value, lowest and highest value, e.g. 2 / 0 / 2. Leave Max empty for no limit.",
                    disabled = ro, disabledTooltip = Kit.READ_ONLY_TIP,
                    getValue = function()
                        return (item.initial or 0) .. " / " .. (item.min or 0) .. " / " .. (item.max and tostring(item.max) or "")
                    end,
                    setValue = function(v)
                        local a, b, c = v:match("^%s*(%-?[%d%.]+)%s*/%s*(%-?[%d%.]+)%s*/?%s*(%-?[%d%.]*)%s*$")
                        a, b = tonumber(a), tonumber(b)
                        if not a or not b then Say("enter start / min / max, e.g. 2 / 0 / 2.") return end
                        item.initial, item.min, item.max = a, b, tonumber(c)
                        Store.Changed(def)
                        Kit.Rebuild()
                    end }
            end
            _, h = W:DualRow(parent, y,
                { type = "input", text = "Name", inputWidth = 170, inputStyle = "popup",
                  tooltip = "Renaming updates every condition that uses it.",
                  disabled = ro, disabledTooltip = Kit.READ_ONLY_TIP,
                  getValue = function() return item.name end,
                  setValue = Renamer(def, kind, item) },
                right)
            y = y - h
            if kind == "variable" then
                y = Kit.Condition(parent, y, def, {
                    owner = item, editable = editable, label = "Expression",
                    get = function() return item.expr end,
                    set = function(t) item.expr = t; Store.Changed(def) end,
                })
            else
                y = BuildTriggers(parent, y, def, item, kind, editable)
            end
            Kit.OpenSpan(parent, top, y, 0)
        end
    end
    _, h = W:DualRow(parent, y,
        { type = "button", text = "Add " .. kind:sub(1, 1):upper() .. kind:sub(2),
          disabled = ro, disabledTooltip = Kit.READ_ONLY_TIP,
          onClick = function()
              local item = Store.AddBlock(def, kind)
              Kit.state.open[item] = true
              Kit.Rebuild()
          end },
        { type = "spacer" })
    return y - h
end

-- Spell short names, each with its TTS text.
local function BuildNames(parent, y, def, editable)
    local W = EllesmereUI.Widgets
    local _, h
    local ro = function() return not editable end
    _, h = W:SectionHeader(parent, "SPELL NAMES", y); y = y - h
    y = Kit.Note(parent, y, "Short names used in conditions (buff.<name>.up). Entries add these automatically. Renaming updates every condition.")
    local names = {}
    for name in pairs(def.names or {}) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local id = def.names[name]
        _, h = W:DualRow(parent, y,
            { type = "input", text = SpellLabel(def, name) .. " |cff909090(" .. id .. ")|r", inputWidth = 170, inputStyle = "popup",
              disabled = ro, disabledTooltip = Kit.READ_ONLY_TIP,
              getValue = function() return name end,
              setValue = Renamer(def, "name", name) },
            { type = "input", text = "Spoken As", inputWidth = 120, inputStyle = "popup",
              placeholder = "Silent",
              tooltip = "What the Suggestion Widget's TTS says when this spell is suggested.",
              disabled = ro, disabledTooltip = Kit.READ_ONLY_TIP,
              getValue = function() return def.tts and def.tts[name] or "" end,
              setValue = function(v)
                  v = v:match("^%s*(.-)%s*$")
                  def.tts = def.tts or {}
                  def.tts[name] = v ~= "" and v or nil
                  Store.Changed(def)
              end })
        y = y - h
    end
    _, h = W:DualRow(parent, y,
        { type = "input", text = "Add Spell", inputWidth = 200, inputStyle = "popup",
          placeholder = "Spell name or ID",
          tooltip = "Adds a short name for a spell, buff or talent you want to use in conditions.",
          disabled = ro, disabledTooltip = Kit.READ_ONLY_TIP,
          getValue = function() return "" end,
          setValue = function(v)
              local id, spellName = Store.LookupSpell(v)
              if not id then if v:match("%S") then Say("no spell found for \"" .. v .. "\".") end return end
              Store.EnsureName(def, id, spellName)
              Kit.Rebuild()
          end },
        { type = "spacer" })
    return y - h
end

function Editor.BuildBlocksPage(parent, yOffset)
    local y = yOffset
    local def = Kit.Def()
    if not def then
        return math.abs(Kit.Note(parent, y, "No APL for this spec yet. Create one on the APLs tab."))
    end
    local editable = Kit.Editable()
    if not editable then
        y = Kit.Note(parent, y, "\"" .. def.name .. "\" is built in and read-only. Duplicate it on the APLs or Lists tab to edit.")
    end
    y = Kit.Problems(parent, y, def)
    y = Editor.BuildDiscovered(parent, y, def, editable)
    y = BuildBlockSection(parent, y, def, "variable", editable)
    y = BuildBlockSection(parent, y, def, "timer", editable)
    y = BuildBlockSection(parent, y, def, "counter", editable)
    y = BuildNames(parent, y, def, editable)
    return math.abs(y)
end
