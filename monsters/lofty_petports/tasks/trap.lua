-- Unit side of emptying traps: reaches the trap the task names and makes it drop its harvest.

PETPORTS_CONSTANTS = PETPORTS_CONSTANTS or {}
PETPORTS_CONSTANTS.trap = PETPORTS_CONSTANTS.trap or {}

PETPORTS_CONSTANTS.trap.reach = 4.0

PETPORTS_TRACKED_TARGETS.trap = {
	field = "target",
	noun = "trap",
	reach = nil,
	moves = false
}

PETPORTS_APPROACH_TYPES.trap = true

-- Empties the trap the task names once the unit has reached it, returning whether the task is over.
function petports_trapArrive(dt, stateData, task)
	if not world.entityExists(task.target) then
		petports_taskReport(stateData, "failed", "trap was gone on arrival")
		return true
	end

	local here = mcontroller.position()
	local there = world.entityPosition(task.target)
	local reach = world.magnitude(here, there)

	if reach > PETPORTS_CONSTANTS.trap.reach then
		petports_taskReport(stateData, "failed", string.format(
			"arrived but %s tiles from the trap at %s (unit at %s)",
			sb.printJson(reach), sb.printJson(there), sb.printJson(here)))
		return true
	end

	local okBefore, before = pcall(world.callScriptedEntity, task.target,
		"activeAge")

	if not okBefore or type(before) ~= "number" then
		petports_taskReport(stateData, "failed", string.format(
			"trap %s did not answer activeAge (%s) -- not a harvestable, or its "
			.. "script is dead",
			sb.printJson(task.target), tostring(before)))
		return true
	end

	local ripeAt = tonumber(task.ripeAt) or 0

	if before < ripeAt then
		petports_taskReport(stateData, "failed", string.format(
			"trap %s is not ready: active age %s of %s -- emptied by someone else?",
			sb.printJson(task.target), sb.printJson(before), sb.printJson(ripeAt)))
		return true
	end

	local okDrop, dropped = pcall(world.callScriptedEntity, task.target,
		"dropHarvest")

	local okAfter, after = pcall(world.callScriptedEntity, task.target,
		"activeAge")

	sb.logInfo("UNIT trap harvest %s: dropHarvest ok %s returned %s, "
		.. "active age %s -> %s (threshold %s)",
		sb.printJson(task.target), tostring(okDrop), tostring(dropped),
		sb.printJson(before), tostring(after), sb.printJson(ripeAt))

	if okAfter and type(after) == "number" and after < before then
		petports_taskReport(stateData, "done",
			"harvested trap " .. sb.printJson(task.target)
			.. " at " .. sb.printJson(there))
		return true
	end

	petports_taskReport(stateData, "failed", string.format(
		"called dropHarvest on %s and its active age did not reset (%s -> %s) "
		.. "-- the trap was not on its harvest stage",
		sb.printJson(task.target), sb.printJson(before), tostring(after)))
	return true
end

petports_taskArrive.trap = function(dt, stateData, task)
	return petports_trapArrive(dt, stateData, task)
end
