-- Fly and swim movement for free movers, replacing approachPoint and setJumpState.

petports_vanillaSetJumpState = setJumpState

local BUILD_STAMP = "2026-09-20c every function, the stamp flag and the setJumpState capture are petports_ globals"

local FLY_RETARGET_DISTANCE = 4.0
petports_flyStampLogged = false

local DRAW_PLAN = false

local PLAN_SHAPE_DEBUG = false

-- Logs the mix of edge actions in a plan when it changes.
function petports_reportPlanShape(finder)
  if not PLAN_SHAPE_DEBUG then return end
  if finder == nil or not finder.hasPath or finder.edges == nil then return end

  local counts, order = {}, {}
  for _, edge in ipairs(finder.edges) do
    local action = tostring(edge.action)
    if counts[action] == nil then
      counts[action] = 0
      table.insert(order, action)
    end
    counts[action] = counts[action] + 1
  end

  local parts = {}
  for _, action in ipairs(order) do
    table.insert(parts, action .. " x" .. tostring(counts[action]))
  end
  table.sort(parts)

  local shape = table.concat(parts, ", ")
  if self.petportsFlyPlanShape == shape then return end
  self.petportsFlyPlanShape = shape

  sb.logInfo("UNIT FLY plan shape: %s edge(s) -- %s",
    sb.printJson(#finder.edges), shape)
end

local FLY_ARRIVAL = 1.0

-- Logs whether the body fits at the start, the target and their tile centres.
function petports_probeStartNode(targetPosition)
  local bounds = mcontroller.boundBox()

  -- Returns whether the body clears terrain at a position.
  local function fits(x, y)
    return not world.rectTileCollision({
      x + bounds[1], y + bounds[2],
      x + bounds[3], y + bounds[4]
    }, { "Null", "Block" })
  end

  local here = mcontroller.position()
  local hereCentre = { math.floor(here[1]) + 0.5, math.floor(here[2]) + 0.5 }

  local there = targetPosition
  local thereCentre = { math.floor(there[1]) + 0.5, math.floor(there[2]) + 0.5 }

  sb.logInfo("UNIT PATHNODE PROBE -- at %s body fits %s | its tile centre %s fits %s "
    .. "|| target %s body fits %s | its tile centre %s fits %s || %s",
    sb.printJson(here), tostring(fits(here[1], here[2])),
    sb.printJson(hereCentre), tostring(fits(hereCentre[1], hereCentre[2])),
    sb.printJson(there), tostring(fits(there[1], there[2])),
    sb.printJson(thereCentre), tostring(fits(thereCentre[1], thereCentre[2])),
    (fits(here[1], here[2]) and not fits(hereCentre[1], hereCentre[2]))
      and "<<<< START IS SUB-TILE VALID AND TILE-CENTRE INVALID, hypothesis confirmed"
      or "start and its tile centre agree -- look elsewhere")
end

-- Logs a path result once per distinct reason.
function petports_reportFlyPathEnd(result, targetPosition, distance)
  local reason = tostring(result)

  if self.petportsFlyPathEnd == reason then return end
  self.petportsFlyPathEnd = reason

  if result == false then petports_probeStartNode(targetPosition) end

  sb.logInfo("UNIT FLY path ended with %s at %s: target %s still %s away (arrival %s) "
    .. "-- replanning next tick",
    reason,
    sb.printJson(mcontroller.position()),
    sb.printJson(targetPosition),
    sb.printJson(distance),
    sb.printJson(FLY_ARRIVAL))
end



local FLY_ANIM_MOVING = 2.0
local FLY_ANIM_STILL = 0.5


local FLY_TELEMETRY = true
local FLY_SAMPLE = 0.5

-- Logs the issued fly command, velocity and current edge twice a second.
function petports_sampleFlyCommand(dt)
  if not FLY_TELEMETRY then return end

  self.petportsFlySampleClock = (self.petportsFlySampleClock or 0) + dt
  if self.petportsFlySampleClock < FLY_SAMPLE then return end
  self.petportsFlySampleClock = 0

  local pather = self.pather
  if pather == nil or pather.delta == nil or pather.edge == nil then return end

  local delta = pather.delta
  local velocity = mcontroller.velocity()
  local finder = pather.finder

  sb.logInfo("UNIT FLY cmd %s (dx %s dy %s) spd %s vel %s | %s edge %s of %s -> %s aim %s skip %s at %s",
    sb.printJson(math.sqrt(delta[1] * delta[1] + delta[2] * delta[2])),
    sb.printJson(delta[1]), sb.printJson(delta[2]),
    sb.printJson(math.sqrt(velocity[1] * velocity[1] + velocity[2] * velocity[2])),
    sb.printJson(velocity),
    tostring(pather.edge.action),
    tostring(finder and finder.currentEdgeIndex),
    tostring(finder and finder.edges and #finder.edges),
    sb.printJson(pather.edge.target and pather.edge.target.position),
    sb.printJson(pather.petportsFlyAim),
    sb.printJson(pather.petportsFlySkip),
    sb.printJson(mcontroller.position()))
end




local FLY_LOOKAHEAD = 6

local FLY_AIM_RANGE = 8.0

local FLY_SWEEP_STEP = 0.8

local FLY_SWEEP_SET = { "Null", "Block", "Dynamic" }

local STRING_PULL_RECHECK = 0.05

local STRING_PULL_RANGE = 40.0

local STRING_PULL_TASKS = {
  fish = true,
  animal = true,
  medic = true
}


-- Returns whether a velocity keeps the body out of denied liquid, stopping the unit when it does not.
function petports_flyCommandAllowed(velocity)
  local dt = script.updateDt and script.updateDt() or (1 / 12)
  local here = mcontroller.position()
  local ahead = { here[1] + velocity[1] * dt, here[2] + velocity[2] * dt }
  local medium = petports_mediumAt(ahead, mcontroller.boundBox())

  if medium == "forbidden" then
    if petports_mediumAt(here, mcontroller.boundBox()) == "forbidden" then
      local away = petports_awayFromDenied(here)
      if away[1] * velocity[1] + away[2] * velocity[2] > 0 then
        self.petportsGuardNoted = nil
        return true
      end
    end

    local now = world.time()
    if self.petportsGuardNoted == nil or (now - self.petportsGuardNoted) >= 2.0 then
      self.petportsGuardNoted = now
      sb.logInfo("UNIT GUARD refused a fly command at %s toward %s: the body would "
        .. "enter a liquid this chassis will not -- stopping (medium here %s)",
        sb.printJson(here), sb.printJson(ahead),
        tostring(petports_mediumAt(here, mcontroller.boundBox())))
    end
    mcontroller.setVelocity({ 0, 0 })
    mcontroller.controlFly({ 0, 0 })
    return false
  end

  self.petportsGuardNoted = nil
  return true
end

-- Issues a fly command, falling back to each single axis, and returns what was issued.
function petports_guardedFly(command)
  if petports_flyCommandAllowed(command) then
    mcontroller.controlFly(command)
    return command
  end

  local horizontal = { command[1], 0 }
  local vertical = { 0, command[2] }
  local first, second = horizontal, vertical
  if math.abs(command[2]) > math.abs(command[1]) then first, second = vertical, horizontal end

  for _, axis in ipairs({ first, second }) do
    if math.abs(axis[1]) + math.abs(axis[2]) > 0.01 and petports_flyCommandAllowed(axis) then
      mcontroller.controlFly(axis)
      return axis
    end
  end

  return nil
end

-- Flies straight at a target, setting the velocity outright when it is within one tick on a tight-turn leg.
function petports_steerDirectly(toTarget, length, running)
  local speed = petports_scaledSpeed(mcontroller.baseParameters().flySpeed)

  mcontroller.controlParameters({ flySpeed = speed })

  local dt = script.updateDt and script.updateDt() or (1 / 12)
  local command

  if length <= speed * dt and self.petportsLegTightTurn == true then
    command = { toTarget[1] / dt, toTarget[2] / dt }
    if not petports_flyCommandAllowed(command) then return end
    mcontroller.setVelocity(command)
    mcontroller.controlFace(toTarget[1])
    setMovementState(running)
    return
  end

  command = { toTarget[1] / length * speed, toTarget[2] / length * speed }
  if petports_guardedFly(command) == nil then return end

  mcontroller.controlFace(toTarget[1])
  setMovementState(running)
end

-- Returns whether a point is occupiable, checking only for denied liquid when the chassis has both media.
function petports_mediumClearAt(x, y, bounds, bothMedia)
  if not bothMedia then return petports_mediumAllows({ x, y }, bounds) end
  local level = world.liquidAt({ x, y })
  local fill = (level ~= nil) and (level[2] or 0) or 0
  if fill >= 0.1 and petports_liquidDenied(level[1]) then return false end
  return true
end

-- Returns whether a straight line is free of terrain and of media this chassis may not occupy.
function petports_flyPathClear(from, to)
  local span = world.distance(to, from)
  local length = math.sqrt(span[1] * span[1] + span[2] * span[2])
  if length < 0.001 then return true end

  local bounds = mcontroller.boundBox()
  local media = petports_media()
  local bothMedia = media.fly == true and media.swim == true
  local steps = math.ceil(length / FLY_SWEEP_STEP)

  for i = 0, steps do
    local t = i / steps
    local x = from[1] + span[1] * t
    local y = from[2] + span[2] * t

    if petports_bodyHitsAt({ x, y }, FLY_SWEEP_SET) then return false end

    if not petports_mediumClearAt(x, y, bounds, bothMedia) then return false end
  end

  return true
end

-- Returns whether the line to the target is clear, rechecked on a timer and refused beyond the pull range.
function petports_stringPullClear(here, targetPosition, dt)
  local task = self.petportsTask
  if task == nil then return false end

  self.petportsPullTimer = (self.petportsPullTimer or 0) - (dt or 0)

  if self.petportsPullTimer <= 0 then
    self.petportsPullTimer = STRING_PULL_RECHECK
    if world.magnitude(here, targetPosition) > STRING_PULL_RANGE then
      self.petportsPullClear = false
    else
      self.petportsPullClear = petports_flyPathClear(here, targetPosition)
    end
  end

  return self.petportsPullClear == true
end

-- Returns whether every point on a straight line is in a medium this chassis may occupy.
function petports_flyMediumClear(from, to)
  local bounds = mcontroller.boundBox()

  local span = world.distance(to, from)
  local length = math.sqrt(span[1] * span[1] + span[2] * span[2])

  if length < 0.001 then return petports_mediumAllows(from, bounds) end

  local steps = math.ceil(length / FLY_SWEEP_STEP)

  for i = 0, steps do
    local t = i / steps
    local x = from[1] + span[1] * t
    local y = from[2] + span[2] * t

    if not petports_mediumAllows({ x, y }, bounds) then return false end
  end

  return true
end

-- Returns whether an edge is a Fly or Swim edge.
function petports_isFreeEdge(edge)
  return edge ~= nil and (edge.action == "Fly" or edge.action == "Swim")
end

-- Returns the furthest free edge target within aim range that has a clear line to it, and how many edges it skips.
function petports_aimAhead(from, edgeAt)
  for i = FLY_LOOKAHEAD, 1, -1 do
    local ahead = edgeAt(i)

    if petports_isFreeEdge(ahead)
       and ahead.target ~= nil and ahead.target.position ~= nil then

      local candidate = ahead.target.position
      local span = world.distance(candidate, from)

      if math.sqrt(span[1] * span[1] + span[2] * span[2]) <= FLY_AIM_RANGE
         and petports_flyPathClear(from, candidate) then
        return candidate, i
      end
    end
  end

  return nil, 0
end


-- Returns whether every leg of a plan, after shortcuts, stays in a medium this chassis may occupy.
function petports_planMediumValid(finder)
  if finder == nil or finder.edges == nil then return true end

  local bounds = mcontroller.boundBox()
  local from = mcontroller.position()

  local startMedium = petports_mediumAt(from, bounds)

  if not petports_mediumAllows(from, bounds) then
    return false, 0, from,
      "the unit is ALREADY outside its own medium -- it plans nothing from here "
        .. "and the port will re-home it", startMedium
  end

  local edges = finder.edges
  local index = 1

  for _ = 1, #edges do
    if index > #edges then break end

    local shortcut, offset = petports_aimAhead(from, function(i) return edges[index + i] end)

    if shortcut ~= nil then
      from = shortcut

      index = index + offset + 1
    else
      local edge = edges[index]
      local target = edge and edge.target and edge.target.position

      if target ~= nil then
        local ok, why = petports_mediumAllows(target, bounds)

        if not ok then
          return false, index, target, why, startMedium
        elseif not petports_flyMediumClear(from, target) then
          return false, index, target,
            "legal in itself, but the leg into it crosses a medium this chassis "
              .. "may not occupy", startMedium
        end

        from = target
      end

      index = index + 1
    end
  end

  return true, nil, nil, nil, startMedium
end


-- Returns a string identifying a plan by its edge count and final target.
function petports_planSignature(finder)
  if finder == nil or finder.edges == nil or #finder.edges == 0 then return nil end

  local last = finder.edges[#finder.edges]
  local target = last and last.target and last.target.position

  return tostring(#finder.edges) .. "@"
    .. (target and (tostring(target[1]) .. "," .. tostring(target[2])) or "?")
end

-- Returns a reduced speed while the unit is close to the start of an upcoming jump edge.
function petports_swimApproachSpeed(pather, base)
  local finder = pather.finder
  local ahead = finder ~= nil and finder.lookAhead and finder:lookAhead(1) or nil

  if ahead == nil or ahead.action ~= "Jump"
     or ahead.source == nil or ahead.source.position == nil then
    pather.petportsSlowingForSwimJump = nil
    return base
  end

  local gap = world.magnitude(mcontroller.position(), ahead.source.position)

  if gap > JUMP_APPROACH_SLOWDOWN then
    pather.petportsSlowingForSwimJump = nil
    return base
  end

  if not pather.petportsSlowingForSwimJump then
    pather.petportsSlowingForSwimJump = true
    sb.logInfo("UNIT swim-slowing to %s for jump point %s (gap %s)",
      sb.printJson(JUMP_APPROACH_SPEED),
      sb.printJson(ahead.source.position), sb.printJson(gap))
  end

  return math.min(base, JUMP_APPROACH_SPEED)
end

-- Advances past reached free edges, validates the plan once per signature, and steers at the furthest clear aim point.
function petports_freeMoverInner(pather)
  while petports_isFreeEdge(pather.edge) do
    if passedTarget(pather.edge) then
      pather:advancePath()
    else
      break
    end
  end

  if not petports_isFreeEdge(pather.edge) then
    pather.petportsFlySkip = nil
    return "running"
  end

  local here = mcontroller.position()
  local finder = pather.finder

  local signature = petports_planSignature(finder)

  if pather.petportsPlanSig ~= signature then
    pather.petportsPlanSig = signature

    local ok, index, at, why, startMedium = petports_planMediumValid(finder)
    pather.petportsPlanRejected = not ok

    if not ok then
      sb.logInfo("UNIT PLAN REFUSED at %s (medium %s): edge %s of %s ends at %s, which is %s -- "
        .. "issuing no control, so this task will fail on the progress watchdog "
        .. "rather than fly the unit somewhere it cannot get out of",
        sb.printJson(here), tostring(startMedium), sb.printJson(index),
        sb.printJson(finder.edges and #finder.edges), sb.printJson(at), tostring(why))
    else
      sb.logInfo("UNIT PLAN accepted at %s (medium %s): %s edge(s), every leg swept",
        sb.printJson(here), tostring(startMedium),
        sb.printJson(finder.edges and #finder.edges))
    end
  end

  if pather.petportsPlanRejected then
    pather.petportsFlySkip = nil
    return "running"
  end

  local edgeIndex = finder ~= nil and finder.currentEdgeIndex or nil
  local now = world.time()

  local aim, skip

  if self.petportsAimNext == nil or now >= self.petportsAimNext
     or self.petportsAimEdge ~= edgeIndex or self.petportsAimAt == nil then
    self.petportsAimNext = now + STRING_PULL_RECHECK
    self.petportsAimEdge = edgeIndex

    aim, skip = petports_aimAhead(here,
      function(i) return finder ~= nil and finder.lookAhead and finder:lookAhead(i) or nil end)

    self.petportsAimAt = { aim = aim, skip = skip or 0 }
  else
    aim, skip = self.petportsAimAt.aim, self.petportsAimAt.skip
  end

  if aim == nil then
    local nextPoint = pather.edge.target.position

    if not petports_mediumAllows(nextPoint, mcontroller.boundBox()) then
      if pather.petportsFlyHeld ~= true then
        pather.petportsFlyHeld = true
        sb.logInfo("UNIT HOLDING at %s: no clear shortcut this tick and the next "
          .. "waypoint %s is outside this chassis's medium. The plan was accepted "
          .. "on the assumption that waypoint would be skipped -- waiting for the "
          .. "shortcut rather than flying the detour",
          sb.printJson(here), sb.printJson(nextPoint))
      end

      pather.petportsFlySkip = nil
      return "running"
    end

    aim = nextPoint
    skip = 0
  end

  pather.petportsFlyHeld = nil
  pather.petportsFlySkip = skip
  pather.petportsFlyAim = aim

  local delta = world.distance(aim, here)
  pather.deltaX = delta[1]

  if delta[2] < -0.25 then
    mcontroller.controlDown()
  end

  if not petports_freeMover() then
    local length = math.sqrt(delta[1] * delta[1] + delta[2] * delta[2])

    if length > 0.0001 then
      local speed = petports_swimApproachSpeed(pather,
        petports_scaledSpeed(mcontroller.baseParameters().walkSpeed))
      local force = mcontroller.baseParameters().liquidJumpProfile.jumpControlForce

      mcontroller.controlApproachVelocity(
        { delta[1] / length * speed, delta[2] / length * speed }, force)
    end
  else
    mcontroller.controlParameters({
      flySpeed = petports_scaledSpeed(mcontroller.baseParameters().flySpeed)
    })

    local speed = petports_scaledSpeed(mcontroller.baseParameters().flySpeed)
    local length = math.sqrt(delta[1] * delta[1] + delta[2] * delta[2])
    local command = length > 0.001
      and { delta[1] / length * speed, delta[2] / length * speed } or { 0, 0 }
    petports_guardedFly(command)
  end

  return "running"
end

-- Sets the movement animation from speed for free movers, otherwise calls the vanilla function.
function setJumpState()
  if not petports_freeMover() then
    return petports_vanillaSetJumpState()
  end

  local velocity = mcontroller.velocity()
  local speed = math.sqrt(velocity[1] * velocity[1] + velocity[2] * velocity[2])

  local state = self.petportsFlyAnim
  if speed >= FLY_ANIM_MOVING then
    state = "run"
  elseif speed <= FLY_ANIM_STILL then
    state = "idle"
  end

  if state == nil then state = "idle" end

  if state ~= self.petportsFlyAnim then
    self.petportsFlyAnim = state
    animator.setAnimationState("movement", state)
  end
end

-- Moves the unit toward a target by ground path, string pull, plan or direct steer, returning true on arrival.
function approachPoint(dt, targetPosition, stopDistance, running, arrival)
  if not petports_freeMover() then
    local toTarget = world.distance(targetPosition, mcontroller.position())
    local targetDistance = world.magnitude(targetPosition, mcontroller.position())

    local groundPosition = findGroundPosition(targetPosition, -20, 1,
      petports_avoidLiquid())

    if groundPosition and not petports_mediumAllows(groundPosition) then
      groundPosition = nil
    end

    if groundPosition then
      self.approachPosition = groundPosition
    end

    if self.pather == nil then
      petports_freshPather("approachPoint ground fallback -- no task pather yet")
    end
    self.pather.options.run = running

    if self.approachPosition
       and (targetDistance > stopDistance or not mcontroller.onGround()) then

      if self.pather:move(self.approachPosition, dt) == "running" then
        mcontroller.controlFace(self.pather.deltaX or toTarget[1])
        setMovementState(running)
      else
        setIdleState()
      end

      return false

    elseif targetDistance <= stopDistance then
      return true
    end

    if self.petportsNoGroundAt ~= sb.printJson(targetPosition) then
      self.petportsNoGroundAt = sb.printJson(targetPosition)
      sb.logInfo("UNIT no ground position for %s (avoidLiquid %s) -- approachPosition is %s, "
        .. "so this unit will not move toward it",
        sb.printJson(targetPosition), tostring(petports_avoidLiquid()),
        self.approachPosition and sb.printJson(self.approachPosition) or "nil")
    end

    return nil
  end

  if not petports_flyStampLogged then
    petports_flyStampLogged = true
    sb.logInfo("PETPORTS flyapproach build: %s (gravityEnabled %s, flySpeed %s, airFriction %s)",
      BUILD_STAMP,
      tostring(mcontroller.baseParameters().gravityEnabled),
      sb.printJson(mcontroller.baseParameters().flySpeed),
      sb.printJson(mcontroller.baseParameters().airFriction))

    if DRAW_PLAN then
      self.debug = true
      sb.logInfo("PETPORTS flyapproach: plan rendering ON (needs /debug in game). "
        .. "Fly edges draw MAGENTA; Walk blue, Jump green, Drop cyan, Land yellow, Arc red.")
    end
  end

  if targetPosition == nil then return nil end

  local here = mcontroller.position()
  local toTarget = world.distance(targetPosition, here)
  local targetDistance = world.magnitude(targetPosition, here)

  if targetDistance <= (arrival or FLY_ARRIVAL) then
    mcontroller.controlFly({0, 0})
    mcontroller.setVelocity({0, 0})

    setIdleState()
    self.petportsFlyPathEnd = nil

    return true
  end

  self.approachPosition = targetPosition

  if petports_stringPullClear(here, targetPosition, dt) then
    if self.petportsPulling ~= true then
      self.petportsPulling = true
      sb.logInfo("UNIT STRING-PULL engaged at %s for %s target %s -- the line is "
        .. "clear, steering directly instead of planning",
        sb.printJson(here),
        tostring(self.petportsTask and self.petportsTask.type),
        sb.printJson(targetPosition))
    end

    petports_steerDirectly(toTarget, targetDistance, running)
    return false
  end

  if self.petportsPulling then
    self.petportsPulling = false
    sb.logInfo("UNIT STRING-PULL released at %s: the line to %s is no longer "
      .. "clear -- handing back to the pathfinder",
      sb.printJson(here), sb.printJson(targetPosition))

    self.petportsPullReleased = true


    petports_freshPather("string-pull released, line blocked")
  end

  if self.pather == nil then
    petports_freshPather("approachPoint fly fallback -- no task pather yet")
  end
  self.pather.options.run = running

  if self.pather.moveFly ~= petportsFreeMover then
    self.pather.moveFly = petportsFreeMover
    self.pather.moveSwim = petportsFreeMover
  end

  local latch = self.petportsDirectLatch
  local here = mcontroller.position()
  if latch == nil or latch.pather ~= self.pather
     or world.magnitude(targetPosition, latch.target) > FLY_RETARGET_DISTANCE
     or (latch.done and world.magnitude(here, latch.target) <= FLY_RETARGET_DISTANCE) then
    if latch ~= nil and latch.pather == self.pather then
      sb.logInfo("UNIT direct target re-latched: live %s is %s from latched %s%s",
        sb.printJson(targetPosition),
        sb.printJson(math.floor(world.magnitude(targetPosition, latch.target) * 10 + 0.5) / 10),
        sb.printJson(latch.target), latch.done and " (plan finished)" or "")
    end
    latch = { target = { targetPosition[1], targetPosition[2] }, pather = self.pather }
    self.petportsDirectLatch = latch
  end
  local result = self.pather:move(latch.target, dt)
  latch.done = result ~= "running" and result ~= "pathfinding"

  petports_reportPlanShape(self.pather.finder)
  petports_sampleFlyCommand(dt)

  if result == "running" then
    self.petportsFlyPathEnd = nil

    self.petportsSteerBlind = nil

    mcontroller.controlFace(self.pather.deltaX or toTarget[1])
    setMovementState(running)
  else
    petports_reportFlyPathEnd(result, targetPosition, targetDistance)

    if result == "pathfinding" then
      local now = world.time()
      if (now - (self.petportsHoldNoted or 0)) > 5 then
        self.petportsHoldNoted = now
        sb.logInfo("UNIT HOLDING at %s for %s -- no route, and the direct search is still running; "
          .. "no blind steer until it fails",
          sb.printJson(mcontroller.position()), sb.printJson(targetPosition))
      end
      return false
    end

    local toTarget = world.distance(targetPosition, here)
    local length = math.sqrt(toTarget[1] * toTarget[1] + toTarget[2] * toTarget[2])

    if length > 0.0001 then
      local clear = petports_flyPathClear(here, targetPosition)

      local legal = clear or petports_flyMediumClear(here, targetPosition)

      local steer = (not legal) and "refused" or clear and "clear" or "blocked"

      if self.petportsSteerBlind ~= steer then
        self.petportsSteerBlind = steer

        sb.logInfo("UNIT STEERING %s at %s from %s -- no route, and %s",
          (steer == "refused") and "REFUSED" or "DIRECTLY",
          sb.printJson(targetPosition), sb.printJson(here),
          (steer == "refused")
            and "the straight line leaves this chassis's medium -- issuing no "
              .. "control, so this task will fail on the progress watchdog rather "
              .. "than steer the unit out of the medium it lives in"
          or (steer == "clear")
            and "the line is clear, aiming straight. This is vanilla's "
              .. "flyInGeneralDirection fallback, not a plan."
          or "the line is blocked by terrain but legal, approaching anyway. This "
            .. "is vanilla's flyInGeneralDirection fallback, not a plan.")
      end

      if legal then
        petports_steerDirectly(toTarget, length, running)

        return false
      end
    end

    setIdleState()
  end

  return false
end

-- Runs the free-mover step inside the profiler.
function petportsFreeMover(pather)
  if petports_profBegin ~= nil then petports_profBegin("freeMover") end
  local result = petports_freeMoverInner(pather)
  if petports_profEnd ~= nil then petports_profEnd("freeMover") end
  return result
end
