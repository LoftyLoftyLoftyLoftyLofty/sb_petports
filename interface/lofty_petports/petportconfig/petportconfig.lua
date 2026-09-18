-- Pane for a Petport: shows the unit's details, edits its settings and lists its stats.

require "/scripts/lofty_petports/petports_strings.lua"

require "/scripts/lofty_petports/petports_modules.lua"

require "/scripts/lofty_petports/petports_flavors.lua"

-- Returns a flavor's label, or its id capitalised.
local function flavorLabel(id)
	if type(id) ~= "string" or id == "" then return nil end

	local flavor = petports_flavor(id)
	if type(flavor) == "table" and type(flavor.label) == "string" then
		return flavor.label
	end

	return id:sub(1, 1):upper() .. id:sub(2)
end

local DEBUG = true

local PANE_BUILD_STAMP = "2026-09-13f the details tab preference value wears its flavor colour"

local PANE_STATE_KEY = "petports_paneState"

local BLIP_ART = "/interface/lofty_petports/petportconfig/fuelblip.png"
local BLIP_COUNT = 20

local BLIP_EMPTY = "2a2a2aff"

local BLIP_FULL = "7fd4ffff"
local BLIP_LOW = "ffc75fff"
local BLIP_CRITICAL = "ff6b6bff"

local DIAG_SLOTS = 4

local MODULE_SLOTS = 5

local MODULE_TAG = "petports_module"

local RATE_FLOOR_MINUTES = 6

local STATS_ROW_ALT = "/interface/lofty_petports/shared/row_180_11_alt.png"
local STATS_ROW_CLEAR = "/interface/lofty_petports/shared/row_180_clear.png"

local STATS_SEPARATOR_TEXT = string.rep("-", 50)
local STATS_SEPARATOR_COLOR = { 184, 148, 64 }


local DIAG_TINT = {
	info = "9aa4b0ff",
	warn = "ffa53cff",
	error = "ff5a5aff"
}

local TAB_WIDGETS = { "tabDetails", "tabSettings", "tabStats" }




local FISH_RARITIES = { "common", "uncommon", "rare", "legendary" }

local RGB_MIN = 0
local RGB_MAX = 255

local RGB_DEFAULT = 140

local RGB_STEP = 1

local LIGHT_CHANNELS = { "r", "g", "b", "intensity", "speed" }

local LIGHT_RANGE = {
	r = { min = RGB_MIN, max = RGB_MAX, default = RGB_DEFAULT },
	g = { min = RGB_MIN, max = RGB_MAX, default = RGB_DEFAULT },
	b = { min = RGB_MIN, max = RGB_MAX, default = RGB_DEFAULT },

	intensity = { min = RGB_MIN, max = RGB_MAX, default = 80 },

	speed = { min = 1, max = 16, default = 8 }
}

-- Returns a light channel's bounds.
local function lightRange(channel)
	return LIGHT_RANGE[channel] or { min = RGB_MIN, max = RGB_MAX, default = RGB_DEFAULT }
end

-- Returns a setting row's kind: check, rgb or sep.
local function rowKind(row)
	if row == nil then return nil end
	if row.kind ~= nil then return row.kind end
	if row.sep then return "sep" end
	return "check"
end

local SETTING_ROWS = {
	{ key = "carried", owner = "toggles", needs = nil, default = true,
	  label = "petport.setting.carried", tip = "petport.tip.carried" },

	{ key = "nametag", owner = "toggles", needs = nil, default = false,
	  label = "petport.setting.nametag", tip = "petport.tip.nametag" },

	{ key = "hauling", owner = "toggles", needs = nil, default = true,
	  label = "petport.setting.hauling", tip = "petport.tip.hauling" },
	{ key = "restock", owner = "toggles", needs = nil, default = true,
	  label = "petport.setting.restock", tip = "petport.tip.restock" },
	{ key = "machines", owner = "toggles", needs = nil, default = true,
	  label = "petport.setting.machines", tip = "petport.tip.machines" },
	{ key = "crosshairs", owner = "toggles", needs = nil, default = true,
	  label = "petport.setting.crosshairs", tip = "petport.tip.crosshairs" },

	{ key = "showCargo", owner = "toggles", needs = nil, default = true,
	  label = "petport.setting.showCargo", tip = "petport.tip.showCargo" },

	{ sep = true, needs = "medic", label = "petport.setting.medicblock" },

	{ key = "player", owner = "medic", needs = "medic",
	  label = "petport.setting.medicplayer", tip = "petport.tip.medicplayer" },
	{ key = "crew", owner = "medic", needs = "medic",
	  label = "petport.setting.mediccrew", tip = "petport.tip.mediccrew" },
	{ key = "npc", owner = "medic", needs = "medic",
	  label = "petport.setting.medicnpc", tip = "petport.tip.medicnpc" },
	{ key = "podpet", owner = "medic", needs = "medic",
	  label = "petport.setting.medicpodpet", tip = "petport.tip.medicpodpet" },
	{ key = "animal", owner = "medic", needs = "medic",
	  label = "petport.setting.medicanimal", tip = "petport.tip.medicanimal" },
	{ key = "unit", owner = "medic", needs = "medic",
	  label = "petport.setting.medicunit", tip = "petport.tip.medicunit" },

	{ key = "medicrestock", owner = "toggles", needs = "medic", default = true,
	  label = "petport.setting.medicrestock", tip = "petport.tip.medicrestock" },
	{ key = "medicdeposit", owner = "toggles", needs = "medic", default = true,
	  label = "petport.setting.medicdeposit", tip = "petport.tip.medicdeposit" },

	{ sep = true, needs = "farming", label = "petport.setting.farmingblock" },

	{ key = "harvest", owner = "farming", needs = "farming",
	  label = "petport.setting.farmharvest", tip = "petport.tip.farmharvest" },
	{ key = "water", owner = "farming", needs = "farming",
	  label = "petport.setting.farmwater", tip = "petport.tip.farmwater" },
	{ key = "replant", owner = "farming", needs = "farming",
	  label = "petport.setting.farmreplant", tip = "petport.tip.farmreplant" },
	{ key = "animals", owner = "farming", needs = "farming",
	  label = "petport.setting.farmanimals", tip = "petport.tip.farmanimals" },

	{ key = "traps", owner = "farming", needs = "farming",
	  label = "petport.setting.farmtraps", tip = "petport.tip.farmtraps" },

	{ key = "farmrestock", owner = "toggles", needs = "farming", default = true,
	  label = "petport.setting.farmrestock", tip = "petport.tip.farmrestock" },
	{ key = "farmdeposit", owner = "toggles", needs = "farming", default = true,
	  label = "petport.setting.farmdeposit", tip = "petport.tip.farmdeposit" },
	{ key = "waterrestock", owner = "toggles", needs = "farming", default = true,
	  label = "petport.setting.waterrestock", tip = "petport.tip.waterrestock" },
	{ key = "waterdeposit", owner = "toggles", needs = "farming", default = true,
	  label = "petport.setting.waterdeposit", tip = "petport.tip.waterdeposit" },

	{ kind = "sep", needs = "defrag", label = "petport.setting.defragblock" },

	{ key = "tidy", owner = "toggles", needs = "defrag", default = true,
	  label = "petport.setting.defragtidy", tip = "petport.tip.defragtidy" },
	{ key = "compact", owner = "toggles", needs = "defrag", default = true,
	  label = "petport.setting.defragcompact", tip = "petport.tip.defragcompact" },
	{ key = "defrag", owner = "toggles", needs = "defrag", default = true,
	  label = "petport.setting.defragspread", tip = "petport.tip.defragspread" },

	{ key = "sort", owner = "toggles", needs = "defrag", default = true,
	  label = "petport.setting.defragsort", tip = "petport.tip.defragsort" },

	{ key = "chill", owner = "toggles", needs = "defrag", default = true,
	  label = "petport.setting.defragchill", tip = "petport.tip.defragchill" },

	{ kind = "sep", needs = "rgblight", label = "petport.setting.rgbblock" },

	{ kind = "rgb", key = "r", owner = "light", needs = "rgblight",
	  label = "petport.setting.rgbred", tip = "petport.tip.rgbred" },
	{ kind = "rgb", key = "g", owner = "light", needs = "rgblight",
	  label = "petport.setting.rgbgreen", tip = "petport.tip.rgbgreen" },
	{ kind = "rgb", key = "b", owner = "light", needs = "rgblight",
	  label = "petport.setting.rgbblue", tip = "petport.tip.rgbblue" },

	{ kind = "sep", needs = "lamplight", label = "petport.setting.lampblock" },

	{ kind = "rgb", key = "intensity", owner = "light", needs = "lamplight",
	  label = "petport.setting.lampintensity", tip = "petport.tip.lampintensity" },

	{ kind = "sep", needs = "huelight", label = "petport.setting.hueblock" },

	{ kind = "rgb", key = "intensity", owner = "light", needs = "huelight",
	  label = "petport.setting.hueintensity", tip = "petport.tip.hueintensity" },
	{ kind = "rgb", key = "speed", owner = "light", needs = "huelight",
	  label = "petport.setting.huespeed", tip = "petport.tip.huespeed" },

	{ key = "huereverse", owner = "toggles", needs = "huelight", default = false,
	  label = "petport.setting.huereverse", tip = "petport.tip.huereverse" }
}

local SETTING_MESSAGE = {
	toggles = "petports_setToggles",
	medic = "petports_setMedic",
	farming = "petports_setFarming",

	light = "petports_setLight"
}

local SETTINGS_ROW = "/interface/lofty_petports/shared/row_180.png"
local SETTINGS_ROW_ALT = "/interface/lofty_petports/shared/row_180_alt.png"
local SETTINGS_ROW_CLEAR = "/interface/lofty_petports/shared/row_180_clear.png"

local SETTINGS_SEPARATOR_TEXT = string.rep("-", 40)
local SETTINGS_SEPARATOR_COLOR = { 184, 148, 64 }

local SETTINGS_HELP_ICONS = {
	carried = "/interface/tooltips/petports_helptooltip_icon_cog.png",
	nametag = "/interface/tooltips/petports_helptooltip_icon_cog.png",
	hauling = "/interface/tooltips/petports_helptooltip_icon_cog.png",
	restock = "/interface/tooltips/petports_helptooltip_icon_cog.png",
	machines = "/interface/tooltips/petports_helptooltip_icon_cog.png",
	crosshairs = "/interface/tooltips/petports_helptooltip_icon_cog.png",
	showCargo = "/interface/tooltips/petports_helptooltip_icon_cog.png"
}

local SETTINGS_HELP_ITEM = "petports_helptooltip"


local TAB_MEMBERS = {
	tabDetails = {
		"detailsModulesLabel", "detailsModulesHint",
		"moduleSlot1", "moduleSlot2", "moduleSlot3", "moduleSlot4", "moduleSlot5",
		"detailsFlavorLabel", "detailsFlavorValue",
		"feedSlot", "feedHint",
		"detailsSerial"
	},

	tabSettings = {
		"renameButton",
		"nameFieldBacking", "tbPetName",
		"settingsScroll"
	},
	tabStats = {
		"statsScroll"
	}
}

local PET_COLUMN = {
	"petName", "petSpecies", "petPreview",
	"fuelLabel", "cargoLabel", "cargoSlot", "cargoTake",
	"taskLabel", "diagLabel"
}

-- Logs a formatted line when DEBUG is set.
local function dbg(fmt, ...)
	if not DEBUG then return end
	local ok, text = pcall(string.format, fmt, ...)
	sb.logInfo("PETPORTS petportpane: %s", ok and text or ("<badformat> " .. tostring(fmt)))
end

-- Sets the visibility of a list of widgets.
local function setVisibleAll(names, visible)
	for _, name in ipairs(names) do
		widget.setVisible(name, visible)
	end
end

-- Returns a value printed as JSON, or a placeholder.
local function j(value)
	local ok, text = pcall(sb.printJson, value)
	return ok and text or "<unprintable>"
end


-- Returns the container entity id.
local function portId()
	return pane.containerEntityId()
end

-- Reads the port's pane state parameter.
local function readState()
	local id = portId()
	if id == nil then return nil end

	local ok, state = pcall(world.getObjectParameter, id, PANE_STATE_KEY, nil)
	if not ok then
		dbg("getObjectParameter threw: %s", tostring(state))
		return nil
	end
	if type(state) ~= "table" then return nil end
	return state
end

-- Sends a message to the port.
local function tell(name, payload)
	local id = portId()
	if id == nil then return end
	world.sendEntityMessage(id, name, payload)
end

local PANE_SOUNDS = {
	refuse = "/sfx/interface/clickon_error.ogg",
	swap = "/sfx/interface/inventory_pickup1.ogg"
}

local soundIsLocal = nil

-- Plays a pane sound locally, falling back to asking the port to play it.
local function paneSound(name)
	local path = PANE_SOUNDS[name]

	if path == nil then
		dbg("no sound named %s", tostring(name))
		return
	end

	if soundIsLocal ~= false then
		local ok, err = pcall(widget.playSound, path)

		if ok then
			soundIsLocal = true
			return
		end

		soundIsLocal = false
		dbg("widget.playSound unavailable, falling back to the port: %s", tostring(err))
	end

	tell("petports_paneSound", { sound = name })
end


local activeTab = "tabDetails"

local blipShown = {}

-- Tints the fuel blips full, low or critical up to the filled count.
local function paintFuel(blips)
	local filled = math.max(0, math.min(BLIP_COUNT, math.floor(blips or 0)))

	local tint = BLIP_FULL
	if filled <= 2 then
		tint = BLIP_CRITICAL
	elseif filled <= 4 then
		tint = BLIP_LOW
	end

	for i = 1, BLIP_COUNT do
		local want = (i <= filled) and tint or BLIP_EMPTY
		if blipShown[i] ~= want then
			blipShown[i] = want
			widget.setImage("fuelBlip" .. i, BLIP_ART .. "?multiply=" .. want)
		end
	end
end

-- Sets the fuel label for an organic or a robotic body.
local function paintFuelLabel(bodyKind)
	local key = (bodyKind == "robotic") and "petport.fuel.robotic" or "petport.fuel.organic"
	local text = petports_string(key)

	if type(text) == "string" then
		widget.setText("fuelLabel", text)
	end
end

-- Puts the first cargo stack in the slot and enables the take button.
local function paintCargo(cargo)
	local stack = cargo and cargo[1] or nil

	if stack == nil then
		widget.setItemSlotItem("cargoSlot", nil)
		widget.setButtonEnabled("cargoTake", false)
		return
	end

	widget.setItemSlotItem("cargoSlot", stack)
	widget.setButtonEnabled("cargoTake", true)
end

local diagText = {}

-- Shows a tinted icon for each diagnostic and sets the diagnostic label.
local function paintDiagnostics(diags)
	diags = diags or {}

	for i = 1, DIAG_SLOTS do
		local d = diags[i]
		local name = "diag" .. i
		diagText[i] = d and { title = d.short or "Diagnostic", body = d.full or d.short } or nil
		if d == nil then
			widget.setVisible(name, false)
		else
			local tint = DIAG_TINT[d.severity or "warn"] or DIAG_TINT.warn
			widget.setImage(name, "/interface/lofty_petports/upcyclerconfig/warning.png?multiply=" .. tint)
			widget.setVisible(name, true)
		end
	end

	widget.setText("diagLabel", diags[1] and (diags[1].short or "") or "")
end

local PORTRAIT_MODES = { "Full", "full", 2 }

local PORTRAIT_MAX_SCALE = 4.0
local PORTRAIT_PAD = 6

local PORTRAIT_FALLBACK_SCALE = 2.0

local PORTRAIT_EXCLUDE = {
	"/lofty_petports/shared/spinner/",
	"/lofty_petports/shared/indicator"
}

-- Returns whether an image path is one of the excluded indicator assets.
local function isIndicator(path)
	for _, fragment in ipairs(PORTRAIT_EXCLUDE) do
		if string.find(path, fragment, 1, true) then return true end
	end
	return false
end

local measuredOnce = false
local transformSignature = nil

-- Returns each portrait drawable's centre and the combined bounds, marking those mirrored against the first.
local function layoutDrawables(drawables)
	local items = {}
	local x0, y0, x1, y1

	for _, d in ipairs(drawables) do
		local image = d.image or d
		if type(image) == "string" and not isIndicator(image) then
			local ok, size = pcall(root.imageSize, image)
			if not ok or type(size) ~= "table" then
				if not measuredOnce then
					measuredOnce = true
					dbg("root.imageSize unavailable (%s) -- portrait falls back to a fixed scale",
						tostring(size))
				end
				return nil
			end

			local m = d.transformation
			local a, b, tx = -1, 0, size[1] * 0.5
			local c, dd, ty = 0, 1, size[2] * -0.5

			if type(m) == "table" and type(m[1]) == "table" and type(m[2]) == "table" then
				a, b, tx = m[1][1] or a, m[1][2] or 0, m[1][3] or tx
				c, dd, ty = m[2][1] or 0, m[2][2] or dd, m[2][3] or ty
			end

			if b ~= 0 or c ~= 0 then
				dbg("portrait drawable has shear/rotation (b=%s c=%s) -- not representable",
					tostring(b), tostring(c))
				return nil
			end

			local p = d.position or { 0, 0 }
			local px, py = p[1] or 0, p[2] or 0

			local ax, bx = tx + px, a * size[1] + tx + px
			local ay, by = ty + py, dd * size[2] + ty + py
			local lx, hx = math.min(ax, bx), math.max(ax, bx)
			local ly, hy = math.min(ay, by), math.max(ay, by)

			table.insert(items, {
				image = image,
				cx = (lx + hx) * 0.5,
				cy = (ly + hy) * 0.5,
				sign = (a < 0) and -1 or 1
			})

			x0 = math.min(x0 or lx, lx)
			y0 = math.min(y0 or ly, ly)
			x1 = math.max(x1 or hx, hx)
			y1 = math.max(y1 or hy, hy)
		end
	end

	if x0 == nil or x1 <= x0 or y1 <= y0 then return nil end

	if not measuredOnce then
		measuredOnce = true
		dbg("portrait bounds %sx%s, %s drawable(s) after filtering",
			tostring(x1 - x0), tostring(y1 - y0), tostring(#items))
	end

	local reference = items[1] and items[1].sign or 1
	for _, it in ipairs(items) do
		it.flip = (it.sign ~= reference)
	end

	local sig = ""
	for _, it in ipairs(items) do
		sig = sig .. ((it.sign < 0) and "L" or "R")
	end
	if sig ~= transformSignature then
		transformSignature = sig
		dbg("portrait raw signs -> %s (reference %s, %s flipped)",
			sig, tostring(reference), tostring(#items))
	end

	return {
		items = items,
		cx = (x0 + x1) * 0.5,
		cy = (y0 + y1) * 0.5,
		w = x1 - x0,
		h = y1 - y0
	}
end
local portraitMode = nil
local portraitResolved = false

local PORTRAIT_AWAY_SIZE = 8

-- Draws the unit's portrait scaled into the preview canvas, or the away text.
local function paintPreview(petId)
	local canvas = widget.bindCanvas("petPreview")
	if canvas == nil then return end

	canvas:clear()
	if petId == nil then return end

	local drawables = nil

	if not portraitResolved then
		for _, mode in ipairs(PORTRAIT_MODES) do
			local ok, result = pcall(world.entityPortrait, petId, mode)
			if ok and type(result) == "table" and #result > 0 then
				portraitMode = mode
				drawables = result
				dbg("entityPortrait mode resolved to %s, %s drawable(s)",
					tostring(mode), tostring(#result))
				break
			end
			dbg("entityPortrait mode %s: %s", tostring(mode),
				ok and "no drawables" or tostring(result))
		end

		if world.entityExists(petId) then
			portraitResolved = true
		end
		if portraitMode == nil then
			dbg("entityPortrait unavailable -- portrait stays blank")
		end
	elseif portraitMode ~= nil then
		local ok, result = pcall(world.entityPortrait, petId, portraitMode)
		if ok and type(result) == "table" then drawables = result end
	end

	if drawables == nil or #drawables == 0 then
		local size = widget.getSize("petPreview")

		canvas:drawText(petports_stringOr("petport.preview.away"), {
			position = { size[1] * 0.5, size[2] * 0.5 },
			horizontalAnchor = "mid",
			verticalAnchor = "mid",
			wrapWidth = size[1]
		}, PORTRAIT_AWAY_SIZE)

		return
	end

	local size = widget.getSize("petPreview")
	local centre = { size[1] * 0.5, size[2] * 0.5 }

	local layout = layoutDrawables(drawables)

	if layout == nil then
		for _, d in ipairs(drawables) do
			local image = d.image or d
			if type(image) == "string" and not isIndicator(image) then
				canvas:drawImage(image, centre, PORTRAIT_FALLBACK_SCALE, nil, true)
			end
		end
		return
	end

	local scale = math.min(
		(size[1] - PORTRAIT_PAD * 2) / layout.w,
		(size[2] - PORTRAIT_PAD * 2) / layout.h)
	scale = math.max(1.0, math.min(PORTRAIT_MAX_SCALE, scale))

	local rounded = math.floor(scale + 0.5)
	if rounded * layout.w > size[1] or rounded * layout.h > size[2] then
		rounded = math.floor(scale)
	end
	scale = math.max(1, rounded)

	for _, it in ipairs(layout.items) do
		local image = it.flip and (it.image .. "flipx") or it.image
		canvas:drawImage(image, {
				math.floor(centre[1] + (it.cx - layout.cx) * scale + 0.5),
				math.floor(centre[2] + (it.cy - layout.cy) * scale + 0.5)
			},
			scale, nil, true)
	end
end

local paneModules = {}
local paneModuleSlotCount = 0

local paneModuleFlags = {}
local paneSettings = {}
local paneHasUnit = false

-- Returns the slot and item of every socketed module, with one slot optionally replaced.
local function moduleRecords(overrideSlot, overrideItem)
	local out = {}
	for i = 1, MODULE_SLOTS do
		local item = paneModules[i]
		if overrideSlot == i then item = overrideItem end

		if item ~= nil then
			table.insert(out, { slot = i, item = item })
		end
	end
	return out
end

local settingsRowPaths = {}
local settingsRowKeys = {}
local settingsSignature = nil

local paneLight = {}

local lightShown = {}

local lightPainted = {}

local lightSent = {}

-- Writes a colour channel's text box and records what it now shows.
local function setLightField(path, channel, value)
	local text = tostring(value)

	lightShown[channel] = text
	lightPainted[channel] = value
	pcall(widget.setText, path .. ".settingField", text)
end

-- Drops focus from a widget when it holds it.
local function blurField(name)
	local ok, focused = pcall(widget.hasFocus, name)
	if ok and focused then pcall(widget.blur, name) end
end

-- Drops focus from the name box and every colour box.
local function blurPaneFields()
	blurField("tbPetName")

	for i, row in ipairs(settingsRowKeys) do
		local path = settingsRowPaths[i]

		if rowKind(row) == "rgb" and path ~= nil then
			blurField(path .. ".settingField")
		end
	end
end

-- Returns text as a whole number clamped to the channel range, and whether it was clamped.
local function rgbValue(text, channel)
	local value = tonumber(text)
	if value == nil then return nil end

	local range = lightRange(channel)

	value = math.floor(value)

	if value < range.min then return range.min, true end
	if value > range.max then return range.max, true end

	return value, false
end

-- Returns the setting rows whose required module flag is present.
local function applicableSettingRows()
	local out = {}

	for _, row in ipairs(SETTING_ROWS) do
		if row.needs == nil or paneModuleFlags[row.needs] then
			table.insert(out, row)
		end
	end

	return out
end

-- Returns a light channel's value, or the default.
local function lightValue(channel)
	local value = paneLight[channel]
	if type(value) ~= "number" then return lightRange(channel).default end
	return value
end

-- Returns a setting row's stored value, or its default.
local function settingValue(row)
	local store = paneSettings[row.owner] or {}
	local value = store[row.key]

	if value == nil then return row.default ~= false end
	return value ~= false
end

-- Returns the icon, subtitle and rarity of the socketed module supplying each module flag.
local function moduleHelpByFlag()
	local out = {}

	for slot = 1, MODULE_SLOTS do
		local item = paneModules[slot]
		local name = type(item) == "table" and item.name or nil

		if type(name) == "string" then
			local ok, resolved = pcall(root.itemConfig, { name = name, count = 1 })

			if ok and type(resolved) == "table" and type(resolved.config) == "table" then
				local cfg = resolved.config
				local icon = cfg.inventoryIcon

				if type(icon) == "string" and icon:sub(1, 1) ~= "/" then
					icon = tostring(resolved.directory or "") .. icon
				end

				for _, flag in ipairs(cfg.petports_moduleFlags or {}) do
					if out[flag] == nil then
						out[flag] = {
							icon = type(icon) == "string" and icon or nil,
							subtitle = cfg.shortdescription,

							rarity = type(cfg.rarity) == "string" and cfg.rarity or nil
						}
					end
				end
			end
		end
	end

	return out
end

-- Puts a help item carrying a row's tooltip into its help slot.
local function setRowHelp(rowPath, row, moduleHelp)
	local tip = petports_string(row.tip)

	if type(tip) ~= "table" or type(tip.title) ~= "string" then
		widget.setVisible(rowPath .. ".helpSlot", false)
		return
	end

	local owner = row.needs ~= nil and moduleHelp[row.needs] or nil

	local ownIcon = row.needs == nil and row.key ~= nil
	                and SETTINGS_HELP_ICONS[row.key] or nil

	local ok, err = pcall(function()
		widget.setItemSlotItem(rowPath .. ".helpSlot", {
			name = SETTINGS_HELP_ITEM,
			count = 1,
			parameters = {
				shortdescription = tip.title,
				description = tip.body or "",
				helpIcon = (owner ~= nil and owner.icon) or ownIcon or nil,
				helpSubtitle = owner ~= nil and owner.subtitle or nil,
				helpRarity = owner ~= nil and owner.rarity or nil
			}
		})
	end)

	if not ok then
		widget.setVisible(rowPath .. ".helpSlot", false)
		dbg("help mark for %s FAILED: %s", tostring(row.tip), tostring(err))
		return
	end

	widget.setVisible(rowPath .. ".helpSlot", true)
end

-- Rebuilds the settings list when its row set changed, then writes every checkbox and colour box.
local function paintSettings()
	local showing = (activeTab == "tabSettings")
	widget.setVisible("settingsScroll", showing and paneHasUnit)

	if not showing or not paneHasUnit then return end

	local rows = applicableSettingRows()

	local names = {}
	for _, row in ipairs(rows) do table.insert(names, row.label) end
	local signature = table.concat(names, "|")

	if signature ~= settingsSignature then
		settingsSignature = signature
		widget.clearListItems("settingsScroll.settingsList")
		settingsRowPaths = {}
		settingsRowKeys = {}

		lightShown = {}
		lightPainted = {}

		local moduleHelp = moduleHelpByFlag()

		local stripe = false

		for i, row in ipairs(rows) do
			local rowId = widget.addListItem("settingsScroll.settingsList")
			local rowPath = "settingsScroll.settingsList." .. rowId

			settingsRowPaths[i] = rowPath
			settingsRowKeys[i] = row

			local kind = rowKind(row)

			local isCheck = (kind == "check")
			local isRgb = (kind == "rgb")

			widget.setVisible(rowPath .. ".settingCheck", isCheck)
			widget.setVisible(rowPath .. ".colorFieldBacking", isRgb)
			widget.setVisible(rowPath .. ".settingField", isRgb)
			widget.setVisible(rowPath .. ".settingDown", isRgb)
			widget.setVisible(rowPath .. ".settingUp", isRgb)

			setRowHelp(rowPath, row, moduleHelp)

			if kind == "sep" then
				stripe = false
				widget.setImage(rowPath .. ".rowBG", SETTINGS_ROW_CLEAR)
				widget.setText(rowPath .. ".settingLabel", SETTINGS_SEPARATOR_TEXT)
				widget.setFontColor(rowPath .. ".settingLabel", SETTINGS_SEPARATOR_COLOR)

				widget.setVisible(rowPath .. ".rowButton", false)
			else
				widget.setImage(rowPath .. ".rowBG",
					stripe and SETTINGS_ROW_ALT or SETTINGS_ROW)
				stripe = not stripe

				widget.setText(rowPath .. ".settingLabel", petports_stringOr(row.label, "--"))

				widget.setVisible(rowPath .. ".rowButton", true)

				widget.setData(rowPath .. ".settingCheck", i)
				widget.setData(rowPath .. ".rowButton", i)

				if isCheck then
					widget.setChecked(rowPath .. ".settingCheck", settingValue(row))
				end

				if isRgb then
					widget.setData(rowPath .. ".settingDown", i)
					widget.setData(rowPath .. ".settingUp", i)

					setLightField(rowPath, row.key, lightValue(row.key))
				end
			end
		end
	end

	for i, row in ipairs(rows) do
		local path = settingsRowPaths[i]
		local kind = rowKind(row)

		if path ~= nil then
			if kind == "check" then
				widget.setChecked(path .. ".settingCheck", settingValue(row))
			elseif kind == "rgb" then
				local value = lightValue(row.key)
				if value ~= lightPainted[row.key] then
					setLightField(path, row.key, value)
				end
			end
		end
	end
end

-- Shows the module slots this unit has and fills them.
local function paintModuleSlots()
	local showing = (activeTab == "tabDetails")

	for i = 1, MODULE_SLOTS do
		local name = "moduleSlot" .. i
		if showing and i <= paneModuleSlotCount then
			widget.setVisible(name, true)
			widget.setItemSlotItem(name, paneModules[i])
		else
			widget.setVisible(name, false)
		end
	end
end

local moduleWriteToken = nil
local moduleTokenSeq = 0

local paneNameSeen = false

-- Returns a fresh module write token.
local function nextModuleToken()
	moduleTokenSeq = moduleTokenSeq + 1

	local ok, uuid = pcall(sb.makeUuid)
	return (ok and tostring(uuid) or "pane") .. ":" .. tostring(moduleTokenSeq)
end

-- Takes the module flags, settings and light out of a state, and repaints the slots once the port echoes the write token.
local function paintModules(state)
	paneModuleFlags = {}
	for _, flag in ipairs(state.moduleFlags or {}) do
		paneModuleFlags[flag] = true
	end

	paneSettings = {
		toggles = state.toggles or {},
		medic = state.medic or {},
		farming = state.farming or {}
	}

	local light = state.light or {}

	for _, channel in ipairs(LIGHT_CHANNELS) do
		local value = tonumber(light[channel])

		if value ~= nil then
			local sent = lightSent[channel]

			if sent == nil then
				paneLight[channel] = value
			elseif value == sent then
				lightSent[channel] = nil
				paneLight[channel] = value
			end
		end
	end

	paneHasUnit = state.hasUnit == true

	paintSettings()

	paneModuleSlotCount = math.max(0, math.min(MODULE_SLOTS, state.moduleSlots or 0))

	if moduleWriteToken ~= nil then
		if state.moduleToken ~= moduleWriteToken then
			dbg("holding module paint: mirror token %s, waiting on %s",
				tostring(state.moduleToken), tostring(moduleWriteToken))
			paintModuleSlots()
			return
		end
		moduleWriteToken = nil
	end

	paneModules = {}
	for _, record in ipairs(state.modules or {}) do
		local slot = tonumber(record and record.slot)
		if slot ~= nil and slot >= 1 and slot <= MODULE_SLOTS then
			paneModules[slot] = record.item
		end
	end

	paintModuleSlots()
end

-- Returns a number with thousands separators.
local function groupDigits(value)
	local text = tostring(math.floor(tonumber(value) or 0))

	while true do
		local replaced
		text, replaced = string.gsub(text, "^(%d+)(%d%d%d)", "%1,%2")
		if replaced == 0 then break end
	end

	return text
end

-- Returns a count in its flavor's colour, or plain when the flavor is unknown.
local function flavorCount(id, count)
	if petports_flavor(id) == nil then
		return groupDigits(count)
	end

	return string.format("^#%s;%s^reset;",
		petports_flavorHex(id), groupDigits(count))
end

local statsRowPaths = {}

-- Builds the stats lines and writes them into the list, rebuilding the rows when their number changed.
local function paintStats(stats)
	if activeTab ~= "tabStats" or type(stats) ~= "table" then
		if #statsRowPaths > 0 then
			widget.clearListItems("statsScroll.statsList")
			statsRowPaths = {}
		end
		return
	end

	local minutes = tonumber(stats.activeMinutes) or 0
	local moved = tonumber(stats.moved) or 0

	local lines = {}

	-- Adds a text line.
	local function addLine(text)
		table.insert(lines, { text = text })
	end

	-- Adds a separator line.
	local function addSeparator()
		table.insert(lines, { text = STATS_SEPARATOR_TEXT, sep = true })
	end

	addLine(petports_format("petport.stats.moved", groupDigits(moved)))

	if minutes >= RATE_FLOOR_MINUTES then
		local perHour = math.floor(moved / (minutes / 60) + 0.5)
		addLine(petports_format("petport.stats.rate", groupDigits(perHour)))
	end

	local duration
	if minutes < 60 then
		duration = petports_format("petport.stats.activeminutes", tostring(minutes))
	else
		duration = petports_format("petport.stats.activehours",
			string.format("%.1f", minutes / 60))
	end
	addLine(petports_format("petport.stats.active", duration))

	addSeparator()
	addLine(petports_format("petport.stats.planted", groupDigits(stats.planted)))
	addLine(petports_format("petport.stats.watered", groupDigits(stats.watered)))
	addLine(petports_format("petport.stats.harvested", groupDigits(stats.harvested)))
	addLine(petports_format("petport.stats.livestock", groupDigits(stats.livestock)))
	addLine(petports_format("petport.stats.traps", groupDigits(stats.traps)))

	addSeparator()

	addLine(petports_format("petport.stats.dosed", groupDigits(stats.dosed)))

	addSeparator()
	addLine(petports_format("petport.stats.fished", groupDigits(stats.fished)))

	local tiers = stats.fishedTiers or {}
	local shown = {}

	for _, tier in ipairs(FISH_RARITIES) do
		shown[tier] = true
		addLine(petports_format("petport.stats.fishedtier",
			tier:sub(1, 1):upper() .. tier:sub(2),
			groupDigits(tiers[tier] or 0)))
	end

	local extra = {}
	for tier, count in pairs(tiers) do
		if not shown[tier] then table.insert(extra, tier) end
	end
	table.sort(extra)

	for _, tier in ipairs(extra) do
		addLine(petports_format("petport.stats.fishedtier",
			tier:sub(1, 1):upper() .. tier:sub(2),
			groupDigits(tiers[tier])))
	end

	addSeparator()
	addLine(petports_format("petport.stats.fed", groupDigits(stats.fed)))

	local flavors = stats.fedFlavors or {}
	local drawn = {}

	local order = { "plain" }
	for _, flavor in ipairs(petports_flavors()) do
		if flavor.id ~= nil and flavor.id ~= "plain" then
			table.insert(order, flavor.id)
		end
	end

	for _, flavor in ipairs(order) do
		drawn[flavor] = true
		addLine(petports_format("petport.stats.fedflavor",
			flavorLabel(flavor),
			flavorCount(flavor, flavors[flavor] or 0)))
	end

	local orphans = {}
	for flavor, count in pairs(flavors) do
		if not drawn[flavor] then table.insert(orphans, flavor) end
	end
	table.sort(orphans)

	for _, flavor in ipairs(orphans) do
		addLine(petports_format("petport.stats.fedflavor",
			flavorLabel(flavor),
			flavorCount(flavor, flavors[flavor])))
	end

	addSeparator()
	addLine(petports_format("petport.stats.traveled", groupDigits(stats.traveled)))
	addLine(petports_format("petport.stats.headpats", groupDigits(stats.headpats)))

	local okStars, starsConfig = pcall(root.itemConfig, "asteriteore")

	if okStars and starsConfig ~= nil then
		addSeparator()
		addLine(petports_format("petport.stats.asteritedeposits",
			groupDigits(stats.asteriteDepositsMined)))
	end

	if #lines ~= #statsRowPaths then
		widget.clearListItems("statsScroll.statsList")
		statsRowPaths = {}

		local stripe = false

		for i = 1, #lines do
			local rowId = widget.addListItem("statsScroll.statsList")
			local rowPath = "statsScroll.statsList." .. rowId
			statsRowPaths[i] = rowPath .. ".statText"

			if lines[i].sep then
				stripe = false
				widget.setImage(rowPath .. ".rowBG", STATS_ROW_CLEAR)
				widget.setFontColor(statsRowPaths[i], STATS_SEPARATOR_COLOR)
			else
				if stripe then
					widget.setImage(rowPath .. ".rowBG", STATS_ROW_ALT)
				end
				stripe = not stripe
			end
		end
	end

	for i = 1, #lines do
		widget.setText(statsRowPaths[i], lines[i].text)
	end
end


-- Switches the visible tab and repaints the module slots and the settings.
local function showTab(which)
	blurPaneFields()

	activeTab = which

	for _, name in ipairs(TAB_WIDGETS) do
		widget.setChecked(name, name == which)
		setVisibleAll(TAB_MEMBERS[name], name == which)
	end

	paintModuleSlots()
	paintSettings()

	dbg("tab -> %s", which)
end


local lastSignature = nil

local livePetId = nil

-- Clears every unit widget and hides the unit column.
local function showEmpty()
	livePetId = nil
	paneModules = {}
	paneModuleSlotCount = 0

	paneModuleFlags = {}
	paneSettings = {}
	paneHasUnit = false
	settingsSignature = nil
	moduleWriteToken = nil

	widget.setText("petName", petports_stringOr("petport.nounit"))
	widget.setText("tbPetName", "")
	paneNameSeen = false
	widget.setText("petSpecies", "")
	widget.setText("taskLabel", "")
	widget.setText("diagLabel", "")
	widget.setText("detailsSerial", "")
	widget.setText("detailsFlavorValue", "--")

	for i = 1, DIAG_SLOTS do
		diagText[i] = nil
		widget.setVisible("diag" .. i, false)
	end

	paintStats(nil)

	for i = 1, MODULE_SLOTS do
		widget.setItemSlotItem("moduleSlot" .. i, nil)
		widget.setVisible("moduleSlot" .. i, false)
	end

	paintFuel(0)
	paintCargo(nil)

	setVisibleAll(PET_COLUMN, false)
	setVisibleAll(TAB_MEMBERS[activeTab], false)
end

-- Reads the port's state and repaints the pane when it changed.
local function refresh(force)
	local state = readState()

	if state == nil then
		showEmpty()
		return
	end

	local ok, signature = pcall(sb.printJson, state)
	if not force and ok and signature == lastSignature then return end
	if ok then lastSignature = signature end

	local hasUnit = state.hasUnit == true

	setVisibleAll(PET_COLUMN, hasUnit)
	setVisibleAll(TAB_MEMBERS[activeTab], hasUnit)

	widget.setChecked("portEnabled", state.enabled ~= false)
	widget.setText("portNetworkLabel", "id: " .. tostring(state.network or "--"))

	if not hasUnit then
		showEmpty()
		return
	end

	local showSpecies = state.species ~= nil and state.petName ~= nil
		and state.species ~= state.petName

	local petName = state.petName or "Unnamed unit"
	local petSpecies = showSpecies and state.species or ""

	if state.medicReady then
		local pattern = petports_string("petport.medicready")

		if type(pattern) == "string" then
			local ok, text = pcall(string.format, pattern,
				showSpecies and petSpecies or petName)

			if ok then
				if showSpecies then petSpecies = text else petName = text end
			end
		end
	end

	widget.setText("petName", petName)

	if state.petNameRaw ~= paneNameSeen then
		paneNameSeen = state.petNameRaw
		widget.setText("tbPetName", state.petNameRaw or "")
	end

	widget.setText("petSpecies", petSpecies)

	livePetId = state.petId
	paintFuel(state.fuelBlips)
	paintFuelLabel(state.bodyKind)
	paintCargo(state.cargo)

	local task = state.task
	widget.setText("taskLabel",
		task and (petports_string("petport.task." .. task) or task) or "")
	paintDiagnostics(state.diagnostics)

	paintModules(state)
	local flavorName = flavorLabel(state.flavor)

	if flavorName == nil or petports_flavor(state.flavor) == nil then
		widget.setText("detailsFlavorValue", flavorName or "--")
	else
		widget.setText("detailsFlavorValue", string.format("^#%s;%s^reset;",
			petports_flavorHex(state.flavor), flavorName))
	end
	widget.setText("detailsSerial", state.serial and ("Serial " .. state.serial) or "")

	paintStats(state.stats)
end


-- Switches to the details tab and refreshes.
function tabDetailsClicked()
	showTab("tabDetails")
	refresh(true)
end

-- Switches to the settings tab and refreshes.
function tabSettingsClicked()
	showTab("tabSettings")
	refresh(true)
end

-- Switches to the stats tab and refreshes.
function tabStatsClicked()
	showTab("tabStats")
	refresh(true)
end

-- Does nothing.
function statsRowSelected()
end

local pendingTake = nil

-- Asks the port for its cargo.
function cargoTakeClicked()
	if pendingTake ~= nil then return end

	dbg("take cargo requested")
	widget.setButtonEnabled("cargoTake", false)

	local id = portId()
	if id == nil then return end
	pendingTake = world.sendEntityMessage(id, "petports_takeCargo", {})
end

-- Gives the player whatever cargo the port returned.
local function pollTake()
	if pendingTake == nil then return end
	if not pendingTake:finished() then return end

	local promise = pendingTake
	pendingTake = nil

	if not promise:succeeded() then
		dbg("take failed -- port did not answer")
		return
	end

	local stack = promise:result()
	if type(stack) ~= "table" or stack.name == nil then
		dbg("take returned nothing")
		return
	end

	player.giveItem(stack)
	dbg("gave %s x%s", tostring(stack.name), tostring(stack.count))

	refresh(true)
end

-- Swaps a module between the cursor and a slot, refusing stacks, non-modules and duplicates.
function moduleSlotClicked(widgetName)
	local index = tonumber(string.sub(widgetName, -1))
	if index == nil or index < 1 or index > MODULE_SLOTS then return end

	if index > paneModuleSlotCount then
		dbg("ignoring click on slot %s: unit has %s", tostring(index),
			tostring(paneModuleSlotCount))
		paneSound("refuse")
		return
	end

	local cursor = player.swapSlotItem()

	if cursor ~= nil and (cursor.count or 1) > 1 then
		dbg("refusing module swap: cursor holds %s", tostring(cursor.count))
		paneSound("refuse")
		return
	end

	if cursor ~= nil then
		local ok, isModule = pcall(root.itemHasTag, cursor.name, MODULE_TAG)
		if not ok or isModule ~= true then
			dbg("refusing module swap: %s is not a module", tostring(cursor.name))
			paneSound("refuse")
			return
		end
	end

	local duplicate, family = petports_moduleSetDuplicate(moduleRecords(index, cursor))

	if duplicate ~= nil then
		if family ~= nil then
			dbg("refusing module swap: %s conflicts with the %s already socketed",
				tostring(duplicate), tostring(family))
		else
			dbg("refusing module swap: %s is already socketed", tostring(duplicate))
		end

		paneSound("refuse")
		return
	end

	local previous = paneModules[index]
	player.setSwapSlotItem(previous)
	paneModules[index] = cursor
	widget.setItemSlotItem(widgetName, cursor)

	dbg("slot %s: %s -> %s", tostring(index),
		tostring(previous and previous.name or "empty"),
		tostring(cursor and cursor.name or "empty"))

	if previous ~= nil and cursor ~= nil and previous.name == cursor.name then
		paneSound("swap")
	end

	moduleWriteToken = nextModuleToken()
	tell("petports_setModules", {
		modules = moduleRecords(),
		token = moduleWriteToken
	})

end

local pendingFeed = nil

-- Offers the item on the cursor to the unit.
function feedSlotClicked()
	if pendingFeed ~= nil then return end

	local cursor = player.swapSlotItem()
	if cursor == nil then return end

	local id = portId()
	if id == nil then return end

	pendingFeed = world.sendEntityMessage(id, "petports_feedUnit",
		{ item = { name = cursor.name, count = 1, parameters = cursor.parameters } })
end

-- Takes one item off the cursor once the feed was accepted.
local function pollFeed()
	if pendingFeed == nil then return end
	if not pendingFeed:finished() then return end

	local promise = pendingFeed
	pendingFeed = nil

	if not promise:succeeded() or promise:result() ~= true then
		paneSound("refuse")
		dbg("feed refused -- treat not taken")
		return
	end

	local cursor = player.swapSlotItem()
	if type(cursor) ~= "table" or cursor.name == nil then return end

	local count = (tonumber(cursor.count) or 1) - 1

	if count <= 0 then
		player.setSwapSlotItem(nil)
	else
		player.setSwapSlotItem({ name = cursor.name, count = count,
			parameters = cursor.parameters })
	end

	paneSound("swap")
	dbg("fed one %s", tostring(cursor.name))
	refresh(true)
end


local TIP_W = 150
local TIP_H = 80
local TIP_PAD = 5

local TIP_WRAP = TIP_W - TIP_PAD * 2

local TIP_PANE_W = 337

local TIP_MARGIN = 2

local TIP_GAP = 4


local TIP_BG = { 22, 24, 29, 255 }
local TIP_EDGE = { 74, 82, 92, 255 }
local TIP_TITLE_COLOR = { 220, 226, 234, 255 }
local TIP_BODY_COLOR = { 150, 156, 164, 255 }

local hoverCanvas = nil
local tipCanvas = nil
local tipShowing = false

local hoverRects = {}

local staticTips = {}

-- Collects the static tooltips declared on the pane's widgets.
local function sweepTips()
	staticTips = petports_sweepTips()
end

-- Returns a widget's rect, cached.
local function hoverRect(name)
	if hoverRects[name] ~= nil then return hoverRects[name] end

	local okPos, pos = pcall(widget.getPosition, name)
	local okSize, size = pcall(widget.getSize, name)

	if not okPos or not okSize or type(pos) ~= "table" or type(size) ~= "table" then
		return nil
	end

	hoverRects[name] = { pos[1], pos[2], pos[1] + size[1], pos[2] + size[2] }
	return hoverRects[name]
end

-- Returns whether a point is inside a rect.
local function within(rect, at)
	return rect ~= nil
		and at[1] >= rect[1] and at[1] <= rect[3]
		and at[2] >= rect[2] and at[2] <= rect[4]
end

-- Returns the title, body and rect of the diagnostic or tipped widget under a point.
local function hoverTarget(at)
	for i = 1, DIAG_SLOTS do
		local entry = diagText[i]
		local rect = hoverRect("diag" .. i)
		if entry ~= nil and within(rect, at) then
			return entry.title, entry.body, rect
		end
	end

	for name, tip in pairs(staticTips) do
		local rect = hoverRect(name)
		if within(rect, at) then
			return tip.title, tip.body, rect
		end
	end

	return nil
end

-- Hides the tooltip canvas.
local function hideTip()
	if not tipShowing then return end
	tipShowing = false
	pcall(widget.setVisible, "tipCanvas", false)
end

local tipMetricCache = {}

local measureFailLogged = false

-- Returns the drawn heights of a tooltip's title and body, cached.
local function tipMetrics(title, body)
	local key = tostring(title) .. "\1" .. tostring(body)
	local cached = tipMetricCache[key]
	if cached ~= nil then return cached[1], cached[2] end

	-- Returns the height and width a measuring widget takes for a text.
	local function measure(name, text)
		local ok, size = pcall(function()
			widget.setText(name, text)
			return widget.getSize(name)
		end)

		if not ok or type(size) ~= "table" or type(size[2]) ~= "number" then return nil end
		if size[2] <= 0 then return nil end
		return size[2], size[1]
	end

	local titleH = measure("tipMeasureTitle", title or "")
	local bodyH, bodyW = measure("tipMeasure", body or "")

	if titleH == nil or bodyH == nil then
		if not measureFailLogged then
			measureFailLogged = true
			dbg("MEASURE FAILED (title %s, body %s) -- tooltips fall back to the full %d px box",
				tostring(titleH), tostring(bodyH), TIP_H)
		end
		return nil, nil
	end

	dbg("measure: title %d high, body %s x %d -- %s", titleH, tostring(bodyW), bodyH, body or "")

	tipMetricCache[key] = { titleH, bodyH }
	return titleH, bodyH
end

-- Draws the tooltip for whatever is under the mouse, or hides it.
local function paintHover()
	if hoverCanvas == nil then
		local ok, bound = pcall(widget.bindCanvas, "hoverCanvas")
		if not ok or bound == nil then
			dbg("bindCanvas hoverCanvas FAILED -- no hover tracking this session")
			return
		end
		hoverCanvas = bound
	end

	local ok, at = pcall(function() return hoverCanvas:mousePosition() end)

	if not ok or type(at) ~= "table" then
		hideTip()
		return
	end

	local title, body, rect = hoverTarget(at)

	if title == nil then
		hideTip()
		return
	end

	if tipCanvas == nil then
		local okBind, bound = pcall(widget.bindCanvas, "tipCanvas")
		if not okBind or bound == nil then
			dbg("bindCanvas tipCanvas FAILED -- nothing can be drawn")
			return
		end
		tipCanvas = bound
	end

	local visible = string.gsub(body or "", "%^%a+;", "")

	local titleH, bodyH = tipMetrics(title, visible)
	local w = TIP_W
	local h

	if titleH == nil then
		h = TIP_H
		titleH = 9
	else
		h = TIP_PAD * 2 + titleH + TIP_GAP + bodyH
	end

	if h > TIP_H then
		dbg("TOOLTIP CLIPS: needs %d px, canvas is %d -- last line(s) lost: %s",
			h, TIP_H, body or "")
		h = TIP_H
	end

	local x = rect[3]

	if x + TIP_W > TIP_PANE_W - TIP_MARGIN then
		local flipped = rect[1] - TIP_W
		if flipped >= TIP_MARGIN then x = flipped end
	end

	local y = math.max(rect[4] - h, 0)

	pcall(widget.setPosition, "tipCanvas", { x, y })

	if not tipShowing then
		tipShowing = true
		pcall(widget.setVisible, "tipCanvas", true)
	end

	tipCanvas:clear()
	tipCanvas:drawRect({ 0, 0, w, h }, TIP_BG)
	tipCanvas:drawRect({ 0, 0, w, 1 }, TIP_EDGE)
	tipCanvas:drawRect({ 0, h - 1, w, h }, TIP_EDGE)
	tipCanvas:drawRect({ 0, 0, 1, h }, TIP_EDGE)
	tipCanvas:drawRect({ w - 1, 0, w, h }, TIP_EDGE)

	tipCanvas:drawText(title, {
		position = { TIP_PAD, h - TIP_PAD },
		horizontalAnchor = "left",
		verticalAnchor = "top"
	}, 8, TIP_TITLE_COLOR)

	tipCanvas:drawText(body or "", {
		position = { TIP_PAD, h - TIP_PAD - titleH - TIP_GAP },
		horizontalAnchor = "left",
		verticalAnchor = "top",
		wrapWidth = TIP_WRAP
	}, 7, TIP_BODY_COLOR)
end

-- Does nothing.
function petNameEntered()
end

-- Sends the trimmed name box to the port.
function renameClicked()
	local typed = widget.getText("tbPetName") or ""
	local trimmed = typed:match("^%s*(.-)%s*$")

	dbg("rename requested: %s", trimmed == "" and "<clear>" or trimmed)
	tell("petports_setPetName", { name = trimmed ~= "" and trimmed or nil })

	blurField("tbPetName")
end


-- Sends the port enabled checkbox.
function portEnabledToggled()
	tell("petports_setPortEnabled", { enabled = widget.getChecked("portEnabled") })
end

-- Focuses a colour box, or flips a checkbox and sends its owner's whole set.
function settingsRowClicked(from, index)
	local i = tonumber(index)
	if i == nil then return end

	local row = settingsRowKeys[i]
	local path = settingsRowPaths[i]
	if path == nil then return end

	local kind = rowKind(row)

	if kind == "rgb" then
		local ok, err = pcall(widget.focus, path .. ".settingField")
		if not ok then
			dbg("cannot focus %s.settingField: %s", path, tostring(err))
		end
		return
	end

	blurPaneFields()

	if kind ~= "check" then return end

	if from ~= "settingCheck" then
		widget.setChecked(path .. ".settingCheck",
			not widget.getChecked(path .. ".settingCheck"))
	end

	local set = {}
	for j, other in ipairs(settingsRowKeys) do
		if rowKind(other) == "check" and other.owner == row.owner
		   and settingsRowPaths[j] ~= nil then
			set[other.key] = widget.getChecked(settingsRowPaths[j] .. ".settingCheck")
		end
	end

	tell(SETTING_MESSAGE[row.owner], set)
end


-- Stores a light channel and sends every channel to the port.
local function commitLight(channel, value)
	if paneLight[channel] == value then return end

	paneLight[channel] = value

	lightPainted[channel] = value

	dbg("light %s -> %s", channel, tostring(value))

	local set = {}

	for _, name in ipairs(LIGHT_CHANNELS) do
		set[name] = lightValue(name)
	end

	for channel, value in pairs(set) do
		lightSent[channel] = value
	end

	tell(SETTING_MESSAGE.light, set)
end

-- Reads each colour box and commits it when its text changed.
local function pollLightFields()
	if activeTab ~= "tabSettings" or not paneHasUnit then return end

	for i, row in ipairs(settingsRowKeys) do
		local path = settingsRowPaths[i]

		if rowKind(row) == "rgb" and path ~= nil then
			local ok, text = pcall(widget.getText, path .. ".settingField")

			if ok and type(text) == "string" and text ~= lightShown[row.key] then
				lightShown[row.key] = text

				local value, clamped = rgbValue(text, row.key)

				if value ~= nil then
					commitLight(row.key, value)

					if clamped then setLightField(path, row.key, value) end
				end
			end
		end
	end
end

-- Steps a colour channel up or down and commits it.
function settingsSpinClicked(from, index)
	local i = tonumber(index)
	if i == nil then return end

	local row = settingsRowKeys[i]
	local path = settingsRowPaths[i]
	if rowKind(row) ~= "rgb" or path == nil then return end

	local step = (from == "settingDown") and -RGB_STEP or RGB_STEP
	local value = lightValue(row.key) + step

	local range = lightRange(row.key)

	if value < range.min then value = range.min end
	if value > range.max then value = range.max end

	commitLight(row.key, value)
	setLightField(path, row.key, value)
end

-- Does nothing.
function settingsFieldChanged()
end


-- Applies the strings, registers the settings row callbacks, shows the details tab and refreshes.
function init()
	dbg("build %s, port %s", PANE_BUILD_STAMP, tostring(portId()))
	widget.setText("buildStamp", PANE_BUILD_STAMP)

	for i = 1, BLIP_COUNT do
		blipShown[i] = nil
	end

	petports_applyStrings()
	sweepTips()

	widget.registerMemberCallback("settingsScroll.settingsList",
		"settingsRowClicked", settingsRowClicked)

	widget.registerMemberCallback("settingsScroll.settingsList",
		"settingsSpinClicked", settingsSpinClicked)
	widget.registerMemberCallback("settingsScroll.settingsList",
		"settingsFieldChanged", settingsFieldChanged)

	dbg("localAnimator %s, playAudio %s",
		type(localAnimator),
		type(localAnimator) == "table" and type(localAnimator.playAudio) or "n/a")

	showTab("tabDetails")
	refresh(true)
end

-- Polls the take and feed promises, refreshes, polls the colour boxes, and draws the portrait and the tooltip.
function update(dt)
	pollTake()
	pollFeed()
	refresh(false)

	pollLightFields()

	paintPreview(livePetId)

	paintHover()
end

-- Does nothing.
function uninit()
end
