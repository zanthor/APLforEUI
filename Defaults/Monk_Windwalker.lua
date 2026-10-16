local _, ns = ...

-------------------------------------------------------------------------------
--  Built-in Windwalker APL: the simplified test APL from monkapl.md as
--  data. Labels are list prefix + position (ST9, AOE13); positions differ
--  from monkapl.md's step numbers because the O1/O2 opener entries come
--  first and step 5 has no entry of its own.
--  tests/parity_sim.lua checks it against the original Lua version.
-------------------------------------------------------------------------------

-- Zenith and Zenith Stomp share one button: once talented into Stomp every
-- press reports zenith_stomp, and what it did depends on the Zenith window
-- at that moment (down = build, <=2s left = recast-to-extend, else a Stomp
-- spend). Shared by the zenith/hotjs timers and the stomp counter.
local ZENITH_BUILD_OR_EXTEND = "!timer.zenith.up|timer.zenith.remains<=2"

ns.RegisterBuiltinAPL({
    id = "builtin:monk_windwalker",
    name = "Windwalker (default)",
    specID = 269,
    builtin = true,
    options = { noRepeatLastCast = true, rangeSpell = "tiger_palm" },

    names = {
        tiger_palm = 100780,
        fists_of_fury = 113656,
        blackout_kick = 100784,
        rising_sun_kick = 107428,
        rushing_wind_kick = 467307,
        whirling_dragon_punch = 152175,
        strike_of_the_windlord = 392983,
        celestial_conduit = 443028,
        invoke_xuen = 123904,
        zenith = 1249625,               -- casts the cooldown and tags the buff
        zenith_stomp = 1272696,
        zenith_stomp_talent = 1261849,
        spinning_crane_kick = 101546,
        slicing_winds = 1217413,
        hotjs = 443294,                 -- Heart of the Jade Serpent buff
        combo_breaker = 137384,
        dance_of_chi_ji = 325202,
        unbroken_rhythm = 1297033,
        obsidian_spiral = 1249832,
        shadowboxing_treads = 392982,
        restore_balance = 442719,       -- Invoke Xuen: 2 min cooldown
        xuens_bond = 292986,            -- Invoke Xuen: 90 sec cooldown
    },

    -- Spoken by the Suggestion Widget's TTS; names without an entry stay silent.
    tts = {
        tiger_palm = "Palm",
        fists_of_fury = "Fists",
        invoke_xuen = "Xeun",
        celestial_conduit = "Conduit",
        blackout_kick = "Kick",
        spinning_crane_kick = "Spin",
        rising_sun_kick = "Sun",
        rushing_wind_kick = "Wind",
        whirling_dragon_punch = "Dragon",
        zenith = "Zenith",
        zenith_stomp = "Stomp",
    },

    variables = {
        -- Unknown (Xuen never seen cast) counts as not soon.
        { name = "xuen_soon", expr = "timer.xuen.remains<=10" },
        -- Spend from 2 Zenith charges freely; from 1 only if a full recharge
        -- fits before Xuen is back, so Xuen always has a charge with it.
        { name = "safe_zenith", expr = "charges.zenith.full|(charges.zenith>=1&!(timer.xuen.remains<spell.zenith.base_cd))" },
        { name = "hotjs_ending", expr = "buff.hotjs.up&timer.hotjs.remains<=2" },
        -- "Almost over" = not enough time left to spend every Stomp charge (~3s each).
        { name = "zenith_almost_over", expr = "buff.zenith.up&timer.zenith.remains<=counter.stomp*3" },
        { name = "stomp_ready", expr = "talent.zenith_stomp_talent&counter.stomp>0" },
        -- WDP only works once Fists of Fury and the kick are both on cooldown.
        { name = "wdp_usable", expr = "talent.whirling_dragon_punch&!cooldown.fists_of_fury.ready&!cooldown.rising_sun_kick.ready" },
        -- Proc stack counts are secret in combat; dump on time left only.
        { name = "cb_dump", expr = "buff.combo_breaker.up&timer.combo_breaker.remains<=3" },
        { name = "dcj_dump", expr = "buff.dance_of_chi_ji.up&timer.dance_of_chi_ji.remains<=3" },
    },

    timers = {
        { name = "xuen", triggers = {
            { on = "cast", spell = "invoke_xuen", when = "talent.xuens_bond", action = "set", value = "90" },
            { on = "cast", spell = "invoke_xuen", when = "talent.restore_balance", action = "set", value = "120" },
            { on = "cast", spell = "invoke_xuen", when = "spell.invoke_xuen.base_cd>0", action = "set", value = "spell.invoke_xuen.base_cd" },
        } },
        -- The 20s buff window, not the 90s charge recharge.
        { name = "zenith", triggers = {
            { on = "cast", spell = "zenith", action = "set", value = "20" },
            { on = "cast", spell = "zenith_stomp", when = ZENITH_BUILD_OR_EXTEND, action = "set", value = "20" },
        } },
        -- Heart of the Jade Serpent: WDP/Conduit grant a flat 6s; Zenith adds
        -- 4s to a window WDP/Conduit started, otherwise starts a fresh 4s.
        -- hotjs_wdp marks a window whose latest source was WDP/Conduit.
        { name = "hotjs_wdp", triggers = {
            { on = "cast", spell = "whirling_dragon_punch", action = "set", value = "6" },
            { on = "cast", spell = "celestial_conduit", action = "set", value = "6" },
            { on = "cast", spell = "zenith", action = "clear" },
            { on = "cast", spell = "zenith_stomp", when = ZENITH_BUILD_OR_EXTEND, action = "clear" },
        } },
        { name = "hotjs", triggers = {
            { on = "cast", spell = "whirling_dragon_punch", action = "set", value = "6" },
            { on = "cast", spell = "celestial_conduit", action = "set", value = "6" },
            { on = "cast", spell = "zenith", when = "timer.hotjs_wdp.up", action = "add", value = "4" },
            { on = "cast", spell = "zenith", action = "set", value = "4" },
            { on = "cast", spell = "zenith_stomp", when = "(" .. ZENITH_BUILD_OR_EXTEND .. ")&timer.hotjs_wdp.up", action = "add", value = "4" },
            { on = "cast", spell = "zenith_stomp", when = ZENITH_BUILD_OR_EXTEND, action = "set", value = "4" },
        } },
        -- 15s procs. The application moment can't be seen under combat
        -- secrecy, so the clock starts at 13s to flag "almost over" early
        -- rather than miss it. Restarts after each consuming cast.
        { name = "combo_breaker", triggers = {
            { on = "cast", spell = "blackout_kick", action = "clear" },
            { on = "aura_present", spell = "combo_breaker", action = "start", value = "13" },
            { on = "aura_absent", spell = "combo_breaker", action = "clear" },
        } },
        { name = "dance_of_chi_ji", triggers = {
            { on = "cast", spell = "spinning_crane_kick", action = "clear" },
            { on = "aura_present", spell = "dance_of_chi_ji", action = "start", value = "13" },
            { on = "aura_absent", spell = "dance_of_chi_ji", action = "clear" },
        } },
    },

    counters = {
        -- Zenith Stomp's 2 charges live with the Zenith window, not a real
        -- recharge (the spell always reads as ready), so they are counted.
        { name = "stomp", initial = 2, min = 0, max = 2, triggers = {
            { on = "cast", spell = "zenith", action = "set", value = "2" },
            { on = "cast", spell = "zenith_stomp", when = "!timer.zenith.up", action = "set", value = "2" },
            { on = "cast", spell = "zenith_stomp", when = "timer.zenith.remains>2", action = "sub", value = "1" },
        } },
    },

    lists = {
        { name = "ST", prefix = "ST", min = 1, max = 1, entries = {
            { spell = "invoke_xuen", when = "override.invoke_xuen=invoke_xuen" },
            { spell = "zenith", when = "!buff.zenith.up&variable.safe_zenith" },
            { spell = "fists_of_fury", when = "variable.hotjs_ending&usable.fists_of_fury" },
            { spell = "whirling_dragon_punch", when = "!buff.hotjs.up&variable.wdp_usable&!variable.xuen_soon" },
            { spell = "strike_of_the_windlord", when = "!buff.hotjs.up&talent.strike_of_the_windlord&!variable.xuen_soon" },
            { spell = "celestial_conduit", when = "!buff.hotjs.up&override.invoke_xuen=celestial_conduit" },
            { spell = "zenith_stomp", when = "buff.zenith.up&variable.stomp_ready&(resource.chi<=4|variable.zenith_almost_over|channeling.celestial_conduit)" },
            { spell = "tiger_palm", when = "!buff.zenith.up&bloodlust&resource.chi<=4" },
            { spell = "tiger_palm", when = "!usable.fists_of_fury" },
            { spell = "fists_of_fury", when = "usable.fists_of_fury" },
            { spell = "rising_sun_kick", when = "override.rising_sun_kick=rushing_wind_kick" },
            { spell = "blackout_kick", when = "variable.cb_dump" },
            { spell = "spinning_crane_kick", when = "variable.dcj_dump" },
            { spell = "spinning_crane_kick", when = "buff.unbroken_rhythm.up" },
            { spell = "rising_sun_kick", when = "override.rising_sun_kick=rising_sun_kick&!buff.unbroken_rhythm.up" },
            { spell = "blackout_kick", when = "buff.combo_breaker.up|(buff.zenith.up&talent.obsidian_spiral)" },
            { spell = "spinning_crane_kick", when = "buff.zenith.up&(resource.chi>4|buff.dance_of_chi_ji.up)" },
            { spell = "tiger_palm", when = "resource.chi<2" },
            { spell = "tiger_palm", when = "resource.chi<=4&!buff.zenith.up" },
            -- Filler; "never suggest the last cast" makes these alternate.
            { spell = "blackout_kick" },
            { spell = "tiger_palm" },
        } },
        { name = "AOE", prefix = "AOE", min = 2, entries = {
            { spell = "invoke_xuen", when = "override.invoke_xuen=invoke_xuen" },
            { spell = "zenith", when = "!buff.zenith.up&variable.safe_zenith" },
            { spell = "fists_of_fury", when = "variable.hotjs_ending&usable.fists_of_fury" },
            { spell = "whirling_dragon_punch", when = "!buff.hotjs.up&variable.wdp_usable&!variable.xuen_soon" },
            { spell = "strike_of_the_windlord", when = "!buff.hotjs.up&talent.strike_of_the_windlord&!variable.xuen_soon" },
            { spell = "celestial_conduit", when = "!buff.hotjs.up&override.invoke_xuen=celestial_conduit" },
            { spell = "zenith_stomp", when = "buff.zenith.up&variable.stomp_ready&(resource.chi<=4|variable.zenith_almost_over|channeling.celestial_conduit)" },
            { spell = "tiger_palm", when = "!usable.fists_of_fury" },
            { spell = "fists_of_fury", when = "usable.fists_of_fury" },
            { spell = "spinning_crane_kick", when = "buff.unbroken_rhythm.up" },
            { spell = "rising_sun_kick", when = "!cooldown.fists_of_fury.ready" },
            { spell = "rising_sun_kick", when = "override.rising_sun_kick=rushing_wind_kick&!buff.unbroken_rhythm.up" },
            { spell = "rising_sun_kick", when = "override.rising_sun_kick=rising_sun_kick&buff.hotjs.up&!buff.unbroken_rhythm.up" },
            { spell = "blackout_kick", when = "variable.cb_dump" },
            { spell = "spinning_crane_kick", when = "variable.dcj_dump" },
            { spell = "spinning_crane_kick", when = "buff.zenith.up&targets>=5" },
            { spell = "rising_sun_kick", when = "override.rising_sun_kick=rising_sun_kick&(bloodlust|buff.zenith.up)&!buff.unbroken_rhythm.up" },
            { spell = "blackout_kick", when = "talent.obsidian_spiral&buff.zenith.up&!cooldown.rising_sun_kick.ready" },
            { spell = "spinning_crane_kick" },
            { spell = "slicing_winds", when = "talent.slicing_winds" },
            { spell = "blackout_kick", when = "buff.combo_breaker.up" },
            { spell = "tiger_palm", when = "resource.chi<=4&!buff.zenith.up" },
            { spell = "blackout_kick", when = "talent.shadowboxing_treads" },
            { spell = "rising_sun_kick" },
            { spell = "blackout_kick" },
            { spell = "tiger_palm" },
        } },
    },
})
