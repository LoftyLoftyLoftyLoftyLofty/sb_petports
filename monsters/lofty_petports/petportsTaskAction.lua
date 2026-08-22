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
--      { id = <workId>, type = <"diag" | "collect">,
--        port = <petport uniqueId>, position = {x, y},
--        target = <entity id, "collect" only>,
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
local function tryVentRoute(stateData, target)
  if petports_planRoute == nil then return "none" end

  --  RECALL DOES NOT VENT-ROUTE.
  --
  --  A walk home is not worth a route search: if the unit cannot walk back, the
  --  port re-homes it, which is instant and always works. Routing a recall cost
  --  38 seconds of probing before failing -- and worse, it filled the cache with
  --  t: keys for recall points chosen at random inside the rect, which will
  --  never be asked about again.
  if stateData.task.type == "return" then
    sb.logInfo("UNIT tryVentRoute: refusing to route a recall")
    return "none"
  end

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
    freshPather()
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
  if task.type == "collect" and not world.entityExists(task.target) then
    if task.port then
      world.sendEntityMessage(task.port, "petports_taskReport", {
        id = task.id,
        outcome = "failed",
        reason = "drop was gone before the unit could start",
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
    dwellTimer = task.dwell or 3.0,
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

local function freshPather()
  local options = petports_pathOptions()
  options.run = false

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
end

function petportsTaskAction.enteringState(stateData)
  sb.logInfo("UNIT entering task state for %s at %s",
    tostring(stateData.task.id), sb.printJson(mcontroller.position()))

  --  Before any approachPoint call, so vanilla picks up ours rather than
  --  building its own with the inverted box -- and fresh, so no abandoned A*
  --  search carries over from a previous task.
  freshPather()

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
  if task.type ~= "collect" then return task.position end

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

    sb.logInfo("UNIT pre-move at %s: action %s edge %s of %s srcDist %s velocity %s onGround %s",
      sb.printJson(mcontroller.position()),
      tostring(preEdge and preEdge.action),
      tostring(preFinder.currentEdgeIndex),
      tostring(preFinder.edges and #preFinder.edges),
      sb.printJson(preSource and world.magnitude(mcontroller.position(), preSource)),
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
  local arcFinder = self.pather and self.pather.finder

  if arcFinder ~= nil and arcFinder.hasPath and not mcontroller.onGround()
     and mcontroller.velocity()[2] < 0 then
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
      sb.logInfo("UNIT skipped %s unreachable arc waypoint(s) while falling from %s -- now on edge %s of %s",
        sb.printJson(skipped), sb.printJson(mcontroller.position()),
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
    end
  end

  if stalledEdge == nil then
    stateData.airborneEdgeStall = 0
  else
    stateData.airborneEdgeStall = (stateData.airborneEdgeStall or 0) + dt

    if stateData.airborneEdgeStall >= AIRBORNE_EDGE_STALL then
      local source = stalledEdge.source and stalledEdge.source.position

      sb.logInfo("UNIT stalled on %s edge %s of %s: grounded and motionless at %s, edge source %s srcDist %s -- replanning",
        tostring(stalledEdge.action),
        tostring(pathFinder.currentEdgeIndex),
        tostring(pathFinder.edges and #pathFinder.edges),
        sb.printJson(mcontroller.position()),
        sb.printJson(source),
        sb.printJson(source and world.magnitude(mcontroller.position(), source)))

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
    --  Despawned, or someone picked it up first. Not a failure worth alarm --
    --  drops expiring is the normal case this task was chosen to exercise.
    report(stateData, "failed", "drop is gone")
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
      --  Station-keeping never vent-routes (tryVentRoute refuses "return"
      --  tasks), so reaching here means only that the direct walk is hard.
      --  There is nowhere else for a tethered unit to be, so keep walking.
      sb.logInfo("UNIT station-keeping: no route offered, retrying the walk")
      stateData.routing = false
      stateData.searchingTimer = 0
      stateData.approachTimer = APPROACH_TIMEOUT
      freshPather()
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
        freshPather()
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
        freshPather()
        return false
      end

      if stateData.plan ~= nil then
        stateData.planIndex = stateData.planIndex + 1
        stateData.routing = stateData.planIndex <= #stateData.plan
      else
        stateData.routing = false
      end

      stateData.planOrigin = nil
      freshPather()
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
      freshPather()
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
      freshPather()

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
      freshPather()
    end

    return false
  end

  --  For collection, walk to standable ground near the drop rather than to the
  --  drop's own position.
  local approachTo = target
  if task.type == "collect" then
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
          "no standable position near drop at " .. sb.printJson(target)
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
            freshPather()
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
      if TASK_DEBUG and stateData.searchingTimer > 0 then
        sb.logInfo("UNIT path found after %s seconds of searching",
          sb.printJson(stateData.searchingTimer))
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
      freshPather()
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
      freshPather()
      return false
    end

    if self.pathing.stuck then
      sb.logInfo("UNIT pathing.stuck is set -- vanilla PathMover gave up")
      report(stateData, "failed", "stuck at " .. sb.printJson(mcontroller.position()))
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
    local home = world.magnitude(mcontroller.position(), task.position)

    --  Pushed off station -- shoved by a player, a door, an explosion. Walk
    --  back rather than holding a position the unit is no longer standing in.
    if home > (task.slack or 3.0) then
      sb.logInfo("UNIT pushed off station (%s from port), returning",
        sb.printJson(home))
      stateData.arrived = false
      stateData.approachTimer = APPROACH_TIMEOUT
      stateData.progressStrikes = 0
      freshPather()
      return false
    end

    if not stateData.onStation then
      stateData.onStation = true
      task.arrivedHome = true
      animator.setAnimationState("movement", "idle")
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
