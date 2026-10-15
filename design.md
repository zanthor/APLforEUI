# APL for EUI: configurable APL design

Goal: replace the hard-coded Windwalker APL with user-editable APLs for any
class/spec, edited in game inside the EllesmereUI plugin section.

## Decisions

| Topic | Decision |
|---|---|
| Sidebar | Plugin section "APL for EUI" with two modules, in order: **APL** (editor), **Widgets** (the former "Settings" module). |
| APLs | Many APLs per account; one active APL per spec (`activeAPL[specID]`). |
| Lists | An APL holds N priority lists, each covering a target-count range (`1`, `2-4`, `5+`). Ranges may not overlap; the editor rejects overlaps. |
| No match | If no list covers the current target count, or no entry in the list matches, show nothing. |
| Conditions | Both a point-and-click builder and a SimC-style text expression (`chi>=3&!buff.zenith.up`). Both edit the same stored condition. |
| Openers | Separate lists that start on entering combat and run for X actions or X seconds. **Later phase.** |
| Combo Strikes | "Never repeat last cast" belongs to the Windwalker spec module only, not a per-APL option. |
| Spec support | Spec modules are written only for supported specs. Monk first; other classes after Monk is done. |
| Import/Export | Wanted. Format still open (see Open items). |
| Saved data | Per account (`APLforEUIDB`). |
| Compliance | Unchanged: "did you press what we suggested", one rolling 60s window across all lists (opener, ST, AOE). |
| Predictive (+1) | Benched. `predictive.md` stays for later. |

## Conditions: two layers

The current rules depend on state the addon tracks itself (HotJS clock,
Zenith Stomp charges, proc expiry timers, Xuen clock), because live values
are secret in real combat. A user cannot build those from generic parts, so:

1. **Generic conditions** for any spec: spell off cooldown, primary resource
   compared to N, buff present (Cooldown Viewer signal, then direct read),
   talent known, target count, last cast, channeling X, bloodlust up.
2. **Spec-module conditions**: named conditions registered by a Lua spec
   module, e.g. `ww.hotjs_ending`, `ww.zenith_almost_over`,
   `ww.stomp_charge`, `ww.safe_zenith_charge`. A spec module also owns its
   cast hooks (the self-tracked clocks) and spec-only rules such as Combo
   Strikes.

Limit to design for: without a spec module, only values that stay readable
in combat are usable (cooldown ready, buff present, primary resources such
as Chi). Exact Energy, buff remaining time and stack counts are not.

## Data model

```lua
APLforEUIDB.apls[id] = {
    name = "Windwalker (default)",
    classID = 10, specID = 269,
    builtin = true,                    -- read-only; duplicate to edit
    lists = {
        { name = "ST",  minTargets = 1, maxTargets = 1,   entries = { ... } },
        { name = "AOE", minTargets = 2, maxTargets = nil, entries = { ... } },  -- nil = no upper bound
    },
}
-- entry
{ spellID = 113656, enabled = true, label = "1", tts = "Fists",
  condition = <stored condition, see below> }

APLforEUIDB.activeAPL[specID] = id
```

- Entries store the **base** spell ID; the engine resolves the live override
  at evaluation time (as `ResolveOverride` does today).
- Stored condition: a parsed tree (`{ op = "and", ... }`), not a string, so
  evaluation never re-parses in combat. The text form is generated from and
  parsed back into the same tree.
- Built-in APLs are shipped in code and never written to saved variables;
  only user copies are.
- Target counting uses a per-spec range spell from the spec module (today
  hard-coded to Tiger Palm).

## Phases

1. **Restructure.** Rename "Settings" to "Widgets", add the APL module stub,
   split the single Lua file by responsibility (Core, Tracking, Widgets,
   Options, Specs/Monk_Windwalker).
2. **Engine.** Data-driven evaluator and condition registry; the Windwalker
   APL converted to a built-in data APL with identical suggestions to the
   hard-coded version. Widgets gate on "current spec has an active APL"
   instead of `IsWindwalker()`.
3. **Editor UI.** APL list (create/duplicate/rename/delete/set active), list
   editor with target ranges, entry editor with condition builder and text
   expression. EUI's widget factory has no text input or reorderable list,
   so those are custom frames styled to match.
4. **Import/Export.**
5. **Openers.** Combat-start lists that run for X actions or X seconds.

## Open items

1. Import/export format: EUI-style profile string, or SimC-style text.
   Recommendation: SimC-style text. The condition text expression already
   needs a SimC-style parser and serializer, so export becomes "print every
   list in that syntax" and import reuses the same parser. It is also
   readable and diffable.
2. Spell/talent IDs for other Monk specs (Brewmaster, Mistweaver) once
   Windwalker is done. Do not guess these; ask.
