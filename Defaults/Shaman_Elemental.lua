local _, ns = ...

-------------------------------------------------------------------------------
--  Built-in Elemental Shaman APLs, Farseer hero tree (Call of the Ancestors,
--  Ancestral Swiftness). From Method's Midnight Elemental guide (playstyle
--  and rotation: Raid Build and M+ Build priorities, single-target and AoE
--  openers); spell and aura IDs from an in-game harvest, not guessed. Two
--  built-ins, Raid (the spec's default) and M+, with the same openers.
--
--  Not expressible yet (secret in restricted combat), so approximated:
--    * Flame Shock's time left on the target is secret: it's self-timed
--      (18s from Flame Shock or Voltaic Blaze, refreshed under 6s) and
--      follows the last cast, not each target. Whether it's on the current
--      target is read through the Cooldown Manager (as for Shadow's
--      Vampiric Touch), which catches a switch to a target without it.
--      Flame Shock's button turns into Voltaic Blaze (tested in game), so
--      either spell ID's icon counts.
--    * "Refresh when Fire Elemental has < 3s left" is left out: Fire
--      Elemental isn't cast directly (Primal Elementalist), so its time
--      left can't be tracked.
--    * "Elemental Blast within 15 Maelstrom of cap" is left out: Maelstrom
--      reads as secret (tested in game). Spenders still wait until they're
--      castable (the usable check).
--    * "Hold Stormkeeper for AoE or damage amps (up to 10s)" is left to you:
--      it's suggested on cooldown.
--    * Ancestral Swiftness replaces Nature's Swiftness (tested in game), so
--      it's the natures_swiftness entry.
--  Stormkeeper is holdable (hold 3, every line), and Ascendance follows
--  Stormkeeper (only while its buff is up), so holding Stormkeeper holds
--  Ascendance with it.
--  Track in the Cooldown Manager: Flame Shock, Master of the Elements,
--  Stormkeeper, Call of the Ancestors, Purging Flames, Lava Surge.
-------------------------------------------------------------------------------

local function Names() return {
    stormkeeper = 191634,
    natures_swiftness = 378081,     -- Ancestral Swiftness replaces it (Farseer)
    ascendance = 114050,
    flame_shock = 470411,
    voltaic_blaze = 470057,
    lava_burst = 51505,
    lightning_bolt = 188196,
    chain_lightning = 188443,
    elemental_blast = 117014,
    earthquake = 61882,
    -- Buffs (player) and the Flame Shock debuff (current target)
    flame_shock_dot = 188389,
    master_of_the_elements = 260734,
    stormkeeper_buff = 191634,
    call_of_the_ancestors = 447244,
    purging_flames = 1259491,
    lava_surge = 77762,
    -- Free casts
    wind_shear = 57994,
    astral_shift = 108271,
    spiritwalkers_grace = 79206,
    capacitor_totem = 192058,
    gust_of_wind = 192063,
    wind_rush_totem = 192077,
    earthbind_totem = 2484,
    thunderstorm = 51490,
    cleanse_spirit = 51886,
    poison_cleansing_totem = 383013,
    earth_elemental = 198103,
    bloodlust = 2825,
    healing_surge = 8004,
    ghost_wolf = 2645,
    purge = 370,
    blood_fury = 33697,
} end

-- Method's openers, as priority lists like Windwalker's: each line fires
-- once its spell is ready; a step that can't go falls through.
local function Openers() return {
    -- Stormkeeper and Lava Burst before the pull, Ancestral Swiftness,
    -- Ascendance, Lightning Bolt, Lava Burst.
    { name = "ST", prefix = "OST", min = 1, max = 1, entries = {
        { spell = "stormkeeper", when = "combat.casts=0", hold = 3 },
        { spell = "lava_burst", when = "combat.casts=0&!prev.lava_burst" },
        { spell = "natures_swiftness" },
        { spell = "ascendance", when = "variable.after_stormkeeper" },
        { spell = "lightning_bolt", when = "buff.stormkeeper_buff.up&!prev.lightning_bolt" },
        { spell = "lava_burst" },
    } },
    -- Stormkeeper before the pull, Ancestral Swiftness, Voltaic Blaze,
    -- Ascendance, Lava Burst.
    { name = "AOE", prefix = "OAO", min = 2, entries = {
        { spell = "stormkeeper", when = "combat.casts=0", hold = 3 },
        { spell = "natures_swiftness" },
        { spell = "voltaic_blaze" },
        { spell = "ascendance", when = "variable.after_stormkeeper" },
        { spell = "lava_burst" },
    } },
} end

-- Single target. raid: Flame Shock as well as Voltaic Blaze for the
-- refresh, and the Stormkeeper Lightning Bolt with Master of the Elements.
-- two: the 2-target version (Voltaic Blaze on cooldown, Chain Lightning
-- for Lightning Bolt).
local function SingleTarget(raid, two)
    local bolt = two and "chain_lightning" or "lightning_bolt"
    local e = {
        { spell = "stormkeeper", hold = 3 },
        { spell = "natures_swiftness" },
        { spell = "ascendance", when = "variable.after_stormkeeper" },
    }
    if two then e[#e + 1] = { spell = "voltaic_blaze" } end
    e[#e + 1] = { spell = "voltaic_blaze", when = "variable.fs_refresh" }
    if raid then e[#e + 1] = { spell = "flame_shock", when = "variable.fs_refresh" } end
    e[#e + 1] = { spell = "lava_burst", when = "!buff.master_of_the_elements.up" }
    if raid then
        e[#e + 1] = { spell = bolt, when = "buff.stormkeeper_buff.up&buff.master_of_the_elements.up" }
    end
    e[#e + 1] = { spell = "elemental_blast", when = "buff.master_of_the_elements.up" }
    e[#e + 1] = { spell = bolt }
    return e
end

-- Multi-target: Stormkeeper, Ancestral Swiftness, Voltaic Blaze,
-- Ascendance, Lava Burst with Purging Flames (Lava Surge first), then the
-- spender, then Chain Lightning. spender: list of entries for the spender
-- step. noLavaBurst: raid at 3 targets (Flame Shock on one target instead).
local function MultiTarget(spender, noLavaBurst)
    local e = {
        { spell = "stormkeeper", hold = 3 },
        { spell = "natures_swiftness" },
        { spell = "voltaic_blaze" },
        { spell = "ascendance", when = "variable.after_stormkeeper" },
    }
    if noLavaBurst then
        e[#e + 1] = { spell = "flame_shock", when = "variable.fs_refresh" }
    else
        e[#e + 1] = { spell = "lava_burst", when = "buff.purging_flames.up&buff.lava_surge.up" }
        e[#e + 1] = { spell = "lava_burst", when = "buff.purging_flames.up" }
    end
    for _, s in ipairs(spender) do e[#e + 1] = s end
    e[#e + 1] = { spell = "chain_lightning" }
    return e
end

local function Elemental(id, name, raid)
    local lists
    if raid then
        lists = {
            { name = "ST", prefix = "ST", min = 1, max = 1, entries = SingleTarget(true, false) },
            { name = "2 Targets", prefix = "T2", min = 2, max = 2, entries = SingleTarget(true, true) },
            { name = "3 Targets", prefix = "T3", min = 3, max = 3,
              entries = MultiTarget({ { spell = "earthquake" } }, true) },
            { name = "AOE", prefix = "AOE", min = 4,
              entries = MultiTarget({ { spell = "earthquake" } }, false) },
        }
    else
        lists = {
            { name = "ST", prefix = "ST", min = 1, max = 1, entries = SingleTarget(false, false) },
            { name = "2 Targets", prefix = "T2", min = 2, max = 2, entries = SingleTarget(false, true) },
            -- Earthquake while the Ancestors are up, Elemental Blast without.
            { name = "AOE", prefix = "AOE", min = 3, max = 4, entries = MultiTarget({
                { spell = "earthquake", when = "buff.call_of_the_ancestors.up" },
                { spell = "elemental_blast", when = "!buff.call_of_the_ancestors.up" },
            }, false) },
            -- 5+: always Earthquake.
            { name = "Big AOE", prefix = "BIG", min = 5,
              entries = MultiTarget({ { spell = "earthquake" } }, false) },
        }
    end
    return {
        id = id,
        name = name,
        specID = 262,
        builtin = true,
        options = { rangeSpell = "lightning_bolt" },
        names = Names(),

        -- Utility casts that never count against compliance.
        freeCasts = {
            "wind_shear", "astral_shift", "spiritwalkers_grace", "capacitor_totem",
            "gust_of_wind", "wind_rush_totem", "earthbind_totem", "thunderstorm",
            "cleanse_spirit", "poison_cleansing_totem", "earth_elemental", "bloodlust",
            "healing_surge", "ghost_wolf", "purge", "blood_fury",
        },

        tts = {
            stormkeeper = "Storm",
            natures_swiftness = "Swift",
            ascendance = "Ascend",
            flame_shock = "Shock",
            voltaic_blaze = "Blaze",
            lava_burst = "Lava",
            lightning_bolt = "Bolt",
            chain_lightning = "Chain",
            elemental_blast = "Blast",
            earthquake = "Quake",
        },

        variables = {
            -- "Ascendance: always cast after Stormkeeper": only while its
            -- buff is up. Holding Stormkeeper (hold 3) holds Ascendance too.
            { name = "after_stormkeeper", expr = "buff.stormkeeper_buff.up" },
            -- Flame Shock missing from this target (not just applied), or
            -- under 6s left.
            { name = "fs_missing", expr = "!(buff.flame_shock_dot.up|buff.flame_shock.up)&!prev.flame_shock&!prev.voltaic_blaze" },
            { name = "fs_refresh", expr = "variable.fs_missing|!timer.fs.up|timer.fs.remains<6" },
        },

        timers = {
            { name = "fs", triggers = {
                { on = "cast", spell = "flame_shock", action = "set", value = "18" },
                { on = "cast", spell = "voltaic_blaze", action = "set", value = "18" },
            } },
        },

        groups = {
            { name = "Opener", prefix = "OP", when = "combat.casts<6&combat.time<10", lists = Openers() },
            { name = "Default", prefix = "DEF", lists = lists },
        },
    }
end

-- The first one registered is the spec's default.
ns.RegisterBuiltinAPL(Elemental("builtin:shaman_elemental_farseer_raid", "Elemental - Farseer Raid (default)", true))
ns.RegisterBuiltinAPL(Elemental("builtin:shaman_elemental_farseer_mplus", "Elemental - Farseer M+ (default)", false))
