local _, ns = ...

-------------------------------------------------------------------------------
--  APL editor: the fixed header (spec + APL picker) and the APLs tab
--  (choose which APL runs, duplicate / rename / delete / new, options).
-------------------------------------------------------------------------------
local Kit = ns.EditorKit
local Store = ns.Store
local Editor = {}
ns.Editor = Editor

-------------------------------------------------------------------------------
--  Header: Spec and APL dropdowns, plus whether the edited APL is running.
-------------------------------------------------------------------------------
function Editor.BuildHeader(hdr, hdrW)
    local H = 86
    local specID = Kit.SpecID()
    local def = Kit.Def()

    local specs = Store.SpecsWithAPLs()
    local current = ns.GetSpecID()
    local haveCurrent = false
    for _, id in ipairs(specs) do if id == current then haveCurrent = true end end
    if current and not haveCurrent then table.insert(specs, 1, current) end
    local specValues = {}
    for _, id in ipairs(specs) do specValues[id] = Kit.SpecLabel(id) end

    local aplValues, aplOrder = {}, {}
    for _, d in ipairs(Store.ListForSpec(specID)) do
        aplValues[d.id] = d.name
        aplOrder[#aplOrder + 1] = d.id
    end

    -- Spec | APL | condition view, each with a small caption above it.
    local level = hdr:GetFrameLevel() + 2
    local aplDD = EllesmereUI.BuildDropdownControl(hdr, 220, level, aplValues, aplOrder,
        function() return def and def.id end,
        function(v) Kit.SelectAPL(v) end)
    aplDD:SetPoint("TOP", hdr, "TOP", 0, -26)
    local specDD = EllesmereUI.BuildDropdownControl(hdr, 220, level, specValues, specs,
        function() return specID end,
        function(v) Kit.SelectSpec(v) end)
    specDD:SetPoint("RIGHT", aplDD, "LEFT", -16, 0)
    local modeDD = EllesmereUI.BuildDropdownControl(hdr, 140, level,
        { builder = "Builder", text = "Text" }, { "builder", "text" },
        Kit.ConditionMode, Kit.SetConditionMode)
    modeDD:SetPoint("LEFT", aplDD, "RIGHT", 16, 0)

    local function Caption(dd, text)
        local fs = EllesmereUI.MakeFont(hdr, 11, nil, 1, 1, 1, EllesmereUI.TEXT_DIM_A)
        fs:SetPoint("BOTTOMLEFT", dd, "TOPLEFT", 2, 4)
        fs:SetText(text)
    end
    Caption(specDD, "Spec")
    Caption(aplDD, "APL")
    Caption(modeDD, "Edit Conditions As")

    local status = EllesmereUI.MakeFont(hdr, 11, nil, 1, 1, 1, 0.8)
    status:SetPoint("TOP", hdr, "TOP", 0, -64)
    if not def then
        status:SetText("No APL for this spec yet. Create one on the APLs tab.")
    else
        local running = Store.ActiveID(specID) == def.id
        local parts = { running and "|cff60d060Running for this spec|r" or "|cffd0a040Not running|r (set it to run on the APLs tab)" }
        if def.builtin then parts[#parts + 1] = "built-in, read-only" end
        status:SetText(table.concat(parts, "   |   "))
    end
    return H
end

-------------------------------------------------------------------------------
--  APLs tab
-------------------------------------------------------------------------------
local function ReadOnly() return not Kit.Editable() end

local function RangeSpellText(def)
    local name = def.options and def.options.rangeSpell
    local id = name and def.names and def.names[name]
    if not id then return "" end
    return ns.SpellName(id)
end

function Editor.BuildAPLsPage(parent, yOffset)
    local W = EllesmereUI.Widgets
    local y = yOffset
    local _, h
    local specID = Kit.SpecID()
    local selected = Kit.Def()

    _, h = W:SectionHeader(parent, "APLS FOR " .. Kit.SpecLabel(specID):upper(), y); y = y - h
    local list = Store.ListForSpec(specID)
    if #list == 0 then
        y = Kit.Note(parent, y, "No APLs for this spec yet. Use New Empty APL below.")
    end
    for _, def in ipairs(list) do
        y = Kit.Header(parent, y, {
            title = def.name .. (def.builtin and "  |cff909090(built-in)|r" or ""),
            open = def == selected,
            tooltip = "Edit this APL on the Lists and Building Blocks tabs.",
            onClick = function() Kit.SelectAPL(def.id) end,
            noDim = true,
            getOn = function() return Store.ActiveID(specID) == def.id end,
            setOn = function(v)
                if v then Store.SetActive(specID, def.id) end
                Kit.RebuildAll()
            end,
            onTip = "Run this APL for " .. Kit.SpecLabel(specID) .. ".",
        })
    end

    if selected then
        _, h = W:SectionHeader(parent, "SELECTED APL", y); y = y - h
        _, h = W:DualRow(parent, y,
            { type = "button", text = "Duplicate", onClick = function()
                local copy = Store.Duplicate(selected)
                Kit.SelectAPL(copy.id)
            end },
            { type = "button", text = "Rename",
              disabled = ReadOnly, disabledTooltip = Kit.READ_ONLY_TIP,
              onClick = function()
                EllesmereUI:ShowInputPopup({
                    title = "Rename APL", message = "Enter a new name for this APL:",
                    placeholder = selected.name, confirmText = "Rename", cancelText = "Cancel",
                    onConfirm = function(text)
                        if Store.Rename(selected, text) then Kit.RebuildAll() end
                    end,
                })
              end })
        y = y - h
        _, h = W:DualRow(parent, y,
            { type = "button", text = "Delete",
              disabled = ReadOnly, disabledTooltip = Kit.READ_ONLY_TIP,
              onClick = function()
                Kit.Confirm("Delete the APL \"" .. selected.name .. "\"? This can't be undone.", function()
                    Store.Delete(selected)
                    Kit.SelectAPL(nil)
                end)
              end },
            { type = "button", text = "New Empty APL", onClick = function()
                local def = Store.New(specID)
                Kit.SelectAPL(def.id)
            end })
        y = y - h

        _, h = W:SectionHeader(parent, "OPTIONS", y); y = y - h
        _, h = W:DualRow(parent, y,
            { type = "toggle", text = "Never Suggest the Last Cast",
              tooltip = "Skip any entry whose spell was the last cast (Windwalker's Combo Strikes).",
              disabled = ReadOnly, disabledTooltip = Kit.READ_ONLY_TIP,
              getValue = function() return selected.options and selected.options.noRepeatLastCast == true end,
              setValue = function(v)
                  selected.options = selected.options or {}
                  selected.options.noRepeatLastCast = v or nil
                  Store.Changed(selected)
              end },
            { type = "input", text = "Range Spell", inputWidth = 170, inputStyle = "popup",
              placeholder = "Spell name or ID",
              tooltip = "Enemies count as targets while this spell is in range of them (a melee spell for melee specs).",
              disabled = ReadOnly, disabledTooltip = Kit.READ_ONLY_TIP,
              getValue = function() return RangeSpellText(selected) end,
              setValue = function(text)
                  local id, name = Store.LookupSpell(text)
                  if not id then
                      if text:match("%S") then print("APL for EUI: no spell found for \"" .. text .. "\".") end
                      return
                  end
                  selected.options = selected.options or {}
                  selected.options.rangeSpell = Store.EnsureName(selected, id, name)
                  Store.Changed(selected)
              end })
        y = y - h
    end
    return math.abs(y)
end
