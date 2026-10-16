local _, ns = ...

-------------------------------------------------------------------------------
--  APL editor, data harvesting UI: the switch and catalog tools (APLs tab)
--  and the Discovered section (Building Blocks tab) that adds harvested
--  spells, buffs and buff timers to the APL. Logic lives in Harvest.lua.
-------------------------------------------------------------------------------
local Kit = ns.EditorKit
local Store = ns.Store
local Harvest = ns.Harvest
local Editor = ns.Editor

local INSTRUCTIONS = "Cast each ability once, then let combat drop. For procs, keep casting until the buff appears, then let combat drop. "
    .. "Buffs, durations and what caused them can only be read out of combat."

-------------------------------------------------------------------------------
--  APLs tab: switch, counts, export, clear
-------------------------------------------------------------------------------
function Editor.BuildHarvestSection(parent, y)
    local W = EllesmereUI.Widgets
    local _, h
    local specID = Kit.SpecID()
    local live = specID == ns.GetSpecID()

    _, h = W:SectionHeader(parent, "DATA HARVESTING", y); y = y - h
    local c = Harvest.Counts(specID)
    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Harvest Data",
          tooltip = "While on, collects your spec's spells, talents, Cooldown Manager entries, casts and buffs for the Discovered section on the Building Blocks tab. " .. INSTRUCTIONS,
          getValue = function() return Harvest.Enabled() end,
          setValue = function(v) Harvest.SetEnabled(v); Kit.Rebuild() end },
        { type = "label", text = string.format("|cff909090%d spells (%d in CDM, %d cast), %d buffs (%d with a cause)|r",
            c.spells, c.cdm, c.casted, c.auras, c.timed) })
    y = y - h
    if not live then
        y = Kit.Note(parent, y, "Harvesting collects for the spec you are playing; this shows the catalog for " .. Kit.SpecLabel(specID) .. ".")
    end
    y = Kit.Note(parent, y, INSTRUCTIONS)
    _, h = W:DualRow(parent, y,
        { type = "button", text = "Export Harvest", onClick = function()
            Kit.TextPopup({
                title = "Harvest for " .. Kit.SpecLabel(specID), readOnly = true,
                subtitle = "Press Ctrl+C to copy. Useful for building default APLs.",
                text = Harvest.Export(specID),
            })
        end },
        { type = "button", text = "Clear Harvest", onClick = function()
            Kit.Confirm("Clear everything harvested for " .. Kit.SpecLabel(specID) .. "?", function()
                Harvest.Clear(specID)
                Kit.Rebuild()
            end)
        end })
    return y - h
end

-------------------------------------------------------------------------------
--  Building Blocks tab: Discovered
-------------------------------------------------------------------------------

-- Stable tables so each category's open state survives rebuilds.
local CATEGORIES = {
    { key = "cdmSpells", title = "Cooldown Manager abilities",
      tip = "Abilities your spec can show in the Cooldown Manager." },
    { key = "cdmBuffs", title = "Cooldown Manager buffs",
      tip = "Buffs your spec can track in the Cooldown Manager. Only tracked buffs are reliable in combat." },
    { key = "buffs", title = "Other buffs seen",
      tip = "Your buffs seen out of combat that the Cooldown Manager doesn't track (unreliable in combat unless you track them there)." },
    { key = "casts", title = "Other abilities cast", tip = "Spells you cast that aren't Cooldown Manager abilities." },
    { key = "talents", title = "Talents", tip = "Your active talents, including the hero tree, for talent.<name> conditions." },
    { key = "spellbook", title = "Other spellbook abilities", tip = "Class and spec abilities not listed above." },
}

Editor.DISCOVERED_CATEGORIES = CATEGORIES

-- Catalog -> { [key] = { item, ... } } with item = { id, name, aura, tags }.
local function Sorted(cat)
    local out = {}
    for _, c in ipairs(CATEGORIES) do out[c.key] = {} end
    for id, s in pairs(cat.spells) do
        local src = s.sources
        local key
        if src.cdm and not s.passive then key = "cdmSpells"
        elseif s.casts and not src.talent then key = "casts"
        elseif src.talent then key = "talents"
        elseif src.spellbook and not s.passive then key = "spellbook" end
        if key then
            local tags = {}
            if s.cd then tags[#tags + 1] = string.format("%gs cd", s.cd) end
            if s.charges then tags[#tags + 1] = s.charges .. " charges" end
            if s.casts then tags[#tags + 1] = "cast " .. s.casts .. "x" end
            out[key][#out[key] + 1] = { id = id, name = s.name or ("Spell " .. id), tags = tags }
        end
    end
    for id, a in pairs(cat.auras) do
        local key = a.cdm and "cdmBuffs" or "buffs"
        local tags = {}
        if a.duration then tags[#tags + 1] = string.format("%gs", a.duration) end
        if a.stacks and a.stacks > 1 then tags[#tags + 1] = "up to " .. a.stacks .. " stacks" end
        local cause = Harvest.MainCause(a)
        local causeName = cause and (cat.spells[cause] and cat.spells[cause].name or ("Spell " .. cause))
        if causeName then tags[#tags + 1] = "from " .. causeName end
        if a.unit == "pet" then tags[#tags + 1] = "pet" end
        out[key][#out[key] + 1] = {
            id = id, name = a.name or ("Spell " .. id), aura = a, tags = tags,
            cause = cause, causeName = causeName,
        }
    end
    for _, list in pairs(out) do
        table.sort(list, function(x, y) return x.name < y.name end)
    end
    return out
end

local function AddItem(def, item)
    if item.aura and item.cause and item.aura.duration then
        Store.AddTimerForAura(def, item.id, item.name, item.cause, item.causeName, item.aura.duration)
    else
        Store.EnsureName(def, item.id, item.name, item.aura ~= nil)
    end
end

function Editor.BuildDiscovered(parent, y, def, editable)
    local W = EllesmereUI.Widgets
    local _, h
    _, h = W:SectionHeader(parent, "DISCOVERED", y); y = y - h
    local cat = Harvest.Catalog(def.specID)
    local lists = Sorted(cat)
    local total = 0
    for _, list in pairs(lists) do total = total + #list end
    if total == 0 then
        return Kit.Note(parent, y, "Nothing harvested for this spec yet. Turn on Harvest Data on the APLs tab, then play as described there.")
    end
    if not editable then
        y = Kit.Note(parent, y, "Duplicate this built-in APL to add discovered spells and buffs.")
    end

    for _, c in ipairs(CATEGORIES) do
        local list = lists[c.key]
        if #list > 0 then
            local added = 0
            for _, item in ipairs(list) do if Store.NameOf(def, item.id) then added = added + 1 end end
            local open = Kit.IsOpen(c)
            local top = y
            y = Kit.Header(parent, y, {
                title = c.title .. "   |cff909090" .. #list .. " found, " .. added .. " added|r",
                tooltip = c.tip, open = open,
                onClick = function() Kit.Toggle(c) end,
            })
            if open then
                local sub = Kit.Child(parent)
                _, h = W:DualRow(sub, y,
                    { type = "button", text = "Add All",
                      tooltip = "Adds every entry below that isn't in this APL yet (buffs with a known cause and duration as timers).",
                      disabled = function() return not editable or added == #list end,
                      disabledTooltip = Kit.READ_ONLY_TIP,
                      onClick = function()
                          for _, item in ipairs(list) do
                              if not Store.NameOf(def, item.id) then AddItem(def, item) end
                          end
                          Kit.Rebuild()
                      end },
                    { type = "spacer" })
                y = y - h
                for _, item in ipairs(list) do
                    local short = Store.NameOf(def, item.id)
                    local asTimer = item.aura and item.cause and item.aura.duration
                    local label = item.name .. "  |cff909090" .. item.id
                        .. (#item.tags > 0 and ("  " .. table.concat(item.tags, ", ")) or "") .. "|r"
                    _, h = W:DualRow(sub, y,
                        { type = "label", text = label },
                        { type = "button",
                          text = short and ("Added: " .. short) or (asTimer and "Add as Timer" or "Add"),
                          tooltip = asTimer and ("Adds the buff and a timer: on each " .. item.causeName
                              .. ", set to " .. string.format("%g", item.aura.duration) .. " seconds.") or nil,
                          disabled = function() return not editable or Store.NameOf(def, item.id) ~= nil end,
                          disabledTooltip = editable and "This option is already in this APL." or Kit.READ_ONLY_TIP,
                          onClick = function()
                              AddItem(def, item)
                              Kit.Rebuild()
                          end })
                    y = y - h
                end
                Kit.OpenSpan(parent, top, y, 0)
            end
        end
    end
    return y
end
