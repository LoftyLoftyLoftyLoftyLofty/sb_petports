-- Unit side of asterite mining: swings at the deposit on arrival, clears the mod and carries the drop home.

require "/scripts/lofty_petports/shared/asterite.lua"

PETPORTS_CONSTANTS.asterite.swingPeriod = 0.25
PETPORTS_CONSTANTS.asterite.swingsMin = 1
PETPORTS_CONSTANTS.asterite.sparks = 6
PETPORTS_CONSTANTS.asterite.sparkProjectile = "petports_asteritespark"
PETPORTS_CONSTANTS.asterite.clearMargin = 1
PETPORTS_CONSTANTS.asterite.reachBase = 8
PETPORTS_CONSTANTS.asterite.reachMax = 12

-- Returns the swing count, mining particle and mining sounds for a tile mod.
function petports_asteriteEffects(modName)
	local swings = PETPORTS_CONSTANTS.asterite.swingsMin
	local particle = nil
	local sounds = nil

	local ok, mod = pcall(root.modConfig, modName)

	if not ok or type(mod) ~= "table" or type(mod.config) ~= "table" then
		return swings, particle, sounds
	end

	local health = tonumber(mod.config.health)
	if health ~= nil and health > swings then swings = math.floor(health) end

	if type(mod.config.miningParticle) == "string" then
		particle = mod.config.miningParticle
	end

	if type(mod.config.miningSounds) == "table"
	   and #mod.config.miningSounds > 0 then

		local base = nil
		if type(mod.path) == "string" then
			base = mod.path:match("^(.*/)[^/]*$")
		end

		sounds = {}

		for _, entry in ipairs(mod.config.miningSounds) do
			if type(entry) == "string" then
				if entry:sub(1, 1) == "/" or base == nil then
					sounds[#sounds + 1] = entry
				else
					sounds[#sounds + 1] = base .. entry
				end
			end
		end

		if #sounds == 0 then sounds = nil end
	end

	return swings, particle, sounds
end

-- Spawns a projectile that plays the mining particles and sounds when it reaps.
function petports_asteriteSwingEffect(centre, particle, sounds)
	local reap = {}

	if particle ~= nil then
		reap[#reap + 1] =
		{
			action = "loop",
			count = PETPORTS_CONSTANTS.asterite.sparks,
			body = { { action = "particle", specification = particle } }
		}
	end

	if sounds ~= nil then
		reap[#reap + 1] = { action = "sound", options = sounds }
	end

	if #reap == 0 then return end

	local ok, err = pcall(world.spawnProjectile,
		PETPORTS_CONSTANTS.asterite.sparkProjectile,
		centre, entity.id(), { 0, 0 }, false, { actionOnReap = reap })

	if not ok then
		sb.logInfo("UNIT asterite swing effect failed at %s: %s",
			sb.printJson(centre), tostring(err))
	end
end

-- Returns the mining reach for this body size, capped.
function petports_asteriteReach()
	local bounds = mcontroller.boundBox()
	local body = 0

	if type(bounds) == "table" and #bounds >= 4 then
		body = math.max(math.abs(bounds[3] - bounds[1]),
			math.abs(bounds[4] - bounds[2]))
	end

	return math.min(PETPORTS_CONSTANTS.asterite.reachBase + body, PETPORTS_CONSTANTS.asterite.reachMax)
end

-- Returns the closest stored asterite deposit, with its key and range.
function petports_asteriteNearest()
	local here = mcontroller.position()
	local bestKey, bestEntry, bestRange

	for key, entry in pairs(petports_asteriteAll()) do
		if type(entry) == "table" and type(entry.position) == "table" then
			local range = world.magnitude(here,
				{ entry.position[1] + 0.5, entry.position[2] + 0.5 })

			if bestRange == nil or range < bestRange then
				bestKey, bestEntry, bestRange = key, entry, range
			end
		end
	end

	return bestKey, bestEntry, bestRange
end

-- Returns a number truncated to two decimal places.
function petports_asteriteRound2(n)
	return math.floor((tonumber(n) or 0) * 100) / 100
end

-- Places a matmod on a tile and logs the mod and material before and after.
function petports_asteriteSetMod(x, y, newMod, allowOverlap)
	if allowOverlap == nil then allowOverlap = true end

	local tile = { math.floor(tonumber(x) or 0), math.floor(tonumber(y) or 0) }

	local okMod, before = pcall(world.mod, tile, "foreground")
	local okMat, material = pcall(world.material, tile, "foreground")

	local okConfig = pcall(root.modConfig, tostring(newMod))

	sb.logInfo("UNIT placeMod harness at %s: mod %s, material %s -- asking for "
		.. "%s (modConfig resolves: %s), allowOverlap %s",
		sb.printJson(tile), tostring(okMod and before),
		tostring(okMat and material), tostring(newMod), tostring(okConfig),
		tostring(allowOverlap))

	local okPlace, placed = pcall(world.placeMod, tile, "foreground",
		tostring(newMod), nil, allowOverlap)

	local _, after = pcall(world.mod, tile, "foreground")
	local _, materialAfter = pcall(world.material, tile, "foreground")

	sb.logInfo("UNIT placeMod harness RESULT: ok %s returned %s -- mod %s to "
		.. "%s (%s), material %s to %s (%s)",
		tostring(okPlace), tostring(placed),
		tostring(before), tostring(after),
		(after ~= before) and "CHANGED" or "UNCHANGED",
		tostring(material), tostring(materialAfter),
		(materialAfter == material) and "INTACT" or "CHANGED")

	return placed
end

-- Damages a tile and logs the mod and material before and after.
function petports_asteriteDamage(x, y, amount, damageType, harvestLevel)
	local tile = { math.floor(tonumber(x) or 0), math.floor(tonumber(y) or 0) }

	amount = tonumber(amount) or 5
	damageType = tostring(damageType or "beamish")

	local okMod, before = pcall(world.mod, tile, "foreground")
	local okMat, material = pcall(world.material, tile, "foreground")

	local modHealth, modHarvest
	local okConfig, mod = pcall(root.modConfig, tostring(okMod and before))

	if okConfig and type(mod) == "table" and type(mod.config) == "table" then
		modHealth = mod.config.health
		modHarvest = mod.config.harvestLevel
	end

	if harvestLevel == nil then harvestLevel = modHarvest end

	sb.logInfo("UNIT damageTiles harness at %s: mod %s (health %s, harvest "
		.. "%s), material %s -- %s damage of type %s at harvestLevel %s",
		sb.printJson(tile), tostring(okMod and before),
		sb.printJson(modHealth), sb.printJson(modHarvest),
		tostring(okMat and material), sb.printJson(amount), damageType,
		sb.printJson(harvestLevel))

	local okDamage, damaged = pcall(world.damageTiles, { tile }, "foreground",
		mcontroller.position(), damageType, amount,
		tonumber(harvestLevel) or 0, entity.id())

	local _, after = pcall(world.mod, tile, "foreground")
	local _, materialAfter = pcall(world.material, tile, "foreground")

	sb.logInfo("UNIT damageTiles harness RESULT: ok %s returned %s -- mod %s "
		.. "to %s (%s), material %s to %s (%s)",
		tostring(okDamage), tostring(damaged),
		tostring(before), tostring(after),
		(after ~= before) and "CHANGED" or "UNCHANGED",
		tostring(material), tostring(materialAfter),
		(materialAfter == material) and "INTACT" or "GONE")

	return damaged
end

-- Clears the asterite mod off a tile within reach, spawns its item drop, and drops the store entry.
function petports_asteriteMine(x, y, allowOverlap, reachOverride)
	if allowOverlap == nil then allowOverlap = true end

	local modName = PETPORTS_CONSTANTS.asterite.mod
	local tile, key

	if x ~= nil and y ~= nil then
		tile = { math.floor(tonumber(x) or 0), math.floor(tonumber(y) or 0) }
		key = petports_tileKey(tile)
	else
		local entry
		key, entry = petports_asteriteNearest()

		if entry == nil then
			sb.logInfo("UNIT asterite probe: the store holds no deposits. Let a "
				.. "port scan one up first, or pass a tile by hand")
			return false
		end

		tile = { entry.position[1], entry.position[2] }

		modName = entry.mod or modName
	end

	local centre = { tile[1] + 0.5, tile[2] + 0.5 }
	local here = mcontroller.position()
	local range = world.magnitude(here, centre)

	local reach = tonumber(reachOverride) or petports_asteriteReach()

	local okMod, before = pcall(world.mod, tile, "foreground")
	local okMat, material = pcall(world.material, tile, "foreground")

	sb.logInfo("UNIT asterite probe at %s: mod %s, material %s, range %s of "
		.. "reach %s, allowOverlap %s",
		sb.printJson(tile), tostring(okMod and before),
		tostring(okMat and material), sb.printJson(petports_asteriteRound2(range)),
		sb.printJson(reach), tostring(allowOverlap))

	if not okMod or before ~= modName then
		sb.logInfo("UNIT asterite probe REFUSED: that tile carries %s, not %s",
			tostring(okMod and before), tostring(modName))

		if okMod and petports_asteriteClear(key) then
			sb.logInfo("UNIT asterite dropped the stale entry for %s (store "
				.. "now %s)", tostring(key),
				sb.printJson(petports_asteriteCount()))
		end

		return false
	end

	if range > reach then
		sb.logInfo("UNIT asterite probe REFUSED: out of reach by %s tiles. "
			.. "Unit is at %s, tile centre is %s -- pass a fourth argument to "
			.. "override the reach and test the removal from here",
			sb.printJson(petports_asteriteRound2(range - reach)), sb.printJson(here),
			sb.printJson(centre))
		return false
	end

	local okPlace, placed = pcall(world.placeMod, tile, "foreground",
		PETPORTS_CONSTANTS.asterite.cleared, nil, allowOverlap)

	local _, after = pcall(world.mod, tile, "foreground")
	local _, materialAfter = pcall(world.material, tile, "foreground")

	local removed = (after ~= modName)
	local intact = (materialAfter == material)

	sb.logInfo("UNIT asterite probe RESULT: placeMod ok %s returned %s -- mod "
		.. "%s to %s (%s), material %s to %s (%s)",
		tostring(okPlace), tostring(placed),
		tostring(before), tostring(after),
		removed and "REMOVED" or "STILL THERE",
		tostring(material), tostring(materialAfter),
		intact and "INTACT" or "CHANGED")

	if not removed then
		sb.logInfo("UNIT asterite probe FAILED: the mod survived. If this ran "
			.. "with allowOverlap true, try false; if both fail then placeMod "
			.. "is not reaching the world from a monster and the removal needs "
			.. "the projectile route instead")
		return false
	end

	if not intact then
		sb.logInfo("UNIT asterite probe DESTROYED THE TILE: %s became %s. "
			.. "placeMod is not a safe removal for a breaksWithTile mod and the "
			.. "feature needs a different primitive",
			tostring(material), tostring(materialAfter))
	end

	local okConfig, mod = pcall(root.modConfig, modName)
	local drop = nil

	if okConfig and type(mod) == "table" and type(mod.config) == "table" then
		drop = mod.config.itemDrop
	end

	if type(drop) == "string" and drop ~= "" then
		local okSpawn = pcall(world.spawnItem, drop, centre, 1)
		sb.logInfo("UNIT asterite probe dropped %s x1 at %s (spawn ok %s)",
			tostring(drop), sb.printJson(centre), tostring(okSpawn))
	else
		sb.logInfo("UNIT asterite probe: matmod %s names no itemDrop, so "
			.. "nothing was spawned", tostring(modName))
	end

	local cleared = petports_asteriteClear(key)

	sb.logInfo("UNIT asterite probe cleared store entry %s: %s (store now %s)",
		tostring(key), tostring(cleared), sb.printJson(petports_asteriteCount()))

	return true
end

-- Mines the deposit the task names once the unit has arrived, returning whether the task is over.
function petports_asteriteArrive(dt, stateData, task)
	local tile = task.tile

	if type(tile) ~= "table" or tile[1] == nil or tile[2] == nil then
		petports_taskReport(stateData, "failed", "asterite task carried no tile")
		return true
	end

	local modName = task.mod or PETPORTS_CONSTANTS.asterite.mod
	local centre = { tile[1] + 0.5, tile[2] + 0.5 }

	local okMod, before = pcall(world.mod, tile, "foreground")
	local okMat, material = pcall(world.material, tile, "foreground")

	if not okMod then
		petports_taskReport(stateData, "failed", string.format(
			"could not read the tile at %s on arrival", sb.printJson(tile)),
			nil, true)
		return true
	end

	if before ~= modName then
		local cleared = petports_asteriteClear(task.target)

		petports_taskReport(stateData, "failed", string.format(
			"arrived to find %s at %s, not %s -- entry dropped: %s",
			tostring(before), sb.printJson(tile), tostring(modName),
			tostring(cleared)))
		return true
	end

	local here = mcontroller.position()
	local range = world.magnitude(here, centre)
	local reach = petports_asteriteReach()

	if range > reach then
		petports_taskReport(stateData, "failed", string.format(
			"arrived %s from the deposit at %s but reach is %s (unit at %s, "
			.. "standing point was %s)", sb.printJson(math.floor(range * 100) / 100),
			sb.printJson(tile), sb.printJson(reach), sb.printJson(here),
			sb.printJson(task.position)), nil, true)
		return true
	end

	if task.asteriteSwings == nil then
		local swings, particle, sounds = petports_asteriteEffects(modName)

		task.asteriteSwings = swings
		task.asteriteParticle = particle
		task.asteriteSounds = sounds
		task.asteriteSwung = 0
		task.asteriteTimer = 0

		petports_publishBeam(centre, swings, PETPORTS_CONSTANTS.asterite.swingPeriod)

		sb.logInfo("UNIT asterite mining %s at %s: %s swing(s) at %ss, particle "
			.. "%s, %s sound(s)", tostring(modName), sb.printJson(tile),
			sb.printJson(swings), sb.printJson(PETPORTS_CONSTANTS.asterite.swingPeriod),
			tostring(particle or "none"),
			sb.printJson(sounds ~= nil and #sounds or 0))
	end

	task.asteriteTimer = (task.asteriteTimer or 0) - dt

	if task.asteriteTimer > 0 then return false end

	if task.asteriteSwung < task.asteriteSwings then
		task.asteriteSwung = task.asteriteSwung + 1
		petports_asteriteSwingEffect(centre, task.asteriteParticle, task.asteriteSounds)
		task.asteriteTimer = PETPORTS_CONSTANTS.asterite.swingPeriod

		return false
	end

	local okConfig, mod = pcall(root.modConfig, modName)
	local drop = nil

	if okConfig and type(mod) == "table" and type(mod.config) == "table" then
		drop = mod.config.itemDrop
	end

	if type(drop) ~= "string" or drop == "" then
		petports_taskReport(stateData, "failed", string.format(
			"matmod %s names no itemDrop -- refusing to remove it for nothing",
			tostring(modName)))
		return true
	end

	local okPlace, placed = pcall(world.placeMod, tile, "foreground",
		PETPORTS_CONSTANTS.asterite.cleared, nil, true)

	local _, after = pcall(world.mod, tile, "foreground")
	local _, materialAfter = pcall(world.material, tile, "foreground")

	if after == modName then
		petports_taskReport(stateData, "failed", string.format(
			"placeMod at %s ok %s returned %s and the deposit is still there",
			sb.printJson(tile), tostring(okPlace), tostring(placed)), nil, true)
		return true
	end

	local clearHealth = 0
	local okCleared, cleared = pcall(root.modConfig, PETPORTS_CONSTANTS.asterite.cleared)

	if okCleared and type(cleared) == "table" and type(cleared.config) == "table" then
		clearHealth = tonumber(cleared.config.health) or 0
	end

	local okClear = pcall(world.damageTiles, { tile }, "foreground",
		mcontroller.position(), "blockish", clearHealth + PETPORTS_CONSTANTS.asterite.clearMargin,
		0, entity.id())

	if not okClear then
		sb.logInfo("UNIT asterite clearing damage THREW at %s -- the placeholder "
			.. "stays until something overwrites it", sb.printJson(tile))
	end


	if okMat and materialAfter ~= material then
		sb.logInfo("UNIT asterite DESTROYED THE TILE at %s: %s became %s. This "
			.. "should be impossible via placeMod and the module must be pulled "
			.. "until it is understood", sb.printJson(tile), tostring(material),
			tostring(materialAfter))
	end

	petports_asteriteClear(task.target)

	petports_taskReport(stateData, "done", string.format(
		"mined %s at %s in %s swing(s) (%s -> %s, cleared, %s intact)",
		tostring(drop), sb.printJson(tile), sb.printJson(task.asteriteSwung or 0),
		tostring(before), tostring(after),
		tostring(material)), { name = drop, count = 1 })

	return true
end

petports_taskArrive.asterite = function(dt, stateData, task)
	return petports_asteriteArrive(dt, stateData, task)
end
