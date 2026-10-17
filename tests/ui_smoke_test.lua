-- Editor UI smoke test: runs every editor page and the header against a
-- mock EllesmereUI that records each row, dropdown and button, then drives
-- them like a user (duplicate, add, rename, builder edits) and checks the
-- results still compile. Catches Lua errors and broken wiring; it can't
-- judge layout, which still needs a look in game.
-- usage: lua tests/ui_smoke_test.lua <addonDir>
local dir = arg[1]

-- Mock EllesmereUI (must exist before the addon loads, for RegisterPlugin).
local rec = { rows = {}, dropdowns = {}, buttons = {}, toggles = {}, refreshes = 0 }
local plugin
local function Stub(parent) return CreateFrame("Frame", nil, parent) end
EllesmereUI = {
    CONTENT_PAD = 20, EXPRESSWAY = "font", TEXT_DIM_A = 0.5, DD_ITEM_HL_A = 0.1,
    ELLESMERE_GREEN = { r = 0, g = 1, b = 0 },
    Widgets = {},
    RegisterPlugin = function(id, spec) plugin = spec; return true end,
    GetPluginModuleKey = function(id, key) return "plugin:" .. id .. ":" .. key end,
    IsSearchPrebuild = function() return false end,
    MakeFont = function(parent) return Stub(parent) end,
    SolidTex = function(parent) return Stub(parent) end,
    MakeBorder = function(parent) return Stub(parent) end,
    SetDeleteIcon = function() end,
    ShowWidgetTooltip = function() end,
    HideWidgetTooltip = function() end,
}
function EllesmereUI:RefreshPage() rec.refreshes = rec.refreshes + 1 end
-- Like the real panel: buildPage must draw its own header through this;
-- getHeaderBuilder alone draws nothing.
function EllesmereUI:SetContentHeader(fn)
    rec.headerDrawn = true
    local h = fn(CreateFrame("Frame"), 800)
    assert(type(h) == "number" and h > 0, "header builder must return a height")
end
function EllesmereUI:InvalidateModulePageCache() end
function EllesmereUI:ShowConfirmPopup(opts) opts.onConfirm() end
function EllesmereUI:ShowInputPopup(opts) opts.onConfirm(rec.inputReply) end
function EllesmereUI.BuildDropdownControl(parent, w, level, values, order, get, set)
    local dd = Stub(parent)
    -- The current value must be one the dropdown can show.
    local cur = get()
    if cur ~= nil and values[cur] == nil then
        error("dropdown value '" .. tostring(cur) .. "' is not among its options", 2)
    end
    rec.dropdowns[#rec.dropdowns + 1] = { values = values, order = order, get = get, set = set, frame = dd }
    return dd, Stub(dd)
end
function EllesmereUI.BuildToggleControl(parent, level, get, set)
    local tg = Stub(parent)
    rec.toggles[#rec.toggles + 1] = { get = get, set = set }
    return tg, function() end, function() end
end
function EllesmereUI.BuildPopupShell(name, opts)
    local dimmer = Stub()
    return dimmer, Stub(dimmer)
end
function EllesmereUI.AttachSmoothScrollbar() return function() end end
function EllesmereUI.BuildPopupButton(parent, w, h, label, onClick)
    local b = Stub(parent)
    rec.buttons[#rec.buttons + 1] = { label = label, onClick = onClick, frame = b }
    return b
end
function EllesmereUI.Widgets:SectionHeader(parent) return Stub(parent), 30 end
function EllesmereUI.Widgets:DualRow(parent, y, l, r)
    local row = Stub(parent)
    for _, cfg in ipairs({ l or false, r or false }) do
        if cfg then
            rec.rows[#rec.rows + 1] = cfg
            if cfg.type == "dropdown" then
                local cur = cfg.getValue and cfg.getValue()
                if cur ~= nil and cfg.values[cur] == nil then error("row dropdown '" .. tostring(cfg.text) .. "' value not in options", 2) end
            end
            if cfg.getValue and cfg.type ~= "dropdown" then cfg.getValue() end
            if cfg.disabled then cfg.disabled() end
        end
    end
    return row, 50
end

local S, ns = dofile(dir .. "/tests/mock_wow.lua")(dir)
local Store, Engine, Kit = ns.Store, ns.Engine, ns.EditorKit

local fails = 0
local function Check(ok, msg)
    if not ok then fails = fails + 1; print_real("FAIL: " .. msg) end
end

assert(plugin, "plugin not registered")
local mod = plugin.modules[1]
Check(mod.key == "APL" and mod.pages[3] == "Building Blocks", "APL module with three tabs")
Check(plugin.modules[2].title == "Glows" and plugin.modules[3].title == "Widgets", "Glows between APL and Widgets")

local parent = Stub()
local function Reset() rec.rows, rec.dropdowns, rec.buttons, rec.toggles = {}, {}, {}, {} end
local function Build(page)
    Reset()
    rec.headerDrawn = false
    local ok, h = pcall(mod.buildPage, page, parent, -10)
    if not ok then Check(false, page .. " page errored: " .. tostring(h)) return 0 end
    Check(type(h) == "number" and h > 0, page .. " page returns a height")
    Check(rec.headerDrawn, page .. " page draws the header")
    Check(type(mod.getHeaderBuilder(page)) == "function", page .. " page reports a header to the cache")
    return h
end
local function Row(text)
    for _, cfg in ipairs(rec.rows) do if cfg.text == text then return cfg end end
end
local function Button(label)
    for _, b in ipairs(rec.buttons) do if b.label == label then return b end end
end

-- 1. Built-in selected: everything builds, read-only.
for _, page in ipairs(mod.pages) do Build(page) end
Check(not Kit.Editable(), "built-in starts read-only")
Build("Lists")
local dup = Row("Duplicate to Edit")
Check(dup ~= nil, "Duplicate to Edit button on Lists")
Check(Row("Add Group").disabled() == true, "Add Group disabled on the built-in")

-- 2. Duplicate, then open every row so all editors build.
dup.onClick()
local def = Kit.Def()
Check(Kit.Editable() and def.id:find("^user:"), "duplicate selected and editable")
Check(def.groups[1].name == "Opener" and def.groups[2].name == "Default", "copy has the Opener and Default groups")
-- The checks below edit the Default group as the first one.
table.remove(def.groups, 1)
Store.Changed(def)
local function OpenAll()
    for _, g in ipairs(def.groups) do Kit.state.open[g] = true end
    for _, l in ipairs(def.groups[1].lists) do
        Kit.state.open[l] = true
        for _, e in ipairs(l.entries) do Kit.state.open[e] = true end
    end
    for _, key in ipairs({ "variables", "timers", "counters" }) do
        for _, item in ipairs(def[key]) do
            Kit.state.open[item] = true
            for _, t in ipairs(item.triggers or {}) do Kit.state.open[t] = true end
        end
    end
end
OpenAll()
for _, page in ipairs(mod.pages) do Build(page) end

-- 3. Lists tab inputs.
Build("Lists")
local nFree = #def.freeCasts
Check(nFree == 7 and Row("Add Free Cast") == nil, "free casts (monk defaults) collapsed by default")
Kit.state.open[ns.Editor.FREE_CASTS_KEY] = true
Build("Lists")
Check(Row("Add Free Cast") ~= nil, "free casts expand when opened")
Row("Add Free Cast").setValue("100780")
Check(#def.freeCasts == nFree + 1, "free cast added from the page")
Row("Add Free Cast").setValue("100780")
Check(#def.freeCasts == nFree + 1, "duplicate free cast refused")
table.remove(def.freeCasts)
Store.Changed(def)
Kit.state.open[ns.Editor.FREE_CASTS_KEY] = nil
Build("Lists")
local function ListPrefix()
    for _, cfg in ipairs(rec.rows) do
        if cfg.text == "Prefix" and cfg.tooltip and cfg.tooltip:find("entry's position", 1, true) then return cfg end
    end
end
ListPrefix().setValue("ABCD")
Check(def.groups[1].lists[1].prefix == "ST", "4-character prefix rejected")
ListPrefix().setValue("S")
Check(def.groups[1].lists[1].prefix == "S", "prefix changed")
Build("Lists")
Row("Max Targets").setValue("3")
Check(def.groups[1].lists[1].max == 1, "overlapping range rejected")
Row("Add Entry").setValue("Fists of Fury")
local st = def.groups[1].lists[1].entries
Check(st[#st].spell == "fists_of_fury" and st[#st].when == "", "Add Entry by spell name")
Row("Add Entry").setValue("No Such Spell")
Check(st[#st].spell == "fists_of_fury", "unknown spell not added")

-- 4. Builder: on a fresh entry, add a row and drive every category.
local entry = st[#st]
wipe(Kit.state.open)
Kit.state.open[def.groups[1]] = true
Kit.state.open[def.groups[1].lists[1]] = true
Kit.state.open[entry] = true
Kit.SetConditionMode("builder")
Build("Lists")
local addCond
for i = #rec.buttons, 1, -1 do if rec.buttons[i].label == "+ Condition" then addCond = rec.buttons[i]; break end end
Check(addCond ~= nil, "builder shows + Condition")
addCond.onClick()
Check(entry.when == "buff.blackout_kick.up", "new builder row is a complete condition: " .. tostring(entry.when))
Build("Lists")
-- Find this entry's category dropdown: the one offering "Buff active" whose
-- current value is "buff" (the row we just added).
local cats = {}
for _, dd in ipairs(rec.dropdowns) do
    if dd.values.buff == "Buff active" then cats[#cats + 1] = dd end
end
local cat = cats[#cats]
Check(cat ~= nil, "category dropdown present")
for _, key in ipairs(cat.order) do
    cat.set(key)
    local ok, err = Engine.CheckExpr(def, entry.when)
    Check(ok, "category " .. key .. " -> '" .. tostring(entry.when) .. "' compiles: " .. tostring(err))
end
-- Group modes and a nested group.
cat.set("targets")
Build("Lists")
local addGroup
for i = #rec.buttons, 1, -1 do if rec.buttons[i].label == "+ Group" then addGroup = rec.buttons[i]; break end end
addGroup.onClick()
Check(entry.when:find("|", 1, true) == nil and entry.when:find("&", 1, true) ~= nil, "nested group joins with &: " .. entry.when)
Build("Lists")
local modes = {}
for _, dd in ipairs(rec.dropdowns) do if dd.values.nor == "None of these" then modes[#modes + 1] = dd end end
for _, m in ipairs(modes) do
    for _, key in ipairs(m.order) do
        m.set(key)
        local ok, err = Engine.CheckExpr(def, entry.when)
        Check(ok, "group mode " .. key .. " compiles: " .. tostring(err) .. " [" .. entry.when .. "]")
    end
end
Check(Engine.CheckExpr(def, entry.when), "builder result compiles")

-- Switch the whole editor to text and back with everything open (covers
-- text-only conditions such as zenith_almost_over in builder view too).
OpenAll()
Kit.SetConditionMode("text")
Check(ns.DB().conditionMode == "text", "mode saved per account")
for _, page in ipairs(mod.pages) do Build(page) end
Kit.SetConditionMode("builder")
Check(ns.DB().conditionMode == nil, "builder is the default")
for _, page in ipairs(mod.pages) do Build(page) end
Reset()
mod.getHeaderBuilder("Lists")(Stub(), 800)
local modeDDs = 0
for _, dd in ipairs(rec.dropdowns) do if dd.values.builder == "Builder" then modeDDs = modeDDs + 1 end end
Check(modeDDs == 1, "one Builder/Text switch, in the header")
Build("Lists")
for _, cfg in ipairs(rec.rows) do
    Check(not (cfg.type == "dropdown" and cfg.values and cfg.values.builder), "no per-condition Builder/Text row")
end

-- 4a. "Only When Usable" is on by default and can be switched off.
wipe(Kit.state.open)
Kit.state.open[def.groups[1]] = true
Kit.state.open[def.groups[1].lists[1]] = true
Kit.state.open[entry] = true
Build("Lists")
local usableRow = Row("Only When Usable")
Check(usableRow and usableRow.getValue() == true, "new entries default to only when usable")
usableRow.setValue(false)
Check(entry.usable == false, "usable check switched off for the entry")
usableRow.setValue(true)
Check(entry.usable == nil, "switched back on (stored as the default)")
-- The entry's on/off toggle is the last header toggle (it's the last entry).
local onOff = rec.toggles[#rec.toggles]
Check(onOff.get() == true, "entry starts switched on")
onOff.set(false)
Check(entry.enabled == false, "entry switched off from its header toggle")
onOff.set(true)
Check(entry.enabled == nil, "entry switched back on")

-- 4a2. Hold After Ignored Casts.
Build("Lists")
local holdRow = Row("Hold After Ignored Casts")
Check(holdRow and holdRow.getValue() == "", "hold empty by default")
holdRow.setValue("0")
Check(entry.hold == nil, "hold 0 rejected")
holdRow.setValue("2")
Check(entry.hold == nil, "hold below 3 rejected")
holdRow.setValue("2.5")
Check(entry.hold == nil, "fractional hold rejected")
holdRow.setValue("3")
Check(entry.hold == 3, "hold set")
Check(Engine.CheckExpr(def, "holding&!holding.fists_of_fury"), "holding reads compile")
holdRow.setValue("")
Check(entry.hold == nil, "hold cleared")

-- 4b. Groups: add one, give it the opener preset, add a list to it.
wipe(Kit.state.open)
Build("Lists")
Row("Add Group").onClick()
local burst = def.groups[1]
Check(#def.groups == 2 and burst.name == "Group 2" and #burst.lists == 1, "Add Group puts a new group on top with an ST list")
Check(burst.lists[1].prefix ~= def.groups[2].lists[1].prefix, "new group's list gets its own prefix: " .. burst.lists[1].prefix)
Build("Lists")
Row("Use Opener Preset").onClick()
Check(burst.when == Store.OPENER_PRESET, "opener preset fills the condition")
Check(Engine.CheckExpr(def, burst.when), "opener preset compiles")
Build("Lists")
Row("Group Name").setValue("Opener")
Check(burst.name == "Opener", "group renamed")
Build("Lists")
local gp
for _, cfg in ipairs(rec.rows) do
    if cfg.text == "Prefix" and cfg.tooltip and cfg.tooltip:find("group prefix", 1, true) then gp = cfg end
end
Check(burst.prefix == "G2", "new group starts with a G prefix: " .. tostring(burst.prefix))
gp.setValue("OPEN")
Check(burst.prefix == "G2", "4-character group prefix rejected")
gp.setValue("")
Check(burst.prefix == "G2", "empty group prefix rejected (required)")
gp.setValue("OP")
Check(burst.prefix == "OP", "group prefix set")
Build("Lists")
Row("Add List").onClick()
Check(#burst.lists == 2 and burst.lists[2].min == 2, "Add List in the group takes its next free count")
Check(#Engine.GetRuntime(def).errors == 0, "APL with two groups compiles: " .. tostring(Engine.GetRuntime(def).errors[1]))
-- Builder on the group condition: the opener preset fits the builder.
Kit.SetConditionMode("builder")
Build("Lists")
local castsRow = false
for _, dd in ipairs(rec.dropdowns) do
    if dd.values.combat_casts and dd.get() == "combat_casts" then castsRow = true end
end
Check(castsRow, "builder shows the opener preset as a Casts this combat row")
-- Can't delete the last group.
local saved = def.groups
def.groups = { saved[2] }
Build("Lists")
def.groups = saved

-- 5. Building Blocks: rename, counter limits, add blocks and triggers.
OpenAll()
Build("Building Blocks")
local nameRows = {}
for _, cfg in ipairs(rec.rows) do if cfg.text == "Name" then nameRows[#nameRows + 1] = cfg end end
Check(#nameRows > 0, "name inputs present")
local xuen
for _, t in ipairs(def.timers) do if t.name == "xuen" then xuen = t end end
-- Rename through the timer's own Name row (getValue identifies it).
for _, cfg in ipairs(nameRows) do if cfg.getValue() == "xuen" then cfg.setValue("xuen_cd") end end
Check(xuen.name == "xuen_cd", "timer renamed from its row")
Check(#Engine.GetRuntime(def).errors == 0, "rename kept the APL compiling: " .. tostring(Engine.GetRuntime(def).errors[1]))
Build("Building Blocks")
local limits = Row("Start / Min / Max")
limits.setValue("3 / 0 / 4")
local stomp = def.counters[1]
Check(stomp.initial == 3 and stomp.min == 0 and stomp.max == 4, "counter limits parsed")
limits.setValue("1 / 0 /")
Check(stomp.max == nil, "empty max means no limit")
limits.setValue("garbage")
Check(stomp.initial == 1, "bad counter input rejected")
Row("Add Timer").onClick()
local newTimer = def.timers[#def.timers]
wipe(Kit.state.open)
Kit.state.open[newTimer] = true
Build("Building Blocks")
local addTrig
for _, cfg in ipairs(rec.rows) do if cfg.text == "Add Trigger" then addTrig = cfg end end
addTrig.onClick()
Check(#newTimer.triggers == 1, "trigger added")
Build("Building Blocks")
Row("Add Spell").setValue("Zenith")
Row("Add Variable").onClick()
Build("Building Blocks")

-- 6. APLs tab: rename, new, delete.
Build("APLs")
rec.inputReply = "My WW"
Row("Rename").onClick()
Check(def.name == "My WW", "rename via popup")
Build("APLs")
Row("New Empty APL").onClick()
local blank = Kit.Def()
Check(blank ~= def and #blank.groups[1].lists == 2, "new empty APL selected")
for _, page in ipairs(mod.pages) do Build(page) end
Build("APLs")
Row("Delete").onClick()
Check(Store.Get(blank.id) == nil, "delete removes it")
for _, page in ipairs(mod.pages) do Build(page) end

-- Running toggle on the APLs tab.
Kit.SelectAPL(def.id)
Build("APLs")
for _, t in ipairs(rec.toggles) do t.get() end
rec.toggles[#rec.toggles].set(true)
Check(Store.ActiveID(269) == def.id, "running toggle activates the APL")
Check(ns.GetActiveAPL() == Engine.GetRuntime(def), "active runtime is the edited APL")

-- 7. Export and import through the popup.
C_Timer.After = function(_, fn) fn() end
local captured
local realPopup = Kit.TextPopup
Kit.TextPopup = function(o) captured = realPopup(o); return captured end
Kit.SelectAPL(def.id)
Build("APLs")
Row("Export").onClick()
Check(captured and ns.EditorKit.GetEditText(captured.edit) == ns.Exchange.Export(def), "export popup shows the export text")
Check(captured.readOnly, "export popup is read-only")
Check(captured.edit:GetText() == ns.Exchange.Export(def):gsub("|", "||"), "export box holds escaped pipes")
local exported = ns.EditorKit.GetEditText(captured.edit)
Row("Import").onClick()
Check(captured.edit:GetText() == "" and not captured.readOnly, "import popup starts empty")
captured.edit:SetText("not an apl")
local ok, err = captured.onConfirm(ns.EditorKit.GetEditText(captured.edit))
Check(not ok and err and err:find("line 1", 1, true), "bad import reports the line: " .. tostring(err))
local before = #Store.ListForSpec(269)
-- What WoW gives back after Ctrl+V: every "|" doubled.
captured.edit:SetText(exported)
local before2 = #Store.ListForSpec(269)
local importBtn
for i = #rec.buttons, 1, -1 do if rec.buttons[i].label == "Import" then importBtn = rec.buttons[i]; break end end
importBtn.onClick()
Check(#Store.ListForSpec(269) == before2 + 1, "Import button imports the pasted text")
Check(#Engine.GetRuntime(Kit.Def()).errors == #Engine.GetRuntime(def).errors, "pasted import has no new problems: " .. tostring(Engine.GetRuntime(Kit.Def()).errors[1]))
ok = captured.onConfirm(exported:gsub("|", "||"))
Check(ok, "good import accepted")
Check(#Store.ListForSpec(269) == before + 2, "import added a new APL")
local imported = Kit.Def()
Check(imported ~= def and imported.name ~= def.name and imported.id:find("^user:"), "editor switched to the imported copy: " .. imported.name)
Check(ns.Exchange.Export(imported):gsub("apl=[^\n]*", "") == exported:gsub("apl=[^\n]*", ""), "imported copy matches the export")
for _, page in ipairs(mod.pages) do Build(page) end
Kit.TextPopup = realPopup

print_real(string.format("%d page rebuild requests", rec.refreshes))
print_real(fails == 0 and "ALL PASS" or (fails .. " failures"))
