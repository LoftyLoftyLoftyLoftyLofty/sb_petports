local THINK_DEBUG = true

local THINK_DELAY = 2.0

local THINK_GRACE = 0.2

local THINK_MIN_SHOW = 0.75

local THINK_STATE_TYPE   = "thinking"
local THINK_STATE_ON     = "spin"
local THINK_STATE_ON_L   = "spinflip"
local THINK_STATE_OFF    = "none"

function petports_think(reason)
  self.petportsThinkPinged = true
  self.petportsThinkReason = reason
end

local function wantedState(want)
  if not want then return THINK_STATE_OFF end
  return mcontroller.facingDirection() < 0 and THINK_STATE_ON_L or THINK_STATE_ON
end

local function applyState(state)
  local ok, err = pcall(animator.setAnimationState, THINK_STATE_TYPE, state)

  if not ok then
    sb.logError("UNIT thinking indicator FAILED to set %s/%s: %s",
      THINK_STATE_TYPE, state, tostring(err))
  end
  return ok
end

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
      self.petportsThinkHeld = 0
      self.petportsThinkReason = nil
      self.petportsThinkLastReason = nil
    end
  end

  if self.petportsThinkShown then
    self.petportsThinkShowLeft = self.petportsThinkShowLeft - dt
  end

  local want
  if self.petportsThinkShown then
    want = (self.petportsThinkHeld >= THINK_DELAY and self.petportsThinkGrace > 0)
      or self.petportsThinkShowLeft > 0
  else
    want = pinged and self.petportsThinkHeld >= THINK_DELAY
  end

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

  local state = wantedState(want)
  if state ~= self.petportsThinkState then
    applyState(state)

    if want and not self.petportsThinkShown then
      self.petportsThinkShowLeft = THINK_MIN_SHOW
    end

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
