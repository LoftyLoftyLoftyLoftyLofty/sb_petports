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

--  THE ROUTE TO THE TITLE ICON IS NOT SETTLED, AND THIS PROBES IT.
--
--  FIRST ATTEMPT, DISPROVEN 2026-08-30: `widget.setImage("title.icon", path)`.
--  The call did not throw and this module logged `applied` four times per pane,
--  AND THE ICON ON SCREEN NEVER CHANGED. The pcall only ever proved the call did
--  not raise; Starbound's widget bindings commonly no-op on a widget that does
--  not resolve, so a successful no-op was being reported as a success. THE
--  DISPROOF CONDITION WAS TOO WEAK -- "it returned" is not "it did something".
--
--  What that leaves: the title icon is almost certainly NOT a child in the
--  pane's addressable widget tree. It is owned by the Pane, the same way
--  ContainerPane owns the header icon it draws from `inventoryIcon` -- see
--  `fact.pane.windowicon`. `title.icon` in the .config is read at construction
--  and does not stay reachable by name.
--
--  SO THIS ASKS THE ENGINE INSTEAD OF GUESSING. Two capabilities, both
--  answerable at runtime, reported once per pane:
--
--    pane.setTitleIcon   the purpose-built route, if ScriptPane exposes it.
--                        `type(...) == "function"` is a FACT, not a hypothesis:
--                        an absent binding is nil and says so immediately.
--
--    widget.getPosition  distinguishes "the widget exists and setImage did
--                        nothing" from "the widget was never there". A binding
--                        that no-ops on setImage will also return nil here.
--
--  THIS IS A PROBE, NOT A FALLBACK LADDER. It names the route it took in the
--  log every time it acts. ONCE THE ANSWER IS IN, DELETE THE LOSING BRANCH --
--  do not leave both wired and do not tune the loser.
PETPORTS_PANEICON_WIDGET = "title.icon"

local probed = false
local route = nil

local function probeOnce()
	if probed then
		return
	end
	probed = true

	local hasSetter = type(pane) == "table" and type(pane.setTitleIcon) == "function"

	--  GUARDED because getPosition on an unresolvable widget may throw rather
	--  than return nil, and the two outcomes are both informative.
	local okPos, posOrErr = pcall(widget.getPosition, PETPORTS_PANEICON_WIDGET)

	sb.logInfo("PETPORTS paneicon PROBE: pane.setTitleIcon is %s; "
		.. "widget.getPosition(%s) -> %s %s",
		type(pane) == "table" and type(pane.setTitleIcon) or "no pane table",
		PETPORTS_PANEICON_WIDGET,
		tostring(okPos),
		okPos and sb.printJson(posOrErr) or tostring(posOrErr))

	if hasSetter then
		route = "pane.setTitleIcon"
	else
		route = "widget.setImage"
	end

	sb.logInfo("PETPORTS paneicon PROBE: taking the %s route", route)
end

--  Returns ok, err. `ok` here means THE ROUTE RAN, which after the first
--  attempt we know is not the same as the icon changing. The screen is still
--  the arbiter; this only reports what was tried.
local function applyByRoute(path)
	probeOnce()

	if route == "pane.setTitleIcon" then
		return pcall(pane.setTitleIcon, path)
	end

	return pcall(widget.setImage, PETPORTS_PANEICON_WIDGET, path)
end

--  CHANGE-GATED, so a pane that calls this every update does not spam. The
--  first call always logs, because the first call is the one carrying the
--  answer to the question above.
local applied = nil
local reported = false

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

	local ok, err = applyByRoute(wanted)

	if ok then
		applied = wanted
		--  INPUTS, NOT JUST THE VERDICT. The state that produced the choice is
		--  logged beside the choice, so a wrong icon can be triaged as either a
		--  wrong state or a wrong mapping without another round.
		--  THE ROUTE IS NAMED so a log cannot be read as proof the icon moved
		--  without saying HOW it was asked to. That ambiguity cost a round.
		sb.logInfo("PETPORTS paneicon set via %s <- %s (enabled %s)",
			tostring(route), wanted, tostring(enabled))
	elseif not reported then
		reported = true
		sb.logError("PETPORTS paneicon REFUSED by %s: %s", tostring(route), tostring(err))
		sb.logError("PETPORTS paneicon: neither route reaches the title icon; "
			.. "the swap needs a plain image widget over the header instead")
	end
end
