-- Port side of fishing: keeps a lure in the water, publishes the fish it draws and hands out tasks to catch them.

PETPORTS_CONSTANTS = PETPORTS_CONSTANTS or {}
PETPORTS_CONSTANTS.fish = PETPORTS_CONSTANTS.fish or {}

PETPORTS_CONSTANTS.fish.flag = "fishing"
PETPORTS_CONSTANTS.fish.lure = "petports_fishinglure"
PETPORTS_CONSTANTS.fish.lureLifetime = { 120, 300 }
PETPORTS_CONSTANTS.fish.dwell = 10
PETPORTS_CONSTANTS.fish.fishParameters = {
	hookDistance = 0,
	approachTimeRange = { 45, 75 },
	lurkTimeRange = { 45, 75 }
}
PETPORTS_CONSTANTS.fish.spawnerConfig = "/scripts/fishing/fishingspawner.config"
PETPORTS_CONSTANTS.fish.storeKey = "petports_fish"

-- Returns every published fish entry.
function petports_fishAll()
	return world.getProperty(PETPORTS_CONSTANTS.fish.storeKey) or {}
end

-- Writes a port's fish entry.
function petports_fishPublish(portId, entry)
	if portId == nil then return end

	local fish = petports_fishAll()
	fish[portId] = entry
	world.setProperty(PETPORTS_CONSTANTS.fish.storeKey, fish)
end

-- Drops a port's fish entry.
function petports_fishClearOwner(portId)
	if portId == nil then return end

	local fish = petports_fishAll()
	if fish[portId] == nil then return end

	sb.logInfo("PETPORTS fish entry from %s withdrawn (was %s)",
		tostring(portId), sb.printJson(fish[portId].id))

	fish[portId] = nil
	world.setProperty(PETPORTS_CONSTANTS.fish.storeKey, fish)
end

-- Drops every fish entry whose expiry has passed.
function petports_fishSweep()
	local fish = petports_fishAll()
	local now = world.time()
	local changed = false

	for portId, entry in pairs(fish) do
		if (entry.expires or 0) <= now then
			sb.logInfo("PETPORTS fish entry from %s EXPIRED (fish %s) -- its port "
				.. "never withdrew it", tostring(portId), sb.printJson(entry.id))
			fish[portId] = nil
			changed = true
		end
	end

	if changed then world.setProperty(PETPORTS_CONSTANTS.fish.storeKey, fish) end
end

-- Returns whether a fishing module is socketed.
function petports_fishSocketed()
	for _, flag in ipairs(petportModuleFlags()) do
		if flag == PETPORTS_CONSTANTS.fish.flag then return true end
	end
	return false
end

-- Returns the rects fishing may use.
function petports_fishRects()
	local rects = self.networkRects
	if rects == nil or #rects == 0 then rects = { petports_portCoverageRect() } end
	return rects
end

-- Returns a random deep, clear water point inside the fishing rects below a ceiling, or nil.
function petports_fishSubmergedSpot(cfg, ceiling)
	local rects = petports_fishRects()
	local threshold = cfg.liquidThreshold or 0.9

	for _ = 1, 24 do
		local rect = rects[math.random(#rects)]

		local top = rect[4]
		if ceiling ~= nil then top = math.min(top, ceiling) end
		if top >= rect[2] then
			local x = math.floor(rect[1] + math.random() * (rect[3] - rect[1])) + 0.5
			local y = math.floor(rect[2] + math.random() * (top - rect[2])) + 0.5
			local here = { x, y }

			local liquid = world.liquidAt(here)
			if liquid and liquid[2] >= threshold then
				local box = { here[1] + cfg.checkRegion[1], here[2] + cfg.checkRegion[2],
											here[1] + cfg.checkRegion[3], here[2] + cfg.checkRegion[4] }

				if not world.rectCollision(box) then
					local fill = world.liquidAt(box)
					if fill and fill[2] >= threshold then return here end
				end
			end
		end
	end

	return nil
end

-- Returns a lure spot, preferring the vanilla depth band, with the reason when there is none.
function petports_fishSpot()
	local ok, cfg = pcall(root.assetJson, PETPORTS_CONSTANTS.fish.spawnerConfig)
	if not ok or type(cfg) ~= "table" or type(cfg.pools) ~= "table"
			or type(cfg.checkRegion) ~= "table" then
		return nil, "vanilla's fishing spawner config is unreadable"
	end

	if cfg.pools[world.type()] ~= nil then
		local ceiling = world.oceanLevel(entity.position()) - (cfg.minDepth or 8)
		local spot = petports_fishSubmergedSpot(cfg, ceiling)
		if spot ~= nil then return spot, nil, "vanilla depth band" end
	end

	local spot = petports_fishSubmergedSpot(cfg, nil)
	if spot ~= nil then return spot, nil, "any submerged water, pending a zone" end

	return nil, "no clear submerged spot anywhere in network coverage"
end

-- Keeps one lure alive while fishing is wanted, and clears the lure and fish entry when it is not.
function petports_fishCheck()
	local wanted = petportEnabled() and self.petId ~= nil
		and world.entityExists(self.petId) and petports_fishSocketed()

	if self.lureId ~= nil and not world.entityExists(self.lureId) then
		self.lureId = nil
	end

	if not wanted then
		if self.lureId ~= nil then
			pcall(world.callScriptedEntity, self.lureId, "kill")
			sb.logInfo("PETPORT %s fishing lure %s dismissed -- no unit with a "
				.. "fishing module", stationUniqueId(), sb.printJson(self.lureId))
			self.lureId = nil
		end

		self.fishId = nil
		self.fishType = nil
		self.fishRarity = nil

		petports_fishClearOwner(stationUniqueId())
		return
	end

	if self.lureId ~= nil then return end

	local spot, why, tier = petports_fishSpot()
	if spot == nil then
		if self.fishingRefusal ~= why then
			self.fishingRefusal = why
			sb.logInfo("PETPORT %s cannot place a fishing lure: %s",
				stationUniqueId(), tostring(why))
		end
		return
	end
	self.fishingRefusal = nil

	local rects = petports_fishRects()

	local lifetime = util.randomInRange(PETPORTS_CONSTANTS.fish.lureLifetime)

	local parameters = {
		timeToLive = lifetime,
		petports_coverage = rects,
		petports_fishParameters = PETPORTS_CONSTANTS.fish.fishParameters
	}

	local ok, result = pcall(world.spawnProjectile,
		PETPORTS_CONSTANTS.fish.lure, spot, entity.id(), { 0, 0 }, false, parameters)

	if ok and result ~= nil then
		self.lureId = result
		sb.logInfo("PETPORT %s fishing lure %s placed at %s for %ss -- %s, across "
			.. "%s network rect(s)",
			stationUniqueId(), sb.printJson(result), sb.printJson(spot),
			sb.printJson(lifetime), tostring(tier),
			sb.printJson(#rects))
	else
		sb.logInfo("PETPORT %s failed to place a fishing lure at %s: %s",
			stationUniqueId(), sb.printJson(spot),
			ok and "spawnProjectile returned nil" or tostring(result))
	end
end

-- Returns whether this chassis can reach a fish at all, with the reason when it cannot.
function petports_fishCanReach()
	if not petports_fishSocketed() then return false, "no fishing module" end

	local monsterType = self.petData and self.petData.monsterType
	if monsterType == nil then return false, "no unit" end

	local caps = petports_habitatCapabilitiesForType(monsterType,
		petports_habitatPermittedSet(petportModuleLiquids()))

	if caps == nil then
		return false, "chassis capabilities unreadable"
	end

	if caps.freeMover then
		if caps.swim then return true end
		return false, string.format(
			"%s is a free mover that cannot swim, so it can never reach a fish",
			tostring(monsterType))
	end

	if caps.avoidLiquid == false then return true end

	return false, string.format(
		"%s is a walker that avoids liquid, so it can never reach a fish",
		tostring(monsterType))
end

-- Returns a task to catch the nearest published fish the unit can reach, or nil with a tally of why each was passed over.
function petports_fishWork()
	local canFish, why = petports_fishCanReach()
	if not canFish then return nil, why end

	local cargo = self.petData and self.petData.cargo
	if cargo ~= nil and #cargo > 0 then
		return nil, string.format(
			"the unit is carrying %s stack(s) and should deposit before fishing",
			sb.printJson(#cargo))
	end

	local published = petports_fishAll()
	local now = world.time()

	local from = entity.position()
	if self.petId ~= nil and world.entityExists(self.petId) then
		from = world.entityPosition(self.petId) or from
	end

	-- Returns whether a position lies in one of the fishing rects.
	local function reachableWater(position)
		for _, area in ipairs(petports_fishRects()) do
			if petports_rectContains(area, position) then return true end
		end
		return false
	end

	local best, bestDistance = nil, nil
	local offered = 0
	local rejected = { expired = 0, gone = 0, claimed = 0, backedOff = 0,
		outside = 0, medium = 0 }

	for _, memberId in ipairs(petports_networkMemberIds(stationUniqueId())) do
		local entry = published[memberId]

		if entry ~= nil and entry.id ~= nil then
			offered = offered + 1

			local workId = "fish:" .. entry.id
			local claim = petports_claimGet(workId)
			local failure = self.workFailures[workId]

			local free = (claim == nil)
				or claim.owner == stationUniqueId()
				or (claim.expires or 0) <= now

			if (entry.expires or 0) <= now then
				rejected.expired = rejected.expired + 1
			elseif not world.entityExists(entry.id) then
				rejected.gone = rejected.gone + 1
			elseif failure ~= nil and (failure["until"] or 0) > now then
				rejected.backedOff = rejected.backedOff + 1
			elseif not free then
				rejected.claimed = rejected.claimed + 1
			else
				local position = world.entityPosition(entry.id)

				if position == nil then
					rejected.gone = rejected.gone + 1

				elseif not reachableWater(position) then
					rejected.outside = rejected.outside + 1
				elseif not petports_targetSuits(position, nil) then
					rejected.medium = rejected.medium + 1
				else
					local distance = world.magnitude(from, position)

					if bestDistance == nil or distance < bestDistance then
						best = { entry = entry, port = memberId, position = position }
						bestDistance = distance
					end
				end
			end
		end
	end

	if best == nil then
		if offered == 0 then
			return nil, "no fish in the water anywhere in the network"
		end

		return nil, string.format(
			"%s fish in the network, none takeable: %s held by another port, "
			.. "%s backed off after a failure, %s outside network coverage, "
			.. "%s in a liquid this chassis cannot enter, %s gone, "
			.. "%s from a port that stopped reporting",
			sb.printJson(offered), sb.printJson(rejected.claimed),
			sb.printJson(rejected.backedOff), sb.printJson(rejected.outside),
			sb.printJson(rejected.medium),
			sb.printJson(rejected.gone), sb.printJson(rejected.expired))
	end

	sb.logInfo("PETPORT %s FISH dispatch: %s#%s (%s) at %s, %s away, from %s's "
		.. "lure (%s offered)",
		stationUniqueId(), tostring(best.entry.type), sb.printJson(best.entry.id),
		tostring(best.entry.rarity or "unknown rarity"),
		sb.printJson(best.position), sb.printJson(bestDistance),
		tostring(best.port), sb.printJson(offered))

	return {
		id = "fish:" .. best.entry.id,
		type = "fish",
		port = stationUniqueId(),
		target = best.entry.id,
		position = best.position,

		fishType = best.entry.type,
		fishRarity = best.entry.rarity,

		dwell = PETPORTS_CONSTANTS.fish.dwell
	}
end

-- Installs the handlers the lure and its fish report through.
function petports_fishInit()
message.setHandler("petports_fishSpawned", simpleHandler(function(fishId, fishType, rarity)
	self.fishId = fishId
	self.fishType = fishType

	self.fishRarity = rarity

	petports_fishPublish(stationUniqueId(), {
		id = fishId,
		type = fishType,
		rarity = rarity,
		expires = world.time() + PETPORTS_CONSTANTS.fish.lureLifetime[2]
	})

	sb.logInfo("PETPORT %s has a fish: %s (%s, %s)",
		stationUniqueId(), sb.printJson(fishId), tostring(fishType),
		tostring(rarity or "unknown rarity"))
end))

message.setHandler("petports_fishGone", simpleHandler(function(fishId)
	if self.fishId == fishId then
		self.fishId = nil
		self.fishType = nil
		self.fishRarity = nil

		petports_fishClearOwner(stationUniqueId())

		sb.logInfo("PETPORT %s fish %s is gone", stationUniqueId(),
			sb.printJson(fishId))
	end
end))
end

-- Clears the fish this port has published.
function petports_fishClear()
	petports_fishClearOwner(stationUniqueId())
end

-- Counts a catch, and its rarity tier, when a fish task reports done.
function petports_fishDone(task, report)
	if task.type ~= "fish" then return end

	petports_metrics.add("fished", 1)

	local tier = task.fishRarity
	if type(tier) == "string" and tier ~= "" then
		petports_metrics.add("fished_" .. tier, 1)
	end
end

petports_registerWork({
	name = "fish",
	order = 1300,
	reasonOrder = true,
	generate = function()
		local work, reason = petports_fishWork()
		if not petports_fishSocketed() then reason = nil end
		return work, reason
	end,
	init = function() return petports_fishInit() end,
	firstUpdate = function() return petports_fishClear() end,
	uninit = function() return petports_fishClear() end,
	workBeat = function() return petports_fishSweep() end,
	environmentBeat = function() return petports_fishCheck() end,
	done = function(task, report) return petports_fishDone(task, report) end
})
