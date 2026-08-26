--  M.A.U.S. UTILITY UNIT -- PETPORT / VENT CONTRACT
--
--  The petport and the vent call functions ON the unit via
--  world.callScriptedEntity. groundPet.lua defines none of them, so without
--  this file those calls do nothing at all -- and they do it SILENTLY. A bare
--  world.callScriptedEntity naming a function the target does not define
--  returns nil rather than raising, so a missing contract does not error, log,
--  or crash. It just quietly fails to happen.
--
--  That is exactly how the socket-cycle leak was found: removing the item let
--  saveAndDespawn run to completion, the petport cleared self.petId, and the
--  unit carried on living because petports_despawn resolved to nothing.
--  Re-socketing then spawned a second unit alongside the orphan.
--
--  ADD THIS TO THE MONSTERTYPE'S scripts LIST, after groundPet.lua.
--
--  CRITICAL: this file must NOT define init, update or uninit. Every script in
--  a monstertype's list shares one Lua environment, so a second definition of
--  any of those silently replaces groundPet.lua's. Prefixed functions only.

--------------------------------------------------------------------------------
--  PETPORT CONTRACT
--------------------------------------------------------------------------------

--  Hand the petport everything worth keeping, so it can write it into the item.
--
--  Only `storage` round-trips for now. groundPet.lua reads knownPlayers,
--  foodLikings and petResources out of `storage` on init, and the petport feeds
--  them back as initialStorage, so storage alone covers everything that
--  currently persists.
--
--  `storage.petResources` is seeded at init and never updated as resources
--  tick, so it is refreshed here from live values before handing it over --
--  otherwise a unit would resume at its starting hunger every time.
--
--  DEFERRED: status round-tripping. `initialStatus` is engine-interpreted and
--  its reciprocal getter is not confirmed, so nothing is returned under that
--  key. Health resets to full on respawn as a result, which is harmless for a
--  unit that cannot be damaged.
function petports_store()
  storage.petResources = petResources()

  return {
    storage = copy(storage)
  }
end

--  Put the unit away.
--
--  There is no Lua call that simply removes a monster, so recall is death with
--  the funeral suppressed -- the vanilla idiom for capture-pod recall. dropPools
--  is already empty on the monstertype, so nothing is left behind.
--
--  VERIFY: setDeathParticleBurst / setDeathSound accepting nil to clear. If the
--  unit poofs audibly on recall, that is these two not taking effect, and the
--  fix is passing "" rather than nil.
function petports_despawn()
  monster.setDeathParticleBurst(nil)
  monster.setDeathSound(nil)
  status.setResource("health", 0)
  return true
end

--------------------------------------------------------------------------------
--  VENT CONTRACT
--------------------------------------------------------------------------------

--  Called by a vent to move this unit to the far end. The vent plays its own
--  effects at both ends before calling, so this only has to handle the move.
--
--  Velocity is cleared so a unit that entered mid-stride does not shoot out of
--  the destination still carrying its momentum.
function petports_ventTeleport(position)
  if position == nil then
    sb.logInfo("UNIT ventTeleport called with nil position")
    return false
  end

  local before = mcontroller.position()

  mcontroller.setPosition(position)
  mcontroller.setVelocity({0, 0})

  sb.logInfo("UNIT teleported: from %s asked %s ended at %s",
    sb.printJson(before), sb.printJson(position),
    sb.printJson(mcontroller.position()))

  return true
end

--------------------------------------------------------------------------------
--  TASK CONTRACT
--------------------------------------------------------------------------------

--  Accept an assignment from the petport.
--
--  The unit HOLDS this; it does not act on it here. Our forked petBehavior
--  re-queues it every tick, because vanilla's actionQueue is a per-tick scoring
--  bucket that is emptied at the end of every run() -- an assignment queued
--  once would vanish on the next tick.
--
--  Refuses a second assignment rather than replacing the first: the port is
--  supposed to know whether its unit is busy, and silently swapping tasks would
--  strand the claim on the one that got dropped.
function petports_assignTask(task)
  if task == nil or task.id == nil then
    sb.logInfo("UNIT refusing assignment: malformed task %s", sb.printJson(task))
    return false
  end

  if self.petportsTask ~= nil then
    sb.logInfo("UNIT refusing assignment %s: already holding %s",
      tostring(task.id), tostring(self.petportsTask.id))
    return false
  end

  sb.logInfo("UNIT accepted task %s type %s target %s at %s",
    tostring(task.id), tostring(task.type),
    sb.printJson(task.target), sb.printJson(task.position))

  self.petportsTask = task
  return true
end

--  What this unit is working on, or nil. Polled by the port.
function petports_taskId()
  return self.petportsTask and self.petportsTask.id or nil
end

--  Drop the assignment without reporting. Used by the port when it has decided
--  the task is gone -- the claim expired, the work vanished, the port is being
--  broken.
function petports_clearTask()
  sb.logInfo("UNIT task cleared by port (was %s)",
    self.petportsTask and tostring(self.petportsTask.id) or "none")
  self.petportsTask = nil
  return true
end

--  The unit's idle bounds: a list of rects, its network's coverage.
--
--  The unit never learns that networks exist, which ports are members, or that
--  union-find happened. It gets rectangles and one rule: WHEN IDLE, STAY
--  INSIDE. A task may path anywhere it likes -- the leash bounds where a unit
--  goes on its OWN initiative, not where a route may lead.
--
--  Deliberately NOT persisted into storage. Entity ids and network shape both
--  change across a reload, and the port re-pushes on spawn anyway.
function petports_setNetwork(rects, home)
  self.petportsNetwork = rects
  self.petportsHome = home
  return true
end

--  A task to walk back inside the network, or nil when the unit is already
--  where it belongs.
--
--  Deliberately carries NO `port` field. report() only messages a port when the
--  task names one, so this is a purely local errand the port never hears about
--  -- which is right: nothing was dispatched, no claim was taken, and nothing
--  is owed a report.
--  How far from the port a tethered unit may drift before it walks back.
--
--  Not zero, and not tight. The unit stands on ground the port resolves for
--  itself, arrival has slop, and a threshold smaller than that slop means the
--  unit is permanently one step from home and permanently re-approaching.
local TETHER_SLACK = 3.0

function petports_leashTask()
  if self.petportsHome == nil then return nil end

  --  TWO DIFFERENT LEASHES, ONE TASK.
  --
  --  Without strictPortTethering this is the original behaviour: come home only
  --  after wandering clean out of the network, and otherwise let vanilla
  --  wanderState do as it likes. That is right for a biological pet.
  --
  --  With it, the bound is the PORT rather than the network, because a robot
  --  has no reason to be anywhere else. It walks back to the ground under its
  --  port and holds there -- see the `hold` flag, which is what stops the task
  --  completing and handing the unit back to wanderState.
  local tethered = config.getParameter("strictPortTethering", false)

  if tethered then
    local distance = world.magnitude(mcontroller.position(), self.petportsHome)
    if distance <= TETHER_SLACK and self.petportsLeashTask ~= nil
       and self.petportsLeashTask.arrivedHome then
      --  Already on station. Keep returning the task so the action state stays
      --  entered and wanderState never gets a turn.
      return self.petportsLeashTask
    end
  elseif petports_inNetwork(mcontroller.position()) then
    self.petportsLeashTask = nil
    return nil
  end

  --  Reuse one table rather than building a fresh one per tick.
  self.petportsLeashTask = self.petportsLeashTask or {
    id = "leash",
    type = "return",
    position = self.petportsHome,
    dwell = 0
  }

  --  RAW PORT POSITION, DELIBERATELY UNRESOLVED.
  --
  --  A port is an object and its position is not somewhere a unit can stand,
  --  so the task carries the raw position and the unit resolves it in
  --  approachTargetFor.
  --
  --  CORRECTION: an earlier version of this comment claimed the resolve was
  --  "findGroundPosition(target, -20, 1) -- twenty tiles DOWN". Both numbers
  --  were wrong and so was the implied direction. The real bounds are
  --  GROUND_SEARCH_DOWN -6 and GROUND_SEARCH_UP 4, and vanilla tests UP FIRST,
  --  so an unbiased resolve happily puts the unit on the port's roof. The
  --  downward bias for "return" tasks lives in approachTargetFor; this comment
  --  is not the place to restate it, only to stop the old claim being trusted.
  self.petportsLeashTask.position = self.petportsHome
  self.petportsLeashTask.hold = tethered
  self.petportsLeashTask.slack = TETHER_SLACK

  return self.petportsLeashTask
end

--  Is this position inside the unit's idle bounds? True when no bounds are set,
--  so a unit without a network is never considered stray.
function petports_inNetwork(position)
  if self.petportsNetwork == nil or #self.petportsNetwork == 0 then return true end

  for _, rect in ipairs(self.petportsNetwork) do
    if position[1] >= rect[1] and position[1] <= rect[3]
       and position[2] >= rect[2] and position[2] <= rect[4] then
      return true
    end
  end
  return false
end

--  Vents the unit may route through, pushed by the port alongside the network.
--
--      { { id, entry = {x,y}, destinations = { {id, position}, ... } }, ... }
--
--  NOT persisted: entity ids do not survive a reload, and the port re-pushes on
--  every spawn.
--  A POSITION THIS UNIT CAN ACTUALLY STAND AT, near `position`.
--
--  Exists because THE PORT CANNOT ANSWER THIS. validStandingPosition tests the
--  unit's BOUNDING BOX, and the box comes from mcontroller.boundBox(), which
--  objects do not have. The port's own findStandingPoint tests a POINT instead,
--  and the two disagree systematically:
--
--    findStandingPoint      wants the tile under the POINT to be solid
--    validStandingPosition  wants the tile under the BOX to be solid, and the
--                           box bottom is boundBox[2] below the point
--
--  For a unit with boundBox[2] = -0.375 those are contradictory -- the row the
--  port requires to be solid is the row the pathfinder requires to be empty.
--  Every standing position this unit ever occupies ends in .375; the port was
--  handing out integers, so the deposit target was rejected before pathing even
--  started and the whole route failed with it.
--
--  findGroundPosition does the alignment properly:
--      position = {x, math.ceil(y) - (bounds[2] % 1)}
--  which is where that .375 comes from. Use it rather than reproducing it.
--
--  Searches columns outward from the centre so the nearest usable spot wins,
--  and checks both directions at each step because a container against a wall
--  may only be approachable from one side.
function petports_standingPointNear(position, radius)
  if position == nil then return nil end
  radius = radius or 4

  for offset = 0, radius do
    for _, dx in ipairs(offset == 0 and { 0 } or { -offset, offset }) do
      --  Tile centre. findGroundPosition only resolves the y.
      local x = math.floor(position[1] + dx) + 0.5

      local ground = findGroundPosition({ x, position[2] }, -radius, radius, false)

      if ground ~= nil and validStandingPosition(ground, false) then
        return { ground[1], ground[2] }
      end
    end
  end

  return nil
end

function petports_setVents(vents)
  local summary = {}
  for _, vent in ipairs(vents or {}) do
    local exits = {}
    for _, destination in ipairs(vent.destinations or {}) do
      table.insert(exits, destination.id)
    end
    table.insert(summary, {id = vent.id, entry = vent.entry, exits = exits})
  end

  sb.logInfo("UNIT received %s vents: %s",
    sb.printJson(#(vents or {})), sb.printJson(summary))

  self.petportsVents = vents
  return true
end

--  The vent whose far side lands nearest the target, skipping any already
--  tried on this task.
--
--  Greedy and deliberately cheap. A proper version would precompute which vents
--  are mutually reachable and compare by route rather than by straight line,
--  but that needs reachability data only units can produce -- see the handoff.


--------------------------------------------------------------------------------
--  ROUTE GRAPH, CACHE AND PROBING
--------------------------------------------------------------------------------
--
--  Routing is a graph search over VENT MOUTHS.
--
--    nodes           the unit's own position, every vent entry, every vent exit
--    teleport edges  a vent entry to each of its exits -- free, always known
--    walk edges      one node to another on foot -- PROBED, then cached
--
--  Walk edges between two vent mouths depend on TERRAIN ONLY, so they are
--  cached forever and shared with every other unit through the port. Only edges
--  involving the unit's own position or the target are query-dependent, and
--  those are keyed to the exact tile, so they are reused only when a unit is
--  genuinely standing where it stood before.
--
--  WHY A GRAPH AND NOT A SINGLE LOOKUP. An earlier version asked only "does
--  this exit reach the target?". That rejects any first hop whose exit reaches
--  only ANOTHER VENT -- which is precisely what a multi-room layout looks like.
--  The route right-lower -> left box -> left-upper -> right-upper -> item needs
--  two hops, and no single-hop question can find it.
--
--  Only units can pathfind -- objects have no mcontroller -- so units produce
--  this knowledge. Ports store and redistribute it, because ports are resident
--  whenever the network is and survive reloads, while units respawn.

function petports_setRouteCache(cache)
  local count = 0
  for _ in pairs(cache or {}) do count = count + 1 end

  sb.logInfo("UNIT received route cache with %s edges", sb.printJson(count))

  self.petportsRoutes = cache or {}
  return true
end

--  Node keys. Tile-exact for positions, entity id for vent mouths.
function petports_unitKey(position)
  return "u:" .. petports_tileKey(position)
end

function petports_targetKey(position)
  return "t:" .. petports_tileKey(position)
end

function petports_entryKey(ventId)
  return "e:" .. tostring(ventId)
end

function petports_exitKey(exitId)
  return "x:" .. tostring(exitId)
end

local function edgeKey(fromKey, toKey)
  return fromKey .. ">" .. toKey
end

--  true / false / nil for unknown.
--  HOW LONG A CACHED ANSWER IS TRUSTED.
--
--  ASYMMETRIC, DELIBERATELY. The two answers fail in completely different ways:
--
--    a stale FALSE is permanent damage. It blocks a route that now works, and
--    nothing ever re-tests it, so the unit refuses forever. Nothing in the
--    system invalidates walkability -- pruneRouteCache only drops edges naming
--    vents that no longer exist, so a player mining one tile invalidates
--    nothing at all.
--
--    a stale TRUE is self-correcting. The unit walks it, fails, and relearns on
--    the spot. The cost is one wasted attempt.
--
--  So negatives expire quickly and positives are kept. Measured motivation: a
--  session's worth of tests were poisoned by falses learned before the terrain
--  was edited, and the fix was re-placing the port to drop the cache.
local ROUTE_TTL_FALSE = 60.0
local ROUTE_TTL_TRUE = 600.0

--  Entries are { r = reachable, t = when learned }. Bare booleans from an older
--  save are treated as expired rather than trusted forever -- an unknown age on
--  a false is exactly the thing this exists to stop.
function petports_routeKnown(fromKey, toKey)
  if self.petportsRoutes == nil then return nil end

  local entry = self.petportsRoutes[edgeKey(fromKey, toKey)]
  if entry == nil then return nil end

  if type(entry) ~= "table" then return nil end

  local age = world.time() - (entry.t or 0)
  local ttl = entry.r and ROUTE_TTL_TRUE or ROUTE_TTL_FALSE

  if age > ttl then
    sb.logInfo("UNIT cache EXPIRED for %s (%s, age %s of %s) -- will re-probe",
      edgeKey(fromKey, toKey), tostring(entry.r),
      sb.printJson(age), sb.printJson(ttl))
    self.petportsRoutes[edgeKey(fromKey, toKey)] = nil
    return nil
  end

  return entry.r
end

function petports_learnRoute(fromKey, toKey, reachable, portUniqueId)
  self.petportsRoutes = self.petportsRoutes or {}
  local key = edgeKey(fromKey, toKey)

  local previous = self.petportsRoutes[key]
  local was = type(previous) == "table" and previous.r or previous

  if previous ~= nil and was ~= reachable then
    sb.logInfo("UNIT cache CONTRADICTED for %s: was %s, now %s",
      key, tostring(was), tostring(reachable))
  end

  local at = world.time()
  self.petportsRoutes[key] = { r = reachable, t = at }

  if portUniqueId then
    world.sendEntityMessage(portUniqueId, "petports_learnedRoute", {
      key = key,
      reachable = reachable,
      at = at
    })
  end
end

--  The path options a unit actually walks with.
--
--  SHARED WITH THE PROBE ON PURPOSE. A probe that searches with different
--  options than the real pather does not predict real behaviour -- and because
--  its answers are CACHED and pushed to the port, a mismatch poisons routing
--  for every future unit until something invalidates it.
--
--  The standing box is padded proportionally rather than by vanilla's flat
--  -0.7, which inverts for any body narrower than 1.4 tiles and silently
--  disables every vertical edge. See the handoff.
function petports_pathOptions()
  local bounds = mcontroller.boundBox()

  --  NO PADDING. THE PLANNER GETS THE BODY THE UNIT ACTUALLY HAS.
  --
  --  This was `math.min(0.7, halfWidth * 0.4)`, giving a standing and dropping
  --  box 0.6 wide against a real body of 1.0. That existed to dodge vanilla's
  --  flat -0.7 default, which INVERTS for anything narrower than 1.4 tiles and
  --  silently disables every vertical edge -- a real bug, and the reason this
  --  is computed rather than left to default.
  --
  --  But a narrower box is not a free safety margin, it is a LIE ABOUT THE BODY.
  --  A* validates positions and clearances with it, so it will happily plan a
  --  trajectory through a gap only the imaginary 0.6-wide unit fits through,
  --  and the real 1.0-wide one clips the corner.
  --
  --  MEASURED, mid-arc in a two-wide chute:
  --
  --    edge 19  [1213,710.75]      velocity [12,25]
  --    edge 20  [1213.63,711.374]  velocity [1.67,-3.53]
  --
  --  Total loss of momentum in one tick, 0.62 tiles of rise -- a head-on
  --  collision (airJumpProfile.collisionCancelled is true), at a point sitting
  --  ON THE PLANNER'S OWN TRAJECTORY. The planner routed the unit through
  --  geometry the movement controller hits. It then fell four tiles past its
  --  intended landing and stalled moveLand at srcDist 4.58.
  --
  --  Zero is safe against the inversion this guarded: the box equals the real
  --  bounds, so left is never right of right. What it costs is permissiveness --
  --  vanilla pads so a unit can be considered standing in a tighter spot than
  --  it strictly fits -- so expect fewer valid standing positions and, in tight
  --  terrain, occasionally no route where one was previously offered and then
  --  failed. A refused route is cheaper than a planned collision.
  --
  --  If the inversion ever needs guarding again, guard it as an assertion on
  --  the result, not by shrinking the body.
  local pad = 0

  return {
    returnBest = false,
    mustEndOnGround = true,
    maxDistance = 200,
    boundBox = bounds,
    standingBoundBox = { bounds[1] + pad, bounds[2], bounds[3] - pad, bounds[4] },
    droppingBoundBox = { bounds[1] + pad, bounds[2], bounds[3] - pad, bounds[4] },
    --  1.0, NOT 0.75. THE ACTOR CANNOT PERFORM A PARTIAL JUMP.
    --
    --  This tells A* it may plan hops at a fraction of full jump strength, and
    --  it plans arcs on that basis. The movement controller then fires every
    --  jump at FULL strength, because default_actor_movement.config sets
    --  jumpInitialPercentage 1.0 and jumpHoldTime 0.0 and the drone overrides
    --  neither -- there is no mechanism by which a weaker jump can happen.
    --
    --  MEASURED, from an arc the unit flew in a two-wide chute:
    --
    --    velocity samples fell -10 per tick at ~1/12s  ->  g = 120
    --    (world gravity 80 x gravityMultiplier 1.5, inherited from the
    --     default actor config -- confirming movementSettings are MERGED)
    --
    --    real apex   45^2 / (2*120)          = 8.44 tiles   observed 8.75
    --    planned apex from the arc edges     = 5.25 tiles
    --    velocity implied by a 5.25 arc      = 33.75 = 45 * 0.75
    --
    --  So the planner was drawing arcs for a 33.75 jump the unit answers with a
    --  45 one. It clears its own planned arc by three tiles, hits ceilings that
    --  were never in the plan, and lands where no mover can recover -- which is
    --  every stall catalogued so far: moveLand with delta[1] 4.58, moveJump at
    --  srcDist 4.03, moveArc grounded under a vertical arc.
    --
    --  Raise this only as far as the actor can actually go. If shorter hops are
    --  ever wanted, the honest place is the monstertype's airJumpProfile, so
    --  that plan and execution move together.
    smallJumpMultiplier = 1.0,
    jumpDropXMultiplier = 0.125,
    enableWalkSpeedJumps = true,
    enableVerticalJumpAirControl = true,
    maxFScore = 400,
    maxNodesToSearch = 70000,
    maxLandingVelocity = -10.0
  }
end

--  A standalone reachability probe.
--
--  PathFinder:find() hardcodes mcontroller.position() as the source, so it
--  cannot answer "is X reachable FROM somewhere else". Driving start() and
--  explore() directly can, because start takes an ARBITRARY SOURCE -- which is
--  what makes multi-leg routing possible without spawning probe entities to
--  walk around and survey.
--
--  Returns true, false, or "searching".
--  IDENTIFIED BY EDGE KEYS, NOT BY POSITION TABLES.
--
--  Comparing positions by identity looks right and is a trap: mcontroller
--  .position() and world.entityPosition() ALLOCATE A FRESH TABLE every call, so
--  `stored ~= given` is always true and the probe is rebuilt from scratch every
--  tick. It then never accumulates progress and always hits its timeout -- even
--  for edges that are trivially reachable. Comparing by value would work too,
--  but the keys are already unique and already computed.
function petports_probeStep(from, to, fromKey, toKey, exploreRate)
  if self.petportsProbe == nil
     or self.petportsProbe.fromKey ~= fromKey
     or self.petportsProbe.toKey ~= toKey then

    --  A target that is not a valid standing position is never pathfound at
    --  all -- find() checks this and so must we, since we are bypassing it.
    if self.petportsProbe ~= nil then
      sb.logInfo("UNIT probe RESTART: was %s -> %s, now %s -> %s (previous progress discarded)",
        tostring(self.petportsProbe.fromKey), tostring(self.petportsProbe.toKey),
        tostring(fromKey), tostring(toKey))
    end

    if not validStandingPosition(to, false) then
      sb.logInfo("UNIT probe %s -> %s skipped: %s is not a valid standing position",
        tostring(fromKey), tostring(toKey), sb.printJson(to))
      self.petportsProbe = nil
      return false
    end

    local finder = PathFinder:new(petports_pathOptions())
    finder.exploreRate = function() return exploreRate or 300 end
    finder:start(from, to)

    --  VALIDATE THE START, NOT JUST THE TARGET.
    --
    --  probeStep checks validStandingPosition on `to` and has never checked
    --  `from`. A probe that begins somewhere the unit cannot occupy gives A*
    --  almost nothing to expand and comes back "UNREACHABLE" in a tick or two,
    --  which is indistinguishable in the log from a genuinely small sealed
    --  region. Those need completely different fixes, so the log has to say
    --  which one it is.
    --
    --  Also reports where the nearest standable ground actually is. If `from`
    --  is invalid but ground sits a fraction of a tile away, the vent's entry
    --  position is misaligned rather than the geometry being wrong.
    local fromValid = validStandingPosition(from, false)
    local fromGround = findGroundPosition(from, -4, 4, false)

    sb.logInfo("UNIT probe START %s -> %s: from %s (standable %s, ground %s) to %s rate %s",
      tostring(fromKey), tostring(toKey), sb.printJson(from),
      tostring(fromValid), sb.printJson(fromGround),
      sb.printJson(to), sb.printJson(exploreRate or 300))

    self.petportsProbe = {
      finder = finder,
      from = from, to = to,
      fromKey = fromKey, toKey = toKey,
      ticks = 0
    }
  end

  self.petportsProbe.ticks = self.petportsProbe.ticks + 1

  local result = self.petportsProbe.finder.aStar:explore(exploreRate or 300)
  if result == true then
    sb.logInfo("UNIT probe %s -> %s REACHABLE after %s ticks",
      tostring(fromKey), tostring(toKey), sb.printJson(self.petportsProbe.ticks))
    self.petportsProbe = nil
    return true
  elseif result == false then
    sb.logInfo("UNIT probe %s -> %s UNREACHABLE after %s ticks (A* exhausted)",
      tostring(fromKey), tostring(toKey), sb.printJson(self.petportsProbe.ticks))
    self.petportsProbe = nil
    return false
  end

  return "searching"
end

--  Ask about one edge, probing if the answer is not cached.
--  Returns true, false, or "searching".
local function edgeReachable(fromPos, fromKey, toPos, toKey, portId, exploreRate)
  local known = petports_routeKnown(fromKey, toKey)
  if known ~= nil then
    sb.logInfo("UNIT edge %s -> %s answered FROM CACHE: %s",
      tostring(fromKey), tostring(toKey), tostring(known))
    return known
  end

  local result = petports_probeStep(fromPos, toPos, fromKey, toKey, exploreRate)
  if result == "searching" then return "searching" end

  petports_learnRoute(fromKey, toKey, result, portId)
  sb.logInfo("UNIT probed %s -> %s : %s", fromKey, toKey, tostring(result))
  return result
end

--  Plan a route from where the unit stands to the target, using vents.
--
--  Breadth-first over vent mouths, so the FEWEST HOPS wins. Consults the cache
--  first and issues AT MOST ONE PROBE per call -- planning is incremental
--  across ticks, and the caller keeps calling until it gets an answer.
--
--  Returns:
--    a list of legs  -- { {id, entry, destinationId, destinationPosition}, ... }
--    "probing"       -- still working it out, call again next tick
--    nil             -- no route exists within maxHops
--  `origin` FREEZES THE STARTING NODE for the duration of a planning session.
--
--  Planning from the unit's live position re-keys every `u:` edge the moment it
--  drifts to a new tile, discarding all probe work done so far and starting
--  over. Probing is measured in tens of seconds, so a unit that shifts position
--  mid-plan can burn minutes and never finish.
--
--  Freezing it also keeps the cached edges usable: the same origin tile means
--  the same keys
--  `avoid` is a set of vent ids to exclude, keyed by entity id.
--
--  The caller blacklists a vent whose mouth it could not physically reach. That
--  judgement is about walking, not wiring, so the planner cannot derive it --
--  and without it the planner cheerfully returns the same unreachable vent
--  forever. Observed as a unit replanning an identical one-hop route every
--  eight seconds until the drop despawned.
--
--  The caller was already recording this. It simply had no way to say so: there
--  was no parameter, and nothing here read one. A blacklist written in two
--  places and read in none is worse than no blacklist, because it reads as
--  handled.
function petports_planRoute(target, maxHops, portId, exploreRate, allowWalk, origin, avoid)
  local vents = self.petportsVents
  if vents == nil or #vents == 0 then
    sb.logInfo("UNIT planRoute impossible: vent list is %s",
      vents == nil and "nil (port never pushed one)" or "empty")
    return nil
  end

  local here = origin or mcontroller.position()
  local targetKey = petports_targetKey(target)

  sb.logInfo("UNIT planRoute to %s from %s (frozen origin %s), %s vents, maxHops %s, allowWalk %s",
    sb.printJson(target), sb.printJson(here), tostring(origin ~= nil),
    sb.printJson(#vents), sb.printJson(maxHops), tostring(allowWalk))

  local queue = {{
    position = here,
    key = petports_unitKey(here),
    legs = {}
  }}
  local visited = { [petports_unitKey(here)] = true }

  while #queue > 0 do
    local node = table.remove(queue, 1)

    --  Can we finish from here on foot?
    sb.logInfo("UNIT planRoute expanding node %s at %s (%s legs so far, %s queued)",
      tostring(node.key), sb.printJson(node.position),
      sb.printJson(#node.legs), sb.printJson(#queue))

    local finishes = edgeReachable(node.position, node.key, target, targetKey,
      portId, exploreRate)
    if finishes == "searching" then return "probing" end
    if finishes == true then
      if #node.legs > 0 then
        sb.logInfo("UNIT planRoute FOUND a %s-hop route to %s",
          sb.printJson(#node.legs), sb.printJson(target))
        return node.legs
      end

      --  Zero legs means the target is walkable FROM WHERE WE STAND.
      --
      --  Before any hop that is stale information -- the caller only asks after
      --  a direct walk already failed. But AFTER a hop the unit is somewhere
      --  new, and "just walk" is a fresh and usually correct answer. Observed a
      --  unit land beside its target, discard exactly this answer, plan a
      --  second hop, and take it.
      if allowWalk then
        sb.logInfo("UNIT planRoute: target walkable from %s, no hops needed",
          sb.printJson(node.position))
        return "walk"
      end

      sb.logInfo("UNIT planRoute: target walkable from %s but allowWalk is false -- continuing into vents",
        sb.printJson(node.position))
    end

    if #node.legs < maxHops then
      for _, vent in ipairs(vents) do
        local entryKey = petports_entryKey(vent.id)

        --  Excluded vents are skipped WITHOUT probing. Probing one costs up to
        --  PROBE_LIMIT and the answer is already known to be useless.
        --  A vent with no exits cannot be traversed -- it can only be arrived
        --  at. Skipping BEFORE probing matters: reaching it might cost a full
        --  PROBE_LIMIT to establish something the planner could not use.
        local traversable = vent.destinations ~= nil and #vent.destinations > 0
        local excluded = avoid ~= nil and avoid[vent.id] == true

        if not traversable or excluded or visited[entryKey] then
          sb.logInfo("UNIT planRoute skipping vent %s: %s",
            sb.printJson(vent.id),
            (not traversable) and "no exits wired (terminal)"
              or (excluded and "blacklisted this task" or "already visited"))
        end

        if traversable and not excluded and not visited[entryKey] then
          local canReach = edgeReachable(node.position, node.key,
            vent.entry, entryKey, portId, exploreRate)
          if canReach == "searching" then return "probing" end

          if canReach == true then
            visited[entryKey] = true

            --  Teleport edges are free and always known.
            for _, destination in ipairs(vent.destinations or {}) do
              local exitKey = petports_exitKey(destination.id)
              if not visited[exitKey] then
                visited[exitKey] = true

                local legs = {}
                for _, leg in ipairs(node.legs) do table.insert(legs, leg) end
                table.insert(legs, {
                  id = vent.id,
                  entry = vent.entry,
                  destinationId = destination.id,
                  destinationPosition = destination.position
                })

                table.insert(queue, {
                  position = destination.position,
                  key = exitKey,
                  legs = legs
                })
              end
            end
          end
        end
      end
    end
  end

  sb.logInfo("UNIT planRoute EXHAUSTED: no route to %s through %s vents within %s hops",
    sb.printJson(target), sb.printJson(#vents), sb.printJson(maxHops))
  return nil
end

--  Abandon the running probe and record its edge as unreachable.
--
--  A probe that has run too long is treated as a "no" for the same reason
--  SEARCH_LIMIT exists: a reachable target resolves quickly, and A* will not
--  report failure in any practical time -- an unreachable edge has to exhaust
--  70000 nodes, roughly nineteen seconds at 300 per tick.
--
--  Recording the answer is what makes planning progress. A wrong "no" is
--  self-correcting: the route it excludes is simply not offered, and the cache
--  is cleared whenever coverage changes.
function petports_probeTimeout(portId)
  if self.petportsProbe == nil then return end

  if self.petportsProbe.fromKey and self.petportsProbe.toKey then
    petports_learnRoute(self.petportsProbe.fromKey, self.petportsProbe.toKey,
      false, portId)
    sb.logInfo("UNIT probe %s -> %s TIMED OUT after %s ticks, recording unreachable (this is a guess, not an answer)",
      self.petportsProbe.fromKey, self.petportsProbe.toKey,
      sb.printJson(self.petportsProbe.ticks or 0))
  end

  self.petportsProbe = nil
end

function petports_cancelProbe()
  if self.petportsProbe ~= nil then
    sb.logInfo("UNIT probe %s -> %s CANCELLED, nothing recorded",
      tostring(self.petportsProbe.fromKey), tostring(self.petportsProbe.toKey))
  end
  self.petportsProbe = nil
end

--------------------------------------------------------------------------------
--  VISUAL DEBUG
--------------------------------------------------------------------------------
--
--  Everything world.debug* draws is per-frame, so this must be called EVERY
--  update -- a one-shot call draws a single frame nobody sees.
--
--  Visible only with debug mode enabled in game (/debug).

PETPORTS_DRAW_DEBUG = true

--  Colour by what the cache says about walking from HERE to that vent mouth.
local function reachColour(known)
  if known == true then return "green" end
  if known == false then return "red" end
  return "yellow"
end

--  Edge colours by move type, so a route reads at a glance.
local function actionColour(action)
  if action == "Jump" then return "orange" end
  if action == "Arc" then return "magenta" end
  if action == "Drop" then return "cyan" end
  if action == "Land" then return "blue" end
  return "white"
end

function petports_drawRouteDebug(stateData)
  if not PETPORTS_DRAW_DEBUG then return end

  local here = mcontroller.position()
  local unitKey = petports_unitKey(here)

  --  Every vent mouth we know about, coloured by cached reachability from the
  --  tile we are standing in.
  for _, vent in ipairs(self.petportsVents or {}) do
    local known = petports_routeKnown(unitKey, petports_entryKey(vent.id))
    local colour = reachColour(known)

    world.debugPoint(vent.entry, colour)
    world.debugText("vent %s", vent.id, {vent.entry[1], vent.entry[2] + 1.5}, colour)

    for _, destination in ipairs(vent.destinations or {}) do
      --  Teleport edge: free, always available.
      world.debugLine(vent.entry, destination.position, "blue")
      world.debugPoint(destination.position, "blue")
    end
  end

  --  What is being probed right now, and from where. This is the line that
  --  explains a long pause.
  if self.petportsProbe ~= nil then
    world.debugLine(self.petportsProbe.from, self.petportsProbe.to, "magenta")
    world.debugPoint(self.petportsProbe.from, "magenta")
    world.debugText("probing %s -> %s",
      tostring(self.petportsProbe.fromKey), tostring(self.petportsProbe.toKey),
      {here[1], here[2] + 4}, "magenta")
  end

  if stateData == nil then return end

  local task = stateData.task

  --  WHAT THIS UNIT THINKS IT IS DOING, above its head.
  --
  --  Stacked upward from the unit so the lines do not overlap each other or the
  --  route text already drawn at +3 and +4. Read bottom-up: what, where, what
  --  it is holding.
  if task ~= nil then
    local phase = "walking"
    if stateData.arrived then phase = "arrived"
    elseif stateData.viaVent ~= nil then phase = "to vent " .. tostring(stateData.viaVent.id)
    elseif stateData.routing then phase = "routing"
    end

    world.debugText("%s [%s]", tostring(task.id), phase,
      {here[1], here[2] + 5}, "yellow")

    --  Hop count only once it is doing any, so an ordinary walk stays quiet.
    if (stateData.ventHops or 0) > 0 then
      world.debugText("hop %s", tostring(stateData.ventHops),
        {here[1], here[2] + 5.75}, "yellow")
    end

    --  The manifest the port sent at dispatch. Drawn one line per stack so a
    --  mixed load is readable rather than a single run-on string.
    local offset = 6.5
    for _, entry in ipairs(task.cargo or {}) do
      world.debugText("%s", entry, {here[1], here[2] + offset}, "orange")
      offset = offset + 0.75
    end

    --  THE DEPOSIT TARGET, drawn to the CONTAINER rather than to the standing
    --  point beside it. Which crate a unit has chosen is the thing that is
    --  impossible to tell from watching it walk, and the standing point can be
    --  several tiles from the crate it belongs to.
    if task.type == "deposit" and task.containerPosition ~= nil then
      world.debugLine(here, task.containerPosition, "orange")
      world.debugPoint(task.containerPosition, "orange")
      world.debugText("deposit -> %s", tostring(task.target),
        {task.containerPosition[1], task.containerPosition[2] + 1.5}, "orange")
    end

    --  AN UPCYCLE TARGET, IN RED, because it is the one delivery that cannot be
    --  undone. Same drawing as a deposit and deliberately a different colour:
    --  watching a unit walk tells you nothing about whether it is filing cargo
    --  or feeding it to a machine, and that is the single most important thing
    --  to be able to see at a glance while this is being built.
    if task.type == "upcycle" and task.containerPosition ~= nil then
      world.debugLine(here, task.containerPosition, "red")
      world.debugPoint(task.containerPosition, "red")
      world.debugText("UPCYCLE -> %s", tostring(task.target),
        {task.containerPosition[1], task.containerPosition[2] + 1.5}, "red")
    end
  end

  --  The planned route, leg by leg.
  if stateData.plan ~= nil then
    local from = here
    for index, leg in ipairs(stateData.plan) do
      local colour = (index < stateData.planIndex) and "gray" or "green"
      world.debugLine(from, leg.entry, colour)
      world.debugText("leg %s", index, {leg.entry[1], leg.entry[2] + 2.5}, colour)
      from = leg.destinationPosition
    end
  end

  --  Where the unit is actually trying to walk.
  local walkingTo = (stateData.viaVent and stateData.viaVent.entry)
    or stateData.groundTarget
  if walkingTo ~= nil then
    world.debugLine(here, walkingTo, "white")
    world.debugPoint(walkingTo, "white")
  end

  --  THE COMPUTED PATH. Edges expose source.position, target.position and
  --  action, so the route the pathfinder actually produced can be drawn --
  --  which is what shows whether a stalled unit has no path at all or a path it
  --  cannot follow.
  local finder = self.pather and self.pather.finder
  if finder ~= nil and finder.edges ~= nil then
    for index, edge in ipairs(finder.edges) do
      if edge.source and edge.target then
        local colour = (index == finder.currentEdgeIndex)
          and "white" or actionColour(edge.action)
        world.debugLine(edge.source.position, edge.target.position, colour)
        world.debugPoint(edge.target.position, colour)
      end
    end

    --  currentEdgeIndex is a pointer into the edge list and reset() leaves it
    --  at 1 with an empty list, so "1/0" is simply "no path yet" rather than
    --  anything wrong. Say that instead of printing the raw numbers.
    if finder.hasPath and #finder.edges > 0 then
      world.debugText("edge %s of %s",
        tostring(finder.currentEdgeIndex), tostring(#finder.edges),
        {here[1], here[2] + 3}, "white")
    else
      world.debugText("no path (searching)", {here[1], here[2] + 3}, "gray")
    end
  end
end
