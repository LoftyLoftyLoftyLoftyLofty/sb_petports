# COARSE NAV -- SESSION HANDOFF (as of taskAction 06d / coarsenav 07h)

Read this before proposing anything. MEASURED means read out of a
starbound.log or an engine `.luaprofile`; FACT means read out of retail 1.4.4
source pasted into a session. Retail Starbound 1.4.4 only; never propose an
OpenStarbound or fork binding. The OpenStarbound repo's first commit is
unmodified retail source and may be READ for facts (StarLuaRoot.cpp was).

Builds in play, all tested in game:
`petports_coarsenav.lua` **2026-09-07h**, `petportsTaskAction.lua`
**2026-09-06d**, `petports_flyapproach.lua` **2026-09-06b**,
`petports_contract.lua` **2026-09-06a**, `petports_petport.lua` **2026-09-07a**.

**STATE.** Walkers and flyers route end to end; a walker retrieved and
deposited across the base, a flyer surveyed the whole ship. Performance work
is DONE for now: no LuaInstructionLimitReached, 12 updates/s, tick max ~75 ms
on the test laptop, and the engine profile shows our remaining cost is the
survey itself under a per-update cap, not bookkeeping. This is the starting
point for the actual feature work, not the end of anything.

**THE TEST MACHINE IS AN HP PROBOOK 440 G5.** Every budget below is tuned so
the survey is tolerable there. That is the pass criterion; a server has
headroom, and a future network budget should expose these constants rather
than a future session loosening them against a faster box.

---

## HOW TO WORK ON THIS

- Read the log before proposing a fix. Every fix in these two days came from a
  grep or a profile; every guess made before one was wrong, including "the
  garbage collector" (twice), which an instruction-limit error falsified.
- One change, one stamp, one log. `petports_navWipe()` only for a store
  change: anchor rule, cell key meaning, verdict meaning, index entry format,
  coverage rule. A profile-string change re-buckets on its own.
- **Profile, do not guess.** Two instruments:
  1. Ours: `PETPORTS_PROFILE = true` prints `PROFILE 5.0s | tick max | heap |
     <sections> | survey: <counters> | world/s: <call counts>` every 5 s per
     unit. Sections: update, navTick, candidates, sweepStart, sweepStep,
     neighbours, probeStep, reaches, flush, purge, graphFor, draw, freeMover.
     Counters: sweeps, sweepR<n>, true1/trueN/false/tooLong/sweepTrue/
     sweepFalse (+Ticks), edgesFlushed, budgetCut, stepCap, graphBuildStart/
     Done. `os.clock` IS available; `collectgarbage` IS NOT.
  2. The engine's: `"scriptProfilingEnabled" : true` in `storage/starbound.config`
     (not patchable as an asset; per-user only, never a release setting).
     Writes `storage/lua/<time>.luaprofile` per Lua root on a clean quit:
     world server, client, item-build. Read the world-server one: our unit is
     under `/monsters/pets/groundPet.lua:78` -> `petportsTaskUpdateInner`.
     It attributes time to every function in every mod; ours is what to
     compare against the others.
- The engine caps Lua instructions per call (`scriptInstructionLimit`,
  StarLuaRoot). Exceeding it throws out of `Monster::update`, aborts the
  update, and the unit snaps to its anchor ("random teleport home"). Nothing
  in the survey may be O(store size) in one call. Everything now is chunked
  or bounded; keep it that way.

---

## THE STRUCTURE, AS SHIPPED

**Cells.** `PETPORTS_NAV_CELL = 2`, `PETPORTS_NAV_STRIDE = 1` (free movers
too; `PETPORTS_NAV_STRIDE_FREE` is a knob, tried at 4 and rejected because it
lost tunnel granularity). Every tile is the origin of a 2x2 window; a
position belongs to the cell whose origin is its tile.

**Coverage.** `NAV_COVERAGE_MARGIN = 2`: a cell outside every port rectangle
is not a candidate, for any profile (was 12; megabase edges were unreliable).
Free-mover nodes trace the coverage edge like a wall; free-mover edges may not
leave coverage along their length.

**Anchors, walker.** Feet on the cell's bottom edge, one row of candidates at
tile centres. Footing `{Block,Slippery,Platform}` in the row beneath under the
body's part inside the cell's columns; `validStandingPosition(point,
petports_avoidLiquid())`; `petports_mediumAllows`. Slippery is the mission
boundary wall, never a floor (Lofty).

**Anchors, free mover.** ONE candidate: the window centre (origin+1,
origin+1). Body-fit against `{Null,Block,Dynamic,Slippery}`; near-surface =
solid within 0.5 of the body box (or the coverage edge); mediumAllows. One
layer of nodes along every surface, every cell of a 2-wide tunnel, every
stair step, nothing in open air. Tile-centre candidates gave a double layer
and no floor/ceiling nodes at all (measured).

**Profile string.** `type|f<freeMover>|b<w,h>|l<liquids>|d<doors>|a<avoidLiquid>`.

**Survey.** Radius ladder 4..12 by 2, index entry `{ at, radius }`, narrowest
first then nearest; a free mover seeds from the nearest anchored cell within
4 tiles. Runs idle AND on task when the unit's pather has no live search.
Per update: at most `NAV_STEPS_PER_TICK = 4` sweeps stepped, within
`NAV_TICK_BUDGET_MS = 10`; a sweep resume steps at most WORKERS probes. Top-up
at most every `NAV_TOPUP_INTERVAL = 0.25` s, scanning `NAV_CANDIDATE_SCAN =
60` graph froms from a rotating cursor, keeping a bounded best list of
`NAV_CLAIM_ATTEMPTS = 8`; empty top-up backs off `NAV_IDLE_INTERVAL = 2` s.
`PETPORTS_NAV_SWEEPS = 8`, `WORKERS = 4`. Purge once a minute.

**Verdicts.** Walker: A* probe, `maxDistance 32`, 300/tick; TRUE also needs
path length <= `3 x distance + 8` edges (else `TOO LONG`, recorded false).
Free mover: `petports_bodyFitsAlong` (shared with the fishing code) plus
in-coverage -> TRUE now; blocked -> FALSE now UNLESS `Dynamic` is on the
line, then the A* fallback (doors). No BFS skip test for free movers.

**Store I/O.** Index read memoised per tick, index entries queued and written
with the edge flush (25 edges / 5 s); no flush per sweep; cell cache TTL 120 s;
anchors and solid verdicts cached 30 s per profile; profile string and stride
memoised per tick.

**Graph.** Memoised; own writes never drop it (learned edges are inserted
and removed in place). Rebuild only on cache expiry or a new unit, as a state
machine: `NAV_BUILD_CHUNK = 40` cells per update reading, then 320 edges per
update deriving fine + coarse; the old graph serves until the swap.

**Routing / legs (taskAction).** Coarse-first for any unit (walker or flyer)
when the target is > 24 tiles or has no line of sight. Legs from the nearest
graph cell (free mover: nearest VISIBLE cell within 32, nearest-first, first
hit wins); target cell resolved once per target. `NAV_LEG_REACH = 8`
(walker), `NAV_FLYER_LEG_REACH = 32` with the leg = farthest visible path
cell (string-pull). Reached legs chain from `navLegTo`. Leg pather:
`maxDistance 32`, `NAV_LEG_EXPLORE_RATE = 1200`. Failed leg -> one hop ->
`petports_navVerify` -> contradict last hop -> re-plan; a leg refused by the
pather for 0.5 s logs which of `find()`'s two gates closed. Flyer lookahead
sweep re-checked 5x/s (`petports_flyapproach.lua`).

**Overlay.** `PETPORTS_NAV_DEBUG = false` (opt-in; the client `/debug` toggle
does NOT stop the script drawing). `petports_navDebugToggle()`. One
`debugPoint` per swept cell within `NAV_DRAW_RANGE = 64`: red if swept within
10 s, else green (walker) / blue (free mover). Readouts refresh every 2 s.
`PETPORTS_NAV_VERBOSE` (opt-in) restores per-probe log lines.

---

## MEASURED FACTS THAT DECIDED THINGS (this pass)

- The unit script updates 12 times a second (counted).
- `maxDistance` bounds wander from the start, not path length (166-edge
  path under the 32 cap).
- A fresh unit on a big store hit the instruction limit in its first navTick
  (one-shot graph rebuild); the same call was `graphFor max=1029 ms` every
  cache expiry before.
- With the overlay on, `world.debugLine` at 5-7k/s was most of the unit's
  cost; `petports_navLevelProgress` memoised on the store version recomputed
  on every flush (3750 of 10072 in the engine profile).
- The candidate walk was O(store) per top-up: `consider` + `table.sort` +
  whole-index reads. Now bounded slice + bounded best list.
- The per-probe log lines were up to 318 lines/s.
- A flush per sweep was ~1 s of every 5 on a flyer.
- `petports_navProfile()` under the anchor cache key cost more than the scan
  it cached; `petports_freeMover()` reads `baseParameters()` every call.
- A wall-blocked flyer pair ran the A* fallback to its cap (false 26-55 per
  5 s); the fallback is for doors only now.
- The 2 s idle spike was two whole-index reads per empty top-up.
- Port ticks are 30-39 ms at worst (instrumented, `PETPORT slow tick`).

## FACT (retail source)

`PathFinder:find` gates: `canPathfind()` false -> "pathfinding", aStar nil
(walker not onGround); `mustEndOnGround and not validStandingPosition(target,
false)` -> false. `StarLuaRoot`: engine owns the collector
(`tuneAutoGarbageCollection(luaGcPause, luaGcStepMultiplier)`, both 1.2 in
`client.config` and `worldserver.config`), caps instructions per call,
and has the `.luaprofile` profiler. `collectgarbage` is not exposed to
scripts; `os.clock` is.

---

## DEAD

- Sparse stride for flyers (4): lost 2x2 tunnel granularity. Density is cut
  by WHERE a free mover anchors instead.
- 1-tile near-surface growth: two layers per surface. 0.3 growth with
  tile-centre candidates: no floor/ceiling nodes. 0.5 with the window centre
  is the one that works.
- "The GC is the stutter": unfalsifiable from script and contradicted by the
  instruction-limit error. Big single calls were the stutter, every time.
- The BFS skip test for free movers: cost more than the body sweeps it
  skipped.
- Contradict-on-failure as the primary correction: probe-provable edges were
  being contradicted because the walk under-searched. Verify first (done).

---

## OPEN, NOT SCHEDULED

- **Swimmer in open water** -- untested. Expect a rim of nodes along the
  coverage edge; `petports_bodyFitsAlong` does not check medium mid-segment.
- **Amphibious** -- combine beach-entry code with leg building (Lofty).
- **openDoors** -- profile carries the flag; drop `Dynamic` from the three
  solid sets for openers; engine-side pathOptions name for doors unread.
- **Network budget** for tens of units: cap concurrent sweeps per port, tune
  against `setProperty`/s. The constants above are what it would expose.
- **TTL semantics**: `NAV_SWEEP_TTL` counts world time while unloaded, so a
  restart after 15 min wipes the mesh. Options: hours-long TTL plus the
  contradiction path, or age by loaded time.
- **Variable-size cells** (3-wide/3-tall): would need cell identity to carry
  extent or a cell table; probes/routing would survive. Not needed after the
  single-layer fix; noted.
- **Player-placed waypoints** as forced seed cells: small object, one branch
  in the seed logic, sits on top of the survey rather than replacing it.
- `petports_navStats` is called from the idle branch (70 in the last
  profile); fold it behind VERBOSE. Cosmetic.
- Pickup is not distance-checked; hop-count BFS routing; coarse levels are a
  rejection filter only.
- `petports_gcTune()` is dead code (collectgarbage unavailable); remove.
- V2 handoff has no coarse-nav entries; `todo.dispatch.reachbudget` should be
  retired; `fact.pathing.ongroundtest` corrected re Slippery already.

---

## DIAGNOSTICS

`petports_navProgress()`, `petports_navVerify(from, to)`, `petports_navSelfTest()`,
`petports_navLevelReport()`, `petports_navStats()`, `petports_navDebugToggle()`,
`petports_navVerboseToggle()`, `petports_profToggle()`, `petports_navWipe()`.
Log lines: `NAV surveying`, `NAV sweep of ... COMPLETE`, `NAV pass at radius`,
`TOO LONG`, `UNIT coarse first`, `UNIT coarse leg from`, `reached coarse leg
... chaining`, `would not walk`, `re-probe says`, `CONTRADICTED`, `refused by
the pather ... onGround ...`, `PROFILE`, `PETPORT slow tick`.
