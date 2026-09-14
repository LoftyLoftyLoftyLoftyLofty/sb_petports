require "/scripts/lofty_petports/petports_work.lua"

local PETPORTS_OVERLAY_BUILD_STAMP = "2026-09-11d beams are not culled at all; the renderer already does it and better"


local OVERLAY_ON_SWAP_SLOT = true
local OVERLAY_ON_HAND_ITEM = true

local PORT_TAG = "petports_petport"

local OVERLAY_PALETTE = {
	{  90, 200, 255 },
	{ 255, 190,  70 },
	{ 140, 255, 140 },
	{ 255, 130, 200 },
	{ 190, 150, 255 },
	{ 255, 240, 130 }
}

local OVERLAY_OUTLINE_ALPHA = 210
local OVERLAY_HATCH_ALPHA = 55
local OVERLAY_WIDTH = 1

local OVERLAY_HATCH_SPACING = 8

local OVERLAY_HATCH_CROSS = true

local OVERLAY_SEGMENT_BUDGET = 700

local OVERLAY_EPSILON = 0.01


local petports_overlay_originalInit = init
local petports_overlay_originalUpdate = update
local petports_overlay_originalUninit = uninit


local function taggedPetport(name)
	if name == nil then return false end

	local ok, tagged = pcall(root.itemHasTag, name, PORT_TAG)
	return ok and tagged == true
end

local function holdingPetport()
	if OVERLAY_ON_SWAP_SLOT and player.swapSlotItem ~= nil then
		local cursor = player.swapSlotItem()
		if cursor ~= nil and taggedPetport(cursor.name) then return true end
	end

	if OVERLAY_ON_HAND_ITEM then
		if player.primaryHandItem ~= nil then
			local hand = player.primaryHandItem()
			if hand ~= nil and taggedPetport(hand.name) then return true end
		elseif world.entityHandItem ~= nil then
			if taggedPetport(world.entityHandItem(entity.id(), "primary")) then
				return true
			end
		end
	end

	return false
end


local function sortedPortIds(ports)
	local ids = {}
	for portId, _ in pairs(ports) do table.insert(ids, portId) end
	table.sort(ids)
	return ids
end

local function allNetworks(ports, ids)
	local claimed = {}
	local networks = {}

	for _, seedId in ipairs(ids) do
		if claimed[seedId] == nil and ports[seedId] ~= nil
		   and ports[seedId].rect ~= nil then
			claimed[seedId] = true

			local group = { seedId }
			local frontier = { seedId }

			while #frontier > 0 do
				local currentId = table.remove(frontier)
				local current = ports[currentId]

				for _, otherId in ipairs(ids) do
					local other = ports[otherId]
					if claimed[otherId] == nil and other ~= nil and other.rect ~= nil
					   and petports_entriesCompatible(current, other)
					   and petports_rectsAdjacent(current.rect, other.rect) then
						claimed[otherId] = true
						table.insert(group, otherId)
						table.insert(frontier, otherId)
					end
				end
			end

			table.sort(group)

			local rects = {}
			for _, memberId in ipairs(group) do
				table.insert(rects, ports[memberId].rect)
			end

			table.insert(networks, { key = group[1], rects = rects })
		end
	end

	return networks
end

local function colourFor(key, alpha)
	local hash = 5381
	for i = 1, #key do
		hash = (hash * 33 + string.byte(key, i)) % 16777216
	end

	local base = OVERLAY_PALETTE[(hash % #OVERLAY_PALETTE) + 1]
	return { base[1], base[2], base[3], alpha }
end


local function mergeIntervals(intervals)
	table.sort(intervals, function(a, b) return a[1] < b[1] end)

	local merged = {}
	for _, span in ipairs(intervals) do
		local last = merged[#merged]
		if last ~= nil and span[1] <= last[2] then
			if span[2] > last[2] then last[2] = span[2] end
		else
			table.insert(merged, { span[1], span[2] })
		end
	end
	return merged
end

local function complement(low, high, removals)
	local kept = {}
	local cursor = low

	for _, span in ipairs(mergeIntervals(removals)) do
		if span[1] > cursor then
			local stop = span[1]
			if stop > high then stop = high end
			if stop - cursor > OVERLAY_EPSILON then
				table.insert(kept, { cursor, stop })
			end
		end
		if span[2] > cursor then cursor = span[2] end
		if cursor >= high then break end
	end

	if high - cursor > OVERLAY_EPSILON then
		table.insert(kept, { cursor, high })
	end

	return kept
end


local function outlineSegments(rects)
	local segments = {}

	for index, rect in ipairs(rects) do
		local edges = {
			{ true,  rect[2], rect[1], rect[3] },
			{ true,  rect[4], rect[1], rect[3] },
			{ false, rect[1], rect[2], rect[4] },
			{ false, rect[3], rect[2], rect[4] }
		}

		for _, edge in ipairs(edges) do
			local horizontal, fixed, low, high = edge[1], edge[2], edge[3], edge[4]
			local removals = {}

			for otherIndex, other in ipairs(rects) do
				if otherIndex ~= index then
					local inside, overlapLow, overlapHigh

					if horizontal then
						inside = other[2] < fixed and fixed < other[4]
						overlapLow = math.max(low, other[1])
						overlapHigh = math.min(high, other[3])
					else
						inside = other[1] < fixed and fixed < other[3]
						overlapLow = math.max(low, other[2])
						overlapHigh = math.min(high, other[4])
					end

					if inside and overlapLow < overlapHigh then
						table.insert(removals, { overlapLow, overlapHigh })
					end
				end
			end

			for _, span in ipairs(complement(low, high, removals)) do
				if horizontal then
					table.insert(segments, { { span[1], fixed }, { span[2], fixed } })
				else
					table.insert(segments, { { fixed, span[1] }, { fixed, span[2] } })
				end
			end
		end
	end

	return segments
end


local function hatchSegments(rects, spacing, anti)
	local segments = {}
	if #rects == 0 then return segments end

	local cMin, cMax

	for _, rect in ipairs(rects) do
		local low, high
		if anti then
			low = rect[1] + rect[2]
			high = rect[3] + rect[4]
		else
			low = rect[1] - rect[4]
			high = rect[3] - rect[2]
		end

		if cMin == nil or low < cMin then cMin = low end
		if cMax == nil or high > cMax then cMax = high end
	end

	local c = math.ceil(cMin / spacing) * spacing

	while c <= cMax do
		local spans = {}

		for _, rect in ipairs(rects) do
			local yLow, yHigh
			if anti then
				yLow = math.max(rect[2], c - rect[3])
				yHigh = math.min(rect[4], c - rect[1])
			else
				yLow = math.max(rect[2], rect[1] - c)
				yHigh = math.min(rect[4], rect[3] - c)
			end

			if yHigh - yLow > OVERLAY_EPSILON then
				table.insert(spans, { yLow, yHigh })
			end
		end

		for _, span in ipairs(mergeIntervals(spans)) do
			if anti then
				table.insert(segments,
					{ { c - span[1], span[1] }, { c - span[2], span[2] } })
			else
				table.insert(segments,
					{ { span[1] + c, span[1] }, { span[2] + c, span[2] } })
			end
		end

		c = c + spacing
	end

	return segments
end


local function geometrySignature(ports, ids)
	local parts = {}

	for _, portId in ipairs(ids) do
		local entry = ports[portId]
		local rect = entry.rect

		if rect ~= nil then
			table.insert(parts, table.concat({
				portId,
				rect[1], rect[2], rect[3], rect[4],
				tostring(entry.participate),
				tostring(entry.id)
			}, ":"))
		end
	end

	return table.concat(parts, "|")
end

local function rebuildIfStale()
	local registry = petports_registry()
	local version = registry.version or 0

	if self.petportsOverlayVersion == version
	   and self.petportsOverlaySegments ~= nil then
		return
	end
	self.petportsOverlayVersion = version

	local ports = registry.ports or {}
	local ids = sortedPortIds(ports)
	local signature = geometrySignature(ports, ids)

	if self.petportsOverlaySignature == signature
	   and self.petportsOverlaySegments ~= nil then
		return
	end
	self.petportsOverlaySignature = signature

	local networks = allNetworks(ports, ids)

	local outline = {}
	local hatch = {}

	for _, network in ipairs(networks) do
		local edgeColour = colourFor(network.key, OVERLAY_OUTLINE_ALPHA)
		local fillColour = colourFor(network.key, OVERLAY_HATCH_ALPHA)

		for _, segment in ipairs(outlineSegments(network.rects)) do
			table.insert(outline,
				{ a = segment[1], b = segment[2], colour = edgeColour })
		end

		local lines = hatchSegments(network.rects, OVERLAY_HATCH_SPACING, false)
		if OVERLAY_HATCH_CROSS then
			for _, segment in ipairs(hatchSegments(network.rects, OVERLAY_HATCH_SPACING, true)) do
				table.insert(lines, segment)
			end
		end

		for _, segment in ipairs(lines) do
			table.insert(hatch,
				{ a = segment[1], b = segment[2], colour = fillColour })
		end
	end

	local dropped = false
	if #outline + #hatch > OVERLAY_SEGMENT_BUDGET then
		hatch = {}
		dropped = true
	end

	self.petportsOverlaySegments = outline
	for _, segment in ipairs(hatch) do
		table.insert(self.petportsOverlaySegments, segment)
	end

	sb.logInfo("PETPORTS overlay rebuilt at version %s: %s networks, %s outline, %s hatch %s",
		sb.printJson(version), sb.printJson(#networks),
		sb.printJson(#outline), sb.printJson(#hatch),
		dropped and "(HATCH DROPPED, over budget)" or "")
end



local BUBBLE_PPT = 8.0

local BUBBLE_SHEET = "/monsters/lofty_petports/shared/bubble/bubble.png"
local BUBBLE_FRAME = { "one", "two", "three" }
local BUBBLE_PITCH = 18.0 / BUBBLE_PPT
local BUBBLE_LIFT  = 3.0 / BUBBLE_PPT

local BUBBLE_Y = 3.0

local BUBBLE_DRAW_RANGE = 25.0


local function bubbleSlotX(count)
	if count == 1 then return { 0.0 } end
	if count == 2 then return { -BUBBLE_PITCH / 2, BUBBLE_PITCH / 2 } end
	return { -BUBBLE_PITCH, 0.0, BUBBLE_PITCH }
end

local function bubblesToDraw(origin)
	local out = {}
	if self.petportsBubbles == nil then return out end

	local cull = BUBBLE_DRAW_RANGE * BUBBLE_DRAW_RANGE

	for id, held in pairs(self.petportsBubbles) do
		if not world.entityExists(id) then
			self.petportsBubbles[id] = nil

		elseif type(held) == "table" and held.enabled
		       and type(held.icons) == "table" and #held.icons > 0 then
			local pos = world.entityPosition(id)
			if pos ~= nil then
				local delta = world.distance(pos, origin)
				local d2 = delta[1] * delta[1] + delta[2] * delta[2]

				if d2 <= cull then
					out[#out + 1] =
					{
						id = id,
						d2 = d2,
						delta = delta,
						icons = held.icons
					}
				end
			end
		end
	end

	table.sort(out, function(a, b)
		if a.d2 ~= b.d2 then return a.d2 < b.d2 end
		return a.id < b.id
	end)

	return out
end

local BUBBLE_ICON_PX = 16

local BUBBLE_ICON_SLACK = 2

local function iconSize(path)
	self.petportsIconSize = self.petportsIconSize or {}

	local held = self.petportsIconSize[path]
	if held ~= nil then
		if held == false then return nil end
		return held
	end

	local ok, size = pcall(root.imageSize, path)

	if not ok or type(size) ~= "table" or size[1] == nil then
		self.petportsIconSize[path] = false
		sb.logInfo("PETPORTS bubble could not measure %s (%s) -- drawn unscaled",
			tostring(path), tostring(size))
		return nil
	end

	self.petportsIconSize[path] = size

	return size
end

local function iconBox(path)
	self.petportsIconBox = self.petportsIconBox or {}

	local held = self.petportsIconBox[path]
	if held ~= nil then return held end

	local size = iconSize(path)
	if size == nil then return nil end

	local w = size[1] or 0
	local h = size[2] or 0

	local box = { -w * 0.5, -h * 0.5, w * 0.5, h * 0.5 }
	local ok, region = pcall(root.nonEmptyRegion, path)

	if ok and type(region) == "table" and region[3] ~= nil
	   and region[3] > region[1] and region[4] > region[2] then
		box = {
			region[1] - w * 0.5,
			region[2] - h * 0.5,
			region[3] - w * 0.5,
			region[4] - h * 0.5
		}
	end

	self.petportsIconBox[path] = box

	sb.logInfo("PETPORTS bubble %s canvas %sx%s visible %s",
		tostring(path), tostring(w), tostring(h),
		(ok and type(region) == "table") and sb.printJson(region) or "unavailable")

	return box
end

local function layoutIcon(icon)
	local layers = icon
	if type(icon) == "string" then layers = { { image = icon } } end
	if type(layers) ~= "table" then return nil end

	local placed = {}
	local minX, minY, maxX, maxY

	for _, layer in ipairs(layers) do
		local image = type(layer) == "table" and layer.image or layer

		if type(image) == "string" then
			local box = iconBox(image)
			if box == nil then
				box = { -BUBBLE_ICON_PX * 0.5, -BUBBLE_ICON_PX * 0.5,
				        BUBBLE_ICON_PX * 0.5, BUBBLE_ICON_PX * 0.5 }
			end

			local at = (type(layer) == "table" and layer.position) or { 0, 0 }
			local px = tonumber(at[1]) or 0
			local py = tonumber(at[2]) or 0

			placed[#placed + 1] =
			{
				image = image, px = px, py = py,
				w = box[3] - box[1], h = box[4] - box[2]
			}

			local l, r = px + box[1], px + box[3]
			local b, t = py + box[2], py + box[4]

			minX = (minX == nil or l < minX) and l or minX
			maxX = (maxX == nil or r > maxX) and r or maxX
			minY = (minY == nil or b < minY) and b or minY
			maxY = (maxY == nil or t > maxY) and t or maxY
		end
	end

	if #placed == 0 then return nil end

	local spanX = maxX - minX
	local spanY = maxY - minY
	local biggest = math.max(spanX, spanY)

	local scale = 1.0
	if biggest > BUBBLE_ICON_PX + BUBBLE_ICON_SLACK and biggest > 0 then
		scale = BUBBLE_ICON_PX / biggest
	end

	local cx = (minX + maxX) * 0.5
	local cy = (minY + maxY) * 0.5

	if #placed > 1 then
		self.petportsIconLogged = self.petportsIconLogged or {}
		local key = placed[1].image

		if not self.petportsIconLogged[key] then
			self.petportsIconLogged[key] = true

			local parts = {}
			for _, part in ipairs(placed) do
				parts[#parts + 1] = string.format("%sx%s@%s,%s",
					tostring(part.w), tostring(part.h),
					tostring(part.px), tostring(part.py))
			end

			sb.logInfo("PETPORTS bubble icon: %s layers, span %sx%s, scale %s -- %s",
				tostring(#placed), tostring(spanX), tostring(spanY),
				tostring(scale), table.concat(parts, " | "))
		end
	end

	local out = { scale = scale }

	for _, part in ipairs(placed) do
		out[#out + 1] =
		{
			image = part.image,
			x = (part.px - cx) * scale / BUBBLE_PPT,
			y = (part.py - cy) * scale / BUBBLE_PPT
		}
	end

	return out
end

local function addBubble(entry)
	local icons = entry.icons
	local n = #icons
	if n > #BUBBLE_FRAME then n = #BUBBLE_FRAME end

	local base = { entry.delta[1], entry.delta[2] + BUBBLE_Y }

	local backing = {
		image = BUBBLE_SHEET .. ":" .. BUBBLE_FRAME[n],
		position = base,
		centered = true,
		fullbright = true
	}

	if self.petportsOverlayLayer ~= nil then
		localAnimator.addDrawable(backing, self.petportsOverlayLayer)
	else
		localAnimator.addDrawable(backing)
	end

	local xs = bubbleSlotX(n)
	for i = 1, n do
		local layout = layoutIcon(icons[i])

		if layout ~= nil then
			local transform = nil

			if layout.scale < 1.0 then
				transform = {
					{ layout.scale, 0, 0 },
					{ 0, layout.scale, 0 },
					{ 0, 0, 1 }
				}
			end

			for _, part in ipairs(layout) do
				local drawable = {
					image = part.image,
					position = {
						base[1] + xs[i] + part.x,
						base[2] + BUBBLE_LIFT + part.y
					},

					centered = true,
					fullbright = true
				}

				if transform ~= nil then drawable.transformation = transform end

				if self.petportsOverlayLayer ~= nil then
					localAnimator.addDrawable(drawable, self.petportsOverlayLayer)
				else
					localAnimator.addDrawable(drawable)
				end
			end
		end
	end
end


local function addSegment(a, b, colour, origin)
	local drawable = {
		line = {
			{ a[1] - origin[1], a[2] - origin[2] },
			{ b[1] - origin[1], b[2] - origin[2] }
		},
		width = OVERLAY_WIDTH,
		color = colour,
		fullbright = true
	}

	if self.petportsOverlayLayer ~= nil then
		localAnimator.addDrawable(drawable, self.petportsOverlayLayer)
	else
		localAnimator.addDrawable(drawable)
	end
end


local BEAM_BODY = "/monsters/lofty_petports/shared/beam/beam.png"
local BEAM_END  = "/monsters/lofty_petports/shared/beam/beamend.png"
local BEAM_SEGMENT = 0.48
local BEAM_OVERDRAW = 0.2

local BEAM_TINT = "ffffff"

local BEAM_WAVE_FREQ = 3.0
local BEAM_WAVE_AMP = 0.12
local BEAM_WAVE_MOVE = 6.0



local BEAM_SEGMENT_CAP = 32

local function beamsToDraw(origin)
	local out = {}
	if self.petportsBeams == nil then return out end

	local now = self.petportsBeamClock or 0

	for id, beam in pairs(self.petportsBeams) do
		if type(beam) ~= "table" or now >= (beam.endsAt or 0) then
			self.petportsBeams[id] = nil
		elseif not world.entityExists(id) then
			self.petportsBeams[id] = nil
		else
			local pos = world.entityPosition(id)

			if pos ~= nil then
				out[#out + 1] =
				{
					from = world.distance(pos, origin),
					to = world.distance(beam.tile, origin),
					beam = beam
				}
			end
		end
	end

	return out
end

local function addBeam(entry)
	local beam = entry.beam
	local now = self.petportsBeamClock or 0

	local elapsed = now - (beam.startedAt or now)
	if elapsed < 0 then return end

	local period = beam.period or 0.25
	local phase = (elapsed % period) / period
	local alpha = math.sin(phase * math.pi)

	if alpha <= 0.01 then return end

	local directive = string.format("?multiply=%s%02x", BEAM_TINT,
		math.floor(alpha * 255))

	local dx = entry.to[1] - entry.from[1]
	local dy = entry.to[2] - entry.from[2]
	local length = math.sqrt(dx * dx + dy * dy)

	if length < 0.05 then return end

	local count = math.floor(((length + BEAM_OVERDRAW) / BEAM_SEGMENT) + 0.5)
	if count < 1 then return end
	if count > BEAM_SEGMENT_CAP then count = BEAM_SEGMENT_CAP end

	local leftward = dx < 0

	local cosine = dx / length
	if cosine > 1 then cosine = 1 elseif cosine < -1 then cosine = -1 end

	local angle = math.acos(cosine)
	if dy < 0 then angle = -angle end

	if leftward then angle = math.pi - angle end

	local stepX = (dx / length) * BEAM_SEGMENT
	local stepY = (dy / length) * BEAM_SEGMENT

	local baseX = entry.from[1] + stepX * 0.5
	local baseY = entry.from[2] + stepY * 0.5

	for i = 1, count do
		local image = (i == count) and BEAM_END or BEAM_BODY

		local wobble = math.sin(((i * BEAM_SEGMENT) - (now * BEAM_WAVE_MOVE))
			/ (BEAM_WAVE_FREQ / math.pi)) * BEAM_WAVE_AMP * 0.5

		local sway = leftward and -angle or angle
		local offX = -math.sin(sway) * wobble
		local offY = math.cos(sway) * wobble

		local drawable = {
			image = image .. directive,
			position = { baseX + offX, baseY + offY },
			centered = true,
			mirrored = leftward,
			rotation = angle,
			fullbright = true
		}

		if self.petportsOverlayLayer ~= nil then
			localAnimator.addDrawable(drawable, self.petportsOverlayLayer)
		else
			localAnimator.addDrawable(drawable)
		end

		baseX = baseX + stepX
		baseY = baseY + stepY
	end
end

local function probeRenderLayer()
	local ok = pcall(function()
		localAnimator.addDrawable(
		{
			line = { { 0, 0 }, { 0, 0 } },
			width = 1,
			color = { 0, 0, 0, 0 },
			fullbright = true
		}, "Overlay")
	end)

	if ok then
		self.petportsOverlayLayer = "Overlay"
	else
		self.petportsOverlayLayer = nil
	end

	sb.logInfo("PETPORTS overlay render layer: %s",
		tostring(self.petportsOverlayLayer or "entity default"))
end


function init()
	if petports_overlay_originalInit then petports_overlay_originalInit() end

	self.petportsOverlayVersion = nil
	self.petportsOverlaySignature = nil
	self.petportsOverlaySegments = nil
	self.petportsOverlayLayer = nil
	self.petportsOverlayProbed = false
	self.petportsOverlayDrawing = false

	self.petportsBubbles = {}

	message.setHandler("petports_bubbleShow", function(_, _, unitId, icons, show)
		if type(unitId) ~= "number" then return end

		if type(icons) ~= "table" or #icons == 0 then
			self.petportsBubbles[unitId] = nil
		else
			self.petportsBubbles[unitId] =
			{
				icons = icons,
				enabled = show ~= false
			}
		end
	end)

	self.petportsBeams = {}
	self.petportsBeamClock = 0

	message.setHandler("petports_beamShow", function(_, _, unitId, tile, swings, period)
		if type(unitId) ~= "number" then return end
		if type(tile) ~= "table" or tile[1] == nil or tile[2] == nil then return end

		local n = tonumber(swings) or 0
		local p = tonumber(period) or 0

		if n <= 0 or p <= 0 then
			self.petportsBeams[unitId] = nil
			return
		end

		local now = self.petportsBeamClock or 0

		self.petportsBeams[unitId] =
		{
			tile = { tile[1], tile[2] },
			period = p,
			startedAt = now,
			endsAt = now + (n * p)
		}
	end)

	sb.logInfo("PETPORTS overlay build: %s", PETPORTS_OVERLAY_BUILD_STAMP)
end

function update(dt)
	if petports_overlay_originalUpdate then petports_overlay_originalUpdate(dt) end

	if localAnimator == nil then return end

	if not self.petportsOverlayProbed then
		self.petportsOverlayProbed = true
		probeRenderLayer()
	end

	self.petportsBeamClock = (self.petportsBeamClock or 0) + dt

	local origin = entity.position()
	local wantCoverage = holdingPetport()
	local bubbles = bubblesToDraw(origin)
	local beams = beamsToDraw(origin)

	if not wantCoverage and #bubbles == 0 and #beams == 0 then
		if self.petportsOverlayDrawing then
			localAnimator.clearDrawables()
			self.petportsOverlayDrawing = false
		end
		return
	end

	if wantCoverage then rebuildIfStale() end

	localAnimator.clearDrawables()

	if wantCoverage and self.petportsOverlaySegments ~= nil then
		for _, segment in ipairs(self.petportsOverlaySegments) do
			addSegment(segment.a, segment.b, segment.colour, origin)
		end
	end

	local okBeams, beamErr = pcall(function()
		for _, entry in ipairs(beams) do
			addBeam(entry)
		end
	end)

	if not okBeams then
		local note = tostring(beamErr)
		if self.petportsBeamFault ~= note then
			self.petportsBeamFault = note
			sb.logInfo("PETPORTS overlay beam draw FAILED and was skipped: %s",
				note)
		end
	elseif self.petportsBeamFault ~= nil then
		self.petportsBeamFault = nil
		sb.logInfo("PETPORTS overlay beam draw recovered")
	end

	for _, entry in ipairs(bubbles) do
		addBubble(entry)
	end

	self.petportsOverlayDrawing = true
end

function uninit()
	if localAnimator ~= nil and self.petportsOverlayDrawing then
		localAnimator.clearDrawables()
	end

	if petports_overlay_originalUninit then petports_overlay_originalUninit() end
end
