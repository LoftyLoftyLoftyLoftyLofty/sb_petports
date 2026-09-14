-- Marker projectile that kills older duplicates of itself.

require "/scripts/vec2.lua"

local DEFAULT_CULL_RADIUS = 2.0

-- Reads petportsItem and installs the item, kill and move handlers.
function init()
	self.item = projectile.getParameter("petportsItem")
	self.culled = false

	if self.item == nil then
		sb.logWarn("PETPORTS crosshair spawned with no petportsItem parameter -- "
			.. "it cannot cull or be culled, and duplicates on this item will stack")
	end

	message.setHandler("petportsCrosshairItem", function()
		return self.item
	end)

	message.setHandler("kill", function()
		projectile.die()
	end)

	message.setHandler("move", function(_, _, position)
		if type(position) ~= "table" then return end

		mcontroller.setPosition(position)

		mcontroller.setVelocity({ 0, 0 })
	end)
end

-- On its first tick, kills nearby crosshairs with a lower entity id carrying the same item.
function update(dt)
	if self.culled then return end
	self.culled = true

	if self.item == nil then return end

	local radius = projectile.getParameter("petportsCullRadius", DEFAULT_CULL_RADIUS)
	local here = mcontroller.position()

	local ok, nearby = pcall(world.entityQuery, here, radius, {
		includedTypes = { "projectile" },

		withoutEntityId = entity.id()
	})

	if not ok then
		sb.logError("PETPORTS crosshair could not query for predecessors at %s: %s",
			sb.printJson(here), tostring(nearby))
		return
	end

	for _, other in ipairs(nearby or {}) do
		local answer = world.sendEntityMessage(other, "petportsCrosshairItem")

		if other < entity.id()
		   and answer:finished() and answer:succeeded()
		   and answer:result() == self.item then

			world.sendEntityMessage(other, "kill")
		end
	end
end
