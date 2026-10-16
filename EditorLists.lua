local _, ns = ...

-------------------------------------------------------------------------------
--  APL editor, Lists tab: groups (name, "active when" condition, priority
--  order), each with its lists (name, prefix, target range) and their
--  entries (spell, on/off, condition). design.md, phase 5.
-------------------------------------------------------------------------------
local Kit = ns.EditorKit
local Store = ns.Store
local Engine = ns.Engine
local Editor = ns.Editor

local function Say(msg) print("|cff60c0ffAPL for EUI|r: " .. msg) end

local function RangeText(list)
    if not list.max then return list.min .. "+ targets" end
    if list.max == list.min then return list.min .. (list.min == 1 and " target" or " targets") end
    return list.min .. "-" .. list.max .. " targets"
end

local function SpellLabel(def, name)
    local id = def.names and def.names[name]
    if not id then return "|cffff6060" .. tostring(name) .. " (unknown)|r" end
    return ns.SpellName(id)
end

local function Preview(text)
    if not text or text == "" then return "always" end
    if #text > 70 then return text:sub(1, 67) .. "..." end
    return text
end

-- Typed spell text -> short name in def (created if new), or nil + message.
local function SpellFromText(def, text)
    local id, name = Store.LookupSpell(text)
    if not id then
        if text and text:match("%S") then Say("no spell found for \"" .. text .. "\".") end
        return nil
    end
    return Store.EnsureName(def, id, name)
end

-- Builds one list's open body: fields, entries, add-entry row.
local function BuildListBody(parent, y, def, list, editable)
    local W = EllesmereUI.Widgets
    local _, h
    local ro = function() return not editable end

    _, h = W:DualRow(parent, y,
        { type = "input", text = "List Name", inputWidth = 170, inputStyle = "popup",
          disabled = ro, disabledTooltip = Kit.READ_ONLY_TIP,
          getValue = function() return list.name end,
          setValue = function(v)
              v = v:match("^%s*(.-)%s*$")
              if v ~= "" and v ~= list.name then list.name = v; Store.Changed(def); Kit.RebuildAll() end
          end },
        { type = "input", text = "Prefix", inputWidth = 60, inputStyle = "popup",
          tooltip = "1-3 characters shown before each entry's position on the Suggestion Widget (ST3, AOE12).",
          disabled = ro, disabledTooltip = Kit.READ_ONLY_TIP,
          getValue = function() return list.prefix end,
          setValue = function(v)
              v = v:match("^%s*(.-)%s*$")
              if v == list.prefix then return end
              if not Engine.ValidPrefix(v) then Say("a prefix must be 1-3 characters.") return end
              list.prefix = v
              Store.Changed(def)
              Kit.Rebuild()
          end })
    y = y - h

    local function SetRange(min, max)
        if not min or min < 1 or min ~= math.floor(min) then Say("targets must be a whole number of 1 or more.") return end
        if max and (max < min or max ~= math.floor(max)) then Say("max targets must be a whole number at least the min.") return end
        local clash = Store.RangeConflict(def, list, min, max)
        if clash then Say("that range " .. clash .. ".") return end
        list.min, list.max = min, max
        Store.Changed(def)
        Kit.Rebuild()
    end
    _, h = W:DualRow(parent, y,
        { type = "input", text = "Min Targets", inputWidth = 60, inputStyle = "popup",
          disabled = ro, disabledTooltip = Kit.READ_ONLY_TIP,
          getValue = function() return tostring(list.min) end,
          setValue = function(v) SetRange(tonumber(v), list.max) end },
        { type = "input", text = "Max Targets", inputWidth = 60, inputStyle = "popup",
          placeholder = "None", tooltip = "Leave empty for no upper limit.",
          disabled = ro, disabledTooltip = Kit.READ_ONLY_TIP,
          getValue = function() return list.max and tostring(list.max) or "" end,
          setValue = function(v)
              if v:match("^%s*$") then SetRange(list.min, nil) else SetRange(list.min, tonumber(v)) end
          end })
    y = y - h

    local count = #list.entries
    if count == 0 then
        y = Kit.Note(parent, y, "No entries yet. Add one below; entries are checked top to bottom and the first match is suggested.")
    end
    for j, entry in ipairs(list.entries) do
        local open = Kit.IsOpen(entry)
        y = Kit.Header(parent, y, {
            depth = 2,
            title = "|cff909090" .. tostring(list.prefix) .. j .. "|r   " .. SpellLabel(def, entry.spell)
                .. "   |cff707070" .. Preview(entry.when) .. "|r",
            open = open, editable = editable, index = j, count = count,
            onClick = function() Kit.Toggle(entry) end,
            onMove = function(d) Store.Move(def, list.entries, j, d); Kit.Rebuild() end,
            getOn = function() return entry.enabled ~= false end,
            -- false when off; nil (the default) when on.
            setOn = function(v) if v then entry.enabled = nil else entry.enabled = false end; Store.Changed(def) end,
            onTip = "Switched-off entries stay in the list but are never suggested.",
            onDelete = function()
                Kit.Confirm("Remove entry " .. list.prefix .. j .. " (" .. SpellLabel(def, entry.spell) .. ")?", function()
                    Store.Remove(def, list.entries, j)
                    Kit.Rebuild()
                end)
            end,
            deleteTip = "Remove entry",
        })
        if open then
            _, h = W:DualRow(parent, y,
                { type = "input", text = "Spell", inputWidth = 200, inputStyle = "popup",
                  placeholder = "Spell name or ID",
                  disabled = ro, disabledTooltip = Kit.READ_ONLY_TIP,
                  getValue = function() return SpellLabel(def, entry.spell) end,
                  setValue = function(v)
                      local name = SpellFromText(def, v)
                      if name and name ~= entry.spell then entry.spell = name; Store.Changed(def); Kit.Rebuild() end
                  end },
                { type = "toggle", text = "Only When Usable",
                  tooltip = "Skip this entry while the game says the spell can't be cast (resources, requirements, not talented). Leave on unless the game's usable flag is wrong for this spell.",
                  disabled = ro, disabledTooltip = Kit.READ_ONLY_TIP,
                  getValue = function() return entry.usable ~= false end,
                  setValue = function(v) if v then entry.usable = nil else entry.usable = false end; Store.Changed(def) end })
            y = y - h
            y = Kit.Condition(parent, y, def, {
                owner = entry, editable = editable, label = "Condition",
                get = function() return entry.when end,
                set = function(t) entry.when = t; Store.Changed(def) end,
            })
        end
    end

    _, h = W:DualRow(parent, y,
        { type = "input", text = "Add Entry", inputWidth = 200, inputStyle = "popup",
          placeholder = "Spell name or ID",
          disabled = ro, disabledTooltip = Kit.READ_ONLY_TIP,
          getValue = function() return "" end,
          setValue = function(v)
              local name = SpellFromText(def, v)
              if not name then return end
              local entry = Store.AddEntry(def, list, name)
              Kit.state.open[entry] = true
              Kit.Rebuild()
          end },
        { type = "spacer" })
    return y - h
end

local function GroupTitle(group)
    local count = #(group.lists or {})
    local cond = (group.when and group.when ~= "") and ("active when " .. Preview(group.when)) or "always active"
    return group.name .. "   |cff909090" .. tostring(group.prefix) .. "  |  " .. cond .. "  |  " .. count .. (count == 1 and " list" or " lists") .. "|r"
end

-- One group's open body: name, condition, opener preset, its lists.
local function BuildGroupBody(parent, y, def, group, editable)
    local W = EllesmereUI.Widgets
    local _, h
    local ro = function() return not editable end

    _, h = W:DualRow(parent, y,
        { type = "input", text = "Group Name", inputWidth = 170, inputStyle = "popup",
          disabled = ro, disabledTooltip = Kit.READ_ONLY_TIP,
          getValue = function() return group.name end,
          setValue = function(v)
              v = v:match("^%s*(.-)%s*$")
              if v ~= "" and v ~= group.name then group.name = v; Store.Changed(def); Kit.Rebuild() end
          end },
        { type = "input", text = "Prefix", inputWidth = 60, inputStyle = "popup",
          tooltip = "1-3 characters. The status widget shows <group prefix>-<list prefix> (OP-ST); the name is only for this editor.",
          disabled = ro, disabledTooltip = Kit.READ_ONLY_TIP,
          getValue = function() return group.prefix or "" end,
          setValue = function(v)
              v = v:match("^%s*(.-)%s*$")
              if v == group.prefix then return end
              if not Engine.ValidPrefix(v) then Say("a prefix must be 1-3 characters.") return end
              group.prefix = v
              Store.Changed(def)
              Kit.Rebuild()
          end })
    y = y - h
    _, h = W:DualRow(parent, y,
        { type = "button", text = "Use Opener Preset",
          tooltip = "Active for the first 5 casts or 8 seconds of combat (and before the pull). Edit the numbers below.",
          disabled = ro, disabledTooltip = Kit.READ_ONLY_TIP,
          onClick = function()
              group.when = Store.OPENER_PRESET
              Store.Changed(def)
              Kit.Rebuild()
          end },
        { type = "spacer" })
    y = y - h
    y = Kit.Condition(parent, y, def, {
        owner = group, editable = editable, label = "Active When",
        get = function() return group.when end,
        set = function(t) group.when = t; Store.Changed(def) end,
    })

    local count = #group.lists
    for i, list in ipairs(group.lists) do
        local open = Kit.IsOpen(list)
        y = Kit.Header(parent, y, {
            depth = 1,
            title = list.name .. "   |cff909090" .. tostring(list.prefix) .. "  |  " .. RangeText(list)
                .. "  |  " .. #list.entries .. (#list.entries == 1 and " entry" or " entries") .. "|r",
            open = open, editable = editable, index = i, count = count,
            tooltip = "This group's list for target counts in its range.",
            onClick = function() Kit.Toggle(list) end,
            onMove = function(d) Store.Move(def, group.lists, i, d); Kit.Rebuild() end,
            onDelete = function()
                Kit.Confirm("Delete the list \"" .. list.name .. "\" and its " .. #list.entries .. " entries?", function()
                    Store.Remove(def, group.lists, i)
                    Kit.Rebuild()
                end)
            end,
            deleteTip = "Delete list",
        })
        if open then y = BuildListBody(parent, y, def, list, editable) end
    end

    _, h = W:DualRow(parent, y,
        { type = "button", text = "Add List",
          disabled = ro, disabledTooltip = Kit.READ_ONLY_TIP,
          onClick = function()
              local list, why = Store.AddList(def, group)
              if not list then Say("can't add a list: " .. why .. ". Give an existing list a max target count first.") return end
              Kit.state.open[list] = true
              Kit.Rebuild()
          end },
        { type = "spacer" })
    return y - h
end

function Editor.BuildListsPage(parent, yOffset)
    local W = EllesmereUI.Widgets
    local y = yOffset
    local _, h
    local def = Kit.Def()
    if not def then
        return math.abs(Kit.Note(parent, y, "No APL for this spec yet. Create one on the APLs tab."))
    end
    local editable = Kit.Editable()

    if not editable then
        y = Kit.Note(parent, y, "\"" .. def.name .. "\" is built in and read-only. Duplicate it to make your own editable copy.")
        _, h = W:DualRow(parent, y,
            { type = "button", text = "Duplicate to Edit", onClick = function()
                local copy = Store.Duplicate(def)
                Kit.SelectAPL(copy.id)
            end },
            { type = "spacer" })
        y = y - h
    end

    y = Kit.Problems(parent, y, def)
    _, h = W:SectionHeader(parent, "GROUPS", y); y = y - h
    y = Kit.Note(parent, y, "Groups are tried top to bottom. The first active group with a list for the target count suggests; if that list has nothing, the next group gets a turn.")
    local groups = def.groups or {}
    for i, group in ipairs(groups) do
        local open = Kit.IsOpen(group)
        y = Kit.Header(parent, y, {
            title = GroupTitle(group),
            open = open, editable = editable, index = i, count = #groups,
            tooltip = "A set of lists that takes priority over the groups below it while its condition holds.",
            onClick = function() Kit.Toggle(group) end,
            onMove = function(d) Store.Move(def, groups, i, d); Kit.Rebuild() end,
            onDelete = #groups > 1 and function()
                Kit.Confirm("Delete the group \"" .. group.name .. "\" and all its lists?", function()
                    Store.Remove(def, groups, i)
                    Kit.Rebuild()
                end)
            end or nil,
            deleteTip = "Delete group",
        })
        if open then y = BuildGroupBody(parent, y, def, group, editable) end
    end

    _, h = W:DualRow(parent, y,
        { type = "button", text = "Add Group",
          tooltip = "Adds a group at the top (highest priority), for an opener or a burst window.",
          disabled = function() return not editable end, disabledTooltip = Kit.READ_ONLY_TIP,
          onClick = function()
              local group = Store.AddGroup(def)
              Kit.state.open[group] = true
              Kit.Rebuild()
          end },
        { type = "spacer" })
    y = y - h
    return math.abs(y)
end
