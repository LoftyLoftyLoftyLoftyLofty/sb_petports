-- Port side of depositing: unloads the cargo into the nearest deposit beacon that will take any of it. Tidying hands out deposit tasks too, and this file settles them all.

-- Returns whether a container would accept any of the unit's cargo, or false when its filter refuses all of it.
function petports_depositContainerTakesAny(containerId, filter)
	if self.petData == nil or self.petData.cargo == nil then return nil end

	local anyAllowed = false

	for _, stack in ipairs(self.petData.cargo) do
		if petports_filterAccepts(filter, stack.name) then
			anyAllowed = true

			if world.containerItemsCanFit == nil then
				return nil
			end

			local fits = world.containerItemsCanFit(containerId, stack)
			if fits ~= nil and fits > 0 then return true end
		end
	end

	if not anyAllowed then return false end

	return false
end

-- Returns whether any deposit beacon would accept any of the cargo.
function petports_depositStorageTakesAny()
	if self.petData == nil then return false end

	if self.petData.cargo == nil or #self.petData.cargo == 0 then return true end

	for _, beacon in ipairs(petports_beaconsFor("deposit")) do
		if world.entityExists(beacon.id) then
			for _, stack in ipairs(self.petData.cargo) do
				if petports_filterAccepts(beacon.filter, stack.name) then
					local fits = world.containerItemsCanFit ~= nil
						and world.containerItemsCanFit(beacon.id, stack) or nil

					if fits == nil or fits > 0 then return true end
				end
			end
		end
	end

	return false
end

-- Returns the crate an item belongs in, cached per beacon scan.
function petports_depositHomeFor(name, targets, descriptor)
	local version = self.beaconVersion or 0

	if self.defragHomeVersion ~= version then
		self.defragHomeVersion = version
		self.defragHomes = {}
	end

	local held = self.defragHomes[name]

	if held ~= nil then
		if held == false then return nil end
		return held
	end

	local where = (self.spread or {})[name] or {}

	local target, why, has = petports_defragDestination(name, where, targets,
		petports_itemPerishable(descriptor or name))

	if target == nil or (has or 0) <= 0 and why == "accepts it, holds most" then
		self.defragHomes[name] = false
		return nil
	end

	self.defragHomes[name] = target.id
	return target.id
end

-- Reorders the deposit beacons to favour the homes the cargo belongs in, skipping a crate an item was just pulled from.
function petports_depositPreferredTargets(targets)
	if not petportDefrag() then return targets end
	if not petportParticipates("defrag") then return targets end
	if self.petData == nil or type(self.petData.cargo) ~= "table" then return targets end

	local votes = {}
	local voted = 0

	for _, stack in ipairs(self.petData.cargo) do
		if type(stack.name) == "string" then
			local home = petports_depositHomeFor(stack.name, targets, stack)

			local pulled = (self.defragPulled or {})[stack.name]

			if pulled ~= nil then
				self.defragPulled[stack.name] = nil

				if home ~= nil and home == pulled.from then
					sb.logError("PETPORT %s defrag pulled %s out of crate %s and is "
						.. "about to put it back -- backing off; the destination it was "
						.. "dispatched toward stopped being the answer between dispatch "
						.. "and arrival",
						stationUniqueId(), tostring(stack.name), sb.printJson(home))

					petports_noteFailure(pulled.workId, "defrag would return it to its source")
					home = nil
				end
			end

			if home ~= nil then
				votes[home] = (votes[home] or 0) + 1
				voted = voted + 1
			end
		end
	end

	if voted == 0 then return targets end

	local ranked = {}
	for index, beacon in ipairs(targets) do
		table.insert(ranked, { beacon = beacon, index = index, votes = votes[beacon.id] or 0 })
	end

	table.sort(ranked, function(a, b)
		if a.votes ~= b.votes then return a.votes > b.votes end
		return a.index < b.index
	end)

	local out = {}
	for _, entry in ipairs(ranked) do table.insert(out, entry.beacon) end

	if DEFRAG_DEBUG and ranked[1] ~= nil and ranked[1].votes > 0 then
		local said = string.format("%s|%s|%s", tostring(ranked[1].beacon.id),
			tostring(ranked[1].votes), tostring(ranked[1].index))

		if said ~= self.defragPreferSaid then
			self.defragPreferSaid = said

			sb.logInfo("PETPORT %s defrag deposit: crate %s wins with %s of %s "
				.. "stack(s), was %s of %s by distance",
				stationUniqueId(), tostring(ranked[1].beacon.id),
				tostring(ranked[1].votes), tostring(#self.petData.cargo),
				tostring(ranked[1].index), tostring(#targets))
		end
	end

	return out
end

-- Returns a task to unload the cargo into the nearest deposit beacon that will take any of it.
function petports_depositWork()
	if self.petData == nil then return nil end
	if self.petData.cargo == nil or #self.petData.cargo == 0 then return nil end

	local targets = petports_beaconsFor("deposit")

	targets = petports_depositPreferredTargets(targets)

	if #targets == 0 then
		return nil, "carrying " .. sb.printJson(#self.petData.cargo)
			.. " stack(s) but no deposit beacon in coverage"
	end

	local now = world.time()
	self.fullContainers = self.fullContainers or {}

	for _, beacon in ipairs(targets) do
		local workId = "deposit:" .. tostring(beacon.id) .. "@" .. stationUniqueId()
		local failure = self.workFailures[workId]
		local failureBackedOff = failure ~= nil and (failure["until"] or 0) > now
		if failureBackedOff then
			sb.logInfo("PETPORT %s deposit target %s SKIPPED: backed off until %s (now %s, failures %s)",
				stationUniqueId(), sb.printJson(beacon.id),
				sb.printJson(failure["until"]), sb.printJson(now), sb.printJson(failure.count))
		end

		local takesAny = petports_depositContainerTakesAny(beacon.id, beacon.filter)
		local backedOff

		if failureBackedOff then
			backedOff = true
		elseif takesAny == nil then
			backedOff = (self.fullContainers[beacon.id] or 0) > now
			if backedOff then
				sb.logInfo("PETPORT %s deposit target %s SKIPPED: was full, retrying in %s (no containerItemsCanFit)",
					stationUniqueId(), sb.printJson(beacon.id),
					sb.printJson((self.fullContainers[beacon.id] or 0) - now))
			end
		else
			backedOff = not takesAny
			if backedOff then
				local held = {}
				for _, stack in ipairs(self.petData.cargo) do
					table.insert(held, string.format("%sx%s",
						tostring(stack.name), tostring(stack.count or 1)))
				end

				local reason = "full"
				if beacon.filter ~= nil then
					local allowed = false
					for _, stack in ipairs(self.petData.cargo) do
						if petports_filterAccepts(beacon.filter, stack.name) then
							allowed = true
							break
						end
					end
					if not allowed then reason = "filter rejects every stack" end
				end

				sb.logInfo("PETPORT %s deposit target %s SKIPPED (%s): cannot take any of [%s]",
					stationUniqueId(), sb.printJson(beacon.id), reason, table.concat(held, ", "))
			end
		end

		if backedOff then
		else
			local stand, standWhy = petports_servicePointNear("crate " .. tostring(beacon.id),
				beacon.id, beacon.position, 4)

			if stand == nil then
				sb.logInfo("PETPORT %s deposit target %s SKIPPED: %s of %s",
					stationUniqueId(), sb.printJson(beacon.id), tostring(standWhy),
					sb.printJson(beacon.position))
			else

				return {
					id = "deposit:" .. tostring(beacon.id) .. "@" .. stationUniqueId(),
					mediumVerified = true,
					type = "deposit",
					target = beacon.id,
					position = stand,
					containerPosition = beacon.position,
					port = stationUniqueId(),
					dwell = 0
				}
			end
		end
	end

	return nil, "every deposit beacon is backed off as full"
end

-- Moves the cargo into the crate when a deposit task reports done.
function petports_depositDone(task, report)
	if task.type ~= "deposit" then return end

	if task.only ~= nil then
		depositCargoOnly(task.target, task.only)
	else
		depositCargo(task.target)
	end
end

petports_registerWork({
	name = "deposit",
	order = 700,
	generate = function() return petports_depositWork() end,
	done = function(task, report) return petports_depositDone(task, report) end
})
