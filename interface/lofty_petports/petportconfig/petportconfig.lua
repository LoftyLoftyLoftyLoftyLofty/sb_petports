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

--  THE MODULE RULES THE PORT ALSO LOADS. The swap is performed here and only
--  committed there, so any rule this pane applies to a swap has to be the same
--  object the port applies to the payload -- see the file's own header.
require "/scripts/lofty_petports/petports_modules.lua"

local DEBUG = true

--  Bump on every change to this file. A pane has no visible version and a stale
--  copy is indistinguishable from an unfixed one -- which cost a cycle on the
--  upcycler before the stamp existed.
local PANE_BUILD_STAMP = "2026-09-03p the name field lets go too"

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
--  FARMING LEFT THIS LIST ON 2026-08-30. It became a module and its four
--  activities are rows in the settings list, stored on petData -- see
--  SETTING_ROWS. Three port groups remain.
local GROUPS = { "hauling", "sorting", "machines" }

--  Widget name per group. Derived rather than tabulated would mean
--  "group" .. "hauling" and a capitalisation rule; two of these are wanted as
--  strings anyway, for the tooltip lookup.
local GROUP_WIDGET = {
	hauling = "groupHauling",
	sorting = "groupSorting",
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
--  THE RARITY TIERS SHOWN IN THE STATS LIST EVEN AT ZERO.
--
--  Vanilla's four, in commonest-to-rarest order. They are named here rather than
--  derived because the port can only report tiers it has COUNTED, and the whole
--  point of the list is that a player sees "Legendary: 0" and learns that
--  legendary fish exist.
local FISH_RARITIES = { "common", "uncommon", "rare", "legendary" }

local RGB_MIN = 0
local RGB_MAX = 255

--  VANILLA'S LAMP VALUE, AND THAT IS THE REASON. petports_module_light.animation
--  ships [140,140,140], so an RGB module whose settings have never been touched
--  looks exactly like the common lamp it upgrades from -- which makes "did my
--  module work" a question the player can answer before adjusting anything.
local RGB_DEFAULT = 140

--  HOW FAR ONE CLICK OF A SPINNER MOVES A CHANNEL.
--
--  ONE, WHICH IS WHAT A SPINNER MEANS, and it is also 255 clicks from end to
--  end. That is deliberate: the arrows are for nudging a colour that is nearly
--  right and the field is for entering one that is not.
local RGB_STEP = 1

--  WHAT A ROW IS, IN ONE VOCABULARY.
--
--  There were two kinds and the second was implicit -- `sep = true` or, by
--  omission, a checkbox. A third kind would have made that omission mean two
--  things, so every read site asks this instead and none of them looks at
--  `.sep` any more.
--
--  THE LEGACY SPELLING IS STILL ACCEPTED rather than rewritten across a dozen
--  entries, because normalising here is what removes the ambiguity; restating
--  it on rows that already read correctly would only widen the diff.
local function rowKind(row)
	if row == nil then return nil end
	if row.kind ~= nil then return row.kind end
	if row.sep then return "sep" end
	return "check"
end

local SETTING_ROWS = {
	--  `default = false` ON BOTH DISPLAY TOGGLES, matching the port, which reads
	--  each of them as `== true` so that absent means OFF. Without it the pane
	--  draws a ticked box over a unit the port considers switched off -- see
	--  settingValue, and the tab's own note on why display toggles start quiet.
	--
	--  `carried` CARRIED THE SAME MISMATCH AND NOBODY COULD SEE IT, because
	--  nothing reads that setting yet. Fixed here rather than left to surface the
	--  day the speech bubbles land.
	{ key = "carried", owner = "toggles", needs = nil, default = false,
	  label = "petport.setting.carried", tip = "petport.tip.carried" },

	--  BESIDE `carried` BECAUSE THEY ARE THE SAME KIND OF THING: universal
	--  per-unit DISPLAY toggles, owned by no module, defaulted off. The tab's
	--  own note gives the reason -- a base running a dozen units with permanent
	--  labels overhead is the vanilla ship-pet clutter this mod exists to avoid.
	--
	--  A SETTING RATHER THAN "DOES IT HAVE A CUSTOM NAME". Every unit item ships
	--  a default petName -- Diver, Wader, Flyer, Unit -- so keying the tag on
	--  whether a name exists would show one over every unit in the fleet and give
	--  the player no way to turn it off short of clearing names they wanted.
	{ key = "nametag", owner = "toggles", needs = nil, default = false,
	  label = "petport.setting.nametag", tip = "petport.tip.nametag" },

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
	  label = "petport.setting.medicunit", tip = "petport.tip.medicunit" },

	{ sep = true, needs = "farming", label = "petport.setting.farmingblock" },

	{ key = "harvest", owner = "farming", needs = "farming",
	  label = "petport.setting.farmharvest", tip = "petport.tip.farmharvest" },
	{ key = "water", owner = "farming", needs = "farming",
	  label = "petport.setting.farmwater", tip = "petport.tip.farmwater" },
	{ key = "replant", owner = "farming", needs = "farming",
	  label = "petport.setting.farmreplant", tip = "petport.tip.farmreplant" },
	{ key = "animals", owner = "farming", needs = "farming",
	  label = "petport.setting.farmanimals", tip = "petport.tip.farmanimals" },

	--  ---- RGB LIGHT ---------------------------------------------------------
	--
	--  GATED ON THE MODULE FLAG, like the medic and farming blocks above. The
	--  RGB lamp item declares petports_moduleFlags ["rgblight"], the port unions
	--  the flags and mirrors them, and these rows exist only while the set
	--  contains it. The port enforces the same thing independently, so a stale
	--  row cannot colour a lamp that is not socketed.
	--
	--  THEY SHOWED UNCONDITIONALLY FOR TWO BUILDS. That was so the textbox could
	--  be proven to construct inside a list row at all, with no module in the
	--  world to gate on.
	{ kind = "sep", needs = "rgblight", label = "petport.setting.rgbblock" },

	{ kind = "rgb", key = "r", owner = "light", needs = "rgblight",
	  label = "petport.setting.rgbred", tip = "petport.tip.rgbred" },
	{ kind = "rgb", key = "g", owner = "light", needs = "rgblight",
	  label = "petport.setting.rgbgreen", tip = "petport.tip.rgbgreen" },
	{ kind = "rgb", key = "b", owner = "light", needs = "rgblight",
	  label = "petport.setting.rgbblue", tip = "petport.tip.rgbblue" }
}

--  Which message carries each owner's set, and where the pane reads it back.
local SETTING_MESSAGE = {
	toggles = "petports_setToggles",
	medic = "petports_setMedic",
	farming = "petports_setFarming",

	--  NOT SENT BY settingsRowClicked LIKE THE OTHER THREE. Those read a set of
	--  checkboxes back; a colour row has no checkbox and commits from two other
	--  paths. commitLight names this directly.
	light = "petports_setLight"
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
		--  THE FIELD IS TWO WIDGETS AND BOTH ARE MEMBERS. The backing is a
		--  separate image rather than part of the textbox, so leaving it out
		--  would paint an empty box over the Details tab.
		"nameFieldBacking", "tbPetName",
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

--  THE PANE'S SOUNDS, PLAYED LOCALLY, WITH THE PORT AS A FALLBACK.
--
--  THE ROUTE WENT THROUGH THE PORT AND DID NOT NEED TO. Two candidates were
--  measured and both failed: a ContainerPane's `pane` table is three functions
--  and none is audio, and `localAnimator` probed nil in a pane script. So the
--  object played the sounds instead, at the cost of a message round trip and
--  positional audio for anyone standing nearby.
--
--  widget.playSound WAS THE ONE NOBODY CHECKED. It is documented as a general
--  callback available for all widgets:
--
--      void widget.playSound(String audio, [int loops = 0], [float volume])
--
--  NOTE THE ARGUMENT. Every other function in that table takes a widget name
--  first; this one takes an ASSET PATH and nothing else. Passing a widget name
--  would look exactly like the rest of this file and be wrong.
--
--  THE PATHS MOVE BACK HERE WITH IT. They lived in the port's animation while
--  the port was playing them, which was right then and is not now.
--
--  THE PORT FALLBACK STAYS FOR THIS BUILD, AND ONLY BECAUSE OF WHAT ELSE IS IN
--  IT. This build also lands the colour wire and the light effect. A sound that
--  silently vanished would be one more thing to rule out while reading a log
--  about a light -- so if the local call fails, the message route that already
--  works takes over and says so once. If the log shows it never fired, the port
--  handler and its `sounds` block can both go.
local PANE_SOUNDS = {
	refuse = "/sfx/interface/clickon_error.ogg",
	swap = "/sfx/interface/inventory_pickup1.ogg"
}

--  nil UNTRIED, true LOCAL WORKS, false FALL BACK TO THE PORT.
local soundIsLocal = nil

local function paneSound(name)
	local path = PANE_SOUNDS[name]

	--  A NAME WITH NO PATH IS A TYPO HERE, NOT A PLAYER ACTION, so it is loud
	--  rather than silent -- there is no runtime condition that reaches it.
	if path == nil then
		dbg("no sound named %s", tostring(name))
		return
	end

	if soundIsLocal ~= false then
		local ok, err = pcall(widget.playSound, path)

		if ok then
			soundIsLocal = true
			return
		end

		soundIsLocal = false
		dbg("widget.playSound unavailable, falling back to the port: %s", tostring(err))
	end

	--  THE NAME IS A KEY, NOT A PATH. The port holds its own closed table of
	--  what it will play and resolves each key against its own animation.
	tell("petports_paneSound", { sound = name })
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
--
--  THE OVERRIDE IS WHAT LETS A SWAP BE TESTED BEFORE IT HAPPENS.
--
--  moduleSlotClicked has to refuse a duplicate BEFORE it moves anything, and
--  the cursor is untouched until setSwapSlotItem runs -- so a refusal at that
--  point costs nothing. But the question is about the set the move WOULD
--  produce, and paneModules does not hold it yet.
--
--  Building the prospective set here rather than mutating paneModules and
--  rolling back keeps the failure path free of a half-applied swap, which is
--  the state dd.module.writetoken exists to keep out of this table.
--
--  `overrideSlot` nil MEANS NO OVERRIDE, so the existing no-argument call is
--  unchanged. An override TO nil is an emptied slot, which is why the two are
--  separate arguments rather than one descriptor whose absence has to mean two
--  different things.
local function moduleRecords(overrideSlot, overrideItem)
	local out = {}
	for i = 1, MODULE_SLOTS do
		local item = paneModules[i]
		if overrideSlot == i then item = overrideItem end

		if item ~= nil then
			table.insert(out, { slot = i, item = item })
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

--  THE COLOUR THIS PANE IS SHOWING, MIRRORED FROM THE PORT.
--
--  IT WAS THE TRUTH FOR TWO BUILDS, while there was no port side. It is now a
--  copy of petData.light, written by refresh and read by the paint.
--
--  IT IS ALSO WRITTEN OPTIMISTICALLY BY commitLight, on the click, rather than
--  waiting for the echo -- which is what makes a spinner feel immediate. The
--  echo then arrives holding the same value, lightPainted already matches it,
--  and the paint stays quiet. That is the mechanism dd.module.writetoken needed
--  a token for and this does not: a colour cannot be duplicated or destroyed by
--  a dropped reply, so the worst a lost message costs is a click.
local paneLight = {}

--  WHAT THIS SCRIPT LAST WROTE INTO EACH FIELD, AND IT IS THE WHOLE MECHANISM.
--
--  The poll decides a player has typed by seeing text it did not put there. So
--  every write to a field has to record itself in the same breath, or the
--  script's own paint reads back as an edit and commits itself in a loop --
--  which is the bookkeeping the restock pane's setField exists for, and the
--  reason its comment says the bookkeeping is the point.
local lightShown = {}

--  THE VALUE THE BOX IS KNOWN TO BE DISPLAYING, WHICH IS NOT THE SAME QUESTION.
--
--  THE BUG THIS EXISTS FOR TURNED 0 INTO 10, AND IT IS IN THE LOG. Backspacing
--  140 away, one character at a time:
--
--      light g -> 14      140, one backspace
--      light g -> 1       two backspaces
--      light g -> 10      the "0" the player typed, on the end of a "1"
--                         they did not
--
--  An empty box is someone mid-edit, so nothing commits and paneLight stays at
--  1. The steady-state paint then compared the STORED VALUE against the TEXT,
--  found "1" against "", concluded the field was stale and wrote the 1 back --
--  one poll after the player deleted it and a fraction before they typed.
--
--  THE PAINT MUST BE DRIVEN BY A CHANGE IN TRUTH, NOT BY DISAGREEMENT WITH THE
--  WIDGET. `lightShown` answers "what text is in there", which is what the poll
--  needs to spot an edit. This answers "what value has been put in there", which
--  is what the paint needs to spot a change -- and an emptied box has not
--  changed the value, so the paint leaves it alone.
--
--  THIS IS THE `lightSeen` THAT BUILD 2 WAS GOING TO NEED FOR THE MIRROR ECHO,
--  arriving a build early because it turns out to be the same mechanism. A port
--  echoing back the value the player just set is a paint whose truth did not
--  move, exactly like a repaint during a local edit.
local lightPainted = {}

--  THE LAST VALUE THIS PANE SENT THE PORT, PER CHANNEL, UNTIL THE ECHO AGREES.
--
--  THE BUG THIS EXISTS FOR IS IN THE LOG AND IT IS A STALE ECHO WINNING:
--
--      light g -> 14      typed 140 down to 14
--      light g -> 1        and down to 1
--      light g -> 1        committed twice, with nothing in between
--
--  Each edit sends immediately, so two messages are in flight when the first
--  echo lands. That echo carries 14 -- true when it was written, stale by the
--  time it arrives -- and the mirror read accepted it, because the only test
--  was whether it differed from paneLight. It did. So paneLight went back to
--  14, the paint saw a value lightPainted did not match, and wrote 14 into a
--  box the player had already cut down to 1. The second echo then put it back.
--  The double commit is the field being repainted twice under the caret.
--
--  THE PANE OWNS A CHANNEL WHILE ITS WRITE IS OUTSTANDING. A mirror value is
--  accepted only once it AGREES with what was last sent, which is the moment
--  the port has caught up; anything else is an older answer to a newer question.
--
--  A VALUE, NOT A TOKEN, and that is the difference from dd.module.writetoken.
--  Modules needed a stamp because a dropped reply could destroy an item, so the
--  pane had to know its own write specifically. A colour cannot be lost or
--  duplicated -- the port clamps to the same range the pane does, and the pane
--  sends all three channels every time -- so "the port now says what I said" is
--  a complete answer and needs nothing on the wire to carry it.
local lightSent = {}

--  Put a channel in its field and remember, two ways, what is now in there.
--
--  BOTH BOOKS OR NEITHER. The poll reads lightShown to tell a keystroke from the
--  script's own write; the paint reads lightPainted to tell a changed value from
--  an unchanged one. A write that updated only the first would have the paint
--  fire again on the very next poll against a box it had just filled.
local function setLightField(path, channel, value)
	local text = tostring(value)

	lightShown[channel] = text
	lightPainted[channel] = value
	pcall(widget.setText, path .. ".settingField", text)
end

--  LET GO OF ONE FIELD, IF IT IS THE ONE HOLDING THE CARET.
--
--  A FOCUSED TEXTBOX CAPTURES THE KEYBOARD, AND THAT INCLUDES ENTER. Observed
--  2026-09-03: with a colour field focused, Enter no longer opened chat, and
--  clicking elsewhere did not let go -- nothing in this pane ever blurred
--  anything, so a field kept the caret until the pane closed.
--
--  ONLY IF FOCUSED. widget.blur is documented as unsetting focus on a FOCUSED
--  widget; calling it on one that never had focus is asking for whatever it
--  does in that case, and hasFocus is right there.
--
--  GUARDED, BECAUSE THIS RUNS FROM A TAB CHANGE. showTab is reachable before
--  the settings list has ever been built, when a row path points at nothing.
local function blurField(name)
	local ok, focused = pcall(widget.hasFocus, name)
	if ok and focused then pcall(widget.blur, name) end
end

--  EVERY TEXT FIELD THIS PANE OWNS, AND THERE ARE TWO KINDS.
--
--  THE NAME FIELD HAD THE SAME FAULT AND HAD IT FIRST. tbPetName has shipped
--  since 2026-09-01 holding the keyboard exactly the same way; the colour rows
--  only made it noticeable. Both are released by the same rule rather than the
--  new one getting a fix the old one does not.
--
--  THE COLOUR FIELDS ARE FOUND BY WALKING THE ROWS, because they exist only
--  while an RGB module is socketed and their paths are new after every rebuild.
local function blurPaneFields()
	blurField("tbPetName")

	for i, row in ipairs(settingsRowKeys) do
		local path = settingsRowPaths[i]

		if rowKind(row) == "rgb" and path ~= nil then
			blurField(path .. ".settingField")
		end
	end
end

--  A CHANNEL VALUE AND WHETHER THE CEILING BIT, OR nil IF THE TEXT IS NOT ONE.
--
--  OUT OF RANGE IS CLAMPED, WHICH REVERSES THIS FUNCTION'S FIRST DRAFT, AND THE
--  REVERSAL IS WHAT THE LOG ARGUED FOR.
--
--  It refused an out-of-range entry, on the reasoning that writing 255 back over
--  a 999 moves the caret out from under someone mid-number. What that actually
--  produced, observed 2026-09-03:
--
--      typing 999 then clicking the up spinner set the value to 100
--      typing 256 then clicking the up spinner set the value to 26
--
--  Both are correct given a refusal, and both look broken. Typing 999 passes
--  through 9 and 99, each of which commits; 999 itself is refused, so 99 is what
--  the unit is left holding while the box says 999. The spinner then does its
--  job on the stored truth and lands on 100. The box and the value had been
--  allowed to disagree, and a control acting on the value could only ever look
--  like it had invented a number.
--
--  THE CARET COST IS REAL AND IS PAID ONLY WHEN THE CLAMP BITS, which is the
--  whole reason this returns a flag rather than just a number. A valid entry is
--  never written back, so "0100" still does not snap to "100" under a moving
--  caret -- the case the restock pane's rule was actually about. Only a number
--  that cannot be a colour gets corrected, and being corrected is the point.
--
--  THE FLOOR IS UNREACHABLE THROUGH THE FIELD, since a \d regex cannot produce a
--  negative. It is stated anyway so the function is total and the spinner's own
--  clamp is not the only thing standing between a caller and a bad value.
local function rgbValue(text)
	local value = tonumber(text)
	if value == nil then return nil end

	value = math.floor(value)

	if value < RGB_MIN then return RGB_MIN, true end
	if value > RGB_MAX then return RGB_MAX, true end

	return value, false
end

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

--  THE CHANNEL A COLOUR ROW SHOULD SHOW, defaulting for a unit whose colour has
--  never been set. Build 2 reads this off the mirror instead.
local function lightValue(channel)
	local value = paneLight[channel]
	if type(value) ~= "number" then return RGB_DEFAULT end
	return value
end

--  THE VALUE A ROW SHOULD SHOW, and ABSENT IS NOT ONE ANSWER FOR EVERY ROW.
--
--  IT USED TO BE `store[row.key] ~= false` FOR EVERYTHING, i.e. absent reads as
--  ON. That is right for the medic and farming rows and matches their port-side
--  accessors, which read `settings[class] ~= false` so a freshly socketed module
--  works immediately instead of looking broken until every box is ticked.
--
--  IT IS WRONG FOR THE DISPLAY TOGGLES, AND THAT MISMATCH WAS THE BUG. The port
--  reads petportNametag() as `toggles.nametag == true` -- absent means OFF,
--  deliberately, so shipping this feature does not label an entire base. The
--  pane defaulted the same absent value to ON, so a legacy unit whose petData
--  predates the toggle drew a TICKED box over a port that was pushing
--  `tag false`. OBSERVED 2026-09-01 on three legacy pets; the checkbox was never
--  lying about its own value, the two sides disagreed about what absent meant.
--
--  DECLARED PER ROW RATHER THAN INFERRED FROM THE OWNER. Every `toggles` row
--  happens to want false today, so keying on owner would work and would be a
--  coincidence -- the next module setting that wants off-by-default would sit
--  under its own owner and quietly get the wrong answer.
--
--  A PRESENT VALUE IS UNCHANGED. Only nil consults the default, so every row
--  that already had a stored setting reads exactly as it did before.
local function settingValue(row)
	local store = paneSettings[row.owner] or {}
	local value = store[row.key]

	if value == nil then return row.default ~= false end
	return value ~= false
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

		--  CLEARED WITH THE ROWS. The fields these recorded no longer exist, so
		--  leaving the record would have the steady state below believe it had
		--  already painted a value into a widget that was just destroyed --
		--  and the new field would come up empty and stay empty.
		lightShown = {}
		lightPainted = {}

		--  PARITY RESETS AT EACH SEPARATOR so every module's block starts on
		--  the base shade, exactly as the stats list does.
		local stripe = false

		for i, row in ipairs(rows) do
			local rowId = widget.addListItem("settingsScroll.settingsList")
			local rowPath = "settingsScroll.settingsList." .. rowId

			settingsRowPaths[i] = rowPath
			settingsRowKeys[i] = row

			local kind = rowKind(row)

			--  EVERY ROW CARRIES EVERY WIDGET, because a list has one template
			--  and the kinds differ only in which of them are shown. Hiding is
			--  therefore stated for all three kinds rather than left to the
			--  template's defaults -- a row is rebuilt from a pool and may
			--  arrive wearing the last kind that used it.
			local isCheck = (kind == "check")
			local isRgb = (kind == "rgb")

			widget.setVisible(rowPath .. ".settingCheck", isCheck)
			widget.setVisible(rowPath .. ".colorFieldBacking", isRgb)
			widget.setVisible(rowPath .. ".settingField", isRgb)
			widget.setVisible(rowPath .. ".settingDown", isRgb)
			widget.setVisible(rowPath .. ".settingUp", isRgb)

			if kind == "sep" then
				stripe = false
				widget.setImage(rowPath .. ".rowBG", SETTINGS_ROW_CLEAR)
				widget.setText(rowPath .. ".settingLabel", SETTINGS_SEPARATOR_TEXT)
				widget.setFontColor(rowPath .. ".settingLabel", SETTINGS_SEPARATOR_COLOR)

				--  A DIVIDER IS NOT A CONTROL. Both interactive widgets go away
				--  rather than being left checked and inert, which would invite
				--  a click that does nothing.
				widget.setVisible(rowPath .. ".rowButton", false)
			else
				widget.setImage(rowPath .. ".rowBG",
					stripe and SETTINGS_ROW_ALT or SETTINGS_ROW)
				stripe = not stripe

				widget.setText(rowPath .. ".settingLabel", petports_stringOr(row.label, "--"))

				--  ON EVERY ROW, INCLUDING COLOUR ROWS, AND ON THEM IT IS LOAD
				--  BEARING RATHER THAN DECORATION.
				--
				--  A list row has no hover of its own -- hover only ever comes
				--  from a button -- so hiding this was what left colour rows flat
				--  for three builds. It was hidden because it appeared to be
				--  stealing the field's click, and it was: it takes the left
				--  press and the field never sees it.
				--
				--  IT NOW HANDS THAT PRESS ON. settingsRowClicked focuses the
				--  field when the row is a colour row, so the button keeps the
				--  hover AND the field gets its caret, which is the outcome
				--  neither hiding it nor reordering the template could reach.
				widget.setVisible(rowPath .. ".rowButton", true)

				--  THE ROW INDEX, ON EVERY INTERACTIVE WIDGET. A member callback
				--  gets the leaf name -- identical for every row -- so only the
				--  widget data can say which row fired.
				--
				--  settingField IS NOT IN THIS LIST. Its callback is a no-op and
				--  the poll identifies rows by walking them, so it needs no data
				--  -- which also avoids setData on a textbox, unverified here.
				widget.setData(rowPath .. ".settingCheck", i)
				widget.setData(rowPath .. ".rowButton", i)

				if isRgb then
					widget.setData(rowPath .. ".settingDown", i)
					widget.setData(rowPath .. ".settingUp", i)

					--  SEEDED HERE, so a freshly built field is never blank.
					--  The steady state below only writes on a CHANGE, and
					--  against an empty lightShown every value is a change --
					--  but stating it at build time keeps the two paths from
					--  having to agree about who paints first.
					setLightField(rowPath, row.key, lightValue(row.key))
				end
			end
		end
	end

	--  THE STEADY STATE TOUCHES A WIDGET ONLY WHEN ITS VALUE MOVED.
	--
	--  THIS RUNS ON EVERY POLL WHERE THE PORT'S STATE CHANGED, which on a
	--  working unit is constantly -- cargo, task, fuel. A field repainted
	--  unconditionally here would be wiped out from under anyone typing into
	--  it several times a second, by changes that have nothing to do with the
	--  colour. The checkboxes do not care, because setChecked over an unchanged
	--  value is invisible; a textbox has a caret.
	for i, row in ipairs(rows) do
		local path = settingsRowPaths[i]
		local kind = rowKind(row)

		if path ~= nil then
			if kind == "check" then
				widget.setChecked(path .. ".settingCheck", settingValue(row))
			elseif kind == "rgb" then
				--  ONLY WHEN THE VALUE MOVED. Comparing against the TEXT is what
				--  restored a deleted digit under the player's caret -- see
				--  lightPainted. An empty box disagrees with every stored value
				--  and is not stale; it is unfinished.
				local value = lightValue(row.key)
				if value ~= lightPainted[row.key] then
					setLightField(path, row.key, value)
				end
			end
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

--  THE LAST NAME THE PORT REPORTED, so refresh can tell a genuine change from
--  its own repetition.
--
--  A TEXTBOX CANNOT BE REPAINTED ON EVERY REFRESH. refresh runs on a mirror that
--  changes for fuel, cargo, task and diagnostics, and writing the field each
--  time would delete whatever the player was halfway through typing -- a rename
--  would be unusable on any unit that was actually working.
--
--  KEYED ON WHAT THE PORT SAID, NOT ON WHAT THE BOX HOLDS. Comparing against the
--  widget's own text would treat every keystroke as a change to undo, which is
--  the same bug wearing a different mask. This only rewrites when the STORED
--  name moves underneath the pane -- a commit landing, or a different unit being
--  socketed.
--
--  false RATHER THAN nil FOR "NOTHING SEEN YET", because nil is also a legitimate
--  value for it to hold: an unnamed unit reports petNameRaw absent, and with nil
--  as the sentinel the first paint of an unnamed unit would compare equal to the
--  initial state and never clear the box.
local paneNameSeen = false

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
		medic = state.medic or {},
		farming = state.farming or {}
	}

	--  THE COLOUR, MIRRORED PER CHANNEL RATHER THAN BY REPLACING THE TABLE.
	--
	--  A WHOLESALE REPLACE WOULD FIGHT AN EDIT IN PROGRESS. paneLight is written
	--  optimistically on the click and the port's echo carries the same value
	--  back, so assigning a fresh table here is usually a no-op -- but assigning
	--  one built from a mirror that has not caught up yet would move a channel
	--  the player just set, and lightPainted would then see a change and repaint
	--  the field under their caret.
	--
	--  COMPARING AGAINST paneLight WAS NOT ENOUGH, AND THE LOG SAYS SO. A stale
	--  echo differs from paneLight exactly as a genuine external change does,
	--  so accepting on difference alone let an older answer overwrite a newer
	--  edit -- see lightSent, which records the fault in full.
	--
	--  A CHANNEL WITH A WRITE OUTSTANDING BELONGS TO THE PANE. Only a mirror
	--  value that AGREES with what was last sent is accepted, and accepting it
	--  is what closes the write. Anything else is discarded unread.
	--
	--  ALWAYS COMPLETE FROM THE PORT. petportLightColor fills every channel, so
	--  there is no absent case to interpret here -- unlike the three tables
	--  above, whose absence means something different for each.
	local light = state.light or {}

	for _, channel in ipairs({ "r", "g", "b" }) do
		local value = tonumber(light[channel])

		if value ~= nil then
			local sent = lightSent[channel]

			if sent == nil then
				--  NOTHING IN FLIGHT, so the port is the authority. This is the
				--  ordinary path: the pane opening, a unit being socketed, or
				--  anything that changed the colour other than this pane.
				paneLight[channel] = value
			elseif value == sent then
				--  THE PORT HAS CAUGHT UP. The write is closed and the next
				--  mirror is believed again.
				lightSent[channel] = nil
				paneLight[channel] = value
			end
		end
	end

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

	--  ONE BLOCK PER ACTIVITY, SEPARATED. Farming above, healing next, fishing
	--  below -- three things a unit does rather than one undifferentiated column
	--  of numbers. The parity note further down explains why a separator is also
	--  the only place stripe colouring resets.
	addSeparator()

	--  EVERY CATEGORY, ALWAYS, EVEN AT ZERO.
	--
	--  A stat that appears only once it is non-zero teaches a player nothing --
	--  they cannot discover that a pet CAN heal or fish by looking at a list
	--  that hides those lines until it already has. "Heals delivered: 0" is a
	--  feature announcement; a missing line is a mystery, and worse, it makes a
	--  player wonder what else the pane is not telling them.
	--
	--  THIS IS WHY dosed IS HERE AT ALL. It has been in the port's paneStats
	--  since the medic shipped and was never drawn, so the medic module's own
	--  output has been invisible this whole time.
	addLine(petports_format("petport.stats.dosed", groupDigits(stats.dosed)))

	addSeparator()
	addLine(petports_format("petport.stats.fished", groupDigits(stats.fished)))

	--  ONE ROW PER RARITY, IN A FIXED ORDER, INCLUDING THE EMPTY ONES.
	--
	--  FIXED RATHER THAN SORTED BY COUNT. An earlier version ranked them by
	--  catch count, which reads well as a one-off distribution and badly as a
	--  live list: rows would reorder themselves under the player as counts
	--  changed. Commonest-to-rarest is the order the rarities themselves imply.
	--
	--  THE FOUR ARE VANILLA'S AND ARE NAMED HERE BECAUSE THEY MUST BE SHOWN AT
	--  ZERO. The port sends only tiers it has actually counted -- it cannot send
	--  a zero for a tier that has never occurred -- so the baseline set has to
	--  live somewhere, and the pane is where "what a player should be told
	--  exists" is decided.
	--
	--  ANY OTHER TIER IS APPENDED AFTER. A fishing zone may declare its own
	--  rarities; those cannot be shown at zero, but once one is caught it gets
	--  its own row rather than being silently folded away.
	local tiers = stats.fishedTiers or {}
	local shown = {}

	for _, tier in ipairs(FISH_RARITIES) do
		shown[tier] = true
		addLine(petports_format("petport.stats.fishedtier",
			tier:sub(1, 1):upper() .. tier:sub(2),
			groupDigits(tiers[tier] or 0)))
	end

	local extra = {}
	for tier, count in pairs(tiers) do
		if not shown[tier] then table.insert(extra, tier) end
	end
	table.sort(extra)

	for _, tier in ipairs(extra) do
		addLine(petports_format("petport.stats.fishedtier",
			tier:sub(1, 1):upper() .. tier:sub(2),
			groupDigits(tiers[tier])))
	end

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
	--  BEFORE activeTab MOVES, so the rows this walks are still the ones on
	--  screen. A field that keeps the caret after its row is hidden holds the
	--  keyboard from a tab that has no text entry on it at all.
	blurPaneFields()

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
	widget.setText("tbPetName", "")
	paneNameSeen = false
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

	--  THE FIELD FOLLOWS petNameRaw, THE HEADER FOLLOWS petName. An unnamed unit
	--  shows its species above and an EMPTY box below, so the box always reads as
	--  "what this unit is called", never as a suggestion the player has to clear
	--  before typing.
	if state.petNameRaw ~= paneNameSeen then
		paneNameSeen = state.petNameRaw
		widget.setText("tbPetName", state.petNameRaw or "")
	end

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
		paneSound("refuse")
		return
	end

	local cursor = player.swapSlotItem()

	if cursor ~= nil and (cursor.count or 1) > 1 then
		dbg("refusing module swap: cursor holds %s", tostring(cursor.count))
		paneSound("refuse")
		return
	end

	if cursor ~= nil then
		local ok, isModule = pcall(root.itemHasTag, cursor.name, MODULE_TAG)
		if not ok or isModule ~= true then
			dbg("refusing module swap: %s is not a module", tostring(cursor.name))
			paneSound("refuse")
			return
		end
	end

	--  ADDITION THREE, THE DUPLICATE GATE. One module of a kind per unit -- see
	--  petports_modules.lua for the rule and why it is not written twice.
	--
	--  ASKED OF THE SET THIS WOULD PRODUCE, not of the cursor against the other
	--  slots. Those are the same question only as long as nothing else can put
	--  a pair in paneModules, and the port's own check reads the payload, so
	--  asking about the payload is what keeps the two sides literally identical.
	--
	--  BEFORE ANYTHING MOVES. The cursor is still the player's at this point --
	--  swapSlotItem READ it, setSwapSlotItem below is what takes it -- so a
	--  refusal here returns with the item exactly where the player left it.
	--  That is the whole reason this gate belongs in the pane and not only in
	--  the port, which cannot refuse without stranding a module the pane has
	--  already lifted.
	--
	--  A SWAP THAT EMPTIES A SLOT PASSES TRIVIALLY, since removing an item
	--  cannot create a pair. No special case is needed for it.
	local duplicate = petports_moduleSetDuplicate(moduleRecords(index, cursor))

	if duplicate ~= nil then
		dbg("refusing module swap: %s is already socketed", tostring(duplicate))
		paneSound("refuse")
		return
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

	--  THE ONE SWAP THAT LEAVES NOTHING TO SEE.
	--
	--  Dropping a module onto a slot holding the SAME module is legal -- the old
	--  one goes back to the cursor -- and nothing on screen moves: the slot shows
	--  a lamp before and after, and so does the cursor. Observed 2026-09-03 as
	--  "the sound is failing", which it was not; there was no refusal to sound.
	--  What was missing was any signal that the swap had happened at all, and an
	--  itemslot makes no sound of its own.
	--
	--  THIS CASE ONLY, AND THAT IS A NARROWING. An earlier draft sounded EVERY
	--  successful swap, on the reasoning that an item moved is an item moved.
	--  Every other swap changes what the slot or the cursor is holding, so the
	--  screen already says so; this is the only one where a sound is the whole
	--  of the feedback.
	--
	--  SAME NAME IS THE SAME TEST THE DUPLICATE RULE USES, and if that ever
	--  stops being name equality -- two lamps carrying different parameters, the
	--  upgrade hook petportModuleSlots' own comment anticipates -- this moves
	--  with petports_modules.lua rather than staying behind as a second opinion.
	--
	--  BEFORE THE tell BELOW, so the sound is asked for on the same frame as the
	--  move rather than behind the module write it does not depend on.
	if previous ~= nil and cursor ~= nil and previous.name == cursor.name then
		paneSound("swap")
	end

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

--  EXISTS SO THE PANE CAN BE BUILT, AND DOES NOTHING SO ENTER CANNOT COMMIT.
--
--  A textbox MUST name a callback -- with none, WidgetParser looks for one named
--  after the widget and throws inside the ContainerPane constructor, taking the
--  client to the main menu on interact rather than merely breaking the field.
--
--  The callback fires on ENTER. Committing there is exactly what we do not want:
--  a half-typed name reaching a server's chat filter is how someone gets banned
--  for a rename they never finished. renameClicked is the only commit path, so
--  this is empty and must stay empty.
function petNameEntered()
end

--  THE ONLY COMMIT PATH, ON PURPOSE. The textbox's callback is a no-op, so a name
--  reaches the port when the player presses this and at no other moment. Enter
--  would commit whatever is in the box the instant it is pressed, and a half-
--  typed name is exactly the sort of thing a server's chat-politeness plugin
--  bans people for.
--
--  TRIMMED, AND AN EMPTY RESULT MEANS CLEAR. A field holding only spaces is a
--  player clearing the name, not naming a unit " ". The port takes nil as
--  "forget the stored name", which drops the header back to the species.
--
--  FIRE AND FORGET, LIKE EVERY OTHER SETTING. No write token: the module swap
--  needed one because a dropped reply could duplicate or destroy an ITEM, and a
--  name has no such hazard. The worst a lost message costs is a click, and the
--  next mirror repaints the field from whatever the port actually holds.
function renameClicked()
	local typed = widget.getText("tbPetName") or ""
	local trimmed = typed:match("^%s*(.-)%s*$")

	dbg("rename requested: %s", trimmed == "" and "<clear>" or trimmed)
	tell("petports_setPetName", { name = trimmed ~= "" and trimmed or nil })

	--  AND LET GO OF THE FIELD. Pressing the commit button is the least
	--  ambiguous "done with this" in the whole pane -- there is nothing else the
	--  player could mean -- so the caret should not survive it, and neither
	--  should the keyboard capture that comes with it.
	--
	--  AFTER THE SEND, NOT BEFORE. The name is read from the widget above; a
	--  blur first would be one more thing between reading it and trusting what
	--  was read, for no gain.
	blurField("tbPetName")
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
	if path == nil then return end

	local kind = rowKind(row)

	--  A COLOUR ROW FOCUSES ITS FIELD, AND THIS IS WHERE THE FOCUS PROBLEM ENDS.
	--
	--  THE FIELD NEVER GETS THE LEFT CLICK AND CONFIG CANNOT FIX THAT.
	--  Widget::sendEvent offers an event to children in REVERSE order and stops
	--  at the first that consumes it, so a later sibling should win -- but
	--  settingField was declared after rowButton from the start and lost anyway,
	--  and declaring it first changed nothing. Whatever order a row's members
	--  end up in, it is not the order written in the listTemplate.
	--
	--  THE RIGHT CLICK WAS THE TELL. It falls through and focuses the field
	--  perfectly, because a ButtonWidget handles the left button only and
	--  declines the other. So the field is under the cursor, its bounds are
	--  right, and it works -- it just never receives the press that matters.
	--
	--  SO THE BUTTON HANDS FOCUS OVER RATHER THAN COMPETING FOR IT. rowButton
	--  already takes the click and already knows the row, and Widget::focus is
	--  reachable from the widget table by member path. That keeps the hover the
	--  button exists for, and makes the WHOLE ROW a target for the field rather
	--  than a 26-pixel strip.
	--
	--  GUARDED AND REPORTED ONCE. Every other route to this field has failed for
	--  a different reason, so a silent no-op here would be indistinguishable
	--  from the four things already ruled out.
	if kind == "rgb" then
		local ok, err = pcall(widget.focus, path .. ".settingField")
		if not ok then
			dbg("cannot focus %s.settingField: %s", path, tostring(err))
		end
		return
	end

	--  ANY OTHER ROW LETS GO OF THE CARET. Clicking away from a text field is
	--  the ordinary way to finish with it, and without this the field kept the
	--  keyboard -- Enter included -- while the player was plainly done with it.
	--
	--  BEFORE THE SEPARATOR RETURN, so a click on a divider releases too. A
	--  divider does nothing else, which makes it the most obvious place someone
	--  clicks to mean "not that".
	--
	--  THE NAME FIELD GOES WITH THEM. It sits on this same tab, so a click on a
	--  settings row is just as plainly "done with the name" as it is "done with
	--  a channel".
	blurPaneFields()

	--  CHECKBOX ROWS ONLY FROM HERE. A separator has no controls at all, so a
	--  click reaching this from one is dropped rather than toggling a widget the
	--  player cannot see.
	if kind ~= "check" then return end

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
		if rowKind(other) == "check" and other.owner == row.owner
		   and settingsRowPaths[j] ~= nil then
			set[other.key] = widget.getChecked(settingsRowPaths[j] .. ".settingCheck")
		end
	end

	tell(SETTING_MESSAGE[row.owner], set)
end

--  ---------------------------------------------------------------------------
--  THE COLOUR ROWS
--  ---------------------------------------------------------------------------

--  COMMIT ONE CHANNEL. Build 1 stops at paneLight; build 2 sends it.
--
--  DOES NOT WRITE BACK TO THE FIELD. A rejected entry leaves the box showing
--  what was typed and the stored value untouched, and an accepted one is already
--  what the box says -- so there is no case where snapping the text back would
--  do anything except move the caret out from under someone mid-number.
local function commitLight(channel, value)
	if paneLight[channel] == value then return end

	paneLight[channel] = value

	--  THE BOX IS ALREADY SHOWING IT, so record that here rather than leaving
	--  the paint to notice a change and write the player's own number back over
	--  their caret. On the typed path the text came FROM the field; on the
	--  spinner path setLightField is about to write it. Either way this line is
	--  what keeps the paint quiet for a value nobody needs told about.
	lightPainted[channel] = value

	dbg("light %s -> %s", channel, tostring(value))

	--  ALL THREE CHANNELS, NOT THE ONE THAT MOVED -- the same reasoning the
	--  checkbox rows use. Sending the whole colour is self-correcting: a channel
	--  that somehow drifted from the port is brought back into line by the next
	--  edit of any of them, and the port's handler needs no notion of a partial
	--  update to be correct.
	--
	--  FIRE AND FORGET. The port rewrites the mirror and the next poll repaints
	--  from what it actually stored, so a refused value corrects itself.
	local set = {
		r = lightValue("r"),
		g = lightValue("g"),
		b = lightValue("b")
	}

	--  RECORDED BEFORE IT IS SENT, ON EVERY CHANNEL, because the payload carries
	--  all three and the port stores all three -- so all three are outstanding
	--  even when only one moved. Marking just the edited channel would leave the
	--  other two open to a stale echo carrying their older values.
	for channel, value in pairs(set) do
		lightSent[channel] = value
	end

	tell(SETTING_MESSAGE.light, set)
end

--  READ THE FIELDS BACK AND COMMIT ANY THAT MOVED.
--
--  A POLL RATHER THAN THE TEXTBOX'S CALLBACK, and the restock pane's note gives
--  the reason: what a textbox callback actually fires ON is not something this
--  mod knows. That pane runs both and shares one function to make it harmless;
--  here the callback cannot identify its row at all, so the poll is the only
--  path and the callback is a no-op.
--
--  AN EMPTY OR OUT-OF-RANGE FIELD IS SOMEONE MID-EDIT, NOT SOMEONE ASKING FOR
--  NOTHING. The regex permits zero digits, so an empty box is the ordinary
--  state of a field just cleared to be retyped -- and rgbValue returns nil for
--  it, which is read here as "not yet", not as zero.
local function pollLightFields()
	if activeTab ~= "tabSettings" or not paneHasUnit then return end

	for i, row in ipairs(settingsRowKeys) do
		local path = settingsRowPaths[i]

		if rowKind(row) == "rgb" and path ~= nil then
			local ok, text = pcall(widget.getText, path .. ".settingField")

			if ok and type(text) == "string" and text ~= lightShown[row.key] then
				--  RECORDED BEFORE IT IS JUDGED. What is in the box is now what
				--  the script knows to be in the box, whether or not it parses.
				--  Without this a field holding "9" on the way to "99" is a new
				--  edit on every single poll, and every one of them logs.
				lightShown[row.key] = text

				local value, clamped = rgbValue(text)

				if value ~= nil then
					commitLight(row.key, value)

					--  THE ONLY WRITE-BACK ON THE TYPED PATH, AND IT IS
					--  CONDITIONAL. A valid entry is left exactly as typed --
					--  caret untouched, "0100" not snapped -- and only a number
					--  that cannot be a colour is corrected in place.
					--
					--  RUNS EVEN WHEN commitLight CHANGED NOTHING. Typing a
					--  fourth digit onto 255 gives 2555, which clamps to the
					--  value already stored, so the commit returns early and
					--  this is the only thing that puts the box back.
					if clamped then setLightField(path, row.key, value) end
				end
			end
		end
	end
end

--  A SPINNER. One handler for both arrows; arg 1 says which.
--
--  THE STEP IS CLAMPED, NOT WRAPPED. 255 rolling to 0 on one click is a colour
--  a player did not ask for and did not see coming, and the field beside it is
--  there for anyone who wants the far end.
--
--  IT WRITES THE FIELD ITSELF, THROUGH setLightField, so the bookkeeping stays
--  in step. Painting it and forgetting to record it would have the poll read
--  the script's own write back as an edit on the very next tick.
function settingsSpinClicked(from, index)
	local i = tonumber(index)
	if i == nil then return end

	local row = settingsRowKeys[i]
	local path = settingsRowPaths[i]
	if rowKind(row) ~= "rgb" or path == nil then return end

	local step = (from == "settingDown") and -RGB_STEP or RGB_STEP
	local value = lightValue(row.key) + step

	if value < RGB_MIN then value = RGB_MIN end
	if value > RGB_MAX then value = RGB_MAX end

	commitLight(row.key, value)
	setLightField(path, row.key, value)
end

--  REQUIRED BY THE PARSER, NOT BY THE FEATURE, exactly like petNameEntered.
--
--  A textbox whose callback does not resolve throws at CONSTRUCTION, and inside
--  a list row that means addListItem takes the pane down before a widget is
--  drawn. Reading is pollLightFields' job; this exists so the row can be built.
--
--  IT FIRES PER KEYSTROKE, AND THAT IS MEASURED. 2026-09-03, instrumented for
--  one session: 105 fires across a handful of short edits, one per character
--  and never once per Enter.
--
--  WHICH KILLS THE OBVIOUS USE FOR IT. Enter is the conventional way to finish
--  with a text field, and blurring from here would have bought that for one
--  line -- and would have made the field impossible to type more than a single
--  character into. The restock pane's warning that what a textbox callback
--  fires on is not something this mod knows was worth taking literally.
--
--  SO BLURRING HAPPENS ON A CLICK ELSEWHERE, in settingsRowClicked and showTab,
--  and Enter is not a way out of the field. The instrumentation is gone because
--  it was a dozen log lines per typed number once the answer was in.
function settingsFieldChanged()
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

	--  THE COLOUR ROW'S THREE, AND THE TEXTBOX IS THE ONE THAT MATTERS.
	--
	--  A textbox's callback must resolve at CONSTRUCTION -- so if this
	--  registration is missing, or runs after the first addListItem, the pane
	--  does not open. The arrows are ordinary buttons and follow the rule the
	--  upcycler's rows already prove.
	widget.registerMemberCallback("settingsScroll.settingsList",
		"settingsSpinClicked", settingsSpinClicked)
	widget.registerMemberCallback("settingsScroll.settingsList",
		"settingsFieldChanged", settingsFieldChanged)

	--  IS THERE AN AUDIO BINDING IN A PANE SCRIPT AT ALL?
	--
	--  Logged once, here, rather than inferred from a silent refusal. An unbound
	--  localAnimator and a sound that plays inaudibly look identical from the
	--  outside, and this is the only line that tells them apart.
	dbg("localAnimator %s, playAudio %s",
		type(localAnimator),
		type(localAnimator) == "table" and type(localAnimator.playAudio) or "n/a")

	showTab("tabDetails")
	refresh(true)
end

function update(dt)
	pollTake()
	refresh(false)

	--  OUTSIDE THE SIGNATURE GATE, like the two below, and for the same kind of
	--  reason: a player types without the port's state changing at all, so a
	--  read gated on refresh would never see the keystroke.
	pollLightFields()

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
