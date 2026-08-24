--  PETPORTS -- BEACON CONFIGURATION PANE SCRIPT
--
--  Talks to the held beacon through the player. See the header of
--  petports_beacon.lua for why that indirection exists and why calling
--  :result() immediately is safe HERE and nowhere near the port.
--
--  WRITE-ON-CHANGE, NOT WRITE-ON-CLOSE. There is no save button and there will
--  not be one: this pane can be closed with the X, with Escape, or by the
--  player switching items -- three exits, only one of which could run a save
--  handler. Writing each change as it happens makes every exit safe.
--
--  THE FILTER SHAPE, mirrored from petports_filters.lua:
--
--      { base = "accept"|"deny", rules = { {action=, group=|item=, except=} } }
--
--  Evaluated top to bottom, LAST MATCH WINS. The list header says so, because
--  this is the reverse of the firewall convention and a player who assumes
--  first-match will put exceptions above the base and see nothing happen.

require "/scripts/lofty_petports/petports_filters.lua"

--  How often the liveness poll runs. Vanilla's transponder does this every
--  tick, but that pane is a full deploy sequence where a missed item swap loses
--  a station. This one only needs to notice within a moment.
local HOLD_CHECK_INTERVAL = 0.25

--  VERBOSE BY DEFAULT WHILE THIS IS BEING BUILT.
--
--  A pane fails in ways that look identical from the outside: a widget path
--  that does not resolve, a callback never registered, a list id that means
--  nothing. All three present as "clicking does nothing". Logging at the point
--  of decision WITH INPUTS -- not just verdicts -- is what tells them apart.
--
--  Flip to false before shipping; leave the calls in place.
local DEBUG = true

--  FORMATTED HERE, NOT BY sb.logInfo.
--
--  Starbound's logger accepts %s and nothing else -- %d, %q and %.2f all
--  raise "Improper lua log format specifier" and take down whatever was
--  logging. Running string.format first means the log call only ever sees one
--  %s, so every specifier Lua supports is available at the call sites.
--
--  pcall'd because a debug line must never be the thing that breaks a script.
--  A malformed format string prints itself instead of throwing.
local function dbg(fmt, ...)
	if not DEBUG then return end
	local ok, text = pcall(string.format, fmt, ...)
	sb.logInfo("petports pane: %s", ok and text or ("<badformat> " .. tostring(fmt)))
end

--  Tables need printJson, and printJson on a nil throws, so every dump goes
--  through here. A crash inside a debug line is a genuinely miserable way to
--  lose an evening.
local function j(value)
	if value == nil then return "nil" end
	local ok, text = pcall(sb.printJson, value)
	if ok then return text end
	return "<unprintable " .. type(value) .. ">"
end

--  itemId returned by widget.addListItem -> index into self.filter.rules, and
--  the same for the group picker. Kept because a list gives back its own opaque
--  id and nothing else; there is no way to ask a row what it represents.
local ruleRowIds = {}
local groupRowIds = {}

--  ---------------------------------------------------------------------------
--  TALKING TO THE ITEM
--  ---------------------------------------------------------------------------

--  TOKEN ON EVERY MESSAGE. Messages go to player.id() and the engine routes
--  them to whatever is HELD, not to the item this pane came from. Without the
--  token, swapping to a second beacon left this pane happily editing the new
--  one: the liveness check still said "yes, held", because a different beacon
--  was answering it.
local function heldBeacon()
	local promise = world.sendEntityMessage(player.id(), "petports_beaconHeld", self.token)
	local result = promise:result()

	--  Only logged when it goes false, because this runs four times a second
	--  and a truthful heartbeat is not information.
	if result ~= true then
		dbg("heldBeacon FALSE token=%s result=%s -- dismissing",
			tostring(self.token), j(result))
	end

	return result == true
end

--  One writer, one place, so what the pane believes and what the item stores
--  cannot drift.
local function write()
	dbg("write token=%s state=%s", tostring(self.token), j(self.state))

	local promise = world.sendEntityMessage(player.id(), "petports_beaconWrite",
		self.token, self.state)

	--  The item returns false when the token does not match -- i.e. the write
	--  landed on a DIFFERENT beacon and was refused. Silently dropping that
	--  would look like "my edits do not save".
	local accepted = promise:result()
	if accepted ~= true then
		dbg("write REFUSED result=%s", j(accepted))
	end
end

--  ---------------------------------------------------------------------------
--  RENDERING
--  ---------------------------------------------------------------------------

local function ruleLabel(rule)
	local verb = (rule.action == "deny") and "Deny" or "Accept"

	if rule.item ~= nil then
		return string.format("%s  %s", verb, rule.item)
	end

	local group = petports_filterGroup(rule.group)

	--  A rule whose group has vanished -- mod removed, manifest edited -- still
	--  has to be visible and deletable. Showing the raw id is ugly and correct;
	--  hiding the row would leave the player unable to remove a rule that is
	--  still being evaluated.
	local name = (group ~= nil and group.label) or ("? " .. tostring(rule.group))

	if type(rule.except) == "table" and #rule.except > 0 and group ~= nil
	   and type(group.subgroups) == "table" then
		--  "5 of 7" rather than a bare group name, because a partially ticked
		--  group that LOOKS whole is how someone spends an hour wondering why
		--  their whips keep coming back.
		return string.format("%s  %s (%d of %d)", verb, name,
			#group.subgroups - #rule.except, #group.subgroups)
	end

	return string.format("%s  %s", verb, name)
end

local function refreshRules()
	widget.clearListItems("rulesScroll.rulesList")
	ruleRowIds = {}

	for index, rule in ipairs(self.state.filter.rules) do
		local rowId = widget.addListItem("rulesScroll.rulesList")
		ruleRowIds[rowId] = index

		local path = string.format("rulesScroll.rulesList.%s.ruleText", rowId)
		local label = ruleLabel(rule)

		--  rowId is opaque and its TYPE matters: it comes back from the engine
		--  and is used to build widget paths. If a row renders blank this line
		--  says whether the id or the path was wrong.
		dbg("rule row %d id=%s(%s) path=%s label=%q rule=%s",
			index, tostring(rowId), type(rowId), path, label, j(rule))

		widget.setText(path, label)
	end

	dbg("refreshRules done, %d rules", #self.state.filter.rules)

	--  Selection does not survive a rebuild, so the buttons that act on a
	--  selection have to go dead with it.
	self.selected = nil
	widget.setButtonEnabled("removeButton", false)
	widget.setButtonEnabled("actionCheckbox", false)
end

local function refreshGroups()
	widget.clearListItems("groupsScroll.groupsList")
	groupRowIds = {}

	local manifest = petports_filterManifest()

	--  An empty manifest here means the asset failed to load or failed to
	--  parse. petports_filters.lua logs that too, but from the pane's side it
	--  presents as an empty picker with no other symptom.
	dbg("refreshGroups: manifest has %d groups", #manifest.groups)

	for _, group in ipairs(manifest.groups) do
		local rowId = widget.addListItem("groupsScroll.groupsList")
		groupRowIds[rowId] = group.id
		widget.setText(string.format("groupsScroll.groupsList.%s.groupText", rowId),
			group.label or group.id)
		dbg("group row id=%s(%s) -> %s", tostring(rowId), type(rowId), tostring(group.id))
	end
end

--  ---------------------------------------------------------------------------
--  ENGINE CALLBACKS
--  ---------------------------------------------------------------------------

function init()
	self.holdTimer = 0
	self.selected = nil

	dbg("init: asking held item for its config")

	local promise = world.sendEntityMessage(player.id(), "petports_beaconRead")
	self.state = promise:result()

	dbg("init: read returned %s", j(self.state))

	--  FAIL CLOSED. If the read did not answer, the pane does not know what it
	--  is editing, and writing defaults over an existing configuration is worse
	--  than not opening at all.
	if type(self.state) ~= "table" or self.state.token == nil then
		sb.logError("petports: beacon pane opened with no readable beacon; dismissing")
		pane.dismiss()
		return
	end

	--  Lifted out of the state table so it is not echoed back inside the write
	--  payload and stored as a parameter -- a per-pane random value on the item
	--  would be one more thing making two identical beacons differ.
	self.token = self.state.token
	self.state.token = nil

	--  A beacon that has never been configured has no filter, and no filter
	--  means accept everything -- the same behaviour as the unconditional
	--  deposit beacon that shipped before filters existed. Materialising it
	--  here rather than on write keeps every callback below able to assume the
	--  table exists.
	if type(self.state.filter) ~= "table" then
		self.state.filter = { base = "accept", rules = {} }
	end
	if type(self.state.filter.rules) ~= "table" then
		self.state.filter.rules = {}
	end

	dbg("init: token=%s enabled=%s filter=%s",
		tostring(self.token), tostring(self.state.enabled), j(self.state.filter))

	widget.setChecked("enabledCheckbox", self.state.enabled ~= false)
	widget.setChecked("baseCheckbox", self.state.filter.base ~= "deny")

	refreshGroups()
	refreshRules()

	dbg("init: complete")
end

function update(dt)
	self.holdTimer = self.holdTimer - dt
	if self.holdTimer > 0 then return end
	self.holdTimer = HOLD_CHECK_INTERVAL

	--  The player put the beacon away, swapped hands, or dropped it. Anything
	--  written from here on would land on whatever is in hand now.
	if not heldBeacon() then
		pane.dismiss()
	end
end

--  Tell the item this pane is gone, so a player who closes and immediately
--  reopens is not refused. The item expires its own timer without this -- see
--  PANE_ALIVE there -- but that path is for panes that die badly, not the
--  ordinary close.
function dismissed()
	world.sendEntityMessage(player.id(), "petports_beaconPaneClosed", self.token)
end

--  ---------------------------------------------------------------------------
--  WIDGET CALLBACKS
--  ---------------------------------------------------------------------------

function enabledToggled()
	self.state.enabled = widget.getChecked("enabledCheckbox")
	dbg("enabledToggled -> %s", tostring(self.state.enabled))
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

	--  If a selection never maps to an index, the id coming out of
	--  getListSelected is a different TYPE from the one addListItem returned --
	--  the table key would not match. That is invisible without both printed.
	dbg("ruleSelected rowId=%s(%s) -> index=%s",
		tostring(rowId), type(rowId), tostring(self.selected))

	local rule = self.selected and self.state.filter.rules[self.selected]
	widget.setButtonEnabled("removeButton", rule ~= nil)
	widget.setButtonEnabled("actionCheckbox", rule ~= nil)

	if rule ~= nil then
		widget.setChecked("actionCheckbox", rule.action ~= "deny")
	end
end

function actionToggled()
	local rule = self.selected and self.state.filter.rules[self.selected]
	if rule == nil then
		dbg("actionToggled with no selection, ignoring")
		return
	end

	rule.action = widget.getChecked("actionCheckbox") and "accept" or "deny"
	dbg("actionToggled index=%d -> %s", self.selected, rule.action)
	write()

	--  Rebuilding drops the selection, so restore it: a player flipping a rule
	--  between accept and deny should not have to reselect it each time.
	local keep = self.selected
	refreshRules()

	--  The row ids are new after a rebuild, so find the one now standing for
	--  the same index. Guarded on nil for the same reason the picker no longer
	--  deselects: passing nil here throws LuaConversionException rather than
	--  doing nothing.
	for rowId, index in pairs(ruleRowIds) do
		if index == keep and rowId ~= nil then
			dbg("actionToggled: restoring selection index=%d rowId=%s(%s)",
				keep, tostring(rowId), type(rowId))
			widget.setListSelected("rulesScroll.rulesList", rowId)
			ruleSelected()
			break
		end
	end
end

function removeRule()
	if self.selected == nil then
		dbg("removeRule with no selection, ignoring")
		return
	end

	dbg("removeRule index=%d rule=%s",
		self.selected, j(self.state.filter.rules[self.selected]))
	table.remove(self.state.filter.rules, self.selected)
	write()
	refreshRules()
end

function groupPicked()
	local rowId = widget.getListSelected("groupsScroll.groupsList")
	local groupId = rowId and groupRowIds[rowId] or nil

	dbg("groupPicked rowId=%s(%s) -> group=%s",
		tostring(rowId), type(rowId), tostring(groupId))

	if groupId == nil then return end

	--  APPENDED, never inserted. The newest thing a player asked for is the
	--  most specific, which is exactly what last-match-wins means -- so adding
	--  a rule always does something visible rather than being shadowed by a
	--  rule further down.
	--
	--  Defaults to DENY. Adding a rule to a filter that already accepts
	--  everything is almost always an attempt to exclude something; the
	--  opposite default would make the common case a two-click operation and
	--  the rare one a one-click.
	--
	--  No `except` key: an absent exclusion list means the whole group, and it
	--  stays absent so a subgroup added later by another mod is inside this
	--  rule automatically.
	table.insert(self.state.filter.rules, { action = "deny", group = groupId })
	write()
	refreshRules()

	--  REBUILD RATHER THAN DESELECT.
	--
	--  The picker's selection has to be cleared or the list callback -- which
	--  only fires on CHANGE -- will not fire again when the same group is
	--  clicked a second time, and adding the same rule twice is a legitimate
	--  thing to want.
	--
	--  widget.setListSelected(list, nil) is NOT the way to do it: the engine
	--  converts that argument to a String and nil throws
	--  LuaConversionException, taking the callback down with it. Tested. The
	--  wiki carries a related warning about out-of-range values crashing
	--  setSelectedOption, so treat "clear the selection" as unsupported across
	--  both widget families.
	--
	--  Rebuilding the list drops the selection as a side effect and costs one
	--  pass over nine rows.
	refreshGroups()
end
