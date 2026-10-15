# APLforEUI

Standalone WoW addon (Midnight, Interface 120100) by zanthor. Suggests the next
cast from an APL and flags player casts that deviate from it. Moving from a
hard-coded Windwalker Monk APL to user-editable APLs for any spec (plan:
`design.md`). Optional integration with EllesmereUI and the
EllesmereUI Cooldown Manager (`OptionalDeps`), so it must also work without them.

- Code (TOC load order): `Core.lua` (shared helpers, legacy
  `ns.RegisterSpec` registry, `ns.slashCommands`), `Expression.lua`
  (SimC-style parser/compiler), `Engine.lua` (data APL runtime: timers,
  counters, variables, lists; APL selection; parity mode), `Defaults/*.lua`
  (built-in APLs as data), `Specs/*.lua` (legacy Lua APLs, deleted once
  parity is proven), `Tracking.lua` (cast events, stats, broker),
  `Widgets.lua`, `Glow.lua`, `Options.lua` (EUI plugin pages), `Slash.lua`.
  Files share state through `ns`, never globals.
- Tests (offline, plain Lua 5.1 with mocked WoW API; `lua.exe` sits next to
  `luac.exe`): `tests/expr_test.lua .` (parser) and `tests/parity_sim.lua .`
  (legacy vs data APL; `EAGER=1` must give 0 mismatches). Not deployed.
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
  been locals or `ns.` fields. Run both tests after any engine/APL change.
  Review the diff against the rules above and say plainly if anything fails.
- Commit messages: `feat: ...` / `fix: ...` style. Ask before pushing.
- Bump `## Version` in the TOC when the user asks for a release.
