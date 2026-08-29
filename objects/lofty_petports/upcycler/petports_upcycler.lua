--  PETPORTS -- UPCYCLER, OBJECT SCRIPT
--
--  Converts surplus items into pet fuel. The machine half only: it knows about
--  its own three slots and its own rule list, and nothing about petports,
--  networks or the census. Routing -- deciding WHICH surplus arrives here -- is
--  the port's job and is not built yet.
--
--  THE RULE LIST IS THE DESTROY LIST, AND IT IS THE ONLY AUTHORITY.
--
--  An item in the input slot is converted if and only if a rule names it. That
--  covers the hand-drop case for free: something the player dropped in to look
--  at sits there, visible and retrievable, and the pane says why. It also means
--  an unconfigured machine is inert no matter what is in it, which is the
--  behaviour the whole feature was designed around.
--
--  Deliberately NOT "convert whatever is in the input". A hand-drop is fairly
--  explicit consent, but "I dropped it in to see what happened" is a mistake
--  people make, and this is the one device in the mod that cannot be undone.
--
--  THE THRESHOLD IS NOT CONSULTED HERE. A rule is { item, max }, and `max` is a
--  statement about how much the NETWORK should keep -- it governs what gets
--  routed here, not what happens once it arrives. By the time a stack is in the
--  input slot the decision to convert it has already been made. Checking it
--  again would need a census this object does not have and would strand
--  anything delivered a moment before the count changed.
--
--  STATE LIVES IN PARAMETERS, EXCEPT POINTS.
--
--  Rules and enabled are parameters: they travel with the dropped item, and a
--  petport can read them with world.getObjectParameter during the same scan
--  pass that finds beacons. Accumulated points are `storage` instead -- world
--  state that survives a reload but has no business following the item, and
--  writing a parameter several times a second would be the wrong tool anyway.
--
--  ABSENCE IS THE OFF STATE. A freshly placed upcycler has no `enabled`
--  parameter at all, and no parameter means OFF. Same engine behaviour that
--  made pristine and configured beacons unstackable, used deliberately here.
--  Note the asymmetry with beacons, which default ON: a loose beacon can only
--  land in a container that was already a target, so it cannot task anything
--  new. An upcycler that starts running can destroy things.

local DEBUG = true

--  sb.logInfo takes %s AND NOTHING ELSE. %d, %q and %.2f all raise "Improper
--  lua log format specifier" at runtime, which is a crash in the middle of
--  whatever was being diagnosed. Pre-format with string.format, which has no
--  such limit, and hand the logger one string.
--
--  pcall'd because a debug line must never be the thing that breaks a script.
local function dbg(fmt, ...)
	if not DEBUG then return end
	local ok, text = pcall(string.format, fmt, ...)
	sb.logInfo("PETPORTS upcycler: %s", ok and text or ("<badformat> " .. tostring(fmt)))
end

--  Parameter keys. Prefixed, because these are read from OTHER scripts -- the
--  pane now, a petport later -- and an unprefixed "rules" on a shared object
--  config is an invitation to collide with something.
local RULES_KEY = "petports_upcyclerRules"
local ENABLED_KEY = "petports_upcyclerEnabled"

--  MAY UNITS EAT STRAIGHT OUT OF THE OUTPUT SLOT.
--
--  DEFAULTS OFF, WHICH DIVERGES FROM THE BEACONS ON PURPOSE -- see storedFeeder
--  for the reasoning.
local FEEDER_KEY = "petports_upcyclerFeeder"

--  BANKED POINTS, MIRRORED INTO A PARAMETER SO THEY SURVIVE THE PICKAXE.
--
--  `storage` already survives a world reload -- it is world state, serialised
--  with everything else -- so reload was never the gap. Breaking the machine
--  was: storage does not follow an item, so a player relocating a half-full
--  upcycler lost the progress.
--
--  MIRRORED PERIODICALLY, NOT PER TICK. A setConfigParameter twelve times a
--  second to track a number that changes by one is the wrong tool. Flushed on a
--  slow timer and again on die(), so the worst case is losing a few seconds of
--  progress rather than all of it -- and the timer means it does not depend on
--  die()'s write reaching the drop, which is still unverified.
--  The flavor table: which items are reagents, what each is worth, and which
--  treat a flavor produces. Same module the pane uses, so the two cannot
--  disagree about what a reagent is.
require "/scripts/lofty_petports/petports_flavors.lua"

local POINTS_KEY = "petports_upcyclerPoints"

--  THE BLIP QUEUE, MIRRORED THE SAME WAY POINTS ARE. A machine mined with four
--  spicy blips left should come back with four spicy blips left: the player
--  already spent the reagent.
local BLIPS_KEY = "petports_upcyclerBlips"

--  PUBLISHED SO A PORT CAN SEE A STALLED MACHINE.
--
--  A port decides a fuel trip is worth making from how much is in the output
--  slot, with two exceptions meaning "no more are coming": the slot is full, or
--  the input is empty. Flavored treats add a third that neither covers -- the
--  machine has points banked and the next treat WILL NOT STACK with what is
--  already sitting there.
--
--  Measured: eight plain treats in the output, a spicy one queued, dirt still
--  in the input. Under the batch floor, not full, not idle -- so the port kept
--  reporting "still converting and not yet worth a trip" while the machine sat
--  at 1000/1000 indefinitely. It only resumed when the treats were pulled out
--  by hand.
--
--  A PARAMETER RATHER THAN AN INFERENCE, because the port cannot work this out:
--  it would have to know which flavor is queued next, which means teaching it
--  the whole charge. The machine already knows, so it says so.
local BLOCKED_KEY = "petports_upcyclerBlocked"

--  How many treats a charge can hold. The reagent slot's display has this many
--  cells and a reagent only spends if ALL of its weight fits.
--
--  EIGHT BECAUSE THE HEAVIEST REAGENT IS EIGHT. That makes "wait for the bar to
--  empty" the worst case a player ever faces, which is a bar's length rather
--  than an unbounded backlog of reagents they committed to and cannot recall.
--  A deeper queue would let them bank flavours they have changed their mind
--  about; a shallower one would make augment materials unusable.
local BLIP_CAPACITY = 8

--  Container offsets are ZERO-based. The keys world.containerItems hands back
--  are ONE-based -- documented engine behaviour, and the same fact
--  SLOT_KEY_TO_OFFSET pays for in petports_petport.lua. Everything here uses
--  the offset-taking calls, so no conversion is needed.
--  REAGENT IN THE MIDDLE, OUTPUT LAST, AND THE ORDER IS A LAYOUT DECISION.
--
--  ContainerPane binds exactly two itemgrids, so three slots means one grid
--  holds two adjacent cells and the other holds one placed freely. The pane
--  draws input -> reagent -> output left to right, so the PAIR has to be input
--  and reagent; the loose one is the output.
--
--  This was input 0, output 1, reagent 2, which put the output in the middle of
--  the pair and the reagent off on its own -- the wrong two joined together.
--  Proxy itemslots were tried to escape it and rolled back.
--
--  CHANGING THESE RENAMES WHAT IS ALREADY IN A PLACED MACHINE. A machine
--  holding treats in the old slot 1 now has them in its reagent slot, and a
--  reagent in the old slot 2 is now in its output. Nothing is destroyed and
--  nothing is consumed wrongly -- a treat is not a reagent, so it is refused --
--  but the contents look shuffled. Empty machines before updating, or move the
--  items back by hand afterwards.
--
--  petports_petport.lua carries its own copies as MACHINE_SLOT_*. They must
--  agree with these; there is no shared header.
local SLOT_INPUT = 0
local SLOT_REAGENT = 1
local SLOT_OUTPUT = 2

local FUEL_ITEM = "petports_petfuel"

--  NEVER CONVERTED, WHATEVER THE RULES SAY.
--
--  ONE TAG, DECLARED BY THE ITEMS THEMSELVES. This used to be a list of tags
--  the machine knew about -- petports_beacon, petports_unit, petports_fuel --
--  which meant every new protected item had to teach the upcycler about itself.
--  `petports_no_upcycling` inverts that: an item says "not this" and the
--  machine never needs updating, including for items from other mods.
--
--  Rules are made by naming an item, and the pane's sample slot means the
--  player can name anything they are holding. Losing a configured beacon is
--  annoying; losing a unit is unrecoverable and is the worst outcome available
--  in this mod. Pet Treats carry the tag too, so output can never be laundered
--  back into output -- the value floor means even a zero-price item is worth a
--  point, so price alone would not have closed that loop.
local EXEMPT_TAG = "petports_no_upcycling"

--  ---------------------------------------------------------------------------
--  STORED STATE
--  ---------------------------------------------------------------------------

--  A rule is { item = "<name>", max = <number> }.
--
--  TYPE-CHECKED ON EVERY READ, NOT NIL-CHECKED. A cleared parameter is stored
--  as an explicit JSON null rather than a removed key, so an emptied rule list
--  reads back as a null and a null is not a table.
local function storedRules()
	local stored = config.getParameter(RULES_KEY)
	if type(stored) ~= "table" then return {} end

	local rules = {}

	for _, rule in ipairs(stored) do
		if type(rule) == "table" and type(rule.item) == "string" and rule.item ~= "" then
			table.insert(rules, { item = rule.item, max = tonumber(rule.max) or 0 })
		end
	end

	return rules
end

local function storedEnabled()
	local stored = config.getParameter(ENABLED_KEY)
	if stored == nil then return false end
	return stored == true
end

--  MAY UNITS FEED FROM THIS MACHINE'S OUTPUT.
--
--  ABSENT MEANS OFF, AND THAT IS THE OPPOSITE OF THE BEACONS. Worth stating
--  plainly because the inconsistency is deliberate and will otherwise read as an
--  oversight.
--
--  A BEACON DEFAULTS ON because a crate a player has told the network about is
--  one they expect the network to use. An upcycler is not a crate -- the player
--  told the network "this is a converter", never "this is a pantry".
--
--  AND IT IS THE FIRST-ORDER OPTIMAL PLACE TO EAT, which is the real reason.
--  This machine MAKES the treats, so a unit that may graze it will always graze
--  it: no drain trip, no deposit, no fetch. Defaulting it on would quietly
--  retire the entire fuel logistics loop the moment the fuel system lands, and a
--  player would never see the behaviour they built the crates for. Off makes
--  grazing an optimisation somebody chooses, which is the interesting version.
--
--  It also matches this object's own convention: `enabled` is absent-and-off on
--  a freshly placed machine, for the same reason -- a machine does nothing until
--  it is told to.
local function storedFeeder()
	local stored = config.getParameter(FEEDER_KEY)
	if stored == nil then return false end
	return stored == true
end

--  Is this item name named by a rule?
--
--  A PURE FUNCTION OF THE NAME, and that is the same property
--  petports_filterAccepts protects: it means no descriptor, no root.itemConfig,
--  no re-roll exposure, and a lookup cheap enough to run per tick.
local function ruleFor(name)
	if type(name) ~= "string" then return nil end

	for _, rule in ipairs(storedRules()) do
		if rule.item == name then return rule end
	end

	return nil
end

local function stateSummary()
	local parts = {}

	for _, rule in ipairs(storedRules()) do
		table.insert(parts, string.format("%s>%s", rule.item, tostring(rule.max)))
	end

	return string.format("enabled=%s points=%s rules=[%s]",
		tostring(storedEnabled()), tostring(storage.points or 0),
		#parts == 0 and "none" or table.concat(parts, " "))
end

--  ---------------------------------------------------------------------------
--  VALUE
--  ---------------------------------------------------------------------------

--  What a single one of these is worth, in points.
--
--  PRICE IS THE ONLY UNIVERSAL VALUE AXIS the engine offers, it is on every
--  item, and it is the same number the sell-for-pixels path uses -- so
--  "capture the value without the pixel detour" is expressible rather than
--  hand-authored. Vanilla's cropshipper values its cargo exactly this way.
--
--  THE FULL DESCRIPTOR, NOT THE NAME. root.itemConfig re-runs a generated
--  item's build script with a fresh time-based seed when the descriptor carries
--  no seed, so pricing a specific sword by name returns a different number
--  every call. The descriptor from containerItemAt carries its parameters, so
--  it prices the actual item.
--
--  MEMOISED BY NAME ONLY WHEN THERE ARE NO PARAMETERS, for the same reason: two
--  stacks sharing a name can be genuinely different items, and caching the
--  first one's price would misprice the second.
local function valueOf(descriptor)
	if type(descriptor) ~= "table" or type(descriptor.name) ~= "string" then
		return self.valueFloor
	end

	local plain = descriptor.parameters == nil
		or next(descriptor.parameters) == nil

	if plain and self.valueCache[descriptor.name] ~= nil then
		return self.valueCache[descriptor.name]
	end

	local value = self.valueFloor
	local ok, resolved = pcall(root.itemConfig, descriptor)

	if ok and type(resolved) == "table" and type(resolved.config) == "table" then
		local price = tonumber(resolved.config.price) or 0

		--  THE FLOOR IS PER ITEM, NOT PER STACK, and that is what makes the
		--  intended arithmetic work: dirt is worthless, a stack is 1000, and a
		--  stack of dirt is therefore exactly one Pet Treat. Read the other way
		--  it would be one Treat per stack regardless of size.
		if price > self.valueFloor then value = price end
	end

	if plain then self.valueCache[descriptor.name] = value end

	return value
end

--  Refused regardless of rules. See EXEMPT_TAG.
local function exempt(descriptor)
	if type(descriptor) ~= "table" or type(descriptor.name) ~= "string" then
		return true
	end

	if self.exemptCache[descriptor.name] ~= nil then
		return self.exemptCache[descriptor.name]
	end

	local verdict = false
	local ok, resolved = pcall(root.itemConfig, { name = descriptor.name, count = 1 })

	if ok and type(resolved) == "table" and type(resolved.config) == "table" then
		for _, tag in ipairs(resolved.config.itemTags or {}) do
			if tag == EXEMPT_TAG then
				verdict = true
				break
			end
		end
	end

	--  Cached by NAME, which is safe here where valueOf's cache is not: an
	--  item's tags are a property of its definition and no build script
	--  invents them per instance.
	self.exemptCache[descriptor.name] = verdict

	return verdict
end

--  ---------------------------------------------------------------------------
--  CONVERSION
--  ---------------------------------------------------------------------------

--  CHANGE-GATED, NOT SUPPRESSED. A log-once hides a stuck state and a repeating
--  log buries everything else. This reads as "still refusing" rather than
--  "stopped running", which is the distinction that matters when a machine sits
--  idle for ten minutes.
local function state(text)
	if self.state == text then return end
	self.state = text
	dbg("%s", text)
end

--  ---------------------------------------------------------------------------
--  THE REAGENT CHARGE
--  ---------------------------------------------------------------------------
--
--  storage.blips is a QUEUE of flavor ids, at most BLIP_CAPACITY long. One
--  entry is one treat that will come out flavored. The head is the oldest, so a
--  charge of two spicy then six sweet pays out spicy, spicy, then six sweet --
--  which is the order the player put them in and the only order they can
--  predict.
--
--  ONE REAGENT AT A TIME, AND ONLY IF ALL OF IT FITS. A weight-8 reagent waits
--  for an empty bar rather than part-filling. That is what makes "ride out the
--  rest" a reasonable thing to ask of a player who changed their mind: the
--  worst case is one bar's length, never a backlog of reagents they have
--  already committed and cannot recall.
--
--  THE REST OF THE STACK STAYS IN THE SLOT, which is the whole reason to take
--  one at a time rather than swallowing the stack. Forty meat in the slot is
--  thirty-nine meat the player can still pull back out.

local function blipQueue()
	if type(storage.blips) ~= "table" then storage.blips = {} end
	return storage.blips
end

--  Take the next flavor off the charge, or nil if it is empty.
local function blipTake()
	local queue = blipQueue()
	if #queue == 0 then return nil end
	return table.remove(queue, 1)
end

--  Spend one reagent from the slot if the whole of it fits.
--
--  Returns true if something was consumed, so the caller can flush.
--  Say why nothing was consumed, ONCE per distinct reason.
--
--  consumeReagent runs every tick and had four silent exits, so "the reagent is
--  not being taken" and "the reagent slot is empty" produced identical logs:
--  none at all. Change-gated on the message, so a machine sitting in one state
--  says so once rather than sixty times a second.
local function reagentState(fmt, ...)
	local text = string.format(fmt, ...)
	if self.lastReagentState == text then return end
	self.lastReagentState = text
	sb.logInfo("PETPORTS upcycler reagent: %s", text)
end

local function consumeReagent()
	local queue = blipQueue()
	local room = BLIP_CAPACITY - #queue

	if room <= 0 then
		reagentState("charge full at %s, nothing can be spent",
			sb.printJson(#queue))
		return false
	end

	--  containerItemAt, NOT containerItems INDEXED BY OFFSET + 1.
	--
	--  OBSERVED, CAUSE NOT ESTABLISHED: with dirt in the input and a block in
	--  the output, pulling the dirt out made the OUTPUT appear to empty in the
	--  pane. That is what indexing a compacted list would do -- every entry
	--  shifts down one -- but petports_filterMisfits treats the same table's
	--  keys as slot indices and has worked for a long time, including comparing
	--  them against a beacon's own slot. Those two cannot both be true, so the
	--  reason for the symptom is still open.
	--
	--  What IS certain is that containerItemAt takes an OFFSET and answers about
	--  that slot whatever else the container holds. It cannot be wrong under
	--  either reading, which is why every slot lookup in this file now uses it.
	--  Do not put the offset + 1 form back to save a call.
	local held = world.containerItemAt(entity.id(), SLOT_REAGENT)

	if type(held) ~= "table" or type(held.name) ~= "string" then
		--  Names the OFFSET it looked at. If a reagent is visibly sitting in the
		--  pane and this says the slot is empty, the pane and the machine
		--  disagree about which container slot that grid is bound to.
		reagentState("slot %s is empty (%s room in the charge)",
			sb.printJson(SLOT_REAGENT), sb.printJson(room))
		return false
	end

	local entry = petports_reagentFor(held.name)

	--  FAIL CLOSED. An item that is not a reagent sits in the slot doing
	--  nothing, rather than being eaten for no effect. The pane is what tells
	--  the player why; the machine's job is to not destroy it.
	if entry == nil then
		reagentState("%s in slot %s is not a reagent", tostring(held.name),
			sb.printJson(SLOT_REAGENT))
		return false
	end

	local weight = tonumber(entry.weight) or 0

	if weight <= 0 then
		reagentState("%s has no usable weight (%s)", tostring(held.name),
			tostring(entry.weight))
		return false
	end

	--  ALL OR NOTHING. Part-filling would let a player queue a flavor they can
	--  never finish paying for and could not clear without emptying the bar
	--  anyway.
	if weight > room then
		reagentState("%s needs %s blip(s), only %s free",
			tostring(held.name), sb.printJson(weight), sb.printJson(room))
		return false
	end

	local taken = world.containerTakeNumItemsAt(entity.id(), SLOT_REAGENT, 1)

	--  Nothing came back: something else took it between the read and the take.
	--  Not an error, just a wasted tick.
	if type(taken) ~= "table" or (taken.count or 0) < 1 then
		--  The read found it and the take did not. That is the slot indexing
		--  disagreeing with itself, which should be impossible now that both
		--  use the same offset.
		reagentState("take FAILED on slot %s holding %s",
			sb.printJson(SLOT_REAGENT), tostring(held.name))
		return false
	end

	for _ = 1, weight do
		table.insert(queue, entry.flavor)
	end

	self.lastReagentState = nil

	sb.logInfo("PETPORTS upcycler: spent 1 %s -> %s x%s blip(s), charge now %s of %s",
		held.name, tostring(entry.flavor), sb.printJson(weight),
		sb.printJson(#queue), sb.printJson(BLIP_CAPACITY))

	return true
end

--  Move banked points into the output slot, one Treat at a time.
--
--  Returns true if the output can still take more. The caller uses that to
--  decide whether to keep eating input: a machine that consumes while unable to
--  pay out would destroy the input and show nothing for it, which is exactly
--  the failure mode this whole design exists to avoid.
local function emitFuel()
	while (storage.points or 0) >= self.pointsPerFuel do
		--  PEEKED, NOT TAKEN. The output slot can refuse -- full, or holding
		--  something the player parked there -- and a blip spent on a treat that
		--  never appeared is a reagent the player paid for and did not get.
		--  It only comes off the queue once the item is placed.
		local queue = blipQueue()
		local flavor = queue[1]
		local item = FUEL_ITEM

		if flavor ~= nil then
			--  A flavor whose treat does not resolve falls back to a plain
			--  treat rather than stalling the machine. petports_flavorItem logs
			--  it; the player gets something either way.
			item = petports_flavorItem(flavor) or FUEL_ITEM
		end

		local leftover = world.containerPutItemsAt(entity.id(),
			{ name = item, count = 1 }, SLOT_OUTPUT)

		--  A DESCRIPTOR COMES BACK, NOT A COUNT. Anything with a positive count
		--  means the slot would not take it -- full, or holding something else
		--  the player parked there.
		if type(leftover) == "table" and (leftover.count or 0) > 0 then
			state(string.format("output blocked: %s point(s) banked, cannot place a %s",
				tostring(storage.points), item))
			storage.blocked = true
			return false
		end

		--  Placed, so now the blip is spent.
		if flavor ~= nil then blipTake() end

		storage.points = storage.points - self.pointsPerFuel
		storage.blocked = false
		dbg("emitted 1 %s%s, %s point(s) left banked, %s blip(s) left",
			item, flavor ~= nil and " (flavored)" or "",
			tostring(storage.points), tostring(#blipQueue()))
	end

	--  Fell out of the loop, so there is nothing banked worth emitting and
	--  nothing is stuck. Clearing it here as well as on a successful place
	--  covers the machine draining below a full treat's worth.
	storage.blocked = false
	return true
end

--  Mirror banked points into a parameter, on a slow timer. See POINTS_KEY.
local function flushPoints(dt)
	self.flushTimer = (self.flushTimer or 0) - dt
	if self.flushTimer > 0 then return end

	self.flushTimer = self.pointsFlushInterval

	--  Change-gated: an idle machine should not rewrite the same number every
	--  five seconds forever.
	local queue = blipQueue()

	--  Compared as a string because the queue is a table: two tables with the
	--  same contents are never equal, so an identity test would rewrite the
	--  parameter every five seconds forever.
	local signature = table.concat(queue, ",")

	local blocked = storage.blocked == true

	if self.flushedPoints == storage.points
	   and self.flushedBlips == signature
	   and self.flushedBlocked == blocked then return end

	self.flushedPoints = storage.points
	self.flushedBlips = signature
	self.flushedBlocked = blocked

	object.setConfigParameter(POINTS_KEY, storage.points)
	object.setConfigParameter(BLOCKED_KEY, blocked)

	--  AN EMPTY QUEUE IS WRITTEN AS AN EMPTY TABLE, not removed.
	--  setInstanceValue(key, nil) writes JSON null rather than deleting the key,
	--  and a null read back as a table is a crash rather than an empty charge.
	object.setConfigParameter(BLIPS_KEY, queue)
end

function update(dt)
	storage.points = storage.points or 0
	flushPoints(dt)

	--  THE CHARGE LOADS WHETHER THE MACHINE IS RUNNING OR NOT, and it has to be
	--  above the switched-off return to do that.
	--
	--  It used to sit below, so an off machine ignored its reagent slot
	--  entirely. That is the DEFAULT experience rather than an edge case:
	--  adding a rule switches the machine off, so the natural order -- add a
	--  rule, drop a reagent in, set a threshold, switch on -- put the reagent in
	--  during the one window where it was ignored, with no log line and no
	--  warning.
	--
	--  LOADING A CHARGE IS NOT CONVERSION. The off switch exists so a machine
	--  cannot destroy input it was not configured for; spending a reagent
	--  destroys nothing the player did not explicitly ask for by putting it in
	--  that slot, and the blips persist across off and on. So there is nothing
	--  for the gate to protect here.
	consumeReagent()

	if not storedEnabled() then
		state("idle: machine is switched off")
		return
	end

	--  Pay out first. Points banked from a previous tick should become fuel
	--  before anything else is eaten, so a machine that was blocked and has
	--  since been emptied recovers on its own.
	local canEmit = emitFuel()

	--  AGAIN AFTER PAYING OUT. Emitting frees blips, and a reagent that did not
	--  fit a moment ago may fit now -- without this a weight-8 reagent would
	--  wait a whole extra tick after the bar emptied, which reads as the
	--  machine hesitating.
	consumeReagent()

	local input = world.containerItemAt(entity.id(), SLOT_INPUT)

	if type(input) ~= "table" or type(input.name) ~= "string" then
		state("idle: input slot empty")
		self.carry = 0
		return
	end

	if exempt(input) then
		state(string.format("REFUSING %s: exempt from conversion regardless of rules",
			input.name))
		self.carry = 0
		return
	end

	if ruleFor(input.name) == nil then
		--  THE HAND-DROP CASE. Named explicitly in the log because "nothing is
		--  happening" and "nothing is happening because you have not told me I
		--  may" are the same picture from outside.
		state(string.format("REFUSING %s: no rule names it, so it will not be converted",
			input.name))
		self.carry = 0
		return
	end

	if not canEmit then
		--  Already logged by emitFuel. Do not eat input we cannot pay for.
		self.carry = 0
		return
	end

	--  FRACTIONAL RATE, CARRIED BETWEEN TICKS. At 5 items a second and a
	--  scriptDelta of 5 this is roughly one item per call, but neither number
	--  should be load-bearing -- carrying the remainder means the rate is
	--  honoured whatever the tick cadence turns out to be.
	self.carry = (self.carry or 0) + dt * self.itemsPerSecond

	local want = math.floor(self.carry)
	if want < 1 then return end

	local taken = world.containerTakeNumItemsAt(entity.id(), SLOT_INPUT, want)

	if type(taken) ~= "table" or (taken.count or 0) < 1 then
		--  The slot emptied between the read and the take, or something else
		--  moved it. Not an error; just nothing to do this tick.
		self.carry = 0
		return
	end

	self.carry = self.carry - taken.count

	local gained = valueOf(taken) * taken.count
	storage.points = storage.points + gained

	state(string.format("converting %s at %s point(s) each", taken.name,
		tostring(valueOf(taken))))

	--  DELIBERATELY NOT LOGGED PER ITEM. At five a second this was the noisiest
	--  thing in the mod by a wide margin and buried everything around it -- the
	--  exact failure the logging discipline section warns about. The
	--  change-gated state line above says what is being converted and at what
	--  rate; emitFuel says when one is finished; the pane's progress bar is
	--  where the tick-by-tick answer belongs.
	emitFuel()
end

function init()
	--  STORAGE WINS WHERE IT EXISTS, PARAMETER FILLS IN WHERE IT DOES NOT.
	--
	--  A reload keeps storage, so it is already right and the parameter is a
	--  stale mirror. A machine placed from a dropped item has empty storage, so
	--  the parameter is the only copy and gets adopted. No merge, no max(), no
	--  ambiguity about which is newer.
	if storage.points == nil then
		storage.points = tonumber(config.getParameter(POINTS_KEY)) or 0

		if storage.points > 0 then
			sb.logInfo("PETPORTS upcycler: adopted %s banked point(s) from a placed item",
				sb.printJson(storage.points))
		end
	end

	--  Same rule for the charge: storage wins where it exists, the parameter
	--  fills in where it does not. A machine mined mid-charge comes back owing
	--  the player the flavors they already paid for.
	if storage.blips == nil then
		local adopted = config.getParameter(BLIPS_KEY)
		storage.blips = type(adopted) == "table" and adopted or {}

		--  TRIMMED ON ADOPTION. A parameter written by an older build, or a
		--  hand-edited one, could be longer than the bar can draw -- and a
		--  charge the display cannot show is a charge the player cannot reason
		--  about.
		while #storage.blips > BLIP_CAPACITY do
			table.remove(storage.blips)
		end

		if #storage.blips > 0 then
			sb.logInfo("PETPORTS upcycler: adopted a charge of %s blip(s) from a placed item",
				sb.printJson(#storage.blips))
		end
	end

	self.carry = 0
	self.flushTimer = 0
	self.valueCache = {}
	self.exemptCache = {}

	--  TUNING KNOBS, IN CONFIG RATHER THAN IN CODE.
	--
	--  Fuel burn does not exist yet, and the only number that will ultimately
	--  matter is fuel-from-one-harvest-cycle's-surplus over fuel-burned-by-the-
	--  units-that-ran-it. That ratio cannot be picked until there is something
	--  to measure, so it must be movable without touching Lua.
	self.pointsPerFuel = config.getParameter("petports_pointsPerFuel", 1000)
	self.valueFloor = config.getParameter("petports_valueFloor", 1)
	self.itemsPerSecond = config.getParameter("petports_itemsPerSecond", 5)
	self.pointsFlushInterval = config.getParameter("petports_pointsFlushInterval", 5.0)

	dbg("init at %s -- %s", sb.printJson(entity.position()), stateSummary())

	--  THE PANE WRITES THE WHOLE STATE, NOT A DIFF.
	--
	--  It holds the authoritative copy while open and sends the complete rule
	--  list on every edit, which is what the beacon pane already does. A diff
	--  protocol needs both ends to agree on a base version and there is nothing
	--  here worth that.
	--
	--  No token, unlike the beacon: a ScriptPane addressing a HELD activeitem
	--  cannot tell which hotbar slot it means. A pane addressing an entity id
	--  has exactly one target and it cannot change underneath the pane.
	message.setHandler("petports_upcyclerWrite", function(_, _, payload)
		if type(payload) ~= "table" then
			dbg("write REJECTED: payload was %s", type(payload))
			return false
		end

		if payload.rules ~= nil then
			--  Written through unvalidated on purpose: storedRules validates on
			--  every READ, so a malformed list cannot survive into behaviour,
			--  and rejecting here would lose the player's edit without saying
			--  why.
			object.setConfigParameter(RULES_KEY, payload.rules)
		end

		if payload.enabled ~= nil then
			object.setConfigParameter(ENABLED_KEY, payload.enabled == true)
		end

		if payload.feeder ~= nil then
			object.setConfigParameter(FEEDER_KEY, payload.feeder == true)
		end

		--  So the next tick re-evaluates rather than sitting on a stale verdict.
		self.state = nil

		dbg("write ACCEPTED -- %s", stateSummary())
		return true
	end)

	--  For a petport, later. The pane reads parameters directly with
	--  world.getObjectParameter -- verified working from a container pane
	--  script -- so nothing calls this yet.
	message.setHandler("petports_upcyclerRead", function()
		return {
			rules = storedRules(),
			enabled = storedEnabled(),
			feeder = storedFeeder(),
			points = storage.points or 0,

			--  So the pane can draw a bar without hardcoding the divisor. It is
			--  a config parameter precisely because it will be retuned.
			pointsPerFuel = self.pointsPerFuel,

			--  The charge, oldest first, so the pane can draw it left to right
			--  in the order it will pay out.
			blips = blipQueue(),
			blipCapacity = BLIP_CAPACITY,
			blocked = storage.blocked == true,

			--  WHAT IS IN THE REAGENT SLOT, so the pane does not have to work it
			--  out. It tried reading the grid and could not: widget.itemGridItems
			--  IGNORES slotOffset and hands back the whole container keyed from
			--  slot 0, so asking itemGrid2 for its first item returned the INPUT
			--  and the pane warned that dirt was not a reagent while the reagent
			--  slot sat empty.
			--
			--  The machine reads this slot every tick anyway and is the authority
			--  on it. Publishing it means the pane's warning and the machine's
			--  refusal cannot disagree, which is the same reason the pane reads
			--  petports_reagentFor rather than keeping its own list.
			--  WHAT IS IN THE OUTPUT SLOT, so the pane can say why a machine
			--  with points banked is doing nothing.
			--
			--  A player can drag anything into any slot. An ore stack parked
			--  here refuses every treat the machine tries to place, and the port
			--  will not clear it -- its fuel scan only recognises treats, on
			--  purpose, because hauling off something the player put somewhere
			--  is worse than leaving it. So nothing in the world resolves this
			--  and the only way out is telling them.
			output = (function()
				local held = world.containerItemAt(entity.id(), SLOT_OUTPUT)

				if type(held) ~= "table" or type(held.name) ~= "string" then
					return nil
				end

				return held.name
			end)(),

			--  A NAME, NOT A DESCRIPTOR. The pane only needs it to look up
			--  whether the item is a reagent and to label a warning, and a bare
			--  string cannot be oversized.
			reagent = (function()
				local held = world.containerItemAt(entity.id(), SLOT_REAGENT)

				if type(held) ~= "table" or type(held.name) ~= "string" then
					return nil
				end

				return held.name
			end)(),

			slots = { input = SLOT_INPUT, output = SLOT_OUTPUT, reagent = SLOT_REAGENT }
		}
	end)

	--  DISCARD THE CHARGE. The pane's only way to undo a reagent.
	--
	--  DESTRUCTIVE AND DELIBERATELY NOT REFUNDABLE. The reagent was consumed
	--  when the blips were filled, and handing it back would mean deciding what
	--  a half-spent charge is worth -- four spicy blips is not four-eighths of a
	--  Scorched Core, it is a Scorched Core that has already done half its job.
	--  Clearing throws away what is left, which is the honest reading and the
	--  one the button's tooltip states.
	--
	--  A MESSAGE RATHER THAN A PARAMETER WRITE FROM THE PANE. The machine owns
	--  the queue; a pane reaching in to rewrite it would be a second author of
	--  the same state, and the two would disagree the moment a treat is emitted
	--  between the read and the write.
	message.setHandler("petports_upcyclerClearCharge", function()
		local queue = blipQueue()
		local had = #queue

		if had == 0 then return false end

		storage.blips = {}

		--  Flushed on the next timer tick like any other change. Not forced
		--  here: the parameter mirror exists for mine-and-replace, and a
		--  five-second window where a mined machine remembers a charge the
		--  player just discarded is a smaller wrong than an extra write path.
		sb.logInfo("PETPORTS upcycler: charge of %s blip(s) DISCARDED by the player",
			sb.printJson(had))

		return true
	end)

	object.setInteractive(true)
end

--  DESTRUCTION ONLY. uninit also fires on world unload, and switching the
--  machine off every time the player leaves would be a bug that looks like the
--  feature working.
--
--  A MINED AND RE-PLACED UPCYCLER MUST COME BACK OFF. Rules travelling with the
--  item is a convenience; `enabled` travelling with it would hand the player a
--  running machine they did not switch on, in a new location.
--
--  UNVERIFIED WHETHER THIS WRITE REACHES THE DROP. There is precedent for a late
--  write missing its target -- writeBackToItem cannot run on unsocket because
--  the item has already left the container by the time update notices. If
--  `enabled` survives a break, the fix is keeping it in `storage`, which
--  persists across reload but does not follow an item.
function die()
	dbg("destroyed -- forcing enabled off (was %s), banking %s point(s)",
		tostring(storedEnabled()), tostring(storage.points or 0))

	object.setConfigParameter(ENABLED_KEY, false)

	--  Final flush, so the last few seconds of progress travel too. The timer
	--  above is what makes this an improvement rather than the only chance.
	object.setConfigParameter(POINTS_KEY, storage.points or 0)
end
