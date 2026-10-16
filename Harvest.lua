local _, ns = ...

-------------------------------------------------------------------------------
--  Data harvesting: while switched on (APLs tab), collects what the game will
--  tell us about the current spec into a per-spec catalog
--  (APLforEUIDB.harvest[specID]) that the Building Blocks tab offers to add
--  from, and that exports as text for building default APLs.
--
--  Sources, and when they can be read:
--    Cooldown Manager  C_CooldownViewer category sets (abilities and the
--                      buffs Blizzard offers to track) -- any time.
--    Spellbook         class + current-spec skill lines -- any time.
--    Talents           active config, incl. the active hero tree -- any time.
--    Casts             UNIT_SPELLCAST_SUCCEEDED spell IDs -- any time
--                      (readable in restricted combat).
--    Buffs             C_UnitAuras on player/pet -- only while auras are not
--                      secret (out of combat). A buff's cause is the cast at
--                      its application time (expiration - duration), so a
--                      buff applied in combat and still up when combat drops
--                      is matched to the cast that made it.
--  Static spell data (base cooldown, charges, recharge) is read alongside.
--  Every read is defensive: errors and secret values are skipped. No UI here.
-------------------------------------------------------------------------------
local Harvest = {}
ns.Harvest = Harvest

local CAUSE_WINDOW = 0.6     -- seconds between a cast and the buff it applies
local CAST_HISTORY = 90      -- seconds of casts kept for cause matching

local function Secret(v) return issecretvalue and issecretvalue(v) end

local function Clean(v)
    if v == nil or Secret(v) then return nil end
    return v
end

local function Call(fn, ...)
    if not fn then return nil end
    local ok, a, b = pcall(fn, ...)
    if not ok then return nil end
    return a, b
end

function Harvest.Enabled() return ns.DB().harvesting == true end

-- The catalog for a spec (created on first use).
function Harvest.Catalog(specID)
    local db = ns.DB()
    db.harvest = db.harvest or {}
    local c = db.harvest[specID]
    if not c then
        c = { spells = {}, auras = {} }
        db.harvest[specID] = c
    end
    return c
end

function Harvest.Clear(specID)
    local db = ns.DB()
    if db.harvest then db.harvest[specID] = nil end
end

local function SpellRecord(cat, id)
    local s = cat.spells[id]
    if not s then
        s = { sources = {} }
        cat.spells[id] = s
    end
    local info = Call(C_Spell and C_Spell.GetSpellInfo, id)
    if info then
        s.name = Clean(info.name) or s.name
        s.icon = Clean(info.iconID) or s.icon
    end
    -- Static data; charges and recharge only out of restricted combat.
    local ms = Clean(Call(GetSpellBaseCooldown, id))
    if type(ms) == "number" and ms > 0 then s.cd = ms / 1000 end
    local ch = Call(C_Spell and C_Spell.GetSpellCharges, id)
    if ch then
        local max = Clean(ch.maxCharges)
        if type(max) == "number" and max > 1 then
            s.charges = max
            local rc = Clean(ch.cooldownDuration)
            if type(rc) == "number" and rc > 0 then s.recharge = rc end
        end
    end
    return s
end

local function AuraRecord(cat, id)
    local a = cat.auras[id]
    if not a then
        a = { causes = {} }
        cat.auras[id] = a
    end
    if not a.name then
        local info = Call(C_Spell and C_Spell.GetSpellInfo, id)
        if info then a.name, a.icon = Clean(info.name), Clean(info.iconID) end
    end
    return a
end

-------------------------------------------------------------------------------
--  Static scans: Cooldown Manager, spellbook, talents
-------------------------------------------------------------------------------
local CDM_CATEGORIES = {
    { key = "Essential", tag = "essential" },
    { key = "Utility", tag = "utility" },
    { key = "TrackedBuff", tag = "buff", aura = true },
    { key = "TrackedBar", tag = "buff", aura = true },
}

function Harvest.ScanCDM(cat)
    local CV = C_CooldownViewer
    local cats = Enum and Enum.CooldownViewerCategory
    if not (CV and CV.GetCooldownViewerCategorySet and cats) then return end
    for _, c in ipairs(CDM_CATEGORIES) do
        local ids = cats[c.key] and Call(CV.GetCooldownViewerCategorySet, cats[c.key], true)
        for _, cdID in ipairs(ids or {}) do
            local info = Call(CV.GetCooldownViewerCooldownInfo, cdID)
            local id = info and Clean(info.spellID)
            if type(id) == "number" and id > 0 then
                if c.aura then
                    AuraRecord(cat, id).cdm = true
                else
                    local s = SpellRecord(cat, id)
                    s.sources.cdm = c.tag
                    if info.isKnown == false then s.unlearned = true end
                end
                -- Buffs a cooldown shows (an ability's own buff, or a tracked
                -- buff's linked spells) are linked to it in any category.
                for _, linked in ipairs(info.linkedSpellIDs or {}) do
                    linked = Clean(linked)
                    if type(linked) == "number" and linked > 0 then AuraRecord(cat, linked).cdm = true end
                end
            end
        end
    end
end

function Harvest.ScanSpellbook(cat, specID)
    local SB = C_SpellBook
    if not (SB and SB.GetNumSpellBookSkillLines and SB.GetSpellBookSkillLineInfo and SB.GetSpellBookItemInfo) then return end
    local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
    local spellType = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell or 1
    local className = UnitClass and UnitClass("player")
    local n = Call(SB.GetNumSpellBookSkillLines) or 0
    for line = 1, n do
        local li = Call(SB.GetSpellBookSkillLineInfo, line)
        -- The class's line (named after the class) and the current spec's
        -- line; never General, professions, guild or other specs.
        local wanted = li and not li.isGuild and not li.shouldHide and not li.offSpecID
            and (li.specID == specID or (not li.specID and li.name == className))
        if wanted then
            for i = li.itemIndexOffset + 1, li.itemIndexOffset + li.numSpellBookItems do
                local item = Call(SB.GetSpellBookItemInfo, i, bank)
                if item and item.itemType == spellType and not item.isOffSpec then
                    local id = Clean(item.actionID)
                    if type(id) == "number" and id > 0 then
                        local s = SpellRecord(cat, id)
                        s.sources.spellbook = true
                        s.passive = item.isPassive or nil
                    end
                end
            end
        end
    end
end

function Harvest.ScanTalents(cat)
    local T = C_Traits
    local configID = C_ClassTalents and Call(C_ClassTalents.GetActiveConfigID)
    if not (T and configID) then return end
    local config = Call(T.GetConfigInfo, configID)
    for _, treeID in ipairs(config and config.treeIDs or {}) do
        for _, nodeID in ipairs(Call(T.GetTreeNodes, treeID) or {}) do
            local node = Call(T.GetNodeInfo, configID, nodeID)
            local active = node and node.activeEntry and (node.activeRank or 0) > 0
            if active and node.subTreeID then
                local sub = Call(T.GetSubTreeInfo, configID, node.subTreeID)
                active = sub and sub.isActive
            end
            if active then
                local entry = Call(T.GetEntryInfo, configID, node.activeEntry.entryID)
                local defn = entry and entry.definitionID and Call(T.GetDefinitionInfo, entry.definitionID)
                local id = defn and Clean(defn.spellID)
                if type(id) == "number" and id > 0 then
                    SpellRecord(cat, id).sources.talent = true
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
--  Casts and buffs
-------------------------------------------------------------------------------
local casts = {}   -- { { id, t }, ... } recent player casts, oldest first

function Harvest.OnCast(specID, spellID, now)
    if type(spellID) ~= "number" or Secret(spellID) then return end
    local cat = Harvest.Catalog(specID)
    local s = SpellRecord(cat, spellID)
    s.casts = (s.casts or 0) + 1
    -- Auto-attacks never cause buffs worth tracking; they'd only mask the
    -- real cause (Auto Shot fires every few seconds).
    if ns.AUTO_ATTACKS[spellID] then return end
    casts[#casts + 1] = { id = spellID, t = now }
    while casts[1] and now - casts[1].t > CAST_HISTORY do table.remove(casts, 1) end
end

-- The cast closest to time t, within the cause window.
local function CastAt(t)
    local best, bestGap
    for i = #casts, 1, -1 do
        local gap = math.abs(casts[i].t - t)
        if gap <= CAUSE_WINDOW and (not bestGap or gap < bestGap) then best, bestGap = casts[i].id, gap end
        if casts[i].t < t - CAUSE_WINDOW then break end
    end
    return best
end

-- Reads the player's (and pet's) own buffs. Skipped while auras are secret.
function Harvest.ScanAuras(specID, now)
    if C_Secrets and C_Secrets.ShouldAurasBeSecret and Call(C_Secrets.ShouldAurasBeSecret) then return end
    local get = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if not get then return end
    local cat = Harvest.Catalog(specID)
    for _, unit in ipairs({ "player", "pet" }) do
        for i = 1, 80 do
            local d = Call(get, unit, i, "HELPFUL")
            if not d then break end
            local id = Clean(d.spellId)
            local mine = Clean(d.isFromPlayerOrPlayerPet)
            if type(id) == "number" and mine then
                local a = AuraRecord(cat, id)
                a.name = a.name or Clean(d.name)
                a.unit = unit
                a.seen = (a.seen or 0) + 1
                local dur, exp = Clean(d.duration), Clean(d.expirationTime)
                if type(dur) == "number" and dur > 0 then
                    a.duration = math.max(a.duration or 0, dur)
                    if type(exp) == "number" then
                        local cause = CastAt(exp - dur)
                        if cause and cause ~= id then a.causes[cause] = (a.causes[cause] or 0) + 1 end
                    end
                end
                local stacks = Clean(d.applications)
                if type(stacks) == "number" and stacks > (a.stacks or 0) then a.stacks = stacks end
            end
        end
    end
end

-- The most frequent cause of an aura, if any.
function Harvest.MainCause(aura)
    local best, n = nil, 0
    for id, count in pairs(aura.causes or {}) do
        if count > n then best, n = id, count end
    end
    return best
end

function Harvest.ScanStatic(specID)
    local cat = Harvest.Catalog(specID)
    Harvest.ScanCDM(cat)
    Harvest.ScanSpellbook(cat, specID)
    Harvest.ScanTalents(cat)
    cat.updated = time and time() or nil
end

-------------------------------------------------------------------------------
--  Driver: zero cost while off.
-------------------------------------------------------------------------------
local frame = CreateFrame("Frame")
local STATIC_EVENTS = { "PLAYER_SPECIALIZATION_CHANGED", "TRAIT_CONFIG_UPDATED", "SPELLS_CHANGED",
    "COOLDOWN_VIEWER_DATA_LOADED" }

local function SpecID() return ns.GetSpecID() end

frame:SetScript("OnEvent", function(_, event, unit, ...)
    local specID = SpecID()
    if not specID then return end
    local now = GetTime()
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, spellID = ...
        if unit == "player" then Harvest.OnCast(specID, spellID, now) end
    elseif event == "UNIT_AURA" then
        Harvest.ScanAuras(specID, now)
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Auras stop being secret once combat ends; give the client a beat.
        C_Timer.After(0.2, function() Harvest.ScanAuras(SpecID() or specID, GetTime()) end)
    else
        Harvest.ScanStatic(specID)
    end
    if Harvest.onChange then Harvest.onChange() end
end)

function Harvest.Apply()
    frame:UnregisterAllEvents()
    if not Harvest.Enabled() then return end
    frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    frame:RegisterUnitEvent("UNIT_AURA", "player", "pet")
    frame:RegisterEvent("PLAYER_REGEN_ENABLED")
    for _, e in ipairs(STATIC_EVENTS) do frame:RegisterEvent(e) end
    local specID = SpecID()
    if specID then
        Harvest.ScanStatic(specID)
        Harvest.ScanAuras(specID, GetTime())
    end
end

function Harvest.SetEnabled(on)
    if on then ns.DB().harvesting = true else ns.DB().harvesting = nil end
    Harvest.Apply()
end

local login = CreateFrame("Frame")
login:RegisterEvent("PLAYER_LOGIN")
login:SetScript("OnEvent", function() Harvest.Apply() end)

-------------------------------------------------------------------------------
--  Counts and export
-------------------------------------------------------------------------------
function Harvest.Counts(specID)
    local cat = Harvest.Catalog(specID)
    local spells, cdm, casted, auras, timed = 0, 0, 0, 0, 0
    for _, s in pairs(cat.spells) do
        spells = spells + 1
        if s.sources.cdm then cdm = cdm + 1 end
        if s.casts then casted = casted + 1 end
    end
    for _, a in pairs(cat.auras) do
        auras = auras + 1
        if a.duration and Harvest.MainCause(a) then timed = timed + 1 end
    end
    return { spells = spells, cdm = cdm, casted = casted, auras = auras, timed = timed }
end

local function SortedIDs(t)
    local ids = {}
    for id in pairs(t) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

-- Readable text (for sharing and for building default APLs).
function Harvest.Export(specID)
    local cat = Harvest.Catalog(specID)
    local out = { "# APL for EUI harvest", "spec=" .. specID }
    if GetSpecializationInfoByID then
        local _, specName, _, _, _, _, className = GetSpecializationInfoByID(specID)
        if specName then out[#out + 1] = "# " .. specName .. " " .. (className or "") end
    end
    out[#out + 1] = ""
    for _, id in ipairs(SortedIDs(cat.spells)) do
        local s = cat.spells[id]
        local tags = {}
        if s.sources.cdm then tags[#tags + 1] = "cdm=" .. s.sources.cdm end
        if s.sources.spellbook then tags[#tags + 1] = "spellbook" end
        if s.sources.talent then tags[#tags + 1] = "talent" end
        if s.passive then tags[#tags + 1] = "passive" end
        if s.unlearned then tags[#tags + 1] = "unlearned" end
        if s.casts then tags[#tags + 1] = "casts=" .. s.casts end
        if s.cd then tags[#tags + 1] = "cd=" .. s.cd end
        if s.charges then tags[#tags + 1] = "charges=" .. s.charges end
        if s.recharge then tags[#tags + 1] = string.format("recharge=%.1f", s.recharge) end
        out[#out + 1] = "spell." .. id .. "=" .. tostring(s.name) .. " | " .. table.concat(tags, " ")
    end
    out[#out + 1] = ""
    for _, id in ipairs(SortedIDs(cat.auras)) do
        local a = cat.auras[id]
        local tags = {}
        if a.cdm then tags[#tags + 1] = "cdm" end
        if a.unit then tags[#tags + 1] = "unit=" .. a.unit end
        if a.duration then tags[#tags + 1] = string.format("duration=%.1f", a.duration) end
        if a.stacks and a.stacks > 1 then tags[#tags + 1] = "stacks=" .. a.stacks end
        local causeIDs = SortedIDs(a.causes or {})
        if #causeIDs > 0 then
            local parts = {}
            for _, cid in ipairs(causeIDs) do
                local name = cat.spells[cid] and cat.spells[cid].name or tostring(cid)
                parts[#parts + 1] = cid .. " " .. name .. " x" .. a.causes[cid]
            end
            tags[#tags + 1] = "from=" .. table.concat(parts, ", ")
        end
        out[#out + 1] = "aura." .. id .. "=" .. tostring(a.name) .. " | " .. table.concat(tags, " ")
    end
    return table.concat(out, "\n") .. "\n"
end
