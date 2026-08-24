--  PETPORTS -- BEACON CONFIGURATION PANE SCRIPT
--
--  Talks to the held beacon through the player. See the header of
--  petports_beacon.lua for why that indirection exists and why calling
--  :result() immediately is safe HERE and nowhere near the port.
--
--  WRITE-ON-CHANGE, NOT WRITE-ON-CLOSE. There is no save button and there will
--  not be one: a pane that can be closed with the X, with Escape, or by the
--  player switching items has three exits and only one of them could run a
--  save handler. Writing each change as it happens means every exit is safe.

--  How often the liveness poll runs. Every tick is what vanilla's transponder
--  does, but that pane is a full-screen deploy sequence where an unnoticed
--  item swap loses a station. This one just needs to notice within a moment.
local HOLD_CHECK_INTERVAL = 0.25

--  TOKEN ON EVERY MESSAGE. Messages go to player.id() and the engine routes
--  them to whatever is HELD, not to the item this pane came from. Without the
--  token, swapping to a second beacon left this pane happily editing the new
--  one: the liveness check still said "yes, held", because a different beacon
--  was answering it.
local function heldBeacon()
	--  false both when nothing answers and when the wrong beacon answers. Both
	--  mean the same thing here: this pane no longer has its item.
	local promise = world.sendEntityMessage(player.id(), "petports_beaconHeld", self.token)
	return promise:result() == true
end

--  One writer, one place. Every widget callback funnels through here so that
--  what the pane believes and what the item stores cannot drift.
local function write()
	world.sendEntityMessage(player.id(), "petports_beaconWrite", self.token, self.state)
end

function init()
	self.holdTimer = 0

	local promise = world.sendEntityMessage(player.id(), "petports_beaconRead")
	self.state = promise:result()

	--  FAIL CLOSED. If the read did not answer, the pane does not know what it
	--  is editing, and writing defaults over an existing configuration is worse
	--  than not opening at all.
	if type(self.state) ~= "table" or self.state.token == nil then
		sb.logError("petports: beacon pane opened with no readable beacon; dismissing")
		pane.dismiss()
		return
	end

	--  Lifted out of the state table so it is not echoed back inside the write
	--  payload and stored as a parameter -- which would put a per-pane random
	--  value on the item and stop beacons stacking.
	self.token = self.state.token
	self.state.token = nil

	widget.setChecked("enabledCheckbox", self.state.enabled ~= false)
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
--  reopens is not refused. The item also expires its own timer without this --
--  see PANE_ALIVE there -- but that path exists for panes that die badly, not
--  for the ordinary close.
function dismissed()
	world.sendEntityMessage(player.id(), "petports_beaconPaneClosed", self.token)
end

function enabledToggled()
	self.state.enabled = widget.getChecked("enabledCheckbox")
	write()
end
