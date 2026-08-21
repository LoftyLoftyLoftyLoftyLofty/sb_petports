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
--  Worth knowing before tuning this: an ordinary A* over open ground resolves
--  in a few hundred ms, so normal walking will NEVER trip a 1.0s threshold.
--  That is deliberate -- a spinner at every re-plan is worse than no spinner --
--  but it also means "the spinner never shows on flat ground" is correct
--  behaviour and not a bug. Cold-cache probing is what this exists for.
local THINK_DELAY = 1.0

--  How long after the last ping before it comes down. Must exceed one script
--  tick comfortably -- monsters run on scriptDelta, not per frame -- so a
--  single-tick gap between two phases of one think does not blink it off and
--  on. Must stay well under THINK_DELAY so a lone stray ping can never
--  accumulate its way to the threshold.
local THINK_GRACE = 0.5

--  Declared in the unit's .animation as a SEPARATE stateType from "movement".
--  Setting a state type that does not exist RAISES, which is the good case:
--  a typo here is loud rather than invisible.
local THINK_STATE_TYPE = "thinking"
local THINK_STATE_ON   = "spin"
local THINK_STATE_OFF  = "none"

--  Ping. Call EVERY TICK for as long as the expensive thing is still running.
--  `reason` is for logging only; nothing branches on it.
function petports_think(reason)
  self.petportsThinkPinged = true
  self.petportsThinkReason = reason
end

local function applyState(want)
  local state = want and THINK_STATE_ON or THINK_STATE_OFF
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
  self.petportsThinkHeld  = self.petportsThinkHeld or 0
  self.petportsThinkGrace = self.petportsThinkGrace or 0
  self.petportsThinkTrace = self.petportsThinkTrace or 0
  if self.petportsThinkShown == nil then self.petportsThinkShown = false end

  if self.petportsThinkPinged then
    self.petportsThinkPinged = false
    self.petportsThinkHeld = self.petportsThinkHeld + dt
    self.petportsThinkGrace = THINK_GRACE
  else
    self.petportsThinkGrace = self.petportsThinkGrace - dt
    if self.petportsThinkGrace <= 0 then
      --  Nobody has thought for a while. Forget the run entirely, so the next
      --  think starts its own clock rather than inheriting a stale one.
      self.petportsThinkHeld = 0
      self.petportsThinkReason = nil
    else
      --  Inside the grace window: keep the clock running so a one-tick gap
      --  between two phases of the same think reads as one continuous think.
      self.petportsThinkHeld = self.petportsThinkHeld + dt
    end
  end

  local want = self.petportsThinkHeld >= THINK_DELAY
    and self.petportsThinkGrace > 0

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

  --  Only touch the animator on a CHANGE. setAnimationState with the state
  --  already set is cheap but not free, and this runs every tick forever.
  if want ~= self.petportsThinkShown then
    applyState(want)
    self.petportsThinkShown = want

    if THINK_DEBUG then
      sb.logInfo("UNIT thinking %s (%s) after %s s",
        want and "SHOWN" or "hidden",
        tostring(self.petportsThinkReason),
        sb.printJson(self.petportsThinkHeld))
    end
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
  self.petportsThinkReason = nil

  if self.petportsThinkShown then
    applyState(false)
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
  applyState(true)
  self.petportsThinkShown = true
  sb.logInfo("UNIT thinking SELFTEST forced on")
end
