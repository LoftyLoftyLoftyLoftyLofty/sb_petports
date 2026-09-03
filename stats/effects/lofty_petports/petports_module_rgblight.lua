--  PETPORTS -- RGB LAMP MODULE EFFECT SCRIPT
--
--  THE WHOLE JOB IS ONE CALL, AND EVERYTHING ELSE HERE IS ABOUT NOT MAKING IT
--  TWELVE TIMES A SECOND.
--
--  WHY A SCRIPT AT ALL, WHEN THE PLAIN LAMP NEEDS NONE. A light's colour lives
--  in an animation file, which is an asset and cannot be told anything at
--  runtime. status.setPersistentEffects carries effect NAMES and no payload, so
--  the port cannot hand a colour to the effect it is applying. The colour
--  arrives on the UNIT instead, as a status property, and this reads it from
--  there -- see petports_setLightColor in petports_contract.lua.
--
--  THE STATUS PROPERTY IS THE SHARED SURFACE BECAUSE NOTHING ELSE IS. This
--  script runs in its own context: it cannot see the unit's `self`, and the
--  unit cannot see this animator. Both can see the status controller.
--
--  animator HERE IS THE EFFECT'S OWN, NOT THE MONSTER'S, and it exists only
--  because the .statuseffect declares an animationConfig. Without that property
--  the table is absent and this file would be talking to nothing.

--  Spelled once here and once in the animation, and nowhere else.
local LIGHT = "petports_module_rgblamp"

--  WHAT THE ANIMATION ALREADY SHIPS. Matching it means the first update is a
--  no-op for an unconfigured unit rather than a redundant write of the value
--  that is already there.
local DEFAULT = { 140, 140, 140 }


local function sameColor(a, b)
	if a == nil or b == nil then return false end
	return a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

--  A COLOUR, OR THE DEFAULT, AND NEVER A MALFORMED ONE.
--
--  READ DEFENSIVELY BECAUSE THE PROPERTY IS NOT OURS ALONE. Status properties
--  are a flat namespace on the entity and anything at all may write one; a
--  table of the wrong shape reaching animator.setLightColor is a throw in an
--  update loop, which would take the effect down and leave the unit dark with
--  no obvious cause.
local function wantedColor()
	local stored = status.statusProperty("petports_lightColor", nil)

	if type(stored) ~= "table" then return DEFAULT end

	local out = {}

	for i = 1, 3 do
		local value = tonumber(stored[i])

		--  ONE BAD CHANNEL DISCARDS THE WHOLE COLOUR rather than being patched
		--  to a default beside two good ones, which would light the unit a
		--  colour nobody chose and look like the feature half working.
		if value == nil then return DEFAULT end

		value = math.floor(value)
		if value < 0 then value = 0 end
		if value > 255 then value = 255 end

		out[i] = value
	end

	return out
end

function init()
	--  NOT SEEDED TO DEFAULT. Leaving it nil forces the first update to write,
	--  whatever it finds -- which is what makes a unit that respawned already
	--  holding a colour light correctly on its first frame instead of waiting
	--  for the port's next push to change something.
	self.applied = nil
end

function update(dt)
	local color = wantedColor()

	--  CHANGE-GATED. scriptDelta 5 is a dozen calls a second per lit unit, and a
	--  fleet of them repainting an unchanged light is work with no possible new
	--  result. The comparison is on the value, not on the property, so a rewrite
	--  of the same colour costs nothing either.
	if sameColor(color, self.applied) then return end

	local ok, err = pcall(animator.setLightColor, LIGHT, color)

	if not ok then
		--  RECORDED AS APPLIED ANYWAY, SO A FAILURE IS ONE LOG LINE. A failing
		--  call left ungated would log twelve times a second for as long as the
		--  module stayed socketed, which buries whatever else is in the log.
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
