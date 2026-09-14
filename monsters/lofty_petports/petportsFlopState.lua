-- Monster state that hops a beached unit until it is back in liquid.

require "/scripts/util.lua"

petportsFlopState = {}

FLOP_BOUNCE_FACTOR = 0.6

FLOP_AIR_FRICTION = 0.5
FLOP_LIQUID_FRICTION = 1.5
FLOP_JUMP_PROFILE = {
  jumpSpeed = 15.0,
  jumpControlForce = 900.0,
  jumpInitialPercentage = 1.0,
  jumpHoldTime = 0.0,
  multiJump = false,
  reJumpDelay = 0.05,
  autoJump = false,
  collisionCancelled = true
}

FLOP_JUMP_INTERVAL = {0.3, 1.5}

FLOP_BUILD_STAMP = "2026-09-02a never for a gravity-switchable chassis"

FLOP_MEDIA = {
  air = true,
  mixed = true
}

-- Returns flop state data when a non-gravity-switchable swimmer is stranded in air, otherwise nil.
function petportsFlopState.enter()
  if petports_gravitySwitchable() then return nil end

  local report = petports_outOfMedium()

  if not report.checked or not report.out then return nil end

  if not config.getParameter("petports_canSwim", false) then
    if self.petportsFlopWrongMedium ~= "cannotswim" then
      self.petportsFlopWrongMedium = "cannotswim"

      sb.logInfo("UNIT is out of its medium at %s (reads %s) but cannot swim -- "
        .. "flopping drops a body toward liquid and this chassis does not want "
        .. "to be in any. Leaving this to the port's medium check.",
        sb.printJson(report.position), tostring(report.medium))
    end

    return nil
  end

  if not FLOP_MEDIA[report.medium] then
    if self.petportsFlopWrongMedium ~= report.medium then
      self.petportsFlopWrongMedium = report.medium

      sb.logInfo("UNIT is out of its medium at %s (reads %s) but flopping would "
        .. "not help -- a flop only rescues a unit stranded in air. Leaving this "
        .. "to the port's medium check.",
        sb.printJson(report.position), tostring(report.medium))
    end

    return nil
  end

  self.petportsFlopWrongMedium = nil

  return {
    jumpTimer = 0,
    jumpDirection = util.randomDirection(),
    flopTime = 0,
    reported = false
  }
end

-- Calls enter and ignores the arguments.
function petportsFlopState.enterWith(args)
  return petportsFlopState.enter()
end

-- Sets the flopping animation and logs the position.
function petportsFlopState.enteringState(stateData)
  animator.setAnimationState("movement", "flopping")

  sb.logInfo("UNIT BEACHED at %s -- flopping (flop build %s). The port's medium "
    .. "check will re-home this unit if it cannot get itself back into water "
    .. "first.",
    sb.printJson(mcontroller.position()), FLOP_BUILD_STAMP)
end

-- Applies the flop movement parameters and jumps in a random direction on an interval, returning true once back in medium.
function petportsFlopState.update(dt, stateData)
  local report = petports_outOfMedium()

  if not report.checked or not report.out then
    sb.logInfo("UNIT un-beached at %s after %ss of flopping -- self-rescued, "
      .. "no re-home needed", sb.printJson(mcontroller.position()),
      sb.printJson(math.floor(stateData.flopTime * 10) / 10))
    return true
  end

  stateData.flopTime = stateData.flopTime + dt

  mcontroller.controlParameters({
    gravityEnabled = true,
    bounceFactor = FLOP_BOUNCE_FACTOR,
    airFriction = FLOP_AIR_FRICTION,
    liquidFriction = FLOP_LIQUID_FRICTION,
    airJumpProfile = FLOP_JUMP_PROFILE
  })

  stateData.jumpTimer = stateData.jumpTimer - dt

  if mcontroller.onGround() then
    if stateData.jumpTimer <= 0 then
      stateData.jumpDirection = util.randomDirection()
      mcontroller.controlMove(stateData.jumpDirection)
      mcontroller.controlJump()
    else
      mcontroller.controlDown()
    end
  end

  if stateData.jumpTimer <= 0 then
    stateData.jumpTimer = util.randomInRange(
      config.getParameter("petports_flopJumpInterval", FLOP_JUMP_INTERVAL))
  end

  return false
end

-- Does nothing.
function petportsFlopState.leavingState(stateData)
end
