--  PETPORTS -- UPCYCLER SLOT STATE
--
--  ONE REFUSAL LADDER, READ BY BOTH THE PANE AND THE MACHINE.
--
--  WHY THIS FILE EXISTS. The same question -- "what is wrong with this slot?"
--  -- was being answered independently in two places, from the same lookup
--  tables, in two hand-written orders. They drifted four times in two days:
--
--    * applyState (pane) vs storedRules (object) -- the pane's copy silently
--      dropped both rule exclusions and wrote the stripped set back.
--    * the two bulk rescues, which were a near-identical pair before they
--      became one function.
--    * the refusal ladders themselves -- the machine was reordered to ask
--      exempt before the manifest and the pane was not, so one item got two
--      different explanations.
--    * hasTag (pane) and exempt (object), the same cached root.itemConfig
--      walk written twice.
--
--  SHARING THE LOOKUP TABLE WAS NEVER ENOUGH. The ORDER is the logic. A
--  ladder of refusals is a sequence of returns, and a sequence written twice
--  is two programs that merely happen to agree today. This file makes the
--  sequence the shared thing.
--
--  IT DECIDES, IT DOES NOT SPEAK. A verdict is a cause id and a severity --
--  no sentences, no widget names, no log strings. The pane turns a cause into
--  player-facing text in its own voice; the machine turns the same cause into
--  a log line and, later, into indicator lights. Neither can change what
--  counts as broken without changing it for the other.

require "/scripts/lofty_petports/petports_flavors.lua"

--  ---------------------------------------------------------------------------
--  TAGS AND SLOTS
--  ---------------------------------------------------------------------------

PETPORTS_UPCYCLER_SLOT_INPUT = 0
PETPORTS_UPCYCLER_SLOT_REAGENT = 1
PETPORTS_UPCYCLER_SLOT_OUTPUT = 2

PETPORTS_TAG_NO_UPCYCLING = "petports_no_upcycling"
PETPORTS_TAG_FUEL = "petports_fuel"

--  CACHED BY NAME, WHICH IS SAFE HERE. An item's tags are a property of its
--  definition; no build script invents them per instance. This is the one
--  place that reads them -- the pane's hasTag and the object's exempt were
--  both this function, written out twice.
local tagCache = {}

function petports_hasItemTag(name, tag)
	if type(name) ~= "string" or type(tag) ~= "string" then return false end

	tagCache[name] = tagCache[name] or {}

	if tagCache[name][tag] == nil then
		local verdict = false
		local ok, resolved = pcall(root.itemConfig, { name = name, count = 1 })

		if ok and type(resolved) == "table" and type(resolved.config) == "table" then
			for _, candidate in ipairs(resolved.config.itemTags or {}) do
				if candidate == tag then
					verdict = true
					break
				end
			end
		end

		tagCache[name][tag] = verdict
	end

	return tagCache[name][tag]
end

--  Refused by every slot regardless of rules. A property of the ITEM, so it is
--  asked before any table lookup -- see the ladder ordering note below.
function petports_upcyclerExempt(name)
	return petports_hasItemTag(name, PETPORTS_TAG_NO_UPCYCLING)
end

--  ---------------------------------------------------------------------------
--  CAUSES
--  ---------------------------------------------------------------------------
--
--  SEVERITY IS THE FIELD THAT MATTERS, not the cause id. Two kinds of wrong:
--
--    "error"    Nothing in the world will fix this. Either the player's own
--               configuration is rejecting something already inside the
--               machine, or the item can never be processed at all. A human
--               has to act. THIS is what lights the alert.
--
--    "waiting"  The machine is blocked by something that clears itself -- a
--               full charge, a slot the shuttle is about to empty. Worth
--               saying in a status line, NEVER worth an alarm. Crying wolf on
--               these is how an alert surface becomes wallpaper.
--
--  Anything not listed is fine and returns nil.

PETPORTS_UPCYCLER_CAUSES = {
	outputBlocked    = { slot = 2, severity = "error"   },
	slotsDeadlocked  = { slot = 0, severity = "error"   },
	inputExempt      = { slot = 0, severity = "error"   },
	inputNoRule      = { slot = 0, severity = "error"   },
	inputStranded    = { slot = 0, severity = "error"   },
	inputWaiting     = { slot = 0, severity = "waiting" },
	reagentExempt    = { slot = 1, severity = "error"   },
	reagentNotAReagent = { slot = 1, severity = "error" },
	reagentStranded  = { slot = 1, severity = "error"   },
	reagentWaiting   = { slot = 1, severity = "waiting" }
}

--  ---------------------------------------------------------------------------
--  THE LADDER
--  ---------------------------------------------------------------------------
--
--  ctx is everything the verdict depends on, passed in rather than looked up,
--  because the two callers hold this state in completely different shapes --
--  the machine reads containers directly, the pane reads a mirror it was sent.
--
--    ctx.input, ctx.reagent, ctx.output   item NAME in each slot, or nil
--    ctx.ruleFor(name)                    -> rule table or nil
--
--  NO CHARGE-ROOM FIELD. Whether a reagent fits right now decides what the
--  SHUTTLE does, not whether anything is wrong -- a full charge is the machine
--  working, not a fault. Adding it here would invite a rung that alarms on
--  normal operation.
--
--  RETURNS THE SINGLE HIGHEST-PRIORITY VERDICT, or nil. One alert surface, one
--  answer -- and the priority order below is the answer to "if two things are
--  wrong, which one do I tell them about?"
--
--  ORDER WITHIN A SLOT IS BY WHAT THE FACT IS ABOUT, NOT BY WHAT IS CHEAP TO
--  TEST. Item-level facts (exempt) come before table lookups (is it in the
--  manifest) before configuration (what does the rule say). Ordered the other
--  way, the generic message wins and the specific one never fires: every
--  exempt item is also absent from the reagent manifest, so a manifest-first
--  ladder answers "not a reagent" for a pet. That exact bug shipped once.
--  ARE THE TWO SLOTS HOLDING EACH OTHER HOSTAGE?
--
--  Burn-denied stock in the burner needs the reagent slot; reagent-denied
--  stock in the reagent slot needs the burner. When both are true of two
--  DIFFERENT items they are each other's blocker, and neither shuttle
--  direction can move without a temporary slot that does not exist.
--
--  IT LOOKS EXACTLY LIKE WAITING FROM EITHER SIDE ALONE, which is why it went
--  unreported for so long -- each half sees an occupied destination and
--  correctly concludes it should wait. Only a check holding both slots at once
--  can tell "wait, that will clear" from "wait, forever".
--
--  BOTH CONDITIONS ALREADY PROVE THE SWAP IS LEGAL. Each item is being tested
--  for permission to enter the slot the other one occupies, so a machine that
--  simply exchanges them puts nothing anywhere its rules forbid. That is what
--  lets the object resolve this automatically instead of asking for a human.
--
--  ONE DEFINITION, TWO CONSUMERS: the machine swaps on it, the pane reports on
--  it. Written twice, they would eventually disagree about whether a given
--  pair is stuck -- which is the drift this whole file exists to stop.
function petports_upcyclerDeadlocked(inputName, reagentName, ruleFor)
	if type(inputName) ~= "string" or type(reagentName) ~= "string" then
		return false
	end

	if inputName == reagentName then return false end
	if type(ruleFor) ~= "function" then return false end

	local inRule = ruleFor(inputName)
	local reRule = ruleFor(reagentName)

	local inWantsReagentSlot = inRule ~= nil and inRule.burn == false
		and inRule.reagent ~= false
		and petports_reagentFor(inputName) ~= nil
		and not petports_upcyclerExempt(inputName)

	local reWantsBurnSlot = reRule ~= nil and reRule.reagent == false
		and reRule.burn ~= false
		and not petports_upcyclerExempt(reagentName)

	return inWantsReagentSlot and reWantsBurnSlot
end

function petports_upcyclerVerdict(ctx)
	if type(ctx) ~= "table" then return nil end

	local ruleFor = type(ctx.ruleFor) == "function" and ctx.ruleFor
		or function() return nil end

	--  OUTPUT FIRST. Every other fault is a machine declining to do something
	--  it was told not to do; this one is a correctly configured machine doing
	--  nothing at all, which is the more surprising failure and the one least
	--  likely to be guessed from the outside.
	if type(ctx.output) == "string"
	   and not petports_hasItemTag(ctx.output, PETPORTS_TAG_FUEL) then
		return { cause = "outputBlocked", item = ctx.output,
			slot = PETPORTS_UPCYCLER_SLOT_OUTPUT, severity = "error" }
	end

	--  THE MUTUAL SWAP DEADLOCK. Detection lives in its own function because
	--  the MACHINE acts on it and the PANE reports it, and those must not be
	--  two opinions about what counts as deadlocked.
	--
	--  Checked BEFORE the per-slot ladders so it cannot be masked by one of
	--  them returning a waiting verdict first.
	if petports_upcyclerDeadlocked(ctx.input, ctx.reagent, ruleFor) then
		return { cause = "slotsDeadlocked", item = ctx.input,
			other = ctx.reagent, slot = PETPORTS_UPCYCLER_SLOT_INPUT,
			severity = "error" }
	end

	--  THE BURN SLOT OUTRANKS THE REAGENT SLOT. A jammed burn slot stops all
	--  conversion; a jammed reagent slot only stops flavouring, and the
	--  machine keeps producing plain treats meanwhile.
	if type(ctx.input) == "string" then
		local name = ctx.input
		local rule = ruleFor(name)

		if petports_upcyclerExempt(name) then
			return { cause = "inputExempt", item = name,
				slot = PETPORTS_UPCYCLER_SLOT_INPUT, severity = "error" }
		end

		--  NO RULE IS AN ERROR HERE, AND DELIBERATELY NOT IN THE REAGENT SLOT.
		--  A hand-dropped reagent is unambiguous -- the player wanted that
		--  flavour and there is nowhere else it could have been going. A
		--  hand-dropped burn item is not, and the rule is also the green light
		--  for the units, so it has to be asked for explicitly.
		if rule == nil then
			return { cause = "inputNoRule", item = name,
				slot = PETPORTS_UPCYCLER_SLOT_INPUT, severity = "error" }
		end

		if rule.burn == false then
			--  Denied the burner. The shuttle can still save it IF the reagent
			--  slot will have it -- reagent box open and the manifest calls it
			--  a reagent. Otherwise both doors are shut and it needs a human.
			if rule.reagent ~= false and petports_reagentFor(name) ~= nil then
				if ctx.reagent ~= nil and ctx.reagent ~= name then
					return { cause = "inputWaiting", item = name,
						slot = PETPORTS_UPCYCLER_SLOT_INPUT, severity = "waiting" }
				end
			else
				return { cause = "inputStranded", item = name,
					slot = PETPORTS_UPCYCLER_SLOT_INPUT, severity = "error" }
			end
		end
	end

	if type(ctx.reagent) == "string" then
		local name = ctx.reagent
		local rule = ruleFor(name)

		if petports_upcyclerExempt(name) then
			return { cause = "reagentExempt", item = name,
				slot = PETPORTS_UPCYCLER_SLOT_REAGENT, severity = "error" }
		end

		if petports_reagentFor(name) == nil then
			return { cause = "reagentNotAReagent", item = name,
				slot = PETPORTS_UPCYCLER_SLOT_REAGENT, severity = "error" }
		end

		if rule ~= nil and rule.reagent == false then
			if rule.burn == false then
				return { cause = "reagentStranded", item = name,
					slot = PETPORTS_UPCYCLER_SLOT_REAGENT, severity = "error" }
			end

			if ctx.input ~= nil and ctx.input ~= name then
				return { cause = "reagentWaiting", item = name,
					slot = PETPORTS_UPCYCLER_SLOT_REAGENT, severity = "waiting" }
			end
		end
	end

	return nil
end

--  Does this verdict deserve the alarm? The alert surface asks this rather
--  than testing severity itself, so "which severities are loud" stays one
--  decision in one place.
function petports_upcyclerAlerting(verdict)
	return type(verdict) == "table" and verdict.severity == "error"
end
