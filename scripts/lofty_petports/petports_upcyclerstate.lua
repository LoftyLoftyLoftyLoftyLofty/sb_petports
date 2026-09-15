-- Decides whether an upcycler refuses to run, and why, from its slot contents.

require "/scripts/lofty_petports/petports_flavors.lua"


PETPORTS_TAG_NO_UPCYCLING = "petports_no_upcycling"
PETPORTS_TAG_FUEL = "petports_fuel"

PETPORTS_TAG_PLAIN_TREAT = "petports_plain_treat"

local tagCache = {}

-- Returns whether an item carries an item tag, caching the answer.
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

-- Returns true when an item is tagged as a plain treat.
function petports_upcyclerPlainTreat(name)
	return petports_hasItemTag(name, PETPORTS_TAG_PLAIN_TREAT) == true
end

-- Returns true when an item is tagged against upcycling.
function petports_upcyclerExempt(name)
	return petports_hasItemTag(name, PETPORTS_TAG_NO_UPCYCLING)
end


-- Returns true when the input wants the reagent slot and the reagent wants the input slot.
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

-- Returns the first refusal cause the slot contents produce, or nil.
function petports_upcyclerVerdict(ctx)
	if type(ctx) ~= "table" then return nil end

	local ruleFor = type(ctx.ruleFor) == "function" and ctx.ruleFor
		or function() return nil end

	local forced = type(ctx.forced) == "string" and ctx.forced == ctx.input

	if type(ctx.output) == "string"
	   and not petports_hasItemTag(ctx.output, PETPORTS_TAG_FUEL) then
		return { cause = "outputBlocked", item = ctx.output }
	end

	if not forced and type(ctx.input) == "string" then
		local name = ctx.input
		local rule = ruleFor(name)

		local plain = petports_upcyclerPlainTreat(name)

		if plain and (tonumber(ctx.charges) or 0) < 1 then
			return { cause = "inputNoCharge", item = name }
		end

		if not plain and petports_upcyclerExempt(name) then
			return { cause = "inputExempt", item = name }
		end

		if not plain and rule == nil then
			return { cause = "inputNoRule", item = name }
		end

		if not plain and rule ~= nil and rule.burn == false then
			if rule.reagent ~= false and petports_reagentFor(name) ~= nil then
				if ctx.reagent ~= nil and ctx.reagent ~= name then
					return { cause = "inputWaiting", item = name }
				end
			else
				return { cause = "inputStranded", item = name }
			end
		end
	end

	if type(ctx.reagent) == "string" then
		local name = ctx.reagent
		local rule = ruleFor(name)

		if petports_upcyclerExempt(name) then
			return { cause = "reagentExempt", item = name }
		end

		if petports_reagentFor(name) == nil then
			return { cause = "reagentNotAReagent", item = name }
		end

		if rule ~= nil and rule.reagent == false then
			if rule.burn == false then
				return { cause = "reagentStranded", item = name }
			end

			if ctx.input ~= nil and ctx.input ~= name then
				return { cause = "reagentWaiting", item = name }
			end
		end
	end

	return nil
end
