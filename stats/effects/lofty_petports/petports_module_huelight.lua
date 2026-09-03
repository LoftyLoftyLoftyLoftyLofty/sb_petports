--  PETPORTS -- HUE LAMP MODULE EFFECT SCRIPT
--
--  THE RGB LAMP WITHOUT THE PLAYER. Same light, same animator, same
--  setLightColor call -- the colour comes from a clock instead of from petData,
--  so this module needs NO pane rows, NO petData, NO port handler and NO push.
--  That is the whole reason it is a third lamp rather than a mode of the
--  second: a mode would need a rule for what the three colour rows mean while
--  it is on, and this way there is nothing to rule on.
--
--  EVERY KNOB LIVES IN THE .statuseffect'S effectConfig, read once at init.
--  Retuning the sweep is editing an asset, not this file.

--  Spelled once here and once in the animation, and nowhere else.
local LIGHT = "petports_module_huelamp"

--  ---------------------------------------------------------------------------
--  HSV, PORTED FROM LSL
--  ---------------------------------------------------------------------------
--
--  A TRIANGLE WAVE PER CHANNEL, 120 DEGREES APART, WHICH IS WHAT MAKES THIS
--  CHEAP. There is no sector switch and no min/max search -- the three channels
--  are the same function sampled at three offsets, so the whole conversion is
--  nine comparisons and no branching on which sixth of the wheel we are in.

local function fclamp(value, low, high)
	if value < low then return low end
	if value > high then return high end
	return value
end

--  ONE CHANNEL'S RAMP. t is a position on the wheel in turns.
--
--  THE WRAP IS A SINGLE SUBTRACTION AND THAT IS SUFFICIENT, not sloppy: the
--  caller always passes a fractional hue plus an offset below 1, so the sum is
--  under 2 and one subtraction is all it can ever need.
--
--  SCALE BY SIX, FOLD ABOVE THREE, CLAMP EITHER SIDE OF THE MIDDLE THIRD. That
--  produces a flat 0 for two sixths, a ramp up, a flat 1 for two sixths, and a
--  ramp down -- the standard hue ramp, written as arithmetic.
local function wave(t)
	if t >= 1.0 then t = t - 1.0 end

	t = t * 6
	if t > 3 then t = -t + 6 end

	return fclamp(t - 1, 0, 1)
end

--  A HUE IN TURNS TO A [0..255] COLOUR.
--
--  SATURATION MIXES TOWARD WHITE AND VALUE SCALES THE RESULT, in that order,
--  matching the original: desaturating a dim colour and dimming a desaturated
--  one are not the same operation, and this is the one that behaves like a lamp.
local function hueColor(hue, sat, val)
	hue = hue - math.floor(hue)

	sat = fclamp(sat, 0, 1)
	val = fclamp(val, 0, 1)

	local function channel(offset)
		local c = wave(hue + offset) * sat + (1.0 - sat)

		--  ROUNDED, NOT TRUNCATED. math.floor alone loses the top of the range:
		--  a full channel lands on 254 rather than 255 for most of its plateau.
		return math.floor(c * val * 255 + 0.5)
	end

	return { channel(0), channel(1 / 3), channel(2 / 3) }
end


--  ---------------------------------------------------------------------------

function init()
	--  SECONDS FOR A FULL TURN OF THE WHEEL, which is the knob worth having.
	--  Expressed as a PERIOD rather than a rate because a period is a number a
	--  person can picture -- "eight seconds to go all the way round" -- and a
	--  rate in turns per second is not.
	--
	--  THE SIGN IS THE DIRECTION, WHICH REPLACES A GUARD THAT REFUSED IT.
	--  This read `if self.period <= 0`, on the reasoning that a backwards sweep
	--  was almost certainly a typo. It was wanted on the first day, so a
	--  negative period now means widdershins and only ZERO is refused -- that
	--  one is a division by zero and an infinite hue, which is never a request.
	--
	--  NOTHING DOWNSTREAM NEEDS TO KNOW. A negative period makes `hue` count
	--  down, and Lua's `%` returns a non-negative result for a positive divisor,
	--  so -0.1 % 1 is 0.9 and the wheel simply turns the other way.
	self.period = tonumber(config.getParameter("huePeriod", -8)) or -8
	if self.period == 0 then self.period = -8 end

	self.saturation = tonumber(config.getParameter("saturation", 1)) or 1

	--  BRIGHTNESS IN 0..255, NOT 0..1, AND IT IS THE ONLY BRIGHTNESS KNOB.
	--
	--  There were two -- a `value` in 0..1 here and an intensity in 0..255
	--  applied to the finished colour -- which multiplied together and gave two
	--  ways to say one thing. 0..255 is the survivor because it is the unit the
	--  other two lamps already state their colour in: the plain lamp is authored
	--  at 140 and the RGB lamp defaults to it.
	--
	--  IT IS PASSED AS hueColor'S `val`, WHICH IS THE SAME MULTIPLY DONE ONE
	--  STEP EARLIER. Scaling the finished colour instead undoes the rounding
	--  hueColor just did and hands setLightColor three floats -- 128 * 80/255 is
	--  40.156 -- and what the engine does with a fractional channel is not
	--  something this mod has measured. Scaling before the round keeps every
	--  colour that leaves here an integer.
	self.intensity = tonumber(config.getParameter("intensity", 80)) or 80

	--  HUE 0 IS CYAN, NOT RED, AND THAT SURPRISES EVERYONE INCLUDING ME.
	--  wave(0) is 0, so at hue 0 the RED channel is the one switched off and the
	--  colour is [0,255,255]. It is the source function's phase convention
	--  rather than a porting slip -- the port was diffed against the original
	--  across twenty thousand hues and agrees to within the rounding this file
	--  adds. The animation is seeded to match, so the first frame is not a jump.
	--
	--  EACH UNIT KEEPS ITS OWN PHASE. A fleet socketed at different times
	--  therefore spreads across the wheel rather than pulsing in unison, which
	--  is the better-looking of the two and costs nothing.
	self.hue = 0

	--  FORCES THE FIRST update TO WRITE whatever it computes, rather than
	--  matching a seeded value and leaving the animation's authored colour up
	--  for one tick.
	self.applied = nil

	sb.logInfo("PETPORTS huelight: a turn every %ss (%s), sat %s, intensity %s/255",
		tostring(math.abs(self.period)),
		self.period < 0 and "widdershins" or "deasil",
		tostring(self.saturation), tostring(self.intensity))
end

function update(dt)
	--  KEPT INSIDE ONE TURN so the accumulator cannot grow without bound on a
	--  unit that stays socketed for a long session -- at which point the
	--  fractional part, which is all anybody reads, starts losing precision.
	self.hue = (self.hue + dt / self.period) % 1

	--  NO POST-SCALING, AND NO NEGATION EITHER. Both used to happen here: the
	--  hue was negated at the call to turn the wheel around, and the finished
	--  colour was multiplied down for brightness. The sign of `huePeriod` now
	--  carries the first and hueColor's `val` carries the second, so this is one
	--  call and everything it returns is still an integer.
	local color = hueColor(self.hue, self.saturation, self.intensity / 255)
	local applied = self.applied

	--  CHANGE-GATED ON THE QUANTISED COLOUR. At a slow sweep most ticks land on
	--  the channel values the last tick already set -- an eight second period
	--  crosses 255 levels over two of the six ramps, so the majority of frames
	--  have nothing to say.
	if applied ~= nil
	   and applied[1] == color[1]
	   and applied[2] == color[2]
	   and applied[3] == color[3] then
		return
	end

	--  DELIBERATELY NOT LOGGED. The RGB lamp logs every colour change because
	--  changes there are a player moving a control, a handful per session. Here
	--  they are continuous, and a line per change would be several hundred per
	--  minute per lit unit. The init line above says the module is running; if
	--  the light is wrong, that is what the RGB lamp is for comparing against.
	local ok, err = pcall(animator.setLightColor, LIGHT, color)

	if not ok then
		--  RECORDED AS APPLIED ANYWAY, so a failing call is one log line rather
		--  than one per tick for as long as the module stays socketed.
		self.applied = color
		sb.logInfo("PETPORTS huelight: setLightColor(%s) failed: %s",
			sb.printJson(color), tostring(err))
		return
	end

	self.applied = color
end

function uninit()
end
