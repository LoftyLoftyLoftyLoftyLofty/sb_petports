--  PETPORTS -- POISON BLOCK MODULE EFFECT
--
--  MODELLED ON VANILLA'S poisonblock.lua, WITH ONE LINE DELIBERATELY DROPPED.
--
--  That script grants two stats:
--
--      poisonResistance      0.25   reduces poison-TYPED damage
--      poisonStatusImmunity  1      blocks the poison status effect
--
--  ONLY THE SECOND IS OURS. The module exists so a unit can work in a poison
--  pool without the damage-over-time that standing in one applies. Poison-typed
--  damage can also arrive from a weapon -- a gun, a sword, a hostile monster --
--  and shrugging a quarter of that off is a combat buff nobody asked this module
--  for. Blocking the DoT is the feature; resisting the damage type is a
--  different feature wearing the same word.
--
--  amount = 1 IS ADDITIVE ONTO THE CHASSIS BASELINE, which is 0 on all four
--  petport chassis -- they inherit the vanilla monster defaults and none of them
--  declares poisonStatusImmunity. So this reaches exactly 1 and is the whole
--  immunity rather than a top-up. A chassis that later ships with its own
--  baseline would exceed 1 with this socketed, which the engine clamps.
--
--  setUpdateDelta(0) BECAUSE THERE IS NOTHING TO TICK. The stat group is applied
--  once at init and held for the life of the effect; vanilla does the same and
--  keeps an empty update, which is left out here rather than kept as a stub.
--
--  APPLIED PERSISTENTLY BY THE PORT, never by duration. status.setPersistentEffects
--  holds it while the module occupies a slot and drops it the moment it leaves,
--  so init and uninit ARE the socket and unsocket.

function init()
	effect.addStatModifierGroup({ { stat = "poisonStatusImmunity", amount = 1 } })

	script.setUpdateDelta(0)
end

function uninit()
end
