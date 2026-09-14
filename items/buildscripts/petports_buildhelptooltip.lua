-- Fills an item's tooltip subtitle, image and rarity from its helpSubtitle, helpIcon and helpRarity parameters.

-- Writes the help subtitle, image and rarity into the item config.
function build(directory, config, parameters, level, seed)
	config.tooltipFields = config.tooltipFields or {}

	config.tooltipFields.subtitle = parameters.helpSubtitle or ""

	if type(parameters.helpIcon) == "string" and parameters.helpIcon ~= "" then
		config.tooltipFields.objectImage = parameters.helpIcon
	end

	if type(parameters.helpRarity) == "string" and parameters.helpRarity ~= "" then
		config.rarity = parameters.helpRarity
	end

	return config, parameters
end
