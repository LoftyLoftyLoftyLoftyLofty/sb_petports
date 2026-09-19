-- Unit side of collecting: reaches the drop the task names and picks it up. The port's ground-feed work hands out collect tasks too.

PETPORTS_TRACKED_TARGETS.collect = {
	field = "target",
	noun = "drop",
	reach = nil,
	moves = false
}

PETPORTS_APPROACH_TYPES.collect = true

-- Picks up the drop the task names once the unit has reached it, returning whether the task is over.
function petports_collectArrive(dt, stateData, task)
	local ok, taken = pcall(world.takeItemDrop, task.target, entity.id())

	sb.logInfo("UNIT pickup attempt on %s: ok %s taken %s (dwell left %s)",
		sb.printJson(task.target), tostring(ok), sb.printJson(taken),
		sb.printJson(stateData.dwellTimer))

	if ok and taken then
		petports_taskReport(stateData, "done",
			"collected at " .. sb.printJson(task.position), taken)
		return true
	end

	stateData.dwellTimer = stateData.dwellTimer - dt
	if stateData.dwellTimer <= 0 then
		petports_taskReport(stateData, "failed",
			"arrived but could not take drop (pcall ok=" .. tostring(ok) .. ")")
		return true
	end

	return false
end

petports_taskArrive.collect = function(dt, stateData, task)
	return petports_collectArrive(dt, stateData, task)
end
