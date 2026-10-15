# Data needed for the predictive (+1) suggestion forecaster

Goal: simulate "if the suggested spell gets cast, what will the APL suggest
next" using known cause-and-effect (chi, buffs, cooldowns), not a live
re-read after the fact. Everything below is real game-design data this
addon doesn't currently have hardcoded -- please fill in actual values
(tooltip/testing-verified), don't let me guess.

## 1. Chi cost / generation per spell

Positive = generates Chi, negative = costs Chi. Leave blank/"?" for anything
you're not sure of rather than guessing.

| Spell | ID | Chi cost/gain |
|---|---|---|
| Tiger Palm | 100780 | ? |
| Blackout Kick | 100784 | ? |
| Rising Sun Kick | 107428 | ? |
| Rushing Wind Kick | 467307 | ? |
| Spinning Crane Kick | 101546 | ? (flat, or per-target?) |
| Whirling Dragon Punch | 152175 | ? |
| Strike of the Windlord | 392983 | ? |
| Zenith | 1249625 | ? |
| Zenith Stomp | 1272696 | ? |
| Celestial Conduit | 443028 | ? (channeled -- cost/gain per tick, or flat on cast?) |
| Slicing Winds | 1217413 | ? |

Fists of Fury (113656) is already handled dynamically via `GetFistsOfFuryCost()`
(base 3, -1 with the Zenith buff, -1 with Harmonic Combo talent 1250041,
floor of 1) -- no new data needed there.

## 2. Buff-consumption rules

For each buff below, which spell(s) consume it when cast, if any? (i.e. "is
this buff gone immediately after casting X, assuming X's priority rule was
specifically gated on this buff being up")

| Buff | ID | Consumed by which cast(s)? |
|---|---|---|
| Combo Breaker | 137384 | ? (Blackout Kick, per step 13/A18?) |
| Heart of the Jade Serpent | 443294 | ? (Fists of Fury, per step 1/A1?) |
| Dance of Chi-Ji | 325201 | ? (Spinning Crane Kick, per step 14?) |
| Unbroken Rhythm | 1297033 | ? (Rushing Wind Kick / Spinning Crane Kick, per step 10/11?) |
| Zenith (buff) | 1249625 | ? (does Zenith Stomp consume/end it, or does it just run its own 20s timer regardless of Stomp casts?) |

## 3. Known limitation (no data needed, just confirming)

Combo Breaker and Dance of Chi-Ji are RNG procs with no way to know in
advance whether they'll be up for a future evaluation. The simulator will
assume "no new proc" for any branch gated on one of these -- predictions
through those branches will sometimes be wrong, and that's an accepted
accuracy ceiling, not a bug to chase.

## 4. Not needed from you (handled automatically)

- GCD duration for advancing self-tracked clocks by one step: read live via
  the standard non-secret "GCD spell" trick (`C_Spell.GetSpellCooldown(61304)`),
  not asked here.
- Cooldown/charge state transitions for non-charge and charge spells: already
  computable from existing `IsOffCooldown`/charge-tracking logic.
