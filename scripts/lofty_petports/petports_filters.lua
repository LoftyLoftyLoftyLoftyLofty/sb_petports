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
		return petportsManifest
	end

	petportsManifest = data
	petportsGroupsById = {}
	for _, group in ipairs(data.groups) do
		if type(group.id) == "string" then
			petportsGroupsById[group.id] = group
		end
	end

	return petportsManifest
end

function petports_filterGroup(groupId)
	petports_filterManifest()
	return petportsGroupsById[groupId]
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

	--  itemTags is the authored list. Vanilla also derives tags the engine
	--  knows about that never appear here; nothing in the manifest depends on
	--  those, and reaching for them would need a callback that may not exist.
	if type(cfg.config.itemTags) == "table" then
		for _, tag in ipairs(cfg.config.itemTags) do
			if type(tag) == "string" then facts.tags[tag] = true end
		end
	end

	--  Logged ONCE per item name, on the miss, because it is memoised. If this
	--  line repeats for the same name the cache is not working and the port is
	--  paying for root.itemConfig on every scan.
	local tagList = {}
	for tag in pairs(facts.tags) do table.insert(tagList, tag) end
	table.sort(tagList)
	fdbg("facts %s: category=%s tags=[%s]",
		name, tostring(facts.category), table.concat(tagList, " "))

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

	local excluded = {}
	if type(rule.except) == "table" then
		for _, id in ipairs(rule.except) do excluded[id] = true end
	end

	for _, subgroup in ipairs(group.subgroups) do
		if not excluded[subgroup.id] and subgroupMatches(subgroup, facts, name) then
			return true
		end
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

--  Drops memoised item facts. Only useful if item definitions can change under
--  a running session; kept because a stale category is invisible and would be
--  diagnosed as a filter bug.
function petports_filterResetCache()
	petportsItemFacts = {}
	petportsManifest = nil
	petportsGroupsById = nil
end
