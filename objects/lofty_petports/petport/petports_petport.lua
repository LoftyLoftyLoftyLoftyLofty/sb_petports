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
  waterrestock = true
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

local crosshairClear

local stackSizeOf
local stackSizeFor

local socketedItem

CARGO_TRACE = true

-- Returns a printable summary of a cargo list.
local function cargoSummary(cargo)
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
local function normaliseCargo(cargo)
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
local function cargoTrace(where, cargo)
  if not CARGO_TRACE then return end
  local ok, text = pcall(string.format, "PETPORT CARGO | %-22s | %s",
    tostring(where), cargoSummary(cargo))
  sb.logInfo("%s", ok and text or ("PETPORT CARGO | bad trace at " .. tostring(where)))
end


BEACON_REQUESTS_KEY = "petports_beaconRequests"

BEACON_FEEDER_KEY = "petports_beaconFeeder"

BEACON_ITEM_KEY = "petports_beaconItem"
BEACON_MIN_KEY = "petports_beaconMin"
BEACON_MAX_KEY = "petports_beaconMax"

HARVEST_INTERVAL = 5.0

FARMABLE_STAGE_BASE = 0

TRAP_INTERVAL = 5.0



WATER_CARRY = 10

WATER_CARRY_HYDRATED = 30

WATER_RUN_REACH = 32

PET_NAME_MAX = 24

CLAIM_TTL = 30.0

WORK_INTERVAL = 2.0

REJECT_REPEAT = 30.0

TASK_DEADLINE = 150.0

DIAG_DWELL = 3.0

FAILURE_BACKOFF = { 1.0, 2.0, 5.0, 10.0, 30.0 }

RETRY_ALLOWANCE = 4

UNROUTABLE_BACKOFF_FLOOR = 30.0

RECALL_LIMIT = 2

STRANDED_LIMIT = 3

VENT_SEARCH_MARGIN = 24

DIAG_FALLBACK = false

RESIDENCY_TYPE = "petports_residency"

-- Logs a labelled value when DEBUG is set.
local function trace(label, value)
  if not DEBUG then return end
  if value == nil then
    sb.logInfo("[petport] %s: nil", label)
  elseif type(value) == "table" then
    sb.logInfo("[petport] %s: %s", label, sb.printJson(value))
  else
    sb.logInfo("[petport] %s: %s", label, tostring(value))
  end
end

local metrics = {}

-- Adds an amount to one of the unit's stat counters.
metrics.add = function(key, amount)
  if self.petData == nil then return end
  if amount == nil or amount == 0 then return end

  self.petData.stats = self.petData.stats or {}
  self.petData.stats[key] = (self.petData.stats[key] or 0) + amount
end

-- Counts a treat against the total and against its flavor.
function countFed(flavor)
  metrics.add("fed", 1)

  if type(flavor) == "string" and flavor ~= "" then
    metrics.add("fed_" .. flavor, 1)
  else
    sb.logError("PETPORT %s counted a treat with no flavor (%s) -- the "
      .. "per-flavor rows will not add up to the total",
      stationUniqueId(), tostring(flavor))
  end
end

-- Returns this port's coverage rect.
local function coverageRect()
  return petports_coverageRect(entity.position(), COVERAGE_SIZE)
end

-- Writes this port's rect, position and network id into the registry, dropping any predecessor on the tile.
local function publishRegistry()
  local rect = coverageRect()

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
local function publishUnitPosition()
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
local function gatherVents()
	local ventReport = {}

  local rects = self.networkRects
  if rects == nil or #rects == 0 then rects = { coverageRect() } end

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
local function ventSignature(vents)
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
local function pruneRouteCache(vents)
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
local function refreshNetwork()
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

    local vents = gatherVents()
    if ventSignature(vents) ~= self.ventSignature then
      self.ventSignature = ventSignature(vents)
      unitChanged = true

      local removed = pruneRouteCache(vents)
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
      self.vents = gatherVents()
      self.ventSignature = ventSignature(self.vents)
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

-- Returns whether a position lies in the network's rects.
local function inNetwork(position)
  local rects = self.networkRects
  if rects == nil or #rects == 0 then rects = { coverageRect() } end

  for _, area in ipairs(rects) do
    if petports_rectContains(area, position) then return true end
  end
  return false
end


FAMILY_HELD = { asterite = true, animal = true }
FAMILY_STRIKES = 3
FAMILY_HOLD = 120.0

-- Returns whether a work family is held, releasing it once its hold expires.
local function familyOnHold(family)
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
local function noteFailure(taskId, reason)
  if taskId == nil then return end

  if taskId == "return:" .. stationUniqueId() then
    self.recallFailures = (self.recallFailures or 0) + 1

    self.recallAt = world.time()

    sb.logInfo("PETPORT %s recall failed (%s of %s): %s",
      stationUniqueId(), self.recallFailures, RECALL_LIMIT, reason)
    return
  end

  sb.logInfo("PETPORT %s noteFailure %s: %s", stationUniqueId(), taskId, tostring(reason))

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
     and not inNetwork(world.entityPosition(self.petId)) then
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
local function residencyUniqueId()
  local position = entity.position()
  return string.format("petports_residency_%s_%s",
    math.floor(position[1]), math.floor(position[2]))
end

-- Spawns the residency stagehand for this port when none exists.
local function ensureResidency()
  local residencyId = residencyUniqueId()
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
local function stopResidency()
  local residencyId = world.loadUniqueEntity(residencyUniqueId())
  if residencyId == nil then return end

  world.sendEntityMessage(residencyId, "petports_residencyStop")
end

-- Drops the held task and releases its claim.
local function abandonTask(reason)
  if self.task == nil then return end

  sb.logInfo("PETPORT %s abandoning %s: %s", stationUniqueId(), self.task.id, reason)
  petports_claimRelease(self.task.id, stationUniqueId())
  self.task = nil
end

local PETPORT_BUILD_STAMP = "2026-09-15a an upcycler holding plain treats with no charge and no reagent counts as idle for output collection"

PETPORT_PROFILE = true

local PORT_PROF_INTERVAL = 10.0
local portProfPhases = {}
local portProfAt = nil

-- Returns the process clock in seconds, or nil where it is unavailable.
local function portClock()
  if type(os) == "table" and type(os.clock) == "function" then
    local ok, t = pcall(os.clock)
    if ok and type(t) == "number" then return t end
  end
  return nil
end

-- Runs a function and adds its time to a named phase.
local function portProf(name, fn, ...)
  if not PETPORT_PROFILE then return fn(...) end

  local began = portClock()
  local a, b, c = fn(...)
  local now = portClock()

  local phase = portProfPhases[name]
  if phase == nil then
    phase = { calls = 0, ms = 0, max = 0 }
    portProfPhases[name] = phase
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
local function portProfReport()
  if not PETPORT_PROFILE then return end

  local t = world.time()
  portProfAt = portProfAt or (t + PORT_PROF_INTERVAL)
  if t < portProfAt then return end
  portProfAt = t + PORT_PROF_INTERVAL

  local parts = {}
  for name, phase in pairs(portProfPhases) do
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

  portProfPhases = {}
end




-- Turns asterite scanning on only when the matmod exists and drops a real item.
function asteriteLatch()
  self.asteriteEnabled = false
  self.asteriteDrop = nil

  local ok, mod = pcall(root.modConfig, PETPORTS_ASTERITE_MOD)

  if not ok or type(mod) ~= "table" or type(mod.config) ~= "table" then
    sb.logInfo("PETPORT asterite scan OFF: no matmod named %s in this asset "
      .. "tree, so there is nothing for this port to look for",
      PETPORTS_ASTERITE_MOD)
    return
  end

  local drop = mod.config.itemDrop

  if type(drop) ~= "string" or drop == "" then
    sb.logInfo("PETPORT asterite scan OFF: matmod %s declares no itemDrop, so "
      .. "mining it would yield nothing", PETPORTS_ASTERITE_MOD)
    return
  end

  local okItem, item = pcall(root.itemConfig, drop)

  if not okItem or item == nil then
    sb.logInfo("PETPORT asterite scan OFF: matmod %s drops %s and no such item "
      .. "exists", PETPORTS_ASTERITE_MOD, tostring(drop))
    return
  end

  self.asteriteEnabled = true
  self.asteriteDrop = drop

  sb.logInfo("PETPORT asterite scan ON: matmod %s drops %s, %s tiles per sweep",
    PETPORTS_ASTERITE_MOD, tostring(drop),
    sb.printJson(math.floor(COVERAGE_SIZE) * math.floor(COVERAGE_SIZE)))
end

-- Returns a scan start index hashed from this port's unique id.
function asteriteCursorSeed()
  local uniqueId = tostring(stationUniqueId() or "")
  local h = 0

  for i = 1, #uniqueId do
    h = (h * 31 + string.byte(uniqueId, i)) % 1048576
  end

  return h
end

-- Checks one tile of the coverage rect for the asterite mod, noting it in the store, and wraps at the end of a sweep.
function asteriteScanStep()
  if not self.asteriteEnabled then return end

  local size = math.floor(COVERAGE_SIZE)
  if size < 1 then return end

  local span = size * size

  if self.asteriteCursor == nil then
    self.asteriteCursor = asteriteCursorSeed() % span
    self.asteriteSweepAt = world.time()
    self.asteriteSweepNew = 0
    self.asteriteSweepSeen = 0

    sb.logInfo("PETPORT asterite scan starting at index %s of %s",
      sb.printJson(self.asteriteCursor), sb.printJson(span))
  end

  local rect = coverageRect()
  local index = self.asteriteCursor

  local tile =
  {
    math.floor(rect[1]) + (index % size),
    math.floor(rect[2]) + math.floor(index / size)
  }

  local ok, modName = pcall(world.mod, tile, "foreground")

  if ok and modName == PETPORTS_ASTERITE_MOD then
    self.asteriteSweepSeen = (self.asteriteSweepSeen or 0) + 1

    local added, count, full =
      petports_asteriteNote(tile, modName, stationUniqueId())

    if added then
      self.asteriteSweepNew = (self.asteriteSweepNew or 0) + 1

      sb.logInfo("PETPORT asterite FOUND %s at %s (store now %s)",
        tostring(modName), sb.printJson(tile), sb.printJson(count))
    end

    if full ~= self.asteriteFullSaid then
      self.asteriteFullSaid = full

      if full then
        sb.logInfo("PETPORT asterite store FULL at %s entries; new deposits "
          .. "refused until something is mined", sb.printJson(count))
      else
        sb.logInfo("PETPORT asterite store has room again at %s entries",
          sb.printJson(count))
      end
    end
  end

  index = index + 1

  if index >= span then
    index = 0

    local elapsed = world.time() - (self.asteriteSweepAt or world.time())
    local seen = self.asteriteSweepSeen or 0
    local new = self.asteriteSweepNew or 0

    sb.logInfo("PETPORT asterite SCAN WRAP: %s tiles in %s s, %s deposit(s) "
      .. "seen, %s new, %s already known, store %s",
      sb.printJson(span), sb.printJson(math.floor(elapsed)),
      sb.printJson(seen), sb.printJson(new), sb.printJson(seen - new),
      sb.printJson(petports_asteriteCount()))

    self.asteriteSweepAt = world.time()
    self.asteriteSweepNew = 0
    self.asteriteSweepSeen = 0
  end

  self.asteriteCursor = index
end

-- Logs the stored deposits up to a limit and returns how many there are.
function petports_asteriteDump(limit)
  limit = tonumber(limit) or 40

  local deposits = petports_asteriteAll()
  local n = 0
  local shown = 0

  for _, entry in pairs(deposits) do
    n = n + 1

    if shown < limit then
      shown = shown + 1

      sb.logInfo("PETPORT asterite [%s] %s at %s, found at %s by %s",
        sb.printJson(n), tostring(entry.mod), sb.printJson(entry.position),
        sb.printJson(math.floor(tonumber(entry.found) or 0)),
        tostring(entry.finder))
    end
  end

  sb.logInfo("PETPORT asterite dump: %s deposit(s) of %s shown, cap %s, "
    .. "this port's scan is %s, cursor %s",
    sb.printJson(shown), sb.printJson(n),
    sb.printJson(petports_asteriteCap()),
    self.asteriteEnabled and "ON" or "OFF",
    sb.printJson(self.asteriteCursor or -1))

  return n
end

-- Reads the config, clears the port state, and installs every message handler.
function init()
  sb.logInfo("PETPORT object build: %s", PETPORT_BUILD_STAMP)
  sb.logInfo("PETPORT work build: %s", PETPORTS_WORK_BUILD_STAMP)

  COVERAGE_SIZE = config.getParameter("petports_coverageSize", COVERAGE_SIZE)
  sb.logInfo("PETPORT coverage size: %s tiles", sb.printJson(COVERAGE_SIZE))

  self.asteriteCursor = nil
  self.asteriteSweepAt = nil
  self.asteriteSweepNew = 0
  self.asteriteSweepSeen = 0

  self.asteriteFullSaid = false

  asteriteLatch()

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

  message.setHandler("petports_fishSpawned", simpleHandler(function(fishId, fishType, rarity)
    self.fishId = fishId
    self.fishType = fishType

    self.fishRarity = rarity

    petports_fishPublish(stationUniqueId(), {
      id = fishId,
      type = fishType,
      rarity = rarity,
      expires = world.time() + FISHING_LURE_LIFETIME[2]
    })

    sb.logInfo("PETPORT %s has a fish: %s (%s, %s)",
      stationUniqueId(), sb.printJson(fishId), tostring(fishType),
      tostring(rarity or "unknown rarity"))
  end))

  message.setHandler("petports_fishGone", simpleHandler(function(fishId)
    if self.fishId == fishId then
      self.fishId = nil
      self.fishType = nil
      self.fishRarity = nil

      petports_fishClearOwner(stationUniqueId())

      sb.logInfo("PETPORT %s fish %s is gone", stationUniqueId(),
        sb.printJson(fishId))
    end
  end))

  message.setHandler("petports_status", simpleHandler(function(status, storage)
    if self.petData then
      self.petData.status = status or self.petData.status
      self.petData.storage = storage or self.petData.storage
      self.dirty = true
      trace("petStatus message -> storage", self.petData.storage)
    end
  end))

  message.setHandler("petports_headpat", simpleHandler(function()
    if self.petData == nil then return end

    metrics.add("headpats", 1)

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

    abandonTask("unit died at " .. sb.printJson(position))

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
    if socketedItem() == nil then return false end

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

    for _, channel in ipairs(RGB_CHANNELS) do
      local value = tonumber(payload[channel])

      if value ~= nil then
        value = math.floor(value)
        if value < RGB_MIN then value = RGB_MIN end
        if value > RGB_MAX then value = RGB_MAX end
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

  message.setHandler("petports_setMedic", simpleHandler(function(payload)
    if type(payload) ~= "table" then return false end
    if self.petData == nil then return false end

    local set = {}
    for _, class in ipairs(MEDIC_CLASSES) do
      set[class] = payload[class] ~= false
    end

    self.petData.medic = set

    self.dirty = true
    self.paneSignature = nil

    self.workTimer = 0

    sb.logInfo("PETPORT %s medic classes: %s", stationUniqueId(), sb.printJson(set))
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
      noteFailure(report.id, report.reason or "no detail")
    end

    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "deposit" and self.task.id == report.id then
      if self.task.only ~= nil then
        depositCargoOnly(self.task.target, self.task.only)
      else
        depositCargo(self.task.target)
      end
    end

    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "upcycle" and self.task.id == report.id then
      depositCargoToMachine(self.task.target, self.task.id)
    end

    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "withdraw" and self.task.id == report.id then
      withdrawSeed(self.task.target, self.task.seed, self.task.id,
        self.task.count)
    end

    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "fuelfetch" and self.task.id == report.id then
      feedFromCrate(self.task.target, self.task.treat, self.task.id,
        self.task.feedSlot)
    end

    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "drain" and self.task.id == report.id then
      withdrawMisfit(self.task.target, self.task.item, self.task.count,
        self.task.id, self.task.slot)
    end

    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "fuel" and self.task.id == report.id then
      withdrawMisfit(self.task.target, self.task.item, self.task.count,
        self.task.id, self.task.slot)
    end

    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "tidy" and self.task.id == report.id then
      withdrawMisfit(self.task.target, self.task.item, self.task.count,
        self.task.id, self.task.slot)
    end

    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "defrag" and self.task.id == report.id then
      withdrawMisfit(self.task.target, self.task.item, self.task.count,
        self.task.id, self.task.slot)
    end

    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "compact" and self.task.id == report.id then
      compactContainer(self.task.target)
    end

    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "sort" and self.task.id == report.id then
      sortContainer(self.task.target)
    end

    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "water" and self.task.id == report.id then
      local watered = tonumber(report.watered) or 0

      for _ = 1, watered do
        spendSeed(self.task.item)
      end

      metrics.add("watered", watered)

      sb.logInfo("PETPORT %s watering finished: %s tile(s), %s %s spent",
        stationUniqueId(), sb.printJson(watered), sb.printJson(watered),
        tostring(self.task.item))
    end

    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "medic" and self.task.id == report.id then
      local dosed = tonumber(report.dosed) or 0

      if dosed > 0 then
        spendMedkit()
        petports_healRecord(report.target or self.task.target, MEDIC_DURATION)
        metrics.add("dosed", dosed)

        sb.logInfo("PETPORT %s medic finished: patient %s dosed, one %s spent, "
          .. "next dose for them in %ss",
          stationUniqueId(), sb.printJson(report.target or self.task.target),
          tostring(self.task.item), sb.printJson(MEDIC_DURATION))
      else
        sb.logInfo("PETPORT %s medic returned without dosing: %s",
          stationUniqueId(), tostring(report.reason))
      end
    end

    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "replant" and self.task.id == report.id then
      spendSeed(self.task.seed)

      metrics.add("planted", 1)

      petports_replantClear(self.task.target, "replanted")
    end

    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "harvest" and self.task.id == report.id then
      metrics.add("harvested", 1)

      if not world.entityExists(self.task.target)
         and self.task.targetName ~= nil then
        petports_replantSet(self.task.position, self.task.targetName,
          stationUniqueId())
      end
    end

    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "animal" and self.task.id == report.id then
      metrics.add("livestock", 1)
    end

    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "trap" and self.task.id == report.id then
      metrics.add("traps", 1)
    end

    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "asterite" and self.task.id == report.id then
      metrics.add("asteriteDepositsMined", 1)
    end

    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "fish" and self.task.id == report.id then
      metrics.add("fished", 1)

      local tier = self.task.fishRarity
      if type(tier) == "string" and tier ~= "" then
        metrics.add("fished_" .. tier, 1)
      end
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

  stopResidency()

  petports_registryRemove(stationUniqueId())
end

-- Abandons the task, clears the fish entry and crosshairs, and saves the unit back into its item.
function uninit()
  abandonTask("petport unloading")

  petports_fishClearOwner(stationUniqueId())

  crosshairClear()

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
socketedItem = function()
  local item = world.containerItemAt(entity.id(), 0)
  if item == nil or item.name == nil then return nil end
  return item
end

-- Returns an item's stored pet seed.
local function itemSeed(item)
  if item == nil or item.parameters == nil then return nil end
  if item.parameters.petData == nil then return nil end
  return item.parameters.petData.seed
end

-- Returns the pet data merged from an item's config and its parameters, with the cargo normalised.
local function petDataFrom(item)
  local base = root.itemConfig(item)
  local data = {}
  if base and base.config and base.config.petData then
    util.mergeTable(data, copy(base.config.petData))
  end
  if item.parameters and item.parameters.petData then
    util.mergeTable(data, copy(item.parameters.petData))
  end
  if data.monsterType == nil then return nil end

  cargoTrace("petDataFrom: off item", data.cargo)

  data.cargo = normaliseCargo(data.cargo)
  cargoTrace("petDataFrom: normalised", data.cargo)

  trace("read from item", data)
  return data
end

-- Spawns the unit at the port's spawn offset with its saved status, storage and name.
function spawnPet()
  cargoTrace("spawnPet: entry", self.petData and self.petData.cargo)
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

  trace("spawning with initialStorage", parameters.initialStorage)

  self.petId = world.spawnMonster(self.petData.monsterType, spawnPosition, parameters)
  if self.petId then
    self.spawning = true
    self.statusTimer = STATUS_INTERVAL

    self.spawnedPetId = self.petId

    world.callScriptedEntity(self.petId, "setAnchor", entity.id())
  else
    trace("spawnMonster returned nil for type", self.petData.monsterType)
  end
end

-- Takes the unit's state back into the pet data, despawns it, and writes it into the item.
function saveAndDespawn(skipWrite, instant)
  if self.petId and world.entityExists(self.petId) then
    local ok, state = pcall(world.callScriptedEntity, self.petId, "petports_store")
    trace("petStore returned", ok and state or nil)

    cargoTrace("saveAndDespawn: before store merge", self.petData and self.petData.cargo)

    if ok and state and self.petData then
      self.petData.status = state.status or self.petData.status
      self.petData.storage = state.storage or self.petData.storage
    end

    cargoTrace("saveAndDespawn: after store merge", self.petData and self.petData.cargo)

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
local function flushCargo()
  self.dirty = true
  writeBackToItem()
  self.writeTimer = WRITE_INTERVAL

  self.workTimer = 0
end


-- Returns a beacon item's behavior, or nil when it is switched off.
local function beaconBehaviorOf(item)
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
local function objectHasTag(id, tag)
  local ok, tags = pcall(world.getObjectParameter, id, "itemTags")
  if not ok or type(tags) ~= "table" then return false end

  for _, candidate in ipairs(tags) do
    if candidate == tag then return true end
  end

  return false
end

-- Returns an object's machine kind, enabled and feeder flags and rules, or nil when it is not a machine.
local function machineAt(id)
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
local function scanContainers()
  local rects = self.networkRects
  if rects == nil or #rects == 0 then rects = { coverageRect() } end

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

        local machine = machineAt(id)
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

            local ignoresBeacons = objectHasTag(id, IGNORE_BEACONS_TAG)

            if ignoresBeacons then
              local offender = nil

              for _, slot in ipairs(slots) do
                if beaconBehaviorOf(items[slot]) ~= nil then
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
              local behavior = beaconBehaviorOf(item)

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
local function reportCensus(census, censusStacks, machines)
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
local function reportSpread(spread)
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
local function crateHasRoom(id, name)
  if world.containerItemsCanFit == nil then return false end

  local ok, fits = pcall(world.containerItemsCanFit, id, { name = name, count = 1 })
  if not ok or type(fits) ~= "number" then return false end

  return fits > 0
end

-- Returns the crate an item belongs in, ranked by filter narrowness, aging, how much it already holds and its size.
local function defragDestination(name, where, crates, perishable)
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

  if crateHasRoom(anchor.crate.id, name) then
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
    if crateHasRoom(entry.crate.id, name) then
      return entry.crate, "nearest the full one", entry.held, entry.breadth
    end
  end

  return nil, string.format("all %s crates that accept it are full",
    tostring(#ranked))
end

-- Returns the crates an item should be moved out of, smallest holding first, and how many refuse it outright.
local function defragSources(name, where, destinationId, byId)
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
local function defragOrder(names)
  table.sort(names, function(a, b)
    if a.slots ~= b.slots then return a.slots > b.slots end
    if a.crates ~= b.crates then return a.crates > b.crates end
    return a.name < b.name
  end)

  return names
end

-- Returns whether a crate ages an item better than its current one, cached per beacon scan.
local function defragBetterTempExists(name, current, deposits, perishable)
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
local function defragBetterHomeExists(name, closest, deposits)
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
local function defragCandidates(spread, crates)
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
      misplaced = defragBetterHomeExists(name, closest, deposits)
    end

    local chilled = false

    if chill and coldest ~= nil then
      local perishable = petports_itemPerishable(name)
      local current = perishable and coldest or warmest

      if perishable and current > 0 then
        chilled = defragBetterTempExists(name, current, deposits, true)
      elseif not perishable and current < 1.0 then
        chilled = defragBetterTempExists(name, current, deposits, false)
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

  return defragOrder(names), deposits, byId
end

DEFRAG_PLAN_CAP = 16

-- Logs the destination and sources planned for each defrag candidate when the plan changes.
local function reportDefragPlan(spread, crates)
  if not DEFRAG_DEBUG then return end
  if not petportDefrag() then return end
  if not petportParticipates("defrag") then return end

  local names, deposits, byId = defragCandidates(spread, crates)

  local lines = {}
  local signature = {}

  for index, entry in ipairs(names) do
    if index > DEFRAG_PLAN_CAP then break end

    local where = spread[entry.name]
    local target, why, held, breadth = defragDestination(entry.name, where, deposits)

    if target == nil then
      table.insert(signature, entry.name .. ">none:" .. tostring(why))

      table.insert(lines, string.format("%s: NO TARGET (%s)",
        tostring(entry.name), tostring(why)))
    else
      local sources, misfiled = defragSources(entry.name, where, target.id, byId)

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
local function refreshBeacons(dt)
  self.beaconTimer = (self.beaconTimer or 0) - dt
  if self.beaconTimer > 0 then return end
  self.beaconTimer = BEACON_INTERVAL

  local found, containers, census, censusStacks, machines, spread =
    scanContainers()

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

  reportCensus(census, censusStacks, machines)
  reportSpread(spread)
  reportDefragPlan(spread, found)
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

-- Adds an item to the unit's cargo, taking the first medkit into its own slot, and writes the item back.
function receiveCargo(item)
  if item == nil or item.name == nil then return end

  if self.petData == nil then
    sb.logError("PETPORT %s received cargo with no petData -- ITEM LOST: %s",
      stationUniqueId(), sb.printJson(item))
    return
  end

  cargoTrace("receiveCargo: before", self.petData.cargo)

  self.petData.cargo = self.petData.cargo or {}

  if item.name == MEDIC_ITEM and self.petData.medkit == nil
     and petportMedic() then
    local whole = item.count or 1

    self.petData.medkit = {
      name = item.name,
      count = 1,
      parameters = copy(item.parameters)
    }

    sb.logInfo("PETPORT %s medkit loaded: 1 %s held for the next patient, "
      .. "%s of %s going to cargo",
      stationUniqueId(), tostring(item.name), sb.printJson(whole - 1),
      sb.printJson(whole))

    self.paneSignature = nil

    if whole <= 1 then
      flushCargo()
      return
    end

    item = {
      name = item.name,
      count = whole - 1,
      parameters = item.parameters
    }
  end

  for _, held in ipairs(self.petData.cargo) do
    if held.name == item.name and compare(held.parameters, item.parameters) then
      held.count = (held.count or 1) + (item.count or 1)

      sb.logInfo("PETPORT %s cargo +%s %s (stack now %s, %s stack(s) held)",
        stationUniqueId(), sb.printJson(item.count or 1), tostring(item.name),
        sb.printJson(held.count), sb.printJson(#self.petData.cargo))

      flushCargo()
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

  flushCargo()
end

-- Serialises the pet data into the socketed item.
function writeBackToItem()
  if self.petData == nil then
    cargoTrace("writeBack: REFUSED, no petData", nil)
    return
  end

  local item = socketedItem()
  if item == nil then
    cargoTrace("writeBack: REFUSED, nothing socketed", self.petData.cargo)
    return
  end

  self.petData.cargo = normaliseCargo(self.petData.cargo)
  cargoTrace("writeBack: serialising", self.petData.cargo)

  item.parameters = item.parameters or {}
  item.parameters.petData = self.petData

  trace("writing back to item", self.petData)

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

local bodyKindCache = {}

-- Returns whether the unit's body is organic or robotic, cached.
local function paneBodyKind()
  local monsterType = self.petData and self.petData.monsterType
  if monsterType == nil then return nil end

  local key = tostring(monsterType)
  if bodyKindCache[key] ~= nil then return bodyKindCache[key] end

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

  bodyKindCache[key] = kind
  return kind
end

PETPORTS_FUEL_LOW = 0.25

PETPORTS_FUEL_PLAIN     = 60
PETPORTS_FUEL_PREFERRED = 120

-- Returns the unit's stored fuel.
local function petportFuelValue()
  local resources = self.petData and self.petData.storage and self.petData.storage.petResources
  if type(resources) ~= "table" then return nil end
  return tonumber(resources.petports_fuel)
end

-- Returns how much fuel the unit has room for.
function petportFuelHeadroom()
  local fuel = petportFuelValue()
  if fuel == nil then return nil end
  return math.max(0, PANE_FUEL_MAX - fuel)
end

-- Returns whether the unit's fuel is below the low mark.
function petportFuelWanted()
  local fuel = petportFuelValue()
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
local function paneFuelBlips()
  local resources = self.petData and self.petData.storage and self.petData.storage.petResources
  if type(resources) ~= "table" then return PANE_FUEL_BLIPS end

  local fuel = tonumber(resources.petports_fuel)

  if fuel == nil then return PANE_FUEL_BLIPS end

  local blips = math.floor((fuel / PANE_FUEL_MAX) * PANE_FUEL_BLIPS + 0.5)
  return math.max(0, math.min(PANE_FUEL_BLIPS, blips))
end

-- Returns the cargo for the pane, each stack capped at its own max size.
local function paneCargo()
  if self.petData == nil or self.petData.cargo == nil then return nil end

  local out = {}
  for _, stack in ipairs(self.petData.cargo) do
    if stack.name then
      local cap = stackSizeOf(stack.name) or 1000
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
local function paneDiag(severity, short, full)
  local capped = short
  if #capped > DIAG_MAX_CHARS then
    capped = string.sub(capped, 1, DIAG_MAX_CHARS - 1) .. "..."
  end
  return { severity = severity, short = capped, full = full or short }
end

DIAG_FRESH = 30.0

-- Returns whether a time is inside the diagnostic freshness window.
local function fresh(at)
  if at == nil then return false end
  return (world.time() - at) < DIAG_FRESH
end

-- Returns the diagnostics the pane shows, newest and most severe first.
local function paneDiagnostics()
  local out = {}

  if petportOblivious() then
    table.insert(out, paneDiag("info", "Oblivious",
      "An Oblivious Module is socketed, so this unit takes no dispatched work. "
      .. "It will still come home and put down anything it is already carrying. "
      .. "Remove the module to put it back on duty."))
  end

  if self.envUnsuitable ~= nil then
    table.insert(out, paneDiag("error", "Wrong environment",
      self.envRetired
        and ("This unit's chassis cannot survive the liquid or air at its port. "
          .. "It has been retired and will return on its own once the port drains "
          .. "or floods back.")
        or ("This unit's chassis cannot survive the liquid or air at its port, so "
          .. "the port has not deployed it. It will deploy on its own once the "
          .. "port drains or floods back.")))
  end

  if (self.unreachableFailures or 0) > 0 and fresh(self.unreachableAt) then
    table.insert(out, paneDiag("warn",
      string.format("%d unreachable", self.unreachableFailures),
      string.format("%d job(s) were abandoned because no route could be found. "
        .. "Usually terrain: a gap too wide, a shaft too narrow, or a door the "
        .. "unit cannot open.", self.unreachableFailures)))
  end

  if (self.recallFailures or 0) > 0 and fresh(self.recallAt) then
    table.insert(out, paneDiag("warn",
      string.format("%d recalls failed", self.recallFailures),
      string.format("%d attempt(s) to walk home failed. The unit will be "
        .. "re-homed to its port if this keeps happening.", self.recallFailures)))
  end

  while #out > PANE_DIAG_LIMIT do table.remove(out) end
  if #out == 0 then return nil end
  return out
end

-- Returns the socketed item's short description.
local function paneSpecies()
  local item = socketedItem()
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
  local item = socketedItem()
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
local function moduleFieldOf(item, field)
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
local function moduleFieldUnion(field)
  if self.petData == nil or type(self.petData.modules) ~= "table" then return {} end

  local seen = {}
  local out = {}

  for _, record in ipairs(self.petData.modules) do
    if type(record) == "table" and record.item ~= nil then
      for _, entry in ipairs(moduleFieldOf(record.item, field)) do
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
  return moduleFieldUnion("petports_moduleEffects")
end

-- Returns the liquids the socketed modules permit.
function petportModuleLiquids()
  return moduleFieldUnion("petports_moduleLiquids")
end

-- Returns the flags the socketed modules carry.
function petportModuleFlags()
  return moduleFieldUnion("petports_moduleFlags")
end

OBLIVIOUS_FLAG = "oblivious"

MEDIC_FLAG = "medic"

DEFRAG_FLAG = "defrag"

CAMOUFLAGE_FLAG = "camouflage"

HYDRATOR_FLAG = "hydrator"

ASTERITE_FLAG = "asterite"

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

RGB_CHANNELS = { "r", "g", "b" }
RGB_MIN = 0
RGB_MAX = 255
RGB_DEFAULT = 140
MEDIC_ITEM = "medicalgoods"

FISHING_FLAG = "fishing"

FISHING_LURE = "petports_fishinglure"

FISHING_LURE_LIFETIME = { 120, 300 }

FISH_DWELL = 10

FISHING_FISH_PARAMETERS = {
  hookDistance = 0,
  approachTimeRange = { 45, 75 },
  lurkTimeRange = { 45, 75 }
}

FISHING_SPAWNER_CONFIG = "/scripts/fishing/fishingspawner.config"

-- Returns whether a fishing module is socketed.
function petportFishing()
  for _, flag in ipairs(petportModuleFlags()) do
    if flag == FISHING_FLAG then return true end
  end
  return false
end


MEDIC_DURATION = 120
MEDIC_EFFECT = "redstim"
MEDIC_PROJECTILE = "petports_medicburst"

MEDIC_REACH = 6

-- Returns whether an oblivious module is socketed.
function petportOblivious()
  for _, flag in ipairs(petportModuleFlags()) do
    if flag == OBLIVIOUS_FLAG then return true end
  end
  return false
end

-- Returns whether a medic module is socketed.
function petportMedic()
  for _, flag in ipairs(petportModuleFlags()) do
    if flag == MEDIC_FLAG then return true end
  end
  return false
end

-- Returns the held medkit, or nil.
function petportMedkit()
  if self.petData == nil then return nil end

  local held = self.petData.medkit
  if type(held) ~= "table" or held.name == nil then return nil end

  return held
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

-- Returns whether an asterite module is socketed.
function petportAsterite()
  for _, flag in ipairs(petportModuleFlags()) do
    if flag == ASTERITE_FLAG then return true end
  end
  return false
end

-- Returns how much water the unit carries, raised by a hydrator.
function petportWaterCarry()
  if petportHydrator() then return WATER_CARRY_HYDRATED end
  return WATER_CARRY
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


-- Returns the unit's stored light colour, defaulting each channel.
function petportLightColor()
  local stored = (self.petData and self.petData.light) or {}
  local out = {}

  for _, channel in ipairs(RGB_CHANNELS) do
    local value = tonumber(stored[channel])
    out[channel] = value ~= nil and value or RGB_DEFAULT
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

  local signature = string.format("%s|%s|%s|%s",
    tostring(self.petId), tostring(color.r), tostring(color.g), tostring(color.b))

  if signature == self.pushedUnitLight then return end
  self.pushedUnitLight = signature

  sb.logInfo("PETPORT %s pushing light to unit %s: %s", stationUniqueId(),
    sb.printJson(self.petId), sb.printJson(color))

  world.callScriptedEntity(self.petId, "petports_setLightColor",
    color.r, color.g, color.b)
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
local function bubbleSpec()

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

  local tokens = bubbleSpec()

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
    name = paneSpecies() or "Utility Unit"
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
local function paneSerial()
  local seed = self.petData and self.petData.seed
  if seed == nil then return nil end
  return string.format("%06d", math.floor(tonumber(seed) or 0) % 1000000)
end

-- Returns the stat counters for the pane, with the per-tier and per-flavor rows gathered up.
metrics.paneStats = function()
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

  local socketed = portProf("pane.socketed", socketedItem) ~= nil
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
      petName = self.petData.petName or paneSpecies() or "Utility Unit",

      petNameRaw = self.petData.petName,
      species = paneSpecies(),
      serial = paneSerial(),
      fuelBlips = paneFuelBlips(),

      bodyKind = paneBodyKind(),
      cargo = paneCargo(),
      task = self.task and self.task.type or "idle",
      diagnostics = paneDiagnostics(),
      moduleSlots = petportModuleSlots(),


      moduleFlags = petportModuleFlags(),

      toggles = (self.petData and self.petData.toggles) or nil,
      medic = (self.petData and self.petData.medic) or nil,
      farming = (self.petData and self.petData.farming) or nil,

      medicReady = petportMedkit() ~= nil,

      light = petportLightColor(),
      modules = self.petData.modules,

      moduleToken = self.moduleToken,

      petId = (self.petId ~= nil and world.entityExists(self.petId)) and self.petId or nil,

      flavor = petportUnitFlavor(),
      stats = metrics.paneStats(),

      network = nil
    }
  end

  local ok, signature = pcall(sb.printJson, state)
  if ok and signature == self.paneSignature then return end
  if ok then self.paneSignature = signature end

  local okJ, blob = portProf("pane.json", pcall, sb.printJson, state)

  if okJ and blob == self.paneLastBlob then return end
  if okJ then self.paneLastBlob = blob end

  portProf("pane.write", object.setConfigParameter, PANE_STATE_KEY, state)
end


-- Returns the socketed chassis's habitat capabilities.
local function unitCapabilities()
  if self.petData == nil or self.petData.monsterType == nil then return nil end

  return petports_habitatCapabilitiesForType(self.petData.monsterType,
    petports_habitatPermittedSet(petportModuleLiquids()))
end

-- Returns whether the port's own spaces are submerged, dry, and which liquids they hold.
local function portMedia()
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
local function environmentCheck()
  if self.petData == nil or self.petData.monsterType == nil then
    self.envUnsuitable = nil
    return
  end

  local live = self.petId ~= nil and world.entityExists(self.petId)
  local wet, dry, liquids = portMedia()
  local verdict = nil

  if live then
    local called, answer = pcall(world.callScriptedEntity, self.petId,
      "petports_canInhabit", wet, dry, liquids)

    if not called or type(answer) ~= "table" then return end
    verdict = answer
  else
    verdict = petports_habitatVerdict(unitCapabilities(), wet, dry, liquids)

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
local function dispatchable(work)
  if work == nil then return nil end

  if RECT_CHECKED_TYPES[work.type]
     and not petports_rectContains(coverageRect(), work.position) then

    local note = string.format("%s type %s at %s outside own rect %s",
      tostring(work.id), tostring(work.type), sb.printJson(work.position),
      sb.printJson(coverageRect()))

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
local function petUniqueId()
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
local function standingPointNear(position, radius, mediumVerified)
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
local function homePointNear()
  if self.petId == nil or not world.entityExists(self.petId) then return nil end

  local ok, resolved = pcall(world.callScriptedEntity, self.petId,
    "petports_homePointNear", entity.position())

  if ok and resolved ~= nil then return resolved end

  sb.logInfo("PETPORT %s unit could not resolve a home point at %s (called %s)",
    stationUniqueId(), sb.printJson(entity.position()), tostring(ok))
  return nil
end

-- Returns whether the chassis can work at a target, with the refusal reason.
local function targetSuits(position, entityId)
  local caps = unitCapabilities()
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
local function targetRefused(label, reason)
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
local function targetEligible(label, position, entityId)
  local ok, reason = targetSuits(position, entityId)
  if ok then return true end

  targetRefused(label, reason)
  return false
end

-- Asks the unit for a standable point beside a target's object bounds, or near its position.
local function standingPointForTarget(position, entityId, radius, mediumVerified)
  local bounds = petports_habitatObjectBounds(entityId)

  if bounds == nil then
    return standingPointNear(position, radius, mediumVerified)
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
local function servicePointNearUncached(label, entityId, position, radius)
  local suits, why = targetSuits(position, entityId)

  if not suits then
    targetRefused(label, why)
    return nil, why
  end

  local bounds = petports_habitatObjectBounds(entityId)
  local stand = standingPointForTarget(position, entityId, radius or 4, true)

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
local function servicePointNear(label, entityId, position, radius)
  self.servicePoints = self.servicePoints or {}

  local key = tostring(entityId) .. "|" .. tostring(radius or 4) .. "|"
    .. tostring(self.petData and self.petData.seed)
  local held = self.servicePoints[key]
  local now = world.time()

  if held ~= nil then
    local ttl = held.stand ~= nil and SERVICE_POINT_TTL or SERVICE_POINT_RETRY
    if (now - held.at) < ttl then return held.stand, held.why end
  end

  local stand, why = servicePointNearUncached(label, entityId, position, radius)
  self.servicePoints[key] = { at = now, stand = stand, why = why }

  return stand, why
end

-- Returns a random floor tile inside a rect, or nil.
local function findStandingPoint(rect)
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

-- Returns a task that walks the unit to a floor tile in this port's rect.
local function diagnosticWork()
  local rect = coverageRect()
  local position = findStandingPoint(rect)

  if position == nil then
    return nil, "no standing point in rect"
  end

  return {
    id = "diag:" .. stationUniqueId(),
    type = "diag",
    port = stationUniqueId(),
    position = position,
    dwell = DIAG_DWELL
  }
end

DEFER_GRACE = 12.0

-- Returns whether an idle unit elsewhere in the network is nearer a position.
local function anotherUnitIsCloser(position, ourDistance)
  for _, entry in ipairs(petports_networkMembers(stationUniqueId())) do
    if entry.unitPosition ~= nil and not entry.busy and entry.hasUnit ~= false then
      if world.magnitude(entry.unitPosition, position) < ourDistance then
        return true
      end
    end
  end
  return false
end

-- Returns whether a drop would stack onto cargo the unit already carries.
local function dropMergesWithCargo(dropId)
  if self.petData == nil or self.petData.cargo == nil then return false end

  local ok, descriptor = pcall(world.itemDropItem, dropId)

  if not ok or type(descriptor) ~= "table" or type(descriptor.name) ~= "string" then
    return false
  end

  for _, stack in ipairs(self.petData.cargo) do
    if stack.name == descriptor.name then
      local limit = stackSizeOf(stack.name)
      local total = (stack.count or 0) + (descriptor.count or 1)

      if total <= limit then return true end

      sb.logInfo("PETPORT %s drop %s would overflow %s: %s held + %s dropped > %s",
        stationUniqueId(), sb.printJson(dropId), tostring(stack.name),
        sb.printJson(stack.count or 0), sb.printJson(descriptor.count or 1),
        sb.printJson(limit))

      return false
    end
  end

  return false
end

-- Returns a task to fetch the nearest unclaimed drop in the network, or nil with a tally of why each was passed over.
local function collectionWork(mergeOnly)
  local rects = self.networkRects
  if rects == nil or #rects == 0 then rects = { coverageRect() } end

  local drops = {}
  local seen = {}
  for _, area in ipairs(rects) do
    local found = world.entityQuery({area[1], area[2]}, {area[3], area[4]}, {
      includedTypes = { "itemDrop" }
    })
    for _, dropId in ipairs(found or {}) do
      if not seen[dropId] then
        seen[dropId] = true
        table.insert(drops, dropId)
      end
    end
  end

  local rect = coverageRect()

  if drops == nil or #drops == 0 then
    local wide = { rect[1] - COVERAGE_SIZE, rect[2] - COVERAGE_SIZE,
                   rect[3] + COVERAGE_SIZE, rect[4] + COVERAGE_SIZE }
    local nearby = world.entityQuery({wide[1], wide[2]}, {wide[3], wide[4]}, {
      includedTypes = { "itemDrop" }
    })

    if nearby ~= nil and #nearby > 0 then
      return nil, string.format(
        "no drops in rect %s, but %s just outside (nearest %s)",
        sb.printJson(rect), #nearby, sb.printJson(world.entityPosition(nearby[1])))
    end

    return nil, "no drops in network coverage (own rect " .. sb.printJson(rect) .. ")"
  end

  sb.logInfo("PETPORT %s scan: %s drops in %s rects",
    stationUniqueId(), sb.printJson(#drops), sb.printJson(#rects))

  local origin = entity.position()
  local best, bestDistance = nil, nil

  local rejected = { claimed = 0, backedOff = 0, deferred = 0, gone = 0,
    unmergeable = 0, medium = 0 }

  self.deferredSince = self.deferredSince or {}
  local stillDeferred = {}

  for _, dropId in ipairs(drops) do
    local workId = "drop:" .. dropId
    local claim = petports_claimGet(workId)

    local failure = self.workFailures[workId]
    local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

    local free = not backedOff and ((claim == nil)
      or claim.owner == stationUniqueId()
      or (claim.expires or 0) <= world.time())

    if backedOff then
      sb.logInfo("PETPORT %s drop %s SKIPPED: backed off until %s (now %s, failures %s)",
        stationUniqueId(), sb.printJson(dropId),
        sb.printJson(failure["until"]), sb.printJson(world.time()),
        sb.printJson(failure.count))
      rejected.backedOff = rejected.backedOff + 1
    elseif not free then
      sb.logInfo("PETPORT %s drop %s SKIPPED: claimed by %s until %s",
        stationUniqueId(), sb.printJson(dropId),
        tostring(claim.owner), sb.printJson(claim.expires))
      rejected.claimed = rejected.claimed + 1
    elseif not world.entityExists(dropId) then
      sb.logInfo("PETPORT %s drop %s SKIPPED: entity gone",
        stationUniqueId(), sb.printJson(dropId))
      rejected.gone = rejected.gone + 1
    elseif mergeOnly and not dropMergesWithCargo(dropId) then
      rejected.unmergeable = (rejected.unmergeable or 0) + 1
    else
      local position = world.entityPosition(dropId)
      if position == nil then
        rejected.gone = rejected.gone + 1

      elseif not targetEligible("drop " .. tostring(dropId), position, dropId) then
        rejected.medium = rejected.medium + 1
      else
        local from = origin
        if self.petId ~= nil and world.entityExists(self.petId) then
          from = world.entityPosition(self.petId)
        end

        local distance = world.magnitude(from, position)

        local defer = anotherUnitIsCloser(position, distance)
        if defer then
          local since = self.deferredSince[workId] or world.time()
          stillDeferred[workId] = since

          if world.time() - since >= DEFER_GRACE then
            sb.logInfo("PETPORT %s taking %s anyway: deferred %ss with no taker",
              stationUniqueId(), workId,
              sb.printJson(math.floor(world.time() - since)))
            defer = false
          end
        end

        if defer then
          sb.logInfo("PETPORT %s drop %s SKIPPED: deferred to a closer unit (ours %s away)",
            stationUniqueId(), sb.printJson(dropId), sb.printJson(distance))
          rejected.deferred = rejected.deferred + 1
        elseif bestDistance == nil or distance < bestDistance then
          sb.logInfo("PETPORT %s drop %s TAKEABLE at %s, %s away -- new best",
            stationUniqueId(), sb.printJson(dropId),
            sb.printJson(position), sb.printJson(distance))
          best, bestDistance = dropId, distance
        else
          sb.logInfo("PETPORT %s drop %s takeable but further (%s vs best %s)",
            stationUniqueId(), sb.printJson(dropId),
            sb.printJson(distance), sb.printJson(bestDistance))
        end
      end
    end
  end

  self.deferredSince = stillDeferred

  if best == nil then
    return nil, string.format(
      "%s drops in rect, none takeable: %s claimed, %s backed off, "
      .. "%s deferred to a closer unit, %s gone, %s in a medium this chassis "
      .. "cannot work in%s",
      #drops, rejected.claimed, rejected.backedOff,
      rejected.deferred, rejected.gone, rejected.medium,

      mergeOnly and string.format(", %s that would not merge with the cargo",
        rejected.unmergeable) or "")
  end

  return {
    id = "drop:" .. best,
    mediumVerified = true,
    type = "collect",
    port = stationUniqueId(),
    target = best,
    position = world.entityPosition(best)
  }
end

-- Saves and despawns the unit, and clears the recall and unreachable counts.
local function rehomeUnit(reason)
  sb.logInfo("PETPORT %s re-homing unit: %s", stationUniqueId(), reason)

  saveAndDespawn()
  self.recallFailures = 0
  self.unreachableFailures = 0
  self.spawnTimer = 0
end


MEDIC_CLASSES = { "player", "crew", "npc", "podpet", "animal", "unit" }

-- Returns which medic class an entity falls into, or nil when it is not friendly.
local function medicClassOf(id)
  local ok, kind = pcall(world.monsterType, id)
  if not ok then kind = nil end

  if petports_isUnitType(kind) then return "unit" end

  local team = world.entityDamageTeam(id)
  if team == nil or tostring(team.type) ~= "friendly" then
    return nil, team and tostring(team.type) or "no team"
  end

  local entityKind = tostring(world.entityType(id))
  if entityKind == "player" then return "player" end

  if entityKind == "npc" then
    if team.team == 0 then return "crew" end
    return "npc"
  end

  if team.team == 0 then return "podpet" end
  return "animal"
end

-- Returns whether a medic class is turned on.
function petportMedicHeals(class)
  if self.petData == nil then return false end

  local settings = self.petData.medic
  if type(settings) ~= "table" then return true end
  return settings[class] ~= false
end

-- Returns the hurt entities in the network the medic settings allow, most hurt first.
local function medicPatients()
  local rects = self.networkRects
  if rects == nil or #rects == 0 then rects = { coverageRect() } end

  local candidates = {}
  local seen = {}

  for _, area in ipairs(rects) do
    local found = world.entityQuery({area[1], area[2]}, {area[3], area[4]},
      { includedTypes = { "npc", "player", "monster" } })

    for _, id in ipairs(found or {}) do
      if not seen[id] then
        seen[id] = true
        table.insert(candidates, id)
      end
    end
  end

  local out = {}

  for _, id in ipairs(candidates) do
    local class = medicClassOf(id)

    if class ~= nil and petportMedicHeals(class) then
      local health = world.entityHealth(id)

      if type(health) == "table" and health[2] ~= nil and health[2] > 0
         and health[1] < health[2] then

        if petports_healCooldownRemaining(id) <= 0 then
          table.insert(out, {
            id = id,
            class = class,
            ratio = health[1] / health[2],
            position = world.entityPosition(id)
          })
        end
      end
    end
  end

  table.sort(out, function(a, b) return a.ratio < b.ratio end)
  return out
end

-- Counts the ticks the unit spends outside its medium and re-homes it once the strikes run out.
local function mediumCheck()
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
    rehomeUnit("outside its own medium at "
      .. sb.printJson(answer.position) .. " (reads " .. tostring(answer.medium)
      .. ") for " .. tostring(ENVIRONMENT_INTERVAL * limit) .. "s")
  end
end

-- Returns the rects fishing may use.
local function fishingRects()
  local rects = self.networkRects
  if rects == nil or #rects == 0 then rects = { coverageRect() } end
  return rects
end

-- Returns a random deep, clear water point inside the fishing rects below a ceiling, or nil.
local function submergedSpot(cfg, ceiling)
  local rects = fishingRects()
  local threshold = cfg.liquidThreshold or 0.9

  for _ = 1, 24 do
    local rect = rects[math.random(#rects)]

    local top = rect[4]
    if ceiling ~= nil then top = math.min(top, ceiling) end
    if top >= rect[2] then
      local x = math.floor(rect[1] + math.random() * (rect[3] - rect[1])) + 0.5
      local y = math.floor(rect[2] + math.random() * (top - rect[2])) + 0.5
      local here = { x, y }

      local liquid = world.liquidAt(here)
      if liquid and liquid[2] >= threshold then
        local box = { here[1] + cfg.checkRegion[1], here[2] + cfg.checkRegion[2],
                      here[1] + cfg.checkRegion[3], here[2] + cfg.checkRegion[4] }

        if not world.rectCollision(box) then
          local fill = world.liquidAt(box)
          if fill and fill[2] >= threshold then return here end
        end
      end
    end
  end

  return nil
end

-- Returns a lure spot, preferring the vanilla depth band, with the reason when there is none.
local function fishingSpot()
  local ok, cfg = pcall(root.assetJson, FISHING_SPAWNER_CONFIG)
  if not ok or type(cfg) ~= "table" or type(cfg.pools) ~= "table"
     or type(cfg.checkRegion) ~= "table" then
    return nil, "vanilla's fishing spawner config is unreadable"
  end

  if cfg.pools[world.type()] ~= nil then
    local ceiling = world.oceanLevel(entity.position()) - (cfg.minDepth or 8)
    local spot = submergedSpot(cfg, ceiling)
    if spot ~= nil then return spot, nil, "vanilla depth band" end
  end

  local spot = submergedSpot(cfg, nil)
  if spot ~= nil then return spot, nil, "any submerged water, pending a zone" end

  return nil, "no clear submerged spot anywhere in network coverage"
end

-- Keeps one lure alive while fishing is wanted, and clears the lure and fish entry when it is not.
local function fishingCheck()
  local wanted = petportEnabled() and self.petId ~= nil
    and world.entityExists(self.petId) and petportFishing()

  if self.lureId ~= nil and not world.entityExists(self.lureId) then
    self.lureId = nil
  end

  if not wanted then
    if self.lureId ~= nil then
      pcall(world.callScriptedEntity, self.lureId, "kill")
      sb.logInfo("PETPORT %s fishing lure %s dismissed -- no unit with a "
        .. "fishing module", stationUniqueId(), sb.printJson(self.lureId))
      self.lureId = nil
    end

    self.fishId = nil
    self.fishType = nil
    self.fishRarity = nil

    petports_fishClearOwner(stationUniqueId())
    return
  end

  if self.lureId ~= nil then return end

  local spot, why, tier = fishingSpot()
  if spot == nil then
    if self.fishingRefusal ~= why then
      self.fishingRefusal = why
      sb.logInfo("PETPORT %s cannot place a fishing lure: %s",
        stationUniqueId(), tostring(why))
    end
    return
  end
  self.fishingRefusal = nil

  local rects = fishingRects()

  local lifetime = util.randomInRange(FISHING_LURE_LIFETIME)

  local parameters = {
    timeToLive = lifetime,
    petports_coverage = rects,
    petports_fishParameters = FISHING_FISH_PARAMETERS
  }

  local ok, result = pcall(world.spawnProjectile,
    FISHING_LURE, spot, entity.id(), { 0, 0 }, false, parameters)

  if ok and result ~= nil then
    self.lureId = result
    sb.logInfo("PETPORT %s fishing lure %s placed at %s for %ss -- %s, across "
      .. "%s network rect(s)",
      stationUniqueId(), sb.printJson(result), sb.printJson(spot),
      sb.printJson(lifetime), tostring(tier),
      sb.printJson(#rects))
  else
    sb.logInfo("PETPORT %s failed to place a fishing lure at %s: %s",
      stationUniqueId(), sb.printJson(spot),
      ok and "spawnProjectile returned nil" or tostring(result))
  end
end

-- Returns whether this chassis can reach a fish at all, with the reason when it cannot.
local function petportCanFish()
  if not petportFishing() then return false, "no fishing module" end

  local monsterType = self.petData and self.petData.monsterType
  if monsterType == nil then return false, "no unit" end

  local caps = petports_habitatCapabilitiesForType(monsterType,
    petports_habitatPermittedSet(petportModuleLiquids()))

  if caps == nil then
    return false, "chassis capabilities unreadable"
  end

  if caps.freeMover then
    if caps.swim then return true end
    return false, string.format(
      "%s is a free mover that cannot swim, so it can never reach a fish",
      tostring(monsterType))
  end

  if caps.avoidLiquid == false then return true end

  return false, string.format(
    "%s is a walker that avoids liquid, so it can never reach a fish",
    tostring(monsterType))
end

-- Returns a task to catch the nearest published fish the unit can reach, or nil with a tally of why each was passed over.
local function fishWork()
  local canFish, why = petportCanFish()
  if not canFish then return nil, why end

  local cargo = self.petData and self.petData.cargo
  if cargo ~= nil and #cargo > 0 then
    return nil, string.format(
      "the unit is carrying %s stack(s) and should deposit before fishing",
      sb.printJson(#cargo))
  end

  local published = petports_fishAll()
  local now = world.time()

  local from = entity.position()
  if self.petId ~= nil and world.entityExists(self.petId) then
    from = world.entityPosition(self.petId) or from
  end

  -- Returns whether a position lies in one of the fishing rects.
  local function reachableWater(position)
    for _, area in ipairs(fishingRects()) do
      if petports_rectContains(area, position) then return true end
    end
    return false
  end

  local best, bestDistance = nil, nil
  local offered = 0
  local rejected = { expired = 0, gone = 0, claimed = 0, backedOff = 0,
    outside = 0 }

  for _, memberId in ipairs(petports_networkMemberIds(stationUniqueId())) do
    local entry = published[memberId]

    if entry ~= nil and entry.id ~= nil then
      offered = offered + 1

      local workId = "fish:" .. entry.id
      local claim = petports_claimGet(workId)
      local failure = self.workFailures[workId]

      local free = (claim == nil)
        or claim.owner == stationUniqueId()
        or (claim.expires or 0) <= now

      if (entry.expires or 0) <= now then
        rejected.expired = rejected.expired + 1
      elseif not world.entityExists(entry.id) then
        rejected.gone = rejected.gone + 1
      elseif failure ~= nil and (failure["until"] or 0) > now then
        rejected.backedOff = rejected.backedOff + 1
      elseif not free then
        rejected.claimed = rejected.claimed + 1
      else
        local position = world.entityPosition(entry.id)

        if position == nil then
          rejected.gone = rejected.gone + 1

        elseif not reachableWater(position) then
          rejected.outside = rejected.outside + 1
        else
          local distance = world.magnitude(from, position)

          if bestDistance == nil or distance < bestDistance then
            best = { entry = entry, port = memberId, position = position }
            bestDistance = distance
          end
        end
      end
    end
  end

  if best == nil then
    if offered == 0 then
      return nil, "no fish in the water anywhere in the network"
    end

    return nil, string.format(
      "%s fish in the network, none takeable: %s held by another port, "
      .. "%s backed off after a failure, %s outside network coverage, %s gone, "
      .. "%s from a port that stopped reporting",
      sb.printJson(offered), sb.printJson(rejected.claimed),
      sb.printJson(rejected.backedOff), sb.printJson(rejected.outside),
      sb.printJson(rejected.gone), sb.printJson(rejected.expired))
  end

  sb.logInfo("PETPORT %s FISH dispatch: %s#%s (%s) at %s, %s away, from %s's "
    .. "lure (%s offered)",
    stationUniqueId(), tostring(best.entry.type), sb.printJson(best.entry.id),
    tostring(best.entry.rarity or "unknown rarity"),
    sb.printJson(best.position), sb.printJson(bestDistance),
    tostring(best.port), sb.printJson(offered))

  return {
    id = "fish:" .. best.entry.id,
    type = "fish",
    port = stationUniqueId(),
    target = best.entry.id,
    position = best.position,

    fishType = best.entry.type,
    fishRarity = best.entry.rarity,

    dwell = FISH_DWELL
  }
end

-- Counts the intervals the unit sits motionless away from the port and re-homes it once the stalls run out.
local function healthCheck()
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
    rehomeUnit("motionless away from the port for "
      .. tostring(HEALTH_INTERVAL * HEALTH_STALL_LIMIT) .. "s")
  end
end


-- Returns the point the unit returns to, from its tethering type or a standable spot near the port.
local function homePosition()
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

  local asked = homePointNear()
  if asked ~= nil then return asked end

  return findStandingPoint({
    entity.position()[1] - 4, entity.position()[2] - 4,
    entity.position()[1] + 4, entity.position()[2] + 4
  }) or findStandingPoint(coverageRect())
end

-- Returns a task to walk the unit home when it is stranded or outside the network, re-homing it once the recalls run out.
local function returnWork()
  local rect = coverageRect()

  if self.petId == nil or not world.entityExists(self.petId) then return nil end

  local stranded = (self.unreachableFailures or 0) >= STRANDED_LIMIT
  local inside = inNetwork(world.entityPosition(self.petId))

  local recallState = string.format("%s/%s/%s/%s", tostring(inside),
    tostring(stranded), tostring(self.unreachableFailures or 0),
    tostring(self.recallFailures or 0))

  if recallState ~= self.recallState then
    self.recallState = recallState

    sb.logInfo("PETPORT %s returnWork: unit at %s inNetwork %s stranded %s (unreachableFailures %s of %s, recallFailures %s of %s)",
      stationUniqueId(), sb.printJson(world.entityPosition(self.petId)),
      tostring(inside), tostring(stranded),
      sb.printJson(self.unreachableFailures or 0), sb.printJson(STRANDED_LIMIT),
      sb.printJson(self.recallFailures or 0), sb.printJson(RECALL_LIMIT))
  end

  if not stranded and inside then
    self.recallFailures = 0
    return nil
  end

  sb.logInfo("PETPORT %s returnWork: RECALLING -- collection is suppressed this pass",
    stationUniqueId())

  if (self.recallFailures or 0) >= RECALL_LIMIT then
    rehomeUnit("stranded outside rect at "
      .. sb.printJson(world.entityPosition(self.petId))
      .. " after " .. sb.printJson(RECALL_LIMIT) .. " failed recalls")
    return nil
  end

  local position = homePosition()

  if position == nil then
    rehomeUnit("no standing point in rect to recall to")
    return nil
  end

  return {
    id = "return:" .. stationUniqueId(),
    type = "return",
    port = stationUniqueId(),
    position = position,
    dwell = 0.5
  }
end

-- Returns whether a container would accept any of the unit's cargo, or false when its filter refuses all of it.
local function containerTakesAny(containerId, filter)
  if self.petData == nil or self.petData.cargo == nil then return nil end

  local anyAllowed = false

  for _, stack in ipairs(self.petData.cargo) do
    if petports_filterAccepts(filter, stack.name) then
      anyAllowed = true

      if world.containerItemsCanFit == nil then
        return nil
      end

      local fits = world.containerItemsCanFit(containerId, stack)
      if fits ~= nil and fits > 0 then return true end
    end
  end

  if not anyAllowed then return false end

  return false
end



local claimFree


MACHINE_SLOT_INPUT = 0

MACHINE_SLOT_REAGENT = 1


MACHINE_MIN_BATCH = 0.25

-- Returns how much of a stack a machine slot has room for.
local function machineSlotRoom(machineId, slot, stack)
  local ok, held = pcall(world.containerItemAt, machineId, slot)
  if not ok then return 0 end

  local limit = stackSizeOf(stack.name)

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
local function machineRuleRoom(machine, rule, stack)
  local room = 0

  if rule.burn ~= false then
    room = room + machineSlotRoom(machine.id, MACHINE_SLOT_INPUT, stack)
  end

  if rule.reagent ~= false and petports_reagentFor(stack.name) ~= nil then
    room = room + machineSlotRoom(machine.id, MACHINE_SLOT_REAGENT, stack)
  end

  return room
end

-- Returns how much room a machine's input slot has left.
local function machineInputFree(machineId)
  local ok, held = pcall(world.containerItemAt, machineId, MACHINE_SLOT_INPUT)
  if not ok then return 0 end

  if type(held) ~= "table" or held.name == nil then
    return math.huge
  end

  local free = stackSizeOf(held.name) - (held.count or 0)
  if free < 0 then return 0 end

  return free
end

-- Returns whether any deposit beacon would accept any of the cargo.
local function storageWouldTakeAny()
  if self.petData == nil then return false end

  if self.petData.cargo == nil or #self.petData.cargo == 0 then return true end

  for _, beacon in ipairs(petports_beaconsFor("deposit")) do
    if world.entityExists(beacon.id) then
      for _, stack in ipairs(self.petData.cargo) do
        if petports_filterAccepts(beacon.filter, stack.name) then
          local fits = world.containerItemsCanFit ~= nil
            and world.containerItemsCanFit(beacon.id, stack) or nil

          if fits == nil or fits > 0 then return true end
        end
      end
    end
  end

  return false
end

-- Returns whether an upcycler wants any of the cargo, with the reason each stack was refused.
local function machineWantsAny(machine, floorWaived)
  if machine.kind ~= "upcycler" then return false, "not an upcycler" end
  if not machine.enabled then return false, "switched off" end

  if self.petData == nil or self.petData.cargo == nil then
    return false, "no cargo"
  end

  local reasons = {}

  for _, stack in ipairs(self.petData.cargo) do
    local rule = nil

    for _, candidate in ipairs(machine.rules) do
      if candidate.item == stack.name then
        rule = candidate
        break
      end
    end

    if rule == nil then
      table.insert(reasons, string.format("%s: no rule names it", tostring(stack.name)))
    else
      local held = ((self.census or {})[stack.name] or 0) + (stack.count or 0)

      local batch = 1

      if not floorWaived then
        batch = math.min(
          math.ceil(stackSizeOf(stack.name) * MACHINE_MIN_BATCH),
          stack.count or 1)
      end

      local room = machineRuleRoom(machine, rule, stack)

      if held <= rule.max then
        table.insert(reasons, string.format("%s: network holds %s, threshold %s",
          tostring(stack.name), tostring(held), tostring(rule.max)))
      elseif room < batch then
        table.insert(reasons, string.format("%s: input has room for %s, want %s%s",
          tostring(stack.name), tostring(room), tostring(batch),
          floorWaived and " (floor waived, storage full)" or ""))
      else
        return true
      end
    end
  end

  return false, table.concat(reasons, "; ")
end

-- Returns how much surplus cargo a machine could take.
local function machineRoomFor(machine)
  local room = 0

  for _, stack in ipairs((self.petData and self.petData.cargo) or {}) do
    for _, rule in ipairs(machine.rules) do
      if rule.item == stack.name then
        local held = ((self.census or {})[stack.name] or 0) + (stack.count or 0)

        if held > rule.max then
          room = room + math.min(stack.count or 0,
            machineRuleRoom(machine, rule, stack))
        end
      end
    end
  end

  return room
end

-- Returns a task to feed the upcycler with the most room, waiving the batch floor when storage is full.
local function upcyclerWork()
  if self.petData == nil then return nil end
  if self.petData.cargo == nil or #self.petData.cargo == 0 then return nil end

  if petportOblivious() then return nil end
  if not petportParticipates("machines") then return nil end

  local candidates = {}
  local declined = {}
  local origin = entity.position()

  local floorWaived = not storageWouldTakeAny()

  if floorWaived ~= self.floorWaived then
    self.floorWaived = floorWaived

    if floorWaived then
      sb.logInfo("PETPORT %s storage will not take the load -- WAIVING the "
        .. "upcycler batch floor to keep drops from decaying", stationUniqueId())
    else
      sb.logInfo("PETPORT %s storage has room again -- upcycler batch floor "
        .. "back in force", stationUniqueId())
    end
  end

  for _, machine in ipairs(self.machines or {}) do
    local workId = "upcycle:" .. tostring(machine.id)
    local failure = self.workFailures[workId]
    local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

    if backedOff then
      table.insert(declined, string.format("%s@%s,%s (backed off, %s failure(s))",
        tostring(machine.kind),
        tostring(math.floor(machine.position[1])),
        tostring(math.floor(machine.position[2])),
        tostring(failure.count)))

    elseif not claimFree(workId) then
      table.insert(declined, string.format("%s@%s,%s (claimed by another unit)",
        tostring(machine.kind),
        tostring(math.floor(machine.position[1])),
        tostring(math.floor(machine.position[2]))))

    elseif world.entityExists(machine.id) then
      local wants, why = machineWantsAny(machine, floorWaived)

      if wants then
        table.insert(candidates, {
          machine = machine,
          room = machineRoomFor(machine),
          distance = world.magnitude(origin, machine.position)
        })
      else
        table.insert(declined, string.format("%s@%s,%s (%s)",
          tostring(machine.kind),
          tostring(math.floor(machine.position[1])),
          tostring(math.floor(machine.position[2])),
          tostring(why)))
      end
    end
  end

  if #candidates == 0 then
    local report = table.concat(declined, " || ")

    if #declined > 0 and report ~= self.upcyclerDeclined then
      self.upcyclerDeclined = report
      sb.logInfo("PETPORT %s upcycler declined: %s", stationUniqueId(), report)
    end

    return nil
  end

  self.upcyclerDeclined = nil

  table.sort(candidates, function(a, b)
    if a.room ~= b.room then return a.room > b.room end
    return a.distance < b.distance
  end)

  for _, candidate in ipairs(candidates) do
    local machine = candidate.machine

    local stand, standWhy = servicePointNear("upcycler " .. tostring(machine.id),
      machine.id, machine.position, 4)

    if stand == nil then
      sb.logInfo("PETPORT %s upcycler %s SKIPPED: %s of %s",
        stationUniqueId(), sb.printJson(machine.id), tostring(standWhy),
        sb.printJson(machine.position))
    else
      sb.logInfo("PETPORT %s upcycling to %s at %s: room for %s, %s tile(s) away (%s candidate(s), %s)",
        stationUniqueId(), tostring(machine.kind), sb.printJson(machine.position),
        sb.printJson(candidate.room), sb.printJson(math.floor(candidate.distance)),
        sb.printJson(#candidates),
        floorWaived and "batch floor waived, storage full" or "normal")

      return {
        id = "upcycle:" .. tostring(machine.id),
        mediumVerified = true,
        type = "upcycle",
        target = machine.id,
        position = stand,
        containerPosition = machine.position,
        port = stationUniqueId(),
        dwell = 0
      }
    end
  end

  return nil
end


-- Returns the crate an item belongs in, cached per beacon scan.
local function defragHomeFor(name, targets, descriptor)
  local version = self.beaconVersion or 0

  if self.defragHomeVersion ~= version then
    self.defragHomeVersion = version
    self.defragHomes = {}
  end

  local held = self.defragHomes[name]

  if held ~= nil then
    if held == false then return nil end
    return held
  end

  local where = (self.spread or {})[name] or {}

  local target, why, has = defragDestination(name, where, targets,
    petports_itemPerishable(descriptor or name))

  if target == nil or (has or 0) <= 0 and why == "accepts it, holds most" then
    self.defragHomes[name] = false
    return nil
  end

  self.defragHomes[name] = target.id
  return target.id
end

-- Reorders the deposit beacons to favour the homes the cargo belongs in, skipping a crate an item was just pulled from.
local function defragPreferredTargets(targets)
  if not petportDefrag() then return targets end
  if not petportParticipates("defrag") then return targets end
  if self.petData == nil or type(self.petData.cargo) ~= "table" then return targets end

  local votes = {}
  local voted = 0

  for _, stack in ipairs(self.petData.cargo) do
    if type(stack.name) == "string" then
      local home = defragHomeFor(stack.name, targets, stack)

      local pulled = (self.defragPulled or {})[stack.name]

      if pulled ~= nil then
        self.defragPulled[stack.name] = nil

        if home ~= nil and home == pulled.from then
          sb.logError("PETPORT %s defrag pulled %s out of crate %s and is "
            .. "about to put it back -- backing off; the destination it was "
            .. "dispatched toward stopped being the answer between dispatch "
            .. "and arrival",
            stationUniqueId(), tostring(stack.name), sb.printJson(home))

          noteFailure(pulled.workId, "defrag would return it to its source")
          home = nil
        end
      end

      if home ~= nil then
        votes[home] = (votes[home] or 0) + 1
        voted = voted + 1
      end
    end
  end

  if voted == 0 then return targets end

  local ranked = {}
  for index, beacon in ipairs(targets) do
    table.insert(ranked, { beacon = beacon, index = index, votes = votes[beacon.id] or 0 })
  end

  table.sort(ranked, function(a, b)
    if a.votes ~= b.votes then return a.votes > b.votes end
    return a.index < b.index
  end)

  local out = {}
  for _, entry in ipairs(ranked) do table.insert(out, entry.beacon) end

  if DEFRAG_DEBUG and ranked[1] ~= nil and ranked[1].votes > 0 then
    local said = string.format("%s|%s|%s", tostring(ranked[1].beacon.id),
      tostring(ranked[1].votes), tostring(ranked[1].index))

    if said ~= self.defragPreferSaid then
      self.defragPreferSaid = said

      sb.logInfo("PETPORT %s defrag deposit: crate %s wins with %s of %s "
        .. "stack(s), was %s of %s by distance",
        stationUniqueId(), tostring(ranked[1].beacon.id),
        tostring(ranked[1].votes), tostring(#self.petData.cargo),
        tostring(ranked[1].index), tostring(#targets))
    end
  end

  return out
end

-- Returns a task to unload the cargo: the upcycler first, then the nearest deposit beacon that will take any of it.
local function depositWork()
  if self.petData == nil then return nil end
  if self.petData.cargo == nil or #self.petData.cargo == 0 then return nil end

  local upcycle = upcyclerWork()
  if dispatchable(upcycle) ~= nil then return upcycle end

  local targets = petports_beaconsFor("deposit")

  targets = defragPreferredTargets(targets)

  if #targets == 0 then
    return nil, "carrying " .. sb.printJson(#self.petData.cargo)
      .. " stack(s) but no deposit beacon in coverage"
  end

  local now = world.time()
  self.fullContainers = self.fullContainers or {}

  for _, beacon in ipairs(targets) do
    local workId = "deposit:" .. tostring(beacon.id) .. "@" .. stationUniqueId()
    local failure = self.workFailures[workId]
    local failureBackedOff = failure ~= nil and (failure["until"] or 0) > now
    if failureBackedOff then
      sb.logInfo("PETPORT %s deposit target %s SKIPPED: backed off until %s (now %s, failures %s)",
        stationUniqueId(), sb.printJson(beacon.id),
        sb.printJson(failure["until"]), sb.printJson(now), sb.printJson(failure.count))
    end

    local takesAny = containerTakesAny(beacon.id, beacon.filter)
    local backedOff

    if failureBackedOff then
      backedOff = true
    elseif takesAny == nil then
      backedOff = (self.fullContainers[beacon.id] or 0) > now
      if backedOff then
        sb.logInfo("PETPORT %s deposit target %s SKIPPED: was full, retrying in %s (no containerItemsCanFit)",
          stationUniqueId(), sb.printJson(beacon.id),
          sb.printJson((self.fullContainers[beacon.id] or 0) - now))
      end
    else
      backedOff = not takesAny
      if backedOff then
        local held = {}
        for _, stack in ipairs(self.petData.cargo) do
          table.insert(held, string.format("%sx%s",
            tostring(stack.name), tostring(stack.count or 1)))
        end

        local reason = "full"
        if beacon.filter ~= nil then
          local allowed = false
          for _, stack in ipairs(self.petData.cargo) do
            if petports_filterAccepts(beacon.filter, stack.name) then
              allowed = true
              break
            end
          end
          if not allowed then reason = "filter rejects every stack" end
        end

        sb.logInfo("PETPORT %s deposit target %s SKIPPED (%s): cannot take any of [%s]",
          stationUniqueId(), sb.printJson(beacon.id), reason, table.concat(held, ", "))
      end
    end

    if backedOff then
    else
      local stand, standWhy = servicePointNear("crate " .. tostring(beacon.id),
        beacon.id, beacon.position, 4)

      if stand == nil then
        sb.logInfo("PETPORT %s deposit target %s SKIPPED: %s of %s",
          stationUniqueId(), sb.printJson(beacon.id), tostring(standWhy),
          sb.printJson(beacon.position))
      else

        return {
          id = "deposit:" .. tostring(beacon.id) .. "@" .. stationUniqueId(),
          mediumVerified = true,
          type = "deposit",
          target = beacon.id,
          position = stand,
          containerPosition = beacon.position,
          port = stationUniqueId(),
          dwell = 0
        }
      end
    end
  end

  return nil, "every deposit beacon is backed off as full"
end

SLOT_KEY_TO_OFFSET = -1

-- Counts a tidy when taking an item leaves a crate holding none of it.
metrics.noteStorageTake = function(containerId, name)
  if containerId == nil or name == nil then return end
  if machineAt(containerId) ~= nil then return end

  local ok, left = pcall(world.containerAvailable, containerId, name)
  if not ok or type(left) ~= "number" or left > 0 then return end

  metrics.add("tidy", 1)

  sb.logInfo("PETPORT %s TIDY +1: cleared the last %s out of %s (score %s)",
    stationUniqueId(), tostring(name), sb.printJson(containerId),
    sb.printJson((self.petData and self.petData.stats and self.petData.stats.tidy) or 0))
end

-- Takes items from a container slot, putting them back when what came out is not what was expected.
local function takeFromSlot(containerId, slot, count, expected)
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

    if workId ~= nil then noteFailure(workId, reason) end
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
    local taken = takeFromSlot(containerId, slot, want, expected)

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

  metrics.noteStorageTake(containerId, seedName)
end

-- Takes a named stack out of one crate slot, refusing when that slot now holds something else.
function withdrawMisfit(containerId, name, count, workId, slot)
  if name == nil then return end
  count = count or 1

  -- Logs the withdrawal coming back empty and backs the task off.
  local function empty(reason)
    sb.logInfo("PETPORT %s tidy of %s from %s took nothing: %s",
      stationUniqueId(), tostring(name), sb.printJson(containerId), reason)

    if workId ~= nil then noteFailure(workId, reason) end
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

  local taken = takeFromSlot(containerId, slot, math.min(count, expected.count or 1),
    expected)

  if taken == nil then
    empty("slot " .. tostring(slot) .. " gave nothing up")
    return
  end

  sb.logInfo("PETPORT %s tidied %s %s out of %s (slot %s)",
    stationUniqueId(), sb.printJson(taken.count or 1), tostring(name),
    sb.printJson(containerId), tostring(slot))

  metrics.noteStorageTake(containerId, name)

  if machineAt(containerId) == nil then
    compactContainer(containerId)
  end

  receiveCargo(taken)
end

-- Uses one medkit charge and writes the item back.
function spendMedkit()
  if self.petData == nil then return end

  local held = self.petData.medkit

  if type(held) ~= "table" or held.name == nil then
    sb.logError("PETPORT %s dosed a patient with an empty medkit",
      stationUniqueId())
    return
  end

  local count = (held.count or 1) - 1

  if count <= 0 then
    self.petData.medkit = nil
  else
    held.count = count
  end

  sb.logInfo("PETPORT %s spent 1 %s dosing; medkit now %s",
    stationUniqueId(), tostring(held.name),
    self.petData.medkit == nil and "empty" or sb.printJson(count))

  self.dirty = true
  self.paneSignature = nil
  writeBackToItem()
end

-- Returns the held medkit to the cargo once the medic module is gone.
function reconcileMedkit()
  if self.petData == nil then return end

  local held = self.petData.medkit
  if held == nil then return end

  if type(held) ~= "table" or held.name == nil then
    sb.logError("PETPORT %s discarding a malformed medkit: %s",
      stationUniqueId(), sb.printJson(held))

    self.petData.medkit = nil
    self.dirty = true
    return
  end

  if petportMedic() then return end

  self.petData.medkit = nil
  self.paneSignature = nil

  sb.logInfo("PETPORT %s medic module is gone -- returning %s x%s from the "
    .. "medkit to cargo for deposit",
    stationUniqueId(), tostring(held.name), sb.printJson(held.count or 1))

  receiveCargo(held)
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
local function placeStack(containerId, stack)
  if type(stack) ~= "table" or stack.name == nil then return 0 end

  local limit = stackSizeFor(stack.name, stack.parameters)
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
    local unplaced = placeStack(containerId, stack)

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

  cargoTrace("deposit: cargo replaced", remaining)
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

  metrics.add("moved", delivered)

  compactContainer(containerId)

  flushCargo()
end

-- Places the cargo a machine's rules want into its input and reagent slots.
function depositCargoToMachine(machineId, workId)
  if self.petData == nil or self.petData.cargo == nil then return end

  if not world.entityExists(machineId) then
    sb.logInfo("PETPORT %s upcycle failed: machine %s no longer exists",
      stationUniqueId(), sb.printJson(machineId))
    return
  end

  local machine = machineAt(machineId)

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
        local slotRoom = machineSlotRoom(machineId, MACHINE_SLOT_REAGENT, stack)
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
        local slotRoom = machineSlotRoom(machineId, MACHINE_SLOT_INPUT, stack)
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

  cargoTrace("deposit: cargo replaced", remaining)
  self.petData.cargo = remaining

  metrics.add("moved", moved)

  if moved == 0 then
    local reason = "machine input was full on arrival"

    sb.logInfo("PETPORT %s upcycle delivered NOTHING to machine %s -- input full, "
      .. "rule gone, or no longer over threshold", stationUniqueId(),
      sb.printJson(machineId))

    noteFailure(workId, reason)
  end

  flushCargo()
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

      local unplaced = placeStack(containerId, stack)

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

  cargoTrace("deposit: cargo replaced", remaining)
  self.petData.cargo = remaining

  metrics.add("moved", delivered)

  compactContainer(containerId)

  flushCargo()
end


-- Returns the engine's default max stack, read once.
local function defaultMaxStack()
  if self.defaultStack == nil then
    local ok, config = pcall(root.assetJson, "/items/defaultParameters.config")

    self.defaultStack = (ok and type(config) == "table"
      and tonumber(config.defaultMaxStack)) or false
  end

  return self.defaultStack or nil
end

-- Returns an item's max stack size, cached, falling back to the default.
stackSizeOf = function(name)
  self.stackSizes = self.stackSizes or {}

  if self.stackSizes[name] == nil then
    local size, source = nil, "guessed"

    local ok, resolved = pcall(root.itemConfig, { name = name, count = 1 })

    if ok and type(resolved) == "table" and type(resolved.config) == "table" then
      size = tonumber(resolved.config.maxStack)
      if size ~= nil then source = "config" end
    end

    if size == nil then
      size = defaultMaxStack()
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
stackSizeFor = function(name, parameters)
  if type(parameters) == "table" then
    local override = tonumber(parameters.maxStack)
    if override ~= nil and override >= 1 then return override end
  end

  return stackSizeOf(name)
end

-- Returns whether two values are equal, comparing tables field by field.
local function sameValue(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end

  for key, value in pairs(a) do
    if not sameValue(value, b[key]) then return false end
  end

  for key in pairs(b) do
    if a[key] == nil then return false end
  end

  return true
end

-- Returns a printable key for a stack's parameters.
local function parameterKey(parameters)
  if parameters == nil then return "" end

  local ok, text = pcall(sb.printJson, parameters)
  if ok then return text end

  return "?" .. tostring(parameters)
end

-- Returns every item held across more slots than its stack sizes need, with its parameter buckets.
local function fragmentation(items)
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
      local key = parameterKey(parameters)
      local bucket = group.byKey[key]

      if bucket ~= nil and not sameValue(bucket.parameters, parameters) then
        bucket = nil

        for _, candidate in ipairs(group.buckets) do
          if sameValue(candidate.parameters, parameters) then
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
          + math.ceil(bucket.count / stackSizeFor(name, bucket.parameters))
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

  local work = fragmentation(items)
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
        local unplaced = placeStack(containerId, {
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
            .. "-- stackSizeOf says %s",
            stationUniqueId(), tostring(group.name), sb.printJson(containerId),
            sb.printJson(slots), sb.printJson(group.needed),
            sb.printJson(stackSizeOf(group.name)))
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
local function sortTypeRank(name)
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
local function sortRarityRank(name, parameters)
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
local function sortLess(a, b)
	if a.type ~= b.type then return a.type < b.type end
	if a.rarity ~= b.rarity then return a.rarity < b.rarity end
	if a.name ~= b.name then return a.name < b.name end
	if a.count ~= b.count then return a.count > b.count end
	if a.pkey ~= b.pkey then return a.pkey < b.pkey end
	return a.key < b.key
end

-- Returns the slot order a container should hold, beacons pinned first, and how many stacks are out of place.
local function sortPlan(items)
	if type(items) ~= "table" then return {}, 0 end

	local keys = {}
	for key in pairs(items) do table.insert(keys, key) end
	table.sort(keys)

	local pinned, loose = {}, {}

	for _, key in ipairs(keys) do
		local stack = items[key]

		if type(stack) == "table" and type(stack.name) == "string" then
			if SORT_BEACONS_FIRST and beaconBehaviorOf(stack) ~= nil then
				table.insert(pinned, { key = key, stack = stack })
			else
				table.insert(loose, {
					key = key,
					stack = stack,
					name = stack.name,
					count = stack.count or 1,
					type = sortTypeRank(stack.name),
					rarity = sortRarityRank(stack.name, stack.parameters),
					pkey = parameterKey(stack.parameters)
				})
			end
		end
	end

	table.sort(loose, sortLess)

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
local function sortLift(containerId, record, key)
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
local function sortLay(containerId, stack, key)
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
local function sortTally(items)
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

	local before = sortTally(items)
	local order, disorder = sortPlan(items)

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
			local hand = sortLift(containerId, record, source)

			if hand == nil then
				aborted = "lift refused"
				break
			end

			local evicted = at[target]
			local carried = nil

			if evicted ~= nil then
				carried = sortLift(containerId, evicted, target)

				if carried == nil then
					sortLay(containerId, hand, source)
					aborted = "second lift refused"
					break
				end
			end

			if not sortLay(containerId, hand, target) then
				if carried ~= nil then sortLay(containerId, carried, source) end
				aborted = "destination refused"
				break
			end

			at[target] = record
			where[record] = target
			at[source] = nil

			if carried ~= nil then
				if not sortLay(containerId, carried, source) then
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
		local tally = sortTally(after)

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
		metrics.add("tidy", 1)

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
claimFree = function(workId)
	local claim = petports_claimGet(workId)

	return (claim == nil)
		or claim.owner == stationUniqueId()
		or (claim.expires or 0) <= world.time()
end


local soilCache = {}

local wetNameCache = nil

-- Returns the wet matmod a dry soil turns into, confirmed against farming.config's inverse table.
local function wetModName(dryName, transformModId)
	if wetNameCache == nil then
		wetNameCache = {}

		for _, path in ipairs({ "/farming.config", "/assets/farming.config" }) do
			local ok, config = pcall(root.assetJson, path)

			if ok and type(config) == "table" and type(config.wetToDryMods) == "table" then
				for wet, dry in pairs(config.wetToDryMods) do
					wetNameCache[tostring(dry)] = tostring(wet)
				end

				sb.logInfo("PETPORT %s read wetToDryMods from %s: %s",
					stationUniqueId(), path, sb.printJson(config.wetToDryMods))
				break
			end
		end
	end

	local inverted = wetNameCache[tostring(dryName)]
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
local function soilInfo(modName)
	if modName == nil then return nil end

	local key = tostring(modName)
	if soilCache[key] ~= nil then return soilCache[key] end

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

				local wetName, via = wetModName(key, interaction.transformModId)

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

	soilCache[key] = info
	return info
end

-- Returns the dry tilled soil at a tile and what it wants, or nil.
local function drySoilAt(tile)
	local modName = world.mod({ tile[1], tile[2] }, "foreground")
	if modName == nil then return nil end

	local info = soilInfo(modName)
	if info == nil or not info.tilled or not info.dry then return nil end

	return { mod = tostring(modName), wants = info.wants }
end

-- Returns a crop's stage list from the object or its item config.
local function farmableStages(id)
	local ok, stages = pcall(world.getObjectParameter, id, "stages")
	if ok and type(stages) == "table" and #stages > 0 then
		return stages
	end

	local name = world.entityName(id)
	if name == nil then return nil end

	local okItem, config = pcall(root.itemConfig, name)
	if okItem and type(config) == "table" and type(config.config) == "table"
	   and type(config.config.stages) == "table" then
		return config.config.stages
	end

	return nil
end

-- Returns the first stage that carries a harvest pool.
local function harvestStageOf(stages)
	for index, stage in ipairs(stages) do
		if type(stage) == "table" and stage.harvestPool ~= nil then
			return index - 1 + FARMABLE_STAGE_BASE
		end
	end

	return nil
end

-- Returns a trap's ripening age, active window and whether it can ever ripen, cached by name.
local function trapProfile(id)
	local name = world.entityName(id)
	if name == nil then return nil end

	self.trapProfiles = self.trapProfiles or {}

	local cached = self.trapProfiles[name]
	if cached ~= nil then
		if cached == false then return nil end
		return cached
	end

	local okStages, stages = pcall(world.getObjectParameter, id, "stages")

	if not okStages or type(stages) ~= "table" or #stages == 0
	   or type(stages[#stages]) ~= "table"
	   or stages[#stages].harvestPool == nil then
		self.trapProfiles[name] = false
		return nil
	end

	local ripeAt = 0
	local stalls = false

	for index, stage in ipairs(stages) do
		if index < #stages then
			local duration = type(stage) == "table" and stage.duration or nil
			local span = nil

			if type(duration) == "table" then
				span = math.max(tonumber(duration[1]) or 0,
					tonumber(duration[2]) or 0)
			elseif type(duration) == "number" then
				span = duration
			end

			if span == nil or span <= 0 then
				stalls = true
			else
				ripeAt = ripeAt + span
			end
		end
	end

	local okRange, range = pcall(world.getObjectParameter, id, "activeTimeRange")
	if not okRange or type(range) ~= "table" then range = { 0, 1 } end

	local span = ((tonumber(range[2]) or 1) - (tonumber(range[1]) or 0)) % 1.0

	local lockedBy = nil
	if span == 0 then
		lockedBy = "its activeTimeRange spans zero of the day"
	elseif stalls then
		lockedBy = "one of its growth stages declares no duration"
	end

	local profile = {
		name = name,
		ripeAt = ripeAt,
		span = span,
		locked = (lockedBy ~= nil),
		lockedBy = lockedBy,
		stageCount = #stages
	}

	self.trapProfiles[name] = profile
	return profile
end

-- Returns a trap's active age, or nil.
local function trapAge(id)
	local ok, age = pcall(world.callScriptedEntity, id, "activeAge")

	if not ok or type(age) ~= "number" then return nil end
	return age
end

-- Logs the traps and their ages when the picture changes, warning once per trap that can never ripen.
local function reportTraps(traps)
	self.trapWarned = self.trapWarned or {}

	local ripe = 0
	local parts = {}

	for _, trap in ipairs(traps) do
		if trap.ripe then ripe = ripe + 1 end

		table.insert(parts, string.format("%s#%s age %s of %s%s%s",
			tostring(trap.name), tostring(trap.id),
			trap.age == nil and "unreadable"
				or string.format("%.0f", trap.age),
			string.format("%.0f", trap.ripeAt),
			trap.locked and " LOCKED" or "",
			trap.ripe and " RIPE" or ""))

		if trap.locked and not self.trapWarned[trap.id] then
			self.trapWarned[trap.id] = true

			sb.logWarn("PETPORT %s trap %s (%s) at %s CAN NEVER RIPEN: %s, so "
				.. "harvestable.lua holds it on an early stage forever and "
				.. "nobody -- player or unit -- can harvest it. Note that "
				.. "OMITTING activeTimeRange defaults it to [0, 1], which that "
				.. "script reads as a span of ZERO.",
				stationUniqueId(), sb.printJson(trap.id), tostring(trap.name),
				sb.printJson(trap.position),
				tostring(trap.lockedBy or "its config stalls stage growth"))
		end
	end

	table.sort(parts)
	local signature = table.concat(parts, " | ")

	if signature ~= self.trapSignature then
		self.trapSignature = signature
		sb.logInfo("PETPORT %s traps: %s found, %s ripe -- %s",
			stationUniqueId(), sb.printJson(#traps), sb.printJson(ripe),
			signature == "" and "none" or signature)
	end
end

-- Scans the network for crops and traps, returning each with its stage and whether it is ripe.
local function scanFarmables()
	local rects = self.networkRects
	if rects == nil or #rects == 0 then rects = { coverageRect() } end

	local found = {}
	local traps = {}
	local seen = {}
	local objects = 0

	for _, rect in ipairs(rects) do
		local ids = world.entityQuery({ rect[1], rect[2] }, { rect[3], rect[4] }, {
			includedTypes = { "object" }
		})

		for _, id in ipairs(ids or {}) do
			if not seen[id] then
				seen[id] = true
				objects = objects + 1

				local ok, stage = pcall(world.farmableStage, id)

				if ok and type(stage) == "number" then
					local stages = farmableStages(id)
					local harvestAt = stages ~= nil and harvestStageOf(stages) or nil

					if harvestAt ~= nil then
						table.insert(found, {
							id = id,
							name = world.entityName(id),
							stage = stage,
							harvestAt = harvestAt,
							stageCount = #stages,
							position = world.entityPosition(id),
							ripe = (stage == harvestAt)
						})
					end
				else
					local profile = trapProfile(id)

					if profile ~= nil then
						local age = profile.locked and 0 or trapAge(id)

						table.insert(traps, {
							id = id,
							name = profile.name,
							age = age,
							ripeAt = profile.ripeAt,
							locked = profile.locked,
							lockedBy = profile.lockedBy,
							stageCount = profile.stageCount,
							position = world.entityPosition(id),
							ripe = (not profile.locked) and age ~= nil
								and age >= profile.ripeAt
						})
					end
				end
			end
		end
	end

	return found, objects, traps
end

-- Rescans the crops and traps on an interval.
local function refreshFarmables(dt)
	self.harvestTimer = (self.harvestTimer or 0) - dt
	if self.harvestTimer > 0 then return end
	self.harvestTimer = HARVEST_INTERVAL

	local found, objects, traps = scanFarmables()
	self.farmables = found
	self.traps = traps

	local ripe = 0
	local parts = {}

	for _, crop in ipairs(found) do
		if crop.ripe then ripe = ripe + 1 end
		table.insert(parts, string.format("%s#%s stage %s of %s harvestAt %s%s",
			tostring(crop.name), tostring(crop.id),
			tostring(crop.stage), tostring(crop.stageCount),
			tostring(crop.harvestAt), crop.ripe and " RIPE" or ""))
	end

	table.sort(parts)
	local signature = table.concat(parts, " | ")

	if signature ~= self.farmableSignature then
		self.farmableSignature = signature
		sb.logInfo("PETPORT %s farmables: %s of %s object(s), %s ripe -- %s",
			stationUniqueId(), sb.printJson(#found), sb.printJson(objects),
			sb.printJson(ripe), signature == "" and "none" or signature)
	end

	reportTraps(traps)
end

local animalTypeCache = {}

-- Returns whether a monster type can be harvested at all.
local function animalHarvestable(monsterType)
	if monsterType == nil then return false end

	local key = tostring(monsterType)
	if animalTypeCache[key] ~= nil then return animalTypeCache[key] end

	local harvestable = false
	local ok, params = pcall(root.monsterParameters, key)

	if ok and type(params) == "table" then
		local base = type(params.baseParameters) == "table"
			and params.baseParameters or {}

		local pool = params.harvestPool or base.harvestPool
		local time = params.harvestTime or base.harvestTime

		harvestable = (pool ~= nil and time ~= nil)

		sb.logInfo("PETPORT %s monster type %s: harvestPool %s harvestTime %s -> %s",
			stationUniqueId(), key, tostring(pool ~= nil), tostring(time ~= nil),
			harvestable and "HARVESTABLE" or "not livestock")
	else
		sb.logInfo("PETPORT %s monster type %s: root.monsterParameters gave nothing",
			stationUniqueId(), key)
	end

	animalTypeCache[key] = harvestable
	return harvestable
end

-- Scans the network for harvestable farm animals.
local function scanAnimals()
	local rects = self.networkRects
	if rects == nil or #rects == 0 then rects = { coverageRect() } end

	local found = {}
	local seen = {}
	local monsters = 0

	for _, rect in ipairs(rects) do
		local ids = world.entityQuery({ rect[1], rect[2] }, { rect[3], rect[4] }, {
			includedTypes = { "monster" }
		})

		for _, id in ipairs(ids or {}) do
			if not seen[id] then
				seen[id] = true
				monsters = monsters + 1

				local monsterType = world.monsterType(id)

				if animalHarvestable(monsterType) then
					local ok, ready = pcall(world.callScriptedEntity, id,
						"hasMonsterHarvest")

					if ok and type(ready) == "boolean" then
						table.insert(found, {
							id = id,
							name = monsterType,
							ready = ready,
							position = world.entityPosition(id)
						})
					end
				end
			end
		end
	end

	return found, monsters
end

-- Rescans the farm animals on an interval.
local function refreshAnimals(dt)
	self.animalTimer = (self.animalTimer or 0) - dt
	if self.animalTimer > 0 then return end
	self.animalTimer = HARVEST_INTERVAL

	local found, monsters = scanAnimals()
	self.animals = found

	local ready = 0
	local parts = {}

	for _, animal in ipairs(found) do
		if animal.ready then ready = ready + 1 end
		table.insert(parts, string.format("%s#%s%s", tostring(animal.name),
			tostring(animal.id), animal.ready and " READY" or ""))
	end

	table.sort(parts)
	local signature = table.concat(parts, " | ")

	if signature ~= self.animalSignature then
		self.animalSignature = signature
		sb.logInfo("PETPORT %s animals: %s farmable of %s monster(s), %s ready -- %s",
			stationUniqueId(), sb.printJson(#found), sb.printJson(monsters),
			sb.printJson(ready), signature == "" and "none" or signature)
	end
end

-- Returns a task to harvest the nearest ready animal, or nil with a tally of why each was passed over.
local function animalWork()
	local animals = self.animals

	if animals == nil or #animals == 0 then
		return nil, "no farm animals in network coverage"
	end

	local from = entity.position()
	if self.petId ~= nil and world.entityExists(self.petId) then
		from = world.entityPosition(self.petId)
	end

	local best, bestDistance = nil, nil
	local rejected = { notReady = 0, claimed = 0, backedOff = 0, gone = 0,
		unreachable = 0 }

	for _, animal in ipairs(animals) do
		local workId = "animal:" .. animal.id
		local failure = self.workFailures[workId]
		local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

		if not world.entityExists(animal.id) then
			rejected.gone = rejected.gone + 1
		elseif not animalHarvestable(animal.name) then
			rejected.notReady = rejected.notReady + 1
		else
			local ok, ready = pcall(world.callScriptedEntity, animal.id,
				"hasMonsterHarvest")

			if not (ok and ready == true) then
				rejected.notReady = rejected.notReady + 1
			elseif backedOff then
				rejected.backedOff = rejected.backedOff + 1
			elseif not claimFree(workId) then
				rejected.claimed = rejected.claimed + 1
			else
				local position = world.entityPosition(animal.id)
				local distance = world.magnitude(from, position)

				if standingPointNear(position, 4) == nil then
					rejected.unreachable = rejected.unreachable + 1
				elseif bestDistance == nil or distance < bestDistance then
					best = { id = animal.id, name = animal.name, position = position }
					bestDistance = distance
				end
			end
		end
	end

	if best == nil then
		local reason = string.format(
			"%s farm animal(s), none harvestable: %s not ready, %s claimed, "
			.. "%s backed off, %s gone, %s with nowhere this chassis can stand",
			#animals, rejected.notReady, rejected.claimed,
			rejected.backedOff, rejected.gone, rejected.unreachable)

		if reason ~= self.animalRejectReason then
			self.animalRejectReason = reason
			sb.logInfo("PETPORT %s animals: %s", stationUniqueId(), reason)
		end

		return nil, reason
	end

	self.animalRejectReason = nil

	sb.logInfo("PETPORT %s ANIMAL dispatch: %s#%s at %s, %s away",
		stationUniqueId(), tostring(best.name), sb.printJson(best.id),
		sb.printJson(best.position), sb.printJson(bestDistance))

	return {
		id = "animal:" .. best.id,
		type = "animal",
		port = stationUniqueId(),
		target = best.id,
		position = best.position
	}
end

-- Returns a task to harvest the nearest ripe crop, or nil with a tally of why each was passed over.
local function harvestWork()
	local crops = self.farmables

	if crops == nil or #crops == 0 then
		return nil, "no farmables in network coverage"
	end

	local from = entity.position()
	if self.petId ~= nil and world.entityExists(self.petId) then
		from = world.entityPosition(self.petId)
	end

	local best, bestDistance = nil, nil
	local rejected = { unripe = 0, claimed = 0, backedOff = 0, gone = 0, medium = 0 }

	for _, crop in ipairs(crops) do
		local workId = "harvest:" .. crop.id
		local claim = petports_claimGet(workId)
		local failure = self.workFailures[workId]
		local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

		local free = not backedOff and ((claim == nil)
			or claim.owner == stationUniqueId()
			or (claim.expires or 0) <= world.time())

		local okStage, stage = pcall(world.farmableStage, crop.id)
		local ripe = okStage and type(stage) == "number"
			and stage == crop.harvestAt

		if not ripe then
			rejected.unripe = rejected.unripe + 1
		elseif backedOff then
			sb.logInfo("PETPORT %s crop %s SKIPPED: backed off until %s (failures %s)",
				stationUniqueId(), sb.printJson(crop.id),
				sb.printJson(failure["until"]), sb.printJson(failure.count))
			rejected.backedOff = rejected.backedOff + 1
		elseif not free then
			sb.logInfo("PETPORT %s crop %s SKIPPED: claimed by %s until %s",
				stationUniqueId(), sb.printJson(crop.id),
				tostring(claim.owner), sb.printJson(claim.expires))
			rejected.claimed = rejected.claimed + 1
		elseif not world.entityExists(crop.id) then
			rejected.gone = rejected.gone + 1

		elseif not targetEligible("crop " .. tostring(crop.id), crop.position, crop.id) then
			rejected.medium = rejected.medium + 1
		else
			local distance = world.magnitude(from, crop.position)

			if bestDistance == nil or distance < bestDistance then
				sb.logInfo("PETPORT %s crop %s (%s) RIPE at %s, %s away -- new best",
					stationUniqueId(), sb.printJson(crop.id), tostring(crop.name),
					sb.printJson(crop.position), sb.printJson(distance))
				best, bestDistance = crop, distance
			end
		end
	end

	if best == nil then
		local reason = string.format(
			"%s farmable(s) in coverage, none harvestable: %s unripe, "
			.. "%s claimed, %s backed off, %s gone, %s in a medium this "
			.. "chassis cannot work in",
			#crops, rejected.unripe, rejected.claimed,
			rejected.backedOff, rejected.gone, rejected.medium)

		if reason ~= self.harvestRejectReason then
			self.harvestRejectReason = reason
			sb.logInfo("PETPORT %s harvest: %s", stationUniqueId(), reason)
		end

		return nil, reason
	end

	self.harvestRejectReason = nil

	return {
		id = "harvest:" .. best.id,
		mediumVerified = true,
		type = "harvest",
		port = stationUniqueId(),
		target = best.id,
		targetName = best.name,
		position = best.position
	}
end

-- Returns a task to empty the nearest ripe trap, or nil with a tally of why each was passed over.
local function trapWork()
	local traps = self.traps

	if traps == nil or #traps == 0 then
		return nil, "no harvestable traps in network coverage"
	end

	local from = entity.position()
	if self.petId ~= nil and world.entityExists(self.petId) then
		from = world.entityPosition(self.petId)
	end

	local best, bestDistance = nil, nil
	local rejected = { unripe = 0, locked = 0, claimed = 0, backedOff = 0,
		gone = 0, medium = 0 }

	for _, trap in ipairs(traps) do
		local workId = "trap:" .. trap.id
		local claim = petports_claimGet(workId)
		local failure = self.workFailures[workId]
		local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

		local free = not backedOff and ((claim == nil)
			or claim.owner == stationUniqueId()
			or (claim.expires or 0) <= world.time())

		if trap.locked then
			rejected.locked = rejected.locked + 1
		elseif not trap.ripe then
			rejected.unripe = rejected.unripe + 1
		elseif backedOff then
			rejected.backedOff = rejected.backedOff + 1
		elseif not free then
			rejected.claimed = rejected.claimed + 1
		elseif not world.entityExists(trap.id) then
			rejected.gone = rejected.gone + 1

		elseif not targetEligible("trap " .. tostring(trap.id),
			trap.position, trap.id) then
			rejected.medium = rejected.medium + 1
		else
			local distance = world.magnitude(from, trap.position)

			if bestDistance == nil or distance < bestDistance then
				best, bestDistance = trap, distance
			end
		end
	end

	if best == nil then
		local reason = string.format(
			"%s trap(s) in coverage, none harvestable: %s unripe, %s age "
			.. "locked, %s claimed, %s backed off, %s gone, %s in a medium "
			.. "this chassis cannot work in",
			#traps, rejected.unripe, rejected.locked, rejected.claimed,
			rejected.backedOff, rejected.gone, rejected.medium)

		if reason ~= self.trapRejectReason then
			self.trapRejectReason = reason
			sb.logInfo("PETPORT %s traps: %s", stationUniqueId(), reason)
		end

		return nil, reason
	end

	self.trapRejectReason = nil

	sb.logInfo("PETPORT %s trap %s (%s) RIPE at %s, %s away -- dispatching",
		stationUniqueId(), sb.printJson(best.id), tostring(best.name),
		sb.printJson(best.position), sb.printJson(bestDistance))

	return {
		id = "trap:" .. best.id,
		mediumVerified = true,
		type = "trap",
		port = stationUniqueId(),
		target = best.id,
		targetName = best.name,
		ripeAt = best.ripeAt,
		position = best.position
	}
end

-- Returns whether a position lies in the network's rects.
local function inNetworkCoverage(position)
	local rects = self.networkRects
	if rects == nil or #rects == 0 then rects = { coverageRect() } end

	for _, rect in ipairs(rects) do
		if petports_rectContains(rect, position) then return true end
	end

	return false
end

-- Returns the unbroken run of dry tilled tiles reaching out from an anchor, and the liquids they take.
local function waterRunFrom(anchor)
	-- Returns the tilled soil at a tile inside coverage, or nil.
	local function farmlandAt(tile)
		if not inNetworkCoverage({ tile[1] + 0.5, tile[2] + 0.5 }) then
			return nil
		end

		local modName = world.mod({ tile[1], tile[2] }, "foreground")
		if modName == nil then return nil end

		local info = soilInfo(modName)
		if info == nil or not info.tilled then return nil end

		return { mod = tostring(modName), dry = info.dry, wants = info.wants }
	end

	local ordered = { anchor }

	for direction = -1, 1, 2 do
		for step = 1, WATER_RUN_REACH do
			local tile = { anchor[1] + direction * step, anchor[2] }
			if farmlandAt(tile) == nil then break end

			if direction < 0 then
				table.insert(ordered, 1, tile)
			else
				table.insert(ordered, tile)
			end
		end
	end

	local soil = nil
	local tiles = {}

	for _, tile in ipairs(ordered) do
		local here = farmlandAt(tile)

		if here ~= nil and here.dry then
			if soil == nil then soil = here end

			if here.mod == soil.mod then
				table.insert(tiles, tile)
			end
		end
	end

	if soil == nil or #tiles == 0 then return nil end

	return { tiles = tiles, wants = soil.wants, mod = soil.mod }
end

-- Returns every dry soil run under the crops in coverage.
local function waterRuns()
	local runs = {}
	local seen = {}

	for _, crop in ipairs(self.farmables or {}) do
		if world.entityExists(crop.id) then
			local position = world.entityPosition(crop.id)

			local tile = { math.floor(position[1]), math.floor(position[2]) - 1 }
			local key = petports_tileKey(tile)

			if not seen[key] then
				local run = waterRunFrom(tile)

				if run ~= nil then
					seen[key] = true

					for _, t in ipairs(run.tiles) do
						seen[petports_tileKey(t)] = true
					end

					run.key = key
					table.insert(runs, run)
				else
					seen[key] = true
				end
			end
		end
	end

	return runs
end

-- Returns the carried stack that waters a run, with the liquid it matches.
local function carriedWaterFor(run)
	if self.petData == nil or self.petData.cargo == nil then return nil end

	for _, stack in ipairs(self.petData.cargo) do
		for _, want in ipairs(run.wants or {}) do
			if stack.name == want.item then
				return stack, want
			end
		end
	end

	return nil
end

-- Returns whether the unit can stand over a run's first tile.
local function waterRunWorkable(run, tile)
	if run == nil or tile == nil then return false end

	return targetEligible("water run " .. tostring(run.key),
		{ tile[1] + 0.5, tile[2] + 1.5 }, nil)
end

-- Returns a task to water a run from its nearer end, as far as the carried water reaches.
local function waterWork()
	local runs = waterRuns()
	if #runs == 0 then return nil, "no dry soil under any crop in coverage" end

	for _, run in ipairs(runs) do
		local workId = "water:" .. tostring(run.key)
		local failure = self.workFailures[workId]
		local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

		local stack, want = carriedWaterFor(run)

		if stack ~= nil and not backedOff and claimFree(workId) then
			local carried = math.min(stack.count or 1, petportWaterCarry())
			local tiles = {}

			for index = 1, math.min(carried, #run.tiles) do
				table.insert(tiles, run.tiles[index])
			end

			local from = entity.position()
			if self.petId ~= nil and world.entityExists(self.petId) then
				from = world.entityPosition(self.petId)
			end

			local head = world.magnitude(from, run.tiles[1])
			local tail = world.magnitude(from, run.tiles[#run.tiles])

			if tail < head then
				tiles = {}
				for index = 0, math.min(carried, #run.tiles) - 1 do
					table.insert(tiles, run.tiles[#run.tiles - index])
				end
			end

			local runHead = tiles[1]

			if waterRunWorkable(run, runHead) then
				sb.logInfo("PETPORT %s WATER dispatch: %s tile(s) of %s in run, "
					.. "%s carried, from %s to %s",
					stationUniqueId(), sb.printJson(#tiles), sb.printJson(#run.tiles),
					sb.printJson(stack.count or 1), sb.printJson(tiles[1]),
					sb.printJson(tiles[#tiles]))

				return {
					id = workId,
					mediumVerified = true,
					type = "water",
					port = stationUniqueId(),
					tiles = tiles,
					waterIndex = 1,
					item = want.item,
					previousMod = run.mod,
					newMod = want.newMod,
					tint = want.tint,
					position = { runHead[1] + 0.5, runHead[2] + 1.5 }
				}
			end
		end
	end

	return nil, string.format("%s dry run(s), none actionable", #runs)
end


local seedSpacesCache = {}

-- Returns the spaces a seed occupies, cached.
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
		sb.logInfo("PETPORT %s could not read spaces for %s -- assuming 1x2",
			stationUniqueId(), tostring(seedName))
		spaces = { {0, 0}, {0, 1} }
	else
		sb.logInfo("PETPORT %s footprint for %s: %s tile(s) %s",
			stationUniqueId(), tostring(seedName), sb.printJson(#spaces),
			sb.printJson(spaces))
	end

	seedSpacesCache[seedName] = spaces
	return spaces
end

-- Returns the tiles a seed would fill at a position.
local function seedTiles(position, seedName)
	local anchor = { math.floor(position[1]), math.floor(position[2]) }
	local tiles = {}

	for _, space in ipairs(seedSpaces(seedName)) do
		table.insert(tiles, { anchor[1] + space[1], anchor[2] + space[2] })
	end

	return tiles
end

-- Returns whether an object covers any of a set of tiles.
local function objectOccupies(objectId, tiles)
	local spaces = world.objectSpaces(objectId)
	if spaces == nil then return false end

	local origin = world.entityPosition(objectId)
	if origin == nil then return false end

	for _, space in ipairs(spaces) do
		local x = math.floor(origin[1]) + space[1]
		local y = math.floor(origin[2]) + space[2]

		for _, tile in ipairs(tiles) do
			if x == tile[1] and y == tile[2] then return true end
		end
	end

	return false
end

-- Returns whether nothing already stands where a seed would go.
local function replantFootprintClear(position, seedName)
	local tiles = seedTiles(position, seedName)

	local lox, loy = tiles[1][1], tiles[1][2]
	local hix, hiy = lox, loy

	for _, t in ipairs(tiles) do
		lox = math.min(lox, t[1]); hix = math.max(hix, t[1])
		loy = math.min(loy, t[2]); hiy = math.max(hiy, t[2])
	end

	local candidates = world.entityQuery(
		{ lox - 1, loy - 1 }, { hix + 2, hiy + 2 },
		{ includedTypes = { "object" } })

	for _, id in ipairs(candidates or {}) do
		if objectOccupies(id, tiles) then
			sb.logInfo("PETPORT %s footprint for %s at %s BLOCKED by object %s",
				stationUniqueId(), tostring(seedName), sb.printJson(tiles),
				sb.printJson(id))
			return false
		end
	end

	return true
end

-- Returns whether the tile under a replant position is tilled.
local function replantGroundTilled(position)
	local under = world.mod({ position[1], position[2] - 1 }, "foreground")
	local at = world.mod({ position[1], position[2] }, "foreground")

	local info = soilInfo(under)
	local tilled = info ~= nil and info.tilled


	if not tilled then
		sb.logInfo("PETPORT %s replant ground at %s: mod below is %s (tilled %s), "
			.. "mod at is %s -- not farmland",
			stationUniqueId(), sb.printJson(position), tostring(under),
			tostring(info ~= nil and info.tilled), tostring(at))
	end

	return tilled
end

REPLANT_SWEEP_INTERVAL = 5.0

-- Drops replant intents whose footprint filled, whose ground was untilled, or that no port covers.
local function sweepReplants(dt)
	self.replantSweepTimer = (self.replantSweepTimer or 0) - dt
	if self.replantSweepTimer > 0 then return end
	self.replantSweepTimer = REPLANT_SWEEP_INTERVAL

	local intents = petports_replantsAll()

	local outstanding = {}
	for key, intent in pairs(intents) do
		table.insert(outstanding, tostring(key) .. "=" .. tostring(intent.name))
	end
	table.sort(outstanding)

	local signature = table.concat(outstanding, " | ")
	if signature ~= self.replantSignature then
		self.replantSignature = signature
		sb.logInfo("PETPORT %s replant intents outstanding: %s",
			stationUniqueId(), signature == "" and "none" or signature)
	end

	local orphans = {}

	for key, intent in pairs(intents) do
		if type(intent) ~= "table" or type(intent.position) ~= "table" then
			table.insert(orphans, key)
		elseif inNetworkCoverage(intent.position) then
			if not replantFootprintClear(intent.position, intent.name) then
				petports_replantClear(key, "footprint occupied")
			elseif not replantGroundTilled(intent.position) then
				petports_replantClear(key, "ground no longer tilled")
			end
		elseif not petports_anyPortCovers(intent.position) then
			table.insert(orphans, key)
		end
	end

	if #orphans > 0 then
		petports_replantClearMany(orphans, "no port covers the tile")
	end
end

-- Returns the nearest reachable beacon holding a seed.
local function containerWithSeed(seedName, wantDeposit, wantRestock)
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
				if servicePointNear("crate " .. tostring(beacon.id),
					beacon.id, beacon.position, 4) ~= nil then
					return beacon.id
				end
			end
		end
	end

	return nil
end

-- Returns the replant intent a carried seed matches, with the intent's key and the stack.
local function carriedSeedIntent()
	if self.petData == nil or self.petData.cargo == nil then return nil end

	local intents = petports_replantsAll()

	for _, stack in ipairs(self.petData.cargo) do
		for key, intent in pairs(intents) do
			if intent.name ~= nil and stack.name == intent.name
			   and intent.position ~= nil
			   and inNetworkCoverage(intent.position) then
				return key, intent, stack
			end
		end
	end

	if #self.petData.cargo > 0 then
		local held = {}
		for _, stack in ipairs(self.petData.cargo) do
			table.insert(held, tostring(stack.name))
		end

		local wanted = {}
		for key, intent in pairs(intents) do
			table.insert(wanted, string.format("%s@%s%s", tostring(intent.name),
				tostring(key),
				inNetworkCoverage(intent.position or {0, 0}) and "" or " (OUT OF RANGE)"))
		end

		table.sort(held)
		table.sort(wanted)

		local signature = table.concat(held, ",") .. " vs " .. table.concat(wanted, ",")

		if signature ~= self.replantMissSignature then
			self.replantMissSignature = signature
			sb.logInfo("PETPORT %s carrying [%s] but no intent matches: intents are [%s]",
				stationUniqueId(),
				table.concat(held, ", "),
				#wanted > 0 and table.concat(wanted, ", ") or "none")
		end
	end

	return nil
end

-- Returns a task to plant a carried seed at its intent tile, clearing the intent when the tile has filled.
local function replantWork()
	local key, intent = carriedSeedIntent()
	if key == nil then return nil, "no carried seed matches an intent" end

	local failure = self.workFailures["replant:" .. key]
	if failure ~= nil and (failure["until"] or 0) > world.time() then
		return nil, string.format("replant at %s backed off until %s",
			tostring(key), sb.printJson(failure["until"]))
	end

	if not replantFootprintClear(intent.position, intent.name) then
		petports_replantClear(key, "footprint occupied at dispatch")
		return nil, "intent tile is occupied"
	end

	local above = { intent.position[1] + 0.5, intent.position[2] + 1.5 }
	local suits, why = targetSuits(above, nil)

	if not suits then
		targetRefused("replant at " .. tostring(key), why)
		return nil, "replant tile " .. tostring(key) .. " " .. tostring(why)
	end

	sb.logInfo("PETPORT %s REPLANT dispatch: %s back into %s (tile %s)",
		stationUniqueId(), tostring(intent.name), tostring(key),
		sb.printJson(intent.position))

	return {
		id = "replant:" .. key,
		mediumVerified = true,
		type = "replant",
		port = stationUniqueId(),
		target = key,
		seed = intent.name,
		position = { intent.position[1] + 0.5, intent.position[2] + 0.5 },
		tile = intent.position
	}
end

-- Returns a task to fetch water from a beacon for the first dry run the unit can reach.
local function withdrawWaterWork()
	local runs = waterRuns()
	if #runs == 0 then return nil, "no dry soil needing water" end

	local sources = {}

	if petportParticipates("waterrestock") then
		for _, beacon in ipairs(petports_beaconsFor("restock")) do
			table.insert(sources, beacon)
		end
	end

	if petportParticipates("waterdeposit") then
		for _, beacon in ipairs(petports_beaconsFor("deposit")) do
			table.insert(sources, beacon)
		end
	end

	for _, run in ipairs(runs) do
		if carriedWaterFor(run) == nil then
			local workId = "fetchwater:" .. tostring(run.key)
			local failure = self.workFailures[workId]
			local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

			local reachableEnd = waterRunWorkable(run, run.tiles[1])
				or waterRunWorkable(run, run.tiles[#run.tiles])

			if not backedOff and reachableEnd and claimFree(workId)
			   and claimFree("water:" .. tostring(run.key)) then
				local wanted = math.min(#run.tiles, petportWaterCarry())

				for _, want in ipairs(run.wants) do
					for _, beacon in ipairs(sources) do
						if world.entityExists(beacon.id) then
							local available = world.containerAvailable(beacon.id,
								{ name = want.item, count = 1 })

							if type(available) == "number" and available >= 1
								and servicePointNear("crate " .. tostring(beacon.id),
									beacon.id, beacon.position, 4) ~= nil then
								local take = math.min(wanted, available)

								sb.logInfo("PETPORT %s FETCHWATER dispatch: %s x%s "
									.. "from %s for a %s tile run",
									stationUniqueId(), tostring(want.item),
									sb.printJson(take), sb.printJson(beacon.id),
									sb.printJson(#run.tiles))

								return {
									id = workId,
									mediumVerified = true,
									type = "withdraw",
									port = stationUniqueId(),
									target = beacon.id,
									seed = want.item,
									count = take,
									position = world.entityPosition(beacon.id)
								}
							end
						end
					end
				end
			end
		end
	end

	return nil, string.format("%s dry run(s), no liquid in storage for any", #runs)
end

-- Returns the treats worth fetching with their fuel value, the preferred flavor first.
local function fuelTreatOrder(preferred)
  local wanted = {}

  if preferred ~= nil then
    local item = petports_flavorItem(preferred)
    if item ~= nil then
      table.insert(wanted, { name = item, value = PETPORTS_FUEL_PREFERRED })
    end
  end

  for _, flavor in ipairs(petports_flavors()) do
    local item = petports_flavorItem(flavor.id)
    if item ~= nil and flavor.id ~= preferred and flavor.preference ~= false then
      table.insert(wanted, { name = item, value = PETPORTS_FUEL_PLAIN })
    end
  end

  table.insert(wanted, { name = "petports_petfuel", value = PETPORTS_FUEL_PLAIN })

  return wanted
end

FUEL_MEAL_LIMIT = 32

-- Returns whether an item is tagged as fuel.
local function isTreat(name)
	if type(name) ~= "string" then return false end
	local ok, tagged = pcall(root.itemHasTag, name, "petports_fuel")
	return ok and tagged == true
end

-- Feeds the unit treats out of its own cargo while its fuel is low, preferring its own flavor.
local function nibbleFromCargo()
	if self.petId == nil or not world.entityExists(self.petId) then return end
	if not petportFuelWanted() then return end
	if self.petData == nil or type(self.petData.cargo) ~= "table" then return end
	if #self.petData.cargo == 0 then return end

	local preferred = petportUnitFlavor()
	local preferredItem = preferred ~= nil and petports_flavorItem(preferred) or nil

	local held = {}

	for _, stack in ipairs(self.petData.cargo) do
		if isTreat(stack.name) then
			table.insert(held, stack.name)
		end
	end

	if #held == 0 then return end

	table.sort(held, function(a, b)
		if a == preferredItem then return b ~= preferredItem end
		if b == preferredItem then return false end
		return a < b
	end)

	local meals = 0

	for _, name in ipairs(held) do
		local hungry = true

		while hungry and meals < FUEL_MEAL_LIMIT do
			local index, stack = nil, nil

			for i, candidate in ipairs(self.petData.cargo) do
				if candidate.name == name then
					index, stack = i, candidate
					break
				end
			end

			if stack == nil then break end

			local item = { name = stack.name, count = 1,
				parameters = stack.parameters }

			local okFeed, meal = pcall(world.callScriptedEntity, self.petId,
				"petports_feedFuel", item, true)

			if okFeed and type(meal) == "table"
			   and (tonumber(meal.amount) or 0) > 0 then
				countFed(meal.flavor)
				meals = meals + 1

				local count = (stack.count or 1) - 1
				if count <= 0 then
					table.remove(self.petData.cargo, index)
				else
					stack.count = count
				end
			else
				hungry = false
			end
		end

		if meals >= FUEL_MEAL_LIMIT then break end
	end

	if meals > 0 then
		sb.logInfo("PETPORT %s unit ate %s treat(s) out of its own cargo "
			.. "(%s stack(s) still held)",
			stationUniqueId(), sb.printJson(meals),
			sb.printJson(#self.petData.cargo))

		flushCargo()
	end
end

-- Feeds the unit treats out of a crate until it is full or the meal limit is reached.
function feedFromCrate(containerId, treatName, workId, slot)
  if containerId == nil or treatName == nil then return end
  if not world.entityExists(containerId) then return end

  local preferred = petportUnitFlavor()
  local order     = fuelTreatOrder(preferred)

  table.insert(order, 1, { name = treatName, value = PETPORTS_FUEL_PLAIN })

  local meals, seen = 0, {}

  for _, treat in ipairs(order) do
    if not seen[treat.name] then
      seen[treat.name] = true

      local hungry = true

      while hungry and meals < FUEL_MEAL_LIMIT do
        local item = { name = treat.name, count = 1 }

        local okTake, taken

        if slot == nil then
          okTake, taken = pcall(world.containerConsume, containerId, item)
          taken = okTake and taken == true
        else
          local okAt, at = pcall(world.containerItemAt, containerId, slot)

          if okAt and type(at) == "table" and at.name == treat.name then
            local okOne, one = pcall(world.containerTakeNumItemsAt,
              containerId, slot, 1)

            taken = okOne and type(one) == "table" and (one.count or 0) >= 1
          else
            taken = false
          end
        end

        if not taken then break end

        local okFeed, meal = pcall(world.callScriptedEntity, self.petId,
          "petports_feedFuel", item, true)

        if okFeed and type(meal) == "table"
           and (tonumber(meal.amount) or 0) > 0 then
          countFed(meal.flavor)
          meals = meals + 1
        else
          hungry = false

          local okBack, left

          if slot == nil then
            okBack, left = pcall(world.containerAddItems, containerId, item)
          else
            okBack, left = pcall(world.containerPutItemsAt, containerId, item, slot)
          end

          if not okBack or (type(left) == "table" and (left.count or 0) > 0) then
            sb.logError("PETPORT %s could not return %s to crate %s after a "
              .. "refused feed -- one treat lost", stationUniqueId(),
              tostring(treat.name), tostring(containerId))
          end

          break
        end
      end

      if not hungry then break end
    end
  end

  if meals == 0 then
    sb.logInfo("PETPORT %s fuel fetch %s: crate held nothing this unit would eat",
      stationUniqueId(), tostring(workId))
    return
  end

  sb.logInfo("PETPORT %s fed unit %s treat(s) from crate %s",
    stationUniqueId(), tostring(meals), tostring(containerId))
end

-- Returns a task to fetch a treat from a feeder crate or an upcycler's output while the unit is hungry.
local function fuelFetchWork()
  if not petportFuelWanted() then
    return nil, "unit is above the fuel low-water mark"
  end

  local headroom = petportFuelHeadroom()
  if headroom == nil then return nil, "no fuel reading for the unit" end

  local preferred = petportUnitFlavor()
  local crates    = 0

  local wanted = fuelTreatOrder(preferred)

  for _, treat in ipairs(wanted) do

    if treat.value <= headroom then
      for _, behavior in ipairs({ "deposit", "restock" }) do
        for _, beacon in ipairs(petports_beaconsFor(behavior)) do
          if beacon.feeder ~= false and world.entityExists(beacon.id) then
            crates = crates + 1

            local workId = "fuelfetch:" .. tostring(beacon.id) .. ":" .. treat.name
            local failure = self.workFailures[workId]
            local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

            if not backedOff and claimFree(workId) then
              local available = world.containerAvailable(beacon.id,
                { name = treat.name, count = 1 })

              if type(available) == "number" and available >= 1
                 and servicePointNear("feeder " .. tostring(beacon.id),
                   beacon.id, beacon.position, 4) ~= nil then
                return {
                  id = workId,
                  mediumVerified = true,
                  type = "fuelfetch",
                  port = stationUniqueId(),
                  target = beacon.id,
                  treat = treat.name,
                  position = world.entityPosition(beacon.id)
                }
              end
            end
          end
        end
      end
    end
  end

  for _, treat in ipairs(wanted) do
    if treat.value <= headroom then
      for _, machine in ipairs(self.machines or {}) do
        if machine.kind == "upcycler" and machine.feeder
           and world.entityExists(machine.id) then

          crates = crates + 1

          local workId = "fuelfetch:" .. tostring(machine.id) .. ":" .. treat.name
          local failure = self.workFailures[workId]
          local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

          if not backedOff and claimFree(workId) then
            local okAt, at = pcall(world.containerItemAt, machine.id,
              MACHINE_SLOT_OUTPUT)

            if okAt and type(at) == "table" and at.name == treat.name
               and (at.count or 0) >= 1
               and servicePointNear("feeder " .. tostring(machine.id),
                 machine.id, machine.position, 4) ~= nil then

              return {
                id = workId,
                mediumVerified = true,
                type = "fuelfetch",
                port = stationUniqueId(),
                target = machine.id,
                treat = treat.name,

                feedSlot = MACHINE_SLOT_OUTPUT,
                position = world.entityPosition(machine.id)
              }
            end
          end
        end
      end
    end
  end

  if crates == 0 then
    return nil, "no container or machine in the network is marked as a pet feeder"
  end

  return nil, string.format(
    "%s feeder source(s), none holding a treat this unit can use (headroom %s)",
    crates, tostring(math.floor(headroom)))
end

-- Returns a task to pick up the nearest treat lying in coverage while the unit is hungry.
local function fuelGroundWork()
  if not petportFuelWanted() then
    return nil, "unit is above the fuel low-water mark"
  end

  if self.petData ~= nil and type(self.petData.cargo) == "table"
     and #self.petData.cargo > 0 then
    return nil, "hungry, but carrying a load -- putting that down first"
  end

  local rects = self.networkRects
  if rects == nil or #rects == 0 then rects = { coverageRect() } end

  local from = entity.position()
  if self.petId ~= nil and world.entityExists(self.petId) then
    from = world.entityPosition(self.petId)
  end

  local best, bestDistance = nil, nil
  local seen = {}
  local treats, rejected = 0, { claimed = 0, backedOff = 0, gone = 0, medium = 0 }

  for _, area in ipairs(rects) do
    local found = world.entityQuery({ area[1], area[2] }, { area[3], area[4] }, {
      includedTypes = { "itemDrop" }
    })

    for _, dropId in ipairs(found or {}) do
      if not seen[dropId] then
        seen[dropId] = true

        local okItem, descriptor = pcall(world.itemDropItem, dropId)

        if okItem and type(descriptor) == "table" and isTreat(descriptor.name) then
          treats = treats + 1

          local workId = "drop:" .. tostring(dropId)
          local failure = self.workFailures[workId]
          local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

          if backedOff then
            rejected.backedOff = rejected.backedOff + 1
          elseif not claimFree(workId) then
            rejected.claimed = rejected.claimed + 1
          elseif not world.entityExists(dropId) then
            rejected.gone = rejected.gone + 1
          else
            local position = world.entityPosition(dropId)

            if not targetEligible("treat " .. tostring(dropId), position, dropId) then
              rejected.medium = rejected.medium + 1
            else
              local distance = world.magnitude(from, position)

              if bestDistance == nil or distance < bestDistance then
                best, bestDistance = dropId, distance
              end
            end
          end
        end
      end
    end
  end

  if best == nil then
    if treats == 0 then
      return nil, "hungry, and no treat on the ground in network coverage"
    end

    return nil, string.format(
      "hungry, %s treat(s) on the ground, none reachable: %s claimed, "
      .. "%s backed off, %s gone, %s in a medium this chassis cannot work in",
      treats, rejected.claimed, rejected.backedOff, rejected.gone,
      rejected.medium)
  end

  sb.logInfo("PETPORT %s hungry unit going for a treat on the ground at %s, "
    .. "%s away (%s treat(s) in coverage)",
    stationUniqueId(), sb.printJson(world.entityPosition(best)),
    sb.printJson(bestDistance), sb.printJson(treats))

  return {
    id = "drop:" .. best,
    mediumVerified = true,
    type = "collect",
    port = stationUniqueId(),
    target = best,
    position = world.entityPosition(best)
  }
end

-- Returns a task to fetch the seed a replant intent needs from storage.
local function withdrawWork()
	if carriedSeedIntent() ~= nil then
		return nil, "unit is already carrying a seed for an intent"
	end

	local intents = petports_replantsAll()
	local wanted = 0

	local wrongMedium = 0

	for key, intent in pairs(intents) do
		if intent.name ~= nil and intent.position ~= nil
		   and inNetworkCoverage(intent.position) then
			wanted = wanted + 1

			local workId = "withdraw:" .. key
			local failure = self.workFailures[workId]
			local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

			local placeFailure = self.workFailures["replant:" .. key]
			local placeBackedOff = placeFailure ~= nil
				and (placeFailure["until"] or 0) > world.time()

			if placeBackedOff then backedOff = true end

			local placeAbove = { intent.position[1] + 0.5, intent.position[2] + 1.5 }

			local free = not backedOff
				and claimFree(workId)
				and claimFree("replant:" .. key)

			if free and not targetEligible("replant at " .. tostring(key),
				placeAbove, nil) then
				wrongMedium = wrongMedium + 1
				free = false
			end

			if free then
				local containerId = containerWithSeed(intent.name,
					petportParticipates("farmdeposit"),
					petportParticipates("farmrestock"))

				if containerId ~= nil then
					return {
						id = "withdraw:" .. key,
						mediumVerified = true,
						type = "withdraw",
						port = stationUniqueId(),
						target = containerId,
						seed = intent.name,
						intent = key,
						position = world.entityPosition(containerId)
					}
				end
			end
		end
	end

	if wanted == 0 then
		return nil, "no replant intents in network coverage"
	end

	return nil, string.format(
		"%s replant intent(s), none actionable (no seed in storage, claimed, "
		.. "or the replant leg has backed off); %s in a medium this chassis "
		.. "cannot work in",
		wanted, wrongMedium)
end


-- Returns how much of an item a container holds.
local function restockHeld(containerId, name)
  if not world.entityExists(containerId) then return nil end

  local ok, items = pcall(world.containerItems, containerId)
  if not ok or type(items) ~= "table" then return nil end

  local total = 0

  for _, stack in pairs(items) do
    if type(stack) == "table" and stack.name == name then
      total = total + (stack.count or 1)
    end
  end

  return total
end

-- Returns the live restock beacons that carry requests.
local function restockBeacons()
  local out = {}

  for _, beacon in ipairs(petports_beaconsFor("restock")) do
    if beacon.requests ~= nil and world.entityExists(beacon.id) then
      table.insert(out, beacon)
    end
  end

  return out
end

-- Returns a task to fetch a medkit, or to dose the first reachable patient.
local function medicWork(preloadOnly)
  if petportOblivious() then return nil, "oblivious" end
  if not petportMedic() then return nil, "no medic module socketed" end

  local carried = petportMedkit()

  -- Returns a task to fetch a dose from storage, or nil with the reason.
  local function fetchDose()
    local containerId = containerWithSeed(MEDIC_ITEM,
      petportParticipates("medicdeposit"),
      petportParticipates("medicrestock"))

    if containerId == nil then
      return nil, string.format(
        "no %s in network storage this unit can reach", MEDIC_ITEM)
    end

    local fetchId = "medicfetch:" .. stationUniqueId()
    local failure = self.workFailures[fetchId]

    if failure ~= nil and (failure["until"] or 0) > world.time() then
      return nil, "medic fetch backed off"
    end

    sb.logInfo("PETPORT %s MEDIC fetch: collecting one %s from %s",
      stationUniqueId(), tostring(MEDIC_ITEM), sb.printJson(containerId))

    return {
      id = fetchId,
      mediumVerified = true,
      type = "withdraw",
      port = stationUniqueId(),
      target = containerId,
      seed = MEDIC_ITEM,
      position = world.entityPosition(containerId)
    }
  end

  if preloadOnly then
    if carried ~= nil then return nil, "a dose is already held" end
    return fetchDose()
  end

  local patients = medicPatients()
  if #patients == 0 then
    return nil, string.format("no treatable patient in network coverage (%s rects)",
      #(self.networkRects or {}))
  end

  if carried == nil then
    local task, why = fetchDose()

    if task == nil then
      return nil, string.format("%s patient(s) waiting, but %s",
        #patients, tostring(why))
    end

    return task
  end

  for _, patient in ipairs(patients) do
    local workId = petports_healWorkId(patient.id)
    local failure = self.workFailures[workId]
    local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

    if not backedOff and claimFree(workId) then
      local stand = standingPointNear(patient.position, MEDIC_REACH)

      if stand ~= nil then
        sb.logInfo("PETPORT %s MEDIC dispatch: patient %s class %s at %s pct "
          .. "health, approach %s",
          stationUniqueId(), sb.printJson(patient.id), patient.class,
          sb.printJson(math.floor(patient.ratio * 100)), sb.printJson(stand))

        return {
          id = workId,
          type = "medic",
          port = stationUniqueId(),

          target = patient.id,
          patientClass = patient.class,

          item = MEDIC_ITEM,
          effect = MEDIC_EFFECT,
          duration = MEDIC_DURATION,
          projectile = MEDIC_PROJECTILE,

          position = stand
        }
      end

      sb.logInfo("PETPORT %s MEDIC patient %s SKIPPED: no standable spot within %s tiles of %s",
        stationUniqueId(), sb.printJson(patient.id), sb.printJson(MEDIC_REACH),
        sb.printJson(patient.position))
    end
  end

  return nil, string.format("%s patient(s), none actionable", #patients)
end

-- Returns a task to deliver carried cargo into a restock beacon that is short of it.
local function restockDeliverWork()
  if self.petData == nil or self.petData.cargo == nil then return nil end
  if #self.petData.cargo == 0 then return nil end

  local beacons = restockBeacons()
  if #beacons == 0 then return nil end

  for _, beacon in ipairs(beacons) do
    for _, request in ipairs(beacon.requests) do
      local carried = nil
      for _, stack in ipairs(self.petData.cargo) do
        if stack.name == request.item then
          carried = stack
          break
        end
      end

      if carried ~= nil then
        local have = restockHeld(beacon.id, request.item)

        if have ~= nil and have < request.max then
          local fits = world.containerItemsCanFit ~= nil
            and world.containerItemsCanFit(beacon.id, carried) or nil

          if fits == nil or fits > 0 then
            local stand, standWhy = servicePointNear("request crate " .. tostring(beacon.id),
              beacon.id, beacon.position, 4)

            if stand == nil then
              sb.logInfo("PETPORT %s restock delivery to %s SKIPPED: %s of %s",
                stationUniqueId(), sb.printJson(beacon.id), tostring(standWhy),
                sb.printJson(beacon.position))
            else
              sb.logInfo("PETPORT %s delivering %s x%s to request crate %s (has %s of %s)",
                stationUniqueId(), tostring(request.item),
                sb.printJson(carried.count or 1), sb.printJson(beacon.id),
                sb.printJson(have), sb.printJson(request.max))

              return {
                id = "restockput:" .. tostring(beacon.id)
                  .. ":" .. tostring(request.item) .. "@" .. stationUniqueId(),
                mediumVerified = true,
                type = "deposit",
                target = beacon.id,

                only = request.item,

                position = stand,
                containerPosition = beacon.position,
                port = stationUniqueId(),
                dwell = 0
              }
            end
          end
        end
      end
    end
  end

  return nil
end

-- Returns a task to fetch stock from a deposit crate for a restock beacon that has fallen below its minimum.
local function restockFetchWork()
  local beacons = restockBeacons()
  if #beacons == 0 then return nil, "no configured restock beacon in coverage" end

  local short, unstocked, noRoom, unreachable = 0, 0, 0, 0

  for _, beacon in ipairs(beacons) do
    if servicePointNear("request crate " .. tostring(beacon.id),
       beacon.id, beacon.position, 4) == nil then
      unreachable = unreachable + 1

      if self.lastRestockSkip ~= beacon.id then
        self.lastRestockSkip = beacon.id
        sb.logInfo("PETPORT %s NOT restocking %s at %s: this unit cannot reach the request "
          .. "crate, so fetching for it would only cycle stock in and out of storage",
          stationUniqueId(), sb.printJson(beacon.id), sb.printJson(beacon.position))
      end

    else
    for _, request in ipairs(beacon.requests) do
      local have = restockHeld(beacon.id, request.item)

      if have ~= nil and have < request.min then
        local want = request.max - have

        if want > 0 then
          short = short + 1

          local workId = "restock:" .. tostring(beacon.id)
            .. ":" .. tostring(request.item)

          local failure = self.workFailures[workId]
          local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

          if not backedOff and claimFree(workId) then
            local source, available = nil, 0

            for _, crate in ipairs(petports_beaconsFor("deposit")) do
              if world.entityExists(crate.id) then
                local n = world.containerAvailable(crate.id,
                  { name = request.item, count = 1 })

                if type(n) == "number" and n >= 1 then
                  if servicePointNear("crate " .. tostring(crate.id),
                     crate.id, crate.position, 4) == nil then
                    if self.lastRestockSourceSkip ~= crate.id then
                      self.lastRestockSourceSkip = crate.id
                      sb.logInfo("PETPORT %s restock source %s at %s SKIPPED: holds %s but "
                        .. "this unit cannot reach it -- looking for another source",
                        stationUniqueId(), sb.printJson(crate.id),
                        sb.printJson(crate.position), tostring(request.item))
                    end
                  else
                    source = crate
                    available = n
                    break
                  end
                end
              end
            end

            if source == nil then
              unstocked = unstocked + 1
            else
              local count = math.min(want, available, stackSizeOf(request.item))

              local fits = world.containerItemsCanFit ~= nil
                and world.containerItemsCanFit(beacon.id,
                  { name = request.item, count = count }) or nil

              if fits ~= nil and fits <= 0 then
                noRoom = noRoom + 1
              else
                sb.logInfo("PETPORT %s RESTOCK dispatch: %s x%s from %s for crate %s (has %s, wants %s-%s)",
                  stationUniqueId(), tostring(request.item), sb.printJson(count),
                  sb.printJson(source.id), sb.printJson(beacon.id),
                  sb.printJson(have), sb.printJson(request.min),
                  sb.printJson(request.max))

                return {
                  id = workId,
                  mediumVerified = true,
                  type = "withdraw",
                  port = stationUniqueId(),
                  target = source.id,

                  seed = request.item,
                  count = count,

                  position = world.entityPosition(source.id)
                }
              end
            end
          end
        end
      end
    end
    end
  end

  if short == 0 then
    return nil, "every restock request is at or above its minimum"
  end

  return nil, string.format(
    "%s restock request(s) short, none actionable: %s with none in storage, "
    .. "%s with the request crate full, %s with an unreachable request crate",
    short, unstocked, noRoom, unreachable)
end

-- Returns the crates this unit is allowed to tidy out of.
local function tidySources(wantDeposit, wantRestock)
  local sources = {}

  if wantDeposit then
    for _, beacon in ipairs(petports_beaconsFor("deposit")) do
      table.insert(sources, beacon)
    end
  end

  if wantRestock then
    for _, beacon in ipairs(petports_beaconsFor("restock")) do
      if beacon.requests ~= nil then
        table.insert(sources, beacon)
      end
    end
  end

  return sources
end

-- Returns a task to move the most valuable misfiled stack out of a crate into one that accepts it.
local function tidyWork(doDeposit, doRestock)
  local destinations = petports_beaconsFor("deposit")

  if #destinations == 0 then
    return nil, "no deposit beacon to tidy into"
  end

  local sources = tidySources(doDeposit, doRestock)

  if #sources == 0 then
    return nil, "no crate this unit is allowed to tidy"
  end

  local misfiled, homeless, full = 0, 0, 0

  local viable = {}

  for _, source in ipairs(sources) do
    if world.entityExists(source.id) then
      local items = world.containerItems(source.id)

      if type(items) == "table" then
        local misfits

        if source.behavior == "restock" then
          misfits = petports_restockMisfits(source.requests, items,
            source.beaconSlot)
        else
          misfits = petports_filterMisfits(source.filter, items,
            source.beaconSlot)
        end

        for _, misfit in ipairs(misfits) do
          misfiled = misfiled + 1

          local workId = "tidy:" .. tostring(source.id)
            .. ":" .. tostring(misfit.name)

          local failure = self.workFailures[workId]
          local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

          if not backedOff and claimFree(workId) then
            local stack = items[misfit.slot]
            local accepted, roomFor = false, false

            for _, destination in ipairs(destinations) do
              if destination.id ~= source.id
                 and world.entityExists(destination.id)
                 and petports_filterAccepts(destination.filter, misfit.name) then
                accepted = true

                local fits = world.containerItemsCanFit ~= nil
                  and world.containerItemsCanFit(destination.id, stack) or nil

                if fits ~= nil and fits > 0 then
                  roomFor = true
                  break
                end
              end
            end

            if not accepted then
              homeless = homeless + 1
            elseif not roomFor then
              full = full + 1
            else
              table.insert(viable, {
                workId = workId,
                source = source,
                name = misfit.name,
                count = misfit.count,
                slot = misfit.slot,

                unitValue = type(stack) == "table"
                  and petports_itemValue(stack) or 0
              })
            end
          end
        end
      end
    end
  end

  table.sort(viable, function(a, b)
    if a.unitValue ~= b.unitValue then return a.unitValue > b.unitValue end
    if a.source.id ~= b.source.id then return a.source.id < b.source.id end
    return (a.slot or 0) < (b.slot or 0)
  end)

  for _, pick in ipairs(viable) do
    local source = pick.source

    local stand, standWhy = servicePointNear("crate " .. tostring(source.id),
      source.id, source.position, 4)

    if stand == nil then
      sb.logInfo("PETPORT %s tidy source %s SKIPPED: %s of %s",
        stationUniqueId(), sb.printJson(source.id), tostring(standWhy),
        sb.printJson(source.position))
    else
      sb.logInfo("PETPORT %s tidying %s x%s out of %s (slot %s, %s each, "
        .. "%s viable candidate(s))",
        stationUniqueId(), tostring(pick.name), sb.printJson(pick.count),
        sb.printJson(source.id), sb.printJson(pick.slot),
        sb.printJson(pick.unitValue), sb.printJson(#viable))

      return {
        id = pick.workId,
        mediumVerified = true,
        type = "tidy",
        target = source.id,
        item = pick.name,
        count = pick.count,
        slot = pick.slot,
        position = stand,
        containerPosition = source.position,
        port = stationUniqueId(),
        dwell = 0
      }
    end
  end

  if misfiled == 0 then
    return nil, "nothing misfiled in coverage"
  end

  return nil, string.format(
    "%s misfiled stack(s), none actionable: %s with no crate that wants them, "
    .. "%s with the right crate full",
    misfiled, homeless, full)
end

-- Returns a task to move over-quota stock out of storage into the upcycler with the most input room.
local function drainWork()
  if self.petData == nil then return nil end
  if self.petData.cargo ~= nil and #self.petData.cargo > 0 then return nil end

  local sources = petports_beaconsFor("deposit")
  if #sources == 0 then return nil, "no deposit beacon to drain from" end

  local overQuota = 0
  local dribbled = 0

  local ranked = {}

  for _, machine in ipairs(self.machines or {}) do
    if machine.kind == "upcycler" and machine.enabled
       and world.entityExists(machine.id) then

      local reachable = servicePointNear("upcycler " .. tostring(machine.id),
        machine.id, machine.position, 4)

      if reachable == nil then
        if self.lastDrainSkip ~= machine.id then
          self.lastDrainSkip = machine.id
          sb.logInfo("PETPORT %s NOT draining for %s at %s: this unit cannot reach the "
            .. "machine, so fetching its input would only cycle stock in and out of storage",
            stationUniqueId(), sb.printJson(machine.id), sb.printJson(machine.position))
        end
      else
        table.insert(ranked, {
          machine = machine,
          free = machineInputFree(machine.id)
        })
      end
    end
  end

  table.sort(ranked, function(a, b) return a.free > b.free end)

  for _, entry in ipairs(ranked) do
    local machine = entry.machine

    do

      local queue = {}

      for index, rule in ipairs(machine.rules) do
        local held = (self.census or {})[rule.item] or 0
        local surplus = held - rule.max

        if surplus > 0 then
          overQuota = overQuota + 1

          local room = machineRuleRoom(machine, rule,
            { name = rule.item, count = 1 })

          local batch = math.min(
            math.ceil(stackSizeOf(rule.item) * MACHINE_MIN_BATCH), surplus)

          if room < batch then
            dribbled = dribbled + 1
            room = 0
          end

          if room > 0 then
            table.insert(queue, {
              rule = rule,
              index = index,
              room = room,
              batch = batch,

              held = held,
              surplus = surplus,
              worth = petports_itemValue({ name = rule.item })
                * math.min(room, batch)
            })
          end
        end
      end

      table.sort(queue, function(a, b)
        if a.worth ~= b.worth then return a.worth > b.worth end
        return a.index < b.index
      end)

      for _, queued in ipairs(queue) do
        local rule = queued.rule
        local room = queued.room
        local batch = queued.batch
        local held = queued.held
        local surplus = queued.surplus

        do
          do
            for _, source in ipairs(sources) do
              if world.entityExists(source.id) then
                local ok, items = pcall(world.containerItems, source.id)

                if ok and type(items) == "table" then
                  for slot, stack in pairs(items) do
                    if slot ~= source.beaconSlot
                       and type(stack) == "table"
                       and stack.name == rule.item then

                      local count = math.min(surplus, stack.count or 0, room,
                        machineRuleRoom(machine, rule, stack))

                      if count > 0 then
                        local workId = "drain:" .. tostring(machine.id)
                          .. ":" .. tostring(rule.item)

                        local failure = self.workFailures[workId]
                        local backedOff = failure ~= nil
                          and (failure["until"] or 0) > world.time()

                        if not backedOff and claimFree(workId) then
                          local stand, standWhy = servicePointNear("crate " .. tostring(source.id),
                            source.id, source.position, 4)

                          if stand == nil then
                            sb.logInfo("PETPORT %s drain source %s SKIPPED: %s of %s",
                              stationUniqueId(), sb.printJson(source.id), tostring(standWhy),
                              sb.printJson(source.position))
                          else
                            sb.logInfo("PETPORT %s draining %s x%s out of %s (slot %s) for %s at %s -- network holds %s, threshold %s, machine input room %s",
                              stationUniqueId(), tostring(rule.item),
                              sb.printJson(count), sb.printJson(source.id),
                              sb.printJson(slot), tostring(machine.kind),
                              sb.printJson(machine.position), sb.printJson(held),
                              sb.printJson(rule.max), sb.printJson(room))

                            return {
                              id = workId,

                              mediumVerified = true,
                              type = "drain",
                              target = source.id,
                              item = rule.item,
                              count = count,
                              slot = slot,
                              position = stand,
                              containerPosition = source.position,
                              port = stationUniqueId(),
                              dwell = 0
                            }
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  if overQuota == 0 then
    return nil, "nothing over an upcycler threshold"
  end

  if dribbled > 0 then
    return nil, string.format(
      "%s rule(s) over threshold, %s waiting for a machine to burn through "
      .. "enough input to be worth a trip", overQuota, dribbled)
  end

  return nil, string.format(
    "%s rule(s) over threshold, none actionable: no deposit crate holds the "
    .. "item, or every machine input is full", overQuota)
end

MACHINE_SLOT_OUTPUT = 2
MACHINE_FUEL_ITEM = "petports_petfuel"

MACHINE_FUEL_TAG = "petports_fuel"

local fuelItemCache = {}

-- Returns whether an item carries the machine fuel tag, cached.
local function isFuelItem(name)
  if type(name) ~= "string" then return false end
  if fuelItemCache[name] ~= nil then return fuelItemCache[name] end

  local verdict = false
  local ok, resolved = pcall(root.itemConfig, { name = name, count = 1 })

  if ok and type(resolved) == "table" and type(resolved.config) == "table" then
    for _, tag in ipairs(resolved.config.itemTags or {}) do
      if tag == MACHINE_FUEL_TAG then verdict = true break end
    end
  end

  fuelItemCache[name] = verdict
  return verdict
end

-- Returns a task to clear an upcycler's output slot into a deposit or restock beacon.
local function fuelWork()
  if self.petData == nil then return nil end
  if self.petData.cargo ~= nil and #self.petData.cargo > 0 then return nil end

  local destinations = petports_beaconsFor("deposit")
  local requesters = restockBeacons()

  if #destinations == 0 and #requesters == 0 then
    return nil, "no deposit or restock beacon to store fuel in"
  end

  local waiting = 0
  local trickling = 0

  local unfilteredNames = {}
  local unroomyNames = {}
  local refusedSeen = {}

  for _, machine in ipairs(self.machines or {}) do
    if machine.kind == "upcycler" and world.entityExists(machine.id) then
      local ok, held = pcall(world.containerItemAt, machine.id, MACHINE_SLOT_OUTPUT)

      if ok and type(held) == "table" and type(held.name) == "string"
         and (held.count or 0) > 0 then
        local isFuel = isFuelItem(held.name)

        waiting = waiting + 1

        local batch = math.ceil(stackSizeOf(held.name) * MACHINE_MIN_BATCH)
        local full = (held.count or 0) >= stackSizeOf(held.name)

        local okInput, input = pcall(world.containerItemAt, machine.id,
          MACHINE_SLOT_INPUT)
        local inputEmpty = not okInput or type(input) ~= "table" or input.name == nil

        local okReagent, reagent = pcall(world.containerItemAt, machine.id,
          MACHINE_SLOT_REAGENT)
        local reagentEmpty = not okReagent or type(reagent) ~= "table" or reagent.name == nil

        local feeding = false

        if inputEmpty and not reagentEmpty then
          for _, rule in ipairs(machine.rules) do
            if rule.item == reagent.name and rule.burn ~= false
               and rule.reagent ~= false then
              feeding = true
              break
            end
          end
        end

        -- A plain treat with no charge banked and no reagent to make one will never reach the output.
        local okBlips, blips = pcall(world.getObjectParameter, machine.id,
          "petports_upcyclerBlips")

        local starved = not inputEmpty and reagentEmpty
          and okBlips and (type(blips) ~= "table" or #blips == 0)
          and petports_upcyclerPlainTreat(input.name)

        local idle = (inputEmpty and not feeding) or starved

        local okBlocked, blocked = pcall(world.getObjectParameter, machine.id,
          "petports_upcyclerBlocked")

        local stalled = okBlocked and blocked == true

        local worthTaking = not isFuel
          or (held.count or 0) >= batch or full or idle or stalled

        if not worthTaking then trickling = trickling + 1 end

        local anyFilterAccepts = false

        local wanted = false

        for _, destination in ipairs(worthTaking and destinations or {}) do
          if world.entityExists(destination.id)
             and petports_filterAccepts(destination.filter, held.name) then

            anyFilterAccepts = true

            local fits = world.containerItemsCanFit ~= nil
              and world.containerItemsCanFit(destination.id, held) or nil

            if fits ~= nil and fits > 0 then
              wanted = true
              break
            end
          end
        end

        if not wanted then
          for _, crate in ipairs(worthTaking and requesters or {}) do
            for _, request in ipairs(crate.requests or {}) do
              if request.item == held.name then
                anyFilterAccepts = true

                local have = restockHeld(crate.id, request.item)
                local fits = world.containerItemsCanFit ~= nil
                  and world.containerItemsCanFit(crate.id, held) or nil

                if have ~= nil and have < request.max
                   and (fits == nil or fits > 0) then
                  wanted = true
                  break
                end
              end
            end

            if wanted then break end
          end
        end

        if wanted then
          local workId = "fuel:" .. tostring(machine.id)

          local failure = self.workFailures[workId]
          local backedOff = failure ~= nil
            and (failure["until"] or 0) > world.time()

          if not backedOff and claimFree(workId) then
            local stand, standWhy = servicePointNear("machine " .. tostring(machine.id),
              machine.id, machine.position, 4)

            if stand == nil then
              sb.logInfo("PETPORT %s fuel source %s SKIPPED: %s of %s",
                stationUniqueId(), sb.printJson(machine.id), tostring(standWhy),
                sb.printJson(machine.position))
            else
              sb.logInfo("PETPORT %s collecting %s %s from machine %s",
                stationUniqueId(), sb.printJson(held.count),
                tostring(held.name), sb.printJson(machine.id))

              return {
                id = workId,
                mediumVerified = true,
                type = "fuel",
                target = machine.id,
                item = held.name,
                count = held.count,

                slot = MACHINE_SLOT_OUTPUT - SLOT_KEY_TO_OFFSET,
                position = stand,
                containerPosition = machine.position,
                port = stationUniqueId(),
                dwell = 0
              }
            end
          end
        end

        if worthTaking and not refusedSeen[held.name] then
          refusedSeen[held.name] = true

          if anyFilterAccepts then
            table.insert(unroomyNames, held.name)
          else
            table.insert(unfilteredNames, held.name)
          end
        end
      end
    end
  end

  if waiting == 0 then
    return nil, "no machine has anything in its output slot"
  end

  if trickling > 0 then
    return nil, string.format(
      "%s machine(s) with output, %s still converting and not yet worth a trip",
      waiting, trickling)
  end

  local parts = {}

  if #unfilteredNames > 0 then
    table.insert(parts, string.format(
      "no deposit or restock beacon accepts %s",
      table.concat(unfilteredNames, ", ")))
  end

  if #unroomyNames > 0 then
    table.insert(parts, string.format(
      "every crate that accepts %s is full or already at its quota",
      table.concat(unroomyNames, ", ")))
  end

  if #parts == 0 then
    table.insert(parts, "nothing was classified, which is a bug in drainWork")
  end

  return nil, string.format("%s machine(s) with output, but %s",
    waiting, table.concat(parts, "; and "))
end

-- Returns a task to merge the split stacks in the first crate that has any.
local function compactWork()
  for _, source in ipairs(tidySources(true, true)) do
    if world.entityExists(source.id) then
      local ok, items = pcall(world.containerItems, source.id)

      if ok and type(items) == "table" then
        local split = fragmentation(items)

        if #split > 0 then
          local workId = "compact:" .. tostring(source.id)

          local failure = self.workFailures[workId]
          local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

          if not backedOff and claimFree(workId) then
            local stand, standWhy = servicePointNear("crate " .. tostring(source.id),
              source.id, source.position, 4)

            if stand == nil then
              sb.logInfo("PETPORT %s compaction of %s SKIPPED: %s of %s",
                stationUniqueId(), sb.printJson(source.id), tostring(standWhy),
                sb.printJson(source.position))
            else
              sb.logInfo("PETPORT %s compacting %s: %s item(s) split across more slots than needed",
                stationUniqueId(), sb.printJson(source.id), sb.printJson(#split))

              return {
                id = workId,

                mediumVerified = true,
                type = "compact",
                target = source.id,
                position = stand,
                containerPosition = source.position,
                port = stationUniqueId(),
                dwell = 0
              }
            end
          end
        end
      end
    end
  end

  return nil, "no crate has stacks worth merging"
end

-- Returns a task to pull a scattered or misplaced item out of a crate toward the one it belongs in.
local function defragWork()
  if self.petData == nil then return nil end
  if self.petData.cargo ~= nil and #self.petData.cargo > 0 then return nil end

  local names, deposits, byId = defragCandidates(self.spread, self.beacons or {})

  if #names == 0 then return nil, "everything is already where it belongs" end
  if #deposits == 0 then return nil, "no deposit beacon to gather into" end

  local homeless, full, unreachable = 0, 0, 0
  local claimed, backedOffN, noStack = 0, 0, 0

  for index, entry in ipairs(names) do
    if index > DEFRAG_PLAN_CAP then break end

    local where = self.spread[entry.name]
    local target = defragDestination(entry.name, where, deposits)

    if target == nil then
      homeless = homeless + 1
    else
      local reachable, reachWhy = servicePointNear("crate " .. tostring(target.id),
        target.id, target.position, 4)

      if reachable == nil then
        unreachable = unreachable + 1
        if self.defragSkip ~= target.id then
          self.defragSkip = target.id
          sb.logInfo("PETPORT %s defrag destination %s SKIPPED: %s of %s",
            stationUniqueId(), sb.printJson(target.id), tostring(reachWhy),
            sb.printJson(target.position))
        end
      else
        local sources = defragSources(entry.name, where, target.id, byId)

        for _, pick in ipairs(sources) do
          local crate = pick.crate

          local workId = "defrag:" .. tostring(crate.id)
            .. ":" .. tostring(entry.name)

          local failure = self.workFailures[workId]
          local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

          if backedOff then backedOffN = backedOffN + 1
          elseif not claimFree(workId) then claimed = claimed + 1 end

          if not backedOff and claimFree(workId) then
            local ok, items = pcall(world.containerItems, crate.id)
            local slot, stack = nil, nil

            if ok and type(items) == "table" then
              local keys = {}
              for key in pairs(items) do table.insert(keys, key) end
              table.sort(keys)

              for _, key in ipairs(keys) do
                local held = items[key]

                if key ~= crate.beaconSlot and type(held) == "table"
                   and held.name == entry.name then
                  slot, stack = key, held
                  break
                end
              end
            end

            if slot == nil then noStack = noStack + 1 end

            if slot ~= nil then
              local fits = world.containerItemsCanFit ~= nil
                and world.containerItemsCanFit(target.id, stack) or nil

              if fits == nil or fits <= 0 then
                full = full + 1
              else
                local stand, standWhy = servicePointNear(
                  "crate " .. tostring(crate.id), crate.id, crate.position, 4)

                if stand == nil then
                  unreachable = unreachable + 1

                  if self.defragSkip ~= crate.id then
                    self.defragSkip = crate.id
                    sb.logInfo("PETPORT %s defrag source %s SKIPPED: %s of %s",
                      stationUniqueId(), sb.printJson(crate.id),
                      tostring(standWhy), sb.printJson(crate.position))
                  end
                else
                  self.defragPulled = self.defragPulled or {}
                  self.defragPulled[entry.name] =
                    { from = crate.id, workId = workId }

                  sb.logInfo("PETPORT %s defrag: taking %s x%s from %s "
                    .. "(slot %s, has %s) toward %s -- %s of %s crate(s), "
                    .. "%s slot(s) total",
                    stationUniqueId(), tostring(entry.name),
                    sb.printJson(stack.count or 1), sb.printJson(crate.id),
                    sb.printJson(slot), sb.printJson(pick.count),
                    sb.printJson(target.id), sb.printJson(index),
                    sb.printJson(entry.crates), sb.printJson(entry.slots))

                  return {
                    id = workId,
                    mediumVerified = true,

                    type = "defrag",
                    target = crate.id,
                    item = entry.name,
                    count = stack.count or 1,
                    slot = slot,
                    position = stand,
                    containerPosition = crate.position,
                    port = stationUniqueId(),
                    dwell = 0
                  }
                end
              end
            end
          end
        end
      end
    end
  end

  local why = string.format(
    "%s name(s) misplaced or scattered, none actionable: %s with nowhere to "
    .. "gather into, %s with the destination full, %s with a crate this unit "
    .. "cannot reach, %s claimed by another unit, %s backed off, %s with no "
    .. "stack found in the source", #names, homeless, full, unreachable,
    claimed, backedOffN, noStack)

  if self.defragWhy ~= why then
    self.defragWhy = why
    sb.logInfo("PETPORT %s defrag: %s", stationUniqueId(), why)
  end

  return nil, why
end

-- Returns a task to sort one crate, stepping round the crates and leaving each alone for a while after.
local function sortWork()
	self.sortScan = (self.sortScan or 0) - (WORK_INTERVAL or 1.0)
	if self.sortScan > 0 then return nil, "one crate is looked at every few seconds" end
	self.sortScan = SORT_SCAN_INTERVAL

	local sources = tidySources(true, true)
	if #sources == 0 then return nil, "no crate to sort" end

	self.sortCursor = (self.sortCursor or 0) + 1
	if self.sortCursor > #sources then self.sortCursor = 1 end

	local source = sources[self.sortCursor]
	if source == nil then return nil, "no crate to sort" end

	if not world.entityExists(source.id) then
		return nil, "the crate in the ring this scan is gone"
	end

	self.sortQuiet = self.sortQuiet or {}

	local quiet = self.sortQuiet[source.id]
	if quiet ~= nil and quiet > world.time() then
		return nil, string.format("crate %s was sorted recently",
			tostring(source.id))
	end

	local ok, items = pcall(world.containerItems, source.id)
	if not ok or type(items) ~= "table" then
		return nil, "the crate in the ring this scan could not be read"
	end

	local _, disorder = sortPlan(items)

	if disorder < SORT_MIN_DISORDER then
		return nil, string.format("crate %s is already in order",
			tostring(source.id))
	end

	local workId = "sort:" .. tostring(source.id)

	local failure = self.workFailures[workId]
	local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

	if backedOff then
		return nil, string.format("crate %s is backed off after a failed trip",
			tostring(source.id))
	end

	if not claimFree(workId) then
		return nil, string.format("crate %s is already claimed", tostring(source.id))
	end

	local stand, standWhy = servicePointNear("crate " .. tostring(source.id),
		source.id, source.position, 4)

	if stand == nil then
		sb.logInfo("PETPORT %s sort of %s SKIPPED: %s of %s",
			stationUniqueId(), sb.printJson(source.id), tostring(standWhy),
			sb.printJson(source.position))

		return nil, string.format("nowhere to stand at crate %s",
			tostring(source.id))
	end

	self.sortQuiet[source.id] = world.time() + SORT_REVISIT

	sb.logInfo("PETPORT %s sorting %s: %s slot(s) out of place (crate %s of %s "
		.. "in the ring)",
		stationUniqueId(), sb.printJson(source.id), sb.printJson(disorder),
		sb.printJson(self.sortCursor), sb.printJson(#sources))

	return {
		id = workId,

		mediumVerified = true,
		type = "sort",
		target = source.id,
		position = stand,
		containerPosition = source.position,
		port = stationUniqueId(),
		dwell = 0
	}
end


ASTERITE_STAND_RADIUS = 8

ASTERITE_CACHE_TTL = 5.0

ASTERITE_STAND_TRIES = 6

-- Returns a task to mine the nearest known asterite deposit the unit can stand at.
function asteriteWork()
	if self.asteriteCacheAt == nil or world.time() >= self.asteriteCacheAt then
		self.asteriteCacheAt = world.time() + ASTERITE_CACHE_TTL
		self.asteriteCache = petports_asteriteAll()
	end

	local deposits = self.asteriteCache or {}

	local from = entity.position()
	if self.petId ~= nil and world.entityExists(self.petId) then
		from = world.entityPosition(self.petId)
	end

	local seen = 0
	local candidates = {}
	local rejected = { outside = 0, claimed = 0, backedOff = 0, medium = 0 }

	for key, entry in pairs(deposits) do
		if type(entry) == "table" and type(entry.position) == "table" then
			seen = seen + 1

			local centre = { entry.position[1] + 0.5, entry.position[2] + 0.5 }
			local workId = "asterite:" .. tostring(key)

			local failure = self.workFailures[workId]
			local backedOff = failure ~= nil
				and (failure["until"] or 0) > world.time()

			if not inNetworkCoverage(centre) then
				rejected.outside = rejected.outside + 1
			elseif backedOff then
				rejected.backedOff = rejected.backedOff + 1
			elseif not claimFree(workId) then
				rejected.claimed = rejected.claimed + 1

			elseif not targetEligible("asterite " .. tostring(key), centre) then
				rejected.medium = rejected.medium + 1
			else
				candidates[#candidates + 1] = {
					key = key,
					entry = entry,
					centre = centre,
					workId = workId,
					distance = world.magnitude(from, centre)
				}
			end
		end
	end

	if #candidates == 0 then
		local reason = string.format(
			"%s deposit(s) known, none workable: %s outside network coverage, "
			.. "%s claimed, %s backed off, %s in a medium this chassis cannot "
			.. "work in", seen, rejected.outside, rejected.claimed,
			rejected.backedOff, rejected.medium)

		if reason ~= self.asteriteRejectReason then
			self.asteriteRejectReason = reason
			sb.logInfo("PETPORT %s asterite: %s", stationUniqueId(), reason)
		end

		return nil, reason
	end

	table.sort(candidates, function(a, b) return a.distance < b.distance end)

	local tries = 0

	for _, candidate in ipairs(candidates) do
		if tries >= ASTERITE_STAND_TRIES then break end
		tries = tries + 1

		local stand = standingPointForTarget(candidate.centre, nil,
			ASTERITE_STAND_RADIUS, true)

		if stand ~= nil then
			self.asteriteRejectReason = nil

			sb.logInfo("PETPORT %s asterite deposit at %s, %s away -- "
				.. "dispatching to stand at %s (%s of %s candidates tried)",
				stationUniqueId(), sb.printJson(candidate.entry.position),
				sb.printJson(math.floor(candidate.distance * 10) / 10),
				sb.printJson(stand), sb.printJson(tries),
				sb.printJson(#candidates))

			return {
				id = candidate.workId,
				mediumVerified = true,

				type = "asterite",
				port = stationUniqueId(),

				target = candidate.key,

				tile = { candidate.entry.position[1], candidate.entry.position[2] },

				mod = candidate.entry.mod,

				position = stand
			}
		end
	end

	local reason = string.format(
		"%s workable deposit(s), nowhere to stand within %s tiles of the "
		.. "nearest %s", #candidates, ASTERITE_STAND_RADIUS, tries)

	if reason ~= self.asteriteRejectReason then
		self.asteriteRejectReason = reason
		sb.logInfo("PETPORT %s asterite: %s", stationUniqueId(), reason)
	end

	return nil, reason
end

-- Calls every work generator in priority order in one pass and returns the first task, or nil with the reason and the switched-off work.
local function findWork()
  local oblivious = petportOblivious()

  local doHauling = not oblivious and petportParticipates("hauling")

  local doRestock = not oblivious and petportParticipates("restock")

  local defrag = not oblivious and petportDefrag()

  local doTidyDeposit = defrag and petportParticipates("tidy")
  local doTidyRestock = doRestock
  local doTidy = doTidyDeposit or doTidyRestock
  local doCompact = defrag and petportParticipates("compact")
  local doDefrag = defrag and petportParticipates("defrag")

  local doSort = defrag and petportParticipates("sort")

  local farming = not oblivious and petportFarming()

  local doHarvest = farming and petportFarmingDoes("harvest")
  local doWater = farming and petportFarmingDoes("water")
  local doReplant = farming and petportFarmingDoes("replant")
  local doAnimals = farming and petportFarmingDoes("animals")
  local doTraps = farming and petportFarmingDoes("traps")
  local doMachines = not oblivious and petportParticipates("machines")

  local doAsterite = not oblivious and petportAsterite()

  local recall = portProf("g.return", returnWork)
  if dispatchable(recall) ~= nil then return recall end

  local scrap, noScrap = portProf("g.fuelGround", fuelGroundWork)
  if dispatchable(scrap) ~= nil then return scrap end

  local grub, noGrub = portProf("g.fuelFetch", fuelFetchWork)
  if dispatchable(grub) ~= nil then return grub end

  if noScrap ~= nil and noScrap ~= self.fuelGroundReason then
    self.fuelGroundReason = noScrap
    sb.logInfo("PETPORT %s ground feed idle: %s", stationUniqueId(), tostring(noScrap))
  end

  if noGrub ~= nil and noGrub ~= self.fuelReason then
    self.fuelReason = noGrub
    sb.logInfo("PETPORT %s fuel fetch idle: %s", stationUniqueId(), tostring(noGrub))
  end

  local putBack, noPutBack
  if doReplant then putBack, noPutBack = portProf("g.replant", replantWork) end
  if dispatchable(putBack) ~= nil then return putBack end

  local wet, noWet
  if doWater then wet, noWet = portProf("g.water", waterWork) end
  if dispatchable(wet) ~= nil then return wet end

  local restock
  if doRestock then restock = portProf("g.restock", restockDeliverWork) end
  if dispatchable(restock) ~= nil then return restock end

  local drop, noDrop = portProf("g.deposit", depositWork)
  if dispatchable(drop) ~= nil then return drop end

  if not petportFuelled() then
    return nil, "out of fuel -- finishing what it holds, taking nothing new"
  end

  local dose, noDose = portProf("g.medic", medicWork)
  if dispatchable(dose) ~= nil then return dose end

  if noDose ~= nil and noDose ~= self.medicReason then
    self.medicReason = noDose
    sb.logInfo("PETPORT %s medic idle: %s", stationUniqueId(), tostring(noDose))
  end

	if self.petData ~= nil and self.petData.cargo ~= nil
	   and #self.petData.cargo > 0 then

		local topUp = doHauling and portProf("g.collectTopUp", collectionWork, true) or nil

		if topUp ~= nil then
			sb.logInfo("PETPORT %s stalled with cargo -- topping up %s instead of idling",
				stationUniqueId(), tostring(topUp.id))
			return topUp
		end

		return nil, noDrop
			or ("carrying " .. sb.printJson(#self.petData.cargo)
				.. " stack(s) with no dispatchable deposit target")
	end

  local work, why
  if doHauling then work, why = portProf("g.collect", collectionWork) end
  if dispatchable(work) ~= nil then return work end

  local preload, noPreload = portProf("g.medicPreload", medicWork, true)
  if dispatchable(preload) ~= nil then return preload end

  if noPreload ~= nil and noPreload ~= self.medicPreloadReason then
    self.medicPreloadReason = noPreload
    sb.logInfo("PETPORT %s medic preload idle: %s", stationUniqueId(),
      tostring(noPreload))
  end

  local fish, noFish = portProf("g.fish", fishWork)
  if dispatchable(fish) ~= nil then return fish end

  local crop, noCrop
  if doHarvest then crop, noCrop = portProf("g.harvest", harvestWork) end
  if dispatchable(crop) ~= nil then return crop end

  local beast, noBeast
  if doAnimals and not familyOnHold("animal") then
    beast, noBeast = portProf("g.animal", animalWork)
  end
  if dispatchable(beast) ~= nil then return beast end

  local trap, noTrap
  if doTraps then trap, noTrap = portProf("g.trap", trapWork) end
  if dispatchable(trap) ~= nil then return trap end

  local ore, noOre
  if doAsterite and not familyOnHold("asterite") then
    ore, noOre = portProf("g.asterite", asteriteWork)
  end
  if dispatchable(ore) ~= nil then return ore end

  local fetch, noFetch
  if doReplant then fetch, noFetch = portProf("g.withdraw", withdrawWork) end
  if dispatchable(fetch) ~= nil then return fetch end

  local fetchWater, noFetchWater
  if doWater then fetchWater, noFetchWater = portProf("g.withdrawWater", withdrawWaterWork) end
  if dispatchable(fetchWater) ~= nil then return fetchWater end

  local stock, noStock
  if doRestock then stock, noStock = portProf("g.restockFetch", restockFetchWork) end
  if dispatchable(stock) ~= nil then return stock end

  local fuel, noFuel
  if doMachines then fuel, noFuel = portProf("g.fuel", fuelWork) end
  if dispatchable(fuel) ~= nil then return fuel end

  local tidy, noTidy
  if doTidy then
    tidy, noTidy = portProf("g.tidy", function()
      return tidyWork(doTidyDeposit, doTidyRestock)
    end)
  end
  if dispatchable(tidy) ~= nil then return tidy end

  local squash, noSquash
  if doCompact then squash, noSquash = portProf("g.compact", compactWork) end
  if dispatchable(squash) ~= nil then return squash end

  local gather, noGather
  if doDefrag then gather, noGather = portProf("g.defrag", defragWork) end
  if dispatchable(gather) ~= nil then return gather end

  local order, noOrder
  if doSort then order, noOrder = portProf("g.sort", sortWork) end
  if dispatchable(order) ~= nil then return order end

  local drain, noDrain
  if doMachines then drain, noDrain = portProf("g.drain", drainWork) end
  if dispatchable(drain) ~= nil then return drain end


  if DIAG_FALLBACK then
    local diag = portProf("g.diagnostic", diagnosticWork)
    if dispatchable(diag) ~= nil then return diag end
  end

  local off = {}
  if not doHauling then table.insert(off, "hauling") end
  if not doRestock then table.insert(off, "restock") end

  if not defrag then
    table.insert(off, petportDefrag() and "defrag module (port off)"
      or "tidy (deposit crates)/compact/defrag (no module)")
  else
    if not doTidyDeposit then table.insert(off, "tidy (deposit crates)") end
    if not doCompact then table.insert(off, "compact") end
    if not doDefrag then table.insert(off, "defrag") end
    if not doSort then table.insert(off, "sort") end
  end
  if not farming then
    table.insert(off, petportFarming() and "farming (port off)" or "farming (no module)")
  else
    for _, class in ipairs(FARMING_CLASSES) do
      if not petportFarmingDoes(class) then
        table.insert(off, "farming: " .. class)
      end
    end
  end
  if not doMachines then table.insert(off, "machines") end

  local optedOut = nil
  if #off > 0 then
    optedOut = "port does not participate in " .. table.concat(off, ", ")
  end

  -- Appends the switched-off work to a reason.
  local function withOptOut(reason)
    if optedOut == nil then return reason end
    if reason == nil then return optedOut end
    return reason .. "; " .. optedOut
  end

  -- Joins the place and fetch halves of a generator's reason, or falls back to a quiet one.
  local function bothLegs(place, fetch, quiet)
    if place ~= nil and fetch ~= nil then return place .. ", and " .. fetch end
    return place or fetch or quiet
  end

  if noCrop ~= nil then
    return nil, withOptOut(tostring(why or "collection not run")
      .. "; " .. tostring(noCrop)
      .. "; " .. tostring(bothLegs(noPutBack, noFetch, "no replant work"))
      .. "; " .. tostring(bothLegs(noWet, noFetchWater, "no watering work"))
      .. "; " .. tostring(noBeast or "no animal work")
      .. "; " .. tostring(noTrap or "no trap work")
      .. "; " .. tostring(noFish or "no fishing work")
      .. "; " .. tostring(noStock or "no restock work")
      .. "; " .. tostring(noFuel or "no fuel to collect")
      .. "; " .. tostring(noTidy or "no tidying work")
      .. "; " .. tostring(noSquash or "no compaction work")
      .. "; " .. tostring(noGather or "no gathering work")
      .. "; " .. tostring(noOrder or "no sorting work")
      .. "; " .. tostring(noDrain or "no draining work"))
  end

  return nil, withOptOut(why)
end

-- Logs why no work was taken, at most once per repeat window for a given reason.
local function reject(reason)
  if reason == self.lastReject
     and (self.lastRejectAt or 0) + REJECT_REPEAT > world.time() then
    return
  end

  self.lastReject = reason
  self.lastRejectAt = world.time()

  sb.logInfo("PETPORT %s no dispatch: %s", stationUniqueId(), reason)
end


-- Takes the claim on the chosen work, attaches the cargo manifest, and hands the task to the unit.
local function dispatchWork()
  if self.petId == nil or not world.entityExists(self.petId) then
    return reject("no unit")
  end

  local work, why = portProf("findWork", findWork)
  if work == nil then
    return reject(why)
  end

  if self.petId == nil or not world.entityExists(self.petId) then
    return reject("unit went away while work was being chosen")
  end


  if not portProf("claimTake", petports_claimTake, work.id, stationUniqueId(),
                            work.type, work.position, CLAIM_TTL) then
    return reject("claimed by another owner: " .. tostring(work.id))
  end

  if self.petData ~= nil and self.petData.cargo ~= nil then
    local manifest = {}
    for _, stack in ipairs(self.petData.cargo) do
      table.insert(manifest, string.format("%sx %s",
        tostring(stack.count or 1), tostring(stack.name)))
    end
    work.cargo = manifest
  end

  if not portProf("assignTask", world.callScriptedEntity, self.petId,
                  "petports_assignTask", work) then
    petports_claimRelease(work.id, stationUniqueId())
    return reject("unit refused assignment")
  end

  self.task = work

  self.taskMoving = false
  self.taskAge = 0
  self.lastReject = nil
  sb.logInfo("PETPORT %s dispatched %s to %s",
    stationUniqueId(), work.id, sb.printJson(work.position))
end

-- Refreshes the running task's claim, and drops it on the deadline or once the unit stops holding it.
local function trackWork()
  self.taskAge = (self.taskAge or 0) + WORK_INTERVAL
  if self.taskAge >= TASK_DEADLINE then
    local taskId = self.task.id
    abandonTask("deadline -- no report in " .. sb.printJson(TASK_DEADLINE) .. "s")
    noteFailure(taskId, "deadline")

    if self.petId ~= nil and world.entityExists(self.petId) then
      world.callScriptedEntity(self.petId, "petports_clearTask")
    end
    return
  end

  if self.petId == nil or not world.entityExists(self.petId) then
    self.task = nil
    return reject("unit gone mid-task")
  end

  if world.callScriptedEntity(self.petId, "petports_taskId") ~= self.task.id then
    local taskId = self.task.id
    self.task = nil
    noteFailure(taskId, "unit stopped holding the task")
    return reject("unit is no longer holding the task")
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
local function crosshairClaimId(dropId)
  return "mark:" .. tostring(dropId)
end

CROSSHAIR_CLAIM_TTL = 4.0
CROSSHAIR_CLAIM_RENEW = 1.5

-- Takes or renews the marker claim on a drop, taking it off another port only for a higher priority state.
local function crosshairClaim(dropId, state)
  local claimId = crosshairClaimId(dropId)
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
local function crosshairRelease(dropId)
  petports_claimRelease(crosshairClaimId(dropId), stationUniqueId())
end

-- Returns the marker colour for a state, preferring the unit's own override.
local function crosshairColor(state)
  local overrides = self.petData ~= nil and self.petData.crosshairColors or nil

  if type(overrides) == "table" and type(overrides[state]) == "string" then
    return overrides[state]
  end

  return CROSSHAIR_COLORS[state]
end

-- Returns every drop in the network rects.
local function crosshairDrops()
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
local function crosshairStorable(dropId, cache)
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
local function crosshairWanted()
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

  for _, dropId in ipairs(crosshairDrops()) do
    if wanted[dropId] == nil then
      local claim = petports_claimGet("drop:" .. dropId)
      local mine = claim == nil
        or claim.owner == stationUniqueId()
        or (claim.expires or 0) <= world.time()

      if not mine then
        wanted[dropId] = nil

      elseif not crosshairStorable(dropId, storable) then
        wanted[dropId] = "blocked"

      else
        wanted[dropId] = "unclaimed"
      end
    end
  end

  return wanted
end

-- Kills a marker projectile.
local function crosshairKill(marker)
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
local function crosshairRefresh(dt)
  self.crosshairs = self.crosshairs or {}

  if not petportCrosshairs() then
    if next(self.crosshairs) ~= nil then
      sb.logInfo("PETPORT %s retiring crosshairs: switched off", stationUniqueId())
      crosshairClear()
    end
    return
  end

  self.crosshairTimer = (self.crosshairTimer or 0) - dt
  if self.crosshairTimer > 0 then return end
  self.crosshairTimer = CROSSHAIR_INTERVAL

  local wanted = crosshairWanted()

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
      crosshairKill(marker)
      crosshairRelease(dropId)
      self.crosshairs[dropId] = nil
    end
  end

  for dropId, state in pairs(wanted) do
    local marker = self.crosshairs[dropId]

    if world.entityExists(dropId) and crosshairClaim(dropId, state) then
      local due = marker == nil or (marker.refresh or 0) <= world.time()

      if due then
        crosshairKill(marker)

        local at = world.entityPosition(dropId)

        local ok, id = pcall(world.spawnProjectile,
          CROSSHAIR_PROJECTILE[state],
          at,

          nil,
          { 0, 0 },
          false,
          {
            processing = "?multiply=" .. crosshairColor(state),

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
crosshairClear = function()
  for dropId, marker in pairs(self.crosshairs or {}) do
    crosshairKill(marker)
    crosshairRelease(dropId)
    self.crosshairs[dropId] = nil
  end
end


local workBeatDispatch

-- Runs the work beat: the sweeps and network refresh, then the beacon, farmable and animal scans across three ticks, then the dispatch.
local function workUpdate(dt)
  if self.beatStage ~= nil then
    local stage = self.beatStage

    if stage == 1 then
      portProf("refreshBeacons", refreshBeacons, WORK_INTERVAL)
      self.beatStage = 2
      return
    elseif stage == 2 then
      portProf("refreshFarmables", refreshFarmables, WORK_INTERVAL)
      portProf("refreshAnimals", refreshAnimals, WORK_INTERVAL)
      portProf("publishUnitPosition", publishUnitPosition)
      portProf("ensureResidency", ensureResidency)
      self.beatStage = 3
      return
    end

    self.beatStage = nil
    workBeatDispatch()
    return
  end

  self.workTimer = self.workTimer - dt
  if self.workTimer > 0 then return end
  self.workTimer = WORK_INTERVAL

  portProf("claimsSweep", petports_claimsSweep)

  portProf("fishSweep", petports_fishSweep)

  local registry = petports_registry()
  if (registry.ports or {})[stationUniqueId()] == nil then
    sb.logInfo("PETPORT %s registry entry is missing -- re-publishing",
      stationUniqueId())
    publishRegistry()
  end

  portProf("nibbleFromCargo", nibbleFromCargo)

  portProf("refreshNetwork", refreshNetwork)

  self.beatStage = 1
end

-- Dispatches new work, or tracks the running task.
workBeatDispatch = function()
  local tickState = string.format("%s/%s", tostring(self.petId),
    self.task and self.task.id or "none")

  if tickState ~= self.tickState then
    self.tickState = tickState

    sb.logInfo("PETPORT %s tick: unit %s task %s",
      stationUniqueId(), sb.printJson(self.petId),
      self.task and self.task.id or "none")
  end

  if self.task == nil then
    portProf("dispatchWork", dispatchWork)
  else
    portProf("trackWork", trackWork)
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

-- Runs the port's tick: markers, replant sweep, asterite scan, pane mirror, the socketed item, the environment and health checks, the spawn, and the work beat.
local function updateInner(dt)
  if self.firstUpdate then
    self.firstUpdate = false
    stationUniqueId()

    petports_claimsClearOwner(stationUniqueId())

    petports_fishClearOwner(stationUniqueId())
    ensureResidency()
    publishRegistry()
  end

  portProf("crosshairRefresh", crosshairRefresh, dt)

  portProf("sweepReplants", sweepReplants, dt)

  portProf("asteriteScan", asteriteScanStep)

  portProf("mirrorPaneState", mirrorPaneState, dt)

  local item = socketedItem()

  if item == nil then
    if self.petId ~= nil then
      saveAndDespawn()
      cargoTrace("unsocket: discarding petData", self.petData and self.petData.cargo)
      self.petData = nil
    end
    setHullAnimationStateIntent("close")

    abandonTask("item removed")

    publishUnitPosition()
    return
  end

  if self.petData ~= nil and itemSeed(item) ~= self.petData.seed then
    trace("item swapped, outgoing seed", self.petData.seed)
    saveAndDespawn(true)
    self.petData = nil
    abandonTask("unit swapped out")
  end

  if self.petData == nil then
    self.petData = petDataFrom(item)
    cargoTrace("socket: petData built", self.petData and self.petData.cargo)
    if self.petData == nil then
      setHullAnimationStateIntent("close")
      abandonTask("socketed item is not a pet")
      return
    end

    self.envUnsuitable = nil
    self.envRetired = nil
    self.envTypeUnreadable = nil

    self.environmentTimer = 0
    self.spawnTimer = 0
  end

  reconcileMedkit()

  local enabled = petportEnabled()

  if self.fadingPetId ~= nil and not world.entityExists(self.fadingPetId) then
    self.fadingPetId = nil
  end

  self.environmentTimer = (self.environmentTimer or 0) - dt
  if self.environmentTimer <= 0 then
    self.environmentTimer = ENVIRONMENT_INTERVAL
    environmentCheck()

    mediumCheck()

    fishingCheck()
  end

  local unitPresent = self.petId ~= nil or self.fadingPetId ~= nil
  local habitable = self.envUnsuitable == nil

  setHullAnimationStateIntent(((enabled and habitable) or unitPresent) and "open" or "close")

  if not enabled then
    if self.petId ~= nil then
      sb.logInfo("PETPORT %s despawning unit: port is switched off. Its state and "
        .. "cargo are written back to the socketed item.", stationUniqueId())

      saveAndDespawn()
      abandonTask("port disabled")

      publishUnitPosition()
    end
  end

-- Records the unit's damage team when it changes.
local function teamWatch()
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
    healthCheck()
  end

  teamWatch()

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
      metrics.add("active", dt)
    end

    local position = world.entityPosition(self.petId)

    if position ~= nil then
      if self.odometerLast ~= nil and self.task ~= nil then
        local step = world.magnitude(position, self.odometerLast)
        if step < 10 then
          metrics.add("traveled", step)
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

  portProf("workUpdate", workUpdate, dt)
  portProfReport()
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
  updateInner(dt)
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
