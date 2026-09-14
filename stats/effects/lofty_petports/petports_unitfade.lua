local DEFAULT_COLOR = "ff00ff"
local WHITE = { 255, 255, 255 }

local function parseColor(hex)
	if type(hex) ~= "string" or #hex < 6 then
		return nil
	end

	local rgb = {}

	for i = 0, 2 do
		local channel = tonumber(hex:sub(i * 2 + 1, i * 2 + 2), 16)

		if channel == nil then
			return nil
		end

		rgb[#rgb + 1] = channel
	end

	return rgb
end

local function hex6(rgb)
	return string.format("%02x%02x%02x", rgb[1], rgb[2], rgb[3])
end

local function lerp(ratio, from, to)
	return math.floor(from + (to - from) * ratio)
end

function init()
	self.grow = config.getParameter("grow", false)
	self.killOnFinish = config.getParameter("killOnFinish", false)
	self.fadeColorDuration = config.getParameter("fadeColorDuration", 0.1)
	self.shrinkDuration = config.getParameter("shrinkDuration", 0.2)
	self.borderWidth = config.getParameter("borderWidth", 3)

	self.fadeColor = parseColor(status.statusProperty("petports_fadeColor", DEFAULT_COLOR))
		or parseColor(DEFAULT_COLOR)

	local bounds = mcontroller.boundBox()
	local widest = math.max(bounds[3] - bounds[1], bounds[4] - bounds[2])
	local shrinkSize = config.getParameter("shrinkSize", 0.25)

	self.shrinkRatio = 1.0
	if widest > 0 then
		self.shrinkRatio = math.min(shrinkSize / widest, 1.0)
	end

	self.total = self.fadeColorDuration + self.shrinkDuration

	self.elapsed = 0
	if self.grow then
		self.elapsed = self.total
	end

	effect.addStatModifierGroup({
		{ stat = "invulnerable", amount = 1 }
	})

	status.setResource("stunned", math.max(status.resource("stunned"), effect.duration()))

	applyAt(self.elapsed)

	self.whooshPlayed = false
end

function applyAt(elapsed)
	local toColor = { self.fadeColor[1], self.fadeColor[2], self.fadeColor[3] }
	local fade = 1.0
	local scale = 1.0

	if elapsed < self.fadeColorDuration then
		fade = elapsed / self.fadeColorDuration
	elseif elapsed < self.total then
		local ratio = (elapsed - self.fadeColorDuration) / self.shrinkDuration

		for i = 1, 3 do
			toColor[i] = lerp(ratio, toColor[i], WHITE[i])
		end

		scale = 1.0 + (self.shrinkRatio - 1.0) * ratio
	else
		toColor = { WHITE[1], WHITE[2], WHITE[3] }
		scale = self.shrinkRatio
	end

	local border = hex6(self.fadeColor)
	local borderAlpha = math.max(math.min(math.floor(fade * 255), 255), 0)

	effect.setParentDirectives(string.format(
		"?fade=%s;%.1f?scalenearest=%.2f?border=%d;%s%02x;%s00",
		hex6(toColor), fade,
		scale,
		self.borderWidth, border, borderAlpha, border))
end

local whooshReported = false

function playWhooshOnce()
	if self.whooshPlayed then
		return
	end
	self.whooshPlayed = true

	local cue = "dematerialise"
	if self.grow then
		cue = "materialise"
	end

	local ok, err = pcall(animator.playSound, cue)

	if not ok and not whooshReported then
		whooshReported = true
		sb.logError("PETPORTS unitfade could not play '%s': %s", cue, tostring(err))
	end
end

function update(dt)
	if self.grow then
		self.elapsed = self.elapsed - dt
	else
		self.elapsed = self.elapsed + dt
	end

	if self.grow and self.elapsed < 0 then
		effect.setParentDirectives("")
		effect.expire()
		return
	end

	applyAt(self.elapsed)
	playWhooshOnce()

	mcontroller.setVelocity({0, 0})
	status.setResource("stunned", math.max(status.resource("stunned"), effect.duration()))

	if self.killOnFinish and self.elapsed >= self.total then
		status.setResource("health", 0)
	end
end

function uninit()
	if not self.killOnFinish then
		effect.setParentDirectives("")
	end
end
