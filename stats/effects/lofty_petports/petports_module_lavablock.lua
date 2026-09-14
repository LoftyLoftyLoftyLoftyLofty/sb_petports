-- Grants lava and fire status immunity while active.

-- Adds the lava and fire immunity modifiers and stops the effect updating.
function init()
	effect.addStatModifierGroup(
	{
		{ stat = "lavaImmunity", amount = 1 },
		{ stat = "fireStatusImmunity", amount = 1 }
	})

	script.setUpdateDelta(0)
end

-- Does nothing.
function uninit()
end
