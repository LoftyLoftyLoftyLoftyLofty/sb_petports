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
	enabled = "petports_beaconEnabled"
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
local ICON_BASE = "/items/lofty_petports/beacons/petports_beacon_deposit.png"

--  How long after the pane's last sign of life it is still assumed open.
--  Comfortably longer than the pane's own 0.25s poll, short enough that a pane
--  which died without saying so unblocks quickly.
local PANE_ALIVE = 1.0

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
--  every message, and a beacon that did not mint it refuses. Runtime state, not
--  a parameter -- it must never reach the item's data or two beacons that are
--  otherwise identical would stop stacking.
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
	activeItem.setInventoryIcon(ICON_BASE .. ":" .. frame)
end

local function readConfig()
	local out = {}
	for field, key in pairs(FIELDS) do
		out[field] = config.getParameter(key, DEFAULTS[field])
	end
	return out
end

function init()
	--  The pane's liveness check. It polls this every tick and dismisses
	--  itself when the answer stops arriving, which is how it notices the
	--  player swapped items mid-edit. Without it, a save would write the
	--  filter into whatever ended up in hand instead.
	--  Answers only for the pane THIS item opened. A beacon the player has
	--  swapped to returns false, and the pane dismisses itself rather than
	--  silently retargeting.
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

	message.setHandler("petports_beaconWrite", function(_, _, token, data)
		--  The write that was landing on the wrong beacon.
		if token == nil or token ~= self.paneToken then return false end
		if type(data) ~= "table" then return false end

		for field, key in pairs(FIELDS) do
			if data[field] ~= nil then
				if data[field] == DEFAULTS[field] then
					activeItem.setInstanceValue(key, nil)
				else
					activeItem.setInstanceValue(key, data[field])
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
	if (self.paneTimer or 0) > 0 then return end

	--  Armed here rather than waiting for the first poll: init sends its read
	--  immediately but the first heartbeat is 0.25s out, and a fast second
	--  click lands inside that gap.
	self.paneTimer = PANE_ALIVE
	self.paneToken = newToken()

	--  Both buttons open it. There is no second thing a beacon could do when
	--  used, and a player who tries the other button and gets nothing assumes
	--  the item is broken.
	activeItem.interact(config.getParameter("interactAction"),
		config.getParameter("interactData"))
end

function uninit()
end
