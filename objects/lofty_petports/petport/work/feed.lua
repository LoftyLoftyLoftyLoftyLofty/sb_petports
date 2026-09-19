-- Port side of feeding: nibbles treats out of the cargo, sends the unit for treats lying in coverage, and fetches treats from a feeder crate or an upcycler's output while it is hungry. The fuel gauge itself stays in the main file.

PETPORTS_CONSTANTS = PETPORTS_CONSTANTS or {}
PETPORTS_CONSTANTS.feed = PETPORTS_CONSTANTS.feed or {}

PETPORTS_CONSTANTS.feed.mealLimit = 32

-- Returns the treats worth fetching with their fuel value, the preferred flavor first.
function petports_feedTreatOrder(preferred)
	local wanted = {}

	if preferred ~= nil then
		local item = petports_flavorItem(preferred)
		if item ~= nil then
			table.insert(wanted, { name = item, value = PETPORTS_FUEL_PREFERRED })
		end
	end

	for _, flavor in ipairs(petports_flavors()) do
		local item = petports_flavorItem(flavor.id)
		if item ~= nil and flavor.id ~= preferred and flavor.preference ~= false then
			table.insert(wanted, { name = item, value = PETPORTS_FUEL_PLAIN })
		end
	end

	table.insert(wanted, { name = "petports_petfuel", value = PETPORTS_FUEL_PLAIN })

	return wanted
end

-- Returns whether an item is tagged as fuel.
function petports_feedIsTreat(name)
	if type(name) ~= "string" then return false end
	local ok, tagged = pcall(root.itemHasTag, name, "petports_fuel")
	return ok and tagged == true
end

-- Feeds the unit treats out of its own cargo while its fuel is low, preferring its own flavor.
function petports_feedNibble()
	if self.petId == nil or not world.entityExists(self.petId) then return end
	if not petportFuelWanted() then return end
	if self.petData == nil or type(self.petData.cargo) ~= "table" then return end
	if #self.petData.cargo == 0 then return end

	local preferred = petportUnitFlavor()
	local preferredItem = preferred ~= nil and petports_flavorItem(preferred) or nil

	local held = {}

	for _, stack in ipairs(self.petData.cargo) do
		if petports_feedIsTreat(stack.name) then
			table.insert(held, stack.name)
		end
	end

	if #held == 0 then return end

	table.sort(held, function(a, b)
		if a == preferredItem then return b ~= preferredItem end
		if b == preferredItem then return false end
		return a < b
	end)

	local meals = 0

	for _, name in ipairs(held) do
		local hungry = true

		while hungry and meals < PETPORTS_CONSTANTS.feed.mealLimit do
			local index, stack = nil, nil

			for i, candidate in ipairs(self.petData.cargo) do
				if candidate.name == name then
					index, stack = i, candidate
					break
				end
			end

			if stack == nil then break end

			local item = { name = stack.name, count = 1,
				parameters = stack.parameters }

			local okFeed, meal = pcall(world.callScriptedEntity, self.petId,
				"petports_feedFuel", item, true)

			if okFeed and type(meal) == "table"
			   and (tonumber(meal.amount) or 0) > 0 then
				countFed(meal.flavor)
				meals = meals + 1

				local count = (stack.count or 1) - 1
				if count <= 0 then
					table.remove(self.petData.cargo, index)
				else
					stack.count = count
				end
			else
				hungry = false
			end
		end

		if meals >= PETPORTS_CONSTANTS.feed.mealLimit then break end
	end

	if meals > 0 then
		sb.logInfo("PETPORT %s unit ate %s treat(s) out of its own cargo "
			.. "(%s stack(s) still held)",
			stationUniqueId(), sb.printJson(meals),
			sb.printJson(#self.petData.cargo))

		petports_flushCargo()
	end
end

-- Feeds the unit treats out of a crate until it is full or the meal limit is reached.
function petports_feedFromCrate(containerId, treatName, workId, slot)
	if containerId == nil or treatName == nil then return end
	if not world.entityExists(containerId) then return end

	local preferred = petportUnitFlavor()
	local order     = petports_feedTreatOrder(preferred)

	table.insert(order, 1, { name = treatName, value = PETPORTS_FUEL_PLAIN })

	local meals, seen = 0, {}

	for _, treat in ipairs(order) do
		if not seen[treat.name] then
			seen[treat.name] = true

			local hungry = true

			while hungry and meals < PETPORTS_CONSTANTS.feed.mealLimit do
				local item = { name = treat.name, count = 1 }

				local okTake, taken

				if slot == nil then
					okTake, taken = pcall(world.containerConsume, containerId, item)
					taken = okTake and taken == true
				else
					local okAt, at = pcall(world.containerItemAt, containerId, slot)

					if okAt and type(at) == "table" and at.name == treat.name then
						local okOne, one = pcall(world.containerTakeNumItemsAt,
							containerId, slot, 1)

						taken = okOne and type(one) == "table" and (one.count or 0) >= 1
					else
						taken = false
					end
				end

				if not taken then break end

				local okFeed, meal = pcall(world.callScriptedEntity, self.petId,
					"petports_feedFuel", item, true)

				if okFeed and type(meal) == "table"
						and (tonumber(meal.amount) or 0) > 0 then
					countFed(meal.flavor)
					meals = meals + 1
				else
					hungry = false

					local okBack, left

					if slot == nil then
						okBack, left = pcall(world.containerAddItems, containerId, item)
					else
						okBack, left = pcall(world.containerPutItemsAt, containerId, item, slot)
					end

					if not okBack or (type(left) == "table" and (left.count or 0) > 0) then
						sb.logError("PETPORT %s could not return %s to crate %s after a "
							.. "refused feed -- one treat lost", stationUniqueId(),
							tostring(treat.name), tostring(containerId))
					end

					break
				end
			end

			if not hungry then break end
		end
	end

	if meals == 0 then
		sb.logInfo("PETPORT %s fuel fetch %s: crate held nothing this unit would eat",
			stationUniqueId(), tostring(workId))
		return
	end

	sb.logInfo("PETPORT %s fed unit %s treat(s) from crate %s",
		stationUniqueId(), tostring(meals), tostring(containerId))
end

-- Returns a task to fetch a treat from a feeder crate or an upcycler's output while the unit is hungry.
function petports_feedFetchWork()
	if not petportFuelWanted() then
		return nil, "unit is above the fuel low-water mark"
	end

	local headroom = petportFuelHeadroom()
	if headroom == nil then return nil, "no fuel reading for the unit" end

	local preferred = petportUnitFlavor()
	local crates    = 0

	local wanted = petports_feedTreatOrder(preferred)

	for _, treat in ipairs(wanted) do

		if treat.value <= headroom then
			for _, behavior in ipairs({ "deposit", "restock" }) do
				for _, beacon in ipairs(petports_beaconsFor(behavior)) do
					if beacon.feeder ~= false and world.entityExists(beacon.id) then
						crates = crates + 1

						local workId = "fuelfetch:" .. tostring(beacon.id) .. ":" .. treat.name
						local failure = self.workFailures[workId]
						local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

						if not backedOff and petports_claimFree(workId) then
							local available = world.containerAvailable(beacon.id,
								{ name = treat.name, count = 1 })

							if type(available) == "number" and available >= 1
									and petports_servicePointNear("feeder " .. tostring(beacon.id),
										beacon.id, beacon.position, 4) ~= nil then
								return {
									id = workId,
									mediumVerified = true,
									type = "fuelfetch",
									port = stationUniqueId(),
									target = beacon.id,
									treat = treat.name,
									position = world.entityPosition(beacon.id)
								}
							end
						end
					end
				end
			end
		end
	end

	for _, treat in ipairs(wanted) do
		if treat.value <= headroom then
			for _, machine in ipairs(self.machines or {}) do
				if machine.kind == "upcycler" and machine.feeder
						and world.entityExists(machine.id) then

					crates = crates + 1

					local workId = "fuelfetch:" .. tostring(machine.id) .. ":" .. treat.name
					local failure = self.workFailures[workId]
					local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

					if not backedOff and petports_claimFree(workId) then
						local okAt, at = pcall(world.containerItemAt, machine.id,
							MACHINE_SLOT_OUTPUT)

						if okAt and type(at) == "table" and at.name == treat.name
								and (at.count or 0) >= 1
								and petports_servicePointNear("feeder " .. tostring(machine.id),
									machine.id, machine.position, 4) ~= nil then

							return {
								id = workId,
								mediumVerified = true,
								type = "fuelfetch",
								port = stationUniqueId(),
								target = machine.id,
								treat = treat.name,

								feedSlot = MACHINE_SLOT_OUTPUT,
								position = world.entityPosition(machine.id)
							}
						end
					end
				end
			end
		end
	end

	if crates == 0 then
		return nil, "no container or machine in the network is marked as a pet feeder"
	end

	return nil, string.format(
		"%s feeder source(s), none holding a treat this unit can use (headroom %s)",
		crates, tostring(math.floor(headroom)))
end

-- Returns a task to pick up the nearest treat lying in coverage while the unit is hungry.
function petports_feedGroundWork()
	if not petportFuelWanted() then
		return nil, "unit is above the fuel low-water mark"
	end

	if self.petData ~= nil and type(self.petData.cargo) == "table"
			and #self.petData.cargo > 0 then
		return nil, "hungry, but carrying a load -- putting that down first"
	end

	local rects = self.networkRects
	if rects == nil or #rects == 0 then rects = { petports_portCoverageRect() } end

	local from = entity.position()
	if self.petId ~= nil and world.entityExists(self.petId) then
		from = world.entityPosition(self.petId)
	end

	local best, bestDistance = nil, nil
	local seen = {}
	local treats, rejected = 0, { claimed = 0, backedOff = 0, gone = 0, medium = 0 }

	for _, area in ipairs(rects) do
		local found = world.entityQuery({ area[1], area[2] }, { area[3], area[4] }, {
			includedTypes = { "itemDrop" }
		})

		for _, dropId in ipairs(found or {}) do
			if not seen[dropId] then
				seen[dropId] = true

				local okItem, descriptor = pcall(world.itemDropItem, dropId)

				if okItem and type(descriptor) == "table" and petports_feedIsTreat(descriptor.name) then
					treats = treats + 1

					local workId = "drop:" .. tostring(dropId)
					local failure = self.workFailures[workId]
					local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

					if backedOff then
						rejected.backedOff = rejected.backedOff + 1
					elseif not petports_claimFree(workId) then
						rejected.claimed = rejected.claimed + 1
					elseif not world.entityExists(dropId) then
						rejected.gone = rejected.gone + 1
					else
						local position = world.entityPosition(dropId)

						if not petports_targetEligible("treat " .. tostring(dropId), position, dropId) then
							rejected.medium = rejected.medium + 1
						else
							local distance = world.magnitude(from, position)

							if bestDistance == nil or distance < bestDistance then
								best, bestDistance = dropId, distance
							end
						end
					end
				end
			end
		end
	end

	if best == nil then
		if treats == 0 then
			return nil, "hungry, and no treat on the ground in network coverage"
		end

		return nil, string.format(
			"hungry, %s treat(s) on the ground, none reachable: %s claimed, "
			.. "%s backed off, %s gone, %s in a medium this chassis cannot work in",
			treats, rejected.claimed, rejected.backedOff, rejected.gone,
			rejected.medium)
	end

	sb.logInfo("PETPORT %s hungry unit going for a treat on the ground at %s, "
		.. "%s away (%s treat(s) in coverage)",
		stationUniqueId(), sb.printJson(world.entityPosition(best)),
		sb.printJson(bestDistance), sb.printJson(treats))

	return {
		id = "drop:" .. best,
		mediumVerified = true,
		type = "collect",
		port = stationUniqueId(),
		target = best,
		position = world.entityPosition(best)
	}
end

-- Feeds the unit from the crate it reached when a fuelfetch task reports done.
function petports_feedDone(task, report)
	if task.type ~= "fuelfetch" then return end

	petports_feedFromCrate(task.target, task.treat, task.id, task.feedSlot)
end

petports_registerWork({
	name = "fuelGround",
	order = 200,
	idleLog = { key = "fuelGroundReason", label = "ground feed idle" },
	generate = function() return petports_feedGroundWork() end,
	workBeat = function() return petports_feedNibble() end,
	done = function(task, report) return petports_feedDone(task, report) end
})

petports_registerWork({
	name = "fuelFetch",
	order = 300,
	idleLog = { key = "fuelReason", label = "fuel fetch idle" },
	generate = function() return petports_feedFetchWork() end
})
