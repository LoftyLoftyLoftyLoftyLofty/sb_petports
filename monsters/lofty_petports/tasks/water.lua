-- Unit side of watering: walks the dry run the task names and pours water on each tile.

PETPORTS_CONSTANTS = PETPORTS_CONSTANTS or {}
PETPORTS_CONSTANTS.water = PETPORTS_CONSTANTS.water or {}

PETPORTS_CONSTANTS.water.dropHeight = 1.0
PETPORTS_CONSTANTS.water.reach = 4.0

PETPORTS_APPROACH_TYPES.water = true

-- Returns the point above the run's current tile, or nil when the run is finished.
function petports_waterTarget(task)
	local tile = task.tiles ~= nil and task.tiles[task.waterIndex or 1] or nil
	if tile == nil then return nil end

	return { tile[1] + 0.5, tile[2] + 1.5 }
end

-- Pours water on the run's current tile once the unit stands by it, returning whether the task is over.
function petports_waterArrive(dt, stateData, task)
	local tiles = task.tiles or {}
	local index = task.waterIndex or 1
	local tile = tiles[index]

	if tile == nil then
		petports_taskReport(stateData, "done",
			"swept " .. sb.printJson(task.watered or 0) .. " tile(s)")
		return true
	end

	local here = mcontroller.position()
	local standing = { tile[1] + 0.5, tile[2] + 1.5 }

	if world.magnitude(here, standing) > PETPORTS_CONSTANTS.water.reach then
		petports_taskReport(stateData, "failed", string.format(
			"arrived but %s from tile %s -- sweep abandoned after %s tile(s)",
			sb.printJson(world.magnitude(here, standing)), sb.printJson(tile),
			sb.printJson(task.watered or 0)))
		return true
	end

	local modNow = world.mod({ tile[1], tile[2] }, "foreground")

	if tostring(modNow) ~= tostring(task.previousMod) then
		sb.logInfo("UNIT water SKIP tile %s: mod is %s, expected %s -- "
			.. "already wet or no longer farmland",
			sb.printJson(tile), tostring(modNow), tostring(task.previousMod))
	else
		local spawn = { tile[1] + 0.25, standing[2] + PETPORTS_CONSTANTS.water.dropHeight }

		local ok, err = pcall(world.spawnProjectile,
			"petports_watersprinkle", spawn, entity.id(), {0, -1}, false, {
				actionOnReap = { {
					action = "applySurfaceMod",
					previousMod = task.previousMod,
					newMod = task.newMod,
					radius = 0
				} },

				processing = task.tint ~= nil and ("?multiply=" .. task.tint) or nil
			})

		sb.logInfo("UNIT water CAST tile %s aim x %s spawn %s: %s -> %s, tint %s, ok %s %s",
			sb.printJson(tile), sb.printJson(spawn[1]), sb.printJson(spawn),
			tostring(task.previousMod), tostring(task.newMod),
			tostring(task.tint or "none"), tostring(ok), tostring(err or ""))

		if not ok then
			petports_taskReport(stateData, "failed", string.format(
				"spawnProjectile failed at %s after %s tile(s): %s",
				sb.printJson(tile), sb.printJson(task.watered or 0), tostring(err)))
			return true
		end

		task.watered = (task.watered or 0) + 1
	end

	task.waterIndex = index + 1

	if task.waterIndex > #tiles then
		petports_taskReport(stateData, "done",
			"swept " .. sb.printJson(#tiles) .. " tile(s), watered "
			.. sb.printJson(task.watered or 0))
		return true
	end

	stateData.arrived = false
	stateData.groundTarget = nil
	stateData.approachTimer = PETPORTS_CONSTANTS.task.approachTimeout
	stateData.searchingTimer = 0
	petports_freshPather("water sweep advancing to tile " .. sb.printJson(task.waterIndex))

	return false
end

petports_taskTarget.water = function(task)
	return petports_waterTarget(task)
end

petports_taskArrive.water = function(dt, stateData, task)
	return petports_waterArrive(dt, stateData, task)
end
