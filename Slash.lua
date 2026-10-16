local _, ns = ...

ns.slashCommands.options = function()
    if EllesmereUI and EllesmereUI.OpenPlugin then EllesmereUI.OpenPlugin("APLforEUI") end
end

-- TEMP DEBUG: per-nameplate dump, remove once target count is confirmed fixed.
ns.slashCommands.melee = function()
    local apl = ns.GetActiveAPL()
    local rangeSpellID = apl and apl.rangeSpellID
    if not rangeSpellID then
        print("APL debug: current spec is not supported.")
        return
    end
    local plates = C_NamePlate and C_NamePlate.GetNamePlates and C_NamePlate.GetNamePlates(issecure())
    print("APL debug: " .. (plates and #plates or 0) .. " nameplate(s)")
    if plates then
        for _, plate in ipairs(plates) do
            local unit = plate.namePlateUnitToken or plate.unitToken
            if unit then
                local canAttack = UnitCanAttack("player", unit)
                local dead = UnitIsDead(unit)
                local inRange = C_Spell and C_Spell.IsSpellInRange and C_Spell.IsSpellInRange(rangeSpellID, unit)
                print("APL debug: " .. unit .. " canAttack=" .. tostring(canAttack)
                    .. " dead=" .. tostring(dead) .. " inCombat=" .. tostring(UnitAffectingCombat(unit))
                    .. " inRange=" .. tostring(inRange))
            else
                -- Neither known field name resolved -- dump every key on this
                -- plate so we can find the real one instead of guessing again.
                local keys = {}
                for k in pairs(plate) do keys[#keys + 1] = tostring(k) end
                print("APL debug: plate with no unit token, keys: " .. table.concat(keys, ", "))
            end
        end
    end
    print("APL debug: GetTargetCount() = " .. ns.GetTargetCount())
end

-- Which addon restrictions are active right now, and whether the data this
-- addon reads would come back secret. Restriction types and predicates are
-- from C_RestrictedActions / C_Secrets (Blizzard_APIDocumentationGenerated).
ns.slashCommands.secrets = function()
    local active = {}
    if C_RestrictedActions and C_RestrictedActions.IsAddOnRestrictionActive and Enum.AddOnRestrictionType then
        for name, value in pairs(Enum.AddOnRestrictionType) do
            if C_RestrictedActions.IsAddOnRestrictionActive(value) then active[#active + 1] = name end
        end
        table.sort(active)
    end
    print("APL secrets: restrictions active: " .. (#active > 0 and table.concat(active, ", ") or "none"))
    local S = C_Secrets
    if not S then
        print("APL secrets: C_Secrets not available.")
        return
    end
    local function Q(fn, ...)
        if not fn then return "n/a" end
        local ok, v = pcall(fn, ...)
        return ok and tostring(v) or "error"
    end
    print("APL secrets: cooldowns=" .. Q(S.ShouldCooldownsBeSecret)
        .. " auras=" .. Q(S.ShouldAurasBeSecret)
        .. " chi=" .. Q(S.ShouldUnitPowerBeSecret, "player", Enum.PowerType.Chi)
        .. " energy=" .. Q(S.ShouldUnitPowerBeSecret, "player", Enum.PowerType.Energy))
end

-- The Cooldown Manager icons the CDM glow (Glow.lua) can see: Blizzard's
-- Essential/Utility viewer item frames (EUI restyles and anchors these), with
-- the spell IDs Blizzard's own methods report, flagging secret values.
ns.slashCommands.cdm = function()
    local function Read(item, method)
        local fn = item[method]
        if not fn then return "n/a" end
        local ok, v = pcall(fn, item)
        if not ok then return "error" end
        if v == nil then return "nil" end
        if issecretvalue and issecretvalue(v) then return "SECRET" end
        return tostring(v)
    end
    local expected = ns.EvaluateExpected()
    local restricted = C_Secrets and C_Secrets.ShouldCooldownsBeSecret and C_Secrets.ShouldCooldownsBeSecret()
    print(string.format("APL cdm: inCombat=%s cooldownsSecret=%s suggestion=%s (%s)",
        tostring(InCombatLockdown()), tostring(restricted), tostring(expected),
        expected and ns.SpellName(expected) or "none"))
    local total, shown, secret, match = 0, 0, 0, 0
    for _, viewerName in ipairs({ "EssentialCooldownViewer", "UtilityCooldownViewer" }) do
        local viewer = _G[viewerName]
        local items = viewer and viewer.GetItemFrames and viewer:GetItemFrames()
        if not items then
            print("APL cdm: " .. viewerName .. " not found")
        else
            for i, item in ipairs(items) do
                total = total + 1
                local isShown = item.IsShown and item:IsShown()
                if isShown then shown = shown + 1 end
                local parent = item.GetParent and item:GetParent()
                local pname = parent and parent.GetName and parent:GetName() or "?"
                local sid, base = Read(item, "GetSpellID"), Read(item, "GetBaseSpellID")
                if sid == "SECRET" or base == "SECRET" then secret = secret + 1 end
                local isMatch = expected and (tostring(expected) == sid or tostring(expected) == base
                    or tostring(expected) == tostring(ns.ResolveOverride(tonumber(base) or 0)))
                if isMatch then match = match + 1 end
                local idNum = tonumber(sid) or tonumber(base)
                print(string.format("  %s #%d shown=%s parent=%s spell=%s base=%s %s%s",
                    viewerName:gsub("CooldownViewer", ""), i, tostring(isShown), pname, sid, base,
                    idNum and ns.SpellName(idNum) or "", isMatch and "  <== suggestion" or ""))
            end
        end
    end
    print(string.format("APL cdm: %d frames, %d shown, %d with secret IDs, %d matching the suggestion",
        total, shown, secret, match))
end

SLASH_APLFOREUI1 = "/apl"
SlashCmdList.APLFOREUI = function(msg)
    local cmd, rest = msg:match("^(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()

    local handler = ns.slashCommands[cmd]
    if handler then
        handler(rest)
        return
    end
    if ns.IsTracking() then
        ns.StopTracking()
        print("APL for EUI: tracking stopped.")
    elseif ns.IsSpecSupported() then
        ns.StartTracking()
        print("APL for EUI: tracking started.")
    else
        print("APL for EUI: current spec is not supported.")
    end
end
