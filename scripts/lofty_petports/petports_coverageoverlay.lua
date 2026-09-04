--  PETPORTS -- COVERAGE OVERLAY (PLAYER SIDE)
--
--  arch.port.coverage: the overlay belongs to the PLAYER and not to any port,
--  because every useful question about coverage is a question about
--  NEIGHBOURS -- does this reach the room next door, does it merge the two
--  networks I deliberately separated -- and an object can only ever draw its
--  own box.
--
--  Holding a petport is already required to place one, so the trigger is free.
--  The item is recognised BY TAG, not by name: `petports_petport` is what a
--  reskinned port carries, so a Steampunk or Floran petport pops the overlay
--  with no edit here. See the tag comment in petports_petport.object.
--
--  NOTHING NEW IS PUBLISHED FOR THIS. `petports_registry` in world.properties
--  is already the authority for every placed port and already carries the
--  rect, the participate flag and the network id -- see arch.network.registry.
--
--  TWO THINGS ARE DRAWN, AND THEY ANSWER DIFFERENT QUESTIONS:
--
--    OUTLINE   the boundary of each network. Where does coverage end.
--    HATCH     a crosshatch across the interior. AM I INSIDE ONE AT ALL -- on a
--              large network the nearest edge is off screen, and an
--              outline-only build looks exactly like an overlay that is broken
--              when read from the middle of the base it is describing.
--
--  THERE IS NO TENTATIVE RECT AND THERE IS NOT GOING TO BE ONE. Four routes
--  were tried and all four are recorded in `dead.port.tentativerect`; the last
--  one that would have worked was rejected on design rather than on mechanism.
--  Do not re-derive it from first principles. Read the entry.
--
--  DRAWABLES ARE RELATIVE TO THE PLAYER, MEASURED 2026-09-04. See
--  fact.port.drawablespace. Every world coordinate here is translated by
--  -entity.position() at the moment it is handed to localAnimator, and that
--  translation happens in EXACTLY ONE PLACE, in addSegment.

require "/scripts/lofty_petports/petports_work.lua"

local PETPORTS_OVERLAY_BUILD_STAMP = "2026-09-04g outline and crosshatch, no tentative rect"

--------------------------------------------------------------------------------
--  TUNING
--------------------------------------------------------------------------------

--  WHAT COUNTS AS HOLDING A PETPORT.
--
--  The swap slot is the cursor stack. The primary hand item is an action-bar
--  selection -- which is how furniture is normally placed, and therefore when
--  the overlay is most wanted. Both are read; either one fires.
--
--  If a port sitting in the action bar keeps the overlay up during ordinary
--  play and that grates, set OVERLAY_ON_HAND_ITEM false and the trigger
--  narrows to the cursor.
local OVERLAY_ON_SWAP_SLOT = true
local OVERLAY_ON_HAND_ITEM = true

local PORT_TAG = "petports_petport"

--  ONE COLOUR PER NETWORK, and the whole reason the overlay is worth building.
--  A subdivided base is unreadable as a pile of identical boxes and obvious as
--  a handful of tinted ones.
--
--  DELIBERATELY NOT KEYED ON THE NETWORK ID. An id is a PER-CLUSTER namespace
--  and it is 0 on every port that never touched the setting -- see
--  arch.network.membership -- so two genuinely separate id-0 clusters on
--  opposite sides of a base would tint identically, which is the exact
--  misreading the overlay exists to prevent. Keyed on the derived group
--  instead.
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

--  HATCH SPACING, IN TILES, AND IT IS THE ONLY COST LEVER HERE.
--
--  Line count scales with the network's BOUNDING BOX over the spacing, not
--  with the number of ports -- see hatchSegments -- so eight is cheap even on
--  a large base. Raise it if a very wide network gets close to the budget.
local OVERLAY_HATCH_SPACING = 8

--  Both diagonals. A single family reads as motion lines; two read as filled
--  area, which is what "am I standing in coverage" wants. Costs exactly twice
--  as many drawables, and the budget below is what catches that going wrong.
local OVERLAY_HATCH_CROSS = true

--  HARD CEILING ON DRAWABLES, AND IT DROPS THE HATCH RATHER THAN TRUNCATING.
--
--  A truncated hatch is worse than none: it draws a partial fill that reads as
--  "coverage stops here". If the budget is blown the outline survives intact
--  and the fill goes away, which is a degradation the player can interpret.
--
--  MEASURED against the shipped geometry: one port is 34 segments, six in a row
--  94, twenty in a long row 262, fifty sprawling 190. The long row is the
--  expensive shape, not the big base.
local OVERLAY_SEGMENT_BUDGET = 700

--  Segments shorter than this are dropped. Floating point rect arithmetic
--  leaves zero-length slivers where two edges are collinear, and a zero-length
--  line drawable is a wasted drawable at best.
local OVERLAY_EPSILON = 0.01

--------------------------------------------------------------------------------
--  CHAINING
--------------------------------------------------------------------------------
--
--  Every script in `deploymentConfig/scripts` shares ONE Lua context, so `init`
--  here overwrites whatever the previous script in the list defined. Capturing
--  and calling the previous one is the whole protocol; forgetting silently
--  disables every mod ahead of us in the list.
--
--  GUARDED, unlike the examples this is copied from. We are appended with `/-`
--  so an original always exists today -- but "today" is a load order, and a nil
--  call here takes the player down at spawn.

local petports_overlay_originalInit = init
local petports_overlay_originalUpdate = update
local petports_overlay_originalUninit = uninit

--------------------------------------------------------------------------------
--  WHAT IS BEING HELD
--------------------------------------------------------------------------------

--  pcall'd because root.itemHasTag throws on a descriptor naming an item that
--  no longer exists -- a stale stack from an uninstalled mod is enough. The
--  overlay is cosmetic and must never be able to take the player script down.
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
		--  player.primaryHandItem RETURNS A DESCRIPTOR; world.entityHandItem
		--  returns a bare NAME. Either answers the tag question, but the first
		--  is the documented player-table binding and the second is reached
		--  through world, so it is only the fallback.
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

--------------------------------------------------------------------------------
--  NETWORKS, FOR EVERY PORT ON THE PLANET
--------------------------------------------------------------------------------
--
--  petports_networkMembers answers "what network is THIS port in", which is the
--  question a port asks. The overlay asks the other one -- "what networks are
--  there" -- so it does its own flood fill over the whole registry.
--
--  IT MUST REACH THE SAME VERDICT, so the compatibility rule is
--  petports_entriesCompatible, shared with networkMemberMap rather than
--  restated here. Restating it is the coverageRect() trap in a new place.

--  SORTED. pairs() order is nondeterministic, and the group key below is the
--  first id in the group -- so an unsorted walk would repaint the base in
--  different colours every time the registry moved.
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

			--  THE KEY IS THE FIRST MEMBER, not the network id. Stable while
			--  membership is, and it CHANGES WHEN TWO NETWORKS MERGE -- which
			--  is a colour change the player wants to see, not a glitch.
			table.insert(networks, { key = group[1], rects = rects })
		end
	end

	return networks
end

--  A stable colour for a group key. Any hash does; this one is djb2 kept inside
--  Lua 5.1's number range by taking the modulus each step.
local function colourFor(key, alpha)
	local hash = 5381
	for i = 1, #key do
		hash = (hash * 33 + string.byte(key, i)) % 16777216
	end

	local base = OVERLAY_PALETTE[(hash % #OVERLAY_PALETTE) + 1]
	return { base[1], base[2], base[3], alpha }
end

--------------------------------------------------------------------------------
--  INTERVAL ARITHMETIC
--------------------------------------------------------------------------------
--
--  Shared by the outline and the hatch, which want opposite halves of the same
--  answer: the outline keeps what is NOT covered by a neighbour, the hatch
--  keeps what IS covered by anything.

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

--  What is left of [low, high] after the removals are taken out.
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

--------------------------------------------------------------------------------
--  THE OUTLINE
--------------------------------------------------------------------------------
--
--  THE EDGE OF THE NETWORK, NOT A PILE OF BOXES. Drawing each rect whole means
--  a base of eight ports is a lattice of interior lines that says nothing --
--  the only line that answers "what does this network cover" is the boundary.
--
--  Each rect contributes its four edges MINUS whatever lies strictly inside a
--  same-network neighbour. Strictly: an edge lying exactly ON a neighbour's
--  edge is kept, so two rects sharing a boundary draw one coincident line
--  rather than a gap.
--
--  Rects a tile apart still both draw in full, and that is correct --
--  adjacency is touch-or-overlap tested with a one-tile pad, so two rects with
--  a visible gap ARE one network and the gap is real coverage the units do not
--  have.

local function outlineSegments(rects)
	local segments = {}

	for index, rect in ipairs(rects) do
		--  { horizontal, fixed coordinate, span low, span high }
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

--------------------------------------------------------------------------------
--  THE CROSSHATCH
--------------------------------------------------------------------------------
--
--  WHY IT EXISTS: on a network big enough to matter, the nearest edge is off
--  screen. Standing in the middle of the base the overlay is describing, an
--  outline-only build looks exactly like an overlay that is not working.
--
--  ONE LINE FAMILY PER NETWORK, NOT PER RECT, AND THAT IS THE WHOLE TRICK.
--  Hatching each rect separately draws the same diagonal twice everywhere two
--  rects overlap -- visible as a brighter band exactly where coverage is
--  densest, which is backwards -- and the count scales with the number of
--  ports. Instead each diagonal is intersected with EVERY rect and the
--  resulting spans are merged, so overlap is free and the count scales with
--  the network's BOUNDING BOX over the spacing. Six ports in a row measured at
--  80 lines rather than 180.
--
--  Diagonals are indexed by c, where c = x - y going one way and c = x + y
--  going the other. Both families are phased on WORLD coordinates, so the
--  hatch does not shift when a network gains a member.

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
				--  x = c - y, so x within [rect[1], rect[3]] bounds y.
				yLow = math.max(rect[2], c - rect[3])
				yHigh = math.min(rect[4], c - rect[1])
			else
				--  x = y + c, the same bound the other way round.
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

--------------------------------------------------------------------------------
--  CACHE
--------------------------------------------------------------------------------

--  THE VERSION COUNTER IS NOT A GEOMETRY VERSION, AND KEYING ON IT ALONE WAS
--  WRONG. MEASURED 2026-09-04.
--
--  A registry publish bumps the version, and a port republishes whenever ITS
--  UNIT MOVES more than four tiles -- see UNIT_POSITION_THRESHOLD. Three
--  working units drove the version from 85501 to 85539 in sixteen seconds, so
--  the overlay rebuilt every outline and every hatch line about forty times
--  over while not one rect had changed. With the signature below the same test
--  window rebuilt ONCE against thirty-two publishes.
--
--  The ports have the same problem and already solve it the same way: re-derive
--  on the version, then compare what came out and only act on a real change
--  (petports_rectListsEqual). This is that, over the fields the overlay
--  actually draws from.
--
--  THE VERSION IS STILL THE CHEAP GATE. It is read first and skips even the
--  signature build on the overwhelming majority of ticks, where nothing at all
--  has moved.
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

	--  THE OUTLINE IS NEVER THE THING THAT GETS DROPPED.
	local dropped = false
	if #outline + #hatch > OVERLAY_SEGMENT_BUDGET then
		hatch = {}
		dropped = true
	end

	self.petportsOverlaySegments = outline
	for _, segment in ipairs(hatch) do
		table.insert(self.petportsOverlaySegments, segment)
	end

	--  ONLY ON A REAL GEOMETRY CHANGE, so this is a placement log and not a
	--  tick log.
	sb.logInfo("PETPORTS overlay rebuilt at version %s: %s networks, %s outline, %s hatch %s",
		sb.printJson(version), sb.printJson(#networks),
		sb.printJson(#outline), sb.printJson(#hatch),
		dropped and "(HATCH DROPPED, over budget)" or "")
end

--------------------------------------------------------------------------------
--  DRAWING
--------------------------------------------------------------------------------

--  THE ONE PLACE WORLD COORDINATES BECOME DRAWABLE COORDINATES.
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

--  ONE-TIME RENDER LAYER PROBE.
--
--  fact.art.renderlayerkey: an unknown render layer key is a hard failure, not
--  a fallback, and the overlay wants to sit above foreground tiles rather than
--  be buried by them. Asked once with a degenerate transparent drawable; if the
--  key is refused we fall back to the player's own layer, which is worse
--  looking and still works. MEASURED 2026-09-04: "Overlay" is accepted.
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

--------------------------------------------------------------------------------
--  LIFECYCLE
--------------------------------------------------------------------------------

function init()
	if petports_overlay_originalInit then petports_overlay_originalInit() end

	self.petportsOverlayVersion = nil
	self.petportsOverlaySignature = nil
	self.petportsOverlaySegments = nil
	self.petportsOverlayLayer = nil
	self.petportsOverlayProbed = false
	self.petportsOverlayDrawing = false

	sb.logInfo("PETPORTS overlay build: %s", PETPORTS_OVERLAY_BUILD_STAMP)
end

function update(dt)
	if petports_overlay_originalUpdate then petports_overlay_originalUpdate(dt) end

	if localAnimator == nil then return end

	if not holdingPetport() then
		--  CLEARED ONCE ON THE FALLING EDGE, NOT EVERY TICK.
		--
		--  clearDrawables wipes the WHOLE list on the player's animator, which
		--  is shared with anything else in this context that draws. We cannot
		--  avoid clobbering a co-tenant while the overlay is up, but we can
		--  avoid clobbering it for the 99% of play where no port is held.
		if self.petportsOverlayDrawing then
			localAnimator.clearDrawables()
			self.petportsOverlayDrawing = false
		end
		return
	end

	if not self.petportsOverlayProbed then
		self.petportsOverlayProbed = true
		probeRenderLayer()
	end

	rebuildIfStale()

	--  Drawables are retained between script ticks -- documented -- so a script
	--  that adds without clearing grows its list without bound.
	localAnimator.clearDrawables()

	local origin = entity.position()

	for _, segment in ipairs(self.petportsOverlaySegments) do
		addSegment(segment.a, segment.b, segment.colour, origin)
	end

	self.petportsOverlayDrawing = true
end

function uninit()
	--  OURS FIRST, THEN THEIRS. The original may tear down state this still
	--  wants; nothing here is state the original could want.
	if localAnimator ~= nil and self.petportsOverlayDrawing then
		localAnimator.clearDrawables()
	end

	if petports_overlay_originalUninit then petports_overlay_originalUninit() end
end
