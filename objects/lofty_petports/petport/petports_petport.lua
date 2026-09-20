-- Petport object: holds the unit, finds work across its network, and dispatches and reports on tasks.

require "/scripts/util.lua"
require "/scripts/messageutil.lua"
require "/scripts/lofty_petports/petports_work.lua"

require "/scripts/lofty_petports/petports_modules.lua"
require "/scripts/lofty_petports/petports_filters.lua"

require "/scripts/lofty_petports/petports_habitat.lua"

require "/scripts/lofty_petports/petports_flavors.lua"
require "/scripts/lofty_petports/petports_upcyclerstate.lua"


STATUS_INTERVAL = 2.0

ENVIRONMENT_INTERVAL = 5.0

ENVIRONMENT_SUBMERGED_FILL = PETPORTS_HABITAT_SUBMERGED_FILL

MEDIUM_STRIKE_LIMIT = 2

MEDIUM_STRIKE_LIMIT_BEACHED = 6

HEALTH_INTERVAL = 30.0

HEALTH_STALL_LIMIT = 3

HEALTH_MOVE = 1.0

HEALTH_HOME_SLACK = 5.0
RESPAWN_GRACE = 1.0

DOOR_POLL = 0.0


PET_TOGGLES =
{
  carried = true,
  showCargo = true,
  nametag = false,
  crosshairs = true,
  hauling = true,
  restock = true,
  machines = true,
  tidy = true,
  compact = true,
  defrag = true,
  sort = true,
  chill = true,
  medicdeposit = true,
  medicrestock = true,
  farmdeposit = true,
  farmrestock = true,
  waterdeposit = true,
  waterrestock = true,
  huereverse = false
}

-- Returns whether the socketed unit has a settings group turned on.
function petportParticipates(group)
  if self.petData == nil then return false end

  local set = self.petData.toggles
  if type(set) ~= "table" then return true end
  return set[group] ~= false
end


ENABLED_KEY = "petports_enabled"


-- Returns whether the port is switched on.
function petportEnabled()
  return config.getParameter(ENABLED_KEY, true) ~= false
end

-- Returns whether the unit has crosshair markers turned on.
function petportCrosshairs()
  if self.petData == nil then return false end

  local toggles = self.petData.toggles
  if type(toggles) ~= "table" then return true end
  return toggles.crosshairs ~= false
end

WRITE_INTERVAL = 10.0

local DEBUG = true

COVERAGE_SIZE = 64

CONTAINER_FULL_BACKOFF = 60.0

BEACON_INTERVAL = 5.0

BEACON_KEY = "petports_sortingBeaconBehavior"

BEACON_ENABLED_KEY = "petports_beaconEnabled"

BEACON_FILTER_KEY = "petports_beaconFilter"

MACHINE_KEY = "petports_machine"

MACHINE_RULES_KEY = "petports_upcyclerRules"
MACHINE_ENABLED_KEY = "petports_upcyclerEnabled"

MACHINE_FEEDER_KEY = "petports_upcyclerFeeder"

IGNORE_BEACONS_TAG = "petports_ignore_inserted_beacons"

CARGO_TRACE = true

-- Returns a printable summary of a cargo list.
function petports_cargoSummary(cargo)
  if cargo == nil then return "nil" end
  if type(cargo) ~= "table" then return "NOT A TABLE (" .. type(cargo) .. ")" end

  local parts = {}
  for _, stack in ipairs(cargo) do
    table.insert(parts, string.format("%s x%s",
      tostring(stack and stack.name), tostring(stack and stack.count)))
  end

  if #parts > 0 then
    return string.format("%d stack(s): %s", #parts, table.concat(parts, ", "))
  end

  local keys = 0
  for _ in pairs(cargo) do keys = keys + 1 end

  if keys > 0 then
    return string.format("EMPTY TO ipairs BUT HAS %d KEY(S) -- json object, not array", keys)
  end
  return "empty"
end

-- Returns a cargo table as a dense array, ordered by its numeric keys.
function petports_normaliseCargo(cargo)
  if type(cargo) ~= "table" then return {} end

  local keyed = {}
  for key, stack in pairs(cargo) do
    local n = tonumber(key)
    if n ~= nil and type(stack) == "table" then
      table.insert(keyed, { n = n, stack = stack })
    end
  end

  table.sort(keyed, function(a, b) return a.n < b.n end)

  local dense = {}
  for _, entry in ipairs(keyed) do table.insert(dense, entry.stack) end
  return dense
end

-- Logs a cargo summary against a label when cargo tracing is on.
function petports_cargoTrace(where, cargo)
  if not CARGO_TRACE then return end
  local ok, text = pcall(string.format, "PETPORT CARGO | %-22s | %s",
    tostring(where), petports_cargoSummary(cargo))
  sb.logInfo("%s", ok and text or ("PETPORT CARGO | bad trace at " .. tostring(where)))
end


BEACON_REQUESTS_KEY = "petports_beaconRequests"

BEACON_FEEDER_KEY = "petports_beaconFeeder"

BEACON_ITEM_KEY = "petports_beaconItem"
BEACON_MIN_KEY = "petports_beaconMin"
BEACON_MAX_KEY = "petports_beaconMax"



PET_NAME_MAX = 24

CLAIM_TTL = 30.0

WORK_INTERVAL = 2.0

REJECT_REPEAT = 30.0

TASK_DEADLINE = 150.0

FAILURE_BACKOFF = { 1.0, 2.0, 5.0, 10.0, 30.0 }

RETRY_ALLOWANCE = 4

UNROUTABLE_BACKOFF_FLOOR = 30.0

RECALL_LIMIT = 2

STRANDED_LIMIT = 3

VENT_SEARCH_MARGIN = 24

RESIDENCY_TYPE = "petports_residency"

-- Logs a labelled value when DEBUG is set.
function petports_trace(label, value)
  if not DEBUG then return end
  if value == nil then
    sb.logInfo("[petport] %s: nil", label)
  elseif type(value) == "table" then
    sb.logInfo("[petport] %s: %s", label, sb.printJson(value))
  else
    sb.logInfo("[petport] %s: %s", label, tostring(value))
  end
end

petports_metrics = {}

-- Adds an amount to one of the unit's stat counters.
petports_metrics.add = function(key, amount)
  if self.petData == nil then return end
  if amount == nil or amount == 0 then return end

  self.petData.stats = self.petData.stats or {}
  self.petData.stats[key] = (self.petData.stats[key] or 0) + amount
end

-- Counts a treat against the total and against its flavor.
function countFed(flavor)
  petports_metrics.add("fed", 1)

  if type(flavor) == "string" and flavor ~= "" then
    petports_metrics.add("fed_" .. flavor, 1)
  else
    sb.logError("PETPORT %s counted a treat with no flavor (%s) -- the "
      .. "per-flavor rows will not add up to the total",
      stationUniqueId(), tostring(flavor))
  end
end

-- Returns this port's coverage rect.
function petports_portCoverageRect()
  return petports_coverageRect(entity.position(), COVERAGE_SIZE)
end

-- Writes this port's rect, position and network id into the registry, dropping any predecessor on the tile.
function petports_publishRegistry()
  local rect = petports_portCoverageRect()

  petports_registryClearAt(entity.position(), stationUniqueId())

  petports_registryPublish(stationUniqueId(), {
    rect = rect,
    position = entity.position(),
    participate = config.getParameter("petports_participate", true),
    id = config.getParameter("petports_networkId", 0)
  })
end

UNIT_POSITION_THRESHOLD = 4.0

-- Updates the registry entry with the unit's position and busy state once either has moved on.
function petports_publishUnitPosition()
  local registry = petports_registry()
  local entry = (registry.ports or {})[stationUniqueId()]
  if entry == nil then return end

  local position = nil
  local busy = self.task ~= nil

  if self.petId ~= nil and world.entityExists(self.petId) then
    position = world.entityPosition(self.petId)
  end

  local appeared = (position == nil) ~= (entry.unitPosition == nil)
  local moved = appeared
    or (position ~= nil and entry.unitPosition ~= nil
        and world.magnitude(position, entry.unitPosition) > UNIT_POSITION_THRESHOLD)

  if not moved and entry.busy == busy
     and entry.hasUnit == (position ~= nil) then return end

  sb.logInfo("PETPORT %s publishing unit position %s (busy %s, hasUnit %s, was %s)",
    stationUniqueId(), sb.printJson(position), tostring(busy),
    tostring(position ~= nil), sb.printJson(entry.unitPosition))

  entry.unitPosition = position
  entry.busy = busy

  entry.hasUnit = position ~= nil
  petports_registryPublish(stationUniqueId(), entry)
end

-- Returns every vent in the network's inflated rects with its entry and exits, logging the set when it changes.
function petports_gatherVents()
	local ventReport = {}

  local rects = self.networkRects
  if rects == nil or #rects == 0 then rects = { petports_portCoverageRect() } end

  local inflated = {}
  for _, area in ipairs(rects) do
    table.insert(inflated, {
      area[1] - VENT_SEARCH_MARGIN, area[2] - VENT_SEARCH_MARGIN,
      area[3] + VENT_SEARCH_MARGIN, area[4] + VENT_SEARCH_MARGIN
    })
  end
  rects = inflated

  local vents = {}
  local seen = {}

  for _, area in ipairs(rects) do
    local found = world.entityQuery({area[1], area[2]}, {area[3], area[4]}, {
      includedTypes = { "object" }
    })

    for _, id in ipairs(found or {}) do
      if not seen[id] and world.entityName(id) == "petports_petvent" then
        seen[id] = true

        local okEntry, entry = pcall(world.callScriptedEntity, id, "petports_ventEntryPosition")
        local okDest, dests = pcall(world.callScriptedEntity, id, "petports_ventDestinations")

        local exits = {}
        for _, destination in ipairs(dests or {}) do
          table.insert(exits, destination.id)
        end

        table.insert(ventReport, string.format("%s@%s->%s%s",
          tostring(id), sb.printJson(entry), sb.printJson(exits),
          (okEntry and okDest) and "" or " (CALL FAILED)"))

        if okEntry and entry ~= nil and okDest and dests ~= nil then
          table.insert(vents, { id = id, entry = entry, destinations = dests })
        else
          sb.logInfo("PETPORT %s gatherVents: DROPPED vent %s -- entry %s dests %s",
            stationUniqueId(), sb.printJson(id),
            sb.printJson(entry), sb.printJson(dests))
        end
      end
    end
  end

  table.sort(ventReport)
  local signature = table.concat(ventReport, " | ")

  if signature ~= self.ventReportSignature then
    self.ventReportSignature = signature
    sb.logInfo("PETPORT %s vents: %s", stationUniqueId(),
      signature == "" and "none" or signature)
  end

  return vents
end

-- Returns a string identifying a vent list by its ids and exits.
function petports_ventSignature(vents)
  local rows = {}
  for _, vent in ipairs(vents or {}) do
    local exits = {}
    for _, destination in ipairs(vent.destinations or {}) do
      table.insert(exits, tostring(destination.id))
    end
    table.sort(exits)
    table.insert(rows, tostring(vent.id) .. ">" .. table.concat(exits, ","))
  end
  table.sort(rows)
  return table.concat(rows, ";")
end

-- Drops cached route edges naming a vent that is gone, and returns how many went.
function petports_pruneRouteCache(vents)
  if self.routeCache == nil then return 0 end

  local live = {}
  for _, vent in ipairs(vents or {}) do live[tostring(vent.id)] = true end

  local removed = 0
  for key in pairs(self.routeCache) do
    for id in string.gmatch(key, "[ex]:(%-?%d+)") do
      if not live[id] then
        self.routeCache[key] = nil
        removed = removed + 1
        break
      end
    end
  end

  return removed
end

-- Rereads the network, units and vents when the registry version moves, and pushes them to the unit.
function petports_refreshNetwork()
  local version = petports_registryVersion()
  local unitChanged = false

  if version ~= self.registryVersion then
    self.registryVersion = version

    sb.logInfo("PETPORT %s registry version moved to %s", stationUniqueId(), sb.printJson(version))

    local rects = petports_networkRects(stationUniqueId())
    if not petports_rectListsEqual(rects, self.networkRects) then
      self.networkRects = rects
      unitChanged = true
      sb.logInfo("PETPORT %s network now %s ports", stationUniqueId(), #rects)
    end

    local units = 0
    for _, member in ipairs(petports_networkMembers(stationUniqueId())) do
      if member.hasUnit then units = units + 1 end
    end
    if units ~= self.networkUnits then
      self.networkUnits = units
      unitChanged = true

      self.routeCache = {}
      self.routeDirty = true
    end

    local vents = petports_gatherVents()
    if petports_ventSignature(vents) ~= self.ventSignature then
      self.ventSignature = petports_ventSignature(vents)
      unitChanged = true

      local removed = petports_pruneRouteCache(vents)
      if removed > 0 then self.routeDirty = true end

      sb.logInfo("PETPORT %s vent topology changed: %s vents, %s stale edges dropped",
        stationUniqueId(), #vents, removed)
    end
    self.vents = vents
  end

  if (unitChanged or self.routeDirty or self.pushedToPet ~= self.petId)
     and self.petId ~= nil and world.entityExists(self.petId) then
    world.callScriptedEntity(self.petId, "petports_setNetwork",
      self.networkRects, entity.position(), self.networkUnits)

    if self.vents == nil then
      self.vents = petports_gatherVents()
      self.ventSignature = petports_ventSignature(self.vents)
    end
    sb.logInfo("PETPORT %s pushing to unit %s: %s rects, %s vents, routeDirty %s, freshUnit %s",
      stationUniqueId(), sb.printJson(self.petId),
      sb.printJson(#(self.networkRects or {})), sb.printJson(#(self.vents or {})),
      tostring(self.routeDirty), tostring(self.pushedToPet ~= self.petId))

    world.callScriptedEntity(self.petId, "petports_setVents", self.vents)
    world.callScriptedEntity(self.petId, "petports_setRouteCache", self.routeCache)
    self.routeDirty = false
    self.pushedToPet = self.petId
  end
end

FAMILY_HELD = {}
FAMILY_STRIKES = 3
FAMILY_HOLD = 120.0

-- Returns whether a work family is held, releasing it once its hold expires.
function petports_familyOnHold(family)
  local until_ = self.familyHold and self.familyHold[family]
  if until_ == nil then return false end
  if world.time() >= until_ then
    self.familyHold[family] = nil
    sb.logInfo("PETPORT %s %s work released from its hold", stationUniqueId(), family)
    return false
  end
  return true
end

-- Records a task failure, backs the task off, and holds its family after repeated stranding.
function petports_noteFailure(taskId, reason)
  if taskId == nil then return end

  if taskId == "return:" .. stationUniqueId() then
    self.recallFailures = (self.recallFailures or 0) + 1

    self.recallAt = world.time()

    sb.logInfo("PETPORT %s recall failed (%s of %s): %s",
      stationUniqueId(), self.recallFailures, RECALL_LIMIT, reason)
    return
  end

  sb.logInfo("PETPORT %s petports_noteFailure %s: %s", stationUniqueId(), taskId, tostring(reason))

  local strandedReason =
    string.find(reason or "", "no vent route", 1, true) ~= nil
    or string.find(reason or "", "no route", 1, true) ~= nil
    or string.find(reason or "", "no net progress", 1, true) ~= nil

  if strandedReason then
    self.unreachableFailures = (self.unreachableFailures or 0) + 1
    self.unreachableAt = world.time()
    sb.logInfo("PETPORT %s unreachable failure %s of %s: %s",
      stationUniqueId(), self.unreachableFailures, STRANDED_LIMIT, reason)
  end

  if self.petId ~= nil and world.entityExists(self.petId)
     and not petports_inNetworkCoverage(world.entityPosition(self.petId)) then
    sb.logInfo("PETPORT %s not blaming %s: unit was outside the network at %s",
      stationUniqueId(), taskId, sb.printJson(world.entityPosition(self.petId)))
    return
  end

  local record = self.workFailures[taskId] or { count = 0 }
  record.count = record.count + 1

  if strandedReason then
    local family = string.match(taskId, "^(%a+):")
    if family ~= nil and FAMILY_HELD[family] then
      self.familyStrikes = self.familyStrikes or {}
      self.familyStrikes[family] = (self.familyStrikes[family] or 0) + 1
      if self.familyStrikes[family] >= FAMILY_STRIKES then
        self.familyHold = self.familyHold or {}
        self.familyHold[family] = world.time() + FAMILY_HOLD
        self.familyStrikes[family] = 0
        sb.logInfo("PETPORT %s %s work HELD for %s s: %s stranding failure(s) running",
          stationUniqueId(), family, sb.printJson(FAMILY_HOLD), sb.printJson(FAMILY_STRIKES))
      end
    end
  end

  record.unroutable = string.find(reason or "", "no vent route", 1, true) ~= nil
    or string.find(reason or "", "no route", 1, true) ~= nil

  local backoff = FAILURE_BACKOFF[math.min(record.count, #FAILURE_BACKOFF)]

  if record.unroutable and backoff < UNROUTABLE_BACKOFF_FLOOR then
    backoff = UNROUTABLE_BACKOFF_FLOOR
  end

  record["until"] = world.time() + backoff
  self.workFailures[taskId] = record

  sb.logInfo("PETPORT %s backing off %s for %s seconds (failure %s)",
    stationUniqueId(), taskId, sb.printJson(backoff), record.count)
end


-- Returns the residency unique id for this port's position.
function petports_residencyUniqueId()
  local position = entity.position()
  return string.format("petports_residency_%s_%s",
    math.floor(position[1]), math.floor(position[2]))
end

-- Spawns the residency stagehand for this port when none exists.
function petports_ensureResidency()
  local residencyId = petports_residencyUniqueId()
  local existing = world.loadUniqueEntity(residencyId)

  if existing ~= nil and world.entityExists(existing) then
    return
  end

  local ok, result = pcall(world.spawnStagehand, entity.position(), RESIDENCY_TYPE, {
    uniqueId = residencyId,
    residencyUniqueId = residencyId,
    portUniqueId = stationUniqueId(),
    coverageSize = COVERAGE_SIZE
  })

  sb.logInfo("PETPORT %s residency spawn id=%s ok=%s result=%s",
    stationUniqueId(), residencyId, tostring(ok), tostring(result))
end

-- Tells this port's residency stagehand to stop.
function petports_stopResidency()
  local residencyId = world.loadUniqueEntity(petports_residencyUniqueId())
  if residencyId == nil then return end

  world.sendEntityMessage(residencyId, "petports_residencyStop")
end

-- Drops the held task and releases its claim.
function petports_abandonTask(reason)
  if self.task == nil then return end

  sb.logInfo("PETPORT %s abandoning %s: %s", stationUniqueId(), self.task.id, reason)
  petports_claimRelease(self.task.id, stationUniqueId())
  self.task = nil
end

local PETPORT_BUILD_STAMP = "2026-09-20a every function and state table in the port script is a petports_ global"

PETPORT_PROFILE = true

local PORT_PROF_INTERVAL = 10.0
petports_portProfPhases = {}
petports_portProfAt = nil

-- Returns the process clock in seconds, or nil where it is unavailable.
function petports_portClock()
  if type(os) == "table" and type(os.clock) == "function" then
    local ok, t = pcall(os.clock)
    if ok and type(t) == "number" then return t end
  end
  return nil
end

-- Runs a function and adds its time to a named phase.
function petports_portProf(name, fn, ...)
  if not PETPORT_PROFILE then return fn(...) end

  local began = petports_portClock()
  local a, b, c = fn(...)
  local now = petports_portClock()

  local phase = petports_portProfPhases[name]
  if phase == nil then
    phase = { calls = 0, ms = 0, max = 0 }
    petports_portProfPhases[name] = phase
  end

  phase.calls = phase.calls + 1

  if began ~= nil and now ~= nil then
    local ms = (now - began) * 1000
    phase.ms = phase.ms + ms
    if ms > phase.max then phase.max = ms end
  end

  return a, b, c
end

-- Logs the phase timings on an interval and clears them.
function petports_portProfReport()
  if not PETPORT_PROFILE then return end

  local t = world.time()
  petports_portProfAt = petports_portProfAt or (t + PORT_PROF_INTERVAL)
  if t < petports_portProfAt then return end
  petports_portProfAt = t + PORT_PROF_INTERVAL

  local parts = {}
  for name, phase in pairs(petports_portProfPhases) do
    if phase.ms >= 1 then
      table.insert(parts, string.format("%s n=%s ms=%s max=%s", name,
        tostring(phase.calls),
        tostring(math.floor(phase.ms + 0.5)),
        tostring(math.floor(phase.max + 0.5))))
    end
  end
  table.sort(parts)

  sb.logInfo("PETPORT profile %s (%ss): %s", stationUniqueId(),
    tostring(PORT_PROF_INTERVAL),
    #parts > 0 and table.concat(parts, " | ") or "nothing over 1 ms")

  petports_portProfPhases = {}
end




-- Reads the config, clears the port state, and installs every message handler.
function init()
  sb.logInfo("PETPORT object build: %s", PETPORT_BUILD_STAMP)
  sb.logInfo("PETPORT work build: %s", PETPORTS_WORK_BUILD_STAMP)

  COVERAGE_SIZE = config.getParameter("petports_coverageSize", COVERAGE_SIZE)
  sb.logInfo("PETPORT coverage size: %s tiles", sb.printJson(COVERAGE_SIZE))

  petports_workHook("init")

  self.petId = nil

  self.fadingPetId = nil

  self.petUniqueId = nil
  self.petData = nil
  self.statusTimer = 0
  self.spawnTimer = 0
  self.spawning = false
  self.dirty = false
  self.writeTimer = WRITE_INTERVAL
  self.firstUpdate = true

  message.setHandler("petports_status", simpleHandler(function(status, storage)
    if self.petData then
      self.petData.status = status or self.petData.status
      self.petData.storage = storage or self.petData.storage
      self.dirty = true
      petports_trace("petStatus message -> storage", self.petData.storage)
    end
  end))

  message.setHandler("petports_headpat", simpleHandler(function()
    if self.petData == nil then return end

    petports_metrics.add("headpats", 1)

    sb.logInfo("PETPORT %s headpat (%s lifetime)", stationUniqueId(),
      sb.printJson((self.petData.stats and self.petData.stats.headpats) or 0))
  end))

  message.setHandler("petports_cargoHandoff", simpleHandler(function(payload)
    if type(payload) ~= "table" then return false end

    local item = payload.item
    if type(item) ~= "table" or type(item.name) ~= "string" then return false end

    sb.logInfo("PETPORT %s unit %s handing over %s %s it could not eat",
      stationUniqueId(), tostring(payload.unit),
      sb.printJson(item.count or 1), tostring(item.name))

    receiveCargo(item)
    return true
  end))

  message.setHandler("petports_unitDied", simpleHandler(function(payload)
    if type(payload) ~= "table" then return false end

    local position = payload.position
    if type(position) ~= "table" then return false end

    local spawnedMine = self.spawnedPetId ~= nil and payload.id == self.spawnedPetId
    local adoptedMine = self.spawnedPetId == nil and self.petId ~= nil
      and payload.id == self.petId

    if not (spawnedMine or adoptedMine) then
      sb.logInfo("PETPORT %s IGNORING a death report from unit %s at %s -- "
        .. "this port spawned %s (owns %s), so that load is not ours to spill",
        stationUniqueId(), sb.printJson(payload.id), sb.printJson(position),
        sb.printJson(self.spawnedPetId), sb.printJson(self.petId))
      return false
    end

    if adoptedMine then
      sb.logInfo("PETPORT %s honouring a death report from unit %s at %s -- "
        .. "this port has spawned nothing this session but OWNS that unit, "
        .. "which is what a re-home after a world load looks like",
        stationUniqueId(), sb.printJson(payload.id), sb.printJson(position))
    end

    petports_abandonTask("unit died at " .. sb.printJson(position))

    local cargo = {}

    if self.petData ~= nil and type(self.petData.cargo) == "table" then
      for _, stack in ipairs(self.petData.cargo) do
        table.insert(cargo, stack)
      end
    end

    if self.petData ~= nil and type(self.petData.medkit) == "table"
       and self.petData.medkit.name ~= nil then
      table.insert(cargo, self.petData.medkit)
    end

    if self.petData == nil or #cargo == 0 then
      sb.logInfo("PETPORT %s unit %s died at %s carrying nothing",
        stationUniqueId(), tostring(payload.unit), sb.printJson(position))
      return true
    end

    local spilled, lost = 0, 0

    for _, stack in ipairs(cargo) do
      local ok = pcall(world.spawnItem, {
        name = stack.name,
        count = stack.count or 1,
        parameters = stack.parameters
      }, position)

      if ok then
        spilled = spilled + 1
      else
        lost = lost + 1
        sb.logError("PETPORT %s could not spill %s x%s at %s -- ITEMS LOST",
          stationUniqueId(), tostring(stack.name),
          sb.printJson(stack.count or 1), sb.printJson(position))
      end
    end

    self.petData.cargo = {}

    self.petData.medkit = nil

    self.paneSignature = nil

    self.dirty = true
    writeBackToItem()
    self.writeTimer = WRITE_INTERVAL

    sb.logInfo("PETPORT %s unit %s died at %s -- spilled %s stack(s), %s lost",
      stationUniqueId(), tostring(payload.unit), sb.printJson(position),
      sb.printJson(spilled), sb.printJson(lost))

    return true
  end))


  message.setHandler("petports_takeCargo", simpleHandler(function()
    if self.petData == nil or self.petData.cargo == nil then return nil end
    if #self.petData.cargo == 0 then return nil end

    local stack = table.remove(self.petData.cargo, 1)
    self.dirty = true
    self.paneSignature = nil

    sb.logInfo("PETPORT %s pane took cargo: %s", stationUniqueId(), sb.printJson(stack))
    return stack
  end))

  message.setHandler("petports_setModules", simpleHandler(function(payload)
    if petports_socketedItem() == nil then return false end

    if self.petData == nil or type(payload) ~= "table" then return false end

    self.moduleToken = payload.token
    self.paneSignature = nil

    local records = payload.modules
    if type(records) ~= "table" then return false end

    -- Clears the pane signature and refuses the module write.
    local function refuse()
      self.paneSignature = nil
      return false
    end

    local duplicate, family = petports_moduleSetDuplicate(records)

    if duplicate ~= nil then
      if family ~= nil then
        sb.logError("PETPORT %s refusing module set: %s conflicts with the "
          .. "%s module already socketed", stationUniqueId(),
          tostring(duplicate), tostring(family))
      else
        sb.logError("PETPORT %s refusing module set: %s socketed twice",
          stationUniqueId(), tostring(duplicate))
      end

      return refuse()
    end

    local slots = petportModuleSlots()
    local accepted = {}
    local taken = {}

    for _, record in ipairs(records) do
      local slot = type(record) == "table" and tonumber(record.slot) or nil

      if slot == nil or slot < 1 or slot > slots then
        sb.logError("PETPORT %s refusing module set: slot %s outside 1..%s",
          stationUniqueId(), tostring(slot), tostring(slots))
        return refuse()
      end

      if taken[slot] then
        sb.logError("PETPORT %s refusing module set: slot %s appears twice",
          stationUniqueId(), tostring(slot))
        return refuse()
      end

      if not petportIsModuleItem(record.item) then
        sb.logError("PETPORT %s refusing module set: %s is not a module item",
          stationUniqueId(), sb.printJson(record.item))
        return refuse()
      end

      taken[slot] = true
      table.insert(accepted, { slot = slot, item = copy(record.item) })
    end

    self.petData.modules = accepted
    self.dirty = true
    self.paneSignature = nil

    self.pushedModuleEffects = nil

    sb.logInfo("PETPORT %s module set committed: %s of %s slot(s) filled",
      stationUniqueId(), sb.printJson(#accepted), sb.printJson(slots))
    return true
  end))

  local PANE_SOUNDS = { refuse = true, swap = true }

  message.setHandler("petports_paneSound", simpleHandler(function(payload)
    local name = type(payload) == "table" and payload.sound or nil

    if type(name) ~= "string" or not PANE_SOUNDS[name] then
      sb.logInfo("PETPORT %s refusing pane sound %s", stationUniqueId(),
        sb.printJson(name))
      return false
    end

    animator.playSound(name)
    return true
  end))

  message.setHandler("petports_feedUnit", simpleHandler(function(payload)
    if type(payload) ~= "table" or payload.item == nil then return false end
    if self.petId == nil or not world.entityExists(self.petId) then return false end

    local ok, meal = pcall(world.callScriptedEntity, self.petId,
      "petports_feedFuel", payload.item)

    if not ok then
      sb.logError("PETPORT %s feed threw: %s", stationUniqueId(), tostring(meal))
      return false
    end

    if type(meal) ~= "table" or (tonumber(meal.amount) or 0) <= 0 then
      return false
    end

    countFed(meal.flavor)
    return true
  end))

  message.setHandler("petports_setToggles", simpleHandler(function(payload)
    if self.petData == nil or type(payload) ~= "table" then return false end

    local set = {}

    for key, default in pairs(PET_TOGGLES) do
      if default then
        set[key] = payload[key] ~= false
      else
        set[key] = payload[key] == true
      end
    end

    self.petData.toggles = set

    self.dirty = true
    self.paneSignature = nil

    pushUnitLight()

    pushPetName()

    pushUnitBubbles()

    self.pushedUnitBubble = nil
    pushUnitBubble()

    self.workTimer = 0

    self.crosshairTimer = 0

    sb.logInfo("PETPORT %s toggles: %s", stationUniqueId(), sb.printJson(self.petData.toggles))
    return true
  end))

  message.setHandler("petports_setPortEnabled", simpleHandler(function(payload)
    if type(payload) ~= "table" then return false end

    local enabled = payload.enabled == true
    object.setConfigParameter(ENABLED_KEY, enabled)

    if enabled then self.spawnTimer = 0 end

    self.paneSignature = nil

    sb.logInfo("PETPORT %s port %s by player", stationUniqueId(),
      enabled and "ENABLED" or "DISABLED")
    return true
  end))

  message.setHandler("petports_setFarming", simpleHandler(function(payload)
    if type(payload) ~= "table" then return false end
    if self.petData == nil then return false end

    local set = {}
    for _, class in ipairs(FARMING_CLASSES) do
      set[class] = payload[class] ~= false
    end

    self.petData.farming = set
    self.dirty = true
    self.paneSignature = nil
    self.workTimer = 0

    sb.logInfo("PETPORT %s farming activities: %s", stationUniqueId(), sb.printJson(set))
    return true
  end))

  message.setHandler("petports_setLight", simpleHandler(function(payload)
    if type(payload) ~= "table" then return false end
    if self.petData == nil then return false end

    local set = petportLightColor()

    for _, channel in ipairs(LIGHT_CHANNELS) do
      local value = tonumber(payload[channel])

      if value ~= nil then
        local range = LIGHT_RANGE[channel]

        value = math.floor(value)
        if value < range.min then value = range.min end
        if value > range.max then value = range.max end
        set[channel] = value
      end
    end

    self.petData.light = set
    self.dirty = true
    self.paneSignature = nil

    pushUnitLight()

    sb.logInfo("PETPORT %s light colour: %s", stationUniqueId(), sb.printJson(set))
    return true
  end))

  message.setHandler("petports_setPetName", simpleHandler(function(payload)
    if type(payload) ~= "table" then return false end
    if self.petData == nil then return false end

    local name = payload.name
    if type(name) ~= "string" or name == "" then
      name = nil
    else
      name = string.sub(name, 1, PET_NAME_MAX)
    end

    self.petData.petName = name
    self.dirty = true
    self.paneSignature = nil

    pushPetName()

    sb.logInfo("PETPORT %s renamed unit to %s", stationUniqueId(),
      name == nil and "<cleared>" or tostring(name))
    return true
  end))

  self.workTimer = math.random() * WORK_INTERVAL
  self.crosshairTimer = math.random() * CROSSHAIR_INTERVAL
  self.paneTimer = math.random() * PANE_MIRROR_INTERVAL
  self.task = nil

  self.moduleToken = nil
  self.lastReject = nil
  self.lastRejectAt = 0
  self.recallFailures = 0
  self.unreachableFailures = 0
  self.taskAge = 0
  self.registryVersion = -1
  self.networkRects = nil
  self.vents = nil
  self.ventSignature = nil

  self.routeCache = {}

  self.workFailures = {}

  self.retryAllowance = {}

  message.setHandler("petports_taskProgress", simpleHandler(function(progress)
    if progress == nil or self.task == nil then return end
    if progress.id ~= self.task.id then return end
    if progress.phase ~= "moving" then return end

    if self.taskMoving then return end
    self.taskMoving = true

    self.crosshairTimer = 0

    sb.logInfo("PETPORT %s task %s is under way", stationUniqueId(), progress.id)
  end))

  message.setHandler("petports_taskReport", simpleHandler(function(report)
    if report == nil or self.task == nil then return end
    if report.id ~= self.task.id then return end

    sb.logInfo("PETPORT %s task %s %s: %s",
      stationUniqueId(), report.id, report.outcome,
      report.reason or "no detail")

    if report.cargo ~= nil then
      if report.cargo.name == nil then
        for _, stack in ipairs(report.cargo) do receiveCargo(stack) end
      else
        receiveCargo(report.cargo)
      end
    end

    if report.outcome == "done" then
      self.workFailures[report.id] = nil
      self.retryAllowance[report.id] = nil
      self.unreachableFailures = 0
      local family = string.match(tostring(report.id), "^(%a+):")
      if family ~= nil and self.familyStrikes ~= nil then self.familyStrikes[family] = 0 end
      if report.id == "return:" .. stationUniqueId() then
        self.recallFailures = 0
      end
    elseif report.retry == true
       and (self.retryAllowance[report.id] or 0) < RETRY_ALLOWANCE then
      self.retryAllowance[report.id] = (self.retryAllowance[report.id] or 0) + 1
      self.workFailures[report.id] = nil

      sb.logInfo("PETPORT %s task %s missed but is retryable (%s of %s): %s",
        stationUniqueId(), report.id,
        sb.printJson(self.retryAllowance[report.id]),
        sb.printJson(RETRY_ALLOWANCE), report.reason or "no detail")
    else
      petports_noteFailure(report.id, report.reason or "no detail")
    end

    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "withdraw" and self.task.id == report.id then
      withdrawSeed(self.task.target, self.task.seed, self.task.id,
        self.task.count)
    end

    if report.outcome == "done" and self.task ~= nil
       and self.task.id == report.id then
      petports_workHook("done", self.task, report)
    end

    petports_claimRelease(self.task.id, stationUniqueId())
    self.task = nil
  end))

  message.setHandler("petports_learnedRoute", simpleHandler(function(learned)
    if learned == nil or learned.key == nil then return end
    local held = self.routeCache[learned.key]
    if type(held) == "table" and held.r == learned.reachable then return end

    self.routeCache[learned.key] = {
      r = learned.reachable,
      t = learned.at or world.time()
    }
    self.routeDirty = true
  end))

  object.setInteractive(true)
end

-- Stops the residency and removes this port from the registry.
function die()
  self.destroyed = true

  petports_stopResidency()

  petports_registryRemove(stationUniqueId())
end

-- Abandons the task, runs the uninit hooks, clears the crosshairs, and saves the unit back into its item.
function uninit()
  petports_abandonTask("petport unloading")

  petports_workHook("uninit")

  petports_crosshairClear()

  saveAndDespawn(false, not self.destroyed)
end


-- Returns whether the unit exists.
function hasPet()
  return self.petId ~= nil and world.entityExists(self.petId)
end

-- Adopts a unit's id and takes its seed, food likings, known players and resources into the pet data.
function setPet(entityId, params)
  if self.petId ~= nil and self.petId ~= entityId then
    return false
  end
  self.petId = entityId

  if params and self.petData then
    self.petData.storage = self.petData.storage or {}

    if params.seed and params.seed ~= self.petData.seed then
      self.petData.seed = params.seed
      self.dirty = true
    end

    if self.spawning then
      self.spawning = false
      return true
    end

    if params.foodLikings and not compare(params.foodLikings, self.petData.storage.foodLikings) then
      self.petData.storage.foodLikings = params.foodLikings
      self.dirty = true
    end

    if params.knownPlayers and not compare(params.knownPlayers, self.petData.storage.knownPlayers) then
      self.petData.storage.knownPlayers = params.knownPlayers
      self.dirty = true
    end

    self.petData.storage.petResources = params.petResources or self.petData.storage.petResources
  end
  return true
end


-- Returns the item in the port's socket, or nil.
function petports_socketedItem()
  local item = world.containerItemAt(entity.id(), 0)
  if item == nil or item.name == nil then return nil end
  return item
end

-- Returns an item's stored pet seed.
function petports_itemSeed(item)
  if item == nil or item.parameters == nil then return nil end
  if item.parameters.petData == nil then return nil end
  return item.parameters.petData.seed
end

-- Returns the pet data merged from an item's config and its parameters, with the cargo normalised.
function petports_petDataFrom(item)
  local base = root.itemConfig(item)
  local data = {}
  if base and base.config and base.config.petData then
    util.mergeTable(data, copy(base.config.petData))
  end
  if item.parameters and item.parameters.petData then
    util.mergeTable(data, copy(item.parameters.petData))
  end
  if data.monsterType == nil then return nil end

  petports_cargoTrace("petDataFrom: off item", data.cargo)

  data.cargo = petports_normaliseCargo(data.cargo)
  petports_cargoTrace("petDataFrom: normalised", data.cargo)

  petports_trace("read from item", data)
  return data
end

-- Spawns the unit at the port's spawn offset with its saved status, storage and name.
function spawnPet()
  petports_cargoTrace("spawnPet: entry", self.petData and self.petData.cargo)
  if self.petData == nil or self.petData.monsterType == nil then return end
  if self.petId ~= nil and world.entityExists(self.petId) then return end

  local spawnPosition = object.toAbsolutePosition(config.getParameter("petSpawnOffset", {0, 2}))

  local parameters = {
    level = math.max(world.threatLevel(), world.getProperty("ship.level") or 0, 1),

    persistent = true,

    relocatable = false,

    stationUniqueId = stationUniqueId(),

    initialStatus = copy(self.petData.status) or {},
    initialStorage = copy(self.petData.storage) or {},

    petName = self.petData.petName,

    petports_showNametag = petportNametag()
  }

  local saved = self.petData.storage or {}
  parameters.petResources = copy(saved.petResources)
  parameters.knownPlayers = copy(saved.knownPlayers)
  parameters.foodLikings = copy(saved.foodLikings)

  parameters.initialStorage.anchorPosition = entity.position()

  if self.petData.seed then
    parameters.seed = self.petData.seed
  end

  parameters.petports_materialise = true

  petports_trace("spawning with initialStorage", parameters.initialStorage)

  self.petId = world.spawnMonster(self.petData.monsterType, spawnPosition, parameters)
  if self.petId then
    self.spawning = true
    self.statusTimer = STATUS_INTERVAL

    self.spawnedPetId = self.petId

    world.callScriptedEntity(self.petId, "setAnchor", entity.id())
  else
    petports_trace("spawnMonster returned nil for type", self.petData.monsterType)
  end
end

-- Takes the unit's state back into the pet data, despawns it, and writes it into the item.
function saveAndDespawn(skipWrite, instant)
  if self.petId and world.entityExists(self.petId) then
    local ok, state = pcall(world.callScriptedEntity, self.petId, "petports_store")
    petports_trace("petStore returned", ok and state or nil)

    petports_cargoTrace("saveAndDespawn: before store merge", self.petData and self.petData.cargo)

    if ok and state and self.petData then
      self.petData.status = state.status or self.petData.status
      self.petData.storage = state.storage or self.petData.storage
    end

    petports_cargoTrace("saveAndDespawn: after store merge", self.petData and self.petData.cargo)

    world.callScriptedEntity(self.petId, "petports_despawn", instant)

    self.fadingPetId = self.petId
  end
  if not skipWrite then
    writeBackToItem()
  end

  self.petId = nil
  self.spawning = false
end

-- Writes the pet data into the item now and lets work run on the next tick.
function petports_flushCargo()
  self.dirty = true
  writeBackToItem()
  self.writeTimer = WRITE_INTERVAL

  self.workTimer = 0
end


-- Returns a beacon item's behavior, or nil when it is switched off.
function petports_beaconBehaviorOf(item)
  if item == nil or item.name == nil then return nil end

  if item.parameters ~= nil and item.parameters[BEACON_ENABLED_KEY] == false then
    return nil
  end

  if item.parameters ~= nil and item.parameters[BEACON_KEY] ~= nil then
    return item.parameters[BEACON_KEY]
  end

  return root.itemConfig(item).config[BEACON_KEY]
end

-- Returns whether an object carries an item tag.
function petports_objectHasTag(id, tag)
  local ok, tags = pcall(world.getObjectParameter, id, "itemTags")
  if not ok or type(tags) ~= "table" then return false end

  for _, candidate in ipairs(tags) do
    if candidate == tag then return true end
  end

  return false
end

-- Returns an object's machine kind, enabled and feeder flags and rules, or nil when it is not a machine.
function petports_machineAt(id)
  local ok, kind = pcall(world.getObjectParameter, id, MACHINE_KEY)
  if not ok or type(kind) ~= "string" or kind == "" then return nil end

  local machine = {
    id = id,
    kind = kind,
    position = world.entityPosition(id),
    name = world.entityName(id),
    enabled = false,
    rules = {}
  }

  local okEnabled, enabled = pcall(world.getObjectParameter, id, MACHINE_ENABLED_KEY)

  machine.enabled = okEnabled and enabled == true

  local okFeeder, feeder = pcall(world.getObjectParameter, id, MACHINE_FEEDER_KEY)

  machine.feeder = (not okFeeder) or feeder ~= false

  local okRules, rules = pcall(world.getObjectParameter, id, MACHINE_RULES_KEY)

  if okRules and type(rules) == "table" then
    for _, rule in ipairs(rules) do
      if type(rule) == "table" and type(rule.item) == "string" and rule.item ~= "" then
        table.insert(machine.rules, {
          item = rule.item,
          max = tonumber(rule.max) or 0,

          reagent = rule.reagent,

          burn = rule.burn
        })
      end
    end
  end

  return machine
end

-- Scans the network for containers, returning the beacons, the deposit census, the machines and where each item is spread.
function petports_scanContainers()
  local rects = self.networkRects
  if rects == nil or #rects == 0 then rects = { petports_portCoverageRect() } end

  local found = {}
  local seen = {}
  local containers = 0

  local census = {}
  local censusStacks = 0
  local machines = {}

  local spread = {}

  for _, rect in ipairs(rects) do
    local ids = world.entityQuery({ rect[1], rect[2] }, { rect[3], rect[4] }, {
      includedTypes = { "object" }
    })

    for _, id in ipairs(ids) do
      if not seen[id] then
        seen[id] = true

        local machine = petports_machineAt(id)
        if machine ~= nil then table.insert(machines, machine) end

        local okSize, size = pcall(world.containerSize, id)

        if okSize and size ~= nil and size > 0 then
          containers = containers + 1

          local okItems, items = pcall(world.containerItems, id)
          if okItems and items ~= nil then
            local slots = {}
            for slot in pairs(items) do
              table.insert(slots, slot)
            end
            table.sort(slots)

            local ignoresBeacons = petports_objectHasTag(id, IGNORE_BEACONS_TAG)

            if ignoresBeacons then
              local offender = nil

              for _, slot in ipairs(slots) do
                if petports_beaconBehaviorOf(items[slot]) ~= nil then
                  offender = items[slot].name
                  break
                end
              end

              self.beaconInMachine = self.beaconInMachine or {}

              if offender ~= nil and self.beaconInMachine[id] ~= offender then
                self.beaconInMachine[id] = offender
                sb.logError("PETPORT %s: a %s is sitting in %s, which is a "
                  .. "petports machine -- beacons inside machines are IGNORED. "
                  .. "Machine slots are not storage; take it back out.",
                  stationUniqueId(), tostring(offender),
                  tostring(world.entityName(id)))
              elseif offender == nil then
                self.beaconInMachine[id] = nil
              end
            end

            for _, slot in ipairs(ignoresBeacons and {} or slots) do
              local item = items[slot]
              local behavior = petports_beaconBehaviorOf(item)

              if behavior ~= nil then
                local filter = nil
                if item.parameters ~= nil then
                  filter = item.parameters[BEACON_FILTER_KEY]
                end

                local requests = nil

                if behavior == "restock" and item.parameters ~= nil then
                  local stored = item.parameters[BEACON_REQUESTS_KEY]

                  if type(stored) == "table" then
                    requests = {}

                    for _, request in ipairs(stored) do
                      if type(request) == "table"
                         and type(request.item) == "string"
                         and request.item ~= "" then
                        table.insert(requests, {
                          item = request.item,
                          min = tonumber(request.min) or 1,
                          max = tonumber(request.max) or 1
                        })
                      end
                    end
                  else
                    local wanted = item.parameters[BEACON_ITEM_KEY]

                    if type(wanted) == "string" and wanted ~= "" then
                      requests = { {
                        item = wanted,
                        min = tonumber(item.parameters[BEACON_MIN_KEY]) or 1,
                        max = tonumber(item.parameters[BEACON_MAX_KEY]) or 1
                      } }
                    end
                  end

                  if requests ~= nil and #requests == 0 then requests = nil end
                end

                table.insert(found, {
                  id = id,
                  position = world.entityPosition(id),
                  behavior = behavior,
                  name = world.entityName(id),
                  filter = filter,
                  requests = requests,

                  capacity = size,

                  breadth = petports_filterBreadth(filter),

                  aging = (function()
                    local okAge, value = pcall(world.getObjectParameter, id,
                      "itemAgeMultiplier", 1.0)

                    if okAge and type(value) == "number" then return value end
                    return 1.0
                  end)(),

                  feeder = not (item.parameters ~= nil
                    and item.parameters[BEACON_FEEDER_KEY] == false),

                  beaconSlot = slot
                })

                if behavior == "deposit" then
                  for _, tallySlot in ipairs(slots) do
                    if tallySlot ~= slot then
                      local tallied = items[tallySlot]

                      if type(tallied) == "table"
                         and type(tallied.name) == "string" then
                        census[tallied.name] = (census[tallied.name] or 0)
                          + (tallied.count or 0)
                        censusStacks = censusStacks + 1

                        local where = spread[tallied.name]

                        if where == nil then
                          where = {}
                          spread[tallied.name] = where
                        end

                        local held = where[id]

                        if held == nil then
                          held = { count = 0, slots = 0 }
                          where[id] = held
                        end

                        held.count = held.count + (tallied.count or 0)
                        held.slots = held.slots + 1
                      end
                    end
                  end
                end

                break
              end
            end
          end
        end
      end
    end
  end

  return found, containers, census, censusStacks, machines, spread
end

-- Logs the item census against each machine rule when the picture changes.
function petports_reportCensus(census, censusStacks, machines)
  local distinct = 0
  for _ in pairs(census) do distinct = distinct + 1 end

  local totals = string.format("%s name(s) across %s stack(s), %s machine(s)",
    tostring(distinct), tostring(censusStacks), tostring(#machines))

  local lines = {}

  for _, machine in ipairs(machines) do
    if #machine.rules == 0 then
      table.insert(lines, string.format("%s@%s,%s [%s] no rules",
        tostring(machine.kind),
        tostring(math.floor(machine.position[1])),
        tostring(math.floor(machine.position[2])),
        machine.enabled and "on" or "OFF"))
    end

    for _, rule in ipairs(machine.rules) do
      local held = census[rule.item] or 0
      local surplus = held - rule.max

      table.insert(lines, string.format("%s@%s,%s [%s] %s held %s max %s -> %s",
        tostring(machine.kind),
        tostring(math.floor(machine.position[1])),
        tostring(math.floor(machine.position[2])),
        machine.enabled and "on" or "OFF",
        tostring(rule.item), tostring(held), tostring(rule.max),
        surplus > 0 and ("OVER by " .. tostring(surplus)) or "under"))
    end
  end

  table.sort(lines)

  local report = totals .. " || " .. (#lines == 0 and "no machine rules"
    or table.concat(lines, " || "))

  if report == self.censusReport then return end
  self.censusReport = report

  sb.logInfo("PETPORT %s census: %s", stationUniqueId(), report)
end

DEFRAG_DEBUG = true

SPREAD_REPORT_CAP = 12

-- Logs which items sit in more than one crate when the picture changes.
function petports_reportSpread(spread)
  if not DEFRAG_DEBUG then return end

  local names = {}

  for name, where in pairs(spread) do
    local ids = {}
    for id in pairs(where) do table.insert(ids, id) end

    if #ids > 1 then
      table.sort(ids)
      table.insert(names, { name = name, ids = ids })
    end
  end

  table.sort(names, function(a, b)
    if #a.ids ~= #b.ids then return #a.ids > #b.ids end
    return a.name < b.name
  end)

  local signature = {}
  local lines = {}
  local crates = 0

  for index, entry in ipairs(names) do
    crates = crates + #entry.ids

    table.insert(signature, entry.name .. "@"
      .. table.concat(entry.ids, ","))

    if index <= SPREAD_REPORT_CAP then
      local parts = {}

      for _, id in ipairs(entry.ids) do
        local held = spread[entry.name][id]

        table.insert(parts, string.format("%s=%s/%ss", tostring(id),
          tostring(held.count), tostring(held.slots)))
      end

      table.insert(lines, string.format("%s across %s: %s", tostring(entry.name),
        tostring(#entry.ids), table.concat(parts, ",")))
    end
  end

  if #names == 0 then
    if self.spreadReport == "" then return end
    self.spreadReport = ""

    sb.logInfo("PETPORT %s spread: nothing held in more than one crate",
      stationUniqueId())
    return
  end

  local joined = table.concat(signature, " ")
  if joined == self.spreadReport then return end
  self.spreadReport = joined

  local shown = #lines

  sb.logInfo("PETPORT %s spread: %s name(s) fragmented across %s crate slot(s)"
    .. "%s || %s",
    stationUniqueId(), tostring(#names), tostring(crates),
    shown < #names and (", worst " .. tostring(shown) .. " shown") or "",
    table.concat(lines, " || "))
end



-- Returns whether a crate can take one more of an item.
function petports_crateHasRoom(id, name)
  if world.containerItemsCanFit == nil then return false end

  local ok, fits = pcall(world.containerItemsCanFit, id, { name = name, count = 1 })
  if not ok or type(fits) ~= "number" then return false end

  return fits > 0
end

-- Returns the crate an item belongs in, ranked by filter narrowness, aging, how much it already holds and its size.
function petports_defragDestination(name, where, crates, perishable)
  local ranked = {}

  if perishable == nil then perishable = petports_itemPerishable(name) end

  local chill = petportParticipates("chill")

  for _, crate in ipairs(crates) do
    if world.entityExists(crate.id)
       and petports_filterAccepts(crate.filter, name) then
      local held = where[crate.id]

      table.insert(ranked,
      {
        crate = crate,
        held = held ~= nil and held.count or 0,

        breadth = crate.breadth or petports_filterBreadth(crate.filter)
      })
    end
  end

  if #ranked == 0 then return nil, "no crate accepts it" end

  table.sort(ranked, function(a, b)
    if a.breadth ~= b.breadth then return a.breadth < b.breadth end

    if chill then
      local aa = a.crate.aging or 1.0
      local ba = b.crate.aging or 1.0

      if aa ~= ba then
        if perishable then return aa < ba end
        return aa > ba
      end
    end

    if a.held ~= b.held then return a.held > b.held end

    local ca = a.crate.capacity or 0
    local cb = b.crate.capacity or 0
    if ca ~= cb then return ca < cb end

    return a.crate.id < b.crate.id
  end)

  local anchor = ranked[1]

  if petports_crateHasRoom(anchor.crate.id, name) then
    return anchor.crate, "declared narrowest", anchor.held, anchor.breadth
  end

  local rest = {}
  for index = 2, #ranked do table.insert(rest, ranked[index]) end

  table.sort(rest, function(a, b)
    if a.breadth ~= b.breadth then return a.breadth < b.breadth end

    if chill then
      local aa = a.crate.aging or 1.0
      local ba = b.crate.aging or 1.0

      if aa ~= ba then
        if perishable then return aa < ba end
        return aa > ba
      end
    end

    local da = world.magnitude(anchor.crate.position, a.crate.position)
    local db = world.magnitude(anchor.crate.position, b.crate.position)

    if da ~= db then return da < db end
    return a.crate.id < b.crate.id
  end)

  for _, entry in ipairs(rest) do
    if petports_crateHasRoom(entry.crate.id, name) then
      return entry.crate, "nearest the full one", entry.held, entry.breadth
    end
  end

  return nil, string.format("all %s crates that accept it are full",
    tostring(#ranked))
end

-- Returns the crates an item should be moved out of, smallest holding first, and how many refuse it outright.
function petports_defragSourcesFor(name, where, destinationId, byId)
  local sources = {}
  local misfiled = 0

  for id, held in pairs(where) do
    if id ~= destinationId and (held.count or 0) > 0 then
      local crate = byId[id]

      if crate ~= nil then
        if petports_filterAccepts(crate.filter, name) then
          table.insert(sources,
          {
            crate = crate,
            count = held.count or 0,
            slots = held.slots or 0
          })
        else
          misfiled = misfiled + 1
        end
      end
    end
  end

  table.sort(sources, function(a, b)
    if a.count ~= b.count then return a.count < b.count end
    return a.crate.id < b.crate.id
  end)

  return sources, misfiled
end

-- Orders defrag candidates by slots used, then crate count, then name.
function petports_defragOrder(names)
  table.sort(names, function(a, b)
    if a.slots ~= b.slots then return a.slots > b.slots end
    if a.crates ~= b.crates then return a.crates > b.crates end
    return a.name < b.name
  end)

  return names
end

-- Returns whether a crate ages an item better than its current one, cached per beacon scan.
function petports_defragBetterTempExists(name, current, deposits, perishable)
  local version = self.beaconVersion or 0

  if self.defragTempVersion ~= version then
    self.defragTempVersion = version
    self.defragTemp = {}
  end

  local key = tostring(name) .. (perishable and "|cold" or "|warm")
  local held = self.defragTemp[key]
  if held ~= nil then return held end

  local better = false

  for _, crate in ipairs(deposits) do
    local aging = crate.aging or 1.0
    local wanted = perishable and (aging < current) or (aging > current)

    if wanted and petports_filterAccepts(crate.filter, name) then
      better = true
      break
    end
  end

  self.defragTemp[key] = better
  return better
end

-- Returns whether a narrower crate accepts an item, cached per beacon scan.
function petports_defragBetterHomeExists(name, closest, deposits)
  local version = self.beaconVersion or 0

  if self.defragBetterVersion ~= version then
    self.defragBetterVersion = version
    self.defragBetter = {}
  end

  local held = self.defragBetter[name]
  if held ~= nil then return held end

  local better = false

  for _, crate in ipairs(deposits) do
    local breadth = crate.breadth or petports_filterBreadth(crate.filter)

    if breadth < closest and petports_filterAccepts(crate.filter, name) then
      better = true
      break
    end
  end

  self.defragBetter[name] = better
  return better
end

-- Returns every item that is scattered, in too broad a crate, or at the wrong temperature, in the order to move them.
function petports_defragCandidates(spread, crates)
  local chill = petportParticipates("chill")
  local byId = {}
  local deposits = {}

  local narrowest = nil

  for _, crate in ipairs(crates) do
    if crate.behavior == "deposit" then
      table.insert(deposits, crate)
      byId[crate.id] = crate

      local breadth = crate.breadth or petports_filterBreadth(crate.filter)
      if narrowest == nil or breadth < narrowest then narrowest = breadth end
    end
  end

  local names = {}

  for name, where in pairs(spread or {}) do
    local count, slots = 0, 0

    local closest = nil

    local coldest, warmest = nil, nil

    for id, held in pairs(where) do
      count = count + 1
      slots = slots + (held.slots or 0)

      local crate = byId[id]

      if crate ~= nil then
        local breadth = crate.breadth or petports_filterBreadth(crate.filter)
        if closest == nil or breadth < closest then closest = breadth end

        local aging = crate.aging or 1.0
        if coldest == nil or aging < coldest then coldest = aging end
        if warmest == nil or aging > warmest then warmest = aging end
      end
    end

    local scattered = count > 1

    local misplaced = narrowest ~= nil and closest ~= nil and closest > narrowest

    if misplaced then
      misplaced = petports_defragBetterHomeExists(name, closest, deposits)
    end

    local chilled = false

    if chill and coldest ~= nil then
      local perishable = petports_itemPerishable(name)
      local current = perishable and coldest or warmest

      if perishable and current > 0 then
        chilled = petports_defragBetterTempExists(name, current, deposits, true)
      elseif not perishable and current < 1.0 then
        chilled = petports_defragBetterTempExists(name, current, deposits, false)
      end
    end

    local reasons = {}

    if scattered then table.insert(reasons, "scattered") end
    if misplaced then table.insert(reasons, "misplaced") end
    if chilled then table.insert(reasons, "wrong temperature") end

    local why = table.concat(reasons, "+")

    if scattered or misplaced or chilled then
      table.insert(names,
      {
        name = name,
        crates = count,
        slots = slots,

        why = why
      })
    end
  end

  return petports_defragOrder(names), deposits, byId
end

DEFRAG_PLAN_CAP = 16

-- Logs the destination and sources planned for each defrag candidate when the plan changes.
function petports_reportDefragPlan(spread, crates)
  if not DEFRAG_DEBUG then return end
  if not petportDefrag() then return end
  if not petportParticipates("defrag") then return end

  local names, deposits, byId = petports_defragCandidates(spread, crates)

  local lines = {}
  local signature = {}

  for index, entry in ipairs(names) do
    if index > DEFRAG_PLAN_CAP then break end

    local where = spread[entry.name]
    local target, why, held, breadth = petports_defragDestination(entry.name, where, deposits)

    if target == nil then
      table.insert(signature, entry.name .. ">none:" .. tostring(why))

      table.insert(lines, string.format("%s: NO TARGET (%s)",
        tostring(entry.name), tostring(why)))
    else
      local sources, misfiled = petports_defragSourcesFor(entry.name, where, target.id, byId)

      local from = {}
      local ids = {}
      local trips = 0

      for _, source in ipairs(sources) do
        trips = trips + (source.slots or 0)
        table.insert(ids, tostring(source.crate.id))
        table.insert(from, string.format("%s=%s/%ss", tostring(source.crate.id),
          tostring(source.count), tostring(source.slots)))
      end

      table.insert(signature, string.format("%s>%s<%s=%s", entry.name,
        tostring(target.id), table.concat(ids, ","), tostring(trips)))

      table.insert(lines, string.format(
        "%s %s -> %s [%s, declares %s, cap %s, has %s] from %s, %s trip(s)%s",
        tostring(entry.name), tostring(entry.why),
        tostring(target.id), tostring(why),
        tostring(breadth), tostring(target.capacity), tostring(held),
        #from == 0 and "nowhere" or table.concat(from, ","), tostring(trips),
        misfiled > 0 and (" (" .. tostring(misfiled) .. " misfiled, tidy's)") or ""))
    end
  end

  if #lines == 0 then
    if self.defragPlan == "" then return end
    self.defragPlan = ""

    sb.logInfo("PETPORT %s defrag: everything is already where it belongs",
      stationUniqueId())
    return
  end

  local joined = table.concat(signature, " ")
  if joined == self.defragPlan then return end
  self.defragPlan = joined

  local report = table.concat(lines, " || ")

  sb.logInfo("PETPORT %s defrag plan (%s of %s name(s)): %s",
    stationUniqueId(), tostring(#lines), tostring(#names), report)
end

-- Rescans the containers on an interval and stores the beacons, census, machines and spread.
function petports_refreshBeacons(dt)
  self.beaconTimer = (self.beaconTimer or 0) - dt
  if self.beaconTimer > 0 then return end
  self.beaconTimer = BEACON_INTERVAL

  local found, containers, census, censusStacks, machines, spread =
    petports_scanContainers()

  self.beacons = found
  self.beaconVersion = (self.beaconVersion or 0) + 1
  self.census = census
  self.machines = machines

  self.spread = spread

  local parts = {}
  for _, beacon in ipairs(found) do
    local what = tostring(beacon.behavior)

    if beacon.requests ~= nil then
      local wants = {}

      for _, request in ipairs(beacon.requests) do
        table.insert(wants, string.format("%s/%s-%s", tostring(request.item),
          tostring(request.min), tostring(request.max)))
      end

      what = what .. ":" .. table.concat(wants, ",")
    end

    table.insert(parts, string.format("%s@%s,%s=%s", tostring(beacon.id),
      tostring(math.floor(beacon.position[1])),
      tostring(math.floor(beacon.position[2])),
      what))
  end
  table.sort(parts)
  local signature = table.concat(parts, " ")

  if signature ~= self.beaconSignature then
    self.beaconSignature = signature
    sb.logInfo("PETPORT %s beacons: %s of %s container(s) in coverage -- %s",
      stationUniqueId(), sb.printJson(#found), sb.printJson(containers),
      signature == "" and "none" or signature)
  end

  petports_reportCensus(census, censusStacks, machines)
  petports_reportSpread(spread)
  petports_reportDefragPlan(spread, found)
end

-- Returns the live beacons of a behavior, nearest first.
function petports_beaconsFor(behavior)
  local matches = {}
  local origin = entity.position()

  for _, beacon in ipairs(self.beacons or {}) do
    if beacon.behavior == behavior and world.entityExists(beacon.id) then
      table.insert(matches, beacon)
    end
  end

  table.sort(matches, function(a, b)
    return world.magnitude(origin, a.position) < world.magnitude(origin, b.position)
  end)

  return matches
end

-- Adds an item to the unit's cargo after the receive hooks have taken what they keep, and writes the item back.
function receiveCargo(item)
  if item == nil or item.name == nil then return end

  if self.petData == nil then
    sb.logError("PETPORT %s received cargo with no petData -- ITEM LOST: %s",
      stationUniqueId(), sb.printJson(item))
    return
  end

  petports_cargoTrace("receiveCargo: before", self.petData.cargo)

  self.petData.cargo = self.petData.cargo or {}

  for _, entry in ipairs(PETPORTS_WORK) do
    if entry.receive ~= nil then
      item = entry.receive(item)

      if item == nil then
        petports_flushCargo()
        return
      end
    end
  end

  for _, held in ipairs(self.petData.cargo) do
    if held.name == item.name and compare(held.parameters, item.parameters) then
      held.count = (held.count or 1) + (item.count or 1)

      sb.logInfo("PETPORT %s cargo +%s %s (stack now %s, %s stack(s) held)",
        stationUniqueId(), sb.printJson(item.count or 1), tostring(item.name),
        sb.printJson(held.count), sb.printJson(#self.petData.cargo))

      petports_flushCargo()
      return
    end
  end

  table.insert(self.petData.cargo, {
    name = item.name,
    count = item.count or 1,
    parameters = item.parameters
  })

  sb.logInfo("PETPORT %s cargo +%s %s (new stack, %s stack(s) held)",
    stationUniqueId(), sb.printJson(item.count or 1), tostring(item.name),
    sb.printJson(#self.petData.cargo))

  petports_flushCargo()
end

-- Serialises the pet data into the socketed item.
function writeBackToItem()
  if self.petData == nil then
    petports_cargoTrace("writeBack: REFUSED, no petData", nil)
    return
  end

  local item = petports_socketedItem()
  if item == nil then
    petports_cargoTrace("writeBack: REFUSED, nothing socketed", self.petData.cargo)
    return
  end

  self.petData.cargo = petports_normaliseCargo(self.petData.cargo)
  petports_cargoTrace("writeBack: serialising", self.petData.cargo)

  item.parameters = item.parameters or {}
  item.parameters.petData = self.petData

  petports_trace("writing back to item", self.petData)

  world.containerSwapItemsNoCombine(entity.id(), item, 0)
  self.dirty = false
end

-- Returns this port's unique id, assigning one when it has none.
function stationUniqueId()
  local uniqueId = entity.uniqueId()
  if not uniqueId then
    uniqueId = sb.makeUuid()
    world.setUniqueId(entity.id(), uniqueId)
  end
  return uniqueId
end


PANE_STATE_KEY = "petports_paneState"
PANE_MIRROR_INTERVAL = 0.5

PANE_FUEL_BLIPS = 20

PANE_FUEL_MAX = 900

PANE_DIAG_LIMIT = 4

petports_bodyKindCache = {}

-- Returns whether the unit's body is organic or robotic, cached.
function petports_paneBodyKind()
  local monsterType = self.petData and self.petData.monsterType
  if monsterType == nil then return nil end

  local key = tostring(monsterType)
  if petports_bodyKindCache[key] ~= nil then return petports_bodyKindCache[key] end

  local kind = "organic"
  local ok, params = pcall(root.monsterParameters, key)

  if ok and type(params) == "table" then
    local base = type(params.baseParameters) == "table" and params.baseParameters or {}
    local declared = params.bodyMaterialKind or base.bodyMaterialKind

    if declared == "robotic" then kind = "robotic" end

    sb.logInfo("PETPORT %s monster type %s: bodyMaterialKind %s -> %s fuel wording",
      stationUniqueId(), key, tostring(declared), kind)
  else
    sb.logInfo("PETPORT %s monster type %s: root.monsterParameters gave nothing, fuel wording defaults to organic",
      stationUniqueId(), key)
  end

  petports_bodyKindCache[key] = kind
  return kind
end

PETPORTS_FUEL_LOW = 0.25

PETPORTS_FUEL_PLAIN     = 60
PETPORTS_FUEL_PREFERRED = 120

-- Returns the unit's stored fuel.
function petports_fuelValue()
  local resources = self.petData and self.petData.storage and self.petData.storage.petResources
  if type(resources) ~= "table" then return nil end
  return tonumber(resources.petports_fuel)
end

-- Returns how much fuel the unit has room for.
function petportFuelHeadroom()
  local fuel = petports_fuelValue()
  if fuel == nil then return nil end
  return math.max(0, PANE_FUEL_MAX - fuel)
end

-- Returns whether the unit's fuel is below the low mark.
function petportFuelWanted()
  local fuel = petports_fuelValue()
  if fuel == nil then return false end
  return fuel < (PANE_FUEL_MAX * PETPORTS_FUEL_LOW)
end

FLAVOR_CACHE_TTL = 5.0

-- Returns the unit's preferred flavor, cached.
function petportUnitFlavor()
  if self.petId == nil or not world.entityExists(self.petId) then return nil end

  if self.flavorCached ~= nil and self.flavorAsked ~= nil
     and (world.time() - self.flavorAsked) < FLAVOR_CACHE_TTL then
    return self.flavorCached
  end

  local ok, flavor = pcall(world.callScriptedEntity, self.petId, "petports_unitFlavor")
  if not ok then return nil end

  self.flavorAsked  = world.time()
  self.flavorCached = flavor

  return flavor
end

-- Returns whether the unit has any fuel left.
function petportFuelled()
  local resources = self.petData and self.petData.storage and self.petData.storage.petResources
  if type(resources) ~= "table" then return true end

  local fuel = tonumber(resources.petports_fuel)
  if fuel == nil then return true end

  return fuel > 0
end

-- Returns the fuel as a blip count for the pane.
function petports_paneFuelBlips()
  local resources = self.petData and self.petData.storage and self.petData.storage.petResources
  if type(resources) ~= "table" then return PANE_FUEL_BLIPS end

  local fuel = tonumber(resources.petports_fuel)

  if fuel == nil then return PANE_FUEL_BLIPS end

  local blips = math.floor((fuel / PANE_FUEL_MAX) * PANE_FUEL_BLIPS + 0.5)
  return math.max(0, math.min(PANE_FUEL_BLIPS, blips))
end

-- Returns the cargo for the pane, each stack capped at its own max size.
function petports_paneCargo()
  if self.petData == nil or self.petData.cargo == nil then return nil end

  local out = {}
  for _, stack in ipairs(self.petData.cargo) do
    if stack.name then
      local cap = petports_stackSizeOf(stack.name) or 1000
      table.insert(out, {
        name = stack.name,
        count = math.min(tonumber(stack.count) or 1, cap),
        parameters = stack.parameters
      })
    end
  end

  if #out == 0 then return nil end
  return out
end

DIAG_MAX_CHARS = 26

-- Returns a diagnostic with its short text cut to the pane's width.
function petports_paneDiag(severity, short, full)
  local capped = short
  if #capped > DIAG_MAX_CHARS then
    capped = string.sub(capped, 1, DIAG_MAX_CHARS - 1) .. "..."
  end
  return { severity = severity, short = capped, full = full or short }
end

DIAG_FRESH = 30.0

-- Returns whether a time is inside the diagnostic freshness window.
function petports_fresh(at)
  if at == nil then return false end
  return (world.time() - at) < DIAG_FRESH
end

-- Returns the diagnostics the pane shows, newest and most severe first.
function petports_paneDiagnostics()
  local out = {}

  if petportOblivious() then
    table.insert(out, petports_paneDiag("info", "Oblivious",
      "An Oblivious Module is socketed, so this unit takes no dispatched work. "
      .. "It will still come home and put down anything it is already carrying. "
      .. "Remove the module to put it back on duty."))
  end

  if self.envUnsuitable ~= nil then
    table.insert(out, petports_paneDiag("error", "Wrong environment",
      self.envRetired
        and ("This unit's chassis cannot survive the liquid or air at its port. "
          .. "It has been retired and will return on its own once the port drains "
          .. "or floods back.")
        or ("This unit's chassis cannot survive the liquid or air at its port, so "
          .. "the port has not deployed it. It will deploy on its own once the "
          .. "port drains or floods back.")))
  end

  if (self.unreachableFailures or 0) > 0 and petports_fresh(self.unreachableAt) then
    table.insert(out, petports_paneDiag("warn",
      string.format("%d unreachable", self.unreachableFailures),
      string.format("%d job(s) were abandoned because no route could be found. "
        .. "Usually terrain: a gap too wide, a shaft too narrow, or a door the "
        .. "unit cannot open.", self.unreachableFailures)))
  end

  if (self.recallFailures or 0) > 0 and petports_fresh(self.recallAt) then
    table.insert(out, petports_paneDiag("warn",
      string.format("%d recalls failed", self.recallFailures),
      string.format("%d attempt(s) to walk home failed. The unit will be "
        .. "re-homed to its port if this keeps happening.", self.recallFailures)))
  end

  while #out > PANE_DIAG_LIMIT do table.remove(out) end
  if #out == 0 then return nil end
  return out
end

-- Returns the socketed item's short description.
function petports_paneSpecies()
  local item = petports_socketedItem()
  if item == nil or item.name == nil then return nil end

  local ok, resolved = pcall(root.itemConfig, { name = item.name, count = 1 })
  if not ok or type(resolved) ~= "table" or type(resolved.config) ~= "table" then
    return nil
  end
  return resolved.config.shortdescription
end

MODULE_SLOTS_BY_RARITY = {
  common = 1,
  uncommon = 2,
  rare = 3,
  legendary = 4,

  essential = 5
}

MODULE_SLOTS_MAX = 5

-- Returns the socketed item's module slot count, from its parameters, its config, or its rarity.
function petportModuleSlots()
  local item = petports_socketedItem()
  if item == nil then return 0 end

  -- Clamps a slot count to the maximum.
  local function clamp(n)
    return math.max(0, math.min(MODULE_SLOTS_MAX, math.floor(n)))
  end

  if item.parameters and item.parameters.petports_moduleSlots ~= nil then
    return clamp(tonumber(item.parameters.petports_moduleSlots) or 0)
  end

  local ok, resolved = pcall(root.itemConfig, { name = item.name, count = 1 })
  if not ok or type(resolved) ~= "table" or type(resolved.config) ~= "table" then
    return 0
  end

  local authored = tonumber(resolved.config.petports_moduleSlots)
  if authored ~= nil then return clamp(authored) end

  local rarity = resolved.config.rarity
  if type(rarity) == "string" then
    local byRarity = MODULE_SLOTS_BY_RARITY[string.lower(rarity)]
    if byRarity ~= nil then return byRarity end
  end

  return 0
end

MODULE_TAG = "petports_module"

-- Returns whether an item is tagged as a module.
function petportIsModuleItem(item)
  if type(item) ~= "table" or item.name == nil then return false end
  local ok, has = pcall(root.itemHasTag, item.name, MODULE_TAG)
  return ok and has == true
end

-- Returns a module item's list field from its parameters or its config.
function petports_moduleFieldOf(item, field)
  if type(item) ~= "table" or item.name == nil then return {} end

  if item.parameters and type(item.parameters[field]) == "table" then
    return item.parameters[field]
  end

  local ok, resolved = pcall(root.itemConfig, { name = item.name, count = 1 })
  if not ok or type(resolved) ~= "table" or type(resolved.config) ~= "table" then
    return {}
  end

  local value = resolved.config[field]
  if type(value) ~= "table" then return {} end
  return value
end

-- Returns the sorted union of a list field across every socketed module.
function petports_moduleFieldUnion(field)
  if self.petData == nil or type(self.petData.modules) ~= "table" then return {} end

  local seen = {}
  local out = {}

  for _, record in ipairs(self.petData.modules) do
    if type(record) == "table" and record.item ~= nil then
      for _, entry in ipairs(petports_moduleFieldOf(record.item, field)) do
        if type(entry) == "string" and not seen[entry] then
          seen[entry] = true
          table.insert(out, entry)
        end
      end
    end
  end

  table.sort(out)
  return out
end

-- Returns the status effects the socketed modules grant.
function petportModuleEffects()
  return petports_moduleFieldUnion("petports_moduleEffects")
end

-- Returns the liquids the socketed modules permit.
function petportModuleLiquids()
  return petports_moduleFieldUnion("petports_moduleLiquids")
end

-- Returns the flags the socketed modules carry.
function petportModuleFlags()
  return petports_moduleFieldUnion("petports_moduleFlags")
end

OBLIVIOUS_FLAG = "oblivious"

DEFRAG_FLAG = "defrag"

CAMOUFLAGE_FLAG = "camouflage"

HYDRATOR_FLAG = "hydrator"

FUEL_EFFICIENCY_BONUS = {
  fuelefficiency1 = 120,
  fuelefficiency2 = 300,
  fuelefficiency3 = 600
}

METABOLISM_PENALTY = {
  metabolism1 = 120,
  metabolism2 = 300,
  metabolism3 = 600
}

METABOLISM_SPEED = {
  metabolism1 = 0.10,
  metabolism2 = 0.20,
  metabolism3 = 0.30
}

-- Returns the fuel drain multiplier from the best fuel efficiency and metabolism modules.
function petportFuelScale()
  local bonus = 0
  local penalty = 0

  for _, flag in ipairs(petportModuleFlags()) do
    local tier = FUEL_EFFICIENCY_BONUS[flag]
    if tier ~= nil and tier > bonus then bonus = tier end

    local cost = METABOLISM_PENALTY[flag]
    if cost ~= nil and cost > penalty then penalty = cost end
  end

  local scale = 1.0

  if bonus > 0 then
    scale = scale * (PANE_FUEL_MAX / (PANE_FUEL_MAX + bonus))
  end

  if penalty > 0 then
    scale = scale * ((PANE_FUEL_MAX + penalty) / PANE_FUEL_MAX)
  end

  return scale
end

-- Returns the speed multiplier from the best metabolism module.
function petportSpeedScale()
  local bonus = 0

  for _, flag in ipairs(petportModuleFlags()) do
    local tier = METABOLISM_SPEED[flag]
    if tier ~= nil and tier > bonus then bonus = tier end
  end

  return 1.0 + bonus
end

FARMING_FLAG = "farming"
FARMING_CLASSES = { "harvest", "water", "replant", "animals", "traps" }

LIGHT_CHANNELS = { "r", "g", "b", "intensity", "speed" }
RGB_MIN = 0
RGB_MAX = 255
RGB_DEFAULT = 140
LIGHT_RANGE = {
  r = { min = RGB_MIN, max = RGB_MAX, default = RGB_DEFAULT },
  g = { min = RGB_MIN, max = RGB_MAX, default = RGB_DEFAULT },
  b = { min = RGB_MIN, max = RGB_MAX, default = RGB_DEFAULT },
  intensity = { min = RGB_MIN, max = RGB_MAX, default = 80 },
  speed = { min = 1, max = 16, default = 8 }
}
-- Returns whether an oblivious module is socketed.
function petportOblivious()
  for _, flag in ipairs(petportModuleFlags()) do
    if flag == OBLIVIOUS_FLAG then return true end
  end
  return false
end

-- Returns whether the unit shows carried-item bubbles.
function petportBubbles()
  if self.petData == nil then return false end

  local toggles = self.petData.toggles
  if type(toggles) ~= "table" then return true end
  return toggles.carried ~= false
end

-- Returns whether the unit shows its cargo in bubbles.
function petportBubbleCargo()
  if self.petData == nil then return false end

  local toggles = self.petData.toggles
  if type(toggles) ~= "table" then return true end
  return toggles.showCargo ~= false
end

-- Returns whether the unit shows bubbles at all.
function petportBubbleChannel()
  return petportBubbles() or petportBubbleCargo()
end

-- Returns whether the unit shows its nametag.
function petportNametag()
  if self.petData == nil then return false end

  local toggles = self.petData.toggles
  if type(toggles) ~= "table" then return false end
  return toggles.nametag == true
end

-- Returns whether a farming module is socketed.
function petportFarming()
  for _, flag in ipairs(petportModuleFlags()) do
    if flag == FARMING_FLAG then return true end
  end
  return false
end

-- Returns whether a defrag module is socketed.
function petportDefrag()
  for _, flag in ipairs(petportModuleFlags()) do
    if flag == DEFRAG_FLAG then return true end
  end
  return false
end

-- Returns whether a hydrator module is socketed.
function petportHydrator()
  for _, flag in ipairs(petportModuleFlags()) do
    if flag == HYDRATOR_FLAG then return true end
  end
  return false
end

-- Returns whether a class of farming work is turned on.
function petportFarmingDoes(class)
  if self.petData == nil then return false end

  local settings = self.petData.farming
  if type(settings) ~= "table" then return true end
  return settings[class] ~= false
end

MODULE_EFFECT_CATEGORY = "petports_modules"

-- Sends the module effects, liquids, flags, team and scales to the unit when they change.
function pushModuleEffects()
  if self.petId == nil or not world.entityExists(self.petId) then
    self.pushedModuleEffects = nil
    return
  end

  local effects = petportModuleEffects()
  local liquids = petportModuleLiquids()

  local flags = petportModuleFlags()

  local baseTeam = petports_chassisTeam(self.petData and self.petData.monsterType)

  local ok, encoded = pcall(sb.printJson, effects)
  if not ok then encoded = tostring(#effects) end

  local okLiquids, encodedLiquids = pcall(sb.printJson, liquids)
  if not okLiquids then encodedLiquids = tostring(#liquids) end

  local okFlags, encodedFlags = pcall(sb.printJson, flags)
  if not okFlags then encodedFlags = tostring(#flags) end


  local signature = tostring(self.petId) .. "|" .. encoded .. "|" .. encodedLiquids
    .. "|" .. encodedFlags

  if signature == self.pushedModuleEffects then return end
  self.pushedModuleEffects = signature

  sb.logInfo("PETPORT %s pushing to unit %s -- %s effect(s) %s, %s liquid(s) %s, %s flag(s) %s",
    stationUniqueId(), sb.printJson(self.petId),
    sb.printJson(#effects), encoded,
    sb.printJson(#liquids), encodedLiquids,
    sb.printJson(#flags), encodedFlags)

  world.callScriptedEntity(self.petId, "petports_setModuleEffects", effects,
    MODULE_EFFECT_CATEGORY, liquids, flags, baseTeam, petportFuelScale(),
    petportSpeedScale())
end


-- Returns the unit's stored light colour, intensity and sweep speed, defaulting each channel.
function petportLightColor()
  local stored = (self.petData and self.petData.light) or {}
  local out = {}

  for _, channel in ipairs(LIGHT_CHANNELS) do
    local value = tonumber(stored[channel])
    out[channel] = value ~= nil and value or LIGHT_RANGE[channel].default
  end

  return out
end

-- Sends the light colour to the unit when it changes.
function pushUnitLight()
  if self.petId == nil or not world.entityExists(self.petId) then
    self.pushedUnitLight = nil
    return
  end

  local color = petportLightColor()

  local reverse = ((self.petData and self.petData.toggles) or {}).huereverse == true

  local signature = string.format("%s|%s|%s|%s|%s|%s|%s",
    tostring(self.petId), tostring(color.r), tostring(color.g), tostring(color.b),
    tostring(color.intensity), tostring(color.speed), tostring(reverse))

  if signature == self.pushedUnitLight then return end
  self.pushedUnitLight = signature

  sb.logInfo("PETPORT %s pushing light to unit %s: %s", stationUniqueId(),
    sb.printJson(self.petId), sb.printJson(color))

  world.callScriptedEntity(self.petId, "petports_setLightColor",
    color.r, color.g, color.b, color.intensity, color.speed, reverse)
end

-- Sends the bubble on or off state to the unit when it changes.
function pushUnitBubbles()
  if self.petId == nil or not world.entityExists(self.petId) then
    self.pushedUnitBubbles = nil
    return
  end

  local show = petportBubbleChannel()

  local signature = string.format("%s|%s", tostring(self.petId), tostring(show))

  if signature == self.pushedUnitBubbles then return end
  self.pushedUnitBubbles = signature

  sb.logInfo("PETPORT %s pushing speech bubbles to unit %s: %s",
    stationUniqueId(), sb.printJson(self.petId), tostring(show))

  world.callScriptedEntity(self.petId, "petports_setUnitBubbles", show)
end

-- Returns up to three cargo items as bubble tokens, or nil.
function petports_bubbleSpec()

  if petportBubbleCargo() and self.petData ~= nil
     and type(self.petData.cargo) == "table" then
    local tokens = {}

    for _, stack in ipairs(self.petData.cargo) do
      if type(stack.name) == "string" and #tokens < 3 then
        table.insert(tokens, {
          item = {
            name = stack.name,
            count = 1,
            parameters = copy(stack.parameters)
          }
        })
      end
    end

    if #tokens > 0 then return tokens end
  end

  return nil
end

-- Sends the bubble tokens to the unit when they change.
function pushUnitBubble()
  if self.petId == nil or not world.entityExists(self.petId) then
    self.pushedUnitBubble = nil
    return
  end

  local tokens = petports_bubbleSpec()

  local ok, signature = pcall(sb.printJson, tokens or {})
  if not ok then signature = tostring(tokens ~= nil) end
  signature = tostring(self.petId) .. "|" .. signature

  if signature == self.pushedUnitBubble then return end
  self.pushedUnitBubble = signature

  local encoded = signature and #signature or 0

  sb.logInfo("PETPORT %s telling unit %s to say: %s token(s), %s bytes",
    stationUniqueId(), sb.printJson(self.petId),
    tokens == nil and "0" or tostring(#tokens), tostring(encoded))

  world.callScriptedEntity(self.petId, "petports_setUnitBubbleSpec", tokens)
end

-- Sends the unit's name and nametag setting when they change.
function pushPetName()
  if self.petId == nil or not world.entityExists(self.petId) then
    self.pushedPetName = nil
    return
  end

  local name = self.petData ~= nil and self.petData.petName or nil
  if name == nil or name == "" then
    name = petports_paneSpecies() or "Utility Unit"
  end

  local show = petportNametag()

  local signature = string.format("%s|%s|%s",
    tostring(self.petId), tostring(name), tostring(show))

  if signature == self.pushedPetName then return end
  self.pushedPetName = signature

  sb.logInfo("PETPORT %s pushing name to unit %s: %s (tag %s)", stationUniqueId(),
    sb.printJson(self.petId), tostring(name), tostring(show))

  world.callScriptedEntity(self.petId, "petports_setUnitName", name, show)
end

-- Returns the unit's seed as a six digit serial.
function petports_paneSerial()
  local seed = self.petData and self.petData.seed
  if seed == nil then return nil end
  return string.format("%06d", math.floor(tonumber(seed) or 0) % 1000000)
end

-- Returns the stat counters for the pane, with the per-tier and per-flavor rows gathered up.
petports_metrics.paneStats = function()
  local stats = (self.petData and self.petData.stats) or {}

  return {
    moved = math.floor(stats.moved or 0),
    planted = math.floor(stats.planted or 0),
    watered = math.floor(stats.watered or 0),
    dosed = math.floor(stats.dosed or 0),
    harvested = math.floor(stats.harvested or 0),
    livestock = math.floor(stats.livestock or 0),
    traps = math.floor(stats.traps or 0),

    asteriteDepositsMined = math.floor(stats.asteriteDepositsMined or 0),

    fished = math.floor(stats.fished or 0),
    fishedTiers = (function()
      local tiers = nil

      for key, value in pairs(stats) do
        local tier = type(key) == "string" and key:match("^fished_(.+)$") or nil

        if tier ~= nil and type(value) == "number" and value > 0 then
          tiers = tiers or {}
          tiers[tier] = math.floor(value)
        end
      end

      return tiers
    end)(),
    fed = math.floor(stats.fed or 0),
    fedFlavors = (function()
      local flavors = nil

      for key, value in pairs(stats) do
        local flavor = type(key) == "string" and key:match("^fed_(.+)$") or nil

        if flavor ~= nil and type(value) == "number" and value > 0 then
          flavors = flavors or {}
          flavors[flavor] = math.floor(value)
        end
      end

      return flavors
    end)(),

    headpats = math.floor(stats.headpats or 0),

    traveled = (self.task ~= nil)
        and math.floor((stats.traveled or 0) / 10) * 10
        or math.floor(stats.traveled or 0),
    activeMinutes = math.floor((stats.active or 0) / 60)
  }
end

-- Writes the pane state parameter on an interval from the unit's name, fuel, cargo, task and diagnostics.
function mirrorPaneState(dt)
  self.paneTimer = (self.paneTimer or 0) - (dt or 0)
  if self.paneTimer > 0 then return end
  self.paneTimer = PANE_MIRROR_INTERVAL

  local socketed = petports_portProf("pane.socketed", petports_socketedItem) ~= nil
  self.paneSocketed = socketed

  local enabled = petportEnabled()

  local state
  if self.petData == nil or not socketed then
    state = {
      hasUnit = false,
      enabled = enabled,
    }
  else
    state = {
      hasUnit = true,
      enabled = enabled,
      petName = self.petData.petName or petports_paneSpecies() or "Utility Unit",

      petNameRaw = self.petData.petName,
      species = petports_paneSpecies(),
      serial = petports_paneSerial(),
      fuelBlips = petports_paneFuelBlips(),

      bodyKind = petports_paneBodyKind(),
      cargo = petports_paneCargo(),
      task = self.task and self.task.type or "idle",
      diagnostics = petports_paneDiagnostics(),
      moduleSlots = petportModuleSlots(),


      moduleFlags = petportModuleFlags(),

      toggles = (self.petData and self.petData.toggles) or nil,
      medic = (self.petData and self.petData.medic) or nil,
      farming = (self.petData and self.petData.farming) or nil,

      medicReady = petports_medicKit ~= nil and petports_medicKit() ~= nil,

      light = petportLightColor(),
      modules = self.petData.modules,

      moduleToken = self.moduleToken,

      petId = (self.petId ~= nil and world.entityExists(self.petId)) and self.petId or nil,

      flavor = petportUnitFlavor(),
      stats = petports_metrics.paneStats(),

      network = nil
    }
  end

  local ok, signature = pcall(sb.printJson, state)
  if ok and signature == self.paneSignature then return end
  if ok then self.paneSignature = signature end

  local okJ, blob = petports_portProf("pane.json", pcall, sb.printJson, state)

  if okJ and blob == self.paneLastBlob then return end
  if okJ then self.paneLastBlob = blob end

  petports_portProf("pane.write", object.setConfigParameter, PANE_STATE_KEY, state)
end


-- Returns the socketed chassis's habitat capabilities.
function petports_unitCapabilities()
  if self.petData == nil or self.petData.monsterType == nil then return nil end

  return petports_habitatCapabilitiesForType(self.petData.monsterType,
    petports_habitatPermittedSet(petportModuleLiquids()))
end

-- Returns whether the port's own spaces are submerged, dry, and which liquids they hold.
function petports_portMedia()
  local spaces = world.objectSpaces(entity.id())
  if spaces == nil or #spaces == 0 then return false, true, {} end

  local origin = entity.position()
  local wet, dry = false, false
  local liquids = {}

  for _, space in ipairs(spaces) do
    local level = world.liquidAt({
      math.floor(origin[1]) + space[1] + 0.5,
      math.floor(origin[2]) + space[2] + 0.5
    })

    local fill = (level ~= nil) and (level[2] or 0) or 0

    if level ~= nil and level[1] ~= nil and fill > 0 then
      liquids[level[1]] = true
    end

    if fill >= ENVIRONMENT_SUBMERGED_FILL then
      wet = true
    else
      dry = true
    end
  end

  local ids = {}
  for id in pairs(liquids) do table.insert(ids, id) end

  return wet, dry, ids
end

-- Asks whether the chassis can inhabit the port's own footprint, and retires the unit when it cannot.
function petports_environmentCheck()
  if self.petData == nil or self.petData.monsterType == nil then
    self.envUnsuitable = nil
    return
  end

  local live = self.petId ~= nil and world.entityExists(self.petId)
  local wet, dry, liquids = petports_portMedia()
  local verdict = nil

  if live then
    local called, answer = pcall(world.callScriptedEntity, self.petId,
      "petports_canInhabit", wet, dry, liquids)

    if not called or type(answer) ~= "table" then return end
    verdict = answer
  else
    verdict = petports_habitatVerdict(petports_unitCapabilities(), wet, dry, liquids)

    if verdict == nil then
      if not self.envTypeUnreadable then
        self.envTypeUnreadable = true
        sb.logInfo("PETPORT %s cannot read capabilities for monster type %s -- the "
          .. "environment gate is open and a unit will spawn unchecked",
          stationUniqueId(), tostring(self.petData.monsterType))
      end

      self.envUnsuitable = nil
      return
    end

    self.envTypeUnreadable = nil
  end

  local reason = verdict.reason or petports_habitatReason(verdict.cause)

  if verdict.ok then
    if self.envUnsuitable ~= nil then
      sb.logInfo("PETPORT %s environment now suits the socketed chassis: %s "
        .. "(footprint wet %s, dry %s) -- the door may open again",
        stationUniqueId(), reason, tostring(wet), tostring(dry))
    end

    self.envUnsuitable = nil
    return
  end

  if self.envUnsuitable == nil then
    self.envRetired = live

    if live then
      sb.logInfo("PETPORT %s RETIRING unit: %s (footprint wet %s, dry %s). Its state and "
        .. "cargo are written back to the item, which stays socketed -- move it to a "
        .. "suitable port to unload it.",
        stationUniqueId(), reason, tostring(wet), tostring(dry))
    else
      sb.logInfo("PETPORT %s REFUSING to deploy: %s (footprint wet %s, dry %s). The "
        .. "door stays shut and the item is untouched; it will deploy on its own if "
        .. "the port floods or drains to suit it.",
        stationUniqueId(), reason, tostring(wet), tostring(dry))
    end
  end

  self.envUnsuitable = reason

  if live then saveAndDespawn() end
end


RECT_CHECKED_TYPES = {
  ["diag"] = true
}

-- Returns work whose type is allowed outside this port's own rect, otherwise nil.
function petports_dispatchable(work)
  if work == nil then return nil end

  if RECT_CHECKED_TYPES[work.type]
     and not petports_rectContains(petports_portCoverageRect(), work.position) then

    local note = string.format("%s type %s at %s outside own rect %s",
      tostring(work.id), tostring(work.type), sb.printJson(work.position),
      sb.printJson(petports_portCoverageRect()))

    if self.lastRectSkip ~= note then
      self.lastRectSkip = note
      sb.logInfo("PETPORT %s SKIPPING %s -- generated point outside rect, "
        .. "falling through to the next kind of work",
        stationUniqueId(), note)
    end

    return nil
  end

  return work
end


-- Returns the unit's unique id, assigning one when it has none.
function petports_petUniqueId()
  if self.petId == nil or not world.entityExists(self.petId) then return nil end

  local uniqueId = world.entityUniqueId(self.petId)
  if not uniqueId then
    uniqueId = sb.makeUuid()
    world.setUniqueId(self.petId, uniqueId)
  end

  self.petUniqueId = uniqueId
  return uniqueId
end

-- Asks the unit for a standable point near a position.
function petports_portStandingPointNear(position, radius, mediumVerified)
  if self.petId ~= nil and world.entityExists(self.petId) then
    local ok, resolved = pcall(world.callScriptedEntity, self.petId,
      "petports_standingPointNear", position, radius or 4, mediumVerified)

    if ok and resolved ~= nil then return resolved end

    sb.logInfo("PETPORT %s unit could not resolve a standing point near %s (called %s)",
      stationUniqueId(), sb.printJson(position), tostring(ok))
  end

  return nil
end

-- Asks the unit for a standable point at the port.
function petports_portHomePointNear()
  if self.petId == nil or not world.entityExists(self.petId) then return nil end

  local ok, resolved = pcall(world.callScriptedEntity, self.petId,
    "petports_homePointNear", entity.position())

  if ok and resolved ~= nil then return resolved end

  sb.logInfo("PETPORT %s unit could not resolve a home point at %s (called %s)",
    stationUniqueId(), sb.printJson(entity.position()), tostring(ok))
  return nil
end

-- Returns whether the chassis can work at a target, with the refusal reason.
function petports_targetSuits(position, entityId)
  local caps = petports_unitCapabilities()
  if caps == nil then return true end

  local points = petports_habitatObjectPoints(entityId)

  if points == nil then
    if position == nil then return true end
    points = { { position[1], position[2] } }
  end

  local verdict = petports_habitatAnyPointSuits(caps, points)

  if verdict == nil or verdict.ok then return true end

  return false, petports_habitatTargetReason(verdict.cause)
end

-- Records a target refusal against a label, once per distinct reason and chassis.
function petports_targetRefused(label, reason)
  local chassis = self.petData ~= nil and self.petData.monsterType or nil

  if self.eligibilitySkips == nil or self.eligibilitySkipsChassis ~= chassis then
    self.eligibilitySkips = {}
    self.eligibilitySkipsChassis = chassis
  end

  local key = tostring(label)
  local note = tostring(reason)

  if self.eligibilitySkips[key] ~= note then
    self.eligibilitySkips[key] = note
    sb.logInfo("PETPORT %s SKIPPING %s %s -- this chassis cannot work there",
      stationUniqueId(), key, note)
  end
end

-- Returns whether a target suits the chassis, recording the refusal when it does not.
function petports_targetEligible(label, position, entityId)
  local ok, reason = petports_targetSuits(position, entityId)
  if ok then return true end

  petports_targetRefused(label, reason)
  return false
end

-- Asks the unit for a standable point beside a target's object bounds, or near its position.
function petports_standingPointForTarget(position, entityId, radius, mediumVerified)
  local bounds = petports_habitatObjectBounds(entityId)

  if bounds == nil then
    return petports_portStandingPointNear(position, radius, mediumVerified)
  end

  if self.petId ~= nil and world.entityExists(self.petId) then
    local ok, resolved = pcall(world.callScriptedEntity, self.petId,
      "petports_objectPointNear", position, bounds, mediumVerified)

    if ok and resolved ~= nil then return resolved end

    sb.logInfo("PETPORT %s unit could not resolve an object point near %s "
      .. "bounds %s (called %s)", stationUniqueId(), sb.printJson(position),
      sb.printJson(bounds), tostring(ok))
  end

  return nil
end

-- Returns the point the unit works a target from, or nil with the reason.
function petports_servicePointNearUncached(label, entityId, position, radius)
  local suits, why = petports_targetSuits(position, entityId)

  if not suits then
    petports_targetRefused(label, why)
    return nil, why
  end

  local bounds = petports_habitatObjectBounds(entityId)
  local stand = petports_standingPointForTarget(position, entityId, radius or 4, true)

  if stand == nil then
    if bounds ~= nil then
      return nil, string.format(
        "no standable spot around the object footprint %s", sb.printJson(bounds))
    end

    return nil, string.format("no standable spot within %s tiles",
      tostring(radius or 4))
  end

  return stand
end

SERVICE_POINT_TTL = 30.0
SERVICE_POINT_RETRY = 5.0

-- Returns a target's service point, cached, with a shorter hold on failures.
function petports_servicePointNear(label, entityId, position, radius)
  self.servicePoints = self.servicePoints or {}

  local key = tostring(entityId) .. "|" .. tostring(radius or 4) .. "|"
    .. tostring(self.petData and self.petData.seed)
  local held = self.servicePoints[key]
  local now = world.time()

  if held ~= nil then
    local ttl = held.stand ~= nil and SERVICE_POINT_TTL or SERVICE_POINT_RETRY
    if (now - held.at) < ttl then return held.stand, held.why end
  end

  local stand, why = petports_servicePointNearUncached(label, entityId, position, radius)
  self.servicePoints[key] = { at = now, stand = stand, why = why }

  return stand, why
end

-- Returns a random floor tile inside a rect, or nil.
function petports_findStandingPoint(rect)
  for _ = 1, 12 do
    local x = math.floor(rect[1] + math.random() * (rect[3] - rect[1])) + 0.5

    for y = rect[4], rect[2], -1 do
      local here = {x, y}
      local below = {x, y - 1}

      if world.pointTileCollision(below) and not world.pointTileCollision(here) then
        return here
      end
    end
  end

  return nil
end

-- Saves and despawns the unit, and clears the recall and unreachable counts.
function petports_rehomeUnit(reason)
  sb.logInfo("PETPORT %s re-homing unit: %s", stationUniqueId(), reason)

  saveAndDespawn()
  self.recallFailures = 0
  self.unreachableFailures = 0
  self.spawnTimer = 0
end


-- Counts the ticks the unit spends outside its medium and re-homes it once the strikes run out.
function petports_mediumCheck()
  if self.petId == nil or not world.entityExists(self.petId) then
    self.mediumStrikes = 0
    return
  end

  local called, answer = pcall(world.callScriptedEntity, self.petId,
    "petports_outOfMedium")

  if not called or type(answer) ~= "table" then return end
  if not answer.checked or not answer.out then
    self.mediumStrikes = 0
    return
  end

  self.mediumStrikes = (self.mediumStrikes or 0) + 1

  local recoverable = (answer.medium == "air") or (answer.medium == "mixed")
  local limit = recoverable and MEDIUM_STRIKE_LIMIT_BEACHED or MEDIUM_STRIKE_LIMIT

  sb.logInfo("PETPORT %s unit is outside its own medium at %s (reads %s) -- "
    .. "poll %s of %s, it will plan nothing until this clears",
    stationUniqueId(), sb.printJson(answer.position), tostring(answer.medium),
    sb.printJson(self.mediumStrikes), sb.printJson(limit))

  if self.mediumStrikes >= limit then
    self.mediumStrikes = 0
    petports_rehomeUnit("outside its own medium at "
      .. sb.printJson(answer.position) .. " (reads " .. tostring(answer.medium)
      .. ") for " .. tostring(ENVIRONMENT_INTERVAL * limit) .. "s")
  end
end

-- Counts the intervals the unit sits motionless away from the port and re-homes it once the stalls run out.
function petports_healthCheck()
  if self.petId == nil or not world.entityExists(self.petId) then
    self.healthAnchor = nil
    self.healthStalls = 0
    return
  end

  local position = world.entityPosition(self.petId)
  if position == nil then return end

  local anchor = self.healthAnchor
  self.healthAnchor = position

  local home = world.magnitude(position, entity.position()) <= HEALTH_HOME_SLACK
  local moved = anchor == nil or world.magnitude(position, anchor) > HEALTH_MOVE

  if home or moved then
    self.healthStalls = 0
    return
  end

  self.healthStalls = (self.healthStalls or 0) + 1

  sb.logInfo("PETPORT %s unit has not moved in %s check(s) of %ss at %s, %s tile(s) from "
    .. "the port and not on station -- %s",
    stationUniqueId(), sb.printJson(self.healthStalls), sb.printJson(HEALTH_INTERVAL),
    sb.printJson(position),
    sb.printJson(math.floor(world.magnitude(position, entity.position()))),
    (self.healthStalls >= HEALTH_STALL_LIMIT) and "RE-HOMING"
      or ("re-homing at " .. tostring(HEALTH_STALL_LIMIT)))

  if self.healthStalls >= HEALTH_STALL_LIMIT then
    self.healthStalls = 0
    self.healthAnchor = nil
    petports_rehomeUnit("motionless away from the port for "
      .. tostring(HEALTH_INTERVAL * HEALTH_STALL_LIMIT) .. "s")
  end
end


-- Returns the point the unit returns to, from its tethering type or a standable spot near the port.
function petports_portHomePosition()
  local tether = PETPORTS_TETHER_FLOOR

  if self.petData ~= nil and self.petData.monsterType ~= nil then
    tether = petports_habitatTether(self.petData.monsterType)
  end

  if tether == PETPORTS_TETHER_PORT then
    return entity.position()
  end

  if tether == PETPORTS_TETHER_CEILING then
    if not self.ceilingTetherWarned then
      self.ceilingTetherWarned = true
      sb.logInfo("PETPORT %s chassis %s asks to tether at the CEILING, which is not "
        .. "implemented -- recalling to the port itself instead",
        stationUniqueId(), tostring(self.petData and self.petData.monsterType))
    end

    return entity.position()
  end

  local asked = petports_portHomePointNear()
  if asked ~= nil then return asked end

  return petports_findStandingPoint({
    entity.position()[1] - 4, entity.position()[2] - 4,
    entity.position()[1] + 4, entity.position()[2] + 4
  }) or petports_findStandingPoint(petports_portCoverageRect())
end

MACHINE_SLOT_INPUT = 0

MACHINE_SLOT_REAGENT = 1


MACHINE_MIN_BATCH = 0.25

-- Returns how much of a stack a machine slot has room for.
function petports_machineSlotRoom(machineId, slot, stack)
  local ok, held = pcall(world.containerItemAt, machineId, slot)
  if not ok then return 0 end

  local limit = petports_stackSizeOf(stack.name)

  if type(held) ~= "table" or held.name == nil then return limit end

  if held.name ~= stack.name then return 0 end

  if stack.parameters ~= nil and not compare(held.parameters, stack.parameters) then
    return 0
  end

  local room = limit - (held.count or 0)
  if room < 0 then return 0 end

  return room
end

-- Returns how much of a stack a machine's rule allows into its input and reagent slots.
function petports_machineRuleRoom(machine, rule, stack)
  local room = 0

  if rule.burn ~= false then
    room = room + petports_machineSlotRoom(machine.id, MACHINE_SLOT_INPUT, stack)
  end

  if rule.reagent ~= false and petports_reagentFor(stack.name) ~= nil then
    room = room + petports_machineSlotRoom(machine.id, MACHINE_SLOT_REAGENT, stack)
  end

  return room
end

-- Returns how much room a machine's input slot has left.
function petports_machineInputFree(machineId)
  local ok, held = pcall(world.containerItemAt, machineId, MACHINE_SLOT_INPUT)
  if not ok then return 0 end

  if type(held) ~= "table" or held.name == nil then
    return math.huge
  end

  local free = petports_stackSizeOf(held.name) - (held.count or 0)
  if free < 0 then return 0 end

  return free
end

SLOT_KEY_TO_OFFSET = -1

-- Counts a tidy when taking an item leaves a crate holding none of it.
petports_metrics.noteStorageTake = function(containerId, name)
  if containerId == nil or name == nil then return end
  if petports_machineAt(containerId) ~= nil then return end

  local ok, left = pcall(world.containerAvailable, containerId, name)
  if not ok or type(left) ~= "number" or left > 0 then return end

  petports_metrics.add("tidy", 1)

  sb.logInfo("PETPORT %s TIDY +1: cleared the last %s out of %s (score %s)",
    stationUniqueId(), tostring(name), sb.printJson(containerId),
    sb.printJson((self.petData and self.petData.stats and self.petData.stats.tidy) or 0))
end

-- Takes items from a container slot, putting them back when what came out is not what was expected.
function petports_takeFromSlot(containerId, slot, count, expected)
  if count == nil or count < 1 then return nil end

  local offset = slot + SLOT_KEY_TO_OFFSET
  local taken = world.containerTakeNumItemsAt(containerId, offset, count)

  if taken == nil or taken.name == nil or (taken.count or 0) < 1 then
    return nil
  end

  if expected ~= nil then
    local same = taken.name == expected.name
      and compare(taken.parameters, expected.parameters)

    if not same then
      sb.logError("PETPORT %s slot key %s (offset %s) held %s, not the %s the "
        .. "scan found there -- returning it and refusing",
        stationUniqueId(), sb.printJson(slot), sb.printJson(offset),
        sb.printJson(taken.name), sb.printJson(expected.name))

      world.containerAddItems(containerId, taken)
      return nil
    end
  end

  return taken
end

-- Takes a number of a seed out of a crate across its slots and adds it to the cargo.
function withdrawSeed(containerId, seedName, workId, count)
  if seedName == nil then return end
  count = count or 1

  -- Logs the withdrawal coming back empty and backs the task off.
  local function empty(reason)
    sb.logInfo("PETPORT %s withdraw of %s from %s took nothing: %s",
      stationUniqueId(), tostring(seedName), sb.printJson(containerId), reason)

    if workId ~= nil then petports_noteFailure(workId, reason) end
  end

  if not world.entityExists(containerId) then
    empty("container no longer exists")
    return
  end

  local ok, items = pcall(world.containerItems, containerId)

  if not ok or type(items) ~= "table" then
    empty("container contents unreadable")
    return
  end

  local slots = {}
  for slot, stack in pairs(items) do
    if type(stack) == "table" and stack.name == seedName then
      table.insert(slots, slot)
    end
  end
  table.sort(slots)

  if #slots == 0 then
    empty("crate holds none of it -- emptied between dispatch and arrival?")
    return
  end

  local remaining = count
  local got = 0

  for _, slot in ipairs(slots) do
    if remaining < 1 then break end

    local expected = items[slot]
    local want = math.min(remaining, expected.count or 1)
    local taken = petports_takeFromSlot(containerId, slot, want, expected)

    if taken ~= nil then
      receiveCargo(taken)
      got = got + (taken.count or 1)
      remaining = remaining - (taken.count or 1)
    end
  end

  if got < 1 then
    local tried = {}
    for _, slot in ipairs(slots) do
      table.insert(tried, string.format("%s->%s(x%s)", tostring(slot),
        tostring(slot + SLOT_KEY_TO_OFFSET),
        tostring((items[slot] or {}).count)))
    end

    empty("every slot holding it refused: key->offset " .. table.concat(tried, " "))
    return
  end

  if got < count then
    sb.logInfo("PETPORT %s withdrew %s of the %s %s asked for from %s",
      stationUniqueId(), sb.printJson(got), sb.printJson(count),
      tostring(seedName), sb.printJson(containerId))
  else
    sb.logInfo("PETPORT %s withdrew %s %s from %s",
      stationUniqueId(), sb.printJson(got), tostring(seedName),
      sb.printJson(containerId))
  end

  petports_metrics.noteStorageTake(containerId, seedName)
end

-- Takes a named stack out of one crate slot, refusing when that slot now holds something else.
function withdrawMisfit(containerId, name, count, workId, slot)
  if name == nil then return end
  count = count or 1

  -- Logs the withdrawal coming back empty and backs the task off.
  local function empty(reason)
    sb.logInfo("PETPORT %s tidy of %s from %s took nothing: %s",
      stationUniqueId(), tostring(name), sb.printJson(containerId), reason)

    if workId ~= nil then petports_noteFailure(workId, reason) end
  end

  if not world.entityExists(containerId) then
    empty("container no longer exists")
    return
  end

  if slot == nil then
    empty("no slot given; refusing to guess which stack to take")
    return
  end

  local ok, items = pcall(world.containerItems, containerId)

  if not ok or type(items) ~= "table" then
    empty("container contents unreadable")
    return
  end

  local expected = items[slot]

  if type(expected) ~= "table" or expected.name ~= name then
    empty(string.format("slot %s now holds %s, not %s -- crate rearranged "
      .. "between dispatch and arrival?", tostring(slot),
      sb.printJson(expected ~= nil and expected.name or nil), tostring(name)))
    return
  end

  local taken = petports_takeFromSlot(containerId, slot, math.min(count, expected.count or 1),
    expected)

  if taken == nil then
    empty("slot " .. tostring(slot) .. " gave nothing up")
    return
  end

  sb.logInfo("PETPORT %s tidied %s %s out of %s (slot %s)",
    stationUniqueId(), sb.printJson(taken.count or 1), tostring(name),
    sb.printJson(containerId), tostring(slot))

  petports_metrics.noteStorageTake(containerId, name)

  if petports_machineAt(containerId) == nil then
    compactContainer(containerId)
  end

  receiveCargo(taken)
end

-- Uses one seed out of the cargo and writes the item back.
function spendSeed(seedName)
  if self.petData == nil or self.petData.cargo == nil then return end

  for index, stack in ipairs(self.petData.cargo) do
    if stack.name == seedName then
      local count = (stack.count or 1) - 1

      if count <= 0 then
        table.remove(self.petData.cargo, index)
      else
        stack.count = count
      end

      sb.logInfo("PETPORT %s spent 1 %s planting; %s stack(s) still held",
        stationUniqueId(), tostring(seedName),
        sb.printJson(#self.petData.cargo))

      writeBackToItem()
      return
    end
  end

  sb.logError("PETPORT %s planted %s but was not carrying it",
    stationUniqueId(), tostring(seedName))
end

-- Adds a stack to a container in its own maximum-sized chunks, and returns what would not fit.
function petports_placeStack(containerId, stack)
  if type(stack) ~= "table" or stack.name == nil then return 0 end

  local limit = petports_stackSizeFor(stack.name, stack.parameters)
  if limit == nil or limit < 1 then limit = 1 end

  local remaining = stack.count or 1

  while remaining > 0 do
    local chunk = math.min(remaining, limit)

    local leftover = world.containerAddItems(containerId, {
      name = stack.name,
      count = chunk,
      parameters = stack.parameters
    })

    local unplaced = 0
    if type(leftover) == "table" then unplaced = leftover.count or 0 end

    local placed = chunk - unplaced
    remaining = remaining - placed

    if placed < 1 then return remaining end
  end

  return 0
end

-- Places the whole cargo into a container, keeps what will not fit, and compacts the container.
function depositCargo(containerId)
  if self.petData == nil or self.petData.cargo == nil then return end

  if not world.entityExists(containerId) then
    sb.logInfo("PETPORT %s deposit failed: container %s no longer exists",
      stationUniqueId(), sb.printJson(containerId))
    return
  end

  local before = #self.petData.cargo
  local remaining = {}

  local delivered = 0

  for _, stack in ipairs(self.petData.cargo) do
    local unplaced = petports_placeStack(containerId, stack)

    delivered = delivered + (stack.count or 1) - unplaced

    if unplaced > 0 then
      table.insert(remaining, {
        name = stack.name,
        count = unplaced,
        parameters = stack.parameters
      })

      sb.logInfo("PETPORT %s deposited %s of %s %s into %s",
        stationUniqueId(),
        sb.printJson((stack.count or 1) - unplaced),
        sb.printJson(stack.count or 1), tostring(stack.name),
        sb.printJson(containerId))
    else
      sb.logInfo("PETPORT %s deposited %s %s into %s",
        stationUniqueId(), sb.printJson(stack.count or 1), tostring(stack.name),
        sb.printJson(containerId))
    end
  end

  petports_cargoTrace("deposit: cargo replaced", remaining)
  self.petData.cargo = remaining

  if #remaining > 0 then
    if world.containerItemsCanFit == nil then
      self.fullContainers = self.fullContainers or {}
      self.fullContainers[containerId] = world.time() + CONTAINER_FULL_BACKOFF
    end

    sb.logInfo("PETPORT %s container %s could not take %s of %s stack(s) (%s)",
      stationUniqueId(), sb.printJson(containerId), sb.printJson(#remaining),
      sb.printJson(before),
      world.containerItemsCanFit == nil
        and ("backed off for " .. sb.printJson(CONTAINER_FULL_BACKOFF))
        or "will re-check per descriptor")
  end

  petports_metrics.add("moved", delivered)

  compactContainer(containerId)

  petports_flushCargo()
end

-- Places the cargo a machine's rules want into its input and reagent slots.
function depositCargoToMachine(machineId, workId)
  if self.petData == nil or self.petData.cargo == nil then return end

  if not world.entityExists(machineId) then
    sb.logInfo("PETPORT %s upcycle failed: machine %s no longer exists",
      stationUniqueId(), sb.printJson(machineId))
    return
  end

  local machine = petports_machineAt(machineId)

  if machine == nil or not machine.enabled then
    sb.logInfo("PETPORT %s upcycle ABORTED: machine %s is %s",
      stationUniqueId(), sb.printJson(machineId),
      machine == nil and "no longer a machine" or "switched off")
    return
  end

  local remaining = {}
  local moved = 0

  for _, stack in ipairs(self.petData.cargo) do
    local rule = nil

    for _, candidate in ipairs(machine.rules) do
      if candidate.item == stack.name then rule = candidate break end
    end

    local stored = (self.census or {})[stack.name] or 0
    local held = stored + (stack.count or 0)

    local surplus = rule ~= nil and (held - rule.max) or 0
    if surplus > (stack.count or 0) then surplus = stack.count or 0 end

    if rule == nil then
      table.insert(remaining, stack)
    elseif surplus < 1 then
      sb.logInfo("PETPORT %s upcycle SKIPPED %s: network holds %s (%s stored + %s carried), threshold %s -- no longer surplus",
        stationUniqueId(), tostring(stack.name), sb.printJson(held),
        sb.printJson(stored), sb.printJson(stack.count or 0),
        sb.printJson(rule.max))
      table.insert(remaining, stack)
    else
      local allowBurn = rule.burn ~= false
      local routeToReagent = rule.reagent ~= false
        and petports_reagentFor(stack.name) ~= nil

      local remainingCount = surplus

      if routeToReagent and remainingCount > 0 then
        local slotRoom = petports_machineSlotRoom(machineId, MACHINE_SLOT_REAGENT, stack)
        local offerCount = math.min(remainingCount, slotRoom)
        local landed = 0

        if offerCount > 0 then
          local leftover = world.containerPutItemsAt(machineId, {
            name = stack.name,
            count = offerCount,
            parameters = stack.parameters
          }, MACHINE_SLOT_REAGENT)

          local refused = (type(leftover) == "table" and leftover.count or 0)
          landed = offerCount - refused
          remainingCount = remainingCount - landed
        end

        sb.logInfo("PETPORT %s reagent route: %s of %s %s into the reagent slot (slot room %s)%s",
          stationUniqueId(), sb.printJson(landed), sb.printJson(surplus),
          tostring(stack.name), sb.printJson(slotRoom),
          (remainingCount > 0 and not allowBurn)
            and " -- burner denied by rule, remainder stays aboard" or "")
      end

      if allowBurn and remainingCount > 0 then
        local slotRoom = petports_machineSlotRoom(machineId, MACHINE_SLOT_INPUT, stack)
        local offerCount = math.min(remainingCount, slotRoom)

        if offerCount > 0 then
          local leftover = world.containerPutItemsAt(machineId, {
            name = stack.name,
            count = offerCount,
            parameters = stack.parameters
          }, MACHINE_SLOT_INPUT)

          local refused = (type(leftover) == "table" and leftover.count or 0)
          remainingCount = remainingCount - (offerCount - refused)
        end
      end

      local placed = surplus - remainingCount

      if placed > 0 then moved = moved + placed end

      sb.logInfo("PETPORT %s upcycled %s of %s %s into machine %s (network held %s = %s stored + %s carried, threshold %s)",
        stationUniqueId(), sb.printJson(placed), sb.printJson(stack.count or 1),
        tostring(stack.name), sb.printJson(machineId), sb.printJson(held),
        sb.printJson(stored), sb.printJson(stack.count or 0),
        sb.printJson(rule.max))

      local keep = (stack.count or 0) - placed

      if keep > 0 then
        table.insert(remaining, {
          name = stack.name,
          count = keep,
          parameters = stack.parameters
        })
      end
    end
  end

  petports_cargoTrace("deposit: cargo replaced", remaining)
  self.petData.cargo = remaining

  petports_metrics.add("moved", moved)

  if moved == 0 then
    local reason = "machine input was full on arrival"

    sb.logInfo("PETPORT %s upcycle delivered NOTHING to machine %s -- input full, "
      .. "rule gone, or no longer over threshold", stationUniqueId(),
      sb.printJson(machineId))

    petports_noteFailure(workId, reason)
  end

  petports_flushCargo()
end

-- Places only the named item from the cargo into a container, and compacts it.
function depositCargoOnly(containerId, name)
  if self.petData == nil or self.petData.cargo == nil then return end
  if name == nil then return end

  if not world.entityExists(containerId) then
    sb.logInfo("PETPORT %s restock delivery failed: container %s no longer exists",
      stationUniqueId(), sb.printJson(containerId))
    return
  end

  local remaining = {}
  local moved = false

  local delivered = 0

  for _, stack in ipairs(self.petData.cargo) do
    if stack.name ~= name then
      table.insert(remaining, stack)
    else
      moved = true

      local unplaced = petports_placeStack(containerId, stack)

      delivered = delivered + (stack.count or 1) - unplaced

      if unplaced > 0 then
        table.insert(remaining, {
          name = stack.name,
          count = unplaced,
          parameters = stack.parameters
        })

        sb.logInfo("PETPORT %s restocked %s of %s %s into %s",
          stationUniqueId(),
          sb.printJson((stack.count or 1) - unplaced),
          sb.printJson(stack.count or 1), tostring(stack.name),
          sb.printJson(containerId))
      else
        sb.logInfo("PETPORT %s restocked %s %s into %s",
          stationUniqueId(), sb.printJson(stack.count or 1), tostring(stack.name),
          sb.printJson(containerId))
      end
    end
  end

  if not moved then
    sb.logInfo("PETPORT %s restock delivery to %s moved nothing: not carrying %s",
      stationUniqueId(), sb.printJson(containerId), tostring(name))
  end

  petports_cargoTrace("deposit: cargo replaced", remaining)
  self.petData.cargo = remaining

  petports_metrics.add("moved", delivered)

  compactContainer(containerId)

  petports_flushCargo()
end


-- Returns the engine's default max stack, read once.
function petports_defaultMaxStack()
  if self.defaultStack == nil then
    local ok, config = pcall(root.assetJson, "/items/defaultParameters.config")

    self.defaultStack = (ok and type(config) == "table"
      and tonumber(config.defaultMaxStack)) or false
  end

  return self.defaultStack or nil
end

-- Returns an item's max stack size, cached, falling back to the default.
petports_stackSizeOf = function(name)
  self.stackSizes = self.stackSizes or {}

  if self.stackSizes[name] == nil then
    local size, source = nil, "guessed"

    local ok, resolved = pcall(root.itemConfig, { name = name, count = 1 })

    if ok and type(resolved) == "table" and type(resolved.config) == "table" then
      size = tonumber(resolved.config.maxStack)
      if size ~= nil then source = "config" end
    end

    if size == nil then
      size = petports_defaultMaxStack()
      if size ~= nil then source = "defaultParameters" end
    end

    if size == nil then size = 1000 end

    self.stackSizes[name] = size

    sb.logInfo("PETPORT %s maxStack for %s: %s (from %s)",
      stationUniqueId(), tostring(name), sb.printJson(size), source)
  end

  return self.stackSizes[name]
end

-- Returns a stack's max size, taking a maxStack parameter over the item's own.
function petports_stackSizeFor(name, parameters)
  if type(parameters) == "table" then
    local override = tonumber(parameters.maxStack)
    if override ~= nil and override >= 1 then return override end
  end

  return petports_stackSizeOf(name)
end

-- Returns whether two values are equal, comparing tables field by field.
function petports_sameValue(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end

  for key, value in pairs(a) do
    if not petports_sameValue(value, b[key]) then return false end
  end

  for key in pairs(b) do
    if a[key] == nil then return false end
  end

  return true
end

-- Returns a printable key for a stack's parameters.
function petports_parameterKey(parameters)
  if parameters == nil then return "" end

  local ok, text = pcall(sb.printJson, parameters)
  if ok then return text end

  return "?" .. tostring(parameters)
end

-- Returns every item held across more slots than its stack sizes need, with its parameter buckets.
function petports_fragmentation(items)
  if type(items) ~= "table" then return {} end

  local groups = {}

  for _, stack in pairs(items) do
    if type(stack) == "table" and type(stack.name) == "string" then
      local group = groups[stack.name]

      if group == nil then
        group = { total = 0, slots = 0, buckets = {}, byKey = {} }
        groups[stack.name] = group
      end

      local count = stack.count or 1
      group.total = group.total + count
      group.slots = group.slots + 1

      local parameters = stack.parameters
      local key = petports_parameterKey(parameters)
      local bucket = group.byKey[key]

      if bucket ~= nil and not petports_sameValue(bucket.parameters, parameters) then
        bucket = nil

        for _, candidate in ipairs(group.buckets) do
          if petports_sameValue(candidate.parameters, parameters) then
            bucket = candidate
            break
          end
        end
      end

      if bucket == nil then
        bucket = { parameters = parameters, count = 0 }
        table.insert(group.buckets, bucket)
        group.byKey[key] = bucket
      end

      bucket.count = bucket.count + count
    end
  end

  local names = {}
  for name in pairs(groups) do table.insert(names, name) end
  table.sort(names)

  local out = {}

  for _, name in ipairs(names) do
    local group = groups[name]

    if group.slots > 1 then
      local needed = 0

      for _, bucket in ipairs(group.buckets) do
        needed = needed
          + math.ceil(bucket.count / petports_stackSizeFor(name, bucket.parameters))
      end

      if group.slots > needed then
        group.name = name
        group.needed = needed
        table.insert(out, group)
      end
    end
  end

  return out
end

-- Merges each fragmented item in a container back into full stacks, taking anything that will not fit into the cargo.
function compactContainer(containerId)
  if not world.entityExists(containerId) then return false end

  local ok, items = pcall(world.containerItems, containerId)
  if not ok or type(items) ~= "table" then return false end

  local work = petports_fragmentation(items)
  if #work == 0 then return false end

  local settled = {}
  local did = false

  for _, group in ipairs(work) do
    local took = world.containerConsume(containerId,
      { name = group.name, count = group.total })

    if took ~= true then
      sb.logInfo("PETPORT %s compaction of %s in %s skipped: consume returned %s",
        stationUniqueId(), tostring(group.name), sb.printJson(containerId),
        tostring(took))
    else
      local returned = 0
      local rescued = 0

      for _, bucket in ipairs(group.buckets) do
        local unplaced = petports_placeStack(containerId, {
          name = group.name,
          count = bucket.count,
          parameters = bucket.parameters
        })

        returned = returned + (bucket.count - unplaced)

        if unplaced > 0 then
          sb.logError("PETPORT %s compaction of %s in %s could not return %s -- "
            .. "moved to cargo",
            stationUniqueId(), tostring(group.name), sb.printJson(containerId),
            sb.printJson(unplaced))

          receiveCargo({
            name = group.name,
            count = unplaced,
            parameters = bucket.parameters
          })

          rescued = rescued + unplaced
        end
      end

      if returned + rescued ~= group.total then
        sb.logError("PETPORT %s COMPACTION LOST ITEMS in %s: took %s %s, "
          .. "returned %s, moved %s to cargo -- %s UNACCOUNTED FOR",
          stationUniqueId(), sb.printJson(containerId),
          sb.printJson(group.total), tostring(group.name),
          sb.printJson(returned), sb.printJson(rescued),
          sb.printJson(group.total - returned - rescued))
      end

      if returned > 0 then
        did = true
        table.insert(settled, group)

        sb.logInfo("PETPORT %s compacted %s %s in %s: %s slot(s), predicted %s (%s descriptor(s))",
          stationUniqueId(), sb.printJson(group.total), tostring(group.name),
          sb.printJson(containerId), sb.printJson(group.slots),
          sb.printJson(group.needed), sb.printJson(#group.buckets))
      end
    end
  end

  if #settled > 0 then
    local okAfter, after = pcall(world.containerItems, containerId)

    if okAfter and type(after) == "table" then
      for _, group in ipairs(settled) do
        local slots = 0

        for _, stack in pairs(after) do
          if type(stack) == "table" and stack.name == group.name then
            slots = slots + 1
          end
        end

        if slots ~= group.needed then
          sb.logInfo("PETPORT %s %s in %s settled at %s slot(s), not the %s predicted "
            .. "-- petports_stackSizeOf says %s",
            stationUniqueId(), tostring(group.name), sb.printJson(containerId),
            sb.printJson(slots), sb.printJson(group.needed),
            sb.printJson(petports_stackSizeOf(group.name)))
        end
      end
    end
  end

  return did
end


SORT_TYPE_ORDER =
{
	generic          =  1,
	liquid           =  2,
	material         =  3,
	object           =  4,
	currency         =  5,
	miningtool       =  6,
	flashlight       =  7,
	wiretool         =  8,
	beamminingtool   =  9,
	harvestingtool   = 10,
	tillingtool      = 11,
	paintingbeamtool = 12,
	headarmor        = 13,
	chestarmor       = 14,
	legsarmor        = 15,
	backarmor        = 16,
	consumable       = 17,
	blueprint        = 18,
	codex            = 19,
	inspectiontool   = 20,
	instrument       = 21,
	thrownitem       = 22,
	unlockitem       = 23,
	activeitem       = 24,
	augmentitem      = 25
}

SORT_TYPE_UNKNOWN = 99

SORT_RARITY_ORDER =
{
	essential = 1,
	legendary = 2,
	rare      = 3,
	uncommon  = 4,
	common    = 5
}

SORT_REVISIT = 60.0

SORT_SCAN_INTERVAL = 5.0

SORT_MIN_DISORDER = 2

SORT_MOVE_CAP = 64

SORT_BEACONS_FIRST = true

-- Returns an item's sort rank by item type, cached.
function petports_sortTypeRank(name)
	self.sortTypes = self.sortTypes or {}

	if self.sortTypes[name] == nil then
		local rank = SORT_TYPE_UNKNOWN
		local ok, kind = pcall(root.itemType, name)

		if ok and type(kind) == "string" then
			rank = SORT_TYPE_ORDER[string.lower(kind)] or SORT_TYPE_UNKNOWN

			if rank == SORT_TYPE_UNKNOWN then
				sb.logInfo("PETPORT %s sort: item type %s (%s) is not in "
					.. "SORT_TYPE_ORDER -- sorting it last",
					stationUniqueId(), tostring(kind), tostring(name))
			end
		end

		self.sortTypes[name] = rank
	end

	return self.sortTypes[name]
end

-- Returns an item's sort rank by rarity, cached, taking a rarity parameter over the item's own.
function petports_sortRarityRank(name, parameters)
	if type(parameters) == "table" and type(parameters.rarity) == "string" then
		local stated = SORT_RARITY_ORDER[string.lower(parameters.rarity)]
		if stated ~= nil then return stated end
	end

	self.sortRarities = self.sortRarities or {}

	if self.sortRarities[name] == nil then
		local rank = SORT_RARITY_ORDER.common
		local ok, resolved = pcall(root.itemConfig, { name = name, count = 1 })

		if ok and type(resolved) == "table" and type(resolved.config) == "table"
			and type(resolved.config.rarity) == "string" then

			rank = SORT_RARITY_ORDER[string.lower(resolved.config.rarity)]
				or SORT_RARITY_ORDER.common
		end

		self.sortRarities[name] = rank
	end

	return self.sortRarities[name]
end

-- Orders stacks by type, rarity, name, count, parameters and then slot.
function petports_sortLess(a, b)
	if a.type ~= b.type then return a.type < b.type end
	if a.rarity ~= b.rarity then return a.rarity < b.rarity end
	if a.name ~= b.name then return a.name < b.name end
	if a.count ~= b.count then return a.count > b.count end
	if a.pkey ~= b.pkey then return a.pkey < b.pkey end
	return a.key < b.key
end

-- Returns the slot order a container should hold, beacons pinned first, and how many stacks are out of place.
function petports_sortPlan(items)
	if type(items) ~= "table" then return {}, 0 end

	local keys = {}
	for key in pairs(items) do table.insert(keys, key) end
	table.sort(keys)

	local pinned, loose = {}, {}

	for _, key in ipairs(keys) do
		local stack = items[key]

		if type(stack) == "table" and type(stack.name) == "string" then
			if SORT_BEACONS_FIRST and petports_beaconBehaviorOf(stack) ~= nil then
				table.insert(pinned, { key = key, stack = stack })
			else
				table.insert(loose, {
					key = key,
					stack = stack,
					name = stack.name,
					count = stack.count or 1,
					type = petports_sortTypeRank(stack.name),
					rarity = petports_sortRarityRank(stack.name, stack.parameters),
					pkey = petports_parameterKey(stack.parameters)
				})
			end
		end
	end

	table.sort(loose, petports_sortLess)

	local order = {}
	for _, record in ipairs(pinned) do table.insert(order, record) end
	for _, record in ipairs(loose) do table.insert(order, record) end

	local disorder = 0
	for index, record in ipairs(order) do
		if record.key ~= index then disorder = disorder + 1 end
	end

	return order, disorder
end

-- Takes a stack out of a slot for sorting, putting it back when it is not what was expected.
function petports_sortLift(containerId, record, key)
	local offset = key + SLOT_KEY_TO_OFFSET
	local ok, taken = pcall(world.containerTakeNumItemsAt, containerId, offset,
		record.stack.count or 1)

	if not ok or type(taken) ~= "table" or (taken.count or 0) < 1 then
		return nil
	end

	if taken.name ~= record.stack.name then
		sb.logError("PETPORT %s sort: slot key %s held %s, not the %s the plan "
			.. "expected -- returning it and abandoning this pass",
			stationUniqueId(), sb.printJson(key), tostring(taken.name),
			tostring(record.stack.name))

		world.containerAddItems(containerId, taken)
		return nil
	end

	if not compare(taken.parameters, record.stack.parameters)
		and not self.sortDrifted then

		self.sortDrifted = true

		sb.logInfo("PETPORT %s sort: %s at slot key %s came back with different "
			.. "parameters than the scan read -- moving it anyway, since what is "
			.. "put down is what the take handed over",
			stationUniqueId(), tostring(taken.name), sb.printJson(key))
	end

	return taken
end

-- Puts a stack into a slot, returning it to the container when the slot refuses any of it.
function petports_sortLay(containerId, stack, key)
	local offset = key + SLOT_KEY_TO_OFFSET
	local ok, leftover = pcall(world.containerPutItemsAt, containerId, stack, offset)

	if not ok then
		sb.logError("PETPORT %s sort: put of %s into slot key %s THREW",
			stationUniqueId(), tostring(stack.name), sb.printJson(key))
		return false
	end

	local refused = (type(leftover) == "table" and (leftover.count or 0)) or 0

	if refused > 0 then
		sb.logError("PETPORT %s sort: slot key %s REFUSED %s of %s -- putting "
			.. "the remainder back loose",
			stationUniqueId(), sb.printJson(key), sb.printJson(refused),
			tostring(stack.name))

		world.containerAddItems(containerId, leftover)
		return false
	end

	return true
end

-- Returns the count of each item name in a container.
function petports_sortTally(items)
	local tally = {}

	if type(items) == "table" then
		for _, stack in pairs(items) do
			if type(stack) == "table" and type(stack.name) == "string" then
				tally[stack.name] = (tally[stack.name] or 0) + (stack.count or 1)
			end
		end
	end

	return tally
end

-- Moves a container's stacks into sorted order, stopping at the move cap or the first refused move.
function sortContainer(containerId)
	if not world.entityExists(containerId) then return false end

	local ok, items = pcall(world.containerItems, containerId)
	if not ok or type(items) ~= "table" then return false end

	local before = petports_sortTally(items)
	local order, disorder = petports_sortPlan(items)

	if disorder < SORT_MIN_DISORDER then
		sb.logInfo("PETPORT %s sort of %s: nothing to do on arrival (%s slot(s) "
			.. "out of place)",
			stationUniqueId(), sb.printJson(containerId), sb.printJson(disorder))
		return false
	end

	local at, where = {}, {}

	for _, record in ipairs(order) do
		at[record.key] = record
		where[record] = record.key
	end

	self.sortDrifted = false

	local moved, aborted = 0, nil

	for target = 1, #order do
		if moved >= SORT_MOVE_CAP then
			sb.logInfo("PETPORT %s sort of %s hit the move cap at %s -- the "
				.. "first %s slot(s) are in order and the rest waits for the "
				.. "next pass",
				stationUniqueId(), sb.printJson(containerId),
				sb.printJson(SORT_MOVE_CAP), sb.printJson(target - 1))
			break
		end

		local record = order[target]
		local source = where[record]

		if source ~= target then
			local hand = petports_sortLift(containerId, record, source)

			if hand == nil then
				aborted = "lift refused"
				break
			end

			local evicted = at[target]
			local carried = nil

			if evicted ~= nil then
				carried = petports_sortLift(containerId, evicted, target)

				if carried == nil then
					petports_sortLay(containerId, hand, source)
					aborted = "second lift refused"
					break
				end
			end

			if not petports_sortLay(containerId, hand, target) then
				if carried ~= nil then petports_sortLay(containerId, carried, source) end
				aborted = "destination refused"
				break
			end

			at[target] = record
			where[record] = target
			at[source] = nil

			if carried ~= nil then
				if not petports_sortLay(containerId, carried, source) then
					aborted = "return refused"
					break
				end

				at[source] = evicted
				where[evicted] = source
			end

			moved = moved + 1
		end
	end

	local okAfter, after = pcall(world.containerItems, containerId)

	if okAfter then
		local tally = petports_sortTally(after)

		for name, count in pairs(before) do
			if (tally[name] or 0) ~= count then
				sb.logError("PETPORT %s SORT CHANGED THE CONTENTS of %s: %s went "
					.. "from %s to %s",
					stationUniqueId(), sb.printJson(containerId), tostring(name),
					sb.printJson(count), sb.printJson(tally[name] or 0))
			end
		end

		for name, count in pairs(tally) do
			if before[name] == nil then
				sb.logError("PETPORT %s SORT CHANGED THE CONTENTS of %s: %s %s "
					.. "appeared out of nothing",
					stationUniqueId(), sb.printJson(containerId),
					sb.printJson(count), tostring(name))
			end
		end
	end

	if aborted ~= nil then
		sb.logError("PETPORT %s sort of %s ABANDONED after %s move(s): %s",
			stationUniqueId(), sb.printJson(containerId), sb.printJson(moved),
			tostring(aborted))
		return moved > 0
	end

	if moved > 0 then
		petports_metrics.add("tidy", 1)

		sb.logInfo("PETPORT %s sorted %s: %s slot(s) moved, %s stack(s) in order "
			.. "(TIDY +1, score %s)",
			stationUniqueId(), sb.printJson(containerId), sb.printJson(moved),
			sb.printJson(#order),
			sb.printJson((self.petData and self.petData.stats
				and self.petData.stats.tidy) or 0))
	end

	return moved > 0
end


-- Returns whether a work claim is free for this port to take.
function petports_claimFree(workId)
	local claim = petports_claimGet(workId)

	return (claim == nil)
		or claim.owner == stationUniqueId()
		or (claim.expires or 0) <= world.time()
end


petports_soilCache = {}

petports_wetNameCache = nil

-- Returns the wet matmod a dry soil turns into, confirmed against farming.config's inverse table.
function petports_wetModName(dryName, transformModId)
	if petports_wetNameCache == nil then
		petports_wetNameCache = {}

		for _, path in ipairs({ "/farming.config", "/assets/farming.config" }) do
			local ok, config = pcall(root.assetJson, path)

			if ok and type(config) == "table" and type(config.wetToDryMods) == "table" then
				for wet, dry in pairs(config.wetToDryMods) do
					petports_wetNameCache[tostring(dry)] = tostring(wet)
				end

				sb.logInfo("PETPORT %s read wetToDryMods from %s: %s",
					stationUniqueId(), path, sb.printJson(config.wetToDryMods))
				break
			end
		end
	end

	local inverted = petports_wetNameCache[tostring(dryName)]
	if inverted == nil then
		return nil, "no wetToDryMods entry for " .. tostring(dryName)
	end

	local ok, mod = pcall(root.modConfig, inverted)

	if not ok or type(mod) ~= "table" or type(mod.config) ~= "table" then
		return nil, "wetToDryMods names " .. tostring(inverted)
			.. " but root.modConfig does not know it"
	end

	if mod.config.modId ~= transformModId then
		return nil, string.format(
			"wetToDryMods names %s (modId %s) but the soil transforms to %s",
			tostring(inverted), tostring(mod.config.modId),
			tostring(transformModId))
	end

	return inverted, "farming.config inverse, modId confirmed"
end

-- Returns whether a matmod is tilled and dry, and which liquids it takes, cached.
function petports_soilInfo(modName)
	if modName == nil then return nil end

	local key = tostring(modName)
	if petports_soilCache[key] ~= nil then return petports_soilCache[key] end

	local info = { tilled = false, dry = false, wants = {} }
	local ok, mod = pcall(root.modConfig, key)

	if ok and type(mod) == "table" and type(mod.config) == "table" then
		info.tilled = mod.config.tilled == true

		for _, interaction in ipairs(mod.config.liquidInteractions or {}) do
			if interaction.transformModId ~= nil and interaction.liquidId ~= nil then
				local okLiquid, liquid = pcall(root.liquidConfig, interaction.liquidId)
				local item = nil
				local tint = nil

				if okLiquid and type(liquid) == "table" and type(liquid.config) == "table" then
					item = liquid.config.itemDrop

					local colour = liquid.config.color

					if type(colour) == "table" and #colour >= 3 then
						-- Clamps a colour channel to 0-255.
						local function channel(value)
							return math.max(0, math.min(255, math.floor(tonumber(value) or 0)))
						end

						tint = string.format("%02X%02X%02XFF",
							channel(colour[1]), channel(colour[2]), channel(colour[3]))
					end
				end

				local wetName, via = petports_wetModName(key, interaction.transformModId)

				if item ~= nil and wetName ~= nil then
					info.dry = true
					table.insert(info.wants, {
						liquidId = interaction.liquidId,
						item = item,
						transformModId = interaction.transformModId,
						newMod = wetName,
						tint = tint
					})
				elseif item ~= nil then
					sb.logInfo("PETPORT %s soil %s: liquid %s yields %s but mod %s "
						.. "has no resolvable name (%s) -- cannot water this soil",
						stationUniqueId(), key, sb.printJson(interaction.liquidId),
						tostring(item), sb.printJson(interaction.transformModId),
						tostring(via))
				end
			end
		end
	end

	sb.logInfo("PETPORT %s soil %s: tilled %s dry %s wants %s",
		stationUniqueId(), key, tostring(info.tilled), tostring(info.dry),
		sb.printJson(info.wants))

	petports_soilCache[key] = info
	return info
end

-- Returns whether a position lies in the network's rects.
function petports_inNetworkCoverage(position)
  local rects = self.networkRects
  if rects == nil or #rects == 0 then rects = { petports_portCoverageRect() } end

  for _, rect in ipairs(rects) do
    if petports_rectContains(rect, position) then return true end
  end

  return false
end

-- Returns the nearest reachable beacon holding a seed.
function petports_containerWithSeed(seedName, wantDeposit, wantRestock)
	local sources = {}

	if wantRestock then
		for _, beacon in ipairs(petports_beaconsFor("restock")) do
			table.insert(sources, beacon)
		end
	end

	if wantDeposit then
		for _, beacon in ipairs(petports_beaconsFor("deposit")) do
			table.insert(sources, beacon)
		end
	end

	for _, beacon in ipairs(sources) do
		if world.entityExists(beacon.id) then
			local available = world.containerAvailable(beacon.id,
				{ name = seedName, count = 1 })

			if type(available) == "number" and available >= 1 then
				if petports_servicePointNear("crate " .. tostring(beacon.id),
					beacon.id, beacon.position, 4) ~= nil then
					return beacon.id
				end
			end
		end
	end

	return nil
end

PETPORTS_WORK = PETPORTS_WORK or {}

-- Adds a work entry to the port's list in order, replacing any entry of the same name.
function petports_registerWork(entry)
	assert(type(entry) == "table" and type(entry.name) == "string",
		"petports_registerWork needs a table with a name")
	assert(type(entry.generate) == "function",
		"petports_registerWork entry " .. entry.name .. " needs a generate function")

	petports_unregisterWork(entry.name)

	entry.order = tonumber(entry.order) or 0
	if entry.reasonOrder == true then entry.reasonOrder = entry.order end

	local at = #PETPORTS_WORK + 1

	for index, other in ipairs(PETPORTS_WORK) do
		if other.order > entry.order then
			at = index
			break
		end
	end

	table.insert(PETPORTS_WORK, at, entry)
end

-- Removes a work entry by name and returns it.
function petports_unregisterWork(name)
	for index, entry in ipairs(PETPORTS_WORK) do
		if entry.name == name then
			return table.remove(PETPORTS_WORK, index)
		end
	end

	return nil
end

-- Returns a work entry by name.
function petports_workEntry(name)
	for _, entry in ipairs(PETPORTS_WORK) do
		if entry.name == name then return entry end
	end

	return nil
end

-- Returns whether the port takes part in a participation group and is not oblivious.
function petports_workGroup(group)
	return not petportOblivious() and petportParticipates(group)
end

-- Returns whether a defrag module is live and the port takes part in one of its groups.
function petports_workDefrag(group)
	return not petportOblivious() and petportDefrag() and petportParticipates(group)
end

-- Returns whether a farming module is live and does one class of farm work.
function petports_workFarming(class)
	return not petportOblivious() and petportFarming() and petportFarmingDoes(class)
end

petports_registerWork({
	name = "fuelled",
	order = 800,
	profile = false,
	generate = function()
		if petportFuelled() then return nil end
		return nil, "out of fuel -- finishing what it holds, taking nothing new", true
	end
})

petports_registerWork({
	name = "cargoStall",
	order = 1000,
	profile = false,
	generate = function(ctx)
		if self.petData == nil or self.petData.cargo == nil
		   or #self.petData.cargo == 0 then
			return nil
		end

		local topUp = petports_workGroup("hauling") and petports_collectWork ~= nil
			and petports_portProf("g.collectTopUp", petports_collectWork, true) or nil

		if topUp ~= nil then
			sb.logInfo("PETPORT %s stalled with cargo -- topping up %s instead of idling",
				stationUniqueId(), tostring(topUp.id))
			return topUp, nil, true
		end

		return nil, ctx.reasons.deposit
			or ("carrying " .. sb.printJson(#self.petData.cargo)
				.. " stack(s) with no dispatchable deposit target"), true
	end
})

-- Runs one named hook on every registered work entry that has it.
function petports_workHook(hook, ...)
	for _, entry in ipairs(PETPORTS_WORK) do
		if entry[hook] ~= nil then
			petports_portProf(hook .. "." .. entry.name, entry[hook], ...)
		end
	end
end

-- Returns the text naming the work this port has switched off, or nil.
function petports_findWorkOptedOut()
	local oblivious = petportOblivious()
	local off = {}

	if not petports_workGroup("hauling") then table.insert(off, "hauling") end
	if not petports_workGroup("restock") then table.insert(off, "restock") end

	if oblivious or not petportDefrag() then
		table.insert(off, petportDefrag() and "defrag module (port off)"
			or "tidy (deposit crates)/compact/defrag (no module)")
	else
		if not petportParticipates("tidy") then table.insert(off, "tidy (deposit crates)") end
		if not petportParticipates("compact") then table.insert(off, "compact") end
		if not petportParticipates("defrag") then table.insert(off, "defrag") end
		if not petportParticipates("sort") then table.insert(off, "sort") end
	end

	if oblivious or not petportFarming() then
		table.insert(off, petportFarming() and "farming (port off)" or "farming (no module)")
	else
		for _, class in ipairs(FARMING_CLASSES) do
			if not petportFarmingDoes(class) then
				table.insert(off, "farming: " .. class)
			end
		end
	end

	if not petports_workGroup("machines") then table.insert(off, "machines") end

	if #off == 0 then return nil end

	return "port does not participate in " .. table.concat(off, ", ")
end

-- Joins the reasons the entries left behind, in reasonOrder.
function petports_findWorkReasons(ctx)
	local slots = {}
	local joined = {}

	for index, entry in ipairs(PETPORTS_WORK) do
		if entry.reasonOrder then
			local reason = ctx.reasons[entry.name]
			local slot = entry.reasonJoin and joined[entry.reasonJoin] or nil

			if slot == nil then
				slot = { order = entry.reasonOrder, index = index, parts = {} }
				table.insert(slots, slot)
				if entry.reasonJoin then joined[entry.reasonJoin] = slot end
			end

			if reason ~= nil then table.insert(slot.parts, tostring(reason)) end
		end
	end

	table.sort(slots, function(a, b)
		if a.order ~= b.order then return a.order < b.order end
		return a.index < b.index
	end)

	local reasons = {}

	for _, slot in ipairs(slots) do
		if #slot.parts > 0 then
			table.insert(reasons, table.concat(slot.parts, ", and "))
		end
	end

	return reasons
end

-- Runs the registered work entries in order and returns the first task, the nearest one among entries sharing an order, or nil with the reason and the switched-off work.
function petports_findWork()
	local ctx = { reasons = {} }
	local index = 1

	while index <= #PETPORTS_WORK do
		local order = PETPORTS_WORK[index].order
		local best, bestEntry, offers = nil, nil, {}

		while index <= #PETPORTS_WORK and PETPORTS_WORK[index].order == order do
			local entry = PETPORTS_WORK[index]
			index = index + 1

			if entry.gate == nil or entry.gate(ctx) then
				local work, reason, stop

				if entry.profile == false then
					work, reason, stop = entry.generate(ctx)
				else
					work, reason, stop = petports_portProf(entry.profile or ("g." .. entry.name),
						entry.generate, ctx)
				end

				if stop then return work, reason end

				if petports_dispatchable(work) ~= nil then
					local distance = tonumber(work.distance) or math.huge

					table.insert(offers, entry.name .. " " .. string.format("%.1f", distance))

					if best == nil or distance < (tonumber(best.distance) or math.huge) then
						best, bestEntry = work, entry
					end
				else
					ctx.reasons[entry.name] = reason

					local idle = entry.idleLog

					if idle ~= nil and reason ~= nil and reason ~= self[idle.key] then
						self[idle.key] = reason
						sb.logInfo("PETPORT %s %s: %s", stationUniqueId(), idle.label,
							tostring(reason))
					end
				end
			end
		end

		if best ~= nil then
			if #offers > 1 then
				sb.logInfo("PETPORT %s order %s tie: %s wins of %s", stationUniqueId(),
					sb.printJson(order), bestEntry.name, table.concat(offers, ", "))
			end

			return best
		end
	end

	local optedOut = petports_findWorkOptedOut()
	local reasons = petports_findWorkReasons(ctx)

	if #reasons == 0 then return nil, optedOut end

	local reason = table.concat(reasons, "; ")

	if optedOut ~= nil then reason = reason .. "; " .. optedOut end

	return nil, reason
end

-- Logs why no work was taken, at most once per repeat window for a given reason.
function petports_reject(reason)
  if reason == self.lastReject
     and (self.lastRejectAt or 0) + REJECT_REPEAT > world.time() then
    return
  end

  self.lastReject = reason
  self.lastRejectAt = world.time()

  sb.logInfo("PETPORT %s no dispatch: %s", stationUniqueId(), reason)
end


-- Takes the claim on the chosen work, attaches the cargo manifest, and hands the task to the unit.
function petports_dispatchWork()
  if self.petId == nil or not world.entityExists(self.petId) then
    return petports_reject("no unit")
  end

  local work, why = petports_portProf("findWork", petports_findWork)
  if work == nil then
    return petports_reject(why)
  end

  if self.petId == nil or not world.entityExists(self.petId) then
    return petports_reject("unit went away while work was being chosen")
  end


  if not petports_portProf("claimTake", petports_claimTake, work.id, stationUniqueId(),
                            work.type, work.position, CLAIM_TTL) then
    return petports_reject("claimed by another owner: " .. tostring(work.id))
  end

  if self.petData ~= nil and self.petData.cargo ~= nil then
    local manifest = {}
    for _, stack in ipairs(self.petData.cargo) do
      table.insert(manifest, string.format("%sx %s",
        tostring(stack.count or 1), tostring(stack.name)))
    end
    work.cargo = manifest
  end

  if not petports_portProf("assignTask", world.callScriptedEntity, self.petId,
                  "petports_assignTask", work) then
    petports_claimRelease(work.id, stationUniqueId())
    return petports_reject("unit refused assignment")
  end

  self.task = work

  self.taskMoving = false
  self.taskAge = 0
  self.lastReject = nil
  sb.logInfo("PETPORT %s dispatched %s to %s",
    stationUniqueId(), work.id, sb.printJson(work.position))
end

-- Refreshes the running task's claim, and drops it on the deadline or once the unit stops holding it.
function petports_trackWork()
  self.taskAge = (self.taskAge or 0) + WORK_INTERVAL
  if self.taskAge >= TASK_DEADLINE then
    local taskId = self.task.id
    petports_abandonTask("deadline -- no report in " .. sb.printJson(TASK_DEADLINE) .. "s")
    petports_noteFailure(taskId, "deadline")

    if self.petId ~= nil and world.entityExists(self.petId) then
      world.callScriptedEntity(self.petId, "petports_clearTask")
    end
    return
  end

  if self.petId == nil or not world.entityExists(self.petId) then
    self.task = nil
    return petports_reject("unit gone mid-task")
  end

  if world.callScriptedEntity(self.petId, "petports_taskId") ~= self.task.id then
    local taskId = self.task.id
    self.task = nil
    petports_noteFailure(taskId, "unit stopped holding the task")
    return petports_reject("unit is no longer holding the task")
  end

  sb.logInfo("PETPORT %s tracking %s, age %s of %s",
    stationUniqueId(), self.task.id,
    sb.printJson(self.taskAge), sb.printJson(TASK_DEADLINE))

  petports_claimRefresh(self.task.id, stationUniqueId(), CLAIM_TTL)
end


CROSSHAIR_INTERVAL = 0.5

CROSSHAIR_REFRESH = 20.0

CROSSHAIR_COLORS = {
  routing = "ffd23fff",

  enroute = "5fd35fff",

  unroutable = "e04b4bff",

  blocked = "ef8b3cff",

  unclaimed = "9aa0a6ff"
}

CROSSHAIR_PROJECTILE = {
  routing = "petports_crosshair",
  enroute = "petports_crosshair",
  unroutable = "petports_crosshair_failed",
  blocked = "petports_crosshair_warn",
  unclaimed = "petports_crosshair"
}

CROSSHAIR_PRIORITY = {
  routing = 4,
  enroute = 4,
  unroutable = 3,
  blocked = 2,
  unclaimed = 1
}

-- Returns the claim id for a drop's marker.
function petports_crosshairClaimId(dropId)
  return "mark:" .. tostring(dropId)
end

CROSSHAIR_CLAIM_TTL = 4.0
CROSSHAIR_CLAIM_RENEW = 1.5

-- Takes or renews the marker claim on a drop, taking it off another port only for a higher priority state.
function petports_crosshairClaim(dropId, state)
  local claimId = petports_crosshairClaimId(dropId)
  local existing = petports_claimGet(claimId)
  local mine = existing ~= nil and existing.owner == stationUniqueId()

  if mine then
    if (existing.expires or 0) - world.time() < CROSSHAIR_CLAIM_RENEW then
      petports_claimRefresh(claimId, stationUniqueId(), CROSSHAIR_CLAIM_TTL)
    end

    return true
  end

  if existing ~= nil and (existing.expires or 0) > world.time() then
    local theirs = CROSSHAIR_PRIORITY[existing.type] or 0
    local ours = CROSSHAIR_PRIORITY[state] or 0

    if ours <= theirs then return false end

    sb.logInfo("PETPORT %s crosshair for drop %s: taking over from %s (%s beats %s)",
      stationUniqueId(), sb.printJson(dropId), tostring(existing.owner),
      tostring(state), tostring(existing.type))

    petports_claimRelease(claimId, nil)
  end

  return petports_claimTake(claimId, stationUniqueId(), nil, state,
    world.entityPosition(dropId), CROSSHAIR_CLAIM_TTL)
end

-- Releases this port's marker claim on a drop.
function petports_crosshairRelease(dropId)
  petports_claimRelease(petports_crosshairClaimId(dropId), stationUniqueId())
end

-- Returns the marker colour for a state, preferring the unit's own override.
function petports_crosshairColor(state)
  local overrides = self.petData ~= nil and self.petData.crosshairColors or nil

  if type(overrides) == "table" and type(overrides[state]) == "string" then
    return overrides[state]
  end

  return CROSSHAIR_COLORS[state]
end

-- Returns every drop in the network rects.
function petports_crosshairDrops()
  local rects = self.networkRects
  if rects == nil or #rects == 0 then return {} end

  local drops = {}
  local seen = {}

  for _, area in ipairs(rects) do
    local found = world.entityQuery({ area[1], area[2] }, { area[3], area[4] }, {
      includedTypes = { "itemDrop" }
    })

    for _, dropId in ipairs(found or {}) do
      if not seen[dropId] then
        seen[dropId] = true
        table.insert(drops, dropId)
      end
    end
  end

  return drops
end

-- Returns whether any deposit beacon would accept a drop, caching the verdict per item and beacon.
function petports_crosshairStorable(dropId, cache)
  local ok, descriptor = pcall(world.itemDropItem, dropId)

  if not ok or type(descriptor) ~= "table" or type(descriptor.name) ~= "string" then
    return true
  end

  if cache[descriptor.name] ~= nil then return cache[descriptor.name] end

  self.filterVerdicts = self.filterVerdicts or {}
  if self.filterVerdicts.version ~= (self.beaconVersion or 0) then
    self.filterVerdicts = { version = self.beaconVersion or 0 }
  end

  local storable = false

  for _, beacon in ipairs(petports_beaconsFor("deposit")) do
    local verdictKey = tostring(beacon.id) .. "|" .. descriptor.name
    local accepts = self.filterVerdicts[verdictKey]

    if accepts == nil then
      accepts = petports_filterAccepts(beacon.filter, descriptor.name) == true
      self.filterVerdicts[verdictKey] = accepts
    end

    if world.entityExists(beacon.id) and accepts then

      local fits = world.containerItemsCanFit ~= nil
        and world.containerItemsCanFit(beacon.id, descriptor) or nil

      if fits == nil or fits > 0 then
        storable = true
        break
      end
    end
  end

  cache[descriptor.name] = storable

  return storable
end

-- Returns the marker state each drop should carry: routing, enroute, unroutable, blocked or unclaimed.
function petports_crosshairWanted()
  local wanted = {}

  if self.task ~= nil and self.task.type == "collect" and self.task.target ~= nil then
    wanted[self.task.target] = self.taskMoving and "enroute" or "routing"
  end

  for taskId, record in pairs(self.workFailures or {}) do
    local dropId = string.match(taskId, "^drop:(%d+)$")

    if dropId ~= nil and (record["until"] or 0) > world.time() then
      dropId = tonumber(dropId)

      if wanted[dropId] == nil then
        wanted[dropId] = record.unroutable and "unroutable" or "blocked"
      end
    end
  end

  local storable = {}

  for _, dropId in ipairs(petports_crosshairDrops()) do
    if wanted[dropId] == nil then
      local claim = petports_claimGet("drop:" .. dropId)
      local mine = claim == nil
        or claim.owner == stationUniqueId()
        or (claim.expires or 0) <= world.time()

      if not mine then
        wanted[dropId] = nil

      elseif not petports_crosshairStorable(dropId, storable) then
        wanted[dropId] = "blocked"

      else
        wanted[dropId] = "unclaimed"
      end
    end
  end

  return wanted
end

-- Kills a marker projectile.
function petports_crosshairKill(marker)
  if marker == nil or marker.id == nil then return end

  if world.entityExists(marker.id) then
    world.sendEntityMessage(marker.id, "kill")
  end
end

CROSSHAIR_DRIFT = 0.5

CROSSHAIR_DWELL = 1.5

CROSSHAIR_IMMEDIATE = {
  routing = { enroute = true }
}

-- Spawns, moves and kills the drop markers to match the wanted states, holding each one briefly before it changes.
function petports_crosshairRefresh(dt)
  self.crosshairs = self.crosshairs or {}

  if not petportCrosshairs() then
    if next(self.crosshairs) ~= nil then
      sb.logInfo("PETPORT %s retiring crosshairs: switched off", stationUniqueId())
      petports_crosshairClear()
    end
    return
  end

  self.crosshairTimer = (self.crosshairTimer or 0) - dt
  if self.crosshairTimer > 0 then return end
  self.crosshairTimer = CROSSHAIR_INTERVAL

  local wanted = petports_crosshairWanted()

  self.crosshairKnownDrops = self.crosshairKnownDrops or {}
  local fresh = false

  for dropId in pairs(wanted) do
    if not self.crosshairKnownDrops[dropId] then
      self.crosshairKnownDrops[dropId] = true
      fresh = true
    end
  end

  for dropId in pairs(self.crosshairKnownDrops) do
    if wanted[dropId] == nil and not world.entityExists(dropId) then
      self.crosshairKnownDrops[dropId] = nil
    end
  end

  if fresh and self.task == nil and (self.workTimer or 0) > 0 then
    self.workTimer = 0
  end

  for dropId, marker in pairs(self.crosshairs) do
    if marker.position ~= nil and world.entityExists(dropId)
       and world.entityExists(marker.id) then

      local at = world.entityPosition(dropId)

      if world.magnitude(at, marker.position) > CROSSHAIR_DRIFT then
        world.sendEntityMessage(marker.id, "move", at)

        sb.logInfo("PETPORT %s crosshair MOVE %s (%s) from %s to %s",
          stationUniqueId(), sb.printJson(marker.id), tostring(marker.state),
          sb.printJson(marker.position), sb.printJson(at))

        marker.position = at
      end
    end

    local exempt = CROSSHAIR_IMMEDIATE[marker.state] ~= nil
      and CROSSHAIR_IMMEDIATE[marker.state][wanted[dropId]] == true

    local settling = wanted[dropId] ~= nil
      and wanted[dropId] ~= marker.state
      and not exempt
      and (world.time() - (marker.since or 0)) < CROSSHAIR_DWELL

    local keep = wanted[dropId] ~= nil
      and (wanted[dropId] == marker.state or settling)
      and world.entityExists(dropId)
      and world.entityExists(marker.id)

    if not keep then
      petports_crosshairKill(marker)
      petports_crosshairRelease(dropId)
      self.crosshairs[dropId] = nil
    end
  end

  for dropId, state in pairs(wanted) do
    local marker = self.crosshairs[dropId]

    if world.entityExists(dropId) and petports_crosshairClaim(dropId, state) then
      local due = marker == nil or (marker.refresh or 0) <= world.time()

      if due then
        petports_crosshairKill(marker)

        local at = world.entityPosition(dropId)

        local ok, id = pcall(world.spawnProjectile,
          CROSSHAIR_PROJECTILE[state],
          at,

          nil,
          { 0, 0 },
          false,
          {
            processing = "?multiply=" .. petports_crosshairColor(state),

            petportsItem = dropId
          })

        sb.logInfo("PETPORT %s crosshair SPAWN %s for drop %s at %s (previous %s)",
          stationUniqueId(), tostring(state), sb.printJson(dropId),
          sb.printJson(at),
          marker ~= nil and sb.printJson(marker.position) or "none")

        if ok and id ~= nil then
          self.crosshairs[dropId] = {
            id = id,
            state = state,

            position = at,

            since = world.time(),
            refresh = world.time() + CROSSHAIR_REFRESH
          }
        else
          if self.crosshairs[dropId] ~= nil or not self.crosshairFailed then
            self.crosshairFailed = true
            sb.logError("PETPORT %s could not spawn a %s crosshair at %s: %s",
              stationUniqueId(), tostring(CROSSHAIR_PROJECTILE[state]),
              sb.printJson(world.entityPosition(dropId)), tostring(id))
          end

          self.crosshairs[dropId] = nil
        end
      end
    end
  end
end

-- Kills every marker and releases its claim.
function petports_crosshairClear()
  for dropId, marker in pairs(self.crosshairs or {}) do
    petports_crosshairKill(marker)
    petports_crosshairRelease(dropId)
    self.crosshairs[dropId] = nil
  end
end


-- Runs the work beat: the sweeps and network refresh, then the beacon scan and the scanBeat hooks across three ticks, then the dispatch.
function petports_workUpdate(dt)
  if self.beatStage ~= nil then
    local stage = self.beatStage

    if stage == 1 then
      petports_portProf("refreshBeacons", petports_refreshBeacons, WORK_INTERVAL)
      self.beatStage = 2
      return
    elseif stage == 2 then
      petports_workHook("scanBeat", WORK_INTERVAL)
      petports_portProf("publishUnitPosition", petports_publishUnitPosition)
      petports_portProf("ensureResidency", petports_ensureResidency)
      self.beatStage = 3
      return
    end

    self.beatStage = nil
    petports_workBeatDispatch()
    return
  end

  self.workTimer = self.workTimer - dt
  if self.workTimer > 0 then return end
  self.workTimer = WORK_INTERVAL

  petports_portProf("claimsSweep", petports_claimsSweep)

  petports_workHook("workBeat")

  local registry = petports_registry()
  if (registry.ports or {})[stationUniqueId()] == nil then
    sb.logInfo("PETPORT %s registry entry is missing -- re-publishing",
      stationUniqueId())
    petports_publishRegistry()
  end

  petports_portProf("refreshNetwork", petports_refreshNetwork)

  self.beatStage = 1
end

-- Dispatches new work, or tracks the running task.
function petports_workBeatDispatch()
  local tickState = string.format("%s/%s", tostring(self.petId),
    self.task and self.task.id or "none")

  if tickState ~= self.tickState then
    self.tickState = tickState

    sb.logInfo("PETPORT %s tick: unit %s task %s",
      stationUniqueId(), sb.printJson(self.petId),
      self.task and self.task.id or "none")
  end

  if self.task == nil then
    petports_portProf("dispatchWork", petports_dispatchWork)
  else
    petports_portProf("trackWork", petports_trackWork)
  end
end

-- Starts the hull opening or closing unless it is already in or heading for that state.
function setHullAnimationStateIntent(intent)

	local currentHullState = animator.animationState("hullState")
	if intent == "open" then
		if 
			currentHullState ~= "opening" and 
			currentHullState ~= "open"
		then
		setAnimationStateForAllHullComponents("opening")
		end
		
	elseif intent == "close" then
		if 
			currentHullState ~= "closing" and 
			currentHullState ~= "closed"
		then
		setAnimationStateForAllHullComponents("closing")
		end
	end
end

-- Sets the hull, door and interior animations to the same state.
function setAnimationStateForAllHullComponents(anim)
	if not anim then return end
	animator.setAnimationState("hullState", anim)
    animator.setAnimationState("doorState", anim)
    animator.setAnimationState("interiorState", anim)
end

-- Runs the port's tick: markers, tick hooks, pane mirror, the socketed item, the environment and health checks, the spawn, and the work beat.
function petports_updateInner(dt)
  if self.firstUpdate then
    self.firstUpdate = false
    stationUniqueId()

    petports_claimsClearOwner(stationUniqueId())

    petports_workHook("firstUpdate")
    petports_ensureResidency()
    petports_publishRegistry()
  end

  petports_portProf("crosshairRefresh", petports_crosshairRefresh, dt)

  petports_workHook("tick", dt)

  petports_portProf("mirrorPaneState", mirrorPaneState, dt)

  local item = petports_socketedItem()

  if item == nil then
    if self.petId ~= nil then
      saveAndDespawn()
      petports_cargoTrace("unsocket: discarding petData", self.petData and self.petData.cargo)
      self.petData = nil
    end
    setHullAnimationStateIntent("close")

    petports_abandonTask("item removed")

    petports_publishUnitPosition()
    return
  end

  if self.petData ~= nil and petports_itemSeed(item) ~= self.petData.seed then
    petports_trace("item swapped, outgoing seed", self.petData.seed)
    saveAndDespawn(true)
    self.petData = nil
    petports_abandonTask("unit swapped out")
  end

  if self.petData == nil then
    self.petData = petports_petDataFrom(item)
    petports_cargoTrace("socket: petData built", self.petData and self.petData.cargo)
    if self.petData == nil then
      setHullAnimationStateIntent("close")
      petports_abandonTask("socketed item is not a pet")
      return
    end

    self.envUnsuitable = nil
    self.envRetired = nil
    self.envTypeUnreadable = nil

    self.environmentTimer = 0
    self.spawnTimer = 0
  end

  petports_workHook("socketed")

  local enabled = petportEnabled()

  if self.fadingPetId ~= nil and not world.entityExists(self.fadingPetId) then
    self.fadingPetId = nil
  end

  self.environmentTimer = (self.environmentTimer or 0) - dt
  if self.environmentTimer <= 0 then
    self.environmentTimer = ENVIRONMENT_INTERVAL
    petports_environmentCheck()

    petports_mediumCheck()

    petports_workHook("environmentBeat")
  end

  local unitPresent = self.petId ~= nil or self.fadingPetId ~= nil
  local habitable = self.envUnsuitable == nil

  setHullAnimationStateIntent(((enabled and habitable) or unitPresent) and "open" or "close")

  if not enabled then
    if self.petId ~= nil then
      sb.logInfo("PETPORT %s despawning unit: port is switched off. Its state and "
        .. "cargo are written back to the socketed item.", stationUniqueId())

      saveAndDespawn()
      petports_abandonTask("port disabled")

      petports_publishUnitPosition()
    end
  end

-- Records the unit's damage team when it changes.
function petports_teamWatch()
  if self.petId == nil or not world.entityExists(self.petId) then
    self.watchedTeam = nil
    return
  end

  local team = world.entityDamageTeam(self.petId)
  local seen = team and (tostring(team.type) .. "/" .. tostring(team.team)) or "nil"

  if seen ~= self.watchedTeam then
    sb.logInfo("PETPORT %s unit %s damage team AS THE WORLD SEES IT: %s (was %s)",
      stationUniqueId(), sb.printJson(self.petId), seen, tostring(self.watchedTeam))
    self.watchedTeam = seen
  end
end

  self.healthTimer = (self.healthTimer or 0) - dt
  if self.healthTimer <= 0 then
    self.healthTimer = HEALTH_INTERVAL
    petports_healthCheck()
  end

  petports_teamWatch()

  if enabled and (self.petId == nil or not world.entityExists(self.petId)) then
    self.spawnTimer = self.spawnTimer - dt
    if self.spawnTimer <= 0 then
      if self.petId ~= nil then
        self.petId = nil
      end

      if animator.animationState("hullState") ~= "open" then
        self.spawnTimer = DOOR_POLL
      else
        if self.envUnsuitable == nil then
          spawnPet()
        end

        self.spawnTimer = RESPAWN_GRACE
      end
    end
  end

  if self.petId ~= nil and world.entityExists(self.petId) then
    if self.task ~= nil then
      petports_metrics.add("active", dt)
    end

    local position = world.entityPosition(self.petId)

    if position ~= nil then
      if self.odometerLast ~= nil and self.task ~= nil then
        local step = world.magnitude(position, self.odometerLast)
        if step < 10 then
          petports_metrics.add("traveled", step)
        end
      end
      self.odometerLast = position
    end
  else
    self.odometerLast = nil
  end

  self.writeTimer = self.writeTimer - dt
  if self.dirty or self.writeTimer <= 0 then
    writeBackToItem()
    self.writeTimer = WRITE_INTERVAL
  end


  pushModuleEffects()

  pushPetName()

  pushUnitLight()

  pushUnitBubbles()

  pushUnitBubble()

  petports_portProf("workUpdate", petports_workUpdate, dt)
  petports_portProfReport()
end

-- Returns the configured interact action.
function onInteraction(args)
  return config.getParameter("interactAction")
end

local PETPORT_SLOW_TICK_MS = 30
local PETPORT_STALL_MS = 250

-- Runs the tick inside the claim snapshot, logging a stall between ticks and a slow tick.
function update(dt)
  local began = nil
  if type(os) == "table" and type(os.clock) == "function" then
    local ok, t = pcall(os.clock)
    if ok and type(t) == "number" then began = t end
  end

  if began ~= nil and self.tickEndedAt ~= nil then
    local gap = (began - self.tickEndedAt) * 1000
    if gap >= PETPORT_STALL_MS then
      sb.logInfo("PETPORT STALL %s ms of process time between my ticks (clock %s)",
        tostring(math.floor(gap)), tostring(math.floor(began * 1000)))
    end
  end

  petports_claimsMemoBegin()
  petports_updateInner(dt)
  petports_claimsMemoEnd()

  if began ~= nil then
    local ok, t = pcall(os.clock)
    if ok and type(t) == "number" then
      local ms = (t - began) * 1000
      if ms >= PETPORT_SLOW_TICK_MS then
        sb.logInfo("PETPORT slow tick: %s ms", tostring(math.floor(ms)))
      end
      self.tickEndedAt = t
    end
  end
end

-- Refreshes the pane at once, and the work beat too when no task is running.
function containerCallback()
  self.paneTimer = 0
  if self.task == nil then self.workTimer = 0 end
end
