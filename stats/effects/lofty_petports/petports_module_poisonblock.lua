-- Grants poison status immunity while active.

-- Adds the poison immunity modifier and stops the effect updating.
function init()
	effect.addStatModifierGroup({ { stat = "poisonStatusImmunity", amount = 1 } })

	script.setUpdateDelta(0)
end

-- Does nothing.
function uninit()
end
