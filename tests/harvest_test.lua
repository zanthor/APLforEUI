-- Data harvesting (Harvest.lua + EditorHarvest.lua): what gets collected
-- from the CDM, spellbook, talents, casts and buffs; what is left out; cause
-- matching; secrecy; export; adding to an APL from the Discovered section.
-- usage: lua tests/harvest_test.lua <addonDir>
local dir = arg[1]

local rows = {}
EllesmereUI = {
    Widgets = {}, CONTENT_PAD = 20, ELLESMERE_GREEN = { r = 0, g = 1, b = 0 }, TEXT_DIM_A = 0.5,
    RegisterPlugin = function() return true end,
    MakeFont = function(p) return CreateFrame("Frame", nil, p) end,
    SolidTex = function(p) return CreateFrame("Frame", nil, p) end,
    BuildToggleControl = function(p) local f = CreateFrame("Frame", nil, p); return f, function() end, function() end end,
    SetDeleteIcon = function() end, ShowWidgetTooltip = function() end, HideWidgetTooltip = function() end,
}
function EllesmereUI:RefreshPage() end
function EllesmereUI.Widgets:SectionHeader(p) return CreateFrame("Frame", nil, p), 30 end
function EllesmereUI.Widgets:DualRow(p, _, l, r)
    for _, cfg in ipairs({ l or false, r or false }) do if cfg then rows[#rows + 1] = cfg end end
    return CreateFrame("Frame", nil, p), 50
end

local S, ns = dofile(dir .. "/tests/mock_wow.lua")(dir)
local Harvest, Store, Engine, Editor, Kit = ns.Harvest, ns.Store, ns.Engine, ns.Editor, ns.EditorKit

local fails = 0
local function Check(ok, msg)
    if not ok then fails = fails + 1; print_real("FAIL: " .. msg) end
end

-- Game data mocks ------------------------------------------------------------
local BW, KC, BS, HM, AIMED, MOUNT = 19574, 34026, 217200, 257284, 19434, 999001
local BW_BUFF, FRENZY, OTHER_BUFF = 186254, 272790, 1126
local names = { [BW] = "Bestial Wrath", [KC] = "Kill Command", [BS] = "Barbed Shot", [HM] = "Hunter's Mark",
    [AIMED] = "Aimed Shot", [BW_BUFF] = "Bestial Wrath", [FRENZY] = "Frenzy", [OTHER_BUFF] = "Mark of the Wild",
    [111] = "Talent One", [222] = "Hero Talent", [333] = "Other Hero", [444] = "Unpicked" }
for id, n in pairs(names) do S.spellNames[id] = n end

Enum.CooldownViewerCategory = { Essential = 0, Utility = 1, TrackedBuff = 2, TrackedBar = 3 }
Enum.SpellBookSpellBank = { Player = 0 }
Enum.SpellBookItemType = { Spell = 1, Flyout = 4 }
local cdmSets = { [0] = { 1, 2 }, [1] = {}, [2] = { 3 }, [3] = {} }
local cdmInfo = {
    [1] = { spellID = BW, linkedSpellIDs = { BW_BUFF }, isKnown = true },
    [2] = { spellID = KC, linkedSpellIDs = {}, isKnown = true },
    [3] = { spellID = FRENZY, linkedSpellIDs = {}, isKnown = true },
}
C_CooldownViewer = {
    GetCooldownViewerCategorySet = function(c) return cdmSets[c] end,
    GetCooldownViewerCooldownInfo = function(id) return cdmInfo[id] end,
}
UnitClass = function() return "Hunter", "HUNTER" end
local lines = {
    { name = "General", itemIndexOffset = 0, numSpellBookItems = 1 },
    { name = "Hunter", itemIndexOffset = 1, numSpellBookItems = 1 },
    { name = "Beast Mastery", itemIndexOffset = 2, numSpellBookItems = 2, specID = 269 },
    { name = "Marksmanship", itemIndexOffset = 4, numSpellBookItems = 1, offSpecID = 254 },
}
local items = {
    { actionID = MOUNT, itemType = 1 },
    { actionID = HM, itemType = 1 },
    { actionID = BS, itemType = 1 },
    { actionID = 555, itemType = 1, isPassive = true },
    { actionID = AIMED, itemType = 1, isOffSpec = true },
}
C_SpellBook.GetNumSpellBookSkillLines = function() return #lines end
C_SpellBook.GetSpellBookSkillLineInfo = function(i) return lines[i] end
C_SpellBook.GetSpellBookItemInfo = function(i) return items[i] end
C_ClassTalents = { GetActiveConfigID = function() return 7 end }
local nodes = {
    [1] = { activeRank = 1, activeEntry = { entryID = 11 } },
    [2] = { activeRank = 0, activeEntry = { entryID = 12 } },
    [3] = { activeRank = 1, activeEntry = { entryID = 13 }, subTreeID = 50 },
    [4] = { activeRank = 1, activeEntry = { entryID = 14 }, subTreeID = 51 },
}
local entrySpell = { [11] = 111, [12] = 444, [13] = 222, [14] = 333 }
C_Traits = {
    GetConfigInfo = function() return { treeIDs = { 900 } } end,
    GetTreeNodes = function() return { 1, 2, 3, 4 } end,
    GetNodeInfo = function(_, id) return nodes[id] end,
    GetSubTreeInfo = function(_, id) return { isActive = id == 50 } end,
    GetEntryInfo = function(_, id) return { definitionID = id } end,
    GetDefinitionInfo = function(id) return { spellID = entrySpell[id] } end,
}
local KC_CHARGES = { maxCharges = 2, cooldownDuration = 7.5, isActive = false }
local realCharges = C_Spell.GetSpellCharges
C_Spell.GetSpellCharges = function(id) if id == KC then return KC_CHARGES end return realCharges(id) end
local auras = { player = {}, pet = {} }
C_UnitAuras.GetAuraDataByIndex = function(unit, i) return auras[unit][i] end
local aurasSecret = false
C_Secrets = { ShouldAurasBeSecret = function() return aurasSecret end }
time = function() return 12345 end

-- 1. Static scans --------------------------------------------------------------
local spec = 269
Harvest.Clear(spec)
Harvest.ScanStatic(spec)
local cat = Harvest.Catalog(spec)
Check(cat.spells[BW] and cat.spells[BW].sources.cdm == "essential", "CDM ability harvested")
Check(cat.spells[KC].charges == 2 and cat.spells[KC].recharge == 7.5, "charges and recharge read")
Check(cat.auras[BW_BUFF] and cat.auras[BW_BUFF].cdm, "buff linked to a CDM cooldown harvested")
Check(cat.auras[FRENZY] and cat.auras[FRENZY].cdm, "CDM tracked buff harvested")
Check(cat.spells[HM] and cat.spells[HM].sources.spellbook, "class line spell harvested")
Check(cat.spells[BS] and cat.spells[BS].sources.spellbook, "spec line spell harvested")
Check(cat.spells[555] and cat.spells[555].passive, "passive marked")
Check(cat.spells[MOUNT] == nil, "General line skipped")
Check(cat.spells[AIMED] == nil, "other spec skipped")
Check(cat.spells[111] and cat.spells[111].sources.talent, "active talent harvested")
Check(cat.spells[444] == nil, "unpicked talent skipped")
Check(cat.spells[222] and cat.spells[222].sources.talent, "active hero tree talent harvested")
Check(cat.spells[333] == nil, "inactive hero tree skipped")

-- 2. Casts and buff causes ------------------------------------------------------
Harvest.OnCast(spec, KC, 99.0)
Harvest.OnCast(spec, BW, 100.0)
-- In combat the buff can't be read; after combat drops it can, and its
-- application time (expiration - duration = 100.1) matches the BW cast.
auras.player = {
    { spellId = BW_BUFF, name = "Bestial Wrath", duration = 15, expirationTime = 115.1, applications = 0, isFromPlayerOrPlayerPet = true },
    { spellId = OTHER_BUFF, name = "Mark of the Wild", duration = 3600, expirationTime = 4000, isFromPlayerOrPlayerPet = false },
}
auras.pet = {
    { spellId = FRENZY, name = "Frenzy", duration = 8, expirationTime = 107.9, applications = 3, isFromPlayerOrPlayerPet = true },
}
Harvest.OnCast(spec, BS, 99.9)  -- pet Frenzy: applied at 99.9
Harvest.OnCast(spec, 75, 100.1) -- Auto Shot right at the BW buff's application time
aurasSecret = true
Harvest.ScanAuras(spec, 104)
Check(cat.auras[BW_BUFF].duration == nil, "nothing read while auras are secret")
aurasSecret = false
Harvest.ScanAuras(spec, 105)
local bwb = cat.auras[BW_BUFF]
Check(bwb.duration == 15 and Harvest.MainCause(bwb) == BW, "buff duration and cause (applied in combat, read after)")
Check(cat.auras[OTHER_BUFF] == nil, "other players' buffs skipped")
local fr = cat.auras[FRENZY]
Check(fr.unit == "pet" and fr.stacks == 3 and Harvest.MainCause(fr) == BS, "pet buff, stacks and cause")
Check(cat.spells[BW].casts == 1, "cast counted")

local c = Harvest.Counts(spec)
Check(c.cdm == 2 and c.auras == 2 and c.timed == 2, "counts: " .. c.cdm .. "/" .. c.auras .. "/" .. c.timed)
local text = Harvest.Export(spec)
Check(text:find("spell.34026=Kill Command | cdm=essential", 1, true) and text:find("charges=2", 1, true), "export: CDM ability with charges")
Check(text:find("aura.186254=Bestial Wrath | cdm unit=player duration=15.0 from=19574 Bestial Wrath x1", 1, true) ~= nil, "export: buff line\n" .. text)

-- 3. Switch: zero cost while off, scans on enable --------------------------------
local hframe
for _, f in ipairs(S.frames) do if f._events == nil and f:GetScript("OnEvent") then hframe = hframe or f end end
Harvest.SetEnabled(false)
Check(ns.DB().harvesting == nil, "off by default")
Harvest.Clear(spec)
Harvest.SetEnabled(true)
Check(ns.DB().harvesting == true and Harvest.Catalog(spec).spells[BW] ~= nil, "enabling scans right away")
Harvest.SetEnabled(false)

-- 4. Adding to an APL -----------------------------------------------------------
cat = Harvest.Catalog(spec)
Harvest.OnCast(spec, BW, 200)
Harvest.OnCast(spec, BS, 199.9)
auras.player[1].expirationTime = 215.1
auras.pet[1].expirationTime = 207.9
Harvest.ScanAuras(spec, 205)
local def = Store.New(spec)
Kit.state.specID, Kit.state.aplID = spec, def.id
local timer = Store.AddTimerForAura(def, BW_BUFF, "Bestial Wrath", BW, "Bestial Wrath", 15)
Check(def.names.bestial_wrath == BW and def.names.bestial_wrath_buff == BW_BUFF,
    "buff sharing its spell's name gets _buff: " .. tostring(Store.NameOf(def, BW_BUFF)))
Check(timer and timer.name == "bestial_wrath_buff", "timer named after the buff: " .. tostring(timer and timer.name))
Check(timer and #timer.triggers == 1 and timer.triggers[1].action == "set" and timer.triggers[1].value == "15", "buff timer created")
Check(Store.AddTimerForAura(def, BW_BUFF, "Bestial Wrath", BW, "Bestial Wrath", 15) == nil, "same timer not added twice")
Check(#Engine.GetRuntime(def).errors == 0, "APL with the timer compiles: " .. tostring(Engine.GetRuntime(def).errors[1]))

-- Discovered section: categories start closed; open them all and use the buttons.
local function Build()
    rows = {}
    return Editor.BuildDiscovered(CreateFrame("Frame"), -10, def, true)
end
local function Buttons()
    local out = {}
    for _, r in ipairs(rows) do if r.type == "button" then out[#out + 1] = r end end
    return out
end
Check(type(Build()) == "number" and #Buttons() == 0, "categories start closed")
for _, cat in ipairs(Editor.DISCOVERED_CATEGORIES) do Kit.state.open[cat] = true end
Build()
local addAll, bwRow, frenzyRow, hmRow
for _, r in ipairs(Buttons()) do
    if r.text == "Add All" then addAll = addAll or r end
end
for i, r in ipairs(rows) do
    if r.type == "label" and r.text:find("^Frenzy") then frenzyRow = rows[i + 1] end
    if r.type == "label" and r.text:find("^Hunter's Mark") then hmRow = rows[i + 1] end
    if r.type == "label" and r.text:find("^Bestial Wrath  |cff909090186254", 1, false) then bwRow = rows[i + 1] end
end
Check(frenzyRow and frenzyRow.text == "Add as Timer", "buff with cause and duration offers Add as Timer: " .. tostring(frenzyRow and frenzyRow.text))
Check(hmRow and hmRow.text == "Add" and hmRow.disabled() == false, "plain spell offers Add")
hmRow.onClick()
Check(Store.NameOf(def, HM) == "hunter_s_mark", "Add creates the short name: " .. tostring(Store.NameOf(def, HM)))
frenzyRow.onClick()
local frenzyTimer
for _, t in ipairs(def.timers) do if t.name == "frenzy" then frenzyTimer = t end end
Check(frenzyTimer and frenzyTimer.triggers[1].spell == "barbed_shot" and frenzyTimer.triggers[1].value == "8",
    "Add as Timer: frenzy set 8 on barbed_shot")
Build()
for i, r in ipairs(rows) do
    if r.type == "label" and r.text:find("^Hunter's Mark") then hmRow = rows[i + 1] end
end
Check(hmRow.text == "Added: hunter_s_mark" and hmRow.disabled() == true, "added entries show their short name, locked")
-- Add All everywhere.
for _, r in ipairs(Buttons()) do if r.text == "Add All" and not r.disabled() then r.onClick() end end
Build()
for _, r in ipairs(Buttons()) do
    if r.text == "Add All" then Check(r.disabled() == true, "Add All locks once everything is added") end
end
Check(#Engine.GetRuntime(def).errors == 0, "APL after Add All compiles: " .. tostring(Engine.GetRuntime(def).errors[1]))
-- Read-only (built-in): buttons locked.
rows = {}
Editor.BuildDiscovered(CreateFrame("Frame"), -10, def, false)
for _, r in ipairs(Buttons()) do Check(r.disabled() == true, "read-only APL: " .. r.text .. " locked") end

-- 5. APLs tab section builds; Clear empties the catalog.
rows = {}
Check(type(Editor.BuildHarvestSection(CreateFrame("Frame"), -10)) == "number", "harvest section builds")
local toggle
for _, r in ipairs(rows) do if r.text == "Harvest Data" then toggle = r end end
toggle.setValue(true)
Check(Harvest.Enabled(), "toggle turns harvesting on")
toggle.setValue(false)
Check(not Harvest.Enabled(), "and off")
Harvest.Clear(spec)
Check(Harvest.Counts(spec).spells == 0, "clear empties the catalog")

print_real(fails == 0 and "ALL PASS" or (fails .. " failures"))
