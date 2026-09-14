require "/scripts/util.lua"
require "/scripts/vec2.lua"

require "/scripts/lofty_petports/petports_work.lua"


local VENT_DEBUG = false

local function collectIds(result, into)
  if result == nil then return end
  for id, _nodeIndex in pairs(result) do
    if type(id) == "number" and id ~= entity.id() then
      into[id] = true
    end
  end
end


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

function exitIds()
  return ventsOnNodes(true)
end

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

local function partnerSignature(ids)
  local copy = {}
  for _, id in ipairs(ids) do table.insert(copy, tostring(id)) end
  table.sort(copy)
  return table.concat(copy, ",")
end

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

  local signature = linkSignature()
  if signature ~= self.partnerSignature then
    self.partnerSignature = signature
    petports_registryTouch()

    sb.logInfo("VENT %s links: exits=%s entries=%s",
      entity.id(), sb.printJson(self.exits), sb.printJson(entryIds()))
  end

  if #self.partners > 0 then
    animator.setAnimationState("ventState", "linked")
  else
    animator.setAnimationState("ventState", "idle")
  end
end


function petports_ventLinked()
  return #self.partners > 0
end

function petports_ventEntryPosition()
  return object.toAbsolutePosition(config.getParameter("entryOffset", {0, 1}))
end

function petports_ventDestinations()
  local destinations = {}
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

function petports_ventArrival()
  sb.logInfo("VENT %s receiving an arrival", entity.id())
  animator.playSound("vent")
  animator.burstParticleEmitter("vent")
end

function update(dt)
  self.refreshTimer = self.refreshTimer - dt
  if self.refreshTimer <= 0 then
    self.refreshTimer = 2.0
    refreshPartners()
    ensureVentResidency()
  end
end
