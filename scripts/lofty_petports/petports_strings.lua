PETPORTS_STRINGS_PATH = "/interface/lofty_petports/shared/petports_strings.config"

PETPORTS_STRING_MISSING = "--"

local stringTable = nil
local loadAttempted = false
local loadFailed = false

local function slog(fmt, ...)
	local ok, text = pcall(string.format, fmt, ...)
	sb.logInfo("PETPORTS strings: %s", ok and text or ("<badformat> " .. tostring(fmt)))
end

local function stringsLoaded()
	if loadAttempted then return stringTable end
	loadAttempted = true

	local ok, loaded = pcall(root.assetJson, PETPORTS_STRINGS_PATH)

	if not ok or type(loaded) ~= "table" then
		loadFailed = true
		slog("FAILED to load %s -- every migrated widget will show %s",
			PETPORTS_STRINGS_PATH, PETPORTS_STRING_MISSING)
		return nil
	end

	stringTable = loaded
	return stringTable
end

function petports_string(key)
	local root_ = stringsLoaded()
	if root_ == nil or type(key) ~= "string" then return nil end

	local node = root_
	for segment in string.gmatch(key, "[^%.]+") do
		if type(node) ~= "table" then return nil end
		node = node[segment]
		if node == nil then return nil end
	end

	return node
end

function petports_stringOr(key)
	local value = petports_string(key)
	if type(value) == "string" then return value end
	return PETPORTS_STRING_MISSING
end

function petports_format(key, ...)
	local pattern = petports_string(key)
	if type(pattern) ~= "string" then return PETPORTS_STRING_MISSING end

	local ok, text = pcall(string.format, pattern, ...)
	return ok and text or PETPORTS_STRING_MISSING
end

function petports_applyStrings()
	local gui = config.getParameter("gui")

	if type(gui) ~= "table" then
		slog("sweep FAILED: config.getParameter('gui') returned %s", type(gui))
		return
	end

	local applied, missing = 0, {}

	for name, widgetConfig in pairs(gui) do
		if type(widgetConfig) == "table" and type(widgetConfig.petportsString) == "string" then
			local value = petports_string(widgetConfig.petportsString)

			if type(value) == "string" then
				local ok = pcall(widget.setText, name, value)
				if ok then
					applied = applied + 1
				else
					table.insert(missing, name .. " (setText threw)")
				end
			else
				table.insert(missing, name .. " -> " .. widgetConfig.petportsString)
			end
		end
	end

	table.sort(missing)

	if #missing > 0 then
		slog("%d string(s) applied, %d UNRESOLVED: %s",
			applied, #missing, table.concat(missing, ", "))
	else
		slog("%d string(s) applied", applied)
	end
end

function petports_sweepTips()
	local tips = {}
	local gui = config.getParameter("gui")

	if type(gui) ~= "table" then
		slog("tip sweep FAILED: config.getParameter('gui') returned %s", type(gui))
		return tips
	end

	local found, broken = {}, {}

	for name, widgetConfig in pairs(gui) do
		if type(widgetConfig) == "table" and type(widgetConfig.petportsTip) == "string" then
			local tip = petports_string(widgetConfig.petportsTip)

			if type(tip) == "table" and type(tip.title) == "string" then
				tips[name] = { title = tip.title, body = tip.body }
				table.insert(found, name)
			else
				tips[name] = {
					title = PETPORTS_STRING_MISSING,
					body = PETPORTS_STRING_MISSING
				}
				table.insert(broken, name .. " -> " .. widgetConfig.petportsTip)
			end
		end
	end

	table.sort(found)
	table.sort(broken)

	slog("tip sweep: %d resolved (%s)%s", #found, table.concat(found, ", "),
		#broken > 0 and (" -- %d UNRESOLVED: " .. table.concat(broken, ", ")):format(#broken) or "")

	return tips
end

function petports_stringsFailed()
	stringsLoaded()
	return loadFailed
end
