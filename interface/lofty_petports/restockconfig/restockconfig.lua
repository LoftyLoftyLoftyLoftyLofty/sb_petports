-- Pane for a Restock Beacon: edits its enabled flag and its list of item requests.

local HOLD_CHECK_INTERVAL = 0.25

local AWAY_LIMIT = 4

local DEBUG = false

require "/scripts/lofty_petports/petports_strings.lua"

require "/scripts/lofty_petports/petports_paneicon.lua"

local PANE_ICONS = {
	on  = "/interface/lofty_petports/restockconfig/paneicon_restock_on.png",
	off = "/interface/lofty_petports/restockconfig/paneicon_restock_off.png"
}

local BUILD_STAMP = "2026-09-15b add request by item id, summary retired"

local QUOTA_CEILING = 99999

local ASSUMED_MAX_STACK = 1000

local SUMMARY_CHARS = 46

local ROW_CHARS = 30

local SELECTED_COLOR = "^yellow;"

local ROW_ART = "/interface/lofty_petports/shared/row_180.png"
local ROW_ART_ALT = "/interface/lofty_petports/shared/row_180_alt.png"
local ROW_ART_SELECTED = "/interface/lofty_petports/shared/row_180_selected.png"

local QUOTA_FIELDS = { "min", "max" }
local FIELD_WIDGET = { min = "tbMin", max = "tbMax" }

local REQUESTS_LIST = "requestsScroll.requestsList"

-- Logs a formatted line when DEBUG is set.
local function dbg(fmt, ...)
	if not DEBUG then return end
	local ok, text = pcall(string.format, fmt, ...)
	sb.logInfo("petports restock pane: %s", ok and text or ("<badformat> " .. tostring(fmt)))
end

-- Returns a value printed as JSON, or a placeholder.
local function j(value)
	if value == nil then return "nil" end
	local ok, text = pcall(sb.printJson, value)
	if ok then return text end
	return "<unprintable " .. type(value) .. ">"
end

local rowIds = {}

local rowPaths = {}
local rowStripes = {}


-- Returns the beacon's answer to the held check.
local function beaconAnswer()
	local promise = world.sendEntityMessage(player.id(), "petports_beaconHeld", self.token)
	return promise:result()
end

-- Returns whether the player's swap slot holds an item.
local function cursorOccupied()
	local ok, swap = pcall(player.swapSlotItem)
	return ok and type(swap) == "table" and swap.name ~= nil
end

local CLEARED_FIELDS = { "requests", "item", "min", "max" }

-- Returns the instance fields the beacon should clear, or nil.
local function clearList()
	local out = nil

	for _, field in ipairs(CLEARED_FIELDS) do
		local gone = field ~= "requests"
			or type(self.state.requests) ~= "table"
			or #self.state.requests == 0

		if gone then
			out = out or {}
			table.insert(out, field)
		end
	end

	return out
end

-- Sends the enabled flag and the requests to the beacon, holding the write when it is refused.
local function write()
	local clear = clearList()

	local requests = nil

	if type(self.state.requests) == "table" and #self.state.requests > 0 then
		requests = {}

		for _, request in ipairs(self.state.requests) do
			table.insert(requests, {
				item = request.item,
				min = request.min,
				max = request.max
			})
		end
	end

	local payload = { enabled = self.state.enabled, requests = requests }

	local promise = world.sendEntityMessage(player.id(), "petports_beaconWrite",
		self.token, payload, clear)

	local accepted = promise:result()

	if accepted == true then
		self.pendingWrite = false
		dbg("write OK payload=%s clear=%s", j(payload), j(clear))
		return true
	end

	self.pendingWrite = true
	dbg("write HELD result=%s payload=%s", j(accepted), j(payload))
	return false
end


-- Returns an item's short description and max stack, or nil.
local function itemFacts(name)
	if type(name) ~= "string" or name == "" then return nil end

	local ok, resolved = pcall(root.itemConfig, { name = name, count = 1 })

	if not ok or type(resolved) ~= "table" or type(resolved.config) ~= "table" then
		dbg("itemFacts(%s): unresolvable", tostring(name))
		return nil
	end

	return {
		label = resolved.config.shortdescription or name,
		maxStack = tonumber(resolved.config.maxStack) or ASSUMED_MAX_STACK
	}
end

local POLYMORPHIC_CONFIG = "/scripts/lofty_petports/petports_polymorphic.config"

-- Loads the polymorphic display name table once.
local function polymorphicNames()
	if self.polymorphic ~= nil then return self.polymorphic end

	local ok, data = pcall(root.assetJson, POLYMORPHIC_CONFIG)

	if not ok or type(data) ~= "table" or type(data.displayNames) ~= "table" then
		sb.logError("petports: polymorphic name table unreadable at %s; request "
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
			local facts = itemFacts(name)
			self.labels[name] = (facts and facts.label) or name
		end
	end

	return self.labels[name]
end

-- Returns a whole number inside the quota range, or nil.
local function quotaValue(text)
	local value = tonumber(text)
	if value == nil then return nil end

	value = math.floor(value)
	if value < 1 or value > QUOTA_CEILING then return nil end

	return value
end

-- Shortens text to a character limit.
local function truncate(text, limit)
	limit = limit or SUMMARY_CHARS
	if #text <= limit then return text end

	if limit < 3 then return "" end

	return text:sub(1, limit - 2) .. ".."
end

-- Returns the selected request.
local function selected()
	if self.selectedIndex == nil then return nil end
	return self.state.requests[self.selectedIndex]
end

-- Moves the selection onto an existing request, or drops it when the list is empty.
local function ensureSelection()
	if #self.state.requests == 0 then
		self.selectedIndex = nil
		return
	end

	if self.selectedIndex == nil
	   or self.state.requests[self.selectedIndex] == nil then
		self.selectedIndex = math.min(self.selectedIndex or 1, #self.state.requests)
	end
end

-- Returns the index of the request for an item, or nil.
local function indexOf(name)
	for index, request in ipairs(self.state.requests) do
		if request.item == name then return index end
	end

	return nil
end


-- Writes a quota text box and records what it now shows.
local function setField(field, value)
	local text = value ~= nil and tostring(value) or ""

	self.shownText[field] = text
	pcall(widget.setText, FIELD_WIDGET[field], text)
end

-- Fills the min and max boxes from the selected request.
local function renderFields()
	local request = selected()

	if request == nil then
		setField("min", nil)
		setField("max", nil)
	else
		setField("min", request.min)
		setField("max", request.max)
	end
end

-- Sets the item slot, the request count and the hint.
local function renderSlot()
	local count = #self.state.requests
	local request = selected()

	if request ~= nil and type(request.item) == "string" then
		pcall(widget.setItemSlotItem, "itemSlot_request",
			{ name = request.item, count = 1 })
	else
		pcall(widget.setItemSlotItem, "itemSlot_request", nil)
	end

	if count == 0 then
		widget.setText("requestName", petports_stringOr("restock.none"))
	else
		widget.setText("requestName", petports_format("restock.count", tostring(count)))
	end

	widget.setText("requestHint", petports_stringOr("restock.hint"))
end

-- Sets each request row's text and background art.
local function paintRows()
	for index, path in pairs(rowPaths) do
		local request = self.state.requests[index]

		if request ~= nil then
			local text = truncate(labelFor(request.item), ROW_CHARS)
			local art = ROW_ART_ALT

			if index == self.selectedIndex then
				text = SELECTED_COLOR .. text
				art = ROW_ART_SELECTED
			elseif (rowStripes[index] or 0) % 2 == 1 then
				art = ROW_ART
			end

			pcall(widget.setText, path .. ".rowText", text)
			pcall(widget.setImage, path .. ".rowBG", art)
		end
	end
end

-- Rebuilds the request list, keeping the selection where it can and skipping items the filter does not match.
local function refreshRequests()
	local keep = self.selectedIndex

	self.rebuilding = true
	widget.clearListItems(REQUESTS_LIST)

	rowIds = {}
	rowPaths = {}
	rowStripes = {}

	local needle = string.lower(self.filterText or "")
	local shown = 0

	for index, request in ipairs(self.state.requests) do
		if needle == "" or string.find(string.lower(request.item), needle, 1, true) ~= nil then
			local rowId = widget.addListItem(REQUESTS_LIST)
			rowIds[rowId] = index

			shown = shown + 1

			local path = string.format("%s.%s", REQUESTS_LIST, rowId)

			widget.setData(path .. ".rowRemove", index)

			rowPaths[index] = path
			rowStripes[index] = shown
		end
	end

	self.rebuilding = false

	if keep ~= nil and self.state.requests[keep] ~= nil then
		for rowId, at in pairs(rowIds) do
			if at == keep then
				widget.setListSelected(REQUESTS_LIST, rowId)
				break
			end
		end
	else
		ensureSelection()
	end

	paintRows()

	dbg("refreshRequests: %s of %s row(s) shown for filter '%s', selection %s",
		tostring(shown), tostring(#self.state.requests), needle,
		tostring(self.selectedIndex))
end

-- Redraws the slot, the list and the fields.
local function renderAll()
	renderSlot()
	refreshRequests()
	renderFields()
end


-- Adds a request for an item with quotas from its stack size, or selects the one already listed.
local function addRequest(name)
	local existing = indexOf(name)

	if existing ~= nil then
		dbg("addRequest(%s): already listed at %s, selecting it",
			tostring(name), tostring(existing))
		self.selectedIndex = existing
		return false
	end

	local facts = itemFacts(name)
	local stack = (facts and facts.maxStack) or ASSUMED_MAX_STACK

	local max = math.max(1, math.min(stack, QUOTA_CEILING))

	table.insert(self.state.requests, {
		item = name,
		max = max,
		min = math.max(1, math.floor(max / 2))
	})

	self.selectedIndex = #self.state.requests

	dbg("addRequest(%s): stack=%s -> min=%s max=%s (%s total)",
		tostring(name), tostring(stack),
		tostring(self.state.requests[self.selectedIndex].min),
		tostring(max), tostring(#self.state.requests))

	return true
end

-- Removes a request and moves the selection.
local function removeRequest(index)
	if self.state.requests[index] == nil then return false end

	dbg("removeRequest(%s): %s", tostring(index),
		tostring(self.state.requests[index].item))

	table.remove(self.state.requests, index)

	self.selectedIndex = index
	ensureSelection()

	return true
end


-- Stores a valid quota on the selected request and writes.
local function commitField(field, text)
	local request = selected()
	if request == nil then return end

	local value = quotaValue(text)

	if value == nil or value == request[field] then return end

	request[field] = value

	dbg("commitField(%s, %s) -> %s is %s-%s", field, tostring(text),
		tostring(request.item), tostring(request.min), tostring(request.max))

	write()
end

-- Reads a quota box and commits it when its text changed.
local function syncField(field)
	if type(self.state) ~= "table" then return end
	if not self.fieldsUsable then return end

	local ok, text = pcall(widget.getText, FIELD_WIDGET[field])

	if not ok or type(text) ~= "string" then
		self.fieldsUsable = false
		sb.logError("petports: restock pane cannot read %s; quota entry is "
			.. "disabled for this pane", FIELD_WIDGET[field])
		return
	end

	if selected() == nil then
		if text ~= "" then setField(field, nil) end
		return
	end

	if text ~= self.shownText[field] then
		self.shownText[field] = text
		commitField(field, text)
	end
end

-- Syncs both quota boxes.
local function pollFields()
	for _, field in ipairs(QUOTA_FIELDS) do
		syncField(field)
	end
end


-- Registers the remove and hover member callbacks on the request list.
local function registerRowCallbacks()
	local ok, err = pcall(function()
		widget.registerMemberCallback(REQUESTS_LIST,
			"requestRowRemove", function(_, data)
				local index = tonumber(data)

				dbg("requestRowRemove: data=%s -> index=%s", j(data), tostring(index))

				if index == nil then return end
				if not removeRequest(index) then return end

				write()
				renderAll()
			end)

		widget.registerMemberCallback(REQUESTS_LIST, "rowHovered", rowHovered)
	end)

	if ok then
		dbg("registered row member callbacks on requestsList")
	else
		sb.logError("petports: registerMemberCallback failed (%s) -- request "
			.. "rows carrying buttons will throw on addListItem", tostring(err))
	end

	return ok
end


-- Converts a stored single item, min and max into a one-entry request list.
local function migrate()
	if type(self.state.requests) == "table" and #self.state.requests > 0 then
		return false
	end

	local name = self.state.item
	if type(name) ~= "string" or name == "" then return false end

	local max = quotaValue(self.state.max)
		or math.max(1, math.min((itemFacts(name) or {}).maxStack or ASSUMED_MAX_STACK,
			QUOTA_CEILING))

	self.state.requests = { {
		item = name,
		min = quotaValue(self.state.min) or 1,
		max = max
	} }

	sb.logInfo("PETPORTS restock pane: migrated single request %s (%s-%s) to a list",
		tostring(name), tostring(self.state.requests[1].min), tostring(max))

	return true
end


-- Returns whether the beacon that opened this pane is on the cursor.
local function openedFromCursor()
	local expected = config.getParameter("beaconItemName")
	if type(expected) ~= "string" then return false end

	local ok, swap = pcall(player.swapSlotItem)

	return ok and type(swap) == "table" and swap.name == expected
end

-- Hides every editing widget and shows the hotbar-only notice.
local function lockWithNotice()
	local messages = config.getParameter("hotbarOnlyMessage") or {}
	local species = nil

	local ok, value = pcall(player.species)
	if ok and type(value) == "string" then species = value end

	local message = (species ~= nil and messages[species]) or messages["default"]

	if type(message) == "string" then message = { message } end

	if type(message) ~= "table" then
		message = { "This must be used from the hotbar." }
	end

	sb.logInfo("PETPORTS restock pane: opened from the cursor (species %s); refusing",
		tostring(species))

	for _, name in ipairs({
		"slotBacking", "itemSlot_request", "requestHeading", "requestName",
		"requestHint", "enabledCheckbox", "enabledLabel", "minLabel", "maxLabel",
		"minFieldBacking", "maxFieldBacking", "tbMin", "tbMax",
		"nameBacking", "tbAddName", "btnAddByName",
		"requestsScroll", "requestFilterLabel", "requestFilterBacking",
		"tbRequestFilter", "btnClearFilter"
	}) do
		pcall(widget.setVisible, name, false)
	end

	widget.setVisible("noticeTitle", true)
	widget.setVisible("noticeLineOne", true)
	widget.setVisible("noticeLineTwo", true)

	widget.setText("noticeTitle", petports_stringOr("restock.blockedtitle"))
	widget.setText("noticeLineOne", truncate(tostring(message[1] or "")))
	widget.setText("noticeLineTwo", truncate(tostring(message[2] or "")))
end

-- Reads the beacon's config, cleans the requests, seeds the checkboxes and draws the pane.
function init()
	sb.logInfo("PETPORTS restockconfig build: %s", BUILD_STAMP)

	petports_applyStrings()

	self.holdTimer = 0
	self.fieldsUsable = true

	self.noticeMode = false

	self.shownText = { min = "", max = "" }
	self.selectedIndex = nil
	self.filterText = ""
	self.labels = {}

	self.pendingWrite = false

	self.reachable = true
	self.awayTicks = 0

	for _, name in ipairs({ "noticeTitle", "noticeLineOne", "noticeLineTwo" }) do
		pcall(widget.setVisible, name, false)
	end

	if openedFromCursor() then
		self.noticeMode = true
		lockWithNotice()
		return
	end

	dbg("init: asking held item for its config")

	local promise = world.sendEntityMessage(player.id(), "petports_beaconRead")
	self.state = promise:result()

	dbg("init: read returned %s", j(self.state))

	if type(self.state) ~= "table" or self.state.token == nil then
		sb.logError("petports: restock pane opened with no readable beacon; dismissing")
		self.state = nil
		pane.dismiss()
		return
	end

	self.token = self.state.token
	self.state.token = nil

	if type(self.state.requests) ~= "table" then
		self.state.requests = {}
	end

	local clean = {}

	for _, request in ipairs(self.state.requests) do
		if type(request) == "table" and type(request.item) == "string"
		   and request.item ~= "" then
			table.insert(clean, {
				item = request.item,
				min = quotaValue(request.min) or 1,
				max = quotaValue(request.max) or ASSUMED_MAX_STACK
			})
		end
	end

	self.state.requests = clean

	local migrated = migrate()

	dbg("init: token=%s enabled=%s requests=%s",
		tostring(self.token), tostring(self.state.enabled), j(self.state.requests))

	widget.setChecked("enabledCheckbox", self.state.enabled ~= false)

	petports_applyPaneIcon(PANE_ICONS, self.state.enabled)

	widget.setChecked("feederCheckbox", self.state.feeder ~= false)

	registerRowCallbacks()

	ensureSelection()

	renderAll()

	if migrated then write() end

	dbg("init: complete")
end

-- Polls the quota boxes, flushes a held write, and dismisses the pane once the beacon is gone.
function update(dt)
	if self.noticeMode then
		self.holdTimer = self.holdTimer - dt
		if self.holdTimer > 0 then return end
		self.holdTimer = HOLD_CHECK_INTERVAL

		if not openedFromCursor() then
			dbg("notice: beacon no longer on the cursor -- dismissing")
			pane.dismiss()
		end

		return
	end

	if type(self.state) ~= "table" then return end

	pollFields()

	self.holdTimer = self.holdTimer - dt
	if self.holdTimer > 0 then return end
	self.holdTimer = HOLD_CHECK_INTERVAL

	local answer = beaconAnswer()
	local reachable = answer == true

	if reachable ~= self.reachable then
		self.reachable = reachable

		dbg("beacon %s (answer=%s, cursor=%s)",
			reachable and "reachable" or "UNREACHABLE",
			j(answer), tostring(cursorOccupied()))
	end

	if reachable then
		self.awayTicks = 0

		if self.pendingWrite then
			dbg("flushing held write")
			write()
		end

		return
	end

	if cursorOccupied() then
		self.awayTicks = 0
		return
	end

	self.awayTicks = (self.awayTicks or 0) + 1
	if self.awayTicks < AWAY_LIMIT then return end

	if self.pendingWrite then
		sb.logError("petports: restock pane closing with an unsaved change -- "
			.. "the beacon left the player's hands before the write landed")
	end

	dbg("beacon gone for %s checks with an empty cursor -- dismissing",
		tostring(self.awayTicks))

	pane.dismiss()
end

-- Attempts a held write and tells the beacon its pane closed.
function dismissed()
	if self.noticeMode then return end

	if self.pendingWrite then
		dbg("dismissed with a held write -- attempting it")
		write()
	end

	world.sendEntityMessage(player.id(), "petports_beaconPaneClosed", self.token)
end


-- Stores the enabled checkbox, sets the title icon and writes.
function enabledToggled()
	self.state.enabled = widget.getChecked("enabledCheckbox")
	dbg("enabledToggled -> %s", tostring(self.state.enabled))
	petports_applyPaneIcon(PANE_ICONS, self.state.enabled)
	write()
end

-- Stores the feeder checkbox and writes.
function feederToggled()
	self.state.feeder = widget.getChecked("feederCheckbox")
	dbg("feederToggled -> %s", tostring(self.state.feeder))
	write()
end

-- Records the selected request and redraws the fields, slot and rows.
function requestSelected()
	if self.rebuilding then return end

	local rowId = widget.getListSelected(REQUESTS_LIST)
	local index = rowId and rowIds[rowId] or nil
	local changed = index ~= self.selectedIndex

	self.selectedIndex = index

	dbg("requestSelected rowId=%s(%s) -> index=%s (changed %s)",
		tostring(rowId), type(rowId), tostring(self.selectedIndex),
		tostring(changed))

	if changed then
		renderFields()

		renderSlot()

		paintRows()
	end
end

-- Adds a request for the item on the cursor and puts the item back.
function requestSlotClicked()
	local swap = player.swapSlotItem()

	dbg("requestSlotClicked: swap slot holds %s", j(swap))

	if type(swap) ~= "table" or type(swap.name) ~= "string" then
		dbg("requestSlotClicked: empty cursor, nothing to add")
		return
	end

	local added = addRequest(swap.name)

	player.setSwapSlotItem(swap)

	if added then write() end
	renderAll()
end

-- Adds a request for the item id typed in the name box, if that id is a real item.
function addByNameClicked()
	local ok, text = pcall(widget.getText, "tbAddName")
	if not ok or type(text) ~= "string" then return end

	local name = text:match("^%s*(.-)%s*$")
	if name == "" then return end

	if itemFacts(name) == nil then
		dbg("addByNameClicked: %s is not an item id", name)
		return
	end

	pcall(widget.setText, "tbAddName", "")

	local added = addRequest(name)

	if added then write() end
	renderAll()
end

-- Drops the selection.
function requestSlotCleared()
	dbg("requestSlotCleared: dropping selection")

	self.selectedIndex = nil

	renderAll()
end

-- Syncs the min box.
function minChanged()
	syncField("min")
end

-- Syncs the max box.
function maxChanged()
	syncField("max")
end

-- Shows the filter clear button only with text in the filter.
local function refreshFilterClear()
	pcall(widget.setVisible, "btnClearFilter", (self.filterText or "") ~= "")
end

-- Stores the filter text and rebuilds the request list when it changed.
function filterChanged()
	local ok, text = pcall(widget.getText, "tbRequestFilter")
	if not ok or type(text) ~= "string" or text == self.filterText then return end

	self.filterText = text

	refreshFilterClear()
	refreshRequests()
end

-- Empties the filter box.
function filterClearClicked()
	pcall(widget.setText, "tbRequestFilter", "")
	filterChanged()
end

-- Does nothing.
function rowHovered()
end
