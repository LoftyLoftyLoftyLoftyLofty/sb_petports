require "/scripts/util.lua"
require "/scripts/messageutil.lua"
require "/scripts/lofty_petports/petports_work.lua"

--  M.A.U.S. PETPORT
--
--  A one-slot container. Socket a petports_unit item and the unit it
--  describes wakes up nearby; take the item out and the unit goes back to sleep,
--  its state written into the item.
--
--  WHY NOT THE VANILLA PET TETHER PIPELINE
--
--  /scripts/companions/petspawner.lua exists to serve capture pods, and almost
--  all of its complexity is pod-shaped: pods holding several pets at once (a
--  hemogoblin splits when it dies), collar merging, associate/disassociate
--  handlers, and a JSON round-trip that keeps a pod item in sync so a pet can be
--  carried between worlds.
--
--  None of that applies to a dedicated item. One item is one pet, there are no
--  collars, and the definition lives in the item's own parameters. What is worth
--  keeping from that file is the spine, reproduced below:
--
--    * assembling spawn parameters and handing the monster its initialStatus /
--      initialStorage, which is how a pet keeps learned state across a respawn
--    * a status heartbeat, so the petport notices when its pet dies or unloads
--    * collision-aware spawn placement
--
--  ANCHORING
--
--  Vanilla's groundPet.lua expects an anchor object and calls setAnchor on
--  itself, which calls back into hasPet/setPet here. It kills the pet outright
--  if it cannot find one -- and note that findAnchor only SEARCHES when
--  storage.anchorPosition already exists, so it is a recovery path, not a
--  discovery path. A console-spawned unit can never survive; only this object
--  can spawn a viable one, because spawnPet's setAnchor call is what writes
--  storage.anchorPosition in the first place.
--
--  So this object implements the same contract the SAIL techstation does --
--  hasPet, setPet -- and the monstertype's anchorName points at this object.
--  That keeps vanilla's pet scripts usable unmodified while the behavior work
--  happens separately.

local STATUS_INTERVAL = 2.0
local RESPAWN_GRACE = 1.0

--  Periodic flush of drifting state into the socketed item.
--
--  Durable changes (a new known player, a new food liking, the seed) write
--  immediately. Resource drift does not, because groundPet.lua re-calls
--  setAnchor -- and therefore setPet -- once per second, and writing the item
--  back on every one of those is a container swap per second, forever,
--  replicated to every client.
--
--  THIS TIMER IS NOT A SAFETY NET. It is the actual persistence mechanism for
--  drifting values, because the final save on unsocket DOES NOT WORK and
--  cannot be made to: writeBackToItem needs the item to still be in the slot,
--  and by the time the petport notices the removal the item is already in the
--  player's inventory, out of reach. Confirmed in testing -- petports_store
--  returns fresher values than the item ends up holding.
--
--  So this interval is exactly how much resource drift an unsocket discards.
--  Only petResources are affected; durable state is written on change and
--  world unload IS covered, since uninit runs while the item is still socketed.
local WRITE_INTERVAL = 10.0

--  Instrumentation, dormant by default (see handoff §4). Flip to true to trace
--  the item <-> pet state round trip in starbound.log.
local DEBUG = false

--------------------------------------------------------------------------------
--  COVERAGE AND WORK
--------------------------------------------------------------------------------
--
--  The coverage rect is a square centred on the petport: the region this port
--  keeps resident, the area its unit may take work in, and the placement-time
--  visual, all one number. 32 tiles is one chunk.
--
--  Residency is NOT implemented here. keepAlive is unavailable on objects, so
--  the loadRegion call belongs to an anchored stagehand -- see the handoff. For
--  now the player has to be nearby, which is deliberate: dispatch is being
--  tested on its own, so "the unit stopped when I walked away" stays a clean
--  signal rather than an ambiguous one.

local COVERAGE_SIZE = 32

--  How long a claim survives without a refresh. Long enough to walk across the
--  rect, short enough that an abandoned job frees up while the player watches.
local CLAIM_TTL = 30.0

--  How often to look for work and to push claim expiry out.
local WORK_INTERVAL = 1.0

--  How often to re-state an unchanged dispatch rejection.
local REJECT_REPEAT = 30.0

--  Hard ceiling on a single task, regardless of what the unit reports.
--
--  Every failure path is supposed to report, but a report that never arrives
--  strands the port in trackWork forever -- refreshing a claim for work nobody
--  is doing and dispatching nothing else, permanently. A deadline makes that
--  self-healing rather than terminal. Longer than any legitimate task: an
--  unreachable target gives up in SEARCH_LIMIT, a long walk in
--  APPROACH_TIMEOUT.
--  Raised from 60: a COLD route cache legitimately spends 40+ seconds probing,
--  since each unreachable edge costs the full A* exhaustion. Once warm, plans
--  resolve in milliseconds.
local TASK_DEADLINE = 150.0

--  Diagnostic task only: how long the unit stands at the point.
local DIAG_DWELL = 3.0

--  UNREACHABLE WORK BACKOFF
--
--  A task that fails must not be re-dispatched immediately. Reachability is not
--  checked at discovery -- the port sees an item drop in its rect and has no
--  cheap way to know a ground unit cannot climb to it -- so the unit finding
--  out IS the reachability test, and the result has to be remembered.
--
--  Without this, one stranded item permanently occupies the port's dispatch
--  slot while everything reachable goes uncollected. Escalating so a
--  briefly-blocked item is retried soon and a genuinely unreachable one stops
--  costing anything.
local FAILURE_BACKOFF = { 10.0, 30.0, 120.0, 600.0 }

--  How many failed walk-home attempts before the unit is re-homed instead.
local RECALL_LIMIT = 2

--  How far beyond the network's coverage to look for usable vents.
local VENT_SEARCH_MARGIN = 24

--  Fall back to the diagnostic task when there is no real work?
--
--  Useful for exercising residency and dispatch with an empty rect, noisy
--  otherwise. Off by default now that collection exists.
local DIAG_FALLBACK = false

--  Residency stagehand type. One per petport, spawned on first update.
local RESIDENCY_TYPE = "petports_residency"

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

--  The port's coverage rect: the region it keeps resident, the area its unit
--  may take work in, and the placement-time visual, all one number.
--
--  Declared UP HERE because init's message handler uses it. A `local function`
--  is not visible above its own declaration, and referencing it from init
--  resolves to a nil global that only throws when the handler actually fires --
--  which is on the first task report, not at load.
local function coverageRect()
  return petports_coverageRect(entity.position(), COVERAGE_SIZE)
end

--  Our registry entry. Published on first update and whenever our own
--  configuration changes; the version counter is what tells other ports to
--  re-derive.
local function publishRegistry()
  local rect = coverageRect()

  --  Clear any predecessor sitting at our own position first, so a port that
  --  was mined and replaced does not leave a phantom coverage zone behind.
  petports_registryClearAt(rect, stationUniqueId())

  petports_registryPublish(stationUniqueId(), {
    rect = rect,
    position = entity.position(),
    participate = config.getParameter("petports_participate", true),
    id = config.getParameter("petports_networkId", 0)
  })
end

--  Re-derive our network when the registry version moves, and push the rect
--  list to our unit only if it actually changed.
--
--  The unit never learns that networks exist. It gets a list of rectangles and
--  one rule: when IDLE, stay inside them. A task may path anywhere.
--  Union dispatch needs to know where other members' units are, so the entry
--  carries it -- refreshed only when the unit has moved MATERIALLY, because
--  this is replicated state and a per-tick write would be the one genuinely
--  expensive thing in the design.
local UNIT_POSITION_THRESHOLD = 4.0

local function publishUnitPosition()
  local registry = petports_registry()
  local entry = (registry.ports or {})[stationUniqueId()]
  if entry == nil then return end

  local position = nil
  local busy = self.task ~= nil

  if self.petId ~= nil and world.entityExists(self.petId) then
    position = world.entityPosition(self.petId)
  end

  local moved = position == nil or entry.unitPosition == nil
    or world.magnitude(position, entry.unitPosition) > UNIT_POSITION_THRESHOLD

  if not moved and entry.busy == busy then return end

  entry.unitPosition = position
  entry.busy = busy
  petports_registryPublish(stationUniqueId(), entry)
end

--  Vents inside the network's coverage, with where they come out.
--
--  The PORT gathers this because it already knows the network's rects and can
--  query objects cheaply. It cannot evaluate REACHABILITY -- pathfinding needs
--  mcontroller, which objects do not have -- so the unit does that part.
local function gatherVents()
  --  Vents are gathered from a rect INFLATED beyond the network's coverage.
  --
  --  A vent sitting just outside coverage is still perfectly usable -- units on
  --  task may leave the network, and vents exist precisely to reach
  --  out-of-the-way places. Gathering only from inside meant a vent one tile
  --  past the boundary silently vanished from the routing options, which reads
  --  as "the drone ignores my vent" with nothing to explain it.
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

        if okEntry and entry ~= nil and okDest and dests ~= nil and #dests > 0 then
          table.insert(vents, { id = id, entry = entry, destinations = dests })
        end
      end
    end
  end

  return vents
end

local function refreshNetwork()
  local version = petports_registryVersion()
  local unitChanged = false

  if version ~= self.registryVersion then
    self.registryVersion = version

    local rects = petports_networkRects(stationUniqueId())
    if not petports_rectListsEqual(rects, self.networkRects) then
      self.networkRects = rects
      unitChanged = true
      sb.logInfo("PETPORT %s network now %s ports", stationUniqueId(), #rects)

      --  Coverage changed, so vents may have appeared or vanished and terrain
      --  the cache was derived from may no longer be reachable the same way.
      --
      --  A stale entry is self-correcting -- it suggests a route that fails
      --  fast, and that failure is the signal -- but clearing on a known
      --  structural change is cheaper than discovering it one bad route at a
      --  time.
      self.routeCache = {}
      self.routeDirty = true
    end
  end

  --  Also push on a fresh unit, which has no list yet, and whenever the route
  --  cache has learned something -- other units on this port benefit from what
  --  one of them discovered.
  if (unitChanged or self.routeDirty or self.pushedToPet ~= self.petId)
     and self.petId ~= nil and world.entityExists(self.petId) then
    world.callScriptedEntity(self.petId, "petports_setNetwork",
      self.networkRects, entity.position())

    --  Vent list rides the same push. Entity ids are not stable across a
    --  reload, which is fine: this is re-gathered and re-pushed on every spawn.
    world.callScriptedEntity(self.petId, "petports_setVents", gatherVents())
    world.callScriptedEntity(self.petId, "petports_setRouteCache", self.routeCache)
    self.routeDirty = false
    self.pushedToPet = self.petId
  end
end

--  Is a position inside our NETWORK's coverage?
--
--  Not our own rect. Union dispatch sends a unit into any member's coverage, so
--  testing against the port's own rect marks a unit stray the moment it does
--  exactly what it was told to do -- and recalls it home after every
--  cross-port pickup.
local function inNetwork(position)
  local rects = self.networkRects
  if rects == nil or #rects == 0 then rects = { coverageRect() } end

  for _, area in ipairs(rects) do
    if petports_rectContains(area, position) then return true end
  end
  return false
end


--  Record that a task did not succeed.
--
--  CENTRALISED because there are two ways a task can end badly and they RACE:
--  the unit reports failure, and trackWork independently notices the unit is no
--  longer holding it. Whichever wins clears self.task, and the loser used to be
--  discarded -- which meant recall failures were never counted, re-home never
--  fired, and a stranded unit was recalled forever.
local function noteFailure(taskId, reason)
  if taskId == nil then return end

  if taskId == "return:" .. stationUniqueId() then
    self.recallFailures = (self.recallFailures or 0) + 1
    sb.logInfo("PETPORT %s recall failed (%s of %s): %s",
      stationUniqueId(), self.recallFailures, RECALL_LIMIT, reason)
    return
  end

  --  A failure while the unit was outside its network says nothing about the
  --  work -- the unit's position was the problem, not the item.
  if self.petId ~= nil and world.entityExists(self.petId)
     and not inNetwork(world.entityPosition(self.petId)) then
    sb.logInfo("PETPORT %s not blaming %s: unit was outside the network at %s",
      stationUniqueId(), taskId, sb.printJson(world.entityPosition(self.petId)))
    return
  end

  local record = self.workFailures[taskId] or { count = 0 }
  record.count = record.count + 1
  local backoff = FAILURE_BACKOFF[math.min(record.count, #FAILURE_BACKOFF)]
  record["until"] = world.time() + backoff
  self.workFailures[taskId] = record

  sb.logInfo("PETPORT %s backing off %s for %s seconds (failure %s)",
    stationUniqueId(), taskId, sb.printJson(backoff), record.count)
end


--  RESIDENCY
--
--  keepAlive is unavailable on objects, so a petport cannot keep its own
--  coverage rect loaded. It anchors a stagehand that can. See
--  /stagehands/lofty_petports/petports_residency.stagehand.
--
--  The stagehand's uniqueId is derived from the port's TILE POSITION, not from
--  the port's uniqueId. A port that is mined and re-placed at the same spot is
--  a new object with a new uniqueId, so a uniqueId-derived key would orphan the
--  old stagehand and mint a second one. Position-derived reuses it, and gives a
--  sweep a pattern to find strays by.
local function residencyUniqueId()
  local position = entity.position()
  return string.format("petports_residency_%s_%s",
    math.floor(position[1]), math.floor(position[2]))
end

--  Spawn the stagehand if it is not already there.
--
--  Retried on a slow timer rather than only on first update: a spawn that fails
--  should be visible as a repeating attempt rather than a single silent miss,
--  and a stagehand that dies while its port lives should be replaced.
local function ensureResidency()
  local residencyId = residencyUniqueId()
  local existing = world.loadUniqueEntity(residencyId)

  if existing ~= nil and world.entityExists(existing) then
    return
  end

  --  uniqueId is passed TWICE on purpose. The override key is the obvious way
  --  and is UNVERIFIED; `residencyUniqueId` is read by the stagehand's own init
  --  which calls stagehand.setUniqueId with it. Whichever mechanism actually
  --  works, the id ends up set, and if both work the second is a no-op.
  local ok, result = pcall(world.spawnStagehand, entity.position(), RESIDENCY_TYPE, {
    uniqueId = residencyId,
    residencyUniqueId = residencyId,
    portUniqueId = stationUniqueId(),
    coverageSize = COVERAGE_SIZE
  })

  sb.logInfo("PETPORT %s residency spawn id=%s ok=%s result=%s",
    stationUniqueId(), residencyId, tostring(ok), tostring(result))
end

--  Only on DESTRUCTION. Never from uninit -- that also fires on world unload,
--  and killing residency there would orphan every port on the next reload.
local function stopResidency()
  local residencyId = world.loadUniqueEntity(residencyUniqueId())
  if residencyId == nil then return end

  world.sendEntityMessage(residencyId, "petports_residencyStop")
end

local function abandonTask(reason)
  if self.task == nil then return end

  sb.logInfo("PETPORT %s abandoning %s: %s", stationUniqueId(), self.task.id, reason)
  petports_claimRelease(self.task.id, stationUniqueId())
  self.task = nil
end

function init()
  self.petId = nil
  self.petUniqueId = nil
  self.petData = nil
  self.statusTimer = 0
  self.spawnTimer = 0
  self.spawning = false
  self.dirty = false
  self.writeTimer = WRITE_INTERVAL
  self.firstUpdate = true

  --  Sent by the pet when it dies or is recalled, so the petport can write the
  --  final state back into the item rather than losing it.
  message.setHandler("petports_status", simpleHandler(function(status, storage)
    if self.petData then
      self.petData.status = status or self.petData.status
      self.petData.storage = storage or self.petData.storage
      self.dirty = true
      trace("petStatus message -> storage", self.petData.storage)
    end
  end))

  self.workTimer = 0
  self.task = nil
  self.lastReject = nil
  self.lastRejectAt = 0
  self.recallFailures = 0
  self.taskAge = 0
  self.registryVersion = -1
  self.networkRects = nil

  --  Route cache: "<destination bucket>|<vent exit id>" -> bool.
  --
  --  Produced by UNITS, because only they can pathfind. Held HERE because a
  --  port is resident whenever the network is and survives reloads, while units
  --  respawn and would each have to rediscover everything.
  self.routeCache = {}

  --  workId -> { count = <failures>, until = <world.time()> }. In memory only:
  --  entity ids do not survive a reload, so neither should this.
  self.workFailures = {}

  --  Outcome from the unit. Reported by uniqueId because entity ids do not
  --  survive a reload and the unit may have respawned since dispatch.
  message.setHandler("petports_taskReport", simpleHandler(function(report)
    if report == nil or self.task == nil then return end
    if report.id ~= self.task.id then return end

    sb.logInfo("PETPORT %s task %s %s: %s",
      stationUniqueId(), report.id, report.outcome,
      report.reason or "no detail")

    if report.outcome == "done" then
      self.workFailures[report.id] = nil
      if report.id == "return:" .. stationUniqueId() then
        self.recallFailures = 0
      end
    else
      noteFailure(report.id, report.reason or "no detail")
    end

    petports_claimRelease(self.task.id, stationUniqueId())
    self.task = nil
  end))

  --  A unit reporting what it learned from a probe.
  message.setHandler("petports_learnedRoute", simpleHandler(function(learned)
    if learned == nil or learned.key == nil then return end
    if self.routeCache[learned.key] == learned.reachable then return end

    self.routeCache[learned.key] = learned.reachable
    self.routeDirty = true
  end))

  object.setInteractive(true)
end

--  DESTRUCTION ONLY. uninit fires on world unload as well, so anything that
--  should survive a reload must not be torn down there.
function die()
  stopResidency()

  --  DESTRUCTION ONLY. From uninit this would wipe the network on every world
  --  unload, and every port would come back believing it stands alone.
  petports_registryRemove(stationUniqueId())
end

function uninit()
  --  Both destruction AND world unload reach here. Releasing the claim is right
  --  either way: on unload it would be orphaned anyway, and this port clears
  --  its own claims on the next init regardless.
  abandonTask("petport unloading")

  --  Petport unloading or being broken: put the unit back in its item so
  --  nothing is lost. This is why a unit does not survive the player beaming
  --  away -- the item carries the state, not the monster.
  saveAndDespawn()
end

--------------------------------------------------------------------------------
--  ANCHOR CONTRACT (see groundPet.lua setAnchor / findAnchor)
--------------------------------------------------------------------------------

function hasPet()
  return self.petId ~= nil and world.entityExists(self.petId)
end

function setPet(entityId, params)
  if self.petId ~= nil and self.petId ~= entityId then
    return false
  end
  self.petId = entityId

  --  groundPet.lua pushes its own state here ONCE PER SECOND, via updateAnchor
  --  re-calling setAnchor. So this runs constantly and must not mark the item
  --  dirty on its own -- see WRITE_INTERVAL above.
  --
  --  Durable state (known players, food likings, seed) changes rarely and is
  --  worth an immediate write. Resource levels drift every tick and are not.
  if params and self.petData then
    self.petData.storage = self.petData.storage or {}

    --  Seed is stable for the life of the monster, so it is safe to take at any
    --  time -- including from the echo below.
    if params.seed and params.seed ~= self.petData.seed then
      self.petData.seed = params.seed
      self.dirty = true
    end

    --  IGNORE THE FIRST CALLBACK AFTER A SPAWN.
    --
    --  spawnPet calls setAnchor immediately, and groundPet answers by pushing
    --  its state straight back here -- state it has only just initialized. That
    --  is an echo, not news. Accepting it overwrites the item with whatever the
    --  unit came up at, so a restore that silently failed would also DESTROY
    --  the saved values it failed to restore. Observed exactly that: defaults
    --  written into the item 23ms after spawn.
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

    --  Kept current in memory, flushed on the slow timer or at despawn.
    self.petData.storage.petResources = params.petResources or self.petData.storage.petResources
  end
  return true
end

--------------------------------------------------------------------------------
--  ITEM <-> PET
--------------------------------------------------------------------------------

--  The socketed item, or nil. Slot 0 because slotCount is 1.
local function socketedItem()
  local item = world.containerItemAt(entity.id(), 0)
  if item == nil or item.name == nil then return nil end
  return item
end

--  Just the seed off a socketed item, without the full merge. Called every
--  tick by the swap check, so it must not do root.itemConfig work (or trace).
local function itemSeed(item)
  if item == nil or item.parameters == nil then return nil end
  if item.parameters.petData == nil then return nil end
  return item.parameters.petData.seed
end

--  Pet definition from the item, merging the item's own instance parameters
--  over the base config. A found item may carry only monsterType; a lived-in
--  one carries status and storage too.
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

  trace("read from item", data)
  return data
end

function spawnPet()
  if self.petData == nil or self.petData.monsterType == nil then return end
  if self.petId ~= nil and world.entityExists(self.petId) then return end

  local spawnPosition = object.toAbsolutePosition(config.getParameter("petSpawnOffset", {0, 2}))

  --  THESE ARE TOP-LEVEL PARAMETERS, NOT A scriptConfig SUB-TABLE.
  --
  --  petspawner.lua looks like it nests them, but only looks like it:
  --  Pet:_scriptConfig(parameters) returns `parameters` unchanged, so the local
  --  named scriptConfig IS the parameters table. Everything assigned to it
  --  lands at the top level of what reaches world.spawnMonster. Nested under a
  --  literal scriptConfig key, none of it is reachable via config.getParameter
  --  and the engine never sees initialStatus / initialStorage at all.
  local parameters = {
    --  Ship pets belong to the ship, not the world's threat level.
    level = math.max(world.threatLevel(), world.getProperty("ship.level") or 0, 1),

    --  Persistent so the unit is not garbage collected while the player is
    --  elsewhere on the ship; the petport owns its lifetime instead.
    persistent = true,

    --  Never yanked around by relocation logic meant for wild creatures.
    relocatable = false,

    damageTeamType = "ghostly",

    --  How the pet reports home. It messages the petport rather than the
    --  petport polling it, which keeps the item current even if the pet dies
    --  while the player is watching something else.
    stationUniqueId = stationUniqueId(),

    --  Resume where it left off.
    --
    --  initialStatus / initialStorage are kept because vanilla sets them, but
    --  OBSERVED NOT TO WORK for seeding a monster's storage table: a unit
    --  spawned with a populated initialStorage still came up with
    --  config-default petResources and an empty knownPlayers. Whatever consumes
    --  these, it is not what groundPet.lua reads on init.
    initialStatus = copy(self.petData.status) or {},
    initialStorage = copy(self.petData.storage) or {},

    petName = self.petData.petName
  }

  --  THE ROUTE THAT ACTUALLY RESTORES STATE.
  --
  --  groundPet.lua's init reads
  --
  --    storage.petResources = storage.petResources or config.getParameter("petResources")
  --    storage.knownPlayers = storage.knownPlayers or config.getParameter("knownPlayers", {})
  --    storage.foodLikings  = storage.foodLikings  or config.getParameter("foodLikings", {})
  --
  --  and spawn parameters ARE config parameters -- that path is proven, it is
  --  how level, persistent and anchorName already arrive. So saved values are
  --  passed as parameters and picked up by the fallback branch, since a freshly
  --  spawned monster's storage is empty.
  --
  --  nil entries simply do not appear in the table, leaving the monstertype's
  --  own defaults in play for a brand new unit.
  local saved = self.petData.storage or {}
  parameters.petResources = copy(saved.petResources)
  parameters.knownPlayers = copy(saved.knownPlayers)
  parameters.foodLikings = copy(saved.foodLikings)

  --  Seed the anchor position so the unit can self-anchor through vanilla's own
  --  recovery path if the setAnchor call below is ever missed. Belt and braces:
  --  the direct call has not failed in testing, but its success depends on the
  --  monster's script having initialized by the time spawnMonster returns.
  parameters.initialStorage.anchorPosition = entity.position()

  --  VERIFY: whether world.spawnMonster honours a seed parameter. If it does,
  --  this pins the monsterpart variant across respawns; if not, it is inert and
  --  the variant needs pinning some other way.
  if self.petData.seed then
    parameters.seed = self.petData.seed
  end

  trace("spawning with initialStorage", parameters.initialStorage)

  self.petId = world.spawnMonster(self.petData.monsterType, spawnPosition, parameters)
  if self.petId then
    self.spawning = true
    self.statusTimer = STATUS_INTERVAL

    --  Hand the pet its anchor, exactly as techstation.lua does. groundPet.lua
    --  calls back into setPet from here.
    world.callScriptedEntity(self.petId, "setAnchor", entity.id())
  else
    trace("spawnMonster returned nil for type", self.petData.monsterType)
  end
end

--  skipWrite: set when the unit is being put away because a DIFFERENT item is
--  now in the slot. Writing back then would stamp the outgoing unit's state
--  onto the incoming item -- the exact corruption the swap check exists to
--  prevent. The outgoing item is already in the player's inventory and out of
--  reach either way.
function saveAndDespawn(skipWrite)
  if self.petId and world.entityExists(self.petId) then
    --  Ask for final state before removing it. Best effort: if the pet is
    --  already gone the item simply keeps the last state we heard about.
    local ok, state = pcall(world.callScriptedEntity, self.petId, "petports_store")
    trace("petStore returned", ok and state or nil)

    if ok and state and self.petData then
      self.petData.status = state.status or self.petData.status
      self.petData.storage = state.storage or self.petData.storage
    end

    --  Defined in petports_contract.lua on the monster side. Note a
    --  bare callScriptedEntity to an UNDEFINED function returns nil silently --
    --  it does not raise -- which is how the socket-cycle unit leak went
    --  unnoticed before that script existed.
    world.callScriptedEntity(self.petId, "petports_despawn")
  end
  --  No-op when the unit is being put away because the ITEM was removed -- it
  --  has already left the container. Still worth calling: this path also runs
  --  from uninit on world unload, where the item is present.
  if not skipWrite then
    writeBackToItem()
  end

  self.petId = nil
  self.spawning = false
end

--  Persist the live pet state into the socketed item, so the unit travels with
--  the item rather than living in the petport.
function writeBackToItem()
  if self.petData == nil then return end
  local item = socketedItem()
  if item == nil then return end

  item.parameters = item.parameters or {}
  item.parameters.petData = self.petData

  trace("writing back to item", self.petData)

  world.containerSwapItemsNoCombine(entity.id(), item, 0)
  self.dirty = false
end

function stationUniqueId()
  local uniqueId = entity.uniqueId()
  if not uniqueId then
    uniqueId = sb.makeUuid()
    world.setUniqueId(entity.id(), uniqueId)
  end
  return uniqueId
end

--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
--  WORK DISCOVERY AND DISPATCH
--------------------------------------------------------------------------------
--
--  Discovery belongs to the PORT, not the unit. Vanilla's seam is
--  querySurroundings -> reactToObject, which scans a radius around wherever the
--  unit happens to be standing -- work found that way would never touch the
--  coverage rect, and the rect is the whole point.

--  The unit's uniqueId, minting one if the engine has not.
--
--  Needed in two places: the claim records who is executing, and the unit calls
--  entity.uniqueId() when it reports back. Without this both are nil.
--
--  PROTOTYPE GAP: this id is minted fresh on every spawn, so it does NOT
--  survive a respawn. The design calls for it to be persisted on the item
--  alongside `seed` and reassigned at spawn, which is what makes a claim
--  survive a world reload. Fine while claims are cleared per load anyway.
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

--  Find a standing spot inside the rect.
--
--  x is snapped to a TILE CENTRE. A unit's boundBox is about a tile wide and
--  centred on its position, so a candidate at integer x straddles two tile
--  columns and only succeeds where both are clear -- the same trap
--  petports_placement.lua documents for resting positions.
--
--  UNVERIFIED: world.pointTileCollision's default collision kinds. If targets
--  come back inside blocks or floating, that default is the first thing to
--  check.
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

--  One diagnostic task at a time per port, so the work id is just the port's.
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

--  TASK 1 -- COLLECTING ITEM DROPS
--
--  Sweep the coverage rect for item drops and claim the nearest one nobody
--  else has spoken for.
--
--  The claim key is the drop's own entity id, which is exactly the property
--  that made drops the right first real task: no wiring, no routing graph, and
--  a naturally unique key. Entity ids do not survive a reload, but claims are
--  cleared per load anyway, so nothing depends on them persisting.
--
--  Drops DESPAWN on their own timer. That is a real deadline rather than an
--  edge case, and it is what exercises claim expiry without a contrived test.
--  Would some OTHER member of our network get to this faster?
--
--  Union dispatch means any port may send its unit into any member's coverage,
--  so without arbitration every port with a free unit races for the same drop
--  and the claim decides arbitrarily. Distance decides instead: the port whose
--  unit is nearest takes it, and the rest skip it.
--
--  Walls are ignored deliberately. A true reachability comparison would mean
--  pathfinding per candidate per drop, which is enormously more expensive than
--  the occasional wrong pick -- and a wrong pick self-corrects, because an
--  unreachable target fails fast and backs off.
local function anotherUnitIsCloser(position, ourDistance)
  for _, entry in ipairs(petports_networkMembers(stationUniqueId())) do
    if entry.unitPosition ~= nil and not entry.busy then
      if world.magnitude(entry.unitPosition, position) < ourDistance then
        return true
      end
    end
  end
  return false
end

local function collectionWork()
  --  Scan the whole NETWORK's coverage, not just our own rect. Queues stay
  --  port-owned -- see the handoff -- but a union is a view assembled at
  --  dispatch time, and this is that view.
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
    --  "None in range" and "none at all" look identical from inside the rect,
    --  and the difference is the whole question when tuning coverage. Scan a
    --  wider box and report what is out there.
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

  local origin = entity.position()
  local best, bestDistance = nil, nil

  for _, dropId in ipairs(drops) do
    local workId = "drop:" .. dropId
    local claim = petports_claimGet(workId)

    --  Someone else's live claim. Ours is fine to re-take.
    local failure = self.workFailures[workId]
    local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

    local free = not backedOff and ((claim == nil)
      or claim.owner == stationUniqueId()
      or (claim.expires or 0) <= world.time())

    if free and world.entityExists(dropId) then
      local position = world.entityPosition(dropId)
      if position ~= nil then
        --  Distance is measured from the UNIT, not the port -- it is the unit
        --  that has to walk.
        local from = origin
        if self.petId ~= nil and world.entityExists(self.petId) then
          from = world.entityPosition(self.petId)
        end

        local distance = world.magnitude(from, position)
        if (bestDistance == nil or distance < bestDistance)
           and not anotherUnitIsCloser(position, distance) then
          best, bestDistance = dropId, distance
        end
      end
    end
  end

  if best == nil then
    return nil, "all drops in rect are claimed or backed off after failing"
  end

  return {
    id = "drop:" .. best,
    type = "collect",
    port = stationUniqueId(),
    target = best,
    position = world.entityPosition(best)
  }
end

--  LEASHING
--
--  Vanilla wanderState has NO BOUNDS. An idle unit walks wherever it likes, and
--  with backoffs in play there is plenty of idle time -- observed 25+ tiles
--  outside the rect, onto terrain with no route back up to the deck.
--
--  From out there every target is genuinely unreachable, so the port fails
--  repeatedly and backs off drops that were never the problem. One stray unit
--  poisons the whole queue.
--
--  So: if the unit is outside its rect and there is no work in flight, walking
--  home IS the work.
--
--  RECALL ALONE IS NOT ENOUGH. A unit can strand itself somewhere with no route
--  back -- onto terrain below the deck, most easily -- and then recall fails as
--  surely as any other task. Because recall is checked BEFORE real work, a
--  stranded unit means the port dispatches nothing but doomed recalls and
--  ignores every item forever. Observed exactly that.
--
--  So recall gets a small retry budget, and then the unit is RE-HOMED: despawned
--  and respawned at the port. The unit's state lives in the item, so this costs
--  nothing except the walk it was going to make anyway, and it always works.
local function rehomeUnit(reason)
  sb.logInfo("PETPORT %s re-homing unit: %s", stationUniqueId(), reason)

  --  Round-trips state through the item, exactly as an unsocket would.
  saveAndDespawn()
  self.recallFailures = 0
  self.spawnTimer = 0
end

local function returnWork()
  local rect = coverageRect()

  if self.petId == nil or not world.entityExists(self.petId) then return nil end
  if inNetwork(world.entityPosition(self.petId)) then
    self.recallFailures = 0
    return nil
  end

  if (self.recallFailures or 0) >= RECALL_LIMIT then
    rehomeUnit("stranded outside rect at "
      .. sb.printJson(world.entityPosition(self.petId))
      .. " after " .. sb.printJson(RECALL_LIMIT) .. " failed recalls")
    return nil
  end

  --  RECALL TO A FIXED POINT, not a random one.
  --
  --  A random standing point each attempt gave the unit a different destination
  --  every time, some of them unreachable, and made recall look flaky when the
  --  unit was fine. The ground by the port is stable and is where we want it
  --  anyway.
  local position = findStandingPoint({
    entity.position()[1] - 4, entity.position()[2] - 4,
    entity.position()[1] + 4, entity.position()[2] + 4
  }) or findStandingPoint(rect)

  if position == nil then
    --  No standable spot in our own rect is a different problem, and recall
    --  cannot fix it either.
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

--  Real work first, diagnostic only as an opt-in filler.
local function findWork()
  --  Before anything else: a unit that has strayed cannot reach work anyway.
  local recall = returnWork()
  if recall ~= nil then return recall end

  local work, why = collectionWork()
  if work ~= nil then return work end

  if DIAG_FALLBACK then
    return diagnosticWork()
  end

  return nil, why
end

--  Every rejection gets a reason. These failures are all silent-nil shaped -- a
--  unit that does not move looks identical whether the port never discovered
--  the work, discovered and rejected it, or dispatched it to a unit that could
--  not path. A reason string collapses that to one line of log.
local function reject(reason)
  --  Log a reason ONCE, then only when it changes. "no drops in rect" once a
  --  second drowns everything else in the log, and a repeating identical reason
  --  carries no information the first line did not.
  --  Repeat suppression, NOT permanent suppression. A port stuck on one
  --  unchanging reason would otherwise print once and go silent forever, which
  --  reads as "stopped running" rather than "still refusing". Re-state the
  --  current reason periodically so a stuck port stays visible.
  if reason == self.lastReject
     and (self.lastRejectAt or 0) + REJECT_REPEAT > world.time() then
    return
  end

  self.lastReject = reason
  self.lastRejectAt = world.time()

  --  NOT gated behind DEBUG. Every one of these failures is silent-nil shaped:
  --  a unit that does not move looks identical whether the port never
  --  discovered work, discovered and rejected it, or dispatched to a unit that
  --  could not path. Hiding the reason behind a flag defeats the entire point
  --  of having one.
  sb.logInfo("PETPORT %s no dispatch: %s", stationUniqueId(), reason)
end


local function dispatchWork()
  if self.petId == nil or not world.entityExists(self.petId) then
    return reject("no unit")
  end

  local work, why = findWork()
  if work == nil then
    return reject(why)
  end

  --  RE-CHECK THE UNIT. findWork can reach rehomeUnit, which despawns the unit
  --  and nils self.petId -- so the guard at the top of this function was
  --  correct when it ran and stale by the time it matters. Calling
  --  callScriptedEntity with a nil id throws a LuaConversionException rather
  --  than returning nil, which kills the port's update.
  if self.petId == nil or not world.entityExists(self.petId) then
    return reject("unit went away while work was being chosen")
  end

  --  Belt and braces: the rect is authoritative for what may be claimed, and
  --  findStandingPoint is supposed to respect it. If this ever fires, the
  --  generator is wrong, not the check.
  if work.type ~= "collect" and not petports_rectContains(coverageRect(), work.position) then
    return reject("generated point outside rect")
  end

  if not petports_claimTake(work.id, stationUniqueId(), petUniqueId(),
                            work.type, work.position, CLAIM_TTL) then
    return reject("claimed by another owner")
  end

  if not world.callScriptedEntity(self.petId, "petports_assignTask", work) then
    --  The unit refused -- already holding something, or the contract is
    --  missing. Do not sit on a claim for work nobody is doing.
    petports_claimRelease(work.id, stationUniqueId())
    return reject("unit refused assignment")
  end

  self.task = work
  self.taskAge = 0
  self.lastReject = nil
  --  sb.logInfo takes %s ONLY. Star's formatter has no width or precision
  --  specifiers, so %.1f raises "Improper lua log format specifier".
  sb.logInfo("PETPORT %s dispatched %s to %s",
    stationUniqueId(), work.id, sb.printJson(work.position))
end

--  Called on the work timer while a task is believed to be in flight.
local function trackWork()
  --  Deadline first: a unit that accepted a task and then never entered its
  --  state reports nothing at all, and every check below would keep passing.
  self.taskAge = (self.taskAge or 0) + WORK_INTERVAL
  if self.taskAge >= TASK_DEADLINE then
    local taskId = self.task.id
    abandonTask("deadline -- no report in " .. sb.printJson(TASK_DEADLINE) .. "s")
    noteFailure(taskId, "deadline")

    --  The unit may still be holding it. Clear its side too, or it will keep
    --  re-queueing an assignment this port has forgotten.
    if self.petId ~= nil and world.entityExists(self.petId) then
      world.callScriptedEntity(self.petId, "petports_clearTask")
    end
    return
  end

  --  The unit died, was recalled, or respawned without its assignment. Stop
  --  refreshing and let the claim age out rather than releasing it here -- if
  --  the unit is merely mid-respawn it will not answer, and dropping the claim
  --  every time would churn replicated state.
  if self.petId == nil or not world.entityExists(self.petId) then
    self.task = nil
    return reject("unit gone mid-task")
  end

  if world.callScriptedEntity(self.petId, "petports_taskId") ~= self.task.id then
    --  The unit dropped it. It very likely also sent a report that is about to
    --  arrive and find self.task already nil, so account for the failure HERE
    --  rather than trusting the message to win the race.
    local taskId = self.task.id
    self.task = nil
    noteFailure(taskId, "unit stopped holding the task")
    return reject("unit is no longer holding the task")
  end

  petports_claimRefresh(self.task.id, stationUniqueId(), CLAIM_TTL)
end

local function workUpdate(dt)
  self.workTimer = self.workTimer - dt
  if self.workTimer > 0 then return end
  self.workTimer = WORK_INTERVAL

  petports_claimsSweep()
  refreshNetwork()
  publishUnitPosition()

  --  Cheap: loadUniqueEntity on an existing stagehand and out.
  ensureResidency()

  if self.task == nil then
    dispatchWork()
  else
    trackWork()
  end
end

function update(dt)
  if self.firstUpdate then
    self.firstUpdate = false
    stationUniqueId()

    --  A world unload orphaned every claim this port held. Clear our own --
    --  this runs exactly once per load, and no port ever touches another's.
    --
    --  Deliberately here rather than in init: stationUniqueId may call
    --  world.setUniqueId, which is why the id is established on the first
    --  update rather than at init in the first place.
    petports_claimsClearOwner(stationUniqueId())
    ensureResidency()
    publishRegistry()
  end

  local item = socketedItem()

  if item == nil then
    --  Item removed: put the unit away.
    if self.petId ~= nil then
      saveAndDespawn()
      self.petData = nil
    end
    animator.setAnimationState("portState", "off")

    --  This branch returns BEFORE workUpdate, so nothing below runs while the
    --  port sits empty -- no sweep, no refresh. A claim left here would survive
    --  until this port's next init cleared it. Release it on the way out.
    abandonTask("item removed")
    return
  end

  --  Newly socketed, or a different unit swapped in.
  --
  --  Swap detection uses `seed` as the identity token. groundPet.lua volunteers
  --  monster.seed() through setPet, and it is captured OUTSIDE the echo guard,
  --  so petData.seed is populated within the same tick a unit is socketed.
  --  Distinct units therefore have distinct seeds, and a used item never
  --  matches a pristine one (which has no seed at all).
  --
  --  The one gap left is two never-spawned items exchanged inside a single
  --  tick, which is about as narrow as it gets and self-corrects on the next
  --  socket.
  if self.petData ~= nil and itemSeed(item) ~= self.petData.seed then
    trace("item swapped, outgoing seed", self.petData.seed)
    saveAndDespawn(true)
    self.petData = nil
    abandonTask("unit swapped out")
  end

  if self.petData == nil then
    self.petData = petDataFrom(item)
    if self.petData == nil then
      --  Not a pet item, or a malformed one. Do nothing rather than spawning
      --  something unintended.
      animator.setAnimationState("portState", "off")
      abandonTask("socketed item is not a pet")
      return
    end
    self.spawnTimer = 0
  end

  animator.setAnimationState("portState", "on")

  --  Spawn, or respawn after an unload/death.
  if self.petId == nil or not world.entityExists(self.petId) then
    self.spawnTimer = self.spawnTimer - dt
    if self.spawnTimer <= 0 then
      if self.petId ~= nil then
        --  It existed and now does not. Keep whatever state we last heard.
        self.petId = nil
      end
      spawnPet()
      self.spawnTimer = RESPAWN_GRACE
    end
  end

  --  Immediate on a durable change, otherwise on the slow timer.
  self.writeTimer = self.writeTimer - dt
  if self.dirty or self.writeTimer <= 0 then
    writeBackToItem()
    self.writeTimer = WRITE_INTERVAL
  end

  workUpdate(dt)
end

function onInteraction(args)
  --  Falls through to the container UI declared by uiConfig on the object.
  return config.getParameter("interactAction")
end
