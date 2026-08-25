--  PETPORTS UNIT -- TASK EXECUTION
--
--  Executes a task the petport dispatched. The unit does not discover work;
--  discovery belongs to the port, which owns the coverage rect and is resident
--  whenever the network is.
--
--  NAMING
--
--  groundPet.lua builds its action list with
--
--      stateMachine.scanScripts(config.getParameter("scripts"), "(%a+Action)%.lua")
--
--  and looks the captured name up in _ENV, so the global below must match the
--  filename's capture exactly. %a is letters only -- an underscore truncates.
--  "petportsTaskAction" is all letters, so it survives whole.
--
--  Unlike petportsSleepAction, this state does NOT need a description()
--  override. That one reports vanilla's name because petBehavior hardcodes
--  ["sleep"] = "sleepAction". Our forked petBehavior maps
--  ["petportsTask"] = "petportsTaskAction", which is what stateDesc() returns
--  by default, so the behaviour layer already sees the right label.
--
--  TASK SHAPE
--
--      { id = <workId>, type = <"diag" | "collect" | "harvest" | ...>,
--        port = <petport uniqueId>, position = {x, y},
--        target = <entity id, "collect" and "harvest" only>,
--        dwell = <seconds, "diag" only> }
--
--  TASK TYPES
--
--  "collect" -- walk to an item drop and take it. The drop's position is
--  re-read every tick rather than trusted from the task, because drops FALL,
--  slide, and get pushed around; a stale target sends the unit to where the
--  item used to be.
--
--  The item is DESTROYED on pickup for now. That is the testing sink, and it is
--  deliberate — clutter accumulating in an inventory or a box across repeated
--  runs makes every subsequent run harder to read. The real sinks are the
--  petport's own storage, then crate routing. A collection task is "claim,
--  path, pick up, dispose" and only the last step changes.
--
--  "harvest" -- walk to a ripe farmable and pick it. The act is a
--  world.damageTiles call on the crop's own tile: FarmableObject overrides
--  damageTiles and calls harvest() for Beamish, Blockish and Plantish damage,
--  consuming the damage when the harvest succeeds. The engine handles
--  resetToStage, so a crop that regrows and a crop that is destroyed take the
--  same call and need no distinction here.
--
--  The unit does NOT pick up what it harvested. The drops are ordinary drops,
--  and the ordinary collection task takes them on a later dispatch -- including
--  any seed, which walks back to storage like anything else. That is the whole
--  of the v1 scope.
--
--  "withdraw" -- walk to a crate and stand there. No act at all: the port does
--  the world.containerConsume when the arrival is reported, the same way it
--  does the containerAddItems for a deposit. The seed lands on petData, so it
--  never has to exist anywhere it could be dropped.
--
--  "replant" -- walk to a tile an intent names and put the seed back in the
--  ground with world.placeObject. The seed and the crop share one name, so
--  there is nothing to look up: what was harvested is what gets planted.
--
--  "water" -- sweep a run of dry tilled soil, one tile at a time, spending one
--  unit of carried liquid per tile.
--
--  THE FIRST TASK WITH MORE THAN ONE DESTINATION. Every other task walks to a
--  place and does a thing; this one walks a LIST, in order, and the order is
--  the feature -- watering a forty-tile row in discovery order looks like a
--  malfunction rather than gardening. The port builds the run ordered and picks
--  the end nearer the unit; the unit sweeps away from it and never reverses.
--
--  The act is a projectile, not a liquid. world.spawnLiquid needed up to
--  fourteen attempts to saturate one tile -- it is tuned for rain, not for
--  gardening -- while applySurfaceMod is exact and lands once. So the droplet
--  is spawned ABOVE the tile and falls onto it, which is also what tilled
--  soil's topOnly liquidInteractions expect.
--
--  "animal" -- walk to a farm animal and take its produce. The act is one
--  call, world.callScriptedEntity(target, "dropMonsterHarvest"), which spawns
--  the treasure AND resets the animal's own harvest timer in the same function.
--  We never touch that timer, so we cannot corrupt it -- faking the harvest with
--  spawnTreasure would leave the animal permanently ready, which is a
--  duplication exploit rather than a farm.
--
--  Drops land on the ground at the animal, so collection and deposit take it
--  from there unchanged, exactly as with crops.
--
--  DIAGNOSTIC TASK
--
--  type "diag" is throwaway. Walk to a point inside the rect, stand there,
--  report done. It exists to isolate the infrastructure -- does the port
--  discover work inside its rect and refuse it outside, does a claim get taken
--  and released, does a claim expire when the unit dies mid-task, does any of
--  it survive a reload -- without also debugging an unproven item API. Delete
--  it once drop collection works.

petportsTaskAction = {}

--  How long to keep trying to reach the target before giving up and handing the
--  task back. Not a cooldown: the port re-dispatches, and repeated failures on
--  the same point are the signal worth seeing in the log.
local APPROACH_TIMEOUT = 20.0

--  How close counts as arrived. Passed to approachPoint, which owns the actual
--  test -- see update().
local ARRIVAL_DISTANCE = 1.5

--  Per-second approach tracing. Noisy; off once reachability is understood.
local TASK_DEBUG = true

--  BUILD STAMP.
--
--  Printed once per state entry. Twice now a fix has been diagnosed as not
--  working when the running game was simply loading an older copy of the file
--  -- once because a whole tree was stale, once because one file of two did not
--  get copied. Both times the symptom was identical to a failed fix, and both
--  times it cost a launch.
--
--  Grep the stamp before believing anything else in the log. Bump it on every
--  handoff; a stamp that never changes is worse than none.
--
--  NOT LOGGED AT FILE SCOPE. THIS IS A CRASH, NOT A STYLE POINT.
--
--  Starbound loads and RUNS a script chunk when the context is created, and
--  binds the root callback tables -- sb, world, root, mcontroller -- afterward.
--  So at chunk-execution time `sb` is still nil, and any top-level `sb.logInfo`
--  raises "attempt to index global 'sb' (a nil value)" before a single function
--  in this file is defined. The unit never gets a task action at all.
--
--  Every other engine call in this mod lives inside a function for this reason.
--  If a stamp is wanted earlier than first entry, put it in a function the
--  monstertype's script list will call, never beside the local it names.
local BUILD_STAMP = "2026-08-25d leash arrival resolves the ground"
local stampLogged = false

--  How long to let A* search without producing a path before calling the
--  target unreachable.
--
--  THE PATHFINDER NEVER REPORTS UNREACHABLE. PathFinder:explore() only returns
--  false when A* exhausts its open set, and on an open planet surface the
--  accessible region is effectively unbounded -- so an unreachable target keeps
--  returning "pathfinding" indefinitely. Observed: hasPath false with aStar
--  alive for the full twelve-second approach timeout, on a target up a ladder.
--
--  A reachable target is found almost immediately by comparison: flat-ground
--  tasks report hasPath true on the first telemetry line. So a search still
--  running after a few seconds is not slow, it is not going to succeed.
--
--  This is a real cost saving as well as a faster failure: a churning A* is
--  burning CPU every tick it runs.
--  How long to let A* search without producing a path before calling the
--  target unreachable.
--
--  MEASURED 2025-08-20 at the default explore rate: a chained route (deck ->
--  staircase -> four platform hops) took 22.25 SECONDS to solve; the same
--  target from atop the platforms took 0.08s. It was never unreachable, it was
--  starved. See EXPLORE_RATE below -- with the budget raised, the hard case
--  costs about two seconds, so six is a comfortable ceiling.
local SEARCH_LIMIT = 6.0

--  Node expansions per update, overriding PathFinder:exploreRate().
--
--  Vanilla derives this from world.fidelity(), which is a SERVER-side load
--  setting with no player control -- 25 at "minimum", 150 at "high". At 25 a
--  jump-chained route needs tens of seconds to solve, which is why long routes
--  looked unreachable.
--
--  Fixing it here rather than accepting the fidelity value means pathing
--  quality no longer varies with server load, which is worth more than the
--  saved cycles: a unit that can reach a platform on a quiet server and not on
--  a busy one is indistinguishable from a bug.
--
--  This does NOT increase total work for a solvable path -- the same nodes are
--  expanded, just sooner. It DOES make an unsolvable search burn its 70000-node
--  allowance faster, which is a benefit: A* then returns false honestly instead
--  of searching indefinitely.
local EXPLORE_RATE = 300

--  How long to wait for a drop to stop falling before calling it unreachable.
local SETTLE_GRACE = 2.0

--  HOW FAR THE UNIT MUST MOVE TO COUNT AS NOT STUCK.
--
--  Compared against an ANCHOR that only moves when the threshold is crossed, so
--  displacement accumulates: a unit crawling at half a tile per second still
--  clears this every fifth of a second, while a unit wedged against terrain
--  never clears it at all.
--
--  See the stuck-timer note below for what this feeds.
local STUCK_MOVE = 0.1

--  HOW LONG A GROUNDED UNIT MAY SIT MOTIONLESS ON AN AIRBORNE EDGE.
--
--  Must be longer than 0.2, because moveJump deliberately parks the unit for
--  that long before takeoff: it sets the position onto the jump source, zeroes
--  the velocity, and counts jumpTimer down from 0.2. That is a legitimate
--  motionless grounded tick on a Jump edge and must not be read as a stall.
--  jumpTimer is also checked directly below; this is the second guard.
--
--  Below vanilla's own 0.5, so the classified line lands before the anonymous
--  reset does.
local AIRBORNE_EDGE_STALL = 0.35

--  The same idea for a GROUNDED WALK edge, and deliberately much longer.
--
--  A walker can be legitimately motionless for a tick or two -- against a step,
--  or while the controller reverses direction -- and replanning on that would
--  thrash a path that was about to work. Over a second of a grounded walk going
--  nowhere is never legitimate.
--
--  ABOVE vanilla's 0.5, unlike AIRBORNE_EDGE_STALL, and that is the trade. If
--  vanilla's stuckTimer is working it resets the path first and this never
--  fires, which is fine -- this exists for the case where it demonstrably did
--  not: a leash walk that sat on one Walk edge for seven seconds with no
--  replan and no path LOST, on an open platform, until the unit was resocketed
--  by hand.
local WALK_EDGE_STALL = 1.25

--  Cap on arc waypoints skipped in one tick. Only a bound on the loop below --
--  reaching it would mean the whole descending half of an arc was above the
--  unit, which cannot happen. It exists so a malformed path cannot spin here.
local MAX_ARC_SKIP = 16

--  Vanilla's own takeoff radius, copied rather than changed. See the header on
--  petportsJumpMover for why this is not widened.
local JUMP_TAKEOFF_REACH = 1.0

--  Below this horizontal offset there is nothing to walk toward -- the jump
--  point is effectively straight up or straight down.
local JUMP_APPROACH_EPSILON = 0.05

--  How far the jump source may sit above or below the unit and still be worth
--  WALKING toward.
--
--  Walking changes x. It does not change what level the unit is standing on, so
--  a source four tiles down is not something to approach -- it is evidence the
--  unit is not where its path thinks it is, and the answer is a replan.
--
--  One tile: enough to cover a source on a slope or a half-step, not enough to
--  cover a different floor.
local JUMP_LEVEL_TOLERANCE = 1.0

--  How close to a coming jump point the unit slows down, and to what.
--
--  moveJump only fires within 1.0 of its source. At walkSpeed 8 the script
--  advances the unit about 0.66 tiles per tick, so that window gets ONE sample,
--  maybe two, and the phase decides whether either lands inside it.
--
--  On flat ground a miss is recoverable -- walk back. AT A LEDGE IT IS NOT.
--  Measured: the unit walked off at full speed, the path advanced to the Jump
--  edge only after it was already airborne and 1.23 tiles from the takeoff
--  point, and it fell eight tiles.
--
--  3.0 gives about 0.25 tiles per tick, so the window gets three or four
--  samples instead of one. 2.5 tiles of run-in is enough to shed the speed
--  without making ordinary walking look sluggish -- it only applies with a jump
--  immediately ahead.
local JUMP_APPROACH_SLOWDOWN = 2.5
local JUMP_APPROACH_SPEED = 3.0

--  How far ahead to read the planned arc when working out how high the jump
--  actually has to go. Arcs run a few dozen sample edges; this only has to
--  outlast the longest of them.
local MAX_JUMP_LOOKAHEAD = 64

--  Launch a little harder than the arithmetic demands. Covers the discrete
--  integration loss between the continuous solution and the engine's stepped
--  one, which costs a few hundredths of a tile of apex.
local JUMP_VELOCITY_MARGIN = 1.02

--  Never launch harder than this multiple of the planned velocity. A path that
--  asks for something absurd is a broken path, and it should fail visibly
--  rather than fling the unit across the room.
local JUMP_VELOCITY_CAP = 1.25

--  NET DISPLACEMENT WATCHDOG.
--
--  The pathfinder's jump model is more optimistic than the movement
--  controller, so it will happily plan an arc the unit cannot complete. The
--  unit jumps, falls short, PathFinder:update trips its stuckTimer, re-plans,
--  and produces the identical arc -- forever.
--
--  Distance TRAVELLED cannot detect this, because jumping in place accumulates
--  plenty of it. Net displacement over a window can: a unit making real
--  progress moves away from where it was, a unit bouncing off a ledge does not.
local PROGRESS_WINDOW = 5.0
local PROGRESS_DISTANCE = 2.5
local PROGRESS_STRIKES = 2

--  How many vent hops one task may make.
--
--  Bounded because the routing is GREEDY: the unit picks the vent whose far
--  side lands nearest the target and tries it, with no knowledge of whether
--  that far side connects to anything useful. Without a bound it could hop
--  forever.
--  Raised from 2 for the same reason the loop breaker counts repeats rather
--  than hops: player-built space is assumed hostile to navigation, and vents
--  are the sanctioned way around that. A two-hop ceiling means a base whose
--  transport lane runs through four vents simply has no route.
--
--  THIS IS NOT A FREE CONSTANT. The BFS probes one edge per vent per expanded
--  node, and `visited` bounds nodes rather than depth -- so raising the ceiling
--  takes the cold-cache probe count from about 2*(V+1) to V^2. A reachable edge
--  resolves in well under a second; an unreachable one costs the full
--  PROBE_LIMIT. A measured 6-vent world cost 47s at depth 2, 32s of which was
--  four timeouts. The same world at depth 10 can approach TASK_DEADLINE, and a
--  twenty-vent base can exceed it by an order of magnitude.
--
--  Survivable ONLY because probe results are banked on the port and outlive the
--  task that paid for them. Still needs the port to tell a BUSY unit from a
--  STUCK one -- see the note on TASK_DEADLINE.
--  Tile damage dealt to harvest, matching the Harvester Beam mod's value.
--
--  DELIBERATELY TINY. The damage is not what harvests the crop -- reaching
--  FarmableObject::damageTiles at all is, since that override calls harvest()
--  for Beamish, Blockish and Plantish damage and consumes the damage when it
--  succeeds. The amount only matters in the FAILURE case, where the call falls
--  through to Object::damageTiles and becomes real damage to a crop that was
--  not ready.
local HARVEST_DAMAGE = 0.2

--  Harvest level 1. REQUIRED: it is what makes destroyed materials and mods
--  drop as items, and a harvest that drops nothing is indistinguishable from
--  one that never happened.
local HARVEST_LEVEL = 1

--  Is anything standing on this tile, or the one above it?
--
--  Exact rather than a bounding-box overlap. world.entityQuery returns anything
--  whose bounds INTERSECT the rect, and a rect drawn around a single tile
--  touches its neighbours -- which in a planted row means every tile reports
--  itself occupied by the crop next door. world.objectSpaces gives an object's
--  real occupied tiles, relative to its position, so the test can be honest.
--
--  Defined ABOVE its call sites deliberately: a local function called from a
--  line above its definition compiles as a nil global. That has already cost
--  one bricked update loop in this mod.
local seedSpacesCache = {}

local function seedSpaces(seedName)
	if seedName == nil then return { {0, 0}, {0, 1} } end
	if seedSpacesCache[seedName] ~= nil then return seedSpacesCache[seedName] end

	local spaces = nil
	local ok, config = pcall(root.itemConfig, seedName)

	if ok and type(config) == "table" and type(config.config) == "table" then
		local orientations = config.config.orientations

		if type(orientations) == "table" and type(orientations[1]) == "table"
		   and type(orientations[1].spaces) == "table"
		   and #orientations[1].spaces > 0 then
			spaces = orientations[1].spaces
		end
	end

	if spaces == nil then
		sb.logInfo("UNIT could not read spaces for %s -- assuming 1x2",
			tostring(seedName))
		spaces = { {0, 0}, {0, 1} }
	end

	seedSpacesCache[seedName] = spaces
	return spaces
end

--  Is anything standing where this crop would go?
--
--  Footprint comes from the SEED'S OWN CONFIG rather than an assumed 1x2 --
--  oculemon and pineapple are two tiles wide, and the old shape both missed
--  blockers in the column it never checked and failed to see a successfully
--  planted wide crop afterwards.
local function tileOccupied(anchor, seedName)
	local tiles = {}
	local lox, loy = anchor[1], anchor[2]
	local hix, hiy = lox, loy

	for _, space in ipairs(seedSpaces(seedName)) do
		local t = { anchor[1] + space[1], anchor[2] + space[2] }
		table.insert(tiles, t)

		lox = math.min(lox, t[1]); hix = math.max(hix, t[1])
		loy = math.min(loy, t[2]); hiy = math.max(hiy, t[2])
	end

	local candidates = world.entityQuery(
		{ lox - 1, loy - 1 }, { hix + 2, hiy + 2 },
		{ includedTypes = { "object" } })

	for _, id in ipairs(candidates or {}) do
		local spaces = world.objectSpaces(id)
		local origin = world.entityPosition(id)

		if spaces ~= nil and origin ~= nil then
			for _, space in ipairs(spaces) do
				local x = math.floor(origin[1]) + space[1]
				local y = math.floor(origin[2]) + space[2]

				for _, tile in ipairs(tiles) do
					if x == tile[1] and y == tile[2] then return true end
				end
			end
		end
	end

	return false
end

--  How high above the target tile the droplet is spawned.
--
--  Far enough that it is unambiguously falling onto the tile from outside it,
--  close enough that a grenade-physics projectile cannot drift into the next
--  tile along on the way down.
local WATER_DROP_HEIGHT = 1.0

--  How close the unit must be to a tile before watering it.
local WATER_REACH = 4.0

--  How close the unit has to be to poke an animal.
--
--  More generous than the crop reach because ANIMALS MOVE and nothing chases
--  them: the standable ground target is resolved once, so an animal that
--  ambled a couple of tiles during the approach should still be reachable
--  rather than failing outright. Small roving livestock may outwalk even this,
--  which is the measurement worth having before any catch-up behaviour is
--  designed.
local ANIMAL_REACH = 6.0

--  How close the unit has to be before it fires the harvest.
--
--  world.damageTiles ENFORCES NO RANGE -- it is a world call, and a unit could
--  harvest a crop across the room the moment its arrival test passed for some
--  other reason. This is a sanity bound rather than a game rule: if the unit
--  believes it has arrived but is nowhere near the crop, something upstream is
--  wrong and firing anyway would hide it.
local HARVEST_REACH = 4.0

--  How long to keep firing before giving up.
--
--  A harvest is not necessarily instant from the caller's side: the crop has to
--  still be there, still be ripe, and the engine has to accept the damage. The
--  budget is small because a harvest that is going to work works immediately.
local HARVEST_TIMEOUT = 3.0

local MAX_VENT_HOPS = 10

--  How long a single reachability probe may run before its answer is taken as
--  "no". Same reasoning as SEARCH_LIMIT.
--  An UNREACHABLE edge has to exhaust A*'s 70000-node allowance before it
--  reports false -- roughly nineteen seconds at EXPLORE_RATE. A reachable one
--  resolves in well under a second. So this only needs to be long enough to let
--  genuine successes through, and everything past it is a "no".
local PROBE_LIMIT = 8.0

--  How long a unit may make NO PROGRESS toward a chosen vent's mouth before
--  concluding the mouth is unreachable. Resets whenever the unit actually
--  moves, so distance costs nothing.
local VENT_APPROACH_TIMEOUT = 8.0

--  How far from the expected exit still counts as having arrived there.
--
--  Generous, because a vent exit is a standing position and a unit lands with
--  some slop. Tight enough to separate "landed at the exit I planned for" from
--  "landed at a different vent entirely" -- the observed failure put the unit
--  20 tiles from where the plan said it would be, so there is no ambiguity to
--  resolve here, only a sanity check to pass.
local VENT_ARRIVAL_TOLERANCE = 6.0

--  LOOP BREAKING IS ABOUT REPETITION, NOT VOLUME.
--
--  A hop budget is the wrong shape for this. These units run in spaces players
--  build, which must be assumed hostile to navigation -- automatic doors that
--  open and close, terrain that changes under them. Vents exist PRECISELY so a
--  player can route around pathfinding shortcomings, so a legitimately hard
--  journey may take many hops and several replans. Capping hops punishes the
--  intended use of the feature.
--
--  Distance to target is no better as a progress metric: a correct vent route
--  routinely moves a unit further away in a straight line before bringing it
--  closer, which is the whole point of a transport lane.
--
--  What a loop actually does, and a hard journey does not, is arrive at the
--  same place from the same vent over and over. Count that instead. This
--  follows the same doctrine as the vent approach timer above, which was
--  rewritten from a flat clock to a no-progress test for the same reason.
local MAX_REPEAT_HOPS = 4

--  Absolute backstop, deliberately far above anything a real journey needs.
--  Exists only so that a fault in the repetition test above cannot produce an
--  endlessly looping unit -- not as a budget anyone should ever reach.
--
--  DERIVED from the plan ceiling rather than fixed, so it cannot silently
--  become a real constraint when that ceiling moves.
local MAX_TASK_HOPS = MAX_VENT_HOPS * 12

--  Fallback radius, used only if the vent's occupied spaces cannot be read.
local VENT_USE_DISTANCE = 2.0

--  Decide whether a vent can rescue this task, probing if the answer is not yet
--  known. Returns "routing" (a leg was started), "probing" (still finding out),
--  or "none" (no vent reaches the target).
--
--  Probing costs a full A* search per unknown exit, but only ONCE per
--  destination tile -- terrain decides reachability, not the drop, so every
--  later target in the same neighbourhood is a table lookup.
--  FORWARD DECLARED, because tryVentRoute below calls it ~940 lines before it
--  is defined.
--
--  A `local function` is only in scope AFTER its definition. Called from above
--  it, the name resolves as a GLOBAL, that global is nil, and the call throws:
--
--    Exception while invoking lua function 'update'
--    attempt to call a nil value (global 'freshPather')
--      in upvalue 'tryVentRoute'
--
--  That kills update() outright. The unit stops running its state machine, the
--  port sees it going nowhere, and it eventually gets re-homed -- which reads
--  as a pathfinding failure and is not one.
--
--  It survived because tryVentRoute reaches this line only on ONE branch, the
--  one where the target is walkable and no hops are needed. Every other caller
--  of freshPather is below 1543.
--
--  THE DEFINITION BELOW MUST STAY AN ASSIGNMENT. Writing `local function
--  freshPather` there would declare a SECOND local that shadows this one, and
--  line 601 would go straight back to calling nil.
local freshPather

local function tryVentRoute(stateData, target)
  if petports_planRoute == nil then return "none" end

  --  RECALLS DO VENT-ROUTE. This used to refuse them outright, and the refusal
  --  is now wrong twice over.
  --
  --  The original reasoning: a walk home is not worth a route search, routing a
  --  recall cost 38 seconds of probing before failing, and worse, it filled the
  --  cache with t: keys for recall points CHOSEN AT RANDOM inside the rect,
  --  which would never be asked about again.
  --
  --  Both halves have since expired. returnWork now recalls to a FIXED point --
  --  findStandingPoint over a small box around the port, same answer every
  --  attempt -- so a recall produces ONE t: key per port rather than a new one
  --  per try. And route cache entries carry a TTL, so even a bad key ages out
  --  instead of accumulating.
  --
  --  What the refusal cost, meanwhile, was units that could not get home at
  --  all. A unit that vent-hopped somewhere to work, finished, and got recalled
  --  had no vent available for the return leg -- it went in one way and was
  --  only permitted to come back another. Inside an enclosure with vent-only
  --  access, that is permanent: the leash deliberately never fails, so the unit
  --  retries a walk that cannot succeed, forever, without ever reporting.
  --
  --  MEASURED: a unit idle at [1195.07,715.8], directly between vent 15 at
  --  [1195,721] and vent 17 at [1195,712], with no walking route home. It
  --  needed exactly the pair it had just used and was refused them.
  --
  --  Only reproducible with more than one unit deployed, which is the tell:
  --  a single unit takes every job and is never left idle deep in the network.

  if stateData.viaVent ~= nil then return "routing" end

  --  Already have a plan? Take the next leg.
  if stateData.plan ~= nil and stateData.planIndex <= #stateData.plan then
    stateData.viaVent = stateData.plan[stateData.planIndex]
    stateData.ventApproachTimer = VENT_APPROACH_TIMEOUT
    stateData.ventLastPosition = nil
    stateData.ventLegStarted = false
    stateData.searchingTimer = 0
    stateData.approachTimer = APPROACH_TIMEOUT
    stateData.groundTarget = nil
    sb.logInfo("UNIT leg %s of %s: vent %s exit %s",
      sb.printJson(stateData.planIndex), sb.printJson(#stateData.plan),
      sb.printJson(stateData.viaVent.id),
      sb.printJson(stateData.viaVent.destinationId))
    return "routing"
  end

  --  Allow a "just walk" answer once the unit has hopped at least once: it is
  --  standing somewhere it has not tried walking from.
  --  Freeze the origin for this planning session. Re-keying as the unit drifts
  --  throws away every probe done so far.
  --  PLAN FROM THE PORT, NOT FROM THE UNIT.
  --
  --  A port does not move, so its `u:` edges are computed ONCE and reused by
  --  every unit and every future task. Planning from the unit re-keys them
  --  whenever it drifts -- observed two consecutive tasks probing the identical
  --  five edges from adjacent positions, roughly forty
  --
  --  Slightly less accurate, since the unit is not always at its port. That is
  --  acceptable: the leash keeps it nearby, and a direct walk has already been
  --  tried and failed before routing is ever consulted.
  --
  --  After a hop the unit really is somewhere else, so planOrigin is cleared
  --  and the live position is used from there on.
  --  ALWAYS THE UNIT'S OWN POSITION. NEVER THE PORT'S.
  --
  --  This substituted the port's position for the unit's to make cached edges
  --  reusable across tasks, then substituted only when the two shared a cache
  --  bucket, which sounded safe and was not: a bucket was 16 tiles, wider than
  --  a room, so a caged unit and the port outside its wall keyed identically.
  --  Every probe ran from the port, every edge came back reachable, and the
  --  unit stood still for the whole approach timeout walking into stone.
  --
  --  Keys are tile-exact now, so the substitution would be visibly wrong rather
  --  than subtly wrong -- but it was never worth anything. A* has to start
  --  where the unit is. That is the entire requirement.
  --
  if stateData.planOrigin == nil then
    stateData.planOrigin = mcontroller.position()
  end

  local plan = petports_planRoute(target, MAX_VENT_HOPS,
    stateData.task.port, EXPLORE_RATE, stateData.ventHops > 0,
    stateData.planOrigin, stateData.triedVents)

  if plan == "probing" then
    stateData.probeTimer = (stateData.probeTimer or 0) + script.updateDt()
    if stateData.probeTimer < PROBE_LIMIT then return "probing" end

    sb.logInfo("UNIT probe exceeded PROBE_LIMIT %s, forcing a timeout",
      sb.printJson(PROBE_LIMIT))

    --  One probe has run too long. RECORD IT as unreachable so planning moves
    --  on -- cancelling without recording restarts the same probe forever.
    petports_probeTimeout(stateData.task.port)
    stateData.probeTimer = 0
    return "probing"
  end

  if plan == "walk" then
    --  Target is reachable on foot from here. Drop out of routing and let the
    --  normal approach run, with a clean pather so the failed search that got
    --  us into routing cannot linger.
    sb.logInfo("UNIT target walkable from here, no further hops needed")
    stateData.plan = nil
    stateData.planIndex = 1
    stateData.probeTimer = 0
    freshPather("target walkable from here, no further ho")
    return "walk"
  end

  if plan == nil then
    sb.logInfo("UNIT tryVentRoute: no plan available, giving up on vents")
    return "none"
  end

  stateData.plan = plan
  stateData.planIndex = 1
  stateData.probeTimer = 0
  sb.logInfo("UNIT planned %s-hop route to %s",
    sb.printJson(#plan), sb.printJson(target))

  --  Fall through on the next call, which takes leg 1.
  return "routing"
end

--  Is the unit OVERLAPPING the vent's occupied tiles?
--
--  A radius is the wrong test: too small and a unit that cannot quite reach the
--  mouth never enters, too large and it triggers while merely walking PAST a
--  vent on the way somewhere else. The vent's own footprint is the honest
--  answer, and `objectBounds` in pathutil.lua already builds it from
--  world.objectSpaces translated to the object's position.
function petportsTaskAction.touchingVent(ventId)
  local ok, ventRect = pcall(objectBounds, ventId)

  if not ok or type(ventRect) ~= "table" or type(ventRect[1]) ~= "number" then
    --  Could not read the footprint. Fall back to a tight radius rather than
    --  refusing to ever enter.
    return world.magnitude(mcontroller.position(), world.entityPosition(ventId))
      <= VENT_USE_DISTANCE
  end

  local me = rect.translate(mcontroller.boundBox(), mcontroller.position())

  return not (me[1] > ventRect[3] or me[3] < ventRect[1]
           or me[2] > ventRect[4] or me[4] < ventRect[2])
end

function petportsTaskAction.enterWith(args)
  local task = args.petportsTask
  if task == nil then return nil end
  if task.position == nil then return nil end

  --  Nothing to walk to.
  --
  --  REFUSING IS NOT FREE. The unit is already holding this assignment, and
  --  petBehavior re-queues a held task every tick -- so a refusal that leaves
  --  the assignment in place loops forever against a pickState that keeps
  --  failing, while the port waits in trackWork for a report that can never
  --  come. Total silence on both sides, and the port never dispatches anything
  --  again. Observed when a drop was picked up by the player between the port's
  --  sweep and the unit entering the state.
  --
  --  So: report and clear before refusing.
  if (task.type == "collect" or task.type == "harvest"
      or task.type == "animal")
     and not world.entityExists(task.target) then
    if task.port then
      world.sendEntityMessage(task.port, "petports_taskReport", {
        id = task.id,
        outcome = "failed",
        reason = "target was gone before the unit could start",
        unit = entity.uniqueId()
      })
    end
    self.petportsTask = nil
    return nil
  end

  if task.position == nil then
    if task.port then
      world.sendEntityMessage(task.port, "petports_taskReport", {
        id = task.id,
        outcome = "failed",
        reason = "task had no position",
        unit = entity.uniqueId()
      })
    end
    self.petportsTask = nil
    return nil
  end

  return {
    task = task,
    approachTimer = APPROACH_TIMEOUT,
    --  For "diag" this is the dwell; for "collect" and "harvest" it doubles as
    --  the retry budget once the unit has arrived.
    dwellTimer = task.dwell
      or ((task.type == "harvest") and HARVEST_TIMEOUT or 3.0),
    arrived = false,
    searchingTimer = 0,
    settleTimer = 0,

    --  Vent routing. viaVent is the vent currently being walked to, if any;
    --  triedVents stops one vent being chosen twice for the same task.
    viaVent = nil,
    ventLegStarted = false,
    planOrigin = nil,
    routing = false,
    routingTried = false,
    probeTimer = 0,
    plan = nil,
    planIndex = 1,
    progressTimer = 0,
    progressAnchor = nil,
    progressStrikes = 0,
    ventHops = 0,
    triedVents = {},
    hopSeen = {},

    --  Approach telemetry. A frozen unit and an unreachable target both look
    --  like a timeout from outside; movement delta separates them.
    startPosition = mcontroller.position(),
    lastPosition = mcontroller.position(),
    traceTimer = 1.0,
    movedTotal = 0
  }
end

--  VANILLA'S standingBoundBox INVERTS FOR NARROW BODIES.
--
--  PathMover:new defaults standingBoundBox to padBoundBox(-0.7, 0) -- the
--  normal bound box shrunk by 0.7 on EACH side, "thinner for standing and
--  landing". Our drone's collisionPoly is one tile wide:
--
--      boundBox         = [-0.5, -0.75, 0.5, 0.6]    width  1.0
--      standingBoundBox = [ 0.2, -0.75, -0.2, 0.6]   width -0.4
--
--  Left edge to the RIGHT of the right edge. Every landing and standing node is
--  validated against that rectangle, so no Jump, Arc or Drop edge can ever
--  terminate -- while Walk edges use the normal boundBox and are unaffected.
--  Hence: flat ground works perfectly, anything vertical never resolves, and
--  A* searches forever without reporting failure.
--
--  Vanilla pets are wider than a tile, so -0.7 leaves them a thin but VALID
--  box. Ours is exactly narrow enough to break it.
--
--  approachPoint does `self.pather = self.pather or PathMover:new(...)`, so
--  constructing the pather ourselves first makes vanilla use ours. Scale the
--  padding to the body instead of using a fixed 0.7 so it can never invert.
--  A SECOND, WORSE BUG: PathFinder:reset() DOES NOT CLEAR self.aStar.
--
--      function PathFinder:reset()
--        self.edges = {}
--        self.hasPath = false
--        self.currentEdgeIndex = 1
--      end
--
--  So once a search is abandoned before it resolves, the finder is permanently
--  poisoned. On the next task, update() sees the new target is more than 2 away
--  and calls reset() -- which clears the path but leaves aStar alive. find()
--  then checks `not self.hasPath and not self.aStar`, sees a live aStar, and
--  SKIPS the reset-and-start entirely. It returns explore(), which keeps
--  grinding the OLD search toward the OLD target forever.
--
--  Observed exactly: the first task after a world load succeeds, then one
--  unreachable target poisons the pather and every subsequent task fails --
--  including trivially reachable ones on flat ground.
--
--  The pather is cheap to build and there is one task at a time, so build a
--  FRESH one per task rather than trying to unpick vanilla's state.
--  REPLACEMENT FOR PathMover:moveWalk
--
--  Vanilla walks at full speed right up to the moment the next edge takes over.
--  That is fine when every mover can pick up from wherever the walk left the
--  unit, and moveJump cannot -- it has a hard 1.0 radius and no way to recover
--  from being outside it.
--
--  So this does one thing: SLOW DOWN WHEN A JUMP IS NEXT. Everything else is
--  vanilla's, called directly through the class table so there is no copy of it
--  to maintain.
--
--  Speed is set on pather.controlParameters, which PathMover:move rebuilds
--  BEFORE edgeMove and applies AFTER it -- so a change made here lands on the
--  same tick.
function petportsWalkMover(pather)
  local finder = pather.finder
  local ahead = finder ~= nil and finder.lookAhead and finder:lookAhead(1) or nil

  if ahead ~= nil and ahead.action == "Jump"
     and ahead.source ~= nil and ahead.source.position ~= nil then

    local gap = world.magnitude(mcontroller.position(), ahead.source.position)

    if gap <= JUMP_APPROACH_SLOWDOWN then
      pather.controlParameters.walkSpeed = JUMP_APPROACH_SPEED
      pather.controlParameters.runSpeed = JUMP_APPROACH_SPEED

      if not pather.petportsSlowingForJump then
        pather.petportsSlowingForJump = true
        sb.logInfo("UNIT slowing to %s for jump point %s (gap %s)",
          sb.printJson(JUMP_APPROACH_SPEED),
          sb.printJson(ahead.source.position), sb.printJson(gap))
      end
    end
  else
    pather.petportsSlowingForJump = nil
  end

  return PathMover.moveWalk(pather)
end

--  REPLACEMENT FOR PathMover:moveJump
--
--  WHAT VANILLA DOES, IN FULL:
--
--      if world.magnitude(mcontroller.position(),
--                         self.edge.source.position) < 1.0 then
--        ... snap to the source, pause 0.2s, launch, advance ...
--      end
--      return "running"
--
--  Outside that radius the function does NOTHING -- no movement, no advance, no
--  report -- and there is no code anywhere that walks the unit to its own jump
--  point. It relies entirely on the approach happening to end inside a one-tile
--  circle.
--
--  WHY THAT FAILS AT SPEED. The Jump edge only becomes current AFTER the unit
--  crosses the source, so the usable half of the window is one tile wide. At
--  walkSpeed 8 the script advances the unit about 0.66 tiles per step, so there
--  are one or two chances to land inside it and the phase decides whether any
--  do. Measured: the unit coasted to a dead stop 1.19 tiles past the jump point,
--  replanned, walked back, overshot by 1.21 the other way, and oscillated
--  between [1208.81] and [1211.21] indefinitely. It gets worse as speed rises,
--  which is exactly backwards for a unit that should move with purpose.
--
--  THE FIX IS THE MISSING ELSE. Outside the radius, walk toward the source.
--  Overshooting stops being terminal and becomes self-correcting, and the whole
--  thing stops depending on approach speed.
--
--  The takeoff path is vanilla's, deliberately unchanged: the snap to
--  source.position is what makes the flown arc match the planned one, the 0.2s
--  jumpTimer pause is what the arc is computed from, and the friction zeroing is
--  what keeps the ascent ballistic. This is an added branch, not a rewrite.
--
--  THE RADIUS IS STILL 1.0. Widening it would be the obvious way to catch a
--  fast approach, but the body of this function TELEPORTS the unit to the jump
--  point -- a larger radius means a longer snap, and a long enough snap puts the
--  unit through a wall. Walking is slower and cannot do that.
--
--  NOTE THE PARAMETER NAME. edgeMove calls this as self:moveJump(), so the
--  pather arrives as the first argument -- but inside THIS file `self` is the
--  monster's script table, which is a completely different thing. pathing.lua
--  flags the same collision in its own comment above setMoved(). Everything
--  below goes through `pather`; `self` is never the pather here.
--  THE HIGHEST POINT THE PLANNED ARC GOES TO.
--
--  Reads forward from the Jump edge through its Arc edges and includes the
--  first non-Arc edge, which is the Land the arc is aimed at. That last one
--  matters: the Land target IS the surface the unit has to get on top of, and
--  it usually sits slightly above the final Arc waypoint.
local function plannedApex(pather)
  local finder = pather.finder
  local edges = finder and finder.edges
  local index = finder and finder.currentEdgeIndex
  if edges == nil or index == nil then return nil end

  local highest = nil

  for i = index + 1, math.min(index + MAX_JUMP_LOOKAHEAD, #edges) do
    local edge = edges[i]
    if edge == nil then break end

    if edge.target ~= nil and edge.target.position ~= nil then
      local y = edge.target.position[2]
      if highest == nil or y > highest then highest = y end
    end

    if edge.action ~= "Arc" then break end
  end

  return highest
end

--  LAUNCH HARD ENOUGH TO REACH WHAT THE PLAN ASKS FOR.
--
--  The planner over-estimates how high this unit jumps. Measured across the
--  four takeoffs of one chute run, sorted by the rise each one needs:
--
--      704.375 -> 711.375   7.0 tiles   ok
--      711.375 -> 719.375   8.0 tiles   ok
--      719.375 -> 728.375   9.0 tiles   FAILS
--
--  Physics allows 45^2 / (2 * 120) = 8.4375. The planner emitted a jump needing
--  9.0, which means it is solving with g near 112.5 against a world running
--  120. The unit apexed at 728.125, a quarter tile under the ledge, hit the
--  vertical face of it -- x velocity went from -12 to -0.003 in one tick -- and
--  dropped three tiles.
--
--  SCALING jumpSpeed DOES NOT FIX THIS. Planner and movement controller both
--  read airJumpProfile.jumpSpeed, so lowering it shrinks both and the
--  percentage error survives; every jump just fails at a proportionally lower
--  ledge.
--
--  So instead of arguing with the planner about physics, satisfy its answer:
--  work out the velocity that genuinely reaches the arc's highest planned point
--  and launch with that.
--
--  IT ONLY EVER RAISES, NEVER LOWERS, and only when the plan demands more than
--  the nominal jump delivers. The 8.0-tile jump needs 43.8 and keeps its 45
--  unchanged; the 9.0-tile one needs 46.5 and gets it. So arcs that already
--  worked are untouched, which is the property that matters -- launching WEAKER
--  than planned is what produced ceiling collisions earlier, and this cannot do
--  that.
local function launchVelocity(pather, edge, source)
  local planned = edge.jumpVelocity[2]

  local apex = plannedApex(pather)
  if apex == nil then return planned, nil end

  local rise = apex - source[2]
  if rise <= 0 then return planned, nil end

  local parameters = mcontroller.baseParameters()
  local gravity = world.gravity(source) * (parameters.gravityMultiplier or 1.0)
  if gravity <= 0 then return planned, nil end

  local needed = math.sqrt(2 * gravity * rise) * JUMP_VELOCITY_MARGIN
  if needed <= planned then return planned, nil end

  local capped = math.min(needed, planned * JUMP_VELOCITY_CAP)
  return capped, { rise = rise, gravity = gravity, needed = needed, apex = apex }
end

--  REPLACEMENT timedDrop AND keepDropping.
--
--  Vanilla's pair has two separate faults and they compound, so both are
--  replaced together. Neither is patched globally -- these are assigned to the
--  pather INSTANCE in freshPather, so PathMover.timedDrop stays reachable and
--  no other entity in the world is affected.
--
--  FAULT ONE, /scripts/pathing.lua PathMover:timedDrop:
--
--      function PathMover:timedDrop(time)
--        if holdTime == nil then holdTime = 0 end
--        holdTime = math.min(holdTime, 0.5)
--        mcontroller.controlDown()
--        self.downHoldTimer = holdTime
--      end
--
--  The parameter is `time`; the body uses `holdTime`, which is declared
--  nowhere and is therefore an undeclared GLOBAL. The argument is ignored
--  entirely, the global is nil on the first call so it becomes 0, and
--  math.min(0, 0.5) is 0 -- so downHoldTimer is 0 on every drop the entity
--  ever makes. moveDrop computes math.max(timeToFall(-delta[2]), 0.05) and
--  hands over a perfectly good fall time that nothing reads.
--
--  FAULT TWO, PathMover:keepDropping: it calls controlDown() and THEN tests
--  onGround(). On the tick the unit lands on the platform below, down has
--  already been pressed for that tick, so it falls through that one too and
--  the timer clears one platform late. Invisible when platforms are far apart
--  -- the unit is still airborne when the timer expires -- and very visible
--  when a player stacks them to fake a ladder, which is exactly where this was
--  observed: drop, land, hesitate, drop again, overshoot, jump back, repeat.
--
--  THE OBVIOUS FIX FOR FAULT TWO RE-BREAKS DROPPING. Testing onGround() before
--  pressing down cancels on the FIRST tick, because the unit is still standing
--  on the platform it is trying to fall through when moveDrop fires. So the
--  hold has to survive until the unit has actually left: dropOrigin records the
--  y at drop start, and onGround only counts once the unit is meaningfully
--  below it. That works whether the physics settles in one tick or three,
--  which matters because it is not known which.
--  MEASURED: vanilla's moveDrop asks for math.max(timeToFall(-delta[2]), 0.05),
--  which came out at 0.158s for a one-tile platform drop -- so this cap is not
--  a formality, it CLAMPS ordinary drops. 0.5 was vanilla's own intended
--  ceiling and is far longer than anything here needs.
--
--  THIS IS NOW A BACKSTOP, NOT THE RELEASE. See DROP FLOOR below.
--
--  A WALL CLOCK CANNOT EXPRESS "ONE PLATFORM", AND THE LOG PROVES IT.
--  Measured on a stack of platforms two tiles apart, dropping from 712.8 with
--  a target of 711.8:
--
--    52.161  y 712.8    hold 0.1 armed
--    52.254  y 712.303  v -11.97  descended 0.50  -- keepDropping presses down
--    52.352  y 710.972  v -21.97  descended 1.83  -- presses down AGAIN
--    52.412  y 708.808  v -31.97  two platforms past the target, path LOST
--
--  The tick rate in that session was 0.082s median across 120 samples -- 12.2
--  FPS, not 60. Every constant in this file that is expressed in SECONDS was
--  reasoned about at a tick five times shorter than the one the game actually
--  ran. 0.1s is "roughly six ticks" at 60Hz and exactly TWO here, and the
--  second of those two lands on the tick where the unit sits 0.17 above the
--  platform it was aiming for. Down is held, it passes through, and it is now
--  falling at 22 tiles per second with nothing left to catch it.
--
--  Lowering the number does not fix this and 0.034 would not have either: any
--  positive hold survives at least one keepDropping call, and one call at 12
--  FPS is worth 1.3 tiles of fall. Below one tick the hold stops working at
--  60Hz instead. There is no value that is correct at both frame rates.
--
--  DROP_DESCENT_EPSILON cannot rescue it either. That guard needs to SEE the
--  unit grounded, and between takeoff and the overshoot the unit is sampled at
--  712.303, 710.972 and 708.808 -- it is never observed touching a platform,
--  because it covers more than a tile per tick.
--
--  So 0.5 here is deliberately loose: vanilla's own intended ceiling, kept only
--  to bound a drop whose floor test never resolves. The floor test below is
--  what actually ends every ordinary drop.
local DROP_HOLD_MAX = 0.5

--  RELEASE AT THE PLAN'S OWN TARGET, WHICH IS FRAME-RATE INDEPENDENT.
--
--  The Drop edge already states where the drop ends: origin minus the descent
--  in pather.delta IS the edge's target y. Recording it at arming turns the
--  release into a position test, which does not care how long a tick is.
--
--  Replaying the trace above against it: floor is 712.8 - 1 = 711.8.
--
--    y 712.303  above the floor  -> press, correct, still inside the platform
--    y 710.972  below the floor  -> RELEASE
--
--  and the step out of 710.972 then collides with the platform at 710.8 the
--  way it was always meant to.
--
--  IT HANDLES MULTI-TILE DROPS CORRECTLY, which a fixed clearance distance
--  would not. The 3-tile Drop edge in the same log runs 714.8 -> 711.8 and is
--  MEANT to pass through the platforms at 712.8 on the way; the floor says so,
--  a "release after 0.75 tiles" rule would have caught it on the first one.
--
--  The margin is slack for a unit that lands fractionally high. Small, because
--  overshooting the floor by a margin is exactly the failure being fixed.
local DROP_FLOOR_MARGIN = 0.05

--  How far below the drop point the unit must be before a landing is believed.
--  A platform is one tile, so anything well under 1 works; this is deliberately
--  small so the guard releases as early as it safely can.
local DROP_DESCENT_EPSILON = 0.35

--  A Drop edge that does not actually descend is not a drop, and pressing down
--  for one is how a unit falls through the floor it is standing on.
--
--  MEASURED, and this is the whole of the reproduced bug. A unit fell further
--  than its plan expected -- an Arc overshot and the Land put it at y 723.8 --
--  and the pather then executed the NEXT edge from the plan regardless:
--
--    post-move at [1207,723.8]: action Drop edge 4 of 26 src [1207,726.8] srcDist 3
--    drop hold 0.05 from y 723.8
--
--  The edge's SOURCE was three tiles above where the unit actually was. It had
--  already fallen past that node. Its target was level with the unit -- vanilla
--  asked for max(timeToFall(-delta[2]), 0.05) and got the 0.05 FLOOR, meaning
--  the descent was about a tenth of a tile. Pressing down there passed the unit
--  through the platform it had just landed on, and the loop that produced
--  repeated on a six-second cycle.
--
--  So: if the next node is not meaningfully below us, consume the edge and do
--  not touch the controls. advancePath still runs in moveDrop, so the plan
--  moves on -- which is correct, because the unit is already past that node.
local MIN_DROP_DISTANCE = 0.5

--  WHY THERE IS NO PER-EDGE ARMING GUARD HERE.
--
--  An earlier pass added one, on the theory that moveDrop runs every tick the
--  Drop edge is current and re-arms downHoldTimer on each of them, so
--  keepDropping's landing release was being undone the same tick it fired.
--
--  THAT THEORY IS FALSE, and vanilla's own source says so. PathMover:moveDrop
--  calls timedDrop and then calls advancePath UNCONDITIONALLY, in the same
--  call. The Drop edge is consumed the tick it becomes current, so timedDrop
--  already runs exactly once per Drop edge. There is nothing to de-duplicate.
--
--  The guard was not merely inert. It keyed on currentEdgeIndex, which is
--  per-path and restarts at 1 on every replan -- so a fresh path whose Drop
--  edge happened to land on a previously-used index would have its drop
--  silently refused, and the unit would stand on the platform forever. That is
--  the inverse failure the handoff warns about, introduced by the fix for a
--  bug that was not there.
--
--  If over-dropping shows up again, the numbers to look at are DROP_HOLD_MAX
--  and MIN_DROP_DISTANCE, and the line to grep is "UNIT drop hold" -- one per
--  Drop edge. Two of those lines for the same edge index would be evidence for
--  the re-arming theory. There have never been two.

--  WHAT IS ACTUALLY UNDER THE UNIT. GROUND TRUTH, NOT INFERENCE.
--
--  Two drops in the same log, same x, same landing surface, opposite outcomes:
--  released at y 710.917 moving -31.53 and was caught, released at y 710.972
--  moving -21.97 and went through. Closer and faster survived; further and
--  slower did not. No model built on position and velocity separates those,
--  which means the assumption underneath -- that the surfaces are where the
--  grounded y-values in the log say they are -- is the thing to stop assuming.
--
--  So ask the world instead. Scans the column under the unit's own footprint
--  and reports each occupied row as P (platform) or B (solid), so the next log
--  says where the collision actually is rather than where a standing position
--  implies it was.
--
--  The x span is the collisionPoly's, via boundBox, because a platform that
--  only covers part of the footprint is one of the shapes that would explain
--  the pair above.
local DROP_PROBE_DEPTH = 6

--  Tile rows and surfaces: a platform tile at row N collides at y = N + 1, and
--  a unit standing on it rests with its feet at N + 1. Confirmed by probe --
--  the stack in the test world reads P713 P711 P709 P707 P705 and the unit
--  stands at 714.8, 712.8, 710.8, 708.8, 706.8.
local PROBE_EPSILON = 0.001

--  IS THERE STILL A PLATFORM TO GET THROUGH?
--
--  A drop presses down for exactly one reason: to pass a platform the plan
--  wants it below. The plan states how far in the Drop edge's descent, so any
--  platform whose surface sits ABOVE the floor is one to pass, and any platform
--  at or below the floor is one to land on. Pressing down near the second kind
--  is the whole bug.
--
--  MEASURED, four drops, same geometry, released above the same platform at
--  row 709 (surface 710.0):
--
--    feet 710.609  v -29.53   1.24 engine ticks to contact   caught
--    feet 706.862  v -17.53   2.95 engine ticks              caught
--    feet 710.244  v -21.53   0.68 engine ticks              through
--    feet 710.172  v -21.97   0.47 engine ticks              through
--
--  About one engine tick of down survives the script's decision to stop. Which
--  mechanism produces that is still not established -- a single stale tick and
--  a whole stale block each explain three of these four and not the fourth --
--  so this deliberately does NOT try to time the release. It removes the
--  reason to press instead: once no unpassed platform remains, down is not
--  wanted on any tick, stale or otherwise, and the window cannot open.
--
--  Returns the surface y of the highest platform still to be passed, or nil.
local function platformToPass(position, floorFeet)
  local bounds = mcontroller.boundBox()
  local feet = position[2] + bounds[2]

  --  Rows whose surface is at or below the FEET, working downward.
  --
  --  floor, not ceil. A dry run of this against the four logged drops caught
  --  ceil admitting the row directly above the feet: at feet 711.503 it
  --  returned surface 712, which the unit was already half a tile below and had
  --  therefore already passed. That would have kept down pressed for exactly
  --  the tick that has to be quiet, reproducing the bug through the fix.
  local first = math.floor(feet + PROBE_EPSILON) - 1

  for row = first, first - DROP_PROBE_DEPTH, -1 do
    local surface = row + 1

    --  At or below the floor: this is a landing surface, not one to pass.
    --  Everything further down is lower still, so stop.
    if surface <= floorFeet + PROBE_EPSILON then break end

    local region = { position[1] + bounds[1], row,
                     position[1] + bounds[3], row + 1 }

    if world.rectTileCollision(region, {"Platform"}) then
      return surface
    end
  end

  return nil
end

local function probeBelow(position)
  local bounds = mcontroller.boundBox()
  local rows = {}

  local feet = position[2] + bounds[2]

  for step = 0, DROP_PROBE_DEPTH do
    local row = math.floor(feet) - step
    local region = { position[1] + bounds[1], row,
                     position[1] + bounds[3], row + 1 }

    if world.rectTileCollision(region, {"Platform"}) then
      table.insert(rows, "P" .. tostring(row))
    elseif world.rectTileCollision(region, {"Null", "Block", "Dynamic"}) then
      table.insert(rows, "B" .. tostring(row))
    end
  end

  if #rows == 0 then return "nothing within " .. tostring(DROP_PROBE_DEPTH) end
  return table.concat(rows, " ")
end

--  HOW FAR BELOW A PLATFORM SURFACE TO PLACE THE FEET.
--
--  Two pixels. Starbound is 8 pixels to the tile, so 0.25 -- far enough that
--  the feet are unambiguously below the surface and no rounding puts them back
--  on top of it, small enough that the placement is not visible as a jump.
local DROP_SCOOT = 0.25

--  THE LOWEST PLATFORM THIS DROP IS MEANT TO GET THROUGH.
--
--  platformToPass answers "is there one left"; this answers "where does the
--  passing end", which is what a placement needs. Same rule: a platform above
--  the floor is one to pass, at or below the floor is one to land on.
local function lastPlatformToPass(position, floorFeet)
  local bounds = mcontroller.boundBox()
  local feet = position[2] + bounds[2]
  local lowest = nil

  for row = math.floor(feet + PROBE_EPSILON) - 1, math.floor(feet) - DROP_PROBE_DEPTH, -1 do
    local surface = row + 1
    if surface <= floorFeet + PROBE_EPSILON then break end

    local region = { position[1] + bounds[1], row,
                     position[1] + bounds[3], row + 1 }

    if world.rectTileCollision(region, {"Platform"}) then
      lowest = surface
    end
  end

  return lowest
end

--  Would the unit be inside something solid if its feet were placed here?
--  Platforms are excluded deliberately -- being inside one is the entire point.
local function bodyFitsWithFeetAt(position, feet)
  local bounds = mcontroller.boundBox()
  local centre = feet - bounds[2]
  local region = { position[1] + bounds[1], centre + bounds[2],
                   position[1] + bounds[3], centre + bounds[4] }

  return not world.rectTileCollision(region, {"Null", "Block", "Dynamic"})
end

--  PLACE THE UNIT THROUGH THE PLATFORM INSTEAD OF ASKING THE CONTROLLER TO.
--
--  MEASURED, build 24e, and this is why controlDown was abandoned entirely.
--  The release fired exactly where the dry run said it would, after a SINGLE
--  arming press and nothing after it:
--
--    27.732  arm      feet 712.000  toPass 712   press
--    27.802  release  feet 711.503  toPass nil
--
--  and the unit still passed surface 712 AND surface 710 before landing on
--  708. One press carries it through two platforms. controlDown is not a
--  per-tick gate on platform collision; it starts a fall-through state whose
--  duration is not observable from script. So no hold length can be correct --
--  not 0.5, not 0.1, not 0.034, not "until nothing is left to pass". Three
--  rewrites of the release condition were all solving a problem that was never
--  about the release.
--
--  A placement has none of that. The feet end up below the surface, the unit is
--  through, gravity does the rest, and no engine state is left running. Both
--  vanilla movers this file already replaces do the same thing: moveJump calls
--  setPosition(source), moveDrop calls setPosition on the x axis.
--
--  FAILS CLOSED. If the destination is inside something solid, or no platform
--  needs passing, nothing is placed and the drop is skipped rather than
--  guessed at -- a unit that does not drop stalls visibly and replans, which is
--  recoverable. A unit placed inside terrain is not.
local function scootThroughPlatform(pather, floorFeet)
  local position = mcontroller.position()
  local surface = lastPlatformToPass(position, floorFeet)

  if surface == nil then
    return false, "no platform above the floor to pass"
  end

  local feet = surface - DROP_SCOOT

  if not bodyFitsWithFeetAt(position, feet) then
    return false, "solid tiles at feet " .. sb.printJson(feet)
  end

  local was = position[2]
  mcontroller.setPosition({ position[1], feet - mcontroller.boundBox()[2] })

  return true, string.format("%s -> %s (through surface %s)",
    sb.printJson(was), sb.printJson(mcontroller.position()[2]),
    sb.printJson(surface))
end

function petportsTimedDrop(pather, time)
  local delta = pather.delta
  local descent = (delta ~= nil and delta[2] ~= nil) and -delta[2] or 0

  if descent < MIN_DROP_DISTANCE then
    --  Explicitly cleared rather than left alone: a stale timer from an earlier
    --  drop would otherwise keep keepDropping pressing on this edge too.
    pather.downHoldTimer = nil
    pather.petportsDropOrigin = nil
    pather.petportsDropFloor = nil
    pather.petportsDropFloorFeet = nil

    sb.logInfo("UNIT drop SKIPPED at y %s: next node is %s below (delta %s) "
      .. "-- already past it, not pressing down",
      sb.printJson(mcontroller.position()[2]), sb.printJson(descent),
      sb.printJson(delta))
    return
  end

  local floorFeet = mcontroller.position()[2] - descent + mcontroller.boundBox()[2]

  --  PLACEMENT FIRST. controlDown is only reached if the placement refuses.
  local scooted, why = scootThroughPlatform(pather, floorFeet)

  if scooted then
    --  downHoldTimer deliberately left nil. PathMover:move early-returns for
    --  the whole of a hold -- no finder update, no edgeMove, no controlParameters
    --  -- so leaving it set would blind the pather for a drop that is already
    --  finished. Nothing to keep dropping.
    pather.downHoldTimer = nil
    pather.petportsDropOrigin = nil
    pather.petportsDropFloor = nil
    pather.petportsDropFloorFeet = nil

    sb.logInfo("UNIT drop SCOOTED %s for a %s tile descent", why,
      sb.printJson(descent))
    return
  end

  sb.logInfo("UNIT drop scoot refused (%s) -- falling back to controlDown", why)

  --  The argument vanilla throws away.
  pather.downHoldTimer = math.min(time or 0, DROP_HOLD_MAX)
  pather.petportsDropOrigin = mcontroller.position()[2]

  --  Where the edge says this drop ends. keepDropping releases here.
  pather.petportsDropFloor = pather.petportsDropOrigin - descent

  --  The same line expressed at the feet, which is what tile surfaces are
  --  measured against.
  pather.petportsDropFloorFeet =
    pather.petportsDropFloor + mcontroller.boundBox()[2]

  mcontroller.controlDown()

  local here = mcontroller.position()

  sb.logInfo("UNIT drop hold %s from y %s to floor %s (a %s tile descent) "
    .. "| feet %s | below: %s",
    sb.printJson(pather.downHoldTimer),
    sb.printJson(pather.petportsDropOrigin),
    sb.printJson(pather.petportsDropFloor), sb.printJson(descent),
    sb.printJson(here[2] + mcontroller.boundBox()[2]),
    probeBelow(here))
end

local function releaseDrop(pather)
  pather.downHoldTimer = nil
  pather.petportsDropOrigin = nil
  pather.petportsDropFloor = nil
  pather.petportsDropFloorFeet = nil
end

function petportsKeepDropping(pather, dt)
  if pather.downHoldTimer == nil then return end

  local y = mcontroller.position()[2]
  local origin = pather.petportsDropOrigin or y
  local floor = pather.petportsDropFloor

  --  AT OR BELOW THE PLAN'S TARGET. The drop is over regardless of what the
  --  clock says, and regardless of whether the unit has touched anything --
  --  at a long tick it will not have. Checked FIRST because it is the only one
  --  of the three tests that holds at any frame rate.
  --  EVERY HELD TICK, not just the release. The interesting question is what
  --  the unit passed while down was held, and that is only answerable if each
  --  tick says where it was and what was under it.
  if TASK_DEBUG then
    sb.logInfo("UNIT drop tick y %s feet %s v %s timer %s floor %s | below: %s",
      sb.printJson(y),
      sb.printJson(y + mcontroller.boundBox()[2]),
      sb.printJson(mcontroller.velocity()[2]),
      sb.printJson(pather.downHoldTimer),
      tostring(floor),
      probeBelow(mcontroller.position()))

    sb.logInfo("UNIT drop tick toPass %s (floorFeet %s)",
      tostring(pather.petportsDropFloorFeet ~= nil
        and platformToPass(mcontroller.position(), pather.petportsDropFloorFeet)),
      tostring(pather.petportsDropFloorFeet))
  end

  --  NOTHING LEFT TO PASS. Checked before the floor, because it is the reason
  --  the floor test existed and it is exact where the floor test was a proxy.
  local floorFeet = pather.petportsDropFloorFeet
  if floorFeet ~= nil then
    local pass = platformToPass(mcontroller.position(), floorFeet)

    if pass == nil then
      sb.logInfo("UNIT drop done passing at y %s feet %s (fell %s, floor %s) "
        .. "-- no platform above the floor left, releasing down",
        sb.printJson(y), sb.printJson(y + mcontroller.boundBox()[2]),
        sb.printJson(origin - y), tostring(floor))

      releaseDrop(pather)
      return
    end
  end

  --  Retained as a backstop for a drop with no floorFeet recorded, and for a
  --  plan whose descent runs past every platform the probe can see.
  if floor ~= nil and y <= floor + DROP_FLOOR_MARGIN then
    sb.logInfo("UNIT drop reached floor %s at y %s (fell %s) -- floor backstop, "
      .. "the platform test should have released first",
      sb.printJson(floor), sb.printJson(y), sb.printJson(origin - y))

    releaseDrop(pather)
    return
  end

  --  CHECKED BEFORE THE PRESS, NOT AFTER. This is fault two. Still worth
  --  keeping: it catches a drop that lands EARLY, on something the plan did
  --  not know about, before the floor is reached.
  if (origin - y) >= DROP_DESCENT_EPSILON and mcontroller.onGround() then
    if TASK_DEBUG then
      sb.logInfo("UNIT drop landed short at y %s (fell %s, floor was %s), releasing down",
        sb.printJson(y), sb.printJson(origin - y), tostring(floor))
    end

    releaseDrop(pather)
    return
  end

  mcontroller.controlDown()

  pather.downHoldTimer = pather.downHoldTimer - dt
  if pather.downHoldTimer <= 0 then
    sb.logInfo("UNIT drop hold EXPIRED at y %s (fell %s, floor %s) -- backstop fired, "
      .. "the floor test should have released first",
      sb.printJson(y), sb.printJson(origin - y), tostring(floor))

    releaseDrop(pather)
  end
end

function petportsJumpMover(pather)
  --  Vanilla's first guard, unchanged. moveArc sets jumpCooldown to 0.3 on
  --  every airborne tick, so without this a unit landing out of an arc would
  --  immediately launch again.
  if mcontroller.onGround() and pather.jumpCooldown then
    return "running"
  end

  local edge = pather.edge
  if edge == nil or edge.source == nil or edge.source.position == nil then
    return "running"
  end

  local source = edge.source.position
  local gap = world.magnitude(mcontroller.position(), source)

  if gap >= JUMP_TAKEOFF_REACH then
    --  THE BRANCH VANILLA IS MISSING.
    --
    --  Only on the ground: airborne on a Jump edge means something else has
    --  gone wrong, and adding thrust to it would make the landing worse rather
    --  than better.
    if mcontroller.onGround() then
      local toSource = source[1] - mcontroller.position()[1]
      local levelGap = math.abs(source[2] - mcontroller.position()[2])

      --  ON A DIFFERENT LEVEL: DO NOT WALK.
      --
      --  Measured failure, and it was this branch that caused it. A unit stood
      --  at [1214.88,711.875] with its jump source at [1215,707.875] -- four
      --  tiles BELOW. The horizontal offset was 0.12, which cleared the epsilon
      --  below, so this issued controlMove toward 1215, overshot to 1215.13,
      --  reversed, overshot to 1214.88, and did that indefinitely.
      --
      --  THE OSCILLATION DEFEATED THE STALL DETECTOR, which is why it never
      --  recovered on its own: the unit was displacing a quarter tile per
      --  cycle, so stuckAnchor kept updating and airborneEdgeStall kept
      --  resetting. A unit that paces looks livelier than one that is wedged
      --  and is in fact worse off.
      --
      --  Standing still is the correct behaviour here. The grounded-stall check
      --  in update() then fires within 0.35s and replans from where the unit
      --  actually is, which is the only thing that can help.
      if levelGap > JUMP_LEVEL_TOLERANCE then
        if not pather.petportsWrongLevel then
          pather.petportsWrongLevel = true
          sb.logInfo("UNIT jump source %s is %s tiles off our level (at %s) -- not walkable, waiting for replan",
            sb.printJson(source), sb.printJson(levelGap),
            sb.printJson(mcontroller.position()))
        end

        return "running"
      end

      pather.petportsWrongLevel = nil

      --  Directly above or below, so no amount of walking closes the gap. Leave
      --  it: the unit will stand still, and the grounded-stall check in
      --  update() replans within 0.35s. Walking an arbitrary direction here
      --  would just wander off the path.
      if math.abs(toSource) >= JUMP_APPROACH_EPSILON then
        mcontroller.controlMove(toSource > 0 and 1 or -1, false)

        if not pather.petportsWalkingToJump then
          pather.petportsWalkingToJump = true
          sb.logInfo("UNIT walking back to jump point %s from %s (gap %s)",
            sb.printJson(source), sb.printJson(mcontroller.position()),
            sb.printJson(gap))
        end
      end
    end

    return "running"
  end

  pather.petportsWalkingToJump = nil
  pather.petportsWrongLevel = nil

  --  Everything from here down is vanilla's takeoff, unmodified.
  if not pather.jumpTimer then
    pather.jumpTimer = 0.2
    mcontroller.setPosition(source)
    mcontroller.setVelocity({0, 0})

    sb.logInfo("UNIT takeoff from %s, jumpVel %s (approached to %s)",
      sb.printJson(source), sb.printJson(edge.jumpVelocity), sb.printJson(gap))
  end

  pather.deltaX = edge.jumpVelocity[1]

  if mcontroller.liquidMovement() or pather.jumpTimer <= 0 then
    pather.controlParameters.airFriction = 0
    pather.controlParameters.liquidFriction = 0
    pather.controlParameters.liquidImpedance = 0
    pather.controlParameters.groundFriction = 0

    local vy, correction = launchVelocity(pather, edge, source)

    if correction ~= nil then
      sb.logInfo("UNIT jump under-powered by the plan: needs %s tiles of rise, planned %s gives %s, launching at %s (g %s, capped %s)",
        sb.printJson(correction.rise), sb.printJson(edge.jumpVelocity[2]),
        sb.printJson((edge.jumpVelocity[2] * edge.jumpVelocity[2]) / (2 * correction.gravity)),
        sb.printJson(vy), sb.printJson(correction.gravity),
        tostring(vy < correction.needed))
    end

    mcontroller.setVelocity({edge.jumpVelocity[1], vy})
    pather.jumpTimer = nil
    pather:advancePath()
  else
    pather.jumpTimer = pather.jumpTimer - script.updateDt()
  end

  return "running"
end

freshPather = function(why)
  local options = petports_pathOptions()
  options.run = false

  --  ALWAYS LOGGED, not behind TASK_DEBUG. A pather rebuilt every tick and a
  --  pather rebuilt once look identical from every other line in the log: the
  --  search restarts, reports success, and restarts again. Naming the caller
  --  is what separates "the search is slow" from "something is throwing the
  --  answer away".
  self.petportsPatherBuilds = (self.petportsPatherBuilds or 0) + 1
  sb.logInfo("UNIT freshPather #%s at %s: %s",
    sb.printJson(self.petportsPatherBuilds),
    sb.printJson(mcontroller.position()),
    tostring(why or "no reason given"))

  if TASK_DEBUG then
    sb.logInfo("UNIT pather boundBox %s standingBoundBox %s",
      sb.printJson(options.boundBox), sb.printJson(options.standingBoundBox))
  end

  --  SAME OPTIONS THE PROBE USES. A probe that searches with different options
  --  than the real walk does not predict it, and its answers are cached.
  self.pather = PathMover:new({
    run = false,
    pathOptions = options
  })

  self.pather.finder.exploreRate = function() return EXPLORE_RATE end

  --  REPLACEMENT moveJump. See the header on petportsJumpMover below.
  --
  --  Assigned to the INSTANCE, so it shadows PathMover.moveJump through the
  --  metatable for this pather only. Vanilla's version stays reachable as
  --  PathMover.moveJump, no other entity is affected, and nothing is patched
  --  globally. Same technique as the exploreRate override above.
  self.pather.moveJump = petportsJumpMover
  self.pather.moveWalk = petportsWalkMover

  --  Vanilla's moveDrop itself is fine and is left alone -- the x snap to
  --  nextPathPosition, setXVelocity(0) and advancePath all do the right thing.
  --  Only the two functions it leans on are broken. See petportsTimedDrop.
  self.pather.timedDrop = petportsTimedDrop
  self.pather.keepDropping = petportsKeepDropping
end

function petportsTaskAction.enteringState(stateData)
  --  First entry only. See BUILD_STAMP for why this is not at file scope.
  if not stampLogged then
    stampLogged = true
    sb.logInfo("PETPORTS taskAction build: %s", BUILD_STAMP)
  end

  sb.logInfo("UNIT entering task state for %s at %s",
    tostring(stateData.task.id), sb.printJson(mcontroller.position()))

  --  Before any approachPoint call, so vanilla picks up ours rather than
  --  building its own with the inverted box -- and fresh, so no abandoned A*
  --  search carries over from a previous task.
  freshPather("entering task state for")

  --  No emote here. This called emote("happy") on every pickup, which at one
  --  task per five seconds is a permanent affection loop -- precisely the
  --  attention-seeking pet this design exists to be the opposite of. Any
  --  acknowledgement of a new task belongs on a cooldown, or nowhere.
end

--  Report the outcome to the petport and drop the assignment.
--
--  Reported by uniqueId, not entity id: the port's entity id is not stable
--  across a reload and the unit may well have respawned since the task was
--  issued.
--  `cargo` is an item descriptor the unit is handing over, or nil. Only a
--  successful pickup passes one.
local function report(stateData, outcome, reason, cargo)
  local task = stateData.task

  sb.logInfo("UNIT reporting %s for %s: %s (ended at %s, target %s, hops %s, moved %s)",
    tostring(outcome), tostring(task.id), tostring(reason),
    sb.printJson(mcontroller.position()), sb.printJson(task.position),
    sb.printJson(stateData.ventHops or 0), sb.printJson(stateData.movedTotal or 0))

  if task.port then
    world.sendEntityMessage(task.port, "petports_taskReport", {
      id = task.id,
      outcome = outcome,
      reason = reason,
      cargo = cargo,
      --  How many tiles a watering sweep actually wetted. The port spends one
      --  item per tile from this number rather than from the tile list it
      --  handed out, so a sweep that ended early is not charged for tiles it
      --  never reached.
      watered = task.watered,
      unit = entity.uniqueId()
    })
  end

  --  CLEAR ONLY THE TASK THIS REPORT IS ABOUT.
  --
  --  This used to nil self.petportsTask unconditionally. That is correct while
  --  the only tasks are dispatched ones, and destructive the moment a leash
  --  task exists: finishing or abandoning a leash would silently throw away a
  --  real task the port had assigned in the meantime, and the port would then
  --  sit in trackWork waiting for a report on work the unit no longer knew it
  --  had.
  --
  --  Otherwise unchanged: a unit holding a task the port has forgotten would
  --  re-assert it every tick forever, so its own task still goes.
  if self.petportsTask ~= nil and task ~= nil
     and self.petportsTask.id == task.id then
    self.petportsTask = nil
  end
end

--  Resolve a raw world position to somewhere a ground unit can actually stand.
--
--  THE GATE IS validStandingPosition, from /scripts/pathing.lua:
--
--      if self.options.mustEndOnGround
--         and not validStandingPosition(targetPosition, false) then return false end
--
--  and mustEndOnGround defaults to mcontroller.baseParameters().gravityEnabled,
--  which is true for a ground unit. So a target that is not a valid standing
--  position is never pathfound AT ALL -- find() returns false before any search
--  runs, every tick, and the unit neither moves nor arrives. That reads as a
--  frozen unit and burns the whole approach timeout.
--
--  The diagnostic task never hit this because its targets came from the port's
--  findStandingPoint and were valid by construction. An item drop's position is
--  where the ITEM rests, which is not where a unit can stand.
--
--  Vanilla's pathfinder DOES handle jumps, drops and arcs -- this is not a
--  missing traversal capability, it is an invalid destination.

--  findGroundPosition(position, minHeight, maxHeight, avoidLiquid,
--                     collisionSet, bounds)
--
--  minHeight and maxHeight have NO DEFAULTS. pathutil.lua line 35 does
--  math.max(math.abs(minHeight), math.abs(maxHeight)), so calling it with one
--  argument always errors -- "bad argument #1 to 'abs' (number expected, got
--  nil)". The error surfaces through pcall as a STRING in the result slot, not
--  as a thrown error, so a caller that only checks for nil will happily index a
--  string and crash somewhere else entirely.
--
--  It already does the search by hand-rolling would duplicate: it walks up and
--  down from the given position testing validStandingPosition at each step, and
--  aligns feet to the tile row below via
--  math.ceil(position[2]) - (bounds[2] % 1).
local GROUND_SEARCH_DOWN = -6
local GROUND_SEARCH_UP = 4

--  Column offsets to try, nearest first.
local COLUMN_SEARCH = { 0, 1, -1, 2, -2, 3, -3 }

--  Somewhere a ground unit can stand, near a drop.
--
--  Per COLUMN rather than per point: x is snapped to a tile centre because a
--  unit's boundBox is about a tile wide and centred, so an integer x straddles
--  two columns and only passes where both are clear. findGroundPosition then
--  supplies the y.
--  `searchUp` overrides how far above `position` a standing spot may be taken
--  from. Pass 0 to forbid climbing -- see the homeward bias in
--  approachTargetFor for why that is sometimes required.
local function standableNear(position, searchUp)
  if searchUp == nil then searchUp = GROUND_SEARCH_UP end

  for _, offset in ipairs(COLUMN_SEARCH) do
    local x = math.floor(position[1] + offset) + 0.5

    local ok, resolved = pcall(findGroundPosition,
      {x, position[2]}, GROUND_SEARCH_DOWN, searchUp, false)

    --  Guard the SHAPE, not just nil-ness: pcall returns the error message in
    --  this slot on failure, and a string indexes without complaint.
    local usable = ok
      and type(resolved) == "table"
      and type(resolved[1]) == "number"
      and type(resolved[2]) == "number"

    if usable then
      if TASK_DEBUG then
        sb.logInfo("UNIT standable for %s -> %s (column offset %s)",
          sb.printJson(position), sb.printJson(resolved), sb.printJson(offset))
      end
      return { resolved[1], resolved[2] }
    end

    if TASK_DEBUG and not ok then
      sb.logInfo("UNIT findGroundPosition failed at x %s: %s",
        sb.printJson(x), tostring(resolved))
    end
  end

  if TASK_DEBUG then
    sb.logInfo("UNIT no standable column near %s", sb.printJson(position))
  end
  return nil
end

--  Where the unit should be heading right now.
--
--  For "collect" this is the drop's CURRENT position, not the one the task was
--  issued with. Returns nil if the drop is gone.
local function currentTarget(task)
  --  A watering task's destination MOVES as the sweep advances. The index
  --  lives on the task rather than on stateData because currentTarget is only
  --  handed the task -- and the task table is this unit's own copy, so
  --  mutating it is local.
  if task.type == "water" then
    local tile = task.tiles ~= nil and task.tiles[task.waterIndex or 1] or nil
    if tile == nil then return nil end

    --  Stand ON the soil tile, which is one below the crop's anchor.
    return { tile[1] + 0.5, tile[2] + 1.5 }
  end

  --  "animal" resolves live for the same reason "collect" does, and more so:
  --  a farm animal wanders while the unit walks to it, so the position it was
  --  dispatched against is stale on arrival.
  if task.type ~= "collect" and task.type ~= "harvest"
     and task.type ~= "animal" then
    return task.position
  end

  if not world.entityExists(task.target) then return nil end
  return world.entityPosition(task.target)
end

--  Cached so the resolve runs once per task rather than once per tick.
--  Cached once RESOLVED. Until then it is recomputed every tick, because a
--  falling drop's position changes and an early resolve would be wrong.
--  HOME IS BENEATH THE PORT, NOT ON TOP OF IT.
--
--  findGroundPosition tests UP BEFORE DOWN at every step of its search:
--
--      for y = 0, max(abs(minHeight), abs(maxHeight)) do
--        if y <= maxHeight and validStandingPosition({x, pos[2] + y}) then break end
--        if -y >= minHeight and validStandingPosition({x, pos[2] - y}) then break end
--      end
--
--  so with GROUND_SEARCH_UP at 4 a standable spot ABOVE the target beats one
--  below it at the same distance, and it will climb four tiles to find one. A
--  port under a shelter has a perfectly good roof, and the roof wins.
--
--  Measured: port at [1203,728] resolved to [1203.5,731.875] -- 3.875 tiles up,
--  on top of its own shelter -- while the floor immediately beneath it was
--  fine. The unit then leashes to the roof, and every recall sends it there.
--
--  So a homeward task forbids climbing outright. Down-only first; the normal
--  search is kept as a fallback so a port with genuinely no floor beneath it
--  still resolves to something rather than nothing.
--
--  Applies to "return" -- both the unit's own leash and the port's recall use
--  that type, and both mean "come back to your port".
local function approachTargetFor(stateData, rawPosition)
  if stateData.groundTarget ~= nil then return stateData.groundTarget end

  local task = stateData.task
  local homeward = task ~= nil and task.type == "return"

  if homeward then
    stateData.groundTarget = standableNear(rawPosition, 0)

    if stateData.groundTarget == nil then
      sb.logInfo("UNIT no floor beneath %s -- falling back to an unbiased search",
        sb.printJson(rawPosition))
      stateData.groundTarget = standableNear(rawPosition)
    end
  else
    stateData.groundTarget = standableNear(rawPosition)
  end

  return stateData.groundTarget
end

function petportsTaskAction.update(dt, stateData)
  local task = stateData.task

  --  HAND THE STATE BACK WHEN REAL WORK ARRIVES.
  --
  --  A leash task is not dispatched work: it is not in self.petportsTask, it
  --  holds no claim, and nothing is owed a report for it. So the unit can be
  --  carrying one out at the exact moment the port assigns a real task -- which
  --  is the ordinary case for a tethered unit, since it is walking home most of
  --  the time it is not working.
  --
  --  petBehavior CANNOT preempt this from its side. Its pick loop skips any
  --  action whose state is already the running one, and a real task and a leash
  --  task are both "petportsTaskAction" -- so the higher score is computed,
  --  compared, and then discarded. Leaving voluntarily is the only way the swap
  --  can happen at all.
  --
  --  Returning true WITHOUT reporting: the leash was never dispatched, and
  --  reporting it would be reporting work nobody asked for.
  if task.port == nil and self.petportsTask ~= nil then
    sb.logInfo("UNIT leaving station-keeping: task %s was dispatched",
      tostring(self.petportsTask.id))
    return true
  end

  --  PUMP THE THINKING INDICATOR HERE, NOT FROM petBehavior.run().
  --
  --  run()'s cadence is NOT verified. Vanilla groundPet.lua may only call it on
  --  the querySurroundings cooldown, which is 1s in the monstertype -- that
  --  would feed a per-tick dt once a second and stretch every timer inside the
  --  pump by roughly twelve. Observed as a forced spinner that would not expire.
  --
  --  This update IS verified per-tick with a real dt: traceTimer counts down by
  --  it and produces exactly one line per second. Use the hook with evidence
  --  behind it.
  --
  --  Scoping the pump to a task costs nothing, because thinking only ever
  --  happens inside one. Pings raised later in this same call are consumed on
  --  the NEXT tick; the grace window absorbs that.
  petports_thinkPump(dt)

  --  VANILLA DISCARDS THE PATH ON EVERY JUMP. THIS IS THE FIX.
  --
  --  /scripts/pathing.lua, PathFinder:update:
  --
  --      if self.hasPath and self.stuckTimer > 0.5 then
  --        self:reset()
  --      end
  --      self.stuckTimer = self.stuckTimer + script.updateDt()
  --
  --  and stuckTimer is zeroed in exactly ONE place, further down the same
  --  function: when currentEdgeIndex changes. So the timer does not measure
  --  being stuck, it measures TIME SPENT ON ONE EDGE -- and any edge lasting
  --  more than half a second destroys the whole path.
  --
  --  Walk edges are a tile long and advance constantly, so flat ground never
  --  trips it. Arc and Land do: moveArc's airborne branch applies velocity and
  --  does not advancePath until passedTarget comes true, and moveLand waits for
  --  onGround. Both are airborne waits, and any jump worth planning is longer
  --  than 0.5s. moveArc's run-up branch has the same shape on the ground.
  --
  --  It then compounds, which is why the symptom is a multi-second freeze
  --  rather than a stutter. PathFinder:canPathfind() is
  --
  --      return mcontroller.onGround() or not gravityEnabled
  --
  --  so find() refuses to start a search while airborne. The path is discarded
  --  MID-FLIGHT, nothing can replace it until the unit lands, the arc finishes
  --  ballistically with nothing steering it, and only then does a cold A* run.
  --  Measured at 3.9s of a motionless unit, having landed short of the arc.
  --
  --  THE FIX IS TO CORRECT THE PREDICATE, NOT THE TIMEOUT. Raising 0.5 to some
  --  larger number just moves the threshold; the timer would still be measuring
  --  the wrong thing, and a genuinely wedged unit would take proportionally
  --  longer to recover. Stuck means NOT MOVING, so measure that: zero the timer
  --  whenever the unit has actually displaced, and let it run when it has not.
  --
  --  Vanilla's reset still fires for a unit that truly cannot move -- which is
  --  the case the timer was put there for, and the only one it now catches.
  --
  --  Done here rather than by overriding PathFinder:update, which would mean
  --  carrying a copy of vanilla's function and re-checking it against every
  --  Starbound release.
  --  A GROUNDED UNIT ON AN AIRBORNE EDGE THAT IS NOT MOVING. VANILLA CANNOT TELL.
  --
  --  PathFinder:update invalidates a path when the TARGET moves more than two
  --  tiles, and never when the UNIT does. Nothing anywhere checks whether the
  --  unit is still standing where the plan says it is.
  --
  --  PRE-MOVE SAMPLE. THE STATE THE MOVERS ACTUALLY SEE.
  --
  --  The `pathing at` line further down runs AFTER approachPoint, so everything
  --  it reports is POST-move -- the state a mover saw on a given tick is the
  --  PREVIOUS line's end state. That is not a detail: it made a srcDist of 0.52
  --  look like a takeoff that should have happened, when moveJump never ran at
  --  that position at all. The two lines together bracket the mover, so a value
  --  can be attributed to the tick that actually used it.
  local preFinder = self.pather and self.pather.finder
  if preFinder ~= nil and preFinder.hasPath then
    local preEdge = preFinder.edges and preFinder.currentEdgeIndex
      and preFinder.edges[preFinder.currentEdgeIndex]
    local preSource = preEdge and preEdge.source and preEdge.source.position

    --  THE DESTINATION, NOT JUST THE DISTANCE FROM THE SOURCE.
    --
    --  srcDist alone cannot tell a unit that is BLOCKED from one whose edge
    --  destination is somewhere it will never satisfy -- both read as a frozen
    --  number. Measured, on a leash walk home across an open platform:
    --
    --    pre-move at [1202.8,706.8]: action Walk edge 5 of 6
    --      srcDist 1.79626 velocity [0,-1.53333] onGround true
    --
    --  sixty times, unchanged, x-velocity decayed to exactly zero. With no
    --  destination in the line there is no way to see whether the unit had
    --  already passed it, was short of it, or was aiming at a point off the
    --  platform entirely.
    --
    --  dstDist and dx are both here on purpose: the magnitude says how far, the
    --  signed x says which SIDE, and "already past it" is the case a walker can
    --  stall on without anything looking wrong.
    local preDest = preEdge and preEdge.target and preEdge.target.position
    local here = mcontroller.position()

    sb.logInfo("UNIT pre-move at %s: action %s edge %s of %s srcDist %s dst %s "
      .. "dstDist %s dx %s velocity %s onGround %s",
      sb.printJson(here),
      tostring(preEdge and preEdge.action),
      tostring(preFinder.currentEdgeIndex),
      tostring(preFinder.edges and #preFinder.edges),
      sb.printJson(preSource and world.magnitude(here, preSource)),
      sb.printJson(preDest),
      sb.printJson(preDest and world.magnitude(here, preDest)),
      sb.printJson(preDest and (preDest[1] - here[1])),
      sb.printJson(mcontroller.velocity()),
      tostring(mcontroller.onGround()))
  end

  --  AN ARC WAYPOINT THE UNIT CANNOT REACH. SKIP IT.
  --
  --  The planner over-estimates jump height. Measured on a straight-up hop:
  --
  --    takeoff                        711.375
  --    planner's last arc waypoint    720.723   (9.348 tiles of rise)
  --    physics, 45^2 / (2 * 120)                 8.438
  --    observed apex                  720.125   (8.750)
  --
  --  So the final waypoint of an arc sits about 7% higher than the unit can
  --  actually get. That is the "PathFinder's jump model is more optimistic than
  --  the movement controller" problem, with a number on it.
  --
  --  It deadlocks because NEITHER AXIS CAN ADVANCE THE PATH:
  --
  --    passedTargetOnAxis(edge, 2)  the unit never reaches the target y, so
  --                                 edgeDistance and targetDistance keep the
  --                                 same sign and the product is never negative
  --    passedTargetOnAxis(edge, 1)  a vertical arc has edgeDistance[1] == 0,
  --                                 which the function's own `~= 0` guard
  --                                 rejects outright
  --
  --  and moveArc calls controlApproachXVelocity(velocity[1], groundForce) with
  --  velocity[1] = 0, actively braking x to zero -- so the unit cannot drift
  --  sideways into passing it either. It rises, stops short, falls back to
  --  exactly where it took off, lands still holding the same edge, and moveArc's
  --  grounded branch then computes arcDelta = delta[1] = 0 and issues moveX(0)
  --  forever.
  --
  --  Nudging the unit does not help: the `~= 0` guard is on the EDGE's own
  --  geometry, not on where the unit is standing.
  --
  --  ONCE THE UNIT IS FALLING, ANY WAYPOINT STILL ABOVE IT IS UNREACHABLE.
  --  Gravity is one-directional and there is no second jump mid-arc. So it is
  --  safe to declare those edges passed and move on, which is what vanilla's
  --  own advance does -- this only supplies the test it is missing. Descending
  --  arcs put their waypoints BELOW the unit, so the loop breaks immediately
  --  and normal flight is untouched.
  --
  --  Deliberately not a fix to the 7% over-estimate. That lives inside
  --  world.platformerPathStart, and shrinking planned jumps to compensate is
  --  how the smallJumpMultiplier mess started.
  --  GROUNDED COUNTS TOO, AND THAT WAS THE HOLE.
  --
  --  The gate above was `not onGround() and falling`, which stops skipping at
  --  the exact moment the leftover waypoints become permanently unreachable:
  --  touchdown. Measured, on a stack of platforms:
  --
  --    [1210.11,712.8]  onGround TRUE   Arc edge 12   dst [1210.56,713.839]
  --    [1210.54,712.8]  velocity 8.13   still Arc edge 12
  --    [1211.49,712.8]  velocity 11.8   -> Land edge 14, already passed
  --    [1212.48,712.303] onGround FALSE -- off the platform edge, falling
  --
  --  The unit landed a tile BELOW an arc waypoint it was still holding. Being
  --  grounded, moveArc's grounded branch takes over, and that branch
  --  repositions HORIZONTALLY ONLY -- so it set off toward the waypoint's x
  --  across a 0.45 tile gap, accelerated to full run speed doing it, blew past
  --  that node AND the Land node behind it, and ran off the platform. Eight
  --  tiles down, grounded far from an airborne edge, stall detector fires,
  --  replan, mirrored arc from the other side, forever.
  --
  --  A waypoint above a GROUNDED unit is exactly as unreachable as one above a
  --  falling unit -- more so, since the unit is now standing on something. The
  --  original reasoning applies unchanged; the predicate was just too narrow.
  --
  --  Still excluded: rising. A unit on its way up has not reached its apex and
  --  its waypoints are legitimately ahead of it.
  local arcFinder = self.pather and self.pather.finder

  local arcSkippable = false
  if arcFinder ~= nil and arcFinder.hasPath then
    if mcontroller.onGround() then
      --  Landed. Whatever is left of the arc is over, whether the plan agrees
      --  or not.
      arcSkippable = true
    elseif mcontroller.velocity()[2] < 0 then
      --  Airborne and descending: the original case.
      arcSkippable = true
    end
  end

  if arcSkippable then
    local skipped = 0

    while skipped < MAX_ARC_SKIP do
      local index = arcFinder.currentEdgeIndex
      local edges = arcFinder.edges
      if index == nil or edges == nil or index > #edges then break end

      local edge = edges[index]
      if edge == nil or edge.action ~= "Arc" then break end
      if edge.target == nil or edge.target.position == nil then break end

      --  Still below us: this is the ordinary descending half of the arc.
      if edge.target.position[2] <= mcontroller.position()[2] then break end

      arcFinder:advance()
      skipped = skipped + 1
    end

    if skipped > 0 then
      sb.logInfo("UNIT skipped %s unreachable arc waypoint(s) while %s from %s -- now on edge %s of %s",
        sb.printJson(skipped),
        mcontroller.onGround() and "GROUNDED" or "falling",
        sb.printJson(mcontroller.position()),
        tostring(arcFinder.currentEdgeIndex),
        tostring(arcFinder.edges and #arcFinder.edges))
    end
  end

  --  THREE STALLS MEASURED, THREE DIFFERENT MOVERS, ONE SHAPE:
  --
  --    Jump  src [1215,713.75]   srcDist 4.03   moveJump does nothing outside
  --                                             1.0 of its source, and contains
  --                                             no code to walk there
  --    Land  src [1214,711.75]   srcDist 4.58   moveLand is four lines with no
  --                                             else -- if abs(delta[1]) >= 1
  --                                             it neither advances nor moves
  --    Arc   src [1215,716.25]   srcDist 0.50   moveArc grounded repositions
  --                                             HORIZONTALLY only, and a
  --                                             vertical arc has delta[1] = 0,
  --                                             so it issues moveX(0) forever
  --
  --  DISTANCE DOES NOT DISCRIMINATE -- 4.58, 4.03 and 0.50 all stall dead. What
  --  they share is that the unit is ON THE GROUND, the current edge is an
  --  AIRBORNE one, and it is NOT MOVING. That is the predicate.
  --
  --  An earlier version of this checked Jump edges against a 1.0 distance gate,
  --  which caught one of the three and read as a fix for all of them.
  --
  --  False positives are covered: a legitimate run-up along the ground toward an
  --  arc IS moving, and moveJump's deliberate 0.2s pre-takeoff pause is excluded
  --  both by jumpTimer below and by AIRBORNE_EDGE_STALL being longer than it.
  --
  --  This does not repair the movers -- it cannot, short of overriding them --
  --  and vanilla's stuck timer would eventually reset anyway. What it buys is a
  --  NAMED failure with the edge, the action and the gap in it, instead of an
  --  anonymous path drop, so the spots that produce unexecutable edges can be
  --  catalogued rather than rediscovered.
  local pathFinder = self.pather and self.pather.finder
  local stalledEdge = nil
  local stalledLimit = AIRBORNE_EDGE_STALL

  --  NOT WHILE ROUTING. Once stateData.routing is set, update() returns from
  --  the routing branch below and approachPoint is never called -- so the
  --  pather is not being driven at all. The unit is then grounded and motionless
  --  for a reason that has nothing to do with the edge it happens to be parked
  --  on, and every check below would read that as a mover dead-end.
  --
  --  Observed: after APPROACH_TIMEOUT handed over to vent routing, this fired on
  --  a Land edge at srcDist 0.5 -- a gap moveLand accepts perfectly well -- and
  --  reset a path that was never the problem.
  if pathFinder ~= nil and pathFinder.hasPath and mcontroller.onGround()
     and not stateData.routing and self.pather.jumpTimer == nil then
    local edge = pathFinder.edges and pathFinder.currentEdgeIndex
      and pathFinder.edges[pathFinder.currentEdgeIndex]

    if edge ~= nil and (edge.action == "Jump" or edge.action == "Arc"
                        or edge.action == "Land") then
      stalledEdge = edge

    --  A GROUNDED WALK THAT HAS STOPPED ADVANCING, WHICH NOTHING WATCHED.
    --
    --  Walk was excluded here on the reasoning that a grounded run-up toward an
    --  arc must not read as a stall. True, and handled elsewhere: the
    --  stuckAnchor check below zeroes this the moment the unit moves more than
    --  STUCK_MOVE, so anything actually walking never accumulates.
    --
    --  What was left uncovered is a walk that is going nowhere. Measured on a
    --  leash home across an OPEN PLATFORM -- so not blocked by anything:
    --
    --    pre-move at [1202.8,706.8]: action Walk edge 5 of 6
    --      srcDist 1.79626 velocity [0,-1.53333] onGround true
    --
    --  for seven seconds and sixty frames, x-velocity decayed to exactly zero,
    --  srcDist frozen, no replan and no path LOST. Vanilla's stuckTimer should
    --  have reset the path after half a second on one edge and did not, for
    --  reasons the log does not show. The unit had to be resocketed by hand.
    --
    --  LONGER THAN THE AIRBORNE LIMIT, and not by a little. 0.35s is tuned for
    --  a unit hanging mid-arc; a walker can legitimately be motionless for a
    --  moment against a step or while the controller reverses direction, and
    --  replanning on that would thrash a path that was about to work. Over a
    --  second of a grounded walk going nowhere is never legitimate.
    elseif edge ~= nil and edge.action == "Walk" then
      stalledEdge = edge
      stalledLimit = WALK_EDGE_STALL
    end
  end

  if stalledEdge == nil then
    stateData.airborneEdgeStall = 0
  else
    stateData.airborneEdgeStall = (stateData.airborneEdgeStall or 0) + dt

    if stateData.airborneEdgeStall >= stalledLimit then
      local source = stalledEdge.source and stalledEdge.source.position
      local dest = stalledEdge.target and stalledEdge.target.position
      local here = mcontroller.position()

      sb.logInfo("UNIT stalled on %s edge %s of %s: grounded and motionless at %s, edge source %s srcDist %s dst %s dstDist %s -- replanning",
        tostring(stalledEdge.action),
        tostring(pathFinder.currentEdgeIndex),
        tostring(pathFinder.edges and #pathFinder.edges),
        sb.printJson(here),
        sb.printJson(source),
        sb.printJson(source and world.magnitude(here, source)),
        sb.printJson(dest),
        sb.printJson(dest and world.magnitude(here, dest)))

      --  reset() clears edges and hasPath but leaves aStar alone; find() starts
      --  a fresh search next tick, and the unit is grounded so canPathfind()
      --  will allow it.
      pathFinder:reset()
      stateData.stuckAnchor = nil
      stateData.airborneEdgeStall = 0
    end
  end

  if pathFinder ~= nil and pathFinder.hasPath then
    local here = mcontroller.position()

    if stateData.stuckAnchor == nil
       or world.magnitude(here, stateData.stuckAnchor) > STUCK_MOVE then
      stateData.stuckAnchor = here
      pathFinder.stuckTimer = 0

      --  Moving, so whatever edge it is on is being executed. This is what
      --  keeps a grounded run-up toward an arc from reading as a stall.
      stateData.airborneEdgeStall = 0
    end
  else
    --  No path: the anchor belongs to a path that no longer exists, and keeping
    --  it would let the first tick of the NEXT path inherit a stale reference
    --  point and skip its own reset.
    stateData.stuckAnchor = nil
  end

  --  Every tick: world.debug* draws per-frame.
  if petports_drawRouteDebug ~= nil then petports_drawRouteDebug(stateData) end

  --  Re-read every tick. A drop that fell off a ledge mid-walk moves.
  local target = currentTarget(task)
  if target == nil then
    --  A CROP THAT VANISHES AFTER WE SWUNG AT IT IS A HARVEST, NOT A LOSS.
    --
    --  This is the ordinary success path for any crop without resetToStage,
    --  and it arrives here rather than in the act branch below because the
    --  engine does not remove the entity within the tick that harvested it.
    --  MEASURED: swing at 19:01:52.088 read the crop as present and unchanged;
    --  81ms later it was gone and its two drops were on the ground. Checking
    --  in the same tick reports every successful harvest as a failure.
    if task.type == "harvest" and stateData.swung then
      report(stateData, "done",
        "harvested " .. sb.printJson(task.target)
        .. " at " .. sb.printJson(task.position) .. " (crop consumed)")
      return true
    end

    --  Despawned, or someone got there first. Not a failure worth alarm --
    --  drops expiring is the normal case this task was chosen to exercise, and
    --  a player harvesting their own crop is the equivalent for farming.
    report(stateData, "failed",
      (task.type == "harvest") and "crop is gone before the swing"
        or "drop is gone")
    return true
  end
  task.position = target

  --  THE ROUTER AND THE WALKER MUST AIM AT THE SAME POINT.
  --
  --  approachPoint resolves a raw target to standable ground internally, so the
  --  direct walk was aiming at the resolved spot while tryVentRoute was handed
  --  the RAW one. That is invisible on flat floor, where the two coincide.
  --
  --  On a slope they do not. Measured with a drop resting at
  --  [1224.71,718.789]:
  --
  --    standableNear      resolved it to [1224.5,718.875]
  --    the direct A*      searched toward [1224.5,718.875] -- fine, just slow
  --    every vent probe   ran toward [1224.71,718.789] and was refused:
  --                       "not a valid standing position"
  --
  --  So the direct walk timed out on a hard route, handed over to vents, and
  --  vent routing then rejected the target outright at every single vent --
  --  planRoute EXHAUSTED, task failed, unit never moved. The drop was reachable
  --  the whole time; only the coordinate handed to the router was wrong.
  --
  --  Resolved HERE rather than at the two call sites, so a third caller cannot
  --  reintroduce the split. approachTargetFor caches once the drop has settled,
  --  and falls back to the raw target while it is still falling or when nothing
  --  standable is near -- the settle grace below owns that case.
  local routeTarget = approachTargetFor(stateData, target) or target

  --  Routing mode: probing exits, or waiting for one to be chosen. Runs every
  --  tick so a probe actually makes progress.
  if stateData.routing and stateData.viaVent == nil then
    local routing = tryVentRoute(stateData, routeTarget)

    if routing == "walk" then
      stateData.routing = false
      return false
    end

    if routing == "none" and task.hold then
      --  STALE PREMISE, KEPT DELIBERATELY. This used to read "station-keeping
      --  never vent-routes, so reaching here means only that the direct walk is
      --  hard" -- true when recalls were refused a route outright. They are not
      --  any more, so reaching here now means something stronger: vents were
      --  offered, considered, and none of them helped.
      --
      --  The behaviour is unchanged and still correct -- there is nowhere else
      --  for a tethered unit to be, so it keeps walking -- but a unit landing
      --  here repeatedly is now genuinely unreachable rather than merely
      --  unrouted, and that is worth noticing in a log rather than reading as
      --  the ordinary case.
      sb.logInfo("UNIT station-keeping: no vent route home either, retrying the walk")
      stateData.routing = false
      stateData.searchingTimer = 0
      stateData.approachTimer = APPROACH_TIMEOUT
      freshPather("station-keeping: no route offered, retry")
      return false
    end

    if routing == "none" then
      stateData.routing = false
      report(stateData, "failed",
        "no vent route to " .. sb.printJson(target)
        .. " (hops used " .. sb.printJson(stateData.ventHops) .. ")")
      return true
    end

    --  "probing" or "routing" -- either way, stand still and continue next
    --  tick. A unit walking while its route is undecided just wanders.
    --
    --  This is THE case the indicator exists for: a cold cache spends a full
    --  PROBE_LIMIT per unknown edge, and a five-edge plan is the better part of
    --  a minute of a unit standing perfectly still.
    if stateData.viaVent == nil then
      petports_think("routing")
      return false
    end
  end

  --  A vent leg replaces the destination until the unit is through it.
  if stateData.viaVent ~= nil then
    --  NEAR ENOUGH IS ENOUGH.
    --
    --  A vent is a hole in a wall. Its alcove often has no walkable entrance at
    --  all, so demanding the unit PATH INTO it is asking for something that
    --  cannot happen -- observed a unit standing directly beside a vent while
    --  the pathfinder reported no route to it, because there is no route, only
    --  adjacency.
    --
    --  Using the vent is a proximity test, not an arrival test.
    if petportsTaskAction.touchingVent(stateData.viaVent.id) then
      local ventId = stateData.viaVent.id
      local wantExit = stateData.viaVent.destinationId
      local wantPosition = stateData.viaVent.destinationPosition

      --  CAPTURE THE VENT'S ANSWER, NOT JUST pcall's.
      --
      --  This read `local ok = pcall(...)`, which is true whenever the call did
      --  not ERROR. petports_ventTravel signals refusal by returning nil, and
      --  that was being discarded -- so a refused hop and a completed one were
      --  indistinguishable, and the unit advanced its plan either way.
      local called, arrivedAt = pcall(world.callScriptedEntity,
        ventId, "petports_ventTravel", entity.id(), wantExit)
      local travelled = called and arrivedAt ~= nil

      sb.logInfo("UNIT [ENTRY SITE A: already touching] vent %s to exit %s called=%s arrivedAt=%s travelled=%s",
        sb.printJson(ventId), sb.printJson(wantExit),
        tostring(called), sb.printJson(arrivedAt), tostring(travelled))

      stateData.viaVent = nil
      stateData.ventApproachTimer = nil
      stateData.ventLastPosition = nil
      stateData.ventLegStarted = false
      stateData.groundTarget = nil
      stateData.searchingTimer = 0
      stateData.approachTimer = APPROACH_TIMEOUT
      stateData.arrived = false

      --  The vent declined -- its exits have changed under the plan. Blacklist
      --  it for this task and route again from where we are still standing.
      if not travelled then
        sb.logInfo("UNIT vent %s refused the hop, blacklisting and replanning from %s",
          sb.printJson(ventId), sb.printJson(mcontroller.position()))
        stateData.triedVents[ventId] = true
        stateData.plan = nil
        stateData.planIndex = 1
        stateData.planOrigin = nil
        stateData.routing = true
        freshPather("vent")
        return false
      end

      local here = mcontroller.position()
      stateData.ventHops = stateData.ventHops + 1

      --  The unit is somewhere new, so every "could not reach that mouth"
      --  judgement in the blacklist was made about a place it is no longer
      --  standing in. Clearing keeps the blacklist meaning "unreachable FROM
      --  HERE" rather than "unreachable for the rest of this task", which would
      --  rule out vents that a later hop puts within easy walking distance.
      --
      --  Termination does not depend on this list. Each stall also writes a
      --  per-tile cache entry through petports_learnRoute, which is permanent
      --  and is what actually stops the planner reoffering a bad vent. The
      --  blacklist only has to cover the window before that lands.
      stateData.triedVents = {}

      --  Count the hop by WHERE IT LANDED, not by which leg it was. A loop
      --  revisits the same tile through the same vent; a hard journey through
      --  a player's base does not. See MAX_REPEAT_HOPS.
      local hopKey = tostring(ventId) .. ">" .. petports_unitKey(here)
      stateData.hopSeen = stateData.hopSeen or {}
      stateData.hopSeen[hopKey] = (stateData.hopSeen[hopKey] or 0) + 1

      sb.logInfo("UNIT hop %s complete, landed %s, repeat count %s of %s",
        sb.printJson(stateData.ventHops), sb.printJson(here),
        sb.printJson(stateData.hopSeen[hopKey]), sb.printJson(MAX_REPEAT_HOPS))

      if stateData.hopSeen[hopKey] > MAX_REPEAT_HOPS
         or stateData.ventHops > MAX_TASK_HOPS then
        report(stateData, "failed",
          "vent loop: " .. hopKey .. " x" .. sb.printJson(stateData.hopSeen[hopKey])
          .. " (hops " .. sb.printJson(stateData.ventHops) .. ")")
        return true
      end

      --  DID WE COME OUT WHERE THE PLAN SAID WE WOULD?
      --
      --  The rest of the plan is written in terms of the exit this leg was
      --  supposed to reach -- leg 2's edges were probed FROM that exit. Landing
      --  somewhere else and advancing anyway means executing the remainder of a
      --  plan from a place it was never built for, which is how a stale vent
      --  list turned into an endless hop-stall-replan cycle rather than a single
      --  wasted hop.
      --
      --  The vent refusing above should make this unreachable in the case that
      --  produced it. It stays as the check that does not depend on the vent
      --  being honest.
      if wantPosition ~= nil
         and world.magnitude(here, wantPosition) > VENT_ARRIVAL_TOLERANCE then
        sb.logInfo("UNIT vent %s put us at %s, plan expected exit %s at %s -- discarding plan",
          sb.printJson(ventId), sb.printJson(here),
          sb.printJson(wantExit), sb.printJson(wantPosition))

        stateData.plan = nil
        stateData.planIndex = 1
        stateData.planOrigin = nil
        stateData.routing = true
        freshPather("vent")
        return false
      end

      if stateData.plan ~= nil then
        stateData.planIndex = stateData.planIndex + 1
        stateData.routing = stateData.planIndex <= #stateData.plan
      else
        stateData.routing = false
      end

      stateData.planOrigin = nil
      freshPather("line 1841")
      return false
    end

    --  THE ENTRY MUST BE REACHABLE TOO. The probe establishes that the EXIT can
    --  reach the target; it says nothing about whether this unit can walk to
    --  the mouth. A vent inside an enclosed room is exactly the case where the
    --  answer is no -- and that is the case vents exist for, so it is the
    --  common one, not an edge.
    --
    --  Without this the unit commits to a vent it cannot reach and stands
    --  still until the port's deadline, having reported nothing.
    --  TIME OUT ON LACK OF PROGRESS, NOT ON A CLOCK.
    --
    --  A flat budget punishes distance: a 35-tile walk to a vent mouth is about
    --  nine seconds of walking plus a couple of seconds of search, which a
    --  12-second clock cuts off mid-climb. The unit was not failing to reach the
    --  mouth, it was being interrupted on the way.
    --
    --  What actually indicates "cannot get there" is standing still, which is
    --  the same signal the main approach uses.
    local here = mcontroller.position()
    if stateData.ventLastPosition == nil
       or world.magnitude(here, stateData.ventLastPosition) > 0.5 then
      stateData.ventLastPosition = here
      stateData.ventApproachTimer = VENT_APPROACH_TIMEOUT
    end

    stateData.ventApproachTimer = (stateData.ventApproachTimer or VENT_APPROACH_TIMEOUT) - dt
    if stateData.ventApproachTimer <= 0 then
      sb.logInfo("UNIT vent approach TIMED OUT (%s s without movement)",
        sb.printJson(VENT_APPROACH_TIMEOUT))
      sb.logInfo("UNIT could not reach vent %s: stalled at %s, mouth %s",
        sb.printJson(stateData.viaVent.id),
        sb.printJson(mcontroller.position()),
        sb.printJson(stateData.viaVent.entry))

      --  Blacklist it for this task and go back to routing, which will offer
      --  the next candidate or report that nothing works.
      --  The plan assumed this mouth was reachable and it is not, so the
      --  cached edge that produced it was wrong. Record the correction and
      --  throw the plan away -- the next planning pass will route around it.
      petports_learnRoute(
        petports_unitKey(mcontroller.position()),
        petports_entryKey(stateData.viaVent.id),
        false, task.port)

      stateData.triedVents[stateData.viaVent.id] = true
      stateData.viaVent = nil
      stateData.ventApproachTimer = nil
      stateData.ventLastPosition = nil
      stateData.ventLegStarted = false
      stateData.plan = nil
      stateData.planIndex = 1
      stateData.routing = true
      freshPather("line 1896")
      return false
    end

    --  WALK TO STANDABLE GROUND NEAR THE MOUTH, NOT TO THE MOUTH.
    --
    --  A vent is mounted in a wall, so its own position can be several tiles
    --  above the floor -- observed at [1219,712] with ground at 704.75.
    --  approachPoint only reports arrival within ARRIVAL_DISTANCE of the RAW
    --  target, so a unit standing directly beneath is permanently seven tiles
    --  short, never arrives, and never moves again. Identical to the very first
    --  collection bug: an object's position is not a place a unit can stand.
    --  PASS THE RAW MOUTH POSITION. approachPoint resolves it itself with
    --  findGroundPosition(target, -20, 1, ...) -- searching twenty tiles DOWN
    --  -- so it finds the walkable ground beneath the alcove and the unit
    --  climbs whatever is there until it is close enough.
    --
    --  This is what worked originally. Resolving the mouth ourselves with
    --  standableNear BROKE it: standableNear tries the raw position first, a
    --  vent alcove PASSES validStandingPosition because it is a carved hole,
    --  and the pather then has a destination with no walkable route into it.
    --  The unit stood still until the progress timeout. Do not re-add it.
    --  WALK TO THE MOUTH ITSELF.
    --
    --  approachPoint resolves it with findGroundPosition(target, -20, 1, ...),
    --  which finds the walkable ground beneath and lets the unit climb whatever
    --  is there. Do NOT resolve it here first -- two attempts to be clever
    --  about this both failed:
    --
    --    standableNear picks the alcove, which passes validStandingPosition but
    --    usually has no walkable route in;
    --    searching adjacent columns for a lower spot sends the unit to an
    --    arbitrary patch of floor near the vent rather than to the vent.
    --
    --  Neither was ever the real problem. The stalls were a stale aStar on a
    --  reused pather -- see freshPather below.
    if not stateData.ventLegStarted then
      stateData.ventLegStarted = true
      freshPather("line 1934")

      sb.logInfo("UNIT walking to vent %s mouth %s from %s",
        sb.printJson(stateData.viaVent.id),
        sb.printJson(stateData.viaVent.entry),
        sb.printJson(mcontroller.position()))
    end

    local mouthTarget = stateData.viaVent.entry

    if approachPoint(dt, mouthTarget, ARRIVAL_DISTANCE, false) then
      --  At the mouth. The vent moves us and calls petports_ventTeleport.
      local ok, arrivedAt = pcall(world.callScriptedEntity,
        stateData.viaVent.id, "petports_ventTravel",
        entity.id(), stateData.viaVent.destinationId)

      --  NOTE: this site does NOT check arrivedAt, does not blacklist a refusal,
      --  does not verify the landing against the plan, and does not count the
      --  hop against MAX_REPEAT_HOPS. Site A above does all four. Logged with
      --  both values so the divergence is visible while it still exists.
      sb.logInfo("UNIT [ENTRY SITE B: walked to mouth] vent %s to exit %s called=%s arrivedAt=%s (refusal NOT handled at this site)",
        sb.printJson(stateData.viaVent.id),
        sb.printJson(stateData.viaVent.destinationId),
        tostring(ok), sb.printJson(arrivedAt))

      stateData.viaVent = nil
      stateData.ventApproachTimer = nil
      stateData.ventLastPosition = nil
      stateData.ventLegStarted = false
      stateData.ventHops = stateData.ventHops + 1

      --  More legs to go? Stay in routing mode so the next one is taken.
      if stateData.plan ~= nil then
        stateData.planIndex = stateData.planIndex + 1
        stateData.routing = stateData.planIndex <= #stateData.plan
      else
        stateData.routing = false
      end

      --  Everything about the approach is stale on the far side.
      stateData.groundTarget = nil
      stateData.searchingTimer = 0
      stateData.approachTimer = APPROACH_TIMEOUT
      stateData.arrived = false
      stateData.planOrigin = nil
      freshPather("line 1979")
    end

    return false
  end

  --  For collection and harvesting, walk to standable ground NEAR the target
  --  rather than to the target's own position. A drop rests where it rests and
  --  a crop is rooted where it is rooted; neither is a place to stand.
  --
  --  NOTE the upward bias documented in the handoff applies here too: a crop on
  --  a floor with a ledge two tiles above it resolves to the LEDGE. Not fixed,
  --  same one-line fix as collection, and it presents as a unit that walks
  --  somewhere near the crop and then times out.
  local approachTo = target

  --  A LEASH RESOLVES TOO, AND FOR THE STRONGEST REASON OF ANY TASK HERE.
  --
  --  This list was collect/harvest/replant/water/animal, and "return" was not on
  --  it -- so a unit walking home ran its ARRIVAL test against the raw port
  --  position. A port is a 4x4 object and its origin is inside itself; nothing
  --  can ever stand within ARRIVAL_DISTANCE of it unless the floor happens to be
  --  close underneath.
  --
  --  MEASURED: port origin [1203,708], floor [1203.5,704.8], unit parked at
  --  [1202.9,704.8]. That is 0.6 from where it belongs and 3.2 from the port,
  --  against an arrival radius of 1.5. approachPoint never returned true, the
  --  unit never arrived, the progress watchdog struck it for moving 0 of a
  --  required 2.5 tiles, and it replanned through the vents forever -- 129 times
  --  in 11 seconds.
  --
  --  ROUTING WAS ALREADY CORRECT, WHICH IS WHY THIS LOOKED LIKE A PATHING BUG.
  --  routeTarget above resolves through approachTargetFor, so planRoute names
  --  the right tile and the unit walks to exactly the right place. Only the
  --  question "are you there yet" was asked about somewhere else.
  --
  --  It hid while the port had platforms two tiles under it: the floor was then
  --  1.2 from the origin, inside 1.5, and arrival fired by luck.
  --
  --  approachTargetFor has a homeward branch that exists ONLY for this task
  --  type -- down-only, so a port under a shelter does not resolve to its roof.
  --  That branch was unreachable from here.
  --
  --  Falls back to the raw target rather than the nil path below: that path is
  --  for a drop still falling and ends in a failure report, and a leash must
  --  never fail.
  if task.type == "return" then
    approachTo = approachTargetFor(stateData, target) or target
  elseif task.type == "collect" or task.type == "harvest"
     or task.type == "replant" or task.type == "water"
     or task.type == "animal" then
    approachTo = approachTargetFor(stateData, target)

    if approachTo == nil then
      --  A FALLING DROP HAS NO STANDABLE COLUMN YET. Item drops are discovered
      --  the moment they exist, which is mid-air, so resolving from that
      --  position finds nothing and looks identical to a genuinely unreachable
      --  item. Observed: a drop seen at y 719 while falling to y 704 failed
      --  instantly, took a ten-second backoff, and was then collected without
      --  incident on the retry.
      --
      --  Give it time to land. Drops settle in well under a second, so a short
      --  grace costs nothing and removes the false failure entirely.
      stateData.settleTimer = stateData.settleTimer + dt

      if stateData.settleTimer >= SETTLE_GRACE then
        report(stateData, "failed",
          "no standable position near " .. tostring(task.type) .. " target at "
          .. sb.printJson(target)
          .. " after " .. sb.printJson(SETTLE_GRACE) .. "s")
        return true
      end

      return false
    end

    --  Landed somewhere resolvable. Clear the cached resolve too, since it was
    --  computed while the drop was still moving.
    stateData.settleTimer = 0
  end

  if not stateData.arrived then
    --  approachPoint OWNS the arrival test, and its return value is the answer.
    --
    --  Do not hand-roll this with world.magnitude against the raw target. A
    --  target y from a tile scan is the coordinate of the empty tile above the
    --  floor, while a unit's position is its CENTRE, roughly half a body
    --  higher. The vertical offset alone can exceed a tight arrival radius, so
    --  a unit standing exactly where it was sent never registers as arrived and
    --  times out instead. approachPoint resolves the target through
    --  findGroundPosition and does not have this problem.
    if approachPoint(dt, approachTo, ARRIVAL_DISTANCE, false) then
      stateData.arrived = true
      animator.setAnimationState("movement", "idle")
      return false
    end

    --  Net displacement check.
    stateData.progressTimer = (stateData.progressTimer or 0) + dt
    if stateData.progressTimer >= PROGRESS_WINDOW then
      stateData.progressTimer = 0

      local now = mcontroller.position()
      local reference = stateData.progressAnchor or now
      local moved = world.magnitude(now, reference)
      stateData.progressAnchor = now

      sb.logInfo("UNIT progress window: moved %s (need %s) in %s s at %s",
        sb.printJson(moved), sb.printJson(PROGRESS_DISTANCE),
        sb.printJson(PROGRESS_WINDOW), sb.printJson(now))

      if moved < PROGRESS_DISTANCE then
        stateData.progressStrikes = (stateData.progressStrikes or 0) + 1
        sb.logInfo("UNIT progress STRIKE %s of %s",
          sb.printJson(stateData.progressStrikes), sb.printJson(PROGRESS_STRIKES))

        if stateData.progressStrikes >= PROGRESS_STRIKES then
          --  Try a vent before giving up: a route the unit cannot jump may be
          --  reachable another way.
          local routing = tryVentRoute(stateData, routeTarget)
          if routing ~= "none" then
            stateData.routing = true
            stateData.progressStrikes = 0
            return false
          end

          if task.hold then
            sb.logInfo("UNIT station-keeping: no net progress, resetting and retrying")
            stateData.progressStrikes = 0
            stateData.approachTimer = APPROACH_TIMEOUT
            freshPather("station-keeping: no net progress, resett")
            return false
          end

          report(stateData, "failed",
            "no net progress -- moved " .. sb.printJson(moved)
            .. " in " .. sb.printJson(PROGRESS_WINDOW * PROGRESS_STRIKES)
            .. "s at " .. sb.printJson(now)
            .. " heading for " .. sb.printJson(approachTo))
          return true
        end
      else
        stateData.progressStrikes = 0
      end
    end

    --  Once a second: how far has it actually got?
    stateData.traceTimer = stateData.traceTimer - dt
    if stateData.traceTimer <= 0 then
      stateData.traceTimer = 1.0

      local here = mcontroller.position()
      stateData.movedTotal = stateData.movedTotal + world.magnitude(here, stateData.lastPosition)
      stateData.lastPosition = here

      if TASK_DEBUG then
        --  self.approachPosition is groundPet.lua's cache. approachPoint only
        --  UPDATES it when findGroundPosition succeeds and NEVER clears it, so
        --  a target that fails to resolve leaves the unit pathing toward
        --  wherever it was last going -- which right after a completed task is
        --  where it already stands. That produces a motionless unit with
        --  onGround true and stuck unset, which is indistinguishable from being
        --  blocked unless this value is visible.
        --  PathFinder does NOT latch -- find() resets and restarts whenever
        --  there is no path and no in-progress A*. So a unit that never moves
        --  means A* is reporting NO ROUTE every tick, which points at the
        --  SOURCE rather than the destination: start() seeds from
        --  mcontroller.position(), and a unit standing somewhere that is not a
        --  valid standing position has no source node to expand from.
        local finder = self.pather and self.pather.finder
        local selfStandable = select(2, pcall(validStandingPosition, here, false))

        sb.logInfo("UNIT approach at %s (standable %s) target %s approachPosition %s moved %s onGround %s | hasPath %s aStar %s finderTarget %s",
          sb.printJson(here), tostring(selfStandable),
          sb.printJson(task.position),
          sb.printJson(self.approachPosition),
          sb.printJson(stateData.movedTotal),
          tostring(mcontroller.onGround()),
          tostring(finder and finder.hasPath),
          tostring(finder ~= nil and finder.aStar ~= nil),
          sb.printJson(finder and finder.target))
      end
    end

    --  PATH ACQUIRED / LOST, PER TICK.
    --
    --  The once-a-second approach line samples too coarsely to see this: a path
    --  is lost and a fresh A* is already running by the time the next sample
    --  lands, so both the loss and its cause fall between two lines.
    --
    --  What is needed to identify the mechanism is the state AT THE INSTANT
    --  hasPath flips:
    --
    --    action     the edge being executed when it went. If this reads Jump or
    --               Arc, the loss is tied to the jump rather than merely
    --               coincident with it -- that is the whole question.
    --    onGround   airborne at the moment of loss points at a guard that
    --               refuses to path off the ground; grounded points elsewhere.
    --    velocity   a jump that fell short lands with a downward velocity and
    --               near-zero horizontal; a jump that never started has both
    --               near zero.
    --    stuck      whether vanilla's PathMover declared it, or something else
    --               cleared the path without saying so.
    --    edge i/n   how far along the path it got. Losing it on the same edge
    --               index every time is a specific edge the unit cannot walk.
    local finder = self.pather and self.pather.finder
    local hasPath = finder ~= nil and finder.hasPath == true

    if hasPath ~= stateData.lastHasPath then
      local edge = nil
      if finder ~= nil and finder.edges ~= nil and finder.currentEdgeIndex ~= nil then
        edge = finder.edges[finder.currentEdgeIndex]
      end

      sb.logInfo("UNIT path %s at %s: action %s onGround %s velocity %s stuck %s aStar %s edge %s of %s target %s",
        hasPath and "ACQUIRED" or "LOST",
        sb.printJson(mcontroller.position()),
        tostring(edge and edge.action),
        tostring(mcontroller.onGround()),
        sb.printJson(mcontroller.velocity()),
        tostring(self.pathing and self.pathing.stuck),
        tostring(finder ~= nil and finder.aStar ~= nil),
        tostring(finder and finder.currentEdgeIndex),
        tostring(finder and finder.edges and #finder.edges),
        sb.printJson(finder and finder.target))

      stateData.lastHasPath = hasPath
    end

    --  Every tick WHILE a path is held, so the tick before a loss is on record
    --  rather than inferred. This is the noisiest line in the mod -- it is here
    --  for the jump diagnosis and should come out once that is settled.
    if hasPath then
      local edge = finder.edges and finder.currentEdgeIndex
        and finder.edges[finder.currentEdgeIndex]

      --  EDGE SOURCE AND THE DISTANCE TO IT.
      --
      --  moveJump does nothing at all unless the unit is within 1.0 of
      --  edge.source.position -- and it contains no code to walk there:
      --
      --      if world.magnitude(mcontroller.position(),
      --                         self.edge.source.position) < 1.0 then
      --        ... take off ...
      --      end
      --      return "running"
      --
      --  So a unit parked further than a tile from its own jump point returns
      --  "running" forever while standing perfectly still. srcDist is the field
      --  that separates that from a cooldown stall, and both from a jump that
      --  fired and fell short.
      local source = edge and edge.source and edge.source.position
      local target = edge and edge.target and edge.target.position

      sb.logInfo("UNIT post-move at %s: action %s edge %s of %s onGround %s velocity %s src %s srcDist %s dst %s jumpVel %s cooldown %s jumpTimer %s",
        sb.printJson(mcontroller.position()),
        tostring(edge and edge.action),
        tostring(finder.currentEdgeIndex),
        tostring(finder.edges and #finder.edges),
        tostring(mcontroller.onGround()),
        sb.printJson(mcontroller.velocity()),
        sb.printJson(source),
        sb.printJson(source and world.magnitude(mcontroller.position(), source)),
        sb.printJson(target),
        sb.printJson(edge and edge.jumpVelocity),
        tostring(self.pather.jumpCooldown),
        tostring(self.pather.jumpTimer))
    end

    if finder ~= nil and not finder.hasPath and finder.aStar ~= nil then
      stateData.searchingTimer = stateData.searchingTimer + dt

      --  A* alive with no path is the unit thinking, by definition. Most such
      --  searches resolve well inside THINK_DELAY and correctly show nothing.
      petports_think("pathing")

      if stateData.searchingTimer >= SEARCH_LIMIT then
        sb.logInfo("UNIT direct path search hit SEARCH_LIMIT %s with no path -- handing over to vent routing",
          sb.printJson(SEARCH_LIMIT))
        --  Direct route failed. Before giving up, see whether a vent lands us
        --  nearer the target. This is the whole reason vents are
        --  infrastructure rather than decoration.
        --  Hand over to routing mode, which runs EVERY TICK from the top of
        --  update. Deciding here on the search timer would step the probe once
        --  per SEARCH_LIMIT -- a few hundred nodes every six seconds, which
        --  never resolves and dies to the port's deadline in silence.
        --  Routing mode reports the failure itself if no vent helps.
        stateData.routing = true
        stateData.searchingTimer = 0
        return false
      end
    else
      --  A path exists now. Report how long the search took, so the limit can
      --  be set from measurements instead of guesswork.
      if stateData.searchingTimer > 0 then
        --  SIZE AND SHAPE, not just "found". A path that satisfies hasPath and
        --  contains nothing moves nobody, and reads in the log exactly like a
        --  healthy one.
        local finder = self.pather ~= nil and self.pather.finder or nil
        local edges = (finder ~= nil and type(finder.path) == "table")
          and #finder.path or nil
        local first = (edges ~= nil and edges > 0 and type(finder.path[1]) == "table")
          and finder.path[1].action or nil

        sb.logInfo("UNIT path found after %s s: %s edge(s), first action %s, "
          .. "unit at %s target %s",
          sb.printJson(stateData.searchingTimer),
          edges ~= nil and sb.printJson(edges) or "unreadable",
          tostring(first), sb.printJson(mcontroller.position()),
          sb.printJson(stateData.groundTarget or target))
      end
      stateData.searchingTimer = 0
    end

    stateData.approachTimer = stateData.approachTimer - dt
    if stateData.approachTimer <= 0 and task.hold then
      --  A tethered unit that cannot get home has nowhere else to be, and
      --  failing the task just drops it back into wanderState -- the exact
      --  outcome the tether exists to prevent. Keep trying instead.
      sb.logInfo("UNIT could not reach station within %s s, retrying from %s",
        sb.printJson(APPROACH_TIMEOUT), sb.printJson(mcontroller.position()))
      stateData.approachTimer = APPROACH_TIMEOUT
      stateData.routingTried = false
      freshPather("could not reach station within")
      return false
    end

    if stateData.approachTimer <= 0 then
      --  Ran out of walking time rather than failing to find a route. A vent
      --  may still shorten what is left, so try one before giving up -- vent
      --  routing used to fire only on SEARCH_LIMIT, which meant a unit that
      --  could technically path but not in time never considered a hop.
      --  Only hand over to routing ONCE. If routing already ran and found no
      --  vent, it cleared the flag and this is a genuine walking failure worth
      --  reporting properly.
      sb.logInfo("UNIT approach timer expired (APPROACH_TIMEOUT %s), routingTried %s",
        sb.printJson(APPROACH_TIMEOUT), tostring(stateData.routingTried))

      if not stateData.routingTried then
        stateData.routingTried = true
        stateData.routing = true
        stateData.approachTimer = APPROACH_TIMEOUT
        return false
      end

      local here = mcontroller.position()

      --  Zero total movement means the unit never started, which is a DIFFERENT
      --  failure from walking as far as it could and not getting there. The
      --  first points at the unit's own position -- groundPet's move() gates on
      --  validStandingPosition, so a unit wedged somewhere invalid may refuse
      --  to move at all. The second points at reachability.
      local why = (stateData.movedTotal < 0.5)
        and "never moved" or "could not reach"

      report(stateData, "failed",
        why .. ", unit at " .. sb.printJson(here)
        .. " target " .. sb.printJson(task.position)
        .. " moved " .. sb.printJson(stateData.movedTotal)
        .. " onGround " .. tostring(mcontroller.onGround()))
      return true
    end

    if self.pathing.stuck and task.hold then
      sb.logInfo("UNIT station-keeping: PathMover reported stuck, rebuilding pather")
      freshPather("station-keeping: PathMover reported stuc")
      return false
    end

    if self.pathing.stuck then
      sb.logInfo("UNIT pathing.stuck is set -- vanilla PathMover gave up")
      report(stateData, "failed", "stuck at " .. sb.printJson(mcontroller.position()))
      return true
    end

    return false
  end

  if task.type == "animal" then
    if not world.entityExists(task.target) then
      report(stateData, "failed", "animal was gone on arrival")
      return true
    end

    local here = mcontroller.position()
    local there = world.entityPosition(task.target)
    local reach = world.magnitude(here, there)

    --  NOTHING CHASES. If the animal walked further than ANIMAL_REACH during
    --  the approach, this fails and says by how much -- which is the number
    --  that decides whether catch-up behaviour is worth building.
    if reach > ANIMAL_REACH then
      report(stateData, "failed", string.format(
        "animal %s moved out of reach: %s away (limit %s), unit at %s animal at %s",
        sb.printJson(task.target), sb.printJson(reach),
        sb.printJson(ANIMAL_REACH), sb.printJson(here), sb.printJson(there)))
      return true
    end

    --  THE TYPE IS CHECKED ON THIS SIDE TOO, and not as belt-and-braces: both
    --  calls below run inside the ANIMAL's script, where a throw kills the
    --  animal rather than failing the task. A task can outlive the dispatch
    --  that created it, and being wrong here costs livestock.
    --
    --  root.monsterParameters reads the type's config, so this is free and
    --  cannot itself trigger anything.
    local animalType = world.monsterType(task.target)
    local okParams, params = pcall(root.monsterParameters, animalType)
    local base = (okParams and type(params) == "table"
      and type(params.baseParameters) == "table") and params.baseParameters or {}
    local harvestable = okParams and type(params) == "table"
      and (params.harvestPool or base.harvestPool) ~= nil
      and (params.harvestTime or base.harvestTime) ~= nil

    if not harvestable then
      report(stateData, "failed", string.format(
        "animal %s is type %s, which declares no harvest -- not poking it",
        sb.printJson(task.target), tostring(animalType)))
      return true
    end

    --  STILL READY? It was at dispatch, but a player may have milked it in the
    --  meantime, or another network's unit may have got there first.
    local okBefore, before = pcall(world.callScriptedEntity, task.target,
      "hasMonsterHarvest")

    if not okBefore or before ~= true then
      report(stateData, "failed", string.format(
        "animal %s is not ready (hasMonsterHarvest %s) -- harvested by someone else?",
        sb.printJson(task.target), tostring(before)))
      return true
    end

    local okDrop, dropped = pcall(world.callScriptedEntity, task.target,
      "dropMonsterHarvest")

    --  VERIFIED BY ASKING AGAIN, NOT BY THE RETURN VALUE. callScriptedEntity
    --  returns nil SILENTLY when the target has no such function, so a nil here
    --  is indistinguishable from a call that ran and returned nothing. The
    --  animal itself is the authority: dropMonsterHarvest calls
    --  resetMonsterHarvest, so a successful poke flips hasMonsterHarvest to
    --  false immediately.
    local okAfter, after = pcall(world.callScriptedEntity, task.target,
      "hasMonsterHarvest")

    sb.logInfo("UNIT animal poke %s: drop ok %s returned %s, ready %s -> %s",
      sb.printJson(task.target), tostring(okDrop), tostring(dropped),
      tostring(before), tostring(after))

    if okAfter and after == false then
      --  NO CARGO. The produce is on the ground and ordinary collection takes
      --  it, seed-style.
      report(stateData, "done",
        "harvested animal " .. sb.printJson(task.target)
        .. " at " .. sb.printJson(there))
      return true
    end

    report(stateData, "failed", string.format(
      "poked %s and it is still ready (%s) -- dropMonsterHarvest did not run",
      sb.printJson(task.target), tostring(after)))
    return true
  end

  if task.type == "water" then
    local tiles = task.tiles or {}
    local index = task.waterIndex or 1
    local tile = tiles[index]

    if tile == nil then
      report(stateData, "done",
        "swept " .. sb.printJson(task.watered or 0) .. " tile(s)")
      return true
    end

    local here = mcontroller.position()
    local standing = { tile[1] + 0.5, tile[2] + 1.5 }

    if world.magnitude(here, standing) > WATER_REACH then
      report(stateData, "failed", string.format(
        "arrived but %s from tile %s -- sweep abandoned after %s tile(s)",
        sb.printJson(world.magnitude(here, standing)), sb.printJson(tile),
        sb.printJson(task.watered or 0)))
      return true
    end

    --  ALREADY WET? Skip it and charge nothing. Another unit may have swept
    --  past, or a player may have watered by hand while this unit walked.
    local modNow = world.mod({ tile[1], tile[2] }, "foreground")

    if tostring(modNow) ~= tostring(task.previousMod) then
      sb.logInfo("UNIT water SKIP tile %s: mod is %s, expected %s -- "
        .. "already wet or no longer farmland",
        sb.printJson(tile), tostring(modNow), tostring(task.previousMod))
    else
      --  PARAMETERS CARRY THE TRANSITION. The projectile ships with an empty
      --  actionOnReap on purpose -- previousMod and newMod are read off the
      --  tile per cast, so one asset covers vanilla and modded soils alike.
      --
      --  IF PARAMETER OVERRIDE DOES NOT REACH actionOnReap, this is where it
      --  shows: the droplet falls, nothing changes, and the mod check on the
      --  next pass still reads dry. Hence logging exactly what was passed.
      --  NOT THE TILE CENTRE. x + 0.5 sits exactly on a rounding boundary, and
      --  MEASURED at radius 0 it landed one tile RIGHT of target every time:
      --  sweeping right to left, the first cast spilled off the right edge and
      --  the leftmost tile never got one.
      --
      --  Two candidate causes and this offset is immune to both. If the engine
      --  FLOORS the reap position, x + 0.25 is inside tile x. If it ROUNDS --
      --  floor(x + 0.5), which is what x + 0.5 landing in x+1 looks like -- then
      --  floor(x + 0.75) is still tile x. Anything in [x, x + 0.5) works under
      --  either rule; a quarter tile keeps clear of both edges.
      --
      --  The standing position keeps + 0.5 deliberately: that is where the unit
      --  walks to, it is not converted to a tile by anything, and centring it
      --  is correct.
      local spawn = { tile[1] + 0.25, standing[2] + WATER_DROP_HEIGHT }

      local ok, err = pcall(world.spawnProjectile,
        "petports_watersprinkle", spawn, entity.id(), {0, -1}, false, {
          actionOnReap = { {
            action = "applySurfaceMod",
            previousMod = task.previousMod,
            newMod = task.newMod,
            --  RADIUS 0, NOT VANILLA'S 1.
            --
            --  MEASURED at radius 1: six casts, five skips, ten tiles wetted
            --  for five items. Each droplet caught its neighbour, so the unit
            --  arrived at every second tile to find it already wet and skipped
            --  it free. That is cheaper but not PREDICTABLE, and the whole
            --  point of one-item-per-tile is that a player can look at a row
            --  and know what it cost.
            --
            --  IF RADIUS 0 WETS NOTHING, the symptom is unmistakable: casts
            --  fire, no tile changes mod, and the sweep re-reports the same
            --  run next pass. Vanilla ships 1, so 0 may be below the floor --
            --  in which case keep 1 and halve WATER_CARRY instead, which buys
            --  the same predictability from the other direction.
            radius = 0
          } },

          --  THE LIQUID PAINTS ITS OWN DROPLET. The sprite is transparent
          --  white, so this multiply is what gives it a colour at all -- and
          --  the colour comes off the liquid's own config on the port side, so
          --  water arrives blue and lava would not.
          --
          --  nil when the liquid config had no colour, which leaves the
          --  parameter absent and the droplet white. Visible, wrong-looking,
          --  and logged -- which is the right failure for a cosmetic.
          processing = task.tint ~= nil and ("?multiply=" .. task.tint) or nil
        })

      --  Spawn x is printed to full precision on purpose: the whole off-by-one
      --  lives in how that float maps to a tile, so the number that produced a
      --  hit or a miss has to be in the log next to the tile it aimed at.
      sb.logInfo("UNIT water CAST tile %s aim x %s spawn %s: %s -> %s, tint %s, ok %s %s",
        sb.printJson(tile), sb.printJson(spawn[1]), sb.printJson(spawn),
        tostring(task.previousMod), tostring(task.newMod),
        tostring(task.tint or "none"), tostring(ok), tostring(err or ""))

      if not ok then
        report(stateData, "failed", string.format(
          "spawnProjectile failed at %s after %s tile(s): %s",
          sb.printJson(tile), sb.printJson(task.watered or 0), tostring(err)))
        return true
      end

      --  COUNTED, NOT ASSUMED. The port charges one item per tile ACTUALLY
      --  wetted, so a sweep cut short partway charges only for what it did.
      task.watered = (task.watered or 0) + 1
    end

    task.waterIndex = index + 1

    if task.waterIndex > #tiles then
      report(stateData, "done",
        "swept " .. sb.printJson(#tiles) .. " tile(s), watered "
        .. sb.printJson(task.watered or 0))
      return true
    end

    --  ON TO THE NEXT TILE. Everything about the previous approach is stale:
    --  the ground target was resolved for a different tile, and arrival has to
    --  be re-earned or the unit waters the whole row from where it stands.
    stateData.arrived = false
    stateData.groundTarget = nil
    stateData.approachTimer = APPROACH_TIMEOUT
    stateData.searchingTimer = 0
    freshPather("water sweep advancing to tile " .. sb.printJson(task.waterIndex))

    return false
  end

  if task.type == "replant" then
    local tile = task.tile or {
      math.floor(task.position[1]), math.floor(task.position[2])
    }

    --  LAST LOOK BEFORE PLANTING. The port checked the footprint at dispatch,
    --  but the unit has been walking since then and a player can put a crate
    --  anywhere in that time. Cheap, and the failure mode it avoids is a seed
    --  spent on a placement that silently did nothing.
    --  SAME EXACT-OCCUPANCY TEST AS THE PORT, and for the same reason: a rect
    --  drawn tightly around one tile intersects the next tile's crop, so in a
    --  planted row a naive query says every tile is occupied by its neighbour.
    if tileOccupied(tile, task.seed) then
      report(stateData, "failed", string.format(
        "footprint for %s at %s is occupied -- not planting",
        tostring(task.seed), sb.printJson(tile)))
      return true
    end

    --  world.placeObject wants a direction. Crops are symmetric and
    --  single-orientation, so this is a formality rather than a choice -- but
    --  it is a required argument, and omitting it is not the same as passing 1.
    local ok, placed = pcall(world.placeObject, task.seed, tile, 1)

    sb.logInfo("UNIT replant at %s: placeObject(%s) ok %s returned %s",
      sb.printJson(tile), tostring(task.seed), tostring(ok), tostring(placed))

    --  VERIFIED BY LOOKING, NOT BY THE RETURN VALUE. Same discipline as the
    --  harvest swing: world.placeObject's return is not documented clearly
    --  enough to branch on, and the world can answer the question directly.
    --  A farmable is an object, so the footprint query that just came back
    --  empty should now come back with exactly the thing we planted.
    --  Verified by looking, not by placeObject's return value. Now checks the
    --  crop's REAL footprint, so a wide crop that planted fine is no longer
    --  reported as a failure because only its anchor column was inspected.
    if tileOccupied(tile, task.seed) then
      --  The port spends the seed and retires the intent on this report.
      report(stateData, "done",
        "planted " .. tostring(task.seed) .. " at " .. sb.printJson(tile))
      return true
    end

    --  Placement refused. The likeliest causes are the ground no longer being
    --  tilled and tile protection, and neither is worth retrying in place --
    --  the port's sweep will clear the intent if the ground changed, and the
    --  backoff ladder handles the rest.
    report(stateData, "failed", string.format(
      "placeObject(%s) at %s left nothing there -- untilled ground, "
      .. "or placement refused",
      tostring(task.seed), sb.printJson(tile)))
    return true
  end

  if task.type == "harvest" then
    --  ONE SWING PER DISPATCH, THEN WATCH.
    --
    --  The swing and the verification cannot share a tick: the engine does not
    --  remove a harvested crop, or settle its new stage, before this script
    --  regains control. So the act runs once, sets a flag, and every tick after
    --  that is verification -- either the crop vanishes (caught at the top of
    --  update, where the target resolves to nil) or its stage moves.
    --
    --  Swinging once rather than every tick also bounds the damage if the
    --  ripeness test is ever wrong: FarmableObject::damageTiles falls through
    --  to ordinary object damage when harvest() declines, and a unit hammering
    --  an unripe crop once a frame would eventually break it.
    if not stateData.swung then
      local here = mcontroller.position()
      local cropPosition = world.entityPosition(task.target)
      local reach = world.magnitude(here, cropPosition)

      --  See HARVEST_REACH. damageTiles does not care how far away the caller
      --  is, so this is the only thing standing between an upstream arrival bug
      --  and a unit harvesting a field it is not standing in.
      if reach > HARVEST_REACH then
        report(stateData, "failed", string.format(
          "arrived but %s tiles from the crop at %s (unit at %s)",
          tostring(reach), sb.printJson(cropPosition), sb.printJson(here)))
        return true
      end

      local okBefore, before = pcall(world.farmableStage, task.target)
      stateData.stageBefore = okBefore and before or nil

      --  TILE COORDS ARE INTEGERS. world.damageTiles takes List<Vec2I>, and a
      --  farmable's entityPosition is a float pair, so floor it rather than
      --  relying on whatever the conversion happens to do.
      --
      --  ONE TILE, THE ANCHOR. A crop occupies two tiles -- spaces [0,0] and
      --  [0,1], anchored bottom -- but it is ROOTED in the anchor, which is
      --  what the Harvester Beam mod damages and what tile damage propagates
      --  from. Confirmed working against a crop at [1203,715].
      local tile = { math.floor(cropPosition[1]), math.floor(cropPosition[2]) }

      --  sourcePosition only sets the direction the damage PARTICLES fly.
      --  Passing the unit's own position makes debris fly away from it, which
      --  is both correct-looking and free.
      local okDamage, damaged = pcall(world.damageTiles, { tile }, "foreground",
        here, "plantish", HARVEST_DAMAGE, HARVEST_LEVEL)

      stateData.swung = true
      stateData.verifyTimer = HARVEST_TIMEOUT

      --  THE RETURN VALUE IS NOISE. It is documented as "was tile damage done",
      --  and FarmableObject::damageTiles returns FALSE on a successful harvest
      --  because it consumed the damage instead. Measured, it came back TRUE on
      --  a harvest that unambiguously worked -- so it is unreliable in BOTH
      --  directions and is logged only, never branched on.
      sb.logInfo("UNIT harvest swing at %s tile %s: damageTiles ok %s returned %s "
        .. "(ignored), stage before %s -- watching for the result",
        sb.printJson(task.target), sb.printJson(tile), tostring(okDamage),
        tostring(damaged), sb.printJson(stateData.stageBefore))

      return false
    end

    --  VERIFYING. The crop vanishing is handled at the top of update; what is
    --  left to catch here is a crop that RESET, which stays alive with a lower
    --  stage number.
    local okAfter, after = pcall(world.farmableStage, task.target)
    if not okAfter then after = nil end

    if type(after) == "number" and type(stateData.stageBefore) == "number"
       and after ~= stateData.stageBefore then
      --  NO CARGO. The drops are on the ground and the collection task comes
      --  back for them, seed included. See the header.
      sb.logInfo("UNIT harvest confirmed on %s: stage %s -> %s (crop survived)",
        sb.printJson(task.target), sb.printJson(stateData.stageBefore),
        sb.printJson(after))

      report(stateData, "done",
        "harvested " .. sb.printJson(task.target)
        .. " at " .. sb.printJson(task.position)
        .. " (crop reset to stage " .. sb.printJson(after) .. ")")
      return true
    end

    stateData.verifyTimer = (stateData.verifyTimer or HARVEST_TIMEOUT) - dt
    if stateData.verifyTimer <= 0 then
      --  THIS IS THE GUARD ON A WRONG FARMABLE_STAGE_BASE. If the port's notion
      --  of "ripe" is off by one, harvest() declines, damageTiles falls through
      --  to ordinary object damage, and nothing changes -- so this path fires,
      --  the port records a failure, and the backoff ladder stops the unit
      --  swinging at that crop once a second.
      report(stateData, "failed", string.format(
        "swung at %s and nothing changed in %ss (stage still %s) "
        .. "-- crop was not ready, or FARMABLE_STAGE_BASE is wrong",
        sb.printJson(task.target), sb.printJson(HARVEST_TIMEOUT),
        sb.printJson(after)))
      return true
    end

    return false
  end

  if task.type == "collect" then
    --  world.takeItemDrop returns the item descriptor on success, nil if the
    --  drop is not yet takeable -- drops have a brief delay after spawning
    --  during which they refuse pickup. Retry rather than failing: the unit is
    --  standing right on top of it.
    local ok, taken = pcall(world.takeItemDrop, task.target, entity.id())

    sb.logInfo("UNIT pickup attempt on %s: ok %s taken %s (dwell left %s)",
      sb.printJson(task.target), tostring(ok), sb.printJson(taken),
      sb.printJson(stateData.dwellTimer))

    if ok and taken then
      --  THE DESCRIPTOR IS THE ITEM. Discarding it destroyed the pickup, which
      --  is what the testing sink used to do. It now travels back to the port
      --  on the report, and the port writes it into the unit ITEM -- so cargo
      --  survives despawn, reload, and being carried to another world, the same
      --  way the unit's own state does.
      --
      --  THERE IS A LOSS WINDOW and it is worth knowing about: takeItemDrop has
      --  already destroyed the world drop by the time this line runs, so if the
      --  report never reaches the port -- port mined during the second between
      --  pickup and report -- the item is gone. Narrow, but real. The port logs
      --  an error rather than swallowing it if cargo arrives with nowhere to go.
      report(stateData, "done",
        "collected at " .. sb.printJson(task.position), taken)
      return true
    end

    --  Not takeable yet. The dwell timer doubles as the retry budget.
    stateData.dwellTimer = stateData.dwellTimer - dt
    if stateData.dwellTimer <= 0 then
      report(stateData, "failed",
        "arrived but could not take drop (pcall ok=" .. tostring(ok) .. ")")
      return true
    end

    return false
  end

  --  ON STATION. Do NOT report done.
  --
  --  Completing the task returns the unit to the state machine's idle branch,
  --  and vanilla wanderState takes it straight back out again -- which is the
  --  behaviour strictPortTethering exists to stop. Staying in the state keeps
  --  the action state occupied, and wanderState only runs when it is not.
  --
  --  The unit leaves this by exactly one route: the check at the top of this
  --  function, when the port dispatches real work.
  if task.hold then
    --  MEASURED AGAINST THE RESOLVED GROUND, NOT THE PORT ORIGIN.
    --
    --  task.position is the raw port position and petports_leashTask says so in
    --  as many words: a port is an object and its position is not somewhere a
    --  unit can stand, so the task carries the raw value and the unit resolves
    --  it. Everything downstream honoured that. This test did not.
    --
    --  MEASURED: port origin [1203,708], floor beneath it [1203.5,704.8], unit
    --  standing at [1203.13,704.8] -- 0.37 from where it belongs and 3.2 from
    --  the port, against a slack of 3.0. So it never arrived, kept approaching,
    --  and the progress watchdog saw it move 0 of the 2.5 tiles it wanted, took
    --  two strikes and forced a vent replan. 137 replans in 64 seconds, and it
    --  would have gone on forever.
    --
    --  IT ONLY SHOWS WHEN THE FLOOR IS FAR FROM THE PORT. With a row of
    --  platforms two tiles under the port the floor was 1.2 away and inside
    --  slack; mining them out put the next standable ground 3.2 down and over
    --  the line. Raising TETHER_SLACK would have hidden this exact case and
    --  left the bug for a port on a ledge.
    local station = approachTargetFor(stateData, task.position) or task.position
    local home = world.magnitude(mcontroller.position(), station)

    --  Pushed off station -- shoved by a player, a door, an explosion. Walk
    --  back rather than holding a position the unit is no longer standing in.
    if home > (task.slack or 3.0) then
      sb.logInfo("UNIT pushed off station (%s from port), returning",
        sb.printJson(home))

      --  RE-RESOLVE THE FLOOR. THE TERRAIN MAY BE WHY IT LEFT.
      --
      --  groundTarget is resolved once and cached for the life of a task, which
      --  is fine for work that finishes. A leash never finishes -- see the
      --  arrival block below -- so its cached floor outlives any change to the
      --  ground it names.
      --
      --  MEASURED: a port with a row of platforms beneath it. The platforms are
      --  mined out; the unit falls, is now further than slack from its station,
      --  walks back -- to the cached platform tile, which is no longer there.
      --  The port is not involved and never issues a recall: returnWork reports
      --  "inNetwork true stranded false" and returns nil, so nothing upstream
      --  looks wrong while the unit walks to a spot in mid-air.
      --
      --  onStation is cleared as well so the arrival block runs again and clears
      --  this a second time. Without that, only the FIRST arrival ever resets
      --  it and the second walk home re-caches a target nothing will invalidate.
      stateData.groundTarget = nil
      stateData.onStation = false

      stateData.arrived = false
      stateData.approachTimer = APPROACH_TIMEOUT
      stateData.progressStrikes = 0
      freshPather("pushed off station (")
      return false
    end

    if not stateData.onStation then
      stateData.onStation = true
      task.arrivedHome = true
      animator.setAnimationState("movement", "idle")

      --  THE TRIP HOME IS OVER, SO THE ROUTE THAT GOT HERE IS HISTORY.
      --
      --  A leash is a HOLD task: it never completes, so its stateData lives for
      --  as long as the unit sits at its port. Anything left on it stays
      --  forever. That did not show while recalls were refused a vent route --
      --  plan was always nil and ventHops always zero on the way home -- and
      --  became visible the moment recalls were allowed to route: a unit that
      --  vent-hopped home then sat at its station indefinitely displaying
      --  "hop 2", with "leg 1" hanging over the vents it had used.
      --
      --  Cosmetic in the overlay, but the same residue is real state: planIndex
      --  and viaVent are read by the routing branches, and a stale plan on a
      --  task that has arrived is a plan nothing intends to execute.
      stateData.plan = nil
      stateData.planIndex = 1
      stateData.ventHops = 0
      stateData.viaVent = nil

      --  AND THE GROUND TARGET, which this list missed the first time.
      --
      --  It is the same residue as the four fields above and the same argument
      --  applies -- but it is not cosmetic. Every other place that clears
      --  groundTarget hangs off a MOVEMENT event: starting a vent leg, coming
      --  out of a vent, stepping to the next watering tile. A unit parked at its
      --  port triggers none of them, so a leash held the floor it resolved on
      --  arrival for as long as the unit stood there, and kept walking to it
      --  after that floor was mined out.
      stateData.groundTarget = nil
      stateData.routing = false

      sb.logInfo("UNIT on station at %s (port %s), holding until dispatched",
        sb.printJson(mcontroller.position()), sb.printJson(task.position))
    end

    return false
  end

  --  Arrived. Stand still for the dwell, which is the whole of the diagnostic.
  stateData.dwellTimer = stateData.dwellTimer - dt
  if stateData.dwellTimer <= 0 then
    --  Success is reported with the target, so outcomes can be correlated
    --  against position. Silent success made it impossible to tell which parts
    --  of the rect were reachable.
    report(stateData, "done",
      "reached " .. sb.printJson(task.position)
      .. " from " .. sb.printJson(stateData.startPosition))
    return true
  end

  return false
end

function petportsTaskAction.leavingState(stateData)
  sb.logInfo("UNIT leaving task state for %s at %s, still holding a task: %s",
    stateData.task and tostring(stateData.task.id) or "none",
    sb.printJson(mcontroller.position()), tostring(self.petportsTask ~= nil))

  --  Nothing will pump the indicator down once this state is gone, so drop it
  --  now rather than leaving a spinner over an idle unit forever.
  --
  --  Deliberately NOT done on vent travel: petports_ventTeleport is a straight
  --  setPosition with no invisible state, the spinner is a PART and moves with
  --  the entity, and the unit is usually still routing on the far side. A clear
  --  there would only blink it off and on between legs.
  petports_thinkClear()

  petports_cancelProbe()

  --  Do not leave an abandoned search behind for follow/inspect to inherit.
  --  approachPoint rebuilds the pather from nil on its next call.
  self.pather = nil
  self.approachPosition = nil

  --  Interrupted rather than completed -- the state was pre-empted, or the unit
  --  is being recalled. Hand the task back so the claim is released rather than
  --  left to age out.
  --  Only if the held task is THE ONE THIS STATE WAS RUNNING. A leash task
  --  yielding to a freshly dispatched task passes through here with the new
  --  task already held, and reporting that as interrupted would fail the work
  --  before it started.
  if self.petportsTask ~= nil and stateData.task ~= nil
     and self.petportsTask.id == stateData.task.id then
    report(stateData, "failed", "interrupted")
  end
end
