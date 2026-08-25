--  PETPORTS -- FILTER EVALUATION
--
--  Shared by the petport (object script), the beacon item, and the config pane.
--  Required from a monster's script list among others, so it must define
--  PREFIXED FUNCTIONS ONLY -- a monster's scripts share one Lua environment and
--  a bare init/update/uninit here would silently replace groundPet.lua's.
--
--  WHAT A FILTER IS
--
--      {
--        base  = "accept" | "deny",        -- the verdict before any rule
--        rules =                           -- evaluated TOP TO BOTTOM
--        [
--          { action = "deny",   group = "weapons", except = { "melee" } },
--          { action = "accept", item  = "ironore" }
--        ]
--      }
--
--  LAST MATCH WINS. Start at `base`, walk the rules in order, and every rule
--  that matches overwrites the verdict. The bottom of the list is the most
--  specific thing the player said.
--
--  This inverts the firewall convention (first match wins, exceptions on top),
--  and it is the right way round here: a filter reads as "start from this, then
--  carve exceptions". The pane has to make the direction obvious or players
--  will write exceptions above the base and see nothing happen.
--
--  The upside is that CONFLICTS ARE NOT CONFLICTS. "accept iron" above "deny
--  iron" is well defined, so nothing has to validate, warn, or explain -- a
--  whole class of UI work that simply does not exist.
--
--  ABSENT MEANS ACCEPT EVERYTHING.
--
--  A beacon that has never been configured carries no parameters at all, and it
--  must behave exactly like the unconditional deposit beacon that shipped
--  before filters existed. A fresh beacon that silently accepts nothing is
--  indistinguishable from a broken mod.
--
--  COST
--
--  Matching needs an item's category and tags, which means root.itemConfig --
--  expensive, and per the handoff it re-runs an item's build script with a
--  fresh time-based seed when the descriptor lacks one. The port asks about the
--  same handful of item names over and over, so results are memoised by NAME.
--  Never memoise by descriptor: two stacks of the same item with different
--  parameters share a category and tags.

--  UNDER /scripts, NOT A FOLDER OF ITS OWN.
--
--  The vanilla client resolves asset paths against a fixed set of top-level
--  folder names, so a mod-invented directory like /filters is not reliably
--  reachable. Data files belong beside the code that reads them.
local PETPORTS_FILTER_MANIFEST = "/scripts/lofty_petports/petports_filtergroups.config"

--  Verbose while this is being built. This one is noisier than the others --
--  it fires per cargo stack per candidate container -- so it is worth turning
--  off first once filters are trusted.
local PETPORTS_FILTER_DEBUG = true

--  FORMATTED HERE, NOT BY sb.logInfo.
--
--  Starbound's logger accepts %s and nothing else -- %d, %q and %.2f all
--  raise "Improper lua log format specifier" and take down whatever was
--  logging. Running string.format first means the log call only ever sees one
--  %s, so every specifier Lua supports is available at the call sites.
--
--  pcall'd because a debug line must never be the thing that breaks a script.
--  A malformed format string prints itself instead of throwing.
local function fdbg(fmt, ...)
	if not PETPORTS_FILTER_DEBUG then return end
	local ok, text = pcall(string.format, fmt, ...)
	sb.logInfo("petports filter: %s", ok and text or ("<badformat> " .. tostring(fmt)))
end

--  name -> { category = <string>, tags = { [tag] = true } }
local petportsItemFacts = {}

--  Parsed manifest, and an id -> group index built alongside it.
local petportsManifest = nil
local petportsGroupsById = nil
local petportsGroupOrder = nil

--  Every group and subgroup, in display order.
--
--  Reads the manifest once per script context and keeps it. Patches are applied
--  at asset load, so re-reading would cost work and change nothing.
function petports_filterManifest()
	if petportsManifest ~= nil then return petportsManifest end

	local ok, data = pcall(root.assetJson, PETPORTS_FILTER_MANIFEST)
	if not ok or type(data) ~= "table" or type(data.groups) ~= "table" then
		--  FAIL LOUD, FAIL EMPTY. An unreadable manifest means no group
		--  matches anything, which combined with an accept base leaves deposit
		--  working as it did before filters. Guessing at a fallback vocabulary
		--  would sort items into the wrong crates instead.
		sb.logError("petports: filter manifest unreadable at %s; no groups available",
			PETPORTS_FILTER_MANIFEST)
		petportsManifest = { groups = {} }
		petportsGroupsById = {}
		petportsGroupOrder = {}
		return petportsManifest
	end

	petportsManifest = data
	petportsGroupsById = data.groups

	--  NORMALISED ONCE, AT LOAD.
	--
	--  groups and subgroups are OBJECTS KEYED BY ID, not arrays, so that a mod
	--  patches "/groups/species/subgroups/mycoolrace" instead of counting its way
	--  to "/groups/20/subgroups/-". An index is a promise about everyone else's
	--  file that we cannot keep -- adding one group upstream would silently
	--  redirect every positional patch in the ecosystem.
	--
	--  The cost is that key order is meaningless in Lua, so display order has to
	--  be stated. Every entry carries "order"; ties break on id so the result is
	--  stable rather than merely deterministic. Vanilla numbers in tens, leaving
	--  room to slot between without renumbering.
	--
	--  The id is copied onto each entry here so nothing downstream has to carry
	--  the key alongside the value.
	local function ordered(container)
		local list = {}

		for id, entry in pairs(container or {}) do
			if type(entry) == "table" then
				entry.id = id
				table.insert(list, entry)
			end
		end

		table.sort(list, function(a, b)
			local ao, bo = a.order or 10000, b.order or 10000
			if ao ~= bo then return ao < bo end
			return tostring(a.id) < tostring(b.id)
		end)

		return list
	end

	petportsGroupOrder = ordered(data.groups)

	for _, group in ipairs(petportsGroupOrder) do
		group.orderedSubgroups = ordered(group.subgroups)
	end

	return petportsManifest
end

function petports_filterGroup(groupId)
	petports_filterManifest()
	return petportsGroupsById[groupId]
end

--  Every group, in display order. Each carries its own id.
function petports_filterGroups()
	petports_filterManifest()
	return petportsGroupOrder or {}
end

--  One group's subgroups, in display order. Each carries its own id.
--
--  Never iterate group.subgroups directly: it is keyed by id, so pairs() gives
--  a different order every run and the beacon UI would shuffle between openings.
function petports_filterSubgroups(group)
	if type(group) ~= "table" then return {} end

	if group.orderedSubgroups == nil then
		--  A group reached before the manifest was normalised, which should not
		--  happen -- but returning nothing here would silently match nothing.
		petports_filterManifest()
	end

	return group.orderedSubgroups or {}
end

--  Category and tags for an item NAME.
--
--  Memoised, including negative results: an item that fails to resolve fails
--  every time, and retrying it once per cargo stack per scan is the expensive
--  version of the same nil.
function petports_itemFacts(name)
	if type(name) ~= "string" then return nil end

	local cached = petportsItemFacts[name]
	if cached ~= nil then
		if cached.missing then return nil end
		return cached
	end

	local ok, cfg = pcall(root.itemConfig, name)
	if not ok or type(cfg) ~= "table" or type(cfg.config) ~= "table" then
		petportsItemFacts[name] = { missing = true }
		return nil
	end

	local facts = { category = cfg.config.category, tags = {} }

	--  TWO SOURCES, ONE SET. ITEMS USE itemTags, OBJECTS USE colonyTags.
	--
	--  Reading only itemTags is why the whole tenant-tag half of the manifest --
	--  species, decor, biome, location, tier, holiday, object themes, 133
	--  subgroups -- matched nothing at all. Measured on four object files:
	--
	--    floranchair     category "furniture"  colonyTags ["floran","floranvillage"]
	--    tier1switch     category "wire"       colonyTags ["wired","tier1"]
	--    frogfurnishing  category "other"      colonyTags ["outpost","commerce"]
	--    retroscifibed   category "furniture"  colonyTags ["retroscifi"]
	--
	--  Not one of them carries itemTags. colonyTags is what the engine reads to
	--  decide which tenant a Colony Deed spawns, and it is the only tag field
	--  objects have.
	--
	--  MERGED RATHER THAN GIVEN ITS OWN SUBGROUP FIELD, deliberately. The
	--  manifest header's rule is that narrowing is expressed by AUTHORING A
	--  SUBGROUP, never by a field that behaves differently from its neighbours --
	--  and a "colonyTags" field would behave identically to "tags" while giving a
	--  mod author a fourth way to pick the wrong one and get a silent no-match.
	--  An author writes the tag; which file it came from is our problem.
	--
	--  COLLISIONS ARE ACCEPTED. "storage", "light", "door" and "crafting" exist
	--  as colonyTags and could plausibly exist as itemTags too. They mean the
	--  same thing in both, so a merge cannot produce a wrong answer here -- and
	--  if a mod ever makes them disagree, that is an argument for a subgroup, not
	--  for a fourth field.
	--
	--  Vanilla also derives tags the engine knows about that appear in NEITHER
	--  list; nothing in the manifest depends on those, and reaching for them
	--  would need a callback that may not exist.
	local function absorb(list)
		if type(list) ~= "table" then return 0 end
		local n = 0
		for _, tag in ipairs(list) do
			if type(tag) == "string" then
				facts.tags[tag] = true
				n = n + 1
			end
		end
		return n
	end

	local itemTagCount = absorb(cfg.config.itemTags)
	local colonyTagCount = absorb(cfg.config.colonyTags)

	--  Logged ONCE per item name, on the miss, because it is memoised. If this
	--  line repeats for the same name the cache is not working and the port is
	--  paying for root.itemConfig on every scan.
	--
	--  The two counts are reported separately even though the set is merged: an
	--  entry with 0 and 0 is an item with no tag vocabulary at all and can only
	--  ever be sorted by category or by name, which is worth being able to see
	--  without opening the asset.
	local tagList = {}
	for tag in pairs(facts.tags) do table.insert(tagList, tag) end
	table.sort(tagList)
	fdbg("facts %s: category=%s tags=[%s] (%s item, %s colony)",
		name, tostring(facts.category), table.concat(tagList, " "),
		tostring(itemTagCount), tostring(colonyTagCount))

	petportsItemFacts[name] = facts
	return facts
end

local function anyOf(list, test)
	if type(list) ~= "table" then return false end
	for _, value in ipairs(list) do
		if test(value) then return true end
	end
	return false
end

--  Does one subgroup's leaf predicate match this item?
--
--  Plain OR across all three fields. Narrowing is done by authoring a
--  subgroup, never by a field that means something different from its
--  neighbours -- see the manifest header.
local function subgroupMatches(subgroup, facts, name)
	if type(subgroup) ~= "table" or facts == nil then return false end

	if anyOf(subgroup.tags, function(tag) return facts.tags[tag] == true end) then
		return true
	end

	if facts.category ~= nil
	   and anyOf(subgroup.categories, function(c) return c == facts.category end) then
		return true
	end

	if anyOf(subgroup.items, function(i) return i == name end) then
		return true
	end

	--  SUFFIXES. The one thing an exact name cannot express.
	--
	--  Blueprints are the case this exists for. Every one is GENERATED --
	--  "ironanvil-recipe", "avianfuelhatch-recipe" -- so there is no file to
	--  scan, no fixed list to enumerate, and the item can be a recipe for
	--  anything from food to a helmet. What they share is the suffix.
	--
	--  Deliberately suffix and not a Lua pattern. A pattern field would let a
	--  mod author write something expensive or wrong into a manifest that is
	--  evaluated per item per scan, and every case seen so far is a suffix.
	--  NAME PARTS. Prefix and suffix TOGETHER, which is the one thing neither
	--  field can do alone.
	--
	--  Codexes are why this exists. No codex file carries a category, a tag or a
	--  race field -- all 123 were scanned and every one came back empty -- so the
	--  only thing that identifies an Apex codex is that it is named apexhistory1
	--  and generates an item ending in "-codex".
	--
	--  A bare prefix would be catastrophic: "apex" alone matches every Apex chair,
	--  door and statue in the game. The suffix is what makes the prefix safe, and
	--  that means BOTH have to hold at once -- unlike every other field here,
	--  which are ORed.
	--
	--  Each entry is a table with optional "prefix" and "suffix". Whichever keys
	--  are present must ALL match; an entry with neither matches nothing rather
	--  than everything, because a typo should sort nothing rather than sort the
	--  whole game into one crate.
	if name ~= nil then
		if anyOf(subgroup.nameParts, function(part)
			if type(part) ~= "table" then return false end
			if part.prefix == nil and part.suffix == nil then return false end

			if part.prefix ~= nil then
				if #name < #part.prefix then return false end
				if name:sub(1, #part.prefix) ~= part.prefix then return false end
			end

			if part.suffix ~= nil then
				if #name < #part.suffix then return false end
				if name:sub(-#part.suffix) ~= part.suffix then return false end
			end

			return true
		end) then
			return true
		end
	end

	if name ~= nil then
		if anyOf(subgroup.suffixes, function(sfx)
			return #sfx > 0 and #name >= #sfx and name:sub(-#sfx) == sfx
		end) then
			return true
		end
	end

	return false
end

--  Does a rule apply to this item?
--
--  A rule targets a GROUP or a literal ITEM, never both. `except` names
--  subgroups switched OFF -- stored as exclusions so that a subgroup added by a
--  later update or another mod is inside every existing rule by default.
local function ruleMatches(rule, facts, name)
	if type(rule) ~= "table" then return false end

	if rule.item ~= nil then
		return rule.item == name
	end

	if rule.group == nil then return false end

	local group = petports_filterGroup(rule.group)
	--  A rule naming a group that no longer exists -- a mod removed, a manifest
	--  edited -- matches nothing rather than matching everything. The verdict
	--  falls through to whatever came before it, which is the conservative read
	--  of a rule we cannot honour.
	if group == nil or type(group.subgroups) ~= "table" then return false end

	local subgroups = petports_filterSubgroups(group)

	local excluded = {}
	if type(rule.except) == "table" then
		for _, id in ipairs(rule.except) do excluded[id] = true end
	end

	--  TWO PASSES, BECAUSE OF "unclassified".
	--
	--  An unclassified subgroup catches what the OTHER SUBGROUPS IN ITS GROUP
	--  CANNOT DESCRIBE. "Other Codices" is the case: mods add codex entries by the
	--  dozen, and one that does not name them conventionally matches no race rule
	--  and would fall out of the group entirely.
	--
	--  IT IS NOT "WHATEVER IS LEFT AFTER TICKING". Two earlier versions were:
	--
	--    1. A normal subgroup matching every codex. Subgroups are ORed, so it won
	--       over the race rules and unticking Glitch silently did nothing.
	--    2. A fallback consulted when nothing ELSE MATCHED THIS TIME. Better, but
	--       unticking Glitch pushed the Glitch codexes into it, so the bucket's
	--       contents changed depending on which boxes were ticked.
	--
	--  Both made one switch depend on the others. This one asks the MANIFEST, not
	--  the rule: does any sibling subgroup DESCRIBE this item, whether or not the
	--  player has that sibling switched on? If yes, this is not unclassified, and
	--  unticking a race removes those items from the crate instead of relocating
	--  them. If no, nothing in the group can name the item and it lands here.
	--
	--  COMPUTED AT MATCH TIME FROM THE SUBGROUP DEFINITIONS. Nothing is precomputed
	--  or written down, so a mod that patches a new race subgroup into a group
	--  immediately narrows what counts as unclassified, with no cache to rebuild
	--  and nothing in the config to keep in step.
	local unclassified = nil

	for _, subgroup in ipairs(subgroups) do
		if not excluded[subgroup.id] then
			if subgroup.unclassified == true then
				unclassified = unclassified or {}
				table.insert(unclassified, subgroup)
			elseif subgroupMatches(subgroup, facts, name) then
				return true
			end
		end
	end

	if unclassified == nil then return false end

	--  Deliberately ignores `excluded`: a sibling the player has switched OFF
	--  still DESCRIBES its items, and that is the question being asked.
	for _, subgroup in ipairs(subgroups) do
		if subgroup.unclassified ~= true
		   and subgroupMatches(subgroup, facts, name) then
			return false
		end
	end

	for _, subgroup in ipairs(unclassified) do
		if subgroupMatches(subgroup, facts, name) then return true end
	end

	return false
end

--  THE ONE ENTRY POINT. true if this item may be deposited under this filter.
--
--  `filter` is nil for a beacon that has never been configured, and nil means
--  accept everything. `name` is an item NAME, not a descriptor.
function petports_filterAccepts(filter, name)
	if type(filter) ~= "table" then return true end

	local verdict = filter.base ~= "deny"

	if type(filter.rules) == "table" then
		local facts = petports_itemFacts(name)

		for index, rule in ipairs(filter.rules) do
			if ruleMatches(rule, facts, name) then
				--  No early exit: last match wins, so a later rule must be
				--  able to overturn this one. Logging every MATCH rather than
				--  only the final verdict is what makes an unexpected outcome
				--  readable -- "rule 3 accepted it, then rule 5 denied it" is
				--  a diagnosis; "denied" is not.
				fdbg("  rule %d %s matches %s (verdict %s -> %s)",
					index, tostring(rule.action), name,
					tostring(verdict), tostring(rule.action ~= "deny"))
				verdict = rule.action ~= "deny"
			end
		end
	end

	fdbg("accepts(%s) = %s (base %s, %d rules)",
		name, tostring(verdict), tostring(filter.base),
		type(filter.rules) == "table" and #filter.rules or 0)

	return verdict
end

--  Does this filter reject everything the manifest can describe?
--
--  Used to tell two failures apart that look identical to a loaded unit: every
--  target FULL (transient, clears itself) versus nothing ACCEPTS this item
--  (permanent, needs the player). Only the second is worth interrupting anyone
--  over.
function petports_filterAcceptsNothing(filter)
	if type(filter) ~= "table" then return false end
	if filter.base ~= "deny" then return false end

	if type(filter.rules) ~= "table" then return true end
	for _, rule in ipairs(filter.rules) do
		if type(rule) == "table" and rule.action ~= "deny" then return false end
	end

	return true
end

--  Which items in a container fail the container's OWN filter?
--
--  This is the whole of "eviction" and therefore the whole of disperse: a crate
--  with base "deny" and no rules accepts nothing, so everything in it is a
--  misfit, which is exactly what a dropbox means. One rule, no second beacon
--  type, no second code path.
--
--  Called from the container scan, which already holds the items table -- this
--  must never trigger its own world.containerItems call.
--
--  `items` is slot -> descriptor as world.containerItems returns it (keyed by
--  slot, holes where slots are empty). `exemptSlot` is the DECIDING beacon's
--  slot: a beacon rarely matches its own crate's filter, and without the
--  exemption the system hauls away its own configuration. Everything else --
--  spare beacons included -- is ordinary cargo, per the standing ruling.
--
--  Returns an ARRAY of { slot, name, count }, ordered by slot so two scans of
--  the same container produce the same list. Empty array when the filter is
--  nil, because an unconfigured beacon accepts everything and therefore
--  evicts nothing.
function petports_filterMisfits(filter, items, exemptSlot)
	local misfits = {}

	if type(filter) ~= "table" or type(items) ~= "table" then
		return misfits
	end

	--  Deterministic order: pairs order is not, and an eviction list that
	--  shuffles between scans makes claim behaviour unreproducible.
	local slots = {}
	for slot in pairs(items) do
		if slot ~= exemptSlot then table.insert(slots, slot) end
	end
	table.sort(slots)

	for _, slot in ipairs(slots) do
		local item = items[slot]
		if type(item) == "table" and type(item.name) == "string" then
			if not petports_filterAccepts(filter, item.name) then
				table.insert(misfits, {
					slot = slot,
					name = item.name,
					count = item.count or 1
				})
			end
		end
	end

	return misfits
end

--  Which items in a RESTOCK crate do not belong there?
--
--  The eviction half of the restock beacon, and the sibling of
--  petports_filterMisfits above. A restock crate has no filter -- it has a
--  REQUEST -- so the question it answers is different in one specific way:
--
--    Anything that is not the requested item is a misfit outright.
--    The requested item is a misfit only in EXCESS of max.
--
--  That second clause is the whole reason this cannot be expressed as a filter.
--  petports_filterAccepts is a pure function of an item NAME, deliberately, so
--  that it can be memoised -- and "yes up to a thousand of them" is not a fact
--  about a name. Bolting counts onto the filter schema would have cost that
--  property everywhere.
--
--  `request` is { item = "name", min = n, max = n }, as the beacon stores it.
--  `min` is not consulted here: min decides when to START FETCHING and has
--  nothing to say about what is already in the box.
--
--  SLOT ORDER DECIDES WHAT SURVIVES. The earliest slots fill the quota and
--  later ones are evicted, which means two scans of an unchanged crate produce
--  the same list -- the same property petports_filterMisfits needs and for the
--  same reason: an eviction list that shuffles makes claim behaviour
--  unreproducible.
--
--  A PARTIAL STACK CAN BE A MISFIT. A crate wanting 500 and holding a stack of
--  800 reports 300, not 800 and not nothing. withdrawMisfit consumes by name
--  and count rather than by slot, so a partial count is something it can
--  already act on.
--
--  Returns the same { slot, name, count } shape, so tidyWork does not care
--  which of the two produced its list.
function petports_restockMisfits(request, items, exemptSlot)
	local misfits = {}

	if type(request) ~= "table" or type(request.item) ~= "string" then
		return misfits
	end

	if type(items) ~= "table" then return misfits end

	local slots = {}
	for slot in pairs(items) do
		if slot ~= exemptSlot then table.insert(slots, slot) end
	end
	table.sort(slots)

	--  A max of zero would make the whole request a misfit, which is not a
	--  shape the pane can produce -- but a hand-edited save can, and evicting
	--  everything on the strength of a missing number is a bad way to find out.
	local max = tonumber(request.max) or 0
	local kept = 0

	for _, slot in ipairs(slots) do
		local item = items[slot]

		if type(item) == "table" and type(item.name) == "string" then
			local count = item.count or 1

			if item.name ~= request.item then
				table.insert(misfits, { slot = slot, name = item.name, count = count })
			else
				local room = max - kept

				if room <= 0 then
					table.insert(misfits, { slot = slot, name = item.name, count = count })
				elseif count > room then
					table.insert(misfits,
						{ slot = slot, name = item.name, count = count - room })
					kept = max
				else
					kept = kept + count
				end
			end
		end
	end

	return misfits
end

--  Drops memoised item facts. Only useful if item definitions can change under
--  a running session; kept because a stale category is invisible and would be
--  diagnosed as a filter bug.
function petports_filterResetCache()
	petportsItemFacts = {}
	petportsManifest = nil
	petportsGroupsById = nil
end
