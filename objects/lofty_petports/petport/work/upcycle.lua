-- Port side of loading the upcycler: offers the cargo to a machine that wants it, one step ahead of depositing. Reads petports_depositStorageTakesAny from work/deposit.lua.

-- Returns whether an upcycler wants any of the cargo, with the reason each stack was refused.
function petports_upcycleWantsAny(machine, floorWaived)
	if machine.kind ~= "upcycler" then return false, "not an upcycler" end
	if not machine.enabled then return false, "switched off" end

	if self.petData == nil or self.petData.cargo == nil then
		return false, "no cargo"
	end

	local reasons = {}

	for _, stack in ipairs(self.petData.cargo) do
		local rule = nil

		for _, candidate in ipairs(machine.rules) do
			if candidate.item == stack.name then
				rule = candidate
				break
			end
		end

		if rule == nil then
			table.insert(reasons, string.format("%s: no rule names it", tostring(stack.name)))
		else
			local held = ((self.census or {})[stack.name] or 0) + (stack.count or 0)

			local batch = 1

			if not floorWaived then
				batch = math.min(
					math.ceil(petports_stackSizeOf(stack.name) * MACHINE_MIN_BATCH),
					stack.count or 1)
			end

			local room = petports_machineRuleRoom(machine, rule, stack)

			if held <= rule.max then
				table.insert(reasons, string.format("%s: network holds %s, threshold %s",
					tostring(stack.name), tostring(held), tostring(rule.max)))
			elseif room < batch then
				table.insert(reasons, string.format("%s: input has room for %s, want %s%s",
					tostring(stack.name), tostring(room), tostring(batch),
					floorWaived and " (floor waived, storage full)" or ""))
			else
				return true
			end
		end
	end

	return false, table.concat(reasons, "; ")
end

-- Returns how much surplus cargo a machine could take.
function petports_upcycleRoomFor(machine)
	local room = 0

	for _, stack in ipairs((self.petData and self.petData.cargo) or {}) do
		for _, rule in ipairs(machine.rules) do
			if rule.item == stack.name then
				local held = ((self.census or {})[stack.name] or 0) + (stack.count or 0)

				if held > rule.max then
					room = room + math.min(stack.count or 0,
						petports_machineRuleRoom(machine, rule, stack))
				end
			end
		end
	end

	return room
end

-- Returns a task to feed the upcycler with the most room, waiving the batch floor when storage is full.
function petports_upcycleWork()
	if self.petData == nil then return nil end
	if self.petData.cargo == nil or #self.petData.cargo == 0 then return nil end

	if petportOblivious() then return nil end
	if not petportParticipates("machines") then return nil end

	local candidates = {}
	local declined = {}
	local origin = entity.position()

	local floorWaived = not petports_depositStorageTakesAny()

	if floorWaived ~= self.floorWaived then
		self.floorWaived = floorWaived

		if floorWaived then
			sb.logInfo("PETPORT %s storage will not take the load -- WAIVING the "
				.. "upcycler batch floor to keep drops from decaying", stationUniqueId())
		else
			sb.logInfo("PETPORT %s storage has room again -- upcycler batch floor "
				.. "back in force", stationUniqueId())
		end
	end

	for _, machine in ipairs(self.machines or {}) do
		local workId = "upcycle:" .. tostring(machine.id)
		local failure = self.workFailures[workId]
		local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

		if backedOff then
			table.insert(declined, string.format("%s@%s,%s (backed off, %s failure(s))",
				tostring(machine.kind),
				tostring(math.floor(machine.position[1])),
				tostring(math.floor(machine.position[2])),
				tostring(failure.count)))

		elseif not petports_claimFree(workId) then
			table.insert(declined, string.format("%s@%s,%s (claimed by another unit)",
				tostring(machine.kind),
				tostring(math.floor(machine.position[1])),
				tostring(math.floor(machine.position[2]))))

		elseif world.entityExists(machine.id) then
			local wants, why = petports_upcycleWantsAny(machine, floorWaived)

			if wants then
				table.insert(candidates, {
					machine = machine,
					room = petports_upcycleRoomFor(machine),
					distance = world.magnitude(origin, machine.position)
				})
			else
				table.insert(declined, string.format("%s@%s,%s (%s)",
					tostring(machine.kind),
					tostring(math.floor(machine.position[1])),
					tostring(math.floor(machine.position[2])),
					tostring(why)))
			end
		end
	end

	if #candidates == 0 then
		local report = table.concat(declined, " || ")

		if #declined > 0 and report ~= self.upcyclerDeclined then
			self.upcyclerDeclined = report
			sb.logInfo("PETPORT %s upcycler declined: %s", stationUniqueId(), report)
		end

		return nil
	end

	self.upcyclerDeclined = nil

	table.sort(candidates, function(a, b)
		if a.room ~= b.room then return a.room > b.room end
		return a.distance < b.distance
	end)

	for _, candidate in ipairs(candidates) do
		local machine = candidate.machine

		local stand, standWhy = petports_servicePointNear("upcycler " .. tostring(machine.id),
			machine.id, machine.position, 4)

		if stand == nil then
			sb.logInfo("PETPORT %s upcycler %s SKIPPED: %s of %s",
				stationUniqueId(), sb.printJson(machine.id), tostring(standWhy),
				sb.printJson(machine.position))
		else
			sb.logInfo("PETPORT %s upcycling to %s at %s: room for %s, %s tile(s) away (%s candidate(s), %s)",
				stationUniqueId(), tostring(machine.kind), sb.printJson(machine.position),
				sb.printJson(candidate.room), sb.printJson(math.floor(candidate.distance)),
				sb.printJson(#candidates),
				floorWaived and "batch floor waived, storage full" or "normal")

			return {
				id = "upcycle:" .. tostring(machine.id),
				mediumVerified = true,
				type = "upcycle",
				target = machine.id,
				position = stand,
				containerPosition = machine.position,
				port = stationUniqueId(),
				dwell = 0
			}
		end
	end

	return nil
end

-- Moves the cargo into the machine when an upcycle task reports done.
function petports_upcycleDone(task, report)
	if task.type ~= "upcycle" then return end

	depositCargoToMachine(task.target, task.id)
end

petports_registerWork({
	name = "upcycle",
	order = 690,
	generate = function()
		if self.petData == nil then return nil end
		if self.petData.cargo == nil or #self.petData.cargo == 0 then return nil end

		local work = petports_upcycleWork()
		return work
	end,
	done = function(task, report) return petports_upcycleDone(task, report) end
})
