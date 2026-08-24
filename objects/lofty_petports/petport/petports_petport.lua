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
local DEBUG = true

--------------------------------------------------------------------------------
--  COVERAGE AND WORK
--------------------------------------------------------------------------------
--
--  The coverage rect is a square centred on the petport: the region this port
--  keeps resident, the area its unit may take work in, and the placement-time
--  visual, all one number.
--
--  64 TILES, RAISED FROM 32. One chunk turned out to be small in practice --
--  a modest base spans several, and a port that cannot see the room next door
--  is not doing logistics.
--
--  THIS NUMBER IS LOAD-BEARING IN FOUR PLACES, and doubling it does not scale
--  them equally:
--
--    residency  the stagehand holds this rect resident every update. AREA is
--               what costs, so 32 -> 64 is 4x, not 2x. Sectors load whole, so
--               the true resident set is larger still.
--    work scan  entityQuery per rect per work tick. Also area.
--    vents      gatherVents inflates by a further COVERAGE_SIZE on each side,
--               so the vent query rect goes from 96x96 to 192x192 -- 4x again,
--               on top of a per-vent callScriptedEntity for entry and another
--               for destinations.
--    eviction   registryClearAt is NOT affected: it matches the port's exact
--               tile and is deliberately independent of coverage.
--
--  Passed to the stagehand as `coverageSize` at spawn, so changing it here is
--  enough -- but only for stagehands spawned AFTER the change. An existing
--  residency keeps the size it was born with until its port respawns it.
local COVERAGE_SIZE = 64

--  How long a container that could not take a whole load is passed over for.
--
--  Not a permanent verdict. A player empties chests, and a chest that was full
--  a minute ago usually is not.
local CONTAINER_FULL_BACKOFF = 60.0

--  How often to re-scan containers for beacons.
--
--  Slow on purpose. A beacon is put in a chest ONCE and then sits there; what
--  changes constantly is the chest's other contents, which this does not care
--  about. Meanwhile the scan reads every container in coverage, and coverage
--  just became four times the area.
local BEACON_INTERVAL = 5.0

--  The config key a beacon item carries. See
--  /items/lofty_petports/beacons/petports_beacon_deposit.activeitem.
local BEACON_KEY = "petports_sortingBeaconBehavior"

--  Set by the beacon's configuration pane. Absent means ON -- see
--  beaconBehaviorOf.
local BEACON_ENABLED_KEY = "petports_beaconEnabled"

--  How long a claim survives without a refresh. Long enough to walk across the
--  rect, short enough that an abandoned job frees up while the player watches.
--------------------------------------------------------------------------------
--  HARVESTING
--------------------------------------------------------------------------------
--
--  How often the network is swept for farmables. SLOW ON PURPOSE, for the same
--  reason the beacon scan is: crops change state on the order of twenty
--  minutes, and an entityQuery for every object across the whole network is
--  not something to run on the work tick.
--
--  KNOWN COST, NOT YET PAID DOWN: this is a SECOND full object sweep of the
--  network alongside scanContainers, on its own timer. Folding both into one
--  query is the obvious saving and was deliberately not done here -- it means
--  editing a verified working path to add an unverified one, and the process
--  note in the handoff is emphatic about not stacking changes like that. Fold
--  it once harvesting is proven.
local HARVEST_INTERVAL = 5.0

--  WHICH NUMBER world.farmableStage COUNTS FROM. UNVERIFIED.
--
--  The stages array in a farmable's config is a Lua list, so its harvest stage
--  sits at Lua index #stages. What world.farmableStage returns for that same
--  stage is not documented and HarvesterBeam never compares it to anything --
--  it only ever tests the value for nil-ness and number-ness, so it proves
--  nothing either way.
--
--  0 assumes engine-side indexing, which is the ordinary C++ convention and
--  what corn's "resetToStage" : 2 reads as (its harvest stage is the fourth
--  entry, resetting to the third).
--
--  IF THIS IS WRONG the symptom is specific and visible: ripeness is tested
--  with EQUALITY, so a wrong base means the unit either never harvests at all,
--  or fires one stage early. The farmable scan logs every crop's stage against
--  its stage count on change, so ONE LOOK AT THE LOG SETTLES IT -- find a crop
--  you can see is fully grown and read what number it reports.
--
--  Firing early is bounded rather than harmless: FarmableObject::damageTiles
--  falls through to ordinary object damage when harvest() declines, so an
--  early fire damages the crop rather than picking it. HARVEST_DAMAGE, on the
--  unit, is sized so that costs little, and a harvest that does not change it is
--  reported as a failure, which puts it on the standard backoff ladder instead
--  of hammering it once a second.
local FARMABLE_STAGE_BASE = 0

--  NOTE the damage amount and harvest level live on the UNIT, in
--  petportsTaskAction.lua, because the unit is what swings. Every script in a
--  monstertype shares one environment and an object has its own; a constant
--  declared here would be a nil global there, inside a pcall, presenting as
--  "damageTiles does not work" rather than as a missing value.

--------------------------------------------------------------------------------
--  WATERING
--------------------------------------------------------------------------------
--
--  How many tiles one dispatch may cover, and therefore how many units of
--  liquid a unit fetches per trip.
--
--  ONE ITEM PER TILE is the economy, deliberately stricter than vanilla, which
--  charges consumeLiquid 0.5 per interaction. But one item per tile does NOT
--  mean one TRIP per tile: a forty-tile row would otherwise be forty round
--  trips to a crate, which is absurd to watch and pointless to simulate.
--
--  The cap also bounds the task. A run is capped at this length, so a long row
--  becomes several sweeps rather than one task that outlives TASK_DEADLINE.
local WATER_CARRY = 10

--  How far to look left and right from a crop for more dry soil.
--
--  A bot that waters only the tile under the crop leaves a checkerboard. The
--  least a fleet can do is finish the row it is standing in -- soil that is
--  tilled and dry and contiguous is planting-ready ground somebody prepared on
--  purpose.
local WATER_RUN_REACH = 32

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

--  Consecutive unreachable-target failures before the unit is treated as
--  SEALED IN rather than merely unlucky.
--
--  Distinct from RECALL_LIMIT, which counts failures to walk home. This counts
--  failures to reach WORK, and it exists because those are the only symptom a
--  unit shut inside a room ever produces.
--
--  Small on purpose. A genuinely unreachable target fails fast once its edges
--  are cached, so three in a row is seconds of evidence, not minutes -- and a
--  unit that can still reach anything at all resets this on its first success.
local STRANDED_LIMIT = 3

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
  --  OUR POSITION, not our rect. Clearing by rect evicted every other port
  --  within sixteen tiles -- see petports_registryClearAt.
  petports_registryClearAt(entity.position(), stationUniqueId())

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

  --  NIL IS NOT MOVEMENT WHEN IT WAS ALREADY NIL.
  --
  --  This read `position == nil or entry.unitPosition == nil or <distance>`,
  --  so an empty port -- position permanently nil -- computed moved = true on
  --  every single tick, skipped the unchanged-state early return below, and
  --  republished forever. Each publish bumps the shared registry version, and
  --  every port polls that version and re-derives its network and re-gathers
  --  its vents when it moves.
  --
  --  Measured: one empty port drove the version from 17249 to 18037 in about
  --  sixty-five seconds, so every port in the world re-ran gatherVents roughly
  --  twelve times a second for as long as it sat there.
  --
  --  What is actually being asked is "has anything changed", and going from no
  --  unit to no unit is not a change.
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

  --  Explicit, so a reader never has to infer "has a unit" from a position that
  --  might merely be stale.
  entry.hasUnit = position ~= nil
  petports_registryPublish(stationUniqueId(), entry)
end

--  Vents inside the network's coverage, with where they come out.
--
--  The PORT gathers this because it already knows the network's rects and can
--  query objects cheaply. It cannot evaluate REACHABILITY -- pathfinding needs
--  mcontroller, which objects do not have -- so the unit does that part.
local function gatherVents()
	local ventReport = {}

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

        --  EVERY vent is listed, including ones with no exits.
        --
        --  Requiring destinations used to drop receive-only and unlinked vents
        --  from the list entirely -- and pruneRouteCache treats absence from
        --  the list as "this vent is gone", so their cached edges were deleted
        --  on every refresh and re-probed from scratch when they came back.
        --  Under directional wiring a terminal vent legitimately has no exits,
        --  so that would have thrown away good probe work constantly.
        --
        --  Pruning now means only what it says: the vent was physically
        --  removed. planRoute skips vents it cannot traverse.
        local exits = {}
        for _, destination in ipairs(dests or {}) do
          table.insert(exits, destination.id)
        end

        --  Accumulated and reported once per refresh, change-gated below.
        --  Was one line per vent per refresh: 339 vents-worth of identical
        --  wiring in a single session.
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

  --  ONE LINE PER REFRESH, AND ONLY WHEN THE WIRING CHANGES. Vent topology is
  --  static until a player rewires something, so re-stating it every few
  --  seconds is pure noise -- but losing it entirely means a mis-wired vent
  --  becomes invisible. Change-gating keeps the signal and drops the volume.
  table.sort(ventReport)
  local signature = table.concat(ventReport, " | ")

  --  DELIBERATELY NOT self.ventSignature -- refreshNetwork owns that one for
  --  ventSignature(vents), and sharing it made both change-gates fire on every
  --  call. The visible symptom was "vent topology changed" once a second; the
  --  invisible one was unitChanged going true with it, so the port re-pushed
  --  rects and vents to its unit every tick.
  if signature ~= self.ventReportSignature then
    self.ventReportSignature = signature
    sb.logInfo("PETPORT %s vents: %s", stationUniqueId(),
      signature == "" and "none" or signature)
  end

  return vents
end

--  A stable signature for the gathered vent list: every vent and every exit it
--  offers. Compared as a string so a rewiring is detected without a deep diff.
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

--  Drop cached edges that name a vent which no longer exists.
--
--  NOT A BLANKET CLEAR, unlike the coverage path above. The two cases are not
--  alike: a coverage change moves terrain the cache was derived from, while a
--  rewiring changes only which exits connect to which. Every cached edge is a
--  WALKABILITY fact -- "from the exit of vent 17, can this unit walk to vent
--  18's mouth" -- and rewiring 84 makes none of them false.
--
--  The distinction is worth the extra code because probing is the single most
--  expensive thing the system does. An instrumented cold cache spent 47 seconds
--  on one plan, all of it A* exhaustion on unreachable edges. Discarding that to
--  react to a wire being moved would be a far worse trade than the stale entry
--  it protects against, and vanished ids are the only genuinely dead entries.
local function pruneRouteCache(vents)
  if self.routeCache == nil then return 0 end

  local live = {}
  for _, vent in ipairs(vents or {}) do live[tostring(vent.id)] = true end

  local removed = 0
  for key in pairs(self.routeCache) do
    --  Keys are "<from>><to>", where a vent appears as "e:<id>" or "x:<id>".
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

    --  VENTS ARE A FIRST-CLASS TRIGGER, NOT A PASSENGER.
    --
    --  gatherVents used to be called only inside the push block below, and that
    --  block only ran when the RECTS changed. A vent rewired in place bumps the
    --  version, moves no rect, and so pushed nothing -- the unit kept its old
    --  vent list and kept planning routes through exits that no longer existed.
    --
    --  Gathered after the rect update above, since it reads self.networkRects.
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

  --  Also push on a fresh unit, which has no list yet, and whenever the route
  --  cache has learned something -- other units on this port benefit from what
  --  one of them discovered.
  if (unitChanged or self.routeDirty or self.pushedToPet ~= self.petId)
     and self.petId ~= nil and world.entityExists(self.petId) then
    world.callScriptedEntity(self.petId, "petports_setNetwork",
      self.networkRects, entity.position())

    --  Vent list rides the same push. Entity ids are not stable across a
    --  reload, which is fine: this is re-gathered and re-pushed on every spawn.
    --
    --  Reuses the list gathered above when there is one. This block also fires
    --  on a fresh unit with the version unmoved, so it must still be able to
    --  gather for itself.
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

  --  COUNT FAILURES THAT MEAN "CANNOT GET THERE FROM HERE".
  --
  --  A unit sealed into a room by a rewiring produces exactly one symptom: every
  --  target becomes unroutable. It never strays, never dies, and never misses a
  --  deadline once its edges are cached -- it just fails everything, instantly,
  --  forever. Counting that is the only way the port can notice.
  --
  --  Reset by any successful task, so a single awkward drop behind a locked
  --  door cannot accumulate its way to a re-home.
  sb.logInfo("PETPORT %s noteFailure %s: %s", stationUniqueId(), taskId, tostring(reason))

  if string.find(reason or "", "no vent route", 1, true) ~= nil
     or string.find(reason or "", "no route", 1, true) ~= nil then
    self.unreachableFailures = (self.unreachableFailures or 0) + 1
    sb.logInfo("PETPORT %s unreachable failure %s of %s: %s",
      stationUniqueId(), self.unreachableFailures, STRANDED_LIMIT, reason)
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
  self.unreachableFailures = 0
  self.taskAge = 0
  self.registryVersion = -1
  self.networkRects = nil
  self.vents = nil
  self.ventSignature = nil

  --  Route cache: "<destination tile>|<vent exit id>" -> bool.
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

    --  Before anything else: the unit may be handing over an item, and the
    --  world drop for it is already gone. Nothing below this may return early
    --  ahead of it.
    if report.cargo ~= nil then
      receiveCargo(report.cargo)
    end

    --  Arrived at a deposit container. The port does the transfer, not the
    --  unit: the cargo has been on petData the whole time, so it never has to
    --  exist anywhere else and there is no second window to lose it in.
    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "deposit" and self.task.id == report.id then
      depositCargo(self.task.target)
    end

    --  Arrived at a crate holding a seed. Symmetric with deposit above: the
    --  container call happens HERE, on the port, so the unit never needs a
    --  container primitive of its own.
    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "withdraw" and self.task.id == report.id then
      withdrawSeed(self.task.target, self.task.seed, self.task.id,
        self.task.count)
    end

    --  Tiles were wetted. Spend one item per tile actually done.
    --
    --  COUNTED FROM THE REPORT, not from the task's tile list. A unit that ran
    --  out of walking time partway through the sweep did fewer tiles than it
    --  was given, and charging it for the whole run would quietly destroy
    --  liquid that is still in its cargo.
    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "water" and self.task.id == report.id then
      local watered = tonumber(report.watered) or 0

      for _ = 1, watered do
        spendSeed(self.task.item)
      end

      sb.logInfo("PETPORT %s watering finished: %s tile(s), %s %s spent",
        stationUniqueId(), sb.printJson(watered), sb.printJson(watered),
        tostring(self.task.item))
    end

    --  The crop went in the ground. Spend the seed and retire the intent.
    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "replant" and self.task.id == report.id then
      spendSeed(self.task.seed)
      petports_replantClear(self.task.target, "replanted")
    end

    --  A HARVEST THAT LEFT A HOLE BECOMES AN INTENT.
    --
    --  Decided here rather than on the unit because the port is the thing that
    --  can still answer it: entityExists on a crop that reset is true, on one
    --  that was destroyed is false, and that single test is the whole
    --  resetToStage distinction without reading any config.
    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "harvest" and self.task.id == report.id then
      if not world.entityExists(self.task.target)
         and self.task.targetName ~= nil then
        petports_replantSet(self.task.position, self.task.targetName,
          stationUniqueId())
      end
    end

    if report.outcome == "done" then
      self.workFailures[report.id] = nil

      --  It got somewhere. Whatever the last few failures were, it is not
      --  sealed in.
      self.unreachableFailures = 0
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
    --  Entries carry when they were learned so the unit can expire them; see
    --  ROUTE_TTL_FALSE in petports_contract.lua. The port only stores and
    --  forwards them, it does not interpret them.
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

--  WRITE CARGO THROUGH IMMEDIATELY, not on the slow timer.
--
--  Everything else on petData is RE-DERIVABLE -- resource levels, known players,
--  food likings all come back from the live unit, so deferring those to
--  WRITE_INTERVAL costs nothing worse than a stale number. Cargo is not like
--  that. takeItemDrop has already destroyed the world drop, so between the
--  handover and the write the item exists in exactly one place: this port's RAM.
--  A crash, an unload, or a player mining the port in that window loses it.
--
--  Cheap by nature: this fires once per pickup, and a pickup involves a unit
--  walking somewhere. It cannot become the per-tick write storm WRITE_INTERVAL
--  exists to prevent.
--
--  dirty stays set first, so if the write cannot land -- no socketed item,
--  which happens if the unit item was pulled mid-task -- the normal timer
--  retries instead of the change being dropped.
local function flushCargo()
  self.dirty = true
  writeBackToItem()
  self.writeTimer = WRITE_INTERVAL

  --  DISPATCH ON THE NEXT TICK, not on the next work interval.
  --
  --  A unit that has just picked something up should be walking to a chest
  --  immediately. Waiting out WORK_INTERVAL is a second of a loaded unit
  --  standing still for no reason, and it reads as the port having missed the
  --  handover entirely.
  --
  --  Zeroing the timer rather than calling dispatchWork here on purpose: the
  --  report handler is still unwinding, self.task is not cleared until it
  --  finishes, and dispatching into that would collide with the task being
  --  closed.
  self.workTimer = 0
end

--------------------------------------------------------------------------------
--  BEACONS AND CONTAINERS
--------------------------------------------------------------------------------
--
--  A CONTAINER DECLARES ITS OWN PURPOSE BY ITS CONTENTS. Drop a beacon item in
--  a chest and the chest becomes a deposit target; take it out and it stops.
--
--  Deliberately not a registry of designated containers. A registry has to be
--  kept in step with a world where chests are mined, moved, and replaced, and
--  it leaks an entry every time that goes wrong. Reading the container answers
--  the question from the only authority that cannot disagree with itself.

--  What behaviour, if any, does this item declare?
--
--  Parameters first, then config -- the same precedence petData uses, so a
--  configured beacon can override its template later without changing how it
--  is found.
local function beaconBehaviorOf(item)
  if item == nil or item.name == nil then return nil end

  --  OFF IS INVISIBLE, NOT A SEPARATE STATE.
  --
  --  A disabled beacon is not "a beacon the port ignores" -- it is not a
  --  beacon at all as far as everything downstream is concerned. That is what
  --  lets a player park spares in a chest: an off beacon is an ordinary item,
  --  it tasks nothing, and the scan walks straight past it to whatever else is
  --  in the container.
  --
  --  Instance parameters only. There is no config default here on purpose --
  --  a beacon that has never been opened has no parameter and is ON, which is
  --  safe because a loose beacon can only ever land in a container that was
  --  ALREADY a target. It cannot task a new one.
  if item.parameters ~= nil and item.parameters[BEACON_ENABLED_KEY] == false then
    return nil
  end

  if item.parameters ~= nil and item.parameters[BEACON_KEY] ~= nil then
    return item.parameters[BEACON_KEY]
  end

  --  Unguarded on purpose. An item in a container HAS a config -- Starbound
  --  fails world load outright on a missing item definition rather than
  --  degrading, so a world holding one never reaches this line.
  return root.itemConfig(item).config[BEACON_KEY]
end

--  Every container in coverage that holds a beacon.
local function scanContainers()
  local rects = self.networkRects
  if rects == nil or #rects == 0 then rects = { coverageRect() } end

  local found = {}
  local seen = {}
  local containers = 0

  for _, rect in ipairs(rects) do
    local ids = world.entityQuery({ rect[1], rect[2] }, { rect[3], rect[4] }, {
      includedTypes = { "object" }
    })

    for _, id in ipairs(ids) do
      if not seen[id] then
        seen[id] = true

        --  containerSize is the test for "is this a container". Checking the
        --  object name against a list would miss every modded chest, and there
        --  are a lot of modded chests.
        local okSize, size = pcall(world.containerSize, id)

        if okSize and size ~= nil and size > 0 then
          containers = containers + 1

          local okItems, items = pcall(world.containerItems, id)
          if okItems and items ~= nil then
            --  SLOT ORDER, EXPLICITLY.
            --
            --  containerItems is keyed by SLOT and empty slots leave holes, so
            --  ipairs stops at the first gap and pairs is the only way to see
            --  every item. But pairs order is nondeterministic, and with two
            --  beacons in one container that made the winner change between
            --  scans -- a chest that silently swapped roles every five seconds
            --  and would have been diagnosed as anything but this.
            --
            --  Collect the keys, sort them, then walk. First ENABLED beacon in
            --  slot order decides the container, every time.
            local slots = {}
            for slot in pairs(items) do
              table.insert(slots, slot)
            end
            table.sort(slots)

            for _, slot in ipairs(slots) do
              local item = items[slot]
              local behavior = beaconBehaviorOf(item)

              if behavior ~= nil then
                table.insert(found, {
                  id = id,
                  position = world.entityPosition(id),
                  behavior = behavior,
                  name = world.entityName(id)
                })
                --  One ENABLED beacon decides a container. A second is the
                --  player's business, not ours -- and a disabled one never got
                --  here, so it cannot shadow an enabled beacon below it.
                break
              end
            end
          end
        end
      end
    end
  end

  return found, containers
end

local function refreshBeacons(dt)
  self.beaconTimer = (self.beaconTimer or 0) - dt
  if self.beaconTimer > 0 then return end
  self.beaconTimer = BEACON_INTERVAL

  local found, containers = scanContainers()
  self.beacons = found

  --  Change-gated on the SIGNATURE, not the count. Two chests swapping roles
  --  keeps the count identical and is exactly the event worth seeing; and at
  --  one scan every five seconds forever, an unconditional line is noise.
  local parts = {}
  for _, beacon in ipairs(found) do
    table.insert(parts, string.format("%s@%s,%s=%s", tostring(beacon.id),
      tostring(math.floor(beacon.position[1])),
      tostring(math.floor(beacon.position[2])),
      tostring(beacon.behavior)))
  end
  table.sort(parts)
  local signature = table.concat(parts, " ")

  if signature ~= self.beaconSignature then
    self.beaconSignature = signature
    sb.logInfo("PETPORT %s beacons: %s of %s container(s) in coverage -- %s",
      stationUniqueId(), sb.printJson(#found), sb.printJson(containers),
      signature == "" and "none" or signature)
  end
end

--  Beacons matching a behaviour, nearest first. The deposit task will want the
--  nearest one it can actually reach; nearest-first is the order to try.
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

--  CARGO HANDOVER.
--
--  Lives on petData, so writeBackToItem persists it with everything else and no
--  new write path is needed. Deliberately NOT routed through the monster's
--  storage table: that syncs via setAnchor's params echo, which whitelists
--  specific fields and IGNORES the first callback after a spawn to avoid
--  overwriting a restore. Suppression is right for state the unit re-derives and
--  wrong for an item that exists exactly once.
--
--  Cargo is also not handed to the monster on spawn. The port owns it; the unit
--  is a courier, not a container.
--  GLOBAL, not local, and that is load-bearing. The petports_taskReport handler
--  is registered in init() -- earlier in the file than this definition -- so a
--  `local function` here is not in scope at the call site and resolves to nil.
--  Globals resolve at call time, which is why writeBackToItem below is one too.
function receiveCargo(item)
  if item == nil or item.name == nil then return end

  if self.petData == nil then
    --  Cargo with nowhere to go. The world drop is already destroyed, so this
    --  is a real item loss and it gets logged as an error rather than dropped
    --  silently -- the whole point of tracing this path.
    sb.logError("PETPORT %s received cargo with no petData -- ITEM LOST: %s",
      stationUniqueId(), sb.printJson(item))
    return
  end

  self.petData.cargo = self.petData.cargo or {}

  --  MERGE INTO AN EXISTING STACK where the descriptor matches. Fifty pickups
  --  of the same block should be one entry of fifty, not fifty entries -- this
  --  goes into item parameters, and parameters are serialised with the item
  --  every write.
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

  --  NO CAPACITY LIMIT YET, on purpose. A cap that silently drops items is
  --  worse than no cap; the right shape is the port refusing to DISPATCH
  --  collection when full, and that belongs with the deposit task. Until then
  --  this count is how unbounded growth becomes visible.
  sb.logInfo("PETPORT %s cargo +%s %s (new stack, %s stack(s) held)",
    stationUniqueId(), sb.printJson(item.count or 1), tostring(item.name),
    sb.printJson(#self.petData.cargo))

  flushCargo()
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
--  Resolve a standing position by ASKING THE UNIT.
--
--  The unit owns the only correct test -- see petports_standingPointNear in
--  petports_contract.lua for why the port's own geometry cannot answer this.
--  callScriptedEntity is synchronous, so this costs one call and no round trip.
--
--  Falls back to findStandingPoint when there is no unit to ask. That fallback
--  is KNOWN TO BE WRONG for any unit whose boundBox bottom is not a whole tile,
--  and it is here only so a port with no unit socketed still produces something
--  rather than nil. Anything dispatched to a unit should go through this
--  function, not findStandingPoint directly.
local function standingPointNear(position, radius)
  if self.petId ~= nil and world.entityExists(self.petId) then
    local ok, resolved = pcall(world.callScriptedEntity, self.petId,
      "petports_standingPointNear", position, radius or 4)

    if ok and resolved ~= nil then return resolved end

    sb.logInfo("PETPORT %s unit could not resolve a standing point near %s (called %s)",
      stationUniqueId(), sb.printJson(position), tostring(ok))
  end

  return nil
end

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
--  How long to keep deferring a drop to a unit that is not taking it.
--
--  Deferral is a TIE-BREAK, NOT A VETO. Straight-line distance says nothing
--  about whether the other unit can actually get there, and in a player's base
--  it is routinely wrong: a unit three tiles from a drop through a cage wall
--  reads as nearer than a free unit twenty tiles away with a clear path.
--
--  Worse, the veto had no timeout. If the "closer" unit never takes the drop --
--  wrong side of a wall, idle, already failing it -- every port deferred
--  forever and nobody collected anything. Observed with a caged unit: the port
--  reported drops as claimed or backed off when in truth it was standing aside
--  for a neighbour that was never going to move.
--
--  After this many seconds of a drop sitting unclaimed, take it anyway. Long
--  enough that a genuinely closer unit wins the race in normal play, short
--  enough that a player notices nothing.
local DEFER_GRACE = 12.0

local function anotherUnitIsCloser(position, ourDistance)
  for _, entry in ipairs(petports_networkMembers(stationUniqueId())) do
    --  A port with no unit socketed cannot take anything, whatever position it
    --  last published. Belt and braces against a stale entry surviving a crash,
    --  an unload, or a version of this file that stopped publishing on empty.
    if entry.unitPosition ~= nil and not entry.busy and entry.hasUnit ~= false then
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

  sb.logInfo("PETPORT %s scan: %s drops in %s rects",
    stationUniqueId(), sb.printJson(#drops), sb.printJson(#rects))

  local origin = entity.position()
  local best, bestDistance = nil, nil

  --  Why each drop was passed over. The old message named only two of the three
  --  possible causes, so deferral -- the one that can deadlock -- was invisible
  --  and presented as a backoff that did not exist.
  local rejected = { claimed = 0, backedOff = 0, deferred = 0, gone = 0 }

  self.deferredSince = self.deferredSince or {}
  local stillDeferred = {}

  for _, dropId in ipairs(drops) do
    local workId = "drop:" .. dropId
    local claim = petports_claimGet(workId)

    --  Someone else's live claim. Ours is fine to re-take.
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
    else
      local position = world.entityPosition(dropId)
      if position == nil then
        rejected.gone = rejected.gone + 1
      else
        --  Distance is measured from the UNIT, not the port -- it is the unit
        --  that has to walk.
        local from = origin
        if self.petId ~= nil and world.entityExists(self.petId) then
          from = world.entityPosition(self.petId)
        end

        local distance = world.magnitude(from, position)

        --  Stand aside for a closer unit, but only for a while. See DEFER_GRACE.
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

  --  Drops no longer being deferred stop accruing. Rebuilt each pass rather
  --  than pruned, so a drop that vanishes cannot leak an entry.
  self.deferredSince = stillDeferred

  if best == nil then
    return nil, string.format(
      "%s drops in rect, none takeable: %s claimed, %s backed off, "
      .. "%s deferred to a closer unit, %s gone",
      #drops, rejected.claimed, rejected.backedOff,
      rejected.deferred, rejected.gone)
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
--  Despawn and respawn at the port. The unit's learned state lives in the item,
--  so this costs nothing but the walk it was going to fail anyway.
local function rehomeUnit(reason)
  sb.logInfo("PETPORT %s re-homing unit: %s", stationUniqueId(), reason)

  --  Round-trips state through the item, exactly as an unsocket would.
  saveAndDespawn()
  self.recallFailures = 0
  self.unreachableFailures = 0
  self.spawnTimer = 0
end

local function returnWork()
  local rect = coverageRect()

  if self.petId == nil or not world.entityExists(self.petId) then return nil end

  --  STRANDED IS ABOUT REACHABILITY, NOT GEOGRAPHY.
  --
  --  This used to return early whenever the unit was inside coverage, on the
  --  assumption that a unit in the rect is a unit that is fine. A player
  --  unlinking the only vent out of an enclosed corridor breaks that: the unit
  --  sits WELL INSIDE the rect and cannot reach a single thing, including the
  --  port. The early return also reset recallFailures, so the counter could
  --  never climb and rehomeUnit -- the one thing that could have freed it --
  --  was unreachable code.
  --
  --  Both predicates now have to agree the unit is healthy. If it is failing to
  --  reach work, it falls through to the recall ladder regardless of where it
  --  is standing: a recall is attempted first, because a unit that CAN walk
  --  home should, and only a unit that cannot gets despawned and respawned.
  local stranded = (self.unreachableFailures or 0) >= STRANDED_LIMIT
  local inside = inNetwork(world.entityPosition(self.petId))

  --  THIS DECISION PRE-EMPTS ALL COLLECTION. returnWork is consulted before
  --  collectionWork, so whenever it returns a task the port collects nothing --
  --  and until now it did that silently.
  sb.logInfo("PETPORT %s returnWork: unit at %s inNetwork %s stranded %s (unreachableFailures %s of %s, recallFailures %s of %s)",
    stationUniqueId(), sb.printJson(world.entityPosition(self.petId)),
    tostring(inside), tostring(stranded),
    sb.printJson(self.unreachableFailures or 0), sb.printJson(STRANDED_LIMIT),
    sb.printJson(self.recallFailures or 0), sb.printJson(RECALL_LIMIT))

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
--  DEPOSIT: THE UNIT IS CARRYING SOMETHING AND SHOULD NOT BE DOING ANYTHING ELSE.
--
--  ANY CARGO IS A FULL LOAD, deliberately. One pixel and a thousand dirt are
--  the same state: "holding something, go put it down". Working out how many
--  radishes fit before a trip back is a real feature and not this one -- and
--  the version of it that guesses wrong is worse than the version that always
--  returns.
--  CAN THIS CRATE TAKE ANY OF WHAT WE ARE CARRYING?
--
--  Asks the engine the same question depositing asks, WITHOUT depositing.
--  world.containerItemsCanFit runs the real merge rules -- matching descriptors
--  top up existing partial stacks, non-matching ones need a free slot -- so a
--  crate with no empty slots but a half-full stack of the thing we are holding
--  correctly reads as usable.
--
--  WHY THIS REPLACES A BACKOFF. `fullContainers` marked the whole crate refused
--  for 60s the moment ANY stack bounced. One steak that needed a free slot
--  therefore diverted every stackable item in the load to a second crate, when
--  those items would have merged into stacks already sitting in the first. The
--  refusal was about one descriptor and was applied to all of them.
--
--  Returns nil when the engine cannot be asked, so the caller can fall back
--  rather than treating "unknown" as "no".
local function containerTakesAny(containerId)
  if world.containerItemsCanFit == nil then return nil end
  if self.petData == nil or self.petData.cargo == nil then return nil end

  for _, stack in ipairs(self.petData.cargo) do
    local fits = world.containerItemsCanFit(containerId, stack)
    if fits ~= nil and fits > 0 then return true end
  end

  return false
end

local function depositWork()
  if self.petData == nil then return nil end
  if self.petData.cargo == nil or #self.petData.cargo == 0 then return nil end

  local targets = petports_beaconsFor("deposit")
  if #targets == 0 then
    --  Change-gated by the reject machinery upstream; a unit with cargo and no
    --  beacon anywhere is a state the player needs to see, not a per-second
    --  line.
    return nil, "carrying " .. sb.printJson(#self.petData.cargo)
      .. " stack(s) but no deposit beacon in coverage"
  end

  local now = world.time()
  self.fullContainers = self.fullContainers or {}

  for _, beacon in ipairs(targets) do
    --  Ask the crate directly. Only if the engine will not answer do we fall
    --  back to the blunt time-based backoff.
    local takesAny = containerTakesAny(beacon.id)
    local backedOff

    if takesAny == nil then
      backedOff = (self.fullContainers[beacon.id] or 0) > now
      if backedOff then
        sb.logInfo("PETPORT %s deposit target %s SKIPPED: was full, retrying in %s (no containerItemsCanFit)",
          stationUniqueId(), sb.printJson(beacon.id),
          sb.printJson((self.fullContainers[beacon.id] or 0) - now))
      end
    else
      backedOff = not takesAny
      if backedOff then
        --  NAMES THE STACKS, not just the count. Cargo can now be mixed -- a
        --  unit may hold an undepositable stack AND a seed it is on its way to
        --  plant -- so "cannot take any of 2 stacks" stopped being enough to
        --  tell a full crate from a wrong-item crate.
        local held = {}
        for _, stack in ipairs(self.petData.cargo) do
          table.insert(held, string.format("%sx%s",
            tostring(stack.name), tostring(stack.count or 1)))
        end

        sb.logInfo("PETPORT %s deposit target %s SKIPPED: cannot take any of [%s]",
          stationUniqueId(), sb.printJson(beacon.id), table.concat(held, ", "))
      end
    end

    if backedOff then
      --  nothing further; try the next beacon
    else
      --  Stand next to the container, not on it. The container's own position
      --  is not a standing position for the same reason a petport's is not --
      --  see the arrival test in PathMover:move, which wants the vertical
      --  component under one tile.
      --
      --  Resolved BY THE UNIT. A point the unit cannot occupy is rejected by
      --  validStandingPosition before pathing starts, which fails the last leg
      --  of the route and therefore the entire plan -- the unit does not move at
      --  all, and the log reads as a vent failure rather than a bad target.
      local stand = standingPointNear(beacon.position, 4)

      if stand == nil then
        sb.logInfo("PETPORT %s deposit target %s SKIPPED: no standable spot within 4 tiles of %s",
          stationUniqueId(), sb.printJson(beacon.id), sb.printJson(beacon.position))
      else

        return {
          --  KEYED BY CONTAINER **AND PORT**. The port half is what matters.
          --
          --  This was keyed by container alone, on the reasoning that
          --  serialising deposits into one chest cost nothing. It cost five
          --  units. Claims are exclusive, so the first port to claim
          --  "deposit:24" owned the crate outright and every other port was
          --  refused with "claimed by another owner" -- their units got no
          --  task, fell back to station-keeping, walked a couple of tiles
          --  toward their ports, were re-dispatched, and were refused again.
          --  That shuffle is what looked like units stuck sliding back and
          --  forth on two tiles.
          --
          --  There is nothing to serialise. containerAddItems already returns
          --  its own overflow per call, so two units arriving at once each get
          --  a truthful answer about what was taken, and each backs the
          --  container off independently if it filled.
          --
          --  Container id stays in the string for readability in claims and
          --  logs; the port id is what makes it non-exclusive.
          id = "deposit:" .. tostring(beacon.id) .. "@" .. stationUniqueId(),
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

--  Take one seed out of a container and put it on the unit.
--
--  GLOBAL for the same reason depositCargo is: the petports_taskReport handler
--  is registered in init(), earlier in this file than the definition, so a
--  local would not be in scope at the call site.
--
--  containerConsume is all-or-nothing -- it succeeds only if the FULL count can
--  be consumed -- which is exactly the semantics wanted for taking exactly one.
function withdrawSeed(containerId, seedName, workId, count)
  if seedName == nil then return end

  --  count is 1 for seeds and the run length for liquid. Same call either way;
  --  containerConsume is all-or-nothing on the full count, so asking for more
  --  than the crate holds fails cleanly rather than half-filling the unit.
  count = count or 1

  --  A WITHDRAW THAT TAKES NOTHING MUST BE RECORDED AS A FAILURE, and this is
  --  the whole reason this function knows its work id.
  --
  --  The unit walked there and reported "done" -- it did arrive, and arriving
  --  is all it was asked to do. The report handler treats done as success and
  --  CLEARS the failure record for that id. So if containerAvailable and
  --  containerConsume ever disagree persistently, the port re-dispatches the
  --  identical walk immediately, and the unit shuttles to an empty crate
  --  forever with no backoff and nothing in the log that looks wrong.
  --
  --  Ordinarily that disagreement means a player emptied the crate mid-walk,
  --  which resolves itself. The backoff exists for the case where it does not.
  local function empty(reason)
    sb.logInfo("PETPORT %s withdraw of %s from %s took nothing: %s",
      stationUniqueId(), tostring(seedName), sb.printJson(containerId), reason)

    if workId ~= nil then noteFailure(workId, reason) end
  end

  if not world.entityExists(containerId) then
    empty("container no longer exists")
    return
  end

  local took = world.containerConsume(containerId,
    { name = seedName, count = count })

  if took ~= true then
    empty("containerConsume returned " .. tostring(took)
      .. " -- crate emptied between dispatch and arrival?")
    return
  end

  sb.logInfo("PETPORT %s withdrew %s %s from %s",
    stationUniqueId(), sb.printJson(count), tostring(seedName),
    sb.printJson(containerId))

  receiveCargo({ name = seedName, count = count })
end

--  Remove one seed from cargo after it has gone into the ground.
--
--  Global, same reason as above.
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

  --  The unit planted something it was not carrying. Worth a shout: it means
  --  cargo accounting and the world disagree.
  sb.logError("PETPORT %s planted %s but was not carrying it",
    stationUniqueId(), tostring(seedName))
end

--  Move cargo into a container. Called when the unit reports it is standing
--  there.
--
--  PARTIAL DEPOSITS ARE NOT SPECIAL-CASED. Whatever the container refuses stays
--  on the unit, the container goes into backoff, and the next dispatch picks a
--  different beacon. That is the same behaviour as a chest being full outright,
--  which means there is one path to test rather than two.
--  GLOBAL, like receiveCargo above it and for the same reason: the
--  petports_taskReport handler is registered in init(), which is earlier in the
--  file than this definition, so a local would not be in scope at the call site.
function depositCargo(containerId)
  if self.petData == nil or self.petData.cargo == nil then return end

  if not world.entityExists(containerId) then
    sb.logInfo("PETPORT %s deposit failed: container %s no longer exists",
      stationUniqueId(), sb.printJson(containerId))
    return
  end

  local before = #self.petData.cargo
  local remaining = {}

  for _, stack in ipairs(self.petData.cargo) do
    --  containerAddItems returns WHAT IT COULD NOT TAKE, or nil when it took
    --  everything. A partial take comes back as the same descriptor with a
    --  smaller count, so this is also how a half-filled stack is accounted.
    local leftover = world.containerAddItems(containerId, stack)

    if leftover ~= nil and (leftover.count or 0) > 0 then
      table.insert(remaining, leftover)
      sb.logInfo("PETPORT %s deposited %s of %s %s into %s",
        stationUniqueId(),
        sb.printJson((stack.count or 1) - leftover.count),
        sb.printJson(stack.count or 1), tostring(stack.name),
        sb.printJson(containerId))
    else
      sb.logInfo("PETPORT %s deposited %s %s into %s",
        stationUniqueId(), sb.printJson(stack.count or 1), tostring(stack.name),
        sb.printJson(containerId))
    end
  end

  self.petData.cargo = remaining

  if #remaining > 0 then
    --  A LEFTOVER IS ABOUT A DESCRIPTOR, NOT ABOUT THE CRATE. The next dispatch
    --  asks containerTakesAny with whatever is still held, so a crate that can
    --  still merge part of the load stays eligible and only a crate that can
    --  take NOTHING is passed over -- no timer needed, and no waiting out 60
    --  seconds for a crate that was never actually unusable.
    --
    --  The timed backoff is kept ONLY for the case where the engine cannot be
    --  asked, so that path still makes progress instead of retrying the same
    --  full crate forever.
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

  --  Cargo changed, and the world drop for it is long gone. Same reasoning as
  --  the pickup side: write it through now.
  flushCargo()
end

--------------------------------------------------------------------------------
--  FARMABLES
--------------------------------------------------------------------------------

--  Is this work item free for this port to take?
--
--  MOVED ABOVE ITS FIRST CALLER. It is used by waterWork, replantWork and
--  withdrawWork, and it originally sat below the first of those -- which is the
--  nil-global trap this file has already been bricked by once: a local called
--  from a line above its definition compiles as a lookup of a global nobody
--  assigns, with no syntax error and no warning until it runs.
--
--  It matters twice over in withdrawWork, which needs it for its own leg AND
--  for the replant that follows; getting that wrong livelocks the queue.
local function claimFree(workId)
	local claim = petports_claimGet(workId)

	return (claim == nil)
		or claim.owner == stationUniqueId()
		or (claim.expires or 0) <= world.time()
end

--------------------------------------------------------------------------------
--  SOIL
--------------------------------------------------------------------------------

--  What a surface mod is and what it wants, cached by name.
--
--  THE MATMOD IS SELF-DESCRIBING, which removes a whole layer that was planned
--  and is not needed. farming.config's wetToDryMods describes the DRYING
--  direction and never has to be read: a mod that carries "tilled" : true is
--  farmland, and one that also carries a liquidInteraction with a
--  transformModId is farmland that is currently DRY and says what would fix it.
--
--    tilleddry   "tilled" : true
--                liquidInteractions -> liquidId 1 or 6, transformModId 31
--    tilled      "tilled" : true, no liquidInteractions
--
--  So no name comparisons and no hardcoded pairs -- this is true for modded
--  soils for free, which is most of what Alta/Enternia compatibility would
--  otherwise have cost.
local soilCache = {}

--  transformModId is a NUMBER; applySurfaceMod wants a NAME.
--
--  The matmod says "liquid 1 turns me into mod 31" and vanilla's droplet says
--  "previousMod tilleddry, newMod tilled". Passing 31 where a name is expected
--  would spawn a droplet that falls and does nothing -- the same silent failure
--  as the parameter override not landing, and indistinguishable from it in a
--  log, so it is worth closing rather than discovering.
--
--  farming.config's wetToDryMods is the wet -> dry pairing, so INVERTED it maps
--  a dry mod name to its wet one, which is exactly the name needed. That is the
--  one thing that file is good for; everything else about dryness comes off the
--  matmod itself.
--
--  THERE IS NO root.modName. The mod API goes one way only -- root.modConfig
--  takes a NAME and yields a config -- so a numeric id cannot be turned into a
--  name directly, and the inverse map is the only route.
--
--  It can be CHECKED, though, and cheaply: the resolved config carries modId,
--  so confirming it equals the transformModId we were aiming at turns a guess
--  into a verified lookup. A modded soil whose author patched wetToDryMods
--  correctly passes; one that did not is refused rather than watered with a
--  droplet naming a mod that does not exist.
local wetNameCache = nil

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

	--  Confirm the name actually names the mod the soil asked for.
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
				--  itemDrop CLOSES THE LOOP FROM THE OTHER END. The matmod names
				--  liquids by numeric id and a liquid item names its liquid by
				--  string, so matching items against the mod directly would need
				--  a bridge. The liquid's own config carries the item that
				--  yields it, so we go mod -> liquid -> item and never match
				--  anything.
				local okLiquid, liquid = pcall(root.liquidConfig, interaction.liquidId)
				local item = nil
				local tint = nil

				if okLiquid and type(liquid) == "table" and type(liquid.config) == "table" then
					item = liquid.config.itemDrop

					--  THE DROPLET WEARS THE LIQUID'S OWN COLOUR. The sprite is
					--  transparent white, so a multiply directive paints it --
					--  and every liquid config already carries the colour the
					--  engine renders it with, so nothing has to be authored per
					--  liquid. Water is blue, lava is not, and swamp water looks
					--  like swamp water without a table anywhere in this mod.
					--
					--  ALPHA IS FORCED OPAQUE. A liquid's alpha describes how a
					--  BODY of it renders -- water is 128, half transparent,
					--  which is right for a lake and nearly invisible on a
					--  three-pixel droplet.
					local colour = liquid.config.color

					if type(colour) == "table" and #colour >= 3 then
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

--  Is this tile dry farmland, and what would fix it?
local function drySoilAt(tile)
	local modName = world.mod({ tile[1], tile[2] }, "foreground")
	if modName == nil then return nil end

	local info = soilInfo(modName)
	if info == nil or not info.tilled or not info.dry then return nil end

	return { mod = tostring(modName), wants = info.wants }
end

--  A farmable's stages array.
--
--  world.getObjectParameter reads the object's own config, which is where
--  "stages" lives, and works whether or not the object has an item form.
--  root.itemConfig is kept as a fallback because HarvesterBeam reaches
--  farmables that way and it is the better-travelled path -- but it is gated on
--  hasObjectItem there for a reason, so it cannot be the primary.
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

--  Which stage number means "ready to pick".
--
--  THE HARVEST STAGE IS THE ONE CARRYING harvestPool, never a fixed index.
--  Potato has three stages and corn has four, so anything of the form
--  "is this stage 2" is wrong for half the crops in the game.
local function harvestStageOf(stages)
	for index, stage in ipairs(stages) do
		if type(stage) == "table" and stage.harvestPool ~= nil then
			--  Lua lists count from 1; the engine is assumed to count from
			--  FARMABLE_STAGE_BASE. See that constant.
			return index - 1 + FARMABLE_STAGE_BASE
		end
	end

	return nil
end

--  Every farmable in network coverage, with its ripeness already decided.
local function scanFarmables()
	local rects = self.networkRects
	if rects == nil or #rects == 0 then rects = { coverageRect() } end

	local found = {}
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

				--  world.farmableStage DOES DOUBLE DUTY: it returns nil for
				--  anything that is not a farmable, so this single call is both
				--  the type test and the ripeness read. No objectType check
				--  needed alongside it.
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
				end
			end
		end
	end

	return found, objects
end

--  THIS LOG IS THE INSTRUMENT THAT SETTLES FARMABLE_STAGE_BASE. Every crop
--  reports its stage against its stage count and against the index this port
--  believes is the harvest stage, so a fully grown crop on screen that reads
--  "stage 3 of 3 harvestAt 2" says the base is wrong and by how much.
--
--  Change-gated on the signature rather than the count, like the beacon scan:
--  crops growing IS the interesting event, and it does not move the count.
local function refreshFarmables(dt)
	self.harvestTimer = (self.harvestTimer or 0) - dt
	if self.harvestTimer > 0 then return end
	self.harvestTimer = HARVEST_INTERVAL

	local found, objects = scanFarmables()
	self.farmables = found

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
end

--------------------------------------------------------------------------------
--  FARM ANIMALS
--------------------------------------------------------------------------------
--
--  Mooshi, Fluffalo and anything else running the "farmable" behavior.
--
--  MUCH SIMPLER THAN CROPS, and for one reason: animals are SCRIPTED monsters,
--  where farmable objects have no script at all. /scripts/actions/monsters/
--  farmable.lua defines hasMonsterHarvest and dropMonsterHarvest as plain
--  globals in the monster's environment, and NEITHER USES ITS args OR board
--  parameters -- they are declared (args, board) and ignore both. So they are
--  callable out of band with no arguments.
--
--  world.callScriptedEntity(id, "hasMonsterHarvest") is therefore a near-exact
--  mirror of world.farmableStage:
--
--      nil    not a farmable animal at all (no such global)
--      false  farmable, not ready yet
--      true   ready to harvest
--
--  The documented trap that callScriptedEntity returns nil SILENTLY for a
--  missing function is what makes that work. Here it is the feature rather
--  than the hazard: one call is both the type test and the readiness test.
--  Can this monster TYPE be harvested, per its own config?
--
--  root.monsterParameters reads the type, so this costs nothing on the entity
--  and cannot make anything throw. BOTH fields are required: harvestTime is
--  what hasMonsterHarvest compares against -- its absence is exactly what
--  killed babies -- and harvestPool is what dropMonsterHarvest spawns from.
--
--  Checked at two levels because the binding's shape is unconfirmed: mooshi
--  carries these under baseParameters in its .monstertype, and whether
--  monsterParameters returns that table flattened or nested is not documented.
--  Looking in both costs one index.
local animalTypeCache = {}

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

				--  ASKED ABOUT THE TYPE, NOT THE ANIMAL. Nothing runs inside
				--  the entity here, which is the whole point.
				--
				--  This replaces a probe that CALLED hasMonsterHarvest on every
				--  monster in coverage to find out what it was. That worked on
				--  adults and KILLED BABIES: baby livestock runs the same
				--  farmable behavior, so the function exists, but babies have no
				--  "harvestTime" in config -- resetMonsterHarvest stores nil and
				--  farmable.lua:34 compares nil with a number. Our pcall caught
				--  it on our side; the error had already happened inside the
				--  MONSTER's script, and a script error kills the monster. The
				--  scan was culling baby Fluffalo once every five seconds.
				--
				--  root.monsterParameters answers from the type's config, so a
				--  baby is filtered before anything is invoked on it. Our own
				--  units fall out here too, having neither field.
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

--  Send a unit at a ready animal.
--
--  READINESS IS RE-READ AT SELECTION, exactly as crop ripeness is, and for the
--  same reason: the scan is up to HARVEST_INTERVAL old and the most likely way
--  for it to be wrong is the case this task creates itself -- an animal
--  harvested a second ago is still READY in the cache for another five seconds.
--  Dispatching against that would send a unit to poke an animal with nothing to
--  give and land it on the failure backoff ladder for a fault that was ours.
--
--  ANIMALS MOVE, and nothing here chases them. The dispatch position is where
--  the animal stood at selection; the unit re-reads the live position while
--  approaching, but the standable ground target is resolved once. A Mooshi
--  ambles slowly enough that this does not matter. Smaller roving livestock may
--  outwalk it, which will present as an arrival that is out of reach -- logged
--  with the distance, deliberately, so the decision to add catch-up behaviour
--  can be made from a measurement rather than a guess.
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
	local rejected = { notReady = 0, claimed = 0, backedOff = 0, gone = 0 }

	for _, animal in ipairs(animals) do
		local workId = "animal:" .. animal.id
		local failure = self.workFailures[workId]
		local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

		if not world.entityExists(animal.id) then
			rejected.gone = rejected.gone + 1
		elseif not animalHarvestable(animal.name) then
			--  Cheap and cached, and it keeps a stale self.animals entry from
			--  reaching a call it should not.
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
				--  Live position, not the scanned one. The animal has had up to
				--  five seconds to wander since.
				local position = world.entityPosition(animal.id)
				local distance = world.magnitude(from, position)

				if bestDistance == nil or distance < bestDistance then
					best = { id = animal.id, name = animal.name, position = position }
					bestDistance = distance
				end
			end
		end
	end

	if best == nil then
		local reason = string.format(
			"%s farm animal(s), none harvestable: %s not ready, %s claimed, "
			.. "%s backed off, %s gone",
			#animals, rejected.notReady, rejected.claimed,
			rejected.backedOff, rejected.gone)

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

--  Pick a ripe crop to send the unit at.
--
--  NO DEFERRAL HERE, unlike collection, and that is deliberate rather than an
--  omission. Deferral exists because two ports racing for one DROP waste a walk
--  on something that may despawn before either arrives. A crop does not
--  despawn, does not move, and will still be there on the next tick -- so the
--  claim is sufficient arbitration and the loser simply picks a different crop.
--  The handoff already argues for deleting deferral outright; there is no
--  reason to grow a second copy of it here first.
local function harvestWork()
	local crops = self.farmables

	if crops == nil or #crops == 0 then
		return nil, "no farmables in network coverage"
	end

	--  Distance is measured from the UNIT, since it is the unit that walks.
	local from = entity.position()
	if self.petId ~= nil and world.entityExists(self.petId) then
		from = world.entityPosition(self.petId)
	end

	local best, bestDistance = nil, nil
	local rejected = { unripe = 0, claimed = 0, backedOff = 0, gone = 0 }

	for _, crop in ipairs(crops) do
		local workId = "harvest:" .. crop.id
		local claim = petports_claimGet(workId)
		local failure = self.workFailures[workId]
		local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

		local free = not backedOff and ((claim == nil)
			or claim.owner == stationUniqueId()
			or (claim.expires or 0) <= world.time())

		--  RIPENESS IS RE-READ HERE, NOT TAKEN FROM THE SCAN.
		--
		--  The scan is up to HARVEST_INTERVAL old, and the single most likely
		--  way for it to be wrong is the case this task creates itself: a crop
		--  with resetToStage is ripe when scanned, harvested a second later,
		--  and immediately unripe -- while the cache still says RIPE for
		--  another five seconds. The port would dispatch a unit to swing at it
		--  for nothing, the swing would fall through to ordinary object damage,
		--  and the crop would land on the failure backoff ladder for a fault
		--  that was entirely ours.
		--
		--  Cheap: one call per FARMABLE, not per object. The expensive part of
		--  the scan is the entityQuery and the config read, and both stay on
		--  the slow timer.
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
			--  Harvested by the player, or by another network's unit, between
			--  the scan and now.
			rejected.gone = rejected.gone + 1
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
			.. "%s claimed, %s backed off, %s gone",
			#crops, rejected.unripe, rejected.claimed,
			rejected.backedOff, rejected.gone)

		--  LOGGED HERE, NOT RETURNED AND HOPED FOR. findWork returns the
		--  deposit reason ahead of this one, so a port sitting next to nine
		--  ripe crops and refusing to dispatch said nothing whatsoever about
		--  the crops -- the reason existed and never reached the log. Change
		--  gated so it does not repeat every tick.
		if reason ~= self.harvestRejectReason then
			self.harvestRejectReason = reason
			sb.logInfo("PETPORT %s harvest: %s", stationUniqueId(), reason)
		end

		return nil, reason
	end

	self.harvestRejectReason = nil

	return {
		id = "harvest:" .. best.id,
		type = "harvest",
		port = stationUniqueId(),
		target = best.id,
		--  CARRIED SO THE INTENT CAN BE WRITTEN AFTER THE CROP IS GONE. Once
		--  the harvest succeeds the entity no longer exists, so entityName is
		--  no longer answerable -- and the crop's own name IS the seed name,
		--  which is the whole thing the intent needs to record.
		targetName = best.name,
		position = best.position
	}
end

--  A contiguous run of dry farmland, ordered, starting from a crop.
--
--  ORDER IS THE POINT. Watering tile-by-tile as separate work items would send
--  a unit across a forty-tile row in whatever order discovery happened to
--  produce, which looks like malfunctioning rather than gardening. The run is
--  built as an ordered list and swept end to end.
--  Is this position inside coverage for ANY port on the network?
--
--  Network-wide rather than this port's own rect: one port harvests, another
--  may be nearer the crate, and a run may span two members. Falls back to the
--  own rect before the network has been derived, which is the same fallback
--  the farmable scan makes.
--
--  Defined here rather than beside its first user because it now has several,
--  the earliest being the watering run builder -- and a local called from above
--  its definition compiles as a nil global, which has bricked this file once.
local function inNetworkCoverage(position)
	local rects = self.networkRects
	if rects == nil or #rects == 0 then rects = { coverageRect() } end

	for _, rect in ipairs(rects) do
		if petports_rectContains(rect, position) then return true end
	end

	return false
end

local function waterRunFrom(anchor)
	--  THE CROP MAKES THE ROW ELIGIBLE. IT DOES NOT HAVE TO BE THIRSTY ITSELF.
	--
	--  This used to require the tile UNDER the crop to be dry, and return
	--  nothing otherwise -- so a crop standing on already-wet soil aborted
	--  before the expansion ran, and freshly tilled dry ground right beside it
	--  was never seen. Break and re-till a patch next to a watered crop and
	--  nothing would ever water it.
	--
	--  Traversal now runs through FARMLAND and collects the DRY tiles out of
	--  it. A wet tile mid-row is passed over rather than treated as the end of
	--  the row, which is the common case once a fleet has been working: rows
	--  become patchy, not cleanly split.
	local function farmlandAt(tile)
		--  COVERAGE BOUNDS THE RUN, not just the crop that anchored it.
		--
		--  scanFarmables only finds crops inside the network, so a farm that
		--  falls out of coverage stops producing work -- but the left/right
		--  expansion had no such limit and would happily walk up to
		--  WATER_RUN_REACH tiles past the edge. A crop just inside a rect could
		--  send a unit thirty tiles outside the network to water soil no port
		--  is responsible for.
		--
		--  Break rather than skip: a run is contiguous by definition, and
		--  stepping over a gap would produce a "run" the sweep walks across in
		--  a straight line through territory it was never given.
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

	--  ONE SOIL TYPE PER RUN. previousMod is a single value on the task and is
	--  used for every cast in the sweep, so a run spanning two kinds of dry
	--  soil would aim the wrong transition at half of it. Take the first dry
	--  tile's soil and keep only tiles matching it; anything else becomes its
	--  own run on a later pass.
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

--  Every dry run worth watering in this network's coverage.
--
--  ANCHORED ON CROPS, not on bare soil. A player with a large fallow field has
--  not asked for it to be watered, and scanning every tile in coverage for dry
--  farmland would generate work nobody wanted. A crop standing on dry ground is
--  an unambiguous request -- it cannot grow until the soil is wet -- and the
--  run expansion then finishes the row it is part of.
local function waterRuns()
	local runs = {}
	local seen = {}

	for _, crop in ipairs(self.farmables or {}) do
		if world.entityExists(crop.id) then
			local position = world.entityPosition(crop.id)

			--  The soil is BELOW the crop's anchor: a crop stands on tilled
			--  dirt rather than in it.
			local tile = { math.floor(position[1]), math.floor(position[2]) - 1 }
			local key = petports_tileKey(tile)

			if not seen[key] then
				local run = waterRunFrom(tile)

				if run ~= nil then
					--  Mark the whole run seen, so the next crop standing in it
					--  does not produce an overlapping duplicate. The ANCHOR is
					--  marked separately because it is no longer necessarily in
					--  the run -- a crop on already-wet soil contributes the row
					--  without being part of the work.
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

--  Is the unit carrying something that would wet this run?
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

--  Sweep a dry run, one tile per unit of liquid carried.
--
--  ABOVE DEPOSIT, for the same reason replant is: a unit holding water that
--  matches outstanding dry soil is mid-job, and deposit fires on any cargo.
local function waterWork()
	local runs = waterRuns()
	if #runs == 0 then return nil, "no dry soil under any crop in coverage" end

	for _, run in ipairs(runs) do
		local workId = "water:" .. tostring(run.key)
		local failure = self.workFailures[workId]
		local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

		local stack, want = carriedWaterFor(run)

		if stack ~= nil and not backedOff and claimFree(workId) then
			--  Carry decides length. One item per tile, and the unit stops when
			--  it runs out rather than pretending.
			local carried = math.min(stack.count or 1, WATER_CARRY)
			local tiles = {}

			for index = 1, math.min(carried, #run.tiles) do
				table.insert(tiles, run.tiles[index])
			end

			--  START FROM THE NEARER END and sweep away from it. Walking to the
			--  far end first doubles the trip for no reason, and reversing
			--  mid-row is the spazzing this whole structure exists to avoid.
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

			sb.logInfo("PETPORT %s WATER dispatch: %s tile(s) of %s in run, "
				.. "%s carried, from %s to %s",
				stationUniqueId(), sb.printJson(#tiles), sb.printJson(#run.tiles),
				sb.printJson(stack.count or 1), sb.printJson(tiles[1]),
				sb.printJson(tiles[#tiles]))

			return {
				id = workId,
				type = "water",
				port = stationUniqueId(),
				tiles = tiles,
				waterIndex = 1,
				item = want.item,
				previousMod = run.mod,
				newMod = want.newMod,
				tint = want.tint,
				position = { tiles[1][1] + 0.5, tiles[1][2] + 1.5 }
			}
		end
	end

	return nil, string.format("%s dry run(s), none actionable", #runs)
end

--------------------------------------------------------------------------------
--  REPLANTING
--------------------------------------------------------------------------------

--  Is this tile still a place a crop could go?
--
--  TWO TILES, NOT ONE. A farmable occupies spaces [0,0] and [0,1] anchored at
--  the bottom, so a check against the anchor alone will happily try to plant
--  into something hanging one tile above the ground.
--  A crop's real footprint, from its own config.
--
--  WAS HARDCODED 1 WIDE BY 2 TALL, generalised from potatoseed's
--  spaces [[0,0],[0,1]]. Wrong for every wide crop -- oculemon and pineapple
--  are two wide -- and the failure was quiet in both directions: the clear
--  check missed a blocker standing in the column it never looked at, and the
--  post-plant check looked for the new crop in tiles it might not occupy and
--  concluded the planting had failed.
--
--  The seed and the crop share one name, so the seed's own config describes
--  exactly what is about to appear. Cached per name: object configs are
--  static, and this is read on every occupancy test.
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
		--  Loud, because falling back means occupancy is a guess from here on.
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

--  The tiles a crop of this type would occupy if planted at this anchor.
local function seedTiles(position, seedName)
	local anchor = { math.floor(position[1]), math.floor(position[2]) }
	local tiles = {}

	for _, space in ipairs(seedSpaces(seedName)) do
		table.insert(tiles, { anchor[1] + space[1], anchor[2] + space[2] })
	end

	return tiles
end

--  Does this object actually stand on any of these tiles?
--
--  world.objectSpaces returns the object's occupied tiles RELATIVE to its own
--  position -- the same thing vanilla's pathutil objectBounds translates -- so
--  this is an exact occupancy test rather than a bounding-box overlap.
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

local function replantFootprintClear(position, seedName)
	local tiles = seedTiles(position, seedName)

	--  Query bounds from the real footprint, padded, since the exact test
	--  below does the actual work.
	local lox, loy = tiles[1][1], tiles[1][2]
	local hix, hiy = lox, loy

	for _, t in ipairs(tiles) do
		lox = math.min(lox, t[1]); hix = math.max(hix, t[1])
		loy = math.min(loy, t[2]); hiy = math.max(hiy, t[2])
	end

	--  QUERY WIDE, THEN FILTER EXACTLY, and the filter is the whole point.
	--
	--  entityQuery returns anything whose bounds INTERSECT the rect, and a rect
	--  drawn tightly around one tile touches the edge of the next one. In a
	--  planted row -- crops at x, x+1, x+2 -- every tile therefore reported
	--  itself occupied by its neighbour, and every replant intent was cleared
	--  as "footprint occupied" within seconds of being written. MEASURED: nine
	--  intents set, seven destroyed this way, and the two survivors only lasted
	--  because their neighbours had not regrown yet.
	--
	--  Padding the query and then testing real occupancy is immune to that,
	--  and costs one objectSpaces call per candidate.
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

--  Is the ground under the tile still tilled?
--
--  THE SOIL IS BELOW THE ANCHOR. A crop stands ON tilled dirt, so the matmod to
--  test is at y - 1, not at the crop's own tile. Both are logged on failure
--  because that offset is an assumption about where world.entityPosition sits
--  for an object, and one look at a real field settles it.
--
--  Mods are NAMED at this layer, not numbered: world.placeMod takes "tilled",
--  and vanilla's own removable-mod tables compare against "tilleddry". So the
--  31/32 ids in the material config are not what shows up here.
local function replantGroundTilled(position)
	local under = world.mod({ position[1], position[2] - 1 }, "foreground")
	local at = world.mod({ position[1], position[2] }, "foreground")

	--  ASK THE MATMOD, DO NOT COMPARE ITS NAME.
	--
	--  This used to test the name against "tilled" and "tilleddry" literally,
	--  which is correct for vanilla and wrong for every modded soil -- and mods
	--  like Alta/Enternia ship a lot of them. Both vanilla matmods carry
	--  "tilled" : true, and soilInfo already reads and caches that, so the
	--  question "is this farmland" is answerable without knowing any names.
	--
	--  Modded soil support for replanting therefore costs nothing beyond this
	--  line, the same way watering got it for free by reading liquidInteractions
	--  rather than hardcoding a wet/dry pair.
	local info = soilInfo(under)
	local tilled = info ~= nil and info.tilled

	--  THE SOIL IS AT y - 1 AND ONLY THERE, now that it is verified.
	--
	--  This used to accept a tilled mod at EITHER tile, hedging an unverified
	--  assumption about where world.entityPosition sits for an object -- getting
	--  it wrong would have cleared every replant intent within five seconds as
	--  "ground no longer tilled", with nothing obviously broken. Watering settled
	--  it: waterRuns derives the soil tile the same way, from
	--  floor(cropPosition) - 1, and it wets exactly the right tiles. The hedge
	--  can go, and dropping it means a crop whose anchor tile happens to be
	--  farmland no longer masks missing soil beneath it.

	if not tilled then
		sb.logInfo("PETPORT %s replant ground at %s: mod below is %s (tilled %s), "
			.. "mod at is %s -- not farmland",
			stationUniqueId(), sb.printJson(position), tostring(under),
			tostring(info ~= nil and info.tilled), tostring(at))
	end

	return tilled
end

--  Drop intents the world has already answered.
--
--  RUNS ON THE FARMABLE TIMER, not the work tick. Sweeping is cheap but it is
--  still an entityQuery per intent, and intents are long-lived by design.
--  OWN TIMER, AND CALLED FROM workUpdate, NOT FROM refreshFarmables.
--
--  This used to be a call at the bottom of refreshFarmables, which crashed
--  every port on the first sweep: refreshFarmables is defined EARLIER in this
--  file, so the `local function` below was not in scope at that call site and
--  Lua compiled it as a lookup of a GLOBAL named sweepReplants, which is nil.
--  Same trap the receiveCargo and writeBackToItem comments describe, reached
--  from the other direction.
--
--  Calling it from workUpdate -- which is defined after everything -- removes
--  the ordering dependency entirely rather than papering over it with a
--  forward declaration.
local REPLANT_SWEEP_INTERVAL = 5.0

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

	for key, intent in pairs(intents) do
		if intent.position ~= nil
		   and inNetworkCoverage(intent.position) then
			--  A SUCCESSFUL REPLANT CLEARS ITS OWN INTENT BY EXISTING, because
			--  a farmable is an object and lands in this same test. One check
			--  covers "we did it" and "the player put a crate there".
			if not replantFootprintClear(intent.position, intent.name) then
				petports_replantClear(key, "footprint occupied")
			elseif not replantGroundTilled(intent.position) then
				petports_replantClear(key, "ground no longer tilled")
			end
		end
	end
end

--  Does any networked container hold this seed?
local function containerWithSeed(seedName)
	--  SEEDS COME OUT OF THE SAME CRATES THEY WENT INTO. Deposit beacons are
	--  the network's storage as far as this mod is concerned, and reusing that
	--  list means a player who moves their storage does not also have to tell
	--  the replanting system about it.
	--
	--  containerAvailable answers "how many could be consumed", which is a
	--  stronger test than reading containerItems and matching names -- it is
	--  the same question containerConsume will ask when the unit arrives.
	for _, beacon in ipairs(petports_beaconsFor("deposit")) do
		if world.entityExists(beacon.id) then
			local available = world.containerAvailable(beacon.id,
				{ name = seedName, count = 1 })

			if type(available) == "number" and available >= 1 then
				return beacon.id
			end
		end
	end

	return nil
end

--  Is the unit already carrying the seed an outstanding intent wants?
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

	--  NO MATCH, WITH BOTH SIDES NON-EMPTY -- the interesting failure, and the
	--  one that produced a withdraw/deposit loop with nothing in the log that
	--  looked wrong. Names both sides so a mismatch is readable at a glance
	--  rather than inferred from what did not happen.
	--
	--  Change-gated: this is reached on every work tick a unit is carrying
	--  something, which is most of them.
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

--  Walk the seed we are already holding to the hole it came out of.
--
--  THIS OUTRANKS DEPOSIT, and that ordering is the whole reason this task can
--  exist. Deposit fires on ANY cargo, so a unit holding a seed would otherwise
--  carry it straight past the tile it belongs in and back to a crate.
--
--  The rule is narrow on purpose: replant wins ONLY when the cargo is the seed
--  an outstanding intent names. A unit holding a potato still deposits. That
--  also makes the whole thing self-healing -- if an intent is invalidated while
--  a unit is carrying its seed, the match stops holding, deposit takes over,
--  and the seed goes to storage like any other item.
local function replantWork()
	local key, intent = carriedSeedIntent()
	if key == nil then return nil, "no carried seed matches an intent" end

	--  BACKOFF IS LOAD-BEARING HERE, not a nicety. Nothing about a failed
	--  replant changes on its own: the unit is still holding the seed, the
	--  intent still exists, and the match still holds -- so without this the
	--  port re-dispatches the identical task on the very next tick and the unit
	--  retries a refused placeObject several times a second, forever. Every
	--  other work type gets away with omitting this because its precondition is
	--  consumed by the attempt.
	local failure = self.workFailures["replant:" .. key]
	if failure ~= nil and (failure["until"] or 0) > world.time() then
		return nil, string.format("replant at %s backed off until %s",
			tostring(key), sb.printJson(failure["until"]))
	end

	if not replantFootprintClear(intent.position, intent.name) then
		petports_replantClear(key, "footprint occupied at dispatch")
		return nil, "intent tile is occupied"
	end

	sb.logInfo("PETPORT %s REPLANT dispatch: %s back into %s (tile %s)",
		stationUniqueId(), tostring(intent.name), tostring(key),
		sb.printJson(intent.position))

	return {
		id = "replant:" .. key,
		type = "replant",
		port = stationUniqueId(),
		target = key,
		seed = intent.name,
		--  Placement wants the tile; standing wants ground near it. The unit
		--  resolves the second from the first, the same way collection does.
		position = { intent.position[1] + 0.5, intent.position[2] + 0.5 },
		tile = intent.position
	}
end

--  Fetch a seed from storage for an outstanding intent.
--
--  LAST IN THE ORDER, BELOW HARVEST, and that is a real decision rather than an
--  accident: this is the only task that MANUFACTURES cargo rather than clearing
--  something. Drops despawn and crops occupy space; an empty tile does neither,
--  so replanting is the chore a network does in its downtime. The visible
--  consequence is that a busy base replants slowly, which is correct.
--
--  SEED GOES TO STORAGE FIRST, BY DESIGN. The harvest drops its seed on the
--  ground, ordinary collection carries it to a crate, and only then does this
--  fetch it back out. The round trip is the point: every seed is accounted for
--  in storage, so a player who wants them for food or crafting can take them
--  before the network spends them on replanting.
--  Fetch liquid for a dry run.
--
--  ONE TRIP, MANY TILES. The economy is one item per tile; the LOGISTICS are
--  one walk per run. Those are separate decisions and conflating them is how a
--  forty-tile row turns into forty round trips.
local function withdrawWaterWork()
	local runs = waterRuns()
	if #runs == 0 then return nil, "no dry soil needing water" end

	for _, run in ipairs(runs) do
		--  Already carrying the right thing? Then this is waterWork's problem,
		--  not ours.
		if carriedWaterFor(run) == nil then
			local workId = "fetchwater:" .. tostring(run.key)
			local failure = self.workFailures[workId]
			local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

			if not backedOff and claimFree(workId)
			   and claimFree("water:" .. tostring(run.key)) then
				local wanted = math.min(#run.tiles, WATER_CARRY)

				for _, want in ipairs(run.wants) do
					for _, beacon in ipairs(petports_beaconsFor("deposit")) do
						if world.entityExists(beacon.id) then
							local available = world.containerAvailable(beacon.id,
								{ name = want.item, count = 1 })

							if type(available) == "number" and available >= 1 then
								local take = math.min(wanted, available)

								sb.logInfo("PETPORT %s FETCHWATER dispatch: %s x%s "
									.. "from %s for a %s tile run",
									stationUniqueId(), tostring(want.item),
									sb.printJson(take), sb.printJson(beacon.id),
									sb.printJson(#run.tiles))

								return {
									id = workId,
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

local function withdrawWork()
	--  CARRYING SOMETHING IS NOT A REASON NOT TO FETCH A SEED.
	--
	--  This used to refuse on any cargo at all, which deadlocked the exact
	--  situation it most needed to survive: storage full, unit holding a stack
	--  nothing will accept. Deposit cannot place it, so the unit carries it
	--  forever -- and a blanket cargo refusal here meant replanting stopped too,
	--  even with seeds sitting in a crate and bare tilled ground waiting.
	--  Nothing about a full crate should stop a seed going into the ground.
	--
	--  What IS still refused is fetching a second seed while already holding one
	--  an intent wants, since that seed is about to be planted and a unit
	--  hoarding seeds helps nobody.
	if carriedSeedIntent() ~= nil then
		return nil, "unit is already carrying a seed for an intent"
	end

	local intents = petports_replantsAll()
	local wanted = 0

	for key, intent in pairs(intents) do
		if intent.name ~= nil and intent.position ~= nil
		   and inNetworkCoverage(intent.position) then
			wanted = wanted + 1

			local workId = "withdraw:" .. key
			local failure = self.workFailures[workId]
			local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

			--  BOTH LEGS ARE CHECKED, and the first one is the fix for a
			--  livelock rather than belt-and-braces.
			--
			--  dispatchWork does take a claim on this work id, so two ports
			--  cannot both FETCH for one intent -- but the refusal happens at
			--  DISPATCH, after selection has already committed to this intent.
			--  A second port would propose the same withdraw, be rejected,
			--  return no work, and propose it again next tick, forever, never
			--  reaching the other intents in the list. Checking here means it
			--  skips to the next one instead.
			--
			--  The replant leg is checked because the two legs have different
			--  work ids and therefore different claims. Without it, a port
			--  would happily fetch a second seed for a tile another unit is
			--  already walking one to.
			local free = not backedOff
				and claimFree(workId)
				and claimFree("replant:" .. key)

			if free then
				local containerId = containerWithSeed(intent.name)

				if containerId ~= nil then
					return {
						id = "withdraw:" .. key,
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

	--  NEVER BLOCKS. An intent with no seed in storage simply waits, the same
	--  way a dry unit is routed around rather than stalling the port. A player
	--  who stops stocking a seed gets a bare tile, not a stuck network.
	return nil, string.format(
		"%s replant intent(s), none actionable (no seed in storage, or claimed)",
		wanted)
end

local function findWork()
  --  Before anything else: a unit that has strayed cannot reach work anyway.
  local recall = returnWork()
  if recall ~= nil then return recall end

  --  CARGO OUTRANKS COLLECTION. A unit holding a load has exactly one job, and
  --  letting it pick up more first is how a unit ends up hoarding instead of
  --  ferrying. Below the recall ladder, though -- a stranded unit cannot reach
  --  a chest either.
  --  REPLANT SITS ABOVE DEPOSIT and below recall. See replantWork: a unit
  --  holding the seed an intent names is two tiles from finishing a job, and
  --  deposit would send it back to a crate instead.
  --
  --  THIS ORDERING IS THE WHOLE FEATURE. It was written below depositWork by
  --  mistake and the loop that produced was exact and undramatic: withdraw a
  --  seed, deposit it, withdraw it again, roughly three times a second, with
  --  nothing in the log looking like an error because every individual task
  --  succeeded.
  local putBack, noPutBack = replantWork()
  if putBack ~= nil then return putBack end

  --  WATER SITS WITH REPLANT, ABOVE DEPOSIT, and for exactly the same reason:
  --  a unit carrying liquid that matches dry soil is mid-job, and deposit fires
  --  on ANY cargo.
  local wet, noWet = waterWork()
  if wet ~= nil then return wet end

  local drop, noDrop = depositWork()
  if drop ~= nil then return drop end

	--  ORDERING IS NOT A GUARD.
	--
	--  Everything above claims cargo outranks collection, and it does -- but only
	--  while depositWork RETURNS something. With no beacon in coverage it returns
	--  nil and a reason, and collection below ran unguarded: a unit picked up a
	--  stack, then a second stack of the same item, then an unrelated third, and
	--  kept going. Precedence cannot order an option that does not exist.
	--
	--  ANY CARGO IS A FULL LOAD. One stack per trip is the design -- more
	--  throughput means more units, which is the point of the scaling loop. So
	--  this is not "stop when full", it is "stop when holding anything".
	--
	--  The FIRST pickup with no crate anywhere is still allowed, and that is
	--  deliberate rather than an exemption: cargo is empty at that moment, so the
	--  guard does not fire. A drop is on a despawn timer and a unit is not, so
	--  rescuing one is strictly better than watching it evaporate.
	--
	--  THIS IS ALSO THE ORPHAN CONDITION. A unit holding cargo that deposit
	--  cannot place is precisely the state the hand-it-back interaction exists
	--  for; when that lands it hangs off this branch rather than a second test.
	--
	--  Blocks harvest, animals and withdraw as well, by returning outright.
	--  Harvesting while unable to deposit only manufactures drops that cannot be
	--  collected either, and withdrawWork manufactures cargo on top of cargo.
	if self.petData ~= nil and self.petData.cargo ~= nil
	   and #self.petData.cargo > 0 then
		return nil, noDrop
			or ("carrying " .. sb.printJson(#self.petData.cargo)
				.. " stack(s) with no dispatchable deposit target")
	end

  local work, why = collectionWork()
  if work ~= nil then return work end

  --  HARVEST SITS BELOW COLLECT, and the reason is perishability. An item drop
  --  has a despawn timer; a ripe crop does not, and will be exactly as ripe in
  --  a minute. So clearing the ground first costs nothing and losing a drop to
  --  a harvest detour costs the item.
  --
  --  It also produces a rhythm that reads well: harvest, drops appear, collect
  --  them, deposit runs because deposit outranks collect, come back, harvest
  --  the next one.
  local crop, noCrop = harvestWork()
  if crop ~= nil then return crop end

  --  BESIDE CROP HARVESTING, below collection, for the same reason: an animal
  --  that is ready stays ready, where a drop on the ground is on a despawn
  --  timer. Nothing is lost by clearing the ground first.
  local beast, noBeast = animalWork()
  if beast ~= nil then return beast end

  --  Fetching is the lowest-priority thing a unit can do: it is the only work
  --  that MANUFACTURES cargo rather than clearing something. See withdrawWork.
  local fetch, noFetch = withdrawWork()
  if fetch ~= nil then return fetch end

  local fetchWater, noFetchWater = withdrawWaterWork()
  if fetchWater ~= nil then return fetchWater end

	--  The old noDrop fallback lived here and is now unreachable: noDrop is only
	--  ever set when cargo is non-empty, and the guard above returns on that
	--  condition before anything below runs.

  if DIAG_FALLBACK then
    return diagnosticWork()
  end

  --  Both reasons, because "no drops in network coverage" alone reads as though
  --  the port never looked at the farm.
  if noCrop ~= nil then
    return nil, tostring(why) .. "; " .. tostring(noCrop)
      .. "; " .. tostring(noFetch or noPutBack or "no replant work")
      .. "; " .. tostring(noWet or noFetchWater or "no watering work")
      .. "; " .. tostring(noBeast or "no animal work")
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
  --  "collect" and "harvest" both name a target the NETWORK found, which may
  --  legitimately sit inside another member port's rect. Only points this port
  --  GENERATED itself are checked against its own rect.
  if work.type ~= "collect" and work.type ~= "harvest"
     and work.type ~= "replant" and work.type ~= "withdraw"
     and work.type ~= "water" and work.type ~= "animal"
     and not petports_rectContains(coverageRect(), work.position) then
    return reject(string.format(
      "generated point outside rect: %s type %s at %s, own rect %s",
      tostring(work.id), tostring(work.type), sb.printJson(work.position),
      sb.printJson(coverageRect())))
  end

  if not petports_claimTake(work.id, stationUniqueId(), petUniqueId(),
                            work.type, work.position, CLAIM_TTL) then
    --  Name the work. "claimed by another owner" on its own does not say
    --  whether two ports are racing for one drop or one crate, and those are
    --  very different problems.
    return reject("claimed by another owner: " .. tostring(work.id))
  end

  --  CARGO MANIFEST, FOR DISPLAY ONLY.
  --
  --  Cargo lives on the port, not the unit, so the unit cannot draw what it is
  --  carrying without being told. The task table is already crossing the
  --  boundary, so it carries a short summary rather than opening a second sync
  --  channel for something only the debug overlay reads.
  --
  --  A SNAPSHOT, not a live view. It is correct at dispatch and goes stale the
  --  moment anything changes -- which for a deposit run is exactly the window
  --  it needs to be right for, since the load does not change between leaving
  --  and arriving.
  if self.petData ~= nil and self.petData.cargo ~= nil then
    local manifest = {}
    for _, stack in ipairs(self.petData.cargo) do
      table.insert(manifest, string.format("%sx %s",
        tostring(stack.count or 1), tostring(stack.name)))
    end
    work.cargo = manifest
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

  sb.logInfo("PETPORT %s tracking %s, age %s of %s",
    stationUniqueId(), self.task.id,
    sb.printJson(self.taskAge), sb.printJson(TASK_DEADLINE))

  petports_claimRefresh(self.task.id, stationUniqueId(), CLAIM_TTL)
end

local function workUpdate(dt)
  self.workTimer = self.workTimer - dt
  if self.workTimer > 0 then return end
  self.workTimer = WORK_INTERVAL

  petports_claimsSweep()

  --  RE-PUBLISH IF OUR OWN ENTRY HAS GONE.
  --
  --  publishRegistry otherwise runs only on the first update, so a port that
  --  lost its entry stayed lost for the rest of the session -- it reported
  --  "network now 0 ports", could not count even itself, and union dispatch
  --  died with it. That is exactly what registryClearAt used to do to every
  --  port within sixteen tiles.
  --
  --  Cheap: one world property read on the work timer, and the branch is not
  --  taken in normal operation.
  --
  --  CANNOT LOOP. Re-publishing calls registryClearAt, which now matches only
  --  the port's exact tile -- and two ports cannot occupy one tile, so the only
  --  entry it can clear is a predecessor with no live object left to re-publish
  --  it. Restoring the rect-wide clear would turn this into two ports evicting
  --  and re-publishing each other forever.
  local registry = petports_registry()
  if (registry.ports or {})[stationUniqueId()] == nil then
    sb.logInfo("PETPORT %s registry entry is missing -- re-publishing",
      stationUniqueId())
    publishRegistry()
  end

  refreshNetwork()
  refreshBeacons(WORK_INTERVAL)
  refreshFarmables(WORK_INTERVAL)
  refreshAnimals(WORK_INTERVAL)
  sweepReplants(WORK_INTERVAL)
  publishUnitPosition()

  --  Cheap: loadUniqueEntity on an existing stagehand and out.
  ensureResidency()

  sb.logInfo("PETPORT %s tick: unit %s task %s",
    stationUniqueId(), sb.printJson(self.petId),
    self.task and self.task.id or "none")

  if self.task == nil then
    dispatchWork()
  else
    trackWork()
  end
end

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

function setAnimationStateForAllHullComponents(anim)
	if not anim then return end
	animator.setAnimationState("hullState", anim)
    animator.setAnimationState("doorState", anim)
    animator.setAnimationState("interiorState", anim)
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
    setHullAnimationStateIntent("close")

    --  This branch returns BEFORE workUpdate, so nothing below runs while the
    --  port sits empty -- no sweep, no refresh. A claim left here would survive
    --  until this port's next init cleared it. Release it on the way out.
    abandonTask("item removed")

    --  AND THE UNIT POSITION, for exactly the same reason.
    --
    --  publishUnitPosition also lives past this return, so an emptied port kept
    --  publishing the position its unit had when the item came out -- forever.
    --  anotherUnitIsCloser reads unitPosition ~= nil and busy == false as a
    --  live idle unit, so every emptied port left a GHOST that could veto drops
    --  near wherever it last stood. In a base with several ports, that suppresses
    --  dispatch for work nobody is ever going to do.
    --
    --  publishUnitPosition already handles this correctly -- it resolves the
    --  position to nil when there is no pet, and treats nil as movement. It was
    --  simply never reached.
    publishUnitPosition()
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
      setHullAnimationStateIntent("close")
      abandonTask("socketed item is not a pet")
      return
    end
    self.spawnTimer = 0
  end

  setHullAnimationStateIntent("open")

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
