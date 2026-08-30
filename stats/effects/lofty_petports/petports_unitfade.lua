--  PETPORTS -- UNIT MATERIALISE / DEMATERIALISE
--
--  MODELLED ON VANILLA'S monsterrelocate.lua, WHICH IS THE ONE TRANSITION IN
--  THE GAME THAT DOES WHAT WE WANTED. Three earlier candidates were read and
--  rejected, and the reasons are worth keeping because each sent this file down
--  a wrong road:
--
--    monstercapture / monsterdespawn  flat fade to black plus an alpha ramp,
--                                     with a particle burst doing the real
--                                     work. Naked, it looks like nothing.
--    modularmech (deploy)             flat fade to WHITE plus alpha, dressed
--                                     with a light, a drop and a boost.
--    distortionsphere (morphball)     flat fade to white with a hand-drawn
--                                     transform.png laid over the top.
--
--  ALL THREE CARRY THEIR IDENTITY IN SOMETHING ELSE -- particles, art, motion.
--  monsterrelocate is the only one where the LOOK IS IN THE DIRECTIVE STRING,
--  and so the only one reproducible without an art pass.
--
--  THE SHAPE, AND WHY IT READS THE WAY IT DOES:
--
--      body   blends toward the colour, then that blend MORPHS TO WHITE
--      rim    a border that stays the colour throughout
--      size   shrinks to a dot while the body whitens
--
--  White in the middle, colour around the edge. Not emergent from layered art
--  and not a gradient anyone painted -- one directive chain, and the split
--  between a whitening body and a coloured border is deliberate.
--
--  SCALE IS A DIRECTIVE, NOT A TRANSFORMATION GROUP. `?scalenearest` needs no
--  animation edits, no transformation groups in the four chassis files, and no
--  wrapper around groundPet.lua's update. An earlier version of this file
--  claimed a status effect could not scale its parent because an effect's
--  `animator` is its own. True, and irrelevant: this never touches the animator.
--
--  NO ALPHA RAMP. Vanilla's relocate has no `?multiply` at all -- the unit
--  disappears by SHRINKING, not by going transparent, and an alpha ramp on top
--  only muddies a silhouette that is already collapsing.

--  ONE DIRECTION, ONE FLAG. `grow` runs the clock backwards, exactly as
--  monsterrelocatespawn does against monsterrelocate. Both effects load this
--  file, so the two directions cannot drift apart.
local DEFAULT_COLOR = "ff00ff"
local WHITE = { 255, 255, 255 }

--  The chassis declares six hex digits; the ramp needs channels to interpolate.
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

	--  SHRINK TARGET IS A SIZE IN TILES, NOT A RATIO, and with four chassis that
	--  is the better choice: every unit collapses to the same apparent dot
	--  regardless of sprite size. A fixed 0.01 would make a large chassis vanish
	--  and a small one merely get smaller.
	local bounds = mcontroller.boundBox()
	local widest = math.max(bounds[3] - bounds[1], bounds[4] - bounds[2])
	local shrinkSize = config.getParameter("shrinkSize", 0.25)

	self.shrinkRatio = 1.0
	if widest > 0 then
		self.shrinkRatio = math.min(shrinkSize / widest, 1.0)
	end

	self.total = self.fadeColorDuration + self.shrinkDuration

	--  A GROW STARTS AT THE FAR END AND COUNTS DOWN, so the same ramp read
	--  backwards is a materialise.
	self.elapsed = 0
	if self.grow then
		self.elapsed = self.total
	end

	--  INVULNERABLE FOR THE DURATION, as vanilla's relocate does. A unit that is
	--  a quarter tile wide should not be taking hits.
	effect.addStatModifierGroup({
		{ stat = "invulnerable", amount = 1 }
	})

	--  STUNNED AS WELL, WHICH VANILLA DOES NOT NEED. A relocating monster is
	--  being yanked out of the world by an item; ours stands on its own port
	--  with groundPet's action states live underneath, and a unit that walks off
	--  mid-materialise gives the whole thing away.
	status.setResource("stunned", math.max(status.resource("stunned"), effect.duration()))

	--  APPLIED IMMEDIATELY so the first rendered frame is already correct rather
	--  than showing one frame of a full-size opaque unit.
	applyAt(self.elapsed)

	--  THE SOUND IS NOT PLAYED HERE. See playWhooshOnce below -- a materialise
	--  effect is applied from inside the MONSTER'S OWN init, and a sound emitted
	--  before the entity is registered goes nowhere.
	self.whooshPlayed = false
end

--  elapsed runs 0 -> total in the DEMATERIALISE direction: 0 is a normal unit,
--  total is a white dot. Materialise is the same curve counted down.
function applyAt(elapsed)
	local toColor = { self.fadeColor[1], self.fadeColor[2], self.fadeColor[3] }
	local fade = 1.0
	local scale = 1.0

	if elapsed < self.fadeColorDuration then
		--  PHASE ONE: blend toward the colour at full size. Nothing moves yet.
		fade = elapsed / self.fadeColorDuration
	elseif elapsed < self.total then
		--  PHASE TWO: the blend MORPHS FROM THE COLOUR TO WHITE while the unit
		--  shrinks. This is the phase that produces the look -- the body turns
		--  white from the inside while the border stays the colour.
		local ratio = (elapsed - self.fadeColorDuration) / self.shrinkDuration

		for i = 1, 3 do
			toColor[i] = lerp(ratio, toColor[i], WHITE[i])
		end

		scale = 1.0 + (self.shrinkRatio - 1.0) * ratio
	else
		toColor = { WHITE[1], WHITE[2], WHITE[3] }
		scale = self.shrinkRatio
	end

	--  THE BORDER KEEPS THE CHASSIS COLOUR while the body whitens, and its inner
	--  edge is THE SAME COLOUR AT ALPHA 00 -- which is what makes it a soft halo
	--  rather than a hard ring. ONE pass, not two: the width carries the
	--  gradient. Vanilla uses 3.
	local border = hex6(self.fadeColor)
	local borderAlpha = math.max(math.min(math.floor(fade * 255), 255), 0)

	effect.setParentDirectives(string.format(
		"?fade=%s;%.1f?scalenearest=%.2f?border=%d;%s%02x;%s00",
		hex6(toColor), fade,
		scale,
		self.borderWidth, border, borderAlpha, border))
end

--  THE WHOOSH, ON THE EFFECT'S OWN ANIMATOR, ON THE FIRST UPDATE.
--
--  NOT IN init, WHICH IS WHERE IT WAS AND WHY THE SPAWN SOUND NEVER PLAYED.
--  The materialise effect is applied from inside the monster's own init -- see
--  `fact.unit.spawnrender` for why it has to be -- so this effect's init runs
--  while the entity is still being built, and a sound emitted then has nothing
--  listening for it. The dematerialise sound worked throughout, because that
--  effect is applied to a unit that has been alive for minutes; a bug that
--  shows on ONE of two directions is the tell that the difference is WHERE the
--  effect is applied from, not what it does.
--
--  ONE TICK LATE AND IT DOES NOT MATTER: at scriptDelta 1 that is a sixtieth
--  of a second against a 0.3s ramp.
--
--  NOT GUARDED SILENTLY. The previous version wrapped this in a bare pcall and
--  discarded the result, so a sound that never played and a sound that failed
--  to load were indistinguishable -- `proc.tooling.guardedcall` in one line.
--  The guard stays, because a missing asset must not take a materialising unit
--  down with it, but it now SAYS SO.
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

	--  A COMPLETED MATERIALISE HANDS BACK A LIVE UNIT and must clear what it
	--  drew, or the unit stays permanently tinted and shrunk at whatever the
	--  last frame was.
	if self.grow and self.elapsed < 0 then
		effect.setParentDirectives("")
		effect.expire()
		return
	end

	applyAt(self.elapsed)
	playWhooshOnce()

	--  HELD DOWN THE WHOLE WAY, as vanilla does every tick. A unit spawned above
	--  its port would otherwise fall while materialising.
	mcontroller.setVelocity({0, 0})
	status.setResource("stunned", math.max(status.resource("stunned"), effect.duration()))

	--  ONLY THE DEMATERIALISE EFFECT KILLS, and it is what ends the unit rather
	--  than petports_despawn doing it inline. Vanilla's relocate does not kill
	--  because the relocator item removes the monster itself; nothing does that
	--  for us.
	if self.killOnFinish and self.elapsed >= self.total then
		status.setResource("health", 0)
	end
end

function uninit()
	--  CLEARED ON ANY EXIT. An effect removed early -- the unit unsocketed
	--  mid-materialise, the port giving up, the chunk unloading -- would leave
	--  the parent stuck at whatever scale and tint it had reached, and a
	--  permanently quarter-size magenta unit reads as a rendering bug rather
	--  than an interrupted animation.
	if not self.killOnFinish then
		effect.setParentDirectives("")
	end
end
