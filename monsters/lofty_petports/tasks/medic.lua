-- Unit side of the medic: chases the patient the task names and doses them once in reach.

PETPORTS_TRACKED_TARGETS.medic = {
	field = "target",
	noun = "patient",
	reach = 5.0,
	moves = true,
	goneIsDone = true
}

PETPORTS_APPROACH_TYPES.medic = true

-- Doses the patient the task names once the unit has reached them, returning whether the task is over.
function petports_medicArrive(dt, stateData, task)
	if task.target == nil or not world.entityExists(task.target) then
		petports_taskReport(stateData, "done", string.format(
			"patient %s is gone -- no dose spent", sb.printJson(task.target)))
		return true
	end

	local health = world.entityHealth(task.target)

	if type(health) ~= "table" or health[2] == nil or health[2] <= 0 then
		petports_taskReport(stateData, "done", string.format(
			"patient %s reports no health -- no dose spent", sb.printJson(task.target)))
		return true
	end

	if health[1] >= health[2] then
		petports_taskReport(stateData, "done", string.format(
			"patient %s recovered on the way (%s/%s) -- no dose spent",
			sb.printJson(task.target), tostring(health[1]), tostring(health[2])))
		return true
	end

	local here = mcontroller.position()
	local there = world.entityPosition(task.target)
	local gap = world.magnitude(here, there)

	local ok, err = pcall(world.spawnProjectile,
		task.projectile or "petports_medicburst", there, entity.id(), {0, 0}, false, {})

	if not ok then
		petports_taskReport(stateData, "failed", string.format(
			"spawnProjectile failed at patient %s: %s",
			sb.printJson(task.target), tostring(err)))
		return true
	end

	sb.logInfo("UNIT medic DOSE patient %s (%s) at %s: health %s/%s, gap %s, effect %s for %ss",
		sb.printJson(task.target), tostring(task.patientClass), sb.printJson(there),
		tostring(health[1]), tostring(health[2]), sb.printJson(gap),
		tostring(task.effect), tostring(task.duration))

	task.dosed = 1

	petports_taskReport(stateData, "done", string.format(
		"dosed patient %s at %s/%s health", sb.printJson(task.target),
		tostring(health[1]), tostring(health[2])))
	return true
end

petports_taskArrive.medic = function(dt, stateData, task)
	return petports_medicArrive(dt, stateData, task)
end
