-- Unit side of tending livestock: reaches the animal the task names and pokes it so it drops its harvest.

PETPORTS_TRACKED_TARGETS.animal = {
	field = "target",
	noun = "animal",
	reach = 6.0,
	moves = true
}

PETPORTS_APPROACH_TYPES.animal = true

-- Tends the animal the task names once the unit has reached it, returning whether the task is over.
function petports_animalArrive(dt, stateData, task)
	local here = mcontroller.position()
	local there = world.entityPosition(task.target)
	local reach = world.magnitude(here, there)

	local animalType = world.monsterType(task.target)
	local okParams, params = pcall(root.monsterParameters, animalType)
	local base = (okParams and type(params) == "table"
		and type(params.baseParameters) == "table") and params.baseParameters or {}
	local harvestable = okParams and type(params) == "table"
		and (params.harvestPool or base.harvestPool) ~= nil
		and (params.harvestTime or base.harvestTime) ~= nil

	if not harvestable then
		petports_taskReport(stateData, "failed", string.format(
			"animal %s is type %s, which declares no harvest -- not poking it",
			sb.printJson(task.target), tostring(animalType)))
		return true
	end

	local okBefore, before = pcall(world.callScriptedEntity, task.target,
		"hasMonsterHarvest")

	if not okBefore or before ~= true then
		petports_taskReport(stateData, "failed", string.format(
			"animal %s is not ready (hasMonsterHarvest %s) -- harvested by someone else?",
			sb.printJson(task.target), tostring(before)))
		return true
	end

	local okDrop, dropped = pcall(world.callScriptedEntity, task.target,
		"dropMonsterHarvest")

	local okAfter, after = pcall(world.callScriptedEntity, task.target,
		"hasMonsterHarvest")

	sb.logInfo("UNIT animal poke %s: drop ok %s returned %s, ready %s -> %s",
		sb.printJson(task.target), tostring(okDrop), tostring(dropped),
		tostring(before), tostring(after))

	if okAfter and after == false then
		petports_taskReport(stateData, "done",
			"harvested animal " .. sb.printJson(task.target)
			.. " at " .. sb.printJson(there))
		return true
	end

	petports_taskReport(stateData, "failed", string.format(
		"poked %s and it is still ready (%s) -- dropMonsterHarvest did not run",
		sb.printJson(task.target), tostring(after)))
	return true
end

petports_taskArrive.animal = function(dt, stateData, task)
	return petports_animalArrive(dt, stateData, task)
end
