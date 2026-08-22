--  PETPORTS -- WORK CLAIMS AND COVERAGE RECTS
--
--  Shared by the petport (object script) and the unit (monster script list).
--  Required from both, so it must define PREFIXED FUNCTIONS ONLY -- a monster's
--  scripts share one Lua environment, and a second definition of init/update/
--  uninit silently replaces groundPet.lua's.
--
--  CLAIMS
--
--  Claims live in world.properties so that two units never chase the same job.
--  This is replicated state written frequently, so the structure is kept small
--  and flat.
--
--      world property "petports_claims" = {
--        [workId] = {
--          owner    = <petport uniqueId>   -- who issued it
--          unit     = <unit uniqueId>      -- who is executing it
--          type     = <string>             -- what kind of work
--          position = {x, y}               -- corroborating detail, see below
--          expires  = <world.time() + ttl>
--        }
--      }
--
--  The KEY is the work id. Corroborating fields are checked at use, never
--  folded into the key: two claims for the same job must not be able to coexist
--  because one of them computed a position half a tile differently.
--
--  STALE CLAIMS AND WORLD RELOAD
--
--  A world unload orphans every claim held at that moment. Rather than a global
--  session token, each petport CLEARS ITS OWN claims at init -- a port's init
--  runs exactly once per load, so its stale entries are gone before it issues
--  anything new, and no port ever touches another's. Expiry then covers the
--  mid-session cases (unit died, port stopped refreshing, task abandoned).
--
--  Entity ids are NOT stable across a reload, so nothing here may key on one.
--  Owner and unit are uniqueIds, which we assign and persist.

local CLAIM_KEY = "petports_claims"

--------------------------------------------------------------------------------
--  CLAIMS
--------------------------------------------------------------------------------

function petports_claimsAll()
  return world.getProperty(CLAIM_KEY) or {}
end

local function writeClaims(claims)
  world.setProperty(CLAIM_KEY, claims)
end

--  Drop everything this owner holds. Called by a petport at init.
function petports_claimsClearOwner(ownerId)
  if ownerId == nil then return end

  local claims = petports_claimsAll()
  local changed = false

  for workId, claim in pairs(claims) do
    if claim.owner == ownerId then
      claims[workId] = nil
      changed = true
    end
  end

  if changed then writeClaims(claims) end
end

--  Drop anything past its expiry. Cheap enough to run on the same slow timer a
--  petport already has.
function petports_claimsSweep()
  local claims = petports_claimsAll()
  local now = world.time()
  local changed = false

  for workId, claim in pairs(claims) do
    if (claim.expires or 0) <= now then
      --  Expiry is the safety net for an interruption nobody reported: the unit
      --  died, the port unloaded mid-task, the world stopped. Logged because an
      --  expiry firing is a signal that something upstream failed to clean up
      --  after itself, not routine housekeeping.
      sb.logInfo("PETPORTS claim %s expired (owner %s, unit %s)",
        workId, tostring(claim.owner), tostring(claim.unit))
      claims[workId] = nil
      changed = true
    end
  end

  if changed then writeClaims(claims) end
end

function petports_claimGet(workId)
  return petports_claimsAll()[workId]
end

--  Take a claim if it is free or already ours. Returns true on success.
function petports_claimTake(workId, ownerId, unitId, workType, position, ttl)
  local claims = petports_claimsAll()
  local existing = claims[workId]
  local now = world.time()

  if existing ~= nil
     and existing.owner ~= ownerId
     and (existing.expires or 0) > now then
    sb.logInfo("PETPORTS claim %s REFUSED to %s: held by %s until %s (now %s)",
      workId, tostring(ownerId), tostring(existing.owner),
      sb.printJson(existing.expires), sb.printJson(now))
    return false
  end

  sb.logInfo("PETPORTS claim %s TAKEN by %s for unit %s, type %s at %s",
    workId, tostring(ownerId), tostring(unitId), tostring(workType),
    sb.printJson(position))

  claims[workId] = {
    owner = ownerId,
    unit = unitId,
    type = workType,
    position = position,
    expires = now + (ttl or 30)
  }

  writeClaims(claims)
  return true
end

--  Push the expiry out. The petport does this while it believes the work is in
--  flight; if the port unloads or the unit dies, refreshing stops and the claim
--  ages out on its own.
function petports_claimRefresh(workId, ownerId, ttl)
  local claims = petports_claimsAll()
  local claim = claims[workId]

  if claim == nil or claim.owner ~= ownerId then return false end

  claim.expires = world.time() + (ttl or 30)
  writeClaims(claims)
  return true
end

function petports_claimRelease(workId, ownerId)
  local claims = petports_claimsAll()
  local claim = claims[workId]

  if claim == nil then return false end

  if ownerId ~= nil and claim.owner ~= ownerId then
    sb.logInfo("PETPORTS claim %s release REFUSED to %s: held by %s",
      workId, tostring(ownerId), tostring(claim.owner))
    return false
  end

  sb.logInfo("PETPORTS claim %s RELEASED by %s", workId, tostring(ownerId))

  claims[workId] = nil
  writeClaims(claims)
  return true
end

--------------------------------------------------------------------------------
--  COVERAGE RECTS
--------------------------------------------------------------------------------
--
--  A rect is {xMin, yMin, xMax, yMax} in world tile coordinates -- the same
--  shape world.loadRegion and the world query calls take.
--
--  The VISUAL rect is authoritative for what work may be claimed and for what
--  gets kept resident. The inflated rect exists only for network adjacency
--  testing and must not leak into either -- see the handoff.

function petports_coverageRect(centre, size)
  local half = size / 2
  return {
    centre[1] - half,
    centre[2] - half,
    centre[1] + half,
    centre[2] + half
  }
end

function petports_rectContains(rect, position)
  return position[1] >= rect[1] and position[1] <= rect[3]
     and position[2] >= rect[2] and position[2] <= rect[4]
end

--  Touch-or-overlap, tested by inflating ONE side. Inflating both would double
--  the tolerance -- two rects with a visible one-tile gap would connect,
--  because each side's inflation eats half the gap.
function petports_rectsAdjacent(a, b, pad)
  pad = pad or 1
  local inflated = { a[1] - pad, a[2] - pad, a[3] + pad, a[4] + pad }

  return not (inflated[1] > b[3] or inflated[3] < b[1]
           or inflated[2] > b[4] or inflated[4] < b[2])
end

--------------------------------------------------------------------------------
--  REGISTRY AND NETWORKS
--------------------------------------------------------------------------------
--
--  Each petport publishes ONE small entry. This is the only thing that crosses
--  the wire, written on placement, removal, or an edit -- never on a tick.
--
--      world property "petports_registry" = {
--        version = <int>,
--        ports = { [portUniqueId] = { rect, participate, id, position } }
--      }
--
--  A version counter lets a port cheaply notice "something changed" without
--  diffing the whole structure every second.
--
--  NO PORT EVER MESSAGES ANOTHER PORT. Membership is DERIVED independently by
--  each port from shared state, so there is no ordering problem and nothing to
--  keep in sync.

local REGISTRY_KEY = "petports_registry"

function petports_registry()
  return world.getProperty(REGISTRY_KEY) or { version = 0, ports = {} }
end

function petports_registryVersion()
  return petports_registry().version or 0
end

--  Publish or update this port's entry. Bumps the version.
function petports_registryPublish(portId, entry)
  local registry = petports_registry()
  registry.ports = registry.ports or {}
  registry.ports[portId] = entry
  registry.version = (registry.version or 0) + 1
  world.setProperty(REGISTRY_KEY, registry)

  sb.logInfo("PETPORTS registry publish %s -> version %s, rect %s, unitPosition %s, busy %s",
    tostring(portId), sb.printJson(registry.version),
    sb.printJson(entry.rect), sb.printJson(entry.unitPosition),
    tostring(entry.busy))
end

--  Remove an entry. MUST be called from die(), never uninit -- uninit also
--  fires on world unload, and dropping every entry then would wipe the network
--  on each reload.
--
--  A lingering entry is the same shape of problem as an orphaned stagehand:
--  invisible, cumulative, and it creates a phantom coverage zone that merges
--  networks which should be separate, with nothing on screen to explain why.
function petports_registryRemove(portId)
  local registry = petports_registry()
  if registry.ports == nil or registry.ports[portId] == nil then return end

  sb.logInfo("PETPORTS registry REMOVE %s (was rect %s)",
    tostring(portId), sb.printJson(registry.ports[portId].rect))

  registry.ports[portId] = nil
  registry.version = (registry.version or 0) + 1
  world.setProperty(REGISTRY_KEY, registry)
end

--  Bump the version without changing any entry.
--
--  For structural changes that are NOT a port coming or going -- a vent being
--  rewired is the case this exists for. A rewired vent changes what routes are
--  possible without changing coverage by one tile, so nothing in `ports` moves
--  and a port diffing rects alone would see nothing at all.
--
--  Deliberately routed through the SAME version counter as coverage rather than
--  a second notification channel. Ports already poll this once and re-derive
--  everything they care about; giving vents their own path would mean two
--  mechanisms that can disagree about whether an update happened.
--
--  Callers must only touch on an ACTUAL change. A vent that touches on every
--  refresh tick turns a cheap poll into a permanent cache invalidation storm.
function petports_registryTouch()
  local registry = petports_registry()
  registry.version = (registry.version or 0) + 1
  world.setProperty(REGISTRY_KEY, registry)

  sb.logInfo("PETPORTS registry touched -> version %s", sb.printJson(registry.version))
end

--  Drop any entry standing on THIS EXACT TILE. Called by a port when it
--  publishes at init, so a port that was mined and replaced does not leave its
--  predecessor behind as a phantom.
--
--  TAKES A POSITION, NOT A RECT.
--
--  It used to take the port's whole COVERAGE RECT and clear every entry inside
--  it, which is the whole coverage square. Any two ports built within half of
--  each other therefore evicted one another from the registry at init, and
--  since publishRegistry only ever runs on the first update, the loser never
--  came back. It then reported "network now 0 ports" -- not even counting
--  itself -- and union dispatch was dead for the rest of the session.
--
--  Observed with six ports on a test planet: the last one to initialise cleared
--  four of the other five, including the only port holding a unit.
--
--  A replaced port occupies the SAME TILE as its predecessor. That is the whole
--  case this exists for, so that is the whole test.
function petports_registryClearAt(position, exceptPortId)
  local registry = petports_registry()
  if registry.ports == nil then return end

  local changed = false
  for portId, entry in pairs(registry.ports) do
    if portId ~= exceptPortId and entry.position ~= nil
       and math.floor(entry.position[1]) == math.floor(position[1])
       and math.floor(entry.position[2]) == math.floor(position[2]) then
      sb.logInfo("PETPORTS registry clearAt %s: dropping predecessor %s at %s",
        sb.printJson(position), tostring(portId), sb.printJson(entry.position))
      registry.ports[portId] = nil
      changed = true
    end
  end

  if changed then
    registry.version = (registry.version or 0) + 1
    world.setProperty(REGISTRY_KEY, registry)
  end
end

--  The network containing this port: contiguous coverage first, ID second.
--
--  Two passes, exactly as the design says:
--    1. union-find over OVERLAPPING (touch-or-overlap) rects -> clusters
--    2. partition each cluster by network ID -> networks
--
--  IDs are PER-CLUSTER NAMESPACES, not planetary ones. Network 1 on one side of
--  a planet and network 1 on the other are unrelated, and plausibly belong to
--  two different players.
--
--  Non-participation is MUTUAL: if A participates and B does not, they are not
--  connected, regardless of what A wants.
--
--  Returns a list of member entries, always including this port.
function petports_networkMembers(portId)
  local registry = petports_registry()
  local ports = registry.ports or {}
  local self_ = ports[portId]

  if self_ == nil then return {} end

  --  Flood fill outward from us. Small n, so a queue beats a real union-find.
  local members = { [portId] = self_ }
  local frontier = { portId }

  while #frontier > 0 do
    local currentId = table.remove(frontier)
    local current = members[currentId]

    for otherId, other in pairs(ports) do
      if members[otherId] == nil then
        --  Both must participate, or both must be pinned to the same id.
        local compatible
        if current.participate and other.participate then
          compatible = true
        elseif not current.participate and not other.participate then
          compatible = (current.id == other.id)
        else
          compatible = false
        end

        if compatible and petports_rectsAdjacent(current.rect, other.rect) then
          members[otherId] = other
          table.insert(frontier, otherId)
        end
      end
    end
  end

  --  SORTED. pairs() order is nondeterministic, and an unsorted list would
  --  compare unequal to itself and re-push to the unit every tick.
  local ids = {}
  for memberId, _ in pairs(members) do table.insert(ids, memberId) end
  table.sort(ids)

  local list = {}
  for _, memberId in ipairs(ids) do
    table.insert(list, members[memberId])
  end
  return list
end

--  Just the rects, for the unit's idle leash.
function petports_networkRects(portId)
  local rects = {}
  for _, entry in ipairs(petports_networkMembers(portId)) do
    table.insert(rects, entry.rect)
  end
  return rects
end

--  Do two rect lists describe the same coverage? Used to avoid pushing an
--  unchanged list to the unit.
function petports_rectListsEqual(a, b)
  if a == nil or b == nil then return a == b end
  if #a ~= #b then return false end

  for i = 1, #a do
    for j = 1, 4 do
      if a[i][j] ~= b[i][j] then return false end
    end
  end
  return true
end

--------------------------------------------------------------------------------
--  ROUTE CACHE KEYS
--------------------------------------------------------------------------------
--
--  The routing question is always the same shape: "can a unit walk to TARGET
--  from vent exit E?" Terrain decides that, not the drop -- so the answer is
--  reusable for every future target in the same neighbourhood.
--
--  Position keys are TILE-EXACT: math.floor of each coordinate, nothing more.
--
--  These were quantised into 16-tile buckets so that every drop in a
--  neighbourhood shared one cached answer. That traded correctness for reuse,
--  and the trade was bad in both directions.
--
--  A bucket is larger than a room. A unit shut in a cage and the port outside
--  it landed in the same bucket, so probes ran from the wrong side of a wall
--  and every edge came back reachable; the unit then stood still for the full
--  approach timeout walking into solid ground. The cache also held the reverse
--  error -- the cage's own vent recorded unreachable, from a probe taken
--  outside the cage -- and because the key was identical either way, nothing
--  could re-ask the question.
--
--  Subdividing does not fix that. The quantisation is GEOMETRIC and the cached
--  fact is TOPOLOGICAL: two points either side of a wall are adjacent by every
--  distance metric and unreachable from each other in fact. A smaller bucket
--  only makes a straddling wall rarer.
--
--  The reuse given up is smaller than it looks. The expensive part of this
--  cache is the vent-to-vent graph, keyed by ENTITY ID and never quantised at
--  all -- that is the V^2 term, and a cold one measured 47 seconds. Only the
--  unit-to-vent and vent-to-target edges lose sharing, and those are O(V). A
--  target key rarely hit anyway, since every drop lands somewhere new.
--
--  If reuse ever needs recovering, the answer is a key derived from CONNECTED
--  REGION rather than a coarser grid: two positions share a key when a unit can
--  actually walk between them. Correct by construction, and considerably more
--  machinery than this needs.

function petports_tileKey(position)
  return string.format("%s,%s",
    math.floor(position[1]),
    math.floor(position[2]))
end

--  One cache entry per (destination tile, vent exit).
function petports_routeKey(position, exitId)
  return petports_tileKey(position) .. "|" .. tostring(exitId)
end
