--  PETPORTS -- BEACON ITEM
--
--  A beacon does its work by EXISTING IN A CONTAINER, not by being used. The
--  port reads container contents and finds `petports_sortingBeaconBehavior` in
--  the item's config; nothing here runs for that to work, and nothing here
--  should ever be required for it to work.
--
--  What this script IS for: opening the configuration pane, and answering the
--  pane's questions about this specific item instance.
--
--  THE MESSAGE CHANNEL, AND WHY IT WORKS.
--
--  A ScriptPane cannot touch the item that opened it -- it has a `player`
--  table, not an `activeItem` one. Vanilla's stationtransponder solves this by
--  registering message handlers on the ITEM and having the pane send messages
--  to the PLAYER: messages addressed to a player entity are delivered to the
--  scripts of whatever that player is holding. So the pane talks to the item
--  through the player, and the item is the only thing that can write to itself.
--
--  Verified by placestation.lua, which polls `holdingTransponder` every tick
--  and calls `:result()` on the promise IMMEDIATELY. That only works because
--  both ends are on the same client, so the promise resolves in the same call.
--  DO NOT COPY THAT IDIOM ANYWHERE NEAR THE PORT -- a petport is
--  world-mastered, its promises take at least a tick, and a nil result there
--  reads as "no" rather than "not yet".
--
--  ONE BEACON PER SLOT.
--
--  maxStack is 1. Per-instance configuration requires it, and the alternative
--  was several visually identical stacks that refused to merge -- see the
--  .activeitem header for why blank-stays-stackable is unreachable rather than
--  merely unimplemented.

--  Read by the pane, written by the pane. Defaults live here rather than in
--  the .activeitem so that a beacon crafted before this feature existed
--  answers the same as one crafted after.
local DEFAULTS =
{
	enabled = true
}

--  Everything the pane can read or write, and nothing else. A parameter not
--  in this list cannot be reached from the GUI, which is deliberate: the
--  behaviour tag is CONFIG state and must never become instance state, or a
--  beacon could be edited into a different kind of beacon.
local FIELDS =
{
	enabled = "petports_beaconEnabled",

	--  The deposit filter, shape documented in petports_filters.lua. Absent
	--  means accept everything -- identical to the unconditional deposit beacon
	--  that shipped before filters existed, which is what a fresh beacon must
	--  behave like. There is no DEFAULTS entry for it: a table would never
	--  compare equal to one anyway, so it is always written rather than
	--  compared away.
	filter = "petports_beaconFilter",

	--  RESTOCK BEACON ONLY -- and this table is deliberately the UNION of every
	--  beacon type's fields rather than one table per type.
	--
	--  The write handler only writes what the pane SENDS, and readConfig only
	--  returns what the item CARRIES, so a deposit beacon answers nil for all
	--  of these and its pane never mentions them. A per-type table would have
	--  to be selected from somewhere, and the only thing available to select on
	--  is the behaviour tag -- which this script is careful never to read,
	--  because that is the one piece of state that must stay in config and
	--  never become a parameter. See the header.
	--
	--  No DEFAULTS entries. A fresh restock beacon requests nothing, and
	--  "nothing" is absence rather than a value; the pane materialises the list
	--  when an item is first sampled, the same way the deposit pane
	--  materialises an empty filter table.
	--
	--  `requests` is an ARRAY of { item, min, max }. One crate, many items --
	--  see petports_restockMisfits for why that beat one request per beacon.
	requests = "petports_beaconRequests",

	--  SUPERSEDED BY `requests`, AND STILL LISTED ON PURPOSE.
	--
	--  These are what a restock beacon carried before the list existed. They
	--  stay readable so the pane can migrate one on open, and stay CLEARABLE so
	--  the same write that stores the list can name them in its clear list. A
	--  field dropped from this table would be a field nothing could ever remove
	--  again -- it would sit in the save forever, and the port would keep
	--  finding it.
	item = "petports_beaconItem",
	min = "petports_beaconMin",
	max = "petports_beaconMax"
}

--  ICON: A DEDICATED SETTER FOR THE SLOT, A GLOBAL TAG FOR THE HAND.
--
--  activeItem.setInventoryIcon(image) is the callback for this and there is no
--  substitute for it. The long detour that found it is worth recording so none
--  of it gets re-run:
--
--    setInstanceValue("inventoryIcon", ...)   nothing. Not parameter-overridable.
--    a build script writing config.inventoryIcon   nothing.
--    retainScriptStorageInItem                 no difference.
--    maxStack 1                                no difference.
--    animationCustom.globalTagDefaults         untested; superseded by this.
--
--  The global tag still earns its place: it repaints the HELD item instantly,
--  and it is what makes the two-frame sheet work in the hand. The setter
--  handles every renderer that has no live animator -- hotbar, inventory grid,
--  a container slot.
--
--  FRAME-QUALIFIED, ABSOLUTE PATH. The icon is one 32x16 sheet with frames
--  named in default.frames. Absolute because a relative path resolves against
--  the item definition's directory and a runtime setter is not read in that
--  context.
--
--  ABSENCE IS STILL CANONICAL for the enabled PARAMETER -- see the write
--  handler. The icon is not a parameter at all, so it has no bearing on
--  stacking either way.
--
--  PER TYPE, FROM CONFIG. This was a constant naming the deposit sheet, which
--  was correct while there was one beacon. It is a config field for the same
--  reason interactAction and interactData are: one script serves every beacon
--  type, and a second type is then a new .activeitem rather than a branch in
--  here. A beacon that omits the field keeps its animated icon -- the global
--  tag below still fires -- and only loses the slot-renderer half.
local ICON_KEY = "petports_beaconIcon"

--  How long after the pane's last sign of life it is still assumed open.
--  Comfortably longer than the pane's own 0.25s poll, short enough that a pane
--  which died without saying so unblocks quickly.
local PANE_ALIVE = 1.0

--  Verbose while this is being built. Flip to false before shipping; leave the
--  calls. See the pane script for why the inputs matter more than the verdicts.
local DEBUG = false

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
	sb.logInfo("petports beacon: %s", ok and text or ("<badformat> " .. tostring(fmt)))
end

local function j(value)
	if value == nil then return "nil" end
	local ok, text = pcall(sb.printJson, value)
	if ok then return text end
	return "<unprintable " .. type(value) .. ">"
end

--  EVERY PANE MESSAGE CARRIES A TOKEN, AND HERE IS WHY.
--
--  A pane addresses this item as world.sendEntityMessage(player.id(), ...),
--  which the engine routes to WHATEVER THE PLAYER IS CURRENTLY HOLDING. Every
--  beacon registers the same handlers, so a pane opened from hotbar slot 5 got
--  a cheerful "yes, still held" from the different beacon in slot 6 and went on
--  editing it. The liveness check was asking "is a beacon held", not "is MY
--  beacon held", and writes landed on the wrong item.
--
--  So the item mints a token when it opens a pane, the pane echoes it back on
--  every message, and a beacon that did not mint it refuses.
--
--  IT IS AN INSTANCE VALUE, AND THAT IS A REVERSAL.
--
--  This used to be runtime state only, on the reasoning that a per-pane random
--  value written into the item would stop two otherwise identical beacons
--  stacking. That reasoning is dead twice over. Beacons are maxStack 1, so
--  there is no stacking to protect; and runtime state does not survive, which
--  a log settled rather than a guess:
--
--    petports beacon: write REFUSED: token=ab5b61a2... mine=nil
--
--  The item was RUNNING and ANSWERING -- so this is not the shadowing case --
--  and had simply lost the token. Taking an item onto the cursor and putting it
--  back re-creates the held item, init() runs again, and self.paneToken is gone
--  for good, because activate() is the only thing that ever set it. The pane
--  could then never write, and the player's edit was lost every time.
--
--  Restoring it in init() closes that. NOT IN FIELDS, deliberately: this is the
--  item's own bookkeeping and the pane must not be able to read or write it.
local TOKEN_KEY = "petports_beaconPaneToken"

local function newToken()
	--  Guarded rather than assumed. If sb.makeUuid is unavailable the fallback
	--  is weaker but sufficient: this only has to distinguish a handful of
	--  beacons in one inventory, not be unguessable.
	if sb.makeUuid then return sb.makeUuid() end
	return tostring(math.random(1, 1073741824))
end

local function setIcon(enabled)
	local frame = enabled and "on" or "off"

	--  The held item: live animator, instant.
	animator.setGlobalTag("state", frame)

	--  Every slot that draws the item without running it.
	--
	--  GUARDED, LOUDLY. A nil here would concatenate into a runtime error and
	--  take init() down with it, which presents as "the beacon does nothing
	--  when used" -- several steps from a missing field in a .activeitem.
	local base = config.getParameter(ICON_KEY)

	if type(base) ~= "string" then
		sb.logError("petports beacon: no %s in item config; slot icon will not "
			.. "track on/off state", ICON_KEY)
		return
	end

	activeItem.setInventoryIcon(base .. ":" .. frame)
end

local function readConfig()
	local out = {}
	for field, key in pairs(FIELDS) do
		out[field] = config.getParameter(key, DEFAULTS[field])
	end
	return out
end

function init()
	--  FIRST, BEFORE ANY HANDLER CAN BE ASKED ANYTHING.
	--
	--  init() runs again every time the held item is re-created, which the
	--  player triggers just by moving something through the cursor. Without
	--  this the token minted by activate() is gone and the open pane can never
	--  write again -- see TOKEN_KEY for the log that proved it.
	--
	--  TYPE-CHECKED, NOT NIL-CHECKED. setInstanceValue(key, nil) writes an
	--  explicit JSON null rather than removing the key, so a beacon whose pane
	--  has closed reads back a null here. That is not a token and must not be
	--  treated as one, or the next pane would be compared against it.
	self.paneToken = config.getParameter(TOKEN_KEY)

	if type(self.paneToken) ~= "string" then
		self.paneToken = nil
	else
		--  Worth a line. A restore means the item was re-created underneath a
		--  live pane, which is invisible from anywhere else.
		dbg("init: restored pane token %s", tostring(self.paneToken))
	end

	--  The pane's liveness check. It polls this every tick and reports the
	--  answer rather than acting on it, which is how it notices the player
	--  swapped items mid-edit. Answers only for the pane THIS item opened.
	message.setHandler("petports_beaconHeld", function(_, _, token)
		if token == nil or token ~= self.paneToken then return false end

		--  Doubles as the pane's heartbeat. See activate().
		self.paneTimer = PANE_ALIVE
		return true
	end)

	--  The normal close path. Without this the heartbeat would still expire on
	--  its own, but a player who closes the pane and immediately clicks again
	--  would be refused for up to a second and conclude the item is broken.
	message.setHandler("petports_beaconPaneClosed", function(_, _, token)
		if token == nil or token ~= self.paneToken then return false end

		self.paneTimer = 0
		self.paneToken = nil

		--  The stored copy goes too, or a beacon carries a dead token around
		--  forever. It lands as an explicit JSON null rather than a removed
		--  key, which init() type-checks for.
		activeItem.setInstanceValue(TOKEN_KEY, nil)

		dbg("pane closed cleanly, token cleared")
		return true
	end)

	--  The one handler with no token to check, because this is where the pane
	--  LEARNS the token. Safe only because it runs at pane init, one tick after
	--  activate() -- the held item is still the one that opened it. A read with
	--  no token minted returns none, and the pane fails closed.
	message.setHandler("petports_beaconRead", function()
		--  Fires at pane init, before the first heartbeat is due.
		self.paneTimer = PANE_ALIVE

		local out = readConfig()
		out.token = self.paneToken
		dbg("read -> %s", j(out))
		return out
	end)

	--  Set on spawn as well as on write. globalTagDefaults covers a beacon
	--  that has never been configured; this covers one that was switched off
	--  and then re-entered the world -- picked up, taken out of a chest,
	--  reloaded -- where the tag starts at its default and the parameter says
	--  otherwise.
	setIcon(config.getParameter(FIELDS.enabled, DEFAULTS.enabled) ~= false)

	--  The only writer. Unknown fields are ignored rather than written
	--  through, so a stale pane from an older version cannot inject keys
	--  nobody reads.
	--
	--  DEFAULTS ARE STORED AS ABSENCE.
	--
	--  Stacking compares name AND parameters, so a beacon at its defaults
	--  should ideally carry none.
	--
	--  KNOWN AND ACCEPTED: it does not fully work, and the reasons are settled
	--  by a save dump rather than guessed. setInstanceValue(key, nil) writes an
	--  explicit JSON null instead of removing the key, and
	--  activeItem.setInventoryIcon ALSO writes a parameter -- so any beacon
	--  that has been held differs from a pristine one regardless of what the
	--  pane does. A build script cannot fix it either: builders run constantly
	--  but produce parameters transiently per construction and never write back
	--  to the stored descriptor.
	--
	--  Attempts to close this made behaviour worse and were rolled back. The
	--  practical effect is extra inventory stacks, nothing more: null and
	--  absent both read as the default here, in the pane, and in
	--  beaconBehaviorOf on the port.

	--  CLEARING IS ITS OWN ARGUMENT, BECAUSE nil IS NOT A VALUE IN LUA.
	--
	--  `data` is a table, and a table cannot carry "this field is now nothing"
	--  -- setting a key to nil removes it, which is indistinguishable from the
	--  pane never having mentioned it. The loop below reads absence as "leave
	--  this alone", which is what makes one write handler serve two panes that
	--  each touch a different subset of FIELDS.
	--
	--  So a pane that wants a field GONE names it in `clear`. The deposit pane
	--  never has -- its filter is always written, never removed -- and passes
	--  nothing, which is why this is a fourth argument rather than a change to
	--  the third.
	--
	--  What lands is still an explicit JSON null rather than a removed key. See
	--  the note above: that is a settled engine behaviour, and null and absent
	--  read identically everywhere either is looked at.
	message.setHandler("petports_beaconWrite", function(_, _, token, data, clear)
		--  The write that was landing on the wrong beacon.
		if token == nil or token ~= self.paneToken then
			--  Expected and harmless when the player has swapped beacons: the
			--  pane is about to dismiss itself. Logged because a token mismatch
			--  in any OTHER circumstance means a write was silently dropped.
			dbg("write REFUSED: token=%s mine=%s",
				tostring(token), tostring(self.paneToken))
			return false
		end

		if type(data) ~= "table" then
			dbg("write REFUSED: data is %s not table", type(data))
			return false
		end

		dbg("write accepted -> %s", j(data))

		for field, key in pairs(FIELDS) do
			if data[field] ~= nil then
				if data[field] == DEFAULTS[field] then
					dbg("  clear %s (equals default)", key)
					activeItem.setInstanceValue(key, nil)
				else
					dbg("  set %s = %s", key, j(data[field]))
					activeItem.setInstanceValue(key, data[field])
				end
			end
		end

		--  AFTER the writes, not before. A pane that both sets and clears in
		--  one message is not a shape anything produces today, but if one ever
		--  does, "clear wins" is the answer that matches what the player just
		--  clicked -- clearing is always the more recent, more deliberate act.
		if type(clear) == "table" then
			for _, field in ipairs(clear) do
				local key = FIELDS[field]

				if key == nil then
					--  Same rule as the write loop above: a field this script
					--  does not know is ignored rather than acted on, so a
					--  stale pane cannot reach anything it was never given.
					dbg("  clear IGNORED: %s is not a known field", tostring(field))
				else
					dbg("  clear %s", key)
					activeItem.setInstanceValue(key, nil)
				end
			end
		end

		if data.enabled ~= nil then
			setIcon(data.enabled ~= false)
		end

		return true
	end)
end

function update(dt, fireMode, shifting, moves)
	if (self.paneTimer or 0) > 0 then
		self.paneTimer = self.paneTimer - dt
	end
end

function activate(fireMode, shifting)
	--  ONE PANE AT A TIME. activeItem.interact opens a new pane every call, so
	--  clicking repeatedly stacked identical panes -- each with its own read of
	--  the item, each able to write. Two panes disagreeing about the same
	--  beacon is a genuine correctness problem, not just clutter.
	--
	--  TIMER, NOT A FLAG. A plain "pane is open" boolean sticks forever if the
	--  pane dies without saying so -- player death, world change, an error in
	--  the pane script -- and the beacon becomes permanently unopenable with no
	--  way for the player to recover. The pane already polls this item every
	--  0.25s to check it is still held; that poll refreshes this timer, so
	--  "open" means "something answered recently" and stops being true on its
	--  own the moment nothing does.
	if (self.paneTimer or 0) > 0 then
		dbg("activate ignored, pane still alive (%.2fs left)", self.paneTimer)
		return
	end

	--  Armed here rather than waiting for the first poll: init sends its read
	--  immediately but the first heartbeat is 0.25s out, and a fast second
	--  click lands inside that gap.
	self.paneTimer = PANE_ALIVE
	self.paneToken = newToken()

	--  PERSISTED IMMEDIATELY, NOT ON FIRST USE. The re-init that loses a
	--  runtime token can happen at any point after this, including before the
	--  pane has sent a single message. See TOKEN_KEY.
	activeItem.setInstanceValue(TOKEN_KEY, self.paneToken)

	--  Both buttons open it. There is no second thing a beacon could do when
	--  used, and a player who tries the other button and gets nothing assumes
	--  the item is broken.
	dbg("activate: opening %s at %s token=%s",
		tostring(config.getParameter("interactAction")),
		tostring(config.getParameter("interactData")),
		tostring(self.paneToken))

	activeItem.interact(config.getParameter("interactAction"),
		config.getParameter("interactData"))
end

function uninit()
end
