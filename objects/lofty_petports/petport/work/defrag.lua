-- Port side of the defrag family: tidy moves a misfiled stack to a crate that accepts it, compact merges split stacks, defrag pulls scattered items toward their home crate, sort orders one crate at a time.

-- Returns the crates this unit is allowed to tidy out of.
function petports_defragTidySources(wantDeposit, wantRestock)
	local sources = {}

	if wantDeposit then
		for _, beacon in ipairs(petports_beaconsFor("deposit")) do
			table.insert(sources, beacon)
		end
	end

	if wantRestock then
		for _, beacon in ipairs(petports_beaconsFor("restock")) do
			if beacon.requests ~= nil then
				table.insert(sources, beacon)
			end
		end
	end

	return sources
end

-- Returns a task to move the most valuable misfiled stack out of a crate into one that accepts it.
function petports_defragTidyWork(doDeposit, doRestock)
	local destinations = petports_beaconsFor("deposit")

	if #destinations == 0 then
		return nil, "no deposit beacon to tidy into"
	end

	local sources = petports_defragTidySources(doDeposit, doRestock)

	if #sources == 0 then
		return nil, "no crate this unit is allowed to tidy"
	end

	local misfiled, homeless, full = 0, 0, 0

	local viable = {}

	for _, source in ipairs(sources) do
		if world.entityExists(source.id) then
			local items = world.containerItems(source.id)

			if type(items) == "table" then
				local misfits

				if source.behavior == "restock" then
					misfits = petports_restockMisfits(source.requests, items,
						source.beaconSlot)
				else
					misfits = petports_filterMisfits(source.filter, items,
						source.beaconSlot)
				end

				for _, misfit in ipairs(misfits) do
					misfiled = misfiled + 1

					local workId = "tidy:" .. tostring(source.id)
						.. ":" .. tostring(misfit.name)

					local failure = self.workFailures[workId]
					local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

					if not backedOff and petports_claimFree(workId) then
						local stack = items[misfit.slot]
						local accepted, roomFor = false, false

						for _, destination in ipairs(destinations) do
							if destination.id ~= source.id
									and world.entityExists(destination.id)
									and petports_filterAccepts(destination.filter, misfit.name) then
								accepted = true

								local fits = world.containerItemsCanFit ~= nil
									and world.containerItemsCanFit(destination.id, stack) or nil

								if fits ~= nil and fits > 0 then
									roomFor = true
									break
								end
							end
						end

						if not accepted then
							homeless = homeless + 1
						elseif not roomFor then
							full = full + 1
						else
							table.insert(viable, {
								workId = workId,
								source = source,
								name = misfit.name,
								count = misfit.count,
								slot = misfit.slot,

								unitValue = type(stack) == "table"
									and petports_itemValue(stack) or 0
							})
						end
					end
				end
			end
		end
	end

	table.sort(viable, function(a, b)
		if a.unitValue ~= b.unitValue then return a.unitValue > b.unitValue end
		if a.source.id ~= b.source.id then return a.source.id < b.source.id end
		return (a.slot or 0) < (b.slot or 0)
	end)

	for _, pick in ipairs(viable) do
		local source = pick.source

		local stand, standWhy = petports_servicePointNear("crate " .. tostring(source.id),
			source.id, source.position, 4)

		if stand == nil then
			sb.logInfo("PETPORT %s tidy source %s SKIPPED: %s of %s",
				stationUniqueId(), sb.printJson(source.id), tostring(standWhy),
				sb.printJson(source.position))
		else
			sb.logInfo("PETPORT %s tidying %s x%s out of %s (slot %s, %s each, "
				.. "%s viable candidate(s))",
				stationUniqueId(), tostring(pick.name), sb.printJson(pick.count),
				sb.printJson(source.id), sb.printJson(pick.slot),
				sb.printJson(pick.unitValue), sb.printJson(#viable))

			return {
				id = pick.workId,
				mediumVerified = true,
				type = "tidy",
				target = source.id,
				item = pick.name,
				count = pick.count,
				slot = pick.slot,
				position = stand,
				containerPosition = source.position,
				port = stationUniqueId(),
				dwell = 0
			}
		end
	end

	if misfiled == 0 then
		return nil, "nothing misfiled in coverage"
	end

	return nil, string.format(
		"%s misfiled stack(s), none actionable: %s with no crate that wants them, "
		.. "%s with the right crate full",
		misfiled, homeless, full)
end

-- Returns a task to merge the split stacks in the first crate that has any.
function petports_defragCompactWork()
	for _, source in ipairs(petports_defragTidySources(true, true)) do
		if world.entityExists(source.id) then
			local ok, items = pcall(world.containerItems, source.id)

			if ok and type(items) == "table" then
				local split = petports_fragmentation(items)

				if #split > 0 then
					local workId = "compact:" .. tostring(source.id)

					local failure = self.workFailures[workId]
					local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

					if not backedOff and petports_claimFree(workId) then
						local stand, standWhy = petports_servicePointNear("crate " .. tostring(source.id),
							source.id, source.position, 4)

						if stand == nil then
							sb.logInfo("PETPORT %s compaction of %s SKIPPED: %s of %s",
								stationUniqueId(), sb.printJson(source.id), tostring(standWhy),
								sb.printJson(source.position))
						else
							sb.logInfo("PETPORT %s compacting %s: %s item(s) split across more slots than needed",
								stationUniqueId(), sb.printJson(source.id), sb.printJson(#split))

							return {
								id = workId,

								mediumVerified = true,
								type = "compact",
								target = source.id,
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

	return nil, "no crate has stacks worth merging"
end

-- Returns a task to pull a scattered or misplaced item out of a crate toward the one it belongs in.
function petports_defragWork()
	if self.petData == nil then return nil end
	if self.petData.cargo ~= nil and #self.petData.cargo > 0 then return nil end

	local names, deposits, byId = petports_defragCandidates(self.spread, self.beacons or {})

	if #names == 0 then return nil, "everything is already where it belongs" end
	if #deposits == 0 then return nil, "no deposit beacon to gather into" end

	local homeless, full, unreachable = 0, 0, 0
	local claimed, backedOffN, noStack = 0, 0, 0

	for index, entry in ipairs(names) do
		if index > DEFRAG_PLAN_CAP then break end

		local where = self.spread[entry.name]
		local target = petports_defragDestination(entry.name, where, deposits)

		if target == nil then
			homeless = homeless + 1
		else
			local reachable, reachWhy = petports_servicePointNear("crate " .. tostring(target.id),
				target.id, target.position, 4)

			if reachable == nil then
				unreachable = unreachable + 1
				if self.defragSkip ~= target.id then
					self.defragSkip = target.id
					sb.logInfo("PETPORT %s defrag destination %s SKIPPED: %s of %s",
						stationUniqueId(), sb.printJson(target.id), tostring(reachWhy),
						sb.printJson(target.position))
				end
			else
				local sources = petports_defragSourcesFor(entry.name, where, target.id, byId)

				for _, pick in ipairs(sources) do
					local crate = pick.crate

					local workId = "defrag:" .. tostring(crate.id)
						.. ":" .. tostring(entry.name)

					local failure = self.workFailures[workId]
					local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

					if backedOff then backedOffN = backedOffN + 1
					elseif not petports_claimFree(workId) then claimed = claimed + 1 end

					if not backedOff and petports_claimFree(workId) then
						local ok, items = pcall(world.containerItems, crate.id)
						local slot, stack = nil, nil

						if ok and type(items) == "table" then
							local keys = {}
							for key in pairs(items) do table.insert(keys, key) end
							table.sort(keys)

							for _, key in ipairs(keys) do
								local held = items[key]

								if key ~= crate.beaconSlot and type(held) == "table"
										and held.name == entry.name then
									slot, stack = key, held
									break
								end
							end
						end

						if slot == nil then noStack = noStack + 1 end

						if slot ~= nil then
							local fits = world.containerItemsCanFit ~= nil
								and world.containerItemsCanFit(target.id, stack) or nil

							if fits == nil or fits <= 0 then
								full = full + 1
							else
								local stand, standWhy = petports_servicePointNear(
									"crate " .. tostring(crate.id), crate.id, crate.position, 4)

								if stand == nil then
									unreachable = unreachable + 1

									if self.defragSkip ~= crate.id then
										self.defragSkip = crate.id
										sb.logInfo("PETPORT %s defrag source %s SKIPPED: %s of %s",
											stationUniqueId(), sb.printJson(crate.id),
											tostring(standWhy), sb.printJson(crate.position))
									end
								else
									self.defragPulled = self.defragPulled or {}
									self.defragPulled[entry.name] =
										{ from = crate.id, workId = workId }

									sb.logInfo("PETPORT %s defrag: taking %s x%s from %s "
										.. "(slot %s, has %s) toward %s -- %s of %s crate(s), "
										.. "%s slot(s) total",
										stationUniqueId(), tostring(entry.name),
										sb.printJson(stack.count or 1), sb.printJson(crate.id),
										sb.printJson(slot), sb.printJson(pick.count),
										sb.printJson(target.id), sb.printJson(index),
										sb.printJson(entry.crates), sb.printJson(entry.slots))

									return {
										id = workId,
										mediumVerified = true,

										type = "defrag",
										target = crate.id,
										item = entry.name,
										count = stack.count or 1,
										slot = slot,
										position = stand,
										containerPosition = crate.position,
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

	local why = string.format(
		"%s name(s) misplaced or scattered, none actionable: %s with nowhere to "
		.. "gather into, %s with the destination full, %s with a crate this unit "
		.. "cannot reach, %s claimed by another unit, %s backed off, %s with no "
		.. "stack found in the source", #names, homeless, full, unreachable,
		claimed, backedOffN, noStack)

	if self.defragWhy ~= why then
		self.defragWhy = why
		sb.logInfo("PETPORT %s defrag: %s", stationUniqueId(), why)
	end

	return nil, why
end

-- Returns a task to sort one crate, stepping round the crates and leaving each alone for a while after.
function petports_defragSortWork()
	self.sortScan = (self.sortScan or 0) - (WORK_INTERVAL or 1.0)
	if self.sortScan > 0 then return nil, "one crate is looked at every few seconds" end
	self.sortScan = SORT_SCAN_INTERVAL

	local sources = petports_defragTidySources(true, true)
	if #sources == 0 then return nil, "no crate to sort" end

	self.sortCursor = (self.sortCursor or 0) + 1
	if self.sortCursor > #sources then self.sortCursor = 1 end

	local source = sources[self.sortCursor]
	if source == nil then return nil, "no crate to sort" end

	if not world.entityExists(source.id) then
		return nil, "the crate in the ring this scan is gone"
	end

	self.sortQuiet = self.sortQuiet or {}

	local quiet = self.sortQuiet[source.id]
	if quiet ~= nil and quiet > world.time() then
		return nil, string.format("crate %s was sorted recently",
			tostring(source.id))
	end

	local ok, items = pcall(world.containerItems, source.id)
	if not ok or type(items) ~= "table" then
		return nil, "the crate in the ring this scan could not be read"
	end

	local _, disorder = petports_sortPlan(items)

	if disorder < SORT_MIN_DISORDER then
		return nil, string.format("crate %s is already in order",
			tostring(source.id))
	end

	local workId = "sort:" .. tostring(source.id)

	local failure = self.workFailures[workId]
	local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

	if backedOff then
		return nil, string.format("crate %s is backed off after a failed trip",
			tostring(source.id))
	end

	if not petports_claimFree(workId) then
		return nil, string.format("crate %s is already claimed", tostring(source.id))
	end

	local stand, standWhy = petports_servicePointNear("crate " .. tostring(source.id),
		source.id, source.position, 4)

	if stand == nil then
		sb.logInfo("PETPORT %s sort of %s SKIPPED: %s of %s",
			stationUniqueId(), sb.printJson(source.id), tostring(standWhy),
			sb.printJson(source.position))

		return nil, string.format("nowhere to stand at crate %s",
			tostring(source.id))
	end

	self.sortQuiet[source.id] = world.time() + SORT_REVISIT

	sb.logInfo("PETPORT %s sorting %s: %s slot(s) out of place (crate %s of %s "
		.. "in the ring)",
		stationUniqueId(), sb.printJson(source.id), sb.printJson(disorder),
		sb.printJson(self.sortCursor), sb.printJson(#sources))

	return {
		id = workId,

		mediumVerified = true,
		type = "sort",
		target = source.id,
		position = stand,
		containerPosition = source.position,
		port = stationUniqueId(),
		dwell = 0
	}
end

-- Carries out the crate change when a tidy, defrag, compact or sort task reports done.
function petports_defragDone(task, report)
	if task.type == "tidy" or task.type == "defrag" then
		withdrawMisfit(task.target, task.item, task.count, task.id, task.slot)
	elseif task.type == "compact" then
		compactContainer(task.target)
	elseif task.type == "sort" then
		sortContainer(task.target)
	end
end

petports_registerWork({
	name = "tidy",
	order = 2200,
	reasonOrder = true,
	gate = function()
		return petports_workDefrag("tidy") or petports_workGroup("restock")
	end,
	generate = function()
		return petports_defragTidyWork(petports_workDefrag("tidy"), petports_workGroup("restock"))
	end,
	done = function(task, report) return petports_defragDone(task, report) end
})

petports_registerWork({
	name = "compact",
	order = 2300,
	reasonOrder = true,
	gate = function() return petports_workDefrag("compact") end,
	generate = function() return petports_defragCompactWork() end
})

petports_registerWork({
	name = "defrag",
	order = 2400,
	reasonOrder = true,
	gate = function() return petports_workDefrag("defrag") end,
	generate = function() return petports_defragWork() end
})

petports_registerWork({
	name = "sort",
	order = 2500,
	reasonOrder = true,
	gate = function() return petports_workDefrag("sort") end,
	generate = function() return petports_defragSortWork() end
})
