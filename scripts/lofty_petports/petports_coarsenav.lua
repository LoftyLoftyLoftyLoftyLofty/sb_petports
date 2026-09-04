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

local COARSENAV_BUILD_STAMP = "2026-09-04k one lifetime -- the sweep, not the edge"

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
local NAV_KEY = "petports_nav"

--  THE ONLY CELL SIZE IN v1.
--
--  The agreed structure is 32/16/8/4/2, derived upward from this by flood fill
--  rather than probed independently -- levels that are probed separately can
--  contradict each other and there is no principled way to resolve that. So
--  this is the only size anything ever probes, and the rest is arithmetic over
--  what it produces. None of that arithmetic is here yet.
PETPORTS_NAV_CELL = 2

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
--  16, AGAINST A 32-TILE PATH CAP, deliberately. The cap says how far a route
--  may WANDER; this says how far apart two things may be to be worth asking
--  about. Leaving room between them means an edge can be true via a modest
--  detour -- around a pillar, up a stair -- rather than only in a straight
--  line, which is exactly the case grid adjacency could not express.
PETPORTS_NAV_RADIUS = 16

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

	return math.floor(position[1] / PETPORTS_NAV_CELL),
		math.floor(position[2] / PETPORTS_NAV_CELL)
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
function petports_navAnchor(cx, cy, freeMover)
	local baseX = cx * PETPORTS_NAV_CELL
	local baseY = cy * PETPORTS_NAV_CELL

	local bounds = mcontroller.boundBox()

	--  How far the body position sits ABOVE its own feet. bounds[2] is the
	--  lower extent and is negative, so this is a positive lift.
	local lift = -(bounds[2] or -0.5)

	local tried = 0

	for dx = 0, PETPORTS_NAV_CELL - 1 do
		for dy = 0, PETPORTS_NAV_CELL - 1 do
			local x = baseX + dx + 0.5

			if freeMover then
				--  CENTRE OF THE TILE, because a free mover is not resting on
				--  anything -- there is no surface to lift off.
				--
				--  THE WHOLE BODY, NOT A POINT. pointTileCollision would pass a
				--  flyer through a one-tile gap it cannot fit in. Platform is
				--  absent from the set deliberately: a platform is passable to
				--  something that ignores gravity. Dynamic is present because
				--  fact.pathing.collisionkinds says Dynamic is DOORS, and a
				--  closed door stops a flyer.
				local point = { x, baseY + dy + 0.5 }
				local region = {
					point[1] + bounds[1], point[2] + bounds[2],
					point[1] + bounds[3], point[2] + bounds[4]
				}

				tried = tried + 1

				local ok, hit = pcall(world.rectTileCollision, region,
					{ "Null", "Block", "Dynamic", "Slippery" })

				if ok and hit == false then return point end
			else
				--  BOTTOM EDGE OF THIS TILE ROW is the surface; the body rests
				--  `lift` above it.
				local point = { x, baseY + dy + lift }

				tried = tried + 1

				local ok, standable = pcall(validStandingPosition, point, false)
				if ok and standable == true then return point end
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
function petports_navNeighbours(cx, cy, freeMover)
	local origin = petports_navAnchor(cx, cy, freeMover)
	if origin == nil then return {}, nil end

	--  Cells that COULD hold something within the radius. Rounded up, then
	--  filtered by true anchor distance below -- the box is a cheap prefilter
	--  and the distance test is the actual rule.
	local reach = math.ceil(PETPORTS_NAV_RADIUS / PETPORTS_NAV_CELL)

	local found = {}

	for dx = -reach, reach do
		for dy = -reach, reach do
			if dx ~= 0 or dy ~= 0 then
				local nx, ny = cx + dx, cy + dy
				local anchor = petports_navAnchor(nx, ny, freeMover)

				if anchor ~= nil then
					local ax = anchor[1] - origin[1]
					local ay = anchor[2] - origin[2]

					local distance = math.sqrt(ax * ax + ay * ay)

					if distance <= PETPORTS_NAV_RADIUS then
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

local function navRead()
	local ok, store = pcall(world.getProperty, NAV_KEY)
	if not ok or type(store) ~= "table" then return {} end
	return store
end

local function navWrite(store)
	pcall(world.setProperty, NAV_KEY, store)
end

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

	local store = navRead()
	local written = 0

	for profile, edges in pairs(pending) do
		store[profile] = store[profile] or {}

		for key, entry in pairs(edges) do
			store[profile][key] = entry
			written = written + 1
		end
	end

	navWrite(store)

	self.petportsNavPending = {}
	self.petportsNavPendingCount = 0
	self.petportsNavFlushAt = world.time() + NAV_FLUSH_INTERVAL

	sb.logInfo("NAV flushed %s edge(s) to the store", sb.printJson(written))

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
		local store = navRead()
		local edges = store[profile]
		if type(edges) ~= "table" then return nil end
		entry = edges[key]
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
	local store = navRead()
	local edges = store[profile]
	if type(edges) ~= "table" then return 0 end

	local dropped = 0

	for key in pairs(edges) do
		local from, to = string.match(key, "^(.-)>(.*)$")
		if from == cellKey or to == cellKey then
			edges[key] = nil
			dropped = dropped + 1
		end
	end

	if dropped > 0 then
		sb.logInfo("NAV cell %s SEALED for %s -- dropped %s edge(s)",
			tostring(cellKey), tostring(profile), sb.printJson(dropped))
		navWrite(store)
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
		local store = navRead()
		previous = type(store[profile]) == "table" and store[profile][key] or nil
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
function petports_navProbeStep(fromCell, toCell, exploreRate)
	stampOnce()

	local freeMover = petports_freeMover()

	local fromKey = petports_navCellKey(fromCell[1], fromCell[2])
	local toKey = petports_navCellKey(toCell[1], toCell[2])

	local probe = self.petportsNavProbe

	if probe == nil or probe.fromKey ~= fromKey or probe.toKey ~= toKey then
		local from, fromWhy = petports_navAnchor(fromCell[1], fromCell[2], freeMover)
		local to, toWhy = petports_navAnchor(toCell[1], toCell[2], freeMover)

		--  NO ANCHOR IS NOT UNREACHABLE. A cell of solid rock has nothing to
		--  path to or from, and recording false would assert something about
		--  connectivity that was never tested. nil, and nothing is stored.
		if from == nil or to == nil then
			sb.logInfo("NAV probe %s -> %s SKIPPED: %s",
				fromKey, toKey, tostring(from == nil and fromWhy or toWhy))

			--  AND FORGET WHATEVER THE SEALED CELL USED TO CLAIM. See
			--  petports_navForget: skipping here is what let a boxed-in unit
			--  keep two reachable edges.
			local profile = petports_navProfile()
			if from == nil then petports_navForget(profile, fromKey) end
			if to == nil then petports_navForget(profile, toKey) end

			self.petportsNavProbe = nil
			return nil
		end

		local finder = PathFinder:new(navPathOptions())
		finder.exploreRate = function() return exploreRate or 300 end
		finder:start(from, to)

		sb.logInfo("NAV probe START %s -> %s: %s to %s (profile %s, rate %s, maxDistance %s)",
			fromKey, toKey, sb.printJson(from), sb.printJson(to),
			tostring(petports_navProfile()), sb.printJson(exploreRate or 300),
			sb.printJson(NAV_MAX_DISTANCE))

		self.petportsNavProbe = {
			finder = finder,
			fromKey = fromKey,
			toKey = toKey,
			ticks = 0,
			started = world.time()
		}

		probe = self.petportsNavProbe
	end

	probe.ticks = probe.ticks + 1

	local result = probe.finder.aStar:explore(exploreRate or 300)

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
		sb.logInfo("NAV probe %s -> %s %s after %s tick(s)",
			fromKey, toKey,
			result and "REACHABLE" or "UNREACHABLE",
			sb.printJson(probe.ticks))

		petports_navLearn(petports_navProfile(), fromKey, toKey, result)

		self.petportsNavProbe = nil
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
	local store = navRead()
	local out = {}

	--  STORE THEN BATCH, so an unflushed edge is traversable the moment it is
	--  learned. Same reason navKnown reads the batch first: a sweep has to be
	--  able to see its own work, or nearest-first ordering buys nothing.
	local edges = {}

	for key, entry in pairs(type(store[profile]) == "table" and store[profile] or {}) do
		edges[key] = entry
	end

	for key, entry in pairs(navPendingFor(profile) or {}) do
		edges[key] = entry
	end

	for key, entry in pairs(edges) do
		--  `entry.r == true` ALSO EXCLUDES THE swept: MARKERS, which share this
		--  table and carry a timestamp with no verdict. Deliberate rather than
		--  incidental: they are per-cell bookkeeping, not edges, and a key
		--  without a ">" would produce a nil `from` below anyway.
		--
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

	local adjacency = navAdjacency(profile)
	local visited = { [fromKey] = true }
	local frontier = { fromKey }
	local expanded = 0

	budget = budget or PETPORTS_NAV_SEARCH_BUDGET

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

--  What is in the store, for a log line. Counted rather than dumped: a full
--  tree is thousands of edges and a printJson of it would be unreadable and
--  would dominate the log it was meant to explain.
function petports_navStats()
	local store = navRead()
	local profiles, edges, reachable = 0, 0, 0
	local pending = self.petportsNavPendingCount or 0

	local markers = 0

	for _, byProfile in pairs(store) do
		profiles = profiles + 1

		for key, entry in pairs(byProfile) do
			--  SWEPT MARKERS SHARE THE TABLE AND ARE NOT EDGES. Counting them
			--  made a 38-edge cell report 39, which is small and is exactly the
			--  kind of off-by-one that gets chased for an hour later.
			if string.find(key, ">", 1, true) == nil then
				markers = markers + 1
			else
				edges = edges + 1
				if type(entry) == "table" and entry.r == true then
					reachable = reachable + 1
				end
			end
		end
	end

	return profiles, edges, reachable, pending, markers
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

local function navSweptKey(cellKey)
	return "swept:" .. cellKey
end

function petports_navSwept(profile, cellKey)
	local store = navRead()
	local edges = store[profile]
	if type(edges) ~= "table" then return nil end

	local entry = edges[navSweptKey(cellKey)]
	if type(entry) ~= "table" then return nil end

	if (world.time() - (entry.t or 0)) > NAV_SWEEP_TTL then return nil end

	return entry.t
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
function petports_navSweepStart(cx, cy, ownerId)
	local profile = petports_navProfile()
	local cellKey = petports_navCellKey(cx, cy)

	if petports_navSwept(profile, cellKey) ~= nil then
		return nil, "already swept"
	end

	local workId = "nav:" .. profile .. ":" .. cellKey

	if not petports_claimTake(workId, ownerId, entity.id(), "nav",
		mcontroller.position(), NAV_CLAIM_TTL) then
		return nil, "claimed by another unit"
	end

	local freeMover = petports_freeMover()

	self.petportsNavSweep = {
		workId = workId,
		ownerId = ownerId,
		cellKey = cellKey,
		profile = profile,
		started = world.time(),
		job = coroutine.create(function()
			local neighbours = petports_navNeighbours(cx, cy, freeMover)

			for _, cell in ipairs(neighbours) do
				--  TWO SKIPS, AND LEAVING OUT THE SECOND COST THE WHOLE SAVING.
				--
				--  petports_navReaches answers "does the GRAPH already join
				--  these", which is true only for reachable pairs -- a false
				--  edge is ABSENCE to a graph search, not a wall. So consulting
				--  it alone skips every cheap pair and re-probes every dear
				--  one. Measured 2026-09-04: a re-sweep of a fully surveyed
				--  cell skipped all 26 reachable pairs instantly and then paid
				--  78 ticks each for the same 12 unreachable ones it had
				--  already cached, which is 77% of the cost of a cold sweep.
				--
				--  petports_navKnown answers the other question -- "do we have
				--  a fresh DIRECT verdict for this pair" -- and that is what
				--  the false cache was written for. This file already said
				--  falses are memoised so the prober does not ask twice; the
				--  prober simply never asked.
				--
				--  ORDER IS DELIBERATE. navKnown is a store read, navReaches is
				--  a graph walk, so the cheaper question goes first.
				--  FRESH MEANS "NEWER THAN A SWEEP INTERVAL", which is the one
				--  place freshness is decided. A verdict older than that is
				--  exactly what this re-sweep exists to refresh.
				local known, age = petports_navKnown(profile, cellKey, cell.key)
				local fresh = known ~= nil and (age or 0) < NAV_SWEEP_TTL

				local joined = (not fresh)
					and petports_navReaches(profile, cellKey, cell.key) or nil

				if not fresh and joined ~= true then
					local verdict = "searching"

					while verdict == "searching" do
						verdict = petports_navProbeStep({ cx, cy },
							{ cell.cx, cell.cy }, 300)

						if verdict == "searching" then coroutine.yield() end
					end
				end

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
function petports_navSweepStep()
	local sweep = self.petportsNavSweep
	if sweep == nil then return nil end

	if coroutine.status(sweep.job) == "dead" then
		petports_navFinishSweep(true)
		return "done"
	end

	local ok, err = coroutine.resume(sweep.job)

	if not ok then
		sb.logError("NAV sweep of %s FAILED: %s", tostring(sweep.cellKey),
			tostring(err))
		petports_navFinishSweep(false)
		return "done"
	end

	return "running"
end

--  MARKED SWEPT ONLY ON A CLEAN FINISH. An abandoned or failed sweep leaves the
--  cell unmarked so somebody tries again; marking it regardless would bake a
--  half-surveyed cell into the tree for the whole sweep TTL.
function petports_navFinishSweep(completed)
	local sweep = self.petportsNavSweep
	if sweep == nil then return end

	if completed then
		local store = navRead()
		store[sweep.profile] = store[sweep.profile] or {}
		store[sweep.profile][navSweptKey(sweep.cellKey)] = { t = world.time() }
		navWrite(store)
	end

	petports_navFlush()
	petports_claimRelease(sweep.workId, sweep.ownerId)

	sb.logInfo("NAV sweep of %s %s", tostring(sweep.cellKey),
		completed and "COMPLETE" or "ABANDONED")

	self.petportsNavSweep = nil
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

	if wipe ~= false then
		pcall(world.setProperty, NAV_KEY, nil)
		self.petportsNavPending = {}
		self.petportsNavPendingCount = 0
		self.petportsNavFlushAt = nil
	end

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
