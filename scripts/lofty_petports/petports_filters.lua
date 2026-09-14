-- Reads the filter group manifest and decides which items a filter accepts.

local PETPORTS_FILTER_MANIFEST = "/scripts/lofty_petports/petports_filtergroups.config"

local PETPORTS_FILTER_DEBUG = false

-- Logs a formatted line when filter debug is on.
local function fdbg(fmt, ...)
	if not PETPORTS_FILTER_DEBUG then return end
	local ok, text = pcall(string.format, fmt, ...)
	sb.logInfo("petports filter: %s", ok and text or ("<badformat> " .. tostring(fmt)))
end

local petportsItemFacts = {}

local petportsItemPrices = {}

local petportsPerishableNames = {}

local petportsManifest = nil
local petportsGroupsById = nil
local petportsGroupOrder = nil

-- Loads the manifest once, dropping groups whose sentinel item is absent and ordering what is left.
function petports_filterManifest()
	if petportsManifest ~= nil then return petportsManifest end

	local ok, data = pcall(root.assetJson, PETPORTS_FILTER_MANIFEST)
	if not ok or type(data) ~= "table" or type(data.groups) ~= "table" then
		sb.logError("petports: filter manifest unreadable at %s; no groups available",
			PETPORTS_FILTER_MANIFEST)
		petportsManifest = { groups = {} }
		petportsGroupsById = {}
		petportsGroupOrder = {}
		return petportsManifest
	end

	petportsManifest = data
	petportsGroupsById = data.groups

	-- Returns whether an item name resolves.
	local function modInstalled(name)
		if type(name) ~= "string" or name == "" then return true end

		local ok, config = pcall(root.itemConfig, name)
		return ok and config ~= nil
	end

	-- Returns a container's installed entries sorted by order then id.
	local function ordered(container)
		local list = {}

		for id, entry in pairs(container or {}) do
			if type(entry) == "table" and modInstalled(entry.sentinelItem) then
				entry.id = id
				table.insert(list, entry)
			end
		end

		table.sort(list, function(a, b)
			local ao, bo = a.order or 100000, b.order or 100000
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

-- Returns a group by id.
function petports_filterGroup(groupId)
	petports_filterManifest()
	return petportsGroupsById[groupId]
end

-- Returns the groups in manifest order.
function petports_filterGroups()
	petports_filterManifest()
	return petportsGroupOrder or {}
end

-- Returns a group's subgroups in order.
function petports_filterSubgroups(group)
	if type(group) ~= "table" then return {} end

	if group.orderedSubgroups == nil then
		petports_filterManifest()
	end

	return group.orderedSubgroups or {}
end

-- Returns an item's category and its item and colony tags, cached.
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

	-- Adds a tag list to the fact table and returns how many were added.
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

	local tagList = {}
	for tag in pairs(facts.tags) do table.insert(tagList, tag) end
	table.sort(tagList)
	fdbg("facts %s: category=%s tags=[%s] (%s item, %s colony)",
		name, tostring(facts.category), table.concat(tagList, " "),
		tostring(itemTagCount), tostring(colonyTagCount))

	petportsItemFacts[name] = facts
	return facts
end

-- Returns an item descriptor's price, cached.
function petports_itemValue(descriptor)
	if type(descriptor) ~= "table" or type(descriptor.name) ~= "string" then
		return 0
	end

	local plain = descriptor.parameters == nil
		or next(descriptor.parameters) == nil

	local key = descriptor.name
	if not plain then
		key = key .. "\0" .. sb.printJson(descriptor.parameters)
	end

	if petportsItemPrices[key] ~= nil then
		return petportsItemPrices[key]
	end

	local price = 0
	local ok, resolved = pcall(root.itemConfig, descriptor)

	if ok and type(resolved) == "table" and type(resolved.config) == "table" then
		price = tonumber(resolved.config.price) or 0
	end

	petportsItemPrices[key] = price

	return price
end

-- Returns whether any entry in a list passes a test.
local function anyOf(list, test)
	if type(list) ~= "table" then return false end
	for _, value in ipairs(list) do
		if test(value) then return true end
	end
	return false
end

-- Returns whether an item matches a subgroup by tag, category, item name, name part or suffix.
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

-- Returns whether an item matches a rule, with unclassified subgroups matching only items no other subgroup claims.
local function ruleMatches(rule, facts, name)
	if type(rule) ~= "table" then return false end

	if rule.item ~= nil then
		return rule.item == name
	end

	if rule.group == nil then return false end

	local group = petports_filterGroup(rule.group)
	if group == nil or type(group.subgroups) ~= "table" then return false end

	local subgroups = petports_filterSubgroups(group)

	local excluded = {}
	if type(rule.except) == "table" then
		for _, id in ipairs(rule.except) do excluded[id] = true end
	end

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

-- Returns the filter's verdict for an item after applying every matching rule in order.
function petports_filterAccepts(filter, name)
	if type(filter) ~= "table" then return true end

	local verdict = filter.base ~= "deny"

	if type(filter.rules) == "table" then
		local facts = petports_itemFacts(name)

		for index, rule in ipairs(filter.rules) do
			if ruleMatches(rule, facts, name) then
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

-- Returns whether a filter admits nothing at all.
function petports_filterAcceptsNothing(filter)
	if type(filter) ~= "table" then return false end
	if filter.base ~= "deny" then return false end

	if type(filter.rules) ~= "table" then return true end
	for _, rule in ipairs(filter.rules) do
		if type(rule) == "table" and rule.action ~= "deny" then return false end
	end

	return true
end

-- Returns the slot, name and count of every item a filter refuses.
function petports_filterMisfits(filter, items, exemptSlot)
	local misfits = {}

	if type(filter) ~= "table" or type(items) ~= "table" then
		return misfits
	end

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

-- Returns the slot, name and surplus count of every item beyond what the requests ask for.
function petports_restockMisfits(requests, items, exemptSlot)
	local misfits = {}

	if type(requests) ~= "table" or type(items) ~= "table" then
		return misfits
	end

	local allowed = {}

	for _, request in ipairs(requests) do
		if type(request) == "table" and type(request.item) == "string"
		   and allowed[request.item] == nil then
			allowed[request.item] = { max = tonumber(request.max) or 0, kept = 0 }
		end
	end

	local slots = {}
	for slot in pairs(items) do
		if slot ~= exemptSlot then table.insert(slots, slot) end
	end
	table.sort(slots)

	for _, slot in ipairs(slots) do
		local item = items[slot]

		if type(item) == "table" and type(item.name) == "string" then
			local count = item.count or 1
			local quota = allowed[item.name]

			if quota == nil then
				table.insert(misfits, { slot = slot, name = item.name, count = count })
			else
				local room = quota.max - quota.kept

				if room <= 0 then
					table.insert(misfits,
						{ slot = slot, name = item.name, count = count })
				elseif count > room then
					table.insert(misfits,
						{ slot = slot, name = item.name, count = count - room })
					quota.kept = quota.max
				else
					quota.kept = quota.kept + count
				end
			end
		end
	end

	return misfits
end


local petportsSubgroupTotal = nil

-- Returns the total number of subgroups, cached.
local function subgroupTotal()
	if petportsSubgroupTotal ~= nil then return petportsSubgroupTotal end

	local total = 0

	for _, group in ipairs(petports_filterGroups()) do
		total = total + #petports_filterSubgroups(group)
	end

	if total < 1 then total = 1 end

	petportsSubgroupTotal = total
	return total
end

-- Returns how many subgroups a filter admits.
function petports_filterBreadth(filter)
	if type(filter) ~= "table" then return subgroupTotal() end

	if filter.base ~= "deny" then return subgroupTotal() end

	if type(filter.rules) ~= "table" then
		return 1
	end

	local admitted = 0

	for _, rule in ipairs(filter.rules) do
		if type(rule) == "table" and rule.action ~= "deny" then
			if rule.item ~= nil then
				admitted = admitted + 1
			elseif rule.group ~= nil then
				local group = petports_filterGroup(rule.group)

				if group ~= nil then
					local excluded = 0

					if type(rule.except) == "table" then
						local subgroups = petports_filterSubgroups(group)
						local known = {}

						for _, subgroup in ipairs(subgroups) do
							known[subgroup.id] = true
						end

						for _, id in ipairs(rule.except) do
							if known[id] then excluded = excluded + 1 end
						end

						admitted = admitted + #subgroups - excluded
					else
						admitted = admitted + #petports_filterSubgroups(group)
					end
				end
			end
		end
	end

	if admitted < 1 then admitted = 1 end

	return admitted
end


local petportsPerishableSubgroups = nil

-- Returns every subgroup marked perishable, cached.
local function perishableSubgroups()
	if petportsPerishableSubgroups ~= nil then return petportsPerishableSubgroups end

	local out = {}

	for _, group in ipairs(petports_filterGroups()) do
		for _, subgroup in ipairs(petports_filterSubgroups(group)) do
			if subgroup.perishable == true then
				table.insert(out, subgroup)
			end
		end
	end

	petportsPerishableSubgroups = out
	return out
end

-- Returns whether an item rots, by its timeToRot parameter or a perishable subgroup.
function petports_itemPerishable(descriptor)
	local name = descriptor

	if type(descriptor) == "table" then
		name = descriptor.name

		if type(descriptor.parameters) == "table"
		   and descriptor.parameters.timeToRot ~= nil then
			return true
		end
	end

	if type(name) ~= "string" then return false end

	local held = petportsPerishableNames[name]
	if held ~= nil then return held end

	local facts = petports_itemFacts(name)
	local rots = false

	if facts ~= nil then
		for _, subgroup in ipairs(perishableSubgroups()) do
			if subgroupMatches(subgroup, facts, name) then
				rots = true
				break
			end
		end
	end

	petportsPerishableNames[name] = rots
	return rots
end

-- Clears the manifest and every cached item fact, price and perishable answer.
function petports_filterResetCache()
	petportsItemFacts = {}
	petportsItemPrices = {}
	petportsManifest = nil
	petportsGroupsById = nil

	petportsSubgroupTotal = nil

	petportsPerishableSubgroups = nil
	petportsPerishableNames = {}
end
