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
| Combo Strikes | Generic APL option "never suggest the last cast"; only the Windwalker APL turns it on. |
| Spec support | A spec is "supported" when we ship a default APL for it. Monk first; other classes after Monk is done. No Lua per spec: everything is configuration (below). The Lua spec registry stays only as a fallback for anything that truly cannot be modelled, and is expected to stay empty. |
| Shipped defaults | Default APLs, plus a library of ready-made timers, counters and variables (as we sort them out) that the editor copies into an APL. Copies, not references, so an APL stays self-contained. |
| Import/Export | Wanted. Format still open (see Open items). |
| Saved data | Per account (`APLforEUIDB`). |
| Compliance | Unchanged: "did you press what we suggested", one rolling 60s window across all lists (opener, ST, AOE). |
| Predictive (+1) | Benched. `predictive.md` stays for later. |

## Conditions: building blocks

Every special case in the old Windwalker code is one of a few generic
patterns, configured per APL. Nothing is spec-specific Lua.

### Expressions

SimC-style: `&` `|` `!`, `=` `!=` `<` `<=` `>` `>=`, `+ - * /`, parentheses,
`max(a,b)`, `min(a,b)`. Every value is a number (true = 1, false = 0) or
**unknown** (nil). Comparisons with an unknown are false, arithmetic with an
unknown is unknown, so "never seen" never accidentally reads as 0.
Precedence: `!` and unary `-` bind tightest, then `* /`, `+ -`,
comparisons, `&`, `|` (write `!(a<=b)`, not `!a<=b`).

### Live reads (no setup)

| Read | Meaning |
|---|---|
| `cooldown.X.ready` | Off cooldown (GCD ignored). Checks the button's current form (override). |
| `charges.X`, `charges.X.full` | 0 / 1 / max from non-secret flags (exact for up to 2 charges). Exact spell X. |
| `usable.X` | `C_Spell.IsSpellUsable` (resources, etc.). Current form. Not flagged secret in the API docs; to be confirmed in combat. |
| `spell.X.base_cd` | Static base cooldown in seconds. |
| `buff.X.up` | Cooldown Viewer signal, then direct read. |
| `talent.X` | Known/talented. |
| `override.X` | Spell ID X currently turns into (compare with a name: `override.invoke_xuen=celestial_conduit`). |
| `prev.X` | Last cast was X. |
| `channeling.X` | Currently channeling X. |
| `resource.<power>` | `UnitPower` for any `Enum.PowerType` (`resource.chi`); unknown if secret. |
| `targets` | Enemies in range of the APL's range spell. |
| `bloodlust` | Any lust buff up. |
| `X` | A bare name is that spell's ID. |

### Timers

Named clock. `timer.T.up`, `timer.T.remains` (unknown until first started).
Triggers, each with an optional guard condition:

- **On:** `cast` of spell X, `aura_present` / `aura_absent` of buff X
  (checked on every player `UNIT_AURA`).
- **Action:** `set d` (overwrite), `start d` (only if not running/cleared),
  `add d` (extend if running, else start), `clear`.
- **Value:** an expression (`90`, `spell.invoke_xuen.base_cd`).

### Counters

Named number with `initial`, `min`, `max`. `counter.C`. Same triggers;
actions `set n`, `add n`, `sub n`, `reset` (back to initial).

### Trigger rules

On each event, every tracker picks its **first** matching trigger, with
all guards and values evaluated against the state **before** the event;
then all picked actions apply. This is what lets one spell ID mean
different things by state (Zenith build / extend / Stomp spend).

### Variables

Named expressions per APL, `variable.V`, computed at most once per
evaluation. A variable may only use variables defined above it (no cycles).

### Entry rules

An entry fires when: it is enabled, its spell (resolved to the current
override) is off cooldown, it is not the last cast (if the APL option is
on), and its condition is true. The suggestion is the resolved spell.

### Windwalker mapped onto these

| Old Lua | Configuration |
|---|---|
| Xuen cooldown clock | Timer `xuen`: on cast Xuen, `set 90` if Xuen's Bond, else `set 120` if Restore Balance, else `set spell.invoke_xuen.base_cd` |
| HotJS clock | Timer `hotjs`: WDP/Conduit `set 6`; Zenith build `add 4` |
| Zenith buff 20s | Timer `zenith`: cast Zenith, or Stomp ID when `!timer.zenith.up \| timer.zenith.remains<=2`: `set 20` |
| Stomp charges | Counter `stomp` (0-2): Zenith build `set 2`; Stomp ID when `timer.zenith.remains>2`: `sub 1` |
| Proc expiry | Timer per proc: `aura_present` `start 13`, `aura_absent` `clear`, consuming cast `clear` |
| Fists cost | `variable.fof_cost = max(1,3-buff.zenith.up-talent.harmonic_combo)` (or `usable.fists_of_fury` once confirmed) |
| Combo Strikes | APL option |

## Data model

```lua
{
    id = "builtin:monk_windwalker", name = "Windwalker (default)",
    specID = 269, builtin = true,             -- read-only; duplicate to edit
    options = { noRepeatLastCast = true, rangeSpell = "tiger_palm" },
    names = { tiger_palm = 100780, fists_of_fury = 113656, ... },
    variables = { { name = "fof_cost", expr = "max(1,3-buff.zenith.up-talent.harmonic_combo)" }, ... },
    timers = { { name = "xuen", triggers = {
        { on = "cast", spell = "invoke_xuen", when = "talent.xuens_bond", action = "set", value = "90" }, ... } } },
    counters = { { name = "stomp", initial = 2, min = 0, max = 2, triggers = { ... } } },
    lists = {
        { name = "ST",  min = 1, max = 1,   entries = { { spell = "fists_of_fury", label = "1", when = "..." }, ... } },
        { name = "AOE", min = 2, max = nil, entries = { ... } },   -- nil max = no upper bound
    },
}
APLforEUIDB.apls[id] = <user APL>;  APLforEUIDB.activeAPL[specID] = id
```

- Conditions are stored as **text** and compiled once (on load or edit) into
  closures, so nothing is parsed in combat. The point-and-click builder
  edits a tree that serializes to the same text; export is the same text.
- List choice uses `max(1, targets)`, so "no enemies" still picks the
  single-target list.
- Built-in APLs live in code (`Defaults/`) and are never written to saved
  variables; only user copies are.

## Phases

1. **Restructure.** DONE.
2. **Engine.** Expression parser/compiler, timers/counters/variables,
   data-driven evaluator, Windwalker as a built-in data APL. Parity mode:
   the old Lua APL keeps driving while the data APL runs alongside and
   logs every disagreement (`/apl parity`); `/apl engine new` switches
   which one drives. Once parity is clean, delete `Specs/Monk_Windwalker.lua`.
3. **Editor UI.** APL list (create/duplicate/rename/delete/set active), list
   editor with target ranges, entry editor with condition builder and text
   expression, names/timers/counters/variables editors, shipped library.
   EUI's widget factory has no text input or reorderable list, so those are
   custom frames styled to match.
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
