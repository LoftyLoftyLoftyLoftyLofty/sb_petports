--  M.A.U.S. UTILITY UNIT -- FLYER APPROACH
--
--  Shadows groundPet.lua's global approachPoint for FLYING units only.
--
--  LISTED IN THE FLYER MONSTERTYPE'S scripts ARRAY AND NOWHERE ELSE. The ground
--  drone never loads this file, so the working ground unit cannot be affected
--  by anything in it even if the gravity check below were wrong.
--
--  CAPTURE AND DELEGATE, NOT A FORK
--
--  Every script in a monstertype's scripts list executes into ONE shared Lua
--  environment, in list order. groundPet.lua is first, so approachPoint is a
--  defined global by the time this chunk runs and can be captured. The shadow
--  then delegates to the captured original whenever gravity is on, which means
--  there is no second copy of vanilla's function to keep in sync across
--  Starbound releases -- the thing the handoff warns about for petBehavior.
--
--  MUST BE LISTED AFTER groundPet.lua. If it is listed before, the capture
--  below binds nil and every ground-path call raises. That is loud, which is
--  the point -- see petports_think.lua on why a nil guard here would be worse.
--
--  CRITICAL: no init, update or uninit in this file. A second definition of any
--  of those silently replaces groundPet.lua's.
--
--  WHY THE SHADOW EXISTS AT ALL -- THE GATE, NOT THE PATHER
--
--  Vanilla's arrival test is the elseif in:
--
--      if self.approachPosition and (targetDistance > stopDistance or not mcontroller.onGround()) then
--        ...
--        return false
--      elseif targetDistance <= stopDistance then
--        return true
--      end
--
--  `not mcontroller.onGround()` is PERMANENTLY TRUE for a gravity-disabled
--  actor, so the first branch always wins whenever approachPosition is set and
--  the arrival branch is unreachable. A flyer would reach its target, sit on
--  it, and report not-arrived until APPROACH_TIMEOUT killed the task. Every
--  task, forever.
--
--  For a ground unit that disjunct is correct and deliberate: do not declare
--  arrival while airborne, keep going until you land. It only fails for an
--  actor that never lands.
--
--  NOTE what is NOT the problem, because it looks like it should be:
--  PathMover:move's return value. approachPoint never uses it as an arrival
--  signal -- it only compares against "running" to pick an animation state.
--  Arrival is decided by distance to the RAW target and nothing else.
--
--  THE SECOND VANILLA FAILURE THIS SIDESTEPS
--
--  Vanilla resolves the target with findGroundPosition and, when that returns
--  nil, leaves self.approachPosition holding whatever it held last -- it is
--  assigned and never cleared. With nothing ever assigned, the gate is false,
--  targetDistance is greater than stopDistance, and the function falls off the
--  end returning nil: no movement, no arrival, no log line. For a ground unit
--  that needs a target with no floor within twenty tiles. For a flyer it is the
--  ordinary case, which is why this branch does no ground resolve at all.
--
--  Targets arrive here ALREADY RESOLVED, by petports_flyPointNear through
--  standableNear and petports_standingPointNear. Resolving again here would be
--  the split the handoff records under "the router and the walker must aim at
--  the same point".

local vanillaApproachPoint = approachPoint
local vanillaSetJumpState = setJumpState

local BUILD_STAMP = "2026-08-27n string-pulled fly mover"
local stampLogged = false

--  DELETE ME ONCE THE ANSWER IS IN THE LOG.
--
--  THE ONE THING THIS WHOLE LOCOMOTION CLASS RESTS ON AND THAT NOTHING HAS
--  MEASURED: does the engine's platformer A* actually EMIT Fly edges for a
--  gravity-disabled actor?
--
--  Everything downstream of it is confirmed from vanilla source --
--  PathMover:edgeMove dispatches "Fly" to moveFly, moveFly issues
--  mcontroller.controlFly, debugPathEdgeColor has a Fly case, and
--  PathFinder:canPathfind checks gravityEnabled explicitly. That is three
--  independent pieces of scaffolding for flying pathers, which is strong
--  circumstantial evidence and is still not a measurement. PathFinder:start
--  hands baseParameters straight to world.platformerPathStart and the search
--  itself is C++, so the only way to know is to look at what comes back.
--
--  ONE LINE PER PLAN, not per tick. Fires when a plan first appears and again
--  whenever its shape changes, so a run of identical plans costs one line.
--
--  READING IT: a tally that is all Fly is the answer this was built for. A tally
--  carrying Walk/Jump/Arc/Land means the search is still planning ground
--  traversal for an actor that cannot walk, and the movers those edges dispatch
--  to are all onGround-gated -- which would present as a flyer that plans
--  routes and never executes them.
--  DRAW THE PLAN. Turns on vanilla's own renderer; nothing here draws anything.
--
--  PathMover:move already calls debugPath(self.finder) EVERY TICK. It is gated
--  on self.debug, which groundPet.lua's init sets to false and which nothing
--  else in vanilla or in this mod ever writes again. So the whole plan renderer
--  has been sitting there running into a disabled branch the entire time.
--
--  WHAT IT DRAWS: a line per edge from the unit's position along every
--  remaining waypoint, plus a point at each one, coloured by ACTION --
--
--      magenta  Fly          blue    Walk        green   Jump
--      cyan     Drop         yellow  Land        red     Arc
--
--  which means it answers two questions at once and neither of them needs a log
--  line. Whether the edges are Fly at all, and whether a detour is in the PLAN
--  or only in the EXECUTION. Those have completely different fixes and nothing
--  short of seeing the plan separates them: a bump the renderer draws is the
--  search and no amount of airForce will touch it, while a bump the unit flies
--  through a straight drawn line is drift and airForce is exactly the knob.
--
--  Requires /debug in game. Also switches on groundPet's drawDebugResources,
--  which puts resource bars over the unit -- noisy, harmless, and the reason
--  this is a toggle rather than being left on.
local DRAW_PLAN = true

--  ANSWERED 2026-08-27, IN GAME, BY LOOKING: the plan draws MAGENTA end to end,
--  so the engine's platformer A* does emit Fly edges for a gravity-disabled
--  actor. That was the single unmeasured assumption this whole locomotion class
--  rested on and it is now settled.
--
--  Left in place and defaulted OFF rather than deleted, because it answers the
--  same question for the aquatic class and for any plan that starts coming back
--  with Walk or Arc in it -- which would mean the search had reverted to ground
--  traversal for an actor that cannot walk.
local PLAN_SHAPE_DEBUG = false

local function reportPlanShape(finder)
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

--  HOW CLOSE COUNTS AS ARRIVED, AND WHY IT IS THIS NUMBER.
--
--  The collision poly's eight vertices are (+-0.8, +-0.6) and (+-0.6, +-0.8).
--  Every one of them has magnitude sqrt(0.64 + 0.36) = exactly 1.0, so the
--  octagon is inscribed in a unit circle and the body's circumradius is 1.0
--  with nothing to estimate. A flyer cannot put its centre closer than that to
--  a point its body cannot enter, so this is the tightest honest value.
--
--  DELIBERATELY OVERRIDES THE CALLER'S stopDistance rather than taking a min or
--  a max of it. The callers' values are ground-unit numbers: petportsTaskAction
--  passes ARRIVAL_DISTANCE 1.5, which is slack for a unit standing on a floor
--  BESIDE a target that may be a tile up. A flyer goes to the tile itself, so
--  1.5 would report arrival a full body-width short.
--
--  If a caller ever genuinely needs a different radius, give it an argument --
--  do not quietly reintroduce stopDistance here, because then a ground-tuned
--  number silently becomes a flyer's.
local FLY_ARRIVAL = 1.0

--  Log a path that ended without arriving, once per change of reason.
--
--  A FLYER HAS NO STALL DETECTION AT ALL, and this is the whole of what it gets
--  for now. Every recovery ladder in petportsTaskAction -- tryPlanDrop, the
--  SURFACE clearance replan, the airborne-edge stall, the grounded-walk stall
--  -- is gated on mcontroller.onGround() and is therefore dead code here. That
--  is mostly good: none of them can misfire. But it means an unexecutable Fly
--  edge produces no named line, and the only thing left watching is vanilla's
--  stuckTimer plus the displacement reset in update().
--
--  Change-gated rather than log-once, per the logging discipline: a log-once
--  hides a stuck state and a per-tick line buries everything else.
local function reportFlyPathEnd(result, targetPosition, distance)
  local reason = tostring(result)

  if self.petportsFlyPathEnd == reason then return end
  self.petportsFlyPathEnd = reason

  sb.logInfo("UNIT FLY path ended with %s at %s: target %s still %s away (arrival %s) "
    .. "-- replanning next tick",
    reason,
    sb.printJson(mcontroller.position()),
    sb.printJson(targetPosition),
    sb.printJson(distance),
    sb.printJson(FLY_ARRIVAL))
end


--------------------------------------------------------------------------------
--  ANIMATION -- A FLYER IS NEITHER JUMPING NOR FALLING
--------------------------------------------------------------------------------

--  Shadows groundPet.lua's setJumpState, same capture-and-delegate as
--  approachPoint above. Ground units get vanilla's, untouched.
--
--  THE STUTTER. Vanilla is:
--
--      if mcontroller.yVelocity() > 0 then "jumping" else "falling" end
--
--  A flyer is never onGround, so BOTH setMovementState and setIdleState fall
--  through to this every tick. Its y velocity sits on zero and crosses it
--  constantly -- more so the higher airFriction goes, because friction is what
--  parks the value on the boundary in the first place. Every crossing is a
--  DIFFERENT animation state, and switching states restarts the cycle.
--
--  That is the trap petports_flyer.animation already records for the thinking
--  spinner: "switching between spin and spinflip RESTARTS the cycle, so a unit
--  that oscillates its facing will stutter". Identical cause, different pair.
--
--  Invisible while every movement state aliases the same run.<frame> strip --
--  the stutter is the cycle resetting, not the frames changing. It would become
--  a visible pop the moment a hover cycle and an idle cycle differ.
--
--  WHY SPEED AND NOT y VELOCITY. Asking "which way am I moving vertically" is
--  the wrong question about an actor with no gravity; "am I under way or
--  holding station" is the right one, and it is the same distinction
--  setMovementState draws for a walker. It also gives real art somewhere to
--  hang: run for transit, idle for station-keeping.
--
--  HYSTERESIS IS THE ENTIRE POINT. A single threshold reintroduces the same
--  metronome one band lower, because the deciding value would still be free to
--  sit on it. Nothing changes state between STILL and MOVING; it holds whatever
--  it last had.
local FLY_ANIM_MOVING = 2.0
local FLY_ANIM_STILL = 0.5


--  MEASURE THE FLY COMMAND. DELETE ME ONCE THE HICCUP IS EXPLAINED.
--
--  THE HYPOTHESIS THIS TESTS. Vanilla's moveFly is:
--
--      mcontroller.controlFly(self.delta)
--
--  and controlFly takes a VELOCITY while self.delta is a DISPLACEMENT --
--  world.distance(nextPathPosition, position), recomputed in updateEdge every
--  tick. So the commanded speed IS the distance to the next waypoint. Five
--  tiles out it commands 5, one tile out it commands 1, a quarter tile out it
--  commands 0.25. On a plan made of roughly one-tile Fly edges, flySpeed is a
--  ceiling the unit barely touches.
--
--  If that holds it predicts the one-tile vertical hiccup directly. Near a
--  waypoint the command shrinks toward zero and high airFriction kills what is
--  left, so the DIRECTION of the command is dominated by whatever residual
--  error remains -- and if that residual is mostly vertical, the unit is
--  briefly commanded almost straight up or down. passedTarget then fires on the
--  x axis alone (it is an OR), delta jumps back to a full tile, and it
--  recovers. Two edges, then normal.
--
--  It also explains the inconsistency without needing a timer: whether the
--  residual is vertical depends on sub-tile phase, which differs on every run
--  across the same stretch.
--
--  WHAT TO READ. cmd is the commanded speed and spd is the actual one.
--
--    cmd tracking the distance to the next waypoint and sitting well under
--    flySpeed  ->  hypothesis confirmed, and the fix is a moveFly shadow that
--                  normalises the direction to flySpeed instead of passing the
--                  raw displacement.
--    cmd pinned near flySpeed regardless of distance  ->  hypothesis dead, the
--                  engine is normalising internally, and the hiccup is
--                  something else. Look at cmdY next: a large vertical
--                  component on an edge whose target is level is the OR firing.
--
--  SAMPLED, NOT PER TICK. Every FLY_SAMPLE seconds while a plan is running.
--  Per-tick would be the largest thing in the log by an order of magnitude and
--  the values change slowly enough that it would say nothing extra.
local FLY_TELEMETRY = true
local FLY_SAMPLE = 0.5

local function sampleFlyCommand(dt)
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


--------------------------------------------------------------------------------
--  MOVEMENT -- STRING-PULL THE FLY PLAN
--------------------------------------------------------------------------------

--  REPLACEMENT FOR PathMover:moveFly. Assigned to the pather INSTANCE, so it
--  shadows PathMover.moveFly through the metatable for this pather only --
--  vanilla's stays reachable, no other entity is affected, nothing is patched
--  globally. Same technique as petportsJumpMover and the other four.
--
--  THE PROBLEM, MEASURED 2026-08-27 IN GAME.
--
--  Fly edges are one tile apart and the unit covers one tile per script tick:
--
--      07.949  [3764.12,1011.8]      srcDist 1.11743  dstDist 0.117458
--      08.030  [3765.12,1011.8]      srcDist 1.11719  dstDist 0.117188
--      08.114  [3766.12,1011.8]      srcDist 1.11694  dstDist 0.116943
--
--  1.00 tile per ~81ms at flySpeed 12, landing a constant 0.117 PAST each
--  waypoint and advancing exactly one edge per tick. The control loop gets ONE
--  SAMPLE PER WAYPOINT. It is sitting on the Nyquist limit and cannot track a
--  path whose waypoints are spaced at its own per-tick travel distance.
--
--  On level ground that is invisible -- y holds to within 0.002 for twenty
--  edges. It bites when a plan puts its whole vertical change on ONE edge:
--
--      07.381  ACQUIRED at [3758.24,1012.8] vel [0,0], edge 1 of 30
--                                           dst [3759,1011.8]  -- 45 deg dive
--      07.461  at [3758.85,1012]      dstDist 0.255
--      07.543  at [3759.45,1011.21]   OVERSHOT y by 0.59, now edge 2
--      07.625  at [3760.13,1011.94]   reversed, overshot back by 0.14
--      07.704  at [3761.12,1011.78]   settled
--
--  Every excursion in that session was edge 1 of a fresh plan; not one was
--  mid-plan. The vertical response is INSTANT -- the sign flips in a single
--  tick -- so this is not sluggishness and no amount of airForce touches it.
--  It is a step input the unit is committed to for the one tick it holds.
--
--  THE FIX: STEER AT THE FURTHEST VISIBLE WAYPOINT, NOT THE NEXT ONE.
--
--  In the case above, aiming from [3758.85,1012] at [3765,1011.8] instead of
--  [3759,1011.8] turns a 53-degree dive held for two ticks into a 2-degree
--  descent spread over seven. The vertical change stops being a step.
--
--  This makes edge granularity irrelevant rather than fighting it, and it kills
--  the passedTarget defect as a side effect: that predicate is
--
--      passedTargetOnAxis(edge, 1) or passedTargetOnAxis(edge, 2)
--
--  an OR, so a waypoint is consumed the moment EITHER component is crossed
--  while the other still carries error. A unit that stays on the line crosses
--  both together and the OR stops being reachable.
--
--  THE CURSOR IS NOT ADVANCED TO THE AIM POINT. Only the steering target
--  changes; the plan is still walked edge by edge and passedTarget still owns
--  advancement. Skipping the cursor ahead would discard edges the unit has not
--  actually passed and would desync every consumer of currentEdgeIndex -- the
--  pre/post-move lines, the stall detectors, debugPath.

--  How many edges ahead may be considered. Bounded because the sweep cost is
--  per candidate and because an aim point far enough away stops describing the
--  plan at all.
local FLY_LOOKAHEAD = 6

--  And a hard distance cap, because an edge is not guaranteed to be one tile.
local FLY_AIM_RANGE = 8.0

--  Sampling interval along the candidate line. The body is 1.6 wide, so
--  consecutive samples at 0.8 overlap exactly and leave no gap for a corner to
--  hide in.
local FLY_SWEEP_STEP = 0.8

--  MATCHES planWalkBlocked's set, and Platform is excluded for the same reason
--  it is excluded there: a platform does not obstruct travel, and including it
--  would refuse every shortcut passing under one.
local FLY_SWEEP_SET = { "Null", "Block", "Dynamic" }

--  Can this body travel the straight line from `from` to `to` without clipping?
--
--  Sweeps the BOUNDING BOX along the line rather than testing a line of points.
--  A point test would happily approve a route that takes the unit's shoulders
--  through a corner, which is the whole failure mode this is meant to avoid --
--  and it is the same mistake as the padded standingBoundBox recorded in the
--  handoff: a lie about the body produces a plan the body cannot fly.
--
--  Conservative by construction. A refused shortcut costs one tick of vanilla
--  behaviour; an approved shortcut through geometry costs a wedged unit.
local function flyPathClear(from, to)
  local span = world.distance(to, from)
  local length = math.sqrt(span[1] * span[1] + span[2] * span[2])
  if length < 0.001 then return true end

  local bounds = mcontroller.boundBox()
  local steps = math.ceil(length / FLY_SWEEP_STEP)

  for i = 0, steps do
    local t = i / steps
    local x = from[1] + span[1] * t
    local y = from[2] + span[2] * t

    local region = {
      x + bounds[1], y + bounds[2],
      x + bounds[3], y + bounds[4]
    }

    if world.rectTileCollision(region, FLY_SWEEP_SET) then return false end
  end

  return true
end

function petportsFlyMover(pather)
  --  Vanilla's consume loop, unmodified. Runs first so the cursor is current
  --  before anything looks ahead of it.
  while pather.edge and pather.edge.action == "Fly" do
    if passedTarget(pather.edge) then
      pather:advancePath()
    else
      break
    end
  end

  if pather.edge == nil or pather.edge.action ~= "Fly" then
    pather.petportsFlySkip = nil
    return "running"
  end

  local here = mcontroller.position()
  local finder = pather.finder

  --  FURTHEST FIRST, AND THAT ORDER IS THE OPTIMISATION.
  --
  --  Open air is the common case and it answers on the first candidate -- one
  --  sweep of about ten samples. Testing nearest-first would sweep every
  --  candidate every tick to reach the same answer. Cluttered terrain degrades
  --  to one sweep per candidate, which is the price of being in clutter.
  local aim = pather.edge.target.position
  local skip = 0

  for i = FLY_LOOKAHEAD, 1, -1 do
    local ahead = finder ~= nil and finder.lookAhead and finder:lookAhead(i) or nil

    --  Fly edges only. A plan that changes action mid-run is not one to smooth
    --  across -- the mover for that action owns its own approach.
    if ahead ~= nil and ahead.action == "Fly"
       and ahead.target ~= nil and ahead.target.position ~= nil then

      local candidate = ahead.target.position
      local span = world.distance(candidate, here)

      if math.sqrt(span[1] * span[1] + span[2] * span[2]) <= FLY_AIM_RANGE
         and flyPathClear(here, candidate) then
        aim = candidate
        skip = i
        break
      end
    end
  end

  pather.petportsFlySkip = skip
  pather.petportsFlyAim = aim

  local delta = world.distance(aim, here)
  mcontroller.controlFly(delta)
  pather.deltaX = delta[1]

  return "running"
end

function setJumpState()
  if mcontroller.baseParameters().gravityEnabled then
    return vanillaSetJumpState()
  end

  local velocity = mcontroller.velocity()
  local speed = math.sqrt(velocity[1] * velocity[1] + velocity[2] * velocity[2])

  local state = self.petportsFlyAnim
  if speed >= FLY_ANIM_MOVING then
    state = "run"
  elseif speed <= FLY_ANIM_STILL then
    state = "idle"
  end

  --  Between the bands with nothing cached yet -- only reachable on the first
  --  call of a unit's life, which is why it is a default rather than a branch.
  if state == nil then state = "idle" end

  --  ONLY ON CHANGE. Re-setting the same state is a no-op in the engine, but
  --  the cache is what makes the hysteresis band mean anything: without it
  --  there is nothing to hold.
  if state ~= self.petportsFlyAnim then
    self.petportsFlyAnim = state
    animator.setAnimationState("movement", state)
  end
end

function approachPoint(dt, targetPosition, stopDistance, running)
  --  GROUND UNITS TAKE VANILLA'S PATH, UNMODIFIED. Guarded even though this
  --  file is only listed in the flyer's monstertype, because the day someone
  --  adds it to the drone's list is the day that costs a session otherwise.
  if mcontroller.baseParameters().gravityEnabled then
    return vanillaApproachPoint(dt, targetPosition, stopDistance, running)
  end

  --  First flyer call only. Same reason the task action's stamp is not at file
  --  scope: a stale file that never runs logs nothing, and the point of a stamp
  --  is to catch exactly that.
  if not stampLogged then
    stampLogged = true
    sb.logInfo("PETPORTS flyapproach build: %s (gravityEnabled %s, flySpeed %s, airFriction %s)",
      BUILD_STAMP,
      tostring(mcontroller.baseParameters().gravityEnabled),
      sb.printJson(mcontroller.baseParameters().flySpeed),
      sb.printJson(mcontroller.baseParameters().airFriction))

    --  Set here rather than at file scope: this file must define no init, and
    --  groundPet.lua's init would overwrite it anyway -- it assigns
    --  self.debug = false unconditionally, and it runs after every chunk loads.
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

  --  ARRIVAL IS TESTED FIRST, WHICH IS THE WHOLE FIX. Vanilla tests it last,
  --  behind a gate a flyer can never open.
  if targetDistance <= FLY_ARRIVAL then
    --  STOP, EXPLICITLY. airFriction would bleed the velocity off on its own,
    --  but stateData.arrived LATCHES in petportsTaskAction and nothing calls
    --  back in here afterwards -- so whatever velocity is carried at this
    --  instant is what the unit coasts on through its dwell and its act phase,
    --  with no gravity to settle it and nothing watching. Zeroing costs one
    --  call on the single tick that arrives.
    --
    --  RAISING airFriction DOES NOT MAKE THIS REDUNDANT. It has gone 0.25 ->
    --  1.0 -> 2.0 across three in-game runs, which shortens the coast each time
    --  but cannot remove it: friction decays velocity over time and this latch
    --  fires on a single tick. Do not delete this on the strength of a friction
    --  change, however tight that number gets.
    mcontroller.controlFly({0, 0})
    mcontroller.setVelocity({0, 0})

    setIdleState()
    self.petportsFlyPathEnd = nil

    return true
  end

  --  RAW, NO GROUND RESOLVE. See the header.
  self.approachPosition = targetPosition

  --  Vanilla's own line. petportsTaskAction.freshPather has normally built this
  --  already with our path options; this is the fallback for any caller that
  --  reaches approachPoint without one, and it matches what vanilla would do.
  self.pather = self.pather or PathMover:new({run = running})
  self.pather.options.run = running

  --  ASSIGNED EVERY TICK, NOT ONCE. petportsTaskAction.freshPather builds a NEW
  --  pather per task -- deliberately, because PathFinder:reset does not clear
  --  aStar -- and it lives in a file shared with the ground drone, which must
  --  not learn about this mover. Re-asserting here is what keeps the two apart
  --  without a nil-guarded call in shared code, which is the silent-failure
  --  shape petports_think.lua warns about.
  if self.pather.moveFly ~= petportsFlyMover then
    self.pather.moveFly = petportsFlyMover
  end

  local result = self.pather:move(targetPosition, dt)

  reportPlanShape(self.pather.finder)
  sampleFlyCommand(dt)

  if result == "running" then
    self.petportsFlyPathEnd = nil
    mcontroller.controlFace(self.pather.deltaX or toTarget[1])
    setMovementState(running)
  else
    --  PathFinder:update returns false when the path runs out, so this is both
    --  "no route" and "route finished short of the arrival radius". They are
    --  worth telling apart eventually; for now the distance in the line says
    --  which one it was.
    reportFlyPathEnd(result, targetPosition, targetDistance)
    setIdleState()
  end

  return false
end
