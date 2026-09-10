# Claude Shepherd — notes for Claude sessions in this repo

Shepherd is a macOS Hammerspoon fleet console for parallel Claude Code sessions. Hooks
(`cc-status.sh`, `cc-approve.sh`, `cc-popup.sh`, helpers in `cc-lib.sh`) write per-session JSON
to `~/.claude/cc-status/`; `claude-dashboard.lua` renders the panel (its HTML/CSS/JS is
embedded) and wires the real effects; `cc-core.lua` holds the pure logic. The code is **Lua
+ bash** — the global TypeScript/Deno defaults don't apply here. Orientation: `context.md`
and the README's "Testing & development" section.

## Architecture rule

- `cc-core.lua` has zero `hs.*` calls. Every effect goes through the `FX` table, so tests
  swap in `tests/support/fx_recorder.lua`. New logic that can be pure goes in `cc-core.lua`
  with tests; `claude-dashboard.lua` only wires it.

## Gate before any merge

- `make lint` (luacheck + `luac -p` + `tests/lint-timers.sh`) and `make test` (every suite)
  are both green — in the worktree, again after rebasing on main, and again on main after
  the merge.

## Deploying — edits don't run until they're deployed

- Hammerspoon runs **copies**: `make install` copies the Lua into `~/.hammerspoon/` and the
  hook scripts into `~/.claude/`; `make deploy` = lint + test + install + reload. A bare
  reload re-runs the stale copy. Changes to the hooks' `settings.json` wiring need
  `make setup` (the full `install.sh`).
- After a deploy, verify the **running** VM with `hs -c` by probing something new in the
  change — the live modules hang off `_G.__ccDashboard`
  (e.g. `hs -c 'return type(_G.__ccDashboard.core.someNewFn)'`, `.fx` for `FX`).
- **Worktrees:** `make install` deploys whichever checkout runs it. Only one worktree deploys
  at a time, and after a merge redeploy from main so the live copy is main. Worktrees live
  at `../claude-instance-manager-<slug>`; TODO.md is gitignored so a worktree's copy never
  blocks `git worktree remove` (`tests/worktree-hygiene.test.sh`).

## Traps that have bitten this repo

- The webview HTML/CSS/JS sits inside a Lua long string (`local HTML = [[ … ]]`). A literal
  `]]` or `[[` anywhere in it — even in a JS comment — ends the string. Use a temp var
  (`var k = a[i]; b[k]`), and run `luac -p claude-dashboard.lua` after editing it.
- The dashboard's main chunk is at Lua's 200-local cap: hang new state and functions on
  `FX` (or inside a `do … end` block), never a new chunk-level `local`.
- Retain every `hs.timer` (assign it); in keystroke chains use the `after()` helper — an
  unretained `hs.timer.doAfter` can be garbage-collected before it fires.
- Every window action (focus, keystrokes, paste) goes through `dispatchSerialized`; every
  item field that reaches `innerHTML` goes through `esc()` (`tests/escaping.test.sh`).
- Status heuristics must be checked on BOTH surfaces: the VS Code extension buffers the
  assistant message (a pending `tool_use` isn't in the transcript until after the tool
  runs); the terminal CLI writes it first.
- When live behaviour contradicts the code, dump the running state with `hs -c` before
  theorising (and compare the Hammerspoon process start time with the deployed files).

## Tests

- Pure logic → `tests/core.test.lua`. Panel wiring → source pins in `tests/ui.test.lua`.
  Shipped panel JS that has to actually run → a node test that extracts the real function
  from `claude-dashboard.lua` (the `tests/done-order.test.js` pattern). Hooks → the bash
  suites (`tests/lib.sh` helpers). New suites get wired into `tests/run.sh`.
- Behaviour-named tests under a dated `-- ---- <topic> (YYYY-MM-DD) ----` banner; a bug
  fixture carries one comment line with the date and the actual cause.
- Log lines keep the file's `[cc-dashboard]` prefix.

## Shipping

- Finished, rebased, green units fast-forward into main. Push main and deploy when Adam
  says ship. No AI attribution in commits.
