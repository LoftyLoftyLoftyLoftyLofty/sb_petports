function init()
	effect.addStatModifierGroup(
	{
		{ stat = "lavaImmunity", amount = 1 },
		{ stat = "fireStatusImmunity", amount = 1 }
	})

	script.setUpdateDelta(0)
end

function uninit()
end
