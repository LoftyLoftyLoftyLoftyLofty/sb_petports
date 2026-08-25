--  PETPORTS -- RESTOCK BEACON CONFIGURATION PANE SCRIPT
--
--  Talks to the held beacon through the player, exactly as the deposit pane
--  does. The header of petports_beacon.lua explains why that indirection
--  exists, why every message carries a token, and why calling :result()
--  immediately is safe HERE and nowhere near the port.
--
--  WRITE-ON-CHANGE, NOT WRITE-ON-CLOSE. Same reasoning as the deposit pane:
--  this can be closed with the X, with Escape, or by the player switching
--  items, and only one of those three could ever run a save handler.
--
--  THE STATE THIS PANE OWNS:
--
--      { enabled = bool, item = "itemname", min = number, max = number }
--
--  `item` is a NAME, never a descriptor, and that is the central decision in
--  this file. See setRequest.

--  How often the liveness poll runs. Matched to the deposit pane.
local HOLD_CHECK_INTERVAL = 0.25

--  Verbose while this is being built. Flip to false before shipping; leave the
--  calls. A pane fails in ways that all look like "clicking does nothing" from
--  the outside -- a widget path that does not resolve, a callback never
--  registered, a nil where a descriptor was expected -- and only logging the
--  INPUTS at each decision tells them apart.
local DEBUG = true

--  BUILD STAMP. Logged once per open, UNCONDITIONALLY, because its whole job
--  is to be greppable in a log where nothing else is trusted yet. Two separate
--  sessions have been spent diagnosing a fixed bug that was simply an older
--  file still on disk.
--
--  NOT AT FILE SCOPE -- root callback tables are bound after a script chunk
--  runs, so a bare sb.logInfo beside this local raises "attempt to index
--  global 'sb'" and kills the script before a single function in it is
--  defined. init() logs it.
local BUILD_STAMP = "2026-08-25g notice lines, bucketed compaction"

--  Absolute ceiling on a quota, AND IT MATCHES THE PANE'S REGEX RATHER THAN
--  BEING CHOSEN INDEPENDENTLY.
--
--  The textboxes filter input with \d{0,4}, lifted from vanilla's pixel
--  printer, so four digits is what a player can physically type. Setting this
--  to anything else would create a range the script defends against and the
--  widget already made unreachable -- two rules for one limit, and a reader has
--  to work out which one is real.
--
--  It is not a capacity figure. The crate's real limit is its own slots, and
--  the port checks that with containerItemsCanFit before it moves anything.
local QUOTA_CEILING = 9999

--  Engine default when an item declares no maxStack of its own.
--
--  STATED, NOT VERIFIED. Most vanilla materials carry no maxStack field and
--  stack to a thousand, so a thousand is the assumption. It is only ever used
--  to pick the DEFAULT quota, so being wrong here is a worse first guess
--  rather than a broken beacon.
local ASSUMED_MAX_STACK = 1000

--  How many characters of summary fit on one line at fontSize 7 across the
--  pane's usable width. Conservative on purpose: too short is a cosmetic gap,
--  too long is text running off the frame.
local SUMMARY_CHARS = 46

--  The two typed fields, and the widgets behind them.
local QUOTA_FIELDS = { "min", "max" }
local FIELD_WIDGET = { min = "tbMin", max = "tbMax" }

--  FORMATTED HERE, NOT BY sb.logInfo.
--
--  Starbound's logger accepts %s and nothing else -- %d, %q and %.2f all raise
--  "Improper lua log format specifier" and take down whatever was logging.
--  Running string.format first means the log call only ever sees one %s.
--
--  pcall'd because a debug line must never be the thing that breaks a script.
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

--  ---------------------------------------------------------------------------
--  TALKING TO THE ITEM
--  ---------------------------------------------------------------------------
--
--  THE SWAP SLOT SHADOWS THE BEACON, AND THAT IS THE WHOLE PROBLEM THIS BLOCK
--  SOLVES.
--
--  world.sendEntityMessage(player.id(), ...) is routed to whatever the player is
--  HOLDING, and an item on the CURSOR counts as held -- the character visibly
--  carries it. So the instant a sample lands on the cursor, the beacon stops
--  being the message target: the liveness check goes unanswered, and the pane
--  used to dismiss itself exactly as designed. The mechanism that makes this
--  pane safe was also what made it unusable, because putting an item on the
--  cursor is the ONLY way to fill the itemslot.
--
--  THE TOKEN IS THE REAL GUARD, NOT THE HEARTBEAT. A write aimed at the wrong
--  beacon is refused on the token whether or not the heartbeat noticed the
--  swap. The heartbeat's only job is to stop the pane lingering over an item
--  the player has genuinely put away -- so it can be permissive in exactly one
--  circumstance and stay correct.
--
--  So: an unanswered check WITH THE CURSOR OCCUPIED is presumed to be
--  shadowing and the pane stays. An unanswered check with an EMPTY cursor is
--  the genuine case and still dismisses.
--
--  Nothing on the item side changes. While shadowed its script is not running,
--  so PANE_ALIVE freezes rather than expiring and the token survives to be
--  matched when it resumes.

--  TOKEN ON EVERY MESSAGE. Every beacon registers the same handlers, so without
--  it a pane opened from one hotbar slot cheerfully edits the beacon in another
--  -- the liveness check still says "yes, held", because a DIFFERENT beacon
--  answered it.
--
--  RETURNS THE RAW ANSWER, NOT A BOOLEAN, and that distinction is the whole
--  point of this function's current shape.
--
--    true   the beacon is in hand and this pane owns it
--    nil    nothing answered at all -- no activeitem script is reachable
--    false  something answered and REFUSED on the token
--
--  Those last two look identical from a caller that only asks "is it live", and
--  they have opposite causes. nil is the beacon being shadowed or put away.
--  false means an activeitem IS running and does not recognise our token --
--  either a different beacon, or the same one whose script has reinitialised
--  and forgotten it. The second would be unrecoverable and is worth knowing
--  about immediately rather than diagnosing as "the pane keeps closing".
local function beaconAnswer()
	local promise = world.sendEntityMessage(player.id(), "petports_beaconHeld", self.token)
	return promise:result()
end

--  Is the player carrying something on the cursor?
--
--  pcall'd for the same reason every other player call here is: this decides
--  whether the pane survives, and a throw would take the whole update with it.
--  Unreadable is treated as EMPTY, which fails toward dismissing -- the
--  conservative direction, since a lingering pane can write to the wrong item
--  and a dismissed one only costs a reopen.
local function cursorOccupied()
	local ok, swap = pcall(player.swapSlotItem)
	return ok and type(swap) == "table" and swap.name ~= nil
end

--  Fields that mean nothing without a request, and must be REMOVED rather than
--  set when there is none. The quota goes with the item: a beacon naming no
--  item but carrying min and max is a shape nothing reads and the next sample
--  overwrites anyway, so leaving it behind is just litter in a save file.
local CLEARED_FIELDS = { "item", "min", "max" }

--  DERIVED AT SEND TIME, NEVER PASSED IN.
--
--  nil is not a value a Lua table can carry, so a field the pane wants gone is
--  indistinguishable from one it never mentioned -- and the item's write
--  handler reads absence as "leave this alone", which is what lets one handler
--  serve this pane and the deposit pane's. Hence a separate list.
--
--  Computing it from state rather than carrying it as an argument is what makes
--  a HELD write safe to retry. A queued "clear the item" paired with a later
--  "set the item to dirt" would null the field it had just written; asking the
--  state what is currently absent cannot disagree with the state being sent
--  beside it.
local function clearList()
	local out = nil

	for _, field in ipairs(CLEARED_FIELDS) do
		if self.state[field] == nil then
			out = out or {}
			table.insert(out, field)
		end
	end

	return out
end

--  One writer, one place, so what the pane believes and what the item stores
--  cannot drift.
--
--  THE PAYLOAD IS BUILT, NOT THE STATE TABLE ITSELF, and a log is why.
--
--    write HELD ... state={"item":"hazard",...,"filter":null,...}
--
--  init() does `self.state.filter = nil` and the read never returned a filter
--  at all, yet one arrived in the payload as a null. A table that came back
--  through a promise does not drop a key on nil assignment the way a plain Lua
--  table does. That matters because the item's write handler tests
--  `data[field] ~= nil` -- and a JSON null is not nil in Lua, so it would stamp
--  petports_beaconFilter onto a beacon that has no filter.
--
--  Naming the four fields this pane owns cannot inherit anything, from a
--  promise or from a future field added to the item's FIELDS table.
--
--  A REFUSED WRITE IS HELD, NOT DROPPED. Nothing answers while an item is on
--  the cursor, which is exactly when naming a request happens. There is no
--  queue and no delta: the payload is rebuilt from current state every time, so
--  a retry is simply calling this again.
local function write()
	local clear = clearList()

	local payload = {
		enabled = self.state.enabled,
		item = self.state.item,
		min = self.state.min,
		max = self.state.max
	}

	local promise = world.sendEntityMessage(player.id(), "petports_beaconWrite",
		self.token, payload, clear)

	local accepted = promise:result()

	if accepted == true then
		self.pendingWrite = false
		dbg("write OK payload=%s clear=%s", j(payload), j(clear))
		return true
	end

	--  nil means nothing answered -- something is on the cursor. false means a
	--  beacon answered and refused on the token. Both are held and retried;
	--  the retry costs one message and being wrong about which costs the edit.
	self.pendingWrite = true
	dbg("write HELD result=%s payload=%s", j(accepted), j(payload))
	return false
end

--  ---------------------------------------------------------------------------
--  THE REQUESTED ITEM
--  ---------------------------------------------------------------------------

--  Display name and stack size for an item NAME.
--
--  root.itemConfig re-runs a generated item's build script with a fresh seed
--  when the descriptor carries no seed, which is a documented trap elsewhere in
--  this mod. It does not bite here: this is called on pane open and on sample,
--  never per tick, and the two fields read are not things a builder invents.
--
--  Returns nil for a name the game does not know, which is a real case -- a
--  beacon configured under a mod that has since been removed.
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

--  A quota value, or nil if the text is not one.
--
--  RANGE ONLY, AND ONLY THIS FIELD. There is deliberately no min-versus-max
--  rule here, and that is the correction to an earlier design rather than an
--  omission.
--
--  Keeping min <= max meant editing one number silently moved the other, and
--  every keystroke of a longer number is a smaller number on the way past: with
--  min 500 and max 1000, typing 2000 into max passes through 2 and dragged min
--  down to 2 with it. The fix for that was a settle delay before committing --
--  a timer whose entire job was to hide a mutation this file was choosing to
--  make. Removing the mutation removes the timer, and nothing else wanted it.
--
--  MIN ABOVE MAX IS A DEFINED STATE, NOT A BROKEN ONE. The port fetches
--  `max - have`, which is zero or negative once the crate is at max, so the
--  crate settles at max and stops -- it behaves as though min equalled max.
--  That guard exists on the port anyway for the overstock case, so this costs
--  nothing there, and renderSummary says out loud what will happen.
--
--  THE CEILING IS BELT TO THE WIDGET'S BRACES. \d{0,4} already makes anything
--  above 9999 untypeable; this catches a value that arrived some other way --
--  an older build, a hand-edited save.
local function quotaValue(text)
	local value = tonumber(text)
	if value == nil then return nil end

	value = math.floor(value)
	if value < 1 or value > QUOTA_CEILING then return nil end

	return value
end

local function truncate(text)
	if #text <= SUMMARY_CHARS then return text end
	--  ".." rather than an ellipsis character: the game font does not carry
	--  every unicode glyph and a missing one renders as nothing, which makes a
	--  truncated label look merely wrong rather than truncated.
	return text:sub(1, SUMMARY_CHARS - 2) .. ".."
end

--  ---------------------------------------------------------------------------
--  RENDERING
--  ---------------------------------------------------------------------------

--  Put a number in a field and remember what is showing there.
--
--  THE BOOKKEEPING IS THE POINT. pollFields decides a player has typed by
--  seeing text it did not put there, so every write to a textbox has to update
--  shownText in the same breath -- otherwise the script's own render reads back
--  as an edit and commits itself in a loop.
--
--  CALLED ONLY WHEN THE REQUEST CHANGES, never while someone is typing. A
--  setText under a keystroke moves the caret, so an entry normalised mid-word
--  -- "0500" becoming "500" -- would fight the player for the cursor. The
--  displayed text is therefore allowed to differ cosmetically from what is
--  stored until the pane is next opened; the summary line is what states the
--  stored value, and it is right underneath.
local function setField(field, value)
	local text = value ~= nil and tostring(value) or ""

	self.shownText[field] = text

	--  pcall'd: a widget call that throws here would take rendering down with
	--  it and freeze the pane mid-draw.
	pcall(widget.setText, FIELD_WIDGET[field], text)
end

local function renderSummary()
	--  UNSAVED EDITS OUTRANK EVERYTHING ELSE THIS LINE COULD SAY.
	--
	--  The pane no longer closes when the beacon stops answering, so this is
	--  the only thing telling a player their change has not landed yet. It
	--  clears itself the moment the flush succeeds.
	if self.pendingWrite then
		widget.setText("summary", "Waiting for the beacon - change not saved yet.")
		return
	end

	local name = self.state.item
	local facts = self.facts

	if type(name) ~= "string" or name == "" then
		widget.setText("summary", "Drop a sample in the slot to name a request.")
		return
	end

	--  %s AND tostring, NOT %d.
	--
	--  Both numbers are materialised in init and range-checked on every commit,
	--  so they are always numbers -- but %d THROWS on anything else, and a throw
	--  here takes rendering down and leaves the pane frozen mid-draw. A summary
	--  reading "Keep nil to 1000" is a diagnosis; a dead pane is not. Same
	--  reasoning as routing every log through string.format first, applied to
	--  the one formatter that can reach a value the script did not produce.
	local label = facts and facts.label or name

	--  MIN ABOVE MAX IS ALLOWED, SO IT HAS TO BE EXPLAINED. Nothing stops the
	--  player typing it and the port copes with it, but "Keep 1000 to 500" tells
	--  them only that they have made a mess -- not what the crate will actually
	--  do, which is settle at max and stay there.
	if (self.state.min or 0) > (self.state.max or 0) then
		widget.setText("summary", truncate(string.format(
			"Fetch below is above fill to - holds %s %s.",
			tostring(self.state.max), label)))
		return
	end

	widget.setText("summary", truncate(string.format(
		"Keep %s to %s %s here.",
		tostring(self.state.min), tostring(self.state.max), label)))
end

--  The whole pane below the checkbox. Called when the REQUEST changes, never
--  from the poll -- it writes both fields, and doing that under a keystroke
--  would erase what the player was typing.
local function renderRequest()
	local name = self.state.item
	local facts = self.facts

	if type(name) == "string" and name ~= "" then
		--  COUNT 1, DELIBERATELY. The slot is a picture of WHAT is wanted, not
		--  of how much; a descriptor carrying the quota would draw "1k" in the
		--  corner and read as a statement about what the crate currently holds.
		widget.setItemSlotItem("itemSlot_request", { name = name, count = 1 })

		widget.setText("requestName", facts and facts.label or name)
		widget.setText("requestHint", "Right-click the slot to clear")

		setField("min", self.state.min)
		setField("max", self.state.max)
	else
		--  nil empties the slot. Not "" -- that is a descriptor with no name
		--  and the engine has no reason to accept it.
		widget.setItemSlotItem("itemSlot_request", nil)

		widget.setText("requestName", "Nothing requested")
		widget.setText("requestHint", "Click the slot holding an item")

		--  Blank rather than zero. There is no quota until there is an item,
		--  and a zero would look like one that had been set badly.
		setField("min", nil)
		setField("max", nil)
	end

	renderSummary()
end

--  Adopt an item name, and give it a quota that is already sensible.
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
--  It also keeps what lands on the item a bare string, which is what lets the
--  port match a quota by name the same way petports_filterAccepts does.
--
--  DEFAULTS ONLY WHEN THE ITEM CHANGES. Clicking the slot again with the same
--  item in hand is idempotent; it must not throw away numbers the player set.
local function setRequest(name)
	if self.state.item == name then
		dbg("setRequest(%s): unchanged, keeping quota %s..%s",
			tostring(name), tostring(self.state.min), tostring(self.state.max))
		return false
	end

	self.state.item = name
	self.facts = itemFacts(name)

	local stack = self.facts and self.facts.maxStack or ASSUMED_MAX_STACK

	--  A COMPLETE CONFIGURATION IN ONE CLICK. Dropping an item in should be
	--  the whole interaction for the common case, so the quota that lands is a
	--  working one with a gap already in it -- fill a stack, refetch at half.
	--  A player who wants 2000 dirt types it.
	self.state.max = math.max(1, math.min(stack, QUOTA_CEILING))
	self.state.min = math.max(1, math.floor(self.state.max / 2))

	dbg("setRequest(%s): label=%s stack=%s -> min=%s max=%s",
		tostring(name), tostring(self.facts and self.facts.label),
		tostring(stack), tostring(self.state.min), tostring(self.state.max))

	return true
end

local function clearRequest()
	dbg("clearRequest: was %s", tostring(self.state.item))

	--  LOCAL STATE ONLY, AND THAT IS NOW ENOUGH. Setting these to nil removes
	--  them from the table, and a field the write payload does not contain
	--  reads as "leave it alone" on the other end -- so the item has to be told
	--  separately. clearList does that by asking state what is absent, which
	--  means every caller just needs write() afterwards.
	--
	--  What lands on the item is an explicit JSON null rather than a removed
	--  key, which is the same settled engine behaviour the deposit beacon's
	--  header documents. Everything that reads these treats null and absent
	--  identically, and at maxStack 1 nothing was going to stack anyway.
	self.state.item = nil
	self.state.min = nil
	self.state.max = nil

	self.facts = nil
end

--  ---------------------------------------------------------------------------
--  THE TYPED FIELDS
--  ---------------------------------------------------------------------------

--  Take a field's text as the new value.
--
--  COMMITTED ON THE KEYSTROKE. There is nothing to wait for: the beacon has to
--  be HELD for this pane to be open, so it is not in a crate, no port is
--  reading it, and no unit can act on a half-typed number. The only thing an
--  intermediate value could ever have damaged was the OTHER field, and that is
--  gone -- see quotaValue.
--
--  DOES NOT WRITE BACK TO THE WIDGET. A rejected entry leaves the field showing
--  what was typed and the stored value untouched; snapping the text back would
--  move the caret out from under someone mid-number. The summary underneath is
--  what states the stored value.
local function commitField(field, text)
	local value = quotaValue(text)

	--  An EMPTY OR OUT-OF-RANGE field is someone mid-edit, not someone asking
	--  for nothing. The regex on the widget permits zero digits, so an empty
	--  box is the ordinary state of a field that has just been cleared to be
	--  retyped -- and committing a nil over a working quota would be its own
	--  bug.
	if value == nil or value == self.state[field] then
		dbg("commitField(%s, %s): no change", field, tostring(text))
		return
	end

	self.state[field] = value

	dbg("commitField(%s, %s) -> min=%s max=%s", field, tostring(text),
		tostring(self.state.min), tostring(self.state.max))

	write()
	renderSummary()
end

--  Read one field back and commit it if it moved.
--
--  TWO CALLERS, ON PURPOSE. The textbox's own callback is the responsive path,
--  and pollFields is the backstop -- because what a textbox callback actually
--  fires ON is not something this mod knows. Per keystroke, on enter, on focus
--  loss, or some combination are all plausible, and the pixel printer's config
--  answers none of them.
--
--  Sharing one function is what makes running both harmless. It commits only
--  when the text differs from what the script last put there, and commitField
--  writes only when the VALUE differs from what is stored, so a callback and a
--  poll arriving in the same tick cost one comparison.
local function syncField(field)
	if type(self.state) ~= "table" then return end
	if not self.fieldsUsable then return end

	local ok, text = pcall(widget.getText, FIELD_WIDGET[field])

	if not ok or type(text) ~= "string" then
		--  LOUD AND ONCE. If getText does not work on a textbox then the quota
		--  simply cannot be edited, and a pane where typing does nothing is
		--  exactly the symptom this file's header warns is indistinguishable
		--  from four other causes.
		self.fieldsUsable = false
		sb.logError("petports: restock pane cannot read %s; quota entry is "
			.. "disabled for this pane", FIELD_WIDGET[field])
		return
	end

	if type(self.state.item) ~= "string" or self.state.item == "" then
		--  Nothing requested, so there is no quota to type into. Anything that
		--  appears in the field is wiped, which is self-explanatory in a way
		--  that a silently ignored number is not.
		if text ~= "" then setField(field, nil) end
		return
	end

	if text ~= self.shownText[field] then
		self.shownText[field] = text
		commitField(field, text)
	end
end

--  Watch the textboxes for anything the callbacks did not deliver.
--
--  Cheap enough to leave in: two getText calls a tick, and every one of them
--  either matches what the script last wrote or is a keystroke worth acting on.
local function pollFields()
	for _, field in ipairs(QUOTA_FIELDS) do
		syncField(field)
	end
end

--  ---------------------------------------------------------------------------
--  ENGINE CALLBACKS
--  ---------------------------------------------------------------------------

--  Was this pane opened by a beacon sitting on the CURSOR rather than the
--  hotbar?
--
--  WHY IT MATTERS. Starbound locks the inventory's category tabs while
--  something is on the cursor -- the rule that stops a rifle being parked in a
--  food slot. A beacon held that way can therefore only ever see items in its
--  own category, which rules out most of the game. There is no supported way
--  around it and there should not be one.
--
--  THE TEST IS BY NAME, AND THAT HAS ONE KNOWN HOLE. If a beacon is on the
--  cursor then the cursor holds an item with our name -- that direction is
--  sound. The converse is not: a player with one restock beacon on the hotbar
--  and a SECOND on the cursor is refused when they should not be. Two beacons
--  at once is rare, the refusal explains itself, and the alternative needs a
--  way to ask which hotbar slot is selected that this mod has not verified
--  exists in retail.
--
--  DONE IN THE PANE RATHER THAN IN activate(). An activeitem script has no
--  `player` table -- see the header of petports_beacon.lua -- so it cannot read
--  the swap slot to find out where it is. The pane can.
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
--  player table at all. The pane is where the player is already looking and it
--  is guaranteed to render, so the message goes here until a better channel is
--  confirmed.
--
--  SPECIES-KEYED, with a default, and the value may be a string or an array of
--  lines. See hotbarOnlyMessage in the pane config for why no species entries
--  ship in this mod.
--
--  EVERY LINE GOES THROUGH truncate. The first build wrote the message straight
--  into the summary label and it ran off the side of the frame -- nothing on
--  this pane carries a wrapWidth, so an overlong string simply keeps going.
--  Two lines of room, and anything past the second is the author's problem
--  rather than a silent overflow.
local function lockWithNotice()
	local messages = config.getParameter("hotbarOnlyMessage") or {}
	local species = nil

	local ok, value = pcall(player.species)
	if ok and type(value) == "string" then species = value end

	local message = (species ~= nil and messages[species]) or messages["default"]

	--  A bare string is one line. Nothing shipped uses that shape, but a mod
	--  patching in something short should not have to know it wants an array.
	if type(message) == "string" then message = { message } end

	if type(message) ~= "table" then
		message = { "This must be used from the hotbar." }
	end

	sb.logInfo("PETPORTS restock pane: opened from the cursor (species %s); refusing",
		tostring(species))

	--  EVERYTHING THE EDITOR OWNS GOES AWAY, the slot backing included. An empty
	--  slot beside a refusal reads as an invitation to fill it.
	for _, name in ipairs({
		"slotBacking", "itemSlot_request", "requestHeading", "requestName",
		"requestHint", "enabledCheckbox", "enabledLabel", "minLabel", "maxLabel",
		"minFieldBacking", "maxFieldBacking", "tbMin", "tbMax", "summary"
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
	self.shownText = { min = "", max = "" }

	--  A write that could not reach the beacon, waiting for it to answer again.
	--  See write() and update().
	self.pendingWrite = false

	--  Whether the beacon answered on the last heartbeat. Reported, never acted
	--  on -- see update().
	self.reachable = true

	--  THE NOTICE IS OFF UNLESS SOMETHING TURNS IT ON. Declared visible in the
	--  config like every other widget, so hiding it here is what keeps three
	--  empty labels from sitting over the editor. Done before the refusal check
	--  below rather than after, so the ONE path that wants them can simply turn
	--  them back on.
	for _, name in ipairs({ "noticeTitle", "noticeLineOne", "noticeLineTwo" }) do
		pcall(widget.setVisible, name, false)
	end

	--  BEFORE THE READ. Nothing should be touched on an item this pane is about
	--  to refuse to edit, and self.state stays nil so update() and dismissed()
	--  both return early.
	if openedFromCursor() then
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

		--  Cleared so that update() and dismissed() -- both of which can still
		--  run after this -- have nothing to act on. Every entry point below
		--  tests for it.
		self.state = nil
		pane.dismiss()
		return
	end

	--  Lifted out of the state table so it is not echoed back inside the write
	--  payload and stored as a parameter.
	self.token = self.state.token
	self.state.token = nil

	--  A DEPOSIT BEACON'S FILTER MUST NOT RIDE ALONG.
	--
	--  petports_beacon.lua's FIELDS table is the union of every beacon type's
	--  keys, so a read answers for all of them. On a restock beacon `filter` is
	--  nil and this is a no-op; the line exists so that a beacon which somehow
	--  carries both cannot have its filter rewritten by a pane that never shows
	--  it. write() sends this whole table, and what it does not contain it
	--  cannot damage.
	self.state.filter = nil

	--  Resolve whatever the beacon already names. A beacon configured under a
	--  mod that has since been removed reads back a name that no longer
	--  resolves; the slot then draws nothing and the label falls back to the
	--  raw name, which is exactly the diagnosis the player needs.
	self.facts = itemFacts(self.state.item)

	if type(self.state.item) == "string" and self.state.item ~= "" then
		local stack = self.facts and self.facts.maxStack or ASSUMED_MAX_STACK

		--  Materialised here rather than on write, so everything below can
		--  assume both numbers exist. A beacon that names an item but carries
		--  no quota is not a shape this pane can produce, but it is one an
		--  older build or a hand-edited save could -- and quotaValue is what
		--  rejects a stored number that is out of range or not a number at all.
		self.state.min = quotaValue(self.state.min) or 1
		self.state.max = quotaValue(self.state.max)
			or math.max(1, math.min(stack, QUOTA_CEILING))
	end

	dbg("init: token=%s enabled=%s item=%s min=%s max=%s",
		tostring(self.token), tostring(self.state.enabled),
		tostring(self.state.item), tostring(self.state.min),
		tostring(self.state.max))

	widget.setChecked("enabledCheckbox", self.state.enabled ~= false)

	renderRequest()

	dbg("init: complete")
end

function update(dt)
	if type(self.state) ~= "table" then return end

	pollFields()

	self.holdTimer = self.holdTimer - dt
	if self.holdTimer > 0 then return end
	self.holdTimer = HOLD_CHECK_INTERVAL

	--  THIS NO LONGER CLOSES THE PANE, AND THAT IS A CORRECTION RATHER THAN A
	--  RELAXATION.
	--
	--  The liveness check used to dismiss on any unanswered heartbeat, on the
	--  reasoning that a pane must not outlive the item it edits. That reasoning
	--  was wrong: the TOKEN is what protects the beacon. A write aimed at the
	--  wrong item is refused there whether or not this check noticed anything,
	--  so dismissing bought no safety at all -- while costing the entire
	--  interaction, because filling an itemslot requires touching the inventory
	--  and touching the inventory is what stops the beacon answering.
	--
	--  So reachability is now something the pane REPORTS. The player closes the
	--  pane; the pane never closes itself. If edits are not landing, the summary
	--  line says so, which is strictly more information than a window that
	--  disappears.
	local answer = beaconAnswer()
	local reachable = answer == true

	if reachable ~= self.reachable then
		self.reachable = reachable

		--  Change-gated. At four checks a second an unchanging state is noise,
		--  and the RAW ANSWER is printed because nil and false have opposite
		--  causes -- see beaconAnswer.
		dbg("beacon %s (answer=%s, cursor=%s)",
			reachable and "reachable" or "UNREACHABLE",
			j(answer), tostring(cursorOccupied()))

		renderSummary()
	end

	--  The moment it answers again is the moment a held write can land. Every
	--  edit worth making is made while the inventory is in play, so this is the
	--  ordinary path for a sample reaching the item, not error recovery.
	if reachable and self.pendingWrite then
		dbg("flushing held write")
		write()
		renderSummary()
	end
end

--  Tell the item this pane is gone, so a player who closes and immediately
--  reopens is not refused. The item expires its own timer without this -- see
--  PANE_ALIVE there -- but that path is for panes that die badly.
--
--  ONE LAST ATTEMPT AT A HELD WRITE, AND IT IS A LONG SHOT RATHER THAN A
--  GUARANTEE.
--
--  Closing the pane while STILL carrying the sample is the one route that can
--  lose an edit: the beacon is shadowed, so the write never landed, and there
--  is no later heartbeat to flush it on. This tries anyway, because if closing
--  the pane returns the cursor item to the inventory first then the beacon is
--  reachable again by the time this runs.
--
--  WHETHER IT DOES IS UNVERIFIED. If the log shows this write still being held,
--  the answer is not more retries here -- it is the augment model, where the
--  beacon is the held item and the player right-clicks a target in their
--  inventory, so nothing ever occupies the cursor.
--
--  BEFORE the closed message, which clears the token on the item and would
--  make anything after it refuse for a real reason.
function dismissed()
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

function requestSlotClicked()
	local swap = player.swapSlotItem()

	dbg("requestSlotClicked: swap slot holds %s", j(swap))

	if type(swap) ~= "table" or type(swap.name) ~= "string" then
		--  Clicking with an empty cursor clears, which is the other half of the
		--  right-click. Two ways to reach it because the slot carries no label
		--  saying how.
		clearRequest()
		write()
		renderRequest()
		return
	end

	local changed = setRequest(swap.name)

	--  PUT IT BACK, UNCONDITIONALLY, AND DO NOT REASON ABOUT WHETHER IT MOVED.
	--
	--  Vanilla's mech assembly performs its swap in Lua, which strongly implies
	--  the engine does not touch the swap slot itself when an itemslot has a
	--  callback -- but "strongly implies" is not "verified", and the failure it
	--  would hide is a player's item disappearing into a beacon that never
	--  wanted it. Re-asserting the same descriptor is a no-op if the engine
	--  left it alone, and a rescue if it did not.
	player.setSwapSlotItem(swap)

	if changed then write() end
	renderRequest()
end

function requestSlotCleared()
	clearRequest()
	write()
	renderRequest()
end

--  THESE MUST EXIST OR THE PANE DOES NOT OPEN.
--
--  A textbox whose callback does not resolve throws at CONSTRUCTION, in the
--  client main loop, before a single widget is drawn -- and with no callback
--  declared the parser looks for one named after the widget. See tbMin in the
--  pane config for the exception text.
--
--  Deliberately thin. Whatever a textbox callback fires on -- keystroke, enter,
--  focus loss -- syncField answers the same way, and pollFields is running the
--  same check anyway.
function minChanged()
	syncField("min")
end

function maxChanged()
	syncField("max")
end
