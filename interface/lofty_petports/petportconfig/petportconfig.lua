--  PETPORTS -- PETPORT PANE SCRIPT
--
--  SKELETON. Renders whatever state the port publishes, switches tabs, and
--  hands three actions back to the object. It computes nothing.
--
--  THE PANE IS A VIEW. Same rule the upcycler pane follows and for the same
--  reason: the port behaves identically whether or not anyone is looking at it,
--  so this polls and never drives. There is deliberately no way to ask whether
--  the pane is open and nothing here needs one.
--
--  READ PATH IS A SINGLE PARAMETER, NOT A MESSAGE ROUND TRIP.
--
--  world.getObjectParameter is reachable from a container pane script -- proven
--  on the upcycler, not assumed here. The port mirrors one summary blob into
--  PANE_STATE_KEY and this reads it. That is the same shape the upcycler uses
--  for points and blips, so there is one transport in the mod rather than two.
--
--  THE MIRROR IS CHANGE-GATED ON THE PORT SIDE AND THAT MATTERS. Fuel is
--  quantised to a blip index before it is written, so a draining unit costs
--  eight writes over its whole bar rather than one per tick. A port cannot know
--  whether anyone is watching, so an ungated mirror would run forever on every
--  port in the world.
--
--  WRITE PATH IS A MESSAGE, because three of these actions change state.

local DEBUG = true

--  Bump on every change to this file. A pane has no visible version and a stale
--  copy is indistinguishable from an unfixed one -- which cost a cycle on the
--  upcycler before the stamp existed.
local PANE_BUILD_STAMP = "2026-08-29e pickup/sorting swapped, relabelled"

local PANE_STATE_KEY = "petports_paneState"

--  ITS OWN SPRITE, NOT THE UPCYCLER'S. blip.png is 6px of solid ink and is
--  SHARED with the reagent charge; twenty of those in the fuel bar's 106px band
--  would overlap by a pixel each, and widening it would reach into a machine
--  that has nothing to do with fuel. fuelblip.png is 4px on the same
--  white-inside-black construction, so "?multiply=" tints it identically.
--
--  TWENTY, AND THE PORT MUST AGREE. The port quantises hunger to this many
--  steps BEFORE it writes the mirror -- that quantisation is what keeps a
--  draining unit down to twenty writes instead of one per tick. So this number
--  is the port's write resolution as much as it is a count of widgets, and
--  raising it here without raising PANE_FUEL_BLIPS there just makes the top of
--  the bar unreachable.
local BLIP_ART = "/interface/lofty_petports/petportconfig/fuelblip.png"
local BLIP_COUNT = 20

--  Empty cells are the same sprite multiplied to near-black rather than a
--  second asset, so the bar never changes length. A bar that shrinks as it
--  drains reads as capacity being lost rather than spent.
local BLIP_EMPTY = "2a2a2aff"

--  Fuel colour walks warm as it empties. Three bands, not a gradient: a player
--  reads "fine / getting low / feed me" and nothing finer than that is
--  actionable.
local BLIP_FULL = "7fd4ffff"
local BLIP_LOW = "ffc75fff"
local BLIP_CRITICAL = "ff6b6bff"

local DIAG_SLOTS = 4

--  FIVE, AND THE CONFIG MUST DECLARE EXACTLY THIS MANY moduleSlot WIDGETS.
--  petports_petport.lua's MODULE_SLOTS_MAX is the same number and clamps on the
--  write side, so an item authoring more gets five rather than a set of
--  invisible slots whose contents could never be taken out again.
local MODULE_SLOTS = 5

--  THE TAG THAT MAKES SOMETHING A MODULE.
--
--  THE PANE IS ALLOWED TO ASK THIS, AND THAT IS NOT A DUPLICATED RULE. It is a
--  question about the ITEM, answered by root.itemHasTag, and the port's commit
--  handler asks the same question of the same item -- so the two cannot come
--  back with different answers the way two hand-written predicates could.
--
--  It has to be asked HERE because the swap is performed here. See
--  moduleSlotClicked.
local MODULE_TAG = "petports_module"

local STATS_LINES = 8

--  Severity tints for the diagnostic row, sharing the crosshair vocabulary on
--  purpose: a player who has learned the world markers can already read these.
local DIAG_TINT = {
	info = "9aa4b0ff",
	warn = "ffa53cff",
	error = "ff5a5aff"
}

local TAB_WIDGETS = { "tabDetails", "tabSettings", "tabStats" }

--  THE FOUR PARTICIPATION BOXES, AND THE ONE PLACE THEIR NAMES ARE LISTED.
--
--  Ordered as they are laid out -- hauling, sorting / farming, machines -- so
--  reading this is reading the pane.
local GROUPS = { "hauling", "sorting", "farming", "machines" }

--  Widget name per group. Derived rather than tabulated would mean
--  "group" .. "hauling" and a capitalisation rule; two of these are wanted as
--  strings anyway, for the tooltip lookup.
local GROUP_WIDGET = {
	hauling = "groupHauling",
	sorting = "groupSorting",
	farming = "groupFarming",
	machines = "groupMachines"
}

--  WHAT EACH BOX ACTUALLY GATES, IN THE PLAYER'S WORDS.
--
--  ^green; MARKS THE VERB, AND THE ^reset; AFTER IT IS NOT OPTIONAL. Starbound
--  colour codes run until they are reset, so a missing one tints the remainder
--  of the tooltip and, depending on where the box ends, whatever is drawn after
--  it.
--
--  DESCRIBES THE BEHAVIOUR, NOT THE GENERATORS. "Sorting" is four work
--  generators -- restock in both directions, tidying and compaction -- and
--  naming them would be true and useless; what a player sees is items moving
--  from one crate to another.
--
--  THE KEY `hauling` READS AS "Item Pickup" IN THE PANE, and the mismatch is
--  deliberate. The key is what a stored setting names and is frozen; the label
--  is free. See petportParticipates in petports_petport.lua, which carries the
--  same note and the reason renaming the key would quietly re-enable the group
--  on every port already configured.
--
--  NOT WHAT THESE SAY, DELIBERATELY: that deposit and recall are ungated. A
--  player who unticks everything still sees a unit carry its load to a crate
--  and walk home, and explaining why in a tooltip would cost four lines to
--  pre-empt a question nobody has yet asked. It is in the port's comments where
--  the next person to change this will find it.
local GROUP_TOOLTIP = {
	hauling = "This pet will ^green;pick up unattended items^reset; within network coverage.",
	sorting = "This pet will ^green;move items^reset; between storage containers within network coverage.",
	farming = "This pet will ^green;automatically water and replant crops^reset; within network coverage.",
	machines = "This pet will automatically ^green;deliver requested items to machines^reset; (such as Upcyclers) within network coverage."
}

--  Widgets owned by each tab. Membership lives here rather than in the config
--  so showTab has exactly one list to be wrong about.
local TAB_MEMBERS = {
	tabDetails = {
		"detailsModulesLabel",
		"moduleSlot1", "moduleSlot2", "moduleSlot3", "moduleSlot4", "moduleSlot5",
		"detailsFlavorLabel", "detailsFlavorValue",
		"feedSlot", "feedHint",
		"detailsSerial", "renameButton"
	},
	tabSettings = {
		"setCarried", "setCarriedLabel",
		"setCrosshairs", "setCrosshairsLabel"
	},
	tabStats = {
		"statsLine1", "statsLine2", "statsLine3", "statsLine4",
		"statsLine5", "statsLine6", "statsLine7", "statsLine8"
	}
}

--  Everything in the pet column, hidden wholesale when nothing is socketed.
--  This is the placeholder for the partial overlay described in the config --
--  one flag either way, but an overlay is one widget and this is twenty.
local PET_COLUMN = {
	"petName", "petSpecies", "petPreview",
	"fuelLabel", "cargoLabel", "cargoSlot", "cargoTake",
	"taskLabel", "diagLabel"
}

--  sb.logInfo accepts %s and nothing else, so everything is pre-formatted
--  through string.format, which has no such limit.
local function dbg(fmt, ...)
	if not DEBUG then return end
	local ok, text = pcall(string.format, fmt, ...)
	sb.logInfo("PETPORTS petportpane: %s", ok and text or ("<badformat> " .. tostring(fmt)))
end

local function setVisibleAll(names, visible)
	for _, name in ipairs(names) do
		widget.setVisible(name, visible)
	end
end

--  sb.printJson can throw on something it cannot serialise, and a logging call
--  is the last thing that should take a pane down. Same helper the upcycler
--  pane carries, for the same reason.
local function j(value)
	local ok, text = pcall(sb.printJson, value)
	return ok and text or "<unprintable>"
end

--  ---------------------------------------------------------------------------
--  READING THE PORT
--  ---------------------------------------------------------------------------

local function portId()
	return pane.containerEntityId()
end

local function readState()
	local id = portId()
	if id == nil then return nil end

	local ok, state = pcall(world.getObjectParameter, id, PANE_STATE_KEY, nil)
	if not ok then
		dbg("getObjectParameter threw: %s", tostring(state))
		return nil
	end
	if type(state) ~= "table" then return nil end
	return state
end

--  FIRE AND FORGET, AND THAT IS DELIBERATE FOR TWO OF THE THREE. A lost setting
--  toggle costs a click. The two that move items -- take and feed -- are still
--  one-way, because the port is the authority on cargo and this pane redraws
--  from the mirror on the very next poll regardless of what it thinks happened.
--  Nothing here may guess at an outcome and paint it.
local function tell(name, payload)
	local id = portId()
	if id == nil then return end
	world.sendEntityMessage(id, name, payload)
end

--  ---------------------------------------------------------------------------
--  PAINTING
--  ---------------------------------------------------------------------------

--  WHICH TAB IS SHOWING. Declared here rather than beside showTab because
--  paintModuleSlots is defined above that section and has to read it -- a
--  `local` further down the file is a nil global to everything before it.
local activeTab = "tabDetails"

--  Last drawn tint per cell. This runs every poll, so an unchanged bar has to
--  cost nothing.
--
--  GATING A REDRAW IS SAFE; GATING VISIBILITY IS NOT. The upcycler's blips were
--  latched invisible forever by a setVisible inside a gate whose cache outlived
--  the widget. These cells are never hidden -- only recoloured -- which is what
--  makes the gate harmless here.
local blipShown = {}

local function paintFuel(blips)
	local filled = math.max(0, math.min(BLIP_COUNT, math.floor(blips or 0)))

	local tint = BLIP_FULL
	if filled <= 2 then
		tint = BLIP_CRITICAL
	elseif filled <= 4 then
		tint = BLIP_LOW
	end

	for i = 1, BLIP_COUNT do
		local want = (i <= filled) and tint or BLIP_EMPTY
		if blipShown[i] ~= want then
			blipShown[i] = want
			--  The declared file is bare precisely so this is the only
			--  directive in play. Directives COMPOUND rather than replace.
			widget.setImage("fuelBlip" .. i, BLIP_ART .. "?multiply=" .. want)
		end
	end
end

local function paintCargo(cargo)
	local stack = cargo and cargo[1] or nil

	if stack == nil then
		widget.setItemSlotItem("cargoSlot", nil)
		widget.setButtonEnabled("cargoTake", false)
		return
	end

	--  Handed straight to the widget. The port already clamped the count to one
	--  maxStack before mirroring it -- an oversized descriptor crossing the wire
	--  surfaces as a bad_alloc naming neither the pane nor the item.
	--  THE WIDGET DRAWS THE COUNT ITSELF. An earlier comment here claimed it
	--  does not; it hides a count of ONE, exactly as an inventory slot does, so
	--  a single-item cargo and a broken readout looked the same.
	widget.setItemSlotItem("cargoSlot", stack)
	widget.setButtonEnabled("cargoTake", true)
end

--  What each icon's tooltip should say, indexed the same as the icons. Held
--  here because createTooltip is called on hover with only a screen position
--  and has no other way to reach the state that produced the row.
local diagText = {}

local function paintDiagnostics(diags)
	diags = diags or {}

	for i = 1, DIAG_SLOTS do
		local d = diags[i]
		local name = "diag" .. i
		diagText[i] = d and (d.full or d.short) or nil
		if d == nil then
			widget.setVisible(name, false)
		else
			local tint = DIAG_TINT[d.severity or "warn"] or DIAG_TINT.warn
			widget.setImage(name, "/interface/lofty_petports/upcyclerconfig/warning.png?multiply=" .. tint)
			widget.setVisible(name, true)
		end
	end

	--  THE LABEL CARRIES THE WORST CONDITION ONLY, and the tooltips carry the
	--  rest. paneDiagnostics emits worst-first, so the one line on screen is
	--  always the one that matters most -- but a second icon with no tooltip is
	--  a shape with no way to find out what it means, which is what createTooltip
	--  below is for.
	--  One line, fixed height, never wrapped.
	widget.setText("diagLabel", diags[1] and (diags[1].short or "") or "")
end

--  ---- the portrait ---------------------------------------------------------
--
--  world.entityPortrait(entityId, mode) returns a LIST OF DRAWABLES for a
--  portrait entity, or nil if the entity is not one. Same call the bounty board
--  uses for its live monster preview.
--
--  THE MODE STRING IS TRIED IN ORDER AND THE ANSWER IS CACHED. The enum is
--  Head / Bust / Full / FullNeutral / FullNude / FullNeutralNude, and whether
--  the binding wants the name, the lowercase name or the ordinal is not
--  something we know -- so all three are tried once, the winner is remembered,
--  and the outcome is logged. Guessing one and shipping it would fail silently:
--  a nil return and a monster that is not a portrait entity look identical.
local PORTRAIT_MODES = { "Full", "full", 2 }

--  THE PORTRAIT FITS ITSELF TO THE CANVAS, rather than carrying a magic number.
--
--  A fixed 3.0 overflowed and clipped the unit; 2.0 would fit THIS chassis and
--  break again the first time a larger pet exists. So the drawables are
--  measured, their union is fitted to the box, and the scale falls out.
--
--  CAPPED AT PORTRAIT_MAX_SCALE so a small sprite is not blown up into mush,
--  and floored at 1 so a huge one still shrinks. PORTRAIT_PAD keeps the fit off
--  the canvas edge, since a portrait touching the border reads as clipped even
--  when it is whole.
local PORTRAIT_MAX_SCALE = 4.0
local PORTRAIT_PAD = 6

--  Used only when the layout is unavailable -- see layoutDrawables.
local PORTRAIT_FALLBACK_SCALE = 2.0

--  INDICATOR LAYERS ARE EXCLUDED FROM THE PORTRAIT, AND THE REASON IS A
--  DIRECTION PROBLEM RATHER THAN A CLUTTER ONE.
--
--  The thinking spinner is an animationState part on the monster, so
--  entityPortrait returns it like any other part. But the engine force-mirrors
--  a left-facing animated actor, and the spinner art is pre-flipped to
--  compensate -- so IN WORLD it needs flipping about half the time, and IN THIS
--  PANE it needs flipping none of the time. There is no single art asset that
--  satisfies both, and the same will be true of every speech bubble and status
--  icon that goes through the same pipeline.
--
--  So the portrait drops them and the in-world flip logic stays as it is,
--  correct for the one consumer it was written for.
--
--  MATCHED ON PATH FRAGMENT, DELIBERATELY, so this is a convention rather than
--  a list. Moving the spinner under a shared indicator root -- and putting
--  every future bubble there too -- makes one fragment cover all of them with
--  no edit here. Until that move happens this names the current location.
local PORTRAIT_EXCLUDE = {
	"/lofty_petports/shared/spinner/",
	"/lofty_petports/shared/indicator"
}

local function isIndicator(path)
	for _, fragment in ipairs(PORTRAIT_EXCLUDE) do
		if string.find(path, fragment, 1, true) then return true end
	end
	return false
end

--  ---- layout -----------------------------------------------------------------
--
--  EVERY DRAWABLE CARRIES A 3x3 AFFINE `transformation`, AND IGNORING IT WAS
--  WRONG. Measured off a live unit:
--
--      body  position [0,  0]  [[-1,0,12],[0,1,-8],[0,0,1]]
--      spin  position [0, 12]  [[-1,0, 8],[0,1,-8],[0,0,1]]
--
--  Three things fall out of that, and each one corrects an earlier claim here.
--
--  1  a = -1. X IS NEGATED -- the horizontal mirror is IN THE MATRIX, which is
--     the whole question the spinner raised. It is not baked into the art and
--     it is not something the pane has to infer from facing.
--
--  2  tx, ty CENTRE the sprite on its own origin: tx is half the width, ty is
--     minus half the height. So a drawable is centred on its `position`, not
--     anchored at its corner -- which is why the old corner-to-corner extent
--     was the wrong box even when it produced a right-looking answer.
--
--  3  `position` IS NOT ALWAYS ZERO. An earlier note here said it was, on the
--     strength of a bounds line that had already EXCLUDED the spinner -- the
--     one drawable with a non-zero position. Measuring only what you draw and
--     concluding something about what you skipped.
--
--  The matrix is applied properly below rather than assumed to be a mirror plus
--  a centring translate: both corners go through it and the extent comes out of
--  the result. Shear or rotation would still defeat the decomposition, so it is
--  detected and reported rather than silently mangled.
local measuredOnce = false
local transformSignature = nil

local function layoutDrawables(drawables)
	local items = {}
	local x0, y0, x1, y1

	for _, d in ipairs(drawables) do
		local image = d.image or d
		if type(image) == "string" and not isIndicator(image) then
			local ok, size = pcall(root.imageSize, image)
			if not ok or type(size) ~= "table" then
				if not measuredOnce then
					measuredOnce = true
					dbg("root.imageSize unavailable (%s) -- portrait falls back to a fixed scale",
						tostring(size))
				end
				return nil
			end

			local m = d.transformation
			local a, b, tx = -1, 0, size[1] * 0.5
			local c, dd, ty = 0, 1, size[2] * -0.5

			if type(m) == "table" and type(m[1]) == "table" and type(m[2]) == "table" then
				a, b, tx = m[1][1] or a, m[1][2] or 0, m[1][3] or tx
				c, dd, ty = m[2][1] or 0, m[2][2] or dd, m[2][3] or ty
			end

			--  A ROTATION OR SHEAR CANNOT BE EXPRESSED THROUGH drawImage, which
			--  takes a position and a scalar scale and nothing else. Portraits
			--  do not rotate, so this is a tripwire rather than a branch.
			if b ~= 0 or c ~= 0 then
				dbg("portrait drawable has shear/rotation (b=%s c=%s) -- not representable",
					tostring(b), tostring(c))
				return nil
			end

			local p = d.position or { 0, 0 }
			local px, py = p[1] or 0, p[2] or 0

			--  Both corners through the matrix; min/max sorts out the negation.
			local ax, bx = tx + px, a * size[1] + tx + px
			local ay, by = ty + py, dd * size[2] + ty + py
			local lx, hx = math.min(ax, bx), math.max(ax, bx)
			local ly, hy = math.min(ay, by), math.max(ay, by)

			table.insert(items, {
				image = image,
				--  Where the CENTRE of this drawable lands once transformed.
				cx = (lx + hx) * 0.5,
				cy = (ly + hy) * 0.5,
				--  THE RAW SIGN. Whether it becomes a flip is decided below,
				--  against the body rather than against zero.
				sign = (a < 0) and -1 or 1
			})

			x0 = math.min(x0 or lx, lx)
			y0 = math.min(y0 or ly, ly)
			x1 = math.max(x1 or hx, hx)
			y1 = math.max(y1 or hy, hy)
		end
	end

	if x0 == nil or x1 <= x0 or y1 <= y0 then return nil end

	if not measuredOnce then
		measuredOnce = true
		dbg("portrait bounds %sx%s, %s drawable(s) after filtering",
			tostring(x1 - x0), tostring(y1 - y0), tostring(#items))
	end

	--  THE FLIP IS RELATIVE TO THE BODY, NOT ABSOLUTE, AND THAT IS THE WHOLE
	--  RULE.
	--
	--  Obeying the matrix directly means the pane mirrors whenever the engine
	--  does -- so a unit walking left would turn around in its own portrait,
	--  which is not what a readout should do. Ignoring the matrix entirely (the
	--  previous build) gives a stable facing but cannot tell a body apart from
	--  an indicator the engine mirrored on its own.
	--
	--  So the FIRST drawable sets the reference facing and everything else is
	--  measured against it. The unit therefore always faces the way its art is
	--  authored, and an indicator whose transformation group picked up a mirror
	--  the body did not gets un-mirrored -- which is the case that made the
	--  spinner render backwards.
	--
	--  It also means this needs no answer to "does `a` track facing". Either
	--  way the reference moves with the body and the relative result is the
	--  same, so the behaviour is correct before the question is settled.
	local reference = items[1] and items[1].sign or 1
	for _, it in ipairs(items) do
		it.flip = (it.sign ~= reference)
	end

	--  CHANGE-GATED. Logs the RAW signs, not the resolved flips, because the
	--  resolved ones are normalised and would look identical whichever way the
	--  unit faced -- which is the property we want and also the property that
	--  hides the answer. `body` is the reference; a run of these while walking
	--  the unit around says whether the engine's sign tracks facing.
	local sig = ""
	for _, it in ipairs(items) do
		sig = sig .. ((it.sign < 0) and "L" or "R")
	end
	if sig ~= transformSignature then
		transformSignature = sig
		dbg("portrait raw signs -> %s (reference %s, %s flipped)",
			sig, tostring(reference), tostring(#items))
	end

	return {
		items = items,
		cx = (x0 + x1) * 0.5,
		cy = (y0 + y1) * 0.5,
		w = x1 - x0,
		h = y1 - y0
	}
end
local portraitMode = nil
local portraitResolved = false

--  REDRAWN EVERY POLL WHILE A UNIT EXISTS, deliberately unlike mechassembly's,
--  which is static and gated. This one is a LIVE view -- the unit is animating
--  out in the world and the portrait should be too -- so the redraw is the
--  feature rather than waste. At scriptDelta 5 that is roughly 12 a second.
local function paintPreview(petId)
	local canvas = widget.bindCanvas("petPreview")
	if canvas == nil then return end

	canvas:clear()
	if petId == nil then return end

	local drawables = nil

	if not portraitResolved then
		for _, mode in ipairs(PORTRAIT_MODES) do
			local ok, result = pcall(world.entityPortrait, petId, mode)
			if ok and type(result) == "table" and #result > 0 then
				portraitMode = mode
				drawables = result
				dbg("entityPortrait mode resolved to %s, %s drawable(s)",
					tostring(mode), tostring(#result))
				break
			end
			dbg("entityPortrait mode %s: %s", tostring(mode),
				ok and "no drawables" or tostring(result))
		end

		--  RESOLVED EITHER WAY. A failure here is about the BINDING, not about
		--  this particular unit, so retrying it twelve times a second forever
		--  would be twelve log lines a second saying the same thing.
		portraitResolved = true
		if portraitMode == nil then
			dbg("entityPortrait unavailable -- portrait stays blank")
		end
	elseif portraitMode ~= nil then
		local ok, result = pcall(world.entityPortrait, petId, portraitMode)
		if ok and type(result) == "table" then drawables = result end
	end

	if drawables == nil then return end

	local size = widget.getSize("petPreview")
	local centre = { size[1] * 0.5, size[2] * 0.5 }

	local layout = layoutDrawables(drawables)

	if layout == nil then
		--  Unmeasured, or a transform we cannot express: centred stack at a
		--  fixed scale. Parts land on top of each other instead of in their
		--  right relative places, which is wrong but VISIBLE -- and visible
		--  beats a blank box while the reason sits in the log.
		for _, d in ipairs(drawables) do
			local image = d.image or d
			if type(image) == "string" and not isIndicator(image) then
				canvas:drawImage(image, centre, PORTRAIT_FALLBACK_SCALE, nil, true)
			end
		end
		return
	end

	local scale = math.min(
		(size[1] - PORTRAIT_PAD * 2) / layout.w,
		(size[2] - PORTRAIT_PAD * 2) / layout.h)
	scale = math.max(1.0, math.min(PORTRAIT_MAX_SCALE, scale))

	for _, it in ipairs(layout.items) do
		--  CENTRED, BECAUSE THE TRANSFORM CENTRES. tx and ty put the sprite on
		--  its own origin, so its centre is what the layout computed and
		--  centred = true is the matching draw. Anchoring every part on the
		--  UNION's centre is what keeps parts at different offsets framed as
		--  one thing instead of each being centred individually.
		local image = it.flip and (it.image .. "flipx") or it.image
		canvas:drawImage(image, {
				centre[1] + (it.cx - layout.cx) * scale,
				centre[2] + (it.cy - layout.cy) * scale
			},
			scale, nil, true)
	end
end

--  THE PANE'S OWN COPY OF THE MODULE SET, AND IT IS NOT A SECOND AUTHORITY.
--
--  mechassemblygui keeps `self.itemSet` for exactly this reason: a swap needs to
--  know what is currently in the slot in order to hand it back to the cursor,
--  and vanilla does NOT read that back off the widget. It is followed here
--  rather than reaching for widget.itemSlotItem, which is unverified in this
--  codebase -- and the failure mode if it does not exist is the OLD module
--  being overwritten with nil instead of returned, which destroys an item.
--
--  REBUILT FROM THE MIRROR ON EVERY REPAINT, so it can only be stale for as long
--  as it takes the port to write one, and the port's write is what wins.
--
--  Keyed by slot number, holding descriptors. The WIRE format is a record list
--  -- see moduleRecords -- because a table with holes does not survive Json.
local paneModules = {}
local paneModuleSlotCount = 0

--  Wire format out. See petports_petport.lua's MODULES section: a Lua table with
--  a hole converts to a Json OBJECT with string keys, so a slot-indexed array
--  loses a module the first time the item round-trips. A record list is sparse
--  and contiguous at once.
local function moduleRecords()
	local out = {}
	for i = 1, MODULE_SLOTS do
		if paneModules[i] ~= nil then
			table.insert(out, { slot = i, item = paneModules[i] })
		end
	end
	return out
end

--  A SLOT IS VISIBLE ONLY IF THE UNIT HAS EARNED IT *AND* THE DETAILS TAB IS
--  THE ONE SHOWING, AND THE SECOND HALF OF THAT IS A BUG FIX.
--
--  This runs from paintModules, which runs from refresh, which runs on every
--  poll where the port's state changed -- regardless of which tab the player is
--  looking at. So switching to Settings hid the slots correctly, and then the
--  next mirror write painted them straight back on top of the Settings tab.
--
--  It only ever looked right because tabDetailsClicked calls refresh(true)
--  immediately after showTab, so the path INTO details always corrected itself.
--  The path out did not.
--
--  THE ASYMMETRY IS WHY THIS LIVES HERE RATHER THAN IN showTab. showTab hides
--  every member of the outgoing tab wholesale, which is right; what it cannot
--  do is stop a later repaint from disagreeing with it. The paint has to carry
--  the condition itself.
local function paintModuleSlots()
	local showing = (activeTab == "tabDetails")

	for i = 1, MODULE_SLOTS do
		local name = "moduleSlot" .. i
		if showing and i <= paneModuleSlotCount then
			widget.setVisible(name, true)
			widget.setItemSlotItem(name, paneModules[i])
		else
			--  An unearned slot is ABSENT, not empty. An empty slot invites a
			--  drag that would be silently refused, which reads as a bug.
			--
			--  The CONTENTS are still written above only when it is visible;
			--  a hidden slot keeps whatever it last held, which is harmless
			--  because paneModules is the authority and it gets rewritten
			--  before the slot is ever shown again.
			widget.setVisible(name, false)
		end
	end
end

--  AN OUTSTANDING MODULE WRITE, AND THIS IS WHAT STOPS THE PORT EATING ONE.
--
--  THE BUG IT FIXES, IN ORDER. paneModules is BOTH the display state and the
--  source of the wire payload. paintModules rebuilds it from the mirror, and the
--  mirror carries cargo -- so a unit picking an item up moves the signature for
--  a reason that has nothing to do with modules. If that write was composed
--  before the port processed a pending setModules, the repaint puts paneModules
--  back to the PRE-SWAP set while the module is already out of the cursor.
--
--  The next click is what destroys it. moduleRecords() is built from a table
--  that no longer mentions the module, the port replaces the whole set with
--  that, and `previous` reads nil -- so setSwapSlotItem hands the player nothing
--  back either. The module exists nowhere. Repeated socketing with cargo moving
--  is exactly the shape that reaches it.
--
--  A TOKEN RATHER THAN A TIMEOUT. The pane stamps each write, the port echoes
--  the stamp it last acted on, and the pane treats the mirror's module set as
--  authoritative only once its own stamp comes back. A deadline would have to
--  guess how long a commit takes and would be wrong on a loaded server.
--
--  IT RESOLVES ON REFUSAL TOO, which is the property that makes it safe. The
--  port stamps before it validates, so a rejected set still echoes and the pane
--  stops waiting and repaints from truth -- the module visibly disappears
--  instead of the pane waiting forever showing a phantom.
--
--  ONLY MODULES ARE HELD BACK. Everything else in a mirror arriving mid-flight
--  -- fuel, cargo, task, diagnostics -- is painted normally. The port is the
--  authority on all of it and none of it is in flight.
local moduleWriteToken = nil
local moduleTokenSeq = 0

local function nextModuleToken()
	moduleTokenSeq = moduleTokenSeq + 1

	--  UUID-PREFIXED SO TWO PANES CANNOT COLLIDE. On a server, two players can
	--  have this open on the same port at once, and a bare counter would let one
	--  pane's echo resolve the other's wait.
	local ok, uuid = pcall(sb.makeUuid)
	return (ok and tostring(uuid) or "pane") .. ":" .. tostring(moduleTokenSeq)
end

local function paintModules(state)
	paneModuleSlotCount = math.max(0, math.min(MODULE_SLOTS, state.moduleSlots or 0))

	if moduleWriteToken ~= nil then
		if state.moduleToken ~= moduleWriteToken then
			--  THIS MIRROR PREDATES OUR WRITE. Keep the local set, repaint the
			--  widgets from it so a slot count change still lands, and wait.
			dbg("holding module paint: mirror token %s, waiting on %s",
				tostring(state.moduleToken), tostring(moduleWriteToken))
			paintModuleSlots()
			return
		end
		moduleWriteToken = nil
	end

	--  REBUILT, NOT MERGED. Anything the port no longer reports is gone, which
	--  is what makes the port the authority rather than this table.
	paneModules = {}
	for _, record in ipairs(state.modules or {}) do
		local slot = tonumber(record and record.slot)
		if slot ~= nil and slot >= 1 and slot <= MODULE_SLOTS then
			paneModules[slot] = record.item
		end
	end

	paintModuleSlots()
end

local function paintStats(lines)
	lines = lines or {}
	for i = 1, STATS_LINES do
		widget.setText("statsLine" .. i, lines[i] or "")
	end
end

--  ---------------------------------------------------------------------------
--  TABS
--  ---------------------------------------------------------------------------

local function showTab(which)
	activeTab = which

	for _, name in ipairs(TAB_WIDGETS) do
		widget.setChecked(name, name == which)
		setVisibleAll(TAB_MEMBERS[name], name == which)
	end

	--  setVisibleAll SHOWS ALL FIVE MODULE SLOTS, including the ones this unit
	--  has not earned, because it works off a flat membership list that cannot
	--  know the count. Re-applying the count here means the correction does not
	--  depend on the caller remembering to force a refresh afterwards.
	paintModuleSlots()

	dbg("tab -> %s", which)
end

--  ---------------------------------------------------------------------------
--  THE POLL
--  ---------------------------------------------------------------------------

local lastSignature = nil

--  The entity id of the unit as of the last mirror read, or nil when nothing is
--  spawned. update paints from this; refresh only sets it.
local livePetId = nil

local function refresh(force)
	local state = readState()

	if state == nil then
		livePetId = nil
		paneModules = {}
		paneModuleSlotCount = 0
		moduleWriteToken = nil
		widget.setText("petName", "No unit")
		widget.setText("petSpecies", "")
		widget.setText("taskLabel", "")
		setVisibleAll(PET_COLUMN, false)
		setVisibleAll(TAB_MEMBERS[activeTab], false)
		paintFuel(0)
		return
	end

	--  ONE SIGNATURE FOR THE WHOLE BLOB. The port only rewrites the parameter
	--  when something actually changed, so an unchanged read is the common case
	--  and repainting it every tick would be pure waste.
	local ok, signature = pcall(sb.printJson, state)
	if not force and ok and signature == lastSignature then return end
	if ok then lastSignature = signature end

	local hasUnit = state.hasUnit == true

	setVisibleAll(PET_COLUMN, hasUnit)
	setVisibleAll(TAB_MEMBERS[activeTab], hasUnit)

	--  THE PORT BAND IS PAINTED ABOVE THE hasUnit RETURN, AND THAT PLACEMENT IS
	--  THE WHOLE POINT OF THE BAND.
	--
	--  Network id and the enabled switch belong to the PORT, so they mean
	--  something with nothing socketed -- which is exactly when a player is most
	--  likely to be looking at them. Painting them at the bottom of this
	--  function, below the early return, meant an empty port showed whatever the
	--  config declared: "id: --" forever, and an enabled checkbox stuck ON no
	--  matter what the port actually was.
	--
	--  Same shape as the unreachable progress signal in the task action: a
	--  paint below a branch that returns is a paint that does not happen.
	--
	--  setChecked RATHER THAN A GATE. The port is the authority; a refused
	--  toggle has to be able to move the box back, and it can only do that if
	--  every repaint asserts the port's value over whatever the click left.
	widget.setChecked("portEnabled", state.enabled ~= false)
	widget.setText("portNetworkLabel", "id: " .. tostring(state.network or "--"))

	--  ABSENT MEANS PARTICIPATING, matching the port's own reader. A mirror from
	--  a port that predates this field must not paint four empty boxes and tell
	--  the player their unit has been opted out of everything.
	local participation = state.participation or {}
	for _, group in ipairs(GROUPS) do
		widget.setChecked(GROUP_WIDGET[group], participation[group] ~= false)
	end

	if not hasUnit then
		livePetId = nil
		paneModules = {}
		paneModuleSlotCount = 0
		moduleWriteToken = nil
		widget.setText("petName", "No unit")
		widget.setText("petSpecies", "")
		return
	end

	widget.setText("petName", state.petName or "Unnamed unit")

	--  THE SPECIES LINE IS A DIFF, NOT A FIELD. It appears only when the player
	--  has renamed the unit, so the port sends both and the comparison happens
	--  once, here.
	if state.species and state.petName and state.species ~= state.petName then
		widget.setText("petSpecies", state.species)
	else
		widget.setText("petSpecies", "")
	end

	--  RECORDED HERE, PAINTED FROM update. refresh is signature-gated and
	--  returns early on an unchanged blob, which is the common case -- so a
	--  portrait painted from in here would freeze on the first frame and stay
	--  frozen. The animation is the point.
	livePetId = state.petId
	paintFuel(state.fuelBlips)
	paintCargo(state.cargo)

	widget.setText("taskLabel", state.task or "")
	paintDiagnostics(state.diagnostics)

	paintModules(state)
	widget.setText("detailsFlavorValue", state.flavor or "--")
	widget.setText("detailsSerial", state.serial and ("Serial " .. state.serial) or "")

	paintStats(state.stats)
end

--  ---------------------------------------------------------------------------
--  CALLBACKS -- globals, because scriptWidgetCallbacks resolves them by name
--  ---------------------------------------------------------------------------

function tabDetailsClicked()
	showTab("tabDetails")
	refresh(true)
end

function tabSettingsClicked()
	showTab("tabSettings")
	refresh(true)
end

function tabStatsClicked()
	showTab("tabStats")
	refresh(true)
end

--  THE ONE PLACE A REPLY IS READ. Everything else here is fire-and-forget; this
--  is not, because the port debits petData and hands the stack back, and the
--  pane is what puts it in the player's inventory.
--
--  A PROMISE, POLLED IN update, BECAUSE IT DOES NOT RESOLVE IN THIS FRAME.
--  Only one is ever outstanding: the button is disabled until the next mirror
--  poll repaints it, so a second click cannot land on the same stack.
local pendingTake = nil

function cargoTakeClicked()
	if pendingTake ~= nil then return end

	dbg("take cargo requested")
	widget.setButtonEnabled("cargoTake", false)

	local id = portId()
	if id == nil then return end
	pendingTake = world.sendEntityMessage(id, "petports_takeCargo", {})
end

local function pollTake()
	if pendingTake == nil then return end
	if not pendingTake:finished() then return end

	local promise = pendingTake
	pendingTake = nil

	if not promise:succeeded() then
		dbg("take failed -- port did not answer")
		return
	end

	local stack = promise:result()
	if type(stack) ~= "table" or stack.name == nil then
		dbg("take returned nothing")
		return
	end

	--  KNOWN GAP, RECORDED ON BOTH SIDES. The port has already debited by the
	--  time this runs, so a player with no room loses the stack to the floor --
	--  and a drop in front of a petport is an item this network collects again.
	--  The fix is an ack before the debit rather than anything here.
	player.giveItem(stack)
	dbg("gave %s x%s", tostring(stack.name), tostring(stack.count))

	refresh(true)
end

--  MECH ASSEMBLY'S SWAP, PERFORMED HERE AND SYNCHRONOUSLY, WITH TWO ADDITIONS.
--
--  THE EARLIER DESIGN SENT THE DESCRIPTOR AND LET THE PORT DECIDE, AND THAT WAS
--  A DUPLICATION BUG WAITING FOR THE PORT TO STOP REFUSING. It read the cursor
--  and deliberately did not take it, so the moment the far end accepted
--  anything the player kept the item AND the unit gained a copy.
--
--  A ROUND TRIP CANNOT BE MADE ATOMIC, and every ordering of one is wrong in a
--  different direction. Take the cursor first and a refusal destroys the item.
--  Commit on the port first and a dropped reply duplicates it. Vanilla never
--  faces the choice because mechassemblygui never crosses the boundary
--  mid-move: it reads the cursor, writes the old occupant back to the cursor,
--  repaints, and only then reports the finished set. So does this.
--
--  WHICH MEANS THE PANE HOLDS THE TEST -- but not a rule of its own. It asks
--  root.itemHasTag, and the port's commit handler asks the same question of the
--  same item, so the two cannot disagree the way two hand-written predicates
--  could. That is the property that makes doing the swap here safe.
--
--  vanilla's gate is `if not swapItem or <valid for this slot>`: an empty cursor
--  always succeeds, so taking a module OUT is never blocked, and a full one has
--  to pass.
--
--  ADDITION ONE, THE COUNT CHECK. player.swapSlotItem() returns the WHOLE cursor
--  stack and mechassemblygui does not clamp it, because mech parts cannot stack.
--  Modules are maxStack 1 for the same reason and this refuses rather than
--  trusting that every module ever authored will be.
--
--  ADDITION TWO, THE SLOT GATE. Vanilla's slots all exist; ours are earned, and
--  a click on a slot beyond what this unit has must not write one the port would
--  then reject -- with the item already out of the cursor.
function moduleSlotClicked(widgetName)
	--  THE LAST CHARACTER, WHICH SURVIVES A PATH. Some widget callbacks receive
	--  a full widget path rather than a leaf name, and both end in the same
	--  digit. Correct for moduleSlot1..9; MODULE_SLOTS is 5 and the config
	--  declares exactly that many, so the two-digit case is unreachable.
	local index = tonumber(string.sub(widgetName, -1))
	if index == nil or index < 1 or index > MODULE_SLOTS then return end

	if index > paneModuleSlotCount then
		dbg("ignoring click on slot %s: unit has %s", tostring(index),
			tostring(paneModuleSlotCount))
		return
	end

	local cursor = player.swapSlotItem()

	if cursor ~= nil and (cursor.count or 1) > 1 then
		dbg("refusing module swap: cursor holds %s", tostring(cursor.count))
		return
	end

	if cursor ~= nil then
		local ok, isModule = pcall(root.itemHasTag, cursor.name, MODULE_TAG)
		if not ok or isModule ~= true then
			dbg("refusing module swap: %s is not a module", tostring(cursor.name))
			return
		end
	end

	--  THE MOVE, IN VANILLA'S ORDER. The old occupant goes to the cursor and the
	--  new one goes to the slot, so the item count in the world is unchanged at
	--  every point in between.
	local previous = paneModules[index]
	player.setSwapSlotItem(previous)
	paneModules[index] = cursor
	widget.setItemSlotItem(widgetName, cursor)

	dbg("slot %s: %s -> %s", tostring(index),
		tostring(previous and previous.name or "empty"),
		tostring(cursor and cursor.name or "empty"))

	--  REPORTED AS A FINISHED SET, matching mechassemblygui's itemSetChanged.
	--  The port stores it and recomputes the unit's effects; its next mirror
	--  write repaints this pane from what is actually true.
	--
	--  STAMPED, AND THE STAMP IS WHAT KEEPS THE SET INTACT. Until the port
	--  echoes this token back, paintModules must not overwrite paneModules from
	--  a mirror -- an unrelated cargo change would otherwise repaint the module
	--  we just socketed straight back out of the local set, and the NEXT click
	--  would then send a payload that does not mention it. See the token block
	--  above paintModules; that is the item-loss path this closes.
	--
	--  A SECOND CLICK BEFORE THE FIRST RESOLVES IS FINE. It stamps a new token
	--  and sends the accumulated set, and the earlier echo simply fails to match
	--  and is ignored.
	moduleWriteToken = nextModuleToken()
	tell("petports_setModules", {
		modules = moduleRecords(),
		token = moduleWriteToken
	})

	--  NO refresh(true) HERE, AND THAT MATTERS. A forced refresh repaints from
	--  the mirror, which still holds the PRE-SWAP module set until the port
	--  writes again -- so it would undo the move on screen and then undo the
	--  undo half a second later. The signature gate in refresh already does the
	--  right thing: it repaints when, and only when, the port's state changes.
end

function feedSlotClicked()
	local cursor = player.swapSlotItem()
	if cursor == nil then return end

	--  ONE TREAT, AND THE PORT TAKES IT OR DOES NOT. The slot is a drop zone
	--  rather than storage: nothing is ever held here, so nothing here needs
	--  serialising.
	tell("petports_feedUnit", { item = cursor })
	refresh(true)
end

--  HOVER TEXT FOR THE DIAGNOSTIC ICONS.
--
--  A pane-level global the engine calls on hover with a SCREEN POSITION and
--  nothing else, so the hovered widget has to be resolved from the position and
--  the text looked up from state the paint pass left behind.
--
--  widget.getChildAt returns a full widget PATH, not a leaf name, so this
--  matches on a substring rather than comparing equal -- the same reason row
--  member callbacks receive a leaf name that is identical for every row.
--
--  Returning nil means "no tooltip here", which is the right answer for every
--  widget in the pane except these four. Anything an itemslot covers already
--  has the engine's own item tooltip and must not be overridden.
function createTooltip(screenPosition)
	local ok, hovered = pcall(widget.getChildAt, screenPosition)
	if not ok or type(hovered) ~= "string" then return nil end

	for i = 1, DIAG_SLOTS do
		if string.find(hovered, "diag" .. i, 1, true) then
			return diagText[i]
		end
	end

	--  THE PARTICIPATION BOXES. Matched on substring for the same reason the
	--  diagnostics are: getChildAt hands back a full widget PATH, not a leaf
	--  name.
	--
	--  MATCHED AFTER THE DIAGNOSTICS AND WITH NO OVERLAP, since no group widget
	--  name contains "diag". If a fifth group is ever added, the thing to check
	--  is that its name does not contain another widget's -- "groupFarm" inside
	--  "groupFarming" would resolve to whichever is tested first.
	for _, group in ipairs(GROUPS) do
		if string.find(hovered, GROUP_WIDGET[group], 1, true) then
			return GROUP_TOOLTIP[group]
		end
	end

	return nil
end

function renameClicked()
	dbg("rename requested -- not built")
end

--  TWO TOGGLES, AND THE TWO THAT WERE HERE ARE GONE FOR DIFFERENT REASONS.
--
--  "Complain when blocked" was never specified anywhere -- it does not appear in
--  the design intent, nothing reads it, and it was carried into this pane on
--  nobody's authority.
--
--  "May sleep when idle" IS specified and is still WRONG HERE. Sleep is
--  `petports_allowSleep` on the MONSTERTYPE: it is a property of the chassis, in
--  the same file as its collisionPoly and its search costs, and a player
--  checkbox over the top of it would be a second authority that the chassis
--  cannot see. A unit that is not built to sleep should not offer the option.
--
--  What is left describes DISPLAY, which is the right shape for this tab: both
--  remaining toggles change what the player sees and neither changes what the
--  unit does.
function settingToggled()
	tell("petports_setToggles", {
		carried = widget.getChecked("setCarried"),
		crosshairs = widget.getChecked("setCrosshairs")
	})
end

function portEnabledToggled()
	tell("petports_setPortEnabled", { enabled = widget.getChecked("portEnabled") })
end

--  THE WHOLE SET, NOT THE ONE THAT MOVED. The button is checkable, so the
--  click has already flipped it by the time this runs and reading all four back
--  is both simpler and self-correcting -- a box that somehow drifted from the
--  port is brought back into line by the next click on any of them.
--
--  FIRE AND FORGET. The port rewrites the mirror and the next poll repaints
--  these from what it actually stored, so a refused toggle moves the box back
--  on its own. Nothing here guesses at an outcome.
function groupToggled()
	local set = {}
	for _, group in ipairs(GROUPS) do
		set[group] = widget.getChecked(GROUP_WIDGET[group])
	end
	tell("petports_setParticipation", set)
end

--  ---------------------------------------------------------------------------

function init()
	dbg("build %s, port %s", PANE_BUILD_STAMP, tostring(portId()))
	widget.setText("buildStamp", PANE_BUILD_STAMP)

	for i = 1, BLIP_COUNT do
		blipShown[i] = nil
	end

	showTab("tabDetails")
	refresh(true)
end

function update(dt)
	pollTake()
	refresh(false)

	--  OUTSIDE THE SIGNATURE GATE, ON PURPOSE. See refresh: the portrait is a
	--  live view of a live entity and has to redraw whether or not the port's
	--  mirrored state changed.
	paintPreview(livePetId)
end

function uninit()
end
