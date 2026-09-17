-- Monster action that carries out one port task: routing to it, working it, and reporting back.

petportsTaskAction = {}

local APPROACH_TIMEOUT = 20.0

local ARRIVAL_DISTANCE = 1.5

local TASK_DEBUG = true

local TASK_TRACE_MOVES = false

local FLIGHT_TRACE = false

local FUEL_TRACE = false

local MEDIA_TRACE_INTERVAL = 0.25

local BUILD_STAMP = "2026-09-17b scootThroughPlatform and probeBelow are exposed to the contract"
local stampLogged = false

local SEARCH_LIMIT = 6.0

local EXPLORE_RATE = 300

local NAV_LEG_EXPLORE_RATE = 1200

local SETTLE_GRACE = 2.0

local STUCK_MOVE = 0.1

local AIRBORNE_EDGE_STALL = 0.35

local ORIGIN_NUDGE_RADIUS = 2

local ORIGIN_NUDGE_ARRIVE = 0.25

local ORIGIN_NUDGE_TIMEOUT = 1.5

local WALK_EDGE_STALL = 1.25

local MAX_ARC_SKIP = 16

local PLAN_SURFACE_TOLERANCE = 0.5

local JUMP_TAKEOFF_REACH = 1.0

local JUMP_APPROACH_EPSILON = 0.05

local JUMP_LEVEL_TOLERANCE = 1.0

JUMP_APPROACH_SLOWDOWN = 2.5
JUMP_APPROACH_SPEED = 3.0

local JUMP_SWIM_CHASE = 4.0

local MAX_JUMP_LOOKAHEAD = 64

local JUMP_VELOCITY_MARGIN = 1.02

local JUMP_VELOCITY_CAP = 1.25

local NARROW_LANDING_VX = 8.0

local JUMP_ARC_CLEARANCE = 0.5

local PHYSICS_DT = 1 / 60

local LAND_BRAKE_ARRIVED = 0.05

local LAND_BRAKE_OVERRUN = 1.5

local LAND_BRAKE_STATIONARY = 0.1

local LAND_BRAKE_CEILING = 1.0

local LAND_BRAKE_STATIONARY_GAP = 0.5

-- Returns the rise a launch speed reaches under the engine's discrete integration.
local function discreteRise(v0, gravity)
  return ((v0 * v0) / (2 * gravity)) + ((v0 * PHYSICS_DT) / 2)
end

-- Returns the launch speed that reaches a rise under the engine's discrete integration.
local function discreteLaunchForRise(rise, gravity)
  local half = PHYSICS_DT / 2
  return gravity * (math.sqrt((half * half) + ((2 * rise) / gravity)) - half)
end

local PROGRESS_WINDOW = 5.0
local PROGRESS_DISTANCE = 2.5
local PROGRESS_STRIKES = 2

local HARVEST_DAMAGE = 0.2

local HARVEST_LEVEL = 1

local seedSpacesCache = {}

-- Returns a seed's occupied spaces, cached, assuming 1x2 when they cannot be read.
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

-- Returns whether any object covers the tiles a seed would occupy at an anchor.
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

local WATER_DROP_HEIGHT = 1.0

local WATER_REACH = 4.0

local MEDIC_REACH = 5.0

local FISH_REACH = 5.0

local CHASE_RETARGET_INTERVAL = 0.5

local CHASE_BUDGET = 10.0

-- Returns the first pool name inside a treasure pool value.
local function treasurePoolName(value)
  if type(value) == "string" then return value end
  if type(value) ~= "table" then return nil end

  if type(value.default) == "string" then return value.default end

  for _, entry in ipairs(value) do
    if type(entry) == "string" then return entry end

    if type(entry) == "table" then
      if type(entry.default) == "string" then return entry.default end

      for _, inner in ipairs(entry) do
        if type(inner) == "string" then return inner end
      end
    end
  end

  return nil
end

local ANIMAL_REACH = 6.0

local TRACKED_TARGETS = {
  collect = { field = "target", noun = "drop", reach = nil, moves = false },
  harvest = { field = "target", noun = "crop", reach = nil, moves = false },
  trap = { field = "target", noun = "trap", reach = nil, moves = false },
  animal = { field = "target", noun = "animal", reach = ANIMAL_REACH, moves = true },
  fish = { field = "target", noun = "fish", reach = FISH_REACH, moves = true },
  medic = { field = "target", noun = "patient", reach = MEDIC_REACH, moves = true,
            goneIsDone = true }
}

-- Returns a task's tracked entity id and its tracking row.
local function trackedEntity(task)
  local row = task ~= nil and TRACKED_TARGETS[task.type] or nil
  if row == nil then return nil, nil end
  return task[row.field], row
end

local HARVEST_REACH = 4.0

local HARVEST_TIMEOUT = 3.0

local TRAP_REACH = 4.0

local MAX_VENT_HOPS = 10

local PROBE_LIMIT = 8.0

local VENT_APPROACH_TIMEOUT = 8.0

local VENT_ARRIVAL_TOLERANCE = 6.0

local MAX_REPEAT_HOPS = 4

local MAX_TASK_HOPS = MAX_VENT_HOPS * 12

local VENT_USE_DISTANCE = 2.0

local freshPather

local NAV_LEG_REACH = 8

local NAV_FLYER_LEG_REACH = 32

local COARSE_FIRST_DISTANCE = 24
local COARSE_LOS_SET = { "Null", "Block", "Dynamic", "Slippery" }

local SIGHT_LATCH_RANGE = 64
local SIGHT_LATCH_INTERVAL = 0.5

local PLAN_REFUSED_LIMIT = 1.0

local BRUSH_BACKOFF = 0.5

local COARSE_RETRY_INTERVAL = 0.5

local NAV_LEG_ARRIVAL_FREE = 0.25

local NAV_LEG_STEP_ARRIVAL = 0.15

local NAV_LEG_ARRIVAL_THROUGH = 1.0
local NAV_LEG_SHARP_TURN = 75

local NAV_ROUTE_LOOKAHEAD = 6
local NAV_LEG_BRAKE_TURN = 45

-- Logs why tryCoarseLeg handed out no leg, once per distinct reason and pair.
local function noteLegRefusal(stateData, why, target, fromKey, toKey)
	local key = why .. "|" .. tostring(fromKey) .. "|" .. tostring(toKey) .. "|" .. sb.printJson(target)
	if stateData.navRefusalNoted == key then return end
	stateData.navRefusalNoted = key
	local here = mcontroller.position()
	sb.logInfo("UNIT coarse leg NOT taken toward %s: %s (from %s to %s, unit at %s, mode %s, medium %s, freeMover %s, onGround %s)",
		sb.printJson(target), tostring(why), tostring(fromKey), tostring(toKey), sb.printJson(here),
		tostring(petports_swimMode()), tostring(petports_mediumAt(here, mcontroller.boundBox())),
		tostring(petports_freeMover()), tostring(mcontroller.onGround()))
end

-- Asks the coarse graph for the next waypoint toward a target and starts a fresh pather on it.
local function tryCoarseLeg(stateData, target, reach, fromOverride)
  if petports_navWaypoint == nil then return false end

  reach = reach or NAV_LEG_REACH

  local switchable = petports_gravitySwitchable ~= nil and petports_gravitySwitchable()
  local profile = (switchable and petports_navBridgeProfile ~= nil
    and petports_navBridgeProfile()) or petports_navProfile()
  local freeMover = petports_freeMover()

  if not freeMover and not mcontroller.onGround() then
		noteLegRefusal(stateData, "a walker off the ground cannot start a leg", target)
		return false
	end

  local here = mcontroller.position()

  local nearRadius = freeMover and ((PETPORTS_NAV_STRIDE_FREE or 4) + 1.5) or 2.5

  local fromKey, fromMore = fromOverride, false
  if fromKey == nil then
    local key, _, _, more
    if switchable and petports_navNearestCellSide ~= nil then
      key, _, _, more = petports_navNearestCellSide(here, freeMover, nearRadius)
    else
      key, _, _, more = petports_navNearestCell(here, freeMover, nearRadius)
    end
    fromKey, fromMore = key, more
  end
  if fromMore then
		noteLegRefusal(stateData, "the nearest-cell search for the unit is still running", target)
		return false, "more"
	end

  if fromKey == nil then
    local fx, fy = petports_navCell(here)
    fromKey = petports_navCellKey(fx, fy)
  end

  local targetKey = sb.printJson(target)
  local toKey = nil

  if stateData.navToFor == targetKey then
    toKey = stateData.navToKey
  else
    local key, _, _, more
    if switchable and petports_navNearestCellSide ~= nil then
      local targetSwim = petports_mediumAtPoint(target) == "swim"
      local targetRadius = (targetSwim and ((PETPORTS_NAV_STRIDE_FREE or 4) + 1.5) or 2.5) + 0.5
      key, _, _, more = petports_navNearestCellSide(target, targetSwim, targetRadius)
    else
      key, _, _, more = petports_navNearestCell(target, freeMover, nearRadius + 0.5)
    end
    if more then
			noteLegRefusal(stateData, "the nearest-cell search for the target is still running", target, fromKey)
			return false, "more"
		end
    toKey = key

    if toKey == nil then
      local tx, ty = petports_navCell(target)
      toKey = petports_navCellKey(tx, ty)
    end

		sb.logInfo("UNIT coarse target %s resolved to cell %s%s -- target medium %s, previous target %s was cell %s",
			targetKey, tostring(toKey), key == nil and " (no graph cell in radius, its own cell)" or "",
			tostring(petports_mediumAtPoint(target)), tostring(stateData.navToFor), tostring(stateData.navToKey))

    stateData.navToFor = targetKey
    stateData.navToKey = toKey
  end

  if fromKey == toKey then
		noteLegRefusal(stateData, "the unit's cell is the target's cell", target, fromKey, toKey)
		return false
	end

  if freeMover and reach == NAV_LEG_REACH then reach = NAV_FLYER_LEG_REACH end

  local waypoint, remaining, legCell, legHops, legFrom, legPrev, legKind =
    petports_navWaypoint(profile, fromKey, toKey, reach, freeMover,
      ARRIVAL_DISTANCE + 0.5, (stateData.navStepFor or 0) < 2)

  if waypoint == nil and remaining == "more" then
		noteLegRefusal(stateData, "the route search is still running", target, fromKey, toKey)
		return false, "more"
	end

  if waypoint == nil then
    local pairKey = fromKey .. ">" .. toKey
    if stateData.navNoLegFor ~= pairKey then
      stateData.navNoLegFor = pairKey
      local why = petports_navWhyNoRoute ~= nil
        and petports_navWhyNoRoute(profile, fromKey, toKey) or "unknown"
      if self.petportsNavLastRoute ~= nil then self.petportsNavLastRoute.why = why end
      sb.logInfo("UNIT coarse nav has no leg from %s to %s -- %s", fromKey, toKey, tostring(why))
    end
    return false
  end

  if legKind == "step" then
    stateData.navStepFor = (stateData.navStepFor or 0) + 1
    local gap = world.magnitude(waypoint, mcontroller.position())
    if gap <= NAV_LEG_ARRIVAL_FREE then
      sb.logInfo("UNIT NUDGE %s onto the route at %s (%s tiles, picker step) and re-taking the leg",
        sb.printJson(mcontroller.position()), sb.printJson(waypoint),
        sb.printJson(math.floor(gap * 100 + 0.5) / 100))
      mcontroller.setPosition(waypoint)
      mcontroller.setVelocity({ 0, 0 })
      stateData.coarseFirstFor = nil
      return tryCoarseLeg(stateData, target, reach, legFrom)
    end
  elseif world.magnitude(waypoint, mcontroller.position()) < ARRIVAL_DISTANCE then
    if legCell ~= nil and legCell ~= fromKey then
      sb.logInfo("UNIT coarse leg %s is where we already are -- taking the next leg from %s",
        sb.printJson(waypoint), tostring(legCell))
      return tryCoarseLeg(stateData, target, reach, legCell)
    end
    sb.logInfo("UNIT coarse leg %s is where we already are -- declining",
      sb.printJson(waypoint))
    return false
  end

  sb.logInfo("UNIT coarse leg from %s to %s: heading for %s, %s hop(s) left%s -- target %s, mode %s, freeMover %s, body at %s",
    fromKey, toKey, sb.printJson(waypoint), sb.printJson(remaining),
    legKind == "step" and " (a step onto the route)" or "",
		sb.printJson(target), tostring(petports_swimMode()), tostring(freeMover),
		sb.printJson(mcontroller.position()))

	stateData.navRefusalNoted = nil

  stateData.navWaypoint = waypoint
  stateData.navRemaining = remaining
  stateData.navLegArrived = nil
  stateData.navLegStart = mcontroller.position()
  stateData.navLegStep = (legKind == "step") or nil
  stateData.navLegFrom = legFrom
  stateData.navLegTo = legCell
  stateData.navLegPrev = legPrev
  stateData.navLegHops = legHops
  stateData.navLegNext = self.petportsNavLastRoute and self.petportsNavLastRoute.nextAnchor or nil
  stateData.navLegReach = reach

  local bridge = self.petportsNavLastRoute and self.petportsNavLastRoute.bridge or nil
  stateData.navBridge = bridge
  self.petportsLegBridge = bridge
  self.petportsLegSide = bridge and bridge.toSide or (freeMover and 1 or 0)
	self.petportsLegWaypoint = waypoint

  if bridge ~= nil then
    sb.logInfo("UNIT coarse leg is a %s bridge %s -> %s (side %s)",
      tostring(bridge.k), tostring(bridge.from), tostring(bridge.to), tostring(bridge.toSide))

    if bridge.k == "dive" and bridge.board ~= nil and bridge.hole ~= nil then
      self.petportsDiveEntry = { bridge.hole[1], bridge.hole[2] }
      self.petportsDivePlan = {
        taskId = stateData.task and stateData.task.id or nil,
        launch = { bridge.board[1], bridge.board[2] },
        entry = { bridge.hole[1], bridge.hole[2] },
        route = true
      }
    end
  end

  stateData.searchingTimer = 0
  stateData.approachTimer = APPROACH_TIMEOUT
  stateData.groundTarget = nil

  freshPather("coarse leg")

  return true
end

-- Takes the next leg of a vent plan, or plans one, returning routing, probing, walk or none.
local function tryVentRoute(stateData, target)
  if petports_planRoute == nil then return "none" end


  if stateData.viaVent ~= nil then return "routing" end

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

    petports_probeTimeout(stateData.task.port)
    stateData.probeTimer = 0
    return "probing"
  end

  if plan == "walk" then
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

  return "routing"
end

-- Returns whether the unit's body overlaps a vent's bounds.
function petportsTaskAction.touchingVent(ventId)
  local ok, ventRect = pcall(objectBounds, ventId)

  if not ok or type(ventRect) ~= "table" or type(ventRect[1]) ~= "number" then
    return world.magnitude(mcontroller.position(), world.entityPosition(ventId))
      <= VENT_USE_DISTANCE
  end

  local me = rect.translate(mcontroller.boundBox(), mcontroller.position())

  return not (me[1] > ventRect[3] or me[3] < ventRect[1]
           or me[2] > ventRect[4] or me[4] < ventRect[2])
end

-- Returns the task state data, refusing a task with no position or a tracked target already gone.
function petportsTaskAction.enterWith(args)
  local task = args.petportsTask
  if task == nil then return nil end
  if task.position == nil then return nil end

  local trackedId, trackedRow = trackedEntity(task)
  if trackedId ~= nil and not trackedRow.goneIsDone
     and not world.entityExists(trackedId) then
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
    dwellTimer = task.dwell
      or ((task.type == "harvest") and HARVEST_TIMEOUT)
      or (TRACKED_TARGETS[task.type] ~= nil and TRACKED_TARGETS[task.type].reach ~= nil
          and CHASE_BUDGET)
      or 3.0,
    arrived = false,
    searchingTimer = 0,
    settleTimer = 0,

    viaVent = nil,
    ventLegStarted = false,
    planOrigin = nil,
    routing = false,
    routingTried = false,
    probeTimer = 0,
    plan = nil,
    planIndex = 1,
    progressTimer = 0,
    progressAnchor = mcontroller.position(),
    progressStrikes = 0,
    ventHops = 0,
    triedVents = {},
    hopSeen = {},

    startPosition = mcontroller.position(),
    lastPosition = mcontroller.position(),
    traceTimer = 1.0,
    movedTotal = 0
  }
end

-- Walks the pather at the scaled speed, slowing on the approach to a jump point.
function petportsWalkMover(pather)
  local finder = pather.finder
  local ahead = finder ~= nil and finder.lookAhead and finder:lookAhead(1) or nil

  pather.controlParameters.walkSpeed =
    petports_scaledSpeed(mcontroller.baseParameters().walkSpeed)
  pather.controlParameters.runSpeed =
    petports_scaledSpeed(mcontroller.baseParameters().runSpeed)

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

-- Returns the highest target height across the upcoming arc edges.
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

-- Returns the position of the first non-arc edge after the current one.
local function plannedLanding(pather)
  local finder = pather.finder
  local edges = finder and finder.edges
  local index = finder and finder.currentEdgeIndex
  if edges == nil or index == nil then return nil end

  for i = index + 1, math.min(index + MAX_JUMP_LOOKAHEAD, #edges) do
    local edge = edges[i]
    if edge == nil then return nil end

    if edge.action ~= "Arc" then
      return edge.target and edge.target.position
    end
  end

  return nil
end


local ARC_DESCENT_SOLIDS = { "Null", "Block", "Slippery", "Dynamic", "Platform" }

-- Steps an arc through the physics timestep and returns where the body first hits terrain.
local function arcHitsTerrain(source, vx, vy, gravity, airtime, landing)
	if gravity == nil or gravity <= 0 then return nil end

	local x, y = source[1], source[2]
	local v = vy

	local steps = math.ceil((airtime or 1) / PHYSICS_DT) + 2

	for i = 1, steps do
		v = v - gravity * PHYSICS_DT
		x = x + vx * PHYSICS_DT
		y = y + v * PHYSICS_DT

		if landing ~= nil and v < 0 and y <= landing[2] then
			return nil
		end

		local movedX = x - source[1]
		local movedY = y - source[2]

		local set = (v < 0) and ARC_DESCENT_SOLIDS or nil

		if (movedX * movedX) + (movedY * movedY) > 0.25
		   and petports_bodyHitsAt({ x, y }, set) then
			return { x, y }, i
		end
	end

	return nil
end

-- Logs whether a solved arc is clear, when flight tracing is on.
local function traceLaunchTerrain(source, vx, vy, gravity, landing, airtime)
	if not FLIGHT_TRACE then return end
	if gravity == nil or gravity <= 0 then return end

	local hit, step = arcHitsTerrain(source, vx, vy, gravity, airtime, landing)

	if hit == nil then
		sb.logInfo("UNIT TRACE-A solved arc is CLEAR -- nothing between %s and "
			.. "%s obstructs it", sb.printJson(source), sb.printJson(landing))
		return
	end

	sb.logInfo("UNIT TRACE-A solved arc hits terrain at step %s (t %s) at "
		.. "[%s,%s] -- intended landing %s at t %s. dx travelled %s of %s",
		sb.printJson(step), sb.printJson(step * PHYSICS_DT),
		sb.printJson(hit[1]), sb.printJson(hit[2]), sb.printJson(landing),
		sb.printJson(airtime), sb.printJson(hit[1] - source[1]),
		sb.printJson(landing and (landing[1] - source[1])))
end

-- Returns whether either tile beside a landing is unstandable.
local function landingIsNarrow(landing)
	for _, side in ipairs({ -1, 1 }) do
		local ok, standable = pcall(validStandingPosition,
			{ landing[1] + side, landing[2] }, false)
		if not ok or not standable then return true end
	end
	return false
end

-- Returns a launch velocity that clears terrain and arrives descending at the planned landing, or the planner's own.
local function solveLaunch(pather, edge, source)
  local plannedVx = edge.jumpVelocity[1]
  local plannedVy = edge.jumpVelocity[2]

  local landing = plannedLanding(pather)
  if landing == nil then return plannedVx, plannedVy, nil end

  local parameters = mcontroller.baseParameters()
  local gravity = world.gravity(source) * (parameters.gravityMultiplier or 1.0)
  if gravity <= 0 then return plannedVx, plannedVy, nil end

  local dx = landing[1] - source[1]
  local dy = landing[2] - source[2]

  local apex = plannedApex(pather)
  local planRise = apex and (apex - source[2]) or 0

  local vx, vy, time, branch

  local narrow = landingIsNarrow(landing)

  if not narrow and plannedVx ~= 0 and dx ~= 0 and ((dx > 0) == (plannedVx > 0)) then
    local t = math.abs(dx) / math.abs(plannedVx)

    if dy < 0.5 * gravity * t * (t + PHYSICS_DT) then
      local candidate = (dy / t) + (0.5 * gravity * (t - PHYSICS_DT))

      if candidate > 0
         and discreteRise(candidate, gravity) >= dy + JUMP_ARC_CLEARANCE then

        local hit = arcHitsTerrain(source, plannedVx, candidate, gravity, t,
          landing)

        if hit == nil then
          vx, vy, time, branch = plannedVx, candidate, t, "kept vx"
        else
          sb.logInfo("UNIT launch REFUSED kept-vx: solved [%s,%s] would hit "
            .. "terrain at %s before reaching %s", sb.printJson(plannedVx),
            sb.printJson(candidate), sb.printJson(hit), sb.printJson(landing))
        end
      end
    end
  end

  if branch == nil then
    local rise = math.max(planRise, dy + JUMP_ARC_CLEARANCE, JUMP_ARC_CLEARANCE)

    if narrow and plannedVx ~= 0 and dx ~= 0 then
      local ceiling = nil
      local okJump, jumpSpeed = pcall(function()
        return mcontroller.baseParameters().airJumpProfile.jumpSpeed
      end)
      if okJump then ceiling = tonumber(jumpSpeed) end

      local tallRise = rise
      for _ = 1, 12 do
        local tryVy = discreteLaunchForRise(tallRise, gravity) * JUMP_VELOCITY_MARGIN
        if ceiling ~= nil and tryVy > ceiling then break end
        local tb = tryVy + ((gravity * PHYSICS_DT) / 2)
        local tdisc = (tb * tb) - (2 * gravity * dy)
        if tdisc < 0 then break end
        local tt = (tb + math.sqrt(tdisc)) / gravity
        if tt > 0 and math.abs(dx / tt) <= NARROW_LANDING_VX then
          rise = tallRise
          branch = "tall arc for a narrow landing"
          break
        end
        tallRise = tallRise + 0.5
      end
    end

    vy = discreteLaunchForRise(rise, gravity) * JUMP_VELOCITY_MARGIN

    local b = vy + ((gravity * PHYSICS_DT) / 2)
    local disc = (b * b) - (2 * gravity * dy)
    if disc < 0 then return plannedVx, plannedVy, nil end

    time = (b + math.sqrt(disc)) / gravity
    if time <= 0 then return plannedVx, plannedVy, nil end

    vx = dx / time
    if branch == nil then branch = "lowered vx" end
  end

  if math.abs(vx) > math.abs(plannedVx) then
    vx = math.abs(plannedVx) * (vx > 0 and 1 or -1)
  end
  if plannedVy > 0 then
    vy = math.min(vy, plannedVy * JUMP_VELOCITY_CAP)
  end

  local finalHit = arcHitsTerrain(source, vx, vy, gravity, time, landing)

  if finalHit ~= nil then
    sb.logInfo("UNIT launch REFUSED %s: solved [%s,%s] would hit terrain at "
      .. "%s -- flying the planner's own [%s,%s] instead",
      tostring(branch), sb.printJson(vx), sb.printJson(vy),
      sb.printJson(finalHit), sb.printJson(plannedVx), sb.printJson(plannedVy))

    return plannedVx, plannedVy, nil
  end

  return vx, vy, {
    branch = branch,
    landing = landing,
    dx = dx,
    dy = dy,
    time = time,
    apex = discreteRise(vy, gravity),
    planApex = planRise,
    gravity = gravity
  }
end

local DROP_HOLD_MAX = 0.5

local DROP_FLOOR_MARGIN = 0.05

local DROP_DESCENT_EPSILON = 0.35

local MIN_DROP_DISTANCE = 0.5


local DROP_PROBE_DEPTH = 6

local PROBE_EPSILON = 0.001

-- Returns the surface height of the first platform below the feet and above a floor.
local function platformToPass(position, floorFeet)
  local bounds = mcontroller.boundBox()
  local feet = position[2] + bounds[2]

  local first = math.floor(feet + PROBE_EPSILON) - 1

  for row = first, first - DROP_PROBE_DEPTH, -1 do
    local surface = row + 1

    if surface <= floorFeet + PROBE_EPSILON then break end

    local region = { position[1] + bounds[1], row,
                     position[1] + bounds[3], row + 1 }

    if world.rectTileCollision(region, {"Platform"}) then
      return surface
    end
  end

  return nil
end

-- Returns a printable list of the platform and block rows below a position.
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

local DROP_SCOOT = 0.25

local DROP_ORIGIN_TOLERANCE = 0.35

local DROP_SETTLE_MAX = 1.0

-- Returns the surface height of the lowest platform below the feet and above a floor.
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

-- Returns whether the body clears solid tiles with its feet at a height.
local function bodyFitsWithFeetAt(position, feet)
  local bounds = mcontroller.boundBox()
  local centre = feet - bounds[2]
  local region = { position[1] + bounds[1], centre + bounds[2],
                   position[1] + bounds[3], centre + bounds[4] }

  return not world.rectTileCollision(region, {"Null", "Block", "Dynamic"})
end

-- Places the body just below the platform it is standing on, and returns whether it could.
local function scootThroughPlatform(pather, floorFeet)
  local position = mcontroller.position()
  local surface = lastPlatformToPass(position, floorFeet)

  if surface == nil then
    return false, "no platform above the floor to pass"
  end

  local feetNow = position[2] + mcontroller.boundBox()[2]
  local standingGap = math.abs(feetNow - surface)

  if standingGap > DROP_ORIGIN_TOLERANCE then
    return false, string.format(
      "feet at %s are %s from the surface %s we would pass -- not standing on it, "
      .. "a placement here would cross %s tiles of geometry unchecked",
      sb.printJson(feetNow), sb.printJson(standingGap),
      sb.printJson(surface), sb.printJson(standingGap))
  end

  local feet = nil
  local offset = DROP_SCOOT

  while offset <= DROP_SETTLE_MAX + PROBE_EPSILON do
    local candidate = surface - offset

    if bodyFitsWithFeetAt(position, candidate) then
      feet = candidate
      break
    end

    offset = offset + DROP_SCOOT
  end

  if feet == nil then
    return false, string.format(
      "no feet height between %s and %s clears solid tiles",
      sb.printJson(surface - DROP_SCOOT), sb.printJson(surface - DROP_SETTLE_MAX))
  end

  local was = position[2]
  mcontroller.setPosition({ position[1], feet - mcontroller.boundBox()[2] })

  return true, string.format("%s -> %s (through surface %s, settled %s below it)",
    sb.printJson(was), sb.printJson(mcontroller.position()[2]),
    sb.printJson(surface), sb.printJson(surface - feet))
end

petports_scootThroughPlatform = scootThroughPlatform
petports_probeBelow = probeBelow

-- Scoots through the platform underfoot, or falls back to holding down for a timed drop.
function petportsTimedDrop(pather, time)
  local delta = pather.delta
  local descent = (delta ~= nil and delta[2] ~= nil) and -delta[2] or 0

  if descent < MIN_DROP_DISTANCE then
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

  local scooted, why = scootThroughPlatform(pather, floorFeet)

  if scooted then
    pather.downHoldTimer = nil
    pather.petportsDropOrigin = nil
    pather.petportsDropFloor = nil
    pather.petportsDropFloorFeet = nil

    sb.logInfo("UNIT drop SCOOTED %s for a %s tile descent", why,
      sb.printJson(descent))
    return
  end

  sb.logInfo("UNIT drop scoot refused (%s) -- falling back to controlDown", why)

  pather.downHoldTimer = math.min(time or 0, DROP_HOLD_MAX)
  pather.petportsDropOrigin = mcontroller.position()[2]

  pather.petportsDropFloor = pather.petportsDropOrigin - descent

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

-- Clears the drop hold state.
local function releaseDrop(pather)
  pather.downHoldTimer = nil
  pather.petportsDropOrigin = nil
  pather.petportsDropFloor = nil
  pather.petportsDropFloorFeet = nil
end

-- Holds down until no platform remains above the floor, the floor is reached, or the hold expires.
function petportsKeepDropping(pather, dt)
  if pather.downHoldTimer == nil then return end

  local y = mcontroller.position()[2]
  local origin = pather.petportsDropOrigin or y
  local floor = pather.petportsDropFloor

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

  if floor ~= nil and y <= floor + DROP_FLOOR_MARGIN then
    sb.logInfo("UNIT drop reached floor %s at y %s (fell %s) -- floor backstop, "
      .. "the platform test should have released first",
      sb.printJson(floor), sb.printJson(y), sb.printJson(origin - y))

    releaseDrop(pather)
    return
  end

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

-- Walks or swims back to the jump point, then launches on the solved velocity.
function petportsJumpMover(pather)
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
    if mcontroller.onGround() then
      local toSource = source[1] - mcontroller.position()[1]
      local levelGap = math.abs(source[2] - mcontroller.position()[2])

      if levelGap >= JUMP_LEVEL_TOLERANCE then
        if not pather.petportsWrongLevel then
          pather.petportsWrongLevel = true
          sb.logInfo("UNIT jump source %s is %s tiles off our level (at %s) -- not walkable, waiting for replan",
            sb.printJson(source), sb.printJson(levelGap),
            sb.printJson(mcontroller.position()))
        end

        return "running"
      end

      pather.petportsWrongLevel = nil

      if math.abs(toSource) >= JUMP_APPROACH_EPSILON then
        mcontroller.controlMove(toSource > 0 and 1 or -1, false)

        if not pather.petportsWalkingToJump then
          pather.petportsWalkingToJump = true
          sb.logInfo("UNIT walking back to jump point %s from %s (gap %s)",
            sb.printJson(source), sb.printJson(mcontroller.position()),
            sb.printJson(gap))
        end
      end

    elseif not petports_freeMover()
           and gap <= JUMP_SWIM_CHASE then
      local medium = petports_mediumAt(mcontroller.position())

      if medium == "swim" or medium == "mixed" then
        local delta = world.distance(source, mcontroller.position())
        local length = math.sqrt(delta[1] * delta[1] + delta[2] * delta[2])

        if length > 0.0001 then
          local force = mcontroller.baseParameters().liquidJumpProfile.jumpControlForce

          mcontroller.controlApproachVelocity(
            { delta[1] / length * JUMP_APPROACH_SPEED,
              delta[2] / length * JUMP_APPROACH_SPEED }, force)
        end

        if not pather.petportsSwimmingToJump then
          pather.petportsSwimmingToJump = true
          sb.logInfo("UNIT swimming back to jump point %s from %s (gap %s, medium %s)",
            sb.printJson(source), sb.printJson(mcontroller.position()),
            sb.printJson(gap), tostring(medium))
        end
      end
    end

    return "running"
  end

  pather.petportsWalkingToJump = nil
  pather.petportsSwimmingToJump = nil
  pather.petportsWrongLevel = nil

  if not pather.jumpTimer then
    pather.jumpTimer = 0.2
    mcontroller.setPosition(source)
    mcontroller.setVelocity({0, 0})

    sb.logInfo("UNIT takeoff from %s, jumpVel %s (approached to %s)",
      sb.printJson(source), sb.printJson(edge.jumpVelocity), sb.printJson(gap))

    local planFinder = pather.finder
    local planEdges = (planFinder and planFinder.edges) or {}
    local planIndex = (planFinder and planFinder.currentEdgeIndex) or 0
    local planParams = mcontroller.baseParameters()
    local planGravity = world.gravity(source) * (planParams.gravityMultiplier or 1.0)
    local nominalRise = nil
    if planGravity > 0 then
      nominalRise = (edge.jumpVelocity[2] * edge.jumpVelocity[2]) / (2 * planGravity)
    end

    sb.logInfo("UNIT ARCPLAN takeoff %s jumpVel %s: g %s, nominal rise %s, physics apex %s, planner apex %s",
      sb.printJson(source), sb.printJson(edge.jumpVelocity),
      sb.printJson(planGravity), sb.printJson(nominalRise),
      sb.printJson(nominalRise and (source[2] + nominalRise)),
      sb.printJson(plannedApex(pather)))

    local plannedTop = plannedApex(pather)
    if plannedTop ~= nil and nominalRise ~= nil then
      local physicsTop = source[2] + nominalRise
      local overshoot = physicsTop - plannedTop

      if overshoot > PLAN_SURFACE_TOLERANCE then
        sb.logInfo("UNIT ARCPLAN VERDICT: planner apex %s is %s tiles BELOW what a %s jump delivers (%s). "
          .. "The plan's Land is on the ASCENDING crossing -- solveLaunch will lower the launch to arrive descending.",
          sb.printJson(plannedTop), sb.printJson(overshoot),
          sb.printJson(edge.jumpVelocity[2]), sb.printJson(physicsTop))
      else
        sb.logInfo("UNIT ARCPLAN VERDICT: planner apex %s vs physics %s, difference %s -- plan is self-consistent",
          sb.printJson(plannedTop), sb.printJson(physicsTop), sb.printJson(overshoot))
      end
    end

    for i = planIndex + 1, math.min(planIndex + MAX_JUMP_LOOKAHEAD, #planEdges) do
      local planEdge = planEdges[i]
      if planEdge == nil then break end

      sb.logInfo("UNIT ARCPLAN   edge %s %s src %s vel %s -> dst %s vel %s",
        tostring(i), tostring(planEdge.action),
        sb.printJson(planEdge.source and planEdge.source.position),
        sb.printJson(planEdge.source and planEdge.source.velocity),
        sb.printJson(planEdge.target and planEdge.target.position),
        sb.printJson(planEdge.target and planEdge.target.velocity))

      if planEdge.action ~= "Arc" then break end
    end
  end

  pather.deltaX = edge.jumpVelocity[1]

  if mcontroller.liquidMovement() or pather.jumpTimer <= 0 then
    pather.controlParameters.airFriction = 0
    pather.controlParameters.liquidFriction = 0
    pather.controlParameters.liquidImpedance = 0
    pather.controlParameters.groundFriction = 0

    local vx, vy, solved = solveLaunch(pather, edge, source)

    if solved ~= nil then
      sb.logInfo("UNIT launch %s: plan [%s,%s] -> [%s,%s], landing %s (dx %s dy %s), "
        .. "apex %s vs plan %s, airtime %s",
        tostring(solved.branch),
        sb.printJson(edge.jumpVelocity[1]), sb.printJson(edge.jumpVelocity[2]),
        sb.printJson(vx), sb.printJson(vy),
        sb.printJson(solved.landing), sb.printJson(solved.dx), sb.printJson(solved.dy),
        sb.printJson(solved.apex), sb.printJson(solved.planApex),
        sb.printJson(solved.time))
    else
      sb.logInfo("UNIT launch UNSOLVED -- flying the plan's own [%s,%s]",
        sb.printJson(vx), sb.printJson(vy))
    end

    mcontroller.setVelocity({vx, vy})

    if FLIGHT_TRACE then
      local traceParams = mcontroller.baseParameters()
      local traceGravity = world.gravity(source)
        * (traceParams.gravityMultiplier or 1.0)

      traceLaunchTerrain(source, vx, vy, traceGravity,
        solved and solved.landing, solved and solved.time)

      self.petportsLaunchSolve =
      {
        source = { source[1], source[2] },
        vx = vx,
        vy = vy,
        gravity = traceGravity,
        landing = solved and solved.landing,
        airtime = solved and solved.time
      }
    end

    pather.deltaX = vx

    pather.petportsLaunch = {
      vx = vx,
      plannedVx = edge.jumpVelocity[1],
      jumpIndex = pather.finder and pather.finder.currentEdgeIndex
    }

    pather.petportsLanding = nil

    pather.jumpTimer = nil
    pather:advancePath()
  else
    pather.jumpTimer = pather.jumpTimer - script.updateDt()
  end

  return "running"
end

-- Flies an arc, killing horizontal velocity once it arrives over the planned landing.
function petportsArcMover(pather)
  pather.jumped = false
  pather.jumpCooldown = 0.3

  while pather.edge and pather.edge.action == "Arc" do
    if passedTarget(pather.edge) then
      pather:advancePath()
    else
      break
    end
  end

  if not pather.edge or pather.edge.action ~= "Arc" then
    return "running"
  end

  local here = mcontroller.position()
  local vel = mcontroller.velocity()

  if mcontroller.onGround() and not mcontroller.liquidMovement() then
    local nextEdge = pather.finder:lookAhead(1) or {}

    if nextEdge.action and nextEdge.action ~= "Arc" then
      sb.logInfo("UNIT ARCMOVER grounded at %s holding the last arc edge, next is %s -- advancing",
        sb.printJson(here), tostring(nextEdge.action))

      pather.arcDelta = nil

      pather.petportsLaunch = nil
      pather.petportsLanding = nil

      pather:advancePath()
      return "running"
    end

    if not pather.petportsArcGrounded then
      pather.petportsArcGrounded = true

      sb.logInfo("UNIT ARCMOVER grounded on an arc at %s vel %s (%s): edge src %s dst %s, next edge %s, "
        .. "vanilla would have latched arcDelta %s and driven it at runSpeed -- issuing NO control",
        sb.printJson(here), sb.printJson(vel),
        vel[2] > 0 and "RISING, expected once per takeoff" or "NOT RISING, this arc is over",
        sb.printJson(pather.edge.source and pather.edge.source.position),
        sb.printJson(pather.edge.target and pather.edge.target.position),
        tostring(nextEdge.action),
        sb.printJson(pather.delta and pather.delta[1]))
    end

    return "running"
  end

  if pather.petportsArcGrounded then
    sb.logInfo("UNIT ARCMOVER airborne again at %s vel %s -- clearing grounded latch",
      sb.printJson(here), sb.printJson(vel))
  end

  local landing = plannedLanding(pather)
  local ahead = nil

  if landing ~= nil then
    if math.abs(vel[1]) < LAND_BRAKE_STATIONARY then
      local gap = math.abs(landing[1] - here[1])
      ahead = (gap <= LAND_BRAKE_STATIONARY_GAP) and 0 or gap
    else
      ahead = (landing[1] - here[1]) * ((vel[1] > 0) and 1 or -1)
    end
  end

  if landing ~= nil and not pather.petportsLanding and vel[2] < 0
    and ahead <= LAND_BRAKE_ARRIVED
    and ahead >= -LAND_BRAKE_OVERRUN
    and here[2] <= landing[2] + LAND_BRAKE_CEILING then

    pather.petportsLanding = true
    mcontroller.setVelocity({ 0, vel[2] })

    sb.logInfo("UNIT ARCMOVER arrived at landing %s from %s vel %s (ahead %s) -- killing horizontal "
      .. "velocity so the unit does not slide off it",
      sb.printJson(landing), sb.printJson(here), sb.printJson(vel),
      sb.printJson(ahead))
  end

  if landing ~= nil and not pather.petportsLanding and vel[2] < 0
    and math.abs(vel[1]) < LAND_BRAKE_STATIONARY
    and ahead > LAND_BRAKE_ARRIVED
    and pather.petportsShortOf ~= landing[1] then

    pather.petportsShortOf = landing[1]

    sb.logInfo("UNIT ARCMOVER NOT arrived at landing %s from %s vel %s -- motionless but %s "
      .. "tiles short horizontally (gap limit %s); descending past it rather than latching",
      sb.printJson(landing), sb.printJson(here), sb.printJson(vel),
      sb.printJson(ahead), sb.printJson(LAND_BRAKE_STATIONARY_GAP))
  end

  if pather.petportsLanding then
    mcontroller.controlApproachXVelocity(0, mcontroller.baseParameters().groundForce)
    return "running"
  end

  pather.petportsArcGrounded = nil
  pather.arcDelta = nil

  pather.controlParameters.airFriction = 0
  pather.controlParameters.liquidFriction = 0
  pather.controlParameters.liquidImpedance = 0
  pather.controlParameters.groundFriction = 0

  local velocity = pather.edge.source.velocity or pather.edge.target.velocity or {0, 0}

  local launch = pather.petportsLaunch
  if launch ~= nil and launch.plannedVx == 0 then
    local wantVx = velocity[1] or 0

    if wantVx ~= 0 and math.abs(wantVx) > math.abs(vel[1]) then
      if pather.petportsSteering ~= wantVx then
        pather.petportsSteering = wantVx
        sb.logInfo("UNIT ARCMOVER steering to plan vx %s at %s (have %s) -- vertical-launch arc, "
          .. "acquiring the horizontal the plan turns on at its apex",
          sb.printJson(wantVx), sb.printJson(here), sb.printJson(vel[1]))
      end

      mcontroller.controlApproachXVelocity(wantVx, mcontroller.baseParameters().airForce)
    end
  end

  if mcontroller.liquidMovement() then
    if velocity[2] ~= 0 then
      mcontroller.controlApproachYVelocity(velocity[2],
        mcontroller.baseParameters().airJumpProfile.jumpControlForce)
    else
      pather:advancePath()
    end
  end

  return "running"
end

-- Builds a new pather with this chassis's path options and movers.
freshPather = function(why)
  if petports_gravitySwitchable() then
    petports_setSwimMode(
      petports_desiredSwimMode(petports_currentTaskDestination()), why)
  end

  local options = petports_pathOptions()
  options.run = false

  if why == "coarse leg" and PETPORTS_NAV_MAX_DISTANCE ~= nil then
    options.maxDistance = PETPORTS_NAV_MAX_DISTANCE
  end

  self.petportsPatherBuilds = (self.petportsPatherBuilds or 0) + 1
  sb.logInfo("UNIT freshPather #%s at %s: %s (mode %s, freeMover %s, onGround %s)",
    sb.printJson(self.petportsPatherBuilds),
    sb.printJson(mcontroller.position()),
    tostring(why or "no reason given"),
		tostring(petports_swimMode()), tostring(petports_freeMover()),
		tostring(mcontroller.onGround()))

  if TASK_DEBUG then
    sb.logInfo("UNIT pather boundBox %s standingBoundBox %s",
      sb.printJson(options.boundBox), sb.printJson(options.standingBoundBox))
  end

  self.pather = PathMover:new({
    run = false,
    pathOptions = options
  })

  self.petportsExploreCalls = 0
  self.petportsExploreRate = (why == "coarse leg") and NAV_LEG_EXPLORE_RATE
    or EXPLORE_RATE
  -- Returns the explore rate, counting the calls.
  self.pather.finder.exploreRate = function()
    self.petportsExploreCalls = (self.petportsExploreCalls or 0) + 1
    return self.petportsExploreRate or EXPLORE_RATE
  end

  self.pather.finder.canPathfind = petportsCanPathfind
  self.pather.finder.start = petportsPathStart

  self.pather.moveJump = petportsJumpMover
  self.pather.moveWalk = petportsWalkMover
  self.pather.moveArc = petportsArcMover

  self.pather.moveSwim = petportsFreeMover

  self.pather.timedDrop = petportsTimedDrop
  self.pather.keepDropping = petportsKeepDropping
end

-- Builds a new pather.
function petports_freshPather(why)
  return freshPather(why)
end

-- Logs the build stamp once and builds a fresh pather for the task.
function petportsTaskAction.enteringState(stateData)
  if not stampLogged then
    stampLogged = true
    sb.logInfo("PETPORTS taskAction build: %s", BUILD_STAMP)
  end

  sb.logInfo("UNIT entering task state for %s at %s",
    tostring(stateData.task.id), sb.printJson(mcontroller.position()))

  freshPather("entering task state for")

end

local TASK_MOVING_DISTANCE = 2.0

local TASK_MOVING_INTERVAL = 0.2

-- Sends a task outcome to the port and drops the held task.
local function report(stateData, outcome, reason, cargo, retry)
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
      retry = retry == true,
      watered = task.watered,

      dosed = task.dosed,
      target = task.target,

      unit = entity.uniqueId()
    })
  end

  if self.petportsTask ~= nil and task ~= nil
     and self.petportsTask.id == task.id then
    self.petportsTask = nil
  end
end


local STANDABLE_TILE_SET = { "Block", "Slippery", "Platform" }

local GROUND_SEARCH_DOWN = -6
local GROUND_SEARCH_UP = 4

local COLUMN_RADIUS = 3

local columnCache = {}

-- Returns the column offsets out to a radius, nearest first, cached.
local function columnsFor(radius)
	radius = math.floor(radius or COLUMN_RADIUS)
	if radius < 0 then radius = 0 end

	if columnCache[radius] ~= nil then return columnCache[radius] end

	local offsets = { 0 }
	for i = 1, radius do
		table.insert(offsets, i)
		table.insert(offsets, -i)
	end

	columnCache[radius] = offsets
	return offsets
end

local standableNearInner

-- Runs the standable search with the survey treating the position's own medium as the unit's.
local function standableNear(position, searchUp, radius, mediumVerified, searchDown)
  if not (petports_gravitySwitchable ~= nil and petports_gravitySwitchable()) then
    return standableNearInner(position, searchUp, radius, mediumVerified, searchDown)
  end

  local asFreeMover = petports_mediumAtPoint(position) == "swim"
  local held = self.petportsNavSurveyFree
  self.petportsNavSurveyFree = asFreeMover

  local results = { pcall(standableNearInner, position, searchUp, radius, mediumVerified, searchDown) }

  self.petportsNavSurveyFree = held

  if not results[1] then error(results[2], 0) end
  return select(2, table.unpack(results))
end

-- Returns the nearest point the unit can stand on, or hover at, searching outward column by column.
standableNearInner = function(position, searchUp, radius, mediumVerified, searchDown)
  if petports_freeMover() then
    local flyPoint = petports_flyPointNear(position, radius, mediumVerified)

    if TASK_DEBUG then
      sb.logInfo("UNIT fly point for %s -> %s",
        sb.printJson(position), (flyPoint ~= nil) and sb.printJson(flyPoint) or "REFUSED")
    end

    return flyPoint
  end

  if searchUp == nil then searchUp = GROUND_SEARCH_UP end

  if searchDown == nil then searchDown = GROUND_SEARCH_DOWN end

  local best = nil
  local bestOffset = nil
  local bestDistance = nil

  for _, offset in ipairs(columnsFor(radius)) do
    local x = math.floor(position[1] + offset) + 0.5

    local ok, resolved = pcall(findGroundPosition,
      {x, position[2]}, searchDown, searchUp, petports_avoidLiquid())

    local usable = ok
      and type(resolved) == "table"
      and type(resolved[1]) == "number"
      and type(resolved[2]) == "number"

    if usable and not petports_mediumAllows({ resolved[1], resolved[2] }) then
      if TASK_DEBUG then
        sb.logInfo("UNIT ground spot %s rejected: a liquid this chassis will not enter",
          sb.printJson(resolved))
      end
      usable = false
    end

    if usable and not petports_freeMover()
       and petports_mediumAtPoint({ resolved[1], resolved[2] }) == "swim"
       and not world.pointTileCollision({ resolved[1], resolved[2] - 1.0 },
             STANDABLE_TILE_SET) then

      local floor = nil

      for drop = 1, math.abs(searchDown) do
        local lower = { resolved[1], resolved[2] - drop }

        if world.pointTileCollision({ lower[1], lower[2] - 1.0 },
           STANDABLE_TILE_SET) then
          local fits, standable = pcall(validStandingPosition, lower,
            petports_avoidLiquid())

          if fits and standable and petports_mediumAllows(lower) then
            floor = lower
          end

          break
        end
      end

      if floor ~= nil then
        if TASK_DEBUG then
          sb.logInfo("UNIT ground spot %s was floating, descended to %s (asked for %s)",
            sb.printJson(resolved), sb.printJson(floor), sb.printJson(position))
        end
        resolved = floor
      else
        if TASK_DEBUG then
          sb.logInfo("UNIT ground spot %s is floating and no floor below it (asked for %s)",
            sb.printJson(resolved), sb.printJson(position))
        end
        usable = false
      end
    end

    if usable then
      local candidate = { resolved[1], resolved[2] }
      local distance = world.magnitude(candidate, position)

      if TASK_DEBUG then
        sb.logInfo("UNIT standable candidate %s for %s (column offset %s) dist %s",
          sb.printJson(candidate), sb.printJson(position),
          sb.printJson(offset), sb.printJson(distance))
      end

      if bestDistance == nil or distance < bestDistance then
        best = candidate
        bestOffset = offset
        bestDistance = distance
      end
    end

    if TASK_DEBUG and not ok then
      sb.logInfo("UNIT findGroundPosition failed at x %s: %s",
        sb.printJson(x), tostring(resolved))
    end
  end

  if best ~= nil then
    sb.logInfo("UNIT standable for %s -> %s (column offset %s, dist %s)",
      sb.printJson(position), sb.printJson(best),
      sb.printJson(bestOffset), sb.printJson(bestDistance))

    return best
  end

  sb.logInfo("UNIT no standable column near %s within %s columns (up %s, down %s)",
    sb.printJson(position), sb.printJson(#columnsFor(radius)),
    sb.printJson(searchUp), sb.printJson(searchDown))
  return nil
end

petports_standablePoint = standableNear

OBJECT_SEARCH_BUFFER = 2

-- Returns the nearest standable point on top of an object's bounds.
local function objectRoofPoint(position, bounds)
  if position == nil or type(bounds) ~= "table" or #bounds < 4 then return nil end

  local roofY = bounds[4] + 1.3
  local best, bestDistance = nil, nil

  for x = math.floor(bounds[1]) + 0.5, math.floor(bounds[3]) + 0.5, 1 do
    local candidate = { x, roofY }
    local why = nil

    if not world.pointTileCollision({ x, roofY - 1.0 }, STANDABLE_TILE_SET) then
      why = "no floor below"
    elseif not petports_mediumAllows(candidate) then
      why = "a medium this chassis will not enter"
    else
      local fits, standable = pcall(validStandingPosition, candidate,
        petports_avoidLiquid())

      if not fits then
        why = "validStandingPosition raised: " .. tostring(standable)
      elseif not standable then
        why = "validStandingPosition says the body does not fit"
      end
    end

    if why == nil then
      local distance = world.magnitude(candidate, position)

      if bestDistance == nil or distance < bestDistance then
        best, bestDistance = candidate, distance
      end
    elseif TASK_DEBUG then
      sb.logInfo("UNIT roof candidate %s refused: %s",
        sb.printJson(candidate), why)
    end
  end

  if best ~= nil then
    sb.logInfo("UNIT roof point for %s bounds %s -> %s (dist %s)",
      sb.printJson(position), sb.printJson(bounds),
      sb.printJson(best), sb.printJson(bestDistance))
  else
    sb.logInfo("UNIT no roof point on bounds %s at y %s -- every column refused",
      sb.printJson(bounds), sb.printJson(roofY))
  end

  return best
end

-- Returns a standable point beside an object's bounds, falling back to its roof.
function petports_objectPointNear(position, bounds, mediumVerified)
  if position == nil or type(bounds) ~= "table" or #bounds < 4 then return nil end

  local minX, minY, maxX, maxY = bounds[1], bounds[2], bounds[3], bounds[4]

  local reach = math.max(math.abs(minX - position[1]), math.abs(maxX - position[1]))
  local radius = math.ceil(reach) + OBJECT_SEARCH_BUFFER

  local up = math.ceil(maxY - position[2]) + OBJECT_SEARCH_BUFFER
  local down = math.floor(minY - position[2]) - OBJECT_SEARCH_BUFFER

  if up < GROUND_SEARCH_UP then up = GROUND_SEARCH_UP end
  if down > GROUND_SEARCH_DOWN then down = GROUND_SEARCH_DOWN end
  if radius < COLUMN_RADIUS then radius = COLUMN_RADIUS end

  if TASK_DEBUG then
    sb.logInfo("UNIT object point for %s bounds %s -> radius %s up %s down %s",
      sb.printJson(position), sb.printJson(bounds),
      sb.printJson(radius), sb.printJson(up), sb.printJson(down))
  end

  local found = standableNear(position, up, radius, mediumVerified, down)
  if found ~= nil then return found end

  return objectRoofPoint(position, bounds)
end

-- Returns a task's live target: the current water tile, the tracked entity's position, or the task position.
local function currentTarget(task)
  if task.type == "water" then
    local tile = task.tiles ~= nil and task.tiles[task.waterIndex or 1] or nil
    if tile == nil then return nil end

    return { tile[1] + 0.5, tile[2] + 1.5 }
  end

  local trackedId = trackedEntity(task)
  if trackedId == nil then
    return task.position
  end

  if not world.entityExists(trackedId) then return nil end
  return world.entityPosition(trackedId)
end

local TARGET_DRIFT = 1.5

-- Records where the approach target came from and logs a change for a switchable chassis.
local function noteGroundTarget(stateData, why, rawPosition)
	stateData.groundTargetWhy = why
	if not PETPORTS_MEDIA_TRACE or not petports_gravitySwitchable() then return end
	local key = tostring(why) .. "|" .. sb.printJson(stateData.groundTarget)
	if stateData.groundTargetNoted == key then return end
	stateData.groundTargetNoted = key
	local plan = self.petportsDivePlan
	sb.logInfo("UNIT approach target %s from %s for raw %s (mode %s, leg side %s, dive plan %s)",
		sb.printJson(stateData.groundTarget), tostring(why), sb.printJson(rawPosition),
		tostring(petports_swimMode()), tostring(self.petportsLegSide),
		plan == nil and "none" or ((plan.route and "route " or "fish ")
			.. (plan.abandoned and "abandoned" or (plan.reached and "reached" or "to board"))))
end

-- Returns the point the unit walks to for a target, holding it until the target drifts.
local function approachTargetFor(stateData, rawPosition)
  if self.petportsDiveRetarget then
    self.petportsDiveRetarget = nil
    stateData.groundTarget = nil
    stateData.groundTargetFrom = nil
  end

  local grounded = petports_freeMover() or mcontroller.onGround()

  if grounded and stateData.groundTarget ~= nil and stateData.groundTargetFrom ~= nil
     and world.magnitude(rawPosition, stateData.groundTargetFrom) > TARGET_DRIFT then
    stateData.groundTarget = nil
    stateData.groundTargetFrom = nil
  end

  if stateData.groundTarget ~= nil then return stateData.groundTarget end

  stateData.groundTargetFrom = rawPosition

  local task = stateData.task
  local homeward = task ~= nil and task.type == "return"

  local verified = task ~= nil and task.mediumVerified or nil

  local divePlan = self.petportsDivePlan

  if not homeward and divePlan ~= nil and divePlan.route
     and not divePlan.abandoned and not divePlan.reached
     and petports_gravitySwitchable()
     and petports_swimMode() == PETPORTS_SWIM_MODE_LAND then
    stateData.groundTarget = divePlan.launch
    stateData.petportsDiveEntry = divePlan.entry
		noteGroundTarget(stateData, "the route dive's board", rawPosition)
    return stateData.groundTarget
  end

	local why = nil
  if homeward then
    stateData.groundTarget = standableNear(rawPosition, 0, nil, verified)
		why = "standableNear below a homeward target"

    if stateData.groundTarget == nil then
      sb.logInfo("UNIT no floor beneath %s -- falling back to an unbiased search",
        sb.printJson(rawPosition))
      stateData.groundTarget = standableNear(rawPosition, nil, nil, verified)
			why = "standableNear unbiased, the homeward fallback"
    end
  else
    local bounds = nil
    if task ~= nil then
      bounds = petports_habitatObjectBounds(task.target)
    end

    if bounds ~= nil then
      stateData.groundTarget = petports_objectPointNear(rawPosition, bounds, verified)
			why = "objectPointNear"
    end

    if stateData.groundTarget == nil then
      stateData.groundTarget = standableNear(rawPosition, nil, nil, verified)
			why = "standableNear"
    end
  end

	noteGroundTarget(stateData, why, rawPosition)

  return stateData.groundTarget
end

-- Returns whether the unit's own node is a valid standing position.
local function originIsPlannable()
  if petports_freeMover() then return true, nil end

  local node = petports_nodePosition(mcontroller.position())

  local ok, standable = pcall(validStandingPosition, node, petports_avoidLiquid())
  if not ok then return true, node end

  return standable == true, node
end

-- Returns the nearest standable node on the same row, and its distance.
local function nudgeTargetNear(node)
  local here = mcontroller.position()

  local candidates = {}
  for dx = -ORIGIN_NUDGE_RADIUS, ORIGIN_NUDGE_RADIUS do
    if dx ~= 0 then
      local candidate = { node[1] + dx, node[2] }
      table.insert(candidates, { candidate, world.magnitude(candidate, here) })
    end
  end

  table.sort(candidates, function(a, b) return a[2] < b[2] end)

  for _, entry in ipairs(candidates) do
    local candidate = entry[1]

    local ok, standable = pcall(validStandingPosition, candidate,
      petports_avoidLiquid())

    if ok and standable and petports_mediumAllows(candidate) then
      return candidate, entry[2]
    end
  end

  return nil
end

-- Walks the unit onto a plannable node, and returns whether it is still doing so.
local function nudgeOrigin(stateData, dt)
  if not mcontroller.onGround() then
    if stateData.originNudge ~= nil then
      sb.logInfo("UNIT origin nudge ABANDONED at %s: left the ground on the way to %s",
        sb.printJson(mcontroller.position()), sb.printJson(stateData.originNudge))

      stateData.originNudge = nil
      stateData.originNudgeTimer = nil
    end

    return false
  end

  local plannable, node = originIsPlannable()

  if plannable then
    if stateData.originNudge ~= nil then
      sb.logInfo("UNIT origin nudge DONE at %s: node %s is standable after %s s",
        sb.printJson(mcontroller.position()), sb.printJson(node),
        sb.printJson(stateData.originNudgeTimer or 0))

      stateData.originNudge = nil
      stateData.originNudgeTimer = nil
      freshPather("origin nudge complete")
    end

    stateData.originNudgeFailed = nil
    return false
  end

  if stateData.originNudgeFailed then return false end

  if stateData.originNudge == nil then
    local finder = self.pather and self.pather.finder

    if finder ~= nil and finder.hasPath then return false end

    local candidate, distance = nudgeTargetNear(node)

    if candidate == nil then
      sb.logInfo("UNIT origin NOT PLANNABLE at %s: node %s is not a standing "
        .. "position and no node within %s tiles on the same row is either -- "
        .. "the search will plan from mid air, falling through to the ordinary "
        .. "failure ladder",
        sb.printJson(mcontroller.position()), sb.printJson(node),
        sb.printJson(ORIGIN_NUDGE_RADIUS))

      stateData.originNudgeFailed = true
      return false
    end

    sb.logInfo("UNIT origin NOT PLANNABLE at %s: node %s is not a standing "
      .. "position -- nudging to %s (%s tiles) before planning",
      sb.printJson(mcontroller.position()), sb.printJson(node),
      sb.printJson(candidate), sb.printJson(distance))

    stateData.originNudge = candidate
    stateData.originNudgeTimer = 0
  end

  stateData.originNudgeTimer = (stateData.originNudgeTimer or 0) + dt

  local here = mcontroller.position()
  local toTarget = stateData.originNudge[1] - here[1]

  if stateData.originNudgeTimer >= ORIGIN_NUDGE_TIMEOUT then
    sb.logInfo("UNIT origin nudge TIMED OUT at %s after %s s: wanted %s, still "
      .. "%s tiles short -- giving up and letting the task fail normally",
      sb.printJson(here), sb.printJson(stateData.originNudgeTimer),
      sb.printJson(stateData.originNudge), sb.printJson(math.abs(toTarget)))

    stateData.originNudge = nil
    stateData.originNudgeTimer = nil
    stateData.originNudgeFailed = true
    return false
  end

  if math.abs(toTarget) <= ORIGIN_NUDGE_ARRIVE then
    mcontroller.controlApproachXVelocity(0, mcontroller.baseParameters().groundForce)
    return true
  end

  local direction = (toTarget > 0) and 1 or -1
  moveX(direction, false)
  mcontroller.controlFace(direction)

  return true
end

local PLAN_WALK_LOOKAHEAD = 6

local PLAN_DROP_REACH = 1.25

-- Scoots through the platform underfoot when a nearby walk or land edge sits below the unit.
local function tryPlanDrop(pather, finder)
  if pather == nil or finder == nil then return false, "no pather", false end
  if not mcontroller.onGround() then return false, "airborne", false end

  local edges = finder.edges
  local index = finder.currentEdgeIndex
  if edges == nil or index == nil then return false, "no path", false end

  local here = mcontroller.position()

  local worstEdge = nil
  local worstIndex = nil
  local worstBelow = nil
  local worstReach = nil

  for i = index, math.min(index + PLAN_WALK_LOOKAHEAD, #edges) do
    local edge = edges[i]
    if edge == nil then break end

    if edge.action ~= "Walk" and edge.action ~= "Land" then break end

    if edge.target ~= nil and edge.target.position ~= nil then
      local below = here[2] - edge.target.position[2]

      local reach = math.abs(here[1] - edge.target.position[1])

      if below >= PLAN_SURFACE_TOLERANCE
         and reach <= PLAN_DROP_REACH
         and (worstBelow == nil or below > worstBelow) then
        worstEdge = edge
        worstIndex = i
        worstBelow = below
        worstReach = reach
      end
    end
  end

  if worstEdge == nil then
    return false, "no ground edge below us", false
  end

  local feetNow = here[2] + mcontroller.boundBox()[2]
  local ok, why = scootThroughPlatform(pather, feetNow - 0.5)

  local detail = string.format("%s edge %s targets %s, %s below us and %s across: %s",
    tostring(worstEdge.action), tostring(worstIndex),
    sb.printJson(worstEdge.target.position), sb.printJson(worstBelow),
    sb.printJson(worstReach), why)

  if ok then
    return true, detail, true
  end

  return false, detail, true
end

-- Returns whether terrain blocks the sweep to the next walk edge, with that edge.
local function planWalkBlocked(finder)
  local edges = finder and finder.edges
  local index = finder and finder.currentEdgeIndex
  if edges == nil or index == nil then return nil end

  local walkEdge = nil
  local walkIndex = nil

  for i = index, math.min(index + PLAN_WALK_LOOKAHEAD, #edges) do
    local candidate = edges[i]
    if candidate == nil then break end

    if candidate.action ~= "Walk" and candidate.action ~= "Land" then break end

    if candidate.action == "Walk" and candidate.target ~= nil
       and candidate.target.position ~= nil then
      walkEdge = candidate
      walkIndex = i
      break
    end
  end

  if walkEdge == nil then return nil end

  local here = mcontroller.position()
  local bounds = mcontroller.boundBox()
  local targetX = walkEdge.target.position[1]

  local sweep = {
    math.min(here[1], targetX) + bounds[1],
    here[2] + bounds[2],
    math.max(here[1], targetX) + bounds[3],
    here[2] + bounds[4]
  }

  local blocked = world.rectTileCollision(sweep, { "Null", "Block", "Dynamic" })

  return blocked, walkIndex, walkEdge, sweep
end

-- Returns the plan's horizontal position at a height.
local function flightPlanX(finder, y)
  if finder == nil or finder.edges == nil then return nil end

  local index = finder.currentEdgeIndex
  if index == nil then return nil end

  for i = index, math.min(index + MAX_JUMP_LOOKAHEAD, #finder.edges) do
    local edge = finder.edges[i]
    if edge == nil then break end

    local from = edge.source and edge.source.position
    local to = edge.target and edge.target.position

    if from ~= nil and to ~= nil then
      local hi, lo = math.max(from[2], to[2]), math.min(from[2], to[2])

      if y <= hi and y >= lo then
        local span = from[2] - to[2]

        if math.abs(span) < 0.0001 then return from[1] end

        local t = (from[2] - y) / span
        return from[1] + t * (to[1] - from[1])
      end
    end

    if edge.action ~= "Arc" and i > index then break end
  end

  return nil
end

-- Logs the position, velocity and drift from the solved arc each tick, when flight tracing is on.
local function flightTrace(dt, stateData)
  if not FLIGHT_TRACE then return end

  local here = mcontroller.position()
  local grounded = mcontroller.onGround()
  local prev = stateData.petportsTrace

  if grounded and (prev == nil or prev.grounded) then
    stateData.petportsTrace = {
      pos = here, grounded = true, tick = 0,
      flight = (prev and prev.flight) or 0
    }
    return
  end

  local flight = (prev and prev.flight) or 0
  local tick = (prev and prev.tick or 0) + 1

  if prev == nil or prev.grounded then
    flight = flight + 1
    tick = 1
  end

  local finder = self.pather and self.pather.finder
  local edge = finder and finder.edges and finder.currentEdgeIndex
    and finder.edges[finder.currentEdgeIndex]

  local moved = prev and prev.pos and world.distance(here, prev.pos) or nil
  local planX = flightPlanX(finder, here[2])

  local solveX, solveY, solveDrift = nil, nil, nil
  local launch = self.petportsLaunchSolve

  if launch ~= nil and launch.gravity ~= nil and tick >= 1 then
    local sx, sy, sv = launch.source[1], launch.source[2], launch.vy

    for _ = 1, tick do
      sv = sv - launch.gravity * PHYSICS_DT
      sx = sx + launch.vx * PHYSICS_DT
      sy = sy + sv * PHYSICS_DT
    end

    solveX, solveY = sx, sy
    solveDrift = here[1] - sx
  end
  local bounds = mcontroller.boundBox()
  local feet = world.liquidAt({ here[1], here[2] + bounds[2] + 0.5 })
  local mid = world.liquidAt(here)

  sb.logInfo("UNIT TRACE #%s.%s at %s moved %s dt %s | vel %s onGround %s liquidMovement %s "
    .. "fillFeet %s fillMid %s medium %s | edge %s/%s %s src %s srcVel %s dst %s "
    .. "| planX %s off %s",
    sb.printJson(flight), sb.printJson(tick),
    sb.printJson(here), sb.printJson(moved), sb.printJson(dt),
    sb.printJson(mcontroller.velocity()), tostring(grounded),
    tostring(mcontroller.liquidMovement()),
    sb.printJson(feet and feet[2] or 0), sb.printJson(mid and mid[2] or 0),
    tostring(petports_mediumAt(here, bounds)),
    tostring(finder and finder.currentEdgeIndex),
    tostring(finder and finder.edges and #finder.edges),
    tostring(edge and edge.action),
    sb.printJson(edge and edge.source and edge.source.position),
    sb.printJson(edge and edge.source and edge.source.velocity),
    sb.printJson(edge and edge.target and edge.target.position),
    sb.printJson(planX),
    sb.printJson(planX and (planX - here[1])))

  if solveX ~= nil then
    sb.logInfo("UNIT TRACE #%s.%s solved: should be [%s,%s], is [%s,%s], "
      .. "drift x %s y %s | launch vx %s, actual vx (moved.x/dt) %s "
      .. "| landing %s airtime %s",
      sb.printJson(flight), sb.printJson(tick),
      sb.printJson(solveX), sb.printJson(solveY),
      sb.printJson(here[1]), sb.printJson(here[2]),
      sb.printJson(solveDrift), sb.printJson(here[2] - solveY),
      sb.printJson(launch.vx),

      sb.printJson(moved and dt and dt > 0 and (moved[1] / dt) or nil),
      sb.printJson(launch.landing), sb.printJson(launch.airtime))
  end

  if tick == 1 then
    local base = mcontroller.baseParameters()
    sb.logInfo("UNIT TRACE #%s chassis: liquidFriction %s liquidImpedance %s "
      .. "airFriction %s groundFriction %s gravityMultiplier %s",
      sb.printJson(flight),
      sb.printJson(base.liquidFriction), sb.printJson(base.liquidImpedance),
      sb.printJson(base.airFriction), sb.printJson(base.groundFriction),
      sb.printJson(base.gravityMultiplier))
  end

  stateData.petportsTrace = { pos = here, grounded = grounded, tick = tick, flight = flight }
end


-- Returns whether the unit has covered ground recently enough for fuel to burn.
local function fuelMoving(dt)
	local here = mcontroller.position()

	if self.petportsFuelAnchor == nil then
		self.petportsFuelAnchor = here
		self.petportsFuelTimer = 0
		self.petportsFuelHeld = false
		return true
	end

	if world.magnitude(here, self.petportsFuelAnchor) >= PROGRESS_DISTANCE then
		if self.petportsFuelHeld and FUEL_TRACE then
			sb.logInfo("UNIT fuel: moving again at %s -- resuming the burn",
				sb.printJson(here))
		end

		self.petportsFuelAnchor = here
		self.petportsFuelTimer = 0
		self.petportsFuelHeld = false
		return true
	end

	self.petportsFuelTimer = (self.petportsFuelTimer or 0) + dt

	if self.petportsFuelTimer >= PROGRESS_WINDOW then
		self.petportsFuelTimer = 0
		self.petportsFuelAnchor = here

		if not self.petportsFuelHeld and FUEL_TRACE then
			sb.logInfo("UNIT fuel: moved less than %s in %s s at %s -- holding the burn",
				sb.printJson(PROGRESS_DISTANCE), sb.printJson(PROGRESS_WINDOW),
				sb.printJson(here))
		end

		self.petportsFuelHeld = true
	end

	return not self.petportsFuelHeld
end

-- Drains fuel at the configured rate while the unit is moving.
local function burnFuel(dt, task)
	local moving = fuelMoving(dt)

	if task == nil or task.port == nil then return end

	if storage.petResources ~= nil and storage.petResources.petports_fuel == nil then
		storage.petResources.petports_fuel = status.resource("petports_fuel")
	end

	if not moving then return end

	local rate = tonumber(config.getParameter("petports_fuelDrain", 1.0)) or 1.0

	rate = rate * (tonumber(self.petportsFuelScale) or 1.0)

	if rate <= 0 then return end

	status.modifyResource("petports_fuel", -(rate * dt))
end

local MUNCH_INTERVAL = 1.0

local MUNCH_RADIUS = 3.0

local MUNCH_LOW = 0.25

-- Returns whether leftovers may be handed to the port rather than dropped.
local function munchMayHold(task)
  return task == nil or task.port == nil or task.hold == true
end

-- Eats nearby unclaimed fuel drops while fuel is low, handing the leftovers to the port.
local function runAndMunch(dt, task)
  self.munchTimer = (self.munchTimer or 0) - dt
  if self.munchTimer > 0 then return end
  self.munchTimer = MUNCH_INTERVAL

  local maximum = status.resourceMax("petports_fuel")
  local current = status.resource("petports_fuel")

  if maximum == nil or current == nil then return end
  if current >= maximum * MUNCH_LOW then return end

  local here = mcontroller.position()

  local found = world.entityQuery(here, MUNCH_RADIUS, {
    includedTypes = { "itemDrop" }
  })

  for _, dropId in ipairs(found or {}) do
    local okItem, descriptor = pcall(world.itemDropItem, dropId)

    if okItem and type(descriptor) == "table"
       and type(descriptor.name) == "string" then

      local okTag, tagged = pcall(root.itemHasTag, descriptor.name, "petports_fuel")

      local claim = petports_claimGet("drop:" .. tostring(dropId))
      local claimed = claim ~= nil and (claim.expires or 0) > world.time()

      if okTag and tagged == true and not claimed then
        local okTake, taken = pcall(world.takeItemDrop, dropId, entity.id())

        if okTake and type(taken) == "table" then
          local held = tonumber(taken.count) or 1
          local eaten = 0

          while eaten < held do
            local meal = petports_feedFuel({
              name = taken.name, count = 1, parameters = taken.parameters
            }, true)

            if type(meal) ~= "table" or (tonumber(meal.amount) or 0) <= 0 then
              break
            end

            eaten = eaten + 1
          end

          local left = held - eaten

          sb.logInfo("UNIT run-and-munch at %s: took %s %s, ate %s, %s left "
            .. "(task %s)",
            sb.printJson(here), sb.printJson(held), tostring(taken.name),
            sb.printJson(eaten), sb.printJson(left),
            task ~= nil and tostring(task.id or "hold") or "none")

          if left > 0 then
            local remainder = {
              name = taken.name, count = left, parameters = taken.parameters
            }

            local port = self.anchorId

            if munchMayHold(task) and port ~= nil and world.entityExists(port) then
              world.sendEntityMessage(port, "petports_cargoHandoff", {
                item = remainder,
                unit = entity.uniqueId()
              })
            else
              local okBack = pcall(world.spawnItem, remainder, here)

              if not okBack then
                sb.logError("UNIT could not put back %s x%s after a munch "
                  .. "-- ITEMS LOST", tostring(taken.name), tostring(left))
              end
            end
          end

          return
        end
      end
    end
  end
end


local ASTERITE_SWING_PERIOD = 0.25
local ASTERITE_SWINGS_MIN = 1

local ASTERITE_SPARKS = 6

local ASTERITE_CLEAR_MARGIN = 1

-- Returns the swing count, mining particle and mining sounds for a tile mod.
local function asteriteEffects(modName)
	local swings = ASTERITE_SWINGS_MIN
	local particle = nil
	local sounds = nil

	local ok, mod = pcall(root.modConfig, modName)

	if not ok or type(mod) ~= "table" or type(mod.config) ~= "table" then
		return swings, particle, sounds
	end

	local health = tonumber(mod.config.health)
	if health ~= nil and health > swings then swings = math.floor(health) end

	if type(mod.config.miningParticle) == "string" then
		particle = mod.config.miningParticle
	end

	if type(mod.config.miningSounds) == "table"
	   and #mod.config.miningSounds > 0 then

		local base = nil
		if type(mod.path) == "string" then
			base = mod.path:match("^(.*/)[^/]*$")
		end

		sounds = {}

		for _, entry in ipairs(mod.config.miningSounds) do
			if type(entry) == "string" then
				if entry:sub(1, 1) == "/" or base == nil then
					sounds[#sounds + 1] = entry
				else
					sounds[#sounds + 1] = base .. entry
				end
			end
		end

		if #sounds == 0 then sounds = nil end
	end

	return swings, particle, sounds
end

-- Tells every player to draw a mining beam at a tile.
local function publishBeam(centre, swings, period)
	local ok, players = pcall(world.players)
	if not ok or players == nil then return end

	for _, id in ipairs(players) do
		world.sendEntityMessage(id, "petports_beamShow", entity.id(), centre,
			swings, period)
	end
end

-- Spawns a projectile that plays the mining particles and sounds when it reaps.
local function asteriteSwingEffect(centre, particle, sounds)
	local reap = {}

	if particle ~= nil then
		reap[#reap + 1] =
		{
			action = "loop",
			count = ASTERITE_SPARKS,
			body = { { action = "particle", specification = particle } }
		}
	end

	if sounds ~= nil then
		reap[#reap + 1] = { action = "sound", options = sounds }
	end

	if #reap == 0 then return end

	local ok, err = pcall(world.spawnProjectile, "petports_asteritespark",
		centre, entity.id(), { 0, 0 }, false, { actionOnReap = reap })

	if not ok then
		sb.logInfo("UNIT asterite swing effect failed at %s: %s",
			sb.printJson(centre), tostring(err))
	end
end

-- Returns whether the unit is level with an arc's target and already past it.
local function arcPastWaypoint(edges, index, here)
	local edge = edges[index]
	local following = edges[index + 1]

	if edge == nil or edge.target == nil or edge.target.position == nil then
		return false
	end
	if following == nil or following.target == nil
	   or following.target.position == nil then
		return false
	end

	local target = edge.target.position
	local onward = following.target.position

	if math.abs(here[2] - target[2]) > PLAN_SURFACE_TOLERANCE then
		return false
	end

	local forward = onward[1] - target[1]
	if forward == 0 then return false end

	return ((here[1] - target[1]) * forward) > 0
end

local LIQUID_LOOK_AHEAD = 3

local LIQUID_SCAN_SPAN = 10

local LIQUID_HOP_VX = 6

-- Returns whether the liquid at a point is one this chassis will not enter.
local function deniedLiquidAt(point)
	local ok, liquid = pcall(world.liquidAt, point)
	if not ok or type(liquid) ~= "table" or liquid[1] == nil then return false end
	return petports_liquidDenied(liquid[1]) == true
end

-- Returns the landing and launch velocity for hopping a pool of denied liquid ahead, or a refusal reason.
function petports_liquidHopFrom(here, dir)
	local bounds = mcontroller.boundBox()
	if type(bounds) ~= "table" or #bounds < 4 then return nil end

	local feetY = here[2] + bounds[2] + 0.2
	local nose = here[1] + (dir > 0 and bounds[3] or bounds[1])

	local entry = nil
	for step = 0, LIQUID_LOOK_AHEAD do
		local x = nose + dir * step
		if deniedLiquidAt({ x, feetY }) or deniedLiquidAt({ x, feetY - 1 }) then
			entry = x
			break
		end
	end
	if entry == nil then return nil end

	local exit = nil
	for step = 1, LIQUID_SCAN_SPAN + 1 do
		local x = entry + dir * step
		if not (deniedLiquidAt({ x, feetY }) or deniedLiquidAt({ x, feetY - 1 })) then
			exit = x
			break
		end
	end
	if exit == nil then return nil, nil, nil, entry, nil, "no far edge within the scan span" end

	local okNear, landing = pcall(standableNear, { exit + dir * 0.5, here[2] }, 2, 1, false, -3)
	if not okNear or landing == nil then return nil, nil, nil, entry, exit, "nowhere dry to land" end

	local parameters = mcontroller.baseParameters()
	local gravity = world.gravity(here) * (parameters.gravityMultiplier or 1.0)
	if gravity <= 0 then return nil, nil, nil, entry, exit, "no gravity" end

	local dx = landing[1] - here[1]
	local dy = landing[2] - here[2]
	local speed = LIQUID_HOP_VX
	local okSpeed, runSpeed = pcall(function() return parameters.runSpeed end)
	if okSpeed and tonumber(runSpeed) ~= nil and runSpeed > 0 then speed = runSpeed end

	if dx == 0 or ((dx > 0) ~= (dir > 0)) then
		return nil, nil, nil, entry, exit, "landing is not ahead"
	end

	local vx = speed * dir
	local t = math.abs(dx) / speed
	local vy = (dy / t) + (0.5 * gravity * (t - PHYSICS_DT))
	vy = math.max(vy, discreteLaunchForRise(math.max(dy, 0) + JUMP_ARC_CLEARANCE, gravity))

	local ceiling = nil
	local okJump, profile = pcall(function() return parameters.airJumpProfile.jumpSpeed end)
	if okJump then ceiling = tonumber(profile) end

	if vy <= 0 then return nil, nil, nil, entry, exit, "arc needs no rise" end
	if ceiling ~= nil and vy > ceiling then
		return nil, nil, nil, entry, exit, string.format("needs %s up, chassis jumps %s",
			sb.printJson(math.floor(vy * 10) / 10), sb.printJson(ceiling))
	end
	if arcHitsTerrain(here, vx, vy, gravity, t, landing) ~= nil then
		return nil, nil, nil, entry, exit, "arc clips terrain"
	end

	return landing, vx, vy, entry, exit
end

-- Hops or stops at denied liquid in the direction of travel, and returns whether it took control.
local function avoidLiquidAhead(stateData)
	if stateData.liquidHopPending then
		if not mcontroller.onGround() then
			stateData.liquidHopAirborne = true
		elseif stateData.liquidHopAirborne then
			stateData.liquidHopPending = nil
			stateData.liquidHopAirborne = nil
			freshPather("landed a liquid hop; the old plan ran through the pool")
		end
	end

	if not mcontroller.onGround() then return false end
	if petports_freeMover ~= nil and petports_freeMover() then return false end

	local vel = mcontroller.velocity()
	local dir = 0
	if vel[1] > 0.5 then dir = 1 elseif vel[1] < -0.5 then dir = -1 end
	if dir == 0 then return false end

	local here = mcontroller.position()
	local landing, vx, vy, entry, exit, reason = petports_liquidHopFrom(here, dir)
	if landing == nil and entry == nil then return false end

	if landing ~= nil then
		sb.logInfo("UNIT LIQUID AHEAD at %s (heading %s): hopping "
			.. "from %s to %s, %s tiles across and %s up, at [%s,%s]",
			sb.printJson(entry), sb.printJson(dir),
			sb.printJson(here), sb.printJson(landing),
			sb.printJson(landing[1] - here[1]), sb.printJson(landing[2] - here[2]),
			sb.printJson(vx), sb.printJson(vy))

		local parameters = mcontroller.baseParameters()
		mcontroller.setVelocity({ vel[1], vy })
		mcontroller.controlApproachXVelocity(vx,
			parameters.airForce or parameters.groundForce)
		stateData.liquidHopPending = true
		stateData.liquidHopAirborne = nil
		return true
	end

	mcontroller.controlApproachXVelocity(0, mcontroller.baseParameters().groundForce)

	if stateData.liquidStopSaid ~= entry then
		stateData.liquidStopSaid = entry

		sb.logInfo("UNIT LIQUID AHEAD at %s (heading %s) and no hop available "
			.. "-- stopping at %s rather than walking in (exit %s, %s)",
			sb.printJson(entry), sb.printJson(dir), sb.printJson(here),
			sb.printJson(exit), tostring(reason))
	end

	return true
end

-- Returns whether there is footing under the body's left and right corners.
local function perchFooting()
	local here = mcontroller.position()
	local box = mcontroller.boundBox()
	local y = here[2] + box[2] - 0.3
	local left = world.pointTileCollision({ here[1] + box[1] + 0.15, y }, STANDABLE_TILE_SET)
	local right = world.pointTileCollision({ here[1] + box[3] - 0.15, y }, STANDABLE_TILE_SET)
	return left, right
end

local UNPERCH_DEBOUNCE = 1.0
local UNPERCH_WALK_TIME = 0.6
local UNPERCH_DWELL = 0.5

-- Starts a timed walk, or a hop, off a perch toward whichever corner has footing.
local function unperchWalk(stateData)
	local left, right = perchFooting()
	local here = mcontroller.position()
	local dir = nil
	if left and not right then dir = -1 elseif right and not left then dir = 1 end

	if dir ~= nil then
		stateData.unperchWalk = { dir = dir, until_ = world.time() + UNPERCH_WALK_TIME, hop = false }
		sb.logInfo("UNIT UNPERCH: %s is perched with footing under its %s corner -- walking that way for %s s",
			sb.printJson(here), dir < 0 and "left" or "right", sb.printJson(UNPERCH_WALK_TIME))
		return true
	end

	local facing = mcontroller.facingDirection()
	if facing == 0 then facing = 1 end
	stateData.unperchWalk = { dir = facing, until_ = world.time() + UNPERCH_WALK_TIME, hop = true }
	sb.logInfo("UNIT UNPERCH: %s is perched with footing under %s corner (left %s, right %s) -- hopping %s",
		sb.printJson(here), (left and right) and "both" or "neither", tostring(left), tostring(right),
		facing < 0 and "left" or "right")
	return true
end

-- Runs the unperch walk, and starts one once the unit has stood somewhere unstandable long enough.
local function unperchWatch(dt, stateData)
	local walk = stateData.unperchWalk
	if walk ~= nil then
		if world.time() < walk.until_ then
			mcontroller.controlMove(walk.dir, true)
			if walk.hop and not walk.jumped then
				mcontroller.controlJump()
				walk.jumped = true
			end
			return
		end
		stateData.unperchWalk = nil
	end

	local perched = mcontroller.onGround()
	if perched then
		local ok, standable = pcall(validStandingPosition, mcontroller.position(), false)
		perched = ok and not standable
	end

	if not perched then
		stateData.perchTime = 0
		stateData.perchAnchor = nil
		return
	end

	local here = mcontroller.position()
	local anchor = stateData.perchAnchor
	if anchor == nil or world.magnitude(here, anchor) > UNPERCH_DWELL then
		stateData.perchAnchor = here
		stateData.perchTime = 0
		return
	end

	stateData.perchTime = (stateData.perchTime or 0) + (dt or 0)
	if stateData.perchTime < UNPERCH_DEBOUNCE then return end

	stateData.perchTime = 0

	if unperchWalk(stateData) then
		stateData.progressStrikes = 0
		freshPather("unperching on foot")
	end
end

-- Logs a switchable chassis's mode, leg and pather while it is in, near or leaving the water.
local function mediaTrace(dt, stateData, routeTarget, approachTo, overshot, legReached)
	if not PETPORTS_MEDIA_TRACE or not petports_gravitySwitchable() then return end

	local here = mcontroller.position()
	local medium = petports_mediumAt(here, mcontroller.boundBox())
	local mode = petports_swimMode()
	local bridge = self.petportsLegBridge
	local finder = self.pather and self.pather.finder
	local hasPath = finder ~= nil and finder.hasPath == true
	local wet = mode ~= PETPORTS_SWIM_MODE_LAND or medium ~= "air" or bridge ~= nil
		or self.petportsLegSide == 1

	local key = tostring(mode) .. "|" .. tostring(medium) .. "|" .. tostring(stateData.navLegTo)
		.. "|" .. tostring(bridge and bridge.k) .. "|" .. tostring(self.petportsLegSide)
		.. "|" .. sb.printJson(routeTarget) .. "|" .. sb.printJson(approachTo)
		.. "|" .. tostring(hasPath) .. "|" .. tostring(stateData.navWaypoint ~= nil)

	stateData.mediaTraceTimer = (stateData.mediaTraceTimer or 0) - dt
	local changed = key ~= stateData.mediaTraceKey
	if not changed and not (wet and stateData.mediaTraceTimer <= 0) then return end
	stateData.mediaTraceKey = key
	if not wet and not stateData.mediaTraceWet then return end
	stateData.mediaTraceWet = wet
	stateData.mediaTraceTimer = MEDIA_TRACE_INTERVAL

	local edge = (hasPath and finder.edges ~= nil and finder.currentEdgeIndex ~= nil)
		and finder.edges[finder.currentEdgeIndex] or nil
	local wp = stateData.navWaypoint
	local plan = self.petportsDivePlan
	local flight = self.petportsDiveFlight

	sb.logInfo("UNIT MEDIA%s at %s vel %s onGround %s | mode %s medium %s freeMover %s legSide %s"
		.. " | leg %s cell %s from %s, %s left, bridge %s, step %s, turn %s, dist %s, overshot %s, reached %s"
		.. " | routeTarget %s (%s) approachTo %s lastLeg %s"
		.. " | pather hasPath %s aStar %s target %s edge %s %s of %s"
		.. " | dive plan %s, flight %s",
		changed and " CHANGE" or "", sb.printJson(here), sb.printJson(mcontroller.velocity()),
		tostring(mcontroller.onGround()),
		tostring(mode), tostring(medium), tostring(petports_freeMover()), tostring(self.petportsLegSide),
		sb.printJson(wp), tostring(stateData.navLegTo), tostring(stateData.navLegFrom),
		sb.printJson(stateData.navRemaining),
		bridge ~= nil and (tostring(bridge.k) .. " " .. tostring(bridge.from) .. ">" .. tostring(bridge.to)) or "none",
		tostring(stateData.navLegStep == true), sb.printJson(stateData.navLegTurn),
		wp ~= nil and sb.printJson(world.magnitude(wp, here)) or "n/a",
		tostring(overshot), tostring(legReached),
		sb.printJson(routeTarget), tostring(stateData.groundTargetWhy), sb.printJson(approachTo),
		sb.printJson(self.petportsLegLast),
		tostring(hasPath), tostring(finder ~= nil and finder.aStar ~= nil),
		sb.printJson(finder and finder.target), tostring(edge and edge.action),
		tostring(finder and finder.currentEdgeIndex), tostring(finder and finder.edges and #finder.edges),
		plan == nil and "none" or ("board " .. sb.printJson(plan.launch) .. " entry " .. sb.printJson(plan.entry)
			.. (plan.route and " route" or " fish") .. (plan.reached and " reached" or "")
			.. (plan.abandoned and " abandoned" or "")),
		flight == nil and "none" or ("airborne " .. tostring(flight.airborne == true)
			.. ", deadline in " .. sb.printJson(flight.deadline - world.time())))
end

-- Runs one tick of a task: fuel, coarse and vent routing, approach and arrival, then the work for the task's own type.
local function petportsTaskUpdateInner(dt, stateData)
  local task = stateData.task

  burnFuel(dt, task)

  runAndMunch(dt, task)

  local finder = self.pather and self.pather.finder
  local searching = finder ~= nil and finder.aStar ~= nil and not finder.hasPath

  if petports_navTick ~= nil then
    petports_navTick(dt, entity.uniqueId(), searching and not munchMayHold(task))
  end

  if task.port == nil and self.petportsTask ~= nil then
    sb.logInfo("UNIT leaving station-keeping: task %s was dispatched",
      tostring(self.petportsTask.id))
    return true
  end

  local movingId, movingRow = trackedEntity(task)
  if movingId ~= nil and movingRow.moves
     and world.entityExists(movingId) then

    local movingAt = world.entityPosition(movingId)
    if movingAt ~= nil and not petports_inNetwork(movingAt) then
      report(stateData, "failed",
        "the " .. movingRow.noun .. " left network coverage at "
        .. sb.printJson(movingAt))
      return true
    end
  end

  petports_swimModeTick()

  local beached = petports_outOfMedium()

  if beached.checked and beached.brush then
    local away = beached.away or { 0, 0 }
    local length = math.sqrt(away[1] * away[1] + away[2] * away[2])

    if stateData.brushTimer == nil or stateData.brushTimer <= 0 then
      sb.logInfo("UNIT BRUSH against denied liquid at %s -- backing off %s and "
        .. "dropping the leg to %s", sb.printJson(beached.position),
        sb.printJson(away), sb.printJson(stateData.navWaypoint))
      stateData.navWaypoint = nil
      stateData.navRemaining = nil
      stateData.navLegArrived = nil
      stateData.groundTarget = nil
      stateData.coarseFirstFor = nil
      self.petportsPullClear = false
      freshPather("brushed denied liquid")
    end

    stateData.brushTimer = BRUSH_BACKOFF

    if length > 0.001 then
      local speed = petports_scaledSpeed(mcontroller.baseParameters().flySpeed or 5)
      mcontroller.controlParameters({ flySpeed = speed })
      mcontroller.controlFly({ away[1] / length * speed, away[2] / length * speed })
    end

    return false
  end

  if stateData.brushTimer ~= nil and stateData.brushTimer > 0 then
    stateData.brushTimer = stateData.brushTimer - dt
  end

  if beached.checked and beached.out then
    sb.logInfo("UNIT beached mid-task at %s (medium %s) -- yielding the task "
      .. "action so it can flop; the port re-homes if it cannot self-rescue",
      sb.printJson(beached.position), tostring(beached.medium))
    return true
  end

  petports_thinkPump(dt)

  if not stateData.reportedMoving and task.port ~= nil then
    stateData.movingTimer = (stateData.movingTimer or 0) - dt

    if stateData.movingTimer <= 0 then
      stateData.movingTimer = TASK_MOVING_INTERVAL

      local from = stateData.startPosition
      local gone = from ~= nil
        and world.magnitude(mcontroller.position(), from) or 0

      if gone > TASK_MOVING_DISTANCE then
        stateData.reportedMoving = true

        sb.logInfo("UNIT under way for %s: %s tile(s) from %s, now at %s",
          tostring(task.id), sb.printJson(gone), sb.printJson(from),
          sb.printJson(mcontroller.position()))

        world.sendEntityMessage(task.port, "petports_taskProgress", {
          id = task.id,
          phase = "moving",
          unit = entity.uniqueId()
        })
      end
    end
  end

  local preFinder = self.pather and self.pather.finder
  if TASK_TRACE_MOVES and preFinder ~= nil and preFinder.hasPath then
    local preEdge = preFinder.edges and preFinder.currentEdgeIndex
      and preFinder.edges[preFinder.currentEdgeIndex]
    local preSource = preEdge and preEdge.source and preEdge.source.position

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

  flightTrace(dt, stateData)

  local groundedNow = mcontroller.onGround()

  if not groundedNow then
    local flightY = mcontroller.position()[2]
    if stateData.flightApex == nil or flightY > stateData.flightApex then
      stateData.flightApex = flightY
    end
  end

  if stateData.wasGrounded == nil then
    stateData.wasGrounded = groundedNow
  end

  if groundedNow ~= stateData.wasGrounded then
    local edgeNow = nil
    if self.pather and self.pather.finder and self.pather.finder.edges
       and self.pather.finder.currentEdgeIndex then
      edgeNow = self.pather.finder.edges[self.pather.finder.currentEdgeIndex]
    end

    if groundedNow then
      sb.logInfo("UNIT FLIGHT touchdown at %s: apex was %s, holding edge %s %s src %s dst %s",
        sb.printJson(mcontroller.position()),
        sb.printJson(stateData.flightApex),
        tostring(self.pather and self.pather.finder and self.pather.finder.currentEdgeIndex),
        tostring(edgeNow and edgeNow.action),
        sb.printJson(edgeNow and edgeNow.source and edgeNow.source.position),
        sb.printJson(edgeNow and edgeNow.target and edgeNow.target.position))

      stateData.flightApex = nil
    else
      sb.logInfo("UNIT FLIGHT left the ground at %s vel %s, holding edge %s %s",
        sb.printJson(mcontroller.position()),
        sb.printJson(mcontroller.velocity()),
        tostring(self.pather and self.pather.finder and self.pather.finder.currentEdgeIndex),
        tostring(edgeNow and edgeNow.action))

      stateData.flightApex = mcontroller.position()[2]
    end

    stateData.wasGrounded = groundedNow
  end

  local arcFinder = self.pather and self.pather.finder

  local droppedThisTick = false
  local arcEdge = nil

  if arcFinder ~= nil and arcFinder.hasPath and arcFinder.edges ~= nil
     and arcFinder.currentEdgeIndex ~= nil then
    arcEdge = arcFinder.edges[arcFinder.currentEdgeIndex]
  end

	if arcEdge ~= nil and arcEdge.action == "Land" and petports_gravitySwitchable()
	   and arcEdge.target ~= nil and arcEdge.target.position ~= nil then
		local landBounds = mcontroller.boundBox()
		local landHere = mcontroller.position()
		local landTargetMedium = petports_mediumAt(arcEdge.target.position, landBounds)
		local landBodyMedium = petports_mediumAt(landHere, landBounds)
		if (landTargetMedium == "swim" or landTargetMedium == "mixed")
		   and (landBodyMedium == "swim" or landBodyMedium == "mixed") then
			sb.logInfo("UNIT LAND edge %s of %s at %s ends in %s and the body reads %s -- passing it",
				tostring(arcFinder.currentEdgeIndex), tostring(#arcFinder.edges),
				sb.printJson(arcEdge.target.position), tostring(landTargetMedium), tostring(landBodyMedium))
			arcFinder:advance()
			arcEdge = arcFinder.edges[arcFinder.currentEdgeIndex]
		end
	end

  if arcEdge ~= nil and arcEdge.action == "Arc" then
    local arcHere = mcontroller.position()
    local arcVel = mcontroller.velocity()
    local arcGrounded = mcontroller.onGround()
    local arcRising = arcVel[2] > 0

    sb.logInfo("UNIT ARC tick: edge %s of %s at %s vel %s onGround %s rising %s src %s dst %s",
      tostring(arcFinder.currentEdgeIndex),
      tostring(#arcFinder.edges),
      sb.printJson(arcHere), sb.printJson(arcVel),
      tostring(arcGrounded), tostring(arcRising),
      sb.printJson(arcEdge.source and arcEdge.source.position),
      sb.printJson(arcEdge.target and arcEdge.target.position))

    local arcMode = nil
    if arcGrounded and not arcRising then
      arcMode = "GROUNDED"
    elseif not arcGrounded and arcVel[2] < 0 then
      arcMode = "FALLING"
    end

    if arcMode == nil then
      sb.logInfo("UNIT ARC no skip: grounded %s rising %s vy %s -- still flying this arc",
        tostring(arcGrounded), tostring(arcRising), sb.printJson(arcVel[2]))
    else
      local skipped = 0
      local stopReason = "hit MAX_ARC_SKIP"
      local landPassed = false

      while skipped < MAX_ARC_SKIP do
        local index = arcFinder.currentEdgeIndex
        local edges = arcFinder.edges

        if index == nil or edges == nil or index > #edges then
          stopReason = "ran off the end of the path"
          break
        end

        local edge = edges[index]

        if edge == nil then
          stopReason = "edge " .. tostring(index) .. " is nil"
          break
        end

        if edge.action ~= "Arc" then
          if arcMode ~= "GROUNDED"
             or not arcPastWaypoint(edges, index, mcontroller.position()) then
            stopReason = "edge " .. tostring(index) .. " is a " .. tostring(edge.action)
            if edge.action == "Land" then landPassed = true end
            break
          end
          if edge.action == "Land" then landPassed = true end

          sb.logInfo("UNIT ARC consuming edge %s of %s in GROUNDED mode: it is "
            .. "a %s to %s and the unit at %s is already past it toward %s",
            tostring(index), tostring(#edges), tostring(edge.action),
            sb.printJson(edge.target.position),
            sb.printJson(mcontroller.position()),
            sb.printJson(edges[index + 1].target.position))

          arcFinder:advance()
          skipped = skipped + 1
        else
          if edge.target == nil or edge.target.position == nil then
            stopReason = "edge " .. tostring(index) .. " has no target position"
            break
          end

          local above = edge.target.position[2] > mcontroller.position()[2]

          if arcMode == "FALLING" and not above then
            stopReason = "descending half reached -- target is below us and still flyable"
            break
          end

          sb.logInfo("UNIT ARC consuming edge %s of %s in %s mode: target %s is %s the unit at %s",
            tostring(index), tostring(#edges), arcMode,
            sb.printJson(edge.target.position),
            above and "ABOVE" or "BELOW",
            sb.printJson(mcontroller.position()))

          arcFinder:advance()
          skipped = skipped + 1
        end
      end

      sb.logInfo("UNIT ARC skip done: mode %s, skipped %s, stopped because %s -- now on edge %s of %s at %s",
        arcMode, sb.printJson(skipped), stopReason,
        tostring(arcFinder.currentEdgeIndex),
        tostring(arcFinder.edges and #arcFinder.edges),
        sb.printJson(mcontroller.position()))

      if arcMode == "GROUNDED" and landPassed then
        local landVel = mcontroller.velocity()
        if math.abs(landVel[1]) >= LAND_BRAKE_STATIONARY then
          mcontroller.setVelocity({ 0, landVel[2] })
          sb.logInfo("UNIT ARC touchdown at %s vel %s reached the Land -- killing horizontal velocity",
            sb.printJson(mcontroller.position()), sb.printJson(landVel))
        end
      end

      if arcMode == "GROUNDED" and skipped > 0 then
        local nextEdge = arcFinder.edges[arcFinder.currentEdgeIndex]
        local nextTarget = nextEdge and nextEdge.target and nextEdge.target.position
        local yGap = nextTarget and math.abs(nextTarget[2] - mcontroller.position()[2])
        local blocked, walkIndex, walkEdge, sweep = planWalkBlocked(arcFinder)
        local dropped, dropWhy, dropWanted = false, "already dropped this tick", false
      if not droppedThisTick then
        dropped, dropWhy, dropWanted = tryPlanDrop(self.pather, arcFinder)
        if dropped then droppedThisTick = true end
      end
        if dropped then droppedThisTick = true end

        if nextTarget == nil then
          sb.logInfo("UNIT ARC landed off-plan at %s: nothing left after the arc -- replanning",
            sb.printJson(mcontroller.position()))

          arcFinder:reset()
          stateData.stuckAnchor = nil
          stateData.airborneEdgeStall = 0
        elseif dropped then
          sb.logInfo("UNIT PLAN DROP after landing at %s: %s -- dropped one platform, keeping "
            .. "the plan (next edge %s targets %s, gap %s)",
            sb.printJson(mcontroller.position()), dropWhy,
            tostring(nextEdge.action), sb.printJson(nextTarget), sb.printJson(yGap))
        elseif dropWanted then
          sb.logInfo("UNIT ARC landed off-plan at %s: %s -- the drop refused, replanning "
            .. "(next edge %s targets %s, gap %s)",
            sb.printJson(mcontroller.position()), dropWhy,
            tostring(nextEdge.action), sb.printJson(nextTarget), sb.printJson(yGap))

          arcFinder:reset()
          stateData.stuckAnchor = nil
          stateData.airborneEdgeStall = 0
        elseif yGap > PLAN_SURFACE_TOLERANCE then
          sb.logInfo("UNIT ARC landed off-plan at %s: next edge %s targets %s, %s tiles off in y "
            .. "(tolerance %s) -- the plan's next step is not reachable from here, replanning "
            .. "(first walk %s, blocked %s)",
            sb.printJson(mcontroller.position()),
            tostring(nextEdge.action), sb.printJson(nextTarget),
            sb.printJson(yGap), sb.printJson(PLAN_SURFACE_TOLERANCE),
            tostring(walkIndex), tostring(blocked))

          arcFinder:reset()
          stateData.stuckAnchor = nil
          stateData.airborneEdgeStall = 0
        elseif blocked == true then
          sb.logInfo("UNIT ARC landed off-plan at %s: y gap to next edge %s is %s, and the plan's "
            .. "Walk edge %s to %s is BLOCKED for this body at this height (sweep %s) -- replanning",
            sb.printJson(mcontroller.position()), sb.printJson(nextTarget),
            sb.printJson(yGap), tostring(walkIndex),
            sb.printJson(walkEdge.target.position), sb.printJson(sweep))

          arcFinder:reset()
          stateData.stuckAnchor = nil
          stateData.airborneEdgeStall = 0
        elseif blocked == false then
          sb.logInfo("UNIT ARC landed at %s: y gap to next edge %s is %s, but the plan's Walk edge "
            .. "%s to %s is CLEAR for this body at this height -- keeping the plan",
            sb.printJson(mcontroller.position()), sb.printJson(nextTarget),
            sb.printJson(yGap), tostring(walkIndex),
            sb.printJson(walkEdge.target.position))
        else
          sb.logInfo("UNIT ARC landed on-plan at %s: next edge %s targets %s, %s tiles off in y, "
            .. "no Walk edge within %s ground-level edges to sweep -- keeping the plan",
            sb.printJson(mcontroller.position()),
            tostring(nextEdge.action), sb.printJson(nextTarget),
            sb.printJson(yGap), sb.printJson(PLAN_WALK_LOOKAHEAD))
        end
      end
    end
  else
    if self.pather ~= nil and self.pather.petportsLanding ~= nil then
      sb.logInfo("UNIT ARCMOVER landing latch cleared at %s: the pather is on %s, not an Arc",
        sb.printJson(mcontroller.position()),
        tostring(arcEdge and arcEdge.action or "no edge"))

      self.pather.petportsLanding = nil
    end

    if self.pather ~= nil and self.pather.petportsLaunch ~= nil then
      sb.logInfo("UNIT ARCMOVER launch record cleared at %s: the pather is on %s, not an Arc "
        .. "-- the flight launched at vx %s",
        sb.printJson(mcontroller.position()),
        tostring(arcEdge and arcEdge.action or "no edge"),
        sb.printJson(self.pather.petportsLaunch.vx))

      self.pather.petportsLaunch = nil
    end
  end

  if arcFinder ~= nil and arcFinder.hasPath and mcontroller.onGround()
     and not stateData.routing then
    local edgeNow = arcFinder.edges and arcFinder.currentEdgeIndex
      and arcFinder.edges[arcFinder.currentEdgeIndex]

    if edgeNow ~= nil and (edgeNow.action == "Walk" or edgeNow.action == "Land") then
      local dropped, dropWhy, dropWanted = tryPlanDrop(self.pather, arcFinder)

      if dropped then
        sb.logInfo("UNIT PLAN DROP at %s: %s -- dropped one platform, keeping the plan "
          .. "(cursor is %s edge %s)",
          sb.printJson(mcontroller.position()), dropWhy,
          tostring(edgeNow.action), tostring(arcFinder.currentEdgeIndex))

      elseif dropWanted then
        sb.logInfo("UNIT PLAN DROP refused at %s: %s -- leaving the plan to the clearance test "
          .. "(cursor is %s edge %s)",
          sb.printJson(mcontroller.position()), dropWhy,
          tostring(edgeNow.action), tostring(arcFinder.currentEdgeIndex))
      end

    end
  end

  local pathFinder = self.pather and self.pather.finder
  local stalledEdge = nil
  local stalledLimit = AIRBORNE_EDGE_STALL

  if pathFinder ~= nil and pathFinder.hasPath and mcontroller.onGround()
     and not stateData.routing and self.pather.jumpTimer == nil then
    local edge = pathFinder.edges and pathFinder.currentEdgeIndex
      and pathFinder.edges[pathFinder.currentEdgeIndex]

    if edge ~= nil and (edge.action == "Jump" or edge.action == "Arc"
                        or edge.action == "Land") then
      stalledEdge = edge

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

      stateData.airborneEdgeStall = 0
    end
  else
    stateData.stuckAnchor = nil
  end

  if petports_drawRouteDebug ~= nil then petports_drawRouteDebug(stateData) end

  local target = currentTarget(task)
  if target == nil then
    if task.type == "harvest" and stateData.swung then
      report(stateData, "done",
        "harvested " .. sb.printJson(task.target)
        .. " at " .. sb.printJson(task.position) .. " (crop consumed)")
      return true
    end

    report(stateData, "failed",
      (task.type == "harvest") and "crop is gone before the swing"
        or "drop is gone")
    return true
  end
  task.position = target

  local routeTarget = approachTargetFor(stateData, target) or target

  if stateData.navWaypoint == nil and not stateData.routing
     and not stateData.arrived and petports_navNearestCell ~= nil then
    local routeKey = sb.printJson(routeTarget)

    if stateData.coarseRetryTimer ~= nil and stateData.coarseRetryTimer > 0 then
      stateData.coarseRetryTimer = stateData.coarseRetryTimer - dt
    elseif stateData.coarseFirstFor ~= routeKey then
      stateData.coarseFirstFor = routeKey

      local here = mcontroller.position()
      local span = world.magnitude(here, routeTarget)
      local far = span > COARSE_FIRST_DISTANCE
      local wanted, why

      if petports_freeMover() then
        local seen = span <= SIGHT_LATCH_RANGE
          and petports_flyPathClear(here, routeTarget) == true
        wanted = not seen
        why = (span > SIGHT_LATCH_RANGE) and "beyond sight range"
          or "no clear line"
      else
        local okLos, blocked = pcall(world.lineTileCollision, here, routeTarget,
          COARSE_LOS_SET)
        local blind = okLos and blocked == true
				local otherSide = petports_gravitySwitchable()
					and petports_mediumAt(routeTarget, mcontroller.boundBox()) == "swim"
        wanted = far or blind or otherSide
        why = far and "far" or (blind and "out of sight" or "in the water")
      end

      local taken, notYet = false, nil
      if wanted then taken, notYet = tryCoarseLeg(stateData, routeTarget) end

			if not taken and notYet ~= "more" and stateData.coarseFirstNoted ~= routeKey then
				stateData.coarseFirstNoted = routeKey
				sb.logInfo("UNIT coarse first: target %s (%s tiles) -- %s",
					routeKey, sb.printJson(math.floor(span * 10 + 0.5) / 10),
					wanted and ("wanted because " .. tostring(why) .. ", but no leg was taken")
						or "near and in sight, going direct")
			end

      if taken then
        sb.logInfo("UNIT coarse first: target %s is %s (%s tiles) -- leg taken",
          routeKey, why, sb.printJson(math.floor(span * 10 + 0.5) / 10))
        return false
      end

      if notYet == "more" then
        stateData.coarseFirstFor = nil
        if stateData.coarseFirstWaitFor ~= routeKey then
          stateData.coarseFirstWaitFor = routeKey
          sb.logInfo("UNIT coarse first: target %s is %s (%s tiles) -- nearest-cell "
            .. "search still running, asking again next tick",
            routeKey, why, sb.printJson(math.floor(span * 10 + 0.5) / 10))
        end
      end

      if wanted and self.petportsNavLastRoute ~= nil
         and self.petportsNavLastRoute.building == true then
        stateData.coarseFirstFor = nil
        stateData.coarseRetryTimer = COARSE_RETRY_INTERVAL
      end
    end
  end

  if not stateData.arrived and nudgeOrigin(stateData, dt) then
    petports_think("pathing")
    return false
  end

  if stateData.routing and stateData.viaVent == nil then
    if stateData.navWaypoint == nil and tryCoarseLeg(stateData, routeTarget) then
      stateData.routing = false
      return false
    end

    local routing = tryVentRoute(stateData, routeTarget)

    if routing == "walk" then
      stateData.routing = false
      return false
    end

    if routing == "none" and task.hold then
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

    if stateData.viaVent == nil then
      petports_think("routing")
      return false
    end
  end

  if stateData.viaVent ~= nil then
    if petportsTaskAction.touchingVent(stateData.viaVent.id) then
      local ventId = stateData.viaVent.id
      local wantExit = stateData.viaVent.destinationId
      local wantPosition = stateData.viaVent.destinationPosition

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

      stateData.triedVents = {}

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
      local ok, arrivedAt = pcall(world.callScriptedEntity,
        stateData.viaVent.id, "petports_ventTravel",
        entity.id(), stateData.viaVent.destinationId)

      sb.logInfo("UNIT [ENTRY SITE B: walked to mouth] vent %s to exit %s called=%s arrivedAt=%s (refusal NOT handled at this site)",
        sb.printJson(stateData.viaVent.id),
        sb.printJson(stateData.viaVent.destinationId),
        tostring(ok), sb.printJson(arrivedAt))

      stateData.viaVent = nil
      stateData.ventApproachTimer = nil
      stateData.ventLastPosition = nil
      stateData.ventLegStarted = false
      stateData.ventHops = stateData.ventHops + 1

      if stateData.plan ~= nil then
        stateData.planIndex = stateData.planIndex + 1
        stateData.routing = stateData.planIndex <= #stateData.plan
      else
        stateData.routing = false
      end

      stateData.groundTarget = nil
      stateData.searchingTimer = 0
      stateData.approachTimer = APPROACH_TIMEOUT
      stateData.arrived = false
      stateData.planOrigin = nil
      freshPather("line 1979")
    end

    return false
  end

  local approachTo = target

  if task.type == "return" then
    approachTo = approachTargetFor(stateData, target) or target
  elseif task.type == "collect" or task.type == "harvest"
     or task.type == "replant" or task.type == "water"
     or task.type == "animal" or task.type == "medic"
     or task.type == "withdraw" or task.type == "fish"
     or task.type == "trap"
     or task.type == "fuelfetch" then
    approachTo = approachTargetFor(stateData, target)

    if approachTo == nil then
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

    stateData.settleTimer = 0
  end

  if stateData.navWaypoint ~= nil and petports_freeMover()
     and self.petportsPullReleased == true then
    self.petportsPullReleased = nil
    sb.logInfo("UNIT string-pull released on a coarse leg to %s -- re-picking "
      .. "the waypoint from %s", sb.printJson(stateData.navWaypoint),
      sb.printJson(mcontroller.position()))
    stateData.navWaypoint = nil
    stateData.navRemaining = nil
    stateData.navLegArrived = nil
    stateData.groundTarget = nil
    stateData.coarseFirstFor = nil
  end
  self.petportsPullReleased = nil

  if stateData.navWaypoint ~= nil and petports_freeMover() then
    stateData.sightTimer = (stateData.sightTimer or 0) - dt

    if stateData.sightTimer <= 0 then
      stateData.sightTimer = SIGHT_LATCH_INTERVAL

      local here = mcontroller.position()
      local span = world.magnitude(here, routeTarget)

      if span <= SIGHT_LATCH_RANGE
         and petports_flyPathClear(here, routeTarget) == true then
        sb.logInfo("UNIT SIGHT latch: target %s is %s tiles away on a clear "
          .. "line -- dropping the leg to %s and %s hop(s) behind it",
          sb.printJson(routeTarget),
          sb.printJson(math.floor(span * 10 + 0.5) / 10),
          sb.printJson(stateData.navWaypoint),
          sb.printJson(stateData.navRemaining or 0))

        stateData.navWaypoint = nil
        stateData.navRemaining = nil
        stateData.navLegArrived = nil
        stateData.groundTarget = nil
        freshPather("target in sight")
      end
    end
  end

  local overshot = false
  if stateData.navWaypoint ~= nil and stateData.navLegStart ~= nil
     and stateData.navLegArrived ~= true and not stateData.navLegStep
     and (petports_freeMover() or mcontroller.onGround()) then
    local here = mcontroller.position()
    local wp, start, nextAnchor = stateData.navWaypoint, stateData.navLegStart, stateData.navLegNext
    local lx, ly = wp[1] - start[1], wp[2] - start[2]
    local t = nil
    local aligned = false
    if petports_freeMover() then
      local len2 = lx * lx + ly * ly
      if len2 >= 1 then
        local px, py = here[1] - start[1], here[2] - start[2]
        t = (px * lx + py * ly) / len2
        aligned = math.abs(px * ly - py * lx) / math.sqrt(len2) <= 2
          and math.abs(here[2] - wp[2]) <= 2
      end
    elseif math.abs(lx) >= 1 then
      t = (here[1] - start[1]) / lx
      local rise = here[2] - wp[2]
      aligned = math.abs(rise) <= 2
      if not aligned and type(nextAnchor) == "table" then
        local toNext = nextAnchor[2] - wp[2]
        aligned = (rise * toNext) > 0 and math.abs(rise) <= math.abs(toNext) + 1
      end
    end
    if t ~= nil and t >= 1 and aligned then
      overshot = true
      sb.logInfo("UNIT coarse leg %s is behind us at %s (%s of the leg from %s) -- arrived",
        sb.printJson(wp), sb.printJson(here),
        sb.printJson(math.floor(t * 100 + 0.5) / 100), sb.printJson(start))
    end
  end

  if stateData.navWaypoint ~= nil and stateData.navLegArrived ~= true
     and not overshot and not stateData.navLegStep
     and not petports_freeMover() and mcontroller.onGround()
     and not (petports_gravitySwitchable ~= nil and petports_gravitySwitchable()) then
    local route = self.petportsNavLastRoute
    local path = route ~= nil and route.path or nil
    local legTo = stateData.navLegTo
    if type(path) == "table" and legTo ~= nil then
      local at = nil
      for i = 1, #path do
        if path[i] == legTo then at = i break end
      end
      if at ~= nil then
        local here = mcontroller.position()
        for j = at + 1, math.min(#path, at + NAV_ROUTE_LOOKAHEAD) do
          local kx, ky = string.match(path[j], "^(-?%d+),(-?%d+)$")
          local anchor = kx ~= nil and petports_navAnchor(tonumber(kx), tonumber(ky), false) or nil
          if anchor ~= nil and world.magnitude(here, anchor) < ARRIVAL_DISTANCE then
            sb.logInfo("UNIT standing on route cell %s at %s, %s cell(s) past the waypoint %s -- reached it instead",
              tostring(path[j]), sb.printJson(here), sb.printJson(j - at), sb.printJson(stateData.navWaypoint))
            stateData.navLegTo = path[j]
            stateData.navRemaining = #path - j
            stateData.navLegArrived = true
            break
          end
        end
      end
    end
  end

  local legReached = stateData.navWaypoint ~= nil
    and (stateData.navLegArrived == true or overshot
      or world.magnitude(stateData.navWaypoint, mcontroller.position())
         < (petports_freeMover()
            and (stateData.navLegStep and NAV_LEG_STEP_ARRIVAL
              or ((stateData.navLegTurn or 0) >= NAV_LEG_SHARP_TURN
                and NAV_LEG_ARRIVAL_FREE or NAV_LEG_ARRIVAL_THROUGH))
            or ARRIVAL_DISTANCE))
    and (petports_freeMover() or mcontroller.onGround())

  if stateData.navWaypoint ~= nil then
    if legReached then
      local remaining = stateData.navRemaining or 0
      if not stateData.navLegStep then stateData.navStepFor = 0 end
      stateData.navLegStep = nil

      stateData.navWaypoint = nil
      stateData.navRemaining = nil
      stateData.navLegArrived = nil
      stateData.groundTarget = nil

      local reachedCell = stateData.navLegTo

      local chained, notYet = false, nil
      if remaining > 0 then
        chained, notYet = tryCoarseLeg(stateData, routeTarget, nil, reachedCell)
      end

      if chained then
        stateData.navChainWait = nil
        sb.logInfo("UNIT reached coarse leg %s with %s hop(s) left -- chaining "
          .. "into the next toward %s", tostring(reachedCell), sb.printJson(remaining),
					sb.printJson(routeTarget))
      elseif notYet == "more" then
        stateData.navLegTo = reachedCell
        stateData.navRemaining = remaining
        stateData.navLegArrived = true
        stateData.navWaypoint = stateData.navLegNext or mcontroller.position()

        if stateData.navChainWait ~= reachedCell then
          stateData.navChainWait = reachedCell
          sb.logInfo("UNIT reached coarse leg %s with %s hop(s) left -- next leg "
            .. "not ready, asking again next tick",
            tostring(reachedCell), sb.printJson(remaining))
        end
      else
        stateData.navChainWait = nil
        sb.logInfo("UNIT reached coarse leg, %s hop(s) were left -- resuming "
          .. "for the real target (chain from %s toward %s returned %s/%s, mode %s, "
					.. "freeMover %s, onGround %s, medium %s)",
					sb.printJson(remaining), tostring(reachedCell), sb.printJson(routeTarget),
					tostring(chained), tostring(notYet), tostring(petports_swimMode()),
					tostring(petports_freeMover()), tostring(mcontroller.onGround()),
					tostring(petports_mediumAt(mcontroller.position(), mcontroller.boundBox())))
        freshPather("coarse leg reached")
      end
    end

    self.petportsLegWaypoint = stateData.navWaypoint

    if stateData.navWaypoint ~= nil then
      approachTo = stateData.navWaypoint
      self.petportsLegLast = stateData.navWaypoint
    end
  end

  if stateData.navWaypoint == nil then
    self.petportsLegWaypoint = nil
    self.petportsLegTightTurn = nil
    self.petportsLegBridge = nil
  end

	mediaTrace(dt, stateData, routeTarget, approachTo, overshot, legReached)

  if not stateData.arrived then
    local turn = 0
    if stateData.navWaypoint ~= nil and stateData.navLegNext ~= nil then
      local heading = mcontroller.velocity()
      local hl = math.sqrt(heading[1] * heading[1] + heading[2] * heading[2])
      if hl < 0.5 then
        local here = mcontroller.position()
        heading = { stateData.navWaypoint[1] - here[1], stateData.navWaypoint[2] - here[2] }
        hl = math.sqrt(heading[1] * heading[1] + heading[2] * heading[2])
      end
      local out = {
        stateData.navLegNext[1] - stateData.navWaypoint[1],
        stateData.navLegNext[2] - stateData.navWaypoint[2]
      }
      local ol = math.sqrt(out[1] * out[1] + out[2] * out[2])
      if hl > 0.001 and ol > 0.001 then
        local cosine = (heading[1] * out[1] + heading[2] * out[2]) / (hl * ol)
        if cosine > 1 then cosine = 1 elseif cosine < -1 then cosine = -1 end
        turn = math.deg(math.acos(cosine))
      end
    end
    stateData.navLegTurn = turn
    local sharp = turn >= NAV_LEG_SHARP_TURN
    self.petportsLegTightTurn = stateData.navWaypoint ~= nil
      and (stateData.navLegStep == true or turn >= NAV_LEG_BRAKE_TURN)

    local legArrival = (stateData.navWaypoint ~= nil and petports_freeMover())
      and (stateData.navLegStep and NAV_LEG_STEP_ARRIVAL
        or (sharp and NAV_LEG_ARRIVAL_FREE or NAV_LEG_ARRIVAL_THROUGH)) or nil

    if approachPoint(dt, approachTo, ARRIVAL_DISTANCE, false, legArrival) then
      if stateData.navWaypoint ~= nil then
        stateData.navLegArrived = true
        return false
      end

      stateData.arrived = true
      animator.setAnimationState("movement", "idle")
      return false
    end

    stateData.progressTimer = (stateData.progressTimer or 0) + dt
    if stateData.progressTimer >= PROGRESS_WINDOW then
      stateData.progressTimer = 0

      local now = mcontroller.position()
      local moved = world.magnitude(now, stateData.progressAnchor)
      stateData.progressAnchor = now

      sb.logInfo("UNIT progress window: moved %s (need %s) in %s s at %s",
        sb.printJson(moved), sb.printJson(PROGRESS_DISTANCE),
        sb.printJson(PROGRESS_WINDOW), sb.printJson(now))

      if moved < PROGRESS_DISTANCE then
        stateData.progressStrikes = (stateData.progressStrikes or 0) + 1
        sb.logInfo("UNIT progress STRIKE %s of %s",
          sb.printJson(stateData.progressStrikes), sb.printJson(PROGRESS_STRIKES))

        if stateData.progressStrikes >= PROGRESS_STRIKES then
          local routing = tryVentRoute(stateData, routeTarget)
          if routing ~= "none" then
            stateData.routing = true
            stateData.progressStrikes = PROGRESS_STRIKES
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

    stateData.traceTimer = stateData.traceTimer - dt
    if stateData.traceTimer <= 0 then
      stateData.traceTimer = 1.0

      local here = mcontroller.position()
      stateData.movedTotal = stateData.movedTotal + world.magnitude(here, stateData.lastPosition)
      stateData.lastPosition = here


      if TASK_DEBUG then
        local finder = self.pather and self.pather.finder
        local selfStandable = select(2, pcall(validStandingPosition, here, false))

        sb.logInfo("UNIT approach at %s (standable %s) target %s approachPosition %s moved %s onGround %s | hasPath %s aStar %s finderTarget %s | search %s explores %s",
          sb.printJson(here), tostring(selfStandable),
          sb.printJson(task.position),
          sb.printJson(self.approachPosition),
          sb.printJson(stateData.movedTotal),
          tostring(mcontroller.onGround()),
          tostring(finder and finder.hasPath),
          tostring(finder ~= nil and finder.aStar ~= nil),
          sb.printJson(finder and finder.target),
          tostring(finder and finder.aStar),
          sb.printJson(self.petportsExploreCalls or 0))
      end
    end

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

	if TASK_DEBUG and hasPath and finder.edges ~= nil and finder.edges ~= stateData.wetEdgesLogged then
		stateData.wetEdgesLogged = finder.edges
		local bounds = mcontroller.boundBox()
		local wanted = {}
		for i, edge in ipairs(finder.edges) do
			local to = edge.target and edge.target.position
			local medium = to and petports_mediumAt(to, bounds)
			if medium == "swim" or medium == "mixed" then
				wanted[i] = true
				wanted[i + 1] = true
			end
		end
		local parts = {}
		for i, edge in ipairs(finder.edges) do
			if wanted[i] then
				local from = edge.source and edge.source.position
				local to = edge.target and edge.target.position
				parts[#parts + 1] = string.format("#%s %s %s->%s (%s)", tostring(i), tostring(edge.action),
					sb.printJson(from), sb.printJson(to), tostring(to and petports_mediumAt(to, bounds)))
			end
		end
		if #parts > 0 then
			sb.logInfo("UNIT WET PLAN at %s, mode %s, %s edge(s): %s",
				sb.printJson(mcontroller.position()), tostring(petports_swimMode()),
				sb.printJson(#finder.edges), table.concat(parts, " | "))
		end
	end

    if TASK_TRACE_MOVES and hasPath then
      local edge = finder.edges and finder.currentEdgeIndex
        and finder.edges[finder.currentEdgeIndex]

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

    if finder ~= nil and finder.aStar == nil and not finder.hasPath
       and stateData.navWaypoint ~= nil and not petports_freeMover() then
      stateData.navRefusedTimer = (stateData.navRefusedTimer or 0) + dt

      if stateData.navRefusedTimer >= 0.5 then
        local wp = stateData.navWaypoint
        local okStand, stand = pcall(validStandingPosition, wp, false)
        local okLiquid, liquid = pcall(world.liquidAt, wp)

        sb.logInfo("UNIT coarse leg target %s refused by the pather without "
          .. "a search for %s s -- onGround %s, validStandingPosition(target,false) %s, "
          .. "liquidAt %s, finder.target %s -- treating as a failed leg",
          sb.printJson(wp), sb.printJson(stateData.navRefusedTimer),
          tostring(mcontroller.onGround()),
          tostring(okStand and stand),
          okLiquid and sb.printJson(liquid) or "err",
          sb.printJson(finder.target))
        stateData.navRefusedTimer = 0
        stateData.searchingTimer = SEARCH_LIMIT
      end
    else
      stateData.navRefusedTimer = 0
    end

    local rejected = self.pather ~= nil and self.pather.petportsPlanRejected == true
    local refused = stateData.navWaypoint ~= nil and rejected

    if rejected then
      stateData.planRefusedTimer = (stateData.planRefusedTimer or 0) + dt
    else
      stateData.planRefusedTimer = 0
    end

    if rejected and not refused and petports_freeMover()
       and stateData.planRefusedTimer >= PLAN_REFUSED_LIMIT then
      local route = self.petportsNavLastRoute
      local why = (route ~= nil and route.why) or "no coarse route asked"

      report(stateData, "failed", string.format(
        "the only local plan crosses a liquid this chassis will not enter, "
        .. "and coarse nav has nothing closer (%s)", tostring(why)), nil, true)
      return true
    end

    if refused and stateData.planRefusedTimer >= PLAN_REFUSED_LIMIT
       and stateData.searchingTimer < SEARCH_LIMIT then
      sb.logInfo("UNIT coarse leg to %s refused by the medium check for %s s -- "
        .. "treating as a failed leg", sb.printJson(stateData.navWaypoint),
        sb.printJson(stateData.planRefusedTimer))
      stateData.searchingTimer = SEARCH_LIMIT
      stateData.planRefusedTimer = 0
    end

    if finder ~= nil and (not finder.hasPath or refused)
       and (finder.aStar ~= nil or stateData.searchingTimer >= SEARCH_LIMIT) then
      stateData.searchingTimer = stateData.searchingTimer + dt

      petports_think("pathing")

      if stateData.searchingTimer >= SEARCH_LIMIT then
        if stateData.navWaypoint ~= nil and petports_navContradict ~= nil then
          local legFrom, legTo = stateData.navLegFrom, stateData.navLegTo
          local legPrev = stateData.navLegPrev or legFrom
          local hops = stateData.navLegHops or 1
          local shrunk = (stateData.navLegReach or NAV_LEG_REACH) <= 0

          stateData.navWaypoint = nil
          stateData.navRemaining = nil
          stateData.groundTarget = nil
          stateData.searchingTimer = 0

          if hops > 1 and not shrunk then
            sb.logInfo("UNIT coarse leg %s > %s (%s hops) would not walk -- "
              .. "retrying one hop at a time", tostring(legFrom),
              tostring(legTo), sb.printJson(hops))

            if tryCoarseLeg(stateData, routeTarget, 0) then return false end
          else
            local verdict, spins = nil, 0

            if legPrev ~= nil and legTo ~= nil and petports_navVerify ~= nil then
              verdict, spins = petports_navVerify(legPrev, legTo)
            end

            sb.logInfo("UNIT coarse edge %s > %s would not walk in %s s -- "
              .. "re-probe says %s after %s tick(s) -- %s",
              tostring(legPrev), tostring(legTo), sb.printJson(SEARCH_LIMIT),
              tostring(verdict), sb.printJson(spins),
              (verdict == true and petports_freeMover())
                and "the edge is real; stepping onto its start first"
                or (verdict == true and "PROBE AND WALK DISAGREE, contradicting anyway"
                  or "contradicted"))

            local stepped = false

            if verdict == true and petports_freeMover() and legPrev ~= nil
               and (stateData.navStepFor or 0) < 2 then
              local px = tonumber(string.match(legPrev, "^(-?%d+),"))
              local py = tonumber(string.match(legPrev, ",(-?%d+)$"))
              local start = px ~= nil and petports_navAnchor(px, py, true) or nil

              if start ~= nil then
                stateData.navStepFor = (stateData.navStepFor or 0) + 1
                stateData.searchingTimer = 0
                stateData.planRefusedTimer = 0

                local gap = world.magnitude(mcontroller.position(), start)

                if gap <= NAV_LEG_ARRIVAL_FREE then
                  sb.logInfo("UNIT NUDGE %s onto the route at %s (%s tiles) and "
                    .. "re-taking the leg", sb.printJson(mcontroller.position()),
                    sb.printJson(start), sb.printJson(math.floor(gap * 100 + 0.5) / 100))
                  mcontroller.setPosition(start)
                  mcontroller.setVelocity({ 0, 0 })
                  stateData.navWaypoint = nil
                  stateData.navRemaining = nil
                  stateData.navLegArrived = nil
                  stateData.groundTarget = nil
                  stateData.coarseFirstFor = nil
                  if tryCoarseLeg(stateData, routeTarget, nil, legPrev) then
                    stepped = true
                  end
                else
                  stateData.navWaypoint = start
                  stateData.navRemaining = (stateData.navRemaining or 0) + 1
                  stateData.navLegTo = legPrev
                  stateData.navLegFrom = legPrev
                  stateData.navLegPrev = legPrev
                  stateData.navLegHops = 0
                  stateData.navLegArrived = nil
                  stateData.navLegStep = true
                  stateData.groundTarget = nil
                  freshPather("stepping onto the route")
                  stepped = true
                end
              end
            end

            if not stepped then
              if legPrev ~= nil and legTo ~= nil and verdict ~= false then
                petports_navContradict(petports_navProfile(), legPrev, legTo)
              end

              if tryCoarseLeg(stateData, routeTarget) then return false end
            else
              return false
            end
          end
        end

        sb.logInfo("UNIT direct path search hit SEARCH_LIMIT %s with no path -- handing over to vent routing",
          sb.printJson(SEARCH_LIMIT))
        stateData.routing = true
        stateData.searchingTimer = 0
        return false
      end
    else
      if stateData.searchingTimer > 0 then
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
      sb.logInfo("UNIT could not reach station within %s s, retrying from %s",
        sb.printJson(APPROACH_TIMEOUT), sb.printJson(mcontroller.position()))
      stateData.approachTimer = APPROACH_TIMEOUT
      stateData.routingTried = false
      freshPather("could not reach station within")
      return false
    end

    if stateData.approachTimer <= 0 then
      sb.logInfo("UNIT approach timer expired (APPROACH_TIMEOUT %s), routingTried %s",
        sb.printJson(APPROACH_TIMEOUT), tostring(stateData.routingTried))

      if not stateData.routingTried then
        stateData.routingTried = true
        stateData.routing = true
        stateData.approachTimer = APPROACH_TIMEOUT
        return false
      end

      local here = mcontroller.position()

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

  local chasedId, chasedRow = trackedEntity(task)
  if chasedId ~= nil and chasedRow.reach ~= nil then
    if not world.entityExists(chasedId) then
      if not chasedRow.goneIsDone then
        report(stateData, "failed", string.format(
          "the %s was gone before the unit reached it", chasedRow.noun))
        return true
      end
    else
      local there = world.entityPosition(chasedId)
      local gap = there and world.magnitude(mcontroller.position(), there) or nil

      if gap == nil or gap > chasedRow.reach then
        stateData.chaseRetarget = (stateData.chaseRetarget or 0) - dt

        if stateData.chaseRetarget <= 0 then
          stateData.chaseCount = (stateData.chaseCount or 0) + 1
          sb.logInfo("UNIT CHASE %s of the %s: %s away (reach %s), re-aim %s, "
            .. "budget %s s left, unit at %s %s at %s",
            sb.printJson(chasedId), chasedRow.noun, sb.printJson(gap or "unknown"),
            sb.printJson(chasedRow.reach), sb.printJson(stateData.chaseCount),
            sb.printJson(stateData.dwellTimer), sb.printJson(mcontroller.position()),
            chasedRow.noun, sb.printJson(there))

          stateData.chaseRetarget = CHASE_RETARGET_INTERVAL
          stateData.arrived = false
          stateData.groundTarget = nil
          stateData.approachTimer = APPROACH_TIMEOUT
        end

        stateData.dwellTimer = stateData.dwellTimer - dt
        if stateData.dwellTimer <= 0 then
          report(stateData, "failed", string.format(
            "arrived but the %s is %s away (reach %s) -- it kept moving",
            chasedRow.noun, sb.printJson(gap or "unknown"),
            sb.printJson(chasedRow.reach)), nil, true)
          return true
        end
        return false
      end
    end
  end

  if task.type == "animal" then
    local here = mcontroller.position()
    local there = world.entityPosition(task.target)
    local reach = world.magnitude(here, there)

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

    local okAfter, after = pcall(world.callScriptedEntity, task.target,
      "hasMonsterHarvest")

    sb.logInfo("UNIT animal poke %s: drop ok %s returned %s, ready %s -> %s",
      sb.printJson(task.target), tostring(okDrop), tostring(dropped),
      tostring(before), tostring(after))

    if okAfter and after == false then
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

  if task.type == "trap" then
    if not world.entityExists(task.target) then
      report(stateData, "failed", "trap was gone on arrival")
      return true
    end

    local here = mcontroller.position()
    local there = world.entityPosition(task.target)
    local reach = world.magnitude(here, there)

    if reach > TRAP_REACH then
      report(stateData, "failed", string.format(
        "arrived but %s tiles from the trap at %s (unit at %s)",
        sb.printJson(reach), sb.printJson(there), sb.printJson(here)))
      return true
    end

    local okBefore, before = pcall(world.callScriptedEntity, task.target,
      "activeAge")

    if not okBefore or type(before) ~= "number" then
      report(stateData, "failed", string.format(
        "trap %s did not answer activeAge (%s) -- not a harvestable, or its "
        .. "script is dead",
        sb.printJson(task.target), tostring(before)))
      return true
    end

    local ripeAt = tonumber(task.ripeAt) or 0

    if before < ripeAt then
      report(stateData, "failed", string.format(
        "trap %s is not ready: active age %s of %s -- emptied by someone else?",
        sb.printJson(task.target), sb.printJson(before), sb.printJson(ripeAt)))
      return true
    end

    local okDrop, dropped = pcall(world.callScriptedEntity, task.target,
      "dropHarvest")

    local okAfter, after = pcall(world.callScriptedEntity, task.target,
      "activeAge")

    sb.logInfo("UNIT trap harvest %s: dropHarvest ok %s returned %s, "
      .. "active age %s -> %s (threshold %s)",
      sb.printJson(task.target), tostring(okDrop), tostring(dropped),
      sb.printJson(before), tostring(after), sb.printJson(ripeAt))

    if okAfter and type(after) == "number" and after < before then
      report(stateData, "done",
        "harvested trap " .. sb.printJson(task.target)
        .. " at " .. sb.printJson(there))
      return true
    end

    report(stateData, "failed", string.format(
      "called dropHarvest on %s and its active age did not reset (%s -> %s) "
      .. "-- the trap was not on its harvest stage",
      sb.printJson(task.target), sb.printJson(before), tostring(after)))
    return true
  end

  if task.type == "medic" then
    if task.target == nil or not world.entityExists(task.target) then
      report(stateData, "done", string.format(
        "patient %s is gone -- no dose spent", sb.printJson(task.target)))
      return true
    end

    local health = world.entityHealth(task.target)

    if type(health) ~= "table" or health[2] == nil or health[2] <= 0 then
      report(stateData, "done", string.format(
        "patient %s reports no health -- no dose spent", sb.printJson(task.target)))
      return true
    end

    if health[1] >= health[2] then
      report(stateData, "done", string.format(
        "patient %s recovered on the way (%s/%s) -- no dose spent",
        sb.printJson(task.target), tostring(health[1]), tostring(health[2])))
      return true
    end

    local here = mcontroller.position()
    local there = world.entityPosition(task.target)
    local gap = world.magnitude(here, there)

    local ok, err = pcall(world.spawnProjectile,
      task.projectile or "petports_medicburst", there, entity.id(), {0, 0}, false, {})

    if not ok then
      report(stateData, "failed", string.format(
        "spawnProjectile failed at patient %s: %s",
        sb.printJson(task.target), tostring(err)))
      return true
    end

    sb.logInfo("UNIT medic DOSE patient %s (%s) at %s: health %s/%s, gap %s, effect %s for %ss",
      sb.printJson(task.target), tostring(task.patientClass), sb.printJson(there),
      tostring(health[1]), tostring(health[2]), sb.printJson(gap),
      tostring(task.effect), tostring(task.duration))

    task.dosed = 1

    report(stateData, "done", string.format(
      "dosed patient %s at %s/%s health", sb.printJson(task.target),
      tostring(health[1]), tostring(health[2])))
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

    local modNow = world.mod({ tile[1], tile[2] }, "foreground")

    if tostring(modNow) ~= tostring(task.previousMod) then
      sb.logInfo("UNIT water SKIP tile %s: mod is %s, expected %s -- "
        .. "already wet or no longer farmland",
        sb.printJson(tile), tostring(modNow), tostring(task.previousMod))
    else
      local spawn = { tile[1] + 0.25, standing[2] + WATER_DROP_HEIGHT }

      local ok, err = pcall(world.spawnProjectile,
        "petports_watersprinkle", spawn, entity.id(), {0, -1}, false, {
          actionOnReap = { {
            action = "applySurfaceMod",
            previousMod = task.previousMod,
            newMod = task.newMod,
            radius = 0
          } },

          processing = task.tint ~= nil and ("?multiply=" .. task.tint) or nil
        })

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

      task.watered = (task.watered or 0) + 1
    end

    task.waterIndex = index + 1

    if task.waterIndex > #tiles then
      report(stateData, "done",
        "swept " .. sb.printJson(#tiles) .. " tile(s), watered "
        .. sb.printJson(task.watered or 0))
      return true
    end

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

    if tileOccupied(tile, task.seed) then
      report(stateData, "failed", string.format(
        "footprint for %s at %s is occupied -- not planting",
        tostring(task.seed), sb.printJson(tile)))
      return true
    end

    local ok, placed = pcall(world.placeObject, task.seed, tile, 1)

    sb.logInfo("UNIT replant at %s: placeObject(%s) ok %s returned %s",
      sb.printJson(tile), tostring(task.seed), tostring(ok), tostring(placed))

    if tileOccupied(tile, task.seed) then
      report(stateData, "done",
        "planted " .. tostring(task.seed) .. " at " .. sb.printJson(tile))
      return true
    end

    report(stateData, "failed", string.format(
      "placeObject(%s) at %s left nothing there -- untilled ground, "
      .. "or placement refused",
      tostring(task.seed), sb.printJson(tile)))
    return true
  end

  if task.type == "harvest" then
    if not stateData.swung then
      local here = mcontroller.position()
      local cropPosition = world.entityPosition(task.target)
      local reach = world.magnitude(here, cropPosition)

      if reach > HARVEST_REACH then
        report(stateData, "failed", string.format(
          "arrived but %s tiles from the crop at %s (unit at %s)",
          tostring(reach), sb.printJson(cropPosition), sb.printJson(here)))
        return true
      end

      local okBefore, before = pcall(world.farmableStage, task.target)
      stateData.stageBefore = okBefore and before or nil

      local tile = { math.floor(cropPosition[1]), math.floor(cropPosition[2]) }

      local okDamage, damaged = pcall(world.damageTiles, { tile }, "foreground",
        here, "plantish", HARVEST_DAMAGE, HARVEST_LEVEL)

      stateData.swung = true
      stateData.verifyTimer = HARVEST_TIMEOUT

      sb.logInfo("UNIT harvest swing at %s tile %s: damageTiles ok %s returned %s "
        .. "(ignored), stage before %s -- watching for the result",
        sb.printJson(task.target), sb.printJson(tile), tostring(okDamage),
        tostring(damaged), sb.printJson(stateData.stageBefore))

      return false
    end

    local okAfter, after = pcall(world.farmableStage, task.target)
    if not okAfter then after = nil end

    if type(after) == "number" and type(stateData.stageBefore) == "number"
       and after ~= stateData.stageBefore then
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
      report(stateData, "failed", string.format(
        "swung at %s and nothing changed in %ss (stage still %s) "
        .. "-- crop was not ready, or FARMABLE_STAGE_BASE is wrong",
        sb.printJson(task.target), sb.printJson(HARVEST_TIMEOUT),
        sb.printJson(after)))
      return true
    end

    return false
  end

  if task.type == "fish" then
    local there = world.entityPosition(task.target)

    local declared, pool = nil, nil
    local okParams, params = pcall(root.monsterParameters, task.fishType)
    if okParams and type(params) == "table" then
      local base = type(params.baseParameters) == "table"
        and params.baseParameters or {}
      declared = params.landedTreasurePool or base.landedTreasurePool
      pool = treasurePoolName(declared)
    end

    if pool == nil or pool == "empty" then
      pcall(world.callScriptedEntity, task.target, "despawn")
      report(stateData, "done", string.format(
        "caught %s but it has no treasure pool (declared %s)",
        tostring(task.fishType), sb.printJson(declared)))
      return true
    end

    local okPool, poolExists = pcall(root.isTreasurePool, pool)
    if not okPool or poolExists ~= true then
      pcall(world.callScriptedEntity, task.target, "despawn")
      report(stateData, "done", string.format(
        "caught %s but pool %s does not exist (declared %s)",
        tostring(task.fishType), tostring(pool), sb.printJson(declared)))
      return true
    end

    local level = math.max(1, world.threatLevel())
    local okTreasure, treasure = pcall(root.createTreasure, pool, level)

    if not okTreasure or type(treasure) ~= "table" or #treasure == 0 then
      report(stateData, "failed", string.format(
        "caught %s but pool %s (declared %s) produced nothing at level %s: %s",
        tostring(task.fishType), tostring(pool), sb.printJson(declared),
        sb.printJson(level), tostring(treasure)))
      pcall(world.callScriptedEntity, task.target, "despawn")
      return true
    end

    pcall(world.callScriptedEntity, task.target, "despawn")

    sb.logInfo("UNIT CAUGHT %s (%s, %s) at %s -- %s stack(s) from pool %s at "
      .. "level %s",
      sb.printJson(task.target), tostring(task.fishType),
      tostring(task.fishRarity or "unknown rarity"), sb.printJson(there),
      sb.printJson(#treasure), tostring(pool), sb.printJson(level))

    report(stateData, "done", string.format(
      "caught %s (%s)", tostring(task.fishType),
      tostring(task.fishRarity or "unknown rarity")), treasure)
    return true
  end

  if task.type == "collect" then
    local ok, taken = pcall(world.takeItemDrop, task.target, entity.id())

    sb.logInfo("UNIT pickup attempt on %s: ok %s taken %s (dwell left %s)",
      sb.printJson(task.target), tostring(ok), sb.printJson(taken),
      sb.printJson(stateData.dwellTimer))

    if ok and taken then
      report(stateData, "done",
        "collected at " .. sb.printJson(task.position), taken)
      return true
    end

    stateData.dwellTimer = stateData.dwellTimer - dt
    if stateData.dwellTimer <= 0 then
      report(stateData, "failed",
        "arrived but could not take drop (pcall ok=" .. tostring(ok) .. ")")
      return true
    end

    return false
  end

  if task.type == "asterite" then
    local tile = task.tile

    if type(tile) ~= "table" or tile[1] == nil or tile[2] == nil then
      report(stateData, "failed", "asterite task carried no tile")
      return true
    end

    local modName = task.mod or PETPORTS_ASTERITE_MOD
    local centre = { tile[1] + 0.5, tile[2] + 0.5 }

    local okMod, before = pcall(world.mod, tile, "foreground")
    local okMat, material = pcall(world.material, tile, "foreground")

    if not okMod then
      report(stateData, "failed", string.format(
        "could not read the tile at %s on arrival", sb.printJson(tile)),
        nil, true)
      return true
    end

    if before ~= modName then
      local cleared = petports_asteriteClear(task.target)

      report(stateData, "failed", string.format(
        "arrived to find %s at %s, not %s -- entry dropped: %s",
        tostring(before), sb.printJson(tile), tostring(modName),
        tostring(cleared)))
      return true
    end

    local here = mcontroller.position()
    local range = world.magnitude(here, centre)
    local reach = petports_asteriteReach()

    if range > reach then
      report(stateData, "failed", string.format(
        "arrived %s from the deposit at %s but reach is %s (unit at %s, "
        .. "standing point was %s)", sb.printJson(math.floor(range * 100) / 100),
        sb.printJson(tile), sb.printJson(reach), sb.printJson(here),
        sb.printJson(task.position)), nil, true)
      return true
    end

    if task.asteriteSwings == nil then
      local swings, particle, sounds = asteriteEffects(modName)

      task.asteriteSwings = swings
      task.asteriteParticle = particle
      task.asteriteSounds = sounds
      task.asteriteSwung = 0
      task.asteriteTimer = 0

      publishBeam(centre, swings, ASTERITE_SWING_PERIOD)

      sb.logInfo("UNIT asterite mining %s at %s: %s swing(s) at %ss, particle "
        .. "%s, %s sound(s)", tostring(modName), sb.printJson(tile),
        sb.printJson(swings), sb.printJson(ASTERITE_SWING_PERIOD),
        tostring(particle or "none"),
        sb.printJson(sounds ~= nil and #sounds or 0))
    end

    task.asteriteTimer = (task.asteriteTimer or 0) - dt

    if task.asteriteTimer > 0 then return false end

    if task.asteriteSwung < task.asteriteSwings then
      task.asteriteSwung = task.asteriteSwung + 1
      asteriteSwingEffect(centre, task.asteriteParticle, task.asteriteSounds)
      task.asteriteTimer = ASTERITE_SWING_PERIOD

      return false
    end

    local okConfig, mod = pcall(root.modConfig, modName)
    local drop = nil

    if okConfig and type(mod) == "table" and type(mod.config) == "table" then
      drop = mod.config.itemDrop
    end

    if type(drop) ~= "string" or drop == "" then
      report(stateData, "failed", string.format(
        "matmod %s names no itemDrop -- refusing to remove it for nothing",
        tostring(modName)))
      return true
    end

    local okPlace, placed = pcall(world.placeMod, tile, "foreground",
      PETPORTS_ASTERITE_CLEARED, nil, true)

    local _, after = pcall(world.mod, tile, "foreground")
    local _, materialAfter = pcall(world.material, tile, "foreground")

    if after == modName then
      report(stateData, "failed", string.format(
        "placeMod at %s ok %s returned %s and the deposit is still there",
        sb.printJson(tile), tostring(okPlace), tostring(placed)), nil, true)
      return true
    end

    local clearHealth = 0
    local okCleared, cleared = pcall(root.modConfig, PETPORTS_ASTERITE_CLEARED)

    if okCleared and type(cleared) == "table" and type(cleared.config) == "table" then
      clearHealth = tonumber(cleared.config.health) or 0
    end

    local okClear = pcall(world.damageTiles, { tile }, "foreground",
      mcontroller.position(), "blockish", clearHealth + ASTERITE_CLEAR_MARGIN,
      0, entity.id())

    if not okClear then
      sb.logInfo("UNIT asterite clearing damage THREW at %s -- the placeholder "
        .. "stays until something overwrites it", sb.printJson(tile))
    end


    if okMat and materialAfter ~= material then
      sb.logInfo("UNIT asterite DESTROYED THE TILE at %s: %s became %s. This "
        .. "should be impossible via placeMod and the module must be pulled "
        .. "until it is understood", sb.printJson(tile), tostring(material),
        tostring(materialAfter))
    end

    petports_asteriteClear(task.target)

    report(stateData, "done", string.format(
      "mined %s at %s in %s swing(s) (%s -> %s, cleared, %s intact)",
      tostring(drop), sb.printJson(tile), sb.printJson(task.asteriteSwung or 0),
      tostring(before), tostring(after),
      tostring(material)), { name = drop, count = 1 })

    return true
  end

  if task.hold then
    local station = approachTargetFor(stateData, task.position) or task.position
    local home = world.magnitude(mcontroller.position(), station)

    if home > (task.slack or 3.0) then
      sb.logInfo("UNIT pushed off station (%s from port), returning",
        sb.printJson(home))

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

      stateData.plan = nil
      stateData.planIndex = 1
      stateData.ventHops = 0
      stateData.viaVent = nil

      stateData.groundTarget = nil
      stateData.routing = false

      sb.logInfo("UNIT on station at %s (port %s), holding until dispatched",
        sb.printJson(mcontroller.position()), sb.printJson(task.position))
    end

    return false
  end

  stateData.dwellTimer = stateData.dwellTimer - dt
  if stateData.dwellTimer <= 0 then
    report(stateData, "done",
      "reached " .. sb.printJson(task.position)
      .. " from " .. sb.printJson(stateData.startPosition))
    return true
  end

  return false
end

-- Clears the leg and pather state, cancels the probe, and reports the task failed if it is still held.
function petportsTaskAction.leavingState(stateData)
  stateData.navWaypoint = nil
  stateData.navRemaining = nil
  stateData.navBridge = nil
  self.petportsLegBridge = nil
  self.petportsLegSide = nil
  self.petportsLegLast = nil

  sb.logInfo("UNIT leaving task state for %s at %s, still holding a task: %s",
    stateData.task and tostring(stateData.task.id) or "none",
    sb.printJson(mcontroller.position()), tostring(self.petportsTask ~= nil))

  petports_thinkClear()

  petports_cancelProbe()

  self.pather = nil
  self.approachPosition = nil

  if self.petportsTask ~= nil and stateData.task ~= nil
     and self.petportsTask.id == stateData.task.id then
    report(stateData, "failed", "interrupted")
  end
end

local taskSectionsInstalled = false
local taskSectionDepth = {}

-- Returns a function that runs another inside a named profiler section, ignoring re-entry.
local function taskProfWrap(name, fn)
  return function(...)
    local depth = (taskSectionDepth[name] or 0) + 1
    taskSectionDepth[name] = depth
    if depth == 1 and petports_profBegin ~= nil then petports_profBegin(name) end
    local a, b, c, d, e, f = fn(...)
    if depth == 1 and petports_profEnd ~= nil then petports_profEnd(name) end
    taskSectionDepth[name] = depth - 1
    return a, b, c, d, e, f
  end
end

-- Wraps the routing, standable, approach, dive and bounds calls in profiler sections, once.
local function installTaskSections()
  if taskSectionsInstalled then return end
  taskSectionsInstalled = true

  tryCoarseLeg = taskProfWrap("coarseLeg", tryCoarseLeg)
  tryVentRoute = taskProfWrap("ventRoute", tryVentRoute)
  standableNear = taskProfWrap("standable", standableNear)
  approachTargetFor = taskProfWrap("approachTarget", approachTargetFor)

  if type(petports_habitatObjectBounds) == "function" then
    petports_habitatObjectBounds = taskProfWrap("objectBounds", petports_habitatObjectBounds)
  end
end

-- Runs the task step inside the profiler, then the liquid-avoidance and unperch watches.
function petportsTaskAction.update(dt, stateData)
  installTaskSections()
  if petports_profInstall ~= nil then petports_profInstall() end
  if petports_profTickBegin ~= nil then petports_profTickBegin() end
  if petports_profBegin ~= nil then petports_profBegin("update") end

  local result = petportsTaskUpdateInner(dt, stateData)

  avoidLiquidAhead(stateData)
  unperchWatch(dt, stateData)

  if petports_profEnd ~= nil then petports_profEnd("update") end
  if petports_profTickEnd ~= nil then petports_profTickEnd() end

  return result
end



local ASTERITE_REACH_BASE = 8
local ASTERITE_REACH_MAX = 12

-- Returns the mining reach for this body size, capped.
function petports_asteriteReach()
	local bounds = mcontroller.boundBox()
	local body = 0

	if type(bounds) == "table" and #bounds >= 4 then
		body = math.max(math.abs(bounds[3] - bounds[1]),
			math.abs(bounds[4] - bounds[2]))
	end

	return math.min(ASTERITE_REACH_BASE + body, ASTERITE_REACH_MAX)
end

-- Returns the closest stored asterite deposit, with its key and range.
local function nearestDeposit()
	local here = mcontroller.position()
	local bestKey, bestEntry, bestRange

	for key, entry in pairs(petports_asteriteAll()) do
		if type(entry) == "table" and type(entry.position) == "table" then
			local range = world.magnitude(here,
				{ entry.position[1] + 0.5, entry.position[2] + 0.5 })

			if bestRange == nil or range < bestRange then
				bestKey, bestEntry, bestRange = key, entry, range
			end
		end
	end

	return bestKey, bestEntry, bestRange
end

-- Returns a number truncated to two decimal places.
local function round2(n)
	return math.floor((tonumber(n) or 0) * 100) / 100
end

-- Places a matmod on a tile and logs the mod and material before and after.
function petports_asteriteSetMod(x, y, newMod, allowOverlap)
	if allowOverlap == nil then allowOverlap = true end

	local tile = { math.floor(tonumber(x) or 0), math.floor(tonumber(y) or 0) }

	local okMod, before = pcall(world.mod, tile, "foreground")
	local okMat, material = pcall(world.material, tile, "foreground")

	local okConfig = pcall(root.modConfig, tostring(newMod))

	sb.logInfo("UNIT placeMod harness at %s: mod %s, material %s -- asking for "
		.. "%s (modConfig resolves: %s), allowOverlap %s",
		sb.printJson(tile), tostring(okMod and before),
		tostring(okMat and material), tostring(newMod), tostring(okConfig),
		tostring(allowOverlap))

	local okPlace, placed = pcall(world.placeMod, tile, "foreground",
		tostring(newMod), nil, allowOverlap)

	local _, after = pcall(world.mod, tile, "foreground")
	local _, materialAfter = pcall(world.material, tile, "foreground")

	sb.logInfo("UNIT placeMod harness RESULT: ok %s returned %s -- mod %s to "
		.. "%s (%s), material %s to %s (%s)",
		tostring(okPlace), tostring(placed),
		tostring(before), tostring(after),
		(after ~= before) and "CHANGED" or "UNCHANGED",
		tostring(material), tostring(materialAfter),
		(materialAfter == material) and "INTACT" or "CHANGED")

	return placed
end

-- Damages a tile and logs the mod and material before and after.
function petports_asteriteDamage(x, y, amount, damageType, harvestLevel)
	local tile = { math.floor(tonumber(x) or 0), math.floor(tonumber(y) or 0) }

	amount = tonumber(amount) or 5
	damageType = tostring(damageType or "beamish")

	local okMod, before = pcall(world.mod, tile, "foreground")
	local okMat, material = pcall(world.material, tile, "foreground")

	local modHealth, modHarvest
	local okConfig, mod = pcall(root.modConfig, tostring(okMod and before))

	if okConfig and type(mod) == "table" and type(mod.config) == "table" then
		modHealth = mod.config.health
		modHarvest = mod.config.harvestLevel
	end

	if harvestLevel == nil then harvestLevel = modHarvest end

	sb.logInfo("UNIT damageTiles harness at %s: mod %s (health %s, harvest "
		.. "%s), material %s -- %s damage of type %s at harvestLevel %s",
		sb.printJson(tile), tostring(okMod and before),
		sb.printJson(modHealth), sb.printJson(modHarvest),
		tostring(okMat and material), sb.printJson(amount), damageType,
		sb.printJson(harvestLevel))

	local okDamage, damaged = pcall(world.damageTiles, { tile }, "foreground",
		mcontroller.position(), damageType, amount,
		tonumber(harvestLevel) or 0, entity.id())

	local _, after = pcall(world.mod, tile, "foreground")
	local _, materialAfter = pcall(world.material, tile, "foreground")

	sb.logInfo("UNIT damageTiles harness RESULT: ok %s returned %s -- mod %s "
		.. "to %s (%s), material %s to %s (%s)",
		tostring(okDamage), tostring(damaged),
		tostring(before), tostring(after),
		(after ~= before) and "CHANGED" or "UNCHANGED",
		tostring(material), tostring(materialAfter),
		(materialAfter == material) and "INTACT" or "GONE")

	return damaged
end

-- Clears the asterite mod off a tile within reach, spawns its item drop, and drops the store entry.
function petports_asteriteMine(x, y, allowOverlap, reachOverride)
	if allowOverlap == nil then allowOverlap = true end

	local modName = PETPORTS_ASTERITE_MOD
	local tile, key

	if x ~= nil and y ~= nil then
		tile = { math.floor(tonumber(x) or 0), math.floor(tonumber(y) or 0) }
		key = petports_tileKey(tile)
	else
		local entry
		key, entry = nearestDeposit()

		if entry == nil then
			sb.logInfo("UNIT asterite probe: the store holds no deposits. Let a "
				.. "port scan one up first, or pass a tile by hand")
			return false
		end

		tile = { entry.position[1], entry.position[2] }

		modName = entry.mod or modName
	end

	local centre = { tile[1] + 0.5, tile[2] + 0.5 }
	local here = mcontroller.position()
	local range = world.magnitude(here, centre)

	local reach = tonumber(reachOverride) or petports_asteriteReach()

	local okMod, before = pcall(world.mod, tile, "foreground")
	local okMat, material = pcall(world.material, tile, "foreground")

	sb.logInfo("UNIT asterite probe at %s: mod %s, material %s, range %s of "
		.. "reach %s, allowOverlap %s",
		sb.printJson(tile), tostring(okMod and before),
		tostring(okMat and material), sb.printJson(round2(range)),
		sb.printJson(reach), tostring(allowOverlap))

	if not okMod or before ~= modName then
		sb.logInfo("UNIT asterite probe REFUSED: that tile carries %s, not %s",
			tostring(okMod and before), tostring(modName))

		if okMod and petports_asteriteClear(key) then
			sb.logInfo("UNIT asterite dropped the stale entry for %s (store "
				.. "now %s)", tostring(key),
				sb.printJson(petports_asteriteCount()))
		end

		return false
	end

	if range > reach then
		sb.logInfo("UNIT asterite probe REFUSED: out of reach by %s tiles. "
			.. "Unit is at %s, tile centre is %s -- pass a fourth argument to "
			.. "override the reach and test the removal from here",
			sb.printJson(round2(range - reach)), sb.printJson(here),
			sb.printJson(centre))
		return false
	end

	local okPlace, placed = pcall(world.placeMod, tile, "foreground",
		PETPORTS_ASTERITE_CLEARED, nil, allowOverlap)

	local _, after = pcall(world.mod, tile, "foreground")
	local _, materialAfter = pcall(world.material, tile, "foreground")

	local removed = (after ~= modName)
	local intact = (materialAfter == material)

	sb.logInfo("UNIT asterite probe RESULT: placeMod ok %s returned %s -- mod "
		.. "%s to %s (%s), material %s to %s (%s)",
		tostring(okPlace), tostring(placed),
		tostring(before), tostring(after),
		removed and "REMOVED" or "STILL THERE",
		tostring(material), tostring(materialAfter),
		intact and "INTACT" or "CHANGED")

	if not removed then
		sb.logInfo("UNIT asterite probe FAILED: the mod survived. If this ran "
			.. "with allowOverlap true, try false; if both fail then placeMod "
			.. "is not reaching the world from a monster and the removal needs "
			.. "the projectile route instead")
		return false
	end

	if not intact then
		sb.logInfo("UNIT asterite probe DESTROYED THE TILE: %s became %s. "
			.. "placeMod is not a safe removal for a breaksWithTile mod and the "
			.. "feature needs a different primitive",
			tostring(material), tostring(materialAfter))
	end

	local okConfig, mod = pcall(root.modConfig, modName)
	local drop = nil

	if okConfig and type(mod) == "table" and type(mod.config) == "table" then
		drop = mod.config.itemDrop
	end

	if type(drop) == "string" and drop ~= "" then
		local okSpawn = pcall(world.spawnItem, drop, centre, 1)
		sb.logInfo("UNIT asterite probe dropped %s x1 at %s (spawn ok %s)",
			tostring(drop), sb.printJson(centre), tostring(okSpawn))
	else
		sb.logInfo("UNIT asterite probe: matmod %s names no itemDrop, so "
			.. "nothing was spawned", tostring(modName))
	end

	local cleared = petports_asteriteClear(key)

	sb.logInfo("UNIT asterite probe cleared store entry %s: %s (store now %s)",
		tostring(key), tostring(cleared), sb.printJson(petports_asteriteCount()))

	return true
end
