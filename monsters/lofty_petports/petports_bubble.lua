local BUBBLE_DEBUG = true

local BUBBLE_MONSTER_PARTS = false

local function publishBubble(icons)
	local ok, players = pcall(world.players)
	if not ok or players == nil then
		if BUBBLE_DEBUG then
			sb.logInfo("UNIT bubble world.players failed: %s", tostring(players))
		end
		return
	end

	self.petportsBubbleSent = icons

	local show = self.petportsBubbleEnabled ~= false

	for _, id in ipairs(players) do
		world.sendEntityMessage(id, "petports_bubbleShow", entity.id(), icons, show)
	end

	if BUBBLE_DEBUG then
		sb.logInfo("UNIT bubble published %s icons to %s players",
			tostring(icons and #icons or 0), tostring(#players))
	end
end

local BUBBLE_STATE_TYPE = "bubble"
local BUBBLE_OFF        = "none"

local BUBBLE_LAYOUT = { "one", "two", "three" }

local BUBBLE_SLOTS = { "bubbleicon1", "bubbleicon2", "bubbleicon3" }

local BUBBLE_GROUP  = "bubble"
local BUBBLE_TAG    = "icon"

local BUBBLE_BLANK  = "/monsters/lofty_petports/shared/spinner/spinner.png:blank"

local BUBBLE_ICON_KEYS = { "inventoryIcon", "codexIcon" }

local BUBBLE_ICONS  = "/monsters/lofty_petports/shared/bubble/icons.png"
petports_bubbleIcon =
{
	x     = BUBBLE_ICONS .. ":x",
	box   = BUBBLE_ICONS .. ":box",
	sword = BUBBLE_ICONS .. ":sword",
	gun   = BUBBLE_ICONS .. ":gun",
	blank = BUBBLE_BLANK
}



function petports_setUnitBubbles(show)
	local enabled = show ~= false
	if enabled == (self.petportsBubbleEnabled ~= false) then return true end

	self.petportsBubbleEnabled = enabled

	sb.logInfo("UNIT bubble speech %s by its port",
		enabled and "ENABLED" or "DISABLED")

	if self.petportsBubbleSent ~= nil then
		publishBubble(self.petportsBubbleSent)
	end

	return true
end

local BUBBLE_HEARTBEAT_CALLS = 10

function petports_bubbleHeartbeat()
	if self.petportsBubbleSent == nil then return end

	self.petportsBubbleBeat = (self.petportsBubbleBeat or 0) + 1
	if self.petportsBubbleBeat < BUBBLE_HEARTBEAT_CALLS then return end
	self.petportsBubbleBeat = 0

	publishBubble(self.petportsBubbleSent)
end

function petports_bubbleSet(icons)
	petports_bubbleInstallShadow()

	local n = 0
	if icons ~= nil then n = #icons end

	if n > #BUBBLE_SLOTS then
		sb.logError("UNIT bubble handed %s icons, only %s slots exist; dropping the rest",
			tostring(n), tostring(#BUBBLE_SLOTS))
		n = #BUBBLE_SLOTS
	end

	publishBubble(n > 0 and icons or nil)

	if not BUBBLE_MONSTER_PARTS then
		self.petportsBubbleState = n > 0 and BUBBLE_LAYOUT[n] or BUBBLE_OFF
		return true
	end

	for i = 1, #BUBBLE_SLOTS do
		local path = BUBBLE_BLANK
		if i <= n then path = icons[i] end
		animator.setPartTag(BUBBLE_SLOTS[i], BUBBLE_TAG, path)
	end

	local state = BUBBLE_OFF
	if n > 0 then state = BUBBLE_LAYOUT[n] end

	local ok, err = pcall(animator.setAnimationState, BUBBLE_STATE_TYPE, state)
	if not ok then
		sb.logError("UNIT bubble FAILED to set %s/%s: %s",
			BUBBLE_STATE_TYPE, state, tostring(err))
		return false
	end

	if BUBBLE_DEBUG and state ~= self.petportsBubbleState then
		sb.logInfo("UNIT bubble %s slots %s", state, sb.printJson(icons or {}))
	end
	self.petportsBubbleState = state

	petports_bubbleFlip(true)
	return true
end

function petports_bubbleClear()
	petports_bubbleSet(nil)
end

function petports_bubbleFlip(force)
	if self.petportsBubbleGroupOk == nil then
		self.petportsBubbleGroupOk = animator.hasTransformationGroup(BUBBLE_GROUP)
		if not self.petportsBubbleGroupOk then
			sb.logError("UNIT bubble has NO transformation group %s -- icons will "
				.. "read backwards and mirrored whenever the unit faces left. "
				.. "Check where transformationGroups is declared in the .animation.",
				BUBBLE_GROUP)
		elseif BUBBLE_DEBUG then
			sb.logInfo("UNIT bubble transformation group %s present", BUBBLE_GROUP)
		end
	end

	if not self.petportsBubbleGroupOk then return end

	local dir = self.petportsBubbleFacing
	if dir == nil then dir = mcontroller.facingDirection() end

	local left = dir < 0
	if not force and left == self.petportsBubbleFlipped then return end
	self.petportsBubbleFlipped = left

	if BUBBLE_DEBUG then
		sb.logInfo("UNIT bubble un-flip applied, facing %s, forced %s",
			left and "left" or "right", tostring(force == true))
	end

	animator.resetTransformationGroup(BUBBLE_GROUP)
	if left then
		animator.scaleTransformationGroup(BUBBLE_GROUP, {-1, 1})
	end
end

function petports_bubbleInstallShadow()
	if self.petportsBubbleHooked ~= nil then return end

	local ok, err = pcall(function()
		local origFace = mcontroller.controlFace

		if type(origFace) == "function" then
			mcontroller.controlFace = function(direction, ...)
				if type(direction) == "number" and direction ~= 0 then
					self.petportsBubbleFacing = direction
					petports_bubbleFlip(false)
				end
				return origFace(direction, ...)
			end
		end
	end)

	self.petportsBubbleHooked = ok == true

	if ok then
		sb.logInfo("UNIT bubble facing shadow INSTALLED -- turns now flip in the "
			.. "frame they are commanded")
	else
		sb.logError("UNIT bubble facing shadow FAILED to install (%s) -- falling "
			.. "back to polling facingDirection(), which is one engine tick "
			.. "stale by construction", tostring(err))
	end
end


function petports_bubblePump(dt)

	if dt ~= nil then
		self.petportsBubblePumpCalls = (self.petportsBubblePumpCalls or 0) + 1
		self.petportsBubblePumpTime = (self.petportsBubblePumpTime or 0) + dt

		if self.petportsBubblePumpTime >= 1.0 then
			if self.petportsBubbleState ~= nil
			   and self.petportsBubbleState ~= BUBBLE_OFF then
				sb.logInfo("UNIT bubble pump cadence %s calls in %s s (dt %s)",
					tostring(self.petportsBubblePumpCalls),
					tostring(self.petportsBubblePumpTime),
					tostring(dt))
			end
			self.petportsBubblePumpCalls = 0
			self.petportsBubblePumpTime = 0
		end
	end

	if self.petportsBubbleState == nil or self.petportsBubbleState == BUBBLE_OFF then
		return
	end
	petports_bubbleFlip(false)
end

local BUBBLE_BLUEPRINT = "/items/generated/blueprint.png"

local function absolutePath(image, directory)
	if type(image) ~= "string" then return image end
	if image:sub(1, 1) == "/" then return image end
	return tostring(directory) .. image
end

local function withBlueprintBacking(icon)
	if icon == nil then return nil end

	local layers = { { image = BUBBLE_BLUEPRINT } }

	if type(icon) == "string" then
		layers[#layers + 1] = { image = icon }
	else
		for _, layer in ipairs(icon) do layers[#layers + 1] = layer end
	end

	return layers
end

function petports_bubbleItemIcon(descriptor)
	local ok, cfg = pcall(root.itemConfig, descriptor)
	if not ok or cfg == nil then
		if BUBBLE_DEBUG then
			sb.logInfo("UNIT bubble no itemConfig for %s", sb.printJson(descriptor))
		end
		return nil
	end


	local blueprint = cfg.config ~= nil and cfg.config.recipe ~= nil

	local icon = nil
	local params = nil

	if type(descriptor) == "table" and type(descriptor.parameters) == "table" then
		params = descriptor.parameters
	end

	for _, key in ipairs(BUBBLE_ICON_KEYS) do
		if icon == nil and params ~= nil then icon = params[key] end
		if icon == nil and cfg.config ~= nil then icon = cfg.config[key] end
	end

	if type(icon) == "table" then
		local layers = {}

		for _, layer in ipairs(icon) do
			local image = type(layer) == "table" and layer.image or layer

			if type(image) == "string" then
				layers[#layers + 1] =
				{
					image = absolutePath(image, cfg.directory),
					position = type(layer) == "table" and layer.position or nil
				}
			end
		end

		if #layers > 0 then
			if BUBBLE_DEBUG then
				self.petportsIconDumped = self.petportsIconDumped or {}
				local name = tostring(descriptor and descriptor.name)

				if not self.petportsIconDumped[name] then
					self.petportsIconDumped[name] = true
					local ok, encoded = pcall(sb.printJson, layers)
					sb.logInfo("UNIT bubble %s icon has %s layer(s): %s", name,
						tostring(#layers), ok and encoded or "unprintable")
				end
			end

			if blueprint then return withBlueprintBacking(layers) end
			return layers
		end

		if BUBBLE_DEBUG then
			sb.logInfo("UNIT bubble %s has a layered inventoryIcon with no usable "
				.. "images: %s", tostring(descriptor and descriptor.name),
				sb.printJson(icon))
		end
		return nil
	end

	if type(icon) ~= "string" then
		if BUBBLE_DEBUG then
			sb.logInfo("UNIT bubble %s has no icon under %s that is a path or a "
				.. "layer list (got %s)",
				tostring(descriptor and descriptor.name),
				table.concat(BUBBLE_ICON_KEYS, "/"), type(icon))
		end
		return nil
	end

	local path = absolutePath(icon, cfg.directory)

	if blueprint then return withBlueprintBacking(path) end
	return path
end

local function resolveToken(token)
	if type(token) == "table" and type(token.item) == "table" then
		local path = petports_bubbleItemIcon(token.item)
		if path ~= nil then return path end

		if BUBBLE_DEBUG then
			sb.logInfo("UNIT bubble %s has no usable icon, using the box",
				tostring(token.item.name))
		end
		return petports_bubbleIcon.box
	end

	if type(token) ~= "string" then return nil end

	local kind, value = token:match("^(%a+):(.+)$")
	if kind == nil then return nil end

	if kind == "mark" then
		return petports_bubbleIcon[value]
	end

	if kind == "item" then
		local path = petports_bubbleItemIcon({ name = value, count = 1 })
		if path ~= nil then return path end

		if BUBBLE_DEBUG then
			sb.logInfo("UNIT bubble %s has no single-path icon, using the box", value)
		end
		return petports_bubbleIcon.box
	end

	return nil
end

function petports_setUnitBubbleSpec(tokens)
	if type(tokens) ~= "table" or #tokens == 0 then
		petports_bubbleClear()
		return true
	end

	local icons = {}
	for _, token in ipairs(tokens) do
		local path = resolveToken(token)
		if path ~= nil then icons[#icons + 1] = path end
	end

	if #icons == 0 then
		sb.logError("UNIT bubble resolved NONE of %s -- saying nothing",
			sb.printJson(tokens))
		petports_bubbleClear()
		return false
	end

	petports_bubbleSet(icons)
	return true
end

function petports_bubbleSelfTest(itemName)
	itemName = itemName or "dirtmaterial"

	local mid = petports_bubbleItemIcon({ name = itemName, count = 1 })
	sb.logInfo("UNIT bubble SELFTEST item %s resolved to %s",
		tostring(itemName), tostring(mid))

	petports_bubbleSet({
		petports_bubbleIcon.x,
		mid or petports_bubbleIcon.box,
		petports_bubbleIcon.gun
	})
end

function petports_bubbleSelfTestItems(a, b, c)
	local icons = {}
	for _, name in ipairs({ a, b, c }) do
		if name ~= nil then
			local path = petports_bubbleItemIcon({ name = name, count = 1 })
			if path == nil then
				sb.logInfo("UNIT bubble bench: %s did not resolve, using the box", tostring(name))
				path = petports_bubbleIcon.box
			end
			icons[#icons + 1] = path
		end
	end
	petports_bubbleSet(icons)
end

function petports_bubbleSelfTestLayout(n)
	local icons = {}
	for i = 1, (n or 3) do icons[i] = petports_bubbleIcon.box end
	petports_bubbleSet(icons)
end



function petports_bubbleProbeMeasure(label, path)
	if type(path) ~= "string" then
		sb.logInfo("PROBE %s -- not a path (%s)", tostring(label), type(path))
		return
	end

	local sized, size = pcall(root.imageSize, path)
	local regioned, region = pcall(root.nonEmptyRegion, path)

	local sizeText = "UNMEASURABLE -- THIS ASSET DOES NOT RESOLVE"
	if sized and type(size) == "table" then
		local shown, encoded = pcall(sb.printJson, size)
		sizeText = shown and encoded or "unprintable"
	end

	local regionText = "unavailable"
	if regioned and type(region) == "table" then
		local shown, encoded = pcall(sb.printJson, region)
		regionText = shown and encoded or "unprintable"
	end

	sb.logInfo("PROBE %s path %s canvas %s visible %s", tostring(label),
		path, sizeText, regionText)
end

local function collectAssets(value, trail, out, depth)
	if depth > 3 then return end

	if type(value) == "string" then
		local lower = value:lower()

		if lower:find(".png", 1, true) or lower:find(".jpg", 1, true) then
			out[#out + 1] = trail .. " = " .. value
		end
		return
	end

	if type(value) ~= "table" then return end

	for key, sub in pairs(value) do
		if key ~= "contentPages" then
			collectAssets(sub, trail .. "." .. tostring(key), out, depth + 1)
		end
	end
end

function petports_bubbleProbeOne(name)
	local descriptor = { name = name, count = 1 }

	local ok, cfg = pcall(root.itemConfig, descriptor)
	if not ok or cfg == nil then
		sb.logInfo("PROBE %s -- root.itemConfig gave nothing (%s). No such item "
			.. "under that name, so nothing below this line ran.",
			tostring(name), tostring(cfg))
		return
	end

	sb.logInfo("PROBE %s directory %s", tostring(name), tostring(cfg.directory))

	local config = cfg.config
	if type(config) ~= "table" then
		sb.logInfo("PROBE %s has no config table (%s)", tostring(name), type(config))
		return
	end

	local keys = {}
	for key in pairs(config) do keys[#keys + 1] = tostring(key) end
	table.sort(keys)

	sb.logInfo("PROBE %s config keys: %s", tostring(name), table.concat(keys, " "))

	for _, key in ipairs(keys) do
		local lower = key:lower()

		if lower:find("icon", 1, true) or lower:find("image", 1, true) then
			local shown, encoded = pcall(sb.printJson, config[key])
			sb.logInfo("PROBE %s config.%s = %s", tostring(name), key,
				shown and encoded or type(config[key]))
		end
	end

	local pkeys = {}
	if type(cfg.parameters) == "table" then
		for key in pairs(cfg.parameters) do pkeys[#pkeys + 1] = tostring(key) end
		table.sort(pkeys)
	end

	sb.logInfo("PROBE %s parameter keys: %s", tostring(name),
		#pkeys > 0 and table.concat(pkeys, " ") or "(none)")

	local assets = {}
	collectAssets(config, "config", assets, 0)
	collectAssets(cfg.parameters, "parameters", assets, 0)

	if #assets == 0 then
		sb.logInfo("PROBE %s carries NO asset path anywhere in its config or "
			.. "parameters", tostring(name))
	end

	for _, line in ipairs(assets) do
		sb.logInfo("PROBE %s %s", tostring(name), line)
	end

	local icon = petports_bubbleItemIcon(descriptor)

	if icon == nil then
		sb.logInfo("PROBE %s resolver returned NIL -- this item draws as the box",
			tostring(name))
		return
	end

	if type(icon) == "string" then
		petports_bubbleProbeMeasure(name, icon)
		return
	end

	sb.logInfo("PROBE %s resolved to %s layer(s)", tostring(name), tostring(#icon))

	for i, layer in ipairs(icon) do
		petports_bubbleProbeMeasure(tostring(name) .. " layer " .. tostring(i),
			type(layer) == "table" and layer.image or layer)
	end
end

function petports_bubbleProbeIcon(...)
	local names = { ... }
	if #names == 0 then names = { "dirtmaterial", "humanhistory1-codex" } end

	for _, name in ipairs(names) do
		petports_bubbleProbeOne(name)
	end
end
