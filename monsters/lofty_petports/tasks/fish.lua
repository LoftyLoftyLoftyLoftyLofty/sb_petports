-- Unit side of fishing: chases the fish the task names, lands it and carries its treasure home.

PETPORTS_TRACKED_TARGETS.fish = {
	field = "target",
	noun = "fish",
	reach = 5.0,
	moves = true
}

PETPORTS_APPROACH_TYPES.fish = true

PETPORTS_SWIM_TASK_TYPES.fish = true

-- Returns the first pool name inside a treasure pool value.
function petports_fishPoolName(value)
	if type(value) == "string" then return value end
	if type(value) ~= "table" then return nil end

	if type(value.default) == "string" then return value.default end

	for _, entry in ipairs(value) do
		if type(entry) == "string" then return entry end

		if type(entry) == "table" then
			if type(entry.default) == "string" then return entry.default end

			for _, inner in ipairs(entry) do
				if type(inner) == "string" then return inner end
			end
		end
	end

	return nil
end

-- Lands the fish the task names once the unit has reached it, returning whether the task is over.
function petports_fishArrive(dt, stateData, task)
	local there = world.entityPosition(task.target)

	local declared, pool = nil, nil
	local okParams, params = pcall(root.monsterParameters, task.fishType)
	if okParams and type(params) == "table" then
		local base = type(params.baseParameters) == "table"
			and params.baseParameters or {}
		declared = params.landedTreasurePool or base.landedTreasurePool
		pool = petports_fishPoolName(declared)
	end

	if pool == nil or pool == "empty" then
		pcall(world.callScriptedEntity, task.target, "despawn")
		petports_taskReport(stateData, "done", string.format(
			"caught %s but it has no treasure pool (declared %s)",
			tostring(task.fishType), sb.printJson(declared)))
		return true
	end

	local okPool, poolExists = pcall(root.isTreasurePool, pool)
	if not okPool or poolExists ~= true then
		pcall(world.callScriptedEntity, task.target, "despawn")
		petports_taskReport(stateData, "done", string.format(
			"caught %s but pool %s does not exist (declared %s)",
			tostring(task.fishType), tostring(pool), sb.printJson(declared)))
		return true
	end

	local level = math.max(1, world.threatLevel())
	local okTreasure, treasure = pcall(root.createTreasure, pool, level)

	if not okTreasure or type(treasure) ~= "table" or #treasure == 0 then
		petports_taskReport(stateData, "failed", string.format(
			"caught %s but pool %s (declared %s) produced nothing at level %s: %s",
			tostring(task.fishType), tostring(pool), sb.printJson(declared),
			sb.printJson(level), tostring(treasure)))
		pcall(world.callScriptedEntity, task.target, "despawn")
		return true
	end

	pcall(world.callScriptedEntity, task.target, "despawn")

	sb.logInfo("UNIT CAUGHT %s (%s, %s) at %s -- %s stack(s) from pool %s at "
		.. "level %s",
		sb.printJson(task.target), tostring(task.fishType),
		tostring(task.fishRarity or "unknown rarity"), sb.printJson(there),
		sb.printJson(#treasure), tostring(pool), sb.printJson(level))

	petports_taskReport(stateData, "done", string.format(
		"caught %s (%s)", tostring(task.fishType),
		tostring(task.fishRarity or "unknown rarity")), treasure)
	return true
end

petports_taskArrive.fish = function(dt, stateData, task)
	return petports_fishArrive(dt, stateData, task)
end
