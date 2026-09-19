-- Port side of restocking: delivers carried cargo into a restock beacon that is short of it, and fetches from storage what a restock beacon asks for. work/machines.lua reads petports_restockBeacons and petports_restockHeld from here.

-- Returns how much of an item a container holds.
function petports_restockHeld(containerId, name)
	if not world.entityExists(containerId) then return nil end

	local ok, items = pcall(world.containerItems, containerId)
	if not ok or type(items) ~= "table" then return nil end

	local total = 0

	for _, stack in pairs(items) do
		if type(stack) == "table" and stack.name == name then
			total = total + (stack.count or 1)
		end
	end

	return total
end

-- Returns the live restock beacons that carry requests.
function petports_restockBeacons()
	local out = {}

	for _, beacon in ipairs(petports_beaconsFor("restock")) do
		if beacon.requests ~= nil and world.entityExists(beacon.id) then
			table.insert(out, beacon)
		end
	end

	return out
end

-- Returns a task to deliver carried cargo into a restock beacon that is short of it.
function petports_restockDeliverWork()
	if self.petData == nil or self.petData.cargo == nil then return nil end
	if #self.petData.cargo == 0 then return nil end

	local beacons = petports_restockBeacons()
	if #beacons == 0 then return nil end

	for _, beacon in ipairs(beacons) do
		for _, request in ipairs(beacon.requests) do
			local carried = nil
			for _, stack in ipairs(self.petData.cargo) do
				if stack.name == request.item then
					carried = stack
					break
				end
			end

			if carried ~= nil then
				local have = petports_restockHeld(beacon.id, request.item)

				if have ~= nil and have < request.max then
					local fits = world.containerItemsCanFit ~= nil
						and world.containerItemsCanFit(beacon.id, carried) or nil

					if fits == nil or fits > 0 then
						local stand, standWhy = petports_servicePointNear("request crate " .. tostring(beacon.id),
							beacon.id, beacon.position, 4)

						if stand == nil then
							sb.logInfo("PETPORT %s restock delivery to %s SKIPPED: %s of %s",
								stationUniqueId(), sb.printJson(beacon.id), tostring(standWhy),
								sb.printJson(beacon.position))
						else
							sb.logInfo("PETPORT %s delivering %s x%s to request crate %s (has %s of %s)",
								stationUniqueId(), tostring(request.item),
								sb.printJson(carried.count or 1), sb.printJson(beacon.id),
								sb.printJson(have), sb.printJson(request.max))

							return {
								id = "restockput:" .. tostring(beacon.id)
									.. ":" .. tostring(request.item) .. "@" .. stationUniqueId(),
								mediumVerified = true,
								type = "deposit",
								target = beacon.id,

								only = request.item,

								position = stand,
								containerPosition = beacon.position,
								port = stationUniqueId(),
								dwell = 0
							}
						end
					end
				end
			end
		end
	end

	return nil
end

-- Returns a task to fetch stock from a deposit crate for a restock beacon that has fallen below its minimum.
function petports_restockFetchWork()
	local beacons = petports_restockBeacons()
	if #beacons == 0 then return nil, "no configured restock beacon in coverage" end

	local short, unstocked, noRoom, unreachable = 0, 0, 0, 0

	for _, beacon in ipairs(beacons) do
		if petports_servicePointNear("request crate " .. tostring(beacon.id),
				beacon.id, beacon.position, 4) == nil then
			unreachable = unreachable + 1

			if self.lastRestockSkip ~= beacon.id then
				self.lastRestockSkip = beacon.id
				sb.logInfo("PETPORT %s NOT restocking %s at %s: this unit cannot reach the request "
					.. "crate, so fetching for it would only cycle stock in and out of storage",
					stationUniqueId(), sb.printJson(beacon.id), sb.printJson(beacon.position))
			end

		else
		for _, request in ipairs(beacon.requests) do
			local have = petports_restockHeld(beacon.id, request.item)

			if have ~= nil and have < request.min then
				local want = request.max - have

				if want > 0 then
					short = short + 1

					local workId = "restock:" .. tostring(beacon.id)
						.. ":" .. tostring(request.item)

					local failure = self.workFailures[workId]
					local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

					if not backedOff and petports_claimFree(workId) then
						local source, available = nil, 0

						for _, crate in ipairs(petports_beaconsFor("deposit")) do
							if world.entityExists(crate.id) then
								local n = world.containerAvailable(crate.id,
									{ name = request.item, count = 1 })

								if type(n) == "number" and n >= 1 then
									if petports_servicePointNear("crate " .. tostring(crate.id),
											crate.id, crate.position, 4) == nil then
										if self.lastRestockSourceSkip ~= crate.id then
											self.lastRestockSourceSkip = crate.id
											sb.logInfo("PETPORT %s restock source %s at %s SKIPPED: holds %s but "
												.. "this unit cannot reach it -- looking for another source",
												stationUniqueId(), sb.printJson(crate.id),
												sb.printJson(crate.position), tostring(request.item))
										end
									else
										source = crate
										available = n
										break
									end
								end
							end
						end

						if source == nil then
							unstocked = unstocked + 1
						else
							local count = math.min(want, available, petports_stackSizeOf(request.item))

							local fits = world.containerItemsCanFit ~= nil
								and world.containerItemsCanFit(beacon.id,
									{ name = request.item, count = count }) or nil

							if fits ~= nil and fits <= 0 then
								noRoom = noRoom + 1
							else
								sb.logInfo("PETPORT %s RESTOCK dispatch: %s x%s from %s for crate %s (has %s, wants %s-%s)",
									stationUniqueId(), tostring(request.item), sb.printJson(count),
									sb.printJson(source.id), sb.printJson(beacon.id),
									sb.printJson(have), sb.printJson(request.min),
									sb.printJson(request.max))

								return {
									id = workId,
									mediumVerified = true,
									type = "withdraw",
									port = stationUniqueId(),
									target = source.id,

									seed = request.item,
									count = count,

									position = world.entityPosition(source.id)
								}
							end
						end
					end
				end
			end
		end
		end
	end

	if short == 0 then
		return nil, "every restock request is at or above its minimum"
	end

	return nil, string.format(
		"%s restock request(s) short, none actionable: %s with none in storage, "
		.. "%s with the request crate full, %s with an unreachable request crate",
		short, unstocked, noRoom, unreachable)
end

petports_registerWork({
	name = "restock",
	order = 600,
	gate = function() return petports_workGroup("restock") end,
	generate = function() return petports_restockDeliverWork() end
})

petports_registerWork({
	name = "restockFetch",
	order = 2000,
	reasonOrder = true,
	gate = function() return petports_workGroup("restock") end,
	generate = function() return petports_restockFetchWork() end
})
