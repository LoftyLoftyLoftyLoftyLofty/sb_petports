--  SHARED PANE TITLE ICON, LOADED ONCE PER PANE.
--
--  A beacon's title icon reflects whether the beacon is enabled: one image for
--  on, another for off, swapped when the box is ticked and seeded from the real
--  state when the pane opens.
--
--  WHY THIS IS A MODULE AND NOT SIX LINES IN EACH PANE. The deposit and restock
--  panes carry the same enabled checkbox, the same handler shape and the same
--  init seeding, and `arch.pane.duplication` is the recurring bug in this file
--  tree: logic copied into two panes drifts apart, and the copy that is not
--  being looked at is the one that rots. The exempt ordering bug, the checkbox
--  applyState bug and the warning ladder were all this. Two call sites, one
--  implementation.
--
--  REQUIRED FROM /scripts/lofty_petports/, which is the only require path
--  proven to work from a pane script -- see the header of petports_strings.lua
--  for why the data lives under /interface and the code does not.

--  THE ROUTE IS `pane.setTitleIcon`, AND IT IS SETTLED.
--
--    void pane.setTitleIcon(String image)
--
--  Confirmed in game 2026-08-30 on both beacon panes -- see
--  `fact.pane.titleicon`. The .config's `icon` block still owns the icon's
--  POSITION and its spacing from the title text; this only swaps the image.
--
--  THE LOSING BRANCH IS DELETED RATHER THAN LEFT WIRED.
--  `widget.setImage("title.icon", path)` was the first attempt. It neither threw
--  nor changed anything: the title icon is owned by the Pane and is not in the
--  addressable widget tree, and Starbound's widget bindings no-op on a name that
--  does not resolve. Wrapped in a pcall it reported a successful NO-OP as a
--  success, four times per pane, while the screen showed one icon throughout.
--  `proc.tooling.guardedcall` carries the general form, which is the part worth
--  keeping: A GUARD PROVES THE CALL RAN, NEVER THAT IT DID ANYTHING.
--
--  NOTHING HERE IS GUARDED NOW, DELIBERATELY. There is no second route to fall
--  back to and no question left to probe, so a failure should be loud rather
--  than swallowed. An absent binding would mean a Starbound version change,
--  which is worth finding out about immediately and not worth hiding.

--  CHANGE-GATED, so a pane that calls this every update does not spam. The
--  first call always logs, so the seed at init is visible as well as the
--  toggles after it.
local applied = nil

--  paths  { on = "<asset>", off = "<asset>" }
--  enabled  the beacon's real state, not the checkbox's pre-script default
function petports_applyPaneIcon(paths, enabled)
	if type(paths) ~= "table" or paths.on == nil or paths.off == nil then
		sb.logError("petports: petports_applyPaneIcon needs both an on and an off asset")
		return
	end

	--  ABSENT READS AS ON, matching `self.state.enabled ~= false` in both panes.
	--  Written as an explicit comparison rather than a truthiness test so that
	--  nil and false are distinguishable here if that ever stops being true --
	--  see `fact.tooling.andnilor` for what the compact idiom costs.
	local wanted = paths.off
	if enabled ~= false then
		wanted = paths.on
	end

	if wanted == applied then
		return
	end

	pane.setTitleIcon(wanted)
	applied = wanted

	--  INPUTS, NOT JUST THE VERDICT. The state that produced the choice is
	--  logged beside the choice, so a wrong icon triages as a wrong state or a
	--  wrong mapping without another round. And it says what was ASKED of the
	--  engine rather than claiming an outcome -- the screen decides that.
	sb.logInfo("PETPORTS paneicon set via pane.setTitleIcon <- %s (enabled %s)",
		wanted, tostring(enabled))
end
