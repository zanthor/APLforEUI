-- Shared WoW API mocks for the offline tests. Loads the addon in TOC order.
-- usage: local S, ns, printed = dofile(dir .. "/tests/mock_wow.lua")(dir)
-- S is the mutable game state the mocks read from.
return function(dir)
    local S = { now = 1000, chi = 3, buffs = {}, cd = {}, talents = {}, overrides = {}, zenCharges = 2, targets = 1,
        spellNames = { [113656] = "Fists of Fury", [100780] = "Tiger Palm", [1249625] = "Zenith" } }

    -- generic frame stub: any method is a no-op
    local FrameMT = { __index = function() return function() end end }
    local function Stub() return setmetatable({}, FrameMT) end

    function wipe(t) for k in pairs(t) do t[k] = nil end return t end
    GetTime = function() return S.now end
    GetSpecialization = function() return 1 end
    GetSpecializationInfo = function() return 269 end
    InCombatLockdown = function() return true end
    CreateFrame = function() return Stub() end
    UIParent = Stub()
    C_Timer = { NewTicker = function() return Stub() end }
    SlashCmdList = {}
    issecure = function() return false end
    IsPlayerSpell = function(id) return true end
    UnitCanAttack = function() return true end
    UnitIsDead = function() return false end
    Enum = { PowerType = { Mana = 0, Energy = 3, Chi = 12, ComboPoints = 4 } }
    UnitPower = function(_, pt) if pt == 12 then return S.chi end return 0 end
    local BASE_CD = { [1249625] = 90000, [123904] = 120000 }
    GetSpellBaseCooldown = function(id) return BASE_CD[id] or 0 end
    local ZENITH = 1249625

    C_Spell = {
        GetOverrideSpell = function(id) return S.overrides[id] or id end,
        -- By ID, or by a name registered in S.spellNames (like the client
        -- resolving a known spell's name).
        GetSpellInfo = function(key)
            if type(key) == "number" then
                return { spellID = key, name = S.spellNames[key] or ("S" .. key), iconID = 1 }
            end
            for id, name in pairs(S.spellNames) do
                if name:lower() == tostring(key):lower() then return { spellID = id, name = name, iconID = 1 } end
            end
            return nil
        end,
        GetSpellCharges = function(id)
            if id == ZENITH then return { maxCharges = 2, isActive = S.zenCharges < 2 } end
            return nil
        end,
        GetSpellCooldown = function(id)
            if id == ZENITH then return { isActive = S.zenCharges == 0, isOnGCD = false } end
            return { isActive = S.cd[id] == true, isOnGCD = false }
        end,
        IsSpellInRange = function() return true end,
        -- Fists of Fury: the real rule the legacy code hard-codes (base 3 Chi,
        -- -1 during Zenith, -1 with Harmonic Combo, floor 1); verified in game
        -- to match IsSpellUsable in both directions.
        IsSpellUsable = function(id)
            if id == 113656 then
                local cost = 3 - (S.buffs[1249625] and 1 or 0) - (S.talents[1250041] and 1 or 0)
                return S.chi >= math.max(1, cost), false
            end
            return true, false
        end,
    }
    C_SpellBook = { IsSpellKnown = function(id) return S.talents[id] == true end }
    C_UnitAuras = {
        GetPlayerAuraBySpellID = function(id) if S.buffs[id] then return {} end return nil end,
        GetAuraDataByAuraInstanceID = function() return nil end,
    }
    C_NamePlate = { GetNamePlates = function()
        local p = {}
        for i = 1, S.targets do p[i] = { unitToken = "nameplate" .. i } end
        return p
    end }

    -- Cooldown Viewer mock: one item per currently active buff
    local function Item(id)
        return {
            GetBaseSpellID = function() return id end,
            IsShown = function() return S.buffs[id] == true end,
            GetAuraSpellInstanceID = function() if S.buffs[id] then return 1 end return nil end,
        }
    end
    local ALL_BUFFS = { 443294, ZENITH, 137384, 325202, 1297033, 2825 }
    S.ALL_BUFFS = ALL_BUFFS
    BuffIconCooldownViewer = { GetItemFrames = function()
        local t = {}
        for _, id in ipairs(ALL_BUFFS) do t[#t + 1] = Item(id) end
        return t
    end }

    local printed = {}
    print_real = print
    print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end

    -- load addon in TOC order
    local ns = {}
    for line in io.lines(dir .. "/APLforEUI.toc") do
        line = line:gsub("\r", "")
        if line ~= "" and not line:match("^##") then
            local f = assert(loadfile(dir .. "/" .. line:gsub("\\", "/")))
            f("APLforEUI", ns)
        end
    end
    return S, ns, printed
end
