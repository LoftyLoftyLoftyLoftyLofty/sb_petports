require "/scripts/util.lua"
require "/scripts/vec2.lua"

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
local VENT_DEBUG = false

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

--  Every vent this one is wired to, in either direction.
function partnerIds()
  local ids = {}

  for i = 0, object.outputNodeCount() - 1 do
    collectIds(object.getOutputNodeIds(i), ids)
  end
  for i = 0, object.inputNodeCount() - 1 do
    collectIds(object.getInputNodeIds(i), ids)
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
    end
  end

  if VENT_DEBUG then
    local seen = {}
    for id, _ in pairs(ids) do
      table.insert(seen, tostring(id) .. "=" ..
        tostring(world.entityExists(id) and world.entityName(id) or "gone"))
    end
    sb.logInfo("VENT %s self=%s want=%s collected=[%s] matched=%s",
      entity.id(), tostring(object.name and object.name() or "no object.name"),
      tostring(ventName), table.concat(seen, " "), #vents)
  end

  return vents
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
  self.refreshTimer = 0
  object.setInteractive(false)
  refreshPartners()
end

function onNodeConnectionChange(args)
  refreshPartners()
end

function onInputNodeChange(args)
  refreshPartners()
end

function refreshPartners()
  self.partners = partnerIds()
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
  for _, id in ipairs(self.partners) do
    if world.entityExists(id) then
      local ok, position = pcall(world.callScriptedEntity, id, "petports_ventEntryPosition")
      if ok and position then
        table.insert(destinations, { id = id, position = position })
      end
    end
  end
  return destinations
end

--  Move an entity to one of this vent's partners.
--
--  destinationId is optional; without it a partner is chosen at random, which is
--  the sane default for a unit that just wants to be somewhere else.
--
--  Returns the destination position on success, nil on failure -- so the caller
--  can fall back to walking rather than assuming it arrived.
function petports_ventTravel(entityId, destinationId)
  if entityId == nil or not world.entityExists(entityId) then return nil end
  if #self.partners == 0 then return nil end

  local destinations = petports_ventDestinations()
  if #destinations == 0 then return nil end

  local chosen = nil
  if destinationId then
    for _, destination in ipairs(destinations) do
      if destination.id == destinationId then chosen = destination end
    end
  end
  chosen = chosen or destinations[math.random(#destinations)]

  --  Announce at both ends before the entity moves, so the effect plays where
  --  the player is looking regardless of which end that is.
  animator.playSound("vent")
  animator.burstParticleEmitter("vent")
  pcall(world.callScriptedEntity, chosen.id, "petports_ventArrival")

  world.callScriptedEntity(entityId, "petports_ventTeleport", chosen.position)

  return chosen.position
end

--  Played on the receiving vent, so travel reads as a journey rather than a
--  disappearance.
function petports_ventArrival()
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
