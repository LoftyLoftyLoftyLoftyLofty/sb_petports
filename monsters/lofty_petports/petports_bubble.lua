--  PETPORTS -- CHAT BUBBLE, RENDER LAYER
--
--  2026-09-08b bench probe for engine-generated item icons (codex, blueprint)
--  2026-09-08c probe hunts asset paths under keys we cannot name
--  2026-09-08d codex icons read from codexIcon
--  2026-09-08e blueprint paper composited back under the item icon
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

--  DRAW THE BUBBLE ON THE MONSTER'S OWN ANIMATOR.
--
--  false because a monster's drawables are clamped to its monstervariant's
--  render layer, so the bubble is drawn behind water and behind foreground
--  tiles with no way to lift it -- there is no per-part render layer and zLevel
--  only orders parts within the entity.
--
--  NOT DELETED. The stateType and the four parts are still in all five
--  .animation files and still work, so the two can be put side by side before
--  either is thrown away. Set this true to get the old behaviour back.
local BUBBLE_MONSTER_PARTS = false

--  Tell every player in the world what this unit is saying.
--
--  world.players() AND NOT world.playerQuery. There is no distance argument
--  here on purpose. Range is a DRAWING decision, and the client already makes
--  it -- BUBBLE_DRAW_RANGE in petports_coverageoverlay.lua. Culling on the
--  sender as well would mean two ranges that have to agree, and the failure
--  mode when they drift is a player standing well inside draw range seeing
--  nothing, which looks like a broken bubble rather than a misconfigured one.
--
--  It also means a player already HOLDS the state before they are close enough
--  to see it, so walking into range shows the bubble immediately instead of
--  waiting for the unit's next content change.
--
--  ON CONTENT CHANGE ONLY. A bubble changes when the unit's situation changes,
--  which is a task transition rather than a tick, so this is rare enough to
--  send eagerly and far too rare to poll for.
--
--  REMAINING GAP: a player who enters the world AFTER the last change was sent
--  is not told. Closing that needs the unit to notice the player set changing,
--  which wants a host in petBehavior.run().
local function publishBubble(icons)
	local ok, players = pcall(world.players)
	if not ok or players == nil then
		if BUBBLE_DEBUG then
			sb.logInfo("UNIT bubble world.players failed: %s", tostring(players))
		end
		return
	end

	--  REMEMBERED SO THE HEARTBEAT HAS SOMETHING TO RESEND. This is the last
	--  thing that was SENT, which is not the same as the last thing that was
	--  ASKED FOR -- a send that failed the pcall above never gets here, so the
	--  heartbeat will not go on reasserting something no client ever saw.
	self.petportsBubbleSent = icons

	--  THE FLAG TRAVELS WITH THE CONTENT, AND THE CONTENT IS SENT EITHER WAY.
	--
	--  A unit with bubbles switched off still publishes what it would have
	--  said. That is deliberate and it is what makes the checkbox feel instant:
	--  every client already holds the current state of every unit in the world,
	--  so ticking the box is a repaint on the next frame rather than a wait for
	--  the unit's next content change.
	--
	--  Not sending at all would be cheaper on the wire and would make a player
	--  switching a unit back on stare at nothing until something happened to
	--  it.
	local show = self.petportsBubbleEnabled ~= false

	for _, id in ipairs(players) do
		world.sendEntityMessage(id, "petports_bubbleShow", entity.id(), icons, show)
	end

	if BUBBLE_DEBUG then
		sb.logInfo("UNIT bubble published %s icons to %s players",
			tostring(icons and #icons or 0), tostring(#players))
	end
end

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

--  WHERE AN ICON CAN LIVE IN AN ITEM CONFIG, IN ORDER OF PREFERENCE.
--
--  ONE LIST BECAUSE THERE TURNED OUT TO BE MORE THAN ONE KEY, and a second key
--  read inline would be a third one waiting to be added inline again. Both the
--  parameter read and the config read walk this, so a key added here is added
--  to both at once.
local BUBBLE_ICON_KEYS = { "inventoryIcon", "codexIcon" }

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



--  THE PORT'S ANSWER TO "MAY THIS UNIT SPEAK".
--
--  Pushed by pushUnitBubbles in petports_petport.lua, signature-gated there and
--  driven from its update, so a respawned unit is told again without anyone
--  having to remember.
--
--  DEFAULTS ON. self.petportsBubbleEnabled is nil until the port speaks, and
--  every read of it here is `~= false` -- so a unit that has not yet been told,
--  or whose port is running an older script, speaks rather than falling silent.
--  Matches petportBubbles() on the port and settingValue in the pane; all three
--  read absent the same way on purpose.
--
--  REPUBLISHES IMMEDIATELY. The whole point of the flag riding with the content
--  is that a client already holds this unit's state, so flipping the checkbox
--  should repaint on the next frame. Waiting for the heartbeat would put up to
--  ten seconds between the click and the bubble.
function petports_setUnitBubbles(show)
	local enabled = show ~= false
	if enabled == (self.petportsBubbleEnabled ~= false) then return true end

	self.petportsBubbleEnabled = enabled

	sb.logInfo("UNIT bubble speech %s by its port",
		enabled and "ENABLED" or "DISABLED")

	--  ONLY IF THERE IS SOMETHING TO SAY. A silent unit has nothing to
	--  republish and the clients have nothing of its to repaint.
	if self.petportsBubbleSent ~= nil then
		publishBubble(self.petportsBubbleSent)
	end

	return true
end

--  Republish the current bubble every ~10 seconds.
--
--  WHY THIS IS NOT REDUNDANT WITH SEND-ON-CHANGE. localAnimator drawables that
--  stay offscreen long enough are dropped, so a client that was told once has
--  no guarantee of still drawing anything after the unit leaves the screen and
--  comes back. The client cannot ask -- a monster's scripts run on the master
--  only, so world.callScriptedEntity from a client cannot reach one. The only
--  direction available is push, so push periodically.
--
--  CALLED FROM petBehavior.run, WHICH IS 1 Hz. groundPet.querySurroundings
--  calls run on querySurroundingsCooldown and all five monstertypes set that to
--  1, so ten calls is ten seconds. Counting calls rather than accumulating
--  script.updateDt() is deliberate: updateDt is the TICK delta, and run is not
--  called per tick, so accumulating it here would measure the wrong thing.
--
--  SILENT WHEN THERE IS NOTHING UP. An idle fleet sends nothing at all.
local BUBBLE_HEARTBEAT_CALLS = 10

function petports_bubbleHeartbeat()
	if self.petportsBubbleSent == nil then return end

	self.petportsBubbleBeat = (self.petportsBubbleBeat or 0) + 1
	if self.petportsBubbleBeat < BUBBLE_HEARTBEAT_CALLS then return end
	self.petportsBubbleBeat = 0

	publishBubble(self.petportsBubbleSent)
end

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

	--  THE PLAYERS ARE TOLD FIRST AND UNCONDITIONALLY. Everything below this
	--  is the monster-side draw, which is off by default and is not the thing
	--  the player actually sees.
	publishBubble(n > 0 and icons or nil)

	if not BUBBLE_MONSTER_PARTS then
		self.petportsBubbleState = n > 0 and BUBBLE_LAYOUT[n] or BUBBLE_OFF
		return true
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

--  THE PAPER A BLUEPRINT IS DRAWN ON.
--
--  MEASURED 2026-09-08. A "-recipe" item's synthesised config carries ONE art
--  path and it is the TARGET item's icon -- the paper is composited by the
--  engine and is in no config anywhere, so no read of root.itemConfig will ever
--  reach it and it has to be put back by hand.
--
--  NOTHING IS SCALED, AND THE INSET IS AN ARTEFACT OF THE SIZES. The paper is
--  18x18 where an item icon is 16x16, so a 1px border of paper shows on every
--  side; the item's own transparent padding -- 2px on the chest that was
--  measured, visible region [2,2,14,14] -- widens that to a 3px margin around
--  the art. It READS as an inset item and is two centred layers at their
--  authored sizes. A per-layer scale was designed for this and is not needed.
--
--  THE UNION IS THEREFORE 18 AND THE SLOT SCALE IS 16/18. layoutIcon shrinks
--  the assembly to the slot as it does for any other composite, so the paper
--  lands at 16px and the art inside it at about 11. That is the vanilla
--  proportion, fitted to our slot rather than to the inventory's.
local BUBBLE_BLUEPRINT = "/items/generated/blueprint.png"

--  Resolve a possibly-relative image path against the item's own directory.
--
--  SHARED BY BOTH SHAPES. A layered icon's images need exactly the treatment a
--  single path gets, and writing it twice is how the two drift.
--
--  A PARAMETER OVERRIDE RESOLVES AGAINST THE BASE ITEM'S DIRECTORY, which is
--  the only directory root.itemConfig offers and is therefore the best answer
--  available rather than the right one. A mod overriding inventoryIcon with a
--  RELATIVE path pointing into its own assets would miss; an absolute path,
--  which is what such overrides normally carry, resolves correctly. If a
--  missing-asset box ever shows up for a retextured item, this is where to
--  look first.
local function absolutePath(image, directory)
	if type(image) ~= "string" then return image end
	if image:sub(1, 1) == "/" then return image end
	return tostring(directory) .. image
end

--  Put the paper back under a blueprint's icon.
--
--  TAKES EITHER SHAPE AND ALWAYS RETURNS A LIST, because a blueprint is a
--  composite whatever the item it depicts happens to be -- a plain path becomes
--  two layers and an authored layer list becomes that list with one more under
--  it.
--
--  BACKING FIRST. Layer order is draw order, so the paper has to be authored
--  before the thing standing on it. If it comes out over the top instead, that
--  is this line and nothing else.
--
--  POSITIONS LEFT ALONE. Both layers are centred on the origin, which is what
--  a nil position already means to layoutIcon, and the 18-versus-16 sizes are
--  what produce the margin. Authoring an offset here would move the item off
--  its paper.
local function withBlueprintBacking(icon)
	if icon == nil then return nil end

	local layers = { { image = BUBBLE_BLUEPRINT } }

	if type(icon) == "string" then
		layers[#layers + 1] = { image = icon }
	else
		for _, layer in ipairs(icon) do layers[#layers + 1] = layer end
	end

	return layers
end

--  Resolve an item descriptor to an icon for a slot.
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

	--  THE INSTANCE FIRST, THE BASE CONFIG SECOND.
	--
	--  root.itemConfig HANDS BACK THE BASE ASSET CONFIG AND THE PARAMETERS
	--  SEPARATELY, unmerged. The engine merges them only at instantiation --
	--  Item::instanceValue checks parameters and falls back to config -- so a
	--  per-instance inventoryIcon override is invisible to a plain
	--  cfg.config read.
	--
	--  MEASURED 2026-09-08: a modded giant moth drops a renamed, retextured
	--  cotton fibre, and the bubble drew vanilla cotton fibre. The item is
	--  base cottonfibre carrying parameter overrides, and this line only ever
	--  looked at the base.
	--
	--  THE DESCRIPTOR WE WERE HANDED, NOT cfg.parameters. Both should carry
	--  the same table, and the argument is the one the caller actually meant
	--  -- reading it back out of the return value adds a way for the two to
	--  differ with nothing gained.
	--
	--  IT IS THE SAME CLASS AS fact.item.generatedicon, arrived at from the
	--  other direction: there the icon is BUILT from parameters, here it is
	--  NAMED by them. Both are icons that are not in the base config, which is
	--  why arch.bubble.protocol sends the whole descriptor -- the plumbing was
	--  already right and only this read was wrong.
	--
	--  A LAYER LIST IS AS VALID HERE AS A PATH. The list branch below handles
	--  whichever this turns out to be, so an override may be either shape.
	--  inventoryIcon IS NOT THE ONLY KEY AN ICON CAN BE UNDER.
	--
	--  MEASURED 2026-09-08. A codex item's config carries NO inventoryIcon at
	--  all. Its keys are category codexIcon codexId cooldown description
	--  itemName price rarity shortdescription tooltipKind windupTime, and the
	--  art is under codexIcon -- ABSOLUTE, "/codex/human/humancover1.png",
	--  where a file-backed item's is relative ("dirt.png" against
	--  /items/materials/). absolutePath handles both, so the only thing that
	--  was ever wrong was the key.
	--
	--  EVERY vanilla codex draws as the box until this reads codexIcon, and
	--  123 of them are pickup-able.
	--
	--  ORDERED, FIRST NON-NIL WINS, PARAMETERS BEFORE CONFIG PER KEY. That
	--  keeps fact.item.instanceicon exactly as it was -- an instance override
	--  still beats the base -- and adds the second key underneath rather than
	--  beside it, so an item carrying both is read as its inventoryIcon, which
	--  is the more specific answer.

	--  A BLUEPRINT IS IDENTIFIED BY ITS CONFIG, NOT BY ITS NAME.
	--
	--  MEASURED 2026-09-08, WITH A CONTROL. nicemicetier1chest-recipe has a
	--  "recipe" key; nicemicetier1chest, the same item without the suffix, does
	--  not. The key is the engine saying what the item IS, where the suffix is
	--  a naming convention a mod is free to break -- and the filter groups only
	--  lean on suffixes because for codexes there was nothing else to lean on.
	--  Here there is.
	local blueprint = cfg.config ~= nil and cfg.config.recipe ~= nil

	local icon = nil
	local params = nil

	if type(descriptor) == "table" and type(descriptor.parameters) == "table" then
		params = descriptor.parameters
	end

	for _, key in ipairs(BUBBLE_ICON_KEYS) do
		if icon == nil and params ~= nil then icon = params[key] end
		if icon == nil and cfg.config ~= nil then icon = cfg.config[key] end
	end

	--  A LAYER LIST IS AN ICON TOO, NOT A FAILURE.
	--
	--  buildweapon.lua builds a generated weapon's icon as a list of
	--  { image, position } drawables rather than one path, and this used to
	--  return nil for it -- which is why every generated gun came out as the
	--  stand-in box.
	--
	--  PASSED THROUGH AS A LIST. The player side assembles it, because that is
	--  where root.imageSize and the drawing already live, and only it can size
	--  the union of the layers.
	--
	--  POSITIONS ARE LEFT EXACTLY AS AUTHORED -- pixels, centre-relative, and
	--  possibly nil. Converting them here would put half the geometry on this
	--  side and half on the other.
	if type(icon) == "table" then
		local layers = {}

		for _, layer in ipairs(icon) do
			local image = type(layer) == "table" and layer.image or layer

			if type(image) == "string" then
				layers[#layers + 1] =
				{
					image = absolutePath(image, cfg.directory),
					position = type(layer) == "table" and layer.position or nil
				}
			end
		end

		if #layers > 0 then
			--  DUMPED ONCE PER ITEM NAME. This used to fire only when an icon
			--  FAILED to resolve; once layered icons started resolving, the one
			--  case worth seeing stopped being logged at all. A composite that
			--  assembles wrongly is unreadable on screen and perfectly legible
			--  here.
			if BUBBLE_DEBUG then
				self.petportsIconDumped = self.petportsIconDumped or {}
				local name = tostring(descriptor and descriptor.name)

				if not self.petportsIconDumped[name] then
					self.petportsIconDumped[name] = true
					local ok, encoded = pcall(sb.printJson, layers)
					sb.logInfo("UNIT bubble %s icon has %s layer(s): %s", name,
						tostring(#layers), ok and encoded or "unprintable")
				end
			end

			if blueprint then return withBlueprintBacking(layers) end
			return layers
		end

		if BUBBLE_DEBUG then
			sb.logInfo("UNIT bubble %s has a layered inventoryIcon with no usable "
				.. "images: %s", tostring(descriptor and descriptor.name),
				sb.printJson(icon))
		end
		return nil
	end

	if type(icon) ~= "string" then
		if BUBBLE_DEBUG then
			--  THE KEYS ARE NAMED because the codex case was exactly this line
			--  reporting nil, and "nil" alone does not say whether the icon is
			--  missing or merely somewhere this does not look.
			sb.logInfo("UNIT bubble %s has no icon under %s that is a path or a "
				.. "layer list (got %s)",
				tostring(descriptor and descriptor.name),
				table.concat(BUBBLE_ICON_KEYS, "/"), type(icon))
		end
		return nil
	end

	local path = absolutePath(icon, cfg.directory)

	if blueprint then return withBlueprintBacking(path) end
	return path
end

--  RESOLVE ONE TOKEN FROM THE PORT INTO AN ASSET PATH.
--
--  Two forms, and the split is what keeps the port free of asset knowledge:
--
--    item:<name>   an inventory icon, through petports_bubbleItemIcon
--    mark:<name>   a frame in the shared icons sheet -- x, box, sword, gun
--
--  AN ITEM THAT WILL NOT RESOLVE FALLS BACK TO THE BOX rather than dropping the
--  slot. A missing icon in a three-icon sentence would silently change what the
--  sentence says; a box says "something, and I could not draw it".
--
--  THE WEAPON FALLBACKS ARE NOT WIRED YET. icons.png carries sword and gun for
--  generated melee and ranged, and choosing between them needs a tag test that
--  has not been measured. Everything unresolvable is a box until then, which is
--  the honest state rather than a guess dressed as a rule.
local function resolveToken(token)
	--  AN ITEM TOKEN IS A TABLE, A MARK IS A STRING.
	--
	--  Items carry their whole descriptor because a generated weapon's icon is
	--  built from its parameters -- resolving one from a bare name produces a
	--  different weapon, which is what this shape exists to stop. A mark names
	--  a frame in our own sheet and has nothing to lose, so it stays a string.
	if type(token) == "table" and type(token.item) == "table" then
		local path = petports_bubbleItemIcon(token.item)
		if path ~= nil then return path end

		if BUBBLE_DEBUG then
			sb.logInfo("UNIT bubble %s has no usable icon, using the box",
				tostring(token.item.name))
		end
		return petports_bubbleIcon.box
	end

	if type(token) ~= "string" then return nil end

	local kind, value = token:match("^(%a+):(.+)$")
	if kind == nil then return nil end

	if kind == "mark" then
		return petports_bubbleIcon[value]
	end

	--  THE STRING FORM OF AN ITEM TOKEN, KEPT AS A FALLBACK. Nothing sends it
	--  any more -- a name alone cannot resolve a generated weapon -- but a port
	--  running an older script still can, and a box is a better answer than a
	--  blank slot.
	if kind == "item" then
		--  SENT UNMODIFIED. Fitting an icon to its slot used to happen here,
		--  as a ?scalenearest directive baked into the path, and a directive
		--  RESAMPLES the source -- a 24x64 weapon sprite brought down to 16
		--  kept one pixel in four. Scaling is a render-time transform now and
		--  belongs where the drawable is built, which is the player side.
		local path = petports_bubbleItemIcon({ name = value, count = 1 })
		if path ~= nil then return path end

		if BUBBLE_DEBUG then
			sb.logInfo("UNIT bubble %s has no single-path icon, using the box", value)
		end
		return petports_bubbleIcon.box
	end

	return nil
end

--  WHAT THE PORT WANTS SAID. Called by pushUnitBubble in petports_petport.lua.
--
--  A TOKEN LIST OR nil. nil takes the bubble down, which is what a port with
--  nothing to report sends -- so this is the ordinary quiet path rather than an
--  error case.
--
--  THE PORT HAS ALREADY PICKED. This does not arbitrate between conditions and
--  must not start to: the port is the only sender and the ladder lives there,
--  so a second opinion here could only ever disagree with it.
function petports_setUnitBubbleSpec(tokens)
	if type(tokens) ~= "table" or #tokens == 0 then
		petports_bubbleClear()
		return true
	end

	local icons = {}
	for _, token in ipairs(tokens) do
		local path = resolveToken(token)
		if path ~= nil then icons[#icons + 1] = path end
	end

	if #icons == 0 then
		sb.logError("UNIT bubble resolved NONE of %s -- saying nothing",
			sb.printJson(tokens))
		petports_bubbleClear()
		return false
	end

	petports_bubbleSet(icons)
	return true
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

--  Bench call for judging PADDING against real content:
--
--      petports_bubbleSelfTestItems("dirtmaterial", "coalore", "ironbar")
--
--  The placeholder icons in icons.png use 10 to 12 pixels of their 16x16 cell
--  and sit 2 to 4 pixels in from each edge, so the bubble reads as having four
--  times the gap between icons that bubble.frames actually specifies. Judging
--  the padding against them measures the placeholders, not the layout.
--
--  Real inventory icons are not uniformly full-bleed either -- plenty are inset
--  as well -- so the padding worth shipping is whatever looks right against the
--  items units ACTUALLY carry. Pass three of those.
--
--  Anything that will not resolve to a single path falls back to the box and is
--  named in the log, so a slot that looks wrong can be told apart from a slot
--  that resolved to something unexpected.
function petports_bubbleSelfTestItems(a, b, c)
	local icons = {}
	for _, name in ipairs({ a, b, c }) do
		if name ~= nil then
			local path = petports_bubbleItemIcon({ name = name, count = 1 })
			if path == nil then
				sb.logInfo("UNIT bubble bench: %s did not resolve, using the box", tostring(name))
				path = petports_bubbleIcon.box
			end
			icons[#icons + 1] = path
		end
	end
	petports_bubbleSet(icons)
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


--  ------------------------------------------------------------------------
--  BENCH PROBE: WHAT DOES root.itemConfig RETURN FOR AN ITEM WITH NO FILE?
--
--      petports_bubbleProbeIcon()
--      petports_bubbleProbeIcon("dirtmaterial", "humanhistory1-codex", "<x>-recipe")
--
--  Codexes and blueprints have NO ASSET FILE. Their item configs are SYNTHESISED
--  by the engine when the item database is built, which makes them a THIRD class
--  beside the two already handled -- fact.item.generatedicon, where the icon is
--  BUILT from parameters, and fact.item.instanceicon, where it is NAMED by them.
--  Here the whole config is invented, and nothing in this mod has ever looked at
--  one.
--
--  THREE THINGS DECIDE THE FIX AND NONE OF THEM ARE KNOWN:
--
--    1. WHICH KEY HOLDS THE ICON. The .codex source field is "icon", not
--       "inventoryIcon" -- and the "itemConfig" block inside a .codex carries
--       rarity and price and no icon at all, so the engine translates one into
--       the other somewhere. If the result lands under any key other than
--       inventoryIcon, petports_bubbleItemIcon reads nil and every codex in the
--       game falls back to the box.
--    2. WHETHER THE PATH IS ABSOLUTE. "humancover1.png" in the source is
--       relative to the .codex file's own directory.
--    3. WHAT cfg.directory SAYS FOR AN ITEM WITH NO FILE. absolutePath()
--       resolves 2 using 3. If 3 is "/" or empty, the result is a path that
--       cannot exist, and the failure surfaces two files away as an
--       unmeasurable drawable in the overlay rather than as a lookup fault
--       here.
--
--  So this prints all three, then what the real resolver makes of them, then
--  whether that path can be MEASURED. Those last two are what separate the
--  three possible answers, which want three different fixes:
--
--      resolver returns nil      -> wrong key, or a shape not handled
--      path built but UNMEASURABLE -> directory or relativity, case 2/3
--      path measures fine        -> the lookup is right and the fault is in
--                                   the drawing, which is a different file
--
--  KEY NAMES ONLY, NOT THE WHOLE CONFIG. A codex config carries contentPages,
--  which is pages of prose, and dumping it would bury the one line that matters.
--  Every key with "icon" or "image" in its NAME is then printed in full --
--  matched on the name rather than against a fixed list, because the entire
--  point is that the key might not be the one expected.
--
--  LEADS WITH A CONTROL. dirtmaterial is plain and file-backed, so the generated
--  items have something to be different FROM. A directory or a key that looks
--  odd means nothing until the known-good one has been read in the same format.
--
--  THE RECIPE NAME IS NOT DEFAULTED. Which items have a "-recipe" is a fact
--  about the recipe database rather than the item database, and a guess that
--  misses costs a whole test cycle to find out. Pass the exact name that was
--  seen to fail.

--  Measure one path and say plainly whether it exists. Split out because a
--  layered icon needs this per layer and a single path needs it once.
--
--  AN UNMEASURABLE PATH IS THE VERDICT, NOT A HICCUP. root.imageSize resolves
--  directives and answers for framed paths -- fact.tooling.imageregion -- so a
--  refusal here means the asset is not there, which is case 2 or 3 above.
function petports_bubbleProbeMeasure(label, path)
	if type(path) ~= "string" then
		sb.logInfo("PROBE %s -- not a path (%s)", tostring(label), type(path))
		return
	end

	local sized, size = pcall(root.imageSize, path)
	local regioned, region = pcall(root.nonEmptyRegion, path)

	local sizeText = "UNMEASURABLE -- THIS ASSET DOES NOT RESOLVE"
	if sized and type(size) == "table" then
		local shown, encoded = pcall(sb.printJson, size)
		sizeText = shown and encoded or "unprintable"
	end

	local regionText = "unavailable"
	if regioned and type(region) == "table" then
		local shown, encoded = pcall(sb.printJson, region)
		regionText = shown and encoded or "unprintable"
	end

	sb.logInfo("PROBE %s path %s canvas %s visible %s", tostring(label),
		path, sizeText, regionText)
end

--  EVERY ASSET-LOOKING STRING ANYWHERE IN A TABLE, WITH THE PATH THAT REACHED
--  IT. Collected as "config.foo.bar = /some/art.png".
--
--  BECAUSE THE KEY NAME IS THE THING WE DO NOT KNOW. Matching on keys called
--  "icon" or "image" only finds an icon that is already named the way we
--  expect, and the codex case has already proved that assumption wrong once --
--  it came back nil from both reads, so whatever holds its art is not called
--  inventoryIcon. A value that ends in .png is an asset no matter what the key
--  above it says.
--
--  DEPTH CAPPED AT 3 AND contentPages SKIPPED. A codex config carries pages of
--  prose in a nested list; walking it in full would cost nothing but would
--  bury the answer under it. Nothing observed so far nests art deeper than a
--  list of drawables inside a key.
local function collectAssets(value, trail, out, depth)
	if depth > 3 then return end

	if type(value) == "string" then
		local lower = value:lower()

		if lower:find(".png", 1, true) or lower:find(".jpg", 1, true) then
			out[#out + 1] = trail .. " = " .. value
		end
		return
	end

	if type(value) ~= "table" then return end

	for key, sub in pairs(value) do
		if key ~= "contentPages" then
			collectAssets(sub, trail .. "." .. tostring(key), out, depth + 1)
		end
	end
end

--  Probe one item name end to end.
function petports_bubbleProbeOne(name)
	local descriptor = { name = name, count = 1 }

	local ok, cfg = pcall(root.itemConfig, descriptor)
	if not ok or cfg == nil then
		sb.logInfo("PROBE %s -- root.itemConfig gave nothing (%s). No such item "
			.. "under that name, so nothing below this line ran.",
			tostring(name), tostring(cfg))
		return
	end

	sb.logInfo("PROBE %s directory %s", tostring(name), tostring(cfg.directory))

	local config = cfg.config
	if type(config) ~= "table" then
		sb.logInfo("PROBE %s has no config table (%s)", tostring(name), type(config))
		return
	end

	--  SORTED. The question is which key the icon is under, and an alphabetical
	--  list is readable where pairs() order is not.
	local keys = {}
	for key in pairs(config) do keys[#keys + 1] = tostring(key) end
	table.sort(keys)

	sb.logInfo("PROBE %s config keys: %s", tostring(name), table.concat(keys, " "))

	for _, key in ipairs(keys) do
		local lower = key:lower()

		if lower:find("icon", 1, true) or lower:find("image", 1, true) then
			local shown, encoded = pcall(sb.printJson, config[key])
			sb.logInfo("PROBE %s config.%s = %s", tostring(name), key,
				shown and encoded or type(config[key]))
		end
	end

	local pkeys = {}
	if type(cfg.parameters) == "table" then
		for key in pairs(cfg.parameters) do pkeys[#pkeys + 1] = tostring(key) end
		table.sort(pkeys)
	end

	sb.logInfo("PROBE %s parameter keys: %s", tostring(name),
		#pkeys > 0 and table.concat(pkeys, " ") or "(none)")

	--  THE WHOLE CONFIG AND THE WHOLE PARAMETER BLOCK, HUNTED FOR ART. If the
	--  codex icon is in here at all this is what finds it, whatever it is
	--  called. If nothing comes back, the icon is NOT IN THE CONFIG -- which
	--  means the engine assembles it in C++ from the codex database and no
	--  read of root.itemConfig will ever reach it. That is a different fix and
	--  this line is what tells the two apart.
	local assets = {}
	collectAssets(config, "config", assets, 0)
	collectAssets(cfg.parameters, "parameters", assets, 0)

	if #assets == 0 then
		sb.logInfo("PROBE %s carries NO asset path anywhere in its config or "
			.. "parameters", tostring(name))
	end

	for _, line in ipairs(assets) do
		sb.logInfo("PROBE %s %s", tostring(name), line)
	end

	--  THE REAL RESOLVER, NOT A REIMPLEMENTATION OF IT. Whatever this build
	--  ships is what the bubble will do; a probe that decided for itself what
	--  the icon should be would agree with itself and prove nothing.
	local icon = petports_bubbleItemIcon(descriptor)

	if icon == nil then
		sb.logInfo("PROBE %s resolver returned NIL -- this item draws as the box",
			tostring(name))
		return
	end

	if type(icon) == "string" then
		petports_bubbleProbeMeasure(name, icon)
		return
	end

	sb.logInfo("PROBE %s resolved to %s layer(s)", tostring(name), tostring(#icon))

	for i, layer in ipairs(icon) do
		petports_bubbleProbeMeasure(tostring(name) .. " layer " .. tostring(i),
			type(layer) == "table" and layer.image or layer)
	end
end

function petports_bubbleProbeIcon(...)
	local names = { ... }
	if #names == 0 then names = { "dirtmaterial", "humanhistory1-codex" } end

	for _, name in ipairs(names) do
		petports_bubbleProbeOne(name)
	end
end
