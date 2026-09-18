-- Drives the module lamp brightness from the petports_lightIntensity status property.

local LIGHT = "petports_module_lamp"

local DEFAULT = 80


-- Returns petports_lightIntensity as a whole 0-255 value, or the configured default.
local function wantedIntensity()
	local stored = tonumber(status.statusProperty("petports_lightIntensity", nil))

	if stored == nil then return self.intensity end

	stored = math.floor(stored)
	if stored < 0 then stored = 0 end
	if stored > 255 then stored = 255 end

	return stored
end


-- Reads the default intensity parameter and clears the last applied level.
function init()
	self.intensity = tonumber(config.getParameter("intensity", DEFAULT)) or DEFAULT

	self.applied = nil
end

-- Applies the wanted brightness to the lamp when it differs from the last applied one.
function update(dt)
	local level = wantedIntensity()

	if level == self.applied then return end

	local ok, err = pcall(animator.setLightColor, LIGHT, { level, level, level })

	if not ok then
		self.applied = level
		sb.logInfo("PETPORTS lamplight: setLightColor(%s) failed: %s",
			tostring(level), tostring(err))
		return
	end

	self.applied = level
	sb.logInfo("PETPORTS lamplight: lamp is now %s", tostring(level))
end

-- Does nothing.
function uninit()
end
