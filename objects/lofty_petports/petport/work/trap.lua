-- Port side of emptying traps: finds ripe traps in coverage and hands out tasks to empty them.

PETPORTS_CONSTANTS = PETPORTS_CONSTANTS or {}
PETPORTS_CONSTANTS.trap = PETPORTS_CONSTANTS.trap or {}

PETPORTS_CONSTANTS.trap.interval = 5.0

-- Returns a trap's ripening age, active window and whether it can ever ripen, cached by name.
function petports_trapProfile(id)
	local name = world.entityName(id)
	if name == nil then return nil end

	self.trapProfiles = self.trapProfiles or {}

	local cached = self.trapProfiles[name]
	if cached ~= nil then
		if cached == false then return nil end
		return cached
	end

	local okStages, stages = pcall(world.getObjectParameter, id, "stages")

	if not okStages or type(stages) ~= "table" or #stages == 0
	   or type(stages[#stages]) ~= "table"
	   or stages[#stages].harvestPool == nil then
		self.trapProfiles[name] = false
		return nil
	end

	local ripeAt = 0
	local stalls = false

	for index, stage in ipairs(stages) do
		if index < #stages then
			local duration = type(stage) == "table" and stage.duration or nil
			local span = nil

			if type(duration) == "table" then
				span = math.max(tonumber(duration[1]) or 0,
					tonumber(duration[2]) or 0)
			elseif type(duration) == "number" then
				span = duration
			end

			if span == nil or span <= 0 then
				stalls = true
			else
				ripeAt = ripeAt + span
			end
		end
	end

	local okRange, range = pcall(world.getObjectParameter, id, "activeTimeRange")
	if not okRange or type(range) ~= "table" then range = { 0, 1 } end

	local span = ((tonumber(range[2]) or 1) - (tonumber(range[1]) or 0)) % 1.0

	local lockedBy = nil
	if span == 0 then
		lockedBy = "its activeTimeRange spans zero of the day"
	elseif stalls then
		lockedBy = "one of its growth stages declares no duration"
	end

	local profile = {
		name = name,
		ripeAt = ripeAt,
		span = span,
		locked = (lockedBy ~= nil),
		lockedBy = lockedBy,
		stageCount = #stages
	}

	self.trapProfiles[name] = profile
	return profile
end

-- Returns a trap's active age, or nil.
function petports_trapAge(id)
	local ok, age = pcall(world.callScriptedEntity, id, "activeAge")

	if not ok or type(age) ~= "number" then return nil end
	return age
end

-- Logs the traps and their ages when the picture changes, warning once per trap that can never ripen.
function petports_trapReport(traps)
	self.trapWarned = self.trapWarned or {}

	local ripe = 0
	local parts = {}

	for _, trap in ipairs(traps) do
		if trap.ripe then ripe = ripe + 1 end

		table.insert(parts, string.format("%s#%s age %s of %s%s%s",
			tostring(trap.name), tostring(trap.id),
			trap.age == nil and "unreadable"
				or string.format("%.0f", trap.age),
			string.format("%.0f", trap.ripeAt),
			trap.locked and " LOCKED" or "",
			trap.ripe and " RIPE" or ""))

		if trap.locked and not self.trapWarned[trap.id] then
			self.trapWarned[trap.id] = true

			sb.logWarn("PETPORT %s trap %s (%s) at %s CAN NEVER RIPEN: %s, so "
				.. "harvestable.lua holds it on an early stage forever and "
				.. "nobody -- player or unit -- can harvest it. Note that "
				.. "OMITTING activeTimeRange defaults it to [0, 1], which that "
				.. "script reads as a span of ZERO.",
				stationUniqueId(), sb.printJson(trap.id), tostring(trap.name),
				sb.printJson(trap.position),
				tostring(trap.lockedBy or "its config stalls stage growth"))
		end
	end

	table.sort(parts)
	local signature = table.concat(parts, " | ")

	if signature ~= self.trapSignature then
		self.trapSignature = signature
		sb.logInfo("PETPORT %s traps: %s found, %s ripe -- %s",
			stationUniqueId(), sb.printJson(#traps), sb.printJson(ripe),
			signature == "" and "none" or signature)
	end
end

-- Scans the network for traps, returning each with its age and whether it is ripe.
function petports_trapScan()
	local rects = self.networkRects
	if rects == nil or #rects == 0 then rects = { petports_portCoverageRect() } end

	local traps = {}
	local seen = {}

	for _, rect in ipairs(rects) do
		local ids = world.entityQuery({ rect[1], rect[2] }, { rect[3], rect[4] }, {
			includedTypes = { "object" }
		})

		for _, id in ipairs(ids or {}) do
			if not seen[id] then
				seen[id] = true

				local ok, stage = pcall(world.farmableStage, id)

				if not (ok and type(stage) == "number") then
					local profile = petports_trapProfile(id)

					if profile ~= nil then
						local age = profile.locked and 0 or petports_trapAge(id)

						table.insert(traps, {
							id = id,
							name = profile.name,
							age = age,
							ripeAt = profile.ripeAt,
							locked = profile.locked,
							lockedBy = profile.lockedBy,
							stageCount = profile.stageCount,
							position = world.entityPosition(id),
							ripe = (not profile.locked) and age ~= nil
								and age >= profile.ripeAt
						})
					end
				end
			end
		end
	end

	return traps
end

-- Rescans the traps on an interval.
function petports_trapRefresh(dt)
	self.trapTimer = (self.trapTimer or 0) - dt
	if self.trapTimer > 0 then return end
	self.trapTimer = PETPORTS_CONSTANTS.trap.interval

	self.traps = petports_trapScan()

	petports_trapReport(self.traps)
end

-- Counts an emptied trap when a trap task reports done.
function petports_trapDone(task, report)
	if task.type ~= "trap" then return end

	petports_metrics.add("traps", 1)
end

-- Returns a task to empty the nearest ripe trap, or nil with a tally of why each was passed over.
function petports_trapWork()
	local traps = self.traps

	if traps == nil or #traps == 0 then
		return nil, "no harvestable traps in network coverage"
	end

	local from = entity.position()
	if self.petId ~= nil and world.entityExists(self.petId) then
		from = world.entityPosition(self.petId)
	end

	local best, bestDistance = nil, nil
	local rejected = { unripe = 0, locked = 0, claimed = 0, backedOff = 0,
		gone = 0, medium = 0 }

	for _, trap in ipairs(traps) do
		local workId = "trap:" .. trap.id
		local claim = petports_claimGet(workId)
		local failure = self.workFailures[workId]
		local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

		local free = not backedOff and ((claim == nil)
			or claim.owner == stationUniqueId()
			or (claim.expires or 0) <= world.time())

		if trap.locked then
			rejected.locked = rejected.locked + 1
		elseif not trap.ripe then
			rejected.unripe = rejected.unripe + 1
		elseif backedOff then
			rejected.backedOff = rejected.backedOff + 1
		elseif not free then
			rejected.claimed = rejected.claimed + 1
		elseif not world.entityExists(trap.id) then
			rejected.gone = rejected.gone + 1

		elseif not petports_targetEligible("trap " .. tostring(trap.id),
			trap.position, trap.id) then
			rejected.medium = rejected.medium + 1
		else
			local distance = world.magnitude(from, trap.position)

			if bestDistance == nil or distance < bestDistance then
				best, bestDistance = trap, distance
			end
		end
	end

	if best == nil then
		local reason = string.format(
			"%s trap(s) in coverage, none harvestable: %s unripe, %s age "
			.. "locked, %s claimed, %s backed off, %s gone, %s in a medium "
			.. "this chassis cannot work in",
			#traps, rejected.unripe, rejected.locked, rejected.claimed,
			rejected.backedOff, rejected.gone, rejected.medium)

		if reason ~= self.trapRejectReason then
			self.trapRejectReason = reason
			sb.logInfo("PETPORT %s traps: %s", stationUniqueId(), reason)
		end

		return nil, reason
	end

	self.trapRejectReason = nil

	sb.logInfo("PETPORT %s trap %s (%s) RIPE at %s, %s away -- dispatching",
		stationUniqueId(), sb.printJson(best.id), tostring(best.name),
		sb.printJson(best.position), sb.printJson(bestDistance))

	return {
		id = "trap:" .. best.id,
		mediumVerified = true,
		type = "trap",
		port = stationUniqueId(),
		target = best.id,
		targetName = best.name,
		ripeAt = best.ripeAt,
		position = best.position
	}
end

petports_registerWork({
	name = "trap",
	order = 1600,
	reasonOrder = true,
	gate = function() return petports_workFarming("traps") end,
	generate = function() return petports_trapWork() end,
	scanBeat = function(dt) return petports_trapRefresh(dt) end,
	done = function(task, report) return petports_trapDone(task, report) end
})
