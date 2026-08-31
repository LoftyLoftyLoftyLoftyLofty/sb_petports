--  PETPORTS -- LAVA BLOCK MODULE EFFECT
--
--  TWO STATS, AND A THIRD DELIBERATELY LEFT OUT. The smoglin -- vanilla's
--  lava-dwelling monster -- carries three relevant ones, and they are not the
--  same kind of thing:
--
--      lavaImmunity        1.0   lava's OWN direct damage
--      fireStatusImmunity  1.0   the burning status effect lava applies
--      fireResistance      0.5   fire-TYPED damage, from any source
--
--  fireResistance IS THE ONE WE DROP, for exactly the reason poisonResistance
--  was dropped from the poison module: fire-typed damage also arrives from a
--  flamethrower, a fire sword, a hostile monster. Shrugging half of that off is
--  a combat buff, which is a different feature wearing the same word.
--
--  lavaImmunity IS NOT THAT, DESPITE LOOKING LIKE IT. It is scoped to the LIQUID
--  rather than to a damage type, so granting it makes a unit safe in a lava pool
--  without making it tougher in a fight. It is also not optional here -- lava
--  hurts through direct damage AND through the burning effect, so without this
--  stat the module would stop the DoT and the unit would still cook.
--
--  THE POISON MODULE NEEDED ONLY ONE STAT because poison harms through its
--  status effect alone. The asymmetry is in the liquids, not in the design.
--
--  amount = 1 IS ADDITIVE ONTO THE CHASSIS BASELINE, which is absent on all four
--  petport chassis -- none declares either stat, so both reach exactly 1.
--
--  setUpdateDelta(0) BECAUSE THERE IS NOTHING TO TICK. The stat group is applied
--  once at init and held for the life of the effect, and the port applies the
--  effect persistently, so init and uninit ARE the socket and unsocket.

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
