--  PETPORTS -- COARSE NAVIGATION, v1
--
--  A SEPARATE SYSTEM FROM VENT ROUTING, ON PURPOSE AND BY INSTRUCTION.
--
--  `arch.vent.routing` answers "which shortcuts get me there" over a graph of
--  vent mouths. This answers "is there ground between here and there at all",
--  over a grid of the world itself. They will meet -- a vent hop is eventually
--  just another directional edge in this graph, and that is the whole reason
--  vents matter to coarse pathing: a vent can put a unit into a region that has
--  no walkable connection to anywhere. But this is BUILT FIRST AND ON ITS OWN,
--  and vents are added to it, rather than this being grown out of the vent
--  cache. Three concrete reasons, all of them measured rather than aesthetic:
--
--      LIFETIME       petports_routeKnown expires TRUE edges at 600 seconds
--                     (ROUTE_TTL_TRUE). That is right for a cache of shortcuts
--                     through a base the player rewires. It is fatal for a
--                     structure that takes minutes to build in the background:
--                     it would spend its life rebuilding. Terrain adjacency is
--                     permanent until contradicted.
--
--      INVALIDATION   the port clears self.routeCache WHOLESALE whenever
--                     coverage changes -- see refreshNetwork. Adding a port to
--                     a network would erase the entire tree. Coverage changing
--                     says nothing about whether two tiles are still adjacent.
--
--      SCOPE          the vent cache lives on `self` on each port, so it is
--                     per-port, in-memory, and gone on reload. A town-scale
--                     tree has to be shared and has to survive, so this lives
--                     in a WORLD PROPERTY.
--
--  WHAT v1 IS, AND WHAT IT IS DELIBERATELY NOT.
--
--  It is: deterministic cell anchors, one cell size, directional adjacency
--  probing, a capability-keyed store, and enough logging to answer the two
--  questions that size every later decision -- WHAT DOES AN ADJACENCY PROBE
--  COST, and ARE THE VERDICTS REPRODUCIBLE.
--
--  It is not: the coarse levels, the background scheduler, dispatch
--  integration, or vent edges. Every one of those is a sizing decision that
--  wants the measurements first. Building them now would be guessing with more
--  code.
--
--  THE TREE IS OPTIMISTIC, AND THAT IS THE LOAD-BEARING DESIGN CHOICE.
--
--  Its job is to cheaply rule targets OUT, never to promise a route in. A cell
--  pair verdict is inherently lossy -- "some point in A reaches some point in
--  B" is not "the point I care about in A reaches the point I care about in B"
--  -- because players build to human clearances that have no relationship to
--  our grid. A two-tile tunnel straddling a cell boundary is the NORMAL case,
--  not an edge case.
--
--  So the two errors are priced differently and the whole design follows:
--
--      a wrong TRUE   costs one ordinary failed task, and the existing failure
--                     path already handles it. Cheap.
--      a wrong FALSE  silently deletes work from the world with no log and no
--                     recovery. Expensive.
--
--  Which is why FALSE expires and TRUE does not, why an unknown edge answers
--  nil rather than false, and why proximity doors and docking fields -- which
--  are unprobeable and time-varying and nobody's fault -- are allowed to
--  produce optimistic-wrong answers. They fail in the cheap direction.

local COARSENAV_BUILD_STAMP = "2026-09-05p an anchor refuses a medium the chassis will not enter"

local navStamped = false

local function stampOnce()
	if navStamped then return end
	navStamped = true
	sb.logInfo("PETPORTS coarsenav build: %s (unit %s)",
		COARSENAV_BUILD_STAMP, tostring(entity.id()))
end

--  WHERE THE TREE LIVES. A world property, so every port and every unit in one
--  world shares one structure and it survives a reload.
--
--  PER WORLD, WHICH IS ALSO CORRECT RATHER THAN MERELY CONVENIENT. Ship and
--  planet are separate worlds with separate property stores, so a ship's tree
--  can never be consulted for a planet -- the same structural separation that
--  keeps the registry, claims and replant intents apart.
--  SHARDED BY SOURCE CELL, NOT ONE BLOB.
--
--  IT WAS A SINGLE PROPERTY AND THE COST WAS THE PROBLEM, not correctness.
--  There was never a race -- a read-modify-write is one uninterrupted Lua call,
--  entity scripts do not interleave, and world properties are synchronous -- so
--  eight units could not clobber each other. What they could do is SERIALISE
--  THE WHOLE TREE EIGHT TIMES PER FLUSH CYCLE, with the cost growing as the
--  tree fills. That is the ceiling, and it is the one thing that gets worse the
--  better the survey does.
--
--  THE SHARD IS THE SOURCE CELL BECAUSE THAT IS WHAT A SWEEP PRODUCES. Sweeping
--  cell X yields exactly one thing: X's outgoing edges. So a sweep is one small
--  property write, and two units on different cells touch different properties
--  entirely.
--
--  THE TRADE IS THAT A FULL GRAPH BUILD IS N READS RATHER THAN ONE, which would
--  be a straight loss without the per-cell memo below. With it, our own write
--  invalidates one cell instead of everything.
--
--  THE INDEX IS SEPARATE AND CHANGES RARELY. There is no way to enumerate world
--  properties, so something has to list the cells -- but it only grows when a
--  cell is FIRST swept, not on every edge, so it is nothing like as hot as the
--  blob it replaces. It also carries sweptAt, which used to live in the edge
--  table as a `swept:` key and never belonged there.
local NAV_INDEX = "petports_navindex"
local NAV_EDGES = "petports_navedges:"

--  How long a cached cell may be held before it is re-read, so ANOTHER unit's
--  discoveries eventually arrive. Our own writes invalidate precisely; nothing
--  can tell us about somebody else's, and polling every read would undo the
--  whole point of the memo.
local NAV_CACHE_TTL = 30.0

--  THE ONLY CELL SIZE IN v1.
--
--  The agreed structure is 32/16/8/4/2, derived upward from this by flood fill
--  rather than probed independently -- levels that are probed separately can
--  contradict each other and there is no principled way to resolve that. So
--  this is the only size anything ever probes, and the rest is arithmetic over
--  what it produces. None of that arithmetic is here yet.
PETPORTS_NAV_CELL = 2

--  HOW FAR APART CELL ORIGINS ARE, IN TILES. CELLS OVERLAP.
--
--  A NON-OVERLAPPING 2x2 GRID CANNOT COVER EVERY TILE, and that was measured
--  2026-09-05 rather than argued: a 7-wide shaft is three cells and one tile
--  over, and the leftover tile shares its cell with the shaft wall. The scan
--  in that cell tries the wall and a tile-centre beside the wall, both refuse,
--  and the ladder standing on that tile has no anchor anywhere. Which tile is
--  left over is decided by the parity of the shaft's x, so it cannot be tuned
--  away.
--
--  SO CELL ORIGINS ARE ONE TILE APART AND EVERY CELL IS STILL A 2x2 WINDOW.
--  Every tile is then the ORIGIN of its own window as well as a member of
--  three others, so no tile is ever only reachable through a neighbour that
--  happens to be a wall.
--
--  IDENTITY STAYS SINGLE-VALUED. A position belongs to the cell whose origin
--  is the tile it is in -- petports_navCell -- never to any of the other
--  windows that also contain it. Cell identity keys the shard property, the
--  claim id, the sweep index and navBlockKey, and each of those needs exactly
--  one answer.
--
--  WHAT IT COSTS is cells: about four times as many cell identities over the
--  same ground, and the neighbour box is measured in STRIDES, so a radius of
--  10 is a 21x21 box of candidate cells rather than 11x11. Overlapping cells
--  frequently share an anchor and their edges are one-tick trues.
PETPORTS_NAV_STRIDE = 1

--  The world position of a cell's bottom-left tile corner.
local function navCellOrigin(cx, cy)
	return cx * PETPORTS_NAV_STRIDE, cy * PETPORTS_NAV_STRIDE
end

--  DECLARED HERE, DEFINED WITH THE HIERARCHY BELOW. petports_navLearn needs
--  it and is written before it; a later `local function` would not be in
--  scope there and the call would silently hit a nil global.
local navBlockKey

--  HOW FAR APART TWO CELLS MAY BE AND STILL BE ASKED ABOUT, IN TILES.
--
--  EDGES ARE RADIAL, NOT GRID ADJACENCY, AND THE FIRST VERSION HAD THIS WRONG.
--
--  Grid adjacency assumes a DENSE node set. The anchored set is not dense: a
--  walker's cell only has an anchor if it contains a standable surface, and in
--  a real base most cells are the open air of a room. The anchored set is
--  roughly THE WALKABLE SURFACE, which is closer to one-dimensional than two.
--
--  That is good for cost -- a 200-tile base with five floors is a few hundred
--  anchored cells, not a few thousand -- and fatal for adjacency. Two floors
--  four tiles apart sit in cells N and N+2 with an ANCHORLESS N+1 between them:
--  no touching, so no edge, and no path through the gap because the gap has no
--  node. A STAIRCASE BETWEEN FLOORS WAS INVISIBLE TO THE GRAPH. Eight-way
--  adjacency does not help; the gap is vertical and bigger than one cell.
--
--  Measured 2026-09-04 by accident: a unit on a ship deck reported left and
--  right edges and had no way to express "up".
--
--  SO A PAIR IS A CANDIDATE IF BOTH CELLS ARE ANCHORED AND THE ANCHORS ARE
--  WITHIN THIS MANY TILES, whether or not the cells touch.
--
--  MEASURED BETWEEN ANCHORS, NOT CELL CENTRES, because the anchors are the
--  actual endpoints the probe will path between. A cell centre is a convenient
--  fiction and the two disagree by up to a cell.
--
--  AGAINST A 32-TILE PATH CAP, deliberately leaving room between them. The cap
--  says how far a route may WANDER; this says how far apart two things may be
--  to be worth asking about. The gap means an edge can be true via a modest
--  detour -- around a pillar, up a stair -- rather than only in a straight
--  line, which is exactly the case grid adjacency could not express.
--
--  LOWERED 16 -> 10, 2026-09-04, ON MEASURED THROUGHPUT. Twenty cells cost 899
--  probes -- about 45 pairs each, up from 38, because a denser graph means more
--  of the surrounding cells are anchored and therefore candidates. The survey
--  was simply taking too long.
--
--  PAIR COUNT GOES WITH THE AREA, NOT THE RADIUS, which is why a modest-looking
--  cut is a large one: the candidate box shrinks from 17x17 cells to 11x11, so
--  roughly 40% of the pairs remain. Expect something near 15 per cell.
--
--  WHAT IT COSTS is reach per cell -- a floor-to-floor link more than 10 tiles
--  apart now needs an intermediate cell to carry it. That is the right trade
--  while cells are cheap and plentiful, and it is the first number to raise if
--  the graph turns out to fragment across a large vertical gap.
--
--  NOW THE CEILING OF A LADDER, NOT THE ONLY RADIUS. 2026-09-05: a cell is
--  swept at PETPORTS_NAV_RADIUS_START first, and each later pass over it
--  widens by PETPORTS_NAV_RADIUS_STEP until it reaches this. The index records
--  the largest radius each cell has been swept at, and the candidate ranking
--  takes the narrowest cells first -- so no cell is swept at 6 until every
--  known cell has been swept at 4, and so on up. A pass is complete when the
--  smallest radius among candidates rises.
--
--  WHY A LADDER. The first pass at 4 is cheap -- a 9x9 box of candidate
--  cells rather than 25x25 -- and it already proves local connectivity, which
--  is what the frontier feeds on and what the skip test needs. Each wider pass
--  re-runs the same sweep with the same skip test, so a cell already swept at
--  4 pays only for the ring between 4 and 6, not for the 4 again.
--
--  THIS STAYS THE COVERAGE MARGIN. NAV_COVERAGE_MARGIN wants the WIDEST reach
--  a sweep will ever have, so that the boundary never carves anchored ground.
PETPORTS_NAV_RADIUS = 12
PETPORTS_NAV_RADIUS_START = 4
PETPORTS_NAV_RADIUS_STEP = 2

--  The radius a cell should be swept at next, given the largest radius it
--  has already been swept at. nil when it is done.
local function navNextRadius(sweptRadius)
	if (sweptRadius or 0) >= PETPORTS_NAV_RADIUS then return nil end
	if (sweptRadius or 0) <= 0 then return PETPORTS_NAV_RADIUS_START end
	return math.min(sweptRadius + PETPORTS_NAV_RADIUS_STEP, PETPORTS_NAV_RADIUS)
end

--  HOW FAR PAST NETWORK COVERAGE A SWEEP MAY BE STARTED, IN TILES.
--
--  THE SURVEY WAS UNBOUNDED AND THAT WAS AN OMISSION, not a decision. Nothing
--  consulted coverage anywhere: the frontier expanded from wherever the unit
--  stood, through any anchored cell it found, indefinitely. Given long enough
--  on one planet it would have surveyed the entire connected walkable surface
--  and filled the world properties with it.
--
--  WHAT THE SURVEY IS FOR is getting a unit from one side of a large base to
--  the other, so the ground worth knowing is the ground the network owns --
--  self.petportsNetwork, which is the UNION OF EVERY PORT'S RECT and is
--  already pushed to the unit for the leash.
--
--  INFLATED RATHER THAN CLAMPED, for the reason gatherVents is. A unit on task
--  leaves the network freely, and the ground just outside the boundary is
--  exactly what it walks onto during a real errand -- so refusing to survey it
--  would blind the structure precisely where it is most needed. The margin is
--  a sweep's own reach, so a cell started at the edge can still probe outward
--  and the boundary does not carve anchored ground in half.
--
--  IT GATES STARTING A SWEEP, NOT PROBING. Probes inside a sweep run to
--  PETPORTS_NAV_RADIUS as always, so the outermost surveyed cells still learn
--  their edges outward. Bounding the probe instead would leave a ragged frontier
--  of half-known cells at the rim.
--
--  DERIVED, NOT A SECOND LITERAL. The margin IS a sweep's own reach -- that is
--  the whole justification above -- so writing 16 in both places meant the two
--  could drift apart silently the first time either was tuned, which happened
--  the same day the margin was written.
local NAV_COVERAGE_MARGIN = PETPORTS_NAV_RADIUS

--  Is this cell close enough to the network to be worth surveying?
--
--  TRUE WHEN THERE IS NO NETWORK, matching petports_inNetwork: a unit that has
--  not been told its bounds is not thereby forbidden from working.
local function navInCoverage(cx, cy)
	local rects = self.petportsNetwork

	if type(rects) ~= "table" or #rects == 0 then return true end

	--  THE WHOLE CELL, not its centre. A cell straddling the boundary is inside
	--  it, which is the same direction the margin errs in.
	local x0, y0 = navCellOrigin(cx, cy)
	local x1 = x0 + PETPORTS_NAV_CELL
	local y1 = y0 + PETPORTS_NAV_CELL

	for _, rect in ipairs(rects) do
		if x1 >= rect[1] - NAV_COVERAGE_MARGIN
		   and x0 <= rect[3] + NAV_COVERAGE_MARGIN
		   and y1 >= rect[2] - NAV_COVERAGE_MARGIN
		   and y0 <= rect[4] + NAV_COVERAGE_MARGIN then
			return true
		end
	end

	return false
end

--  EDGES DO NOT EXPIRE ON A TIMER. THE SWEEP IS THE ONLY LIFETIME.
--
--  THREE INDEPENDENT LIFETIMES CANNOT BE MADE COHERENT, and two versions of
--  this file tried. The knobs were an edge TTL for true, another for false, and
--  NAV_SWEEP_TTL deciding when a cell is re-surveyed -- and they fight:
--
--      edges outlive sweptAt   a re-sweep finds every verdict still fresh,
--                              skips all of them, and refreshes nothing.
--      edges die first         the tree evaporates between visits.
--
--  MEASURED 2026-09-04, AND IT WAS FATAL RATHER THAN SLOW. With true edges at
--  600 seconds and a cell costing roughly 88 seconds to sweep at the unit's
--  update delta, a unit can hold about SEVEN CELLS before the first ones lapse.
--  A base needs hundreds. Observed directly: a store written at 16:22 was
--  entirely expired by 16:40, so a re-sweep that should have been nearly free
--  paid the full 1059 ticks and every log line read `EXPIRED`.
--
--  THIS IS THE SECOND TIME 600 SECONDS BROKE SOMETHING TODAY. The header above
--  already rejects it for the vent route cache, for this exact reason, and it
--  was then chosen here an hour later.
--
--  SO: ONE KNOB. An edge persists until something contradicts it or a re-sweep
--  overwrites it, and NAV_SWEEP_TTL is what decides when that happens. The two
--  align BY CONSTRUCTION rather than by tuning -- a cell becomes re-sweepable
--  at exactly the age its edges become stale, so the re-sweep re-probes them.
--
--  WHAT THIS GIVES UP: a cell nobody ever revisits keeps its edges forever,
--  wall or no wall. Accepted. petports_navForget still clears a sealed cell on
--  contact, petports_navContradict is there for a failed traversal to call, and
--  a region no unit visits is a region whose connectivity nothing is asking
--  about.

--  HOW FAR AN ADJACENCY PROBE MAY SEARCH, OVERRIDING petports_pathOptions.
--
--  THE INHERITED VALUE IS 200 AND IT IS WRONG FOR THIS QUESTION, not merely
--  slow. Two cells two tiles apart with a wall between them would send A*
--  searching two hundred tiles of base before conceding -- which is the
--  expensive long search this whole structure exists to REPLACE, performed once
--  per adjacency to build it.
--
--  IT IS A SEMANTIC CHANGE AND NOT AN OPTIMISATION, so say what a verdict means
--  now: a FALSE edge is "not connected WITHIN 32 TILES OF PATH", not "not
--  connected". Those differ, and the difference is the point. If A and B are
--  adjacent cells needing a fifty-tile detour, a direct edge claiming them
--  connected is true and useless -- the detour is real and the graph should
--  carry it as A -> C -> ... -> B, where a router can cost it.
--
--  WHICH MAKES IT SAFE ONLY BECAUSE QUERIES GO THROUGH THE GRAPH. Connectivity
--  is a flood fill over edges; the detour still connects the two regions, just
--  not directly. Reading a single edge as "can this unit get there" would turn
--  every bounded refusal into a wrongly-deleted target -- the expensive error
--  the header prices. NOTHING MAY ASK THIS STRUCTURE ABOUT ONE EDGE.
--
--  32 RATHER THAN SOMETHING TIGHTER because it is 16 cells of detour allowance
--  at the current cell size -- generous enough that ordinary furniture, a
--  doorway or a step never produces a spurious false, and bounded enough that
--  an exhausting search stays cheap.
--
--  maxNodesToSearch IS LEFT AT ITS INHERITED 70000. It is a backstop against a
--  pathological search rather than a tuning knob, and with distance capped it
--  should now be unreachable -- if it is ever hit, that is a finding about the
--  distance cap and not a reason to raise this.
local NAV_MAX_DISTANCE = 32

--  maxDistance IS NOT PATH LENGTH. MEASURED 2026-09-05 03:56: a probe under
--  this cap proved 994,1039 -> 999,1036 (five tiles apart, the deck below,
--  through the floor) with a 166-EDGE path -- west along the deck, down the
--  ladder, back east underneath. The cap bounds how far the search wanders
--  from its start, not how long the route is. So "reachable" meant "there is
--  SOME route", and the hop-counting router took one 166-edge hop over ten
--  short ones, and the unit walked twenty seconds the wrong way and timed
--  out. The comments above that say "within 32 tiles of path" were wrong.
--
--  SO A TRUE VERDICT ALSO NEEDS A SHORT PATH: at most this many edges per
--  tile of anchor distance, plus a constant for the odd step or jump. A
--  route longer than that is recorded FALSE for the pair -- which is the
--  design's own argument: a long detour belongs in the graph as the chain of
--  short hops it is made of, not as one edge that hides it.
local NAV_EDGE_STRETCH = 3
local NAV_EDGE_SLACK = 8

--  PUBLIC, 2026-09-05, BECAUSE A LEG MUST BE WALKED WITH THE SAME CAP IT WAS
--  PROVED WITH. A probe with maxDistance 32 searches a bounded box and can
--  exhaust it; the unit's pather at 200 searching the same pair has a space
--  larger than maxNodesToSearch and never finishes -- so the store says
--  REACHABLE and the walk says nothing, forever. Same start, same end, one
--  number different. A coarse leg's pather takes this cap.
PETPORTS_NAV_MAX_DISTANCE = NAV_MAX_DISTANCE

--  THE PROBE'S OPTIONS: the unit's real ones with the distance cap applied.
--
--  A COPY, NEVER A MUTATION OF A SHARED TABLE. petports_pathOptions builds a
--  fresh table per call today, so writing into it is currently harmless -- and
--  that is exactly the kind of currently-harmless that becomes a silent
--  cross-system bug the day someone memoises it. Units need maxDistance 200 to
--  cross a base; if this ever leaked into their pather they would simply stop
--  being able to, with nothing in a log to say why.
local function navPathOptions()
	local options = petports_pathOptions()
	options.maxDistance = NAV_MAX_DISTANCE
	return options
end

--  ------------------------------------------------------------------ CELLS

--  A position to its cell coordinates. Floor, so negatives behave.
function petports_navCell(position)
	if type(position) ~= "table" then return nil, nil end

	return math.floor(position[1] / PETPORTS_NAV_STRIDE),
		math.floor(position[2] / PETPORTS_NAV_STRIDE)
end

function petports_navCellKey(cx, cy)
	return tostring(cx) .. "," .. tostring(cy)
end

--  THE ANCHOR -- one canonical point per cell, and it MUST be deterministic.
--
--  THIS IS THE PART THAT MAKES OR BREAKS THE CACHE. A probe is "from the anchor
--  of A to the anchor of B", so if the anchor moves between calls the same cell
--  pair produces different verdicts and the stored answer means nothing.
--
--  THE EXISTING HELPER DOES NOT QUALIFY. findStandingPoint returns the highest
--  point in a RANDOM COLUMN -- see todo.port.findstandingpoint -- which is fine
--  for "put a unit somewhere near here" and useless for an identity.
--
--  SO THE RULE IS A FIXED SCAN: x ascending, then y ascending within each
--  column, first acceptable tile wins. Bottom-up rather than top-down because a
--  cell spanning a floor and the air above it should anchor to the floor, which
--  is where a walker can actually be.
--
--  WHAT "ACCEPTABLE" MEANS DEPENDS ON THE PROFILE, which is why this takes one.
--  A walker wants somewhere it can stand; a free mover wants somewhere it can
--  float, and asking a flyer for a standing position would anchor it to the
--  seabed or nothing at all.
--
--  A CANDIDATE IS A BODY POSITION RESTING ON A SURFACE, NOT A TILE CENTRE, AND
--  GETTING THAT WRONG MADE v1 RETURN nil EVERYWHERE.
--
--  Measured 2026-09-04: a drone standing on its own deck reported no anchor for
--  the cell it was standing in. fact.pathing.ongroundtest says why --
--  validStandingPosition CHECKS THE BODY FITS, via
--  `not rectTileCollision(boundRegion, collisionSet)`. A 1.6-tall body placed at
--  a tile centre extends 0.8 DOWN, into the floor tile it is meant to be
--  standing on, so it collides and every candidate in every cell was refused.
--
--  The logs had been saying so all along: standing units sit at y = 1146.8,
--  1152.8, 1184.8. That .8 is the bound box, not a coincidence.
--
--  SO THE CANDIDATE IS DERIVED FROM THE BOUND BOX. A tile row's BOTTOM EDGE is
--  a surface a unit could rest on; the body position that rests there is that
--  edge minus the box's lower extent. Read per call rather than hardcoded,
--  because chassis differ and a swim-mode change rewrites the box.
--
--  RETURNS nil FOR A CELL WITH NO ANCHOR -- solid rock, or open air for a
--  walker. nil is "no opinion", never "unreachable": a cell nothing can occupy
--  has no edges rather than false ones.
--
--  A REFUSAL SAYS WHY, in a second return. fact.tooling.mergedrefusal: the bare
--  nil this returned before was indistinguishable from "cell is solid", which
--  is exactly how a wrong candidate rule survived a full test round.
--  IS EVERY TILE IN THIS CELL SOLID?
--
--  A CHEAP REFUSAL AHEAD OF AN EXPENSIVE ONE. petports_navAnchor should already
--  return nil for solid rock -- validStandingPosition checks the body FITS, and
--  a body placed inside stone does not -- but it costs up to four rect tests
--  against a 1.6-tile body to find that out, per candidate cell, across a
--  121-cell box. This is four POINT tests and short-circuits on the first gap.
--
--  UNDERGROUND THAT IS MOST OF THE BOX, so the saving is not marginal: a
--  neighbour scan in rock goes from ~480 rect tests to ~480 point tests, and
--  the point tests stop early.
--
--  IT MAY ALSO BE CATCHING SOMETHING THE ANCHOR RULE MISSES. Reported from play
--  2026-09-05: probes running to exhaustion on cells "full of solid blocks",
--  which by the reasoning above should never have produced an anchor to probe
--  toward. If NAV solid refusals appear in the log at all, that premise is
--  wrong somewhere and the anchor scan is what wants looking at -- so this logs
--  rather than passing silently.
--
--  Platform IS ABSENT deliberately: a platform is a floor, not a wall, and a
--  cell of platforms is somewhere a unit can stand. Dynamic is present because
--  fact.pathing.collisionkinds says Dynamic is DOORS, and a cell that is
--  entirely closed door is entirely impassable while it stays shut.
local NAV_SOLID_SET = { "Null", "Block", "Dynamic", "Slippery" }

local function navCellSolid(cx, cy)
	local baseX, baseY = navCellOrigin(cx, cy)

	for dx = 0, PETPORTS_NAV_CELL - 1 do
		for dy = 0, PETPORTS_NAV_CELL - 1 do
			local ok, hit = pcall(world.pointTileCollision,
				{ baseX + dx + 0.5, baseY + dy + 0.5 }, NAV_SOLID_SET)

			--  A READ THAT FAILS IS NOT A SOLID TILE. Unloaded terrain answers
			--  Null, which IS in the set -- but a pcall that threw answers
			--  nothing, and treating that as solid would silently delete cells
			--  whenever the engine was unhappy rather than the world being full.
			if not ok or hit ~= true then return false end
		end
	end

	return true
end

--  WHAT A WALKER MAY REST ON. The same set petportsTaskAction uses for the
--  question -- Platform in, Dynamic (doors) and Null (unloaded) out.
local NAV_FOOTING_SET = { "Block", "Slippery", "Platform" }

--  A WALKER'S ANCHOR STANDS ON THE CELL'S OWN GROUND, 2026-09-05.
--
--  validStandingPosition accepts footing anywhere under the 1.6-wide bound
--  box, which overhangs 0.3 into each neighbouring column. So a cell with no
--  floor of its own could anchor on the edge of a platform in the NEXT cell --
--  and the engine's pathfinder, asked to start or end there, fails at once:
--  it wants ground beneath the body inside the space it was given. The anchor
--  claimed a surface the cell did not contain.
--
--  THE RULE: the feet are on the cell's bottom edge, and the row beneath the
--  cell must hold something standable under the part of the body that is
--  inside the cell's columns. Ground in a neighbouring column does not count,
--  however much of the box hangs over it.
--
--  ONE ROW OF CANDIDATES, NOT TWO. With cell origins one tile apart (05c),
--  every row is the bottom edge of some cell, so a candidate standing on a
--  tile INSIDE the window is just the anchor of the cell below, again. The
--  second row only ever produced duplicates -- 688 identical-anchor probes in
--  the 02:04 log -- and each duplicate cost a pair.
local function navFootingUnderCell(x, baseX, baseY, bounds)
	--  The body's footprint clipped to the cell's columns, pulled in a little
	--  so a shared edge does not read as overlap.
	local left = math.max(baseX, x + bounds[1]) + 0.05
	local right = math.min(baseX + PETPORTS_NAV_CELL, x + bounds[3]) - 0.05

	if right <= left then return false end

	local ok, hit = pcall(world.rectTileCollision,
		{ left, baseY - 0.95, right, baseY - 0.05 }, NAV_FOOTING_SET)

	return ok and hit == true
end

function petports_navAnchor(cx, cy, freeMover)
	local baseX, baseY = navCellOrigin(cx, cy)

	local bounds = mcontroller.boundBox()

	--  How far the body position sits ABOVE its own feet. bounds[2] is the
	--  lower extent and is negative, so this is a positive lift.
	local lift = -(bounds[2] or -0.5)

	local tried = 0

	if freeMover then
		for dx = 0, PETPORTS_NAV_CELL - 1 do
			for dy = 0, PETPORTS_NAV_CELL - 1 do
				--  CENTRE OF THE TILE, because a free mover is not resting on
				--  anything -- there is no surface to lift off.
				--
				--  THE WHOLE BODY, NOT A POINT. pointTileCollision would pass a
				--  flyer through a one-tile gap it cannot fit in. Platform is
				--  absent from the set deliberately: a platform is passable to
				--  something that ignores gravity. Dynamic is present because
				--  fact.pathing.collisionkinds says Dynamic is DOORS, and a
				--  closed door stops a flyer.
				local point = { baseX + dx + 0.5, baseY + dy + 0.5 }
				local region = {
					point[1] + bounds[1], point[2] + bounds[2],
					point[1] + bounds[3], point[2] + bounds[4]
				}

				tried = tried + 1

				local ok, hit = pcall(world.rectTileCollision, region,
					{ "Null", "Block", "Dynamic", "Slippery" })

				--  AND THE MEDIUM, as for a walker: a flyer's anchor in water
				--  it cannot enter is a node it can never reach.
				if ok and hit == false then
					local okMedium, allowed = pcall(petports_mediumAllows, point, bounds)

					if not okMedium or allowed ~= false then return point end
				end
			end
		end
	else
		for dx = 0, PETPORTS_NAV_CELL - 1 do
			local x = baseX + dx + 0.5

			--  FEET ON THE CELL'S BOTTOM EDGE; the body rests `lift` above it.
			local point = { x, baseY + lift }

			tried = tried + 1

			--  THE CELL'S OWN GROUND FIRST -- one rect test -- then the body
			--  fit, then THE MEDIUM. validStandingPosition is called with
			--  avoidLiquid false so a sinker's seabed still counts, which
			--  means it says nothing about whether THIS chassis may be in
			--  the liquid standing there. petports_mediumAllows is the
			--  chassis's own answer (module liquids, swim capability), and
			--  it is the same predicate the task action uses before sending
			--  a unit anywhere. Seen 2026-09-05: a plain ground unit on an
			--  ocean world surveying the seabed.
			if navFootingUnderCell(x, baseX, baseY, bounds) then
				local ok, standable = pcall(validStandingPosition, point, false)

				if ok and standable == true then
					local okMedium, allowed = pcall(petports_mediumAllows, point, bounds)

					if not okMedium or allowed ~= false then return point end
				end
			end
		end
	end

	return nil, string.format(
		"no anchor in cell %s,%s -- %s candidate(s) tried, freeMover %s, lift %s",
		tostring(cx), tostring(cy), tostring(tried), tostring(freeMover),
		tostring(lift))
end

--  EVERY CELL WORTH ASKING THIS ONE ABOUT.
--
--  A PLAIN RADIAL SCAN, CHOSEN OVER A CLEVERER ONE ON PURPOSE. The efficient
--  alternative is to run ONE search from a cell and read which anchored cells
--  its closed set reached, learning many edges per probe. That may well work,
--  and it depends on PathFinder internals that have not been read -- so it is
--  not what a foundational structure gets built on. This is O(n^2) locally and
--  obvious; the other is fast and would have to be trusted.
--
--  DETERMINISTIC ORDER, x ascending then y ascending, for the same reason the
--  anchor scan is: a caller that walks this list must walk it the same way
--  twice or the sweep is not reproducible.
--
--  RETURNS CELLS AND THEIR ANCHORS, because the caller would otherwise recompute
--  every one of them and the anchor scan is the expensive part of this function
--  -- up to four validStandingPosition calls per candidate cell.
--
--  THE SOURCE CELL IS EXCLUDED. A self-edge answers a question nobody asks.
function petports_navNeighbours(cx, cy, freeMover, radius)
	--  THE RADIUS IS THE CALLER'S. A sweep passes the rung of the ladder it is
	--  on; anything else gets the ceiling.
	radius = radius or PETPORTS_NAV_RADIUS

	local origin = petports_navAnchor(cx, cy, freeMover)
	if origin == nil then return {}, nil end

	--  Cells that COULD hold something within the radius. Rounded up, then
	--  filtered by true anchor distance below -- the box is a cheap prefilter
	--  and the distance test is the actual rule.
	local reach = math.ceil(radius / PETPORTS_NAV_STRIDE)

	local found = {}
	local solid = 0

	for dx = -reach, reach do
		for dy = -reach, reach do
			if dx ~= 0 or dy ~= 0 then
				local nx, ny = cx + dx, cy + dy

				--  SOLID FIRST, ANCHOR SECOND. The cheap test gates the dear
				--  one; see navCellSolid for why that ordering is most of the
				--  saving in a neighbour scan.
				local anchor = nil

				if navCellSolid(nx, ny) then
					solid = solid + 1
				else
					anchor = petports_navAnchor(nx, ny, freeMover)
				end

				if anchor ~= nil then
					local ax = anchor[1] - origin[1]
					local ay = anchor[2] - origin[2]

					local distance = math.sqrt(ax * ax + ay * ay)

					if distance <= radius then
						table.insert(found, {
							cx = nx, cy = ny,
							anchor = anchor,
							distance = distance,
							key = petports_navCellKey(nx, ny)
						})
					end
				end
			end
		end
	end

	--  NEAREST FIRST, AND IT IS THE DIFFERENCE BETWEEN A TREE THAT BUILDS AND
	--  ONE THAT DOES NOT.
	--
	--  Measured 2026-09-04 on a ship deck: 38 pairs, 2.51 seconds, and the 12
	--  FALSE verdicts cost 77% of it -- 78 to 79 ticks each, against 1 tick for
	--  a near TRUE. The expensive pairs are the far ones, and the far ones are
	--  mostly the redundant ones: a cell that is already attached to its
	--  component through a near neighbour needs no long edge to prove it again.
	--
	--  So a caller walking this list in order and stopping when the cell is
	--  connected pays the cheap probes and skips the dear ones. Walking it in
	--  scan order pays them in whatever sequence the grid happens to produce.
	--
	--  TIE-BROKEN ON THE CELL KEY, so equidistant cells still order the same
	--  way twice. table.sort is NOT stable, so without this a sweep would not
	--  be reproducible and neither would a log of it.
	table.sort(found, function(a, b)
		if a.distance ~= b.distance then return a.distance < b.distance end
		return a.key < b.key
	end)

	sb.logInfo("NAV neighbours of %s at radius %s: %s candidate(s), "
		.. "%s solid cell(s) skipped",
		petports_navCellKey(cx, cy), sb.printJson(radius), sb.printJson(#found),
		sb.printJson(solid))

	return found, origin
end

--  ------------------------------------------------------- CAPABILITY PROFILE

--  WHO THIS ANSWER IS FOR.
--
--  A REACHABILITY VERDICT IS NOT A FACT ABOUT THE WORLD ALONE. Two units of the
--  same monstertype can genuinely disagree about whether A reaches B, and the
--  disagreement is not symmetric in cost:
--
--      a lava-capable unit teaches CONNECTED, a plain one reads it
--          -> the plain unit is dispatched into lava. This kills pets.
--      a plain unit teaches NOT CONNECTED, a lava-capable one reads it
--          -> routes silently vanish for a unit that had them.
--
--  So the store is keyed by CAPABILITY, never by monstertype alone.
--
--  A HASH OF A SORTED DESCRIPTION, NOT CONCATENATED FIELDS. There will be a
--  fourth dimension and then a fifth -- the door-opening flag is already
--  proposed -- and a positional key silently mis-buckets when one is added,
--  while a described one just produces a different profile and rebuilds. The
--  cost of rebuilding is bounded; the cost of a wrong shared answer is a dead
--  unit.
--
--  DOORS ARE NAMED HERE ALREADY, reading nil until the flag exists, so adding
--  it later changes the profile string and invalidates exactly the entries that
--  should be invalidated. Wiring the option into petports_pathOptions is a
--  separate change and the engine's spelling for it has NOT been read from
--  source yet -- do not guess it.
function petports_navProfile()
	local monsterType = world.monsterType(entity.id())
	local freeMover = petports_freeMover()

	--  SORTED, because pairs() order is not stable across contexts and a key
	--  that reorders is a key that misses.
	local liquids = {}
	for name in pairs(self.petportsModuleLiquids or {}) do
		table.insert(liquids, tostring(name))
	end
	table.sort(liquids)

	--  THE BODY, because a bigger unit fits through fewer gaps and that is a
	--  reachability difference exactly like a liquid permission.
	local bounds = mcontroller.boundBox()

	return string.format("%s|f%s|b%s|l%s|d%s",
		tostring(monsterType),
		freeMover and "1" or "0",
		string.format("%.2f,%.2f",
			(bounds[3] or 0) - (bounds[1] or 0),
			(bounds[4] or 0) - (bounds[2] or 0)),
		table.concat(liquids, "+"),
		tostring(config.getParameter("petports_canOpenDoors", nil)))
end

--  ------------------------------------------------------------------ STORE

local function navEdgeKey(fromKey, toKey)
	return fromKey .. ">" .. toKey
end

local function navIndexRead()
	local ok, index = pcall(world.getProperty, NAV_INDEX)
	if not ok or type(index) ~= "table" then return {} end
	return index
end

local function navIndexWrite(index)
	pcall(world.setProperty, NAV_INDEX, index)
end

local function navCellProperty(profile, cellKey)
	return NAV_EDGES .. profile .. ":" .. cellKey
end

--  ONE CELL'S OUTGOING EDGES, memoised on the unit.
--
--  THE MEMO IS WHAT MAKES SHARDING PAY. Without it, rebuilding the graph would
--  be one property read per cell where it used to be one read total. With it, a
--  rebuild after our own write re-reads exactly the cell we wrote.
local function navCellRead(profile, cellKey)
	self.petportsNavCellCache = self.petportsNavCellCache or {}
	self.petportsNavCacheAt = self.petportsNavCacheAt or world.time()

	if (world.time() - self.petportsNavCacheAt) > NAV_CACHE_TTL then
		self.petportsNavCellCache = {}
		self.petportsNavCacheAt = world.time()
		self.petportsNavGraph = nil
	end

	local key = navCellProperty(profile, cellKey)
	local held = self.petportsNavCellCache[key]

	if held ~= nil then return held end

	local ok, edges = pcall(world.getProperty, key)
	if not ok or type(edges) ~= "table" then edges = {} end

	self.petportsNavCellCache[key] = edges

	return edges
end

local function navCellWrite(profile, cellKey, edges)
	local key = navCellProperty(profile, cellKey)

	pcall(world.setProperty, key, edges)

	self.petportsNavCellCache = self.petportsNavCellCache or {}
	self.petportsNavCellCache[key] = edges

	self.petportsNavVersion = (self.petportsNavVersion or 0) + 1
	self.petportsNavGraph = nil
end

--  self.petportsNavVersion IS BUMPED BY navCellWrite AND IS WHAT MAKES THE
--  DERIVED GRAPHS SAFE TO MEMOISE. Deriving the coarse levels costs a pass over
--  the edge set, so doing it per query would cost more than the fine BFS it
--  replaces.
--
--  ON `self`, NOT IN THE STORE. It counts writes THIS unit has seen, so another
--  unit's write does not invalidate our memo -- a real staleness window, and an
--  accepted one: the derived graph is used to REJECT targets, an edge we have
--  not seen can only make something MORE reachable, and missing one costs a
--  probe rather than a wrong answer. NAV_CACHE_TTL is the backstop that lets
--  another unit's work arrive eventually.

--  ------------------------------------------------------------- THE BATCH
--
--  EVERY LEARNED EDGE USED TO SERIALISE THE WHOLE TREE, TWICE.
--
--  petports_navLearn read the entire structure out of the world property,
--  changed one key, and wrote the entire structure back. Thirty-eight edges
--  from one cell sweep meant thirty-eight full round trips -- and the cost GROWS
--  WITH THE THING BEING BUILT, because the store gets larger as the tree fills.
--  Multiply by every deployed unit of a profile and that is the real ceiling,
--  not probe cost. The 2.51-second sweep measured on 2026-09-04 was against a
--  nearly empty store and so never saw it.
--
--  SO EDGES LAND ON THE UNIT AND GO OUT IN GROUPS. Two triggers, because either
--  alone has a bad case: a count alone leaves the last few edges of a finished
--  sweep sitting in memory indefinitely, and an interval alone lets a fast
--  sweep pile up unboundedly between flushes.
local NAV_FLUSH_EDGES = 25
local NAV_FLUSH_INTERVAL = 5.0

--  A FLUSH IS READ-MODIFY-WRITE AND THAT IS SAFE HERE, which is worth stating
--  because it normally would not be. Two units of one profile flushing
--  overlapping regions would ordinarily race -- both read, both write, the first
--  one's edges lost -- and batching makes the window wider. It does not happen
--  because the read, the merge and the write are one uninterrupted Lua call:
--  entity scripts do not interleave, and world properties are synchronous. The
--  merge applies only OUR pending deltas onto whatever is in the store at flush
--  time, so a concurrent unit's edges survive.
--
--  DO NOT REWRITE THIS AS "read once, write later". That is the version that
--  loses another unit's work, and it looks tidier.
local function navPendingFor(profile)
	local pending = self.petportsNavPending
	if type(pending) ~= "table" then return nil end
	return pending[profile]
end

function petports_navFlush()
	local pending = self.petportsNavPending

	if type(pending) ~= "table" or next(pending) == nil then
		return 0
	end

	local written, shards = 0, 0

	--  GROUPED BY SOURCE CELL, so a flush spanning three cells is three small
	--  writes rather than one whole-tree rewrite. A sweep almost always
	--  produces exactly one group, since every edge it learns leaves the cell
	--  being swept.
	for profile, edges in pairs(pending) do
		local byCell = {}

		for key, entry in pairs(edges) do
			local from, to = string.match(key, "^(.-)>(.*)$")

			if from ~= nil then
				byCell[from] = byCell[from] or {}
				byCell[from][to] = entry
				written = written + 1
			end
		end

		for cellKey, learned in pairs(byCell) do
			local stored = navCellRead(profile, cellKey)

			--  A COPY, because navCellRead hands back the memoised table and
			--  mutating it in place would leave the cache correct only by luck
			--  if the write below failed.
			local merged = {}
			for to, entry in pairs(stored) do merged[to] = entry end
			for to, entry in pairs(learned) do merged[to] = entry end

			navCellWrite(profile, cellKey, merged)
			shards = shards + 1
		end
	end

	self.petportsNavPending = {}
	self.petportsNavPendingCount = 0
	self.petportsNavFlushAt = world.time() + NAV_FLUSH_INTERVAL

	sb.logInfo("NAV flushed %s edge(s) across %s cell(s)",
		sb.printJson(written), sb.printJson(shards))

	return written
end

--  DIRECTIONAL, ALWAYS. A drop from A to B does not imply a climb from B to A,
--  and a one-way ledge is the single most common shape in a player's base. Two
--  entries, never one with a symmetry assumption.
--
--  Returns true, false, or nil for "not known". nil is NOT false -- see the
--  optimism note in the header.
function petports_navKnown(profile, fromKey, toKey)
	local key = navEdgeKey(fromKey, toKey)

	--  THE BATCH FIRST, BECAUSE IT IS NEWER. An edge learned this sweep and not
	--  yet flushed must be visible immediately -- the skip test in a sweep is
	--  built on reading back what the sweep just learned, and a read that saw
	--  only the store would make every edge of a sweep invisible to the rest of
	--  it. That is precisely the transitivity the ordering exists to exploit.
	local pending = navPendingFor(profile)
	local entry = pending ~= nil and pending[key] or nil

	if type(entry) ~= "table" then
		entry = navCellRead(profile, fromKey)[toKey]
	end

	if type(entry) ~= "table" then return nil end

	--  THE AGE IS RETURNED, NOT ACTED ON. Freshness is a caller's question:
	--  a sweep wants to know whether to re-probe, a router does not care. An
	--  expiry decided here would be the third lifetime all over again.
	return entry.r, world.time() - (entry.t or 0)
end

--  A CELL CAN NO LONGER BE OCCUPIED, SO EVERY EDGE TOUCHING IT IS MEANINGLESS.
--
--  AN ANCHORLESS CELL IS STRONGER EVIDENCE THAN A FAILED PATH, not weaker. A
--  path failure says "I could not get there just now"; this says "nothing of
--  this shape can BE there at all", which is a durable fact about terrain. The
--  edges are not wrong, they are void -- so they are dropped rather than set
--  false, and a later probe starts clean.
--
--  SKIPPING INSTEAD WAS THE BUG. Returning nil and writing nothing left stale
--  TRUE edges asserting a unit could walk out of a box that had just been built
--  around it.
--
--  MATCHED ON THE SPLIT KEY, NEVER A SUBSTRING. Cell "490,519" is a substring
--  of "1490,519", and a string.find here would quietly delete a neighbour's
--  edges every time a base grew past ten cells in x.
function petports_navForget(profile, cellKey)
	--  THE BATCH TOO, AND FIRST. Forgetting only the store would leave an edge
	--  the sweep learned moments ago waiting in memory to be written back after
	--  the cell was found to be sealed -- resurrecting exactly what this call
	--  exists to remove.
	local pending = navPendingFor(profile)

	if pending ~= nil then
		for key in pairs(pending) do
			local from, to = string.match(key, "^(.-)>(.*)$")
			if from == cellKey or to == cellKey then
				pending[key] = nil
				self.petportsNavPendingCount =
					math.max((self.petportsNavPendingCount or 1) - 1, 0)
			end
		end
	end

	--  EAGER ON THE STORE, unlike a learn. This is a correctness action rather
	--  than an accumulation, it is rare, and deferring it would leave the tree
	--  asserting a route through a sealed cell for up to a flush interval.
	--
	--  OUTGOING EDGES ONLY, AND INBOUND ONES ARE LEFT STALE ON PURPOSE. Sharding
	--  by source cell means edges POINTING AT this one are scattered across
	--  every other cell's property, and finding them would mean reading the
	--  whole index -- turning the cheapest correctness action into the most
	--  expensive read in the file.
	--
	--  IT IS SAFE TO LEAVE THEM because a stale inbound edge is a wrong TRUE,
	--  the cheap direction, and it is barely even that: the cell has no anchor,
	--  so nothing can be dispatched to it and any probe or traversal aimed there
	--  fails immediately. It also self-corrects, since the next sweep of the
	--  source cell re-probes and finds no anchor.
	local dropped = 0

	for _ in pairs(navCellRead(profile, cellKey)) do
		dropped = dropped + 1
	end

	local index = navIndexRead()

	if type(index[profile]) == "table" and index[profile][cellKey] ~= nil then
		index[profile][cellKey] = nil
		navIndexWrite(index)
	end

	if dropped > 0 or index[profile] ~= nil then
		sb.logInfo("NAV cell %s SEALED for %s -- dropped %s outgoing edge(s)",
			tostring(cellKey), tostring(profile), sb.printJson(dropped))

		--  navCellWrite bumps the version, which drops the derived graphs. A
		--  sealed cell that stayed in a memoised coarse level would keep
		--  answering for edges that no longer exist.
		navCellWrite(profile, cellKey, {})
	end

	return dropped
end

function petports_navLearn(profile, fromKey, toKey, reachable)
	self.petportsNavPending = self.petportsNavPending or {}
	self.petportsNavPending[profile] = self.petportsNavPending[profile] or {}

	local key = navEdgeKey(fromKey, toKey)

	--  The previous value from wherever it currently lives, so a contradiction
	--  is still detected across a flush boundary.
	local previous = self.petportsNavPending[profile][key]

	if type(previous) ~= "table" then
		previous = navCellRead(profile, fromKey)[toKey]
	end

	--  CONTRADICTIONS ARE LOGGED, NEVER SWALLOWED. A verdict that flips is
	--  either the world changing under us -- which is expected and fine -- or
	--  the anchor rule being non-deterministic, which would make the whole
	--  structure meaningless. The two are indistinguishable without this line,
	--  and telling them apart is one of the two questions v1 exists to answer.
	if type(previous) == "table" and previous.r ~= reachable then
		sb.logInfo("NAV edge %s CONTRADICTED for %s: was %s, now %s",
			key, tostring(profile), tostring(previous.r), tostring(reachable))
	end

	self.petportsNavPending[profile][key] = { r = reachable, t = world.time() }

	--  INTO THE MEMOISED GRAPH NOW, NOT AT THE NEXT FLUSH.
	--
	--  MEASURED 2026-09-05, 02:04 LOG: probes per sweep equalled candidates
	--  per sweep -- median 17 and 17 -- across 721 sweeps. The skip test was
	--  skipping nothing. navGraphFor memoises on petportsNavVersion, which
	--  only navCellWrite bumps, so an edge learned two ticks ago sat in the
	--  pending batch invisible to petports_navReaches until a flush. The
	--  comment in navAdjacency says a sweep must see its own work; it did not.
	--
	--  INSERTED RATHER THAN INVALIDATED. Dropping the memo would rebuild it
	--  on the next skip test -- a pass over every shard and every edge, per
	--  probe. Adding one edge to the fine list and the coarse sets is the same
	--  arithmetic navGraphFor does for that edge, done once.
	local graph = self.petportsNavGraph

	--  A FALSE LEAVES THE MEMO AT ONCE TOO. Measured 03:30: a contradicted
	--  edge stayed in the memoised fine list until the next flush, so the
	--  re-plan chose it again, six seconds at a time. The coarse sets are
	--  left as they are; they are optimistic by construction.
	if reachable == false and graph ~= nil and graph.profile == profile
	   and graph.fine[fromKey] ~= nil then
		for i = #graph.fine[fromKey], 1, -1 do
			if graph.fine[fromKey][i] == toKey then
				table.remove(graph.fine[fromKey], i)
			end
		end
	end

	if reachable == true then
		if graph ~= nil and graph.profile == profile then
			graph.fine[fromKey] = graph.fine[fromKey] or {}

			local present = false
			for _, to in ipairs(graph.fine[fromKey]) do
				if to == toKey then present = true break end
			end

			if not present then
				table.insert(graph.fine[fromKey], toKey)

				for tiles, bucket in pairs(graph.coarse) do
					local a = navBlockKey(fromKey, tiles)
					local b = navBlockKey(toKey, tiles)

					if a ~= nil and b ~= nil and a ~= b then
						bucket[a] = bucket[a] or {}
						bucket[a][b] = true
					end
				end
			end
		end
	end

	self.petportsNavPendingCount = (self.petportsNavPendingCount or 0) + 1
	self.petportsNavFlushAt = self.petportsNavFlushAt
		or (world.time() + NAV_FLUSH_INTERVAL)

	if self.petportsNavPendingCount >= NAV_FLUSH_EDGES
	   or world.time() >= self.petportsNavFlushAt then
		petports_navFlush()
	end
end

--  THE CORRECTION HOOK, AND NOTHING CALLS IT YET.
--
--  A true edge is permanent, so the ONLY thing that can retire one is a unit
--  discovering it was wrong -- walking the edge and failing. That belongs in
--  the task action's failure path and is deliberately not wired in v1, because
--  wiring it before the prober is measured means debugging two things at once.
--  Stated here so the gap is visible rather than implied.
function petports_navContradict(profile, fromKey, toKey)
	petports_navLearn(profile, fromKey, toKey, false)
end

--  RE-PROBE ONE EDGE TO COMPLETION, RIGHT NOW. Diagnostic, 2026-09-05.
--
--  A leg the unit could not walk is either an edge the world has since
--  closed, or a disagreement between the probe's search and the walk's --
--  and those need opposite fixes. This runs the exact probe the store was
--  built with, for the exact pair, and returns its verdict and tick count.
--  The verdict is learned as a side effect of petports_navProbeStep, so a
--  stale true is replaced with the current truth rather than a blind false.
--
--  DRIVEN TO COMPLETION IN ONE CALL, on a slot no sweep uses. The spin cap
--  is a hang guard. This is a frame hitch on purpose and only runs when a
--  leg has already cost SEARCH_LIMIT seconds.
local NAV_VERIFY_SLOT = 999

function petports_navVerify(fromKey, toKey)
	local fx, fy = string.match(fromKey, "^(-?%d+),(-?%d+)$")
	local tx, ty = string.match(toKey, "^(-?%d+),(-?%d+)$")
	if fx == nil or tx == nil then return nil, 0 end

	local verdict, spins = "searching", 0

	while verdict == "searching" and spins < 500 do
		verdict = petports_navProbeStep(
			{ tonumber(fx), tonumber(fy) }, { tonumber(tx), tonumber(ty) },
			300, NAV_VERIFY_SLOT)
		spins = spins + 1
	end

	if self.petportsNavProbes ~= nil then
		self.petportsNavProbes[NAV_VERIFY_SLOT] = nil
	end

	return verdict, spins
end

--  ------------------------------------------------------------------ PROBE

--  ITS OWN SLOT ON `self`, NOT petportsProbe.
--
--  The vent prober owns self.petportsProbe and restarts itself whenever the
--  from/to pair changes -- so sharing the slot would mean the two systems
--  discarding each other's progress every tick, each blaming the other. This is
--  the most literal form of "do not staple it onto the vent system".
--
--  DRIVES start/explore DIRECTLY, which is the one mechanism worth taking from
--  the vent prober because it is non-obvious: PathFinder:find hardcodes
--  mcontroller.position() as its source, so it cannot answer "is X reachable
--  FROM somewhere else". start() takes an arbitrary source and can.
--
--  RETURNS true, false, or "searching". Incremental across ticks, one explore
--  budget per call, exactly like the vent prober -- a unit stays responsive
--  while this runs.
--  `slot` LETS ONE UNIT RUN SEVERAL PROBES AT ONCE.
--
--  IT WAS A SINGLE FIELD ON `self` AND THAT WAS THE WHOLE BLOCKER. This
--  function restarts its search whenever the from/to pair changes, so two
--  concurrent probes sharing one slot would each discard the other's progress
--  every tick and neither would ever finish -- silently, since a restart is a
--  normal event and only logs at Info.
--
--  DEFAULTS TO 1, so the self test and any single-probe caller are unchanged.
function petports_navProbeStep(fromCell, toCell, exploreRate, slot)
	stampOnce()

	slot = slot or 1

	local freeMover = petports_freeMover()

	local fromKey = petports_navCellKey(fromCell[1], fromCell[2])
	local toKey = petports_navCellKey(toCell[1], toCell[2])

	self.petportsNavProbes = self.petportsNavProbes or {}

	local probe = self.petportsNavProbes[slot]

	if probe == nil or probe.fromKey ~= fromKey or probe.toKey ~= toKey then
		local from, fromWhy = petports_navAnchor(fromCell[1], fromCell[2], freeMover)
		local to, toWhy = petports_navAnchor(toCell[1], toCell[2], freeMover)

		--  NO ANCHOR IS NOT UNREACHABLE. A cell of solid rock has nothing to
		--  path to or from, and recording false would assert something about
		--  connectivity that was never tested. nil, and nothing is stored.
		--  A SECOND GATE, AT THE ONLY OTHER DOOR. petports_navNeighbours filters
		--  solid cells out of a sweep, but a probe can also be driven directly
		--  -- the self test does it, and a future router might -- and the cost
		--  of a wasted exhaustion is 78 ticks either way.
		if navCellSolid(fromCell[1], fromCell[2])
		   or navCellSolid(toCell[1], toCell[2]) then
			sb.logInfo("NAV probe %s -> %s SKIPPED: a cell is solid", fromKey, toKey)
			self.petportsNavProbes[slot] = nil
			return nil
		end

		if from == nil or to == nil then
			sb.logInfo("NAV probe %s -> %s SKIPPED: %s",
				fromKey, toKey, tostring(from == nil and fromWhy or toWhy))

			--  AND FORGET WHATEVER THE SEALED CELL USED TO CLAIM. See
			--  petports_navForget: skipping here is what let a boxed-in unit
			--  keep two reachable edges.
			local profile = petports_navProfile()
			if from == nil then petports_navForget(profile, fromKey) end
			if to == nil then petports_navForget(profile, toKey) end

			self.petportsNavProbes[slot] = nil
			return nil
		end

		local finder = PathFinder:new(navPathOptions())
		finder.exploreRate = function() return exploreRate or 300 end
		finder:start(from, to)

		sb.logInfo("NAV probe START %s -> %s: %s to %s (profile %s, rate %s, maxDistance %s)",
			fromKey, toKey, sb.printJson(from), sb.printJson(to),
			tostring(petports_navProfile()), sb.printJson(exploreRate or 300),
			sb.printJson(NAV_MAX_DISTANCE))

		self.petportsNavProbes[slot] = {
			finder = finder,
			fromKey = fromKey,
			toKey = toKey,
			--  KEPT FOR THE DEBUG DRAW, which runs on a later tick than this
			--  and cannot re-derive them cheaply -- an anchor is up to four
			--  validStandingPosition calls and re-running it per frame would
			--  make the overlay cost more than the survey.
			fromCell = { fromCell[1], fromCell[2] },
			toCell = { toCell[1], toCell[2] },
			fromAnchor = from,
			toAnchor = to,
			ticks = 0,
			started = world.time()
		}

		probe = self.petportsNavProbes[slot]
	end

	probe.ticks = probe.ticks + 1

	local result = probe.finder.aStar:explore(exploreRate or 300)

	--  THE PATH LENGTH, ON A TRUE. aStar:result() is the engine's edge list
	--  for the solved search; read through pcall so a binding surprise is a
	--  logged unknown rather than a dead probe.
	local edgeCount = nil

	if result == true then
		local ok, edges = pcall(function() return probe.finder.aStar:result() end)

		if ok and type(edges) == "table" then
			edgeCount = #edges
		else
			sb.logInfo("NAV probe %s -> %s: aStar:result() unavailable (%s)",
				fromKey, toKey, tostring(edges))
		end

		if edgeCount ~= nil and probe.fromAnchor ~= nil
		   and probe.toAnchor ~= nil then
			local span = world.magnitude(probe.fromAnchor, probe.toAnchor)
			local limit = span * NAV_EDGE_STRETCH + NAV_EDGE_SLACK

			if edgeCount > limit then
				sb.logInfo("NAV probe %s -> %s TOO LONG: %s edge(s) for %s "
					.. "tile(s) apart (limit %s) -- recorded as unreachable",
					fromKey, toKey, sb.printJson(edgeCount),
					sb.printJson(math.floor(span * 10 + 0.5) / 10),
					sb.printJson(math.floor(limit)))
				result = false
			end
		end
	end

	if result == true or result == false then
		--  THE COST, WHICH IS THE WHOLE POINT OF v1. Ticks AND seconds, because
		--  the two answer different questions: ticks say how much A* work an
		--  adjacency costs, seconds say what it costs the player watching.
		--  TICKS ONLY. An earlier version printed seconds too and printed 0
		--  every time: world.time() advances BETWEEN FRAMES, and a probe driven
		--  to completion inside one frame -- which is what an eval loop does,
		--  and what a fast probe does anyway -- never sees it move. A timing
		--  field that is structurally always zero is worse than no field, so it
		--  is gone. Wall-clock cost is read off the log timestamps instead:
		--  measured 2026-09-04, ~1ms for a TRUE and ~162ms for a FALSE.
		sb.logInfo("NAV probe %s -> %s %s after %s tick(s), %s edge(s)",
			fromKey, toKey,
			result and "REACHABLE" or "UNREACHABLE",
			sb.printJson(probe.ticks), tostring(edgeCount))

		petports_navLearn(petports_navProfile(), fromKey, toKey, result)

		self.petportsNavProbes[slot] = nil
		return result
	end

	return "searching"
end

--  ----------------------------------------------------------- CONNECTIVITY

--  THE LIVE TRUE EDGES FOR ONE PROFILE, AS AN ADJACENCY LIST.
--
--  ONLY TRUE EDGES ARE TRAVERSABLE, AND A FALSE EDGE IS NOT A WALL -- IT IS
--  ABSENCE. A graph with a false edge behaves exactly like a graph with no
--  edge, because the answer "not connected within 32 tiles of path" says
--  nothing about whether a longer route exists through other cells. Falses are
--  memoised only so the prober does not ask twice.
--
--  EXPIRED ENTRIES ARE SKIPPED, NOT DELETED. Reading must not write: this runs
--  inside reachability queries that may be called many times a tick, and a
--  store write per read would be the ceiling all over again.
local function navAdjacency(profile)
	local index = navIndexRead()
	local cells = index[profile]
	local out = {}

	--  THE INDEX NAMES THE CELLS, then one shard read per cell -- each memoised,
	--  so a rebuild after our own write re-reads exactly the one cell we wrote.
	--  The other reads come back from the cache until NAV_CACHE_TTL lapses.
	local edges = {}

	for cellKey in pairs(type(cells) == "table" and cells or {}) do
		for to, entry in pairs(navCellRead(profile, cellKey)) do
			edges[cellKey .. ">" .. to] = entry
		end
	end

	--  THE BATCH LAST, so an unflushed edge is traversable the moment it is
	--  learned. A sweep has to be able to see its own work, or nearest-first
	--  ordering buys nothing.
	for key, entry in pairs(navPendingFor(profile) or {}) do
		edges[key] = entry
	end

	for key, entry in pairs(edges) do
		--  NO AGE TEST. A router asks what the graph knows; deciding that a
		--  known edge is too old to walk is the sweep's job, not a reader's.
		if type(entry) == "table" and entry.r == true then
			local from, to = string.match(key, "^(.-)>(.*)$")

			if from ~= nil and to ~= nil then
				out[from] = out[from] or {}
				table.insert(out[from], to)
			end
		end
	end

	return out
end

--  THE COARSE LEVELS, IN TILES, ABOVE THE 2-TILE BASE.
--
--  DERIVED FROM THE FINE EDGES, NEVER PROBED. Levels probed independently can
--  contradict each other -- 32 says connected, 2 says no -- and there is no
--  principled way to resolve that. One kind of probe, and the rest is
--  arithmetic over what it produced.
--
--  A COARSE EDGE EXISTS IF ANY FINE EDGE CROSSES BETWEEN THE TWO BLOCKS. That
--  makes coarse connectivity OPTIMISTIC: two blocks can be joined while the
--  particular cells a caller cares about are not.
--
--  WHICH IS EXACTLY THE DIRECTION THAT MAKES IT USEFUL, and the soundness
--  argument is worth stating because everything below depends on it:
--
--      if a fine path exists, every edge on it induces a coarse edge, so a
--      coarse path exists. Contrapositive: NO COARSE PATH MEANS NO FINE PATH.
--
--  So a coarse "no" is a PROOF and can be acted on, while a coarse "yes" is a
--  hint that has to be confirmed at the fine level. Rejection is the cheap,
--  sound direction -- and ruling targets out cheaply is the entire job.
local NAV_LEVELS = { 4, 8, 16, 32 }

--  A cell key to the key of the block containing it at a given tile size.
navBlockKey = function(cellKey, tiles)
	local cx, cy = string.match(cellKey, "^(-?%d+),(-?%d+)$")
	if cx == nil then return nil end

	local divisor = tiles / PETPORTS_NAV_STRIDE

	return tostring(math.floor(tonumber(cx) / divisor))
		.. "," .. tostring(math.floor(tonumber(cy) / divisor))
end

--  THE FINE GRAPH AND EVERY LEVEL ABOVE IT, BUILT ONCE PER STORE VERSION.
--
--  ONE PASS OVER THE EDGES BUILDS ALL FIVE. Walking the edge set once per level
--  would be five passes to answer one question, which is how a hierarchy ends
--  up slower than the flat structure it was meant to accelerate.
--
--  SELF-LOOPS ARE DROPPED at every coarse level: a fine edge inside one block
--  says nothing about leaving it, and keeping it would let a BFS "move" without
--  going anywhere.
local function navGraphFor(profile)
	local cached = self.petportsNavGraph

	if cached ~= nil and cached.profile == profile
	   and cached.version == (self.petportsNavVersion or 0) then
		return cached
	end

	local fine = navAdjacency(profile)
	local coarse = {}

	for _, tiles in ipairs(NAV_LEVELS) do coarse[tiles] = {} end

	for from, tos in pairs(fine) do
		for _, to in ipairs(tos) do
			for _, tiles in ipairs(NAV_LEVELS) do
				local a = navBlockKey(from, tiles)
				local b = navBlockKey(to, tiles)

				if a ~= nil and b ~= nil and a ~= b then
					local bucket = coarse[tiles]
					bucket[a] = bucket[a] or {}

					--  A SET, NOT A LIST. Hundreds of fine edges collapse onto
					--  one coarse edge, and appending would make the coarse
					--  graph LARGER than the fine one it summarises.
					bucket[a][b] = true
				end
			end
		end
	end

	self.petportsNavGraph = {
		profile = profile,
		version = self.petportsNavVersion or 0,
		fine = fine,
		coarse = coarse
	}

	return self.petportsNavGraph
end

--  BFS over one coarse level. Set-valued adjacency, so pairs() not ipairs().
local function navCoarseReaches(graph, tiles, fromKey, toKey, budget)
	local a = navBlockKey(fromKey, tiles)
	local b = navBlockKey(toKey, tiles)

	if a == nil or b == nil then return nil end
	if a == b then return true end

	local adjacency = graph.coarse[tiles]
	local visited = { [a] = true }
	local frontier = { a }
	local expanded = 0

	while #frontier > 0 do
		local nextFrontier = {}

		for _, node in ipairs(frontier) do
			expanded = expanded + 1
			if expanded > budget then return nil end

			for neighbour in pairs(adjacency[node] or {}) do
				if neighbour == b then return true end

				if not visited[neighbour] then
					visited[neighbour] = true
					table.insert(nextFrontier, neighbour)
				end
			end
		end

		frontier = nextFrontier
	end

	return false
end

--  CAN A UNIT OF THIS PROFILE GET FROM ONE CELL TO ANOTHER, THROUGH THE GRAPH?
--
--  DIRECTED, AND THAT RULES OUT UNION-FIND. The obvious implementation of
--  "which cells are connected" is a component label per cell, and it is WRONG
--  HERE: our edges are directional because a drop is one-way. A unit that falls
--  off a ledge into a pit is in the same undirected component as the ledge and
--  cannot climb back. Merging them would have the graph cheerfully promise a
--  return trip that does not exist -- and promising a route that is not there
--  is the expensive error this whole structure is priced around.
--
--  So this is a breadth-first walk over DIRECTED edges, run per query, and the
--  answer to "A to B" says nothing about "B to A".
--
--  THIS IS THE ONLY LEGAL WAY TO ASK THE STRUCTURE ANYTHING. NAV_MAX_DISTANCE
--  makes a single edge mean "connected within 32 tiles of path", which is not
--  the question anybody wants answered -- two cells needing a 50-tile detour
--  have a false direct edge and a true route. Composition through the graph is
--  what recovers the real answer. Reading one edge instead would turn every
--  bounded refusal into a wrongly-deleted target.
--
--  FALSE MEANS "NOT BY WHAT IS KNOWN", NEVER "UNREACHABLE". The graph is
--  incomplete by construction -- it is built lazily and it expires -- so an
--  exhausted search has only proven that the edges probed so far do not join
--  the two. CALLERS MAY ACT ON true. They may not act on false without
--  understanding that it also means "not probed yet".
--
--  nil IS "COULD NOT ANSWER", when the budget runs out. Distinguished from
--  false deliberately: a caller deciding whether to skip a probe must probe on
--  nil, because skipping on an unanswered question silently loses the edge.
PETPORTS_NAV_SEARCH_BUDGET = 2000

function petports_navReaches(profile, fromKey, toKey, budget)
	if fromKey == toKey then return true, 0 end

	budget = budget or PETPORTS_NAV_SEARCH_BUDGET

	local graph = navGraphFor(profile)

	--  COARSEST FIRST, AND ONLY A "NO" IS ACTED ON. Each level is a smaller
	--  graph than the one below it, so the cheapest possible rejection is tried
	--  first and the fine walk is only reached by a target nothing could rule
	--  out. A level that answers true or nil says nothing and costs one small
	--  BFS to find that out.
	for i = #NAV_LEVELS, 1, -1 do
		local tiles = NAV_LEVELS[i]

		if navCoarseReaches(graph, tiles, fromKey, toKey, budget) == false then
			return false, 0
		end
	end

	local adjacency = graph.fine
	local visited = { [fromKey] = true }
	local frontier = { fromKey }
	local expanded = 0

	while #frontier > 0 do
		local nextFrontier = {}

		for _, node in ipairs(frontier) do
			expanded = expanded + 1

			if expanded > budget then
				sb.logInfo("NAV reach %s -> %s ABANDONED for %s at budget %s",
					tostring(fromKey), tostring(toKey), tostring(profile),
					sb.printJson(budget))
				return nil, expanded
			end

			for _, neighbour in ipairs(adjacency[node] or {}) do
				if neighbour == toKey then return true, expanded end

				if not visited[neighbour] then
					visited[neighbour] = true
					table.insert(nextFrontier, neighbour)
				end
			end
		end

		frontier = nextFrontier
	end

	return false, expanded
end

--  THE ACTUAL CELL SEQUENCE FROM ONE CELL TO ANOTHER, not just whether one
--  exists.
--
--  THIS IS WHAT THE WHOLE STRUCTURE IS FOR. A verdict answers "should the port
--  bother dispatching"; a PATH answers "how does a unit on the left of a base
--  get to the right of it" -- which is the question todo.dispatch.reachbudget
--  was filed about. A* starves on a long route -- measured at SEARCH_LIMIT 6.0
--  every time, and 22 seconds at vanilla's explore rate before that -- but it
--  solves each SHORT leg of the same route in milliseconds. The graph knows the
--  legs.
--
--  BREADTH-FIRST, SO FEWEST CELLS WINS. Not shortest in tiles: an edge is
--  bounded at NAV_MAX_DISTANCE, so every hop is comparable in length and hop
--  count is a fair proxy. Weighting by true distance would need edge costs the
--  probe never measured.
--
--  THE COARSE LADDER IS NOT CONSULTED. petports_navReaches uses it to REJECT
--  cheaply, which is sound because a coarse no proves a fine no -- but a coarse
--  path is not a fine path, and following one would route a unit through blocks
--  it cannot cross. Paths come from the fine graph or not at all.
--
--  RETURNS nil FOR NO PATH, which is not the same as "unreachable" -- see
--  petports_navReaches on what a false means here.
function petports_navPath(profile, fromKey, toKey, budget)
	if fromKey == toKey then return { fromKey } end

	local adjacency = navGraphFor(profile).fine
	local cameFrom = { [fromKey] = false }
	local frontier = { fromKey }
	local expanded = 0

	budget = budget or PETPORTS_NAV_SEARCH_BUDGET

	while #frontier > 0 do
		local nextFrontier = {}

		for _, node in ipairs(frontier) do
			expanded = expanded + 1
			if expanded > budget then return nil end

			for _, neighbour in ipairs(adjacency[node] or {}) do
				if cameFrom[neighbour] == nil then
					cameFrom[neighbour] = node

					if neighbour == toKey then
						--  WALKED BACKWARD, THEN REVERSED. Storing forward
						--  links instead would need a second pass to prune the
						--  branches that went nowhere.
						local path = { toKey }
						local at = node

						while at do
							table.insert(path, 1, at)
							at = cameFrom[at]
						end

						return path, expanded
					end

					table.insert(nextFrontier, neighbour)
				end
			end
		end

		frontier = nextFrontier
	end

	return nil, expanded
end

--  ONE LEG OF THAT PATH: how far along it a unit should walk next.
--
--  NOT THE NEXT CELL. Cells are two tiles across, so walking them one at a time
--  would re-plan every stride and spend more time in the pathfinder than
--  moving. This returns the FARTHEST cell on the path still within `reach`
--  straight-line of the start, which is the longest leg A* can be trusted to
--  solve in one go.
--
--  STRAIGHT-LINE, NOT PATH LENGTH, and that is deliberately conservative. A leg
--  that doubles back covers less ground than its tile count suggests, so
--  measuring the chord under-reaches rather than handing A* a leg it will
--  starve on -- which is the failure this exists to avoid.
--
--  ALWAYS ADVANCES AT LEAST ONE CELL when a path exists, so a caller cannot
--  loop on a waypoint it is already standing in.
--
--  RETURNS a position and the remaining hop count, or nil.
--  minAdvance, 2026-09-05: a hop closer than this to the origin is passed
--  over unless it is the last. At stride 1 consecutive hops are one tile
--  apart, inside the caller's arrival radius, and a waypoint the unit is
--  already "at" was being declined -- which handed the leg back to the direct
--  search it had just failed.
function petports_navWaypoint(profile, fromKey, toKey, reach, freeMover, minAdvance)
	local path = petports_navPath(profile, fromKey, toKey)
	if path == nil or #path < 2 then return nil end

	minAdvance = minAdvance or 0

	local origin = petports_navAnchor(
		tonumber(string.match(path[1], "^(-?%d+),")),
		tonumber(string.match(path[1], ",(-?%d+)$")), freeMover)

	if origin == nil then return nil end

	local chosen, chosenAt = nil, 2

	for i = 2, #path do
		local cx = tonumber(string.match(path[i], "^(-?%d+),"))
		local cy = tonumber(string.match(path[i], ",(-?%d+)$"))
		local anchor = petports_navAnchor(cx, cy, freeMover)

		if anchor ~= nil then
			local dx = anchor[1] - origin[1]
			local dy = anchor[2] - origin[2]
			local distance = math.sqrt(dx * dx + dy * dy)

			if distance < minAdvance and i < #path then
				--  TOO CLOSE TO BE A LEG. Keep walking the path.
			elseif distance <= (reach or 24) then
				chosen, chosenAt = anchor, i
			elseif chosen ~= nil then
				break
			else
				--  THE FIRST HOP IS TAKEN EVEN IF IT IS TOO FAR. An edge can be
				--  up to NAV_MAX_DISTANCE of PATH long while its endpoints are
				--  much closer or further apart than that; refusing here would
				--  return nil for a route that genuinely exists.
				chosen, chosenAt = anchor, i
				break
			end
		end
	end

	if chosen == nil then return nil end

	--  ALSO THE CHOSEN CELL AND HOW MANY HOPS THE LEG SPANS, so a caller that
	--  fails to walk the leg can retry it one hop at a time and, when a single
	--  hop fails, contradict exactly that edge.
	return chosen, #path - chosenAt, path[chosenAt], chosenAt - 1, path[1],
		path[chosenAt - 1]
end

--  THE GRAPH CELL NEAREST A POSITION, 2026-09-05.
--
--  MEASURED 03:01: "no leg from 1016,1032" with the unit at [1016.51,1032.56]
--  mid-jump, and "no leg from 1017,1031" with it standing at [1017.2,1031.8]
--  on the last tile of a deck whose cells end at 1016. The unit's own cell
--  was not in the graph either time -- one was air, the other had no floor
--  under its own columns -- and a leg plan from an unknown cell is nil.
--
--  So a leg starts from the nearest cell the graph KNOWS, within `radius`
--  of the position, measured to that cell's anchor. Nothing is planned from
--  a cell that has never been swept into the graph.
function petports_navNearestCell(position, freeMover, radius)
	radius = radius or 2.5

	local profile = petports_navProfile()
	local fine = navGraphFor(profile).fine
	local px, py = petports_navCell(position)

	local reach = math.ceil(radius / PETPORTS_NAV_STRIDE)
	local bestKey, bestAnchor, bestDistance = nil, nil, nil

	for cx = px - reach, px + reach do
		for cy = py - reach, py + reach do
			local key = petports_navCellKey(cx, cy)

			if fine[key] ~= nil then
				local anchor = petports_navAnchor(cx, cy, freeMover)

				if anchor ~= nil then
					local distance = world.magnitude(anchor, position)

					if distance <= radius
					   and (bestDistance == nil or distance < bestDistance) then
						bestKey, bestAnchor, bestDistance = key, anchor, distance
					end
				end
			end
		end
	end

	return bestKey, bestAnchor, bestDistance
end

--  What is in the store, for a log line. Counted rather than dumped: a full
--  tree is thousands of edges and a printJson of it would be unreadable and
--  would dominate the log it was meant to explain.
function petports_navStats()
	local index = navIndexRead()
	local profiles, edges, reachable = 0, 0, 0
	local pending = self.petportsNavPendingCount or 0
	local swept = 0

	for profile, cells in pairs(index) do
		profiles = profiles + 1

		for cellKey in pairs(type(cells) == "table" and cells or {}) do
			swept = swept + 1

			for _, entry in pairs(navCellRead(profile, cellKey)) do
				edges = edges + 1
				if type(entry) == "table" and entry.r == true then
					reachable = reachable + 1
				end
			end
		end
	end

	return profiles, edges, reachable, pending, swept
end

--  ---------------------------------------------------------------- SWEEP

--  HOW LONG A SWEPT CELL STAYS SWEPT, and it is NOT the claim.
--
--  THE TWO ANSWER DIFFERENT QUESTIONS AND WANT DIFFERENT LIFETIMES:
--
--      the claim   "a unit is working on this RIGHT NOW". Seconds. Released
--                  when the sweep ends, and expiring on its own if the unit
--                  dies holding it.
--      sweptAt     "this cell has been surveyed". As long as the data. Read by
--                  a unit deciding whether there is anything to do here.
--
--  WITHOUT THE SECOND ONE a unit arriving after another has finished finds no
--  claim, concludes nobody is working here, and re-sweeps all 38 pairs -- 1059
--  probe ticks, measured -- for edges already in the store.
--
--  AND "DOES THIS CELL HAVE EDGES" CANNOT SUBSTITUTE FOR IT. A cell with no
--  anchored neighbours legitimately has zero edges, so absence of edges would
--  mean re-sweeping it forever. WE LOOKED AND FOUND NOTHING has to be
--  distinguishable from NOBODY LOOKED -- the same distinction that made
--  petports_navAnchor return nil rather than false.
local NAV_SWEEP_TTL = 900.0

--  How long a sweep claim is held before it lapses. Generously longer than a
--  sweep takes, because the cost of a stale claim is one unit idling and the
--  cost of a lapsed one is two units duplicating 1059 ticks of work.
local NAV_CLAIM_TTL = 120.0

--  THE INDEX ANSWERS THIS NOW. It used to be a `swept:<cell>` key sitting in
--  the edge table, which meant per-cell bookkeeping lived in a structure keyed
--  by edge -- and cost an off-by-one in navStats, which counted the markers as
--  edges. Sharding gave it a proper home.
--
--  READ FRESH, NOT MEMOISED. The index is one small property and it is the one
--  thing several units genuinely contend over: two units must not both decide a
--  cell is unswept because they are each holding a stale copy.
--  AN INDEX ENTRY IS `{ at = <world time>, radius = <tiles> }`. It was a bare
--  number -- the sweep time -- until 2026-09-05, when the radius ladder needed
--  the largest radius a cell had been swept at. A bare number is still read,
--  as a sweep at radius 0, so a stale index cannot crash a reader; it just
--  gets re-swept from the bottom rung.
local function navIndexEntry(value)
	if type(value) == "number" then return value, 0 end
	if type(value) ~= "table" then return nil, 0 end

	local at = tonumber(value.at)
	if at == nil then return nil, 0 end

	return at, tonumber(value.radius) or 0
end

function petports_navSwept(profile, cellKey)
	local index = navIndexRead()
	local cells = index[profile]
	if type(cells) ~= "table" then return nil end

	local at, radius = navIndexEntry(cells[cellKey])
	if at == nil then return nil end

	if (world.time() - at) > NAV_SWEEP_TTL then return nil end

	return at, radius
end

--  The largest radius a cell has been swept at, 0 if never or expired.
function petports_navSweptRadius(profile, cellKey)
	local at, radius = petports_navSwept(profile, cellKey)
	if at == nil then return 0 end
	return radius
end

--  THE SAME ANSWER FROM AN INDEX ALREADY IN HAND. petports_navSwept reads the
--  index property fresh on every call, which is right for a single question
--  and wrong for a walk over every known cell: measured 2026-09-05, the
--  candidate walk was 504 whole-index reads per top-up and cost about three
--  seconds between one sweep releasing and the next being claimed -- more
--  than the sweeps themselves. A walk reads once and asks this.
local function navSweptRadiusIn(cells, cellKey, now)
	if type(cells) ~= "table" then return 0 end

	local at, radius = navIndexEntry(cells[cellKey])
	if at == nil then return 0 end
	if (now - at) > NAV_SWEEP_TTL then return 0 end

	return radius
end

--  HOW MANY CELLS ONE UNIT SWEEPS AT ONCE, AND HOW MANY PROBES EACH GETS.
--
--  THE TOTAL IS THE COST: every slot is one PathFinder explore call per resume,
--  so four sweeps of eight slots is 32 x 300 = 9600 node expansions per unit
--  update. That is four times what a single eight-slot sweep cost and it is
--  DELIBERATE -- the survey was measured taking too long, and cutting the
--  radius alone did not close the gap.
--
--  THE TWO NUMBERS ARE INDEPENDENT ON PURPOSE. PETPORTS_NAV_SWEEPS widens the
--  frontier, PETPORTS_NAV_WORKERS deepens each cell, and they trade against
--  frame time TOGETHER. If a fleet ever makes this hurt, drop WORKERS first:
--  fewer probes per cell slows each sweep, while fewer sweeps also narrows the
--  frontier and makes the skip test less effective.
--
--  WHY FOUR CELLS RATHER THAN ONE. A claim covers a 2x2 tile square, which is
--  a very small unit of reservation for a sweep that probes ten tiles in every
--  direction -- so a unit finishing a cell every few seconds spends much of its
--  time between sweeps, taking and releasing claims, rather than probing. Four
--  in flight keeps the slots busy across the gaps.
--
--  IT ALSO SPREADS THE FRONTIER. Four cells are chosen from the ranked
--  candidate list at once, so a unit advances on several fronts instead of
--  finishing one cell before starting its neighbour -- which matters because a
--  cell's edges only help the skip test once that cell is DONE.
--
--  SLOT IDS MUST NOT COLLIDE ACROSS SWEEPS. petports_navProbeStep keys its
--  search state by slot on `self`, so two sweeps both using slot 1 would each
--  restart the other's probe every tick and neither would finish -- the exact
--  bug that made probes slotted in the first place. Each sweep gets a base
--  offset; see navSlotBase.
--  4 x 8 -> 2 x 4, 2026-09-05. Cut with the stride-1 cells (05c) and the
--  per-tick top-up (05e): four times the cells and no idle gap between sweeps
--  meant the 32-slot budget above was being spent every tick, and the survey
--  is background work. This is a quarter of it -- 8 x 300 expansions per
--  update. The two numbers stay independent; see above for which to move
--  first if it needs tuning again.
PETPORTS_NAV_SWEEPS = 2
PETPORTS_NAV_WORKERS = 4

local function navSlotBase(index)
	return (index - 1) * PETPORTS_NAV_WORKERS
end

--  A SWEEP OF ONE CELL, AS A COROUTINE.
--
--  MEASURED: a full sweep is 1059 probe ticks and about 2.2 seconds of wall
--  clock. Running that inline would freeze the unit for two seconds every time,
--  which is not background work, it is a stall with a nice name.
--
--  A COROUTINE RATHER THAN AN EXPLICIT STATE MACHINE because the outer loop is
--  the awkward part, not the inner one. petports_navProbeStep is ALREADY
--  resumable -- it returns "searching" and keeps its own progress -- so the
--  only thing needing hand-rolled state was "which neighbour am I on", plus
--  every early exit around it. A coroutine makes that a plain `for` loop.
--
--  DO NOT WRAP THE YIELD IN pcall. Lua 5.1 -- see fact.tooling.lua51 -- cannot
--  yield across a C call boundary, so a pcall anywhere between the resume and
--  the yield turns every yield into "attempt to yield across C-call boundary".
--  The pcalls inside petports_navProbeStep are FINE because they complete and
--  return before this function yields; a pcall placed around the loop below
--  would not be.
--
--  ONE PAIR PER RESUME AT MOST, so the cost per tick is one explore call --
--  invisible -- and a cell takes as many ticks as it takes.
function petports_navSweepStart(cx, cy, ownerId, index)
	local profile = petports_navProfile()
	local cellKey = petports_navCellKey(cx, cy)

	local sweptRadius = petports_navSweptRadius(profile, cellKey)
	local radius = navNextRadius(sweptRadius)

	if radius == nil then
		return nil, "already swept to full radius"
	end

	local workId = "nav:" .. profile .. ":" .. cellKey

	if not petports_claimTake(workId, ownerId, entity.id(), "nav",
		mcontroller.position(), NAV_CLAIM_TTL) then
		return nil, "claimed by another unit"
	end

	local freeMover = petports_freeMover()

	index = index or 1

	self.petportsNavSweeps = self.petportsNavSweeps or {}
	self.petportsNavSweeps[index] = {
		workId = workId,
		index = index,
		ownerId = ownerId,
		cellKey = cellKey,
		profile = profile,
		radius = radius,
		started = world.time(),
		job = coroutine.create(function()
			local neighbours = petports_navNeighbours(cx, cy, freeMover, radius)

			--  N PAIRS IN FLIGHT AT ONCE, ON ONE UNIT.
			--
			--  WITHIN A CELL RATHER THAN ACROSS CELLS, and that is the choice
			--  worth explaining. Running eight CELL sweeps at once would leave
			--  eight half-surveyed cells, none of which contributes to the skip
			--  test until it finishes -- and the skip test is what makes a warm
			--  sweep 40 ticks instead of 1059. Finishing cells FASTER puts
			--  their edges into the graph sooner, which is what the frontier
			--  feeds on.
			--
			--  A SLOT ARRAY RATHER THAN N COROUTINES. The state a worker needs
			--  is "which pair" and petports_navProbeStep already keeps the rest
			--  in its own slot, so eight coroutines would be eight stacks to
			--  hold one integer each.
			--
			--  THE SKIP TEST RUNS WHEN A PAIR IS PULLED, not when the list is
			--  built. Seven other workers are learning edges while this one
			--  waits, and a pair that was worth probing at plan time may be
			--  answered by the time its slot frees up.
			local nextPair = 1
			local active = {}
			local base = navSlotBase(index)

			while true do
				for slot = 1, PETPORTS_NAV_WORKERS do
					if active[slot] == nil then
						while nextPair <= #neighbours do
							local candidate = neighbours[nextPair]
							nextPair = nextPair + 1

							local known, age =
								petports_navKnown(profile, cellKey, candidate.key)
							local fresh = known ~= nil
								and (age or 0) < NAV_SWEEP_TTL

							local joined = (not fresh) and petports_navReaches(
								profile, cellKey, candidate.key) or nil

							if not fresh and joined ~= true then
								active[slot] = candidate
								break
							end
						end
					end
				end

				local working = false

				for slot = 1, PETPORTS_NAV_WORKERS do
					local candidate = active[slot]

					if candidate ~= nil then
						working = true

						local verdict = petports_navProbeStep({ cx, cy },
							{ candidate.cx, candidate.cy }, 300, base + slot)

						if verdict ~= "searching" then active[slot] = nil end
					end
				end

				--  DONE WHEN NOTHING IS IN FLIGHT AND NOTHING IS LEFT TO START.
				--  Testing only the pair index would end the sweep with seven
				--  searches still running and abandon their work.
				if not working and nextPair > #neighbours then return end

				coroutine.yield()
			end
		end)
	}

	return true
end

--  Resume one step. Returns "running", "done", or nil when nothing is running.
--
--  A DEAD COROUTINE IS REPORTED, NEVER SWALLOWED. coroutine.resume returns
--  false and a message on error rather than raising, so an unchecked resume
--  turns a broken sweep into a unit that quietly does nothing forever --
--  fact.tooling.mergedrefusal, in the one place it would be hardest to notice.
--  EVERY RUNNING SWEEP, ONE RESUME EACH. Returns "running" while any is alive,
--  "done" on the tick the last one finishes, nil when none are.
function petports_navSweepStep()
	local sweeps = self.petportsNavSweeps
	if sweeps == nil or next(sweeps) == nil then return nil end

	local alive = 0

	--  COLLECTED FIRST, because finishing a sweep mutates the table and pairs()
	--  over a table being modified is undefined in Lua.
	local indices = {}
	for index in pairs(sweeps) do table.insert(indices, index) end
	table.sort(indices)

	for _, index in ipairs(indices) do
		local sweep = sweeps[index]

		if sweep ~= nil then
			if coroutine.status(sweep.job) == "dead" then
				petports_navFinishSweep(index, true)
			else
				local ok, err = coroutine.resume(sweep.job)

				if not ok then
					sb.logError("NAV sweep of %s FAILED: %s",
						tostring(sweep.cellKey), tostring(err))
					petports_navFinishSweep(index, false)
				else
					alive = alive + 1
				end
			end
		end
	end

	if alive > 0 then return "running" end

	return "done"
end

--  How many sweeps this unit currently has in flight.
function petports_navSweepCount()
	local count = 0
	for _ in pairs(self.petportsNavSweeps or {}) do count = count + 1 end
	return count
end

--  MARKED SWEPT ONLY ON A CLEAN FINISH. An abandoned or failed sweep leaves the
--  cell unmarked so somebody tries again; marking it regardless would bake a
--  half-surveyed cell into the tree for the whole sweep TTL.
function petports_navFinishSweep(index, completed)
	local sweeps = self.petportsNavSweeps or {}
	local sweep = sweeps[index]
	if sweep == nil then return end

	--  FLUSH FIRST, THEN MARK. A cell marked swept whose edges never landed is
	--  a cell nothing will revisit for NAV_SWEEP_TTL and that has nothing in it
	--  -- the one ordering that can lose a whole sweep silently.
	petports_navFlush()

	if completed then
		local index = navIndexRead()
		index[sweep.profile] = index[sweep.profile] or {}

		--  THE LARGEST RADIUS, NEVER A SMALLER ONE. Another unit may have swept
		--  this cell wider while we were on it; the ladder only climbs.
		local _, held = navIndexEntry(index[sweep.profile][sweep.cellKey])

		index[sweep.profile][sweep.cellKey] = {
			at = world.time(),
			radius = math.max(held or 0, sweep.radius or 0)
		}
		navIndexWrite(index)
	end
	petports_claimRelease(sweep.workId, sweep.ownerId)

	--  ITS OWN SLOTS, NOT ALL OF THEM. Three other sweeps may be mid-probe.
	local base = navSlotBase(index)
	for slot = 1, PETPORTS_NAV_WORKERS do
		if self.petportsNavProbes ~= nil then
			self.petportsNavProbes[base + slot] = nil
		end
	end

	sb.logInfo("NAV sweep of %s at radius %s %s", tostring(sweep.cellKey),
		sb.printJson(sweep.radius), completed and "COMPLETE" or "ABANDONED")

	sweeps[index] = nil
end

--  WHAT THE HIERARCHY LOOKS LIKE, AND WHETHER IT IS SOUND.
--
--  TWO THINGS, AND THE SECOND IS THE ONE THAT MATTERS.
--
--  The counts show whether the levels SUMMARISE. A coarse level with as many
--  nodes as the fine graph is a level that costs a pass to build and rejects
--  nothing -- which is the failure mode of a hierarchy over a sparse set, and
--  our anchored set IS sparse. If level 32 has one node, everything collapses
--  into one block and the ladder is pure overhead on this base.
--
--  THE INVARIANT CHECK IS THE POINT: a coarse NO must never contradict a fine
--  YES. petports_navReaches acts on a coarse false as PROOF, so a single
--  violation there means dispatch would silently delete reachable targets --
--  the expensive error this whole structure is priced around. Checked
--  exhaustively over every known cell pair rather than argued.
--
--  A VIOLATION IS A BUG IN navBlockKey OR IN THE DERIVATION, never in the data.
--  The soundness argument holds for any edge set, so if this ever reports one,
--  do not tune anything -- read those two functions.
function petports_navLevelReport()
	local profile = petports_navProfile()
	local graph = navGraphFor(profile)

	--  Every cell that appears as an endpoint anywhere.
	local cells, order = {}, {}

	for from, tos in pairs(graph.fine) do
		if not cells[from] then cells[from] = true; table.insert(order, from) end
		for _, to in ipairs(tos) do
			if not cells[to] then cells[to] = true; table.insert(order, to) end
		end
	end

	table.sort(order)

	local levels = {}

	for _, tiles in ipairs(NAV_LEVELS) do
		--  DISTINCT BLOCKS, SOURCES AND TARGETS ALIKE.
		--
		--  An earlier version counted the keys of the adjacency map, which is
		--  blocks WITH OUTGOING EDGES, and reported `nodes: 1` at every level
		--  on a star-shaped graph -- true, useless, and read as a derivation
		--  bug for a minute. A hierarchy's whole claim is that it has fewer
		--  nodes than the level below, so the count has to be of nodes.
		local blocks, edges = {}, 0
		local nodes = 0

		for from, tos in pairs(graph.coarse[tiles]) do
			blocks[from] = true
			for to in pairs(tos) do
				blocks[to] = true
				edges = edges + 1
			end
		end

		for _ in pairs(blocks) do nodes = nodes + 1 end

		levels[tostring(tiles)] = { nodes = nodes, edges = edges }
	end

	--  EXHAUSTIVE, BOTH DIRECTIONS, because the edges are directional and a
	--  derivation bug could easily be right one way and wrong the other.
	local checked, violations, examples = 0, 0, {}

	for _, a in ipairs(order) do
		for _, b in ipairs(order) do
			if a ~= b then
				checked = checked + 1

				local coarseSaysNo = false

				for _, tiles in ipairs(NAV_LEVELS) do
					if navCoarseReaches(graph, tiles, a, b,
						PETPORTS_NAV_SEARCH_BUDGET) == false then
						coarseSaysNo = true
						break
					end
				end

				if coarseSaysNo then
					--  The fine walk, WITHOUT the coarse ladder in front of it,
					--  or this would be asking the answer to check itself.
					local visited = { [a] = true }
					local frontier = { a }
					local fineSaysYes = false

					while #frontier > 0 and not fineSaysYes do
						local nextFrontier = {}

						for _, node in ipairs(frontier) do
							for _, neighbour in ipairs(graph.fine[node] or {}) do
								if neighbour == b then fineSaysYes = true break end
								if not visited[neighbour] then
									visited[neighbour] = true
									table.insert(nextFrontier, neighbour)
								end
							end

							if fineSaysYes then break end
						end

						frontier = nextFrontier
					end

					if fineSaysYes then
						violations = violations + 1
						if #examples < 5 then
							table.insert(examples, a .. ">" .. b)
						end
					end
				end
			end
		end
	end

	return {
		profile = profile,
		fineCells = #order,
		levels = levels,
		invariant = {
			pairsChecked = checked,
			violations = violations,
			examples = examples
		}
	}
end

--  ---------------------------------------------------------- DEBUG DRAW

--  SEE WHAT THE SURVEY IS DOING, IN THE WORLD, WHILE IT DOES IT.
--
--  THE POINT IS GEOMETRY, NOT PROGRESS. Every invariant this file checks is
--  about graph structure -- petports_navLevelReport proved soundness over 702
--  pairs without ever noticing whether a cell rectangle is drawn one tile off,
--  because a consistent off-by-one is invisible to a consistency check. Only
--  looking at it catches that.
--
--  WHAT IS DRAWN:
--
--      magenta rect    the two cells, at their exact tile boundaries. If an
--                      anchor point sits outside its own rect, navBlockKey or
--                      petports_navAnchor disagree about what a cell is.
--      green point     the source anchor -- where the probe searches FROM
--      red point       the target anchor -- where it searches TO
--      yellow line     the pair being asked about
--
--  DRAWN EVERY TICK OR NOT AT ALL. Starbound's debug primitives last one frame,
--  so this has to be called from the pump rather than from the probe -- a probe
--  that resolves in one tick would otherwise flicker for a single frame and a
--  probe that takes 79 would draw once and vanish.
--
--  EVERY CALL IS WRAPPED. The colour argument is the one thing here not read
--  from source, and a rejected colour name would raise inside the survey pump
--  -- turning a debug aid into a crash in the thing it was meant to observe.
--  It reports once and disables itself instead.
local navDebugBroken = false

local function navDrawSafely(fn, ...)
	if navDebugBroken then return end

	local ok, err = pcall(fn, ...)

	if not ok then
		navDebugBroken = true
		sb.logError("NAV debug draw disabled -- %s", tostring(err))
	end
end

local function navDrawCell(cx, cy, colour)
	local x0, y0 = navCellOrigin(cx, cy)
	local x1 = x0 + PETPORTS_NAV_CELL
	local y1 = y0 + PETPORTS_NAV_CELL

	navDrawSafely(world.debugLine, { x0, y0 }, { x1, y0 }, colour)
	navDrawSafely(world.debugLine, { x1, y0 }, { x1, y1 }, colour)
	navDrawSafely(world.debugLine, { x1, y1 }, { x0, y1 }, colour)
	navDrawSafely(world.debugLine, { x0, y1 }, { x0, y0 }, colour)
end

--  A point, as a small cross. world.debugPoint exists but is a single pixel at
--  most zoom levels and is unfindable next to a line.
local function navDrawPoint(position, colour)
	if type(position) ~= "table" then return end

	local size = 0.25

	navDrawSafely(world.debugLine,
		{ position[1] - size, position[2] }, { position[1] + size, position[2] },
		colour)
	navDrawSafely(world.debugLine,
		{ position[1], position[2] - size }, { position[1], position[2] + size },
		colour)
end

--  ON BY DEFAULT WHILE THIS SYSTEM IS BEING BUILT, and that is a deliberate
--  reversal. It shipped opt-in, which was wrong twice over: the whole point was
--  to WATCH IT RUN, so requiring a command first means the first run is always
--  invisible -- and the flag is a script-context global, so it was lost on
--  every unit respawn and every reload anyway. An overlay you have to re-enable
--  after each rebuild is an overlay nobody sees.
--
--  IT COSTS ALMOST NOTHING WHEN UNSEEN. Nothing is drawn unless a probe is in
--  flight, and Starbound renders none of it unless the client has debug
--  rendering on. Turn it off here before release, not before testing.
--
--  RESETS TO ON AFTER A RELOAD, on purpose, for the same reason.
--  HOW COMPLETE EACH LEVEL IS.
--
--  A BLOCK IS COMPLETE WHEN EVERY KNOWN CELL INSIDE IT HAS BEEN SWEPT, and
--  "known" is the important word: a block is not measured against how many
--  cells it COULD hold, because most of those are open air with no anchor and
--  would never be swept. It is measured against the cells the survey has
--  actually discovered inside it. So a level reaches 100% when nothing
--  currently known is outstanding -- and can drop BELOW 100% again when a sweep
--  discovers new cells, which is honest rather than a glitch.
--
--  LEVEL 2 IS THE FINE CELLS THEMSELVES, included because it is the number
--  that actually answers "how far along is this".
--
--  MEMOISED ON THE GRAPH VERSION, because it walks every known cell once per
--  level and the overlay would otherwise pay that every frame.
function petports_navLevelProgress()
	local profile = petports_navProfile()
	local version = self.petportsNavVersion or 0

	local held = self.petportsNavLevelStats

	if held ~= nil and held.profile == profile and held.version == version then
		return held.levels
	end

	local index = navIndexRead()
	local swept = type(index[profile]) == "table" and index[profile] or {}

	--  EVERY CELL THE SURVEY HAS HEARD OF: swept ones from the index, plus
	--  endpoints seen in the graph that have not been reached yet.
	local known = {}

	for cellKey in pairs(swept) do known[cellKey] = true end

	local graph = navGraphFor(profile)

	for from, tos in pairs(graph.fine) do
		known[from] = true
		for _, to in ipairs(tos) do known[to] = true end
	end

	local levels = {}

	for _, tiles in ipairs({ PETPORTS_NAV_CELL, 4, 8, 16, 32 }) do
		local blocks = {}

		for cellKey in pairs(known) do
			local blockKey = tiles == PETPORTS_NAV_CELL
				and cellKey or navBlockKey(cellKey, tiles)

			if blockKey ~= nil then
				local block = blocks[blockKey]

				if block == nil then
					block = { total = 0, done = 0 }
					blocks[blockKey] = block
				end

				block.total = block.total + 1
				if swept[cellKey] ~= nil then block.done = block.done + 1 end
			end
		end

		local total, complete = 0, 0

		for _, block in pairs(blocks) do
			total = total + 1
			if block.done == block.total then complete = complete + 1 end
		end

		table.insert(levels, {
			tiles = tiles,
			blocks = total,
			complete = complete,
			percent = total > 0 and (complete / total * 100) or 100
		})
	end

	self.petportsNavLevelStats = {
		profile = profile,
		version = version,
		levels = levels
	}

	return levels
end

--  EVERY SWEPT CELL, AS A GREEN POINT AT ITS CENTRE.
--
--  WHAT IT IS FOR is watching coverage SPREAD from the seed after a wipe --
--  which is the only way to see whether the frontier is expanding evenly or
--  crawling along a single corridor, and neither number in the level readout
--  shows that.
--
--  MEMOISED ON THE STORE VERSION. The index is a world property, and reading it
--  once per frame to redraw a few hundred points would cost more than the
--  survey it is watching. The version bumps on every write this unit makes, so
--  the picture refreshes exactly when it changes.
local function navSweptPoints()
	local version = self.petportsNavVersion or 0
	local held = self.petportsNavSweptPoints

	if held ~= nil and held.version == version then return held.points end

	local profile = petports_navProfile()
	local index = navIndexRead()
	local cells = index[profile]
	local points = {}

	for cellKey in pairs(type(cells) == "table" and cells or {}) do
		local cx = tonumber(string.match(cellKey, "^(-?%d+),"))
		local cy = tonumber(string.match(cellKey, ",(-?%d+)$"))

		if cx ~= nil and cy ~= nil then
			--  CELL CENTRE, not the anchor. The anchor is where a probe starts
			--  and sits at body height; the centre is where the CELL is, which
			--  is what a coverage picture wants.
			local ox, oy = navCellOrigin(cx, cy)

			table.insert(points, {
				ox + PETPORTS_NAV_CELL * 0.5,
				oy + PETPORTS_NAV_CELL * 0.5
			})
		end
	end

	self.petportsNavSweptPoints = { version = version, points = points }

	return points
end

--  Where a probe's tick count is written, inside the cell it is checking.
--
--  BY SLOT, SO CONCURRENT PROBES DO NOT STACK. Every probe in a sweep shares
--  one source cell, so labelling the SOURCE put up to eight numbers on top of
--  each other. The target cell is unique per probe within a sweep, and the
--  corner spreads the rare case where two sweeps aim at the same cell.
--
--  FOUR CORNERS, WRAPPED. There are eight slots per sweep and four corners, so
--  slots 1 and 5 share one -- acceptable because they are almost never aimed at
--  the same cell, and a wrapped corner is easier to read than eight positions
--  crowded around one square.
local NAV_LABEL_CORNERS = {
	{ 0.15, 0.75 },   --  top left
	{ 0.55, 0.75 },   --  top right
	{ 0.15, 0.25 },   --  bottom left
	{ 0.55, 0.25 }    --  bottom right
}

PETPORTS_NAV_DEBUG = true

--  Toggle from a console: /entityeval return petports_navDebugToggle()
function petports_navDebugToggle()
	PETPORTS_NAV_DEBUG = not PETPORTS_NAV_DEBUG
	navDebugBroken = false

	sb.logInfo("NAV debug draw %s", PETPORTS_NAV_DEBUG and "ON" or "OFF")

	return PETPORTS_NAV_DEBUG
end

function petports_navDebugDraw()
	if not PETPORTS_NAV_DEBUG then return end

	--  THE LEVEL READOUT DRAWS WHETHER OR NOT A PROBE IS RUNNING, because the
	--  gap between sweeps is exactly when someone wants to know how far along
	--  it is. Anchored to the unit rather than to a cell so it follows the eye.
	--
	--  INCOMPLETE LEVELS ONLY. A finished level is a line that says nothing and
	--  pushes the ones that do say something off the top.
	local levels = petports_navLevelProgress()
	local here = mcontroller.position()
	local line = 0

	for _, level in ipairs(levels) do
		if level.percent < 100 then
			--  NO PERCENT SIGN IN THE OUTPUT, AND THIS IS NOT A STYLE CHOICE.
			--
			--  world.debugText TREATS ITS FIRST ARGUMENT AS A FORMAT STRING,
			--  same as sb.logInfo. A string built with `%%` here renders a
			--  literal `%`, which the engine then reads as a specifier and
			--  throws on: "Improper lua log format specifier %". Lua's
			--  string.format is perfectly happy with it, so this passes every
			--  test that is not run in game.
			--
			--  MEASURED 2026-09-04, and it disabled the ENTIRE overlay on its
			--  first frame -- navDrawSafely caught it, which is the only reason
			--  it was a blank screen and not a crash inside the survey pump.
			--
			--  THE RULE IS BROADER THAN THIS LINE: nothing that reaches
			--  sb.log*, world.debugText or any other formatLua call may contain
			--  a percent sign at all, whoever put it there. petports_luacheck
			--  now refuses one mechanically, because this file already carried
			--  the rule in prose and it did not help.
			navDrawSafely(world.debugText,
				string.format("nav L%s  %s pct  %s/%s",
					tostring(level.tiles),
					tostring(math.floor(level.percent + 0.5)),
					tostring(level.complete), tostring(level.blocks)),
				{ here[1] + 2, here[2] + 3 - line * 0.7 }, "cyan")

			line = line + 1
		end
	end

	if line == 0 then
		navDrawSafely(world.debugText, "nav COMPLETE",
			{ here[1] + 2, here[2] + 3 }, "green")
	end

	--  COVERAGE FIRST, so the probe overlay draws on top of it.
	for _, point in ipairs(navSweptPoints()) do
		navDrawPoint(point, "green")
	end

	local probes = self.petportsNavProbes
	if probes == nil or next(probes) == nil then return end

	--  SAID ONCE, SO "I SEE NOTHING" IS DIAGNOSABLE. Three things have to line
	--  up for the overlay to appear -- the flag, a probe in flight, and the
	--  client's debug rendering -- and the first two are the only ones this
	--  script can report on. Without this line, a flag left off and a client
	--  with debug rendering off look identical from the log.
	if not self.petportsNavDrewOnce then
		self.petportsNavDrewOnce = true
		sb.logInfo("NAV debug draw ACTIVE -- if nothing appears in game, "
			.. "the client needs debug rendering enabled (/debug)")
	end

	--  EVERY SLOT, so eight concurrent probes are eight lines rather than
	--  whichever one happened to be looked at last.
	for slot, probe in pairs(probes) do
		navDrawCell(probe.fromCell[1], probe.fromCell[2], "magenta")
		navDrawCell(probe.toCell[1], probe.toCell[2], "magenta")

		if probe.fromAnchor ~= nil and probe.toAnchor ~= nil then
			navDrawSafely(world.debugLine, probe.fromAnchor, probe.toAnchor,
				"yellow")
		end

		navDrawPoint(probe.fromAnchor, "green")
		navDrawPoint(probe.toAnchor, "red")

		--  THE TICK COUNT ALONE, IN A CORNER OF THE CELL BEING CHECKED.
		--
		--  The cell keys were in the label and are now redundant: the magenta
		--  rect already says which two cells, and reading "489,519>494,518"
		--  eight times over one anchor was noise rather than information. What
		--  cannot be seen without a number is how long a probe has been going,
		--  which is the whole difference between a cheap true and an expensive
		--  false.
		local corner = NAV_LABEL_CORNERS[((slot - 1) % 4) + 1]

		local ox, oy = navCellOrigin(probe.toCell[1], probe.toCell[2])

		navDrawSafely(world.debugText, tostring(probe.ticks), {
			ox + corner[1] * PETPORTS_NAV_CELL,
			oy + corner[2] * PETPORTS_NAV_CELL
		}, "yellow")
	end
end

--  ------------------------------------------------------------ SCHEDULER

--  WHICH CELL TO SWEEP NEXT.
--
--  THE FRONTIER IS THE NEIGHBOUR LISTS OF ALREADY-SWEPT CELLS, which is what
--  makes the skip test worth anything. Measured 2026-09-04: a cold sweep is
--  1059 probe ticks, a warm one is 40 -- a 26-fold difference that exists ONLY
--  when a cell's neighbours already carry verdicts. Sweeping cells in scan
--  order or at random leaves the graph a collection of disconnected stars, each
--  one paying full cold price, and nothing ever gets cheap.
--
--  SO CANDIDATES COME FROM THE GRAPH, NOT FROM GEOMETRY. Every cell that
--  appears in the fine adjacency was reached from somewhere, so it is anchored
--  by construction -- no anchor scan needed to find it. A geometric walk would
--  spend most of its time on the 87% of cells that hold nothing but air.
--
--  NEAREST TO THE UNIT WINS, so expansion follows the unit around the base
--  rather than radiating from wherever it happened to start.
--
--  THE SEED IS THE UNIT'S OWN CELL. With an empty graph there is no frontier,
--  and the cell a unit is standing in is the one place its connectivity is
--  certainly worth knowing.
function petports_navCandidates(limit)
	local here = mcontroller.position()
	local cx, cy = petports_navCell(here)
	local profile = petports_navProfile()
	local mine = petports_navCellKey(cx, cy)

	local found = {}

	--  ONE READ FOR THE WHOLE WALK. See navSweptRadiusIn.
	local sweptCells = navIndexRead()[profile]
	local now = world.time()

	local mineRadius = navSweptRadiusIn(sweptCells, mine, now)

	--  THE SEED IS ONLY THE UNIT'S CELL WHEN THAT CELL IS WORTH SWEEPING.
	--  Seen 2026-09-05: green markers on cells a unit was jumping or falling
	--  through. The seed took petports_navCell(position) unconditionally, so
	--  a unit in the air seeded a sweep of open air, which found no anchor,
	--  finished at once and was marked swept. A walker seeds only from the
	--  ground, and any seed must have an anchor.
	local freeMover = petports_freeMover()
	local grounded = freeMover or mcontroller.onGround()

	if mineRadius < PETPORTS_NAV_RADIUS and navInCoverage(cx, cy)
	   and grounded and petports_navAnchor(cx, cy, freeMover) ~= nil then
		table.insert(found, {
			cx = cx, cy = cy, key = mine, distance = 0, radius = mineRadius
		})
	end

	local graph = navGraphFor(profile)
	local seen = { [mine] = true }

	--  CELLS THIS UNIT IS ALREADY SWEEPING. The claim would refuse them anyway,
	--  but a refusal costs a claim read and burns one of NAV_CLAIM_ATTEMPTS --
	--  and with four sweeps running, the four nearest candidates are exactly
	--  the ones already in flight, so every top-up would spend its whole budget
	--  refusing its own work.
	for _, sweep in pairs(self.petportsNavSweeps or {}) do
		seen[sweep.cellKey] = true
	end

	local function consider(cellKey)
		if seen[cellKey] then return end
		seen[cellKey] = true

		--  BELOW THE CEILING IS A CANDIDATE, swept or not. A cell swept at 4
		--  is still owed its 6.
		local radius = navSweptRadiusIn(sweptCells, cellKey, now)
		if radius >= PETPORTS_NAV_RADIUS then return end

		local bx, by = string.match(cellKey, "^(-?%d+),(-?%d+)$")
		if bx == nil then return end

		--  OUT OF COVERAGE IS NOT A CANDIDATE. It stays in the graph if some
		--  earlier sweep found it -- an edge is an edge -- but nothing goes and
		--  surveys it, so the frontier cannot walk off across the planet.
		if not navInCoverage(tonumber(bx), tonumber(by)) then return end

		--  CELL CENTRES, not anchors. An anchor costs a scan to derive and this
		--  is only ranking candidates -- the sweep will compute the real one.
		local ox, oy = navCellOrigin(tonumber(bx), tonumber(by))

		local dx = ox + PETPORTS_NAV_CELL * 0.5 - here[1]
		local dy = oy + PETPORTS_NAV_CELL * 0.5 - here[2]

		table.insert(found, {
			cx = tonumber(bx), cy = tonumber(by),
			key = cellKey,
			distance = dx * dx + dy * dy,
			radius = radius
		})
	end

	for from, tos in pairs(graph.fine) do
		consider(from)
		for _, to in ipairs(tos) do consider(to) end
	end

	--  NARROWEST FIRST, THEN NEAREST, tie-broken on the key because table.sort
	--  is not stable. The radius term is what makes the ladder run in PASSES:
	--  nothing is widened to 6 while any known cell is still owed its 4, and a
	--  cell the unit has only just discovered goes to the front of the queue
	--  at 0, so new ground always starts on the bottom rung.
	table.sort(found, function(a, b)
		if a.radius ~= b.radius then return a.radius < b.radius end
		if a.distance ~= b.distance then return a.distance < b.distance end
		return a.key < b.key
	end)

	if limit ~= nil then
		while #found > limit do table.remove(found) end
	end

	return found
end

--  The single best candidate, kept for evals and for reading.
function petports_navNextCell(freeMover)
	local candidates = petports_navCandidates(1)
	if #candidates == 0 then return nil, nil, "no unswept cell in the graph" end
	return candidates[1].cx, candidates[1].cy, candidates[1].key
end

--  How many candidates a unit will try before giving up for this interval.
--
--  A LIST RATHER THAN ONE PICK, BECAUSE ONE PICK DOES NOT PARALLELISE. Every
--  unit ranks by distance from ITSELF, and units cluster -- the leash keeps
--  them near their port by design. So eight units in one room all choose the
--  same nearest cell, one wins the claim, and the other seven idle for a whole
--  interval and then choose it again. They convoy instead of splitting the
--  work, and adding units makes the survey no faster.
--
--  Walking down the ranked list on refusal fixes it with no coordination: the
--  second unit takes the second-nearest cell, and so on. The claim is still the
--  thing that decides; this only stops a refusal from wasting the tick.
--
--  CAPPED, because each attempt is a claim read and a swept lookup, and a unit
--  that cannot find work in four tries can afford to wait two seconds.
local NAV_CLAIM_ATTEMPTS = 4

--  HOW MANY STALE OUT-OF-COVERAGE CELLS ARE DROPPED PER PASS.
--
--  A CELL THAT LEAVES COVERAGE IS DEAD DATA FOREVER OTHERWISE. Coverage moves
--  -- a port is mined, a network splits -- and the cells it used to own can
--  never be re-swept, so their sweptAt simply ages past NAV_SWEEP_TTL and sits
--  in the world properties for the life of the world.
--
--  THE TWO CONDITIONS TOGETHER, NEVER EITHER ALONE. Out of coverage but FRESH
--  is a cell the network just released and may reclaim, and dropping it would
--  throw away a survey that is still true. Stale but IN coverage is simply a
--  cell due for re-survey -- that is what the TTL is for, and purging it would
--  make the tree rebuild from nothing on a timer.
--
--  A FEW PER PASS, NOT ALL. This walks the index, which is the one structure
--  every unit reads fresh; doing the whole thing at once on a large base would
--  be a spike on a two-second timer for work that has no deadline at all.
local NAV_PURGE_PER_PASS = 4

local function navPurgeDeadzones(profile)
	local index = navIndexRead()
	local cells = index[profile]

	if type(cells) ~= "table" then return 0 end

	local now = world.time()
	local dropped = 0

	for cellKey, entry in pairs(cells) do
		if dropped >= NAV_PURGE_PER_PASS then break end

		local bx, by = string.match(cellKey, "^(-?%d+),(-?%d+)$")
		local sweptAt = navIndexEntry(entry)

		if bx ~= nil and sweptAt ~= nil
		   and (now - sweptAt) > NAV_SWEEP_TTL
		   and not navInCoverage(tonumber(bx), tonumber(by)) then

			pcall(world.setProperty, navCellProperty(profile, cellKey), nil)
			cells[cellKey] = nil

			self.petportsNavCellCache = self.petportsNavCellCache or {}
			self.petportsNavCellCache[navCellProperty(profile, cellKey)] = nil

			dropped = dropped + 1
		end
	end

	if dropped > 0 then
		navIndexWrite(index)
		self.petportsNavGraph = nil

		sb.logInfo("NAV purged %s stale out-of-coverage cell(s) for %s",
			sb.printJson(dropped), tostring(profile))
	end

	return dropped
end

--  How often an idle unit looks for something to survey.
--
--  EVERY TICK, 2026-09-05. It was 2.0 seconds, on the argument that the
--  candidate lookup walks the whole edge set and a cell that goes unswept for
--  a few seconds costs nothing. Against that: with four sweeps in flight and
--  cells finishing out of order, a free slot sat empty for up to two seconds
--  every time a sweep completed, and at 05c cell counts that idle time was
--  most of the survey. The lookup still does not run while the roster is full
--  -- petports_navTick returns before the timer when every slot is busy -- so
--  the walk is paid only on the tick a slot opens.
--
--  Zero rather than removing the timer, so it can be raised again from one
--  place if the walk ever shows up in frame time.
local NAV_TICK_INTERVAL = 0.0

--  ONE STEP OF BACKGROUND SURVEYING, CALLED FROM AN IDLE UNIT.
--
--  A RUNNING SWEEP IS STEPPED EVERY TICK; a new one is LOOKED FOR on the
--  interval, which is now also every tick but gated on a free slot. Those are
--  different costs -- a step is one explore call, a search is a pass over the
--  edge set -- and the slot gate is what keeps the second from being constant.
--
--  IT DOES NOT CHECK IDLENESS ITSELF. The caller does, because the caller is
--  the thing that knows what the unit is doing, and a predicate here would be a
--  second answer to a question petportsTaskAction already answers.
function petports_navTick(dt, ownerId)
	--  BEFORE THE STEP, so the pair currently in flight is drawn even on the
	--  tick it resolves and clears itself.
	petports_navDebugDraw()

	--  STEP EVERY RUNNING SWEEP, EVERY TICK. Only the SEARCH for new cells is
	--  on the interval below; stepping is one explore call per slot and must not
	--  wait two seconds between resumes.
	petports_navSweepStep()

	--  AND KEEP STEPPING WITHOUT LOOKING FOR MORE while the roster is full.
	--  Topping up is a walk over the edge set, and there is nothing to top up.
	if petports_navSweepCount() >= PETPORTS_NAV_SWEEPS then return true end

	self.petportsNavTimer = (self.petportsNavTimer or 0) - (dt or 0)
	if self.petportsNavTimer > 0 then return false end
	self.petportsNavTimer = NAV_TICK_INTERVAL

	--  ON THE SAME TIMER AS THE SEARCH, and before it: a purge can only make
	--  the candidate list shorter or leave it alone, never longer, so doing it
	--  first costs nothing and keeps the graph the search walks smaller.
	navPurgeDeadzones(petports_navProfile())

	local candidates = petports_navCandidates(NAV_CLAIM_ATTEMPTS)

	if #candidates == 0 then
		--  SAID ONCE, THEN NEVER AGAIN UNTIL SOMETHING CHANGES.
		--
		--  THE SURVEY DOES TERMINATE, and until now nothing announced it. New
		--  cells only enter the frontier as endpoints of edges from swept
		--  cells, so once every known cell is swept nothing new can arrive --
		--  the graph has closed over the walkable region reachable in
		--  PETPORTS_NAV_RADIUS hops from the seed. That is genuinely done, not
		--  stalled, and the two look identical from outside.
		--
		--  CLEARED ON ANY START BELOW, so walking the unit into new ground and
		--  re-opening the frontier announces itself again rather than
		--  completing in silence.
		if not self.petportsNavComplete then
			self.petportsNavComplete = true

			local _, edges, reachable = petports_navStats()

			sb.logInfo("NAV survey COMPLETE for %s -- every known cell swept "
				.. "to radius %s, %s edge(s), %s reachable",
				tostring(petports_navProfile()), sb.printJson(PETPORTS_NAV_RADIUS),
				sb.printJson(edges), sb.printJson(reachable))
		end

		return false
	end

	--  FILL EVERY FREE SLOT IN THE ROSTER, not just one.
	--
	--  DOWN THE LIST ON REFUSAL. See NAV_CLAIM_ATTEMPTS: a refusal means the
	--  cell is already swept or another unit got there first, and either is a
	--  reason to take the NEXT cell rather than to stop.
	--
	--  THE FREE INDEX IS FOUND, NOT COUNTED. Sweeps finish out of order, so the
	--  roster is sparse -- and an index is what decides a sweep's probe slots,
	--  so reusing a live one would have two sweeps sharing search state.
	local started = false

	for _, cell in ipairs(candidates) do
		if petports_navSweepCount() >= PETPORTS_NAV_SWEEPS then break end

		local index = nil
		for i = 1, PETPORTS_NAV_SWEEPS do
			if (self.petportsNavSweeps or {})[i] == nil then index = i break end
		end

		if index == nil then break end

		if petports_navSweepStart(cell.cx, cell.cy, ownerId, index) then
			self.petportsNavComplete = false
			started = true

			local radius = self.petportsNavSweeps[index].radius

			--  A PASS BOUNDARY, SAID ONCE. The candidate order guarantees the
			--  sweep radius only rises when nothing narrower is left, so the
			--  first sweep at a wider radius IS the end of the previous pass.
			--  It can fall again when new ground is found, which is honest.
			if self.petportsNavPassRadius ~= nil
			   and radius > self.petportsNavPassRadius then
				sb.logInfo("NAV pass at radius %s complete for %s -- "
					.. "sweeping at %s",
					sb.printJson(self.petportsNavPassRadius or 0),
					tostring(petports_navProfile()), sb.printJson(radius))
			end
			self.petportsNavPassRadius = radius

			sb.logInfo("NAV surveying %s at radius %s (sweep %s of %s)",
				cell.key, sb.printJson(radius), sb.printJson(index),
				sb.printJson(PETPORTS_NAV_SWEEPS))
		end
	end

	if started then return true end

	--  ALL REFUSED, AND THAT IS NOT LOGGED. "already swept" and "claimed by
	--  another unit" are the normal outcome of several units sharing a base,
	--  and a line per refusal per unit per interval would bury everything else.
	return false
end

--  Where the survey has got to. For a log line or an eval, not for logic.
function petports_navProgress()
	local profile = petports_navProfile()
	local graph = navGraphFor(profile)

	local cells, swept, full = 0, 0, 0
	local seen = {}

	local sweptCells = navIndexRead()[profile]
	local now = world.time()

	local function count(cellKey)
		if seen[cellKey] then return end
		seen[cellKey] = true

		cells = cells + 1

		local radius = navSweptRadiusIn(sweptCells, cellKey, now)
		if radius > 0 then swept = swept + 1 end
		if radius >= PETPORTS_NAV_RADIUS then full = full + 1 end
	end

	for from, tos in pairs(graph.fine) do
		count(from)
		for _, to in ipairs(tos) do count(to) end
	end

	local _, edges, reachable = petports_navStats()

	local sweeping = {}
	for _, sweep in pairs(self.petportsNavSweeps or {}) do
		table.insert(sweeping, sweep.cellKey)
	end
	table.sort(sweeping)

	return {
		profile = profile,
		cells = cells,
		swept = swept,
		full = full,
		frontier = cells - full,
		edges = edges,
		reachable = reachable,
		sweeping = sweeping
	}
end

--  CLEAR EVERYTHING, FOR A COLD TEST.
--
--  THE INDEX IS WHAT MAKES THIS POSSIBLE. Sharding means there is no single key
--  to delete, and world properties cannot be enumerated -- so without the index
--  a wipe would leave orphaned shards that nothing could ever find or clear,
--  and the next survey would silently inherit them.
function petports_navWipe()
	local index = navIndexRead()
	local cleared = 0

	for profile, cells in pairs(index) do
		for cellKey in pairs(type(cells) == "table" and cells or {}) do
			pcall(world.setProperty, navCellProperty(profile, cellKey), nil)
			cleared = cleared + 1
		end
	end

	pcall(world.setProperty, NAV_INDEX, nil)

	self.petportsNavPending = {}
	self.petportsNavPendingCount = 0
	self.petportsNavFlushAt = nil
	self.petportsNavCellCache = {}
	self.petportsNavGraph = nil
	self.petportsNavComplete = false
	self.petportsNavPassRadius = nil
	self.petportsNavVersion = (self.petportsNavVersion or 0) + 1

	sb.logInfo("NAV wiped %s cell shard(s) and the index", sb.printJson(cleared))

	return cleared
end

--  ------------------------------------------------------------- SELF TEST

--  ONE COMMAND, BECAUSE THE ALTERNATIVE DOES NOT WORK.
--
--  Several things here can only be observed WITHIN A SINGLE FRAME -- whether a
--  read sees an unflushed batch, what the pending count is mid-sweep -- and
--  Starbound's chat box cannot issue two evals fast enough to catch either.
--  Timing-sensitive verification has to live in the code being verified.
--
--  IT IS ALSO WHY world.time() IS ABSENT FROM EVERY MEASUREMENT HERE. It does
--  not advance inside a frame, so nothing timed from in here would ever read
--  anything but zero. Ticks and counts only; wall clock comes off the log
--  timestamps.
--
--  DESTRUCTIVE BY DEFAULT. It clears the store first, because a sweep against a
--  populated one cannot tell a fresh edge from a remembered one and the numbers
--  stop meaning anything. Pass false to keep what is there.
--
--  WHAT EACH FIELD ANSWERS:
--
--      pairs             how sparse the anchored set is around here
--      probed            true/false split, and false is the expensive one
--      midSweep          edges committed and edges still pending, taken BEFORE
--                        the final flush -- a non-zero pending here is the
--                        thing that makes the next field meaningful
--      reachWhilePending whether a query sees unflushed edges. THIS IS THE
--                        POINT. All true with pending above zero means the
--                        overlay works; a false there means a sweep cannot see
--                        its own work and nearest-first ordering is worthless.
--      afterFlush        edges and pending after forcing a flush
function petports_navSelfTest(wipe)
	stampOnce()

	if wipe ~= false then petports_navWipe() end

	local here = mcontroller.position()
	local cx, cy = petports_navCell(here)
	local me = petports_navCellKey(cx, cy)
	local profile = petports_navProfile()
	local freeMover = petports_freeMover()

	local neighbours = petports_navNeighbours(cx, cy, freeMover)

	local yes, no, unknown, ticks = 0, 0, 0, 0

	for _, cell in ipairs(neighbours) do
		local verdict, spins = "searching", 0

		--  DRIVEN TO COMPLETION HERE, which a scheduler must NOT do -- it is
		--  what makes this a measurement rather than a simulation of one. The
		--  spin cap is a hang guard, not a budget.
		while verdict == "searching" and spins < 500 do
			verdict = petports_navProbeStep({ cx, cy }, { cell.cx, cell.cy }, 300)
			spins = spins + 1
		end

		ticks = ticks + spins

		if verdict == true then yes = yes + 1
		elseif verdict == false then no = no + 1
		else unknown = unknown + 1 end
	end

	local _, committed, _, pending = petports_navStats()

	--  THE OVERLAY TEST, and it has to happen before the flush below.
	local reach = {}
	for i = 1, math.min(6, #neighbours) do
		local ok = petports_navReaches(profile, me, neighbours[i].key)
		reach[neighbours[i].key] = tostring(ok)
	end

	local flushed = petports_navFlush()
	local _, settled, reachable, leftover = petports_navStats()

	return {
		cell = me,
		profile = profile,
		pairs = #neighbours,
		probed = { yes = yes, no = no, unknown = unknown, ticks = ticks },
		midSweep = { edges = committed, pending = pending },
		reachWhilePending = reach,
		afterFlush = { edges = settled, reachable = reachable,
			pending = leftover, flushed = flushed }
	}
end
