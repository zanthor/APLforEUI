## Opener (AOE & ST -- not part of the live suggestion widget)
1. Trinket/Potion (Missing)
2. Tiger Palm (Missing)
3. Invoke Xuen, the White Tiger
4. Zenith -- always reserve 1 charge for Xuen

The opener sets the stage to enter the following APL.

## Single Target APL
1. Fists of Fury if HotJS < 2s
2. Whirling Dragon Punch if no HotJS and Invoke Xuen > 10s
3. Strike of the Windlord if no HotJS and Invoke Xuen > 10s (Missing)
4. Conduit if no HotJS
5. Zenith if no Zenith Buff -- always reserve 1 charge for Xuen
6. Zenith Stomp if low on Chi or Zenith Buff is below 3s per charge or inside Celestial Conduit Channel
7. Tiger Palm if no Zenith Buff AND Bloodlust Buff AND <= 4 Chi (Missing)
8. Tiger Palm if not enough Chi to cast Fists of Fury
9. Fists of Fury
10. Rushing Wind Kick (with or without Unbroken Rhythm)
11. Blackout Kick with < 3 seconds left on Combo Breaker (137384) -- stack count not currently trackable in combat, see open item 8
12. Spinning Crane Kick with < 3 seconds left on Dance of Chi-Ji (325202) -- stack count not currently trackable in combat, see open item 8
13. Spinning Crane Kick with Unbroken Rhythm
14. Rising Sun Kick without Unbroken Rhythm
15. Blackout Kick with Combo Breaker OR with Zenith Buff and talented into Obsidian Spiral
16. Spinning Crane Kick with Zenith Buff and > 4 Chi OR Dance of Chi-Ji
17. Tiger Palm if < 2 Chi
18. Tiger Palm if <= 4 Chi and no Zenith Buff (Missing)
19. Blackout Kick (filler, alternates with Tiger Palm)

## AOE APL (2+ melee targets)
1. Fists of Fury if HotJS < 2s
2. Whirling Dragon Punch if no HotJS and Invoke Xuen > 10s
3. Strike of the Windlord if no HotJS and Invoke Xuen > 10s
4. Conduit if no HotJS (Missing)
5. Zenith if no Zenith Buff -- always reserve 1 charge for Xuen
6. Zenith Stomp if low on Chi or Zenith Buff  is below 3s per charge or inside Celestial Conduit Channel
7. Tiger Palm if not enough Chi to cast Fists of Fury
8. Fists of Fury
9. Spinning Crane Kick with Unbroken Rhythm
10. Rising Sun Kick/Rushing Wind Kick if it will activate Whirling Dragon Punch
11. Rushing Wind Kick without Unbroken Rhythm
12. Rising Sun Kick with HotJS without Unbroken Rhythm
13. Blackout Kick with < 3 seconds left on Combo Breaker (137384) -- stack count not currently trackable in combat, see open item 8
14. Spinning Crane Kick with < 3 seconds left on Dance of Chi-Ji (325202) -- stack count not currently trackable in combat, see open item 8
15. Spinning Crane Kick with Zenith Buff and >= 5 targets
16. Rising Sun Kick with Bloodlust OR Zenith Buff without Unbroken Rhythm
17. Blackout Kick with Obsidian Spiral talented, during Zenith, with Rising Sun Kick on cooldown
18. Spinning Crane Kick
19. Slicing Winds if talented
20. Blackout Kick with Combo Breaker
21. Tiger Palm if <= 4 Chi and no Zenith Buff
22. Blackout Kick with Shadowboxing Treads talented
23. Rising Sun Kick
24. Blackout Kick (filler, alternates with Tiger Palm)

## Open items before implementation
1. Opener steps 1-2 (Trinket/Potion, Tiger Palm) are new -- only Invoke Xuen/Zenith (steps 3-4) exist in code today, tagged O1/O2. - This doesn't need displayed in any fashion at all.  I just documented it here for my sanity.
2. DONE. FoF-vs-HotJS timing is "< 2s", self-tracked off observed casts (direct aura/timing reads confirmed secret even through Blizzard's own linked-aura resolution). Heart of the Jade Serpent has 3 sources with different durations: Zenith (4s, 1238904), Whirling Dragon Punch (6s, 443421), Celestial Conduit (6s, 443616). WDP/Conduit always overwrite the window to a flat 6s; Zenith extends (+4s) a currently active WDP/Conduit window, otherwise starts fresh at 4s. Presence ("is HotJS up") still reads the existing CDM-based HasHeartOfJadeSerpent() (443294) unchanged.
3. DONE. ST step 3 (Strike of the Windlord) added.
4. DONE. AOE step 4 (Conduit) added; AOE's Zenith Stomp (step 6) now also checks "or inside Celestial Conduit Channel".
5. DONE. ST steps 7 and 16 (the two new Tiger Palm rules) implemented.
6. AOE step 17 (Blackout Kick / Obsidian Spiral / Zenith / RSK-on-cooldown) is confirmed correct and already implemented (AOE step A14 in code) -- no change needed.
7. The "without Unbroken Rhythm" qualifiers on several AOE steps are confirmed intentional, matching current code.
8. DONE (time-only). ST steps 11-12 / AOE steps 13-14 (Combo Breaker / Dance of Chi-Ji) are implemented as a TIME-ONLY trigger (<3s left on the buff) -- the "2 stacks" half of the original rule was dropped. CONFIRMED via live testing (crash log with full secret-value locals dump) that stack count cannot be read or tracked in real combat by any currently-known addon API: aura instance ID, applications count, and even the UNIT_AURA event's own updatedAuraInstanceIDs list all read as secret values, and comparing them (even just `==`) hard-errors. Only presence (is the buff up at all, via IsShown()) is safely readable -- that doesn't distinguish 1 stack from 2. The self-tracked expiry clock also can't know the true application moment, so it starts at (15s duration - 2s) instead of a fresh 15s, biasing toward flagging "almost over" a little early rather than risking missing the window. Should reconsider counting stacks again if a safe detection method is ever found -- the underlying stacks field/consumption tracking (ConsumeProcStack) was deliberately left in place for that.
9. DONE. Dance of Chi-Ji's spell ID confirmed: 325202 is the buff (per CDM tooltip), 325201 is the talent -- code constant DANCE_OF_CHI_JI_BUFF corrected from 325201 to 325202.





