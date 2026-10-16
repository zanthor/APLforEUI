# APLforEUI

Standalone WoW addon (Midnight, Interface 120100) by zanthor. Suggests the next
cast from an APL and flags player casts that deviate from it. Moving from a
hard-coded Windwalker Monk APL to user-editable APLs for any spec (plan:
`design.md`). Optional integration with EllesmereUI and the
EllesmereUI Cooldown Manager (`OptionalDeps`), so it must also work without them.

- EllesmereUI dependency: stock release only (no custom build). The APL
  section uses `EllesmereUI.RegisterPlugin`; the CDM glow (`Glow.lua`) finds
  icons through Blizzard's Essential/Utility viewer item frames (which EUI's
  CDM restyles) and draws with `EllesmereUI.Glows`. Follow EUI's rules for
  those frames (EllesmereUICdmHooks.lua): never reparent, rescale, hide or
  show them, never write keys onto them; use our own overlay frames.
- Code (TOC load order): `Core.lua` (shared helpers, `ns.slashCommands`),
  `Expression.lua` (SimC-style parser/compiler), `Engine.lua` (data APL
  runtime: timers, counters, variables, lists; APL selection), `Store.lua`
  (user APLs in saved variables and every editor operation on them; no UI),
  `Exchange.lua` (SimC-style text import/export; format documented at the
  top of the file; no UI),
  `Defaults/*.lua` (built-in APLs as data; no per-spec Lua),
  `Tracking.lua` (cast events, stats, broker), `Editor*.lua` (APL editor:
  Kit = shared controls/state, APLs/Lists/Blocks tabs, Builder = condition
  editor; built from EUI's Macro Factory patterns, public EUI functions only),
  `Widgets.lua`, `Glow.lua`, `Options.lua` (EUI plugin pages), `Slash.lua`.
  Files share state through `ns`, never globals.
- Tests (offline, plain Lua 5.1; `lua.exe` sits next to `luac.exe`; WoW API
  mocks shared in `tests/mock_wow.lua`): `tests/expr_test.lua .` (parser),
  `tests/editor_logic_test.lua .` (formatter, builder forms, store),
  `tests/exchange_test.lua .` (import/export round trip and errors),
  `tests/groups_test.lua .` (list groups: priority, fall-through, openers),
  `tests/holds_test.lua .` (holding cooldowns through Tracking's events),
  `tests/glow_test.lua .` (CDM glow and its settings page),
  `tests/ui_smoke_test.lua .` (every editor page against a recording mock
  EllesmereUI, driven like a user; catches errors, not layout) and
  `tests/parity_sim.lua .` (frozen `tests/legacy_Monk_Windwalker.lua` vs the
  data APL; `EAGER=1` must give 0 mismatches). Keep UI-free logic in
  `Store.lua`/`Engine.lua`/`Expression.lua` so it stays testable. Not deployed.
- Design notes: `design.md` (configurable APL plan), `monkapl.md` (the
  Windwalker APL), `predictive.md` (benched +1 forecaster data). Do not guess spell data; ask the user or
  leave it marked missing.
- Repo: `zanthor/APLforEUI` (public), branch `main`. This is NOT an
  EllesmereUI fork: the EllesmereUI PR workflow and `eui-full-review` skill do
  not apply here, and there is no upstream.

## Code rules

Borrowed from EllesmereUI's CONTRIBUTING so the addon stays compatible with
it and could later be upstreamed:

- Lua 5.1 only (no `goto`/labels). Each file must stay under 200 locals in
  scope and 60 upvalues per function; move helpers onto `ns.` if it nears the cap.
- ASCII only in code, comments and strings (`--` not em dashes). Check with
  `grep -nP '[^\x00-\x7F]' *.lua`.
- Zero cost unless enabled, event-driven, no OnUpdate polling or per-frame
  allocations in hot paths.
- Zero taint: never touch protected frames or call protected functions from
  insecure code; cosmetic `hooksecurefunc` only.
- 12.x secret values: never compare, index or do arithmetic on them; check
  `issecretvalue` first. Secrecy follows the active addon restriction, not
  the content: training-dummy combat already activates `Combat`, with
  cooldowns, auras and Energy secret but Chi and `C_Spell.IsSpellUsable`
  readable (verified in game, 2026-10-15). So dummy tests are valid
  restricted-combat tests; `/apl secrets` shows the live state.
- Use `C_` APIs (`C_Spell`, `C_SpecializationInfo`, `C_Item`), not the
  deprecated globals.
- When EllesmereUI already solves something (cast tracking, cooldown viewer
  lookups, lust detection), mirror its implementation and cite the file in a
  brief comment rather than inventing a new approach.
- Research Blizzard APIs in `../wow-ui-source` or wago.tools only; no code
  copied from other addons.
- Brief comments that explain why, not what; no change history in comments.

## Workflow

- Before committing, run `luac -p` on every Lua file (Lua 5.1 compile check;
  the `LUAC` env var points at it). After moving code between files, also
  check `luac -l -p <file>` for GETGLOBAL/SETGLOBAL names that should have
  been locals or `ns.` fields. Run all tests after any change. Run
  `grep -nE "and (false|nil) or" *.lua`: `x and false or y` never yields
  false in Lua (this has caused four bugs here); write an if/else instead.
  Review the diff against the rules above and say plainly if anything fails.
- Commit messages: `feat: ...` / `fix: ...` style. Ask before pushing.
- Bump `## Version` in the TOC when the user asks for a release.
