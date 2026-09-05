# COARSE NAV -- SESSION HANDOFF, 2026-09-05 (end of session)

Read this before proposing anything. Everything below marked MEASURED was
read out of a starbound.log this day; everything marked FACT was read out of
retail 1.4.4 source pasted into the session. Items from earlier sessions that
were rolled back are not listed unless re-derived here.

Retail Starbound 1.4.4 only. Never propose an OpenStarbound or fork binding.

Builds in play, all tested in game:
`petports_coarsenav.lua` **2026-09-05q**, `petportsTaskAction.lua`
**2026-09-05o**, `petports_petport.lua` **2026-09-05a**.

**STATE:** coarse nav works end to end. MEASURED 05:59-06:01: 164 legs, 136
chained, 11 tasks done, 1 failed then succeeded on redispatch. Ground unit on a
farm planet with ponds: 19 tasks done, 0 failed, 0 refusals. Committed.

---

## THE TEST LOOP IS EXPENSIVE. BUDGET ACCORDINGLY.

Read the log before proposing a fix. Every fix this session came from a grep,
and every guess made before the grep was wrong. Say less. Change one thing.

`petports_navWipe()` only when the STORE is known bad -- a change to the anchor
rule, the cell key rule, what a verdict means, or the index entry format.
Changes to `petportsTaskAction` never need one. A profile-string change (05q
added `|a1`) re-buckets on its own, no wipe.

---

## THE STRUCTURE, AS SHIPPED

**Cells.** `PETPORTS_NAV_CELL = 2`, `PETPORTS_NAV_STRIDE = 1`: every tile is
the origin of a 2x2 window; a position belongs to the cell whose origin is its
tile (`petports_navCell`, `navCellOrigin`). Lofty's decision, 05c: a
non-overlapping 2x2 grid could not cover a 7-wide shaft's wall-side tile.

**Anchors, walker.** Feet on the cell's bottom edge, one row of candidates
(`x = origin + dx + 0.5`). Accept when: `navFootingUnderCell` finds
`{Block,Slippery,Platform}` in the row beneath the cell under the part of the
body inside the cell's own columns; `validStandingPosition(point,
petports_avoidLiquid())`; `petports_mediumAllows(point, bounds)` is not false.
Free movers: 2x2 body-fit scan at tile centres, then mediumAllows.

**Profile string.** `monsterType|f<freeMover>|b<w,h>|l<liquids>|d<doors>|a<avoidLiquid>`.

**Sweep.** Radius ladder 4 -> 12 by 2 (`PETPORTS_NAV_RADIUS_START/STEP/RADIUS`);
index entry per cell is `{ at, radius }` (a bare number reads as radius 0);
candidates sorted narrowest-radius first then nearest, so passes are emergent.
Seed cell only when grounded and anchored. Top-up every tick a slot is free
(`NAV_TICK_INTERVAL = 0`), 2 sweeps x 4 workers. Survey runs while idle AND
while on task whenever the unit's own pather has no live search.

**Verdict.** A probe is `start(anchorA, anchorB)` with the unit's pathOptions
and `maxDistance 32`, explored 300/tick. TRUE also requires the solved path to
be at most `3 x anchorDistance + 8` edges (`aStar:result()`), else recorded
FALSE with a `TOO LONG` line. A TRUE is inserted into the memoised graph at
once; a FALSE removed from it at once.

**Routing.** BFS over fine edges (hop count). `petports_navWaypoint` returns
the farthest path cell within `NAV_LEG_REACH = 8` of the origin, skipping
hops inside `ARRIVAL_DISTANCE + 0.5`, plus the chosen cell, hop count, origin
cell and previous cell.

**Task action.** Coarse-first, once per target, for a walker whose target is
> 24 tiles away or has no line of sight (`world.lineTileCollision`). A fresh
leg plans from `petports_navNearestCell` (nearest anchored graph cell within
2.5 tiles), only on the ground. A reached leg (grounded, or approachPoint's
own verdict) chains at once, planning from the cell it just reached
(`navLegTo`), never from the nearest cell. approachPoint arrival at a
waypoint never sets `arrived`. A leg pather gets `maxDistance 32` and explores
at 1200/call. A leg that hits `SEARCH_LIMIT`: multi-hop -> retried at reach 0;
one hop (or already reach 0) -> `petports_navVerify` re-probes it, the LAST
hop is contradicted unless the re-probe says false, re-plan. A leg the pather
refuses without a search for 0.5 s is sent to the same handover; the line
prints onGround / validStandingPosition(target,false) / liquidAt /
finder.target. solveLaunch never accepts a downward launch.

---

## MEASURED FACTS THAT DECIDED THINGS

- **The unit script updates 12 times a second.** Counted via exploreRate.
  So `SEARCH_LIMIT 6 s = 72 explores`. The probe that proved a deck-to-deck
  edge needed 88. Every "would not walk" before taskAction 05h was 72 vs 88.
- **`maxDistance` bounds how far a search wanders from its start, not path
  length.** A 5-tile pair was proved with a 166-edge path under the 32 cap.
  Every comment saying "within 32 tiles of path" was wrong; older comment
  blocks above `NAV_MAX_DISTANCE` still say it, the correction sits beside
  the constant.
- **The candidate walk read the whole index once per known cell** (504 reads
  per top-up, ~3 s). Fixed coarsenav 05g; both walks read once.
- **The skip test skipped nothing** until learned edges entered the memo
  (coarsenav 05h): probes per sweep == candidates per sweep.
- **A leg reached mid-jump** was cleared with onGround false, and the chain
  refused to plan from the air. A waypoint arrival from approachPoint set
  `arrived` and a pickup ran 35 tiles from the item.
- **Adjacent cells can have opposite shortest routes.** Chaining from the
  nearest cell instead of the reached cell oscillated on a platform stack.
- **A store edge can be a stale verdict for THIS unit**: the anchor rule
  passed avoidLiquid false, the unit's find() refuses a liquid target. 05q.
- **Cargo:** an item came back from disk with `cargo = {"1":{...}}` (json
  object); every reader uses ipairs/#; the next write-back erased it.
  `normaliseCargo` on read and write, petport 05a. Root remover not found.

## FACT (retail source, read this session)

`PathFinder:find(target)`: returns `"pathfinding"` (aStar stays nil) when
`canPathfind()` is false -- a walker not onGround; returns false when
`options.mustEndOnGround and not validStandingPosition(target, false)`;
otherwise `reset()`, `start(mcontroller.position(), target)`, `explore()`.
`start()` sets `self.target` and calls `world.platformerPathStart(...)`.
`validStandingPosition(position, avoidLiquid, collisionSet, bounds)`: ground
rect = full box width, one tile under the feet, against
`{Null,Block,Dynamic,Platform}` OR (`not avoidLiquid and liquidAt(position)`);
body rect against `collisionSet or {Null,Block}`. Default explore rate is
world-fidelity 25..150; ours overrides to 300 / 1200.

**Slippery is NOT ice.** It is the invisible mission-boundary wall (Lofty).
Treat it as a wall (body fit, solid prefilter); it is never a floor. The
`fact.pathing.ongroundtest` entry in V2 calls it ice and is wrong there.

---

## DEAD -- RULED OUT WITH EVIDENCE

- "Overlapping cells alone fix the shaft" -- no: the candidate rule did.
  Overlap was kept by decision; the footing rule is what puts an anchor on a
  wall-side platform's cell.
- "The mesh is inconsistent because of maxDistance 32 vs 200" -- partly:
  matching the cap was necessary, the explore budget (12 Hz x 300) was the
  larger cause.
- "Contradict the edge when the walk fails" as the primary correction --
  works, but every contradicted edge in the 03:42 log was a probe-provable
  edge the walk under-searched. Verify before contradicting; the code does.

---

## OPEN, NOT SCHEDULED

- **First `SEARCH_LIMIT` stall on a target under 24 tiles with line of
  sight** still exists by design (coarse-first does not fire).
- **Pond-edge refusals** (05:59 log, `y=1158.8`) did not reproduce after 05q.
  The instrumented refusal line will name the gate if they return.
- **Flyers:** legs as "farthest visible node on the path" via the existing LOS
  check (Lofty). Coarse-first is gated `not freeMover` today. The free-mover
  graph only needs to be connected, not dense.
- **Amphibious:** already paths into water it passes through; the manual mode
  switch is only for the fish target / underwater heal. Combine the existing
  beach-entry code with leg building. Not a store or profile problem.
- **openDoors:** profile already carries the flag; drop `Dynamic` from
  `NAV_SOLID_SET`, the anchor body-fit set and `COARSE_LOS_SET` for openers.
  Engine-side pathOptions name for door opening still unread (pathutil.lua's
  `openDoorsAhead` is a movement-side helper, not a pathfinder option).
- **Pickup is not distance-checked** in the task action (it ran 35 tiles
  away when `arrived` was set wrongly). Guarded now only by arrival being
  correct.
- **Routing is hop-count BFS.** Edge cost is now available (`aStar:result()`
  length) but not stored or used. The coarse levels are a rejection filter
  only. Neither has been the cause of a failure since coarsenav 05n.
- `NAV pass at radius N complete` logs once per unit per boundary and can
  repeat when new cells appear. Cosmetic.
- `petports_petBehavior.lua` has never had a build stamp. Twenty files remain
  CRLF-flipped from zip transport.

---

## DIAGNOSTICS AVAILABLE

- `petports_navProgress()` -- cells / swept / full / frontier / sweeping.
- `petports_navVerify(fromKey, toKey)` -- one pair, probe to completion now.
- `petports_navSelfTest()`, `petports_navLevelReport()`, `petports_navStats()`.
- Log lines: `NAV surveying <cell> at radius N`, `NAV probe A -> B
  REACHABLE/UNREACHABLE after T tick(s), E edge(s)`, `TOO LONG`, `UNIT coarse
  first`, `UNIT coarse leg from A to B: heading for P, N hop(s) left`, `UNIT
  reached coarse leg <cell> with N hop(s) left -- chaining`, `would not walk`,
  `re-probe says`, `CONTRADICTED`, `refused by the pather ... onGround ...`,
  `UNIT approach at ... | search <aStar> explores <count>`.
- Overlay: green = swept cell centres; magenta = cells being probed; yellow
  line = probe; tick count in a corner. `petports_navDebugToggle()`. Draw
  runs every tick from navTick and draws every swept cell; turn it off when
  measuring frame time.
