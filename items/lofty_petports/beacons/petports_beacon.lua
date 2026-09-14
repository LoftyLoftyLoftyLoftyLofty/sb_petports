local DEFAULTS =
{
	enabled = true,

	feeder = true
}

local FIELDS =
{
	enabled = "petports_beaconEnabled",

	filter = "petports_beaconFilter",

	feeder = "petports_beaconFeeder",

	requests = "petports_beaconRequests",

	item = "petports_beaconItem",
	min = "petports_beaconMin",
	max = "petports_beaconMax"
}

local ICON_KEY = "petports_beaconIcon"

local PANE_ALIVE = 1.0

local DEBUG = false

local function dbg(fmt, ...)
	if not DEBUG then return end
	local ok, text = pcall(string.format, fmt, ...)
	sb.logInfo("petports beacon: %s", ok and text or ("<badformat> " .. tostring(fmt)))
end

local function j(value)
	if value == nil then return "nil" end
	local ok, text = pcall(sb.printJson, value)
	if ok then return text end
	return "<unprintable " .. type(value) .. ">"
end

local TOKEN_KEY = "petports_beaconPaneToken"

local function newToken()
	if sb.makeUuid then return sb.makeUuid() end
	return tostring(math.random(1, 1073741824))
end

local function setIcon(enabled)
	local frame = enabled and "on" or "off"

	animator.setGlobalTag("state", frame)

	local base = config.getParameter(ICON_KEY)

	if type(base) ~= "string" then
		sb.logError("petports beacon: no %s in item config; slot icon will not "
			.. "track on/off state", ICON_KEY)
		return
	end

	activeItem.setInventoryIcon(base .. ":" .. frame)
end

local function readConfig()
	local out = {}
	for field, key in pairs(FIELDS) do
		out[field] = config.getParameter(key, DEFAULTS[field])
	end
	return out
end

function init()
	self.paneToken = config.getParameter(TOKEN_KEY)

	if type(self.paneToken) ~= "string" then
		self.paneToken = nil
	else
		dbg("init: restored pane token %s", tostring(self.paneToken))
	end

	message.setHandler("petports_beaconHeld", function(_, _, token)
		if token == nil or token ~= self.paneToken then return false end

		self.paneTimer = PANE_ALIVE
		return true
	end)

	message.setHandler("petports_beaconPaneClosed", function(_, _, token)
		if token == nil or token ~= self.paneToken then return false end

		self.paneTimer = 0
		self.paneToken = nil

		activeItem.setInstanceValue(TOKEN_KEY, nil)

		dbg("pane closed cleanly, token cleared")
		return true
	end)

	message.setHandler("petports_beaconRead", function()
		self.paneTimer = PANE_ALIVE

		local out = readConfig()
		out.token = self.paneToken
		dbg("read -> %s", j(out))
		return out
	end)

	setIcon(config.getParameter(FIELDS.enabled, DEFAULTS.enabled) ~= false)


	message.setHandler("petports_beaconWrite", function(_, _, token, data, clear)
		if token == nil or token ~= self.paneToken then
			dbg("write REFUSED: token=%s mine=%s",
				tostring(token), tostring(self.paneToken))
			return false
		end

		if type(data) ~= "table" then
			dbg("write REFUSED: data is %s not table", type(data))
			return false
		end

		dbg("write accepted -> %s", j(data))

		for field, key in pairs(FIELDS) do
			if data[field] ~= nil then
				if data[field] == DEFAULTS[field] then
					dbg("  clear %s (equals default)", key)
					activeItem.setInstanceValue(key, nil)
				else
					dbg("  set %s = %s", key, j(data[field]))
					activeItem.setInstanceValue(key, data[field])
				end
			end
		end

		if type(clear) == "table" then
			for _, field in ipairs(clear) do
				local key = FIELDS[field]

				if key == nil then
					dbg("  clear IGNORED: %s is not a known field", tostring(field))
				else
					dbg("  clear %s", key)
					activeItem.setInstanceValue(key, nil)
				end
			end
		end

		if data.enabled ~= nil then
			setIcon(data.enabled ~= false)
		end

		return true
	end)
end

function update(dt, fireMode, shifting, moves)
	if (self.paneTimer or 0) > 0 then
		self.paneTimer = self.paneTimer - dt
	end
end

function activate(fireMode, shifting)
	if (self.paneTimer or 0) > 0 then
		dbg("activate ignored, pane still alive (%.2fs left)", self.paneTimer)
		return
	end

	self.paneTimer = PANE_ALIVE
	self.paneToken = newToken()

	activeItem.setInstanceValue(TOKEN_KEY, self.paneToken)

	dbg("activate: opening %s at %s token=%s",
		tostring(config.getParameter("interactAction")),
		tostring(config.getParameter("interactData")),
		tostring(self.paneToken))

	activeItem.interact(config.getParameter("interactAction"),
		config.getParameter("interactData"))
end

function uninit()
end
