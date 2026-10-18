local _, ns = ...

-------------------------------------------------------------------------------
--  Built-in Shadow Priest APLs, Archon hero tree. From Method's Midnight
--  Shadow guide (playstyle and rotation, Archon priority); spell and aura IDs
--  from an in-game harvest, not guessed. Two built-ins share everything but
--  the opener: Method's opener without the new 4-piece (the spec's default)
--  and with it.
--
--  Not expressible yet (secret in restricted combat), so approximated:
--    * Debuff timing on the target is secret, so the dots are self-timed
--      from your casts: Vampiric Touch 21s (from Vampiric Touch or Tentacle
--      Slam, refreshed in the pandemic window, < 6.3s), Shadow Word: Madness
--      6s (recast with a GCD or less left). The timers follow the last cast,
--      not each target.
--    * Whether Vampiric Touch is on the current target IS readable through
--      the Cooldown Manager (tested in game, in combat): that catches a
--      switch to an undotted target. Just after a Vampiric Touch / Tentacle
--      Slam cast the icon may lag, so "missing" waits for the next cast.
--    * "Insanity near capping" reads resource.insanity >= 85; if Insanity
--      turns out to be secret in combat this is simply never true.
--    * Shadow Word: Death "below 20% health" is left out: target health is
--      secret in combat.
--    * Void Volley replaces the Voidform button (its tooltip: cast by
--      Voidform, then up to 3 more during Voidform), so it's the voidform
--      entry while the button has turned into Void Volley or Voidform is up.
--  Misery (talented in the harvest) makes Vampiric Touch apply Shadow Word:
--  Pain, so there's no separate Shadow Word: Pain line.
--  Track in the Cooldown Manager: Vampiric Touch, Voidform, Mind Flay:
--  Insanity. Without Vampiric Touch tracked, it's always "missing".
-------------------------------------------------------------------------------
-- Method's openers. Priority lists like Windwalker's: each line fires once
-- its spell is ready; a step that can't go falls through to Default.
local OPENERS = {
    -- Tentacle Slam, Halo, Voidform, Power Infusion, Shadow Word: Madness,
    -- Void Volley.
    base = {
        { spell = "shadowform", when = "combat.time=0&!buff.shadowform.up" },
        { spell = "tentacle_slam", when = "combat.casts=0&!prev.tentacle_slam" },
        { spell = "halo" },
        { spell = "voidform", when = "!variable.void_volley" },
        { spell = "power_infusion" },
        { spell = "shadow_word_madness", when = "!timer.swm.up" },
        { spell = "voidform", when = "variable.void_volley" },
    },
    -- With the 4-piece: Mind Blast, Tentacle Slam, Halo, Void Volley (from
    -- the set, before Voidform), Voidform, Power Infusion, Shadow Word:
    -- Madness, Void Volley.
    tier = {
        { spell = "shadowform", when = "combat.time=0&!buff.shadowform.up" },
        { spell = "mind_blast", when = "combat.casts=0&!prev.mind_blast" },
        { spell = "tentacle_slam", when = "combat.casts<=1&!prev.tentacle_slam" },
        { spell = "halo" },
        { spell = "voidform", when = "variable.void_volley&!buff.voidform_buff.up" },
        { spell = "voidform", when = "!variable.void_volley" },
        { spell = "power_infusion" },
        { spell = "shadow_word_madness", when = "!timer.swm.up" },
        { spell = "voidform", when = "variable.void_volley" },
    },
}

local function ShadowArchon(id, name, opener, window) return {
    id = id,
    name = name,
    specID = 258,
    builtin = true,
    options = { rangeSpell = "vampiric_touch" },

    names = {
        shadowform = 232698,
        vampiric_touch = 34914,
        tentacle_slam = 1227280,
        halo = 120644,
        voidform = 228260,              -- the button also casts Void Volley in Voidform
        power_infusion = 10060,
        shadow_word_madness = 335467,
        mind_blast = 8092,
        mind_flay = 15407,
        voidform_buff = 194249,
        mind_flay_insanity = 391401,    -- buff: Mind Flay casts as Mind Flay: Insanity
        -- Free casts
        silence = 15487,
        psychic_scream = 8122,
        fade = 586,
        dispersion = 47585,
        desperate_prayer = 19236,
        power_word_shield = 17,
        vampiric_embrace = 15286,
        angelic_feather = 121536,
        leap_of_faith = 73325,
        purify_disease = 213634,
        mass_dispel = 32375,
        dispel_magic = 528,
        flash_heal = 2061,
    },

    -- Utility casts that never count against compliance.
    freeCasts = {
        "silence", "psychic_scream", "fade", "dispersion", "desperate_prayer",
        "power_word_shield", "vampiric_embrace", "angelic_feather", "leap_of_faith",
        "purify_disease", "mass_dispel", "dispel_magic", "flash_heal",
    },

    tts = {
        vampiric_touch = "Touch",
        tentacle_slam = "Slam",
        halo = "Halo",
        voidform = "Void",
        power_infusion = "Infusion",
        shadow_word_madness = "Madness",
        mind_blast = "Blast",
        mind_flay = "Flay",
    },

    variables = {
        -- Vampiric Touch missing from this target (not just cast), or inside
        -- its pandemic window (30% of 21s).
        { name = "vt_missing", expr = "!buff.vampiric_touch.up&!prev.vampiric_touch&!prev.tentacle_slam" },
        { name = "vt_refresh", expr = "variable.vt_missing|!timer.vt.up|timer.vt.remains<6.3" },
        -- Shadow Word: Madness missing or about to expire (a GCD or less).
        { name = "swm_refresh", expr = "!timer.swm.up|timer.swm.remains<=1.5" },
        { name = "insanity_capping", expr = "resource.insanity>=85" },
        -- The Voidform button is Void Volley right now (or Voidform is up).
        { name = "void_volley", expr = "!(override.voidform=voidform)|buff.voidform_buff.up" },
    },

    timers = {
        { name = "vt", triggers = {
            { on = "cast", spell = "vampiric_touch", action = "set", value = "21" },
            { on = "cast", spell = "tentacle_slam", action = "set", value = "21" },
        } },
        { name = "swm", triggers = {
            { on = "cast", spell = "shadow_word_madness", action = "set", value = "6" },
        } },
    },

    groups = {
        { name = "Opener", prefix = "OP", when = window, lists = {
            { name = "Opener", prefix = "O", min = 1, entries = opener },
        } },
        { name = "Default", prefix = "DEF", lists = {
            -- The guide's multi-target priority is the single-target one
            -- (Psychic Link cleaves every spell); the difference is dotting
            -- extra targets, which is left to you. One list for all counts.
            { name = "All", prefix = "P", min = 1, entries = {
                { spell = "shadowform", when = "combat.time=0&!buff.shadowform.up" },
                { spell = "tentacle_slam", when = "variable.vt_refresh" },
                { spell = "vampiric_touch", when = "variable.vt_refresh" },
                { spell = "halo" },
                { spell = "voidform", when = "!variable.void_volley" },
                { spell = "power_infusion" },
                { spell = "shadow_word_madness", when = "variable.swm_refresh|variable.insanity_capping" },
                { spell = "tentacle_slam", when = "charges.tentacle_slam.full" },
                { spell = "mind_blast" },
                { spell = "tentacle_slam" },
                { spell = "mind_flay", when = "buff.mind_flay_insanity.up&timer.swm.up" },
                -- Void Volley.
                { spell = "voidform", when = "variable.void_volley" },
                { spell = "mind_flay" },
            } },
        } },
    },
} end

-- The first one registered is the spec's default.
ns.RegisterBuiltinAPL(ShadowArchon("builtin:priest_shadow_archon", "Shadow - Archon (default)",
    OPENERS.base, "combat.casts<7&combat.time<15"))
ns.RegisterBuiltinAPL(ShadowArchon("builtin:priest_shadow_archon_4pc", "Shadow - Archon 4-piece (default)",
    OPENERS.tier, "combat.casts<9&combat.time<18"))
