local LIGHT = "petports_module_rgblamp"

local DEFAULT = { 140, 140, 140 }


local function sameColor(a, b)
	if a == nil or b == nil then return false end
	return a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

local function wantedColor()
	local stored = status.statusProperty("petports_lightColor", nil)

	if type(stored) ~= "table" then return DEFAULT end

	local out = {}

	for i = 1, 3 do
		local value = tonumber(stored[i])

		if value == nil then return DEFAULT end

		value = math.floor(value)
		if value < 0 then value = 0 end
		if value > 255 then value = 255 end

		out[i] = value
	end

	return out
end

function init()
	self.applied = nil
end

function update(dt)
	local color = wantedColor()

	if sameColor(color, self.applied) then return end

	local ok, err = pcall(animator.setLightColor, LIGHT, color)

	if not ok then
		self.applied = color
		sb.logInfo("PETPORTS rgblight: setLightColor(%s) failed: %s",
			sb.printJson(color), tostring(err))
		return
	end

	self.applied = color
	sb.logInfo("PETPORTS rgblight: lamp is now %s", sb.printJson(color))
end

function uninit()
end
