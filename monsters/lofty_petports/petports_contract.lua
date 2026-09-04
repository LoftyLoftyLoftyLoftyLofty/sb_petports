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
local CONTRACT_BUILD_STAMP = "2026-09-04l a death report carries the entity id"

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
--  THAT LAST SENTENCE STOPPED BEING THE WHOLE TRUTH WHEN die() LEARNED TO
--  SPILL CARGO. dropPools is still empty and still leaves nothing behind, but
--  a recall now arrives at die() by exactly the route a lava death does --
--  health reaching zero -- and die() cannot tell them apart on its own. So
--  this sets the latch that says which one it is. Without it every unsocket
--  would dump the unit's load on the floor, and so would every world unload,
--  because the port calls saveAndDespawn from its own uninit as well.
--
--  SET BEFORE ANY EARLY RETURN, so that no later edit to the idempotency
--  guard below can strand it. It is unconditional; it does not want to be
--  anywhere a branch can skip.
--
--  AND SETTING IT IS NOT ENOUGH ON ITS OWN, WHICH COST A TEST ROUND. The
--  latch lives on `self`, and `self` dies with the script context -- but the
--  FADE OUTLIVES THE CONTEXT. Measured 2026-09-04: the port called this from
--  its uninit 68ms before the world was torn down, the effect needs about a
--  second to reach zero health, and the still-living unit was serialised into
--  the world save MID-DEATH. On reload it came back as a fresh entity with the
--  kill still queued and the latch gone, and spilled its load on the floor.
--  `instant` below is what closes that window; see it for the rest.
--
--  VERIFY: setDeathParticleBurst / setDeathSound accepting nil to clear. If the
--  unit poofs audibly on recall, that is these two not taking effect, and the
--  fix is passing "" rather than nil.
--
--  `instant` -- CULL NOW, NO FADE. Passed by the port when it is putting the
--  unit away for a WORLD UNLOAD, and by nothing else.
--
--  arch.unit.exitpaths already said this and the code was not doing it: a
--  world unload is "not an event at all. No animation, no cargo drop." The
--  fade was copied from the unsocket path, where a player IS watching, to one
--  where the world is being torn down and nobody can see it. It bought
--  nothing and cost the window above.
--
--  NOTHING IS LOST BY SKIPPING IT. saveAndDespawn has already taken the
--  unit's state and written cargo into the item by the time this is called,
--  so a unit culled here resumes from the item on the next load exactly as
--  one that faded would.
function petports_despawn(instant)
  stampOnce()
  self.petportsNoDrop = true
  monster.setDeathParticleBurst(nil)
  monster.setDeathSound(nil)

  if instant then
    --  NO IDEMPOTENCY GUARD, DELIBERATELY. The fade below needs one because
    --  re-applying an ephemeral effect restarts its ramp and visibly
    --  re-brightens a unit mid-dissolve. Setting a resource that is already
    --  zero does nothing at all, so a second call is free.
    sb.logInfo("UNIT %s culled at %s -- world unloading, no fade",
      tostring(entity.id()), sb.printJson(mcontroller.position()))

    status.setResource("health", 0)
    return true
  end

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

--  DEATH -- THE UNIT'S ONE CHANCE TO SAY WHERE IT FELL.
--
--  A FRESH DEFINITION, NOT A REPLACEMENT, AND THAT IS THE OPPOSITE OF
--  interact() BELOW. groundPet.lua defines no die(), no shouldDie() and no
--  uninit() -- read from the vanilla source, 2026-09-04, not inferred from the
--  absence of a symptom. interact() had to reproduce vanilla's body verbatim or
--  pats went visually dead; there is no body here to lose.
--
--  NOT MODELLED ON /scripts/monster.lua EITHER, which is the other place a
--  die() would normally be read from. Its body is three statements and all
--  three are absent from a pet's script context:
--
--      capturable.die()    /scripts/companions/capturable.lua is in no
--                          chassis scripts list, so `capturable` is a nil
--                          global and the call would RAISE rather than no-op.
--                          Moot regardless -- every monstertype here sets
--                          capturable false.
--      self.deathBehavior  a BEHAVIOR TREE, built by behavior.lua from a
--                          "deathBehavior" config key. These units run
--                          stateMachine.lua and never load behavior.lua, so
--                          the tree is never built and the branch is dead.
--      spawnDrops()        from /scripts/drops.lua, also unlisted, and
--                          dropPools is empty on every chassis anyway.
--
--  WHICH MEANS AN ON-DEATH BEHAVIOUR -- gibs, an explosion, a noise -- CANNOT
--  BE AUTHORED AS A deathBehavior KEY and has to be spawned from right here.
--  Nothing does that yet. This function is the hook when something does.
--
--  THE UNIT SENDS A POSITION AND NOTHING ELSE, because it is carrying nothing
--  to send. Every pickup is handed over on the tick it happens, and a withdraw
--  never touches an item at all -- the port does the containerConsume when the
--  arrival is reported. The load lives on petData and only the port can see
--  it, which is the division interact()'s header below already anticipated.
--
--  THREE DEATHS MUST NOT SPILL AND ONLY ONE OF THEM NEEDS THE LATCH:
--
--      recall        petports_despawn kills through petports_unitfadeout, so
--                    it reaches here looking exactly like a real death.
--                    self.petportsNoDrop is the entire difference.
--      world unload  the same path, because the port calls saveAndDespawn
--                    from uninit -- so the same latch covers it.
--      lost anchor   groundPet's findAnchor sets health to 0 when it cannot
--                    re-find its port, and it only runs once self.anchorId is
--                    already dead. The entityExists guard below refuses the
--                    send on its own, so no latch is wanted. Nothing is lost
--                    either way: flushCargo writes cargo into the unit ITEM on
--                    every receive, and that item dropped when the port broke.
--
--  UNVERIFIED, AND THE FIRST TEST IS WHAT ANSWERS IT: whether a
--  world.sendEntityMessage issued from inside die() is still delivered once
--  the sender is destroyed. The message is queued on the world rather than
--  held by the sender, so it SHOULD survive -- but that is reasoning, not a
--  measurement. The port logs on receipt; if that line never appears, this
--  has to move to a poll on the port side instead.
function die()
  if self.petportsNoDrop then
    sb.logInfo("UNIT %s died on a recall at %s -- cargo stays with the port",
      tostring(entity.id()), sb.printJson(mcontroller.position()))
    return
  end

  if self.anchorId == nil or not world.entityExists(self.anchorId) then
    sb.logInfo("UNIT %s died at %s with no live port to tell",
      tostring(entity.id()), sb.printJson(mcontroller.position()))
    return
  end

  sb.logInfo("UNIT %s died at %s -- asking port %s to spill the load",
    tostring(entity.id()), sb.printJson(mcontroller.position()),
    tostring(self.anchorId))

  --  THE ENTITY ID IS WHAT THE PORT CHECKS, and the uniqueId is only for the
  --  log line. An entity id is unambiguous WITHIN THIS WORLD AT THIS INSTANT,
  --  which is exactly the question being asked at the far end -- "are you the
  --  unit I currently own" -- and it is the same number the port holds in
  --  self.petId. A uniqueId would need the port to have recorded one, and a
  --  leftover restored from a world save carries a perfectly valid uniqueId
  --  that no live port has ever heard of, which is the case this exists for.
  world.sendEntityMessage(self.anchorId, "petports_unitDied", {
    position = mcontroller.position(),
    id = entity.id(),
    unit = entity.uniqueId()
  })
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

  --  THE STORED NAME, APPLIED AT SPAWN.
  --
  --  ABOVE THE MATERIALISE GATE ON PURPOSE. That gate exists to keep a debug or
  --  relocated unit from fading in out of nothing; a name is not choreography and
  --  a unit that arrived some other way should still wear one if it was given it.
  --
  --  petName IS OUR OWN SPAWN PARAMETER, NOT VANILLA'S. Nothing in monster.lua or
  --  capturable.lua reads a `petName` config parameter -- capturable.optName goes
  --  to world.entityName instead -- so the port putting it in the spawn table does
  --  not by itself name anything. THIS is what makes that parameter mean something,
  --  and without it a rename would survive in petData and vanish on every respawn.
  local spawnName = config.getParameter("petName")

  --  THE TAG IS A SEPARATE PARAMETER, NOT INFERRED FROM THE NAME. Every unit
  --  item ships a default petName, so "has a name" is true for the whole fleet
  --  and would show a tag over all of it. petports_showNametag carries the
  --  player's actual choice, off by default, and the port sends both together.
  --
  --  BOTH ARE APPLIED HERE RATHER THAN WAITING FOR A PUSH, because the port only
  --  pushes on a settings change. Without this a respawned unit would come back
  --  wearing whatever the engine defaults to until somebody opened the pane.
  if type(spawnName) == "string" and spawnName ~= "" then
    petports_setUnitName(spawnName, config.getParameter("petports_showNametag", false))
  end

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
--  THE NAME OVER THIS UNIT, PUSHED BY THE PORT.
--
--  monster.setName AND monster.setDisplayNametag BOTH EXIST -- CONFIRMED
--  2026-09-01 by /entityeval on a deployed unit, which returned "function" for
--  each. That eval also returned "Utility Unit" for world.entityName, so a unit
--  is ALREADY NAMED before this ever runs: the engine takes the monstertype's
--  shortdescription as the entity name.
--
--  WHICH MEANS THE TAG, NOT THE NAME, IS WHAT THIS TURNS ON. Nothing switches
--  setDisplayNametag on for us -- vanilla only does it from capturable.update
--  and only under capturable.ownerUuid(), which a port-spawned unit has no pod
--  to provide. So an unnamed unit renders no tag at all, and that is the state
--  `show` false has to be able to get back to.
--
--  `show` IS A PARAMETER RATHER THAN name ~= nil BECAUSE THE NAME IS NEVER NIL.
--  A cleared name arrives here as the SPECIES with show false: the port resolves
--  it before pushing, because vanilla's tick loop renames anything whose
--  world.entityName reads empty to the literal "Pet". Passing the species keeps
--  that branch unreachable while the flag does the actual clearing.
--
--  CALLED FROM TWO PLACES, which is the point of it being a function. The port
--  pushes it on rename, and init applies the stored name at spawn -- see the
--  petName read there. A unit that only got the push would come back nameless
--  after every respawn.
function petports_setUnitName(name, show)
  if type(name) ~= "string" or name == "" then
    sb.logInfo("UNIT setUnitName REFUSED: %s is not a usable name",
      sb.printJson(name))
    return false
  end

  local ok, err = pcall(monster.setName, name)

  if not ok then
    sb.logInfo("UNIT setUnitName FAILED for %s: %s", tostring(name), tostring(err))
    return false
  end

  --  GUARDED SEPARATELY so a missing binding is reported rather than swallowed
  --  with the rename it accompanied. If the name changes and no tag appears,
  --  this line says which half failed.
  local okTag, errTag = pcall(monster.setDisplayNametag, show == true)

  if not okTag then
    sb.logInfo("UNIT setDisplayNametag FAILED: %s", tostring(errTag))
  end

  sb.logInfo("UNIT name set to %s, tag %s", tostring(name), tostring(show == true))
  return true
end

--  THE COLOUR OF THE RGB LAMP MODULE'S LIGHT.
--
--  A STATUS PROPERTY RATHER THAN A FIELD ON self, AND THAT IS THE WHOLE
--  MECHANISM. The light is drawn by a status effect's own animator, and a
--  status effect script runs in ITS OWN context -- it cannot see this file's
--  self. What it CAN see is the status controller it is attached to, so the
--  property is the shared surface between the two.
--
--  THE COLOUR COULD NOT TRAVEL WITH THE EFFECT. status.setPersistentEffects
--  takes effect NAMES and carries no payload, so the port cannot hand a colour
--  to the thing that uses it; it has to arrive separately and be waiting when
--  the effect looks. See pushUnitLight on the port side.
--
--  WRITTEN EVEN WITH NO EFFECT APPLIED, deliberately. The property is set
--  whether or not an RGB module is socketed, so a module socketed onto a unit
--  that already has a colour lights correctly on its first frame rather than
--  waiting for the next push.
--
--  CLAMPED A THIRD TIME. The pane clamps, the port clamps, and this clamps --
--  which is not paranoia about the other two but about the CALLER: this is a
--  global on a scripted entity and world.callScriptedEntity can reach it from
--  anywhere.
function petports_setLightColor(r, g, b)
  local function channel(value)
    value = tonumber(value)
    if value == nil then return 140 end

    value = math.floor(value)
    if value < 0 then return 0 end
    if value > 255 then return 255 end

    return value
  end

  local color = { channel(r), channel(g), channel(b) }

  --  A LIST, NOT A KEYED TABLE, because animator.setLightColor wants a Color
  --  and the effect script hands this straight to it without reshaping.
  local ok, err = pcall(status.setStatusProperty, "petports_lightColor", color)

  if not ok then
    sb.logInfo("UNIT setLightColor FAILED: %s", tostring(err))
    return false
  end

  sb.logInfo("UNIT light colour set to %s", sb.printJson(color))
  return true
end

function petports_setModuleEffects(effects, category, liquids, flags, baseTeam,
                                   fuelScale, speedScale)
  category = category or "petports_modules"
  effects = effects or {}

  petports_applyModuleFlags(flags or {}, baseTeam)

  --  THE PORT DECIDED THIS, THE UNIT ONLY MULTIPLIES BY IT. The chassis rate
  --  is this side's -- petports_fuelDrain, per monstertype -- and the module
  --  bonus is the port's. Neither knows the other's number and neither needs
  --  to. See burnFuel in petportsTaskAction.lua, which reads this off self.
  --
  --  A MISSING SCALE IS 1.0, NOT 0. An older port, or any push predating this
  --  argument, must leave the unit burning at its chassis rate; a nil treated
  --  as zero would make every such unit run forever on one tank.
  self.petportsFuelScale = tonumber(fuelScale) or 1.0

  --  THE SAME SPLIT FOR MOVEMENT SPEED -- arch.module.metabolism. The chassis
  --  owns walkSpeed, runSpeed and flySpeed; the port owns the multiplier, and
  --  petports_scaledSpeed is the one place it is ever applied.
  --
  --  A MISSING SCALE IS 1.0 FOR THE SAME REASON, and the failure here would be
  --  louder than a fuel one: nil read as zero is a unit that cannot move at
  --  all, which looks exactly like every pathing bug in this document.
  self.petportsSpeedScale = tonumber(speedScale) or 1.0

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
--------------------------------------------------------------------------------
--  THE TWO PathFinder SHADOWS THAT MAKE SWIM MODE PLANNABLE
--------------------------------------------------------------------------------
--
--  READ FROM VANILLA'S /scripts/pathing.lua, 2026-09-02, not inferred. Both of
--  these were quoted second-hand in this mod's comments for weeks; the file was
--  finally read and the quotes were right, which is why the shape below matches.
--
--  THE PROBLEM IN ONE LINE:
--
--      function PathFinder:canPathfind()
--        return mcontroller.onGround() or not mcontroller.baseParameters().gravityEnabled
--      end
--
--  A swim-mode unit has its gravity overridden by controlParameters, which
--  baseParameters() cannot see -- measured, see petports_freeMover's header. So
--  the second half is FALSE for a floating amphibious unit and the whole gate
--  reduces to onGround(). It plans when it happens to touch terrain and sits
--  there when it does not, which is exactly the intermittency measured
--  2026-09-02: "occasionally swims to the target, most of the time just sits".
--
--  IT IS TWO GATES, NOT ONE, AND THE SECOND ONE IS THE NASTY ONE. PathFinder:
--  explore re-asks on completion:
--
--      if result == true and self:canPathfind() then
--
--  so a search that FINISHES while the unit is floating has its result thrown
--  away, and because that branch does not clear self.aStar the finder re-explores
--  the same search forever without ever latching a path. A unit could therefore
--  fail even having started legally, if it drifted off the ground mid-search.

--  ALWAYS TRUE WHILE THE SWIM MODE MACHINE OWNS THE UNIT.
--
--  The vanilla test is not arbitrary: an actor that walks can only begin a
--  platformer search from a place it could stand, and one that flies has no such
--  constraint. Our free movers are exactly the second case, and the only reason
--  they fail the test is that the flag they would be recognised by is
--  unreadable. This restores the intended answer rather than widening it -- a
--  genuine walker still falls through to vanilla's own line.
--
--  `exiting` NEEDS THE BYPASS TOO, AND THAT IS NOT OBVIOUS, so it is its own
--  clause rather than folded into the one above. That mode deliberately keeps
--  gravityEnabled TRUE -- it wants Walk and Jump edges to get out of the water,
--  which is why petportsPathStart leaves its parameters alone. But it also
--  floats on liquidBuoyancy 1.0, so onGround() is false, and vanilla's gate is
--  `onGround() or not gravityEnabled` -- BOTH HALVES FALSE. The mode could
--  never plan anything.
--
--  MEASURED 2026-09-02, three times in one log:
--
--      UNIT swim mode aquatic -> exiting at [2552.52,1147.8]
--      UNIT standable for [2538,1184] -> [2538.5,1184.8]      <- resolver fine
--      UNIT approach ... moved 0 onGround false | hasPath nil aStar false
--
--  `aStar false` is the tell: PathFinder:find returned "pathfinding" from its
--  first line and never reached start(). Ten seconds of that failed the task,
--  the next dispatch was a submerged fish, and the mode flipped back -- so it
--  read as a unit that would not leave the water, which is what it was.
--
--  THE REMAINING BET, AND IT IS A REAL ONE. This lets the search START from open
--  water with gravity on; whether world.platformerPathStart can find a source
--  NODE there is the engine's business, not ours. Two things say it can: a
--  gravity-enabled submerged unit was planned 12 Swim edges on 2026-09-01, so
--  Swim nodes exist for a walking chassis in water; and petports_amphibious's
--  own header records Swim edges up to a surface followed by Jump arcs out as
--  measured in game. If the search instead returns false immediately, that is
--  the engine refusing a mid-water source and the answer is the two-leg exit --
--  swim to the waterline as a free mover, then flip -- not more of this.
--  THE SAME QUESTION, ASKED ABOUT A MODE THE UNIT IS NOT IN YET.
--
--  petports_swimModeTick needs to know whether a rebuild would be able to plan
--  AFTER the mode it is about to switch to takes effect. It cannot ask
--  petportsCanPathfind, which reads the mode the unit is still in and would
--  answer about the wrong one -- during a water exit the current mode is
--  `exiting`, which returns true unconditionally, while the mode being switched
--  TO is `land`, which needs ground the unit does not have.
--
--  ONE SPELLING, AND THAT IS THE WHOLE REASON THIS IS A SEPARATE FUNCTION
--  RATHER THAN A SECOND TEST WRITTEN INLINE. arch.pathing.oneanchor records
--  what the last duplicated predicate cost; petportsCanPathfind now delegates
--  here so there is exactly one copy of the rule.
--
--  THE AQUATIC ARM REPLACES A petports_freeMover CALL AND IS EQUIVALENT.
--  freeMover is `mode == AQUATIC or not gravityEnabled`; the first half is this
--  arm and the second half is the fall-through's second clause, so every input
--  lands on the same answer it did before. The gravity-disabled chassis --
--  aquatic and flyer, never gravitySwitchable, mode `land` for life -- reach the
--  fall-through and get exactly what they always got.
function petports_canPathfindIn(mode)
	if mode == PETPORTS_SWIM_MODE_AQUATIC then return true end
	if mode == PETPORTS_SWIM_MODE_EXITING then return true end
	return mcontroller.onGround() or not mcontroller.baseParameters().gravityEnabled
end

function petportsCanPathfind(finder)
	return petports_canPathfindIn(petports_swimMode())
end

--  VANILLA'S start, LINE FOR LINE, WITH TWO OVERWRITES.
--
--  IT SAID "ONE FIELD" UNTIL 2026-09-04, when the metabolism module added the
--  speed scaling below. Corrected here rather than left to read as agreement --
--  proc.pathing.supersede exists because a bold claim five sections from its
--  correction is the one the next reader believes.
--
--  THE SEAM IS THAT VANILLA ALREADY TREATS THIS TABLE AS A SCRATCH COPY:
--
--      local baseParameters = mcontroller.baseParameters()
--      baseParameters.airJumpProfile.jumpSpeed = jumpSpeed
--      self.aStar = world.platformerPathStart(source, target, baseParameters, options)
--
--  It mutates airJumpProfile before handing the table over, so the table is
--  demonstrably a per-call copy and writing one more field into it is the same
--  kind of act, not a new one.
--
--  WHY THIS IS THE ONLY WAY TO GET Fly EDGES. world.platformerPathStart picks
--  edge types from the PARAMETERS argument, and that argument comes from an
--  accessor no control override can reach. Without this the planner emits
--  Walk/Jump/Drop for a unit whose physics are flying.
--
--  ONLY IN AQUATIC MODE. `exiting` deliberately keeps gravity TRUE here, because
--  the entire point of that mode is to obtain a GROUND route out of the water.
--  petports_freeMover is false in `exiting`, so this leaves the table alone.
--
--  THE jumpModifier STAT LINE IS KEPT EVEN THOUGH A FREE MOVER NEVER JUMPS.
--  status.stat is a real call with real cost and vanilla's ordering is not ours
--  to trim; keeping it means this function stays a diff-able copy of vanilla's
--  when Starbound changes pathing.lua.
--  EVERY MOVEMENT SPEED THIS UNIT USES, SCALED BY ITS METABOLISM MODULE.
--
--  ONE SPELLING, AND THAT IS THE ONLY REASON THIS IS A FUNCTION RATHER THAN A
--  MULTIPLY AT EACH SITE. arch.pathing.oneanchor records what the last
--  duplicated predicate cost; there are FOUR places a base speed is read and a
--  fifth that scales the planner's copy, and they must not be able to disagree.
--
--  1.0 UNTIL THE PORT HAS PUSHED ONCE. A unit spawned and walking before its
--  first module push moves at its chassis speed, which is the only safe default
--  -- see petports_setModuleEffects for why nil must never read as zero here.
--
--  DEFINED ABOVE ITS FIRST CALLER DELIBERATELY. proc.tooling.localorder was hit
--  twice in two consecutive builds by a helper placed above the local it calls;
--  this is a global, so the hazard is the reverse -- but the ordering is free
--  and costs nothing to keep honest.
function petports_scaledSpeed(base)
	local value = tonumber(base)

	--  LOUD, NOT SILENT, AND THIS COST A TEST CYCLE. The first build returned
	--  `base` unchanged here and a caller handed it a nil field, so the whole
	--  metabolism module was a no-op on the mover with nothing in the log to say
	--  so -- fact.tooling.mergedrefusal, committed by a guard written to be
	--  careful. Change-gated because a per-tick line would bury the log.
	if value == nil then
		if self.petportsSpeedScaleComplaint ~= true then
			self.petportsSpeedScaleComplaint = true
			sb.logInfo("UNIT petports_scaledSpeed got a non-number (%s) -- "
				.. "the caller is reading a field that does not exist, and this "
				.. "scaling is doing nothing", tostring(base))
		end

		return base
	end

	self.petportsSpeedScaleComplaint = nil

	return value * (tonumber(self.petportsSpeedScale) or 1.0)
end

function petportsPathStart(finder, sourcePosition, targetPosition)
	finder.target = targetPosition

	local baseParameters = mcontroller.baseParameters()
	local jumpSpeed = baseParameters.airJumpProfile.jumpSpeed
	jumpSpeed = jumpSpeed + (jumpSpeed * status.stat("jumpModifier"))
	baseParameters.airJumpProfile.jumpSpeed = jumpSpeed

	--  THE SECOND DEVIATION, AND THE ONE THAT MAKES THE METABOLISM MODULE SAFE.
	--
	--  THE PLANNER MUST BE TOLD THE SPEED THE UNIT WILL ACTUALLY TRAVEL AT.
	--  mcontroller.controlParameters is invisible to baseParameters()
	--  (fact.unit.movementparams), so scaling only the MOVER would leave A*
	--  drawing arcs from {0, +-walkSpeed, +-runSpeed} at the CHASSIS speed while
	--  the body moved faster. petportsArcMover steers to the plan's vx and a
	--  Jump edge's source is an exact point, so the unit would arrive at its own
	--  jump point early and overshoot it -- which is exactly what
	--  JUMP_APPROACH_SLOWDOWN exists to prevent and what an eight-tile fall was
	--  once measured as.
	--
	--  SAME SEAM AS THE GRAVITY OVERRIDE BELOW, and safe for the same reason
	--  vanilla's own airJumpProfile write is: this table is a per-call copy.
	baseParameters.walkSpeed = petports_scaledSpeed(baseParameters.walkSpeed)
	baseParameters.runSpeed  = petports_scaledSpeed(baseParameters.runSpeed)
	baseParameters.flySpeed  = petports_scaledSpeed(baseParameters.flySpeed)

	--  THE GRAVITY DEVIATION.
	if petports_freeMover() then
		baseParameters.gravityEnabled = false
	end

	finder.aStar = world.platformerPathStart(sourcePosition, finder.target,
		baseParameters, finder.options)
end

--  IS THIS UNIT A FREE MOVER RIGHT NOW?
--
--  THE MODE IS ASKED FIRST, AND IT HAS TO BE, BECAUSE THE PHYSICS CANNOT BE READ
--  BACK. Measured 2026-09-02, in the one log this question was built to answer:
--
--      UNIT swim mode land -> aquatic ... asked gravity false,
--      baseParameters now reports gravityEnabled true, onGround false,
--      liquidMovement true, freeMover false
--
--  The unit was floating -- onGround false, not sinking, the control override
--  plainly in effect -- and baseParameters still reported gravityEnabled TRUE.
--  So an ActorMovementController control override changes the PHYSICS and is
--  invisible to the accessor. There is no applyParameters on a monster to write
--  the base with (see petports_assertSwimMode), so nothing can ever make that
--  accessor agree with the mode.
--
--  WHAT IT COST TO NOT ASK THE MODE: 1684 "no standable column" failures in 44
--  seconds. The unit floated correctly and every resolver still treated it as a
--  walker, so it hunted for a seabed under a submerged port, forever.
--
--  THE FALL-THROUGH IS THE ORIGINAL TEST AND STILL ANSWERS FOR EVERYONE ELSE.
--  The aquatic and flyer chassis are gravity-disabled in their monstertype, are
--  not gravitySwitchable, and hold mode `land` for their whole lives -- so they
--  reach the second line and get exactly the answer they always got.
--
--  THIS IS THE SINGLE PREDICATE. Six other places used to read
--  baseParameters().gravityEnabled directly and now call this instead, because
--  with the mode in play those two questions have different answers and the
--  codebase cannot afford a second spelling of "is this thing flying" -- see
--  arch.pathing.oneanchor for what the last duplicate predicate cost.
function petports_freeMover()
  if petports_swimMode() == PETPORTS_SWIM_MODE_AQUATIC then return true end
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

  --  THREE ANSWERS, NOT TWO. This used to accumulate one `submerged` flag with
  --  an AND, which answers "is ALL of me in water" and calls everything else
  --  air. A body straddling a waterline is not air. The flyer was cleared to
  --  hover at the surface inside the flooded half of a shipping container with
  --  its bottom row submerged, and the physics did the rest: buoyancy on the wet
  --  half, none on the dry, and it slid under and stuck.
  --
  --  "mixed" IS A REAL ANSWER and petports_mediumAllows refuses it for a free
  --  mover, because a chassis that cannot swim must be clear of the water and
  --  one that cannot leave it must be under. Neither wants to be half in.
  --
  --  WALKERS ARE UNAFFECTED. petports_mediumAllows returns early for a gravity
  --  chassis -- its medium is physics, and wading is a thing walkers do -- and
  --  that early return sits below the "forbidden" check, which still fires.
  --
  --  THE THRESHOLD IS STILL PETPORTS_SUBMERGED_FILL. A row at half fill counts
  --  as dry here, so a body resting in shallow water reads as air and is
  --  allowed. That is unchanged behaviour and NOT known to be right -- it is
  --  simply not what the container measured, and widening it to "any liquid at
  --  all" would ground a flyer in rain. If a unit is later seen dragging through
  --  shallows, this is the line to revisit.
  local submerged, anySubmerged = true, false

  for row = bottom, top do
    local level = world.liquidAt({ x, row + 0.5 })

    --  world.liquidAt returns {liquidId, level} or nil. A nil is air, which is
    --  a definite answer and not a missing one.
    local fill = (level ~= nil) and (level[2] or 0) or 0

    if fill >= PETPORTS_HARMFUL_FILL and petports_liquidDenied(level[1]) then
      return "forbidden"
    end

    if fill < PETPORTS_SUBMERGED_FILL then
      submerged = false
    else
      anySubmerged = true
    end
  end

  if submerged then return "swim" end
  if anySubmerged then return "mixed" end
  return "air"
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

--  WHAT THIS CHASSIS PERMANENTLY IS, NOT WHAT IT IS DOING RIGHT NOW.
--
--  THE SWIM MODE MUST NOT REACH THIS ANSWER. petports_freeMover() became
--  mode-aware so that resolvers would treat a swimming amphibious unit as a free
--  mover, which is right for THEM and wrong here: this table is what the port
--  asks in order to decide whether the socket is a home, and a home is a
--  property of the chassis and the terrain, not of what the pet is up to.
--
--  MEASURED 2026-09-02, three tenths of a second apart:
--
--      UNIT swim mode diving -> aquatic ... freeMover true
--      PETPORT RETIRING unit: the port is out of the water and this chassis
--          cannot leave it (footprint wet false, dry true)
--
--  The unit answered "free mover, swims, cannot fly" because it happened to be
--  mid-dive, so the port saw a fish in a dry socket and retired it -- writing
--  state and cargo back to the item and shutting the door on a working pet that
--  was doing exactly what it had been dispatched to do.
--
--  A GRAVITY-SWITCHABLE CHASSIS IS A WALKER, FOR THIS QUESTION AND ALWAYS. It
--  can swim, and that is expressed by avoidLiquid being false, which is what
--  earns it PETPORTS_HABITAT_AMPHIBIOUS -- "any medium" -- rather than being
--  sorted into the free-mover ladder where a dry port has no cause that fits it.
--  Reporting freeMover here would put it in that ladder for as long as the mode
--  happened to last, and the port polls on its own clock.
function petports_capabilities()
  local freeMover = petports_freeMover()

  if petports_gravitySwitchable() then freeMover = false end

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

  --  HALF IN IS OUT, FOR EVERY FREE MOVER. A flyer here has buoyancy on one half
  --  of its body and none on the other and slides under; a swimmer here is
  --  hauling itself against the surface. There is no chassis this is right for,
  --  so it is refused before the fly/swim split rather than inside it.
  if medium == "mixed" then
    return false, "straddling the waterline, which no free-moving chassis can hold"
  end

  if media.fly then return true, "air" end
  return false, "not submerged and this chassis cannot fly"
end

--------------------------------------------------------------------------------
--  SWIM MODE -- A CHASSIS THAT CHANGES WHAT KIND OF MOVER IT IS
--------------------------------------------------------------------------------
--
--  ONE CHASSIS, THREE MODES, AND THE MODE IS THE SIGNAL RATHER THAN GRAVITY.
--
--    land      gravityEnabled true,  liquidBuoyancy 0.0 -- an ordinary walker
--    aquatic   gravityEnabled false                     -- the aquatic chassis
--    exiting   gravityEnabled true,  liquidBuoyancy 1.0 -- gravity, but afloat
--
--  WHY THIS EXISTS. An amphibious unit dispatched to a fish was resolving a spot
--  on the SEABED under it, because every walker resolver in this mod answers
--  "where can a body stand". Measured 2026-09-02: unit at [2493.18,1128.8], fish
--  at [2493.97,1136.25], gap 7.45 against FISH_REACH 5.0. There is no standing
--  answer to a fish, and assuming ground beneath one is wrong in open ocean
--  regardless. A submerged unit has to stop being a walker.
--
--  petports_freeMover() IS `not baseParameters().gravityEnabled`, SO ONE WRITE
--  MOVES THE WHOLE STACK. Flipping gravity off gives, in a single call: the
--  controlFly branch of the swim mover (flySpeed, liquidForce, liquidImpedance,
--  instead of walkSpeed through controlApproachVelocity), standableNear
--  resolving open water through petports_flyPointNear instead of hunting for a
--  seabed, the descend-to-floor block skipped as free movers are exempt,
--  canPathfind no longer requiring onGround, Fly edges out of
--  platformerPathStart, and mustEndOnGround defaulting false.
--
--  THE MODE IS STORED SEPARATELY FROM THE BOOLEAN ON PURPOSE. Reading gravity
--  back to infer intent conflates "what the physics are" with "what we decided",
--  and those differ for one tick after every write and forever if a write fails.
--  Callers branch on petports_swimMode(); gravityEnabled is a consequence.
--
--  THE PHYSICS ARE WRITTEN PER TICK BY petports_assertSwimMode, NOT ONCE HERE.
--  An earlier version of this header argued for one atomic applyParameters call
--  per transition, on the grounds that a per-tick assertion has to be reachable
--  from every code path the unit can be in. The argument was fine and the API
--  was imaginary: mcontroller.applyParameters does not exist on a monster and
--  every pather build crashed on it. That reachability problem is now real and
--  is answered by two assertion sites -- the task action and petBehavior --
--  which between them cover holding a task and not holding one.
--
--  liquidBuoyancy 1.0 IS WHAT MAKES `exiting` POSSIBLE AT ALL. Gravity has to be
--  ON for the engine to plan a ground route -- PathFinder:start hands
--  baseParameters() to platformerPathStart -- and gravity with the chassis's own
--  buoyancy of 0.0 sinks the unit to the seabed of whatever it is standing in.
--  1.0 is vanilla's own fish value, recorded in petports_aquatic's header.
--
--  KNOWN OPEN QUESTION, DELIBERATELY NOT DESIGNED AROUND YET. PathFinder:
--  canPathfind is `onGround() or not gravityEnabled`, and in `exiting` both are
--  false while the unit floats -- so the search may refuse to start from open
--  water. The fish test does not exercise this, since a submerged target keeps
--  the unit `aquatic` throughout; the RETURN LEG to the port does. That is the
--  line to read in the first log, and the fallback if it fails is to treat
--  `exiting` as a two-leg move: free-mover to the waterline, then flip.
PETPORTS_SWIM_MODE_LAND = "land"
PETPORTS_SWIM_MODE_AQUATIC = "aquatic"
PETPORTS_SWIM_MODE_EXITING = "exiting"

--  THE FOURTH MODE: COMMITTED TO A TRAJECTORY, NOT STEERING.
--
--  gravityEnabled TRUE and controlDown held. It is the only mode entered by an
--  ACT rather than by a position -- the other three are read off where the body
--  is, and this one is chosen at the moment the unit steps off a board and holds
--  until it is wet or it has failed.
--
--  IT EXISTS BECAUSE air -> land IS UNCONDITIONAL. A diving unit is in air, and
--  without a mode of its own the tick would decide it was a walker mid-flight,
--  rebuild the pather, and re-resolve an approach against a fish it cannot reach
--  from the sky. That branch cannot be softened -- the exit path depends on it
--  being absolute -- so the exception is a mode instead.
PETPORTS_SWIM_MODE_DIVING = "diving"

--  HOW NEARLY ABOVE THE HOLE COUNTS AS DIRECTLY ABOVE IT.
--
--  A BOARD OVER THE WATER NEEDS NO ARC AT ALL -- step off, fall in. Measured
--  2026-09-02, two of four boards were exactly aligned (launch [2519.5,1152.8]
--  over surface [2519.5,1149.5]) because the launch scan tends to pick platforms
--  above pools. The aligned case is both the commonest and the most reliable, so
--  it is its own path with no velocity written and nothing to solve or fail.
PETPORTS_DIVE_DROP_ALIGN = 1.5

--  HOW LONG PAST THE ARC'S OWN PREDICTION BEFORE A DIVE HAS FAILED.
PETPORTS_DIVE_GRACE = 3.0

--  How many points along the flight to test for clearance before committing.
PETPORTS_DIVE_SWEEP_SAMPLES = 12

--  THE HOP. UPWARD VELOCITY WRITTEN AT LAUNCH, IN TILES PER SECOND.
--
--  controlDown ALONE DOES NOT DROP A GROUNDED UNIT THROUGH A PLATFORM. Measured
--  2026-09-02: held from a standing start it reads as a crouch and nothing else
--  happens. The recorded fault in petportsTaskAction is about not knowing WHEN
--  the fall-through ends; this is a different and simpler one -- from rest it
--  does not begin. petportsTaskAction's answer was scootThroughPlatform, placing
--  the body through with setPosition, and that remains the right tool for a
--  pathed drop that must land on a known floor. A dive is not that: it wants to
--  leave the board with some authority anyway, and a hop gets the unit airborne
--  so controlDown has a descent to apply to.
--
--  SIZED BY THE RISE IT BUYS, NOT BY FEEL. apex = vy0^2 / (2*g), and g here is
--  world gravity times this chassis's gravityMultiplier of 1.5 -- 120 on the
--  measured test world, the same figure the jump arcs were tuned against. So:
--
--      vy0  6  ->  0.15 tiles      two pixels; does not clear anything
--      vy0 12  ->  0.60 tiles      lifts the feet, ~0.2 s of air
--      vy0 45  ->  8.44 tiles      the chassis's actual jump, far too much
--
--  TWELVE. Enough to unstick the feet and let the descent begin, and nowhere
--  near a jump. Every tile of rise is another tile of sweep that must be clear
--  above a board frequently sitting under a low ceiling, and an apex is exactly
--  what airJumpProfile's collisionCancelled kills an arc for touching.
PETPORTS_DIVE_HOP = 12.0

--  HOW CLOSE THE FEET MUST BE TO THE BOARD BEFORE THE DIVE IS SOLVED.
--
--  TIGHTER THAN THE ARRIVAL LATCH, AND NOT A REPLACEMENT FOR IT. The pather
--  parks the unit around a tile short -- measured 2026-09-02, arrival gaps of
--  0.99, 1.21 and 1.23 -- so raising the latch to this would simply never fire.
--  The latch stays generous and says "you are here"; this says "you are ON it",
--  and the gap between them is closed by walking rather than by rounding.
--
--  IT MATTERS BEYOND TIDINESS. The board was chosen because a flight FROM IT is
--  clear, and the sweep runs from wherever the unit actually stands. A tile of
--  slop is a tile of different terrain, which is the likeliest reason a board
--  that should work reports the flight blocked.
PETPORTS_DIVE_BOARD_FOOT = 0.4

--  How long to shuffle onto the board before giving up and diving from here.
--
--  A DIVE FROM SLIGHTLY OFF THE BOARD IS STILL SWEPT AND STILL SAFE, so this
--  fails toward diving rather than toward standing still. If the last half tile
--  is unwalkable -- a lip, a corner, a body width -- waiting forever for it
--  would turn a cosmetic imperfection into a stalled task.
PETPORTS_DIVE_SHUFFLE_TIMEOUT = 1.5

--  MAY THIS CHASSIS SWITCH AT ALL?
--
--  A STATIC DECLARATION, NOT AN INFERENCE. The drone and the sinker are walkers
--  that must never do this, and the aquatic and flyer chassis are already free
--  movers that must never be handed a gravity write. Deriving permission from
--  some combination of canSwim and avoidLiquid would make every future chassis a
--  question; a flag makes it a decision recorded in the monstertype.
--
--  MEMOISED. config.getParameter is a per-call lookup and this is asked on paths
--  that run per tick.
function petports_gravitySwitchable()
	if self.petportsGravitySwitchable == nil then
		self.petportsGravitySwitchable =
			config.getParameter("petports_gravitySwitchable", false) and true or false
	end

	return self.petportsGravitySwitchable
end

function petports_swimMode()
	return self.petportsSwimMode or PETPORTS_SWIM_MODE_LAND
end

--------------------------------------------------------------------------------
--  GETTING INTO THE WATER: FINDING THE HOLE AND SOMEWHERE TO JUMP FROM
--------------------------------------------------------------------------------
--
--  THE PROBLEM. A unit standing on dry land with a fish task is a WALKER --
--  petports_desiredSwimMode will not make it a swimmer until it is fully under,
--  and it will not get fully under by accident. Every walker resolver answers
--  "where can a body stand", so asking one about a fish returns the seabed
--  beneath it, and over real water there is no seabed within the search box and
--  the answer is nil. The task then fails at dispatch without the unit moving.
--
--  WHAT THIS PRODUCES. Two points: the ENTRY, a spot on the water's surface the
--  unit can fall into, and the LAUNCH, dry standable ground near it that the
--  unit can walk to. Increment one aims the fish approach at the launch point,
--  so the unit walks to the diving board. The dive itself is separate.
--
--  WHY THE SURFACE IS TRACED RATHER THAN LOOKED UP. world.oceanLevel exists and
--  is used elsewhere in this mod, and it is WRONG FOR THIS. It reports the
--  world's ocean level, which says nothing about the surface of the particular
--  pool a fish is in -- a player-built tank thirty tiles up has a surface
--  oceanLevel has never heard of, and a cave pool below sea level has one too.
--  The premise here is adversarial player terrain, so the only trustworthy
--  surface is the one reached by walking through water contiguously from the
--  fish. Anything cheaper answers a different question.
--
--  THE TRACE IS A FLOOD THAT PREFERS UP, and prefers up because liquid in
--  Starbound settles downward: the top of a connected body of water is where its
--  air boundary is, and every other direction is a detour. It branches sideways
--  only where the ceiling is solid, which is exactly the capped-tank case that
--  makes this necessary at all. Ceilings above the surface are not modelled and
--  do not need to be -- once air is reached the question is answered.

--  How many tiles the trace may examine before giving up. Bounds the cost of a
--  sealed or enormous body of water; a pool that needs more than this to find
--  its own surface is not one a unit should be swimming in.
PETPORTS_DIVE_TRACE_BUDGET = 400

--  How far above the fish the trace may look, in tiles.
PETPORTS_DIVE_TRACE_RISE = 96

--  How far the TRACE may reach sideways past the fish and the unit.
--
--  MUCH WIDER THAN THE BOARD WINDOW, AND THEY ARE NOW SEPARATE NUMBERS. Sharing
--  one window was right when the complaint was "the unit's own platform is not a
--  candidate"; it is wrong for the trace, which is not looking for footing at
--  all. It is looking for the EDGE OF A LID, and a lid is as wide as whatever
--  the player built.
--
--  MEASURED 2026-09-02 on an islet with the port on top and the fish directly
--  beneath: "no surface within 400 tiles ... sealed, or a pool larger than the
--  budget". The budget was NOT the constraint. Simulated against the same shape,
--  a 12-tile window fails on any islet wider than about twenty tiles while a
--  48-tile reach solves all of them inside the SAME 400 budget -- the flood was
--  filling a boxed-in region it could never escape, not searching too little.
--
--  IT COSTS ALMOST NOTHING IN OPEN WATER. The frontier pops the highest node
--  first, so a pool with sky above it is answered in the four to seven tiles
--  measured previously; this bound only engages when the water is genuinely
--  roofed, which is when it is needed.
PETPORTS_DIVE_TRACE_REACH = 48

--  How far the search reaches SIDEWAYS PAST the two columns that matter.
--
--  THE WINDOW SPANS THE FISH AND THE UNIT, NOT JUST THE FISH, and that is the
--  fix rather than a bigger number. Both the trace and the board scan used to be
--  centred on the fish -- the trace at 24 tiles, the boards at 12 -- so a unit
--  parked on a platform directly over the water was never considered, because
--  the fish happened to be off to the left. Measured 2026-09-02: "2 opening(s)
--  found near [2503.08,1135.13] but no dry footing within 12 tiles can see any
--  of them", over and over, while the unit stood on perfectly good footing above
--  the same pool.
--
--  THE UNIT'S OWN COLUMN IS THE ONE COLUMN WE KNOW IT CAN REACH. Leaving it out
--  of the search is the least defensible omission available: every other
--  candidate needs a walk that might not exist, and this one is already stood on.
PETPORTS_DIVE_SPAN_MARGIN = 12

--  Hard cap on the width of that window, in tiles.
--
--  A FISH AND A UNIT CAN BE ARBITRARILY FAR APART, and the span is derived from
--  their separation, so without this a distant fish turns a bounded search into
--  an unbounded one. Clamped toward the FISH when it bites, because the fish is
--  what the task is about and openings near it are the ones worth having.
PETPORTS_DIVE_SPAN_MAX = 72

--  RETIRED: PETPORTS_DIVE_LAUNCH_SPREAD.
--
--  It bounded the board scan at 12 tiles either side of the hole, which is the
--  window that hid the unit's own platform from the search. Replaced by
--  PETPORTS_DIVE_SPAN_MARGIN and PETPORTS_DIVE_SPAN_MAX, which span the fish and
--  the unit instead of orbiting one of them. Named here rather than deleted
--  silently, because "widen the launch spread" is the obvious wrong fix and this
--  says why it was not the answer.

--  WHAT COUNTS AS SOLID TO A DIVE, WHICH IS NOT WHAT COUNTS AS STANDABLE.
--
--  PLATFORMS ARE DELIBERATELY ABSENT. A dive holds controlDown and falls through
--  them, so a platform over a pool is not a lid -- treating one as solid would
--  make the trace branch sideways looking for a way around something it can go
--  straight through. STANDABLE_TILE_SET in petportsTaskAction includes Platform
--  for the opposite reason: a platform IS somewhere to stand.
--
--  Null is included: an unloaded chunk is not somewhere to aim a body.
PETPORTS_DIVE_SOLID_SET = { "Null", "Block", "Slippery", "Dynamic" }

--  VISUAL DEBUG FOR THE DIVE SEARCH.
--
--  RECORDED ONCE, REPLAYED EVERY TICK, AND THAT SPLIT IS FORCED. world.debugPoint
--  and world.debugLine draw for ONE FRAME -- they are not persistent markers, so
--  anything drawn from inside the trace would flash for a single tick and be
--  gone. The trace also runs once and caches, so by the time a human is looking
--  at the unit the search is long over. Capture during the search, draw forever
--  after: that is what these two halves are.
--
--  ONLY VISIBLE WITH /debug ON. The calls are harmless otherwise, but they are
--  not free -- a full trace is up to PETPORTS_DIVE_TRACE_BUDGET points every
--  tick -- so the flag exists to turn the recording off wholesale for a release
--  build rather than to make it pretty.
PETPORTS_DIVE_DEBUG = true

--  Colours are {r, g, b, a}, 0-255.
PETPORTS_DIVE_COLOR_WATER   = { 60, 120, 255, 160 }   --  traced through liquid
PETPORTS_DIVE_COLOR_BLOCKED = { 255, 80, 80, 200 }    --  ceiling was solid here
PETPORTS_DIVE_COLOR_NARROW  = { 255, 160, 0, 230 }    --  surface, body would not fit
PETPORTS_DIVE_COLOR_FOOTING = { 200, 200, 80, 180 }   --  launch scan probed here
PETPORTS_DIVE_COLOR_ENTRY   = { 0, 255, 255, 255 }    --  the hole we picked
PETPORTS_DIVE_COLOR_LAUNCH  = { 80, 255, 80, 255 }    --  the board we jump from

local function diveDebugReset()
	if not PETPORTS_DIVE_DEBUG then return end
	self.petportsDiveMarks = {}
	self.petportsDiveEntryMark = nil
	self.petportsDiveLaunchMark = nil
	self.petportsDiveFishMark = nil
end

--  DROP THE PLAN AND EVERYTHING DRAWN FOR IT.
--
--  CALLED WHENEVER NO FISH TASK IS HELD, which is what stops a finished or
--  failed dive leaving its markers on screen forever. Measured 2026-09-02: the
--  launch point and the whole trace stayed lit after the task was over, so the
--  display described a plan nothing was acting on -- worse than no display,
--  because it looks current.
--
--  THE PLAN GOES WITH THE MARKS, not just the marks. They describe the same
--  decision and a surviving plan would be re-adopted by the next fish task
--  through the taskId check, which is exactly the staleness this removes.
function petports_diveForget()
	--  THE FLIGHT GOES FIRST, AND FORGETTING IT IS NOT OPTIONAL. petports_diving
	--  reading true holds the mode at `diving`, and that mode holds controlDown
	--  UNCONDITIONALLY -- which on a gravity chassis means falling through every
	--  platform it tries to stand on, forever. If a fish task ends while a dive
	--  is in the air, this is the only thing that stops it.
	self.petportsDiveFlight = nil

	self.petportsDivePlan = nil
	self.petportsDiveEntry = nil
	self.petportsDivePuddleNoted = nil

	--  Cleared with the plan so a pending re-resolve cannot leak into whatever
	--  the unit does next.
	self.petportsDiveRetarget = nil
	self.petportsDiveMarks = nil
	self.petportsDiveEntryMark = nil
	self.petportsDiveLaunchMark = nil
	self.petportsDiveFishMark = nil
end

local function diveDebugMark(position, color)
	if not PETPORTS_DIVE_DEBUG then return end
	if self.petportsDiveMarks == nil then self.petportsDiveMarks = {} end
	table.insert(self.petportsDiveMarks, { position, color })
end

--  DRAW WHAT THE LAST TRACE FOUND. Called every tick; see the header above.
--
--  THE TWO LINES ARE THE WHOLE STORY AT A GLANCE: unit to launch is the walk,
--  launch to entry is the dive. If the second one crosses terrain, the arc was
--  never going to work and the trace picked the wrong hole.
function petports_diveDebugDraw()
	if not PETPORTS_DIVE_DEBUG then return end

	for _, mark in ipairs(self.petportsDiveMarks or {}) do
		world.debugPoint(mark[1], mark[2])
	end

	local here = mcontroller.position()

	if self.petportsDiveFishMark ~= nil then
		world.debugText("fish", self.petportsDiveFishMark,
			PETPORTS_DIVE_COLOR_WATER)
	end

	if self.petportsDiveLaunchMark ~= nil then
		world.debugPoint(self.petportsDiveLaunchMark, PETPORTS_DIVE_COLOR_LAUNCH)
		world.debugLine(here, self.petportsDiveLaunchMark,
			PETPORTS_DIVE_COLOR_LAUNCH)
		world.debugText("launch", self.petportsDiveLaunchMark,
			PETPORTS_DIVE_COLOR_LAUNCH)
	end

	if self.petportsDiveEntryMark ~= nil then
		world.debugPoint(self.petportsDiveEntryMark, PETPORTS_DIVE_COLOR_ENTRY)
		world.debugText("entry", self.petportsDiveEntryMark,
			PETPORTS_DIVE_COLOR_ENTRY)

		--  From the board, not from the unit: this line is the DIVE, and drawing
		--  it from wherever the unit currently stands would make a good plan look
		--  like it passes through a cliff while the unit is still walking over.
		local from = self.petportsDiveLaunchMark or here
		world.debugLine(from, self.petportsDiveEntryMark,
			PETPORTS_DIVE_COLOR_ENTRY)
	end
end

local function tileIsWater(x, y)
	return petports_mediumAtPoint({ x + 0.5, y + 0.5 }) == "swim"
end

local function tileIsSolid(x, y)
	return world.pointTileCollision({ x + 0.5, y + 0.5 }, PETPORTS_DIVE_SOLID_SET)
end

--  IS THE HOLE WIDE ENOUGH FOR THIS BODY?
--
--  THE BODY IS 1.6 WIDE, WHICH NEEDS TWO CLEAR TILES, NOT ONE. That width is not
--  incidental -- petports_amphibious's collisionPoly comment records it as
--  deliberately above 1.5 so the pathfinder rejects one-tile tunnels. A hole the
--  trace is delighted with can still be a slot the unit cannot fit through, and
--  the dive is ballistic and cannot correct, so this is checked before anything
--  is aimed at it rather than discovered on impact.
--
--  ASKED WITH THE REAL BOUNDS AT THE REAL POINT, so it answers for the body that
--  is actually going there rather than for a tile count. Same predicate shape
--  validStandingPosition uses for its own clearance half.
--  CAN THE BOARD SEE THE HOLE?
--
--  ITS OWN HELPER, NOT flySighted. That one is declared far below this point and
--  would be nil here -- Lua locals are not hoisted, which this file has been
--  bitten by before. It also uses FLY_TILE_SET, and a PLATFORM between a board
--  and the water is not a wall to something that is about to drop through one.
--  PETPORTS_DIVE_SOLID_SET is the set that means "solid to a dive".
local function diveSighted(from, to)
	return not world.lineTileCollision(from, to, PETPORTS_DIVE_SOLID_SET)
end

--  IS THERE A PLATFORM UNDER THE FEET, AND ONLY A PLATFORM?
--
--  THE DROP-THROUGH RETRY IS MEANINGLESS WITHOUT ONE, AND WORSE THAN
--  MEANINGLESS. controlJump with controlDown drops through a platform; on solid
--  ground the same pair is just a jump, and this chassis's airJumpProfile
--  jumpSpeed of 45 at g 120 is an 8.44 tile apex.
--
--  MEASURED 2026-09-02, the cleanest repro of it:
--
--      UNIT DIVE launched ... aligned drop-through, no hop, predicted 0.234523 s
--      UNIT DIVE SUCCEEDED ... (rose 8.00378 tiles above the board, drop-through)
--
--  Eight tiles on a dive solved for none. It reached the water in the end, which
--  is why it logged SUCCEEDED, but it went up a storey first. The other three
--  drop-throughs in the same log rose 0.2, 0.99 and 1.06 -- those had a platform
--  and released; this one did not, so the jump simply happened.
--
--  ONLY A PLATFORM. A tile that is BOTH -- a platform drawn over solid, or a
--  solid tile the probe clips -- cannot be fallen through either, so solid is
--  tested first and wins.
local function platformUnderfoot()
	local position = mcontroller.position()
	local bounds = mcontroller.boundBox()

	--  Half a tile below the soles: inside the tile being stood on, not inside
	--  the body.
	local probe = { position[1], position[2] + bounds[2] - 0.5 }

	if world.pointTileCollision(probe, PETPORTS_DIVE_SOLID_SET) then return false end

	return world.pointTileCollision(probe, { "Platform" })
end

--  How far below the feet still counts as water a walker can wade.
PETPORTS_WADE_DEPTH = 4

--  IS THERE A BOTTOM CLOSE ENOUGH TO WALK ON?
--
--  THIS IS WHAT SEPARATES WADING FROM FALLING IN, and until 2026-09-02 nothing
--  did. A walker crossing a shin-deep pool and a walker that has just fallen off
--  a cliff into open ocean report the same medium, hold the same kind of task,
--  and want opposite things -- and the mode machine was answering `land` to
--  both because only a FISH task was allowed to make a swimmer.
--
--  MEASURED: a unit missed its exit jump, fell back into deep water holding an
--  upcycle task, and sank 54 tiles over 17 seconds at a steady 3 tiles a second.
--  Nothing stopped it. The progress watchdog counts distance MOVED, and a unit
--  falling is moving -- 15 tiles per five-second window against the 2.5 it needs
--  -- so the one safeguard that could have caught it read the sink as healthy
--  progress. It recovered only when the task failed on its own and left no task
--  at all.
--
--  SOLID ONLY, AND PLATFORMS COUNT. Anything that stops a body is a floor worth
--  standing on for this question; what matters is whether walking is an option
--  at all, not whether it is a good one.
local function wadeableBottom()
	local position = mcontroller.position()
	local bounds = mcontroller.boundBox()

	local feet = position[2] + bounds[2]

	return world.rectTileCollision({
		position[1] + bounds[1], feet - PETPORTS_WADE_DEPTH,
		position[1] + bounds[3], feet
	}, { "Null", "Block", "Slippery", "Dynamic", "Platform" })
end

local function bodyFitsAt(position)
	local box = rect.translate(mcontroller.boundBox(), position)
	return not world.rectTileCollision(box, PETPORTS_DIVE_SOLID_SET)
end

--  TRACE UP FROM THE FISH TO THE SURFACE OF THE WATER IT IS ACTUALLY IN.
--
--  Returns the entry position, or nil and a reason.
local function traceSurface(from, spanLow, spanHigh)
	local startX = math.floor(from[1])
	local startY = math.floor(from[2])

	if not tileIsWater(startX, startY) then
		return nil, "the fish is not in water at " .. sb.printJson(from)
	end

	--  Visited set keyed by tile, and a frontier walked highest-first so the
	--  trace climbs before it spreads.
	diveDebugReset()
	self.petportsDiveFishMark = { from[1], from[2] }

	local seen = { [startX .. "," .. startY] = true }
	local frontier = { { startX, startY } }
	local entries = {}
	local examined = 0

	while #frontier > 0 and examined < PETPORTS_DIVE_TRACE_BUDGET do
		--  Highest node in the frontier. A linear scan rather than a heap: the
		--  frontier is bounded by the budget and this runs once per task.
		local bestAt = 1
		for i = 2, #frontier do
			if frontier[i][2] > frontier[bestAt][2] then bestAt = i end
		end

		local node = table.remove(frontier, bestAt)
		examined = examined + 1

		local x, y = node[1], node[2]

		diveDebugMark({ x + 0.5, y + 0.5 }, PETPORTS_DIVE_COLOR_WATER)

		--  THE TILE ABOVE DECIDES EVERYTHING.
		if not tileIsWater(x, y + 1) then
			if not tileIsSolid(x, y + 1) then
				--  Air above water: this is a surface of this body. Aim at the
				--  water tile itself rather than the air above it, so the arc
				--  ends INSIDE the liquid and momentum carries the body under.
				local entry = { x + 0.5, y + 0.5 }

				if bodyFitsAt(entry) then
					--  COLLECTED, NOT RETURNED. The first surface the body fits
					--  through is not necessarily the one worth aiming at --
					--  pickBoardAndEntry pairs every opening against every board
					--  rather than taking either on its own. Walking on costs
					--  nothing: these tiles were being visited regardless and the
					--  budget is unchanged.
					table.insert(entries, entry)
					diveDebugMark(entry, PETPORTS_DIVE_COLOR_ENTRY)
				else
					--  Air over water, refused: the body does not fit. Marked
					--  distinctly, because "no surface" and "every surface is a
					--  slot" are different terrain problems.
					diveDebugMark(entry, PETPORTS_DIVE_COLOR_NARROW)
				end
			end

			if tileIsSolid(x, y + 1) then
				diveDebugMark({ x + 0.5, y + 1.5 }, PETPORTS_DIVE_COLOR_BLOCKED)
			end

			--  Solid above, or a hole too tight: spread sideways along this row.
			for _, dx in ipairs({ -1, 1 }) do
				local nx = x + dx
				local key = nx .. "," .. y

				if not seen[key]
				   and nx >= spanLow and nx <= spanHigh
				   and tileIsWater(nx, y) then
					seen[key] = true
					table.insert(frontier, { nx, y })
				end
			end
		else
			--  Water above: climb.
			local key = x .. "," .. (y + 1)

			if not seen[key] and (y + 1 - startY) <= PETPORTS_DIVE_TRACE_RISE then
				seen[key] = true
				table.insert(frontier, { x, y + 1 })
			end

			--  Spread as well as climb, or a column that dead-ends under an
			--  overhang takes the whole budget with it.
			for _, dx in ipairs({ -1, 1 }) do
				local nx = x + dx
				local sideKey = nx .. "," .. y

				if not seen[sideKey]
				   and nx >= spanLow and nx <= spanHigh
				   and tileIsWater(nx, y) then
					seen[sideKey] = true
					table.insert(frontier, { nx, y })
				end
			end
		end
	end

	--  A BUDGET EXHAUSTED WITH ENTRIES IN HAND IS NOT A FAILURE. It only means
	--  the pool is bigger than the search, and the openings already found are as
	--  real as any the rest of it would have held.
	if #entries > 0 then return entries, nil, examined end

	if examined >= PETPORTS_DIVE_TRACE_BUDGET then
		return nil, string.format("no surface within %s tiles of %s -- sealed, or a pool larger than the budget",
			sb.printJson(PETPORTS_DIVE_TRACE_BUDGET), sb.printJson(from))
	end

	return nil, "the water around " .. sb.printJson(from) .. " has no reachable surface"
end

--  How many body-sized samples to take along the line to the fish.
PETPORTS_DIVE_SWIM_SAMPLES = 14

--  CAN THE UNIT SIMPLY SWIM AT THE FISH FROM WHERE IT IS?
--
--  A SWEPT BODY, NOT A RAY, AND THE DIFFERENCE IS THE WHOLE POINT. A ray passes
--  through a one-tile gap that a 1.6-wide body cannot -- which is exactly the
--  case where two nearly separate pools touch at a single tile, and abandoning a
--  good board for a hole the unit cannot fit through would strand it mid-pool.
--  Sampling bodyFitsAt along the line asks the question a ray only approximates.
--
--  IT DOES NOT ASK WHETHER THE LINE IS WET. Being submerged is tested separately
--  by the caller and is about the UNIT; this is about what is between it and the
--  fish. A line that leaves the water and comes back is still swimmable by a
--  chassis that has just proven it can cross a waterline in both directions.
--
--  NOT A SUBSTITUTE FOR THE PATHER. This says "there is nothing in the way", and
--  the free-mover machinery still has to plan the actual route. A false yes
--  costs one abandoned board and a plan that fails honestly; a false no costs a
--  walk to a diving board that was never needed.
local function swimReachable(target)
	if target == nil then return false end

	local from = mcontroller.position()

	for i = 0, PETPORTS_DIVE_SWIM_SAMPLES do
		local t = i / PETPORTS_DIVE_SWIM_SAMPLES
		local at = {
			from[1] + ((target[1] - from[1]) * t),
			from[2] + ((target[2] - from[2]) * t)
		}

		if not bodyFitsAt(at) then return false end
	end

	return true
end

--  BOARDS THAT HAVE ALREADY REFUSED, AND WHY THIS IS NOT THE "BEST BOARD" WORK.
--
--  Choosing a GOOD diving board is deliberately still unbuilt -- the scan takes
--  the first thing that works, not the best. This is narrower and is not an
--  improvement to that: it is only a record of boards PROVEN unusable by an
--  actual swept flight, so the scan stops handing back the same failure. One
--  refusal is a fact about that board, not a preference between boards.
--
--  KEYED BY TILE. The launch scan returns positions on tile centres, so rounding
--  is exact rather than approximate, and a board refused at [2504.5,1152.8] is
--  the same board next tick.
--
--  IT OUTLIVES petports_diveForget ON PURPOSE. Forget runs on every refusal, so
--  a blacklist stored with the plan would be erased by the very event that
--  writes it. It is cleared when the fish changes instead -- a different fish is
--  a different pool and possibly a different set of viable boards.
local function diveRefusedKey(point)
	return string.format("%s,%s", math.floor(point[1]), math.floor(point[2]))
end

function petports_diveRefuse(point, why)
	if point == nil then return end

	self.petportsDiveRefused = self.petportsDiveRefused or {}
	self.petportsDiveRefused[diveRefusedKey(point)] = true

	sb.logInfo("UNIT DIVE REFUSED from %s: %s -- board struck off, looking for another",
		sb.printJson(point), tostring(why))
end

local function diveRefusedAt(point)
	local refused = self.petportsDiveRefused
	return refused ~= nil and refused[diveRefusedKey(point)] == true
end

--  HOW MANY OPENINGS ARE CARRIED FORWARD INTO PAIRING, NEAREST THE FISH FIRST.
--
--  REPLACES A DISTANCE BOUND, AND THE CHANGE IS NOT COSMETIC. This was
--  PETPORTS_DIVE_ENTRY_REACH, twenty tiles from the fish (retired). That was
--  sound while the trace could only reach twenty-four tiles anyway; with a reach
--  of PETPORTS_DIVE_TRACE_REACH it would throw away precisely the openings the
--  wider trace exists to find -- an islet's edge is far from a fish under its
--  middle, and it is the ONLY way in.
--
--  A COUNT BOUNDS THE COST WHERE A DISTANCE DOES NOT. Pairing is columns times
--  openings rays, and a wide trace can return seventy-six of them; against a
--  board window that must now also widen, that is thousands of casts in one
--  tick. Twelve nearest keeps it in the hundreds and discards only openings that
--  were going to score badly anyway -- distance from the fish is already what
--  makes an opening worse.
PETPORTS_DIVE_ENTRY_KEEP = 12

--  A BOARD AND A HOLE, CHOSEN TOGETHER.
--
--  NEITHER IS MEANINGFUL ALONE, AND CHOOSING THEM IN SEQUENCE WAS THE BUG. The
--  trace used to stop at the first surface the body fit through, and boards were
--  then scored by distance to that one hole -- so an unlucky first opening threw
--  away every board in the pool, and the nearest footing won even when it sat
--  behind a wall. Measured 2026-09-02: a board on the left, an entry further
--  left, and something solid between them, chosen again and again.
--
--  SCORED ON HORIZONTAL OFFSET, NOT ON DISTANCE, AND THE LOG IS THE ARGUMENT.
--  Of eight dives on 2026-09-02, the five ALIGNED ones all landed, each rising
--  0.667 tiles with no horizontal solve at all. Alignment is not a tidiness
--  preference: |dx| <= PETPORTS_DIVE_DROP_ALIGN is the case that writes no vx,
--  so there is no drag to fight, no velocity to get wrong, and no swept flight
--  across terrain to be refused by. Distance cannot express that -- it prefers a
--  board a tile away diagonally over one two tiles directly above, and the
--  second is strictly the better dive.
--
--  VERTICAL DROP BREAKS TIES, SHORTEST FIRST, because a shorter fall is less
--  flight to be interrupted and lands nearer the surface the fish is under.
--
--  COST. One ray per pair, so columns times entries -- a few hundred
--  lineTileCollision calls at the current spreads. It runs ONCE PER TASK now the
--  plan is sticky, beside a trace that already spends comparably.
--  THE COLUMN WINDOW BOTH HALVES OF THE SEARCH USE.
--
--  ONE WINDOW, NOT TWO, so the trace cannot collect an opening the board scan
--  will never look under, nor the reverse. Spans the fish and the unit with
--  PETPORTS_DIVE_SPAN_MARGIN either side, clamped toward the fish at
--  PETPORTS_DIVE_SPAN_MAX.
local function diveSpan(fish, reach)
	local here = mcontroller.position()[1]

	reach = reach or PETPORTS_DIVE_SPAN_MARGIN

	local low = math.floor(math.min(fish[1], here)) - reach
	local high = math.ceil(math.max(fish[1], here)) + reach

	--  CLAMPED TOWARD THE FISH. If the unit is a long way off, the openings
	--  worth having are the ones near the target, not the ones near the walker.
	local widest = math.max(PETPORTS_DIVE_SPAN_MAX, reach * 2)

	if (high - low) > widest then
		if fish[1] < here then
			high = low + widest
		else
			low = high - widest
		end
	end

	return low, high
end

local function pickBoardAndEntry(entries, fish, spanLow, spanHigh)
	--  A LIST OF POINTS, NOT A POINT. Shipped 2026-09-02 with traceSurface still
	--  returning a single {x,y} from an early return that an aborted edit had
	--  failed to remove: ipairs walked that table as two NUMBERS and every tick
	--  died on `attempt to index a number value (local 'entry')`, which killed
	--  the unit script and read from outside as a failed media check.
	--
	--  CHEAP AND LOUD. One type test per call against a crash that presents as
	--  something else entirely.
	if type(entries) ~= "table" or type(entries[1]) ~= "table" then
		sb.logInfo("UNIT DIVE cannot choose a board: traceSurface returned %s, "
			.. "which is not a list of openings",
			sb.printJson(entries))
		return nil
	end

	local best = nil

	for column = spanLow, spanHigh do
		local x = column + 0.5

		--  SEEDED AT THE WATER SURFACE, NOT AT THE FISH.
		--
		--  THIS LINE READ fish[2] AND THAT WAS THE WHOLE FAILURE. Dry footing sits
		--  at the WATERLINE; a fish sits wherever it likes, which is usually well
		--  under it. Measured 2026-09-02: fish at y 1127.66, surface openings at
		--  about 1149, so the search swept y 1119..1143 -- twenty tiles below any
		--  dry ground in the world -- and reported "41 opening(s) found ... but no
		--  dry footing in that span can see any of them". Forty-one real holes and
		--  not one board, because it was looking in the wrong half of the ocean.
		--
		--  IT IS A REGRESSION FROM THE PAIRING REWRITE. launchPointNear seeded at
		--  entry[2], correctly; when the signature changed from one entry to a
		--  list plus a fish, the seed followed the wrong argument.
		--
		--  THE NEAREST OPENING IN X DECIDES THE HEIGHT, so a pool with surfaces at
		--  several levels -- a stepped shoreline, a cave pool above a bay -- gets
		--  the level belonging to this column rather than one global guess. Pure
		--  arithmetic over the entry list, so it costs no world calls; the single
		--  findGroundPosition per column is unchanged.
		local seedY, seedGap = nil, nil

		for _, entry in ipairs(entries) do
			local gap = math.abs(entry[1] - x)

			if seedGap == nil or gap < seedGap then
				seedY, seedGap = entry[2], gap
			end
		end

		--  avoidLiquid TRUE, WHICH IS THE OPPOSITE OF WHAT THIS CHASSIS USUALLY
		--  PASSES. petports_avoidLiquid() is false for an amphibious unit, so the
		--  ordinary resolvers hand back submerged standing spots -- fine to stand
		--  on, useless to dive FROM. findGroundPosition refuses wet ground when
		--  this flag is set, so vanilla answers the question directly.
		--
		--  ASYMMETRIC WINDOW, MOSTLY UPWARD. A board is above the water it drops
		--  into by definition; below the surface there is only more water.
		local ok, spot = pcall(findGroundPosition, { x, seedY }, -4, 12, true)

		if ok and type(spot) == "table" and type(spot[1]) == "number"
		   and type(spot[2]) == "number" then

			diveDebugMark({ spot[1], spot[2] }, PETPORTS_DIVE_COLOR_FOOTING)

			--  Proven unusable by an actual swept flight. Skipped, not scored.
			if diveRefusedAt(spot) then spot = nil end

			if spot ~= nil then
				local sighted = false

				for _, entry in ipairs(entries) do
					--  THE HOLE MUST BE BELOW THE BOARD. One above it cannot be
					--  fallen into.
					--
					--  NO DISTANCE TEST HERE ANY MORE. It used to also refuse a hole
					--  more than PETPORTS_DIVE_ENTRY_REACH from the fish; that bound
					--  is retired, because the whole point of the wider trace is to
					--  find openings a long way from a fish under a lid. Distance is
					--  now handled where it belongs -- by keeping only the nearest
					--  PETPORTS_DIVE_ENTRY_KEEP openings, and by the walk term in
					--  the score below.
					if entry[2] < spot[2] and diveSighted(spot, entry) then

						sighted = true

						local dx = math.abs(entry[1] - spot[1])
						local drop = spot[2] - entry[2]
						local aligned = dx <= PETPORTS_DIVE_DROP_ALIGN
						local walk = math.abs(spot[1] - mcontroller.position()[1])

						--  ALIGNMENT FIRST, THEN THE WALK, THEN THE REST.
						--
						--  THE WALK TERM IS WHAT FIXES THE LEFT BIAS. Scored on
						--  offset and drop alone, aligned pairs TIE EXACTLY -- dx
						--  is 0 and the drop is the same waterline -- so the
						--  winner was simply whichever column the scan reached
						--  first, and the scan runs spanLow upward. Observed
						--  2026-09-02 as a standing preference for holes on the
						--  left regardless of where the unit was standing.
						--
						--  IT OUTRANKS dx WITHIN THE ALIGNED CLASS ON PURPOSE.
						--  Every aligned pair already works -- five for five in
						--  the 2026-09-02 log, each rising 0.667 tiles -- so
						--  splitting hairs over a tile of offset while walking
						--  twenty tiles further is the wrong trade. Between two
						--  dives that both work, take the nearer one.
						--
						--  ALIGNMENT STILL WINS OUTRIGHT. The 1000 is larger than
						--  any walk the span can produce (PETPORTS_DIVE_SPAN_MAX
						--  is 72), so no amount of nearness promotes an offset
						--  pair over an aligned one.
						local score = (aligned and 0 or 1000)
							+ walk + dx + (drop * 0.1)

						if best == nil or score < best.score then
							best = {
								launch = { spot[1], spot[2] },
								entry = { entry[1], entry[2] },
								score = score, dx = dx, drop = drop,
								aligned = aligned, walk = walk
							}
						end
					end
				end

				--  A BOARD THAT CAN SEE NO HOLE AT ALL IS WORTH DRAWING, and it is a
				--  different fact from a board that merely lost on score.
				if not sighted then
					diveDebugMark({ spot[1], spot[2] }, PETPORTS_DIVE_COLOR_NARROW)
				end
			end
		end
	end

	return best
end

--  WHERE SHOULD A DRY UNIT GO TO GET AT A FISH?
--
--  Returns launch, entry -- or nil and a reason fit for a log line.
--  THE PLAN STICKS TO THE TASK, NOT TO THE FISH.
--
--  A FISH MOVES AND THE DIVING BOARD MUST NOT. This resolves twice a second
--  against the fish's LIVE position, and re-tracing each time re-derives the
--  hole and therefore the board. Measured 2026-09-02, thirty plans in five
--  seconds for one fish, the launch point walking 2531 -> 2538 -> 2539 -> 2541
--  -> 2543 -> 2531: the unit was chasing a destination that moved faster than
--  it did and never committed to any of them.
--
--  KEYED ON THE TASK ID, WHICH FOR A FISH IS "fish:<entityId>" AND THEREFORE
--  STABLE FOR THE WHOLE CHASE. A new fish is a new id and gets a new plan; the
--  same fish keeps the board it was first given.
--
--  A FISH THAT LEAVES THE TRACED POOL INVALIDATES NOTHING HERE, deliberately.
--  The dive is a commitment -- see the answers recorded on the diving latch --
--  and a plan that turns out to aim at water the fish has left fails the task,
--  which the port already backs off and re-dispatches. Re-planning mid-walk is
--  the behaviour this exists to stop.
--
--  IT ALSO MAKES THE TRACE CHEAP AGAIN. Once per task instead of twice a second,
--  which matters less than it sounds -- the traces measured at four to seven
--  tiles -- but the pather rebuild each new board caused did not.
function petports_diveApproach(fishPosition, taskId)
	if fishPosition == nil then return nil, "no fish position" end

	local plan = self.petportsDivePlan

	if plan ~= nil and taskId ~= nil and plan.taskId == taskId then
		return plan.launch, plan.entry
	end

	--  A NEW FISH CLEARS THE STRUCK-OFF BOARDS. They are facts about one flight
	--  to one hole; a different fish is a different pool and its own set of
	--  viable boards. Kept ACROSS petports_diveForget within a task, because
	--  forget runs on every refusal and would otherwise erase the record the
	--  refusal just wrote.
	if taskId ~= nil and self.petportsDiveRefusedFor ~= taskId then
		self.petportsDiveRefusedFor = taskId
		self.petportsDiveRefused = nil
	end

	--  TWO WINDOWS, BECAUSE THE TWO HALVES ARE LOOKING FOR DIFFERENT THINGS.
	--
	--  The trace hunts the EDGE OF A LID and must be free to run as wide as the
	--  player built it -- PETPORTS_DIVE_TRACE_REACH. The board scan hunts DRY
	--  FOOTING and only wants columns near something worth diving into. Sharing
	--  one window meant the narrower need silently bounded the wider one, and a
	--  fish under an islet was unreachable because the flood could not escape a
	--  box it was told to stay inside.
	local traceLow, traceHigh = diveSpan(fishPosition, PETPORTS_DIVE_TRACE_REACH)

	local entries, why, examined = traceSurface(fishPosition, traceLow, traceHigh)

	--  CLEARED ON EVERY FAILURE, AND THAT MATTERS MORE THAN IT LOOKS.
	--  petports_desiredSwimMode treats a stored entry as "the fish's water is
	--  over there, do not commit to anything else". A stale one left behind by a
	--  fish in a different pool would keep refusing swim mode for water the unit
	--  is legitimately in. No plan means no gate, which fails toward letting the
	--  unit swim rather than toward stranding it.
	if entries == nil then
		self.petportsDiveEntry = nil
		self.petportsDivePlan = nil
		return nil, why
	end

	--  NEAREST OPENINGS FIRST, THEN CAPPED. Both halves of this bound the pairing
	--  cost: sorting decides WHICH openings survive, the cap decides how many.
	--  See PETPORTS_DIVE_ENTRY_KEEP.
	table.sort(entries, function(a, b)
		return math.abs(a[1] - fishPosition[1]) < math.abs(b[1] - fishPosition[1])
	end)

	while #entries > PETPORTS_DIVE_ENTRY_KEEP do
		table.remove(entries)
	end

	--  THE BOARD WINDOW IS DERIVED FROM THE OPENINGS THAT SURVIVED, not from the
	--  fish alone. A hole at an islet's edge needs a board at that edge, which
	--  the fish-centred window would not have reached -- and looking for footing
	--  anywhere else is looking where no dive can start.
	local boardLow = math.floor(fishPosition[1])
	local boardHigh = boardLow

	for _, entry in ipairs(entries) do
		boardLow = math.min(boardLow, math.floor(entry[1]))
		boardHigh = math.max(boardHigh, math.ceil(entry[1]))
	end

	local unitLow, unitHigh = diveSpan(fishPosition)

	boardLow = math.min(boardLow - PETPORTS_DIVE_SPAN_MARGIN, unitLow)
	boardHigh = math.max(boardHigh + PETPORTS_DIVE_SPAN_MARGIN, unitHigh)

	local pair = pickBoardAndEntry(entries, fishPosition, boardLow, boardHigh)

	if pair == nil then
		self.petportsDivePlan = nil
		self.petportsDiveEntry = nil

		return nil, string.format("%s opening(s) kept near %s (traced %s tiles over "
			.. "columns %s..%s) but no dry footing over columns %s..%s can see any "
			.. "of them, unit at %s",
			sb.printJson(#entries), sb.printJson(fishPosition),
			sb.printJson(examined), sb.printJson(traceLow), sb.printJson(traceHigh),
			sb.printJson(boardLow), sb.printJson(boardHigh),
			sb.printJson(mcontroller.position()[1]))
	end

	local launch, entry = pair.launch, pair.entry

	self.petportsDiveEntryMark = { entry[1], entry[2] }
	self.petportsDiveLaunchMark = { launch[1], launch[2] }

	--  REAL STATE, NOT JUST A DEBUG MARK. petports_desiredSwimMode reads this to
	--  tell the fish's pool from a puddle on the way to it.
	self.petportsDiveEntry = { entry[1], entry[2] }
	self.petportsDivePlan = {
		taskId = taskId,
		launch = { launch[1], launch[2] },
		entry = { entry[1], entry[2] }
	}

	sb.logInfo("UNIT DIVE plan for fish at %s: %s opening(s) from %s tiles traced; "
		.. "chose board %s -> hole %s (%s, dx %s, drop %s, walk %s)",
		sb.printJson(fishPosition), sb.printJson(#entries), sb.printJson(examined),
		sb.printJson(launch), sb.printJson(entry),
		pair.aligned and "ALIGNED" or "offset",
		sb.printJson(pair.dx), sb.printJson(pair.drop), sb.printJson(pair.walk))

	return launch, entry
end

--  HOW CLOSE TO THE DIVING BOARD COUNTS AS STANDING ON IT.
--
--  THE GATE USED TO MEASURE DISTANCE TO THE HOLE, AND THAT WAS THE WRONG POINT
--  ENTIRELY. Measured 2026-09-02, with the board at [2493.5,1152.8] and the hole
--  at [2493.5,1149.5]:
--
--      UNIT submerged at [2504,1148.83] but the planned hole is [2493.5,1149.5],
--          10.5213 tiles away -- this is not the fish's water, staying a walker
--      UNIT swim mode land -> aquatic at [2499.22,1148.81]
--
--  The unit waded in along the SHORE of the right pool, drifted inside six tiles
--  of the hole, and latched while it was still six tiles short of the board it
--  was walking to. It never once arrived. A radius around the hole cannot tell
--  "dived in" from "waded past", because both happen near the hole -- only
--  standing on the board distinguishes them, and that is a place, not a range.
--
--  1.5 IS ARRIVAL_DISTANCE FROM petportsTaskAction, deliberately reused: this is
--  the same question every other approach asks about its own target, and a dive
--  should not invent a second opinion about what "there" means.
PETPORTS_DIVE_BOARD_ARRIVAL = 1.5

--  IS A DIVE IN FLIGHT?
function petports_diving()
	return self.petportsDiveFlight ~= nil
end

--  STEP OFF THE BOARD.
--
--  A FLAT STEP-OFF, NOT AN ARC UP AND OVER. The trajectory is horizontal
--  velocity plus gravity and nothing else. An upward kick would look better and
--  costs two things this cannot afford yet: headroom above the board, and the
--  airJumpProfile's collisionCancelled, which kills an arc that clips anything
--  on the way UP -- so the prettier version fails in exactly the cramped
--  player-built terrain this whole feature exists for. Adding a rise later is
--  one term in vy; getting wet reliably is the job now.
--
--  THE ALIGNED CASE WRITES NO VELOCITY AT ALL. If the board is over the hole,
--  controlDown and gravity are the entire dive. Nothing to solve means nothing
--  to solve WRONG, and it is the common case -- see PETPORTS_DIVE_DROP_ALIGN.
--
--  THE PATH IS SWEPT BEFORE COMMITTING, because after this there is no steering.
--  A dive is ballistic and cannot be corrected, so the only chance to find out
--  the body does not fit is now.
function petports_diveLaunch(plan, hop)
	local source = mcontroller.position()
	local entry = plan.entry

	local dx = entry[1] - source[1]
	local dy = entry[2] - source[2]

	if dy >= 0 then
		return false, string.format("the hole at %s is not below the board at %s",
			sb.printJson(entry), sb.printJson(source))
	end

	local parameters = mcontroller.baseParameters()
	local gravity = world.gravity(source) * (parameters.gravityMultiplier or 1.0)

	if gravity <= 0 then return false, "no gravity to fall with" end

	--  WITH A HOP THE FLIGHT IS NO LONGER A FREE FALL FROM REST.
	--
	--      y(t) = y0 + vy0*t - (g/2)*t^2,  and we want y(t) - y0 = dy
	--      => (g/2)*t^2 - vy0*t + dy = 0
	--      => t = (vy0 + sqrt(vy0^2 - 2*g*dy)) / g
	--
	--  dy IS NEGATIVE, so the discriminant exceeds vy0^2 and the positive root
	--  always exists -- there is no unsolvable geometry here once the hole is
	--  below the board, which the check above already guaranteed.
	local vy0 = hop or PETPORTS_DIVE_HOP
	local disc = (vy0 * vy0) - (2 * gravity * dy)
	if disc < 0 then return false, "no descending solution" end

	local time = (vy0 + math.sqrt(disc)) / gravity
	if time <= 0 then return false, "degenerate fall time" end

	local aligned = math.abs(dx) <= PETPORTS_DIVE_DROP_ALIGN
	local vx = aligned and 0 or (dx / time)

	--  SWEEP THE FLIGHT. Same predicate the trace used on the hole itself, so
	--  "wide enough" means the same thing at every point of the dive as it did
	--  at its destination.
	for i = 1, PETPORTS_DIVE_SWEEP_SAMPLES do
		local t = (time * i) / PETPORTS_DIVE_SWEEP_SAMPLES
		local at = {
			source[1] + (vx * t),
			source[2] + (vy0 * t) - ((gravity * t * t) / 2)
		}

		if not bodyFitsAt(at) then
			return false, string.format("the flight is blocked at %s (sample %s of %s)",
				sb.printJson(at), sb.printJson(i),
				sb.printJson(PETPORTS_DIVE_SWEEP_SAMPLES))
		end
	end

	--  vx IS STORED AND RE-ASSERTED EVERY TICK, NOT SET ONCE HERE.
	--
	--  A SINGLE setVelocity DECAYS. airFriction acts on horizontal velocity for
	--  the whole flight, so a one-shot launch arrives short of where it was
	--  solved to land -- and the solve has no drag term to compensate with,
	--  because a closed-form one that matched the engine's integration would be a
	--  guess dressed as arithmetic. Re-asserting makes the horizontal component
	--  exactly what was solved and leaves the vertical entirely to gravity.
	--
	--  THE OFFSET BOARDS NEED IT MOST. Measured against the boards in the
	--  2026-09-02 log: a 3.3 tile drop is 0.235 s, so covering the 4 to 5 tiles
	--  those boards sit from their holes wants 17 to 21 tiles/s. There is no
	--  margin in that for drag.
	--  THE HOP IS WRITTEN FOR ALIGNED DIVES TOO, and it is the only thing they
	--  write. An aligned board still has feet resting on a platform, and that is
	--  the case controlDown cannot start on its own.
	mcontroller.setVelocity({ vx, vy0 })

	self.petportsDiveFlight = {
		startedAt = world.time(),
		startY = source[2],
		peak = 0,
		deadline = world.time() + time + PETPORTS_DIVE_GRACE,
		entry = { entry[1], entry[2] },
		aligned = aligned,
		vx = vx,

		--  NO HOP MEANS THE PLATFORM HAS TO BE ASKED, NOT JUMPED OFF. See the
		--  retry in petports_swimModeTick and the controlJump in
		--  petports_assertSwimMode.
		dropThrough = vy0 <= 0
	}

	--  THE MODE IS SET HERE, DIRECTLY, AND NOT LEFT TO THE TICK'S REBUILD.
	--
	--  petports_swimModeTick only changes mode by calling petports_freshPather,
	--  and that is throttled by PETPORTS_SWIM_MODE_REBUILD_INTERVAL -- one
	--  second. A dive lasts a third of that. Measured 2026-09-02: "swim mode
	--  land -> diving" appears NOWHERE in a log full of launches, so
	--  petports_assertSwimMode never reached its controlDown branch and the unit
	--  hopped straight back down onto the platform it was trying to leave.
	--
	--  NO REBUILD, AND THAT IS THE POINT RATHER THAN AN OMISSION. Every other
	--  mode change rebuilds the pather because it changes what a route may be
	--  made of. A dive has no route: it is ballistic from this instant until it
	--  is wet, so there is nothing to rebuild and a second of waiting to find
	--  that out is a second the unit spends falling wrong.
	petports_setSwimMode(PETPORTS_SWIM_MODE_DIVING, "dive launched")

	sb.logInfo("UNIT DIVE launched from %s toward %s: %s, dx %s dy %s, "
		.. "vx %s, predicted %s s, deadline +%s s",
		sb.printJson(source), sb.printJson(entry),
		aligned and (vy0 > 0 and "aligned hop-and-drop" or "aligned drop-through, no hop")
			or "hopped off with horizontal velocity",
		sb.printJson(dx), sb.printJson(dy), sb.printJson(vx),
		sb.printJson(time), sb.printJson(time + PETPORTS_DIVE_GRACE))

	return true
end

--  HAS THE DIVE ENDED, AND HOW?
--
--  Returns nil while still in flight, or a reason string once it is over. The
--  three endings are the ones recorded as the spec:
--
--    submerged                    the dive worked
--    solid contact, still dry     it hit something -- a sealed hole, a ledge,
--                                 a player who bricked the pool while it fell
--    past the deadline            it never arrived anywhere at all
function petports_diveOutcome()
	local flight = self.petportsDiveFlight
	if flight == nil then return nil end

	--  PEAK HEIGHT, ONE FIELD, BECAUSE THE LOG CANNOT ANSWER "HOW HIGH" TODAY.
	--
	--  An unusually high launch was seen 2026-09-02 and there is nothing in a log
	--  to confirm or refute it: the launch line reports what was ASKED for and
	--  the outcome reports where it ended, and a pogo between them leaves no
	--  trace. The suspicion is that a drop-through whose platform does not
	--  release becomes a full jump -- airJumpProfile's jumpSpeed 45 is an 8.44
	--  tile rise -- which would be unmistakable against a hop's 0.6.
	--
	--  ONE NUMBER ON A TABLE THAT ALREADY EXISTS. Not a trace, not a per-tick
	--  line: it is reported once, in the outcome that was already being logged.
	local height = mcontroller.position()[2] - flight.startY

	if height > (flight.peak or 0) then flight.peak = height end

	local medium = petports_mediumAt(mcontroller.position(), mcontroller.boundBox())

	if medium == "swim" then return "landed" end

	--  YOU CANNOT HIT GROUND YOU NEVER LEFT.
	--
	--  setVelocity does not move anything; the next physics step does. So on the
	--  launch tick onGround() is still true, and testing it there failed every
	--  dive one millisecond after starting it -- measured 2026-09-02, launch at
	--  .530 and "hit solid ground" at .531, over and over. The hop was real and
	--  the verdict was delivered before it could happen.
	--
	--  LATCHED, NOT TIMED. A grace period would be a guess about physics rate;
	--  this is the actual condition the failure is about. Once the feet have left
	--  the ground, touching it again means something.
	if not flight.airborne then
		if not mcontroller.onGround() then flight.airborne = true end
		return nil
	end

	--  ONGROUND WHILE STILL DRY IS THE FAILURE THE SPEC NAMES. controlDown is
	--  held for the whole flight, so a platform cannot be what stopped it -- if
	--  the unit is standing on something, that something is solid.
	if mcontroller.onGround() then
		return "hit solid ground without reaching the water"
	end

	if world.time() >= flight.deadline then
		return string.format("still airborne %s s after launch",
			sb.printJson(world.time() - flight.startedAt))
	end

	return nil
end

--  WHICH TASKS ARE WORTH BECOMING A SWIMMER FOR.
--
--  ONLY FISH, AND THAT IS THE WHOLE LIST. Every other submerged behaviour this
--  chassis had was already correct as a WALKER: it wades, it swims along the
--  bottom on Swim edges, and it climbs out, all with gravity on, and it has done
--  since before swim mode existed. A fish is the one target that is not on the
--  floor and never will be.
--
--  MEASURED 2026-09-02, and it is why this gate exists. A harvest task with a
--  target on dry land, mid-route with 27 tiles of progress behind it:
--
--      approach ... moved 27.9349 | hasPath true finderTarget [2532.5,1184.8]
--      swim mode land -> exiting at [2530.87,1159.14] (medium swim)
--      UNIT path LOST at [2530.87,1159.14]
--      UNIT path found after 1.83333 s
--
--  The unit walked through a shallow pool, went briefly fully under, and the
--  mode change threw away a working plan and spent nearly two seconds rebuilding
--  one. Twice in one log. Swim mode was not wrong about the medium; it was wrong
--  that the medium mattered.
--
--  A TABLE RATHER THAN A COMPARISON, so adding a second such task later is one
--  line here instead of an `or` chain somewhere unrelated.
PETPORTS_SWIM_TASK_TYPES = {
	fish = true
}

--  DOES THE HELD TASK NEED THIS UNIT TO STOP BEING A WALKER?
--
--  THE TASK, NOT THE LEASH. petports_currentTaskDestination falls back to the
--  leash so the RETURN LEG can pick a mode; this deliberately does not, because
--  going home is never a reason to become a swimmer -- a walker already gets
--  home from anywhere it can walk, and from anywhere it cannot, `exiting` is
--  what carries it and that path is reached from a water mode rather than this
--  one.
local function taskWantsSwimming()
	local task = self.petportsTask

	return type(task) == "table" and task.type ~= nil
		and PETPORTS_SWIM_TASK_TYPES[task.type] == true
end

--  WHICH MODE DOES THIS TASK CALL FOR, FROM WHERE THE UNIT IS STANDING?
--
--  THE THRESHOLDS ARE ASYMMETRIC ON PURPOSE. A water mode is ENTERED only when
--  the body is fully under ("swim") and LEFT only when it is fully out ("air").
--  In between -- "mixed", a body straddling the waterline -- the current mode is
--  held.
--
--  SYMMETRIC THRESHOLDS PRODUCED A LIMIT CYCLE AT THE SURFACE, measured
--  2026-09-02 and it stopped the unit leaving the water at all:
--
--      exiting -> land at [2527.46,1149.25] (medium mixed)
--      land -> exiting at [2527.25,1146.14] (medium swim)
--      exiting -> land at [2522.74,1149.27] (medium mixed)
--
--  ...for the whole log, y bouncing between 1146 and 1149 on a one-second
--  period. The two modes have OPPOSITE PHYSICS -- `exiting` floats on
--  liquidBuoyancy 1.0, `land` sinks on the chassis's 0.0 -- so each one drove
--  the unit back into the other's territory. That is not a rate-limiting problem
--  and the rebuild interval could not have fixed it; it only set the period.
--
--  WHY "mixed" CANNOT DECIDE ANYTHING BY ITSELF. petportsFlopState's header
--  works through the same ambiguity and reaches the same wall: a body at the
--  waterline reads mixed whether it is on its way in or on its way out, so the
--  reading contains no information about which. The CURRENT MODE is the missing
--  bit -- it is the only record of which direction the unit was going -- so
--  holding it is not inertia for its own sake, it is the answer.
--
--  ENTRY IS GATED ON THE TASK, EXIT IS NOT, AND THE ASYMMETRY IS DELIBERATE. A
--  walker only becomes a swimmer for a task that needs one (see
--  taskWantsSwimming). But once it IS one, it must be able to get out no matter
--  what it is doing next -- gating the way home on a task type is how a unit
--  ends up floating in deep water with a harvest to do and no way to reach it.
function petports_desiredSwimMode(destination)
	if not petports_gravitySwitchable() then return PETPORTS_SWIM_MODE_LAND end

	--  A DIVE IN FLIGHT OUTRANKS EVERY READING BELOW, INCLUDING air -> land.
	--
	--  This is the one place the mode is NOT a function of where the body is. A
	--  diving unit is in air by definition and would otherwise be told it is a
	--  walker halfway down, which rebuilds the pather mid-flight and re-resolves
	--  an approach to a fish from the sky. petports_diveOutcome in the tick is
	--  what ends this, not a medium reading here.
	if petports_diving() then return PETPORTS_SWIM_MODE_DIVING end

	local medium = petports_mediumAt(mcontroller.position(), mcontroller.boundBox())

	--  FULLY OUT OF THE WATER. Unconditional, and it is the only way to reach
	--  LAND from a water mode.
	if medium == "air" then return PETPORTS_SWIM_MODE_LAND end

	--  STILL A WALKER? Two things must both be true to stop being one: the body
	--  is fully under, and there is a reason to swim.
	if petports_swimMode() == PETPORTS_SWIM_MODE_LAND then
		if medium ~= "swim" then return PETPORTS_SWIM_MODE_LAND end

		--  NO TASK AT ALL IS ITSELF A REASON, AND THIS IS NOT THE SAME TEST AS
		--  taskWantsSwimming. A unit that spawns into a submerged port with
		--  nothing to do is a walker under gravity with nowhere to be, so it
		--  settles onto the seabed and stays there -- measured 2026-09-02, and
		--  it is the state the unit is in for its first seconds of life.
		--
		--  Holding itself in the water is what an amphibious unit should do
		--  while idle, and it makes the next task cheaper too: a station-keeping
		--  swimmer handed dry work becomes `exiting` and swims out, where a unit
		--  on the bottom of a submerged port first has to be dug out of a
		--  home-resolve that has no answer down there.
		--
		--  WADING IS UNAFFECTED, which is the whole reason this is a separate
		--  branch. Crossing a pool on the way to a crop means HOLDING a task, so
		--  it takes the line below and stays a walker.
		if self.petportsTask ~= nil then
			if not taskWantsSwimming() then
				--  WADING IS FINE, DROWNING IS NOT. A task that is not worth
				--  becoming a swimmer for is still not worth SINKING for. With a
				--  bottom underfoot this is a pool being crossed and the walker
				--  handles it, which is the behaviour the fish gate was added to
				--  protect. Without one the unit is in open water it did not
				--  choose, and falling through it is not a plan -- so it drops
				--  out of this branch and the destination decides, which for the
				--  dry target such a task always has means `exiting`.
				if wadeableBottom() then return PETPORTS_SWIM_MODE_LAND end

				if not self.petportsSinkNoted then
					self.petportsSinkNoted = true
					sb.logInfo("UNIT submerged at %s with no bottom within %s tiles and a "
						.. "task that does not swim -- taking the water seriously rather "
						.. "than walking down it",
						sb.printJson(mcontroller.position()),
						sb.printJson(PETPORTS_WADE_DEPTH))
				end
			else


		--  THE BOARD MUST HAVE BEEN REACHED FIRST. A planned dive means the unit
		--  is walking somewhere specific, and until it has stood there, every
		--  drop of water it touches -- a puddle on the way, or the shallow shore
		--  of the right pool -- is water it must NOT commit to.
		--
		--  ONCE REACHED, ALWAYS REACHED FOR THIS PLAN. The flag is not a range
		--  test repeated per tick: after the dive the unit is a long way from the
		--  board and must stay a swimmer. petports_diveForget clears it with the
		--  plan when the task ends, which is the only thing that should.
		--
		--  NO PLAN MEANS NO GATE, which is the case where the unit was already in
		--  the fish's water when the task arrived -- there is nothing to walk to
		--  and nothing to be confused by.
			local plan = self.petportsDivePlan

			--  `abandoned` COUNTS AS ARRIVED, because it answers the same
			--  question by a better route: the gate exists to stop a unit
			--  committing to the wrong water, and a body-width clear run to the
			--  fish is proof this is the right water. See the abandon block in
			--  petports_swimModeTick.
			if plan ~= nil and not plan.reached and not plan.abandoned then
				if not self.petportsDivePuddleNoted then
					self.petportsDivePuddleNoted = true
					sb.logInfo("UNIT submerged at %s but has not reached its board at %s "
						.. "(%s tiles away) -- not diving yet, staying a walker",
						sb.printJson(mcontroller.position()), sb.printJson(plan.launch),
						sb.printJson(world.magnitude(mcontroller.position(), plan.launch)))
				end

				return PETPORTS_SWIM_MODE_LAND
			end

			self.petportsDivePuddleNoted = nil
			end
		end
	end

	--  In a water mode already, or a fish task has just earned one.
	if destination == nil then return PETPORTS_SWIM_MODE_AQUATIC end

	if petports_mediumAtPoint(destination) == "swim" then
		return PETPORTS_SWIM_MODE_AQUATIC
	end

	return PETPORTS_SWIM_MODE_EXITING
end

--  WHERE IS THIS UNIT TRYING TO GET TO RIGHT NOW?
--
--  DISPATCHED WORK FIRST, THEN THE LEASH. Those are the only two things that
--  ever move this unit, and the leash matters as much as the work does here: the
--  RETURN LEG is how a submerged unit learns it needs to be a walker again.
--  Without the second branch a unit that finished a fish would sit in aquatic
--  mode with nothing to do and no reason to ever leave the water.
--
--  THE RAW `position`, NOT A RESOLVED APPROACH POINT. This answers one question
--  -- is the destination wet -- and a resolved point is both unavailable this
--  early and no more accurate for the purpose. petportsTaskAction's own
--  currentTarget is a file-local declared BELOW freshPather and is not in its
--  lexical scope, which is the other reason this lives here.
--
--  nil IS A REAL ANSWER meaning "nowhere in particular", and callers treat it
--  as such rather than as an error.
function petports_currentTaskDestination()
	local task = self.petportsTask

	if type(task) == "table" and type(task.position) == "table" then
		return task.position
	end

	local leash = self.petportsLeashTask

	if type(leash) == "table" and type(leash.position) == "table" then
		return leash.position
	end

	return nil
end

--  HOW LONG BETWEEN MODE-DRIVEN PATHER REBUILDS.
--
--  A BACKSTOP, NOT THE THRASH FIX. An earlier version of this comment claimed it
--  was what stopped a unit flip-flopping at a waterline. It is not, and the
--  measurement that proved it is in petports_desiredSwimMode's header: with
--  symmetric thresholds the unit oscillated on exactly this period for a whole
--  log, because each mode's physics drove it into the other's territory. An
--  interval can only set the period of a limit cycle, never end it. Hysteresis
--  in the mode choice is what ends it.
--
--  KEPT ANYWAY, because a rebuild throws away a live plan and something should
--  bound how often that can happen no matter what future condition starts
--  flickering. One second is short enough that entering water still feels
--  immediate.
PETPORTS_SWIM_MODE_REBUILD_INTERVAL = 1.0

--  RE-EVALUATE THE MODE, EVERY TICK, AND REBUILD IF IT CHANGED.
--
--  THE MODE USED TO BE CHOSEN ONLY AT freshPather, WHICH MEANT ONLY AT TASK
--  BOUNDARIES. petports_desiredSwimMode answers LAND for any unit that is not
--  already submerged, so a unit standing on a dock was a walker no matter how
--  wet its target was -- and stayed one for the whole route.
--
--  MEASURED 2026-09-02, unit on a dock at [2511,1152.8], fish at y 1134.88:
--
--      UNIT standable for [2495.6,1134.88] -> [2495.5,1128.8] (dist 6.08289)
--      UNIT path ACQUIRED: action Walk ... edge 1 of 35 target [2495.5,1128.8]
--
--  It resolved the SEABED SIX TILES UNDER THE FISH and walked a 35-edge route to
--  the bottom, arriving sixteen seconds later, at which point it finally noticed
--  it was submerged and became a swimmer. That is the seabed hunt this whole
--  change set exists to delete, surviving on land because the mode never got
--  asked again mid-route. It only worked at all because a seabed happened to be
--  within six tiles of that fish; over open water standableNear returns nil and
--  the task fails at dispatch without the unit moving.
--
--  ASKING PER TICK IS THE FIX BECAUSE THE ANSWER CHANGES UNDER THE UNIT. Getting
--  wet is not an event anything reports -- it is just a position, one tick after
--  another. The moment the body is fully under, this notices and hands the route
--  to the free-mover machinery, which aims at the fish itself rather than the
--  floor beneath it.
--
--  REBUILDING IS MANDATORY, NOT AN OPTIMISATION. dd.locomotion.otter refused
--  runtime gravity switching because PathFinder:start reads baseParameters and
--  PathMover:new captures mustEndOnGround at construction, so a live plan built
--  under one mode is invalid under the other. petports_freshPather re-chooses and
--  applies the mode itself before building, so this passes no mode in -- it asks
--  for a rebuild and lets the one decision point make the decision.
--
--  REENTRY GUARDED. freshPather calls setSwimMode, which is why this must not be
--  the thing setSwimMode calls; the flag makes that ordering safe to get wrong.
function petports_swimModeTick()
	if not petports_gravitySwitchable() then return end

	if not self.petportsSwimModeRebuilding then
		local desired = petports_desiredSwimMode(petports_currentTaskDestination())

		if desired ~= petports_swimMode() then
			--  A REBUILD THAT CANNOT PLAN CAN ONLY DESTROY, SO DEFER IT.
			--
			--  MEASURED 2026-09-04, six attempts, five identical to the
			--  decimal. An amphibious unit swims to a jump point at 1149.8,
			--  launches [0,45] with a plan to land at [2487,1158.8], and rises.
			--  At 1159.45 the body clears the water, medium reads `air`, this
			--  tick sees `exiting` -> `land` and rebuilds. The rebuild lands
			--  mid-arc:
			--
			--      swim mode exiting -> land at [2486,1159.45] (medium air)
			--      freshPather #77 ... swim mode wants land
			--      path LOST ... action nil onGround false edge nil of 0
			--
			--  and produces nothing, because `land` needs ground the unit does
			--  not have. It then falls straight back into the water it launched
			--  from and does the whole thing again, 2.13 seconds a cycle,
			--  forever.
			--
			--  THE LAUNCH IS VERTICAL AND THE HORIZONTAL ARRIVES AT THE APEX,
			--  WHICH IS WHY THIS ONE NEVER RECOVERS. The plan is [0,45] with
			--  vx ZERO; petportsArcMover turns the horizontal on when the arc
			--  turns over. Loss altitude was 1159.45 and the next trace line
			--  reads 1159.74, so the plan dies ONE TICK before the only thing
			--  that would have moved it sideways. Compare the two dry losses in
			--  the same session, at vel [-8,20.18] and [8,20.18]: horizontal
			--  already applied, so the body coasted, landed, and replanned. A
			--  mid-arc rebuild costs a replan when vx is live and costs the
			--  whole manoeuvre when it is not.
			--
			--  THE EXIT JUMP IS THE ONE MANOEUVRE THIS IS GUARANTEED TO BREAK.
			--  Clearing the water IS the mode change, so on a water exit the
			--  transition always fires mid-arc -- the rule that exists to keep
			--  plans valid was reliably destroying the only plan that could
			--  finish the crossing.
			--
			--  DEFERRING IS SAFE BECAUSE ONLY THE PATHER WAITS. The physics are
			--  written per tick by petports_assertSwimMode, independently of
			--  this, so gravity and buoyancy still flip on the tick the medium
			--  changes. And a live Arc ends in a Land, which is the plan worth
			--  keeping. dd.locomotion.otterswitch's objection is about a plan being
			--  EXECUTED under the wrong mode; an arc in flight is being carried
			--  by physics and consults nothing.
			--
			--  NO STATE, AND NO SCHEDULING. This tick re-asks every tick, so the
			--  moment the unit is back on ground the same mismatch is still
			--  here and the rebuild happens then. The throttle timestamp is
			--  deliberately NOT stamped on a deferral, or landing could be made
			--  to wait out a second it never spent rebuilding.
			--  AN if/else RATHER THAN AN EARLY RETURN, AND THAT IS NOT STYLE.
			--  The dive-plan expiry at the bottom of this function is the only
			--  code that runs whether a task is held or not, and returning from
			--  here would stop it on every deferred tick -- a stale dive plan
			--  outliving its task. proc.tooling.earlyreturn is on its fourth
			--  instance in this codebase and every one of them was housekeeping
			--  stranded below a gate.
			if not petports_canPathfindIn(desired) then
				if self.petportsSwimModeDeferred ~= desired then
					self.petportsSwimModeDeferred = desired
					sb.logInfo("UNIT swim mode rebuild to %s DEFERRED at %s: "
						.. "cannot plan from here (onGround %s) -- holding the live plan",
						tostring(desired), sb.printJson(mcontroller.position()),
						tostring(mcontroller.onGround()))
				end
			else
				--  CLEARED AT THE EVENT THAT MAKES THE DEFERRAL STALE --
				--  proc.tooling.gatereset. Not at the bottom of the function,
				--  which would clear it on the same tick it was set and print
				--  every tick.
				self.petportsSwimModeDeferred = nil

				local now = world.time()
				local last = self.petportsSwimModeRebuiltAt or -math.huge

				if now - last >= PETPORTS_SWIM_MODE_REBUILD_INTERVAL then
					self.petportsSwimModeRebuiltAt = now
					self.petportsSwimModeRebuilding = true

					--  pcall so a rebuild fault cannot leave the guard set and
					--  silently disable mode switching for the rest of this unit's
					--  life. A raise here would also kill the unit script, which is
					--  how the last two faults presented.
					local ok, err = pcall(petports_freshPather,
						"swim mode wants " .. tostring(desired))

					self.petportsSwimModeRebuilding = false

					if not ok then
						sb.logInfo("UNIT swim mode rebuild to %s FAILED: %s",
							tostring(desired), tostring(err))
					end
				end
			end
		end
	end

	--  A DIVE PLAN OUTLIVES ITS TASK UNLESS SOMETHING DROPS IT. Nothing else is
	--  positioned to notice: the plan is made inside an approach resolve, and a
	--  task that ends simply stops calling one. This tick is the only code that
	--  runs whether a task is held or not.
	--  MARKS OR PLAN, NOT PLAN ALONE.
	--
	--  A TRACE THAT FAILS LEAVES MARKS AND NO PLAN, which is exactly the case
	--  this used to miss: petports_diveApproach draws its whole search before it
	--  finds out there is no surface, then returns nil, so there is nothing for a
	--  plan-gated clear to catch. The unit wanders off to collect items with a
	--  dead trace still lit behind it -- which reads as current, and is worse
	--  than showing nothing.
	if not taskWantsSwimming()
	   and (self.petportsDivePlan ~= nil or self.petportsDiveMarks ~= nil) then
		petports_diveForget()
	end

	--  LATCH ARRIVAL AT THE BOARD.
	--
	--  CHECKED HERE RATHER THAN IN THE APPROACH, because the approach resolve
	--  answers "where am I going" and stops being interesting the moment the
	--  answer is "here" -- arriving is a fact about position, tested per tick,
	--  the same way getting wet is. It is also the point where the mode is about
	--  to be decided, so latching first means the decision sees it this tick
	--  rather than next.
	--
	--  ONE-WAY. Nothing clears `reached` except petports_diveForget dropping the
	--  whole plan; a unit that has dived is far from its board and must not be
	--  un-arrived by walking away from it.
	local plan = self.petportsDivePlan

	--  AN ABANDONED PLAN NEVER ARRIVES. Without this the unit could swim past its
	--  discarded board, latch `reached`, and -- if it happened to be dry and
	--  grounded at that moment -- dive off a board it had already decided it did
	--  not need. `abandoned` is a decision, not a position, so no later position
	--  should undo it.
	if plan ~= nil and not plan.reached and not plan.abandoned
	   and plan.launch ~= nil then
		local gap = world.magnitude(mcontroller.position(), plan.launch)

		if gap <= PETPORTS_DIVE_BOARD_ARRIVAL then
			plan.reached = true

			sb.logInfo("UNIT DIVE reached its board at %s (%s from %s) -- clear to enter the water",
				sb.printJson(plan.launch), sb.printJson(gap),
				sb.printJson(mcontroller.position()))
		end
	end

	local medium = petports_mediumAt(mcontroller.position(), mcontroller.boundBox())

	--  ABANDON THE BOARD IF THE FISH IS ALREADY SWIMMABLE FROM HERE.
	--
	--  A WALK TO A DIVING BOARD IS A MEANS, NOT A GOAL. The unit routinely gets
	--  fully submerged on the way -- crossing the pool it is going to dive into
	--  is often the shortest path to the board over it -- and at that moment the
	--  board has nothing left to offer. Every tile it walks after that is away
	--  from the fish.
	--
	--  SUBMERGED AND UNOBSTRUCTED, BOTH. Submerged alone is the puddle problem
	--  that PETPORTS_DIVE_BOARD_ARRIVAL exists to stop; unobstructed alone would
	--  fire while the unit stands dry on a ledge with a clear line down. Together
	--  they say something the plan cannot argue with: the unit is IN water and
	--  nothing is between it and the target.
	--
	--  "IN THE TRACED TILES" WAS THE OTHER CANDIDATE AND IS WEAKER. The trace
	--  floods contiguously, so two nearly separate pools joined at a single tile
	--  read as one body -- the unit would abandon its board for water it cannot
	--  actually cross. swimReachable sweeps the BODY along the line instead, so a
	--  gap too narrow for 1.6 tiles answers no.
	--
	--  ONE-WAY, LIKE `reached`. Once taken, the mode change follows and the
	--  hysteresis holds it; nothing re-walks to a board it has already given up.
	if plan ~= nil and not plan.reached and not plan.abandoned
	   and medium == "swim" then

		local fish = petports_currentTaskDestination()

		if swimReachable(fish) then
			plan.abandoned = true

			--  THE CACHED APPROACH TARGET IS NOW WRONG AND NOTHING ELSE WILL
			--  NOTICE. stateData.groundTarget still holds the BOARD, and it is
			--  only invalidated when the TARGET drifts -- the unit changing its
			--  mind is not a drift. Measured 2026-09-02, one tick after this
			--  fired:
			--
			--      UNIT FLY path ended with pathfinding: target [2489.5,1152.8]
			--          still 7.95624 away
			--      UNIT STEERING REFUSED ... the straight line leaves this
			--          chassis's medium
			--      UNIT progress window: moved 0 (need 2.5) in 5 s
			--
			--  The unit became a swimmer and then tried to FLY to a diving board
			--  standing in air, which canFly false refuses -- correctly, and the
			--  refusal is why it stalled rather than steering itself out of the
			--  water. Abandoning the board has to abandon the target too.
			self.petportsDiveRetarget = true

			sb.logInfo("UNIT DIVE abandoning its board at %s: already submerged at %s "
				.. "with a clear body-width run to the fish at %s -- swimming instead",
				sb.printJson(plan.launch), sb.printJson(mcontroller.position()),
				sb.printJson(fish))
		end
	end

	--  START THE DIVE.
	--
	--  STANDING ON THE BOARD, IN AIR, ON THE GROUND. All three, and the second
	--  two were missing.
	--
	--  "NOT FULLY SUBMERGED" WAS NOT THE SAME AS "OUT OF THE WATER". A body
	--  clambering out reads `mixed`, which passed, so a dive could launch while
	--  the unit was still climbing -- and then controlDown held it back down into
	--  the water it was trying to leave. Measured 2026-09-02: the one successful
	--  dive launched from [2493.76,1151.85] with its board at 1152.8, nearly a
	--  full tile BELOW it, which is not a unit standing anywhere.
	--
	--  onGround IS THE OTHER HALF, AND IT IS WHAT MAKES THE HOP MEAN ANYTHING.
	--  Hopping mid-air does nothing except overwrite a fall that was already
	--  going the right way, and it would re-fire every tick the unit was near the
	--  board while airborne.
	if plan ~= nil and plan.reached and not petports_diving()
	   and petports_swimMode() == PETPORTS_SWIM_MODE_LAND
	   and medium == "air" and mcontroller.onGround() then

		--  SHUFFLE THE LAST TILE ONTO THE BOARD FIRST.
		--
		--  The pather stops around a tile short and calls that arrived, which is
		--  fine for walking somewhere and not fine for diving: the board earned
		--  its place because a flight FROM IT is clear, and a tile of slop is a
		--  tile of different terrain under the sweep. Walking the remainder is
		--  cheaper and more honest than tightening the latch, which at the
		--  measured gaps of 0.99 to 1.23 would have stopped it diving at all.
		--
		--  TIMED OUT, NOT INSISTED ON. If that last half tile is unwalkable the
		--  dive still happens from here -- swept from the real position, so still
		--  safe -- because a stalled task is worse than an imperfect launch.
		local foot = world.magnitude(mcontroller.position(), plan.launch)

		if foot > PETPORTS_DIVE_BOARD_FOOT then
			plan.shuffleUntil = plan.shuffleUntil
				or (world.time() + PETPORTS_DIVE_SHUFFLE_TIMEOUT)

			if world.time() < plan.shuffleUntil then
				local direction = plan.launch[1] > mcontroller.position()[1] and 1 or -1

				mcontroller.controlMove(direction, false)
				mcontroller.controlFace(direction)

				petports_assertSwimMode()
				petports_diveDebugDraw()
				return
			end

			if not plan.shuffleGaveUp then
				plan.shuffleGaveUp = true
				sb.logInfo("UNIT DIVE could not close the last %s tiles to its board "
					.. "at %s -- launching from %s anyway",
					sb.printJson(foot), sb.printJson(plan.launch),
					sb.printJson(mcontroller.position()))
			end
		end

		--  HOP FIRST, THEN DROP-THROUGH.
		--
		--  The hop is what unsticks the feet, and it is also the only part of the
		--  flight that goes UP -- so on a board under a low ceiling it is the
		--  HOP the sweep refuses, not the dive. Retrying without one asks the
		--  platform to be passed rather than jumped off, which is what
		--  controlJump alongside controlDown does, and it needs no headroom.
		--
		--  ONE RETRY, NOT A SEARCH. If a flat drop from this board is blocked too
		--  then something solid is under it, and no hop height fixes that.
		local launched, why = petports_diveLaunch(plan)

		if not launched then
			--  THE RETRY NEEDS A PLATFORM TO DROP THROUGH. Without one,
			--  controlJump is not a release, it is an eight tile jump -- see
			--  platformUnderfoot. A board with solid ground under it and no room
			--  to hop is simply not divable, and saying so is better than
			--  launching the unit over the pool.
			local dropped, dropWhy = false, "there is no platform under the feet to drop through"

			if platformUnderfoot() then
				dropped, dropWhy = petports_diveLaunch(plan, 0)
			end

			if not dropped then
				--  BLACKLIST THE BOARD, THEN DROP THE PLAN. Dropping alone
				--  re-traced and picked the SAME board, which refused again:
				--  measured 2026-09-02, fifteen refusals in four seconds from
				--  [2504.5,1152.8], blocked at sample 3 of 12 every time by a
				--  wall a tile to its left. "Backing off" that re-offers the
				--  identical answer is a spin, not a back-off.
				petports_diveRefuse(plan.launch,
					string.format("%s; and with no hop, %s",
						tostring(why), tostring(dropWhy)))
				petports_diveForget()
			end
		end
	end

	--  END THE DIVE.
	--
	--  CHECKED BEFORE THE MODE IS CHOSEN, because petports_desiredSwimMode reads
	--  petports_diving() and would hold the unit in flight for one more tick
	--  after it had already landed.
	local outcome = petports_diveOutcome()

	if outcome ~= nil then
		local landed = outcome == "landed"

		sb.logInfo("UNIT DIVE %s at %s: %s (rose %s tiles above the board, %s)",
			landed and "SUCCEEDED" or "FAILED",
			sb.printJson(mcontroller.position()), tostring(outcome),
			sb.printJson(self.petportsDiveFlight.peak or 0),
			self.petportsDiveFlight.dropThrough and "drop-through" or "hop")

		self.petportsDiveFlight = nil

		--  LET THE NEXT MODE CHANGE HAPPEN AT ONCE. The rebuild throttle is
		--  there to stop a flickering condition thrashing the pather, and the end
		--  of a dive is neither flickering nor optional: the unit is in water and
		--  needs to be a swimmer NOW, not up to a second from now.
		self.petportsSwimModeRebuiltAt = nil

		--  A FAILED DIVE STRIKES THE BOARD OFF AND DROPS THE PLAN. A flight that
		--  ended on solid ground is proof about that board, exactly as a refused
		--  sweep is -- and without striking it the trace re-picks it and the unit
		--  hops there forever.
		--
		--  A SUCCESSFUL ONE KEEPS THE PLAN, which is what stops it re-diving: the
		--  plan carries `reached`, and the trigger needs the unit dry and
		--  grounded, which after a success it is not.
		if not landed then
			if plan ~= nil then petports_diveRefuse(plan.launch, outcome) end
			petports_diveForget()
		end
	end

	petports_assertSwimMode()

	--  Per tick, because debug draws last exactly one frame -- see
	--  petports_diveDebugDraw's header. This is the only hook that already runs
	--  every tick from both the task action and petBehavior.
	petports_diveDebugDraw()
end

--  RE-ASSERT THE CURRENT MODE'S PHYSICS. CALLED EVERY TICK.
--
--  mcontroller.applyParameters DOES NOT EXIST ON A MONSTER, AND THE REASON IS
--  WORTH KEEPING BECAUSE THE WRONG ANSWER IS ONE SEARCH RESULT AWAY.
--
--  THERE ARE TWO mcontroller TABLES AND THE WIKI DOCUMENTS THEM SEPARATELY.
--  MovementController -- projectiles and vehicles -- HAS applyParameters and
--  resetParameters. ActorMovementController -- monsters, npcs, tech, status
--  effects, active items -- HAS NEITHER. It exposes baseParameters() to read and
--  controlParameters() to write, and nothing else.
--
--  Measured 2026-09-02: every pather build threw "attempt to call a nil value
--  (field 'applyParameters')", the unit script died, the port saw no unit and
--  respawned it, roughly sixty times in one log. dd.locomotion.otter's plan to
--  switch gravity with applyParameters was never executed, so the call had never
--  been proven -- it was inherited from a design note as though it had been.
--  petportsFlopState's header names applyParameters too, and only ever as the
--  thing it chose NOT to use.
--
--  SO controlParameters IS THE ONLY LEVER, AND IT LAPSES EVERY TICK. That is
--  what makes this function exist at all: a one-shot write at freshPather would
--  hold for a single frame and then evaporate.
--
--  setAutoClearControls(false) WOULD MAKE CONTROLS PERSIST AND IS NOT USED. It
--  is global to every control, so controlFly and controlApproachVelocity would
--  persist too and the last movement command would repeat forever. Clearing and
--  re-asserting per tick is this function, with none of that risk.
--
--  WHETHER IT MOVES baseParameters IS THE OPEN QUESTION OF THIS BUILD, AND IT
--  DECIDES THE WHOLE DESIGN. petports_freeMover, petports_pathOptions'
--  mustEndOnGround, the swim mover's controlFly branch and PathFinder:
--  canPathfind all read mcontroller.baseParameters(). The documentation does not
--  settle it -- controlParameters is described as merging INTO the base
--  parameters while baseParameters() is described as returning THE BASE -- so it
--  is measured here rather than argued. If a control override is visible there,
--  the mode machine works as designed and nothing else is needed. If it is not,
--  the physics will float while every resolver still treats the unit as a
--  walker, and the fix is to make petports_freeMover read the MODE instead.
--
--  The swim-mode log line reports baseParameters directly for exactly this
--  reason. Do not remove it until the question is answered and recorded.
function petports_assertSwimMode()
	if not petports_gravitySwitchable() then return end

	local mode = petports_swimMode()

	--  DIVING: GRAVITY, AND controlDown EVERY TICK.
	--
	--  controlDown IS SAFE HERE FOR THE REASON petports_flyapproach GIVES AND
	--  petportsTimedDrop DOES NOT HAVE. The recorded fault is that it starts a
	--  fall-through state whose duration script cannot observe, so no release
	--  condition can be right -- which matters only to code that must know WHEN
	--  the platform was cleared. A dive never asks: it needs to end up wet, and
	--  an extra platform passed on the way down is the direction it was going.
	--
	--  UNCONDITIONAL ONLY WITHIN THIS MODE. flyapproach holds it conditionally
	--  because a gravity chassis that holds it forever falls through everything
	--  it tries to stand on. The mode is the condition here, and it ends the
	--  moment the unit is wet or the dive has failed.
	if mode == PETPORTS_SWIM_MODE_DIVING then
		mcontroller.controlParameters({ gravityEnabled = true })
		mcontroller.controlDown()

		local flight = self.petportsDiveFlight

		--  controlJump ONCE, ALONGSIDE A controlDown THAT IS HELD.
		--
		--  HELD, IT IS A POGO STICK. controlJump is a press, not a state: every
		--  tick it is asserted is another jump the moment the feet touch
		--  anything. Measured 2026-09-02, a drop-through launched from
		--  [2493.15,1152.8] and was at [2493.8,1156.32] two seconds later --
		--  THREE AND A HALF TILES ABOVE the board it was trying to fall off,
		--  having jumped its way up out of the hole instead of down through it.
		--
		--  THE ASYMMETRY IS THE WHOLE FIX. The drop-through is one press of jump
		--  WHILE down is held: the press is the event that releases the platform
		--  and the hold is what keeps it released. Latched on the flight so it
		--  survives across ticks and dies with the dive.
		if flight ~= nil and flight.dropThrough and not flight.jumped then
			flight.jumped = true
			mcontroller.controlJump()
		end

		--  HOLD THE SOLVED HORIZONTAL VELOCITY, LEAVE THE VERTICAL ALONE. See
		--  petports_diveLaunch on why this is re-asserted rather than set once.
		--  Reading the live vy back and writing it unchanged is deliberate: it
		--  keeps gravity's integration untouched while pinning x.
		--
		--  NOT ON THE LAUNCH TICK. petports_setSwimMode runs from inside
		--  petports_diveLaunch, one line after the hop is written, so this can
		--  fire before the controller has integrated anything -- and reading vy
		--  back then would hand the hop's own vy0 to a write that could just as
		--  easily read zero and erase it. `airborne` is latched by
		--  petports_diveOutcome the first tick the feet are actually off the
		--  ground, which is the earliest moment this is safe and needed.
		if flight ~= nil and flight.airborne and not flight.aligned
		   and flight.vx ~= nil then
			mcontroller.setVelocity({ flight.vx, mcontroller.velocity()[2] })
		end

		return
	end

	if mode == PETPORTS_SWIM_MODE_LAND then return end

	--  liquidBuoyancy 1.0 IS WHAT LETS `exiting` KEEP GRAVITY AND STILL FLOAT.
	--  vanilla's own fish value, recorded in petports_aquatic's header.
	mcontroller.controlParameters({
		gravityEnabled = mode ~= PETPORTS_SWIM_MODE_AQUATIC,
		liquidBuoyancy = (mode == PETPORTS_SWIM_MODE_EXITING) and 1.0 or 0.0
	})
end

--  APPLY A MODE. RETURNS THE MODE IN FORCE AFTERWARDS.
--
--  CALLED ONLY FROM freshPather, NEVER MID-ROUTE, AND THAT RESTRICTION IS THE
--  WHOLE REASON THIS IS SAFE. dd.locomotion.otter refused runtime gravity
--  switching because PathFinder:start reads baseParameters and PathMover:new
--  captures mustEndOnGround at construction, so a flip underneath a live plan
--  corrupts it. A flip immediately before the pather is built has no live plan
--  to corrupt -- the same argument petportsFlopState's header makes for a
--  beached unit that has yielded its task.
--
--  A NO-OP WHEN THE MODE IS UNCHANGED, so the ordinary case costs one string
--  compare and writes nothing.
function petports_setSwimMode(mode, why)
	if not petports_gravitySwitchable() then return PETPORTS_SWIM_MODE_LAND end

	local current = petports_swimMode()
	if mode == current then return current end

	self.petportsSwimMode = mode
	petports_assertSwimMode()

	--  ALWAYS LOGGED, AND IT REPORTS baseParameters RATHER THAN WHAT WE ASKED
	--  FOR. What we asked for is in the source; what the engine now believes is
	--  the open question this build exists to answer -- see the header above.
	--  Printing the request would have told us nothing we did not already know.
	sb.logInfo("UNIT swim mode %s -> %s at %s (medium %s): asked gravity %s, "
		.. "baseParameters now reports gravityEnabled %s, onGround %s, "
		.. "liquidMovement %s, freeMover %s -- %s",
		tostring(current), tostring(mode),
		sb.printJson(mcontroller.position()),
		tostring(petports_mediumAt(mcontroller.position(), mcontroller.boundBox())),
		tostring(mode ~= PETPORTS_SWIM_MODE_AQUATIC),
		tostring(mcontroller.baseParameters().gravityEnabled),
		tostring(mcontroller.onGround()),
		tostring(mcontroller.liquidMovement()),
		tostring(petports_freeMover()),
		tostring(why or "no reason given"))

	return mode
end

--  IS THIS UNIT CURRENTLY SOMEWHERE ITS CHASSIS MAY NOT BE?
--
--  ASKED BY THE PORT, on the environment timer, and the answer is a re-home. It
--  replaces the escape clause that used to live in planMediumValid -- see the
--  header there for the two versions of that clause and how each one became a
--  licence to cross to a DIFFERENT body of water rather than a way back into
--  the one the unit left.
--
--  THE UNIT IS NOT ASKED TO RESCUE ITSELF. A displaced unit wants to be at its
--  port; the port can put it there instantly and for free; and rehomeUnit is the
--  rescue every recovery ladder in this mod already ends with. Improvising a
--  route back is strictly worse, and was measured going somewhere else entirely.
--
--  MEANINGLESS FOR A WALKER, AND IT SAYS SO RATHER THAN GUESSING.
--  petports_mediumAllows short-circuits to true for a gravity-enabled chassis --
--  its medium is physics, not permission -- so a bare boolean would report
--  "fine" for every walker regardless of where it was standing, which is true
--  today and would silently stay true if that ever stopped being so. `checked`
--  keeps it honest: the port can tell "this unit is fine" from "this question
--  does not apply to this unit".
--
--  RETURNS ONE TABLE, per the marshalling convention this file records twice.
--  world.callScriptedEntity returns nil SILENTLY for a function the target does
--  not define, so a bare boolean could not be told apart from an older unit
--  script -- and failing closed on that would teleport working units after a
--  partial install.
function petports_outOfMedium()
  if not petports_freeMover() then
    return { checked = false, out = false, medium = "physics" }
  end

  --  A CHASSIS THAT MANAGES ITS OWN MEDIUM IS NOT ASKED EITHER.
  --
  --  `checked = false` here is the same answer a walker gets and it is the same
  --  claim: the question does not apply. An amphibious unit is gravity-DISABLED
  --  only because petports_setSwimMode put it that way on purpose, and while it
  --  is that way petports_media reports canFly false -- so every medium except
  --  water reads as a violation and the unit is "out" the instant it surfaces.
  --
  --  FOUR THINGS HANG OFF THIS ONE FIELD, AND ALL FOUR ARE WRONG FOR THIS
  --  CHASSIS. In call order:
  --
  --    petports_petport.lua mediumCheck   re-homes it -- 30s on the recoverable
  --                                       ladder, for surfacing in a mode it
  --                                       chose
  --    petportsFlopState.enter            turns gravity back ON and hops, which
  --                                       is a second writer fighting this one
  --                                       over the same parameter
  --    petportsTaskAction.update          yields the task action mid-task
  --    petports_petBehavior.run           queues no action at all, so the unit
  --                                       stops working entirely
  --
  --  A 30-SECOND TIMER THAT RE-HOMES A UNIT BUILT FOR BOTH MEDIA, because the
  --  permission function is too coarse to describe it, is not a safety net --
  --  it is the safety net firing on the one chassis it was never about.
  --
  --  WHAT STILL PROTECTS THIS UNIT. mediumAllows tests `forbidden` FIRST, above
  --  every short-circuit, so the lava and poison deny-list is untouched by this.
  --  And the port's health check still re-homes a unit that stops making
  --  progress, whatever the reason.
  if petports_gravitySwitchable() then
    return { checked = false, out = false, medium = "managed" }
  end

  local bounds = mcontroller.boundBox()
  local position = mcontroller.position()

  return {
    checked = true,
    out = not petports_mediumAllows(position, bounds),
    medium = petports_mediumAt(position, bounds),
    position = position
  }
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

function petports_flyPointNear(position, radius, mediumVerified)
  if position == nil then return nil end

  --  petports_freeMover, NOT A RAW gravityEnabled READ. A unit in aquatic swim
  --  mode has its gravity overridden by controlParameters, which the accessor
  --  cannot see -- so the raw test refused every open-water point to the one
  --  chassis that had just asked to be a free mover.
  if not petports_freeMover() then return nil end

  radius = radius or 4

  local bounds = mcontroller.boundBox()
  local originX = math.floor(position[1]) + 0.5
  local originY = math.floor(position[2]) + 0.5

  --  THE TARGET'S OWN MEDIUM, BEFORE ANY SEARCHING. Refusing here rather than
  --  inside the loop is not just an optimisation: the loop's job is to find the
  --  nearest usable spot, and for an out-of-medium target every answer it can
  --  give is wrong. Letting it run produced a unit that hovered under a crate
  --  it could not reach and reported the work done.
  --
  --  IT SAMPLES ONE POINT, WHICH IS ONLY ENOUGH FOR A POINT TARGET. An OBJECT
  --  has a footprint, and a footprint can straddle a waterline: a shipping
  --  container with its bottom half flooded is reachable by a swimmer from below
  --  and a flyer from above, and both are legitimate. Asked about its origin
  --  tile -- which sits in the flooded half -- this refused the flyer outright
  --  and said "no position near it can help" while five open air tiles sat
  --  directly above, inside the search radius. Measured on crate 204 at
  --  [2553,1147]: the flyer stalled holding one unstackable beacon it had
  --  nowhere to put, while the aquatic and amphibious units worked the same
  --  container all session.
  --
  --  SO THE CALLER MAY VOUCH INSTEAD OF THIS GUESSING. `mediumVerified` means a
  --  caller has already run the medium ladder over the target's REAL footprint
  --  -- petports_habitatAnyPointSuits over world.objectSpaces, port-side, which
  --  is the question this cannot ask from a single tile. When it has, the search
  --  runs and finds the touchable face.
  --
  --  NOTHING THAT CANNOT VOUCH LOSES THE GUARD. Medic and animal work call the
  --  same resolver deliberately WITHOUT a medium check, because a patient or a
  --  Mooshi has moved by the time the unit arrives and a verdict about a stale
  --  point buys nothing. Those still get the veto, and so does every call the
  --  unit makes to re-resolve its own destination on arrival. Removing it
  --  outright would hand the hover-and-report bug straight back to them.
  local targetOk, targetWhy = petports_targetAllowed(position)

  if mediumVerified then
    targetOk = true
    targetWhy = (targetWhy or "medium") .. ", and the caller vouched for the footprint"
  end

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

--  THE PORT'S ENTRY POINT, AND IT IS NOW A DELEGATE.
--
--  IT USED TO BE A SECOND IMPLEMENTATION AND THAT WAS THE BUG. It ran its own
--  first-fit column search over findGroundPosition and had NO DESCEND STEP, so
--  underwater -- where validStandingPosition calls every point standable for a
--  chassis that does not avoid liquid -- it handed back a point hanging in open
--  water. standableNear in petportsTaskAction.lua grew the descend fix, the
--  distance ranking across columns and the platform-aware floor test; this one
--  grew none of them, and the port has been asking the wrong one of the two.
--
--  See `arch.pathing.oneanchor`: there were THREE functions answering "where
--  does a unit stand near this point" and no two agreed. This is one of the two
--  that had to go.
--
--  THE FREE-MOVER BRANCH WENT WITH IT, and its reasoning is preserved in
--  standableNear because both copies had it and both were right: a free-moving
--  chassis owns this answer outright INCLUDING THE nil, because nil from
--  petports_flyPointNear means REFUSED as well as "not a flyer". Falling through
--  to a ground search handed an aquatic unit a dry-land standing spot one line
--  after it had declined the target for being dry.
--
--  CALLED BARE. If petportsTaskAction.lua is not in the monstertype's scripts
--  list this raises on the first resolve, which is the intent -- see the export
--  note beside petports_standablePoint.
--  `mediumVerified` is passed by the port when it has already run the medium
--  ladder over the target's own footprint. See the note in petports_flyPointNear.
function petports_standingPointNear(position, radius, mediumVerified)
  if position == nil then return nil end
  return petports_standablePoint(position, nil, radius, mediumVerified)
end

--  WHERE THIS UNIT PARKS WHEN IT IS AT HOME.
--
--  THE PORT ASKS THIS, AND IT IS THE SAME CALL THE UNIT'S OWN LEASH MAKES FOR
--  ITSELF. approachTargetFor resolves a "return" task with
--  `standableNear(rawPosition, 0)`; this is that call with the port's position.
--  Identical inputs into identical code, so the port's recall and the unit's
--  tether cannot resolve to different points -- which they did, for as long as
--  there were two resolvers. See `arch.pathing.oneanchor`.
--
--  searchUp 0 IS THE HOMEWARD BIAS AND IT LIVES HERE, ON THE UNIT, rather than
--  being passed in. findGroundPosition tests UP BEFORE DOWN at every step, so an
--  unbiased resolve puts the unit on the port's own roof -- measured, a port at
--  [1203,728] resolving to [1203.5,731.875], 3.875 tiles up, while the floor
--  beneath it was fine.
--
--  A DEDICATED FUNCTION RATHER THAN AN ARGUMENT ON petports_standingPointNear,
--  because the alternative was a nil in the MIDDLE of a callScriptedEntity
--  argument list and this mod has not measured whether that boundary preserves
--  one. It also names the question the port is actually asking.
--
--  NO radius, SO THE UNIT'S OWN DEFAULT APPLIES. A number here would be a
--  constant needing to stay equal to one in another file, which is the drift
--  this change exists to remove.
function petports_homePointNear(position)
  if position == nil then return nil end
  return petports_standablePoint(position, 0)
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
  --  petports_freeMover, NOT A RAW gravityEnabled READ -- see its header. A
  --  swim-mode unit needs mustEndOnGround FALSE, and the accessor would say
  --  otherwise and refuse every target that is not standable.
  local flying = petports_freeMover()

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

--  EATING. ONE TREAT, ONE CALL, AND THE UNIT DECIDES WHAT IT IS WORTH.
--
--  arch.fuel.eat. The port forwards a descriptor and nothing else. Preference
--  is resolved HERE because this is the only place that natively holds both
--  halves of the question -- monster.seed() and the chassis's own
--  petports_fuelFlavors -- so no version of it has to travel over the wire and
--  no second copy can disagree with this one.
--
--  A WRONG FLAVOR IS EXACTLY AS GOOD AS NO FLAVOR, NEVER WORSE. dd.fuel.flavor
--  is explicit that there must be no way to feed a unit something bad for it:
--  a player who ignores reagents loses a bonus and is never punished, and one
--  who flavors the wrong thing has wasted a reagent rather than ruined a batch.
PETPORTS_FUEL_PLAIN     = 60
PETPORTS_FUEL_PREFERRED = 120

--  THE LATCH. Derived from the seed, so it is stable without being stored --
--  but stored anyway, because the derivation runs over the ELIGIBLE list and
--  that list can change under a unit. Re-rolled only when the latched flavor
--  stops being eligible, which is the difference between "a modlist change
--  moved my unit's favourite" and "a modlist change moved EVERY unit's
--  favourite".
function petports_unitFlavor()
  local eligible = config.getParameter("petports_fuelFlavors", nil)

  if storage.petportsFlavor ~= nil
     and petports_flavorEligible(storage.petportsFlavor, eligible) then
    return storage.petportsFlavor
  end

  storage.petportsFlavor = petports_preferredFlavor(monster.seed(), eligible)

  sb.logInfo("UNIT rolled preferred flavor %s from seed %s",
    tostring(storage.petportsFlavor), tostring(monster.seed()))

  return storage.petportsFlavor
end

--  RETURNS ONE TABLE, OR nil. `{ amount = n, flavor = id }` on a treat eaten,
--  nil when nothing was taken and the player keeps it -- a slot that swallows a
--  treat and does nothing reads as a broken machine.
--
--  ONE TABLE BECAUSE callScriptedEntity DOES NOT CARRY A SECOND RETURN VALUE.
--  This returned `amount, flavor` for one build and the port saw the amount
--  and never the flavor: totals counted, every per-flavor row stayed at zero.
--  Nothing else in the mod had ever asked for two -- every other call site
--  binds `ok, oneValue` -- so there was no working example to have copied and
--  the assumption went in untested. DO NOT GO BACK TO MULTIPLE RETURNS.
--
--  THE SECOND RETURN IS THE TREAT'S FLAVOR, NOT THE UNIT'S PREFERENCE. The port
--  counts what was actually eaten, so a unit that prefers savory and eats sour
--  must increment sour. Carried back from here rather than re-derived on the
--  port for the same reason the amount is: this is the side holding the item
--  and the tag test that decided it.
--
--  A PARTIAL SWALLOW IS A FULL TREAT WHEN A PLAYER CHOSE IT, AND A REFUSAL WHEN
--  NOBODY DID. `sparing` is what tells the two apart.
--
--  Manual: a unit at 880 of 900 eats a plain treat, gains 20, and the treat is
--  gone. Refusing would mean a nearly-full unit cannot be topped up before a
--  long job, and with a refusal sound wired the player reads that as a broken
--  slot rather than as thrift.
--
--  Automatic: dd.fuel.autoeat says the opposite, and MEASURED IN GAME on
--  2026-09-03 the automatic path did the manual thing. A meal from 217.98 took
--  five clean 120s and then a sixth treat that delivered 82.02 -- 37.98 of a
--  treat the player farmed, burned by a unit nobody was watching, on every
--  meal.
--
--  THE TEST LIVES HERE BECAUSE THIS IS THE ONLY SIDE WITH A LIVE NUMBER. The
--  port mirrors fuel on the anchor tick, which is stale after the first bite
--  of a loop that eats six.
function petports_feedFuel(descriptor, sparing)
  if type(descriptor) ~= "table" or type(descriptor.name) ~= "string" then
    return nil
  end

  if not root.itemHasTag(descriptor.name, "petports_fuel") then return nil end

  local maximum = status.resourceMax("petports_fuel")
  local current = status.resource("petports_fuel")
  if maximum == nil or current == nil or current >= maximum then return nil end

  --  THE FLAVOR TAG IS THE ITEM'S, THE PREFERENCE IS THE UNIT'S. Matching on
  --  the tag rather than the item name is what lets a rarity tier or a third
  --  party's treat count as the same flavor without being listed anywhere.
  local preferred = petports_unitFlavor()
  local amount    = PETPORTS_FUEL_PLAIN
  local eaten     = nil

  --  ONE WALK OF THE MANIFEST ANSWERS BOTH QUESTIONS. What flavor is this, and
  --  is it the one this unit likes. Plain treats carry petports_flavor_plain
  --  and land here as "plain", which is a real answer rather than a nil -- the
  --  stats row for unflavored treats is a row a player should see.
  for _, flavor in ipairs(petports_flavors()) do
    if root.itemHasTag(descriptor.name, "petports_flavor_" .. flavor.id) then
      eaten = flavor.id
      break
    end
  end

  if eaten == nil and root.itemHasTag(descriptor.name, "petports_flavor_plain") then
    eaten = "plain"
  end

  if preferred ~= nil and eaten == preferred then
    amount = PETPORTS_FUEL_PREFERRED
  end

  --  SPARING REFUSES RATHER THAN OVERFILLS, and refusing is what ends the
  --  port's meal loop -- so this is also the stop signal for a unit that is
  --  full enough, not just a rule about waste.
  if sparing == true and amount > (maximum - current) then
    return nil
  end

  status.modifyResource("petports_fuel", amount)

  --  KEEP THE MIRROR HONEST IMMEDIATELY. The port only resamples on its anchor
  --  tick, and a player who feeds a unit and sees no bar movement for a second
  --  will feed it again.
  if storage.petResources ~= nil then
    storage.petResources.petports_fuel = status.resource("petports_fuel")
  end

  sb.logInfo("UNIT ate %s (%s) for %s fuel (prefers %s), now %s",
    tostring(descriptor.name), tostring(eaten), tostring(amount),
    tostring(preferred), tostring(status.resource("petports_fuel")))

  return { amount = amount, flavor = eaten }
end
