--  PETPORTS -- CROSSHAIR PROJECTILE SCRIPT
--
--  THREE JOBS: evict my predecessors, move where told, die when told.
--
--  ONE MARKER PER ITEM, ENFORCED BY THE MARKERS THEMSELVES.
--
--  The port tries not to create duplicates and mostly succeeds, but "tries not
--  to" only prevents the duplicates it knows about. A marker that evicts its
--  own predecessors makes the invariant TRUE BY CONSTRUCTION, and cleans up
--  after causes nobody anticipated -- a port that unloaded mid-task leaving a
--  marker with seconds of timeToLive left, a state that flapped faster than the
--  port's refresh, a second port that spawned nine milliseconds after the
--  first.
--
--  THE HIGHER ENTITY ID WINS, AND A TIE-BREAK IS NOT OPTIONAL.
--
--  This originally relied on spawn order: a marker spawning at t+9ms sees the
--  one from t, and the one from t saw nothing, so no comparison was needed.
--  That was wrong. The cull runs on the first UPDATE, not on spawn, so two
--  markers created in the same tick both run their first update after both
--  exist -- each finds the other, matches the item, and kills it. Nothing is
--  left marking the drop.
--
--  MEASURED, and a takeover is exactly what produces it:
--
--    12:07:48.650  PETPORT 4db5... crosshair SPAWN unroutable for drop 29
--    12:07:48.651  PETPORT c3f3... crosshair SPAWN routing for drop 29
--    12:07:49.139  PETPORT c3f3... crosshair SPAWN routing for drop 29 (previous none)
--
--  -- the third line is c3f3 rebuilding a marker that its own victim had
--  already killed on the way out.
--
--  Comparing entity ids makes the relation ANTISYMMETRIC, so exactly one of any
--  pair dies. Ids are allocated increasing, so the higher one is the newer one
--  and the newcomer still wins in the ordinary case.
--
--  FAILS TOWARD SURVIVAL. If ids ever wrapped or were reused, the worst case is
--  two markers both declining to kill -- a visible duplicate, which is what
--  this whole mechanism exists to clean up and will be cleaned up by the next
--  spawn. The opposite failure, both dying, leaves the drop unmarked with
--  nothing to notice it.
--
--  WHY THE ITEM ID AND NOT JUST PROXIMITY. Measured on a real spill: two drops
--  sat at x=1691.89 and x=1691.68, a fifth of a tile apart. A radius wide
--  enough to catch a genuine duplicate is far wider than the gap between
--  adjacent items in a pile, so without the id every marker in a spill would
--  evict its neighbours.
--
--  SILENCE MEANS LEAVE IT ALONE. The radius query returns every projectile
--  nearby -- watering droplets, anything from any other mod -- and only the
--  ones that ANSWER with a matching item are ours to cull. Treating no reply as
--  permission would make this script delete other mods' projectiles.

require "/scripts/vec2.lua"

--  How far to look for a predecessor.
--
--  Generous on purpose. A duplicate can be up to CROSSHAIR_DRIFT away on the
--  port side plus whatever the drop moved between the two spawns, and the item
--  id is what keeps the radius safe -- widening it costs nothing because
--  everything it catches has to identify itself before it dies.
local DEFAULT_CULL_RADIUS = 2.0

function init()
	--  UNVERIFIED BINDING, AND THE WHOLE DESIGN HANGS ON IT.
	--
	--  projectile.getParameter is how the watering droplet reads its
	--  actionOnReap override, so spawn parameters certainly reach a projectile
	--  script -- but that one is read by the ENGINE, not by Lua, so this is the
	--  first time the mod asks for one itself.
	--
	--  If it is not there, self.item is nil, every marker warns once on spawn,
	--  and duplicates stack exactly as they did before. Loud, and diagnosable
	--  from one line.
	self.item = projectile.getParameter("petportsItem")
	self.culled = false

	--  A marker with no item is not one of ours to reason about: it cannot
	--  identify itself to a successor and cannot recognise a predecessor. It
	--  still renders, and it will still be evicted by anything that CAN.
	if self.item == nil then
		sb.logWarn("PETPORTS crosshair spawned with no petportsItem parameter -- "
			.. "it cannot cull or be culled, and duplicates on this item will stack")
	end

	--  WHAT ITEM ARE YOU MARKING? Answered, not acted on -- the asker decides.
	--  A marker never volunteers to die; it only ever reports what it is.
	message.setHandler("petportsCrosshairItem", function()
		return self.item
	end)

	message.setHandler("kill", function()
		projectile.die()
	end)

	--  Reposition. Sent by the port when the drop this marks has moved far
	--  enough that the marker would visibly lag it.
	--
	--  mcontroller.setPosition rather than a velocity: the marker is not
	--  travelling to the drop, it IS at the drop, and anything that
	--  interpolates would put it briefly in the wrong place on every bounce.
	message.setHandler("move", function(_, _, position)
		if type(position) ~= "table" then return end

		mcontroller.setPosition(position)

		--  Belt and braces. speed is 0 and physics is "laser", so there should
		--  be nothing to cancel -- but a marker that has drifted once should not
		--  be able to keep drifting.
		mcontroller.setVelocity({ 0, 0 })
	end)
end

--  CULLED FROM update, NOT init.
--
--  Asking costs a round trip: world.sendEntityMessage returns a promise that
--  will not have resolved by the time init returns. Doing it on the first
--  update is the earliest point an answer can actually be read, and one frame
--  of two markers is invisible where a permanent stack is not.
function update(dt)
	if self.culled then return end
	self.culled = true

	if self.item == nil then return end

	local radius = projectile.getParameter("petportsCullRadius", DEFAULT_CULL_RADIUS)
	local here = mcontroller.position()

	--  SECOND UNVERIFIED BINDING: a radius-form entityQuery from inside a
	--  projectile. The rect form is used all over the port; this one takes a
	--  centre and a radius, and pcall'd because a signature mismatch here would
	--  otherwise take the marker down on its first update and leave a dead
	--  projectile sitting on the drop.
	local ok, nearby = pcall(world.entityQuery, here, radius, {
		includedTypes = { "projectile" },

		--  Never ourselves. Without this the first thing a marker does is ask
		--  itself what it is marking, agree, and die.
		withoutEntityId = entity.id()
	})

	if not ok then
		sb.logError("PETPORTS crosshair could not query for predecessors at %s: %s",
			sb.printJson(here), tostring(nearby))
		return
	end

	for _, other in ipairs(nearby or {}) do
		local answer = world.sendEntityMessage(other, "petportsCrosshairItem")

		--  ONE FRAME'S PATIENCE AND NO MORE. A projectile that is one of ours
		--  answers immediately -- the handler is a bare return with no work in
		--  it. Anything still thinking is not a crosshair, and waiting on it
		--  would mean holding a duplicate on screen for the sake of something
		--  that was never going to reply.
		--  ONLY DOWNWARD. See the header: without this, two markers spawned in
		--  the same tick kill each other and the drop ends up unmarked.
		if other < entity.id()
		   and answer:finished() and answer:succeeded()
		   and answer:result() == self.item then

			world.sendEntityMessage(other, "kill")
		end
	end
end
