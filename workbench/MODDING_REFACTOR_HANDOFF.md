# Petports modder-usability refactor -- handoff

State only. No history, no reasoning, no theories. If a line here is not verified, it says UNTESTED.

## Goals

1. Split the large scripts into one small file per behaviour.
2. Delocalize everything so other mods can override, hijack or wrap it.

Acceptance test: copy the asterite behaviour files, change the variables at the top, patch the copies onto the `scripts` arrays of the `.object` and `.monstertype`, and the pet mines a different matmod.

## Decisions (Lofty, 2026-09-17)

- Behaviours announce themselves through registration points; the hardcoded ladders go.
- Layout: `objects/lofty_petports/petport/work/<behaviour>.lua` (port side), `monsters/lofty_petports/tasks/<behaviour>.lua` (unit side). The big files keep shared plumbing only.
- Every delocalized name takes the `petports_` prefix.
- Every constant moves into `PETPORTS_CONSTANTS.<name>`. Code reads it at the moment of use, never copies it into a local at load.
- Registered callbacks are wrappers that call the global by name at call time (`generate = function() return petports_asteriteWork() end`), so a later script that replaces the global is honoured.
- Modders add scripts by JSON-patching the `scripts` arrays. No `require` edits.
- Line endings: LF. Git already stores LF; a CRLF working copy is converted to LF when a build touches it (no git diff results).

## Port work registry (`petports_petport.lua`)

`PETPORTS_WORK` is a list kept sorted by `order`. API: `petports_registerWork(entry)`, `petports_unregisterWork(name)`, `petports_workEntry(name)`. `petports_findWork()` walks the list; first dispatchable work wins.

Entry fields:

| Field | Meaning |
|---|---|
| `name` | unique; registering the same name replaces the entry |
| `order` | ladder position, ascending; equal orders keep registration order |
| `gate(ctx)` | optional; entry is skipped when it returns false |
| `generate(ctx)` | returns `work, reason, stop`; `stop == true` ends the walk and returns `work, reason` as they are |
| `profile` | portProf phase name; default `"g." .. name`; `false` means not profiled |
| `idleLog` | `{ key, label }`; logs `reason` when it differs from `self[key]` |
| `reasonOrder` | position of `reason` in the no-dispatch text; `true` means use `order`; absent means the reason is not listed |
| `reasonJoin` | entries sharing a key have their reasons joined with `", and "` in one slot |
| `init()` | optional; run from the port's `init()` by `petports_workInit()` |
| `tick(dt)` | optional; run every port update by `petports_workTick(dt)`, profiled as `"tick." .. name` |

`ctx.reasons[name]` holds the reason of every entry that already ran this walk.

Behaviour files load through the `scripts` array of `petports_petport.object`, after `petports_petport.lua`. Currently: `work/asterite.lua`.

Gate helpers: `petports_workGroup(group)`, `petports_workDefrag(group)`, `petports_workFarming(class)`.

Current orders: return 100, fuelGround 200, fuelFetch 300, replant 400, water 500, restock 600, deposit 700, fuelled 800, medic 900, cargoStall 1000, collect 1100, medicPreload 1200, fish 1300, harvest 1400, animal 1500, trap 1600, asterite 1700, withdraw 1800, withdrawWater 1900, restockFetch 2000, fuel 2100, tidy 2200, compact 2300, defrag 2400, sort 2500, drain 2600, diagnostic 2700.

## Asterite footprint (the pilot)

| Piece | File |
|---|---|
| deposit store `petports_asterite*`, `PETPORTS_ASTERITE_MOD`, `PETPORTS_ASTERITE_CLEARED`, local key and cap | `scripts/lofty_petports/petports_work.lua` -- STILL TO MOVE (both contexts use it) |
| latch, scan, dump, `petports_asteriteSocketed()`, `petports_asteriteWork()`, `petports_asteriteInit()`, registration, `FAMILY_HELD.asterite`, `PETPORTS_CONSTANTS.asterite` | `objects/lofty_petports/petport/work/asterite.lua` -- MOVED in 2026-09-18a |
| metric `asteriteDepositsMined` on a done report, and its stats mirror | `petports_petport.lua` -- STILL TO MOVE |
| swing effects, `ASTERITE_*` constants | `petportsTaskAction.lua` |
| arrival branch `task.type == "asterite"` | inside `petportsTaskUpdateInner`; uses only `stateData`, `task`, `dt`, `report`, `publishBeam` |
| reach and probe functions `petports_asteriteReach/SetMod/Damage/Mine` | `petportsTaskAction.lua` |
| pane stat line | `petportconfig.lua` |

## Builds

| Build | Content | State |
|---|---|---|
| 2026-09-17a | `findWork` ladder replaced by `PETPORTS_WORK`; all generators still in place, registered just above `petports_findWork` | offline harness identical over 200,000 scenarios. In game 2026-09-18: stamp seen, no Lua errors, dispatched upcycle, drop, deposit, defrag, animal, restockput, fuel, fish, drain, trap; no-dispatch text intact. Asterite, harvest, replant, water, medic were not exercised |
| 2026-09-18a | asterite port side moved to `work/asterite.lua`; registry `init`/`tick` hooks; delocalized `petports_inNetworkCoverage`, `petports_claimFree`, `petports_targetEligible`, `petports_standingPointForTarget`, `petports_familyOnHold`, `petports_coverageRect` | syntax, balance, free-name check pass. UNTESTED in game |
| next | asterite unit side: `petports_taskArrive[task.type]`, `monsters/lofty_petports/tasks/asterite.lua`, store and shared constants out of `petports_work.lua` | not started |
| after | remaining behaviours, one family per build | not started |
| last | delocalize the remaining shared plumbing (movers, doors, standable search, coarse nav) | not started |

Known difference in 2026-09-18a: the profiler phase `asteriteScan` is now `tick.asterite`.

Known difference in 2026-09-17a: `ground feed idle` is logged as soon as `fuelGround` fails with a new reason. The ladder logged it only when `fuelFetch` also failed to dispatch on the same walk.

## Verification per build

- patch script with exactly-once anchors, refuses to write on any failure
- `texluac -p <file>` (syntax), `petports_luabalance.py`, `petports_localorder.py` compared against `git show HEAD:<file>`
- where code moves to a new file: every free name in the new file must resolve to a global, never to a `local` of the file it left
- where a ladder is replaced: old-versus-new harness under `texlua` with stubbed generators
