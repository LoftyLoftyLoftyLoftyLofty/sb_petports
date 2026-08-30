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

--  EVERY VISIBLE STRING COMES FROM THE SHARED TABLE. This pane's config names a
--  key beside each label and declares "--" as its value; a key that does not
--  resolve leaves the dash showing. See petports_strings.config.
require "/scripts/lofty_petports/petports_strings.lua"

--  THE TITLE ICON REFLECTS WHETHER THE BEACON IS ENABLED. One implementation
--  shared with the restock pane, which carries the same checkbox and the same
--  handler shape. See petports_paneicon.lua -- the widget path it uses is a
--  hypothesis with a disproof condition, not a settled fact.
require "/scripts/lofty_petports/petports_paneicon.lua"

--  THE TWO VARIANTS, DECLARED ONCE. The .config names the ON file as its
--  pre-script default; these are what init and the toggle actually apply, and a
--  disagreement between the two lists is a wrong icon for one frame at open,
--  not a broken pane.
local PANE_ICONS = {
	on  = "/interface/lofty_petports/beaconconfig/paneicon_deposit_on.png",
	off = "/interface/lofty_petports/beaconconfig/paneicon_deposit_off.png"
}

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
local DEBUG = false

--  BUILD STAMP.
--
--  Logged once per pane open, UNCONDITIONALLY -- not behind DEBUG, because its
--  whole job is to be greppable in a log where nothing else is trusted yet.
--
--  Earned twice over. A taskAction fix was diagnosed as not working when the
--  game was loading an older copy of the file, and a pane log was read as two
--  fixed bugs still being broken when it was simply the previous build. Both
--  cost a launch. Grep the stamp before believing anything else.
--
--  NOT AT FILE SCOPE. Root callback tables are bound AFTER a script chunk runs,
--  so a bare sb.logInfo beside this local raises "attempt to index global 'sb'"
--  and kills the script before a single function in it is defined. That is
--  exactly how the monster taskAction was broken for three launches. init()
--  logs it instead.
local BUILD_STAMP = "2026-08-30b title icon route probe"

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

--  Full widget path -> rule index, for the per-row widgets. Rebuilt with the
--  list. A member callback is handed the member widget, so this is how a
--  click gets back to the rule it belongs to.
local rowWidgetIndex = {}

--  Tile widget path -> subgroup index, for the subgroup grid. Same purpose
--  as rowWidgetIndex: read the checkbox back after the engine has toggled it.
local tileWidgetPath = {}

--  Which rule index those tiles were built for.
--
--  MEASURED: every selection event rebuilt the grid TWICE.
--
--    refreshSubgroups: building, 4 tiles, 1 excluded
--    refreshSubgroups: building, 4 tiles, 1 excluded
--
--  selectRuleAt calls widget.setListSelected and then calls ruleSelected by
--  hand -- but ListWidget::setSelected invokes the list callback itself, which
--  is ruleSelected, which calls showPanelFor. Both paths run every time.
--
--  Worse than wasted work: subgroupToggled states outright that the grid must
--  NOT be rebuilt or the tile under the click is destroyed mid-click, and it
--  was being rebuilt twice per click. It survived, on luck.
--
--  Rather than delete the manual call -- which would leave the pane depending
--  on an engine callback firing, and self.selected unset if it ever did not --
--  showPanelFor is made idempotent. Calling it twice for the same rule costs
--  one label write.
local shownRuleIndex = nil

--  Tile widget path -> subgroup table, for createTooltip. The tiles carry
--  placeholder art and no label, so hover text is the only thing naming them.
local tileSubgroup = {}
local groupRowIds = {}

--  Row art, set per row rather than by the list schema.
--
--  selectedBG and unselectedBG never drew anything in this mod. Vanilla's
--  crafting and vending lists carry a `background` image at zlevel -1 inside
--  listTemplate and drive it from script, which is what these mirror -- and
--  driving it per row is also what makes the alternating shade possible.
--
--  Sized to each list's own memberSize. Art cut for a different row size is
--  exactly how the schema attempt went wrong.
local RULE_ROW_ART = "/interface/lofty_petports/shared/row_144.png"
local RULE_ROW_ART_ALT = "/interface/lofty_petports/shared/row_144_alt.png"
local RULE_ROW_ART_SELECTED = "/interface/lofty_petports/shared/row_144_selected.png"

local GROUP_ROW_ART = "/interface/lofty_petports/shared/row_155.png"
local GROUP_ROW_ART_ALT = "/interface/lofty_petports/shared/row_155_alt.png"

--  index -> the row's widget path prefix, so a selection change can repaint
--  without rebuilding. Rebuilding calls clearListItems, which invokes the
--  list's own callback -- so a repaint that rebuilt would fire the very
--  callback that asked for it.
--
--  The rules list uses it for the selection bar; the group picker uses it for
--  the alternating shade that sits UNDER its row buttons, since a button has
--  only one base image and cannot alternate on its own.
local ruleRowPaths = {}
local groupRowPaths = {}

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

local RULE_LABEL_CHARS = 26

--  Clip a string to the row width, marking that it was clipped.
--
--  ".." rather than a single ellipsis character: the game font does not carry
--  every unicode glyph and a missing one renders as nothing, which would make a
--  truncated label look merely wrong rather than truncated.
local function truncate(text)
	if #text <= RULE_LABEL_CHARS then return text end
	return text:sub(1, RULE_LABEL_CHARS - 2) .. ".."
end

--  RULE_LABEL_CHARS above: how many characters fit in a rule row before the
--  delete button. The label has no wrapWidth -- see the pane config -- so
--  nothing stops an overlong string running under the X. Truncating is a guess
--  at font metrics and a deliberate one: too short is a cosmetic gap, too long
--  is text under a button. 26 is conservative for ~115px of usable row width.

--  The text of a rule row.
--
--  NO VERB. It used to read "Accept  Weapons (5 of 7)", which is both the
--  longest thing this can produce and now redundant: the row carries its own
--  accept/deny checkbox, and refreshRules colours the label to match. Dropping
--  the word is what makes the string fit at all.
local function ruleLabel(rule)
	if rule.item ~= nil then
		return truncate(tostring(rule.item))
	end

	local group = petports_filterGroup(rule.group)

	--  A rule whose group has vanished -- mod removed, manifest edited -- still
	--  has to be visible and deletable. Showing the raw id is ugly and correct;
	--  hiding the row would leave the player unable to remove a rule that is
	--  still being evaluated.
	local name = (group ~= nil and group.label) or ("? " .. tostring(rule.group))

	if type(rule.except) == "table" and #rule.except > 0 and group ~= nil
	   and type(group.subgroups) == "table" then
		--  "5/7" rather than a bare group name, because a partially ticked group
		--  that LOOKS whole is how someone spends an hour wondering why their
		--  whips keep coming back. Abbreviated from "(5 of 7)" purely for width.
		local subgroups = petports_filterSubgroups(group)
		return truncate(string.format("%s %d/%d", name,
			#subgroups - #rule.except, #subgroups))
	end

	return truncate(name)
end

--  Repaint the rule rows' backgrounds for the current selection.
--
--  SELECTION HERE IS THE BAR ALONE. The restock pane tints its selected label
--  yellow as well; this list cannot, because ruleLabel's colour already carries
--  MEANING -- green accept, red deny, set by setFontColor above. A third colour
--  competing with those would make the list harder to read, not easier.
--
--  REPAINTS IN PLACE. Rebuilding to show a selection change would call
--  clearListItems, which invokes the list's own callback -- so the repaint
--  would fire the thing that asked for it.
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


--  Alternating shade for the group picker, painted UNDER its row buttons.
--
--  NO SELECTED STATE, DELIBERATELY. This list is a menu of ACTIONS rather than
--  a selection: clicking a group adds a rule, the row is not "current"
--  afterwards, and the same group can be added again. A row left lit would say
--  otherwise. Hover is the button's own job.
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

	--  Row ids are all new after this, so whatever the grid was built against
	--  no longer corresponds to a selection. Cleared so the next showPanelFor
	--  cannot mistake a stale index for a live one.
	shownRuleIndex = nil

	for index, rule in ipairs(self.state.filter.rules) do
		local rowId = widget.addListItem("rulesScroll.rulesList")
		ruleRowIds[rowId] = index
		ruleRowPaths[index] = string.format("rulesScroll.rulesList.%s", rowId)

		local path = string.format("rulesScroll.rulesList.%s.ruleText", rowId)
		local label = ruleLabel(rule)

		--  rowId is opaque and its TYPE matters: it comes back from the engine
		--  and is used to build widget paths. If a row renders blank this line
		--  says whether the id or the path was wrong.
		dbg("rule row %d id=%s(%s) path=%s label=%q rule=%s",
			index, tostring(rowId), type(rowId), path, label, j(rule))

		widget.setText(path, label)

		--  THE COLOUR IS THE VERB. ruleLabel no longer says "Accept" or "Deny"
		--  because that string did not fit; the row checkbox and this carry it
		--  instead. Muted rather than saturated -- these sit on a dark list
		--  background and full red on dark grey is hard to read.
		pcall(widget.setFontColor, path, (rule.action == "deny")
			and { 255, 128, 128 } or { 128, 255, 128 })

		--  PER-ROW WIDGETS. Constructible only because registerMemberCallback
		--  ran in init -- see the pane config header.
		local actionPath = string.format("rulesScroll.rulesList.%s.rowAction", rowId)
		local removePath = string.format("rulesScroll.rulesList.%s.rowRemove", rowId)

		rowWidgetIndex[actionPath] = index
		rowWidgetIndex[removePath] = index

		--  setData as well as the path map: the exact arguments a member
		--  callback receives are not documented. Whichever arrives,
		--  rowIndexFrom resolves it and the log says which route worked.
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

	--  Selection does not survive a rebuild, so the buttons that act on a
	--  selection have to go dead with it.
	self.selected = nil

	--  The rows exist now, so the selection can be shown on them.
	paintRuleRows()
end

local function refreshGroups()
	widget.clearListItems("groupsScroll.groupsList")
	groupRowIds = {}
	groupRowPaths = {}

	local manifest = petports_filterManifest()

	--  An empty manifest here means the asset failed to load or failed to
	--  parse. petports_filters.lua logs that too, but from the pane's side it
	--  presents as an empty picker with no other symptom.
	--  petports_filterGroups, never pairs(manifest.groups): the manifest is
	--  keyed by id, so a raw pairs() would list the picker in a different
	--  order every time the pane opened.
	local groups = petports_filterGroups()
	dbg("refreshGroups: manifest has %d groups", #groups)

	for _, group in ipairs(groups) do
		local rowId = widget.addListItem("groupsScroll.groupsList")
		groupRowIds[rowId] = group.id

		--  THE ROW BUTTON CARRIES ITS OWN GROUP ID. A member callback is handed
		--  (leafName, widgetData) and the leaf name is "rowBG" for every row, so
		--  the data is the only thing that can say WHICH row was clicked. Same
		--  mechanism the rule rows' action and remove buttons already use.
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

--  Every argument a callback was handed, with types. The argument shape of a
--  member callback is not documented, so this is how it got established --
--  and it stays, because the next widget family will raise the same question.
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

--  ---------------------------------------------------------------------------
--  SUBGROUP GRID
--  ---------------------------------------------------------------------------
--
--  A TICKED TILE MEANS INCLUDED, AND THE STORED FORM IS THE OPPOSITE.
--
--  rule.except lists the subgroups switched OFF. That is deliberate and load
--  bearing -- a subgroup added later, by an update or another mod, is inside
--  every existing rule by default, so a player who said "Weapons" does not
--  find one kind of weapon quietly not sorting. Storing inclusions would give
--  the opposite and much worse behaviour.
--
--  So the pane inverts on read and on write, and nothing downstream ever sees
--  an inclusion list. An absent except key means the whole group; a full
--  except list means a rule that matches nothing, which is legal and visible
--  in the row label as "(0 of 7)".

--  The group whose subgroups are on screen, or nil when nothing is selected.
local shownGroup = nil

--  That group's subgroups in display order, cached because subgroupToggled
--  indexes into it by tile position. group.subgroups is KEYED BY ID and has
--  no order at all, so indexing it numerically returns nil.
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

	--  Exclusions as a set, so the tick state is a lookup rather than a scan
	--  per tile.
	local excluded = {}
	if type(rule.except) == "table" then
		for _, id in ipairs(rule.except) do excluded[id] = true end
	end

	for index, subgroup in ipairs(shownSubgroups) do
		local rowId = widget.addListItem("subgroupsScroll.subgroupsList")
		local path = string.format("subgroupsScroll.subgroupsList.%s.tile", rowId)

		tileWidgetPath[path] = index
		tileSubgroup[path] = subgroup

		--  setData is the ONLY thing that identifies a tile to its callback --
		--  arg 1 is the leaf name "tile" on every one of them.
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

--  Point the subgroup grid at a rule, or empty it when there is none.
--
--  NOTHING IS HIDDEN. The picker and the grid shared a rect while the pane was
--  160 wide and had to take turns; at 318 they sit one above the other down the
--  right side and are both always live. Adding a rule and narrowing one stopped
--  being modes.
--
--  The label above the grid carries the rule's verb, because "Allow Weapons"
--  and "Deny Weapons" tick identically and the tiles cannot show which.
--  "Allow Weapons", OR "Deny Weapons -- nothing to narrow".
--
--  ASSEMBLED FROM A FORMAT STRING, NOT FROM CONCATENATION. Gluing a verb to a
--  name with a space bakes English word order into the pane; "%s %s" lets a
--  translator move the pieces, and the verbs are their own keys because they
--  are words rather than code.
local function narrowLabel(rule, group, nothingToNarrow)
	local verb = petports_stringOr((rule.action == "deny")
		and "beacon.verb.deny" or "beacon.verb.allow")

	return petports_format(nothingToNarrow
		and "beacon.narrownothing" or "beacon.narrow", verb, group.label or group.id)
end

local function showPanelFor(rule)
	--  ALREADY SHOWING THIS RULE. The tiles are correct -- the player's own click
	--  is what changed them -- so only the label can need updating, and that is
	--  the case where the rule's action flipped under an unchanged selection.
	if rule ~= nil and shownRuleIndex ~= nil and shownRuleIndex == self.selected
	   and shownGroup ~= nil and shownGroup.id == rule.group then
		widget.setText("subgroupsLabel", narrowLabel(rule, shownGroup, false))
		return
	end

	local showing = refreshSubgroups(rule)
	shownRuleIndex = showing and self.selected or nil

	if showing then
		--  A GROUP WITH NOTHING TO NARROW SAYS SO. Unsorted has no subgroups by
		--  design -- an item either has a home elsewhere or it does not -- and an
		--  empty grid under a normal label reads as a bug rather than as an
		--  absence of choice.
		if #shownSubgroups == 0 then
			widget.setText("subgroupsLabel", narrowLabel(rule, shownGroup, true))
		else
			widget.setText("subgroupsLabel", narrowLabel(rule, shownGroup, false))
		end
	else
		widget.setText("subgroupsLabel", petports_stringOr("beacon.subgroups"))
	end
end

--  Tick or untick one subgroup on the selected rule.
--
--  Registered as a member callback on the subgroup list, same mechanism as the
--  rule rows.
local function subgroupToggled(...)
	dbg("subgroupToggled fired with %s", describeArgs(...))

	local rule = self.selected and self.state.filter.rules[self.selected]
	if rule == nil or shownGroup == nil then return end

	--  The tile index, from widget data. Deliberately not resolved through
	--  rowIndexFrom: that one validates against filter.rules, and these index
	--  the SUBGROUP list.
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

	--  Read the tile back rather than inverting: the engine has already
	--  toggled it by the time this runs.
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

	--  Rebuild the exclusion list from the tiles rather than editing it in
	--  place. An except list that drifts out of step with what is on screen is
	--  invisible until someone wonders why a whole group stopped sorting.
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

	--  ABSENT, not empty, when nothing is excluded. An empty array and a
	--  missing key mean the same thing to the resolver, but the missing key is
	--  what ruleLabel tests to decide whether to print "(n of m)".
	if #except == 0 then
		rule.except = nil
	else
		rule.except = except
	end

	dbg("subgroupToggled %s.%s -> %s (%d excluded)", tostring(shownGroup.id),
		tostring(subgroup.id), tostring(checked), #except)

	write()

	--  The rule row label carries the "(n of m)" count, so it has to be
	--  rebuilt -- but the grid must NOT be, or the tile the player just
	--  clicked is destroyed underneath the click.
	local keep = self.selected
	refreshRules()
	selectRuleAt(keep, "subgroupToggled")
end

--  ---------------------------------------------------------------------------
--  ROW WIDGET CALLBACKS
--  ---------------------------------------------------------------------------
--
--  Registered on the LIST via widget.registerMemberCallback, NOT named in
--  scriptWidgetCallbacks. See the pane config header for why a row button
--  cannot use a pane callback.

--  Pull a rule index out of what a member callback was handed.
--
--  MEASURED, and the first version of this got it wrong:
--
--    ruleRowRemove fired with [1] string = rowRemove, [2] number = 1
--    ruleRowRemove resolved index=1 via arg 1 by path suffix
--
--  Arg 1 is the member LEAF NAME -- "rowRemove", byte-identical on every row
--  in the list -- and arg 2 is whatever widget.setData put on that member.
--  Only arg 2 identifies a row.
--
--  The earlier version also tried a suffix match on arg 1, and it returned the
--  right answer only because that test had ONE rule. "rowRemove" is a suffix
--  of every row path, so with three rules the winner was whichever pairs()
--  reached first, and the X would have deleted an arbitrary rule. Removed.
--
--  Data only, and nil if it is not there. A wrong rule deleted silently is far
--  worse than a click that does nothing and says so in the log.
local function rowIndexFrom(...)
	local args = {...}

	for position, value in ipairs(args) do
		if type(value) == "number" and self.state.filter.rules[value] ~= nil then
			return value, string.format("arg %d as widget data", position)
		end
	end

	return nil, "unresolved -- no argument carried a usable rule index"
end
--  Flip one rule between accept and deny.
local function ruleRowAction(...)
	dbg("ruleRowAction fired with %s", describeArgs(...))

	local index, how = rowIndexFrom(...)
	dbg("ruleRowAction resolved index=%s via %s", tostring(index), how)

	local rule = index and self.state.filter.rules[index]
	if rule == nil then return end

	--  Read the checkbox back rather than inverting the stored value: the engine
	--  has already toggled it by the time this runs, and inverting would
	--  double-toggle if that ever stops being true.
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

--  Delete one rule.
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

--  MUST RUN BEFORE THE FIRST addListItem. A row button naming a callback the
--  list does not know throws a WidgetParserException inside addListItem and
--  takes down whatever called it, so this cannot be deferred.
local function registerRowCallbacks()
	local ok, err = pcall(function()
		widget.registerMemberCallback("rulesScroll.rulesList",
			"ruleRowAction", ruleRowAction)
		widget.registerMemberCallback("rulesScroll.rulesList",
			"ruleRowRemove", ruleRowRemove)
		--  The hover layer is a button, so it needs a member callback like every
		--  other row widget -- even though it does nothing. See rowHovered.
		widget.registerMemberCallback("rulesScroll.rulesList",
			"rowHovered", rowHovered)
		widget.registerMemberCallback("subgroupsScroll.subgroupsList",
			"subgroupToggled", subgroupToggled)

		--  The group picker's rows are full-width BUTTONS now, so they need a
		--  member callback like any other row widget. See groupRowPicked.
		widget.registerMemberCallback("groupsScroll.groupsList",
			"groupRowPicked", groupRowPicked)
	end)

	--  LOUD ON FAILURE. If registration does not take, the next addListItem
	--  throws and the pane breaks on its first rule -- a symptom several steps
	--  removed from the cause.
	if ok then
		dbg("registered row member callbacks on rulesList")
	else
		sb.logError("petports: registerMemberCallback failed (%s) -- rule rows "
			.. "carrying buttons will throw on addListItem", tostring(err))
	end

	return ok
end

--  Select the row now standing for a given rule index.
--
--  refreshRules rebuilds the list and the row ids are all new afterwards, so a
--  caller that wants a selection to survive has to look it up again. Guarded on
--  nil for the same reason the picker rebuilds rather than deselecting:
--  widget.setListSelected(list, nil) throws LuaConversionException instead of
--  clearing anything.
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

--  ---------------------------------------------------------------------------
--  ENGINE CALLBACKS
--  ---------------------------------------------------------------------------

function init()
	sb.logInfo("PETPORTS beaconconfig build: %s", BUILD_STAMP)

	--  ONCE, AT INIT. The gui table and the string table are both fixed for the
	--  life of the pane, so there is nothing a later pass could find.
	petports_applyStrings()

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

	--  THE ICON IS SEEDED FROM THE SAME VALUE AS THE CHECKBOX, on the line
	--  below it, so the two cannot be made to disagree by a later edit that
	--  moves one of them. The .config's `file` is a pre-script default and this
	--  is what the player actually sees.
	petports_applyPaneIcon(PANE_ICONS, self.state.enabled)

	--  ABSENT MEANS ON, so a beacon placed before this field existed feeds
	--  pets rather than silently refusing to.
	widget.setChecked("feederCheckbox", self.state.feeder ~= false)
	widget.setChecked("baseCheckbox", self.state.filter.base ~= "deny")

	--  BEFORE refreshRules, which calls addListItem, which constructs the row
	--  buttons. Registering afterwards is one frame too late and the pane
	--  breaks on its first rule.
	registerRowCallbacks()

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
	petports_applyPaneIcon(PANE_ICONS, self.state.enabled)
	write()
end

--  MAY UNITS EAT FROM THIS CONTAINER.
--
--  NOTHING READS IT YET. The fuel system is unbuilt -- treats accumulate in
--  seven flavors and nothing consumes one -- so this stores a preference and
--  stops there. Written now because the beacon state travels with the ITEM, and
--  a field added later would be absent on every beacon a player has already
--  placed. Absent reads as ON, so that costs nothing whenever it does land.
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

	--  If a selection never maps to an index, the id coming out of
	--  getListSelected is a different TYPE from the one addListItem returned --
	--  the table key would not match. That is invisible without both printed.
	dbg("ruleSelected rowId=%s(%s) -> index=%s",
		tostring(rowId), type(rowId), tostring(self.selected))

	local rule = self.selected and self.state.filter.rules[self.selected]

	--  Selecting a rule swaps the lower panel to its subgroups; deselecting
	--  swaps back to the picker.
	--  The bar is the only thing marking the selected rule, so it has to
	--  follow the click. In place, not by rebuilding -- see paintRuleRows.
	paintRuleRows()

	showPanelFor(rule)
end
--  Add a rule for a group. The one place that acts.
--
--  TAKES THE GROUP ID DIRECTLY, because a row button knows which row it is via
--  setData while the list only knows what is SELECTED -- and a full-width button
--  may well be consuming the click the list needs to notice a selection change.
local function addGroupRule(groupId, why)
	if groupId == nil then return end

	dbg("addGroupRule(%s) via %s", tostring(groupId), tostring(why))

	--  A FIRST RULE ON AN ACCEPT-ALL FILTER FLIPS THE BASE. Adding "accept
	--  ores" to a filter that already accepts everything says nothing; the
	--  player plainly means "ores and not the rest".
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

	--  THE PICKER IS NOT REBUILT, AND THAT IS A REMOVAL RATHER THAN AN
	--  OVERSIGHT.
	--
	--  It used to be. The picker's selection had to be cleared or its list
	--  callback -- which only fires on CHANGE -- would not fire again when the
	--  same group was clicked twice, and adding the same rule twice is a
	--  legitimate thing to want. setListSelected(list, nil) cannot do it: the
	--  engine converts that argument to a String and nil throws
	--  LuaConversionException. So the list got rebuilt, which dropped the
	--  selection as a side effect.
	--
	--  None of that applies now. The rows are buttons with their own callback
	--  and the list's callback is "null", so nothing is ever selected and there
	--  is nothing to clear. The content is the static manifest either way -- 74
	--  rows that do not depend on the rules at all.
	--
	--  REBUILDING ALSO ATE THE HOVER. Every row is a fresh widget afterwards,
	--  and a fresh button has had no mouse-enter -- so the row under the cursor
	--  drew its base image and the highlight did not come back after a click
	--  until the pointer moved away and returned.
end

--  THE ROW BUTTON. This is expected to be the one that fires.
function groupRowPicked(_, data)
	addGroupRule(data, "row button")
end

function createTooltip(screenPosition)
	for path, subgroup in pairs(tileSubgroup) do
		local ok, inside = pcall(widget.inMember, path, screenPosition)
		
		if ok and inside then
			local tooltip = config.getParameter("tooltipLayout")
			tooltip.title.value = subgroup.label or subgroup.id
			
			--  Says what the tick MEANS, not just what the subgroup is called.
			--  Ticked-is-included and stored-as-excluded are opposites, and the
			--  tooltip is the only place that can explain the tick.
			local on = true
			local okChecked, value = pcall(widget.getChecked, path)
			if okChecked then on = value end
			
			tooltip.description.value = petports_stringOr(on
				and "beacon.tip.included" or "beacon.tip.excluded")
			
			return tooltip
		end
	end
end

--  THE HOVER LAYER'S CALLBACK, WHICH DOES NOTHING BY DESIGN.
--
--  Its button exists only to own a hover state -- a list schema has none, and a
--  row can only get one from a button. Selection is still the LIST's job: a
--  full-width row button and the list callback both fire on one click, measured
--  on the group picker, so nothing here needs to act.
--
--  IT CANNOT SIMPLY BE OMITTED. A row widget naming a callback that does not
--  resolve throws inside addListItem and takes the pane down at construction.
function rowHovered()
end
