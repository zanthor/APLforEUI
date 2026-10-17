# APL for EUI

**A real, configurable action priority list (APL) for World of Warcraft: Midnight, built as an [EllesmereUI](https://github.com/EllesmereGaming/EllesmereUI) plugin.**

APL for EUI is designed to replace the default client's **Assisted Highlight** with a rotation helper that follows a real-world APL. Instead of Blizzard's generic "press this next" hint, it follows a priority list you can see, edit, share and tune for your spec, hero talents and content. It also shows how closely you're following it.

> **Status: 0.9, in active development.** Default APLs exist for only two specs so far:
> - **Windwalker Monk**, Conduit of the Celestials
> - **Beast Mastery Hunter**, Pack Leader
>
> Every other spec works too, but you build its APL yourself with the in-game editor. Data harvesting (below) does most of the groundwork.

---

## What it does

- **Suggests your next cast.** A movable **Suggestion Widget** shows the spell to press, with its icon and the entry label (e.g. `ST3`). It can optionally speak a short name over text-to-speech.
- **Glows the right button.** The suggested spell glows on its Cooldown Manager icon (on by default) and, optionally, on its action bar buttons, including macros that cast it. Both use EUI's own glow styles, set separately, and glow in combat only or always (the cog next to Enabled). If you use the action bar glow, turn off Blizzard's Assisted Highlight so two buttons don't glow at once.
- **Tracks compliance.** A **Status Widget** (and a LibDataBroker feed for EUI DataBars) shows your last 60 seconds: casts, the percentage that matched the suggestion, and broken Combo Strikes for Windwalker.
- **Is fully editable in game.** APLs, lists, entries, conditions, timers, counters and variables are all edited in the EllesmereUI options panel, with no Lua.

## Features

### APLs that work like SimC
- **Groups of lists by target count:** `1`, `2-4`, `5+` and so on. The first active group with a list for the current target count suggests. If that list has nothing ready, the next group gets a turn.
- **Openers and burst windows** are just groups with a condition, e.g. "first 5 casts or 8 seconds of combat" (one click), or "while Bestial Wrath is up".
- **Free casts:** a per-APL list of spells (interrupts, movement, defensives) you can press at any time without lowering compliance. They don't count as ignoring a hold line or as the last cast. The Windwalker default lists its kick, crowd control, movement and defensives.
- **Conditions** can be built **point-and-click** (All / Any / None of these, with is / is-not rows), or typed as **SimC-style text** with autocomplete and live error checking:
  ```
  buff.zenith.up&variable.stomp_ready&(resource.chi<=4|variable.zenith_almost_over)
  ```
- **Timers, counters and variables** cover what the game won't tell you in combat, e.g. "this buff lasts 6 seconds after I cast X". They're configured per APL; nothing is hard-coded per spec.
- **Every entry checks that its spell is actually usable** (resources, requirements, talented), so it never suggests something you can't cast.

### Holding cooldowns
Mark an entry as holdable: "if I ignore this N times in a row, I'm saving it" (N is 3 or more). While a holdable line is the suggestion, its spell glows in a separate **Hold Color**, and the next action down the APL glows normally beside it (turn on **Persistent Hold**, in the cog by the colors, to keep the Hold Color glow on a held spell until you use it). Press that next action twice in a row and the cooldown is held, without waiting for N ignores (the first press doesn't hold it on its own, so a press already on its way when the cooldown came up never holds it by accident). Otherwise, after N ignores the APL stops suggesting it and suggests what to do instead. Other entries can react to `holding`. Your compliance score isn't penalised for the deliberate hold, and a green `*` on the Status Widget shows a cooldown is being held.

### Import and export
APLs export as readable SimC-style text, so you can paste them in Discord, keep them in a gist, or diff two versions:
```
group.opener=Opener
group.opener.prefix=OP
group.opener.if=combat.casts<7&combat.time<12
actions.st+=/barbed_shot,if=charges.barbed_shot.full|variable.bw_soon
```
Importing always adds a new APL; it never overwrites one.

### Data harvesting
Building an APL for a new spec starts with finding spell and buff IDs. Switch on **Harvest Data**, play normally (cast each ability, then let combat drop), and the addon collects:
- your Cooldown Manager entries;
- your class and spec spellbook;
- your active talents, including the hero tree;
- your casts;
- your buffs, with their durations and what caused them.

The **Discovered** section then adds any of it to your APL in one click. Buffs with a known cause can be added as a ready-made timer.

## Requirements

- **World of Warcraft: Midnight** (Interface 120100).
- **[EllesmereUI](https://github.com/EllesmereGaming/EllesmereUI)**, the standard release; no custom build is needed. The APL editor and all settings live in the EllesmereUI options panel.
- **EllesmereUI Cooldown Manager**, for the icon glow and for reading buffs in combat (see below).

## Getting started

1. Install the addon, `/reload`, and open EllesmereUI's options. **APL for EUI** has its own section in the sidebar.
2. **Glows:** set the glow style for the Cooldown Manager and, if you want it, switch on the action bar glow.
3. **Widgets:** enable the **Suggestion Widget** and/or **Status Widget**. Hold Shift and drag a widget to move it.
4. **APL:** if your spec has a built-in APL it's already running. Built-ins are read-only; click **Duplicate to Edit** to make your own copy.
5. **Track the buffs your APL uses in the Cooldown Manager.** The defaults list theirs at the top of their files, e.g. Howl of the Pack Leader, Nature's Ally, Beast Cleave and Cobra Fang for Beast Mastery.

## How it copes with combat secrecy

In Midnight, much of the game's combat data is **secret** to addons during restricted combat, including dungeons, raids and even training-dummy fights. That covers cooldown timers, buff durations and stack counts, and resources such as Energy. APL for EUI only uses what stays readable and fills the gaps itself:

- **Yes/no signals** for cooldowns, charges and "can I cast this", plus Chi and similar resources.
- **Buffs through the Cooldown Manager.** Blizzard's Cooldown Manager can still show which buffs are active, so **a buff must be tracked there** for an APL to see it in combat.
- **Self-tracked timers and counters** for everything else, started from your casts (which stay readable).
- **Enemies in combat within your range spell** for the target count.

Some guide lines can't be expressed exactly and are approximated. Each default APL lists its approximations at the top of its file in [`Defaults/`](Defaults/).

## Slash commands

| Command | What it does |
|---|---|
| `/apl options` | Open the APL for EUI settings |
| `/apl` | Toggle cast tracking on/off |
| `/apl expr <expression>` | Evaluate any condition right now, e.g. `/apl expr charges.barbed_shot` |
| `/apl debug <label>` | Speak (TTS) whenever entry `<label>` is suggested; `/apl debug clear` to stop |
| `/apl secrets` | Show which addon restrictions are active and what is secret |
| `/apl cdm` | List the Cooldown Manager icons the glow can see |
| `/apl glow` | Diagnose the glows (Cooldown Manager and action bars) |
| `/apl melee` | Show what the target count sees, per nameplate |
| `/apl chat` | Toggle per-cast debug output in chat |

## Contributing a default APL

Default APLs are plain data files in [`Defaults/`](Defaults/). The usual path:
1. Build and tune the APL in game.
2. Run **Harvest Data** for the spec and **Export Harvest**, so every spell and buff ID comes from the game rather than being guessed.
3. Export the APL.
4. Open an issue or PR with both exports and the guide you followed.

Please don't guess spell IDs. Midnight has many spells that share a name but use different IDs for the spell, its buff and its talent.

## Development

- Pure Lua 5.1, ASCII only, no libraries bundled. LibDataBroker is used if present.
- Offline tests run with a plain Lua 5.1 interpreter against a mocked WoW API, for example:
  ```
  lua tests/expr_test.lua .
  lua tests/bm_test.lua .
  EAGER=1 lua tests/parity_sim.lua .
  ```
  The other suites in [`tests/`](tests/) run the same way: `ui_smoke_test`, `editor_logic_test`, `exchange_test`, `groups_test`, `holds_test`, `glow_test` and `harvest_test`.
- Design notes and decisions: [`design.md`](design.md).

## Author and license

zanthor. Released under the [MIT License](LICENSE).
