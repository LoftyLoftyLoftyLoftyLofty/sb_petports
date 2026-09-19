-- Port side of recalling the unit: walks it home when it is stranded or outside the network, and re-homes it once the recalls run out. The failure counts themselves stay in the main file.

-- Returns a task to walk the unit home when it is stranded or outside the network, re-homing it once the recalls run out.
function petports_returnWork()
	local rect = petports_portCoverageRect()

	if self.petId == nil or not world.entityExists(self.petId) then return nil end

	local stranded = (self.unreachableFailures or 0) >= STRANDED_LIMIT
	local inside = petports_inNetworkCoverage(world.entityPosition(self.petId))

	local recallState = string.format("%s/%s/%s/%s", tostring(inside),
		tostring(stranded), tostring(self.unreachableFailures or 0),
		tostring(self.recallFailures or 0))

	if recallState ~= self.recallState then
		self.recallState = recallState

		sb.logInfo("PETPORT %s petports_returnWork: unit at %s petports_inNetworkCoverage %s stranded %s (unreachableFailures %s of %s, recallFailures %s of %s)",
			stationUniqueId(), sb.printJson(world.entityPosition(self.petId)),
			tostring(inside), tostring(stranded),
			sb.printJson(self.unreachableFailures or 0), sb.printJson(STRANDED_LIMIT),
			sb.printJson(self.recallFailures or 0), sb.printJson(RECALL_LIMIT))
	end

	if not stranded and inside then
		self.recallFailures = 0
		return nil
	end

	sb.logInfo("PETPORT %s petports_returnWork: RECALLING -- collection is suppressed this pass",
		stationUniqueId())

	if (self.recallFailures or 0) >= RECALL_LIMIT then
		petports_rehomeUnit("stranded outside rect at "
			.. sb.printJson(world.entityPosition(self.petId))
			.. " after " .. sb.printJson(RECALL_LIMIT) .. " failed recalls")
		return nil
	end

	local position = petports_portHomePosition()

	if position == nil then
		petports_rehomeUnit("no standing point in rect to recall to")
		return nil
	end

	return {
		id = "return:" .. stationUniqueId(),
		type = "return",
		port = stationUniqueId(),
		position = position,
		dwell = 0.5
	}
end

petports_registerWork({
	name = "return",
	order = 100,
	generate = function() return petports_returnWork() end
})
