--  PETPORTS -- HELP TOOLTIP BUILDER
--
--  IT EXISTS TO DECOUPLE TWO ICONS THAT WERE THE SAME ICON.
--
--  A settings row's help lives on an itemslot, because that is the only tooltip
--  a ContainerPane can produce -- see petports_helptooltip.item. The tooltip's
--  picture is `objectImage`, and left alone the engine fills that from the
--  item's own icon drawables. So showing a MODULE's icon in the tooltip meant
--  overriding the instance's `inventoryIcon`, which is the same field the row's
--  slot draws: the row mark and the tooltip picture were one image in two
--  places, and asking for the module in one meant losing the question mark in
--  the other.
--
--  `config.tooltipFields` IS THE SECOND CHANNEL, AND IT IS GENERAL. A build
--  script sets tooltip widgets BY NAME, and the vanilla scripts show how far
--  that reaches:
--
--      buildfishingrod   reelIconImage, lureIconImage -- arbitrary widget
--                        names carrying image paths, straight from parameters
--      buildmechpart     objectImage set to a DRAWABLES LIST, plus
--                        <stat>StatImage and energyDrainStatLabel
--      buildwhip/bow     subtitle, damageKindImage, and a handful of labels
--
--  So objectImage can be aimed anywhere without touching inventoryIcon. The row
--  keeps its question mark; the tooltip shows the module.
--
--  ---- WHAT THE PANE PASSES ----------------------------------------------
--
--    helpIcon      absolute image path, or absent
--    helpSubtitle  the line under the title, or absent
--    helpRarity    the owning module's rarity string, or absent
--
--  RESOLVED IN THE PANE, NOT HERE. The pane already walks the socketed modules
--  to build its settings rows and already resolves an icon from
--  root.itemConfig's `directory` plus `inventoryIcon` -- the upcycler's flavor
--  rows do exactly that. Doing it again here would be a second copy of a rule
--  that has to agree with the first.
--
--  ---- ABSENT IS NOT EMPTY, AND THE DIFFERENCE MATTERS TWICE --------------
--
--  NO helpIcon MEANS LEAVE objectImage ALONE, which leaves the engine's default
--  in place: the item's own icon, the question mark. That is the fallback for
--  every row no module owns, and it costs no plumbing -- there is no unit item
--  name on the mirror to point at instead. If the pet's own icon is wanted
--  there, that is a new mirror field rather than a change here.
--
--  NO helpSubtitle MEANS EMPTY, WHICH IS NOT THE SAME AS LEAVING IT. Left
--  alone, the engine stamps the item's category and every tip in the list reads
--  "Petport Module" under its title -- wrong for the seven rows that belong to
--  no module. Writing "" is how that is refused without removing `category`
--  from the item, which would change how it sorts and which filter subgroup
--  claims it.

function build(directory, config, parameters, level, seed)
	config.tooltipFields = config.tooltipFields or {}

	--  ALWAYS WRITTEN. See the header: absent means empty here, deliberately.
	config.tooltipFields.subtitle = parameters.helpSubtitle or ""

	--  ONLY WHEN ASKED. A nil assignment would be a no-op anyway, but a stated
	--  guard is what makes the fallback readable as a decision.
	if type(parameters.helpIcon) == "string" and parameters.helpIcon ~= "" then
		config.tooltipFields.objectImage = parameters.helpIcon
	end

	--  ---- RARITY, AND IT IS NOT A TOOLTIP FIELD ---------------------------
	--
	--  IT IS SET FOR THE ROW, NOT FOR THE TOOLTIP. petports_help.tooltip
	--  declares no rarityLabel, so nothing in the tooltip reads this. The
	--  ItemSlotWidget in the settings row does: a slot draws its item's rarity
	--  as a border, which means the help mark was announcing itself Common
	--  next to a Legendary module. Matching the owner makes that border say
	--  something true instead.
	--
	--  `config.rarity`, NOT `config.tooltipFields.rarity`. This is an item
	--  field like `price`, which buildwhip and buildbow both write the same
	--  way, and the item is constructed from the config this returns.
	--
	--  PASSED THROUGH VERBATIM, CASE AND ALL. Every module states its rarity
	--  the way a .item file does -- "Rare", "Legendary" -- and re-casing it
	--  here would be this file guessing at the engine's parse rule for no
	--  reason. A string the engine cannot parse throws at construction, which
	--  the pane's own pcall contains: that row loses its mark and logs.
	if type(parameters.helpRarity) == "string" and parameters.helpRarity ~= "" then
		config.rarity = parameters.helpRarity
	end

	return config, parameters
end
