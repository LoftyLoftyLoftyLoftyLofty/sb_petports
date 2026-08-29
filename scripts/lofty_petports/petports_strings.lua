--  SHARED STRING TABLE, LOADED ONCE PER PANE.
--
--  Every visible string in every pane lives in one asset; this resolves dotted
--  keys against it and sweeps them onto widgets. See the header of
--  petports_strings.config for the shape of the file and why there is one.
--
--  WHY THE CODE IS HERE AND THE DATA IS NOT. The .config sits under
--  /interface/lofty_petports/shared/ because that is where pane assets live and
--  it is read by path, which works from anywhere. This file is REQUIRED, and
--  every proven require path in this mod points at /scripts/lofty_petports/ --
--  petports_filters.lua and petports_flavors.lua both load from here. Whether
--  require resolves out of /interface is not something we know, and finding out
--  costs a pane that will not open. Move it if you would rather have the pair
--  together; it is a path in four pane scripts.

PETPORTS_STRINGS_PATH = "/interface/lofty_petports/shared/petports_strings.config"

--  WHAT A MISSING STRING RENDERS AS.
--
--  Two dashes, and the same two dashes are declared as the `value` of every
--  migrated widget in every pane config. So a file that fails to load produces
--  a pane of dashes -- obvious in testing, and a state that cannot be reached
--  in a shipped build without the asset being absent outright.
PETPORTS_STRING_MISSING = "--"

local stringTable = nil
local loadAttempted = false
local loadFailed = false

local function slog(fmt, ...)
	local ok, text = pcall(string.format, fmt, ...)
	sb.logInfo("PETPORTS strings: %s", ok and text or ("<badformat> " .. tostring(fmt)))
end

--  LOADED ONCE, AND A FAILURE IS REMEMBERED AS A FAILURE.
--
--  Without the attempted flag a missing asset is re-fetched on every lookup,
--  which is a throw per string per pane open.
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

--  A DOTTED KEY, WALKED. Returns whatever is at the end of it -- a string for a
--  label, a table for a tooltip -- or nil, which every caller treats as
--  "leave the widget alone".
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

--  SWEEPS THE PANE'S OWN gui TABLE AND APPLIES EVERY petportsString IT FINDS.
--
--  ONE PASS, AT INIT, and no per-frame cost: these strings cannot change while
--  the pane is open. A widget whose key does not resolve is LEFT AS DECLARED,
--  which is what makes the config's "--" the visible failure rather than
--  something this file has to write.
--
--  widget.setText SETS A BUTTON'S CAPTION AS WELL AS A LABEL'S VALUE, so both
--  go through the same call and the config does not have to say which is which.
--  UNVERIFIED for buttons on this engine build; if a caption comes out as "--"
--  while the labels beside it are correct, that is what happened.
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

--  RESOLVES EVERY petportsTip IN THE PANE INTO name -> { title = , body = }.
--
--  The hover layer stays in the pane that owns it -- only the petport has one --
--  so this hands back the table rather than doing anything with it.
--
--  AN UNRESOLVED TIP STILL PRODUCES A TOOLTIP, made of dashes. A tooltip that
--  silently stops appearing looks exactly like a hit-rect bug, and one that
--  says "--" does not.
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

--  Did the table load at all? For a pane that wants to say so once.
function petports_stringsFailed()
	stringsLoaded()
	return loadFailed
end
