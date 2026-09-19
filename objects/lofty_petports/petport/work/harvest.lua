-- Port side of harvesting: finds ripe crops in coverage and hands out tasks to harvest them. Watering reads the crops this scan leaves in self.farmables.

PETPORTS_CONSTANTS = PETPORTS_CONSTANTS or {}
PETPORTS_CONSTANTS.harvest = PETPORTS_CONSTANTS.harvest or {}

PETPORTS_CONSTANTS.harvest.interval = 5.0
PETPORTS_CONSTANTS.harvest.stageBase = 0

-- Returns a crop's stage list from the object or its item config.
function petports_harvestStages(id)
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
function petports_harvestStageOf(stages)
	for index, stage in ipairs(stages) do
		if type(stage) == "table" and stage.harvestPool ~= nil then
			return index - 1 + PETPORTS_CONSTANTS.harvest.stageBase
		end
	end

	return nil
end

-- Scans the network for crops, returning each with its stage and whether it is ripe.
function petports_harvestScan()
	local rects = self.networkRects
	if rects == nil or #rects == 0 then rects = { petports_portCoverageRect() } end

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

				local ok, stage = pcall(world.farmableStage, id)

				if ok and type(stage) == "number" then
					local stages = petports_harvestStages(id)
					local harvestAt = stages ~= nil and petports_harvestStageOf(stages) or nil

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

-- Rescans the crops on an interval.
function petports_harvestRefresh(dt)
	self.harvestTimer = (self.harvestTimer or 0) - dt
	if self.harvestTimer > 0 then return end
	self.harvestTimer = PETPORTS_CONSTANTS.harvest.interval

	local found, objects = petports_harvestScan()
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

-- Returns a task to harvest the nearest ripe crop, or nil with a tally of why each was passed over.
function petports_harvestWork()
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

		elseif not petports_targetEligible("crop " .. tostring(crop.id), crop.position, crop.id) then
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

-- Counts a harvest when a harvest task reports done, and marks the spot for replanting when the crop was consumed.
function petports_harvestDone(task, report)
	if task.type ~= "harvest" then return end

	petports_metrics.add("harvested", 1)

	if not world.entityExists(task.target) and task.targetName ~= nil then
		petports_replantSet(task.position, task.targetName, stationUniqueId())
	end
end

petports_registerWork({
	name = "harvest",
	order = 1400,
	reasonOrder = true,
	gate = function() return petports_workFarming("harvest") end,
	generate = function() return petports_harvestWork() end,
	scanBeat = function(dt) return petports_harvestRefresh(dt) end,
	done = function(task, report) return petports_harvestDone(task, report) end
})
