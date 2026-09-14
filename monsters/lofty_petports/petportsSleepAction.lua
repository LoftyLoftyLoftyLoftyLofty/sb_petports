petportsSleepAction = {
  cooldown = 10
}

local APPROACH_TIMEOUT = 6.0

function petportsSleepAction.description()
  return "sleepAction"
end

function petportsSleepAction.enterWith(args)
  if not config.getParameter("petports_allowSleep", true) then
    sb.logInfo("UNIT sleep refused: petports_allowSleep is false")
    return nil
  end

  if not args.sleepAction and not args.sleepTarget then return nil end

  if args.sleepAction and status.resourcePercentage("sleepy") < 1 then
    return nil
  end

  if args.sleepTarget and status.resource("sleepy") < config.getParameter("actionParams.sleep.minSleepy", 65) then
    return nil
  end

  return {
    targetId = args.sleepTarget,
    sleepRate = -5,
    sleeping = false,
    restPosition = nil,
    approachTimer = APPROACH_TIMEOUT
  }
end

function petportsSleepAction.enteringState(stateData)
  if stateData.targetId then
    emote("sleepy")
  else
    animator.setParticleEmitterActive("sleep", true)
  end
end

local function settleInPlace(dt, stateData)
  if stateData.restPosition == nil then
    local here = mcontroller.position()

    if petports_canRestAt(here) then
      stateData.restPosition = here
    else
      stateData.restPosition = petports_findRestPosition(here, 6)

      if stateData.restPosition == nil then
        return true, config.getParameter("actionParams.sleep.cooldown", 15)
      end
    end
  end

  if world.magnitude(mcontroller.position(), stateData.restPosition) <= 0.5 then
    stateData.sleeping = true
    animator.setParticleEmitterActive("sleep", true)
    return false
  end

  stateData.approachTimer = stateData.approachTimer - dt
  if stateData.approachTimer <= 0 or self.pathing.stuck then
    return true, config.getParameter("actionParams.sleep.cooldown", 15)
  end

  approachPoint(dt, stateData.restPosition, 0.5, false)
  return false
end

local function settleAtTarget(dt, stateData)
  if not world.entityExists(stateData.targetId) then return true end

  local targetPosition = petports_perchPosition(stateData.targetId)
    or world.entityPosition(stateData.targetId)
  if targetPosition == nil then return true end

  if not approachPoint(dt, targetPosition, 1.5, false) then
    if self.pathing.stuck then
      return true, config.getParameter("actionParams.sleep.cooldown", 15)
    end
    return false
  end

  if not petports_settleAt(targetPosition, { ignoreEntityId = stateData.targetId }) then
    return true, config.getParameter("actionParams.sleep.cooldown", 15)
  end

  animator.setParticleEmitterActive("sleep", true)
  stateData.sleeping = true
  return false
end

function petportsSleepAction.update(dt, stateData)
  if not stateData.sleeping then
    if stateData.targetId then
      return settleAtTarget(dt, stateData)
    else
      return settleInPlace(dt, stateData)
    end
  end

  status.modifyResource("sleepy", stateData.sleepRate * dt)

  if stateData.targetId then
    if not world.entityExists(stateData.targetId) then
      return true, config.getParameter("actionParams.sleep.cooldown", 15)
    end
    animator.setAnimationState("movement", "invisible")
  else
    animator.setAnimationState("movement", "sleep")
  end

  if status.resourcePercentage("sleepy") <= 0 then
    return true, config.getParameter("actionParams.sleep.cooldown", 15)
  end

  return false
end

function petportsSleepAction.leavingState(stateData)
  setIdleState()
  animator.setParticleEmitterActive("sleep", false)
end
