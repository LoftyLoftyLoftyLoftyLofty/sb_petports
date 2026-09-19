-- Port side of replanting: keeps the world-wide list of spots a consumed crop left behind, fetches the seed for one and hands out tasks to plant it. Harvesting adds to the list through petports_replantSet.

PETPORTS_CONSTANTS = PETPORTS_CONSTANTS or {}
PETPORTS_CONSTANTS.replant = PETPORTS_CONSTANTS.replant or {}

PETPORTS_CONSTANTS.replant.storeKey = "petports_replants"
PETPORTS_CONSTANTS.replant.sweepInterval = 5.0

-- Returns every replant intent.
function petports_replantsAll()
	return world.getProperty(PETPORTS_CONSTANTS.replant.storeKey) or {}
end

-- Returns the replant intent at a tile key.
function petports_replantGet(tileKey)
	return petports_replantsAll()[tileKey]
end

-- Records a replant intent at a position and returns its tile key.
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

	world.setProperty(PETPORTS_CONSTANTS.replant.storeKey, intents)
	return key
end

-- Drops the replant intents at a list of tile keys and returns how many went.
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

	world.setProperty(PETPORTS_CONSTANTS.replant.storeKey, intents)
	return cleared
end

-- Drops the replant intent at a tile key.
function petports_replantClear(tileKey, why)
	local intents = petports_replantsAll()
	if intents[tileKey] == nil then return false end

	sb.logInfo("PETPORTS replant intent CLEARED at %s: %s",
		tostring(tileKey), tostring(why or "no reason given"))

	intents[tileKey] = nil
	world.setProperty(PETPORTS_CONSTANTS.replant.storeKey, intents)
	return true
end

PETPORTS_REPLANT_SPACES_CACHE = {}

-- Returns the spaces a seed occupies, cached.
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
		sb.logInfo("PETPORT %s could not read spaces for %s -- assuming 1x2",
			stationUniqueId(), tostring(seedName))
		spaces = { {0, 0}, {0, 1} }
	else
		sb.logInfo("PETPORT %s footprint for %s: %s tile(s) %s",
			stationUniqueId(), tostring(seedName), sb.printJson(#spaces),
			sb.printJson(spaces))
	end

	PETPORTS_REPLANT_SPACES_CACHE[seedName] = spaces
	return spaces
end

-- Returns the tiles a seed would fill at a position.
function petports_replantSeedTiles(position, seedName)
	local anchor = { math.floor(position[1]), math.floor(position[2]) }
	local tiles = {}

	for _, space in ipairs(petports_replantSeedSpaces(seedName)) do
		table.insert(tiles, { anchor[1] + space[1], anchor[2] + space[2] })
	end

	return tiles
end

-- Returns whether an object covers any of a set of tiles.
function petports_replantObjectOccupies(objectId, tiles)
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
function petports_replantFootprintClear(position, seedName)
	local tiles = petports_replantSeedTiles(position, seedName)

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
		if petports_replantObjectOccupies(id, tiles) then
			sb.logInfo("PETPORT %s footprint for %s at %s BLOCKED by object %s",
				stationUniqueId(), tostring(seedName), sb.printJson(tiles),
				sb.printJson(id))
			return false
		end
	end

	return true
end

-- Returns whether the tile under a replant position is tilled.
function petports_replantGroundTilled(position)
	local under = world.mod({ position[1], position[2] - 1 }, "foreground")
	local at = world.mod({ position[1], position[2] }, "foreground")

	local info = petports_soilInfo(under)
	local tilled = info ~= nil and info.tilled


	if not tilled then
		sb.logInfo("PETPORT %s replant ground at %s: mod below is %s (tilled %s), "
			.. "mod at is %s -- not farmland",
			stationUniqueId(), sb.printJson(position), tostring(under),
			tostring(info ~= nil and info.tilled), tostring(at))
	end

	return tilled
end


-- Drops replant intents whose footprint filled, whose ground was untilled, or that no port covers.
function petports_replantSweep(dt)
	self.replantSweepTimer = (self.replantSweepTimer or 0) - dt
	if self.replantSweepTimer > 0 then return end
	self.replantSweepTimer = PETPORTS_CONSTANTS.replant.sweepInterval

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
		elseif petports_inNetworkCoverage(intent.position) then
			if not petports_replantFootprintClear(intent.position, intent.name) then
				petports_replantClear(key, "footprint occupied")
			elseif not petports_replantGroundTilled(intent.position) then
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

-- Returns the replant intent a carried seed matches, with the intent's key and the stack.
function petports_replantCarriedIntent()
	if self.petData == nil or self.petData.cargo == nil then return nil end

	local intents = petports_replantsAll()

	for _, stack in ipairs(self.petData.cargo) do
		for key, intent in pairs(intents) do
			if intent.name ~= nil and stack.name == intent.name
			   and intent.position ~= nil
			   and petports_inNetworkCoverage(intent.position) then
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
				petports_inNetworkCoverage(intent.position or {0, 0}) and "" or " (OUT OF RANGE)"))
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
function petports_replantWork()
	local key, intent = petports_replantCarriedIntent()
	if key == nil then return nil, "no carried seed matches an intent" end

	local failure = self.workFailures["replant:" .. key]
	if failure ~= nil and (failure["until"] or 0) > world.time() then
		return nil, string.format("replant at %s backed off until %s",
			tostring(key), sb.printJson(failure["until"]))
	end

	if not petports_replantFootprintClear(intent.position, intent.name) then
		petports_replantClear(key, "footprint occupied at dispatch")
		return nil, "intent tile is occupied"
	end

	local above = { intent.position[1] + 0.5, intent.position[2] + 1.5 }
	local suits, why = petports_targetSuits(above, nil)

	if not suits then
		petports_targetRefused("replant at " .. tostring(key), why)
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

-- Returns a task to fetch the seed a replant intent needs from storage.
function petports_replantWithdrawWork()
	if petports_replantCarriedIntent() ~= nil then
		return nil, "unit is already carrying a seed for an intent"
	end

	local intents = petports_replantsAll()
	local wanted = 0

	local wrongMedium = 0

	for key, intent in pairs(intents) do
		if intent.name ~= nil and intent.position ~= nil
		   and petports_inNetworkCoverage(intent.position) then
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
				and petports_claimFree(workId)
				and petports_claimFree("replant:" .. key)

			if free and not petports_targetEligible("replant at " .. tostring(key),
				placeAbove, nil) then
				wrongMedium = wrongMedium + 1
				free = false
			end

			if free then
				local containerId = petports_containerWithSeed(intent.name,
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

-- Spends the seed, counts the planting and clears the spot when a replant task reports done.
function petports_replantDone(task, report)
	if task.type ~= "replant" then return end

	spendSeed(task.seed)

	petports_metrics.add("planted", 1)

	petports_replantClear(task.target, "replanted")
end

petports_registerWork({
	name = "replant",
	order = 400,
	reasonOrder = 1410,
	reasonJoin = "replant",
	gate = function() return petports_workFarming("replant") end,
	generate = function() return petports_replantWork() end,
	tick = function(dt) return petports_replantSweep(dt) end,
	done = function(task, report) return petports_replantDone(task, report) end
})

petports_registerWork({
	name = "withdraw",
	order = 1800,
	reasonOrder = 1410,
	reasonJoin = "replant",
	gate = function() return petports_workFarming("replant") end,
	generate = function() return petports_replantWithdrawWork() end
})
