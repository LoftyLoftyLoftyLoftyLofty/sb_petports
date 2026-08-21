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
local TASK_DEBUG = false

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

--  How many vent hops one task may make.
--
--  Bounded because the routing is GREEDY: the unit picks the vent whose far
--  side lands nearest the target and tries it, with no knowledge of whether
--  that far side connects to anything useful. Without a bound it could hop
--  forever.
local MAX_VENT_HOPS = 2

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

--  How close a unit must get to a vent mouth to use it.
--
--  GENEROUS ON PURPOSE. A vent embedded in a wall has no walkable alcove, so
--  the nearest place a unit can actually stand is often the floor several tiles
--  below. If this is tighter than that drop, the unit arrives at the only spot
--  it can reach and still refuses to use the vent.
local VENT_USE_DISTANCE = 4.0

--  Decide whether a vent can rescue this task, probing if the answer is not yet
--  known. Returns "routing" (a leg was started), "probing" (still finding out),
--  or "none" (no vent reaches the target).
--
--  Probing costs a full A* search per unknown exit, but only ONCE per
--  destination bucket -- terrain decides reachability, not the drop, so every
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
  if stateData.task.type == "return" then return "none" end
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
  --  whenever it drifts a bucket -- observed two consecutive tasks probing the
  --  identical five edges from buckets 74,44 and then 75,44, roughly forty
  --  seconds of work thrown away.
  --
  --  Slightly less accurate, since the unit is not always at its port. That is
  --  acceptable: the leash keeps it nearby, and a direct walk has already been
  --  tried and failed before routing is ever consulted.
  --
  --  After a hop the unit really is somewhere else, so planOrigin is cleared
  --  and the live position is used from there on.
  if stateData.planOrigin == nil then
    stateData.planOrigin = (stateData.ventHops == 0 and self.petportsHome)
      or mcontroller.position()
  end

  local plan = petports_planRoute(target, MAX_VENT_HOPS,
    stateData.task.port, EXPLORE_RATE, stateData.ventHops > 0,
    stateData.planOrigin)

  if plan == "probing" then
    stateData.probeTimer = (stateData.probeTimer or 0) + script.updateDt()
    if stateData.probeTimer < PROBE_LIMIT then return "probing" end

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

  if plan == nil then return "none" end

  stateData.plan = plan
  stateData.planIndex = 1
  stateData.probeTimer = 0
  sb.logInfo("UNIT planned %s-hop route to %s",
    sb.printJson(#plan), sb.printJson(target))

  --  Fall through on the next call, which takes leg 1.
  return "routing"
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
    ventHops = 0,
    triedVents = {},

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
end

function petportsTaskAction.enteringState(stateData)
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
local function report(stateData, outcome, reason)
  local task = stateData.task

  if task.port then
    world.sendEntityMessage(task.port, "petports_taskReport", {
      id = task.id,
      outcome = outcome,
      reason = reason,
      unit = entity.uniqueId()
    })
  end

  --  Clear locally regardless of whether the port heard us. A unit holding a
  --  task the port has forgotten would re-assert it every tick forever; the
  --  port re-dispatches if it still wants the work done.
  self.petportsTask = nil
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
local function standableNear(position)
  for _, offset in ipairs(COLUMN_SEARCH) do
    local x = math.floor(position[1] + offset) + 0.5

    local ok, resolved = pcall(findGroundPosition,
      {x, position[2]}, GROUND_SEARCH_DOWN, GROUND_SEARCH_UP, false)

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
local function approachTargetFor(stateData, rawPosition)
  if stateData.groundTarget ~= nil then return stateData.groundTarget end

  stateData.groundTarget = standableNear(rawPosition)
  return stateData.groundTarget
end

function petportsTaskAction.update(dt, stateData)
  local task = stateData.task

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

  --  Routing mode: probing exits, or waiting for one to be chosen. Runs every
  --  tick so a probe actually makes progress.
  if stateData.routing and stateData.viaVent == nil then
    local routing = tryVentRoute(stateData, target)

    if routing == "walk" then
      stateData.routing = false
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
    if stateData.viaVent == nil then return false end
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
    if world.magnitude(mcontroller.position(), stateData.viaVent.entry)
       <= VENT_USE_DISTANCE then
      local ok = pcall(world.callScriptedEntity,
        stateData.viaVent.id, "petports_ventTravel",
        entity.id(), stateData.viaVent.destinationId)

      sb.logInfo("UNIT entered vent %s to exit %s ok=%s",
        sb.printJson(stateData.viaVent.id),
        sb.printJson(stateData.viaVent.destinationId), tostring(ok))

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
      local ok = pcall(world.callScriptedEntity,
        stateData.viaVent.id, "petports_ventTravel",
        entity.id(), stateData.viaVent.destinationId)

      sb.logInfo("UNIT vent travel through %s to exit %s ok=%s",
        sb.printJson(stateData.viaVent.id),
        sb.printJson(stateData.viaVent.destinationId), tostring(ok))

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

    --  A* alive but no path yet. Reset whenever a path IS found, so a unit
    --  that legitimately re-plans mid-walk is not punished for it.
    local finder = self.pather and self.pather.finder
    if finder ~= nil and not finder.hasPath and finder.aStar ~= nil then
      stateData.searchingTimer = stateData.searchingTimer + dt

      if stateData.searchingTimer >= SEARCH_LIMIT then
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
    if stateData.approachTimer <= 0 then
      --  Ran out of walking time rather than failing to find a route. A vent
      --  may still shorten what is left, so try one before giving up -- vent
      --  routing used to fire only on SEARCH_LIMIT, which meant a unit that
      --  could technically path but not in time never considered a hop.
      --  Only hand over to routing ONCE. If routing already ran and found no
      --  vent, it cleared the flag and this is a genuine walking failure worth
      --  reporting properly.
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

    if self.pathing.stuck then
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

    if ok and taken then
      --  TESTING SINK: the descriptor is discarded, which destroys the item.
      --  Replace with deposit-into-port when the port UI grows storage.
      report(stateData, "done", "collected at " .. sb.printJson(task.position))
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
  petports_cancelProbe()

  --  Do not leave an abandoned search behind for follow/inspect to inherit.
  --  approachPoint rebuilds the pather from nil on its next call.
  self.pather = nil
  self.approachPosition = nil

  --  Interrupted rather than completed -- the state was pre-empted, or the unit
  --  is being recalled. Hand the task back so the claim is released rather than
  --  left to age out.
  if self.petportsTask ~= nil then
    report(stateData, "failed", "interrupted")
  end
end
