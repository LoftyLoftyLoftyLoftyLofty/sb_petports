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

--  The flavor table. Reads petports_flavors.config through root.assetJson and
--  hands it back in display order, with a reagent -> flavor index built at load.
--  Same shape as petports_filters.lua, which beaconconfig.lua requires the same
--  way -- so a pane script reaching a /scripts/ config is proven, not assumed.
require "/scripts/lofty_petports/petports_flavors.lua"

local DEBUG = true

--  sb.logInfo accepts %s and nothing else. Pre-format through string.format,
--  which has no such limit, and hand the logger one string.
--  "1 rule" and "2 rules", never "1 rule(s)".
--
--  The parenthesised form exists because a string with no logic in it cannot
--  agree with a number. This one has the number in hand, so there is no reason
--  to make the player read the seam.
--
--  ENGLISH ONLY, AND KNOWINGLY. Appending an s is wrong in most languages and
--  wrong for a fair number of English words too. It is right for every word
--  this pane pluralises -- rule, reagent, treat, flavor, cell -- and a real
--  plural table is not worth building until something needs translating.
local function plural(count, word)
	if count == 1 then return string.format("%d %s", count, word) end
	return string.format("%d %ss", count, word)
end

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

--  SHARED BY BOTH LISTS, and hoisted here for exactly that reason. They were
--  declared beside the flavors code at first, four hundred lines below the rules
--  list that also needs them -- and a local referenced above its own definition
--  is a nil GLOBAL that only throws when that path first runs.
--  ---- the reagent charge ----------------------------------------------------
--
--  One sprite, tinted per flavor. White inside a black outline, so "?multiply="
--  leaves the outline alone and turns the fill into the tint exactly.
local BLIP_ART = "/interface/lofty_petports/upcyclerconfig/blip.png"
local BLIP_COUNT = 8

--  An EMPTY cell is the same sprite multiplied down to near-black rather than a
--  second asset. Hiding individual cells would make the bar change length as it
--  drains, and a bar that shrinks reads as capacity being lost rather than
--  spent.
--
--  THIS IS THE ONLY PLACE A BLIP DIRECTIVE IS APPLIED. The widget's declared
--  file must stay bare: directives COMPOUND, so a "?multiply=" in the config is
--  not replaced by this one, it multiplies with it -- which turned sweet's
--  cfe9f2 into something indistinguishable from an empty cell.
local BLIP_EMPTY = "2a2a2aff"

--  Last drawn tint per cell, so an unchanged bar costs nothing. This runs on
--  the progress poll, which is every tick the pane is open.
local blipShown = {}

local ROW_ART = "/interface/lofty_petports/shared/row_144.png"
local ROW_ART_ALT = "/interface/lofty_petports/shared/row_144_alt.png"
local ROW_ART_SELECTED = "/interface/lofty_petports/shared/row_144_selected.png"

--  Where the polymorphic display-name overrides live. Shared with the restock
--  pane on purpose: an item that needs a family name in one list needs the same
--  family name in the other, and two tables would drift.
local POLYMORPHIC_CONFIG = "/scripts/lofty_petports/petports_polymorphic.config"

--  Declared by the items themselves rather than listed here. An item says "do
--  not convert me" and neither the machine nor this pane needs updating when a
--  new one appears, including from another mod.
local TAG_NO_UPCYCLING = "petports_no_upcycling"
local TAG_BEACON = "petports_beacon"

--  Every Pet Treat carries this, flavored or not, and it is the same tag the
--  deposit filter's Pet Treats group matches on -- so "the pane thinks this is
--  a treat" and "a crate will take it as fuel" cannot drift apart.
local TAG_FUEL = "petports_fuel"

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

--  SELECTION IS NEVER NIL WHILE ROWS EXIST.
--
--  An empty selection means the threshold field edits nothing, the slot shows
--  nothing, and the pane silently swallows what the player types. There is no
--  state where that is the useful answer, so there is no state where it happens.
--
--  Three rules, and they are the same rule from three directions:
--    opening   -> the first
--    adding    -> the one just added
--    deleting  -> the one below, or the one above if it was the last
--
--  Called BEFORE refreshRules, because that is what paints the selection.
local function ensureSelection()
	if #self.rules == 0 then
		self.selectedIndex = nil
		return
	end

	--  Clamped as well as filled. A rule removed from above the selection
	--  shifts every index down, so a stale one can point past the end.
	if self.selectedIndex == nil or self.rules[self.selectedIndex] == nil then
		self.selectedIndex = math.min(self.selectedIndex or 1, #self.rules)
	end
end

--  REPAINTS IN PLACE, NEVER REBUILDS. Rebuilding to show a selection change
--  would call clearListItems, which fires the list's own callback -- the repaint
--  would trigger the thing that asked for it.
--
--  The schema's selectedBG and unselectedBG are set on this list and do nothing;
--  they are vestigial in vanilla's UI. Row art lives in the listTemplate and is
--  driven from here, the same way the flavors list does it.
local function paintRuleRows()
	for index, path in pairs(self.rowPaths or {}) do
		local art = ROW_ART_ALT

		if index == self.selectedIndex then
			art = ROW_ART_SELECTED
		elseif index % 2 == 1 then
			art = ROW_ART
		end

		pcall(widget.setImage, path .. ".rowBG", art)
	end
end

local function refreshRules()
	--  THE REBUILD FIRES THE SELECTION CALLBACK, and without this guard that
	--  callback wins. clearListItems invokes ruleSelected, which finds nothing
	--  selected and sets selectedIndex to nil -- so the restore at the bottom of
	--  this function read a selection its own first line had just destroyed.
	--
	--  Symptom, and it is not obviously a selection bug: adding a rule appeared
	--  to work, and then typing in the threshold box updated nothing until the
	--  player clicked a row. The restock pane has carried this guard from the
	--  start; this one never got it.
	self.rebuilding = true
	widget.clearListItems(RULES_LIST)
	self.rebuilding = false

	--  ROW NAMES ARE KEPT so a selection can be restored after a rebuild.
	--  widget.setListSelected(list, nil) throws LuaConversionException -- the
	--  engine converts the argument to a String and nil does not survive it --
	--  so clearing a selection means rebuilding the list, and restoring one
	--  means having the row's generated name to hand.
	self.rowNames = {}

	--  Paths as well as names: the names restore the engine's own selection,
	--  the paths are what paintRuleRows writes art to.
	self.rowPaths = {}

	for index, rule in ipairs(self.rules) do
		local row = widget.addListItem(RULES_LIST)
		local path = RULES_LIST .. "." .. row

		self.rowNames[index] = row
		self.rowPaths[index] = path

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

	paintRuleRows()

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
--  THE SLOT SHOWS THE SELECTED RULE'S ITEM, and the old comment saying it must
--  always be empty was about a different question.
--
--  That reasoning was: the sampler reads a NAME off the cursor and hands the
--  item straight back, so an item rendered in it would be a lie about where that
--  item actually is. True while the slot means "what is in here". It does not
--  apply to "which rule are you editing" -- nothing is claiming the item is
--  stored, any more than a recipe icon claims to hold the recipe.
--
--  IT MAKES THE THRESHOLD FIELD LEGIBLE. "Keep at most 500" is meaningless
--  without saying 500 of WHAT, and the rule list is a separate glance away.
--
--  THE SLOT STILL TAKES A CLICK, which is why the hint changes with it: a slot
--  that shows something and says "click holding an item" reads as two
--  contradictory instructions.
local function refreshSampleSlot()
	local rule = self.selectedIndex ~= nil and self.rules[self.selectedIndex] or nil

	if rule ~= nil and type(rule.item) == "string" then
		pcall(widget.setItemSlotItem, "itemSlot_sample",
			{ name = rule.item, count = 1 })
		widget.setText("sampleHint", "Click holding an item")
	else
		pcall(widget.setItemSlotItem, "itemSlot_sample", nil)
		widget.setText("sampleHint", "Click holding an item")
	end
end

local function refreshThreshold()
	local rule = self.selectedIndex ~= nil and self.rules[self.selectedIndex] or nil

	if rule ~= nil then
		setThresholdText(rule.max)
		widget.setText("thresholdLabel", "Keep at most")
	else
		widget.setText("thresholdLabel", "New rule keeps")
	end

	--  Driven from here rather than from every caller, because every path that
	--  changes the selection already calls this one. A second thing to remember
	--  is a second thing to forget.
	refreshSampleSlot()
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
	--  A REBUILD IS NOT A CLICK. See refreshRules.
	if self.rebuilding then return end

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

	--  The tint has to follow the click, and repainting is the only way to move
	--  it without a rebuild.
	paintRuleRows()
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

			--  A SELECT, NOT AN ADD, so the machine is left alone -- nothing
			--  became more destructive than it already was.
			refreshRules()
			refreshThreshold()
			return
		end
	end

	--  A MISSING OR MALFORMED THRESHOLD IS ZERO, and zero means "keep none of
	--  these" -- the most destructive reading available.
	--  ZERO, NOT WHATEVER IS IN THE BOX.
	--
	--  This read thresholdValue(), which was coherent while nothing was selected
	--  by default: the field was a staging value, the label read "New rule
	--  keeps", and it became "Keep at most" once a row was picked.
	--  ensureSelection deleted that state -- something is always selected now, so
	--  the field always shows a rule's cap and adding silently borrowed an
	--  unrelated rule's number.
	--
	--  So the field means exactly one thing: the selected rule's cap. A new rule
	--  starts at zero, which is safe only because adding also switches the
	--  machine off -- those two changes are a pair, not independent.
	--
	--  DELIBERATELY NOT DERIVED FROM THE ITEM the way restock derives a quota
	--  from maxStack. A quota has an honest default -- fill a stack, refetch at
	--  half. A threshold does not: "upcycle above one stack" is a guess about
	--  intent, and guessing wrong destroys things.
	table.insert(self.rules, { item = swap.name, max = 0 })

	--  The new one. Survives the rebuild now that refreshRules is guarded --
	--  before that, this line was correct and then immediately undone.
	self.selectedIndex = #self.rules

	--  ADDING A RULE SWITCHES THE MACHINE OFF, ALWAYS.
	--
	--  The old defence was that a zero threshold is safe because the machine
	--  ships off and every rule is visible before it can run. That covers the
	--  FIRST rule and nothing after it: a player adding a second rule to a
	--  RUNNING machine has just told it to destroy every one of that item, and
	--  the gap between dropping the item and typing a number is however long it
	--  takes them to look at the keyboard.
	--
	--  So the destructive default stays -- zero is the honest reading of "no
	--  rule yet" -- and the machine stops instead. A player who has to switch it
	--  back on has lost two seconds; one who did not has lost a stack.
	--
	--  DELIBERATELY UNCONDITIONAL. Only switching off when the machine happens
	--  to be running would mean the behaviour depends on state the player is not
	--  looking at, and "sometimes it stops" is harder to learn than "it stops".
	if self.enabled then
		dbg("sampleSlotClicked: machine was running, switching it off")
	end

	self.enabled = false
	pcall(widget.setChecked, "enabledCheckbox", false)

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

	--  THE ONE BELOW, OR THE ONE ABOVE IF THAT WAS THE LAST.
	--
	--  Everything below the removed row shifts up by one, so the same INDEX now
	--  names the row that was underneath -- which is what a player expects to
	--  land on, and it makes deleting several in a row work without moving the
	--  mouse. Past the end means it was the last row, so fall back to the new
	--  last. ensureSelection does the clamp.
	--
	--  This used to clear the selection outright, on the reasoning that
	--  re-deriving which rule the player "meant" is guesswork. It is not
	--  guesswork for a DELETE: the row below is the only sensible answer, and an
	--  empty selection blanks the slot and the threshold field for no reason.
	self.selectedIndex = index
	ensureSelection()

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
--  Everything in the machine's slots, for the beacon check.
--
--  ONE GRID IS ENOUGH AND ALL THREE ARE ASKED ANYWAY. widget.itemGridItems
--  ignores slotOffset and returns the WHOLE container regardless of which grid
--  is named, so asking three lists every slot three times.
--
--  Harmless here -- the caller only asks "is any of these a beacon", and asking
--  three times about the same item gives the same answer. Left as-is rather
--  than narrowed, because the day that behaviour is fixed the one-grid version
--  would quietly stop seeing the other slots, and a beacon parked in one would
--  go unreported. Redundant now, correct either way.
--
--  This is also why the reagent warning cannot be read off a grid: asking
--  itemGrid2 for its first item returns the INPUT. See self.reagentName, which
--  comes from the machine.
local function allSlotItems()
	local items = {}

	--  ALL THREE GRIDS. ContainerPane binds itemGrid, itemGrid2 AND
	--  outputItemGrid, and this machine now uses one cell of each.
	for _, grid in ipairs({ "itemGrid", "itemGrid2", "outputItemGrid" }) do
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

	--  SOMETHING IN THE OUTPUT THAT IS NOT A TREAT.
	--
	--  It refuses every treat the machine tries to place, so the machine banks
	--  points and stops. NOTHING IN THE WORLD FIXES THIS: the port's fuel scan
	--  only recognises treats, deliberately, because hauling off an item a
	--  player parked somewhere is worse than leaving it there. This warning is
	--  the only way they find out.
	--
	--  ABOVE THE INPUT CHECKS. Both stop the machine, but an input it was never
	--  told to convert is a machine doing what it was configured to do. A
	--  blocked output is a correctly configured machine doing nothing, which is
	--  the more surprising of the two.
	if type(self.outputName) == "string"
	   and not hasTag(self.outputName, TAG_FUEL) then

		showWarning(string.format("%s is blocking the output. Nothing will be "
			.. "made until it is taken out.", labelFor(self.outputName)))
		return
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

	--  AN ITEM IN THE REAGENT SLOT THAT IS NOT A REAGENT.
	--
	--  The machine fails closed and leaves it alone, which is right and also
	--  completely silent -- from outside, "this is not a reagent" and "the bar
	--  is full so I am waiting" look identical. This is the only place that can
	--  tell the player which.
	--
	--  LOWEST SEVERITY of the three, and deliberately last: it costs the player
	--  nothing, where an unrecognised INPUT means the machine is doing no work
	--  at all.
	--
	--  Reads the same table the machine does, so the two cannot disagree about
	--  what counts as a reagent.
	local reagent = self.reagentName

	if type(reagent) == "string" and petports_reagentFor(reagent) == nil then
		showWarning(string.format("%s is not a reagent, so it will not flavor "
			.. "anything. See the Flavors tab.", labelFor(reagent)))
		return
	end

	hideWarning()

	if not self.enabled then
		widget.setText("lblStatus", string.format(
			"%s. Machine is off.", plural(#self.rules, "rule")))
		return
	end

	if input == nil then
		widget.setText("lblStatus", string.format(
			"%s. Running, input empty.", plural(#self.rules, "rule")))
		return
	end

	widget.setText("lblStatus", string.format(
		"%s. Converting %s.", plural(#self.rules, "rule"), labelFor(input.name)))
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

--  Paint the charge. `queue` is a list of flavor ids, oldest first.
--
--  CHANGE-GATED PER CELL. Eight setImage calls a tick would be harmless and
--  pointless; comparing the tint we last wrote costs one string compare.
local function refreshBlips(queue)
	if type(queue) ~= "table" then queue = {} end

	for index = 1, BLIP_COUNT do
		local flavor = queue[index]

		--  petports_flavorColor falls back to white for a flavor with no usable
		--  colour, which multiplies to no change -- a plain white blip rather
		--  than an invisible one.
		local tint = flavor ~= nil and petports_flavorColor(flavor) or BLIP_EMPTY

		if blipShown[index] ~= tint then
			blipShown[index] = tint
			pcall(widget.setImage, "blip" .. index, BLIP_ART .. "?multiply=" .. tint)

			--  THE BLIPS ARE DECLARED INVISIBLE and first become visible here,
			--  once they have a colour. That is what stops eight white cells
			--  flashing between the pane opening and the first poll returning.
			--
			--  All eight are painted in the same pass, so they appear together
			--  and the bar never changes length -- absent for a frame, never
			--  briefly wrong.
			pcall(widget.setVisible, "blip" .. index, true)
		end
	end
end

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

			refreshBlips(result.blips)

			--  PUBLISHED BY THE MACHINE, not read off the grid.
			--
			--  widget.itemGridItems IGNORES slotOffset and returns the whole
			--  container keyed from slot 0, so asking itemGrid2 for its first
			--  item handed back the INPUT -- the pane warned that dirt was not a
			--  reagent while the reagent slot was empty.
			--
			--  Arriving on the poll rather than instantly is the cost. It is the
			--  same channel the progress bar and the blips use, so the warning
			--  cannot be more than one poll out of step with the charge it is
			--  explaining.
			self.reagentName = result.reagent
			self.outputName = result.output
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

	--  Opening onto a machine with rules and nothing selected leaves the
	--  threshold field editing nothing, which reads as the field being broken.
	ensureSelection()

	refreshRules()
	refreshThreshold()

	--  lblStatus is owned by update(), which re-derives it every tick from the
	--  rules AND the input slot. Setting it here as well would flash the
	--  rules-only version for one frame on every edit.
	refreshStatus()
end

--------------------------------------------------------------------------------
--  TABS AND THE FLAVOR REFERENCE
--------------------------------------------------------------------------------
--
--  WHY THIS IS IN THE PANE AT ALL. The reagent table is 251 entries and nothing
--  in game says which item makes which flavor. Chilli making Spicy is
--  guessable; Bio Sample making Zesty, Metal Coated Wood making Sharp and Phase
--  Matter making Bitter are not. Without this the flavors are discoverable only
--  by feeding the machine one item at a time and watching the output slot.

local FLAVORS_LIST = "flavorsScroll.flavorsList"
local REAGENTS_LIST = "reagentsScroll.reagentsList"

--  Which tab is showing. Not read back from the buttons: a checkable button's
--  state is the RESULT of a click, and asking it is how a tab ends up
--  disagreeing with what is on screen after a rebuild.
local activeTab = "instructions"

local shownFlavors = {}

--  Row id -> flavor, and row id -> widget path. getListSelected hands back a row
--  ID, which is neither an index nor something to do arithmetic on, so the only
--  safe route from a click to a flavor is a map built when the rows were.
local flavorByRow = {}
local flavorRowPath = {}
local flavorRowIndex = {}
local selectedRow = nil

--  Cell widget path -> { name = , weight = }, for the reagent tooltips.
--
--  DECLARED HERE, and it was an implicit GLOBAL until now. A rewrite of this
--  block dropped the `local` and nothing complained, because a global works --
--  right up until another script in the same environment picks the same name.
local reagentCell = {}

--  Row button path -> flavor, for the flavor-row tooltips. Same mechanism:
--  createTooltip is handed a SCREEN POSITION and has to work out what is under
--  it, so anything with hover text has to be findable by path.
local flavorRowTip = {}

--  Which flavor the grid currently holds, so re-clicking the selected row does
--  not rebuild 78 cells to arrive at the same 78 cells.
local shownReagentFlavor = nil

--  ITS OWN GUARD, NOT SHARED WITH THE RULES LIST.
--
--  widget.clearListItems INVOKES THE LIST'S OWN CALLBACK, so tearing a list down
--  looks exactly like the player clicking away from the selected row. Sharing
--  one flag across both lists would mean a rules rebuild suppresses a legitimate
--  flavor selection -- a bug that only shows up when a player edits a rule and
--  then opens the flavors tab. One flag per list.
--
--  DECLARED HERE, and it was an implicit global until now for the same reason
--  reagentCell was: a rewrite of this block dropped the `local` and nothing
--  complained, because a global works right up until it does not.
local rebuildingFlavors = false

local FLAVOR_WIDGETS = { "flavorsScroll", "reagentsLabel", "reagentsScroll" }
local INSTRUCTION_WIDGETS = { "instructionsText" }

--  Named setWidgetsVisible, NOT setVisible. A local called setVisible sits one
--  character from widget.setVisible in every line that uses either, and the two
--  take different arguments -- a LIST of names versus one name.
local function setWidgetsVisible(names, shown)
	for _, name in ipairs(names) do
		--  pcall because a missing widget here should cost a tab, not the pane.
		local ok, err = pcall(widget.setVisible, name, shown)
		if not ok then
			dbg("setVisible %s -> %s FAILED: %s", name, tostring(shown), tostring(err))
		end
	end
end

--  REPAINTS IN PLACE, NEVER REBUILDS. Rebuilding to show a selection change
--  would call clearListItems, which invokes the list's own callback -- so the
--  repaint would fire the thing that asked for it. Same reasoning, and the same
--  shape, as the beacon pane's rule rows.
local function paintFlavorRows()
	for rowId, path in pairs(flavorRowPath) do
		local art = ROW_ART_ALT

		if rowId == selectedRow then
			art = ROW_ART_SELECTED
		elseif (flavorRowIndex[rowId] or 0) % 2 == 1 then
			art = ROW_ART
		end

		pcall(widget.setImage, path .. ".rowBG", art)
	end
end

--  Fill the grid with one flavor's reagents.
--
--  ALREADY SORTED BY THE ACCESSOR, heaviest first. Deliberately not re-sorted
--  here: a pane that asks for a different order than the object uses would
--  eventually get one, and then the list would be showing something no other
--  part of the mod agrees with.
--  INCREMENTAL BUILDING WAS TRIED HERE AND BACKED OUT. Do not re-add it.
--
--  Savory is 78 reagents and building them in one frame is a visible hitch, so
--  a queue drained a few cells per update() looked like the obvious fix. It is
--  not: widget.addListItem REPAINTS THE WHOLE CONTAINER, so every batch strobed
--  the entire grid. Measured in game -- the flicker was far worse than the
--  hitch it replaced.
--
--  That rules out spreading ANY list build across frames, not just this one.
--  The engine gives no way to append to a live list quietly.
--
--  What is left, if the hitch ever needs solving: fewer widgets per cell, or
--  fewer cells. Not fewer per frame.
local function refreshReagents(flavor)
	--  ALREADY SHOWING IT. Clicking the selected row again is a no-op rather
	--  than a rebuild. Free, and it covers the commonest repeat -- which is most
	--  of what the incremental version was reaching for anyway.
	local wantId = flavor ~= nil and flavor.id or nil
	if wantId == shownReagentFlavor then return end
	shownReagentFlavor = wantId

	rebuildingFlavors = true
	widget.clearListItems(REAGENTS_LIST)
	rebuildingFlavors = false

	reagentCell = {}

	if flavor == nil then
		widget.setText("reagentsLabel", "Select a flavor")
		return
	end

	--  ALREADY SORTED BY THE ACCESSOR, heaviest first. Deliberately not re-sorted
	--  here: a pane asking for a different order than the object uses would
	--  eventually get one, and then the list would show something no other part
	--  of the mod agrees with.
	local reagents = petports_flavorReagents(flavor.id)

	for _, entry in ipairs(reagents) do
		local rowId = widget.addListItem(REAGENTS_LIST)
		local path = string.format("%s.%s", REAGENTS_LIST, rowId)

		reagentCell[path .. ".icon"] = entry

		--  COUNT 1, ALWAYS, AND NEVER THE WEIGHT. An itemslot draws a stack
		--  number for anything above one, and a number beside an item reads as
		--  "you need this many of it" -- the exact inverse of what a weight
		--  means. The weight goes in its own label until the blip art exists.
		local ok, err = pcall(function()
			widget.setItemSlotItem(path .. ".icon", { name = entry.name, count = 1 })
			widget.setText(path .. ".weight", tostring(entry.weight))
		end)

		if not ok then
			dbg("reagent cell %s FAILED: %s", entry.name, tostring(err))
		end
	end

	widget.setText("reagentsLabel",
		string.format("%s -- %s", flavor.label or flavor.id,
			plural(#reagents, "reagent")))

	dbg("refreshReagents: %s, %d cell(s)", tostring(flavor.id), #reagents)
end

--  Build the flavor picker. Runs once; the table cannot change without an asset
--  reload, so there is nothing to poll and nothing to invalidate.
local function refreshFlavors()
	rebuildingFlavors = true
	widget.clearListItems(FLAVORS_LIST)
	rebuildingFlavors = false

	--  Cleared with the rows they describe. A stale entry would resolve a fresh
	--  row id to a flavor from the previous build.
	flavorByRow = {}
	flavorRowPath = {}
	flavorRowIndex = {}
	flavorRowTip = {}
	selectedRow = nil

	--  The grid belongs to a row that is about to stop existing.
	shownReagentFlavor = nil

	shownFlavors = petports_flavors()

	for index, flavor in ipairs(shownFlavors) do
		local rowId = widget.addListItem(FLAVORS_LIST)
		local path = string.format("%s.%s", FLAVORS_LIST, rowId)

		flavorByRow[rowId] = flavor
		flavorRowPath[rowId] = path
		flavorRowIndex[rowId] = index

		--  setData is the ONLY thing that identifies a row to a member callback:
		--  arg 1 is the leaf name "rowButton", identical on every row.
		local ok, err = pcall(function()
			widget.setData(path .. ".rowButton", rowId)


			widget.setText(path .. ".rowLabel",
				string.format("%s  (%d)", flavor.label or flavor.id,
					#petports_flavorReagents(flavor.id)))

			--  THE FLAVOR'S OWN TREAT AS ITS ICON. It is the flavor's identity,
			--  it is already named by `item` in the config, and the treat colours
			--  were spread across lightness as well as hue precisely so seven of
			--  them stay legible side by side.
			--
			--  NOT THE ANCHOR REAGENT, and that is not a preference -- the anchor
			--  CANNOT be derived. Savory's anchor is Alien Meat at weight 4 while
			--  its heaviest entries are cooked dishes at 8, so "first in the
			--  sorted list" would show a random casserole. An anchor icon would
			--  need an explicit field in petports_flavors.config.
			--  AN IMAGE PATH, NOT A DESCRIPTOR, because the icon is an image
			--  widget now -- see the config for why a slot could not work.
			--
			--  root.itemConfig returns the item's own DIRECTORY alongside its
			--  config, and inventoryIcon is relative to it. Resolving it that
			--  way rather than hardcoding our fuels folder is what lets a
			--  modded flavor's treat show its own icon.
			local item = petports_flavorItem(flavor.id)

			if item ~= nil then
				local okCfg, resolved = pcall(root.itemConfig, { name = item, count = 1 })

				if okCfg and type(resolved) == "table"
				   and type(resolved.config) == "table"
				   and type(resolved.config.inventoryIcon) == "string" then

					local icon = resolved.config.inventoryIcon

					--  An absolute path is already complete; a relative one is
					--  relative to the item's own directory.
					if icon:sub(1, 1) ~= "/" then
						icon = tostring(resolved.directory or "") .. icon
					end

					widget.setImage(path .. ".icon", icon)
				else
					--  A flavor whose treat has no readable icon still gets a
					--  usable row; the label carries the name. Logged because it
					--  means the manifest names an item that does not resolve.
					dbg("flavor %s: no icon for %s",
						tostring(flavor.id), tostring(item))
				end
			end

			--  THE WHOLE ROW IS THE TOOLTIP TARGET, tested against rowButton
			--  rather than the icon: the icon is mouseTransparent, and the
			--  button spans the row so hovering anywhere on it answers.
			flavorRowTip[path .. ".rowButton"] = flavor
		end)

		if not ok then
			dbg("flavor row %d FAILED: %s", index, tostring(err))
		end
	end

	paintFlavorRows()
	dbg("refreshFlavors: %d flavor(s)", #shownFlavors)
end

--  ONE ENTRY POINT FOR BOTH TABS, and it is what a radioGroup callback would
--  call too when the tab art lands. Nothing else in this file knows how tabs
--  are drawn.
local function showTab(which)
	activeTab = which

	setWidgetsVisible(INSTRUCTION_WIDGETS, which == "instructions")
	setWidgetsVisible(FLAVOR_WIDGETS, which == "flavors")

	--  Set from HERE rather than left wherever the click put them, so the pair
	--  cannot end up both checked or both clear. That is the one thing a
	--  radioGroup would do for free.
	pcall(widget.setChecked, "tabInstructions", which == "instructions")
	pcall(widget.setChecked, "tabFlavors", which == "flavors")

	dbg("showTab: %s", tostring(which))
end

--  Throw away whatever flavors are still queued.
--
--  ASKS THE MACHINE RATHER THAN REWRITING THE QUEUE. The machine owns it; a
--  pane writing the parameter would be a second author of the same state, and
--  the two would disagree the moment a treat is emitted between the read and
--  the write.
--
--  The blips do not clear here. They clear on the next poll, from the machine's
--  own answer -- so what the player sees is what the machine actually did,
--  rather than what the pane assumed it would do.
function clearChargeClicked()
	local id = pane.containerEntityId()
	if id == nil then return end

	dbg("clearChargeClicked: asking %s to discard its charge", tostring(id))
	world.sendEntityMessage(id, "petports_upcyclerClearCharge")
end

function tabInstructionsClicked()
	showTab("instructions")
end

function tabFlavorsClicked()
	showTab("flavors")

	--  BUILT ON FIRST OPEN, not in init. 251 cells is real work and most players
	--  will never open this tab, so it does not belong in the path every player
	--  pays for when they click on the machine.
	if #shownFlavors == 0 then refreshFlavors() end
end

--  Registered on the LIST with widget.registerMemberCallback, NOT named in
--  scriptWidgetCallbacks. A row widget naming a scriptWidgetCallbacks entry
--  throws at CONSTRUCTION and takes the pane down with it.
--  TWO WIDGETS, ONE SELECTION. The row button and the icon both land here so a
--  click anywhere on the row does the same thing.
local function selectFlavorRow(rowId, from)
	--  See rebuildingFlavors.
	if rebuildingFlavors then return end

	local flavor = rowId ~= nil and flavorByRow[rowId] or nil
	selectedRow = rowId

	dbg("selectFlavorRow (%s): row %s -> %s", tostring(from),
		tostring(rowId), flavor ~= nil and tostring(flavor.id) or "none")

	paintFlavorRows()
	refreshReagents(flavor)
end

local function flavorRowClicked(_, rowId)
	selectFlavorRow(rowId, "row")
end


--  Hover text for the reagent cells.
--
--  Handed a SCREEN POSITION, so every cell has to be tested with
--  widget.inMember -- there is no "what is under the cursor" call. Same
--  mechanism the beacon pane uses for its subgroup tiles.
--
--  THE TOOLTIP IS WHERE THE BLIP CONVENTION GETS TAUGHT. Blips are the
--  at-a-glance read; this is where somebody who has not worked out what they
--  mean finds out in words.
function createTooltip(screenPosition)
	--  The discard button. Says what it costs BEFORE it is pressed, which is the
	--  whole reason it has no confirm step.
	local okClear, onClear = pcall(widget.inMember, "btnClearCharge", screenPosition)

	if okClear and onClear then
		local tooltip = config.getParameter("tooltipLayout")

		if type(tooltip) == "table" then
			tooltip.title.value = "Discard charge"
			tooltip.description.value =
				"Throws away the flavors still queued. The reagents are not returned."
			return tooltip
		end
	end

	--  Flavor rows first -- a smaller table, and the two can never overlap.
	for path, flavor in pairs(flavorRowTip) do
		local ok, inside = pcall(widget.inMember, path, screenPosition)

		if ok and inside then
			local tooltip = config.getParameter("tooltipLayout")
			if type(tooltip) ~= "table" then return nil end

			tooltip.title.value = flavor.label or flavor.id
			tooltip.description.value = string.format("%s make this.",
				plural(#petports_flavorReagents(flavor.id), "reagent"))

			return tooltip
		end
	end

	for path, entry in pairs(reagentCell) do
		local ok, inside = pcall(widget.inMember, path, screenPosition)

		if ok and inside then
			local tooltip = config.getParameter("tooltipLayout")
			if type(tooltip) ~= "table" then return nil end

			local name = entry.name
			local okCfg, resolved = pcall(root.itemConfig, { name = entry.name, count = 1 })

			if okCfg and type(resolved) == "table" and type(resolved.config) == "table" then
				name = resolved.config.shortdescription or name
			end

			tooltip.title.value = name
			tooltip.description.value =
				string.format("Flavors %s.", plural(entry.weight, "treat"))

			return tooltip
		end
	end
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
	widget.registerMemberCallback(FLAVORS_LIST, "flavorRowClicked", flavorRowClicked)

	--  Cleared here and then owned by refreshSampleSlot, which applyState reaches
	--  through refreshThreshold below. Explicitly cleared first so a pane opened
	--  on a machine with no rules starts blank rather than showing whatever the
	--  widget was constructed with.
	pcall(widget.setItemSlotItem, "itemSlot_sample", nil)

	--  Establishes the initial visibility rather than trusting the "visible"
	--  flags in the config, so the two cannot disagree after an edit to either.
	showTab("instructions")

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
