-- Sets a pane's title icon from an on/off image pair.

local applied = nil

-- Sets the title icon to paths.on or paths.off, skipping the call when that asset is already applied.
function petports_applyPaneIcon(paths, enabled)
	if type(paths) ~= "table" or paths.on == nil or paths.off == nil then
		sb.logError("petports: petports_applyPaneIcon needs both an on and an off asset")
		return
	end

	local wanted = paths.off
	if enabled ~= false then
		wanted = paths.on
	end

	if wanted == applied then
		return
	end

	pane.setTitleIcon(wanted)
	applied = wanted

	sb.logInfo("PETPORTS paneicon set via pane.setTitleIcon <- %s (enabled %s)",
		wanted, tostring(enabled))
end
