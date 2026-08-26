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
local POINTS_KEY = "petports_upcyclerPoints"

--  Container offsets are ZERO-based. The keys world.containerItems hands back
--  are ONE-based -- documented engine behaviour, and the same fact
--  SLOT_KEY_TO_OFFSET pays for in petports_petport.lua. Everything here uses
--  the offset-taking calls, so no conversion is needed.
local SLOT_INPUT = 0
local SLOT_OUTPUT = 1
local SLOT_REAGENT = 2

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

--  Move banked points into the output slot, one Treat at a time.
--
--  Returns true if the output can still take more. The caller uses that to
--  decide whether to keep eating input: a machine that consumes while unable to
--  pay out would destroy the input and show nothing for it, which is exactly
--  the failure mode this whole design exists to avoid.
local function emitFuel()
	while (storage.points or 0) >= self.pointsPerFuel do
		local leftover = world.containerPutItemsAt(entity.id(),
			{ name = FUEL_ITEM, count = 1 }, SLOT_OUTPUT)

		--  A DESCRIPTOR COMES BACK, NOT A COUNT. Anything with a positive count
		--  means the slot would not take it -- full, or holding something else
		--  the player parked there.
		if type(leftover) == "table" and (leftover.count or 0) > 0 then
			state(string.format("output blocked: %s point(s) banked, cannot place a %s",
				tostring(storage.points), FUEL_ITEM))
			return false
		end

		storage.points = storage.points - self.pointsPerFuel
		dbg("emitted 1 %s, %s point(s) left banked", FUEL_ITEM, tostring(storage.points))
	end

	return true
end

--  Mirror banked points into a parameter, on a slow timer. See POINTS_KEY.
local function flushPoints(dt)
	self.flushTimer = (self.flushTimer or 0) - dt
	if self.flushTimer > 0 then return end

	self.flushTimer = self.pointsFlushInterval

	--  Change-gated: an idle machine should not rewrite the same number every
	--  five seconds forever.
	if self.flushedPoints == storage.points then return end

	self.flushedPoints = storage.points
	object.setConfigParameter(POINTS_KEY, storage.points)
end

function update(dt)
	storage.points = storage.points or 0
	flushPoints(dt)

	if not storedEnabled() then
		state("idle: machine is switched off")
		return
	end

	--  Pay out first. Points banked from a previous tick should become fuel
	--  before anything else is eaten, so a machine that was blocked and has
	--  since been emptied recovers on its own.
	local canEmit = emitFuel()

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
			points = storage.points or 0,

			--  So the pane can draw a bar without hardcoding the divisor. It is
			--  a config parameter precisely because it will be retuned.
			pointsPerFuel = self.pointsPerFuel,
			slots = { input = SLOT_INPUT, output = SLOT_OUTPUT, reagent = SLOT_REAGENT }
		}
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
