-- Unit side of harvesting: reaches the crop the task names, swings at it and confirms the harvest.

PETPORTS_CONSTANTS = PETPORTS_CONSTANTS or {}
PETPORTS_CONSTANTS.harvest = PETPORTS_CONSTANTS.harvest or {}

PETPORTS_CONSTANTS.harvest.damage = 0.2
PETPORTS_CONSTANTS.harvest.level = 1
PETPORTS_CONSTANTS.harvest.reach = 4.0
PETPORTS_CONSTANTS.harvest.timeout = 3.0

PETPORTS_TRACKED_TARGETS.harvest = {
	field = "target",
	noun = "crop",
	reach = nil,
	moves = false,
	dwell = 3.0
}

PETPORTS_APPROACH_TYPES.harvest = true

-- Swings at the crop the task names once the unit has reached it and waits for the harvest to show, returning whether the task is over.
function petports_harvestArrive(dt, stateData, task)
	if not stateData.swung then
		local here = mcontroller.position()
		local cropPosition = world.entityPosition(task.target)
		local reach = world.magnitude(here, cropPosition)

		if reach > PETPORTS_CONSTANTS.harvest.reach then
			petports_taskReport(stateData, "failed", string.format(
				"arrived but %s tiles from the crop at %s (unit at %s)",
				tostring(reach), sb.printJson(cropPosition), sb.printJson(here)))
			return true
		end

		local okBefore, before = pcall(world.farmableStage, task.target)
		stateData.stageBefore = okBefore and before or nil

		local tile = { math.floor(cropPosition[1]), math.floor(cropPosition[2]) }

		local okDamage, damaged = pcall(world.damageTiles, { tile }, "foreground",
			here, "plantish", PETPORTS_CONSTANTS.harvest.damage, PETPORTS_CONSTANTS.harvest.level)

		stateData.swung = true
		stateData.verifyTimer = PETPORTS_CONSTANTS.harvest.timeout

		sb.logInfo("UNIT harvest swing at %s tile %s: damageTiles ok %s returned %s "
			.. "(ignored), stage before %s -- watching for the result",
			sb.printJson(task.target), sb.printJson(tile), tostring(okDamage),
			tostring(damaged), sb.printJson(stateData.stageBefore))

		return false
	end

	local okAfter, after = pcall(world.farmableStage, task.target)
	if not okAfter then after = nil end

	if type(after) == "number" and type(stateData.stageBefore) == "number"
			and after ~= stateData.stageBefore then
		sb.logInfo("UNIT harvest confirmed on %s: stage %s -> %s (crop survived)",
			sb.printJson(task.target), sb.printJson(stateData.stageBefore),
			sb.printJson(after))

		petports_taskReport(stateData, "done",
			"harvested " .. sb.printJson(task.target)
			.. " at " .. sb.printJson(task.position)
			.. " (crop reset to stage " .. sb.printJson(after) .. ")")
		return true
	end

	stateData.verifyTimer = (stateData.verifyTimer or PETPORTS_CONSTANTS.harvest.timeout) - dt
	if stateData.verifyTimer <= 0 then
		petports_taskReport(stateData, "failed", string.format(
			"swung at %s and nothing changed in %ss (stage still %s) "
			.. "-- crop was not ready, or FARMABLE_STAGE_BASE is wrong",
			sb.printJson(task.target), sb.printJson(PETPORTS_CONSTANTS.harvest.timeout),
			sb.printJson(after)))
		return true
	end

	return false
end

-- Settles a harvest whose crop has vanished: done when the swing already landed, failed when it had not.
function petports_harvestTargetGone(stateData, task)
	if stateData.swung then
		petports_taskReport(stateData, "done",
			"harvested " .. sb.printJson(task.target)
			.. " at " .. sb.printJson(task.position) .. " (crop consumed)")
		return true
	end

	petports_taskReport(stateData, "failed", "crop is gone before the swing")
	return true
end

petports_taskArrive.harvest = function(dt, stateData, task)
	return petports_harvestArrive(dt, stateData, task)
end

petports_taskTargetGone.harvest = function(stateData, task)
	return petports_harvestTargetGone(stateData, task)
end
