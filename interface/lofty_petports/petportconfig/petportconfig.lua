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

--  EVERY VISIBLE STRING COMES FROM THE SHARED TABLE, not from this pane's
--  config. The config names a key beside each widget and declares "--" as its
--  value; petports_applyStrings resolves the keys at init and a key that does
--  not resolve leaves the dash showing. See petports_strings.config.
require "/scripts/lofty_petports/petports_strings.lua"

local DEBUG = true

--  Bump on every change to this file. A pane has no visible version and a stale
--  copy is indistinguishable from an unfixed one -- which cost a cycle on the
--  upcycler before the stamp existed.
local PANE_BUILD_STAMP = "2026-08-30e crew row"

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

--  Minutes of active time before the per-hour rate is worth showing. Below
--  this the division is honest arithmetic on a dishonest denominator -- one
--  crate emptied in the first forty seconds reads as thousands an hour. Six
--  minutes is a tenth of an hour, which is also the display precision of the
--  active line, so the two settle together.
local RATE_FLOOR_MINUTES = 6

--  Striping and separators for the stats list. The alt art is the family's
--  alternate shade at the list's 11px row height; clear is the do-nothing art
--  a separator row wears so the stripe rhythm visibly breaks at each block.
local STATS_ROW_ALT = "/interface/lofty_petports/shared/row_180_11_alt.png"
local STATS_ROW_CLEAR = "/interface/lofty_petports/shared/row_180_clear.png"

--  PLACEHOLDER SEPARATOR, BY REQUEST: a dashed rule in a dull yellow-orange so
--  it reads unmistakably as "separator, art pending" rather than as a stat
--  that failed to resolve. Real art replaces both of these later.
local STATS_SEPARATOR_TEXT = string.rep("-", 50)
local STATS_SEPARATOR_COLOR = { 184, 148, 64 }

--  WHAT THE TASK LABEL SAYS, KEYED ON THE PORT'S INTERNAL TASK TYPE.
--
--  The mirror carries `self.task.type` verbatim -- a dispatch identifier, not
--  copy. "drain" is meaningful to findWork and to nobody else.
--
--  TRANSLATED IN THE PANE, NOT AT THE SOURCE. The type is what the port logs,
--  what work ids are built from, and what every dispatch branch compares
--  against; renaming it there would be renaming an identifier to fix a caption.
--  This is a display concern and it lives with the display.
--
--  PHRASED AS WHAT THE UNIT IS DOING, present tense, because the label sits
--  under a portrait of the unit doing it. "Ready" rather than "Idle" -- idle
--  reads as a fault when a player is waiting for work to happen.
--
--  TWO TYPES ARE OVERLOADED AND THEIR LABELS HAVE TO STAY GENERIC.
--  `withdraw` covers seed withdrawal, water withdrawal AND restock fetch;
--  `deposit` covers ordinary deposit and restock delivery. Naming either one
--  specifically would be wrong most of the time. Splitting them needs a subtype
--  on the task, which is a change to dispatch rather than to this table.
local TASK_LABELS = {
	idle = "Ready",

	collect = "Collecting Items",
	deposit = "Storing Items",
	tidy = "Tidying Storage",
	compact = "Compacting Stacks",
	withdraw = "Fetching Supplies",

	harvest = "Harvesting Crops",
	replant = "Replanting",
	water = "Watering Crops",
	animal = "Tending Livestock",

	drain = "Emptying Upcycler",
	fuel = "Collecting Treats",
	upcycle = "Loading Upcycler",

	["return"] = "Returning to Port",

	--  Not player-facing work: the fallback drop task that DIAG_FALLBACK gates,
	--  which is false. Named anyway so that if it ever does dispatch, the pane
	--  says something rather than showing a bare identifier.
	diag = "Running Diagnostics"
}

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

--  THE SETTINGS LIST, DESCRIBED RATHER THAN DRAWN.
--
--  Each entry says what a row IS; buildSettingsRows turns the applicable ones
--  into list items. Adding a setting is an entry here plus a string key, with
--  no config edit and no geometry -- which is the whole reason this is a list.
--
--  `owner` NAMES THE MESSAGE, NOT THE STORAGE. Some of these end up on the port
--  and some on the pet, and that split is invisible to a player and should stay
--  that way. The pane's job is to send the right message; where the port files
--  it is the port's business.
--
--  `needs` IS A MODULE FLAG OR nil. nil means the chassis provides it and every
--  unit has it. A flag means the row exists only while that module is socketed
--  -- and only APPLIES while socketed, which the port enforces independently.
--
--  `sep` MARKS THE START OF A MODULE BLOCK. Each module's settings are preceded
--  by a divider so a player can see which module brought what.
local SETTING_ROWS = {
	{ key = "carried", owner = "toggles", needs = nil,
	  label = "petport.setting.carried", tip = "petport.tip.carried" },

	{ sep = true, needs = "medic", label = "petport.setting.medicblock" },

	{ key = "player", owner = "medic", needs = "medic",
	  label = "petport.setting.medicplayer", tip = "petport.tip.medicplayer" },
	{ key = "crew", owner = "medic", needs = "medic",
	  label = "petport.setting.mediccrew", tip = "petport.tip.mediccrew" },
	{ key = "npc", owner = "medic", needs = "medic",
	  label = "petport.setting.medicnpc", tip = "petport.tip.medicnpc" },
	{ key = "podpet", owner = "medic", needs = "medic",
	  label = "petport.setting.medicpodpet", tip = "petport.tip.medicpodpet" },
	{ key = "animal", owner = "medic", needs = "medic",
	  label = "petport.setting.medicanimal", tip = "petport.tip.medicanimal" },
	{ key = "unit", owner = "medic", needs = "medic",
	  label = "petport.setting.medicunit", tip = "petport.tip.medicunit" }
}

--  Which message carries each owner's set, and where the pane reads it back.
local SETTING_MESSAGE = {
	toggles = "petports_setToggles",
	medic = "petports_setMedic"
}

--  Row art. The 180 family at its native 16, not the stats list's regenerated
--  _11 -- a checkbox does not fit in eleven pixels.
local SETTINGS_ROW = "/interface/lofty_petports/shared/row_180.png"
local SETTINGS_ROW_ALT = "/interface/lofty_petports/shared/row_180_alt.png"
local SETTINGS_ROW_CLEAR = "/interface/lofty_petports/shared/row_180_clear.png"

--  PLACEHOLDER SEPARATOR, matching the stats list's: a dashed rule in a dull
--  yellow-orange so it reads as "divider, art pending" rather than as a setting
--  whose label failed to resolve.
local SETTINGS_SEPARATOR_TEXT = string.rep("-", 40)
local SETTINGS_SEPARATOR_COLOR = { 184, 148, 64 }


--  Widgets owned by each tab. Membership lives here rather than in the config
--  so showTab has exactly one list to be wrong about.
local TAB_MEMBERS = {
	tabDetails = {
		"detailsModulesLabel", "detailsModulesHint",
		"moduleSlot1", "moduleSlot2", "moduleSlot3", "moduleSlot4", "moduleSlot5",
		"detailsFlavorLabel", "detailsFlavorValue",
		"feedSlot", "feedHint",
		"detailsSerial"
	},

	--  RENAME LIVES HERE, NOT ON DETAILS. Details is a READOUT -- serial, flavor,
	--  modules, what the unit is. Renaming CHANGES the unit, which is what this
	--  tab is for, and it sat on Details only because that is where the serial it
	--  sits beside happens to be.
	tabSettings = {
		"renameButton",
		--  THE LIST IS ONE WIDGET NOW, where the pet toggles used to be several.
		--  Its ROWS are not members of anything -- they do not exist until
		--  paintSettings builds them.
		"settingsScroll"
	},
	tabStats = {
		--  ONE WIDGET, AND ITS VISIBILITY IS NOT THE ONLY GUARD. Whether
		--  setVisible on a scrollArea cascades to the list inside it is
		--  UNMEASURED, so paintStats also empties the list whenever the stats
		--  tab is not the active one -- an empty list draws nothing wherever
		--  visibility lands.
		"statsScroll"
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

--  "Fuel" OVER A DRONE, "Hunger" OVER AN ANIMAL.
--
--  The port mirrors the unit's bodyMaterialKind and this maps it to a key; the
--  wording itself is in the shared string table with everything else, so a
--  translator sees both variants side by side rather than one buried in Lua.
--
--  ORGANIC IS THE FALLBACK, INCLUDING FOR AN EMPTY PORT. The underlying
--  resource is vanilla's `hunger` whatever is socketed, so "Hunger" is the
--  honest word when there is nothing to ask -- and a port with no unit still
--  shows a bar frame that needs a caption.
--
--  A KEY THAT DOES NOT RESOLVE LEAVES THE DASH, exactly as the init sweep does.
--  This runs on the refresh path rather than at init, so it cannot use the
--  sweep, but it must not behave differently from it.
local function paintFuelLabel(bodyKind)
	local key = (bodyKind == "robotic") and "petport.fuel.robotic" or "petport.fuel.organic"
	local text = petports_string(key)

	if type(text) == "string" then
		widget.setText("fuelLabel", text)
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
		--  BOTH HALVES KEPT, not just the one the old string-return used. The
		--  tooltip layout has a title and a description, and `short` is exactly
		--  a title -- so the row that reads "Blocked" gains the sentence that
		--  says why underneath it.
		diagText[i] = d and { title = d.short or "Diagnostic", body = d.full or d.short } or nil
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

	--  QUANTISED TO A WHOLE NUMBER, AND THIS IS A RENDERING BUG FIX.
	--
	--  The fit lands on 3.917 for a 24x16 sprite in this 106x76 canvas --
	--  min((106-12)/24, (76-12)/16) -- and a fractional scale samples pixel art
	--  unevenly: some source columns are drawn three times and some four. Where
	--  a doubled column is the outline, which is (37,40,42) at luminance 39 and
	--  the most common colour in the sheet, the result reads as a black band.
	--
	--  IT LOOKS FRAME-DEPENDENT because WHICH source columns get doubled is
	--  fixed while the sprite content under them moves, so the band appears on
	--  the frames whose outline happens to fall there. That made it look like a
	--  sprite defect; it is not. All eight frames of the sheet are identical in
	--  their dark columns.
	--
	--  ROUNDED, NOT FLOORED, WITH A FIT CHECK. Flooring 3.917 gives 3 and
	--  shrinks the portrait by a quarter for no reason. 4 fits -- 24x4 = 96
	--  against a 106 canvas, 16x4 = 64 against 76 -- so it is both bigger than
	--  the fractional fit and crisp. It only eats into PORTRAIT_PAD, which is
	--  breathing room rather than a hard limit; the fallback to floor is what
	--  guards the real one, the canvas edge.
	local rounded = math.floor(scale + 0.5)
	if rounded * layout.w > size[1] or rounded * layout.h > size[2] then
		rounded = math.floor(scale)
	end
	scale = math.max(1, rounded)

	for _, it in ipairs(layout.items) do
		--  CENTRED, BECAUSE THE TRANSFORM CENTRES. tx and ty put the sprite on
		--  its own origin, so its centre is what the layout computed and
		--  centred = true is the matching draw. Anchoring every part on the
		--  UNION's centre is what keeps parts at different offsets framed as
		--  one thing instead of each being centred individually.
		--
		--  SNAPPED TO WHOLE PIXELS. An integer scale is only half of it: the
		--  offsets are computed from measured drawable centres and are
		--  fractional, so a part landing on x.5 is resampled across two
		--  destination pixels and blurs its own outline. Rounding here is what
		--  makes the quantised scale actually land on the pixel grid.
		local image = it.flip and (it.image .. "flipx") or it.image
		canvas:drawImage(image, {
				math.floor(centre[1] + (it.cx - layout.cx) * scale + 0.5),
				math.floor(centre[2] + (it.cy - layout.cy) * scale + 0.5)
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

--  CACHED AT MODULE LEVEL FOR THE SAME REASON paneModuleSlotCount IS: showTab
--  runs on a click, with no state in hand, and has to be able to re-apply a
--  conditional that refresh last computed. A local inside refresh cannot be
--  read from there.
--  WHAT THE LIST NEEDS THAT refresh's LOCAL `state` CANNOT PROVIDE. showTab runs
--  on a click with no state in hand, same reason paneModuleSlotCount exists.
--
--  paneModuleFlags IS A SET, NOT A LIST, because every lookup here asks "is this
--  flag present" and a list would make each row a linear scan.
local paneModuleFlags = {}
local paneSettings = {}
local paneHasUnit = false

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
--  Row path per list index, and what each index means. Rebuilt only when the
--  applicable set changes; the steady state repaints checked marks in place.
local settingsRowPaths = {}
local settingsRowKeys = {}
local settingsSignature = nil

--  WHICH ROWS APPLY TO THIS UNIT RIGHT NOW.
--
--  A row with `needs` survives only while that module flag is present. The port
--  enforces the same thing independently -- a stale checkbox cannot make a
--  desocketed module work -- so this is presentation, not permission.
local function applicableSettingRows()
	local out = {}

	for _, row in ipairs(SETTING_ROWS) do
		if row.needs == nil or paneModuleFlags[row.needs] then
			table.insert(out, row)
		end
	end

	return out
end

--  THE VALUE A ROW SHOULD SHOW, defaulting to ON when absent.
--
--  Matches the port: petportMedicTreats reads `~= false`, so a unit whose
--  settings table has never been written treats everybody. A module socketed
--  into an existing unit works immediately rather than looking broken until
--  every box is ticked.
local function settingValue(row)
	local store = paneSettings[row.owner] or {}
	return store[row.key] ~= false
end

--  REBUILT ONLY WHEN THE SET CHANGES, repainted otherwise.
--
--  clearListItems invokes the list's own callback -- measured on the beacon
--  panes -- so a rebuild on every poll would have the repaint firing the thing
--  that asked for it. The signature is the applicable rows, not their values.
local function paintSettings()
	local showing = (activeTab == "tabSettings")
	widget.setVisible("settingsScroll", showing and paneHasUnit)

	if not showing or not paneHasUnit then return end

	local rows = applicableSettingRows()

	local names = {}
	for _, row in ipairs(rows) do table.insert(names, row.label) end
	local signature = table.concat(names, "|")

	if signature ~= settingsSignature then
		settingsSignature = signature
		widget.clearListItems("settingsScroll.settingsList")
		settingsRowPaths = {}
		settingsRowKeys = {}

		--  PARITY RESETS AT EACH SEPARATOR so every module's block starts on
		--  the base shade, exactly as the stats list does.
		local stripe = false

		for i, row in ipairs(rows) do
			local rowId = widget.addListItem("settingsScroll.settingsList")
			local rowPath = "settingsScroll.settingsList." .. rowId

			settingsRowPaths[i] = rowPath
			settingsRowKeys[i] = row

			if row.sep then
				stripe = false
				widget.setImage(rowPath .. ".rowBG", SETTINGS_ROW_CLEAR)
				widget.setText(rowPath .. ".settingLabel", SETTINGS_SEPARATOR_TEXT)
				widget.setFontColor(rowPath .. ".settingLabel", SETTINGS_SEPARATOR_COLOR)

				--  A DIVIDER IS NOT A CONTROL. Both interactive widgets go away
				--  rather than being left checked and inert, which would invite
				--  a click that does nothing.
				widget.setVisible(rowPath .. ".settingCheck", false)
				widget.setVisible(rowPath .. ".rowButton", false)
			else
				widget.setImage(rowPath .. ".rowBG",
					stripe and SETTINGS_ROW_ALT or SETTINGS_ROW)
				stripe = not stripe

				widget.setText(rowPath .. ".settingLabel", petports_stringOr(row.label, "--"))
				widget.setVisible(rowPath .. ".settingCheck", true)
				widget.setVisible(rowPath .. ".rowButton", true)

				--  THE ROW INDEX, ON BOTH INTERACTIVE WIDGETS. A member callback
				--  gets the leaf name -- identical for every row -- so only the
				--  widget data can say which row fired.
				widget.setData(rowPath .. ".settingCheck", i)
				widget.setData(rowPath .. ".rowButton", i)
			end
		end
	end

	--  THE STEADY STATE TOUCHES CHECKED MARKS ONLY.
	for i, row in ipairs(rows) do
		if not row.sep and settingsRowPaths[i] ~= nil then
			widget.setChecked(settingsRowPaths[i] .. ".settingCheck", settingValue(row))
		end
	end
end

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
	--  FLAGS AS A SET, and the mirror sends a list. Built here once rather than
	--  in applicableSettingRows, which runs per paint.
	paneModuleFlags = {}
	for _, flag in ipairs(state.moduleFlags or {}) do
		paneModuleFlags[flag] = true
	end

	paneSettings = {
		toggles = state.toggles or {},
		medic = state.medic or {}
	}

	--  state.hasUnit, NOT hasUnit. This block lives in paintModules, which takes
	--  `state` -- the bare local belongs to refresh and is not in scope here, so
	--  it read as nil and paintSettings hid the list on every paint. The list
	--  never appeared once.
	paneHasUnit = state.hasUnit == true

	paintSettings()

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

--  1,234,567 rather than 1234567. The engine offers no locale formatting and
--  the totals here are the one place in the pane a number can grow past four
--  digits.
local function groupDigits(value)
	local text = tostring(math.floor(tonumber(value) or 0))

	while true do
		local replaced
		text, replaced = string.gsub(text, "^(%d+)(%d%d%d)", "%1,%2")
		if replaced == 0 then break end
	end

	return text
end

--  THE MIRROR CARRIES NUMBERS AND THIS TURNS THEM INTO SENTENCES -- the same
--  split as bodyKind: the port does not know the wording, and the rate is
--  derived HERE so the mirror never carries a value that two fields could
--  disagree about.
--
--  RATES ARE SHOWN, TOTALS ARE STORED (dd.pane.ratesnottotals). The total is
--  painted too, because "4,120 items" next to "over 3.2 h active" is the pair
--  that means something; either alone is a number without a scale.
--
--  THE RATE LINE IS ABSENT, NOT ZERO, UNTIL THE CLOCK HAS RUN. See
--  RATE_FLOOR_MINUTES. An absent line is a readout that has nothing to say
--  yet; a wild early rate is a readout lying confidently.
--
--  activeMinutes ARRIVES PRE-QUANTIZED -- the port floors it to whole minutes
--  so the mirror signature is not churned by the one field that moves every
--  tick. Under an hour it is painted as minutes; from an hour up, as hours to
--  one decimal, which RATE_FLOOR_MINUTES matches by construction.
--
--  A LIST NOW, NOT EIGHT LABELS, because the metric set outgrew the positions
--  and per-treat counters will have no fixed count at all. THE STROBE
--  HYPOTHESIS THIS TESTS: addListItem repaints the whole container (measured
--  -- the beacon panes live with it), but setText on an EXISTING row may not.
--  So rows are rebuilt ONLY when the line count changes -- once at minute six
--  when the rate appears, and on tab entry -- and every other refresh touches
--  text alone. If the tab strobes on refresh anyway, the hypothesis is dead
--  and the eight labels come back from git.
--
--  POPULATED ONLY WHILE ITS TAB IS ACTIVE, cleared otherwise. This is the
--  belt to setVisible's braces: whether hiding a scrollArea hides the list
--  inside it is unmeasured, and an empty list draws nothing either way. The
--  rebuild this costs on each visit to the tab coincides with the repaint the
--  tab click already causes.
local statsRowPaths = {}

local function paintStats(stats)
	if activeTab ~= "tabStats" or type(stats) ~= "table" then
		if #statsRowPaths > 0 then
			widget.clearListItems("statsScroll.statsList")
			statsRowPaths = {}
		end
		return
	end

	local minutes = tonumber(stats.activeMinutes) or 0
	local moved = tonumber(stats.moved) or 0

	--  DENSE, IN DISPLAY ORDER, entries rather than bare strings so a
	--  separator can carry its flag. The list draws top-down in insertion
	--  order. The haul block, the farm block, then the odometer-and-affection
	--  block; treats-per-type will append as its own block when eating exists.
	local lines = {}

	local function addLine(text)
		table.insert(lines, { text = text })
	end

	local function addSeparator()
		table.insert(lines, { text = STATS_SEPARATOR_TEXT, sep = true })
	end

	addLine(petports_format("petport.stats.moved", groupDigits(moved)))

	if minutes >= RATE_FLOOR_MINUTES then
		local perHour = math.floor(moved / (minutes / 60) + 0.5)
		addLine(petports_format("petport.stats.rate", groupDigits(perHour)))
	end

	local duration
	if minutes < 60 then
		duration = petports_format("petport.stats.activeminutes", tostring(minutes))
	else
		duration = petports_format("petport.stats.activehours",
			string.format("%.1f", minutes / 60))
	end
	addLine(petports_format("petport.stats.active", duration))

	addSeparator()
	addLine(petports_format("petport.stats.planted", groupDigits(stats.planted)))
	addLine(petports_format("petport.stats.watered", groupDigits(stats.watered)))
	addLine(petports_format("petport.stats.harvested", groupDigits(stats.harvested)))
	addLine(petports_format("petport.stats.livestock", groupDigits(stats.livestock)))

	addSeparator()
	addLine(petports_format("petport.stats.traveled", groupDigits(stats.traveled)))
	addLine(petports_format("petport.stats.headpats", groupDigits(stats.headpats)))

	--  REBUILD ONLY ON A COUNT CHANGE; see the header. clearListItems fires
	--  the list's own callback mid-rebuild -- measured on the beacon panes --
	--  which is why statsRowSelected below must tolerate being called with the
	--  list in any state.
	--
	--  STRIPES AND SEPARATOR DRESSING ARE SET HERE AND ONLY HERE, because a
	--  rebuild is the one moment a repaint is already being paid for -- the
	--  strobe hypothesis says setText alone is what keeps the steady state
	--  calm, so the steady-state loop below touches nothing but text. Safe
	--  because row meanings cannot change without the count changing: the only
	--  line that comes and goes is the rate, and its arrival IS a count change.
	--
	--  PARITY RESETS AT EACH SEPARATOR, so every block starts on the base
	--  shade and the alternation reads as belonging to its block. A separator
	--  wears the clear art -- the visible break in the stripe rhythm is half
	--  of what makes it read as a divider.
	if #lines ~= #statsRowPaths then
		widget.clearListItems("statsScroll.statsList")
		statsRowPaths = {}

		local stripe = false

		for i = 1, #lines do
			local rowId = widget.addListItem("statsScroll.statsList")
			local rowPath = "statsScroll.statsList." .. rowId
			statsRowPaths[i] = rowPath .. ".statText"

			if lines[i].sep then
				stripe = false
				widget.setImage(rowPath .. ".rowBG", STATS_ROW_CLEAR)
				widget.setFontColor(statsRowPaths[i], STATS_SEPARATOR_COLOR)
			else
				if stripe then
					widget.setImage(rowPath .. ".rowBG", STATS_ROW_ALT)
				end
				stripe = not stripe
			end
		end
	end

	for i = 1, #lines do
		widget.setText(statsRowPaths[i], lines[i].text)
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
	paintSettings()

	dbg("tab -> %s", which)
end

--  ---------------------------------------------------------------------------
--  THE POLL
--  ---------------------------------------------------------------------------

local lastSignature = nil

--  The entity id of the unit as of the last mirror read, or nil when nothing is
--  spawned. update paints from this; refresh only sets it.
local livePetId = nil

--  EVERYTHING THE PANE SHOWS ABOUT A UNIT, PUT BACK TO EMPTY.
--
--  THERE WERE TWO OF THESE AND NEITHER WAS COMPLETE. refresh had one reset for
--  `state == nil` and a second for `hasUnit == false`, and they cleared
--  different things: the first painted the fuel bar down and blanked the task
--  line, the second did not, and NEITHER touched the cargo slot, the
--  diagnostics, the serial, the flavor, the stats lines or the module slots. A
--  port emptied while its pane was open kept showing the departed unit's
--  readout.
--
--  THE MODULE SLOTS ARE THE PART THAT MATTERED. paintModuleSlots leaves a
--  hidden slot's CONTENTS alone on purpose -- its comment says paneModules is
--  the authority and gets rewritten before the slot is shown again -- and that
--  is true on every path except this one, which returned before reaching it.
--
--  CLEARED, NOT JUST HIDDEN. A hidden slot holding a real item descriptor is
--  one tab switch away from being a slot the player can click.
local function showEmpty()
	livePetId = nil
	paneModules = {}
	paneModuleSlotCount = 0

	paneModuleFlags = {}
	paneSettings = {}
	paneHasUnit = false
	settingsSignature = nil
	moduleWriteToken = nil

	widget.setText("petName", petports_stringOr("petport.nounit"))
	widget.setText("petSpecies", "")
	widget.setText("taskLabel", "")
	widget.setText("diagLabel", "")
	widget.setText("detailsSerial", "")
	widget.setText("detailsFlavorValue", "--")

	for i = 1, DIAG_SLOTS do
		diagText[i] = nil
		widget.setVisible("diag" .. i, false)
	end

	--  Through paintStats rather than a loop of its own, so the empty path and
	--  the tab-switch path clear the list the same one way.
	paintStats(nil)

	for i = 1, MODULE_SLOTS do
		widget.setItemSlotItem("moduleSlot" .. i, nil)
		widget.setVisible("moduleSlot" .. i, false)
	end

	paintFuel(0)
	paintCargo(nil)

	setVisibleAll(PET_COLUMN, false)
	setVisibleAll(TAB_MEMBERS[activeTab], false)
end

local function refresh(force)
	local state = readState()

	if state == nil then
		showEmpty()
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
	widget.setChecked("portCrosshairs", state.crosshairs ~= false)
	widget.setText("portNetworkLabel", "id: " .. tostring(state.network or "--"))

	--  ABSENT MEANS PARTICIPATING, matching the port's own reader. A mirror from
	--  a port that predates this field must not paint four empty boxes and tell
	--  the player their unit has been opted out of everything.
	local participation = state.participation or {}
	for _, group in ipairs(GROUPS) do
		widget.setChecked(GROUP_WIDGET[group], participation[group] ~= false)
	end

	if not hasUnit then
		showEmpty()
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
	paintFuelLabel(state.bodyKind)
	paintCargo(state.cargo)

	--  UNMAPPED FALLS BACK TO THE RAW TYPE, deliberately. A task type added to
	--  dispatch without a line in TASK_LABELS then reads as an untranslated
	--  identifier -- odd-looking and traceable -- rather than as blank, which
	--  would read as a unit with nothing to do.
	local task = state.task
	widget.setText("taskLabel", task and (TASK_LABELS[task] or task) or "")
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

--  THE LIST'S REQUIRED CALLBACK, AND A DELIBERATE NO-OP. Selection means
--  nothing on a readout, and the engine offers no way to refuse it --
--  setListSelected(list, nil) throws -- so the selection is simply invisible:
--  both schema BGs are the clear row art and this does nothing. It must also
--  TOLERATE ANY LIST STATE, because clearListItems invokes it mid-rebuild.
function statsRowSelected()
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
--  ---------------------------------------------------------------------------
--  THE HOVER LAYER
--  ---------------------------------------------------------------------------
--
--  THIS PANE DRAWS ITS OWN TOOLTIPS, AND createTooltip IS GONE BECAUSE IT WAS
--  NEVER CALLED.
--
--  MEASURED, TWICE, AFTER TWO WRONG FIXES. The first attempt guessed at the hit
--  test; the second found the pane declared no `tooltipLayout` and fixed that.
--  Neither mattered. A ContainerPane does not forward createTooltip to its
--  script at all: the beacon panes open with interactAction "ScriptPane" and
--  their tooltips work, while this pane and the upcycler open through uiConfig
--  and produce none. The only tooltips either ContainerPane shows are the item
--  ones ItemSlotWidget draws for itself, which is why the upcycler's rule slot
--  looked like a working counter-example.
--
--  AND THERE IS NO WIDGET-LEVEL FIELD TO FALL BACK ON -- a grep of the whole
--  asset tree finds tooltip text only in .tooltip templates, never as a widget
--  property. createTooltip was the only engine route and it is closed here.
--
--  SO: TRACK THE CURSOR ON A CANVAS AND DRAW IT. Same technique
--  /interface/easel/signstoregui.lua uses for its entire interface.
--
--  TWO CANVASES, AND THE SPLIT IS MEASURED RATHER THAN CHOSEN. A single
--  full-pane canvas on TOP worked for hovering and killed every ITEM tooltip in
--  the pane -- the socket and the module slots went dead. captureMouseEvents was
--  already false, so capture is not what does it; being on top is. The sign
--  store puts its dispenser in a separate container with a separate UI, which
--  reads less like a design choice once you have seen this.
--
--  hoverCanvas is BENEATH EVERYTHING, including the background, and is never
--  drawn on. It reports the cursor and occludes nothing, because nothing is
--  under it. tipCanvas is small, topmost and hidden until there is something to
--  say. Both verified in game.

--  THE CANVAS IS A FIXED 150x80; THE BOX DRAWN INSIDE IT IS NOT.
--
--  A canvas can be moved but not resized, so tipCanvas is declared at the size
--  of the LARGEST tooltip and the visible box is drawn to fit its own text
--  inside that. The unused remainder is transparent -- it costs a little extra
--  occlusion while a tooltip is up, and nothing else.
--
--  THE FIRST VERSION FILLED THE WHOLE CANVAS and every tooltip came out around
--  twice as tall as its text. That was not a measurement problem; the estimate
--  below was already right. It was drawing the container instead of the
--  contents.
--
--  DRAWN FROM THE CANVAS ORIGIN, which is bottom-left, so the box sits at the
--  bottom of the canvas and lands where the cursor offset puts it. The slack is
--  above, out of the way.
local TIP_W = 150
local TIP_H = 80
local TIP_PAD = 5

--  Wrap width for the body, inside the padding.
local TIP_WRAP = TIP_W - TIP_PAD * 2

--  THE PANE'S DRAWABLE WIDTH, taken from the background art rather than
--  guessed: panetall_body.png is 337 wide. A canvas that crosses it is clipped
--  by the pane, which is measured -- see the placement note in paintHover.
local TIP_PANE_W = 337

--  KEEP-OFF FROM THAT EDGE. Two pixels, because landing exactly on 337 clipped.
local TIP_MARGIN = 2

--  THE ONLY AUTHORED SPACING LEFT, AND IT IS A GAP RATHER THAN A SIZE.
--
--  TIP_LINE, TIP_TITLE_H and TIP_CHAR_W are all gone: they were estimates of
--  how tall rendered text IS, and a label reports that exactly -- see
--  tipMetrics. This is the space BETWEEN the two blocks, which is a spacing
--  choice and does not vary with the script the text is written in.
local TIP_GAP = 4

--  WHY THE ESTIMATE HAD TO GO, AND IT IS NOT ONLY A TRANSLATION PROBLEM.
--
--  MEASURED, four English bodies at a 140px wrap, chars divided by real lines:
--  3.89, 4.44, 5.53, 5.53 px per character. TIP_CHAR_W was 4.3 and could not
--  have been right, because WRAPPING BREAKS ON WORD BOUNDARIES and a character
--  count does not predict where those fall. The Machines body was estimated at
--  four lines and renders in three, which is the extra margin under it.
--
--  A translated string makes it worse rather than differently wrong -- a CJK
--  glyph is roughly twice a Latin one, so the error becomes a factor and it
--  clips instead of running long -- but the estimate was already unfixable in
--  the language it was fitted to.

--  FULLY OPAQUE. At alpha 235 the widgets behind the box read straight through
--  it -- the participation labels were legible under the text.
local TIP_BG = { 22, 24, 29, 255 }
local TIP_EDGE = { 74, 82, 92, 255 }
local TIP_TITLE_COLOR = { 220, 226, 234, 255 }
local TIP_BODY_COLOR = { 150, 156, 164, 255 }

local hoverCanvas = nil
local tipCanvas = nil
local tipShowing = false

--  Widget name -> hit rect, read off the widget itself rather than transcribed.
local hoverRects = {}

--  Widget name -> { title = , body = }, RESOLVED AT INIT FROM THE SHARED TABLE.
--
--  A tooltip is a property of the widget it describes, so the widget names its
--  key as `petportsTip` in this pane's config and the text itself lives in
--  petports_strings.config with every other string in the mod. Adding one is a
--  key in each file and no Lua at all -- which is the whole question this
--  answers: no per-widget canvas is needed, because one movable canvas serves
--  every marked widget.
--
--  DYNAMIC TIPS STILL COME FROM CODE. The diagnostics say different things at
--  different times; only their existence is static, so they are not swept.
local staticTips = {}

local function sweepTips()
	staticTips = petports_sweepTips()
end

local function hoverRect(name)
	if hoverRects[name] ~= nil then return hoverRects[name] end

	local okPos, pos = pcall(widget.getPosition, name)
	local okSize, size = pcall(widget.getSize, name)

	if not okPos or not okSize or type(pos) ~= "table" or type(size) ~= "table" then
		return nil
	end

	hoverRects[name] = { pos[1], pos[2], pos[1] + size[1], pos[2] + size[2] }
	return hoverRects[name]
end

local function within(rect, at)
	return rect ~= nil
		and at[1] >= rect[1] and at[1] <= rect[3]
		and at[2] >= rect[2] and at[2] <= rect[4]
end

--  WHAT IS UNDER THE CURSOR, OR NOTHING.
--
--  Diagnostics first and from code, because a hidden icon has no entry in
--  diagText and must not claim a hover even though its widget still has a
--  position. Then the swept ones, which carry their own text.
--
--  THE RECT COMES BACK TOO, because the box is anchored to the WIDGET and not
--  to the pointer -- see the placement note in paintHover.
local function hoverTarget(at)
	for i = 1, DIAG_SLOTS do
		local entry = diagText[i]
		local rect = hoverRect("diag" .. i)
		if entry ~= nil and within(rect, at) then
			return entry.title, entry.body, rect
		end
	end

	for name, tip in pairs(staticTips) do
		local rect = hoverRect(name)
		if within(rect, at) then
			return tip.title, tip.body, rect
		end
	end

	return nil
end

--  HIDDEN AND MOVED, RATHER THAN CLEARED IN PLACE.
--
--  A canvas occludes what is under it whether or not anything is drawn on it --
--  that is what killed every item tooltip in the pane last build. So the drawing
--  canvas is only visible while a tooltip is up, and only ever covers the patch
--  the tooltip itself covers.
local function hideTip()
	if not tipShowing then return end
	tipShowing = false
	pcall(widget.setVisible, "tipCanvas", false)
end

--  ---- text measurement -------------------------------------------------------
--
--  THE BOX IS SIZED FROM WHAT THE TEXT ACTUALLY MEASURES, not from an estimate
--  of it. A canvas cannot measure text -- drawText returns void and there is no
--  measure call -- but a LABEL reports the size of the text it laid out, and
--  widget.getSize hands that back.
--
--  MEASURED, in the probe build that established it. Four bodies at a 140px
--  wrap returned 133x25, 137x16, 127x25 and 139x25 -- widths that vary with the
--  string and heights that fit 7 + (n - 1) * 9 exactly. So:
--
--    A label reports real text bounds, not the nothing it was configured with.
--    A HIDDEN label lays out. The visible alpha-zero twin returned identical
--      numbers on all four, so it is gone and this one stays invisible.
--    There is NO FRAME LAG. Hover order was Farming, Item Pickup, Sorting,
--      Machines; a lag of one would have given Item Pickup the 25 belonging to
--      Farming, and it returned its own 16.
--
--  TWO LABELS, ONE PER FONT SIZE. The body wraps at fontSize 7 and the title is
--  a single unwrapped line at 8. Measuring only the body would leave the title
--  as an authored English constant, which is half a fix.
--
--  THE BODY IS MEASURED WITH COLOUR CODES STRIPPED, deliberately. `^green;` is
--  seven bytes and zero pixels in both renderers, so either string should
--  measure the same -- but the stripped one is what the probe was verified
--  against, and it cannot go wrong if a label and a canvas ever disagree about
--  escapes.
--
--  CACHED PER STRING. paintHover runs every update for as long as the cursor
--  sits still, and a setText plus a getSize per frame is a write and a layout
--  for an answer that cannot have changed.
local tipMetricCache = {}

--  IF MEASUREMENT FAILS, DRAW THE WHOLE CANVAS.
--
--  The fallback is deliberately NOT a re-derived estimate. An estimate is the
--  thing this replaced, and a per-language constant buried in a fallback path is
--  worse than no fallback at all, because it only ever runs where nobody is
--  looking. A full-height box is roomy, cannot clip, and is obvious on screen.
local measureFailLogged = false

local function tipMetrics(title, body)
	local key = tostring(title) .. "\1" .. tostring(body)
	local cached = tipMetricCache[key]
	if cached ~= nil then return cached[1], cached[2] end

	local function measure(name, text)
		local ok, size = pcall(function()
			widget.setText(name, text)
			return widget.getSize(name)
		end)

		if not ok or type(size) ~= "table" or type(size[2]) ~= "number" then return nil end
		if size[2] <= 0 then return nil end
		return size[2], size[1]
	end

	local titleH = measure("tipMeasureTitle", title or "")
	local bodyH, bodyW = measure("tipMeasure", body or "")

	if titleH == nil or bodyH == nil then
		if not measureFailLogged then
			measureFailLogged = true
			dbg("MEASURE FAILED (title %s, body %s) -- tooltips fall back to the full %d px box",
				tostring(titleH), tostring(bodyH), TIP_H)
		end
		return nil, nil
	end

	dbg("measure: title %d high, body %s x %d -- %s", titleH, tostring(bodyW), bodyH, body or "")

	tipMetricCache[key] = { titleH, bodyH }
	return titleH, bodyH
end

local function paintHover()
	if hoverCanvas == nil then
		local ok, bound = pcall(widget.bindCanvas, "hoverCanvas")
		if not ok or bound == nil then
			dbg("bindCanvas hoverCanvas FAILED -- no hover tracking this session")
			return
		end
		hoverCanvas = bound
	end

	local ok, at = pcall(function() return hoverCanvas:mousePosition() end)

	if not ok or type(at) ~= "table" then
		hideTip()
		return
	end

	local title, body, rect = hoverTarget(at)

	if title == nil then
		hideTip()
		return
	end

	if tipCanvas == nil then
		local okBind, bound = pcall(widget.bindCanvas, "tipCanvas")
		if not okBind or bound == nil then
			dbg("bindCanvas tipCanvas FAILED -- nothing can be drawn")
			return
		end
		tipCanvas = bound
	end

	--  COLOUR CODES ARE NOT TEXT. `^green;` and `^reset;` are fourteen bytes of
	--  the Machines body and zero pixels of it, in the label that measures it
	--  and in the canvas that draws it alike.
	local visible = string.gsub(body or "", "%^%a+;", "")

	local titleH, bodyH = tipMetrics(title, visible)
	local w = TIP_W
	local h

	if titleH == nil then
		--  Measurement is unavailable. Take the whole canvas rather than guess.
		h = TIP_H
		titleH = 9
	else
		h = TIP_PAD * 2 + titleH + TIP_GAP + bodyH
	end

	--  LOUD WHEN IT CLIPS, because the canvas cannot be resized at runtime and
	--  80px is therefore a hard ceiling. The first tooltip written long enough
	--  to hit it would otherwise just lose its last line, on screen, silently.
	if h > TIP_H then
		dbg("TOOLTIP CLIPS: needs %d px, canvas is %d -- last line(s) lost: %s",
			h, TIP_H, body or "")
		h = TIP_H
	end

	--  ANCHORED TO THE WIDGET, NOT TO THE POINTER.
	--
	--  The box's TOP-LEFT sits on the hovered widget's TOP-RIGHT corner, so it
	--  opens down and to the right and never covers the thing being hovered --
	--  which a checkbox 9px on a side cannot afford.
	--
	--  WHY NOT THE CURSOR: the pointer moves inside a widget and the box moved
	--  with it, and the two clamps then pinned it. Every participation tooltip
	--  shared a bottom edge at y 240 and both right-hand ones shared a right
	--  edge flush with the pane, which read as the UI shoving them around. It
	--  was this arithmetic. Anchoring to the widget makes the position a
	--  property of what is hovered, so it does not move at all while hovering.
	--
	--  IT FLIPS ACROSS THE WIDGET, IT DOES NOT SLIDE ALONG THE EDGE.
	--
	--  MEASURED: a pane DOES clip a canvas that overhangs its bounds, and all
	--  four participation tooltips were cut -- not just the two on the right.
	--  The pane art is 337 wide, and the left pair anchors at x 187, so the box
	--  reached exactly 337 and lost its edge. Flush with the boundary is already
	--  too far.
	--
	--  SO: right of the widget when there is room, left of it when there is not.
	--  Sliding it back along the edge instead is what parked it on top of the
	--  checkbox in the first place, and a 9px checkbox cannot spare the cover.
	--
	--  TIP_MARGIN IS A KEEP-OFF, NOT A FUDGE. Landing exactly on 337 is what
	--  clipped, so the test has to reject the boundary rather than allow it.
	--
	--  IF NEITHER SIDE FITS, RIGHT WINS. That needs a box wider than the pane
	--  and cannot happen at 150 against 337, but a silent negative x would draw
	--  the tooltip off the left edge and look identical to this bug.
	local x = rect[3]

	if x + TIP_W > TIP_PANE_W - TIP_MARGIN then
		local flipped = rect[1] - TIP_W
		if flipped >= TIP_MARGIN then x = flipped end
	end

	--  The box is drawn from the canvas origin, which is BOTTOM-left, so the
	--  canvas y that puts the box's top on the widget's top is that minus h.
	--
	--  THE FLOOR IS SAFE HERE in a way the old x clamp was not: the box is
	--  always beside the widget, never over it, so pushing it up off the bottom
	--  edge cannot hide what is being hovered.
	local y = math.max(rect[4] - h, 0)

	pcall(widget.setPosition, "tipCanvas", { x, y })

	if not tipShowing then
		tipShowing = true
		pcall(widget.setVisible, "tipCanvas", true)
	end

	tipCanvas:clear()
	tipCanvas:drawRect({ 0, 0, w, h }, TIP_BG)
	tipCanvas:drawRect({ 0, 0, w, 1 }, TIP_EDGE)
	tipCanvas:drawRect({ 0, h - 1, w, h }, TIP_EDGE)
	tipCanvas:drawRect({ 0, 0, 1, h }, TIP_EDGE)
	tipCanvas:drawRect({ w - 1, 0, w, h }, TIP_EDGE)

	--  ANCHORED TOP AND LAID OUT DOWNWARD, WHICH MAKES AN OVERLAP STRUCTURALLY
	--  IMPOSSIBLE RATHER THAN MERELY UNLIKELY.
	--
	--  MEASURED, in game: a BOTTOM-anchored wrapped block puts the bottom of the
	--  WHOLE BLOCK at the position and grows UPWARD from it. The previous version
	--  assumed the opposite -- first line at the position, stacking down -- and
	--  back-offset the body by (lines - 1) lines to land its last line on the
	--  padding. Under that assumption the title's bottom sits exactly 4px above
	--  the body's top for every line count, so an overlap could never happen.
	--  One happened, which is what falsifies it: the four-line Machines body ran
	--  to y 68 against a title bottom at 45. It was overlapping before the box
	--  was resized too; the taller canvas put the title at 66 where it read as a
	--  near miss instead of a collision.
	--
	--  WHY TOP RATHER THAN CORRECTED ARITHMETIC. Bottom-anchoring can be made to
	--  work by placing the title's bottom at the top of the body block, but that
	--  puts the body's HEIGHT into the position of the title as well as into the
	--  height of the box, so one bad number moves two things. Anchoring top
	--  positions both blocks from the top edge and lets the height decide only
	--  how tall the box is.
	--
	--  THAT MATTERED MORE WHEN THE HEIGHT WAS A GUESS and it is still the right
	--  shape now that it is measured, because the fallback path still runs on an
	--  authored number when measurement fails.
	--
	--  The exact case reads: body bottom lands on TIP_PAD, because h is
	--  TIP_PAD * 2 + titleH + TIP_GAP + bodyH by construction.
	tipCanvas:drawText(title, {
		position = { TIP_PAD, h - TIP_PAD },
		horizontalAnchor = "left",
		verticalAnchor = "top"
	}, 8, TIP_TITLE_COLOR)

	tipCanvas:drawText(body or "", {
		position = { TIP_PAD, h - TIP_PAD - titleH - TIP_GAP },
		horizontalAnchor = "left",
		verticalAnchor = "top",
		wrapWidth = TIP_WRAP
	}, 7, TIP_BODY_COLOR)
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
--  settingToggled IS GONE. The pet toggles moved into settingsList, so the one
--  fixed checkbox that used to live on this tab is now a row like any other and
--  settingsRowClicked sends its message.

--  CLAIM MARKERS. A PORT SETTING, so it sits in the port band and writes its
--  own message rather than riding along with the pet toggles.
--
--  Fire and forget, like the other two in that band: the port rewrites the
--  mirror and the next poll repaints this from what it actually stored, so a
--  refused toggle moves the box back on its own.
function portCrosshairsToggled()
	tell("petports_setCrosshairs", { enabled = widget.getChecked("portCrosshairs") })
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
--  ONE CALLBACK FOR THE WHOLE LIST, registered at runtime -- see init.
--
--  BOTH THE BOX AND THE ROW LAND HERE. The box is checkable so a click on it has
--  already flipped it; the row button is not, so a click on the row has to flip
--  the box itself. `from` distinguishes them, and it is the leaf name the engine
--  passes as arg 1 -- the only thing that differs between the two widgets, since
--  the row index arrives identically in arg 2.
function settingsRowClicked(from, index)
	local i = tonumber(index)
	if i == nil then return end

	local row = settingsRowKeys[i]
	local path = settingsRowPaths[i]
	if row == nil or row.sep or path == nil then return end

	if from ~= "settingCheck" then
		widget.setChecked(path .. ".settingCheck",
			not widget.getChecked(path .. ".settingCheck"))
	end

	--  THE WHOLE SET FOR THAT OWNER, NOT THE ONE THAT MOVED -- same reasoning as
	--  groupToggled. Reading every row back is self-correcting: a box that
	--  somehow drifted from the port is brought back into line by the next click
	--  on any row sharing its owner.
	--
	--  FIRE AND FORGET. The port rewrites the mirror and the next poll repaints
	--  from what it actually stored, so a refused toggle moves the box back.
	local set = {}
	for j, other in ipairs(settingsRowKeys) do
		if not other.sep and other.owner == row.owner and settingsRowPaths[j] ~= nil then
			set[other.key] = widget.getChecked(settingsRowPaths[j] .. ".settingCheck")
		end
	end

	tell(SETTING_MESSAGE[row.owner], set)
end

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

	--  ONCE, AT INIT, BOTH OF THEM. The gui table does not change and neither
	--  does the string table, so walking sixty widgets every poll to find the
	--  marked ones would be work with no possible new answer.
	--
	--  STRINGS BEFORE TABS. showTab hides most of the pane, and a hidden widget
	--  is still a widget as far as setText is concerned -- but running the sweep
	--  first means the log reports the whole pane's strings rather than only the
	--  tab that happens to open first.
	petports_applyStrings()
	sweepTips()

	--  ROW CALLBACKS, REGISTERED BEFORE ANY ROW EXISTS.
	--
	--  MUST happen before the first addListItem and MUST NOT appear in
	--  scriptWidgetCallbacks. ListWidget parses its template with a parser that
	--  has never heard of pane-level callbacks, so a row naming one throws
	--  inside addListItem -- at CONSTRUCTION, taking the whole pane down rather
	--  than failing at click. The pre-flight cannot catch this: from its side an
	--  unregistered row callback looks exactly like a correctly absent one.
	--
	--  BOTH ROW WIDGETS SHARE ONE HANDLER. The box carries the tooltip and the
	--  row carries the hover; which one fired is arg 1.
	widget.registerMemberCallback("settingsScroll.settingsList",
		"settingsRowClicked", settingsRowClicked)

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

	--  Also outside it, and for a stronger reason: the cursor moves without the
	--  port's state changing at all.
	paintHover()
end

function uninit()
end
