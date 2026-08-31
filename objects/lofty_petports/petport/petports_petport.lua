require "/scripts/util.lua"
require "/scripts/messageutil.lua"
require "/scripts/lofty_petports/petports_work.lua"
require "/scripts/lofty_petports/petports_filters.lua"

--  SO THE PORT CAN ANSWER "CAN THIS CHASSIS LIVE HERE" WITH NO UNIT TO ASK.
--  The unit runs the same ladder over live capabilities; this side runs it over
--  the monstertype's. See the head of that file for why there are two sources
--  and which one wins.
require "/scripts/lofty_petports/petports_habitat.lua"

--  FOR ONE QUESTION ONLY: is this item name a reagent? Reagent routing needs
--  the manifest's answer so that an item a MOD adds to a flavor is routed
--  without anyone re-ticking anything -- see the note on MACHINE_SLOT_REAGENT.
require "/scripts/lofty_petports/petports_flavors.lua"

--  M.A.U.S. PETPORT
--
--  A one-slot container. Socket a petports_unit item and the unit it
--  describes wakes up nearby; take the item out and the unit goes back to sleep,
--  its state written into the item.
--
--  WHY NOT THE VANILLA PET TETHER PIPELINE
--
--  /scripts/companions/petspawner.lua exists to serve capture pods, and almost
--  all of its complexity is pod-shaped: pods holding several pets at once (a
--  hemogoblin splits when it dies), collar merging, associate/disassociate
--  handlers, and a JSON round-trip that keeps a pod item in sync so a pet can be
--  carried between worlds.
--
--  None of that applies to a dedicated item. One item is one pet, there are no
--  collars, and the definition lives in the item's own parameters. What is worth
--  keeping from that file is the spine, reproduced below:
--
--    * assembling spawn parameters and handing the monster its initialStatus /
--      initialStorage, which is how a pet keeps learned state across a respawn
--    * a status heartbeat, so the petport notices when its pet dies or unloads
--    * collision-aware spawn placement
--
--  ANCHORING
--
--  Vanilla's groundPet.lua expects an anchor object and calls setAnchor on
--  itself, which calls back into hasPet/setPet here. It kills the pet outright
--  if it cannot find one -- and note that findAnchor only SEARCHES when
--  storage.anchorPosition already exists, so it is a recovery path, not a
--  discovery path. A console-spawned unit can never survive; only this object
--  can spawn a viable one, because spawnPet's setAnchor call is what writes
--  storage.anchorPosition in the first place.
--
--  So this object implements the same contract the SAIL techstation does --
--  hasPet, setPet -- and the monstertype's anchorName points at this object.
--  That keeps vanilla's pet scripts usable unmodified while the behavior work
--  happens separately.

--  CONSTANTS ARE GLOBALS, DELIBERATELY, AS OF 2026-08-29.
--
--  The main chunk hit Lua's 200-locals-per-scope ceiling -- measured: build 201
--  refused to compile, "too many local variables (limit is 200) in main
--  function" -- and 74 of those slots were UPPER_CASE constants. A global costs
--  no slot, and DE-LOCALIZING TOUCHES NO READ SITE: every existing reference
--  resolves to the global unchanged, which is what makes this the safe fix
--  where a rename to a constants table would not be.
--
--  Globals here are CONTEXT-scoped, not game-scoped -- they are visible to the
--  scripts this file requires and to nothing else. Checked at conversion time:
--  none of the required petports scripts define or read any of these names.
--
--  DEBUG IS THE ONE EXCEPTION AND STAYS LOCAL. It is the only name generic
--  enough that a required script -- vanilla's included, someday -- could
--  plausibly own a global by it, and a collision on a debug flag fails
--  silently in the worst direction.
--
--  The local/global split still signals what it always did for FUNCTIONS:
--  global means "reachable from a handler registered in init". UPPER_CASE
--  already says "constant" without needing `local` to say it twice.
STATUS_INTERVAL = 2.0

--  How often the port re-measures the liquid in its own footprint.
--
--  SHORT ON PURPOSE. Water level is not static -- it rains, players dig, pools
--  drain -- so this cannot be a one-shot check at spawn. Five seconds is
--  responsive enough that a flooding port retires its unit before the unit gets
--  itself stuck, and the measurement is sixteen liquid lookups, which is
--  nothing against a per-second work scan.
ENVIRONMENT_INTERVAL = 5.0

--  Fill fraction that counts as submerged. MUST MATCH PETPORTS_SUBMERGED_FILL
--  in petports_contract.lua -- the port and the unit have to agree about what
--  water is, or a unit is retired for an environment it would have accepted.
--
--  NOW READ FROM THE SHARED MODULE rather than spelled again here. Dispatch
--  eligibility samples tiles through petports_habitatMedia, which needs the same
--  threshold, and a third copy of 0.9 was one copy too many. The contract's own
--  constant is deliberately left alone -- it is load-bearing for the pathing
--  work closed on 2026-08-31 and agrees today.
ENVIRONMENT_SUBMERGED_FILL = PETPORTS_HABITAT_SUBMERGED_FILL

--  Consecutive environment polls a unit must read as outside its own medium
--  before the port re-homes it. See mediumCheck.
--
--  TWO, WHICH IS TEN SECONDS, AND THE SECOND POLL IS NOT CAUTION FOR ITS OWN
--  SAKE. petports_mediumAt requires EVERY tile row the body overlaps to be at or
--  above ENVIRONMENT_SUBMERGED_FILL, so a swimmer riding just under a surface can
--  read "air" for a moment without having gone anywhere. Ten seconds of a
--  genuinely beached unit costs nothing; teleporting a working one off a job
--  because it bobbed is a visible bug.
--
--  NOT THREE. HEALTH_STALL_LIMIT is 3 because a cold-cache route probe is
--  legitimately motionless for 45-50 seconds; there is no equivalent legitimate
--  reason to be in the wrong medium for fifteen.
MEDIUM_STRIKE_LIMIT = 2

--  How often the port asks whether its unit is still alive in the useful sense.
--
--  SEPARATE FROM DISPATCHED-WORK FAILURE, AND IT HAS TO BE. The stranding ladder
--  in noteFailure only counts tasks that fail, so a unit wedged in an opaque
--  hatch with nothing to do generates no signal at all -- and that is precisely
--  the case where a player goes looking for their pet and cannot find it. Work
--  failure is the RESPONSIVE path when there is work; this is the one that
--  notices when there is not.
HEALTH_INTERVAL = 30.0

--  Consecutive still checks before re-homing. THE NUMBER IS SET BY COLD-CACHE
--  ROUTE PLANNING, NOT BY IMPATIENCE: the first plan from a port spends roughly
--  45-50 seconds probing, motionless, because every unreachable edge has to
--  exhaust A* to answer. At two checks this would abort those searches for ever
--  and the route cache would never populate. Three puts the floor at 90 seconds,
--  comfortably past the longest legitimate stillness measured.
HEALTH_STALL_LIMIT = 3

--  Displacement that counts as "moved" between checks. Generous, because the
--  question is "is this thing alive", not "is it making good progress".
HEALTH_MOVE = 1.0

--  How close to the port counts as parked. A unit on station is motionless BY
--  DESIGN under strictPortTethering, so home has to be excluded or every idle
--  fleet re-homes itself every ninety seconds. Wider than the unit's own
--  TETHER_SLACK of 3.0, since the unit parks on resolved ground that can sit a
--  little off the port's own origin.
HEALTH_HOME_SLACK = 5.0
RESPAWN_GRACE = 1.0

--  HOW OFTEN TO LOOK WHILE THE HULL DOOR IS STILL MOVING.
--
--  SEPARATE FROM RESPAWN_GRACE BECAUSE THEY ANSWER DIFFERENT QUESTIONS.
--  RESPAWN_GRACE is a BACKOFF -- it exists so a port that cannot spawn does not
--  retry in a tight loop. "The door has not finished opening" is not a failure
--  and needs no backoff; it is a wait of known, short duration.
--
--  MEASURED AS A PALPABLE DELAY. Spending a full second on it meant the door
--  visibly finished and then the port sat there, because a ten-frame transition
--  lands somewhere inside the grace window and the remainder is dead time.
--
--  ZERO MEANS EVERY UPDATE TICK, which is affordable only because the door
--  check is now the FIRST thing in the block and nothing expensive runs on a
--  tick that fails it -- see the restructure below.
DOOR_POLL = 0.0

--  WHICH LOOPS THIS PORT TAKES PART IN.
--
--  A PORT PARAMETER LIKE ENABLED, AND FOR THE SAME REASONS: it describes the
--  port, survives the item being taken out, and does not travel with a unit
--  carried elsewhere.
--
--  BY GROUP, NOT BY TASK. There are fourteen work generators and nobody thinks
--  in generators. Four boxes is what a player can hold in their head, and the
--  grouping is by what they SEE happening rather than by dispatch structure.
PARTICIPATION_KEY = "petports_participation"

--  THE FOUR GROUPS, AND WHICH GENERATORS EACH ONE GATES.
--
--      hauling    collection
--      sorting    restockFetch, restockDeliver, tidy, compact
--      farming    replant, water, harvest, animal, withdraw, withdrawWater
--      machines   drain, fuel
--
--  THE LINE BETWEEN THE FIRST TWO IS INGRESS. `hauling` is how a thing ENTERS
--  the network -- loose items picked up off the ground -- and `sorting` is
--  everything done to a thing already inside it: restocked, tidied, compacted.
--  That split is why deposit belongs to neither. It is the hinge between them,
--  and it is also the unload path, which must never be switchable off.
--
--  THE KEY IS `hauling` AND THE PANE LABELS IT "Item Pickup". Deliberate, and
--  the same convention the filter manifest runs on, where a subgroup with id
--  "unit" reads "Pets": the ID IS FROZEN because it is what a stored setting
--  names, and the LABEL is free because nothing persists it. Renaming the key
--  would silently opt every configured port back into a group it had switched
--  off, since an absent key reads as participating.
--
--  TWO GENERATORS ARE IN NO GROUP AND MUST STAY THAT WAY.
--
--  returnWork is the leash. A unit that cannot be recalled is a unit that
--  wanders out of coverage and stays there.
--
--  depositWork IS THE UNLOAD PATH, AND GATING IT BUILDS A DEADLOCK. findWork
--  returns outright when a unit holds cargo with no dispatchable deposit
--  target -- that guard is what stops a unit hoarding -- so a switched-off
--  deposit means a unit which fetched a seed, planted it and kept the
--  remainder is stuck holding it forever, blocked from every other job
--  including the ones whose boxes are still ticked. A unit must always be able
--  to put down what it is carrying.
--
--  ABSENT MEANS PARTICIPATING. Every port placed before this existed has no
--  parameter, and reading that as "opted out" would switch off every port in
--  every existing world. Only an explicit false denies.
--
--  GLOBAL for the same reason petportEnabled is: its readers are the message
--  handler in init(), findWork 7000 lines below it, and the pane mirror.
function petportParticipates(group)
  local set = config.getParameter(PARTICIPATION_KEY, nil)
  if type(set) ~= "table" then return true end
  return set[group] ~= false
end

--  THE WHOLE SET, FOR THE MIRROR. Built from the same reader so the pane cannot
--  disagree with dispatch about what is switched on.
function petportParticipation()
  return {
    hauling = petportParticipates("hauling"),
    sorting = petportParticipates("sorting"),
    machines = petportParticipates("machines")
  }
end

--  THE PORT'S OWN OFF SWITCH.
--
--  An OBJECT parameter rather than anything on petData: it describes the port,
--  survives the item being taken out and put back, and does not travel with a
--  unit carried elsewhere. See the petports_setPortEnabled handler.
ENABLED_KEY = "petports_enabled"

--  CLAIM CROSSHAIRS, AND THEY BELONG TO THE PORT RATHER THAN TO THE UNIT.
--
--  MOVED HERE FROM petData.toggles. Markers are spawned by crosshairRefresh off
--  self.crosshairs, keyed on drops THIS PORT has an opinion about, and it runs
--  whether or not anything is socketed -- so filing the switch on the pet made
--  an empty port's markers unswitchable and tied a port-wide display choice to
--  whichever unit happened to be plugged in.
--
--  ABSENT MEANS ON, matching the enabled switch and matching what every
--  existing world already does.
CROSSHAIRS_KEY = "petports_crosshairs"

--  GLOBAL BECAUSE ITS READERS ARE SCATTERED -- the message handler in init(),
--  the lifecycle block in update(), and the pane mirror -- and the first of
--  those is defined 8000 lines above the last. A `local` here would work for
--  all three, being at file scope and above them; it is a global for
--  consistency with the other cross-file-scope helpers, and to keep the
--  ordering rule from having to be re-checked if this ever moves.
--
--  ABSENT MEANS ON. Every port placed before this existed has no parameter at
--  all, and reading that as "disabled" would switch off every port in every
--  existing world on update. Only an explicit false disables.
function petportEnabled()
  return config.getParameter(ENABLED_KEY, true) ~= false
end

--  Global for the same reason petportEnabled is: read from a message handler in
--  init(), from crosshairRefresh 8000 lines below it, and from the pane mirror.
function petportCrosshairs()
  return config.getParameter(CROSSHAIRS_KEY, true) ~= false
end

--  Periodic flush of drifting state into the socketed item.
--
--  Durable changes (a new known player, a new food liking, the seed) write
--  immediately. Resource drift does not, because groundPet.lua re-calls
--  setAnchor -- and therefore setPet -- once per second, and writing the item
--  back on every one of those is a container swap per second, forever,
--  replicated to every client.
--
--  THIS TIMER IS NOT A SAFETY NET. It is the actual persistence mechanism for
--  drifting values, because the final save on unsocket DOES NOT WORK and
--  cannot be made to: writeBackToItem needs the item to still be in the slot,
--  and by the time the petport notices the removal the item is already in the
--  player's inventory, out of reach. Confirmed in testing -- petports_store
--  returns fresher values than the item ends up holding.
--
--  So this interval is exactly how much resource drift an unsocket discards.
--  Only petResources are affected; durable state is written on change and
--  world unload IS covered, since uninit runs while the item is still socketed.
WRITE_INTERVAL = 10.0

--  Instrumentation, dormant by default (see handoff §4). Flip to true to trace
--  the item <-> pet state round trip in starbound.log.
local DEBUG = true

--------------------------------------------------------------------------------
--  COVERAGE AND WORK
--------------------------------------------------------------------------------
--
--  The coverage rect is a square centred on the petport: the region this port
--  keeps resident, the area its unit may take work in, and the placement-time
--  visual, all one number.
--
--  64 TILES, RAISED FROM 32. One chunk turned out to be small in practice --
--  a modest base spans several, and a port that cannot see the room next door
--  is not doing logistics.
--
--  THIS NUMBER IS LOAD-BEARING IN FOUR PLACES, and doubling it does not scale
--  them equally:
--
--    residency  the stagehand holds this rect resident every update. AREA is
--               what costs, so 32 -> 64 is 4x, not 2x. Sectors load whole, so
--               the true resident set is larger still.
--    work scan  entityQuery per rect per work tick. Also area.
--    vents      gatherVents inflates by a further COVERAGE_SIZE on each side,
--               so the vent query rect goes from 96x96 to 192x192 -- 4x again,
--               on top of a per-vent callScriptedEntity for entry and another
--               for destinations.
--    eviction   registryClearAt is NOT affected: it matches the port's exact
--               tile and is deliberately independent of coverage.
--
--  Passed to the stagehand as `coverageSize` at spawn, so changing it here is
--  enough -- but only for stagehands spawned AFTER the change. An existing
--  residency keeps the size it was born with until its port respawns it.
COVERAGE_SIZE = 64

--  How long a container that could not take a whole load is passed over for.
--
--  Not a permanent verdict. A player empties chests, and a chest that was full
--  a minute ago usually is not.
CONTAINER_FULL_BACKOFF = 60.0

--  How often to re-scan containers for beacons.
--
--  Slow on purpose. A beacon is put in a chest ONCE and then sits there; what
--  changes constantly is the chest's other contents, which this does not care
--  about. Meanwhile the scan reads every container in coverage, and coverage
--  just became four times the area.
BEACON_INTERVAL = 5.0

--  The config key a beacon item carries. See
--  /items/lofty_petports/beacons/petports_beacon_deposit.activeitem.
BEACON_KEY = "petports_sortingBeaconBehavior"

--  Set by the beacon's configuration pane. Absent means ON -- see
--  beaconBehaviorOf.
BEACON_ENABLED_KEY = "petports_beaconEnabled"

--  The deposit filter, shape documented in petports_filters.lua. Absent means
--  accept everything.
BEACON_FILTER_KEY = "petports_beaconFilter"

--  MACHINES DECLARE A CAPABILITY, NOT AN IDENTITY.
--
--  An upcycler is found by reading this parameter off the object, never by
--  matching objectName. A name would have to be relearned for every tier,
--  variant and third-party copy; a marker keeps working for all of them, and
--  the next machine kind costs the port nothing.
MACHINE_KEY = "petports_machine"

--  Rules live on the machine object, written by its own pane. Same principle as
--  the beacon filter: read the thing itself and it cannot disagree with itself.
MACHINE_RULES_KEY = "petports_upcyclerRules"
MACHINE_ENABLED_KEY = "petports_upcyclerEnabled"

--  A MACHINE'S SLOTS ARE NOT STORAGE.
--
--  An upcycler is a container, so a beacon dropped into its input slot would
--  otherwise make it a sorting destination -- and units would begin filing
--  cargo into the one device in the mod that destroys things. Anything carrying
--  this tag has its contents ignored by beacon scanning entirely.
IGNORE_BEACONS_TAG = "petports_ignore_inserted_beacons"

--  FORWARD-DECLARED HERE, AND THE POSITION IS THE POINT.
--
--  uninit lives near the top of this file; the crosshair manager lives near the
--  bottom. A `local function` is only in scope after its declaration, so the
--  tidy-up call from uninit would compile as a global lookup and be nil at
--  runtime -- an error thrown during world unload, which is the worst possible
--  place to find one because the log ends immediately afterwards.
--
--  Declared with the constants rather than with the other forward declarations
--  further down, because those sit BELOW uninit and would not have helped.
local crosshairClear

--  FORWARD-DECLARED FOR THE SAME REASON, AND THEY KEEP MOVING UP THIS FILE.
--
--  stackSizeOf and stackSizeFor are defined hundreds of lines below, and the
--  set of things that need them keeps growing upward: placeStack, which every
--  deposit now goes through; machineInputRoom, for the upcycler; and now
--  dropMergesWithCargo, which caps a cargo top-up at one stack.
--
--  A `local function` is only in scope AFTER its declaration, so each of those
--  would otherwise compile as a global lookup and be nil at runtime -- no load
--  error, no parse error, just a nil call the first time the path is taken.
--  Declaring them here, with the constants, puts them above every caller
--  regardless of where the next one turns up.
local stackSizeOf
local stackSizeFor

--  FORWARD-DECLARED, AND IT JOINED THIS LIST THE HARD WAY.
--
--  socketedItem is defined with the item/pet helpers, ~550 lines below the
--  message handlers -- and the petports_setModules handler now asks it whether
--  anything is still in the socket. A handler registered in init closes over a
--  name that is not yet a local, so the reference compiled as a GLOBAL lookup
--  and threw `attempt to call a nil value (global 'socketedItem')` the first
--  time a module slot was clicked.
--
--  NOTHING STATIC CAUGHT IT because there is nothing wrong with the line in
--  isolation, and the position check that should have caught it was made
--  against the wrong caller: the mirror's call sits below the definition and
--  passes, the handler's does not.
local socketedItem

--------------------------------------------------------------------------------
--  CARGO TRACE -- TEMPORARY, AND IT SHOULD COME OUT.
--------------------------------------------------------------------------------
--
--  Cargo is written into the socketed item on every pickup and read back out on
--  every socket, and a save dump has PROVEN the item carries it correctly:
--  100 snowflakes, serialised under parameters.petData.cargo, survived an
--  unsocket and a full game shutdown. So the write path is sound and the loss
--  is somewhere between reading that item and the next time the cargo is used.
--
--  EVERY SITE THAT READS, WRITES OR DROPS CARGO REPORTS HERE, so one socket
--  cycle produces an ordered trace instead of a guess. Turn CARGO_TRACE off
--  when this is closed; none of these sites are hot, but they are noise.
--
--  IT DISTINGUISHES AN EMPTY ARRAY FROM A JSON OBJECT, deliberately. A Lua
--  table with a hole serialises as an object rather than an array, and an
--  object is invisible to ipairs -- which is how a full cargo list could read
--  as empty everywhere downstream without anything ever throwing. If that is
--  what is happening, this line says so in words rather than printing "{}".
CARGO_TRACE = true

local function cargoSummary(cargo)
  if cargo == nil then return "nil" end
  if type(cargo) ~= "table" then return "NOT A TABLE (" .. type(cargo) .. ")" end

  local parts = {}
  for _, stack in ipairs(cargo) do
    table.insert(parts, string.format("%s x%s",
      tostring(stack and stack.name), tostring(stack and stack.count)))
  end

  if #parts > 0 then
    return string.format("%d stack(s): %s", #parts, table.concat(parts, ", "))
  end

  local keys = 0
  for _ in pairs(cargo) do keys = keys + 1 end

  if keys > 0 then
    return string.format("EMPTY TO ipairs BUT HAS %d KEY(S) -- json object, not array", keys)
  end
  return "empty"
end

local function cargoTrace(where, cargo)
  if not CARGO_TRACE then return end
  local ok, text = pcall(string.format, "PETPORT CARGO | %-22s | %s",
    tostring(where), cargoSummary(cargo))
  sb.logInfo("%s", ok and text or ("PETPORT CARGO | bad trace at " .. tostring(where)))
end


--  THE RESTOCK REQUESTS, written by the restock beacon's pane.
--
--  An ARRAY of { item, min, max }. One crate can name as many items as the
--  player adds -- "all my building materials in one box" is the case that drove
--  it, and the obvious alternative (several beacons in one crate) fails exactly
--  there, since twenty materials would need twenty beacons AND twenty stacks
--  competing for the same slots.
--
--  A beacon carrying no requests is one nobody has configured yet. It scans as
--  a restock beacon, takes its crate out of the deposit pool, and asks for
--  nothing, which is the honest reading of "I put this here but have not said
--  what I want".
BEACON_REQUESTS_KEY = "petports_beaconRequests"

--  THE SHAPE THAT CAME BEFORE THE LIST. Read only so a beacon configured under
--  the earlier build keeps working until its pane is next opened, which is when
--  it gets rewritten as a one-entry list. See restockRequestsOf.
BEACON_ITEM_KEY = "petports_beaconItem"
BEACON_MIN_KEY = "petports_beaconMin"
BEACON_MAX_KEY = "petports_beaconMax"

--  How long a claim survives without a refresh. Long enough to walk across the
--  rect, short enough that an abandoned job frees up while the player watches.
--------------------------------------------------------------------------------
--  HARVESTING
--------------------------------------------------------------------------------
--
--  How often the network is swept for farmables. SLOW ON PURPOSE, for the same
--  reason the beacon scan is: crops change state on the order of twenty
--  minutes, and an entityQuery for every object across the whole network is
--  not something to run on the work tick.
--
--  KNOWN COST, NOT YET PAID DOWN: this is a SECOND full object sweep of the
--  network alongside scanContainers, on its own timer. Folding both into one
--  query is the obvious saving and was deliberately not done here -- it means
--  editing a verified working path to add an unverified one, and the process
--  note in the handoff is emphatic about not stacking changes like that. Fold
--  it once harvesting is proven.
HARVEST_INTERVAL = 5.0

--  WHICH NUMBER world.farmableStage COUNTS FROM. UNVERIFIED.
--
--  The stages array in a farmable's config is a Lua list, so its harvest stage
--  sits at Lua index #stages. What world.farmableStage returns for that same
--  stage is not documented and HarvesterBeam never compares it to anything --
--  it only ever tests the value for nil-ness and number-ness, so it proves
--  nothing either way.
--
--  0 assumes engine-side indexing, which is the ordinary C++ convention and
--  what corn's "resetToStage" : 2 reads as (its harvest stage is the fourth
--  entry, resetting to the third).
--
--  IF THIS IS WRONG the symptom is specific and visible: ripeness is tested
--  with EQUALITY, so a wrong base means the unit either never harvests at all,
--  or fires one stage early. The farmable scan logs every crop's stage against
--  its stage count on change, so ONE LOOK AT THE LOG SETTLES IT -- find a crop
--  you can see is fully grown and read what number it reports.
--
--  Firing early is bounded rather than harmless: FarmableObject::damageTiles
--  falls through to ordinary object damage when harvest() declines, so an
--  early fire damages the crop rather than picking it. HARVEST_DAMAGE, on the
--  unit, is sized so that costs little, and a harvest that does not change it is
--  reported as a failure, which puts it on the standard backoff ladder instead
--  of hammering it once a second.
FARMABLE_STAGE_BASE = 0

--  NOTE the damage amount and harvest level live on the UNIT, in
--  petportsTaskAction.lua, because the unit is what swings. Every script in a
--  monstertype shares one environment and an object has its own; a constant
--  declared here would be a nil global there, inside a pcall, presenting as
--  "damageTiles does not work" rather than as a missing value.

--------------------------------------------------------------------------------
--  WATERING
--------------------------------------------------------------------------------
--
--  How many tiles one dispatch may cover, and therefore how many units of
--  liquid a unit fetches per trip.
--
--  ONE ITEM PER TILE is the economy, deliberately stricter than vanilla, which
--  charges consumeLiquid 0.5 per interaction. But one item per tile does NOT
--  mean one TRIP per tile: a forty-tile row would otherwise be forty round
--  trips to a crate, which is absurd to watch and pointless to simulate.
--
--  The cap also bounds the task. A run is capped at this length, so a long row
--  becomes several sweeps rather than one task that outlives TASK_DEADLINE.
WATER_CARRY = 10

--  How far to look left and right from a crop for more dry soil.
--
--  A bot that waters only the tile under the crop leaves a checkerboard. The
--  least a fleet can do is finish the row it is standing in -- soil that is
--  tilled and dry and contiguous is planting-ready ground somebody prepared on
--  purpose.
WATER_RUN_REACH = 32

CLAIM_TTL = 30.0

--  How often to look for work and to push claim expiry out.
WORK_INTERVAL = 1.0

--  How often to re-state an unchanged dispatch rejection.
REJECT_REPEAT = 30.0

--  Hard ceiling on a single task, regardless of what the unit reports.
--
--  Every failure path is supposed to report, but a report that never arrives
--  strands the port in trackWork forever -- refreshing a claim for work nobody
--  is doing and dispatching nothing else, permanently. A deadline makes that
--  self-healing rather than terminal. Longer than any legitimate task: an
--  unreachable target gives up in SEARCH_LIMIT, a long walk in
--  APPROACH_TIMEOUT.
--  Raised from 60: a COLD route cache legitimately spends 40+ seconds probing,
--  since each unreachable edge costs the full A* exhaustion. Once warm, plans
--  resolve in milliseconds.
TASK_DEADLINE = 150.0

--  Diagnostic task only: how long the unit stands at the point.
DIAG_DWELL = 3.0

--  UNREACHABLE WORK BACKOFF
--
--  A task that fails must not be re-dispatched immediately. Reachability is not
--  checked at discovery -- the port sees an item drop in its rect and has no
--  cheap way to know a ground unit cannot climb to it -- so the unit finding
--  out IS the reachability test, and the result has to be remembered.
--
--  Without this, one stranded item permanently occupies the port's dispatch
--  slot while everything reachable goes uncollected. Escalating so a
--  briefly-blocked item is retried soon and a genuinely unreachable one stops
--  costing anything.
--
--  RETUNED: WAS { 10, 30, 120, 600 }.
--
--  The old curve was wrong at both ends. Ten seconds for a FIRST failure is an
--  age for the commonest cause -- an item that was still falling, or a unit
--  that was momentarily boxed in by another -- so transient blockages were
--  punished as if they were permanent. And six hundred seconds is not a
--  backoff, it is an abandonment: a drop behind a door the player opens a
--  minute later sits ignored for another nine.
--
--  The last entry is what a persistent failure settles on, because the lookup
--  clamps to the end of the list. Thirty seconds costs almost nothing to retry
--  and means anything the player fixes is picked up within half a minute
--  without them having to think about it.
--
--  The ramp matters more than the ceiling. One and two seconds cover "try
--  again in a moment", five and ten cover "something is genuinely in the way",
--  and only past that does the port conclude it should stop asking often.
FAILURE_BACKOFF = { 1.0, 2.0, 5.0, 10.0, 30.0 }

--  How many failed walk-home attempts before the unit is re-homed instead.
RECALL_LIMIT = 2

--  Consecutive unreachable-target failures before the unit is treated as
--  SEALED IN rather than merely unlucky.
--
--  Distinct from RECALL_LIMIT, which counts failures to walk home. This counts
--  failures to reach WORK, and it exists because those are the only symptom a
--  unit shut inside a room ever produces.
--
--  Small on purpose. A genuinely unreachable target fails fast once its edges
--  are cached, so three in a row is seconds of evidence, not minutes -- and a
--  unit that can still reach anything at all resets this on its first success.
STRANDED_LIMIT = 3

--  How far beyond the network's coverage to look for usable vents.
VENT_SEARCH_MARGIN = 24

--  Fall back to the diagnostic task when there is no real work?
--
--  Useful for exercising residency and dispatch with an empty rect, noisy
--  otherwise. Off by default now that collection exists.
DIAG_FALLBACK = false

--  Residency stagehand type. One per petport, spawned on first update.
RESIDENCY_TYPE = "petports_residency"

local function trace(label, value)
  if not DEBUG then return end
  if value == nil then
    sb.logInfo("[petport] %s: nil", label)
  elseif type(value) == "table" then
    sb.logInfo("[petport] %s: %s", label, sb.printJson(value))
  else
    sb.logInfo("[petport] %s: %s", label, tostring(value))
  end
end

--  METRICS -- raw monotonic totals on petData.stats. See dd.pane.ratesnottotals:
--  TOTALS ARE STORED HERE, RATES ARE COMPUTED IN THE PANE, and the pane owns
--  the wording, same split as bodyKind.
--
--  ON petData RATHER THAN ON THE PORT, because the stats describe the UNIT: they
--  ride writeBackToItem wholesale, survive unsocket, reload and respawn, and
--  travel with the item -- which is what an examiner NPC will one day inspect.
--
--  DELIBERATELY DOES NOT SET self.dirty. Every moved/tidy increment happens on a
--  path that already ends in flushCargo or writeBackToItem, and `active` ticks
--  every frame -- marking that dirty would turn the slow write timer into a
--  write-per-tick. Losing up to one WRITE_INTERVAL of stats to a crash is the
--  accepted cost.
--
--  ONE TABLE, ONE LOCAL SLOT. Three functions live on it -- add,
--  noteStorageTake, paneStats -- because the main chunk sits at Lua's
--  200-locals-per-scope ceiling, MEASURED 2026-08-29: build 201 refused to
--  compile with "too many local variables (limit is 200) in main function".
--  Fields resolve at call time through the table, so definition order between
--  them stops mattering; the table itself is declared up here so every later
--  function can reach it.
local metrics = {}

metrics.add = function(key, amount)
  if self.petData == nil then return end
  if amount == nil or amount == 0 then return end

  self.petData.stats = self.petData.stats or {}
  self.petData.stats[key] = (self.petData.stats[key] or 0) + amount
end

--  The port's coverage rect: the region it keeps resident, the area its unit
--  may take work in, and the placement-time visual, all one number.
--
--  Declared UP HERE because init's message handler uses it. A `local function`
--  is not visible above its own declaration, and referencing it from init
--  resolves to a nil global that only throws when the handler actually fires --
--  which is on the first task report, not at load.
local function coverageRect()
  return petports_coverageRect(entity.position(), COVERAGE_SIZE)
end

--  Our registry entry. Published on first update and whenever our own
--  configuration changes; the version counter is what tells other ports to
--  re-derive.
local function publishRegistry()
  local rect = coverageRect()

  --  Clear any predecessor sitting at our own position first, so a port that
  --  was mined and replaced does not leave a phantom coverage zone behind.
  --  OUR POSITION, not our rect. Clearing by rect evicted every other port
  --  within sixteen tiles -- see petports_registryClearAt.
  petports_registryClearAt(entity.position(), stationUniqueId())

  petports_registryPublish(stationUniqueId(), {
    rect = rect,
    position = entity.position(),
    participate = config.getParameter("petports_participate", true),
    id = config.getParameter("petports_networkId", 0)
  })
end

--  Re-derive our network when the registry version moves, and push the rect
--  list to our unit only if it actually changed.
--
--  The unit never learns that networks exist. It gets a list of rectangles and
--  one rule: when IDLE, stay inside them. A task may path anywhere.
--  Union dispatch needs to know where other members' units are, so the entry
--  carries it -- refreshed only when the unit has moved MATERIALLY, because
--  this is replicated state and a per-tick write would be the one genuinely
--  expensive thing in the design.
UNIT_POSITION_THRESHOLD = 4.0

local function publishUnitPosition()
  local registry = petports_registry()
  local entry = (registry.ports or {})[stationUniqueId()]
  if entry == nil then return end

  local position = nil
  local busy = self.task ~= nil

  if self.petId ~= nil and world.entityExists(self.petId) then
    position = world.entityPosition(self.petId)
  end

  --  NIL IS NOT MOVEMENT WHEN IT WAS ALREADY NIL.
  --
  --  This read `position == nil or entry.unitPosition == nil or <distance>`,
  --  so an empty port -- position permanently nil -- computed moved = true on
  --  every single tick, skipped the unchanged-state early return below, and
  --  republished forever. Each publish bumps the shared registry version, and
  --  every port polls that version and re-derives its network and re-gathers
  --  its vents when it moves.
  --
  --  Measured: one empty port drove the version from 17249 to 18037 in about
  --  sixty-five seconds, so every port in the world re-ran gatherVents roughly
  --  twelve times a second for as long as it sat there.
  --
  --  What is actually being asked is "has anything changed", and going from no
  --  unit to no unit is not a change.
  local appeared = (position == nil) ~= (entry.unitPosition == nil)
  local moved = appeared
    or (position ~= nil and entry.unitPosition ~= nil
        and world.magnitude(position, entry.unitPosition) > UNIT_POSITION_THRESHOLD)

  if not moved and entry.busy == busy
     and entry.hasUnit == (position ~= nil) then return end

  sb.logInfo("PETPORT %s publishing unit position %s (busy %s, hasUnit %s, was %s)",
    stationUniqueId(), sb.printJson(position), tostring(busy),
    tostring(position ~= nil), sb.printJson(entry.unitPosition))

  entry.unitPosition = position
  entry.busy = busy

  --  Explicit, so a reader never has to infer "has a unit" from a position that
  --  might merely be stale.
  entry.hasUnit = position ~= nil
  petports_registryPublish(stationUniqueId(), entry)
end

--  Vents inside the network's coverage, with where they come out.
--
--  The PORT gathers this because it already knows the network's rects and can
--  query objects cheaply. It cannot evaluate REACHABILITY -- pathfinding needs
--  mcontroller, which objects do not have -- so the unit does that part.
local function gatherVents()
	local ventReport = {}

  --  Vents are gathered from a rect INFLATED beyond the network's coverage.
  --
  --  A vent sitting just outside coverage is still perfectly usable -- units on
  --  task may leave the network, and vents exist precisely to reach
  --  out-of-the-way places. Gathering only from inside meant a vent one tile
  --  past the boundary silently vanished from the routing options, which reads
  --  as "the drone ignores my vent" with nothing to explain it.
  local rects = self.networkRects
  if rects == nil or #rects == 0 then rects = { coverageRect() } end

  local inflated = {}
  for _, area in ipairs(rects) do
    table.insert(inflated, {
      area[1] - VENT_SEARCH_MARGIN, area[2] - VENT_SEARCH_MARGIN,
      area[3] + VENT_SEARCH_MARGIN, area[4] + VENT_SEARCH_MARGIN
    })
  end
  rects = inflated

  local vents = {}
  local seen = {}

  for _, area in ipairs(rects) do
    local found = world.entityQuery({area[1], area[2]}, {area[3], area[4]}, {
      includedTypes = { "object" }
    })

    for _, id in ipairs(found or {}) do
      if not seen[id] and world.entityName(id) == "petports_petvent" then
        seen[id] = true

        local okEntry, entry = pcall(world.callScriptedEntity, id, "petports_ventEntryPosition")
        local okDest, dests = pcall(world.callScriptedEntity, id, "petports_ventDestinations")

        --  EVERY vent is listed, including ones with no exits.
        --
        --  Requiring destinations used to drop receive-only and unlinked vents
        --  from the list entirely -- and pruneRouteCache treats absence from
        --  the list as "this vent is gone", so their cached edges were deleted
        --  on every refresh and re-probed from scratch when they came back.
        --  Under directional wiring a terminal vent legitimately has no exits,
        --  so that would have thrown away good probe work constantly.
        --
        --  Pruning now means only what it says: the vent was physically
        --  removed. planRoute skips vents it cannot traverse.
        local exits = {}
        for _, destination in ipairs(dests or {}) do
          table.insert(exits, destination.id)
        end

        --  Accumulated and reported once per refresh, change-gated below.
        --  Was one line per vent per refresh: 339 vents-worth of identical
        --  wiring in a single session.
        table.insert(ventReport, string.format("%s@%s->%s%s",
          tostring(id), sb.printJson(entry), sb.printJson(exits),
          (okEntry and okDest) and "" or " (CALL FAILED)"))

        if okEntry and entry ~= nil and okDest and dests ~= nil then
          table.insert(vents, { id = id, entry = entry, destinations = dests })
        else
          sb.logInfo("PETPORT %s gatherVents: DROPPED vent %s -- entry %s dests %s",
            stationUniqueId(), sb.printJson(id),
            sb.printJson(entry), sb.printJson(dests))
        end
      end
    end
  end

  --  ONE LINE PER REFRESH, AND ONLY WHEN THE WIRING CHANGES. Vent topology is
  --  static until a player rewires something, so re-stating it every few
  --  seconds is pure noise -- but losing it entirely means a mis-wired vent
  --  becomes invisible. Change-gating keeps the signal and drops the volume.
  table.sort(ventReport)
  local signature = table.concat(ventReport, " | ")

  --  DELIBERATELY NOT self.ventSignature -- refreshNetwork owns that one for
  --  ventSignature(vents), and sharing it made both change-gates fire on every
  --  call. The visible symptom was "vent topology changed" once a second; the
  --  invisible one was unitChanged going true with it, so the port re-pushed
  --  rects and vents to its unit every tick.
  if signature ~= self.ventReportSignature then
    self.ventReportSignature = signature
    sb.logInfo("PETPORT %s vents: %s", stationUniqueId(),
      signature == "" and "none" or signature)
  end

  return vents
end

--  A stable signature for the gathered vent list: every vent and every exit it
--  offers. Compared as a string so a rewiring is detected without a deep diff.
local function ventSignature(vents)
  local rows = {}
  for _, vent in ipairs(vents or {}) do
    local exits = {}
    for _, destination in ipairs(vent.destinations or {}) do
      table.insert(exits, tostring(destination.id))
    end
    table.sort(exits)
    table.insert(rows, tostring(vent.id) .. ">" .. table.concat(exits, ","))
  end
  table.sort(rows)
  return table.concat(rows, ";")
end

--  Drop cached edges that name a vent which no longer exists.
--
--  NOT A BLANKET CLEAR, unlike the coverage path above. The two cases are not
--  alike: a coverage change moves terrain the cache was derived from, while a
--  rewiring changes only which exits connect to which. Every cached edge is a
--  WALKABILITY fact -- "from the exit of vent 17, can this unit walk to vent
--  18's mouth" -- and rewiring 84 makes none of them false.
--
--  The distinction is worth the extra code because probing is the single most
--  expensive thing the system does. An instrumented cold cache spent 47 seconds
--  on one plan, all of it A* exhaustion on unreachable edges. Discarding that to
--  react to a wire being moved would be a far worse trade than the stale entry
--  it protects against, and vanished ids are the only genuinely dead entries.
local function pruneRouteCache(vents)
  if self.routeCache == nil then return 0 end

  local live = {}
  for _, vent in ipairs(vents or {}) do live[tostring(vent.id)] = true end

  local removed = 0
  for key in pairs(self.routeCache) do
    --  Keys are "<from>><to>", where a vent appears as "e:<id>" or "x:<id>".
    for id in string.gmatch(key, "[ex]:(%-?%d+)") do
      if not live[id] then
        self.routeCache[key] = nil
        removed = removed + 1
        break
      end
    end
  end

  return removed
end

local function refreshNetwork()
  local version = petports_registryVersion()
  local unitChanged = false

  if version ~= self.registryVersion then
    self.registryVersion = version

    sb.logInfo("PETPORT %s registry version moved to %s", stationUniqueId(), sb.printJson(version))

    local rects = petports_networkRects(stationUniqueId())
    if not petports_rectListsEqual(rects, self.networkRects) then
      self.networkRects = rects
      unitChanged = true
      sb.logInfo("PETPORT %s network now %s ports", stationUniqueId(), #rects)

      --  Coverage changed, so vents may have appeared or vanished and terrain
      --  the cache was derived from may no longer be reachable the same way.
      --
      --  A stale entry is self-correcting -- it suggests a route that fails
      --  fast, and that failure is the signal -- but clearing on a known
      --  structural change is cheaper than discovering it one bad route at a
      --  time.
      self.routeCache = {}
      self.routeDirty = true
    end

    --  VENTS ARE A FIRST-CLASS TRIGGER, NOT A PASSENGER.
    --
    --  gatherVents used to be called only inside the push block below, and that
    --  block only ran when the RECTS changed. A vent rewired in place bumps the
    --  version, moves no rect, and so pushed nothing -- the unit kept its old
    --  vent list and kept planning routes through exits that no longer existed.
    --
    --  Gathered after the rect update above, since it reads self.networkRects.
    local vents = gatherVents()
    if ventSignature(vents) ~= self.ventSignature then
      self.ventSignature = ventSignature(vents)
      unitChanged = true

      local removed = pruneRouteCache(vents)
      if removed > 0 then self.routeDirty = true end

      sb.logInfo("PETPORT %s vent topology changed: %s vents, %s stale edges dropped",
        stationUniqueId(), #vents, removed)
    end
    self.vents = vents
  end

  --  Also push on a fresh unit, which has no list yet, and whenever the route
  --  cache has learned something -- other units on this port benefit from what
  --  one of them discovered.
  if (unitChanged or self.routeDirty or self.pushedToPet ~= self.petId)
     and self.petId ~= nil and world.entityExists(self.petId) then
    world.callScriptedEntity(self.petId, "petports_setNetwork",
      self.networkRects, entity.position())

    --  Vent list rides the same push. Entity ids are not stable across a
    --  reload, which is fine: this is re-gathered and re-pushed on every spawn.
    --
    --  Reuses the list gathered above when there is one. This block also fires
    --  on a fresh unit with the version unmoved, so it must still be able to
    --  gather for itself.
    if self.vents == nil then
      self.vents = gatherVents()
      self.ventSignature = ventSignature(self.vents)
    end
    sb.logInfo("PETPORT %s pushing to unit %s: %s rects, %s vents, routeDirty %s, freshUnit %s",
      stationUniqueId(), sb.printJson(self.petId),
      sb.printJson(#(self.networkRects or {})), sb.printJson(#(self.vents or {})),
      tostring(self.routeDirty), tostring(self.pushedToPet ~= self.petId))

    world.callScriptedEntity(self.petId, "petports_setVents", self.vents)
    world.callScriptedEntity(self.petId, "petports_setRouteCache", self.routeCache)
    self.routeDirty = false
    self.pushedToPet = self.petId
  end
end

--  Is a position inside our NETWORK's coverage?
--
--  Not our own rect. Union dispatch sends a unit into any member's coverage, so
--  testing against the port's own rect marks a unit stray the moment it does
--  exactly what it was told to do -- and recalls it home after every
--  cross-port pickup.
local function inNetwork(position)
  local rects = self.networkRects
  if rects == nil or #rects == 0 then rects = { coverageRect() } end

  for _, area in ipairs(rects) do
    if petports_rectContains(area, position) then return true end
  end
  return false
end


--  Record that a task did not succeed.
--
--  CENTRALISED because there are two ways a task can end badly and they RACE:
--  the unit reports failure, and trackWork independently notices the unit is no
--  longer holding it. Whichever wins clears self.task, and the loser used to be
--  discarded -- which meant recall failures were never counted, re-home never
--  fired, and a stranded unit was recalled forever.
local function noteFailure(taskId, reason)
  if taskId == nil then return end

  if taskId == "return:" .. stationUniqueId() then
    self.recallFailures = (self.recallFailures or 0) + 1

    --  WHEN, NOT JUST HOW MANY. See paneDiagnostics: the COUNT is escalation
    --  state and is right to persist, but a player reading a persistent count
    --  on an idle unit concludes it is broken. The timestamp is what lets the
    --  readout say "currently struggling" without touching the escalation.
    self.recallAt = world.time()

    sb.logInfo("PETPORT %s recall failed (%s of %s): %s",
      stationUniqueId(), self.recallFailures, RECALL_LIMIT, reason)
    return
  end

  --  COUNT FAILURES THAT MEAN "CANNOT GET THERE FROM HERE".
  --
  --  A unit sealed into a room by a rewiring produces exactly one symptom: every
  --  target becomes unroutable. It never strays, never dies, and never misses a
  --  deadline once its edges are cached -- it just fails everything, instantly,
  --  forever. Counting that is the only way the port can notice.
  --
  --  Reset by any successful task, so a single awkward drop behind a locked
  --  door cannot accumulate its way to a re-home.
  sb.logInfo("PETPORT %s noteFailure %s: %s", stationUniqueId(), taskId, tostring(reason))

  --  WHICH FAILURES MEAN "THIS UNIT IS STRANDED" RATHER THAN "THAT JOB IS HARD".
  --
  --  This matched only "no route", which was every stranding the mod could
  --  produce when it was written. It is not any more, and the consequence was
  --  that rehomeUnit -- the whole failsafe -- became unreachable code:
  --  unreachableFailures never climbed, so `stranded` was never true, so the
  --  inside-the-rect guard in returnWork returned early and reset recallFailures
  --  every tick.
  --
  --  MEASURED tonight in three separate shapes, none of which say "no route":
  --  a unit wedged in a trapdoor, a flyer frozen in water it could not plan out
  --  of, and a unit walled into dirt. All three reported "no net progress --
  --  moved 0 in 10s", which is the single most direct statement of "this unit
  --  is stuck" the system produces.
  --
  --  DELIBERATELY NOT MATCHING "no standable position" OR "no ground position".
  --  Those describe a TARGET the unit cannot occupy, not a unit that cannot
  --  move -- an aquatic pet correctly declining a dry crate says one of those
  --  every time, and counting it would re-home a perfectly healthy unit for
  --  doing its job right.
  --
  --  Three of these in a row still has to happen, and ANY successful task
  --  resets the counter, so a single awkward target cannot accumulate its way
  --  to a re-home.
  local strandedReason =
    string.find(reason or "", "no vent route", 1, true) ~= nil
    or string.find(reason or "", "no route", 1, true) ~= nil
    or string.find(reason or "", "no net progress", 1, true) ~= nil

  if strandedReason then
    self.unreachableFailures = (self.unreachableFailures or 0) + 1
    self.unreachableAt = world.time()
    sb.logInfo("PETPORT %s unreachable failure %s of %s: %s",
      stationUniqueId(), self.unreachableFailures, STRANDED_LIMIT, reason)
  end

  --  A failure while the unit was outside its network says nothing about the
  --  work -- the unit's position was the problem, not the item.
  if self.petId ~= nil and world.entityExists(self.petId)
     and not inNetwork(world.entityPosition(self.petId)) then
    sb.logInfo("PETPORT %s not blaming %s: unit was outside the network at %s",
      stationUniqueId(), taskId, sb.printJson(world.entityPosition(self.petId)))
    return
  end

  local record = self.workFailures[taskId] or { count = 0 }
  record.count = record.count + 1

  --  WAS THIS A ROUTING FAILURE OR SOMETHING ELSE?
  --
  --  Recorded here rather than re-derived later, because this is the one place
  --  the reason string exists. The crosshair markers key off it: a target the
  --  unit cannot REACH is a different problem from one it can reach and cannot
  --  service, and they want different symbols -- an X versus a warning.
  record.unroutable = string.find(reason or "", "no vent route", 1, true) ~= nil
    or string.find(reason or "", "no route", 1, true) ~= nil
  local backoff = FAILURE_BACKOFF[math.min(record.count, #FAILURE_BACKOFF)]
  record["until"] = world.time() + backoff
  self.workFailures[taskId] = record

  sb.logInfo("PETPORT %s backing off %s for %s seconds (failure %s)",
    stationUniqueId(), taskId, sb.printJson(backoff), record.count)
end


--  RESIDENCY
--
--  keepAlive is unavailable on objects, so a petport cannot keep its own
--  coverage rect loaded. It anchors a stagehand that can. See
--  /stagehands/lofty_petports/petports_residency.stagehand.
--
--  The stagehand's uniqueId is derived from the port's TILE POSITION, not from
--  the port's uniqueId. A port that is mined and re-placed at the same spot is
--  a new object with a new uniqueId, so a uniqueId-derived key would orphan the
--  old stagehand and mint a second one. Position-derived reuses it, and gives a
--  sweep a pattern to find strays by.
local function residencyUniqueId()
  local position = entity.position()
  return string.format("petports_residency_%s_%s",
    math.floor(position[1]), math.floor(position[2]))
end

--  Spawn the stagehand if it is not already there.
--
--  Retried on a slow timer rather than only on first update: a spawn that fails
--  should be visible as a repeating attempt rather than a single silent miss,
--  and a stagehand that dies while its port lives should be replaced.
local function ensureResidency()
  local residencyId = residencyUniqueId()
  local existing = world.loadUniqueEntity(residencyId)

  if existing ~= nil and world.entityExists(existing) then
    return
  end

  --  uniqueId is passed TWICE on purpose. The override key is the obvious way
  --  and is UNVERIFIED; `residencyUniqueId` is read by the stagehand's own init
  --  which calls stagehand.setUniqueId with it. Whichever mechanism actually
  --  works, the id ends up set, and if both work the second is a no-op.
  local ok, result = pcall(world.spawnStagehand, entity.position(), RESIDENCY_TYPE, {
    uniqueId = residencyId,
    residencyUniqueId = residencyId,
    portUniqueId = stationUniqueId(),
    coverageSize = COVERAGE_SIZE
  })

  sb.logInfo("PETPORT %s residency spawn id=%s ok=%s result=%s",
    stationUniqueId(), residencyId, tostring(ok), tostring(result))
end

--  Only on DESTRUCTION. Never from uninit -- that also fires on world unload,
--  and killing residency there would orphan every port on the next reload.
local function stopResidency()
  local residencyId = world.loadUniqueEntity(residencyUniqueId())
  if residencyId == nil then return end

  world.sendEntityMessage(residencyId, "petports_residencyStop")
end

local function abandonTask(reason)
  if self.task == nil then return end

  sb.logInfo("PETPORT %s abandoning %s: %s", stationUniqueId(), self.task.id, reason)
  petports_claimRelease(self.task.id, stationUniqueId())
  self.task = nil
end

--  BUILD STAMP.
--
--  THE LARGEST FILE IN THE MOD AND THE ONE MOST OFTEN EDITED, and until now the
--  only way to tell a stale copy from a wrong one was to guess. The upcycler
--  object's missing stamp already cost a full test round; this is the same
--  silent failure with more surface area.
local PETPORT_BUILD_STAMP = "2026-08-31k the vouch rides on the task"

function init()
  sb.logInfo("PETPORT object build: %s", PETPORT_BUILD_STAMP)

  self.petId = nil

  --  Held between petports_despawn and the unit actually leaving the world, so
  --  the hull door does not close over a dematerialising unit. Cleared by the
  --  entityExists poll in the main update.
  self.fadingPetId = nil

  self.petUniqueId = nil
  self.petData = nil
  self.statusTimer = 0
  self.spawnTimer = 0
  self.spawning = false
  self.dirty = false
  self.writeTimer = WRITE_INTERVAL
  self.firstUpdate = true

  --  Sent by the pet when it dies or is recalled, so the petport can write the
  --  final state back into the item rather than losing it.
  message.setHandler("petports_status", simpleHandler(function(status, storage)
    if self.petData then
      self.petData.status = status or self.petData.status
      self.petData.storage = storage or self.petData.storage
      self.dirty = true
      trace("petStatus message -> storage", self.petData.storage)
    end
  end))

  --  A HEADPAT. Sent by the unit when a player interacts with it AND vanilla's
  --  own interaction window accepts it -- see interact() in
  --  petports_contract.lua, where the send sits INSIDE the interactCooldown
  --  branch. ONE GATE, AND IT IS THE UNIT'S: a pat that emotes is exactly a
  --  pat that counts, and no second cooldown here can disagree with the first.
  --  The port-side 1s cooldown this used to carry is superseded.
  --
  --  THE STUCK-CARGO BRANCH GOES HERE WHEN IT EXISTS. The intended design:
  --  interacting with a unit that is holding cargo it cannot deliver makes it
  --  drop that cargo, and only an interaction with nothing to drop is a pat.
  --  Cargo lives on petData, so the PORT owns that decision -- the unit
  --  reports every accepted interaction and this handler decides what it
  --  meant. Today no stuck-cargo mechanic exists, so every one is a pat.
  message.setHandler("petports_headpat", simpleHandler(function()
    if self.petData == nil then return end

    metrics.add("headpats", 1)

    sb.logInfo("PETPORT %s headpat (%s lifetime)", stationUniqueId(),
      sb.printJson((self.petData.stats and self.petData.stats.headpats) or 0))
  end))

  --  ---- THE PANE'S WRITE PATH ----------------------------------------------
  --
  --  The pane READS through a mirrored parameter and WRITES through these. It
  --  never guesses at an outcome: every one of these rewrites the mirror, and
  --  the pane repaints from the mirror on its next poll. So a refused action
  --  simply leaves the pane showing what is actually true.

  --  TAKE CARGO. The port debits petData and RETURNS the descriptor; the pane
  --  gives it to the player.
  --
  --  ONE AUTHORITY, WHICH IS THE WHOLE REASON THIS IS A BUTTON AND NOT A BOUND
  --  ITEMGRID. Cargo lives on petData, which is what makes it survive unsocket,
  --  respawn and world reload. A grid bound to container slots would be a
  --  second store, and the two diverge exactly when a unit is out in the field:
  --  player empties the slot, unit still believes it is carrying.
  --
  --  KNOWN GAP -- the debit happens here and the give happens in the pane, so a
  --  player whose inventory cannot take the stack loses it. player.giveItem
  --  drops rather than destroys, but a drop in front of a petport is an item
  --  this network will promptly collect again. Wants an ack before the debit.
  message.setHandler("petports_takeCargo", simpleHandler(function()
    if self.petData == nil or self.petData.cargo == nil then return nil end
    if #self.petData.cargo == 0 then return nil end

    local stack = table.remove(self.petData.cargo, 1)
    self.dirty = true
    self.paneSignature = nil

    sb.logInfo("PETPORT %s pane took cargo: %s", stationUniqueId(), sb.printJson(stack))
    return stack
  end))

  --  COMMIT THE WHOLE MODULE SET, NOT ONE SLOT.
  --
  --  THE SWAP HAS ALREADY HAPPENED BY THE TIME THIS RUNS, and that is the part
  --  worth understanding before changing anything here.
  --
  --  The pane performs the item move locally and synchronously -- reads the
  --  cursor, writes the old occupant back to the cursor, repaints the slot --
  --  which is exactly mechassemblygui's shape. It is done that way because a
  --  message round trip CANNOT be made atomic: take the cursor first and a
  --  refusal destroys the item, commit here first and a dropped reply
  --  duplicates it. Vanilla avoids the choice by never crossing the boundary
  --  mid-move, and so do we.
  --
  --  WHICH MAKES THIS A COMMIT, NOT A GATE. The validation below is a backstop
  --  against a malformed payload, not the decision -- the decision was made in
  --  the pane, against the same root.itemHasTag call this uses, so the two
  --  cannot disagree about what a module is.
  --
  --  A REFUSAL HERE IS THEREFORE LOUD AND WHOLESALE. If any record fails, none
  --  is stored and the mirror repaints the pane back to what is actually true.
  --  The player's item is already out of the cursor at that point, so this is a
  --  loss window -- narrow enough to accept (it needs an item's tags to change
  --  between the pane opening and the click) and logged at error level so that
  --  if it ever does happen it is not diagnosed as a pathing bug.
  --
  --  See the MODULES section for why the payload is a list of records rather
  --  than an array indexed by slot.
  message.setHandler("petports_setModules", simpleHandler(function(payload)
    --  THE CONTAINER IS CHECKED, NOT JUST petData. petData survives an unsocket
    --  until workUpdate next runs -- up to WORK_INTERVAL -- and a module write
    --  accepted in that gap would be stored against a unit that has already
    --  left, on top of the copy that left with it. See mirrorPaneState.
    --
    --  THIS CANNOT UNDO THE PANE'S HALF OF THE SWAP and is not meant to. The
    --  window is closed by mirroring the empty socket promptly; this is the
    --  backstop for a message already in flight when it closed.
    if socketedItem() == nil then return false end

    if self.petData == nil or type(payload) ~= "table" then return false end

    --  STAMPED BEFORE ANYTHING IS VALIDATED, AND THAT ORDER IS THE POINT.
    --
    --  The pane holds its own module set as authoritative until this token comes
    --  back, because a mirror written between its click and this handler would
    --  otherwise repaint the module it just socketed back out of the local set
    --  -- and the next click would then send a payload that does not mention it.
    --  That is an item-loss path, and it is the one that ate a module in
    --  testing while a unit was picking up cargo.
    --
    --  A REFUSAL MUST RESOLVE THE WAIT TOO, or the pane sits forever showing a
    --  module the port never accepted. So this is recorded on the way IN, ahead
    --  of every early return below, rather than beside the commit.
    --
    --  paneSignature IS CLEARED UNCONDITIONALLY so the echo is guaranteed to
    --  reach the pane even when the module set did not actually change -- an
    --  unchanged blob would otherwise be swallowed by the mirror's change gate
    --  and the pane would wait on a token that is never sent. Once per click.
    self.moduleToken = payload.token
    self.paneSignature = nil

    local records = payload.modules
    if type(records) ~= "table" then return false end

    --  EVERY REFUSAL BELOW REPAINTS THE PANE, and that is the only thing that
    --  can be done about the loss window described above.
    --
    --  The pane has already taken the item out of the cursor by the time this
    --  runs. If the set is refused, the port stores nothing and the pane is
    --  left holding a module that exists in no inventory -- a phantom that
    --  looks perfectly normal until the pane is closed and it is gone.
    --
    --  Clearing the signature forces the next mirror write through the change
    --  gate whether or not the state moved, so the pane repaints from truth and
    --  the module visibly disappears. That does not save the item. It turns a
    --  silent loss into one the player can SEE, which is the difference between
    --  a bug report and a mystery.
    local function refuse()
      self.paneSignature = nil
      return false
    end

    local slots = petportModuleSlots()
    local accepted = {}
    local taken = {}

    for _, record in ipairs(records) do
      local slot = type(record) == "table" and tonumber(record.slot) or nil

      if slot == nil or slot < 1 or slot > slots then
        sb.logError("PETPORT %s refusing module set: slot %s outside 1..%s",
          stationUniqueId(), tostring(slot), tostring(slots))
        return refuse()
      end

      --  TWO RECORDS FOR ONE SLOT IS A MALFORMED PAYLOAD, not a last-one-wins
      --  merge. Silently keeping one would put the pane and the port one module
      --  apart with nothing to notice it.
      if taken[slot] then
        sb.logError("PETPORT %s refusing module set: slot %s appears twice",
          stationUniqueId(), tostring(slot))
        return refuse()
      end

      if not petportIsModuleItem(record.item) then
        sb.logError("PETPORT %s refusing module set: %s is not a module item",
          stationUniqueId(), sb.printJson(record.item))
        return refuse()
      end

      --  STORED AS A CLEAN RECORD rather than by keeping the payload's table.
      --  The message table is not ours and copying it here is what keeps a
      --  stray field out of the item's saved parameters forever.
      taken[slot] = true
      table.insert(accepted, { slot = slot, item = copy(record.item) })
    end

    self.petData.modules = accepted
    self.dirty = true
    self.paneSignature = nil

    --  NOT PUSHED FROM HERE. pushModuleEffects is signature-gated and runs from
    --  update, so clearing the signature is the whole of what this has to do --
    --  and it means the push has exactly one call site rather than two that can
    --  drift apart.
    self.pushedModuleEffects = nil

    sb.logInfo("PETPORT %s module set committed: %s of %s slot(s) filled",
      stationUniqueId(), sb.printJson(#accepted), sb.printJson(slots))
    return true
  end))

  --  FEED. One treat, consumed on drop if the unit has room for it.
  --
  --  NOT BUILT: nothing eats a treat yet -- that is the last gap between the
  --  flavor work and it mattering. Logged rather than silently dropped, so the
  --  wiring can be verified before there is anything on the far end of it.
  message.setHandler("petports_feedUnit", simpleHandler(function(payload)
    if type(payload) ~= "table" or payload.item == nil then return false end
    sb.logInfo("PETPORT %s feed requested with %s -- nothing consumes fuel yet",
      stationUniqueId(), sb.printJson(payload.item))
    return false
  end))

  --  PER-UNIT DISPLAY TOGGLES. These live on petData rather than on the port,
  --  because they describe the UNIT and have to travel with it when the item
  --  moves to another port.
  --
  --  DISPLAY ONLY, AND DOWN TO ONE FIELD. Three have left this table: `bubbles`
  --  was never specified and nothing read it, `sleep` duplicated
  --  `petports_allowSleep` (a MONSTERTYPE parameter, a property of the chassis
  --  this had no business shadowing), and `crosshairs` moved to the PORT -- see
  --  CROSSHAIRS_KEY.
  --
  --  WRITTEN WHOLESALE RATHER THAN MERGED, deliberately, which is also what
  --  retires the two dead fields from an already-lived-in item: the first
  --  toggle a player touches replaces the table and they are gone. A merge
  --  would carry them forever with nothing left to read them.
  message.setHandler("petports_setToggles", simpleHandler(function(payload)
    if self.petData == nil or type(payload) ~= "table" then return false end

    self.petData.toggles = {
      carried = payload.carried == true
    }
    self.dirty = true
    self.paneSignature = nil

    sb.logInfo("PETPORT %s toggles: %s", stationUniqueId(), sb.printJson(self.petData.toggles))
    return true
  end))

  --  PORT-LEVEL CONTROLS. These belong to the PORT, not the unit -- a network
  --  id means something whether or not anything is socketed, which is also why
  --  they sit above the divider in the pane and outside the empty-port overlay.
  --
  --  NOT BUILT. Networks derive correctly and no player can author one; this is
  --  the largest gap between what the design says and what is reachable in
  --  game. The handlers exist so the pane's wiring can be tested against
  --  something real before the feature lands.
  --  PORT ENABLED -- A KILL SWITCH FOR ONE PORT, AND IT PERSISTS.
  --
  --  STORED AS AN OBJECT PARAMETER, NOT ON petData. It belongs to the PORT: an
  --  emptied and re-socketed port stays switched off, and a unit carried to a
  --  different port is not carrying somebody else's off switch with it. That is
  --  also why it sits above the divider in the pane.
  --
  --  object.setConfigParameter IS ALREADY THE MOD'S PERSISTENCE ROUTE -- it is
  --  what the pane mirror is written through -- so this needs no new mechanism
  --  and survives a world reload for the same reason the mirror does.
  --
  --  DEFAULTS TO ON, WHICH DIVERGES FROM THE UPCYCLER ON PURPOSE. A machine
  --  defaults off because a freshly placed one would otherwise start converting
  --  a player's things unasked. A petport does nothing at all until a unit is
  --  socketed into it, so the equivalent caution is already built in, and a port
  --  that has to be switched on after placement is a support question.
  --
  --  NOTHING IS DESPAWNED FROM IN HERE. The flag is written and update()
  --  reconciles on its next tick -- one place that decides whether a unit should
  --  exist, rather than two that can disagree. Same reasoning as the module
  --  effect push.
  message.setHandler("petports_setPortEnabled", simpleHandler(function(payload)
    if type(payload) ~= "table" then return false end

    local enabled = payload.enabled == true
    object.setConfigParameter(ENABLED_KEY, enabled)

    --  ZEROED SO AN ENABLE IS PROMPT. Otherwise the unit comes back on whatever
    --  was left of RESPAWN_GRACE, which is a click that appears to do nothing.
    if enabled then self.spawnTimer = 0 end

    self.paneSignature = nil

    sb.logInfo("PETPORT %s port %s by player", stationUniqueId(),
      enabled and "ENABLED" or "DISABLED")
    return true
  end))

  --  CLAIM CROSSHAIRS. Same storage and same defaulting as the enabled switch.
  --
  --  NOTHING IS RETIRED FROM IN HERE. crosshairRefresh clears the markers on its
  --  next pass, so this writes the flag and the display follows -- one place
  --  that decides whether a marker should exist, which also covers a world
  --  loading with a port already switched off.
  message.setHandler("petports_setCrosshairs", simpleHandler(function(payload)
    if type(payload) ~= "table" then return false end

    local on = payload.enabled == true
    object.setConfigParameter(CROSSHAIRS_KEY, on)
    self.paneSignature = nil

    --  ZEROED SO THE MARKERS APPEAR PROMPTLY on a switch-on, rather than on
    --  whatever was left of CROSSHAIR_INTERVAL.
    self.crosshairTimer = 0

    sb.logInfo("PETPORT %s crosshairs %s by player", stationUniqueId(),
      on and "ON" or "OFF")
    return true
  end))

  --  PARTICIPATION. Same storage and same defaulting as the enabled switch, and
  --  the same division of labour: this writes, dispatch reads.
  --
  --  WRITTEN WHOLESALE, so a group the pane stops sending is a group that
  --  reverts to participating rather than one that silently keeps its last
  --  value with nothing left to change it.
  --
  --  A TASK ALREADY UNDER WAY IS LEFT ALONE, DELIBERATELY. These gate DISPATCH;
  --  cancelling in flight would strand a claim and drop a unit mid-errand,
  --  possibly holding cargo, to save it a few seconds of walking. The unit
  --  finishes and is simply not given another of that kind.
  message.setHandler("petports_setParticipation", simpleHandler(function(payload)
    if type(payload) ~= "table" then return false end

    --  NO farming KEY. It moved to the farming MODULE on 2026-08-30 and is
    --  stored on petData, not here -- see FARMING_CLASSES. A stored value from
    --  before that is simply never read again; nothing merges it forward,
    --  because the port-level switch no longer means anything.
    local set = {
      hauling = payload.hauling ~= false,
      sorting = payload.sorting ~= false,
      machines = payload.machines ~= false
    }

    object.setConfigParameter(PARTICIPATION_KEY, set)
    self.paneSignature = nil

    --  ZEROED SO AN OPT-IN IS PROMPT, matching the enabled switch. A port that
    --  has just been given a loop back should look for work now rather than on
    --  whatever was left of its work timer.
    self.workTimer = 0

    sb.logInfo("PETPORT %s participation: %s", stationUniqueId(), sb.printJson(set))
    return true
  end))

  --  MEDIC PATIENT CLASSES, WRITTEN TO petData AND NOT TO A CONFIG PARAMETER.
  --
  --  The four participation groups live on the PORT via object.setConfigParameter
  --  because they describe what this port contributes to the network. These
  --  describe how ONE MEDIC's supplies are allocated, so they belong to the pet
  --  and have to survive being carried to a different port.
  --
  --  ABSENT MEANS ALL ON, and the write below is the first thing that creates
  --  the table. petportMedicHeals reads `settings[class] ~= false`, so a unit
  --  that has never had this pane touched treats everybody -- a module socketed
  --  into an existing unit works immediately rather than looking broken until
  --  five boxes are ticked.
  --  FARMING ACTIVITIES. Same shape and same reasoning as petports_setMedic:
  --  written to petData so the preference travels with the pet, absent meaning
  --  all on, self.dirty so writeBackToItem persists it.
  message.setHandler("petports_setFarming", simpleHandler(function(payload)
    if type(payload) ~= "table" then return false end
    if self.petData == nil then return false end

    local set = {}
    for _, class in ipairs(FARMING_CLASSES) do
      set[class] = payload[class] ~= false
    end

    self.petData.farming = set
    self.dirty = true
    self.paneSignature = nil
    self.workTimer = 0

    sb.logInfo("PETPORT %s farming activities: %s", stationUniqueId(), sb.printJson(set))
    return true
  end))

  message.setHandler("petports_setMedic", simpleHandler(function(payload)
    if type(payload) ~= "table" then return false end
    if self.petData == nil then return false end

    local set = {}
    for _, class in ipairs(MEDIC_CLASSES) do
      set[class] = payload[class] ~= false
    end

    self.petData.medic = set

    --  self.dirty, exactly as petports_setToggles does. An earlier draft of this
    --  invented a self.petDataDirty that does not exist and asserted no flag was
    --  needed -- both wrong. writeBackToItem is gated on this.
    self.dirty = true
    self.paneSignature = nil

    --  ZEROED SO AN OPT-IN IS PROMPT, matching participation. Ticking a class
    --  back on should be looked at now rather than on whatever was left of the
    --  work timer.
    self.workTimer = 0

    sb.logInfo("PETPORT %s medic classes: %s", stationUniqueId(), sb.printJson(set))
    return true
  end))

  self.workTimer = 0
  self.task = nil

  --  The pane write this port last ACTED ON, accepted or refused. Echoed in the
  --  mirror; see petports_setModules.
  self.moduleToken = nil
  self.lastReject = nil
  self.lastRejectAt = 0
  self.recallFailures = 0
  self.unreachableFailures = 0
  self.taskAge = 0
  self.registryVersion = -1
  self.networkRects = nil
  self.vents = nil
  self.ventSignature = nil

  --  Route cache: "<destination tile>|<vent exit id>" -> bool.
  --
  --  Produced by UNITS, because only they can pathfind. Held HERE because a
  --  port is resident whenever the network is and survives reloads, while units
  --  respawn and would each have to rediscover everything.
  self.routeCache = {}

  --  workId -> { count = <failures>, until = <world.time()> }. In memory only:
  --  entity ids do not survive a reload, so neither should this.
  self.workFailures = {}

  --  Outcome from the unit. Reported by uniqueId because entity ids do not
  --  survive a reload and the unit may have respawned since dispatch.
  --  MID-TASK PROGRESS, WHICH IS ONLY EVER A COSMETIC.
  --
  --  taskReport says how a task ENDED. This says it is under way -- the unit has
  --  covered ground, so it found a route rather than still searching for one.
  --  That is the entire difference between the yellow marker and the green one,
  --  and there was no signal for it until now: dispatch and outcome were all the
  --  port ever heard.
  --
  --  DELIBERATELY INERT BEYOND THE MARKER. It sets no state the dispatcher
  --  reads, resets no timer, and cannot fail a task. A lost or duplicated
  --  progress message costs a colour, never a decision -- which is why it is
  --  fire-and-forget on the unit's side.
  message.setHandler("petports_taskProgress", simpleHandler(function(progress)
    if progress == nil or self.task == nil then return end
    if progress.id ~= self.task.id then return end
    if progress.phase ~= "moving" then return end

    if self.taskMoving then return end
    self.taskMoving = true

    --  REDRAW ON THE NEXT TICK, not on the next scheduled pass.
    --
    --  crosshairRefresh gates itself on CROSSHAIR_INTERVAL, so a message
    --  arriving just after a pass waited out most of half a second before the
    --  colour it caused was drawn. That is a fixed cost on the ONE transition
    --  a player is watching for, and the pass is cheap, so it is worth
    --  spending one early.
    --
    --  Zeroing the timer rather than calling crosshairRefresh directly: this
    --  runs inside a message handler, and the refresh spawns projectiles,
    --  writes claims and reads self.task. Letting update() own when that
    --  happens keeps it on one thread of control.
    self.crosshairTimer = 0

    sb.logInfo("PETPORT %s task %s is under way", stationUniqueId(), progress.id)
  end))

  message.setHandler("petports_taskReport", simpleHandler(function(report)
    if report == nil or self.task == nil then return end
    if report.id ~= self.task.id then return end

    sb.logInfo("PETPORT %s task %s %s: %s",
      stationUniqueId(), report.id, report.outcome,
      report.reason or "no detail")

    --  Before anything else: the unit may be handing over an item, and the
    --  world drop for it is already gone. Nothing below this may return early
    --  ahead of it.
    if report.cargo ~= nil then
      receiveCargo(report.cargo)
    end

    --  THE DONE-CLEANUP RUNS BEFORE THE ARRIVAL WORK, AND THE ORDER IS A FIX.
    --
    --  MEASURED 2026-08-29: a unit patrolled an upcycler at three trips a
    --  second, and every cycle logged "backing off for 1 seconds (failure 1)"
    --  -- the ladder never climbed. "Done" means the WALK succeeded; it says
    --  nothing about the delivery, which happens below and records its own
    --  failure through noteFailure. Sitting at the bottom, this cleanup erased
    --  that record microseconds after it was written, so the escalating
    --  backoff -- the thing that turns a broken delivery into a slow retry
    --  instead of a sprint -- was dead code on every arrival failure.
    --
    --  Up here it clears STALE failures from earlier attempts, which is its
    --  actual job, and anything the arrival work notes afterwards stands.
    --  unreachableFailures and the recall counter are reachability state and
    --  reaching the target is exactly what "done" attests, so they belong in
    --  the same early clear.
    if report.outcome == "done" then
      self.workFailures[report.id] = nil
      self.unreachableFailures = 0
      if report.id == "return:" .. stationUniqueId() then
        self.recallFailures = 0
      end
    else
      noteFailure(report.id, report.reason or "no detail")
    end

    --  Arrived at a deposit container. The port does the transfer, not the
    --  unit: the cargo has been on petData the whole time, so it never has to
    --  exist anywhere else and there is no second window to lose it in.
    --
    --  `only` NARROWS IT TO ONE ITEM, and is what makes a restock delivery a
    --  deposit task rather than a task type of its own. The unit's side of a
    --  delivery is identical to a deposit -- walk to a crate, stand there -- so
    --  reusing the type means petportsTaskAction needs no change at all and the
    --  proven walk-and-stand path is the one that runs.
    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "deposit" and self.task.id == report.id then
      if self.task.only ~= nil then
        depositCargoOnly(self.task.target, self.task.only)
      else
        depositCargo(self.task.target)
      end
    end

    --  Arrived at an upcycler. Same shape as deposit -- the unit only ever
    --  walked and stood, and the container work happens here -- but the
    --  transfer is slot-precise and re-checks the threshold, because this is
    --  the one destination that destroys what it receives.
    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "upcycle" and self.task.id == report.id then
      depositCargoToMachine(self.task.target, self.task.id)
    end

    --  Arrived at a crate holding a seed. Symmetric with deposit above: the
    --  container call happens HERE, on the port, so the unit never needs a
    --  container primitive of its own.
    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "withdraw" and self.task.id == report.id then
      withdrawSeed(self.task.target, self.task.seed, self.task.id,
        self.task.count)
    end

    --  Arrived at a crate holding over-quota stock. IDENTICAL to a tidy: take
    --  a slot-precise count out of the crate and onto the unit. What makes it a
    --  drain rather than housekeeping is only where the load goes next, and
    --  that is depositWork's decision, not this one's.
    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "drain" and self.task.id == report.id then
      withdrawMisfit(self.task.target, self.task.item, self.task.count,
        self.task.id, self.task.slot)
    end

    --  Arrived at a machine holding finished fuel. Same shape again -- the unit
    --  walked and stood, the container work happens here -- and slot-precise so
    --  only the output slot is ever touched.
    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "fuel" and self.task.id == report.id then
      withdrawMisfit(self.task.target, self.task.item, self.task.count,
        self.task.id, self.task.slot)
    end

    --  Arrived at a crate holding something that does not belong in it. Same
    --  shape as the withdraw above -- the unit only ever walks and stands, and
    --  the container call happens on the port.
    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "tidy" and self.task.id == report.id then
      withdrawMisfit(self.task.target, self.task.item, self.task.count,
        self.task.id, self.task.slot)
    end

    --  Arrived at a crate holding one item across more slots than it needs.
    --  Same shape as tidy above -- the unit only walks and stands, and the
    --  container work happens here.
    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "compact" and self.task.id == report.id then
      compactContainer(self.task.target)
    end

    --  Tiles were wetted. Spend one item per tile actually done.
    --
    --  COUNTED FROM THE REPORT, not from the task's tile list. A unit that ran
    --  out of walking time partway through the sweep did fewer tiles than it
    --  was given, and charging it for the whole run would quietly destroy
    --  liquid that is still in its cargo.
    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "water" and self.task.id == report.id then
      local watered = tonumber(report.watered) or 0

      for _ = 1, watered do
        spendSeed(self.task.item)
      end

      --  ITS OWN METRIC, NOT "moved" -- watering is farm work, not hauling,
      --  and folding it into the haul total hid it. Counted from the report
      --  for the same reason the spend is: tiles actually done, not tiles
      --  assigned. spendSeed itself stays metric-free; the task type here is
      --  the only thing that knows what the spend MEANT.
      metrics.add("watered", watered)

      sb.logInfo("PETPORT %s watering finished: %s tile(s), %s %s spent",
        stationUniqueId(), sb.printJson(watered), sb.printJson(watered),
        tostring(self.task.item))
    end

    --  A DOSE LANDED. Spend one medical good and start the network cooldown.
    --
    --  RECORDED HERE AND NOT AT DISPATCH, which is the whole reason the cooldown
    --  is trustworthy. A unit dispatched to a patient it never reaches has healed
    --  nobody, and marking them at dispatch would lock them out for two minutes
    --  over a trip that failed.
    --
    --  COUNTED FROM THE REPORT, like watering. The unit returns `dosed` only on
    --  the path where the burst actually spawned -- a patient who died, recovered
    --  or walked out of reach reports done with no dose, and costs nothing.
    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "medic" and self.task.id == report.id then
      local dosed = tonumber(report.dosed) or 0

      if dosed > 0 then
        spendSeed(self.task.item)
        petports_healRecord(report.patient or self.task.patient, MEDIC_DURATION)
        metrics.add("dosed", dosed)

        sb.logInfo("PETPORT %s medic finished: patient %s dosed, one %s spent, "
          .. "next dose for them in %ss",
          stationUniqueId(), sb.printJson(report.patient or self.task.patient),
          tostring(self.task.item), sb.printJson(MEDIC_DURATION))
      else
        --  NOT A FAILURE AND NOT SILENT. The trip happened and nothing was
        --  spent, which is the correct outcome but looks identical to a broken
        --  medic in a log that does not say so.
        sb.logInfo("PETPORT %s medic returned without dosing: %s",
          stationUniqueId(), tostring(report.reason))
      end
    end

    --  The crop went in the ground. Spend the seed and retire the intent.
    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "replant" and self.task.id == report.id then
      spendSeed(self.task.seed)

      --  Same split as watering above: planting is its own metric, and this
      --  branch is the one place that knows the spend put a crop in the ground.
      metrics.add("planted", 1)

      petports_replantClear(self.task.target, "replanted")
    end

    --  A HARVEST THAT LEFT A HOLE BECOMES AN INTENT.
    --
    --  Decided here rather than on the unit because the port is the thing that
    --  can still answer it: entityExists on a crop that reset is true, on one
    --  that was destroyed is false, and that single test is the whole
    --  resetToStage distinction without reading any config.
    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "harvest" and self.task.id == report.id then
      --  A COMPLETED HARVEST IS ONE, whatever it dropped -- the metric counts
      --  executions of the task, and the yield is the treasure pool's business.
      metrics.add("harvested", 1)

      if not world.entityExists(self.task.target)
         and self.task.targetName ~= nil then
        petports_replantSet(self.task.position, self.task.targetName,
          stationUniqueId())
      end
    end

    --  A completed livestock collection. Same counting rule as the crop
    --  harvest above: one per execution, however many items the animal shed.
    if report.outcome == "done" and self.task ~= nil
       and self.task.type == "animal" and self.task.id == report.id then
      metrics.add("livestock", 1)
    end

    --  The done-cleanup that used to sit here moved ABOVE the delivery
    --  branches -- see the note at the top of this handler. A failure noted
    --  during the arrival work must survive to drive its backoff.

    petports_claimRelease(self.task.id, stationUniqueId())
    self.task = nil
  end))

  --  A unit reporting what it learned from a probe.
  message.setHandler("petports_learnedRoute", simpleHandler(function(learned)
    if learned == nil or learned.key == nil then return end
    --  Entries carry when they were learned so the unit can expire them; see
    --  ROUTE_TTL_FALSE in petports_contract.lua. The port only stores and
    --  forwards them, it does not interpret them.
    local held = self.routeCache[learned.key]
    if type(held) == "table" and held.r == learned.reachable then return end

    self.routeCache[learned.key] = {
      r = learned.reachable,
      t = learned.at or world.time()
    }
    self.routeDirty = true
  end))

  object.setInteractive(true)
end

--  DESTRUCTION ONLY. uninit fires on world unload as well, so anything that
--  should survive a reload must not be torn down there.
function die()
  stopResidency()

  --  DESTRUCTION ONLY. From uninit this would wipe the network on every world
  --  unload, and every port would come back believing it stands alone.
  petports_registryRemove(stationUniqueId())
end

function uninit()
  --  Both destruction AND world unload reach here. Releasing the claim is right
  --  either way: on unload it would be orphaned anyway, and this port clears
  --  its own claims on the next init regardless.
  abandonTask("petport unloading")

  --  A marker outliving the port that owns it would sit over a drop nothing is
  --  coming for -- worse than no marker, because it asserts something false.
  --  The projectiles carry a timeToLive as well, so this is the tidy path and
  --  that is the backstop.
  crosshairClear()

  --  Petport unloading or being broken: put the unit back in its item so
  --  nothing is lost. This is why a unit does not survive the player beaming
  --  away -- the item carries the state, not the monster.
  saveAndDespawn()
end

--------------------------------------------------------------------------------
--  ANCHOR CONTRACT (see groundPet.lua setAnchor / findAnchor)
--------------------------------------------------------------------------------

function hasPet()
  return self.petId ~= nil and world.entityExists(self.petId)
end

function setPet(entityId, params)
  if self.petId ~= nil and self.petId ~= entityId then
    return false
  end
  self.petId = entityId

  --  groundPet.lua pushes its own state here ONCE PER SECOND, via updateAnchor
  --  re-calling setAnchor. So this runs constantly and must not mark the item
  --  dirty on its own -- see WRITE_INTERVAL above.
  --
  --  Durable state (known players, food likings, seed) changes rarely and is
  --  worth an immediate write. Resource levels drift every tick and are not.
  if params and self.petData then
    self.petData.storage = self.petData.storage or {}

    --  Seed is stable for the life of the monster, so it is safe to take at any
    --  time -- including from the echo below.
    if params.seed and params.seed ~= self.petData.seed then
      self.petData.seed = params.seed
      self.dirty = true
    end

    --  IGNORE THE FIRST CALLBACK AFTER A SPAWN.
    --
    --  spawnPet calls setAnchor immediately, and groundPet answers by pushing
    --  its state straight back here -- state it has only just initialized. That
    --  is an echo, not news. Accepting it overwrites the item with whatever the
    --  unit came up at, so a restore that silently failed would also DESTROY
    --  the saved values it failed to restore. Observed exactly that: defaults
    --  written into the item 23ms after spawn.
    if self.spawning then
      self.spawning = false
      return true
    end

    if params.foodLikings and not compare(params.foodLikings, self.petData.storage.foodLikings) then
      self.petData.storage.foodLikings = params.foodLikings
      self.dirty = true
    end

    if params.knownPlayers and not compare(params.knownPlayers, self.petData.storage.knownPlayers) then
      self.petData.storage.knownPlayers = params.knownPlayers
      self.dirty = true
    end

    --  Kept current in memory, flushed on the slow timer or at despawn.
    self.petData.storage.petResources = params.petResources or self.petData.storage.petResources
  end
  return true
end

--------------------------------------------------------------------------------
--  ITEM <-> PET
--------------------------------------------------------------------------------

--  The socketed item, or nil. Slot 0 because slotCount is 1.
--
--  ASSIGNED, NOT DECLARED. It is forward-declared with the constants so the
--  message handlers above can reach it -- see the note there.
socketedItem = function()
  local item = world.containerItemAt(entity.id(), 0)
  if item == nil or item.name == nil then return nil end
  return item
end

--  Just the seed off a socketed item, without the full merge. Called every
--  tick by the swap check, so it must not do root.itemConfig work (or trace).
local function itemSeed(item)
  if item == nil or item.parameters == nil then return nil end
  if item.parameters.petData == nil then return nil end
  return item.parameters.petData.seed
end

--  Pet definition from the item, merging the item's own instance parameters
--  over the base config. A found item may carry only monsterType; a lived-in
--  one carries status and storage too.
local function petDataFrom(item)
  local base = root.itemConfig(item)
  local data = {}
  if base and base.config and base.config.petData then
    util.mergeTable(data, copy(base.config.petData))
  end
  if item.parameters and item.parameters.petData then
    util.mergeTable(data, copy(item.parameters.petData))
  end
  if data.monsterType == nil then return nil end

  --  THE FIRST POINT CARGO COULD BE LOST: what the item actually handed over,
  --  after the base config merge, before anything else touches it.
  cargoTrace("petDataFrom: off item", data.cargo)

  trace("read from item", data)
  return data
end

function spawnPet()
  cargoTrace("spawnPet: entry", self.petData and self.petData.cargo)
  if self.petData == nil or self.petData.monsterType == nil then return end
  if self.petId ~= nil and world.entityExists(self.petId) then return end

  local spawnPosition = object.toAbsolutePosition(config.getParameter("petSpawnOffset", {0, 2}))

  --  THESE ARE TOP-LEVEL PARAMETERS, NOT A scriptConfig SUB-TABLE.
  --
  --  petspawner.lua looks like it nests them, but only looks like it:
  --  Pet:_scriptConfig(parameters) returns `parameters` unchanged, so the local
  --  named scriptConfig IS the parameters table. Everything assigned to it
  --  lands at the top level of what reaches world.spawnMonster. Nested under a
  --  literal scriptConfig key, none of it is reachable via config.getParameter
  --  and the engine never sees initialStatus / initialStorage at all.
  local parameters = {
    --  Ship pets belong to the ship, not the world's threat level.
    level = math.max(world.threatLevel(), world.getProperty("ship.level") or 0, 1),

    --  Persistent so the unit is not garbage collected while the player is
    --  elsewhere on the ship; the petport owns its lifetime instead.
    persistent = true,

    --  Never yanked around by relocation logic meant for wild creatures.
    relocatable = false,

    --  NO damageTeamType HERE, DELIBERATELY -- THE CHASSIS OWNS IT.
    --
    --  This line used to read `damageTeamType = "ghostly"`, and a spawn
    --  parameter BEATS THE MONSTERTYPE. So when all four chassis were moved to
    --  `friendly` on 2026-08-30, nothing changed: the files were correct and
    --  this overwrote them on every spawn. Freshly spawned units kept reporting
    --  ghostly/2 while root.monsterParameters read the new value happily,
    --  because one is entity-level and the other is type-level.
    --
    --  THE VALUE BELONGS TO THE CHASSIS, NOT TO THE SPAWNER. A third-party unit
    --  should be able to declare its own team without this file having an
    --  opinion, and stating it in two places is how the two disagree.
    --  How the pet reports home. It messages the petport rather than the
    --  petport polling it, which keeps the item current even if the pet dies
    --  while the player is watching something else.
    stationUniqueId = stationUniqueId(),

    --  Resume where it left off.
    --
    --  initialStatus / initialStorage are kept because vanilla sets them, but
    --  OBSERVED NOT TO WORK for seeding a monster's storage table: a unit
    --  spawned with a populated initialStorage still came up with
    --  config-default petResources and an empty knownPlayers. Whatever consumes
    --  these, it is not what groundPet.lua reads on init.
    initialStatus = copy(self.petData.status) or {},
    initialStorage = copy(self.petData.storage) or {},

    petName = self.petData.petName
  }

  --  THE ROUTE THAT ACTUALLY RESTORES STATE.
  --
  --  groundPet.lua's init reads
  --
  --    storage.petResources = storage.petResources or config.getParameter("petResources")
  --    storage.knownPlayers = storage.knownPlayers or config.getParameter("knownPlayers", {})
  --    storage.foodLikings  = storage.foodLikings  or config.getParameter("foodLikings", {})
  --
  --  and spawn parameters ARE config parameters -- that path is proven, it is
  --  how level, persistent and anchorName already arrive. So saved values are
  --  passed as parameters and picked up by the fallback branch, since a freshly
  --  spawned monster's storage is empty.
  --
  --  nil entries simply do not appear in the table, leaving the monstertype's
  --  own defaults in play for a brand new unit.
  local saved = self.petData.storage or {}
  parameters.petResources = copy(saved.petResources)
  parameters.knownPlayers = copy(saved.knownPlayers)
  parameters.foodLikings = copy(saved.foodLikings)

  --  Seed the anchor position so the unit can self-anchor through vanilla's own
  --  recovery path if the setAnchor call below is ever missed. Belt and braces:
  --  the direct call has not failed in testing, but its success depends on the
  --  monster's script having initialized by the time spawnMonster returns.
  parameters.initialStorage.anchorPosition = entity.position()

  --  VERIFY: whether world.spawnMonster honours a seed parameter. If it does,
  --  this pins the monsterpart variant across respawns; if not, it is inert and
  --  the variant needs pinning some other way.
  if self.petData.seed then
    parameters.seed = self.petData.seed
  end

  --  MATERIALISE ON ARRIVAL, AS A SPAWN PARAMETER AND NOT AS A CALL.
  --
  --  This was a callScriptedEntity after spawnMonster, and the unit rendered
  --  once at full size before it landed. A round trip is always at least a tick
  --  late; a spawn parameter is read inside the monster's own init, which is
  --  what vanilla's relocator does with `wasRelocated`. See the init wrapper in
  --  petports_contract.lua.
  --
  --  TOP LEVEL, NOT UNDER initialStorage -- see the note above about what
  --  actually reaches world.spawnMonster, and fact.unit.initialstorage for why
  --  the storage table is not a route for this.
  parameters.petports_materialise = true

  trace("spawning with initialStorage", parameters.initialStorage)

  self.petId = world.spawnMonster(self.petData.monsterType, spawnPosition, parameters)
  if self.petId then
    self.spawning = true
    self.statusTimer = STATUS_INTERVAL

    --  Hand the pet its anchor, exactly as techstation.lua does. groundPet.lua
    --  calls back into setPet from here.
    world.callScriptedEntity(self.petId, "setAnchor", entity.id())
  else
    trace("spawnMonster returned nil for type", self.petData.monsterType)
  end
end

--  skipWrite: set when the unit is being put away because a DIFFERENT item is
--  now in the slot. Writing back then would stamp the outgoing unit's state
--  onto the incoming item -- the exact corruption the swap check exists to
--  prevent. The outgoing item is already in the player's inventory and out of
--  reach either way.
function saveAndDespawn(skipWrite)
  if self.petId and world.entityExists(self.petId) then
    --  Ask for final state before removing it. Best effort: if the pet is
    --  already gone the item simply keeps the last state we heard about.
    local ok, state = pcall(world.callScriptedEntity, self.petId, "petports_store")
    trace("petStore returned", ok and state or nil)

    cargoTrace("saveAndDespawn: before store merge", self.petData and self.petData.cargo)

    if ok and state and self.petData then
      self.petData.status = state.status or self.petData.status
      self.petData.storage = state.storage or self.petData.storage
    end

    cargoTrace("saveAndDespawn: after store merge", self.petData and self.petData.cargo)

    --  Defined in petports_contract.lua on the monster side. Note a
    --  bare callScriptedEntity to an UNDEFINED function returns nil silently --
    --  it does not raise -- which is how the socket-cycle unit leak went
    --  unnoticed before that script existed.
    world.callScriptedEntity(self.petId, "petports_despawn")

    --  HELD PAST self.petId. The unit is no longer ours to command -- it is
    --  stunned, suppressed and dying on its own clock -- but it is still in the
    --  world, and the door above must not close over it.
    self.fadingPetId = self.petId
  end
  --  No-op when the unit is being put away because the ITEM was removed -- it
  --  has already left the container. Still worth calling: this path also runs
  --  from uninit on world unload, where the item is present.
  if not skipWrite then
    writeBackToItem()
  end

  self.petId = nil
  self.spawning = false
end

--  WRITE CARGO THROUGH IMMEDIATELY, not on the slow timer.
--
--  Everything else on petData is RE-DERIVABLE -- resource levels, known players,
--  food likings all come back from the live unit, so deferring those to
--  WRITE_INTERVAL costs nothing worse than a stale number. Cargo is not like
--  that. takeItemDrop has already destroyed the world drop, so between the
--  handover and the write the item exists in exactly one place: this port's RAM.
--  A crash, an unload, or a player mining the port in that window loses it.
--
--  Cheap by nature: this fires once per pickup, and a pickup involves a unit
--  walking somewhere. It cannot become the per-tick write storm WRITE_INTERVAL
--  exists to prevent.
--
--  dirty stays set first, so if the write cannot land -- no socketed item,
--  which happens if the unit item was pulled mid-task -- the normal timer
--  retries instead of the change being dropped.
local function flushCargo()
  self.dirty = true
  writeBackToItem()
  self.writeTimer = WRITE_INTERVAL

  --  DISPATCH ON THE NEXT TICK, not on the next work interval.
  --
  --  A unit that has just picked something up should be walking to a chest
  --  immediately. Waiting out WORK_INTERVAL is a second of a loaded unit
  --  standing still for no reason, and it reads as the port having missed the
  --  handover entirely.
  --
  --  Zeroing the timer rather than calling dispatchWork here on purpose: the
  --  report handler is still unwinding, self.task is not cleared until it
  --  finishes, and dispatching into that would collide with the task being
  --  closed.
  self.workTimer = 0
end

--------------------------------------------------------------------------------
--  BEACONS AND CONTAINERS
--------------------------------------------------------------------------------
--
--  A CONTAINER DECLARES ITS OWN PURPOSE BY ITS CONTENTS. Drop a beacon item in
--  a chest and the chest becomes a deposit target; take it out and it stops.
--
--  Deliberately not a registry of designated containers. A registry has to be
--  kept in step with a world where chests are mined, moved, and replaced, and
--  it leaks an entry every time that goes wrong. Reading the container answers
--  the question from the only authority that cannot disagree with itself.

--  What behaviour, if any, does this item declare?
--
--  Parameters first, then config -- the same precedence petData uses, so a
--  configured beacon can override its template later without changing how it
--  is found.
local function beaconBehaviorOf(item)
  if item == nil or item.name == nil then return nil end

  --  OFF IS INVISIBLE, NOT A SEPARATE STATE.
  --
  --  A disabled beacon is not "a beacon the port ignores" -- it is not a
  --  beacon at all as far as everything downstream is concerned. That is what
  --  lets a player park spares in a chest: an off beacon is an ordinary item,
  --  it tasks nothing, and the scan walks straight past it to whatever else is
  --  in the container.
  --
  --  Instance parameters only. There is no config default here on purpose --
  --  a beacon that has never been opened has no parameter and is ON, which is
  --  safe because a loose beacon can only ever land in a container that was
  --  ALREADY a target. It cannot task a new one.
  if item.parameters ~= nil and item.parameters[BEACON_ENABLED_KEY] == false then
    return nil
  end

  if item.parameters ~= nil and item.parameters[BEACON_KEY] ~= nil then
    return item.parameters[BEACON_KEY]
  end

  --  Unguarded on purpose. An item in a container HAS a config -- Starbound
  --  fails world load outright on a missing item definition rather than
  --  degrading, so a world holding one never reaches this line.
  return root.itemConfig(item).config[BEACON_KEY]
end

--  Every container in coverage that holds a beacon.
--  Does this object declare a tag?
--
--  world.getObjectParameter reads the object's CONFIG, so anything declared in
--  the .object file is visible -- no descriptor, no root.itemConfig, and no
--  dependence on what happens to be in the container.
local function objectHasTag(id, tag)
  local ok, tags = pcall(world.getObjectParameter, id, "itemTags")
  if not ok or type(tags) ~= "table" then return false end

  for _, candidate in ipairs(tags) do
    if candidate == tag then return true end
  end

  return false
end

--  A machine in coverage, or nil.
--
--  READ FRESH EVERY SCAN, deliberately. Rules are edited in the machine's own
--  pane and written straight to its parameters, so re-reading is how an edit
--  takes effect -- exactly as a beacon filter does. Caching would introduce a
--  staleness window on the one thing in the mod that destroys items.
local function machineAt(id)
  local ok, kind = pcall(world.getObjectParameter, id, MACHINE_KEY)
  if not ok or type(kind) ~= "string" or kind == "" then return nil end

  local machine = {
    id = id,
    kind = kind,
    position = world.entityPosition(id),
    name = world.entityName(id),
    enabled = false,
    rules = {}
  }

  local okEnabled, enabled = pcall(world.getObjectParameter, id, MACHINE_ENABLED_KEY)

  --  ABSENCE IS OFF. A machine that has never been configured has no parameter
  --  at all, and the whole off-on-placement guarantee depends on reading that
  --  as false rather than as missing data.
  machine.enabled = okEnabled and enabled == true

  local okRules, rules = pcall(world.getObjectParameter, id, MACHINE_RULES_KEY)

  --  TYPE-CHECKED ON EVERY READ, NOT NIL-CHECKED. A cleared parameter is stored
  --  as an explicit JSON null rather than a removed key, and a null is not a
  --  table.
  if okRules and type(rules) == "table" then
    for _, rule in ipairs(rules) do
      if type(rule) == "table" and type(rule.item) == "string" and rule.item ~= "" then
        table.insert(machine.rules, {
          item = rule.item,
          max = tonumber(rule.max) or 0,

          --  ABSENT MEANS "ASK THE MANIFEST", AND ONLY false EXCLUDES.
          --
          --  Stored as an exclusion rather than an inclusion, the same way the
          --  filter rules are: a rule written before this feature existed, or
          --  one whose item a mod later adds to a flavor, then routes as a
          --  reagent by default instead of needing the player to find it.
          reagent = rule.reagent,

          --  SAME SHAPE FOR THE BURNER. Absent means the burner is open to
          --  this item; only an explicit false closes it. A rule written
          --  before the burn checkbox existed keeps burning, unchanged.
          burn = rule.burn
        })
      end
    end
  end

  return machine
end

local function scanContainers()
  local rects = self.networkRects
  if rects == nil or #rects == 0 then rects = { coverageRect() } end

  local found = {}
  local seen = {}
  local containers = 0

  --  THE CENSUS: how many of each item name the network holds.
  --
  --  NEARLY FREE, which is why it lives here rather than in a pass of its own.
  --  This loop already calls world.containerItems on every container in every
  --  network rect; tallying names on the way past is arithmetic on data already
  --  in hand. A separate scan would double the queries to learn nothing new.
  --
  --  DEPOSIT CRATES ONLY. Restock crates are excluded because a request IS the
  --  correct amount to hold by definition -- counting a maintained stock as
  --  surplus would have the network fetch items in order to destroy them.
  --  Unbeaconed chests are excluded because they are the player's own business,
  --  and a mushroom collection in a personal chest is not network surplus.
  --  Machines are excluded because their contents are in transit.
  local census = {}
  local censusStacks = 0
  local machines = {}

  for _, rect in ipairs(rects) do
    local ids = world.entityQuery({ rect[1], rect[2] }, { rect[3], rect[4] }, {
      includedTypes = { "object" }
    })

    for _, id in ipairs(ids) do
      if not seen[id] then
        seen[id] = true

        local machine = machineAt(id)
        if machine ~= nil then table.insert(machines, machine) end

        --  containerSize is the test for "is this a container". Checking the
        --  object name against a list would miss every modded chest, and there
        --  are a lot of modded chests.
        local okSize, size = pcall(world.containerSize, id)

        if okSize and size ~= nil and size > 0 then
          containers = containers + 1

          local okItems, items = pcall(world.containerItems, id)
          if okItems and items ~= nil then
            --  SLOT ORDER, EXPLICITLY.
            --
            --  containerItems is keyed by SLOT and empty slots leave holes, so
            --  ipairs stops at the first gap and pairs is the only way to see
            --  every item. But pairs order is nondeterministic, and with two
            --  beacons in one container that made the winner change between
            --  scans -- a chest that silently swapped roles every five seconds
            --  and would have been diagnosed as anything but this.
            --
            --  Collect the keys, sort them, then walk. First ENABLED beacon in
            --  slot order decides the container, every time.
            local slots = {}
            for slot in pairs(items) do
              table.insert(slots, slot)
            end
            table.sort(slots)

            --  A MACHINE'S SLOTS ARE NOT STORAGE.
            --
            --  An upcycler is a container, so without this a beacon dropped
            --  into its input would make it a sorting destination and units
            --  would file cargo into the one device that destroys things.
            --
            --  LOUD, NOT SILENT. A beacon that has visibly stopped working is
            --  worth explaining -- a player who put one there had a reason, and
            --  "it does nothing and nobody said why" is the worst of the three
            --  possible behaviours. Change-gated on the container id so it says
            --  it once per machine rather than every scan forever.
            local ignoresBeacons = objectHasTag(id, IGNORE_BEACONS_TAG)

            if ignoresBeacons then
              local offender = nil

              for _, slot in ipairs(slots) do
                if beaconBehaviorOf(items[slot]) ~= nil then
                  offender = items[slot].name
                  break
                end
              end

              self.beaconInMachine = self.beaconInMachine or {}

              if offender ~= nil and self.beaconInMachine[id] ~= offender then
                self.beaconInMachine[id] = offender
                sb.logError("PETPORT %s: a %s is sitting in %s, which is a "
                  .. "petports machine -- beacons inside machines are IGNORED. "
                  .. "Machine slots are not storage; take it back out.",
                  stationUniqueId(), tostring(offender),
                  tostring(world.entityName(id)))
              elseif offender == nil then
                self.beaconInMachine[id] = nil
              end
            end

            for _, slot in ipairs(ignoresBeacons and {} or slots) do
              local item = items[slot]
              local behavior = beaconBehaviorOf(item)

              if behavior ~= nil then
                --  THE FILTER RIDES ALONG, FOR FREE.
                --
                --  world.containerItems returns full descriptors including
                --  parameters, so the beacon's filter is already in hand here.
                --  No registry, no second lookup, nothing to keep in sync --
                --  and a filter edited in the pane takes effect on the next
                --  scan without anyone being told.
                --
                --  nil for a beacon that has never been configured, and nil
                --  means accept everything, which is what the unconditional
                --  deposit beacon did before filters existed.
                local filter = nil
                if item.parameters ~= nil then
                  filter = item.parameters[BEACON_FILTER_KEY]
                end

                --  THE REQUESTS RIDE ALONG THE SAME WAY THE FILTER DOES, and
                --  for the same reason: containerItems already handed us the
                --  full descriptor, so a quota edited in the pane takes effect
                --  on the next scan with no registry and nothing to keep in
                --  sync.
                --
                --  TYPE-CHECKED THROUGHOUT, NOT NIL-CHECKED. A cleared field is
                --  stored as an explicit JSON null rather than a removed key --
                --  see setInstanceValue in petports_beacon.lua -- so a migrated
                --  beacon reads back nulls where its old single request used to
                --  be, and a null is neither a string nor a table.
                local requests = nil

                if behavior == "restock" and item.parameters ~= nil then
                  local stored = item.parameters[BEACON_REQUESTS_KEY]

                  if type(stored) == "table" then
                    requests = {}

                    for _, request in ipairs(stored) do
                      if type(request) == "table"
                         and type(request.item) == "string"
                         and request.item ~= "" then
                        table.insert(requests, {
                          item = request.item,
                          min = tonumber(request.min) or 1,
                          max = tonumber(request.max) or 1
                        })
                      end
                    end
                  else
                    --  LEGACY SINGLE REQUEST. A beacon configured before the
                    --  list existed keeps working; the pane rewrites it as a
                    --  one-entry list the next time it is opened.
                    local wanted = item.parameters[BEACON_ITEM_KEY]

                    if type(wanted) == "string" and wanted ~= "" then
                      requests = { {
                        item = wanted,
                        min = tonumber(item.parameters[BEACON_MIN_KEY]) or 1,
                        max = tonumber(item.parameters[BEACON_MAX_KEY]) or 1
                      } }
                    end
                  end

                  --  An empty list is no list. Everything downstream tests for
                  --  a table and then walks it, so leaving an empty one behind
                  --  would make "configured with nothing" and "not configured"
                  --  two states that behave identically but read differently.
                  if requests ~= nil and #requests == 0 then requests = nil end
                end

                table.insert(found, {
                  id = id,
                  position = world.entityPosition(id),
                  behavior = behavior,
                  name = world.entityName(id),
                  filter = filter,
                  requests = requests,

                  --  The deciding beacon's slot. Eviction needs it: a beacon
                  --  rarely matches its own crate's filter, and without the
                  --  exemption a crate hauls away its own configuration.
                  beaconSlot = slot
                })

                --  TALLY, NOW THAT THE CRATE'S ROLE IS KNOWN.
                --
                --  It has to happen here rather than in the walk above, because
                --  whether this container counts depends on the behaviour of a
                --  beacon that might sit in its last slot. Deposit crates only;
                --  see the census comment at the top of this function.
                --
                --  SUMMED BY NAME ACROSS DIFFERING PARAMETERS, which matches
                --  how rules match -- a rule is a pure function of a name, so
                --  the count has to be too. The only items this reads oddly for
                --  are genuinely polymorphic one-offs, and nobody sorts two
                --  hundred music sheets by song title.
                if behavior == "deposit" then
                  for _, tallySlot in ipairs(slots) do
                    --  THE DECIDING BEACON IS NOT INVENTORY. Counting a crate's
                    --  own configuration as network stock would be wrong in the
                    --  same way as counting the machine's input slot.
                    if tallySlot ~= slot then
                      local tallied = items[tallySlot]

                      if type(tallied) == "table"
                         and type(tallied.name) == "string" then
                        census[tallied.name] = (census[tallied.name] or 0)
                          + (tallied.count or 0)
                        censusStacks = censusStacks + 1
                      end
                    end
                  end
                end

                --  One ENABLED beacon decides a container. A second is the
                --  player's business, not ours -- and a disabled one never got
                --  here, so it cannot shadow an enabled beacon below it.
                break
              end
            end
          end
        end
      end
    end
  end

  return found, containers, census, censusStacks, machines
end

--  THE CENSUS READOUT. REPORTS, DECIDES NOTHING.
--
--  Nothing acts on any of this yet -- no routing, no drain, no dispatch change.
--  That is deliberate: the numbers here decide what gets fed into a machine
--  that destroys items, and they should be read off a real base before they are
--  allowed to move anything.
--
--  DELIBERATELY VERBOSE. Every rule prints every scan it changes, with the
--  count, the threshold, the surplus and the verdict, because a wrong number
--  found in one pass is worth more than a tidy log. This gets gated down once
--  routing is trusted; until then, fail loudly.
local function reportCensus(census, censusStacks, machines)
  local distinct = 0
  for _ in pairs(census) do distinct = distinct + 1 end

  --  THE TOTALS LINE SEPARATES TWO FAILURES THAT LOOK IDENTICAL. "No rule is
  --  over threshold" and "the census saw nothing at all" produce the same
  --  silence otherwise, and they have completely different causes.
  local totals = string.format("%s name(s) across %s stack(s), %s machine(s)",
    tostring(distinct), tostring(censusStacks), tostring(#machines))

  local lines = {}

  for _, machine in ipairs(machines) do
    if #machine.rules == 0 then
      table.insert(lines, string.format("%s@%s,%s [%s] no rules",
        tostring(machine.kind),
        tostring(math.floor(machine.position[1])),
        tostring(math.floor(machine.position[2])),
        machine.enabled and "on" or "OFF"))
    end

    for _, rule in ipairs(machine.rules) do
      local held = census[rule.item] or 0
      local surplus = held - rule.max

      --  STRICTLY GREATER, so a threshold of N means the network may hold
      --  exactly N. "Upcycle above this many" has to leave N reachable and
      --  stable, or a rule set to 500 would sit forever oscillating at 499.
      table.insert(lines, string.format("%s@%s,%s [%s] %s held %s max %s -> %s",
        tostring(machine.kind),
        tostring(math.floor(machine.position[1])),
        tostring(math.floor(machine.position[2])),
        machine.enabled and "on" or "OFF",
        tostring(rule.item), tostring(held), tostring(rule.max),
        surplus > 0 and ("OVER by " .. tostring(surplus)) or "under"))
    end
  end

  table.sort(lines)

  local report = totals .. " || " .. (#lines == 0 and "no machine rules"
    or table.concat(lines, " || "))

  --  Change-gated on the WHOLE report, so a count ticking up by one prints.
  --  That is a lot of lines while a unit is ferrying cargo, and it is meant to
  --  be: this is the pass where the arithmetic gets checked.
  if report == self.censusReport then return end
  self.censusReport = report

  sb.logInfo("PETPORT %s census: %s", stationUniqueId(), report)
end

local function refreshBeacons(dt)
  self.beaconTimer = (self.beaconTimer or 0) - dt
  if self.beaconTimer > 0 then return end
  self.beaconTimer = BEACON_INTERVAL

  local found, containers, census, censusStacks, machines = scanContainers()

  self.beacons = found
  self.census = census
  self.machines = machines

  --  Change-gated on the SIGNATURE, not the count. Two chests swapping roles
  --  keeps the count identical and is exactly the event worth seeing; and at
  --  one scan every five seconds forever, an unconditional line is noise.
  local parts = {}
  for _, beacon in ipairs(found) do
    --  THE REQUESTS ARE PART OF THE SIGNATURE, so re-quotaing a crate in the
    --  pane logs a line rather than passing silently. Behaviour alone would
    --  make "wants 500 hazard" and "wants 2000 dirt" identical.
    local what = tostring(beacon.behavior)

    if beacon.requests ~= nil then
      local wants = {}

      for _, request in ipairs(beacon.requests) do
        table.insert(wants, string.format("%s/%s-%s", tostring(request.item),
          tostring(request.min), tostring(request.max)))
      end

      what = what .. ":" .. table.concat(wants, ",")
    end

    table.insert(parts, string.format("%s@%s,%s=%s", tostring(beacon.id),
      tostring(math.floor(beacon.position[1])),
      tostring(math.floor(beacon.position[2])),
      what))
  end
  table.sort(parts)
  local signature = table.concat(parts, " ")

  if signature ~= self.beaconSignature then
    self.beaconSignature = signature
    sb.logInfo("PETPORT %s beacons: %s of %s container(s) in coverage -- %s",
      stationUniqueId(), sb.printJson(#found), sb.printJson(containers),
      signature == "" and "none" or signature)
  end

  reportCensus(census, censusStacks, machines)
end

--  Beacons matching a behaviour, nearest first. The deposit task will want the
--  nearest one it can actually reach; nearest-first is the order to try.
function petports_beaconsFor(behavior)
  local matches = {}
  local origin = entity.position()

  for _, beacon in ipairs(self.beacons or {}) do
    if beacon.behavior == behavior and world.entityExists(beacon.id) then
      table.insert(matches, beacon)
    end
  end

  table.sort(matches, function(a, b)
    return world.magnitude(origin, a.position) < world.magnitude(origin, b.position)
  end)

  return matches
end

--  CARGO HANDOVER.
--
--  Lives on petData, so writeBackToItem persists it with everything else and no
--  new write path is needed. Deliberately NOT routed through the monster's
--  storage table: that syncs via setAnchor's params echo, which whitelists
--  specific fields and IGNORES the first callback after a spawn to avoid
--  overwriting a restore. Suppression is right for state the unit re-derives and
--  wrong for an item that exists exactly once.
--
--  Cargo is also not handed to the monster on spawn. The port owns it; the unit
--  is a courier, not a container.
--  GLOBAL, not local, and that is load-bearing. The petports_taskReport handler
--  is registered in init() -- earlier in the file than this definition -- so a
--  `local function` here is not in scope at the call site and resolves to nil.
--  Globals resolve at call time, which is why writeBackToItem below is one too.
function receiveCargo(item)
  if item == nil or item.name == nil then return end

  if self.petData == nil then
    --  Cargo with nowhere to go. The world drop is already destroyed, so this
    --  is a real item loss and it gets logged as an error rather than dropped
    --  silently -- the whole point of tracing this path.
    sb.logError("PETPORT %s received cargo with no petData -- ITEM LOST: %s",
      stationUniqueId(), sb.printJson(item))
    return
  end

  cargoTrace("receiveCargo: before", self.petData.cargo)

  self.petData.cargo = self.petData.cargo or {}

  --  MERGE INTO AN EXISTING STACK where the descriptor matches. Fifty pickups
  --  of the same block should be one entry of fifty, not fifty entries -- this
  --  goes into item parameters, and parameters are serialised with the item
  --  every write.
  for _, held in ipairs(self.petData.cargo) do
    if held.name == item.name and compare(held.parameters, item.parameters) then
      held.count = (held.count or 1) + (item.count or 1)

      sb.logInfo("PETPORT %s cargo +%s %s (stack now %s, %s stack(s) held)",
        stationUniqueId(), sb.printJson(item.count or 1), tostring(item.name),
        sb.printJson(held.count), sb.printJson(#self.petData.cargo))

      flushCargo()
      return
    end
  end

  table.insert(self.petData.cargo, {
    name = item.name,
    count = item.count or 1,
    parameters = item.parameters
  })

  --  NO CAPACITY LIMIT YET, on purpose. A cap that silently drops items is
  --  worse than no cap; the right shape is the port refusing to DISPATCH
  --  collection when full, and that belongs with the deposit task. Until then
  --  this count is how unbounded growth becomes visible.
  sb.logInfo("PETPORT %s cargo +%s %s (new stack, %s stack(s) held)",
    stationUniqueId(), sb.printJson(item.count or 1), tostring(item.name),
    sb.printJson(#self.petData.cargo))

  flushCargo()
end

--  Persist the live pet state into the socketed item, so the unit travels with
--  the item rather than living in the petport.
function writeBackToItem()
  --  BOTH REFUSALS WERE SILENT, and the second one fires at exactly the moment
  --  under investigation: the item has left the container, so the write that
  --  would have persisted the cargo cannot land.
  if self.petData == nil then
    cargoTrace("writeBack: REFUSED, no petData", nil)
    return
  end

  local item = socketedItem()
  if item == nil then
    cargoTrace("writeBack: REFUSED, nothing socketed", self.petData.cargo)
    return
  end

  cargoTrace("writeBack: serialising", self.petData.cargo)

  item.parameters = item.parameters or {}
  item.parameters.petData = self.petData

  trace("writing back to item", self.petData)

  world.containerSwapItemsNoCombine(entity.id(), item, 0)
  self.dirty = false
end

function stationUniqueId()
  local uniqueId = entity.uniqueId()
  if not uniqueId then
    uniqueId = sb.makeUuid()
    world.setUniqueId(entity.id(), uniqueId)
  end
  return uniqueId
end

--------------------------------------------------------------------------------
--  THE PANE MIRROR
--------------------------------------------------------------------------------
--
--  ONE PARAMETER, READ DIRECTLY BY THE PANE. world.getObjectParameter is
--  reachable from a container pane script -- proven on the upcycler -- so the
--  pane needs no message to read and no round trip to open. Same transport the
--  upcycler uses for points and blips, so there is one of these in the mod
--  rather than two.
--
--  CHANGE-GATED, AND THE GATE IS THE WHOLE DESIGN.
--
--  A port cannot know whether anyone has the pane open -- there is deliberately
--  no way to ask -- so this runs on every port in the world forever. An
--  ungated mirror would be a setConfigParameter several times a second per
--  port to track numbers that mostly do not move.
--
--  So FUEL IS QUANTISED TO A BLIP INDEX BEFORE IT IS WRITTEN, not after. A unit
--  draining its whole bar costs eight writes rather than one per tick, and the
--  pane cannot tell the difference because eight blips is all it draws. Every
--  other field here changes on a task boundary or slower.
--
--  NOTHING IS COMPUTED FOR THE PANE'S BENEFIT. Every field is state the port
--  already holds for its own reasons; this only reshapes it. If a readout ever
--  needs a number that has to be derived, it belongs in the port's own logic
--  with a name, not in here.

PANE_STATE_KEY = "petports_paneState"
PANE_MIRROR_INTERVAL = 0.5

--  THE PANE'S BLIP COUNT AND THIS PORT'S WRITE RESOLUTION ARE THE SAME NUMBER,
--  and that is the coupling worth knowing about. Hunger is quantised to this
--  many steps BEFORE the mirror is written, which is what keeps a draining unit
--  down to twenty writes across its whole bar rather than one per tick -- on
--  every port in the world, since a port cannot know whether anyone is looking.
--
--  Lowering it here makes the pane's top blips unreachable. Raising it costs
--  writes. petportconfig.lua's BLIP_COUNT carries the matching note.
PANE_FUEL_BLIPS = 20

--  The pane draws four at most, so there is no point mirroring more. Ordered
--  worst-first: a red condition should never be pushed off the row by an
--  informational one.
PANE_DIAG_LIMIT = 4

--  IS THE UNIT A MACHINE OR AN ANIMAL? The fuel bar is labelled from this and
--  nothing else reads it yet.
--
--  bodyMaterialKind IS A VANILLA FIELD AND EVERY MONSTERTYPE ALREADY HAS ONE --
--  it is what picks a hit sound and a damage effect -- so nothing new is
--  authored to make this work and a modded pet is classified correctly whether
--  or not its author has ever heard of this pane. All four chassis here declare
--  "robotic"; vanilla creatures declare "organic".
--
--  CACHED PER TYPE, and checked at both levels for the same reason
--  animalHarvestable is: whether root.monsterParameters returns baseParameters
--  flattened or nested is not documented, and looking in both costs one index.
--
--  ANYTHING THAT IS NOT "robotic" IS ORGANIC, rather than the reverse. An
--  unrecognised or absent value should land on the biological wording, because
--  the underlying resource genuinely is vanilla's `hunger` -- see dd.fuel.label.
local bodyKindCache = {}

local function paneBodyKind()
  local monsterType = self.petData and self.petData.monsterType
  if monsterType == nil then return nil end

  local key = tostring(monsterType)
  if bodyKindCache[key] ~= nil then return bodyKindCache[key] end

  local kind = "organic"
  local ok, params = pcall(root.monsterParameters, key)

  if ok and type(params) == "table" then
    local base = type(params.baseParameters) == "table" and params.baseParameters or {}
    local declared = params.bodyMaterialKind or base.bodyMaterialKind

    if declared == "robotic" then kind = "robotic" end

    sb.logInfo("PETPORT %s monster type %s: bodyMaterialKind %s -> %s fuel wording",
      stationUniqueId(), key, tostring(declared), kind)
  else
    sb.logInfo("PETPORT %s monster type %s: root.monsterParameters gave nothing, fuel wording defaults to organic",
      stationUniqueId(), key)
  end

  bodyKindCache[key] = kind
  return kind
end

local function paneFuelBlips()
  local resources = self.petData and self.petData.storage and self.petData.storage.petResources
  if type(resources) ~= "table" then return PANE_FUEL_BLIPS end

  local hunger = tonumber(resources.hunger)
  if hunger == nil then return PANE_FUEL_BLIPS end

  --  QUANTISED HERE AND NOWHERE ELSE. See the gate note above -- this is what
  --  keeps the mirror cheap, so a caller wanting the raw number must read the
  --  resource rather than scaling this back up.
  local blips = math.floor((hunger / 100.0) * PANE_FUEL_BLIPS + 0.5)
  return math.max(0, math.min(PANE_FUEL_BLIPS, blips))
end

--  ONE STACK, CLAMPED. Cargo capacity is one stack by design, and an oversized
--  descriptor crossing the wire surfaces as a bad_alloc naming neither the pane
--  nor the item -- so the clamp happens on this side, before it is written.
local function paneCargo()
  if self.petData == nil or self.petData.cargo == nil then return nil end

  local out = {}
  for _, stack in ipairs(self.petData.cargo) do
    if stack.name then
      local cap = stackSizeOf(stack.name) or 1000
      table.insert(out, {
        name = stack.name,
        count = math.min(tonumber(stack.count) or 1, cap),
        parameters = stack.parameters
      })
    end
  end

  if #out == 0 then return nil end
  return out
end

--  WORST FIRST, AND CAPPED TWO WAYS. These are conditions the port already
--  tracks; nothing new is measured to produce them.
--
--  SHORT ENOUGH TO FIT THE COLUMN, WHICH IS A HARD RULE RATHER THAN A STYLE.
--  The pet column is about 108px and the label does not wrap -- deliberately,
--  since a wrapped label grows UPWARD into the icon row above it. So anything
--  longer than DIAG_MAX_CHARS runs off the pane, and the truncation below is
--  the backstop for a message someone adds later without measuring it.
--
--  `lastReject` IS DELIBERATELY NOT HERE, and was, and it was wrong twice over.
--
--  It is the LOGGER'S repeat-suppression state, not a condition: it changes
--  every time the rejection reason changes, so a port alternating between two
--  reasons flips it every scan. That put a per-scan write back into a mirror
--  whose entire design is a change gate -- on every port in the world, whether
--  or not anyone has the pane open.
--
--  And its contents are developer prose with tile rects in them. "no drops in
--  network coverage (own rect [2518, 1129, 2582, 1193])" is a log line. It
--  belongs in the log, where it already is.
DIAG_MAX_CHARS = 26

--  TWO STRINGS PER DIAGNOSTIC, AND THAT IS WHAT THE ICON ROW IS FOR.
--
--  `short` is what fits under the icons -- capped, single line, no wrap. `full`
--  is what the icon's tooltip says, and it is allowed to be a sentence, because
--  a tooltip has its own box and does not push the layout around.
--
--  This is what makes the icons a readout rather than decoration. Only the
--  worst condition's short form can be on screen at once, so without the
--  tooltip a second icon is a shape with no way to find out what it means.
local function paneDiag(severity, short, full)
  local capped = short
  if #capped > DIAG_MAX_CHARS then
    capped = string.sub(capped, 1, DIAG_MAX_CHARS - 1) .. "..."
  end
  return { severity = severity, short = capped, full = full or short }
end

--  A DIAGNOSTIC IS A LIVE CONDITION, NOT A TALLY, AND THAT DISTINCTION IS THE
--  WHOLE REASON THIS EXISTS.
--
--  `unreachableFailures` clears only when a task reports done -- returnWork
--  clears recallFailures and deliberately not this one, because a unit that
--  walked home is no proof it can reach WORK. That is correct for the
--  STRANDED_LIMIT escalation it was written for.
--
--  It is wrong as a persistent readout. A unit that leashed home, idled and is
--  perfectly healthy sat there reporting "2 unreachable" forever, and a player
--  reads that as a fault rather than as history.
--
--  So the COUNT is untouched and the DISPLAY is gated on recency. The lifetime
--  tally is a Stats-tab number; the status line carries only what is true now.
DIAG_FRESH = 30.0

local function fresh(at)
  if at == nil then return false end
  return (world.time() - at) < DIAG_FRESH
end

local function paneDiagnostics()
  local out = {}

  --  SAID OUT LOUD BECAUSE THE CHECKBOXES STILL LOOK ACTIVE. Oblivious
  --  suppresses dispatch without rewriting the player's participation settings,
  --  so without this line the pane shows ticked boxes and a unit doing nothing,
  --  which is indistinguishable from the dispatcher being broken.
  --
  --  "info" RATHER THAN "warn" OR "error". Nothing is wrong; the player asked
  --  for this. DIAG_TINT has carried an `info` grey since it was written and
  --  this is its first user -- the icon is the same warning glyph multiplied by
  --  the tint, so a neutral colour is the whole difference.
  if petportOblivious() then
    table.insert(out, paneDiag("info", "Oblivious",
      "An Oblivious Module is socketed, so this unit takes no dispatched work. "
      .. "It will still come home and put down anything it is already carrying. "
      .. "Remove the module to put it back on duty."))
  end

  --  TWO WORDINGS, AND THE DIFFERENCE IS NOT COSMETIC. The port refuses to open
  --  its door on an unsuitable environment now, so the common case is a unit
  --  that was NEVER DEPLOYED -- and telling a player their pet "has been
  --  retired" when nothing ever came out reads as the mod having lost it.
  --  self.envRetired records which happened, at the moment the verdict was set.
  if self.envUnsuitable ~= nil then
    table.insert(out, paneDiag("error", "Wrong environment",
      self.envRetired
        and ("This unit's chassis cannot survive the liquid or air at its port. "
          .. "It has been retired and will return on its own once the port drains "
          .. "or floods back.")
        or ("This unit's chassis cannot survive the liquid or air at its port, so "
          .. "the port has not deployed it. It will deploy on its own once the "
          .. "port drains or floods back.")))
  end

  if (self.unreachableFailures or 0) > 0 and fresh(self.unreachableAt) then
    table.insert(out, paneDiag("warn",
      string.format("%d unreachable", self.unreachableFailures),
      string.format("%d job(s) were abandoned because no route could be found. "
        .. "Usually terrain: a gap too wide, a shaft too narrow, or a door the "
        .. "unit cannot open.", self.unreachableFailures)))
  end

  if (self.recallFailures or 0) > 0 and fresh(self.recallAt) then
    table.insert(out, paneDiag("warn",
      string.format("%d recalls failed", self.recallFailures),
      string.format("%d attempt(s) to walk home failed. The unit will be "
        .. "re-homed to its port if this keeps happening.", self.recallFailures)))
  end

  while #out > PANE_DIAG_LIMIT do table.remove(out) end
  if #out == 0 then return nil end
  return out
end

--  THE SPECIES NAME COMES FROM THE ITEM, NOT FROM A STORED COPY. A stored
--  default would drift the moment the item's shortdescription changed, and the
--  pane's "show the species only when renamed" test would then compare a name
--  against a stale one and show the subtitle forever.
local function paneSpecies()
  local item = socketedItem()
  if item == nil or item.name == nil then return nil end

  local ok, resolved = pcall(root.itemConfig, { name = item.name, count = 1 })
  if not ok or type(resolved) ~= "table" or type(resolved.config) ~= "table" then
    return nil
  end
  return resolved.config.shortdescription
end

--  AUTHORED ON THE ITEM, WITH RARITY AS THE FALLBACK RATHER THAN THE RULE.
--
--  SUPERSEDES the earlier "never derived" position, and the objection that
--  produced it is what the fallback ordering answers. That objection was that a
--  modded pet bracketed into the normally-unobtainable Essential tier would have
--  no way to author around a derivation. It has one: the authored field is read
--  FIRST and the table is only consulted when nothing is authored. Essential is
--  also in the table now, so even the un-authored case lands somewhere sensible
--  instead of at zero.
--
--  ONE SLOT AT THE BOTTOM, NOT ZERO. A Common pet with no slots renders the
--  Modules region of the pane completely empty, which reads as a broken pane
--  rather than as an unupgraded unit. Every pet can hold something.
MODULE_SLOTS_BY_RARITY = {
  common = 1,
  uncommon = 2,
  rare = 3,
  legendary = 4,

  --  Not normally obtainable, and present precisely because that is where a
  --  modder brackets a special pet.
  essential = 5
}

--  THE CEILING THE PANE CAN ACTUALLY DRAW, and it is a shared number rather
--  than a local opinion: petportconfig declares exactly this many itemslot
--  widgets and petportconfig.lua's MODULE_SLOTS carries the matching note.
--
--  CLAMPED HERE, ON THE WRITE SIDE, so an item authoring twenty slots gets five
--  rather than fifteen invisible ones. A slot the player cannot see is a slot
--  whose contents cannot be removed.
MODULE_SLOTS_MAX = 5

function petportModuleSlots()
  local item = socketedItem()
  if item == nil then return 0 end

  local function clamp(n)
    return math.max(0, math.min(MODULE_SLOTS_MAX, math.floor(n)))
  end

  if item.parameters and item.parameters.petports_moduleSlots ~= nil then
    return clamp(tonumber(item.parameters.petports_moduleSlots) or 0)
  end

  local ok, resolved = pcall(root.itemConfig, { name = item.name, count = 1 })
  if not ok or type(resolved) ~= "table" or type(resolved.config) ~= "table" then
    return 0
  end

  local authored = tonumber(resolved.config.petports_moduleSlots)
  if authored ~= nil then return clamp(authored) end

  --  LOWERCASED BEFORE THE LOOKUP. Rarity is authored as "Rare" in every
  --  vanilla item file and as "rare" in a fair number of modded ones, and a
  --  case-sensitive miss here would silently hand back zero slots -- the same
  --  casing trap SORTING_FOR_MODDERS.md warns about for filter tags.
  local rarity = resolved.config.rarity
  if type(rarity) == "string" then
    local byRarity = MODULE_SLOTS_BY_RARITY[string.lower(rarity)]
    if byRarity ~= nil then return byRarity end
  end

  return 0
end

--------------------------------------------------------------------------------
--  MODULES
--------------------------------------------------------------------------------
--
--  A LIST OF RECORDS, NOT AN ARRAY INDEXED BY SLOT, AND THAT IS A SERIALISATION
--  DECISION RATHER THAN A STYLE ONE.
--
--  The obvious shape is `modules[slot] = descriptor`, and it works perfectly in
--  Lua right up until it crosses a Json boundary -- which this does twice, into
--  the item's parameters and into the pane's mirrored parameter. A Lua table
--  with keys 1 and 3 and a hole at 2 is not a contiguous array, so the engine
--  converts it to an OBJECT with the string keys "1" and "3". Read back,
--  `modules[3]` with a NUMBER key misses, and a module in slot 3 silently
--  vanishes the first time a unit is unsocketed and re-socketed.
--
--  Nothing has ever hit this because nothing has ever written a module. The
--  record list is sparse by construction and contiguous by construction, so it
--  round-trips identically in both directions with no holes to convert.
--
--  BELIEVED, NOT MEASURED. The list-versus-object conversion rule above is from
--  reading, not from a log in this mod. One socket into slot 2 with slot 1 empty,
--  followed by an unsocket and re-socket, settles it -- and the record list is
--  correct whichever way that lands, which is why it is worth taking now rather
--  than after the measurement.
--
--      modules = { { slot = 1, item = <descriptor> }, { slot = 3, item = ... } }
--
--  ORDER IN THE LIST IS NOT MEANINGFUL. `slot` is, and every reader keys off it.
MODULE_TAG = "petports_module"

--  IS THIS ITEM A MODULE AT ALL?
--
--  A QUESTION ABOUT THE ITEM, WHICH IS WHY THE PANE MAY ALSO ASK IT. The pane
--  performs the swap locally and synchronously -- mech assembly's shape, adopted
--  because a message round trip cannot be made atomic and every ordering of one
--  either loses or duplicates the item. That only stays safe while the two sides
--  cannot disagree about what a module is, and they cannot, because both call
--  root.itemHasTag on the same item rather than consulting separate rules.
function petportIsModuleItem(item)
  if type(item) ~= "table" or item.name == nil then return false end
  local ok, has = pcall(root.itemHasTag, item.name, MODULE_TAG)
  return ok and has == true
end

--  WHAT DOES THIS MODULE DECLARE UNDER `field`?
--
--  Parameters first, then the item config, matching how petportModuleSlots reads
--  its own field -- so an instance of a module can carry different values from
--  its item file, which is the hook a future upgrade or randomisation path needs.
local function moduleFieldOf(item, field)
  if type(item) ~= "table" or item.name == nil then return {} end

  if item.parameters and type(item.parameters[field]) == "table" then
    return item.parameters[field]
  end

  local ok, resolved = pcall(root.itemConfig, { name = item.name, count = 1 })
  if not ok or type(resolved) ~= "table" or type(resolved.config) ~= "table" then
    return {}
  end

  local value = resolved.config[field]
  if type(value) ~= "table" then return {} end
  return value
end

--  THE UNION OF ONE FIELD ACROSS EVERY SOCKETED SLOT, DEDUPLICATED AND SORTED.
--
--  ONE FUNCTION FOR THREE FIELDS, and it is generic because the third one was
--  about to be the third copy of an identical loop. Modules declare three lists
--  and they are read by different things at different times --
--
--      petports_moduleEffects   pushed to a LIVE unit as status effects
--      petports_moduleLiquids   read by the port, with no unit, for the gate
--      petports_moduleFlags     read by the port, to suppress its own dispatch
--
--  -- but the SHAPE is identical in all three cases, and three copies of one
--  loop is how they end up subtly disagreeing about nil handling.
--
--  SORTED SO SIGNATURES ARE STABLE. Two modules swapped between slots grant the
--  same set, and an unsorted list would spell it two ways and push a redundant
--  update every time a player rearranged their slots.
--
--  DEDUPLICATED. Two lamp modules are a player wasting a slot, not a brighter
--  unit, and that is the honest outcome -- stacking would need per-entry
--  knowledge this layer does not have.
local function moduleFieldUnion(field)
  if self.petData == nil or type(self.petData.modules) ~= "table" then return {} end

  local seen = {}
  local out = {}

  for _, record in ipairs(self.petData.modules) do
    if type(record) == "table" and record.item ~= nil then
      for _, entry in ipairs(moduleFieldOf(record.item, field)) do
        if type(entry) == "string" and not seen[entry] then
          seen[entry] = true
          table.insert(out, entry)
        end
      end
    end
  end

  table.sort(out)
  return out
end

function petportModuleEffects()
  return moduleFieldUnion("petports_moduleEffects")
end

--  A SECOND FIELD RATHER THAN MORE petports_moduleEffects ENTRIES, and the
--  reason is that the two are read at different times by different things.
--  Effects are pushed to a LIVE unit and held as status effects. A liquid
--  permission has to be legible to the PORT, with no unit in the world, because
--  it feeds the habitat gate -- and the gate is what decides whether a unit gets
--  spawned at all. A poison module whose permission lived in a status effect
--  would grant immunity to a unit the port had already refused to deploy.
--
--  NAMES, NOT IDS, matching petports_avoidLiquids on the chassis. The two sets
--  are compared key against key, so they must be spelled the same way and are
--  lowercased at both ends.
function petportModuleLiquids()
  return moduleFieldUnion("petports_moduleLiquids")
end

--  BEHAVIOUR FLAGS THE PORT ACTS ON ITSELF. Nothing here is pushed anywhere:
--  these change what the PORT does, not what the unit is, so sending them would
--  be state the unit holds and never reads.
function petportModuleFlags()
  return moduleFieldUnion("petports_moduleFlags")
end

--  DOES A SOCKETED MODULE TAKE THIS UNIT OFF THE DUTY ROSTER?
--
--  Named rather than compared inline because findWork is not the only place that
--  will ever ask -- the pane says so too, and a second spelling of the string
--  "oblivious" is the kind of thing that survives a rename by exactly one file.
OBLIVIOUS_FLAG = "oblivious"

--  THE MEDIC FLAG, AND WHAT A DOSE IS.
--
--  MEDIC_ITEM IS A LITERAL ITEM NAME, NOT A CATEGORY. "Medical Trade Goods"
--  specifically -- a category would sweep in bandages and stim packs, which are
--  things a player wants for themselves, and a medic quietly consuming those is
--  a worse outcome than one that never runs.
MEDIC_FLAG = "medic"

--  CAMOUFLAGE. Read by the UNIT, not by this file -- it changes the unit's
--  damage team, which needs monster.* callbacks the port does not have. Named
--  here anyway so the one place flags are spelled stays one place.
CAMOUFLAGE_FLAG = "camouflage"

--  FARMING IS A MODULE NOW, NOT A PORT SWITCH.
--
--  It used to be the fourth participation group, alongside hauling, sorting and
--  machines -- a PORT setting, because the port dispatches. That split was drawn
--  at "is this universally available to a pet", and farming stopped being
--  universal the moment it needed the granularity below. No module, no farming.
--
--  THE FOUR CLASSES ARE PLAYER-FACING ACTIVITIES, NOT GENERATORS. Six generators
--  are gated by them, because two of the activities own a fetch leg: watering
--  owns withdrawWaterWork and replanting owns withdrawWork, the same way the
--  medic task owns its own trip to the crate. Nobody ticks a box for "go and get
--  a seed" -- that is part of replanting, not a decision beside it.
FARMING_FLAG = "farming"
FARMING_CLASSES = { "harvest", "water", "replant", "animals" }
MEDIC_ITEM = "medicalgoods"

--  A TRADE GOOD WITH ALMOST NO VANILLA USE, GIVEN ONE. That is the design
--  intent rather than an accident of naming: medicalgoods sits in vanilla as
--  a sellable with no sink, and this makes a stockpile of it mean something.

--  TWO MINUTES. Long enough that the network cooldown outlasts any plausible
--  re-wounding, which is what makes two medics healing each other harmless --
--  the loop cannot sustain itself because the first dose is still running.
MEDIC_DURATION = 120
--  VANILLA'S redstim, NOT AN EFFECT OF OUR OWN. The projectile's statusEffects
--  entry carries its own duration, which beats the effect's defaultDuration, so
--  a two-minute dose needs no new file. Named here anyway because the port logs
--  it and the unit reports it -- a dose whose effect nobody can name is a dose
--  nobody can debug.
MEDIC_EFFECT = "redstim"
MEDIC_PROJECTILE = "petports_medicburst"

--  HOW FAR FROM A PATIENT COUNTS AS ARRIVED. Wider than a crate's 4, because the
--  patient MOVES and the dose is an area burst rather than a touch -- see
--  todo.pathing.movingtarget. Tolerance here is doing the work a re-resolve
--  would otherwise have to.
MEDIC_REACH = 6

function petportOblivious()
  for _, flag in ipairs(petportModuleFlags()) do
    if flag == OBLIVIOUS_FLAG then return true end
  end
  return false
end

function petportMedic()
  for _, flag in ipairs(petportModuleFlags()) do
    if flag == MEDIC_FLAG then return true end
  end
  return false
end

function petportFarming()
  for _, flag in ipairs(petportModuleFlags()) do
    if flag == FARMING_FLAG then return true end
  end
  return false
end

--  IS THIS FARMING ACTIVITY SWITCHED ON FOR THIS UNIT?
--
--  ON petData, exactly like the medic classes and for the same reason: it
--  describes how one PET behaves and should travel with it to another port.
--  Defaults ON when absent, so socketing the module into an existing unit starts
--  farming immediately rather than looking broken until four boxes are ticked.
function petportFarmingDoes(class)
  if self.petData == nil then return false end

  local settings = self.petData.farming
  if type(settings) ~= "table" then return true end
  return settings[class] ~= false
end

--  THE CATEGORY THE UNIT HOLDS THEM UNDER.
--
--  status.setPersistentEffects REPLACES EVERYTHING UNDER ONE CATEGORY, which is
--  the entire reason this needs no diffing and no removal path: the port
--  recomputes the whole set and pushes it, and an effect that is no longer in
--  the set is gone by construction. An add/remove protocol would have to stay in
--  step with petData across respawns, reloads and a unit carried to another port.
--
--  OURS ALONE. Anything else applying effects to the unit uses its own category
--  and is untouched by this.
MODULE_EFFECT_CATEGORY = "petports_modules"

--  PUSHED ON CHANGE, AND THE PET ID IS PART OF WHAT COUNTS AS A CHANGE.
--
--  SIGNATURE-GATED RATHER THAN DIRTY-FLAGGED, deliberately. A dirty flag has to
--  be set by every site that mutates modules and is silently wrong the moment
--  one forgets -- and a respawned unit is not a mutation at all, so a flag would
--  not cover it. Folding the entity id into the signature means a unit that died
--  and came back re-applies its effects for free, with nobody having to remember.
--
--  Same shape as self.ventSignature, for the same reasons.
function pushModuleEffects()
  if self.petId == nil or not world.entityExists(self.petId) then
    --  Cleared so the next unit -- respawn or replacement -- is pushed to,
    --  rather than matching a signature left behind by its predecessor.
    self.pushedModuleEffects = nil
    return
  end

  local effects = petportModuleEffects()
  local liquids = petportModuleLiquids()

  --  FLAGS TRAVEL NOW TOO, WHICH THEY DID NOT WHEN THE CHANNEL WAS OPENED.
  --  Oblivious is read entirely port-side -- it changes what the DISPATCHER
  --  does -- so the original comment said flags are never pushed anywhere.
  --  Camouflage broke that: changing a unit's damage team needs monster.*,
  --  which only the unit has. The flags go down the same wire as everything
  --  else rather than growing a second one.
  local flags = petportModuleFlags()

  --  THE CHASSIS TEAM TRAVELS WITH THE FLAGS, computed here rather than looked
  --  up by the unit.
  --
  --  The unit needs it to undo camouflage, and it cannot work it out for itself:
  --  entity.damageTeam() is corrupted on a restored persistent unit -- see
  --  petports_chassisTeam -- and monster.type() is an API this mod has never
  --  used, so a unit-side lookup that failed would fall back to exactly the
  --  untrustworthy source the lookup exists to avoid.
  --
  --  THE PORT KNOWS THE TYPE FOR CERTAIN. petData.monsterType is what it spawned
  --  the unit FROM. Same split as liquid permissions: the port resolves, the
  --  unit consumes.
  local baseTeam = petports_chassisTeam(self.petData and self.petData.monsterType)

  local ok, encoded = pcall(sb.printJson, effects)
  if not ok then encoded = tostring(#effects) end

  local okLiquids, encodedLiquids = pcall(sb.printJson, liquids)
  if not okLiquids then encodedLiquids = tostring(#liquids) end

  local okFlags, encodedFlags = pcall(sb.printJson, flags)
  if not okFlags then encodedFlags = tostring(#flags) end

  --  NOT IN THE SIGNATURE. It is derived from the monster type, which cannot
  --  change for the life of a socketed unit, so including it could only ever
  --  add churn -- and a push that fires for another reason carries it anyway.

  --  BOTH SETS ARE IN THE SIGNATURE. They travel together, so a change to
  --  either has to re-push -- and a signature covering only the effects would
  --  silently swallow a module swap that changed permissions and nothing else.
  local signature = tostring(self.petId) .. "|" .. encoded .. "|" .. encodedLiquids
    .. "|" .. encodedFlags

  if signature == self.pushedModuleEffects then return end
  self.pushedModuleEffects = signature

  sb.logInfo("PETPORT %s pushing to unit %s -- %s effect(s) %s, %s liquid(s) %s, %s flag(s) %s",
    stationUniqueId(), sb.printJson(self.petId),
    sb.printJson(#effects), encoded,
    sb.printJson(#liquids), encodedLiquids,
    sb.printJson(#flags), encodedFlags)

  --  Defined in petports_contract.lua. A bare callScriptedEntity naming a
  --  function the target does not define returns nil SILENTLY rather than
  --  raising, so a missing contract here would look exactly like a status
  --  effect that does not work -- hence the log line above, which fires
  --  whether or not the far end exists.
  world.callScriptedEntity(self.petId, "petports_setModuleEffects", effects,
    MODULE_EFFECT_CATEGORY, liquids, flags, baseTeam)
end

--------------------------------------------------------------------------------

--  Derived from the seed rather than stored as its own field. The seed already
--  exists, already persists, and already decides which monsterpart the unit
--  wears -- so a serial taken from it is stamped at build time by construction
--  and cannot drift from the unit it names.
local function paneSerial()
  local seed = self.petData and self.petData.seed
  if seed == nil then return nil end
  return string.format("%06d", math.floor(tonumber(seed) or 0) % 1000000)
end

--  THE STATS BLOCK FOR THE MIRROR -- NUMBERS, NOT LINES. The pane owns the
--  wording and the arithmetic that makes a total into a rate, same split as
--  bodyKind: the port does not know the words and should not.
--
--  active IS QUANTIZED TO WHOLE MINUTES, and that is load-bearing. It is the
--  one field guaranteed to change every tick, and the mirror is signature-gated
--  -- mirrored raw it would defeat the change gate outright and force a write
--  plus a repaint every PANE_MIRROR_INTERVAL forever. A minute is finer than
--  anything the pane displays.
--
--  tidy IS GATHERED AND DELIBERATELY NOT MIRRORED. dd.dispatch.tidyscore: the
--  raw number is never displayed -- the rank belongs to Maxwell -- so putting
--  it on the wire would be mirroring a number nothing may paint. It is visible
--  in the log at every increment instead.
--
--  ZEROS RATHER THAN ABSENT for a unit with no history yet: this only runs with
--  petData present, and a fresh unit showing "Items moved: 0" is alive where a
--  blank tab reads as broken.
metrics.paneStats = function()
  local stats = (self.petData and self.petData.stats) or {}

  return {
    moved = math.floor(stats.moved or 0),
    planted = math.floor(stats.planted or 0),
    watered = math.floor(stats.watered or 0),
    dosed = math.floor(stats.dosed or 0),
    harvested = math.floor(stats.harvested or 0),
    livestock = math.floor(stats.livestock or 0),
    headpats = math.floor(stats.headpats or 0),

    --  QUANTIZED TO TENS ONLY WHILE ON A TASK, EXACT AT REST. The raw total on
    --  petData is never quantized -- the flooring here is wire-churn control
    --  only, because a walking unit would otherwise bump the blob (a
    --  setConfigParameter write and its client sync) every mirror interval.
    --  The moment the task ends, the wire syncs to the exact figure, so the
    --  display always settles on the truth and the next task counts up from
    --  it. There is no leftover to carry or clear; the total always held
    --  every tile.
    traveled = (self.task ~= nil)
        and math.floor((stats.traveled or 0) / 10) * 10
        or math.floor(stats.traveled or 0),
    activeMinutes = math.floor((stats.active or 0) / 60)
  }
end

function mirrorPaneState(dt)
  --  THE CONTAINER IS THE AUTHORITY FOR "IS ANYTHING SOCKETED", NOT self.petData.
  --
  --  self.petData IS CLEARED IN workUpdate, WHICH RUNS ON WORK_INTERVAL -- one
  --  full second. For that second after the player pulls the item out, petData
  --  still holds a departed unit and this function mirrored it as live: name,
  --  portrait, fuel, and the whole module set, with the pane's slots clickable
  --  the entire time.
  --
  --  THAT WAS A DUPLICATION WINDOW, not a cosmetic lag. The module items travel
  --  inside the pet item's parameters, so they leave with it. A click on a
  --  module slot inside the window hands the player a SECOND copy out of a
  --  stale pane, and petports_setModules cannot undo it -- the pane has already
  --  moved the item to the cursor by the time the port sees the message.
  --
  --  Reading the container costs one call per mirror write and cannot lag,
  --  because it is the same thing the player just changed.
  local socketed = socketedItem() ~= nil

  --  A CHANGE HERE BYPASSES THE TIMER. Waiting out the remaining fraction of an
  --  interval would leave the window open for exactly as long as this is meant
  --  to close it.
  if socketed ~= self.paneSocketed then
    self.paneSocketed = socketed
    self.paneTimer = 0
  end

  self.paneTimer = (self.paneTimer or 0) - (dt or 0)
  if self.paneTimer > 0 then return end
  self.paneTimer = PANE_MIRROR_INTERVAL

  --  A PORT-LEVEL FIELD, SO IT IS ON BOTH BRANCHES. The enabled checkbox sits
  --  above the divider and means something whether or not anything is socketed
  --  -- so an empty port has to report it too, or the pane paints the box from
  --  its config default and shows ON for a port that is off.
  local enabled = petportEnabled()

  --  PORT-LEVEL, SO IT IS ON BOTH BRANCHES for the same reason `enabled` is:
  --  which loops a port takes part in means something with nothing socketed,
  --  and an empty port that omitted it would have the pane paint all four boxes
  --  from their config defaults and show ticked for groups that are off.
  local participation = petportParticipation()
  local crosshairs = petportCrosshairs()

  --  EMPTY IF EITHER SAYS SO. `socketed` closes the window described above;
  --  petData still matters because a socketed item that is not a valid pet
  --  never produces one.
  local state
  if self.petData == nil or not socketed then
    state = {
      hasUnit = false,
      enabled = enabled,
      participation = participation,
      crosshairs = crosshairs
    }
  else
    state = {
      hasUnit = true,
      enabled = enabled,
      participation = participation,
      crosshairs = crosshairs,
      petName = self.petData.petName or paneSpecies() or "Utility Unit",
      species = paneSpecies(),
      serial = paneSerial(),
      fuelBlips = paneFuelBlips(),

      --  "Fuel" over a drone, "Hunger" over an animal. The pane maps this to a
      --  string key; the port does not know the wording and should not.
      bodyKind = paneBodyKind(),
      cargo = paneCargo(),
      task = self.task and self.task.type or "idle",
      diagnostics = paneDiagnostics(),
      moduleSlots = petportModuleSlots(),

      --  MEDIC. Two fields, and they answer different questions: whether the
      --  five patient boxes should EXIST at all, and what they should read.
      --
      --  isMedic IS DERIVED FROM THE SOCKETED MODULE, not stored. It is exactly
      --  petportMedic(), the same test medicWork gates on, so a pane showing
      --  the boxes and a port generating the work can never disagree.
      --  THE FLAG SET, NOT A BOOLEAN PER MODULE. The pane's settings list keys
      --  each row on the flag that reveals it, so sending the raw list means a
      --  future module needs no new mirror field -- only a row entry and a
      --  string. isMedic would have been the first of N such booleans.
      moduleFlags = petportModuleFlags(),

      --  BOTH PET-OWNED SETTING STORES. The pane does not care which message
      --  files which; it reads them back to paint the boxes it drew.
      toggles = (self.petData and self.petData.toggles) or nil,
      medic = (self.petData and self.petData.medic) or nil,
      farming = (self.petData and self.petData.farming) or nil,
      modules = self.petData.modules,

      --  THE ECHO. The pane stamps every module write and refuses to overwrite
      --  its own module set from a mirror until its stamp comes back -- see the
      --  petports_setModules handler for the item-loss path that closes.
      --
      --  MIRRORED EVEN WHEN NOTHING CHANGED, which it is, because the handler
      --  clears paneSignature on the way in. A token swallowed by the change
      --  gate is a pane waiting forever.
      moduleToken = self.moduleToken,

      --  THE LIVE UNIT'S ENTITY ID, WHICH IS THE WHOLE PORTRAIT MECHANISM.
      --
      --  world.entityPortrait(id, mode) returns a list of DRAWABLES for a
      --  portrait entity -- the same call the bounty board uses -- so the pane
      --  draws the actual unit rather than a static per-chassis icon that goes
      --  stale at the art pass.
      --
      --  IT IS ONLY VALID WHILE THE UNIT EXISTS. A socketed-but-unspawned unit,
      --  a dead one inside RESPAWN_GRACE, or a retired one all have no entity,
      --  so this goes nil and the pane draws nothing. That is honest -- the
      --  portrait is a live view of a live unit, not a picture of the item.
      --
      --  NOT self.petId DIRECTLY: it survives in the field after the entity is
      --  gone, and handing the pane a dead id would have it call entityPortrait
      --  on nothing every poll.
      petId = (self.petId ~= nil and world.entityExists(self.petId)) and self.petId or nil,

      flavor = self.petData.flavor,
      stats = metrics.paneStats(),

      --  NOT BUILT, AND ABSENT RATHER THAN FAKED. The pane renders a blank for
      --  a missing field and a wrong value for a placeholder one, so absent is
      --  the honest option.
      network = nil
    }
  end

  --  ONE SIGNATURE FOR THE WHOLE BLOB. Cheaper than comparing fields, and it
  --  cannot fall out of step with the table above when a field is added.
  local ok, signature = pcall(sb.printJson, state)
  if ok and signature == self.paneSignature then return end
  if ok then self.paneSignature = signature end

  object.setConfigParameter(PANE_STATE_KEY, state)
end

--------------------------------------------------------------------------------

--  THE SOCKETED CHASSIS'S CAPABILITIES, WITH ITS MODULES APPLIED.
--
--  READS THE ITEM, NOT THE UNIT, and that is the whole reason it can be asked at
--  all times. A port whose environment refuses the spawn still holds the item,
--  still knows the monsterType, and still has to answer questions about what
--  that chassis could do -- the same argument that moved the habitat ladder out
--  of petports_contract.lua in the first place.
--
--  MODULES ARE PART OF THE QUESTION. Leaving petportModuleLiquids out here would
--  defeat the liquid modules exactly halfway: the environment gate would let a
--  poison-immune unit live at a poison pool, and dispatch would then refuse it
--  every target in the pool it was socketed to work.
--
--  CACHED BY petports_habitatCapabilitiesForType, per monsterType, so this is a
--  table lookup plus a permission-set walk that is almost always empty. Cheap
--  enough to call per candidate, which is what dispatch eligibility does.
local function unitCapabilities()
  if self.petData == nil or self.petData.monsterType == nil then return nil end

  return petports_habitatCapabilitiesForType(self.petData.monsterType,
    petports_habitatPermittedSet(petportModuleLiquids()))
end

--  WHAT MEDIA DOES THIS PORT'S OWN FOOTPRINT OFFER?
--
--  Returns wet, dry -- each meaning "at least one occupied tile is like this".
--  A port straddling a waterline offers both, which is correct: there is a wet
--  half for a swimmer and a dry half for a flyer.
--
--  world.objectSpaces RATHER THAN AN ASSUMED 4x4. The footprint is whatever the
--  object declares, and hardcoding its current size would go quietly wrong the
--  first time the art changes. Spaces are relative to the object, so they are
--  offset by its position before being read.
--  Returns wet, dry, liquids -- where `liquids` is the set of liquid ids found
--  anywhere in the footprint, at any depth.
--
--  THE PORT COLLECTS IDS AND DOES NOT JUDGE THEM. Which liquids a chassis
--  refuses is a monstertype parameter, so only the unit can classify them, and
--  duplicating a deny-list here would be a second source of truth for the one
--  question this whole system exists to answer consistently. Any depth, not
--  just swimmable depth: a shallow lava film in the footprint is a reason to
--  retire a unit even though it is not deep enough to count as wet.
local function portMedia()
  local spaces = world.objectSpaces(entity.id())
  if spaces == nil or #spaces == 0 then return false, true, {} end

  local origin = entity.position()
  local wet, dry = false, false
  local liquids = {}

  for _, space in ipairs(spaces) do
    local level = world.liquidAt({
      math.floor(origin[1]) + space[1] + 0.5,
      math.floor(origin[2]) + space[2] + 0.5
    })

    local fill = (level ~= nil) and (level[2] or 0) or 0

    if level ~= nil and level[1] ~= nil and fill > 0 then
      liquids[level[1]] = true
    end

    if fill >= ENVIRONMENT_SUBMERGED_FILL then
      wet = true
    else
      dry = true
    end
  end

  local ids = {}
  for id in pairs(liquids) do table.insert(ids, id) end

  return wet, dry, ids
end

--  RETIRE A UNIT THE PORT'S ENVIRONMENT NO LONGER SUITS, AND REFUSE TO SPAWN
--  ONE INTO AN ENVIRONMENT IT CANNOT LIVE IN.
--
--  FOUR SYMPTOMS, ONE CAUSE. A flyer socketed into a flooded port could not path
--  out of the water. An aquatic unit in a dry port worked nearby pools and then
--  stalled the moment its leash asked it to come home. A ground unit leashing to
--  a submerged port sat still. All three are the same sentence: THE UNIT CANNOT
--  OCCUPY ITS OWN HOME, and no amount of retrying fixes it because home does not
--  move.
--
--  DESPAWNING IS SAFE AND IS THE POINT. saveAndDespawn writes the unit's state
--  and its CARGO back into the item first, so nothing is lost -- the item sits
--  in the port holding whatever it was carrying, and socketing it into a
--  suitable port later unloads it. A retired unit is recoverable; a unit frozen
--  in terrain is not.
--
--  RE-EVALUATED, NOT LATCHED. The environment changes: rain floods a port, a
--  player drains a pool, a dug channel reaches the base. So the same check that
--  retires a unit also brings it back, and self.envUnsuitable is a cache of the
--  last verdict rather than a permanent decision.
--
--  IT NO LONGER NEEDS A UNIT, AND THAT IS THE WHOLE CHANGE.
--
--  It used to return immediately unless a unit existed, because capability was
--  a monstertype parameter and only the unit had read it. True of the ENTITY,
--  never true of the TYPE -- root.monsterParameters answers the same questions
--  from here, and this file already calls it twice for other reasons.
--
--  WHAT THE OLD ORDER COST, once the spawn stopped being a one-frame pop: the
--  port opened its door, materialised a unit, waited up to ENVIRONMENT_INTERVAL,
--  dematerialised it and closed the door, forever. The flicker that
--  dd.port.envflicker accepted was a frame; the choreography made it a
--  performance. See dd.port.envpresence for the supersession.
--
--  ASKS THE UNIT WHENEVER THERE IS ONE, AND THE TYPE OTHERWISE. Both routes run
--  the SAME ladder in petports_habitat.lua, so they cannot disagree by drifting.
--  They can disagree on purpose later, when module-granted liquid permissions
--  make the live answer wider than the authored one -- and that runs the safe
--  way: the type gate can only refuse a spawn the unit would have allowed.
local function environmentCheck()
  --  NO ITEM, NO QUESTION. A verdict about a chassis that is not socketed is
  --  meaningless, and leaving a stale one latched here would hold the door shut
  --  on the next unit in. Cleared rather than left alone for that reason.
  if self.petData == nil or self.petData.monsterType == nil then
    self.envUnsuitable = nil
    return
  end

  local live = self.petId ~= nil and world.entityExists(self.petId)
  local wet, dry, liquids = portMedia()
  local verdict = nil

  if live then
    local called, answer = pcall(world.callScriptedEntity, self.petId,
      "petports_canInhabit", wet, dry, liquids)

    --  A UNIT THAT CANNOT ANSWER IS LEFT ALONE. callScriptedEntity returns nil
    --  silently for a function the target does not define, so a nil here is
    --  indistinguishable from an older unit script -- and failing closed on that
    --  would retire working units over a version mismatch. A late retirement
    --  costs a few seconds; a wrong one costs the player their pet.
    --
    --  IT DOES NOT FALL BACK TO THE TYPE. A live unit that will not answer is a
    --  version mismatch, and the type answer would be a DIFFERENT question
    --  quietly substituted for the one that failed. Leaving the last verdict
    --  standing is the honest reading and the one that cannot retire anything.
    if not called or type(answer) ~= "table" then return end
    verdict = answer
  else
    --  nil FROM HERE IS "root.monsterParameters GAVE NOTHING", which is a
    --  tooling problem and not a statement about the terrain. Same rule as
    --  above: leave the port alone rather than brick it over a bad type name.
    --  MODULE PERMISSIONS ARE PART OF THE QUESTION, and leaving them out here
    --  would defeat the poison module entirely: the port would refuse to open
    --  its door at a poison pool, so the unit that carries the immunity would
    --  never be deployed to use it. The gate has to know what the socketed
    --  modules grant, which is why the permission set is read from the ITEM and
    --  not from a status effect on a unit that does not exist yet.
    verdict = petports_habitatVerdict(unitCapabilities(), wet, dry, liquids)

    if verdict == nil then
      if not self.envTypeUnreadable then
        self.envTypeUnreadable = true
        sb.logInfo("PETPORT %s cannot read capabilities for monster type %s -- the "
          .. "environment gate is open and a unit will spawn unchecked",
          stationUniqueId(), tostring(self.petData.monsterType))
      end

      self.envUnsuitable = nil
      return
    end

    self.envTypeUnreadable = nil
  end

  --  THE UNIT'S OWN SENTENCE WINS WHERE THERE IS ONE. It is the same string
  --  today -- both sides look it up in the same table -- but a unit answering
  --  with a reason and no cause is what an out-of-step script version looks
  --  like, and the specific sentence is more use in a log than the fallback.
  local reason = verdict.reason or petports_habitatReason(verdict.cause)

  if verdict.ok then
    --  LOGGED ON THE TRANSITION ONLY, both ways. This runs every
    --  ENVIRONMENT_INTERVAL now whether or not a unit exists, so an unconditional
    --  line here would print forever at a port nobody is looking at.
    if self.envUnsuitable ~= nil then
      sb.logInfo("PETPORT %s environment now suits the socketed chassis: %s "
        .. "(footprint wet %s, dry %s) -- the door may open again",
        stationUniqueId(), reason, tostring(wet), tostring(dry))
    end

    self.envUnsuitable = nil
    return
  end

  --  BOTH THE LINE AND THE FLAG BELONG TO THE TRANSITION, NOT TO THE POLL.
  --
  --  self.envRetired IS LATCHED HERE AND NOT ASSIGNED BELOW, and that is a real
  --  bug rather than a tidiness point. Written unconditionally it would be true
  --  on the tick a unit is retired and FALSE five seconds later, when the same
  --  verdict is re-reached with no unit left to be live -- so the pane would
  --  announce a retirement and then quietly rewrite it as "never deployed".
  if self.envUnsuitable == nil then
    --  WHICH OF THE TWO SENTENCES THE PANE SHOWS. "It has been retired" is a lie
    --  about a unit that never existed, and the shared module cannot tell the
    --  difference -- it is asked the same question either way.
    self.envRetired = live

    if live then
      sb.logInfo("PETPORT %s RETIRING unit: %s (footprint wet %s, dry %s). Its state and "
        .. "cargo are written back to the item, which stays socketed -- move it to a "
        .. "suitable port to unload it.",
        stationUniqueId(), reason, tostring(wet), tostring(dry))
    else
      sb.logInfo("PETPORT %s REFUSING to deploy: %s (footprint wet %s, dry %s). The "
        .. "door stays shut and the item is untouched; it will deploy on its own if "
        .. "the port floods or drains to suit it.",
        stationUniqueId(), reason, tostring(wet), tostring(dry))
    end
  end

  self.envUnsuitable = reason

  if live then saveAndDespawn() end
end

--  DEFINED HERE, NOT BESIDE findWork, AND THE PLACEMENT IS LOAD-BEARING.
--
--  A `local function` called from ABOVE its definition is a nil GLOBAL, and it
--  fails at the call rather than at load -- so it looks like a runtime bug in
--  whatever function happened to reach it first.
--
--  MEASURED, and it was mine: gating the findWork rungs by pattern-matching
--  `if X ~= nil then return X end` also matched a line inside depositWork some
--  four thousand lines earlier, which happens to use the same shape. Result:
--
--      attempt to call a nil value (global 'dispatchable')
--
--  the first time a unit had cargo. So this sits directly under
--  stationUniqueId -- the last thing it depends on -- and above every caller.
--  Do not move it back down beside its users.

--  WHICH WORK TYPES ARE CHECKED AGAINST THIS PORT'S OWN RECT.
--
--  AN ALLOW-LIST, INVERTED FROM WHAT THIS USED TO BE, and the inversion is the
--  point. The old test named six types as exempt and checked everything else,
--  which quietly assumed that anything not listed was generated from this
--  port's own scan. That is false for a NETWORK: drain, deposit and upcycle all
--  name a machine or a crate that a MEMBER port found, and in a three-port
--  network they routinely sit in someone else's rect.
--
--  MEASURED, and it cost the whole run. A ground port with rect [2511,...]
--  picked drain:13:dirtmaterial at [2506.5,1163.8] on every single tick,
--  failed this check every time, and dispatched nothing else for 104 seconds
--  while drops sat inside its own coverage.
--
--  So the honest question is not "which types are exempt" but "which positions
--  did this port INVENT". Only diag does: it calls findStandingPoint against
--  its own rect and the result must land inside it, so a failure there really
--  is the generator being wrong. Everything else names a discovered entity and
--  belongs to the network.
--
--  A deny-list grows every time a work type is added and fails closed in the
--  worst way -- by silently starving a unit rather than by erroring. This
--  fails open, which for work dispatch is the correct direction.
RECT_CHECKED_TYPES = {
  ["diag"] = true
}

--  Is this work actually dispatchable by this port, or should findWork keep
--  looking?
--
--  ORDERING IS NOT A GUARD, AND NEITHER IS SELECTION. findWork is a ladder of
--  "first non-nil wins", and the rect test used to run in the CALLER after the
--  winner was chosen -- so a candidate that could never be dispatched ended the
--  tick and everything below it never ran. That is starvation from a single
--  refused task, and the log made it invisible: the reject was change-gated, so
--  it printed once and then eighteen seconds of "draining dirtmaterial x289,
--  x294, x299" scrolled past looking like a busy port.
--
--  Same lesson as the note further up this file about depositWork: precedence
--  cannot order an option that does not exist. A rung must decline, not end the
--  search.
local function dispatchable(work)
  if work == nil then return nil end

  if RECT_CHECKED_TYPES[work.type]
     and not petports_rectContains(coverageRect(), work.position) then

    --  Not via reject(): that sets the port's single refusal reason and returns
    --  from the tick, and this is a rung declining rather than the tick ending.
    --  Change-gated on its own key so a rung that refuses every tick says so
    --  once rather than per tick.
    local note = string.format("%s type %s at %s outside own rect %s",
      tostring(work.id), tostring(work.type), sb.printJson(work.position),
      sb.printJson(coverageRect()))

    if self.lastRectSkip ~= note then
      self.lastRectSkip = note
      sb.logInfo("PETPORT %s SKIPPING %s -- generated point outside rect, "
        .. "falling through to the next kind of work",
        stationUniqueId(), note)
    end

    return nil
  end

  return work
end

--------------------------------------------------------------------------------
--  WORK DISCOVERY AND DISPATCH
--------------------------------------------------------------------------------
--
--  Discovery belongs to the PORT, not the unit. Vanilla's seam is
--  querySurroundings -> reactToObject, which scans a radius around wherever the
--  unit happens to be standing -- work found that way would never touch the
--  coverage rect, and the rect is the whole point.

--  The unit's uniqueId, minting one if the engine has not.
--
--  Needed in two places: the claim records who is executing, and the unit calls
--  entity.uniqueId() when it reports back. Without this both are nil.
--
--  PROTOTYPE GAP: this id is minted fresh on every spawn, so it does NOT
--  survive a respawn. The design calls for it to be persisted on the item
--  alongside `seed` and reassigned at spawn, which is what makes a claim
--  survive a world reload. Fine while claims are cleared per load anyway.
local function petUniqueId()
  if self.petId == nil or not world.entityExists(self.petId) then return nil end

  local uniqueId = world.entityUniqueId(self.petId)
  if not uniqueId then
    uniqueId = sb.makeUuid()
    world.setUniqueId(self.petId, uniqueId)
  end

  self.petUniqueId = uniqueId
  return uniqueId
end

--  Find a standing spot inside the rect.
--
--  x is snapped to a TILE CENTRE. A unit's boundBox is about a tile wide and
--  centred on its position, so a candidate at integer x straddles two tile
--  columns and only succeeds where both are clear -- the same trap
--  petports_placement.lua documents for resting positions.
--
--  UNVERIFIED: world.pointTileCollision's default collision kinds. If targets
--  come back inside blocks or floating, that default is the first thing to
--  check.
--  Resolve a standing position by ASKING THE UNIT.
--
--  The unit owns the only correct test -- see petports_standingPointNear in
--  petports_contract.lua for why the port's own geometry cannot answer this.
--  callScriptedEntity is synchronous, so this costs one call and no round trip.
--
--  Falls back to findStandingPoint when there is no unit to ask. That fallback
--  is KNOWN TO BE WRONG for any unit whose boundBox bottom is not a whole tile,
--  and it is here only so a port with no unit socketed still produces something
--  rather than nil. Anything dispatched to a unit should go through this
--  function, not findStandingPoint directly.
--  `mediumVerified` travels to the unit, where petports_flyPointNear stands its
--  single-point veto down for it. Only servicePointNear passes it, and only
--  because targetSuits has just run the medium ladder over the target's real
--  footprint. See the note in petports_flyPointNear for what the veto is for and
--  why it is not simply deleted.
local function standingPointNear(position, radius, mediumVerified)
  if self.petId ~= nil and world.entityExists(self.petId) then
    local ok, resolved = pcall(world.callScriptedEntity, self.petId,
      "petports_standingPointNear", position, radius or 4, mediumVerified)

    if ok and resolved ~= nil then return resolved end

    sb.logInfo("PETPORT %s unit could not resolve a standing point near %s (called %s)",
      stationUniqueId(), sb.printJson(position), tostring(ok))
  end

  return nil
end

--  WHERE WOULD THIS UNIT PARK, IF IT WALKED HOME BY ITSELF?
--
--  A SEPARATE QUESTION RATHER THAN standingPointNear WITH MORE ARGUMENTS, and
--  the reason is the boundary. Threading a `searchUp` through meant calling
--  world.callScriptedEntity with a nil in the MIDDLE of the argument list --
--  `(position, nil, 0)` -- and whether that boundary preserves an embedded nil
--  or truncates the list there is not something this mod has measured. A
--  truncated list would silently drop the homeward bias and put the unit on the
--  port's roof, which is the exact bug this change exists to remove, arriving by
--  a route nobody would look at.
--
--  IT ALSO NAMES THE RIGHT THING. The port does not want "a ground search with
--  these parameters"; it wants "your home point". The parameters are the unit's
--  business and they now live in exactly one place.
local function homePointNear()
  if self.petId == nil or not world.entityExists(self.petId) then return nil end

  local ok, resolved = pcall(world.callScriptedEntity, self.petId,
    "petports_homePointNear", entity.position())

  if ok and resolved ~= nil then return resolved end

  sb.logInfo("PETPORT %s unit could not resolve a home point at %s (called %s)",
    stationUniqueId(), sb.printJson(entity.position()), tostring(ok))
  return nil
end

--  CAN THE SOCKETED CHASSIS WORK AT THIS TARGET AT ALL?
--
--  `todo.dispatch.eligibility`. The port filtered farmables on ripeness, claims,
--  backoff and existence, and never asked whether THIS CHASSIS could service
--  one. An aquatic unit was therefore dispatched to dry crops, declined on
--  arrival, and failed two seconds later -- and with several ripe crops rotating
--  against a per-target backoff, one was always eligible, so the leash never
--  finished. It read in game as stutter stepping and looked like a pathing
--  fault.
--
--  THE SAME LADDER THE ENVIRONMENT GATE RUNS, ASKED ABOUT A TARGET INSTEAD OF A
--  HOME. petports_habitatVerdict already encodes every rule this needs: free
--  movers by medium, a walker that avoids liquid needs dry footing, and an
--  amphibious walker takes any medium. Writing a second predicate would have
--  been the fourth spelling of one question -- standingPointNear is the third --
--  and this file's history is mostly about what happens when two of those drift.
--
--  DELIBERATELY NOT petports_targetAllowed. That function looks like the right
--  one and is not: it reads petports_media(), which defaults canSwim to false,
--  and the amphibious chassis declares NEITHER flag. It has only ever been
--  reachable through petports_flyPointNear, which returns nil for a walker, so
--  its walker branch has never run. Using it here would refuse an amphibious
--  unit every submerged target -- the one chassis that is supposed to take them
--  all -- and the drone would pass dry targets only by accident of canFly
--  defaulting true.
--
--  AN OBJECT IS SAMPLED BY ITS OWN FOOTPRINT. Crops, containers and machines are
--  all objects, so world.objectSpaces answers for every one of them and a
--  half-submerged shipping container is correctly a valid target for both a
--  swimmer and a flyer -- either can touch some part of it. Everything else --
--  item drops, livestock, patients -- is a point, and a point cannot straddle a
--  waterline, so MIXED_MEDIUM is unreachable there by construction.
--
--  IT DOES NOT ASK WHERE THE UNIT WOULD STAND. That is standingPointNear's
--  question and the two are complementary: this one refuses a target in the
--  wrong medium, that one refuses a target with no footing. Moving targets get
--  the second and not the first, because a Mooshi's position at dispatch is
--  already stale and sampling the medium of a stale point buys nothing.
--
--  FAILS OPEN. A capability table that could not be built means
--  root.monsterParameters gave nothing, which is a tooling problem and not a
--  statement about the terrain -- the same reading environmentCheck takes. A
--  port that starves its unit over an unreadable type is worse than one that
--  dispatches a trip that fails.
local function targetSuits(position, entityId)
  local caps = unitCapabilities()
  if caps == nil then return true end

  local points = petports_habitatObjectPoints(entityId)

  if points == nil then
    if position == nil then return true end
    points = { { position[1], position[2] } }
  end

  --  ANY TILE, NOT EVERY TILE. See petports_habitatAnyPointSuits: the port's own
  --  environment gate still runs the whole-footprint ladder, because a unit must
  --  LIVE in its home, and this one only has to REACH its work.
  local verdict = petports_habitatAnyPointSuits(caps, points)

  if verdict == nil or verdict.ok then return true end

  return false, petports_habitatTargetReason(verdict.cause)
end

--  Say it once per target, then only when that target's answer changes.
--
--  A REFUSAL HERE IS THE NORMAL STEADY STATE, not an error: an aquatic unit in a
--  base with a dry farm refuses every crop, every scan, forever. Ungated that is
--  the loudest line in the log by a wide margin.
--
--  ONE SLOT WAS NOT A GATE. The first version of this kept a single
--  self.lastEligibilitySkip, on the assumption that a repeating refusal repeats
--  the same sentence. It does not: a port walks EIGHT refused targets per scan
--  -- five crops, a crate, a request crate, a machine -- so every line displaced
--  the one before it and nothing was ever suppressed. Measured at 767 lines in a
--  three-minute session, 69 of them the same sentence about crop 191, on a port
--  that dispatched nothing at all. A gate keyed on the wrong thing is not a
--  quieter log, it is the same log plus a comment claiming otherwise.
--
--  KEYED BY TARGET, VALUED BY SENTENCE, so each target says its piece once and
--  says it again only if the verdict changes underneath it -- a row that floods,
--  a module that grants a liquid.
--
--  RESET WHEN THE CHASSIS CHANGES, because every answer in the table was about
--  the old one. Swapping an aquatic unit for a flyer inverts the whole set, and
--  a stale table would silently swallow the first refusal of each new target.
--
--  NOT SILENT, THOUGH. `todo.dispatch.eligibility` records that this is a
--  VISIBLE behaviour change -- a unit that used to fail noisily at a dry farm
--  now ignores it silently -- and until the pane says so, the log is the only
--  place a player chasing a still pet can find out why. The per-scan summary
--  line still counts them every tick; this only stops the roll call repeating.
local function targetRefused(label, reason)
  local chassis = self.petData ~= nil and self.petData.monsterType or nil

  if self.eligibilitySkips == nil or self.eligibilitySkipsChassis ~= chassis then
    self.eligibilitySkips = {}
    self.eligibilitySkipsChassis = chassis
  end

  local key = tostring(label)
  local note = tostring(reason)

  if self.eligibilitySkips[key] ~= note then
    self.eligibilitySkips[key] = note
    sb.logInfo("PETPORT %s SKIPPING %s %s -- this chassis cannot work there",
      stationUniqueId(), key, note)
  end
end

--  Both halves in one call, for the generators that only need "yes or no".
local function targetEligible(label, position, entityId)
  local ok, reason = targetSuits(position, entityId)
  if ok then return true end

  targetRefused(label, reason)
  return false
end

--  BOTH QUESTIONS, IN THE ORDER THAT MAKES THE CHEAP ONE FIRST.
--
--  Every object target wants the same pair: is the target in a medium this
--  chassis works in, and is there anywhere near it to stand. They are genuinely
--  different -- a crate in air above a pool passes the second for an aquatic
--  unit and fails the first, which is the measured bug recorded in the header
--  of petports_targetAllowed -- and the medium test is a handful of
--  world.liquidAt calls against a standing search, so it goes first.
--
--  RETURNS THE STANDING POINT AND THE REASON IT DID NOT.
--
--  A nil means refused, and the SECOND RETURN SAYS WHICH HALF REFUSED. Callers
--  print their own SKIPPED line and every one of them used to assert "no
--  standable spot within N tiles", which was true when this call was
--  standingPointNear and stopped being true the moment a medium test went in
--  front of it: 77 lines in one session blamed standability for what was really
--  a half-submerged crate. A message that names the wrong cause is worse than no
--  message, because it sends the next reader to measure the wrong thing.
--
--  MOVING TARGETS DO NOT COME HERE. A patient or an animal gets the reach test
--  alone -- see the note in animalWork.
local function servicePointNear(label, entityId, position, radius)
  local suits, why = targetSuits(position, entityId)

  if not suits then
    targetRefused(label, why)
    return nil, why
  end

  --  VOUCHING, AND ONLY BECAUSE targetSuits JUST RAN. The unit's own resolver
  --  keeps a single-point veto that cannot see a straddling footprint, and the
  --  line above is the footprint answer it is missing. Passing true anywhere
  --  targetSuits has NOT run would be a lie that costs a hovering unit.
  local stand = standingPointNear(position, radius or 4, true)

  if stand == nil then
    return nil, string.format("no standable spot within %s tiles",
      tostring(radius or 4))
  end

  return stand
end

local function findStandingPoint(rect)
  for _ = 1, 12 do
    local x = math.floor(rect[1] + math.random() * (rect[3] - rect[1])) + 0.5

    for y = rect[4], rect[2], -1 do
      local here = {x, y}
      local below = {x, y - 1}

      if world.pointTileCollision(below) and not world.pointTileCollision(here) then
        return here
      end
    end
  end

  return nil
end

--  One diagnostic task at a time per port, so the work id is just the port's.
local function diagnosticWork()
  local rect = coverageRect()
  local position = findStandingPoint(rect)

  if position == nil then
    return nil, "no standing point in rect"
  end

  return {
    id = "diag:" .. stationUniqueId(),
    type = "diag",
    port = stationUniqueId(),
    position = position,
    dwell = DIAG_DWELL
  }
end

--  TASK 1 -- COLLECTING ITEM DROPS
--
--  Sweep the coverage rect for item drops and claim the nearest one nobody
--  else has spoken for.
--
--  The claim key is the drop's own entity id, which is exactly the property
--  that made drops the right first real task: no wiring, no routing graph, and
--  a naturally unique key. Entity ids do not survive a reload, but claims are
--  cleared per load anyway, so nothing depends on them persisting.
--
--  Drops DESPAWN on their own timer. That is a real deadline rather than an
--  edge case, and it is what exercises claim expiry without a contrived test.
--  Would some OTHER member of our network get to this faster?
--
--  Union dispatch means any port may send its unit into any member's coverage,
--  so without arbitration every port with a free unit races for the same drop
--  and the claim decides arbitrarily. Distance decides instead: the port whose
--  unit is nearest takes it, and the rest skip it.
--
--  Walls are ignored deliberately. A true reachability comparison would mean
--  pathfinding per candidate per drop, which is enormously more expensive than
--  the occasional wrong pick -- and a wrong pick self-corrects, because an
--  unreachable target fails fast and backs off.
--  How long to keep deferring a drop to a unit that is not taking it.
--
--  Deferral is a TIE-BREAK, NOT A VETO. Straight-line distance says nothing
--  about whether the other unit can actually get there, and in a player's base
--  it is routinely wrong: a unit three tiles from a drop through a cage wall
--  reads as nearer than a free unit twenty tiles away with a clear path.
--
--  Worse, the veto had no timeout. If the "closer" unit never takes the drop --
--  wrong side of a wall, idle, already failing it -- every port deferred
--  forever and nobody collected anything. Observed with a caged unit: the port
--  reported drops as claimed or backed off when in truth it was standing aside
--  for a neighbour that was never going to move.
--
--  After this many seconds of a drop sitting unclaimed, take it anyway. Long
--  enough that a genuinely closer unit wins the race in normal play, short
--  enough that a player notices nothing.
DEFER_GRACE = 12.0

local function anotherUnitIsCloser(position, ourDistance)
  for _, entry in ipairs(petports_networkMembers(stationUniqueId())) do
    --  A port with no unit socketed cannot take anything, whatever position it
    --  last published. Belt and braces against a stale entry surviving a crash,
    --  an unload, or a version of this file that stopped publishing on empty.
    if entry.unitPosition ~= nil and not entry.busy and entry.hasUnit ~= false then
      if world.magnitude(entry.unitPosition, position) < ourDistance then
        return true
      end
    end
  end
  return false
end

--  Would this drop merge into a stack the unit already holds?
--
--  THE TOP-UP RULE, AND THE CEILING IS WHAT MAKES IT SAFE.
--
--  A unit carrying anything is a full load -- one stack per trip is the design,
--  because more throughput is supposed to mean more units. Topping up an
--  existing stack does not break that: the unit still carries ONE stack, just a
--  fuller one, and still cannot carry two different things.
--
--  CAPACITY IS COUNTED IN SLOTS, so a merge consumes none of it. That is the
--  whole reason this is free where a general "keep collecting" would have spent
--  a progression stat before the pets that earn it exist.
--
--  CAPPED AT maxStack, without which "matches my cargo" is unlimited
--  single-flavoured hoarding -- the same sack, one item at a time. The cap has
--  a second benefit: cargo stacks stay legal descriptors, which is one of the
--  two routes into the containerAddItems destruction bug that placeStack now
--  has to defend against.
--
--  ALL OR NOTHING. A drop is collected whole, so a stack that would overflow is
--  passed over rather than split. A unit holding 3 dirt can take a drop of 997
--  and not one of 998.
local function dropMergesWithCargo(dropId)
  if self.petData == nil or self.petData.cargo == nil then return false end

  local ok, descriptor = pcall(world.itemDropItem, dropId)

  if not ok or type(descriptor) ~= "table" or type(descriptor.name) ~= "string" then
    --  Unreadable means we cannot prove it merges, and this path only ever runs
    --  when the unit is already stalled. Declining costs nothing.
    return false
  end

  for _, stack in ipairs(self.petData.cargo) do
    if stack.name == descriptor.name then
      local limit = stackSizeOf(stack.name)
      local total = (stack.count or 0) + (descriptor.count or 1)

      if total <= limit then return true end

      sb.logInfo("PETPORT %s drop %s would overflow %s: %s held + %s dropped > %s",
        stationUniqueId(), sb.printJson(dropId), tostring(stack.name),
        sb.printJson(stack.count or 0), sb.printJson(descriptor.count or 1),
        sb.printJson(limit))

      return false
    end
  end

  return false
end

local function collectionWork(mergeOnly)
  --  Scan the whole NETWORK's coverage, not just our own rect. Queues stay
  --  port-owned -- see the handoff -- but a union is a view assembled at
  --  dispatch time, and this is that view.
  local rects = self.networkRects
  if rects == nil or #rects == 0 then rects = { coverageRect() } end

  local drops = {}
  local seen = {}
  for _, area in ipairs(rects) do
    local found = world.entityQuery({area[1], area[2]}, {area[3], area[4]}, {
      includedTypes = { "itemDrop" }
    })
    for _, dropId in ipairs(found or {}) do
      if not seen[dropId] then
        seen[dropId] = true
        table.insert(drops, dropId)
      end
    end
  end

  local rect = coverageRect()

  if drops == nil or #drops == 0 then
    --  "None in range" and "none at all" look identical from inside the rect,
    --  and the difference is the whole question when tuning coverage. Scan a
    --  wider box and report what is out there.
    local wide = { rect[1] - COVERAGE_SIZE, rect[2] - COVERAGE_SIZE,
                   rect[3] + COVERAGE_SIZE, rect[4] + COVERAGE_SIZE }
    local nearby = world.entityQuery({wide[1], wide[2]}, {wide[3], wide[4]}, {
      includedTypes = { "itemDrop" }
    })

    if nearby ~= nil and #nearby > 0 then
      return nil, string.format(
        "no drops in rect %s, but %s just outside (nearest %s)",
        sb.printJson(rect), #nearby, sb.printJson(world.entityPosition(nearby[1])))
    end

    return nil, "no drops in network coverage (own rect " .. sb.printJson(rect) .. ")"
  end

  sb.logInfo("PETPORT %s scan: %s drops in %s rects",
    stationUniqueId(), sb.printJson(#drops), sb.printJson(#rects))

  local origin = entity.position()
  local best, bestDistance = nil, nil

  --  Why each drop was passed over. The old message named only two of the three
  --  possible causes, so deferral -- the one that can deadlock -- was invisible
  --  and presented as a backoff that did not exist.
  local rejected = { claimed = 0, backedOff = 0, deferred = 0, gone = 0,
    unmergeable = 0, medium = 0 }

  self.deferredSince = self.deferredSince or {}
  local stillDeferred = {}

  for _, dropId in ipairs(drops) do
    local workId = "drop:" .. dropId
    local claim = petports_claimGet(workId)

    --  Someone else's live claim. Ours is fine to re-take.
    local failure = self.workFailures[workId]
    local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

    local free = not backedOff and ((claim == nil)
      or claim.owner == stationUniqueId()
      or (claim.expires or 0) <= world.time())

    if backedOff then
      sb.logInfo("PETPORT %s drop %s SKIPPED: backed off until %s (now %s, failures %s)",
        stationUniqueId(), sb.printJson(dropId),
        sb.printJson(failure["until"]), sb.printJson(world.time()),
        sb.printJson(failure.count))
      rejected.backedOff = rejected.backedOff + 1
    elseif not free then
      sb.logInfo("PETPORT %s drop %s SKIPPED: claimed by %s until %s",
        stationUniqueId(), sb.printJson(dropId),
        tostring(claim.owner), sb.printJson(claim.expires))
      rejected.claimed = rejected.claimed + 1
    elseif not world.entityExists(dropId) then
      sb.logInfo("PETPORT %s drop %s SKIPPED: entity gone",
        stationUniqueId(), sb.printJson(dropId))
      rejected.gone = rejected.gone + 1
    elseif mergeOnly and not dropMergesWithCargo(dropId) then
      --  Top-up pass: the unit is stalled holding cargo it cannot deposit, and
      --  may only pick up more of what it is already carrying.
      rejected.unmergeable = (rejected.unmergeable or 0) + 1
    else
      local position = world.entityPosition(dropId)
      if position == nil then
        rejected.gone = rejected.gone + 1

      --  MEDIUM BEFORE DISTANCE, so an ineligible drop does not win the
      --  comparison and end the rung. A drop is not an object, so this samples
      --  the single tile the item sits in -- which is the right question even
      --  where a mod has turned on item buoyancy, because a floating drop and a
      --  sunk one are then genuinely in different media and the fleet should
      --  divide them that way.
      elseif not targetEligible("drop " .. tostring(dropId), position, dropId) then
        rejected.medium = rejected.medium + 1
      else
        --  Distance is measured from the UNIT, not the port -- it is the unit
        --  that has to walk.
        local from = origin
        if self.petId ~= nil and world.entityExists(self.petId) then
          from = world.entityPosition(self.petId)
        end

        local distance = world.magnitude(from, position)

        --  Stand aside for a closer unit, but only for a while. See DEFER_GRACE.
        local defer = anotherUnitIsCloser(position, distance)
        if defer then
          local since = self.deferredSince[workId] or world.time()
          stillDeferred[workId] = since

          if world.time() - since >= DEFER_GRACE then
            sb.logInfo("PETPORT %s taking %s anyway: deferred %ss with no taker",
              stationUniqueId(), workId,
              sb.printJson(math.floor(world.time() - since)))
            defer = false
          end
        end

        if defer then
          sb.logInfo("PETPORT %s drop %s SKIPPED: deferred to a closer unit (ours %s away)",
            stationUniqueId(), sb.printJson(dropId), sb.printJson(distance))
          rejected.deferred = rejected.deferred + 1
        elseif bestDistance == nil or distance < bestDistance then
          sb.logInfo("PETPORT %s drop %s TAKEABLE at %s, %s away -- new best",
            stationUniqueId(), sb.printJson(dropId),
            sb.printJson(position), sb.printJson(distance))
          best, bestDistance = dropId, distance
        else
          sb.logInfo("PETPORT %s drop %s takeable but further (%s vs best %s)",
            stationUniqueId(), sb.printJson(dropId),
            sb.printJson(distance), sb.printJson(bestDistance))
        end
      end
    end
  end

  --  Drops no longer being deferred stop accruing. Rebuilt each pass rather
  --  than pruned, so a drop that vanishes cannot leak an entry.
  self.deferredSince = stillDeferred

  if best == nil then
    return nil, string.format(
      "%s drops in rect, none takeable: %s claimed, %s backed off, "
      .. "%s deferred to a closer unit, %s gone, %s in a medium this chassis "
      .. "cannot work in%s",
      #drops, rejected.claimed, rejected.backedOff,
      rejected.deferred, rejected.gone, rejected.medium,

      --  Only meaningful on a top-up pass, and silent otherwise. On a normal
      --  pass it is always zero, and a reason string listing a category that
      --  cannot apply is noise in the one line a player reads to find out why
      --  nothing is happening.
      mergeOnly and string.format(", %s that would not merge with the cargo",
        rejected.unmergeable) or "")
  end

  return {
    id = "drop:" .. best,
    --  The footprint ladder ran on this target above -- see arch.dispatch.vouch.
    mediumVerified = true,
    type = "collect",
    port = stationUniqueId(),
    target = best,
    position = world.entityPosition(best)
  }
end

--  LEASHING
--
--  Vanilla wanderState has NO BOUNDS. An idle unit walks wherever it likes, and
--  with backoffs in play there is plenty of idle time -- observed 25+ tiles
--  outside the rect, onto terrain with no route back up to the deck.
--
--  From out there every target is genuinely unreachable, so the port fails
--  repeatedly and backs off drops that were never the problem. One stray unit
--  poisons the whole queue.
--
--  So: if the unit is outside its rect and there is no work in flight, walking
--  home IS the work.
--
--  RECALL ALONE IS NOT ENOUGH. A unit can strand itself somewhere with no route
--  back -- onto terrain below the deck, most easily -- and then recall fails as
--  surely as any other task. Because recall is checked BEFORE real work, a
--  stranded unit means the port dispatches nothing but doomed recalls and
--  ignores every item forever. Observed exactly that.
--
--  So recall gets a small retry budget, and then the unit is RE-HOMED: despawned
--  and respawned at the port. The unit's state lives in the item, so this costs
--  nothing except the walk it was going to make anyway, and it always works.
--  Despawn and respawn at the port. The unit's learned state lives in the item,
--  so this costs nothing but the walk it was going to fail anyway.
local function rehomeUnit(reason)
  sb.logInfo("PETPORT %s re-homing unit: %s", stationUniqueId(), reason)

  --  Round-trips state through the item, exactly as an unsocket would.
  saveAndDespawn()
  self.recallFailures = 0
  self.unreachableFailures = 0
  self.spawnTimer = 0
end

--  PLACED BELOW rehomeUnit ON PURPOSE. It calls it, and a `local function`
--  called from above its definition is a nil GLOBAL that fails at the call
--  rather than at load. That has already cost this file one crash, so the rule
--  is now checked mechanically rather than by eye.

--  IS THE UNIT STILL GOING ANYWHERE?
--
--  Purely an observation from the port: position now against position last
--  check. No new contract function, and no dependence on the unit noticing its
--  own problem -- which matters, because every stranding found tonight was a
--  unit that believed it was fine and kept trying.
--
--  THREE EXCLUSIONS, and each one is a false positive that would otherwise
--  re-home a healthy unit:
--
--    parked at home    a tethered unit is motionless on purpose
--    it moved          anything covering HEALTH_MOVE between checks is alive
--    no unit           nothing to judge
--
--  PATIENT CLASSES, AND THE ONE PLACE THEIR NAMES ARE SPELLED.
--
--  These are settings keys, so a rename here is a save-compat break -- they are
--  listed once for the same reason the participation groups are.
MEDIC_CLASSES = { "player", "crew", "npc", "podpet", "animal", "unit" }

--  WHAT CLASS IS THIS ENTITY, IF ANY?
--
--  MEASURED, NOT GUESSED. Every branch below was observed in game 2026-08-30
--  against a live census -- see fact.unit.damageteams for the full table. The
--  three rules that survived contact:
--
--    damageTeamType IS THE DISCRIMINATOR. All five accept classes come back
--    `friendly`, spread across teams 0, 1 and 2, so anything comparing team
--    NUMBERS catches at most one of them. A hostile monster and a farm animal
--    are both team 2 and differ only in type.
--
--    TEAM NUMBER CARRIES SIGNAL IN EXACTLY ONE PLACE: among friendly MONSTERS,
--    0 is a capture-pod pet inheriting its owner's team, 2 is a farm animal on
--    the monster default.
--
--    petports_unit IS THE ONLY UNIT TEST. On the friendly team our units are
--    byte-identical to a Mooshi on every engine field -- monster, friendly,
--    team 2 -- so without the marker every medic treats every other unit as
--    livestock.
--
--  THE MARKER IS TESTED FIRST AND THAT ORDER IS LOAD-BEARING. `ghostly` is what
--  FISHING FISH come back as, and it is what our own units carried until this
--  session. A unit whose team somehow reads ghostly -- a modder copying old
--  files, a spawn parameter creeping back -- is still recognised as ours rather
--  than silently classed as a fish.
local function medicClassOf(id)
  local ok, kind = pcall(world.monsterType, id)
  if not ok then kind = nil end

  if petports_isUnitType(kind) then return "unit" end

  local team = world.entityDamageTeam(id)
  if team == nil or tostring(team.type) ~= "friendly" then
    return nil, team and tostring(team.type) or "no team"
  end

  local entityKind = tostring(world.entityType(id))
  if entityKind == "player" then return "player" end

  --  TEAM 0 SPLITS CREW FROM EVERY OTHER FRIENDLY NPC, and it is a mechanism
  --  rather than a coincidence: crew inherit the PLAYER's team so friendly fire
  --  cannot hit them, while villagers, tenants and guards sit on team 1.
  --  Measured 2026-08-30 -- a crew mechanic came back friendly/0 and a villager
  --  friendly/1 in the same census.
  --
  --  THEY ARE SEPARATE CLASSES BECAUSE THEY ARE SEPARATE DECISIONS. Crew are
  --  worth medical goods to almost everybody; ordinary NPCs can sleep in a bed
  --  and heal for free, so spending a trade good on one is a choice a player
  --  may well decline.
  if entityKind == "npc" then
    if team.team == 0 then return "crew" end
    return "npc"
  end

  --  Same team-0 rule, different meaning: a capture-pod pet also inherits its
  --  owner's team, while a farm animal sits on the monster default.
  if team.team == 0 then return "podpet" end
  return "animal"
end

--  IS THIS CLASS SWITCHED ON FOR THIS UNIT?
--
--  NAMED "HEALS", NOT "TREATS". A TREAT is the flavor system's word in this
--  mod -- petports_flavors.config, the feed slot on the Details tab -- so a
--  medic function called "treats" reads as being about food. The pane hit the
--  same collision: its five rows said "Treat players" and now say "Heal".
--
--  ON petData, NOT ON THE PORT, unlike the four participation groups. Those
--  describe what a PORT contributes to the network; these describe how a
--  player wants one medic's supplies allocated, and that preference should
--  travel with the pet when it is carried to another port.
--
--  DEFAULTS ON WHEN ABSENT, so a medic module socketed into an existing unit
--  works immediately rather than appearing broken until five boxes are ticked.
function petportMedicHeals(class)
  if self.petData == nil then return false end

  local settings = self.petData.medic
  if type(settings) ~= "table" then return true end
  return settings[class] ~= false
end

--  EVERY TREATABLE PATIENT IN COVERAGE, WORST FIRST.
--
--  WORST FIRST RATHER THAN NEAREST, which is a departure from every other task
--  in this mod and is inherited deliberately from nicemice_resolveHealTarget. A
--  medic walking past someone at 90% to reach someone at 20% is correct; a
--  hauler walking past the near crate is not.
local function medicPatients()
  local rect = coverageRect()

  --  MONSTER IS IN THE FILTER AND IS THE WHOLE POINT. Two of the five classes
  --  -- farm animals and capture-pod pets -- are monsters, and Nicemice's
  --  equivalent query asks for npc and player only.
  local candidates = world.entityQuery({rect[1], rect[2]}, {rect[3], rect[4]},
    { includedTypes = { "npc", "player", "monster" } })

  local out = {}

  for _, id in ipairs(candidates) do
    local class = medicClassOf(id)

    if class ~= nil and petportMedicHeals(class) then
      local health = world.entityHealth(id)

      --  NOT AT FULL HEALTH, with no threshold invented. A fraction was
      --  considered and rejected: the trigger is "wounded", and a percentage
      --  is a balance number nobody asked for.
      if type(health) == "table" and health[2] ~= nil and health[2] > 0
         and health[1] < health[2] then

        --  ALREADY DOSED IS NOT A PATIENT. The cooldown is network-wide, so
        --  this also stops a second port dispatching to someone our unit is
        --  already walking toward.
        if petports_healCooldownRemaining(id) <= 0 then
          table.insert(out, {
            id = id,
            class = class,
            ratio = health[1] / health[2],
            position = world.entityPosition(id)
          })
        end
      end
    end
  end

  table.sort(out, function(a, b) return a.ratio < b.ratio end)
  return out
end

--  A UNIT SITTING IN A MEDIUM ITS CHASSIS MAY NOT OCCUPY IS SENT HOME.
--
--  THIS IS THE OTHER HALF OF REMOVING THE ESCAPE CLAUSE. planMediumValid used to
--  let a displaced unit plan its own way out, and both versions of that licence
--  turned out to be a licence to fly somewhere else -- an aquatic unit crossed a
--  drain-held air gap into a second pool under it, twice, on 2026-08-31. The
--  unit now refuses to plan at all from an illegal medium, which makes it hold
--  still, which makes this the thing that has to notice.
--
--  RE-HOMING IS THE WHOLE RESPONSE, and it is the right one because it is what
--  the unit wanted anyway. A displaced pet belongs at its port; rehomeUnit is
--  instant, free, needs no pathing, and writes state and cargo back to the item
--  first. The recovery ladders all end here already -- this only arrives sooner
--  and with a reason attached.
--
--  ON THE ENVIRONMENT TIMER, NOT THE HEALTH ONE. HEALTH_INTERVAL is 30 seconds
--  and needs three strikes, which is 90 seconds of a swimmer sitting in open air
--  before anything reacts. ENVIRONMENT_INTERVAL is 5, and this is the same
--  family of question that timer already asks: "does where this unit is suit the
--  chassis it is".
--
--  TWO CONSECUTIVE POLLS, NOT ONE, AND THE SECOND ONE IS NOT CAUTION FOR ITS OWN
--  SAKE. petports_mediumAt requires EVERY row the body overlaps to be at or above
--  PETPORTS_SUBMERGED_FILL, so a swimmer riding just under a surface can read
--  "air" for an instant without having gone anywhere. Ten seconds of a genuinely
--  beached unit is cheap; teleporting a working one off a job because it bobbed
--  is not.
--
--  A WALKER IS NOT ASKED TWICE, IT IS NOT ASKED AT ALL. petports_outOfMedium
--  reports `checked = false` for a gravity-enabled chassis, because medium
--  permission is a free-mover concept and the answer would otherwise be a
--  meaningless true.
local function mediumCheck()
  if self.petId == nil or not world.entityExists(self.petId) then
    self.mediumStrikes = 0
    return
  end

  local called, answer = pcall(world.callScriptedEntity, self.petId,
    "petports_outOfMedium")

  --  A UNIT THAT CANNOT ANSWER IS LEFT ALONE, the same rule environmentCheck
  --  follows and for the same reason: callScriptedEntity returns nil silently
  --  for a function the target does not define, so a nil here is indistinguish-
  --  able from an older unit script. Failing closed would re-home working units
  --  over a partial install.
  if not called or type(answer) ~= "table" then return end
  if not answer.checked or not answer.out then
    self.mediumStrikes = 0
    return
  end

  self.mediumStrikes = (self.mediumStrikes or 0) + 1

  sb.logInfo("PETPORT %s unit is outside its own medium at %s (reads %s) -- "
    .. "poll %s of %s, it will plan nothing until this clears",
    stationUniqueId(), sb.printJson(answer.position), tostring(answer.medium),
    sb.printJson(self.mediumStrikes), sb.printJson(MEDIUM_STRIKE_LIMIT))

  if self.mediumStrikes >= MEDIUM_STRIKE_LIMIT then
    self.mediumStrikes = 0
    rehomeUnit("outside its own medium at "
      .. sb.printJson(answer.position) .. " (reads " .. tostring(answer.medium)
      .. ") for " .. tostring(ENVIRONMENT_INTERVAL * MEDIUM_STRIKE_LIMIT) .. "s")
  end
end

--  What is left is a unit sitting still, away from its port, for HEALTH_INTERVAL
--  x HEALTH_STALL_LIMIT. In a working fleet that state does not occur.
--
--  RE-HOMING IS CHEAP AND RECOVERABLE, which is what makes a rare false positive
--  acceptable: saveAndDespawn writes state and cargo back to the item first, so
--  the worst case is one abandoned task and a respawn at the port. The worst
--  case of NOT having this is a pet the player cannot find.
local function healthCheck()
  if self.petId == nil or not world.entityExists(self.petId) then
    self.healthAnchor = nil
    self.healthStalls = 0
    return
  end

  local position = world.entityPosition(self.petId)
  if position == nil then return end

  local anchor = self.healthAnchor
  self.healthAnchor = position

  local home = world.magnitude(position, entity.position()) <= HEALTH_HOME_SLACK
  local moved = anchor == nil or world.magnitude(position, anchor) > HEALTH_MOVE

  if home or moved then
    self.healthStalls = 0
    return
  end

  self.healthStalls = (self.healthStalls or 0) + 1

  sb.logInfo("PETPORT %s unit has not moved in %s check(s) of %ss at %s, %s tile(s) from "
    .. "the port and not on station -- %s",
    stationUniqueId(), sb.printJson(self.healthStalls), sb.printJson(HEALTH_INTERVAL),
    sb.printJson(position),
    sb.printJson(math.floor(world.magnitude(position, entity.position()))),
    (self.healthStalls >= HEALTH_STALL_LIMIT) and "RE-HOMING"
      or ("re-homing at " .. tostring(HEALTH_STALL_LIMIT)))

  if self.healthStalls >= HEALTH_STALL_LIMIT then
    self.healthStalls = 0
    self.healthAnchor = nil
    rehomeUnit("motionless away from the port for "
      .. tostring(HEALTH_INTERVAL * HEALTH_STALL_LIMIT) .. "s")
  end
end


--  WHERE SHOULD THIS PORT'S UNIT COME BACK TO?
--
--  ONE ANSWER, ONE CALLER TODAY, AND DELIBERATELY ITS OWN FUNCTION. `returnWork`
--  is the leash and `diagnosticWork` is a filler errand; they want different
--  things and conflating them is how the leash got a random point in the first
--  place. This is home. Nothing else should use it and nothing else does.
--
--  THE FLOOR BRANCH IS THE OLD BEHAVIOUR, BUG INCLUDED, AND THAT IS ON PURPOSE.
--  findStandingPoint picks its column with math.random and descends from the TOP
--  of the rect, so it returns the highest ledge in an arbitrary column rather
--  than the floor nearest the port -- see todo.pathing.standpointchoice. Fixing
--  that is a change to WALKER recall behaviour and this is a change to swimmer
--  and flyer recall behaviour; doing both in one build would make neither
--  attributable when the next log comes back.
local function homePosition()
  local tether = PETPORTS_TETHER_FLOOR

  if self.petData ~= nil and self.petData.monsterType ~= nil then
    tether = petports_habitatTether(self.petData.monsterType)
  end

  --  THE PORT'S OWN POSITION, UNRESOLVED, AND THAT IS THE WHOLE FIX.
  --
  --  A swimmer or a flyer has no use for a floor, and every resolver this mod
  --  owns answers "where can a body stand", which is the wrong question for
  --  them. The port sits in the medium the chassis was gated into -- the
  --  environment gate refuses to deploy a swimmer to a dry port at all -- so the
  --  port's own position is by construction somewhere the unit may be.
  --
  --  NOT NUDGED TO A LEGAL BODY POSITION HERE. The unit does that itself:
  --  approachTargetFor hands a "return" task's raw position to standableNear,
  --  which for a free mover is petports_flyPointNear and already finds the
  --  nearest spot the body fits, in a medium it may occupy, with sight of the
  --  target. Resolving here as well would be the router-and-walker split the
  --  handoff warns about, with the port's answer and the unit's disagreeing.
  if tether == PETPORTS_TETHER_PORT then
    return entity.position()
  end

  --  NOT BUILT. Named in the vocabulary because the field exists for it and a
  --  chassis that wants it is planned; refusing to invent an untested resolver
  --  for a chassis that does not exist yet is the same call as the rest of v1.0.
  --  Falls back to the port rather than the floor, because anything asking for a
  --  ceiling is a free mover and the floor is the answer least likely to suit it.
  if tether == PETPORTS_TETHER_CEILING then
    if not self.ceilingTetherWarned then
      self.ceilingTetherWarned = true
      sb.logInfo("PETPORT %s chassis %s asks to tether at the CEILING, which is not "
        .. "implemented -- recalling to the port itself instead",
        stationUniqueId(), tostring(self.petData and self.petData.monsterType))
    end

    return entity.position()
  end

  --  ASK THE UNIT. IT OWNS THIS ANSWER AND THE PORT NEVER DID.
  --
  --  This is the same call, with the same arguments, that the unit's own leash
  --  makes for itself -- `standableNear(portPosition, 0)` through
  --  approachTargetFor. Identical inputs into identical code, so the recall and
  --  the tether cannot resolve to different points. They did before: the tether
  --  descended to the floor under the port while the recall took a random column
  --  and the highest ledge in it, up to thirty tiles away.
  --
  --  searchUp 0 IS THE HOMEWARD BIAS AND IT IS NOT OPTIONAL HERE. findGroundPosition
  --  tests UP BEFORE DOWN at every step, so an unbiased resolve puts the unit on
  --  the port's own roof -- measured, [1203,728] resolving to [1203.5,731.875].
  --
  --  radius LEFT nil ON PURPOSE, so the unit's own default applies. Naming a
  --  number here would be a constant that has to be kept equal to one in another
  --  file, which is the drift this whole change exists to remove.
  local asked = homePointNear()
  if asked ~= nil then return asked end

  --  NO UNIT TO ASK. findStandingPoint is the fallback its own header always
  --  said it was, and it is KNOWN WRONG in three ways -- random column, descends
  --  from the top of the rect, cannot see platforms. It is here so a port with
  --  nothing socketed still produces something rather than nil, and it is no
  --  longer on the path any live unit takes home.
  return findStandingPoint({
    entity.position()[1] - 4, entity.position()[2] - 4,
    entity.position()[1] + 4, entity.position()[2] + 4
  }) or findStandingPoint(coverageRect())
end

local function returnWork()
  local rect = coverageRect()

  if self.petId == nil or not world.entityExists(self.petId) then return nil end

  --  STRANDED IS ABOUT REACHABILITY, NOT GEOGRAPHY.
  --
  --  This used to return early whenever the unit was inside coverage, on the
  --  assumption that a unit in the rect is a unit that is fine. A player
  --  unlinking the only vent out of an enclosed corridor breaks that: the unit
  --  sits WELL INSIDE the rect and cannot reach a single thing, including the
  --  port. The early return also reset recallFailures, so the counter could
  --  never climb and rehomeUnit -- the one thing that could have freed it --
  --  was unreachable code.
  --
  --  Both predicates now have to agree the unit is healthy. If it is failing to
  --  reach work, it falls through to the recall ladder regardless of where it
  --  is standing: a recall is attempted first, because a unit that CAN walk
  --  home should, and only a unit that cannot gets despawned and respawned.
  local stranded = (self.unreachableFailures or 0) >= STRANDED_LIMIT
  local inside = inNetwork(world.entityPosition(self.petId))

  --  THIS DECISION PRE-EMPTS ALL COLLECTION. returnWork is consulted before
  --  collectionWork, so whenever it returns a task the port collects nothing --
  --  and until now it did that silently.
  --
  --  CHANGE-GATED ON THE VERDICT, NOT ON THE POSITION. This ran every tick and
  --  was 159 lines of one short session, restating "inNetwork true stranded
  --  false" while a unit walked back and forth doing its job. Position is in
  --  the line because it is what makes a verdict actionable, but position is
  --  also what changes constantly -- so gating on it would gate on nothing.
  --
  --  The verdict and the two counters are the state worth seeing. Gated this
  --  way the line appears when the unit leaves the network, when it is judged
  --  stranded, and when either counter moves, which is exactly the set of
  --  moments anyone would go looking for it.
  local recallState = string.format("%s/%s/%s/%s", tostring(inside),
    tostring(stranded), tostring(self.unreachableFailures or 0),
    tostring(self.recallFailures or 0))

  if recallState ~= self.recallState then
    self.recallState = recallState

    sb.logInfo("PETPORT %s returnWork: unit at %s inNetwork %s stranded %s (unreachableFailures %s of %s, recallFailures %s of %s)",
      stationUniqueId(), sb.printJson(world.entityPosition(self.petId)),
      tostring(inside), tostring(stranded),
      sb.printJson(self.unreachableFailures or 0), sb.printJson(STRANDED_LIMIT),
      sb.printJson(self.recallFailures or 0), sb.printJson(RECALL_LIMIT))
  end

  if not stranded and inside then
    self.recallFailures = 0
    return nil
  end

  sb.logInfo("PETPORT %s returnWork: RECALLING -- collection is suppressed this pass",
    stationUniqueId())

  if (self.recallFailures or 0) >= RECALL_LIMIT then
    rehomeUnit("stranded outside rect at "
      .. sb.printJson(world.entityPosition(self.petId))
      .. " after " .. sb.printJson(RECALL_LIMIT) .. " failed recalls")
    return nil
  end

  --  WHERE HOME IS DEPENDS ON THE CHASSIS. See petports_habitatTether.
  --
  --  "RECALL TO A FIXED POINT, not a random one" was the intent of the previous
  --  version of this block, and the code did not honour it: findStandingPoint
  --  picks its column with math.random, so a walker got a different destination
  --  on every attempt too. The comment is kept because the intent was right; the
  --  floor branch below still has the defect and it is recorded, not fixed here.
  local position = homePosition()

  if position == nil then
    --  No standable spot in our own rect is a different problem, and recall
    --  cannot fix it either. UNREACHABLE for a port-tethered chassis, which
    --  always has an answer -- see homePosition.
    rehomeUnit("no standing point in rect to recall to")
    return nil
  end

  return {
    id = "return:" .. stationUniqueId(),
    type = "return",
    port = stationUniqueId(),
    position = position,
    dwell = 0.5
  }
end

--  Real work first, diagnostic only as an opt-in filler.
--  DEPOSIT: THE UNIT IS CARRYING SOMETHING AND SHOULD NOT BE DOING ANYTHING ELSE.
--
--  ANY CARGO IS A FULL LOAD, deliberately. One pixel and a thousand dirt are
--  the same state: "holding something, go put it down". Working out how many
--  radishes fit before a trip back is a real feature and not this one -- and
--  the version of it that guesses wrong is worse than the version that always
--  returns.
--  CAN THIS CRATE TAKE ANY OF WHAT WE ARE CARRYING?
--
--  Asks the engine the same question depositing asks, WITHOUT depositing.
--  world.containerItemsCanFit runs the real merge rules -- matching descriptors
--  top up existing partial stacks, non-matching ones need a free slot -- so a
--  crate with no empty slots but a half-full stack of the thing we are holding
--  correctly reads as usable.
--
--  WHY THIS REPLACES A BACKOFF. `fullContainers` marked the whole crate refused
--  for 60s the moment ANY stack bounced. One steak that needed a free slot
--  therefore diverted every stackable item in the load to a second crate, when
--  those items would have merged into stacks already sitting in the first. The
--  refusal was about one descriptor and was applied to all of them.
--
--  Returns nil when the engine cannot be asked, so the caller can fall back
--  rather than treating "unknown" as "no".
--  Will this crate take ANY stack the unit is carrying?
--
--  TWO QUESTIONS, ASKED TOGETHER. "Does the player allow it here" and "is there
--  physical room" are independent, and asking them in separate places is how a
--  denied item still ends up in a crate: containerItemsCanFit answers yes on
--  stack-merge grounds for an item the filter rejects, because the engine has
--  never heard of the filter. The filter is asked FIRST and a rejected stack is
--  never offered to the engine at all.
--
--  PER STACK, NEVER PER CONTAINER. The deposit-beacon bug this loop already
--  guards against: one steak needing a free slot backed off the whole crate and
--  diverted every stackable item in the load. A filter that rejects one stack
--  must likewise reject one stack.
--
--  Returns nil when the engine cannot answer, which is a different thing from
--  false and drives the time-based backoff fallback downstream. Filter-only
--  rejection is a real false, not a nil -- the player's rules are knowable
--  whether or not containerItemsCanFit exists.
local function containerTakesAny(containerId, filter)
  if self.petData == nil or self.petData.cargo == nil then return nil end

  local anyAllowed = false

  for _, stack in ipairs(self.petData.cargo) do
    if petports_filterAccepts(filter, stack.name) then
      anyAllowed = true

      if world.containerItemsCanFit == nil then
        --  Allowed by the filter, and the engine will not tell us about room.
        --  Fall through to the caller's backoff, which is what nil means.
        return nil
      end

      local fits = world.containerItemsCanFit(containerId, stack)
      if fits ~= nil and fits > 0 then return true end
    end
  end

  --  Nothing in the load is allowed here. Not a full crate -- a wrong crate --
  --  and the distinction matters because a full one clears itself and a wrong
  --  one never will.
  if not anyAllowed then return false end

  return false
end

--  ---------------------------------------------------------------------------
--  UPCYCLER ROUTING
--  ---------------------------------------------------------------------------

--  FORWARD-DECLARED, AND NOT OPTIONAL.
--
--  machineInputRoom below needs stackSizeOf, which is defined several hundred
--  lines further down. A `local function` is only in scope AFTER its
--  declaration, so a call from above it compiles as a GLOBAL lookup and is nil
--  at runtime -- no error at load, no error at parse, just a nil call the first
--  time a unit reaches an upcycler. This mod has already paid for that once:
--  see the leash bug caused by a forward-referenced local.
--
--  Declaring the name here and ASSIGNING to it at the original site keeps one
--  definition and makes the whole file see it.

--  Same again. upcyclerWork screens its candidates with claimFree, and the
--  claim helpers live with the SOIL section far below -- so without this the
--  call compiles as a global lookup and is nil at runtime, silently making
--  every machine look available and putting the whole fleet back on one
--  machine. Exactly the failure stackSizeOf already paid for.
local claimFree


--  An upcycler's input slot. Zero-based, like every container OFFSET; the keys
--  world.containerItems returns are one-based, which is what SLOT_KEY_TO_OFFSET
--  exists to reconcile. Nothing here goes through those keys.
MACHINE_SLOT_INPUT = 0

--  THE REAGENT SLOT, AND YES THIS IS THE THIRD COPY OF A NUMBER THAT LIVES IN
--  petports_upcycler.lua. Deliberate for now -- see todo.upcycler.slotorderdup.
--  If a SLOT_ constant moves over there, this moves with it, and the failure is
--  a unit posting surplus into whatever the slot became.
MACHINE_SLOT_REAGENT = 1

--  DO NOT WALK ACROSS A BASE TO DELIVER TWENTY BLOCKS.
--
--  Measured: with a machine consuming 5 items a second and a round trip of
--  about 4.6 seconds, a drain sized to "whatever room exists right now" settles
--  at ~23 items a trip. The unit spends its entire life topping up one
--  already-full machine, every other machine starves, and the network's
--  throughput collapses to one stack per four minutes.
--
--  A minimum batch turns that into "wait until the machine has burned enough to
--  be worth the walk". Expressed as a FRACTION OF A STACK rather than a count,
--  so it means the same thing for blocks that stack to 1000 and for weapons
--  that stack to 1.
--
--  CAPPED BY THE SURPLUS ITSELF, at the call site: a network only 30 items over
--  its threshold should still deliver those 30 and finish the job, rather than
--  holding out for a batch that will never exist.
MACHINE_MIN_BATCH = 0.25

--  How many of `stack` the machine's INPUT slot could take right now.
--
--  NOT world.containerItemsCanFit, which answers for the WHOLE container -- it
--  would count the output and reagent slots as room and send a unit walking to
--  a machine whose input is full. Slot-precise, because delivery is
--  slot-precise: containerPutItemsAt(id, stack, 0) and nothing else.
--  How much of this stack a NAMED SLOT could take. The name-specific answer:
--  zero when the slot holds something else, the free headroom when it holds
--  the same item, a full stack when empty. Every caller that used to ask
--  machineInputRoom now goes through machineRuleRoom below, which is why no
--  input-only wrapper survives.
local function machineSlotRoom(machineId, slot, stack)
  local ok, held = pcall(world.containerItemAt, machineId, slot)
  if not ok then return 0 end

  local limit = stackSizeOf(stack.name)

  if type(held) ~= "table" or held.name == nil then return limit end

  --  A DIFFERENT ITEM IS NOT ROOM. The player can park anything in any slot by
  --  hand, and a machine chewing through someone's ore is not a state to route
  --  more cargo into.
  if held.name ~= stack.name then return 0 end

  --  SAME NAME IS NOT SAME ITEM, AND THE PATROL LOG PROVED IT. Measured
  --  2026-08-29: dispatch said "room for 1000", both puts refused all 1000,
  --  sub-second loop. Milk is food, food carries rot state in parameters, and
  --  the engine merges by DESCRIPTOR -- a slot of older milk offers no room to
  --  fresher milk however much headroom the name math sees. Compared only when
  --  the caller HAS parameters: drain's synthetic name-only probe stays an
  --  estimate, and the per-stack cap at its take site is what makes that safe.
  if stack.parameters ~= nil and not compare(held.parameters, stack.parameters) then
    return 0
  end

  local room = limit - (held.count or 0)
  if room < 0 then return 0 end

  return room
end

--  THE ROOM A RULE ACTUALLY OFFERS THIS STACK -- the sum of every slot the
--  rule's checkboxes leave open. This is the ONE predicate dispatch and
--  arrival must share: the patrol bug class is exactly a dispatch that asked
--  about the burner while the arrival routed reagent-first, so any change to
--  which slots a delivery may use has to happen HERE and nowhere else.
--
--    burn ~= false      the burner counts
--    reagent ~= false   the reagent slot counts, IF the manifest calls the
--                       item a reagent -- same test the arrival routing runs
--
--  Both denied is a rule that accepts nothing, and it correctly reads as zero
--  room everywhere: no dispatch, no walk, no backoff loop.
local function machineRuleRoom(machine, rule, stack)
  local room = 0

  if rule.burn ~= false then
    room = room + machineSlotRoom(machine.id, MACHINE_SLOT_INPUT, stack)
  end

  if rule.reagent ~= false and petports_reagentFor(stack.name) ~= nil then
    room = room + machineSlotRoom(machine.id, MACHINE_SLOT_REAGENT, stack)
  end

  return room
end

--  How empty is the input slot, regardless of what we intend to put there.
--
--  SEPARATE FROM machineSlotRoom, WHICH IS NAME-SPECIFIC. That one answers
--  "could this stack go in", and returns zero when the slot holds something
--  else -- correct for deciding a delivery, useless for ranking machines
--  against each other, because every busy machine would score zero and the
--  ordering would collapse back to scan order.
--
--  Reads the slot's OWN item to size it, so a slot holding 200 of something
--  that stacks to 1000 scores 800 whatever the unit happens to be carrying.
local function machineInputFree(machineId)
  local ok, held = pcall(world.containerItemAt, machineId, MACHINE_SLOT_INPUT)
  if not ok then return 0 end

  if type(held) ~= "table" or held.name == nil then
    --  Empty slot. Ranked above every partly-full one, which is the whole
    --  point: a starving machine should win.
    return math.huge
  end

  local free = stackSizeOf(held.name) - (held.count or 0)
  if free < 0 then return 0 end

  return free
end

--  Does this machine currently want any of the load?
--
--  THREE CONDITIONS, ALL REQUIRED, AND THE ORDER IS THE ARGUMENT.
--
--    1  a rule names the item -- the machine may only ever receive things the
--       player explicitly named. This is NOT a fallback destination; an item
--       with no rule is refused here exactly as it would be by a crate whose
--       filter rejects it.
--    2  the census says the network holds MORE than the threshold -- strictly
--       greater, so a threshold of N leaves N reachable and stable rather than
--       oscillating at N-1.
--    3  the input slot has room for it.
--
--  Condition 3 is deliberately part of "wants", not a separate backoff. A
--  machine that cannot take the stack right now should be passed over so the
--  load falls through to ordinary storage -- overshooting the threshold is soft
--  and self-correcting, where a unit parked holding cargo is not.
--  Returns true, or false and WHY NOT.
--
--  THE REASON IS THE POINT. Four conditions decline for four completely
--  different causes with four different fixes -- switch it on, name the item,
--  lower the threshold, empty the input -- and from outside they are one
--  identical silence: a unit walking past a machine to a crate.
--  WILL ORDINARY STORAGE TAKE ANY OF THIS LOAD RIGHT NOW?
--
--  THE QUESTION THAT DECIDES WHETHER THE BATCH FLOOR APPLIES. The floor exists
--  so a unit does not walk across a base to deliver twenty blocks -- a pure
--  throughput argument, and a good one WHILE THERE IS SOMEWHERE ELSE TO PUT THE
--  LOAD. Waiting is free when the cargo is safe in a crate either way.
--
--  It is not free when the cargo has nowhere to go. A unit holding an
--  undeliverable load does not collect -- cargo outranks collection, by design,
--  so it does not hoard -- which means every drop in coverage sits there
--  decaying while the network optimises its walking distance. Items ceasing to
--  exist is the worst outcome available, and it outranks every efficiency
--  argument in this file.
--
--  Deliberately the same shape as the test depositWork runs a moment later.
--  Duplicated rather than shared because the two want different answers: this
--  asks "is there an alternative", that one asks "which crate".
local function storageWouldTakeAny()
  if self.petData == nil then return false end

  --  NOTHING TO PLACE IS NOT AN OBSTRUCTION.
  --
  --  This iterated the cargo and returned false when there was none, so an
  --  empty unit read as "storage will not take it" -- which made every fresh
  --  drop on the ground triage to the blocked marker instead of the unclaimed
  --  one. The question is whether storage can accept A LOAD; with no load, the
  --  honest answer is that nothing is in the way.
  --
  --  Safe for the batch-floor waiver too: upcyclerWork returns before it asks
  --  when the cargo is empty.
  if self.petData.cargo == nil or #self.petData.cargo == 0 then return true end

  for _, beacon in ipairs(petports_beaconsFor("deposit")) do
    if world.entityExists(beacon.id) then
      for _, stack in ipairs(self.petData.cargo) do
        if petports_filterAccepts(beacon.filter, stack.name) then
          --  nil means the engine will not answer. Treated as YES here, which
          --  is the opposite of tidyWork's reading and deliberate: guessing
          --  wrong costs a slightly inefficient trip, where guessing the other
          --  way could waive the floor when it should not have been.
          local fits = world.containerItemsCanFit ~= nil
            and world.containerItemsCanFit(beacon.id, stack) or nil

          if fits == nil or fits > 0 then return true end
        end
      end
    end
  end

  return false
end

local function machineWantsAny(machine, floorWaived)
  if machine.kind ~= "upcycler" then return false, "not an upcycler" end
  if not machine.enabled then return false, "switched off" end

  if self.petData == nil or self.petData.cargo == nil then
    return false, "no cargo"
  end

  local reasons = {}

  for _, stack in ipairs(self.petData.cargo) do
    local rule = nil

    for _, candidate in ipairs(machine.rules) do
      if candidate.item == stack.name then
        rule = candidate
        break
      end
    end

    if rule == nil then
      table.insert(reasons, string.format("%s: no rule names it", tostring(stack.name)))
    else
      --  THE STACK IN HAND IS PART OF THE NETWORK'S HOLDINGS.
      --
      --  The census counts CRATES, so the moment a unit picks a stack up the
      --  count drops by that much -- 6000 dirt in storage reads as 5000 while a
      --  unit carries the other 1000 to a machine. Comparing that against a
      --  threshold of 5000 says "no longer surplus", and the unit walks the
      --  whole way there and carries it back.
      --
      --  MEASURED EXACTLY THAT: 6000 held, threshold 5000, unit collects 1000,
      --  arrives, finds 5000, returns it to storage. 6000 held. Repeat.
      --
      --  Adding what is being carried asks the question that actually matters:
      --  would the network be over its threshold if this stack were put back?
      local held = ((self.census or {})[stack.name] or 0) + (stack.count or 0)

      --  A TRIP HAS TO BE WORTH TAKING -- THE SAME FLOOR drainWork USES.
      --
      --  This test was `room < 1`, and the emergent behaviour was ugly. With
      --  five full machines, a unit holding 978 dirt orbited all five forever,
      --  delivering fifteen or twenty at a time and never filing the rest.
      --  Measured, verbatim:
      --
      --    upcycled 21 of 963 ... room for 13, 25 tile(s) away
      --    upcycled 0 of 978  ... room for 15, 13 tile(s) away
      --
      --  Any room above zero counted as "wants", so ordinary storage was never
      --  reached and the census sat at 6000 while the dirt rode around on a
      --  unit. The floor was written into drainWork and never applied here,
      --  which is the whole bug.
      --
      --  CAPPED BY THE STACK, so a unit holding thirty blocks can still deliver
      --  thirty. This is about not walking across a base for a handful, not
      --  about refusing small loads.
      --  WAIVED WHEN NOTHING ELSE WILL TAKE THE LOAD. See storageWouldTakeAny:
      --  with storage full and drops decaying on the ground, an inefficient
      --  drip-feed into whatever room a machine has is strictly better than a
      --  parked unit and a pile of items timing out. Trips get ugly; nothing is
      --  destroyed.
      local batch = 1

      if not floorWaived then
        batch = math.min(
          math.ceil(stackSizeOf(stack.name) * MACHINE_MIN_BATCH),
          stack.count or 1)
      end

      --  THE SAME ROOM THE ARRIVAL WILL USE. machineRuleRoom sums every slot
      --  the rule's checkboxes leave open -- this used to ask about the burner
      --  alone while depositCargoToMachine routed reagent-first, and a
      --  disagreement between those two is a unit dispatched to a delivery
      --  that cannot land, walking it off in front of the machine.
      local room = machineRuleRoom(machine, rule, stack)

      if held <= rule.max then
        --  STRICTLY GREATER, so a threshold of N leaves N reachable and stable
        --  rather than oscillating at N-1.
        table.insert(reasons, string.format("%s: network holds %s, threshold %s",
          tostring(stack.name), tostring(held), tostring(rule.max)))
      elseif room < batch then
        --  Deliberately part of "wants" rather than a backoff. A machine that
        --  cannot take a worthwhile amount is passed over so the load falls
        --  through to ordinary storage -- overshooting a threshold is soft and
        --  self-correcting, and drainWork pulls it back out later when a machine
        --  has real room. A unit orbiting full machines is neither.
        table.insert(reasons, string.format("%s: input has room for %s, want %s%s",
          tostring(stack.name), tostring(room), tostring(batch),
          floorWaived and " (floor waived, storage full)" or ""))
      else
        return true
      end
    end
  end

  return false, table.concat(reasons, "; ")
end

--  How much of the load this machine could take, total.
--
--  THE SCORE THAT ORDERS CANDIDATES. An emptier machine takes more, so ranking
--  by this is the same thing as "feed the starving one first" without needing a
--  separate notion of hunger.
local function machineRoomFor(machine)
  local room = 0

  for _, stack in ipairs((self.petData and self.petData.cargo) or {}) do
    for _, rule in ipairs(machine.rules) do
      if rule.item == stack.name then
        --  Carried stock counts, same as in machineWantsAny -- a score computed
        --  on a different rule than the decision would rank machines for a
        --  delivery that never happens.
        local held = ((self.census or {})[stack.name] or 0) + (stack.count or 0)

        if held > rule.max then
          room = room + math.min(stack.count or 0,
            machineRuleRoom(machine, rule, stack))
        end
      end
    end
  end

  return room
end

--  UPCYCLING OUTRANKS IDLE STORAGE, AND SITS BELOW RESTOCK.
--
--  Called from the top of depositWork, which is already below
--  restockDeliverWork in findWork -- so the order is restock, then upcycler,
--  then ordinary crates. That is the whole "threshold is a cap on idle storage"
--  idea expressed as ordering: over-threshold cargo goes to the machine while
--  it can, and falls through to a crate when it cannot.
--
--  EMPTIEST FIRST, THEN NEAREST.
--
--  Nearest-first alone produced a measured pathology: one unit adopted the
--  closest machine, kept it perpetually full, and every other machine in the
--  network starved. Distance is the wrong primary key because it never changes,
--  so the winner never changes either.
--
--  Room does change, and ranking by it is self-balancing without any notion of
--  fairness or round-robin: a machine that has just been fed drops to the
--  bottom of the list on its own, and rises again as it burns through what it
--  was given. Distance stays as the tie-break, so two equally hungry machines
--  still resolve to the cheaper walk.
--
--  "STRICTER THRESHOLD WINS" STILL EMERGES, just for a different reason than
--  before. The machine with the lower threshold keeps declaring surplus after
--  the higher one has stopped, so it keeps being a candidate at all -- which
--  outranks any ordering among candidates.
local function upcyclerWork()
  if self.petData == nil then return nil end
  if self.petData.cargo == nil or #self.petData.cargo == 0 then return nil end

  local candidates = {}
  local declined = {}
  local origin = entity.position()

  --  COMPUTED ONCE PER DISPATCH, not per machine. It is the same answer for
  --  every candidate, and it walks every deposit beacon against every cargo
  --  stack -- not something to repeat five times.
  local floorWaived = not storageWouldTakeAny()

  --  CHANGE-GATED. This is a genuinely unusual state and the player almost
  --  certainly wants to know they are in it: storage is full, so the network has
  --  stopped optimising and is drip-feeding machines to keep drops from timing
  --  out. Silent, it just looks like the inefficiency that was fixed two builds
  --  ago coming back.
  if floorWaived ~= self.floorWaived then
    self.floorWaived = floorWaived

    if floorWaived then
      sb.logInfo("PETPORT %s storage will not take the load -- WAIVING the "
        .. "upcycler batch floor to keep drops from decaying", stationUniqueId())
    else
      sb.logInfo("PETPORT %s storage has room again -- upcycler batch floor "
        .. "back in force", stationUniqueId())
    end
  end

  for _, machine in ipairs(self.machines or {}) do
    --  HONOUR THE BACKOFF. Every other generator checks workFailures and this
    --  one did not, so a delivery that arrived to a full slot was recorded and
    --  then immediately ignored -- the unit re-targeted the same machine on the
    --  next tick and orbited the set. The record only helps if something reads
    --  it.
    --  EXCLUSIVE ACROSS PORTS -- NO PORT SUFFIX.
    --
    --  This carried the port id on the reasoning that several units CAN share a
    --  destination, because containerPutItemsAt gives every arrival a truthful
    --  leftover. That holds while room is plentiful and inverts exactly when it
    --  is not -- which is the state the batch floor waiver exists for.
    --
    --  Measured: with storage full, every port ranked the same machine highest,
    --  three units walked there as a pack, the leader took the twenty items
    --  available and the rest arrived at zero. One unit per machine at a time
    --  is the honest model when a machine's room is the scarce resource.
    local workId = "upcycle:" .. tostring(machine.id)
    local failure = self.workFailures[workId]
    local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

    if backedOff then
      table.insert(declined, string.format("%s@%s,%s (backed off, %s failure(s))",
        tostring(machine.kind),
        tostring(math.floor(machine.position[1])),
        tostring(math.floor(machine.position[2])),
        tostring(failure.count)))

    --  ALREADY SPOKEN FOR -- AND THIS WAS THE MISSING FILTER.
    --
    --  Every other generator screens its candidates with claimFree before
    --  offering one. This did not, so making the claim exclusive stopped three
    --  units from SUCCEEDING at the same machine without stopping them from
    --  WALKING there: the loser found out on arrival, having spent the trip.
    --
    --  With this, a port whose first choice is taken simply moves to the next
    --  emptiest, which is what spreads the fleet across machines. Ordering
    --  decides preference; claims decide availability. Trying to make ordering
    --  do both is what produced the nearest-first mistake above.
    elseif not claimFree(workId) then
      table.insert(declined, string.format("%s@%s,%s (claimed by another unit)",
        tostring(machine.kind),
        tostring(math.floor(machine.position[1])),
        tostring(math.floor(machine.position[2]))))

    elseif world.entityExists(machine.id) then
      local wants, why = machineWantsAny(machine, floorWaived)

      if wants then
        table.insert(candidates, {
          machine = machine,
          room = machineRoomFor(machine),
          distance = world.magnitude(origin, machine.position)
        })
      else
        table.insert(declined, string.format("%s@%s,%s (%s)",
          tostring(machine.kind),
          tostring(math.floor(machine.position[1])),
          tostring(math.floor(machine.position[2])),
          tostring(why)))
      end
    end
  end

  if #candidates == 0 then
    --  CHANGE-GATED, because a unit holding cargo no machine wants asks this
    --  question several times a second and the answer is usually the same one.
    --  Silence here was the whole problem: a unit walking past a machine to a
    --  crate looks identical whatever the reason.
    local report = table.concat(declined, " || ")

    if #declined > 0 and report ~= self.upcyclerDeclined then
      self.upcyclerDeclined = report
      sb.logInfo("PETPORT %s upcycler declined: %s", stationUniqueId(), report)
    end

    return nil
  end

  self.upcyclerDeclined = nil

  --  EMPTIEST FIRST, ALWAYS. DISTANCE ONLY BREAKS TIES.
  --
  --  This briefly inverted to nearest-first while the batch floor was waived,
  --  on the reasoning that scarcity makes trips tiny and the walk dominates.
  --  THAT REASONING WAS WRONG, and the result was worse than the problem: the
  --  two machines closest to the fleet stayed topped up with one- and two-item
  --  deliveries while the three furthest starved at maximum room.
  --
  --  ROOM IS DELIVERY SIZE. A machine with a thousand free is a thousand-item
  --  trip; a machine with twenty free is a twenty-item trip. Trips were never
  --  small because of scarcity -- they were small because the ranking kept
  --  choosing machines that could not accept anything. Sorting by room IS
  --  sorting by trip value, and it is self-balancing for free: a machine that
  --  was just fed sinks to the bottom and rises as it burns through what it got.
  table.sort(candidates, function(a, b)
    if a.room ~= b.room then return a.room > b.room end
    return a.distance < b.distance
  end)

  for _, candidate in ipairs(candidates) do
    local machine = candidate.machine

    --  Stand next to it, not on it -- same reason as a deposit crate, and
    --  resolved by the unit for the same reason: a point the unit cannot occupy
    --  fails the last leg of the route and therefore the whole plan.
    local stand, standWhy = servicePointNear("upcycler " .. tostring(machine.id),
      machine.id, machine.position, 4)

    if stand == nil then
      sb.logInfo("PETPORT %s upcycler %s SKIPPED: %s of %s",
        stationUniqueId(), sb.printJson(machine.id), tostring(standWhy),
        sb.printJson(machine.position))
    else
      sb.logInfo("PETPORT %s upcycling to %s at %s: room for %s, %s tile(s) away (%s candidate(s), %s)",
        stationUniqueId(), tostring(machine.kind), sb.printJson(machine.position),
        sb.printJson(candidate.room), sb.printJson(math.floor(candidate.distance)),
        sb.printJson(#candidates),
        floorWaived and "batch floor waived, storage full" or "normal")

      return {
        --  Keyed by machine AND port, for the reason spelled out on the deposit
        --  task: a claim keyed by container alone is exclusive, and the first
        --  port to take it locks every other port's unit out of the machine.
        --  MUST MATCH the workId the backoff check above computes, or a
        --  recorded failure is filed under a key nothing ever looks up.
        id = "upcycle:" .. tostring(machine.id),
        --  The footprint ladder ran on this target above -- see arch.dispatch.vouch.
        mediumVerified = true,
        type = "upcycle",
        target = machine.id,
        position = stand,
        containerPosition = machine.position,
        port = stationUniqueId(),
        dwell = 0
      }
    end
  end

  return nil
end

local function depositWork()
  if self.petData == nil then return nil end
  if self.petData.cargo == nil or #self.petData.cargo == 0 then return nil end

  --  THE MACHINE GETS FIRST REFUSAL ON OVER-THRESHOLD CARGO. See upcyclerWork:
  --  it returns nothing unless a rule names the item, the census says the
  --  network is over the threshold, and the input slot has room -- so anything
  --  else falls straight through to the crates below.
  local upcycle = upcyclerWork()
  if dispatchable(upcycle) ~= nil then return upcycle end

  local targets = petports_beaconsFor("deposit")
  if #targets == 0 then
    --  Change-gated by the reject machinery upstream; a unit with cargo and no
    --  beacon anywhere is a state the player needs to see, not a per-second
    --  line.
    return nil, "carrying " .. sb.printJson(#self.petData.cargo)
      .. " stack(s) but no deposit beacon in coverage"
  end

  local now = world.time()
  self.fullContainers = self.fullContainers or {}

  for _, beacon in ipairs(targets) do
    --  Ask the crate directly. Only if the engine will not answer do we fall
    --  back to the blunt time-based backoff.
    local takesAny = containerTakesAny(beacon.id, beacon.filter)
    local backedOff

    if takesAny == nil then
      backedOff = (self.fullContainers[beacon.id] or 0) > now
      if backedOff then
        sb.logInfo("PETPORT %s deposit target %s SKIPPED: was full, retrying in %s (no containerItemsCanFit)",
          stationUniqueId(), sb.printJson(beacon.id),
          sb.printJson((self.fullContainers[beacon.id] or 0) - now))
      end
    else
      backedOff = not takesAny
      if backedOff then
        --  NAMES THE STACKS, not just the count. Cargo can now be mixed -- a
        --  unit may hold an undepositable stack AND a seed it is on its way to
        --  plant -- so "cannot take any of 2 stacks" stopped being enough to
        --  tell a full crate from a wrong-item crate.
        local held = {}
        for _, stack in ipairs(self.petData.cargo) do
          table.insert(held, string.format("%sx%s",
            tostring(stack.name), tostring(stack.count or 1)))
        end

        --  WHY it was skipped, not just that it was. A full crate empties and
        --  retries; a crate whose filter rejects the load never will. Reading
        --  "cannot take any of [...]" for both is how an afternoon goes into
        --  diagnosing a filter as a capacity problem.
        local reason = "full"
        if beacon.filter ~= nil then
          local allowed = false
          for _, stack in ipairs(self.petData.cargo) do
            if petports_filterAccepts(beacon.filter, stack.name) then
              allowed = true
              break
            end
          end
          if not allowed then reason = "filter rejects every stack" end
        end

        sb.logInfo("PETPORT %s deposit target %s SKIPPED (%s): cannot take any of [%s]",
          stationUniqueId(), sb.printJson(beacon.id), reason, table.concat(held, ", "))
      end
    end

    if backedOff then
      --  nothing further; try the next beacon
    else
      --  Stand next to the container, not on it. The container's own position
      --  is not a standing position for the same reason a petport's is not --
      --  see the arrival test in PathMover:move, which wants the vertical
      --  component under one tile.
      --
      --  Resolved BY THE UNIT. A point the unit cannot occupy is rejected by
      --  validStandingPosition before pathing starts, which fails the last leg
      --  of the route and therefore the entire plan -- the unit does not move at
      --  all, and the log reads as a vent failure rather than a bad target.
      local stand, standWhy = servicePointNear("crate " .. tostring(beacon.id),
        beacon.id, beacon.position, 4)

      if stand == nil then
        sb.logInfo("PETPORT %s deposit target %s SKIPPED: %s of %s",
          stationUniqueId(), sb.printJson(beacon.id), tostring(standWhy),
          sb.printJson(beacon.position))
      else

        return {
          --  KEYED BY CONTAINER **AND PORT**. The port half is what matters.
          --
          --  This was keyed by container alone, on the reasoning that
          --  serialising deposits into one chest cost nothing. It cost five
          --  units. Claims are exclusive, so the first port to claim
          --  "deposit:24" owned the crate outright and every other port was
          --  refused with "claimed by another owner" -- their units got no
          --  task, fell back to station-keeping, walked a couple of tiles
          --  toward their ports, were re-dispatched, and were refused again.
          --  That shuffle is what looked like units stuck sliding back and
          --  forth on two tiles.
          --
          --  There is nothing to serialise. containerAddItems already returns
          --  its own overflow per call, so two units arriving at once each get
          --  a truthful answer about what was taken, and each backs the
          --  container off independently if it filled.
          --
          --  Container id stays in the string for readability in claims and
          --  logs; the port id is what makes it non-exclusive.
          id = "deposit:" .. tostring(beacon.id) .. "@" .. stationUniqueId(),
          --  The footprint ladder ran on this target above -- see arch.dispatch.vouch.
          mediumVerified = true,
          type = "deposit",
          target = beacon.id,
          position = stand,
          containerPosition = beacon.position,
          port = stationUniqueId(),
          dwell = 0
        }
      end
    end
  end

  return nil, "every deposit beacon is backed off as full"
end

--  Take up to `count` from ONE slot, and hand back what actually left.
--
--  THIS EXISTS BECAUSE containerConsume LOSES PARAMETERS. Both withdraw paths
--  used to consume `{ name = ..., count = ... }` and then hand receiveCargo a
--  descriptor rebuilt from the same two values. receiveCargo has always stored
--  parameters correctly -- it even compares them when merging stacks -- so the
--  damage was entirely in what its callers passed it.
--
--  What that cost, measured: a request for 500 sb_musicsheet collected every
--  sheet in storage regardless of track and delivered them as one stack of
--  parameterless sheets. The same shape strips the dye off clothing, which
--  makes this a data-loss bug in the SORTER rather than anything restock
--  specific -- tidying a dyed shirt out of a deposit crate would have done it
--  too. It never surfaced because seeds and liquids, the only things this path
--  carried until now, have no parameters.
--
--  SLOT-PRECISE, SO NOTHING HAS TO BE MATCHED. containerTakeNumItemsAt names an
--  offset rather than a descriptor, and RETURNS what it consumed -- so the
--  parameters come back from the engine rather than being predicted, and there
--  is no read-then-consume window for the crate to change in.
--
--  It also fixes the eviction artifact at its source. withdrawMisfit took its
--  count by NAME, so evicting 2 hazard blocks came off the front of a
--  thousand-stack and left 998 + 2. tidyWork has always known the real slot; it
--  was only being logged.
--
--  THE KEYS FROM containerItems ARE NOT THE OFFSETS THIS WANTS. SUBTRACT ONE.
--
--  The container's own slots are 0-indexed and so is this offset, but the Lua
--  table the binding hands back is 1-based -- a JsonArray converted to Lua, and
--  the two claims were never the same claim. Assuming they matched produced:
--
--    withdraw of liquidhealing from 105 took nothing:
--      every slot holding it refused to give any up
--
--  Every take returned nil with the mismatch guard silent, which is an offset
--  landing on an EMPTY slot rather than on the wrong item.
--
--  MEASURED, NOT ASSUMED. A build that tried offset+0 then offset-1 and cached
--  whichever verified reported `container slot bias is -1: containerItems key 7
--  is offset 6`, twice in separate sessions, and -1 is the convention visible
--  in other scripts. The probe is gone: it had to TAKE a stack to test a
--  candidate, and putting a rejected one back with containerAddItems can land
--  it in a different slot and stale the snapshot the next attempt uses.
SLOT_KEY_TO_OFFSET = -1

--  Take up to `count` from ONE slot, and hand back what actually left.
--
--  THIS EXISTS BECAUSE containerConsume LOSES PARAMETERS. Both withdraw paths
--  used to consume `{ name = ..., count = ... }` and then hand receiveCargo a
--  descriptor rebuilt from the same two values. receiveCargo has always stored
--  parameters correctly -- it even compares them when merging stacks -- so the
--  damage was entirely in what its callers passed it.
--
--  What that cost, measured: a request for 500 sb_musicsheet collected every
--  sheet in storage regardless of track and delivered them as one stack of
--  parameterless sheets. The same shape strips the dye off clothing, which
--  makes this a data-loss bug in the SORTER rather than anything restock
--  specific -- tidying a dyed shirt out of a deposit crate would have done it
--  too. It never surfaced because seeds and liquids, the only things this path
--  carried until now, have no parameters.
--
--  SLOT-PRECISE, SO NOTHING HAS TO BE MATCHED. containerTakeNumItemsAt names an
--  offset rather than a descriptor, and RETURNS what it consumed -- so the
--  parameters come back from the engine rather than being predicted, and there
--  is no read-then-consume window for the crate to change in.
--
--  It also fixes the eviction artifact at its source. withdrawMisfit took its
--  count by NAME, so evicting 2 hazard blocks came off the front of a
--  thousand-stack and left 998 + 2. tidyWork has always known the real slot; it
--  was only being logged.
--
--  VERIFIED AND PUT BACK IF WRONG. The check earns its keep on more than the
--  offset: two music sheets share a name and differ only in parameters, so
--  `taken.name == expected.name` alone would have accepted the wrong track.
--  compare() is what makes this safe for items whose identity is not their
--  name -- which is the whole point of the change.
--  THE TIDY SCORE, COUNTED AT THE MOMENT IT HAPPENS. See dd.dispatch.tidyscore:
--  when a unit removes the LAST STACK OF A TYPE from a container, +1. An event,
--  an integer, and monotonic by construction -- every put the fleet makes is
--  filter-approved, so no unit can add a type a container did not ask for.
--
--  BY NAME, AND THAT IS THE RIGHT GRAIN. world.containerAvailable counts by
--  name, not descriptor -- normally a hazard, here exactly the semantics the
--  entropy framing wants: two dye variants of one item read as one TYPE to the
--  player's eye, and the score is about the player's eye.
--
--  MACHINES DO NOT SCORE. A machine's slots are not a shelf (see
--  depositCargoToMachine) -- emptying an upcycler's output slot eliminates "a
--  type" every single time, which would credit routine fuel hauling as
--  housekeeping. machineAt is the same test everything else uses.
--
--  Called AFTER the take, by whichever withdraw actually got something.
--  Compaction never calls this: moving a type around inside one container is
--  not removing it.
metrics.noteStorageTake = function(containerId, name)
  if containerId == nil or name == nil then return end
  if machineAt(containerId) ~= nil then return end

  local ok, left = pcall(world.containerAvailable, containerId, name)
  if not ok or type(left) ~= "number" or left > 0 then return end

  metrics.add("tidy", 1)

  --  ALWAYS LOGGED. Increments are rare -- one per type actually cleared out of
  --  a crate -- and the score is deliberately not painted anywhere yet (the
  --  rank display belongs to Maxwell, see dd.dispatch.tidyscore), so the log is
  --  the only way to verify gathering until he exists.
  sb.logInfo("PETPORT %s TIDY +1: cleared the last %s out of %s (score %s)",
    stationUniqueId(), tostring(name), sb.printJson(containerId),
    sb.printJson((self.petData and self.petData.stats and self.petData.stats.tidy) or 0))
end

local function takeFromSlot(containerId, slot, count, expected)
  if count == nil or count < 1 then return nil end

  local offset = slot + SLOT_KEY_TO_OFFSET
  local taken = world.containerTakeNumItemsAt(containerId, offset, count)

  if taken == nil or taken.name == nil or (taken.count or 0) < 1 then
    return nil
  end

  if expected ~= nil then
    local same = taken.name == expected.name
      and compare(taken.parameters, expected.parameters)

    if not same then
      --  Loud. With the offset settled, this can only mean the crate changed
      --  between the scan and the take -- or that the numbering assumption
      --  above has stopped holding, which would be worth knowing immediately.
      sb.logError("PETPORT %s slot key %s (offset %s) held %s, not the %s the "
        .. "scan found there -- returning it and refusing",
        stationUniqueId(), sb.printJson(slot), sb.printJson(offset),
        sb.printJson(taken.name), sb.printJson(expected.name))

      --  RAW, AND SAFE, unlike every other add in this file: `taken` came out
      --  of ONE slot a moment ago, so it is stack-sized by construction and
      --  cannot trip the oversized-descriptor loss placeStack exists to
      --  prevent. Left direct so the put-back is exactly the inverse of the
      --  take, with no chunking to reason about on an error path.
      world.containerAddItems(containerId, taken)
      return nil
    end
  end

  return taken
end

--  Take a named item out of a container and put it on the unit.
--
--  GLOBAL for the same reason depositCargo is: the petports_taskReport handler
--  is registered in init(), earlier in this file than the definition, so a
--  local would not be in scope at the call site.
--
--  `seedName` is a fossil of the replanting work this was written for. It has
--  been general since watering started using it for liquid, and restocking now
--  uses it for anything a player can name.
function withdrawSeed(containerId, seedName, workId, count)
  if seedName == nil then return end
  count = count or 1

  local function empty(reason)
    sb.logInfo("PETPORT %s withdraw of %s from %s took nothing: %s",
      stationUniqueId(), tostring(seedName), sb.printJson(containerId), reason)

    if workId ~= nil then noteFailure(workId, reason) end
  end

  if not world.entityExists(containerId) then
    empty("container no longer exists")
    return
  end

  local ok, items = pcall(world.containerItems, containerId)

  if not ok or type(items) ~= "table" then
    empty("container contents unreadable")
    return
  end

  --  SLOTS IN ORDER, so two runs against an unchanged crate take the same
  --  stacks. pairs, not ipairs: containerItems is keyed by slot and empty slots
  --  leave holes that ipairs stops at.
  local slots = {}
  for slot, stack in pairs(items) do
    if type(stack) == "table" and stack.name == seedName then
      table.insert(slots, slot)
    end
  end
  table.sort(slots)

  if #slots == 0 then
    empty("crate holds none of it -- emptied between dispatch and arrival?")
    return
  end

  --  ACROSS SLOTS, AND EACH ONE ARRIVES AS ITS OWN CARGO STACK.
  --
  --  A fetch that spans two dye variants is two descriptors, not one wrong one.
  --  receiveCargo merges what genuinely matches -- it compares parameters -- so
  --  identical stacks still collapse and different ones stay apart.
  local remaining = count
  local got = 0

  for _, slot in ipairs(slots) do
    if remaining < 1 then break end

    local expected = items[slot]
    local want = math.min(remaining, expected.count or 1)
    local taken = takeFromSlot(containerId, slot, want, expected)

    if taken ~= nil then
      receiveCargo(taken)
      got = got + (taken.count or 1)
      remaining = remaining - (taken.count or 1)
    end
  end

  if got < 1 then
    --  NAMES WHAT IT TRIED. "every slot refused" on its own says nothing about
    --  WHY, and the first build of this failed exactly here with no way to tell
    --  an empty crate from a wrong offset.
    local tried = {}
    for _, slot in ipairs(slots) do
      table.insert(tried, string.format("%s->%s(x%s)", tostring(slot),
        tostring(slot + SLOT_KEY_TO_OFFSET),
        tostring((items[slot] or {}).count)))
    end

    empty("every slot holding it refused: key->offset " .. table.concat(tried, " "))
    return
  end

  --  PARTIAL IS NOW POSSIBLE, where containerConsume was all-or-nothing on the
  --  full count. That is a graceful degradation rather than a regression: the
  --  unit carries what it got and the next tick asks for the rest. Callers cap
  --  their request by containerAvailable first, so a short take means the crate
  --  changed under us.
  if got < count then
    sb.logInfo("PETPORT %s withdrew %s of the %s %s asked for from %s",
      stationUniqueId(), sb.printJson(got), sb.printJson(count),
      tostring(seedName), sb.printJson(containerId))
  else
    sb.logInfo("PETPORT %s withdrew %s %s from %s",
      stationUniqueId(), sb.printJson(got), tostring(seedName),
      sb.printJson(containerId))
  end

  --  A fetch that emptied the crate of this type is a type-elimination too --
  --  the score does not care which task did the tidying. Asked after every
  --  slot is settled, so a partial take of a multi-slot type cannot score.
  metrics.noteStorageTake(containerId, seedName)
end

--  Take a misfiled stack out of a crate. The eviction half of tidying.
--
--  Global for the same reason withdrawSeed is: the petports_taskReport handler
--  is registered in init(), earlier in this file than this definition.
--
--  BY SLOT, AND THAT IS A REVERSAL.
--
--  This used to take by name and count, on the reasoning that the slot is not
--  stable -- a player rearranging the crate between dispatch and arrival moves
--  it -- and that containerConsume works on descriptors anyway. Both halves of
--  that were true and the conclusion was still wrong.
--
--  Taking by name let the engine choose which stack to take from, so evicting 2
--  hazard blocks came off the front of a thousand-stack and left 998 + 2: the
--  right total in the wrong shape, and the whole reason compaction exists.
--  Worse, a descriptor rebuilt from a name and a count carries no PARAMETERS,
--  so the same path stripped the dye off clothing and the track off a music
--  sheet. See takeFromSlot.
--
--  The instability is real and is handled rather than avoided: the slot is
--  checked against what the scan expected to find there, and a crate that moved
--  under us is refused so the next scan can look again.
--
--  Symmetric with withdrawSeed on failure: a withdraw that takes nothing must
--  be recorded, or the port re-dispatches the identical walk forever with
--  nothing in the log looking wrong.
function withdrawMisfit(containerId, name, count, workId, slot)
  if name == nil then return end
  count = count or 1

  local function empty(reason)
    sb.logInfo("PETPORT %s tidy of %s from %s took nothing: %s",
      stationUniqueId(), tostring(name), sb.printJson(containerId), reason)

    if workId ~= nil then noteFailure(workId, reason) end
  end

  if not world.entityExists(containerId) then
    empty("container no longer exists")
    return
  end

  if slot == nil then
    --  Every caller passes one -- petports_filterMisfits and
    --  petports_restockMisfits both report the slot they found it in -- so a
    --  nil here is a new caller that has not been told this is load-bearing.
    empty("no slot given; refusing to guess which stack to take")
    return
  end

  local ok, items = pcall(world.containerItems, containerId)

  if not ok or type(items) ~= "table" then
    empty("container contents unreadable")
    return
  end

  local expected = items[slot]

  --  THE CRATE MOVED UNDER US. The scan that found this misfit ran on the work
  --  tick and the unit has walked here since, so the player has had ample time
  --  to rearrange it. Refusing is right: the next scan will find whatever is
  --  actually there now.
  if type(expected) ~= "table" or expected.name ~= name then
    empty(string.format("slot %s now holds %s, not %s -- crate rearranged "
      .. "between dispatch and arrival?", tostring(slot),
      sb.printJson(expected ~= nil and expected.name or nil), tostring(name)))
    return
  end

  --  BY SLOT, NOT BY NAME, and this is what fixes the fragmentation the tidy
  --  pass used to create. Consuming "2 hazard blocks" let the engine take them
  --  off the front of a thousand-stack, leaving 998 + 2 -- the right total in
  --  the wrong shape. The scan already knew which stack it meant.
  local taken = takeFromSlot(containerId, slot, math.min(count, expected.count or 1),
    expected)

  if taken == nil then
    empty("slot " .. tostring(slot) .. " gave nothing up")
    return
  end

  sb.logInfo("PETPORT %s tidied %s %s out of %s (slot %s)",
    stationUniqueId(), sb.printJson(taken.count or 1), tostring(name),
    sb.printJson(containerId), tostring(slot))

  --  BEFORE the compaction below on purpose, though the order cannot matter:
  --  compaction only rearranges what is already present, so it can neither
  --  create nor destroy the zero this checks for.
  metrics.noteStorageTake(containerId, name)

  --  Still worth doing on a CRATE: taking from the right slot stops this pass
  --  fragmenting it, but says nothing about fragmentation that was already
  --  there.
  --
  --  NEVER ON A MACHINE. A machine's slots are MEANINGS, not shelf space --
  --  the same principle depositCargoToMachine states on the put side, now
  --  enforced on the take side, because the FUEL task routes through here
  --  with the MACHINE as the container. Observed before this guard: every
  --  treat pickup compacted the upcycler, fragmentation() read milk in the
  --  burner plus milk in the reagent slot as one item split across two slots,
  --  and containerAddItems refilled lowest-slot-first -- the whole reagent
  --  stack merged into the burner on every harvest.
  if machineAt(containerId) == nil then
    compactContainer(containerId)
  end

  receiveCargo(taken)
end

--  Remove one seed from cargo after it has gone into the ground.
--
--  Global, same reason as above.
function spendSeed(seedName)
  if self.petData == nil or self.petData.cargo == nil then return end

  for index, stack in ipairs(self.petData.cargo) do
    if stack.name == seedName then
      local count = (stack.count or 1) - 1

      if count <= 0 then
        table.remove(self.petData.cargo, index)
      else
        stack.count = count
      end

      sb.logInfo("PETPORT %s spent 1 %s planting; %s stack(s) still held",
        stationUniqueId(), tostring(seedName),
        sb.printJson(#self.petData.cargo))

      writeBackToItem()
      return
    end
  end

  --  The unit planted something it was not carrying. Worth a shout: it means
  --  cargo accounting and the world disagree.
  sb.logError("PETPORT %s planted %s but was not carrying it",
    stationUniqueId(), tostring(seedName))
end

--  Move cargo into a container. Called when the unit reports it is standing
--  there.
--
--  PARTIAL DEPOSITS ARE NOT SPECIAL-CASED. Whatever the container refuses stays
--  on the unit, the container goes into backoff, and the next dispatch picks a
--  different beacon. That is the same behaviour as a chest being full outright,
--  which means there is one path to test rather than two.
--  GLOBAL, like receiveCargo above it and for the same reason: the
--  petports_taskReport handler is registered in init(), which is earlier in the
--  file than this definition, so a local would not be in scope at the call site.
--  ADD A DESCRIPTOR TO A CONTAINER, ONE STACK AT A TIME.
--
--  THE ONLY SAFE WAY TO CALL world.containerAddItems, because that function
--  SILENTLY DESTROYS ANYTHING PAST ONE STACK. Handed
--  { dirtmaterial, count = 8497 } into a crate with ten free slots, it filled
--  ONE slot to maxStack and returned NO LEFTOVER -- 7,497 dirt ceased to exist
--  and the call looked like a complete success from Lua.
--
--  Measured, verbatim from the log:
--
--    compacted 8497 dirtmaterial in 5: 10 slot(s), predicted 9
--    dirtmaterial in 5 settled at 1 slot(s), not the 9 predicted
--
--  and then a census reporting 1000 held where 8497 belonged. Note what the
--  second line is: the prediction check, written to catch a stackSizeOf that
--  was too LOW, correctly reporting an impossible packing -- and being read as
--  a bad prediction rather than as items going missing.
--
--  TWO ROUTES REACHED IT, AND ONLY ONE INVOLVED THE UPCYCLER. Compaction hands
--  the engine a whole bucket at once. And receiveCargo merges cargo stacks with
--  no maxStack cap by design, so three 1,000-block pickups become one stack of
--  3,000 and depositCargo hands THAT over -- which is the ordinary collect-and-
--  file path, and has nothing to do with any of the machine work.
--
--  Returns the number of items that could NOT be placed, so every caller can
--  account for its own load.
local function placeStack(containerId, stack)
  if type(stack) ~= "table" or stack.name == nil then return 0 end

  local limit = stackSizeFor(stack.name, stack.parameters)
  if limit == nil or limit < 1 then limit = 1 end

  local remaining = stack.count or 1

  while remaining > 0 do
    local chunk = math.min(remaining, limit)

    local leftover = world.containerAddItems(containerId, {
      name = stack.name,
      count = chunk,
      parameters = stack.parameters
    })

    local unplaced = 0
    if type(leftover) == "table" then unplaced = leftover.count or 0 end

    local placed = chunk - unplaced
    remaining = remaining - placed

    --  A chunk that placed NOTHING means the crate is genuinely full. Stop
    --  rather than spinning: the caller keeps what is left.
    if placed < 1 then return remaining end
  end

  return 0
end

function depositCargo(containerId)
  if self.petData == nil or self.petData.cargo == nil then return end

  if not world.entityExists(containerId) then
    sb.logInfo("PETPORT %s deposit failed: container %s no longer exists",
      stationUniqueId(), sb.printJson(containerId))
    return
  end

  local before = #self.petData.cargo
  local remaining = {}

  --  ITEMS MOVED, COUNTED FROM WHAT ACTUALLY LANDED. See
  --  dd.pane.ratesnottotals -- the total is stored, the pane makes it a rate.
  --  Placed counts only: whatever the crate refused stays on the unit and is
  --  counted whenever it finally lands somewhere.
  local delivered = 0

  for _, stack in ipairs(self.petData.cargo) do
    --  THROUGH placeStack, NEVER containerAddItems DIRECTLY. Cargo stacks are
    --  merged without a maxStack cap -- see receiveCargo -- so this descriptor
    --  can be several stacks' worth, which is precisely what the raw call
    --  destroys.
    local unplaced = placeStack(containerId, stack)

    delivered = delivered + (stack.count or 1) - unplaced

    if unplaced > 0 then
      table.insert(remaining, {
        name = stack.name,
        count = unplaced,
        parameters = stack.parameters
      })

      sb.logInfo("PETPORT %s deposited %s of %s %s into %s",
        stationUniqueId(),
        sb.printJson((stack.count or 1) - unplaced),
        sb.printJson(stack.count or 1), tostring(stack.name),
        sb.printJson(containerId))
    else
      sb.logInfo("PETPORT %s deposited %s %s into %s",
        stationUniqueId(), sb.printJson(stack.count or 1), tostring(stack.name),
        sb.printJson(containerId))
    end
  end

  cargoTrace("deposit: cargo replaced", remaining)
  self.petData.cargo = remaining

  if #remaining > 0 then
    --  A LEFTOVER IS ABOUT A DESCRIPTOR, NOT ABOUT THE CRATE. The next dispatch
    --  asks containerTakesAny with whatever is still held, so a crate that can
    --  still merge part of the load stays eligible and only a crate that can
    --  take NOTHING is passed over -- no timer needed, and no waiting out 60
    --  seconds for a crate that was never actually unusable.
    --
    --  The timed backoff is kept ONLY for the case where the engine cannot be
    --  asked, so that path still makes progress instead of retrying the same
    --  full crate forever.
    if world.containerItemsCanFit == nil then
      self.fullContainers = self.fullContainers or {}
      self.fullContainers[containerId] = world.time() + CONTAINER_FULL_BACKOFF
    end

    sb.logInfo("PETPORT %s container %s could not take %s of %s stack(s) (%s)",
      stationUniqueId(), sb.printJson(containerId), sb.printJson(#remaining),
      sb.printJson(before),
      world.containerItemsCanFit == nil
        and ("backed off for " .. sb.printJson(CONTAINER_FULL_BACKOFF))
        or "will re-check per descriptor")
  end

  metrics.add("moved", delivered)

  --  A DELIVERY IS A GOOD MOMENT TO TIDY THE SHELF. The unit is standing here
  --  anyway, so this costs no trip -- and a partial stack that just merged into
  --  an existing one is exactly when a crate is most likely to be one slot
  --  away from compact.
  compactContainer(containerId)

  --  Cargo changed, and the world drop for it is long gone. Same reasoning as
  --  the pickup side: write it through now.
  flushCargo()
end

--  Hand over-threshold cargo to a machine's INPUT slot.
--
--  SEPARATE FROM depositCargo, AND NOT A VARIANT OF IT. depositCargo empties the
--  unit outright with containerAddItems, which fills ANY free slot -- into a
--  three-slot machine that means dirt landing in the output, or in the reagent
--  slot, and a machine whose output the units then haul away as if it were
--  fuel. containerPutItemsAt names slot 0 and makes the whole class unreachable
--  rather than policed.
--
--  RE-TESTED AT THE MOMENT OF TRANSFER, not trusted from dispatch. A census is
--  a snapshot taken up to five seconds ago and the walk takes longer than that;
--  another unit may have delivered in the meantime, or the player may have
--  emptied a crate. The dispatch decides where to walk. This decides what
--  actually goes in, and it is the only check that matters.
--
--  NO COMPACTION AFTERWARDS, unlike depositCargo. A machine's slots are not a
--  shelf, and there is nothing to tidy in a slot that holds one stack.
function depositCargoToMachine(machineId, workId)
  if self.petData == nil or self.petData.cargo == nil then return end

  if not world.entityExists(machineId) then
    sb.logInfo("PETPORT %s upcycle failed: machine %s no longer exists",
      stationUniqueId(), sb.printJson(machineId))
    return
  end

  --  READ FRESH. The machine's own pane writes rules straight to its
  --  parameters, so the player may have changed or removed the rule while the
  --  unit was walking. Nothing about a machine that destroys items should run
  --  off a cached copy.
  local machine = machineAt(machineId)

  if machine == nil or not machine.enabled then
    sb.logInfo("PETPORT %s upcycle ABORTED: machine %s is %s",
      stationUniqueId(), sb.printJson(machineId),
      machine == nil and "no longer a machine" or "switched off")
    return
  end

  local remaining = {}
  local moved = 0

  for _, stack in ipairs(self.petData.cargo) do
    local rule = nil

    for _, candidate in ipairs(machine.rules) do
      if candidate.item == stack.name then rule = candidate break end
    end

    --  THE CARRIED STACK COUNTS. See machineWantsAny: the census counts crates,
    --  so a unit holding 1000 of something has already removed it from the
    --  count. Asking "is the network over threshold" without adding it back
    --  answers about a network with a hole in it exactly the size of the
    --  delivery.
    local stored = (self.census or {})[stack.name] or 0
    local held = stored + (stack.count or 0)

    --  How much of this stack is genuinely surplus, rather than all-or-nothing.
    --
    --  A unit carrying 1000 into a network 400 over its threshold should
    --  deliver 400 and keep 600, not deliver everything and take the network
    --  under, and not refuse the trip because the whole stack does not fit
    --  above the line. This is what makes "keep at most N" mean N.
    local surplus = rule ~= nil and (held - rule.max) or 0
    if surplus > (stack.count or 0) then surplus = stack.count or 0 end

    if rule == nil then
      --  Not an error and not worth a line every trip: the unit is allowed to
      --  be carrying other things, and they simply stay aboard for the crates.
      table.insert(remaining, stack)
    elseif surplus < 1 then
      --  THE THRESHOLD WAS MET WHILE THE UNIT WALKED -- genuinely, now that the
      --  carried stack is counted. Keep it; the next dispatch files it in
      --  ordinary storage. This is the check that makes a stale census harmless
      --  rather than destructive.
      sb.logInfo("PETPORT %s upcycle SKIPPED %s: network holds %s (%s stored + %s carried), threshold %s -- no longer surplus",
        stationUniqueId(), tostring(stack.name), sb.printJson(held),
        sb.printJson(stored), sb.printJson(stack.count or 0),
        sb.printJson(rule.max))
      table.insert(remaining, stack)
    else
      --  SLOT-PRECISE, ONLY THE SURPLUS PORTION, parameters carried on every
      --  put so the kept remainder is the same item the unit picked up.
      --
      --  A REAGENT GOES TO THE REAGENT SLOT, AND FALLS BACK TO THE BURNER --
      --  IF THE RULE'S BURN BOX ALLOWS IT.
      --
      --  EVERY OFFER IS CAPPED TO MEASURED, DESCRIPTOR-TRUE ROOM FIRST.
      --  machineSlotRoom is asked with the REAL stack, parameters and all, and
      --  only what fits is ever handed to the engine. Measured 2026-08-29:
      --  uncapped offers of 1000 milk were refused WHOLE by slots with
      --  name-level headroom -- rot parameters block the merge -- and whether
      --  containerPutItemsAt would even split an oversized offer stops
      --  mattering once no offer can be oversized.
      --
      --  THE FALLBACK IS THE SAFETY STORY, AND THE BURN BOX IS ITS GATE.
      --  Whatever the reagent slot cannot take goes to the burner in the same
      --  trip -- UNLESS the rule denies the burner, in which case it stays
      --  aboard and files to ordinary storage. Denying the burner is the
      --  player saying "never destroy this", and a fallback that destroys it
      --  anyway would make the checkbox a lie.
      local allowBurn = rule.burn ~= false
      local routeToReagent = rule.reagent ~= false
        and petports_reagentFor(stack.name) ~= nil

      local remainingCount = surplus

      if routeToReagent and remainingCount > 0 then
        local slotRoom = machineSlotRoom(machineId, MACHINE_SLOT_REAGENT, stack)
        local offerCount = math.min(remainingCount, slotRoom)
        local landed = 0

        if offerCount > 0 then
          local leftover = world.containerPutItemsAt(machineId, {
            name = stack.name,
            count = offerCount,
            parameters = stack.parameters
          }, MACHINE_SLOT_REAGENT)

          local refused = (type(leftover) == "table" and leftover.count or 0)
          landed = offerCount - refused
          remainingCount = remainingCount - landed
        end

        sb.logInfo("PETPORT %s reagent route: %s of %s %s into the reagent slot (slot room %s)%s",
          stationUniqueId(), sb.printJson(landed), sb.printJson(surplus),
          tostring(stack.name), sb.printJson(slotRoom),
          (remainingCount > 0 and not allowBurn)
            and " -- burner denied by rule, remainder stays aboard" or "")
      end

      if allowBurn and remainingCount > 0 then
        local slotRoom = machineSlotRoom(machineId, MACHINE_SLOT_INPUT, stack)
        local offerCount = math.min(remainingCount, slotRoom)

        if offerCount > 0 then
          local leftover = world.containerPutItemsAt(machineId, {
            name = stack.name,
            count = offerCount,
            parameters = stack.parameters
          }, MACHINE_SLOT_INPUT)

          local refused = (type(leftover) == "table" and leftover.count or 0)
          remainingCount = remainingCount - (offerCount - refused)
        end
      end

      local placed = surplus - remainingCount

      if placed > 0 then moved = moved + placed end

      sb.logInfo("PETPORT %s upcycled %s of %s %s into machine %s (network held %s = %s stored + %s carried, threshold %s)",
        stationUniqueId(), sb.printJson(placed), sb.printJson(stack.count or 1),
        tostring(stack.name), sb.printJson(machineId), sb.printJson(held),
        sb.printJson(stored), sb.printJson(stack.count or 0),
        sb.printJson(rule.max))

      --  Whatever was not surplus, plus whatever the machine could not take.
      local keep = (stack.count or 0) - placed

      if keep > 0 then
        table.insert(remaining, {
          name = stack.name,
          count = keep,
          parameters = stack.parameters
        })
      end
    end
  end

  cargoTrace("deposit: cargo replaced", remaining)
  self.petData.cargo = remaining

  --  `moved` is already the placed sum here -- this function was doing the
  --  accounting before the stat existed. A machine feed is a delivery like any
  --  other; the machine only stops SCORING (see noteStorageTake), not counting.
  metrics.add("moved", moved)

  if moved == 0 then
    --  RECORDED, NOT JUST LOGGED.
    --
    --  Without this the unit re-targets the next machine on the very next tick
    --  and orbits the whole set, because nothing remembers that this one had no
    --  room when it actually arrived. The backoff is what lets the load fall
    --  through to ordinary storage instead.
    --
    --  Room at dispatch is a prediction; another unit can fill the slot during
    --  the walk. This is the arrival telling the truth about it.
    local reason = "machine input was full on arrival"

    sb.logInfo("PETPORT %s upcycle delivered NOTHING to machine %s -- input full, "
      .. "rule gone, or no longer over threshold", stationUniqueId(),
      sb.printJson(machineId))

    noteFailure(workId, reason)
  end

  --  Cargo changed and the world drop for it is long gone. Same reasoning as
  --  the pickup side: write it through now.
  flushCargo()
end

--  Move ONE named item out of cargo into a container.
--
--  The restock delivery half. depositCargo above empties the unit outright,
--  which is right for ordinary storage and wrong for a request crate: a unit
--  carrying hazard blocks for a restock beacon and anything else at all would
--  post the anything-else through the same slot.
--
--  Cargo is normally one stack, because the guard in findWork stops a loaded
--  unit picking anything else up -- so this is belt to that braces rather than
--  a case anyone has seen. It costs one comparison and removes a whole class of
--  "why is there a sword in my rail crate".
--
--  NOT CAPPED AT THE QUOTA. Overshoot is possible only when two ports fetch for
--  the same crate at once, and the excess is a misfit the moment it lands --
--  petports_restockMisfits reports it, tidyWork hauls it back to storage, and
--  the crate settles at max. Capping here would leave a remainder on the unit
--  instead, which is the state the cargo guard exists to avoid.
--
--  GLOBAL, like depositCargo beside it and for the same reason: the
--  petports_taskReport handler is registered in init(), earlier in this file
--  than this definition, so a local would not be in scope at the call site.
function depositCargoOnly(containerId, name)
  if self.petData == nil or self.petData.cargo == nil then return end
  if name == nil then return end

  if not world.entityExists(containerId) then
    sb.logInfo("PETPORT %s restock delivery failed: container %s no longer exists",
      stationUniqueId(), sb.printJson(containerId))
    return
  end

  local remaining = {}
  local moved = false

  --  Same accounting as depositCargo: placed counts only, refused stays on the
  --  unit and is counted when it lands.
  local delivered = 0

  for _, stack in ipairs(self.petData.cargo) do
    if stack.name ~= name then
      table.insert(remaining, stack)
    else
      moved = true

      --  THROUGH placeStack. Same reason as depositCargo: a cargo stack has no
      --  maxStack cap and the raw call silently discards the overflow.
      local unplaced = placeStack(containerId, stack)

      delivered = delivered + (stack.count or 1) - unplaced

      if unplaced > 0 then
        table.insert(remaining, {
          name = stack.name,
          count = unplaced,
          parameters = stack.parameters
        })

        sb.logInfo("PETPORT %s restocked %s of %s %s into %s",
          stationUniqueId(),
          sb.printJson((stack.count or 1) - unplaced),
          sb.printJson(stack.count or 1), tostring(stack.name),
          sb.printJson(containerId))
      else
        sb.logInfo("PETPORT %s restocked %s %s into %s",
          stationUniqueId(), sb.printJson(stack.count or 1), tostring(stack.name),
          sb.printJson(containerId))
      end
    end
  end

  --  A DELIVERY THAT MOVED NOTHING IS WORTH SAYING OUT LOUD. The unit walked
  --  there holding something else entirely, which means the match that
  --  dispatched it and the cargo it arrived with disagree.
  if not moved then
    sb.logInfo("PETPORT %s restock delivery to %s moved nothing: not carrying %s",
      stationUniqueId(), sb.printJson(containerId), tostring(name))
  end

  cargoTrace("deposit: cargo replaced", remaining)
  self.petData.cargo = remaining

  metrics.add("moved", delivered)

  --  Same as an ordinary deposit: the unit is already here, and a delivery
  --  landing beside an existing partial stack is the common way a request
  --  crate ends up holding one item across two slots.
  compactContainer(containerId)

  --  Cargo changed and the world drop for it is long gone. Same reasoning as
  --  every other cargo mutation: write it through now.
  flushCargo()
end

--------------------------------------------------------------------------------
--  STACK COMPACTION
--------------------------------------------------------------------------------
--
--  ONE STACK'S WORTH OF AN ITEM ACROSS TWO SLOTS IS AN ARTIFACT, and it is the
--  kind of artifact a bot can fix.
--
--  Observed: a crate holding 2 hazard blocks received a delivery of 1000. The
--  quota was 1000, so the 2 became overstock and eviction correctly identified
--  them -- but withdrawMisfit consumes BY NAME AND COUNT, and the engine took
--  its 2 off the front of the thousand-stack. The arithmetic was right and the
--  crate ended 998 + 2, which is the right total in the wrong shape.
--
--  Fixing the slot selection would stop this ONE source of fragmentation.
--  Compaction fixes all of them, including the player putting two half stacks
--  in a chest by hand, so that is what this does.

--  The engine's default for an item that declares no maxStack of its own.
--
--  MEASURED: /items/defaultParameters.config carries defaultMaxStack, and it is
--  1000. Not 1 -- that was believed here for one build and is what switched
--  compaction off entirely, since a stack size of 1 makes `needed` equal the
--  item count and no crate can ever read as fragmented.
--
--  Read from the asset rather than hardcoded, so a mod that changes the default
--  changes this too.
local function defaultMaxStack()
  if self.defaultStack == nil then
    local ok, config = pcall(root.assetJson, "/items/defaultParameters.config")

    self.defaultStack = (ok and type(config) == "table"
      and tonumber(config.defaultMaxStack)) or false
  end

  return self.defaultStack or nil
end

--  One full stack of an item, memoised. A static config read, on a path that
--  runs on the work tick.
--
--  BOTH REAL SOURCES ARE AUTHORITATIVE, WHICH IS WHY THE WALK-BACK LOOP CANNOT
--  ARISE HERE ANY MORE.
--
--  compactWork dispatches on `slots > needed`, and `needed` divides by this
--  number. A value that is too HIGH makes needed too low, the crate still reads
--  as fragmented after a merge that could not have fixed it, and a unit walks
--  back on every idle tick -- with each pass logging a success, because the
--  task did succeed. compactWork has no workFailures backoff to stop that.
--
--  Two earlier versions got here by different wrong routes:
--
--    `or 1000` was accidentally correct -- it happened to match the engine's
--    real default -- but it was a guess standing in for a number nobody had
--    read, and it would have been silently wrong for any other default.
--
--    `or 1` was safe in the loop direction and switched the feature off. It
--    reads as "no crate has stacks worth merging" on every tick, which looks
--    exactly like a tidy network.
--
--  Neither of those is what makes this correct now. Both live paths return the
--  authoritative value -- the item's own declared maxStack, or the engine's
--  default read from the asset that defines it -- so neither can come back too
--  high. Measured across seven items: gentlereminder answered 1 from config,
--  oculemon 1000 from config, and everything undeclared answered 1000 from
--  defaultParameters. The trailing 1000 is reachable only if the asset read
--  itself fails, and it is the right answer even then.
--
--  PARAMETERS ARE NOT CONSULTED HERE, and that is a real limitation rather than
--  an oversight. This is a base lookup -- the descriptor passed in carries no
--  parameters -- so an item instance that overrides its OWN maxStack downward
--  would pack into more slots than predicted, which is the loop again. See
--  fragmentation: it has each bucket's real parameters in hand and asks them
--  first, which is the only place that question can honestly be answered.
--
--  LOGGED ONCE PER ITEM NAME, unconditionally. Cheap -- once per name per
--  session, not per tick -- and it is what turned "compaction stopped working"
--  into a one-line diagnosis.
--  Assigned, not declared -- the name is forward-declared far above so the
--  upcycler routing can reach it. Changing this back to `local function` would
--  silently break machineInputRoom.
stackSizeOf = function(name)
  self.stackSizes = self.stackSizes or {}

  if self.stackSizes[name] == nil then
    local size, source = nil, "guessed"

    local ok, resolved = pcall(root.itemConfig, { name = name, count = 1 })

    if ok and type(resolved) == "table" and type(resolved.config) == "table" then
      size = tonumber(resolved.config.maxStack)
      if size ~= nil then source = "config" end
    end

    if size == nil then
      size = defaultMaxStack()
      if size ~= nil then source = "defaultParameters" end
    end

    if size == nil then size = 1000 end

    self.stackSizes[name] = size

    sb.logInfo("PETPORT %s maxStack for %s: %s (from %s)",
      stationUniqueId(), tostring(name), sb.printJson(size), source)
  end

  return self.stackSizes[name]
end

--  One full stack of a SPECIFIC descriptor.
--
--  An instance parameter may override the item's own maxStack, and when it does
--  it is the number the engine will actually pack by. stackSizeOf cannot see it
--  -- it asks with a bare descriptor -- so the bucket asks its own parameters
--  first and falls back to the item's base value.
--
--  This is the last path by which `needed` could come out too low, and it is
--  closed by reading the right number rather than by guarding against a wrong
--  one.
--  Assigned, not declared: the name is forward-declared far above so placeStack
--  can reach it. Changing this back to `local function` would silently break
--  every deposit in the mod.
stackSizeFor = function(name, parameters)
  if type(parameters) == "table" then
    local override = tonumber(parameters.maxStack)
    if override ~= nil and override >= 1 then return override end
  end

  return stackSizeOf(name)
end

--  Are two parameter blocks the same?
--
--  DEEP, RECURSIVE, AND NOT A printJson COMPARISON. Serialising two tables and
--  comparing the strings assumes a stable key order, which is a promise about
--  the engine's Json implementation that nothing here can check. Walking them
--  cannot be wrong about it. Parameter blocks are small and this only runs on
--  the tidying tick.
--
--  A KEY PRESENT WITH A NULL IS NOT THE SAME AS A KEY ABSENT, and that
--  distinction is correct rather than pedantic.
--
--  MEASURED, TWICE. Assigning nil into an engine-backed table writes an
--  explicit JSON null rather than removing the key -- the same behaviour
--  setInstanceValue has. The restock pane's own log shows it: a read returned
--  no filter at all, the pane did `state.filter = nil`, and the payload went
--  out carrying `"filter":null`. The beacon stacking work found the other half
--  of it first, where a beacon whose parameters had been cleared would no
--  longer stack with a pristine one, and the decision there was to stop trying
--  to make them stack.
--
--  The consequence here is the same and equally deliberate. An item carrying a
--  stamped null genuinely will not merge with one that does not, so reporting
--  them as different descriptors is the truth. Calling them equal would produce
--  a merge the engine then refuses -- and that path is survivable
--  (compactContainer routes the remainder to cargo) but it would be a move
--  nobody needed to make.
local function sameValue(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end

  for key, value in pairs(a) do
    if not sameValue(value, b[key]) then return false end
  end

  --  Both directions. The loop above passes a table that is a strict subset of
  --  the other, so the reverse check is what makes this equality.
  for key in pairs(b) do
    if a[key] == nil then return false end
  end

  return true
end

--  A cheap first-pass key for a parameter block.
--
--  WHY THIS EXISTS: A CRATE OF MUSIC SHEETS IS THE WORST CASE FOR A LINEAR
--  BUCKET SEARCH.
--
--  Betabound's sb_musicsheet is one item name carrying one distinct parameter
--  block per song, and a player who has been collecting them fills a crate with
--  sixty of the things. Matching each slot against every bucket found so far is
--  quadratic in exactly that situation -- and this runs per container, on the
--  work tick, from both compactContainer and compactWork.
--
--  So the parameter block is serialised once and used as a table key, and
--  sameValue is consulted only to CONFIRM a hit. Correctness never rests on the
--  hash:
--
--    Two blocks that serialise the same are deep-compared before merging, so a
--    collision cannot merge unlike items.
--
--    Two equal blocks that serialise DIFFERENTLY -- which would need the
--    engine's key order to be unstable -- fall into separate buckets, `needed`
--    comes out higher, and the crate is simply reported as already compact.
--    A missed merge, never a wrong one.
--
--  An unprintable block gets a key derived from its identity, so it buckets
--  alone and is left untouched.
local function parameterKey(parameters)
  if parameters == nil then return "" end

  local ok, text = pcall(sb.printJson, parameters)
  if ok then return text end

  return "?" .. tostring(parameters)
end

--  Which items in this container occupy more slots than they need to?
--
--  Returns an array of { name, total, slots, needed, buckets }, ordered by name
--  so two scans of an unchanged crate agree. Each bucket is
--  { parameters, count } -- one distinct descriptor and how many of it there
--  are across every slot.
--
--  BUCKETED BY PARAMETERS, WHICH IS WHAT MAKES MUSIC SHEETS WORK.
--
--  An earlier version refused to touch any name whose stacks were not all bare,
--  because merging two sheets with different songs by name would have produced
--  two IDENTICAL sheets -- corruption, not untidiness. Bucketing keeps them
--  apart properly: two stacks of the SAME song merge, two different songs do
--  not, and `needed` counts each bucket's own stacks.
--
--  So a crate holding 3 of song A in two slots and 2 of song B in two slots
--  needs two slots and has four, and compacting it produces exactly one stack
--  of each.
local function fragmentation(items)
  if type(items) ~= "table" then return {} end

  local groups = {}

  for _, stack in pairs(items) do
    if type(stack) == "table" and type(stack.name) == "string" then
      local group = groups[stack.name]

      if group == nil then
        group = { total = 0, slots = 0, buckets = {}, byKey = {} }
        groups[stack.name] = group
      end

      local count = stack.count or 1
      group.total = group.total + count
      group.slots = group.slots + 1

      local parameters = stack.parameters
      local key = parameterKey(parameters)
      local bucket = group.byKey[key]

      --  CONFIRMED, NOT TRUSTED. A hit on the key is a candidate; sameValue
      --  decides. JSON should not collide, so this is belt to the braces --
      --  but the cost of being wrong is merging two different songs into one.
      if bucket ~= nil and not sameValue(bucket.parameters, parameters) then
        bucket = nil

        for _, candidate in ipairs(group.buckets) do
          if sameValue(candidate.parameters, parameters) then
            bucket = candidate
            break
          end
        end
      end

      if bucket == nil then
        bucket = { parameters = parameters, count = 0 }
        table.insert(group.buckets, bucket)
        group.byKey[key] = bucket
      end

      bucket.count = bucket.count + count
    end
  end

  local names = {}
  for name in pairs(groups) do table.insert(names, name) end
  table.sort(names)

  local out = {}

  for _, name in ipairs(names) do
    local group = groups[name]

    if group.slots > 1 then
      local needed = 0

      --  PER BUCKET, NOT ON THE GRAND TOTAL. Two half stacks of different
      --  songs need two slots however few sheets they hold, and dividing the
      --  combined count would claim they need one.
      --
      --  AND SIZED PER BUCKET TOO. stackSizeFor asks the bucket's own
      --  parameters before the item's base config, because an instance that
      --  overrides its maxStack packs by that number and predicting with the
      --  base value would put `needed` below what the engine can deliver -- the
      --  one remaining way this could ask for a merge that cannot happen.
      for _, bucket in ipairs(group.buckets) do
        needed = needed
          + math.ceil(bucket.count / stackSizeFor(name, bucket.parameters))
      end

      --  The precise test for "this can be compressed". Two FULL stacks need
      --  two slots and are already as compact as they can be; rewriting them
      --  would be work that changes nothing.
      if group.slots > needed then
        group.name = name
        group.needed = needed
        table.insert(out, group)
      end
    end
  end

  return out
end

--  Merge split stacks in one container.
--
--  TAKE THE WHOLE NAME OUT, PUT EACH DESCRIPTOR BACK. That order is what makes
--  this safe without knowing how containerConsume matches.
--
--  Starbound's Item::matches takes an exactMatch flag, and which way
--  containerConsume passes it is not something this mod has verified. Both
--  answers are survivable here:
--
--    If it matches BY NAME, the single consume below takes every stack of that
--    name -- which is exactly what was intended, since every one of them is
--    about to be put back bucket by bucket with its own parameters.
--
--    If it matches EXACTLY, a bare descriptor cannot account for parameterised
--    stacks, the consume fails outright -- it is all-or-nothing -- and nothing
--    has moved. A no-op with a log line.
--
--  What is NOT possible either way is taking a parameterised stack and handing
--  back a bare one, which is the corruption this shape exists to rule out.
--
--  containerAddItems then runs the engine's own merge rules per descriptor, so
--  the resulting slot count is minimal by construction -- no slot arithmetic
--  here, and nothing to get wrong when a mod changes a maxStack.
--
--  GLOBAL, like depositCargo and receiveCargo, and for the same reason: the
--  petports_taskReport handler is registered in init(), earlier in this file
--  than this definition.
function compactContainer(containerId)
  if not world.entityExists(containerId) then return false end

  local ok, items = pcall(world.containerItems, containerId)
  if not ok or type(items) ~= "table" then return false end

  local work = fragmentation(items)
  if #work == 0 then return false end

  --  Names this pass actually put back, so the check at the bottom only asks
  --  about crates it touched.
  local settled = {}
  local did = false

  for _, group in ipairs(work) do
    local took = world.containerConsume(containerId,
      { name = group.name, count = group.total })

    if took ~= true then
      --  Nothing has moved -- containerConsume is all-or-nothing -- so this is
      --  a no-op rather than a half-finished merge. Worth a line: it is either
      --  the exact-match case above, or the crate changed between the read and
      --  this call.
      sb.logInfo("PETPORT %s compaction of %s in %s skipped: consume returned %s",
        stationUniqueId(), tostring(group.name), sb.printJson(containerId),
        tostring(took))
    else
      local returned = 0
      local rescued = 0

      for _, bucket in ipairs(group.buckets) do
        --  THROUGH placeStack, like every other add in this file. A bucket is
        --  the whole of one descriptor in the crate -- routinely several stacks
        --  worth -- and handing that to containerAddItems directly is exactly
        --  what destroyed 7,497 dirt. See placeStack's header for the measured
        --  numbers.
        local unplaced = placeStack(containerId, {
          name = group.name,
          count = bucket.count,
          parameters = bucket.parameters
        })

        returned = returned + (bucket.count - unplaced)

        if unplaced > 0 then
          --  SHOULD BE UNREACHABLE: the slots were freed a moment ago, so what
          --  came out must fit back in. Loud, and the remainder goes onto the
          --  unit rather than being destroyed -- losing a player's items to a
          --  tidying pass is the worst outcome available here.
          sb.logError("PETPORT %s compaction of %s in %s could not return %s -- "
            .. "moved to cargo",
            stationUniqueId(), tostring(group.name), sb.printJson(containerId),
            sb.printJson(unplaced))

          receiveCargo({
            name = group.name,
            count = unplaced,
            parameters = bucket.parameters
          })

          rescued = rescued + unplaced
        end
      end

      --  HARD ACCOUNTING, EVERY PASS.
      --
      --  The whole class of failure above was silent: a consume that succeeded,
      --  an add that reported success, and a smaller number of items in the
      --  world afterwards. Counting what went in against what came out is the
      --  only check that catches that, and it costs one comparison.
      if returned + rescued ~= group.total then
        sb.logError("PETPORT %s COMPACTION LOST ITEMS in %s: took %s %s, "
          .. "returned %s, moved %s to cargo -- %s UNACCOUNTED FOR",
          stationUniqueId(), sb.printJson(containerId),
          sb.printJson(group.total), tostring(group.name),
          sb.printJson(returned), sb.printJson(rescued),
          sb.printJson(group.total - returned - rescued))
      end

      if returned > 0 then
        did = true
        table.insert(settled, group)

        --  "PREDICTED", NOT "->". This line used to read `6 slot(s) -> 4`,
        --  which states an OUTCOME -- and it is not one. It is what
        --  stackSizeOf's arithmetic expects the engine to do, and that rests on
        --  a maxStack the item may not declare. Reading a prediction as a
        --  result cost a full diagnosis of a bug that turned out to be someone
        --  rearranging the crate by hand between two passes. The check below
        --  asks the container instead.
        sb.logInfo("PETPORT %s compacted %s %s in %s: %s slot(s), predicted %s (%s descriptor(s))",
          stationUniqueId(), sb.printJson(group.total), tostring(group.name),
          sb.printJson(containerId), sb.printJson(group.slots),
          sb.printJson(group.needed), sb.printJson(#group.buckets))
      end
    end
  end

  --  DID THE ENGINE DO WHAT WAS PREDICTED? ASK THE CRATE.
  --
  --  compactWork dispatches on `slots > needed`, so if `needed` is ever too LOW
  --  the crate stays fragmented by this file's own definition and a unit walks
  --  back to it on every idle tick, forever, with each pass logging a success.
  --  Every other work generator here is protected from that shape by a
  --  workFailures backoff; this one has none.
  --
  --  INSTRUMENTED RATHER THAN DEFENDED, deliberately. A backoff would hide the
  --  loop; this names it the first time it happens, with both numbers, and the
  --  fix then goes in stackSizeOf where the wrong answer came from.
  --
  --  SILENT WHEN THE PREDICTION HOLDS, which is the normal case -- and the read
  --  only happens at all when something was actually merged, since the function
  --  returns early otherwise.
  --
  --  WHAT THIS DELIBERATELY DOES NOT DO is learn a maxStack from the packing it
  --  finds here. That was written and backed out: this read can catch a crate
  --  the PLAYER has just edited, and caching a wrong stack size would silently
  --  stop the network ever compacting that item again.
  if #settled > 0 then
    local okAfter, after = pcall(world.containerItems, containerId)

    if okAfter and type(after) == "table" then
      for _, group in ipairs(settled) do
        local slots = 0

        for _, stack in pairs(after) do
          if type(stack) == "table" and stack.name == group.name then
            slots = slots + 1
          end
        end

        if slots ~= group.needed then
          sb.logInfo("PETPORT %s %s in %s settled at %s slot(s), not the %s predicted "
            .. "-- stackSizeOf says %s",
            stationUniqueId(), tostring(group.name), sb.printJson(containerId),
            sb.printJson(slots), sb.printJson(group.needed),
            sb.printJson(stackSizeOf(group.name)))
        end
      end
    end
  end

  return did
end

--------------------------------------------------------------------------------
--  FARMABLES
--------------------------------------------------------------------------------

--  Is this work item free for this port to take?
--
--  MOVED ABOVE ITS FIRST CALLER. It is used by waterWork, replantWork and
--  withdrawWork, and it originally sat below the first of those -- which is the
--  nil-global trap this file has already been bricked by once: a local called
--  from a line above its definition compiles as a lookup of a global nobody
--  assigns, with no syntax error and no warning until it runs.
--
--  It matters twice over in withdrawWork, which needs it for its own leg AND
--  for the replant that follows; getting that wrong livelocks the queue.
--  Assigned, not declared -- the name is forward-declared far above so
--  upcyclerWork can screen candidates with it.
claimFree = function(workId)
	local claim = petports_claimGet(workId)

	return (claim == nil)
		or claim.owner == stationUniqueId()
		or (claim.expires or 0) <= world.time()
end

--------------------------------------------------------------------------------
--  SOIL
--------------------------------------------------------------------------------

--  What a surface mod is and what it wants, cached by name.
--
--  THE MATMOD IS SELF-DESCRIBING, which removes a whole layer that was planned
--  and is not needed. farming.config's wetToDryMods describes the DRYING
--  direction and never has to be read: a mod that carries "tilled" : true is
--  farmland, and one that also carries a liquidInteraction with a
--  transformModId is farmland that is currently DRY and says what would fix it.
--
--    tilleddry   "tilled" : true
--                liquidInteractions -> liquidId 1 or 6, transformModId 31
--    tilled      "tilled" : true, no liquidInteractions
--
--  So no name comparisons and no hardcoded pairs -- this is true for modded
--  soils for free, which is most of what Alta/Enternia compatibility would
--  otherwise have cost.
local soilCache = {}

--  transformModId is a NUMBER; applySurfaceMod wants a NAME.
--
--  The matmod says "liquid 1 turns me into mod 31" and vanilla's droplet says
--  "previousMod tilleddry, newMod tilled". Passing 31 where a name is expected
--  would spawn a droplet that falls and does nothing -- the same silent failure
--  as the parameter override not landing, and indistinguishable from it in a
--  log, so it is worth closing rather than discovering.
--
--  farming.config's wetToDryMods is the wet -> dry pairing, so INVERTED it maps
--  a dry mod name to its wet one, which is exactly the name needed. That is the
--  one thing that file is good for; everything else about dryness comes off the
--  matmod itself.
--
--  THERE IS NO root.modName. The mod API goes one way only -- root.modConfig
--  takes a NAME and yields a config -- so a numeric id cannot be turned into a
--  name directly, and the inverse map is the only route.
--
--  It can be CHECKED, though, and cheaply: the resolved config carries modId,
--  so confirming it equals the transformModId we were aiming at turns a guess
--  into a verified lookup. A modded soil whose author patched wetToDryMods
--  correctly passes; one that did not is refused rather than watered with a
--  droplet naming a mod that does not exist.
local wetNameCache = nil

local function wetModName(dryName, transformModId)
	if wetNameCache == nil then
		wetNameCache = {}

		for _, path in ipairs({ "/farming.config", "/assets/farming.config" }) do
			local ok, config = pcall(root.assetJson, path)

			if ok and type(config) == "table" and type(config.wetToDryMods) == "table" then
				for wet, dry in pairs(config.wetToDryMods) do
					wetNameCache[tostring(dry)] = tostring(wet)
				end

				sb.logInfo("PETPORT %s read wetToDryMods from %s: %s",
					stationUniqueId(), path, sb.printJson(config.wetToDryMods))
				break
			end
		end
	end

	local inverted = wetNameCache[tostring(dryName)]
	if inverted == nil then
		return nil, "no wetToDryMods entry for " .. tostring(dryName)
	end

	--  Confirm the name actually names the mod the soil asked for.
	local ok, mod = pcall(root.modConfig, inverted)

	if not ok or type(mod) ~= "table" or type(mod.config) ~= "table" then
		return nil, "wetToDryMods names " .. tostring(inverted)
			.. " but root.modConfig does not know it"
	end

	if mod.config.modId ~= transformModId then
		return nil, string.format(
			"wetToDryMods names %s (modId %s) but the soil transforms to %s",
			tostring(inverted), tostring(mod.config.modId),
			tostring(transformModId))
	end

	return inverted, "farming.config inverse, modId confirmed"
end

local function soilInfo(modName)
	if modName == nil then return nil end

	local key = tostring(modName)
	if soilCache[key] ~= nil then return soilCache[key] end

	local info = { tilled = false, dry = false, wants = {} }
	local ok, mod = pcall(root.modConfig, key)

	if ok and type(mod) == "table" and type(mod.config) == "table" then
		info.tilled = mod.config.tilled == true

		for _, interaction in ipairs(mod.config.liquidInteractions or {}) do
			if interaction.transformModId ~= nil and interaction.liquidId ~= nil then
				--  itemDrop CLOSES THE LOOP FROM THE OTHER END. The matmod names
				--  liquids by numeric id and a liquid item names its liquid by
				--  string, so matching items against the mod directly would need
				--  a bridge. The liquid's own config carries the item that
				--  yields it, so we go mod -> liquid -> item and never match
				--  anything.
				local okLiquid, liquid = pcall(root.liquidConfig, interaction.liquidId)
				local item = nil
				local tint = nil

				if okLiquid and type(liquid) == "table" and type(liquid.config) == "table" then
					item = liquid.config.itemDrop

					--  THE DROPLET WEARS THE LIQUID'S OWN COLOUR. The sprite is
					--  transparent white, so a multiply directive paints it --
					--  and every liquid config already carries the colour the
					--  engine renders it with, so nothing has to be authored per
					--  liquid. Water is blue, lava is not, and swamp water looks
					--  like swamp water without a table anywhere in this mod.
					--
					--  ALPHA IS FORCED OPAQUE. A liquid's alpha describes how a
					--  BODY of it renders -- water is 128, half transparent,
					--  which is right for a lake and nearly invisible on a
					--  three-pixel droplet.
					local colour = liquid.config.color

					if type(colour) == "table" and #colour >= 3 then
						local function channel(value)
							return math.max(0, math.min(255, math.floor(tonumber(value) or 0)))
						end

						tint = string.format("%02X%02X%02XFF",
							channel(colour[1]), channel(colour[2]), channel(colour[3]))
					end
				end

				local wetName, via = wetModName(key, interaction.transformModId)

				if item ~= nil and wetName ~= nil then
					info.dry = true
					table.insert(info.wants, {
						liquidId = interaction.liquidId,
						item = item,
						transformModId = interaction.transformModId,
						newMod = wetName,
						tint = tint
					})
				elseif item ~= nil then
					sb.logInfo("PETPORT %s soil %s: liquid %s yields %s but mod %s "
						.. "has no resolvable name (%s) -- cannot water this soil",
						stationUniqueId(), key, sb.printJson(interaction.liquidId),
						tostring(item), sb.printJson(interaction.transformModId),
						tostring(via))
				end
			end
		end
	end

	sb.logInfo("PETPORT %s soil %s: tilled %s dry %s wants %s",
		stationUniqueId(), key, tostring(info.tilled), tostring(info.dry),
		sb.printJson(info.wants))

	soilCache[key] = info
	return info
end

--  Is this tile dry farmland, and what would fix it?
local function drySoilAt(tile)
	local modName = world.mod({ tile[1], tile[2] }, "foreground")
	if modName == nil then return nil end

	local info = soilInfo(modName)
	if info == nil or not info.tilled or not info.dry then return nil end

	return { mod = tostring(modName), wants = info.wants }
end

--  A farmable's stages array.
--
--  world.getObjectParameter reads the object's own config, which is where
--  "stages" lives, and works whether or not the object has an item form.
--  root.itemConfig is kept as a fallback because HarvesterBeam reaches
--  farmables that way and it is the better-travelled path -- but it is gated on
--  hasObjectItem there for a reason, so it cannot be the primary.
local function farmableStages(id)
	local ok, stages = pcall(world.getObjectParameter, id, "stages")
	if ok and type(stages) == "table" and #stages > 0 then
		return stages
	end

	local name = world.entityName(id)
	if name == nil then return nil end

	local okItem, config = pcall(root.itemConfig, name)
	if okItem and type(config) == "table" and type(config.config) == "table"
	   and type(config.config.stages) == "table" then
		return config.config.stages
	end

	return nil
end

--  Which stage number means "ready to pick".
--
--  THE HARVEST STAGE IS THE ONE CARRYING harvestPool, never a fixed index.
--  Potato has three stages and corn has four, so anything of the form
--  "is this stage 2" is wrong for half the crops in the game.
local function harvestStageOf(stages)
	for index, stage in ipairs(stages) do
		if type(stage) == "table" and stage.harvestPool ~= nil then
			--  Lua lists count from 1; the engine is assumed to count from
			--  FARMABLE_STAGE_BASE. See that constant.
			return index - 1 + FARMABLE_STAGE_BASE
		end
	end

	return nil
end

--  Every farmable in network coverage, with its ripeness already decided.
local function scanFarmables()
	local rects = self.networkRects
	if rects == nil or #rects == 0 then rects = { coverageRect() } end

	local found = {}
	local seen = {}
	local objects = 0

	for _, rect in ipairs(rects) do
		local ids = world.entityQuery({ rect[1], rect[2] }, { rect[3], rect[4] }, {
			includedTypes = { "object" }
		})

		for _, id in ipairs(ids or {}) do
			if not seen[id] then
				seen[id] = true
				objects = objects + 1

				--  world.farmableStage DOES DOUBLE DUTY: it returns nil for
				--  anything that is not a farmable, so this single call is both
				--  the type test and the ripeness read. No objectType check
				--  needed alongside it.
				local ok, stage = pcall(world.farmableStage, id)

				if ok and type(stage) == "number" then
					local stages = farmableStages(id)
					local harvestAt = stages ~= nil and harvestStageOf(stages) or nil

					if harvestAt ~= nil then
						table.insert(found, {
							id = id,
							name = world.entityName(id),
							stage = stage,
							harvestAt = harvestAt,
							stageCount = #stages,
							position = world.entityPosition(id),
							ripe = (stage == harvestAt)
						})
					end
				end
			end
		end
	end

	return found, objects
end

--  THIS LOG IS THE INSTRUMENT THAT SETTLES FARMABLE_STAGE_BASE. Every crop
--  reports its stage against its stage count and against the index this port
--  believes is the harvest stage, so a fully grown crop on screen that reads
--  "stage 3 of 3 harvestAt 2" says the base is wrong and by how much.
--
--  Change-gated on the signature rather than the count, like the beacon scan:
--  crops growing IS the interesting event, and it does not move the count.
local function refreshFarmables(dt)
	self.harvestTimer = (self.harvestTimer or 0) - dt
	if self.harvestTimer > 0 then return end
	self.harvestTimer = HARVEST_INTERVAL

	local found, objects = scanFarmables()
	self.farmables = found

	local ripe = 0
	local parts = {}

	for _, crop in ipairs(found) do
		if crop.ripe then ripe = ripe + 1 end
		table.insert(parts, string.format("%s#%s stage %s of %s harvestAt %s%s",
			tostring(crop.name), tostring(crop.id),
			tostring(crop.stage), tostring(crop.stageCount),
			tostring(crop.harvestAt), crop.ripe and " RIPE" or ""))
	end

	table.sort(parts)
	local signature = table.concat(parts, " | ")

	if signature ~= self.farmableSignature then
		self.farmableSignature = signature
		sb.logInfo("PETPORT %s farmables: %s of %s object(s), %s ripe -- %s",
			stationUniqueId(), sb.printJson(#found), sb.printJson(objects),
			sb.printJson(ripe), signature == "" and "none" or signature)
	end
end

--------------------------------------------------------------------------------
--  FARM ANIMALS
--------------------------------------------------------------------------------
--
--  Mooshi, Fluffalo and anything else running the "farmable" behavior.
--
--  MUCH SIMPLER THAN CROPS, and for one reason: animals are SCRIPTED monsters,
--  where farmable objects have no script at all. /scripts/actions/monsters/
--  farmable.lua defines hasMonsterHarvest and dropMonsterHarvest as plain
--  globals in the monster's environment, and NEITHER USES ITS args OR board
--  parameters -- they are declared (args, board) and ignore both. So they are
--  callable out of band with no arguments.
--
--  world.callScriptedEntity(id, "hasMonsterHarvest") is therefore a near-exact
--  mirror of world.farmableStage:
--
--      nil    not a farmable animal at all (no such global)
--      false  farmable, not ready yet
--      true   ready to harvest
--
--  The documented trap that callScriptedEntity returns nil SILENTLY for a
--  missing function is what makes that work. Here it is the feature rather
--  than the hazard: one call is both the type test and the readiness test.
--  Can this monster TYPE be harvested, per its own config?
--
--  root.monsterParameters reads the type, so this costs nothing on the entity
--  and cannot make anything throw. BOTH fields are required: harvestTime is
--  what hasMonsterHarvest compares against -- its absence is exactly what
--  killed babies -- and harvestPool is what dropMonsterHarvest spawns from.
--
--  Checked at two levels because the binding's shape is unconfirmed: mooshi
--  carries these under baseParameters in its .monstertype, and whether
--  monsterParameters returns that table flattened or nested is not documented.
--  Looking in both costs one index.
local animalTypeCache = {}

local function animalHarvestable(monsterType)
	if monsterType == nil then return false end

	local key = tostring(monsterType)
	if animalTypeCache[key] ~= nil then return animalTypeCache[key] end

	local harvestable = false
	local ok, params = pcall(root.monsterParameters, key)

	if ok and type(params) == "table" then
		local base = type(params.baseParameters) == "table"
			and params.baseParameters or {}

		local pool = params.harvestPool or base.harvestPool
		local time = params.harvestTime or base.harvestTime

		harvestable = (pool ~= nil and time ~= nil)

		sb.logInfo("PETPORT %s monster type %s: harvestPool %s harvestTime %s -> %s",
			stationUniqueId(), key, tostring(pool ~= nil), tostring(time ~= nil),
			harvestable and "HARVESTABLE" or "not livestock")
	else
		sb.logInfo("PETPORT %s monster type %s: root.monsterParameters gave nothing",
			stationUniqueId(), key)
	end

	animalTypeCache[key] = harvestable
	return harvestable
end

local function scanAnimals()
	local rects = self.networkRects
	if rects == nil or #rects == 0 then rects = { coverageRect() } end

	local found = {}
	local seen = {}
	local monsters = 0

	for _, rect in ipairs(rects) do
		local ids = world.entityQuery({ rect[1], rect[2] }, { rect[3], rect[4] }, {
			includedTypes = { "monster" }
		})

		for _, id in ipairs(ids or {}) do
			if not seen[id] then
				seen[id] = true
				monsters = monsters + 1

				--  ASKED ABOUT THE TYPE, NOT THE ANIMAL. Nothing runs inside
				--  the entity here, which is the whole point.
				--
				--  This replaces a probe that CALLED hasMonsterHarvest on every
				--  monster in coverage to find out what it was. That worked on
				--  adults and KILLED BABIES: baby livestock runs the same
				--  farmable behavior, so the function exists, but babies have no
				--  "harvestTime" in config -- resetMonsterHarvest stores nil and
				--  farmable.lua:34 compares nil with a number. Our pcall caught
				--  it on our side; the error had already happened inside the
				--  MONSTER's script, and a script error kills the monster. The
				--  scan was culling baby Fluffalo once every five seconds.
				--
				--  root.monsterParameters answers from the type's config, so a
				--  baby is filtered before anything is invoked on it. Our own
				--  units fall out here too, having neither field.
				local monsterType = world.monsterType(id)

				if animalHarvestable(monsterType) then
					local ok, ready = pcall(world.callScriptedEntity, id,
						"hasMonsterHarvest")

					if ok and type(ready) == "boolean" then
						table.insert(found, {
							id = id,
							name = monsterType,
							ready = ready,
							position = world.entityPosition(id)
						})
					end
				end
			end
		end
	end

	return found, monsters
end

local function refreshAnimals(dt)
	self.animalTimer = (self.animalTimer or 0) - dt
	if self.animalTimer > 0 then return end
	self.animalTimer = HARVEST_INTERVAL

	local found, monsters = scanAnimals()
	self.animals = found

	local ready = 0
	local parts = {}

	for _, animal in ipairs(found) do
		if animal.ready then ready = ready + 1 end
		table.insert(parts, string.format("%s#%s%s", tostring(animal.name),
			tostring(animal.id), animal.ready and " READY" or ""))
	end

	table.sort(parts)
	local signature = table.concat(parts, " | ")

	if signature ~= self.animalSignature then
		self.animalSignature = signature
		sb.logInfo("PETPORT %s animals: %s farmable of %s monster(s), %s ready -- %s",
			stationUniqueId(), sb.printJson(#found), sb.printJson(monsters),
			sb.printJson(ready), signature == "" and "none" or signature)
	end
end

--  Send a unit at a ready animal.
--
--  READINESS IS RE-READ AT SELECTION, exactly as crop ripeness is, and for the
--  same reason: the scan is up to HARVEST_INTERVAL old and the most likely way
--  for it to be wrong is the case this task creates itself -- an animal
--  harvested a second ago is still READY in the cache for another five seconds.
--  Dispatching against that would send a unit to poke an animal with nothing to
--  give and land it on the failure backoff ladder for a fault that was ours.
--
--  ANIMALS MOVE, and nothing here chases them. The dispatch position is where
--  the animal stood at selection; the unit re-reads the live position while
--  approaching, but the standable ground target is resolved once. A Mooshi
--  ambles slowly enough that this does not matter. Smaller roving livestock may
--  outwalk it, which will present as an arrival that is out of reach -- logged
--  with the distance, deliberately, so the decision to add catch-up behaviour
--  can be made from a measurement rather than a guess.
local function animalWork()
	local animals = self.animals

	if animals == nil or #animals == 0 then
		return nil, "no farm animals in network coverage"
	end

	local from = entity.position()
	if self.petId ~= nil and world.entityExists(self.petId) then
		from = world.entityPosition(self.petId)
	end

	local best, bestDistance = nil, nil
	local rejected = { notReady = 0, claimed = 0, backedOff = 0, gone = 0,
		unreachable = 0 }

	for _, animal in ipairs(animals) do
		local workId = "animal:" .. animal.id
		local failure = self.workFailures[workId]
		local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

		if not world.entityExists(animal.id) then
			rejected.gone = rejected.gone + 1
		elseif not animalHarvestable(animal.name) then
			--  Cheap and cached, and it keeps a stale self.animals entry from
			--  reaching a call it should not.
			rejected.notReady = rejected.notReady + 1
		else
			local ok, ready = pcall(world.callScriptedEntity, animal.id,
				"hasMonsterHarvest")

			if not (ok and ready == true) then
				rejected.notReady = rejected.notReady + 1
			elseif backedOff then
				rejected.backedOff = rejected.backedOff + 1
			elseif not claimFree(workId) then
				rejected.claimed = rejected.claimed + 1
			else
				--  Live position, not the scanned one. The animal has had up to
				--  five seconds to wander since.
				local position = world.entityPosition(animal.id)
				local distance = world.magnitude(from, position)

				--  A MOVING TARGET GETS THE REACH TEST AND NOT THE MEDIUM TEST.
				--
				--  standingPointNear asks the UNIT, which is per-chassis for
				--  free: a free mover resolves through petports_flyPointNear,
				--  which already refuses a medium the chassis cannot enter, and
				--  a walker resolves through the ground search, which refuses
				--  standing in liquid it avoids. So this one call answers both
				--  halves for livestock, and sampling the animal's own tile on
				--  top of it would only add a verdict about a position that is
				--  stale by the time the unit arrives.
				--
				--  THE THIRD COPY OF A CALL medicWork ALREADY MAKES for
				--  patients. Livestock was the only moving target without it.
				if standingPointNear(position, 4) == nil then
					rejected.unreachable = rejected.unreachable + 1
				elseif bestDistance == nil or distance < bestDistance then
					best = { id = animal.id, name = animal.name, position = position }
					bestDistance = distance
				end
			end
		end
	end

	if best == nil then
		local reason = string.format(
			"%s farm animal(s), none harvestable: %s not ready, %s claimed, "
			.. "%s backed off, %s gone, %s with nowhere this chassis can stand",
			#animals, rejected.notReady, rejected.claimed,
			rejected.backedOff, rejected.gone, rejected.unreachable)

		if reason ~= self.animalRejectReason then
			self.animalRejectReason = reason
			sb.logInfo("PETPORT %s animals: %s", stationUniqueId(), reason)
		end

		return nil, reason
	end

	self.animalRejectReason = nil

	sb.logInfo("PETPORT %s ANIMAL dispatch: %s#%s at %s, %s away",
		stationUniqueId(), tostring(best.name), sb.printJson(best.id),
		sb.printJson(best.position), sb.printJson(bestDistance))

	return {
		id = "animal:" .. best.id,
		type = "animal",
		port = stationUniqueId(),
		target = best.id,
		position = best.position
	}
end

--  Pick a ripe crop to send the unit at.
--
--  NO DEFERRAL HERE, unlike collection, and that is deliberate rather than an
--  omission. Deferral exists because two ports racing for one DROP waste a walk
--  on something that may despawn before either arrives. A crop does not
--  despawn, does not move, and will still be there on the next tick -- so the
--  claim is sufficient arbitration and the loser simply picks a different crop.
--  The handoff already argues for deleting deferral outright; there is no
--  reason to grow a second copy of it here first.
local function harvestWork()
	local crops = self.farmables

	if crops == nil or #crops == 0 then
		return nil, "no farmables in network coverage"
	end

	--  Distance is measured from the UNIT, since it is the unit that walks.
	local from = entity.position()
	if self.petId ~= nil and world.entityExists(self.petId) then
		from = world.entityPosition(self.petId)
	end

	local best, bestDistance = nil, nil
	local rejected = { unripe = 0, claimed = 0, backedOff = 0, gone = 0, medium = 0 }

	for _, crop in ipairs(crops) do
		local workId = "harvest:" .. crop.id
		local claim = petports_claimGet(workId)
		local failure = self.workFailures[workId]
		local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

		local free = not backedOff and ((claim == nil)
			or claim.owner == stationUniqueId()
			or (claim.expires or 0) <= world.time())

		--  RIPENESS IS RE-READ HERE, NOT TAKEN FROM THE SCAN.
		--
		--  The scan is up to HARVEST_INTERVAL old, and the single most likely
		--  way for it to be wrong is the case this task creates itself: a crop
		--  with resetToStage is ripe when scanned, harvested a second later,
		--  and immediately unripe -- while the cache still says RIPE for
		--  another five seconds. The port would dispatch a unit to swing at it
		--  for nothing, the swing would fall through to ordinary object damage,
		--  and the crop would land on the failure backoff ladder for a fault
		--  that was entirely ours.
		--
		--  Cheap: one call per FARMABLE, not per object. The expensive part of
		--  the scan is the entityQuery and the config read, and both stay on
		--  the slow timer.
		local okStage, stage = pcall(world.farmableStage, crop.id)
		local ripe = okStage and type(stage) == "number"
			and stage == crop.harvestAt

		if not ripe then
			rejected.unripe = rejected.unripe + 1
		elseif backedOff then
			sb.logInfo("PETPORT %s crop %s SKIPPED: backed off until %s (failures %s)",
				stationUniqueId(), sb.printJson(crop.id),
				sb.printJson(failure["until"]), sb.printJson(failure.count))
			rejected.backedOff = rejected.backedOff + 1
		elseif not free then
			sb.logInfo("PETPORT %s crop %s SKIPPED: claimed by %s until %s",
				stationUniqueId(), sb.printJson(crop.id),
				tostring(claim.owner), sb.printJson(claim.expires))
			rejected.claimed = rejected.claimed + 1
		elseif not world.entityExists(crop.id) then
			--  Harvested by the player, or by another network's unit, between
			--  the scan and now.
			rejected.gone = rejected.gone + 1

		--  THIS IS THE ONE THE LOG INDICTED. A crop is an object, so the sample
		--  is its own footprint -- a plant standing with its feet in a paddy and
		--  its head in air is legitimately workable by either chassis, and one
		--  fully under water is workable only by a swimmer.
		--
		--  IN THE LOOP, NOT ON THE WINNER, and that is the whole reason it is
		--  here rather than in dispatchable(). Refusing the winner would decline
		--  the entire harvest rung and fall through to animals, so a swimmer with
		--  one dry crop nearest and four submerged ones behind it would harvest
		--  nothing. Refusing a candidate lets the next-nearest win.
		elseif not targetEligible("crop " .. tostring(crop.id), crop.position, crop.id) then
			rejected.medium = rejected.medium + 1
		else
			local distance = world.magnitude(from, crop.position)

			if bestDistance == nil or distance < bestDistance then
				sb.logInfo("PETPORT %s crop %s (%s) RIPE at %s, %s away -- new best",
					stationUniqueId(), sb.printJson(crop.id), tostring(crop.name),
					sb.printJson(crop.position), sb.printJson(distance))
				best, bestDistance = crop, distance
			end
		end
	end

	if best == nil then
		local reason = string.format(
			"%s farmable(s) in coverage, none harvestable: %s unripe, "
			.. "%s claimed, %s backed off, %s gone, %s in a medium this "
			.. "chassis cannot work in",
			#crops, rejected.unripe, rejected.claimed,
			rejected.backedOff, rejected.gone, rejected.medium)

		--  LOGGED HERE, NOT RETURNED AND HOPED FOR. findWork returns the
		--  deposit reason ahead of this one, so a port sitting next to nine
		--  ripe crops and refusing to dispatch said nothing whatsoever about
		--  the crops -- the reason existed and never reached the log. Change
		--  gated so it does not repeat every tick.
		if reason ~= self.harvestRejectReason then
			self.harvestRejectReason = reason
			sb.logInfo("PETPORT %s harvest: %s", stationUniqueId(), reason)
		end

		return nil, reason
	end

	self.harvestRejectReason = nil

	return {
		id = "harvest:" .. best.id,
		--  The footprint ladder ran on this target above -- see arch.dispatch.vouch.
		mediumVerified = true,
		type = "harvest",
		port = stationUniqueId(),
		target = best.id,
		--  CARRIED SO THE INTENT CAN BE WRITTEN AFTER THE CROP IS GONE. Once
		--  the harvest succeeds the entity no longer exists, so entityName is
		--  no longer answerable -- and the crop's own name IS the seed name,
		--  which is the whole thing the intent needs to record.
		targetName = best.name,
		position = best.position
	}
end

--  A contiguous run of dry farmland, ordered, starting from a crop.
--
--  ORDER IS THE POINT. Watering tile-by-tile as separate work items would send
--  a unit across a forty-tile row in whatever order discovery happened to
--  produce, which looks like malfunctioning rather than gardening. The run is
--  built as an ordered list and swept end to end.
--  Is this position inside coverage for ANY port on the network?
--
--  Network-wide rather than this port's own rect: one port harvests, another
--  may be nearer the crate, and a run may span two members. Falls back to the
--  own rect before the network has been derived, which is the same fallback
--  the farmable scan makes.
--
--  Defined here rather than beside its first user because it now has several,
--  the earliest being the watering run builder -- and a local called from above
--  its definition compiles as a nil global, which has bricked this file once.
local function inNetworkCoverage(position)
	local rects = self.networkRects
	if rects == nil or #rects == 0 then rects = { coverageRect() } end

	for _, rect in ipairs(rects) do
		if petports_rectContains(rect, position) then return true end
	end

	return false
end

local function waterRunFrom(anchor)
	--  THE CROP MAKES THE ROW ELIGIBLE. IT DOES NOT HAVE TO BE THIRSTY ITSELF.
	--
	--  This used to require the tile UNDER the crop to be dry, and return
	--  nothing otherwise -- so a crop standing on already-wet soil aborted
	--  before the expansion ran, and freshly tilled dry ground right beside it
	--  was never seen. Break and re-till a patch next to a watered crop and
	--  nothing would ever water it.
	--
	--  Traversal now runs through FARMLAND and collects the DRY tiles out of
	--  it. A wet tile mid-row is passed over rather than treated as the end of
	--  the row, which is the common case once a fleet has been working: rows
	--  become patchy, not cleanly split.
	local function farmlandAt(tile)
		--  COVERAGE BOUNDS THE RUN, not just the crop that anchored it.
		--
		--  scanFarmables only finds crops inside the network, so a farm that
		--  falls out of coverage stops producing work -- but the left/right
		--  expansion had no such limit and would happily walk up to
		--  WATER_RUN_REACH tiles past the edge. A crop just inside a rect could
		--  send a unit thirty tiles outside the network to water soil no port
		--  is responsible for.
		--
		--  Break rather than skip: a run is contiguous by definition, and
		--  stepping over a gap would produce a "run" the sweep walks across in
		--  a straight line through territory it was never given.
		if not inNetworkCoverage({ tile[1] + 0.5, tile[2] + 0.5 }) then
			return nil
		end

		local modName = world.mod({ tile[1], tile[2] }, "foreground")
		if modName == nil then return nil end

		local info = soilInfo(modName)
		if info == nil or not info.tilled then return nil end

		return { mod = tostring(modName), dry = info.dry, wants = info.wants }
	end

	local ordered = { anchor }

	for direction = -1, 1, 2 do
		for step = 1, WATER_RUN_REACH do
			local tile = { anchor[1] + direction * step, anchor[2] }
			if farmlandAt(tile) == nil then break end

			if direction < 0 then
				table.insert(ordered, 1, tile)
			else
				table.insert(ordered, tile)
			end
		end
	end

	--  ONE SOIL TYPE PER RUN. previousMod is a single value on the task and is
	--  used for every cast in the sweep, so a run spanning two kinds of dry
	--  soil would aim the wrong transition at half of it. Take the first dry
	--  tile's soil and keep only tiles matching it; anything else becomes its
	--  own run on a later pass.
	local soil = nil
	local tiles = {}

	for _, tile in ipairs(ordered) do
		local here = farmlandAt(tile)

		if here ~= nil and here.dry then
			if soil == nil then soil = here end

			if here.mod == soil.mod then
				table.insert(tiles, tile)
			end
		end
	end

	if soil == nil or #tiles == 0 then return nil end

	return { tiles = tiles, wants = soil.wants, mod = soil.mod }
end

--  Every dry run worth watering in this network's coverage.
--
--  ANCHORED ON CROPS, not on bare soil. A player with a large fallow field has
--  not asked for it to be watered, and scanning every tile in coverage for dry
--  farmland would generate work nobody wanted. A crop standing on dry ground is
--  an unambiguous request -- it cannot grow until the soil is wet -- and the
--  run expansion then finishes the row it is part of.
local function waterRuns()
	local runs = {}
	local seen = {}

	for _, crop in ipairs(self.farmables or {}) do
		if world.entityExists(crop.id) then
			local position = world.entityPosition(crop.id)

			--  The soil is BELOW the crop's anchor: a crop stands on tilled
			--  dirt rather than in it.
			local tile = { math.floor(position[1]), math.floor(position[2]) - 1 }
			local key = petports_tileKey(tile)

			if not seen[key] then
				local run = waterRunFrom(tile)

				if run ~= nil then
					--  Mark the whole run seen, so the next crop standing in it
					--  does not produce an overlapping duplicate. The ANCHOR is
					--  marked separately because it is no longer necessarily in
					--  the run -- a crop on already-wet soil contributes the row
					--  without being part of the work.
					seen[key] = true

					for _, t in ipairs(run.tiles) do
						seen[petports_tileKey(t)] = true
					end

					run.key = key
					table.insert(runs, run)
				else
					seen[key] = true
				end
			end
		end
	end

	return runs
end

--  Is the unit carrying something that would wet this run?
local function carriedWaterFor(run)
	if self.petData == nil or self.petData.cargo == nil then return nil end

	for _, stack in ipairs(self.petData.cargo) do
		for _, want in ipairs(run.wants or {}) do
			if stack.name == want.item then
				return stack, want
			end
		end
	end

	return nil
end

--  CAN THIS CHASSIS WATER THE HEAD OF THIS RUN?
--
--  THE SPACE ABOVE THE SOIL, NOT THE SOIL. A tilled tile is solid foreground, so
--  world.liquidAt over it always reads zero and a check aimed there would pass
--  every chassis every time. The tile above is where liquid actually sits and
--  where the unit stands, so it is both the honest sample and the dispatch
--  position -- one expression rather than two that must stay equal.
--
--  THE HEAD OF THE RUN ONLY. A run that crosses a waterline is a farm somebody
--  deliberately built half under water, and a tile that already has liquid on it
--  is not a tile that needs a bucket. If one ever shows up in a log, the fix is
--  to truncate the run to its eligible prefix -- which rewrites the task rather
--  than filtering it, and is a different shape of change.
--
--  ASKED BY BOTH LEGS, which is the whole reason it is a function. waterWork
--  asked it and withdrawWaterWork did not, so the fetch leg hauled liquid across
--  the base for runs the place leg then refused. That is the replant split
--  again, and worse: a run refused on MEDIUM records no failure, so the backoff
--  coupling added for replant cannot see it. There is nothing to back off from.
--  The only thing that stops it is asking the same question before fetching.
local function waterRunWorkable(run, tile)
	if run == nil or tile == nil then return false end

	return targetEligible("water run " .. tostring(run.key),
		{ tile[1] + 0.5, tile[2] + 1.5 }, nil)
end

--  Sweep a dry run, one tile per unit of liquid carried.
--
--  ABOVE DEPOSIT, for the same reason replant is: a unit holding water that
--  matches outstanding dry soil is mid-job, and deposit fires on any cargo.
local function waterWork()
	local runs = waterRuns()
	if #runs == 0 then return nil, "no dry soil under any crop in coverage" end

	for _, run in ipairs(runs) do
		local workId = "water:" .. tostring(run.key)
		local failure = self.workFailures[workId]
		local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

		local stack, want = carriedWaterFor(run)

		if stack ~= nil and not backedOff and claimFree(workId) then
			--  Carry decides length. One item per tile, and the unit stops when
			--  it runs out rather than pretending.
			local carried = math.min(stack.count or 1, WATER_CARRY)
			local tiles = {}

			for index = 1, math.min(carried, #run.tiles) do
				table.insert(tiles, run.tiles[index])
			end

			--  START FROM THE NEARER END and sweep away from it. Walking to the
			--  far end first doubles the trip for no reason, and reversing
			--  mid-row is the spazzing this whole structure exists to avoid.
			local from = entity.position()
			if self.petId ~= nil and world.entityExists(self.petId) then
				from = world.entityPosition(self.petId)
			end

			local head = world.magnitude(from, run.tiles[1])
			local tail = world.magnitude(from, run.tiles[#run.tiles])

			if tail < head then
				tiles = {}
				for index = 0, math.min(carried, #run.tiles) - 1 do
					table.insert(tiles, run.tiles[#run.tiles - index])
				end
			end

			--  THE GATE BEFORE THE ANNOUNCEMENT. This log used to sit above the
			--  check, so a port with six dry runs and an aquatic unit announced
			--  six WATER dispatches per scan and dispatched none of them. A line
			--  that says "dispatch" about work that is about to be refused is
			--  worse than no line: it is the first thing a reader searches for.
			--
			--  `runHead` AND NOT `head`, because `head` is already a DISTANCE in
			--  this scope, a dozen lines up, and a second local of that name
			--  shadowing it worked only by accident of the distance being
			--  consumed before the shadow was declared.
			--
			--  See waterRunWorkable for why this samples the tile ABOVE the soil.
			local runHead = tiles[1]

			if waterRunWorkable(run, runHead) then
				sb.logInfo("PETPORT %s WATER dispatch: %s tile(s) of %s in run, "
					.. "%s carried, from %s to %s",
					stationUniqueId(), sb.printJson(#tiles), sb.printJson(#run.tiles),
					sb.printJson(stack.count or 1), sb.printJson(tiles[1]),
					sb.printJson(tiles[#tiles]))

				return {
					id = workId,
					--  The footprint ladder ran on this target above -- see arch.dispatch.vouch.
					mediumVerified = true,
					type = "water",
					port = stationUniqueId(),
					tiles = tiles,
					waterIndex = 1,
					item = want.item,
					previousMod = run.mod,
					newMod = want.newMod,
					tint = want.tint,
					position = { runHead[1] + 0.5, runHead[2] + 1.5 }
				}
			end
		end
	end

	return nil, string.format("%s dry run(s), none actionable", #runs)
end

--------------------------------------------------------------------------------
--  REPLANTING
--------------------------------------------------------------------------------

--  Is this tile still a place a crop could go?
--
--  TWO TILES, NOT ONE. A farmable occupies spaces [0,0] and [0,1] anchored at
--  the bottom, so a check against the anchor alone will happily try to plant
--  into something hanging one tile above the ground.
--  A crop's real footprint, from its own config.
--
--  WAS HARDCODED 1 WIDE BY 2 TALL, generalised from potatoseed's
--  spaces [[0,0],[0,1]]. Wrong for every wide crop -- oculemon and pineapple
--  are two wide -- and the failure was quiet in both directions: the clear
--  check missed a blocker standing in the column it never looked at, and the
--  post-plant check looked for the new crop in tiles it might not occupy and
--  concluded the planting had failed.
--
--  The seed and the crop share one name, so the seed's own config describes
--  exactly what is about to appear. Cached per name: object configs are
--  static, and this is read on every occupancy test.
local seedSpacesCache = {}

local function seedSpaces(seedName)
	if seedName == nil then return { {0, 0}, {0, 1} } end
	if seedSpacesCache[seedName] ~= nil then return seedSpacesCache[seedName] end

	local spaces = nil
	local ok, config = pcall(root.itemConfig, seedName)

	if ok and type(config) == "table" and type(config.config) == "table" then
		local orientations = config.config.orientations

		if type(orientations) == "table" and type(orientations[1]) == "table"
		   and type(orientations[1].spaces) == "table"
		   and #orientations[1].spaces > 0 then
			spaces = orientations[1].spaces
		end
	end

	if spaces == nil then
		--  Loud, because falling back means occupancy is a guess from here on.
		sb.logInfo("PETPORT %s could not read spaces for %s -- assuming 1x2",
			stationUniqueId(), tostring(seedName))
		spaces = { {0, 0}, {0, 1} }
	else
		sb.logInfo("PETPORT %s footprint for %s: %s tile(s) %s",
			stationUniqueId(), tostring(seedName), sb.printJson(#spaces),
			sb.printJson(spaces))
	end

	seedSpacesCache[seedName] = spaces
	return spaces
end

--  The tiles a crop of this type would occupy if planted at this anchor.
local function seedTiles(position, seedName)
	local anchor = { math.floor(position[1]), math.floor(position[2]) }
	local tiles = {}

	for _, space in ipairs(seedSpaces(seedName)) do
		table.insert(tiles, { anchor[1] + space[1], anchor[2] + space[2] })
	end

	return tiles
end

--  Does this object actually stand on any of these tiles?
--
--  world.objectSpaces returns the object's occupied tiles RELATIVE to its own
--  position -- the same thing vanilla's pathutil objectBounds translates -- so
--  this is an exact occupancy test rather than a bounding-box overlap.
local function objectOccupies(objectId, tiles)
	local spaces = world.objectSpaces(objectId)
	if spaces == nil then return false end

	local origin = world.entityPosition(objectId)
	if origin == nil then return false end

	for _, space in ipairs(spaces) do
		local x = math.floor(origin[1]) + space[1]
		local y = math.floor(origin[2]) + space[2]

		for _, tile in ipairs(tiles) do
			if x == tile[1] and y == tile[2] then return true end
		end
	end

	return false
end

local function replantFootprintClear(position, seedName)
	local tiles = seedTiles(position, seedName)

	--  Query bounds from the real footprint, padded, since the exact test
	--  below does the actual work.
	local lox, loy = tiles[1][1], tiles[1][2]
	local hix, hiy = lox, loy

	for _, t in ipairs(tiles) do
		lox = math.min(lox, t[1]); hix = math.max(hix, t[1])
		loy = math.min(loy, t[2]); hiy = math.max(hiy, t[2])
	end

	--  QUERY WIDE, THEN FILTER EXACTLY, and the filter is the whole point.
	--
	--  entityQuery returns anything whose bounds INTERSECT the rect, and a rect
	--  drawn tightly around one tile touches the edge of the next one. In a
	--  planted row -- crops at x, x+1, x+2 -- every tile therefore reported
	--  itself occupied by its neighbour, and every replant intent was cleared
	--  as "footprint occupied" within seconds of being written. MEASURED: nine
	--  intents set, seven destroyed this way, and the two survivors only lasted
	--  because their neighbours had not regrown yet.
	--
	--  Padding the query and then testing real occupancy is immune to that,
	--  and costs one objectSpaces call per candidate.
	local candidates = world.entityQuery(
		{ lox - 1, loy - 1 }, { hix + 2, hiy + 2 },
		{ includedTypes = { "object" } })

	for _, id in ipairs(candidates or {}) do
		if objectOccupies(id, tiles) then
			sb.logInfo("PETPORT %s footprint for %s at %s BLOCKED by object %s",
				stationUniqueId(), tostring(seedName), sb.printJson(tiles),
				sb.printJson(id))
			return false
		end
	end

	return true
end

--  Is the ground under the tile still tilled?
--
--  THE SOIL IS BELOW THE ANCHOR. A crop stands ON tilled dirt, so the matmod to
--  test is at y - 1, not at the crop's own tile. Both are logged on failure
--  because that offset is an assumption about where world.entityPosition sits
--  for an object, and one look at a real field settles it.
--
--  Mods are NAMED at this layer, not numbered: world.placeMod takes "tilled",
--  and vanilla's own removable-mod tables compare against "tilleddry". So the
--  31/32 ids in the material config are not what shows up here.
local function replantGroundTilled(position)
	local under = world.mod({ position[1], position[2] - 1 }, "foreground")
	local at = world.mod({ position[1], position[2] }, "foreground")

	--  ASK THE MATMOD, DO NOT COMPARE ITS NAME.
	--
	--  This used to test the name against "tilled" and "tilleddry" literally,
	--  which is correct for vanilla and wrong for every modded soil -- and mods
	--  like Alta/Enternia ship a lot of them. Both vanilla matmods carry
	--  "tilled" : true, and soilInfo already reads and caches that, so the
	--  question "is this farmland" is answerable without knowing any names.
	--
	--  Modded soil support for replanting therefore costs nothing beyond this
	--  line, the same way watering got it for free by reading liquidInteractions
	--  rather than hardcoding a wet/dry pair.
	local info = soilInfo(under)
	local tilled = info ~= nil and info.tilled

	--  THE SOIL IS AT y - 1 AND ONLY THERE, now that it is verified.
	--
	--  This used to accept a tilled mod at EITHER tile, hedging an unverified
	--  assumption about where world.entityPosition sits for an object -- getting
	--  it wrong would have cleared every replant intent within five seconds as
	--  "ground no longer tilled", with nothing obviously broken. Watering settled
	--  it: waterRuns derives the soil tile the same way, from
	--  floor(cropPosition) - 1, and it wets exactly the right tiles. The hedge
	--  can go, and dropping it means a crop whose anchor tile happens to be
	--  farmland no longer masks missing soil beneath it.

	if not tilled then
		sb.logInfo("PETPORT %s replant ground at %s: mod below is %s (tilled %s), "
			.. "mod at is %s -- not farmland",
			stationUniqueId(), sb.printJson(position), tostring(under),
			tostring(info ~= nil and info.tilled), tostring(at))
	end

	return tilled
end

--  Drop intents the world has already answered.
--
--  RUNS ON THE FARMABLE TIMER, not the work tick. Sweeping is cheap but it is
--  still an entityQuery per intent, and intents are long-lived by design.
--  OWN TIMER, AND CALLED FROM workUpdate, NOT FROM refreshFarmables.
--
--  This used to be a call at the bottom of refreshFarmables, which crashed
--  every port on the first sweep: refreshFarmables is defined EARLIER in this
--  file, so the `local function` below was not in scope at that call site and
--  Lua compiled it as a lookup of a GLOBAL named sweepReplants, which is nil.
--  Same trap the receiveCargo and writeBackToItem comments describe, reached
--  from the other direction.
--
--  Calling it from workUpdate -- which is defined after everything -- removes
--  the ordering dependency entirely rather than papering over it with a
--  forward declaration.
REPLANT_SWEEP_INTERVAL = 5.0

local function sweepReplants(dt)
	self.replantSweepTimer = (self.replantSweepTimer or 0) - dt
	if self.replantSweepTimer > 0 then return end
	self.replantSweepTimer = REPLANT_SWEEP_INTERVAL

	local intents = petports_replantsAll()

	local outstanding = {}
	for key, intent in pairs(intents) do
		table.insert(outstanding, tostring(key) .. "=" .. tostring(intent.name))
	end
	table.sort(outstanding)

	local signature = table.concat(outstanding, " | ")
	if signature ~= self.replantSignature then
		self.replantSignature = signature
		sb.logInfo("PETPORT %s replant intents outstanding: %s",
			stationUniqueId(), signature == "" and "none" or signature)
	end

	--  ORPHANS: intents no port anywhere can reach.
	--
	--  The coverage gate below is CORRECT and must stay. Outside coverage the
	--  chunk is not loaded, so a footprint or tile test answers from nothing --
	--  and clearing on that would delete a working farm the moment the player
	--  walked away.
	--
	--  The consequence is that an intent nobody covers is evaluated by nobody
	--  and can never be cleared. Move a port, mine one, or rebuild a farm
	--  somewhere else and those tiles freeze in world.properties permanently,
	--  with no way to remove them from in game. It was the only unbounded
	--  structure this mod writes: claims expire and sweep, and the registry is
	--  one entry per port removed in die().
	--
	--  petports_anyPortCovers asks the REGISTRY rather than this port's network,
	--  which is what separates "nobody's problem" from "somebody else's". A tile
	--  another network covers is left alone for that network to handle.
	--
	--  BATCHED INTO ONE WRITE. petports_replantClear rewrites the whole property
	--  per call, and a world that has been farmed and rebuilt can produce a lot
	--  of these at once.
	local orphans = {}

	for key, intent in pairs(intents) do
		if type(intent) ~= "table" or type(intent.position) ~= "table" then
			--  Malformed, and previously immortal: the old loop skipped anything
			--  with no position, which meant it was never looked at again.
			table.insert(orphans, key)
		elseif inNetworkCoverage(intent.position) then
			--  A SUCCESSFUL REPLANT CLEARS ITS OWN INTENT BY EXISTING, because
			--  a farmable is an object and lands in this same test. One check
			--  covers "we did it" and "the player put a crate there".
			if not replantFootprintClear(intent.position, intent.name) then
				petports_replantClear(key, "footprint occupied")
			elseif not replantGroundTilled(intent.position) then
				petports_replantClear(key, "ground no longer tilled")
			end
		elseif not petports_anyPortCovers(intent.position) then
			table.insert(orphans, key)
		end
	end

	--  EVERY PORT RUNS THIS, and that is harmless: the first one to reach it
	--  wins and the rest find nothing to clear. Making one port responsible
	--  would mean electing one, and an election is more machinery than the
	--  duplicate work costs.
	if #orphans > 0 then
		petports_replantClearMany(orphans, "no port covers the tile")
	end
end

--  Does any networked container hold this seed?
local function containerWithSeed(seedName)
	--  SEEDS COME OUT OF THE SAME CRATES THEY WENT INTO. Deposit beacons are
	--  the network's storage as far as this mod is concerned, and reusing that
	--  list means a player who moves their storage does not also have to tell
	--  the replanting system about it.
	--
	--  containerAvailable answers "how many could be consumed", which is a
	--  stronger test than reading containerItems and matching names -- it is
	--  the same question containerConsume will ask when the unit arrives.
	for _, beacon in ipairs(petports_beaconsFor("deposit")) do
		if world.entityExists(beacon.id) then
			local available = world.containerAvailable(beacon.id,
				{ name = seedName, count = 1 })

			--  KEEP LOOKING RATHER THAN GIVE UP, which is the same rule
			--  restockFetchWork's source scan follows and for the same reason: a
			--  network holding the seed in both a wet crate and a dry one should
			--  serve a swimmer from the wet one rather than refuse to replant.
			--
			--  BOTH FETCH LEGS COME THROUGH HERE -- withdrawWork's seed and
			--  medicWork's dose. The medic's DELIVERY leg has been checked since
			--  it was written and its fetch never was, so a medic could verify it
			--  could reach a patient and then be sent to a crate it could not.
			if type(available) == "number" and available >= 1 then
				if servicePointNear("crate " .. tostring(beacon.id),
					beacon.id, beacon.position, 4) ~= nil then
					return beacon.id
				end
			end
		end
	end

	return nil
end

--  Is the unit already carrying the seed an outstanding intent wants?
local function carriedSeedIntent()
	if self.petData == nil or self.petData.cargo == nil then return nil end

	local intents = petports_replantsAll()

	for _, stack in ipairs(self.petData.cargo) do
		for key, intent in pairs(intents) do
			if intent.name ~= nil and stack.name == intent.name
			   and intent.position ~= nil
			   and inNetworkCoverage(intent.position) then
				return key, intent, stack
			end
		end
	end

	--  NO MATCH, WITH BOTH SIDES NON-EMPTY -- the interesting failure, and the
	--  one that produced a withdraw/deposit loop with nothing in the log that
	--  looked wrong. Names both sides so a mismatch is readable at a glance
	--  rather than inferred from what did not happen.
	--
	--  Change-gated: this is reached on every work tick a unit is carrying
	--  something, which is most of them.
	if #self.petData.cargo > 0 then
		local held = {}
		for _, stack in ipairs(self.petData.cargo) do
			table.insert(held, tostring(stack.name))
		end

		local wanted = {}
		for key, intent in pairs(intents) do
			table.insert(wanted, string.format("%s@%s%s", tostring(intent.name),
				tostring(key),
				inNetworkCoverage(intent.position or {0, 0}) and "" or " (OUT OF RANGE)"))
		end

		table.sort(held)
		table.sort(wanted)

		local signature = table.concat(held, ",") .. " vs " .. table.concat(wanted, ",")

		if signature ~= self.replantMissSignature then
			self.replantMissSignature = signature
			sb.logInfo("PETPORT %s carrying [%s] but no intent matches: intents are [%s]",
				stationUniqueId(),
				table.concat(held, ", "),
				#wanted > 0 and table.concat(wanted, ", ") or "none")
		end
	end

	return nil
end

--  Walk the seed we are already holding to the hole it came out of.
--
--  THIS OUTRANKS DEPOSIT, and that ordering is the whole reason this task can
--  exist. Deposit fires on ANY cargo, so a unit holding a seed would otherwise
--  carry it straight past the tile it belongs in and back to a crate.
--
--  The rule is narrow on purpose: replant wins ONLY when the cargo is the seed
--  an outstanding intent names. A unit holding a potato still deposits. That
--  also makes the whole thing self-healing -- if an intent is invalidated while
--  a unit is carrying its seed, the match stops holding, deposit takes over,
--  and the seed goes to storage like any other item.
local function replantWork()
	local key, intent = carriedSeedIntent()
	if key == nil then return nil, "no carried seed matches an intent" end

	--  BACKOFF IS LOAD-BEARING HERE, not a nicety. Nothing about a failed
	--  replant changes on its own: the unit is still holding the seed, the
	--  intent still exists, and the match still holds -- so without this the
	--  port re-dispatches the identical task on the very next tick and the unit
	--  retries a refused placeObject several times a second, forever. Every
	--  other work type gets away with omitting this because its precondition is
	--  consumed by the attempt.
	local failure = self.workFailures["replant:" .. key]
	if failure ~= nil and (failure["until"] or 0) > world.time() then
		return nil, string.format("replant at %s backed off until %s",
			tostring(key), sb.printJson(failure["until"]))
	end

	if not replantFootprintClear(intent.position, intent.name) then
		petports_replantClear(key, "footprint occupied at dispatch")
		return nil, "intent tile is occupied"
	end

	--  ABOVE THE HOLE, NOT THE HOLE. Same trap watering has: the intent names a
	--  tilled tile, which is solid foreground, so sampling it reads zero liquid
	--  for every chassis and the check would be vacuously true -- and worse than
	--  useless, because "air" is a REFUSAL for an aquatic unit, so a submerged
	--  farm would turn away the only chassis that could work it.
	--
	--  NOT DISPATCHED FROM HERE, deliberately. The task position stays the tile,
	--  because the unit resolves its own standing point from it the way
	--  collection does, and changing that would be a change to placement rather
	--  than to eligibility.
	local above = { intent.position[1] + 0.5, intent.position[2] + 1.5 }
	local suits, why = targetSuits(above, nil)

	if not suits then
		targetRefused("replant at " .. tostring(key), why)
		return nil, "replant tile " .. tostring(key) .. " " .. tostring(why)
	end

	sb.logInfo("PETPORT %s REPLANT dispatch: %s back into %s (tile %s)",
		stationUniqueId(), tostring(intent.name), tostring(key),
		sb.printJson(intent.position))

	return {
		id = "replant:" .. key,
		--  The footprint ladder ran on this target above -- see arch.dispatch.vouch.
		mediumVerified = true,
		type = "replant",
		port = stationUniqueId(),
		target = key,
		seed = intent.name,
		--  Placement wants the tile; standing wants ground near it. The unit
		--  resolves the second from the first, the same way collection does.
		position = { intent.position[1] + 0.5, intent.position[2] + 0.5 },
		tile = intent.position
	}
end

--  Fetch a seed from storage for an outstanding intent.
--
--  LAST IN THE ORDER, BELOW HARVEST, and that is a real decision rather than an
--  accident: this is the only task that MANUFACTURES cargo rather than clearing
--  something. Drops despawn and crops occupy space; an empty tile does neither,
--  so replanting is the chore a network does in its downtime. The visible
--  consequence is that a busy base replants slowly, which is correct.
--
--  SEED GOES TO STORAGE FIRST, BY DESIGN. The harvest drops its seed on the
--  ground, ordinary collection carries it to a crate, and only then does this
--  fetch it back out. The round trip is the point: every seed is accounted for
--  in storage, so a player who wants them for food or crafting can take them
--  before the network spends them on replanting.
--  Fetch liquid for a dry run.
--
--  ONE TRIP, MANY TILES. The economy is one item per tile; the LOGISTICS are
--  one walk per run. Those are separate decisions and conflating them is how a
--  forty-tile row turns into forty round trips.
local function withdrawWaterWork()
	local runs = waterRuns()
	if #runs == 0 then return nil, "no dry soil needing water" end

	for _, run in ipairs(runs) do
		--  Already carrying the right thing? Then this is waterWork's problem,
		--  not ours.
		if carriedWaterFor(run) == nil then
			local workId = "fetchwater:" .. tostring(run.key)
			local failure = self.workFailures[workId]
			local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

			--  BEFORE THE CRATE SCAN, because the crate is irrelevant if the
			--  destination is not workable. waterWork approaches the run from
			--  whichever end is nearer, so either end being workable is enough
			--  to be worth fetching for; asking about both is what waterWork
			--  itself will do when it picks the end.
			local reachableEnd = waterRunWorkable(run, run.tiles[1])
				or waterRunWorkable(run, run.tiles[#run.tiles])

			if not backedOff and reachableEnd and claimFree(workId)
			   and claimFree("water:" .. tostring(run.key)) then
				local wanted = math.min(#run.tiles, WATER_CARRY)

				for _, want in ipairs(run.wants) do
					for _, beacon in ipairs(petports_beaconsFor("deposit")) do
						if world.entityExists(beacon.id) then
							local available = world.containerAvailable(beacon.id,
								{ name = want.item, count = 1 })

							--  A SOURCE THE UNIT CANNOT REACH IS NOT A SOURCE. Same rule
							--  as containerWithSeed above: skip it and let the loop
							--  find another crate holding the same liquid.
							if type(available) == "number" and available >= 1
								and servicePointNear("crate " .. tostring(beacon.id),
									beacon.id, beacon.position, 4) ~= nil then
								local take = math.min(wanted, available)

								sb.logInfo("PETPORT %s FETCHWATER dispatch: %s x%s "
									.. "from %s for a %s tile run",
									stationUniqueId(), tostring(want.item),
									sb.printJson(take), sb.printJson(beacon.id),
									sb.printJson(#run.tiles))

								return {
									id = workId,
									--  The footprint ladder ran on this target above -- see arch.dispatch.vouch.
									mediumVerified = true,
									type = "withdraw",
									port = stationUniqueId(),
									target = beacon.id,
									seed = want.item,
									count = take,
									position = world.entityPosition(beacon.id)
								}
							end
						end
					end
				end
			end
		end
	end

	return nil, string.format("%s dry run(s), no liquid in storage for any", #runs)
end

local function withdrawWork()
	--  CARRYING SOMETHING IS NOT A REASON NOT TO FETCH A SEED.
	--
	--  This used to refuse on any cargo at all, which deadlocked the exact
	--  situation it most needed to survive: storage full, unit holding a stack
	--  nothing will accept. Deposit cannot place it, so the unit carries it
	--  forever -- and a blanket cargo refusal here meant replanting stopped too,
	--  even with seeds sitting in a crate and bare tilled ground waiting.
	--  Nothing about a full crate should stop a seed going into the ground.
	--
	--  What IS still refused is fetching a second seed while already holding one
	--  an intent wants, since that seed is about to be planted and a unit
	--  hoarding seeds helps nobody.
	if carriedSeedIntent() ~= nil then
		return nil, "unit is already carrying a seed for an intent"
	end

	local intents = petports_replantsAll()
	local wanted = 0

	for key, intent in pairs(intents) do
		if intent.name ~= nil and intent.position ~= nil
		   and inNetworkCoverage(intent.position) then
			wanted = wanted + 1

			local workId = "withdraw:" .. key
			local failure = self.workFailures[workId]
			local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

			--  A BACKED-OFF PLACE LEG BACKS OFF ITS FETCH LEG TOO.
			--
			--  The two halves carry different work ids, so they carried
			--  different backoff entries, and a replant that had failed left its
			--  withdraw completely eligible. Measured: a unit fetched one
			--  oculemonseed for intent 2506,1184, could not place it, deposited
			--  it back into the crate it came from, found its cargo empty, and
			--  fetched the same seed again -- nine times in thirty seconds, one
			--  cycle every three, until another port took the intent. The
			--  withdraw leg never failed, so its own backoff never engaged; only
			--  the leg it was fetching for had given up.
			--
			--  THE CLAIM CHECK BELOW ALREADY CONSULTS THIS KEY. Reading
			--  "replant:"..key for claims and not for failures was the whole gap:
			--  the code already knew the sibling leg existed and asked it only
			--  half a question.
			--
			--  FETCHING IS NOT FREE. Manufacturing cargo for a leg that will not
			--  run costs a round trip, blocks the single cargo slot, and -- since
			--  deposit outranks nothing that could clear it -- puts the stack
			--  straight back where it came from. Idling is the better failure.
			local placeFailure = self.workFailures["replant:" .. key]
			local placeBackedOff = placeFailure ~= nil
				and (placeFailure["until"] or 0) > world.time()

			if placeBackedOff then backedOff = true end

			--  BOTH LEGS ARE CHECKED, and the first one is the fix for a
			--  livelock rather than belt-and-braces.
			--
			--  dispatchWork does take a claim on this work id, so two ports
			--  cannot both FETCH for one intent -- but the refusal happens at
			--  DISPATCH, after selection has already committed to this intent.
			--  A second port would propose the same withdraw, be rejected,
			--  return no work, and propose it again next tick, forever, never
			--  reaching the other intents in the list. Checking here means it
			--  skips to the next one instead.
			--
			--  The replant leg is checked because the two legs have different
			--  work ids and therefore different claims. Without it, a port
			--  would happily fetch a second seed for a tile another unit is
			--  already walking one to.
			local free = not backedOff
				and claimFree(workId)
				and claimFree("replant:" .. key)

			if free then
				local containerId = containerWithSeed(intent.name)

				if containerId ~= nil then
					return {
						id = "withdraw:" .. key,
						--  The footprint ladder ran on this target above -- see arch.dispatch.vouch.
						mediumVerified = true,
						type = "withdraw",
						port = stationUniqueId(),
						target = containerId,
						seed = intent.name,
						intent = key,
						position = world.entityPosition(containerId)
					}
				end
			end
		end
	end

	if wanted == 0 then
		return nil, "no replant intents in network coverage"
	end

	--  NEVER BLOCKS. An intent with no seed in storage simply waits, the same
	--  way a dry unit is routed around rather than stalling the port. A player
	--  who stops stocking a seed gets a bare tile, not a stuck network.
	return nil, string.format(
		"%s replant intent(s), none actionable (no seed in storage, claimed, "
		.. "or the replant leg has backed off)",
		wanted)
end

--------------------------------------------------------------------------------
--  RESTOCKING
--------------------------------------------------------------------------------
--
--  A restock beacon names ONE item and a range. Units keep that crate stocked
--  out of the network's ordinary storage.
--
--  MIN IS WHEN TO START, MAX IS WHEN TO STOP, and the gap between them is the
--  entire reason there are two numbers. One quota thrashes: fetch one item,
--  drop below it, fetch another, forever.
--
--  TWO LEGS WITH DIFFERENT PRIORITIES, and that split is the whole design.
--  Fetching manufactures cargo and sits at the bottom of findWork beside tidy.
--  Delivering sits ABOVE deposit, because deposit fires on ANY cargo and would
--  otherwise walk a fetched stack straight past the crate it was fetched for
--  and into ordinary storage. That is the same argument replantWork and
--  waterWork already make, arrived at independently.
--
--  A RESTOCK CRATE IS NEVER A SOURCE. Only deposit beacons are searched for
--  stock, so two request crates cannot drain each other and the "two crates
--  with a quota never trade" rule costs no code -- it is structural. Eviction
--  goes out through depositWork into ordinary storage, and if a second request
--  crate wants that item it fetches it from there like anything else.

--  How much of one item a container holds, counted BY NAME.
--
--  Not containerAvailable, which matches a full descriptor including
--  parameters. A quota is a statement about a name -- "keep twenty torches
--  here" means twenty torches, not twenty torches that match some sample's
--  parameters -- and this is the count the player is thinking of.
--
--  Returns nil when the container cannot be read, which the callers treat as
--  "do not act", never as zero. Zero would read as "empty, fetch everything".
local function restockHeld(containerId, name)
  if not world.entityExists(containerId) then return nil end

  local ok, items = pcall(world.containerItems, containerId)
  if not ok or type(items) ~= "table" then return nil end

  local total = 0

  --  pairs, not ipairs: containerItems is keyed by slot and empty slots leave
  --  holes, so ipairs stops at the first gap. Order does not matter here --
  --  this is a sum -- so nothing needs sorting.
  for _, stack in pairs(items) do
    if type(stack) == "table" and stack.name == name then
      total = total + (stack.count or 1)
    end
  end

  return total
end

--  Every configured restock beacon in coverage.
local function restockBeacons()
  local out = {}

  for _, beacon in ipairs(petports_beaconsFor("restock")) do
    if beacon.requests ~= nil and world.entityExists(beacon.id) then
      table.insert(out, beacon)
    end
  end

  return out
end

--  Carrying something a request crate wants? Then take it there.
--
--  ABOVE depositWork IN findWork. Deposit fires on ANY cargo, so without this
--  ordering a unit that had just fetched 500 hazard blocks for a request crate
--  would carry them to the nearest deposit beacon instead -- and then
--  restockFetchWork would fetch them straight back out again. That loop is
--  exactly the one replantWork's header describes being bitten by, where every
--  individual task succeeds and nothing in the log looks wrong.
--
--  SELF-HEALING, like replant. The match is re-derived from the crate's current
--  contents every tick rather than remembered on the task, so a request the
--  player edits or deletes mid-walk simply stops matching and deposit takes the
--  cargo to storage like anything else.
--
--  NEAREST CRATE, THEN ITS REQUESTS IN ORDER. petports_beaconsFor already
--  sorts by distance, so a unit holding something two crates both want goes to
--  the closer one.
--  TASK -- MEDICAL DELIVERY
--
--  ONE MEDICAL GOOD PER TRIP, and that is a balance decision rather than a
--  limitation. This is free automated healing; a player who wants it to scale
--  adds another pet. Carrying a stack would make one medic cover a whole base
--  and delete the reason to build a second.
--
--  THE MODULE IS THE SWITCH. There is no fifth participation group, because one
--  port holds one unit and a checkbox plus a module is the two-switches-for-one-
--  behaviour trap that killed the farming module. No medic module, no medic work.
--
--  THE PATIENT MOVES, AND THAT IS ACCEPTED. `todo.pathing.movingtarget` is
--  unbuilt: the approach position is resolved once and a wounded player is the
--  worst case of a stale target in this whole mod. Partial delivery beats none,
--  and a failed dispatch already self-corrects. DO NOT READ A HIGH FAILURE RATE
--  HERE AS A MEDIC BUG.
--
--  THE SPLASH SOFTENS IT. Delivery is an area projectile rather than a touch, so
--  the unit does not have to reach the patient's exact tile -- only close enough
--  for the damage poly to cover it. That widens arrival tolerance for this task
--  specifically.
local function medicWork()
  --  OBLIVIOUS IS CHECKED HERE AND NOT IN findWork. The four participation
  --  groups are zeroed there, but medic is not one of them -- it has no group,
  --  because the module is its switch. So it needs its own check or an
  --  oblivious medic keeps working.
  if petportOblivious() then return nil, "oblivious" end
  if not petportMedic() then return nil, "no medic module socketed" end

  --  HELD BEFORE ASKED FOR. Unlike water, which is withdrawn per run, the unit
  --  carries its dose -- so no patient is worth choosing until there is
  --  something to give them.
  local carried = nil
  if self.petData ~= nil and type(self.petData.cargo) == "table" then
    for _, stack in ipairs(self.petData.cargo) do
      if stack.name == MEDIC_ITEM then
        carried = stack
        break
      end
    end
  end

  --  NOTE: not carrying a dose is NOT a reason to stop. The fetch leg below is
  --  what turns an empty-handed medic into one holding a medical good, and its
  --  absence is why the first build of this never dispatched anything.

  local patients = medicPatients()
  if #patients == 0 then return nil, "no treatable patient in coverage" end

  --  NO DOSE IN HAND? GO AND GET ONE. This leg was missing from the first
  --  build and the symptom was total silence: medicWork required the unit to
  --  ALREADY be carrying medicalgoods, nothing ever fetched them, so the
  --  generator returned nil forever and never logged a reason.
  --
  --  IT IS IN THIS GENERATOR RATHER THAN withdrawWork DELIBERATELY. That one is
  --  driven entirely by replant intents -- it fetches a seed because a tile is
  --  waiting for it -- and medic has no intent table. Keeping both legs here
  --  means one place knows the whole task: fetch when empty, deliver when
  --  loaded.
  --
  --  ONLY WHEN THERE IS A PATIENT. Fetching a dose speculatively would leave a
  --  unit holding a medical good it has nobody to give to, blocking the cargo
  --  slot that hauling and harvesting need.
  if carried == nil then
    local containerId = containerWithSeed(MEDIC_ITEM)

    --  "NONE THIS UNIT CAN GET TO", NOT "NONE". containerWithSeed skips a crate
    --  the chassis cannot reach, so a nil here covers both cases and the old
    --  wording would send a player looking for a stock problem that is really a
    --  terrain one. The crate that was skipped names itself in the SKIPPING line
    --  above this, so the pair reads correctly.
    if containerId == nil then
      return nil, string.format(
        "%s patient(s) waiting, but no %s in network storage this unit can reach",
        #patients, MEDIC_ITEM)
    end

    local fetchId = "medicfetch:" .. stationUniqueId()
    local failure = self.workFailures[fetchId]

    if failure ~= nil and (failure["until"] or 0) > world.time() then
      return nil, "medic fetch backed off"
    end

    sb.logInfo("PETPORT %s MEDIC fetch: %s patient(s) waiting, collecting one %s from %s",
      stationUniqueId(), sb.printJson(#patients), tostring(MEDIC_ITEM),
      sb.printJson(containerId))

    --  A `withdraw` TASK, REUSING THE SEED MACHINERY WHOLESALE. The unit-side
    --  handler takes one of `seed` out of `target` and puts it in cargo; it has
    --  no opinion about what the item is for. Naming the field `seed` is
    --  inherited rather than chosen -- see todo below if it ever gets renamed.
    return {
      id = fetchId,
      --  The footprint ladder ran on this target above -- see arch.dispatch.vouch.
      mediumVerified = true,
      type = "withdraw",
      port = stationUniqueId(),
      target = containerId,
      seed = MEDIC_ITEM,
      position = world.entityPosition(containerId)
    }
  end

  for _, patient in ipairs(patients) do
    local workId = petports_healWorkId(patient.id)
    local failure = self.workFailures[workId]
    local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

    if not backedOff and claimFree(workId) then
      --  APPROACH A STANDABLE SPOT NEAR THEM, not their exact position. An
      --  entity position is its CENTRE and a humanoid's is at its feet, so
      --  neither is somewhere a unit can finish a path -- the same reasoning
      --  restock delivery uses for a crate.
      local stand = standingPointNear(patient.position, MEDIC_REACH)

      if stand ~= nil then
        sb.logInfo("PETPORT %s MEDIC dispatch: patient %s class %s at %s%% health, "
          .. "approach %s",
          stationUniqueId(), sb.printJson(patient.id), patient.class,
          sb.printJson(math.floor(patient.ratio * 100)), sb.printJson(stand))

        return {
          id = workId,
          type = "medic",
          port = stationUniqueId(),

          --  THE ENTITY ID TRAVELS, NOT JUST THE POSITION. Arrival re-reads
          --  health from the entity, because a patient who recovered on the
          --  way should not cost a medical good.
          patient = patient.id,
          patientClass = patient.class,

          item = MEDIC_ITEM,
          effect = MEDIC_EFFECT,
          duration = MEDIC_DURATION,
          projectile = MEDIC_PROJECTILE,

          position = stand
        }
      end

      sb.logInfo("PETPORT %s MEDIC patient %s SKIPPED: no standable spot within %s tiles of %s",
        stationUniqueId(), sb.printJson(patient.id), sb.printJson(MEDIC_REACH),
        sb.printJson(patient.position))
    end
  end

  return nil, string.format("%s patient(s), none actionable", #patients)
end

local function restockDeliverWork()
  if self.petData == nil or self.petData.cargo == nil then return nil end
  if #self.petData.cargo == 0 then return nil end

  local beacons = restockBeacons()
  if #beacons == 0 then return nil end

  for _, beacon in ipairs(beacons) do
    for _, request in ipairs(beacon.requests) do
      --  Is any of what we hold what this crate asked for?
      local carried = nil
      for _, stack in ipairs(self.petData.cargo) do
        if stack.name == request.item then
          carried = stack
          break
        end
      end

      if carried ~= nil then
        local have = restockHeld(beacon.id, request.item)

        --  ALREADY AT MAX MEANS DO NOT DELIVER, which is also what stops an
        --  overshoot ping-ponging: the excess goes back to storage through
        --  depositWork, and this refuses to bring it out again.
        if have ~= nil and have < request.max then
          --  nil means the engine will not answer. Treated as YES here, unlike
          --  tidying: the unit is already holding this and has to put it
          --  somewhere, so refusing would strand it. A crate that turns out to
          --  be full returns a leftover and depositWork places the remainder.
          local fits = world.containerItemsCanFit ~= nil
            and world.containerItemsCanFit(beacon.id, carried) or nil

          if fits == nil or fits > 0 then
            local stand, standWhy = servicePointNear("request crate " .. tostring(beacon.id),
              beacon.id, beacon.position, 4)

            if stand == nil then
              sb.logInfo("PETPORT %s restock delivery to %s SKIPPED: %s of %s",
                stationUniqueId(), sb.printJson(beacon.id), tostring(standWhy),
                sb.printJson(beacon.position))
            else
              sb.logInfo("PETPORT %s delivering %s x%s to request crate %s (has %s of %s)",
                stationUniqueId(), tostring(request.item),
                sb.printJson(carried.count or 1), sb.printJson(beacon.id),
                sb.printJson(have), sb.printJson(request.max))

              return {
                --  KEYED BY CRATE AND ITEM. The crate alone would serialise two
                --  units delivering different materials to one box for no
                --  reason; containerAddItems gives each arrival a truthful
                --  answer about what it took.
                --
                --  PORT-SUFFIXED, like deposit and for the same reason: an
                --  exclusive claim would refuse every other port's unit and
                --  strand them mid-shuffle.
                id = "restockput:" .. tostring(beacon.id)
                  .. ":" .. tostring(request.item) .. "@" .. stationUniqueId(),
                --  The footprint ladder ran on this target above -- see arch.dispatch.vouch.
                mediumVerified = true,
                type = "deposit",
                target = beacon.id,

                --  What makes this a delivery rather than a deposit. See the
                --  report handler and depositCargoOnly.
                only = request.item,

                position = stand,
                containerPosition = beacon.position,
                port = stationUniqueId(),
                dwell = 0
              }
            end
          end
        end
      end
    end
  end

  return nil
end

--  A request crate is below one of its minimums. Go and get some.
--
--  BOTTOM OF findWork, BESIDE TIDY. A player who asked for 2000 dirt did ask
--  for it, but not more urgently than a drop on a despawn timer -- and this is
--  the only work besides fetching that MANUFACTURES cargo rather than clearing
--  something.
--
--  Runs only with empty cargo, because the cargo guard in findWork returns
--  before reaching here. So a fetched stack is the unit's whole load and
--  restockDeliverWork above is guaranteed to match it on the next tick.
--
--  ONE REQUEST PER TRIP. A crate naming twenty materials produces twenty
--  sequential trips rather than twenty tasks, which is the same standing design
--  tidying uses -- and it means a crate short on two things fills the first,
--  then the second, rather than needing a unit that can carry both.
local function restockFetchWork()
  local beacons = restockBeacons()
  if #beacons == 0 then return nil, "no configured restock beacon in coverage" end

  local short, unstocked, noRoom, unreachable = 0, 0, 0, 0

  for _, beacon in ipairs(beacons) do
    --  THE REQUEST CRATE IS THE DESTINATION, AND IT MUST BE REACHABLE FIRST.
    --
    --  THIRD INSTANCE OF ONE BUG. This generator, like drainWork before it,
    --  validated its SOURCE and never its DESTINATION -- so a unit was sent to
    --  withdraw stock for a crate it could not deliver to, and the result is a
    --  livelock in which every single task succeeds:
    --
    --    restock:17:petports_petfuel_savory  withdraw from crate 31   done
    --    restockDeliverWork refuses 17, unreachable
    --    deposit -> crate 31                                          done
    --    request 17 is still short                                    withdraw again
    --
    --  MEASURED at roughly one cycle every three seconds against a submerged
    --  request crate, with nothing in the log resembling an error.
    --
    --  THE GENERAL SHAPE, since it has now cost three sessions' worth of
    --  symptoms: ANY GENERATOR WHOSE DESTINATION DIFFERS FROM ITS SOURCE MUST
    --  CHECK BOTH. Checking only the source produces work that completes and
    --  accomplishes nothing, and a repeating pair of successes is invisible to
    --  the reject machinery and to the failure counters alike.
    --
    --  standingPointNear asks the UNIT, so this is per-chassis for free: a
    --  submerged request crate is unreachable for a walker and fine for a
    --  swimmer, with no special case here.
    if servicePointNear("request crate " .. tostring(beacon.id),
       beacon.id, beacon.position, 4) == nil then
      unreachable = unreachable + 1

      if self.lastRestockSkip ~= beacon.id then
        self.lastRestockSkip = beacon.id
        sb.logInfo("PETPORT %s NOT restocking %s at %s: this unit cannot reach the request "
          .. "crate, so fetching for it would only cycle stock in and out of storage",
          stationUniqueId(), sb.printJson(beacon.id), sb.printJson(beacon.position))
      end

    else
    for _, request in ipairs(beacon.requests) do
      local have = restockHeld(beacon.id, request.item)

      if have ~= nil and have < request.min then
        --  WANT IS MEASURED AGAINST MAX, NOT MIN. Filling only to min
        --  guarantees the crate is at the fetch threshold the moment the unit
        --  walks away.
        --
        --  This is also what makes min > max a defined state rather than a
        --  loop: want comes out zero or negative, nothing dispatches, and the
        --  crate settles at max. The pane allows that configuration precisely
        --  because this line copes with it.
        local want = request.max - have

        if want > 0 then
          short = short + 1

          --  NETWORK-EXCLUSIVE, WITH NO PORT SUFFIX, unlike deposit and
          --  delivery. Two ports each fetching 500 for a request that wants
          --  500 total overshoots by a full load. The claim releases when the
          --  fetch task reports, so a second port can still slip in while the
          --  first unit walks its stack over -- the same residual race
          --  withdrawWork lives with, and it self-corrects the same way: the
          --  second delivery finds the crate at max, refuses, and the cargo
          --  goes to storage.
          local workId = "restock:" .. tostring(beacon.id)
            .. ":" .. tostring(request.item)

          local failure = self.workFailures[workId]
          local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

          if not backedOff and claimFree(workId) then
            --  SOURCES ARE DEPOSIT BEACONS ONLY. Never another request crate --
            --  that is what stops two quotas trading forever, and it is
            --  structural rather than a rule anything has to enforce.
            --
            --  containerAvailable asks the same question containerConsume will
            --  ask when the unit arrives, which is stronger than reading
            --  containerItems and matching names.
            local source, available = nil, 0

            --  THE SOURCE MUST BE REACHABLE TOO, AND IT IS A SEPARATE QUESTION
            --  FROM THE REQUEST CRATE'S REACHABILITY.
            --
            --  The destination check above stops a unit fetching FOR somewhere
            --  it cannot deliver. This stops the mirror image: fetching FROM
            --  somewhere it cannot collect. Measured with an aquatic unit and a
            --  submerged request crate whose only stock sat in a crate above
            --  the waterline -- the destination check passed, the source was
            --  never asked about, and the unit was dispatched to a withdraw it
            --  could not begin.
            --
            --  KEEP LOOKING RATHER THAN GIVE UP. Sources are iterated, so an
            --  unreachable crate is skipped and the next one considered -- a
            --  network with the same item in a wet crate and a dry one should
            --  serve a swimmer from the wet one rather than refusing the
            --  request outright.
            for _, crate in ipairs(petports_beaconsFor("deposit")) do
              if world.entityExists(crate.id) then
                local n = world.containerAvailable(crate.id,
                  { name = request.item, count = 1 })

                if type(n) == "number" and n >= 1 then
                  if servicePointNear("crate " .. tostring(crate.id),
                     crate.id, crate.position, 4) == nil then
                    if self.lastRestockSourceSkip ~= crate.id then
                      self.lastRestockSourceSkip = crate.id
                      sb.logInfo("PETPORT %s restock source %s at %s SKIPPED: holds %s but "
                        .. "this unit cannot reach it -- looking for another source",
                        stationUniqueId(), sb.printJson(crate.id),
                        sb.printJson(crate.position), tostring(request.item))
                    end
                  else
                    source = crate
                    available = n
                    break
                  end
                end
              end
            end

            if source == nil then
              unstocked = unstocked + 1
            else
              --  ONE STACK PER TRIP, and never more than the crate has.
              --  containerConsume is all-or-nothing on the full count, so
              --  asking for more than is there fails cleanly and takes nothing
              --  -- which would read as a mysteriously idle unit.
              local count = math.min(want, available, stackSizeOf(request.item))

              --  BOTH HALVES BEFORE ANYTHING MOVES, the same rule tidying uses.
              --  Fetching into a full request crate means the unit picks the
              --  stack up, delivery refuses it, deposit puts it back in
              --  storage, and this fetches it again next tick. nil means the
              --  engine will not answer and is treated as YES -- unlike
              --  tidying, because a crate under its own minimum is work someone
              --  explicitly asked for rather than housekeeping.
              local fits = world.containerItemsCanFit ~= nil
                and world.containerItemsCanFit(beacon.id,
                  { name = request.item, count = count }) or nil

              if fits ~= nil and fits <= 0 then
                noRoom = noRoom + 1
              else
                sb.logInfo("PETPORT %s RESTOCK dispatch: %s x%s from %s for crate %s (has %s, wants %s-%s)",
                  stationUniqueId(), tostring(request.item), sb.printJson(count),
                  sb.printJson(source.id), sb.printJson(beacon.id),
                  sb.printJson(have), sb.printJson(request.min),
                  sb.printJson(request.max))

                return {
                  id = workId,
                  --  The footprint ladder ran on this target above -- see arch.dispatch.vouch.
                  mediumVerified = true,
                  type = "withdraw",
                  port = stationUniqueId(),
                  target = source.id,

                  --  `seed` is what withdrawSeed reads. The name is a fossil of
                  --  the replanting work it was written for; the function has
                  --  been general since watering started using it for liquid.
                  seed = request.item,
                  count = count,

                  --  Raw container position, matching withdrawWork and
                  --  withdrawWaterWork. The unit resolves a standing point
                  --  itself for this task type; deposit-shaped tasks are the
                  --  ones that arrive pre-resolved.
                  position = world.entityPosition(source.id)
                }
              end
            end
          end
        end
      end
    end
    end
  end

  if short == 0 then
    return nil, "every restock request is at or above its minimum"
  end

  --  unreachable is reported alongside the others because "N short, none
  --  actionable" reads as a stock problem, and a crate this chassis simply
  --  cannot get to is a completely different thing to go and look at.
  return nil, string.format(
    "%s restock request(s) short, none actionable: %s with none in storage, "
    .. "%s with the request crate full, %s with an unreachable request crate",
    short, unstocked, noRoom, unreachable)
end

--  Every crate the network can act on, both kinds, in a stable order.
--
--  Deposit beacons and configured restock beacons. Shared by tidyWork, which
--  wants misfits out of both, and compactWork, which wants split stacks merged
--  in both.
--
--  DEFINED ABOVE ITS FIRST CALLER, and that is not incidental. A `local
--  function` called from earlier in the file resolves as a nil GLOBAL and
--  throws at the call -- the trap that hid in freshPather for months. It was
--  also deleted outright once, by a block rewrite of the restock generators
--  that ran up to the header below; the two call sites survived and nothing in
--  a syntax check noticed. Grep for callers after moving anything near here.
local function tidySources()
  local sources = {}

  for _, beacon in ipairs(petports_beaconsFor("deposit")) do
    table.insert(sources, beacon)
  end

  for _, beacon in ipairs(petports_beaconsFor("restock")) do
    if beacon.requests ~= nil then
      table.insert(sources, beacon)
    end
  end

  return sources
end

--  DEFRAGMENT STORAGE. Eviction, and therefore disperse.
--
--  A crate's filter says what belongs in it. Anything else in there is a
--  misfit, and moving misfits to where they belong is the whole feature.
--  petports_filterMisfits owns the question; this owns the dispatching.
--
--  DISPERSE IS NOT A SECOND MECHANISM. A dropbox is a deposit beacon whose
--  filter accepts nothing -- base "deny", no allow rules -- so every stack in
--  it is a misfit and the whole crate empties outward by tag. No second beacon
--  type, no second work generator, and a dropbox can never be its own
--  destination because its own filter rejects everything.
--
--  A MISFIT WITH NOWHERE TO GO STAYS PUT. Both halves are checked before
--  anything moves: some other beacon's filter must ACCEPT the stack, and that
--  crate must have ROOM for it.
--
--  The room half is the player's call, and it is about not wasting their unit.
--  Tidying a stack into a full network means the unit picks it up, depositWork
--  finds no target, and the cargo guard in findWork then blocks collection,
--  harvest, animals and fetching outright -- one misfiled stack takes a unit
--  out of the working pool and stalls everything it would have done. Someone
--  mid-reorganisation of their base should not have to think about that. So
--  full storage simply postpones defragmenting until there is space.
--
--  It is also the deadlock withdrawWork's header describes having already been
--  bitten by, arrived at from the other direction.
--
--  LOWEST PRIORITY, below collection and harvest. A drop on the ground is on a
--  despawn timer; a misfiled stack is in a box and will be exactly as misfiled
--  in a minute.
--
--  SELF-LIMITING. One stack per trip is the standing design, so a crate with
--  forty misfits produces forty sequential trips rather than forty tasks.
local function tidyWork()
  --  DESTINATIONS ARE DEPOSIT BEACONS. A misfit always goes to ordinary
  --  storage, never straight into another request crate -- restockFetchWork is
  --  the only thing that fills those, and giving eviction a second route into
  --  them would mean two mechanisms racing over one quota.
  local destinations = petports_beaconsFor("deposit")

  if #destinations == 0 then
    return nil, "no deposit beacon to tidy into"
  end

  --  SOURCES ARE BOTH KINDS.
  --
  --  A deposit crate's filter says what belongs in it. A request crate's quota
  --  says the same thing in a different language: one item, up to max. Both
  --  answer "what is in here that should not be", and tidyWork does not care
  --  which produced its list because both return { slot, name, count }.
  --
  --  This is the part of restocking that did NOT come for free. The handoff's
  --  requester design says overstock costs no new code because tidyWork would
  --  already see it -- true while restock was a MODE on the deposit beacon, and
  --  false the moment it became its own behaviour, because everything here
  --  iterated petports_beaconsFor("deposit") and a request crate is not in that
  --  list.
  local sources = tidySources()

  --  Counted so the no-work reason can tell "nothing is misfiled" from
  --  "plenty is misfiled and storage is full", which are very different
  --  states and look identical from a silent port.
  local misfiled, homeless, full = 0, 0, 0

  for _, source in ipairs(sources) do
    if world.entityExists(source.id) then
      local items = world.containerItems(source.id)

      if type(items) == "table" then
        local misfits

        if source.behavior == "restock" then
          misfits = petports_restockMisfits(source.requests, items,
            source.beaconSlot)
        else
          misfits = petports_filterMisfits(source.filter, items,
            source.beaconSlot)
        end

        for _, misfit in ipairs(misfits) do
          misfiled = misfiled + 1

          --  EXCLUSIVE ACROSS PORTS -- NO PORT SUFFIX.
          --
          --  This carried "@" .. stationUniqueId() and was the last take-shaped
          --  generator that did. A deposit claim is keyed per port on purpose,
          --  because several units genuinely CAN share one crate:
          --  containerAddItems gives every arrival a truthful answer and there
          --  is nothing to serialise. A TAKE is the opposite -- one misfiled
          --  stack, one unit -- so a per-port key sent every port after the same
          --  stack and all but the first arrived to find it gone, took a
          --  ten-second backoff, and had burned a trip for nothing.
          --
          --  MEASURED ON THE SAME SHAPE ELSEWHERE: three ports each dispatched a
          --  unit across the base for the same three Pet Treats, and two of them
          --  logged "took nothing: slot 1 now holds null". restock, compact,
          --  drain and fuel already key this way; tidy was the outlier.
          --
          --  ONCE UNITS RUN ON FUEL THIS STOPS BEING MERELY WASTEFUL. A
          --  redundant dispatch will cost treats to accomplish nothing, so the
          --  network would be paying to idle.
          --
          --  WHAT TO WATCH: tidy is by far the busiest take-shaped generator, so
          --  this is where the deposit comment's warning could plausibly bite --
          --  refused ports falling back to station-keeping and sliding back and
          --  forth. They should fall through to compactWork and drainWork
          --  instead. That is reasoning, not measurement.
          local workId = "tidy:" .. tostring(source.id)
            .. ":" .. tostring(misfit.name)

          local failure = self.workFailures[workId]
          local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

          if not backedOff and claimFree(workId) then
            --  The full descriptor, not just the name: containerItemsCanFit
            --  runs the real merge rules and parameters decide whether a stack
            --  tops up an existing one or needs a free slot.
            local stack = items[misfit.slot]
            local accepted, roomFor = false, false

            for _, destination in ipairs(destinations) do
              if destination.id ~= source.id
                 and world.entityExists(destination.id)
                 and petports_filterAccepts(destination.filter, misfit.name) then
                accepted = true

                --  nil means the engine will not answer. Treated as NO here,
                --  deliberately: this is optional housekeeping, and guessing
                --  wrong costs a unit out of the pool. Deposit falls back to a
                --  backoff because it has cargo it must place; tidying has the
                --  luxury of simply waiting.
                local fits = world.containerItemsCanFit ~= nil
                  and world.containerItemsCanFit(destination.id, stack) or nil

                if fits ~= nil and fits > 0 then
                  roomFor = true
                  break
                end
              end
            end

            if not accepted then
              homeless = homeless + 1
            elseif not roomFor then
              full = full + 1
            else
              local stand, standWhy = servicePointNear("crate " .. tostring(source.id),
                source.id, source.position, 4)

              if stand == nil then
                sb.logInfo("PETPORT %s tidy source %s SKIPPED: %s of %s",
                  stationUniqueId(), sb.printJson(source.id), tostring(standWhy),
                  sb.printJson(source.position))
              else
                sb.logInfo("PETPORT %s tidying %s x%s out of %s (slot %s)",
                  stationUniqueId(), tostring(misfit.name),
                  sb.printJson(misfit.count), sb.printJson(source.id),
                  sb.printJson(misfit.slot))

                return {
                  id = workId,
                  --  The footprint ladder ran on this target above -- see arch.dispatch.vouch.
                  mediumVerified = true,
                  type = "tidy",
                  target = source.id,
                  item = misfit.name,
                  count = misfit.count,
                  slot = misfit.slot,
                  position = stand,
                  containerPosition = source.position,
                  port = stationUniqueId(),
                  dwell = 0
                }
              end
            end
          end
        end
      end
    end
  end

  if misfiled == 0 then
    return nil, "nothing misfiled in coverage"
  end

  return nil, string.format(
    "%s misfiled stack(s), none actionable: %s with no crate that wants them, "
    .. "%s with the right crate full",
    misfiled, homeless, full)
end

--  ---------------------------------------------------------------------------
--  DRAIN: PULL EXISTING OVER-QUOTA STOCK OUT TO A MACHINE
--  ---------------------------------------------------------------------------
--
--  Routing alone only CAPS GROWTH. It diverts cargo that happens to be in
--  transit, so a network already holding nine thousand dirt above its threshold
--  sits at nine thousand forever -- nothing ever picks it back up. This is the
--  half that actually reduces the pile, and it is the reason the feature exists
--  at all: entropy that has already accumulated is the problem, not entropy
--  arriving.
--
--  THE VERY BOTTOM OF findWork, BELOW COMPACTION.
--
--  This is the only work in the mod that is irreversible. A unit should do
--  literally anything else first -- collect a despawning drop, water a crop,
--  fill a request, tidy a shelf, merge two stacks -- and reach for this only
--  when the network has nothing else to offer. Nothing here is urgent: the
--  surplus has been sitting there and will keep.
--
--  IT MANUFACTURES CARGO, then hands off. The withdraw puts the stack on the
--  unit and stops; the next findWork sees cargo, depositWork runs, and
--  upcyclerWork routes it to the machine exactly as it routes a fresh pickup.
--  One path to the machine, not two.
--
--  WHICH IS ALSO THE LIVELOCK RISK, and why the count is capped three ways
--  below. If a drained stack cannot be delivered it goes back into ordinary
--  storage, and an ungated drain would pull it straight out again -- the same
--  fetch-deposit-fetch loop replantWork's header records, where every
--  individual task succeeds and nothing in the log looks wrong.
local function drainWork()
  --  ONLY WITH EMPTY HANDS. A unit already carrying something has a delivery to
  --  finish, and depositWork above will route that load on its own.
  if self.petData == nil then return nil end
  if self.petData.cargo ~= nil and #self.petData.cargo > 0 then return nil end

  local sources = petports_beaconsFor("deposit")
  if #sources == 0 then return nil, "no deposit beacon to drain from" end

  local overQuota = 0
  local dribbled = 0

  --  EMPTIEST MACHINE FIRST.
  --
  --  Iterating self.machines in scan order meant whichever machine the query
  --  happened to return first was fed forever while the rest starved --
  --  measured, and it looks exactly like a unit that has adopted one machine as
  --  a pet. Sorting by input room makes the choice self-balancing: a machine
  --  that was just fed sinks to the bottom and rises again as it burns through
  --  what it was given, with no round-robin state to keep.
  --  SCORED ONCE, THEN SORTED. A comparator that calls into the engine is both
  --  wasteful -- table.sort evaluates it O(n log n) times -- and unstable, since
  --  a machine that consumes mid-sort can make the comparison contradict itself
  --  and Lua's sort will happily error on an invalid order function.
  local ranked = {}

  for _, machine in ipairs(self.machines or {}) do
    if machine.kind == "upcycler" and machine.enabled
       and world.entityExists(machine.id) then

      --  THE DESTINATION MUST BE REACHABLE BEFORE ITS SUPPLY IS WORTH FETCHING.
      --
      --  This checked the SOURCE CRATE and never the machine, so a unit could
      --  be sent to pull stock for somewhere it could not go. That is not a
      --  wasted trip, it is a LIVELOCK, and it is invisible because every task
      --  in it succeeds:
      --
      --    drain dirtmaterial out of crate 31 for upcycler 13   done
      --    deposit -> upcyclerWork refuses 13, unreachable      done, back in 31
      --    census sees dirtmaterial over threshold again        drain again
      --
      --  MEASURED at 2.4 full cycles per second against a submerged upcycler,
      --  with a "done" on every line and nothing resembling an error anywhere
      --  in the log. Same shape as the withdraw/deposit loop recorded above
      --  replantWork, and the same reason it was hard to see.
      --
      --  IT WAS ALWAYS BROKEN. Before petports_avoidLiquid landed, the unit
      --  accepted the unreachable machine and stood still for ten seconds per
      --  attempt, so the loop ran slowly enough to look like ordinary retrying.
      --  Making the refusal correct is what turned it into a fast loop and made
      --  it visible.
      --
      --  standingPointNear ASKS THE UNIT, so this is per-chassis by
      --  construction: a submerged machine is unreachable for a walker and fine
      --  for a swimmer, and neither has to be special-cased here.
      local reachable = servicePointNear("upcycler " .. tostring(machine.id),
        machine.id, machine.position, 4)

      if reachable == nil then
        if self.lastDrainSkip ~= machine.id then
          self.lastDrainSkip = machine.id
          sb.logInfo("PETPORT %s NOT draining for %s at %s: this unit cannot reach the "
            .. "machine, so fetching its input would only cycle stock in and out of storage",
            stationUniqueId(), sb.printJson(machine.id), sb.printJson(machine.position))
        end
      else
        table.insert(ranked, {
          machine = machine,
          free = machineInputFree(machine.id)
        })
      end
    end
  end

  table.sort(ranked, function(a, b) return a.free > b.free end)

  for _, entry in ipairs(ranked) do
    local machine = entry.machine

    do

      for _, rule in ipairs(machine.rules) do
        local held = (self.census or {})[rule.item] or 0
        local surplus = held - rule.max

        if surplus > 0 then
          overQuota = overQuota + 1

          --  CAP ONE: the surplus itself, so a drain can never take the network
          --  below the threshold the player set. This is what makes "keep at
          --  most N" mean N rather than "somewhere near N".
          --
          --  CAP TWO: the room the rule's checkboxes actually offer, so the
          --  unit is never sent to fetch something the machine cannot accept
          --  when it arrives. machineRuleRoom, the same predicate dispatch and
          --  arrival use -- a burn-denied reagent still gets fetched for its
          --  reagent slot, and a both-denied rule fetches nothing.
          local room = machineRuleRoom(machine, rule,
            { name = rule.item, count = 1 })

          --  CAP THREE, AND THE ONE THAT STOPS THE DRIBBLE: a trip has to be
          --  worth taking. Without this the drain sizes itself to whatever the
          --  machine burned during the last walk -- measured at ~23 items a
          --  round trip -- and one unit spends its whole life shuttling
          --  handfuls to a machine that is already nearly full.
          --
          --  Capped by the surplus so a nearly-finished job still completes:
          --  30 items over threshold delivers 30 rather than waiting forever
          --  for a batch that cannot exist.
          local batch = math.min(
            math.ceil(stackSizeOf(rule.item) * MACHINE_MIN_BATCH), surplus)

          if room < batch then
            dribbled = dribbled + 1
            room = 0
          end

          if room > 0 then
            for _, source in ipairs(sources) do
              if world.entityExists(source.id) then
                local ok, items = pcall(world.containerItems, source.id)

                if ok and type(items) == "table" then
                  for slot, stack in pairs(items) do
                    --  THE DECIDING BEACON IS NOT STOCK, the same exemption the
                    --  census and filterMisfits both make.
                    if slot ~= source.beaconSlot
                       and type(stack) == "table"
                       and stack.name == rule.item then

                      --  CAP THREE: what is actually in the slot. Slot-precise
                      --  from end to end, so parameters survive and a partial
                      --  take comes off the slot the port actually looked at.
                      --
                      --  CAP FOUR: THIS STACK'S OWN DESCRIPTOR-TRUE ROOM. The
                      --  aggregate `room` above was estimated from the bare
                      --  name -- the only thing drain knows before it reads a
                      --  crate -- but THIS stack has real parameters, and a
                      --  slot of differently-rotted milk offers it nothing
                      --  however much the name math sees. Asking again with
                      --  the real stack is what stops drain fetching a load
                      --  the machine will refuse and depositWork will file
                      --  straight back -- the fetch-and-return loop.
                      local count = math.min(surplus, stack.count or 0, room,
                        machineRuleRoom(machine, rule, stack))

                      if count > 0 then
                        --  EXCLUSIVE ACROSS PORTS -- NO PORT SUFFIX.
                        --
                        --  A deposit claim carries "@" .. stationUniqueId()
                        --  because several units CAN share one crate:
                        --  containerAddItems gives each arrival a truthful
                        --  answer and there is nothing to serialise. A TAKE is
                        --  the opposite -- the supply is finite, so the first
                        --  unit gets it and every other unit walks there for
                        --  nothing and eats a backoff.
                        --
                        --  restockFetchWork and compactWork already key this
                        --  way; drain and fuel were the two that did not, and
                        --  it showed immediately on a three-port network.
                        local workId = "drain:" .. tostring(machine.id)
                          .. ":" .. tostring(rule.item)

                        local failure = self.workFailures[workId]
                        local backedOff = failure ~= nil
                          and (failure["until"] or 0) > world.time()

                        if not backedOff and claimFree(workId) then
                          local stand, standWhy = servicePointNear("crate " .. tostring(source.id),
                            source.id, source.position, 4)

                          if stand == nil then
                            sb.logInfo("PETPORT %s drain source %s SKIPPED: %s of %s",
                              stationUniqueId(), sb.printJson(source.id), tostring(standWhy),
                              sb.printJson(source.position))
                          else
                            sb.logInfo("PETPORT %s draining %s x%s out of %s (slot %s) for %s at %s -- network holds %s, threshold %s, machine input room %s",
                              stationUniqueId(), tostring(rule.item),
                              sb.printJson(count), sb.printJson(source.id),
                              sb.printJson(slot), tostring(machine.kind),
                              sb.printJson(machine.position), sb.printJson(held),
                              sb.printJson(rule.max), sb.printJson(room))

                            return {
                              id = workId,

                              --  A TYPE petportsTaskAction HAS NEVER HEARD OF,
                              --  which is how tidy and compact already work:
                              --  dispatch falls through to the generic
                              --  walk-and-stand path and the port does the
                              --  container work on arrival.
                              --
                              --  Its own type rather than reusing "tidy" so the
                              --  log can tell housekeeping from feeding a
                              --  machine, which are very different things to
                              --  find a unit doing.
                              --  The footprint ladder ran on this target above -- see arch.dispatch.vouch.
                              mediumVerified = true,
                              type = "drain",
                              target = source.id,
                              item = rule.item,
                              count = count,
                              slot = slot,
                              position = stand,
                              containerPosition = source.position,
                              port = stationUniqueId(),
                              dwell = 0
                            }
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  if overQuota == 0 then
    return nil, "nothing over an upcycler threshold"
  end

  if dribbled > 0 then
    return nil, string.format(
      "%s rule(s) over threshold, %s waiting for a machine to burn through "
      .. "enough input to be worth a trip", overQuota, dribbled)
  end

  return nil, string.format(
    "%s rule(s) over threshold, none actionable: no deposit crate holds the "
    .. "item, or every machine input is full", overQuota)
end

--  ---------------------------------------------------------------------------
--  FUEL: TAKE FINISHED TREATS OUT OF A MACHINE
--  ---------------------------------------------------------------------------
--
--  ONLY IF STORAGE ACTUALLY WANTS THEM. A machine whose output nobody has asked
--  for keeps its treats, fills its output slot, and stops -- which is a
--  deliberate throttle rather than a jam. It hands the player control over how
--  fast upcycling runs: filter fuel into a crate and the machine runs
--  continuously; do not, and it converts one slot's worth and waits.
--
--  SLOT ONE, AND ONLY petports_petfuel.
--
--  NOT "whatever is in the output". The player can drag anything into any slot
--  by hand, and a stack of ore parked there being hauled off to storage by a
--  machine they thought was idle is exactly the sort of thing that is
--  impossible to diagnose after the fact.
--  AN OFFSET, ZERO-BASED, like every other MACHINE_SLOT_ constant and like
--  every world.container*At call that takes one.
--
--  The keys world.containerItems hands back are ONE-based, and withdrawMisfit
--  takes a KEY. Anything crossing from this constant into that world has to
--  convert -- see the `slot` field on the fuel task, which is the one place it
--  happens and the one place it was once wrong.
--
--  2, NOT 1. The upcycler's slots are input 0, reagent 1, output 2 -- reordered
--  so its pane can put input and reagent in one two-cell grid and place the
--  output freely. This constant is a second copy of that layout with nothing
--  linking it to the first; if SLOT_OUTPUT moves in petports_upcycler.lua this
--  has to move with it, and the failure is a unit hauling off whatever is in
--  the reagent slot.
MACHINE_SLOT_OUTPUT = 2
MACHINE_FUEL_ITEM = "petports_petfuel"

--  ANY TREAT, NOT JUST THE PLAIN ONE.
--
--  The output slot used to be tested with `held.name == MACHINE_FUEL_ITEM`,
--  which stopped being true the moment flavored treats existed. A machine whose
--  output held spicy treats was not counted as holding fuel AT ALL, so it was
--  never collected and never even reported -- not a deadlock, just invisible.
--
--  The tag is the right test because it is the same one the deposit filter's
--  Pet Treats group matches on, so "the port thinks this is fuel" and "a crate
--  will accept it as fuel" cannot drift apart. It also picks up a modded
--  flavor's treat with no further work.
MACHINE_FUEL_TAG = "petports_fuel"

--  Cached because root.itemConfig re-runs an item's build script, and this is
--  asked once per machine per work tick. An item's tags cannot change at
--  runtime, so one answer per name lasts the session.
local fuelItemCache = {}

local function isFuelItem(name)
  if type(name) ~= "string" then return false end
  if fuelItemCache[name] ~= nil then return fuelItemCache[name] end

  local verdict = false
  local ok, resolved = pcall(root.itemConfig, { name = name, count = 1 })

  if ok and type(resolved) == "table" and type(resolved.config) == "table" then
    for _, tag in ipairs(resolved.config.itemTags or {}) do
      if tag == MACHINE_FUEL_TAG then verdict = true break end
    end
  end

  fuelItemCache[name] = verdict
  return verdict
end

local function fuelWork()
  if self.petData == nil then return nil end
  if self.petData.cargo ~= nil and #self.petData.cargo > 0 then return nil end

  local destinations = petports_beaconsFor("deposit")
  if #destinations == 0 then return nil, "no deposit beacon to store fuel in" end

  local waiting = 0
  local trickling = 0

  --  What was in the output slots nobody would take, for the message at the
  --  bottom. Deduplicated because two machines making spicy treats is one
  --  filter problem, not two.
  local refusedNames = {}
  local refusedSeen = {}

  for _, machine in ipairs(self.machines or {}) do
    if machine.kind == "upcycler" and world.entityExists(machine.id) then
      --  DELIBERATELY NOT GATED ON `enabled`. A machine switched off with
      --  finished treats still in it should be emptied -- the treats are made,
      --  and stranding them because the player paused conversion would be
      --  surprising.
      local ok, held = pcall(world.containerItemAt, machine.id, MACHINE_SLOT_OUTPUT)

      --  NOT GATED ON isFuelItem ANY MORE. Anything in the output slot is
      --  collectable, treat or not.
      --
      --  A NON-TREAT PARKED HERE STOPS THE MACHINE DEAD. emitFuel peeks rather
      --  than takes, so it refuses to place and banks points instead -- a
      --  correctly configured machine producing nothing, with no rule to
      --  change and nothing in the world that fixes it. It could only ever be
      --  cleared by hand, which is the opposite of what this mod is for.
      --
      --  THE DELIVERY END NEEDED NOTHING. Destinations are matched with
      --  petports_filterAccepts against the item ACTUALLY held, and "deposit"
      --  is the general storage set that tidy and sort already use, so junk
      --  routes by the same filter rules as anything else a unit carries. The
      --  work stays type "fuel" because withdrawMisfit is what consumes it and
      --  that is a take-from-a-slot, not a treat-specific errand.
      if ok and type(held) == "table" and type(held.name) == "string"
         and (held.count or 0) > 0 then
        local isFuel = isFuelItem(held.name)

        waiting = waiting + 1

        --  IS IT WORTH THE WALK YET?
        --
        --  Measured: three ports each dispatched a unit across the base for
        --  THREE treats, and two of them arrived at an empty slot and took a
        --  ten-second backoff. Treats accumulate one per thousand points, so
        --  without a floor the first one made triggers a full round trip.
        --
        --  TWO EXCEPTIONS, both meaning "no more are coming, take what is
        --  there": a full output slot has stopped the machine outright, and an
        --  empty input means it has nothing left to convert. Without those a
        --  small job would leave its last handful stranded forever.
        --  NO `goto` -- Starbound is Lua 5.1 and it is a 5.2 keyword. A
        --  positive condition wrapping the loop does the same job.
        --  Sized against the item ACTUALLY held, not the plain treat. They share
        --  a maxStack today and there is no reason a modded flavor must.
        local batch = math.ceil(stackSizeOf(held.name) * MACHINE_MIN_BATCH)
        local full = (held.count or 0) >= stackSizeOf(held.name)

        local okInput, input = pcall(world.containerItemAt, machine.id,
          MACHINE_SLOT_INPUT)
        local inputEmpty = not okInput or type(input) ~= "table" or input.name == nil

        --  AN EMPTY BURNER STOPPED MEANING A DRY MACHINE when the shuttle
        --  landed. The shuttle feeds the burner ONE item at a time and only
        --  into an EMPTY slot, so a machine working through reagent-slot stock
        --  is empty-burnered most of the time BY DESIGN -- and reading that as
        --  "nothing left to convert" harvested every single treat the moment
        --  it was made, one round trip each. Observed exactly that.
        --
        --  So: empty input counts as idle only when the reagent slot offers no
        --  shuttle-eligible supply -- an item its rule lets into the burner
        --  (both boxes, the shuttle's own feed condition). The exempt check
        --  the shuttle also runs is deliberately not mirrored here: the tag
        --  lives on item config the port has no reader for, and the miss is
        --  conservative -- treats wait for the batch floor instead of
        --  single-tripping, and the full and stalled exceptions still release.
        local feeding = false

        if inputEmpty then
          local okReagent, reagent = pcall(world.containerItemAt, machine.id,
            MACHINE_SLOT_REAGENT)

          if okReagent and type(reagent) == "table" and reagent.name ~= nil then
            for _, rule in ipairs(machine.rules) do
              if rule.item == reagent.name and rule.burn ~= false
                 and rule.reagent ~= false then
                feeding = true
                break
              end
            end
          end
        end

        local idle = inputEmpty and not feeding

        --  THE THIRD "NO MORE ARE COMING" CASE, and the one flavored treats
        --  introduced: the machine has a treat banked that WILL NOT STACK with
        --  what is in the slot. Not full, not idle, under the batch floor, and
        --  stuck forever -- see BLOCKED_KEY in petports_upcycler.lua.
        --
        --  Read from a parameter rather than inferred, because working it out
        --  here would mean knowing which flavor is queued next. Absent reads as
        --  false, which is the pre-flavor behaviour.
        local okBlocked, blocked = pcall(world.getObjectParameter, machine.id,
          "petports_upcyclerBlocked")

        local stalled = okBlocked and blocked == true

        --  JUNK SKIPS THE BATCH FLOOR ENTIRELY.
        --
        --  The floor exists because treats ACCUMULATE -- one per thousand
        --  points -- so collecting the first one made costs a round trip for
        --  three items. None of that applies to a single misplaced item: no
        --  more are coming, it will never reach a batch, and every second it
        --  sits there the machine is stopped. Waiting for a floor it cannot
        --  reach is the stranding this change exists to remove.
        local worthTaking = not isFuel
          or (held.count or 0) >= batch or full or idle or stalled

        if worthTaking and not refusedSeen[held.name] then
          refusedSeen[held.name] = true
          table.insert(refusedNames, held.name)
        end

        if not worthTaking then trickling = trickling + 1 end

        for _, destination in ipairs(worthTaking and destinations or {}) do
          if world.entityExists(destination.id)
             --  THE ITEM ACTUALLY HELD. Flavors sort into separate subgroups,
             --  so a crate that accepts plain treats may refuse spicy ones --
             --  testing the plain name would send a unit to a crate that will
             --  not take what it is carrying.
             and petports_filterAccepts(destination.filter, held.name) then

            --  nil means the engine will not answer, treated as NO. Same
            --  reasoning as tidyWork: this is optional, and guessing wrong
            --  costs a unit out of the pool for a round trip.
            local fits = world.containerItemsCanFit ~= nil
              and world.containerItemsCanFit(destination.id, held) or nil

            if fits ~= nil and fits > 0 then
              --  EXCLUSIVE ACROSS PORTS. See the drain claim above: a take has
              --  a finite supply, so a per-port claim sends every port's unit
              --  after the same three items.
              local workId = "fuel:" .. tostring(machine.id)

              local failure = self.workFailures[workId]
              local backedOff = failure ~= nil
                and (failure["until"] or 0) > world.time()

              if not backedOff and claimFree(workId) then
                local stand, standWhy = servicePointNear("machine " .. tostring(machine.id),
                  machine.id, machine.position, 4)

                if stand == nil then
                  sb.logInfo("PETPORT %s fuel source %s SKIPPED: %s of %s",
                    stationUniqueId(), sb.printJson(machine.id), tostring(standWhy),
                    sb.printJson(machine.position))
                else
                  sb.logInfo("PETPORT %s collecting %s %s from machine %s",
                    stationUniqueId(), sb.printJson(held.count),
                    tostring(held.name), sb.printJson(machine.id))

                  return {
                    id = workId,
                    --  The footprint ladder ran on this target above -- see arch.dispatch.vouch.
                    mediumVerified = true,
                    type = "fuel",
                    target = machine.id,
                    item = held.name,
                    count = held.count,

                    --  A KEY, NOT AN OFFSET, AND THE DIFFERENCE IS THE WHOLE
                    --  BUG THIS LINE ONCE HAD.
                    --
                    --  This task is read with an OFFSET-taking call --
                    --  world.containerItemAt(id, MACHINE_SLOT_OUTPUT) -- and
                    --  consumed by withdrawMisfit, which takes a one-based KEY
                    --  and applies SLOT_KEY_TO_OFFSET itself. Handing it the
                    --  raw offset sent the take to slot 0, the INPUT, which on
                    --  an idle machine is empty:
                    --
                    --    collecting 3 petports_petfuel from machine 1
                    --    tidy of petports_petfuel from 1 took nothing:
                    --      slot 1 now holds null, not petports_petfuel
                    --
                    --  and the unit walked back and forth forever, dispatched
                    --  by a correct read and defeated by an incorrect take.
                    --
                    --  Subtracting SLOT_KEY_TO_OFFSET rather than adding a
                    --  literal 1, so this stays correct if the bias is ever
                    --  found to differ.
                    slot = MACHINE_SLOT_OUTPUT - SLOT_KEY_TO_OFFSET,
                    position = stand,
                    containerPosition = machine.position,
                    port = stationUniqueId(),
                    dwell = 0
                  }
                end
              end
            end
          end
        end
      end
    end
  end

  if waiting == 0 then
    return nil, "no machine has anything in its output slot"
  end

  if trickling > 0 then
    return nil, string.format(
      "%s machine(s) with output, %s still converting and not yet worth a trip",
      waiting, trickling)
  end

  --  Names what was actually refused rather than the plain treat. With flavors
  --  the two differ, and "no crate accepts petports_petfuel" while the machine
  --  holds spicy ones sends a reader looking at the wrong filter.
  return nil, string.format(
    "%s machine(s) with output, but no deposit crate accepts %s or has room",
    waiting, table.concat(refusedNames, ", "))
end

--  MERGE SPLIT STACKS IN A CRATE NOTHING ELSE IS VISITING.
--
--  Every port-side container mutation already compacts what it touched, so this
--  exists for the fragmentation nobody here caused: a player emptying half a
--  stack into a chest by hand, a crate that predates the network, a mod
--  changing a maxStack under a save.
--
--  BELOW EVEN TIDYING, which is saying something. A misfiled stack is in the
--  wrong box; a split stack is in the right box in the wrong shape. Nothing is
--  lost, no timer is running, and the crate works perfectly well as it is.
--
--  ONE CRATE PER TRIP, and compactContainer merges every fragmented item in it
--  on arrival -- so a badly fragmented crate is one walk, not one walk per
--  item.
local function compactWork()
  for _, source in ipairs(tidySources()) do
    if world.entityExists(source.id) then
      local ok, items = pcall(world.containerItems, source.id)

      if ok and type(items) == "table" then
        local split = fragmentation(items)

        if #split > 0 then
          --  NETWORK-EXCLUSIVE, no port suffix. Two units walking to the same
          --  crate to merge the same stacks is pure waste, and unlike deposit
          --  there is nothing for the second one to usefully do when it
          --  arrives.
          local workId = "compact:" .. tostring(source.id)

          local failure = self.workFailures[workId]
          local backedOff = failure ~= nil and (failure["until"] or 0) > world.time()

          if not backedOff and claimFree(workId) then
            local stand, standWhy = servicePointNear("crate " .. tostring(source.id),
              source.id, source.position, 4)

            if stand == nil then
              sb.logInfo("PETPORT %s compaction of %s SKIPPED: %s of %s",
                stationUniqueId(), sb.printJson(source.id), tostring(standWhy),
                sb.printJson(source.position))
            else
              sb.logInfo("PETPORT %s compacting %s: %s item(s) split across more slots than needed",
                stationUniqueId(), sb.printJson(source.id), sb.printJson(#split))

              return {
                id = workId,

                --  A TYPE petportsTaskAction HAS NEVER HEARD OF, which is
                --  fine and is how "tidy" already works: its dispatch falls
                --  through to the generic walk-and-stand path. The port does
                --  the container work when the arrival is reported.
                --  The footprint ladder ran on this target above -- see arch.dispatch.vouch.
                mediumVerified = true,
                type = "compact",
                target = source.id,
                position = stand,
                containerPosition = source.position,
                port = stationUniqueId(),
                dwell = 0
              }
            end
          end
        end
      end
    end
  end

  return nil, "no crate has stacks worth merging"
end

local function findWork()
  --  PARTICIPATION, READ ONCE. Four config reads rather than fourteen, and
  --  every branch below reasons about the same snapshot -- a set that changed
  --  halfway down this function would be a job dispatched under one policy and
  --  rejected under another.
  --
  --  THESE GATE THE CALL, NOT THE RESULT. A generator that is not going to be
  --  dispatched should not be run: several scan containers or the world, and
  --  paying for that to discard the answer is the kind of cost that only shows
  --  up on a large base.
  --  OBLIVIOUS TAKES THE UNIT OFF THE ROSTER WITHOUT TOUCHING THE CHECKBOXES.
  --
  --  It ZEROES THE FOUR GROUPS HERE rather than inside petportParticipates,
  --  deliberately. Those config values are the PLAYER'S setting and the pane
  --  mirrors them; rewriting them would make the pane lie about what the player
  --  chose, and pulling the module would then have to restore something. The
  --  module suppresses the dispatch, not the preference.
  --
  --  RECALL AND DEPOSIT SURVIVE IT, BY CONSTRUCTION RATHER THAN BY EXCEPTION.
  --  returnWork is ungated because it is the leash -- a unit that cannot be
  --  recalled wanders out of coverage and stays there -- and depositWork is
  --  ungated because putting down what you are already holding is finishing, not
  --  starting. So a unit that goes oblivious mid-haul places its cargo and walks
  --  home, rather than standing in a field holding a stack forever.
  --
  --  THAT IS ALSO WHY THIS IS NOT petportEnabled. Unticking the port closes the
  --  door and despawns; this leaves the unit deployed, visible and idle, which
  --  is the whole point of the module.
  local oblivious = petportOblivious()

  local doHauling = not oblivious and petportParticipates("hauling")
  local doSorting = not oblivious and petportParticipates("sorting")
  --  FARMING SPLITS INTO FOUR, GATED BY THE MODULE RATHER THAN BY THE PORT.
  local farming = not oblivious and petportFarming()

  local doHarvest = farming and petportFarmingDoes("harvest")
  local doWater = farming and petportFarmingDoes("water")
  local doReplant = farming and petportFarmingDoes("replant")
  local doAnimals = farming and petportFarmingDoes("animals")
  local doMachines = not oblivious and petportParticipates("machines")

  --  Before anything else: a unit that has strayed cannot reach work anyway.
  --
  --  UNGATED, AND IT MUST STAY UNGATED. This is the leash. A unit that cannot
  --  be recalled wanders out of coverage and stays there.
  local recall = returnWork()
  if dispatchable(recall) ~= nil then return recall end

  --  MEDIC SITS DIRECTLY BELOW RECALL AND ABOVE EVERYTHING ELSE.
  --
  --  BELOW RECALL because a stranded unit cannot reach a patient either, and the
  --  leash has to stay the first thing tested.
  --
  --  ABOVE CARGO, WHICH IS A DEPARTURE. Every other task defers to a unit
  --  holding a load, on the reasoning that hoarding is worse than fetching. A
  --  wounded ally outranks a stack of ore: the crop will still be dry in thirty
  --  seconds and the patient may not be there. This is the only place in the
  --  ladder where urgency beats tidiness.
  --
  --  IT GATES ITSELF. There is no participation group for medic -- the module is
  --  the switch -- so unlike the four below, this is not wrapped in a flag. It
  --  returns nil immediately when no medic module is socketed.
  local dose, noDose = medicWork()
  if dispatchable(dose) ~= nil then return dose end

  --  SAID OUT LOUD, CHANGE-GATED. The first build of this returned nil for
  --  three different reasons and logged none of them, so a medic that could
  --  never fetch a dose was indistinguishable from a medic with nothing to do.
  --  Gated on the reason CHANGING so a port with no patients does not print a
  --  line every scan forever.
  if noDose ~= nil and noDose ~= self.medicReason then
    self.medicReason = noDose
    sb.logInfo("PETPORT %s medic idle: %s", stationUniqueId(), tostring(noDose))
  end

  --  CARGO OUTRANKS COLLECTION. A unit holding a load has exactly one job, and
  --  letting it pick up more first is how a unit ends up hoarding instead of
  --  ferrying. Below the recall ladder, though -- a stranded unit cannot reach
  --  a chest either.
  --  REPLANT SITS ABOVE DEPOSIT and below recall. See replantWork: a unit
  --  holding the seed an intent names is two tiles from finishing a job, and
  --  deposit would send it back to a crate instead.
  --
  --  THIS ORDERING IS THE WHOLE FEATURE. It was written below depositWork by
  --  mistake and the loop that produced was exact and undramatic: withdraw a
  --  seed, deposit it, withdraw it again, roughly three times a second, with
  --  nothing in the log looking like an error because every individual task
  --  succeeded.
  local putBack, noPutBack
  if doReplant then putBack, noPutBack = replantWork() end
  if dispatchable(putBack) ~= nil then return putBack end

  --  WATER SITS WITH REPLANT, ABOVE DEPOSIT, and for exactly the same reason:
  --  a unit carrying liquid that matches dry soil is mid-job, and deposit fires
  --  on ANY cargo.
  local wet, noWet
  if doWater then wet, noWet = waterWork() end
  if dispatchable(wet) ~= nil then return wet end

  --  RESTOCK DELIVERY SITS HERE FOR THE THIRD TIME OVER. A unit holding a stack
  --  a request crate asked for is mid-job in exactly the way a held seed or a
  --  held bucket is. Below deposit this would be a livelock rather than a
  --  detour: fetch the stack, deposit it into ordinary storage, fetch it out
  --  again, with every individual task succeeding and nothing in the log
  --  looking wrong -- which is precisely what replantWork's header records
  --  happening when it was written on the wrong side of this line.
  local restock
  if doSorting then restock = restockDeliverWork() end
  if dispatchable(restock) ~= nil then return restock end

  local drop, noDrop = depositWork()
  if dispatchable(drop) ~= nil then return drop end

	--  ORDERING IS NOT A GUARD.
	--
	--  Everything above claims cargo outranks collection, and it does -- but only
	--  while depositWork RETURNS something. With no beacon in coverage it returns
	--  nil and a reason, and collection below ran unguarded: a unit picked up a
	--  stack, then a second stack of the same item, then an unrelated third, and
	--  kept going. Precedence cannot order an option that does not exist.
	--
	--  ANY CARGO IS A FULL LOAD. One stack per trip is the design -- more
	--  throughput means more units, which is the point of the scaling loop. So
	--  this is not "stop when full", it is "stop when holding anything".
	--
	--  The FIRST pickup with no crate anywhere is still allowed, and that is
	--  deliberate rather than an exemption: cargo is empty at that moment, so the
	--  guard does not fire. A drop is on a despawn timer and a unit is not, so
	--  rescuing one is strictly better than watching it evaporate.
	--
	--  THIS IS ALSO THE ORPHAN CONDITION. A unit holding cargo that deposit
	--  cannot place is precisely the state the hand-it-back interaction exists
	--  for; when that lands it hangs off this branch rather than a second test.
	--
	--  Blocks harvest, animals and withdraw as well, by returning outright.
	--  Harvesting while unable to deposit only manufactures drops that cannot be
	--  collected either, and withdrawWork manufactures cargo on top of cargo.
	if self.petData ~= nil and self.petData.cargo ~= nil
	   and #self.petData.cargo > 0 then

		--  ONE EXCEPTION, AND ONLY HERE: TOP UP WHAT IS ALREADY IN HAND.
		--
		--  This is the stalled state -- cargo the unit cannot place anywhere,
		--  which in practice means storage is full and a spill is decaying on
		--  the ground. The unit has nothing else to do and a drop despawn timer
		--  is running, so a unit holding 3 dirt fetching 10 more dirt saves
		--  items that would otherwise evaporate.
		--
		--  NOT A HOLE IN THE GUARD ABOVE. Merging leaves the unit carrying ONE
		--  stack, capacity is counted in slots so nothing is consumed, and
		--  dropMergesWithCargo refuses anything that would exceed maxStack. The
		--  unit still cannot pick up a second KIND of thing, which is what "any
		--  cargo is a full load" exists to prevent.
		--
		--  DELIBERATELY ONLY IN THE STALL. When a deposit target exists the unit
		--  delivers instead, even if it is carrying three of something and
		--  standing next to nine hundred more. Topping up on the way to a crate
		--  is a better feature and a much bigger one -- it needs a detour rule
		--  and can ping-pong -- so it is not smuggled in here.
		local topUp = doHauling and collectionWork(true) or nil

		if topUp ~= nil then
			sb.logInfo("PETPORT %s stalled with cargo -- topping up %s instead of idling",
				stationUniqueId(), tostring(topUp.id))
			return topUp
		end

		return nil, noDrop
			or ("carrying " .. sb.printJson(#self.petData.cargo)
				.. " stack(s) with no dispatchable deposit target")
	end

  local work, why
  if doHauling then work, why = collectionWork() end
  if dispatchable(work) ~= nil then return work end

  --  HARVEST SITS BELOW COLLECT, and the reason is perishability. An item drop
  --  has a despawn timer; a ripe crop does not, and will be exactly as ripe in
  --  a minute. So clearing the ground first costs nothing and losing a drop to
  --  a harvest detour costs the item.
  --
  --  It also produces a rhythm that reads well: harvest, drops appear, collect
  --  them, deposit runs because deposit outranks collect, come back, harvest
  --  the next one.
  local crop, noCrop
  if doHarvest then crop, noCrop = harvestWork() end
  if dispatchable(crop) ~= nil then return crop end

  --  BESIDE CROP HARVESTING, below collection, for the same reason: an animal
  --  that is ready stays ready, where a drop on the ground is on a despawn
  --  timer. Nothing is lost by clearing the ground first.
  local beast, noBeast
  if doAnimals then beast, noBeast = animalWork() end
  if dispatchable(beast) ~= nil then return beast end

  --  Fetching is the lowest-priority thing a unit can do: it is the only work
  --  that MANUFACTURES cargo rather than clearing something. See withdrawWork.
  local fetch, noFetch
  if doReplant then fetch, noFetch = withdrawWork() end
  if dispatchable(fetch) ~= nil then return fetch end

  local fetchWater, noFetchWater
  if doWater then fetchWater, noFetchWater = withdrawWaterWork() end
  if dispatchable(fetchWater) ~= nil then return fetchWater end

  --  RESTOCKING SITS ABOVE TIDYING AND BELOW EVERYTHING ELSE. It manufactures
  --  cargo, like fetching a seed does, so it goes near the bottom -- but a
  --  player who asked for 2000 hazard blocks asked for something, where tidying
  --  is the network's own housekeeping and nobody requested it.
  local stock, noStock
  if doSorting then stock, noStock = restockFetchWork() end
  if dispatchable(stock) ~= nil then return stock end

  --  FUEL SITS ABOVE TIDYING because it UNBLOCKS something. A machine whose
  --  output slot is full stops converting, so collecting from it restarts work
  --  that is otherwise halted -- where tidying is purely cosmetic and nothing
  --  waits on it.
  local fuel, noFuel
  if doMachines then fuel, noFuel = fuelWork() end
  if dispatchable(fuel) ~= nil then return fuel end

  --  BELOW EVERYTHING, INCLUDING FETCHING. Tidying is the only work that is
  --  purely cosmetic from the network's point of view -- nothing is lost, no
  --  timer is running, and every other job represents something that either
  --  perishes or is already half done.
  local tidy, noTidy
  if doSorting then tidy, noTidy = tidyWork() end
  if dispatchable(tidy) ~= nil then return tidy end

  --  THE VERY BOTTOM. Tidying moves something that is in the wrong box;
  --  compaction reshapes something that is already in the right one. If there
  --  is any other job in the network at all, it outranks this.
  local squash, noSquash
  if doSorting then squash, noSquash = compactWork() end
  if dispatchable(squash) ~= nil then return squash end

  --  BELOW THE VERY BOTTOM. Draining is the only IRREVERSIBLE work in the mod:
  --  everything above moves things, and this one feeds them to a machine that
  --  destroys them. A unit should do literally anything else first, including
  --  merging two stacks in a crate nobody is looking at.
  --
  --  Nothing is waiting on it either. The surplus has been sitting there and
  --  will keep sitting there.
  local drain, noDrain
  if doMachines then drain, noDrain = drainWork() end
  if dispatchable(drain) ~= nil then return drain end

	--  The old noDrop fallback lived here and is now unreachable: noDrop is only
	--  ever set when cargo is non-empty, and the guard above returns on that
	--  condition before anything below runs.

  --  THE ONLY TYPE RECT_CHECKED_TYPES ACTUALLY GUARDS, so it is the one rung
  --  that must not bypass dispatchable(). diagnosticWork calls findStandingPoint
  --  against this port's own rect, so a point outside it means the generator is
  --  wrong -- which is what the original assertion was always for.
  if DIAG_FALLBACK then
    local diag = diagnosticWork()
    if dispatchable(diag) ~= nil then return diag end
  end

  --  A SWITCHED-OFF GROUP IS A REASON, AND IT HAS TO BE SAID OUT LOUD.
  --
  --  The composite below is assembled entirely from the `no*` reasons, and
  --  every one of those is nil for a group whose generator never ran. So
  --  without this, a port with farming unticked reports the same thing as a
  --  port that cannot see the farm at all -- and the `noCrop ~= nil` gate would
  --  drop the composite entirely and return a bare nil reason, which reject()
  --  then logs as nothing useful.
  --
  --  This is the diagnosis path for "why is my pet standing still", which is
  --  the question this whole mod's logging exists to answer. An opt-out is the
  --  most likely answer once these boxes exist and the easiest to forget.
  local off = {}
  if not doHauling then table.insert(off, "hauling") end
  if not doSorting then table.insert(off, "sorting") end
  --  FARMING REPORTS ITS OWN REASON, because "does not participate in farming"
  --  is now three different situations: no module, the module with this activity
  --  unticked, or the port switched off entirely. A player chasing a still pet
  --  needs to know which.
  if not farming then
    table.insert(off, petportFarming() and "farming (port off)" or "farming (no module)")
  else
    for _, class in ipairs(FARMING_CLASSES) do
      if not petportFarmingDoes(class) then
        table.insert(off, "farming: " .. class)
      end
    end
  end
  if not doMachines then table.insert(off, "machines") end

  local optedOut = nil
  if #off > 0 then
    optedOut = "port does not participate in " .. table.concat(off, ", ")
  end

  local function withOptOut(reason)
    if optedOut == nil then return reason end
    if reason == nil then return optedOut end
    return reason .. "; " .. optedOut
  end

  --  BOTH LEGS OF A TWO-LEG JOB, NOT WHICHEVER CAME FIRST.
  --
  --  Replanting and watering each run as a fetch rung and a place rung, and
  --  this used to join them with `or`. The fetch reason is set on essentially
  --  every scan, so the place reason was unreachable -- which is how a port
  --  spent thirty seconds withdrawing one oculemonseed and depositing it back
  --  into the crate it came from while its summary line said only "2 replant
  --  intent(s), none actionable", the FETCH rung's reason, about a fetch that
  --  was succeeding every time. The rung that was refusing never spoke.
  --
  --  They answer different questions -- "can I place what I am holding" versus
  --  "can I fetch what I am missing" -- so an `or` between them was wrong even
  --  before it hid anything.
  local function bothLegs(place, fetch, quiet)
    if place ~= nil and fetch ~= nil then return place .. ", and " .. fetch end
    return place or fetch or quiet
  end

  --  Both reasons, because "no drops in network coverage" alone reads as though
  --  the port never looked at the farm.
  if noCrop ~= nil then
    return nil, withOptOut(tostring(why or "collection not run")
      .. "; " .. tostring(noCrop)
      .. "; " .. tostring(bothLegs(noPutBack, noFetch, "no replant work"))
      .. "; " .. tostring(bothLegs(noWet, noFetchWater, "no watering work"))
      .. "; " .. tostring(noBeast or "no animal work")
      .. "; " .. tostring(noStock or "no restock work")
      .. "; " .. tostring(noFuel or "no fuel to collect")
      .. "; " .. tostring(noTidy or "no tidying work")
      .. "; " .. tostring(noSquash or "no compaction work")
      .. "; " .. tostring(noDrain or "no draining work"))
  end

  return nil, withOptOut(why)
end

--  Every rejection gets a reason. These failures are all silent-nil shaped -- a
--  unit that does not move looks identical whether the port never discovered
--  the work, discovered and rejected it, or dispatched it to a unit that could
--  not path. A reason string collapses that to one line of log.
local function reject(reason)
  --  Log a reason ONCE, then only when it changes. "no drops in rect" once a
  --  second drowns everything else in the log, and a repeating identical reason
  --  carries no information the first line did not.
  --  Repeat suppression, NOT permanent suppression. A port stuck on one
  --  unchanging reason would otherwise print once and go silent forever, which
  --  reads as "stopped running" rather than "still refusing". Re-state the
  --  current reason periodically so a stuck port stays visible.
  if reason == self.lastReject
     and (self.lastRejectAt or 0) + REJECT_REPEAT > world.time() then
    return
  end

  self.lastReject = reason
  self.lastRejectAt = world.time()

  --  NOT gated behind DEBUG. Every one of these failures is silent-nil shaped:
  --  a unit that does not move looks identical whether the port never
  --  discovered work, discovered and rejected it, or dispatched to a unit that
  --  could not path. Hiding the reason behind a flag defeats the entire point
  --  of having one.
  sb.logInfo("PETPORT %s no dispatch: %s", stationUniqueId(), reason)
end


local function dispatchWork()
  if self.petId == nil or not world.entityExists(self.petId) then
    return reject("no unit")
  end

  local work, why = findWork()
  if work == nil then
    return reject(why)
  end

  --  RE-CHECK THE UNIT. findWork can reach rehomeUnit, which despawns the unit
  --  and nils self.petId -- so the guard at the top of this function was
  --  correct when it ran and stale by the time it matters. Calling
  --  callScriptedEntity with a nil id throws a LuaConversionException rather
  --  than returning nil, which kills the port's update.
  if self.petId == nil or not world.entityExists(self.petId) then
    return reject("unit went away while work was being chosen")
  end

  --  The rect check now lives in findWork, at every rung, so a refused
  --  candidate falls through to the next kind of work instead of ending the
  --  tick. See RECT_CHECKED_TYPES and dispatchable() above findWork.

  if not petports_claimTake(work.id, stationUniqueId(), petUniqueId(),
                            work.type, work.position, CLAIM_TTL) then
    --  Name the work. "claimed by another owner" on its own does not say
    --  whether two ports are racing for one drop or one crate, and those are
    --  very different problems.
    return reject("claimed by another owner: " .. tostring(work.id))
  end

  --  CARGO MANIFEST, FOR DISPLAY ONLY.
  --
  --  Cargo lives on the port, not the unit, so the unit cannot draw what it is
  --  carrying without being told. The task table is already crossing the
  --  boundary, so it carries a short summary rather than opening a second sync
  --  channel for something only the debug overlay reads.
  --
  --  A SNAPSHOT, not a live view. It is correct at dispatch and goes stale the
  --  moment anything changes -- which for a deposit run is exactly the window
  --  it needs to be right for, since the load does not change between leaving
  --  and arriving.
  if self.petData ~= nil and self.petData.cargo ~= nil then
    local manifest = {}
    for _, stack in ipairs(self.petData.cargo) do
      table.insert(manifest, string.format("%sx %s",
        tostring(stack.count or 1), tostring(stack.name)))
    end
    work.cargo = manifest
  end

  if not world.callScriptedEntity(self.petId, "petports_assignTask", work) then
    --  The unit refused -- already holding something, or the contract is
    --  missing. Do not sit on a claim for work nobody is doing.
    petports_claimRelease(work.id, stationUniqueId())
    return reject("unit refused assignment")
  end

  self.task = work

  --  A NEW TASK HAS NOT MOVED YET. Without clearing this, the second task in a
  --  row would render green from its first frame -- the unit would appear to
  --  have found a route before it had been asked to look for one.
  self.taskMoving = false
  self.taskAge = 0
  self.lastReject = nil
  --  sb.logInfo takes %s ONLY. Star's formatter has no width or precision
  --  specifiers, so %.1f raises "Improper lua log format specifier".
  sb.logInfo("PETPORT %s dispatched %s to %s",
    stationUniqueId(), work.id, sb.printJson(work.position))
end

--  Called on the work timer while a task is believed to be in flight.
local function trackWork()
  --  Deadline first: a unit that accepted a task and then never entered its
  --  state reports nothing at all, and every check below would keep passing.
  self.taskAge = (self.taskAge or 0) + WORK_INTERVAL
  if self.taskAge >= TASK_DEADLINE then
    local taskId = self.task.id
    abandonTask("deadline -- no report in " .. sb.printJson(TASK_DEADLINE) .. "s")
    noteFailure(taskId, "deadline")

    --  The unit may still be holding it. Clear its side too, or it will keep
    --  re-queueing an assignment this port has forgotten.
    if self.petId ~= nil and world.entityExists(self.petId) then
      world.callScriptedEntity(self.petId, "petports_clearTask")
    end
    return
  end

  --  The unit died, was recalled, or respawned without its assignment. Stop
  --  refreshing and let the claim age out rather than releasing it here -- if
  --  the unit is merely mid-respawn it will not answer, and dropping the claim
  --  every time would churn replicated state.
  if self.petId == nil or not world.entityExists(self.petId) then
    self.task = nil
    return reject("unit gone mid-task")
  end

  if world.callScriptedEntity(self.petId, "petports_taskId") ~= self.task.id then
    --  The unit dropped it. It very likely also sent a report that is about to
    --  arrive and find self.task already nil, so account for the failure HERE
    --  rather than trusting the message to win the race.
    local taskId = self.task.id
    self.task = nil
    noteFailure(taskId, "unit stopped holding the task")
    return reject("unit is no longer holding the task")
  end

  sb.logInfo("PETPORT %s tracking %s, age %s of %s",
    stationUniqueId(), self.task.id,
    sb.printJson(self.taskAge), sb.printJson(TASK_DEADLINE))

  petports_claimRefresh(self.task.id, stationUniqueId(), CLAIM_TTL)
end

--------------------------------------------------------------------------------
--  CROSSHAIRS
--------------------------------------------------------------------------------
--
--  A marker floating over every drop the network has an opinion about, so the
--  player can see the fleet working without reading a log.
--
--  THE VENT CASE IS WHY THIS EXISTS. A unit that walks into a vent, vanishes,
--  and surfaces two rooms away reads as the network ignoring the item. A marker
--  sitting on the drop the whole time says "seen, spoken for" without having to
--  explain traversal at all.
--
--  DRIVEN ENTIRELY FROM STATE THE PORT ALREADY HAS. Nothing here decides
--  anything -- it reads the current task and the failure records and renders
--  them. A marker that could disagree with dispatch would be worse than none.
--
--  REFRESHED, NOT TRACKED FOREVER. Each pass computes what SHOULD be showing
--  and reconciles: spawn what is missing, kill what has changed, leave what
--  matches. The projectiles also carry a timeToLive as a backstop, so a port
--  that unloads mid-task cannot leave a permanent artefact in someone's world.

--  Faster than WORK_INTERVAL on purpose. Dispatch changes between work ticks,
--  and a marker that lags its task by five seconds is describing the past.
CROSSHAIR_INTERVAL = 0.5

--  How long a marker may live before it is rebuilt.
--
--  THIS IS RENEWAL, NOT THE LIFECYCLE, and at 2.0 it was neither. The
--  projectile's timeToLive was three seconds, so every marker on the map was
--  destroyed and rebuilt every two -- roughly thirty times a minute for a drop
--  nobody had touched, each rebuild leaving a predecessor behind for the cull
--  to clear. The log made it obvious in hindsight: the same drop, the same
--  state, the same position, respawning on a metronome.
--
--  With the projectile's TTL raised to thirty seconds, this only has to beat
--  that. Twenty leaves ten seconds of margin and turns a constant churn into
--  something that happens roughly once per marker per twenty seconds.
--
--  MUST STAY BELOW THE PROJECTILE'S timeToLive. If it ever exceeds it, markers
--  wink out and reappear on their own, which reads as the network losing track
--  of the item.
CROSSHAIR_REFRESH = 20.0

--  DEFAULTS ONLY. Overridden per unit by petData.crosshairColors, so an
--  accessibility or preference interface can rewrite them per unit without
--  touching the mod -- colourblind players should not be stuck with red versus
--  green carrying the load.
--
--  RRGGBBAA, fed to "?multiply=" against a white sprite with a black outline:
--  white takes the colour, black stays black.
CROSSHAIR_COLORS = {
  --  Dispatched. The unit has been given this target.
  routing = "ffd23fff",

  --  The unit found a route and is walking it. Set by the unit's
  --  petports_taskProgress message once it has actually covered ground -- see
  --  TASK_MOVING_DISTANCE in petportsTaskAction.lua for why movement is the
  --  signal rather than the pather's internal state.
  enroute = "5fd35fff",

  --  Could not get there from here.
  unroutable = "e04b4bff",

  --  Could get there, could not do the job -- no room, nothing accepts it.
  blocked = "ef8b3cff",

  --  In coverage, nobody has claimed it. The network can see it and has not got
  --  to it yet, which is a different and much commoner statement than any of
  --  the above -- and the one that answers "does the fleet even know this is
  --  here" while a unit is busy elsewhere.
  --
  --  Deliberately the dullest colour in the set. It is on screen the most, and
  --  a marker that competes with the ones that mean something would make all of
  --  them easier to ignore.
  unclaimed = "9aa0a6ff"
}

CROSSHAIR_PROJECTILE = {
  routing = "petports_crosshair",
  enroute = "petports_crosshair",
  unroutable = "petports_crosshair_failed",
  blocked = "petports_crosshair_warn",
  unclaimed = "petports_crosshair"
}

--  WHICH STATE OUTRANKS WHICH, when two ports both have an opinion about one
--  drop.
--
--  MEASURED: three ports covering one unreachable item drew grey, yellow and
--  red simultaneously, stacked on the same tile. Every port has its own view --
--  one dispatched it, one backed off from it, one had never touched it -- and
--  every view was correct from where it stood. The marker is a statement about
--  the NETWORK, so exactly one of them may speak.
--
--  Ordered by how much the player needs to know it. Being worked on beats a
--  failure, because it supersedes it; a failure beats a blockage, because it is
--  more specific; anything beats "nobody has got to it".
CROSSHAIR_PRIORITY = {
  routing = 4,
  enroute = 4,
  unroutable = 3,
  blocked = 2,
  unclaimed = 1
}

--  Marker ownership rides the ordinary claim registry, which already has
--  expiry, sweeping and cross-port visibility. A separate mechanism would be a
--  second thing to keep in sync for no gain.
local function crosshairClaimId(dropId)
  return "mark:" .. tostring(dropId)
end

--  Long enough that renewals are rare, short enough that a port which dies
--  mid-task frees its markers quickly.
--
--  RENEWED LAZILY, NOT EVERY PASS, and the cost is the reason. Every
--  petports_claimRefresh writes the whole claim registry to a world property --
--  fine for a handful of long-lived work claims, and not fine for a marker per
--  drop refreshed twice a second. A spill of twenty drops across three ports
--  would have been a hundred and twenty registry writes a second to keep
--  cosmetics alive.
--
--  Renewing only in the last stretch before expiry brings that to roughly one
--  write per marker per two and a half seconds, and nothing observable changes:
--  the claim's job is to answer "is someone else already drawing this", and it
--  answers identically either way.
CROSSHAIR_CLAIM_TTL = 4.0
CROSSHAIR_CLAIM_RENEW = 1.5

--  May this port draw the marker for this drop, in this state?
--
--  STEALS FROM A LOWER-PRIORITY HOLDER, which is what makes the priority table
--  above mean anything. petports_claimTake refuses outright when someone else
--  holds a live claim, so outranking it means releasing first --
--  petports_claimRelease with a nil owner releases regardless of who holds it.
local function crosshairClaim(dropId, state)
  local claimId = crosshairClaimId(dropId)
  local existing = petports_claimGet(claimId)
  local mine = existing ~= nil and existing.owner == stationUniqueId()

  if mine then
    if (existing.expires or 0) - world.time() < CROSSHAIR_CLAIM_RENEW then
      petports_claimRefresh(claimId, stationUniqueId(), CROSSHAIR_CLAIM_TTL)
    end

    return true
  end

  if existing ~= nil and (existing.expires or 0) > world.time() then
    local theirs = CROSSHAIR_PRIORITY[existing.type] or 0
    local ours = CROSSHAIR_PRIORITY[state] or 0

    --  STRICTLY GREATER. Equal priority leaves the incumbent alone, so two
    --  ports both seeing "unclaimed" do not trade the marker back and forth
    --  every half second.
    if ours <= theirs then return false end

    sb.logInfo("PETPORT %s crosshair for drop %s: taking over from %s (%s beats %s)",
      stationUniqueId(), sb.printJson(dropId), tostring(existing.owner),
      tostring(state), tostring(existing.type))

    petports_claimRelease(claimId, nil)
  end

  return petports_claimTake(claimId, stationUniqueId(), nil, state,
    world.entityPosition(dropId), CROSSHAIR_CLAIM_TTL)
end

local function crosshairRelease(dropId)
  petports_claimRelease(crosshairClaimId(dropId), stationUniqueId())
end

local function crosshairColor(state)
  local overrides = self.petData ~= nil and self.petData.crosshairColors or nil

  if type(overrides) == "table" and type(overrides[state]) == "string" then
    return overrides[state]
  end

  return CROSSHAIR_COLORS[state]
end

--  What SHOULD be marked right now, as { [dropId] = state }.
--
--  ONLY DROPS. Crates and machines are objects a player can already see and
--  reason about; a drop on the ground is the thing that looks ignored.
--  Every drop in network coverage.
--
--  QUERIED HERE RATHER THAN REUSED FROM collectionWork, which only runs when the
--  unit is free. Markers have to keep telling the truth while the unit is busy
--  ferrying something else -- that is precisely when a player wonders whether
--  the fleet has noticed a pile at all.
--
--  Same rects and same includedTypes as collectionWork, so the two cannot
--  disagree about what is in range.
local function crosshairDrops()
  local rects = self.networkRects
  if rects == nil or #rects == 0 then return {} end

  local drops = {}
  local seen = {}

  for _, area in ipairs(rects) do
    local found = world.entityQuery({ area[1], area[2] }, { area[3], area[4] }, {
      includedTypes = { "itemDrop" }
    })

    for _, dropId in ipairs(found or {}) do
      if not seen[dropId] then
        seen[dropId] = true
        table.insert(drops, dropId)
      end
    end
  end

  return drops
end

--  Will any deposit crate take this item, right now?
--
--  PER ITEM, NOT PER LOAD, AND THAT DISTINCTION IS THE WHOLE FIX.
--
--  The blocked marker used to key off storageWouldTakeAny, which asks whether
--  storage will accept THE UNIT'S CURRENT CARGO. That made every drop in
--  coverage change colour together every time a unit picked something up or put
--  it down -- measured at 143 blocked against 81 unclaimed spawns in one
--  session, with single drops respawning eighteen times. The field strobed, and
--  none of it was about the drops.
--
--  world.itemDropItem gives the drop's own descriptor, so each marker can now
--  answer for the item it is actually sitting on. A drop of something no crate
--  wants stays orange while a drop of something storable stays grey, regardless
--  of what any unit happens to be carrying.
--
--  CACHED PER PASS, BY NAME. A spill is many drops of few names, so this is a
--  handful of filter checks rather than one per drop -- and the cache lives for
--  a single pass, because room changes between them.
local function crosshairStorable(dropId, cache)
  local ok, descriptor = pcall(world.itemDropItem, dropId)

  if not ok or type(descriptor) ~= "table" or type(descriptor.name) ~= "string" then
    --  UNREADABLE IS TREATED AS STORABLE, so a drop we cannot identify shows
    --  the quiet marker rather than the alarming one. Guessing wrong towards
    --  grey means a missing warning; guessing wrong towards orange means
    --  crying wolf on every drop in the base.
    return true
  end

  if cache[descriptor.name] ~= nil then return cache[descriptor.name] end

  local storable = false

  for _, beacon in ipairs(petports_beaconsFor("deposit")) do
    if world.entityExists(beacon.id)
       and petports_filterAccepts(beacon.filter, descriptor.name) then

      --  nil means the engine will not answer, read as YES for the same reason
      --  as above: the quiet marker is the safer guess.
      local fits = world.containerItemsCanFit ~= nil
        and world.containerItemsCanFit(beacon.id, descriptor) or nil

      if fits == nil or fits > 0 then
        storable = true
        break
      end
    end
  end

  cache[descriptor.name] = storable

  return storable
end

local function crosshairWanted()
  local wanted = {}

  --  The live task, if it is a collection.
  --
  --  No "enroute" yet -- see CROSSHAIR_COLORS.enroute. Everything dispatched
  --  shows as routing, which still answers the question the marker exists for.
  if self.task ~= nil and self.task.type == "collect" and self.task.target ~= nil then
    --  ROUTING UNTIL THE UNIT HAS ACTUALLY COVERED GROUND, then ENROUTE.
    --
    --  Yellow means "a unit has been given this and is working out how to get
    --  there"; green means "it found a way and is walking it". The distinction
    --  matters most exactly where it is hardest to see -- a unit that
    --  vent-routes vanishes, and a green marker says the disappearance is
    --  progress rather than the network having lost interest.
    --
    --  self.taskMoving is set by the unit's progress message and cleared with
    --  every new task, so it can only ever describe the task in hand.
    wanted[self.task.target] = self.taskMoving and "enroute" or "routing"
  end

  --  Anything currently backed off. These OUTLIVE the task that produced them,
  --  which is the whole point: a failure the player never sees is a failure
  --  they cannot fix. They persist until the backoff expires or the drop is
  --  gone, and are overwritten above if the drop gets dispatched again.
  for taskId, record in pairs(self.workFailures or {}) do
    local dropId = string.match(taskId, "^drop:(%d+)$")

    if dropId ~= nil and (record["until"] or 0) > world.time() then
      dropId = tonumber(dropId)

      if wanted[dropId] == nil then
        wanted[dropId] = record.unroutable and "unroutable" or "blocked"
      end
    end
  end

  --  EVERYTHING ELSE IN COVERAGE, AT THE BOTTOM OF THE PRIORITY ORDER, so a
  --  drop that is dispatched or backed off keeps the more specific marker it
  --  already earned above.
  --  One pass, one cache. See crosshairStorable.
  local storable = {}

  for _, dropId in ipairs(crosshairDrops()) do
    if wanted[dropId] == nil then
      local claim = petports_claimGet("drop:" .. dropId)
      local mine = claim == nil
        or claim.owner == stationUniqueId()
        or (claim.expires or 0) <= world.time()

      if not mine then
        --  ANOTHER PORT'S CLAIM DRAWS NOTHING HERE. That port is marking it,
        --  and two markers on one drop would stack and read as a brighter
        --  colour rather than as two ports agreeing.
        wanted[dropId] = nil

      elseif not crosshairStorable(dropId, storable) then
        --  ORANGE: reachable, and nothing will take it.
        --
        --  Answered per item now. It was keyed off failed drop tasks first --
        --  which almost never happens, since collecting rarely fails once the
        --  unit can reach the drop -- and then off the unit's cargo, which made
        --  every drop in coverage flip whenever the unit's hands changed.
        wanted[dropId] = "blocked"

      else
        wanted[dropId] = "unclaimed"
      end
    end
  end

  return wanted
end

local function crosshairKill(marker)
  if marker == nil or marker.id == nil then return end

  if world.entityExists(marker.id) then
    world.sendEntityMessage(marker.id, "kill")
  end
end

--  How far a drop may drift from its marker before the marker is repositioned.
--
--  A PROJECTILE CAN BE MOVED -- see the "move" handler in
--  petports_crosshair.lua, and vanilla's controlprojectile, which repositions a
--  whole set of them every tick. An earlier version of this killed and
--  respawned instead, which costs a spawn per move and blanks the marker for a
--  frame.
--
--  Half a tile is tight enough that a marker never visibly lags the item, and
--  loose enough that a settling drop is not messaged every pass.
CROSSHAIR_DRIFT = 0.5

--  How long a marker must hold a state before it may show a different one.
--
--  THE UNDERLYING FLAPPING IS REAL, and not a bug to fix here. An unreachable
--  drop genuinely cycles: a port dispatches it, the unit fails to route, the
--  port backs off, the backoff expires, another port tries. Measured at
--  thirty-four state changes on a single item across one session.
--
--  Rendering every one of those faithfully produces a strobe, which conveys
--  less than either colour would on its own -- and with retire-on-one-pass,
--  replace-on-the-next, half of them would be gaps. A marker is for a human
--  reading it at a glance, so it changes at a speed a human can read.
--
--  DELIBERATELY NOT A FIX FOR THE CYCLE ITSELF. The dispatch-fail-backoff loop
--  is correct behaviour and the log records it in full; this only governs how
--  often the cosmetic redraws.
CROSSHAIR_DWELL = 1.5

--  TRANSITIONS THE DWELL DOES NOT GOVERN.
--
--  The dwell is anti-strobe, and it only earns that by costing latency on
--  changes that could come back. routing -> enroute cannot: self.taskMoving
--  goes false to true exactly once per task and is cleared only when a NEW task
--  is dispatched, so the pair can never trade back and forth the way an
--  unreachable drop's dispatch-fail-backoff cycle does.
--
--  IT WAS THE WORST CASE FOR THE DWELL, NOT AN INCIDENTAL ONE. A yellow marker
--  is spawned AT DISPATCH, so its `since` is always fresh -- which means the
--  yellow-to-green change was the one transition in the set that reliably
--  landed inside the dwell window and paid the full 1.5s. Everything else here
--  changes state on a marker that has usually been up for a while.
CROSSHAIR_IMMEDIATE = {
  routing = { enroute = true }
}

local function crosshairRefresh(dt)
  self.crosshairs = self.crosshairs or {}

  --  SWITCHED OFF: RETIRE WHAT IS OUT THERE, THEN DO NOTHING.
  --
  --  ABOVE THE TIMER, so a switch-off takes effect on the next tick rather than
  --  up to CROSSHAIR_INTERVAL later. A player unticking a box wants the markers
  --  gone, not gone shortly.
  --
  --  SELF-LIMITING WITHOUT A FLAG: crosshairClear empties self.crosshairs, so
  --  the `next` test is false on every tick after the first and this costs one
  --  table lookup while the port stays off.
  if not petportCrosshairs() then
    if next(self.crosshairs) ~= nil then
      sb.logInfo("PETPORT %s retiring crosshairs: switched off", stationUniqueId())
      crosshairClear()
    end
    return
  end

  self.crosshairTimer = (self.crosshairTimer or 0) - dt
  if self.crosshairTimer > 0 then return end
  self.crosshairTimer = CROSSHAIR_INTERVAL

  local wanted = crosshairWanted()

  --  RETIRE FIRST, so a state change never shows two markers at once on one
  --  drop -- the old colour would sit on top of the new one for a frame.
  for dropId, marker in pairs(self.crosshairs) do
    --  FOLLOW, RATHER THAN REPLACE. A drop that is still settling moves; the
    --  marker follows it with a message and keeps its identity.
    if marker.position ~= nil and world.entityExists(dropId)
       and world.entityExists(marker.id) then

      local at = world.entityPosition(dropId)

      if world.magnitude(at, marker.position) > CROSSHAIR_DRIFT then
        world.sendEntityMessage(marker.id, "move", at)

        sb.logInfo("PETPORT %s crosshair MOVE %s (%s) from %s to %s",
          stationUniqueId(), sb.printJson(marker.id), tostring(marker.state),
          sb.printJson(marker.position), sb.printJson(at))

        marker.position = at
      end
    end

    --  A state that changed too recently to redraw is held, not retired. The
    --  marker keeps showing the older state until the dwell elapses -- unless
    --  this particular transition is one the dwell has no business delaying.
    local exempt = CROSSHAIR_IMMEDIATE[marker.state] ~= nil
      and CROSSHAIR_IMMEDIATE[marker.state][wanted[dropId]] == true

    local settling = wanted[dropId] ~= nil
      and wanted[dropId] ~= marker.state
      and not exempt
      and (world.time() - (marker.since or 0)) < CROSSHAIR_DWELL

    local keep = wanted[dropId] ~= nil
      and (wanted[dropId] == marker.state or settling)
      and world.entityExists(dropId)
      and world.entityExists(marker.id)

    if not keep then
      crosshairKill(marker)
      crosshairRelease(dropId)
      self.crosshairs[dropId] = nil
    end
  end

  for dropId, state in pairs(wanted) do
    local marker = self.crosshairs[dropId]

    --  A drop that has been collected or despawned takes its marker with it.
    --
    --  ONE MARKER PER DROP, ACROSS THE WHOLE NETWORK, and this is only half of
    --  it: the claim settles WHICH PORT SPEAKS for a drop, so the colour is not
    --  simply whichever port redrew last. The markers themselves enforce that
    --  only one exists -- see petportsItem below and the cull in
    --  petports_crosshair.lua.
    --
    --  Two mechanisms because they answer different questions. Without the
    --  claim, three ports produced grey, yellow and red on one tile, each
    --  correct from where it stood. Without the cull, nothing makes the
    --  invariant true rather than merely intended.
    if world.entityExists(dropId) and crosshairClaim(dropId, state) then
      local due = marker == nil or (marker.refresh or 0) <= world.time()

      if due then
        crosshairKill(marker)

        local at = world.entityPosition(dropId)

        local ok, id = pcall(world.spawnProjectile,
          CROSSHAIR_PROJECTILE[state],
          at,

          --  NO SOURCE ENTITY. Attributing a harmless marker to the port would
          --  make it the port's projectile for damage-team purposes, and a
          --  marker should belong to nobody.
          nil,
          { 0, 0 },
          false,
          {
            processing = "?multiply=" .. crosshairColor(state),

            --  WHAT THIS MARKER IS FOR, so it can evict any predecessor on the
            --  same item and identify itself to its own successor. Without it
            --  a marker cannot cull or be culled -- see petports_crosshair.lua,
            --  which enforces one-marker-per-item by construction rather than
            --  relying on this side getting the bookkeeping right.
            petportsItem = dropId
          })

        --  KEPT, AND NOT TEMPORARY AFTER ALL. This was added to chase a red
        --  marker sitting off-centre from the yellow it replaced, and it
        --  answered a different question instead: two ports spawning markers
        --  for the SAME drop at the SAME position, microseconds apart. What
        --  looked like one misplaced marker was two stacked ones.
        --
        --  That is worth keeping visible while the claim arbitration above is
        --  young: a second port spawning for a drop this port already marks
        --  means the claim is not holding.
        sb.logInfo("PETPORT %s crosshair SPAWN %s for drop %s at %s (previous %s)",
          stationUniqueId(), tostring(state), sb.printJson(dropId),
          sb.printJson(at),
          marker ~= nil and sb.printJson(marker.position) or "none")

        if ok and id ~= nil then
          self.crosshairs[dropId] = {
            id = id,
            state = state,

            --  Where it was PUT, so drift is measured against the marker rather
            --  than against the drop's position last pass. A projectile cannot
            --  be moved, so this is the only record of where the thing actually
            --  is on screen.
            position = at,

            --  When this state started showing. The dwell is measured from
            --  here, so a marker that has just changed cannot change again
            --  immediately.
            since = world.time(),
            refresh = world.time() + CROSSHAIR_REFRESH
          }
        else
          --  Loud once per drop rather than every half second. A cosmetic that
          --  cannot spawn is not worth spamming over, but it IS worth knowing
          --  about -- silence here would look like the feature was never wired.
          if self.crosshairs[dropId] ~= nil or not self.crosshairFailed then
            self.crosshairFailed = true
            sb.logError("PETPORT %s could not spawn a %s crosshair at %s: %s",
              stationUniqueId(), tostring(CROSSHAIR_PROJECTILE[state]),
              sb.printJson(world.entityPosition(dropId)), tostring(id))
          end

          self.crosshairs[dropId] = nil
        end
      end
    end
  end
end

--  Retire every marker. Called when the port stops caring -- unit gone, port
--  broken, world unloading -- so the last thing a player sees is not a
--  crosshair over a drop nothing is coming for.
--  Assigned, not declared -- the name is forward-declared near the top so uninit
--  can reach it.
crosshairClear = function()
  for dropId, marker in pairs(self.crosshairs or {}) do
    crosshairKill(marker)
    crosshairRelease(dropId)
    self.crosshairs[dropId] = nil
  end
end

local function workUpdate(dt)
  self.workTimer = self.workTimer - dt
  if self.workTimer > 0 then return end
  self.workTimer = WORK_INTERVAL

  petports_claimsSweep()

  --  RE-PUBLISH IF OUR OWN ENTRY HAS GONE.
  --
  --  publishRegistry otherwise runs only on the first update, so a port that
  --  lost its entry stayed lost for the rest of the session -- it reported
  --  "network now 0 ports", could not count even itself, and union dispatch
  --  died with it. That is exactly what registryClearAt used to do to every
  --  port within sixteen tiles.
  --
  --  Cheap: one world property read on the work timer, and the branch is not
  --  taken in normal operation.
  --
  --  CANNOT LOOP. Re-publishing calls registryClearAt, which now matches only
  --  the port's exact tile -- and two ports cannot occupy one tile, so the only
  --  entry it can clear is a predecessor with no live object left to re-publish
  --  it. Restoring the rect-wide clear would turn this into two ports evicting
  --  and re-publishing each other forever.
  local registry = petports_registry()
  if (registry.ports or {})[stationUniqueId()] == nil then
    sb.logInfo("PETPORT %s registry entry is missing -- re-publishing",
      stationUniqueId())
    publishRegistry()
  end

  refreshNetwork()
  refreshBeacons(WORK_INTERVAL)
  refreshFarmables(WORK_INTERVAL)
  refreshAnimals(WORK_INTERVAL)
  publishUnitPosition()

  --  Cheap: loadUniqueEntity on an existing stagehand and out.
  ensureResidency()

  --  A HEARTBEAT, CHANGE-GATED ON WHAT IT ACTUALLY REPORTS.
  --
  --  Unit id and current task are both slow-moving, so at one line per tick
  --  this was 160 lines saying "task none" in a session where the port was
  --  idle -- burying the handful of lines that meant something. Gated, it
  --  marks every task starting and finishing and the unit appearing or going
  --  away, which is what it was for.
  --
  --  NOT log-once: a port that is silent because it is idle and one that is
  --  silent because it stopped running look identical, and the no-dispatch
  --  reason line above is what distinguishes them.
  local tickState = string.format("%s/%s", tostring(self.petId),
    self.task and self.task.id or "none")

  if tickState ~= self.tickState then
    self.tickState = tickState

    sb.logInfo("PETPORT %s tick: unit %s task %s",
      stationUniqueId(), sb.printJson(self.petId),
      self.task and self.task.id or "none")
  end

  if self.task == nil then
    dispatchWork()
  else
    trackWork()
  end
end

function setHullAnimationStateIntent(intent)

	local currentHullState = animator.animationState("hullState")
	if intent == "open" then
		if 
			currentHullState ~= "opening" and 
			currentHullState ~= "open"
		then
		setAnimationStateForAllHullComponents("opening")
		end
		
	elseif intent == "close" then
		if 
			currentHullState ~= "closing" and 
			currentHullState ~= "closed"
		then
		setAnimationStateForAllHullComponents("closing")
		end
	end
end

function setAnimationStateForAllHullComponents(anim)
	if not anim then return end
	animator.setAnimationState("hullState", anim)
    animator.setAnimationState("doorState", anim)
    animator.setAnimationState("interiorState", anim)
end

function update(dt)
  if self.firstUpdate then
    self.firstUpdate = false
    stationUniqueId()

    --  A world unload orphaned every claim this port held. Clear our own --
    --  this runs exactly once per load, and no port ever touches another's.
    --
    --  Deliberately here rather than in init: stationUniqueId may call
    --  world.setUniqueId, which is why the id is established on the first
    --  update rather than at init in the first place.
    petports_claimsClearOwner(stationUniqueId())
    ensureResidency()
    publishRegistry()
  end

  --  MARKERS RUN ON THEIR OWN TIMER, from update rather than workUpdate.
  --
  --  workUpdate fires on WORK_INTERVAL, and dispatch changes between those
  --  ticks -- a marker refreshed on the work timer would spend most of its life
  --  describing the previous task. It has its own, faster interval and gates
  --  itself internally.
  crosshairRefresh(dt)

  --  ABOVE THE NO-ITEM RETURN, AND THAT IS THE POINT.
  --
  --  This was called from workUpdate, which is the LAST line of this function,
  --  so an EMPTY petport never swept anything. Measured: a second port with no
  --  unit socketed logged five lines when it was placed and then nothing at all
  --  for the rest of a four-minute session, while the port beside it logged
  --  every second.
  --
  --  Same shape as the trap already recorded for claims and unit position -- an
  --  early return silently disabling everything below it. Both of those were
  --  fixed before this sweep existed, so it inherited the problem rather than
  --  reintroducing it.
  --
  --  AN EMPTY PORT MUST STILL SWEEP. It holds its coverage rect and its
  --  residency whether or not it has a unit -- that is the design -- and
  --  housekeeping needs no unit to do. The case that makes it matter: the only
  --  port covering a farm can be empty, and then its own IN-COVERAGE intents
  --  stop being state-checked too, not just the orphans elsewhere.
  --
  --  Takes dt now rather than WORK_INTERVAL, because it is no longer riding a
  --  timer that has already fired. It gates itself on REPLANT_SWEEP_INTERVAL.
  sweepReplants(dt)

  --  ABOVE EVERY EARLY RETURN IN THIS FUNCTION, AND THAT IS THE ONLY PLACE IT
  --  CAN GO.
  --
  --  THIS IS THE THIRD TIME an early return in update() has silently disabled
  --  something below it -- claims and unit position were the first two, and
  --  both were fixed by duplicating a call into the no-item branch. This one is
  --  hoisted instead, because a pane needs telling on EVERY path, not just that
  --  one: switched off, not a pet item, malformed item.
  --
  --  WHAT IT COST: an unsocketed port never rewrote the mirror at all, so the
  --  pane went on reading the blob from while the unit was still socketed --
  --  name, portrait, fuel, and a full module set with clickable slots, forever
  --  rather than for the one second I attributed it to. That is the module
  --  duplication path.
  --
  --  IT MUST NOT DEPEND ON self.petData BEING CURRENT, because at this point in
  --  the tick it is not: petData is cleared further down, in the branch below.
  --  mirrorPaneState asks the container instead, which is why that check exists
  --  and why it has to stay.
  mirrorPaneState(dt)

  local item = socketedItem()

  if item == nil then
    --  Item removed: put the unit away.
    if self.petId ~= nil then
      saveAndDespawn()
      cargoTrace("unsocket: discarding petData", self.petData and self.petData.cargo)
      self.petData = nil
    end
    setHullAnimationStateIntent("close")

    --  This branch returns BEFORE workUpdate, so nothing below runs while the
    --  port sits empty -- no sweep, no refresh. A claim left here would survive
    --  until this port's next init cleared it. Release it on the way out.
    abandonTask("item removed")

    --  AND THE UNIT POSITION, for exactly the same reason.
    --
    --  publishUnitPosition also lives past this return, so an emptied port kept
    --  publishing the position its unit had when the item came out -- forever.
    --  anotherUnitIsCloser reads unitPosition ~= nil and busy == false as a
    --  live idle unit, so every emptied port left a GHOST that could veto drops
    --  near wherever it last stood. In a base with several ports, that suppresses
    --  dispatch for work nobody is ever going to do.
    --
    --  publishUnitPosition already handles this correctly -- it resolves the
    --  position to nil when there is no pet, and treats nil as movement. It was
    --  simply never reached.
    publishUnitPosition()
    return
  end

  --  Newly socketed, or a different unit swapped in.
  --
  --  Swap detection uses `seed` as the identity token. groundPet.lua volunteers
  --  monster.seed() through setPet, and it is captured OUTSIDE the echo guard,
  --  so petData.seed is populated within the same tick a unit is socketed.
  --  Distinct units therefore have distinct seeds, and a used item never
  --  matches a pristine one (which has no seed at all).
  --
  --  The one gap left is two never-spawned items exchanged inside a single
  --  tick, which is about as narrow as it gets and self-corrects on the next
  --  socket.
  if self.petData ~= nil and itemSeed(item) ~= self.petData.seed then
    trace("item swapped, outgoing seed", self.petData.seed)
    saveAndDespawn(true)
    self.petData = nil
    abandonTask("unit swapped out")
  end

  if self.petData == nil then
    self.petData = petDataFrom(item)
    cargoTrace("socket: petData built", self.petData and self.petData.cargo)
    if self.petData == nil then
      --  Not a pet item, or a malformed one. Do nothing rather than spawning
      --  something unintended.
      setHullAnimationStateIntent("close")
      abandonTask("socketed item is not a pet")
      return
    end

    --  A NEW UNIT GETS A FRESH ENVIRONMENT VERDICT.
    --
    --  envUnsuitable answers "can THIS chassis live at THIS port", so it belongs
    --  to the PAIR -- and it was being stored on the port alone. Consequence,
    --  measured: retire a flyer at a flooded port, socket an AQUATIC unit into
    --  the same port, and nothing spawns. The footprint has not changed, so the
    --  change test in update() never fires, envUnsuitable never clears, and the
    --  port refuses every chassis including the one that would have been fine.
    --  One retirement bricked the port.
    --
    --  Clearing here rather than in the swap branch above covers both routes in:
    --  a swap nils petData first and then arrives here, and a first socket
    --  arrives here directly.
    --
    --  AN UNSUITABLE UNIT SOCKETED INTO AN UNSUITABLE PORT NO LONGER SPAWNS AT
    --  ALL. It used to spawn and be retired within ENVIRONMENT_INTERVAL, and
    --  that flicker was accepted as the price of the retirement line saying why.
    --  The choreography changed the price: see dd.port.envpresence.
    --
    --  THE ENVIRONMENT TIMER IS ZEROED WITH THE SPAWN TIMER, and it has to be.
    --  The verdict is what holds the door shut, so a verdict that arrives up to
    --  ENVIRONMENT_INTERVAL after the socket arrives AFTER the door has opened
    --  and the unit has spawned -- which is the entire bug, moved rather than
    --  fixed. Both clocks start together or the gate is decorative.
    self.envUnsuitable = nil
    self.envRetired = nil
    self.envTypeUnreadable = nil

    self.environmentTimer = 0
    self.spawnTimer = 0
  end

  --  THE OFF SWITCH, RECONCILED HERE AND NOWHERE ELSE.
  --
  --  The handler only writes the flag; this is what makes it mean something, so
  --  there is one place that decides whether a unit should exist. That also
  --  covers the cases no handler sees: a world reloading with a port already
  --  switched off, and a disabled port having an item socketed into it.
  --
  --  NOT AN EARLY RETURN, AND THAT IS DELIBERATE. Four things below this point
  --  must keep running while a port is off -- the item write-back, the pane
  --  mirror, the module effect push and workUpdate's housekeeping -- and an
  --  early return here is exactly how the replant sweep once stopped running
  --  for an empty port. A disabled port still holds its coverage rect and its
  --  residency; it simply has no unit.
  local enabled = petportEnabled()

  --  THE DOOR NOW MEANS "OPEN FOR BUSINESS" RATHER THAN "SOMETHING IS
  --  SOCKETED", which is a small widening of what it said before. A switched-off
  --  port with an item in it reads as closed, which is what it is.
  --  AND IT STAYS OPEN WHILE A UNIT STILL EXISTS. petports_despawn now runs a
  --  one-second dematerialise rather than killing on the spot, so a port that
  --  closed the moment it asked would drop its door over a unit still fading in
  --  the doorway. self.fadingPetId outlives self.petId for exactly that window.
  --
  --  POLLED ON entityExists RATHER THAN TIMED. A fade that is interrupted --
  --  the unit killed some other way, the effect removed, the chunk unloaded --
  --  ends early, and a timer would hold the door open past it. The entity going
  --  away is the real signal and the only one that cannot disagree.
  if self.fadingPetId ~= nil and not world.entityExists(self.fadingPetId) then
    self.fadingPetId = nil
  end

  --  ENVIRONMENT. Retires a unit whose home has become uninhabitable, refuses to
  --  deploy one into a home it could not live in, and is what clears
  --  self.envUnsuitable when the port becomes habitable again.
  --
  --  ABOVE THE DOOR INTENT, AND THE ORDER IS THE FIX. It used to sit below,
  --  which was harmless while the verdict needed a live unit -- there was never
  --  a verdict on the tick a port was socketed anyway. Now there is, and reading
  --  it one line before it is written means a fresh placement into bad terrain
  --  tells the door "open" on one tick and "close" on the next. The hull would
  --  twitch, which is a smaller version of the same complaint.
  --
  --  IT ALSO RUNS WHILE THE PORT IS SWITCHED OFF. The verdict costs a footprint
  --  measure on a five-second timer and keeping it current means the door makes
  --  the right decision on the tick the player switches the port back ON, rather
  --  than opening and then correcting itself.
  self.environmentTimer = (self.environmentTimer or 0) - dt
  if self.environmentTimer <= 0 then
    self.environmentTimer = ENVIRONMENT_INTERVAL
    environmentCheck()

    --  SAME TIMER, SEPARATE QUESTION. environmentCheck asks whether the PORT's
    --  footprint suits the socketed chassis; mediumCheck asks whether the UNIT
    --  is currently somewhere its chassis may be. They share a cadence because
    --  they share a cause -- water moves -- and nothing else.
    --
    --  AFTER, NOT BEFORE. environmentCheck can retire the unit, and re-homing
    --  one that is already being withdrawn would be two rescues racing over the
    --  same entity.
    mediumCheck()
  end

  --  THE DOOR NOW ALSO MEANS "AND SOMETHING COULD LIVE IN HERE".
  --
  --  unitPresent STILL OVERRIDES IT, and that is not a loophole. A unit being
  --  retired is inside the port dematerialising, and dropping the hull on it is
  --  the thing self.fadingPetId was added to prevent. The door closes when the
  --  unit is actually gone, one poll later.
  --
  --  THE SPAWN GUARD BELOW IS WHAT MAKES THAT SAFE. During that same window the
  --  hull reads "open" while envUnsuitable is set and self.petId is already nil,
  --  which is exactly the shape the spawn block tests -- so without its own
  --  envUnsuitable check it would deploy a replacement into the terrain that
  --  just retired the last one.
  local unitPresent = self.petId ~= nil or self.fadingPetId ~= nil
  local habitable = self.envUnsuitable == nil

  setHullAnimationStateIntent(((enabled and habitable) or unitPresent) and "open" or "close")

  if not enabled then
    if self.petId ~= nil then
      sb.logInfo("PETPORT %s despawning unit: port is switched off. Its state and "
        .. "cargo are written back to the socketed item.", stationUniqueId())

      --  WRITES THE ITEM BACK FIRST, so cargo and resources survive. Switching a
      --  port off is not meant to cost the player anything.
      saveAndDespawn()
      abandonTask("port disabled")

      --  THE GHOST PROBLEM, SAME AS THE ITEM-REMOVED BRANCH ABOVE. A stale
      --  published position reads to anotherUnitIsCloser as a live idle unit and
      --  suppresses dispatch for work nobody will do.
      publishUnitPosition()
    end
  end

--  WHAT THE WORLD THINKS THIS UNIT'S DAMAGE TEAM IS.
--
--  AN INDEPENDENT READ, AND THAT IS THE ENTIRE POINT. The unit logs its own
--  transitions from entity.damageTeam() inside petports_applyModuleFlags -- that
--  is what the unit BELIEVES. This is world.entityDamageTeam from outside, which
--  is what everything else in the world actually resolves against.
--
--  THE TWO DISAGREEING IS A REAL FAILURE MODE, not a hypothetical: the same
--  type-level versus entity-level split is what exposed spawnPet overriding the
--  monstertype -- see fact.unit.spawnoverride. A unit that logs "chassis default
--  restored" while the world still sees ghostly looks identical, from the unit's
--  side, to a restore that worked.
--
--  CHANGE-GATED, so a settled unit costs one line at spawn and nothing after.
local function teamWatch()
  if self.petId == nil or not world.entityExists(self.petId) then
    self.watchedTeam = nil
    return
  end

  local team = world.entityDamageTeam(self.petId)
  local seen = team and (tostring(team.type) .. "/" .. tostring(team.team)) or "nil"

  if seen ~= self.watchedTeam then
    sb.logInfo("PETPORT %s unit %s damage team AS THE WORLD SEES IT: %s (was %s)",
      stationUniqueId(), sb.printJson(self.petId), seen, tostring(self.watchedTeam))
    self.watchedTeam = seen
  end
end

  --  HEALTH. The slow backstop for a unit that is stuck with no work to fail
  --  at. See healthCheck for why the interval and the stall limit are what they
  --  are -- the limit is set by cold-cache route probing, not by patience.
  self.healthTimer = (self.healthTimer or 0) - dt
  if self.healthTimer <= 0 then
    self.healthTimer = HEALTH_INTERVAL
    healthCheck()
  end

  --  Cheap and change-gated; see teamWatch.
  teamWatch()

  --  Spawn, or respawn after an unload/death.
  --
  --  `enabled` GATES THE WHOLE BLOCK RATHER THAN THE spawnPet CALL. Gating only
  --  the call would leave the timer counting down and the environment re-measure
  --  running every second on a port that is switched off -- work with no
  --  possible consumer. It also means an enable starts from a zeroed timer,
  --  which the handler sets, instead of from wherever the countdown happened to
  --  be.
  if enabled and (self.petId == nil or not world.entityExists(self.petId)) then
    self.spawnTimer = self.spawnTimer - dt
    if self.spawnTimer <= 0 then
      if self.petId ~= nil then
        --  It existed and now does not. Keep whatever state we last heard.
        self.petId = nil
      end

      --  THE DOOR HAS TO FINISH OPENING FIRST, AND IT IS CHECKED FIRST.
      --
      --  "opening" is a ten-frame transition into "open", so testing for the
      --  terminal state is what sequences the two -- a unit materialising
      --  behind a shut hatch is the abruptness this whole change exists to
      --  remove. A port whose door never reaches "open" simply never spawns,
      --  which is correct: that is a port that is closed.
      --
      --  ORDER MATTERS FOR COST. This used to sit BELOW the environment
      --  re-measure and share RESPAWN_GRACE with it, which meant a door that
      --  finished mid-window left the port idle for the remainder -- the
      --  palpable pause between the hatch opening and the unit appearing.
      --  Checking it first lets a not-yet-open door cost one string compare and
      --  come straight back, while portMedia() still only runs on the slow
      --  timer.
      if animator.animationState("hullState") ~= "open" then
        self.spawnTimer = DOOR_POLL
      else
        --  DO NOT DEPLOY INTO AN ENVIRONMENT THAT JUST RETIRED A UNIT.
        --
        --  MOSTLY UNREACHABLE NOW AND KEPT ANYWAY. The door is gated on the same
        --  verdict, so an unsuitable port normally never reaches "open" and
        --  never gets here. The exception is the dematerialise window: the hull
        --  is held open by unitPresent while the retired unit fades, and
        --  self.petId is already nil, so this branch runs with the terrain still
        --  unsuitable. Without this test the port would deploy a replacement
        --  into it and retire that one too.
        --
        --  THE RE-MEASURE THAT USED TO LIVE HERE IS GONE. It existed because
        --  environmentCheck could not clear its own verdict with no unit to ask
        --  -- so the reopening had to happen somewhere a unit was about to be
        --  spawned. environmentCheck answers from the monstertype now and clears
        --  itself on its own timer, which is where recovery belongs.
        --
        --  IT COULD NOT HAVE STAYED. Gating the door on envUnsuitable puts this
        --  whole block behind a hull that will never reach "open" while the
        --  verdict stands, so a re-measure here would be unreachable exactly when
        --  it was needed and the port would never recover from a flood.
        if self.envUnsuitable == nil then
          spawnPet()
        end

        self.spawnTimer = RESPAWN_GRACE
      end
    end
  end

  --  ACTIVE TIME -- the honest denominator from dd.pane.ratesnottotals, and
  --  GATED ON HAVING A TASK: idle-with-no-work does not count. Same definition
  --  of "working" the fuel design already uses -- hunger drains only while
  --  working -- so the clock and the stomach agree. A recall or a diagnostic
  --  filler still counts; the unit is on the clock, just not hauling.
  --
  --  NO dirty AND NO FLUSH -- see metrics.add. This rides the slow write below,
  --  which is the next statement, so at most WRITE_INTERVAL of it is ever at
  --  risk.
  if self.petId ~= nil and world.entityExists(self.petId) then
    if self.task ~= nil then
      metrics.add("active", dt)
    end

    --  THE ODOMETER. Per-tick wrap-aware step between successive positions.
    --
    --  ADDS ONLY WHILE ON A TASK -- same gate as the clock above, so traveled
    --  and active measure the same definition of working and idle pacing near
    --  the port counts toward neither. THE SAMPLING IS DELIBERATELY NOT GATED:
    --  the baseline must follow the unit through idle time, or the first
    --  working tick after an idle stroll measures the whole stroll as one
    --  step -- and past ten tiles the threshold below would then discard real
    --  legwork as a teleport.
    --
    --  world.magnitude RATHER THAN RAW SUBTRACTION, because worlds wrap
    --  horizontally and a unit working near the seam would otherwise bank the
    --  whole planet's circumference in one tick.
    --
    --  THE THRESHOLD IS A DISCONTINUITY DETECTOR, NOT A SPEED LIMIT. Vent hops,
    --  recalls and respawns all move the unit by setPosition, and an odometer
    --  that credits a teleport is measuring the network's shortcuts, not the
    --  unit's legwork. Ten tiles in one tick is 600 tiles/s -- nothing walks,
    --  flies or swims that fast -- so past it the step is discarded and the
    --  baseline re-seeded where the unit reappeared.
    local position = world.entityPosition(self.petId)

    if position ~= nil then
      if self.odometerLast ~= nil and self.task ~= nil then
        local step = world.magnitude(position, self.odometerLast)
        if step < 10 then
          metrics.add("traveled", step)
        end
      end
      self.odometerLast = position
    end
  else
    --  No unit, no baseline. Without this the first sample after a respawn
    --  measures against wherever the previous unit last stood.
    self.odometerLast = nil
  end

  --  Immediate on a durable change, otherwise on the slow timer.
  self.writeTimer = self.writeTimer - dt
  if self.dirty or self.writeTimer <= 0 then
    writeBackToItem()
    self.writeTimer = WRITE_INTERVAL
  end

  --  mirrorPaneState USED TO BE HERE, and the comment justifying the position
  --  was wrong about where the hazard was. It said the no-item return "sits
  --  inside workUpdate", so sitting above workUpdate was enough. It does not --
  --  it is in update() itself, ~190 lines above this point -- so an empty port
  --  returned before ever reaching the mirror and the pane kept reading the
  --  last blob written while a unit was still socketed. Moved to the top of
  --  update; see the note there.

  --  ABOVE workUpdate, and it is not a hypothetical: a unit whose modules were
  --  removed to empty must still be told, or a port that returned early would
  --  leave a lamp burning on a unit carrying nothing.
  --
  --  IT IS STILL BELOW THE TWO EARLY RETURNS IN update(), and that is checked
  --  rather than assumed: both of them are paths with no unit at all -- nothing
  --  socketed, or something socketed that is not a pet -- so there is no unit
  --  to push effects to and nothing to leave burning. If a third early return
  --  is ever added on a path that DOES have a unit, this has to move up with
  --  the mirror. See the note beside mirrorPaneState.
  --
  --  UNGATED BY ANY TIMER. The signature compare inside is the gate, and it is
  --  a string equality against a value that changes only when the module set or
  --  the entity does -- cheaper than the timer that would guard it.
  pushModuleEffects()

  workUpdate(dt)
end

function onInteraction(args)
  --  Falls through to the container UI declared by uiConfig on the object.
  return config.getParameter("interactAction")
end
