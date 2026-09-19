-- Port side of the two machine hauling jobs. The entry named fuel clears an upcycler's output slot into a deposit or restock beacon; the entry named drain moves over-quota stock out of storage into an upcycler. The slot-room helpers they share with loading stay in the main file.

PETPORTS_CONSTANTS = PETPORTS_CONSTANTS or {}
PETPORTS_CONSTANTS.machines = PETPORTS_CONSTANTS.machines or {}

PETPORTS_CONSTANTS.machines.slotOutput = 2
PETPORTS_CONSTANTS.machines.fuelItem = "petports_petfuel"
PETPORTS_CONSTANTS.machines.fuelTag = "petports_fuel"

-- Returns a task to move over-quota stock out of storage into the upcycler with the most input room.
function petports_machinesDrainWork()
	if self.petData == nil then return nil end
	if self.petData.cargo ~= nil and #self.petData.cargo > 0 then return nil end

	local sources = petports_beaconsFor("deposit")
	if #sources == 0 then return nil, "no deposit beacon to drain from" end

	local overQuota = 0
	local dribbled = 0

	local ranked = {}

	for _, machine in ipairs(self.machines or {}) do
		if machine.kind == "upcycler" and machine.enabled
				and world.entityExists(machine.id) then

			local reachable = petports_servicePointNear("upcycler " .. tostring(machine.id),
				machine.id, machine.position, 4)

			if reachable == nil then
				if self.lastDrainSkip ~= machine.id then
					self.lastDrainSkip = machine.id
					sb.logInfo("PETPORT %s NOT draining for %s at %s: this unit cannot reach the "
						.. "machine, so fetching its input would only cycle stock in and out of storage",
						stationUniqueId(), sb.printJson(machine.id), sb.printJson(machine.position))
				end
			else
				table.insert(ranked, {
					machine = machine,
					free = petports_machineInputFree(machine.id)
				})
			end
		end
	end

	table.sort(ranked, function(a, b) return a.free > b.free end)

	for _, entry in ipairs(ranked) do
		local machine = entry.machine

		do

			local queue = {}

			for index, rule in ipairs(machine.rules) do
				local held = (self.census or {})[rule.item] or 0
				local surplus = held - rule.max

				if surplus > 0 then
					overQuota = overQuota + 1

					local room = petports_machineRuleRoom(machine, rule,
						{ name = rule.item, count = 1 })

					local batch = math.min(
						math.ceil(petports_stackSizeOf(rule.item) * MACHINE_MIN_BATCH), surplus)

					if room < batch then
						dribbled = dribbled + 1
						room = 0
					end

					if room > 0 then
						table.insert(queue, {
							rule = rule,
							index = index,
							room = room,
							batch = batch,

							held = held,
							surplus = surplus,
							worth = petports_itemValue({ name = rule.item })
								* math.min(room, batch)
						})
					end
				end
			end

			table.sort(queue, function(a, b)
				if a.worth ~= b.worth then return a.worth > b.worth end
				return a.index < b.index
			end)

			for _, queued in ipairs(queue) do
				local rule = queued.rule
				local room = queued.room
				local batch = queued.batch
				local held = queued.held
				local surplus = queued.surplus

				do
					do
						for _, source in ipairs(sources) do
							if world.entityExists(source.id) then
								local ok, items = pcall(world.containerItems, source.id)

								if ok and type(items) == "table" then
									for slot, stack in pairs(items) do
										if slot ~= source.beaconSlot
												and type(stack) == "table"
												and stack.name == rule.item then

											local count = math.min(surplus, stack.count or 0, room,
												petports_machineRuleRoom(machine, rule, stack))

											if count > 0 then
												local workId = "drain:" .. tostring(machine.id)
													.. ":" .. tostring(rule.item)

												local failure = self.workFailures[workId]
												local backedOff = failure ~= nil
													and (failure["until"] or 0) > world.time()

												if not backedOff and petports_claimFree(workId) then
													local stand, standWhy = petports_servicePointNear("crate " .. tostring(source.id),
														source.id, source.position, 4)

													if stand == nil then
														sb.logInfo("PETPORT %s drain source %s SKIPPED: %s of %s",
															stationUniqueId(), sb.printJson(source.id), tostring(standWhy),
															sb.printJson(source.position))
													else
														sb.logInfo("PETPORT %s draining %s x%s out of %s (slot %s) for %s at %s -- network holds %s, threshold %s, machine input room %s",
															stationUniqueId(), tostring(rule.item),
															sb.printJson(count), sb.printJson(source.id),
															sb.printJson(slot), tostring(machine.kind),
															sb.printJson(machine.position), sb.printJson(held),
															sb.printJson(rule.max), sb.printJson(room))

														return {
															id = workId,

															mediumVerified = true,
															type = "drain",
															target = source.id,
															item = rule.item,
															count = count,
															slot = slot,
															position = stand,
															containerPosition = source.position,
															port = stationUniqueId(),
															dwell = 0
														}
													end
												end
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end

	if overQuota == 0 then
		return nil, "nothing over an upcycler threshold"
	end

	if dribbled > 0 then
		return nil, string.format(
			"%s rule(s) over threshold, %s waiting for a machine to burn through "
			.. "enough input to be worth a trip", overQuota, dribbled)
	end

	return nil, string.format(
		"%s rule(s) over threshold, none actionable: no deposit crate holds the "
		.. "item, or every machine input is full", overQuota)
end

PETPORTS_MACHINES_FUEL_ITEM_CACHE = {}

-- Returns whether an item carries the machine fuel tag, cached.
function petports_machinesIsFuelItem(name)
	if type(name) ~= "string" then return false end
	if PETPORTS_MACHINES_FUEL_ITEM_CACHE[name] ~= nil then return PETPORTS_MACHINES_FUEL_ITEM_CACHE[name] end

	local verdict = false
	local ok, resolved = pcall(root.itemConfig, { name = name, count = 1 })

	if ok and type(resolved) == "table" and type(resolved.config) == "table" then
		for _, tag in ipairs(resolved.config.itemTags or {}) do
			if tag == PETPORTS_CONSTANTS.machines.fuelTag then verdict = true break end
		end
	end

	PETPORTS_MACHINES_FUEL_ITEM_CACHE[name] = verdict
	return verdict
end

-- Returns a task to clear an upcycler's output slot into a deposit or restock beacon.
function petports_machinesFuelWork()
	if self.petData == nil then return nil end
	if self.petData.cargo ~= nil and #self.petData.cargo > 0 then return nil end

	local destinations = petports_beaconsFor("deposit")
	local requesters = petports_restockBeacons()

	if #destinations == 0 and #requesters == 0 then
		return nil, "no deposit or restock beacon to store fuel in"
	end

	local waiting = 0
	local trickling = 0

	local unfilteredNames = {}
	local unroomyNames = {}
	local refusedSeen = {}

	for _, machine in ipairs(self.machines or {}) do
		if machine.kind == "upcycler" and world.entityExists(machine.id) then
			local ok, held = pcall(world.containerItemAt, machine.id, PETPORTS_CONSTANTS.machines.slotOutput)

			if ok and type(held) == "table" and type(held.name) == "string"
					and (held.count or 0) > 0 then
				local isFuel = petports_machinesIsFuelItem(held.name)

				waiting = waiting + 1

				local batch = math.ceil(petports_stackSizeOf(held.name) * MACHINE_MIN_BATCH)
				local full = (held.count or 0) >= petports_stackSizeOf(held.name)

				local okInput, input = pcall(world.containerItemAt, machine.id,
					MACHINE_SLOT_INPUT)
				local inputEmpty = not okInput or type(input) ~= "table" or input.name == nil

				local okReagent, reagent = pcall(world.containerItemAt, machine.id,
					MACHINE_SLOT_REAGENT)
				local reagentEmpty = not okReagent or type(reagent) ~= "table" or reagent.name == nil

				local feeding = false

				if inputEmpty and not reagentEmpty then
					for _, rule in ipairs(machine.rules) do
						if rule.item == reagent.name and rule.burn ~= false
								and rule.reagent ~= false then
							feeding = true
							break
						end
					end
				end

				-- A plain treat with no charge banked and no reagent to make one will never reach the output.
				local okBlips, blips = pcall(world.getObjectParameter, machine.id,
					"petports_upcyclerBlips")

				local starved = not inputEmpty and reagentEmpty
					and okBlips and (type(blips) ~= "table" or #blips == 0)
					and petports_upcyclerPlainTreat(input.name)

				local idle = (inputEmpty and not feeding) or starved

				local okBlocked, blocked = pcall(world.getObjectParameter, machine.id,
					"petports_upcyclerBlocked")

				local stalled = okBlocked and blocked == true

				local worthTaking = not isFuel
					or (held.count or 0) >= batch or full or idle or stalled

				if not worthTaking then trickling = trickling + 1 end

				local anyFilterAccepts = false

				local wanted = false

				for _, destination in ipairs(worthTaking and destinations or {}) do
					if world.entityExists(destination.id)
							and petports_filterAccepts(destination.filter, held.name) then

						anyFilterAccepts = true

						local fits = world.containerItemsCanFit ~= nil
							and world.containerItemsCanFit(destination.id, held) or nil

						if fits ~= nil and fits > 0 then
							wanted = true
							break
						end
					end
				end

				if not wanted then
					for _, crate in ipairs(worthTaking and requesters or {}) do
						for _, request in ipairs(crate.requests or {}) do
							if request.item == held.name then
								anyFilterAccepts = true

								local have = petports_restockHeld(crate.id, request.item)
								local fits = world.containerItemsCanFit ~= nil
									and world.containerItemsCanFit(crate.id, held) or nil

								if have ~= nil and have < request.max
										and (fits == nil or fits > 0) then
									wanted = true
									break
								end
							end
						end

						if wanted then break end
					end
				end

				if wanted then
					local workId = "fuel:" .. tostring(machine.id)

					local failure = self.workFailures[workId]
					local backedOff = failure ~= nil
						and (failure["until"] or 0) > world.time()

					if not backedOff and petports_claimFree(workId) then
						local stand, standWhy = petports_servicePointNear("machine " .. tostring(machine.id),
							machine.id, machine.position, 4)

						if stand == nil then
							sb.logInfo("PETPORT %s fuel source %s SKIPPED: %s of %s",
								stationUniqueId(), sb.printJson(machine.id), tostring(standWhy),
								sb.printJson(machine.position))
						else
							sb.logInfo("PETPORT %s collecting %s %s from machine %s",
								stationUniqueId(), sb.printJson(held.count),
								tostring(held.name), sb.printJson(machine.id))

							return {
								id = workId,
								mediumVerified = true,
								type = "fuel",
								target = machine.id,
								item = held.name,
								count = held.count,

								slot = PETPORTS_CONSTANTS.machines.slotOutput - SLOT_KEY_TO_OFFSET,
								position = stand,
								containerPosition = machine.position,
								port = stationUniqueId(),
								dwell = 0
							}
						end
					end
				end

				if worthTaking and not refusedSeen[held.name] then
					refusedSeen[held.name] = true

					if anyFilterAccepts then
						table.insert(unroomyNames, held.name)
					else
						table.insert(unfilteredNames, held.name)
					end
				end
			end
		end
	end

	if waiting == 0 then
		return nil, "no machine has anything in its output slot"
	end

	if trickling > 0 then
		return nil, string.format(
			"%s machine(s) with output, %s still converting and not yet worth a trip",
			waiting, trickling)
	end

	local parts = {}

	if #unfilteredNames > 0 then
		table.insert(parts, string.format(
			"no deposit or restock beacon accepts %s",
			table.concat(unfilteredNames, ", ")))
	end

	if #unroomyNames > 0 then
		table.insert(parts, string.format(
			"every crate that accepts %s is full or already at its quota",
			table.concat(unroomyNames, ", ")))
	end

	if #parts == 0 then
		table.insert(parts, "nothing was classified, which is a bug in petports_machinesFuelWork")
	end

	return nil, string.format("%s machine(s) with output, but %s",
		waiting, table.concat(parts, "; and "))
end

-- Takes the items out of the container the unit reached when a fuel or drain task reports done.
function petports_machinesDone(task, report)
	if task.type ~= "fuel" and task.type ~= "drain" then return end

	withdrawMisfit(task.target, task.item, task.count, task.id, task.slot)
end

petports_registerWork({
	name = "fuel",
	order = 2100,
	reasonOrder = true,
	gate = function() return petports_workGroup("machines") end,
	generate = function() return petports_machinesFuelWork() end,
	done = function(task, report) return petports_machinesDone(task, report) end
})

petports_registerWork({
	name = "drain",
	order = 2600,
	reasonOrder = true,
	gate = function() return petports_workGroup("machines") end,
	generate = function() return petports_machinesDrainWork() end
})
