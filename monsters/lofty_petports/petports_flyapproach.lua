--  M.A.U.S. UTILITY UNIT -- FREE-MOVEMENT APPROACH
--
--  Shadows groundPet.lua's approachPoint and setJumpState for any chassis that
--  moves without gravity -- flyers, swimmers, and amphibious units, which are
--  the same movement layer with different MEDIUM permissions rather than
--  different locomotion code.
--
--  SHARED, AND THE GATE IS NOW LOAD-BEARING.
--
--  This was flyer-only, listed in one monstertype, and its safety came from the
--  ground drone never loading it. That stops being true the moment an
--  amphibious GROUND chassis needs the avoidLiquid correction below, so the
--  runtime gravity check is now the thing keeping ground units on vanilla's
--  path rather than a belt-and-braces second line. Treat it accordingly: any
--  new branch here must state which chassis it applies to.
--
--  CAPTURE AND DELEGATE WHERE POSSIBLE; A PARALLEL COPY WHERE IT IS NOT
--
--  setJumpState is a delegate. approachPoint WAS one and is now a parallel
--  implementation, because the defect it had to fix sits inside vanilla's body
--  rather than around it. See the ground branch for the measurement.
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

--  approachPoint IS NO LONGER CAPTURED, and that is a deliberate downgrade from
--  capture-and-delegate to a parallel implementation. The reason is in the
--  ground branch below: the line needing correction is inside vanilla's body,
--  so there is nothing useful to delegate to. setJumpState is still a genuine
--  delegate, and stays one.
local vanillaSetJumpState = setJumpState

local BUILD_STAMP = "2026-09-01c fallback pathers via petports_freshPather"
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
--
--  OFF 2026-08-30. The resource bars were obscuring the port during
--  multi-chassis testing. IT IS ONE FLAG WITH TWO CONSUMERS -- self.debug gates
--  both groundPet's bars and PathMover's debugPath -- so turning the bars off
--  costs the plan lines too. Separating them means shadowing groundPet's draw,
--  which is not worth it while the arc mover is settled; turn this back on for
--  any session that is looking at plans again.
local DRAW_PLAN = false

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
--  DIAGNOSTIC. DELETE ONCE THE ANSWER IS IN THE LOG.
--
--  THE QUESTION: is a failed search failing because THE UNIT IS STANDING
--  SOMEWHERE THE PATHFINDER CANNOT PLAN FROM?
--
--  petports_flyPointNear nudges to a SUB-TILE position where the body fits --
--  y 1146.8 rather than the tile centre 1146.5 -- which is what stopped flyers
--  scooping items through walls and is not a mistake to undo. But the engine's
--  A* navigates between TILE-ALIGNED nodes, and nothing has ever checked that a
--  nudged position is somewhere a search can START.
--
--  If it is not, the search has nothing to expand and exhausts immediately.
--  That matches what was measured: "pathfinding" then "false" on alternate
--  ticks at a FIXED position, with a target 49 tiles away and maxFScore 1200.
--  exploreRate is 25-150 by world fidelity, so two ticks is 50 to 300 nodes --
--  not a small region, a search with almost nothing to look at.
--
--  READING IT. Three outcomes and they point three different ways:
--
--    body fits HERE but NOT at the tile centre
--        confirmed. The nudge parks units where the pathfinder cannot begin,
--        and the fix is to steer to the nearest tile-centre-valid position
--        before planning -- the same search the nudge runs, inverted.
--
--    body fits at NEITHER
--        different bug. The unit is somewhere it does not fit at all, and how
--        it got there is the question rather than why it cannot plan.
--
--    body fits at BOTH
--        hypothesis dead. The start is fine and the failure is in the engine's
--        neighbour generation, which is where this was before the nudge became
--        the suspect.
--
--  Also reports the TARGET the same way, because a goal the search cannot place
--  on a node is unreachable for the same reason and would look identical.
local function probeStartNode(targetPosition)
  local bounds = mcontroller.boundBox()

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

local function reportFlyPathEnd(result, targetPosition, distance)
  local reason = tostring(result)

  if self.petportsFlyPathEnd == reason then return end
  self.petportsFlyPathEnd = reason

  --  Only on a genuine failure. "pathfinding" means the search is still
  --  running and says nothing about the start being valid.
  if result == false then probeStartNode(targetPosition) end

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

--  REPLACEMENT FOR BOTH PathMover:moveFly AND PathMover:moveSwim.
--
--  THE ENGINE EMITS "Swim" EDGES, NOT "Fly", FOR A SUBMERGED ACTOR. Measured
--  2026-08-27: an aquatic unit's plan came back "Swim edge 3 of 20" throughout,
--  so edgeMove dispatched to moveSwim and this mover -- assigned only to
--  moveFly -- was never called once. The telemetry said so plainly, since `aim`
--  and `skip` are written nowhere else and both logged null on every line.
--
--  WHAT VANILLA'S moveSwim DOES, AND WHY IT IS NOT ENOUGH:
--
--      function PathMover:moveSwim()
--        self.deltaX = self.delta[1]
--        mcontroller.controlApproachVelocity(
--          vec2.mul(vec2.norm(self.delta), mcontroller.baseParameters().walkSpeed),
--          mcontroller.baseParameters().liquidJumpProfile.jumpControlForce)
--        if passedTarget(self.edge) then self:advancePath() end
--        return "running"
--      end
--
--  Three defects in four lines. No look-ahead, so the one-sample-per-edge
--  problem this mover exists to solve is back in full. NO `while` LOOP -- it
--  advances at most ONE edge per tick where moveFly drains the whole passed
--  run, so an overshoot of more than one edge leaves the cursor BEHIND the unit
--  and the next command points back at a waypoint already passed. That is the
--  visible back-and-forth. And it steers on walkSpeed through
--  liquidJumpProfile.jumpControlForce, neither of which any chassis here tunes:
--  measured speed was a rigid 4.8, which is walkSpeed 8 x the 0.6 friction
--  sampling factor, not flySpeed at all.
--
--  controlFly IS THE SWIM PRIMITIVE FOR A FREE MOVER. Vanilla's own fish issue
--  exactly that call while submerged, and it honours flySpeed with liquidForce
--  and liquidFriction governing instead of the air pair.
--
--  IT IS NOT THE PRIMITIVE FOR A GRAVITY-ENABLED CHASSIS, which is a correction
--  to the first version of this note and cost a test cycle. controlFly does
--  nothing at all for a walker, so a ground unit swimming needs vanilla's
--  controlApproachVelocity. See the actuation branch at the end of the mover.
--
--  So there is still ONE mover bound to both slots -- the steering, the
--  look-ahead and the clearance test are shared by every chassis -- and only
--  the final control call differs.
--
--  Assigned to the pather INSTANCE, so it
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

--  Can this body travel the straight line from `from` to `to`?
--
--  TWO CONDITIONS ON EVERY SAMPLE, geometry and MEDIUM. One-tile plan edges are
--  safe to test at their endpoints, but this line runs up to eight tiles and a
--  shortcut that leaves the water halfway is exactly as illegal as one that
--  clips a corner -- and far easier to miss, because both ends are wet.
--
--  The medium test rides on the samples the body sweep already walks, so it
--  costs nothing beyond the liquid lookups themselves.
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

    --  MEDIUM, SAMPLED ALONG THE SHORTCUT. petports_mediumAllows is the same
    --  predicate the destination resolver uses, so a chassis cannot be offered
    --  a route through something it is not allowed to be offered a position in.
    if not petports_mediumAllows({ x, y }, bounds) then return false end
  end

  return true
end

--  THE MEDIUM HALF OF flyPathClear, WITHOUT THE GEOMETRY HALF.
--
--  EXISTS BECAUSE A PLAN EDGE HAS TO BE VALIDATED ALONG ITS LENGTH AND NOT AT
--  ITS ENDS, and geometry must not enter that question. A* has already decided
--  the edge is geometrically traversable; second-guessing it here would refuse
--  legal routes through terrain it understands better than we do. The MEDIUM is
--  the part it knows nothing about.
--
--  SAME SAMPLING AS flyPathClear so the two cannot disagree about where the
--  waterline is: same step, same body box, same predicate. Only the collision
--  test is absent.
local function flyMediumClear(from, to)
  local bounds = mcontroller.boundBox()

  local span = world.distance(to, from)
  local length = math.sqrt(span[1] * span[1] + span[2] * span[2])

  --  A degenerate line is one point, and that point is `from`. Answering true
  --  here would approve a step the unit is already refusing to be in.
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

--  Both action names this mover owns. A plan may legitimately mix them for an
--  amphibious chassis crossing a surface, and string-pulling across that
--  boundary is safe because flyPathClear tests the MEDIUM on every sample.
local function isFreeEdge(edge)
  return edge ~= nil and (edge.action == "Fly" or edge.action == "Swim")
end

--  WHICH WAYPOINT SHOULD THE UNIT STEER AT FROM `from`?
--
--  EXTRACTED SO THE MOVER AND THE PLAN VALIDATOR CANNOT DRIFT. It was inline in
--  petportsFreeMover, and the validator did not model it at all -- it walked the
--  RAW waypoint chain while the mover flew the STRING-PULLED one. Those are
--  different routes, and validating the one the unit does not fly is how a
--  perfectly good plan came to be refused: see planMediumValid.
--
--  FURTHEST FIRST, AND THAT ORDER IS THE OPTIMISATION.
--
--  Open water is the common case and it answers on the first candidate -- one
--  sweep of about ten samples. Testing nearest-first would sweep every candidate
--  every tick to reach the same answer. Cluttered terrain degrades to one sweep
--  per candidate, which is the price of being in clutter.
--
--  `edgeAt(i)` RETURNS THE EDGE i AHEAD OF THE CURSOR, or nil. A function rather
--  than an index because the mover has a cursor inside the finder and asks
--  finder:lookAhead, while the validator is walking the edge list from outside
--  and has no cursor to ask. The SELECTION RULE is the thing that has to be
--  shared; how the caller finds an edge is its own business.
--
--  RETURNS nil WHEN NOTHING IS REACHABLE, and the caller decides what that
--  means. For the mover it means "aim at the next waypoint"; for the validator
--  it means "the next waypoint is the leg, so it has to be legal itself".
local function aimAhead(from, edgeAt)
  for i = FLY_LOOKAHEAD, 1, -1 do
    local ahead = edgeAt(i)

    --  Fly and Swim only. A plan that changes to a GROUND action mid-run is
    --  not one to smooth across -- the mover for that action owns its own
    --  approach.
    if isFreeEdge(ahead)
       and ahead.target ~= nil and ahead.target.position ~= nil then

      local candidate = ahead.target.position
      local span = world.distance(candidate, from)

      --  flyPathClear TESTS GEOMETRY AND MEDIUM TOGETHER, so a shortcut it
      --  approves is legal on both counts by construction. That is the
      --  property the validator leans on: an approved shortcut needs no
      --  further medium check, and the waypoints it skips need none either,
      --  because the unit never goes to them.
      if math.sqrt(span[1] * span[1] + span[2] * span[2]) <= FLY_AIM_RANGE
         and flyPathClear(from, candidate) then
        return candidate, i
      end
    end
  end

  return nil, 0
end

--------------------------------------------------------------------------------
--  PLAN MEDIUM VALIDATION
--------------------------------------------------------------------------------
--
--  A* HAS NO CONCEPT OF MEDIUM, so it will happily route a chassis through
--  something that chassis is not allowed to occupy. Destinations are gated by
--  petports_flyPointNear and shortcut samples by flyPathClear, and NEITHER
--  COVERS THE PLAN ITSELF: refusing a shortcut only falls back to aiming at the
--  next waypoint, which is still on the illegal route.
--
--  MEASURED, and it was not merely untidy. A flyer -- canSwim false -- was
--  routed through water on the way to an air target, ended up submerged at
--  [2503.97,1146.8], and then A* returned ZERO edges to every target it was
--  given for twenty-one seconds: its own leash, a crate, a machine. Velocity
--  [0,0], standable true, completely frozen. Whether that is a submerged-to-air
--  transition the search cannot express for a gravity-disabled actor, or rising
--  rainwater having sealed the route, is UNRESOLVED -- and prevention does not
--  depend on knowing which, because a flyer that never gets wet never asks.
--
--  VALIDATE THE ROUTE THE UNIT WILL FLY, NOT THE ONE A* HANDED BACK.
--
--  ENDPOINTS WERE NOT ENOUGH, AND THE PREMISE THAT SAID THEY WERE IS RETIRED.
--  It read:
--
--      Plan edges are a tile apart, so a route cannot cross a medium boundary
--      between two consecutive waypoints without one of them landing in it.
--
--  THIS FILE ALREADY CONTRADICTED ITSELF ON THAT POINT. FLY_AIM_RANGE exists
--  because "an edge is not guaranteed to be one tile", forty lines above. Two
--  statements about the same objects, one of them load-bearing for a safety
--  check, and only one of them true.
--
--  MEASURED 2026-08-31: an AQUATIC unit was given a plan that STARTED submerged
--  in one pool and ENDED submerged in another, and travelled through the
--  player's base -- air -- in between. The engine's own validity test is
--  geometric, so a route between two wet nodes through dry air is a route it
--  considers sound; the medium is ours to enforce and we were enforcing it at
--  the wrong granularity.
--
--  AND THEN THE SWEEP WAS TOO STRICT, FOR THE MIRROR-IMAGE REASON. Sweeping the
--  RAW waypoint chain validates a route the unit does not fly. A* contours the
--  ground, so a plan crossing a shallow bar rises to follow it and BRUSHES THE
--  SURFACE on the way over -- one or two waypoints reading air in an otherwise
--  entirely submerged crossing. The mover skips exactly those: aimAhead finds a
--  later waypoint with a clear line and steers at it, and the contour detour is
--  never travelled. Observed in game: a good plan refused over a detour that
--  would not have happened.
--
--  SO THE WALK BELOW IS THE MOVER'S OWN WALK. Same aimAhead, same bounds, same
--  order. Where a shortcut exists the leg IS the shortcut, and flyPathClear has
--  already tested its geometry and its medium together -- the waypoints it skips
--  need no check at all, because the unit never goes to them. Where no shortcut
--  exists the mover aims at the next waypoint, so that waypoint and the leg into
--  it must both be legal, which is what the old sweep tested.
--
--  IT IS AN APPROXIMATION IN ONE DIRECTION, AND THE DIRECTION IS STATED. The
--  validator steps from WAYPOINT to waypoint; the mover asks from the unit's
--  LIVE POSITION, which sits a fraction past each waypoint and drifts off the
--  line. So a shortcut this accepts can fail at runtime. petportsFreeMover
--  covers that case rather than leaving it to luck -- see the hold there.
--
--  ONCE PER PLAN, NOT PER TICK, AND THAT IS WHAT MAKES IT AFFORDABLE. The walk
--  is bounded by FLY_LOOKAHEAD sweeps per step and skips whole runs of edges on
--  success, so it costs less than the old per-edge sweep did. The per-plan gate
--  is petportsPlanSig in the mover and it has to stay.

--  THE ESCAPE CLAUSE IS GONE. A UNIT OUT OF ITS MEDIUM PLANS NOTHING, AND THE
--  PORT SENDS IT HOME.
--
--  Two versions of an escape licence have now been measured and both were the
--  mechanism of a bug rather than a safety net.
--
--  V1, A BLANKET PASS: while the unit was out of medium, EVERY plan was
--  accepted. That latches -- a unit that has left the water is out of medium,
--  so the next plan is unconditional, so it need never come back.
--
--  V2, A BOUNDED PREFIX: the licence covered the leading run of illegal
--  waypoints and ended at the first legal one. Strictly better and still wrong,
--  because ANY water counts as the end of the escape, including a DIFFERENT
--  POOL. Measured 2026-08-31, an aquatic unit blind-steered into a drain-held
--  air gap and was then handed a 25-edge plan -- five Fly edges across the gap,
--  then Swim -- which the prefix licensed end to end as "a route out". It
--  crossed. A 17-edge plan later did the same over a pool rim.
--
--  THE PREMISE WAS THE ERROR, NOT EITHER BOUND. Both versions assume the unit
--  is the right thing to ask for a rescue plan. It is not. A displaced unit
--  wants to be AT ITS PORT, and the port can put it there instantly, for free,
--  with no pathing at all -- rehomeUnit already exists and is the rescue every
--  recovery ladder in this mod ends with. Letting the pather improvise a way
--  back is strictly worse than a teleport and, as measured twice, is a licence
--  to go somewhere else entirely.
--
--  SO THE RULE IS NOW UNCONDITIONAL: no chassis plans a route through a medium
--  it may not occupy, including out of one. The unit refuses, issues no control
--  and holds still; petports_outOfMedium reports the condition and the port's
--  mediumCheck re-homes it. See both.
--
--  A UNIT THAT CANNOT MOVE IS NOT STRANDED HERE, and that is the property that
--  makes the unconditional rule safe. Standing still is the SIGNAL. It was only
--  unsafe while nothing was watching for it.
local function planMediumValid(finder)
  if finder == nil or finder.edges == nil then return true end

  local bounds = mcontroller.boundBox()
  local from = mcontroller.position()

  --  REPORTED TO THE CALLER, NOT JUST USED. The medium a plan STARTED in is
  --  what tells a reader whether a refusal is an ordinary "that route is
  --  illegal" or the displaced case that the port is about to re-home.
  local startMedium = petports_mediumAt(from, bounds)

  --  THE UNIT'S OWN POSITION IS EDGE ZERO. Checked first and refused outright,
  --  because a plan from somewhere illegal is not a plan this chassis should be
  --  flying at all -- see the header.
  if not petports_mediumAllows(from, bounds) then
    return false, 0, from,
      "the unit is ALREADY outside its own medium -- it plans nothing from here "
        .. "and the port will re-home it", startMedium
  end

  local edges = finder.edges
  local index = 1

  --  BOUNDED BY THE EDGE COUNT, NOT BY `while true`. Every branch below either
  --  advances `index` or returns, so the loop terminates on its own -- but a
  --  plan is engine data and a malformed one must not hang the unit's update.
  for _ = 1, #edges do
    if index > #edges then break end

    --  THE MOVER'S OWN CHOICE, MADE THE MOVER'S OWN WAY. `index + i` is the
    --  cursor arithmetic finder:lookAhead does internally; the selection rule
    --  itself is shared rather than restated.
    local shortcut, offset = aimAhead(from, function(i) return edges[index + i] end)

    if shortcut ~= nil then
      --  THE LEG IS THE SHORTCUT AND IT IS ALREADY LEGAL. flyPathClear tested
      --  geometry and medium along it, so there is nothing left to ask -- and
      --  the waypoints between here and there are not tested BECAUSE THE UNIT
      --  DOES NOT VISIT THEM. That is the whole correction: a contour detour
      --  that brushes the surface is not part of the route if it is skipped.
      from = shortcut

      --  RESUME FROM THE WAYPOINT THE SHORTCUT LANDED ON, USING THE OFFSET
      --  aimAhead RETURNED. A first version scanned the edges for the matching
      --  position instead, which meant comparing position tables by identity --
      --  the trap this handoff records for mcontroller.position(). It happens to
      --  hold here, because the table comes from the edge rather than a fresh
      --  allocation, and "happens to hold" is not a property to build on. The
      --  offset is not a second number that has to agree with the point: it is
      --  the index the point was fetched with.
      index = index + offset + 1
    else
      --  NO SHORTCUT, SO THE UNIT AIMS AT THE NEXT WAYPOINT AND ACTUALLY GOES
      --  THERE. Both the point and the leg into it have to be legal, which is
      --  exactly what the previous version of this check asked of every edge.
      local edge = edges[index]
      local target = edge and edge.target and edge.target.position

      if target ~= nil then
        local ok, why = petports_mediumAllows(target, bounds)

        if not ok then
          return false, index, target, why, startMedium
        elseif not flyMediumClear(from, target) then
          --  THE ENDPOINT IS FINE AND THE LEG INTO IT IS NOT. The case endpoint
          --  validation could not see -- named separately so the log says which
          --  check refused.
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


local function planSignature(finder)
  if finder == nil or finder.edges == nil or #finder.edges == 0 then return nil end

  local last = finder.edges[#finder.edges]
  local target = last and last.target and last.target.position

  return tostring(#finder.edges) .. "@"
    .. (target and (tostring(target[1]) .. "," .. tostring(target[2])) or "?")
end

--  SLOW DOWN WHEN A JUMP IS NEXT -- petportsWalkMover's brake, for swimmers.
--
--  THE SAME BUG, IN THE OTHER MEDIUM. moveJump fires only within 1.0 of its
--  source and the Jump edge does not become current until the unit has already
--  crossed that source, so the usable half of the window is one tile wide. At
--  walkSpeed 8 a swimmer covers about 0.64 tiles per look, the radius test runs
--  a whole tick AFTER the handover, and what is left is roughly a 0.36 window
--  sampled every 0.64 tiles. It is a coin flip.
--
--  MEASURED 2026-09-01, four Swim -> Jump handovers at one waterline:
--
--      gap at handover   gap when moveJump ran   outcome
--      0.119             0.728                   takeoff
--      0.023             0.681                   takeoff
--      0.497             0.836                   takeoff
--      0.557             1.194                   REFUSED, unit fell 21 tiles
--
--  Nothing distinguishes the fourth except phase.
--
--  AT JUMP_APPROACH_SPEED THE COIN STOPS BEING FLIPPED. 3.0 is about 0.25 tiles
--  per look, so the handover lands inside a quarter tile and the radius test a
--  tick later still sees under 0.5 -- comfortably inside 1.0 rather than
--  straddling it.
--
--  THE AIM IS ALREADY THE JUMP SOURCE AND THAT IS WHY THIS IS ONLY A SPEED.
--  aimAhead returns Fly and Swim edges only, and a Jump is always followed by
--  Arcs, so on the run-in it finds no shortcut at all and the mover falls
--  through to the current edge's target -- which IS the jump source. The unit
--  was steering at exactly the right point the whole time. It was steering at
--  it at eight tiles a second, and controlApproachVelocity commands a VELOCITY,
--  not a stopping place, so it sailed straight through.
--
--  GRAVITY-ENABLED CALLERS ONLY, matching the swim arm in petportsJumpMover: a
--  free mover neither sinks nor is handed Jump edges, and there is no measured
--  fault to fix for it.
--
--  math.min RATHER THAN ASSIGNMENT, so a chassis slower than 3.0 is never sped
--  UP by a brake.
local function swimApproachSpeed(pather, base)
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

function petportsFreeMover(pather)
  --  Vanilla's consume loop, unmodified. Runs first so the cursor is current
  --  before anything looks ahead of it.
  while isFreeEdge(pather.edge) do
    if passedTarget(pather.edge) then
      pather:advancePath()
    else
      break
    end
  end

  if not isFreeEdge(pather.edge) then
    pather.petportsFlySkip = nil
    return "running"
  end

  local here = mcontroller.position()
  local finder = pather.finder

  --  VALIDATE THE PLAN'S MEDIUM, ONCE PER PLAN.
  local signature = planSignature(finder)

  if pather.petportsPlanSig ~= signature then
    pather.petportsPlanSig = signature

    local ok, index, at, why, startMedium = planMediumValid(finder)
    pather.petportsPlanRejected = not ok

    if not ok then
      sb.logInfo("UNIT PLAN REFUSED at %s (medium %s): edge %s of %s ends at %s, which is %s -- "
        .. "issuing no control, so this task will fail on the progress watchdog "
        .. "rather than fly the unit somewhere it cannot get out of",
        sb.printJson(here), tostring(startMedium), sb.printJson(index),
        sb.printJson(finder.edges and #finder.edges), sb.printJson(at), tostring(why))
    else
      --  THE ACCEPTED CASE IS LOGGED TOO, AND IT IS NOT NOISE.
      --
      --  A plan that is flown is indistinguishable in the log from a plan that
      --  was never checked, which is exactly the ambiguity that let an aquatic
      --  unit cross a base unremarked. One line per PLAN, not per tick -- the
      --  same gate the refusal sits behind -- so a unit working steadily costs
      --  one line per replan.
      --
      --  THE MEDIUM IS IN IT BECAUSE IT IS THE DISCRIMINATOR. "air" here for a
      --  swimmer means the plan was waved through by the escape clause rather
      --  than examined, and that is a completely different bug from a plan that
      --  was examined and passed.
      sb.logInfo("UNIT PLAN accepted at %s (medium %s): %s edge(s), every leg swept",
        sb.printJson(here), tostring(startMedium),
        sb.printJson(finder.edges and #finder.edges))
    end
  end

  --  SCRAP MOTION, DO NOT RESET THE FINDER. Resetting would restart a cold A*
  --  every tick and hand back the same illegal plan; leaving it alone and
  --  issuing nothing lets the progress watchdog fail the task in ten seconds and
  --  the port back it off, which is the correct outcome for a target that is
  --  unreachable within this chassis's medium.
  if pather.petportsPlanRejected then
    pather.petportsFlySkip = nil
    return "running"
  end

  --  THE SELECTION RULE LIVES IN aimAhead, SHARED WITH planMediumValid. It was
  --  inline here, and the validator did not model it -- which is how a plan the
  --  mover would have string-pulled clean over a shallow bar came to be refused
  --  for a contour detour it was never going to fly.
  local aim, skip = aimAhead(here,
    function(i) return finder ~= nil and finder.lookAhead and finder:lookAhead(i) or nil end)

  --  NO SHORTCUT MEANS THE NEXT WAYPOINT IS THE LEG, AND THE VALIDATOR ONLY
  --  ACCEPTED THIS PLAN BECAUSE IT COULD REACH SOMETHING FURTHER.
  --
  --  THE TWO ASK FROM DIFFERENT PLACES AND THAT GAP IS REAL. planMediumValid
  --  steps waypoint to waypoint; this asks from the LIVE position, which sits a
  --  fraction past each waypoint -- measured at a constant 0.35 -- and drifts off
  --  the line under airFriction. So a shortcut the validator approved can fail
  --  here, and the fallback would be to aim at the very contour waypoint the
  --  validator was relying on skipping. On a plan that grazes a waterline that
  --  waypoint is in AIR, and taking it is the unit leaving the water on an
  --  accepted plan -- the exact outcome this whole check exists to prevent.
  --
  --  SO IT HOLDS FOR A TICK RATHER THAN FLYING IT. Issuing no control costs one
  --  tick of acceleration and nothing else: the next tick re-reads the position
  --  and re-asks, and a shortcut that failed on drift alone will usually be back.
  --  If it never comes back the unit stops making progress and the watchdog
  --  fails the task, which is the correct end for a route it cannot legally fly.
  --
  --  ONLY WHEN THE NEXT WAYPOINT IS ITSELF ILLEGAL. A plan with no shortcut and
  --  a legal next waypoint is the ordinary case -- clutter, tight corridors, the
  --  first tick of a plan -- and must keep moving exactly as before.
  if aim == nil then
    --  NOT NAMED `next`. That shadows Lua's own next() for the rest of the
    --  block, and this file calls it elsewhere -- a landmine for whoever adds
    --  the second line to this branch.
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

  --  ACTUATION IS BY CHASSIS. STEERING IS NOT.
  --
  --  Everything above -- draining the passed run, the look-ahead, the swept
  --  clearance test -- is right for anything on a Fly or Swim edge. HOW THE
  --  FORCE IS APPLIED IS NOT, and taking vanilla's whole moveSwim as broken
  --  threw away the one part of it that was correct.
  --
  --  MEASURED: a ground unit standing on the bottom of a lake, planned 22 Swim
  --  edges, target one tile straight up, y velocity pinned at -1.535 for the
  --  entire run and edge 1 never advancing. controlFly is the FLYING-actor
  --  control and does nothing for a gravity-enabled chassis, so no upward force
  --  was ever applied. Before this mover was bound, vanilla's moveSwim moved the
  --  same unit -- badly, but it moved it. That before-and-after is what named
  --  the line.
  --  DESCENDING? HOLD controlDown, OR PLATFORMS WILL STOP THE PLAN DEAD.
  --
  --  THE PATHFINDER WILL ROUTE STRAIGHT DOWN THROUGH A PLATFORM AND IS RIGHT TO.
  --  PlatformerAStar::validPosition tests against CollisionSolid, which is
  --  {Null, Slippery, Block} -- PLATFORM IS NOT IN IT. So a submerged or flying
  --  node happily generates a neighbour one tile below through a platform.
  --
  --  The movement controller disagrees. Standing on a platform, a downward
  --  controlApproachVelocity does nothing at all: the platform holds the unit
  --  up, onGround stays true, and the edge never completes.
  --
  --  MEASURED: an amphibious unit standing on the very crate it was delivering
  --  to, planning "Swim edge 1 of 3, dst [2509,1148.8]" one tile below itself,
  --  velocity pinned, onGround true, for the full ten seconds until the progress
  --  watchdog failed the task.
  --
  --  "THE CRATE IS A PLATFORM" WAS NEVER PROBED FOR THIS OBJECT. It is an
  --  inference from the stall, not a measurement of the crate, and a DIFFERENT
  --  crate in the origin-node investigation measured as Block or Dynamic --
  --  Block, once fact.pathing.collisionkinds rules out Dynamic. Whether all
  --  containers share a collision kind is not something this mod has checked.
  --
  --  THE HOLD DOES NOT REST ON IT. controlDown while descending is vanilla's own
  --  behaviour in flyInGeneralDirection, held unconditionally there for exactly
  --  this hazard; the conditional below is that precedent with a gravity-enabled
  --  chassis accounted for. It is right for platforms whatever this crate was.
  --
  --  VANILLA'S ANSWER IS THE FIRST LINE OF flyInGeneralDirection --
  --  mcontroller.controlDown() held unconditionally, every tick, so platforms
  --  never block a flyer. Neither vanilla's moveSwim nor our replacement did it.
  --
  --  CONDITIONAL, NOT UNCONDITIONAL, AND THE DIFFERENCE MATTERS. Vanilla can
  --  hold it forever because flyInGeneralDirection only ever runs on
  --  gravity-disabled actors, which have nothing to fall through TO. An
  --  amphibious chassis is gravity-ENABLED: hold controlDown permanently and it
  --  drops through every platform it is trying to stand on. So it is held only
  --  while the aim is genuinely below the unit.
  --
  --  THE DEADBAND IS THE POINT. Level travel along a platform must not trip
  --  this, and a string-pulled aim wobbles by fractions of a tile, so a bare
  --  "dy < 0" would fire constantly on a flat run.
  --
  --  NOTE the handoff's warning that controlDown starts an unobservable
  --  fall-through state. That was learned for petportsTimedDrop, which has to
  --  know WHEN the unit has cleared the platform in order to stop dropping.
  --  Nothing here needs to know: the next tick re-reads position and re-aims,
  --  so an extra tick of falling is simply progress along the edge.
  if delta[2] < -0.25 then
    mcontroller.controlDown()
  end

  if mcontroller.baseParameters().gravityEnabled then
    --  Vanilla's actuation, unchanged, including walkSpeed. A swimming ground
    --  unit's speed is a separate tuning question from its steering, and
    --  changing both at once is how a fix stops being attributable.
    local length = math.sqrt(delta[1] * delta[1] + delta[2] * delta[2])

    if length > 0.0001 then
      --  walkSpeed, EXCEPT WITH A JUMP IMMEDIATELY AHEAD. See swimApproachSpeed
      --  -- the run-in to a jump point is the one case where full speed loses
      --  the takeoff window outright, and the walk mover has braked for it on
      --  land since the same failure was measured there.
      local speed = swimApproachSpeed(pather,
        mcontroller.baseParameters().walkSpeed)
      local force = mcontroller.baseParameters().liquidJumpProfile.jumpControlForce

      mcontroller.controlApproachVelocity(
        { delta[1] / length * speed, delta[2] / length * speed }, force)
    end
  else
    --  Free movers: controlFly honours flySpeed and is the primitive vanilla's
    --  own fish use while submerged.
    mcontroller.controlFly(delta)
  end

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
  --  GROUND UNITS TAKE A PARALLEL COPY, NOT VANILLA'S.
  --
  --  This delegated to vanillaApproachPoint until 2026-08-27. It cannot any
  --  more, because the one line that needs correcting lives inside it:
  --
  --      findGroundPosition(targetPosition, -20, 1, util.toDirection(-toTarget[1]))
  --
  --  The fourth parameter is avoidLiquid and it is being handed a DIRECTION.
  --  Both 1 and -1 are truthy, so vanilla always avoids liquid here by accident
  --  and offers no way to ask otherwise. That made our standableNear and
  --  vanilla's internal resolver disagree about the same point, which is how a
  --  ground unit came to stand still for 10.7 seconds with approachPosition nil.
  --
  --  EVERYTHING ELSE BELOW IS VANILLA'S, LINE FOR LINE, DELIBERATELY. Only the
  --  avoidLiquid argument, the moveSwim binding and the closing log line differ,
  --  so when Starbound changes groundPet.lua the diff to re-check is exactly
  --  this one function and the three deviations are marked.
  if mcontroller.baseParameters().gravityEnabled then
    local toTarget = world.distance(targetPosition, mcontroller.position())
    local targetDistance = world.magnitude(targetPosition, mcontroller.position())

    --  THE CORRECTION, AND THE ONLY ONE. A real boolean from the chassis flag.
    local groundPosition = findGroundPosition(targetPosition, -20, 1,
      petports_avoidLiquid())

    --  AND THE SAME GATE HERE, because this resolver is independent of the
    --  other two and a disagreement between them is what left a unit standing
    --  still with approachPosition nil earlier tonight.
    if groundPosition and not petports_mediumAllows(groundPosition) then
      groundPosition = nil
    end

    if groundPosition then
      self.approachPosition = groundPosition
    end

    --  FALLBACK PATHER, VIA freshPather RATHER THAN BY HAND. 2026-09-01.
    --
    --  This read `self.pather = self.pather or PathMover:new({run = running})`
    --  followed by a single moveSwim binding. A pather built that way ran
    --  VANILLA moveJump, which ignores `edge.jumpVelocity` and fires at full
    --  strength -- harmless while the planner only ever drew 45s, and a real
    --  wrong-jump since `smallJumpMultiplier` left 1.0 and 22.5 edges started
    --  appearing. Answering a 22.5 edge with a 45 launch is exactly the failure
    --  the old velocity pin existed to stop.
    --
    --  ONE PLACE KNOWS WHAT A PATHER NEEDS, and it is freshPather: moveJump,
    --  moveWalk, moveArc, moveSwim, timedDrop, keepDropping, the path options
    --  and the explore rate. Binding a subset here is how the set drifted out of
    --  agreement in the first place, so the subset is gone rather than extended.
    --
    --  THE moveSwim RE-ASSERTION THAT USED TO FOLLOW IS DELETED, NOT MOVED.
    --  Every pather now comes from freshPather -- this site, the fly site below,
    --  and petportsTaskAction on entering any task state -- and freshPather
    --  binds moveSwim for every chassis. There is no longer a path that reaches
    --  here with a pather lacking it.
    --
    --  THE NARROW CASE THIS FIRES IN: freshPather runs on entering any task
    --  state including leash, and `self.pather` persists on the script table,
    --  so only a unit that reaches petportsSleepAction before it has ever held
    --  a task can get here -- a fresh spawn that goes straight to rest.
    --
    --  VIA petports_freshPather, NOT freshPather. THAT DISTINCTION CRASHED A
    --  UNIT ON 2026-09-01.
    --
    --  freshPather is a FILE-LOCAL in petportsTaskAction.lua, forward-declared
    --  so tryVentRoute can call it early. A local is invisible across files, so
    --  a bare `freshPather` here resolves to a nil global and the call is a hard
    --  error -- which vanilla's inspectAction hit through approachPoint one tick
    --  after a beaching, killing the unit. petports_freshPather is the wrapper
    --  that file exposes for exactly this.
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

    --  VANILLA FALLS OFF THE END HERE AND RETURNS nil, WHICH IS NOT NOTHING.
    --
    --  It happens when no ground position has ever been assigned and the target
    --  is still far away -- so the unit does not move, does not arrive, and
    --  says nothing. That silence is what made the submerged-upcycler failure
    --  take ten seconds to show up as anything at all. The behaviour is
    --  unchanged, because callers already treat nil as "not arrived"; only the
    --  silence is fixed.
    if self.petportsNoGroundAt ~= sb.printJson(targetPosition) then
      self.petportsNoGroundAt = sb.printJson(targetPosition)
      sb.logInfo("UNIT no ground position for %s (avoidLiquid %s) -- approachPosition is %s, "
        .. "so this unit will not move toward it",
        sb.printJson(targetPosition), tostring(petports_avoidLiquid()),
        self.approachPosition and sb.printJson(self.approachPosition) or "nil")
    end

    return nil
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

  --  SAME FIX AS THE GROUND BRANCH ABOVE, 2026-09-01: build through freshPather
  --  rather than by hand, so the pather gets moveJump, moveWalk, moveArc,
  --  moveSwim, timedDrop and keepDropping instead of vanilla's for all but one.
  if self.pather == nil then
    petports_freshPather("approachPoint fly fallback -- no task pather yet")
  end
  self.pather.options.run = running

  --  ASSIGNED EVERY TICK, NOT ONCE, AND STILL NECESSARY AFTER THAT CHANGE.
  --  petportsTaskAction.freshPather builds a NEW pather per task -- deliberately,
  --  because PathFinder:reset does not clear aStar -- and it lives in a file
  --  shared with the ground drone, which must not learn about this mover.
  --  Re-asserting here is what keeps the two apart without a nil-guarded call in
  --  shared code, which is the silent-failure shape petports_think.lua warns
  --  about.
  --
  --  freshPather DOES NOT BIND moveFly, WHICH IS WHY THIS BLOCK SURVIVED THE
  --  DELETION OF ITS SIBLING ABOVE. That one only re-asserted moveSwim, which
  --  freshPather does bind, so it was dead the moment the construction changed.
  --  This one is not: a task-built pather reaching a flyer still arrives without
  --  moveFly, exactly as before.
  --
  --  BOTH SLOTS. Which one the engine dispatches to depends on whether the unit
  --  is submerged at that instant, and an amphibious chassis crosses that line
  --  mid-route. Binding only the one that "should" apply is how the first
  --  aquatic test ended up silently running vanilla's moveSwim.
  if self.pather.moveFly ~= petportsFreeMover then
    self.pather.moveFly = petportsFreeMover
    self.pather.moveSwim = petportsFreeMover
  end

  local result = self.pather:move(targetPosition, dt)

  reportPlanShape(self.pather.finder)
  sampleFlyCommand(dt)

  if result == "running" then
    self.petportsFlyPathEnd = nil

    --  THE STEER GATE IS CLEARED HERE, AND THE PLACE IS THE WHOLE FIX.
    --
    --  petportsSteerBlind holds the last outcome the fallback announced, so a
    --  per-tick line does not bury the log. It used to be cleared ONLY on the
    --  no-motion path below -- reached when `legal` is false -- and never in
    --  this branch. So the first blind steer of a unit's life latched the
    --  value and every later one was silent for as long as that unit lived.
    --
    --  MEASURED 2026-08-31: 72 "FLY path ended with false" and ZERO steering
    --  lines in one session, while the unit was demonstrably being driven at
    --  flySpeed with no plan. The session before it logged exactly three --
    --  one per re-home, because a respawn is the only thing that was resetting
    --  it. A silent fallback is how this went unattributed for two sessions.
    --
    --  A RUNNING PLAN IS THE EVENT THAT MAKES THE PREVIOUS OUTCOME STALE, which
    --  is why it belongs beside petportsFlyPathEnd rather than anywhere else.
    self.petportsSteerBlind = nil

    mcontroller.controlFace(self.pather.deltaX or toTarget[1])
    setMovementState(running)
  else
    --  PathFinder:update returns false when the path runs out, so this is both
    --  "no route" and "route finished short of the arrival radius". They are
    --  worth telling apart eventually; for now the distance in the line says
    --  which one it was.
    reportFlyPathEnd(result, targetPosition, targetDistance)

    --  A FAILED SEARCH IS NOT A REASON TO STOP MOVING. STEER DIRECTLY.
    --
    --  THIS IS VANILLA'S OWN ANSWER, copied from flyapproach.behavior, which
    --  wires its pathfinding action as
    --
    --      optional (shouldRun: usePathfinding)
    --        inverter
    --          moveToPosition { groundPosition: false, avoidLiquid: ... }
    --      ...
    --      flyInGeneralDirection { position: movePosition }
    --
    --  The optional-plus-inverter wrapper means TRY PATHFINDING, AND WHEN IT
    --  FAILS FALL THROUGH TO DIRECT STEERING. flyInGeneralDirection is a
    --  controlApproachVelocity straight at the target with a randomised wobble
    --  and NO terrain awareness at all.
    --
    --  That is why vanilla flying monsters climb out of water to attack: not
    --  because the search routes them out, but because when it cannot they stop
    --  asking it. Our units did the opposite -- setIdleState and sit there --
    --  which is how a pelagic unit came to alternate "pathfinding" and "false"
    --  for twenty seconds while a reachable target sat 49 tiles away.
    --
    --  WE CAN DO BETTER THAN THE WOBBLE. vanilla relies on randomness to get
    --  round obstacles because it has no collision test here; flyPathClear
    --  already sweeps the BODY along a line, so aim straight when the line is
    --  clear and only fall back to vanilla's blind approach when it is not.
    --
    --  BOUNDED BY EVERYTHING THAT ALREADY EXISTS. This only runs on a failed
    --  search, so it cannot interfere with a working plan; the progress
    --  watchdog still fails the task if steering gets nowhere; and the
    --  stranding ladder still re-homes a unit that cannot recover. It buys a
    --  chance to escape before those fire, which is exactly what it is for.
    local toTarget = world.distance(targetPosition, here)
    local length = math.sqrt(toTarget[1] * toTarget[1] + toTarget[2] * toTarget[2])

    if length > 0.0001 then
      local clear = flyPathClear(here, targetPosition)

      --  MEDIUM STILL APPLIES, ALONG THE WHOLE LINE AND NOT JUST AT ITS END.
      --
      --  Steering blind is a licence to ignore the PATHFINDER, not a licence to
      --  swim into lava or for a swimmer to leave the water. flyPathClear tests
      --  both geometry and medium, so a clear line is already a legal one; when
      --  it refuses, the fallback has to know WHICH of the two refused it.
      --  BLOCKED GEOMETRY IS STILL WORTH APPROACHING -- the unit slides along
      --  the obstacle and may get round it, which is the whole value of the
      --  fallback. AN ILLEGAL MEDIUM IS NOT, because a unit does not slide off
      --  water into air, it simply leaves.
      --
      --  MEASURED 2026-08-31, AND THIS IS THE FIRST HALF OF THE POOL CROSSING.
      --  The line read
      --
      --      local legal = clear or petports_mediumAllows(targetPosition)
      --
      --  which re-asked the medium question AT THE DESTINATION ONLY, so a line
      --  whose ends are both wet was approved however dry its middle was. An
      --  aquatic unit in one pool, dispatched to a drop in another across a
      --  drain-held air gap:
      --
      --      entering task drop:3305 at [2485.2,1145.92]   submerged, pool A
      --      A* fails -- path LOST, aStar false
      --      under way: 4.21808 tile(s), now at [2489.4,1146.32]
      --      PLAN accepted at [2490.4,1146.34] (medium air)
      --
      --  Four tiles of driven flight, at flySpeed, out of the water and into the
      --  gap, with no plan in existence. Everything after that -- including the
      --  plan the escape clause then licensed -- followed from this line.
      --
      --  ASYMMETRY IS NOT NEEDED HERE, AND THAT IS A DELIBERATE DIFFERENCE FROM
      --  THE OLD planMediumValid. A unit that is already out of its medium is
      --  not steered out of trouble by this fallback; it is sent home. See
      --  petports_outOfMedium and the port's mediumCheck.
      local legal = clear or flyMediumClear(here, targetPosition)

      --  THREE OUTCOMES, AND THE REFUSAL IS ONE OF THEM RATHER THAN SILENCE. A
      --  refused fallback issues no control, so the unit stops and the task dies
      --  on the progress watchdog. That is correct for a target this chassis
      --  cannot legally reach, and indistinguishable from a hang unless it says
      --  so.
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
        --  Normalised to flySpeed rather than passing the raw displacement, so
        --  a distant target does not command a speed the controller will simply
        --  clamp and a near one does not crawl.
        local speed = mcontroller.baseParameters().flySpeed

        mcontroller.controlFly({
          toTarget[1] / length * speed,
          toTarget[2] / length * speed
        })

        mcontroller.controlFace(toTarget[1])
        setMovementState(running)

        return false
      end
    end

    --  THE GATE IS NOT CLEARED HERE, AND THIS LINE IS WHERE 1871 IDENTICAL LOG
    --  LINES CAME FROM.
    --
    --  `self.petportsSteerBlind = nil` used to sit here, and it was correct while
    --  this was the SILENT path: it was reached only when `legal` was false, and
    --  nothing above had written the gate on that tick. Making the refusal a
    --  LOGGED outcome broke that -- the refusal sets the gate twenty lines up,
    --  falls straight past `if legal`, and lands here, which clears it again on
    --  the same tick. Set, cleared, set, cleared, once per tick, for as long as
    --  the unit faces a target it will not steer toward. Measured 2026-08-31:
    --  1871 lines in four minutes.
    --
    --  A RUNNING PLAN IS THE ONLY THING THAT MAKES THE PREVIOUS OUTCOME STALE,
    --  and that is where the reset now lives -- see the branch above.
    setIdleState()
  end

  return false
end
