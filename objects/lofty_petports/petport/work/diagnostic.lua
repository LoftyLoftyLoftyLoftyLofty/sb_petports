-- Port side of the diagnostic walk: when switched on, sends an otherwise idle unit to a floor tile in the port's own rect. Off by default.

PETPORTS_CONSTANTS = PETPORTS_CONSTANTS or {}
PETPORTS_CONSTANTS.diagnostic = PETPORTS_CONSTANTS.diagnostic or {}

PETPORTS_CONSTANTS.diagnostic.dwell = 3.0
PETPORTS_CONSTANTS.diagnostic.fallback = false

-- Returns a task that walks the unit to a floor tile in this port's rect.
function petports_diagnosticWork()
	local rect = petports_portCoverageRect()
	local position = petports_findStandingPoint(rect)

	if position == nil then
		return nil, "no standing point in rect"
	end

	return {
		id = "diag:" .. stationUniqueId(),
		type = "diag",
		port = stationUniqueId(),
		position = position,
		dwell = PETPORTS_CONSTANTS.diagnostic.dwell
	}
end

petports_registerWork({
	name = "diagnostic",
	order = 2700,
	gate = function() return PETPORTS_CONSTANTS.diagnostic.fallback end,
	generate = function() return petports_diagnosticWork() end
})
