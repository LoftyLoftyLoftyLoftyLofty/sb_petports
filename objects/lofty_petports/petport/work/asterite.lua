-- Port side of asterite mining: finds deposits in coverage and hands out tasks to mine them.

require "/scripts/lofty_petports/shared/asterite.lua"

PETPORTS_CONSTANTS.asterite.flag = "asterite"
PETPORTS_CONSTANTS.asterite.standRadius = 8
PETPORTS_CONSTANTS.asterite.cacheTtl = 5.0
PETPORTS_CONSTANTS.asterite.standTries = 6

FAMILY_HELD.asterite = true

-- Turns asterite scanning on only when the matmod exists and drops a real item.
function petports_asteriteLatch()
	self.asteriteEnabled = false
	self.asteriteDrop = nil

	local ok, mod = pcall(root.modConfig, PETPORTS_CONSTANTS.asterite.mod)

	if not ok or type(mod) ~= "table" or type(mod.config) ~= "table" then
		sb.logInfo("PETPORT asterite scan OFF: no matmod named %s in this asset "
			.. "tree, so there is nothing for this port to look for",
			PETPORTS_CONSTANTS.asterite.mod)
		return
	end

	local drop = mod.config.itemDrop

	if type(drop) ~= "string" or drop == "" then
		sb.logInfo("PETPORT asterite scan OFF: matmod %s declares no itemDrop, so "
			.. "mining it would yield nothing", PETPORTS_CONSTANTS.asterite.mod)
		return
	end

	local okItem, item = pcall(root.itemConfig, drop)

	if not okItem or item == nil then
		sb.logInfo("PETPORT asterite scan OFF: matmod %s drops %s and no such item "
			.. "exists", PETPORTS_CONSTANTS.asterite.mod, tostring(drop))
		return
	end

	self.asteriteEnabled = true
	self.asteriteDrop = drop

	sb.logInfo("PETPORT asterite scan ON: matmod %s drops %s, %s tiles per sweep",
		PETPORTS_CONSTANTS.asterite.mod, tostring(drop),
		sb.printJson(math.floor(COVERAGE_SIZE) * math.floor(COVERAGE_SIZE)))
end

-- Returns a scan start index hashed from this port's unique id.
function petports_asteriteCursorSeed()
	local uniqueId = tostring(stationUniqueId() or "")
	local h = 0

	for i = 1, #uniqueId do
		h = (h * 31 + string.byte(uniqueId, i)) % 1048576
	end

	return h
end

-- Checks one tile of the coverage rect for the asterite mod, noting it in the store, and wraps at the end of a sweep.
function petports_asteriteScanStep()
	if not self.asteriteEnabled then return end

	local size = math.floor(COVERAGE_SIZE)
	if size < 1 then return end

	local span = size * size

	if self.asteriteCursor == nil then
		self.asteriteCursor = petports_asteriteCursorSeed() % span
		self.asteriteSweepAt = world.time()
		self.asteriteSweepNew = 0
		self.asteriteSweepSeen = 0

		sb.logInfo("PETPORT asterite scan starting at index %s of %s",
			sb.printJson(self.asteriteCursor), sb.printJson(span))
	end

	local rect = petports_portCoverageRect()
	local index = self.asteriteCursor

	local tile =
	{
		math.floor(rect[1]) + (index % size),
		math.floor(rect[2]) + math.floor(index / size)
	}

	local ok, modName = pcall(world.mod, tile, "foreground")

	if ok and modName == PETPORTS_CONSTANTS.asterite.mod then
		self.asteriteSweepSeen = (self.asteriteSweepSeen or 0) + 1

		local added, count, full =
			petports_asteriteNote(tile, modName, stationUniqueId())

		if added then
			self.asteriteSweepNew = (self.asteriteSweepNew or 0) + 1

			sb.logInfo("PETPORT asterite FOUND %s at %s (store now %s)",
				tostring(modName), sb.printJson(tile), sb.printJson(count))
		end

		if full ~= self.asteriteFullSaid then
			self.asteriteFullSaid = full

			if full then
				sb.logInfo("PETPORT asterite store FULL at %s entries; new deposits "
					.. "refused until something is mined", sb.printJson(count))
			else
				sb.logInfo("PETPORT asterite store has room again at %s entries",
					sb.printJson(count))
			end
		end
	end

	index = index + 1

	if index >= span then
		index = 0

		local elapsed = world.time() - (self.asteriteSweepAt or world.time())
		local seen = self.asteriteSweepSeen or 0
		local new = self.asteriteSweepNew or 0

		sb.logInfo("PETPORT asterite SCAN WRAP: %s tiles in %s s, %s deposit(s) "
			.. "seen, %s new, %s already known, store %s",
			sb.printJson(span), sb.printJson(math.floor(elapsed)),
			sb.printJson(seen), sb.printJson(new), sb.printJson(seen - new),
			sb.printJson(petports_asteriteCount()))

		self.asteriteSweepAt = world.time()
		self.asteriteSweepNew = 0
		self.asteriteSweepSeen = 0
	end

	self.asteriteCursor = index
end

-- Logs the stored deposits up to a limit and returns how many there are.
function petports_asteriteDump(limit)
	limit = tonumber(limit) or 40

	local deposits = petports_asteriteAll()
	local n = 0
	local shown = 0

	for _, entry in pairs(deposits) do
		n = n + 1

		if shown < limit then
			shown = shown + 1

			sb.logInfo("PETPORT asterite [%s] %s at %s, found at %s by %s",
				sb.printJson(n), tostring(entry.mod), sb.printJson(entry.position),
				sb.printJson(math.floor(tonumber(entry.found) or 0)),
				tostring(entry.finder))
		end
	end

	sb.logInfo("PETPORT asterite dump: %s deposit(s) of %s shown, cap %s, "
		.. "this port's scan is %s, cursor %s",
		sb.printJson(shown), sb.printJson(n),
		sb.printJson(petports_asteriteCap()),
		self.asteriteEnabled and "ON" or "OFF",
		sb.printJson(self.asteriteCursor or -1))

	return n
end

-- Returns whether an asterite module is socketed.
function petports_asteriteSocketed()
	for _, flag in ipairs(petportModuleFlags()) do
		if flag == PETPORTS_CONSTANTS.asterite.flag then return true end
	end
	return false
end

-- Returns a task to mine the nearest known asterite deposit the unit can stand at.
function petports_asteriteWork()
	if self.asteriteCacheAt == nil or world.time() >= self.asteriteCacheAt then
		self.asteriteCacheAt = world.time() + PETPORTS_CONSTANTS.asterite.cacheTtl
		self.asteriteCache = petports_asteriteAll()
	end

	local deposits = self.asteriteCache or {}

	local from = entity.position()
	if self.petId ~= nil and world.entityExists(self.petId) then
		from = world.entityPosition(self.petId)
	end

	local seen = 0
	local candidates = {}
	local rejected = { outside = 0, claimed = 0, backedOff = 0, medium = 0 }

	for key, entry in pairs(deposits) do
		if type(entry) == "table" and type(entry.position) == "table" then
			seen = seen + 1

			local centre = { entry.position[1] + 0.5, entry.position[2] + 0.5 }
			local workId = "asterite:" .. tostring(key)

			local failure = self.workFailures[workId]
			local backedOff = failure ~= nil
				and (failure["until"] or 0) > world.time()

			if not petports_inNetworkCoverage(centre) then
				rejected.outside = rejected.outside + 1
			elseif backedOff then
				rejected.backedOff = rejected.backedOff + 1
			elseif not petports_claimFree(workId) then
				rejected.claimed = rejected.claimed + 1

			elseif not petports_targetEligible("asterite " .. tostring(key), centre) then
				rejected.medium = rejected.medium + 1
			else
				candidates[#candidates + 1] = {
					key = key,
					entry = entry,
					centre = centre,
					workId = workId,
					distance = world.magnitude(from, centre)
				}
			end
		end
	end

	if #candidates == 0 then
		local reason = string.format(
			"%s deposit(s) known, none workable: %s outside network coverage, "
			.. "%s claimed, %s backed off, %s in a medium this chassis cannot "
			.. "work in", seen, rejected.outside, rejected.claimed,
			rejected.backedOff, rejected.medium)

		if reason ~= self.asteriteRejectReason then
			self.asteriteRejectReason = reason
			sb.logInfo("PETPORT %s asterite: %s", stationUniqueId(), reason)
		end

		return nil, reason
	end

	table.sort(candidates, function(a, b) return a.distance < b.distance end)

	local tries = 0

	for _, candidate in ipairs(candidates) do
		if tries >= PETPORTS_CONSTANTS.asterite.standTries then break end
		tries = tries + 1

		local stand = petports_standingPointForTarget(candidate.centre, nil,
			PETPORTS_CONSTANTS.asterite.standRadius, true)

		if stand ~= nil then
			self.asteriteRejectReason = nil

			sb.logInfo("PETPORT %s asterite deposit at %s, %s away -- "
				.. "offering a stand at %s (%s of %s candidates tried)",
				stationUniqueId(), sb.printJson(candidate.entry.position),
				sb.printJson(math.floor(candidate.distance * 10) / 10),
				sb.printJson(stand), sb.printJson(tries),
				sb.printJson(#candidates))

			return {
				id = candidate.workId,
				mediumVerified = true,

				type = "asterite",
				port = stationUniqueId(),

				target = candidate.key,

				tile = { candidate.entry.position[1], candidate.entry.position[2] },

				mod = candidate.entry.mod,

				distance = candidate.distance,

				position = stand
			}
		end
	end

	local reason = string.format(
		"%s workable deposit(s), nowhere to stand within %s tiles of the "
		.. "nearest %s", #candidates, PETPORTS_CONSTANTS.asterite.standRadius, tries)

	if reason ~= self.asteriteRejectReason then
		self.asteriteRejectReason = reason
		sb.logInfo("PETPORT %s asterite: %s", stationUniqueId(), reason)
	end

	return nil, reason
end

-- Clears the scan state and latches scanning on or off.
function petports_asteriteInit()
	self.asteriteCursor = nil
	self.asteriteSweepAt = nil
	self.asteriteSweepNew = 0
	self.asteriteSweepSeen = 0

	self.asteriteFullSaid = false

	petports_asteriteLatch()
end

petports_registerWork({
	name = "asterite",
	order = 1700,
	reasonOrder = true,
	gate = function()
		return not petportOblivious() and petports_asteriteSocketed()
			and not petports_familyOnHold("asterite")
	end,
	generate = function() return petports_asteriteWork() end,
	init = function() return petports_asteriteInit() end,
	tick = function(dt) return petports_asteriteScanStep(dt) end
})
