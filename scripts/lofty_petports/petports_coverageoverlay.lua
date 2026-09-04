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
--  THREE THINGS ARE DRAWN, AND THEY ANSWER DIFFERENT QUESTIONS:
--
--    OUTLINE     the boundary of each network. Where does coverage end.
--    HATCH       a crosshatch across the interior. AM I INSIDE ONE AT ALL --
--                on a large network the nearest edge is off screen, and an
--                outline alone means the overlay looks broken from the middle
--                of the base it is describing.
--    TENTATIVE   where the held port would land, tinted by what it would JOIN.
--
--  DRAWABLES ARE RELATIVE TO THE PLAYER, MEASURED 2026-09-04. See
--  fact.port.drawablespace. Every world coordinate here is translated by
--  -entity.position() at the moment it is handed to localAnimator, and that
--  translation happens in EXACTLY ONE PLACE, in addSegment.

require "/scripts/lofty_petports/petports_work.lua"

local PETPORTS_OVERLAY_BUILD_STAMP = "2026-09-04c tentative rect names its refusal"

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

--  The parameter the object authors its reach under. Spelled here and in
--  petports_petport.object and nowhere else.
local COVERAGE_SIZE_PARAMETER = "petports_coverageSize"

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
local OVERLAY_SEGMENT_BUDGET = 700

--  Segments shorter than this are dropped. Floating point rect arithmetic
--  leaves zero-length slivers where two edges are collinear, and a zero-length
--  line drawable is a wasted drawable at best.
local OVERLAY_EPSILON = 0.01

--  THE TENTATIVE RECT, TINTED BY CONSEQUENCE.
--
--  Neutral when the port would stand alone. The joined network's own colour
--  when it would be absorbed by exactly one -- so the box literally turns the
--  colour of the thing it is about to become part of. And a loud separate
--  colour when it touches TWO OR MORE, because that is a MERGE, it is the one
--  outcome a player can regret, and it is invisible without this.
local OVERLAY_TENTATIVE_ALONE = { 220, 220, 220, 200 }
local OVERLAY_TENTATIVE_BRIDGE = { 255, 80, 80, 240 }
local OVERLAY_TENTATIVE_WIDTH = 2

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

--  Returns a DESCRIPTOR, not a boolean, because the tentative rect needs to ask
--  the held item how far it reaches and a name alone cannot carry parameters.
local function heldPetport()
	if OVERLAY_ON_SWAP_SLOT and player.swapSlotItem ~= nil then
		local cursor = player.swapSlotItem()
		if cursor ~= nil and taggedPetport(cursor.name) then return cursor end
	end

	if OVERLAY_ON_HAND_ITEM then
		--  player.primaryHandItem RETURNS A DESCRIPTOR; world.entityHandItem
		--  returns a bare NAME. Both are vanilla and the first is strictly
		--  better here, because the tentative rect wants to ask the item about
		--  its parameters and a name cannot carry any.
		if player.primaryHandItem ~= nil then
			local hand = player.primaryHandItem()
			if hand ~= nil and taggedPetport(hand.name) then return hand end
		elseif world.entityHandItem ~= nil then
			local name = world.entityHandItem(entity.id(), "primary")
			if taggedPetport(name) then return { name = name, count = 1 } end
		end
	end

	return nil
end

--  How far the held port would reach.
--
--  RETURNS nil RATHER THAN A DEFAULT WHEN IT CANNOT TELL, and the caller draws
--  nothing. A tentative rect is a promise about where units will work; drawing
--  a guessed one is worse than drawing none, because the player has no way to
--  know it was a guess.
local function heldCoverageSize(descriptor)
	local ok, item = pcall(root.itemConfig, descriptor)

	--  THE SHAPE IS LOGGED ONCE, NOT ASSUMED. root.itemConfig on an OBJECT item
	--  is the uncertain part of this whole path -- an object's item form is
	--  generated rather than authored, and whether the .object's own keys
	--  survive into `config` is not something the docs say. One line in the log
	--  settles it; a nil return with no line settles nothing.
	if not self.petportsOverlayConfigLogged then
		self.petportsOverlayConfigLogged = true
		if not ok then
			sb.logInfo("PETPORTS overlay itemConfig(%s) THREW: %s",
				tostring(descriptor.name), tostring(item))
		elseif item == nil then
			sb.logInfo("PETPORTS overlay itemConfig(%s) returned nil",
				tostring(descriptor.name))
		else
			local keys = {}
			for key, _ in pairs(item) do table.insert(keys, key) end
			table.sort(keys)
			sb.logInfo("PETPORTS overlay itemConfig(%s) top-level keys: %s",
				tostring(descriptor.name), table.concat(keys, " "))
			sb.logInfo("PETPORTS overlay itemConfig(%s) %s: config %s, parameters %s",
				tostring(descriptor.name), COVERAGE_SIZE_PARAMETER,
				sb.printJson(item.config ~= nil
					and item.config[COVERAGE_SIZE_PARAMETER] or nil),
				sb.printJson(item.parameters ~= nil
					and item.parameters[COVERAGE_SIZE_PARAMETER] or nil))
		end
	end

	if not ok or item == nil then return nil end

	--  PARAMETERS BEAT CONFIG, matching how every other item parameter in this
	--  mod resolves.
	local size = nil
	if item.parameters ~= nil then size = item.parameters[COVERAGE_SIZE_PARAMETER] end
	if size == nil and item.config ~= nil then size = item.config[COVERAGE_SIZE_PARAMETER] end

	if type(size) ~= "number" or size <= 0 then return nil end
	return size
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

local function allNetworks()
	local ports = petports_registry().ports or {}
	local ids = sortedPortIds(ports)

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
			local members = {}
			for _, memberId in ipairs(group) do
				table.insert(rects, ports[memberId].rect)
				table.insert(members, ports[memberId])
			end

			--  THE KEY IS THE FIRST MEMBER, not the network id. Stable while
			--  membership is, and it CHANGES WHEN TWO NETWORKS MERGE -- which
			--  is a colour change the player wants to see, not a glitch.
			table.insert(networks, { key = group[1], rects = rects, members = members })
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
--
--  The geometry depends on the REGISTRY ONLY, and the registry publishes a
--  version counter precisely so a reader can notice a change without diffing
--  the structure. Rebuilt when that moves and not otherwise; the per-frame cost
--  is then a property read, the tentative rect, and a translate.

local function rebuildIfStale()
	local registry = petports_registry()
	local version = registry.version or 0

	if self.petportsOverlayVersion == version
	   and self.petportsOverlaySegments ~= nil then
		return
	end

	self.petportsOverlayVersion = version
	self.petportsOverlayNetworks = allNetworks()

	local outline = {}
	local hatch = {}

	for _, network in ipairs(self.petportsOverlayNetworks) do
		local edgeColour = colourFor(network.key, OVERLAY_OUTLINE_ALPHA)
		local fillColour = colourFor(network.key, OVERLAY_HATCH_ALPHA)

		for _, segment in ipairs(outlineSegments(network.rects)) do
			table.insert(outline,
				{ a = segment[1], b = segment[2], colour = edgeColour, width = OVERLAY_WIDTH })
		end

		local lines = hatchSegments(network.rects, OVERLAY_HATCH_SPACING, false)
		if OVERLAY_HATCH_CROSS then
			for _, segment in ipairs(hatchSegments(network.rects, OVERLAY_HATCH_SPACING, true)) do
				table.insert(lines, segment)
			end
		end

		for _, segment in ipairs(lines) do
			table.insert(hatch,
				{ a = segment[1], b = segment[2], colour = fillColour, width = OVERLAY_WIDTH })
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

	sb.logInfo("PETPORTS overlay rebuilt at version %s: %s networks, %s outline, %s hatch %s",
		sb.printJson(version), sb.printJson(#self.petportsOverlayNetworks),
		sb.printJson(#outline), sb.printJson(#hatch),
		dropped and "(HATCH DROPPED, over budget)" or "")
end

--------------------------------------------------------------------------------
--  THE TENTATIVE RECT
--------------------------------------------------------------------------------
--
--  Where the held port would land, and -- the part that matters -- WHAT IT
--  WOULD JOIN. Recomputed every frame rather than cached, because it follows
--  the cursor and nothing else does.
--
--  THE CENTRE IS DERIVED FROM THE AIM POSITION AND THAT MAPPING IS UNVERIFIED.
--  arch.port.coverage flagged it and it is still flagged: a placed port centres
--  its rect on entity.position(), which is its occupied tile, and the floor of
--  the aim position is only an assumption about where the placement cursor
--  actually commits. The derived centre is LOGGED on change so it can be read
--  straight off against the rect the port publishes once it goes down.

--  EVERY REFUSAL BELOW NAMES ITSELF, AND THE FIRST BUILD OF THIS DID NOT.
--
--  It bailed to nil on three separate conditions -- no binding, no size, no aim
--  -- with no log on any of them, so "the tentative rect is not applying" could
--  not be told from "the aim binding is wrong". That is exactly
--  fact.tooling.mergedrefusal, in a function whose own comment cited it.
--
--  Each cause is logged ONCE, on change, so a permanent failure does not spam
--  and a transient one is still visible.
local function refuse(cause)
	if self.petportsOverlayRefusal ~= cause then
		self.petportsOverlayRefusal = cause
		sb.logInfo("PETPORTS overlay tentative rect refused: %s", cause)
	end
	return nil
end

--  WHERE THE PLAYER IS AIMING, ASKED FOUR WAYS.
--
--  world.entityAimPosition is documented for tool-user entities and a player is
--  one, so it SHOULD be the answer -- but it is reached here through world,
--  aimed at ourselves, from a context that is neither the aiming entity's tool
--  user nor an active item, and it did not produce a rect on the first build.
--
--  Rather than swap one guess for another, every candidate is called once and
--  the whole table is logged. The first that returns a two-element vector wins
--  and is remembered; the log says which, and says what the others did.
--
--  player.aimPosition is not in vanilla's player table. It is here because
--  OpenStarbound and its forks add it and cost nothing to ask.
local function aimCandidates()
	return {
		{
			name = "player.aimPosition",
			call = function()
				if player.aimPosition == nil then return nil, "absent" end
				return player.aimPosition()
			end
		},
		{
			name = "world.entityAimPosition",
			call = function()
				if world.entityAimPosition == nil then return nil, "absent" end
				return world.entityAimPosition(entity.id())
			end
		},
		{
			name = "mcontroller.aimPosition",
			call = function()
				if mcontroller == nil then return nil, "no mcontroller" end
				if mcontroller.aimPosition == nil then return nil, "absent" end
				return mcontroller.aimPosition()
			end
		},
		{
			name = "entity.aimPosition",
			call = function()
				if entity.aimPosition == nil then return nil, "absent" end
				return entity.aimPosition()
			end
		}
	}
end

local function looksLikeVector(value)
	return type(value) == "table"
	   and type(value[1]) == "number" and type(value[2]) == "number"
end

local function resolveAim()
	--  A source that worked once keeps working; no reason to re-probe.
	if self.petportsOverlayAimSource ~= nil then
		local ok, aim = pcall(self.petportsOverlayAimSource.call)
		if ok and looksLikeVector(aim) then return aim end

		--  It stopped answering. Forget it and fall through to a fresh probe
		--  rather than silently going dark.
		sb.logInfo("PETPORTS overlay aim source %s stopped answering, re-probing",
			self.petportsOverlayAimSource.name)
		self.petportsOverlayAimSource = nil
		self.petportsOverlayAimProbed = false
	end

	local chosen = nil
	local report = {}

	for _, candidate in ipairs(aimCandidates()) do
		local ok, aim, why = pcall(candidate.call)

		local verdict
		if not ok then
			verdict = "threw: " .. tostring(aim)
		elseif aim == nil then
			verdict = why or "nil"
		elseif not looksLikeVector(aim) then
			verdict = "not a vector: " .. sb.printJson(aim)
		else
			verdict = sb.printJson(aim)
			if chosen == nil then chosen = { candidate = candidate, aim = aim } end
		end

		table.insert(report, candidate.name .. " -> " .. verdict)
	end

	if not self.petportsOverlayAimProbed then
		self.petportsOverlayAimProbed = true
		for _, line in ipairs(report) do
			sb.logInfo("PETPORTS overlay aim probe: %s", line)
		end
		sb.logInfo("PETPORTS overlay aim probe: also present -- %s %s %s",
			mcontroller ~= nil and "mcontroller" or "no-mcontroller",
			activeItem ~= nil and "activeItem" or "no-activeItem",
			status ~= nil and "status" or "no-status")
	end

	if chosen == nil then return nil end

	self.petportsOverlayAimSource = chosen.candidate
	sb.logInfo("PETPORTS overlay aim source: %s", chosen.candidate.name)
	return chosen.aim
end

local function tentativeRect(descriptor)
	local size = heldCoverageSize(descriptor)
	if size == nil then
		return refuse("root.itemConfig gave no " .. COVERAGE_SIZE_PARAMETER
			.. " for " .. tostring(descriptor.name))
	end

	local aim = resolveAim()
	if aim == nil then return refuse("no aim source answered") end

	self.petportsOverlayRefusal = nil

	local centre = { math.floor(aim[1]), math.floor(aim[2]) }

	if self.petportsOverlayLastCentre == nil
	   or self.petportsOverlayLastCentre[1] ~= centre[1]
	   or self.petportsOverlayLastCentre[2] ~= centre[2] then
		self.petportsOverlayLastCentre = centre
		sb.logInfo("PETPORTS overlay tentative centre %s from aim %s, size %s",
			sb.printJson(centre), sb.printJson(aim), sb.printJson(size))
	end

	return petports_coverageRect(centre, size)
end

--  Which existing networks this rect would be absorbed into.
--
--  A HELD PORT IS AN UNCONFIGURED ONE: participate true, id 0, matching the
--  defaults petports_petport.lua reads when the object has no saved settings.
--  Compatibility therefore reduces to "does the neighbour participate", but it
--  is asked through petports_entriesCompatible anyway so that a change to the
--  rule reaches here too.
local function joinedNetworks(rect)
	local fresh = { participate = true, id = 0 }
	local joined = {}

	for _, network in ipairs(self.petportsOverlayNetworks or {}) do
		for index, member in ipairs(network.members) do
			if petports_entriesCompatible(fresh, member)
			   and petports_rectsAdjacent(rect, network.rects[index]) then
				table.insert(joined, network)
				break
			end
		end
	end

	return joined
end

--------------------------------------------------------------------------------
--  DRAWING
--------------------------------------------------------------------------------

--  THE ONE PLACE WORLD COORDINATES BECOME DRAWABLE COORDINATES.
local function addSegment(a, b, colour, width, origin)
	local drawable = {
		line = {
			{ a[1] - origin[1], a[2] - origin[2] },
			{ b[1] - origin[1], b[2] - origin[2] }
		},
		width = width,
		color = colour,
		fullbright = true
	}

	if self.petportsOverlayLayer ~= nil then
		localAnimator.addDrawable(drawable, self.petportsOverlayLayer)
	else
		localAnimator.addDrawable(drawable)
	end
end

local function drawTentative(rect, origin)
	local joined = joinedNetworks(rect)

	local colour
	if #joined == 0 then
		colour = OVERLAY_TENTATIVE_ALONE
	elseif #joined == 1 then
		colour = colourFor(joined[1].key, OVERLAY_TENTATIVE_ALONE[4])
	else
		colour = OVERLAY_TENTATIVE_BRIDGE
	end

	--  DRAWN WHOLE, NOT UNIONED WITH WHAT IS ALREADY THERE. This box is a
	--  question about ONE port -- "how far would this reach" -- and clipping it
	--  against its future neighbours would answer a different one.
	local corners = {
		{ { rect[1], rect[2] }, { rect[3], rect[2] } },
		{ { rect[3], rect[2] }, { rect[3], rect[4] } },
		{ { rect[3], rect[4] }, { rect[1], rect[4] } },
		{ { rect[1], rect[4] }, { rect[1], rect[2] } }
	}

	for _, edge in ipairs(corners) do
		addSegment(edge[1], edge[2], colour, OVERLAY_TENTATIVE_WIDTH, origin)
	end
end

--  ONE-TIME RENDER LAYER PROBE.
--
--  fact.art.renderlayerkey: an unknown render layer key is a hard failure, not
--  a fallback, and the overlay wants to sit above foreground tiles rather than
--  be buried by them. Asked once with a degenerate transparent drawable; if the
--  key is refused we fall back to the player's own layer, which is worse
--  looking and still works.
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
	self.petportsOverlaySegments = nil
	self.petportsOverlayNetworks = nil
	self.petportsOverlayLayer = nil
	self.petportsOverlayLastCentre = nil
	self.petportsOverlayRefusal = nil
	self.petportsOverlayAimSource = nil
	self.petportsOverlayAimProbed = false
	self.petportsOverlayConfigLogged = false
	self.petportsOverlayProbed = false
	self.petportsOverlayDrawing = false

	sb.logInfo("PETPORTS overlay build: %s", PETPORTS_OVERLAY_BUILD_STAMP)
end

function update(dt)
	if petports_overlay_originalUpdate then petports_overlay_originalUpdate(dt) end

	if localAnimator == nil then return end

	local held = heldPetport()

	if held == nil then
		--  CLEARED ONCE ON THE FALLING EDGE, NOT EVERY TICK.
		--
		--  clearDrawables wipes the WHOLE list on the player's animator, which
		--  is shared with anything else in this context that draws. We cannot
		--  avoid clobbering a co-tenant while the overlay is up, but we can
		--  avoid clobbering it for the 99% of play where no port is held.
		if self.petportsOverlayDrawing then
			localAnimator.clearDrawables()
			self.petportsOverlayDrawing = false
			self.petportsOverlayLastCentre = nil
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
		addSegment(segment.a, segment.b, segment.colour, segment.width, origin)
	end

	--  LAST, SO IT SITS ON TOP OF THE HATCH IT OVERLAPS.
	local tentative = tentativeRect(held)
	if tentative ~= nil then drawTentative(tentative, origin) end

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
