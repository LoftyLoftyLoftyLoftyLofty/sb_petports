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

--  BUILD STAMP, LOGGED LAZILY -- NEVER AT CHUNK SCOPE.
--
--  IT HAS NEVER HAD ONE, and that is the gap this closes. The absence of an
--  object-side stamp already cost a full test round on the upcycler, and this
--  is the file whose silent absence is hardest to diagnose: every contract
--  function is reached by bare world.callScriptedEntity, which returns nil
--  without raising when the target does not define it. A missing contract and
--  a contract that answered "no" look identical from the port.
--
--  THE FIRST ATTEMPT PUT THE LOG CALL IN THE CHUNK BODY AND BROKE EVERY UNIT IN
--  THE GAME. `sb` IS NOT BOUND WHILE THE CHUNKS RUN:
--
--      Exception while creating lua context for scripts '(...)':
--      petports_contract.lua:39: attempt to index a nil value (global 'sb')
--
--  and because that is thrown during CONTEXT CREATION, the whole script list
--  fails together -- groundPet and every action state with it. 16 spawn
--  attempts, 16 dead contexts, no pets at all. A stamp is a diagnostic and a
--  diagnostic that can take the actor down with it is worse than none.
--
--  THIS FILE MAY NOT DEFINE init, per the header above, so there is no callback
--  to log from. Instead the stamp is emitted by the first CONTRACT CALL that
--  arrives, which is strictly better information anyway: it proves the file
--  loaded AND that the port can reach it, which is the pair of facts the stamp
--  exists to establish.
local CONTRACT_BUILD_STAMP = "2026-08-30i chassis team sent by the port"

local contractStamped = false

local function stampOnce()
  if contractStamped then
    return
  end
  contractStamped = true

  sb.logInfo("PETPORTS contract build: %s (unit %s)",
    CONTRACT_BUILD_STAMP, tostring(entity.id()))
end

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
  stampOnce()
  monster.setDeathParticleBurst(nil)
  monster.setDeathSound(nil)

  --  THE EFFECT KILLS, NOT THIS FUNCTION. petports_unitfadeout ends its ramp
  --  with status.setResource("health", 0), so the unit lives about a second
  --  longer than it used to and disappears on a fade instead of an instant
  --  vanish. See petports_unitfade.lua.
  --
  --  WHICH MAKES THIS FUNCTION'S RETURN A LIE IF READ AS "the unit is gone".
  --  It always meant "the request was accepted"; the difference did not matter
  --  while the kill was inline and it does now. Callers that need the unit
  --  actually gone must poll world.entityExists -- the hull door does.
  --
  --  IDEMPOTENT. addEphemeralEffect on an effect already running restarts it,
  --  which would visibly re-brighten a unit mid-fade, so a second call is
  --  ignored. The port can ask twice: saveAndDespawn runs from unsocket and
  --  again from uninit on world unload.
  if self.petportsFading then
    return true
  end
  self.petportsFading = true

  status.addEphemeralEffect("petports_unitfadeout")
  return true
end

--  MATERIALISE, APPLIED FROM THE MONSTER'S OWN init.
--
--  THE FIRST VERSION WAS CALLED BY THE PORT after world.spawnMonster, and the
--  unit was VISIBLE AT FULL SIZE WITH NO EFFECT for at least one tick. A
--  callScriptedEntity is a round trip: the monster has already initialised and
--  rendered once by the time the call lands.
--
--  VANILLA NEVER DOES IT THAT WAY. capturable.lua reads a SPAWN PARAMETER and
--  applies the effect inside the monster's own init --
--
--      if capturable.wasRelocated() and not storage.spawned then
--        status.addEphemeralEffect("monsterrelocatespawn")
--
--  -- so the relocator's monsters are already shrunk on their first rendered
--  frame. The beam is not hiding a pop; there is no pop to hide.
--
--  WRAPPING init RATHER THAN DEFINING IT. The header of this file forbids
--  DEFINING init, because a second definition silently REPLACES groundPet's.
--  Capturing the previous one and calling through is the opposite of that: it
--  preserves the chain. Verified that nothing in the monstertype's script list
--  defines init after this file -- if one ever does, it will replace this
--  wrapper and the pop comes back.
--
--  AFTER, NOT BEFORE. groundPet's init sets up the state machines and the pet
--  resources; applying a status effect before that has run would be reaching
--  into a half-built actor.
local petportsBaseInit = init

function init()
  if petportsBaseInit then
    petportsBaseInit()
  end

  stampOnce()

  --  SET BY THE PORT IN THE SPAWN PARAMETERS. Absent means a unit that arrived
  --  some other way -- a relocated one, a debug spawn -- and those should not
  --  materialise out of nothing.
  if not config.getParameter("petports_materialise", false) then
    return
  end

  --  HIDDEN SYNCHRONOUSLY, BEFORE ANYTHING CAN RENDER.
--
--  THE SPAWN PARAMETER ALONE WAS NOT ENOUGH. Moving the effect into init
--  removed most of the pop but not all of it -- a unit still appeared at full
--  size for one tick about a third of the time. status.addEphemeralEffect hands
--  off to the STATUS CONTROLLER, and whether that controller's first update
--  lands before or after this tick's render is not deterministic. Vanilla has
--  the same hole; the relocator's beam is what covers it, and we have no beam.
--
--  animator.setAnimationState IS SYNCHRONOUS. It is the one thing reachable
--  from here that is guaranteed to be in place before a frame can be drawn, so
--  the unit starts on a blank image and the effect takes over whenever the
--  status controller gets to it.
--
--  SELF-HEALING, WHICH IS WHY THIS IS SAFE. groundPet writes "movement" every
--  update out of setMovementState / setIdleState, so this state survives
--  exactly one tick and needs nothing to clear it. IF THE EFFECT FAILS
--  ENTIRELY the unit is invisible for one tick rather than visible for one --
--  strictly the better failure, and still self-correcting.
--
--  `invisible` was already declared in all four chassis animations and aliased
--  to the run strip, which made it a no-op. It now points at the spinner
--  sheet's deliberately empty `blank` frame.
  animator.setAnimationState("movement", "invisible")

  local ok, err = pcall(status.addEphemeralEffect, "petports_unitfadein")

  if not ok then
    sb.logError("PETPORTS unit %s could not apply petports_unitfadein: %s",
      tostring(entity.id()), tostring(err))
  end
end

--  WEAR WHAT THE MODULES GRANT.
--
--  The port owns the module set, resolves each module item's declared effects,
--  unions them and pushes the whole result here. This applies it and decides
--  nothing -- the unit does not know what a module is and should not learn.
--
--  setPersistentEffects REPLACES THE CATEGORY WHOLESALE, and that is the entire
--  reason this is four lines rather than a diff. Everything the port sends is
--  applied, anything it stops sending is dropped, and removing a module needs no
--  path of its own. An add/remove protocol would have to stay in step with the
--  item's stored state across respawn, world reload, and the unit being carried
--  to a different port -- three places it could silently fall behind.
--
--  IDEMPOTENT BY CONSTRUCTION, which matters because the port pushes on a
--  signature that includes the entity id: a unit that died and respawned gets
--  pushed to again, and re-applying an identical set has to be free.
--
--  A CATEGORY OF OUR OWN, PASSED IN RATHER THAN NAMED HERE. Effects applied by
--  anything else live under their own categories and are untouched by this.
--  Defaulted so a caller omitting it still lands somewhere sensible rather than
--  clearing whatever category `nil` resolves to.
--
--  VERIFY ON FIRST RUN: that status.setPersistentEffects is bound for a MONSTER
--  rather than only for players. The call is standard StatusController API and
--  the unit has a full statusSettings block, so it should be -- but this file
--  has been wrong about a binding before, and a silent no-op looks exactly like
--  a status effect that does not work. The log line below is what tells them
--  apart.
--  `liquids` IS A LIST OF LIQUID NAMES SOCKETED MODULES HAVE UNLOCKED, computed
--  by the port from the module ITEMS. It rides this call rather than getting one
--  of its own for two reasons.
--
--  ONE COMPUTATION, TWO CONSUMERS. The port needs the set for its own habitat
--  gate before a unit exists; the unit needs it for pathing and target
--  selection. Sending what the port already worked out means the two cannot
--  disagree about where this unit may go.
--
--  AND THE ARRIVAL IS THE INVALIDATION EVENT. Both caches cleared below latch on
--  first read and never expire, so a permission that changed while a unit was
--  alive would do nothing until it was re-socketed. There is no other hook that
--  fires on a module change -- this call IS the change -- so clearing them here
--  is not tidiness, it is the only place it can happen.
--  `flags` ARE NEW ON THIS CALL and did not travel when the channel was opened.
--  Oblivious is read entirely port-side, so the original design said flags never
--  reach a unit. Camouflage changes that: a damage team can only be set through
--  monster.*, which the port does not have.
function petports_setModuleEffects(effects, category, liquids, flags, baseTeam)
  category = category or "petports_modules"
  effects = effects or {}

  petports_applyModuleFlags(flags or {}, baseTeam)

  --  petportsAvoidLiquids is the SET this unit refuses.
  --  petportsLiquidVerdict is the memo of per-id answers derived from it, and it
  --  is the easy one to forget: it caches the VERDICT, not the list, so leaving
  --  it would keep returning "denied" for poison from a set that no longer
  --  contains poison.
  self.petportsModuleLiquids = petports_habitatPermittedSet(liquids or {})
  self.petportsAvoidLiquids = nil
  self.petportsLiquidVerdict = nil

  local ok, err = pcall(status.setPersistentEffects, category, effects)

  if not ok then
    sb.logInfo("UNIT setModuleEffects FAILED for category %s: %s",
      tostring(category), tostring(err))
    return false
  end

  sb.logInfo("UNIT module effects applied under %s: %s -- liquid permissions %s",
    tostring(category), sb.printJson(effects), sb.printJson(liquids or {}))
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

--  A HARMFUL LIQUID IS HARMFUL AT 0.1, NOT AT 0.9, AND THAT ASYMMETRY IS THE
--  WHOLE POINT OF HAVING TWO NUMBERS.
--
--  minimumLiquidStatusEffectPercentage is 0.1 on every chassis here, so that is
--  the fill at which the engine starts applying a liquid's status effects. A
--  tile one tenth full of lava is not deep enough to swim in and is entirely
--  deep enough to kill, so a denied liquid is refused from the moment it is
--  present rather than from the moment it is swimmable.
local PETPORTS_HARMFUL_FILL = 0.1

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
--  two progress strikes failed the task.
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

--  LIQUIDS THIS CHASSIS WILL NOT ENTER, BY NAME.
--
--  BY NAME AND NOT BY ID, DELIBERATELY. Starbound has 255 liquid slots and the
--  numbering is not something to hardcode from memory -- the one id this mod
--  has ever measured is 12 for swampwater, which matches no ordering anyone
--  would guess. root.liquidConfig resolves an id to its config, and the
--  watering code already relies on that call, so names are available and
--  numbers do not have to be.
--
--  A DENY-LIST, NOT AN ALLOW-LIST, AND THE REASONING IS NOT THE USUAL ONE. An
--  allow-list fails closed, which is normally right -- but there are hundreds of
--  benign modded liquids and three or four dangerous ones, so an allow-list
--  would break every liquid mod on contact and demand a patch per mod. The
--  asymmetry runs the other way here: the dangerous set is small, nameable, and
--  mostly vanilla.
--
--  ENTRIES MATCH LOOSELY ON PURPOSE. A liquid's name and its itemDrop are not
--  the same string ("lava" versus "liquidlava"), and which one root.liquidConfig
--  exposes is not something to assume, so both are compared and a bare number is
--  accepted too for anyone working from the wiki table. An unmatched liquid logs
--  what it actually resolved to, once, so a wrong entry is a one-cycle fix
--  rather than a mystery.
--  THE CHASSIS LIST MINUS WHAT MODULES HAVE UNLOCKED.
--
--  SUBTRACTIVE ONLY. A module can cancel an entry and cannot add one, so a
--  module can widen where this unit will go and can never strand it by
--  forbidding the water it lives in. Same rule as the port's overlay, and it has
--  to be, because the port's habitat gate and this unit's pathing must agree
--  about where it may be.
--
--  CACHED, AND CLEARED BY petports_setModuleEffects. The cache is what makes
--  this cheap enough for the search paths that call it; the clear is what stops
--  it outliving the permission set it was computed from.
local function avoidedLiquids()
  if self.petportsAvoidLiquids ~= nil then return self.petportsAvoidLiquids end

  local avoided =
    petports_habitatAvoidedSet(config.getParameter("petports_avoidLiquids", {}))

  local permitted = self.petportsModuleLiquids
  if permitted ~= nil and next(permitted) ~= nil then
    for name in pairs(permitted) do
      if avoided[name] then
        avoided[name] = nil
        sb.logInfo("UNIT module permission unlocks liquid %s -- it is no longer avoided",
          tostring(name))
      end
    end
  end

  self.petportsAvoidLiquids = avoided
  return avoided
end

--  Is this liquid one this chassis refuses to be in? Cached per id, because
--  this is asked once per tile row per candidate position inside searches that
--  already run eighty-one of them.
function petports_liquidDenied(liquidId)
  if liquidId == nil then return false end

  self.petportsLiquidVerdict = self.petportsLiquidVerdict or {}
  local cached = self.petportsLiquidVerdict[liquidId]
  if cached ~= nil then return cached end

  --  THE RESOLUTION MOVED TO petports_habitat.lua; THE MEMO DID NOT.
  --
  --  The shared resolver caches the NAMES a liquid id maps to, which is a
  --  property of the liquid. This cache holds the VERDICT, which is a property
  --  of the pair -- and it is the one that matters here, because this is asked
  --  once per tile row per candidate position inside searches that already run
  --  eighty-one of them. Without it every call would walk the avoided set again.
  local names = avoidedLiquids()
  local denied = petports_habitatLiquidDenied(names, liquidId)

  if next(names) ~= nil then
    sb.logInfo("UNIT liquid %s resolves to %s -- %s",
      sb.printJson(liquidId), sb.printJson(petports_habitatLiquidNames(liquidId)),
      denied and "DENIED, this chassis will not enter it" or "allowed")
  end

  self.petportsLiquidVerdict[liquidId] = denied
  return denied
end

--  WHAT MEDIUM IS THE BODY IN AT `position`? "air", "swim" or "forbidden".
--
--  THREE STATES, NOT TWO, AND THE THIRD IS WHY THIS REPLACED A BOOLEAN. A
--  denied liquid is neither swimmable nor air. Reporting it as "not submerged"
--  would make a flyer treat a lava lake as open sky; reporting it as "submerged"
--  would let a swimmer that happens to allow water treat it as home. It has to
--  refuse both, so it needs its own answer.
--
--  Rows only. Liquid fills by row, and a column-wise test would answer a
--  question liquid does not have.
--
--  FORBIDDEN WINS OVER EVERYTHING. One row of lava anywhere in the body's
--  footprint condemns the position, however much water surrounds it.
function petports_mediumAt(position, bounds)
  if position == nil then return "air" end
  bounds = bounds or mcontroller.boundBox()

  local x = position[1]
  local bottom = math.floor(position[2] + bounds[2])
  local top = math.ceil(position[2] + bounds[4]) - 1

  local submerged = true

  for row = bottom, top do
    local level = world.liquidAt({ x, row + 0.5 })

    --  world.liquidAt returns {liquidId, level} or nil. A nil is air, which is
    --  a definite answer and not a missing one.
    local fill = (level ~= nil) and (level[2] or 0) or 0

    if fill >= PETPORTS_HARMFUL_FILL and petports_liquidDenied(level[1]) then
      return "forbidden"
    end

    if fill < PETPORTS_SUBMERGED_FILL then submerged = false end
  end

  return submerged and "swim" or "air"
end

--  Point version of petports_mediumAt, same three states.
--
--  A POINT, NOT THE BODY BOX, and the distinction is the whole reason this
--  exists separately. petports_mediumAt asks "may my body occupy this", which is
--  the right question about a standing spot and the WRONG one about a target: a
--  crate resting just under the surface is submerged while a body centred on it
--  would straddle the waterline, so a body test would refuse work the unit can
--  plainly do.
function petports_mediumAtPoint(position)
  if position == nil then return "air" end

  local level = world.liquidAt(position)
  local fill = (level ~= nil) and (level[2] or 0) or 0

  if fill >= PETPORTS_HARMFUL_FILL and petports_liquidDenied(level[1]) then
    return "forbidden"
  end

  return (fill >= PETPORTS_SUBMERGED_FILL) and "swim" or "air"
end

--  Kept as a boolean for the callers that only ask "is this water". A forbidden
--  liquid is deliberately NOT submerged here: nothing should ever treat it as
--  somewhere to swim, and every caller that cares about the difference asks
--  petports_mediumAt instead.
function petports_submergedAt(position, bounds)
  return petports_mediumAt(position, bounds) == "swim"
end

--  Chassis capability. Cached per unit--  Chassis capability. Cached per unit: these are monstertype parameters and
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
--  "all of them". WHAT THE LADDER DOES WITH THAT IS petports_habitat.lua's
--  business and is deliberately not restated here -- this comment used to carry
--  its own copy of the rule, and that copy went stale the day the rule changed.
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
--  THE LADDER ITSELF NOW LIVES IN petports_habitat.lua, because the PORT has to
--  ask the same question BEFORE a unit exists to answer it. This function is
--  what gathers the LIVE capabilities and hands them over; the shared module
--  owns the order of the tests and the causes.
--
--  STILL WORTH CALLING EVEN THOUGH THE PORT CAN ANSWER FROM THE TYPE. The type
--  answer is a pre-check; this one is the truth, and it is the one that will
--  start diverging when module-granted liquid permissions land. See the note at
--  the head of petports_habitat.lua for which way that divergence runs.
--  petports_media IS READ ONLY FOR A FREE MOVER, and that is not an
--  optimisation. It logs the chassis's media on first call, including the
--  "NEITHER, this chassis can legally occupy nothing" warning -- which is
--  meaningless for a walker, whose flags are the meaningless defaults. The old
--  ladder only reached it inside the free-mover branch and this keeps that true.
--  THE CHASSIS TEAM, READ FROM THE MONSTER TYPE.
--
--  TWO EARLIER VERSIONS OF THIS ASKED THE ENTITY AND BOTH WERE WRONG.
--
--  The first read entity.damageTeam() lazily, and Lua's short-circuit meant it
--  was never called while camouflage was on -- so the "default" was captured on
--  UNSOCKET, after the team had already been changed to ghostly.
--
--  The second captured it eagerly, before any change, which fixed that and was
--  still wrong for a reason no ordering can fix: units are spawned PERSISTENT.
--  A unit saved to the world chunk while camouflaged is RESTORED with ghostly
--  baked in rather than respawned, so entity.damageTeam() reports ghostly as the
--  chassis default however early it is asked. Measured 2026-08-30 -- a restored
--  unit sat at ghostly/0 through repeated socket and unsocket cycles, logging
--  nothing at all, because the change gate saw have == want every time.
--
--  THE TYPE CANNOT BE CORRUPTED BY A SAVE. petports_chassisTeam reads the
--  monstertype, which is what the unit WOULD have been spawned with -- see
--  fact.unit.spawnoverride for the same type/entity split deciding two other
--  bugs in this mod.
--  SENT BY THE PORT, which resolves it from the monster type. The unit does not
--  look it up: monster.type() is an API this mod has never used, and a lookup
--  that failed would fall back to entity.damageTeam() -- the exact untrustworthy
--  source the whole exercise exists to avoid.
--
--  CACHED so a push that omits it -- an older port, a partial install -- does not
--  strand the unit on whatever it currently has.
local function baseTeam(sent)
  if type(sent) == "table" and sent.type ~= nil then
    self.petportsBaseTeam = sent
  end

  if self.petportsBaseTeam ~= nil then return self.petportsBaseTeam end

  --  LAST RESORT, AND KNOWN TO BE UNRELIABLE. A restored persistent unit that
  --  was saved while camouflaged reports ghostly here.
  return entity.damageTeam()
end

--  UNIT-SIDE MODULE FLAGS. Everything the PORT can act on itself stays there;
--  this is only for what needs monster.* callbacks.
--
--  CAMOUFLAGE GOES GHOSTLY, which is the same team vanilla's Oblivious Collar
--  uses to pacify a pet -- and, measured 2026-08-30, the team FISHING FISH sit
--  on. It takes the unit out of damage resolution entirely so nothing hunts it.
--
--  IT DOES NOT STOP THE UNIT WORKING, unlike the oblivious module. Hidden and
--  busy is the point.
--
--  A CAMOUFLAGED UNIT IS STILL A VALID PATIENT, and that is not luck: the medic
--  classifier tests petports_unit BEFORE it looks at the damage team, precisely
--  so a unit that reads ghostly is recognised as ours rather than as a fish.
--  See arch.dispatch.medicpatients -- this is the case that ordering protects.
function petports_applyModuleFlags(flags, sentBaseTeam)
  local set = {}
  for _, flag in ipairs(flags or {}) do set[flag] = true end

  --  CAPTURED FIRST, UNCONDITIONALLY, AND THE ORDER IS THE FIX.
  --
  --  This used to read `set.camouflage and {ghostly} or baseTeam()`, and Lua
  --  short-circuits: with camouflage on, baseTeam() was NEVER CALLED. A unit
  --  whose first push already had the module -- a world reload, a respawn after
  --  death, anything that rebuilds the unit with camo socketed -- then captured
  --  its "chassis default" for the first time on UNSOCKET, by which point
  --  entity.damageTeam() returns the ghostly value it was changed to. It cached
  --  ghostly as the default and restored the unit to ghostly, permanently, while
  --  logging that it had restored the default.
  --
  --  Calling it here means the capture always happens BEFORE this function has
  --  changed anything, which is the only moment the answer is trustworthy.
  local base = baseTeam(sentBaseTeam)

  local want = set.camouflage and { type = "ghostly", team = 0 } or base
  local have = entity.damageTeam()

  --  CHANGE-GATED. setDamageTeam every push would rewrite the team on every
  --  module rearrangement, and this call runs whenever the signature moves.
  if have ~= nil and want ~= nil
     and tostring(have.type) == tostring(want.type)
     and have.team == want.team then
    return
  end

  local ok, err = pcall(monster.setDamageTeam, want)

  if not ok then
    sb.logInfo("UNIT setDamageTeam FAILED for %s: %s", sb.printJson(want), tostring(err))
    return
  end

  sb.logInfo("UNIT damage team %s -> %s (%s)",
    have and (tostring(have.type) .. "/" .. tostring(have.team)) or "nil",
    tostring(want.type) .. "/" .. tostring(want.team),
    set.camouflage and "camouflage module socketed" or "chassis default restored")
end

function petports_capabilities()
  local freeMover = petports_freeMover()
  local media = freeMover and petports_media() or {}

  return
  {
    freeMover = freeMover,
    fly = media.fly,
    swim = media.swim,
    avoidLiquid = petports_avoidLiquid(),
    avoided = avoidedLiquids()
  }
end

function petports_canInhabit(wet, dry, liquids)
  local verdict = petports_habitatVerdict(petports_capabilities(), wet, dry, liquids)

  --  A nil VERDICT IS PASSED STRAIGHT THROUGH, and the port already treats it
  --  as "this unit did not answer" -- which is the correct reading. It cannot
  --  happen from here today, because a capability table built from live
  --  callbacks is always a table, but returning a fabricated refusal instead
  --  would retire a working unit over a future change in that module.
  if verdict == nil then return nil end

  --  THE SENTENCE TRAVELS WITH THE CAUSE, because "the port despawned my pet"
  --  has to say why in one line or it reads as the mod losing units. The port
  --  can look it up itself and does; sending it costs one string and keeps this
  --  answer readable in a log on its own.
  verdict.reason = petports_habitatReason(verdict.cause)
  return verdict
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
  local medium = petports_mediumAtPoint(position)

  if medium == "forbidden" then
    return false, "target sits in a liquid this chassis will not enter"
  end

  if medium == "swim" then
    if media.swim then return true, "target is submerged" end
    return false, "target is submerged and this chassis cannot swim"
  end

  if media.fly then return true, "target is in air" end
  return false, "target is not submerged and this chassis cannot leave the water"
end

function petports_mediumAllows(position, bounds)
  local medium = petports_mediumAt(position, bounds)

  --  FORBIDDEN FIRST, AND FOR EVERY CHASSIS INCLUDING WALKERS.
  --
  --  This test used to sit BELOW the free-mover short-circuit, which meant a
  --  walking chassis never reached it -- fine while the only walker refused all
  --  liquid outright, and wrong the moment an amphibious one exists. An
  --  amphibious walker with the short-circuit first wades into lava for exactly
  --  the reason the aquatic unit would have without a deny-list.
  --
  --  The distinction that matters: "forbidden" is not a medium this chassis
  --  lacks the equipment for, it is one it is configured to stay out of. No
  --  combination of canFly, canSwim or avoidLiquid overrides it, so it is asked
  --  before any of them.
  if medium == "forbidden" then
    return false, "a liquid this chassis will not enter"
  end

  --  MEDIUM PERMISSION IS A FREE-MOVER CONCEPT ONLY.
  --
  --  A walking chassis has no medium PERMISSION -- its medium is decided by
  --  physics. It sinks, it wades, it swims when the engine says so, and none of
  --  that is ours to allow or refuse. Whether it should enter ordinary water at
  --  all is the avoidLiquid question, which is separate and answered elsewhere.
  --
  --  THIS IS NOT A TIDINESS EDIT. Without it, a ground unit that string-pulls
  --  through water gets every submerged sample of flyPathClear refused, because
  --  the drone declares no flags and therefore defaults to canSwim false. The
  --  shortcut silently collapses to "aim at the next waypoint", the mover
  --  appears bound and does nothing, and the rubberbanding it was added to fix
  --  carries on exactly as before with no line in the log to say why.
  if not petports_freeMover() then
    return true, "walking chassis, medium is physics"
  end

  local media = petports_media()

  if medium == "swim" then
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

--------------------------------------------------------------------------------
--  THE PATHFINDER'S GRID
--------------------------------------------------------------------------------
--
--  THE SEARCH ONLY UNDERSTANDS POSITIONS WHERE THE BODY'S FEET SIT ON A TILE
--  LINE. Everything else is a position the unit can occupy and cannot plan
--  from: ask for a route and the search has no node to begin on, so it exhausts
--  immediately and returns no path.
--
--  MEASURED, 120 of 120 edge targets in one log, no exceptions: every waypoint
--  the engine produced was at a WHOLE-NUMBER x and a y ending in .8. Nothing in
--  between, ever.
--
--  WHY .8, AND WHY IT MUST NOT BE HARDCODED. Our body is 1.6 tall with
--  bounds[2] of -0.8, so a centre at y.8 puts the BOTTOM at y.0 -- on the tile
--  line. The rule is about the bottom of the box, not the middle of it. It
--  equals half the height only because this poly happens to be symmetric: a
--  1.6-tall body with bounds[2] of -0.5 needs .5, and half-height would say .8
--  and be wrong.
--
--  So it is derived from bounds[2], using VANILLA'S OWN LINE from
--  findGroundPosition -- which means it stays correct if the alignment rule
--  ever changes:
--
--      position = {position[1], math.ceil(position[2]) - (bounds[2] % 1)}
--
--  THE X RULE IS MEASURED, NOT DERIVED. Whole numbers, 120 out of 120, but
--  nothing about a 1.6-wide body implies its centre belongs on a tile boundary
--  rather than a tile centre -- that is the engine's choice and we are copying
--  it. IF A DIFFERENTLY SHAPED CHASSIS EVER FAILS TO PLAN FROM A SPOT IT IS
--  SITTING IN, re-measure this first: dump the fractional part of the `dst`
--  values in any plan and see what it actually is.
function petports_nodePosition(position, bounds)
  bounds = bounds or mcontroller.boundBox()

  return {
    math.floor(position[1] + 0.5),
    math.ceil(position[2]) - (bounds[2] % 1)
  }
end

--  Only search near the target. A correction three tiles away is not a fix for
--  anything; if nothing close works, declining is the answer.
local FLY_SEARCH_RADIUS = 4

--  Set false once the flyer is trusted.
local FLY_POINT_DEBUG = true

--  How far to walk the open run when reporting spans. Diagnostic only.
local FLY_SPAN_PROBE = 6

--  Does the body fit centred exactly here? Everything is built out of this one
--  test so the search and the diagnostics cannot disagree.
local function flyBodyFits(x, y, bounds)
  return not world.rectTileCollision({
    x + bounds[1], y + bounds[2],
    x + bounds[3], y + bounds[4]
  }, FLY_TILE_SET)
end

--  Fits AND is in a medium this chassis may occupy. Both conditions travel
--  together everywhere, because a position that is geometrically free but in
--  the wrong medium is exactly as unusable as one inside a wall.
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

  --  SCAN THE PATHFINDER'S GRID, NOT AN ARBITRARY SUB-TILE ONE.
  --
  --  This used to test tile CENTRES and then, when one failed, search sub-tile
  --  offsets in 0.1 steps for anywhere the body fitted. That fixed real bugs --
  --  a flyer could not otherwise enter a 2-high corridor, nor reach an item
  --  beside a wall -- and it also produced positions like x 2511.96, which the
  --  unit occupies happily and CANNOT PLAN A ROUTE FROM.
  --
  --  Measured: a pelagic unit parked at [2511.96,1146.8], every search
  --  exhausting in one or two ticks at exploreRate 25-150. Not a small region;
  --  a search with no node to begin on.
  --
  --  NOTHING IS LOST BY RESTRICTING TO THE GRID. Both cases the sub-tile search
  --  was built for are solved by grid positions:
  --
  --    2-high corridor  the free search answered y 1023.8, which IS a grid y --
  --                     it found the right answer by luck, because the correct
  --                     offset happened to fall inside its range. Tile centres
  --                     1023.5 and 1024.5 both fail, which is why it was needed.
  --    item by a wall   the free search answered x 3763.2; the grid gives
  --                     3763.0, which clears the same wall.
  --
  --  So this is strictly a narrowing: same solving power, minus the ability to
  --  produce somewhere unplannable. It is also cheaper -- one candidate per
  --  lattice point instead of up to 121 sub-tile probes per tile.
  --
  --  ORDERED BY TRUE DISTANCE. The old order walked Chebyshev rings and, within
  --  a ring, dx outer and dy inner from -offset, so the first candidate of every
  --  ring was down-and-left and everything else lost to it regardless of
  --  distance. In a first-fit search the order IS the answer.
  local origin = petports_nodePosition(position, bounds)

  local candidates = {}
  for dx = -radius, radius do
    for dy = -radius, radius do
      local x = origin[1] + dx
      local y = origin[2] + dy
      table.insert(candidates, { x, y, world.magnitude({ x, y }, position) })
    end
  end
  table.sort(candidates, function(a, b) return a[3] < b[3] end)

  local examined = 0

  for _, candidate in ipairs(candidates) do
    local cx, cy = candidate[1], candidate[2]
    examined = examined + 1

    local usable, why = flyBodyUsable(cx, cy, bounds)
    local reason = why

    if usable then
      if flySighted({ cx, cy }, position) then
        if FLY_POINT_DEBUG then
          sb.logInfo("UNIT flypoint ACCEPTED %s for %s after %s grid point(s): dist %s",
            sb.printJson({ cx, cy }), sb.printJson(position),
            sb.printJson(examined), sb.printJson(candidate[3]))
        end

        return { cx, cy }
      end

      reason = "fits but cannot see the target"
    end

    if FLY_POINT_DEBUG then
      sb.logInfo("UNIT flypoint  #%s grid %s dist %s: %s",
        sb.printJson(examined), sb.printJson({ cx, cy }),
        sb.printJson(candidate[3]), tostring(reason))
    end
  end

  if FLY_POINT_DEBUG then
    sb.logInfo("UNIT flypoint NO POINT for %s after %s grid point(s) out to radius %s -- "
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

      --  Same forbidden-liquid gate as standableNear in petportsTaskAction --
      --  the two resolvers must agree, and a denied liquid is the one thing
      --  petports_mediumAllows refuses for a walking chassis.
      if ground ~= nil and validStandingPosition(ground, false)
         and petports_mediumAllows({ ground[1], ground[2] }) then
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

--  The path options a unit actually walks with. See petports_pathOptions
--  below; the escalating small jump it reads is defined first.

--------------------------------------------------------------------------------
--  THE SMALL JUMP
--------------------------------------------------------------------------------
--
--  AN ESCALATING MULTIPLIER WAS TRIED HERE AND REMOVED. Recording it because the
--  idea is an obvious one to have twice.
--
--  The theory was that no fixed smallJumpMultiplier suits all terrain, so each
--  jump-attributable replan would add 0.1 and a fresh pather would offer A* a
--  second jump height it had not tried. Measured over one session's log, it was
--  wrong twice over:
--
--  1  IT COULD NOT REACH THE FAILING JUMPS. Every unexecutable takeoff in that
--     log -- 14 of them, a perfect correlation -- launched at [12,45], the FULL
--     jump. smallJumpMultiplier scales only the SECOND height, so no value of it
--     touches those at all. Worse, escalating toward 1.0 converges the small
--     jump ONTO 45 and removes the 31.82 option, which succeeded every time it
--     was used.
--
--  2  IT NEVER FIRED WHERE THE LOOPS WERE. All three observed loops replanned
--     through the airborne-edge stall, not the arc-landing handler where the
--     hooks were. The two times it did fire, neither was a jump: one was a Land
--     edge 0.57 tiles out against a 0.5 tolerance, the other a body-clearance
--     failure on a one-edge walk plan.
--
--  THE ACTUAL FAULT WAS IN THE PLAN, NOT THE OPTIONS. A* emitted a Jump edge
--  whose own arc waypoints top out at the target height while the launch it
--  prescribes is still rising at vy 36 -- a Land placed on the ASCENDING
--  crossing. See petportsJumpMover.
--
--  A CONSTANT, THEREFORE, AND PARAMETERISED so a chassis can retune it from the
--  monstertype without editing this file.

--  SEARCH OPTIONS, SHARED BY THE REAL PATHER AND THE PROBE. A probe that uses
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
    boundBox = bounds,
    standingBoundBox = { bounds[1] + pad, bounds[2], bounds[3] - pad, bounds[4] },
    droppingBoundBox = { bounds[1] + pad, bounds[2], bounds[3] - pad, bounds[4] },
    --  A SECOND JUMP HEIGHT FOR THE PLANNER. IT DOES NOT REPLACE THE FIRST.
    --
    --  From PlatformerAStar.cpp, getJumpingNeighbors:
    --
    --      forEachArcVelocity(*jumpSpeed, addVel);
    --      forEachArcVelocity(*jumpSpeed * smallJumpMultiplier, addVel);
    --
    --  forEachArcVelocity emits five velocities -- (0,vy), (+-walkSpeed,vy),
    --  (+-runSpeed,vy) -- so this is called TWICE and A* is offered two jump
    --  strengths. It is not a minimum, not a tolerance, and not a constraint
    --  that jumps must match. AT 1.0 THE SECOND CALL DUPLICATES THE FIRST, and
    --  the planner has exactly ONE jump available: full strength.
    --
    --  THAT IS WHY EVERY JUMP THIS MOD HAS EVER PLANNED IS A MAXIMUM-HEIGHT
    --  LAUNCH. A unit that needs to get onto a ONE-TILE STEP was planned an
    --  8.44-tile arc or nothing, and "nothing" is what produced the coffee
    --  route that dropped into the sea to jump back out -- walking up a square
    --  step is not an edge the engine generates (see the step entry in the
    --  handoff), so the hop was the only way up and there was no small hop.
    --
    --  Rise goes with the SQUARE of the multiplier, so the numbers are smaller
    --  than the name suggests. g 120, jumpSpeed 45, walkSpeed 8:
    --
    --      mult    launch    rise    airtime   x @walk8
    --      1.0      45.00    8.438     0.750       6.00   what we had
    --      0.7071   31.82    4.219     0.530       4.24   here, and vanilla's
    --      0.5      22.50    2.109     0.375       3.00   the previous value
    --
    --  0.70711 IS VANILLA'S NUMBER AND THE REASON TO MATCH IT IS NOT "MATCH
    --  VANILLA". An earlier note here said 0.5 was deliberate -- a hop "sized
    --  for the one and two tile steps players actually build" -- and offered
    --  0.70711 only as a fallback if that proved too small, on the grounds of
    --  parity. That had the argument backwards.
    --
    --  1/sqrt(2) HALVES THE HEIGHT. 0.5 QUARTERS IT, and a quarter-height arc is
    --  low enough that the planner starts SOLVING SHORT HOPS WITH IT -- and a
    --  very flat arc is the worst tool for a short hop, because clearing any
    --  height at all then demands horizontal speed the unit carries straight
    --  past the target. The observed result is comic overshoot on exactly the
    --  small steps the smaller multiplier was chosen to serve.
    --
    --  So the second jump height has to stay high enough that the solver keeps
    --  reaching for the full arc on anything that needs real lift, and vanilla's
    --  choice is where that line sits. This is a correction to the value AND to
    --  why it was picked, not a fallback being taken.
    --
    --  WHY THE OLD PIN AT 1.0 WAS RIGHT WHEN IT WAS WRITTEN, AND IS NOT NOW.
    --  It read "the actor cannot perform a partial jump", citing
    --  jumpInitialPercentage 1.0 and jumpHoldTime 0.0, and it was measured: the
    --  planner drew a 33.75 arc and the unit answered with 45, clearing its own
    --  plan by three tiles. But those settings govern the jump CONTROL, and
    --  petportsJumpMover does not use it -- it calls
    --  mcontroller.setVelocity({edge.jumpVelocity[1], vy}), and launchVelocity
    --  returns the PLANNED velocity untouched unless the arc needs more. A 22.5
    --  edge is flown at 22.5 (plus the 2% JUMP_VELOCITY_MARGIN). Only ever
    --  raising is a policy, not a physical constraint.
    --
    --  THE ONE PATH THAT COULD STILL BREAK IT. approachPoint in
    --  petports_flyapproach.lua has a fallback `self.pather = self.pather or
    --  PathMover:new(...)` that rebinds moveSwim and NOTHING ELSE -- so a pather
    --  built there runs VANILLA moveJump, which ignores edge.jumpVelocity and
    --  fires at full strength. That is exactly the 33.75-planned/45-flown
    --  failure above. It is narrow today: freshPather runs on entering any task
    --  state including leash, and self.pather persists on the script table
    --  afterwards, so the fallback can only fire for a unit that reaches
    --  petportsSleepAction before it has ever held a task. Fix that binding
    --  before trusting this value on a fresh spawn.
    --
    --  Parameterised like the search costs below so the value can be retuned
    --  from the monstertype without editing this file.
    --
    --  CHANGING IT NEEDS A NEW PATHER, NOT A RESET. PathFinder holds the options
    --  table it was constructed with, and PathFinder:reset() clears edges,
    --  hasPath and the cursor -- not the options. So every replan that goes
    --  through reset() re-searches with the value that just failed, and from the
    --  same position produces the same plan. Only freshPather picks up a change.
    --  Measured: three loops of byte-identical replans, ten iterations of one of
    --  them.
    smallJumpMultiplier = config.getParameter("petports_smallJumpMultiplier", 0.70711),
    jumpDropXMultiplier = 0.125,
    enableWalkSpeedJumps = true,
    enableVerticalJumpAirControl = true,
    --  SEARCH COSTS ARE PER CHASSIS, AND THEY STEER THE PLANNER RATHER THAN
    --  MERELY EXPRESSING A PREFERENCE.
    --
    --  These were never set, so vanilla's defaults applied to every locomotion
    --  class: swimCost 5, liquidJumpCost 15, dropCost 2. Those encode "swimming
    --  is a last resort", which is right for a humanoid NPC wading a river and
    --  wrong for something built to swim.
    --
    --  WHY IT IS NOT COSMETIC. Plan medium validation REFUSES a route through a
    --  medium this chassis may not occupy, and a refusal produces no motion at
    --  all -- if A* keeps handing back the same illegal route, the unit never
    --  moves and the task dies on the progress watchdog. Cost is what makes the
    --  search return an ACCEPTABLE plan instead of one we have to reject. So
    --  making water expensive for a flyer is not a nicety, it is how the flyer
    --  gets a dry route rather than a refusal.
    --
    --  THE ASYMMETRY: there is no flyCost. Water can be made attractive or
    --  costly, air cannot, so an aquatic chassis still relies on validation to
    --  refuse air routes rather than on cost to avoid them. Nothing to be done
    --  about that from here.
    --
    --  liquidJumpCost IS THE PRICE OF A WATER BOUNDARY, paid on every jump made
    --  from liquid. An amphibious route that leaves the water, re-enters and
    --  leaves again pays it FOUR TIMES -- 60 F-score of the 400 budget before a
    --  single tile of distance is counted, on top of swimCost 5 per submerged
    --  tile. That is the suspected cause of an amphibious unit failing to find
    --  any route home across multiple crossings, and these values are the test
    --  of it.
    swimCost = config.getParameter("petports_swimCost", 5),
    liquidJumpCost = config.getParameter("petports_liquidJumpCost", 15),
    dropCost = config.getParameter("petports_dropCost", 2),

    --  BUDGETS, ALSO PER CHASSIS. A route that exits water, re-enters and exits
    --  again is far longer than the straight line to its target, so maxDistance
    --  bounds it out of existence before maxFScore ever gets a say.
    --
    --  SHARED WITH THE PROBE, WHICH IS WHY THESE READ FROM CONFIG RATHER THAN
    --  BEING PASSED IN. petports_probeStep builds its finder from this same
    --  function, and the handoff is emphatic that a probe searching with
    --  different options than the real walk does not predict it -- and its
    --  answers are CACHED and pushed to the port, so a mismatch poisons routing
    --  for every future unit. Config keeps both sides identical by construction.
    --  1200, UP FROM VANILLA'S 400, FOR EVERY CHASSIS.
    --
    --  MEASURED: an amphibious unit could route home across two shallow pools
    --  at 800 and failed on a slightly longer case -- out of the water, up a
    --  platform, back in, back out. 800 was scraping the edge, so the budget is
    --  the binding constraint on multi-crossing routes rather than anything
    --  structural in the search.
    --
    --  WHAT IT ACTUALLY COSTS, because this is not free. maxFScore bounds a
    --  FAILING search, not a succeeding one: a reachable target is found and the
    --  budget never comes near. An UNREACHABLE target explores until it hits
    --  this or maxNodesToSearch, so tripling this triples how long the unit
    --  spends proving something cannot be reached -- and that time is spent
    --  MOTIONLESS, because canPathfind refuses to search while airborne and the
    --  unit is not moving during a cold search anyway.
    --
    --  The hard ceiling is maxNodesToSearch 70000 at exploreRate 300 per tick,
    --  which is 233 ticks -- roughly 19 seconds at the measured ~82ms tick. So
    --  the worst case per search is bounded regardless; what changes is how many
    --  searches reach that ceiling instead of stopping early.
    --
    --  SEE THE NOTE ON healthCheck IN petports_petport.lua. Its stall limit was
    --  set at 90 seconds specifically to clear the 45-50s cold-cache probe
    --  measured in the handoff, and vent routing runs several searches back to
    --  back. If a probing unit ever gets re-homed mid-search, this number and
    --  that one are the pair to look at together -- not either alone.
    maxFScore = config.getParameter("petports_maxFScore", 1200),
    maxDistance = config.getParameter("petports_maxDistance", 200),
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

--------------------------------------------------------------------------------
--  PLAYER INTERACTION -- HEADPATS
--------------------------------------------------------------------------------
--
--  THE UNIT IS A DUMB REPORTER. Every accepted interaction is sent to the home
--  port and the PORT decides what it meant -- today a headpat, later "drop the
--  stuck cargo" once that mechanic exists, because cargo lives on petData and
--  only the port can see it. See the petports_headpat handler in
--  petports_petport.lua.
--
--  THIS REPLACES VANILLA'S interact() AND CARRIES ITS BODY FORWARD -- read
--  from the vanilla source, not guessed. groundPet.lua defines interact() to
--  emote "happy" on a config cooldown ("interactCooldown", default 3.0)
--  tracked in self.lastInteract, which its init() zeroes. One shared
--  environment means this later definition replaces it silently, so the emote
--  half is reproduced verbatim below; lose it and pats go visually dead.
--
--  NO setInteractive AND NO setAnchor SHADOW, because vanilla already does
--  both jobs: groundPet's init() calls monster.setInteractive(true), and its
--  setAnchor() stores the port's entity id in self.anchorId, which
--  updateAnchor() re-verifies every second. Reading vanilla's own field beats
--  shadowing vanilla's function to duplicate it.
--
--  ONE GATE, AND IT IS VANILLA'S. The send sits INSIDE the interactCooldown
--  branch, so a pat that emotes is exactly a pat that counts -- the emote and
--  the ledger cannot disagree, and mashing E collapses to one of each per
--  window. The port-side counting cooldown this used to pair with is gone.
function interact()
  if world.time() - self.lastInteract > config.getParameter("interactCooldown", 3.0) then
    emote("happy")
    self.lastInteract = world.time()

    --  An orphan with no live port has nobody to tell. Quietly nothing: the
    --  pat happened, the ledger just was not open.
    if self.anchorId ~= nil and world.entityExists(self.anchorId) then
      world.sendEntityMessage(self.anchorId, "petports_headpat")
    end
  end

  --  nil: no interact action, same as vanilla's fall-through.
  return nil
end
