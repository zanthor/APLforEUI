# APL for EUI: configurable APL design

Goal: replace the hard-coded Windwalker APL with user-editable APLs for any
class/spec, edited in game inside the EllesmereUI plugin section.

## Decisions

| Topic | Decision |
|---|---|
| Sidebar | Plugin section "APL for EUI" with two modules, in order: **APL** (editor), **Widgets** (the former "Settings" module). |
| APLs | Many APLs per account; one active APL per spec (`activeAPL[specID]`). |
| Lists | An APL holds N priority lists, each covering a target-count range (`1`, `2-4`, `5+`). Ranges may not overlap within a group; the editor rejects overlaps. Phase 5 puts lists into prioritized **groups** (see below). |
| No match | If no list covers the current target count, or no entry in the list matches, show nothing. Phase 5: an active group with nothing to suggest falls through to the next group; only after the last group does it show nothing. |
| Conditions | Both a point-and-click builder and a SimC-style text expression (`chi>=3&!buff.zenith.up`). Both edit the same stored condition. |
| Openers | N opener list sets (ST/AOE like any other). Phase 5 models them as groups whose condition is "early in combat". |
| Burst / conditional lists | List sets that take priority while a condition holds (e.g. Courage of the White Tiger or HotJS up). Phase 5, same mechanism as openers. |
| Holding cooldowns | An entry can be marked holdable: ignoring it for X casts sets a "holding" state that conditions can read; casting it (or leaving combat) clears it. Phase 6. |
| Combo Strikes | Generic APL option "never suggest the last cast"; only the Windwalker APL turns it on. |
| Spec support | A spec is "supported" when we ship a default APL for it. Monk first; other classes after Monk is done. No Lua per spec: everything is configuration (below). The Lua spec registry was removed once Windwalker reached parity; re-add a hook only if something truly cannot be modelled. |
| Shipped defaults | Default APLs, plus a library of ready-made timers, counters and variables (as we sort them out) that the editor copies into an APL. Copies, not references, so an APL stays self-contained. |
| Import/Export | Wanted. Format still open (see Open items). |
| Saved data | Per account (`APLforEUIDB`). |
| Compliance | Unchanged: "did you press what we suggested", one rolling 60s window across all lists (opener, ST, AOE). |
| Predictive (+1) | Benched. `predictive.md` stays for later. |
| EUI dependency | Stock EllesmereUI only. The CDM glow finds the suggested spell's icon among Blizzard's Essential/Utility viewer item frames (EUI's CDM restyles those; IDs verified readable in restricted combat) and draws with `EllesmereUI.Glows`, restriction-safe styles only. Settings: Widgets > CDM Glow. Icons EUI adds itself (outside Blizzard's tracked set) can't glow. |

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
| `usable.X` | `C_Spell.IsSpellUsable` (resources, etc.). Current form. Confirmed readable under the `Combat` restriction (cooldowns/auras/Energy secret at the same time). The way to check resource costs for specs whose resource is secret. |
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
override) is off cooldown and usable (`C_Spell.IsSpellUsable`: resources,
requirements, talented; an entry can opt out with "Only When Usable" off),
it is not the last cast (if the APL option is on), and its condition is
true. The suggestion is the resolved spell. An unknown/secret usable value
never blocks an entry.

### Windwalker mapped onto these

| Old Lua | Configuration |
|---|---|
| Xuen cooldown clock | Timer `xuen`: on cast Xuen, `set 90` if Xuen's Bond, else `set 120` if Restore Balance, else `set spell.invoke_xuen.base_cd` |
| HotJS clock | Timer `hotjs`: WDP/Conduit `set 6`; Zenith build `add 4` |
| Zenith buff 20s | Timer `zenith`: cast Zenith, or Stomp ID when `!timer.zenith.up \| timer.zenith.remains<=2`: `set 20` |
| Stomp charges | Counter `stomp` (0-2): Zenith build `set 2`; Stomp ID when `timer.zenith.remains>2`: `sub 1` |
| Proc expiry | Timer per proc: `aura_present` `start 13`, `aura_absent` `clear`, consuming cast `clear` |
| Fists cost | `usable.fists_of_fury` (matched the hand-written cost rule in both directions in game) |
| Combo Strikes | APL option |

## Data model

```lua
{
    id = "builtin:monk_windwalker", name = "Windwalker (default)",
    specID = 269, builtin = true,             -- read-only; duplicate to edit
    options = { noRepeatLastCast = true, rangeSpell = "tiger_palm" },
    names = { tiger_palm = 100780, fists_of_fury = 113656, ... },
    tts = { fists_of_fury = "Fists", ... },   -- spoken by the Suggestion Widget
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
2. **Engine.** DONE. Expression parser/compiler, timers/counters/
   variables, data-driven evaluator, Windwalker as a built-in data APL.
   Parity confirmed offline and in game; the Lua version now lives only in
   `tests/` as the parity reference. Status widget shows the running
   list's name.
3. **Editor UI.** DONE, except the shipped library: APLs / Lists /
   Building Blocks tabs, condition builder and text editor, Problems list.
   Still to do: the library of ready-made timers, counters and variables
   that the editor copies into an APL (decided earlier; nothing to put in
   it beyond Windwalker yet).
4. **Import/Export.** DONE. SimC-style text (format in `Exchange.lua`);
   import always adds a new APL, never replaces one.
5. **List groups: openers and conditional lists.** DONE. See "Phase 5" below.
6. **Holding cooldowns.** DONE. See "Phase 6" below.

## Phase 5: list groups (openers, burst windows)

Openers and burst windows are the same idea: a set of ST/AOE lists that
takes priority while a condition holds. So lists move into **groups**:

```lua
groups = {
    { name = "Opener", when = "combat.casts<5&combat.time<8", lists = { ST, AOE } },
    { name = "Burst",  when = "buff.courage_of_the_white_tiger.up|buff.hotjs.up", lists = { ST } },
    { name = "Default", lists = { ST, AOE } },   -- no condition: always
}
```

- **Selection:** walk groups top to bottom. A group applies when its
  condition is true and one of its lists covers the target count; that
  list is evaluated. If it suggests nothing, fall through to the next group.
  After the last group: nothing.
- **Ranges** may not overlap *within* a group; different groups can each
  have their own ST and AOE lists.
- **New reads:** `combat.time` (seconds since entering combat) and
  `combat.casts` (casts reported since entering combat). Both read 0 out of
  combat, so an opener group already shows before the pull; counting starts
  fresh on entering combat, so pre-pull casts (mounting, food) never use it
  up. An opener is just a group using them; the editor's "Use Opener
  Preset" fills in `combat.casts<5&combat.time<8`.
- **Broken conditions:** a group whose condition doesn't compile is
  skipped (and listed under Problems), never treated as always active.
- **Labels:** widgets show prefixes, never names (names are for the
  editor). Groups and lists each have a required 1-3 character prefix.
  Entries: list prefix + position (`OST3`, `ST9`); a list prefix used twice
  is reported under Problems. Status widget: "<group prefix>-<list prefix>"
  (`OP-OST`, `DEF-AOE`). Groups saved or imported without a prefix get one
  from their name ("Default" -> `DEF`).
- **Migration:** an APL's existing `lists` become one group "Default" with
  no condition. Saved user APLs are converted on load; export moves to
  `format=2` (`group.<key>=<name>`, `group.<key>.if=...`, lists name their
  group); format 1 text still imports as a single Default group.
- **Editor:** the Lists tab shows groups (name, condition, order) with their
  lists nested inside.

## Phase 6: holding cooldowns

The APL can't know you are saving a cooldown for a burst window. Instead it
notices you skipping one:

- An entry can be marked **holdable** with a threshold N ("held after
  ignoring it N times").
- **Ignored** = the entry was the suggestion when you cast something else.
  At N, that spell becomes **held**.
- While held, the entry is skipped (the APL suggests what comes next), and
  conditions can read `holding` (anything held) or `holding.<name>` (that
  spell). A "Holding" group (phase 5) can use it too.
- **Cleared** when the held spell is cast, or when combat ends.
- **Counting** is consecutive: casting the spell, or a cast while it wasn't
  the suggestion, resets it.
- **Compliance:** the N ignored casts are re-scored as compliant once the
  spell becomes held.
- **Display:** the compliance % on the status widget and broker gets a
  prefix: none for 0-1 consecutive ignores, yellow `*` from 2 ignores until
  held, green `*` while anything is held.
- **Data:** an entry's `hold = N` (export `,hold=N`); editor field "Hold
  After Ignored Casts" (empty = never). Only in-combat casts count; the
  state lives in the APL runtime and resets on leaving combat, on a reload,
  and when the APL is edited.

## Editor (phase 3)

| Topic | Decision |
|---|---|
| Layout | Fixed header with an APL picker over three tabs: **APLs** (manage), **Lists** (lists and entries), **Building blocks** (names, variables, timers, counters, TTS, options). Accordion rows (header: label, up/down, on/off, delete; click to expand), mirroring EUI's Macro Factory page. |
| Scope | Defaults to the current spec's APLs; the picker can switch to any spec. Active choice stays per spec. |
| Built-ins | Read-only; "Duplicate to edit" makes a user copy. |
| Saving | Edits write straight to saved variables and recompile the APL; no Save button (the panel cannot open in combat). |
| Spell names | Typing a spell name or ID in an entry auto-creates its short name (Fists of Fury -> `fists_of_fury`) if the APL doesn't have one. |
| Labels | Each list has a required 1-3 character **prefix**; an entry's label is prefix + its position in the list (`ST3`, `AOE12`), renumbering on reorder. No free-text labels. |
| Conditions | Text box with autocomplete and live validation, **and** a point-and-click builder, both built now. The builder edits AND/OR groups of `[!] read [op value]` rows; text that doesn't fit that shape (arithmetic, `max()`) stays text-only and the builder says so. Both views edit the same stored text. |

## Open items

1. DONE: import/export uses SimC-style text.
2. Spell/talent IDs for other Monk specs (Brewmaster, Mistweaver) once
   Windwalker is done. Do not guess these; ask.
3. DONE (decided): Phase 5 falls through to the next group when the active
   group's list suggests nothing.
4. DONE (decided): Phase 6 counts **consecutive** ignores; casting the spell,
   or a cast while it wasn't the suggestion, resets the count.
5. DONE (decided): the N ignored casts are **forgiven** in the compliance
   stats once the spell becomes held.
6. DONE (decided): a held entry is **skipped** until the hold clears.
