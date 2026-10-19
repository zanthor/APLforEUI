local _, ns = ...

-------------------------------------------------------------------------------
--  Built-in Subtlety Rogue APL, Trickster hero tree (Coup de Grace, Unseen
--  Blade). From Method's Midnight Subtlety guide (playstyle and rotation:
--  Trickster openers and priorities); spell and aura IDs from an in-game
--  harvest, not guessed. The guide has no Raid / M+ split.
--
--  Not expressible yet, or assumed (check in game):
--    * Combo points are read with resource.combo_points, readable in combat
--      like Windwalker's Chi (tested in game; max 7 in the harvested build).
--      Supercharger's charged (blue) slots aren't points: an empty charged
--      slot reads 0.
--    * Shadowstrike is NOT an override of Backstab (tested in game): the
--      stealth / Shadow Dance action bar page swaps it in. So it's its own
--      entry while stealthed; an unpaged key needs a macro (README,
--      "Stance-paged spells").
--    * Coup de Grace IS Eviscerate's button turning into it (an override,
--      tested in game): it's the eviscerate entry while the button is
--      Coup de Grace.
--    * Shadowstrike (185438) wasn't in the harvest; its ID is confirmed in
--      game (usable only while stealthed).
--    * Shadow Dance: two uses per Shadow Blades. Shadow Blades' cooldown is
--      self-timed from its cast (secret in combat); within 10s of it Dance
--      waits so both charges go with Blades.
--    * The opener's "skip if Quietus Celeris procced" steps aren't modelled:
--      the openers are numbered by cast and a skipped step falls through.
--  Vanish only while another group member is in combat (group.combat):
--  solo, it drops combat and resets the fight.
--  Shadow Blades is holdable (hold 3, every line). While it's held, Shadow
--  Dance keeps one charge back for it (Dance only from 2 charges).
--  Track in the Cooldown Manager: Stealth, Subterfuge, Shadow Dance.
-------------------------------------------------------------------------------

local NAMES = function() return {
    stealth = 1784,
    backstab = 53,
    shadowstrike = 185438,          -- stealth / Shadow Dance page
    eviscerate = 196819,            -- Coup de Grace when it's up (override)
    shuriken_storm = 197835,
    black_powder = 319175,
    shadow_dance = 185313,
    shadow_blades = 121471,
    secret_technique = 280719,
    goremaws_bite = 426591,
    vanish = 1856,
    -- Buffs
    stealth_buff = 158185,
    subterfuge = 115192,
    shadow_dance_buff = 185422,
    -- Free casts
    kick = 1766,
    kidney_shot = 408,
    cheap_shot = 1833,
    blind = 2094,
    sap = 6770,
    distract = 1725,
    sprint = 2983,
    evasion = 5277,
    cloak_of_shadows = 31224,
    crimson_vial = 185311,
    feint = 1966,
    shadowstep = 36554,
    tricks_of_the_trade = 57934,
    shroud_of_concealment = 114018,
    thistle_tea = 381623,
    thistle_tea_2 = 1298826,
    shuriken_toss = 114014,
    will_of_the_forsaken = 7744,
} end

-- Default lists. aoe: Shuriken Storm generator and Black Powder finisher.
local function Priority(aoe)
    -- Generator: Shadowstrike while stealthed / in Dance on one target, else
    -- Backstab; Shuriken Storm on 2+ either way.
    local gen = aoe and "shuriken_storm" or "backstab"
    local e = {
        { spell = "stealth", when = "combat.time=0&!variable.stealthed" },
        { spell = "goremaws_bite" },
        -- Coup de Grace whenever it's up.
        { spell = "eviscerate", when = "variable.coup_de_grace" },
        { spell = "shadow_dance", when = "!buff.shadow_dance_buff.up&variable.cp_full&cooldown.secret_technique.ready&variable.dance_ok" },
        { spell = "shadow_blades", when = "buff.shadow_dance_buff.up", hold = 3 },
        { spell = "secret_technique", when = "buff.shadow_dance_buff.up&variable.cp_full" },
    }
    if aoe then
        e[#e + 1] = { spell = "black_powder", when = "variable.cp_full" }
    else
        e[#e + 1] = { spell = "eviscerate", when = "variable.cp_full" }
    end
    -- Vanish outside Dance at low combo points, then the stealth generator.
    -- Only while someone else in the group is fighting: solo, Vanish drops
    -- combat and resets the fight.
    e[#e + 1] = { spell = "vanish", when = "!variable.stealthed&resource.combo_points<=2&group.combat" }
    if not aoe then e[#e + 1] = { spell = "shadowstrike", when = "variable.stealthed" } end
    e[#e + 1] = { spell = gen }
    return e
end

ns.RegisterBuiltinAPL({
    id = "builtin:rogue_subtlety_trickster",
    name = "Subtlety - Trickster (default)",
    specID = 261,
    builtin = true,
    options = { rangeSpell = "backstab" },
    names = NAMES(),

    -- Utility casts that never count against compliance.
    freeCasts = {
        "kick", "kidney_shot", "cheap_shot", "blind", "sap", "distract", "sprint",
        "evasion", "cloak_of_shadows", "crimson_vial", "feint", "shadowstep",
        "tricks_of_the_trade", "shroud_of_concealment", "thistle_tea", "thistle_tea_2",
        "shuriken_toss", "will_of_the_forsaken",
    },

    tts = {
        backstab = "Stab",
        shadowstrike = "Strike",
        eviscerate = "Evis",
        shuriken_storm = "Storm",
        black_powder = "Powder",
        shadow_dance = "Dance",
        shadow_blades = "Blades",
        secret_technique = "Secret",
        goremaws_bite = "Bite",
        vanish = "Vanish",
        stealth = "Stealth",
    },

    variables = {
        { name = "stealthed", expr = "buff.stealth.up|buff.stealth_buff.up|buff.subterfuge.up|buff.shadow_dance_buff.up" },
        { name = "cp_full", expr = "resource.combo_points>=6" },
        -- Eviscerate's button has turned into Coup de Grace.
        { name = "coup_de_grace", expr = "!(override.eviscerate=eviscerate)" },
        -- Save both Dance charges for Shadow Blades once it's 10s or less
        -- away (unknown = never cast this session: no reason to wait).
        -- While Shadow Blades is held, Dance only from 2 charges, so one is
        -- always kept back for the burst.
        { name = "dance_ok", expr = "(cooldown.shadow_blades.ready|!(timer.blades_cd.remains<=10))&(!holding.shadow_blades|charges.shadow_dance.full)" },
    },

    timers = {
        { name = "blades_cd", triggers = {
            { on = "cast", spell = "shadow_blades", action = "set", value = "90" },
        } },
    },

    groups = {
        -- Method's Trickster openers, numbered by cast like Beast Mastery's.
        { name = "Opener", prefix = "OP", when = "combat.casts<10&combat.time<15", lists = {
            -- Shadowstrike, Eviscerate, Vanish, Shadowstrike, Goremaw's
            -- Bite, Eviscerate, Shadow Dance + Shadow Blades + Shuriken
            -- Storm, Secret Technique.
            { name = "ST", prefix = "OST", min = 1, max = 1, entries = {
                { spell = "stealth", when = "combat.time=0&!variable.stealthed" },
                { spell = "shadowstrike", when = "combat.casts=0" },
                { spell = "eviscerate", when = "combat.casts=1" },
                { spell = "vanish", when = "combat.casts=2&group.combat" },
                { spell = "shadowstrike", when = "combat.casts=3" },
                { spell = "goremaws_bite", when = "combat.casts=4" },
                { spell = "eviscerate", when = "combat.casts=5" },
                { spell = "shadow_dance", when = "combat.casts=6" },
                { spell = "shadow_blades", when = "combat.casts=7", hold = 3 },
                { spell = "shuriken_storm", when = "combat.casts=8" },
                { spell = "secret_technique", when = "combat.casts=9" },
            } },
            -- Shuriken Storm, Goremaw's Bite, Shadow Dance + Shadow Blades +
            -- Secret Technique, Shuriken Storm, Black Powder, Shuriken Storm.
            { name = "AOE", prefix = "OAO", min = 2, entries = {
                { spell = "stealth", when = "combat.time=0&!variable.stealthed" },
                { spell = "shuriken_storm", when = "combat.casts=0" },
                { spell = "goremaws_bite", when = "combat.casts=1" },
                { spell = "shadow_dance", when = "combat.casts=2" },
                { spell = "shadow_blades", when = "combat.casts=3", hold = 3 },
                { spell = "secret_technique", when = "combat.casts=4" },
                { spell = "shuriken_storm", when = "combat.casts=5" },
                { spell = "black_powder", when = "combat.casts=6" },
                { spell = "shuriken_storm", when = "combat.casts=7" },
            } },
        } },
        { name = "Default", prefix = "DEF", lists = {
            { name = "ST", prefix = "ST", min = 1, max = 1, entries = Priority(false) },
            { name = "AOE", prefix = "AOE", min = 2, entries = Priority(true) },
        } },
    },
})
