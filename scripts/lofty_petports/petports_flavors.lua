--  PETPORTS -- FLAVOR TABLE ACCESS
--
--  Reads petports_flavors.config and hands it back in display order. Shared by
--  the upcycler (object script), its config pane, and eventually whatever
--  consumes fuel.
--
--  PREFIXED FUNCTIONS ONLY, same rule as petports_filters.lua. This may end up
--  in a monster's script list, and a monster's scripts share one Lua
--  environment -- a bare init/update/uninit here would silently replace
--  groundPet.lua's.
--
--  WHAT THE CONFIG IS
--
--      flavors = {
--        spicy = {
--          label    = "Spicy",
--          order    = 10,
--          item     = "petports_petfuel_spicy",
--          reagents = { scorchedcore = 8, chili = 2, ... }
--        },
--        ...
--      }
--
--  A reagent's number is its WEIGHT: how many treats one of it flavors. There
--  is no second value and no efficiency stat -- the batch length IS the value.
--
--  KEYED BY ID, NOT AN ARRAY, for the same reason the filter manifest is: a mod
--  patches "/flavors/umami" rather than counting its way to "/flavors/7". An
--  index is a promise about everyone else's file that cannot be kept.
--
--  The cost is that Lua key order is meaningless, so display order is stated
--  per entry and normalised here once. NOTHING DOWNSTREAM MAY ITERATE
--  `manifest.flavors` DIRECTLY -- use petports_flavors(). Doing it the other way
--  is what made every subgroup tile in the beacon pane silently do nothing.
--
--  REVERSE LOOKUP IS BUILT HERE TOO. "which flavor does this reagent belong to"
--  is the question the upcycler asks on every reagent slot change, and walking
--  seven tables of up to eighty entries to answer it would be per-tick work for
--  a fact that cannot change without an asset reload.

local PETPORTS_FLAVOR_MANIFEST = "/scripts/lofty_petports/petports_flavors.config"

local petportsFlavorManifest = nil
local petportsFlavorsById = nil
local petportsFlavorOrder = nil

--  reagent item name -> { flavor = <id>, weight = <n> }
local petportsReagentIndex = nil

--  Parse once per script context. Patches are applied at asset load, so
--  re-reading would cost work and change nothing.
function petports_flavorManifest()
	if petportsFlavorManifest ~= nil then return petportsFlavorManifest end

	local ok, data = pcall(root.assetJson, PETPORTS_FLAVOR_MANIFEST)

	if not ok or type(data) ~= "table" or type(data.flavors) ~= "table" then
		--  FAIL LOUD, FAIL EMPTY. No flavors means the reagent slot refuses
		--  everything and the upcycler produces plain treats, which is exactly
		--  what it did before flavors existed. Inventing a fallback would mean
		--  guessing which item makes which flavor, and a wrong guess is worse
		--  than the feature being off.
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
			--  The id is copied onto the entry so nothing downstream has to
			--  carry the key alongside the value.
			flavor.id = id
			table.insert(petportsFlavorOrder, flavor)

			--  ORDERED REAGENT LIST, BUILT HERE RATHER THAN IN THE PANE.
			--
			--  Sorted by weight DESCENDING, then by name. The question a player
			--  brings to the reagent list is "what is the best thing I have for
			--  this flavor", and weight-descending answers it reading top-down
			--  -- which matters because Savory is eighty entries and will
			--  always scroll.
			flavor.orderedReagents = {}

			for name, weight in pairs(flavor.reagents or {}) do
				if type(weight) == "number" then
					table.insert(flavor.orderedReagents,
						{ name = name, weight = weight })

					--  FIRST ENTRY WINS ON A COLLISION, and it is logged rather
					--  than silently resolved. A reagent in two flavors is a
					--  manifest bug -- most likely two mods claiming the same
					--  item -- and the player needs to be able to find out why
					--  their cores stopped making Spicy.
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

	--  Ties break on id so the result is stable rather than merely
	--  deterministic. Numbering in tens leaves room to slot between.
	table.sort(petportsFlavorOrder, function(a, b)
		local ao, bo = a.order or 10000, b.order or 10000
		if ao ~= bo then return ao < bo end
		return tostring(a.id) < tostring(b.id)
	end)

	--  Counted inline rather than through petports_reagentCount(), which calls
	--  back into this function. The guard above makes that safe today only
	--  because petportsFlavorManifest is assigned before this line -- a
	--  reentrancy that works by accident is one somebody reorders later.
	local reagents = 0
	for _ in pairs(petportsReagentIndex) do reagents = reagents + 1 end

	sb.logInfo("petports: %s flavor(s), %s reagent(s)",
		sb.printJson(#petportsFlavorOrder), sb.printJson(reagents))

	return petportsFlavorManifest
end

--  Every flavor, in display order. Each carries its own id.
function petports_flavors()
	petports_flavorManifest()
	return petportsFlavorOrder or {}
end

--  One flavor by id, or nil.
function petports_flavor(flavorId)
	petports_flavorManifest()
	return petportsFlavorsById[flavorId]
end

--  One flavor's reagents, heaviest first, as { name = , weight = }.
function petports_flavorReagents(flavorId)
	local flavor = petports_flavor(flavorId)
	if flavor == nil then return {} end
	return flavor.orderedReagents or {}
end

--  WHAT DOES THIS REAGENT DO? nil for anything that is not a reagent.
--
--  This is the whole reagent-slot contract. FAIL CLOSED on nil: an item that is
--  not in the table is refused rather than silently producing plain treats,
--  because a slot that accepts something and does nothing with it reads as a
--  broken machine.
function petports_reagentFor(itemName)
	if type(itemName) ~= "string" then return nil end
	petports_flavorManifest()
	return petportsReagentIndex[itemName]
end

--  How many treats one of this item flavors, or 0 if it is not a reagent.
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

--  The blip colour for a flavor, as RRGGBBAA ready for "?multiply=".
--
--  EIGHT DIGITS OUT, SIX DIGITS IN. The config stores RRGGBB because that is
--  what anyone editing it will type; the directive wants alpha too, and a
--  flavour is never drawn translucent.
--
--  A flavour with no colour falls back to white, which multiplies to no change
--  at all -- so a mod that forgets the field gets a visible plain blip rather
--  than an invisible one or an error.
function petports_flavorColor(flavorId)
	local flavor = petports_flavor(flavorId)
	if flavor == nil then return "ffffffff" end

	local color = flavor.color

	if type(color) ~= "string" or #color ~= 6 then
		if flavor.color ~= nil then
			sb.logError("petports: flavor %s has an unusable color %s; wanted RRGGBB",
				tostring(flavorId), tostring(flavor.color))
		end
		return "ffffffff"
	end

	return color .. "ff"
end

--  The treat item a flavor produces. nil is a MANIFEST ERROR rather than an
--  ordinary absence -- a flavor that names no item cannot be made, so the
--  reagent for it would be accepted and then produce nothing.
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
