-- Port side of tending livestock: finds harvestable animals in coverage and hands out tasks to tend them.

FAMILY_HELD.animal = true

PETPORTS_ANIMAL_TYPE_CACHE = {}

-- Returns whether a monster type can be harvested at all.
function petports_animalHarvestable(monsterType)
	if monsterType == nil then return false end

	local key = tostring(monsterType)
	if PETPORTS_ANIMAL_TYPE_CACHE[key] ~= nil then return PETPORTS_ANIMAL_TYPE_CACHE[key] end

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

	PETPORTS_ANIMAL_TYPE_CACHE[key] = harvestable
	return harvestable
end

-- Scans the network for harvestable farm animals.
function petports_animalScan()
	local rects = self.networkRects
	if rects == nil or #rects == 0 then rects = { petports_portCoverageRect() } end

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

				local monsterType = world.monsterType(id)

				if petports_animalHarvestable(monsterType) then
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

-- Rescans the farm animals on an interval.
function petports_animalRefresh(dt)
	self.animalTimer = (self.animalTimer or 0) - dt
	if self.animalTimer > 0 then return end
	self.animalTimer = HARVEST_INTERVAL

	local found, monsters = petports_animalScan()
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

-- Returns a task to harvest the nearest ready animal, or nil with a tally of why each was passed over.
function petports_animalWork()
	local animals = self.animals

	if animals == nil or #animals == 0 then
		return nil, "no farm animals in network coverage"
	end

	local from = entity.position()
	if self.petId ~= nil and world.entityExists(self.petId) then
		from = world.entityPosition(self.petId)
	end

	local best, bestDistance = nil, nil
	local rejected = { notReady = 0, claimed = 0, backedOff = 0, gone = 0,
		unreachable = 0 }

	for _, animal in ipairs(animals) do
		local workId = "animal:" .. animal.id
		local failure = self.workFailures[workId]
		local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

		if not world.entityExists(animal.id) then
			rejected.gone = rejected.gone + 1
		elseif not petports_animalHarvestable(animal.name) then
			rejected.notReady = rejected.notReady + 1
		else
			local ok, ready = pcall(world.callScriptedEntity, animal.id,
				"hasMonsterHarvest")

			if not (ok and ready == true) then
				rejected.notReady = rejected.notReady + 1
			elseif backedOff then
				rejected.backedOff = rejected.backedOff + 1
			elseif not petports_claimFree(workId) then
				rejected.claimed = rejected.claimed + 1
			else
				local position = world.entityPosition(animal.id)
				local distance = world.magnitude(from, position)

				if petports_portStandingPointNear(position, 4) == nil then
					rejected.unreachable = rejected.unreachable + 1
				elseif bestDistance == nil or distance < bestDistance then
					best = { id = animal.id, name = animal.name, position = position }
					bestDistance = distance
				end
			end
		end
	end

	if best == nil then
		local reason = string.format(
			"%s farm animal(s), none harvestable: %s not ready, %s claimed, "
			.. "%s backed off, %s gone, %s with nowhere this chassis can stand",
			#animals, rejected.notReady, rejected.claimed,
			rejected.backedOff, rejected.gone, rejected.unreachable)

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

-- Counts a tended animal when an animal task reports done.
function petports_animalDone(task, report)
	if task.type ~= "animal" then return end

	petports_metrics.add("livestock", 1)
end

petports_registerWork({
	name = "animal",
	order = 1500,
	reasonOrder = true,
	gate = function()
		return petports_workFarming("animals") and not petports_familyOnHold("animal")
	end,
	generate = function() return petports_animalWork() end,
	scanBeat = function(dt) return petports_animalRefresh(dt) end,
	done = function(task, report) return petports_animalDone(task, report) end
})
