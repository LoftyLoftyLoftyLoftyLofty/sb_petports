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

local PETPORTS_OVERLAY_BUILD_STAMP = "2026-09-11d beams are not culled at all; the renderer already does it and better"

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
--  CHAT BUBBLES
--------------------------------------------------------------------------------
--
--  2026-09-07c player-side bubble reader
--
--  A unit cannot draw its own bubble above the water overlay. Every drawable a
--  monster produces is clamped to its monstervariant's render layer -- there is
--  no per-part override, and zLevel only orders parts WITHIN that layer. So the
--  bubble is drawn here instead, on the player, at the same "Overlay" layer the
--  coverage boxes use, which is where engine chat text lives and why chat stays
--  legible from inside a one-tile shaft.
--
--  THE UNIT PUSHES, THIS SCRIPT NEVER ASKS. A monster's scripts run on the
--  master only, so world.callScriptedEntity from a client cannot reach one.
--  Pull is not available; the unit sends on content change.
--
--  A DEAD OR DISTANT UNIT IS DROPPED HERE, NOT REMEMBERED. The sender cannot
--  send a retraction it is not alive to send, so the reader treats its table as
--  a cache to be validated rather than a record to be trusted.

--  Pixels to the tile. bubble.frames is measured in pixels; drawable positions
--  are in tiles.
local BUBBLE_PPT = 8.0

--  Straight out of bubble.frames. Changing the art means changing these and
--  nothing else on this side.
local BUBBLE_SHEET = "/monsters/lofty_petports/shared/bubble/bubble.png"
local BUBBLE_FRAME = { "one", "two", "three" }
local BUBBLE_PITCH = 18.0 / BUBBLE_PPT
local BUBBLE_LIFT  = 3.0 / BUBBLE_PPT

--  Height of the bubble's centre above the unit's own position, in tiles.
--  TUNE-IN-GAME, and the only number here that is a taste judgement rather
--  than a measurement.
local BUBBLE_Y = 3.0

--  Beyond this RADIUS a bubble is not drawn even if its unit is still sending.
--  Stops a unit offscreen from contributing drawables nobody can read.
--
--  A RADIUS AND NOT A BOX. The first pass tested abs(dx) and abs(dy)
--  separately, which admits a unit 84 tiles out on the diagonal.
--
--  25 SET BY EYE, 2026-09-07. This is an earshot, not a view frustum -- the
--  question it answers is whether the player is close enough to be spoken to,
--  which is a judgement rather than a measurement. 40 was tried first and read
--  as too far, 20 as slightly too near.
--
--  Tightening it further only ever removes the furthest, because the sort below
--  is nearest-first.
local BUBBLE_DRAW_RANGE = 25.0


--  Slot x offsets by icon count, centred on the unit. Same derivation as the
--  per-state offsets in the .animation files, from the same two numbers.
local function bubbleSlotX(count)
	if count == 1 then return { 0.0 } end
	if count == 2 then return { -BUBBLE_PITCH / 2, BUBBLE_PITCH / 2 } end
	return { -BUBBLE_PITCH, 0.0, BUBBLE_PITCH }
end

--  Collect what is currently worth drawing, dropping anything stale.
--
--  world.distance AND NOT A SUBTRACTION. Worlds wrap in x, so a plain
--  subtraction sends the bubble of a unit near the seam across the whole map.
--
--  ENTRIES FOR UNITS THAT NO LONGER EXIST ARE DROPPED. What world.entityExists
--  reports on a client for a unit that is merely far away is UNVERIFIED -- it
--  may report false for an unloaded entity the same as for a dead one, or it
--  may not. Either way there is nothing to draw, so the entry goes.
--
--  THE CONSEQUENCE OF THAT DEPENDS ON THE ANSWER AND IS NOT YET KNOWN. If a
--  dropped entry can only come back when the unit's content next changes, then
--  walking out of range and back leaves no bubble until something happens to
--  the unit. Nothing re-announces on approach today.
--
--  SORTED, AND NOT CAPPED. There was a draw budget here and it is gone: a
--  player who fills the screen with units should see all of them say what they
--  are doing, and a cap chooses for them. The range cull above is the only
--  limit, and that one is an earshot rather than a performance guess.
--
--  THE SORT OUTLIVED THE CAP, for a smaller reason. pairs() order is
--  nondeterministic and drawables overlap in the order they are added, so an
--  unsorted walk makes two overlapping bubbles swap which is on top from frame
--  to frame. Nearest first, entity id as the tiebreak so two units at exactly
--  equal range still order stably.
local function bubblesToDraw(origin)
	local out = {}
	if self.petportsBubbles == nil then return out end

	local cull = BUBBLE_DRAW_RANGE * BUBBLE_DRAW_RANGE

	for id, held in pairs(self.petportsBubbles) do
		if not world.entityExists(id) then
			self.petportsBubbles[id] = nil

		--  SWITCHED OFF IS SKIPPED, NOT FORGOTTEN. The entry stays so that
		--  switching it back on repaints immediately; only a unit that has
		--  stopped existing is dropped.
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

--  THE SIZE OF ONE ICON SLOT, IN PIXELS. bubble.frames is laid out around 16px
--  icons at an 18px pitch, and every offset above derives from those two
--  numbers -- so an icon bigger than this does not overflow its slot, it
--  overflows the bubble.
local BUBBLE_ICON_PX = 16

--  HOW FAR AN ICON MAY OVERSHOOT ITS SLOT BEFORE IT IS SHRUNK.
--
--  MEASURED 2026-09-08. A blueprint is an 18x18 paper behind a 16x16 item icon
--  -- see BUBBLE_BLUEPRINT in petports_bubble.lua -- so the assembly is 18 and
--  the 16px cap was scaling it by 16/18. That resamples 12px of visible pixel
--  art down to 10.67 at a NON-INTEGER ratio, which is visible mush, and it is
--  worse damage than the overshoot costs.
--
--  WHAT THE OVERSHOOT ACTUALLY COSTS, FROM bubble.frames: cell 16, gap 2, so
--  the pitch is 18. An 18px icon centred in its cell spends 1px of gap on each
--  side and reaches neither the 4px padding nor the border. The worst case in
--  the game is two blueprints side by side, which touch exactly and do not
--  overlap; a blueprint beside an ordinary 16px icon still leaves 1px.
--
--  VANILLA DOES THE SAME THING. Blueprints are drawn oversized in the 16px
--  inventory slot rather than fitted to it.
--
--  IT DOES NOT CHANGE ANYTHING THAT WAS ALREADY SCALING. An icon past the
--  tolerance is still fitted to BUBBLE_ICON_PX and not to the tolerance, so a
--  generated weapon lands at exactly the 16 it landed at before and the padding
--  tuned against it is untouched. Only the 17-to-18 band behaves differently,
--  and the one thing in it is the blueprint.
--
--  2 AND NOT MORE. This is the gap, in full. A wider tolerance would start
--  overlapping neighbours rather than closing on them.
local BUBBLE_ICON_SLACK = 2

--  HOW BIG IS THIS ICON, IN PIXELS? Cached, because addBubble runs every frame
--  and a bubble that has not changed would otherwise cost three root.imageSize
--  calls a frame forever.
--
--  A FAILURE IS CACHED TOO, as false rather than nil, so an unmeasurable path
--  is not retried sixty times a second.
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

--  THE VISIBLE BOX OF AN ICON, IN PIXELS RELATIVE TO ITS OWN CENTRE.
--
--  MEASURING THE CANVAS WAS WRONG. root.imageSize reports the whole image
--  including transparent padding, so the plasma pistol's parts came back 5x16,
--  7x16 and 7x16 -- 16-tall canvases holding a gun nowhere near 16 tall -- and
--  the slot scale was decided by padding.
--
--  root.nonEmptyRegion IS WHAT THE INVENTORY USES to fit a drawable into its
--  own 16x16 slot. It returns the rectangle of the image that is not
--  transparent.
--
--  RELATIVE TO THE CENTRE, because the drawable is centred on its position.
--  Layers have different canvas sizes, so their visible boxes cannot be unioned
--  until they share an origin -- which is why imageSize is still needed.
--
--  FALLS BACK TO THE FULL CANVAS. An image that is entirely transparent, or a
--  binding that will not answer, gives the old behaviour rather than nothing.
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

	--  THE REGION IS LOGGED BESIDE THE SIZE because whether nonEmptyRegion
	--  counts rows from the bottom or the top is unverified, and that decides
	--  the sign of the vertical centring. Art sitting low in its canvas is what
	--  would expose it.
	sb.logInfo("PETPORTS bubble %s canvas %sx%s visible %s",
		tostring(path), tostring(w), tostring(h),
		(ok and type(region) == "table") and sb.printJson(region) or "unavailable")

	return box
end

--  MEASURE A SLOT'S ICON AND PLACE ITS LAYERS.
--
--  Takes a path string or a list of { image, position } layers -- see
--  petports_bubbleItemIcon. Returns a list of { image, x, y } in TILES relative
--  to the slot centre, already scaled, or nil if nothing could be measured.
--
--  THE UNION BOX SETS THE SCALE. A composite is laid out left to right from
--  zero by buildweapon.lua, so scaling from any single layer would push the
--  assembly out of its slot even where every piece fits on its own -- and the
--  assembly is not centred on its origin either, so the box is what centres it.
--
--  POSITIONS ARE PIXELS AND CENTRE-RELATIVE, straight out of
--  partImagePositions. A layer spans px +/- w/2, and nil means the origin --
--  which is what a generated melee weapon gets, because partImagePositions is
--  only filled for gunParts.
--
--  AN UNMEASURABLE LAYER IS ASSUMED SLOT-SIZED rather than dropped. Dropping it
--  would silently change what the icon shows; a wrong size is visible.
local function layoutIcon(icon)
	local layers = icon
	if type(icon) == "string" then layers = { { image = icon } } end
	if type(layers) ~= "table" then return nil end

	local placed = {}
	local minX, minY, maxX, maxY

	for _, layer in ipairs(layers) do
		local image = type(layer) == "table" and layer.image or layer

		if type(image) == "string" then
			--  THE VISIBLE BOX, NOT THE CANVAS. See iconBox: padding decided the
			--  scale before this, so a gun in a 16-tall sheet was shrunk to fit
			--  transparency.
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

	--  THE ASSEMBLED RESULT, ONCE PER DISTINCT ICON.
	--
	--  A composite that comes out spread across its slot is unreadable on
	--  screen and says nothing about WHY. These are the four numbers that
	--  decide it -- the span, the scale, and each layer's measured size against
	--  its authored position. A layer that could not be measured is assumed
	--  slot-sized, which inflates the span and pushes everything else apart, so
	--  it shows up here as a suspiciously round 16x16.
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
			--  ONE DRAWABLE PER LAYER, ALL SHARING THE SLOT'S SCALE. A plain
			--  path is a one-layer icon, so it takes exactly this path too and
			--  there is no second code route to keep in step.
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

					--  CENTRED BY THE DRAWABLE, SCALED BY THE MATRIX. Putting
					--  the centring in the matrix as well moved every icon a
					--  half-image down and to the left -- measured 2026-09-07.
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

--------------------------------------------------------------------------------
--  MINING BEAMS
--------------------------------------------------------------------------------
--
--  DRAWN ON THE PLAYER, NOT ON THE UNIT, for the reason arch.bubble.rendering
--  already records: a monster has no client-side script context to draw from,
--  so anything that appears over a unit is drawn here and positioned relative
--  to the player.
--
--  THE RELOCATOR'S BEAM DOES NOT TRANSFER, AND THAT IS WHY THIS EXISTS.
--  relocate.lua ends at activeItem.setScriptedAnimationParameter("chains"),
--  consumed by /items/active/effects/chain.lua listed under the item's
--  animationScripts. Both halves are activeitem-only: a monster has no
--  activeItem table and a monstertype has no animationScripts field. What
--  transfers is the GEOMETRY, which is what is reimplemented below.
--
--  WHAT WAS DELIBERATELY LEFT OUT OF THE PORT: testCollision and bounces (a
--  mining beam cuts through, which is the whole convention), arcRadius (we are
--  drawing a straight line), and drawPercentage (the beam appears at full
--  length and fades rather than extending).
--
--  ONE MESSAGE PER MINE, NOT PER FRAME. The endpoint is a FIXED TILE and the
--  swing train is deterministic, so the unit says "beaming at this tile, this
--  many swings, this period, from now" exactly once and this side runs the
--  whole animation off its own clock. No heartbeat, and the entry SELF-EXPIRES
--  at swings * period -- so a unit that dies or is retired mid-beam leaves no
--  orphan drawable on anybody's screen.

--  Straight out of the art. 4px wide at 8 pixels per tile is half a tile; 0.48
--  overlaps each segment slightly so no seam shows at an angle.
local BEAM_BODY = "/monsters/lofty_petports/shared/beam/beam.png"
local BEAM_END  = "/monsters/lofty_petports/shared/beam/beamend.png"
local BEAM_SEGMENT = 0.48
local BEAM_OVERDRAW = 0.2

--  THE SPRITES ARE GREYSCALE AT FULL ALPHA so one ?multiply= directive carries
--  both the colour and the fade. White leaves the art as drawn; asterite's own
--  gold is "e3aa00" if the beam should read as the ore rather than as petports
--  equipment.
local BEAM_TINT = "ffffff"

--  A SWING'S WORTH OF FADE: nothing, to full, to nothing, once per period.
--  sin over half a cycle is exactly that shape and needs no easing table.
local BEAM_WAVE_FREQ = 3.0
local BEAM_WAVE_AMP = 0.12
local BEAM_WAVE_MOVE = 6.0

--  THERE IS NO BEAM DRAW RANGE, AND TWO ATTEMPTS AT ONE IS WHY.
--
--  The first copied BUBBLE_DRAW_RANGE's 25, which that constant's own header
--  calls "an earshot, not a view frustum" -- it decides whether the player is
--  close enough to be SPOKEN TO. A beam is not the unit talking; it is a thing
--  happening in the world. Measured 2026-09-11, five mines in one session with
--  the player at the port: 24.18, 24.51, 7.13 and 7.13 drew, and 26.60 did
--  not, which is how that got found.
--
--  The second widened it to 60 and culled on the NEARER of the two endpoints,
--  because a beam is a line and testing the unit alone is wrong by up to the
--  unit's whole reach in both directions.
--
--  BOTH WERE ANSWERING A QUESTION THE RENDERER ALREADY ANSWERS. Off-screen
--  drawables are culled by the engine, exactly, every frame, with the real
--  viewport -- which no number here can know, because it changes with zoom and
--  window size. A hand-rolled approximation of that can only ever be too tight
--  (a missing beam) or too loose (no saving), and the first one is a bug.
--
--  THE WORK WAS NEVER UNBOUNDED, WHICH IS WHAT THE GUARD WAS FOR.
--  self.petportsBeams holds an entry only while a unit is actually mining, for
--  one second each, and a unit on another world fails world.entityExists below
--  and is dropped. The ceiling is "units mining simultaneously", which is the
--  fleet size, not the world.
--
--  WHAT IS KEPT IS CLEANUP, NOT CULLING: the expiry and existence tests below
--  remove entries that should not exist at all, which is a different job from
--  deciding whether something visible is worth drawing. BEAM_SEGMENT_CAP stays
--  for the same reason -- it guards against a malformed message, not distance.


--  HOW MANY SEGMENTS ONE BEAM MAY DRAW. At 0.48 a tile, the unit's maximum
--  reach of 8 tiles is about 17 -- so this is a guard against a malformed
--  message rather than a budget, and it is what stops a bad endpoint from
--  asking for ten thousand drawables.
local BEAM_SEGMENT_CAP = 32

local function beamsToDraw(origin)
	local out = {}
	if self.petportsBeams == nil then return out end

	local now = self.petportsBeamClock or 0

	for id, beam in pairs(self.petportsBeams) do
		--  SELF-EXPIRING, AND CHECKED BEFORE EXISTENCE. A beam whose time is up
		--  goes whether or not its unit is still alive, which is what makes the
		--  unit side able to send once and forget.
		if type(beam) ~= "table" or now >= (beam.endsAt or 0) then
			self.petportsBeams[id] = nil
		elseif not world.entityExists(id) then
			self.petportsBeams[id] = nil
		else
			local pos = world.entityPosition(id)

			if pos ~= nil then
				--  THE START IS THE UNIT, LIVE. It may drift a little while it
				--  mines, and a beam anchored to where it stood when the
				--  message arrived would detach.
				--
				--  world.distance AND NOT PLAIN SUBTRACTION, both ends. Worlds
				--  wrap, and two points either side of the seam are adjacent
				--  in the world and very far apart in arithmetic -- which
				--  would draw a beam straight across the map.
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

	--  WHERE WE ARE INSIDE THE CURRENT SWING, 0 to 1. sin over that is the
	--  fade: 0 at the start, 1 at the middle, 0 at the end.
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

	--  MIRRORED RATHER THAN ROTATED PAST VERTICAL, which is chain.lua's own
	--  handling: a sprite rotated more than a right angle reads upside down,
	--  so a leftward beam is drawn mirrored at the reflected angle instead.
	local leftward = dx < 0

	--  math.atan2 DOES NOT EXIST IN THIS LUA. Measured 2026-09-11, as a hard
	--  error out of a player script:
	--
	--      attempt to call a nil value (field 'atan2')
	--
	--  math.atan is not used anywhere in this mod either, so it is not assumed
	--  to be there. acos IS used, and gives the same answer: acos of the
	--  normalised x component is the angle from the positive x axis over 0 to
	--  pi, and the sign of dy picks the half.
	--
	--  CLAMPED, because dx/length can land a hair outside -1..1 on float error
	--  and acos of 1.0000001 is nan -- which propagates silently into a
	--  rotation and draws nothing rather than erroring.
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

		--  THE WAVEFORM IS PERPENDICULAR TO THE BEAM, so it is applied as an
		--  offset in local space and then rotated with the segment -- the same
		--  order chain.lua uses. Applied in world space it would wobble
		--  vertically regardless of which way the beam pointed.
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

	--  CHAT BUBBLES. Keyed by unit entity id; the value is the icon path list,
	--  or nil to take the bubble down.
	--
	--  Registered here rather than at file scope because message.setHandler
	--  wants a live script context, and init is the only place this script is
	--  guaranteed to have one.
	self.petportsBubbles = {}

	--  THE ENABLED FLAG IS TRACKED, NOT FILTERED ON ARRIVAL.
	--
	--  A unit with bubbles switched off still tells us what it would have said,
	--  and we keep it. That is what makes the pane checkbox feel instant: the
	--  state for every unit in the world is already here, so ticking the box
	--  repaints on the next frame instead of waiting for that unit's next
	--  content change.
	--
	--  `~= false` so a message from a unit running an older script -- no fifth
	--  argument at all -- reads as enabled rather than silently going dark.
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

	--  MINING BEAMS. One message per mine; see the beam block above.
	--
	--  THE CLOCK IS OURS, NOT THE SENDER'S. Nothing here can read the unit's
	--  time base, and os.clock is process time rather than game time -- so the
	--  beam is anchored to this script's own dt accumulator, which starts
	--  whenever this client did and is monotonic. Network latency shifts the
	--  start by a frame or two and nothing else depends on it.
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

	--  THE PROBE MOVED ABOVE THE EARLY RETURN. Bubbles draw whether or not a
	--  port is held, so the render layer has to be known in either case.
	if not self.petportsOverlayProbed then
		self.petportsOverlayProbed = true
		probeRenderLayer()
	end

	--  ADVANCED BEFORE ANYTHING READS IT, and unconditionally -- a beam that
	--  started while the player was out of range must still expire on time.
	self.petportsBeamClock = (self.petportsBeamClock or 0) + dt

	local origin = entity.position()
	local wantCoverage = holdingPetport()
	local bubbles = bubblesToDraw(origin)
	local beams = beamsToDraw(origin)

	if not wantCoverage and #bubbles == 0 and #beams == 0 then
		--  CLEARED ONCE ON THE FALLING EDGE, NOT EVERY TICK.
		--
		--  clearDrawables wipes the WHOLE list on the player's animator, which
		--  is shared with anything else in this context that draws. We cannot
		--  avoid clobbering a co-tenant while we are drawing, but we can avoid
		--  clobbering it for the play where we have nothing to say.
		--
		--  THE CONDITION IS NOW "NOTHING TO DRAW" RATHER THAN "NO PORT HELD",
		--  because a bubble is a reason to keep drawing on its own.
		if self.petportsOverlayDrawing then
			localAnimator.clearDrawables()
			self.petportsOverlayDrawing = false
		end
		return
	end

	if wantCoverage then rebuildIfStale() end

	--  Drawables are retained between script ticks -- documented -- so a script
	--  that adds without clearing grows its list without bound.
	localAnimator.clearDrawables()

	if wantCoverage and self.petportsOverlaySegments ~= nil then
		for _, segment in ipairs(self.petportsOverlaySegments) do
			addSegment(segment.a, segment.b, segment.colour, origin)
		end
	end

	--  BEAMS UNDER BUBBLES AND OVER THE HATCHING. A beam is a thing happening
	--  in the world; a bubble is the unit talking about it, and the talking
	--  should never be hidden behind the doing.
	--
	--  WRAPPED, AND THE BLAST RADIUS IS WHY. This script's update runs inside a
	--  chain of other mods' player-script wrappers -- the atan2 traceback went
	--  through arcana, starforge, thea, neki and nebs-snails before it reached
	--  us -- so an exception here does not just lose a beam, it takes every
	--  one of those down for that frame. A beam is scenery and is already
	--  logged-and-swallowed on the unit side; this is the same rule applied
	--  where it matters most.
	--
	--  CHANGE-GATED, or a fault that fires every frame is sixty lines a second.
	--  NOT SILENT: a broken beam still says so, once, with its reason.
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

	--  BUBBLES LAST, so they sit over the coverage hatching rather than under
	--  it when both are up.
	for _, entry in ipairs(bubbles) do
		addBubble(entry)
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
