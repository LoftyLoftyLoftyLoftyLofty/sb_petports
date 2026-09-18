-- Cycles the module lamp through hues at a configured period.

local LIGHT = "petports_module_huelamp"

local SPEED_MIN = 1
local SPEED_MAX = 16

-- A speed of 1 is a turn every sixteen seconds, a speed of 16 a turn every one.
local SPEED_SPAN = SPEED_MIN + SPEED_MAX


-- Clamps a number to a range.
local function fclamp(value, low, high)
	if value < low then return low end
	if value > high then return high end
	return value
end

-- Maps a wrapped hue position to a 0-1 channel ramp.
local function wave(t)
	if t >= 1.0 then t = t - 1.0 end

	t = t * 6
	if t > 3 then t = -t + 6 end

	return fclamp(t - 1, 0, 1)
end

-- Converts hue, saturation and value into a 0-255 colour triple.
local function hueColor(hue, sat, val)
	hue = hue - math.floor(hue)

	sat = fclamp(sat, 0, 1)
	val = fclamp(val, 0, 1)

	-- Returns one colour channel for a hue offset.
	local function channel(offset)
		local c = wave(hue + offset) * sat + (1.0 - sat)

		return math.floor(c * val * 255 + 0.5)
	end

	return { channel(0), channel(1 / 3), channel(2 / 3) }
end



-- Returns the sweep period in seconds, signed by petports_lightReverse.
local function wantedPeriod()
	local speed = tonumber(status.statusProperty("petports_lightSpeed", nil))

	if speed == nil then return self.period end

	speed = math.floor(speed)
	if speed < SPEED_MIN then speed = SPEED_MIN end
	if speed > SPEED_MAX then speed = SPEED_MAX end

	local period = SPEED_SPAN - speed

	if status.statusProperty("petports_lightReverse", false) ~= true then return -period end

	return period
end

-- Returns petports_lightIntensity as a whole 0-255 value, or the configured default.
local function wantedIntensity()
	local stored = tonumber(status.statusProperty("petports_lightIntensity", nil))

	if stored == nil then return self.intensity end

	stored = math.floor(stored)
	if stored < 0 then stored = 0 end
	if stored > 255 then stored = 255 end

	return stored
end


-- Reads the default huePeriod, saturation and intensity parameters and logs them.
function init()
	self.period = tonumber(config.getParameter("huePeriod", -8)) or -8
	if self.period == 0 then self.period = -8 end

	self.saturation = tonumber(config.getParameter("saturation", 1)) or 1

	self.intensity = tonumber(config.getParameter("intensity", 80)) or 80

	self.hue = 0

	self.applied = nil

	sb.logInfo("PETPORTS huelight: defaults -- a turn every %ss (%s), sat %s, intensity %s/255",
		tostring(math.abs(self.period)),
		self.period < 0 and "widdershins" or "deasil",
		tostring(self.saturation), tostring(self.intensity))
end

-- Advances the hue by dt and applies the resulting colour when it changes.
function update(dt)
	self.hue = (self.hue + dt / wantedPeriod()) % 1

	local color = hueColor(self.hue, self.saturation, wantedIntensity() / 255)
	local applied = self.applied

	if applied ~= nil
	   and applied[1] == color[1]
	   and applied[2] == color[2]
	   and applied[3] == color[3] then
		return
	end

	local ok, err = pcall(animator.setLightColor, LIGHT, color)

	if not ok then
		self.applied = color
		sb.logInfo("PETPORTS huelight: setLightColor(%s) failed: %s",
			sb.printJson(color), tostring(err))
		return
	end

	self.applied = color
end

-- Does nothing.
function uninit()
end
