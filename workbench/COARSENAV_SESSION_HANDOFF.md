# COARSE NAV -- SESSION HANDOFF (as of coarsenav 07m / taskAction 07a / petport 07g)

Read this before proposing anything. MEASURED means read out of a
starbound.log or an engine `.luaprofile`; FACT means read out of retail 1.4.4
source pasted into a session. Retail Starbound 1.4.4 only; never propose an
OpenStarbound or fork binding. The OpenStarbound repo's first commit is
unmodified retail source and may be READ for facts (StarLuaRoot.cpp was).

Builds in play:
`petports_coarsenav.lua` **2026-09-07m**, `petportsTaskAction.lua`
**2026-09-07b**, `petports_flyapproach.lua` **2026-09-06b**,
`petports_contract.lua` **2026-09-06a**, `petports_petport.lua` **2026-09-07g**.
**SOAK TEST, 2026-09-05 22:21 -> 00:25 (2 h, 1.2 M lines), on these builds:**
zero LuaInstructionLimitReached; 14 unit ticks over 200 ms in two hours
(one of 1,689 ms at 22:23:09, in the task action OUTSIDE navTick --
unsectioned, see open list); 96 port ticks over 100 ms, worst 315 ms;
store 4.9 -> 7.6 MB, all of it the free-mover ladder finishing (flyer 50k
-> 77k true edges, ~80 per cell at radius 12), not a leak. Acceptable for
a small unit count (Lofty). ONE REAL DEFECT FOUND IN IT: 6,702 of 6,975
"refused by the pather" lines were free movers in water (onGround false is
their normal state); each good leg was failed at 0.5 s, re-probed (true),
contradicted and re-planned -- 4,002 contradictions on |f1| profiles, and
the false edges growing in the aquatic stores. taskAction 07b makes the
refusal detector walker-only; UNTESTED as written. Expect the aquatic false
counts in `petports_navDumpStore` to stop growing and the zigzag to go. Five of the 14 big unit ticks were `candidates`
at ~220 ms with the survey idle: the graph rebuild's FIRST step (read the
profile index, build the key list) is still one call.

**STATE.** Walkers and flyers route end to end; a walker retrieved and
deposited across the base, a flyer surveyed the whole ship. Six ports on a
small islet with seven units was "runs like crap" at the start of the second
performance pass and is near acceptable at the end of it: unit updates flat,
port ticks ~3.5% of the world thread, the 2 s planet lockup found and
removed (07m). No LuaInstructionLimitReached since 07f. This is the starting
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

## SECOND PERFORMANCE PASS (07i..07m, petport 07a..07g) -- WHAT WAS FOUND

Every one of these was read off a log, a `PROFILE` line, a `PETPORT profile`
line, or an engine `.luaprofile`. In the order found:

- **Long-run "memory leak" (hours):** three growth paths, all ours. Anchor and
  solid caches never evicted (07i: cleared every 30 s). Free movers stored
  every false edge, ~600 pairs per cell at radius 12 (07i: not stored). The
  15-minute sweep TTL re-ran the whole ladder forever while loaded and wiped
  the mesh on any restart after lunch (07j: six hours). The store itself is
  small: `petports_navDumpStore()` measured 1.6 MB for seven profiles.
- **Fresh unit's first two updates took ~1 s each:** the index was one
  property holding every profile's cells, converted whole on every read
  (07k: one property per profile, `petports_navindex:<profile>`, plus a
  registry). MIGRATION: run `petports_navWipe()` on the old build before
  loading 07k, or old shards are orphaned.
- **Log volume, 170-320 lines/s:** `UNIT pre-move/post-move` per tick
  (taskAction 07a: behind `TASK_TRACE_MOVES`), per-probe NAV lines (07b:
  behind `PETPORTS_NAV_VERBOSE`), `UNIT standable candidate` (petport 07g).
- **Ports.** `PETPORT profile` (petport 07b/07d/07e/07f): six ports in
  lockstep at 1 s beats, `dispatchWork` 30 ms a call, `crosshairRefresh` and
  `mirrorPaneState` every tick. Petport 07c: 2 s beats with random phase,
  drop-triggered dispatch from the crosshair scan (ingress <= 0.5 s),
  filter-accepts cached per beacon+name (space still live), pane mirror on
  its interval with `containerCallback()` closing the duplication window and
  writes only on change. Petport 07g: `servicePointNear` cached 30 s per
  object per socketed unit (refusals retried at 5 s) -- the standable-spot
  search was what all 22 generators shared. `findWork` is now the port's
  top phase at ~2 s per 128 s across six ports; the cross-port shared scan
  (one port scans, publishes, the rest read) is the next structural step
  and has not been built.
- **The 2 s planet lockup:** `survey COMPLETE` called `petports_navStats()`,
  which reads every shard of every profile cold. Fired per fresh unit and per
  closed frontier. 07m: gone; COMPLETE is also not declared while the graph
  is still being built.
- **pcall** is not a cost here: every one wraps an engine call that costs
  100-1000x more than the wrapper (measured by the probe timings and absent
  from the engine profile).

## FISHING NOTE (not a bug)

Vanilla `fishingspawner.config`: rarity thresholds ascending, lower is rarer
(`roll <= 0.001` legendary), `roll = random + bias`, bias starts 0.2 and
DROPS 0.1 per spawn; legendary needs bias 0 (third spawn on) AND a 0.1%
roll AND `deep` (>= 25 tiles below `world.oceanLevel`). Every legendary in
every pool is deep-only. Lofty eyeballed the islet: ~1/6 of water coverage
is deep enough. Rares have shallow variants, which is why they appear.

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
- `petports_gcTune()` is dead code (collectgarbage unavailable); remove.
  The port profiler's `portProf("pane.json", pcall, ...)` is two wrappers
  deep for no reason; flatten when the profiler comes out.
- Pane mirror still builds the state blob every 0.5 s (~1.4 ms x 6 ports);
  a change signature (task id, fuel, cargo count, stats) would make idle
  free.
- Cross-port shared scanning (see second pass above).
- **Section the task action outside navTick**: tryCoarseLeg /
  petports_navNearestCell (free mover: sight sweeps to graph cells out to
  32 tiles) and the direct search, so a 1.7 s outlier gets a name.
- **Chunk the graph build's start** (index read + key list) like the rest of
  it; and/or **cap the free-mover ladder at radius 8**, which halves the
  free-mover stores and every read of them.
- Network budget for tens of units: the per-update caps above are what it
  would expose; six ports x seven units is ~35% of the world thread on the
  laptop with everything idle-surveying.
- Pickup is not distance-checked; hop-count BFS routing; coarse levels are a
  rejection filter only.
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
