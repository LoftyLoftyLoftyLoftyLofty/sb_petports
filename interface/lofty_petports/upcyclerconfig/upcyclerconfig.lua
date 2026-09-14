-- Pane for the Upcycler: edits its rules, shows its charge and progress, and lists the flavors.

require "/scripts/lofty_petports/petports_flavors.lua"
require "/scripts/lofty_petports/petports_upcyclerstate.lua"

require "/scripts/lofty_petports/petports_strings.lua"

local DEBUG = true

local PANE_BUILD_STAMP = "2026-09-14a a burn button forces the input slot by hand past every refusal, and the pane captions, reports and cancels it"

-- Returns the singular or plural string for a count of a noun.
local function counted(count, noun)
	local form = "many"
	if count == 1 then form = "one" end
	return petports_format("upcycler.count." .. noun .. "." .. form, tostring(count))
end

-- Logs a formatted line when DEBUG is set.
local function dbg(fmt, ...)
	if not DEBUG then return end
	local ok, text = pcall(string.format, fmt, ...)
	sb.logInfo("PETPORTS upcyclerpane: %s", ok and text or ("<badformat> " .. tostring(fmt)))
end

-- Returns a value printed as JSON, or a placeholder.
local function j(value)
	local ok, text = pcall(sb.printJson, value)
	return ok and text or "<unprintable>"
end

local RULES_KEY = "petports_upcyclerRules"
local ENABLED_KEY = "petports_upcyclerEnabled"

local FEEDER_KEY = "petports_upcyclerFeeder"

local RULES_LIST = "rulesScroll.rulesList"

local BLIP_ART = "/interface/lofty_petports/upcyclerconfig/blip.png"
local BLIP_COUNT = 8

local BLIP_EMPTY = "2a2a2aff"

local blipShown = {}

local RULE_ROW_ART = "/interface/lofty_petports/shared/row_164.png"
local RULE_ROW_ART_ALT = "/interface/lofty_petports/shared/row_164_alt.png"
local RULE_ROW_ART_SELECTED = "/interface/lofty_petports/shared/row_164_selected.png"

local FLAVOR_ROW_ART = "/interface/lofty_petports/shared/row_148.png"
local FLAVOR_ROW_ART_ALT = "/interface/lofty_petports/shared/row_148_alt.png"
local FLAVOR_ROW_ART_SELECTED = "/interface/lofty_petports/shared/row_148_selected.png"

local POLYMORPHIC_CONFIG = "/scripts/lofty_petports/petports_polymorphic.config"

local TAG_NO_UPCYCLING = "petports_no_upcycling"
local TAG_BEACON = "petports_beacon"

local TAG_FUEL = "petports_fuel"


-- Reads the rules, enabled and feeder parameters straight off the container object.
local function readDirect()
	if world == nil or world.getObjectParameter == nil then
		dbg("readDirect: world.getObjectParameter not available in this context")
		return nil
	end

	local id = pane.containerEntityId()
	if id == nil then return nil end

	local okRules, rules = pcall(world.getObjectParameter, id, RULES_KEY)
	local okEnabled, enabled = pcall(world.getObjectParameter, id, ENABLED_KEY)
	local okFeeder, feeder = pcall(world.getObjectParameter, id, FEEDER_KEY)

	if not okRules or not okEnabled or not okFeeder then
		dbg("readDirect: threw (rules ok=%s enabled ok=%s feeder ok=%s)",
			tostring(okRules), tostring(okEnabled), tostring(okFeeder))
		return nil
	end

	dbg("readDirect OK: rules=%s enabled=%s feeder=%s",
		j(rules), tostring(enabled), tostring(feeder))

	return {
		rules = type(rules) == "table" and rules or {},

		enabled = enabled == true,

		feeder = feeder ~= false
	}
end


-- Sends the rules, enabled and feeder state to the container object.
local function writeState()
	local id = pane.containerEntityId()

	if id == nil then
		dbg("write SKIPPED: no container entity")
		return
	end

	world.sendEntityMessage(id, "petports_upcyclerWrite", {
		rules = self.rules,
		enabled = self.enabled,
		feeder = self.feeder
	})

	dbg("write SENT: %s", j({ rules = self.rules, enabled = self.enabled }))
end


-- Loads the polymorphic display name table once.
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

-- Returns an item's display name, cached, preferring its polymorphic override.
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
				self.labels[name] = name
			end
		end
	end

	return self.labels[name]
end

local WARNING_ARGS = {
	-- Returns the labels of both items named in a deadlock verdict.
	slotsDeadlocked = function(v) return labelFor(v.item), labelFor(v.other) end
}

-- Returns the warning line for a refusal verdict.
local function warningText(verdict)
	local key = "upcycler.warn." .. string.lower(verdict.cause or "")

	if petports_string(key) == nil then
		return petports_format("upcycler.warn.generic", labelFor(verdict.item))
	end

	local args = WARNING_ARGS[verdict.cause]
	if args ~= nil then
		return petports_format(key, args(verdict))
	end

	return petports_format(key, labelFor(verdict.item))
end


-- Moves the selection onto an existing rule, or drops it when the list is empty.
local function ensureSelection()
	if #self.rules == 0 then
		self.selectedIndex = nil
		return
	end

	if self.selectedIndex == nil or self.rules[self.selectedIndex] == nil then
		self.selectedIndex = math.min(self.selectedIndex or 1, #self.rules)
	end
end

-- Sets each rule row's background to the plain, alternate or selected art.
local function paintRuleRows()
	for index, path in pairs(self.rowPaths or {}) do
		local art = RULE_ROW_ART_ALT

		if index == self.selectedIndex then
			art = RULE_ROW_ART_SELECTED
		elseif index % 2 == 1 then
			art = RULE_ROW_ART
		end

		pcall(widget.setImage, path .. ".rowBG", art)
	end
end

-- Rebuilds the rule list with each row's text, reagent button and burn button.
local function refreshRules()
	self.rebuilding = true
	widget.clearListItems(RULES_LIST)
	self.rebuilding = false

	self.rowNames = {}

	self.rowPaths = {}

	for index, rule in ipairs(self.rules) do
		local row = widget.addListItem(RULES_LIST)
		local path = RULES_LIST .. "." .. row

		self.rowNames[index] = row
		self.rowPaths[index] = path

		widget.setData(path, index)
		widget.setData(path .. ".rowRemove", index)
		widget.setData(path .. ".rowReagent", index)
		widget.setData(path .. ".rowBurn", index)

		widget.setText(path .. ".ruleText",
			string.format("%s  >  %s", labelFor(rule.item), tostring(rule.max)))

		local isReagent = petports_reagentFor(rule.item) ~= nil
		widget.setButtonEnabled(path .. ".rowReagent", isReagent)
		widget.setChecked(path .. ".rowReagent", isReagent and rule.reagent ~= false)

		widget.setChecked(path .. ".rowBurn", rule.burn ~= false)
	end

	if self.selectedIndex ~= nil and self.rowNames[self.selectedIndex] ~= nil then
		pcall(widget.setListSelected, RULES_LIST, self.rowNames[self.selectedIndex])
	end

	paintRuleRows()

	dbg("refreshRules: %s row(s), selected %s",
		tostring(#self.rules), tostring(self.selectedIndex))
end

-- Rewrites one rule row's text.
local function refreshRuleRow(index)
	local row = (self.rowNames or {})[index]
	local rule = self.rules[index]

	if row == nil or rule == nil then return end

	widget.setText(RULES_LIST .. "." .. row .. ".ruleText",
		string.format("%s  >  %s", labelFor(rule.item), tostring(rule.max)))
end

-- Writes the threshold box and records what it now shows.
local function setThresholdText(value)
	local text = value ~= nil and tostring(value) or ""

	self.shownThreshold = text
	pcall(widget.setText, "tbThreshold", text)
end

-- Puts the selected rule's item in the sample slot and sets the hint.
local function refreshSampleSlot()
	local rule = self.selectedIndex ~= nil and self.rules[self.selectedIndex] or nil

	if rule ~= nil and type(rule.item) == "string" then
		pcall(widget.setItemSlotItem, "itemSlot_sample",
			{ name = rule.item, count = 1 })
		widget.setText("sampleHint", petports_stringOr("upcycler.samplehint"))
	else
		pcall(widget.setItemSlotItem, "itemSlot_sample", nil)
		widget.setText("sampleHint", petports_stringOr("upcycler.samplehint"))
	end
end

-- Fills the threshold box and its label from the selected rule.
local function refreshThreshold()
	local rule = self.selectedIndex ~= nil and self.rules[self.selectedIndex] or nil

	if rule ~= nil then
		setThresholdText(rule.max)
		widget.setText("thresholdLabel", petports_stringOr("upcycler.threshold"))
	else
		widget.setText("thresholdLabel", petports_stringOr("upcycler.thresholdnew"))
	end

	refreshSampleSlot()
end

-- Reads the threshold box and stores it on the selected rule when it changed.
local function syncThreshold()
	if not self.fieldUsable then return end

	local ok, text = pcall(widget.getText, "tbThreshold")

	if not ok or type(text) ~= "string" then
		self.fieldUsable = false
		sb.logError("petports: upcycler pane cannot read tbThreshold; "
			.. "threshold entry is disabled for this pane")
		return
	end

	if text == self.shownThreshold then return end
	self.shownThreshold = text

	if text == "" then return end

	local rule = self.selectedIndex ~= nil and self.rules[self.selectedIndex] or nil

	if rule == nil then return end

	local value = tonumber(text)
	if value == nil or rule.max == value then return end

	rule.max = value
	dbg("threshold: %s -> %s", rule.item, tostring(value))

	refreshRuleRow(self.selectedIndex)
	writeState()
end


-- Stores the enabled checkbox and writes.
function enabledToggled()
	self.enabled = widget.getChecked("enabledCheckbox") == true
	dbg("enabledToggled -> %s", tostring(self.enabled))
	writeState()
end

-- Stores the feeder checkbox and writes.
function feederToggled()
	self.feeder = widget.getChecked("feederCheckbox") == true
	dbg("feederToggled -> %s", tostring(self.feeder))
	writeState()
end

-- Returns the threshold box as a number.
local function thresholdValue()
	local ok, text = pcall(widget.getText, "tbThreshold")
	if not ok then return nil end

	return tonumber(text)
end

-- Records the selected rule and redraws the rows and the threshold.
function ruleSelected()
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

	paintRuleRows()
	refreshThreshold()
end

-- Adds a rule for the item on the cursor and switches the machine off, or selects the rule it already has.
function sampleSlotClicked()
	local swap = player.swapSlotItem()

	dbg("sampleSlotClicked: cursor holds %s", j(swap))

	if type(swap) ~= "table" or type(swap.name) ~= "string" then
		return
	end

	player.setSwapSlotItem(swap)

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

	table.insert(self.rules, { item = swap.name, max = 0 })

	self.selectedIndex = #self.rules

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

-- Drops the selection.
function sampleSlotCleared()
	self.selectedIndex = nil

	refreshRules()
	refreshThreshold()
end

-- Syncs the threshold box.
function thresholdChanged()
	syncThreshold()
end


-- Removes a rule and writes.
local function ruleRowRemove(_, rowIndex)
	dbg("ruleRowRemove fired with data=%s (%s)", tostring(rowIndex), type(rowIndex))

	local index = tonumber(rowIndex)
	if index == nil or self.rules[index] == nil then return end

	table.remove(self.rules, index)

	self.selectedIndex = index
	ensureSelection()

	refreshRules()
	refreshThreshold()
	writeState()
end


-- Returns the item in the input grid, or nil.
local function inputItem()
	local ok, items = pcall(widget.itemGridItems, "itemGrid")
	if not ok or type(items) ~= "table" then return nil end

	local candidate = items[1]

	if type(candidate) == "table" and type(candidate.name) == "string" then
		return candidate
	end

	return nil
end

-- Returns the rule naming an item, or nil.
local function ruleFor(name)
	for _, rule in ipairs(self.rules or {}) do
		if rule.item == name then return rule end
	end

	return nil
end

-- Returns every item across the input, reagent and output grids.
local function allSlotItems()
	local items = {}

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

-- Returns whether an item carries an item tag, cached.
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

-- Shows the warning text and icon.
local function showWarning(text)
	widget.setText("warnText", text)
	widget.setVisible("warnText", true)
	widget.setVisible("warnIcon", true)
end

-- Hides the warning text and icon.
local function hideWarning()
	widget.setVisible("warnText", false)
	widget.setVisible("warnIcon", false)
end

-- Sets the burn button's caption and enabled state from the forced item and the input slot.
local function refreshBurnButton(input)
	local forced = type(self.forcedName) == "string"

	local caption = petports_stringOr(forced and "upcycler.burn.stop"
		or "upcycler.burn.now")

	if caption ~= self.burnCaption then
		self.burnCaption = caption
		pcall(widget.setText, "btnBurnNow", caption)
	end

	local usable = forced or input ~= nil

	if usable ~= self.burnUsable then
		self.burnUsable = usable
		pcall(widget.setButtonEnabled, "btnBurnNow", usable)
	end
end

-- Updates the burn button, the warning line and the status line from the slot contents.
function refreshStatus()
	if not self.loaded then return end

	local input = inputItem()

	refreshBurnButton(input)

	for _, item in ipairs(allSlotItems()) do
		if hasTag(item.name, TAG_BEACON) then
			showWarning(petports_stringOr("upcycler.warn.beacon"))
			return
		end
	end

	local verdict = petports_upcyclerVerdict({
		input = input ~= nil and input.name or nil,
		reagent = type(self.reagentName) == "string" and self.reagentName or nil,
		output = type(self.outputName) == "string" and self.outputName or nil,

		charges = tonumber(self.blipCount) or 0,

		forced = self.forcedName,

		ruleFor = ruleFor
	})

	if verdict ~= nil then
		local said = warningText(verdict)

		if said ~= nil then
			showWarning(said)
		else
			showWarning(string.format("%s is stopping the machine.",
				labelFor(verdict.item)))
		end

		return
	end

	hideWarning()

	if type(self.forcedName) == "string" then
		widget.setText("lblStatus",
			petports_format("upcycler.status.forced", labelFor(self.forcedName)))
		return
	end

	if not self.enabled then
		widget.setText("lblStatus",
			petports_format("upcycler.status.off", counted(#self.rules, "rule")))
		return
	end

	if input == nil then
		widget.setText("lblStatus",
			petports_format("upcycler.status.idle", counted(#self.rules, "rule")))
		return
	end

	widget.setText("lblStatus", petports_format("upcycler.status.converting",
		counted(#self.rules, "rule"), labelFor(input.name)))
end


local PROGRESS_STEPS = 20

local PROGRESS_INTERVAL = 0.25

-- Returns the charge queue as a plain array of at most the blip count.
local function blipSequence(queue)
	if type(queue) ~= "table" then return {} end

	local out = {}
	for index = 1, BLIP_COUNT do
		local flavor = queue[index]
		if flavor == nil then flavor = queue[tostring(index)] end
		if flavor == nil then break end
		out[index] = flavor
	end
	return out
end

-- Tints each blip to its flavor's colour, or to the empty colour.
local function refreshBlips(queue)
	queue = blipSequence(queue)

	for index = 1, BLIP_COUNT do
		local flavor = queue[index]

		local tint = flavor ~= nil and petports_flavorColor(flavor) or BLIP_EMPTY

		if blipShown[index] ~= tint then
			blipShown[index] = tint
			pcall(widget.setImage, "blip" .. index, BLIP_ART .. "?multiply=" .. tint)
		end

		pcall(widget.setVisible, "blip" .. index, true)
	end
end

-- Polls the machine on an interval and takes the points, blips and slot names from its reply.
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

			local step = math.floor(fraction * PROGRESS_STEPS)

			if step ~= self.progressStep then
				self.progressStep = step
				widget.setImage("progressBar", string.format(
					"/interface/lofty_petports/upcyclerconfig/progressbar.png:p%d", step))
			end

			widget.setText("progressLabel", petports_format("upcycler.progress",
				tostring(self.points), tostring(self.pointsPerFuel)))

			refreshBlips(result.blips)

			self.blipCount = #blipSequence(result.blips)

			self.reagentName = result.reagent
			self.outputName = result.output

			self.forcedName = type(result.forced) == "string" and result.forced
				or nil
		end
	end

	if self.progressTimer > 0 or self.progressPromise ~= nil then return end

	self.progressTimer = PROGRESS_INTERVAL

	local id = pane.containerEntityId()
	if id == nil then return end

	self.progressPromise = world.sendEntityMessage(id, "petports_upcyclerRead")
end


-- Takes a read state into the pane and redraws everything.
local function applyState(state)
	self.rules = {}

	for _, rule in ipairs(type(state.rules) == "table" and state.rules or {}) do
		if type(rule) == "table" and type(rule.item) == "string" and rule.item ~= "" then
			table.insert(self.rules, {
				item = rule.item,
				max = tonumber(rule.max) or 0,
				reagent = rule.reagent,
				burn = rule.burn
			})
		end
	end

	self.enabled = state.enabled == true
	self.loaded = true

	widget.setChecked("enabledCheckbox", self.enabled)

	self.feeder = state.feeder == true
	widget.setChecked("feederCheckbox", self.feeder)

	ensureSelection()

	refreshRules()
	refreshThreshold()

	refreshStatus()
end


local FLAVORS_LIST = "flavorsScroll.flavorsList"
local REAGENTS_LIST = "reagentsScroll.reagentsList"

local activeTab = "instructions"

local shownFlavors = {}

local flavorByRow = {}
local flavorRowPath = {}
local flavorRowIndex = {}
local selectedRow = nil

local shownReagentFlavor = nil

local rebuildingFlavors = false

local FLAVOR_WIDGETS = { "flavorsScroll", "reagentsLabel", "reagentsScroll" }
local INSTRUCTION_WIDGETS = { "instructionsText" }

-- Sets the visibility of a list of widgets.
local function setWidgetsVisible(names, shown)
	for _, name in ipairs(names) do
		local ok, err = pcall(widget.setVisible, name, shown)
		if not ok then
			dbg("setVisible %s -> %s FAILED: %s", name, tostring(shown), tostring(err))
		end
	end
end

-- Sets each flavor row's background to the plain, alternate or selected art.
local function paintFlavorRows()
	for rowId, path in pairs(flavorRowPath) do
		local art = FLAVOR_ROW_ART_ALT

		if rowId == selectedRow then
			art = FLAVOR_ROW_ART_SELECTED
		elseif (flavorRowIndex[rowId] or 0) % 2 == 1 then
			art = FLAVOR_ROW_ART
		end

		pcall(widget.setImage, path .. ".rowBG", art)
	end
end

-- Rebuilds the reagent cells for a flavor and sets the heading.
local function refreshReagents(flavor)
	local wantId = flavor ~= nil and flavor.id or nil
	if wantId == shownReagentFlavor then return end
	shownReagentFlavor = wantId

	rebuildingFlavors = true
	widget.clearListItems(REAGENTS_LIST)
	rebuildingFlavors = false

	if flavor == nil then
		widget.setText("reagentsLabel", petports_stringOr("upcycler.flavors.prompt"))
		return
	end

	local reagents = petports_flavorReagents(flavor.id)

	for _, entry in ipairs(reagents) do
		local rowId = widget.addListItem(REAGENTS_LIST)
		local path = string.format("%s.%s", REAGENTS_LIST, rowId)

		local ok, err = pcall(function()
			widget.setItemSlotItem(path .. ".icon", { name = entry.name, count = 1 })
			widget.setText(path .. ".weight", tostring(entry.weight))
		end)

		if not ok then
			dbg("reagent cell %s FAILED: %s", entry.name, tostring(err))
		end
	end

	widget.setText("reagentsLabel",
		petports_format("upcycler.flavors.selected", flavor.label or flavor.id,
			counted(#reagents, "reagent")))

	dbg("refreshReagents: %s, %d cell(s)", tostring(flavor.id), #reagents)
end

-- Rebuilds the flavor list with each row's label and item icon.
local function refreshFlavors()
	rebuildingFlavors = true
	widget.clearListItems(FLAVORS_LIST)
	rebuildingFlavors = false

	flavorByRow = {}
	flavorRowPath = {}
	flavorRowIndex = {}
	selectedRow = nil

	shownReagentFlavor = nil

	shownFlavors = petports_flavors()

	for index, flavor in ipairs(shownFlavors) do
		local rowId = widget.addListItem(FLAVORS_LIST)
		local path = string.format("%s.%s", FLAVORS_LIST, rowId)

		flavorByRow[rowId] = flavor
		flavorRowPath[rowId] = path
		flavorRowIndex[rowId] = index

		local ok, err = pcall(function()
			widget.setData(path .. ".rowButton", rowId)


			widget.setText(path .. ".rowLabel",
				petports_format("upcycler.flavors.row", flavor.label or flavor.id,
					tostring(#petports_flavorReagents(flavor.id))))

			local item = petports_flavorItem(flavor.id)

			if item ~= nil then
				local okCfg, resolved = pcall(root.itemConfig, { name = item, count = 1 })

				if okCfg and type(resolved) == "table"
				   and type(resolved.config) == "table"
				   and type(resolved.config.inventoryIcon) == "string" then

					local icon = resolved.config.inventoryIcon

					if icon:sub(1, 1) ~= "/" then
						icon = tostring(resolved.directory or "") .. icon
					end

					widget.setImage(path .. ".icon", icon)
				else
					dbg("flavor %s: no icon for %s",
						tostring(flavor.id), tostring(item))
				end
			end

		end)

		if not ok then
			dbg("flavor row %d FAILED: %s", index, tostring(err))
		end
	end

	paintFlavorRows()
	dbg("refreshFlavors: %d flavor(s)", #shownFlavors)
end

-- Shows the instructions or flavors widgets and sets the tab checkboxes.
local function showTab(which)
	activeTab = which

	setWidgetsVisible(INSTRUCTION_WIDGETS, which == "instructions")
	setWidgetsVisible(FLAVOR_WIDGETS, which == "flavors")

	pcall(widget.setChecked, "tabInstructions", which == "instructions")
	pcall(widget.setChecked, "tabFlavors", which == "flavors")

	dbg("showTab: %s", tostring(which))
end

-- Asks the machine to discard its charge.
function clearChargeClicked()
	local id = pane.containerEntityId()
	if id == nil then return end

	dbg("clearChargeClicked: asking %s to discard its charge", tostring(id))
	world.sendEntityMessage(id, "petports_upcyclerClearCharge")
end

-- Asks the machine to force-burn the input item, or to stop the forced burn.
function burnNowClicked()
	local id = pane.containerEntityId()
	if id == nil then return end

	if type(self.forcedName) == "string" then
		dbg("burnNowClicked: asking %s to STOP forcing %s", tostring(id),
			self.forcedName)

		world.sendEntityMessage(id, "petports_upcyclerBurnNow",
			{ item = self.forcedName })

		return
	end

	local held = inputItem()

	if held == nil then
		dbg("burnNowClicked: input slot is empty, nothing to force")
		return
	end

	dbg("burnNowClicked: asking %s to force-burn %s", tostring(id), held.name)

	world.sendEntityMessage(id, "petports_upcyclerBurnNow",
		{ item = held.name })
end

-- Shows the instructions tab.
function tabInstructionsClicked()
	showTab("instructions")
end

-- Shows the flavors tab, building the list on first use.
function tabFlavorsClicked()
	showTab("flavors")

	if #shownFlavors == 0 then refreshFlavors() end
end

-- Records the selected flavor row and shows its reagents.
local function selectFlavorRow(rowId, from)
	if rebuildingFlavors then return end

	local flavor = rowId ~= nil and flavorByRow[rowId] or nil
	selectedRow = rowId

	dbg("selectFlavorRow (%s): row %s -> %s", tostring(from),
		tostring(rowId), flavor ~= nil and tostring(flavor.id) or "none")

	paintFlavorRows()
	refreshReagents(flavor)
end

-- Flips a rule's reagent routing and writes.
local function ruleReagentToggled(_, index)
	index = tonumber(index)
	local rule = index and self.rules[index]

	if rule == nil then
		dbg("reagent toggle ignored: no rule at index %s", tostring(index))
		return
	end

	local nowAllowed = rule.reagent == false

	if nowAllowed then
		rule.reagent = nil
	else
		rule.reagent = false
	end

	local path = self.rowPaths[index]
	if path ~= nil then
		widget.setChecked(path .. ".rowReagent", nowAllowed)
	end

	dbg("reagent routing for %s -> %s", tostring(rule.item),
		nowAllowed and "reagent slot" or "burner only")

	writeState()
end

-- Flips a rule's burner entry and writes.
local function ruleBurnToggled(_, index)
	index = tonumber(index)
	local rule = index and self.rules[index]

	if rule == nil then
		dbg("burn toggle ignored: no rule at index %s", tostring(index))
		return
	end

	local nowAllowed = rule.burn == false

	if nowAllowed then
		rule.burn = nil
	else
		rule.burn = false
	end

	local path = self.rowPaths[index]
	if path ~= nil then
		widget.setChecked(path .. ".rowBurn", nowAllowed)
	end

	dbg("burner entry for %s -> %s", tostring(rule.item),
		nowAllowed and "allowed" or "denied")

	writeState()
end

-- Selects a flavor row.
local function flavorRowClicked(_, rowId)
	selectFlavorRow(rowId, "row")
end



-- Clears the pane state, registers the row callbacks, shows the instructions tab and reads the machine.
function init()
	sb.logInfo("PETPORTS upcyclerconfig build: %s", PANE_BUILD_STAMP)

	petports_applyStrings()

	blipShown = {}

	self.rules = {}
	self.enabled = false
	self.loaded = false

	self.selectedIndex = nil
	self.rowNames = {}

	self.shownThreshold = ""
	self.fieldUsable = true
	self.tagCache = {}

	self.forcedName = nil
	self.burnCaption = nil
	self.burnUsable = nil

	self.points = 0
	self.pointsPerFuel = 1000
	self.progressStep = -1
	self.progressTimer = 0

	dbg("init: containerEntityId=%s", tostring(pane.containerEntityId()))

	dbg("probe: player=%s swapSlotItem=%s setSwapSlotItem=%s",
		type(player),
		type(player) == "table" and type(player.swapSlotItem) or "n/a",
		type(player) == "table" and type(player.setSwapSlotItem) or "n/a")

	widget.registerMemberCallback(RULES_LIST, "ruleRowRemove", ruleRowRemove)
	widget.registerMemberCallback(RULES_LIST, "ruleReagentToggled", ruleReagentToggled)
	widget.registerMemberCallback(RULES_LIST, "ruleBurnToggled", ruleBurnToggled)
	widget.registerMemberCallback(FLAVORS_LIST, "flavorRowClicked", flavorRowClicked)

	pcall(widget.setItemSlotItem, "itemSlot_sample", nil)

	showTab("instructions")

	local direct = readDirect()

	if direct ~= nil then
		applyState(direct)
	else
		widget.setText("lblStatus", petports_stringOr("upcycler.status.unreadable"))
	end
end

local LIGHT_WIDGET = "runningLight"
local LIGHT_ON = "/interface/lofty_petports/upcyclerconfig/light_on.png"
local LIGHT_OFF = "/interface/lofty_petports/upcyclerconfig/light_off.png"

local FLARE_SECONDS = 2.2
local FLICKER_HZ = 9
local BREATHE_HZ = 0.7
local BREATHE_FLOOR = 0.45

-- Returns a 0-1 level as a two-digit alpha byte.
local function alphaHex(level)
	local byte = math.floor(math.max(0, math.min(1, level)) * 255 + 0.5)
	return string.format("%02x", byte)
end

-- Paints the running light: flickering after a switch, steady while on, breathing while off.
local function paintLight(dt)
	local enabled = self.enabled == true

	if self.lightWas == nil then
		self.lightWas = enabled
		self.lightFlare = 0
	elseif self.lightWas ~= enabled then
		self.lightWas = enabled
		self.lightFlare = FLARE_SECONDS
	end

	self.lightFlare = math.max(0, (self.lightFlare or 0) - (dt or 0))
	self.lightClock = ((self.lightClock or 0) + (dt or 0)) % 3600

	local level

	if self.lightFlare > 0 then
		local phase = math.floor(self.lightClock * FLICKER_HZ) % 2
		level = phase == 0 and 1.0 or 0.15
	elseif enabled then
		level = 1.0
	else
		local wave = (math.sin(self.lightClock * BREATHE_HZ * 2 * math.pi) + 1) / 2
		level = BREATHE_FLOOR + wave * (1 - BREATHE_FLOOR)
	end

	local file = enabled and LIGHT_ON or LIGHT_OFF
	local directive = string.format("%s?multiply=ffffff%s", file, alphaHex(level))

	if directive ~= self.lightPainted then
		self.lightPainted = directive
		pcall(widget.setImage, LIGHT_WIDGET, directive)
	end
end

-- Paints the light, syncs the threshold, and refreshes the status and the progress.
function update(dt)
	paintLight(dt)
	syncThreshold()
	refreshStatus()
	refreshProgress(dt)
end
