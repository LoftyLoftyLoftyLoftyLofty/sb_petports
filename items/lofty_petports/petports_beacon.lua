--  PETPORTS -- BEACON ITEM
--
--  A beacon does its work by EXISTING IN A CONTAINER, not by being used. The
--  port reads container contents and finds `petports_sortingBeaconBehavior` in
--  the item's config; nothing here runs for that to work, and nothing here
--  should ever be required for it to work.
--
--  This script exists for one reason: an .activeitem with no script errors when
--  activated, and a player WILL click one. Everything below is a deliberate
--  no-op.
--
--  WHERE THE CONFIG UI GOES. `activate()` is the hook -- open a pane, write the
--  player's choices into item parameters, and let the port merge parameters over
--  config the same way petData is merged. Two things to settle before that
--  lands: a configured beacon needs maxStack 1 while a blank one stays
--  stackable, and the port needs to read parameters rather than config alone.

function init()
end

function update(dt, fireMode, shifting, moves)
end

function activate(fireMode, shifting)
	--  No config UI yet. Say so once rather than silently doing nothing, which
	--  reads as a broken item.
	if fireMode == "primary" or fireMode == "alt" then
		activeItem.setInstanceValue("petports_beaconNoticed", true)
	end
end

function uninit()
end
