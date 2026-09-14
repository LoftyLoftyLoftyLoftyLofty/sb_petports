PETPORTS_HABITAT_SWIMS = "swims"
PETPORTS_HABITAT_FLIES = "flies"
PETPORTS_HABITAT_EITHER_MEDIUM = "eitherMedium"
PETPORTS_HABITAT_AMPHIBIOUS = "amphibious"
PETPORTS_HABITAT_DRY_FOOTING = "dryFooting"

PETPORTS_HABITAT_FORBIDDEN_LIQUID = "forbiddenLiquid"
PETPORTS_HABITAT_MIXED_MEDIUM = "mixedMedium"
PETPORTS_HABITAT_SUBMERGED_NO_SWIM = "submergedNoSwim"
PETPORTS_HABITAT_DRY_NO_FLY = "dryNoFly"
PETPORTS_HABITAT_NO_MEDIUM = "noMedium"
PETPORTS_HABITAT_SUBMERGED_WALKER = "submergedWalker"

local REASONS =
{
	[PETPORTS_HABITAT_SWIMS] = "port is submerged and this chassis swims",
	[PETPORTS_HABITAT_FLIES] = "port is in air and this chassis flies",
	[PETPORTS_HABITAT_EITHER_MEDIUM] = "this chassis both flies and swims, so any footprint suits it",
	[PETPORTS_HABITAT_AMPHIBIOUS] = "amphibious walker, any medium",
	[PETPORTS_HABITAT_DRY_FOOTING] = "port has dry footing",

	[PETPORTS_HABITAT_FORBIDDEN_LIQUID] = "the port sits in a liquid this chassis will not enter",
	[PETPORTS_HABITAT_MIXED_MEDIUM] = "the port straddles a waterline, and this chassis needs all of it to be one medium",
	[PETPORTS_HABITAT_SUBMERGED_NO_SWIM] = "the port is fully submerged and this chassis cannot swim",
	[PETPORTS_HABITAT_DRY_NO_FLY] = "the port is out of the water and this chassis cannot leave it",
	[PETPORTS_HABITAT_NO_MEDIUM] = "this chassis can occupy neither medium the port offers",
	[PETPORTS_HABITAT_SUBMERGED_WALKER] = "the port is fully submerged and this walker will not stand in liquid"
}

local TARGET_REASONS =
{
	[PETPORTS_HABITAT_FORBIDDEN_LIQUID] = "sits in a liquid this chassis will not enter",
	[PETPORTS_HABITAT_MIXED_MEDIUM] = "straddles a waterline, and this chassis needs all of it to be one medium",
	[PETPORTS_HABITAT_SUBMERGED_NO_SWIM] = "is submerged and this chassis cannot swim",
	[PETPORTS_HABITAT_DRY_NO_FLY] = "is out of the water and this chassis cannot leave it",
	[PETPORTS_HABITAT_NO_MEDIUM] = "offers neither medium this chassis can occupy",
	[PETPORTS_HABITAT_SUBMERGED_WALKER] = "is submerged and this walker will not stand in liquid"
}

function petports_habitatTargetReason(cause)
	return TARGET_REASONS[cause] or ("is refused: " .. tostring(cause))
end

function petports_habitatReason(cause)
	return REASONS[cause] or "cannot inhabit this port"
end


local liquidNameCache = {}

function petports_habitatLiquidNames(liquidId)
	local key = tostring(liquidId)
	if liquidNameCache[key] ~= nil then return liquidNameCache[key] end

	local resolved = {}
	local ok, liquid = pcall(root.liquidConfig, liquidId)

	if ok and type(liquid) == "table" then
		if liquid.name ~= nil then table.insert(resolved, string.lower(tostring(liquid.name))) end

		if type(liquid.config) == "table" then
			if liquid.config.name ~= nil then table.insert(resolved, string.lower(tostring(liquid.config.name))) end
			if liquid.config.itemDrop ~= nil then table.insert(resolved, string.lower(tostring(liquid.config.itemDrop))) end
		end
	end

	table.insert(resolved, string.lower(key))

	liquidNameCache[key] = resolved
	return resolved
end

function petports_habitatLiquidDenied(avoided, liquidId)
	if liquidId == nil then return false end
	if avoided == nil or next(avoided) == nil then return false end

	for _, candidate in ipairs(petports_habitatLiquidNames(liquidId)) do
		if avoided[candidate] then return true end
	end

	return false
end

function petports_habitatAvoidedSet(list)
	local names = {}

	for _, entry in ipairs(list or {}) do
		names[string.lower(tostring(entry))] = true
	end

	return names
end


local capabilityCache = {}

local function polyBounds(poly)
	if type(poly) ~= "table" or #poly == 0 then return nil end

	local left, bottom, right, top = nil, nil, nil, nil

	for _, point in ipairs(poly) do
		if type(point) == "table" and #point >= 2 then
			local x, y = point[1], point[2]

			if left == nil or x < left then left = x end
			if right == nil or x > right then right = x end
			if bottom == nil or y < bottom then bottom = y end
			if top == nil or y > top then top = y end
		end
	end

	if left == nil then return nil end
	return { left, bottom, right, top }
end

local function typeCapabilities(monsterType)
	if monsterType == nil then return nil end

	local key = tostring(monsterType)
	if capabilityCache[key] ~= nil then return capabilityCache[key] end

	local ok, params = pcall(root.monsterParameters, key)
	if not ok or type(params) ~= "table" then return nil end

	local base = type(params.baseParameters) == "table" and params.baseParameters or {}

	local function read(name, fallback)
		local value = params[name]
		if value == nil then value = base[name] end
		if value == nil then return fallback end
		return value
	end

	local movement = read("movementSettings", {})
	if type(movement) ~= "table" then movement = {} end

	local caps =
	{
		freeMover = (movement.gravityEnabled == false),
		fly = read("petports_canFly", true),
		swim = read("petports_canSwim", false),
		avoidLiquid = read("petports_avoidLiquid", true),
		avoided = petports_habitatAvoidedSet(read("petports_avoidLiquids", {})),

		bounds = polyBounds(movement.collisionPoly)
	}

	capabilityCache[key] = caps
	return caps
end

function petports_habitatCapabilitiesForType(monsterType, permitted)
	local caps = typeCapabilities(monsterType)
	if caps == nil then return nil end
	if permitted == nil or next(permitted) == nil then return caps end

	local avoided = {}
	for name in pairs(caps.avoided) do
		if not permitted[name] then avoided[name] = true end
	end

	return
	{
		freeMover = caps.freeMover,
		fly = caps.fly,
		swim = caps.swim,
		avoidLiquid = caps.avoidLiquid,
		avoided = avoided,
		bounds = caps.bounds
	}
end

function petports_habitatPermittedSet(list)
	return petports_habitatAvoidedSet(list)
end


PETPORTS_TETHER_PORT = "port"
PETPORTS_TETHER_FLOOR = "floor"
PETPORTS_TETHER_CEILING = "ceiling"

local DEFAULT_TETHER = PETPORTS_TETHER_FLOOR

local KNOWN_TETHERS =
{
	[PETPORTS_TETHER_PORT] = true,
	[PETPORTS_TETHER_FLOOR] = true,
	[PETPORTS_TETHER_CEILING] = true
}

local tetherCache = {}

function petports_habitatTether(monsterType)
	if monsterType == nil then return DEFAULT_TETHER end

	local key = tostring(monsterType)
	if tetherCache[key] ~= nil then return tetherCache[key] end

	local ok, params = pcall(root.monsterParameters, key)
	local value = nil

	if ok and type(params) == "table" then
		value = params.petports_portTetheringLocationType

		if value == nil and type(params.baseParameters) == "table" then
			value = params.baseParameters.petports_portTetheringLocationType
		end
	end

	if value ~= nil and not KNOWN_TETHERS[value] then
		sb.logInfo("PETPORTS monster type %s declares petports_portTetheringLocationType %s, "
			.. "which is not one of port/floor/ceiling -- falling back to %s",
			key, tostring(value), DEFAULT_TETHER)
		value = nil
	end

	value = value or DEFAULT_TETHER
	tetherCache[key] = value
	return value
end


function petports_habitatVerdict(caps, wet, dry, liquids)
	if type(caps) ~= "table" then return nil end

	for _, id in ipairs(liquids or {}) do
		if petports_habitatLiquidDenied(caps.avoided, id) then
			return { ok = false, cause = PETPORTS_HABITAT_FORBIDDEN_LIQUID }
		end
	end

	if caps.freeMover then
		if caps.fly and caps.swim then
			return { ok = true, cause = PETPORTS_HABITAT_EITHER_MEDIUM }
		end

		if caps.swim and wet and not dry then
			return { ok = true, cause = PETPORTS_HABITAT_SWIMS }
		end

		if caps.fly and dry and not wet then
			return { ok = true, cause = PETPORTS_HABITAT_FLIES }
		end

		if wet and dry then
			return { ok = false, cause = PETPORTS_HABITAT_MIXED_MEDIUM }
		end

		if wet then
			return { ok = false, cause = PETPORTS_HABITAT_SUBMERGED_NO_SWIM }
		end

		if dry then
			return { ok = false, cause = PETPORTS_HABITAT_DRY_NO_FLY }
		end

		return { ok = false, cause = PETPORTS_HABITAT_NO_MEDIUM }
	end

	if not caps.avoidLiquid then
		return { ok = true, cause = PETPORTS_HABITAT_AMPHIBIOUS }
	end

	if dry then return { ok = true, cause = PETPORTS_HABITAT_DRY_FOOTING } end
	return { ok = false, cause = PETPORTS_HABITAT_SUBMERGED_WALKER }
end


PETPORTS_HABITAT_SUBMERGED_FILL = 0.9

function petports_habitatMedia(points)
	if points == nil or #points == 0 then return false, true, {} end

	local wet, dry = false, false
	local seen, liquids = {}, {}

	for _, point in ipairs(points) do
		local level = world.liquidAt(point)
		local fill = (level ~= nil) and (level[2] or 0) or 0

		if level ~= nil and level[1] ~= nil and fill > 0 and not seen[level[1]] then
			seen[level[1]] = true
			table.insert(liquids, level[1])
		end

		if fill >= PETPORTS_HABITAT_SUBMERGED_FILL then
			wet = true
		else
			dry = true
		end
	end

	return wet, dry, liquids
end

function petports_habitatAnyPointSuits(caps, points)
	if points == nil or #points == 0 then return { ok = true } end

	local firstRefusal = nil

	for _, point in ipairs(points) do
		local wet, dry, liquids = petports_habitatMedia({ point })
		local verdict = petports_habitatVerdict(caps, wet, dry, liquids)

		if verdict == nil or verdict.ok then return verdict or { ok = true } end
		if firstRefusal == nil then firstRefusal = verdict end
	end

	return firstRefusal
end

function petports_habitatObjectPoints(entityId)
	if entityId == nil then return nil end

	if type(entityId) ~= "number" then
		if self ~= nil and self.petportsObjectPointsWarned ~= entityId then
			self.petportsObjectPointsWarned = entityId
			sb.logInfo("HABITAT objectPoints asked about a non-entity target %s -- refusing",
				tostring(entityId))
		end
		return nil
	end

	local ok, spaces = pcall(world.objectSpaces, entityId)
	if not ok or type(spaces) ~= "table" or #spaces == 0 then return nil end

	local origin = world.entityPosition(entityId)
	if origin == nil then return nil end

	local points = {}

	for _, space in ipairs(spaces) do
		table.insert(points, {
			math.floor(origin[1]) + space[1] + 0.5,
			math.floor(origin[2]) + space[2] + 0.5
		})
	end

	return points
end

function petports_habitatObjectBounds(entityId)
	local points = petports_habitatObjectPoints(entityId)
	if points == nil or #points == 0 then return nil end

	local minX, minY = points[1][1], points[1][2]
	local maxX, maxY = minX, minY

	for _, point in ipairs(points) do
		if point[1] < minX then minX = point[1] end
		if point[1] > maxX then maxX = point[1] end
		if point[2] < minY then minY = point[2] end
		if point[2] > maxY then maxY = point[2] end
	end

	return { minX, minY, maxX, maxY }
end
