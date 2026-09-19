-- Unit side of replanting: stands by the spot the task names and places the seed there.

PETPORTS_APPROACH_TYPES.replant = true

PETPORTS_REPLANT_SPACES_CACHE = {}

-- Returns a seed's occupied spaces, cached, assuming 1x2 when they cannot be read.
function petports_replantSeedSpaces(seedName)
	if seedName == nil then return { {0, 0}, {0, 1} } end
	if PETPORTS_REPLANT_SPACES_CACHE[seedName] ~= nil then return PETPORTS_REPLANT_SPACES_CACHE[seedName] end

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
		sb.logInfo("UNIT could not read spaces for %s -- assuming 1x2",
			tostring(seedName))
		spaces = { {0, 0}, {0, 1} }
	end

	PETPORTS_REPLANT_SPACES_CACHE[seedName] = spaces
	return spaces
end

-- Returns whether any object covers the tiles a seed would occupy at an anchor.
function petports_replantTileOccupied(anchor, seedName)
	local tiles = {}
	local lox, loy = anchor[1], anchor[2]
	local hix, hiy = lox, loy

	for _, space in ipairs(petports_replantSeedSpaces(seedName)) do
		local t = { anchor[1] + space[1], anchor[2] + space[2] }
		table.insert(tiles, t)

		lox = math.min(lox, t[1]); hix = math.max(hix, t[1])
		loy = math.min(loy, t[2]); hiy = math.max(hiy, t[2])
	end

	local candidates = world.entityQuery(
		{ lox - 1, loy - 1 }, { hix + 2, hiy + 2 },
		{ includedTypes = { "object" } })

	for _, id in ipairs(candidates or {}) do
		local spaces = world.objectSpaces(id)
		local origin = world.entityPosition(id)

		if spaces ~= nil and origin ~= nil then
			for _, space in ipairs(spaces) do
				local x = math.floor(origin[1]) + space[1]
				local y = math.floor(origin[2]) + space[2]

				for _, tile in ipairs(tiles) do
					if x == tile[1] and y == tile[2] then return true end
				end
			end
		end
	end

	return false
end

-- Places the seed at the task's tile once the unit has arrived, returning whether the task is over.
function petports_replantArrive(dt, stateData, task)
	local tile = task.tile or {
		math.floor(task.position[1]), math.floor(task.position[2])
	}

	if petports_replantTileOccupied(tile, task.seed) then
		petports_taskReport(stateData, "failed", string.format(
			"footprint for %s at %s is occupied -- not planting",
			tostring(task.seed), sb.printJson(tile)))
		return true
	end

	local ok, placed = pcall(world.placeObject, task.seed, tile, 1)

	sb.logInfo("UNIT replant at %s: placeObject(%s) ok %s returned %s",
		sb.printJson(tile), tostring(task.seed), tostring(ok), tostring(placed))

	if petports_replantTileOccupied(tile, task.seed) then
		petports_taskReport(stateData, "done",
			"planted " .. tostring(task.seed) .. " at " .. sb.printJson(tile))
		return true
	end

	petports_taskReport(stateData, "failed", string.format(
		"placeObject(%s) at %s left nothing there -- untilled ground, "
		.. "or placement refused",
		tostring(task.seed), sb.printJson(tile)))
	return true
end

petports_taskArrive.replant = function(dt, stateData, task)
	return petports_replantArrive(dt, stateData, task)
end
