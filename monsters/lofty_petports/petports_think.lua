--  PETPORTS -- THINKING INDICATOR
--
--  A sustained "working on it" signal for a unit standing still while
--  something expensive runs. The motivating case is cold-cache route planning,
--  which parks a unit motionless for tens of seconds; without a signal, that
--  reads as broken rather than busy.
--
--  WHY THIS IS NOT AN EMOTE
--
--  groundPet's emote() is a ONE-SHOT BURST -- animator.burstParticleEmitter.
--  Fine for a heart, wrong for a spinner: a spinner is a STATE with a duration,
--  not an event. Re-bursting on a timer to fake duration means matching
--  emission cadence to particle timeToLive, and world particles do not follow
--  the entity -- a unit that hops a vent mid-think leaves its spinner behind in
--  the other room. So this drives a dedicated animation state instead, and does
--  NOT route through emote() or the action cooldowns emote() answers to.
--
--  HEARTBEAT, NOT BEGIN/END
--
--  Callers ping every tick while thinking; nobody ever calls a release. A
--  begin/end pair leaks the moment a code path returns early or gets
--  interrupted -- and update() in the task action returns early in half a dozen
--  places. A heartbeat cannot leak: stop pinging and it goes away by itself.
--
--  CRITICAL: no init, update or uninit here. Every script in a monstertype's
--  list shares one Lua context and a second definition silently replaces the
--  first. State lazy-initialises inside the pump.
--
--  THE PUMP IS CALLED FROM petportsTaskAction.update, AND ONLY FROM THERE.
--
--  Not from petBehavior.run(). That was the first attempt and it failed: run()'s
--  cadence is unverified and may be the querySurroundings cooldown rather than
--  a tick, which feeds a per-tick dt once a second and stretches every timer
--  here by roughly twelve. The symptom was a forced spinner that never expired.
--  petportsTaskAction.update has a verified per-tick dt.
--
--  Exactly ONE host. Two pumps double-count dt and halve both thresholds.
--
--  DO NOT nil-guard the call sites.
--
--  An earlier version wrapped every call as `if petports_think then ... end`,
--  which meant forgetting this file in the monstertype's scripts list disabled
--  the whole feature in SILENCE. That is the same failure mode as a missing
--  contract function, and it cost a debugging session. A missing script FILE
--  raises AssetException and is loud; a nil-guarded call to a function in a
--  file nobody loaded is not. Call petports_think() bare and let it error.

--  Log every state change, plus per-second telemetry while a think is running.
--  Leave OFF once this is trusted -- the pump runs every tick forever.
local THINK_DEBUG = true

--  How long thinking must run CONTINUOUSLY before the indicator appears.
--
--  MEASURED, NOT GUESSED. Instrumented runs show think durations are strongly
--  bimodal: cold-cache route probing runs 45-50s (one PROBE_LIMIT per unknown
--  edge, and there are several), while the jump-arc solve after a vent exit
--  runs about 1.0s. Nothing lands in between.
--
--  This was 1.0, which is the single worst value in that whole range -- it sat
--  exactly on top of the arc solve, so a perfectly ordinary vent exit crossed
--  the threshold at the instant it finished and blipped the spinner for the
--  length of the grace tail. The indicator was working; the threshold was
--  parked on a common case.
--
--  2.0 clears the arc solve with headroom and costs one extra second of
--  stillness before a 47s probe announces itself, which is noise at that scale.
--  Lower it toward 1.5 if two seconds of motionless unit feels too long, but do
--  not go back to 1.0.
local THINK_DELAY = 2.0

--  What counts as ONE think. Bridges a gap of a tick or two so that a single
--  hiccup inside one continuous search does not restart the clock.
--
--  KEEP THIS SMALL. It is the only thing separating one think from the next.
--
--  It was 0.5s, and that was too generous by far. Repathing during a walk pings
--  in short bursts a few tenths of a second apart; at 0.5s every one of those
--  gaps was bridged, so `held` never reset and crept upward across an entire
--  multi-hop journey. The unit would leave its last vent already sitting at
--  0.9-something, and a legitimate split-second jump-arc calculation would tip
--  it over the threshold and blip the spinner.
--
--  At roughly two script ticks, a real gap between two separate thinks breaks
--  the run, which is the point. Pings inside one think arrive every tick, so
--  nothing legitimate is at risk of being split.
local THINK_GRACE = 0.2

--  Once shown, stay shown at least this long.
--
--  Separate constant on purpose. Bridging hiccups wants a SMALL number; not
--  flashing wants a LARGE one. THINK_GRACE used to do both jobs at once, which
--  is how it ended up at a value that was simultaneously too big for the first
--  and too small for the second. A think that runs just past THINK_DELAY needs
--  this floor or it appears and vanishes inside a couple of frames.
local THINK_MIN_SHOW = 0.75

local THINK_STATE_TYPE   = "thinking"
local THINK_STATE_ON     = "spin"
local THINK_STATE_ON_L   = "spinflip"
local THINK_STATE_OFF    = "none"

--  Ping. Call EVERY TICK for as long as the expensive thing is still running.
--  `reason` is for logging only; nothing branches on it.
function petports_think(reason)
  self.petportsThinkPinged = true
  self.petportsThinkReason = reason
end

--  Which of the three states the unit should be showing right now.
local function wantedState(want)
  if not want then return THINK_STATE_OFF end
  return mcontroller.facingDirection() < 0 and THINK_STATE_ON_L or THINK_STATE_ON
end

local function applyState(state)
  local ok, err = pcall(animator.setAnimationState, THINK_STATE_TYPE, state)

  --  NOT flag-gated. If the animation is missing the "thinking" stateType
  --  entirely, this is the only evidence anyone will ever get, and a silent
  --  no-op here looks identical to a spinner that is simply never triggered.
  if not ok then
    sb.logError("UNIT thinking indicator FAILED to set %s/%s: %s",
      THINK_STATE_TYPE, state, tostring(err))
  end
  return ok
end

--  Per-tick pump. Called from petportsTaskAction.update, top of the function so
--  that its early returns cannot skip it. See the header before moving it.
function petports_thinkPump(dt)
  self.petportsThinkHeld     = self.petportsThinkHeld or 0
  self.petportsThinkGrace    = self.petportsThinkGrace or 0
  self.petportsThinkTrace    = self.petportsThinkTrace or 0
  self.petportsThinkShowLeft = self.petportsThinkShowLeft or 0
  self.petportsThinkPeak     = self.petportsThinkPeak or 0
  if self.petportsThinkShown == nil then self.petportsThinkShown = false end

  local pinged = self.petportsThinkPinged
  self.petportsThinkPinged = false

  if pinged then
    self.petportsThinkLastReason = self.petportsThinkReason
    self.petportsThinkHeld = self.petportsThinkHeld + dt
    self.petportsThinkGrace = THINK_GRACE
    if self.petportsThinkHeld > self.petportsThinkPeak then
      self.petportsThinkPeak = self.petportsThinkHeld
    end
  else
    self.petportsThinkGrace = self.petportsThinkGrace - dt
    if self.petportsThinkGrace <= 0 then
      --  The run is over. Discard the clock so the NEXT think is measured on
      --  its own merits rather than inheriting whatever this one accumulated.
      self.petportsThinkHeld = 0
      self.petportsThinkReason = nil
      self.petportsThinkLastReason = nil
    end
    --  Inside the grace window `held` is FROZEN, never advanced. Grace decides
    --  whether the clock is kept or discarded; it does not add to it. Advancing
    --  here would let a sub-threshold think keep climbing after its work had
    --  already finished and trip the threshold post hoc.
  end

  if self.petportsThinkShown then
    self.petportsThinkShowLeft = self.petportsThinkShowLeft - dt
  end

  local want
  if self.petportsThinkShown then
    --  Already up: stay up while the think is still live, or until the
    --  anti-flash floor runs out, whichever is longer.
    want = (self.petportsThinkHeld >= THINK_DELAY and self.petportsThinkGrace > 0)
      or self.petportsThinkShowLeft > 0
  else
    --  Not up yet: the threshold may only be crossed on a tick that actually
    --  CARRIED A PING. Without this, a think could cross it while coasting
    --  through the grace window after its work was done.
    want = pinged and self.petportsThinkHeld >= THINK_DELAY
  end

  --  Telemetry while a think is accumulating, whether or not it ever crosses
  --  the threshold. A think that reaches 0.4s and dies explains a missing
  --  spinner completely, and is invisible without this.
  if THINK_DEBUG and self.petportsThinkHeld > 0 then
    self.petportsThinkTrace = self.petportsThinkTrace - dt
    if self.petportsThinkTrace <= 0 then
      self.petportsThinkTrace = 1.0
      sb.logInfo("UNIT think held %s grace %s want %s shown %s reason %s",
        sb.printJson(self.petportsThinkHeld),
        sb.printJson(self.petportsThinkGrace),
        tostring(want), tostring(self.petportsThinkShown),
        tostring(self.petportsThinkReason))
    end
  end

  --  Compare the STATE NAME, not the boolean. Facing can change while `want`
  --  stays true, and that still needs the animator touched -- tracking only
  --  "shown" would leave a unit that turned mid-think spinning backwards for
  --  the rest of the think.
  --
  --  Still only touched on a change: setAnimationState with the state already
  --  set is cheap but not free, and this runs every tick forever.
  local state = wantedState(want)
  if state ~= self.petportsThinkState then
    applyState(state)

    if want and not self.petportsThinkShown then
      self.petportsThinkShowLeft = THINK_MIN_SHOW
    end

    --  Report the PEAK, not the current value. By the time a think is hidden
    --  the clock has usually been discarded already, so the old message read
    --  "hidden (nil) after 0 s" -- true, and useless. The peak is the one
    --  number that tells you where THINK_DELAY should sit.
    if THINK_DEBUG and want ~= self.petportsThinkShown then
      sb.logInfo("UNIT thinking %s (%s) peak %s s",
        want and "SHOWN" or "hidden",
        tostring(self.petportsThinkReason or self.petportsThinkLastReason),
        sb.printJson(self.petportsThinkPeak))
      if not want then self.petportsThinkPeak = 0 end
    end

    self.petportsThinkState = state
    self.petportsThinkShown = want
  end
end

--  Force it down NOW, without waiting out the grace window. For the cases
--  where the unit is about to stop existing visually: vent travel sets the
--  movement state to "invisible", and a spinner hanging over an invisible unit
--  is a floating orphan.
function petports_thinkClear()
  self.petportsThinkPinged = false
  self.petportsThinkHeld = 0
  self.petportsThinkGrace = 0
  self.petportsThinkShowLeft = 0
  self.petportsThinkPeak = 0
  self.petportsThinkReason = nil
  self.petportsThinkLastReason = nil

  if self.petportsThinkShown then
    applyState(THINK_STATE_OFF)
    self.petportsThinkState = THINK_STATE_OFF
    self.petportsThinkShown = false
  end
end

--  Bench call. Run once from anywhere to prove the animation side works
--  independently of whether anything ever thinks:
--
--      petports_thinkSelfTest()
--
--  Forces the spinner on for five seconds by pinging from nothing. If this
--  shows a spinner and real work does not, the fault is in the CALL SITES; if
--  this shows nothing either, the fault is in the .animation or the assets.
function petports_thinkSelfTest()
  self.petportsThinkHeld = THINK_DELAY
  self.petportsThinkGrace = 5.0
  self.petportsThinkReason = "selftest"
  self.petportsThinkShowLeft = 0
  self.petportsThinkState = wantedState(true)
  applyState(self.petportsThinkState)
  self.petportsThinkShown = true
  sb.logInfo("UNIT thinking SELFTEST forced on")
end
