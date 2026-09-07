--  PETPORTS -- CHAT BUBBLE, RENDER LAYER
--
--  2026-09-07a bubble render layer, bench only
--
--  A bubble over a unit's head holding up to three 16x16 icons, read left to
--  right. "I am carrying dirt", "I cannot deposit into a crate", "I am fishing".
--  This file draws it and nothing else -- what to say and when is the priority
--  layer, which is the NEXT build and does not exist yet.
--
--  NOT monster.say OR monster.sayPortrait. Deliberately. Those render engine
--  chat, which is text in the player's chat log as well as a bubble, is not
--  addressable per-icon, and cannot carry an item icon at all.
--
--  THIS IS thinkingspinner GENERALISED
--
--  Same shape as petports_think.lua, for the same reasons: a dedicated
--  stateType at its own priority so it composes with whatever "movement" is
--  doing, literal shared asset paths rather than <partImage> so one sheet
--  serves every chassis, fullbright so a unit in a dark cave can still be
--  read. Read that file's header before changing this one; the arguments there
--  about state-versus-burst and about a spinner left behind by a vent hop apply
--  here unchanged.
--
--  TWO THINGS IT NEEDS THAT THE SPINNER DOES NOT
--
--  CONTENT IS NOT KNOWN AT CONFIG TIME. The icon is whatever the unit happens
--  to be holding, so the part image is a TAG and the script fills it in.
--  animator.setPartTag scopes a tag to ONE part, so all three slots use the
--  same tag name "icon" and cannot collide. petports_beacon.lua already proves
--  the substitution is live -- it repaints an inventory icon mid-frame with
--  setGlobalTag -- but that is an activeitem. A monster's animator is a
--  NetworkedAnimator drawn on remote clients, so THAT this networks is the
--  thing this build is testing.
--
--  SLOT COUNT VARIES. One icon centred and three icons centred are different
--  offsets, and offsets are config rather than script. So the stateType's
--  STATES ARE THE LAYOUTS -- none, one, two, three -- and each icon part
--  carries a per-state offset override. Content from the tag, geometry from
--  the state.
--
--  THE UN-FLIP, AND WHY IT IS ONE TRANSFORMATION GROUP AND NOT FOUR
--
--  The engine mirrors a monster's whole animation with facing direction. For
--  the spinner that reverses a rotation, which pre-mirrored art fixes. For a
--  bubble it reverses the READING ORDER of the icons and mirrors each icon on
--  top of that, which pre-mirrored art cannot fix because the content is
--  chosen at runtime. So the parts sit in a transformation group scaled -1 on
--  x whenever the unit faces left, cancelling the engine's mirror exactly.
--
--  Scaling about the default centre works ONLY because the bubble is centred
--  on x = 0. Both mirrors are reflections about the same axis, so they compose
--  to the identity whichever order the engine applies them -- which matters,
--  because the order is NOT the order the Lua calls are made.
--
--  DO NOT ADD A SECOND GROUP TO THESE PARTS. A part in two transformation
--  groups gets them applied in a fixed internal order, not in call order: a
--  documented case had a part in a translate group and a flip group come out
--  flipped-then-translated no matter which call went first. That is why the
--  layout offsets are per-state config and not a translate group. Anything
--  that wants to move the bubble must move it inside the existing group.
--
--  DO NOT MARK THE GROUP "interpolated". A mirror has to snap. Interpolating
--  one animates the bubble squashing through zero width on every turn.
--
--  CRITICAL: no init, update or uninit here. Every script in a monstertype's
--  list shares one Lua context and a second definition silently replaces the
--  first. State lazy-initialises inside the functions.
--
--  WHAT IS NOT DONE YET, SO THAT A GAP IS NOT MISTAKEN FOR A BUG
--
--    - Nothing calls petports_bubbleSet except the bench. No cargo indicator,
--      no error bubbles, no headpats.
--    - No priority arbitration. That layer sits on top of this one and picks
--      WHICH message renders; this file renders whatever it is handed.
--    - petports_bubblePump is hosted in petportsTaskAction.update, which only
--      runs while a task holds the unit. An idle unit that turns around will
--      not re-flip until a task starts. Fine for cargo and for errors, which
--      only exist inside a task; a headpat bubble on an idle unit will need a
--      second host, and that is safe here in a way it was not for the think
--      pump -- this pump takes no dt and is idempotent, so double-hosting
--      cannot double-count anything.

--  Log every content change and the group probe. Leave ON until the bubble is
--  trusted; unlike the think pump this logs on CHANGE only, not per tick.
local BUBBLE_DEBUG = true

local BUBBLE_STATE_TYPE = "bubble"
local BUBBLE_OFF        = "none"

--  Indexed by slot count. BUBBLE_LAYOUT[2] is the state to set for two icons.
local BUBBLE_LAYOUT = { "one", "two", "three" }

--  Part names, in reading order. The Nth icon handed to petports_bubbleSet
--  goes in the Nth of these, and the per-state offsets in the .animation are
--  what centre the row for a given count.
local BUBBLE_SLOTS = { "bubbleicon1", "bubbleicon2", "bubbleicon3" }

local BUBBLE_GROUP  = "bubble"
local BUBBLE_TAG    = "icon"

--  The spinner sheet's empty cell, reused rather than duplicated. The body
--  layers already blank themselves with this exact path.
local BUBBLE_BLANK  = "/monsters/lofty_petports/shared/spinner/spinner.png:blank"

--  Generic stand-ins for items whose inventoryIcon is a drawable LIST rather
--  than a single path. See icons.frames.
local BUBBLE_ICONS  = "/monsters/lofty_petports/shared/bubble/icons.png"
petports_bubbleIcon =
{
	x     = BUBBLE_ICONS .. ":x",
	box   = BUBBLE_ICONS .. ":box",
	sword = BUBBLE_ICONS .. ":sword",
	gun   = BUBBLE_ICONS .. ":gun",
	blank = BUBBLE_BLANK
}

--  Set the bubble's contents. `icons` is a list of up to three asset paths in
--  reading order, or nil / empty to hide the bubble entirely. Extra entries
--  are DROPPED, loudly -- silently truncating a four-icon message would make
--  the missing icon look like a resolver failure.
--
--  Idempotent and cheap enough to call on every content change, but not
--  free: prefer calling it when the content actually changes.
function petports_bubbleSet(icons)
	--  INSTALLED HERE BECAUSE NOTHING HOSTS THE PUMP ANY MORE. Raising a bubble
	--  is the first moment the mirror can matter, and this runs before the
	--  bubble is on screen, so the shadow is in place before the first turn it
	--  would have to answer. Idempotent -- it returns immediately after the
	--  first call.
	petports_bubbleInstallShadow()

	local n = 0
	if icons ~= nil then n = #icons end

	if n > #BUBBLE_SLOTS then
		sb.logError("UNIT bubble handed %s icons, only %s slots exist; dropping the rest",
			tostring(n), tostring(#BUBBLE_SLOTS))
		n = #BUBBLE_SLOTS
	end

	for i = 1, #BUBBLE_SLOTS do
		local path = BUBBLE_BLANK
		if i <= n then path = icons[i] end
		animator.setPartTag(BUBBLE_SLOTS[i], BUBBLE_TAG, path)
	end

	local state = BUBBLE_OFF
	if n > 0 then state = BUBBLE_LAYOUT[n] end

	--  NOT flag-gated. A missing "bubble" stateType is indistinguishable from
	--  a bubble nothing ever triggers, and this is the only evidence that
	--  would ever exist.
	local ok, err = pcall(animator.setAnimationState, BUBBLE_STATE_TYPE, state)
	if not ok then
		sb.logError("UNIT bubble FAILED to set %s/%s: %s",
			BUBBLE_STATE_TYPE, state, tostring(err))
		return false
	end

	if BUBBLE_DEBUG and state ~= self.petportsBubbleState then
		sb.logInfo("UNIT bubble %s slots %s", state, sb.printJson(icons or {}))
	end
	self.petportsBubbleState = state

	--  Force the mirror to match CURRENT facing rather than waiting for the
	--  next pump tick. Without this a bubble raised while facing left shows
	--  its icons backwards for a frame.
	petports_bubbleFlip(true)
	return true
end

--  Hide it. Separate name because "set nothing" reads as a mistake at a call
--  site and "clear" does not.
function petports_bubbleClear()
	petports_bubbleSet(nil)
end

--  Cancel the engine's mirror when the unit faces left. Split out from the
--  pump so petports_bubbleSet can force it without a tick going by.
function petports_bubbleFlip(force)
	--  Probed ONCE and cached. If the transformation group is missing --
	--  declared in the wrong place in the .animation, most likely -- every
	--  call below is a no-op or a raise, and the visible symptom is icons in
	--  reverse order which reads as a bug in the CALLER. Say so instead.
	if self.petportsBubbleGroupOk == nil then
		self.petportsBubbleGroupOk = animator.hasTransformationGroup(BUBBLE_GROUP)
		if not self.petportsBubbleGroupOk then
			sb.logError("UNIT bubble has NO transformation group %s -- icons will "
				.. "read backwards and mirrored whenever the unit faces left. "
				.. "Check where transformationGroups is declared in the .animation.",
				BUBBLE_GROUP)
		elseif BUBBLE_DEBUG then
			sb.logInfo("UNIT bubble transformation group %s present", BUBBLE_GROUP)
		end
	end

	if not self.petportsBubbleGroupOk then return end

	--  COMMANDED FACING FIRST, OBSERVED SECOND.
	--
	--  self.petportsBubbleFacing is written by the controlFace / controlMove
	--  shadow below at the moment a turn is ASKED FOR. facingDirection() only
	--  reports what the movement controller applied on the previous engine
	--  tick, so it is always a tick stale and cannot be made otherwise from
	--  Lua -- the script never runs after the controller integrates.
	--
	--  The fallback is not dead code. It covers every turn nobody commanded:
	--  facing that follows velocity, and anything the engine decides on its
	--  own. It also covers the case where the shadow failed to install.
	local dir = self.petportsBubbleFacing
	if dir == nil then dir = mcontroller.facingDirection() end

	local left = dir < 0
	if not force and left == self.petportsBubbleFlipped then return end
	self.petportsBubbleFlipped = left

	if BUBBLE_DEBUG then
		sb.logInfo("UNIT bubble un-flip applied, facing %s, forced %s",
			left and "left" or "right", tostring(force == true))
	end

	animator.resetTransformationGroup(BUBBLE_GROUP)
	if left then
		animator.scaleTransformationGroup(BUBBLE_GROUP, {-1, 1})
	end
end

--  Per-tick pump. Called from petportsTaskAction.update beside the think pump.
--  Takes no dt on purpose: there is nothing here to integrate, and a dt-free
--  idempotent pump is safe to host in two places if an idle unit ever needs a
--  bubble. See the header.
--  Shadow mcontroller.controlFace so that a commanded turn reaches the bubble
--  in the SAME frame it is commanded, rather than being discovered by a poll on
--  the next one.
--
--  controlFace AND NOT controlMove. controlMove was hooked here and was the
--  cause of a visible hiccup: it commands MOVEMENT, and a mover can push one
--  way while the unit faces another -- braking, an approach velocity that
--  overshoots, a path edge whose direction is not the resting facing. Each of
--  those wrote a facing the controller never applied, the bubble flipped to it,
--  and the next controlFace corrected it a frame or two later.
--
--  petports_contract.lua 3438 is the shape that showed it: controlMove and
--  controlFace with the same direction on adjacent lines. Where they agree the
--  controlMove hook is redundant; where they disagree it is wrong. It is never
--  the one that is right.
--
--  THE COST IS REAL. Facing follows movement when nothing calls controlFace, so
--  a plain walk under vanilla's PathMover turns the unit with no controlFace at
--  all, and the bubble will not see it. Our own movers do call controlFace --
--  petports_flyapproach.lua 676, 686, 1493, 1689, petportsTaskAction.lua 4580,
--  petports_contract.lua 3439 -- so a unit under one of ours stays correct. If
--  a bubble sticks mirrored on a plain walk, that is this, and the fix is one
--  petports_bubblePump() back at the top of petportsTaskAction.update.
--
--  INSTALLED ONCE, LAZILY, FROM THE PUMP -- which runs at the top of the update
--  and therefore before anything in this tick has had a chance to turn the
--  unit.
--
--  THE SHADOWS DELEGATE AND RETURN WHAT THE ORIGINAL RETURNED. They are on the
--  path of every movement this unit makes, including vanilla's, so a wrapper
--  that swallowed a return value or raised would break locomotion outright
--  rather than break the bubble. Varargs throughout: neither signature is
--  something to assume.
--
--  ZERO IS NOT A TURN. controlFace(0) means no facing command, not face
--  forward, and treating it as a direction would flip the bubble to the right
--  every time one arrived.
function petports_bubbleInstallShadow()
	if self.petportsBubbleHooked ~= nil then return end

	local ok, err = pcall(function()
		local origFace = mcontroller.controlFace

		if type(origFace) == "function" then
			mcontroller.controlFace = function(direction, ...)
				if type(direction) == "number" and direction ~= 0 then
					self.petportsBubbleFacing = direction
					petports_bubbleFlip(false)
				end
				return origFace(direction, ...)
			end
		end
	end)

	self.petportsBubbleHooked = ok == true

	if ok then
		sb.logInfo("UNIT bubble facing shadow INSTALLED -- turns now flip in the "
			.. "frame they are commanded")
	else
		sb.logError("UNIT bubble facing shadow FAILED to install (%s) -- falling "
			.. "back to polling facingDirection(), which is one engine tick "
			.. "stale by construction", tostring(err))
	end
end


function petports_bubblePump(dt)

	--  CADENCE PROBE, 2026-09-07b. Counts calls and reports the rate once a
	--  second while a bubble is up. The flip is POLLED, so the poll rate is an
	--  upper bound on how fast a turn can possibly be answered -- and the
	--  reported number is what says whether the visible lag is the poll or
	--  something downstream of it.
	--
	--  Counted BEFORE the early return, so the rate is the host's real cadence
	--  rather than the rate at which the bubble happens to be up. Reported only
	--  while a bubble IS up, so an idle fleet does not fill the log.
	--
	--  REMOVE THIS BLOCK once the number is known. It is a measurement, not a
	--  feature.
	if dt ~= nil then
		self.petportsBubblePumpCalls = (self.petportsBubblePumpCalls or 0) + 1
		self.petportsBubblePumpTime = (self.petportsBubblePumpTime or 0) + dt

		if self.petportsBubblePumpTime >= 1.0 then
			if self.petportsBubbleState ~= nil
			   and self.petportsBubbleState ~= BUBBLE_OFF then
				sb.logInfo("UNIT bubble pump cadence %s calls in %s s (dt %s)",
					tostring(self.petportsBubblePumpCalls),
					tostring(self.petportsBubblePumpTime),
					tostring(dt))
			end
			self.petportsBubblePumpCalls = 0
			self.petportsBubblePumpTime = 0
		end
	end

	--  Nothing on screen, nothing to keep straight. Skips the facingDirection
	--  call on the overwhelming majority of ticks.
	if self.petportsBubbleState == nil or self.petportsBubbleState == BUBBLE_OFF then
		return
	end
	petports_bubbleFlip(false)
end

--  Resolve an item descriptor to ONE asset path for an icon slot.
--
--  root.itemConfig returns inventoryIcon as either a path string or a LIST of
--  layered drawables, and an animator part image is a single path, so the list
--  case cannot be rendered faithfully. Returns nil for it and lets the caller
--  choose a stand-in -- the caller knows whether it is holding a sword.
--
--  Relative icon paths resolve against the item's own directory, which is what
--  makes a modded item show its own icon rather than a missing-asset box.
function petports_bubbleItemIcon(descriptor)
	local ok, cfg = pcall(root.itemConfig, descriptor)
	if not ok or cfg == nil then
		if BUBBLE_DEBUG then
			sb.logInfo("UNIT bubble no itemConfig for %s", sb.printJson(descriptor))
		end
		return nil
	end

	local icon = nil
	if cfg.config ~= nil then icon = cfg.config.inventoryIcon end

	if type(icon) ~= "string" then
		if BUBBLE_DEBUG then
			sb.logInfo("UNIT bubble %s has a non-string inventoryIcon (%s); caller "
				.. "must pick a stand-in",
				sb.printJson(descriptor), type(icon))
		end
		return nil
	end

	if icon:sub(1, 1) == "/" then return icon end
	return tostring(cfg.directory) .. icon
end

--  Bench call. Run once from anywhere to prove the render side works
--  independently of whether anything ever raises a bubble:
--
--      petports_bubbleSelfTest()
--
--  Cycles nothing -- it puts up a fixed three-icon bubble and leaves it there,
--  because the questions this build is answering are all answerable from a
--  still frame:
--
--    1. does setPartTag network to a monster's animator at all
--    2. do per-state offset overrides work, or do the icons stack at the base
--       offset instead of spreading
--    3. does the transformation group cancel the mirror -- walk the unit left
--       and check the icons stay in the same order and unmirrored
--
--  The middle slot is resolved through petports_bubbleItemIcon from a real
--  item, so a resolver failure is visible as one blank slot between two drawn
--  ones rather than as nothing at all.
function petports_bubbleSelfTest(itemName)
	itemName = itemName or "dirtmaterial"

	local mid = petports_bubbleItemIcon({ name = itemName, count = 1 })
	sb.logInfo("UNIT bubble SELFTEST item %s resolved to %s",
		tostring(itemName), tostring(mid))

	petports_bubbleSet({
		petports_bubbleIcon.x,
		mid or petports_bubbleIcon.box,
		petports_bubbleIcon.gun
	})
end

--  Bench call for the layout states alone, with no item resolution involved:
--
--      petports_bubbleSelfTestLayout(2)
--
--  Puts up n copies of the same stand-in. If three icons spread correctly and
--  two do not, the fault is one offset in the .animation rather than the
--  mechanism.
function petports_bubbleSelfTestLayout(n)
	local icons = {}
	for i = 1, (n or 3) do icons[i] = petports_bubbleIcon.box end
	petports_bubbleSet(icons)
end
