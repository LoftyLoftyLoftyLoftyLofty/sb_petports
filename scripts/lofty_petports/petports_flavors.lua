local PETPORTS_FLAVOR_MANIFEST = "/scripts/lofty_petports/petports_flavors.config"

local petportsFlavorManifest = nil
local petportsFlavorsById = nil
local petportsFlavorOrder = nil

local petportsReagentIndex = nil

function petports_flavorManifest()
	if petportsFlavorManifest ~= nil then return petportsFlavorManifest end

	local ok, data = pcall(root.assetJson, PETPORTS_FLAVOR_MANIFEST)

	if not ok or type(data) ~= "table" or type(data.flavors) ~= "table" then
		sb.logError("petports: flavor manifest unreadable at %s; no flavors available",
			PETPORTS_FLAVOR_MANIFEST)
		petportsFlavorManifest = { flavors = {} }
		petportsFlavorsById = {}
		petportsFlavorOrder = {}
		petportsReagentIndex = {}
		return petportsFlavorManifest
	end

	petportsFlavorManifest = data
	petportsFlavorsById = data.flavors
	petportsFlavorOrder = {}
	petportsReagentIndex = {}

	for id, flavor in pairs(data.flavors) do
		if type(flavor) == "table" then
			flavor.id = id
			table.insert(petportsFlavorOrder, flavor)

			flavor.orderedReagents = {}

			for name, weight in pairs(flavor.reagents or {}) do
				if type(weight) == "number" then
					table.insert(flavor.orderedReagents,
						{ name = name, weight = weight })

					local seen = petportsReagentIndex[name]

					if seen ~= nil then
						sb.logError(
							"petports: reagent %s is in both %s and %s; keeping %s",
							name, tostring(seen.flavor), tostring(id),
							tostring(seen.flavor))
					else
						petportsReagentIndex[name] =
							{ flavor = id, weight = weight }
					end
				end
			end

			table.sort(flavor.orderedReagents, function(a, b)
				if a.weight ~= b.weight then return a.weight > b.weight end
				return a.name < b.name
			end)
		end
	end

	table.sort(petportsFlavorOrder, function(a, b)
		local ao, bo = a.order or 10000, b.order or 10000
		if ao ~= bo then return ao < bo end
		return tostring(a.id) < tostring(b.id)
	end)

	local reagents = 0
	for _ in pairs(petportsReagentIndex) do reagents = reagents + 1 end

	sb.logInfo("petports: %s flavor(s), %s reagent(s)",
		sb.printJson(#petportsFlavorOrder), sb.printJson(reagents))

	return petportsFlavorManifest
end

function petports_flavors()
	petports_flavorManifest()
	return petportsFlavorOrder or {}
end

function petports_flavor(flavorId)
	petports_flavorManifest()
	return petportsFlavorsById[flavorId]
end

function petports_flavorReagents(flavorId)
	local flavor = petports_flavor(flavorId)
	if flavor == nil then return {} end
	return flavor.orderedReagents or {}
end

function petports_reagentFor(itemName)
	if type(itemName) ~= "string" then return nil end
	petports_flavorManifest()
	return petportsReagentIndex[itemName]
end

function petports_reagentWeight(itemName)
	local entry = petports_reagentFor(itemName)
	return entry ~= nil and entry.weight or 0
end

function petports_reagentCount()
	petports_flavorManifest()
	local n = 0
	for _ in pairs(petportsReagentIndex or {}) do n = n + 1 end
	return n
end

function petports_flavorHex(flavorId)
	local flavor = petports_flavor(flavorId)
	if flavor == nil then return "ffffff" end

	local color = flavor.color

	if type(color) ~= "string" or #color ~= 6 then
		if flavor.color ~= nil then
			sb.logError("petports: flavor %s has an unusable color %s; wanted RRGGBB",
				tostring(flavorId), tostring(flavor.color))
		end
		return "ffffff"
	end

	return color
end

function petports_flavorColor(flavorId)
	return petports_flavorHex(flavorId) .. "ff"
end

function petports_flavorYield(flavorId)
	local flavor = petports_flavor(flavorId)
	local n = flavor and tonumber(flavor.yield) or 1
	if n < 1 then n = 1 end
	return math.floor(n)
end

function petports_flavorItem(flavorId)
	local flavor = petports_flavor(flavorId)
	if flavor == nil then return nil end

	if type(flavor.item) ~= "string" then
		sb.logError("petports: flavor %s names no item; it can never be produced",
			tostring(flavorId))
		return nil
	end

	return flavor.item
end

function petports_preferredFlavor(seed, eligible)
	local allowed = nil

	if type(eligible) == "table" and #eligible > 0 then
		allowed = {}
		for _, id in ipairs(eligible) do allowed[id] = true end
	end

	local candidates = {}
	for _, flavor in ipairs(petports_flavors()) do
		if flavor.id ~= nil and flavor.preference ~= false
		   and (allowed == nil or allowed[flavor.id]) then
			table.insert(candidates, flavor.id)
		end
	end

	if #candidates == 0 then return nil end

	local n = math.floor(tonumber(seed) or 0)
	if n < 0 then n = -n end

	return candidates[(n % #candidates) + 1]
end

function petports_flavorEligible(flavorId, eligible)
	if flavorId == nil then return false end
	if petports_flavor(flavorId) == nil then return false end

	if type(eligible) == "table" and #eligible > 0 then
		for _, id in ipairs(eligible) do
			if id == flavorId then return true end
		end
		return false
	end

	return true
end
