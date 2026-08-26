--  PETPORTS -- UPCYCLER PANE SCRIPT
--
--  SKELETON. Renders whatever rules the object holds, lets one be added and one
--  removed, and toggles the machine. It does not compute a census, does not
--  show progress, and does not know what a Pet Treat is.
--
--  THE PANE IS A VIEW, AND THAT IS ARCHITECTURAL RATHER THAN INCIDENTAL.
--
--  Conversion runs in the object's own update loop, so the machine behaves
--  identically whether anyone is looking at it. This pane polls -- the way
--  cropshippergui recomputes its total every tick -- and never drives anything.
--  There is deliberately no way to ask whether the pane is open, and nothing
--  here needs one.
--
--  READ PATH IS DIRECT, AND THAT IS MEASURED RATHER THAN ASSUMED.
--
--  world.getObjectParameter IS reachable from a container pane script --
--  confirmed by log, "readDirect OK: rules=null enabled=nil" on a fresh
--  machine. So the pane reads the object with no message and no round trip.
--
--  There was a message fallback here and it is gone: the direct path answered
--  on the first test, and a second read path that never runs is a branch nobody
--  will ever exercise or maintain. The object still answers
--  petports_upcyclerRead, because a petport will want it later for the census.

local DEBUG = true

--  sb.logInfo accepts %s and nothing else. Pre-format through string.format,
--  which has no such limit, and hand the logger one string.
local function dbg(fmt, ...)
	if not DEBUG then return end
	local ok, text = pcall(string.format, fmt, ...)
	sb.logInfo("PETPORTS upcyclerpane: %s", ok and text or ("<badformat> " .. tostring(fmt)))
end

local function j(value)
	local ok, text = pcall(sb.printJson, value)
	return ok and text or "<unprintable>"
end

local RULES_KEY = "petports_upcyclerRules"
local ENABLED_KEY = "petports_upcyclerEnabled"

local RULES_LIST = "rulesScroll.rulesList"

--  Where the polymorphic display-name overrides live. Shared with the restock
--  pane on purpose: an item that needs a family name in one list needs the same
--  family name in the other, and two tables would drift.
local POLYMORPHIC_CONFIG = "/scripts/lofty_petports/petports_polymorphic.config"

--  Declared by the items themselves rather than listed here. An item says "do
--  not convert me" and neither the machine nor this pane needs updating when a
--  new one appears, including from another mod.
local TAG_NO_UPCYCLING = "petports_no_upcycling"
local TAG_BEACON = "petports_beacon"

--  ---------------------------------------------------------------------------
--  READING THE OBJECT
--  ---------------------------------------------------------------------------

--  Direct parameter read, if the binding exists here.
--
--  Returns nil for "could not read", which is DIFFERENT from an empty rule
--  list -- and telling those apart is most of the point of this build. A pane
--  that cannot see its object and a machine that has no rules look identical
--  on screen.
local function readDirect()
	if world == nil or world.getObjectParameter == nil then
		dbg("readDirect: world.getObjectParameter not available in this context")
		return nil
	end

	local id = pane.containerEntityId()
	if id == nil then return nil end

	local okRules, rules = pcall(world.getObjectParameter, id, RULES_KEY)
	local okEnabled, enabled = pcall(world.getObjectParameter, id, ENABLED_KEY)

	if not okRules or not okEnabled then
		dbg("readDirect: threw (rules ok=%s enabled ok=%s)",
			tostring(okRules), tostring(okEnabled))
		return nil
	end

	dbg("readDirect OK: rules=%s enabled=%s", j(rules), tostring(enabled))

	return {
		--  Absent is not empty, but for a read both behave the same way here:
		--  no rules. The distinction that matters is enabled, below.
		rules = type(rules) == "table" and rules or {},

		--  ABSENCE MEANS OFF. A machine that has never been configured has no
		--  parameter at all, and the whole off-on-placement guarantee rests on
		--  reading that as false rather than as missing data.
		enabled = enabled == true
	}
end

--  ---------------------------------------------------------------------------
--  WRITING
--  ---------------------------------------------------------------------------

--  THE WHOLE STATE, EVERY TIME. See the object script's handler for why there
--  is no diff protocol.
local function writeState()
	local id = pane.containerEntityId()

	if id == nil then
		dbg("write SKIPPED: no container entity")
		return
	end

	world.sendEntityMessage(id, "petports_upcyclerWrite", {
		rules = self.rules,
		enabled = self.enabled
	})

	dbg("write SENT: %s", j({ rules = self.rules, enabled = self.enabled }))
end

--  ---------------------------------------------------------------------------
--  LABELS
--  ---------------------------------------------------------------------------

local function polymorphicNames()
	if self.polymorphic ~= nil then return self.polymorphic end

	local ok, data = pcall(root.assetJson, POLYMORPHIC_CONFIG)

	if not ok or type(data) ~= "table" or type(data.displayNames) ~= "table" then
		sb.logError("petports: polymorphic name table unreadable at %s; upcycler "
			.. "rows will use each item's own description", POLYMORPHIC_CONFIG)
		self.polymorphic = {}
	else
		self.polymorphic = data.displayNames
	end

	return self.polymorphic
end

--  Display name for an item NAME.
--
--  THE OVERRIDE WINS WHERE THERE IS ONE, for the same reason it does in the
--  restock pane: root.itemConfig gets a bare descriptor, so a genuinely
--  polymorphic item rebuilds with a fresh seed and the row would name one
--  arbitrary member of a family the rule covers entirely.
--
--  Vanilla generated weapons do NOT need an override -- a bare `raredagger`
--  resolves to "Rare Dagger", which is both stable and honest about the rule's
--  scope. Confirmed in the restock pane, which already does this.
local function labelFor(name)
	self.labels = self.labels or {}

	if self.labels[name] == nil then
		local override = polymorphicNames()[name]

		if type(override) == "string" and override ~= "" then
			self.labels[name] = override
		else
			local ok, resolved = pcall(root.itemConfig, { name = name, count = 1 })

			if ok and type(resolved) == "table" and type(resolved.config) == "table" then
				self.labels[name] = resolved.config.shortdescription or name
			else
				--  Unresolvable is not an error worth hiding. A rule naming an
				--  item from a mod the player has since removed should read as
				--  its raw name rather than vanishing from the list.
				self.labels[name] = name
			end
		end
	end

	return self.labels[name]
end

--  ---------------------------------------------------------------------------
--  THE RULE LIST
--  ---------------------------------------------------------------------------

local function refreshRules()
	widget.clearListItems(RULES_LIST)

	--  ROW NAMES ARE KEPT so a selection can be restored after a rebuild.
	--  widget.setListSelected(list, nil) throws LuaConversionException -- the
	--  engine converts the argument to a String and nil does not survive it --
	--  so clearing a selection means rebuilding the list, and restoring one
	--  means having the row's generated name to hand.
	self.rowNames = {}

	for index, rule in ipairs(self.rules) do
		local row = widget.addListItem(RULES_LIST)
		local path = RULES_LIST .. "." .. row

		self.rowNames[index] = row

		--  THE ROW INDEX GOES ON THE ROW WIDGETS, not just the row.
		--
		--  A member callback is handed (leafName, widgetData), and the leaf name
		--  is identical for every row -- so widgetData is the ONLY thing that
		--  can identify which row fired. Anything clickable in a row needs its
		--  own setData or its callback cannot tell where it came from.
		widget.setData(path, index)
		widget.setData(path .. ".rowRemove", index)

		widget.setText(path .. ".ruleText",
			string.format("%s  >  %s", labelFor(rule.item), tostring(rule.max)))
	end

	if self.selectedIndex ~= nil and self.rowNames[self.selectedIndex] ~= nil then
		pcall(widget.setListSelected, RULES_LIST, self.rowNames[self.selectedIndex])
	end

	dbg("refreshRules: %s row(s), selected %s",
		tostring(#self.rules), tostring(self.selectedIndex))
end

--  Repaint ONE row's label.
--
--  EXISTS SO EDITING A THRESHOLD NEVER REBUILDS THE LIST. clearListItems drops
--  the selection and forces a setListSelected to restore it, and doing that on
--  every keystroke is what made the field impossible to type in.
local function refreshRuleRow(index)
	local row = (self.rowNames or {})[index]
	local rule = self.rules[index]

	if row == nil or rule == nil then return end

	widget.setText(RULES_LIST .. "." .. row .. ".ruleText",
		string.format("%s  >  %s", labelFor(rule.item), tostring(rule.max)))
end

--  WRITE THE FIELD AND RECORD WHAT WE WROTE, IN ONE BREATH.
--
--  syncThreshold decides the player has typed by seeing text it did not put
--  there, so every script-side write has to update shownThreshold too --
--  otherwise the pane's own render reads back as an edit and commits itself in
--  a loop. Straight out of restockconfig's setField, for the same reason.
local function setThresholdText(value)
	local text = value ~= nil and tostring(value) or ""

	self.shownThreshold = text
	pcall(widget.setText, "tbThreshold", text)
end

--  The threshold field follows the selection: editing it edits the selected
--  rule, and with nothing selected it is the value the NEXT rule will take.
local function refreshThreshold()
	local rule = self.selectedIndex ~= nil and self.rules[self.selectedIndex] or nil

	if rule ~= nil then
		setThresholdText(rule.max)
		widget.setText("thresholdLabel", "Keep at most")
	else
		widget.setText("thresholdLabel", "New rule keeps")
	end
end

--  POLLED, NOT DRIVEN BY THE CALLBACK.
--
--  A textbox `callback` does not fire per keystroke. Measured: an entire
--  editing session produced no thresholdChanged line at all, while the field
--  visibly accepted one backspace and then appeared stuck. restockconfig
--  already runs this way -- its minChanged/maxChanged are stubs that exist
--  only because a textbox whose callback does not resolve throws at
--  CONSTRUCTION -- and the real work happens in a poll from update().
local function syncThreshold()
	if not self.fieldUsable then return end

	local ok, text = pcall(widget.getText, "tbThreshold")

	if not ok or type(text) ~= "string" then
		--  LOUD AND ONCE. A pane where typing does nothing is indistinguishable
		--  from several other faults, so say which one it is.
		self.fieldUsable = false
		sb.logError("petports: upcycler pane cannot read tbThreshold; "
			.. "threshold entry is disabled for this pane")
		return
	end

	if text == self.shownThreshold then return end
	self.shownThreshold = text

	--  AN EMPTY FIELD IS NOT ZERO, AND THE DIFFERENCE IS DESTRUCTIVE.
	--
	--  Clearing 500 to type 250 passes through "", and reading that as 0 would
	--  mean "keep none of these" for as long as the player takes to type the
	--  next digit -- on a running machine, with the input slot already full.
	--  Mid-edit is not a state worth committing.
	if text == "" then return end

	local rule = self.selectedIndex ~= nil and self.rules[self.selectedIndex] or nil

	--  Nothing selected, so the field is only the value the next rule will
	--  take. Deliberately NOT wiped -- unlike restock, where an unselected
	--  field means nothing at all, here it is the default for the next sample.
	if rule == nil then return end

	local value = tonumber(text)
	if value == nil or rule.max == value then return end

	rule.max = value
	dbg("threshold: %s -> %s", rule.item, tostring(value))

	refreshRuleRow(self.selectedIndex)
	writeState()
end

--  ---------------------------------------------------------------------------
--  CALLBACKS
--  ---------------------------------------------------------------------------

function enabledToggled()
	self.enabled = widget.getChecked("enabledCheckbox") == true
	dbg("enabledToggled -> %s", tostring(self.enabled))
	writeState()
end

--  The number in the field, or nil if it is not one.
local function thresholdValue()
	local ok, text = pcall(widget.getText, "tbThreshold")
	if not ok then return nil end

	return tonumber(text)
end

--  Selecting a rule loads its threshold into the field.
function ruleSelected()
	local selected = widget.getListSelected(RULES_LIST)

	self.selectedIndex = nil

	for index, row in pairs(self.rowNames or {}) do
		if row == selected then
			self.selectedIndex = index
			break
		end
	end

	dbg("ruleSelected: row %s -> index %s",
		tostring(selected), tostring(self.selectedIndex))

	refreshThreshold()
end

--  NAME AN ITEM BY SHOWING IT.
--
--  The cursor's item is read for its NAME and handed straight back. Nothing is
--  consumed and the slot stays empty -- it is a sampler, not a socket.
--
--  THIS IS WHY RULES ARE PER-NAME AND NOT CATEGORICAL. Naming an item by
--  showing it needs no typing, no autocomplete and no vocabulary, and it works
--  for modded items no manifest has heard of. Copied from restockconfig, which
--  does the same thing for the same reason.
--
--  PUT IT BACK UNCONDITIONALLY, without reasoning about whether the engine
--  moved it. Vanilla's mech assembly performs its swap in Lua, which strongly
--  implies the engine leaves the swap slot alone when an itemslot has a
--  callback -- but "strongly implies" is not "verified", and the failure it
--  would hide is a player's item vanishing into a machine that never wanted it.
function sampleSlotClicked()
	local swap = player.swapSlotItem()

	dbg("sampleSlotClicked: cursor holds %s", j(swap))

	if type(swap) ~= "table" or type(swap.name) ~= "string" then
		--  A bare click has no job. Removing is the row's own X, which acts on
		--  one thing and cannot be misread as "delete everything".
		return
	end

	player.setSwapSlotItem(swap)

	--  ALREADY NAMED MEANS SELECT, NOT DUPLICATE. Two rules for one item would
	--  make the effective threshold depend on which the port read first, and
	--  the player almost certainly meant to edit the one they already made.
	for index, rule in ipairs(self.rules) do
		if rule.item == swap.name then
			self.selectedIndex = index
			dbg("sampleSlotClicked: %s already has a rule at %s",
				swap.name, tostring(index))

			refreshRules()
			refreshThreshold()
			return
		end
	end

	--  A MISSING OR MALFORMED THRESHOLD IS ZERO, and zero means "keep none of
	--  these" -- the most destructive reading available. It is safe as a default
	--  only because the machine ships off and every rule is visible in the list
	--  before it can run.
	table.insert(self.rules, { item = swap.name, max = thresholdValue() or 0 })
	self.selectedIndex = #self.rules

	dbg("sampleSlotClicked: added %s keeping %s",
		swap.name, tostring(self.rules[#self.rules].max))

	refreshRules()
	refreshThreshold()
	writeState()
end

--  Right-clicking the slot drops the SELECTION, not the list.
function sampleSlotCleared()
	self.selectedIndex = nil

	refreshRules()
	refreshThreshold()
end

--  MUST EXIST OR THE PANE DOES NOT OPEN. A textbox whose callback does not
--  resolve throws at CONSTRUCTION, in the client main loop, before a single
--  widget is drawn. Whatever it does fire on, syncThreshold has already handled
--  the edit by then.
function thresholdChanged()
	syncThreshold()
end


--  Registered at runtime via registerMemberCallback, NOT named in
--  scriptWidgetCallbacks. A row widget naming a pane-level callback throws
--  inside addListItem and the pane never opens.
local function ruleRowRemove(_, rowIndex)
	dbg("ruleRowRemove fired with data=%s (%s)", tostring(rowIndex), type(rowIndex))

	local index = tonumber(rowIndex)
	if index == nil or self.rules[index] == nil then return end

	table.remove(self.rules, index)

	--  The selection is an INDEX, so removing a row above it silently retargets
	--  it at a different rule. Dropping it is the honest answer; re-deriving
	--  which rule the player "meant" is guesswork.
	self.selectedIndex = nil

	refreshRules()
	refreshThreshold()
	writeState()
end

--  ---------------------------------------------------------------------------
--  STATUS
--  ---------------------------------------------------------------------------

--  What is actually in the input slot, or nil.
--
--  READ FROM THE GRID, NOT FROM THE CONTAINER. widget.itemGridItems is what
--  vanilla's cropshipper pane uses to total its contents, so it is the proven
--  route from a container pane script.
--
--  POSITION 1 IS THE INPUT, MEASURED. The return is a 1-based array over the
--  grid's own cells -- logged once as [null,null,null] on a three-cell grid --
--  so it does NOT follow the 0-based convention container OFFSETS use. Both
--  conventions are live in this codebase; see SLOT_KEY_TO_OFFSET in
--  petports_petport.lua, which pays for the same split.
--
--  With one grid per slot this reads cell 1 of the input grid rather than cell
--  1 of a three-cell grid. Same index, different reason -- worth knowing if the
--  layout changes again.
local function inputItem()
	local ok, items = pcall(widget.itemGridItems, "itemGrid")
	if not ok or type(items) ~= "table" then return nil end

	local candidate = items[1]

	if type(candidate) == "table" and type(candidate.name) == "string" then
		return candidate
	end

	return nil
end

local function ruleFor(name)
	for _, rule in ipairs(self.rules or {}) do
		if rule.item == name then return rule end
	end

	return nil
end

--  Every slot the machine has, across both grids.
--
--  A BEACON IN ANY SLOT IS A PROBLEM, not just one in the input, which is why
--  this looks at everything rather than reusing inputItem. A player who drops a
--  beacon into the reagent slot has made the same mistake.
local function allSlotItems()
	local items = {}

	for _, grid in ipairs({ "itemGrid", "itemGrid2" }) do
		local ok, contents = pcall(widget.itemGridItems, grid)

		if ok and type(contents) == "table" then
			for _, item in pairs(contents) do
				if type(item) == "table" and type(item.name) == "string" then
					table.insert(items, item)
				end
			end
		end
	end

	return items
end

--  Does this item name carry this tag?
--
--  MEMOISED BY NAME, which is safe where the upcycler's PRICE cache is not: an
--  item's tags come from its definition and no build script invents them per
--  instance, so two items sharing a name share their tags.
local function hasTag(name, tag)
	self.tagCache = self.tagCache or {}
	self.tagCache[name] = self.tagCache[name] or {}

	if self.tagCache[name][tag] == nil then
		local verdict = false
		local ok, resolved = pcall(root.itemConfig, { name = name, count = 1 })

		if ok and type(resolved) == "table" and type(resolved.config) == "table" then
			for _, candidate in ipairs(resolved.config.itemTags or {}) do
				if candidate == tag then
					verdict = true
					break
				end
			end
		end

		self.tagCache[name][tag] = verdict
	end

	return self.tagCache[name][tag]
end

local function showWarning(text)
	widget.setText("warnText", text)
	widget.setVisible("warnText", true)
	widget.setVisible("warnIcon", true)
end

local function hideWarning()
	widget.setVisible("warnText", false)
	widget.setVisible("warnIcon", false)
end

--  THE PANE COMPUTES ITS OWN REFUSALS rather than being told.
--
--  It already holds the rule list and can read its own grids, so every test
--  here is local -- no status channel, no message per tick, no third copy of
--  the machine's state to keep in step. The object refuses independently, on
--  the same one-line predicates; duplicating them is only safe because they are
--  this small.
--
--  ORDERED BY SEVERITY. A beacon in a machine is a mistake with consequences
--  beyond this pane -- the petport ignores it, so a crate the player thinks is
--  configured is not -- and it outranks a refusal that merely means nothing is
--  happening.
function refreshStatus()
	if not self.loaded then return end

	for _, item in ipairs(allSlotItems()) do
		if hasTag(item.name, TAG_BEACON) then
			showWarning("A beacon is in this machine. Machine slots are not "
				.. "storage, so the network ignores it. Take it back out.")
			return
		end
	end

	local input = inputItem()

	if input ~= nil and hasTag(input.name, TAG_NO_UPCYCLING) then
		--  The object refuses these whatever the rules say, so a rule naming
		--  one would look configured and do nothing.
		showWarning(string.format("%s can never be upcycled.", labelFor(input.name)))
		return
	end

	if input ~= nil and ruleFor(input.name) == nil then
		showWarning(string.format("No rule names %s, so it will not be "
			.. "converted.", labelFor(input.name)))
		return
	end

	hideWarning()

	if not self.enabled then
		widget.setText("lblStatus", string.format(
			"%s rule(s). Machine is off.", tostring(#self.rules)))
		return
	end

	if input == nil then
		widget.setText("lblStatus", string.format(
			"%s rule(s). Running, input empty.", tostring(#self.rules)))
		return
	end

	widget.setText("lblStatus", string.format(
		"%s rule(s). Converting %s.", tostring(#self.rules), labelFor(input.name)))
end

--  ---------------------------------------------------------------------------
--  PROGRESS
--  ---------------------------------------------------------------------------

--  Frames in progressbar.png, p0..p20.
local PROGRESS_STEPS = 20

--  How often to ask the object how many points it has banked.
--
--  ASKED, NOT DERIVED, and this is the one thing on the pane that cannot be
--  computed locally: points live in the object's `storage`, which
--  world.getObjectParameter cannot see. Everything else here is derived from
--  rules the pane already holds.
--
--  FOUR TIMES A SECOND, NOT EVERY TICK. The bar has 21 discrete steps, so
--  polling faster than the steps can change is spending messages on frames
--  nobody can see. Only ever while the pane is open -- the machine converts
--  whether or not anyone is looking, and nothing here drives it.
local PROGRESS_INTERVAL = 0.25

local function refreshProgress(dt)
	self.progressTimer = (self.progressTimer or 0) - dt

	if self.progressPromise ~= nil and self.progressPromise:finished() then
		local result = self.progressPromise:result()
		self.progressPromise = nil

		if type(result) == "table" then
			self.points = tonumber(result.points) or 0
			self.pointsPerFuel = tonumber(result.pointsPerFuel) or self.pointsPerFuel

			local fraction = 0

			if self.pointsPerFuel > 0 then
				fraction = self.points / self.pointsPerFuel
				if fraction > 1 then fraction = 1 end
				if fraction < 0 then fraction = 0 end
			end

			--  FLOORED, NOT ROUNDED. A bar that shows a full segment before the
			--  Treat exists reads as the machine being stuck at 100%.
			local step = math.floor(fraction * PROGRESS_STEPS)

			if step ~= self.progressStep then
				self.progressStep = step
				widget.setImage("progressBar", string.format(
					"/interface/lofty_petports/upcyclerconfig/progressbar.png:p%d", step))
			end

			widget.setText("progressLabel", string.format("%s / %s to next treat",
				tostring(self.points), tostring(self.pointsPerFuel)))
		end
	end

	if self.progressTimer > 0 or self.progressPromise ~= nil then return end

	self.progressTimer = PROGRESS_INTERVAL

	local id = pane.containerEntityId()
	if id == nil then return end

	self.progressPromise = world.sendEntityMessage(id, "petports_upcyclerRead")
end

--  ---------------------------------------------------------------------------
--  LIFECYCLE
--  ---------------------------------------------------------------------------

local function applyState(state)
	self.rules = {}

	for _, rule in ipairs(type(state.rules) == "table" and state.rules or {}) do
		if type(rule) == "table" and type(rule.item) == "string" and rule.item ~= "" then
			table.insert(self.rules, {
				item = rule.item,
				max = tonumber(rule.max) or 0
			})
		end
	end

	self.enabled = state.enabled == true
	self.loaded = true

	widget.setChecked("enabledCheckbox", self.enabled)
	refreshRules()
	refreshThreshold()

	--  lblStatus is owned by update(), which re-derives it every tick from the
	--  rules AND the input slot. Setting it here as well would flash the
	--  rules-only version for one frame on every edit.
	refreshStatus()
end

function init()
	self.rules = {}
	self.enabled = false
	self.loaded = false

	self.selectedIndex = nil
	self.rowNames = {}

	self.shownThreshold = ""
	self.fieldUsable = true
	self.tagCache = {}

	self.points = 0
	self.pointsPerFuel = 1000
	self.progressStep = -1
	self.progressTimer = 0

	dbg("init: containerEntityId=%s", tostring(pane.containerEntityId()))

	--  PROBE. Costs one log line and answers a question worth real money.
	--
	--  A container pane binds at most TWO itemgrids -- measured, twice, from
	--  both directions -- which caps the layout at two independently positioned
	--  groups. The way out is itemslot widgets as proxies over one container,
	--  the mech assembly station's pattern: it reads the cursor with
	--  player.swapSlotItem(), hands the old item back with
	--  player.setSwapSlotItem(), and validates in between.
	--
	--  itemslot callbacks come from scriptWidgetCallbacks rather than from
	--  hardcoded names, so proxies have NO two-widget limit. The whole approach
	--  therefore hinges on one thing: whether this pane has `player` at all.
	--
	--  Mech assembly is a ScriptPane and this is a ContainerPane -- genuinely
	--  different C++ classes, per the crash traces -- but the Lua bindings are
	--  plausibly hung off a shared base, in which case the only real difference
	--  is the item-bag scaffolding. Instrument rather than assume.
	dbg("probe: player=%s swapSlotItem=%s setSwapSlotItem=%s",
		type(player),
		type(player) == "table" and type(player.swapSlotItem) or "n/a",
		type(player) == "table" and type(player.setSwapSlotItem) or "n/a")

	--  REGISTRATION BEFORE ANY addListItem. The row parser resolves callback
	--  names at construction time, so a row built before this line throws and
	--  takes the pane down with it.
	widget.registerMemberCallback(RULES_LIST, "ruleRowRemove", ruleRowRemove)

	--  The sampler is always empty. It reads a name off the cursor and hands the
	--  item straight back, so anything left rendered in it would be a lie about
	--  where that item actually is.
	pcall(widget.setItemSlotItem, "itemSlot_sample", nil)

	local direct = readDirect()

	if direct ~= nil then
		applyState(direct)
	else
		--  A read that fails and a machine with no rules look identical on
		--  screen, so this says which it is rather than rendering an empty list
		--  and leaving the player to guess.
		widget.setText("lblStatus", "Could not read machine state.")
	end
end

--  POLLED, NOT PUSHED. The machine converts in its own update loop whether or
--  not anyone is looking at it, so there is deliberately no way to ask whether
--  this pane is open and nothing here drives the object. It is a view.
function update(dt)
	syncThreshold()
	refreshStatus()
	refreshProgress(dt)
end
