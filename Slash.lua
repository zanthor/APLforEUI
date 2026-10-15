local _, ns = ...

ns.slashCommands.options = function()
    if EllesmereUI and EllesmereUI.OpenPlugin then EllesmereUI.OpenPlugin("APLforEUI") end
end

-- TEMP DEBUG: per-nameplate dump, remove once target count is confirmed fixed.
ns.slashCommands.melee = function()
    local apl, spec = ns.GetActiveAPL(), ns.GetActiveSpec()
    local rangeSpellID = (apl and apl.rangeSpellID) or (spec and spec.rangeSpellID)
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
                    .. " dead=" .. tostring(dead) .. " inRange=" .. tostring(inRange))
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
