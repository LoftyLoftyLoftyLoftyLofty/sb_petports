require "/scripts/util.lua"
require "/scripts/vec2.lua"

--  For petports_registryTouch. A rewired vent has to announce itself on the
--  same registry version that coverage changes ride, and that lives here.
--
--  Safe to pull into an object: petports_work.lua is a pure library. It defines
--  no init, update or uninit, so nothing of this vent's own is replaced.
require "/scripts/lofty_petports/petports_work.lua"

--  M.A.U.S. UTILITY VENT
--
--  A node a ship pet can travel between. Wire two vents together and a unit can
--  move from one to the other instantly, which sidesteps pathfinding entirely --
--  worth doing deliberately, because a small ground pet has no good way to climb
--  ladders or cross decks on a multi-level ship.
--
--  WIRING
--
--  Every other wired object in the game uses wires as a SIGNAL: setOutputNodeLevel
--  on one end, getInputNodeLevel on the other. Vents use them as a LINK instead --
--  what matters is not the level but which object is on the far end, which is what
--  getOutputNodeIds / getInputNodeIds report.
--
--  That buys a nice property: ONE wire links a pair both ways. Wire A's output to
--  B's input and A discovers B through its output node while B discovers A through
--  its input node. The player does not have to think about direction, and pulling
--  the wire disconnects both ends at once.
--
--  A vent may have several partners; a travelling unit picks one.
--
--  UNVERIFIED: the exact return shape of getOutputNodeIds/getInputNodeIds. It is
--  documented as a list of connected entity ids, and partnerIds() below tolerates
--  either a plain list or a map of id -> node index. If linking silently fails,
--  log what these actually return before changing anything else.

--  Partner-resolution tracing. Off: linking is verified working. Flip to true
--  if vents stop pairing -- it prints what the node calls returned, what each
--  collected id actually is, and how many survived the name filter, which
--  separates "collected nothing" from "collected and discarded".
local VENT_DEBUG = true

--  VERIFIED 2025-08-20, twice, in game: getOutputNodeIds / getInputNodeIds
--  return a table KEYED BY ENTITY ID, whose value is the node index. Entity 18
--  wired to node 0 is `{[18] = 0}`.
--
--  TRAP THAT COST TWO ATTEMPTS: sb.printJson STRINGIFIES NUMERIC TABLE KEYS,
--  because JSON object keys can only be strings. The same table prints as
--  {"18":0}, which reads as a string key and is not one. Key type cannot be
--  inferred from printJson output -- check with type() if it matters.
--
--  Both key and value are numbers here, so there is no way to tell this shape
--  from a plain list of ids by inspecting a single entry. Do not try. The shape
--  is known; take the key.
local function collectIds(result, into)
  if result == nil then return end
  for id, _nodeIndex in pairs(result) do
    if type(id) == "number" and id ~= entity.id() then
      into[id] = true
    end
  end
end

--  WIRING IS DIRECTIONAL, AND READS AS A PIPE: a unit goes IN through an input
--  node and comes OUT through an output node.
--
--  So a wire from vent A's INPUT to vent B's OUTPUT means A can send a unit to
--  B. A is the mouth it steps into, B is where it emerges. The opposite
--  direction is a separate, independent wire.
--
--  THIS RUNS AGAINST STARBOUND'S USUAL READING, in which a signal travels from
--  an output to an input -- a switch's output drives a door's input. Here the
--  unit travels the other way along the wire. The pipe metaphor was chosen
--  deliberately: it is what a player building a transport lane expects, because
--  the thing you step into is the input.
--
--  Built backwards once already, and it is invisible from anywhere downstream.
--  It presents as routes that exist only opposite to the direction the wiring
--  describes, which reads as a pathfinding fault rather than a convention
--  error. If routes only ever work reversed, look here first.
--
--  These used to be merged into one undifferentiated partner set, which made
--  every wire bidirectional no matter which nodes a player joined. A one-way
--  drop chute was impossible to build.
--
--  Starbound's wiring tool refuses input-to-input and output-to-output, so
--  every connection that can exist is unambiguous and there is no degenerate
--  case to resolve.

--  The engine bindings are called DIRECTLY rather than passed in as function
--  values. An earlier version took them as parameters, which is tidier and
--  relies on the object callback table behaving like ordinary Lua functions --
--  an assumption about engine internals whose failure mode is every vent
--  reporting zero exits and the whole network silently disappearing. Not worth
--  the tidiness.
local function ventsOnNodes(useInputNodes)
  local ids = {}

  if useInputNodes then
    for i = 0, object.inputNodeCount() - 1 do
      local raw = object.getInputNodeIds(i)
      if VENT_DEBUG then
        sb.logInfo("VENT %s INPUT node %s (pet ENTERS here) raw %s",
          entity.id(), sb.printJson(i), sb.printJson(raw))
      end
      collectIds(raw, ids)
    end
  else
    for i = 0, object.outputNodeCount() - 1 do
      local raw = object.getOutputNodeIds(i)
      if VENT_DEBUG then
        sb.logInfo("VENT %s OUTPUT node %s (pet EXITS here) raw %s",
          entity.id(), sb.printJson(i), sb.printJson(raw))
      end
      collectIds(raw, ids)
    end
  end

  --  Only other vents. A player may well wire a vent to a door or a light by
  --  accident, and teleporting a unit into a lamp would be impolite.
  --
  --  object.name() rather than config.getParameter("objectName"). If that
  --  parameter lookup returns nil -- and it is not guaranteed to surface a
  --  top-level object config key -- then every comparison below is
  --  `entityName == nil`, which is false for everything. The ids get collected
  --  correctly and are then all discarded, which looks exactly like collecting
  --  nothing.
  local ventName = object.name and object.name() or config.getParameter("objectName")

  local vents = {}
  for id, _ in pairs(ids) do
    if world.entityExists(id) and world.entityName(id) == ventName then
      table.insert(vents, id)
    else
      sb.logInfo("VENT %s ignoring wired entity %s: exists %s name %s (want %s)",
        entity.id(), sb.printJson(id), tostring(world.entityExists(id)),
        tostring(world.entityExists(id) and world.entityName(id) or nil),
        tostring(ventName))
    end
  end
  return vents
end

--  Vents this one can SEND a unit to.
--
--  Read from OUR INPUT NODES. A unit enters here, so this vent's input is the
--  mouth, and whatever hangs off it is where that unit comes out.
function exitIds()
  return ventsOnNodes(true)
end

--  Vents that can send a unit HERE, read from our OUTPUT nodes -- this vent is
--  where they emerge. Not traversable from this end. Kept so that a
--  receive-only vent still counts as linked and still holds its residency.
function entryIds()
  return ventsOnNodes(false)
end

function partnerIds()
  local seen = {}
  local all = {}
  for _, list in ipairs({ exitIds(), entryIds() }) do
    for _, id in ipairs(list) do
      if not seen[id] then seen[id] = true; table.insert(all, id) end
    end
  end

  if VENT_DEBUG then
    sb.logInfo("VENT %s exits=%s entries=%s", entity.id(),
      sb.printJson(exitIds()), sb.printJson(entryIds()))
  end

  return all
end

--  VENT RESIDENCY
--
--  A vent holds a small region around itself loaded, reusing the petport's
--  stagehand. Without it a hop can deliver a unit into an unloaded chunk, and
--  the vent on the far side is not running to catch it.
--
--  This is a real cost and it scales with vent count, which is why it is
--  configurable -- a server owner who does not want it can patch
--  petports_ventResidency to false. The rect is small: a vent needs its own
--  mouth and the ground around it loaded, not a port-sized area.
local VENT_COVERAGE = 12

local function ventUniqueId()
  local uniqueId = entity.uniqueId()
  if not uniqueId then
    uniqueId = sb.makeUuid()
    world.setUniqueId(entity.id(), uniqueId)
  end
  return uniqueId
end

local function residencyUniqueId()
  local position = entity.position()
  return string.format("petports_ventres_%s_%s",
    math.floor(position[1]), math.floor(position[2]))
end

local function ensureVentResidency()
  if not config.getParameter("petports_ventResidency", true) then return end

  --  Only linked vents matter. An unlinked vent is somewhere a unit can never
  --  arrive, so holding a region open for it buys nothing.
  if #self.partners == 0 then return end

  local residencyId = residencyUniqueId()
  local existing = world.loadUniqueEntity(residencyId)
  if existing ~= nil and world.entityExists(existing) then return end

  local ok, result = pcall(world.spawnStagehand, entity.position(), "petports_residency", {
    uniqueId = residencyId,
    residencyUniqueId = residencyId,
    portUniqueId = ventUniqueId(),
    coverageSize = VENT_COVERAGE
  })

  sb.logInfo("VENT %s residency spawn id=%s ok=%s result=%s",
    entity.id(), residencyId, tostring(ok), tostring(result))
end

local function stopVentResidency()
  local residencyId = world.loadUniqueEntity(residencyUniqueId())
  if residencyId == nil then return end
  world.sendEntityMessage(residencyId, "petports_residencyStop")
end

--  DESTRUCTION ONLY -- from uninit this would drop residency on every world
--  unload.
function die()
  stopVentResidency()
end

function init()
  self.partners = {}
  self.exits = {}
  self.refreshTimer = 0
  object.setInteractive(false)
  refreshPartners()
end

function onNodeConnectionChange(args)
  sb.logInfo("VENT %s output wiring changed", entity.id())
  refreshPartners()
end

function onInputNodeChange(args)
  sb.logInfo("VENT %s input wiring changed", entity.id())
  refreshPartners()
end

--  A stable signature for the current partner set, so a change can be detected
--  without comparing tables. Sorted, because partnerIds() makes no ordering
--  promise and an order-only difference is not a change.
local function partnerSignature(ids)
  local copy = {}
  for _, id in ipairs(ids) do table.insert(copy, tostring(id)) end
  table.sort(copy)
  return table.concat(copy, ",")
end

--  Signature must cover DIRECTION, not just membership. Reversing a wire leaves
--  the partner set identical while changing every route through this vent.
local function linkSignature()
  return partnerSignature(exitIds()) .. "|" .. partnerSignature(entryIds())
end

function refreshPartners()
  self.exits = exitIds()
  self.partners = partnerIds()

  if VENT_DEBUG then
    sb.logInfo("VENT %s refreshPartners: canSendTo %s partners %s",
      entity.id(), sb.printJson(self.exits), sb.printJson(self.partners))
  end

  --  ANNOUNCE REWIRING THE SAME WAY COVERAGE ANNOUNCES ITSELF.
  --
  --  A rewired vent changes which routes exist without moving a single coverage
  --  rect, so a port diffing rects sees nothing and keeps planning against a
  --  topology that no longer exists. Bumping the shared registry version puts
  --  this on the one channel ports already poll.
  --
  --  ONLY ON AN ACTUAL CHANGE. refreshPartners also runs on a 2s timer to catch
  --  partners broken or unloaded without a node event; touching unconditionally
  --  would invalidate every port's view of the world twice a second forever.
  --
  --  The first refresh at init DOES touch, and that is intended. A vent whose
  --  partners resolve after its port has already gathered is invisible to that
  --  port otherwise -- gatherVents skips vents reporting no destinations, and
  --  nothing would ever prompt a second look. One bump per linked vent per
  --  world load is a bounded, one-time cost.
  local signature = linkSignature()
  if signature ~= self.partnerSignature then
    self.partnerSignature = signature
    petports_registryTouch()

    --  NOT behind VENT_DEBUG. Fires only on an actual rewiring, which is rare
    --  and player-initiated, and it is the one line that distinguishes "the
    --  wiring runs the other way" from "the node read returned nothing" --
    --  two faults that are indistinguishable from anywhere downstream.
    sb.logInfo("VENT %s links: exits=%s entries=%s",
      entity.id(), sb.printJson(self.exits), sb.printJson(entryIds()))
  end

  if #self.partners > 0 then
    animator.setAnimationState("ventState", "linked")
  else
    animator.setAnimationState("ventState", "idle")
  end
end

--------------------------------------------------------------------------------
--  PET-FACING API
--
--  Called by a unit's behavior via world.callScriptedEntity. Kept deliberately
--  small so the pet side can stay simple.
--------------------------------------------------------------------------------

--  Is this vent usable right now? A vent with nothing wired to it is scenery.
function petports_ventLinked()
  return #self.partners > 0
end

--  Where a unit should stand to enter. One tile above the vent, so the pet is
--  standing on it rather than inside it.
function petports_ventEntryPosition()
  return object.toAbsolutePosition(config.getParameter("entryOffset", {0, 1}))
end

--  Every destination this vent can reach, as {id, position} pairs, so a pet can
--  choose by proximity to whatever it is actually trying to reach.
function petports_ventDestinations()
  local destinations = {}
  --  EXITS ONLY -- our INPUT-node links, the vents a unit entering here comes
  --  out at. An output-side link means some other vent delivers a unit to this
  --  one; it does not mean this vent can send one back.
  for _, id in ipairs(self.exits or {}) do
    if world.entityExists(id) then
      local ok, position = pcall(world.callScriptedEntity, id, "petports_ventEntryPosition")
      if ok and position then
        table.insert(destinations, { id = id, position = position })
      else
        sb.logInfo("VENT %s exit %s unreadable: ok %s position %s",
          entity.id(), sb.printJson(id), tostring(ok), sb.printJson(position))
      end
    else
      sb.logInfo("VENT %s exit %s no longer exists", entity.id(), sb.printJson(id))
    end
  end

  if VENT_DEBUG then
    sb.logInfo("VENT %s destinations: %s", entity.id(), sb.printJson(destinations))
  end

  return destinations
end

--  Move an entity to one of this vent's partners.
--
--  destinationId is optional; without it a partner is chosen at random, which is
--  the sane default for a unit that just wants to be somewhere else.
--
--  A NAMED DESTINATION IS HONOURED OR REFUSED. NEVER SUBSTITUTED.
--
--  This used to fall through to the random pick when a named destination was no
--  longer a partner, and return that partner's position as success. A unit
--  whose route said "vent 84, exit 17" got silently posted to vent 85 instead
--  and carried on executing a plan for a place it was not standing in --
--  observed as an endless loop of hopping one vent, failing to reach the next
--  leg from the wrong side, replanning identically, and hopping again.
--
--  The random pick is right for an unspecified destination and wrong for a
--  specified one. A caller that named an exit has a plan built around it, and
--  the honest answer when that exit is gone is no answer.
--
--  Returns the destination position on success, nil on failure -- so the caller
--  can fall back to walking rather than assuming it arrived.
function petports_ventTravel(entityId, destinationId)
  sb.logInfo("VENT %s travel request: rider %s wants exit %s (our exits %s)",
    entity.id(), sb.printJson(entityId), sb.printJson(destinationId),
    sb.printJson(self.exits))

  if entityId == nil or not world.entityExists(entityId) then
    sb.logInfo("VENT %s refusing travel: rider %s does not exist",
      entity.id(), sb.printJson(entityId))
    return nil
  end

  if self.exits == nil or #self.exits == 0 then
    sb.logInfo("VENT %s refusing travel: no output wiring, nothing to exit to",
      entity.id())
    return nil
  end

  local destinations = petports_ventDestinations()
  if #destinations == 0 then
    sb.logInfo("VENT %s refusing travel: wired exits %s but none readable",
      entity.id(), sb.printJson(self.exits))
    return nil
  end

  local chosen = nil
  if destinationId then
    for _, destination in ipairs(destinations) do
      if destination.id == destinationId then chosen = destination end
    end

    --  Named and not available. Refuse rather than guess.
    if chosen == nil then
      sb.logInfo("VENT %s refusing travel: exit %s is no longer a partner",
        sb.printJson(entity.id()), sb.printJson(destinationId))
      return nil
    end
  else
    chosen = destinations[math.random(#destinations)]
    sb.logInfo("VENT %s no destination named, picked %s at random from %s",
      entity.id(), sb.printJson(chosen.id), sb.printJson(#destinations))
  end

  --  Announce at both ends before the entity moves, so the effect plays where
  --  the player is looking regardless of which end that is.
  animator.playSound("vent")
  animator.burstParticleEmitter("vent")
  pcall(world.callScriptedEntity, chosen.id, "petports_ventArrival")

  local before = world.entityPosition(entityId)
  world.callScriptedEntity(entityId, "petports_ventTeleport", chosen.position)

  sb.logInfo("VENT %s sent rider %s to exit %s: from %s asked %s landed %s",
    entity.id(), sb.printJson(entityId), sb.printJson(chosen.id),
    sb.printJson(before), sb.printJson(chosen.position),
    sb.printJson(world.entityPosition(entityId)))

  return chosen.position
end

--  Played on the receiving vent, so travel reads as a journey rather than a
--  disappearance.
function petports_ventArrival()
  sb.logInfo("VENT %s receiving an arrival", entity.id())
  animator.playSound("vent")
  animator.burstParticleEmitter("vent")
end

function update(dt)
  --  Wire callbacks cover connection changes, but a partner can also be broken,
  --  unloaded, or replaced without any node event firing here. Re-checking on a
  --  slow timer keeps the animation state and the partner list honest.
  self.refreshTimer = self.refreshTimer - dt
  if self.refreshTimer <= 0 then
    self.refreshTimer = 2.0
    refreshPartners()
    ensureVentResidency()
  end
end
