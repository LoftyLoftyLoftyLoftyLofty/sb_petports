--  PETPORTS -- BEHAVIOR LAYER
--
--  A FORK of /monsters/pets/petBehavior.lua. Vanilla's file must be REMOVED
--  from the monstertype's scripts list; this one defines the same global, so
--  groundPet.lua calls into it unmodified.
--
--  WHY FORK RATHER THAN WRAP
--
--  Registering a new action state means adding to petBehavior.actionStates,
--  which vanilla REBUILDS WHOLESALE inside petBehavior.init(). Adding at load
--  time is overwritten; adding afterwards means wrapping init, and a wrapper is
--  load-order dependent the moment another mod wraps the same function. Owning
--  the file removes the whole class of problem, and keeps another mod's
--  experiment on vanilla pet behaviour from reaching into our units.
--
--  Vanilla's file is untouched. Nothing is clobbered; ours simply is not
--  vanilla's.
--
--  WHAT CHANGED FROM VANILLA
--
--  1.  "petportsTask" registered in actionStates, scored as WORK rather than
--      appetite -- see scoreAction.
--  2.  run() re-asserts a held task every tick. See the note below; this is
--      NOT optional.
--  3.  "starving" removed from actionStates. Vanilla lists it but scoreAction
--      has no branch for it, so it always scores 0 and can never be picked.
--      Our units do not starve to death anyway.
--
--  THE QUEUE IS NOT A QUEUE
--
--  The last line of run() is `petBehavior.actionQueue = {}`, and the first
--  thing run() does is re-queue every action state from scratch. It is a
--  PER-TICK SCORING BUCKET, not a work queue. A task queued once vanishes on
--  the next tick.
--
--  So the unit holds its assignment in self.petportsTask (durable, set by the
--  petport through the contract) and re-queues it every single tick. The
--  petport dispatches STATE, not an event.

petBehavior = {
  actionQueue = {}
}

--  Work outranks every appetite. Appetites cap at 100.
--
--  Note the consequence, because it is not obvious from the number: run()'s
--  pick loop BREAKS rather than continues, and currentActionScore holds for the
--  life of the running state, so a task at this score is also UNINTERRUPTIBLE
--  while it runs. Correct for the diagnostic task. When real tasks land, hunger
--  needs to be able to interrupt work, and this is the knob that stops it.
local TASK_SCORE = 150

--  Walking back inside the network outranks every appetite, but loses to real
--  work -- a unit already carrying out a task must not abandon it to come home,
--  and a task may legitimately path outside the network.
--
--  THE LEASH BOUNDS WHERE A UNIT GOES ON ITS OWN INITIATIVE, NOT WHERE A PATH
--  MAY LEAD. That distinction is what makes this cheap: no inspecting waypoints
--  against rects, no aborting mid-route when a jump arc clips outside. While a
--  task is held, unbounded; while idle, bounded.
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

  --  Assignment from the petport. Contract functions in petports_contract.lua
  --  read and write it; nothing here creates work on its own.
  self.petportsTask = self.petportsTask or nil
end

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
  if self.actionState.stateDesc() == "" then
    self.currentActionScore = 0
  end

  --  Re-assert the held task. Every tick, unconditionally -- see the header.
  if self.petportsTask ~= nil then
    petBehavior.queueAction(
      "petportsTask",
      { petportsTask = self.petportsTask },
      TASK_SCORE
    )
  else
    --  No work. If the unit has wandered outside its network, coming home is
    --  what it does instead of wandering further.
    local leash = petports_leashTask and petports_leashTask() or nil
    if leash ~= nil then
      petBehavior.queueAction("petportsTask", { petportsTask = leash }, LEASH_SCORE)
    end
  end

  for actionName, _ in pairs(petBehavior.actionStates) do
    --  Already queued above, with its args. Queueing it again bare would let
    --  the argless fallback in the pick loop enter the state with no task.
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
    return status.resource("sleepy")

  elseif action == "emote" then
    return 100

  --  Work is not an appetite. A held task always scores the same; whether the
  --  unit HAS one is the only variable.
  elseif action == "petportsTask" then
    if self.petportsTask then return TASK_SCORE end
    return self.petportsLeashTask and LEASH_SCORE or 0

  else
    return 0
  end
end

----------------------------------------
--ENTITY REACTIONS
----------------------------------------

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
    petBehavior.queueAction("sleep", {sleepTarget = entityId})
  end
end

----------------------------------------
--ACTIONS
----------------------------------------

function petBehavior.emote(emoteName)
  emote(emoteName)
  return false
end
