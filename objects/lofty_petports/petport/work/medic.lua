-- Port side of the medic: holds one medkit in its own slot, finds hurt friends in the network, fetches a medkit when it has none and hands out tasks to dose a patient.

PETPORTS_CONSTANTS = PETPORTS_CONSTANTS or {}
PETPORTS_CONSTANTS.medic = PETPORTS_CONSTANTS.medic or {}

PETPORTS_CONSTANTS.medic.flag = "medic"
PETPORTS_CONSTANTS.medic.item = "medicalgoods"
PETPORTS_CONSTANTS.medic.duration = 120
PETPORTS_CONSTANTS.medic.effect = "redstim"
PETPORTS_CONSTANTS.medic.projectile = "petports_medicburst"
PETPORTS_CONSTANTS.medic.reach = 6
PETPORTS_CONSTANTS.medic.classes = { "player", "crew", "npc", "podpet", "animal", "unit" }
PETPORTS_CONSTANTS.medic.storeKey = "petports_heals"

-- Returns every recorded heal cooldown.
function petports_healsAll()
	return world.getProperty(PETPORTS_CONSTANTS.medic.storeKey) or {}
end

-- Drops heal cooldowns that have passed or whose entity is gone.
function petports_healPrune(heals)
	local now = world.time()

	for key, readyAt in pairs(heals) do
		local id = tonumber(key)
		if type(readyAt) ~= "number" or readyAt <= now
		   or id == nil or not world.entityExists(id) then
			heals[key] = nil
		end
	end

	return heals
end

-- Returns the heal table key for an entity id.
function petports_healKey(entityId)
	return tostring(entityId)
end

-- Returns the seconds left on an entity's heal cooldown.
function petports_healCooldownRemaining(entityId)
	if entityId == nil then return 0 end

	local heals = petports_healsAll()
	local readyAt = heals[petports_healKey(entityId)]
	if type(readyAt) ~= "number" then return 0 end

	return math.max(readyAt - world.time(), 0)
end

-- Records a heal cooldown for an entity.
function petports_healRecord(entityId, duration)
	if entityId == nil then return false end

	local heals = petports_healPrune(petports_healsAll())
	heals[petports_healKey(entityId)] = world.time() + (duration or 0)
	world.setProperty(PETPORTS_CONSTANTS.medic.storeKey, heals)

	sb.logInfo("PETPORTS heal recorded for entity %s, next dose in %ss",
		tostring(entityId), tostring(duration or 0))
	return true
end

-- Returns the work id for healing an entity.
function petports_healWorkId(entityId)
	return "heal:" .. tostring(entityId)
end

-- Returns whether a medic module is socketed.
function petports_medicSocketed()
	for _, flag in ipairs(petportModuleFlags()) do
		if flag == PETPORTS_CONSTANTS.medic.flag then return true end
	end
	return false
end

-- Returns the held medkit, or nil.
function petports_medicKit()
	if self.petData == nil then return nil end

	local held = self.petData.medkit
	if type(held) ~= "table" or held.name == nil then return nil end

	return held
end

-- Returns which medic class an entity falls into, or nil when it is not friendly.
function petports_medicClassOf(id)
	local ok, kind = pcall(world.monsterType, id)
	if not ok then kind = nil end

	if petports_isUnitType(kind) then return "unit" end

	local team = world.entityDamageTeam(id)
	if team == nil or tostring(team.type) ~= "friendly" then
		return nil, team and tostring(team.type) or "no team"
	end

	local entityKind = tostring(world.entityType(id))
	if entityKind == "player" then return "player" end

	if entityKind == "npc" then
		if team.team == 0 then return "crew" end
		return "npc"
	end

	if team.team == 0 then return "podpet" end
	return "animal"
end

-- Returns whether a medic class is turned on.
function petports_medicHeals(class)
	if self.petData == nil then return false end

	local settings = self.petData.medic
	if type(settings) ~= "table" then return true end
	return settings[class] ~= false
end

-- Returns the hurt entities in the network the medic settings allow, most hurt first.
function petports_medicPatients()
	local rects = self.networkRects
	if rects == nil or #rects == 0 then rects = { petports_portCoverageRect() } end

	local candidates = {}
	local seen = {}

	for _, area in ipairs(rects) do
		local found = world.entityQuery({area[1], area[2]}, {area[3], area[4]},
			{ includedTypes = { "npc", "player", "monster" } })

		for _, id in ipairs(found or {}) do
			if not seen[id] then
				seen[id] = true
				table.insert(candidates, id)
			end
		end
	end

	local out = {}

	for _, id in ipairs(candidates) do
		local class = petports_medicClassOf(id)

		if class ~= nil and petports_medicHeals(class) then
			local health = world.entityHealth(id)

			if type(health) == "table" and health[2] ~= nil and health[2] > 0
					and health[1] < health[2] then

				if petports_healCooldownRemaining(id) <= 0 then
					table.insert(out, {
						id = id,
						class = class,
						ratio = health[1] / health[2],
						position = world.entityPosition(id)
					})
				end
			end
		end
	end

	table.sort(out, function(a, b) return a.ratio < b.ratio end)
	return out
end

-- Uses one medkit charge and writes the item back.
function petports_medicSpendKit()
	if self.petData == nil then return end

	local held = self.petData.medkit

	if type(held) ~= "table" or held.name == nil then
		sb.logError("PETPORT %s dosed a patient with an empty medkit",
			stationUniqueId())
		return
	end

	local count = (held.count or 1) - 1

	if count <= 0 then
		self.petData.medkit = nil
	else
		held.count = count
	end

	sb.logInfo("PETPORT %s spent 1 %s dosing; medkit now %s",
		stationUniqueId(), tostring(held.name),
		self.petData.medkit == nil and "empty" or sb.printJson(count))

	self.dirty = true
	self.paneSignature = nil
	writeBackToItem()
end

-- Returns the held medkit to the cargo once the medic module is gone.
function petports_medicReconcileKit()
	if self.petData == nil then return end

	local held = self.petData.medkit
	if held == nil then return end

	if type(held) ~= "table" or held.name == nil then
		sb.logError("PETPORT %s discarding a malformed medkit: %s",
			stationUniqueId(), sb.printJson(held))

		self.petData.medkit = nil
		self.dirty = true
		return
	end

	if petports_medicSocketed() then return end

	self.petData.medkit = nil
	self.paneSignature = nil

	sb.logInfo("PETPORT %s medic module is gone -- returning %s x%s from the "
		.. "medkit to cargo for deposit",
		stationUniqueId(), tostring(held.name), sb.printJson(held.count or 1))

	receiveCargo(held)
end

-- Returns a task to fetch a medkit, or to dose the first reachable patient.
function petports_medicWork(preloadOnly)
	if petportOblivious() then return nil, "oblivious" end
	if not petports_medicSocketed() then return nil, "no medic module socketed" end

	local carried = petports_medicKit()

	-- Returns a task to fetch a dose from storage, or nil with the reason.
	local function fetchDose()
		local containerId = petports_containerWithSeed(PETPORTS_CONSTANTS.medic.item,
			petportParticipates("medicdeposit"),
			petportParticipates("medicrestock"))

		if containerId == nil then
			return nil, string.format(
				"no %s in network storage this unit can reach", PETPORTS_CONSTANTS.medic.item)
		end

		local fetchId = "medicfetch:" .. stationUniqueId()
		local failure = self.workFailures[fetchId]

		if failure ~= nil and (failure["until"] or 0) > world.time() then
			return nil, "medic fetch backed off"
		end

		sb.logInfo("PETPORT %s MEDIC fetch: collecting one %s from %s",
			stationUniqueId(), tostring(PETPORTS_CONSTANTS.medic.item), sb.printJson(containerId))

		return {
			id = fetchId,
			mediumVerified = true,
			type = "withdraw",
			port = stationUniqueId(),
			target = containerId,
			seed = PETPORTS_CONSTANTS.medic.item,
			position = world.entityPosition(containerId)
		}
	end

	if preloadOnly then
		if carried ~= nil then return nil, "a dose is already held" end
		return fetchDose()
	end

	local patients = petports_medicPatients()
	if #patients == 0 then
		return nil, string.format("no treatable patient in network coverage (%s rects)",
			#(self.networkRects or {}))
	end

	if carried == nil then
		local task, why = fetchDose()

		if task == nil then
			return nil, string.format("%s patient(s) waiting, but %s",
				#patients, tostring(why))
		end

		return task
	end

	for _, patient in ipairs(patients) do
		local workId = petports_healWorkId(patient.id)
		local failure = self.workFailures[workId]
		local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

		if not backedOff and petports_claimFree(workId) then
			local stand = petports_portStandingPointNear(patient.position, PETPORTS_CONSTANTS.medic.reach)

			if stand ~= nil then
				sb.logInfo("PETPORT %s MEDIC dispatch: patient %s class %s at %s pct "
					.. "health, approach %s",
					stationUniqueId(), sb.printJson(patient.id), patient.class,
					sb.printJson(math.floor(patient.ratio * 100)), sb.printJson(stand))

				return {
					id = workId,
					type = "medic",
					port = stationUniqueId(),

					target = patient.id,
					patientClass = patient.class,

					item = PETPORTS_CONSTANTS.medic.item,
					effect = PETPORTS_CONSTANTS.medic.effect,
					duration = PETPORTS_CONSTANTS.medic.duration,
					projectile = PETPORTS_CONSTANTS.medic.projectile,

					position = stand
				}
			end

			sb.logInfo("PETPORT %s MEDIC patient %s SKIPPED: no standable spot within %s tiles of %s",
				stationUniqueId(), sb.printJson(patient.id), sb.printJson(PETPORTS_CONSTANTS.medic.reach),
				sb.printJson(patient.position))
		end
	end

	return nil, string.format("%s patient(s), none actionable", #patients)
end

-- Installs the handler the pane sets the healed classes through.
function petports_medicInit()
message.setHandler("petports_setMedic", simpleHandler(function(payload)
	if type(payload) ~= "table" then return false end
	if self.petData == nil then return false end

	local set = {}
	for _, class in ipairs(PETPORTS_CONSTANTS.medic.classes) do
		set[class] = payload[class] ~= false
	end

	self.petData.medic = set

	self.dirty = true
	self.paneSignature = nil

	self.workTimer = 0

	sb.logInfo("PETPORT %s medic classes: %s", stationUniqueId(), sb.printJson(set))
	return true
end))
end

-- Takes the first medkit that arrives into its own slot and returns what is left for the cargo, or nil.
function petports_medicReceive(item)
	if item.name ~= PETPORTS_CONSTANTS.medic.item or self.petData.medkit ~= nil
	   or not petports_medicSocketed() then
		return item
	end

	local whole = item.count or 1

	self.petData.medkit = {
		name = item.name,
		count = 1,
		parameters = copy(item.parameters)
	}

	sb.logInfo("PETPORT %s medkit loaded: 1 %s held for the next patient, "
		.. "%s of %s going to cargo",
		stationUniqueId(), tostring(item.name), sb.printJson(whole - 1),
		sb.printJson(whole))

	self.paneSignature = nil

	if whole <= 1 then return nil end

	return {
		name = item.name,
		count = whole - 1,
		parameters = item.parameters
	}
end

-- Spends the medkit, records the cooldown and counts the dose when a medic task reports done.
function petports_medicDone(task, report)
	if task.type ~= "medic" then return end

	local dosed = tonumber(report.dosed) or 0

	if dosed > 0 then
		petports_medicSpendKit()
		petports_healRecord(report.target or task.target, PETPORTS_CONSTANTS.medic.duration)
		petports_metrics.add("dosed", dosed)

		sb.logInfo("PETPORT %s medic finished: patient %s dosed, one %s spent, "
			.. "next dose for them in %ss",
			stationUniqueId(), sb.printJson(report.target or task.target),
			tostring(task.item), sb.printJson(PETPORTS_CONSTANTS.medic.duration))
	else
		sb.logInfo("PETPORT %s medic returned without dosing: %s",
			stationUniqueId(), tostring(report.reason))
	end
end

petports_registerWork({
	name = "medic",
	order = 900,
	idleLog = { key = "medicReason", label = "medic idle" },
	generate = function() return petports_medicWork() end,
	init = function() return petports_medicInit() end,
	socketed = function() return petports_medicReconcileKit() end,
	receive = function(item) return petports_medicReceive(item) end,
	done = function(task, report) return petports_medicDone(task, report) end
})

petports_registerWork({
	name = "medicPreload",
	order = 1200,
	idleLog = { key = "medicPreloadReason", label = "medic preload idle" },
	generate = function() return petports_medicWork(true) end
})
