--  PETPORTS -- CAN THIS CHASSIS LIVE AT THIS PORT?
--
--  Shared by the petport (object script) and the unit (monster script list),
--  the same way petports_work.lua is. PREFIXED FUNCTIONS ONLY -- a monster's
--  scripts share one Lua environment, and a second definition of init/update/
--  uninit silently replaces groundPet.lua's.
--
--  WHY THIS FILE EXISTS. The ladder below used to live only in
--  petports_contract.lua, on the unit, because the reasoning was that
--  capability is a monstertype parameter and only the unit has read it. That
--  was true of the ENTITY and never true of the TYPE: root.monsterParameters
--  answers the same questions from the object side, and the port already calls
--  it twice for other reasons.
--
--  The consequence of leaving it there was that the port could not know the
--  answer until AFTER it had spawned something to ask. It opened its door,
--  materialised a unit, waited up to ENVIRONMENT_INTERVAL, dematerialised it
--  and closed the door again -- a full choreographed sequence ending in
--  nothing, on a loop. That was acceptable when a spawn was a one-frame pop.
--
--  SO THERE ARE NOW TWO CALLERS ASKING THE SAME QUESTION, and this file is
--  what stops them being two programs that merely happen to agree today. The
--  ORDER of the ladder is the logic -- forbidden liquid before capability,
--  free mover before walker -- and an order written twice drifts. The upcycler
--  learned this four times in two days; see petports_upcyclerstate.lua.
--
--  IT DECIDES ON A CAUSE, and the sentence is a separate lookup underneath.
--  Callers that only need to branch read `cause`; callers that need to speak
--  call petports_habitatReason. The petport's PANE wording is deliberately not
--  here, because it has two variants this file cannot distinguish -- a unit
--  that was retired and a unit that was never spawned.
--
--  THE TWO CAPABILITY SOURCES ARE NOT INTERCHANGEABLE, AND THAT IS DELIBERATE.
--  petports_habitatCapabilitiesForType reads the TYPE and is what the port uses
--  before a unit exists. The unit builds its own from config and mcontroller.
--  Today they cannot disagree. When module-granted liquid permissions land they
--  will, and the divergence runs the right way: the type answer is the
--  conservative pre-check and the live unit refines it, so a module can only
--  ever ALLOW a spawn the type would have refused -- never retire one the type
--  would have allowed.

--  ---------------------------------------------------------------------------
--  CAUSES
--  ---------------------------------------------------------------------------

--  A CLOSED SET. Anything reading a cause must handle all of them, so they are
--  named here rather than spelled as literals at the call sites.
PETPORTS_HABITAT_SWIMS = "swims"
PETPORTS_HABITAT_FLIES = "flies"
PETPORTS_HABITAT_EITHER_MEDIUM = "eitherMedium"
PETPORTS_HABITAT_AMPHIBIOUS = "amphibious"
PETPORTS_HABITAT_DRY_FOOTING = "dryFooting"

PETPORTS_HABITAT_FORBIDDEN_LIQUID = "forbiddenLiquid"
PETPORTS_HABITAT_MIXED_MEDIUM = "mixedMedium"
PETPORTS_HABITAT_SUBMERGED_NO_SWIM = "submergedNoSwim"
PETPORTS_HABITAT_DRY_NO_FLY = "dryNoFly"
PETPORTS_HABITAT_NO_MEDIUM = "noMedium"
PETPORTS_HABITAT_SUBMERGED_WALKER = "submergedWalker"

--  THE SENTENCES ARE THE ONES THAT ALREADY SHIPPED, word for word. They appear
--  in the retirement log line, which is the one place a player is told why
--  their pet went away, and rewording them here would silently change what the
--  log says while looking like a refactor.
local REASONS =
{
	[PETPORTS_HABITAT_SWIMS] = "port is submerged and this chassis swims",
	[PETPORTS_HABITAT_FLIES] = "port is in air and this chassis flies",
	[PETPORTS_HABITAT_EITHER_MEDIUM] = "this chassis both flies and swims, so any footprint suits it",
	[PETPORTS_HABITAT_AMPHIBIOUS] = "amphibious walker, any medium",
	[PETPORTS_HABITAT_DRY_FOOTING] = "port has dry footing",

	[PETPORTS_HABITAT_FORBIDDEN_LIQUID] = "the port sits in a liquid this chassis will not enter",
	[PETPORTS_HABITAT_MIXED_MEDIUM] = "the port straddles a waterline, and this chassis needs all of it to be one medium",
	[PETPORTS_HABITAT_SUBMERGED_NO_SWIM] = "the port is fully submerged and this chassis cannot swim",
	[PETPORTS_HABITAT_DRY_NO_FLY] = "the port is out of the water and this chassis cannot leave it",
	[PETPORTS_HABITAT_NO_MEDIUM] = "this chassis can occupy neither medium the port offers",
	[PETPORTS_HABITAT_SUBMERGED_WALKER] = "the port is fully submerged and this walker will not stand in liquid"
}

--  THE SAME CAUSES, SAID ABOUT A TARGET INSTEAD OF A HOME.
--
--  A SECOND TABLE RATHER THAN A REWORDING, because the sentences above ship in
--  the retirement log -- the one place a player is told why their pet went away
--  -- and rewording them there would change what the log says while looking
--  like a refactor. The header on this file says so explicitly.
--
--  KEYED BY THE SAME CLOSED SET, so the ladder stays one ladder and a new cause
--  cannot be added to one vocabulary and forgotten in the other. A missing key
--  falls back to the cause name rather than to the port sentence, because
--  "the port sits in a liquid this chassis will not enter" printed about a crate
--  forty tiles away is worse than no sentence at all.
local TARGET_REASONS =
{
	[PETPORTS_HABITAT_FORBIDDEN_LIQUID] = "sits in a liquid this chassis will not enter",
	[PETPORTS_HABITAT_MIXED_MEDIUM] = "straddles a waterline, and this chassis needs all of it to be one medium",
	[PETPORTS_HABITAT_SUBMERGED_NO_SWIM] = "is submerged and this chassis cannot swim",
	[PETPORTS_HABITAT_DRY_NO_FLY] = "is out of the water and this chassis cannot leave it",
	[PETPORTS_HABITAT_NO_MEDIUM] = "offers neither medium this chassis can occupy",
	[PETPORTS_HABITAT_SUBMERGED_WALKER] = "is submerged and this walker will not stand in liquid"
}

--  The refusal sentence for a TARGET, phrased as a predicate so a caller can
--  write "crop 158 <reason>". Only refusal causes are listed; an accepting cause
--  reaching here is a caller bug and reads as one.
function petports_habitatTargetReason(cause)
	return TARGET_REASONS[cause] or ("is refused: " .. tostring(cause))
end

function petports_habitatReason(cause)
	return REASONS[cause] or "cannot inhabit this port"
end

--  ---------------------------------------------------------------------------
--  LIQUIDS
--  ---------------------------------------------------------------------------

--  RESOLVED BY NAME AND NOT BY ID, DELIBERATELY -- the reasoning is unchanged
--  from petports_contract.lua, which this replaces. Starbound has 255 liquid
--  slots and the numbering is not something to hardcode from memory; the one id
--  this mod has ever measured is 12 for swampwater, which matches no ordering
--  anyone would guess.
--
--  ENTRIES MATCH LOOSELY ON PURPOSE. A liquid's name and its itemDrop are not
--  the same string ("lava" versus "liquidlava"), and which one root.liquidConfig
--  exposes is not something to assume, so both are compared and a bare number is
--  accepted too for anyone working from the wiki table.
--
--  CACHED BY ID AND NOT BY CHASSIS. What a liquid is called is a property of
--  the liquid, so this cache is shared by every caller in the context and does
--  not have to be rebuilt when a different unit asks. The DENY-LIST is the
--  per-chassis part and is passed in.
--
--  PUBLIC, because the unit LOGS what a liquid resolved to. That line is the
--  whole reason a wrong deny-list entry is a one-cycle fix rather than a
--  mystery, and it cannot be written without the resolved list.
local liquidNameCache = {}

function petports_habitatLiquidNames(liquidId)
	local key = tostring(liquidId)
	if liquidNameCache[key] ~= nil then return liquidNameCache[key] end

	local resolved = {}
	local ok, liquid = pcall(root.liquidConfig, liquidId)

	if ok and type(liquid) == "table" then
		if liquid.name ~= nil then table.insert(resolved, string.lower(tostring(liquid.name))) end

		if type(liquid.config) == "table" then
			if liquid.config.name ~= nil then table.insert(resolved, string.lower(tostring(liquid.config.name))) end
			if liquid.config.itemDrop ~= nil then table.insert(resolved, string.lower(tostring(liquid.config.itemDrop))) end
		end
	end

	table.insert(resolved, string.lower(key))

	liquidNameCache[key] = resolved
	return resolved
end

--  `avoided` is a SET of lowercased names, as built by
--  petports_habitatAvoidedSet. A nil or empty set denies nothing, which is the
--  right default: a deny-list that failed to load must not strand every unit.
function petports_habitatLiquidDenied(avoided, liquidId)
	if liquidId == nil then return false end
	if avoided == nil or next(avoided) == nil then return false end

	for _, candidate in ipairs(petports_habitatLiquidNames(liquidId)) do
		if avoided[candidate] then return true end
	end

	return false
end

function petports_habitatAvoidedSet(list)
	local names = {}

	for _, entry in ipairs(list or {}) do
		names[string.lower(tostring(entry))] = true
	end

	return names
end

--  ---------------------------------------------------------------------------
--  CAPABILITIES, FROM A MONSTER TYPE
--  ---------------------------------------------------------------------------

--  WHAT THE PORT USES BEFORE A UNIT EXISTS. The unit builds the same table from
--  config.getParameter and mcontroller instead -- see petports_capabilities in
--  petports_contract.lua.
--
--  freeMover IS movementSettings.gravityEnabled, INVERTED. The unit asks
--  mcontroller.baseParameters().gravityEnabled, which is not reachable from an
--  object, but it is the same authored value: the two free-moving chassis set
--  it false explicitly and the two walkers omit it entirely, so ABSENT MUST
--  READ AS TRUE. Testing `== false` rather than `not x` is what makes a missing
--  key a walker instead of a flyer.
--
--  CHECKED AT BOTH LEVELS, for the same reason paneBodyKind and
--  animalHarvestable are: whether root.monsterParameters returns baseParameters
--  flattened or nested is not documented, and looking in both costs one index.
--
--  CACHED PER TYPE. These are authored constants; nothing can change them for
--  the life of the world. THE MODULE OVERLAY IS NOT CACHED WITH THEM -- see
--  petports_habitatCapabilitiesForType, which is the entry point callers use.
local capabilityCache = {}

--  The axis-aligned box a collision poly occupies, as {left, bottom, right, top}
--  relative to the body's position. Same layout mcontroller.boundBox() returns,
--  so the two are interchangeable at a call site.
--
--  nil FOR A MISSING OR MALFORMED POLY rather than a fabricated default. A box
--  invented here would be silently wrong in a way no log would show; a nil is a
--  caller's problem and says so.
local function polyBounds(poly)
	if type(poly) ~= "table" or #poly == 0 then return nil end

	local left, bottom, right, top = nil, nil, nil, nil

	for _, point in ipairs(poly) do
		if type(point) == "table" and #point >= 2 then
			local x, y = point[1], point[2]

			if left == nil or x < left then left = x end
			if right == nil or x > right then right = x end
			if bottom == nil or y < bottom then bottom = y end
			if top == nil or y > top then top = y end
		end
	end

	if left == nil then return nil end
	return { left, bottom, right, top }
end

local function typeCapabilities(monsterType)
	if monsterType == nil then return nil end

	local key = tostring(monsterType)
	if capabilityCache[key] ~= nil then return capabilityCache[key] end

	local ok, params = pcall(root.monsterParameters, key)
	if not ok or type(params) ~= "table" then return nil end

	local base = type(params.baseParameters) == "table" and params.baseParameters or {}

	local function read(name, fallback)
		local value = params[name]
		if value == nil then value = base[name] end
		if value == nil then return fallback end
		return value
	end

	local movement = read("movementSettings", {})
	if type(movement) ~= "table" then movement = {} end

	local caps =
	{
		freeMover = (movement.gravityEnabled == false),
		fly = read("petports_canFly", true),
		swim = read("petports_canSwim", false),
		avoidLiquid = read("petports_avoidLiquid", true),
		avoided = petports_habitatAvoidedSet(read("petports_avoidLiquids", {})),

		--  THE BODY BOX, DERIVED FROM THE AUTHORED POLY.
		--
		--  The unit reads mcontroller.boundBox(), which an object cannot call.
		--  movementSettings.collisionPoly is the same authored shape the engine
		--  builds that box from, so the AABB of the poly IS the box -- and it
		--  is readable through root.monsterParameters with no entity, which is
		--  the whole point: a chassis whose port is full of lava never spawns,
		--  and the port still needs to know how big it would have been.
		--
		--  CACHED WITH THE REST, and for the same reason: authored constants
		--  that cannot change for the life of the world.
		--
		--  NOTHING READS THIS YET. Object targets are sampled by their own
		--  world.objectSpaces and point targets by a single tile, so no caller
		--  needs a body box today. It is here because the alternative -- asking
		--  a live unit at spawn -- cannot answer for a unit that failed to
		--  spawn, which is exactly the case a port needs an answer in.
		bounds = polyBounds(movement.collisionPoly)
	}

	capabilityCache[key] = caps
	return caps
end

--  `permitted` IS A SET OF LIQUID NAMES A SOCKETED MODULE HAS UNLOCKED, as built
--  by petports_habitatPermittedSet. nil means no modules, which is the common
--  case and costs a table copy either way.
--
--  THE OVERLAY IS RECOMPUTED EVERY CALL AND THAT IS DELIBERATE. Folding it into
--  the cache would mean keying on the type AND the permission set, and a cache
--  keyed on one of the two is worse than no cache at all: two units of the same
--  chassis with different modules would each get whichever answer was computed
--  first, and the symptom is a module that does nothing until you re-socket it.
--  The type read is the expensive half and it stays cached; the overlay is a
--  walk of a set that is almost always empty and usually has one entry.
--
--  IT ONLY EVER SUBTRACTS. A module can remove a liquid from the avoid list and
--  cannot add one, so a broken or hostile module item can widen where a unit
--  will go but can never strand one by forbidding the water it lives in.
function petports_habitatCapabilitiesForType(monsterType, permitted)
	local caps = typeCapabilities(monsterType)
	if caps == nil then return nil end
	if permitted == nil or next(permitted) == nil then return caps end

	local avoided = {}
	for name in pairs(caps.avoided) do
		if not permitted[name] then avoided[name] = true end
	end

	return
	{
		freeMover = caps.freeMover,
		fly = caps.fly,
		swim = caps.swim,
		avoidLiquid = caps.avoidLiquid,
		avoided = avoided,
		bounds = caps.bounds
	}
end

--  THE SAME LOWERCASING AS petports_habitatAvoidedSet, and it has to be the
--  same, because these two sets are compared against each other by key. A
--  module naming "Poison" must cancel a chassis avoiding "poison".
function petports_habitatPermittedSet(list)
	return petports_habitatAvoidedSet(list)
end

--  ---------------------------------------------------------------------------
--  WHERE A CHASSIS TETHERS
--  ---------------------------------------------------------------------------

--  A CLOSED SET, for the same reason the causes above are one: anything reading
--  a tether location has to handle all of them, and a literal at a call site is
--  a value nobody can grep for.
--
--  WHAT THIS ANSWERS. `strictPortTethering` decides WHETHER a chassis comes home
--  and holds; this decides WHERE home is. They were one question while every
--  chassis walked -- home was "the floor under the port" and nothing else was
--  expressible -- and they stopped being one question the moment a chassis had
--  no use for a floor.
--
--  MEASURED 2026-08-31, and it is why this exists. `returnWork` resolved the
--  recall target with `findStandingPoint`, which requires a solid tile below the
--  candidate and picks its column with `math.random` across the coverage rect.
--  With the port at [2525,1145] and an AQUATIC unit in the water beneath it, six
--  recalls in four minutes aimed at
--
--      [2500.5,1163]  [2523.5,1158]  [2529.5,1158]
--      [2553.5,1174]  [2554.5,1174]  [2556.5,1175]
--
--  -- seabed and ledges, three of them thirty tiles away. Every one of those is
--  a VALID standing point and not one of them is where a swimmer lives.
--
--  PREFIXED, THOUGH ITS NEIGHBOUR IS NOT. `strictPortTethering` is vanilla's
--  parameter and keeps vanilla's name; this one is ours, so it takes the
--  petports_ prefix every other parameter this mod adds takes. A collision with
--  a future engine or mod parameter costs more than the longer name does.
PETPORTS_TETHER_PORT = "port"
PETPORTS_TETHER_FLOOR = "floor"
PETPORTS_TETHER_CEILING = "ceiling"

--  THE DEFAULT IS "floor" AND THAT IS NOT A PREFERENCE, IT IS THE BEHAVIOUR
--  EVERY CHASSIS ALREADY HAD. An absent parameter must mean "carry on as
--  before", so a monstertype that has not been touched -- including one from a
--  mod that has never heard of this field -- keeps the ground search it was
--  written against.
local DEFAULT_TETHER = PETPORTS_TETHER_FLOOR

local KNOWN_TETHERS =
{
	[PETPORTS_TETHER_PORT] = true,
	[PETPORTS_TETHER_FLOOR] = true,
	[PETPORTS_TETHER_CEILING] = true
}

--  WHERE DOES THIS MONSTER TYPE CONSIDER HOME? Read from the TYPE rather than
--  from a live unit, because the port asks this while deciding where to recall
--  something to and the answer must not depend on a unit existing.
--
--  AN UNRECOGNISED VALUE FALLS BACK AND SAYS SO. A typo in a monstertype would
--  otherwise silently become whatever the resolver's else-branch happens to do,
--  and the symptom -- a unit recalled somewhere odd -- is exactly the symptom
--  this field exists to fix, so it would read as the fix not working.
local tetherCache = {}

function petports_habitatTether(monsterType)
	if monsterType == nil then return DEFAULT_TETHER end

	local key = tostring(monsterType)
	if tetherCache[key] ~= nil then return tetherCache[key] end

	local ok, params = pcall(root.monsterParameters, key)
	local value = nil

	if ok and type(params) == "table" then
		--  BOTH SHAPES, EXACTLY AS typeCapabilities DOES, AND FOR THE SAME
		--  RECORDED REASON: whether root.monsterParameters returns baseParameters
		--  flattened or nested is not documented, and looking in both costs one
		--  index. Reading only the flat one here would have made this field
		--  silently absent on every chassis -- which does not fail, it just
		--  returns the default, so the symptom would have been "the fix did
		--  nothing" with no line anywhere saying why.
		value = params.petports_portTetheringLocationType

		if value == nil and type(params.baseParameters) == "table" then
			value = params.baseParameters.petports_portTetheringLocationType
		end
	end

	if value ~= nil and not KNOWN_TETHERS[value] then
		sb.logInfo("PETPORTS monster type %s declares petports_portTetheringLocationType %s, "
			.. "which is not one of port/floor/ceiling -- falling back to %s",
			key, tostring(value), DEFAULT_TETHER)
		value = nil
	end

	value = value or DEFAULT_TETHER
	tetherCache[key] = value
	return value
end

--  ---------------------------------------------------------------------------
--  THE LADDER
--  ---------------------------------------------------------------------------

--  `wet` and `dry` are "at least one tile of my footprint is like this", NOT
--  "all of them" -- so a port straddling a waterline reports BOTH.
--
--  A FREE MOVER NEEDS ALL OF IT TO BE ONE MEDIUM. The original reading was that
--  both being true was the right answer for both chassis, because a swimmer
--  could sit in the flooded half and a flyer in the dry half. Nothing ever chose
--  a half: spawnPet spawns at petSpawnOffset, [0,0], the middle of the
--  footprint. So the reasoning described a placement the code did not perform.
--  See the ladder itself for what replaced it.
--
--  A WALKER IS A DIFFERENT QUESTION AND MUST NOT BE ASKED THE FLYER ONE. Its
--  media flags default to canFly true / canSwim false, which would read as "air
--  only" and is meaningless -- a ground unit does not fly. What decides for a
--  walker is whether it will stand in liquid at all. It is also NOT subject to
--  the uniformity rule: gravity moves it to the floor of whatever it spawns in,
--  so a mixed footprint resolves itself.
--
--  RETURNS ONE TABLE, NOT TWO VALUES. Whether world.callScriptedEntity forwards
--  multiple return values across the boundary is not something this mod has
--  measured, and a nil is already indistinguishable from "the target does not
--  define that function" -- so a marshalling difference would look like a unit
--  that simply never answers. A table is unambiguous and costs nothing.
function petports_habitatVerdict(caps, wet, dry, liquids)
	--  A CAPABILITY TABLE THAT COULD NOT BE BUILT IS NOT A REFUSAL. nil here
	--  means root.monsterParameters gave nothing, which is a tooling or version
	--  problem and not a statement about the terrain. Failing closed on it would
	--  brick a port over a mistyped monster name; the caller decides what to do
	--  with the nil, and both current callers leave the port alone.
	if type(caps) ~= "table" then return nil end

	--  A LIQUID THIS CHASSIS REFUSES ANYWHERE IN THE FOOTPRINT IS DISQUALIFYING,
	--  regardless of how much dry footing the port also offers. A petport with
	--  one tile of lava in it is not a home for anything that avoids lava, and it
	--  is checked before capability because no capability answers it.
	for _, id in ipairs(liquids or {}) do
		if petports_habitatLiquidDenied(caps.avoided, id) then
			return { ok = false, cause = PETPORTS_HABITAT_FORBIDDEN_LIQUID }
		end
	end

	if caps.freeMover then
		--  A CHASSIS THAT DOES BOTH TAKES ANY FOOTPRINT, and it is tested first
		--  so the uniformity rule below never refuses one. None of the four
		--  chassis is both today; the ladder must not encode that.
		if caps.fly and caps.swim then
			return { ok = true, cause = PETPORTS_HABITAT_EITHER_MEDIUM }
		end

		--  "ONLY AIR", NOT "SOME AIR" -- AND THE MIRROR FOR WATER.
		--
		--  This used to ask whether the footprint offered a suitable medium
		--  ANYWHERE, on the reasoning that a port straddling a waterline offers a
		--  wet half to a swimmer and a dry half to a flyer, and neither has to be
		--  told which. NOBODY WAS EVER TOLD WHICH. spawnPet spawns at
		--  petSpawnOffset, which is [0,0] -- the middle of a 4x4 footprint -- so a
		--  half-flooded port materialised the flyer under its own waterline, into a
		--  closed node set it cannot path out of. Measured in game 2026-08-30.
		--
		--  UNIFORMITY IS THE CHEAP FIX AND IT IS THE RIGHT ONE HERE. Picking a
		--  suitable tile and spawning there would preserve the old intent, but it
		--  makes the verdict a position search and gives every caller a point to
		--  keep in step with. Refusing a mixed footprint costs a port that is
		--  fifteen-sixteenths dry and buys a rule with no gap in it.
		--
		--  THE THRESHOLD IS INHERITED, NOT CHOSEN. `wet` means a tile at or above
		--  ENVIRONMENT_SUBMERGED_FILL and `dry` is everything else, so a tile at
		--  0.85 fill still counts as dry and a flyer will accept it. That matches
		--  what the UNIT calls water -- PETPORTS_SUBMERGED_FILL is the same 0.9 --
		--  which is the property that matters: the two must not disagree.
		if caps.swim and wet and not dry then
			return { ok = true, cause = PETPORTS_HABITAT_SWIMS }
		end

		if caps.fly and dry and not wet then
			return { ok = true, cause = PETPORTS_HABITAT_FLIES }
		end

		--  MIXED IS ITS OWN CAUSE. Falling through to "neither medium" would be a
		--  lie about a port that offers a perfectly good one -- just not
		--  everywhere -- and it is the sentence a player needs to act on, because
		--  the fix is to finish draining or finish flooding.
		if wet and dry then
			return { ok = false, cause = PETPORTS_HABITAT_MIXED_MEDIUM }
		end

		if wet then
			return { ok = false, cause = PETPORTS_HABITAT_SUBMERGED_NO_SWIM }
		end

		if dry then
			return { ok = false, cause = PETPORTS_HABITAT_DRY_NO_FLY }
		end

		return { ok = false, cause = PETPORTS_HABITAT_NO_MEDIUM }
	end

	if not caps.avoidLiquid then
		return { ok = true, cause = PETPORTS_HABITAT_AMPHIBIOUS }
	end

	if dry then return { ok = true, cause = PETPORTS_HABITAT_DRY_FOOTING } end
	return { ok = false, cause = PETPORTS_HABITAT_SUBMERGED_WALKER }
end

--  ---------------------------------------------------------------------------
--  SAMPLING A PATCH OF WORLD
--  ---------------------------------------------------------------------------

--  WHAT COUNTS AS SUBMERGED, FOR EVERY CALLER OF THIS FILE.
--
--  This number exists three times in the mod and all three must agree, because
--  a port that calls a tile wet while the unit standing in it calls the same
--  tile dry produces a unit retired from a home it was perfectly happy in.
--  ENVIRONMENT_SUBMERGED_FILL in petports_petport.lua now reads this one;
--  PETPORTS_SUBMERGED_FILL in petports_contract.lua is still its own copy and
--  is deliberately left alone -- it is load-bearing for the pathing work closed
--  on 2026-08-31 and is not worth reopening for a constant that agrees.
PETPORTS_HABITAT_SUBMERGED_FILL = 0.9

--  Summarise a list of world points into the three arguments the verdict takes.
--
--  THE SHAPE petports_habitatVerdict ALREADY WANTED. The port has been building
--  this inline from world.objectSpaces since the environment gate landed; this
--  is that loop with the source of the points lifted out, so the gate and
--  dispatch eligibility cannot come to different conclusions about one tile.
--
--  `wet` AND `dry` ARE NOT COMPLEMENTS ACROSS A MULTI-TILE SAMPLE, and that is
--  the whole reason the verdict takes both: a footprint with some of each is
--  MIXED_MEDIUM, which is a refusal in its own right and not the absence of an
--  answer. Over a ONE-POINT sample they are complements and MIXED_MEDIUM is
--  unreachable, which is correct -- one tile cannot straddle anything.
--
--  AN EMPTY LIST READS AS DRY, matching what portMedia already returns for an
--  object with no spaces. Reporting neither medium instead would refuse every
--  chassis, which is the wrong direction to fail for a question about work.
--
--  ANY LIQUID AT ALL CONTRIBUTES ITS ID, not merely a submerging amount. The
--  verdict's forbidden check is a deny-list and a chassis that will not enter
--  lava will not enter a splash of it either -- see PETPORTS_HARMFUL_FILL in
--  petports_contract.lua, which draws the same line at 0.1 for the unit's own
--  movement.
function petports_habitatMedia(points)
	if points == nil or #points == 0 then return false, true, {} end

	local wet, dry = false, false
	local seen, liquids = {}, {}

	for _, point in ipairs(points) do
		local level = world.liquidAt(point)
		local fill = (level ~= nil) and (level[2] or 0) or 0

		if level ~= nil and level[1] ~= nil and fill > 0 and not seen[level[1]] then
			seen[level[1]] = true
			table.insert(liquids, level[1])
		end

		if fill >= PETPORTS_HABITAT_SUBMERGED_FILL then
			wet = true
		else
			dry = true
		end
	end

	return wet, dry, liquids
end

--  The tile centres an object occupies, in world coordinates.
--
--  world.objectSpaces IS AVAILABLE TO ANYTHING IN A WORLD CONTEXT and takes any
--  entity id, so this answers for a crop, a crate or a machine without caring
--  which. A non-object returns nothing, which is the caller's signal to fall
--  back to a point -- item drops and livestock take that path.
--
--  THE +0.5 AND THE math.floor ARE BOTH LOAD-BEARING. Spaces are integer tile
--  offsets from the object's tile origin, so the origin has to be floored before
--  they are added and the result has to be nudged to a tile centre before
--  world.liquidAt is asked about it. This is portMedia's arithmetic, unchanged.
function petports_habitatObjectPoints(entityId)
	if entityId == nil then return nil end

	local ok, spaces = pcall(world.objectSpaces, entityId)
	if not ok or type(spaces) ~= "table" or #spaces == 0 then return nil end

	local origin = world.entityPosition(entityId)
	if origin == nil then return nil end

	local points = {}

	for _, space in ipairs(spaces) do
		table.insert(points, {
			math.floor(origin[1]) + space[1] + 0.5,
			math.floor(origin[2]) + space[2] + 0.5
		})
	end

	return points
end
