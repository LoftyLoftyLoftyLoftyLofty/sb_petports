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
--  the life of the world.
local capabilityCache = {}

function petports_habitatCapabilitiesForType(monsterType)
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
		avoided = petports_habitatAvoidedSet(read("petports_avoidLiquids", {}))
	}

	capabilityCache[key] = caps
	return caps
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
