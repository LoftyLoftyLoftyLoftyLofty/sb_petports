--  PETPORTS -- RESTOCK BEACON CONFIGURATION PANE SCRIPT
--
--  Talks to the held beacon through the player. The header of
--  petports_beacon.lua explains why that indirection exists, why every message
--  carries a token, and why calling :result() immediately is safe HERE and
--  nowhere near the port.
--
--  WRITE-ON-CHANGE, NOT WRITE-ON-CLOSE. This can be closed with the X, with
--  Escape, or by the player switching items, and only one of those three could
--  ever run a save handler.
--
--  THE STATE THIS PANE OWNS:
--
--      { enabled = bool, requests = { { item, min, max }, ... } }
--
--  ONE BEACON, MANY REQUESTS. It was one item per beacon first, and the obvious
--  workaround -- several beacons in one crate -- fails on the case that
--  prompted it: twenty building materials would mean twenty beacons AND twenty
--  stacks competing for the same slots in one chest. See migrate() for how a
--  beacon configured under the old shape is carried across.
--
--  `item` is a NAME, never a descriptor, and that is the central decision in
--  this file. See addRequest.

--  How often the liveness poll runs. Matched to the deposit pane.
local HOLD_CHECK_INTERVAL = 0.25

--  How many consecutive unanswered checks WITH AN EMPTY CURSOR mean the beacon
--  has genuinely left the player's hands, rather than being hidden behind
--  something they picked up. See update() for why one is not enough.
--
--  FOUR, AT A QUARTER SECOND EACH: ONE SECOND. This is a margin over the
--  re-creation gap and nothing else, so it is sized against a measurement
--  rather than chosen for feel:
--
--    17.679  beacon UNREACHABLE (answer=false, cursor=false)
--    18.189  beacon reachable (answer=true, cursor=false)
--
--  0.51s. Four checks is roughly twice that. It was eight, which measured 1.80s
--  from stow to close and read as a lag rather than a decision.
--
--  THIS IS THE DIAL, AND THE FAILURE MODE IN EACH DIRECTION IS DIFFERENT. Too
--  high is a pane that lingers after the beacon is stowed -- untidy, harmless.
--  Too low is a pane that closes mid-sample, and if a write happened to still
--  be pending that edit is lost. So raise it, do not lower it, if the log ever
--  shows a dismissal while the player was plainly still working.
local AWAY_LIMIT = 4

--  Verbose while this is being built. Flip to false before shipping; leave the
--  calls. A pane fails in ways that all look like "clicking does nothing" from
--  the outside -- a widget path that does not resolve, a callback never
--  registered, a nil where a descriptor was expected -- and only logging the
--  INPUTS at each decision tells them apart.
local DEBUG = false

--  BUILD STAMP. Logged once per open, UNCONDITIONALLY, because its whole job
--  is to be greppable in a log where nothing else is trusted yet.
--
--  NOT AT FILE SCOPE -- root callback tables are bound after a script chunk
--  runs, so a bare sb.logInfo beside this local raises "attempt to index
--  global 'sb'" and kills the script before a single function in it is
--  defined. init() logs it.
local BUILD_STAMP = "2026-08-25r restock pane, row hover"

--  Absolute ceiling on a quota, AND IT MATCHES THE PANE'S REGEX RATHER THAN
--  BEING CHOSEN INDEPENDENTLY. The textboxes filter input with \d{0,5}, so five
--  digits is what a player can physically type; a different number here would
--  create a range the script defends against and the widget already made
--  unreachable.
--
--  IT WAS 9999, WHICH IS ONE STACK OF DIRT. Wanting two stacks meant adding the
--  same item to the list twice -- silly for the most ordinary request there is.
--
--  99999 rather than a round 100000 BECAUSE OF THAT MATCHING RULE. Six digits
--  would make 999999 typeable and the script would have to refuse it after the
--  fact, which is exactly the silent rejection this pairing exists to avoid.
--  The practical ceiling is storage anyway: 99999 is 99.999 slots of dirt
--  against a 64-slot vanilla container, so this is already past what vanilla
--  can hold and well into modded capacity. Beyond it, use a second crate.
--
--  IT IS NOT A CEILING ON A TRIP. restockFetchWork still caps each fetch at one
--  stack, so a request for 99999 dirt is about a hundred round trips. That is
--  the standing one-stack-per-trip design rather than something this number
--  changed, but it is worth knowing before typing a big number.
local QUOTA_CEILING = 99999

--  Default quota for an item that will not resolve. Only reachable when
--  root.itemConfig fails outright, at which point the request is broken anyway;
--  guessing high here is harmless because it is a starting value the player
--  sees and can change, not something the network acts on unseen.
local ASSUMED_MAX_STACK = 1000

--  How many characters fit on one line at fontSize 7 across the pane's usable
--  width. Conservative: too short is a cosmetic gap, too long is text running
--  off the frame.
local SUMMARY_CHARS = 46

--  How many characters fit in a request row before the delete button. The row
--  label has no wrapWidth -- see the deposit pane, where a wrapped label in a
--  16px row drew its first line ABOVE the row -- so nothing stops an overlong
--  string running under the X.
--
--  The whole budget goes to the item name. The quota lives on the summary line
--  and in the two fields, so the row does not compete with itself for space.
local ROW_CHARS = 30

--  What the selected row's label is tinted with.
--
--  A Starbound colour escape, the same mechanism the pane title's subtitle uses.
--  Yellow because it reads as "this one" without colliding with the green this
--  mod already uses for enabled/on states -- a selected row and an active
--  beacon are different ideas and should not share a colour.
local SELECTED_COLOR = "^yellow;"

--  Row background art, set per row by paintRows.
--
--  DRIVEN FROM HERE RATHER THAN BY THE SCHEMA. The list's own selectedBG and
--  unselectedBG never drew anything in this mod; vanilla's crafting and vending
--  lists both carry a `background` image inside listTemplate and address it the
--  same way this does. Per row rather than per list is also what makes the
--  alternating shade possible at all.
--
--  Sized to this list's memberSize of 180x16. A file cut for a different row
--  size is exactly how the schema attempt went wrong.
local ROW_ART = "/interface/lofty_petports/shared/row_180.png"
local ROW_ART_ALT = "/interface/lofty_petports/shared/row_180_alt.png"
local ROW_ART_SELECTED = "/interface/lofty_petports/shared/row_180_selected.png"

--  The two typed fields, and the widgets behind them.
local QUOTA_FIELDS = { "min", "max" }
local FIELD_WIDGET = { min = "tbMin", max = "tbMax" }

local REQUESTS_LIST = "requestsScroll.requestsList"

--  FORMATTED HERE, NOT BY sb.logInfo. Starbound's logger accepts %s and nothing
--  else -- %d, %q and %.2f all raise "Improper lua log format specifier" and
--  take down whatever was logging.
local function dbg(fmt, ...)
	if not DEBUG then return end
	local ok, text = pcall(string.format, fmt, ...)
	sb.logInfo("petports restock pane: %s", ok and text or ("<badformat> " .. tostring(fmt)))
end

local function j(value)
	if value == nil then return "nil" end
	local ok, text = pcall(sb.printJson, value)
	if ok then return text end
	return "<unprintable " .. type(value) .. ">"
end

--  itemId returned by widget.addListItem -> index into self.state.requests.
--  Kept because a list gives back its own opaque id and nothing else; there is
--  no way to ask a row what it represents.
local rowIds = {}

--  request index -> full widget path of that row. Kept so a selection change
--  can repaint the labels without rebuilding the list -- and rebuilding is what
--  invokes the list's own callback, so repainting has to avoid it.
local rowPaths = {}

--  ---------------------------------------------------------------------------
--  TALKING TO THE ITEM
--  ---------------------------------------------------------------------------
--
--  THE SWAP SLOT SHADOWS THE BEACON. world.sendEntityMessage(player.id(), ...)
--  is routed to whatever the player is HOLDING, and an item on the CURSOR
--  counts as held -- so the instant a sample lands on the cursor, nothing
--  answers. The pane reports that rather than acting on it; the TOKEN is what
--  protects the beacon, not the heartbeat.

local function beaconAnswer()
	local promise = world.sendEntityMessage(player.id(), "petports_beaconHeld", self.token)
	return promise:result()
end

local function cursorOccupied()
	local ok, swap = pcall(player.swapSlotItem)
	return ok and type(swap) == "table" and swap.name ~= nil
end

--  Fields that mean nothing without requests, and must be REMOVED rather than
--  set when there are none.
--
--  THE THREE LEGACY KEYS ARE HERE BECAUSE OF MIGRATION. A beacon configured
--  before the list existed carries item/min/max; the same write that stores its
--  new `requests` array names them in the clear list, so the old shape does not
--  sit in the save forever with the port still able to find it.
local CLEARED_FIELDS = { "requests", "item", "min", "max" }

--  DERIVED AT SEND TIME, NEVER PASSED IN. nil is not a value a Lua table can
--  carry, so a field the pane wants gone is indistinguishable from one it never
--  mentioned -- and the item's write handler reads absence as "leave this
--  alone". Computing the list from state is also what makes a HELD write safe
--  to retry: it cannot disagree with the state being sent beside it.
local function clearList()
	local out = nil

	--  The legacy trio is ALWAYS cleared. Once this pane has written a
	--  `requests` array they are dead weight, and leaving them would let the
	--  port's own legacy fallback disagree with the list.
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

--  One writer, one place, so what the pane believes and what the item stores
--  cannot drift.
--
--  THE PAYLOAD IS BUILT, NOT THE STATE TABLE ITSELF. A table that came back
--  through a promise does not drop a key on nil assignment the way a plain Lua
--  table does -- measured: a read that returned no filter at all produced
--  `"filter":null` in the payload after `state.filter = nil`. Naming the fields
--  this pane owns cannot inherit anything.
--
--  A REFUSED WRITE IS HELD, NOT DROPPED. Every edit worth making is made with
--  something on the cursor, which is exactly when nothing answers. There is no
--  queue and no delta: the payload is rebuilt from current state every time.
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

	--  nil means nothing answered -- something is on the cursor. false means a
	--  beacon answered and refused on the token. Both are held and retried; the
	--  retry costs one message and being wrong about which costs the edit.
	self.pendingWrite = true
	dbg("write HELD result=%s payload=%s", j(accepted), j(payload))
	return false
end

--  ---------------------------------------------------------------------------
--  REQUESTS
--  ---------------------------------------------------------------------------

--  Display name and stack size for an item NAME.
--
--  root.itemConfig re-runs a generated item's build script with a fresh seed
--  when the descriptor carries no seed, which is a documented trap elsewhere in
--  this mod. It does not bite here: this runs on pane open and on sample, never
--  per tick, and the two fields read are not things a builder invents.
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

--  Where the polymorphic display-name overrides live. See that file for what
--  counts as polymorphic and why the override is display-only.
local POLYMORPHIC_CONFIG = "/scripts/lofty_petports/petports_polymorphic.config"

--  The override table, read once per pane.
--
--  FAIL EMPTY, AND SAY SO ONCE. An unreadable table means every item falls back
--  to its shortdescription, which is what happened before this existed -- so
--  the pane still works and only the family names are missing. Guessing at a
--  fallback vocabulary would be worse than not having one.
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

--  Cached per name, because the row labels ask for every request on every
--  refresh and the answer cannot change while the pane is open.
--
--  THE OVERRIDE WINS, AND IT HAS TO. For a polymorphic item the alternative is
--  not a worse name, it is a WRONG one: root.itemConfig gets a bare descriptor,
--  so a generated item rebuilds with a fresh seed and the pane names one
--  arbitrary song for a request that means any of them. "Music Sheets
--  (Betabound!)" is what the request actually is.
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

--  A quota value, or nil if the text is not one.
--
--  RANGE ONLY, AND ONLY THIS FIELD. There is deliberately no min-versus-max
--  rule, and that is a correction rather than an omission. Keeping min <= max
--  meant editing one number silently moved the other, and every keystroke of a
--  longer number is a smaller number on the way past: typing 2000 into max
--  passes through 2 and dragged min down with it. The fix for that was a settle
--  delay -- a timer whose entire job was to hide a mutation this file chose to
--  make. Removing the mutation removed the timer.
--
--  MIN ABOVE MAX IS A DEFINED STATE. The port fetches `max - have`, which is
--  zero or negative once the crate is at max, so it settles at max and stops.
--  renderSummary says so out loud.
local function quotaValue(text)
	local value = tonumber(text)
	if value == nil then return nil end

	value = math.floor(value)
	if value < 1 or value > QUOTA_CEILING then return nil end

	return value
end

local function truncate(text, limit)
	limit = limit or SUMMARY_CHARS
	if #text <= limit then return text end

	--  A LIMIT BELOW THREE WOULD RETURN ALMOST THE WHOLE STRING.
	--
	--  sub(1, limit - 2) with limit 2 is sub(1, 0) -- empty, fine -- but limit 1
	--  is sub(1, -1), and Lua counts a negative end index from the END of the
	--  string, so that is the ENTIRE text. The tightest possible budget would
	--  produce the longest possible output, which is the exact opposite of the
	--  job. Only reachable when a caller's sentence has almost no room left for
	--  its label, which is precisely when overflowing matters most.
	if limit < 3 then return "" end

	--  ".." rather than an ellipsis character: the game font does not carry
	--  every unicode glyph and a missing one renders as nothing, which makes a
	--  truncated label look merely wrong rather than truncated.
	return text:sub(1, limit - 2) .. ".."
end

--  The currently selected request, or nil.
local function selected()
	if self.selectedIndex == nil then return nil end
	return self.state.requests[self.selectedIndex]
end

--  Is this item already requested? Returns its index.
local function indexOf(name)
	for index, request in ipairs(self.state.requests) do
		if request.item == name then return index end
	end

	return nil
end

--  ---------------------------------------------------------------------------
--  RENDERING
--  ---------------------------------------------------------------------------

--  Put a number in a field and remember what is showing there.
--
--  THE BOOKKEEPING IS THE POINT. syncField decides a player has typed by seeing
--  text it did not put there, so every write to a textbox has to update
--  shownText in the same breath -- otherwise the script's own render reads back
--  as an edit and commits itself in a loop.
local function setField(field, value)
	local text = value ~= nil and tostring(value) or ""

	self.shownText[field] = text
	pcall(widget.setText, FIELD_WIDGET[field], text)
end

local function renderSummary()
	--  UNSAVED EDITS OUTRANK EVERYTHING ELSE THIS LINE COULD SAY. The pane does
	--  not close when the beacon stops answering, so this is the only thing
	--  telling a player their change has not landed yet.
	if self.pendingWrite then
		widget.setText("summary", "Waiting for the beacon - change not saved yet.")
		return
	end

	local count = #self.state.requests

	if count == 0 then
		widget.setText("summary", "Click the slot holding an item to add one.")
		return
	end

	local request = selected()

	if request == nil then
		widget.setText("summary", truncate(string.format(
			"%s request(s). Select one to set its amounts.", tostring(count))))
		return
	end

	local label = labelFor(request.item)

	--  THE LABEL IS TRIMMED TO WHAT THE SENTENCE LEAVES, not the other way
	--  round. "Keep 500 to 1000 Music Sheets (Betabound!) here." is 47
	--  characters against a 46-character line, so truncating the whole string
	--  would eat the closing word and leave it reading as though it had been cut
	--  off mid-thought. Same budgeting as the request rows, same reason.
	--
	--  The `""` substitution measures the sentence WITHOUT the label, which is
	--  the budget the label then gets.

	--  MIN ABOVE MAX IS ALLOWED, SO IT HAS TO BE EXPLAINED. Nothing stops the
	--  player typing it and the port copes, but "Keep 1000 to 500" tells them
	--  only that they have made a mess -- not what the crate will actually do,
	--  which is settle at max and stay there.
	if (request.min or 0) > (request.max or 0) then
		--  SHORTER WORDING THAN IT READS LIKE IT WANTS. The full sentence left
		--  five characters for the label against a twenty-five character family
		--  name, which overflowed the line by two even after trimming. Losing
		--  four words of explanation to keep the item legible is the right
		--  trade: the player can see the two numbers they typed.
		local shell = "Above fill to - holds %s %s."
		local fixed = #string.format(shell, tostring(request.max), "")

		widget.setText("summary", string.format(shell, tostring(request.max),
			truncate(label, SUMMARY_CHARS - fixed)))
		return
	end

	local shell = "Keep %s to %s %s here."
	local fixed = #string.format(shell,
		tostring(request.min), tostring(request.max), "")

	widget.setText("summary", string.format(shell,
		tostring(request.min), tostring(request.max),
		truncate(label, SUMMARY_CHARS - fixed)))
end

--  The quota fields, which edit whichever row is selected.
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

local function renderSlot()
	local count = #self.state.requests

	--  THE SLOT IS AN ADD BUTTON, NOT A DISPLAY. It stays empty on purpose:
	--  showing the last-added item would read as "this is the request", which
	--  is what the list beside it is for.
	widget.setItemSlotItem("itemSlot_request", nil)

	if count == 0 then
		widget.setText("requestName", "Nothing requested")
	else
		widget.setText("requestName", string.format("%s requested", tostring(count)))
	end

	widget.setText("requestHint", "Click holding an item to add")
end

--  Write every row's label, marking the selected one.
--
--  SELECTION IS SHOWN IN THE TEXT, because the schema's own mechanism does not
--  visibly work here. `selectedBG` and `unselectedBG` have been set on every
--  list in this mod since before the restock pane existed, pointed first at
--  vanilla's crafting art and then at art generated to each list's exact
--  memberSize -- and neither produced anything on screen. No asset error, no
--  parse error, both panes built: the keys are simply not doing what their
--  names suggest, and nothing in the log says why.
--
--  A colour escape in the label cannot fail the same way. The pane title
--  already proves labels honour them, so this needs no new widget type and no
--  assumption about how a ListWidget draws its rows.
--
--  TRUNCATE FIRST, THEN PREFIX. The escape is markup, not glyphs, but it counts
--  toward the string length -- trimming afterwards would eat the code itself
--  and print it.
--
--  REPAINTS WITHOUT REBUILDING. clearListItems invokes the list's callback, so
--  rebuilding to show a selection change would tear down and re-select the row
--  the player just clicked.
local function paintRows()
	for index, path in pairs(rowPaths) do
		local request = self.state.requests[index]

		if request ~= nil then
			local text = truncate(labelFor(request.item), ROW_CHARS)
			local art = ROW_ART_ALT

			if index == self.selectedIndex then
				text = SELECTED_COLOR .. text
				art = ROW_ART_SELECTED
			elseif index % 2 == 1 then
				art = ROW_ART
			end

			--  BOTH, because neither alone is enough. The tint survives
			--  whatever the row background does or does not draw, and the
			--  background is what makes a selection readable at a glance rather
			--  than by reading. They were built in that order for that reason.
			pcall(widget.setText, path .. ".rowText", text)
			pcall(widget.setImage, path .. ".rowBG", art)
		end
	end
end

--  Rebuild the request list.
--
--  REBUILT WHOLE, NEVER PATCHED. Row ids are opaque and new after every
--  addListItem, so a caller that wants a selection to survive has to look it up
--  again -- which is what the two halves of this function do.
--
--  clearListItems INVOKES THE LIST'S CALLBACK, and that cost the selection on
--  every edit. Measured:
--
--    commitField(min, 100) -> ... is 100-1000
--    requestSelected rowId=nil(nil) -> index=nil
--    refreshRequests: 2 row(s)
--
--  Note the order: requestSelected ran BEFORE the rebuild had finished, because
--  clearing the list is itself a selection change. So typing a number blanked
--  the row highlight, syncField then saw nothing selected and wiped both
--  fields, and adding a request never highlighted the row it had just made.
--
--  The deposit pane records the same engine behaviour for setListSelected. It
--  is the same trap through a different door.
--
--  GUARDED, THEN RESTORED. The guard stops the teardown being mistaken for the
--  player clicking away; the restore puts the highlight back on the row that
--  now stands for the same request.
local function refreshRequests()
	local keep = self.selectedIndex

	self.rebuilding = true
	widget.clearListItems(REQUESTS_LIST)

	rowIds = {}
	rowPaths = {}

	for index, request in ipairs(self.state.requests) do
		local rowId = widget.addListItem(REQUESTS_LIST)
		rowIds[rowId] = index

		local path = string.format("%s.%s", REQUESTS_LIST, rowId)

		--  THE MEMBER CALLBACK IS HANDED (leafName, widgetData), and the leaf
		--  name is identical for every row -- "rowRemove". Only the data can
		--  identify a row, which is why every row widget gets setData here.
		widget.setData(path .. ".rowRemove", index)

		--  THE NAME ONLY. The row used to carry "label  min-max", which meant a
		--  twenty-five character family name and an eight character quota
		--  competing for thirty characters -- the label had to be trimmed to
		--  make room for numbers that are already on the summary line, and
		--  every keystroke in a quota field stale-dated the row and forced a
		--  rebuild.
		--
		--  Selecting a row shows its amounts in the two fields below. That is
		--  the same "select a thing, then narrow it" shape the deposit pane
		--  uses, and it leaves the whole row for the one thing that identifies
		--  it. "Music Sheets (Betabound!)" fits in full.
		rowPaths[index] = path
	end

	self.rebuilding = false

	--  setListSelected invokes the callback too, which re-derives
	--  self.selectedIndex from the new row id. Belt to that braces: if it ever
	--  does not fire, selectedIndex is still `keep`, untouched by the guarded
	--  teardown above.
	if keep ~= nil and self.state.requests[keep] ~= nil then
		for rowId, at in pairs(rowIds) do
			if at == keep then
				widget.setListSelected(REQUESTS_LIST, rowId)
				break
			end
		end
	else
		self.selectedIndex = nil
	end

	paintRows()

	dbg("refreshRequests: %s row(s), selection %s",
		tostring(#self.state.requests), tostring(self.selectedIndex))
end

local function renderAll()
	renderSlot()
	refreshRequests()
	renderFields()
	renderSummary()
end

--  ---------------------------------------------------------------------------
--  EDITING
--  ---------------------------------------------------------------------------

--  Adopt an item name as a new request.
--
--  THE SLOT SAMPLES. IT DOES NOT TAKE. This is the one place this pane
--  deliberately diverges from vanilla's mechassemblygui.lua, which reads
--  player.swapSlotItem(), hands the previously-held part back with
--  setSwapSlotItem, and genuinely STORES what it was given.
--
--  A restock beacon needs a NAME, not an item, so taking one would be a tax on
--  configuring the beacon -- and it would drag in the whole problem the deposit
--  beacon solved with dismissed() plus a heartbeat: something has to give the
--  item back when the pane dies badly. Sampling has nothing to give back.
--
--  ALREADY LISTED MEANS SELECT, NOT DUPLICATE. Two entries for one item would
--  make the quota depend on which the port read first, and
--  petports_restockMisfits resolves duplicates first-wins precisely because a
--  hand-edited save can still produce them.
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

	--  A COMPLETE REQUEST IN ONE CLICK. Dropping an item in should be the whole
	--  interaction for the common case, so what lands is a working quota with a
	--  gap already in it -- fill a stack, refetch at half. A player who wants
	--  2000 dirt types it.
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

local function removeRequest(index)
	if self.state.requests[index] == nil then return false end

	dbg("removeRequest(%s): %s", tostring(index),
		tostring(self.state.requests[index].item))

	table.remove(self.state.requests, index)

	--  The selection cannot outlive the row it named. Dropping it entirely is
	--  safer than guessing at a neighbour: the fields blank, and the player
	--  picks what they meant.
	self.selectedIndex = nil

	return true
end

--  ---------------------------------------------------------------------------
--  THE TYPED FIELDS
--  ---------------------------------------------------------------------------

--  Take a field's text as the selected request's new value.
--
--  COMMITTED ON THE KEYSTROKE. There is nothing to wait for: the beacon has to
--  be HELD for this pane to be open, so it is not in a crate, no port is
--  reading it, and no unit can act on a half-typed number.
--
--  DOES NOT WRITE BACK TO THE WIDGET. A rejected entry leaves the field showing
--  what was typed and the stored value untouched; snapping the text back would
--  move the caret out from under someone mid-number.
local function commitField(field, text)
	local request = selected()
	if request == nil then return end

	local value = quotaValue(text)

	--  An EMPTY OR OUT-OF-RANGE field is someone mid-edit, not someone asking
	--  for nothing. The regex permits zero digits, so an empty box is the
	--  ordinary state of a field just cleared to be retyped.
	if value == nil or value == request[field] then return end

	request[field] = value

	dbg("commitField(%s, %s) -> %s is %s-%s", field, tostring(text),
		tostring(request.item), tostring(request.min), tostring(request.max))

	write()

	--  NO LIST REBUILD. The row carries the item name and nothing else now, so
	--  a quota edit cannot stale it. That matters beyond the wasted work:
	--  clearListItems invokes the list's own callback, so rebuilding on every
	--  keystroke meant tearing down and re-selecting the row the player was
	--  editing, several times a second, for no visible change.
	renderSummary()
end

--  Read one field back and commit it if it moved.
--
--  TWO CALLERS, ON PURPOSE. The textbox's own callback is the responsive path,
--  and pollFields is the backstop -- because what a textbox callback actually
--  fires ON is not something this mod knows. Sharing one function is what makes
--  running both harmless.
local function syncField(field)
	if type(self.state) ~= "table" then return end
	if not self.fieldsUsable then return end

	local ok, text = pcall(widget.getText, FIELD_WIDGET[field])

	if not ok or type(text) ~= "string" then
		--  LOUD AND ONCE. If getText does not work on a textbox then the quota
		--  cannot be edited, and a pane where typing does nothing is exactly
		--  the symptom this file's header warns is indistinguishable from four
		--  other causes.
		self.fieldsUsable = false
		sb.logError("petports: restock pane cannot read %s; quota entry is "
			.. "disabled for this pane", FIELD_WIDGET[field])
		return
	end

	if selected() == nil then
		--  Nothing selected, so there is no quota to type into. Anything that
		--  appears is wiped, which is self-explanatory in a way that a silently
		--  ignored number is not.
		if text ~= "" then setField(field, nil) end
		return
	end

	if text ~= self.shownText[field] then
		self.shownText[field] = text
		commitField(field, text)
	end
end

local function pollFields()
	for _, field in ipairs(QUOTA_FIELDS) do
		syncField(field)
	end
end

--  ---------------------------------------------------------------------------
--  ROW CALLBACKS
--  ---------------------------------------------------------------------------

--  A widget inside a list row CANNOT use a scriptWidgetCallbacks name. The
--  engine throws at CONSTRUCTION, not at click -- addListItem throws and takes
--  down whatever called it -- because those names are registered on the parser
--  that builds the PANE, and ListWidget constructs rows with a different one.
--
--  MUST HAPPEN BEFORE THE FIRST addListItem. Registering afterwards is one
--  frame too late and the pane breaks on its first row.
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

		--  The hover layer is a button, so it needs a member callback like
		--  every other row widget -- even though it does nothing. See
		--  rowHovered.
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

--  ---------------------------------------------------------------------------
--  MIGRATION
--  ---------------------------------------------------------------------------

--  A beacon configured before the list existed.
--
--  Its item/min/max become a one-entry array, and clearList names the three old
--  keys on the next write so the old shape does not linger in the save. The
--  port has the same fallback, so a beacon whose pane is never opened keeps
--  working in the meantime.
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

--  ---------------------------------------------------------------------------
--  ENGINE CALLBACKS
--  ---------------------------------------------------------------------------

--  Was this pane opened by a beacon sitting on the CURSOR rather than the
--  hotbar?
--
--  Starbound locks the inventory's category tabs while something is on the
--  cursor -- the rule that stops a rifle being parked in a food slot. A beacon
--  held that way can only ever see items in its own category, which rules out
--  most of the game. There is no supported way around it and there should not
--  be one.
--
--  THE TEST IS BY NAME, AND THAT HAS ONE KNOWN HOLE. A player with one restock
--  beacon on the hotbar and a SECOND on the cursor is refused when they should
--  not be. Two beacons at once is rare, the refusal explains itself, and the
--  alternative needs a way to ask which hotbar slot is selected that this mod
--  has not verified exists in retail.
--
--  DONE IN THE PANE RATHER THAN IN activate(). An activeitem script has no
--  `player` table -- see the header of petports_beacon.lua -- so it cannot read
--  the swap slot to find out where it is.
local function openedFromCursor()
	local expected = config.getParameter("beaconItemName")
	if type(expected) ~= "string" then return false end

	local ok, swap = pcall(player.swapSlotItem)

	return ok and type(swap) == "table" and swap.name == expected
end

--  Turn the pane into a notice and nothing else.
--
--  A PANE RATHER THAN A CHAT BUBBLE, FOR NOW. Making the player SAY something
--  wants a mechanism reachable from a ScriptPane, and this mod has not verified
--  one -- `entity.say` belongs to monsters and NPCs, and an activeitem has no
--  player table at all.
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

	--  EVERYTHING THE EDITOR OWNS GOES AWAY, the slot backing included. An
	--  empty slot beside a refusal reads as an invitation to fill it.
	for _, name in ipairs({
		"slotBacking", "itemSlot_request", "requestHeading", "requestName",
		"requestHint", "enabledCheckbox", "enabledLabel", "minLabel", "maxLabel",
		"minFieldBacking", "maxFieldBacking", "tbMin", "tbMax", "summary",
		"requestsScroll"
	}) do
		pcall(widget.setVisible, name, false)
	end

	widget.setVisible("noticeTitle", true)
	widget.setVisible("noticeLineOne", true)
	widget.setVisible("noticeLineTwo", true)

	widget.setText("noticeTitle", "Cannot configure here")
	widget.setText("noticeLineOne", truncate(tostring(message[1] or "")))
	widget.setText("noticeLineTwo", truncate(tostring(message[2] or "")))
end

function init()
	sb.logInfo("PETPORTS restockconfig build: %s", BUILD_STAMP)

	self.holdTimer = 0
	self.fieldsUsable = true

	--  Set only when the pane opens as a refusal notice. See openedFromCursor.
	self.noticeMode = false

	self.shownText = { min = "", max = "" }
	self.selectedIndex = nil
	self.labels = {}

	--  A write that could not reach the beacon, waiting for it to answer again.
	self.pendingWrite = false

	--  Whether the beacon answered on the last heartbeat, and how many checks
	--  in a row it has been unanswered with an empty cursor. See update().
	self.reachable = true
	self.awayTicks = 0

	--  THE NOTICE IS OFF UNLESS SOMETHING TURNS IT ON.
	for _, name in ipairs({ "noticeTitle", "noticeLineOne", "noticeLineTwo" }) do
		pcall(widget.setVisible, name, false)
	end

	--  BEFORE THE READ. Nothing should be touched on an item this pane is about
	--  to refuse to edit, and self.state stays nil so update() and dismissed()
	--  both return early.
	if openedFromCursor() then
		--  Marks this pane as the notice rather than the editor. update() reads
		--  it to retire the notice on its own; without it the pane has no way
		--  to ever close itself. See update().
		self.noticeMode = true
		lockWithNotice()
		return
	end

	dbg("init: asking held item for its config")

	local promise = world.sendEntityMessage(player.id(), "petports_beaconRead")
	self.state = promise:result()

	dbg("init: read returned %s", j(self.state))

	--  FAIL CLOSED. If the read did not answer, this pane does not know what it
	--  is editing, and writing defaults over an existing configuration is worse
	--  than not opening at all.
	if type(self.state) ~= "table" or self.state.token == nil then
		sb.logError("petports: restock pane opened with no readable beacon; dismissing")
		self.state = nil
		pane.dismiss()
		return
	end

	self.token = self.state.token
	self.state.token = nil

	--  Materialised here rather than on write, so everything below can assume
	--  the array exists.
	if type(self.state.requests) ~= "table" then
		self.state.requests = {}
	end

	--  Sanitise whatever was stored. A beacon written by this pane cannot carry
	--  a bad entry, but an older build or a hand-edited save can, and a request
	--  with no item name would render as a blank row nothing could remove.
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

	--  BEFORE refreshRequests, which calls addListItem, which constructs the
	--  row buttons. Registering afterwards is one frame too late.
	registerRowCallbacks()

	renderAll()

	--  The migrated shape is only real once it is stored, and this also carries
	--  the clear list that retires the three legacy keys.
	if migrated then write() end

	dbg("init: complete")
end

function update(dt)
	--  THE NOTICE HAS ITS OWN LIFECYCLE, AND WITHOUT ONE IT IS AN ORPHAN.
	--
	--  It leaves self.state nil so nothing below can touch an item it refused
	--  to edit -- which also meant this function returned immediately and the
	--  notice never re-checked anything. It sat there until dismissed by hand,
	--  and because it sends no heartbeat either, the item's PANE_ALIVE timer
	--  expired after a second and activate() cheerfully opened a SECOND pane
	--  beside it.
	--
	--  The notice is about a beacon on the CURSOR. The moment that is no longer
	--  true it has nothing to say, and putting the beacon somewhere it can be
	--  used is exactly the thing it was asking for -- so the same test that
	--  raised it retires it.
	--
	--  FAILS TOWARD CLOSING. openedFromCursor returns false when the swap slot
	--  cannot be read at all, so an unreadable cursor dismisses rather than
	--  stranding the pane, which is the right direction for a window whose only
	--  content is a sentence.
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

	--  REACHABILITY IS REPORTED, AND ONLY "GONE" CLOSES THE PANE.
	--
	--  The liveness check used to dismiss on any unanswered heartbeat. That was
	--  wrong twice over: the TOKEN protects the beacon, so dismissing bought no
	--  safety, and it made the itemslot unusable, because filling one requires
	--  touching the inventory and touching the inventory is what stops the
	--  beacon answering.
	--
	--  Removing it entirely was too far the other way. A beacon dropped into a
	--  crate with the pane still open left the pane editing an item that was no
	--  longer in hand -- measured, and it is the one case where the deposit
	--  pane's stricter rule is right. That pane can afford it: it has no
	--  itemslot, so it never needs the cursor.
	--
	--  THE CURSOR IS THE DISCRIMINATOR. Both cases answer nil, and they differ
	--  in exactly one observable:
	--
	--    beacon UNREACHABLE (answer=nil, cursor=true)   sampling -- stay
	--    beacon UNREACHABLE (answer=nil, cursor=false)  put away -- go
	local answer = beaconAnswer()
	local reachable = answer == true

	if reachable ~= self.reachable then
		self.reachable = reachable

		dbg("beacon %s (answer=%s, cursor=%s)",
			reachable and "reachable" or "UNREACHABLE",
			j(answer), tostring(cursorOccupied()))

		renderSummary()
	end

	if reachable then
		self.awayTicks = 0

		--  The moment it answers again is the moment a held write can land.
		if self.pendingWrite then
			dbg("flushing held write")
			write()
			renderSummary()
		end

		return
	end

	--  SHADOWED, NOT GONE. An item on the cursor is "held" as far as message
	--  routing is concerned, so nothing answers in the beacon's place.
	if cursorOccupied() then
		self.awayTicks = 0
		return
	end

	--  AN EMPTY CURSOR AND NO ANSWER, SUSTAINED.
	--
	--  Sustained because a single one of those is ORDINARY. Taking an item onto
	--  the cursor and putting it back re-creates the held beacon, and there is
	--  a real window either side of that where the cursor is already empty and
	--  the item is not yet answering. Measured at about half a second:
	--
	--    17.679  beacon UNREACHABLE (answer=false, cursor=false)
	--    18.160  init: restored pane token
	--    18.189  beacon reachable (answer=true, cursor=false)
	--
	--  So the verdict waits. Two seconds of a pane outliving a stowed beacon is
	--  invisible; closing one out from under someone mid-sample is not.
	self.awayTicks = (self.awayTicks or 0) + 1
	if self.awayTicks < AWAY_LIMIT then return end

	--  An edit that never reached the beacon dies here, and saying so is the
	--  least this can do. It needs the beacon to be in hand and is not, which
	--  is the one thing the player can act on.
	if self.pendingWrite then
		sb.logError("petports: restock pane closing with an unsaved change -- "
			.. "the beacon left the player's hands before the write landed")
	end

	dbg("beacon gone for %s checks with an empty cursor -- dismissing",
		tostring(self.awayTicks))

	pane.dismiss()
end

--  Tell the item this pane is gone, so a player who closes and immediately
--  reopens is not refused.
--
--  ONE LAST ATTEMPT AT A HELD WRITE. Closing while still carrying the sample is
--  the one route that can lose an edit; this tries anyway, because if closing
--  returns the cursor item to the inventory first then the beacon is reachable
--  again by the time this runs.
--
--  BEFORE the closed message, which clears the token on the item and would make
--  anything after it refuse for a real reason.
function dismissed()
	--  THE NOTICE NEVER READ THE ITEM, so it holds no token and has nothing to
	--  say. The item's PANE_ALIVE timer expires on its own, which is the path
	--  that exists for panes that never checked in.
	if self.noticeMode then return end

	if self.pendingWrite then
		dbg("dismissed with a held write -- attempting it")
		write()
	end

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

function requestSelected()
	--  A REBUILD IS NOT A CLICK. clearListItems fires this while the list is
	--  being torn down; acting on it would drop the selection the rebuild is
	--  about to put back. See refreshRequests.
	if self.rebuilding then return end

	local rowId = widget.getListSelected(REQUESTS_LIST)
	local index = rowId and rowIds[rowId] or nil
	local changed = index ~= self.selectedIndex

	self.selectedIndex = index

	--  If a selection never maps to an index, the id from getListSelected is a
	--  different TYPE from the one addListItem returned -- the table key would
	--  not match. That is invisible without both printed.
	dbg("requestSelected rowId=%s(%s) -> index=%s (changed %s)",
		tostring(rowId), type(rowId), tostring(self.selectedIndex),
		tostring(changed))

	--  ONLY ON A REAL CHANGE. refreshRequests re-selects the same row after
	--  every edit, and re-rendering the fields there would overwrite what the
	--  player is typing with its normalised form -- "0100" snapping to "100"
	--  mid-word, moving the caret out from under them. Same reason commitField
	--  does not write back to the widget.
	if changed then
		renderFields()

		--  The tint is the only visible selection indicator, so it has to
		--  follow the click. Repaints in place rather than rebuilding: a
		--  rebuild would fire this callback again.
		paintRows()
	end

	renderSummary()
end

function requestSlotClicked()
	local swap = player.swapSlotItem()

	dbg("requestSlotClicked: swap slot holds %s", j(swap))

	if type(swap) ~= "table" or type(swap.name) ~= "string" then
		--  Clicking with an empty cursor does nothing. There is a per-row
		--  delete button for removing, so a bare click has no job here.
		dbg("requestSlotClicked: empty cursor, nothing to add")
		return
	end

	local added = addRequest(swap.name)

	--  PUT IT BACK, UNCONDITIONALLY, AND DO NOT REASON ABOUT WHETHER IT MOVED.
	--  Vanilla's mech assembly performs its swap in Lua, which strongly implies
	--  the engine does not touch the swap slot itself when an itemslot has a
	--  callback -- but "strongly implies" is not "verified", and the failure it
	--  would hide is a player's item disappearing into a beacon that never
	--  wanted it.
	player.setSwapSlotItem(swap)

	if added then write() end
	renderAll()
end

--  Right-clicking the slot clears the SELECTION, not the list. Removing is the
--  row's own X, which acts on one thing and cannot be misread as "delete
--  everything".
function requestSlotCleared()
	dbg("requestSlotCleared: dropping selection")

	--  widget.setListSelected(list, nil) is NOT the way to clear a selection:
	--  the engine converts that argument to a String and nil throws
	--  LuaConversionException, taking the callback down with it. Rebuilding the
	--  list drops it as a side effect.
	self.selectedIndex = nil

	renderAll()
end

--  THESE MUST EXIST OR THE PANE DOES NOT OPEN. A textbox whose callback does
--  not resolve throws at CONSTRUCTION, in the client main loop, before a single
--  widget is drawn.
function minChanged()
	syncField("min")
end

function maxChanged()
	syncField("max")
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
