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

local COARSENAV_BUILD_STAMP = "2026-09-09v the merged graph: routing crosses bridges, legs stop at the side change"

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

--  THE MANIFEST, 2026-09-07v. Every world-property family the nav system
--  writes registers its ROOT here, with an enumerator that lists every
--  property under it, so ONE function can clear the lot -- edge shards,
--  their per-profile indices, the profile registry, and whatever a later
--  build adds (boundary cells, highway edges). A family that writes a
--  property without registering is a leak the wipe cannot see; adding a
--  family means adding a row here, not a branch in petports_navWipe.
--
--  The world copy, NAV_MANIFEST, holds the root names so a unit that has
--  never touched a family still wipes it. The in-script table holds the
--  enumerators, keyed by root.
local NAV_MANIFEST = "petports_navmanifest"

--  A GENERATION COUNTER, so a wipe by ONE unit reaches every other unit's
--  memos (graph, cell cache, anchors) at its next cache tick instead of at
--  NAV_CACHE_TTL. Read once per navCachesTick, which is per tick but the
--  read is one small property.
local NAV_GEN = "petports_navgen"

--  Candidate-scan blocks, NAV_BLOCK_CELLS cells on a side (16 tiles at
--  cell 2). Declared here because petports_navLearn keeps the block index
--  current and is defined long before the scan. See navGraphBlocks.
local NAV_BLOCK_CELLS = 8

--  64 -> 32, 2026-09-08f (Lofty). MEASURED 16:04: draw was 440-470 ms of
--  every 5 s and up to 90 ms in one tick, 12-18k debugPoint calls a second
--  -- every swept cell in a 64-tile square every update. No cap on our
--  side, none known on the engine's; the range is the only knob.
local NAV_DRAW_RANGE = 32

local navFamilies = {}
local navEdgeFamilyEnumerate = nil  --  assigned below navCellProperty

--  LIQUID BOUNDARY CELLS -- THE SHARED STORE, 2026-09-07x.
--
--  dd.pathing.boundarystore: where the water IS does not depend on who asks,
--  so boundary cells are written ONCE for the world, keyed on the liquids
--  involved and the body that measured the openings, never on a chassis
--  profile. Six chassis is not six copies of the ocean surface.
--
--      petports_navbounds                        registry of buckets
--      petports_navbounds:<bucket>               index: cellKey -> true
--      petports_navbounds:<bucket>:<cellKey>     the record
--
--  bucket = "<liquid>[+<liquid>...]|b<w>,<h>" -- the distinct liquids in the
--  window, sorted, and the body that judged `fit`.
--
--  THE RECORD IS GEOMETRY ONLY. What a boundary MEANS to a profile -- a
--  wall, a bridge, a floor -- is decided when a profile builds its graph
--  (a later build), not here.
--
--      m    per tile of the 2x2 window, keyed "dx,dy": "air" or the
--           liquid's name (first name root.liquidConfig gives it)
--      top  the highest wet tile row in the window, or nil -- the surface
--           row when the boundary is horizontal
--      fit  per column dx: whether this body fits in the air directly above
--           the wet tile in that column (the opening test the dive trace
--           makes, made local)
--      t    world.time() written
--
--  DISCOVERED WHERE THE SURVEY ALREADY LOOKS. petports_navAnchor samples
--  every cell the survey considers, both sides, on an anchor-cache miss;
--  navBoundaryNote rides on that miss. Four world.liquidAt calls per cell,
--  once per NAV_ANCHOR_TTL, only for cells the survey visits anyway.
local NAV_BOUNDS = "petports_navbounds"
local NAV_BOUNDS_FILL = 0.5
local navBoundaryNote = nil  --  assigned in the boundary-store section; called from petports_navAnchor above it
local navGenerationCheck = nil  --  assigned beside navCachesTick; called from the flushes and the tick
local navGenNow = nil  --  assigned beside navGenerationCheck; the generation every read and write is checked against
local navDrawBounds = nil    --  assigned beside the debug draw; called from petports_navDebugDraw above it
local navContradictThrough = nil  --  assigned below navBoundaryNote; called from it
local navSeedBesideWall = nil     --  assigned below navBoundaryNote; called from it
local navBoxForbidden = nil  --  assigned in the wall section; called from navContradictThrough above it
local navForbiddenCells = nil  --  assigned in the wall section; called from navAnchorUncached above it
local navTickClock = nil  --  assigned beside the sweep step; called from navContradictTick above it

local function navFamilyRegister(root, enumerate)
	navFamilies[root] = enumerate

	local ok, manifest = pcall(world.getProperty, NAV_MANIFEST)
	if not ok or type(manifest) ~= "table" then manifest = {} end

	if manifest[root] ~= true then
		manifest[root] = true
		pcall(world.setProperty, NAV_MANIFEST, manifest)
	end
end

--  How long a cached cell may be held before it is re-read, so ANOTHER unit's
--  discoveries eventually arrive. Our own writes invalidate precisely; nothing
--  can tell us about somebody else's, and polling every read would undo the
--  whole point of the memo.
--  30 -> 120, 2026-09-07b. PROFILED: the expiry drops the memoised graph,
--  and the rebuild that follows read every shard and took 1,029 ms in one
--  tick -- the periodic big hitch, every 30 s. Another unit's edges now
--  arrive two minutes late instead of half a minute; claims already keep
--  units off each other's cells, and a route this unit needs across the
--  other's area is also in the store when it plans (navPath reads the
--  memo, which is rebuilt on expiry, so it is at most this stale).
local NAV_CACHE_TTL = 120.0

--  How often the overlay's derived readouts (level progress, swept points)
--  are recomputed while the overlay is on; see petports_navLevelProgress.
local NAV_OVERLAY_REFRESH = 2.0

--  PER-PROBE LOG LINES ARE OPT-IN, 2026-09-07b. PROFILED: 9,327 body-sweep
--  verdict lines in one session, up to 318 log lines a second -- each a
--  string.format and a file write on the laptop's disk, inside the tick.
--  The verdict is in the store and the survey counters are on the PROFILE
--  line; the per-pair line is for reading a single route's history, so it
--  is behind this flag. petports_navVerboseToggle() flips it. Lines that
--  happen per sweep (surveying, neighbours, COMPLETE) stay: tens per 5 s.
PETPORTS_NAV_VERBOSE = true  --  ON for the corner-cut logs, 2026-09-09f

function petports_navVerboseToggle()
	PETPORTS_NAV_VERBOSE = not PETPORTS_NAV_VERBOSE
	sb.logInfo("NAV verbose %s", PETPORTS_NAV_VERBOSE and "ON" or "OFF")
	return PETPORTS_NAV_VERBOSE
end

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

--  A FREE MOVER'S STRIDE IS WIDER, 2026-09-06. MEASURED: a flyer on the base
--  swept 297 cells with 35 candidates each and 1934 edges, 44 of them false
--  -- open air is homogeneous, every cell anchors, every pair is true, and
--  iterating that store stalled the world physics thread. A walker's nodes
--  follow surfaces and are sparse on their own; a flyer's fill the volume.
--  Four tiles apart is one node per sixteen the walker would have, still
--  well inside NAV_MAX_DISTANCE, and the leg is string-pulled to the
--  farthest visible node anyway, so intermediate nodes were never walked
--  to. The 2x2 window is unchanged: it is a body-fit sample at the origin.
--
--  The stride is part of what a cell key MEANS, so it is per profile and
--  never mixed: a free mover's store is keyed at its own stride.
--  BACK TO 1, 2026-09-06 (Lofty): the sparse grid lost the granularity a
--  2x2 zigzag tunnel needs. Density is cut by WHERE a free mover anchors
--  instead -- see the surface test in petports_navAnchor. Kept as a knob.
PETPORTS_NAV_STRIDE_FREE = 1

--  READ ONCE PER TICK. 2026-09-06: this was calling petports_freeMover()
--  on every call, and petports_freeMover() reads mcontroller.baseParameters()
--  -- the whole movement parameter table converted to Lua -- and navStride
--  sits under navCellOrigin, which the candidate walk, the coverage test,
--  the anchor scan and the neighbour box call once PER CELL. Thousands of
--  full parameter conversions per tick, every tick the unit existed, which
--  is the stutter that only stopped when the flyer was despawned. The
--  stride cannot change within a tick; world.time() is the tick stamp.
local function navStride()
	local now = world.time()

	if self.petportsNavStrideAt ~= now then
		self.petportsNavStrideAt = now
		self.petportsNavStride = PETPORTS_NAV_STRIDE

		if petports_freeMover ~= nil and petports_freeMover() then
			self.petportsNavStride = PETPORTS_NAV_STRIDE_FREE
		end
	end

	return self.petportsNavStride
end

--  The world position of a cell's bottom-left tile corner.
local function navCellOrigin(cx, cy)
	local stride = navStride()
	return cx * stride, cy * stride
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

--  FOUR CELLS FOR A FREE MOVER, 2026-09-09r. MEASURED 14:42: 76,000 edges
--  on 1,200 cells -- 63 a cell -- because in open water every cell within
--  twelve is visible from every other. A free mover string-pulls, so a long
--  clear line is found at execution from the short hops; the long edges
--  were redundant and cost a minute of "still building" per rebuild and
--  67 ms candidate walks. Eight tiles keeps every cell connected to its
--  neighbourhood. Walkers keep 12: their edges are paths.
PETPORTS_NAV_RADIUS_FREE = 4

--  The full radius for the side being surveyed.
local function navFullRadius()
	if petports_freeMover ~= nil and petports_freeMover() then
		return PETPORTS_NAV_RADIUS_FREE
	end
	return PETPORTS_NAV_RADIUS
end
--  4 -> 2, 2026-09-08x (Lofty): the first pass touches only the cells right
--  beside a swept one, so the frontier moves in small, visible steps and a
--  cell's nearest edges exist before anything wider is tried.
PETPORTS_NAV_RADIUS_START = 2
PETPORTS_NAV_RADIUS_STEP = 2

--  The radius a cell should be swept at next, given the largest radius it
--  has already been swept at. nil when it is done.
local function navNextRadius(sweptRadius)
	if (sweptRadius or 0) >= navFullRadius() then return nil end
	if (sweptRadius or 0) <= 0 then return PETPORTS_NAV_RADIUS_START end
	return math.min(sweptRadius + PETPORTS_NAV_RADIUS_STEP, navFullRadius())
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
--  CLAMPED TO THE COVERAGE ITSELF, 2026-09-06 (Lofty). The margin below
--  was a sweep's reach so the rim would be complete; it also let nodes sit
--  up to twelve tiles outside every port's rectangle, and a swimmer on a
--  megabase was surveying the open water below the network for edges that
--  do not exist. The roam-outside allowance was written for a one-port base
--  whose pet sometimes had to step out; on a megabase it makes the edges
--  unreliable. So: a node is inside a port rectangle or it is not a node.
--  The rim is complete anyway -- the candidate walk stops at the boundary,
--  so no cell inside is half-known. Two tiles of slack for arrival.
local NAV_COVERAGE_MARGIN = 2

--  A box version for the free-mover rules: entirely inside some rectangle.
local function navBoxInCoverage(x0, y0, x1, y1)
	local rects = self.petportsNetwork

	if type(rects) ~= "table" or #rects == 0 then return true end

	for _, rect in ipairs(rects) do
		if x0 >= rect[1] - NAV_COVERAGE_MARGIN
		   and x1 <= rect[3] + NAV_COVERAGE_MARGIN
		   and y0 >= rect[2] - NAV_COVERAGE_MARGIN
		   and y1 <= rect[4] + NAV_COVERAGE_MARGIN then
			return true
		end
	end

	return false
end

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

	local stride = navStride()
	return math.floor(position[1] / stride),
		math.floor(position[2] / stride)
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

--  CACHED WITH THE ANCHORS (same TTL, same wipe), 2026-09-06s. PROFILED:
--  pointTileCollision at 1,200-1,300 per second was this, four per cell
--  for every cell in every neighbour box, never remembered.
--  How long an anchor or a solid verdict is remembered; see petports_navAnchor.
local NAV_ANCHOR_TTL = 30.0

local function navCellSolidUncached(cx, cy)
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

local function navCellSolid(cx, cy)
	local key = petports_navCellKey(cx, cy)
	local now = world.time()

	self.petportsNavSolidCache = self.petportsNavSolidCache or {}
	local hit = self.petportsNavSolidCache[key]

	if hit ~= nil and (now - hit.at) <= (NAV_ANCHOR_TTL or 30.0) then
		return hit.solid
	end

	local solid = navCellSolidUncached(cx, cy)
	self.petportsNavSolidCache[key] = { at = now, solid = solid }

	return solid
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

--  CACHED, 2026-09-06r. PROFILED: with the graph rebuild gone, the largest
--  survey cost per 5 s was `neighbours` (250-380 ms) against `probeStep`
--  (100-300 ms) -- the anchor scan over the 9x9 neighbour box, four to
--  six world calls per cell, 80 cells per sweep, seven sweeps a second,
--  re-asked for the same cells by every overlapping sweep. An anchor is a
--  fact about the tiles, which change rarely; thirty seconds is the same
--  horizon the cell cache uses. Keyed by profile so a chassis change gets
--  its own answers; nil results are cached too (an air cell is the common
--  case and the expensive one to keep re-scanning). Wipe clears it.
--  NAV_ANCHOR_TTL is declared above navCellSolid, which shares it.

local function navAnchorUncached(cx, cy, freeMover)
	local baseX, baseY = navCellOrigin(cx, cy)

	local bounds = mcontroller.boundBox()

	--  How far the body position sits ABOVE its own feet. bounds[2] is the
	--  lower extent and is negative, so this is a positive lift.
	local lift = -(bounds[2] or -0.5)

	local tried = 0

	if freeMover then
		--  ONE CANDIDATE, THE WINDOW CENTRE, 2026-09-06w. The four tile-centre
		--  candidates were both the double layer and the dead end:
		--
		--  DOUBLE: cell (x,y) at its upper-row candidate and cell (x,y+1) at
		--  its lower-row candidate are the SAME point, so every surface got
		--  two cells per anchor, like the walker's second row before 05h.
		--
		--  DEAD END (13:32 log, 20 cells then COMPLETE): a tile-centre body
		--  overhangs 0.3 into the next row, so the cell beside a floor never
		--  fits, and the cell beyond it sits 0.7 clear -- outside 06u's 0.3
		--  growth. Floors and ceilings anchored nothing; only vertical walls
		--  did, and the survey stopped at the first corner.
		--
		--  The window centre (origin + 1, origin + 1) puts the body 0.2 from
		--  the surface beside it, fits a 2-wide tunnel exactly (1.6 in 2.0),
		--  and sits on the node lattice. Growth 0.5 takes the 0.2 and refuses
		--  the 1.2 of the next cell out: one layer, every surface.
		--
		--  THE WHOLE BODY, NOT A POINT. pointTileCollision would pass a
		--  flyer through a one-tile gap it cannot fit in. Platform is absent
		--  from the set deliberately: a platform is passable to something
		--  that ignores gravity. Dynamic is present because
		--  fact.pathing.collisionkinds says Dynamic is DOORS, and a closed
		--  door stops a flyer.
		local point = {
			baseX + PETPORTS_NAV_CELL * 0.5, baseY + PETPORTS_NAV_CELL * 0.5
		}
		local region = {
			point[1] + bounds[1], point[2] + bounds[2],
			point[1] + bounds[3], point[2] + bounds[4]
		}

		tried = tried + 1

		--  THE POLY, 2026-09-09h (petports_bodyHitsAt); `region` stays for
		--  the near-surface and coverage tests below.
		local ok, hit = true, petports_bodyHitsAt(point, { "Null", "Block", "Dynamic", "Slippery" })

		--  NEAR A SURFACE, OR NOT A NODE (Lofty, 2026-09-06). Open air needs
		--  no nodes -- a leg string-pulls across it to the farthest visible
		--  node -- but the nodes must TRACE the walls, so a 2x2 tunnel that
		--  zigzags through the interior keeps a node in every cell. Cells in
		--  the middle of a room anchor nothing. The store follows geometry.
		local nearSurface = false

		if ok and hit == false then
			local grown = {
				region[1] - 0.5, region[2] - 0.5, region[3] + 0.5, region[4] + 0.5
			}

			local okNear, near = pcall(world.rectTileCollision, grown,
				{ "Block", "Dynamic", "Slippery", "Platform" })

			--  THE COVERAGE EDGE IS A WALL TOO (Lofty, 2026-09-06): a free
			--  mover's nodes trace it like any other surface, so a swimmer in
			--  open water gets a rim of nodes along the network boundary and
			--  nothing beyond it.
			local insideGrown = navBoxInCoverage(
				grown[1], grown[2], grown[3], grown[4])
			local insideBody = navBoxInCoverage(
				region[1], region[2], region[3], region[4])

			nearSurface = insideBody
				and ((okNear and near == true) or not insideGrown)

			--  A WALL OF DENIED LIQUID IS A SURFACE, 2026-09-08e. MEASURED
			--  15:45: `coarse nav has no leg` sixty times with the fish behind
			--  the poison maze -- the maze's corridors are water bounded by
			--  poison, not blocks, so no cell inside them was near a solid and
			--  none anchored; to the graph they were open water. For the
			--  profile the liquid is a wall for, a denied tile within the
			--  grown box is as good as a block: the corridor gets anchors, the
			--  edges between them are swept against the wall, and the maze is
			--  shoreline. The body box itself must still be clean, which
			--  petports_mediumAllows enforces below.
			--  A CHANGE OF MEDIUM IS A SURFACE, 2026-09-09l (Lofty): a swimmer
			--  under open water with air above it, a flyer over water -- the
			--  boundary is the thing to hug and the solids test cannot see it.
			--  Any tile in the grown box whose wetness differs from the tile
			--  under the body's centre makes this cell near a surface. Nine
			--  liquidAt calls on an anchor miss that had none.
			if insideBody and not nearSurface then
				local okC, centreLevel = pcall(world.liquidAt, { point[1], point[2] })
				local centreWet = okC and centreLevel ~= nil
					and (centreLevel[2] or 0) >= (PETPORTS_SUBMERGED_FILL or 0.5)
				--  FOUR SAMPLES, 2026-09-09p: the midpoints of the grown box's four
				--  edges. Nine per anchor miss was 4,700-6,700 liquidAt a second
				--  (MEASURED 14:30). A surface within half a tile of the body
				--  crosses one of the four.
				local midX, midY = (grown[1] + grown[3]) * 0.5, (grown[2] + grown[4]) * 0.5
				for _, sample in ipairs({
					{ grown[1] + 0.05, midY }, { grown[3] - 0.05, midY },
					{ midX, grown[2] + 0.05 }, { midX, grown[4] - 0.05 }
				}) do
					local okT, level = pcall(world.liquidAt, sample)
					local wet = okT and level ~= nil
						and (level[2] or 0) >= (PETPORTS_SUBMERGED_FILL or 0.5)
					if wet ~= centreWet then nearSurface = true end
				end
			end

			if insideBody and not nearSurface and navForbiddenCells ~= nil then
				local walls = navForbiddenCells()
				if next(walls) ~= nil then
					local x0, y0 = math.floor(grown[1]), math.floor(grown[2])
					local x1, y1 = math.floor(grown[3] - 0.01), math.floor(grown[4] - 0.01)
					for ty = y0, y1 do
						for tx = x0, x1 do
							if walls[tx .. "," .. ty] ~= nil then nearSurface = true end
						end
					end
				end
			end
		end

		--  AND THE MEDIUM, as for a walker: a flyer's anchor in water it
		--  cannot enter is a node it can never reach.
		if ok and hit == false and nearSurface then
			local okMedium, allowed = pcall(petports_mediumAllows, point, bounds)

			if not okMedium or allowed ~= false then return point end
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
				--  THE UNIT'S OWN avoidLiquid, NOT false. Measured 2026-09-05
				--  05:23: the anchor rule passed avoidLiquid false and accepted
				--  [2533.5,1158.8] in water; the unit's pather, built with
				--  avoidLiquid true, refused that target outright -- no search,
				--  no SEARCH_LIMIT, no contradiction, a progress-strike loop.
				--  The anchor must be a point the unit's own find() will take.
				local ok, standable = pcall(validStandingPosition, point,
					petports_avoidLiquid())

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

--  EVICTED WHOLESALE ON THE TTL, 2026-09-07i. Entries were checked for age
--  on read but never removed, so over hours every cell ever scanned by a
--  neighbour box (a 25x25 box per sweep at radius 12) stayed in the
--  anchor and solid caches forever. Clearing both every NAV_ANCHOR_TTL
--  bounds them to what one TTL's worth of sweeps touched.
--  EVERYTHING THIS UNIT REMEMBERS ABOUT THE STORE, DROPPED. Own wipe and
--  another unit's wipe (seen through NAV_GEN) both land here.
local function navDropMemos(generation)
	self.petportsNavPending = {}
	self.petportsNavPendingCount = 0
	self.petportsNavFlushAt = nil
	self.petportsNavCellCache = {}
	self.petportsNavGraph = nil
	self.petportsNavGraphBuild = nil
	self.petportsNavMerged = nil
	self.petportsNavMergedBuild = nil
	self.petportsNavComplete = {}
	self.petportsNavPassRadius = nil
	self.petportsNavIndexPending = nil
	self.petportsNavIndexPendingCount = 0
	self.petportsNavIndexMemo = nil
	self.petportsNavAnchorCache = nil
	self.petportsNavSolidCache = nil
	self.petportsNavSweeps = nil
	self.petportsNavProbes = nil
	self.petportsNavBoundsMine = nil
	self.petportsNavBoundsPendingCount = 0
	self.petportsNavBoundsSeen = nil
	self.petportsNavIndexMine = nil
	self.petportsNavForbidden = nil
	self.petportsNavForbiddenAt = nil
	self.petportsNavBoundsDraw = nil
	self.petportsNavBoundsDrawAt = nil
	self.petportsNavContradictQueue = nil
	self.petportsNavBoundsFlood = nil
	self.petportsNavBoundsFound = nil
	self.petportsNavSeeds = nil
	self.petportsNavBoundsLocal = nil
	self.petportsNavLastRoute = nil
	self.petportsNavSurveyNote = nil
	self.petportsNavVersion = (self.petportsNavVersion or 0) + 1
	self.petportsNavGen = generation
end

--  ANOTHER UNIT WIPED: the generation moved, drop everything now rather
--  than serving a graph of cells that no longer exist for two minutes.
--
--  CALLED BEFORE ANY WRITE-BACK, 2026-09-08u. MEASURED 18:00 (Lofty): after
--  a wipe the overlay still drew swept cells and the survey sat idle. The
--  wiping unit cleared the index; another unit's flush ran at the top of
--  its nav tick, BEFORE this check (which only ran on an anchor lookup),
--  and re-asserted its remembered entries (08n) into the empty index --
--  index entries for cells whose shards were gone. The survey then held
--  those cells as swept to their old radius and never re-swept them, and
--  the graph read empty shards. Once per tick, from navTickInner first and
--  from every flush, so nothing remembered from before a wipe is written
--  after it.
--  THE CURRENT GENERATION. Everything written into the store carries it
--  (edge entries `g`, index entries `g`, boundary records `g`) and every
--  read ignores an entry from any other generation. 2026-09-08v: the wipe
--  enumerates the store through its indices and the indices do not list
--  everything (MEASURED: 178 properties wiped where 331 had been; a shard
--  whose index entry was lost survived, and the next sweep of that cell
--  merged into it and carried a stale TRUE edge through the poison
--  forward, `coarse leg from 2518,1141 ... heading for [2514,1142]`, the
--  unit beached in it). World properties cannot be listed, so enumeration
--  can never be trusted; the generation can. A wipe is the bump, and what
--  the enumerator missed becomes unreadable instead of resurrected.
navGenNow = function()
	navGenerationCheck()
	if self.petportsNavGen == nil then
		local ok, gen = pcall(world.getProperty, NAV_GEN)
		self.petportsNavGen = (ok and type(gen) == "number") and gen or 0
	end
	return self.petportsNavGen
end

navGenerationCheck = function()
	local now = world.time()
	if self.petportsNavGenAt == now then return end
	self.petportsNavGenAt = now

	local ok, gen = pcall(world.getProperty, NAV_GEN)
	gen = (ok and type(gen) == "number") and gen or 0

	if self.petportsNavGen == nil then
		self.petportsNavGen = gen
	elseif gen ~= self.petportsNavGen then
		sb.logInfo("NAV generation %s -> %s: another unit wiped the store, "
			.. "dropping memos", sb.printJson(self.petportsNavGen), sb.printJson(gen))
		navDropMemos(gen)
	end
end

local function navCachesTick()
	local now = world.time()

	if self.petportsNavCachesAt == nil
	   or (now - self.petportsNavCachesAt) > NAV_ANCHOR_TTL then
		self.petportsNavCachesAt = now
		self.petportsNavAnchorCache = nil
		self.petportsNavSolidCache = nil
	end

	navGenerationCheck()
end

function petports_navAnchor(cx, cy, freeMover)
	navCachesTick()

	local key = petports_navCellKey(cx, cy)
	local profile = petports_navProfile()
	local now = world.time()

	self.petportsNavAnchorCache = self.petportsNavAnchorCache or {}
	local cache = self.petportsNavAnchorCache[profile]

	if cache == nil then
		cache = {}
		self.petportsNavAnchorCache[profile] = cache
	end

	local hit = cache[key]

	if hit ~= nil and (now - hit.at) <= NAV_ANCHOR_TTL then
		return hit.anchor, hit.why
	end

	local anchor, why = navAnchorUncached(cx, cy, freeMover)
	cache[key] = { at = now, anchor = anchor, why = why }

	--  BOUNDARY DISCOVERY RIDES ON THE MISS, 2026-09-07x. Every cell the
	--  survey ever asks about, both sides, once per TTL. See NAV_BOUNDS.
	if navInCoverage(cx, cy) then navBoundaryNote(cx, cy) end

	return anchor, why
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
local NAV_NEIGHBOUR_CHUNK = 40

function petports_navNeighbours(cx, cy, freeMover, radius)
	--  THE RADIUS IS THE CALLER'S. A sweep passes the rung of the ladder it is
	--  on; anything else gets the ceiling.
	radius = radius or navFullRadius()

	local origin = petports_navAnchor(cx, cy, freeMover)
	if origin == nil then return {}, nil end

	--  Cells that COULD hold something within the radius. Rounded up, then
	--  filtered by true anchor distance below -- the box is a cheap prefilter
	--  and the distance test is the actual rule.
	local reach = math.ceil(radius / navStride())

	local found = {}
	local solid = 0

	--  YIELDS FROM INSIDE A SWEEP, 2026-09-07r. MEASURED 02:14 on 07p:
	--  neighbours max 66 ms in one call, inside a sweepStep of 76, and
	--  20-40 ms in three more windows. This scan is the first thing the
	--  sweep coroutine does and it never yielded: up to (2r+1)^2 = 625 cells
	--  at radius 12, each a navCellSolid tile query and a petports_navAnchor
	--  (a footing scan or a body fit whenever the 30 s cache is cold), in ONE
	--  resume -- which is why the per-turn budget, checked between resumes,
	--  could not cut it. Every NAV_NEIGHBOUR_CHUNK cells inspected it now
	--  yields IF it is running inside a coroutine (coroutine.running() is
	--  nil on the main thread in Lua 5.1), so the sweep spreads its scan
	--  over resumes like its probes. petports_navSelfTest calls this from
	--  the main thread and is unchanged.
	local inspected = 0
	local inCoroutine = coroutine.running() ~= nil

	for dx = -reach, reach do
		for dy = -reach, reach do
			if dx ~= 0 or dy ~= 0 then
				local nx, ny = cx + dx, cy + dy

				inspected = inspected + 1
				if inCoroutine and inspected % NAV_NEIGHBOUR_CHUNK == 0 then
					--  THE SECTION IS CLOSED ACROSS THE YIELD, 2026-09-07s. The
					--  profWrap around this function opens "neighbours" on entry and
					--  closes it on return, so with a yield in the middle it counted
					--  wall time across resumes: 357, 1074 and 2750 ms in the first
					--  log on 07r, none of it real (tick max was 57).
					petports_profEnd("neighbours")
					coroutine.yield()
					petports_profBegin("neighbours")
				end

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
--  PER TICK, 2026-09-06s. This reads world.monsterType, baseParameters
--  (through petports_freeMover), boundBox and two config keys, then
--  formats -- and 06r put it under petports_navAnchor, which the neighbour
--  box calls 80 times a sweep. PROFILED: neighbours did not fall at all
--  after the anchor cache, because the cache lookup itself paid for a
--  profile. None of the inputs change within a tick.
local function navProfileUncached()
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

	--  avoidLiquid IS PART OF THE CAPABILITY, 2026-09-05: two chassis that
	--  differ only in it anchor different cells and must not share a store.
	return string.format("%s|f%s|b%s|l%s|d%s|a%s",
		tostring(monsterType),
		freeMover and "1" or "0",
		string.format("%.2f,%.2f",
			(bounds[3] or 0) - (bounds[1] or 0),
			(bounds[4] or 0) - (bounds[2] or 0)),
		table.concat(liquids, "+"),
		tostring(config.getParameter("petports_canOpenDoors", nil)),
		petports_avoidLiquid() and "1" or "0")
end

--  MEMOISED PER SIDE, 2026-09-07u. The survey and the task action can ask
--  in the same tick with different answers (see navWithSide), so the memo
--  is keyed on the side as well as the tick.
function petports_navProfile()
	local now = world.time()
	local side = petports_freeMover() and "1" or "0"

	if self.petportsNavProfileAt ~= now or self.petportsNavProfileMemo == nil then
		self.petportsNavProfileAt = now
		self.petportsNavProfileMemo = {}
	end

	if self.petportsNavProfileMemo[side] == nil then
		self.petportsNavProfileMemo[side] = navProfileUncached()
	end

	return self.petportsNavProfileMemo[side]
end

--  RUN fn AS ONE SIDE OF A SWITCHABLE CHASSIS.
--
--  2026-09-07u. The whole survey path -- profile string, anchors, medium
--  permission, avoidLiquid, and which probe (A* or body sweep) -- branches on
--  petports_freeMover(). A gravity-switchable unit surveying the side it is
--  NOT in needs every one of those to answer for that side at once, and
--  patching them one by one would be four spellings of one question
--  (arch.pathing.oneanchor). So the predicate itself carries an override,
--  set here for exactly the duration of one piece of survey work and
--  restored on the way out, error or not. Routing never runs inside this,
--  so it always sees the live mode.
--
--  A NO-OP FOR A CHASSIS THAT CANNOT SWITCH: the override equals the live
--  answer and every caller gets what it always got.
local function navWithSide(freeMover, fn, ...)
	local held = self.petportsNavSurveyFree
	self.petportsNavSurveyFree = freeMover

	local results = { pcall(fn, ...) }

	self.petportsNavSurveyFree = held

	if not results[1] then error(results[2], 0) end
	--  table.unpack, NOT unpack: Starbound's Lua has no global unpack.
	--  Measured 2026-09-06 14:03, every unit's update() threw on it.
	return select(2, table.unpack(results))
end

--  WHICH SIDE THIS TOP-UP SURVEYS. A switchable chassis alternates every
--  top-up so both stores grow whichever mode it is in; anything else surveys
--  the side it is, which is the only side it has.
local function navSurveySide()
	if not petports_gravitySwitchable() then return petports_freeMover() end

	self.petportsNavSideFlip = not self.petportsNavSideFlip
	return self.petportsNavSideFlip == true
end

--  ------------------------------------------------------------------ STORE

local function navEdgeKey(fromKey, toKey)
	return fromKey .. ">" .. toKey
end

--  INDEX WRITES ARE BATCHED, 2026-09-06. MEASURED: a free mover's sweeps
--  complete in one step (body sweep), so 490 sweeps in a short window meant
--  490 whole-index world.setProperty calls plus two claim writes each --
--  on the world thread, which is the physics stutter that was seen. Own
--  entries are held in petportsNavIndexPending, merged into every read so
--  this unit sees its own work at once, and written with the edge flush.
--  Another unit sees them a flush later, which the claim already covers.
--  AND READ AT MOST ONCE PER TICK. 2026-09-06: the idle top-up read it
--  twice every two seconds (purge, then candidates) -- the index holds
--  EVERY profile's cells, so on a multi-chassis base that is a JSON-to-Lua
--  conversion of a thousand-entry table, twice, on a two-second beat, which
--  is the idle spike at that cadence. Memoised on world.time(); a write
--  through navIndexFlush or navIndexWrite drops the memo.
--  ONE PROPERTY PER PROFILE, 2026-09-07k. MEASURED 19:39: a freshly
--  socketed unit's first two updates took ~1 s each, entirely in the first
--  index read -- every profile's cells in one property, converted whole on
--  every read, and reads happen on every top-up. The index grew with hours
--  of survey across three chassis and every read paid for all of it. Now
--  `petports_navindex:<profile>` holds one profile's cells and a unit only
--  ever converts its own; `petports_navindex` itself is a registry of
--  profile names so wipe and stats can still enumerate everything.
--
--  navIndexRead() keeps its shape -- a table indexed by profile -- but the
--  profiles load lazily through a metatable, so `index[profile]` costs one
--  read of one profile, memoised per tick. pairs() over it sees only the
--  profiles touched this tick; enumerate with navIndexProfiles().
local function navIndexProperty(profile)
	return NAV_INDEX .. ":" .. profile
end

local function navIndexProfiles()
	local ok, registry = pcall(world.getProperty, NAV_INDEX)
	if not ok or type(registry) ~= "table" then return {} end

	local names = {}
	for profile in pairs(type(registry.profiles) == "table" and registry.profiles or {}) do
		table.insert(names, profile)
	end
	table.sort(names)
	return names
end

--  ------------------------------------------------------ BOUNDARY STORE

local function navBoundsIndexProperty(bucket)
	return NAV_BOUNDS .. ":" .. bucket
end

local function navBoundsCellProperty(bucket, cellKey)
	return NAV_BOUNDS .. ":" .. bucket .. ":" .. cellKey
end

local function navBoundsFamilyEnumerate()
	local names = {}

	local ok, registry = pcall(world.getProperty, NAV_BOUNDS)
	if not ok or type(registry) ~= "table" then registry = {} end

	for bucket in pairs(registry) do
		local okCells, cells = pcall(world.getProperty, navBoundsIndexProperty(bucket))
		if okCells and type(cells) == "table" then
			for cellKey in pairs(cells) do
				table.insert(names, navBoundsCellProperty(bucket, cellKey))
			end
		end
		table.insert(names, navBoundsIndexProperty(bucket))
	end

	table.insert(names, NAV_BOUNDS)
	return names
end

--  The liquid's first configured name, memoised; "air" for none.
local function navLiquidName(level)
	local fill = (level ~= nil) and (level[2] or 0) or 0
	if level == nil or fill < NAV_BOUNDS_FILL then return "air" end

	local id = level[1]
	self.petportsNavLiquidNames = self.petportsNavLiquidNames or {}

	if self.petportsNavLiquidNames[id] == nil then
		local names = petports_habitatLiquidNames ~= nil
			and petports_habitatLiquidNames(id) or nil
		self.petportsNavLiquidNames[id] = (type(names) == "table" and names[1])
			or tostring(id)
	end

	return self.petportsNavLiquidNames[id]
end

--  PENDING BOUNDARY WRITES, batched like the edge index: the record goes out
--  at once (it is small and rare), the bucket index and registry go out with
--  petports_navFlush so a shoreline of a hundred cells is not a hundred
--  whole-index writes on the world thread (the 07k lesson).
--  EVERY UNIT RE-ASSERTS WHAT IT CONTRIBUTED, 2026-09-08n. The bucket index
--  is one property that several units read-merge-write; two flushes that
--  interleave drop each other's entries, and the record survives while the
--  index -- which the overlay AND the wall set read -- forgets it. So a
--  unit keeps every cell it ever queued (petportsNavBoundsMine) and on each
--  flush writes the index only if any of its own cells are missing from
--  what it read. Last-write-wins still loses an entry for one flush; the
--  loser puts it back on its next. Dropped with the other memos on a wipe,
--  which is when the store no longer has the records either.
local function navBoundsQueue(bucket, cellKey)
	self.petportsNavBoundsMine = self.petportsNavBoundsMine or {}
	self.petportsNavBoundsMine[bucket] = self.petportsNavBoundsMine[bucket] or {}
	self.petportsNavBoundsMine[bucket][cellKey] = true
	self.petportsNavBoundsPendingCount = (self.petportsNavBoundsPendingCount or 0) + 1
end

local function navBoundsFlush()
	navGenerationCheck()
	if (self.petportsNavBoundsPendingCount or 0) == 0 then return end

	navFamilyRegister(NAV_BOUNDS, navBoundsFamilyEnumerate)

	local ok, registry = pcall(world.getProperty, NAV_BOUNDS)
	if not ok or type(registry) ~= "table" then registry = {} end
	local registryChanged = false

	for bucket, cells in pairs(self.petportsNavBoundsMine or {}) do
		local okIndex, index = pcall(world.getProperty, navBoundsIndexProperty(bucket))
		if not okIndex or type(index) ~= "table" then index = {} end

		local missing = false
		for cellKey in pairs(cells) do
			if index[cellKey] ~= true then
				index[cellKey] = true
				missing = true
			end
		end

		if missing then
			pcall(world.setProperty, navBoundsIndexProperty(bucket), index)
		end

		if registry[bucket] ~= true then
			registry[bucket] = true
			registryChanged = true
		end
	end

	if registryChanged then pcall(world.setProperty, NAV_BOUNDS, registry) end

	self.petportsNavBoundsPendingCount = 0
end

--  LOOK AT ONE CELL'S WINDOW AND RECORD IT IF LIQUID MEETS SOMETHING ELSE.
--
--  A cell is a boundary when its four tiles are not all the same medium:
--  air over water is the surface, water beside poison is a pocket edge.
--  Solids are not a medium here -- a solid tile reads as whatever liquid is
--  in it, usually none, and a wall between water and air is not a crossing
--  a body can make; the anchor rules and the fit test already refuse it.
--
--  MEMOISED PER CELL for NAV_ANCHOR_TTL on the unit, so a cell the survey
--  keeps asking about is sampled once per TTL; the store itself is the
--  cross-unit memo. Only writes when the record changed, so a stable
--  shoreline is read once and never rewritten.
navBoundaryNote = function(cx, cy)
	self.petportsNavBoundsSeen = self.petportsNavBoundsSeen or {}
	local cellKey = petports_navCellKey(cx, cy)
	local now = world.time()
	local seen = self.petportsNavBoundsSeen[cellKey]

	self.petportsNavBoundsFound = self.petportsNavBoundsFound or {}

	if seen ~= nil and (now - seen) <= NAV_ANCHOR_TTL then
		return self.petportsNavBoundsFound[cellKey] == true
	end
	self.petportsNavBoundsSeen[cellKey] = now
	self.petportsNavBoundsFound[cellKey] = false

	local baseX, baseY = navCellOrigin(cx, cy)
	local media = {}
	local liquids = {}
	local distinct = 0
	local first = nil
	local same = true
	local top = nil

	for dy = 0, PETPORTS_NAV_CELL - 1 do
		for dx = 0, PETPORTS_NAV_CELL - 1 do
			local ok, level = pcall(world.liquidAt, { baseX + dx + 0.5, baseY + dy + 0.5 })
			local name = navLiquidName(ok and level or nil)

			media[dx .. "," .. dy] = name

			if name ~= "air" then
				if not liquids[name] then
					liquids[name] = true
					distinct = distinct + 1
				end
				if top == nil or baseY + dy > top then top = baseY + dy end
			end

			if first == nil then first = name elseif name ~= first then same = false end
		end
	end

	--  AN ALL-DENIED WINDOW IS NOT A BOUNDARY BUT THE FLOOD WALKS THROUGH IT,
	--  2026-09-08n. MEASURED 17:08-17:12 (Lofty's probes): a two-wide poison
	--  column, west face recorded, east face never sampled -- the west
	--  face's flood pushed the all-poison interior window, which is
	--  correctly not a boundary and so pushed nothing, and the east face is
	--  two cells off, outside the 8-neighbourhood. An interior window whose
	--  one liquid this unit denies queues its neighbours anyway, so a
	--  pocket's shell is found from any side. All-water windows still stop
	--  the flood, or it would walk the ocean.
	if same and distinct == 1 and first ~= "air"
	   and petports_liquidNameDenied ~= nil and petports_liquidNameDenied(first) then
		self.petportsNavBoundsFlood = self.petportsNavBoundsFlood or {}
		for ndy = -1, 1 do
			for ndx = -1, 1 do
				if (ndx ~= 0 or ndy ~= 0) and navInCoverage(cx + ndx, cy + ndy) then
					local nkey = petports_navCellKey(cx + ndx, cy + ndy)
					local nseen = self.petportsNavBoundsSeen[nkey]
					if nseen == nil or (now - nseen) > NAV_ANCHOR_TTL then
						table.insert(self.petportsNavBoundsFlood, { cx + ndx, cy + ndy })
					end
				end
			end
		end
		return false
	end

	if same or distinct == 0 then return false end

	--  A BOUNDARY CELL'S NEIGHBOURS ARE WHERE THE REST OF THE BOUNDARY IS,
	--  2026-09-08i. Queue the eight around it for navBoundsFloodTick, so the
	--  shell is walked in seconds rather than discovered a cell at a time as
	--  survey passes widen (MEASURED 16:30: minutes parked beside the maze,
	--  one or two poison tiles appearing per pass).
	self.petportsNavBoundsFound[cellKey] = true
	self.petportsNavBoundsFlood = self.petportsNavBoundsFlood or {}
	for ndy = -1, 1 do
		for ndx = -1, 1 do
			if (ndx ~= 0 or ndy ~= 0) and navInCoverage(cx + ndx, cy + ndy) then
				local nkey = petports_navCellKey(cx + ndx, cy + ndy)
				local nseen = self.petportsNavBoundsSeen[nkey]
				if nseen == nil or (now - nseen) > NAV_ANCHOR_TTL then
					table.insert(self.petportsNavBoundsFlood, { cx + ndx, cy + ndy })
				end
			end
		end
	end

	local bounds = mcontroller.boundBox()
	local fit = {}

	for dx = 0, PETPORTS_NAV_CELL - 1 do
		local wetRow = nil
		for dy = 0, PETPORTS_NAV_CELL - 1 do
			if media[dx .. "," .. dy] ~= "air" then
				if wetRow == nil or baseY + dy > wetRow then wetRow = baseY + dy end
			end
		end

		if wetRow ~= nil then
			--  THE BODY IN THE AIR ABOVE THE WET TILE: feet on the surface,
			--  box up. A solid inside it is a lid, and the column is no
			--  opening for this body.
			local centre = { baseX + dx + 0.5, wetRow + 1 - (bounds[2] or -0.8) }
			local region = {
				centre[1] + bounds[1], centre[2] + bounds[2],
				centre[1] + bounds[3], centre[2] + bounds[4]
			}
			local okFit, hit = pcall(world.rectTileCollision, region, NAV_SOLID_SET)
			fit[tostring(dx)] = (okFit and hit == false) and true or false
		end
	end

	local names = {}
	for name in pairs(liquids) do table.insert(names, name) end
	table.sort(names)

	local bucket = string.format("%s|b%.2f,%.2f", table.concat(names, "+"),
		(bounds[3] or 0) - (bounds[1] or 0), (bounds[4] or 0) - (bounds[2] or 0))

	local record = { m = media, top = top, fit = fit, t = now, g = navGenNow() }

	local okOld, old = pcall(world.getProperty, navBoundsCellProperty(bucket, cellKey))
	if okOld and type(old) == "table" then
		local unchanged = old.top == top and old.g == record.g
		for k, v in pairs(media) do
			if type(old.m) ~= "table" or old.m[k] ~= v then unchanged = false end
		end
		for k, v in pairs(fit) do
			if type(old.fit) ~= "table" or old.fit[k] ~= v then unchanged = false end
		end
		if unchanged then
			navSeedBesideWall(cx, cy, media)

	--  A BOUNDARY THIS CHASSIS MAY CROSS IS A BRIDGE CANDIDATE, 2026-09-09t.
	--  Queued for navBridgeTick; re-examined every NAV_BRIDGE_SEEN_TTL.
	local crossable = petports_gravitySwitchable ~= nil and petports_gravitySwitchable()
	for _, name in ipairs(names) do
		if petports_liquidNameDenied ~= nil and petports_liquidNameDenied(name) then crossable = false end
	end
	if crossable then
		self.petportsNavBridgeSeen = self.petportsNavBridgeSeen or {}
		local bseen = self.petportsNavBridgeSeen[cellKey]
		if bseen == nil or (now - bseen) > NAV_BRIDGE_SEEN_TTL then
			self.petportsNavBridgeSeen[cellKey] = now
			self.petportsNavBridgeQueue = self.petportsNavBridgeQueue or {}
			self.petportsNavBridgeQueue[cellKey] = { cx = cx, cy = cy, bucket = bucket, record = record }
		end
	end
			return true
		end
	end

	pcall(world.setProperty, navBoundsCellProperty(bucket, cellKey), record)
	navBoundsQueue(bucket, cellKey)
	petports_profCount("boundary")

	--  KEPT LOCALLY FOR THE OVERLAY, 2026-09-08s: drawn the tick it is
	--  written, no index, no refresh timer.
	self.petportsNavBoundsLocal = self.petportsNavBoundsLocal or {}
	self.petportsNavBoundsLocal[cellKey] = { ox = baseX, oy = baseY, m = media, bucket = bucket }

	--  OWN WALLS ARE WALLS AT ONCE, 2026-09-08b. MEASURED 15:24:11: a leg
	--  2518,1141 -> 2507,1141 straight through the pocket, recorded TRUE by
	--  the sweep that had discovered the shell seconds before -- the bucket
	--  index had not flushed and the forbidden memo was still the old one,
	--  so the probe saw no wall. Same rule as the edge index: this unit sees
	--  its own writes immediately; others see them a flush later.
	local newTiles = nil
	for offset, name in pairs(media) do
		if name ~= "air" and petports_liquidNameDenied ~= nil
		   and petports_liquidNameDenied(name) then
			local dx, dy = string.match(offset, "^(%d+),(%d+)$")
			if dx ~= nil then
				newTiles = newTiles or {}
				newTiles[(baseX + tonumber(dx)) .. "," .. (baseY + tonumber(dy))] = bucket
			end
		end
	end

	if newTiles ~= nil then
		self.petportsNavForbidden = self.petportsNavForbidden or {}
		for tile, b in pairs(newTiles) do self.petportsNavForbidden[tile] = b end
		navContradictThrough(newTiles, cellKey)
	end

	navSeedBesideWall(cx, cy, media)

	--  A BOUNDARY THIS CHASSIS MAY CROSS IS A BRIDGE CANDIDATE, 2026-09-09t.
	--  Queued for navBridgeTick; re-examined every NAV_BRIDGE_SEEN_TTL.
	local crossable = petports_gravitySwitchable ~= nil and petports_gravitySwitchable()
	for _, name in ipairs(names) do
		if petports_liquidNameDenied ~= nil and petports_liquidNameDenied(name) then crossable = false end
	end
	if crossable then
		self.petportsNavBridgeSeen = self.petportsNavBridgeSeen or {}
		local bseen = self.petportsNavBridgeSeen[cellKey]
		if bseen == nil or (now - bseen) > NAV_BRIDGE_SEEN_TTL then
			self.petportsNavBridgeSeen[cellKey] = now
			self.petportsNavBridgeQueue = self.petportsNavBridgeQueue or {}
			self.petportsNavBridgeQueue[cellKey] = { cx = cx, cy = cy, bucket = bucket, record = record }
		end
	end

	if PETPORTS_NAV_VERBOSE then
		sb.logInfo("NAV boundary %s in %s: top %s, media %s, fit %s",
			cellKey, bucket, tostring(top), sb.printJson(media), sb.printJson(fit))
	end

	return true
end

--  EDGES ALREADY IN THE GRAPH THAT CROSS A WALL FOUND JUST NOW ARE
--  CONTRADICTED, 2026-09-08b. A pocket the player builds after the survey,
--  or one the survey finds late, would otherwise keep every TRUE edge
--  through it for the six-hour sweep TTL. Free-mover edges only: those are
--  straight segments and the test is exact. A walker's edge is a path the
--  engine found, which may well go round the pocket while the straight
--  line between its anchors goes through it, so a walker edge is left to
--  re-probe rather than falsely contradicted.
--
--  Bounded to edges whose FROM cell is within 2 * PETPORTS_NAV_RADIUS of
--  the boundary cell; no edge longer than the probe radius exists.
navContradictThrough = function(tiles, cellKey)
	--  QUEUED, NOT RUN HERE, 2026-09-08d. MEASURED 15:32:15: the pass over
	--  the whole swim graph (thousands of cells, a string.match each) ran
	--  inside the sweep coroutine for every new shell record and hit the
	--  Lua instruction limit -- `NAV sweep ... FAILED: userdata` is the
	--  engine's limit exception surfacing through the resume, tick max 174
	--  ms. navContradictTick below walks graph.fineKeys with a cursor, a
	--  bounded number of cells per tick, outside any coroutine.
	self.petportsNavContradictQueue = self.petportsNavContradictQueue or {}
	table.insert(self.petportsNavContradictQueue, { tiles = tiles, cellKey = cellKey })
end

local NAV_CONTRADICT_SCAN = 300
local NAV_CONTRADICT_BUDGET_MS = 2.0

--  ONE SLICE OF THE CONTRADICTION PASS. Two phases per job, 2026-09-08e:
--
--    scan   walk graph.fineKeys with a cursor, NAV_CONTRADICT_SCAN keys a
--           tick, keeping the froms within 2 * radius of the boundary cell
--           -- a string.match each and nothing else.
--    test   walk the kept froms' edges under a clock budget, anchors FROM
--           THE CACHE ONLY. MEASURED 15:44: forty froms a tick was 200 ms,
--           because a cold anchor is a collision test, a medium sample and
--           a boundary note that can queue another job. An edge whose
--           anchors are not cached is skipped, not resolved; the sweep TTL
--           still covers it.
local function navContradictTick()
	local queue = self.petportsNavContradictQueue
	if queue == nil or #queue == 0 then return end

	local graph = self.petportsNavGraph
	if graph == nil or type(graph.fine) ~= "table" or not petports_freeMover() then
		self.petportsNavContradictQueue = nil
		return
	end

	local job = queue[1]
	local profile = petports_navProfile()

	if job.froms == nil then
		if graph.fineKeys == nil then
			graph.fineKeys = {}
			for from in pairs(graph.fine) do table.insert(graph.fineKeys, from) end
			table.sort(graph.fineKeys)
		end

		local bx, by = string.match(job.cellKey, "^(-?%d+),(-?%d+)$")
		if bx == nil then table.remove(queue, 1) return end
		bx, by = tonumber(bx), tonumber(by)

		local keys = graph.fineKeys
		local total = #keys
		local cursor = job.cursor or 0
		local reach = PETPORTS_NAV_RADIUS * 2
		job.kept = job.kept or {}

		local scanned = 0
		while cursor < total and scanned < NAV_CONTRADICT_SCAN do
			cursor = cursor + 1
			scanned = scanned + 1
			local fromKey = keys[cursor]
			local fx, fy = string.match(fromKey, "^(-?%d+),(-?%d+)$")
			if fx ~= nil and math.abs(tonumber(fx) - bx) <= reach
			   and math.abs(tonumber(fy) - by) <= reach then
				table.insert(job.kept, fromKey)
			end
		end

		job.cursor = cursor
		if cursor >= total then
			job.froms = job.kept
			job.kept = nil
			job.at = 0
		end
		return
	end

	local began = navTickClock()
	local bounds = mcontroller.boundBox()
	local cache = (self.petportsNavAnchorCache or {})[profile] or {}

	local function cachedAnchor(key)
		local hit = cache[key]
		return hit ~= nil and hit.anchor or nil
	end

	while job.at < #job.froms do
		if began ~= nil and (navTickClock() - began) * 1000 >= NAV_CONTRADICT_BUDGET_MS then
			return
		end

		job.at = job.at + 1
		local fromKey = job.froms[job.at]
		local tos = graph.fine[fromKey]
		local from = cachedAnchor(fromKey)

		if tos ~= nil and from ~= nil then
			for k = #tos, 1, -1 do
				local toKey = tos[k]
				local to = cachedAnchor(toKey)

				if to ~= nil then
					local length = world.magnitude(from, to)
					local steps = math.max(1, math.ceil(length / 0.5))
					local hit = nil

					for step = 0, steps do
						local t = step / steps
						hit = navBoxForbidden(job.tiles, {
							from[1] + (to[1] - from[1]) * t, from[2] + (to[2] - from[2]) * t
						}, bounds)
						if hit ~= nil then break end
					end

					if hit ~= nil then
						petports_navContradict(profile, fromKey, toKey)
						job.dropped = (job.dropped or 0) + 1
					end
				end
			end
		end
	end

	if (job.dropped or 0) > 0 then
		sb.logInfo("NAV boundary %s contradicted %s edge(s) that crossed it for %s",
			tostring(job.cellKey), sb.printJson(job.dropped), tostring(profile))
	end
	table.remove(queue, 1)
end

--  A WALL THIS PROFILE CANNOT CROSS SEEDS THE SURVEY BESIDE IT, 2026-09-08i.
--  Since 08e a denied tile is a surface for the free-mover anchor, so the
--  cells beside a poison shell anchor -- but the survey only reaches them
--  when a widening pass from a swept cell happens to include them. Here a
--  found boundary with a denied liquid tests the eight cells around it for
--  a free-mover anchor and puts the anchored, unswept ones on the seed list
--  that petports_navCandidates considers every top-up. The graph then
--  creeps along the wall at survey speed instead of pass speed. Free-mover
--  side only; a walker does not route along a liquid wall.
navSeedBesideWall = function(cx, cy, media)
	if not petports_gravitySwitchable() and not petports_freeMover() then return end
	petports_profBegin("seedWall")

	local denied = false
	for _, name in pairs(media) do
		if name ~= "air" and petports_liquidNameDenied ~= nil
		   and petports_liquidNameDenied(name) then denied = true end
	end
	if not denied then petports_profEnd("seedWall") return end

	self.petportsNavSeeds = self.petportsNavSeeds or {}

	--  KEYS ONLY, 2026-09-09q. MEASURED 14:37: `flood max=61` -- each wall
	--  found by the flood anchor-tested eight neighbours here, each miss ran
	--  the poly, medium and surface tests and its own boundary note, which
	--  on a wall seeded eight more, inside one tick. The candidate scan
	--  anchor-tests what it considers anyway; a seed that cannot anchor is
	--  refused at sweep start for the price of one miss, on the survey's
	--  own budget.
	for ndy = -1, 1 do
		for ndx = -1, 1 do
			local nx, ny = cx + ndx, cy + ndy
			if navInCoverage(nx, ny) then
				self.petportsNavSeeds[petports_navCellKey(nx, ny)] = world.time()
			end
		end
	end
	petports_profEnd("seedWall")
end

local NAV_FLOOD_PER_TICK = 6

--  Declared with the flood, defined with the bridges below: navBoundaryNote
--  reads it and runs first.
NAV_BRIDGE_SEEN_TTL = 300.0

--  ONE SLICE OF THE BOUNDARY FLOOD. Pops queued neighbours of found
--  boundary cells and samples them; a find queues its own neighbours in
--  navBoundaryNote. Six cells a tick is 24 liquidAt calls.
local function navBoundsFloodTick()
	local queue = self.petportsNavBoundsFlood
	if queue == nil or #queue == 0 then return end

	local done = 0
	while #queue > 0 and done < NAV_FLOOD_PER_TICK do
		local cell = table.remove(queue)
		done = done + 1
		navBoundaryNote(cell[1], cell[2])
	end
end

--  ONE CELL, IN FULL, FOR /entityeval. What each of the four tiles holds
--  (liquid id, name, fill), what the boundary sampler would call it, and
--  what the store has for the cell in every bucket. `x, y` is any tile in
--  the cell.
function petports_navBoundsProbe(x, y)
	local cx, cy = petports_navCell({ x, y })
	local cellKey = petports_navCellKey(cx, cy)
	local baseX, baseY = navCellOrigin(cx, cy)
	local out = { cell = cellKey, tiles = {}, store = {} }

	for dy = 0, PETPORTS_NAV_CELL - 1 do
		for dx = 0, PETPORTS_NAV_CELL - 1 do
			local ok, level = pcall(world.liquidAt, { baseX + dx + 0.5, baseY + dy + 0.5 })
			local id = (ok and level ~= nil) and level[1] or nil
			local fill = (ok and level ~= nil) and (level[2] or 0) or 0
			out.tiles[(baseX + dx) .. "," .. (baseY + dy)] = {
				id = id,
				fill = fill,
				name = navLiquidName(ok and level or nil),
				denied = id ~= nil and petports_liquidDenied ~= nil
					and petports_liquidDenied(id) or false
			}
		end
	end

	out.indexed = {}
	local okReg, registry = pcall(world.getProperty, NAV_BOUNDS)
	if okReg and type(registry) == "table" then
		for bucket in pairs(registry) do
			local okRec, record = pcall(world.getProperty, navBoundsCellProperty(bucket, cellKey))
			if okRec and type(record) == "table" then out.store[bucket] = record end

			local okIdx, index = pcall(world.getProperty, navBoundsIndexProperty(bucket))
			out.indexed[bucket] = okIdx and type(index) == "table" and index[cellKey] == true or false
		end
	end
	out.registry = okReg and type(registry) == "table" and registry or "none"

	--  What this unit's wall set and overlay currently hold for the tiles.
	local walls = navForbiddenCells()
	out.walls = {}
	for dy = 0, PETPORTS_NAV_CELL - 1 do
		for dx = 0, PETPORTS_NAV_CELL - 1 do
			local tile = (baseX + dx) .. "," .. (baseY + dy)
			out.walls[tile] = walls[tile] or false
		end
	end

	out.drawn = false
	for _, entry in ipairs(self.petportsNavBoundsDraw or {}) do
		if entry.ox == baseX and entry.oy == baseY then out.drawn = entry.bucket end
	end
	out.drawAgo = self.petportsNavBoundsDrawAt ~= nil
		and (world.time() - self.petportsNavBoundsDrawAt) or nil
	out.drawRange = math.abs(baseX - mcontroller.position()[1]) <= NAV_DRAW_RANGE
		and math.abs(baseY - mcontroller.position()[2]) <= NAV_DRAW_RANGE

	out.seenAgo = self.petportsNavBoundsSeen ~= nil and self.petportsNavBoundsSeen[cellKey] ~= nil
		and (world.time() - self.petportsNavBoundsSeen[cellKey]) or nil
	out.found = self.petportsNavBoundsFound ~= nil and self.petportsNavBoundsFound[cellKey] or nil
	out.inCoverage = navInCoverage(cx, cy)

	sb.logInfo("NAV bounds probe %s", sb.printJson(out))
	return out
end

--  Counts for stats and the log: buckets and cells in the shared store.
function petports_navBoundsStats()
	local ok, registry = pcall(world.getProperty, NAV_BOUNDS)
	if not ok or type(registry) ~= "table" then return {} end

	local out = {}
	for bucket in pairs(registry) do
		local okCells, cells = pcall(world.getProperty, navBoundsIndexProperty(bucket))
		local count = 0
		if okCells and type(cells) == "table" then
			for _ in pairs(cells) do count = count + 1 end
		end
		out[bucket] = count
	end
	return out
end

--  THE BOUNDARY CELLS THIS PROFILE MAY NOT CROSS, AS A SET.
--
--  2026-09-07y, the first READER of the shared store. A bucket whose liquids
--  include one this chassis denies (petports_liquidNameDenied -- the same
--  deny set, with the same module unlocks) contributes every cell in its
--  index. A poison pocket in the ocean is a closed shell of `poison+water`
--  cells at cell resolution, so any segment or path into the pocket crosses
--  one of them, and the probe below refuses it there. A chassis with an
--  empty deny set reads nothing and pays one registry read per TTL.
--
--  PER TILE, NOT PER CELL, 2026-09-07z. Cells are 2x2 at a 1-tile stride,
--  so a shell cell's window overlaps its neighbours' -- and an anchor that
--  is itself clean sits inside a window with a poison tile in its other
--  column. MEASURED 14:59:14: `2517,1141 -> 2514,1141 UNREACHABLE: the line
--  crosses boundary cell 2517,1142`, an edge running along the row AWAY
--  from the pocket, refused because its origin shared a window with the
--  shell. A wrong FALSE is the expensive error here. The record carries the
--  medium per tile, so the set is the denied TILES, and a segment is
--  refused only when the body box actually overlaps one.
--
--  MEMOISED FOR NAV_ANCHOR_TTL on the unit; a wipe or generation bump drops
--  it with the other memos.
navForbiddenCells = function()
	local now = world.time()

	if self.petportsNavForbidden ~= nil
	   and (now - (self.petportsNavForbiddenAt or 0)) <= NAV_ANCHOR_TTL then
		return self.petportsNavForbidden
	end

	local cells = {}
	local buckets = 0

	local ok, registry = pcall(world.getProperty, NAV_BOUNDS)
	if ok and type(registry) == "table" then
		for bucket in pairs(registry) do
			local liquids = string.match(bucket, "^([^|]*)|") or ""
			local denied = false

			for name in string.gmatch(liquids, "[^+]+") do
				if petports_liquidNameDenied ~= nil and petports_liquidNameDenied(name) then
					denied = true
				end
			end

			if denied then
				local okIndex, index = pcall(world.getProperty, navBoundsIndexProperty(bucket))
				if okIndex and type(index) == "table" then
					buckets = buckets + 1
					for cellKey in pairs(index) do
						local okRec, record = pcall(world.getProperty,
							navBoundsCellProperty(bucket, cellKey))
						local bx, by = string.match(cellKey, "^(-?%d+),(-?%d+)$")

						if okRec and type(record) == "table" and type(record.m) == "table"
						   and record.g == navGenNow() and bx ~= nil then
							local baseX, baseY = navCellOrigin(tonumber(bx), tonumber(by))

							for offset, name in pairs(record.m) do
								local dx, dy = string.match(offset, "^(%d+),(%d+)$")
								if dx ~= nil and name ~= "air"
								   and petports_liquidNameDenied(name) then
									cells[(baseX + tonumber(dx)) .. "," .. (baseY + tonumber(dy))]
										= bucket
								end
							end
						end
					end
				end
			end
		end
	end

	self.petportsNavForbidden = cells
	self.petportsNavForbiddenAt = now

	if buckets > 0 and self.petportsNavForbiddenNoted ~= buckets then
		self.petportsNavForbiddenNoted = buckets
		local count = 0
		for _ in pairs(cells) do count = count + 1 end
		sb.logInfo("NAV %s denied-liquid tile(s) from %s bucket(s) are walls for %s",
			sb.printJson(count), sb.printJson(buckets), tostring(petports_navProfile()))
	end

	return cells
end

--  Does the body box at `position` overlap a forbidden tile? Returns the
--  tile key and bucket. The box is shrunk by a hair so a box exactly
--  flush with a tile edge does not count as inside it.
navBoxForbidden = function(forbidden, position, bounds)
	local x0 = math.floor(position[1] + bounds[1] + 0.01)
	local x1 = math.floor(position[1] + bounds[3] - 0.01)
	local y0 = math.floor(position[2] + bounds[2] + 0.01)
	local y1 = math.floor(position[2] + bounds[4] - 0.01)

	for ty = y0, y1 do
		for tx = x0, x1 do
			local key = tx .. "," .. ty
			if forbidden[key] ~= nil then return key, forbidden[key] end
		end
	end

	return nil
end

--  The first forbidden tile the body touches along a straight segment, or
--  nil. Half-tile steps against a 1.6 body cannot skip a tile.
local function navSegmentForbidden(from, to)
	local forbidden = navForbiddenCells()
	if next(forbidden) == nil then return nil end

	local bounds = mcontroller.boundBox()
	local length = world.magnitude(from, to)
	local steps = math.max(1, math.ceil(length / 0.5))

	for i = 0, steps do
		local t = i / steps
		local key, bucket = navBoxForbidden(forbidden, {
			from[1] + (to[1] - from[1]) * t, from[2] + (to[2] - from[2]) * t
		}, bounds)
		if key ~= nil then return key, bucket end
	end

	return nil
end

--  The first forbidden tile the body touches at any node of an A* result,
--  or nil.
local function navPathForbidden(edges)
	local forbidden = navForbiddenCells()
	if next(forbidden) == nil or type(edges) ~= "table" then return nil end

	local bounds = mcontroller.boundBox()

	for _, edge in ipairs(edges) do
		for _, node in ipairs({ edge.source, edge.target }) do
			if type(node) == "table" and type(node.position) == "table" then
				local key, bucket = navBoxForbidden(forbidden, node.position, bounds)
				if key ~= nil then return key, bucket end
			end
		end
	end

	return nil
end

local function navIndexRegister(profile)
	navFamilyRegister(NAV_INDEX, navEdgeFamilyEnumerate)
	local ok, registry = pcall(world.getProperty, NAV_INDEX)
	if not ok or type(registry) ~= "table" then registry = {} end
	registry.profiles = registry.profiles or {}

	if registry.profiles[profile] == true then return end

	registry.profiles[profile] = true
	pcall(world.setProperty, NAV_INDEX, registry)
end

local function navIndexProfileRead(profile)
	local ok, cells = pcall(world.getProperty, navIndexProperty(profile))
	if not ok or type(cells) ~= "table" then cells = {} end

	--  ONLY THIS GENERATION, 2026-09-08y: a key whose entry is from another
	--  generation is dropped here, so the candidate scan, the overlay and
	--  the flush's merge never see it.
	local gen = navGenNow()
	for cellKey, entry in pairs(cells) do
		if type(entry) ~= "table" or entry.g ~= gen then cells[cellKey] = nil end
	end

	local pending = self.petportsNavIndexPending
	if type(pending) == "table" and type(pending[profile]) == "table" then
		for cellKey, entry in pairs(pending[profile]) do
			cells[cellKey] = entry
		end
	end

	return cells
end

local function navIndexRead()
	local now = world.time()

	if self.petportsNavIndexMemoAt == now and self.petportsNavIndexMemo ~= nil then
		return self.petportsNavIndexMemo
	end

	local index = setmetatable({}, {
		__index = function(t, profile)
			if type(profile) ~= "string" then return nil end
			local cells = navIndexProfileRead(profile)
			rawset(t, profile, cells)
			return cells
		end
	})

	self.petportsNavIndexMemo = index
	self.petportsNavIndexMemoAt = now

	return index
end

local function navIndexQueue(profile, cellKey, entry)
	self.petportsNavIndexPending = self.petportsNavIndexPending or {}
	self.petportsNavIndexPending[profile] = self.petportsNavIndexPending[profile] or {}
	self.petportsNavIndexPending[profile][cellKey] = entry
	self.petportsNavIndexPendingCount = (self.petportsNavIndexPendingCount or 0) + 1

	--  KEPT AFTER THE FLUSH TOO, 2026-09-08n: see navBoundsQueue for the
	--  read-merge-write race between two units of one chassis. The edge
	--  index re-asserts this unit's own entries on every flush.
	self.petportsNavIndexMine = self.petportsNavIndexMine or {}
	self.petportsNavIndexMine[profile] = self.petportsNavIndexMine[profile] or {}
	self.petportsNavIndexMine[profile][cellKey] = entry
end

--  Write the queued entries, one property per profile that has any.
local function navIndexFlush()
	navGenerationCheck()
	if (self.petportsNavIndexPendingCount or 0) == 0 then return end

	local pending = self.petportsNavIndexPending or {}
	local index = navIndexRead()

	for profile in pairs(pending) do
		local cells = index[profile]

		--  RE-ASSERT EVERYTHING THIS UNIT EVER CONTRIBUTED, 2026-09-08n. An
		--  entry another unit's interleaved write dropped comes back here;
		--  a newer entry already in the index is left as it is.
		for cellKey, entry in pairs((self.petportsNavIndexMine or {})[profile] or {}) do
			if cells[cellKey] == nil then cells[cellKey] = entry end
		end

		navIndexRegister(profile)
		pcall(world.setProperty, navIndexProperty(profile), cells)
	end

	self.petportsNavIndexPending = nil
	self.petportsNavIndexPendingCount = 0
	self.petportsNavIndexMemo = nil
end

--  Write back every profile the caller touched in this index table (the
--  ones loaded through the metatable, i.e. rawly present).
local function navIndexWrite(index)
	for profile, cells in pairs(index) do
		if type(profile) == "string" and type(cells) == "table" then
			navIndexRegister(profile)
			pcall(world.setProperty, navIndexProperty(profile), cells)
		end
	end

	self.petportsNavIndexMemo = nil
end

local function navCellProperty(profile, cellKey)
	return NAV_EDGES .. profile .. ":" .. cellKey
end

--  ENUMERATE THE EDGE FAMILY: the profile registry, every profile's cell
--  index, every cell shard. Reads the store cold; only the wipe calls it.
navEdgeFamilyEnumerate = function()
	local names = {}

	local ok, registry = pcall(world.getProperty, NAV_INDEX)
	if not ok or type(registry) ~= "table" then registry = {} end

	for profile in pairs(registry) do
		local okCells, cells = pcall(world.getProperty, navIndexProperty(profile))
		if okCells and type(cells) == "table" then
			for cellKey in pairs(cells) do
				table.insert(names, navCellProperty(profile, cellKey))
			end
		end
		table.insert(names, navIndexProperty(profile))
	end

	table.insert(names, NAV_INDEX)
	return names
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
		--  A VERSION BUMP, NOT A DROP, 2026-09-07e: the old graph stays in
		--  service while the chunked rebuild runs; see navGraphBuildStep.
		self.petportsNavVersion = (self.petportsNavVersion or 0) + 1
	end

	local key = navCellProperty(profile, cellKey)
	local held = self.petportsNavCellCache[key]

	if held ~= nil then return held end

	local ok, edges = pcall(world.getProperty, key)
	if not ok or type(edges) ~= "table" then edges = {} end

	--  ONLY THIS GENERATION, 2026-09-08v. An entry without `g` is from
	--  before generations existed and is stale by definition.
	local gen = navGenNow()
	for to, entry in pairs(edges) do
		if type(entry) ~= "table" or entry.g ~= gen then edges[to] = nil end
	end

	self.petportsNavCellCache[key] = edges

	return edges
end

local function navCellWrite(profile, cellKey, edges)
	local key = navCellProperty(profile, cellKey)

	pcall(world.setProperty, key, edges)

	self.petportsNavCellCache = self.petportsNavCellCache or {}
	self.petportsNavCellCache[key] = edges

	--  THE MEMOISED GRAPH SURVIVES OUR OWN WRITES, 2026-09-06. PROFILED:
	--  graphFor n=176..428 per 5 s, 2.1-2.5 s of every 5 -- the graph was
	--  rebuilt after every flush (every 25 edges, ten to twenty times per 5
	--  s), each rebuild a pass over every shard and every edge at 200-300
	--  ms. But a flush writes edges that petports_navLearn ALREADY inserted
	--  into the memo, one at a time, as they were learned. Nothing in the
	--  graph changes when they reach the store. So the version still bumps
	--  (it gates the overlay and the level readout, which are cheap) and the
	--  graph's own version is moved with it instead of the graph being
	--  dropped. Another unit's writes still arrive through the cell cache
	--  TTL, and THAT expiry drops the graph, as before.
	self.petportsNavVersion = (self.petportsNavVersion or 0) + 1

	if self.petportsNavGraph ~= nil then
		self.petportsNavGraph.version = self.petportsNavVersion
	end
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
	navBoundsFlush()
	navIndexFlush()

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

	petports_profCount("edgesFlushed", written)

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

	self.petportsNavPending[profile][key] = { r = reachable, t = world.time(), g = navGenNow() }

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
			if graph.fine[fromKey] == nil then
				graph.fine[fromKey] = {}

				--  KEEP THE BLOCK INDEX CURRENT, 2026-09-08h, so a cell
				--  learned this tick is scanned this top-up.
				if graph.blocks ~= nil then
					local fx, fy = string.match(fromKey, "^(-?%d+),(-?%d+)$")
					if fx ~= nil then
						local key = math.floor(tonumber(fx) / NAV_BLOCK_CELLS) .. ","
							.. math.floor(tonumber(fy) / NAV_BLOCK_CELLS)
						if graph.blocks.map[key] == nil then
							graph.blocks.map[key] = {}
							graph.blocks.count = graph.blocks.count + 1
						end
						table.insert(graph.blocks.map[key], fromKey)
					end
				end
			end

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

--  Queued index entries ride the same timer as the edge flush, so a unit
--  that learns no edges (every pair known) still writes its sweeps out.
local function navIndexTick()
	if (self.petportsNavIndexPendingCount or 0) > 0
	   and self.petportsNavFlushAt ~= nil
	   and world.time() >= self.petportsNavFlushAt then
		navIndexFlush()
		self.petportsNavFlushAt = nil
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

	--  AND THE RECIPROCAL, FOR A FREE MOVER, 2026-09-09g (Lofty): a swept
	--  line is the same line both ways, and contradicting one direction
	--  only leaves a one-way trap -- the unit can enter a cell it can never
	--  leave through the graph. Walkers are directional (a drop is not a
	--  climb) and keep one-way contradictions.
	if petports_freeMover() then
		petports_navLearn(profile, toKey, fromKey, false)
	end
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
--  A free mover's edge may not leave coverage between two nodes that are
--  inside it (two port rectangles with a gap between them). Half-tile
--  samples of the body box against the coverage rectangles.
function navSegmentInCoverage(from, to)
	local bounds = mcontroller.boundBox()
	local samples = math.max(1, math.ceil(world.magnitude(from, to) / 0.5))

	for i = 0, samples do
		local t = i / samples
		local x = from[1] + (to[1] - from[1]) * t
		local y = from[2] + (to[2] - from[2]) * t

		if not navBoxInCoverage(x + bounds[1], y + bounds[2],
		                        x + bounds[3], y + bounds[4]) then
			return false
		end
	end

	return true
end

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

		--  A FREE MOVER DOES NOT NEED A SEARCH (Lofty, 2026-09-06). Nothing
		--  pulls it down, so the question between two anchors is only "does
		--  the body fit all the way along the straight line" -- and the
		--  fishing code already asks it: petports_bodyFitsAlong in
		--  petports_contract.lua, the sweep behind swimReachable. One call,
		--  verdict now. A blocked line is FALSE for the pair, and the graph
		--  carries the way round as its neighbours.
		--  A CLEAR LINE IS THE ANSWER; A BLOCKED ONE IS NOT (Lofty,
		--  2026-09-06). The sweep fails on a door the unit may open or fly
		--  through, so a blocked sweep falls through to the search below,
		--  which asks with the unit's own pathOptions.
		if freeMover then
			local edges = math.ceil(world.magnitude(from, to))

			--  NO LONGER THAN THE EXECUTOR CAN FLY, 2026-09-08r. MEASURED
			--  16:40 and again 17:50: a 38-tile diagonal between two water
			--  anchors (radius 12 cells is 34 on the diagonal, plus anchor
			--  offsets), body-clear and in-medium, so a true edge -- and a
			--  collect task, which gets no string-pull, has to A* it under
			--  NAV_MAX_DISTANCE 32 and cannot. The waypoint's "first hop is
			--  always eligible" hands it over anyway. An edge the executor
			--  cannot fly is not an edge; not learned, not logged as false
			--  either, since a shorter route through the same cells is what
			--  the graph will find instead.
			if edges > NAV_MAX_DISTANCE then
				petports_profCount("tooFar")
				self.petportsNavProbes[slot] = nil
				return nil
			end

			--  A DENIED BOUNDARY IS A WALL, 2026-09-07y. petports_bodyFitsAlong
			--  tests solids only; the poison maze was recorded TRUE through the
			--  pocket. Now the segment is walked against the forbidden set
			--  first, and a hit is a FALSE with the cell in the log.
			local wall, wallBucket = navSegmentForbidden(from, to)

			if wall ~= nil then
				sb.logInfo("NAV probe %s -> %s UNREACHABLE: the body would cross tile "
					.. "%s (%s), a liquid this chassis will not enter",
					fromKey, toKey, tostring(wall), tostring(wallBucket))
				petports_profCount("wallFalse")
				petports_navLearn(petports_navProfile(), fromKey, toKey, false)
				self.petportsNavProbes[slot] = nil
				return false
			end

			--  THE EXECUTOR'S TEST, 2026-09-08k. petports_bodyFitsAlong is
			--  solids only. MEASURED 16:40:08: a 38-tile diagonal edge between
			--  two in-water anchors, recorded TRUE, whose straight line
			--  leaves the water; the executor's flyPathClear refused it, the
			--  A* could not plan it under maxDistance, and every strike-out
			--  re-took it because the re-probe agreed with the store. An edge
			--  exists only if the line can be flown: body-swept AND
			--  medium-sampled, the same predicate the leg is flown with.
			local swept
			if petports_flyPathClear ~= nil then
				local okClear, verdict = pcall(petports_flyPathClear, from, to)
				swept = okClear and verdict == true
			else
				swept = petports_bodyFitsAlong(from, to) == true
			end

			if swept and navSegmentInCoverage(from, to) then
				if PETPORTS_NAV_VERBOSE then
					sb.logInfo("NAV probe %s -> %s REACHABLE by body sweep, %s edge(s)",
						fromKey, toKey, sb.printJson(edges))
				end

				petports_profCount("sweepTrue")

				petports_navLearn(petports_navProfile(), fromKey, toKey, true)
				self.petportsNavProbes[slot] = nil
				return true
			end

			--  A BLOCKED SWEEP ONLY FALLS THROUGH TO A SEARCH WHEN A DOOR IS
			--  ON THE LINE, 2026-09-06x. PROFILED: `false` 26-55 per 5 s at
			--  150-330 probe ticks, the largest probe cost on a flyer -- every
			--  wall-blocked pair ran the A* fallback to its cap. The fallback
			--  exists for doors (Lofty, 06e); a line blocked by terrain gets
			--  its detour from the graph's other edges, not from this pair.
			--  So: Dynamic on the straight line -> search; otherwise false now.
			--  NO FALL-THROUGH TO THE ENGINE A*, 2026-09-09f: it was reached
			--  when a door tile lay on the line, and it is poison-blind and
			--  (since 08u) run with gravity on. A free mover's edge is the
			--  swept line or nothing.
			local okDoor, door = false, false

			if not (okDoor and door == true) then
				if PETPORTS_NAV_VERBOSE then
					sb.logInfo("NAV probe %s -> %s UNREACHABLE by body sweep, %s edge(s)",
						fromKey, toKey, sb.printJson(edges))
				end

				--  NOT STORED, 2026-09-07i. A false edge is only worth keeping
				--  when it saves a search, and a free mover's re-check is a
				--  one-millisecond sweep. Stored, they were most of a flyer's
				--  shards: at radius 12 a cell sees ~600 pairs and nearly all
				--  are wall-blocked, so the store grew to hundreds of entries
				--  per cell over a long session -- world-file bloat, bigger
				--  shard reads, longer rebuilds, for nothing.
				petports_profCount("sweepFalse")
				self.petportsNavProbes[slot] = nil
				return false
			end
		end

		--  THE BINDING DIRECTLY, WITH THE PROBED SIDE'S PARAMETERS, 2026-09-07u.
		--  world.platformerPathStart takes the movement parameters as an
		--  argument (fact.pathing.pathstartparams); only the /scripts/pathing.lua
		--  wrapper reads baseParameters() off the entity, and this probe never
		--  needed the wrapper for anything but that call. So a swimming otter
		--  can probe a walker edge: the chassis parameters with the wrapper's
		--  own jumpModifier adjustment, and gravity forced ON because a walker
		--  probe is only ever run for a walker profile. Buoyancy stays the
		--  chassis's. dd.pathing.probeprofile, and the reason surrogate
		--  entities were not built.
		local params = mcontroller.baseParameters()
		local liveGravity = params.gravityEnabled

		if type(params.airJumpProfile) == "table"
		   and params.airJumpProfile.jumpSpeed ~= nil then
			local jumpSpeed = params.airJumpProfile.jumpSpeed
			params.airJumpProfile.jumpSpeed =
				jumpSpeed + (jumpSpeed * (status.stat("jumpModifier") or 0))
		end

		params.gravityEnabled = true

		local okStart, aStar = pcall(world.platformerPathStart, from, to, params,
			navPathOptions())

		if not okStart or aStar == nil then
			sb.logInfo("NAV probe %s -> %s SKIPPED: platformerPathStart refused (%s)",
				fromKey, toKey, tostring(aStar))
			self.petportsNavProbes[slot] = nil
			return nil
		end

		if PETPORTS_NAV_VERBOSE then sb.logInfo("NAV probe START %s -> %s: %s to %s (profile %s, rate %s, maxDistance %s, gravity true, live gravity %s)",
			fromKey, toKey, sb.printJson(from), sb.printJson(to),
			tostring(petports_navProfile()), sb.printJson(exploreRate or 300),
			sb.printJson(NAV_MAX_DISTANCE), tostring(liveGravity)) end

		self.petportsNavProbes[slot] = {
			aStar = aStar,
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

	local result = probe.aStar:explore(exploreRate or 300)

	--  THE PATH LENGTH, ON A TRUE. aStar:result() is the engine's edge list
	--  for the solved search; read through pcall so a binding surprise is a
	--  logged unknown rather than a dead probe.
	local edgeCount = nil

	if result == true then
		local ok, edges = pcall(function() return probe.aStar:result() end)

		if ok and type(edges) == "table" then
			edgeCount = #edges
		else
			sb.logInfo("NAV probe %s -> %s: aStar:result() unavailable (%s)",
				fromKey, toKey, tostring(edges))
		end

		--  THE ENGINE DOES NOT KNOW WHAT THIS CHASSIS WILL NOT ENTER, so a
		--  found path is checked node by node against the forbidden set
		--  before it counts. 2026-09-07y.
		if ok and type(edges) == "table" then
			local wall, wallBucket = navPathForbidden(edges)
			if wall ~= nil then
				sb.logInfo("NAV probe %s -> %s UNREACHABLE: the path puts the body on tile "
					.. "%s (%s), a liquid this chassis will not enter",
					fromKey, toKey, tostring(wall), tostring(wallBucket))
				petports_profCount("wallFalse")
				result = false
				edgeCount = nil
			end
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
				petports_profCount("tooLong")
				petports_profCount("tooLongTicks", probe.ticks or 0)
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

		if result == true then
			petports_profCount((probe.ticks or 0) <= 1 and "true1" or "trueN")
			petports_profCount("trueTicks", probe.ticks or 0)
		elseif edgeCount == nil then
			petports_profCount("false")
			petports_profCount("falseTicks", probe.ticks or 0)
		end

		petports_navLearn(petports_navProfile(), fromKey, toKey, result)

		self.petportsNavProbes[slot] = nil
		return result
	end

	return "searching"
end

--  ---------------------------------------------------------------- BRIDGES
--
--  A BRIDGE IS AN EDGE BETWEEN THE TWO SIDES OF A SWITCHABLE CHASSIS,
--  2026-09-09t (todo.pathing.amphibiousbridge, dd.pathing.boundarystore).
--  The otter surveys two stores -- `|f0|` walker cells and `|f1|` swimmer
--  cells -- and nothing joined them, so a land-mode route to a wet target
--  had no leg and the dive only ever engaged at dispatch for a fish. A
--  bridge is a land cell L and a swim cell S with a way across the
--  boundary between them, learned here and stored in a THIRD profile,
--  `|fb|`, through the ordinary edge store: index, flush, generation,
--  wipe, TTL and stats come for free. The graph loader for a switchable
--  chassis merges all three (build two; not this file yet).
--
--  THREE KINDS, TWO DIRECTIONS. Into the water:
--
--      dive   L's anchor is a BOARD above a HOLE -- a boundary column whose
--             `fit` says the body fits in the air above the wet tile -- with
--             a clear sight line board -> hole, and a body-clear drop from
--             the hole to S's anchor. The stored plan is exactly what
--             petports_diveLaunch takes: { launch = board, entry = hole }.
--      wade   L's anchor and S's anchor are within NAV_BRIDGE_WADE_REACH of
--             each other with the body fitting all the way between: a
--             shore the unit walks down until it is under. No launch; the
--             mode flips when the medium does.
--
--  Out of the water:
--
--      exit   from the FLOAT point -- the body afloat at the surface,
--             feet on the top wet row, which is where `exiting` holds it
--             -- a walker A* to L's anchor under `exiting`'s own physics:
--             gravity on, liquidBuoyancy 1.0 (arch.locomotion.exitdefer).
--             dd.pathing.probeprofile: platformerPathStart takes the
--             parameters as an argument, so a swimming otter can ask.
--
--  DISCOVERY RIDES ON THE BOUNDARY FLOOD. navBoundaryNote queues every
--  boundary cell whose liquid this chassis may enter; navBridgeTick takes
--  one per tick, gathers the anchored cells of both sides within
--  NAV_BRIDGE_RADIUS, and pairs them. Dives and wades are verdicts now
--  (a ray and a sweep); exits are an incremental A* in one slot, the same
--  shape as petports_navProbeStep.
--
--  BUILD ONE IS DISCOVERY ONLY. Nothing routes over these yet; the log
--  says where the bridges are and the overlay will draw them.

NAV_BRIDGE_RADIUS = 4            --  cells either side of a boundary cell
NAV_BRIDGE_DX = 6                --  tiles of horizontal offset a dive may solve
NAV_BRIDGE_PAIRS = 3             --  dives kept per boundary cell, best first
NAV_BRIDGE_WADE_REACH = 3.0      --  tiles between a land anchor and a swim anchor
NAV_BRIDGE_EXIT_RATE = 300       --  A* explores per tick for an exit probe
NAV_BRIDGE_EXIT_TICKS = 40       --  ticks before an exit probe is given up on
NAV_BRIDGE_RETRY = 30.0          --  a cell with nothing to pair is looked at again this soon
NAV_BRIDGE_RETRIES = 10          --  ...this many times, then it waits out NAV_BRIDGE_SEEN_TTL

--  THE BRIDGE PROFILE IS THE WALKER PROFILE WITH ITS SIDE RENAMED. Body,
--  liquids, doors and avoidLiquid all still discriminate; only the side is
--  new. Memoised per tick with the profile it derives from.
local function navBridgeProfile()
	local now = world.time()

	if self.petportsNavBridgeProfileAt ~= now or self.petportsNavBridgeProfile == nil then
		local land = navWithSide(false, petports_navProfile)
		self.petportsNavBridgeProfile = (string.gsub(land, "|f0|", "|fb|", 1))
		self.petportsNavBridgeProfileAt = now
	end

	return self.petportsNavBridgeProfile
end

function petports_navBridgeProfile()
	if not petports_gravitySwitchable() then return nil end
	return navBridgeProfile()
end

--  ONE LEARNED BRIDGE. The plain edge goes through petports_navLearn so the
--  contradiction log, the batch and the flush all apply; the kind and the
--  points ride on the pending entry, which is the table the flush writes.
local function navBridgeLearn(fromKey, toKey, reachable, extra)
	local profile = navBridgeProfile()

	navIndexRegister(profile)
	petports_navLearn(profile, fromKey, toKey, reachable)

	local pending = self.petportsNavPending and self.petportsNavPending[profile]
	local entry = pending and pending[navEdgeKey(fromKey, toKey)]

	if type(entry) == "table" and type(extra) == "table" then
		for k, v in pairs(extra) do entry[k] = v end
	end

	--  KEPT LOCALLY FOR THE OVERLAY, like the boundary records.
	self.petportsNavBridgesLocal = self.petportsNavBridgesLocal or {}
	self.petportsNavBridgesLocal[navEdgeKey(fromKey, toKey)] = {
		k = extra and extra.k, r = reachable,
		a = extra and (extra.board or extra.float),
		b = extra and extra.hole,
		fromKey = fromKey, toKey = toKey
	}

	--  BOTH CELLS INTO THE INDEX, so the merged loader can find the shard.
	--  Radius 1: a bridge is a single edge, not a sweep.
	local now = world.time()
	local cells = navIndexRead()[profile]
	for _, cellKey in ipairs({ fromKey, toKey }) do
		local held = type(cells) == "table" and type(cells[cellKey]) == "table"
			and tonumber(cells[cellKey].radius) or 0
		navIndexQueue(profile, cellKey, {
			at = now, radius = math.max(held, 1), g = navGenNow()
		})
	end
	self.petportsNavFlushAt = self.petportsNavFlushAt or (now + NAV_FLUSH_INTERVAL)
end

--  THE ANCHORED CELLS OF ONE SIDE AROUND A CELL, with their anchors. Anchor
--  resolution runs as that side (navWithSide), so a swimming otter resolves
--  walker anchors and a walking one resolves swim anchors. Only cells the
--  side's index already knows: an anchor nothing has swept is not in any
--  graph and a bridge to it would dangle.
local function navBridgeAnchorsAround(cx, cy, freeMover)
	local out = {}
	local profile = navWithSide(freeMover, petports_navProfile)
	local cells = navIndexRead()[profile]

	if type(cells) ~= "table" then return out end

	for dy = -NAV_BRIDGE_RADIUS, NAV_BRIDGE_RADIUS do
		for dx = -NAV_BRIDGE_RADIUS, NAV_BRIDGE_RADIUS do
			local key = petports_navCellKey(cx + dx, cy + dy)

			if cells[key] ~= nil then
				local anchor = navWithSide(freeMover, petports_navAnchor, cx + dx, cy + dy, freeMover)
				if anchor ~= nil then
					table.insert(out, { key = key, anchor = anchor })
				end
			end
		end
	end

	return out
end

--  A SIGHT LINE FOR A DIVE: the fish code's diveSighted, spelled here
--  because that one is file-local to the contract.
local function navBridgeSighted(from, to)
	local set = PETPORTS_DIVE_SOLID_SET or NAV_SOLID_SET
	local ok, hit = pcall(world.lineTileCollision, from, to, set)
	return ok and hit == false
end

local function navBridgeQueueTake()
	local queue = self.petportsNavBridgeQueue
	if type(queue) ~= "table" then return nil end

	for cellKey, item in pairs(queue) do
		queue[cellKey] = nil
		return cellKey, item
	end

	return nil
end

--  STEP THE ONE EXIT PROBE. Returns true while it is still searching.
local function navBridgeExitStep()
	local probe = self.petportsNavBridgeExit
	if probe == nil then return false end

	if probe.aStar == nil then
		local params = mcontroller.baseParameters()

		if type(params.airJumpProfile) == "table"
		   and params.airJumpProfile.jumpSpeed ~= nil then
			local jumpSpeed = params.airJumpProfile.jumpSpeed
			params.airJumpProfile.jumpSpeed =
				jumpSpeed + (jumpSpeed * (status.stat("jumpModifier") or 0))
		end

		--  `exiting`: gravity, but afloat. See petports_assertSwimMode.
		params.gravityEnabled = true
		params.liquidBuoyancy = 1.0

		local ok, aStar = pcall(world.platformerPathStart, probe.from, probe.to,
			params, navPathOptions())

		if not ok or aStar == nil then
			sb.logInfo("NAV bridge exit %s -> %s SKIPPED: platformerPathStart refused (%s)",
				probe.fromKey, probe.toKey, tostring(aStar))
			self.petportsNavBridgeExit = nil
			return false
		end

		probe.aStar = aStar
		probe.ticks = 0
	end

	probe.ticks = probe.ticks + 1

	local result = probe.aStar:explore(NAV_BRIDGE_EXIT_RATE)
	local edgeCount = nil

	if result == true then
		local ok, edges = pcall(function() return probe.aStar:result() end)
		if ok and type(edges) == "table" then
			edgeCount = #edges
			local wall = navPathForbidden(edges)
			if wall ~= nil then result = false end
		end
	end

	if result ~= true and result ~= false and probe.ticks >= NAV_BRIDGE_EXIT_TICKS then
		result = false
	end

	if result == true or result == false then
		sb.logInfo("NAV bridge exit %s -> %s %s after %s tick(s), %s edge(s): float %s -> land %s",
			probe.fromKey, probe.toKey, result and "REACHABLE" or "UNREACHABLE",
			sb.printJson(probe.ticks), tostring(edgeCount),
			sb.printJson(probe.from), sb.printJson(probe.to))

		navBridgeLearn(probe.fromKey, probe.toKey, result, { k = "exit", float = probe.from })
		petports_profCount(result and "bridgeExit" or "bridgeExitFalse")
		self.petportsNavBridgeExit = nil
		return false
	end

	return true
end

--  EXAMINE ONE BOUNDARY CELL: pair its holes and shore with the anchored
--  cells around it. Every pair found queues its exit probe behind it.
local function navBridgeExamine(cellKey, item)
	local cx, cy, record = item.cx, item.cy, item.record
	local baseX, baseY = navCellOrigin(cx, cy)
	local bounds = mcontroller.boundBox()
	local top = tonumber(record.top)

	if top == nil then return end

	local land = navBridgeAnchorsAround(cx, cy, false)
	local swim = navBridgeAnchorsAround(cx, cy, true)

	--  NOTHING TO PAIR IS USUALLY "NOT YET", 2026-09-09u. MEASURED 12:47:54:
	--  250 boundary cells examined within twenty seconds of spawn, every
	--  one with 0 land and 0 swim anchors -- the flood walks a shoreline in
	--  seconds and the survey indexes the cells beside it in minutes. Such
	--  a cell comes back in NAV_BRIDGE_RETRY rather than the full TTL, a
	--  bounded number of times.
	if #land == 0 or #swim == 0 then
		if PETPORTS_NAV_VERBOSE then
			sb.logInfo("NAV bridge %s: nothing to pair (%s land, %s swim anchor(s) within %s)",
				cellKey, sb.printJson(#land), sb.printJson(#swim), sb.printJson(NAV_BRIDGE_RADIUS))
		end
		item.retries = (item.retries or 0) + 1
		if item.retries <= NAV_BRIDGE_RETRIES then
			self.petportsNavBridgeRetry = self.petportsNavBridgeRetry or {}
			self.petportsNavBridgeRetry[cellKey] = { at = world.time() + NAV_BRIDGE_RETRY, item = item }
		end
		return
	end

	local exits = {}
	local learned = 0

	--  THE FLOAT POINT for an exit from column x: feet on the top wet row.
	local function floatAt(x)
		return { x, top + 1 - (bounds[2] or -0.8) }
	end

	local function queueExit(s, l, float)
		local key = s.key .. ">" .. l.key
		if exits[key] then return end
		exits[key] = true
		self.petportsNavBridgeExits = self.petportsNavBridgeExits or {}
		table.insert(self.petportsNavBridgeExits, {
			fromKey = s.key, toKey = l.key, from = float, to = l.anchor
		})
	end

	--  DIVES: one per hole column, scored the way the fish dive scores its
	--  pairs -- aligned first, then the drop, then the offset.
	local dives = {}

	for dx = 0, PETPORTS_NAV_CELL - 1 do
		if type(record.fit) == "table" and record.fit[tostring(dx)] == true then
			local hole = { baseX + dx + 0.5, top + 0.5 }

			--  THE NEAREST SWIM ANCHOR BELOW THE HOLE the body drops to clear.
			local bestS, bestSDist = nil, nil
			for _, s in ipairs(swim) do
				if s.anchor[2] < hole[2] then
					local d = world.magnitude(s.anchor, hole)
					if (bestSDist == nil or d < bestSDist)
					   and petports_bodyFitsAlong ~= nil
					   and petports_bodyFitsAlong(hole, s.anchor) then
						bestS, bestSDist = s, d
					end
				end
			end

			if bestS ~= nil then
				for _, l in ipairs(land) do
					local board = l.anchor
					local offset = math.abs(board[1] - hole[1])
					local drop = board[2] - hole[2]

					if drop > 0 and offset <= NAV_BRIDGE_DX and navBridgeSighted(board, hole) then
						local aligned = offset <= (PETPORTS_DIVE_DROP_ALIGN or 0.5)
						table.insert(dives, {
							l = l, s = bestS, hole = hole,
							score = (aligned and 0 or 1000) + offset + drop * 0.1,
							aligned = aligned
						})
					end
				end
			end
		end
	end

	table.sort(dives, function(a, b) return a.score < b.score end)

	local seenPair = {}
	for i = 1, math.min(#dives, NAV_BRIDGE_PAIRS) do
		local d = dives[i]
		local pairKey = d.l.key .. ">" .. d.s.key

		if not seenPair[pairKey] then
			seenPair[pairKey] = true
			if petports_navKnown(navBridgeProfile(), d.l.key, d.s.key) == true then
				queueExit(d.s, d.l, floatAt(d.hole[1]))
			else
				sb.logInfo("NAV bridge DIVE %s -> %s at %s: board %s, hole %s, %s",
					d.l.key, d.s.key, cellKey, sb.printJson(d.l.anchor), sb.printJson(d.hole),
					d.aligned and "aligned" or "offset")
				navBridgeLearn(d.l.key, d.s.key, true, { k = "dive", board = d.l.anchor, hole = d.hole })
				learned = learned + 1
				queueExit(d.s, d.l, floatAt(d.hole[1]))
			end
		end
	end

	--  WADES: a land anchor and a swim anchor close enough to walk between,
	--  the body fitting the whole way, the land side no lower than the
	--  water side. Nothing to launch.
	for _, l in ipairs(land) do
		for _, s in ipairs(swim) do
			local pairKey = l.key .. ">" .. s.key
			if not seenPair[pairKey]
			   and l.anchor[2] >= s.anchor[2]
			   and world.magnitude(l.anchor, s.anchor) <= NAV_BRIDGE_WADE_REACH
			   and petports_bodyFitsAlong ~= nil
			   and petports_bodyFitsAlong(l.anchor, s.anchor) then
				seenPair[pairKey] = true
				if petports_navKnown(navBridgeProfile(), l.key, s.key) == true then
					queueExit(s, l, floatAt(s.anchor[1]))
				else
					sb.logInfo("NAV bridge WADE %s -> %s at %s: shore %s, water %s",
						l.key, s.key, cellKey, sb.printJson(l.anchor), sb.printJson(s.anchor))
					navBridgeLearn(l.key, s.key, true, { k = "wade" })
					learned = learned + 1
					queueExit(s, l, floatAt(s.anchor[1]))
				end
			end
		end
	end

	if learned == 0 and PETPORTS_NAV_VERBOSE then
		sb.logInfo("NAV bridge %s: %s land and %s swim anchor(s), no pair crosses",
			cellKey, sb.printJson(#land), sb.printJson(#swim))
	end

	petports_profCount("bridgeCells")
	petports_profCount("bridgeLearned", learned)
end

--  ONE BOUNDARY CELL PER TICK, and the exit slot stepped every tick.
local function navBridgeTick()
	if not petports_gravitySwitchable() then return end

	if navBridgeExitStep() then return end

	local queued = self.petportsNavBridgeExits
	if type(queued) == "table" and #queued > 0 then
		local job = table.remove(queued, 1)
		local known = petports_navKnown(navBridgeProfile(), job.fromKey, job.toKey)
		if known == nil then
			self.petportsNavBridgeExit = job
		end
		return
	end

	local retry = self.petportsNavBridgeRetry
	if type(retry) == "table" then
		local now = world.time()
		for key, held in pairs(retry) do
			if now >= held.at then
				retry[key] = nil
				self.petportsNavBridgeQueue = self.petportsNavBridgeQueue or {}
				self.petportsNavBridgeQueue[key] = held.item
			end
		end
	end

	local cellKey, item = navBridgeQueueTake()
	if cellKey == nil then return end

	navBridgeExamine(cellKey, item)
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

	local divisor = math.max(1, tiles / navStride())

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
--  THE GRAPH IS BUILT IN CHUNKS ACROSS UPDATES, 2026-09-07e. MEASURED
--  14:43: a freshly socketed flyer on a store of thousands of cells hit
--  LuaInstructionLimitReached inside its first navTick -- the one-shot
--  rebuild (every shard read, every edge keyed, every coarse level derived)
--  is one Lua call and the engine caps a call's instructions. Before that
--  it showed as graphFor max=1029 ms every cache expiry. So the rebuild is
--  a state machine: NAV_BUILD_CHUNK cells per update, and until it is
--  finished callers get the PREVIOUS graph (or an empty one on first
--  build). Learned edges during a build go into both the old graph (via
--  petports_navLearn) and the new one (the pending batch is folded in at
--  the end), so nothing is lost across the swap.
--  40 -> 12, 2026-09-09o. MEASURED 14:25: one build step was the whole of
--  a 46 ms tick (graphFor inside nearestCell inside coarseLeg). Same work,
--  three times as many ticks, a third the height.
local NAV_BUILD_CHUNK = 12

local function navGraphBuildStep(profile)
	local build = self.petportsNavGraphBuild

	if build == nil or build.profile ~= profile then
		local cells = navIndexRead()[profile]
		local keys = {}
		for cellKey in pairs(type(cells) == "table" and cells or {}) do
			table.insert(keys, cellKey)
		end

		build = {
			profile = profile,
			version = self.petportsNavVersion or 0,
			keys = keys,
			at = 1,
			edges = {}
		}
		self.petportsNavGraphBuild = build
		petports_profCount("graphBuildStart")
	end

	local stop = math.min(#build.keys, build.at + NAV_BUILD_CHUNK - 1)

	for k = build.at, stop do
		local cellKey = build.keys[k]
		for to, entry in pairs(navCellRead(profile, cellKey)) do
			build.edges[cellKey .. ">" .. to] = entry
		end
	end

	build.at = stop + 1

	if build.at <= #build.keys then return nil end

	--  PHASE TWO, ALSO IN CHUNKS, 2026-09-07g. The engine profile put
	--  navGraphBuildStep at 728 with 157 self: the derivation at the end
	--  (every edge keyed into fine, then four coarse levels per edge) was
	--  still one call over the whole store. So reading finishes, the edge
	--  keys become a list, and each update derives NAV_BUILD_CHUNK x 8
	--  edges until the list is done; then the swap.
	if build.edgeKeys == nil then
		for key, entry in pairs(navPendingFor(profile) or {}) do
			build.edges[key] = entry
		end

		build.edgeKeys = {}
		for key in pairs(build.edges) do table.insert(build.edgeKeys, key) end
		build.edgeAt = 1
		build.fine = {}
		build.coarse = {}
		for _, tiles in ipairs(NAV_LEVELS) do build.coarse[tiles] = {} end
	end

	local edgeStop = math.min(#build.edgeKeys, build.edgeAt + NAV_BUILD_CHUNK * 8 - 1)

	for k = build.edgeAt, edgeStop do
		local key = build.edgeKeys[k]
		local entry = build.edges[key]

		if type(entry) == "table" and entry.r == true then
			local from, to = string.match(key, "^(.-)>(.*)$")

			if from ~= nil and to ~= nil then
				build.fine[from] = build.fine[from] or {}
				table.insert(build.fine[from], to)

				for _, tiles in ipairs(NAV_LEVELS) do
					local a = navBlockKey(from, tiles)
					local b = navBlockKey(to, tiles)

					if a ~= nil and b ~= nil and a ~= b then
						local bucket = build.coarse[tiles]
						bucket[a] = bucket[a] or {}
						bucket[a][b] = true
					end
				end
			end
		end
	end

	build.edgeAt = edgeStop + 1

	if build.edgeAt <= #build.edgeKeys then return nil end

	self.petportsNavGraph = {
		profile = profile,
		version = self.petportsNavVersion or 0,
		fine = build.fine,
		coarse = build.coarse
	}
	self.petportsNavGraphBuild = nil
	petports_profCount("graphBuildDone")

	return self.petportsNavGraph
end


--  ------------------------------------------------------ THE MERGED GRAPH
--
--  ONE GRAPH FOR A SWITCHABLE CHASSIS, 2026-09-09v: the walker cells, the
--  swimmer cells and the bridges between them, so a route from a dry cell
--  to a wet one is the ordinary BFS. Nodes keep their plain cell keys --
--  both strides are 1, so a key names the same 2x2 window on either side
--  and the thirty places that parse a key go on working. The side rides
--  beside the adjacency: `side[key]` is 0 (walker), 1 (swimmer) or 2 (in
--  both indexes), and `bridge[from>to]` is the stored bridge entry with
--  its kind and points.
--
--  A CELL ON BOTH SIDES IS A WADE IN ITSELF. Its walker anchor is a
--  standing point and its swim anchor the window centre, at most two
--  tiles apart, so the body is at the waterline there; the merged
--  adjacency is the union and a route may change side on it without a
--  bridge. Counted at build time so the log says how often it happens.
--
--  ITS OWN MEMO. The side graph memo is one slot and the survey already
--  alternates sides through it; a third profile in the same slot would
--  rebuild on every routing call. Rebuilt in chunks when the store version
--  moves, no more than once per NAV_MERGED_MIN_AGE, and served stale
--  meanwhile like the side graph is.
local NAV_MERGED_MIN_AGE = 5.0

local function navMergedBuildStep()
	local build = self.petportsNavMergedBuild
	local bridgeProfile = navBridgeProfile()

	if build == nil then
		local land = navWithSide(false, petports_navProfile)
		local swim = navWithSide(true, petports_navProfile)
		local index = navIndexRead()
		local keys = {}

		for _, source in ipairs({ { land, 0 }, { swim, 1 }, { bridgeProfile, 3 } }) do
			local cells = index[source[1]]
			for cellKey in pairs(type(cells) == "table" and cells or {}) do
				table.insert(keys, { cellKey, source[1], source[2] })
			end
		end

		build = {
			version = self.petportsNavVersion or 0,
			keys = keys, at = 1,
			edges = {}, side = {}, bridge = {},
			land = land, swim = swim
		}
		self.petportsNavMergedBuild = build
		petports_profCount("mergedBuildStart")
	end

	local stop = math.min(#build.keys, build.at + NAV_BUILD_CHUNK - 1)

	for k = build.at, stop do
		local cellKey, profile, sideTag = build.keys[k][1], build.keys[k][2], build.keys[k][3]

		if sideTag < 2 then
			local held = build.side[cellKey]
			if held == nil then
				build.side[cellKey] = sideTag
			elseif held ~= sideTag then
				build.side[cellKey] = 2
			end
		end

		for to, entry in pairs(navCellRead(profile, cellKey)) do
			local key = cellKey .. ">" .. to
			if sideTag == 3 then
				if type(entry) == "table" and entry.r == true then
					build.bridge[key] = entry
					build.edges[key] = entry
				end
			elseif build.edges[key] == nil then
				build.edges[key] = entry
			end
		end
	end

	build.at = stop + 1
	if build.at <= #build.keys then return nil end

	if build.edgeKeys == nil then
		for _, profile in ipairs({ build.land, build.swim }) do
			for key, entry in pairs(navPendingFor(profile) or {}) do
				if build.edges[key] == nil then build.edges[key] = entry end
			end
		end
		for key, entry in pairs(navPendingFor(bridgeProfile) or {}) do
			if type(entry) == "table" and entry.r == true then
				build.bridge[key] = entry
				build.edges[key] = entry
			end
		end

		build.edgeKeys = {}
		for key in pairs(build.edges) do table.insert(build.edgeKeys, key) end
		build.edgeAt = 1
		build.fine = {}
		build.coarse = {}
		for _, tiles in ipairs(NAV_LEVELS) do build.coarse[tiles] = {} end
	end

	local edgeStop = math.min(#build.edgeKeys, build.edgeAt + NAV_BUILD_CHUNK * 8 - 1)

	for k = build.edgeAt, edgeStop do
		local key = build.edgeKeys[k]
		local entry = build.edges[key]

		if type(entry) == "table" and entry.r == true then
			local from, to = string.match(key, "^(.-)>(.*)$")

			if from ~= nil and to ~= nil then
				build.fine[from] = build.fine[from] or {}
				table.insert(build.fine[from], to)

				for _, tiles in ipairs(NAV_LEVELS) do
					local a = navBlockKey(from, tiles)
					local b = navBlockKey(to, tiles)
					if a ~= nil and b ~= nil and a ~= b then
						local bucket = build.coarse[tiles]
						bucket[a] = bucket[a] or {}
						bucket[a][b] = true
					end
				end
			end
		end
	end

	build.edgeAt = edgeStop + 1
	if build.edgeAt <= #build.edgeKeys then return nil end

	local both, bridges = 0, 0
	for _, sideTag in pairs(build.side) do if sideTag == 2 then both = both + 1 end end
	for _ in pairs(build.bridge) do bridges = bridges + 1 end

	self.petportsNavMerged = {
		profile = bridgeProfile,
		version = build.version,
		builtAt = world.time(),
		fine = build.fine, coarse = build.coarse,
		side = build.side, bridge = build.bridge
	}
	self.petportsNavMergedBuild = nil
	petports_profCount("mergedBuildDone")

	if self.petportsNavMergedNoted ~= bridges then
		self.petportsNavMergedNoted = bridges
		sb.logInfo("NAV merged graph: %s cell(s), %s on both sides, %s bridge(s)",
			sb.printJson(#build.keys), sb.printJson(both), sb.printJson(bridges))
	end

	return self.petportsNavMerged
end

local function navMergedGraphFor()
	local cached = self.petportsNavMerged
	local version = self.petportsNavVersion or 0
	local now = world.time()

	if cached ~= nil and cached.version == version then return cached end

	if self.petportsNavMergedBuild == nil and cached ~= nil
	   and (now - (cached.builtAt or 0)) < NAV_MERGED_MIN_AGE then
		return cached
	end

	if self.petportsNavMergedBuildAt ~= now then
		self.petportsNavMergedBuildAt = now
		local done = navMergedBuildStep()
		if done ~= nil then return done end
	end

	if cached ~= nil then return cached end

	return { profile = navBridgeProfile(), version = -1, fine = {}, coarse = {},
		side = {}, bridge = {}, building = true }
end

local function navGraphForInner(profile)
	if petports_gravitySwitchable() and profile == navBridgeProfile() then
		return navMergedGraphFor()
	end

	local cached = self.petportsNavGraph

	if cached ~= nil and cached.profile == profile
	   and cached.version == (self.petportsNavVersion or 0) then
		return cached
	end

	--  Stale or absent: advance the build ONE chunk PER UPDATE (many callers
	--  ask per tick; the first one pays), and answer with what we have
	--  meanwhile. An absent graph answers empty, which every caller already
	--  treats as "nothing known yet".
	local now = world.time()

	if self.petportsNavGraphBuildAt ~= now then
		self.petportsNavGraphBuildAt = now
		local done = navGraphBuildStep(profile)
		if done ~= nil then return done end
	end

	if cached ~= nil and cached.profile == profile then return cached end

	return { profile = profile, version = -1, fine = {}, coarse = {}, building = true }
end

local function navGraphFor(profile)
	petports_profBegin("graphFor")
	local g = navGraphForInner(profile)
	petports_profEnd("graphFor")
	return g
end

--  BFS over one coarse level. Set-valued adjacency, so pairs() not ipairs().
local function navCoarseReaches(graph, tiles, fromKey, toKey, budget)
	local a = navBlockKey(fromKey, tiles)
	local b = navBlockKey(toKey, tiles)

	if a == nil or b == nil then return nil end
	if a == b then return true end

	--  NO LEVEL, NO ANSWER, 2026-09-07t. navGraphForInner hands back a
	--  placeholder `{ fine = {}, coarse = {} }` while a rebuild is in flight
	--  and no older graph exists -- a fresh unit's first minute -- and that
	--  placeholder has no level tables. MEASURED 2026-09-06 05:32..05:39:
	--  twelve sweeps died here on "attempt to index a nil value (local
	--  'adjacency')", every one on a unit whose graph was still building.
	--  nil is "unknown", which is what every caller already treats a spent
	--  budget as; the coarse ladder is a rejection filter only.
	local adjacency = graph.coarse[tiles]
	if adjacency == nil then return nil end

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
--  WHY IS THERE NO ROUTE, in one line. 2026-09-08p: `coarse nav has no
--  leg` covered three different situations -- an unknown from cell, an
--  unknown to cell, and two known cells with no path between them -- and
--  they need different fixes. Reports which, with the graph's size and, for
--  two known cells, how many cells the BFS could reach from `from`.
function petports_navWhyNoRoute(profile, fromKey, toKey)
	local graph = navGraphFor(profile)
	local fine = graph.fine or {}
	local known = 0
	for _ in pairs(fine) do known = known + 1 end

	local fromKnown = fine[fromKey] ~= nil
	local toKnown = fine[toKey] ~= nil
	if not toKnown then
		for _, tos in pairs(fine) do
			for _, to in ipairs(tos) do
				if to == toKey then toKnown = true break end
			end
			if toKnown then break end
		end
	end

	if graph.building then
		local build = self.petportsNavGraphBuild
		if build ~= nil then
			return string.format("graph still building: %s of %s cell shard(s) read, %s of %s edge(s) placed",
				sb.printJson(math.max(0, (build.at or 1) - 1)), sb.printJson(#(build.keys or {})),
				sb.printJson(math.max(0, (build.edgeAt or 1) - 1)),
				sb.printJson(build.edgeKeys and #build.edgeKeys or 0))
		end
		return "graph still building: no build in flight this tick"
	end
	if not fromKnown and not toKnown then
		return string.format("neither %s nor %s is in the graph (%s cell(s))",
			fromKey, toKey, sb.printJson(known))
	end
	if not fromKnown then
		return string.format("from cell %s is not in the graph (%s cell(s))", fromKey, sb.printJson(known))
	end
	if not toKnown then
		return string.format("to cell %s is not in the graph (%s cell(s))", toKey, sb.printJson(known))
	end

	local seen = { [fromKey] = true }
	local frontier = { fromKey }
	local reached = 0
	while #frontier > 0 and reached < PETPORTS_NAV_SEARCH_BUDGET do
		local node = table.remove(frontier)
		reached = reached + 1
		for _, to in ipairs(fine[node] or {}) do
			if not seen[to] then
				seen[to] = true
				table.insert(frontier, to)
			end
		end
	end

	--  WHAT THE LAST ROUTE SAID ABOUT THIS CELL, 2026-09-09d. MEASURED
	--  19:16:08: a 21-hop route through 2514,1126, then "no path" from
	--  2514,1126 a quarter-second later with nothing contradicted between.
	--  Either the graph consulted differs or the cell is not where the leg
	--  said. So: the from cell's out-degree, its index in the last route,
	--  and whether the edge to the route's next cell is present now.
	local outDegree = #(fine[fromKey] or {})
	local last = self.petportsNavLastRoute
	local place = "not in the last route"
	if last ~= nil and type(last.path) == "table" then
		for i, key in ipairs(last.path) do
			if key == fromKey then
				local nextKey = last.path[i + 1]
				local present = false
				for _, to in ipairs(fine[fromKey] or {}) do
					if to == nextKey then present = true end
				end
				place = string.format("at %s of %s in the last route (%s -> %s), next %s, edge to it %s",
					sb.printJson(i), sb.printJson(#last.path), tostring(last.from),
					tostring(last.to), tostring(nextKey), present and "PRESENT" or "ABSENT")
			end
		end
	end

	return string.format("both known, no path: %s cell(s) reachable from %s of %s in the graph "
		.. "(version %s); from has %s outgoing edge(s); %s",
		sb.printJson(reached), fromKey, sb.printJson(known), tostring(graph.version),
		sb.printJson(outDegree), place)
end

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

	--  THE LAST ROUTE ASKED FOR, FOR THE OVERLAY, 2026-09-08s. Path or nil,
	--  and the why when nil; drawn as a polyline unit cell to target cell.
	self.petportsNavLastRoute = {
		from = fromKey, to = toKey, path = path, at = world.time(),
		why = (path == nil or #path < 2) and petports_navWhyNoRoute(profile, fromKey, toKey) or nil,
		building = navGraphFor(profile).building == true
	}

	if path == nil or #path < 2 then return nil end

	minAdvance = minAdvance or 0

	--  SIDES, 2026-09-09v. In a merged graph every node has a side and an
	--  anchor is resolved AS that side; a cell on both sides resolves as
	--  the caller's. A leg never crosses a side change, and a route whose
	--  next hop crosses one is a BRIDGE leg: the stored plan travels with
	--  it in petportsNavLastRoute.bridge.
	local graph = navGraphFor(profile)
	local sides = graph.side
	local function sideOf(key)
		local tag = sides ~= nil and sides[key] or nil
		if tag == nil or tag == 2 then return freeMover and 1 or 0 end
		return tag
	end
	local function anchorOf(key, asSide)
		local kx = tonumber(string.match(key, "^(-?%d+),"))
		local ky = tonumber(string.match(key, ",(-?%d+)$"))
		if kx == nil then return nil end
		if sides == nil then return petports_navAnchor(kx, ky, freeMover) end
		local swim = (asSide or sideOf(key)) == 1
		return navWithSide(swim, petports_navAnchor, kx, ky, swim)
	end
	local startSide = sideOf(path[1])
	self.petportsNavLastRoute.bridge = nil

	local origin = anchorOf(path[1], startSide)

	if origin == nil then return nil end

	if sides ~= nil and sideOf(path[2]) ~= startSide then
		local entry = graph.bridge ~= nil and graph.bridge[path[1] .. ">" .. path[2]] or nil
		local target = anchorOf(path[2])
		if target == nil then return nil end
		self.petportsNavLastRoute.bridge = {
			k = entry and entry.k or "wade",
			board = entry and entry.board, hole = entry and entry.hole,
			float = entry and entry.float,
			from = path[1], to = path[2], toSide = sideOf(path[2])
		}
		self.petportsNavLastRoute.leg = path[2]
		self.petportsNavLastRoute.waypoint = target
		self.petportsNavLastRoute.nextAnchor = #path >= 3 and anchorOf(path[3]) or nil
		return target, #path - 2, path[2], 1, path[1], path[1]
	end

	--  FROM THE BODY, NOT THE CELL, 2026-09-09c (Lofty): the string-pull
	--  line was judged from the route's first anchor, and the unit steers
	--  from wherever it is -- tiles off that anchor and, at a corner of the
	--  maze, on the other side of the poison from it. A line that is clear
	--  anchor-to-cell and not body-to-cell was being flown into the wall.
	--  Free movers only; a walker's leg is a path, not a line.
	local cellAnchor = origin
	if freeMover then origin = mcontroller.position() end

	--  STEP ONTO THE ROUTE FIRST, 2026-09-09e. "The first hop is always
	--  eligible" keeps a route from coming back empty, and it also hands a
	--  free mover a first hop it cannot see from where its body is -- offset
	--  in a two-wide corridor, just round a corner -- which releases at
	--  once, re-picks the same hop, and reaches the engine A*. If the first
	--  hop is not clear from the body but the body's own cell anchor is, the
	--  leg is that anchor: a short line inside the unit's own cell, after
	--  which the first hop is judged from the route, not beside it.
	if freeMover and petports_flyPathClear ~= nil and #path >= 2 then
		local hopX = tonumber(string.match(path[2], "^(-?%d+),"))
		local hopY = tonumber(string.match(path[2], ",(-?%d+)$"))
		local hop = anchorOf(path[2])

		if hop ~= nil then
			local okHop, hopClear = pcall(petports_flyPathClear, origin, hop)
			if not (okHop and hopClear == true)
			   and world.magnitude(origin, cellAnchor) > (minAdvance or 0) then
				local okStep, stepClear = pcall(petports_flyPathClear, origin, cellAnchor)
				if okStep and stepClear == true then
					self.petportsNavLastRoute.leg = path[1]
					self.petportsNavLastRoute.waypoint = cellAnchor
					return cellAnchor, #path - 1, path[1], 0, path[1], path[1]
				end
			end
		end
	end

	local chosen, chosenAt = nil, 2

	--  THE NEAREST IN-REACH CELL PAST minAdvance, 2026-09-09i, kept as the
	--  free mover's fallback. MEASURED 20:40:45: in a corridor nothing past
	--  the next corner is visible from the body, the 2-tile cell was skipped
	--  by minAdvance, and the first cell BEYOND reach was returned by the
	--  never-return-empty rule -- a 33-tile leg the engine A* cannot plan
	--  under maxDistance 32 and no line to pull. A free mover is never
	--  handed a leg beyond reach; the fallback is this cell, which is
	--  flyable by construction: it is one graph edge from where the body is.
	local nearest, nearestAt = nil, nil

	for i = 2, #path do
		--  THE LEG ENDS BEFORE THE SIDE CHANGES. The hop across is its own
		--  leg, planned from the cell before it on the next call.
		if sides ~= nil and sideOf(path[i]) ~= startSide then break end

		local anchor = anchorOf(path[i], startSide)

		if anchor ~= nil then
			local dx = anchor[1] - origin[1]
			local dy = anchor[2] - origin[2]
			local distance = math.sqrt(dx * dx + dy * dy)

			if distance < minAdvance and i < #path then
				--  TOO CLOSE TO BE A LEG. Keep walking the path.
			elseif freeMover then
				--  A FREE MOVER'S LEG IS THE FARTHEST PATH CELL IT CAN SEE
				--  (Lofty, 2026-09-05): string-pull, the same way a moving
				--  target is chased. Within reach, and with nothing solid on
				--  the straight line from the origin. A blocked cell is
				--  passed over, not a stop -- a later one round the corner
				--  may be visible again. The first hop is always eligible so
				--  a route that exists is never returned as nil.
				if distance <= (reach or 24) and nearest == nil then
					nearest, nearestAt = anchor, i
				end

				if distance <= (reach or 24) then
					--  THE EXECUTOR'S TEST, NOT A RAY, 2026-09-08j. MEASURED
					--  16:29:44: from 2518,1141 the ray saw straight through
					--  the poison to 2493,1138, the leg was handed over, the
					--  free mover's own flyPathClear refused the line, the A*
					--  fallback planned through the poison and was refused,
					--  and the unit stood for ten seconds on a route that
					--  went round the pocket correctly, six hops long. Same
					--  predicate on both sides (arch.pathing.oneanchor):
					--  body-swept, medium-sampled, so a line through denied
					--  liquid, or out of the water, is no string-pull
					--  candidate here either.
					local clear
					if petports_flyPathClear ~= nil then
						local okClear, verdict = pcall(petports_flyPathClear, origin, anchor)
						clear = okClear and verdict == true
					else
						local okLos, blocked = pcall(world.lineTileCollision,
							origin, anchor, { "Null", "Block", "Dynamic", "Slippery" })
						clear = okLos and blocked == false
					end

					if i == 2 or clear then
						chosen, chosenAt = anchor, i
					end
				elseif chosen ~= nil then
					break
				elseif nearest ~= nil then
					chosen, chosenAt = nearest, nearestAt
					break
				else
					chosen, chosenAt = anchor, i
					break
				end
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

	if chosen == nil and nearest ~= nil then chosen, chosenAt = nearest, nearestAt end
	if chosen == nil then return nil end

	self.petportsNavLastRoute.leg = path[chosenAt]
	self.petportsNavLastRoute.waypoint = chosen

	--  THE TURN AT THE END OF THE LEG, 2026-09-09j (Lofty): the angle in
	--  degrees between the leg's direction and the route's direction out of
	--  the waypoint, nil at the route's end. The executor arrives tightly and
	--  brakes only where the turn is sharp, and flies through otherwise.
	--  09k: the turn is no longer computed here from the PLANNED incoming
	--  direction -- the body arrives from wherever it actually is, and a
	--  planned 45 read as 135 in flight (Lofty, 21:05). The leg carries the
	--  anchor AFTER its end and the executor measures the turn against its
	--  own velocity every tick.
	self.petportsNavLastRoute.turn = nil
	self.petportsNavLastRoute.nextAnchor = nil
	if chosenAt < #path then
		self.petportsNavLastRoute.nextAnchor = anchorOf(path[chosenAt + 1])
	end

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
--  FOR A FREE MOVER, THE NEAREST CELL IT CAN SEE. Its nodes trace surfaces
--  (2026-09-06), so a position in the middle of a room has no node within
--  arm's reach; the graph cell for it is the nearest wall node with a clear
--  body-wide line to it, out to the probe distance. The last leg ends on
--  that wall node and the direct search covers the sighted remainder.
--  BOUNDED PER CALL AND RESUMABLE, 2026-09-07q. MEASURED 02:12 on 07p, the
--  first log with this call sectioned: nearestCell max 67 ms inside a
--  coarseLeg of 71, in the tick of a 0.39 s wallclock stall. For a free
--  mover the radius is NAV_MAX_DISTANCE, so this was a 65x65 cell scan and
--  then one body sweep (~1 ms, synchronous) per sighted candidate,
--  nearest-first, with NO cap: behind a wall or in a tunnel that is dozens
--  of sweeps in one call. Now at most NAV_NEAREST_SWEEPS sweeps per call;
--  past that the sorted candidate list and the cursor are kept on self,
--  keyed by the asking cell, mover class and radius, and the FOURTH return
--  is true for "more" -- the caller (tryCoarseLeg) returns false without
--  logging and asks again next tick, where this resumes. A new query, or a
--  graph swap, throws the cursor away. Walkers never sweep and are unchanged.
local NAV_NEAREST_SWEEPS = 6

--  THE GRAPH'S CELLS BY BLOCK, built once per graph version and kept
--  current by petports_navLearn. One string.match per cell, once.
local function navGraphBlocks(graph)
	if graph.blocks ~= nil then return graph.blocks end

	local blocks = { map = {}, count = 0 }

	for from in pairs(graph.fine) do
		local fx, fy = string.match(from, "^(-?%d+),(-?%d+)$")
		if fx ~= nil then
			local key = math.floor(tonumber(fx) / NAV_BLOCK_CELLS) .. ","
				.. math.floor(tonumber(fy) / NAV_BLOCK_CELLS)
			if blocks.map[key] == nil then
				blocks.map[key] = {}
				blocks.count = blocks.count + 1
			end
			table.insert(blocks.map[key], from)
		end
	end

	graph.blocks = blocks
	return blocks
end


--  The colour for a swept radius: red at PETPORTS_NAV_RADIUS_START, green
--  at PETPORTS_NAV_RADIUS, linearly between. An RGBA array, which the debug
--  bindings take as a colour.
local function navRadiusColour(radius)
	local lo, hi = PETPORTS_NAV_RADIUS_START, navFullRadius()
	local t = (radius - lo) / math.max(1, hi - lo)
	if t < 0 then t = 0 elseif t > 1 then t = 1 end
	return { math.floor(255 * (1 - t) + 0.5), math.floor(255 * t + 0.5), 0, 255 }
end

local function navNearestFrom(candidates, startAt, position, freeMover, radius, resumeKey, fine)
	local swept = 0

	for i = startAt, #candidates do
		local c = candidates[i]
		local anchor = petports_navAnchor(c.cx, c.cy, freeMover)

		if anchor ~= nil then
			local distance = world.magnitude(anchor, position)

			if distance <= radius then
				if not freeMover then
					self.petportsNavNearestResume = nil
					return c.key, anchor, distance
				end

				if swept >= NAV_NEAREST_SWEEPS then
					self.petportsNavNearestResume = {
						key = resumeKey, fine = fine, candidates = candidates, at = i
					}
					petports_profCount("nearestCut")
					return nil, nil, nil, true
				end

				swept = swept + 1

				if petports_bodyFitsAlong(position, anchor) == true then
					self.petportsNavNearestResume = nil
					return c.key, anchor, distance
				end
			end
		end
	end

	self.petportsNavNearestResume = nil
	return nil
end

local function navNearestCellIn(graph, position, freeMover, radius, sideTag)
	radius = radius or 2.5

	if freeMover then radius = math.max(radius, NAV_MAX_DISTANCE) end

	local fine = graph.fine
	local sides = graph.side
	local px, py = petports_navCell(position)

	local reach = math.ceil(radius / navStride())

	local resumeKey = petports_navCellKey(px, py) .. "|" .. tostring(freeMover)
		.. "|" .. tostring(radius) .. "|" .. tostring(sideTag)
	local resume = self.petportsNavNearestResume

	if resume ~= nil and resume.key == resumeKey and resume.fine == fine then
		return navNearestFrom(resume.candidates, resume.at, position, freeMover,
			radius, resumeKey, fine)
	end

	--  NEAREST-FIRST, STOP AT THE FIRST THAT QUALIFIES. 2026-09-06: the
	--  free-mover version swept the body to EVERY graph cell within 32
	--  tiles before choosing -- ~150 cells x up to 64 rect queries, on
	--  every chained leg, on the world thread. That was the stutter. Cells
	--  are gathered by cell-centre distance (no world calls), sorted, and
	--  the anchor and the sight sweep are computed in that order; the first
	--  visible one is the answer, which is usually the first or second.
	--  BLOCKS, NOT A SQUARE OF CELLS, 2026-09-09n. MEASURED 14:17: 42-83 ms
	--  per call, eight calls in five seconds. A free mover's radius is raised
	--  to NAV_MAX_DISTANCE, so this built its candidate list by testing every
	--  key in a 65x65-cell square -- 4,225 string keys per call, on every
	--  drift re-resolve -- before sweeping anything. The block index (08h)
	--  holds only the graph's cells; the blocks in range are walked instead.
	local candidates = {}
	local blocks = navGraphBlocks(graph)
	local bx0 = math.floor((px - reach) / NAV_BLOCK_CELLS)
	local bx1 = math.floor((px + reach) / NAV_BLOCK_CELLS)
	local by0 = math.floor((py - reach) / NAV_BLOCK_CELLS)
	local by1 = math.floor((py + reach) / NAV_BLOCK_CELLS)

	for by = by0, by1 do
		for bx = bx0, bx1 do
			for _, key in ipairs(blocks.map[bx .. "," .. by] or {}) do
				local cx = tonumber(string.match(key, "^(-?%d+),"))
				local cy = tonumber(string.match(key, ",(-?%d+)$"))
				--  THE ASKED-FOR SIDE ONLY, in a merged graph: a walker
				--  starts from a walker cell, a swimmer from a swimmer cell,
				--  and a cell on both sides serves either.
				local sideOk = sideTag == nil or sides == nil
					or sides[key] == sideTag or sides[key] == 2
				if sideOk and cx ~= nil and math.abs(cx - px) <= reach and math.abs(cy - py) <= reach then
					local ox, oy = navCellOrigin(cx, cy)
					local dx = ox + PETPORTS_NAV_CELL * 0.5 - position[1]
					local dy = oy + PETPORTS_NAV_CELL * 0.5 - position[2]
					table.insert(candidates, {
						cx = cx, cy = cy, key = key, rough = dx * dx + dy * dy
					})
				end
			end
		end
	end

	table.sort(candidates, function(a, b)
		if a.rough ~= b.rough then return a.rough < b.rough end
		return a.key < b.key
	end)

	return navNearestFrom(candidates, 1, position, freeMover, radius, resumeKey, fine)
end

function petports_navNearestCell(position, freeMover, radius)
	return navNearestCellIn(navGraphFor(petports_navProfile()), position, freeMover, radius, nil)
end

--  THE NEAREST CELL OF ONE SIDE OF THE MERGED GRAPH, 2026-09-09v, with the
--  anchors resolved as that side. This is how a walker finds the swim cell
--  nearest a wet target, and a swimmer the walker cell nearest a dry one.
function petports_navNearestCellSide(position, freeMover, radius)
	if not petports_gravitySwitchable() then
		return petports_navNearestCell(position, freeMover, radius)
	end

	local graph = navGraphFor(navBridgeProfile())
	return navWithSide(freeMover, navNearestCellIn, graph, position, freeMover,
		radius, freeMover and 1 or 0)
end

--  What is in the store, for a log line. Counted rather than dumped: a full
--  tree is thousands of edges and a printJson of it would be unreadable and
--  would dominate the log it was meant to explain.
function petports_navStats()
	local index = navIndexRead()
	local profiles, edges, reachable = 0, 0, 0
	local pending = self.petportsNavPendingCount or 0
	local swept = 0

	for _, profile in ipairs(navIndexProfiles()) do
		local cells = index[profile]
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
--  15 MINUTES -> 6 HOURS, 2026-09-07j. world.time() counts while the world
--  is unloaded, so the old value measured absence, not staleness: a restart
--  after lunch dropped the whole mesh, and a world left running re-ran the
--  full 4..12 ladder every fifteen minutes forever, rewriting every shard
--  each time. Stale edges are caught where they are used -- a leg that will
--  not walk is re-probed and contradicted (taskAction 05c/05f) -- so the TTL
--  only needs to be shorter than "someone rebuilt the base and nobody ever
--  walked there since". A pass over the store is still a full survey when
--  it does come due.
local NAV_SWEEP_TTL = 21600.0

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
	if type(value) == "number" then return nil, 0 end
	if type(value) ~= "table" then return nil, 0 end
	if value.g ~= navGenNow() then return nil, 0 end

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
--  2 -> 6, 2026-09-06r. PROFILED at 2: probeStep 100-300 ms per 5 s, so
--  the search budget was mostly idle; sweeps complete in a tick or two and
--  the two slots were the ceiling on cells per second (~7). Workers stay
--  at 4; most verdicts are one tick.
--  6 -> 8, 2026-09-06x. PROFILED at 6: tick max 30-60 ms on the laptop,
--  update rate 12/s, navTick 13-27% -- room for two more.
PETPORTS_NAV_SWEEPS = 8
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
		freeMover = freeMover,
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

							--  NO BFS SKIP TEST FOR A FREE MOVER, 2026-09-06y.
							--  PROFILED: reaches n=4400-5800 per 5 s, 1.4-1.6 s
							--  of every 5, growing with the graph -- to avoid
							--  body sweeps that cost a millisecond each. The
							--  skip test only pays when the probe it skips is a
							--  search; a walker keeps it.
							local joined = nil

							if not fresh and not freeMover then
								joined = petports_navReaches(profile, cellKey, candidate.key)
							end

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
--  A PER-TICK TIME BUDGET FOR STEPPING SWEEPS, 2026-09-07a. PROFILED: a
--  free mover's probes resolve synchronously (a body sweep, ~1 ms), so eight
--  sweeps x four workers could spend 32+ ms in one tick, and did -- tick max
--  85-150 ms, ~1000 probes per 5 s, a lurch on every tick the unit moved.
--  The free-mover lookahead was 30-50 ms per 5 s: not it. With os.clock
--  available (PROFILE reports it), stepping stops for the tick once this
--  many milliseconds have been spent and the remaining sweeps resume next
--  tick, in rotating order so a starved one goes first. Without a clock the
--  budget is ignored. Tuned for the laptop: this is the pass criterion.
--  10 -> 4 AND STEPS 4 -> 2, 2026-09-07o. THE CRITERION MOVED. The engine's
--  world timestep is 1/60 s (retail WorldTimestep), so everything on the
--  world thread shares 16.7 ms a frame, and a script call that crosses it
--  freezes every walking entity on screen until it returns -- the "everything
--  halts for a fraction of a second" hitch, as opposed to one unit pausing
--  to plan. MEASURED 01:53 on 07n/07j with seven units: 157 of 233 unit
--  profile windows had a tick over 16 ms and navTick was the tick in 157 of
--  208 of them. The budget is checked BETWEEN steps, so a step begun at 9 ms
--  that resolves a 20 ms body sweep runs the tick to ~30, and CONCURRENT = 2
--  allows two such units in one frame plus a port beat. At 4 ms and two
--  steps the overrun is one step's worth from a smaller base; the survey is
--  slower in wall time, which is the accepted trade (see NAV_SURVEY_CONCURRENT).
local NAV_TICK_BUDGET_MS = 4.0

--  AND AT MOST THIS MANY SWEEPS PER UPDATE, 2026-09-07d. The engine caps
--  the Lua instructions one update may execute (scriptInstructionLimit in
--  StarLuaRoot, from starbound.config) and threw LuaInstructionLimitReached
--  out of Monster::update at 14:43, which aborts the whole update mid-way.
--  A time budget cannot see instructions, and one sweep resume can resolve
--  several body sweeps in a row; a count cap can. The rotation below means
--  every sweep still gets stepped within two updates.
local NAV_STEPS_PER_TICK = 2

navTickClock = function()
	if type(os) == "table" and type(os.clock) == "function" then
		local ok, t = pcall(os.clock)
		if ok and type(t) == "number" then return t end
	end
	return nil
end

function petports_navSweepStep()
	local sweeps = self.petportsNavSweeps
	if sweeps == nil or next(sweeps) == nil then return nil end

	local alive = 0

	--  COLLECTED FIRST, because finishing a sweep mutates the table and pairs()
	--  over a table being modified is undefined in Lua.
	local indices = {}
	for index in pairs(sweeps) do table.insert(indices, index) end
	table.sort(indices)

	--  Rotated so the sweep cut off last tick is stepped first this tick.
	local count = #indices
	local start = (self.petportsNavStepRotate or 0) % count
	local rotated = {}
	for i = 1, count do
		table.insert(rotated, indices[((start + i - 1) % count) + 1])
	end
	indices = rotated

	local began = navTickClock()
	local stepped = 0

	for _, index in ipairs(indices) do
		local sweep = sweeps[index]

		if stepped >= NAV_STEPS_PER_TICK then
			petports_profCount("stepCap")
			self.petportsNavStepRotate = (self.petportsNavStepRotate or 0) + stepped
			return "running"
		end

		if began ~= nil and stepped > 0 then
			local now = navTickClock()

			if now ~= nil and (now - began) * 1000 >= NAV_TICK_BUDGET_MS then
				petports_profCount("budgetCut")
				self.petportsNavStepRotate = (self.petportsNavStepRotate or 0) + stepped
				return "running"
			end
		end

		stepped = stepped + 1

		if sweep ~= nil then
			if coroutine.status(sweep.job) == "dead" then
				petports_navFinishSweep(index, true)
			else
				--  RESUMED AS ITS OWN SIDE, 2026-09-07u: a sweep started as `f0`
				--  keeps probing as `f0` however many top-ups of the other side
				--  happen while it is in flight.
				local ok, err = navWithSide(sweep.freeMover, coroutine.resume, sweep.job)

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

	self.petportsNavStepRotate = 0

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

	--  NO FLUSH HERE ANY MORE, 2026-09-06t. It used to flush first and mark
	--  second so a cell could not be marked swept with its edges unwritten.
	--  Since 06e the mark is QUEUED (navIndexQueue) and written by the same
	--  flush that writes the edges -- navIndexFlush is the first thing
	--  petports_navFlush does -- so the ordering is kept without a flush per
	--  sweep. PROFILED: a flush per sweep was flush n=60-73, ~1 s of every 5
	--  on a free mover whose sweeps finish in a tick, and the largest cost
	--  left in navTick.

	if completed then
		local index = navIndexRead()
		local cells = index[sweep.profile] or {}

		--  THE LARGEST RADIUS, NEVER A SMALLER ONE. Another unit may have swept
		--  this cell wider while we were on it; the ladder only climbs.
		local _, held = navIndexEntry(cells[sweep.cellKey])

		navIndexQueue(sweep.profile, sweep.cellKey, {
			at = world.time(),
			radius = math.max(held or 0, sweep.radius or 0),
			g = navGenNow()
		})

		--  Written with the next edge flush, or now if nothing is pending
		--  there for a while; see navIndexFlush.
		self.petportsNavFlushAt = self.petportsNavFlushAt
			or (world.time() + NAV_FLUSH_INTERVAL)
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

	petports_profCount(completed and "sweeps" or "abandoned")
	petports_profCount("sweepR" .. tostring(sweep.radius or 0))

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

		for from, tos in pairs(graph.coarse[tiles] or {}) do
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

	--  ONCE EVERY NAV_OVERLAY_REFRESH SECONDS, NOT PER VERSION, 2026-09-07h.
	--  The engine profile put this at 3750 of the unit's 10072 with the
	--  overlay on: the version bumps on every flush (several a second) and
	--  each recompute keys every cell into four coarse levels. A readout
	--  two seconds old is a readout.
	local now = world.time()

	if held ~= nil and held.profile == profile
	   and (held.version == version
	        or (now - (held.at or 0)) < NAV_OVERLAY_REFRESH) then
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
		levels = levels, at = now }

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
	local now = world.time()

	--  Same two-second refresh as the level readout; see petports_navLevelProgress.
	if held ~= nil and (held.version == version
	   or (now - (held.at or 0)) < NAV_OVERLAY_REFRESH) then
		return held.points
	end

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

			local at, radius = navIndexEntry(cells[cellKey])

			--  AN ENTRY FROM ANOTHER GENERATION IS NOT A CELL, 2026-09-08y:
			--  it read as unswept since 08v and drew orange after 08w.
			if at ~= nil then
				table.insert(points, {
					ox + PETPORTS_NAV_CELL * 0.5,
					oy + PETPORTS_NAV_CELL * 0.5,
					at = at,
					radius = radius or 0
				})
			end
		end
	end

	self.petportsNavSweptPoints = { version = version, points = points, at = now }

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

--  OFF BY DEFAULT, 2026-09-06. PROFILED: with the overlay on, navTick
--  cost 100 ms per update on average and 650 ms at worst, and the update
--  rate fell to six a second; world.debugLine ran at 5,000-7,000 calls per
--  second, two per swept cell per tick, for every swept cell in the store.
--  That was the whole of the flyer stutter that survived the survey fixes.
--  petports_navDebugToggle() turns it on; when on, only cells within
--  NAV_DRAW_RANGE of the unit are drawn.
--  BACK ON, 2026-09-06p, now that the graph is no longer rebuilt per flush
--  and the draw is culled and one call per cell.
--  OPT-IN AGAIN, 2026-09-06z. PROFILED with client debug rendering OFF:
--  draw 1.1-1.8 s of every 5, debugPoint 7,500 per second. The client
--  toggle does not stop the script drawing; only this flag does, and the
--  draw is the largest section in navTick whenever it is on. Turn it on
--  with petports_navDebugToggle() to watch a pass, and off after.
PETPORTS_NAV_DEBUG = false

--  96 -> 64, 2026-09-06y. PROFILED at 96: debugPoint 8,000 per second and
--  the update rate back down to 6-7/s. The draw is now its own PROFILE
--  section so the range can be traded against the tick rate on purpose.
local NAV_DRAW_FRESH = 10.0

--  Toggle from a console: /entityeval return petports_navDebugToggle()
--  The store's records within NAV_DRAW_RANGE of `here`, memoised per
--  NAV_ANCHOR_TTL. A cold pass reads every bucket index and every record
--  in range; the overlay is a diagnostic and pays for it once per TTL.
local NAV_BOUNDS_DRAW_REFRESH = 4.0

--  Graph edge lines in the overlay. Off by default (2026-09-09a); flip with
--  /entityeval PETPORTS_NAV_DRAW_EDGES = true.
PETPORTS_NAV_DRAW_EDGES = false

--  Cell key -> tile coordinates of its origin, or nil.
local function navKeyOrigin(key)
	local kx, ky = string.match(tostring(key), "^(-?%d+),(-?%d+)$")
	if kx == nil then return nil end
	return navCellOrigin(tonumber(kx), tonumber(ky))
end

--  A cached anchor for a cell of the current profile, or nil; never resolves.
local function navCachedAnchor(key)
	local cache = (self.petportsNavAnchorCache or {})[petports_navProfile()]
	local hit = cache ~= nil and cache[key] or nil
	return hit ~= nil and hit.anchor or nil
end

--  EVERYTHING THE UNIT HOLDS IN MEMORY THAT DECIDES WHERE IT GOES.
--
--    graph   this unit's graph memo: every edge whose from cell is within
--            NAV_DRAW_RANGE, as a line between cached anchors (uncached
--            anchors are skipped, not resolved). Blue for f1, green for f0.
--    walls   this unit's forbidden tile set: red points.
--    bounds  boundary records THIS unit wrote: cyan water, yellow poison,
--            white other -- the tick they were written.
--    route   the last route the router computed: a white polyline through
--            the cells' anchors, the held leg's waypoint as a magenta point,
--            or the why-line in red beside the unit when there was none.
--    text    survey verdict, graph size, route verdict.
local function navDrawLive(here, line)
	local profile = petports_navProfile()
	local freeMover = petports_freeMover()
	local edgeColour = freeMover and "blue" or "green"
	local graph = self.petportsNavGraph

	local cells, edges = 0, 0
	if graph ~= nil and graph.profile == profile and type(graph.fine) == "table" then
		local blocks = navGraphBlocks(graph)
		local ucx, ucy = petports_navCell(here)
		local ubx, uby = math.floor(ucx / NAV_BLOCK_CELLS), math.floor(ucy / NAV_BLOCK_CELLS)
		local ring = math.ceil(NAV_DRAW_RANGE / (NAV_BLOCK_CELLS * PETPORTS_NAV_CELL))

		for by = uby - ring, uby + ring do
			for bx = ubx - ring, ubx + ring do
				--  GRAPH EDGE LINES OFF, 2026-09-09a (Lofty). PETPORTS_NAV_DRAW_EDGES
				--  turns them back on for a look at the graph itself.
				if PETPORTS_NAV_DRAW_EDGES then
					for _, from in ipairs(blocks.map[bx .. "," .. by] or {}) do
						local a = navCachedAnchor(from)
						for _, to in ipairs(graph.fine[from] or {}) do
							local b = navCachedAnchor(to)
							if a ~= nil and b ~= nil then
								navDrawSafely(world.debugLine, a, b, edgeColour)
							end
						end
					end
				end
			end
		end

		for _ in pairs(graph.fine) do cells = cells + 1 end
		for _, tos in pairs(graph.fine) do edges = edges + #tos end

		--  CELLS THE GRAPH KNOWS ONLY AS EDGE TARGETS -- never swept, so not
		--  in the index and not drawn by the swept-points pass -- are orange
		--  as well. These are the frontier the survey has yet to reach.
		local sweptCells = navIndexRead()[profile]
		local now = world.time()
		local shown = {}
		for by = uby - ring, uby + ring do
			for bx = ubx - ring, ubx + ring do
				for _, from in ipairs(blocks.map[bx .. "," .. by] or {}) do
					for _, to in ipairs(graph.fine[from] or {}) do
						if not shown[to] and navSweptRadiusIn(sweptCells, to, now) <= 0 then
							shown[to] = true
							local ox, oy = navKeyOrigin(to)
							if ox ~= nil and math.abs(ox - here[1]) <= NAV_DRAW_RANGE
							   and math.abs(oy - here[2]) <= NAV_DRAW_RANGE then
								--  DARK MAGENTA, 2026-09-09b (Lofty): "never swept" and
								--  "swept just now" (bright magenta) were reading alike.
								navDrawSafely(world.debugPoint,
									{ ox + PETPORTS_NAV_CELL * 0.5, oy + PETPORTS_NAV_CELL * 0.5 },
									{ 110, 0, 110, 255 })
							end
						end
					end
				end
			end
		end
	end

	local wallCount = 0
	for tile in pairs(self.petportsNavForbidden or {}) do
		wallCount = wallCount + 1
		local tx, ty = string.match(tile, "^(-?%d+),(-?%d+)$")
		if tx ~= nil and math.abs(tonumber(tx) - here[1]) <= NAV_DRAW_RANGE
		   and math.abs(tonumber(ty) - here[2]) <= NAV_DRAW_RANGE then
			navDrawSafely(world.debugPoint, { tonumber(tx) + 0.5, tonumber(ty) + 0.5 }, "red")
		end
	end

	local mine = 0
	for _, entry in pairs(self.petportsNavBoundsLocal or {}) do
		mine = mine + 1
		if math.abs(entry.ox - here[1]) <= NAV_DRAW_RANGE
		   and math.abs(entry.oy - here[2]) <= NAV_DRAW_RANGE then
			for offset, name in pairs(entry.m) do
				local dx, dy = string.match(offset, "^(%d+),(%d+)$")
				if dx ~= nil and name ~= "air" then
					local colour = (name == "water" and "cyan")
						or (name == "poison" and "yellow") or "white"
					navDrawSafely(world.debugPoint,
						{ entry.ox + tonumber(dx) + 0.5, entry.oy + tonumber(dy) + 0.5 }, colour)
				end
			end
		end
	end

	local route = self.petportsNavLastRoute
	local routeText = "route: none asked"
	if route ~= nil then
		if route.path ~= nil then
			local previous = nil
			for _, key in ipairs(route.path) do
				local at = navCachedAnchor(key)
				if at == nil then
					local ox, oy = navKeyOrigin(key)
					if ox ~= nil then at = { ox + PETPORTS_NAV_CELL * 0.5, oy + PETPORTS_NAV_CELL * 0.5 } end
				end
				if previous ~= nil and at ~= nil then
					navDrawSafely(world.debugLine, previous, at, "white")
				end
				previous = at or previous
			end
			if route.waypoint ~= nil then
				navDrawSafely(world.debugPoint, route.waypoint, "magenta")
				navDrawSafely(world.debugLine, here, route.waypoint, "magenta")
			end
			routeText = string.format("route %s -> %s: %s hop(s), leg %s",
				tostring(route.from), tostring(route.to), sb.printJson(#route.path - 1),
				tostring(route.leg))
		else
			routeText = string.format("NO ROUTE %s -> %s: %s",
				tostring(route.from), tostring(route.to), tostring(route.why))
			navDrawSafely(world.debugText, tostring(route.why), { here[1] + 2, here[2] - 1.5 }, "red")
		end
	end

	local note = self.petportsNavSurveyNote
	local surveyText = "survey: no top-up yet"
	if note ~= nil then
		surveyText = string.format(
			"survey %s seed %s r%s cov %s gnd %s anchor %s -> %s | cand %s started %s refused %s %s",
			tostring(note.side), tostring(note.seed), tostring(note.seedRadius),
			tostring(note.seedCoverage), tostring(note.seedGrounded), tostring(note.seedAnchor),
			note.seedOk and "SEED" or "no seed",
			tostring(note.candidates or 0), tostring(note.started or 0),
			tostring(note.refused or 0), tostring(note.refusal or ""))
	end

	local lines = {
		{ surveyText, "cyan" },
		{ string.format("graph %s: %s cell(s) %s edge(s), walls %s, own bounds %s, sweeps %s",
			(graph ~= nil and graph.profile == profile) and "ready" or "MISSING",
			sb.printJson(cells), sb.printJson(edges), sb.printJson(wallCount),
			sb.printJson(mine), sb.printJson(petports_navSweepCount())), "cyan" },
		{ routeText, route ~= nil and route.path ~= nil and "green" or "red" }
	}

	for i, entry in ipairs(lines) do
		navDrawSafely(world.debugText, entry[1],
			{ here[1] + 2, here[2] + 3 - (line + i - 1) * 0.7 }, entry[2])
	end
end

local function navBoundsInRange(here)
	local now = world.time()

	--  FOUR SECONDS, NOT THE ANCHOR TTL, 2026-09-08l (Lofty): a shell
	--  appearing thirty seconds after it was found made the flood unreadable
	--  in the test. The pass is a registry read plus the records in range.
	if self.petportsNavBoundsDraw ~= nil
	   and (now - (self.petportsNavBoundsDrawAt or 0)) <= NAV_BOUNDS_DRAW_REFRESH then
		return self.petportsNavBoundsDraw
	end

	local out = {}
	local ok, registry = pcall(world.getProperty, NAV_BOUNDS)

	if ok and type(registry) == "table" then
		for bucket in pairs(registry) do
			local okIndex, index = pcall(world.getProperty, navBoundsIndexProperty(bucket))
			if okIndex and type(index) == "table" then
				for cellKey in pairs(index) do
					local bx, by = string.match(cellKey, "^(-?%d+),(-?%d+)$")
					if bx ~= nil then
						local ox, oy = navCellOrigin(tonumber(bx), tonumber(by))
						if math.abs(ox - here[1]) <= NAV_DRAW_RANGE
						   and math.abs(oy - here[2]) <= NAV_DRAW_RANGE then
							local okRec, record = pcall(world.getProperty,
								navBoundsCellProperty(bucket, cellKey))
							if okRec and type(record) == "table" and record.g == navGenNow() then
								table.insert(out, {
									bucket = bucket, ox = ox, oy = oy, record = record
								})
							end
						end
					end
				end
			end
		end
	end

	self.petportsNavBoundsDraw = out
	self.petportsNavBoundsDrawAt = now
	return out
end

--  THE OVERLAY'S SHARE, 2026-09-09u: every bridge this unit has learned,
--  within NAV_DRAW_RANGE. Green board -> hole for a dive, green shore ->
--  water for a wade, orange float -> land for an exit that works, red for
--  one that does not, magenta for the exit probe in flight, and a grey
--  cross at the centre of every boundary cell still waiting to be paired.
local function navDrawBridges(here)
	local function near(p)
		return type(p) == "table"
			and math.abs(p[1] - here[1]) <= NAV_DRAW_RANGE
			and math.abs(p[2] - here[2]) <= NAV_DRAW_RANGE
	end

	local function cross(position, colour)
		local size = 0.25
		navDrawSafely(world.debugLine,
			{ position[1] - size, position[2] }, { position[1] + size, position[2] }, colour)
		navDrawSafely(world.debugLine,
			{ position[1], position[2] - size }, { position[1], position[2] + size }, colour)
	end

	for _, bridge in pairs(self.petportsNavBridgesLocal or {}) do
		if bridge.k == "dive" and near(bridge.a) then
			navDrawSafely(world.debugLine, bridge.a, bridge.b, "green")
			cross(bridge.a, "green")
			cross(bridge.b, "green")
		elseif bridge.k == "wade" then
			local fx, fy = string.match(bridge.fromKey, "^(-?%d+),(-?%d+)$")
			local tx, ty = string.match(bridge.toKey, "^(-?%d+),(-?%d+)$")
			if fx ~= nil and tx ~= nil then
				local a = navWithSide(false, petports_navAnchor, tonumber(fx), tonumber(fy), false)
				local b = navWithSide(true, petports_navAnchor, tonumber(tx), tonumber(ty), true)
				if a ~= nil and b ~= nil and near(a) then
					navDrawSafely(world.debugLine, a, b, "green")
					cross(a, "green")
				end
			end
		elseif bridge.k == "exit" and near(bridge.a) then
			local tx, ty = string.match(bridge.toKey, "^(-?%d+),(-?%d+)$")
			local land = tx ~= nil and navWithSide(false, petports_navAnchor, tonumber(tx), tonumber(ty), false) or nil
			local colour = bridge.r and "orange" or "red"
			cross(bridge.a, colour)
			if land ~= nil then navDrawSafely(world.debugLine, bridge.a, land, colour) end
		end
	end

	local probe = self.petportsNavBridgeExit
	if probe ~= nil and near(probe.from) then
		navDrawSafely(world.debugLine, probe.from, probe.to, "magenta")
	end

	local function pendingCross(key)
		local cx, cy = string.match(key, "^(-?%d+),(-?%d+)$")
		if cx == nil then return end
		local ox, oy = navCellOrigin(tonumber(cx), tonumber(cy))
		local centre = { ox + PETPORTS_NAV_CELL / 2, oy + PETPORTS_NAV_CELL / 2 }
		if near(centre) then cross(centre, "gray") end
	end

	for key in pairs(self.petportsNavBridgeQueue or {}) do pendingCross(key) end
	for key in pairs(self.petportsNavBridgeRetry or {}) do pendingCross(key) end
end

navDrawBounds = function(here)
	for _, entry in ipairs(navBoundsInRange(here)) do
		local record = entry.record

		--  A POINT PER WET TILE, 2026-09-08c (Lofty): cyan for water, yellow
		--  for poison, white for anything else. No text, no boxes, no top
		--  line -- the overlay is read at a glance beside the swept-cell dots.
		if type(record.m) == "table" then
			for offset, name in pairs(record.m) do
				local dx, dy = string.match(offset, "^(%d+),(%d+)$")
				if dx ~= nil and name ~= "air" then
					local colour = (name == "water" and "cyan")
						or (name == "poison" and "yellow") or "white"
					navDrawSafely(world.debugPoint,
						{ entry.ox + tonumber(dx) + 0.5, entry.oy + tonumber(dy) + 0.5 }, colour)
				end
			end
		end
	end
end

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

	--  THE UNIT'S OWN VIEW, EVERY TICK, 2026-09-08s (Lofty). Nothing below
	--  reads the store. The level readout above said "COMPLETE" on an empty
	--  graph; this says what the survey, the graph, the walls and the router
	--  actually hold right now.
	navDrawLive(here, line)

	--  COVERAGE FIRST, so the probe overlay draws on top of it. CULLED to
	--  what is near the unit; see PETPORTS_NAV_DEBUG. ONE debugPoint per
	--  cell rather than two debugLines (Lofty, 2026-09-06), and BLUE for a
	--  free mover so its store reads differently from a walker's green
	--  crosses at a glance.
	--  RED WHILE FRESH (Lofty, 2026-09-06): a cell swept within the last
	--  NAV_DRAW_FRESH seconds draws red, so the front of a pass is visible
	--  at a glance and its speed can be judged by eye.
	--  BOUNDARY CELLS, 2026-09-08a. Every record in range, whoever wrote it:
	--  a wet tile is a square -- red if this chassis denies the liquid, cyan
	--  otherwise -- and the record's `top` row is a white line across the
	--  window, with the bucket's liquid list under the lower-left corner.
	navDrawBounds(here)
	navDrawBridges(here)

	local sweptColour = petports_freeMover() and "blue" or "green"
	local now = world.time()

	for _, point in ipairs(navSweptPoints()) do
		if math.abs(point[1] - here[1]) <= NAV_DRAW_RANGE
		   and math.abs(point[2] - here[2]) <= NAV_DRAW_RANGE then
			--  RED AT THE FIRST PASS, GREEN AT FULL RADIUS, 2026-09-08z (Lofty):
			--  the colour is the last radius the cell was swept to, so the
			--  survey's progress across a region reads as a gradient. Never
			--  swept (an edge target only) stays orange in navDrawLive.
			--  MAGENTA WHILE FRESH, 2026-09-09a (Lofty), then the radius gradient.
			local fresh = (now - (point.at or 0)) <= NAV_DRAW_FRESH
			navDrawSafely(world.debugPoint, point,
				fresh and "magenta" or navRadiusColour(point.radius))
		end
	end

	--  A LINE FROM THE UNIT TO EVERY SWEEP IN FLIGHT, 2026-09-08g (Lofty):
	--  the origin cell of each active sweep, drawn from where the unit is,
	--  so where the survey is working is visible as it happens rather than
	--  as a batch of swept dots appearing later. Green for the walker side,
	--  blue for the free-mover side, with the sweep's radius at the cell.
	for _, sweep in pairs(self.petportsNavSweeps or {}) do
		local sx, sy = string.match(tostring(sweep.cellKey), "^(-?%d+),(-?%d+)$")
		if sx ~= nil then
			local ox, oy = navCellOrigin(tonumber(sx), tonumber(sy))
			local centre = { ox + PETPORTS_NAV_CELL * 0.5, oy + PETPORTS_NAV_CELL * 0.5 }
			--  GREEN, 2026-09-08x (Lofty): the graph's edges draw blue on the
			--  swim side, so a sweep line in blue read as a route.
			navDrawSafely(world.debugLine, here, centre, "green")
			navDrawCell(tonumber(sx), tonumber(sy), "green")
			navDrawSafely(world.debugText, "r" .. tostring(sweep.radius),
				{ ox, oy + PETPORTS_NAV_CELL + 0.3 }, "green")
		end
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
--  How many graph cells one candidate walk examines; see the slice below.
--  300 -> 60, 2026-09-07h. Each scanned from brings its edges, so 300 froms
--  was a few thousand consider() calls per top-up; the engine profile had
--  candidates at 2881 of 10072 even after 07g. Sixty froms four times a
--  second still covers a thousand-cell graph in about four seconds.
local NAV_CANDIDATE_SCAN = 60

--  Blocks are NAV_BLOCK_CELLS cells on a side (16 tiles at cell 2); the
--  ring walk stops after NAV_CANDIDATE_RINGS rings so a unit in an empty
--  corner of a huge graph does not scan the whole thing every top-up.
local NAV_CANDIDATE_RINGS = 12

--  How many from-cells one top-up may walk while looking for unswept work.
--  A string.match and a table lookup each; six hundred is a few ms.
local NAV_CANDIDATE_FROMS = 200  --  600 -> 200, 2026-09-09q: 59 ms in one top-up

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

	--  A FREE MOVER'S OWN CELL USUALLY HAS NO ANCHOR (06u: only cells that
	--  touch a surface do), so a flyer at its station, hovering clear of the
	--  wall, seeded nothing after a wipe and the survey reported COMPLETE
	--  with zero cells (13:27 log). The seed is the nearest anchored cell
	--  within a few tiles instead; the anchor cache makes the box cheap.
	local seedX, seedY, seedKey = cx, cy, mine

	--  SEEDS BESIDE WALLS, 2026-09-08i: see navSeedBesideWall. Considered
	--  ahead of the ring scan; a seed that has been swept to full radius, or
	--  is older than the anchor TTL, is dropped. `consider` is defined below,
	--  so the list is walked after it is.

	if freeMover and petports_navAnchor(cx, cy, freeMover) == nil then
		local best = nil

		for dx = -4, 4 do
			for dy = -4, 4 do
				local d = dx * dx + dy * dy

				if (best == nil or d < best)
				   and petports_navAnchor(cx + dx, cy + dy, freeMover) ~= nil then
					best = d
					seedX, seedY = cx + dx, cy + dy
				end
			end
		end

		seedKey = petports_navCellKey(seedX, seedY)
		mineRadius = navSweptRadiusIn(sweptCells, seedKey, now)
	end

	--  THE SEED VERDICT, KEPT FOR THE OVERLAY, 2026-09-08s. MEASURED 18:00:
	--  after a wipe the survey ran candidates once every few seconds and got
	--  nothing, and no line said which of these four conditions refused the
	--  seed. Now the overlay prints it every tick.
	local seedAnchor = petports_navAnchor(seedX, seedY, freeMover)
	local seedOk = mineRadius < navFullRadius() and navInCoverage(seedX, seedY)
		and grounded and seedAnchor ~= nil

	self.petportsNavSurveyNote = {
		side = freeMover and "f1" or "f0",
		seed = seedKey,
		seedRadius = mineRadius,
		seedCoverage = navInCoverage(seedX, seedY),
		seedGrounded = grounded,
		seedAnchor = seedAnchor ~= nil,
		seedOk = seedOk,
		at = now
	}

	if seedOk then
		table.insert(found, {
			cx = seedX, cy = seedY, key = seedKey, distance = 0, radius = mineRadius
		})
	end

	local graph = navGraphFor(profile)
	local seen = { [mine] = true, [seedKey] = true }

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
		if radius >= navFullRadius() then return end

		local bx, by = string.match(cellKey, "^(-?%d+),(-?%d+)$")
		if bx == nil then return end

		--  OUT OF COVERAGE IS NOT A CANDIDATE. It stays in the graph if some
		--  earlier sweep found it -- an edge is an edge -- but nothing goes and
		--  surveys it, so the frontier cannot walk off across the planet.
		--  Asked only of a cell never swept (07g): a swept cell was inside
		--  coverage when swept, and the rectangles do not move between
		--  top-ups. navInCoverage was 174 of consider's 591 in the profile.
		if radius <= 0 and not navInCoverage(tonumber(bx), tonumber(by)) then
			return
		end

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

	--  A BOUNDED SLICE OF THE GRAPH PER CALL, 2026-09-07f. MEASURED 14:51:
	--  candidates max=103 ms and a second LuaInstructionLimitReached after
	--  the chunked rebuild -- this walk visited every cell and every edge
	--  in one call, then sorted every result. The graph carries a key list
	--  built once per version; each call scans NAV_CANDIDATE_SCAN froms
	--  from a rotating cursor. Nearest-first ranking still holds within the
	--  slice, and the cursor reaches every cell within a few calls, so the
	--  frontier is served in turn rather than all at once.
	--  SPATIAL, NOT ALPHABETICAL, 2026-09-08h. MEASURED 16:20 (Lofty): r8+
	--  sweeps on a shoreline hundreds of tiles off while r4 cells beside
	--  the port went untouched. The 60-key slice above was cut from
	--  graph.fineKeys, which is sorted AS STRINGS, so "nearest-first within
	--  the slice" ranked whatever sixty cells the cursor had reached, and
	--  the cursor reached the maze once per lap of the alphabet. Now the
	--  graph's cells are bucketed into NAV_BLOCK-tile blocks once per graph
	--  version (navGraphBlocks) and the scan walks rings of blocks outward
	--  from the unit's own block, stopping when it has NAV_CANDIDATE_SCAN
	--  froms or has run out of graph. The slice IS the neighbourhood, and
	--  the radius-then-distance sort below ranks it as it was meant to.
	if freeMover and self.petportsNavSeeds ~= nil then
		for key, at in pairs(self.petportsNavSeeds) do
			if (now - at) > NAV_ANCHOR_TTL * 4
			   or navSweptRadiusIn(sweptCells, key, now) >= navFullRadius() then
				self.petportsNavSeeds[key] = nil
			else
				consider(key)
			end
		end
	end

	--  UNTIL IT FINDS UNSWEPT WORK, 2026-09-09m. MEASURED (Lofty, five
	--  times): no cells at the coverage edge or the far shore, ever. 08h
	--  stopped this walk after NAV_CANDIDATE_SCAN from-cells; a never-swept
	--  cell only enters as the TARGET of a scanned from-cell, and around a
	--  parked unit there are hundreds of swept cells closer than the
	--  frontier, so the sixty were always the same interior cells being
	--  re-swept at the next radius and the frontier was never reached. Now
	--  the walk stops on candidates FOUND that are unswept (radius 0), keeps
	--  going outward until it has NAV_CANDIDATE_SCAN of them, and is bounded
	--  by NAV_CANDIDATE_FROMS from-cells and the ring limit instead.
	local blocks = navGraphBlocks(graph)
	local ubx, uby = math.floor(cx / NAV_BLOCK_CELLS), math.floor(cy / NAV_BLOCK_CELLS)
	local scanned = 0
	local ring = 0
	local seenBlocks = 0

	--  A RUNNING COUNT, 2026-09-09n: the rescan of `found` per block was
	--  87 ms in one top-up (MEASURED 14:17).
	local unswept, foundBefore = 0, 0

	local function unsweptFound()
		for i = foundBefore + 1, #found do
			if (found[i].radius or 0) <= 0 then unswept = unswept + 1 end
		end
		foundBefore = #found
		return unswept
	end

	while unsweptFound() < NAV_CANDIDATE_SCAN and scanned < NAV_CANDIDATE_FROMS
	      and seenBlocks < blocks.count and ring <= NAV_CANDIDATE_RINGS do
		for by = uby - ring, uby + ring do
			for bx = ubx - ring, ubx + ring do
				if math.abs(bx - ubx) == ring or math.abs(by - uby) == ring then
					local bucket = blocks.map[bx .. "," .. by]
					if bucket ~= nil then
						seenBlocks = seenBlocks + 1
						for _, from in ipairs(bucket) do
							consider(from)
							for _, to in ipairs(graph.fine[from] or {}) do consider(to) end
							scanned = scanned + 1
						end
					end
				end
			end
		end
		ring = ring + 1
	end

	--  NARROWEST FIRST, THEN NEAREST, tie-broken on the key because table.sort
	--  is not stable. The radius term is what makes the ladder run in PASSES:
	--  nothing is widened to 6 while any known cell is still owed its 4, and a
	--  cell the unit has only just discovered goes to the front of the queue
	--  at 0, so new ground always starts on the bottom rung.
	--  A BOUNDED BEST LIST, NOT A SORT, 2026-09-07g. The engine profile
	--  (.luaprofile, 15:13) put table.sort at 280 of this unit's 2264 and
	--  consider() at 591: every cell below the ceiling was collected and
	--  then all of them sorted to keep eight. Insertion into a list of at
	--  most `limit` is O(n x limit) with limit 8, and the same order.
	local function before(a, b)
		if a.radius ~= b.radius then return a.radius < b.radius end
		if a.distance ~= b.distance then return a.distance < b.distance end
		return a.key < b.key
	end

	if limit ~= nil and #found > limit then
		local best = {}

		for _, entry in ipairs(found) do
			local placed = false

			for i = 1, #best do
				if before(entry, best[i]) then
					table.insert(best, i, entry)
					placed = true
					break
				end
			end

			if not placed and #best < limit then
				table.insert(best, entry)
			elseif #best > limit then
				table.remove(best)
			end
		end

		return best
	end

	table.sort(found, before)
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
--  4 -> 8, 2026-09-06z, with the top-up now four times a second: one
--  top-up has to be able to refill every one of PETPORTS_NAV_SWEEPS slots.
local NAV_CLAIM_ATTEMPTS = 8

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

local function navPurgeDeadzonesInner(profile)
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

local function navPurgeDeadzones(profile)
	petports_profBegin("purge")
	local r = navPurgeDeadzonesInner(profile)
	petports_profEnd("purge")
	return r
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

--  BUT AN EMPTY TOP-UP BACKS OFF. 2026-09-06: a free mover's sweeps
--  complete in one step, so a slot is free nearly every tick, and once the
--  graph is fully swept the top-up ran twelve times a second forever: a
--  whole-index world.getProperty in the purge, the candidate walk, and
--  nothing to start. A walker never showed this because its slots stay
--  full for seconds at a time. When the top-up finds nothing, wait this
--  long before asking again; a new cell can only appear via a sweep, and
--  there is none running.
local NAV_IDLE_INTERVAL = 2.0
local NAV_TOPUP_INTERVAL = 0.25

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
--  ============================================================================
--  PROFILER, 2026-09-06 (Lofty: profile, do not guess). Two instruments:
--
--  1. SECTION TIMERS, if the sandbox exposes os.clock (checked at install,
--     reported once). petports_profBegin/End around a section; the report
--     gives calls, total ms and worst single call per section, and the
--     worst whole-update tick.
--  2. WORLD-CALL COUNTS, always. The world.* functions that touch tiles,
--     liquids and properties are wrapped in counting proxies. These are the
--     calls that cross to the world thread, which is where the stutter
--     lives, so their count per second is the number that matters even
--     without a clock.
--
--  A REPORT LINE EVERY PROF_REPORT_INTERVAL SECONDS while enabled:
--    PROFILE <secs>s | tick max Nms | <section> n=.. ms=.. max=.. | world/s: ..
--  petports_profToggle() flips it. Off, the wrappers still count (cheap)
--  but nothing is timed or logged.
--  ============================================================================
PETPORTS_PROFILE = true

local PROF_REPORT_INTERVAL = 5.0
local PROF_WORLD_FUNCTIONS = {
	"rectTileCollision", "lineTileCollision", "pointTileCollision",
	"liquidAt", "getProperty", "setProperty", "debugLine", "debugText",
	"debugPoint", "entityQuery", "material", "platformerPathStart"
}

--  SURVEY THROUGHPUT COUNTERS, 2026-09-06q. Bumped at the sites that mean
--  something and reported on the PROFILE line as a "survey:" segment:
--  sweeps done / abandoned, verdicts by kind (true in one tick, true in
--  more, false, too long, sweep-true for free movers), total probe ticks
--  spent on each kind (which is the search budget consumed), cells gained
--  to the frontier, and edges flushed. This is the number a "make it
--  propagate faster" change has to move, and where the ticks go says
--  which pairs to stop searching.
local profSurvey = {}

function petports_profCount(name, by)
	profSurvey[name] = (profSurvey[name] or 0) + (by or 1)
end

local profClock = nil
local profSections = {}
local profOpen = {}
local profWorldCounts = {}
local profTickStart, profTickMax = nil, 0
local profReportAt = nil
local profInstalled = false

local function profNow()
	if profClock == nil then return nil end
	local ok, t = pcall(profClock)
	if ok and type(t) == "number" then return t end
	return nil
end

--  THE GARBAGE COLLECTOR, 2026-09-07c. PROFILED after every other cost was
--  named: single probes of ~1 ms show maxima of 50-65 ms, `candidates`
--  maxima of 40-180 ms, `freeMover` maxima of 40 ms -- outliers of the same
--  size landing in whichever section is running, a few times a second.
--  That is the shape of a collector pause: the survey allocates a table or
--  three per probe and a string per key, hundreds of times a second, and
--  Lua 5.1's incremental collector pays for it in steps whose size grows
--  with the heap. Two things here: the PROFILE line reports the heap
--  (collectgarbage("count"), in KB) and its growth per interval, and
--  petports_gcTune() sets the collector to work in smaller, more frequent
--  steps (setpause 100, setstepmul 400) so the pauses shrink -- opt-in,
--  reported, reversible with the same call, because whether the sandbox
--  exposes collectgarbage at all is measured here, not assumed.
local profGcTuned = false

function petports_gcTune()
	if type(collectgarbage) ~= "function" then
		sb.logInfo("GC tune: collectgarbage is not available")
		return false
	end

	profGcTuned = not profGcTuned

	local pause = profGcTuned and 100 or 200
	local stepmul = profGcTuned and 400 or 200

	local okP = pcall(collectgarbage, "setpause", pause)
	local okS = pcall(collectgarbage, "setstepmul", stepmul)

	sb.logInfo("GC tune %s: setpause %s (%s), setstepmul %s (%s)",
		profGcTuned and "ON" or "OFF (defaults)", tostring(pause),
		okP and "ok" or "refused", tostring(stepmul), okS and "ok" or "refused")

	return profGcTuned
end

local function profHeapKb()
	if type(collectgarbage) ~= "function" then return nil end
	local ok, kb = pcall(collectgarbage, "count")
	if ok and type(kb) == "number" then return kb end
	return nil
end

local profHeapLast = nil

function petports_profInstall()
	if profInstalled then return end
	profInstalled = true

	local kb = profHeapKb()
	sb.logInfo("PROFILE heap: %s", kb ~= nil
		and (tostring(math.floor(kb)) .. " KB, collectgarbage available")
		or "collectgarbage NOT available")

	if type(os) == "table" and type(os.clock) == "function" then
		profClock = os.clock
	end

	local counted = 0

	for _, name in ipairs(PROF_WORLD_FUNCTIONS) do
		local original = world[name]

		if type(original) == "function" then
			--  The world table may refuse assignment; a refusal is reported,
			--  not fatal, and that function simply is not counted.
			local ok = pcall(function()
				world[name] = function(...)
					profWorldCounts[name] = (profWorldCounts[name] or 0) + 1
					return original(...)
				end
			end)

			if ok then
				profWorldCounts[name] = 0
				counted = counted + 1
			end
		end
	end

	sb.logInfo("PROFILE installed: clock %s, %s of %s world functions counted",
		profClock ~= nil and "os.clock" or "NONE (counts only)",
		sb.printJson(counted), sb.printJson(#PROF_WORLD_FUNCTIONS))
end

function petports_profToggle()
	PETPORTS_PROFILE = not PETPORTS_PROFILE
	sb.logInfo("PROFILE %s", PETPORTS_PROFILE and "ON" or "OFF")
	return PETPORTS_PROFILE
end

function petports_profBegin(section)
	if not PETPORTS_PROFILE then return end
	profOpen[section] = profNow()
end

function petports_profEnd(section)
	if not PETPORTS_PROFILE then return end

	local started = profOpen[section]
	profOpen[section] = nil

	local entry = profSections[section]
	if entry == nil then
		entry = { calls = 0, ms = 0, max = 0 }
		profSections[section] = entry
	end

	entry.calls = entry.calls + 1

	local now = profNow()
	if started ~= nil and now ~= nil then
		local ms = (now - started) * 1000
		entry.ms = entry.ms + ms
		if ms > entry.max then entry.max = ms end
	end
end

--  Call once per update, at the very start and the very end.
--  A STALL BETWEEN THIS UNIT'S OWN TICKS, 2026-09-07s. MEASURED 02:23 on
--  07r: a 0.5 s wallclock gap in the log that no section owned -- the
--  largest unit tick in the window was 57 ms and the largest port tick 79.
--  Either several entities put their 40-80 ms ticks in the SAME frame
--  (everything socketed together ticks in lockstep: unit profile lines
--  print 1-6 ms apart, all seven ports within 8 ms), or the time is
--  engine-side and no script sees it. This tells the two apart: every unit
--  sees the same stall, so the lines identify the frame; the entity whose
--  tick was longest just before it is the suspect, and if no entity had
--  one, the engine did it. os.clock is process CPU time, so with the
--  client thread busy the interval between two ticks reads longer than the
--  wall clock; the threshold is generous for that reason and the number is
--  for matching lines, not for measuring the stall.
local PROF_STALL_MS = 250
local profTickEndAt = nil

function petports_profTickBegin()
	if not PETPORTS_PROFILE then return end
	profTickStart = profNow()

	if profTickEndAt ~= nil and profTickStart ~= nil then
		local gap = (profTickStart - profTickEndAt) * 1000

		if gap >= PROF_STALL_MS then
			sb.logInfo("PROFILE STALL %s ms of process time between my ticks (clock %s)",
				tostring(math.floor(gap)), tostring(math.floor(profTickStart * 1000)))
		end
	end
end

function petports_profTickEnd()
	if not PETPORTS_PROFILE then return end

	local now = profNow()
	if profTickStart ~= nil and now ~= nil then
		local ms = (now - profTickStart) * 1000
		if ms > profTickMax then profTickMax = ms end
	end
	profTickEndAt = now

	local t = world.time()
	profReportAt = profReportAt or (t + PROF_REPORT_INTERVAL)
	if t < profReportAt then return end

	local span = PROF_REPORT_INTERVAL
	profReportAt = t + PROF_REPORT_INTERVAL

	local parts = {}

	for name, entry in pairs(profSections) do
		table.insert(parts, string.format("%s n=%s ms=%s max=%s",
			name, tostring(entry.calls),
			tostring(math.floor(entry.ms * 10 + 0.5) / 10),
			tostring(math.floor(entry.max * 10 + 0.5) / 10)))
	end
	table.sort(parts)

	local calls = {}
	for name, count in pairs(profWorldCounts) do
		if count > 0 then
			table.insert(calls, { name = name, count = count })
		end
	end
	table.sort(calls, function(a, b) return a.count > b.count end)

	local callParts = {}
	for _, c in ipairs(calls) do
		table.insert(callParts, string.format("%s %s",
			c.name, tostring(math.floor(c.count / span + 0.5))))
	end

	local surveyParts = {}
	for name, count in pairs(profSurvey) do
		table.insert(surveyParts, string.format("%s %s", name, tostring(count)))
	end
	table.sort(surveyParts)

	local heap = profHeapKb()
	local heapText = "n/a"

	if heap ~= nil then
		local grew = profHeapLast ~= nil and (heap - profHeapLast) or 0
		profHeapLast = heap
		heapText = string.format("%s KB (%s%s KB/5s)%s",
			tostring(math.floor(heap)), grew >= 0 and "+" or "",
			tostring(math.floor(grew)), profGcTuned and " gc-tuned" or "")
	end

	sb.logInfo("PROFILE %ss | tick max %sms | heap %s | %s | survey: %s | world/s: %s",
		tostring(span),
		tostring(math.floor(profTickMax * 10 + 0.5) / 10),
		heapText,
		#parts > 0 and table.concat(parts, " | ") or "no sections",
		#surveyParts > 0 and table.concat(surveyParts, ", ") or "idle",
		#callParts > 0 and table.concat(callParts, ", ") or "none")

	profSections = {}
	profSurvey = {}
	profTickMax = 0
	for name in pairs(profWorldCounts) do profWorldCounts[name] = 0 end
end

--  A NETWORK SURVEY BUDGET, AS A STRIDE, 2026-09-07n. MEASURED after six
--  petports_navWipe() calls on a seven-unit islet: every unit ran its own
--  NAV_TICK_BUDGET_MS and NAV_STEPS_PER_TICK at once, so the network's
--  survey cost was 10 ms x 7 per world update and the unit update rate
--  halved (57 -> 30 per 5 s window, nominal 60) until the ladders closed.
--  82% of unit time was navTick, and of that sweepStep -> probeStep: the
--  probes themselves, not the graph build or the flush.
--
--  THE PER-UNIT CONSTANTS ARE NOT LOWERED. They are also the instruction-cap
--  safety, and they are what one unit alone costs. Instead a unit takes a
--  survey TURN only on every k-th update, k = ceil(ports / CONCURRENT),
--  phased by entity id so the units interleave. Network survey cost is then
--  flat at CONCURRENT x one unit's budget whatever the unit count; a
--  rebuild takes proportionally longer in wall time, which is the trade.
--  Routing, legs and navGraphFor are never behind this gate.
--
--  THE PORT COUNT IS #self.petportsNetwork: one rect per member port,
--  pushed by the port, one unit per port. No new reads. A unit with no
--  rects (not yet pushed) or a single-port network gets stride 1: today's
--  behaviour. The top-up timer only counts dt on turns, so its intervals
--  stretch by the same stride, which is consistent with the rest.
local NAV_SURVEY_CONCURRENT = 2

local function navSurveyTurn()
	self.petportsNavUpdateCount = (self.petportsNavUpdateCount or 0) + 1

	local rects = self.petportsNetwork
	local ports = 1
	if type(rects) == "table" and #rects > 0 then ports = #rects end

	local stride = math.ceil(ports / NAV_SURVEY_CONCURRENT)
	if stride <= 1 then return true end

	--  entity.id() can be negative for some entity classes; the phase only
	--  needs to differ between units, not to be positive.
	local phase = math.abs(entity.id()) % stride

	if (self.petportsNavUpdateCount + phase) % stride == 0 then return true end

	petports_profCount("strideSkip")
	return false
end

--  ONE TOP-UP FOR ONE SIDE. Split out of navTickInner 2026-09-07u so
--  navWithSide can wrap exactly this and nothing above it. COMPLETION IS
--  PER SIDE: a switchable unit's `f0` can be complete while `f1` is not.
local function navTopUp(ownerId)
	local candidates = petports_navCandidates(NAV_CLAIM_ATTEMPTS)
	local side = petports_freeMover() and "1" or "0"

	self.petportsNavComplete = self.petportsNavComplete or {}

	if #candidates == 0 then
		self.petportsNavTimer = NAV_IDLE_INTERVAL

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
		--  NOT WHILE THE GRAPH IS STILL BEING BUILT: an empty candidate list
		--  from an empty graph is "not ready", not "complete".
		if not self.petportsNavComplete[side] and self.petportsNavGraphBuild == nil then
			self.petportsNavComplete[side] = true

			--  NO petports_navStats HERE ANY MORE, 2026-09-07m. It walks every
			--  profile's index and reads every shard in the store, cold -- on
			--  a base of thousands of cells that was a 700-2,900 ms tick, once
			--  per freshly socketed unit and again each time the frontier
			--  closed, which is the two-second planet lockup that survived
			--  every other fix. The counts are one /entityeval away
			--  (petports_navStats, petports_navDumpStore) when wanted.
			sb.logInfo("NAV survey COMPLETE for %s -- every known cell swept "
				.. "to radius %s",
				tostring(petports_navProfile()), sb.printJson(navFullRadius()))
		end

		return "idle"
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

		local began, refusal = petports_navSweepStart(cell.cx, cell.cy, ownerId, index)

		local note = self.petportsNavSurveyNote
		if note ~= nil then
			note.candidates = #candidates
			if began then
				note.started = (note.started or 0) + 1
				note.last = cell.key
			else
				note.refused = (note.refused or 0) + 1
				note.refusal = tostring(refusal)
			end
		end

		if began then
			self.petportsNavComplete[side] = false
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

local function navTickInner(dt, ownerId)
	navGenerationCheck()
	navIndexTick()

	--  THE REBUILD ADVANCES EVERY TICK, 2026-09-09s. MEASURED 14:42..14:46:
	--  "graph still building" for four minutes, fifty-three tasks failed
	--  with coarse nav having nothing, because a build step only ran when a
	--  routing call asked for the graph -- a few times a second, not twelve.
	--  navGraphFor steps the build at most once per tick; asking here makes
	--  that once every tick.
	if self.petportsNavGraphBuild ~= nil then
		navGraphFor(petports_navProfile())
	end
	if self.petportsNavMergedBuild ~= nil then
		navMergedGraphFor()
	end

	petports_profBegin("contradict")
	navContradictTick()
	petports_profEnd("contradict")
	petports_profBegin("flood")
	navBoundsFloodTick()
	petports_profEnd("flood")
	petports_profBegin("bridge")
	navBridgeTick()
	petports_profEnd("bridge")
	--  BEFORE THE STEP, so the pair currently in flight is drawn even on the
	--  tick it resolves and clears itself.
	petports_profBegin("draw")
	petports_navDebugDraw()
	petports_profEnd("draw")

	--  NOT THIS UNIT'S TURN: nothing below runs. Returns true when sweeps are
	--  alive so the caller reads it as "surveying", which it still is.
	if not navSurveyTurn() then
		return petports_navSweepCount() > 0
	end

	--  STEP EVERY RUNNING SWEEP, EVERY TURN. Only the SEARCH for new cells is
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
	--  THE PURGE ON ITS OWN SLOW TIMER. It can only remove entries older
	--  than NAV_SWEEP_TTL (fifteen minutes), so once a minute is plenty.
	local now = world.time()

	if self.petportsNavPurgeAt == nil or now >= self.petportsNavPurgeAt then
		self.petportsNavPurgeAt = now + 60.0
		navPurgeDeadzones(petports_navProfile())
	end

	--  THE TOP-UP RUNS AT MOST FOUR TIMES A SECOND, 2026-09-06z. PROFILED:
	--  candidates n=16-22 per 5 s at 400-530 ms -- a walk over every known
	--  cell, every tick a slot was free, and with eight sweeps finishing in
	--  a tick each that was most ticks. A quarter second of latency on a
	--  new sweep costs nothing the frontier notices.
	self.petportsNavTimer = NAV_TOPUP_INTERVAL

	--  THE TOP-UP RUNS AS ONE SIDE, 2026-09-07u. See navWithSide: candidates,
	--  seed, claims and the sweeps this starts all belong to that side, and
	--  the sweep records carry it so their resumes do too.
	local side = navSurveySide()
	local result = navWithSide(side, navTopUp, ownerId)

	--  AN IDLE SIDE FALLS THROUGH TO THE OTHER, 2026-09-07x. MEASURED 14:33..
	--  14:35 on the otter: an `f1` top-up on dry land usually has no
	--  candidates, and navTopUp then sets the 2 s idle timer -- which the
	--  NEXT top-up, the `f0` one, waited out. One empty side was halving
	--  the busy side's cadence. Now the empty side costs one candidate scan
	--  and the other side runs in the same tick; the idle timer only stands
	--  when BOTH sides are empty.
	if result == "idle" and petports_gravitySwitchable() then
		self.petportsNavSideFlip = not self.petportsNavSideFlip
		result = navWithSide(not side, navTopUp, ownerId)
	end

	return result == true
end

function petports_navTick(dt, ownerId)
	petports_profInstall()
	petports_profBegin("navTick")
	local result = navTickInner(dt, ownerId)
	petports_profEnd("navTick")
	return result
end

--  SUB-SECTIONS OF navTick, 2026-09-06: wrapped by reassignment so the
--  bodies stay untouched. Removed with the profiler when it goes.
local function profWrap(name, fn)
	return function(...)
		petports_profBegin(name)
		local a, b, c, d, e, f = fn(...)
		petports_profEnd(name)
		return a, b, c, d, e, f
	end
end

petports_navNeighbours = profWrap("neighbours", petports_navNeighbours)
petports_navFlush = profWrap("flush", petports_navFlush)
petports_navProbeStep = profWrap("probeStep", petports_navProbeStep)
petports_navReaches = profWrap("reaches", petports_navReaches)
petports_navSweepStart = profWrap("sweepStart", petports_navSweepStart)
petports_navSweepStep = profWrap("sweepStep", petports_navSweepStep)
petports_navCandidates = profWrap("candidates", petports_navCandidates)
--  THE ROUTING SIDE, 2026-09-07p: what the task action calls on a state
--  entry, which was the only unsectioned part of a unit tick. MEASURED
--  02:05 on 07o: two ~0.4 s wallclock stalls, both in the first update after
--  freshPather, invisible to every section above.
petports_navNearestCell = profWrap("nearestCell", petports_navNearestCell)
petports_navWaypoint = profWrap("waypoint", petports_navWaypoint)

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
		if radius >= navFullRadius() then full = full + 1 end
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
--  SIZE THE STORE, 2026-09-07l. Retail has no way to enumerate world
--  properties, but every one of ours is reachable from the registry:
--  registry -> per-profile index -> per-cell shard. This walks them and logs
--  one line per profile with cell count, shard count, edges (true/false),
--  and the serialised size in bytes (sb.printJson length, which is what the
--  world file and the property map actually hold), plus the claims table.
--  Read, not held: nothing is retained after the call.
--  /entityeval return petports_navDumpStore()
function petports_navDumpStore()
	local index = navIndexRead()
	local grand = 0

	for _, profile in ipairs(navIndexProfiles()) do
		local cells = index[profile]
		local cellCount, shards, trues, falses, bytes = 0, 0, 0, 0, 0

		local okIdx, idxJson = pcall(sb.printJson, cells)
		if okIdx then bytes = bytes + #idxJson end

		for cellKey in pairs(type(cells) == "table" and cells or {}) do
			cellCount = cellCount + 1

			local ok, shard = pcall(world.getProperty, navCellProperty(profile, cellKey))

			if ok and type(shard) == "table" then
				shards = shards + 1

				for _, entry in pairs(shard) do
					if type(entry) == "table" then
						if entry.r == true then trues = trues + 1 else falses = falses + 1 end
					end
				end

				local okJ, json = pcall(sb.printJson, shard)
				if okJ then bytes = bytes + #json end
			end
		end

		grand = grand + bytes

		sb.logInfo("NAV STORE %s: %s cell(s), %s shard(s), %s true / %s false edge(s), %s KB",
			profile, sb.printJson(cellCount), sb.printJson(shards),
			sb.printJson(trues), sb.printJson(falses),
			sb.printJson(math.floor(bytes / 1024)))
	end

	local okC, claims = pcall(world.getProperty, "petports_claims")
	local claimCount, claimBytes = 0, 0

	if okC and type(claims) == "table" then
		for _ in pairs(claims) do claimCount = claimCount + 1 end
		local okJ, json = pcall(sb.printJson, claims)
		if okJ then claimBytes = #json end
	end

	sb.logInfo("NAV STORE claims: %s entr(ies), %s KB | store total %s KB",
		sb.printJson(claimCount), sb.printJson(math.floor(claimBytes / 1024)),
		sb.printJson(math.floor((grand + claimBytes) / 1024)))

	return math.floor((grand + claimBytes) / 1024)
end

--  CLEAR EVERY NAV STORE IN THE WORLD, WHATEVER WROTE IT.
--
--  2026-09-07v. Walks the manifest: for each registered root, the family's
--  enumerator lists its properties and every one is cleared; a root with no
--  enumerator in THIS script (a family this build does not know) still has
--  its root cleared, and is logged, so a stale family from an older build
--  cannot survive silently. Then the survey claims, then the generation
--  bump that makes every other unit drop its memos. Own memos are dropped
--  here directly.
--
--  Wire up: /entityeval petports_navWipe() on any unit or port that loads
--  this file. petports_navSelfTest(true) calls it first.
function petports_navWipe()
	local cleared = 0
	local roots = 0

	local ok, manifest = pcall(world.getProperty, NAV_MANIFEST)
	if not ok or type(manifest) ~= "table" then manifest = {} end

	--  The families THIS build knows are enumerated whether or not any unit
	--  registered them; the manifest is for families this build does not.
	manifest[NAV_INDEX] = true
	manifest[NAV_BOUNDS] = true

	--  THIS UNIT'S OWN PROFILES, BY NAME, 2026-09-08y: the registry is one
	--  more memo-written property and need not list them. Both sides of a
	--  switchable chassis.
	local own = { petports_navProfile() }
	if petports_gravitySwitchable() then
		own[2] = navWithSide(not petports_freeMover(), petports_navProfile)
		own[3] = petports_navBridgeProfile()
	end
	for _, profile in ipairs(own) do
		local okCells, cells = pcall(world.getProperty, navIndexProperty(profile))
		if okCells and type(cells) == "table" then
			for cellKey in pairs(cells) do
				pcall(world.setProperty, navCellProperty(profile, cellKey), nil)
				cleared = cleared + 1
			end
		end
		pcall(world.setProperty, navIndexProperty(profile), nil)
		cleared = cleared + 1
	end

	for root in pairs(manifest) do
		roots = roots + 1
		local enumerate = navFamilies[root]
			or (root == NAV_INDEX and navEdgeFamilyEnumerate)
			or (root == NAV_BOUNDS and navBoundsFamilyEnumerate)

		if enumerate ~= nil then
			for _, name in ipairs(enumerate()) do
				pcall(world.setProperty, name, nil)
				cleared = cleared + 1
			end
		else
			sb.logInfo("NAV wipe: family %s is in the manifest but this build has no "
				.. "enumerator for it -- clearing its root only", tostring(root))
			pcall(world.setProperty, root, nil)
			cleared = cleared + 1
		end
	end

	pcall(world.setProperty, NAV_MANIFEST, nil)

	local claims = petports_claimsClearType ~= nil
		and petports_claimsClearType("nav") or 0

	local okGen, gen = pcall(world.getProperty, NAV_GEN)
	gen = (okGen and type(gen) == "number") and gen or 0
	pcall(world.setProperty, NAV_GEN, gen + 1)

	navDropMemos(gen + 1)

	sb.logInfo("NAV wiped %s propert(ies) across %s famil(ies), %s survey claim(s); "
		.. "generation %s", sb.printJson(cleared), sb.printJson(roots),
		sb.printJson(claims), sb.printJson(gen + 1))

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
