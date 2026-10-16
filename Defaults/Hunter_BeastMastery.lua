local _, ns = ...

-------------------------------------------------------------------------------
--  Built-in Beast Mastery Hunter APL, Pack Leader hero tree. From Method's
--  Midnight BM guide (Qenjua, patch 12.1.5, updated 13 Oct 2026); spell and
--  buff IDs from an in-game harvest, not guessed.
--
--  Bestial Wrath's remaining cooldown is secret in combat, so it's
--  self-tracked: 90s base, 60s less with The Beast Within (231548).
--  Not expressible yet (secret in restricted combat), so approximated:
--    * "Barbed Shot about to reach 2 charges" -> "Barbed Shot at 2 charges"
--      (recharge progress is secret).
--    * "Cobra Shot at max Cobra Fang stacks" -> "while Cobra Fang is up":
--      stacks are secret, but (tested in game with Animal Companion and the
--      2-piece) one Barbed Shot gives all 4 stacks and Cobra Shot spends them
--      all, so "up" means "at max". Without the tier set it never appears.
--      With fewer Stomps per Barbed Shot this would fire before max.
--  Buffs used here must be tracked in the Cooldown Manager to be readable in
--  combat: Howl of the Pack Leader, Nature's Ally, Beast Cleave, Cobra Fang.
-------------------------------------------------------------------------------
ns.RegisterBuiltinAPL({
    id = "builtin:hunter_bm_pack_leader",
    name = "Beast Mastery - Pack Leader (default)",
    specID = 253,
    builtin = true,
    options = { rangeSpell = "cobra_shot" },

    names = {
        barbed_shot = 217200,
        bestial_wrath = 19574,
        kill_command = 34026,
        cobra_shot = 193455,
        wild_thrash = 1264359,
        hunters_mark = 257284,
        the_beast_within = 231548,  -- talent: Bestial Wrath cooldown -60s
        -- Howl of the Pack Leader is up under three buff IDs (30s each); the
        -- one Bestial Wrath grants is 472325.
        howl_1 = 471877,
        howl_2 = 471878,
        howl_bw = 472325,
        natures_ally = 1276720,
        beast_cleave = 268877,   -- player buff from Wild Thrash (10s)
        cobra_fang = 1299389,    -- tier set: 4 stacks per Barbed Shot, 15s
    },

    tts = {
        barbed_shot = "Barbed",
        bestial_wrath = "Wrath",
        kill_command = "Kill",
        cobra_shot = "Cobra",
        wild_thrash = "Thrash",
        hunters_mark = "Mark",
    },

    variables = {
        -- "Bestial Wrath is coming up": ready now, or due within ~2 GCDs.
        -- Unknown (not cast yet this session) reads as not due; "ready"
        -- covers that case.
        { name = "bw_soon", expr = "cooldown.bestial_wrath.ready|timer.bw_cd.remains<=4" },
        { name = "howl", expr = "buff.howl_1.up|buff.howl_2.up|buff.howl_bw.up" },
        -- Kill Command is worth pressing while either buff is up.
        { name = "kc_buffed", expr = "variable.howl|buff.natures_ally.up" },
    },

    timers = {
        { name = "bw_cd", triggers = {
            { on = "cast", spell = "bestial_wrath", when = "talent.the_beast_within",
              action = "set", value = "spell.bestial_wrath.base_cd-60" },
            { on = "cast", spell = "bestial_wrath", action = "set", value = "spell.bestial_wrath.base_cd" },
        } },
    },

    groups = {
        -- Method's openers as fixed sequences: step N is cast number N of the
        -- fight. Hunter's Mark shows before the pull (combat.time reads 0).
        -- A step whose spell isn't ready falls through to the Default group.
        { name = "Opener", prefix = "OP", when = "combat.casts<7&combat.time<12", lists = {
            { name = "ST", prefix = "OST", min = 1, max = 1, entries = {
                { spell = "hunters_mark", when = "combat.time=0&!prev.hunters_mark" },
                { spell = "barbed_shot", when = "combat.casts<=1" },
                { spell = "bestial_wrath", when = "combat.casts=2" },
                { spell = "kill_command", when = "combat.casts=3" },
                { spell = "cobra_shot", when = "combat.casts=4" },
                { spell = "barbed_shot", when = "combat.casts=5" },
                { spell = "kill_command", when = "combat.casts=6" },
            } },
            -- The guide's "Fast" multi-target opener.
            { name = "AOE", prefix = "OAO", min = 2, entries = {
                { spell = "hunters_mark", when = "combat.time=0&!prev.hunters_mark" },
                { spell = "wild_thrash", when = "combat.casts=0" },
                { spell = "barbed_shot", when = "combat.casts=1" },
                { spell = "kill_command", when = "combat.casts=2" },
                { spell = "bestial_wrath", when = "combat.casts=3" },
                { spell = "barbed_shot", when = "combat.casts=4" },
                { spell = "kill_command", when = "combat.casts=5" },
                { spell = "cobra_shot", when = "combat.casts=6" },
            } },
        } },
        { name = "Default", prefix = "DEF", lists = {
            { name = "ST", prefix = "ST", min = 1, max = 1, entries = {
                -- Spend Barbed Shot before Bestial Wrath (which wants it at
                -- 0 charges), or so it never sits at 2.
                { spell = "barbed_shot", when = "charges.barbed_shot.full|variable.bw_soon" },
                { spell = "bestial_wrath", when = "charges.barbed_shot=0" },
                { spell = "kill_command", when = "variable.kc_buffed" },
                { spell = "cobra_shot", when = "buff.cobra_fang.up" },
                { spell = "barbed_shot" },
                { spell = "cobra_shot" },
            } },
            { name = "AOE", prefix = "AOE", min = 2, entries = {
                -- Right after Bestial Wrath, or to (re)apply Beast Cleave.
                { spell = "wild_thrash", when = "prev.bestial_wrath|!buff.beast_cleave.up" },
                { spell = "barbed_shot", when = "charges.barbed_shot.full" },
                { spell = "bestial_wrath", when = "buff.beast_cleave.up" },
                { spell = "wild_thrash" },
                { spell = "kill_command", when = "variable.kc_buffed" },
                { spell = "cobra_shot", when = "buff.cobra_fang.up" },
                { spell = "barbed_shot" },
                { spell = "cobra_shot" },
            } },
        } },
    },
})
