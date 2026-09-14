local function exclusivityOf(name)
	if type(name) ~= "string" or name == "" then return nil end

	local ok, config = pcall(root.itemConfig, name)
	if not ok or type(config) ~= "table" or type(config.config) ~= "table" then
		return nil
	end

	local categories = config.config.mutualExclusivityCategories
	if type(categories) ~= "table" then return nil end

	return categories
end

function petports_moduleSetDuplicate(records)
	if type(records) ~= "table" then return nil end

	local seen = {}
	local families = {}

	for _, record in ipairs(records) do
		local item = type(record) == "table" and record.item or nil
		local name = type(item) == "table" and item.name or nil

		if type(name) == "string" and name ~= "" then
			if seen[name] then return name end
			seen[name] = true

			for _, category in ipairs(exclusivityOf(name) or {}) do
				if type(category) == "string" and category ~= "" then

					if families[category] ~= nil then
						return name, category
					end

					families[category] = name
				end
			end
		end
	end

	return nil
end
