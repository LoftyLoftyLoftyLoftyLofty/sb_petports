-- Port side of watering: finds dry tilled runs under the crops the harvest scan left in self.farmables, fetches water for them and hands out tasks to pour it.

PETPORTS_CONSTANTS = PETPORTS_CONSTANTS or {}
PETPORTS_CONSTANTS.water = PETPORTS_CONSTANTS.water or {}

PETPORTS_CONSTANTS.water.carry = 10
PETPORTS_CONSTANTS.water.carryHydrated = 30
PETPORTS_CONSTANTS.water.runReach = 32

-- Returns how much water the unit carries, raised by a hydrator.
function petports_waterCarry()
	if petportHydrator() then return PETPORTS_CONSTANTS.water.carryHydrated end
	return PETPORTS_CONSTANTS.water.carry
end

-- Returns the unbroken run of dry tilled tiles reaching out from an anchor, and the liquids they take.
function petports_waterRunFrom(anchor)
	-- Returns the tilled soil at a tile inside coverage, or nil.
	local function farmlandAt(tile)
		if not petports_inNetworkCoverage({ tile[1] + 0.5, tile[2] + 0.5 }) then
			return nil
		end

		local modName = world.mod({ tile[1], tile[2] }, "foreground")
		if modName == nil then return nil end

		local info = petports_soilInfo(modName)
		if info == nil or not info.tilled then return nil end

		return { mod = tostring(modName), dry = info.dry, wants = info.wants }
	end

	local ordered = { anchor }

	for direction = -1, 1, 2 do
		for step = 1, PETPORTS_CONSTANTS.water.runReach do
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
function petports_waterRuns()
	local runs = {}
	local seen = {}

	for _, crop in ipairs(self.farmables or {}) do
		if world.entityExists(crop.id) then
			local position = world.entityPosition(crop.id)

			local tile = { math.floor(position[1]), math.floor(position[2]) - 1 }
			local key = petports_tileKey(tile)

			if not seen[key] then
				local run = petports_waterRunFrom(tile)

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
function petports_waterCarriedFor(run)
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
function petports_waterRunWorkable(run, tile)
	if run == nil or tile == nil then return false end

	return petports_targetEligible("water run " .. tostring(run.key),
		{ tile[1] + 0.5, tile[2] + 1.5 }, nil)
end

-- Returns a task to water a run from its nearer end, as far as the carried water reaches.
function petports_waterWork()
	local runs = petports_waterRuns()
	if #runs == 0 then return nil, "no dry soil under any crop in coverage" end

	for _, run in ipairs(runs) do
		local workId = "water:" .. tostring(run.key)
		local failure = self.workFailures[workId]
		local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

		local stack, want = petports_waterCarriedFor(run)

		if stack ~= nil and not backedOff and petports_claimFree(workId) then
			local carried = math.min(stack.count or 1, petports_waterCarry())
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

			if petports_waterRunWorkable(run, runHead) then
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

-- Returns a task to fetch water from a beacon for the first dry run the unit can reach.
function petports_waterWithdrawWork()
	local runs = petports_waterRuns()
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
		if petports_waterCarriedFor(run) == nil then
			local workId = "fetchwater:" .. tostring(run.key)
			local failure = self.workFailures[workId]
			local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

			local reachableEnd = petports_waterRunWorkable(run, run.tiles[1])
				or petports_waterRunWorkable(run, run.tiles[#run.tiles])

			if not backedOff and reachableEnd and petports_claimFree(workId)
			   and petports_claimFree("water:" .. tostring(run.key)) then
				local wanted = math.min(#run.tiles, petports_waterCarry())

				for _, want in ipairs(run.wants) do
					for _, beacon in ipairs(sources) do
						if world.entityExists(beacon.id) then
							local available = world.containerAvailable(beacon.id,
								{ name = want.item, count = 1 })

							if type(available) == "number" and available >= 1
								and petports_servicePointNear("crate " .. tostring(beacon.id),
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

-- Spends the water poured and counts the tiles when a water task reports done.
function petports_waterDone(task, report)
	if task.type ~= "water" then return end

	local watered = tonumber(report.watered) or 0

	for _ = 1, watered do
		spendSeed(task.item)
	end

	petports_metrics.add("watered", watered)

	sb.logInfo("PETPORT %s watering finished: %s tile(s), %s %s spent",
		stationUniqueId(), sb.printJson(watered), sb.printJson(watered),
		tostring(task.item))
end

petports_registerWork({
	name = "water",
	order = 500,
	reasonOrder = 1420,
	reasonJoin = "water",
	gate = function() return petports_workFarming("water") end,
	generate = function() return petports_waterWork() end,
	done = function(task, report) return petports_waterDone(task, report) end
})

petports_registerWork({
	name = "withdrawWater",
	order = 1900,
	reasonOrder = 1420,
	reasonJoin = "water",
	gate = function() return petports_workFarming("water") end,
	generate = function() return petports_waterWithdrawWork() end
})
