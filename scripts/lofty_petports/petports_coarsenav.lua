-- Coarse navigation: a cell graph of the world kept in world properties, and the routes taken across it.

local COARSENAV_BUILD_STAMP = "2026-09-20i the near-surface test reads the contract's submerged fill, 0.9, where it fell back to 0.5"

petports_navStamped = false

-- Logs the coarsenav build stamp once.
function petports_navStampOnce()
	if petports_navStamped then return end
	petports_navStamped = true
	sb.logInfo("PETPORTS coarsenav build: %s (unit %s)",
		COARSENAV_BUILD_STAMP, tostring(entity.id()))
end

local NAV_INDEX = "petports_navindex"
local NAV_EDGES = "petports_navedges:"

local NAV_MANIFEST = "petports_navmanifest"

local NAV_GEN = "petports_navgen"

local NAV_BLOCK_CELLS = 8

local NAV_DRAW_RANGE = 32

petports_navFamilies = {}

local NAV_BOUNDS = "petports_navbounds"
local NAV_BOUNDS_FILL = 0.5

-- Records a property family and its enumerator in the world manifest.
function petports_navFamilyRegister(root, enumerate)
	petports_navFamilies[root] = enumerate

	local ok, manifest = pcall(world.getProperty, NAV_MANIFEST)
	if not ok or type(manifest) ~= "table" then manifest = {} end

	if manifest[root] ~= true then
		manifest[root] = true
		pcall(world.setProperty, NAV_MANIFEST, manifest)
	end
end

local NAV_CACHE_TTL = 120.0

local NAV_OVERLAY_REFRESH = 2.0

PETPORTS_NAV_VERBOSE = true

-- Flips nav verbose logging and returns the new state.
function petports_navVerboseToggle()
	PETPORTS_NAV_VERBOSE = not PETPORTS_NAV_VERBOSE
	sb.logInfo("NAV verbose %s", PETPORTS_NAV_VERBOSE and "ON" or "OFF")
	return PETPORTS_NAV_VERBOSE
end

PETPORTS_NAV_CELL = 2

PETPORTS_NAV_STRIDE = 1

PETPORTS_NAV_STRIDE_FREE = 1

-- Returns this tick's cell stride, taking the free-mover value when the unit is one.
function petports_navStride()
	local now = world.time()

	if self.petportsNavStrideAt ~= now then
		self.petportsNavStrideAt = now
		self.petportsNavStride = PETPORTS_NAV_STRIDE

		if petports_freeMover ~= nil and petports_freeMover() then
			self.petportsNavStride = PETPORTS_NAV_STRIDE_FREE
		end
	end

	return self.petportsNavStride
end

-- Returns the world coordinates of a cell's origin.
function petports_navCellOrigin(cx, cy)
	local stride = petports_navStride()
	return cx * stride, cy * stride
end


PETPORTS_NAV_RADIUS = 12

PETPORTS_NAV_RADIUS_FREE = 4

-- Returns the neighbour search radius for this chassis.
function petports_navFullRadius()
	if petports_freeMover ~= nil and petports_freeMover() then
		return PETPORTS_NAV_RADIUS_FREE
	end
	return PETPORTS_NAV_RADIUS
end
PETPORTS_NAV_RADIUS_START = 2
PETPORTS_NAV_RADIUS_STEP = 2

-- Returns the next radius to sweep a cell at, or nil once it is fully swept.
function petports_navNextRadius(sweptRadius)
	if (sweptRadius or 0) >= petports_navFullRadius() then return nil end
	if (sweptRadius or 0) <= 0 then return PETPORTS_NAV_RADIUS_START end
	return math.min(sweptRadius + PETPORTS_NAV_RADIUS_STEP, petports_navFullRadius())
end

local NAV_COVERAGE_MARGIN = 2

-- Returns whether a box lies inside a network rect, with margin.
function petports_navBoxInCoverage(x0, y0, x1, y1)
	local rects = self.petportsNetwork

	if type(rects) ~= "table" or #rects == 0 then return true end

	for _, rect in ipairs(rects) do
		if x0 >= rect[1] - NAV_COVERAGE_MARGIN
		   and x1 <= rect[3] + NAV_COVERAGE_MARGIN
		   and y0 >= rect[2] - NAV_COVERAGE_MARGIN
		   and y1 <= rect[4] + NAV_COVERAGE_MARGIN then
			return true
		end
	end

	return false
end

-- Returns whether a cell overlaps a network rect, with margin.
function petports_navInCoverage(cx, cy)
	local rects = self.petportsNetwork

	if type(rects) ~= "table" or #rects == 0 then return true end

	local x0, y0 = petports_navCellOrigin(cx, cy)
	local x1 = x0 + PETPORTS_NAV_CELL
	local y1 = y0 + PETPORTS_NAV_CELL

	for _, rect in ipairs(rects) do
		if x1 >= rect[1] - NAV_COVERAGE_MARGIN
		   and x0 <= rect[3] + NAV_COVERAGE_MARGIN
		   and y1 >= rect[2] - NAV_COVERAGE_MARGIN
		   and y0 <= rect[4] + NAV_COVERAGE_MARGIN then
			return true
		end
	end

	return false
end


local NAV_MAX_DISTANCE = 32


PETPORTS_NAV_MAX_DISTANCE = NAV_MAX_DISTANCE

-- Returns the pathfinder options with the nav leg distance cap.
function petports_navPathOptions()
	local options = petports_pathOptions()
	options.maxDistance = NAV_MAX_DISTANCE
	return options
end


-- Returns the cell coordinates holding a position.
function petports_navCell(position)
	if type(position) ~= "table" then return nil, nil end

	local stride = petports_navStride()
	return math.floor(position[1] / stride),
		math.floor(position[2] / stride)
end

-- Returns the string key for cell coordinates.
function petports_navCellKey(cx, cy)
	return tostring(cx) .. "," .. tostring(cy)
end

local NAV_SOLID_SET = { "Null", "Block", "Dynamic", "Slippery" }

local NAV_ANCHOR_TTL = 30.0

-- Returns whether every tile in a cell collides.
function petports_navCellSolidUncached(cx, cy)
	local baseX, baseY = petports_navCellOrigin(cx, cy)

	for dx = 0, PETPORTS_NAV_CELL - 1 do
		for dy = 0, PETPORTS_NAV_CELL - 1 do
			local ok, hit = pcall(world.pointTileCollision,
				{ baseX + dx + 0.5, baseY + dy + 0.5 }, NAV_SOLID_SET)

			if not ok or hit ~= true then return false end
		end
	end

	return true
end

-- Returns whether a cell is solid, cached.
function petports_navCellSolid(cx, cy)
	local key = petports_navCellKey(cx, cy)
	local now = world.time()

	self.petportsNavSolidCache = self.petportsNavSolidCache or {}
	local hit = self.petportsNavSolidCache[key]

	if hit ~= nil and (now - hit.at) <= (NAV_ANCHOR_TTL or 30.0) then
		return hit.solid
	end

	local solid = petports_navCellSolidUncached(cx, cy)
	self.petportsNavSolidCache[key] = { at = now, solid = solid }

	return solid
end

local NAV_FOOTING_SET = { "Block", "Slippery", "Platform" }

-- Returns whether there is footing under the body's overlap with a cell at an x.
function petports_navFootingUnderCell(x, baseX, baseY, bounds)
	local left = math.max(baseX, x + bounds[1]) + 0.05
	local right = math.min(baseX + PETPORTS_NAV_CELL, x + bounds[3]) - 0.05

	if right <= left then return false end

	local ok, hit = pcall(world.rectTileCollision,
		{ left, baseY - 0.95, right, baseY - 0.05 }, NAV_FOOTING_SET)

	return ok and hit == true
end


-- Returns the point a body can stand or hover at inside a cell, or nil with the reason.
function petports_navAnchorUncached(cx, cy, freeMover)
	local baseX, baseY = petports_navCellOrigin(cx, cy)

	local bounds = mcontroller.boundBox()

	local lift = -(bounds[2] or -0.5)

	local tried = 0
	local refusal = nil

	if freeMover then
		local point = {
			baseX + PETPORTS_NAV_CELL * 0.5, baseY + PETPORTS_NAV_CELL * 0.5
		}
		local region = {
			point[1] + bounds[1], point[2] + bounds[2],
			point[1] + bounds[3], point[2] + bounds[4]
		}

		tried = tried + 1

		local ok, hit = true, petports_bodyHitsAt(point, { "Null", "Block", "Dynamic", "Slippery" })
		if hit ~= false then refusal = "the body hits a solid at the window centre" end

		local nearSurface = false

		if ok and hit == false then
			local grown = {
				region[1] - 0.5, region[2] - 0.5, region[3] + 0.5, region[4] + 0.5
			}

			local okNear, near = pcall(world.rectTileCollision, grown,
				{ "Block", "Dynamic", "Slippery", "Platform" })

			local insideGrown = petports_navBoxInCoverage(
				grown[1], grown[2], grown[3], grown[4])
			local insideBody = petports_navBoxInCoverage(
				region[1], region[2], region[3], region[4])

			nearSurface = insideBody
				and ((okNear and near == true) or not insideGrown)

			if insideBody and not nearSurface then
				local okC, centreLevel = pcall(world.liquidAt, { point[1], point[2] })
				local centreWet = okC and centreLevel ~= nil
					and (centreLevel[2] or 0) >= PETPORTS_CONSTANTS.contract.submergedFill
				local midX, midY = (grown[1] + grown[3]) * 0.5, (grown[2] + grown[4]) * 0.5
				for _, sample in ipairs({
					{ grown[1] + 0.05, midY }, { grown[3] - 0.05, midY },
					{ midX, grown[2] + 0.05 }, { midX, grown[4] - 0.05 }
				}) do
					local okT, level = pcall(world.liquidAt, sample)
					local wet = okT and level ~= nil
						and (level[2] or 0) >= PETPORTS_CONSTANTS.contract.submergedFill
					if wet ~= centreWet then nearSurface = true end
				end
			end

			if insideBody and not nearSurface and petports_navForbiddenCells ~= nil then
				local walls = petports_navForbiddenCells()
				if next(walls) ~= nil then
					local x0, y0 = math.floor(grown[1]), math.floor(grown[2])
					local x1, y1 = math.floor(grown[3] - 0.01), math.floor(grown[4] - 0.01)
					for ty = y0, y1 do
						for tx = x0, x1 do
							if walls[tx .. "," .. ty] ~= nil then nearSurface = true end
						end
					end
				end
			end

			if not nearSurface then
				refusal = insideBody and "no surface, waterline or wall within 0.5 of the body"
					or "the body leaves coverage"
			end
		end

		if ok and hit == false and nearSurface then
			local okMedium, allowed, allowWhy = pcall(petports_mediumAllows, point, bounds)

			if not okMedium or allowed ~= false then return point end

			refusal = "medium " .. tostring(petports_mediumAt(point, bounds)) .. " at "
				.. sb.printJson(point) .. " refused: " .. tostring(allowWhy)
		end
	else
		for dx = 0, PETPORTS_NAV_CELL - 1 do
			local x = baseX + dx + 0.5

			local point = { x, baseY + lift }

			tried = tried + 1

			if petports_navFootingUnderCell(x, baseX, baseY, bounds) then
				local ok, standable = pcall(validStandingPosition, point,
					petports_avoidLiquid())

				if ok and standable == true then
					local okMedium, allowed, allowWhy = pcall(petports_mediumAllows, point, bounds)

					if petports_gravitySwitchable() and petports_mediumAt(point, bounds) == "swim" then
						refusal = "the standing body is fully submerged at " .. sb.printJson(point)
					elseif not okMedium or allowed ~= false then
						return point
					else
						refusal = "medium at " .. sb.printJson(point) .. " refused: " .. tostring(allowWhy)
					end
				else
					refusal = "not a valid standing position at " .. sb.printJson(point)
				end
			elseif refusal == nil then
				refusal = "no footing under the cell"
			end
		end
	end

	return nil, string.format(
		"no anchor in cell %s,%s -- %s candidate(s) tried, freeMover %s, lift %s, last refusal: %s",
		tostring(cx), tostring(cy), tostring(tried), tostring(freeMover),
		tostring(lift), tostring(refusal))
end

-- Clears every cached nav structure and records the store generation.
function petports_navDropMemos(generation)
	self.petportsNavPending = {}
	self.petportsNavPendingCount = 0
	self.petportsNavFlushAt = nil
	self.petportsNavCellCache = {}
	self.petportsNavGraph = nil
	self.petportsNavGraphBuild = nil
	self.petportsNavMerged = nil
	self.petportsNavMergedBuild = nil
	self.petportsNavComplete = {}
	self.petportsNavPassRadius = nil
	self.petportsNavIndexPending = nil
	self.petportsNavIndexPendingCount = 0
	self.petportsNavIndexMemo = nil
	self.petportsNavAnchorCache = nil
	self.petportsNavSolidCache = nil
	self.petportsNavSweeps = nil
	self.petportsNavProbes = nil
	self.petportsNavBoundsMine = nil
	self.petportsNavBoundsPendingCount = 0
	self.petportsNavBoundsSeen = nil
	self.petportsNavIndexMine = nil
	self.petportsNavIndexSeen = nil
	self.petportsNavIndexLastRaw = nil
	self.petportsNavIndexShort = nil
	self.petportsNavIndexShortTries = nil
	self.petportsNavChunkKnown = nil
	self.petportsNavForbidden = nil
	self.petportsNavForbiddenAt = nil
	self.petportsNavBoundsDraw = nil
	self.petportsNavBoundsDrawAt = nil
	self.petportsNavContradictQueue = nil
	self.petportsNavBoundsFlood = nil
	self.petportsNavBoundsFound = nil
	self.petportsNavSeeds = nil
	self.petportsNavBoundsLocal = nil
	self.petportsNavLastRoute = nil
	self.petportsNavSurveyNote = nil
	self.petportsNavVersion = (self.petportsNavVersion or 0) + 1
	self.petportsNavGen = generation
end

-- Returns the store generation this unit is on.
function petports_navGenNow()
	petports_navGenerationCheck()
	if self.petportsNavGen == nil then
		local ok, gen = pcall(world.getProperty, NAV_GEN)
		self.petportsNavGen = (ok and type(gen) == "number") and gen or 0
	end
	return self.petportsNavGen
end

-- Drops the memos once another unit has bumped the store generation.
function petports_navGenerationCheck()
	local now = world.time()
	if self.petportsNavGenAt == now then return end
	self.petportsNavGenAt = now

	local ok, gen = pcall(world.getProperty, NAV_GEN)
	gen = (ok and type(gen) == "number") and gen or 0

	if self.petportsNavGen == nil then
		self.petportsNavGen = gen
	elseif gen ~= self.petportsNavGen then
		sb.logInfo("NAV generation %s -> %s: another unit wiped the store, "
			.. "dropping memos", sb.printJson(self.petportsNavGen), sb.printJson(gen))
		petports_navDropMemos(gen)
	end
end

-- Expires the anchor and solid caches on an interval and checks the generation.
function petports_navCachesTick()
	local now = world.time()

	if self.petportsNavCachesAt == nil
	   or (now - self.petportsNavCachesAt) > NAV_ANCHOR_TTL then
		self.petportsNavCachesAt = now
		self.petportsNavAnchorCache = nil
		self.petportsNavSolidCache = nil
	end

	petports_navGenerationCheck()
end

-- Returns a cell's anchor point, cached per profile, noting the cell as a boundary candidate.
function petports_navAnchor(cx, cy, freeMover)
	petports_navCachesTick()

	local key = petports_navCellKey(cx, cy)
	local profile = petports_navProfile()
	local now = world.time()

	self.petportsNavAnchorCache = self.petportsNavAnchorCache or {}
	local cache = self.petportsNavAnchorCache[profile]

	if cache == nil then
		cache = {}
		self.petportsNavAnchorCache[profile] = cache
	end

	local hit = cache[key]

	if hit ~= nil and (now - hit.at) <= NAV_ANCHOR_TTL then
		return hit.anchor, hit.why
	end

	local anchor, why = petports_navAnchorUncached(cx, cy, freeMover)
	cache[key] = { at = now, anchor = anchor, why = why }

	if petports_navInCoverage(cx, cy) then petports_navBoundaryNote(cx, cy) end

	return anchor, why
end

local NAV_NEIGHBOUR_CHUNK = 40

-- Returns the anchored cells within a radius, nearest first, yielding as it scans.
function petports_navNeighbours(cx, cy, freeMover, radius)
	radius = radius or petports_navFullRadius()

	local origin = petports_navAnchor(cx, cy, freeMover)
	if origin == nil then return {}, nil end

	local reach = math.ceil(radius / petports_navStride())

	local found = {}
	local solid = 0

	local inspected = 0
	local inCoroutine = coroutine.running() ~= nil

	for dx = -reach, reach do
		for dy = -reach, reach do
			if dx ~= 0 or dy ~= 0 then
				local nx, ny = cx + dx, cy + dy

				inspected = inspected + 1
				if inCoroutine and inspected % NAV_NEIGHBOUR_CHUNK == 0 then
					petports_profEnd("neighbours")
					coroutine.yield()
					petports_profBegin("neighbours")
				end

				local anchor = nil

				if petports_navCellSolid(nx, ny) then
					solid = solid + 1
				else
					anchor = petports_navAnchor(nx, ny, freeMover)
				end

				if anchor ~= nil then
					local ax = anchor[1] - origin[1]
					local ay = anchor[2] - origin[2]

					local distance = math.sqrt(ax * ax + ay * ay)

					if distance <= radius then
						table.insert(found, {
							cx = nx, cy = ny,
							anchor = anchor,
							distance = distance,
							key = petports_navCellKey(nx, ny)
						})
					end
				end
			end
		end
	end

	table.sort(found, function(a, b)
		if a.distance ~= b.distance then return a.distance < b.distance end
		return a.key < b.key
	end)

	sb.logInfo("NAV neighbours of %s at radius %s: %s candidate(s), "
		.. "%s solid cell(s) skipped",
		petports_navCellKey(cx, cy), sb.printJson(radius), sb.printJson(#found),
		sb.printJson(solid))

	return found, origin
end


-- Returns the profile string covering this chassis's type, movement, size and liquid rules.
function petports_navProfileUncached()
	local monsterType = world.monsterType(entity.id())
	local freeMover = petports_freeMover()

	local liquids = {}
	for name in pairs(self.petportsModuleLiquids or {}) do
		table.insert(liquids, tostring(name))
	end
	table.sort(liquids)

	local bounds = mcontroller.boundBox()

	return string.format("%s|f%s|b%s|l%s|d%s|a%s",
		tostring(monsterType),
		freeMover and "1" or "0",
		string.format("%.2f,%.2f",
			(bounds[3] or 0) - (bounds[1] or 0),
			(bounds[4] or 0) - (bounds[2] or 0)),
		table.concat(liquids, "+"),
		self.petportsOpenDoors and "1" or "0",
		petports_avoidLiquid() and "1" or "0")
end

-- Returns this tick's profile string, memoised per side.
function petports_navProfile()
	local now = world.time()
	local side = petports_freeMover() and "1" or "0"

	if self.petportsNavProfileAt ~= now or self.petportsNavProfileMemo == nil then
		self.petportsNavProfileAt = now
		self.petportsNavProfileMemo = {}
	end

	if self.petportsNavProfileMemo[side] == nil then
		self.petportsNavProfileMemo[side] = petports_navProfileUncached()
	end

	return self.petportsNavProfileMemo[side]
end

-- Calls a function with the survey forced to one side, restoring it afterwards.
function petports_navWithSide(freeMover, fn, ...)
	local held = self.petportsNavSurveyFree
	self.petportsNavSurveyFree = freeMover

	local results = { pcall(fn, ...) }

	self.petportsNavSurveyFree = held

	if not results[1] then error(results[2], 0) end
	return select(2, table.unpack(results))
end

-- Returns the side to survey this turn, alternating for a gravity-switchable chassis.
function petports_navSurveySide()
	if not petports_gravitySwitchable() then return petports_freeMover() end

	self.petportsNavSideFlip = not self.petportsNavSideFlip
	return self.petportsNavSideFlip == true
end


-- Returns the key for an edge between two cells.
function petports_navEdgeKey(fromKey, toKey)
	return fromKey .. ">" .. toKey
end

petports_navKeyCoordsCache = {}
-- Returns the coordinates a cell key holds, cached.
function petports_navKeyCoords(key)
	local held = petports_navKeyCoordsCache[key]
	if held ~= nil then return held[1], held[2] end
	local kx, ky = string.match(key, "^(-?%d+),(-?%d+)$")
	if kx == nil then return nil, nil end
	kx, ky = tonumber(kx), tonumber(ky)
	petports_navKeyCoordsCache[key] = { kx, ky }
	return kx, ky
end

-- Returns the world distance between two cells.
function petports_navCellSpan(fromKey, toKey)
	local fx, fy = petports_navKeyCoords(fromKey)
	local tx, ty = petports_navKeyCoords(toKey)
	if fx == nil or tx == nil then return 1 end
	local dx, dy = tx - fx, ty - fy
	return math.max(1, math.sqrt(dx * dx + dy * dy) * petports_navStride())
end

-- Returns the index property name for a profile.
function petports_navIndexProperty(profile)
	return NAV_INDEX .. ":" .. profile
end

-- Returns every profile named in the index registry.
function petports_navIndexProfiles()
	local ok, registry = pcall(world.getProperty, NAV_INDEX)
	if not ok or type(registry) ~= "table" then return {} end

	local names = {}
	for profile in pairs(type(registry.profiles) == "table" and registry.profiles or {}) do
		table.insert(names, profile)
	end
	table.sort(names)
	return names
end


-- Returns the bounds index property name for a bucket.
function petports_navBoundsIndexProperty(bucket)
	return NAV_BOUNDS .. ":" .. bucket
end

-- Returns the bounds property name for a cell in a bucket.
function petports_navBoundsCellProperty(bucket, cellKey)
	return NAV_BOUNDS .. ":" .. bucket .. ":" .. cellKey
end

-- Returns every property name the bounds family holds.
function petports_navBoundsFamilyEnumerate()
	local names = {}

	local ok, registry = pcall(world.getProperty, NAV_BOUNDS)
	if not ok or type(registry) ~= "table" then registry = {} end

	for bucket in pairs(registry) do
		local okCells, cells = pcall(world.getProperty, petports_navBoundsIndexProperty(bucket))
		if okCells and type(cells) == "table" then
			for cellKey in pairs(cells) do
				table.insert(names, petports_navBoundsCellProperty(bucket, cellKey))
			end
		end
		table.insert(names, petports_navBoundsIndexProperty(bucket))
	end

	table.insert(names, NAV_BOUNDS)
	return names
end

-- Returns a liquid level's name, or air below the fill threshold, cached.
function petports_navLiquidName(level)
	local fill = (level ~= nil) and (level[2] or 0) or 0
	if level == nil or fill < NAV_BOUNDS_FILL then return "air" end

	local id = level[1]
	self.petportsNavLiquidNames = self.petportsNavLiquidNames or {}

	if self.petportsNavLiquidNames[id] == nil then
		local names = petports_habitatLiquidNames ~= nil
			and petports_habitatLiquidNames(id) or nil
		self.petportsNavLiquidNames[id] = (type(names) == "table" and names[1])
			or tostring(id)
	end

	return self.petportsNavLiquidNames[id]
end

-- Queues a bounds cell for the next flush.
function petports_navBoundsQueue(bucket, cellKey)
	self.petportsNavBoundsMine = self.petportsNavBoundsMine or {}
	self.petportsNavBoundsMine[bucket] = self.petportsNavBoundsMine[bucket] or {}
	self.petportsNavBoundsMine[bucket][cellKey] = true
	self.petportsNavBoundsPendingCount = (self.petportsNavBoundsPendingCount or 0) + 1
end

-- Writes the queued bounds cells into their bucket indexes and the registry.
function petports_navBoundsFlush()
	petports_navGenerationCheck()
	if (self.petportsNavBoundsPendingCount or 0) == 0 then return end

	petports_navFamilyRegister(NAV_BOUNDS, petports_navBoundsFamilyEnumerate)

	local ok, registry = pcall(world.getProperty, NAV_BOUNDS)
	if not ok or type(registry) ~= "table" then registry = {} end
	local registryChanged = false

	for bucket, cells in pairs(self.petportsNavBoundsMine or {}) do
		local okIndex, index = pcall(world.getProperty, petports_navBoundsIndexProperty(bucket))
		if not okIndex or type(index) ~= "table" then index = {} end

		local missing = false
		for cellKey in pairs(cells) do
			if index[cellKey] ~= true then
				index[cellKey] = true
				missing = true
			end
		end

		if missing then
			pcall(world.setProperty, petports_navBoundsIndexProperty(bucket), index)
		end

		if registry[bucket] ~= true then
			registry[bucket] = true
			registryChanged = true
		end
	end

	if registryChanged then pcall(world.setProperty, NAV_BOUNDS, registry) end

	self.petportsNavBoundsPendingCount = 0
end

-- Records a cell's liquid layout as a boundary record, queues its neighbours, and contradicts edges crossing any newly denied tile.
function petports_navBoundaryNote(cx, cy)
	self.petportsNavBoundsSeen = self.petportsNavBoundsSeen or {}
	local cellKey = petports_navCellKey(cx, cy)
	local now = world.time()
	local seen = self.petportsNavBoundsSeen[cellKey]

	self.petportsNavBoundsFound = self.petportsNavBoundsFound or {}

	if seen ~= nil and (now - seen) <= NAV_ANCHOR_TTL then
		return self.petportsNavBoundsFound[cellKey] == true
	end
	self.petportsNavBoundsSeen[cellKey] = now
	self.petportsNavBoundsFound[cellKey] = false

	local baseX, baseY = petports_navCellOrigin(cx, cy)
	local media = {}
	local liquids = {}
	local distinct = 0
	local first = nil
	local same = true
	local top = nil

	for dy = 0, PETPORTS_NAV_CELL - 1 do
		for dx = 0, PETPORTS_NAV_CELL - 1 do
			local ok, level = pcall(world.liquidAt, { baseX + dx + 0.5, baseY + dy + 0.5 })
			local name = petports_navLiquidName(ok and level or nil)

			media[dx .. "," .. dy] = name

			if name ~= "air" then
				if not liquids[name] then
					liquids[name] = true
					distinct = distinct + 1
				end
				if top == nil or baseY + dy > top then top = baseY + dy end
			end

			if first == nil then first = name elseif name ~= first then same = false end
		end
	end

	if same and distinct == 1 and first ~= "air"
	   and petports_liquidNameDenied ~= nil and petports_liquidNameDenied(first) then
		self.petportsNavBoundsFlood = self.petportsNavBoundsFlood or {}
		for ndy = -1, 1 do
			for ndx = -1, 1 do
				if (ndx ~= 0 or ndy ~= 0) and petports_navInCoverage(cx + ndx, cy + ndy) then
					local nkey = petports_navCellKey(cx + ndx, cy + ndy)
					local nseen = self.petportsNavBoundsSeen[nkey]
					if nseen == nil or (now - nseen) > NAV_ANCHOR_TTL then
						table.insert(self.petportsNavBoundsFlood, { cx + ndx, cy + ndy })
					end
				end
			end
		end
		return false
	end

	if same or distinct == 0 then return false end

	self.petportsNavBoundsFound[cellKey] = true
	self.petportsNavBoundsFlood = self.petportsNavBoundsFlood or {}
	for ndy = -1, 1 do
		for ndx = -1, 1 do
			if (ndx ~= 0 or ndy ~= 0) and petports_navInCoverage(cx + ndx, cy + ndy) then
				local nkey = petports_navCellKey(cx + ndx, cy + ndy)
				local nseen = self.petportsNavBoundsSeen[nkey]
				if nseen == nil or (now - nseen) > NAV_ANCHOR_TTL then
					table.insert(self.petportsNavBoundsFlood, { cx + ndx, cy + ndy })
				end
			end
		end
	end

	local bounds = mcontroller.boundBox()
	local fit = {}

	for dx = 0, PETPORTS_NAV_CELL - 1 do
		local wetRow = nil
		for dy = 0, PETPORTS_NAV_CELL - 1 do
			if media[dx .. "," .. dy] ~= "air" then
				if wetRow == nil or baseY + dy > wetRow then wetRow = baseY + dy end
			end
		end

		if wetRow ~= nil then
			local centre = { baseX + dx + 0.5, wetRow + 1 - (bounds[2] or -0.8) }
			local region = {
				centre[1] + bounds[1], centre[2] + bounds[2],
				centre[1] + bounds[3], centre[2] + bounds[4]
			}
			local okFit, hit = pcall(world.rectTileCollision, region, NAV_SOLID_SET)
			fit[tostring(dx)] = (okFit and hit == false) and true or false
		end
	end

	local names = {}
	for name in pairs(liquids) do table.insert(names, name) end
	table.sort(names)

	local bucket = string.format("%s|b%.2f,%.2f", table.concat(names, "+"),
		(bounds[3] or 0) - (bounds[1] or 0), (bounds[4] or 0) - (bounds[2] or 0))

	local record = { m = media, top = top, fit = fit, t = now, g = petports_navGenNow() }

	local okOld, old = pcall(world.getProperty, petports_navBoundsCellProperty(bucket, cellKey))
	if okOld and type(old) == "table" then
		local unchanged = old.top == top and old.g == record.g
		for k, v in pairs(media) do
			if type(old.m) ~= "table" or old.m[k] ~= v then unchanged = false end
		end
		for k, v in pairs(fit) do
			if type(old.fit) ~= "table" or old.fit[k] ~= v then unchanged = false end
		end
		if unchanged then
			petports_navSeedBesideWall(cx, cy, media)

	local crossable = true
	for _, name in ipairs(names) do
		if petports_liquidNameDenied ~= nil and petports_liquidNameDenied(name) then crossable = false end
	end
	if crossable then
		self.petportsNavBridgeSeen = self.petportsNavBridgeSeen or {}
		local bseen = self.petportsNavBridgeSeen[cellKey]
		if bseen == nil or (now - bseen) > NAV_BRIDGE_SEEN_TTL then
			self.petportsNavBridgeSeen[cellKey] = now
			self.petportsNavBridgeQueue = self.petportsNavBridgeQueue or {}
			self.petportsNavBridgeQueue[cellKey] = { cx = cx, cy = cy, bucket = bucket, record = record }
		end
	end
			return true
		end
	end

	pcall(world.setProperty, petports_navBoundsCellProperty(bucket, cellKey), record)
	petports_navBoundsQueue(bucket, cellKey)
	petports_profCount("boundary")

	self.petportsNavBoundsLocal = self.petportsNavBoundsLocal or {}
	self.petportsNavBoundsLocal[cellKey] = { ox = baseX, oy = baseY, m = media, bucket = bucket }

	local newTiles = nil
	for offset, name in pairs(media) do
		if name ~= "air" and petports_liquidNameDenied ~= nil
		   and petports_liquidNameDenied(name) then
			local dx, dy = string.match(offset, "^(%d+),(%d+)$")
			if dx ~= nil then
				newTiles = newTiles or {}
				newTiles[(baseX + tonumber(dx)) .. "," .. (baseY + tonumber(dy))] = bucket
			end
		end
	end

	if newTiles ~= nil then
		self.petportsNavForbidden = self.petportsNavForbidden or {}
		for tile, b in pairs(newTiles) do self.petportsNavForbidden[tile] = b end
		petports_navContradictThrough(newTiles, cellKey)
	end

	petports_navSeedBesideWall(cx, cy, media)

	local crossable = true
	for _, name in ipairs(names) do
		if petports_liquidNameDenied ~= nil and petports_liquidNameDenied(name) then crossable = false end
	end
	if crossable then
		self.petportsNavBridgeSeen = self.petportsNavBridgeSeen or {}
		local bseen = self.petportsNavBridgeSeen[cellKey]
		if bseen == nil or (now - bseen) > NAV_BRIDGE_SEEN_TTL then
			self.petportsNavBridgeSeen[cellKey] = now
			self.petportsNavBridgeQueue = self.petportsNavBridgeQueue or {}
			self.petportsNavBridgeQueue[cellKey] = { cx = cx, cy = cy, bucket = bucket, record = record }
		end
	end

	if PETPORTS_NAV_VERBOSE then
		sb.logInfo("NAV boundary %s in %s: top %s, media %s, fit %s",
			cellKey, bucket, tostring(top), sb.printJson(media), sb.printJson(fit))
	end

	return true
end

-- Queues a set of newly denied tiles for the contradiction pass.
function petports_navContradictThrough(tiles, cellKey)
	self.petportsNavContradictQueue = self.petportsNavContradictQueue or {}
	table.insert(self.petportsNavContradictQueue, { tiles = tiles, cellKey = cellKey })
end

local NAV_CONTRADICT_SCAN = 300
local NAV_CONTRADICT_BUDGET_MS = 2.0

-- Drops fine edges that cross newly denied tiles, a budget at a time.
function petports_navContradictTick()
	local queue = self.petportsNavContradictQueue
	if queue == nil or #queue == 0 then return end

	local graph = self.petportsNavGraph
	if graph == nil or type(graph.fine) ~= "table" or not petports_freeMover() then
		self.petportsNavContradictQueue = nil
		return
	end

	local job = queue[1]
	local profile = petports_navProfile()

	if job.froms == nil then
		if graph.fineKeys == nil then
			graph.fineKeys = {}
			for from in pairs(graph.fine) do table.insert(graph.fineKeys, from) end
			table.sort(graph.fineKeys)
		end

		local bx, by = string.match(job.cellKey, "^(-?%d+),(-?%d+)$")
		if bx == nil then table.remove(queue, 1) return end
		bx, by = tonumber(bx), tonumber(by)

		local keys = graph.fineKeys
		local total = #keys
		local cursor = job.cursor or 0
		local reach = PETPORTS_NAV_RADIUS * 2
		job.kept = job.kept or {}

		local scanned = 0
		while cursor < total and scanned < NAV_CONTRADICT_SCAN do
			cursor = cursor + 1
			scanned = scanned + 1
			local fromKey = keys[cursor]
			local fx, fy = string.match(fromKey, "^(-?%d+),(-?%d+)$")
			if fx ~= nil and math.abs(tonumber(fx) - bx) <= reach
			   and math.abs(tonumber(fy) - by) <= reach then
				table.insert(job.kept, fromKey)
			end
		end

		job.cursor = cursor
		if cursor >= total then
			job.froms = job.kept
			job.kept = nil
			job.at = 0
		end
		return
	end

	local began = petports_navTickClock()
	local bounds = mcontroller.boundBox()
	local cache = (self.petportsNavAnchorCache or {})[profile] or {}

	-- Returns a cell's anchor from the cache only.
	local function cachedAnchor(key)
		local hit = cache[key]
		return hit ~= nil and hit.anchor or nil
	end

	while job.at < #job.froms do
		if began ~= nil and (petports_navTickClock() - began) * 1000 >= NAV_CONTRADICT_BUDGET_MS then
			return
		end

		job.at = job.at + 1
		local fromKey = job.froms[job.at]
		local tos = graph.fine[fromKey]
		local from = cachedAnchor(fromKey)

		if tos ~= nil and from ~= nil then
			for k = #tos, 1, -1 do
				local toKey = tos[k]
				local to = cachedAnchor(toKey)

				if to ~= nil then
					local length = world.magnitude(from, to)
					local steps = math.max(1, math.ceil(length / 0.5))
					local hit = nil

					for step = 0, steps do
						local t = step / steps
						hit = petports_navBoxForbidden(job.tiles, {
							from[1] + (to[1] - from[1]) * t, from[2] + (to[2] - from[2]) * t
						}, bounds)
						if hit ~= nil then break end
					end

					if hit ~= nil then
						petports_navContradict(profile, fromKey, toKey)
						job.dropped = (job.dropped or 0) + 1
					end
				end
			end
		end
	end

	if (job.dropped or 0) > 0 then
		sb.logInfo("NAV boundary %s contradicted %s edge(s) that crossed it for %s",
			tostring(job.cellKey), sb.printJson(job.dropped), tostring(profile))
	end
	table.remove(queue, 1)
end

-- Marks the cells around a denied-liquid cell as sweep seeds.
function petports_navSeedBesideWall(cx, cy, media)
	if not petports_gravitySwitchable() and not petports_freeMover() then return end
	petports_profBegin("seedWall")

	local denied = false
	for _, name in pairs(media) do
		if name ~= "air" and petports_liquidNameDenied ~= nil
		   and petports_liquidNameDenied(name) then denied = true end
	end
	if not denied then petports_profEnd("seedWall") return end

	self.petportsNavSeeds = self.petportsNavSeeds or {}

	for ndy = -1, 1 do
		for ndx = -1, 1 do
			local nx, ny = cx + ndx, cy + ndy
			if petports_navInCoverage(nx, ny) then
				self.petportsNavSeeds[petports_navCellKey(nx, ny)] = world.time()
			end
		end
	end
	petports_profEnd("seedWall")
end

local NAV_FLOOD_PER_TICK = 6

NAV_BRIDGE_SEEN_TTL = 300.0

-- Notes a few queued neighbour cells as boundaries each tick.
function petports_navBoundsFloodTick()
	local queue = self.petportsNavBoundsFlood
	if queue == nil or #queue == 0 then return end

	local done = 0
	while #queue > 0 and done < NAV_FLOOD_PER_TICK do
		local cell = table.remove(queue)
		done = done + 1
		petports_navBoundaryNote(cell[1], cell[2])
	end
end

-- Logs and returns everything known about the boundary cell at a position.
function petports_navBoundsProbe(x, y)
	local cx, cy = petports_navCell({ x, y })
	local cellKey = petports_navCellKey(cx, cy)
	local baseX, baseY = petports_navCellOrigin(cx, cy)
	local out = { cell = cellKey, tiles = {}, store = {} }

	for dy = 0, PETPORTS_NAV_CELL - 1 do
		for dx = 0, PETPORTS_NAV_CELL - 1 do
			local ok, level = pcall(world.liquidAt, { baseX + dx + 0.5, baseY + dy + 0.5 })
			local id = (ok and level ~= nil) and level[1] or nil
			local fill = (ok and level ~= nil) and (level[2] or 0) or 0
			out.tiles[(baseX + dx) .. "," .. (baseY + dy)] = {
				id = id,
				fill = fill,
				name = petports_navLiquidName(ok and level or nil),
				denied = id ~= nil and petports_liquidDenied ~= nil
					and petports_liquidDenied(id) or false
			}
		end
	end

	out.indexed = {}
	local okReg, registry = pcall(world.getProperty, NAV_BOUNDS)
	if okReg and type(registry) == "table" then
		for bucket in pairs(registry) do
			local okRec, record = pcall(world.getProperty, petports_navBoundsCellProperty(bucket, cellKey))
			if okRec and type(record) == "table" then out.store[bucket] = record end

			local okIdx, index = pcall(world.getProperty, petports_navBoundsIndexProperty(bucket))
			out.indexed[bucket] = okIdx and type(index) == "table" and index[cellKey] == true or false
		end
	end
	out.registry = okReg and type(registry) == "table" and registry or "none"

	local walls = petports_navForbiddenCells()
	out.walls = {}
	for dy = 0, PETPORTS_NAV_CELL - 1 do
		for dx = 0, PETPORTS_NAV_CELL - 1 do
			local tile = (baseX + dx) .. "," .. (baseY + dy)
			out.walls[tile] = walls[tile] or false
		end
	end

	out.drawn = false
	for _, entry in ipairs(self.petportsNavBoundsDraw or {}) do
		if entry.ox == baseX and entry.oy == baseY then out.drawn = entry.bucket end
	end
	out.drawAgo = self.petportsNavBoundsDrawAt ~= nil
		and (world.time() - self.petportsNavBoundsDrawAt) or nil
	out.drawRange = math.abs(baseX - mcontroller.position()[1]) <= NAV_DRAW_RANGE
		and math.abs(baseY - mcontroller.position()[2]) <= NAV_DRAW_RANGE

	out.seenAgo = self.petportsNavBoundsSeen ~= nil and self.petportsNavBoundsSeen[cellKey] ~= nil
		and (world.time() - self.petportsNavBoundsSeen[cellKey]) or nil
	out.found = self.petportsNavBoundsFound ~= nil and self.petportsNavBoundsFound[cellKey] or nil
	out.inCoverage = petports_navInCoverage(cx, cy)

	sb.logInfo("NAV bounds probe %s", sb.printJson(out))
	return out
end

-- Returns the number of stored boundary cells in each bucket.
function petports_navBoundsStats()
	local ok, registry = pcall(world.getProperty, NAV_BOUNDS)
	if not ok or type(registry) ~= "table" then return {} end

	local out = {}
	for bucket in pairs(registry) do
		local okCells, cells = pcall(world.getProperty, petports_navBoundsIndexProperty(bucket))
		local count = 0
		if okCells and type(cells) == "table" then
			for _ in pairs(cells) do count = count + 1 end
		end
		out[bucket] = count
	end
	return out
end

-- Returns the tiles holding denied liquid, read out of the bounds store, cached.
function petports_navForbiddenCells()
	local now = world.time()

	if self.petportsNavForbidden ~= nil
	   and (now - (self.petportsNavForbiddenAt or 0)) <= NAV_ANCHOR_TTL then
		return self.petportsNavForbidden
	end

	local cells = {}
	local buckets = 0

	local ok, registry = pcall(world.getProperty, NAV_BOUNDS)
	if ok and type(registry) == "table" then
		for bucket in pairs(registry) do
			local liquids = string.match(bucket, "^([^|]*)|") or ""
			local denied = false

			for name in string.gmatch(liquids, "[^+]+") do
				if petports_liquidNameDenied ~= nil and petports_liquidNameDenied(name) then
					denied = true
				end
			end

			if denied then
				local okIndex, index = pcall(world.getProperty, petports_navBoundsIndexProperty(bucket))
				if okIndex and type(index) == "table" then
					buckets = buckets + 1
					for cellKey in pairs(index) do
						local okRec, record = pcall(world.getProperty,
							petports_navBoundsCellProperty(bucket, cellKey))
						local bx, by = string.match(cellKey, "^(-?%d+),(-?%d+)$")

						if okRec and type(record) == "table" and type(record.m) == "table"
						   and record.g == petports_navGenNow() and bx ~= nil then
							local baseX, baseY = petports_navCellOrigin(tonumber(bx), tonumber(by))

							for offset, name in pairs(record.m) do
								local dx, dy = string.match(offset, "^(%d+),(%d+)$")
								if dx ~= nil and name ~= "air"
								   and petports_liquidNameDenied(name) then
									cells[(baseX + tonumber(dx)) .. "," .. (baseY + tonumber(dy))]
										= bucket
								end
							end
						end
					end
				end
			end
		end
	end

	self.petportsNavForbidden = cells
	self.petportsNavForbiddenAt = now

	if buckets > 0 and self.petportsNavForbiddenNoted ~= buckets then
		self.petportsNavForbiddenNoted = buckets
		local count = 0
		for _ in pairs(cells) do count = count + 1 end
		sb.logInfo("NAV %s denied-liquid tile(s) from %s bucket(s) are walls for %s",
			sb.printJson(count), sb.printJson(buckets), tostring(petports_navProfile()))
	end

	return cells
end

-- Returns the first forbidden tile a body covers at a position.
function petports_navBoxForbidden(forbidden, position, bounds)
	local x0 = math.floor(position[1] + bounds[1] + 0.01)
	local x1 = math.floor(position[1] + bounds[3] - 0.01)
	local y0 = math.floor(position[2] + bounds[2] + 0.01)
	local y1 = math.floor(position[2] + bounds[4] - 0.01)

	for ty = y0, y1 do
		for tx = x0, x1 do
			local key = tx .. "," .. ty
			if forbidden[key] ~= nil then return key, forbidden[key] end
		end
	end

	return nil
end

-- Returns the first forbidden tile a body crosses along a line.
function petports_navSegmentForbidden(from, to)
	local forbidden = petports_navForbiddenCells()
	if next(forbidden) == nil then return nil end

	local bounds = mcontroller.boundBox()
	local length = world.magnitude(from, to)
	local steps = math.max(1, math.ceil(length / 0.5))

	for i = 0, steps do
		local t = i / steps
		local key, bucket = petports_navBoxForbidden(forbidden, {
			from[1] + (to[1] - from[1]) * t, from[2] + (to[2] - from[2]) * t
		}, bounds)
		if key ~= nil then return key, bucket end
	end

	return nil
end

-- Returns the first forbidden tile a path's nodes sit on, ignoring spans the unit can hop.
function petports_navPathForbidden(edges)
	local forbidden = petports_navForbiddenCells()
	if next(forbidden) == nil or type(edges) ~= "table" then return nil end

	local bounds = mcontroller.boundBox()

	local hopLo, hopHi = nil, nil
	local lastDry = nil

	for i, edge in ipairs(edges) do
		for _, node in ipairs({ edge.source, edge.target }) do
			if type(node) == "table" and type(node.position) == "table" then
				local key, bucket = petports_navBoxForbidden(forbidden, node.position, bounds)
				if key ~= nil and hopLo ~= nil and node.position[1] >= hopLo
				   and node.position[1] <= hopHi then
					key = nil
				end
				if key ~= nil and tostring(edge.action) == "Walk"
				   and petports_liquidHopFrom ~= nil and lastDry ~= nil then
					local dry = lastDry
					local dir = node.position[1] >= dry[1] and 1 or -1
					local okHop, landing, _, _, entry, exit, why = pcall(petports_liquidHopFrom, dry, dir)
					if okHop and landing ~= nil then
						hopLo = math.min(dry[1], landing[1])
						hopHi = math.max(dry[1], landing[1])
						if PETPORTS_NAV_VERBOSE then
							sb.logInfo("NAV probe path walks a denied span at %s -- HOPPABLE from %s "
								.. "to %s (entry %s, exit %s), not a wall",
								tostring(key), sb.printJson(dry), sb.printJson(landing),
								sb.printJson(entry), sb.printJson(exit))
						end
						key = nil
					elseif okHop then
						sb.logInfo("NAV probe path walks a denied span at %s -- not hoppable from %s: %s",
							tostring(key), sb.printJson(dry), tostring(why))
					end
				end
				if key == nil then lastDry = node.position end
				if key ~= nil then
					local actions = {}
					for j, e in ipairs(edges) do actions[j] = tostring(e.action) end
					return key, bucket, string.format("%s edge %s of %s at %s; path %s",
						tostring(edge.action), sb.printJson(i), sb.printJson(#edges),
						sb.printJson(node.position), table.concat(actions, ">"))
				end
			end
		end
	end

	return nil
end

-- Adds a profile to the index registry.
function petports_navIndexRegister(profile)
	petports_navFamilyRegister(NAV_INDEX, petports_navEdgeFamilyEnumerate)
	local ok, registry = pcall(world.getProperty, NAV_INDEX)
	if not ok or type(registry) ~= "table" then registry = {} end
	registry.profiles = registry.profiles or {}

	if registry.profiles[profile] == true then return end

	registry.profiles[profile] = true
	pcall(world.setProperty, NAV_INDEX, registry)
end

petports_navChunk = {}
petports_navChunk.TILES = 32
petports_navChunk.INDEX_PREFIX = "petports_navchunk:"
petports_navChunk.EDGES_PREFIX = "petports_navchunkedges:"
petports_navChunk.EDGE_FORMAT = 5

-- Returns the number of cells along a chunk's side.
function petports_navChunk.side()
	return math.max(1, math.floor(petports_navChunk.TILES / petports_navStride()))
end

-- Returns the chunk key holding a cell, and the cell's id inside that chunk.
function petports_navChunk.of(cellKey)
	local cx, cy = petports_navKeyCoords(cellKey)
	if cx == nil then return nil, nil end
	local side = petports_navChunk.side()
	local chx, chy = math.floor(cx / side), math.floor(cy / side)
	return tostring(chx) .. "," .. tostring(chy),
		(cx - chx * side) + (cy - chy * side) * side
end

-- Returns the cell key for an id inside a chunk.
function petports_navChunk.cellKey(chunkKey, id)
	local chx, chy = string.match(chunkKey, "^(-?%d+),(-?%d+)$")
	if chx == nil then return nil end
	local side = petports_navChunk.side()
	id = math.floor(tonumber(id) or 0)
	return tostring(tonumber(chx) * side + (id % side)) .. ","
		.. tostring(tonumber(chy) * side + math.floor(id / side))
end

-- Returns the index property name for a chunk under a profile.
function petports_navChunk.indexProperty(profile, chunkKey)
	return petports_navChunk.INDEX_PREFIX .. profile .. ":" .. chunkKey
end

-- Returns the edges property name for a chunk under a profile.
function petports_navChunk.edgesProperty(profile, chunkKey)
	return petports_navChunk.EDGES_PREFIX .. profile .. ":" .. chunkKey
end

-- Returns a profile's chunk registry, clearing a pre-chunk store if it finds one.
function petports_navChunk.registryRead(profile)
	local ok, registry = pcall(world.getProperty, petports_navIndexProperty(profile))
	if not ok or type(registry) ~= "table" then return {} end

	if type(registry.chunks) ~= "table" then
		petports_navChunk.legacyClear(profile, registry)
		return {}
	end

	return registry.chunks
end

-- Adds a chunk to a profile's registry.
function petports_navChunk.registryAdd(profile, chunkKey)
	self.petportsNavChunkKnown = self.petportsNavChunkKnown or {}
	self.petportsNavChunkKnown[profile] = self.petportsNavChunkKnown[profile] or {}
	if self.petportsNavChunkKnown[profile][chunkKey] then return end

	local chunks = petports_navChunk.registryRead(profile)
	self.petportsNavChunkKnown[profile] = chunks
	if chunks[chunkKey] == true then return end

	chunks[chunkKey] = true
	petports_navIndexRegister(profile)
	pcall(world.setProperty, petports_navIndexProperty(profile), { _g = petports_navGenNow(), chunks = chunks })
end

-- Removes a chunk from a profile's registry.
function petports_navChunk.registryDrop(profile, chunkKey)
	local chunks = petports_navChunk.registryRead(profile)
	if chunks[chunkKey] == nil then return end
	chunks[chunkKey] = nil
	self.petportsNavChunkKnown = self.petportsNavChunkKnown or {}
	self.petportsNavChunkKnown[profile] = chunks
	pcall(world.setProperty, petports_navIndexProperty(profile), { _g = petports_navGenNow(), chunks = chunks })
end

-- Reads a chunk's swept-cell index, returning the cells, whether the read worked, and the count it recorded.
function petports_navChunk.indexDecode(profile, chunkKey)
	local ok, raw = pcall(world.getProperty, petports_navChunk.indexProperty(profile, chunkKey))
	local readOk = ok and type(raw) == "table"
	local cells = {}
	if not readOk then return cells, false, nil end

	local gen = petports_navGenNow()
	if raw._g ~= gen then return cells, true, 0 end

	local flat = raw.c
	if type(flat) == "table" then
		for i = 1, #flat - 2, 3 do
			local cellKey = petports_navChunk.cellKey(chunkKey, flat[i])
			if cellKey ~= nil then
				cells[cellKey] = { at = flat[i + 1], radius = flat[i + 2], g = gen }
			end
		end
	end

	return cells, true, tonumber(raw._n)
end

-- Packs a chunk's cells into the flat index record, and returns it with the count written.
function petports_navChunk.indexEncode(chunkKey, cells)
	local flat, n = {}, 0
	for cellKey, entry in pairs(cells) do
		if type(entry) == "table" then
			local ck, id = petports_navChunk.of(cellKey)
			if ck == chunkKey then
				flat[#flat + 1] = id
				flat[#flat + 1] = entry.at or 0
				flat[#flat + 1] = entry.radius or 0
				n = n + 1
			end
		end
	end
	return { _g = petports_navGenNow(), _n = n, c = flat }, n
end

-- Reads a chunk's edges, returning nothing when the generation or the format stride does not match.
function petports_navChunk.edgesDecode(profile, chunkKey)
	petports_profBegin("chunkGet")
	local ok, raw = pcall(world.getProperty, petports_navChunk.edgesProperty(profile, chunkKey))
	petports_profEnd("chunkGet")
	local chunk = {}
	if not ok or type(raw) ~= "table" then return chunk end

	local gen = petports_navGenNow()
	if raw._g ~= gen or type(raw.e) ~= "table" then return chunk end

	if raw._f ~= petports_navChunk.EDGE_FORMAT then
		if not self.petportsNavFormatNoted then
			self.petportsNavFormatNoted = true
			sb.logInfo("NAV edge chunk %s:%s has stride %s and this build reads %s -- run petports_navWipe()",
				tostring(profile), tostring(chunkKey), tostring(raw._f), sb.printJson(petports_navChunk.EDGE_FORMAT))
		end
		return chunk
	end

	petports_profBegin("chunkDecode")

	local stride = petports_navStride()
	local extras = type(raw.x) == "table" and raw.x or nil
	for id, flat in pairs(raw.e) do
		local cellKey = petports_navChunk.cellKey(chunkKey, id)
		if cellKey ~= nil and type(flat) == "table" then
			local cx, cy = petports_navKeyCoords(cellKey)
			local edges = {}
			for i = 1, #flat - 4, 5 do
				local dx, dy = flat[i], flat[i + 1]
				local toKey = tostring(cx + dx) .. "," .. tostring(cy + dy)
				local entry = { r = (flat[i + 2] == 1), t = flat[i + 3], g = gen,
					d = flat[i + 4] or math.max(1, math.floor(math.sqrt(dx * dx + dy * dy) * stride + 0.5)) }
				local x = extras ~= nil and extras[tostring(id) .. ":" .. tostring(dx) .. "," .. tostring(dy)] or nil
				if type(x) == "table" then
					entry.k, entry.board, entry.float, entry.hole = x.k, x.b, x.f, x.h
				end
				edges[toKey] = entry
			end
			chunk[cellKey] = edges
		end
	end
	petports_profEnd("chunkDecode")

	return chunk
end

-- Packs a chunk's edges into the flat record, and returns it with the edge count.
function petports_navChunk.edgesEncode(chunk)
	local e, n = {}, 0
	local x = nil
	for cellKey, edges in pairs(chunk) do
		local _, id = petports_navChunk.of(cellKey)
		local cx, cy = petports_navKeyCoords(cellKey)
		if id ~= nil and type(edges) == "table" and next(edges) ~= nil then
			local flat = {}
			for toKey, entry in pairs(edges) do
				local tx, ty = petports_navKeyCoords(toKey)
				if tx ~= nil and type(entry) == "table" then
					flat[#flat + 1] = tx - cx
					flat[#flat + 1] = ty - cy
					flat[#flat + 1] = entry.r == true and 1 or 0
					flat[#flat + 1] = math.floor(entry.t or 0)
					flat[#flat + 1] = math.max(1, math.floor((entry.d or petports_navCellSpan(cellKey, toKey)) + 0.5))
					n = n + 1
					if entry.k ~= nil then
						x = x or {}
						x[tostring(id) .. ":" .. tostring(tx - cx) .. "," .. tostring(ty - cy)] =
							{ k = entry.k, b = entry.board, f = entry.float, h = entry.hole }
					end
				end
			end
			if #flat > 0 then e[tostring(id)] = flat end
		end
	end
	return { _g = petports_navGenNow(), _f = petports_navChunk.EDGE_FORMAT, e = e, x = x }, n
end


-- Holds an index entry in this unit's memory of the chunk.
function petports_navIndexRemember(profile, cellKey, entry)
	local chunkKey = petports_navChunk.of(cellKey)
	if chunkKey == nil then return end
	self.petportsNavIndexSeen = self.petportsNavIndexSeen or {}
	local byProfile = self.petportsNavIndexSeen[profile] or {}
	self.petportsNavIndexSeen[profile] = byProfile
	byProfile[chunkKey] = byProfile[chunkKey] or {}
	byProfile[chunkKey][cellKey] = entry
end

-- Drops a cell from this unit's memory of its chunk.
function petports_navIndexForgetSeen(profile, cellKey)
	local chunkKey = petports_navChunk.of(cellKey)
	local seen = self.petportsNavIndexSeen and self.petportsNavIndexSeen[profile]
	if chunkKey ~= nil and seen ~= nil and seen[chunkKey] ~= nil then seen[chunkKey][cellKey] = nil end
end

local NAV_INDEX_SHORT_TRIES = 12

-- Reads a chunk's index, restores cells the read lost from memory, and flags a read that came back short.
function petports_navChunk.indexRead(profile, chunkKey)
	local cells, readOk, expected = petports_navChunk.indexDecode(profile, chunkKey)
	local raw = 0
	for _ in pairs(cells) do raw = raw + 1 end

	local seen = self.petportsNavIndexSeen and self.petportsNavIndexSeen[profile]
	seen = seen ~= nil and seen[chunkKey] or nil
	local restored = 0
	local gen = petports_navGenNow()
	if type(seen) == "table" then
		for cellKey, entry in pairs(seen) do
			if cells[cellKey] == nil and type(entry) == "table" and entry.g == gen then
				cells[cellKey] = entry
				restored = restored + 1
			end
		end
	end
	for cellKey, entry in pairs(cells) do petports_navIndexRemember(profile, cellKey, entry) end

	local slot = profile .. ":" .. chunkKey
	self.petportsNavIndexLastRaw = self.petportsNavIndexLastRaw or {}
	self.petportsNavIndexShort = self.petportsNavIndexShort or {}
	local last = self.petportsNavIndexLastRaw[slot]
	local short = (expected ~= nil and raw < expected * 0.9)
		or (last ~= nil and (not readOk or raw < last * 0.9))
	self.petportsNavIndexShort[slot] = short
	if short then
		sb.logInfo("NAV INDEX SHRANK for %s chunk %s: property read %s cell(s) (ok %s), it recorded %s at its last "
			.. "write, %s last read here; %s restored from this unit's memory -- this read will NOT be written back",
			profile, chunkKey, sb.printJson(raw), tostring(readOk), tostring(expected), tostring(last),
			sb.printJson(restored))
	end
	if readOk then self.petportsNavIndexLastRaw[slot] = raw end

	return cells
end

-- Returns every indexed cell for a profile across its chunks, with the pending writes applied.
function petports_navIndexProfileRead(profile)
	local cells = {}
	local chunks = petports_navChunk.registryRead(profile)
	self.petportsNavChunkKnown = self.petportsNavChunkKnown or {}
	self.petportsNavChunkKnown[profile] = chunks

	local n = 0
	for chunkKey in pairs(chunks) do
		n = n + 1
		for cellKey, entry in pairs(petports_navChunk.indexRead(profile, chunkKey)) do
			cells[cellKey] = entry
		end
	end
	petports_profCount("indexChunkReads", n)

	local pending = self.petportsNavIndexPending
	if type(pending) == "table" and type(pending[profile]) == "table" then
		for cellKey, entry in pairs(pending[profile]) do
			cells[cellKey] = entry
		end
	end

	return cells
end

local NAV_INDEX_READ_INTERVAL = 10.0

-- Returns the index as a table that reads each profile on first access, memoised.
function petports_navIndexRead()
	local now = world.time()

	if self.petportsNavIndexMemo ~= nil
	   and (now - (self.petportsNavIndexMemoAt or -1e9)) < NAV_INDEX_READ_INTERVAL then
		return self.petportsNavIndexMemo
	end

	local index = setmetatable({}, {
		-- Reads and stores a profile's cells the first time it is asked for.
		__index = function(t, profile)
			if type(profile) ~= "string" then return nil end
			local cells = petports_navIndexProfileRead(profile)
			rawset(t, profile, cells)
			return cells
		end
	})

	self.petportsNavIndexMemo = index
	self.petportsNavIndexMemoAt = now

	return index
end

-- Queues an index entry for the next flush and applies it to the memos.
function petports_navIndexQueue(profile, cellKey, entry)
	self.petportsNavIndexPending = self.petportsNavIndexPending or {}
	self.petportsNavIndexPending[profile] = self.petportsNavIndexPending[profile] or {}
	self.petportsNavIndexPending[profile][cellKey] = entry
	self.petportsNavIndexPendingCount = (self.petportsNavIndexPendingCount or 0) + 1

	local memo = self.petportsNavIndexMemo
	if memo ~= nil and rawget(memo, profile) ~= nil then
		rawget(memo, profile)[cellKey] = entry
	end

	local chunkKey = petports_navChunk.of(cellKey)
	if chunkKey ~= nil then
		self.petportsNavIndexMine = self.petportsNavIndexMine or {}
		local mine = self.petportsNavIndexMine[profile] or {}
		self.petportsNavIndexMine[profile] = mine
		mine[chunkKey] = mine[chunkKey] or {}
		mine[chunkKey][cellKey] = entry
	end
	petports_navIndexRemember(profile, cellKey, entry)
end

-- Merges updates into a chunk's index and writes it, holding the write while recent reads came back short.
function petports_navChunk.indexApply(profile, chunkKey, updates, force)
	local cells = petports_navChunk.indexRead(profile, chunkKey)
	local slot = profile .. ":" .. chunkKey

	self.petportsNavIndexShortTries = self.petportsNavIndexShortTries or {}
	if self.petportsNavIndexShort and self.petportsNavIndexShort[slot] and not force then
		local tries = (self.petportsNavIndexShortTries[slot] or 0) + 1
		self.petportsNavIndexShortTries[slot] = tries
		if tries <= NAV_INDEX_SHORT_TRIES then
			sb.logInfo("NAV index write for %s chunk %s HELD: read was short (try %s of %s)",
				profile, chunkKey, sb.printJson(tries), sb.printJson(NAV_INDEX_SHORT_TRIES))
			return false
		end
		sb.logInfo("NAV index write for %s chunk %s: read short %s times running, writing anyway",
			profile, chunkKey, sb.printJson(tries))
	else
		self.petportsNavIndexShortTries[slot] = 0
	end

	local mine = self.petportsNavIndexMine and self.petportsNavIndexMine[profile]
	for cellKey, entry in pairs(mine ~= nil and mine[chunkKey] or {}) do
		if cells[cellKey] == nil then cells[cellKey] = entry end
	end

	for cellKey, entry in pairs(updates) do
		if entry == false then cells[cellKey] = nil else cells[cellKey] = entry end
	end

	local encoded, wrote = petports_navChunk.indexEncode(chunkKey, cells)
	if wrote == 0 then
		pcall(world.setProperty, petports_navChunk.indexProperty(profile, chunkKey), nil)
		petports_navChunk.registryDrop(profile, chunkKey)
	else
		petports_navChunk.registryAdd(profile, chunkKey)
		local okSet, err = pcall(world.setProperty, petports_navChunk.indexProperty(profile, chunkKey), encoded)
		if not okSet then
			sb.logInfo("NAV INDEX WRITE FAILED for %s chunk %s (%s cells): %s", profile,
				chunkKey, sb.printJson(wrote), tostring(err))
		end
	end
	self.petportsNavIndexLastRaw[slot] = wrote > 0 and wrote or nil

	return true
end

local NAV_INDEX_FLUSH_INTERVAL = 30.0
local NAV_INDEX_FLUSH_BACKLOG = 200

-- Writes the queued index entries chunk by chunk once the interval or the backlog is reached.
function petports_navIndexFlush()
	petports_navGenerationCheck()
	if (self.petportsNavIndexPendingCount or 0) == 0 then return end

	local now = world.time()
	if (now - (self.petportsNavIndexFlushedAt or -1e9)) < NAV_INDEX_FLUSH_INTERVAL
	   and (self.petportsNavIndexPendingCount or 0) < NAV_INDEX_FLUSH_BACKLOG then
		return
	end
	self.petportsNavIndexFlushedAt = now

	local pending = self.petportsNavIndexPending or {}
	local held, heldCount, wroteChunks = {}, 0, 0

	for profile, entries in pairs(pending) do
		local byChunk = {}
		for cellKey, entry in pairs(entries) do
			local ck = petports_navChunk.of(cellKey)
			if ck ~= nil then
				byChunk[ck] = byChunk[ck] or {}
				byChunk[ck][cellKey] = entry
			end
		end

		for ck, updates in pairs(byChunk) do
			if petports_navChunk.indexApply(profile, ck, updates, false) then
				wroteChunks = wroteChunks + 1
			else
				held[profile] = held[profile] or {}
				for cellKey, entry in pairs(updates) do
					held[profile][cellKey] = entry
					heldCount = heldCount + 1
				end
			end
		end
	end

	if PETPORTS_NAV_VERBOSE then
		sb.logInfo("NAV index flush: %s chunk(s) written, %s entr(ies) held",
			sb.printJson(wroteChunks), sb.printJson(heldCount))
	end

	self.petportsNavIndexPending = next(held) ~= nil and held or nil
	self.petportsNavIndexPendingCount = heldCount
	self.petportsNavIndexMemo = nil
end

-- Removes cells from their chunk indexes and from every memo.
function petports_navChunk.indexDrop(profile, cellKeys)
	local byChunk = {}
	for _, cellKey in ipairs(cellKeys) do
		local ck = petports_navChunk.of(cellKey)
		if ck ~= nil then
			byChunk[ck] = byChunk[ck] or {}
			byChunk[ck][cellKey] = false
		end
		petports_navIndexForgetSeen(profile, cellKey)
		local mine = self.petportsNavIndexMine and self.petportsNavIndexMine[profile]
		if ck ~= nil and mine ~= nil and mine[ck] ~= nil then mine[ck][cellKey] = nil end
		if self.petportsNavIndexPending and self.petportsNavIndexPending[profile]
		   and self.petportsNavIndexPending[profile][cellKey] ~= nil then
			self.petportsNavIndexPending[profile][cellKey] = nil
			self.petportsNavIndexPendingCount = math.max((self.petportsNavIndexPendingCount or 1) - 1, 0)
		end
	end

	for ck, updates in pairs(byChunk) do
		petports_navChunk.indexApply(profile, ck, updates, true)
	end

	self.petportsNavIndexMemo = nil
end


-- Deletes a profile's pre-chunk per-cell shards and its index.
petports_navChunk.legacyClear = function(profile, legacy)
	local cleared = 0
	for cellKey, entry in pairs(legacy) do
		if type(entry) == "table" then
			pcall(world.setProperty, NAV_EDGES .. profile .. ":" .. cellKey, nil)
			cleared = cleared + 1
		end
	end
	pcall(world.setProperty, petports_navIndexProperty(profile), nil)
	sb.logInfo("NAV legacy store for %s cleared: %s per-cell shard(s) and its index (12b chunk migration)",
		profile, sb.printJson(cleared))
end

-- Returns every property name the edge family holds.
function petports_navEdgeFamilyEnumerate()
	local names = {}

	local ok, registry = pcall(world.getProperty, NAV_INDEX)
	if not ok or type(registry) ~= "table" then registry = {} end

	for profile in pairs(type(registry.profiles) == "table" and registry.profiles or {}) do
		local okReg, perProfile = pcall(world.getProperty, petports_navIndexProperty(profile))
		if okReg and type(perProfile) == "table" then
			if type(perProfile.chunks) == "table" then
				for chunkKey in pairs(perProfile.chunks) do
					table.insert(names, petports_navChunk.indexProperty(profile, chunkKey))
					table.insert(names, petports_navChunk.edgesProperty(profile, chunkKey))
				end
			else
				for cellKey, entry in pairs(perProfile) do
					if type(entry) == "table" then
						table.insert(names, NAV_EDGES .. profile .. ":" .. cellKey)
					end
				end
			end
		end
		table.insert(names, petports_navIndexProperty(profile))
	end

	table.insert(names, NAV_INDEX)
	return names
end

-- Returns the decoded-chunk cache, emptying it once its time to live passes.
function petports_navChunk.cache()
	self.petportsNavCellCache = self.petportsNavCellCache or {}
	self.petportsNavCacheAt = self.petportsNavCacheAt or world.time()

	if (world.time() - self.petportsNavCacheAt) > NAV_CACHE_TTL then
		self.petportsNavCellCache = {}
		self.petportsNavCacheAt = world.time()
		self.petportsNavVersion = (self.petportsNavVersion or 0) + 1
	end

	return self.petportsNavCellCache
end

-- Returns a chunk's edges, cached.
function petports_navChunk.edgesRead(profile, chunkKey)
	local cache = petports_navChunk.cache()
	local key = petports_navChunk.edgesProperty(profile, chunkKey)
	local held = cache[key]
	if held ~= nil then return held end

	held = petports_navChunk.edgesDecode(profile, chunkKey)
	cache[key] = held
	petports_profCount("edgeChunkReads")
	return held
end

-- Returns a cell's outgoing edges from its chunk.
function petports_navCellRead(profile, cellKey)
	local chunkKey = petports_navChunk.of(cellKey)
	if chunkKey == nil then return {} end

	local chunk = petports_navChunk.edgesRead(profile, chunkKey)
	local edges = chunk[cellKey]
	if edges == nil then
		edges = {}
		chunk[cellKey] = edges
	end
	return edges
end

-- Merges or replaces cells in a chunk's edges, writes it, and returns the edge count.
function petports_navChunk.edgesApply(profile, chunkKey, updates, replace)
	local chunk = petports_navChunk.edgesDecode(profile, chunkKey)

	for cellKey, edges in pairs(updates) do
		if replace then
			chunk[cellKey] = edges
		else
			local stored = chunk[cellKey] or {}
			local merged = {}
			for to, entry in pairs(stored) do merged[to] = entry end
			for to, entry in pairs(edges) do merged[to] = entry end
			chunk[cellKey] = merged
		end
	end

	petports_profBegin("chunkEncode")
	local encoded, n = petports_navChunk.edgesEncode(chunk)
	petports_profEnd("chunkEncode")
	petports_profBegin("chunkSet")
	if n == 0 then
		pcall(world.setProperty, petports_navChunk.edgesProperty(profile, chunkKey), nil)
	else
		pcall(world.setProperty, petports_navChunk.edgesProperty(profile, chunkKey), encoded)
	end
	petports_profEnd("chunkSet")
	petports_profCount("chunkEdges", n)

	petports_navChunk.cache()[petports_navChunk.edgesProperty(profile, chunkKey)] = chunk

	self.petportsNavVersion = (self.petportsNavVersion or 0) + 1

	if self.petportsNavGraph ~= nil then
		self.petportsNavGraph.version = self.petportsNavVersion
	end

	return n
end

-- Replaces one cell's outgoing edges in its chunk.
function petports_navCellWrite(profile, cellKey, edges)
	local chunkKey = petports_navChunk.of(cellKey)
	if chunkKey == nil then return end
	petports_navChunk.edgesApply(profile, chunkKey, { [cellKey] = edges }, true)
end


local NAV_FLUSH_EDGES = 25
local NAV_FLUSH_INTERVAL = 5.0

-- Returns a profile's pending edge writes.
function petports_navPendingFor(profile)
	local pending = self.petportsNavPending
	if type(pending) ~= "table" then return nil end
	return pending[profile]
end

-- Writes the queued bounds, index and edge changes to the world properties.
function petports_navFlush()
	petports_profBegin("flushBounds")
	petports_navBoundsFlush()
	petports_profEnd("flushBounds")
	petports_profBegin("flushIndex")
	petports_navIndexFlush()
	petports_profEnd("flushIndex")
	petports_profBegin("flushEdges")

	local pending = self.petportsNavPending

	if type(pending) ~= "table" or next(pending) == nil then
		return 0
	end

	local written, shards = 0, 0

	for profile, edges in pairs(pending) do
		local byChunk = {}

		for key, entry in pairs(edges) do
			local from, to = string.match(key, "^(.-)>(.*)$")

			if from ~= nil then
				local ck = petports_navChunk.of(from)
				if ck ~= nil then
					byChunk[ck] = byChunk[ck] or {}
					byChunk[ck][from] = byChunk[ck][from] or {}
					byChunk[ck][from][to] = entry
					written = written + 1
				end
			end
		end

		for ck, updates in pairs(byChunk) do
			petports_navChunk.edgesApply(profile, ck, updates, false)
			shards = shards + 1
		end
	end

	self.petportsNavPending = {}
	self.petportsNavPendingCount = 0
	self.petportsNavFlushAt = world.time() + NAV_FLUSH_INTERVAL
	petports_profEnd("flushEdges")

	petports_profCount("edgesFlushed", written)

	sb.logInfo("NAV flushed %s edge(s) across %s chunk(s)",
		sb.printJson(written), sb.printJson(shards))

	return written
end

-- Returns an edge's stored verdict and its age.
function petports_navKnown(profile, fromKey, toKey)
	local key = petports_navEdgeKey(fromKey, toKey)

	local pending = petports_navPendingFor(profile)
	local entry = pending ~= nil and pending[key] or nil

	if type(entry) ~= "table" then
		entry = petports_navCellRead(profile, fromKey)[toKey]
	end

	if type(entry) ~= "table" then return nil end

	return entry.r, world.time() - (entry.t or 0)
end

-- Drops a cell's outgoing edges and its index entry, and returns how many edges went.
function petports_navForget(profile, cellKey)
	local pending = petports_navPendingFor(profile)

	if pending ~= nil then
		for key in pairs(pending) do
			local from, to = string.match(key, "^(.-)>(.*)$")
			if from == cellKey or to == cellKey then
				pending[key] = nil
				self.petportsNavPendingCount =
					math.max((self.petportsNavPendingCount or 1) - 1, 0)
			end
		end
	end

	local dropped = 0

	for _ in pairs(petports_navCellRead(profile, cellKey)) do
		dropped = dropped + 1
	end

	local index = petports_navIndexRead()

	if type(index[profile]) == "table" and index[profile][cellKey] ~= nil then
		index[profile][cellKey] = nil
		petports_navChunk.indexDrop(profile, { cellKey })
	end

	if dropped > 0 or index[profile] ~= nil then
		sb.logInfo("NAV cell %s SEALED for %s -- dropped %s outgoing edge(s)",
			tostring(cellKey), tostring(profile), sb.printJson(dropped))

		petports_navCellWrite(profile, cellKey, {})
	end

	return dropped
end

-- Records an edge verdict, updates the live graph, and flushes once the backlog or the interval is reached.
function petports_navLearn(profile, fromKey, toKey, reachable, travelled, extra)
	self.petportsNavPending = self.petportsNavPending or {}
	self.petportsNavPending[profile] = self.petportsNavPending[profile] or {}

	local key = petports_navEdgeKey(fromKey, toKey)

	local previous = self.petportsNavPending[profile][key]

	if type(previous) ~= "table" then
		previous = petports_navCellRead(profile, fromKey)[toKey]
	end

	if type(previous) == "table" and previous.r ~= reachable then
		sb.logInfo("NAV edge %s CONTRADICTED for %s: was %s, now %s",
			key, tostring(profile), tostring(previous.r), tostring(reachable))
	end

	local length = math.max(1, math.floor((travelled or petports_navCellSpan(fromKey, toKey)) + 0.5))
	local entry = { r = reachable, t = world.time(), g = petports_navGenNow(), d = length }
	for k, v in pairs(extra or {}) do entry[k] = v end
	self.petportsNavPending[profile][key] = entry

	if reachable == true and profile == petports_navProfile() then
		local cells = petports_navIndexRead()[profile]
		if not (type(cells) == "table" and type(cells[toKey]) == "table") then
			self.petportsNavFrontier = self.petportsNavFrontier or {}
			local side = petports_freeMover() and "1" or "0"
			self.petportsNavFrontier[side] = self.petportsNavFrontier[side] or {}
			if self.petportsNavFrontier[side][toKey] == nil then
				self.petportsNavFrontier[side][toKey] = world.time()
			end
		end
	end

	local graph = self.petportsNavGraph

	if reachable == false and graph ~= nil and graph.profile == profile
	   and graph.fine[fromKey] ~= nil then
		for i = #graph.fine[fromKey], 1, -1 do
			if graph.fine[fromKey][i] == toKey then
				table.remove(graph.fine[fromKey], i)
			end
		end
		if graph.len ~= nil and graph.len[fromKey] ~= nil then
			graph.len[fromKey][toKey] = nil
		end
	end

	if reachable == true then
		if graph ~= nil and graph.profile == profile then
			if graph.fine[fromKey] == nil then
				graph.fine[fromKey] = {}

				if graph.blocks ~= nil then
					local fx, fy = string.match(fromKey, "^(-?%d+),(-?%d+)$")
					if fx ~= nil then
						local key = math.floor(tonumber(fx) / NAV_BLOCK_CELLS) .. ","
							.. math.floor(tonumber(fy) / NAV_BLOCK_CELLS)
						if graph.blocks.map[key] == nil then
							graph.blocks.map[key] = {}
							graph.blocks.count = graph.blocks.count + 1
						end
						table.insert(graph.blocks.map[key], fromKey)
					end
				end
			end

			local present = false
			for _, to in ipairs(graph.fine[fromKey]) do
				if to == toKey then present = true break end
			end

			graph.len = graph.len or {}
			graph.len[fromKey] = graph.len[fromKey] or {}
			graph.len[fromKey][toKey] = length

			if not present then
				table.insert(graph.fine[fromKey], toKey)

				for tiles, bucket in pairs(graph.coarse) do
					local a = petports_navBlockKey(fromKey, tiles)
					local b = petports_navBlockKey(toKey, tiles)

					if a ~= nil and b ~= nil and a ~= b then
						bucket[a] = bucket[a] or {}
						bucket[a][b] = true
					end
				end
			end
		end
	end

	self.petportsNavPendingCount = (self.petportsNavPendingCount or 0) + 1
	self.petportsNavFlushAt = self.petportsNavFlushAt
		or (world.time() + NAV_FLUSH_INTERVAL)

	if self.petportsNavPendingCount >= NAV_FLUSH_EDGES
	   or world.time() >= self.petportsNavFlushAt then
		petports_navFlush()
	end
end

-- Flushes the index once the edge flush time has arrived.
function petports_navIndexTick()
	if (self.petportsNavIndexPendingCount or 0) > 0
	   and self.petportsNavFlushAt ~= nil
	   and world.time() >= self.petportsNavFlushAt then
		petports_navIndexFlush()
		self.petportsNavFlushAt = nil
	end
end

-- Records an edge as unreachable, and its reverse too for free movers.
function petports_navContradict(profile, fromKey, toKey)
	petports_navLearn(profile, fromKey, toKey, false)

	if petports_freeMover() then
		petports_navLearn(profile, toKey, fromKey, false)
	end
end

local NAV_VERIFY_SLOT = 999

-- Spins the probe to completion for one edge and returns the verdict and the spin count.
function petports_navVerify(fromKey, toKey)
	local fx, fy = string.match(fromKey, "^(-?%d+),(-?%d+)$")
	local tx, ty = string.match(toKey, "^(-?%d+),(-?%d+)$")
	if fx == nil or tx == nil then return nil, 0 end

	local verdict, spins = "searching", 0

	while verdict == "searching" and spins < 500 do
		verdict = petports_navProbeStep(
			{ tonumber(fx), tonumber(fy) }, { tonumber(tx), tonumber(ty) },
			300, NAV_VERIFY_SLOT)
		spins = spins + 1
	end

	if self.petportsNavProbes ~= nil then
		self.petportsNavProbes[NAV_VERIFY_SLOT] = nil
	end

	return verdict, spins
end


-- Returns whether the body stays inside network coverage along a line.
function navSegmentInCoverage(from, to)
	local bounds = mcontroller.boundBox()
	local samples = math.max(1, math.ceil(world.magnitude(from, to) / 0.5))

	for i = 0, samples do
		local t = i / samples
		local x = from[1] + (to[1] - from[1]) * t
		local y = from[2] + (to[2] - from[2]) * t

		if not petports_navBoxInCoverage(x + bounds[1], y + bounds[2],
		                        x + bounds[3], y + bounds[4]) then
			return false
		end
	end

	return true
end

-- Runs one slice of a probe between two cells: a body sweep for free movers, otherwise A*, and records the verdict.
function petports_navProbeStep(fromCell, toCell, exploreRate, slot)
	petports_navStampOnce()

	slot = slot or 1

	local freeMover = petports_freeMover()

	local fromKey = petports_navCellKey(fromCell[1], fromCell[2])
	local toKey = petports_navCellKey(toCell[1], toCell[2])

	self.petportsNavProbes = self.petportsNavProbes or {}

	local probe = self.petportsNavProbes[slot]

	if probe == nil or probe.fromKey ~= fromKey or probe.toKey ~= toKey then
		local from, fromWhy = petports_navAnchor(fromCell[1], fromCell[2], freeMover)
		local to, toWhy = petports_navAnchor(toCell[1], toCell[2], freeMover)

		if petports_navCellSolid(fromCell[1], fromCell[2])
		   or petports_navCellSolid(toCell[1], toCell[2]) then
			sb.logInfo("NAV probe %s -> %s SKIPPED: a cell is solid", fromKey, toKey)
			self.petportsNavProbes[slot] = nil
			return nil
		end

		if from == nil or to == nil then
			sb.logInfo("NAV probe %s -> %s SKIPPED: %s",
				fromKey, toKey, tostring(from == nil and fromWhy or toWhy))

			local profile = petports_navProfile()
			if from == nil then petports_navForget(profile, fromKey) end
			if to == nil then petports_navForget(profile, toKey) end

			self.petportsNavProbes[slot] = nil
			return nil
		end

		if freeMover then
			local edges = math.ceil(world.magnitude(from, to))

			if edges > NAV_MAX_DISTANCE then
				petports_profCount("tooFar")
				self.petportsNavProbes[slot] = nil
				return nil
			end

			local wall, wallBucket = petports_navSegmentForbidden(from, to)

			if wall ~= nil then
				sb.logInfo("NAV probe %s -> %s UNREACHABLE: the body would cross tile "
					.. "%s (%s), a liquid this chassis will not enter",
					fromKey, toKey, tostring(wall), tostring(wallBucket))
				petports_profCount("wallFalse")
				petports_navLearn(petports_navProfile(), fromKey, toKey, false)
				self.petportsNavProbes[slot] = nil
				return false
			end

			local swept
			if petports_flyPathClear ~= nil then
				local okClear, verdict = pcall(petports_flyPathClear, from, to)
				swept = okClear and verdict == true
			else
				swept = petports_bodyFitsAlong(from, to) == true
			end

			if swept and navSegmentInCoverage(from, to) then
				if PETPORTS_NAV_VERBOSE then
					sb.logInfo("NAV probe %s -> %s REACHABLE by body sweep, %s edge(s)",
						fromKey, toKey, sb.printJson(edges))
				end

				petports_profCount("sweepTrue")

				petports_navLearn(petports_navProfile(), fromKey, toKey, true, edges)

				petports_navLearn(petports_navProfile(), toKey, fromKey, true, edges)
				self.petportsNavProbes[slot] = nil
				return true
			end

			local okDoor, door = false, false

			if not (okDoor and door == true) then
				if PETPORTS_NAV_VERBOSE then
					sb.logInfo("NAV probe %s -> %s UNREACHABLE by body sweep, %s edge(s)",
						fromKey, toKey, sb.printJson(edges))
				end

				petports_profCount("sweepFalse")
				self.petportsNavProbes[slot] = nil
				return false
			end
		end

		local params = mcontroller.baseParameters()
		local liveGravity = params.gravityEnabled

		if type(params.airJumpProfile) == "table"
		   and params.airJumpProfile.jumpSpeed ~= nil then
			local jumpSpeed = params.airJumpProfile.jumpSpeed
			params.airJumpProfile.jumpSpeed =
				jumpSpeed + (jumpSpeed * (status.stat("jumpModifier") or 0))
		end

		params.gravityEnabled = true

		local okStart, aStar = pcall(world.platformerPathStart, from, to, params,
			petports_navPathOptions())

		if not okStart or aStar == nil then
			sb.logInfo("NAV probe %s -> %s SKIPPED: platformerPathStart refused (%s)",
				fromKey, toKey, tostring(aStar))
			self.petportsNavProbes[slot] = nil
			return nil
		end

		if PETPORTS_NAV_VERBOSE then sb.logInfo("NAV probe START %s -> %s: %s to %s (profile %s, rate %s, maxDistance %s, gravity true, live gravity %s)",
			fromKey, toKey, sb.printJson(from), sb.printJson(to),
			tostring(petports_navProfile()), sb.printJson(exploreRate or 300),
			sb.printJson(NAV_MAX_DISTANCE), tostring(liveGravity)) end

		self.petportsNavProbes[slot] = {
			aStar = aStar,
			fromKey = fromKey,
			toKey = toKey,
			profile = petports_navProfile(),
			fromCell = { fromCell[1], fromCell[2] },
			toCell = { toCell[1], toCell[2] },
			fromAnchor = from,
			toAnchor = to,
			ticks = 0,
			started = world.time()
		}

		probe = self.petportsNavProbes[slot]
	end

	probe.ticks = probe.ticks + 1

	local result = probe.aStar:explore(exploreRate or 300)

	if result ~= true and result ~= false and probe.ticks >= NAV_PROBE_MAX_TICKS then
		sb.logInfo("NAV probe %s -> %s GAVE UP after %s tick(s) (%s node(s) explored) -- recorded as unreachable",
			fromKey, toKey, sb.printJson(probe.ticks), sb.printJson(probe.ticks * (exploreRate or 300)))
		petports_profCount("probeGaveUp")
		result = false
	end

	local edgeCount = nil
	local travelled = nil

	if result == true then
		local ok, edges = pcall(function() return probe.aStar:result() end)

		if ok and type(edges) == "table" then
			edgeCount = #edges
		else
			sb.logInfo("NAV probe %s -> %s: aStar:result() unavailable (%s)",
				fromKey, toKey, tostring(edges))
		end

		if ok and type(edges) == "table" then
			local wall, wallBucket, wallHow = petports_navPathForbidden(edges)
			if wall ~= nil then
				sb.logInfo("NAV probe %s -> %s UNREACHABLE: the path puts the body on tile "
					.. "%s (%s), a liquid this chassis will not enter -- %s",
					fromKey, toKey, tostring(wall), tostring(wallBucket), tostring(wallHow))
				petports_profCount("wallFalse")
				result = false
				edgeCount = nil
			end
		end

		if edgeCount ~= nil then
			local sum = 0
			for _, e in ipairs(edges) do
				if type(e.source) == "table" and type(e.target) == "table"
				   and type(e.source.position) == "table" and type(e.target.position) == "table" then
					sum = sum + world.magnitude(e.source.position, e.target.position)
				end
			end
			if sum > 0 then travelled = sum end
		end
	end

	if result == true or result == false then
		sb.logInfo("NAV probe %s -> %s %s after %s tick(s), %s edge(s), %s tile(s) travelled",
			fromKey, toKey,
			result and "REACHABLE" or "UNREACHABLE",
			sb.printJson(probe.ticks), tostring(edgeCount),
			travelled ~= nil and sb.printJson(math.floor(travelled * 10 + 0.5) / 10) or "-")

		if result == true then
			petports_profCount((probe.ticks or 0) <= 1 and "true1" or "trueN")
			petports_profCount("trueTicks", probe.ticks or 0)
		elseif edgeCount == nil then
			petports_profCount("false")
			petports_profCount("falseTicks", probe.ticks or 0)
		end

		petports_navLearn(probe.profile or petports_navProfile(), fromKey, toKey, result, travelled)

		self.petportsNavProbes[slot] = nil
		return result
	end

	return "searching"
end


NAV_BRIDGE_RADIUS = 8
NAV_BRIDGE_DX = 8
NAV_BRIDGE_PAIRS = 3
NAV_BRIDGE_WADE_REACH = 3.0
NAV_BRIDGE_EXIT_RATE = 300
NAV_BRIDGE_EXIT_TICKS = 40
NAV_PROBE_MAX_TICKS = 60
NAV_BRIDGE_RETRY = 30.0
NAV_BRIDGE_RETRIES = 10

-- Returns the profile string bridge edges are stored under.
function petports_navBridgeProfileRaw()
	local now = world.time()

	if self.petportsNavBridgeProfileAt ~= now or self.petportsNavBridgeProfile == nil then
		local land = petports_navWithSide(false, petports_navProfile)
		self.petportsNavBridgeProfile = (string.gsub(land, "|f0|", "|fb|", 1))
		self.petportsNavBridgeProfileAt = now
	end

	return self.petportsNavBridgeProfile
end

-- Returns the bridge profile for a gravity-switchable chassis, otherwise nil.
function petports_navBridgeProfile()
	if not petports_gravitySwitchable() then return nil end
	return petports_navBridgeProfileRaw()
end

-- Records a bridge edge with its kind and geometry, and indexes both its cells.
function petports_navBridgeLearn(fromKey, toKey, reachable, extra)
	local profile = petports_navBridgeProfileRaw()

	petports_navIndexRegister(profile)
	petports_navLearn(profile, fromKey, toKey, reachable, nil, extra)

	self.petportsNavBridgesLocal = self.petportsNavBridgesLocal or {}
	self.petportsNavBridgesLocal[petports_navEdgeKey(fromKey, toKey)] = {
		k = extra and extra.k, r = reachable,
		a = extra and (extra.board or extra.float),
		b = extra and extra.hole,
		fromKey = fromKey, toKey = toKey
	}

	local now = world.time()
	local cells = petports_navIndexRead()[profile]
	for _, cellKey in ipairs({ fromKey, toKey }) do
		local held = type(cells) == "table" and type(cells[cellKey]) == "table"
			and tonumber(cells[cellKey].radius) or 0
		petports_navIndexQueue(profile, cellKey, {
			at = now, radius = math.max(held, 1), g = petports_navGenNow()
		})
	end
	self.petportsNavFlushAt = self.petportsNavFlushAt or (now + NAV_FLUSH_INTERVAL)
end

-- Returns the indexed cells and anchors within bridge radius of a cell, on one side.
function petports_navBridgeAnchorsAround(cx, cy, freeMover)
	local out = {}
	local profile = petports_navWithSide(freeMover, petports_navProfile)
	local cells = petports_navIndexRead()[profile]

	if type(cells) ~= "table" then return out end

	for dy = -NAV_BRIDGE_RADIUS, NAV_BRIDGE_RADIUS do
		for dx = -NAV_BRIDGE_RADIUS, NAV_BRIDGE_RADIUS do
			local key = petports_navCellKey(cx + dx, cy + dy)

			if cells[key] ~= nil then
				local anchor = petports_navWithSide(freeMover, petports_navAnchor, cx + dx, cy + dy, freeMover)
				if anchor ~= nil then
					table.insert(out, { key = key, anchor = anchor })
				end
			end
		end
	end

	return out
end

-- Returns whether a line between two points clears solid tiles.
function petports_navBridgeSighted(from, to)
	local set = PETPORTS_DIVE_SOLID_SET or NAV_SOLID_SET
	local ok, hit = pcall(world.lineTileCollision, from, to, set)
	return ok and hit == false
end

-- Removes and returns one queued bridge cell, preferring one already part-way through.
function petports_navBridgeQueueTake()
	local queue = self.petportsNavBridgeQueue
	if type(queue) ~= "table" then return nil end

	for cellKey, item in pairs(queue) do
		if item.seedState ~= nil or item.inProgress then
			queue[cellKey] = nil
			return cellKey, item
		end
	end
	for cellKey, item in pairs(queue) do
		queue[cellKey] = nil
		return cellKey, item
	end

	return nil
end

-- Runs one slice of the A* probe from a floating point back onto land, and records the result.
function petports_navBridgeExitStep()
	local probe = self.petportsNavBridgeExit
	if probe == nil then return false end

	if probe.aStar == nil then
		local params = mcontroller.baseParameters()

		if type(params.airJumpProfile) == "table"
		   and params.airJumpProfile.jumpSpeed ~= nil then
			local jumpSpeed = params.airJumpProfile.jumpSpeed
			params.airJumpProfile.jumpSpeed =
				jumpSpeed + (jumpSpeed * (status.stat("jumpModifier") or 0))
		end

		params.gravityEnabled = true
		params.liquidBuoyancy = 1.0

		local ok, aStar = pcall(world.platformerPathStart, probe.from, probe.to,
			params, petports_navPathOptions())

		if not ok or aStar == nil then
			sb.logInfo("NAV bridge exit %s -> %s SKIPPED: platformerPathStart refused (%s)",
				probe.fromKey, probe.toKey, tostring(aStar))
			self.petportsNavBridgeExit = nil
			return false
		end

		probe.aStar = aStar
		probe.ticks = 0
	end

	probe.ticks = probe.ticks + 1

	local result = probe.aStar:explore(NAV_BRIDGE_EXIT_RATE)
	local edgeCount = nil

	if result == true then
		local ok, edges = pcall(function() return probe.aStar:result() end)
		if ok and type(edges) == "table" then
			edgeCount = #edges
			local wall = petports_navPathForbidden(edges)
			if wall ~= nil then result = false end
		end
	end

	if result ~= true and result ~= false and probe.ticks >= NAV_BRIDGE_EXIT_TICKS then
		result = false
	end

	if result == true or result == false then
		sb.logInfo("NAV bridge exit %s -> %s %s after %s tick(s), %s edge(s): float %s -> land %s",
			probe.fromKey, probe.toKey, result and "REACHABLE" or "UNREACHABLE",
			sb.printJson(probe.ticks), tostring(edgeCount),
			sb.printJson(probe.from), sb.printJson(probe.to))

		petports_navBridgeLearn(probe.fromKey, probe.toKey, result, { k = "exit", float = probe.from })
		petports_profCount(result and "bridgeExit" or "bridgeExitFalse")
		self.petportsNavBridgeExit = nil
		return false
	end

	return true
end

local NAV_BRIDGE_BUDGET_MS = 1.5

-- Marks the anchored cells around a boundary as survey seeds on each side, within a time budget.
function petports_navBridgeSeedSides(cx, cy, item)
	local sides
	if petports_gravitySwitchable() then sides = { false, true }
	else sides = { petports_freeMover() } end

	self.petportsNavSideSeeds = self.petportsNavSideSeeds or {}
	local now = world.time()
	local state = item.seedState
	if state == nil then
		state = { side = 1, dx = -NAV_BRIDGE_RADIUS, dy = -NAV_BRIDGE_RADIUS, seeded = 0 }
		item.seedState = state
	end

	local began = petports_navTickClock()
	while state.side <= #sides do
		local freeMover = sides[state.side]
		local key = freeMover and "1" or "0"
		self.petportsNavSideSeeds[key] = self.petportsNavSideSeeds[key] or {}
		while state.dy <= NAV_BRIDGE_RADIUS do
			while state.dx <= NAV_BRIDGE_RADIUS do
				local dx, dy = state.dx, state.dy
				state.dx = state.dx + 1
				if petports_navInCoverage(cx + dx, cy + dy)
				   and petports_navWithSide(freeMover, petports_navAnchor, cx + dx, cy + dy, freeMover) ~= nil then
					local cellKey = petports_navCellKey(cx + dx, cy + dy)
					if self.petportsNavSideSeeds[key][cellKey] == nil then
						state.seeded = state.seeded + 1
					end
					self.petportsNavSideSeeds[key][cellKey] = now
				end
				if began ~= nil then
					local clock = petports_navTickClock()
					if clock ~= nil and (clock - began) * 1000 >= NAV_BRIDGE_BUDGET_MS then
						return false, state.seeded
					end
				end
			end
			state.dx = -NAV_BRIDGE_RADIUS
			state.dy = state.dy + 1
		end
		state.dy = -NAV_BRIDGE_RADIUS
		state.side = state.side + 1
	end

	item.seedState = nil
	return true, state.seeded
end

-- Pairs the land and swim anchors around a boundary cell into dive and wade edges, and queues their exits.
function petports_navBridgeExamine(cellKey, item)
	local cx, cy, record = item.cx, item.cy, item.record
	local baseX, baseY = petports_navCellOrigin(cx, cy)
	local bounds = mcontroller.boundBox()
	local top = tonumber(record.top)

	if top == nil then return end

	if not item.seeded then
		local done, seeded = petports_navBridgeSeedSides(cx, cy, item)
		if not done then
			item.inProgress = true
			self.petportsNavBridgeQueue = self.petportsNavBridgeQueue or {}
			self.petportsNavBridgeQueue[cellKey] = item
			return
		end
		item.seeded = true
		if seeded > 0 and PETPORTS_NAV_VERBOSE then
			sb.logInfo("NAV boundary %s seeds %s survey cell(s) across its sides", cellKey, sb.printJson(seeded))
		end
	end

	if not petports_gravitySwitchable() then return end

	if item.landAnchors == nil then
		item.landAnchors = petports_navBridgeAnchorsAround(cx, cy, false)
		item.inProgress = true
		self.petportsNavBridgeQueue = self.petportsNavBridgeQueue or {}
		self.petportsNavBridgeQueue[cellKey] = item
		return
	end
	if item.swimAnchors == nil then
		item.swimAnchors = petports_navBridgeAnchorsAround(cx, cy, true)
		item.inProgress = true
		self.petportsNavBridgeQueue = self.petportsNavBridgeQueue or {}
		self.petportsNavBridgeQueue[cellKey] = item
		return
	end
	item.inProgress = nil
	local land = item.landAnchors
	local swim = item.swimAnchors
	item.landAnchors, item.swimAnchors = nil, nil
	item.seeded = nil

	if #land == 0 or #swim == 0 then
		if PETPORTS_NAV_VERBOSE then
			sb.logInfo("NAV bridge %s: nothing to pair (%s land, %s swim anchor(s) within %s)",
				cellKey, sb.printJson(#land), sb.printJson(#swim), sb.printJson(NAV_BRIDGE_RADIUS))
		end
		item.retries = (item.retries or 0) + 1
		item.seeded = nil
		if item.retries <= NAV_BRIDGE_RETRIES then
			local wait = math.min(NAV_BRIDGE_RETRY * (2 ^ (item.retries - 1)), NAV_BRIDGE_SEEN_TTL)
			self.petportsNavBridgeRetry = self.petportsNavBridgeRetry or {}
			self.petportsNavBridgeRetry[cellKey] = { at = world.time() + wait, item = item }
		end
		return
	end

	local exits = {}
	local learned = 0

	-- Returns the point a body floats at above the water's top row.
	local function floatAt(x)
		return { x, top + 1 - (bounds[2] or -0.8) }
	end

	-- Queues an exit probe from a floating point back to a land anchor, once per pair.
	local function queueExit(s, l, float)
		local key = s.key .. ">" .. l.key
		if exits[key] then return end
		exits[key] = true
		self.petportsNavBridgeExits = self.petportsNavBridgeExits or {}
		table.insert(self.petportsNavBridgeExits, {
			fromKey = s.key, toKey = l.key, from = float, to = l.anchor
		})
	end

	local dives = {}

	for dx = 0, PETPORTS_NAV_CELL - 1 do
		if type(record.fit) == "table" and record.fit[tostring(dx)] == true then
			local hole = { baseX + dx + 0.5, top + 0.5 }

			local bestS, bestSDist = nil, nil
			for _, s in ipairs(swim) do
				if s.anchor[2] < hole[2] then
					local d = world.magnitude(s.anchor, hole)
					if (bestSDist == nil or d < bestSDist)
					   and petports_bodyFitsAlong ~= nil
					   and petports_bodyFitsAlong(hole, s.anchor) then
						bestS, bestSDist = s, d
					end
				end
			end

			if bestS ~= nil then
				for _, l in ipairs(land) do
					local board = l.anchor
					local offset = math.abs(board[1] - hole[1])
					local drop = board[2] - hole[2]

					if drop > 0 and offset <= NAV_BRIDGE_DX and petports_navBridgeSighted(board, hole) then
						local aligned = offset <= (PETPORTS_DIVE_DROP_ALIGN or 0.5)
						table.insert(dives, {
							l = l, s = bestS, hole = hole,
							score = (aligned and 0 or 1000) + offset + drop * 0.1,
							aligned = aligned
						})
					end
				end
			end
		end
	end

	table.sort(dives, function(a, b) return a.score < b.score end)

	local seenPair = {}
	for i = 1, math.min(#dives, NAV_BRIDGE_PAIRS) do
		local d = dives[i]
		local pairKey = d.l.key .. ">" .. d.s.key

		if not seenPair[pairKey] then
			seenPair[pairKey] = true
			if petports_navKnown(petports_navBridgeProfileRaw(), d.l.key, d.s.key) == true then
				queueExit(d.s, d.l, floatAt(d.hole[1]))
			else
				sb.logInfo("NAV bridge DIVE %s -> %s at %s: board %s, hole %s, %s",
					d.l.key, d.s.key, cellKey, sb.printJson(d.l.anchor), sb.printJson(d.hole),
					d.aligned and "aligned" or "offset")
				petports_navBridgeLearn(d.l.key, d.s.key, true, { k = "dive", board = d.l.anchor, hole = d.hole })
				learned = learned + 1
				queueExit(d.s, d.l, floatAt(d.hole[1]))
			end
		end
	end

	for _, l in ipairs(land) do
		for _, s in ipairs(swim) do
			local pairKey = l.key .. ">" .. s.key
			if not seenPair[pairKey]
			   and l.anchor[2] >= s.anchor[2]
			   and world.magnitude(l.anchor, s.anchor) <= NAV_BRIDGE_WADE_REACH
			   and petports_bodyFitsAlong ~= nil
			   and petports_bodyFitsAlong(l.anchor, s.anchor) then
				seenPair[pairKey] = true
				if petports_navKnown(petports_navBridgeProfileRaw(), l.key, s.key) == true then
					queueExit(s, l, floatAt(s.anchor[1]))
				else
					sb.logInfo("NAV bridge WADE %s -> %s at %s: shore %s, water %s",
						l.key, s.key, cellKey, sb.printJson(l.anchor), sb.printJson(s.anchor))
					petports_navBridgeLearn(l.key, s.key, true, { k = "wade" })
					learned = learned + 1
					queueExit(s, l, floatAt(s.anchor[1]))
				end
			end
		end
	end

	if learned == 0 and PETPORTS_NAV_VERBOSE then
		sb.logInfo("NAV bridge %s: %s land and %s swim anchor(s), no pair crosses",
			cellKey, sb.printJson(#land), sb.printJson(#swim))
	end

	petports_profCount("bridgeCells")
	petports_profCount("bridgeLearned", learned)
end

-- Runs the bridge work for this tick: an exit probe, a queued exit, a retry, or one boundary cell.
function petports_navBridgeTick()
	if petports_gravitySwitchable() and petports_navBridgeExitStep() then return end

	local queued = self.petportsNavBridgeExits
	if type(queued) == "table" and #queued > 0 then
		local job = table.remove(queued, 1)
		local known = petports_navKnown(petports_navBridgeProfileRaw(), job.fromKey, job.toKey)
		if known == nil then
			self.petportsNavBridgeExit = job
		end
		return
	end

	local retry = self.petportsNavBridgeRetry
	if type(retry) == "table" then
		local now = world.time()
		for key, held in pairs(retry) do
			if now >= held.at then
				retry[key] = nil
				self.petportsNavBridgeQueue = self.petportsNavBridgeQueue or {}
				self.petportsNavBridgeQueue[key] = held.item
			end
		end
	end

	local cellKey, item = petports_navBridgeQueueTake()
	if cellKey == nil then return end

	petports_navBridgeExamine(cellKey, item)
end



-- Returns the reachable-edge adjacency for a profile, from the store and the pending writes.
function petports_navAdjacency(profile)
	local index = petports_navIndexRead()
	local cells = index[profile]
	local out = {}

	local edges = {}

	for cellKey in pairs(type(cells) == "table" and cells or {}) do
		for to, entry in pairs(petports_navCellRead(profile, cellKey)) do
			edges[cellKey .. ">" .. to] = entry
		end
	end

	for key, entry in pairs(petports_navPendingFor(profile) or {}) do
		edges[key] = entry
	end

	for key, entry in pairs(edges) do
		if type(entry) == "table" and entry.r == true then
			local from, to = string.match(key, "^(.-)>(.*)$")

			if from ~= nil and to ~= nil then
				out[from] = out[from] or {}
				table.insert(out[from], to)
			end
		end
	end

	return out
end

local NAV_LEVELS = { 4, 8, 16, 32 }

-- Returns the key of the block a cell falls in at a tile size.
function petports_navBlockKey(cellKey, tiles)
	local cx, cy = string.match(cellKey, "^(-?%d+),(-?%d+)$")
	if cx == nil then return nil end

	local divisor = math.max(1, tiles / petports_navStride())

	return tostring(math.floor(tonumber(cx) / divisor))
		.. "," .. tostring(math.floor(tonumber(cy) / divisor))
end

local NAV_BUILD_CHUNK = 12

local NAV_BUILD_BUDGET_MS = 3.0
local NAV_GRAPH_MIN_AGE = 30.0

-- Returns whether a build step has used its millisecond budget.
function petports_navBuildOverBudget(began)
	if began == nil then return false end
	local now = petports_navTickClock()
	return now ~= nil and (now - began) * 1000 >= NAV_BUILD_BUDGET_MS
end

-- Builds a profile's fine and coarse graphs a budget at a time, returning it once finished.
function petports_navGraphBuildStep(profile)
	local build = self.petportsNavGraphBuild

	if build == nil or build.profile ~= profile then
		local cells = petports_navIndexRead()[profile]
		local keys = {}
		for cellKey in pairs(type(cells) == "table" and cells or {}) do
			table.insert(keys, cellKey)
		end

		build = {
			profile = profile,
			version = self.petportsNavVersion or 0,
			keys = keys,
			at = 1,
			edges = {},
			pairs = {}
		}
		self.petportsNavGraphBuild = build
		petports_profCount("graphBuildStart")
	end

	local began = petports_navTickClock()
	local stop = math.min(#build.keys, build.at + NAV_BUILD_CHUNK - 1)
	local k = build.at
	while k <= #build.keys and (k <= stop or not petports_navBuildOverBudget(began)) do
		local cellKey = build.keys[k]
		for to, entry in pairs(petports_navCellRead(profile, cellKey)) do
			build.edges[cellKey .. ">" .. to] = entry
			if type(entry) == "table" and entry.r == true then
				build.pairs[#build.pairs + 1] = cellKey
				build.pairs[#build.pairs + 1] = to
				build.pairs[#build.pairs + 1] = entry.d or petports_navCellSpan(cellKey, to)
			end
		end
		k = k + 1
	end

	build.at = k

	if build.at <= #build.keys then return nil end

	if build.edgeAt == nil then
		for key, entry in pairs(petports_navPendingFor(profile) or {}) do
			if build.edges[key] == nil and type(entry) == "table" and entry.r == true then
				local from, to = string.match(key, "^(.-)>(.*)$")
				if from ~= nil and to ~= nil then
					build.pairs[#build.pairs + 1] = from
					build.pairs[#build.pairs + 1] = to
					build.pairs[#build.pairs + 1] = entry.d or petports_navCellSpan(from, to)
				end
			end
			build.edges[key] = entry
		end

		build.edgeAt = 1
		build.fine = {}
		build.len = {}
		build.coarse = {}
		build.blocks = {}
		for _, tiles in ipairs(NAV_LEVELS) do build.coarse[tiles] = {} end
	end

	local levels = NAV_LEVELS
	local blocks = build.blocks
	-- Returns a cell's block key at every level, cached.
	local function blocksOf(cellKey)
		local held = blocks[cellKey]
		if held ~= nil then return held end
		held = {}
		for i, tiles in ipairs(levels) do held[i] = petports_navBlockKey(cellKey, tiles) end
		blocks[cellKey] = held
		return held
	end

	local total = #build.pairs
	local edgeStop = math.min(total, build.edgeAt + NAV_BUILD_CHUNK * 24 - 1)
	local began = petports_navTickClock()
	local k = build.edgeAt
	local fine, len, coarse = build.fine, build.len, build.coarse
	while k < total and (k <= edgeStop or not petports_navBuildOverBudget(began)) do
		local from, to, d = build.pairs[k], build.pairs[k + 1], build.pairs[k + 2]

		local list = fine[from]
		if list == nil then list = {} fine[from] = list end
		list[#list + 1] = to
		local row = len[from]
		if row == nil then row = {} len[from] = row end
		row[to] = d

		local fa, fb = blocksOf(from), blocksOf(to)
		for i = 1, #levels do
			local a, b = fa[i], fb[i]
			if a ~= nil and b ~= nil and a ~= b then
				local bucket = coarse[levels[i]]
				local row = bucket[a]
				if row == nil then row = {} bucket[a] = row end
				row[b] = true
			end
		end
		k = k + 3
	end

	build.edgeAt = k

	if build.edgeAt < total then return nil end

	self.petportsNavGraph = {
		profile = profile,
		version = self.petportsNavVersion or 0,
		builtAt = world.time(),
		fine = build.fine,
		len = build.len,
		coarse = build.coarse
	}
	self.petportsNavGraphBuild = nil
	petports_profCount("graphBuildDone")

	return self.petportsNavGraph
end


local NAV_MERGED_MIN_AGE = 5.0

-- Builds the graph merging the land, swim and bridge profiles, a budget at a time.
function petports_navMergedBuildStep()
	local build = self.petportsNavMergedBuild
	local bridgeProfile = petports_navBridgeProfileRaw()

	if build == nil then
		local land = petports_navWithSide(false, petports_navProfile)
		local swim = petports_navWithSide(true, petports_navProfile)
		local index = petports_navIndexRead()
		local keys = {}

		for _, source in ipairs({ { land, 0 }, { swim, 1 }, { bridgeProfile, 3 } }) do
			local cells = index[source[1]]
			for cellKey in pairs(type(cells) == "table" and cells or {}) do
				table.insert(keys, { cellKey, source[1], source[2] })
			end
		end

		build = {
			version = self.petportsNavVersion or 0,
			keys = keys, at = 1,
			edges = {}, side = {}, bridge = {},
			land = land, swim = swim
		}
		self.petportsNavMergedBuild = build
		petports_profCount("mergedBuildStart")
	end

	local stop = math.min(#build.keys, build.at + NAV_BUILD_CHUNK - 1)

	for k = build.at, stop do
		local cellKey, profile, sideTag = build.keys[k][1], build.keys[k][2], build.keys[k][3]

		if sideTag < 2 then
			local held = build.side[cellKey]
			if held == nil then
				build.side[cellKey] = sideTag
			elseif held ~= sideTag then
				build.side[cellKey] = 2
			end
		end

		for to, entry in pairs(petports_navCellRead(profile, cellKey)) do
			local key = cellKey .. ">" .. to
			if sideTag == 3 then
				if type(entry) == "table" and entry.r == true then
					build.bridge[key] = entry
					build.edges[key] = entry
				end
			elseif build.edges[key] == nil then
				build.edges[key] = entry
			end
		end
	end

	build.at = stop + 1
	if build.at <= #build.keys then return nil end

	if build.edgeKeys == nil then
		for _, profile in ipairs({ build.land, build.swim }) do
			for key, entry in pairs(petports_navPendingFor(profile) or {}) do
				if build.edges[key] == nil then build.edges[key] = entry end
			end
		end
		for key, entry in pairs(petports_navPendingFor(bridgeProfile) or {}) do
			if type(entry) == "table" and entry.r == true then
				build.bridge[key] = entry
				build.edges[key] = entry
			end
		end

		build.edgeKeys = {}
		for key in pairs(build.edges) do table.insert(build.edgeKeys, key) end
		build.edgeAt = 1
		build.fine = {}
		build.len = {}
		build.coarse = {}
		for _, tiles in ipairs(NAV_LEVELS) do build.coarse[tiles] = {} end
	end

	local edgeStop = math.min(#build.edgeKeys, build.edgeAt + NAV_BUILD_CHUNK * 8 - 1)

	for k = build.edgeAt, edgeStop do
		local key = build.edgeKeys[k]
		local entry = build.edges[key]

		if type(entry) == "table" and entry.r == true then
			local from, to = string.match(key, "^(.-)>(.*)$")

			if from ~= nil and to ~= nil then
				build.fine[from] = build.fine[from] or {}
				table.insert(build.fine[from], to)
				build.len[from] = build.len[from] or {}
				build.len[from][to] = entry.d or petports_navCellSpan(from, to)

				for _, tiles in ipairs(NAV_LEVELS) do
					local a = petports_navBlockKey(from, tiles)
					local b = petports_navBlockKey(to, tiles)
					if a ~= nil and b ~= nil and a ~= b then
						local bucket = build.coarse[tiles]
						bucket[a] = bucket[a] or {}
						bucket[a][b] = true
					end
				end
			end
		end
	end

	build.edgeAt = edgeStop + 1
	if build.edgeAt <= #build.edgeKeys then return nil end

	local both, bridges = 0, 0
	for _, sideTag in pairs(build.side) do if sideTag == 2 then both = both + 1 end end
	for _ in pairs(build.bridge) do bridges = bridges + 1 end

	self.petportsNavMerged = {
		profile = bridgeProfile,
		version = build.version,
		builtAt = world.time(),
		fine = build.fine, len = build.len, coarse = build.coarse,
		side = build.side, bridge = build.bridge
	}
	self.petportsNavMergedBuild = nil
	petports_profCount("mergedBuildDone")

	if self.petportsNavMergedNoted ~= bridges then
		self.petportsNavMergedNoted = bridges
		sb.logInfo("NAV merged graph: %s cell(s), %s on both sides, %s bridge(s)",
			sb.printJson(#build.keys), sb.printJson(both), sb.printJson(bridges))
	end

	return self.petportsNavMerged
end

-- Returns the merged graph, rebuilding it when the store version moved and its minimum age has passed.
function petports_navMergedGraphFor()
	local cached = self.petportsNavMerged
	local version = self.petportsNavVersion or 0
	local now = world.time()

	if cached ~= nil and cached.version == version then return cached end

	if self.petportsNavMergedBuild == nil and cached ~= nil
	   and (now - (cached.builtAt or 0)) < NAV_MERGED_MIN_AGE then
		return cached
	end

	if self.petportsNavMergedBuildAt ~= now then
		self.petportsNavMergedBuildAt = now
		local done = petports_navMergedBuildStep()
		if done ~= nil then return done end
	end

	if cached ~= nil then return cached end

	return { profile = petports_navBridgeProfileRaw(), version = -1, fine = {}, len = {}, coarse = {},
		side = {}, bridge = {}, building = true }
end

-- Returns a profile's graph, rebuilding it when the store version moved and its minimum age has passed.
function petports_navGraphForInner(profile)
	if petports_gravitySwitchable() and profile == petports_navBridgeProfileRaw() then
		return petports_navMergedGraphFor()
	end

	local cached = self.petportsNavGraph

	if cached ~= nil and cached.profile == profile
	   and cached.version == (self.petportsNavVersion or 0) then
		return cached
	end

	local now = world.time()

	if cached ~= nil and cached.profile == profile
	   and self.petportsNavGraphBuild == nil
	   and (now - (cached.builtAt or 0)) < NAV_GRAPH_MIN_AGE then
		return cached
	end

	if self.petportsNavGraphBuildAt ~= now then
		self.petportsNavGraphBuildAt = now
		local done = petports_navGraphBuildStep(profile)
		if done ~= nil then return done end
	end

	if cached ~= nil and cached.profile == profile then return cached end

	return { profile = profile, version = -1, fine = {}, len = {}, coarse = {}, building = true }
end

-- Returns a profile's graph inside a profiler section.
function petports_navGraphFor(profile)
	petports_profBegin("graphFor")
	local g = petports_navGraphForInner(profile)
	petports_profEnd("graphFor")
	return g
end

-- Returns whether two cells' blocks connect at a block size, or nil once the budget runs out.
function petports_navCoarseReaches(graph, tiles, fromKey, toKey, budget)
	local a = petports_navBlockKey(fromKey, tiles)
	local b = petports_navBlockKey(toKey, tiles)

	if a == nil or b == nil then return nil end
	if a == b then return true end

	local adjacency = graph.coarse[tiles]
	if adjacency == nil then return nil end

	local visited = { [a] = true }
	local frontier = { a }
	local expanded = 0

	while #frontier > 0 do
		local nextFrontier = {}

		for _, node in ipairs(frontier) do
			expanded = expanded + 1
			if expanded > budget then return nil, expanded, "budget" end

			for neighbour in pairs(adjacency[node] or {}) do
				if neighbour == b then return true end

				if not visited[neighbour] then
					visited[neighbour] = true
					table.insert(nextFrontier, neighbour)
				end
			end
		end

		frontier = nextFrontier
	end

	return false
end

PETPORTS_NAV_SEARCH_BUDGET = 20000

-- Returns whether one cell reaches another, ruling it out at each block size before searching the fine graph.
function petports_navReaches(profile, fromKey, toKey, budget)
	if fromKey == toKey then return true, 0 end

	budget = budget or PETPORTS_NAV_SEARCH_BUDGET

	local graph = petports_navGraphFor(profile)

	for i = #NAV_LEVELS, 1, -1 do
		local tiles = NAV_LEVELS[i]

		if petports_navCoarseReaches(graph, tiles, fromKey, toKey, budget) == false then
			return false, 0
		end
	end

	local adjacency = graph.fine
	local visited = { [fromKey] = true }
	local frontier = { fromKey }
	local expanded = 0

	while #frontier > 0 do
		local nextFrontier = {}

		for _, node in ipairs(frontier) do
			expanded = expanded + 1

			if expanded > budget then
				sb.logInfo("NAV reach %s -> %s ABANDONED for %s at budget %s",
					tostring(fromKey), tostring(toKey), tostring(profile),
					sb.printJson(budget))
				return nil, expanded
			end

			for _, neighbour in ipairs(adjacency[node] or {}) do
				if neighbour == toKey then return true, expanded end

				if not visited[neighbour] then
					visited[neighbour] = true
					table.insert(nextFrontier, neighbour)
				end
			end
		end

		frontier = nextFrontier
	end

	return false, expanded
end

-- Returns a line describing why two cells have no route: the build state, a missing cell, or the nearest seam between their reachable sets.
function petports_navWhyNoRoute(profile, fromKey, toKey)
	local graph = petports_navGraphFor(profile)
	local fine = graph.fine or {}
	local known = 0
	for _ in pairs(fine) do known = known + 1 end

	local fromKnown = fine[fromKey] ~= nil
	local toKnown = fine[toKey] ~= nil
	if not toKnown then
		for _, tos in pairs(fine) do
			for _, to in ipairs(tos) do
				if to == toKey then toKnown = true break end
			end
			if toKnown then break end
		end
	end

	if graph.building then
		local build = self.petportsNavGraphBuild
		if build ~= nil then
			return string.format("graph still building: %s of %s cell shard(s) read, %s of %s edge(s) placed",
				sb.printJson(math.max(0, (build.at or 1) - 1)), sb.printJson(#(build.keys or {})),
				sb.printJson(math.floor(math.max(0, (build.edgeAt or 1) - 1) / 2)),
				sb.printJson(build.pairs and math.floor(#build.pairs / 2) or (build.edgeKeys and #build.edgeKeys or 0)))
		end
		return "graph still building: no build in flight this tick"
	end
	if not fromKnown and not toKnown then
		return string.format("neither %s nor %s is in the graph (%s cell(s))",
			fromKey, toKey, sb.printJson(known))
	end
	if not fromKnown then
		return string.format("from cell %s is not in the graph (%s cell(s))", fromKey, sb.printJson(known))
	end
	if not toKnown then
		return string.format("to cell %s is not in the graph (%s cell(s))", toKey, sb.printJson(known))
	end

	local seen = { [fromKey] = true }
	local frontier = { fromKey }
	local reached = 0
	while #frontier > 0 and reached < PETPORTS_NAV_SEARCH_BUDGET do
		local node = table.remove(frontier)
		reached = reached + 1
		for _, to in ipairs(fine[node] or {}) do
			if not seen[to] then
				seen[to] = true
				table.insert(frontier, to)
			end
		end
	end

	local toSeen = { [toKey] = true }
	local toFrontier = { toKey }
	local toReached = 0
	while #toFrontier > 0 and toReached < PETPORTS_NAV_SEARCH_BUDGET do
		local node = table.remove(toFrontier)
		toReached = toReached + 1
		for _, to in ipairs(fine[node] or {}) do
			if not toSeen[to] then
				toSeen[to] = true
				table.insert(toFrontier, to)
			end
		end
	end

	local fromList, toList = {}, {}
	for key in pairs(seen) do
		local kx, ky = string.match(key, "^(-?%d+),(-?%d+)$")
		if kx ~= nil and #fromList < 600 then table.insert(fromList, { key, tonumber(kx), tonumber(ky) }) end
	end
	for key in pairs(toSeen) do
		local kx, ky = string.match(key, "^(-?%d+),(-?%d+)$")
		if kx ~= nil and #toList < 600 then table.insert(toList, { key, tonumber(kx), tonumber(ky) }) end
	end

	local seamA, seamB, seamD = nil, nil, nil
	for _, a in ipairs(fromList) do
		for _, b in ipairs(toList) do
			if not seen[b[1]] then
				local dx, dy = a[2] - b[2], a[3] - b[3]
				local d = dx * dx + dy * dy
				if seamD == nil or d < seamD then seamA, seamB, seamD = a[1], b[1], d end
			end
		end
	end

	local seam = "no seam found"
	if seamA ~= nil then
		local ab = petports_navKnown(profile, seamA, seamB)
		local ba = petports_navKnown(profile, seamB, seamA)
		local sa, sb_ = petports_navSweptRadius(profile, seamA), petports_navSweptRadius(profile, seamB)
		seam = string.format("seam %s (from-side, swept r%s) <-> %s (to-side, swept r%s), %s cell(s) apart: "
			.. "store says %s->%s %s, %s->%s %s",
			seamA, sb.printJson(sa), seamB, sb.printJson(sb_),
			sb.printJson(math.floor(math.sqrt(seamD) * 10 + 0.5) / 10),
			seamA, seamB, ab == nil and "ABSENT" or tostring(ab),
			seamB, seamA, ba == nil and "ABSENT" or tostring(ba))
	end

	local outDegree = #(fine[fromKey] or {})
	local last = self.petportsNavLastRoute
	local place = "not in the last route"
	if last ~= nil and type(last.path) == "table" then
		for i, key in ipairs(last.path) do
			if key == fromKey then
				local nextKey = last.path[i + 1]
				local present = false
				for _, to in ipairs(fine[fromKey] or {}) do
					if to == nextKey then present = true end
				end
				place = string.format("at %s of %s in the last route (%s -> %s), next %s, edge to it %s",
					sb.printJson(i), sb.printJson(#last.path), tostring(last.from),
					tostring(last.to), tostring(nextKey), present and "PRESENT" or "ABSENT")
			end
		end
	end

	local capped = (reached >= PETPORTS_NAV_SEARCH_BUDGET or toReached >= PETPORTS_NAV_SEARCH_BUDGET)
		and " -- A COUNT AT THE SEARCH BUDGET IS A BUDGET-OUT, NOT A WALL" or ""
	return string.format("both known, no path: %s cell(s) reachable from %s, %s from %s, of %s in the graph "
		.. "(version %s); from has %s outgoing edge(s); %s; %s%s",
		sb.printJson(reached), fromKey, sb.printJson(toReached), toKey, sb.printJson(known),
		tostring(graph.version), sb.printJson(outDegree), seam, place, capped)
end

local NAV_ROUTE_BUDGET_MS = 3.0
local NAV_WAYPOINT_SWEEPS_PER_CALL = 2

petports_navHeap = {}

-- Pushes a key onto the heap at a cost.
function petports_navHeap.push(heap, cost, key)
	local n = #heap + 1
	heap[n] = { cost, key }
	while n > 1 do
		local parent = math.floor(n / 2)
		if heap[parent][1] <= heap[n][1] then break end
		heap[parent], heap[n] = heap[n], heap[parent]
		n = parent
	end
end

-- Removes and returns the lowest cost entry on the heap.
function petports_navHeap.pop(heap)
	local n = #heap
	if n == 0 then return nil end
	local top = heap[1]
	heap[1] = heap[n]
	heap[n] = nil
	n = n - 1
	local i = 1
	while true do
		local l, r = i * 2, i * 2 + 1
		local small = i
		if l <= n and heap[l][1] < heap[small][1] then small = l end
		if r <= n and heap[r][1] < heap[small][1] then small = r end
		if small == i then break end
		heap[i], heap[small] = heap[small], heap[i]
		i = small
	end
	return top[1], top[2]
end

-- Relaxes a node's neighbours into the search, returning the path once the target is settled.
function petports_navRouteExpand(job, adjacency, lengths, node, cost, toKey)
	if node == toKey then
		local path = { toKey }
		local step = job.cameFrom[node]
		while step do
			table.insert(path, 1, step)
			step = job.cameFrom[step]
		end
		return path
	end
	local row = lengths ~= nil and lengths[node] or nil
	for _, neighbour in ipairs(adjacency[node] or {}) do
		local d = row ~= nil and row[neighbour] or nil
		if d == nil then d = petports_navCellSpan(node, neighbour) end
		local total = cost + d
		local held = job.dist[neighbour]
		if held == nil or total < held then
			job.dist[neighbour] = total
			job.cameFrom[neighbour] = node
			petports_navHeap.push(job.heap, total, neighbour)
		end
	end
	return nil
end

-- Runs the route search a millisecond budget at a time, returning the path, or more while it continues.
function petports_navRouteStep(profile, fromKey, toKey, budget)
	if fromKey == toKey then return { fromKey } end
	local graph = petports_navGraphFor(profile)
	local adjacency = graph.fine
	local lengths = graph.len
	budget = budget or PETPORTS_NAV_SEARCH_BUDGET

	local job = self.petportsNavRouteJob
	if job == nil or job.profile ~= profile or job.from ~= fromKey or job.to ~= toKey
	   or job.version ~= graph.version then
		job = {
			profile = profile, from = fromKey, to = toKey, version = graph.version,
			cameFrom = { [fromKey] = false }, dist = { [fromKey] = 0 }, heap = {},
			settled = {}, expanded = 0
		}
		petports_navHeap.push(job.heap, 0, fromKey)
		self.petportsNavRouteJob = job
	end

	local began = petports_navTickClock()
	while true do
		local cost, node = petports_navHeap.pop(job.heap)
		if node == nil then
			self.petportsNavRouteJob = nil
			return nil, job.expanded, "none"
		end
		if not job.settled[node] then
			job.settled[node] = true
			job.expanded = job.expanded + 1
			if job.expanded > budget then
				self.petportsNavRouteJob = nil
				return nil, job.expanded, "budget"
			end
			local path = petports_navRouteExpand(job, adjacency, lengths, node, cost, toKey)
			if path ~= nil then
				self.petportsNavRouteJob = nil
				if PETPORTS_NAV_VERBOSE then
					local routeKey = fromKey .. ">" .. toKey
					if self.petportsNavRouteNoted ~= routeKey then
						self.petportsNavRouteNoted = routeKey
						sb.logInfo("NAV route %s -> %s: %s hop(s), %s tile(s) by edge length, %s expanded",
							fromKey, toKey, sb.printJson(#path - 1), sb.printJson(math.floor(cost + 0.5)),
							sb.printJson(job.expanded))
					end
				end
				return path, job.expanded
			end
			if began ~= nil and job.expanded % 64 == 0 then
				local now = petports_navTickClock()
				if now ~= nil and (now - began) * 1000 >= NAV_ROUTE_BUDGET_MS then
					return nil, job.expanded, "more"
				end
			end
		end
	end
end

-- Returns the cell path between two cells, searched in one call.
function petports_navPath(profile, fromKey, toKey, budget)
	if fromKey == toKey then return { fromKey } end

	local graph = petports_navGraphFor(profile)
	local job = { cameFrom = { [fromKey] = false }, dist = { [fromKey] = 0 }, heap = {} }
	local settled = {}
	local expanded = 0

	budget = budget or PETPORTS_NAV_SEARCH_BUDGET
	petports_navHeap.push(job.heap, 0, fromKey)

	while true do
		local cost, node = petports_navHeap.pop(job.heap)
		if node == nil then return nil, expanded end
		if not settled[node] then
			settled[node] = true
			expanded = expanded + 1
			if expanded > budget then return nil, expanded, "budget" end
			local path = petports_navRouteExpand(job, graph.fine, graph.len, node, cost, toKey)
			if path ~= nil then return path, expanded end
		end
	end
end

-- Returns the next waypoint along the route to a cell, with the hops left behind it and the leg's cells and kind.
function petports_navWaypoint(profile, fromKey, toKey, reach, freeMover, minAdvance, allowStep)
	local sweepJob = self.petportsNavWaypointJob
	local path
	if sweepJob ~= nil and sweepJob.profile == profile and sweepJob.from == fromKey
	   and sweepJob.to == toKey and sweepJob.version == petports_navGraphFor(profile).version then
		path = sweepJob.path
	else
		local expanded, verdict
		path, expanded, verdict = petports_navRouteStep(profile, fromKey, toKey)
		if path == nil and verdict == "more" then return nil, "more" end
	end

	self.petportsNavLastRoute = {
		from = fromKey, to = toKey, path = path, at = world.time(),
		building = petports_navGraphFor(profile).building == true
	}

	if path == nil or #path < 2 then return nil end

	minAdvance = minAdvance or 0

	local graph = petports_navGraphFor(profile)
	local sides = graph.side
	-- Returns a cell's side, taking the unit's own for cells on both.
	local function sideOf(key)
		local tag = sides ~= nil and sides[key] or nil
		if tag == nil or tag == 2 then return freeMover and 1 or 0 end
		return tag
	end
	-- Returns a cell's anchor as surveyed from a side.
	local function anchorOf(key, asSide)
		local kx = tonumber(string.match(key, "^(-?%d+),"))
		local ky = tonumber(string.match(key, ",(-?%d+)$"))
		if kx == nil then return nil end
		if sides == nil then return petports_navAnchor(kx, ky, freeMover) end
		local swim = (asSide or sideOf(key)) == 1
		return petports_navWithSide(swim, petports_navAnchor, kx, ky, swim)
	end
	local startSide = sideOf(path[1])
	self.petportsNavLastRoute.bridge = nil

	if PETPORTS_NAV_VERBOSE and sides ~= nil then
		local sidesKey = fromKey .. ">" .. toKey .. "#" .. tostring(#path)
		if self.petportsNavSidesNoted ~= sidesKey then
			self.petportsNavSidesNoted = sidesKey
			local runs, runSide, runStart, runCount = {}, startSide, path[1], 0
			for i = 1, #path + 1 do
				local cellSide = (i <= #path) and sideOf(path[i]) or nil
				if cellSide ~= runSide then
					runs[#runs + 1] = (runSide == 1 and "swim " or "land ") .. tostring(runStart)
						.. " x" .. tostring(runCount)
					if cellSide ~= nil then
						local entry = graph.bridge ~= nil and graph.bridge[path[i - 1] .. ">" .. path[i]] or nil
						runs[#runs + 1] = "[" .. (entry ~= nil and tostring(entry.k) or "NO BRIDGE ENTRY")
							.. " " .. path[i - 1] .. ">" .. path[i] .. "]"
					end
					runSide, runStart, runCount = cellSide, path[i], 0
				end
				runCount = runCount + 1
			end
			sb.logInfo("NAV route sides %s -> %s, %s cell(s), unit side %s: %s",
				fromKey, toKey, sb.printJson(#path), sb.printJson(startSide), table.concat(runs, " "))
		end
	end

	local origin, originWhy = anchorOf(path[1], startSide)

	if origin == nil then
		if PETPORTS_NAV_VERBOSE then
			sb.logInfo("NAV waypoint from %s to %s picked nothing: the start cell has no anchor as side %s (tag %s), %s-cell route -- %s",
				fromKey, toKey, sb.printJson(startSide), sb.printJson(sides ~= nil and sides[path[1]] or nil),
				sb.printJson(#path), tostring(originWhy))
		end
		return nil
	end

	if sides ~= nil and sideOf(path[2]) ~= startSide then
		local entry = graph.bridge ~= nil and graph.bridge[path[1] .. ">" .. path[2]] or nil
		local target, targetWhy = anchorOf(path[2])
		if target == nil then
			if PETPORTS_NAV_VERBOSE then
				sb.logInfo("NAV waypoint from %s to %s picked nothing: the crossing %s>%s has no anchor for %s as side %s (tag %s), bridge entry %s -- %s",
					fromKey, toKey, tostring(path[1]), tostring(path[2]), tostring(path[2]),
					sb.printJson(sideOf(path[2])), sb.printJson(sides[path[2]]), tostring(entry and entry.k),
					tostring(targetWhy))
			end
			return nil
		end
		self.petportsNavLastRoute.bridge = {
			k = entry and entry.k or "wade",
			board = entry and entry.board, hole = entry and entry.hole,
			float = entry and entry.float,
			from = path[1], to = path[2], toSide = sideOf(path[2])
		}
		self.petportsNavLastRoute.leg = path[2]
		self.petportsNavLastRoute.waypoint = target
		self.petportsNavLastRoute.nextAnchor = #path >= 3 and anchorOf(path[3]) or nil
		return target, #path - 2, path[2], 1, path[1], path[1]
	end

	local cellAnchor = origin
	local body = freeMover and mcontroller.position() or origin

	local hopClear, hop = nil, nil
	if freeMover and petports_flyPathClear ~= nil and #path >= 2 then
		hop = anchorOf(path[2])

		if hop ~= nil then
			local okHop, verdict = pcall(petports_flyPathClear, body, hop)
			hopClear = okHop and verdict == true
			if not hopClear then
				local gap = world.magnitude(body, cellAnchor)
				local okStep, stepClear = pcall(petports_flyPathClear, body, cellAnchor)
				stepClear = okStep and stepClear == true
				sb.logInfo("UNIT leg pick from %s: first hop %s is NOT clear from the body %s; "
					.. "own anchor %s is %s tiles off and %s -- %s",
					tostring(path[1]), sb.printJson(hop), sb.printJson(body),
					sb.printJson(cellAnchor), sb.printJson(math.floor(gap * 100 + 0.5) / 100),
					stepClear and "clear" or "NOT clear",
					(stepClear and allowStep ~= false) and "stepping onto it first"
						or (stepClear and "step budget spent, handing out the hop"
							or "no step possible, handing out the hop"))
				if stepClear and allowStep ~= false then
					self.petportsNavLastRoute.leg = path[1]
					self.petportsNavLastRoute.waypoint = cellAnchor
					self.petportsNavLastRoute.nextAnchor = hop
					self.petportsNavLastRoute.turn = nil
					return cellAnchor, #path - 1, path[1], 0, path[1], path[1], "step"
				end
			end
		end
	end

	local chosen, chosenAt = nil, 2
	local legKind = nil

	local nearest, nearestAt = nil, nil
	local inReach = {}

	for i = 2, #path do
		if sides ~= nil and sideOf(path[i]) ~= startSide then break end

		local anchor = anchorOf(path[i], startSide)

		if anchor ~= nil then
			local dx = anchor[1] - origin[1]
			local dy = anchor[2] - origin[2]
			local distance = math.sqrt(dx * dx + dy * dy)

			if distance < minAdvance and i < #path then
			elseif freeMover then
				if distance <= (reach or 24) then
					if nearest == nil then nearest, nearestAt = anchor, i end
					inReach[#inReach + 1] = { anchor = anchor, at = i }
				elseif #inReach > 0 then
					break
				elseif nearest ~= nil then
					chosen, chosenAt = nearest, nearestAt
					break
				else
					chosen, chosenAt = anchor, i
					break
				end
			elseif distance <= (reach or 24) then
				chosen, chosenAt = anchor, i
			elseif chosen ~= nil then
				break
			else
				chosen, chosenAt = anchor, i
				break
			end
		end
	end

	if freeMover and #inReach > 0 then
		-- Returns whether the line from the body to a candidate anchor is clear.
		local function clearTo(entry)
			if petports_flyPathClear ~= nil then
				local okClear, verdict = pcall(petports_flyPathClear, origin, entry.anchor)
				return okClear and verdict == true
			end
			local okLos, blocked = pcall(world.lineTileCollision,
				origin, entry.anchor, { "Null", "Block", "Dynamic", "Slippery" })
			return okLos and blocked == false
		end
		local reachParts = {}
		for i, entry in ipairs(inReach) do
			reachParts[i] = tostring(entry.at) .. "@" .. tostring(entry.anchor[1]) .. "," .. tostring(entry.anchor[2])
		end
		local reachKey = table.concat(reachParts, ";")
		local job = self.petportsNavWaypointJob
		if job == nil or job.profile ~= profile or job.from ~= fromKey or job.to ~= toKey
		   or job.version ~= graph.version or job.reachKey ~= reachKey then
			job = { profile = profile, from = fromKey, to = toKey, path = path, version = graph.version,
				reachKey = reachKey, lo = 1, hi = #inReach, farTried = false, sweeps = 0,
				loClear = false }
			self.petportsNavWaypointJob = job
		end
		local budgetLeft = NAV_WAYPOINT_SWEEPS_PER_CALL
		if not job.farTried then
			job.farTried = true
			if job.hi > 1 then
				job.sweeps = job.sweeps + 1
				budgetLeft = budgetLeft - 1
				if clearTo(inReach[job.hi]) then job.lo = job.hi job.loClear = true end
			end
		end
		while job.hi - job.lo > 1 do
			if budgetLeft <= 0 then return nil, "more" end
			local mid = math.floor((job.lo + job.hi) / 2)
			job.sweeps = job.sweeps + 1
			budgetLeft = budgetLeft - 1
			if clearTo(inReach[mid]) then job.lo = mid job.loClear = true else job.hi = mid end
		end
		if not job.loClear then
			if budgetLeft <= 0 then return nil, "more" end
			job.sweeps = job.sweeps + 1
			job.loClear = clearTo(inReach[job.lo])
			if not job.loClear then
				sb.logInfo("UNIT leg pick from %s: no in-reach node is clear from %s "
					.. "(nearest %s at hop %s) -- the first hop %s is the leg",
					tostring(path[1]), sb.printJson(origin), sb.printJson(inReach[job.lo].anchor),
					sb.printJson(inReach[job.lo].at), sb.printJson(hop))
				job.lo = nil
			end
		end
		if job.lo ~= nil then
			chosen, chosenAt = inReach[job.lo].anchor, inReach[job.lo].at
		elseif hop ~= nil then
			chosen, chosenAt = hop, 2
			legKind = "step"
		end
		petports_profCount("waypointSweeps", job.sweeps)
		self.petportsNavWaypointJob = nil
	end

	if chosen == nil and nearest ~= nil then chosen, chosenAt = nearest, nearestAt end
	if chosen == nil then
		local pickKey = fromKey .. ">" .. toKey .. "#" .. tostring(#path)
		if PETPORTS_NAV_VERBOSE and self.petportsNavPickNoted ~= pickKey then
			self.petportsNavPickNoted = pickKey
			local notes = {}
			for i = 2, #path do
				local tag = sides ~= nil and sides[path[i]] or nil
				if sides ~= nil and sideOf(path[i]) ~= startSide then
					notes[#notes + 1] = path[i] .. " tag " .. tostring(tag) .. " is the other side, run ends"
					break
				end
				local anchor, anchorWhy = anchorOf(path[i], startSide)
				if anchor == nil then
					notes[#notes + 1] = path[i] .. " tag " .. tostring(tag) .. " NO ANCHOR as side " .. tostring(startSide)
						.. " (" .. tostring(anchorWhy) .. ")"
				else
					local dx, dy = anchor[1] - origin[1], anchor[2] - origin[2]
					notes[#notes + 1] = path[i] .. " tag " .. tostring(tag) .. " anchor " .. sb.printJson(anchor)
						.. " at " .. tostring(math.floor(math.sqrt(dx * dx + dy * dy) * 100 + 0.5) / 100)
				end
			end
			sb.logInfo("NAV waypoint from %s to %s picked nothing on a %s-cell route: origin %s, start %s tag %s as side %s, "
				.. "minAdvance %s, reach %s, freeMover %s, first hop %s clear %s -- %s",
				fromKey, toKey, sb.printJson(#path), sb.printJson(origin), tostring(path[1]),
				sb.printJson(sides ~= nil and sides[path[1]] or nil), sb.printJson(startSide),
				sb.printJson(minAdvance), sb.printJson(reach), tostring(freeMover),
				sb.printJson(hop), tostring(hopClear), table.concat(notes, "; "))
		end
		return nil
	end

	self.petportsNavLastRoute.leg = path[chosenAt]
	self.petportsNavLastRoute.waypoint = chosen

	self.petportsNavLastRoute.turn = nil
	self.petportsNavLastRoute.nextAnchor = nil
	if chosenAt < #path then
		self.petportsNavLastRoute.nextAnchor = anchorOf(path[chosenAt + 1])
	end

	return chosen, #path - chosenAt, path[chosenAt], chosenAt - 1, path[1],
		path[chosenAt - 1], legKind
end

local NAV_NEAREST_SWEEPS = 6

-- Returns the graph's cells bucketed by block, built on first use.
function petports_navGraphBlocks(graph)
	if graph.blocks ~= nil then return graph.blocks end

	local blocks = { map = {}, count = 0 }

	for from in pairs(graph.fine) do
		local fx, fy = string.match(from, "^(-?%d+),(-?%d+)$")
		if fx ~= nil then
			local key = math.floor(tonumber(fx) / NAV_BLOCK_CELLS) .. ","
				.. math.floor(tonumber(fy) / NAV_BLOCK_CELLS)
			if blocks.map[key] == nil then
				blocks.map[key] = {}
				blocks.count = blocks.count + 1
			end
			table.insert(blocks.map[key], from)
		end
	end

	graph.blocks = blocks
	return blocks
end


-- Returns the debug colour for a swept radius.
function petports_navRadiusColour(radius)
	local lo, hi = PETPORTS_NAV_RADIUS_START, petports_navFullRadius()
	local t = (radius - lo) / math.max(1, hi - lo)
	if t < 0 then t = 0 elseif t > 1 then t = 1 end
	return { math.floor(255 * (1 - t) + 0.5), math.floor(255 * t + 0.5), 0, 255 }
end

-- Returns the first candidate cell inside the radius the body can reach, saving a resume point when its sweeps run out.
function petports_navNearestFrom(candidates, startAt, position, freeMover, radius, resumeKey, fine)
	local swept = 0

	for i = startAt, #candidates do
		local c = candidates[i]
		local anchor = petports_navAnchor(c.cx, c.cy, freeMover)

		if anchor ~= nil then
			local distance = world.magnitude(anchor, position)

			if distance <= radius then
				if not freeMover then
					self.petportsNavNearestResume = nil
					return c.key, anchor, distance
				end

				if swept >= NAV_NEAREST_SWEEPS then
					self.petportsNavNearestResume = {
						key = resumeKey, fine = fine, candidates = candidates, at = i
					}
					petports_profCount("nearestCut")
					return nil, nil, nil, true
				end

				swept = swept + 1

				if petports_bodyFitsAlong(position, anchor) == true then
					self.petportsNavNearestResume = nil
					return c.key, anchor, distance
				end
			end
		end
	end

	self.petportsNavNearestResume = nil
	return nil
end

-- Returns the nearest graph cell to a position on a side, resuming a part-finished search.
function petports_navNearestCellIn(graph, position, freeMover, radius, sideTag)
	radius = radius or 2.5

	if freeMover then radius = math.max(radius, NAV_MAX_DISTANCE) end

	local fine = graph.fine
	local sides = graph.side
	local px, py = petports_navCell(position)

	local reach = math.ceil(radius / petports_navStride())

	local resumeKey = petports_navCellKey(px, py) .. "|" .. tostring(freeMover)
		.. "|" .. tostring(radius) .. "|" .. tostring(sideTag)
	local resume = self.petportsNavNearestResume

	if resume ~= nil and resume.key == resumeKey and resume.fine == fine then
		return petports_navNearestFrom(resume.candidates, resume.at, position, freeMover,
			radius, resumeKey, fine)
	end

	local candidates = {}
	local blocks = petports_navGraphBlocks(graph)
	local bx0 = math.floor((px - reach) / NAV_BLOCK_CELLS)
	local bx1 = math.floor((px + reach) / NAV_BLOCK_CELLS)
	local by0 = math.floor((py - reach) / NAV_BLOCK_CELLS)
	local by1 = math.floor((py + reach) / NAV_BLOCK_CELLS)

	for by = by0, by1 do
		for bx = bx0, bx1 do
			for _, key in ipairs(blocks.map[bx .. "," .. by] or {}) do
				local cx = tonumber(string.match(key, "^(-?%d+),"))
				local cy = tonumber(string.match(key, ",(-?%d+)$"))
				local sideOk = sideTag == nil or sides == nil
					or sides[key] == sideTag or sides[key] == 2
				if sideOk and cx ~= nil and math.abs(cx - px) <= reach and math.abs(cy - py) <= reach then
					local ox, oy = petports_navCellOrigin(cx, cy)
					local dx = ox + PETPORTS_NAV_CELL * 0.5 - position[1]
					local dy = oy + PETPORTS_NAV_CELL * 0.5 - position[2]
					table.insert(candidates, {
						cx = cx, cy = cy, key = key, rough = dx * dx + dy * dy
					})
				end
			end
		end
	end

	table.sort(candidates, function(a, b)
		if a.rough ~= b.rough then return a.rough < b.rough end
		return a.key < b.key
	end)

	return petports_navNearestFrom(candidates, 1, position, freeMover, radius, resumeKey, fine)
end

-- Returns the nearest graph cell to a position.
function petports_navNearestCell(position, freeMover, radius)
	return petports_navNearestCellIn(petports_navGraphFor(petports_navProfile()), position, freeMover, radius, nil)
end

-- Returns the nearest merged-graph cell on the unit's own side.
function petports_navNearestCellSide(position, freeMover, radius)
	if not petports_gravitySwitchable() then
		return petports_navNearestCell(position, freeMover, radius)
	end

	local graph = petports_navGraphFor(petports_navBridgeProfileRaw())
	return petports_navWithSide(freeMover, petports_navNearestCellIn, graph, position, freeMover,
		radius, freeMover and 1 or 0)
end

-- Returns the profile, edge, reachable, pending and swept-cell counts.
function petports_navStats()
	local index = petports_navIndexRead()
	local profiles, edges, reachable = 0, 0, 0
	local pending = self.petportsNavPendingCount or 0
	local swept = 0

	for _, profile in ipairs(petports_navIndexProfiles()) do
		local cells = index[profile]
		profiles = profiles + 1

		for cellKey in pairs(type(cells) == "table" and cells or {}) do
			swept = swept + 1

			for _, entry in pairs(petports_navCellRead(profile, cellKey)) do
				edges = edges + 1
				if type(entry) == "table" and entry.r == true then
					reachable = reachable + 1
				end
			end
		end
	end

	return profiles, edges, reachable, pending, swept
end


local NAV_SWEEP_TTL = 21600.0

local NAV_CLAIM_TTL = 120.0

-- Returns an index entry's sweep time and radius when it matches the current generation.
function petports_navIndexEntry(value)
	if type(value) == "number" then return nil, 0 end
	if type(value) ~= "table" then return nil, 0 end
	if value.g ~= petports_navGenNow() then return nil, 0 end

	local at = tonumber(value.at)
	if at == nil then return nil, 0 end

	return at, tonumber(value.radius) or 0
end

-- Returns when a cell was swept and to what radius, or nil once the record has expired.
function petports_navSwept(profile, cellKey)
	local index = petports_navIndexRead()
	local cells = index[profile]
	if type(cells) ~= "table" then return nil end

	local at, radius = petports_navIndexEntry(cells[cellKey])
	if at == nil then return nil end

	if (world.time() - at) > NAV_SWEEP_TTL then return nil end

	return at, radius
end

-- Returns the radius a cell has been swept to.
function petports_navSweptRadius(profile, cellKey)
	local at, radius = petports_navSwept(profile, cellKey)
	if at == nil then return 0 end
	return radius
end

-- Returns the radius a cell has been swept to, from an index already read.
function petports_navSweptRadiusIn(cells, cellKey, now)
	if type(cells) ~= "table" then return 0 end

	local at, radius = petports_navIndexEntry(cells[cellKey])
	if at == nil then return 0 end
	if (now - at) > NAV_SWEEP_TTL then return 0 end

	return radius
end

PETPORTS_NAV_SWEEPS = 8
PETPORTS_NAV_WORKERS = 4

-- Returns the first probe slot a sweep's workers use.
function petports_navSlotBase(index)
	return (index - 1) * PETPORTS_NAV_WORKERS
end

-- Claims a cell and starts the coroutine that probes its neighbours out to the next radius.
function petports_navSweepStart(cx, cy, ownerId, index)
	local profile = petports_navProfile()
	local cellKey = petports_navCellKey(cx, cy)

	local sweptRadius = petports_navSweptRadius(profile, cellKey)
	local radius = petports_navNextRadius(sweptRadius)

	if radius == nil then
		return nil, "already swept to full radius"
	end

	local workId = "nav:" .. profile .. ":" .. cellKey

	for _, live in pairs(self.petportsNavSweeps or {}) do
		if live.workId == workId then
			return nil, "already being swept by this unit"
		end
	end

	if not petports_claimTake(workId, ownerId, entity.id(), "nav",
		mcontroller.position(), NAV_CLAIM_TTL) then
		return nil, "claimed by another unit"
	end

	local freeMover = petports_freeMover()

	index = index or 1

	self.petportsNavSweeps = self.petportsNavSweeps or {}
	self.petportsNavSweeps[index] = {
		workId = workId,
		index = index,
		ownerId = ownerId,
		cellKey = cellKey,
		profile = profile,
		freeMover = freeMover,
		radius = radius,
		started = world.time(),
		job = coroutine.create(function()
			local neighbours = petports_navNeighbours(cx, cy, freeMover, radius)

			local nextPair = 1
			local active = {}
			local base = petports_navSlotBase(index)

			local workers = freeMover and 1 or PETPORTS_NAV_WORKERS
			while true do
				for slot = 1, workers do
					if active[slot] == nil then
						while nextPair <= #neighbours do
							local candidate = neighbours[nextPair]
							nextPair = nextPair + 1

							local known, age =
								petports_navKnown(profile, cellKey, candidate.key)
							local fresh = known ~= nil
								and (age or 0) < NAV_SWEEP_TTL

							local joined = nil

							if not fresh and not freeMover then
								joined = petports_navReaches(profile, cellKey, candidate.key)
							end

							if not fresh and joined ~= true then
								active[slot] = candidate
								break
							end
						end
					end
				end

				local working = false

				for slot = 1, workers do
					local candidate = active[slot]

					if candidate ~= nil then
						working = true

						local verdict = petports_navProbeStep({ cx, cy },
							{ candidate.cx, candidate.cy }, 300, base + slot)

						if verdict ~= "searching" then active[slot] = nil end
					end
				end

				if not working and nextPair > #neighbours then return end

				coroutine.yield()
			end
		end)
	}

	return true
end

local NAV_TICK_BUDGET_MS = 4.0

local NAV_STEPS_PER_TICK = 2

local NAV_STEPS_PER_TICK_FREE = 8

-- Returns the process clock in seconds, or nil where it is unavailable.
function petports_navTickClock()
	if type(os) == "table" and type(os.clock) == "function" then
		local ok, t = pcall(os.clock)
		if ok and type(t) == "number" then return t end
	end
	return nil
end

-- Resumes the live sweeps in rotation, within the tick's step count and time budget.
function petports_navSweepStep()
	local sweeps = self.petportsNavSweeps
	if sweeps == nil or next(sweeps) == nil then return nil end

	local alive = 0

	local indices = {}
	for index in pairs(sweeps) do table.insert(indices, index) end
	table.sort(indices)

	local count = #indices
	local start = (self.petportsNavStepRotate or 0) % count
	local rotated = {}
	for i = 1, count do
		table.insert(rotated, indices[((start + i - 1) % count) + 1])
	end
	indices = rotated

	local began = petports_navTickClock()
	local stepped = 0
	local stepCap = petports_freeMover() and NAV_STEPS_PER_TICK_FREE or NAV_STEPS_PER_TICK

	for _, index in ipairs(indices) do
		local sweep = sweeps[index]

		if stepped >= stepCap then
			petports_profCount("stepCap")
			self.petportsNavStepRotate = (self.petportsNavStepRotate or 0) + stepped
			return "running"
		end

		if began ~= nil and stepped > 0 then
			local now = petports_navTickClock()

			if now ~= nil and (now - began) * 1000 >= NAV_TICK_BUDGET_MS then
				petports_profCount("budgetCut")
				self.petportsNavStepRotate = (self.petportsNavStepRotate or 0) + stepped
				return "running"
			end
		end

		stepped = stepped + 1

		if sweep ~= nil then
			if coroutine.status(sweep.job) == "dead" then
				petports_navFinishSweep(index, true)
			else
				local ok, err = petports_navWithSide(sweep.freeMover, coroutine.resume, sweep.job)

				if not ok then
					sb.logError("NAV sweep of %s FAILED: %s",
						tostring(sweep.cellKey), tostring(err))
					petports_navFinishSweep(index, false)
				else
					alive = alive + 1
				end
			end
		end
	end

	self.petportsNavStepRotate = 0

	if alive > 0 then return "running" end

	return "done"
end

-- Returns how many sweeps are live.
function petports_navSweepCount()
	local count = 0
	for _ in pairs(self.petportsNavSweeps or {}) do count = count + 1 end
	return count
end

-- Records a completed sweep's radius in the index, releases its claim and clears its probe slots.
function petports_navFinishSweep(index, completed)
	local sweeps = self.petportsNavSweeps or {}
	local sweep = sweeps[index]
	if sweep == nil then return end


	if completed then
		local index = petports_navIndexRead()
		local cells = index[sweep.profile] or {}

		local _, held = petports_navIndexEntry(cells[sweep.cellKey])

		petports_navIndexQueue(sweep.profile, sweep.cellKey, {
			at = world.time(),
			radius = math.max(held or 0, sweep.radius or 0),
			g = petports_navGenNow()
		})

		self.petportsNavFlushAt = self.petportsNavFlushAt
			or (world.time() + NAV_FLUSH_INTERVAL)
	end
	petports_claimRelease(sweep.workId, sweep.ownerId)

	local base = petports_navSlotBase(index)
	for slot = 1, PETPORTS_NAV_WORKERS do
		if self.petportsNavProbes ~= nil then
			self.petportsNavProbes[base + slot] = nil
		end
	end

	sb.logInfo("NAV sweep of %s at radius %s %s", tostring(sweep.cellKey),
		sb.printJson(sweep.radius), completed and "COMPLETE" or "ABANDONED")

	petports_profCount(completed and "sweeps" or "abandoned")
	petports_profCount("sweepR" .. tostring(sweep.radius or 0))

	sweeps[index] = nil
end

-- Returns the per-level block and edge counts, and every pair the coarse levels rule out that the fine graph connects.
function petports_navLevelReport()
	local profile = petports_navProfile()
	local graph = petports_navGraphFor(profile)

	local cells, order = {}, {}

	for from, tos in pairs(graph.fine) do
		if not cells[from] then cells[from] = true; table.insert(order, from) end
		for _, to in ipairs(tos) do
			if not cells[to] then cells[to] = true; table.insert(order, to) end
		end
	end

	table.sort(order)

	local levels = {}

	for _, tiles in ipairs(NAV_LEVELS) do
		local blocks, edges = {}, 0
		local nodes = 0

		for from, tos in pairs(graph.coarse[tiles] or {}) do
			blocks[from] = true
			for to in pairs(tos) do
				blocks[to] = true
				edges = edges + 1
			end
		end

		for _ in pairs(blocks) do nodes = nodes + 1 end

		levels[tostring(tiles)] = { nodes = nodes, edges = edges }
	end

	local checked, violations, examples = 0, 0, {}

	for _, a in ipairs(order) do
		for _, b in ipairs(order) do
			if a ~= b then
				checked = checked + 1

				local coarseSaysNo = false

				for _, tiles in ipairs(NAV_LEVELS) do
					if petports_navCoarseReaches(graph, tiles, a, b,
						PETPORTS_NAV_SEARCH_BUDGET) == false then
						coarseSaysNo = true
						break
					end
				end

				if coarseSaysNo then
					local visited = { [a] = true }
					local frontier = { a }
					local fineSaysYes = false

					while #frontier > 0 and not fineSaysYes do
						local nextFrontier = {}

						for _, node in ipairs(frontier) do
							for _, neighbour in ipairs(graph.fine[node] or {}) do
								if neighbour == b then fineSaysYes = true break end
								if not visited[neighbour] then
									visited[neighbour] = true
									table.insert(nextFrontier, neighbour)
								end
							end

							if fineSaysYes then break end
						end

						frontier = nextFrontier
					end

					if fineSaysYes then
						violations = violations + 1
						if #examples < 5 then
							table.insert(examples, a .. ">" .. b)
						end
					end
				end
			end
		end
	end

	return {
		profile = profile,
		fineCells = #order,
		levels = levels,
		invariant = {
			pairsChecked = checked,
			violations = violations,
			examples = examples
		}
	}
end


petports_navDebugBroken = false

-- Calls a debug draw function, turning debug drawing off for the session on the first failure.
function petports_navDrawSafely(fn, ...)
	if petports_navDebugBroken then return end

	local ok, err = pcall(fn, ...)

	if not ok then
		petports_navDebugBroken = true
		sb.logError("NAV debug draw disabled -- %s", tostring(err))
	end
end

-- Draws a cell's outline.
function petports_navDrawCell(cx, cy, colour)
	local x0, y0 = petports_navCellOrigin(cx, cy)
	local x1 = x0 + PETPORTS_NAV_CELL
	local y1 = y0 + PETPORTS_NAV_CELL

	petports_navDrawSafely(world.debugLine, { x0, y0 }, { x1, y0 }, colour)
	petports_navDrawSafely(world.debugLine, { x1, y0 }, { x1, y1 }, colour)
	petports_navDrawSafely(world.debugLine, { x1, y1 }, { x0, y1 }, colour)
	petports_navDrawSafely(world.debugLine, { x0, y1 }, { x0, y0 }, colour)
end

-- Draws a cross at a position.
function petports_navDrawPoint(position, colour)
	if type(position) ~= "table" then return end

	local size = 0.25

	petports_navDrawSafely(world.debugLine,
		{ position[1] - size, position[2] }, { position[1] + size, position[2] },
		colour)
	petports_navDrawSafely(world.debugLine,
		{ position[1], position[2] - size }, { position[1], position[2] + size },
		colour)
end

-- Returns the share of blocks fully swept at each level, cached.
function petports_navLevelProgress()
	local profile = petports_navProfile()
	local version = self.petportsNavVersion or 0

	local held = self.petportsNavLevelStats

	local now = world.time()

	if held ~= nil and held.profile == profile
	   and (held.version == version
	        or (now - (held.at or 0)) < NAV_OVERLAY_REFRESH) then
		return held.levels
	end

	local index = petports_navIndexRead()
	local swept = type(index[profile]) == "table" and index[profile] or {}

	local known = {}

	for cellKey in pairs(swept) do known[cellKey] = true end

	local graph = petports_navGraphFor(profile)

	for from, tos in pairs(graph.fine) do
		known[from] = true
		for _, to in ipairs(tos) do known[to] = true end
	end

	local levels = {}

	for _, tiles in ipairs({ PETPORTS_NAV_CELL, 4, 8, 16, 32 }) do
		local blocks = {}

		for cellKey in pairs(known) do
			local blockKey = tiles == PETPORTS_NAV_CELL
				and cellKey or petports_navBlockKey(cellKey, tiles)

			if blockKey ~= nil then
				local block = blocks[blockKey]

				if block == nil then
					block = { total = 0, done = 0 }
					blocks[blockKey] = block
				end

				block.total = block.total + 1
				if swept[cellKey] ~= nil then block.done = block.done + 1 end
			end
		end

		local total, complete = 0, 0

		for _, block in pairs(blocks) do
			total = total + 1
			if block.done == block.total then complete = complete + 1 end
		end

		table.insert(levels, {
			tiles = tiles,
			blocks = total,
			complete = complete,
			percent = total > 0 and (complete / total * 100) or 100
		})
	end

	self.petportsNavLevelStats = {
		profile = profile,
		version = version,
		levels = levels, at = now }

	return levels
end

-- Returns the centre, sweep time and radius of every swept cell, cached.
function petports_navSweptPoints()
	local version = self.petportsNavVersion or 0
	local held = self.petportsNavSweptPoints
	local now = world.time()

	if held ~= nil and (held.version == version
	   or (now - (held.at or 0)) < NAV_OVERLAY_REFRESH) then
		return held.points
	end

	local profile = petports_navProfile()
	local index = petports_navIndexRead()
	local cells = index[profile]
	local points = {}

	for cellKey in pairs(type(cells) == "table" and cells or {}) do
		local cx = tonumber(string.match(cellKey, "^(-?%d+),"))
		local cy = tonumber(string.match(cellKey, ",(-?%d+)$"))

		if cx ~= nil and cy ~= nil then
			local ox, oy = petports_navCellOrigin(cx, cy)

			local at, radius = petports_navIndexEntry(cells[cellKey])

			if at ~= nil then
				table.insert(points, {
					ox + PETPORTS_NAV_CELL * 0.5,
					oy + PETPORTS_NAV_CELL * 0.5,
					at = at,
					radius = radius or 0
				})
			end
		end
	end

	self.petportsNavSweptPoints = { version = version, points = points, at = now }

	return points
end

local NAV_LABEL_CORNERS = {
	{ 0.15, 0.75 },
	{ 0.55, 0.75 },
	{ 0.15, 0.25 },
	{ 0.55, 0.25 }
}

PETPORTS_NAV_DEBUG = false

local NAV_DRAW_FRESH = 10.0

local NAV_DRAW_WHY_CHARS = 48

local NAV_BOUNDS_DRAW_REFRESH = 4.0

PETPORTS_NAV_DRAW_EDGES = false

-- Returns the world origin of a cell key.
function petports_navKeyOrigin(key)
	local kx, ky = string.match(tostring(key), "^(-?%d+),(-?%d+)$")
	if kx == nil then return nil end
	return petports_navCellOrigin(tonumber(kx), tonumber(ky))
end

-- Returns a cell's anchor from the cache, without computing one.
function petports_navCachedAnchor(key)
	local cache = (self.petportsNavAnchorCache or {})[petports_navProfile()]
	local hit = cache ~= nil and cache[key] or nil
	return hit ~= nil and hit.anchor or nil
end

-- Draws the graph edges, walls, boundaries and last route near the unit, with the survey and graph status lines.
function petports_navDrawLive(here, line)
	local profile = petports_navProfile()
	local freeMover = petports_freeMover()
	local edgeColour = freeMover and "blue" or "green"
	local graph = self.petportsNavGraph

	local cells, edges = 0, 0
	if graph ~= nil and graph.profile == profile and type(graph.fine) == "table" then
		local blocks = petports_navGraphBlocks(graph)
		local ucx, ucy = petports_navCell(here)
		local ubx, uby = math.floor(ucx / NAV_BLOCK_CELLS), math.floor(ucy / NAV_BLOCK_CELLS)
		local ring = math.ceil(NAV_DRAW_RANGE / (NAV_BLOCK_CELLS * PETPORTS_NAV_CELL))

		for by = uby - ring, uby + ring do
			for bx = ubx - ring, ubx + ring do
				if PETPORTS_NAV_DRAW_EDGES then
					for _, from in ipairs(blocks.map[bx .. "," .. by] or {}) do
						local a = petports_navCachedAnchor(from)
						for _, to in ipairs(graph.fine[from] or {}) do
							local b = petports_navCachedAnchor(to)
							if a ~= nil and b ~= nil then
								petports_navDrawSafely(world.debugLine, a, b, edgeColour)
							end
						end
					end
				end
			end
		end

		for _ in pairs(graph.fine) do cells = cells + 1 end
		for _, tos in pairs(graph.fine) do edges = edges + #tos end

		local sweptCells = petports_navIndexRead()[profile]
		local now = world.time()
		local shown = {}
		for by = uby - ring, uby + ring do
			for bx = ubx - ring, ubx + ring do
				for _, from in ipairs(blocks.map[bx .. "," .. by] or {}) do
					for _, to in ipairs(graph.fine[from] or {}) do
						if not shown[to] and petports_navSweptRadiusIn(sweptCells, to, now) <= 0 then
							shown[to] = true
							local ox, oy = petports_navKeyOrigin(to)
							if ox ~= nil and math.abs(ox - here[1]) <= NAV_DRAW_RANGE
							   and math.abs(oy - here[2]) <= NAV_DRAW_RANGE then
								petports_navDrawSafely(world.debugPoint,
									{ ox + PETPORTS_NAV_CELL * 0.5, oy + PETPORTS_NAV_CELL * 0.5 },
									{ 110, 0, 110, 255 })
							end
						end
					end
				end
			end
		end
	end

	local wallCount = 0
	for tile in pairs(self.petportsNavForbidden or {}) do
		wallCount = wallCount + 1
		local tx, ty = string.match(tile, "^(-?%d+),(-?%d+)$")
		if tx ~= nil and math.abs(tonumber(tx) - here[1]) <= NAV_DRAW_RANGE
		   and math.abs(tonumber(ty) - here[2]) <= NAV_DRAW_RANGE then
			petports_navDrawSafely(world.debugPoint, { tonumber(tx) + 0.5, tonumber(ty) + 0.5 }, "red")
		end
	end

	local mine = 0
	for _, entry in pairs(self.petportsNavBoundsLocal or {}) do
		mine = mine + 1
		if math.abs(entry.ox - here[1]) <= NAV_DRAW_RANGE
		   and math.abs(entry.oy - here[2]) <= NAV_DRAW_RANGE then
			for offset, name in pairs(entry.m) do
				local dx, dy = string.match(offset, "^(%d+),(%d+)$")
				if dx ~= nil and name ~= "air" then
					local colour = (name == "water" and "cyan")
						or (name == "poison" and "yellow") or "white"
					petports_navDrawSafely(world.debugPoint,
						{ entry.ox + tonumber(dx) + 0.5, entry.oy + tonumber(dy) + 0.5 }, colour)
				end
			end
		end
	end

	local route = self.petportsNavLastRoute
	local routeText = "route: none asked"
	if route ~= nil then
		if route.path ~= nil then
			local previous = nil
			for _, key in ipairs(route.path) do
				local at = petports_navCachedAnchor(key)
				if at == nil then
					local ox, oy = petports_navKeyOrigin(key)
					if ox ~= nil then at = { ox + PETPORTS_NAV_CELL * 0.5, oy + PETPORTS_NAV_CELL * 0.5 } end
				end
				if previous ~= nil and at ~= nil then
					petports_navDrawSafely(world.debugLine, previous, at, "white")
				end
				previous = at or previous
			end
			if route.waypoint ~= nil then
				petports_navDrawSafely(world.debugPoint, route.waypoint, "magenta")
				petports_navDrawSafely(world.debugLine, here, route.waypoint, "magenta")
			end
			routeText = string.format("route %s -> %s: %s hop(s), leg %s",
				tostring(route.from), tostring(route.to), sb.printJson(#route.path - 1),
				tostring(route.leg))
		else
			local why = tostring(route.why)
			if #why > NAV_DRAW_WHY_CHARS then why = string.sub(why, 1, NAV_DRAW_WHY_CHARS) .. ".." end
			routeText = string.format("NO ROUTE %s -> %s: %s",
				tostring(route.from), tostring(route.to), why)
		end
	end

	local note = self.petportsNavSurveyNote
	local surveyText = "survey: no top-up yet"
	if note ~= nil then
		surveyText = string.format(
			"survey %s seed %s r%s cov %s gnd %s anchor %s -> %s | cand %s started %s refused %s %s",
			tostring(note.side), tostring(note.seed), tostring(note.seedRadius),
			tostring(note.seedCoverage), tostring(note.seedGrounded), tostring(note.seedAnchor),
			note.seedOk and "SEED" or "no seed",
			tostring(note.candidates or 0), tostring(note.started or 0),
			tostring(note.refused or 0), tostring(note.refusal or ""))
	end

	local lines = {
		{ surveyText, "cyan" },
		{ string.format("graph %s: %s cell(s) %s edge(s), walls %s, own bounds %s, sweeps %s",
			(graph ~= nil and graph.profile == profile) and "ready" or "MISSING",
			sb.printJson(cells), sb.printJson(edges), sb.printJson(wallCount),
			sb.printJson(mine), sb.printJson(petports_navSweepCount())), "cyan" },
		{ routeText, route ~= nil and route.path ~= nil and "green" or "red" }
	}

	for i, entry in ipairs(lines) do
		petports_navDrawSafely(world.debugText, entry[1],
			{ here[1] + 2, here[2] + 2.2 - (line + i - 1) * 0.7 }, entry[2])
	end
end

-- Returns the stored boundary records within draw range, cached.
function petports_navBoundsInRange(here)
	local now = world.time()

	if self.petportsNavBoundsDraw ~= nil
	   and (now - (self.petportsNavBoundsDrawAt or 0)) <= NAV_BOUNDS_DRAW_REFRESH then
		return self.petportsNavBoundsDraw
	end

	local out = {}
	local ok, registry = pcall(world.getProperty, NAV_BOUNDS)

	if ok and type(registry) == "table" then
		for bucket in pairs(registry) do
			local okIndex, index = pcall(world.getProperty, petports_navBoundsIndexProperty(bucket))
			if okIndex and type(index) == "table" then
				for cellKey in pairs(index) do
					local bx, by = string.match(cellKey, "^(-?%d+),(-?%d+)$")
					if bx ~= nil then
						local ox, oy = petports_navCellOrigin(tonumber(bx), tonumber(by))
						if math.abs(ox - here[1]) <= NAV_DRAW_RANGE
						   and math.abs(oy - here[2]) <= NAV_DRAW_RANGE then
							local okRec, record = pcall(world.getProperty,
								petports_navBoundsCellProperty(bucket, cellKey))
							if okRec and type(record) == "table" and record.g == petports_navGenNow() then
								table.insert(out, {
									bucket = bucket, ox = ox, oy = oy, record = record
								})
							end
						end
					end
				end
			end
		end
	end

	self.petportsNavBoundsDraw = out
	self.petportsNavBoundsDrawAt = now
	return out
end

-- Draws the dive, wade and exit bridges near the unit, and the queued cells.
function petports_navDrawBridges(here)
	-- Returns whether a point is inside draw range.
	local function near(p)
		return type(p) == "table"
			and math.abs(p[1] - here[1]) <= NAV_DRAW_RANGE
			and math.abs(p[2] - here[2]) <= NAV_DRAW_RANGE
	end

	-- Draws a cross at a position.
	local function cross(position, colour)
		local size = 0.25
		petports_navDrawSafely(world.debugLine,
			{ position[1] - size, position[2] }, { position[1] + size, position[2] }, colour)
		petports_navDrawSafely(world.debugLine,
			{ position[1], position[2] - size }, { position[1], position[2] + size }, colour)
	end

	for _, bridge in pairs(self.petportsNavBridgesLocal or {}) do
		if bridge.k == "dive" and near(bridge.a) then
			petports_navDrawSafely(world.debugLine, bridge.a, bridge.b, "green")
			cross(bridge.a, "green")
			cross(bridge.b, "green")
		elseif bridge.k == "wade" then
			local fx, fy = string.match(bridge.fromKey, "^(-?%d+),(-?%d+)$")
			local tx, ty = string.match(bridge.toKey, "^(-?%d+),(-?%d+)$")
			if fx ~= nil and tx ~= nil then
				local a = petports_navWithSide(false, petports_navAnchor, tonumber(fx), tonumber(fy), false)
				local b = petports_navWithSide(true, petports_navAnchor, tonumber(tx), tonumber(ty), true)
				if a ~= nil and b ~= nil and near(a) then
					petports_navDrawSafely(world.debugLine, a, b, "green")
					cross(a, "green")
				end
			end
		elseif bridge.k == "exit" and near(bridge.a) then
			local tx, ty = string.match(bridge.toKey, "^(-?%d+),(-?%d+)$")
			local land = tx ~= nil and petports_navWithSide(false, petports_navAnchor, tonumber(tx), tonumber(ty), false) or nil
			local colour = bridge.r and "orange" or "red"
			cross(bridge.a, colour)
			if land ~= nil then petports_navDrawSafely(world.debugLine, bridge.a, land, colour) end
		end
	end

	local probe = self.petportsNavBridgeExit
	if probe ~= nil and near(probe.from) then
		petports_navDrawSafely(world.debugLine, probe.from, probe.to, "magenta")
	end

	-- Draws a grey cross at a queued cell's centre.
	local function pendingCross(key)
		local cx, cy = string.match(key, "^(-?%d+),(-?%d+)$")
		if cx == nil then return end
		local ox, oy = petports_navCellOrigin(tonumber(cx), tonumber(cy))
		local centre = { ox + PETPORTS_NAV_CELL / 2, oy + PETPORTS_NAV_CELL / 2 }
		if near(centre) then cross(centre, "gray") end
	end

	for key in pairs(self.petportsNavBridgeQueue or {}) do pendingCross(key) end
	for key in pairs(self.petportsNavBridgeRetry or {}) do pendingCross(key) end
end

-- Draws the liquid tiles of every boundary record in range.
function petports_navDrawBounds(here)
	for _, entry in ipairs(petports_navBoundsInRange(here)) do
		local record = entry.record

		if type(record.m) == "table" then
			for offset, name in pairs(record.m) do
				local dx, dy = string.match(offset, "^(%d+),(%d+)$")
				if dx ~= nil and name ~= "air" then
					local colour = (name == "water" and "cyan")
						or (name == "poison" and "yellow") or "white"
					petports_navDrawSafely(world.debugPoint,
						{ entry.ox + tonumber(dx) + 0.5, entry.oy + tonumber(dy) + 0.5 }, colour)
				end
			end
		end
	end
end

-- Flips nav debug drawing and returns the new state.
function petports_navDebugToggle()
	PETPORTS_NAV_DEBUG = not PETPORTS_NAV_DEBUG
	petports_navDebugBroken = false

	sb.logInfo("NAV debug draw %s", PETPORTS_NAV_DEBUG and "ON" or "OFF")

	return PETPORTS_NAV_DEBUG
end

-- Draws the level progress, the live graph, the swept cells, the running sweeps and the running probes.
function petports_navDebugDraw()
	if not PETPORTS_NAV_DEBUG then return end

	local levels = petports_navLevelProgress()
	local here = mcontroller.position()
	local line = 0

	for _, level in ipairs(levels) do
		if level.percent < 100 then
			petports_navDrawSafely(world.debugText,
				string.format("nav L%s  %s pct  %s/%s",
					tostring(level.tiles),
					tostring(math.floor(level.percent + 0.5)),
					tostring(level.complete), tostring(level.blocks)),
				{ here[1] + 2, here[2] + 2.2 - line * 0.7 }, "cyan")

			line = line + 1
		end
	end

	petports_navDrawLive(here, line)

	petports_navDrawBounds(here)
	petports_navDrawBridges(here)

	local sweptColour = petports_freeMover() and "blue" or "green"
	local now = world.time()

	for _, point in ipairs(petports_navSweptPoints()) do
		if math.abs(point[1] - here[1]) <= NAV_DRAW_RANGE
		   and math.abs(point[2] - here[2]) <= NAV_DRAW_RANGE then
			local fresh = (now - (point.at or 0)) <= NAV_DRAW_FRESH
			petports_navDrawSafely(world.debugPoint, point,
				fresh and "magenta" or petports_navRadiusColour(point.radius))
		end
	end

	for _, sweep in pairs(self.petportsNavSweeps or {}) do
		local sx, sy = string.match(tostring(sweep.cellKey), "^(-?%d+),(-?%d+)$")
		if sx ~= nil then
			local ox, oy = petports_navCellOrigin(tonumber(sx), tonumber(sy))
			local centre = { ox + PETPORTS_NAV_CELL * 0.5, oy + PETPORTS_NAV_CELL * 0.5 }
			petports_navDrawSafely(world.debugLine, here, centre, "green")
			petports_navDrawCell(tonumber(sx), tonumber(sy), "green")
			petports_navDrawSafely(world.debugText, "r" .. tostring(sweep.radius),
				{ ox, oy + PETPORTS_NAV_CELL + 0.3 }, "green")
		end
	end

	local probes = self.petportsNavProbes
	if probes == nil or next(probes) == nil then return end

	if not self.petportsNavDrewOnce then
		self.petportsNavDrewOnce = true
		sb.logInfo("NAV debug draw ACTIVE -- if nothing appears in game, "
			.. "the client needs debug rendering enabled (/debug)")
	end

	for slot, probe in pairs(probes) do
		petports_navDrawCell(probe.fromCell[1], probe.fromCell[2], "magenta")
		petports_navDrawCell(probe.toCell[1], probe.toCell[2], "magenta")

		if probe.fromAnchor ~= nil and probe.toAnchor ~= nil then
			petports_navDrawSafely(world.debugLine, probe.fromAnchor, probe.toAnchor,
				"yellow")
		end

		petports_navDrawPoint(probe.fromAnchor, "green")
		petports_navDrawPoint(probe.toAnchor, "red")

		local corner = NAV_LABEL_CORNERS[((slot - 1) % 4) + 1]

		local ox, oy = petports_navCellOrigin(probe.toCell[1], probe.toCell[2])

		petports_navDrawSafely(world.debugText, tostring(probe.ticks), {
			ox + corner[1] * PETPORTS_NAV_CELL,
			oy + corner[2] * PETPORTS_NAV_CELL
		}, "yellow")
	end
end


local NAV_CANDIDATE_SCAN = 60

local NAV_CANDIDATE_RINGS = 12

local NAV_CANDIDATE_FROMS = 200

local NAV_FRONTIER_CAP = 2000
local NAV_FRONTIER_HEAD = 32

local NAV_FRONTIER_REBUILD = 10.0

local NAV_CANDIDATE_CACHE = 2.0

-- Yields once a candidate scan has used the tick budget, then restarts the clock.
function petports_navCandYield(clock)
	if clock.began == nil then return end
	local now = petports_navTickClock()
	if now ~= nil and (now - clock.began) * 1000 >= NAV_TICK_BUDGET_MS then
		coroutine.yield()
		clock.began = petports_navTickClock()
	end
end

-- Returns the cells worth sweeping next, served from the cache or from a coroutine that rebuilds the list.
function petports_navCandidates(limit)
	local now = world.time()
	local freeMover = petports_freeMover()
	local sideKey = freeMover and "1" or "0"
	local cache = self.petportsNavCandCache
	self.petportsNavCandPending = false
	if cache ~= nil and cache.side == sideKey and (now - cache.at) < NAV_CANDIDATE_CACHE
	   and #cache.list > 0 then
		local sweptCells = petports_navIndexRead()[petports_navProfile()]
		local inSweep = {}
		for _, sweep in pairs(self.petportsNavSweeps or {}) do
			if type(sweep) == "table" and sweep.cellKey ~= nil then inSweep[sweep.cellKey] = true end
		end
		local out = {}
		local kept = {}
		for _, entry in ipairs(cache.list) do
			local radius = petports_navSweptRadiusIn(sweptCells, entry.key, now)
			if not inSweep[entry.key] and radius <= (entry.radius or 0) then
				table.insert(kept, entry)
				if limit == nil or #out < limit then table.insert(out, entry) end
			end
		end
		cache.list = kept
		if #out > 0 then return out end
	end

	local job = self.petportsNavCandJob
	if job == nil or job.side ~= sideKey or coroutine.status(job.co) == "dead" then
		job = { side = sideKey, co = coroutine.create(function() return petports_navCandidatesInner(NAV_FRONTIER_HEAD) end) }
		self.petportsNavCandJob = job
	end
	local okResume, list = coroutine.resume(job.co)
	if not okResume then
		sb.logInfo("NAV candidate recompute died: %s", tostring(list))
		self.petportsNavCandJob = nil
		return {}
	end
	if coroutine.status(job.co) ~= "dead" then
		self.petportsNavCandPending = true
		return {}
	end
	self.petportsNavCandJob = nil
	list = type(list) == "table" and list or {}
	self.petportsNavCandCache = { at = now, side = sideKey, list = list }
	if limit ~= nil and #list > limit then
		local out = {}
		for i = 1, limit do out[i] = list[i] end
		return out
	end
	return list
end

-- Builds the sweep candidate list from the unit's own cell, the seeds, the nearby graph and the frontier queue, yielding on the tick budget.
function petports_navCandidatesInner(limit)
	local clock = { began = coroutine.running() ~= nil and petports_navTickClock() or nil }
	local yieldEvery, yieldCount = 8, 0
	-- Yields on the tick budget every eighth call.
	local function candTick()
		yieldCount = yieldCount + 1
		if yieldCount % yieldEvery == 0 then petports_navCandYield(clock) end
	end
	local here = mcontroller.position()
	local cx, cy = petports_navCell(here)
	local profile = petports_navProfile()
	local mine = petports_navCellKey(cx, cy)

	local found = {}

	local sweptCells = petports_navIndexRead()[profile]
	local now = world.time()

	local mineRadius = petports_navSweptRadiusIn(sweptCells, mine, now)

	local freeMover = petports_freeMover()
	local grounded = freeMover or mcontroller.onGround()

	local seedX, seedY, seedKey = cx, cy, mine


	if freeMover and petports_navAnchor(cx, cy, freeMover) == nil then
		local best = nil

		for dx = -4, 4 do
			for dy = -4, 4 do
				local d = dx * dx + dy * dy

				if (best == nil or d < best)
				   and petports_navAnchor(cx + dx, cy + dy, freeMover) ~= nil then
					best = d
					seedX, seedY = cx + dx, cy + dy
				end
			end
		end

		seedKey = petports_navCellKey(seedX, seedY)
		mineRadius = petports_navSweptRadiusIn(sweptCells, seedKey, now)
	end

	local seedAnchor = petports_navAnchor(seedX, seedY, freeMover)
	local seedOk = mineRadius < petports_navFullRadius() and petports_navInCoverage(seedX, seedY)
		and grounded and seedAnchor ~= nil

	self.petportsNavSurveyNote = {
		side = freeMover and "f1" or "f0",
		seed = seedKey,
		seedRadius = mineRadius,
		seedCoverage = petports_navInCoverage(seedX, seedY),
		seedGrounded = grounded,
		seedAnchor = seedAnchor ~= nil,
		seedOk = seedOk,
		at = now
	}

	if seedOk then
		table.insert(found, {
			cx = seedX, cy = seedY, key = seedKey, distance = 0, radius = mineRadius
		})
	end

	local graph = petports_navGraphFor(profile)
	local seen = { [mine] = true, [seedKey] = true }

	for _, sweep in pairs(self.petportsNavSweeps or {}) do
		seen[sweep.cellKey] = true
	end

	self.petportsNavFrontier = self.petportsNavFrontier or {}
	local sideKey = freeMover and "1" or "0"
	self.petportsNavFrontier[sideKey] = self.petportsNavFrontier[sideKey] or {}
	local queue = self.petportsNavFrontier[sideKey]

	-- Adds an unswept in-coverage cell to the candidate list and to the frontier queue.
	local function consider(cellKey)
		if seen[cellKey] then return end
		seen[cellKey] = true

		local radius = petports_navSweptRadiusIn(sweptCells, cellKey, now)
		if radius >= petports_navFullRadius() then return end

		if radius <= 0 and queue[cellKey] == nil then queue[cellKey] = now end

		local bx, by = string.match(cellKey, "^(-?%d+),(-?%d+)$")
		if bx == nil then return end

		if radius <= 0 and not petports_navInCoverage(tonumber(bx), tonumber(by)) then
			return
		end

		local ox, oy = petports_navCellOrigin(tonumber(bx), tonumber(by))

		local dx = ox + PETPORTS_NAV_CELL * 0.5 - here[1]
		local dy = oy + PETPORTS_NAV_CELL * 0.5 - here[2]

		table.insert(found, {
			cx = tonumber(bx), cy = tonumber(by),
			key = cellKey,
			distance = dx * dx + dy * dy,
			radius = radius
		})
	end

	if freeMover and self.petportsNavSeeds ~= nil then
		for key, at in pairs(self.petportsNavSeeds) do
			if (now - at) > NAV_ANCHOR_TTL * 4
			   or petports_navSweptRadiusIn(sweptCells, key, now) >= petports_navFullRadius() then
				self.petportsNavSeeds[key] = nil
			else
				consider(key)
			end
		end
	end

	local sideSeeds = self.petportsNavSideSeeds
		and self.petportsNavSideSeeds[freeMover and "1" or "0"] or nil
	if sideSeeds ~= nil then
		for key, at in pairs(sideSeeds) do
			if (now - at) > NAV_ANCHOR_TTL * 4
			   or petports_navSweptRadiusIn(sweptCells, key, now) >= petports_navFullRadius() then
				sideSeeds[key] = nil
			else
				consider(key)
			end
		end
	end

	local blocks = petports_navGraphBlocks(graph)
	local ubx, uby = math.floor(cx / NAV_BLOCK_CELLS), math.floor(cy / NAV_BLOCK_CELLS)
	local scanned = 0
	local ring = 0
	local seenBlocks = 0

	local unswept, foundBefore = 0, 0

	-- Returns how many candidates found so far have never been swept.
	local function unsweptFound()
		for i = foundBefore + 1, #found do
			if (found[i].radius or 0) <= 0 then unswept = unswept + 1 end
		end
		foundBefore = #found
		return unswept
	end

	while unsweptFound() < NAV_CANDIDATE_SCAN and scanned < NAV_CANDIDATE_FROMS
	      and seenBlocks < blocks.count and ring <= NAV_CANDIDATE_RINGS do
		for by = uby - ring, uby + ring do
			for bx = ubx - ring, ubx + ring do
				if math.abs(bx - ubx) == ring or math.abs(by - uby) == ring then
					local bucket = blocks.map[bx .. "," .. by]
					if bucket ~= nil then
						seenBlocks = seenBlocks + 1
						for _, from in ipairs(bucket) do
							candTick()
							consider(from)
							for _, to in ipairs(graph.fine[from] or {}) do consider(to) end
							scanned = scanned + 1
						end
					end
				end
			end
		end
		ring = ring + 1
	end

	if next(queue) == nil
	   and (now - (self.petportsNavFrontierRebuiltAt or -1e9)) > NAV_FRONTIER_REBUILD then
		self.petportsNavFrontierRebuiltAt = now
		local added = 0
		for _, targets in pairs(graph.fine or {}) do
			candTick()
			for _, to in ipairs(targets) do
				if queue[to] == nil and petports_navSweptRadiusIn(sweptCells, to, now) <= 0 then
					local tx, ty = petports_navKeyCoords(to)
					if tx ~= nil and petports_navInCoverage(tx, ty) then
						queue[to] = now
						added = added + 1
					end
				end
			end
		end
		if added > 0 then
			sb.logInfo("NAV frontier rebuilt from the graph for %s: %s unswept target cell(s) queued",
				tostring(profile), sb.printJson(added))
		end
	end

	local queued = {}
	local purgeList = {}
	for key, at in pairs(queue) do purgeList[#purgeList + 1] = key end
	for _, key in ipairs(purgeList) do
		candTick()
		local at = queue[key]
		if at ~= nil then
			local radius = petports_navSweptRadiusIn(sweptCells, key, now)
			local qx, qy = petports_navKeyCoords(key)
			if radius > 0 or qx == nil or not petports_navInCoverage(qx, qy) then
				queue[key] = nil
			else
				queued[#queued + 1] = { key = key, at = at, cx = qx, cy = qy, radius = 0 }
			end
		end
	end
	if #queued > NAV_FRONTIER_CAP then
		table.sort(queued, function(a, b) return a.at > b.at end)
		for i = NAV_FRONTIER_CAP + 1, #queued do queue[queued[i].key] = nil end
		while #queued > NAV_FRONTIER_CAP do table.remove(queued) end
	end
	if seedOk and mineRadius <= 0 then
		queue[seedKey] = queue[seedKey] or now
		for i = #queued, 1, -1 do
			if queued[i].key == seedKey then table.remove(queued, i) end
		end
		table.insert(queued, 1, { key = seedKey, at = -1, cx = seedX, cy = seedY, radius = 0 })
	end
	if #queued > 0 then
		local head = {}
		for _, entry in ipairs(queued) do
			candTick()
			local placed = false
			for i = 1, #head do
				local h = head[i]
				if entry.at < h.at or (entry.at == h.at and entry.key < h.key) then
					table.insert(head, i, entry)
					placed = true
					break
				end
			end
			if not placed and #head < NAV_FRONTIER_HEAD then
				head[#head + 1] = entry
			elseif #head > NAV_FRONTIER_HEAD then
				table.remove(head)
			end
		end
		self.petportsNavFrontierCount = #queued
		return head
	end
	self.petportsNavFrontierCount = 0

	self.petportsNavWideRebuiltAt = self.petportsNavWideRebuiltAt or {}
	self.petportsNavWideList = self.petportsNavWideList or {}
	if (now - (self.petportsNavWideRebuiltAt[sideKey] or -1e9)) > NAV_FRONTIER_REBUILD then
		self.petportsNavWideRebuiltAt[sideKey] = now
		local wide = {}
		for cellKey, entry in pairs(sweptCells or {}) do
			candTick()
			if type(entry) == "table" then
				local radius = petports_navSweptRadiusIn(sweptCells, cellKey, now)
				if radius > 0 and radius < petports_navFullRadius() then
					local wx, wy = petports_navKeyCoords(cellKey)
					if wx ~= nil and petports_navInCoverage(wx, wy) then
						wide[#wide + 1] = cellKey
					end
				end
			end
		end
		self.petportsNavWideList[sideKey] = wide
	end
	for _, cellKey in ipairs(self.petportsNavWideList[sideKey] or {}) do
		candTick()
		consider(cellKey)
	end

	-- Orders candidates by swept radius, then distance, then key.
	local function before(a, b)
		if a.radius ~= b.radius then return a.radius < b.radius end
		if a.distance ~= b.distance then return a.distance < b.distance end
		return a.key < b.key
	end

	if limit ~= nil and #found > limit then
		local best = {}

		for _, entry in ipairs(found) do
			candTick()
			local placed = false

			for i = 1, #best do
				if before(entry, best[i]) then
					table.insert(best, i, entry)
					placed = true
					break
				end
			end

			if not placed and #best < limit then
				table.insert(best, entry)
			elseif #best > limit then
				table.remove(best)
			end
		end

		return best
	end

	table.sort(found, before)
	return found
end

-- Returns the cell to sweep next, or a reason there is none.
function petports_navNextCell(freeMover)
	local candidates = petports_navCandidates(1)
	if #candidates == 0 then return nil, nil, "no unswept cell in the graph" end
	return candidates[1].cx, candidates[1].cy, candidates[1].key
end

local NAV_CLAIM_ATTEMPTS = 8

local NAV_PURGE_PER_PASS = 4

-- Drops a few stale cells that fell outside coverage, with their edges and index entries.
function petports_navPurgeDeadzonesInner(profile)
	local index = petports_navIndexRead()
	local cells = index[profile]

	if type(cells) ~= "table" then return 0 end

	local now = world.time()
	local dropped = 0
	local gone = {}

	for cellKey, entry in pairs(cells) do
		if dropped >= NAV_PURGE_PER_PASS then break end

		local bx, by = string.match(cellKey, "^(-?%d+),(-?%d+)$")
		local sweptAt = petports_navIndexEntry(entry)

		if bx ~= nil and sweptAt ~= nil
		   and (now - sweptAt) > NAV_SWEEP_TTL
		   and not petports_navInCoverage(tonumber(bx), tonumber(by)) then

			cells[cellKey] = nil
			gone[#gone + 1] = cellKey
			dropped = dropped + 1
		end
	end

	if dropped > 0 then
		local byChunk = {}
		for _, cellKey in ipairs(gone) do
			local ck = petports_navChunk.of(cellKey)
			if ck ~= nil then
				byChunk[ck] = byChunk[ck] or {}
				byChunk[ck][cellKey] = {}
			end
		end
		for ck, updates in pairs(byChunk) do petports_navChunk.edgesApply(profile, ck, updates, true) end
		petports_navChunk.indexDrop(profile, gone)
		self.petportsNavGraph = nil

		sb.logInfo("NAV purged %s stale out-of-coverage cell(s) for %s",
			sb.printJson(dropped), tostring(profile))
	end

	return dropped
end

-- Purges stale out-of-coverage cells inside a profiler section.
function petports_navPurgeDeadzones(profile)
	petports_profBegin("purge")
	local r = petports_navPurgeDeadzonesInner(profile)
	petports_profEnd("purge")
	return r
end

local NAV_TICK_INTERVAL = 0.0

local NAV_IDLE_INTERVAL = 2.0
local NAV_IDLE_TICK_INTERVAL = 2.0
local NAV_TOPUP_INTERVAL = 0.25

PETPORTS_PROFILE = true

local PROF_REPORT_INTERVAL = 5.0
local PROF_WORLD_FUNCTIONS = {
	"rectTileCollision", "lineTileCollision", "pointTileCollision",
	"liquidAt", "getProperty", "setProperty", "debugLine", "debugText",
	"debugPoint", "entityQuery", "material", "platformerPathStart"
}

petports_profSurvey = {}

-- Adds to a survey counter.
function petports_profCount(name, by)
	petports_profSurvey[name] = (petports_profSurvey[name] or 0) + (by or 1)
end

petports_profClock = nil
petports_profSections = {}
petports_profOpen = {}
petports_profWorldCounts = {}
petports_profTickStart = nil
petports_profTickMax = 0
petports_profReportAt = nil
petports_profInstalled = false

-- Returns the profiler clock, or nil when there is none.
function petports_profNow()
	if petports_profClock == nil then return nil end
	local ok, t = pcall(petports_profClock)
	if ok and type(t) == "number" then return t end
	return nil
end

petports_profGcTuned = false

-- Flips the garbage collector between the tuned and the default pause and step multiplier.
function petports_gcTune()
	if type(collectgarbage) ~= "function" then
		sb.logInfo("GC tune: collectgarbage is not available")
		return false
	end

	petports_profGcTuned = not petports_profGcTuned

	local pause = petports_profGcTuned and 100 or 200
	local stepmul = petports_profGcTuned and 400 or 200

	local okP = pcall(collectgarbage, "setpause", pause)
	local okS = pcall(collectgarbage, "setstepmul", stepmul)

	sb.logInfo("GC tune %s: setpause %s (%s), setstepmul %s (%s)",
		petports_profGcTuned and "ON" or "OFF (defaults)", tostring(pause),
		okP and "ok" or "refused", tostring(stepmul), okS and "ok" or "refused")

	return petports_profGcTuned
end

-- Returns the Lua heap size in kilobytes, or nil.
function petports_profHeapKb()
	if type(collectgarbage) ~= "function" then return nil end
	local ok, kb = pcall(collectgarbage, "count")
	if ok and type(kb) == "number" then return kb end
	return nil
end

petports_profHeapLast = nil

-- Takes the clock and wraps the counted world functions, once.
function petports_profInstall()
	if petports_profInstalled then return end
	petports_profInstalled = true

	local kb = petports_profHeapKb()
	sb.logInfo("PROFILE heap: %s", kb ~= nil
		and (tostring(math.floor(kb)) .. " KB, collectgarbage available")
		or "collectgarbage NOT available")

	if type(os) == "table" and type(os.clock) == "function" then
		petports_profClock = os.clock
	end

	local counted = 0

	for _, name in ipairs(PROF_WORLD_FUNCTIONS) do
		local original = world[name]

		if type(original) == "function" then
			local ok = pcall(function()
				world[name] = function(...)
					petports_profWorldCounts[name] = (petports_profWorldCounts[name] or 0) + 1
					return original(...)
				end
			end)

			if ok then
				petports_profWorldCounts[name] = 0
				counted = counted + 1
			end
		end
	end

	sb.logInfo("PROFILE installed: clock %s, %s of %s world functions counted",
		petports_profClock ~= nil and "os.clock" or "NONE (counts only)",
		sb.printJson(counted), sb.printJson(#PROF_WORLD_FUNCTIONS))
end

-- Flips profiling and returns the new state.
function petports_profToggle()
	PETPORTS_PROFILE = not PETPORTS_PROFILE
	sb.logInfo("PROFILE %s", PETPORTS_PROFILE and "ON" or "OFF")
	return PETPORTS_PROFILE
end

-- Marks the start of a profiler section.
function petports_profBegin(section)
	if not PETPORTS_PROFILE then return end
	petports_profOpen[section] = petports_profNow()
end

-- Closes a profiler section and adds its call count and time.
function petports_profEnd(section)
	if not PETPORTS_PROFILE then return end

	local started = petports_profOpen[section]
	petports_profOpen[section] = nil

	local entry = petports_profSections[section]
	if entry == nil then
		entry = { calls = 0, ms = 0, max = 0 }
		petports_profSections[section] = entry
	end

	entry.calls = entry.calls + 1

	local now = petports_profNow()
	if started ~= nil and now ~= nil then
		local ms = (now - started) * 1000
		entry.ms = entry.ms + ms
		if ms > entry.max then entry.max = ms end
	end
end

local PROF_STALL_MS = 250
petports_profTickEndAt = nil

-- Starts the tick timer and logs a stall when process time passed between ticks.
function petports_profTickBegin()
	if not PETPORTS_PROFILE then return end
	petports_profTickStart = petports_profNow()

	if petports_profTickEndAt ~= nil and petports_profTickStart ~= nil then
		local gap = (petports_profTickStart - petports_profTickEndAt) * 1000

		if gap >= PROF_STALL_MS then
			sb.logInfo("PROFILE STALL %s ms of process time between my ticks (clock %s)",
				tostring(math.floor(gap)), tostring(math.floor(petports_profTickStart * 1000)))
		end
	end
end

-- Closes the tick timer and logs the section, survey, heap and world-call report on an interval.
function petports_profTickEnd()
	if not PETPORTS_PROFILE then return end

	local now = petports_profNow()
	if petports_profTickStart ~= nil and now ~= nil then
		local ms = (now - petports_profTickStart) * 1000
		if ms > petports_profTickMax then petports_profTickMax = ms end
	end
	petports_profTickEndAt = now

	local t = world.time()
	petports_profReportAt = petports_profReportAt or (t + PROF_REPORT_INTERVAL)
	if t < petports_profReportAt then return end

	local span = PROF_REPORT_INTERVAL
	petports_profReportAt = t + PROF_REPORT_INTERVAL

	local parts = {}

	for name, entry in pairs(petports_profSections) do
		table.insert(parts, string.format("%s n=%s ms=%s max=%s",
			name, tostring(entry.calls),
			tostring(math.floor(entry.ms * 10 + 0.5) / 10),
			tostring(math.floor(entry.max * 10 + 0.5) / 10)))
	end
	table.sort(parts)

	local calls = {}
	for name, count in pairs(petports_profWorldCounts) do
		if count > 0 then
			table.insert(calls, { name = name, count = count })
		end
	end
	table.sort(calls, function(a, b) return a.count > b.count end)

	local callParts = {}
	for _, c in ipairs(calls) do
		table.insert(callParts, string.format("%s %s",
			c.name, tostring(math.floor(c.count / span + 0.5))))
	end

	local surveyParts = {}
	for name, count in pairs(petports_profSurvey) do
		table.insert(surveyParts, string.format("%s %s", name, tostring(count)))
	end
	table.sort(surveyParts)

	local heap = petports_profHeapKb()
	local heapText = "n/a"

	if heap ~= nil then
		local grew = petports_profHeapLast ~= nil and (heap - petports_profHeapLast) or 0
		petports_profHeapLast = heap
		heapText = string.format("%s KB (%s%s KB/5s)%s",
			tostring(math.floor(heap)), grew >= 0 and "+" or "",
			tostring(math.floor(grew)), petports_profGcTuned and " gc-tuned" or "")
	end

	local okType, unitType = pcall(monster.type)
	sb.logInfo("PROFILE unit %s (%s) | %ss | tick max %sms | heap %s | %s | survey: %s | world/s: %s",
		tostring(entity.id()), okType and tostring(unitType) or "?",
		tostring(span),
		tostring(math.floor(petports_profTickMax * 10 + 0.5) / 10),
		heapText,
		#parts > 0 and table.concat(parts, " | ") or "no sections",
		#surveyParts > 0 and table.concat(surveyParts, ", ") or "idle",
		#callParts > 0 and table.concat(callParts, ", ") or "none")

	petports_profSections = {}
	petports_profSurvey = {}
	petports_profTickMax = 0
	for name in pairs(petports_profWorldCounts) do petports_profWorldCounts[name] = 0 end
end

local NAV_SURVEY_CONCURRENT = 2

-- Returns whether this unit takes a survey turn this tick, staggering the units across the network.
function petports_navSurveyTurn()
	self.petportsNavUpdateCount = (self.petportsNavUpdateCount or 0) + 1

	local rects = self.petportsNetwork
	local ports = 1
	if type(rects) == "table" and #rects > 0 then ports = #rects end

	local units = tonumber(self.petportsNetworkUnits)
	if units ~= nil and units >= 1 then ports = units end

	local stride = math.ceil(ports / NAV_SURVEY_CONCURRENT)
	if stride <= 1 then return true end

	local phase = math.abs(entity.id()) % stride

	if (self.petportsNavUpdateCount + phase) % stride == 0 then return true end

	petports_profCount("strideSkip")
	return false
end

-- Starts sweeps on the best candidate cells, and reports the side complete when there are none.
function petports_navTopUp(ownerId)
	local candidates = petports_navCandidates(NAV_CLAIM_ATTEMPTS)
	local side = petports_freeMover() and "1" or "0"

	self.petportsNavComplete = self.petportsNavComplete or {}

	if #candidates == 0 then
		if self.petportsNavCandPending then
			self.petportsNavTimer = 0
			return
		end
		self.petportsNavTimer = NAV_IDLE_INTERVAL

		if not self.petportsNavComplete[side] and self.petportsNavGraphBuild == nil
		   and not self.petportsNavCandPending then
			self.petportsNavComplete[side] = true

			sb.logInfo("NAV survey COMPLETE for %s -- every known cell swept "
				.. "to radius %s",
				tostring(petports_navProfile()), sb.printJson(petports_navFullRadius()))
		end

		return "idle"
	end

	local started = false

	for _, cell in ipairs(candidates) do
		if petports_navSweepCount() >= PETPORTS_NAV_SWEEPS then break end

		local index = nil
		for i = 1, PETPORTS_NAV_SWEEPS do
			if (self.petportsNavSweeps or {})[i] == nil then index = i break end
		end

		if index == nil then break end

		local began, refusal = petports_navSweepStart(cell.cx, cell.cy, ownerId, index)

		local note = self.petportsNavSurveyNote
		if note ~= nil then
			note.candidates = #candidates
			if began then
				note.started = (note.started or 0) + 1
				note.last = cell.key
			else
				note.refused = (note.refused or 0) + 1
				note.refusal = tostring(refusal)
			end
		end

		if began then
			self.petportsNavComplete[side] = false
			started = true

			local radius = self.petportsNavSweeps[index].radius

			if self.petportsNavPassRadius ~= nil
			   and radius > self.petportsNavPassRadius then
				sb.logInfo("NAV pass at radius %s complete for %s -- "
					.. "sweeping at %s",
					sb.printJson(self.petportsNavPassRadius or 0),
					tostring(petports_navProfile()), sb.printJson(radius))
			end
			self.petportsNavPassRadius = radius

			local queued = self.petportsNavFrontierCount or 0
			local why
			if queued > 0 and cell.at ~= nil then
				why = string.format("frontier, queue %s, waited %ss", sb.printJson(queued),
					sb.printJson(math.floor(math.max(0, world.time() - cell.at))))
			elseif queued > 0 then
				why = string.format("frontier, queue %s", sb.printJson(queued))
			else
				why = "widening, queue empty"
			end
			sb.logInfo("NAV surveying %s at radius %s (sweep %s of %s; %s)",
				cell.key, sb.printJson(radius), sb.printJson(index),
				sb.printJson(PETPORTS_NAV_SWEEPS), why)
		end
	end

	if started then return true end

	return false
end

-- Runs the tick's nav work: builds, contradictions, drawing, boundary and bridge steps, then the sweeps and top-up.
function petports_navTickInner(dt, ownerId, searching)
	petports_navGenerationCheck()
	petports_navIndexTick()

	if self.petportsNavGraphBuild ~= nil then
		petports_navGraphFor(petports_navProfile())
	end
	if self.petportsNavMergedBuild ~= nil then
		petports_navMergedGraphFor()
	end

	petports_profBegin("contradict")
	petports_navContradictTick()
	petports_profEnd("contradict")
	local side = petports_freeMover() and "1" or "0"
	local sideDone = self.petportsNavComplete ~= nil and self.petportsNavComplete[side] == true
	local now = world.time()
	local idleDue = (now - (self.petportsNavIdleTickAt or -1e9)) >= NAV_IDLE_TICK_INTERVAL
	local exitsPending = self.petportsNavBridgeExit ~= nil
		or (type(self.petportsNavBridgeExits) == "table" and #self.petportsNavBridgeExits > 0)
	petports_profBegin("draw")
	petports_navDebugDraw()
	petports_profEnd("draw")

	if searching then
		return petports_navSweepCount() > 0
	end

	if not sideDone or idleDue or exitsPending then
		if idleDue then self.petportsNavIdleTickAt = now end
		petports_profBegin("flood")
		petports_navBoundsFloodTick()
		petports_profEnd("flood")
		petports_profBegin("bridge")
		petports_navBridgeTick()
		petports_profEnd("bridge")
	end

	self.petportsNavTimer = (self.petportsNavTimer or 0) - (dt or 0)
	if not petports_navSurveyTurn() then
		return petports_navSweepCount() > 0
	end

	petports_navSweepStep()

	if petports_navSweepCount() >= PETPORTS_NAV_SWEEPS then return true end

	if self.petportsNavTimer > 0 then return false end
	self.petportsNavTimer = NAV_TICK_INTERVAL

	local now = world.time()

	if self.petportsNavPurgeAt == nil or now >= self.petportsNavPurgeAt then
		self.petportsNavPurgeAt = now + 60.0
		petports_navPurgeDeadzones(petports_navProfile())
	end

	self.petportsNavTimer = NAV_TOPUP_INTERVAL

	local side = petports_navSurveySide()
	local result = petports_navWithSide(side, petports_navTopUp, ownerId)

	if result == "idle" and petports_gravitySwitchable() then
		self.petportsNavSideFlip = not self.petportsNavSideFlip
		result = petports_navWithSide(not side, petports_navTopUp, ownerId)
	end

	return result == true
end

-- Runs the nav tick inside the profiler.
function petports_navTick(dt, ownerId, searching)
	petports_profInstall()
	petports_profBegin("navTick")
	local result = petports_navTickInner(dt, ownerId, searching)
	petports_profEnd("navTick")
	return result
end

-- Packs a call's return values with their count.
function petports_profPack(...)
	return { n = select("#", ...), ... }
end

-- Returns a function that runs another inside a named profiler section.
function petports_profWrap(name, fn)
	return function(...)
		petports_profBegin(name)
		local results = petports_profPack(fn(...))
		petports_profEnd(name)
		return table.unpack(results, 1, results.n)
	end
end

petports_navNeighbours = petports_profWrap("neighbours", petports_navNeighbours)
petports_navFlush = petports_profWrap("flush", petports_navFlush)
petports_navProbeStep = petports_profWrap("probeStep", petports_navProbeStep)
petports_navReaches = petports_profWrap("reaches", petports_navReaches)
petports_navSweepStart = petports_profWrap("sweepStart", petports_navSweepStart)
petports_navSweepStep = petports_profWrap("sweepStep", petports_navSweepStep)
petports_navCandidates = petports_profWrap("candidates", petports_navCandidates)
petports_navNearestCell = petports_profWrap("nearestCell", petports_navNearestCell)
petports_navWaypoint = petports_profWrap("waypoint", petports_navWaypoint)

-- Returns the cell, swept, fully-swept, frontier and edge counts, with the cells being swept now.
function petports_navProgress()
	local profile = petports_navProfile()
	local graph = petports_navGraphFor(profile)

	local cells, swept, full = 0, 0, 0
	local seen = {}

	local sweptCells = petports_navIndexRead()[profile]
	local now = world.time()

	-- Counts a cell once into the total, swept and fully-swept tallies.
	local function count(cellKey)
		if seen[cellKey] then return end
		seen[cellKey] = true

		cells = cells + 1

		local radius = petports_navSweptRadiusIn(sweptCells, cellKey, now)
		if radius > 0 then swept = swept + 1 end
		if radius >= petports_navFullRadius() then full = full + 1 end
	end

	for from, tos in pairs(graph.fine) do
		count(from)
		for _, to in ipairs(tos) do count(to) end
	end

	local _, edges, reachable = petports_navStats()

	local sweeping = {}
	for _, sweep in pairs(self.petportsNavSweeps or {}) do
		table.insert(sweeping, sweep.cellKey)
	end
	table.sort(sweeping)

	return {
		profile = profile,
		cells = cells,
		swept = swept,
		full = full,
		frontier = cells - full,
		edges = edges,
		reachable = reachable,
		sweeping = sweeping
	}
end

-- Logs the cell, chunk, edge and byte counts of each profile's store and returns its total size in kilobytes.
function petports_navDumpStore()
	local index = petports_navIndexRead()
	local grand = 0

	for _, profile in ipairs(petports_navIndexProfiles()) do
		local cells = index[profile]
		local cellCount, shards, trues, falses, bytes = 0, 0, 0, 0, 0
		local kindless = 0

		local okIdx, idxJson = pcall(sb.printJson, cells)
		if okIdx then bytes = bytes + #idxJson end

		for _ in pairs(type(cells) == "table" and cells or {}) do
			cellCount = cellCount + 1
		end

		for chunkKey in pairs(petports_navChunk.registryRead(profile)) do
			shards = shards + 1
			local okI, idx = pcall(world.getProperty, petports_navChunk.indexProperty(profile, chunkKey))
			if okI and type(idx) == "table" then
				local okJ, json = pcall(sb.printJson, idx)
				if okJ then bytes = bytes + #json end
			end
			local okE, edgesRaw = pcall(world.getProperty, petports_navChunk.edgesProperty(profile, chunkKey))
			if okE and type(edgesRaw) == "table" then
				local okJ, json = pcall(sb.printJson, edgesRaw)
				if okJ then bytes = bytes + #json end
			end
			for _, edges in pairs(petports_navChunk.edgesDecode(profile, chunkKey)) do
				for _, entry in pairs(edges) do
					if entry.r == true then
						trues = trues + 1
						if entry.k == nil then kindless = kindless + 1 end
					else
						falses = falses + 1
					end
				end
			end
		end

		grand = grand + bytes

		sb.logInfo("NAV STORE %s: %s cell(s), %s chunk(s), %s true (%s without a kind) / %s false edge(s), %s KB",
			profile, sb.printJson(cellCount), sb.printJson(shards),
			sb.printJson(trues), sb.printJson(kindless), sb.printJson(falses),
			sb.printJson(math.floor(bytes / 1024)))
	end

	local okC, claims = pcall(world.getProperty, "petports_claims")
	local claimCount, claimBytes = 0, 0

	if okC and type(claims) == "table" then
		for _ in pairs(claims) do claimCount = claimCount + 1 end
		local okJ, json = pcall(sb.printJson, claims)
		if okJ then claimBytes = #json end
	end

	sb.logInfo("NAV STORE claims: %s entr(ies), %s KB | store total %s KB",
		sb.printJson(claimCount), sb.printJson(math.floor(claimBytes / 1024)),
		sb.printJson(math.floor((grand + claimBytes) / 1024)))

	return math.floor((grand + claimBytes) / 1024)
end

-- Deletes every nav property in the manifest, releases the survey claims, and bumps the store generation.
function petports_navWipe()
	local cleared = 0
	local roots = 0

	local ok, manifest = pcall(world.getProperty, NAV_MANIFEST)
	if not ok or type(manifest) ~= "table" then manifest = {} end

	manifest[NAV_INDEX] = true
	manifest[NAV_BOUNDS] = true

	local own = { petports_navProfile() }
	if petports_gravitySwitchable() then
		own[2] = petports_navWithSide(not petports_freeMover(), petports_navProfile)
		own[3] = petports_navBridgeProfile()
	end
	for _, profile in ipairs(own) do
		local okReg, perProfile = pcall(world.getProperty, petports_navIndexProperty(profile))
		if okReg and type(perProfile) == "table" then
			if type(perProfile.chunks) == "table" then
				for chunkKey in pairs(perProfile.chunks) do
					pcall(world.setProperty, petports_navChunk.indexProperty(profile, chunkKey), nil)
					pcall(world.setProperty, petports_navChunk.edgesProperty(profile, chunkKey), nil)
					cleared = cleared + 2
				end
			else
				for cellKey, entry in pairs(perProfile) do
					if type(entry) == "table" then
						pcall(world.setProperty, NAV_EDGES .. profile .. ":" .. cellKey, nil)
						cleared = cleared + 1
					end
				end
			end
		end
		pcall(world.setProperty, petports_navIndexProperty(profile), nil)
		cleared = cleared + 1
	end

	for root in pairs(manifest) do
		roots = roots + 1
		local enumerate = petports_navFamilies[root]
			or (root == NAV_INDEX and petports_navEdgeFamilyEnumerate)
			or (root == NAV_BOUNDS and petports_navBoundsFamilyEnumerate)

		if enumerate ~= nil then
			for _, name in ipairs(enumerate()) do
				pcall(world.setProperty, name, nil)
				cleared = cleared + 1
			end
		else
			sb.logInfo("NAV wipe: family %s is in the manifest but this build has no "
				.. "enumerator for it -- clearing its root only", tostring(root))
			pcall(world.setProperty, root, nil)
			cleared = cleared + 1
		end
	end

	pcall(world.setProperty, NAV_MANIFEST, nil)

	local claims = petports_claimsClearType ~= nil
		and petports_claimsClearType("nav") or 0

	local okGen, gen = pcall(world.getProperty, NAV_GEN)
	gen = (okGen and type(gen) == "number") and gen or 0
	pcall(world.setProperty, NAV_GEN, gen + 1)

	petports_navDropMemos(gen + 1)

	sb.logInfo("NAV wiped %s propert(ies) across %s famil(ies), %s survey claim(s); "
		.. "generation %s", sb.printJson(cleared), sb.printJson(roots),
		sb.printJson(claims), sb.printJson(gen + 1))

	return cleared
end


-- Probes every neighbour of the unit's own cell to completion and returns the verdict, store and reach counts.
function petports_navSelfTest(wipe)
	petports_navStampOnce()

	if wipe ~= false then petports_navWipe() end

	local here = mcontroller.position()
	local cx, cy = petports_navCell(here)
	local me = petports_navCellKey(cx, cy)
	local profile = petports_navProfile()
	local freeMover = petports_freeMover()

	local neighbours = petports_navNeighbours(cx, cy, freeMover)

	local yes, no, unknown, ticks = 0, 0, 0, 0

	for _, cell in ipairs(neighbours) do
		local verdict, spins = "searching", 0

		while verdict == "searching" and spins < 500 do
			verdict = petports_navProbeStep({ cx, cy }, { cell.cx, cell.cy }, 300)
			spins = spins + 1
		end

		ticks = ticks + spins

		if verdict == true then yes = yes + 1
		elseif verdict == false then no = no + 1
		else unknown = unknown + 1 end
	end

	local _, committed, _, pending = petports_navStats()

	local reach = {}
	for i = 1, math.min(6, #neighbours) do
		local ok = petports_navReaches(profile, me, neighbours[i].key)
		reach[neighbours[i].key] = tostring(ok)
	end

	local flushed = petports_navFlush()
	local _, settled, reachable, leftover = petports_navStats()

	return {
		cell = me,
		profile = profile,
		pairs = #neighbours,
		probed = { yes = yes, no = no, unknown = unknown, ticks = ticks },
		midSweep = { edges = committed, pending = pending },
		reachWhilePending = reach,
		afterFlush = { edges = settled, reachable = reachable,
			pending = leftover, flushed = flushed }
	}
end
