-- Port side of collecting: finds the nearest unclaimed drop in the network and hands out a task to fetch it. The stalled-with-cargo step in the main file tops up through petports_collectWork when it exists.

PETPORTS_CONSTANTS = PETPORTS_CONSTANTS or {}
PETPORTS_CONSTANTS.collect = PETPORTS_CONSTANTS.collect or {}

PETPORTS_CONSTANTS.collect.deferGrace = 12.0

-- Returns whether an idle unit elsewhere in the network is nearer a position.
function petports_collectAnotherUnitCloser(position, ourDistance)
	for _, entry in ipairs(petports_networkMembers(stationUniqueId())) do
		if entry.unitPosition ~= nil and not entry.busy and entry.hasUnit ~= false then
			if world.magnitude(entry.unitPosition, position) < ourDistance then
				return true
			end
		end
	end
	return false
end

-- Returns whether a drop would stack onto cargo the unit already carries.
function petports_collectDropMerges(dropId)
	if self.petData == nil or self.petData.cargo == nil then return false end

	local ok, descriptor = pcall(world.itemDropItem, dropId)

	if not ok or type(descriptor) ~= "table" or type(descriptor.name) ~= "string" then
		return false
	end

	for _, stack in ipairs(self.petData.cargo) do
		if stack.name == descriptor.name then
			local limit = petports_stackSizeOf(stack.name)
			local total = (stack.count or 0) + (descriptor.count or 1)

			if total <= limit then return true end

			sb.logInfo("PETPORT %s drop %s would overflow %s: %s held + %s dropped > %s",
				stationUniqueId(), sb.printJson(dropId), tostring(stack.name),
				sb.printJson(stack.count or 0), sb.printJson(descriptor.count or 1),
				sb.printJson(limit))

			return false
		end
	end

	return false
end

-- Returns a task to fetch the nearest unclaimed drop in the network, or nil with a tally of why each was passed over.
function petports_collectWork(mergeOnly)
	local rects = self.networkRects
	if rects == nil or #rects == 0 then rects = { petports_portCoverageRect() } end

	local drops = {}
	local seen = {}
	for _, area in ipairs(rects) do
		local found = world.entityQuery({area[1], area[2]}, {area[3], area[4]}, {
			includedTypes = { "itemDrop" }
		})
		for _, dropId in ipairs(found or {}) do
			if not seen[dropId] then
				seen[dropId] = true
				table.insert(drops, dropId)
			end
		end
	end

	local rect = petports_portCoverageRect()

	if drops == nil or #drops == 0 then
		local wide = { rect[1] - COVERAGE_SIZE, rect[2] - COVERAGE_SIZE,
										rect[3] + COVERAGE_SIZE, rect[4] + COVERAGE_SIZE }
		local nearby = world.entityQuery({wide[1], wide[2]}, {wide[3], wide[4]}, {
			includedTypes = { "itemDrop" }
		})

		if nearby ~= nil and #nearby > 0 then
			return nil, string.format(
				"no drops in rect %s, but %s just outside (nearest %s)",
				sb.printJson(rect), #nearby, sb.printJson(world.entityPosition(nearby[1])))
		end

		return nil, "no drops in network coverage (own rect " .. sb.printJson(rect) .. ")"
	end

	sb.logInfo("PETPORT %s scan: %s drops in %s rects",
		stationUniqueId(), sb.printJson(#drops), sb.printJson(#rects))

	local origin = entity.position()
	local best, bestDistance = nil, nil

	local rejected = { claimed = 0, backedOff = 0, deferred = 0, gone = 0,
		unmergeable = 0, medium = 0 }

	self.deferredSince = self.deferredSince or {}
	local stillDeferred = {}

	for _, dropId in ipairs(drops) do
		local workId = "drop:" .. dropId
		local claim = petports_claimGet(workId)

		local failure = self.workFailures[workId]
		local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

		local free = not backedOff and ((claim == nil)
			or claim.owner == stationUniqueId()
			or (claim.expires or 0) <= world.time())

		if backedOff then
			sb.logInfo("PETPORT %s drop %s SKIPPED: backed off until %s (now %s, failures %s)",
				stationUniqueId(), sb.printJson(dropId),
				sb.printJson(failure["until"]), sb.printJson(world.time()),
				sb.printJson(failure.count))
			rejected.backedOff = rejected.backedOff + 1
		elseif not free then
			sb.logInfo("PETPORT %s drop %s SKIPPED: claimed by %s until %s",
				stationUniqueId(), sb.printJson(dropId),
				tostring(claim.owner), sb.printJson(claim.expires))
			rejected.claimed = rejected.claimed + 1
		elseif not world.entityExists(dropId) then
			sb.logInfo("PETPORT %s drop %s SKIPPED: entity gone",
				stationUniqueId(), sb.printJson(dropId))
			rejected.gone = rejected.gone + 1
		elseif mergeOnly and not petports_collectDropMerges(dropId) then
			rejected.unmergeable = (rejected.unmergeable or 0) + 1
		else
			local position = world.entityPosition(dropId)
			if position == nil then
				rejected.gone = rejected.gone + 1

			elseif not petports_targetEligible("drop " .. tostring(dropId), position, dropId) then
				rejected.medium = rejected.medium + 1
			else
				local from = origin
				if self.petId ~= nil and world.entityExists(self.petId) then
					from = world.entityPosition(self.petId)
				end

				local distance = world.magnitude(from, position)

				local defer = petports_collectAnotherUnitCloser(position, distance)
				if defer then
					local since = self.deferredSince[workId] or world.time()
					stillDeferred[workId] = since

					if world.time() - since >= PETPORTS_CONSTANTS.collect.deferGrace then
						sb.logInfo("PETPORT %s taking %s anyway: deferred %ss with no taker",
							stationUniqueId(), workId,
							sb.printJson(math.floor(world.time() - since)))
						defer = false
					end
				end

				if defer then
					sb.logInfo("PETPORT %s drop %s SKIPPED: deferred to a closer unit (ours %s away)",
						stationUniqueId(), sb.printJson(dropId), sb.printJson(distance))
					rejected.deferred = rejected.deferred + 1
				elseif bestDistance == nil or distance < bestDistance then
					sb.logInfo("PETPORT %s drop %s TAKEABLE at %s, %s away -- new best",
						stationUniqueId(), sb.printJson(dropId),
						sb.printJson(position), sb.printJson(distance))
					best, bestDistance = dropId, distance
				else
					sb.logInfo("PETPORT %s drop %s takeable but further (%s vs best %s)",
						stationUniqueId(), sb.printJson(dropId),
						sb.printJson(distance), sb.printJson(bestDistance))
				end
			end
		end
	end

	self.deferredSince = stillDeferred

	if best == nil then
		return nil, string.format(
			"%s drops in rect, none takeable: %s claimed, %s backed off, "
			.. "%s deferred to a closer unit, %s gone, %s in a medium this chassis "
			.. "cannot work in%s",
			#drops, rejected.claimed, rejected.backedOff,
			rejected.deferred, rejected.gone, rejected.medium,

			mergeOnly and string.format(", %s that would not merge with the cargo",
				rejected.unmergeable) or "")
	end

	return {
		id = "drop:" .. best,
		mediumVerified = true,
		type = "collect",
		port = stationUniqueId(),
		target = best,
		position = world.entityPosition(best)
	}
end

petports_registerWork({
	name = "collect",
	order = 1100,
	reasonOrder = true,
	gate = function() return petports_workGroup("hauling") end,
	generate = function() return petports_collectWork() end
})
