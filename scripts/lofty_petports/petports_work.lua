PETPORTS_WORK_BUILD_STAMP = "2026-09-11b removal is replacement: petports_cleared, because metamod:none is not a real mod"

local CLAIM_KEY = "petports_claims"


function petports_claimsAll()
  return world.getProperty(CLAIM_KEY) or {}
end

local claimsMemo = nil

function petports_claimsMemoBegin()
  claimsMemo = petports_claimsAll()
end

function petports_claimsMemoEnd()
  claimsMemo = nil
end

local function writeClaims(claims)
  world.setProperty(CLAIM_KEY, claims)
  if claimsMemo ~= nil then claimsMemo = claims end
end

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

function petports_claimsClearType(workType)
  if workType == nil then return 0 end
  local claims = petports_claimsAll()
  local dropped = 0
  for workId, claim in pairs(claims) do
    if claim.type == workType then
      claims[workId] = nil
      dropped = dropped + 1
    end
  end
  if dropped > 0 then writeClaims(claims) end
  return dropped
end

function petports_claimsSweep()
  local claims = petports_claimsAll()
  local now = world.time()
  local changed = false

  for workId, claim in pairs(claims) do
    if (claim.expires or 0) <= now then
      sb.logInfo("PETPORTS claim %s expired (owner %s, unit %s)",
        workId, tostring(claim.owner), tostring(claim.unit))
      claims[workId] = nil
      changed = true
    end
  end

  if changed then writeClaims(claims) end
end

function petports_claimGet(workId)
  if claimsMemo ~= nil then return claimsMemo[workId] end
  return petports_claimsAll()[workId]
end

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

function petports_rectsAdjacent(a, b, pad)
  pad = pad or 1
  local inflated = { a[1] - pad, a[2] - pad, a[3] + pad, a[4] + pad }

  return not (inflated[1] > b[3] or inflated[3] < b[1]
           or inflated[2] > b[4] or inflated[4] < b[2])
end


local REGISTRY_KEY = "petports_registry"

function petports_registry()
  return world.getProperty(REGISTRY_KEY) or { version = 0, ports = {} }
end

function petports_registryVersion()
  return petports_registry().version or 0
end

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

function petports_registryRemove(portId)
  local registry = petports_registry()
  if registry.ports == nil or registry.ports[portId] == nil then return end

  sb.logInfo("PETPORTS registry REMOVE %s (was rect %s)",
    tostring(portId), sb.printJson(registry.ports[portId].rect))

  registry.ports[portId] = nil
  registry.version = (registry.version or 0) + 1
  world.setProperty(REGISTRY_KEY, registry)
end

function petports_registryTouch()
  local registry = petports_registry()
  registry.version = (registry.version or 0) + 1
  world.setProperty(REGISTRY_KEY, registry)

  sb.logInfo("PETPORTS registry touched -> version %s", sb.printJson(registry.version))
end

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

function petports_entriesCompatible(a, b)
  if a.participate and b.participate then return true end
  if not a.participate and not b.participate then return a.id == b.id end
  return false
end

local function networkMemberMap(portId)
  local registry = petports_registry()
  local ports = registry.ports or {}
  local self_ = ports[portId]

  if self_ == nil then return {} end

  local members = { [portId] = self_ }
  local frontier = { portId }

  while #frontier > 0 do
    local currentId = table.remove(frontier)
    local current = members[currentId]

    for otherId, other in pairs(ports) do
      if members[otherId] == nil then
        if petports_entriesCompatible(current, other)
           and petports_rectsAdjacent(current.rect, other.rect) then
          members[otherId] = other
          table.insert(frontier, otherId)
        end
      end
    end
  end

  return members
end

local function sortedMemberIds(members)
  local ids = {}
  for memberId, _ in pairs(members) do table.insert(ids, memberId) end
  table.sort(ids)
  return ids
end

function petports_networkMemberIds(portId)
  return sortedMemberIds(networkMemberMap(portId))
end

function petports_networkMembers(portId)
  local members = networkMemberMap(portId)

  local list = {}
  for _, memberId in ipairs(sortedMemberIds(members)) do
    table.insert(list, members[memberId])
  end
  return list
end

function petports_networkRects(portId)
  local rects = {}
  for _, entry in ipairs(petports_networkMembers(portId)) do
    table.insert(rects, entry.rect)
  end
  return rects
end

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


local FISH_KEY = "petports_fish"

function petports_fishAll()
	return world.getProperty(FISH_KEY) or {}
end

function petports_fishPublish(portId, entry)
	if portId == nil then return end

	local fish = petports_fishAll()
	fish[portId] = entry
	world.setProperty(FISH_KEY, fish)
end

function petports_fishClearOwner(portId)
	if portId == nil then return end

	local fish = petports_fishAll()
	if fish[portId] == nil then return end

	sb.logInfo("PETPORTS fish entry from %s withdrawn (was %s)",
		tostring(portId), sb.printJson(fish[portId].id))

	fish[portId] = nil
	world.setProperty(FISH_KEY, fish)
end

function petports_fishSweep()
	local fish = petports_fishAll()
	local now = world.time()
	local changed = false

	for portId, entry in pairs(fish) do
		if (entry.expires or 0) <= now then
			sb.logInfo("PETPORTS fish entry from %s EXPIRED (fish %s) -- its port "
				.. "never withdrew it", tostring(portId), sb.printJson(entry.id))
			fish[portId] = nil
			changed = true
		end
	end

	if changed then world.setProperty(FISH_KEY, fish) end
end


function petports_tileKey(position)
  return string.format("%s,%s",
    math.floor(position[1]),
    math.floor(position[2]))
end

local REPLANT_KEY = "petports_replants"

function petports_replantsAll()
	return world.getProperty(REPLANT_KEY) or {}
end

function petports_replantGet(tileKey)
	return petports_replantsAll()[tileKey]
end

function petports_replantSet(position, seedName, ownerId)
	local key = petports_tileKey(position)
	local intents = petports_replantsAll()

	intents[key] = {
		name = seedName,
		position = { math.floor(position[1]), math.floor(position[2]) },
		owner = ownerId,
		created = world.time()
	}

	sb.logInfo("PETPORTS replant intent SET at %s for %s (by %s)",
		key, tostring(seedName), tostring(ownerId))

	world.setProperty(REPLANT_KEY, intents)
	return key
end

function petports_replantClearMany(keys, why)
	if type(keys) ~= "table" or #keys == 0 then return 0 end

	local intents = petports_replantsAll()
	local cleared = 0

	for _, key in ipairs(keys) do
		if intents[key] ~= nil then
			intents[key] = nil
			cleared = cleared + 1
		end
	end

	if cleared == 0 then return 0 end

	sb.logInfo("PETPORTS replant intents CLEARED x%s: %s",
		sb.printJson(cleared), tostring(why or "no reason given"))

	world.setProperty(REPLANT_KEY, intents)
	return cleared
end

function petports_anyPortCovers(position)
	if type(position) ~= "table" then return false end

	for _, entry in pairs(petports_registry().ports or {}) do
		if type(entry) == "table" and type(entry.rect) == "table"
		   and #entry.rect == 4
		   and petports_rectContains(entry.rect, position) then
			return true
		end
	end

	return false
end

function petports_replantClear(tileKey, why)
	local intents = petports_replantsAll()
	if intents[tileKey] == nil then return false end

	sb.logInfo("PETPORTS replant intent CLEARED at %s: %s",
		tostring(tileKey), tostring(why or "no reason given"))

	intents[tileKey] = nil
	world.setProperty(REPLANT_KEY, intents)
	return true
end

function petports_routeKey(position, exitId)
  return petports_tileKey(position) .. "|" .. tostring(exitId)
end

local unitTypeCache = {}

function petports_isUnitType(monsterType)
	if monsterType == nil then return false end

	local key = tostring(monsterType)
	if unitTypeCache[key] ~= nil then return unitTypeCache[key] end

	local ok, params = pcall(root.monsterParameters, key)
	if not ok or type(params) ~= "table" then
		return false
	end

	local base = type(params.baseParameters) == "table" and params.baseParameters or {}
	local flag = params.petports_unit
	if flag == nil then flag = base.petports_unit end

	local verdict = (flag == true)
	unitTypeCache[key] = verdict
	return verdict
end


local HEAL_KEY = "petports_heals"

function petports_healsAll()
	return world.getProperty(HEAL_KEY) or {}
end

local function pruneHeals(heals)
	local now = world.time()

	for key, readyAt in pairs(heals) do
		local id = tonumber(key)
		if type(readyAt) ~= "number" or readyAt <= now
		   or id == nil or not world.entityExists(id) then
			heals[key] = nil
		end
	end

	return heals
end

local function healKey(entityId)
	return tostring(entityId)
end

function petports_healCooldownRemaining(entityId)
	if entityId == nil then return 0 end

	local heals = petports_healsAll()
	local readyAt = heals[healKey(entityId)]
	if type(readyAt) ~= "number" then return 0 end

	return math.max(readyAt - world.time(), 0)
end

function petports_healRecord(entityId, duration)
	if entityId == nil then return false end

	local heals = pruneHeals(petports_healsAll())
	heals[healKey(entityId)] = world.time() + (duration or 0)
	world.setProperty(HEAL_KEY, heals)

	sb.logInfo("PETPORTS heal recorded for entity %s, next dose in %ss",
		tostring(entityId), tostring(duration or 0))
	return true
end

function petports_healWorkId(entityId)
	return "heal:" .. tostring(entityId)
end

local chassisTeamCache = {}

function petports_chassisTeam(monsterType)
	if monsterType == nil then return nil end

	local key = tostring(monsterType)
	if chassisTeamCache[key] ~= nil then return chassisTeamCache[key] end

	local ok, params = pcall(root.monsterParameters, key)
	if not ok or type(params) ~= "table" then return nil end

	local base = type(params.baseParameters) == "table" and params.baseParameters or {}

	local function read(name, fallback)
		local value = params[name]
		if value == nil then value = base[name] end
		if value == nil then return fallback end
		return value
	end

	local team =
	{
		type = tostring(read("damageTeamType", "friendly")),
		team = tonumber(read("damageTeam", 2)) or 2
	}

	chassisTeamCache[key] = team
	return team
end


local ASTERITE_KEY = "petports_asterite"

PETPORTS_ASTERITE_MOD = "asterite"
PETPORTS_ASTERITE_CLEARED = "petports_cleared"

local ASTERITE_CAP = 2000

function petports_asteriteCap()
	return ASTERITE_CAP
end

function petports_asteriteAll()
	return world.getProperty(ASTERITE_KEY) or {}
end

function petports_asteriteGet(tileKey)
	return petports_asteriteAll()[tileKey]
end

function petports_asteriteCount()
	local n = 0
	for _ in pairs(petports_asteriteAll()) do n = n + 1 end
	return n
end

function petports_asteriteNote(position, modName, ownerId)
	if type(position) ~= "table" or type(modName) ~= "string" then
		return false, 0, false
	end

	local key = petports_tileKey(position)
	local deposits = petports_asteriteAll()

	local count = 0
	for _ in pairs(deposits) do count = count + 1 end

	if deposits[key] ~= nil then return false, count, false end
	if count >= ASTERITE_CAP then return false, count, true end

	deposits[key] = {
		position = { math.floor(position[1]), math.floor(position[2]) },
		mod = modName,
		found = world.time(),
		finder = ownerId
	}

	world.setProperty(ASTERITE_KEY, deposits)
	return true, count + 1, false
end

function petports_asteriteClear(tileKey)
	if tileKey == nil then return false end

	local deposits = petports_asteriteAll()
	if deposits[tileKey] == nil then return false end

	deposits[tileKey] = nil
	world.setProperty(ASTERITE_KEY, deposits)
	return true
end

function petports_asteriteWipe()
	local n = petports_asteriteCount()
	world.setProperty(ASTERITE_KEY, {})
	sb.logInfo("PETPORTS asterite store WIPED, %s deposit(s) dropped",
		sb.printJson(n))
	return n
end
