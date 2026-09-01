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

--  PER-TICK FLIGHT TRACE. See flightTrace. OFF FOR RELEASE -- it is one line per
--  tick of every flight, which is the densest logging in this mod and is meant
--  to be switched on for a specific question and switched off again.
local FLIGHT_TRACE = false

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
local BUILD_STAMP = "2026-09-01l trace off, latch fixed"
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

--  HOW FAR TO LOOK FOR A NODE THE SEARCH CAN ACTUALLY BEGIN FROM.
--
--  Two tiles, and small on purpose. This corrects a unit that is standing a
--  fraction off its own node, not one that is somewhere wrong -- the measured
--  case needed 0.61 tiles. A candidate further out than this is not a nudge,
--  it is a journey, and a journey is the pathfinder's job.
local ORIGIN_NUDGE_RADIUS = 2

--  How close to the chosen node counts as arrived.
--
--  NOT "until the predicate flips", even though that is the condition we care
--  about. The node boundary sits at x.5, so the predicate flips the instant the
--  unit crosses it and leaves the body balanced ON the boundary, where a
--  fraction of drift breaks it again. Walking to the node CENTRE puts half a
--  tile of margin either side. Measured: the perch at x 2503.39 flips at
--  2503.5, which is 0.11 tiles of travel and no margin at all.
local ORIGIN_NUDGE_ARRIVE = 0.25

--  Give up and let the ordinary failure ladder have it.
--
--  Generous relative to the distance involved -- 1.5s is roughly twelve tiles
--  at walk speed and the nudge is never more than two. Anything approaching
--  this limit means the unit is not travelling, and continuing to push it is
--  how a recovery turns into a livelock.
local ORIGIN_NUDGE_TIMEOUT = 1.5

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

--  (superseded header, see PLAN_SURFACE_TOLERANCE above)
--  and the rest of its arc has been discarded.
--
--  The plan past an arc was computed for the position the arc was supposed to
--  end at. Land somewhere else and every edge after it is describing a walk the
--  unit is not standing at the start of. Vanilla cannot notice: moveLand's
--  acceptance test is
--
--      (onGround or ...) and math.abs(self.delta[1]) < 1
--
--  which is HORIZONTAL ONLY -- so a unit four tiles above its landing, with x
--  within a tile, advances straight off the end of the path. moveWalk is blind
--  the same way: it steers on edgeDelta[1] alone and will happily walk a plan
--  belonging to another surface.
--
--  HOW FAR OFF IN Y THE UNIT IS ALLOWED TO BE FROM THE SURFACE ITS PLAN WAS
--  COMPUTED FOR.
--
--  THIS WAS 1.0 AND 1.0 WAS WRONG. It was picked to match the tolerance
--  moveLand already applies to x, and that reasoning does not transfer: x is a
--  position along a surface and genuinely needs slack, y IS the surface. Feet
--  snap to tile tops, so a landing that went to plan reads EXACTLY 0 -- every
--  on-plan landing measured so far has.
--
--  So the number was never absorbing measurement error. It was absorbing whole
--  platforms, and on ONE-TILE platform spacing it absorbed exactly one:
--
--      ARC landed on-plan at [3758,1027.8]: next edge Land targets
--        [3758,1026.8], 1 tiles off in y (tolerance 1) -- keeping the plan
--
--  `1 > 1` is false, so a plan that was a full rung wrong was kept. The next
--  four lines are Walk edges targeting y 1026.8 executed by a unit standing at
--  1027.8, and it wedged at x 3756.7 with velocity [0,-1.537] for six tenths of
--  a second -- the top of a 1.6-tall box in the dirt, walking a corridor sized
--  for a body one tile lower.
--
--  0.5 is below the tightest platform spacing the game permits and far above
--  any float noise in a snapped landing, so it cannot swallow a surface and
--  cannot fire on a good one.
local PLAN_SURFACE_TOLERANCE = 0.5

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
--
--  CONTEXT-GLOBAL, NOT local, AND THE SWIM MOVER IS WHY. petportsFreeMover
--  lives in petports_flyapproach.lua and needs the same two numbers for the
--  same reason -- see the brake in that file. A local here would read as a nil
--  global there and the comparison would silently never fire, which is the trap
--  petports_objectPointNear was moved into this file to avoid. Both files load
--  into one monster context and the read happens at CALL time, so load order
--  does not matter. Costs nothing and returns two slots against MAXVARS.
JUMP_APPROACH_SLOWDOWN = 2.5
JUMP_APPROACH_SPEED = 3.0

--  HOW FAR A SWIMMER WILL CHASE ITS OWN JUMP POINT.
--
--  The walk-back recovery below is gated on onGround, which is never true for a
--  unit swimming at a waterline, so a swimmer that overshoots its jump source
--  has no recovery at all -- and, because an amphibious chassis is held up
--  ENTIRELY by the swim mover's thrust, a mover that issues nothing is a mover
--  that drops it. Measured 2026-09-01: handover at srcDist 0.557, the radius
--  test one tick later at 1.194, and the unit fell 21 tiles to the lakebed.
--
--  4.0 IS SIZED BY THE SINK, NOT BY TASTE. The first look after handover sees
--  about 1.2 tiles of gap; at terminal -22 and a script delta of 5 the unit can
--  drop 1.8 tiles between looks. Four tiles leaves at least one whole look of
--  margin after the first, and is still short enough that a unit further out
--  than this is not "just past its jump point" -- it is somewhere else, and
--  chasing a point it was never near is guessing.
--
--  BEYOND IT, LETTING THE UNIT SINK IS THE CORRECT ANSWER, which is worth
--  stating because it looks like the bug. The grounded-stall check in update()
--  is the ONLY thing that can replan a unit parked on a Jump edge, and it
--  requires onGround -- so holding station in open water would wait forever on
--  a detector that cannot fire. Sinking terminates in a floor, a stall and a
--  replan. It is slow and it is ugly and it converges.
local JUMP_SWIM_CHASE = 4.0

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

--  HOW FAR ABOVE THE LANDING THE ARC MUST TOP OUT.
--
--  An arc whose apex is exactly the landing height arrives with zero vertical
--  velocity, which is the marginal case: any rounding, any friction, and the
--  unit falls short of the ledge and hits its face instead. This buys enough
--  height that the unit is genuinely coming DOWN onto the surface.
--
--  0.5 MATCHES PLAN_SURFACE_TOLERANCE, deliberately. That is the distance at
--  which the rest of this file already decides a unit is on the wrong surface,
--  so aiming to arrive inside it means a landing this solver produces is one the
--  landing checks will accept.
local JUMP_ARC_CLEARANCE = 0.5

--  THE ENGINE'S PHYSICS TICK, AND THE REASON THE SOLVER HAS TO KNOW IT.
--
--  The movement controller integrates with EXPLICIT EULER -- it advances
--  position using the velocity from BEFORE gravity is applied that tick -- so a
--  real trajectory sits above the ideal parabola by
--
--      y_discrete - y_continuous = g * dt * t / 2
--
--  which at g 120 and dt 1/60 is exactly t tiles. Half a tile at half a second
--  of airtime, and it grows with every jump that hangs longer.
--
--  MEASURED, NOT ASSUMED. Fitted over every ballistic in-flight sample in one
--  session's log, using each tick's own vertical velocity as the clock, per
--  flight:
--
--      8 of 9 flights, slope 1.0000, sd 0.0024
--
--  The ninth was a ceiling contact, where vy is no longer a clock. dt = 1/60 to
--  a quarter of one percent.
--
--  THIS IS WHAT MADE THE FIRST ENDPOINT SOLVER MISS. It solved the continuous
--  parabola exactly and correctly, and the unit still arrived half a tile high
--  at its landing, clipped the ledge lip and fell back -- five identical laps.
--  The solve was right about the physics it modelled and the engine was running
--  different physics.
--
--  NOT AVAILABLE FROM ANY API, hence a constant. script.updateDt() is the SCRIPT
--  delta and is unrelated -- the controller integrates on the engine tick no
--  matter how often this script runs.
local PHYSICS_DT = 1 / 60

--  ARRIVAL IS A SIGN TEST, NOT A DISTANCE. -- REPLACES LAND_BRAKE_REACH 0.5
--
--  THE OLD TEST WAS `math.abs(here[1] - landing[1]) <= 0.5`, which asks "am I
--  near the landing's column" and NOT "have I got there". Those differ in
--  exactly the case that matters: a unit still travelling TOWARD the landing is
--  near it, and braking then removes the only velocity that could finish the
--  crossing.
--
--  MEASURED THREE TIMES, 2026-09-01, at two different sites:
--
--      here [2535.59,1150.56]  landing [2536,1149.8]   0.41 short, 0.76 high
--      here [2523.40,1160.80]  landing [2523,1160.8]   0.40 short, level
--      here [2523.40,1160.80]  landing [2523,1160.8]   0.40 short, level
--
--  All three braked, dropped vertically and landed on the lip of a step-up
--  instead of on it. The one firing in the same log that was CORRECT had the
--  unit at the landing exactly -- `here [2531,1152.8] landing [2531,1152.8]`.
--  Signed distance separates those four cases and absolute distance cannot.
--
--  WHY THE OLD SHAPE SURVIVED REVIEW. todo.pathing.brakefloor triaged this as a
--  note rather than a defect on the argument that a 1.6-wide body braked half a
--  tile short still overlaps the landing tile. True, and it named two things
--  that would break it -- a narrower chassis, a bigger reach. It missed a third:
--  OVERLAP ONLY SAVES A LANDING WHOSE NEIGHBOURING TILE IS AT THE SAME HEIGHT.
--  Onto a step up, short means falling down the side of it.
--
--  THE EPSILON EXISTS FOR THE EXACT-ARRIVAL CASE, which is a real reading and
--  not float noise -- the successful brake above had a signed distance of
--  precisely 0. Small enough that neither measured failure (0.40, 0.41) is
--  anywhere near it.
local LAND_BRAKE_ARRIVED = 0.05

--  AND HOW FAR PAST THE LANDING THE BRAKE IS STILL WORTH APPLYING.
--
--  A far-side bound is needed because the near-side one is gone. Sized to ONE
--  LOOK plus margin: at script delta 5 and speeds up to 12, the unit covers
--  about 1.0 tiles between looks, so a brake that refused anything past 1.0
--  could be stepped clean over by a fast arc -- the same one-sample problem the
--  jump takeoff radius has. Past this the arc has failed at something other than
--  its last tenth of a tile and stopping the unit dead is not the repair.
--
--  KEPT, AND KNOWN UNEXERCISED. 2026-09-01: 24 brake firings across 35 takeoffs,
--  every one of them at an `ahead` between 0 and 0.0017 -- not a single negative
--  reading, so this bound has never actually decided anything. It stays because
--  it is the only thing standing between a fast arc and no brake at all, and
--  because removing a guard on the grounds that it has not yet been needed is
--  how the near-side reach came to be trusted. It should not be quoted as
--  tested.
local LAND_BRAKE_OVERRUN = 1.5

--  BELOW THIS HORIZONTAL SPEED THE UNIT IS NOT GOING ANYWHERE, and the sign of
--  its velocity carries no information about which side of the landing it is
--  heading for. Reported velocity is a friction sampling artifact at rest -- the
--  logs are full of a resting unit reading [0,-1.5353] -- so this is a band
--  rather than a comparison against zero.
local LAND_BRAKE_STATIONARY = 0.1

--  And how far ABOVE the landing still counts, so a pass-over five tiles up on
--  the way to something else is not mistaken for an arrival.
local LAND_BRAKE_CEILING = 1.0

--  How high a launch of v0 actually gets, on the engine's integrator.
--
--  Apex is at t = v0/g, and substituting into the discrete trajectory gives
--  v0^2/(2g) + v0*dt/2 -- the continuous answer plus a term that is small but
--  is the whole difference between landing on a ledge and clipping its edge.
local function discreteRise(v0, gravity)
  return ((v0 * v0) / (2 * gravity)) + ((v0 * PHYSICS_DT) / 2)
end

--  The inverse: the launch that actually reaches a given height.
--
--  Solving v0^2/(2g) + v0*dt/2 = rise for v0, positive root.
local function discreteLaunchForRise(rise, gravity)
  local half = PHYSICS_DT / 2
  return gravity * (math.sqrt((half * half) + ((2 * rise) / gravity)) - half)
end

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

--  HOW CLOSE COUNTS AS ARRIVED AT A PATIENT. Wider than WATER_REACH because a
--  tile does not move and a patient does -- see todo.pathing.movingtarget, which
--  is unbuilt, so the approach position was resolved once and the patient has
--  been walking ever since. The dose is an AREA burst covering ten tiles, so
--  tolerance here is doing the work a re-resolve would otherwise have to.
--
--  MUST NOT EXCEED THE BURST'S HALF-WIDTH. petports_medicburst uses a +/-40px
--  poly, five tiles from centre, so a unit that "arrived" further than that
--  spends a medical good on a burst that does not reach.
local MEDIC_REACH = 5.0

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

--  WHERE THE PLANNED ARC IS MEANT TO PUT THE UNIT DOWN.
--
--  Walks forward from the Jump edge through its Arc edges and returns the first
--  NON-Arc edge's target -- the Land the whole arc exists to reach. Same walk
--  plannedApex does, kept separate because the apex and the landing are
--  different questions and the pathological case is precisely when they are the
--  same point.
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

--  FLY THE PLAN'S ENDPOINT, NOT THE PLAN'S STATED VELOCITY.
--
--  SUPERSEDES a raise-only correction that could not fix the failure that
--  actually loops. That version compared the planned apex against what the
--  planned launch physically delivers, raised the launch when the plan wanted
--  MORE rise than the jump gives, and deliberately never lowered it -- on the
--  reasoning that launching weaker than planned is what caused ceiling
--  collisions.
--
--  MEASURED, ONE SESSION, PERFECT CORRELATION: every unexecutable takeoff in the
--  log -- 14 of them -- was the opposite case. A Jump edge carrying [12,45]
--  whose own arc waypoints top out at the landing height, 3 tiles up. A 45
--  launch crosses that height at t=0.074s STILL RISING AT vy 36, carries on to
--  8.44 tiles, and comes down 3.66 tiles past the target and 3 tiles below it.
--  The unit then walks back to the same tile and does it again: ten identical
--  replans, srcDist 4.72912 every time.
--
--  THE PLANNER PUT A LAND ON THE ASCENDING CROSSING. Its arc is not wrong about
--  physics -- it is a correct 45 trajectory -- it just stops where that
--  trajectory first passes the target height and calls that a landing. The
--  launch velocity is the part of the edge that cannot be honoured; the TARGET
--  is right, and is what this solves for.
--
--  TWO BRANCHES, AND THE FIRST IS PREFERRED.
--
--  KEEP THE PLANNER'S vx. It comes from {0, +-walkSpeed, +-runSpeed} and is the
--  horizontal reach the plan was counting on, so the arrival time is fixed and
--  only vy is free. Solving it is one line, and it is the branch that a normal
--  working jump takes -- a flat hop keeps its 12 and simply stops launching at
--  full height.
--
--  LOWER vx when no vy can arrive descending at that speed. For a target 1 tile
--  right and 3 up, vx 12 crosses the target's column in 0.083s, far too soon to
--  have risen and fallen; the geometry is impossible, not merely badly tuned.
--  Then the apex is pinned just above the landing and vx falls out of the
--  airtime.
--
--  ARRIVING DESCENDING IS THE WHOLE INVARIANT. Both branches guarantee it, and
--  it is what makes a Land edge mean what it says.
--
--  NEVER MORE HORIZONTAL REACH THAN PLANNED, and a raise in vy is still capped
--  at JUMP_VELOCITY_CAP, so this cannot turn a planned hop into a launch across
--  the room.
--
--  THE CEILING WORRY IS BOUNDED. This exceeds the plan's own apex by at most
--  JUMP_ARC_CLEARANCE, and only in the pathological case -- where the plan's
--  apex was the landing itself and the real trajectory was going five tiles
--  higher anyway. Every other case comes out at or below what the plan drew.
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

  --  ---- branch 1: keep the planner's horizontal velocity -------------------
  --
  --  Guarded on the sign matching as well as on being non-zero: a plan whose vx
  --  points away from its own landing is malformed, and dividing by it would
  --  produce a negative time.
  if plannedVx ~= 0 and dx ~= 0 and ((dx > 0) == (plannedVx > 0)) then
    local t = math.abs(dx) / math.abs(plannedVx)

    --  DESCENDING AT THE TARGET, on the DISCRETE trajectory: the continuous
    --  form of this test is dy < g*t^2/2, and the integrator's extra lift makes
    --  the real bound g*t*(t + dt)/2.
    if dy < 0.5 * gravity * t * (t + PHYSICS_DT) then
      --  Solving  v0*t - g*t*(t - dt)/2 = dy  for v0. The continuous version of
      --  this line read `+ 0.5 * gravity * t` and launched the unit t tiles too
      --  high at the landing -- half a tile on a half-second hop, which is
      --  exactly enough to clear a ledge instead of landing on it.
      local candidate = (dy / t) + (0.5 * gravity * (t - PHYSICS_DT))

      --  And the apex it implies must still clear the landing, or the arrival
      --  is descending by a hair and lands on the lip.
      if discreteRise(candidate, gravity) >= dy + JUMP_ARC_CLEARANCE then
        vx, vy, time, branch = plannedVx, candidate, t, "kept vx"
      end
    end
  end

  --  ---- branch 2: pin the apex, solve for vx -------------------------------
  if branch == nil then
    local rise = math.max(planRise, dy + JUMP_ARC_CLEARANCE)
    if rise <= 0 then return plannedVx, plannedVy, nil end

    vy = discreteLaunchForRise(rise, gravity) * JUMP_VELOCITY_MARGIN

    --  Descending root of  v0*t - g*t*(t - dt)/2 = dy, which rearranges to
    --  g/2 * t^2 - (v0 + g*dt/2) * t + dy = 0.
    local b = vy + ((gravity * PHYSICS_DT) / 2)
    local disc = (b * b) - (2 * gravity * dy)
    if disc < 0 then return plannedVx, plannedVy, nil end

    time = (b + math.sqrt(disc)) / gravity
    if time <= 0 then return plannedVx, plannedVy, nil end

    vx = dx / time
    branch = "lowered vx"
  end

  --  Never out-reach the planner horizontally, and keep the old cap on a raise.
  if plannedVx ~= 0 and math.abs(vx) > math.abs(plannedVx) then
    vx = math.abs(plannedVx) * (vx > 0 and 1 or -1)
  end
  if plannedVy > 0 then
    vy = math.min(vy, plannedVy * JUMP_VELOCITY_CAP)
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

--  HOW FAR THE UNIT'S FEET MAY BE FROM THE PLATFORM IT IS DROPPING THROUGH.
--
--  A drop placement is only safe while the unit is resting on the surface it
--  passes, because nothing sweeps the space between origin and destination.
--  Feet on a platform read EXACTLY its surface, so this only has to be big
--  enough for float noise and small enough that it cannot span a platform --
--  which on the tightest legal spacing means well under 1.0.
local DROP_ORIGIN_TOLERANCE = 0.35

--  HOW FAR BELOW THE PASSED SURFACE A PLACEMENT MAY SETTLE.
--
--  DROP_SCOOT is the nudge; this is the floor of the search when the nudge pose
--  does not fit under a low ceiling. Exactly 1.0, and that number is doing real
--  work: platform surfaces are integers, so one tile reaches the next standing
--  height and cannot reach the one past it. Raise this and a placement starts
--  crossing platforms unchecked, which is the teleport all over again.
local DROP_SETTLE_MAX = 1.0

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

  --  YOU MAY ONLY SCOOT THROUGH THE SURFACE YOU ARE STANDING ON.
  --
  --  This placement bypasses the collision sweep between origin and
  --  destination -- bodyFitsWithFeetAt checks where the unit lands, never the
  --  path it takes to get there. That is safe at DROP_SCOOT, 0.25 tiles, only
  --  because of an invariant nothing was checking: the unit is resting on the
  --  platform it is about to pass, so origin and destination are a quarter tile
  --  apart and there is nothing in between.
  --
  --  DROP_SCOOT never changed. THE ORIGIN DRIFTED. A unit executing a plan
  --  three tiles above the surface that plan was drawn on reaches the Drop edge
  --  with a descent measured from where it actually is, and the lowest platform
  --  above the edge's floor is then nowhere near its feet. MEASURED, on four
  --  platforms stacked a tile apart:
  --
  --      pre-move at [3751.8,1029.8]: action Drop edge 24 of 68
  --        src [3752,1026.8] dst [3752,1025.8] dstDist 4.00499
  --      UNIT drop SCOOTED 1029.8 -> 1026.55 (through surface 1026)
  --        for a 4 tile descent
  --
  --  A 3.25-tile placement straight through three solid-from-above platform
  --  surfaces, into a tunnel the unit had no route into. It reads in game as
  --  the unit falling through the floor, and it is the only line in the log
  --  that says so.
  --
  --  The invariant is now asserted rather than assumed. Refusing here falls
  --  back to controlDown, which is physics and cannot pass through anything it
  --  should not -- and the refusal is logged, so a drop attempted from the
  --  wrong storey names itself instead of teleporting.
  local feetNow = position[2] + mcontroller.boundBox()[2]
  local standingGap = math.abs(feetNow - surface)

  if standingGap > DROP_ORIGIN_TOLERANCE then
    return false, string.format(
      "feet at %s are %s from the surface %s we would pass -- not standing on it, "
      .. "a placement here would cross %s tiles of geometry unchecked",
      sb.printJson(feetNow), sb.printJson(standingGap),
      sb.printJson(surface), sb.printJson(standingGap))
  end

  --  SETTLE DOWNWARD WHEN THE NUDGE POSE DOES NOT FIT.
  --
  --  DROP_SCOOT is a nudge: put the feet a hair under the platform and let
  --  gravity finish. That assumes headroom below, and a two-high tunnel does
  --  not have any. MEASURED:
  --
  --      PLAN DROP refused at [3752.29,1024.8]: Walk edge 28 targets
  --        [3753,1023.8], 1.00006 below us: solid tiles at feet 1023.75
  --
  --  Feet at 1023.75 puts a 1.6-tall body from 1023.75 to 1025.35, and the
  --  top tile is the tunnel ceiling. Feet at 1023.0 -- where the unit actually
  --  comes to rest, and where the plan's own edge sits -- spans 1023.0 to
  --  1024.6 and fits the tunnel exactly. The pose being rejected was one the
  --  unit passes through, not one it stops in.
  --
  --  So when the nudge does not fit, step the feet down and take the first
  --  height that does. CAPPED AT ONE TILE BELOW THE SURFACE, which is the
  --  whole safety argument: platform surfaces land on integers, so a full tile
  --  reaches the next standing height and cannot reach the one after it. This
  --  still passes exactly one platform, and the origin assertion above still
  --  requires the unit to be standing on it.
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
    --
    --  THAT REASONING IS ABOUT AIR, AND LIQUID IS A THIRD STATE IT DOES NOT
    --  COVER -- see the swim arm below. Kept as written for the air case, which
    --  it is still right about.
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

    --  THE SAME RECOVERY, FOR A UNIT THAT IS IN WATER RATHER THAN ON A FLOOR.
    --
    --  A swimmer at a waterline is never onGround, so every line above is
    --  unreachable for it and this function did nothing at all -- which for a
    --  chassis with no buoyancy is not "nothing", it is a 21-tile fall. The
    --  surface hold on an amphibious unit is produced ENTIRELY by
    --  petportsFreeMover's controlApproachVelocity, once per tick, so the first
    --  tick on a Jump edge is the first tick with no thrust and the unit starts
    --  down. See JUMP_SWIM_CHASE for the measurement.
    --
    --  GRAVITY-ENABLED ONLY. A free mover does not sink when nothing pushes it
    --  and does not get handed Jump edges in the first place; leaving it out
    --  keeps this arm to the chassis that demonstrated the fault.
    --
    --  ANY WATER IN THE BODY, NOT FULL SUBMERSION. petports_mediumAt answers
    --  "mixed" for a body straddling a waterline, and that is exactly where
    --  this failed -- a 1.6-tall body centred at 1149.81 spans a wet row and a
    --  dry one. Asking only for "swim" would miss the measured case entirely.
    --
    --  NO JUMP_LEVEL_TOLERANCE HERE, DELIBERATELY. That rule exists because
    --  walking cannot change what floor you are on, so a source four tiles down
    --  is evidence of a bad plan rather than something to approach. Swimming
    --  changes both axes, so a source above or below is simply somewhere to
    --  swim to, and the bound that matters is DISTANCE.
    --
    --  NO controlDown, unlike the free mover's descent case. That hold exists
    --  because A* routes down through platforms; this is not following a plan
    --  edge, it is a correction back to a point the unit was at a tick ago, and
    --  no platform can have appeared underneath it in between.
    elseif mcontroller.baseParameters().gravityEnabled
           and gap <= JUMP_SWIM_CHASE then
      local medium = petports_mediumAt(mcontroller.position())

      if medium == "swim" or medium == "mixed" then
        local delta = world.distance(source, mcontroller.position())
        local length = math.sqrt(delta[1] * delta[1] + delta[2] * delta[2])

        if length > 0.0001 then
          --  THE SAME ACTUATION THE SWIM MOVER USES, INCLUDING THE FORCE. Two
          --  functions pushing one body through water with different forces
          --  would make the approach depend on which one happened to be
          --  driving, and the handover between them is the whole bug.
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

  --  Everything from here down is vanilla's takeoff, unmodified.
  if not pather.jumpTimer then
    pather.jumpTimer = 0.2
    mcontroller.setPosition(source)
    mcontroller.setVelocity({0, 0})

    sb.logInfo("UNIT takeoff from %s, jumpVel %s (approached to %s)",
      sb.printJson(source), sb.printJson(edge.jumpVelocity), sb.printJson(gap))

    --  WHAT THE PLANNER ACTUALLY DREW, dumped once per takeoff.
    --
    --  This exists to settle one open question: the planner emits a Jump edge
    --  carrying a jumpVelocity, and then draws an arc that does not match it.
    --  Measured on a four-tile rung climb -- jumpVelocity [8,45], which at
    --  g 120 is 8.4375 tiles of rise, against an arc that turned over 5.85
    --  tiles up. The unit flew the 8.4375 and sailed clean over the rung it was
    --  aiming for. smallJumpMultiplier was 1.0 when this was measured, so the
    --  catalogued explanation did not cover it. It is 0.70711 now -- see the
    --  entry beside it in petports_contract.lua -- which means this measurement
    --  should be RE-TAKEN before it is reasoned from: with only one jump height
    --  available, every plan was a maximum-height launch, and that alone
    --  accounts for part of what is described here.
    --
    --  The per-edge VELOCITIES are the discriminator and are the reason this
    --  dump exists rather than a apex number. If the first arc edge's source
    --  velocity reads [8,45], the planner is drawing a trajectory that
    --  contradicts its own launch and the disagreement is in the arc sampling.
    --  If it reads something smaller, the planner is deliberately planning a
    --  partial jump the actor cannot perform, and the Jump edge's jumpVelocity
    --  is a ceiling rather than an instruction.
    --
    --  Delete this block once that is answered.
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

    --  THE ONE NUMBER THAT MATTERS, stated rather than left to subtraction.
    --
    --  A planner apex BELOW the physics apex means the plan's Land sits on the
    --  ASCENDING crossing: the trajectory it drew is a correct one for the
    --  velocity it specifies, it just stops the first time that trajectory
    --  passes the target height, while the unit is still going up hard.
    --
    --  THIS USED TO BE FATAL AND IS NOW DIAGNOSTIC. The note here said the case
    --  was "not correctable at all: the actor cannot jump softer". The actor
    --  cannot, but petportsJumpMover does not ask it to -- it sets velocity
    --  outright, and solveLaunch now flies the plan's LANDING rather than the
    --  plan's stated velocity, which lowers the launch until the arrival is on
    --  the way down. So this line no longer predicts a failure; it names the
    --  plans that are being corrected, and the `launch lowered vx` line that
    --  follows says what they were corrected to.
    --
    --  KEPT, AND WORTH KEEPING, because the frequency is the signal. This firing
    --  constantly means A* is routinely emitting ascending Lands, which is worth
    --  knowing even when every one of them is handled.
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
      --  ALWAYS LOGGED, one line per takeoff. This is the only place the
      --  difference between what the plan SAID and what the unit is about to do
      --  appears, and a jump that still misses cannot be diagnosed without it.
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

    --  THE LAUNCHED vx, NOT THE PLANNED ONE. deltaX is what the movers read for
    --  direction and magnitude after takeoff, and leaving it at a value the unit
    --  is not travelling at is the same class of disagreement this function
    --  exists to remove.
    pather.deltaX = vx

    --  AND THE ARC MOVER HAS TO BE TOLD, OR IT UNDOES THIS ON THE FIRST
    --  AIRBORNE TICK.
    --
    --  petportsArcMover drives horizontal velocity toward the ARC EDGE'S OWN
    --  source.velocity every tick it is in flight -- which is the planner's
    --  velocity, the one this function just decided is unflyable. A launch of
    --  2.86 would be pushed straight back to 12 and the unit would sail past
    --  its landing exactly as before, with the launch line in the log claiming
    --  it had been corrected.
    --
    --  plannedVx IS CARRIED FOR DIAGNOSIS ONLY, NOT AS A GATE. It used to be
    --  the test for whether an arc edge belonged to this jump, and that was
    --  wrong in the one case that matters -- see the airborne branch of
    --  petportsArcMover, and fact.pathing.plannervxdrop. The arc's ownership is
    --  now a state invariant maintained per tick: the record exists only while
    --  the pather is on an Arc edge.
    --
    --  jumpIndex IS THE EDGE THE JUMP WAS TAKEN FROM. The arcs belonging to this
    --  jump are the contiguous run after it, so an index at or below it in a
    --  substitution is a record that should already have been cleared, and is
    --  logged as such rather than silently applied.
    pather.petportsLaunch = {
      vx = vx,
      plannedVx = edge.jumpVelocity[1],
      jumpIndex = pather.finder and pather.finder.currentEdgeIndex
    }

    --  A NEW JUMP IS NOT A LANDING. Cleared here as well as when an arc ends,
    --  because an arc that terminates some other way -- the skip logic reaching
    --  a Land, a replan mid-flight -- would otherwise leave this set and brake
    --  the next takeoff to a standstill in the air.
    pather.petportsLanding = nil

    pather.jumpTimer = nil
    pather:advancePath()
  else
    pather.jumpTimer = pather.jumpTimer - script.updateDt()
  end

  return "running"
end

--  REPLACEMENT moveArc.
--
--  Vanilla's grounded branch is a RUN-UP, and it has three problems that only
--  show up together. From /scripts/pathing.lua:
--
--      if mcontroller.onGround() and not mcontroller.liquidMovement() then
--        local nextEdge = self.finder:lookAhead(1) or {}
--        if nextEdge.action and nextEdge.action ~= "Arc" then
--          self.arcDelta = nil
--          self:advancePath()
--        else
--          self.arcDelta = self.arcDelta or self.delta[1]
--          moveX(self.arcDelta, run)
--          self.deltaX = self.arcDelta
--        end
--        return "running"
--
--  ONE: `self.arcDelta = self.arcDelta or self.delta[1]` LATCHES. It is taken
--  once, on the first grounded tick, and never recomputed. So it is a direction
--  held forever rather than an approach.
--
--  TWO: `run` IS AN UNDECLARED GLOBAL. moveWalk declares `local run = self.run`
--  at the top; moveArc never does, so this is a nil global reaching
--  mcontroller.controlMove(direction, run), where the run flag DEFAULTS TO
--  TRUE. The run-up therefore happens at runSpeed, not walkSpeed. Same shape as
--  the `holdTime` typo in timedDrop -- an undeclared global standing in for a
--  parameter, silently.
--
--  THREE: there is no terminating condition. Nothing checks arrival, nothing
--  re-reads the delta, and passedTarget cannot advance a vertical arc edge --
--  edgeDistance[1] is 0, which its own `~= 0` guard rejects, and the unit is
--  ABOVE a target it is meant to fall to, so axis 2 never changes sign either.
--
--  MEASURED, on a four-tile platform stack, from the pre-move dx field:
--
--      [3768.2,1026.8]   dx -0.04   velocity   0      grounded, arcDelta latched
--      [3767.82,1026.8]  dx +0.34   velocity  -7.59
--      [3766.88,1026.8]  dx +1.28   velocity -11.8    runSpeed, wrong direction
--      [3765.88,1026.8]  dx +2.28   velocity -11.8
--      [3763.88,1026.78] dx +4.28   velocity -11.8
--      [3762.88,1026.21] dx +5.28   velocity -12      off the end of the rung
--
--  dx is the distance to the edge target. It crosses zero on the second tick
--  and the unit keeps accelerating away from it, because the latched value is
--  the only thing steering. Six tiles later it left the platform and fell
--  sixteen.
--
--  AND IT DEFEATED EVERY GUARD, because all of them read motion as health --
--  vanilla's stuckTimer, our airborneEdgeStall, and the stuckAnchor reset that
--  zeroes both. That is the failure petportsJumpMover's header already warned
--  about from the other direction: a recovery that produces motion is worse
--  than no recovery.
--
--  THE RUN-UP IS DELETED RATHER THAN REPAIRED, because the state it fires in is
--  never a state a run-up helps. canPathfind() requires onGround, so a path is
--  always planned from the ground and a jump sequence always opens with a Jump
--  edge -- moveJump owns the approach to the takeoff point and only advances
--  once the launch velocity is set. Grounded on an Arc therefore means one of
--  exactly two things:
--
--    the tick immediately after takeoff, still touching the floor while rising
--    -- one tick, velocity[2] well positive, and the launch is already applied
--    so there is nothing for a run-up to contribute
--
--    the arc is over and the unit landed somewhere the plan did not predict
--
--  Neither wants horizontal control. Issuing none leaves the unit standing
--  still, which is the honest signal: the skip in update() consumes the dead
--  arc on the same tick, and if it somehow does not, the grounded-stall check
--  replans within AIRBORNE_EDGE_STALL. Standing still is also exactly what
--  petportsJumpMover's wrong-level branch settled on, for the same reason.
--
--  Everything else here is vanilla's, unmodified.
function petportsArcMover(pather)
  pather.jumped = false
  pather.jumpCooldown = 0.3

  --  Vanilla's advance loop, unchanged.
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

    --  NOTHING BRAKES HERE, AND A TOUCHDOWN STOP WAS TRIED AND REMOVED.
    --
    --  2026-09-01: a hard `setVelocity({0, vel[2]})` was added at the top of
    --  this branch as a backstop for the airborne brake, on the reasoning that
    --  touchdown is the one arrival that cannot be predicted wrong. It fired
    --  ZERO times in a session with 35 takeoffs and 40 landings, and so did
    --  every other line in this branch:
    --
    --      ARCMOVER grounded on an arc     0
    --      ARCMOVER grounded at            0
    --      ARCMOVER airborne again         0
    --      hit MAX_ARC_SKIP                0
    --
    --  THE ARC SKIP IN update() GETS HERE FIRST, EVERY TIME. It runs before the
    --  mover, its GROUNDED mode is the same predicate a touchdown stop would
    --  use -- `onGround() and vel[2] <= 0` -- and it consumes every remaining
    --  Arc edge before stopping on the Land. By the time this mover runs, the
    --  cursor is on a non-Arc and the guard above has already returned.
    --
    --  SO THIS BRANCH IS A FALLBACK, NOT THE LANDING PATH. It is still reachable
    --  in principle -- MAX_ARC_SKIP, or a tick where the arc block in update()
    --  does not run -- and is kept for that. What it must not do is carry a
    --  guarantee, because a guarantee on a path that never executes reads as
    --  cover and is not. If a slide-off is ever measured, the place to stop it
    --  is the GROUNDED branch of that skip, at the moment it decides the arc is
    --  over.
    --
    --  Vanilla's escape, kept as-is: on the LAST arc edge, hand over to
    --  whatever follows. Worth knowing this is why the bug needs two or more
    --  arc edges left at touchdown -- land holding the last one and vanilla
    --  gets out of its own way.
    if nextEdge.action and nextEdge.action ~= "Arc" then
      sb.logInfo("UNIT ARCMOVER grounded at %s holding the last arc edge, next is %s -- advancing",
        sb.printJson(here), tostring(nextEdge.action))

      pather.arcDelta = nil

      --  THE ARC IS OVER, so the launch record it belonged to must not survive
      --  into the next one. The record is DIAGNOSTIC ONLY since nothing steers
      --  x any more -- see the airborne branch -- but its lifetime is still what
      --  makes the "launch record cleared" line report the right flight, and
      --  petportsLanding beside it is load-bearing.
      pather.petportsLaunch = nil
      pather.petportsLanding = nil

      pather:advancePath()
      return "running"
    end

    --  Change-gated so a unit parked here does not fill the log, but it
    --  fires again the moment the situation changes.
    --
    --  RISING IS THE ORDINARY CASE AND IS EXPECTED ONCE PER JUMP. There is
    --  one tick after takeoff where the launch velocity is applied and
    --  onGround has not gone false yet -- measured at [3768,1010.8] with
    --  velocity [0,48.314]. It is called out separately so a normal jump
    --  does not read as a fault in the log.
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

  --  ARRIVED: STOP, DO NOT KEEP FLYING.
  --
  --  MEASURED, AND IT IS THE WHOLE OF THE REMAINING LOOP. With the launch solved
  --  on the engine's own integrator the unit now reaches its landing exactly --
  --
  --      ARC tick: edge 40 of 43 at [2493,1155.8] vel [8,-25]
  --
  --  which is the Land target to the decimal, descending. And then it slides
  --  straight off the ledge and falls three tiles back to where it started. Five
  --  identical laps.
  --
  --  BECAUSE THIS MOVER IS STILL FLYING IT. The Land is edge 42 and the unit is
  --  on edge 41, an Arc -- so moveLand, whose whole body is vanilla's
  --  controlApproachXVelocity(0, groundForce), never gets a tick. What runs
  --  instead is the code below, which drives x toward the FLIGHT velocity and
  --  sets groundFriction to 0. The unit touches down at 8 tiles per second on a
  --  frictionless surface with the throttle open and is gone in five ticks.
  --  `ARCMOVER grounded` appears zero times in the entire log.
  --
  --  ZEROED OUTRIGHT RATHER THAN BRAKED, on the first tick that sees the
  --  arrival. groundForce is not declared on any chassis, so its value is an
  --  engine default this code cannot verify -- and at script delta 5 the brake
  --  gets ONE look before the unit is two thirds of a tile past. A brake that
  --  might be too weak is the failure being fixed, so it is not the mechanism to
  --  fix it with. Approaching 0 afterwards keeps it there.
  --
  --  THE PLAN AGREES: the Land edge is a zero-length marker whose dst velocity
  --  is null. Stopping is what a Land MEANS.
  --  THE TRIGGER IS "HAVE I ARRIVED", NOT "AM I NEAR". See LAND_BRAKE_ARRIVED.
  --
  --  `ahead` is the distance to the landing MEASURED ALONG THE DIRECTION OF
  --  TRAVEL: positive while the landing is still in front, zero at it, negative
  --  once past.
  --
  --  A UNIT WITH NO HORIZONTAL VELOCITY IS TREATED AS ARRIVED, and that is a
  --  branch rather than a consequence of the sign expression. Signing by
  --  `vel[1] >= 0` would call a landing to the RIGHT of a motionless unit "still
  --  ahead" and refuse to brake forever, on the strength of a velocity that is
  --  not going to close anything. There is nothing left to protect when nothing
  --  is moving, so the brake may fire -- and it is a no-op on a vx already at
  --  zero, which is why this reads as pedantry until the latch is considered.
  --
  --  THIS IS WHERE THE BRAKE WAS ORIGINALLY EARNED, AND THAT CASE STILL FIRES.
  --  The five-lap slide-off was a unit at `[2493,1155.8]` with the Land target
  --  at exactly that point -- `ahead` 0, inside the epsilon, braked. What no
  --  longer fires is the brake on a unit that has not got there yet.
  local landing = plannedLanding(pather)
  local ahead = nil

  if landing ~= nil then
    if math.abs(vel[1]) < LAND_BRAKE_STATIONARY then
      ahead = 0
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

  if pather.petportsLanding then
    --  AHEAD OF THE FRICTION ASSIGNMENTS BELOW, WHICH IS THE POINT. Those run
    --  every airborne tick and are what make the surface slippery. Returning
    --  from here leaves groundFriction at the chassis value, so the unit has
    --  something to stop against as well as nothing pushing it.
    mcontroller.controlApproachXVelocity(0, mcontroller.baseParameters().groundForce)
    return "running"
  end

  pather.petportsArcGrounded = nil
  pather.arcDelta = nil

  --  Airborne: vanilla's branch, unmodified.
  pather.controlParameters.airFriction = 0
  pather.controlParameters.liquidFriction = 0
  pather.controlParameters.liquidImpedance = 0
  pather.controlParameters.groundFriction = 0

  local velocity = pather.edge.source.velocity or pather.edge.target.velocity or {0, 0}

  --  NOTHING STEERS X DURING A FLIGHT. THE FRICTION ZEROING ABOVE IS THE WHOLE
  --  MECHANISM.
  --
  --  This branch used to end in
  --
  --      mcontroller.controlApproachXVelocity(wantVx, groundForce)
  --
  --  where wantVx was `launch.vx` on a real jump and `velocity[1]` -- THE
  --  PLANNER'S PER-EDGE VELOCITY -- on anything else. Both halves are gone.
  --
  --  THE PLANNER'S VELOCITIES DESCRIBE A TRAJECTORY THE UNIT IS NOT FLYING, and
  --  A* CHANGES ITS OWN vx PARTWAY THROUGH AN ARC. See fact.pathing.plannervxdrop.
  --  Measured on the platform course:
  --
  --      edge 62 Arc  vel [12,7.06]  -> dst [2516.71,1180.75] vel [1,0]
  --      edge 64 Arc  vel [1,0]      -> dst [2516.93,1180.25] vel [1,-26.5]
  --
  --      25.607  [2514.65,1180.89]  vel [7.95553, 6.256]   edge 62
  --      25.690  [2514.92,1181.07]  vel [1, -3.744]        edge 64
  --
  --  One look, and the unit was braked from the launched 7.96 to the planner's 1
  --  at the apex, with a quarter second of descent still to run. It crossed its
  --  landing altitude 1.83 tiles short and fell twelve tiles.
  --
  --  A LAUNCH RECORD ONLY EVER PATCHED HALF OF THAT. It covered jumps, because a
  --  jump has a takeoff to record. A WALK-OFF FALL HAS NO TAKEOFF, so it fell
  --  through to the planner's numbers -- and A* models a walk-off as a short
  --  forward hop followed by a VERTICAL DROP, whose stored vx is zero. Measured
  --  2026-09-01 at the ledge above [2536,1149.8], six times, identical:
  --
  --      45.170  [2534.65,1152.16]   vx  8.05
  --      45.252  [2534.91,1150.99]   vx  2.99
  --      45.337  [2534.91,1149.10]   vx  0.00   -- braked to a standstill in air
  --      45.414  [2534.91,1148.80]   grounded, one tile low and 1.09 short
  --
  --  The unit then sat on an unreachable Land edge until the stall watchdog
  --  replanned. No wall was involved: an earlier flight occupied x 2535.59 at
  --  that height. The mover was obeying an instruction sampled at a point the
  --  unit never occupied -- the skip logic had already advanced the cursor to an
  --  edge whose source is [2535.33,1151.12], 0.4 tiles further east.
  --
  --  THE CONTROL THAT SETTLED IT, AND IT PREDATES THIS CHANGE: on one attempt the
  --  task failed mid-flight and the pather was discarded at the apex. With
  --  NOTHING CALLING THIS MOVER, the unit kept its launched vx, flew pure
  --  ballistics and touched down at [2517.22,1177.8] -- its planned landing, 0.22
  --  over. Guided it missed by 1.83 tiles; unguided it hit. That is this change,
  --  observed a session before it was written.
  --
  --  SO THE SUBSTITUTION WAS NEVER THE FIX -- IT WAS A NARROWER BUG. Holding
  --  launch.vx and issuing nothing produce the same trajectory whenever the
  --  command is correct, because airFriction is zero four lines above and an
  --  unforced horizontal velocity simply persists. They differ only where the
  --  command is WRONG, and there the command wins. Deleting it removes the only
  --  case where the two disagree.
  --
  --  OVERSHOOT IS STILL HANDLED, AND NOT BY THIS. The arrival brake above zeroes
  --  x with setVelocity once the unit reaches its landing, and the
  --  petportsLanding hold keeps it there. Both are untouched: this branch only
  --  ever ran while the unit was still in flight.
  --
  --  AN OPEN MEASUREMENT THIS SHOULD SETTLE. The same command, with the same
  --  groundForce, behaved asymmetrically: commanding -12 against an actual -10.8
  --  never closed the gap in five ticks, while commanding 0 against an actual 8
  --  closed it in two. Whether groundForce simply has no airborne authority in
  --  the ACCELERATING direction is unmeasured. If the pool-exit jumps stop
  --  arriving 0.4 short after this, that deficit was this call interfering and
  --  the question answers itself.
  --
  --  `velocity` SURVIVES because the liquid branch below reads velocity[2]. Only
  --  the horizontal half is removed.

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
  self.pather.moveArc = petportsArcMover

  --  SWIM IS BOUND FOR EVERY CHASSIS, INCLUDING GROUND ONES.
  --
  --  THE PATHFINDER PICKS EDGE TYPE BY MEDIUM, NOT BY CHASSIS. Measured: a
  --  gravity-ENABLED ground unit dropped into deep water was planned a route of
  --  Swim edges. canPathfind() is `onGround() or not gravityEnabled`, so it can
  --  only start that search while touching the bottom -- which it was.
  --
  --  So any unit can end up on a Swim edge, and vanilla's moveSwim is four
  --  lines with no look-ahead and NO `while` LOOP: it advances at most one edge
  --  per tick, so any overshoot leaves the cursor behind the unit and the next
  --  command points back at a waypoint already passed. That is the rubberbanding
  --  seen first on the aquatic chassis and then, identically, on a ground unit
  --  in water.
  --
  --  petportsFreeMover handles both Fly and Swim and is defined in
  --  petports_flyapproach.lua, which EVERY chassis now loads for exactly this
  --  reason. Called bare rather than nil-guarded: a missing script raises and is
  --  loud, while a guarded call to a file nobody loaded is silent, and the
  --  handoff records that costing a session.
  self.pather.moveSwim = petportsFreeMover

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
--  How far a unit must get from where it started before it is reported as
--  under way.
--
--  NOT ZERO. A unit jostled by another, or settling onto the ground on the
--  first tick, moves a little without having gone anywhere -- and a marker that
--  turns green and then sits still for twenty seconds while A* grinds is worse
--  than one that stayed yellow, because it asserts progress that is not
--  happening.
--
--  Two tiles is far enough to be deliberate and close enough that the colour
--  changes while the player is still watching.
--
--  NET DISPLACEMENT FROM startPosition, NOT ACCUMULATED PATH LENGTH, and the
--  change matters for two separate reasons.
--
--  Accumulated length only exists at the trace timer's granularity, so it could
--  not be sampled faster than once a second without also multiplying the
--  TASK_DEBUG block that shares that timer. Net displacement is a single
--  magnitude against a fixed point and can be taken as often as we like.
--
--  It is also immune to the sample rate in a way a running total is not. A
--  total that adds every measured wobble creeps upward while a unit stands
--  still -- slowly at one sample a second, five times faster at five -- so
--  speeding the old test up would have traded a late green for a false one.
--  Distance from a fixed point does not creep.
--
--  A VENT HOP COUNTS, deliberately. It displaces the unit well past two tiles
--  in one tick, so a unit that routes through a vent goes green the moment it
--  comes out the far side -- which is exactly what the marker is FOR. Nothing
--  else moves a unit that far without walking: moveJump's snap to its source is
--  capped at one tile and the platform drop placement is a quarter of one.
local TASK_MOVING_DISTANCE = 2.0

--  How often that test runs. Its own timer, NOT the trace timer.
--
--  THE TRACE TIMER WAS THE LAG. The old check rode inside the once-a-second
--  trace block, which itself sits below `if not stateData.arrived` and below
--  the vent branch's own `return false` -- so a unit walking to a vent mouth
--  never ran it at all, and every other unit waited out up to a full second of
--  trace phase on top of the port's half-second marker pass. See the pump in
--  update(), which is where this now runs from.
local TASK_MOVING_INTERVAL = 0.2

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

      --  Whether a dose was actually delivered. Same contract as `watered`: the
      --  port spends one medicalgoods from THIS number, so every early return in
      --  the medic branch -- patient gone, patient recovered, patient out of
      --  reach -- costs the player nothing.
      dosed = task.dosed,
      patient = task.patient,

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
--  WHAT COUNTS AS SOMETHING A WALKER CAN REST ON.
--
--  EXISTS BECAUSE world.pointTileCollision's DEFAULT SET DOES NOT INCLUDE
--  PLATFORMS, and the descend guard below was asking it whether there was floor
--  under a submerged candidate. There is no direct proof of what the default IS
--  -- findStandingPoint in petports_petport.lua carries an "UNVERIFIED" note on
--  exactly that question -- but there is proof of what it is NOT: this file
--  calls world.rectTileCollision(region, {"Platform"}) in three places for the
--  drop-through logic, and every one of them would be redundant if platforms
--  came back by default.
--
--  MEASURED 2026-08-31, an AMPHIBIOUS unit leashing to a submerged port at
--  [2535,1152] with platforms about two tiles beneath it:
--
--      ground spot [2532.5,1149.8] is floating and no floor below it
--      ground spot [2533.5,1149.8] is floating and no floor below it
--      ... all seven columns, 27090 rejections in one log
--
--  findGroundPosition FOUND the platforms -- 1149.8 in every column is the
--  platform row -- because validStandingPosition accepts a platform as ground.
--  The guard then threw all seven away and the unit stalled with no home to go
--  to. THE TWO PREDICATES DISAGREED ABOUT WHAT FLOOR IS.
--
--  Dynamic is NOT in this set, and the reason is simpler than the one first
--  written here. DYNAMIC COLLISION IN STARBOUND IS DOORS. Not crates, not
--  containers, not objects generally -- see fact.pathing.collisionkinds, which
--  exists because this mod has now guessed "crates are Dynamic" three times.
--  A door is not somewhere to resolve a home to, so it has no business in a set
--  that answers "can a walker rest on this".
--
--  Null is NOT in it either. An unloaded chunk is not floor; it is an absence of
--  information, and treating it as somewhere to stand would resolve homes into
--  regions nothing has confirmed exist.
local STANDABLE_TILE_SET = { "Block", "Slippery", "Platform" }

local GROUND_SEARCH_DOWN = -6
local GROUND_SEARCH_UP = 4

--  Column offsets to try, nearest first. THREE IS THE DEFAULT AND WAS THE ONLY
--  VALUE until this became the one resolver -- the port asks for wider searches
--  around machines and patients, so the range is a parameter now.
local COLUMN_RADIUS = 3

--  MEMOISED PER RADIUS, and the reason is not the allocation. The ORDER is the
--  answer in a first-fit search -- `petports_flyPointNear`'s header records what
--  ring-ordering cost when it was arbitrary -- so building it in one place means
--  a caller cannot accidentally hand over a differently ordered set and get a
--  differently biased result from the same function.
local columnCache = {}

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

--  Somewhere a ground unit can stand, near a drop.
--
--  Per COLUMN rather than per point: x is snapped to a tile centre because a
--  unit's boundBox is about a tile wide and centred, so an integer x straddles
--  two columns and only passes where both are clear. findGroundPosition then
--  supplies the y.
--  `searchUp` overrides how far above `position` a standing spot may be taken
--  from. Pass 0 to forbid climbing -- see the homeward bias in
--  approachTargetFor for why that is sometimes required.
--
--  FLYER BRANCH FIRST, and it ignores searchUp entirely. searchUp exists for
--  the homeward bias -- "do not resolve the port to its own roof" -- which is a
--  statement about which SURFACE to stand on, and a flyer is not standing on
--  one. petports_flyPointNear returns nil for a ground unit, so the whole
--  existing path below is untouched.
--
--  THIS IS NOW THE ONLY RESOLVER FOR "WHERE DOES A UNIT STAND NEAR A POINT".
--  There were three -- see arch.pathing.oneanchor for what each one got wrong --
--  and the other two are gone: petports_standingPointNear delegates here, and
--  findStandingPoint on the port is demoted to the no-unit-exists fallback its
--  own header always said it was. `radius` exists because the port asks wider
--  than a task does.
local function standableNear(position, searchUp, radius, mediumVerified, searchDown)
  --  A FREE-MOVING CHASSIS OWNS THIS ANSWER OUTRIGHT, INCLUDING THE nil.
  --  Same correction as petports_standingPointNear -- read the note there for
  --  the measurement. Short version: nil from petports_flyPointNear now means
  --  REFUSED as well as "not a flyer", and falling through to the ground search
  --  handed an aquatic unit a dry-land target one line after it declined one.
  if petports_freeMover() then
    --  `mediumVerified` is only meaningful to this branch: the ground search
    --  below decides medium by physics, and will not stand a walker in a liquid
    --  it avoids regardless of who vouches for what.
    local flyPoint = petports_flyPointNear(position, radius, mediumVerified)

    if TASK_DEBUG then
      sb.logInfo("UNIT fly point for %s -> %s",
        sb.printJson(position), (flyPoint ~= nil) and sb.printJson(flyPoint) or "REFUSED")
    end

    return flyPoint
  end

  if searchUp == nil then searchUp = GROUND_SEARCH_UP end

  --  TRAILING, NOT MIDDLE, AND THAT IS THE WHOLE REASON IT IS LAST. Every other
  --  caller passes four arguments and gets the constant; only the object-sized
  --  search overrides it. An argument added in the middle would have meant a nil
  --  in the middle of a callScriptedEntity list, which this mod has never
  --  measured -- see the note on petports_homePointNear.
  if searchDown == nil then searchDown = GROUND_SEARCH_DOWN end

  --  EVERY COLUMN IS ASKED, AND THE NEAREST ANSWER WINS. THIS USED TO RETURN
  --  THE FIRST ONE.
  --
  --  COLUMN_SEARCH is ordered nearest-first, which made the old first-fit loop
  --  look correct, and it is nearest BY COLUMN. Each column was exhausted --
  --  the full GROUND_SEARCH_UP above and GROUND_SEARCH_DOWN below -- before the
  --  next column was examined at all. So a spot six tiles DOWN in the target's
  --  own column beat one a single tile SIDEWAYS at exactly the right height.
  --
  --  MEASURED, watering a row of coffee against a cliff with water at its foot:
  --
  --    UNIT water CAST tile [2499,1152]                        tile 1, from [2499.85,1153.8]
  --    UNIT standable for [2498.5,1153.5] -> [2498.5,1147.8]   column offset 0
  --    UNIT reporting failed: arrived but 5.80751 from tile [2498,1152]
  --
  --  The unit had just watered tile 1 while standing 1.36 tiles from tile 2's
  --  standing point, and was then sent 5.7 tiles straight down into the sea.
  --
  --  TWO THINGS HAVE TO BE TRUE FOR IT TO LAND SOMEWHERE THAT SILLY, which is
  --  why it reproduces in one place and nowhere else. A WALL kills the target's
  --  own column at every sane height, because a 1.6-wide body centred on the
  --  tile overlaps it. And WATER BELOW makes the deep spot acceptable to an
  --  amphibious chassis: petports_avoidLiquid() is false, which skips
  --  findGroundPosition's own liquid rejection AND makes validStandingPosition
  --  count liquid as standable. A drone would have refused it and searched on.
  --
  --  THIRD INSTANCE OF ONE PATTERN. petports_flyPointNear had exactly this bug
  --  and its header carries the lesson -- "in a first-fit search the order IS
  --  the answer" -- but only free movers reach that function, and this one never
  --  got the same treatment.
  --
  --  WHY THE PER-COLUMN BEST IS SAFE TO RANK. findGroundPosition walks outward
  --  from position[2], so what it returns is the SMALLEST |dy| standable spot in
  --  that column. Every other spot in the same column shares its dx and has a
  --  larger |dy|, hence a larger true distance -- so the column's first answer
  --  is also the column's nearest, and taking the minimum across columns gives
  --  the genuine nearest overall rather than an approximation of it.
  --
  --  ITS UP-BEFORE-DOWN BIAS SURVIVES ONLY AS A TIE-BREAK. Up and down at equal
  --  |dy| are equidistant, so ranking cannot separate them and the column search
  --  still prefers up. That is unchanged behaviour, and `searchUp = 0` is still
  --  how a homeward task refuses to climb -- see approachTargetFor.
  --
  --  COST: seven findGroundPosition calls instead of an early exit on the first.
  --  This runs once per resolve, cached on stateData.groundTarget, not per tick.
  --
  --  STRICTLY LESS THAN, so ties keep COLUMN_SEARCH's order and the target's own
  --  column still wins whenever it can.
  local best = nil
  local bestOffset = nil
  local bestDistance = nil

  for _, offset in ipairs(columnsFor(radius)) do
    local x = math.floor(position[1] + offset) + 0.5

    --  petports_avoidLiquid(), NOT a hardcoded false. This resolver and the one
    --  inside approachPoint must answer the same question the same way, or a
    --  target resolves here and is refused there -- which is precisely how a
    --  unit ends up standing still with approachPosition nil and nothing in the
    --  log to explain it. See the flag's header in petports_contract.lua.
    local ok, resolved = pcall(findGroundPosition,
      {x, position[2]}, searchDown, searchUp, petports_avoidLiquid())

    --  Guard the SHAPE, not just nil-ness: pcall returns the error message in
    --  this slot on failure, and a string indexes without complaint.
    local usable = ok
      and type(resolved) == "table"
      and type(resolved[1]) == "number"
      and type(resolved[2]) == "number"

    --  A GROUND SPOT IN A FORBIDDEN LIQUID IS NOT A SPOT.
    --
    --  findGroundPosition answers a geometry question and knows nothing about
    --  which liquids this chassis refuses. For a walker petports_mediumAllows
    --  returns true for everything EXCEPT a denied liquid, so this costs one
    --  predicate on the path that has always worked and is the only thing
    --  stopping an amphibious chassis from wading into lava.
    if usable and not petports_mediumAllows({ resolved[1], resolved[2] }) then
      if TASK_DEBUG then
        sb.logInfo("UNIT ground spot %s rejected: a liquid this chassis will not enter",
          sb.printJson(resolved))
      end
      usable = false
    end

    --  IS THERE ACTUALLY FLOOR UNDER THIS? ASSERTION ONLY -- NOTHING ACTS ON IT.
    --
    --  Underwater, petports_avoidLiquid() false makes validStandingPosition
    --  count liquid as standable, so EVERY point in the water passes. With the
    --  up-before-down bias, findGroundPosition can return the first wet point
    --  it meets rather than descending to the seabed -- a spot hanging in open
    --  water, which a walking chassis can never end a path on.
    --
    --  SUSPECTED CAUSE of the submerged-animal failure. A cow's entity position
    --  is its CENTRE, floating above the floor; a dropped item rests ON the
    --  floor. Same resolver, same pond, two tiles apart: the drop resolved to
    --  1142.8 and was reached, the cow to 1143.8 and was not. Exactly one tile.
    --
    --  MEASURED 2026-08-30, and it is the whole submerged-animal bug. A cow's
    --  entity position is its CENTRE, floating above the seabed; a dropped item
    --  rests ON it. Same pond, same resolver, targets two tiles apart:
    --
    --    drop  [2536.42,1142.62] -> [2536.5,1142.8]   reached, item collected
    --    cow   [2534.33,1143.38] -> [2534.5,1143.8]   no route, ever
    --
    --  No bias to blame: from 1143.38 the floating spot at 1143.8 is 0.42 away
    --  and the seabed at 1142.8 is 0.58, so findGroundPosition returned the
    --  genuinely NEARER one. Nothing rejected it because underwater
    --  validStandingPosition calls every point standable.
    --
    --  IT DESCENDS -- IT DOES NOT REJECT. Rejecting was tried first and broke
    --  every submerged target: findGroundPosition returns ONE answer per
    --  column, so refusing it discards the column instead of searching it
    --  lower. All seven columns returned the same floating y, all seven were
    --  refused, and the resolver reported no standable position at all --
    --  1456 rejections and a unit that never moved.
    --
    --  STEPS DOWN ONE TILE AT A TIME, re-validating each with the same
    --  predicate the column search uses, so what comes back is a position this
    --  column actually passed rather than an unchecked guess. Bounded by the
    --  search depth already in scope, so it cannot walk off into the dark.
    --
    --  FREE MOVERS ARE EXEMPT. A flyer or an aquatic unit is SUPPOSED to finish
    --  in open water; this is the walking chassis's constraint alone.
    --
    --  DRY LAND IS UNTOUCHED: `wet` is false there, so every route that has
    --  ever worked pays one predicate and exits.
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

          --  STOP AT THE FIRST STANDABLE TILE either way. Past it we are inside
          --  the seabed -- or under a platform -- and a deeper hit would be a
          --  different cave.
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
    --  ALWAYS LOGGED, not behind TASK_DEBUG. The old line was the one that
    --  named the bug -- "-> [2498.5,1147.8] (column offset 0)" is the whole
    --  diagnosis in one string -- and a resolve landing somewhere surprising is
    --  worth seeing without a flag set. The distance is what makes a wrong one
    --  obvious at a glance.
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

--  THE ONE RESOLVER, EXPORTED UNDER A PREFIXED NAME.
--
--  A monster's scripts share one Lua environment, so this is reachable from
--  petports_contract.lua even though that file loads FIRST -- the delegate there
--  runs at call time, by which point every chunk has executed.
--
--  EXPORTED RATHER THAN MOVED, because everything it depends on lives here:
--  COLUMN_RADIUS, GROUND_SEARCH_DOWN, STANDABLE_TILE_SET, TASK_DEBUG. Moving the
--  function to contract would mean moving four constants and leaving the task
--  side reaching across for them, which trades one split for another.
--
--  NOT nil-GUARDED AT ITS CALL SITES, deliberately. A unit whose monstertype
--  omits this file should RAISE, loudly, on the first resolve -- the same rule
--  the moveSwim binding follows in freshPather, and for the same reason the
--  handoff records: a guarded call to a file nobody loaded is silent and costs a
--  session.
petports_standablePoint = standableNear

--  A STANDING POINT SIZED TO AN OBJECT RATHER THAN TO A POINT.
--
--  THE DEFAULT SEARCH IS ANCHORED ON AN ENTITY POSITION AND REACHES FOUR TILES
--  UP. That is right for a crop, a drop or a cow, and wrong for anything TALL:
--  an object's entity position sits near its base, so a container taller than
--  GROUND_SEARCH_UP has a perfectly good roof the search cannot see. A submerged
--  shipping container is where that became visible -- a ground unit could walk a
--  platform to it and had nowhere to be sent -- but the bug is general and every
--  tall object had it.
--
--  THE FOOTPRINT BOX PLUS TWO TILES ON EVERY SIDE. The buffer is what makes the
--  roof REACHABLE rather than merely included: the top row is inside the object,
--  and the tile a unit actually stands on is the one above it. Two rather than
--  one because the same margin has to serve the sides, where the unit stands
--  BESIDE the object on ground that may itself step down.
--
--  IT WIDENS THE SEARCH AND RELAXES NOTHING. Whether the chassis may work here
--  was already settled by targetSuits over this same footprint, and every
--  candidate still passes validStandingPosition, petports_mediumAllows and the
--  descend guard exactly as before. A wider net, the same fish.
--
--  NO COLLISION KIND IS CONSULTED, DELIBERATELY. Whether a container top is
--  Block or Platform does not matter here: STANDABLE_TILE_SET holds both and
--  validStandingPosition accepts either, so the roof is standable either way.
--  Gating this on "has platform collision" would have excluded the Block case,
--  which fact.pathing.collisionkinds says is what a crate top actually is.
--
--  IT LIVES HERE RATHER THAN IN petports_contract.lua, WHERE THE OTHER TWO
--  ENTRY POINTS ARE, because GROUND_SEARCH_UP, GROUND_SEARCH_DOWN and
--  COLUMN_RADIUS are locals of this file. A copy of them next to the contract's
--  delegates would be three constants needing to stay equal across two files,
--  which is the drift arch.pathing.oneanchor exists to have stopped.
--
--  FREE MOVERS FALL THROUGH UNCHANGED. standableNear hands a free-moving chassis
--  to petports_flyPointNear before any of this is read.
OBJECT_SEARCH_BUFFER = 2

--  Somewhere to stand on TOP of an object, found from the object rather than
--  from the tile world.
--
--  THE ROW ABOVE THE TOP ROW. `bounds` holds tile CENTRES, so the top row is
--  bounds[4] - 0.5 and a unit standing on it has its feet at bounds[4] + 1.3 --
--  which is the same `row + 1.8` the column search produces, e.g. a floor row of
--  1152 giving 1153.8. The floor test then samples one full tile below, exactly
--  as the descend guard does.
--
--  NEAREST COLUMN WINS, ranked by true distance, for the same reason
--  standableNear ranks rather than first-fits: the order of a first-fit search
--  IS its answer, and this file has had that bug three times.
local function objectRoofPoint(position, bounds)
  if position == nil or type(bounds) ~= "table" or #bounds < 4 then return nil end

  local roofY = bounds[4] + 1.3
  local best, bestDistance = nil, nil

  for x = math.floor(bounds[1]) + 0.5, math.floor(bounds[3]) + 0.5, 1 do
    local candidate = { x, roofY }
    local why = nil

    --  STANDABLE_TILE_SET, NOT THE DEFAULT. This is the whole reason the
    --  fallback exists -- see the note at its call site.
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

function petports_objectPointNear(position, bounds, mediumVerified)
  if position == nil or type(bounds) ~= "table" or #bounds < 4 then return nil end

  local minX, minY, maxX, maxY = bounds[1], bounds[2], bounds[3], bounds[4]

  --  THE RADIUS IS THE FURTHER SIDE, not half the width. `position` is the
  --  entity position and is not guaranteed to sit at the box's centre, so
  --  measuring to both edges and taking the larger is what actually covers it.
  local reach = math.max(math.abs(minX - position[1]), math.abs(maxX - position[1]))
  local radius = math.ceil(reach) + OBJECT_SEARCH_BUFFER

  --  OFFSETS FROM position[2], because that is what findGroundPosition takes.
  --  Up positive, down negative, matching GROUND_SEARCH_UP and _DOWN.
  local up = math.ceil(maxY - position[2]) + OBJECT_SEARCH_BUFFER
  local down = math.floor(minY - position[2]) - OBJECT_SEARCH_BUFFER

  --  NEVER TIGHTER THAN THE DEFAULTS. A one-tile crate or a crop would otherwise
  --  come out with a SMALLER search than it gets today, which would be a
  --  regression wearing a fix's clothes.
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

  --  THE ROOF, ASKED FOR DIRECTLY, WHEN THE COLUMN SEARCH FOUND NOTHING.
  --
  --  MEASURED 2026-09-01 by /entityeval on the submerged shipping container:
  --
  --      pointTileCollision(top tile)                          false
  --      pointTileCollision(top tile, STANDABLE_TILE_SET)      true
  --
  --  The container IS standable -- the author stood on it -- and the DEFAULT
  --  collision set does not report it. That is fact.pathing.platformfloor
  --  exactly, one layer further down: there, the descend guard asked with
  --  defaults and threw away platforms findGroundPosition had found. Here the
  --  column search returned NOTHING AT ALL for twenty-one columns -- not one
  --  candidate logged, rejected or descended -- so whatever dropped it sits
  --  inside findGroundPosition, below anything this file can pass kinds to.
  --
  --  SO THIS STOPS ASKING IT. The object's own footprint already says where the
  --  roof is; the standing row is the one above the top row. Every candidate is
  --  then put through the SAME three predicates the column search uses, with the
  --  floor test given STANDABLE_TILE_SET explicitly -- so this is a different
  --  route to the answer, not a weaker standard.
  --
  --  A FALLBACK, NOT A REPLACEMENT. It runs only where the existing search
  --  produced nothing, so every target that resolves today resolves the same way
  --  by the same code. There is no case this can make worse.
  --
  --  IT LOGS WHICH PREDICATE REFUSED, and that is half the point of building it
  --  this way. If the roof is still refused, the next log says whether it was the
  --  floor, the medium or validStandingPosition -- which is the measurement the
  --  column search could not produce, because it reported one silence for
  --  twenty-one columns.
  return objectRoofPoint(position, bounds)
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

  --  THE PORT'S VOUCH, ARRIVING WITH THE WORK.
  --
  --  Most task types dispatch a RAW target position and leave the unit to
  --  resolve its own approach point -- see the note in restockFetchWork. That
  --  re-resolution runs petports_flyPointNear's single-point veto, which cannot
  --  see a footprint, so a half-submerged crate the port vetted and cleared was
  --  refused here on arrival: 1122 outright declines against one container in
  --  one session, and every fetchwater failure in it belonged to the flyer while
  --  the swimmer serviced the same crate without trouble.
  --
  --  `mediumVerified` is set by the generator that ran the footprint ladder, so
  --  it is absent on exactly the tasks that never ran one -- `animal`, `medic`,
  --  `return` and `diag` -- and those keep the veto. See arch.dispatch.vouch.
  --
  --  NOT APPLIED TO THE HOMEWARD BRANCH, which is `return`, which never carries
  --  it. Written as a lookup rather than a branch so the leash cannot acquire a
  --  vouch by accident later.
  local verified = task ~= nil and task.mediumVerified or nil

  if homeward then
    stateData.groundTarget = standableNear(rawPosition, 0, nil, verified)

    if stateData.groundTarget == nil then
      sb.logInfo("UNIT no floor beneath %s -- falling back to an unbiased search",
        sb.printJson(rawPosition))
      stateData.groundTarget = standableNear(rawPosition, nil, nil, verified)
    end
  else
    --  AN OBJECT TARGET IS SIZED TO ITS FOOTPRINT HERE TOO, AND THE OMISSION
    --  WAS THE WHOLE BUG.
    --
    --  MEASURED 2026-09-01. The PORT resolved a standing point on the roof of a
    --  submerged shipping container -- `roof point for [2553,1147] ... ->
    --  [2552.5,1153.8]` -- dispatched on it, and the unit then declined the same
    --  target two seconds later with `no standable position near withdraw
    --  target`. The port had run petports_objectPointNear; this line ran the bare
    --  column search, which is exactly the search that had already returned
    --  nothing for twenty-one columns.
    --
    --  arch.pathing.oneanchor, AGAIN, AND IN ITS PUREST FORM: two resolvers,
    --  identical inputs, opposite answers. Routing both through
    --  petports_objectPointNear with the same bounds and the same raw position
    --  is what makes the port's dispatch and the unit's approach agree by
    --  construction rather than by both happening to be right.
    --
    --  `task.target` IS AN ENTITY ID ONLY FOR SOME TASK TYPES -- replant and
    --  water carry a tile key string instead. No branch is needed:
    --  petports_habitatObjectBounds pcalls world.objectSpaces, so a string, a nil
    --  or a dead id all come back nil and the old path runs untouched.
    local bounds = nil
    if task ~= nil then
      bounds = petports_habitatObjectBounds(task.target)
    end

    if bounds ~= nil then
      stateData.groundTarget = petports_objectPointNear(rawPosition, bounds, verified)
    end

    --  STILL FALLS BACK. petports_objectPointNear never searches TIGHTER than
    --  the default, so this can only matter if it returned nil outright -- but a
    --  target that used to resolve must keep resolving, and that guarantee is
    --  cheaper to keep than to reason about.
    if stateData.groundTarget == nil then
      stateData.groundTarget = standableNear(rawPosition, nil, nil, verified)
    end
  end

  return stateData.groundTarget
end

--  CAN THE SEARCH BEGIN FROM WHERE THE UNIT IS STANDING?
--
--  THE UNIT'S POSITION AND THE UNIT'S NODE ARE DIFFERENT PLACES, AND THE SEARCH
--  ONLY KNOWS THE NODE. `PathFinder:find` hands mcontroller.position() to
--  world.platformerPathStart, which rounds it onto the lattice before anything
--  else happens. Vanilla checks the TARGET is standable and never checks the
--  origin at all -- there is no such line in pathing.lua.
--
--  So a unit can be genuinely on the ground, pass canPathfind(), and have the
--  search begin from a node hanging in mid air. The plan then opens with a
--  ballistic fall the unit cannot perform, the arc-landing guard correctly
--  refuses it, and A* re-runs from the same unchanged position and returns the
--  same plan. Nothing in the loop moves, so nothing breaks it.
--
--  MEASURED, twice, to the digit. A unit landed on the top-left corner of a
--  crate at [2503.39,1166.79], carried by a 0.19-tile sliver of it:
--
--    body        2502.59 .. 2504.19   overlaps the crate at column 2504
--    node        [2503,1166.8]
--    node body   2502.20 .. 2503.80   entirely over the void
--
--    UNIT approach at [2503.39,1166.79] (standable true) ... onGround true
--    UNIT path ACQUIRED ... action Arc ... edge 1 of 93
--
--  Standable where it is, airborne where the search thinks it is. Three
--  different targets that session -- [2520.5,1152.8], [2501.5,1163.8],
--  [2549.5,1159.8] -- all produced a first edge descending from [2503,1166.8].
--  THE CONSTANT IS THE ORIGIN, NOT THE GOAL, and that is the whole diagnosis.
--
--  297 refusals over 92 seconds, ending in a re-home. Every rung of the
--  recovery ladder below rehomeUnit re-plans through the same broken origin --
--  the recall's own plan opened with the identical fall -- so only the teleport
--  could break it.
--
--  THIS FAILS OPEN, DELIBERATELY, AND IT IS THE ONE PLACE IN THIS FILE THAT
--  DOES. Everything else here fails closed because guessing is worse than
--  declining. Not this: a false negative refuses to plan and bricks a unit that
--  was fine, while a false positive plans exactly as the code does today. The
--  worst outcome of being wrong is the behaviour we already have.
--
--  Returns the node alongside the verdict so the caller can log it. A free
--  mover is always plannable here: mustEndOnGround derives false for it, so
--  standing is not a property its start node needs. Its equivalent problem is
--  the medium, and petports_flyPointNear already owns that.
--
--  THIS IS A PURE QUESTION ABOUT THE NODE AND ASKS NOTHING ABOUT BEING
--  AIRBORNE. It used to, and that was a defect: an airborne unit came back
--  "plannable, node nil", the caller could not tell that from a nudge having
--  succeeded, and it logged `node null is standable` and rebuilt the pather --
--  discarding a live path IN FLIGHT, which canPathfind() then cannot replace
--  until the unit lands. Measured twice:
--
--    UNIT FLIGHT left the ground at [2503.03,1166.3] ...
--    UNIT origin nudge DONE at [2503.03,1166.3]: node null is standable
--    UNIT path LOST at [2503.03,1166.3]: ... onGround false
--
--  The ground gate belongs to the caller, which has somewhere sensible to put
--  the answer. Two return paths that a caller cannot distinguish is the bug,
--  not the check itself.
local function originIsPlannable()
  if petports_freeMover() then return true, nil end

  local node = petports_nodePosition(mcontroller.position())

  --  pcall because validStandingPosition indexes its arguments, and a shape it
  --  does not like raises rather than returning false. See standableNear.
  local ok, standable = pcall(validStandingPosition, node, petports_avoidLiquid())
  if not ok then return true, node end

  return standable == true, node
end

--  WHERE TO STAND SO THE SEARCH HAS SOMETHING TO BEGIN FROM.
--
--  SAME ROW ONLY, AND THAT IS NOT A SIMPLIFICATION. Walking changes x, not
--  which floor the unit is standing on -- the lesson petportsJumpMover's
--  wrong-level branch is built out of. A standable node one row up is not
--  somewhere a walk can deliver the unit, so offering it would produce motion
--  toward a place it cannot reach, and motion is what the stall detector reads
--  as health.
--
--  ORDERED BY TRUE DISTANCE, because in a first-fit search the order IS the
--  answer. petports_flyPointNear's header records what ring-ordering cost when
--  this was got wrong there.
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

    --  The same forbidden-liquid gate every other resolver in this file
    --  applies. A node in lava is standable geometry and not a destination.
    if ok and standable and petports_mediumAllows(candidate) then
      return candidate, entry[2]
    end
  end

  return nil
end

--  Push the unit onto its own node before anything asks the pathfinder a
--  question. Returns true when the caller should stand down for this tick.
--
--  RUNS BEFORE THE PLAN, NOT AFTER IT. Catching this from a returned plan is
--  possible -- a descending airborne first edge while grounded is conclusive --
--  but it pays for a search first, and in the measured case no usable plan came
--  back at all. One predicate per tick is cheaper than one A* per tick.
--
--  IT DOES NOT DRIVE THE PATHER. While a nudge is running the unit is steered
--  directly with moveX, because the pathfinder is precisely the thing that
--  cannot help from here. On completion the pather is rebuilt, since whatever
--  plan it holds was drawn from the bad node.
local function nudgeOrigin(stateData, dt)
  --  AIRBORNE FIRST, BEFORE THE PREDICATE IS EVEN ASKED.
  --
  --  A falling unit's node is SUPPOSED to be in mid air, so the predicate has
  --  no useful answer, and canPathfind() already refuses to search from one.
  --  This branch used to live inside originIsPlannable, where its "true" was
  --  indistinguishable from a nudge succeeding -- see the note there for the
  --  path it destroyed in flight.
  --
  --  ABANDONING IS NOT COMPLETING. No freshPather here: the premise was
  --  "standing in the wrong place", the unit is no longer standing, and gravity
  --  is now solving it. Whatever plan the pather holds is the landing's problem.
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

    --  Cleared on success so a unit that gets stuck again later gets a fresh
    --  attempt rather than inheriting an old refusal.
    stateData.originNudgeFailed = nil
    return false
  end

  --  Already tried and could not find anywhere. Do not re-probe every tick;
  --  the position has not meaningfully changed and the answer will not either.
  if stateData.originNudgeFailed then return false end

  if stateData.originNudge == nil then
    --  ONLY WHEN THERE IS NO PLAN TO RUIN.
    --
    --  "Pre-flight before every plan" means before a SEARCH, not before every
    --  tick, and scoping it to the tick was a defect. A plan may legitimately
    --  walk the unit across a ledge edge, and while it is doing so the node
    --  under the unit is genuinely not standable -- which is fine, because
    --  nobody is about to plan from it. Measured: a correct six-edge Walk plan
    --  deliberately walked the unit LEFT off the crate toward the crops, the
    --  node flipped un-standable as it crossed x 2503.5, and the nudge fired
    --  and pushed RIGHT against a plan that was working.
    --
    --    UNIT pre-move at [2503.41,1166.8]: action Walk edge 1 of 6
    --    UNIT origin NOT PLANNABLE at [2503.41,1166.8] ... nudging to [2504,1166.8]
    --
    --  It only came out right because momentum carried the unit off the ledge
    --  anyway. A recovery that overrides a working plan is not a recovery.
    --
    --  hasPath false covers both cases that matter: no plan yet, and a plan
    --  just discarded by a guard or a stall. A search still running (aStar set,
    --  hasPath false) is one that STARTED from the bad origin and is therefore
    --  wasted, so interrupting it is right too.
    --
    --  A nudge already under way is exempt: it runs the branches above this one
    --  and never reaches here, so completing it is never cancelled by the stale
    --  plan the pather is still carrying.
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

  --  Arrived by distance. The predicate flipping is checked at the top of the
  --  next tick and is what actually ends the nudge; this only stops the walk
  --  from running past the node it was aimed at.
  if math.abs(toTarget) <= ORIGIN_NUDGE_ARRIVE then
    --  Vanilla's own braking line from moveLand, read the same way. NOT
    --  `groundForce or 0` -- a missing field would then brake with no force at
    --  all, silently, and a unit coasting past its node looks like the nudge
    --  not working rather than like a bad read.
    mcontroller.controlApproachXVelocity(0, mcontroller.baseParameters().groundForce)
    return true
  end

  local direction = (toTarget > 0) and 1 or -1
  moveX(direction, false)
  mcontroller.controlFace(direction)

  return true
end

--  CAN THE PLAN BE WALKED FROM WHERE THE UNIT IS ACTUALLY STANDING?
--
--  THIS REPLACES A HEIGHT COMPARISON, AND THE HEIGHT COMPARISON WAS THE WRONG
--  QUESTION. Asking "am I on the surface the plan used" assumes there is only
--  one surface worth being on, and in player builds there routinely is not: a
--  chute lined with platforms above a dirt floor offers two valid standing
--  heights a tile apart in the same column, and a route along either is a route.
--  Rejecting a plan because the unit ended up on the other one is churn, and if
--  A* keeps answering with the same surface it is a loop of exactly the shape
--  this file already spends two hundred lines fighting.
--
--  What actually matters is not height, it is CLEARANCE. The unit wedges when
--  its box cannot fit through the space the next Walk edge crosses -- which is
--  a fact about the body and the terrain, not about which tile the planner
--  happened to stand on. So test that directly.
--
--  Both observed cases fall out correctly:
--
--    unit at 1027.8, plan walking left to 3756 -- box spans y 1027.0..1028.6,
--    dirt at row 1028, the sweep collides, the plan is refused. That is the
--    wedge that produced the cage loop.
--
--    unit on a dirt floor, plan drawn along the platform a tile above it --
--    the sweep at the unit's own height is clear, the plan is kept, and it
--    walks the planner's x route on the surface it is standing on.
--
--  Platforms are excluded from the collision set on purpose. They do not
--  obstruct horizontal travel, and including them would refuse every walk
--  underneath one -- which in a platform-lined chute is all of them.
--
--  Returns nil when there is no Walk edge near enough to test, which is a
--  different answer from "clear" and the caller must treat it as such.
local PLAN_WALK_LOOKAHEAD = 6

--  HOW CLOSE A LOWER GROUND EDGE HAS TO BE TO SAY ANYTHING ABOUT THE SURFACE WE
--  ARE STANDING ON.
--
--  1.25, AND 2.0 WAS WRONG BY ITS OWN LOG. Sized to separate two shapes the scan
--  cannot otherwise tell apart, from three measurements in one session:
--
--      ~1.0   the wedge this scan exists for -- a Land at our height with its
--             lower Walks immediately after it. MUST still fire.
--       2.0   a unit standing at [2547,1153.55] on the west end of the shipping
--             container, with the plan stepping off at [2545,1152.8]. MUST NOT
--             fire: this is the ledge two tiles ahead, and dropping here is what
--             put the unit back in the water it had just climbed out of.
--       6.35  the same ledge seen from the middle of the container roof. MUST
--             NOT fire; this is the drop that started the whole investigation.
--
--  THE FIRST DRAFT OF THIS CONSTANT WAS 2.0 AND WOULD HAVE FIRED ON THE SECOND
--  CASE, because the test is `<=` and the measurement is exactly 2.0. The number
--  was reasoned from the two extremes while the middle case was sitting in the
--  same log, four lines further down. Read the whole log before picking a
--  threshold from the ends of it.
--
--  ERR SMALL. Too small costs a drop that happens a tick later, once the unit has
--  walked closer to the ledge. Too large costs a unit dropping through the floor
--  it is standing on. Those are not comparable, so the gap above the wedge's ~1.0
--  is deliberately thin.
local PLAN_DROP_REACH = 1.25

--  THE PLAN WANTS US A STOREY DOWN. DROP, DO NOT REPLAN.
--
--  When a plan's next ground edge sits below the unit, replanning is the wrong
--  answer even though it is the safe-looking one. A* re-runs from
--  mcontroller.position(), so it plans from the same tile, and in a platform
--  chute it hands back the same route it just handed back -- which is a loop
--  built out of nothing but caution.
--
--  The unit is standing on a platform. Going down one is a solved problem: it
--  is the same placement the Drop edge itself uses, and it is exact. So take
--  it, keep the plan, and let the next tick judge the result.
--
--  ONE PLATFORM PER CALL, and the floor passed in is what enforces it.
--  lastPlatformToPass returns the LOWEST platform surface above the floor it is
--  given, so handing it the plan's own floor would pick a surface several rungs
--  down and place the unit through everything between -- exactly the teleport
--  the origin assertion in scootThroughPlatform now refuses. Half a tile under
--  the unit's own feet leaves only the surface it is standing on in range.
--
--  A gap of several tiles therefore descends one rung per tick rather than in
--  one jump, each step asserting its own origin. Slower, and it cannot pass
--  through anything.
--
--  Fails closed. Standing on dirt rather than a platform returns no surface to
--  pass, the drop refuses, and the caller falls through to whatever it would
--  have done anyway.
local function tryPlanDrop(pather, finder)
  if pather == nil or finder == nil then return false, "no pather", false end
  if not mcontroller.onGround() then return false, "airborne", false end

  local edges = finder.edges
  local index = finder.currentEdgeIndex
  if edges == nil or index == nil then return false, "no path", false end

  local here = mcontroller.position()

  --  SCAN THE WHOLE GROUND RUN, NOT JUST THE EDGE UNDER THE CURSOR.
  --
  --  Checking only the current edge misses the shape that actually occurs: a
  --  Land at the unit's own height, reading a perfectly innocent gap of 0,
  --  followed by Walk edges a storey down. The check passes, moveLand advances
  --  on horizontal distance alone, and the unit walks the lower plan at the
  --  upper height -- which is the wedge, one edge later than anything was
  --  looking.
  --
  --  WALK AND LAND ONLY, AND THE EXCLUSIONS ARE THE WHOLE DESIGN:
  --
  --    Drop is excluded because a Drop edge targets below the unit BY
  --    DEFINITION -- that is what the action is. Treating it as evidence of a
  --    wrong storey would fire on every plan containing one and pre-empt a
  --    descent the plan already performs correctly, one rung early, every time.
  --
  --    Jump and Arc end the scan outright. Past them the plan is deliberately
  --    at a different height, and an edge below us on the far side of a jump
  --    says nothing about where we are standing now.
  --
  --  So the scan covers exactly the run of ground work the unit is expected to
  --  perform from the surface it is on, and a Walk or Land inside that run
  --  sitting below us can only mean the surface is wrong.
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

      --  AND IT HAS TO BE AN EDGE WE HAVE ACTUALLY REACHED.
      --
      --  A LOWER EDGE FAR AHEAD IS THE PLAN DESCENDING, NOT US ON THE WRONG
      --  STOREY, and without this the scan cannot tell those apart. MEASURED
      --  2026-09-01, a ground unit leaving the roof of a submerged shipping
      --  container westward:
      --
      --      PLAN DROP at [2551.35,1153.55]: Walk edge 7 targets [2545,1152.8],
      --      1 below us -- dropped one platform (cursor is Walk edge 1)
      --
      --  Edges 1..6 were the roof at 1153.8 and the unit was correctly standing
      --  on them. Edge 7 -- the LAST index PLAN_WALK_LOOKAHEAD admits -- was the
      --  ground a tile lower, six tiles west, where the plan steps off the
      --  container. The scan took the worst edge in the run, called the roof the
      --  wrong storey, and dropped the unit through the platform it was walking
      --  on. It swam out, climbed back on, and did it again.
      --
      --  IT ONLY BIT NOW BECAUSE THE DROP HAS TO SUCCEED TO HURT. On solid
      --  ground scootThroughPlatform refuses and the mistake is a log line; the
      --  container is the first PLATFORM-collision footing a walker has ever
      --  been given, so this is the first time the bad verdict could act.
      --
      --  PROXIMITY IS THE DISCRIMINATOR, AND IT KEEPS THE SHAPE THE SCAN WAS
      --  BUILT FOR. The wedge case in the header -- a Land at our height
      --  followed by Walks a storey down -- has those Walks IMMEDIATELY after
      --  the Land, within a tile. A legitimate step-down sits further along the
      --  run. Gating on distance separates them without narrowing the lookahead,
      --  which would reintroduce the wedge.
      --
      --  THE SAME LOG ALSO CAUGHT THE UNIT AT THE CONTAINER'S WEST END, two
      --  tiles from the step-down, dropping straight back into the water it had
      --  just climbed out of. That case is why PLAN_DROP_REACH is 1.25 and not
      --  the 2.0 the two outer measurements suggested -- see the constant.
      --
      --  IT ALSO MAKES THE DROP HAPPEN IN THE RIGHT PLACE rather than merely not
      --  happening in the wrong one. The unit now walks the roof to the step and
      --  drops there, which is what the plan describes.
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

local function planWalkBlocked(finder)
  local edges = finder and finder.edges
  local index = finder and finder.currentEdgeIndex
  if edges == nil or index == nil then return nil end

  local walkEdge = nil
  local walkIndex = nil

  --  STOP AT THE FIRST EDGE THAT LEAVES THE GROUND.
  --
  --  The sweep is taken at the unit's CURRENT height, so it only means anything
  --  for edges the unit could reach without changing surface. Land and Walk
  --  qualify; a Jump, Arc or Drop in between means the plan moves to a
  --  different height before that Walk happens, and testing it here answers a
  --  question nobody asked.
  --
  --  MEASURED, and this is why the bound exists: a unit landed at
  --  [3753.02,1026.8] holding a Land edge targeting [3752,1023.8] -- three
  --  tiles below it -- and the scan ran past that Land to a Walk edge six
  --  ahead, found it clear, and kept a plan whose very next step was
  --  unreachable. moveLand then sat at srcDist 3.33 doing nothing until the
  --  stall check replanned 0.65s later, every lap.
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

  --  The swept box from where the unit stands to where the edge ends, at the
  --  unit's OWN height rather than the plan's.
  local sweep = {
    math.min(here[1], targetX) + bounds[1],
    here[2] + bounds[2],
    math.max(here[1], targetX) + bounds[3],
    here[2] + bounds[4]
  }

  local blocked = world.rectTileCollision(sweep, { "Null", "Block", "Dynamic" })

  return blocked, walkIndex, walkEdge, sweep
end

--  WHERE THE PLAN SAYS THE UNIT SHOULD BE AT THIS ALTITUDE.
--
--  Walks forward from the cursor through the Arc run and finds the first
--  segment whose endpoints bracket `y`, then interpolates x across it. Returns
--  nil when nothing brackets -- above the first waypoint, below the last, or a
--  plan with no arc left.
--
--  FIRST BRACKET, NOT NEAREST. An arc's y is not monotonic across its apex, so
--  a rising arc can bracket one altitude twice. Taking the first match from the
--  cursor forward is right for a FALL, which is what this exists to measure,
--  and is knowingly approximate on the ascending half of a jump.
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

        --  A LEVEL SEGMENT BRACKETS EVERY y INSIDE IT AND INTERPOLATES
        --  NONE OF THEM. Report its start rather than dividing by zero.
        if math.abs(span) < 0.0001 then return from[1] end

        local t = (from[2] - y) / span
        return from[1] + t * (to[1] - from[1])
      end
    end

    if edge.action ~= "Arc" and i > index then break end
  end

  return nil
end

--  ONE LINE PER TICK FOR THE WHOLE OF A FLIGHT.
--
--  BUILT 2026-09-01 BECAUSE 12 Hz RECONSTRUCTION RAN OUT. Three explanations
--  for a unit falling short of its planned arc -- a late Walk -> Arc handover, a
--  liquid drag leak, and the planner-velocity steering since deleted -- all
--  produce the same shape when sampled from `pre-move` lines alone. The author
--  watching at 60 fps could see the trajectory break BEFORE the waterline,
--  which no reading of the existing log could confirm or refute. This is the
--  instrument that separates them.
--
--  IT FIRES REGARDLESS OF EDGE ACTION, and that is the point. The first
--  airborne tick of a walk-off is still on the WALK edge -- the pather does not
--  advance to the Arc until the following tick -- so anything gated on `action
--  == "Arc"` misses the handover, which is the interval under suspicion.
--
--  liquidMovement() IS THE FIELD THAT SETTLES THE DRAG QUESTION. It is the
--  engine's own verdict on whether this body is being moved as a swimmer, so it
--  beats inferring a waterline from where a swimmer floats. If horizontal speed
--  decays across ticks that all report false, drag is not the mechanism and the
--  liquidFriction control test is unnecessary.
--
--  POSITIONS ARE THE TRUTH AND VELOCITY IS NOT. proc.pathing.velocitysample
--  records that a reported velocity is a friction sampling artifact; the
--  round-numbered [8,-10] readings in every arc log are planner values, not
--  measurements. `moved` is the real displacement since the previous trace line
--  and `dt` is the interval it happened over -- divide them and that is the only
--  honest velocity in the line. mcontroller.velocity() is kept BESIDE it so the
--  size of the artifact is on the record rather than in a comment.
--
--  ONE FLIGHT PER `#n`, so a log with six falls in it sorts into six flights
--  without matching timestamps by hand.
local function flightTrace(dt, stateData)
  if not FLIGHT_TRACE then return end

  local here = mcontroller.position()
  local grounded = mcontroller.onGround()
  local prev = stateData.petportsTrace

  --  Grounded and was already grounded: nothing in flight, keep the anchor
  --  fresh so the first airborne tick has something to measure against.
  if grounded and (prev == nil or prev.grounded) then
    stateData.petportsTrace = {
      pos = here, grounded = true, tick = 0,
      flight = (prev and prev.flight) or 0
    }
    return
  end

  local flight = (prev and prev.flight) or 0
  local tick = (prev and prev.tick or 0) + 1

  --  A NEW FLIGHT STARTS ON THE FIRST TICK OFF THE GROUND.
  if prev == nil or prev.grounded then
    flight = flight + 1
    tick = 1
  end

  local finder = self.pather and self.pather.finder
  local edge = finder and finder.edges and finder.currentEdgeIndex
    and finder.edges[finder.currentEdgeIndex]

  local moved = prev and prev.pos and world.distance(here, prev.pos) or nil
  local planX = flightPlanX(finder, here[2])
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

  --  THE CHASSIS NUMBERS, ONCE PER FLIGHT. These are what the arc mover's
  --  controlParameters zeroing is trying to override, so a decay measured
  --  against them says whether the override reached the engine.
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

  --  TELL THE PORT WE ARE ACTUALLY UNDER WAY.
  --
  --  The port knows only two things about a task: that it dispatched one, and
  --  how it ended. Both crosshair colours it could derive from that -- yellow on
  --  dispatch, red on failure -- so a unit still searching for a route and a
  --  unit halfway there looked identical from outside. This is what green keys
  --  off.
  --
  --  MOVEMENT IS THE SIGNAL, NOT THE PATHER'S INTERNAL STATE. "Has a path" is
  --  genuinely hard to answer here -- PathFinder does not latch, a plan can span
  --  several vent legs, and routing flips true and false several times over one
  --  journey. Distance covered has none of that ambiguity: a unit that has moved
  --  is a unit that found a way.
  --
  --  UP HERE, ABOVE EVERY BRANCH, AND THAT IS THE WHOLE FIX. This used to live
  --  inside the trace block near the bottom of this function, which is reached
  --  only when the unit is on a direct approach and has not yet arrived. Three
  --  paths return before it:
  --
  --    the routing branch      probing exits -- correct to skip, nothing moves
  --    the vent-leg branch     WALKING TO A VENT MOUTH -- real, visible motion
  --                            that never counted, so the marker stayed yellow
  --                            through the approach, the hop, and every leg
  --                            after it
  --    the settle branch       a drop still falling -- correct to skip
  --
  --  The middle one is the bug Lofty saw. It is also the case the green marker
  --  exists for, since a unit that vanishes into a vent is precisely when a
  --  player wants to be told the network is still on it.
  --
  --  ONCE PER TASK. reportedMoving latches, so this costs one message per task
  --  and stops testing afterwards. Fire-and-forget on this side: the port either
  --  updates a cosmetic or it does not, and a lost message costs a colour rather
  --  than a decision.
  --
  --  NOT FOR A LEASH. A station-keeping task has no port to tell -- and nothing
  --  is owed a report for one either way.
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

  --  AHEAD OF THE ARC BLOCK, AND UNGATED ON EDGE ACTION. The handover tick of a
  --  walk-off is still on the Walk edge, so anything downstream of the arc
  --  block's `action == "Arc"` test cannot see the interval being measured.
  flightTrace(dt, stateData)

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
  --  APEX AND TOUCHDOWN, logged every flight.
  --
  --  Pairs with the ARCPLAN dump at takeoff: that says where the planner
  --  intended to go, this says where the unit actually went. One line each and
  --  the plan-versus-physics gap is a subtraction rather than an inference.
  --  Delete alongside ARCPLAN.
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

  --  THE ABOVE-ONLY TEST WAS THE HOLE, AND THE COMMENT ABOVE IT WAS ALREADY
  --  RIGHT: "Landed. Whatever is left of the arc is over, whether the plan
  --  agrees or not." The loop then did not do that -- it broke on the first
  --  waypoint at or below the unit, which is EVERY waypoint when the unit
  --  overshot and came down on top of something.
  --
  --  A waypoint below a grounded unit is not reachable by waiting. The unit is
  --  standing on the thing that is in the way. Falling and grounded are
  --  therefore different questions:
  --
  --    FALLING   only waypoints ABOVE are unreachable; the descending half is
  --              still ahead and must be kept
  --    GROUNDED  the flight is over; ALL of it is unreachable, in both
  --              directions
  --
  --  RISING IS EXCLUDED IN BOTH, AND THAT NOW INCLUDES RISING WHILE GROUNDED.
  --  There is one tick after takeoff where onGround is still true and the
  --  launch velocity is already applied -- measured at [3768,1010.8] with
  --  velocity [0,48.314] holding the first arc edge. Under the old predicate
  --  that tick qualified as GROUNDED and every waypoint of the ascending arc
  --  was above it, so the whole jump was one ordering accident away from being
  --  skipped at the moment it began. It survived only because the skip runs
  --  before moveJump advances onto the arc within the same tick. That is luck,
  --  not a design, and it is now an explicit test.
  local arcFinder = self.pather and self.pather.finder

  --  ONE PLACEMENT PER TICK, SHARED BY BOTH CALL SITES.
  --
  --  The arc-landing decision and the per-tick ground guard both call
  --  tryPlanDrop, and after an arc landing they run in the SAME tick -- the arc
  --  site drops, then the guard immediately re-reads a position that is already
  --  mid-placement and considers dropping again. Observed as a paired
  --  "dropped one platform" / "refused ... no platform above the floor to pass"
  --  on one timestamp, which only stayed harmless because the second call found
  --  nothing to pass. Two placements in one tick is exactly the multi-rung
  --  descent the one-per-call rule exists to prevent.
  local droppedThisTick = false
  local arcEdge = nil

  if arcFinder ~= nil and arcFinder.hasPath and arcFinder.edges ~= nil
     and arcFinder.currentEdgeIndex ~= nil then
    arcEdge = arcFinder.edges[arcFinder.currentEdgeIndex]
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
          stopReason = "edge " .. tostring(index) .. " is a " .. tostring(edge.action)
          break
        end

        if edge.target == nil or edge.target.position == nil then
          stopReason = "edge " .. tostring(index) .. " has no target position"
          break
        end

        local above = edge.target.position[2] > mcontroller.position()[2]

        --  FALLING keeps the descending half. GROUNDED keeps nothing.
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

      sb.logInfo("UNIT ARC skip done: mode %s, skipped %s, stopped because %s -- now on edge %s of %s at %s",
        arcMode, sb.printJson(skipped), stopReason,
        tostring(arcFinder.currentEdgeIndex),
        tostring(arcFinder.edges and #arcFinder.edges),
        sb.printJson(mcontroller.position()))

      --  WHAT IS LEFT OF THE PLAN WAS COMPUTED FOR A POSITION THE UNIT IS NOT
      --  IN, and only the grounded case can tell.
      --
      --  Skipping the dead arc is not on its own enough. The next edge is
      --  normally the Land that the arc was supposed to deliver the unit to,
      --  and moveLand accepts on HORIZONTAL distance alone -- so a unit four
      --  tiles above its landing, with x within a tile, advances straight past
      --  it and off the end of the path. PathFinder:update then returns false
      --  from currentEdgeIndex > #edges, which reads as a lost path rather than
      --  as the plan having been wrong.
      --
      --  Note this cannot produce a false arrival: arrival is decided by
      --  PathMover:move's own onGround/targetDistance test before edgeMove ever
      --  runs, not by the path running out. But a replan is both cheaper and
      --  truthful, and it is the only thing that can actually get the unit
      --  somewhere -- A* from where it is standing knows about the platform
      --  under its feet, which the dead plan does not.
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
          --  THE IMMEDIATE NEXT EDGE COMES FIRST, AND CLEARANCE CANNOT OVERRULE
          --  IT. A clear walk six edges away is worth nothing if the step in
          --  front of the unit is three tiles down.
          --
          --  This is also the answer to the churn worry that produced the
          --  clearance test: a replan is not a loop, because PathFinder:find
          --  starts every search from mcontroller.position(). A* cannot keep
          --  handing back a route for a surface the unit is not on -- the route
          --  always begins where the unit is. So refusing a plan costs one
          --  search and never repeats for the same reason.
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
          --  NO WALK EDGE NEAR ENOUGH TO TEST, and the next edge is reachable.
          --  Nothing to sweep and nothing to object to, so the plan stands.
          sb.logInfo("UNIT ARC landed on-plan at %s: next edge %s targets %s, %s tiles off in y, "
            .. "no Walk edge within %s ground-level edges to sweep -- keeping the plan",
            sb.printJson(mcontroller.position()),
            tostring(nextEdge.action), sb.printJson(nextTarget),
            sb.printJson(yGap), sb.printJson(PLAN_WALK_LOOKAHEAD))
        end
      end
    end
  else
    --  THE ARRIVAL BRAKE LATCH IS CLEARED SEPARATELY, AND THE NESTING IS THE
    --  WHOLE POINT.
    --
    --  IT USED TO SIT INSIDE `petportsLaunch ~= nil` AND THAT WAS A BUG WITH A
    --  BODY COUNT. The two flags have the same lifetime -- both live exactly as
    --  long as the arc -- but only one of them is only ever SET on a jump. The
    --  arrival brake fires on any arc, including a walk-off fall, which has no
    --  takeoff and therefore no launch record. So a fall that ended in the brake
    --  latched petportsLanding and then failed its own clear, because the guard
    --  above it asked about a record that was never written.
    --
    --  WHAT THAT COSTS, MEASURED 2026-09-01:
    --
    --      45.516  arrived at landing [2494,1164.8] (ahead -0.713623)   walk-off,
    --              no launch record, no "launch record cleared" line follows
    --      47.63   next flight, first tick the arc mover runs
    --              [2510.02,1161.97] vx 8.00 -> 3.07 -> 0.00, medium AIR
    --      47.96   grounded at [2510.02,1152.8], nine tiles of vertical drop,
    --              1.98 short of its Land, stalled and replanned
    --
    --  A LATCHED BRAKE IS INVISIBLE. It logs once when it fires and never again;
    --  the hold below it issues controlApproachXVelocity(0) silently on every
    --  airborne tick thereafter and RETURNS ABOVE THE FRICTION ZEROING. So the
    --  symptom is a unit that stops dead in mid-air on a later, unrelated
    --  flight, with nothing in the log connecting the two.
    --
    --  IT ALSO EXPLAINS TWO WRONG DIAGNOSES. The same collapse was attributed
    --  first to the planner-velocity steering in the airborne branch and then to
    --  liquid drag at a waterline; deleting the first changed nothing and the
    --  second was coincidence -- the brake bites on the first arc-mover tick of
    --  a flight, which on one route happened to be the tick the body touched
    --  water. Both readings were of one sample; the per-tick trace separated
    --  them in one run by showing an identical collapse in dry air.
    --
    --  UNCONDITIONAL, AND IDEMPOTENT. This branch runs on every tick the pather
    --  is not on an Arc -- most of a unit's life -- so clearing a flag that is
    --  already nil is the ordinary case and costs nothing. Gating it on anything
    --  is how it broke.
    if self.pather ~= nil and self.pather.petportsLanding ~= nil then
      sb.logInfo("UNIT ARCMOVER landing latch cleared at %s: the pather is on %s, not an Arc",
        sb.printJson(mcontroller.position()),
        tostring(arcEdge and arcEdge.action or "no edge"))

      self.pather.petportsLanding = nil
    end

    --  THE LAUNCH RECORD LIVES EXACTLY AS LONG AS THE ARC DOES.
    --
    --  IT IS DIAGNOSTIC NOW, NOT CONTROL. Nothing steers x during a flight any
    --  more -- see the airborne branch of petportsArcMover -- so no trajectory
    --  depends on this record. It is kept because the line below is the only
    --  place the log states what a flight ACTUALLY launched with, and that is
    --  precisely the quantity the new ballistic behaviour is trusted to preserve.
    --  Deleting the instrument in the same change that starts relying on what it
    --  measures is how a regression goes unnoticed.
    --
    --  Stating the lifetime as a per-tick state check rather than hooking each
    --  exit is deliberate: there are at least four ways off an arc -- the
    --  mover's grounded last-edge branch, its advance loop running past the last
    --  Arc, the skip loop stopping on a Land, and a path lost mid-flight -- and
    --  only the first ever cleared this.
    --
    --  ONE PLACE, ONE RULE: not on an Arc edge, no launch record. That covers
    --  every exit including ones not written yet.
    --
    --  A TAKEOFF TICK IS NOT AN EXIT. This block runs before edgeMove, so on the
    --  tick a jump launches the current edge is still the Jump and the record
    --  has not been written yet -- moveJump sets it and advances onto the first
    --  Arc later in the same tick. The clear below sees nothing to clear, which
    --  is correct, and the following tick reads an Arc.
    if self.pather ~= nil and self.pather.petportsLaunch ~= nil then
      sb.logInfo("UNIT ARCMOVER launch record cleared at %s: the pather is on %s, not an Arc "
        .. "-- the flight launched at vx %s",
        sb.printJson(mcontroller.position()),
        tostring(arcEdge and arcEdge.action or "no edge"),
        sb.printJson(self.pather.petportsLaunch.vx))

      self.pather.petportsLaunch = nil
    end
  end

  --  A GROUNDED WALK BELONGING TO A DIFFERENT SURFACE.
  --
  --  The arc check above only looks at the moment of touchdown. This is the
  --  same question asked every tick, and it exists because a wrong surface can
  --  also be inherited -- a plan kept by a tolerance that was too loose, or one
  --  whose descent stopped a platform early because the planner drew an Arc
  --  through a platform that the unit simply lands on.
  --
  --  Starbound has no slopes, so a Walk edge's target y IS the surface it was
  --  planned on, and for a unit standing on that surface it should read exactly
  --  the unit's own y. Anything else means the plan is describing somewhere the
  --  unit is not.
  --
  --  moveWalk cannot notice. It steers on `edgeDelta[1]` -- the edge's own x
  --  extent -- and never looks at y at all, so it walks the plan out at full
  --  speed on whatever surface the unit happens to be on. MEASURED, on one-tile
  --  platform spacing:
  --
  --      pre-move at [3758,1027.8]:   Walk edge 4 of 74  dst [3757,1026.8]
  --      pre-move at [3757.62,1027.8] Walk edge 4        dst [3757,1026.8]
  --      pre-move at [3756.7,1027.8]  Walk edge 5        dst [3756,1026.8]
  --      pre-move at [3756.7,1027.8]  Walk edge 5        velocity [0,-1.537]
  --      ... frozen, eight ticks
  --
  --  One tile of y error, and the top of a 1.6-tall box went into dirt that the
  --  corridor cleared for a body one tile lower. Nothing named it: vanilla's
  --  stuckTimer reset the path after half a second of no edge change, silently,
  --  and A* returned the identical plan.
  if arcFinder ~= nil and arcFinder.hasPath and mcontroller.onGround()
     and not stateData.routing then
    local edgeNow = arcFinder.edges and arcFinder.currentEdgeIndex
      and arcFinder.edges[arcFinder.currentEdgeIndex]

    if edgeNow ~= nil and (edgeNow.action == "Walk" or edgeNow.action == "Land") then
      --  THE SAME RULE, ASKED EVERY TICK RATHER THAN ONLY AT TOUCHDOWN.
      --
      --  A plan whose current ground edge sits below the unit is a plan for a
      --  storey the unit is not on, however it got that way -- landed off it,
      --  inherited it, or walked onto it. One platform down is the answer in
      --  all three cases, and it is cheaper and more certain than a search.
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

      --  Clearance is still the backstop: right height and still will not fit
      --  is a different failure, and only a replan answers it.
      if not dropped and edgeNow.action == "Walk" then
        local blocked, walkIndex, walkEdge, sweep = planWalkBlocked(arcFinder)

        if blocked == true then
          sb.logInfo("UNIT SURFACE blocked: standing at %s, Walk edge %s of %s to %s does not "
            .. "clear this body at this height (sweep %s, box %s) -- replanning",
            sb.printJson(mcontroller.position()),
            tostring(walkIndex), tostring(#arcFinder.edges),
            sb.printJson(walkEdge.target.position),
            sb.printJson(sweep), sb.printJson(mcontroller.boundBox()))

          arcFinder:reset()
          stateData.stuckAnchor = nil
          stateData.airborneEdgeStall = 0
        end
      end
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

  --  PRE-FLIGHT: BEFORE ANYTHING ASKS THE PATHFINDER A QUESTION.
  --
  --  Placed above the routing branch rather than beside approachPoint, because
  --  tryVentRoute probes with real A* searches and those begin from
  --  mcontroller.position() exactly as the direct walk does. A bad origin
  --  poisons both, and the probe results are CACHED -- a route refused from a
  --  node in mid air would be remembered as terrain that does not work. Gating
  --  here covers every consumer with one call.
  --
  --  NOT ONCE ARRIVED. An arrived unit is standing where its work happens and
  --  is not going to ask for a plan, so a nudge there is pure interference --
  --  it would walk a waterer off its own soil tile. The water sweep re-earns
  --  arrival per tile, so the next leg is covered again.
  if not stateData.arrived and nudgeOrigin(stateData, dt) then
    petports_think("pathing")
    return false
  end

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
  --  `withdraw` JOINED THIS LIST 2026-08-31, AND FOR THE SAME REASON `return`
  --  DID. Every other type here dispatches a RAW target position; the ones NOT
  --  here -- deposit, upcycle, tidy, drain, fuel, compact -- carry a standing
  --  point the port already resolved, and re-resolving one of those would run
  --  the search against an answer that is already correct.
  --
  --  The four withdraw generators dispatch `world.entityPosition(containerId)`,
  --  the container's ORIGIN, and that origin sits in the flooded half of a
  --  half-submerged crate. So the flyer was told to approach a position it
  --  cannot occupy, approachPoint never arrived, and the progress watchdog
  --  struck it: nine `fetchwater` failures reading `moved 0 in 10s heading for
  --  [2553,1147]`, which is the RAW origin and not any resolved point. The
  --  swimmer serviced the same crate seven times, because for it that tile is
  --  a legal place to be.
  --
  --  THE VOUCH IS WHAT MAKES THIS WORK AND IS NOT SUFFICIENT ON ITS OWN. Without
  --  `task.mediumVerified` the resolve here returns nil for a straddling crate;
  --  without this list entry the resolve happens and its answer is discarded.
  --  Both were needed.
  if task.type == "return" then
    approachTo = approachTargetFor(stateData, target) or target
  elseif task.type == "collect" or task.type == "harvest"
     or task.type == "replant" or task.type == "water"
     or task.type == "animal" or task.type == "medic"
     or task.type == "withdraw" then
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

      --  The under-way report used to live here and does not any more -- it is
      --  pumped from the top of update() instead, above every branch that
      --  returns before this line. movedTotal stays: it is accumulated PATH
      --  LENGTH and it still owns the "never moved" versus "could not reach"
      --  split in the approach-timeout report below, which net displacement
      --  cannot answer -- a unit that walked out and back has covered ground
      --  and is a different failure from one that never started.

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

  if task.type == "medic" then
    --  THE PATIENT IS RE-CHECKED ON ARRIVAL, AND THAT IS THE POINT OF CARRYING
    --  AN ENTITY ID RATHER THAN A POSITION.
    --
    --  Every other task targets something that cannot heal itself. A patient
    --  can: by a bandage, by another medic, by regeneration they already had,
    --  or by simply having been at 99% when the port looked. Spending a medical
    --  good on someone who recovered while the unit walked is the one waste this
    --  task can actually prevent, so it checks twice.
    if task.patient == nil or not world.entityExists(task.patient) then
      report(stateData, "done", string.format(
        "patient %s is gone -- no dose spent", sb.printJson(task.patient)))
      return true
    end

    --  DONE, NOT FAILED, WHEN THE PATIENT RECOVERED. A failure feeds the backoff
    --  ladder and would penalise this port for an outcome that is GOOD: someone
    --  got better. The distinction matters because the ladder is what protects
    --  the network from a target it genuinely cannot service.
    local health = world.entityHealth(task.patient)

    if type(health) ~= "table" or health[2] == nil or health[2] <= 0 then
      report(stateData, "done", string.format(
        "patient %s reports no health -- no dose spent", sb.printJson(task.patient)))
      return true
    end

    if health[1] >= health[2] then
      report(stateData, "done", string.format(
        "patient %s recovered on the way (%s/%s) -- no dose spent",
        sb.printJson(task.patient), tostring(health[1]), tostring(health[2])))
      return true
    end

    local here = mcontroller.position()
    local there = world.entityPosition(task.patient)
    local gap = world.magnitude(here, there)

    --  FAILED, NOT DONE, WHEN OUT OF REACH -- this one IS a failure, because the
    --  patient is still hurt and nothing was delivered. The backoff ladder
    --  should see it, and re-dispatch is the correct response.
    if gap > MEDIC_REACH then
      report(stateData, "failed", string.format(
        "arrived but patient %s is %s away (reach %s) -- likely moved while walking",
        sb.printJson(task.patient), sb.printJson(gap), sb.printJson(MEDIC_REACH)))
      return true
    end

    --  CAST AT THE PATIENT, NOT AT THE UNIT. The burst is an area, but centring
    --  it on the patient is what makes MEDIC_REACH and the poly half-width
    --  independent -- otherwise the effective coverage is the difference between
    --  them and shrinks every time either is tuned.
    local ok, err = pcall(world.spawnProjectile,
      task.projectile or "petports_medicburst", there, entity.id(), {0, 0}, false, {})

    if not ok then
      report(stateData, "failed", string.format(
        "spawnProjectile failed at patient %s: %s",
        sb.printJson(task.patient), tostring(err)))
      return true
    end

    sb.logInfo("UNIT medic DOSE patient %s (%s) at %s: health %s/%s, gap %s, effect %s for %ss",
      sb.printJson(task.patient), tostring(task.patientClass), sb.printJson(there),
      tostring(health[1]), tostring(health[2]), sb.printJson(gap),
      tostring(task.effect), tostring(task.duration))

    --  `dosed` IS WHAT THE PORT CHARGES ON, exactly as `watered` is. The port
    --  spends one medicalgoods per dose ACTUALLY delivered, so every early
    --  return above costs the player nothing.
    --  ON THE TASK, NOT IN THE `cargo` ARGUMENT. report()'s fourth parameter is
    --  cargo specifically; counters ride as task fields and are lifted into the
    --  message, the way task.watered is.
    task.dosed = 1

    report(stateData, "done", string.format(
      "dosed patient %s at %s/%s health", sb.printJson(task.patient),
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
