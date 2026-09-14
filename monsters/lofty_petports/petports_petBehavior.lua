local RUN_CADENCE_DEBUG = false

petBehavior = {
  actionQueue = {}
}

local TASK_SCORE = 150

local LEASH_SCORE = 120

function petBehavior.init()

  petBehavior.entityTypeReactions = {
    ["player"] = petBehavior.reactToPlayer,
    ["itemDrop"] = petBehavior.reactToItemDrop,
    ["monster"] = petBehavior.reactToMonster,
    ["object"] = petBehavior.reactToObject
  }

  petBehavior.actions = {
    ["emote"] = petBehavior.emote
  }

  petBehavior.actionStates = {
    ["inspect"] = "inspectAction",
    ["follow"] = "followAction",
    ["eat"] = "eatAction",
    ["beg"] = "begAction",
    ["play"] = "pounceAction",
    ["sleep"] = "sleepAction",
    ["petportsTask"] = "petportsTaskAction"
  }

  self.currentActionScore = 0
  self.actionParams = config.getParameter("actionParams")
  self.actionInterruptThreshold = config.getParameter("actionParams.interruptThreshold", 15)
  self.inspected = {}

  self.petportsTask = self.petportsTask or nil
end

local SURFACE_NUDGE_REACH = 3

function petBehavior.queueAction(type, args, score)
  table.insert(petBehavior.actionQueue, {type = type, args = args, score = score})
end

function petBehavior.performAction(action)
  if petBehavior.actions[action.type] and self.actionCooldowns[action.type] <= 0 and self.actionState.stateDesc() == "" then
    return petBehavior.actions[action.type](args)
  end

  return false
end

function petBehavior.run()
  if petports_bubbleHeartbeat ~= nil then petports_bubbleHeartbeat() end

  if RUN_CADENCE_DEBUG then
    self.runCadenceCalls = (self.runCadenceCalls or 0) + 1
    self.runCadenceClock = (self.runCadenceClock or 0) + script.updateDt()
    if self.runCadenceClock >= 5.0 then
      sb.logInfo("BEHAVIOR run() %s calls per 5.0 script-seconds -- if these "
        .. "lines are 5s apart it is per-tick, if ~60s apart it is throttled",
        sb.printJson(self.runCadenceCalls))
      self.runCadenceCalls = 0
      self.runCadenceClock = 0
    end
  end

  if self.actionState.stateDesc() == "" then
    self.currentActionScore = 0
  end

  petports_swimModeTick()

  local mediumReport = petports_outOfMedium()
  local beached = mediumReport.checked and mediumReport.out

  if beached then
    if not config.getParameter("petports_canSwim", false)
       and not self.petportsSurfaceNudged then

      self.petportsSurfaceNudged = true

      local here = mcontroller.position()
      local bounds = mcontroller.boundBox()
      local moved = nil

      for rise = 1, SURFACE_NUDGE_REACH do
        local candidate = { here[1], here[2] + rise }

        local box = {
          candidate[1] + bounds[1], candidate[2] + bounds[2],
          candidate[1] + bounds[3], candidate[2] + bounds[4]
        }

        if not world.rectTileCollision(box, { "Null", "Block", "Dynamic" })
           and petports_mediumAllows(candidate, bounds) then
          mcontroller.setPosition(candidate)
          mcontroller.setVelocity({ 0, 0 })
          moved = candidate
          break
        end
      end

      sb.logInfo("BEHAVIOR surface nudge for a non-swimmer at %s (medium %s): %s",
        sb.printJson(here), tostring(mediumReport.medium),
        moved ~= nil
          and ("lifted to " .. sb.printJson(moved))
          or ("nothing clear within " .. sb.printJson(SURFACE_NUDGE_REACH)
              .. " tiles above -- leaving it to the port"))
    end

    if self.actionState ~= nil and self.actionState.stateDesc() ~= "" then
      sb.logInfo("BEHAVIOR ending action %s -- unit is beached and the action "
        .. "slot has to be empty before the flop state can tick",
        tostring(self.actionState.stateDesc()))
      self.actionState.endState()
    end

    if self.state ~= nil and self.state.stateDesc() ~= "petportsFlopState" then
      local picked = self.state.pickState({ petportsFlopState = true })

      if not picked and self.petportsFlopPickFailed ~= true then
        self.petportsFlopPickFailed = true
        sb.logInfo("BEHAVIOR flop pick REFUSED while out of medium (%s) -- "
          .. "state is %s. petportsFlopState.enterWith returned nil, or the "
          .. "state is not in this chassis's scripts list.",
          tostring(mediumReport.medium),
          tostring(self.state.stateDesc()))
      elseif picked then
        self.petportsFlopPickFailed = nil
      end
    end

    if self.petportsBeachedQuiet ~= true then
      self.petportsBeachedQuiet = true
      sb.logInfo("BEHAVIOR suppressing task actions -- unit is out of its medium "
        .. "(%s). It will hold task %s and resume when it is back in water.",
        tostring(mediumReport.medium),
        tostring(self.petportsTask and self.petportsTask.id or "none"))
    end

    petBehavior.actionQueue = {}
    self.currentActionScore = 0
    return
  end

  if self.petportsTask ~= nil then
    self.petportsSurfaceNudged = nil

    if self.petportsBeachedQuiet then
      self.petportsBeachedQuiet = nil
      sb.logInfo("BEHAVIOR resuming task actions -- unit is back in its medium, "
        .. "task %s was held throughout", tostring(self.petportsTask.id))
    end

    petBehavior.queueAction(
      "petportsTask",
      { petportsTask = self.petportsTask },
      TASK_SCORE
    )
  else
    local leash = petports_leashTask and petports_leashTask() or nil
    if leash ~= nil then
      petBehavior.queueAction("petportsTask", { petportsTask = leash }, LEASH_SCORE)
    end
  end

  for actionName, _ in pairs(petBehavior.actionStates) do
    if actionName ~= "petportsTask" then
      petBehavior.queueAction(actionName)
    end
  end

  for _, queuedAction in pairs(petBehavior.actionQueue) do
    queuedAction.score = queuedAction.score or petBehavior.scoreAction(queuedAction.type)
  end
  table.sort(petBehavior.actionQueue, function(a, b) return a.score > b.score end)

  for _, action in pairs(petBehavior.actionQueue) do
    if action.score <= 0 or action.score <= self.currentActionScore + self.actionInterruptThreshold then break end

    local picked = false
    if not self.actionParams[action.type] or action.score > self.actionParams[action.type].minScore then
      if petBehavior.actionStates[action.type] and self.actionState.stateDesc() ~= petBehavior.actionStates[action.type] then
        if (action.args and self.actionState.pickState(action.args)) then
          picked = true
        elseif(petBehavior.actionStates[action.type] and self.actionState.pickState({[petBehavior.actionStates[action.type]] = true})) then
          picked = true
        end
      elseif petBehavior.actions[action.type] and petBehavior.performAction(action.type) then
        picked = true
      end
    end

    if picked then
      self.currentActionScore = action.score
      break
    end
  end

  petBehavior.actionQueue = {}
end

function petBehavior.scoreAction(action)
  if action == "eat" or action == "beg" then
    return status.resource("hunger")

  elseif action == "follow" then
    return status.resource("curiosity")

  elseif action == "inspect" then
    return status.resource("curiosity")

  elseif action == "play" then
    return status.resource("playful")

  elseif action == "sleep" then
    if not config.getParameter("petports_allowSleep", true) then return 0 end
    return status.resource("sleepy")

  elseif action == "emote" then
    return 100

  elseif action == "petportsTask" then
    if self.petportsTask then return TASK_SCORE end
    return self.petportsLeashTask and LEASH_SCORE or 0

  else
    return 0
  end
end


function petBehavior.reactTo(entityId)
  local entityType = world.entityType(entityId)

  if petBehavior.entityTypeReactions[entityType] then
    petBehavior.entityTypeReactions[entityType](entityId)
  end
end

function petBehavior.reactToPlayer(entityId)
  local playerUuid = world.entityUniqueId(entityId)

  local primaryItem = world.entityHandItem(entityId, "primary")
  local altItem = world.entityHandItem(entityId, "alt")
  local foodLiking = itemFoodLiking(primaryItem) or itemFoodLiking(altItem)
  if foodLiking then
    local score = status.resource("hunger") - (100 - foodLiking)
    petBehavior.queueAction("beg", {begTarget = entityId}, score)
  end

  if storage.knownPlayers[tostring(playerUuid)] then
    petBehavior.queueAction("follow", {followTarget = entityId})
  else
    petBehavior.queueAction("inspect", {inspectTarget = entityId, approachDistance = 4})
  end
end

function petBehavior.reactToItemDrop(entityId)
  local entityName = world.entityName(entityId)
  local foodLiking = itemFoodLiking(entityName)
  if foodLiking then
    local score = status.resource("hunger") - (100 - foodLiking)
    petBehavior.queueAction("eat", {eatTarget = entityId}, score)
  elseif foodLiking == nil then
    petBehavior.queueAction("inspect", {inspectTarget = entityId, approachDistance = 2}, status.resource("hunger"))
  end
end

function petBehavior.reactToMonster(entityId)
  local entityName = world.monsterType(entityId)
  if entityName == "petball" then
    petBehavior.queueAction("play", {pounceTarget = entityId})
  end
end

function petBehavior.reactToObject(entityId)
  local entityName = world.entityName(entityId)
  if entityName == "pethouse" then
    if not config.getParameter("petports_allowSleep", true) then return end
    petBehavior.queueAction("sleep", {sleepTarget = entityId})
  end
end


function petBehavior.emote(emoteName)
  emote(emoteName)
  return false
end
