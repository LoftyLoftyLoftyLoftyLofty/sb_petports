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
--  A POSITION A FLYING UNIT CAN HOLD, near `position`. nil for a ground unit.
--
--  THE FLYER'S ANSWER TO THE SAME QUESTION petports_standingPointNear ASKS, and
--  it is a different question with a different answer: a ground unit wants the
--  floor beneath the target, a flyer wants the TARGET'S OWN TILE. Resolving a
--  flyer's targets to ground would make it a walking unit that happens to
--  ignore terrain -- and would skip every target with no floor under it, which
--  is a ceiling-mounted crate, a drop over a chasm, or a floating platform.
--
--  RETURNS nil FOR A GROUND UNIT, DELIBERATELY, so both call sites can be
--  written as "try the flyer answer, fall through to the ground one" without
--  either of them testing gravity themselves.
--
--  THE FIT TEST IS WHAT MAKES THE FALLBACK CORRECT. A target embedded in solid
--  rock -- or a petport mounted flush against a wall, which is the leash target
--  every idle tick -- has a tile centre the body cannot occupy. Without the
--  test the unit would approach forever and never close inside its arrival
--  radius, and because a tethered leash task never completes, that is a
--  permanent soft-lock on the idle path rather than one failed task.
--
--  COLLISION SET MATCHES VANILLA'S BODY TEST. validStandingPosition checks the
--  bound region against {"Null", "Block"} and nothing else -- not Dynamic, not
--  Platform. Matching it means a flyer will hold station inside a crate's own
--  footprint or under a platform, exactly as a ground unit is allowed to stand
--  in those places. Refusing Dynamic here would be stricter than the engine and
--  would skip the ceiling-crate case this was built for.
--
--  Searched as Chebyshev rings so the nearest ring wins; order WITHIN a ring is
--  arbitrary and not distance-sorted. Fine at radius 4 (81 candidates worst
--  case, and offset 0 answers almost every real call).
--------------------------------------------------------------------------------
--  LOCOMOTION MEDIUM
--------------------------------------------------------------------------------
--
--  A chassis declares which MEDIA it may occupy, and every position and every
--  path edge is tested against that. Two flags, one predicate:
--
--      petports_canFly    may occupy air
--      petports_canSwim   may occupy liquid
--
--  Both true is an amphibious flyer. canFly only is the ordinary flyer. canSwim
--  only is the aquatic unit. BOTH FALSE IS A BRICKED PET AND THAT IS ALLOWED --
--  a modder who configures a chassis that way did it deliberately, and adding a
--  guard would mean silently overriding an author's stated intent to protect
--  them from a mistake they had to go out of their way to make.
--
--  DECLARED ON THE CHASSIS, NOT THE UNIT. One visual identity owns one
--  behavioural parameter set, so these live in the monstertype and are read
--  through config.getParameter -- which spawn parameters also satisfy, so a
--  future item-level override needs no change here.
--
--  WHY THIS IS NOT gravityEnabled
--
--  An authentic fish keeps gravity ON and floats on liquidBuoyancy. It also
--  CANNOT PATHFIND, because PathFinder:canPathfind is
--
--      mcontroller.onGround() or not mcontroller.baseParameters().gravityEnabled
--
--  and a gravity-enabled actor suspended in water is not onGround, so find()
--  never starts a search. Vanilla's own fish work around this by not
--  pathfinding at all -- swimmingMonster.lua steers on whisker sensors and
--  reverses when it bumps something, which is fine for ambient wildlife and
--  useless for a unit that must reach a named crate two rooms away.
--
--  So an aquatic unit is a FLYER WITH A MEDIUM CONSTRAINT. controlFly is the
--  swim primitive too -- vanilla's fish issue exactly that call -- and liquid
--  only swaps which parameters govern it: liquidForce and liquidFriction in
--  place of airForce and airFriction, with flySpeed shared.

--  SUBMERGED MEANS 0.9 FILL, NOT 0.1.
--
--  0.1 is vanilla's threshold in findGroundPosition and it is there to keep
--  NPCs out of shallow lava, where a splash is enough to matter. Swimming is a
--  different question: a tile that is one tenth full is not water to move
--  through. 0.9 rather than 1.0 leaves margin for a player measuring the top
--  row of a hand-dug pool, where fill settles slightly under full.
--
--  CONSEQUENCE, AND IT IS A DESIGN CONSTRAINT WORTH STATING: the body is 1.6
--  tall, so it always overlaps at least two tile rows. A POOL THEREFORE NEEDS
--  TWO FULL ROWS OF DEPTH AT MINIMUM, and at exactly two the only legal body
--  centre is the single point on the row boundary -- reachable, but only via a
--  sub-tile nudge at the far edge of its range. Three rows gives a full tile of
--  window and is the comfortable number.
local PETPORTS_SUBMERGED_FILL = 0.9

--  Is every tile row the body would overlap at `position` submerged?
--
--  THE BODY BOX, NOT A POINT. A point test passes with the unit's head out of
--  the water, which is the same class of mistake as resolving a hover point on
--  the far side of a floor -- geometrically near, physically wrong.
--
--  Rows only. Liquid fills by row, and a column-wise test would answer a
--  question liquid does not have.
function petports_submergedAt(position, bounds)
  if position == nil then return false end
  bounds = bounds or mcontroller.boundBox()

  local x = position[1]
  local bottom = math.floor(position[2] + bounds[2])
  local top = math.ceil(position[2] + bounds[4]) - 1

  for row = bottom, top do
    local level = world.liquidAt({ x, row + 0.5 })

    --  world.liquidAt returns {liquidId, level} or nil. A nil is air, which is
    --  a definite answer and not a missing one.
    if level == nil or (level[2] or 0) < PETPORTS_SUBMERGED_FILL then
      return false
    end
  end

  return true
end

--  SHOULD THIS CHASSIS REFUSE TO STAND IN LIQUID?
--
--  True for an ordinary ground pet, false for an amphibious one. Free movers
--  never consult it -- their medium is governed by petports_canFly and
--  petports_canSwim, which is a permission question rather than an avoidance
--  one.
--
--  THIS EXISTS BECAUSE VANILLA'S IS A BUG, NOT A SETTING. groundPet.lua does
--
--      findGroundPosition(targetPosition, -20, 1, util.toDirection(-toTarget[1]))
--
--  and the fourth parameter is avoidLiquid. It is being handed a DIRECTION --
--  1 or -1, and BOTH ARE TRUTHY IN LUA -- so vanilla always avoids liquid here,
--  by accident, with no way to ask for anything else.
--
--  MEASURED COST: a ground unit was dispatched to a submerged upcycler. Our own
--  standableNear resolved the spot happily (it passes avoidLiquid false), then
--  vanilla's approachPoint refused the same point one line later, left
--  self.approachPosition nil, and the unit stood still for 10.7 seconds until
--  two progress strikes failed the task. It then churned deposit/drain at a
--  reachable crate until the port offered the submerged machine again.
--
--  Two resolvers aiming at the same point under different rules is exactly the
--  router-versus-walker split the handoff records. THEY MUST AGREE, and this
--  flag is what they agree on.
function petports_avoidLiquid()
  if petports_freeMover() then return false end
  return config.getParameter("petports_avoidLiquid", true)
end

--  Does this chassis move freely -- fly, swim, or both -- rather than walk?
--
--  THE ONE THING THAT DECIDES WHO OWNS A POSITION ANSWER. A free-moving chassis
--  resolves its own destinations through petports_flyPointNear and NEVER falls
--  back to the ground search, because for it a nil is a REFUSAL and not an
--  absence. See the note on that fall-through in petports_standingPointNear.
function petports_freeMover()
  return not mcontroller.baseParameters().gravityEnabled
end

--  Is the single tile containing `position` submerged?
--
--  A POINT, NOT THE BODY BOX, and the distinction is the whole reason this
--  exists separately. petports_submergedAt asks "may my body occupy this", which
--  is the right question about a standing spot and the WRONG one about a target:
--  a crate resting just under the surface is submerged while a body centred on
--  it would straddle the waterline, so a body test would refuse work the unit
--  can plainly do.
function petports_submergedPoint(position)
  if position == nil then return false end

  local level = world.liquidAt(position)
  return level ~= nil and (level[2] or 0) >= PETPORTS_SUBMERGED_FILL
end

--  Chassis capability. Cached per unit: these are monstertype parameters and
--  cannot change for the life of an entity, and this is called per candidate
--  position inside a search that already runs eighty-one of them.
function petports_media()
  if self.petportsMedia == nil then
    self.petportsMedia = {
      fly = config.getParameter("petports_canFly", true),
      swim = config.getParameter("petports_canSwim", false)
    }

    sb.logInfo("UNIT locomotion media: canFly %s, canSwim %s%s",
      tostring(self.petportsMedia.fly), tostring(self.petportsMedia.swim),
      (not self.petportsMedia.fly and not self.petportsMedia.swim)
        and " -- NEITHER, this chassis can legally occupy nothing and will refuse every target"
        or "")
  end

  return self.petportsMedia
end

--  May this chassis occupy `position`? The single question every destination
--  and every path sample is asked.
--
--  Returns the verdict and a reason, because "the unit refuses to go anywhere"
--  is otherwise indistinguishable from "the unit cannot path there".
--  CAN THIS CHASSIS LIVE AT A PORT THAT OFFERS THESE MEDIA?
--
--  Called BY THE PORT, which measures its own footprint and passes what it
--  found. The port cannot answer this itself: capability is a monstertype
--  parameter and only the unit has read it.
--
--  `wet` and `dry` are "at least one tile of my footprint is like this", NOT
--  "all of them". A port half in the water offers BOTH, and that is the right
--  answer for both chassis -- a swimmer can sit in the flooded half, a flyer in
--  the dry half, and neither has to be told which.
--
--  A WALKER IS A DIFFERENT QUESTION AND MUST NOT BE ASKED THE FLYER ONE. Its
--  media flags default to canFly true / canSwim false, which would read as "air
--  only" and is meaningless -- a ground unit does not fly. What decides for a
--  walker is whether it will stand in liquid at all, which is petports_avoidLiquid.
--
--  RETURNS ONE TABLE, NOT TWO VALUES. Whether world.callScriptedEntity
--  forwards multiple return values across the boundary is not something this
--  mod has measured, and the handoff already records that it returns nil
--  SILENTLY for a function that does not exist -- so a marshalling difference
--  here would look like a unit that simply never answers. A table is
--  unambiguous and costs nothing.
--
--  The reason travels with it because "the port despawned my pet" has to say
--  why in one line, or it reads as the mod losing units.
function petports_canInhabit(wet, dry)
  if petports_freeMover() then
    local media = petports_media()

    if media.swim and wet then
      return { ok = true, reason = "port is submerged and this chassis swims" }
    end
    if media.fly and dry then
      return { ok = true, reason = "port is in air and this chassis flies" }
    end

    if wet and not dry then
      return { ok = false, reason = "the port is fully submerged and this chassis cannot swim" }
    end
    if dry and not wet then
      return { ok = false, reason = "the port is out of the water and this chassis cannot leave it" }
    end

    return { ok = false, reason = "this chassis can occupy neither medium the port offers" }
  end

  if not petports_avoidLiquid() then
    return { ok = true, reason = "amphibious walker, any medium" }
  end

  if dry then return { ok = true, reason = "port has dry footing" } end
  return { ok = false, reason = "the port is fully submerged and this walker will not stand in liquid" }
end

--  MAY THIS CHASSIS WORK ON A TARGET SITTING AT `position`?
--
--  A DIFFERENT QUESTION FROM "may I stand here", AND OMITTING IT COST A REAL
--  BUG. Measured 2026-08-27: an aquatic unit was dispatched to drain a crate at
--  [2506,1152], which sits in AIR above a waterline at about 1148.5. The
--  position search did exactly what it was told -- found the nearest spot the
--  body could occupy in an allowed medium -- and returned [2506.5,1148.5], three
--  and a half tiles BELOW the crate at the surface. The unit flew there and
--  REPORTED THE DRAIN DONE without ever reaching it.
--
--  Line of sight cannot catch this. Straight up through water into air is
--  clear; the point is legal, reachable, sighted and useless.
--
--  So the target's OWN medium is a separate precondition. An aquatic unit does
--  not service a crate in air by hovering under it, any more than it waters a
--  dry field by floating beside one.
--
--  CONSEQUENCE WORTH SAYING OUT LOUD: an aquatic chassis can never take a
--  watering task, because dry tilled soil is by definition not submerged. That
--  is correct rather than a limitation -- a submerged farm does not go dry --
--  but it will read as "the unit ignores my farm" to anyone who has not been
--  told, and it belongs in the aquatic unit's item description.
function petports_targetAllowed(position)
  local media = petports_media()

  if petports_submergedPoint(position) then
    if media.swim then return true, "target is submerged" end
    return false, "target is submerged and this chassis cannot swim"
  end

  if media.fly then return true, "target is in air" end
  return false, "target is not submerged and this chassis cannot leave the water"
end

function petports_mediumAllows(position, bounds)
  --  MEDIUM PERMISSION IS A FREE-MOVER CONCEPT ONLY.
  --
  --  A walking chassis has no medium PERMISSION -- its medium is decided by
  --  physics. It sinks, it wades, it swims when the engine says so, and none of
  --  that is ours to allow or refuse. Whether it should enter water at all is
  --  the avoidLiquid question, which lives in the approach shadow and is a
  --  different question with a different answer.
  --
  --  THIS IS NOT A TIDINESS EDIT. Without it, a ground unit that string-pulls
  --  through water gets every submerged sample of flyPathClear refused, because
  --  the drone declares no flags and therefore defaults to canSwim false. The
  --  shortcut silently collapses to "aim at the next waypoint", the mover
  --  appears bound and does nothing, and the rubberbanding it was added to fix
  --  carries on exactly as before with no line in the log to say why.
  if not petports_freeMover() then return true, "walking chassis, medium is physics" end

  local media = petports_media()

  if petports_submergedAt(position, bounds) then
    if media.swim then return true, "submerged" end
    return false, "submerged and this chassis cannot swim"
  end

  if media.fly then return true, "air" end
  return false, "not submerged and this chassis cannot fly"
end

--  WHERE A FLYING UNIT SHOULD SIT TO WORK ON SOMETHING AT `position`.
--
--  Three defects were measured in game on 2026-08-27 and all three are fixed
--  here. The measurements are kept because each one killed a plausible theory:
--
--  1. TILE-CENTRE GRANULARITY CANNOT PLACE THIS BODY IN A 2-HIGH CORRIDOR.
--     The body is 1.6 tall, so an open run of rows [1023,1025) admits centres
--     in 1023.8..1024.2 -- a window 0.4 wide -- and the only positions ever
--     offered were floor(y) + 0.5, which is 1023.5 or 1024.5. Both miss.
--     Measured: "open 1023..1024 (2 tiles), centre window 1023.8..1024.2 --
--     tile centres inside it: NONE". The unit fits the corridor; the resolver
--     could not express a position inside it.
--
--  2. NO LINE OF SIGHT WAS REQUIRED, so having failed near the item the search
--     kept going until it found open air on the FAR SIDE OF THE FLOOR and
--     accepted that. Measured: item at [3763.38,1023.62] resolved to
--     [3759.5,1019.5], 5.66 tiles away, sight blocked by terrain. The unit flew
--     under the floor and took the item through it, because world.takeItemDrop
--     has no occlusion test of its own.
--
--  3. THE RING WAS SEARCHED DOWN-AND-LEFT FIRST, and within a ring the order
--     was arbitrary rather than by distance. The disaster candidate above was
--     d(-4,-4), the FIRST of its ring -- the bias did not merely exist, it
--     landed on the one direction a flyer cannot recover from. A second pickup
--     took a point 3.53 tiles out when a legal one sat at 0.45.
--
--  RETURNS nil FOR A GROUND UNIT, DELIBERATELY, so both call sites read as "try
--  the flyer answer, fall through to the ground one" without testing gravity.
--
--  FAILS CLOSED, AND THAT IS A DELIBERATE BEHAVIOUR CHANGE. nil now means the
--  port SKIPS that target and a task-side resolve FAILS the task after
--  SETTLE_GRACE. Previously a point behind a wall was always found and the work
--  went ahead through terrain. Declining work the unit cannot legitimately
--  reach is the correct answer, but it is a new way for a target to go
--  unserviced -- if something stops being dispatched, this is the first
--  suspect, and the debug block below names the reason per candidate.

--  Sub-tile search. RANGE is half a tile because beyond that the next tile
--  centre is nearer and already its own candidate. STEP is 0.1 because the
--  window it hunts is 0.4 wide vertically -- and measured horizontally at
--  -0.3 on one pickup, which 0.2 steps would have stepped over.
local FLY_NUDGE_STEP = 0.1
local FLY_NUDGE_RANGE = 0.5

--  Nudge only near the target. A sub-tile correction three tiles away is not a
--  fix for anything; if nothing close works, declining is the answer.
local FLY_NUDGE_MAX_RING = 2

--  Ceiling on sub-tile tests across one whole resolve. Measured cost of a full
--  50-candidate resolve WITH nudging was 10ms, once per task, so this only
--  bounds the pathological case. Beyond it, tiles are tested at their centres.
local FLY_NUDGE_BUDGET = 1500

--  Platform and Dynamic are excluded from BOTH tests on purpose. A flyer passes
--  through platforms, and A* routes through doors, so treating either as
--  occlusion would refuse work the unit can genuinely do.
local FLY_TILE_SET = { "Null", "Block" }

--  Set false once the flyer is trusted. Verified twice in game with it on, and
--  it is the only thing that explains a target going unserviced.
local FLY_POINT_DEBUG = true

--  How far to walk the open run when reporting spans. Diagnostic only.
local FLY_SPAN_PROBE = 6

--  Does the body fit centred exactly here? Everything is built out of this one
--  test so the search and the diagnostics cannot disagree -- an earlier probe
--  used its own narrower rect and reported positions as free that the very next
--  line rejected.
local function flyBodyFits(x, y, bounds)
  return not world.rectTileCollision({
    x + bounds[1], y + bounds[2],
    x + bounds[3], y + bounds[4]
  }, FLY_TILE_SET)
end

--  Fits AND is in a medium this chassis may occupy. Both conditions travel
--  together everywhere, because a position that is geometrically free but in
--  the wrong medium is exactly as unusable as one inside a wall -- and keeping
--  them in one function is what stops a future caller checking only the half it
--  remembered.
local function flyBodyUsable(x, y, bounds)
  if not flyBodyFits(x, y, bounds) then return false, "body does not fit" end

  local ok, why = petports_mediumAllows({ x, y }, bounds)
  if not ok then return false, why end

  return true
end

--  Is `target` visible from `point`, i.e. are they on the same side of the
--  terrain? A ray, not a sweep: this asks whether the unit is in the right
--  PLACE, while getting there is the pather's problem and has its own body
--  sweep in petports_flyapproach.lua.
local function flySighted(point, target)
  return not world.lineTileCollision(point, target, FLY_TILE_SET)
end

--  Sub-tile offsets ordered nearest-first, built once. (0,0) sorts first, so
--  the plain tile-centre test is the first thing tried and open ground still
--  answers on one collision test.
local flyNudgeOffsets = nil

local function nudgeOffsets()
  if flyNudgeOffsets ~= nil then return flyNudgeOffsets end

  local list = {}
  local steps = math.floor(FLY_NUDGE_RANGE / FLY_NUDGE_STEP)

  for ix = -steps, steps do
    for iy = -steps, steps do
      local ox = ix * FLY_NUDGE_STEP
      local oy = iy * FLY_NUDGE_STEP
      table.insert(list, { ox, oy, math.sqrt(ox * ox + oy * oy) })
    end
  end

  table.sort(list, function(a, b) return a[3] < b[3] end)
  flyNudgeOffsets = list
  return list
end

--  Nearest sub-tile position around a tile centre where the body BOTH fits and
--  can see the target. Both conditions together, because the first fitting
--  offset is not necessarily a sighted one and settling for it would reopen
--  defect 2 at sub-tile scale.
local function nudgeProbe(cx, cy, bounds, target, budget)
  local offsets = nudgeOffsets()
  local spent = 0

  for _, offset in ipairs(offsets) do
    if spent >= budget then return nil, spent end
    spent = spent + 1

    local x = cx + offset[1]
    local y = cy + offset[2]

    if flyBodyUsable(x, y, bounds) then
      local point = { x, y }
      if flySighted(point, target) then return point, spent, offset[3] end
    end
  end

  return nil, spent
end

--  Open run at the target column and row, measured with the REAL body box.
--
--  Each axis is measured with the other held at the tile centre, so these are
--  slices and not a free-space map. Stated because the first version of this
--  probe used a fixed 0.8-wide column against a 1.6-wide body, reported centres
--  as available that the body test rejected one line later, and was one line
--  away from sending a whole session after the wrong axis.
local function logFlySpan(position, bounds)
  local width = bounds[3] - bounds[1]
  local height = bounds[4] - bounds[2]

  local x = math.floor(position[1]) + 0.5
  local y = math.floor(position[2]) + 0.5
  local row = math.floor(position[2])
  local col = math.floor(position[1])

  local function rowOpen(r)
    return not world.rectTileCollision(
      { x + bounds[1], r + 0.05, x + bounds[3], r + 0.95 }, FLY_TILE_SET)
  end

  local function colOpen(c)
    return not world.rectTileCollision(
      { c + 0.05, y + bounds[2], c + 0.95, y + bounds[4] }, FLY_TILE_SET)
  end

  local function report(axis, here, openHere, lowIndex, highIndex, size)
    if not openHere then
      sb.logInfo("UNIT flypoint span %s at %s: the target's own %s %s is already blocked "
        .. "for this body at the tile centre -- only a nudge can help on this axis",
        axis, sb.printJson(position), axis, sb.printJson(here))
      return
    end

    local low = lowIndex + size / 2
    local high = (highIndex + 1) - size / 2

    local hits = {}
    for i = lowIndex, highIndex do
      if (i + 0.5) >= low and (i + 0.5) <= high then table.insert(hits, i + 0.5) end
    end

    sb.logInfo("UNIT flypoint span %s at %s: open %s..%s (%s tiles), body %s %s, "
      .. "centre window %s..%s%s -- tile centres inside it: %s",
      axis, sb.printJson(position),
      sb.printJson(lowIndex), sb.printJson(highIndex),
      sb.printJson((highIndex + 1) - lowIndex),
      sb.printJson(size), (axis == "Y") and "tall" or "wide",
      sb.printJson(low), sb.printJson(high),
      (high < low) and " (EMPTY -- body does not fit this run at all)" or "",
      (#hits == 0) and "NONE, so no tile centre can ever be chosen here" or sb.printJson(hits))
  end

  local openRow = rowOpen(row)
  local bottom, top = row, row
  if openRow then
    for _ = 1, FLY_SPAN_PROBE do
      if not rowOpen(bottom - 1) then break end
      bottom = bottom - 1
    end
    for _ = 1, FLY_SPAN_PROBE do
      if not rowOpen(top + 1) then break end
      top = top + 1
    end
  end
  report("Y", row, openRow, bottom, top, height)

  local openCol = colOpen(col)
  local left, right = col, col
  if openCol then
    for _ = 1, FLY_SPAN_PROBE do
      if not colOpen(left - 1) then break end
      left = left - 1
    end
    for _ = 1, FLY_SPAN_PROBE do
      if not colOpen(right + 1) then break end
      right = right + 1
    end
  end
  report("X", col, openCol, left, right, width)
end

function petports_flyPointNear(position, radius)
  if position == nil then return nil end
  if mcontroller.baseParameters().gravityEnabled then return nil end

  radius = radius or 4

  local bounds = mcontroller.boundBox()
  local originX = math.floor(position[1]) + 0.5
  local originY = math.floor(position[2]) + 0.5

  --  THE TARGET'S OWN MEDIUM, BEFORE ANY SEARCHING. Refusing here rather than
  --  inside the loop is not just an optimisation: the loop's job is to find the
  --  nearest usable spot, and for an out-of-medium target every answer it can
  --  give is wrong. Letting it run produced a unit that hovered under a crate
  --  it could not reach and reported the work done.
  local targetOk, targetWhy = petports_targetAllowed(position)

  if not targetOk then
    if FLY_POINT_DEBUG then
      sb.logInfo("UNIT flypoint DECLINED %s outright: %s -- no position near it can help, "
        .. "so this target is not workable by this chassis",
        sb.printJson(position), tostring(targetWhy))
    end

    return nil
  end

  if FLY_POINT_DEBUG then
    sb.logInfo("UNIT flypoint SEARCH for %s (%s): origin tile centre %s, radius %s, boundBox %s",
      sb.printJson(position), tostring(targetWhy), sb.printJson({ originX, originY }),
      sb.printJson(radius), sb.printJson(bounds))
    logFlySpan(position, bounds)
  end

  --  ORDERED BY TRUE DISTANCE, NOT BY RING THEN dx THEN dy.
  --
  --  The old order walked Chebyshev rings and, within a ring, dx outer and dy
  --  inner from -offset -- so the first candidate of every ring was
  --  down-and-left, and everything else in that ring lost to it regardless of
  --  how much further away it was. Same candidate SET as before; only the order
  --  changes, and the order is what decides the answer in a first-fit search.
  local tiles = {}
  for dx = -radius, radius do
    for dy = -radius, radius do
      local x = originX + dx
      local y = originY + dy
      table.insert(tiles, {
        x, y,
        world.magnitude({ x, y }, position),
        math.max(math.abs(dx), math.abs(dy))
      })
    end
  end
  table.sort(tiles, function(a, b) return a[3] < b[3] end)

  local budget = FLY_NUDGE_BUDGET
  local examined = 0

  for _, tile in ipairs(tiles) do
    local cx, cy, ring = tile[1], tile[2], tile[4]
    local point, offset, reason = nil, nil, nil

    if ring <= FLY_NUDGE_MAX_RING and budget > 0 then
      local spent
      point, spent, offset = nudgeProbe(cx, cy, bounds, position, budget)
      budget = budget - (spent or 0)
      if point == nil then
        --  Name the medium when it is the medium, so "refuses everything" and
        --  "cannot path there" never look alike in the log.
        local _, why = petports_mediumAllows({ cx, cy }, bounds)
        reason = "no usable, sighted offset within " .. tostring(FLY_NUDGE_RANGE)
          .. " (tile centre: " .. tostring(why) .. ")"
      end

    --  Beyond the nudge rings, or out of budget: the tile centre only, and it
    --  still has to see the target.
    else
      local usable, why = flyBodyUsable(cx, cy, bounds)

      if not usable then
        reason = why
      elseif flySighted({ cx, cy }, position) then
        point, offset = { cx, cy }, 0
      else
        reason = "fits but cannot see the target"
      end
    end

    examined = examined + 1

    if point ~= nil then
      if FLY_POINT_DEBUG then
        sb.logInfo("UNIT flypoint ACCEPTED %s for %s after %s tile(s): dist %s, "
          .. "sub-tile offset %s, ring %s, %s nudge test(s) left",
          sb.printJson(point), sb.printJson(position), sb.printJson(examined),
          sb.printJson(world.magnitude(point, position)),
          sb.printJson(offset), sb.printJson(ring), sb.printJson(budget))
      end

      return point
    end

    if FLY_POINT_DEBUG then
      sb.logInfo("UNIT flypoint  #%s tile %s ring %s dist %s: %s",
        sb.printJson(examined), sb.printJson({ cx, cy }), sb.printJson(ring),
        sb.printJson(tile[3]), tostring(reason))
    end
  end

  if FLY_POINT_DEBUG then
    sb.logInfo("UNIT flypoint NO POINT for %s after %s tile(s) out to radius %s -- "
      .. "nothing within reach fits this body, sits in a medium it may occupy, and can "
      .. "see the target, so this target will be DECLINED (media: canFly %s canSwim %s)",
      sb.printJson(position), sb.printJson(examined), sb.printJson(radius),
      tostring(petports_media().fly), tostring(petports_media().swim))
  end

  return nil
end

function petports_standingPointNear(position, radius)
  if position == nil then return nil end
  radius = radius or 4

  --  A FREE-MOVING CHASSIS OWNS THIS ANSWER OUTRIGHT, INCLUDING THE nil.
  --
  --  This used to be "try the flyer answer, fall through to the ground one",
  --  which was correct while nil could only mean "not a flyer". It stopped being
  --  correct the moment petports_flyPointNear gained a REFUSAL: nil now also
  --  means "I am a free mover and this target is not workable by me", and
  --  falling through turns that refusal into a ground answer one line later.
  --
  --  MEASURED, and it is exactly as silly as it sounds:
  --
  --    UNIT flypoint DECLINED [2501.5,1158.5]: target is not submerged and this
  --      chassis cannot leave the water
  --    UNIT standable for [2501.5,1158.5] -> [2501.5,1158.8] (column offset 0)
  --
  --  An aquatic unit refused a dry crop and was handed a dry-land standing spot
  --  on the next line. It then spent twenty seconds failing to path there,
  --  burned its progress strikes, and the port re-dispatched on a ten-second
  --  loop forever.
  --
  --  A ground unit never enters this branch, so the path that has always worked
  --  is untouched.
  if petports_freeMover() then
    return petports_flyPointNear(position, radius)
  end

  for offset = 0, radius do
    for _, dx in ipairs(offset == 0 and { 0 } or { -offset, offset }) do
      --  Tile centre. findGroundPosition only resolves the y.
      local x = math.floor(position[1] + dx) + 0.5

      local ground = findGroundPosition({ x, position[2] }, -radius, radius,
        petports_avoidLiquid())

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

  --  MUST NOT BE HARDCODED. Vanilla's PathMover:new defaults this to
  --  mcontroller.baseParameters().gravityEnabled, and we were overriding that
  --  default with a literal `true`.
  --
  --  PathFinder:find gates on it:
  --
  --      if self.options.mustEndOnGround
  --         and not validStandingPosition(targetPosition, false) then return false end
  --
  --  so for a flyer, `true` means every target that is not somewhere the unit
  --  could STAND is refused before any search runs -- which is most of the
  --  places a flyer exists to reach. It deletes the entire locomotion class.
  --
  --  Shared with the probe, so this fixes reachability caching in the same
  --  stroke: a probe that answers "unreachable" for a hover target and pushes
  --  that to the port would poison routing for every future unit.
  local flying = not mcontroller.baseParameters().gravityEnabled

  return {
    returnBest = false,
    mustEndOnGround = not flying,
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
    local fromGround = findGroundPosition(from, -4, 4, petports_avoidLiquid())

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
