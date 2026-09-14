-- Upcycler object: burns input for points, spends reagents as flavor charge and emits fuel.

local DEBUG = true

-- Logs a formatted line when DEBUG is set.
local function dbg(fmt, ...)
	if not DEBUG then return end
	local ok, text = pcall(string.format, fmt, ...)
	sb.logInfo("PETPORTS upcycler: %s", ok and text or ("<badformat> " .. tostring(fmt)))
end

local RULES_KEY = "petports_upcyclerRules"
local ENABLED_KEY = "petports_upcyclerEnabled"

local FEEDER_KEY = "petports_upcyclerFeeder"

require "/scripts/lofty_petports/petports_flavors.lua"
require "/scripts/lofty_petports/petports_upcyclerstate.lua"

require "/scripts/lofty_petports/petports_filters.lua"

local POINTS_KEY = "petports_upcyclerPoints"

local BLIPS_KEY = "petports_upcyclerBlips"

local BLOCKED_KEY = "petports_upcyclerBlocked"

local BLIP_CAPACITY = 8

local SLOT_INPUT = 0
local SLOT_REAGENT = 1
local SLOT_OUTPUT = 2

local FUEL_ITEM = "petports_petfuel"

local OBJECT_BUILD_STAMP = "2026-09-14a a hand-pressed burn forces the input slot past its rule, its burn box, the exempt tag and the off switch"

local EXEMPT_TAG = "petports_no_upcycling"


-- Returns the stored rules as item, max, reagent and burn fields.
local function storedRules()
	local stored = config.getParameter(RULES_KEY)
	if type(stored) ~= "table" then return {} end

	local rules = {}

	for _, rule in ipairs(stored) do
		if type(rule) == "table" and type(rule.item) == "string" and rule.item ~= "" then
			table.insert(rules, {
				item = rule.item,
				max = tonumber(rule.max) or 0,
				reagent = rule.reagent,
				burn = rule.burn
			})
		end
	end

	return rules
end

-- Returns whether the machine is switched on.
local function storedEnabled()
	local stored = config.getParameter(ENABLED_KEY)
	if stored == nil then return false end
	return stored == true
end

-- Returns whether the feeder flag is set.
local function storedFeeder()
	local stored = config.getParameter(FEEDER_KEY)
	return stored ~= false
end

-- Returns the stored rule naming an item, or nil.
local function ruleFor(name)
	if type(name) ~= "string" then return nil end

	for _, rule in ipairs(storedRules()) do
		if rule.item == name then return rule end
	end

	return nil
end

-- Returns a one-line summary of the enabled flag, the points and the rules.
local function stateSummary()
	local parts = {}

	for _, rule in ipairs(storedRules()) do
		table.insert(parts, string.format("%s>%s", rule.item, tostring(rule.max)))
	end

	return string.format("enabled=%s points=%s rules=[%s]",
		tostring(storedEnabled()), tostring(storage.points or 0),
		#parts == 0 and "none" or table.concat(parts, " "))
end


-- Returns an item's price, floored at the configured value floor.
local function valueOf(descriptor)
	local price = petports_itemValue(descriptor)
	if price > self.valueFloor then return price end
	return self.valueFloor
end

-- Returns whether an item is a plain treat.
local function plainTreat(descriptor)
	if type(descriptor) ~= "table" or type(descriptor.name) ~= "string" then
		return false
	end

	return petports_upcyclerPlainTreat(descriptor.name)
end

-- Returns whether an item carries the no-upcycling tag, cached.
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

	self.exemptCache[descriptor.name] = verdict

	return verdict
end


-- Returns the item name a forced burn covers, clearing it once the input slot holds something else.
local function forcedBurn(input)
	local wanted = storage.forceBurn

	if type(wanted) ~= "string" then return nil end

	local held = type(input) == "table" and type(input.name) == "string"
		and input.name or nil

	if held ~= wanted then
		sb.logInfo("PETPORTS upcycler: forced burn of %s ENDED -- slot %s now holds %s",
			wanted, sb.printJson(SLOT_INPUT), held or "nothing")

		storage.forceBurn = nil

		self.state = nil

		return nil
	end

	return wanted
end


-- Logs a state line when it differs from the last one.
local function state(text)
	if self.state == text then return end
	self.state = text
	dbg("%s", text)
end


-- Returns the stored blip queue, rebuilding it as an array if it came back string-keyed.
local function blipQueue()
	local q = storage.blips
	if type(q) ~= "table" then
		storage.blips = (jarray and jarray()) or {}
		return storage.blips
	end

	if q[1] == nil and q["1"] ~= nil then
		local fixed = (jarray and jarray()) or {}
		local index = 1
		while q[tostring(index)] ~= nil do
			fixed[index] = q[tostring(index)]
			index = index + 1
		end
		storage.blips = fixed
		return fixed
	end

	return q
end

-- Removes and returns the first blip.
local function blipTake()
	local queue = blipQueue()
	if #queue == 0 then return nil end
	return table.remove(queue, 1)
end

-- Logs a reagent line when it differs from the last one.
local function reagentState(fmt, ...)
	local text = string.format(fmt, ...)
	if self.lastReagentState == text then return end
	self.lastReagentState = text
	sb.logInfo("PETPORTS upcycler reagent: %s", text)
end

-- Spends one reagent from its slot into the blip queue when there is room for its weight.
local function consumeReagent()
	local queue = blipQueue()
	local room = BLIP_CAPACITY - #queue

	if room <= 0 then
		reagentState("charge full at %s, nothing can be spent",
			sb.printJson(#queue))
		return false
	end

	local held = world.containerItemAt(entity.id(), SLOT_REAGENT)

	if type(held) ~= "table" or type(held.name) ~= "string" then
		reagentState("slot %s is empty (%s room in the charge)",
			sb.printJson(SLOT_REAGENT), sb.printJson(room))
		return false
	end

	if exempt(held) then
		reagentState("%s in slot %s is exempt from upcycling entirely",
			tostring(held.name), sb.printJson(SLOT_REAGENT))
		return false
	end

	local entry = petports_reagentFor(held.name)

	if entry == nil then
		reagentState("%s in slot %s is not a reagent", tostring(held.name),
			sb.printJson(SLOT_REAGENT))
		return false
	end

	local rule = ruleFor(held.name)

	if rule ~= nil and rule.reagent == false then
		reagentState("%s in slot %s is reagent-denied by its own rule",
			tostring(held.name), sb.printJson(SLOT_REAGENT))
		return false
	end

	local weight = tonumber(entry.weight) or 0

	if weight <= 0 then
		reagentState("%s has no usable weight (%s)", tostring(held.name),
			tostring(entry.weight))
		return false
	end

	if weight > room then
		reagentState("%s needs %s blip(s), only %s free",
			tostring(held.name), sb.printJson(weight), sb.printJson(room))
		return false
	end

	local taken = world.containerTakeNumItemsAt(entity.id(), SLOT_REAGENT, 1)

	if type(taken) ~= "table" or (taken.count or 0) < 1 then
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

-- Logs a shuttle line when it differs from the last one.
local function shuttleState(fmt, ...)
	local text = string.format(fmt, ...)
	if self.lastShuttleState == text then return end
	self.lastShuttleState = text
	sb.logInfo("PETPORTS upcycler shuttle: %s", text)
end

-- Moves a whole stack between two slots, returning whatever the destination refuses.
local function bulkRescue(source, destination, held, blocker, why)
	if blocker ~= nil and blocker.name ~= held.name then
		shuttleState("rescue of %s waiting: slot %s holds %s",
			tostring(held.name), sb.printJson(destination), tostring(blocker.name))
		return
	end

	local taken = world.containerTakeNumItemsAt(entity.id(), source, held.count or 1)
	if type(taken) ~= "table" or (taken.count or 0) < 1 then return end

	local leftover = world.containerPutItemsAt(entity.id(), taken, destination)
	local refused = (type(leftover) == "table" and leftover.count or 0)
	local moved = (taken.count or 0) - refused

	if refused > 0 then
		local returned = world.containerPutItemsAt(entity.id(), leftover, source)

		if type(returned) == "table" and (returned.count or 0) > 0 then
			sb.logError("PETPORTS upcycler SHUTTLE LOST %s %s: slot %s and slot %s "
				.. "both refused the rescue",
				sb.printJson(returned.count), tostring(held.name),
				sb.printJson(destination), sb.printJson(source))
		end
	end

	if moved > 0 then
		self.lastShuttleState = nil
		sb.logInfo("PETPORTS upcycler shuttle: RESCUED %s %s slot %s -> slot %s (%s)",
			sb.printJson(moved), tostring(held.name),
			sb.printJson(source), sb.printJson(destination), why)
	else
		shuttleState("rescue of %s waiting: slot %s cannot merge it",
			tostring(held.name), sb.printJson(destination))
	end
end

-- Returns whether an item's reagent weight fits in the remaining charge.
local function chargeFits(name)
	local entry = petports_reagentFor(name)
	if entry == nil then return false end

	local weight = tonumber(entry.weight) or 0
	if weight <= 0 then return false end

	return weight <= (BLIP_CAPACITY - #blipQueue())
end

-- Moves one item between two slots, returning it when the destination refuses.
local function moveOne(source, destination, held)
	local taken = world.containerTakeNumItemsAt(entity.id(), source, 1)
	if type(taken) ~= "table" or (taken.count or 0) < 1 then return end

	local leftover = world.containerPutItemsAt(entity.id(), taken, destination)

	if type(leftover) == "table" and (leftover.count or 0) > 0 then
		local returned = world.containerPutItemsAt(entity.id(), leftover, source)

		if type(returned) == "table" and (returned.count or 0) > 0 then
			sb.logError("PETPORTS upcycler SHUTTLE LOST %s %s: destination %s and "
				.. "source %s both refused",
				sb.printJson(returned.count), tostring(held.name),
				sb.printJson(destination), sb.printJson(source))
		end
		return
	end

	self.lastShuttleState = nil

	local key = string.format("%s %s>%s", tostring(held.name),
		tostring(source), tostring(destination))

	local continuing = key == self.lastMoveKey
		and self.lastMoveTick == (self.shuttleTick or 0) - 1

	self.lastMoveTick = self.shuttleTick or 0

	if not continuing then
		self.lastMoveKey = key
		sb.logInfo("PETPORTS upcycler shuttle: moving %s, slot %s -> slot %s "
			.. "(one per tick while this holds)",
			tostring(held.name), sb.printJson(source), sb.printJson(destination))
	end
end

-- Exchanges the contents of the input and reagent slots.
local function swapSlots(input, reagent)
	local tookInput = world.containerTakeNumItemsAt(entity.id(), SLOT_INPUT,
		input.count or 1)
	if type(tookInput) ~= "table" or (tookInput.count or 0) < 1 then return end

	local tookReagent = world.containerTakeNumItemsAt(entity.id(), SLOT_REAGENT,
		reagent.count or 1)

	if type(tookReagent) ~= "table" or (tookReagent.count or 0) < 1 then
		world.containerPutItemsAt(entity.id(), tookInput, SLOT_INPUT)
		return
	end

	local leftInput = world.containerPutItemsAt(entity.id(), tookInput, SLOT_REAGENT)
	local leftReagent = world.containerPutItemsAt(entity.id(), tookReagent, SLOT_INPUT)

	local strandedIn = type(leftInput) == "table" and (leftInput.count or 0) or 0
	local strandedRe = type(leftReagent) == "table" and (leftReagent.count or 0) or 0

	if strandedIn > 0 then
		local back = world.containerPutItemsAt(entity.id(), leftInput, SLOT_INPUT)
		if type(back) == "table" and (back.count or 0) > 0 then
			sb.logError("PETPORTS upcycler SWAP LOST %s %s: neither slot would "
				.. "take it back", sb.printJson(back.count), tostring(input.name))
		end
	end

	if strandedRe > 0 then
		local back = world.containerPutItemsAt(entity.id(), leftReagent, SLOT_REAGENT)
		if type(back) == "table" and (back.count or 0) > 0 then
			sb.logError("PETPORTS upcycler SWAP LOST %s %s: neither slot would "
				.. "take it back", sb.printJson(back.count), tostring(reagent.name))
		end
	end

	self.lastShuttleState = nil
	sb.logInfo("PETPORTS upcycler shuttle: SWAPPED %s and %s -- each held the "
		.. "other's slot", tostring(input.name), tostring(reagent.name))
end

-- Moves the input and reagent slot contents to the slot each one's rule allows.
local function shuttleSlots()
	self.shuttleTick = (self.shuttleTick or 0) + 1

	local input = world.containerItemAt(entity.id(), SLOT_INPUT)
	local reagent = world.containerItemAt(entity.id(), SLOT_REAGENT)

	local inputHeld = type(input) == "table" and type(input.name) == "string"
	local reagentHeld = type(reagent) == "table" and type(reagent.name) == "string"

	local forced = forcedBurn(inputHeld and input or nil)

	if forced == nil and inputHeld and reagentHeld
	   and petports_upcyclerDeadlocked(input.name, reagent.name, ruleFor) then
		swapSlots(input, reagent)
		return
	end

	if forced == nil and inputHeld and not exempt(input) then
		local rule = ruleFor(input.name)

		if rule ~= nil then
			if rule.burn == false then
				if rule.reagent ~= false and petports_reagentFor(input.name) ~= nil then
					bulkRescue(SLOT_INPUT, SLOT_REAGENT, input,
						reagentHeld and reagent or nil, "burner denied")
				else
					shuttleState("%s stranded in slot %s: denied the burner and "
						.. "the reagent slot cannot take it",
						tostring(input.name), sb.printJson(SLOT_INPUT))
				end

				return
			end

			if rule.reagent ~= false and not reagentHeld
			   and chargeFits(input.name) then
				moveOne(SLOT_INPUT, SLOT_REAGENT, input)
				return
			end
		end
	end

	if reagentHeld and not exempt(reagent) then
		local rule = ruleFor(reagent.name)

		if rule ~= nil and rule.reagent == false then
			if rule.burn ~= false then
				bulkRescue(SLOT_REAGENT, SLOT_INPUT, reagent,
					inputHeld and input or nil, "reagent denied")
			else
				shuttleState("%s stranded in slot %s: its rule denies both slots",
					tostring(reagent.name), sb.printJson(SLOT_REAGENT))
			end

			return
		end

		if not inputHeld and rule ~= nil and rule.burn ~= false
		   and not chargeFits(reagent.name) then
			moveOne(SLOT_REAGENT, SLOT_INPUT, reagent)
		end
	end
end

-- Turns one plain treat into the item of the first charged flavor.
local function flavorTreat(input)
	local queue = blipQueue()
	local flavor = queue[1]

	if flavor == nil then
		state(string.format("holding %s: no flavor charge remains to spend on it",
			input.name))
		return
	end

	local item = petports_flavorItem(flavor)

	if item == nil or item == input.name then
		state(string.format("cannot flavor %s: flavor %s has no treat of its own",
			input.name, tostring(flavor)))
		return
	end

	local taken = world.containerTakeNumItemsAt(entity.id(), SLOT_INPUT, 1)

	if type(taken) ~= "table" or (taken.count or 0) < 1 then
		return
	end

	local leftover = world.containerPutItemsAt(entity.id(),
		{ name = item, count = 1 }, SLOT_OUTPUT)

	if type(leftover) == "table" and (leftover.count or 0) > 0 then
		local back = world.containerPutItemsAt(entity.id(), taken, SLOT_INPUT)

		if type(back) == "table" and (back.count or 0) > 0 then
			sb.logError("PETPORTS upcycler: could not return %s to the input "
				.. "slot after a blocked flavoring -- one treat lost",
				tostring(taken.name))
		end

		storage.blocked = true
		state(string.format("output blocked: cannot place a %s", item))
		return
	end

	blipTake()
	storage.blocked = false

	state(string.format("flavored 1 %s into %s, %s blip(s) left",
		input.name, item, tostring(#blipQueue())))
end

-- Spends banked points into fuel or flavored items until they run out or the output refuses.
local function emitFuel()
	while (storage.points or 0) >= self.pointsPerFuel do
		local queue = blipQueue()
		local flavor = queue[1]
		local item = FUEL_ITEM

		if flavor ~= nil then
			item = petports_flavorItem(flavor) or FUEL_ITEM
		end

		local yield = flavor ~= nil and petports_flavorYield(flavor) or 1

		if yield > 1 and world.containerItemsCanFit ~= nil then
			local okFit, fits = pcall(world.containerItemsCanFit, entity.id(),
				{ name = item, count = yield })
			if okFit and type(fits) == "number" and fits < yield then
				state(string.format("output blocked: %s point(s) banked, cannot place %s %s",
					tostring(storage.points), tostring(yield), item))
				storage.blocked = true
				return false
			end
		end

		local leftover = world.containerPutItemsAt(entity.id(),
			{ name = item, count = yield }, SLOT_OUTPUT)

		if type(leftover) == "table" and (leftover.count or 0) > 0 then
			state(string.format("output blocked: %s point(s) banked, cannot place a %s",
				tostring(storage.points), item))
			storage.blocked = true
			return false
		end

		if flavor ~= nil then blipTake() end

		storage.points = storage.points - self.pointsPerFuel
		storage.blocked = false
		dbg("emitted %s %s%s, %s point(s) left banked, %s blip(s) left",
			tostring(yield), item, flavor ~= nil and " (flavored)" or "",
			tostring(storage.points), tostring(#blipQueue()))
	end

	storage.blocked = false
	return true
end

-- Writes the points, blips and blocked flag into the object config on an interval when they change.
local function flushPoints(dt)
	self.flushTimer = (self.flushTimer or 0) - dt
	if self.flushTimer > 0 then return end

	self.flushTimer = self.pointsFlushInterval

	local queue = blipQueue()

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

	object.setConfigParameter(BLIPS_KEY, queue)
end

-- Runs the reagent and shuttle steps, emits fuel, then burns input into points.
function update(dt)
	storage.points = storage.points or 0
	flushPoints(dt)

	consumeReagent()

	shuttleSlots()

	if not storedEnabled() and storage.forceBurn == nil then
		state("idle: machine is switched off")
		return
	end

	local canEmit = emitFuel()

	consumeReagent()

	local input = world.containerItemAt(entity.id(), SLOT_INPUT)

	local forced = forcedBurn(input)

	if type(input) ~= "table" or type(input.name) ~= "string" then
		state("idle: input slot empty")
		self.carry = 0
		return
	end

	if forced == nil and plainTreat(input) then
		flavorTreat(input)
		self.carry = 0
		return
	end

	if forced == nil and exempt(input) then
		state(string.format("REFUSING %s: exempt from conversion regardless of rules",
			input.name))
		self.carry = 0
		return
	end

	local inputRule = ruleFor(input.name)

	if inputRule == nil and forced == nil then
		state(string.format("REFUSING %s: no rule names it, so it will not be converted",
			input.name))
		self.carry = 0
		return
	end

	if inputRule ~= nil and inputRule.burn == false and forced == nil then
		state(string.format("REFUSING %s: rule denies the burner", input.name))
		self.carry = 0
		return
	end

	if not canEmit then
		self.carry = 0
		return
	end

	self.carry = (self.carry or 0) + dt * self.itemsPerSecond

	local want = math.floor(self.carry)
	if want < 1 then return end

	local taken = world.containerTakeNumItemsAt(entity.id(), SLOT_INPUT, want)

	if type(taken) ~= "table" or (taken.count or 0) < 1 then
		self.carry = 0
		return
	end

	self.carry = self.carry - taken.count

	local each = valueOf(taken)
	local gained = each * taken.count
	storage.points = storage.points + gained

	state(string.format("converting %s at %s point(s) each%s", taken.name,
		tostring(each), forced ~= nil and " (FORCED by hand)" or ""))

	emitFuel()
end

-- Adopts the stored points and blips, reads the rate parameters and installs the pane handlers.
function init()
	sb.logInfo("PETPORTS upcycler build: %s", OBJECT_BUILD_STAMP)

	if storage.points == nil then
		storage.points = tonumber(config.getParameter(POINTS_KEY)) or 0

		if storage.points > 0 then
			sb.logInfo("PETPORTS upcycler: adopted %s banked point(s) from a placed item",
				sb.printJson(storage.points))
		end
	end

	if storage.blips == nil then
		local adopted = config.getParameter(BLIPS_KEY)
		storage.blips = type(adopted) == "table" and adopted or {}

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
	self.exemptCache = {}

	self.pointsPerFuel = config.getParameter("petports_pointsPerFuel", 1000)
	self.valueFloor = config.getParameter("petports_valueFloor", 1)
	self.itemsPerSecond = config.getParameter("petports_itemsPerSecond", 5)
	self.pointsFlushInterval = config.getParameter("petports_pointsFlushInterval", 5.0)

	dbg("init at %s -- %s", sb.printJson(entity.position()), stateSummary())

	message.setHandler("petports_upcyclerWrite", function(_, _, payload)
		if type(payload) ~= "table" then
			dbg("write REJECTED: payload was %s", type(payload))
			return false
		end

		if payload.rules ~= nil then
			object.setConfigParameter(RULES_KEY, payload.rules)
		end

		if payload.enabled ~= nil then
			object.setConfigParameter(ENABLED_KEY, payload.enabled == true)
		end

		if payload.feeder ~= nil then
			object.setConfigParameter(FEEDER_KEY, payload.feeder == true)
		end

		self.state = nil

		dbg("write ACCEPTED -- %s", stateSummary())
		return true
	end)

	message.setHandler("petports_upcyclerRead", function()
		return {
			rules = storedRules(),
			enabled = storedEnabled(),
			feeder = storedFeeder(),
			points = storage.points or 0,

			pointsPerFuel = self.pointsPerFuel,

			blips = blipQueue(),
			blipCapacity = BLIP_CAPACITY,
			blocked = storage.blocked == true,

			forced = storage.forceBurn,

			output = (function()
				local held = world.containerItemAt(entity.id(), SLOT_OUTPUT)

				if type(held) ~= "table" or type(held.name) ~= "string" then
					return nil
				end

				return held.name
			end)(),

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

	message.setHandler("petports_upcyclerBurnNow", function(_, _, payload)
		local named = type(payload) == "table" and payload.item or nil
		local held = world.containerItemAt(entity.id(), SLOT_INPUT)
		local holding = type(held) == "table" and type(held.name) == "string"
			and held.name or nil

		if type(storage.forceBurn) == "string"
		   and (named == nil or named == storage.forceBurn) then
			sb.logInfo("PETPORTS upcycler: forced burn of %s CANCELLED by the player",
				storage.forceBurn)

			storage.forceBurn = nil
			self.state = nil

			return true
		end

		if holding == nil then
			sb.logInfo("PETPORTS upcycler: manual burn REFUSED -- slot %s is empty",
				sb.printJson(SLOT_INPUT))
			return false
		end

		if type(named) == "string" and named ~= holding then
			sb.logInfo("PETPORTS upcycler: manual burn REFUSED -- the pane asked "
				.. "for %s and slot %s holds %s",
				named, sb.printJson(SLOT_INPUT), holding)
			return false
		end

		storage.forceBurn = holding
		self.state = nil

		if exempt(held) then
			sb.logInfo("PETPORTS upcycler: manual burn ACCEPTED for an EXEMPT item "
				.. "-- forcing %s x%s in slot %s, past its %s tag",
				holding, sb.printJson(held.count or 1), sb.printJson(SLOT_INPUT),
				EXEMPT_TAG)
		else
			sb.logInfo("PETPORTS upcycler: manual burn ACCEPTED -- forcing %s x%s "
				.. "in slot %s, past its rule and the off switch",
				holding, sb.printJson(held.count or 1), sb.printJson(SLOT_INPUT))
		end

		return true
	end)

	message.setHandler("petports_upcyclerClearCharge", function()
		local queue = blipQueue()
		local had = #queue

		if had == 0 then return false end

		storage.blips = {}

		sb.logInfo("PETPORTS upcycler: charge of %s blip(s) DISCARDED by the player",
			sb.printJson(had))

		return true
	end)

	object.setInteractive(true)
end

-- Switches the machine off and banks the points into the object config.
function die()
	dbg("destroyed -- forcing enabled off (was %s), banking %s point(s)",
		tostring(storedEnabled()), tostring(storage.points or 0))

	object.setConfigParameter(ENABLED_KEY, false)

	object.setConfigParameter(POINTS_KEY, storage.points or 0)
end
