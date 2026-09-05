# COARSE NAV — SESSION HANDOFF, 2026-09-05

Read this before proposing anything. Several hours went into the items marked
DEAD; re-deriving them costs a test round each.

Builds in play: `petports_coarsenav.lua` **2026-09-05m**,
`petportsTaskAction.lua` **2026-09-05i**. Both untested at time of writing.

---

## THE TEST LOOP IS EXPENSIVE. BUDGET ACCORDINGLY.

A wipe-and-rebuild costs Lofty **~15 minutes** of sitting and waiting. Do not
propose "wipe and try this" as a way of narrowing a hypothesis. Read the
existing logs and dumps first; most questions are already answered in them.

Only `petports_navWipe()` when the STORE is known bad — a change to
`petports_navAnchor`, to the cell key rule, or to what an edge means. Changes to
`petportsTaskAction` never need one.

Retail Starbound 1.4.4 only. Never propose an OpenStarbound or fork binding.

---

## THE FAILURE BEING CHASED

A unit deposits an item on the far side of the ship and cannot get home. It
walks most of the route correctly and stalls at one spot, which Lofty marks as
the "yellow X": the west lip of the y1036 deck, around world x1017.

Relevant geometry, derived from the ship layout and confirmed against unit
positions in logs:

- y1036 corridor is in two pieces: **x990..1010** and **x1018..1084**, with a
  seven-tile hole between them.
- The deposit target sits at **[1005.5,1036.8]**, on the west piece.
- Crossing the hole means dropping to the y1031 level and climbing back.
- Home port is **[981,1044]**, approached at **[981.5,1039.8]**.

---

## FIXED AND CONFIRMED WORKING — DO NOT REOPEN

1. **Leg chaining.** A reached leg with hops remaining chains straight into the
   next instead of resuming the final target. Before, each leg cost a full
   6-second `SEARCH_LIMIT` failure first. Confirmed: five legs chained in ~7s.

2. **One hop per leg.** `petports_navWaypoint` used to take the farthest cell
   within a 24-tile `reach`, swallowing several proven edges into one unproven
   leg. It now advances exactly one graph hop. `NAV_LEG_REACH` is gone.

3. **The downward launch.** `solveLaunch` branch 1 accepted a NEGATIVE launch
   velocity for a descent, because `discreteRise` squares `v0` and returns a
   positive rise for a downward launch. Measured: `-39.3333`, accepted, set on a
   grounded unit, floor wins, unit never leaves the ground. Branch 1 now
   requires `candidate > 0`; branch 2's rise is floored at
   `JUMP_ARC_CLEARANCE`. **Confirmed in game** — the ledge jump executes.

4. **Anchors were not on nodes.** `petports_navAnchor` produced tile centres
   (`x.5`); pathfinder nodes are integers (`petports_nodePosition` is
   `floor(x + 0.5)`). Every anchor sat exactly on a node seam with zero margin.
   Candidates are now integers. **Confirmed: 206/206 anchors on `.0`.**

5. **Anchors in mid air.** `validStandingPosition` tests whether the BODY FITS,
   not whether it can stand, so every body-sized pocket of open air anchored.
   `navHasFooting` now requires support in `[x-0.5, x+0.5]` one row under the
   feet, against `{"Block","Slippery","Platform"}`. **Confirmed: 0/206
   anchorless-with-edges, down from 28/204.**

6. **Arrival in mid air.** `ARRIVAL_DISTANCE` is 1.5 and a jump passes within
   that of its landing point while still falling. The chain then planned from
   the cell the unit was falling THROUGH. Arrival now requires `onGround`, and
   `tryCoarseLeg` refuses to plan while airborne. Confirmed.

---

## THE PENDING FIX (untested)

`petports_navCell` is `floor(x / 2)`; a node is `floor(x + 0.5)`. They round on
different boundaries, so a position can sit in one cell while the node it
occupies is in the next.

Measured: unit settled at `[1011.8,1031.8]` after the ledge. `floor(1011.8/2)`
is **505**; its node is **1012**, which is in cell **506**. Cell `506,515` has
anchor `[1012,1031.8]` — the exact point the unit was standing on — and a direct
edge to `502,518`, one hop from home. Cell `505,515` has never existed in the
store. Result: `sourceIsolated`, journey dropped half a hop short.

`petports_navCellAt` resolves a position to its node first. Used for both ends
of a leg plan, the survey seed and the breadcrumb trail. Free movers pass
through unchanged (the node y term is not an identity for a tile-centre anchor).

**Expected next log:** `leg 6 TAKEN: 506,515 > 502,518` then `journey ARRIVED`.

---

## DEAD — RULED OUT WITH EVIDENCE

- **"The route is greedy / badly weighted."** BFS minimises hops rather than
  cost, which is true and has NOT been the cause of any observed failure. Every
  route inspected was legitimate given the graph. Do not rewrite the search
  before something measurably fails on it.
- **"It should use vents."** There are ZERO vents on this network
  (`vents: none`, `planRoute impossible: vent list is empty`). Vent routing has
  never run. What looks like ducts is ship corridors.
- **"The overlay shows cells floating in air."** Two separate causes, both
  fixed: the marker was drawn at the cell centre, which is a TILE CORNER; and
  the anchors themselves were genuinely in air (item 5). The overlay now marks
  anchors, and swept cells with no anchor draw a grey box.
- **Anchors sitting one tile clear of a 1-wide platform.** Caused by a footing
  test that used the full 1.6-wide bound box, which overhangs 0.3 into each
  neighbour. Narrowed to the node's own catchment. Fixed.

---

## THE GRANULARITY QUESTION — CURRENT EVIDENCE SAYS NO

Lofty's standing theory is that 2x2 cells miss one-wide platforms in
odd-width vertical shafts, and that the fix is cell size 1 (or a 1-tile stride).
**The last dump does not support this.** The ladder the unit climbs at x1028
is fully represented:

```
cell 514,521  anchor [1028,1042.8]  out 16 in 16
cell 514,522  anchor [1028,1044.8]  out 14 in 14
cell 514,523  anchor [1028,1046.8]  out  8 in  8
cell 514,524  anchor [1028,1048.8]  out  8 in  8
```

Those are exactly the positions the unit stood at while climbing in an earlier
log. Nothing is missing. Before concluding the granularity is at fault, produce
a cell that (a) contains a standable node and (b) is absent from a dump.

**There IS a real granularity concern, but it is a different one.**
`petports_navAnchor` returns the FIRST acceptable candidate and stops, scanning
`dx = 0` before `dx = 1`. So a cell holding both ordinary floor and a ladder
rung anchors on whichever is reached first. Measured skew in the last dump:
**194 anchors on the even (left) node, 12 on the odd**. If a route ever needs
the feature on the right-hand node of a cell that also has floor on the left,
the graph cannot express it. That is the argument for cell size 1 — not missing
cells.

If cell size 1 is attempted:
- `PETPORTS_NAV_CELL = 1`. Do NOT use a 1-tile stride with 2-wide cells: cell
  identity must be single-valued, and it keys the shard property, the claim id,
  the sweep index and `navBlockKey`.
- At size 1 the cell IS the node, so `petports_navCell` and
  `petports_navCellAt` must collapse to the same function.
- The coarse ladder `NAV_LEVELS = {4,8,16,32}` wants a `2` in front or the
  first level does nothing.
- Expect roughly double the cells (the anchored set is close to
  one-dimensional), and consider cutting `PETPORTS_NAV_RADIUS` again — probe
  count goes with the AREA of the candidate box.

---

## DIAGNOSTICS AVAILABLE

- `petports_navDumpGraph()` / `(radius)` — every node: tile extent, anchor or
  refusal reason, swept age, coverage, out/in degree, then every outgoing edge
  with distance, `dx`, `dy` and both directions' verdicts. Includes target-only
  cells. Radius is centred on the nearest PLAYER.
- `NAVT` trace — every leg request with its reason, the full path, every edge's
  verdict both ways, every candidate cell considered (including skipped ones and
  why), and each leg's outcome with a clock and odometer.
- `petports_navExplain(from, to)` — one-call diagnosis of a refused route.
- Overlay: green cross = anchor, blue = two-way edge, red = one-way with a
  chevron, orange box = sink (in-edges, no out-edges), grey box = swept cell with
  no anchor. `PETPORTS_NAV_EDGE_RADIUS` is live-tunable via `/entityeval`.

`grep 'dy -'` on the trace finds every descent, which is where the failures
have clustered.

---

## OPEN, NOT SCHEDULED

- **Arrival at 0.82 tiles failed.** `drop:134`, unit at `[1051.28,1036.8]`,
  target `[1052.1,1036.88]`, `ARRIVAL_DISTANCE` 1.5. Six approaches, then "no
  vent route". Nothing to do with coarse nav.
- **`ARCPLAN VERDICT`** decides "the plan's Land is on the ASCENDING crossing"
  for a landing BELOW the takeoff. The verdict text is wrong even where the new
  branch-2 path produces a working launch. Cosmetic so far.
- **Free-mover anchors** are still tile centres, deliberately. Same seam
  argument applies; no flyer has been measured failing on it. Reopen the first
  time a flyer hovers beside a waypoint instead of reaching it.
- **`petports_petBehavior.lua`** has never had a build stamp.
- Twenty files remain CRLF-flipped from zip transport.
