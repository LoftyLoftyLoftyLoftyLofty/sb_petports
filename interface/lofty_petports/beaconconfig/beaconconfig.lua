require "/scripts/lofty_petports/petports_filters.lua"

require "/scripts/lofty_petports/petports_strings.lua"

require "/scripts/lofty_petports/petports_paneicon.lua"

local PANE_ICONS = {
	on  = "/interface/lofty_petports/beaconconfig/paneicon_deposit_on.png",
	off = "/interface/lofty_petports/beaconconfig/paneicon_deposit_off.png"
}

local HOLD_CHECK_INTERVAL = 0.25

local DEBUG = false

local BUILD_STAMP = "2026-08-30c state-driven title icon"

local function dbg(fmt, ...)
	if not DEBUG then return end
	local ok, text = pcall(string.format, fmt, ...)
	sb.logInfo("petports pane: %s", ok and text or ("<badformat> " .. tostring(fmt)))
end

local function j(value)
	if value == nil then return "nil" end
	local ok, text = pcall(sb.printJson, value)
	if ok then return text end
	return "<unprintable " .. type(value) .. ">"
end

local ruleRowIds = {}

local rowWidgetIndex = {}

local tileWidgetPath = {}

local shownRuleIndex = nil

local tileSubgroup = {}
local groupRowIds = {}

local RULE_ROW_ART = "/interface/lofty_petports/shared/row_144.png"
local RULE_ROW_ART_ALT = "/interface/lofty_petports/shared/row_144_alt.png"
local RULE_ROW_ART_SELECTED = "/interface/lofty_petports/shared/row_144_selected.png"

local GROUP_ROW_ART = "/interface/lofty_petports/shared/row_155.png"
local GROUP_ROW_ART_ALT = "/interface/lofty_petports/shared/row_155_alt.png"

local ruleRowPaths = {}
local groupRowPaths = {}


local function heldBeacon()
	local promise = world.sendEntityMessage(player.id(), "petports_beaconHeld", self.token)
	local result = promise:result()

	if result ~= true then
		dbg("heldBeacon FALSE token=%s result=%s -- dismissing",
			tostring(self.token), j(result))
	end

	return result == true
end

local function write()
	dbg("write token=%s state=%s", tostring(self.token), j(self.state))

	local promise = world.sendEntityMessage(player.id(), "petports_beaconWrite",
		self.token, self.state)

	local accepted = promise:result()
	if accepted ~= true then
		dbg("write REFUSED result=%s", j(accepted))
	end
end


local RULE_LABEL_CHARS = 26

local function truncate(text)
	if #text <= RULE_LABEL_CHARS then return text end
	return text:sub(1, RULE_LABEL_CHARS - 2) .. ".."
end


local function ruleLabel(rule)
	if rule.item ~= nil then
		return truncate(tostring(rule.item))
	end

	local group = petports_filterGroup(rule.group)

	local name = (group ~= nil and group.label) or ("? " .. tostring(rule.group))

	if type(rule.except) == "table" and #rule.except > 0 and group ~= nil
	   and type(group.subgroups) == "table" then
		local subgroups = petports_filterSubgroups(group)
		return truncate(string.format("%s %d/%d", name,
			#subgroups - #rule.except, #subgroups))
	end

	return truncate(name)
end

local function paintRuleRows()
	for index, path in pairs(ruleRowPaths) do
		local art = RULE_ROW_ART_ALT

		if index == self.selected then
			art = RULE_ROW_ART_SELECTED
		elseif index % 2 == 1 then
			art = RULE_ROW_ART
		end

		pcall(widget.setImage, path .. ".rowBG", art)
	end
end


local function paintGroupRows()
	for index, path in ipairs(groupRowPaths) do
		pcall(widget.setImage, path .. ".rowBGShade",
			(index % 2 == 1) and GROUP_ROW_ART or GROUP_ROW_ART_ALT)
	end
end

local function refreshRules()
	widget.clearListItems("rulesScroll.rulesList")
	ruleRowIds = {}
	ruleRowPaths = {}
	rowWidgetIndex = {}

	shownRuleIndex = nil

	for index, rule in ipairs(self.state.filter.rules) do
		local rowId = widget.addListItem("rulesScroll.rulesList")
		ruleRowIds[rowId] = index
		ruleRowPaths[index] = string.format("rulesScroll.rulesList.%s", rowId)

		local path = string.format("rulesScroll.rulesList.%s.ruleText", rowId)
		local label = ruleLabel(rule)

		dbg("rule row %d id=%s(%s) path=%s label=%q rule=%s",
			index, tostring(rowId), type(rowId), path, label, j(rule))

		widget.setText(path, label)

		pcall(widget.setFontColor, path, (rule.action == "deny")
			and { 255, 128, 128 } or { 128, 255, 128 })

		local actionPath = string.format("rulesScroll.rulesList.%s.rowAction", rowId)
		local removePath = string.format("rulesScroll.rulesList.%s.rowRemove", rowId)

		rowWidgetIndex[actionPath] = index
		rowWidgetIndex[removePath] = index

		local ok, err = pcall(function()
			widget.setData(actionPath, index)
			widget.setData(removePath, index)
			widget.setChecked(actionPath, rule.action ~= "deny")
		end)

		if not ok then
			dbg("rule row %d: setting row widgets FAILED: %s", index, tostring(err))
		end
	end

	dbg("refreshRules done, %d rules", #self.state.filter.rules)

	self.selected = nil

	paintRuleRows()
end

local function refreshGroups()
	widget.clearListItems("groupsScroll.groupsList")
	groupRowIds = {}
	groupRowPaths = {}

	local manifest = petports_filterManifest()

	local groups = petports_filterGroups()
	dbg("refreshGroups: manifest has %d groups", #groups)

	for _, group in ipairs(groups) do
		local rowId = widget.addListItem("groupsScroll.groupsList")
		groupRowIds[rowId] = group.id

		widget.setData(string.format("groupsScroll.groupsList.%s.rowBG", rowId),
			group.id)

		table.insert(groupRowPaths,
			string.format("groupsScroll.groupsList.%s", rowId))
		widget.setText(string.format("groupsScroll.groupsList.%s.groupText", rowId),
			group.label or group.id)
		dbg("group row id=%s(%s) -> %s", tostring(rowId), type(rowId), tostring(group.id))
	end


	paintGroupRows()
end

local function describeArgs(...)
	local args = {...}
	local parts = {}

	for position, value in ipairs(args) do
		table.insert(parts, string.format("[%d] %s = %s",
			position, type(value), tostring(value)))
	end

	if #parts == 0 then return "no arguments" end
	return table.concat(parts, ", ")
end


local shownGroup = nil

local shownSubgroups = {}


local function refreshSubgroups(rule)
	widget.clearListItems("subgroupsScroll.subgroupsList")
	tileWidgetPath = {}
	tileSubgroup = {}
	shownGroup = nil
	shownSubgroups = {}

	if rule == nil or rule.group == nil then return false end

	local group = petports_filterGroup(rule.group)
	if group == nil or type(group.subgroups) ~= "table" then
		dbg("refreshSubgroups: group %s has no subgroups", tostring(rule.group))
		return false
	end

	shownGroup = group
	shownSubgroups = petports_filterSubgroups(group)

	local excluded = {}
	if type(rule.except) == "table" then
		for _, id in ipairs(rule.except) do excluded[id] = true end
	end

	for index, subgroup in ipairs(shownSubgroups) do
		local rowId = widget.addListItem("subgroupsScroll.subgroupsList")
		local path = string.format("subgroupsScroll.subgroupsList.%s.tile", rowId)

		tileWidgetPath[path] = index
		tileSubgroup[path] = subgroup

		local ok, err = pcall(function()
			widget.setData(path, index)
			widget.setChecked(path, not excluded[subgroup.id])
		end)

		if not ok then
			dbg("subgroup tile %d: setting widgets FAILED: %s", index, tostring(err))
		end
	end

	dbg("refreshSubgroups: %s, %d tiles, %d excluded",
		tostring(group.id), #shownSubgroups, #(rule.except or {}))

	return true
end

local function narrowLabel(rule, group, nothingToNarrow)
	local verb = petports_stringOr((rule.action == "deny")
		and "beacon.verb.deny" or "beacon.verb.allow")

	return petports_format(nothingToNarrow
		and "beacon.narrownothing" or "beacon.narrow", verb, group.label or group.id)
end

local function showPanelFor(rule)
	if rule ~= nil and shownRuleIndex ~= nil and shownRuleIndex == self.selected
	   and shownGroup ~= nil and shownGroup.id == rule.group then
		widget.setText("subgroupsLabel", narrowLabel(rule, shownGroup, false))
		return
	end

	local showing = refreshSubgroups(rule)
	shownRuleIndex = showing and self.selected or nil

	if showing then
		if #shownSubgroups == 0 then
			widget.setText("subgroupsLabel", narrowLabel(rule, shownGroup, true))
		else
			widget.setText("subgroupsLabel", narrowLabel(rule, shownGroup, false))
		end
	else
		widget.setText("subgroupsLabel", petports_stringOr("beacon.subgroups"))
	end
end

local function subgroupToggled(...)
	dbg("subgroupToggled fired with %s", describeArgs(...))

	local rule = self.selected and self.state.filter.rules[self.selected]
	if rule == nil or shownGroup == nil then return end

	local index = nil
	for _, value in ipairs({...}) do
		if type(value) == "number" and shownSubgroups[value] ~= nil then
			index = value
			break
		end
	end

	if index == nil then
		dbg("subgroupToggled: no argument carried a usable subgroup index")
		return
	end

	local subgroup = shownSubgroups[index]

	local checked = nil
	for path, at in pairs(tileWidgetPath) do
		if at == index then
			local ok, value = pcall(widget.getChecked, path)
			if ok then checked = value end
			break
		end
	end

	if checked == nil then
		dbg("subgroupToggled could not read tile %d, assuming it was turned on", index)
		checked = true
	end

	local except = {}
	for at, entry in ipairs(shownSubgroups) do
		local on
		if at == index then
			on = checked
		else
			on = true
			if type(rule.except) == "table" then
				for _, id in ipairs(rule.except) do
					if id == entry.id then on = false break end
				end
			end
		end

		if not on then table.insert(except, entry.id) end
	end

	if #except == 0 then
		rule.except = nil
	else
		rule.except = except
	end

	dbg("subgroupToggled %s.%s -> %s (%d excluded)", tostring(shownGroup.id),
		tostring(subgroup.id), tostring(checked), #except)

	write()

	local keep = self.selected
	refreshRules()
	selectRuleAt(keep, "subgroupToggled")
end


local function rowIndexFrom(...)
	local args = {...}

	for position, value in ipairs(args) do
		if type(value) == "number" and self.state.filter.rules[value] ~= nil then
			return value, string.format("arg %d as widget data", position)
		end
	end

	return nil, "unresolved -- no argument carried a usable rule index"
end
local function ruleRowAction(...)
	dbg("ruleRowAction fired with %s", describeArgs(...))

	local index, how = rowIndexFrom(...)
	dbg("ruleRowAction resolved index=%s via %s", tostring(index), how)

	local rule = index and self.state.filter.rules[index]
	if rule == nil then return end

	local checked = nil
	for widgetPath, at in pairs(rowWidgetIndex) do
		if at == index and widgetPath:find("rowAction", 1, true) then
			local ok, value = pcall(widget.getChecked, widgetPath)
			if ok then checked = value end
			break
		end
	end

	if checked == nil then
		dbg("ruleRowAction could not read the checkbox, inverting stored value")
		checked = (rule.action == "deny")
	end

	rule.action = checked and "accept" or "deny"
	dbg("ruleRowAction index=%d -> %s", index, rule.action)

	write()
	refreshRules()
	selectRuleAt(index, "ruleRowAction")
end

local function ruleRowRemove(...)
	dbg("ruleRowRemove fired with %s", describeArgs(...))

	local index, how = rowIndexFrom(...)
	dbg("ruleRowRemove resolved index=%s via %s", tostring(index), how)

	if index == nil or self.state.filter.rules[index] == nil then return end

	dbg("ruleRowRemove index=%d rule=%s", index, j(self.state.filter.rules[index]))
	table.remove(self.state.filter.rules, index)

	write()
	refreshRules()
end

local function registerRowCallbacks()
	local ok, err = pcall(function()
		widget.registerMemberCallback("rulesScroll.rulesList",
			"ruleRowAction", ruleRowAction)
		widget.registerMemberCallback("rulesScroll.rulesList",
			"ruleRowRemove", ruleRowRemove)
		widget.registerMemberCallback("rulesScroll.rulesList",
			"rowHovered", rowHovered)
		widget.registerMemberCallback("subgroupsScroll.subgroupsList",
			"subgroupToggled", subgroupToggled)

		widget.registerMemberCallback("groupsScroll.groupsList",
			"groupRowPicked", groupRowPicked)
	end)

	if ok then
		dbg("registered row member callbacks on rulesList")
	else
		sb.logError("petports: registerMemberCallback failed (%s) -- rule rows "
			.. "carrying buttons will throw on addListItem", tostring(err))
	end

	return ok
end

function selectRuleAt(index, why)
	if index == nil then return false end

	for rowId, at in pairs(ruleRowIds) do
		if at == index and rowId ~= nil then
			dbg("%s: selecting index=%d rowId=%s(%s)",
				tostring(why), index, tostring(rowId), type(rowId))
			widget.setListSelected("rulesScroll.rulesList", rowId)
			ruleSelected()
			return true
		end
	end

	dbg("%s: no row found for index=%s", tostring(why), tostring(index))
	return false
end


function init()
	sb.logInfo("PETPORTS beaconconfig build: %s", BUILD_STAMP)

	petports_applyStrings()

	self.holdTimer = 0
	self.selected = nil

	dbg("init: asking held item for its config")

	local promise = world.sendEntityMessage(player.id(), "petports_beaconRead")
	self.state = promise:result()

	dbg("init: read returned %s", j(self.state))

	if type(self.state) ~= "table" or self.state.token == nil then
		sb.logError("petports: beacon pane opened with no readable beacon; dismissing")
		pane.dismiss()
		return
	end

	self.token = self.state.token
	self.state.token = nil

	if type(self.state.filter) ~= "table" then
		self.state.filter = { base = "accept", rules = {} }
	end
	if type(self.state.filter.rules) ~= "table" then
		self.state.filter.rules = {}
	end

	dbg("init: token=%s enabled=%s filter=%s",
		tostring(self.token), tostring(self.state.enabled), j(self.state.filter))

	widget.setChecked("enabledCheckbox", self.state.enabled ~= false)

	petports_applyPaneIcon(PANE_ICONS, self.state.enabled)

	widget.setChecked("feederCheckbox", self.state.feeder ~= false)
	widget.setChecked("baseCheckbox", self.state.filter.base ~= "deny")

	registerRowCallbacks()

	refreshGroups()
	refreshRules()

	dbg("init: complete")
end

function update(dt)
	self.holdTimer = self.holdTimer - dt
	if self.holdTimer > 0 then return end
	self.holdTimer = HOLD_CHECK_INTERVAL

	if not heldBeacon() then
		pane.dismiss()
	end
end

function dismissed()
	world.sendEntityMessage(player.id(), "petports_beaconPaneClosed", self.token)
end


function enabledToggled()
	self.state.enabled = widget.getChecked("enabledCheckbox")
	dbg("enabledToggled -> %s", tostring(self.state.enabled))
	petports_applyPaneIcon(PANE_ICONS, self.state.enabled)
	write()
end

function feederToggled()
	self.state.feeder = widget.getChecked("feederCheckbox")
	dbg("feederToggled -> %s", tostring(self.state.feeder))
	write()
end

function baseToggled()
	self.state.filter.base = widget.getChecked("baseCheckbox") and "accept" or "deny"
	dbg("baseToggled -> %s", tostring(self.state.filter.base))
	write()
end

function ruleSelected()
	local rowId = widget.getListSelected("rulesScroll.rulesList")
	self.selected = rowId and ruleRowIds[rowId] or nil

	dbg("ruleSelected rowId=%s(%s) -> index=%s",
		tostring(rowId), type(rowId), tostring(self.selected))

	local rule = self.selected and self.state.filter.rules[self.selected]

	paintRuleRows()

	showPanelFor(rule)
end
local function addGroupRule(groupId, why)
	if groupId == nil then return end

	dbg("addGroupRule(%s) via %s", tostring(groupId), tostring(why))

	if #self.state.filter.rules == 0 and self.state.filter.base ~= "deny" then
		self.state.filter.base = "deny"
		widget.setChecked("baseCheckbox", false)
		dbg("addGroupRule: first rule on an accept-all filter, base -> deny")
	end

	table.insert(self.state.filter.rules, { action = "accept", group = groupId })

	dbg("addGroupRule: appended accept rule for %s (base %s)",
		tostring(groupId), tostring(self.state.filter.base))

	write()

	refreshRules()
	selectRuleAt(#self.state.filter.rules, "addGroupRule")

end

function groupRowPicked(_, data)
	addGroupRule(data, "row button")
end

function createTooltip(screenPosition)
	for path, subgroup in pairs(tileSubgroup) do
		local ok, inside = pcall(widget.inMember, path, screenPosition)
		
		if ok and inside then
			local tooltip = config.getParameter("tooltipLayout")
			tooltip.title.value = subgroup.label or subgroup.id
			
			local on = true
			local okChecked, value = pcall(widget.getChecked, path)
			if okChecked then on = value end
			
			tooltip.description.value = petports_stringOr(on
				and "beacon.tip.included" or "beacon.tip.excluded")
			
			return tooltip
		end
	end
end

function rowHovered()
end
