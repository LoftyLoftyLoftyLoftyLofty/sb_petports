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
--  CADENCE IS UNVERIFIED -- DO NOT HANG TIMERS OFF THIS
--
--  The note below says run() re-asserts the task "every tick". That was
--  inferred from the re-assert WORKING, which it would at 1 Hz just as well:
--  once the action state is entered it stays entered until it returns true, so
--  a slow re-assert is indistinguishable from a fast one.
--
--  Vanilla groundPet.lua may well call this on the querySurroundings cooldown
--  (1s in the monstertype) rather than per tick. The thinking indicator was
--  pumped from here first and produced a spinner that would not expire, which
--  is exactly what a twelvefold-stretched timer looks like. It now pumps from
--  petportsTaskAction.update, whose per-tick dt is verified.
--
--  Anything that needs a real dt belongs in an action state's update, not here.
--  Set RUN_CADENCE_DEBUG below to settle the question properly.
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

--  Measure run()'s real cadence. Accumulates SCRIPT dt per call and logs every
--  time that sum reaches 5.
--
--  Read the result off the WALL CLOCK, not the number: if run() is per-tick,
--  the accumulated script-dt tracks real time and lines land every 5 real
--  seconds. If it is throttled to 1 Hz, the same sum needs roughly a minute of
--  real time to get there. The gap between log lines is the answer, and it
--  needs no API whose behaviour is itself in question.
local RUN_CADENCE_DEBUG = false

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
  --  DO NOT SET THE SCRIPT UPDATE DELTA HERE. TRIED, AND IT MADE THINGS WORSE.
  --
  --  script.setUpdateDelta(1) IS accepted in a monster context -- it logged
  --  "delta set to 1 (dt now 0.0166667)" cleanly. But the cadence did not
  --  change: pre-move samples stayed at 0.0820s median, 4.92 engine ticks,
  --  and the repro drop came out bit-identical to the four runs before it.
  --
  --  So the call moves what script.updateDt() REPORTS without moving when
  --  update() is actually called, which is strictly worse than doing nothing.
  --  Every timer in this mod accumulates that dt -- petBehavior.run's cadence
  --  clock, THINK_DELAY, AIRBORNE_EDGE_STALL, SETTLE_GRACE, APPROACH_TIMEOUT,
  --  the vent timeouts, keepDropping's countdown. All of them would run at a
  --  fifth of real time while the world ran at full speed, and a 30-second lap
  --  is short enough to hide that.
  --
  --  "scriptDelta" in the monstertype's baseParameters was also tried, with no
  --  effect at all. If the update rate is ever worth chasing again, find a
  --  VANILLA monstertype that changes it and copy the key and its placement --
  --  do not infer either.

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

--  HOW FAR ABOVE ITSELF A DROWNING NON-SWIMMER WILL LOOK FOR AIR.
--
--  3 tiles. A surface graze is a matter of tenths, so one tile almost always
--  does it; three gives a little room for a unit that sank slightly before the
--  medium check noticed, without turning a nudge into a teleport across a cave.
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

  --  BEACHED SUPPRESSION. WITHOUT THIS THE FLOP CAN NEVER RUN.
  --
  --  petportsTaskAction.update yields on petports_outOfMedium so the unit can
  --  flop -- but yielding only ENDS the action. The re-assert below runs every
  --  tick and would put it straight back at TASK_SCORE, so the measured result
  --  was 91 yields in 8 seconds, 80ms apart, and the flop state never reached
  --  once. A plain %a+State only runs while actionState is empty, so the queue
  --  has to stay empty too.
  --
  --  QUEUE NOTHING RATHER THAN SCORE IT LOWER. Any positive score re-enters the
  --  action; a beached unit must hold NO action at all for petportsFlopState to
  --  be picked.
  --
  --  self.petportsTask IS NOT CLEARED. The task is still held and still owed a
  --  report -- it is simply not offered while the unit cannot work. The moment
  --  the medium clears, the re-assert below resumes and the unit carries on with
  --  the same task rather than needing a fresh dispatch.
  --
  --  WALKERS NEVER PAY FOR THIS. petports_outOfMedium short-circuits on
  --  petports_freeMover, which is one baseParameters read.
  local mediumReport = petports_outOfMedium()
  local beached = mediumReport.checked and mediumReport.out

  --  Re-assert the held task. Every tick, unconditionally -- see the header.
  if beached then
    --  A NON-SWIMMER THAT CLIPPED THE WATER GETS ONE NUDGE UPWARD.
    --
    --  MEASURED 2026-09-01: a flyer string-pulling across a pond grazed the
    --  surface, failed its medium test, and then simply waited for the port's
    --  re-home -- because petportsFlopState correctly refuses it. A flop drops a
    --  body toward liquid, which is the wrong direction for something drowning.
    --
    --  BUT WAITING IS ALSO WRONG. Rising a tile is trivially within a flyer's
    --  means and the whole episode is usually a graze of a few tenths of a tile.
    --  Ten seconds of stillness for that is a bug the player can see.
    --
    --  ONCE PER EPISODE, NOT A RESCUE LOOP. If one nudge does not clear it the
    --  unit is genuinely stuck -- wedged under an overhang, or in a pool with no
    --  air above it -- and repeating would be a unit bouncing against a ceiling
    --  until the timer ran out. The port's medium check is the answer to that,
    --  and it is already counting.
    --
    --  setPosition, NOT AN IMPULSE. A flyer carries airFriction 24 and
    --  liquidFriction 24, so a velocity nudge is eaten within a few ticks and
    --  may not clear the surface at all. Placement is the sanctioned call for
    --  exactly this -- see the flop state's note on controlDown.
    --
    --  THE DESTINATION IS TESTED BEFORE IT IS USED, both for terrain and for
    --  medium, so this can never place a unit inside a wall or somewhere its
    --  chassis likes even less than where it started.
    if not config.getParameter("petports_canSwim", false)
       and not self.petportsSurfaceNudged then

      self.petportsSurfaceNudged = true

      local here = mcontroller.position()
      local bounds = mcontroller.boundBox()
      local moved = nil

      for rise = 1, SURFACE_NUDGE_REACH do
        local candidate = { here[1], here[2] + rise }

        --  THE BOX IS TRANSLATED BY HAND. rect.lua is not in any chassis's
        --  scripts list, so rect.translate here would be a nil call -- four
        --  sums cost less than adding a shared library to five monstertypes.
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

    --  END WHATEVER ACTION IS ALREADY RUNNING. SUPPRESSION ALONE CANNOT.
    --
    --  groundPet.update only ticks the plain-state machine when the action slot
    --  is empty:
    --
    --      if self.actionState.stateDesc() == "" and not self.state.update(dt)
    --
    --  Suppressing the queue below stops a NEW action being picked, but an
    --  action already in flight keeps the slot until it finishes on its own --
    --  and inspect, follow, beg, eat and play are all VANILLA and have no idea
    --  beaching exists. Measured 2026-09-01: the flop state was entered by the
    --  forced pick below and then never ticked once, because inspectAction was
    --  mid-run and held the slot.
    --
    --  endState IS THE CLEAN EXIT, NOT A CANCEL. stateMachine.endState calls the
    --  state's own leavingState first, so petportsTaskAction still reports its
    --  task through the ordinary path if it happens to be the one running.
    --
    --  petportsTaskAction ALSO YIELDS ITSELF on the same condition, per tick,
    --  which is faster than this -- run() is only called once a second. This is
    --  the catch-all for the five actions that cannot yield themselves.
    if self.actionState ~= nil and self.actionState.stateDesc() ~= "" then
      sb.logInfo("BEHAVIOR ending action %s -- unit is beached and the action "
        .. "slot has to be empty before the flop state can tick",
        tostring(self.actionState.stateDesc()))
      self.actionState.endState()
    end

    --  FORCE THE STATE, RATHER THAN HOPING THE PICK ORDER FAVOURS IT.
    --
    --  This is vanilla's own pattern -- swimmingMonster.lua does exactly this:
    --
    --      if not mcontroller.liquidMovement() then
    --        if self.state.stateDesc() ~= "flopState" then
    --          self.state.pickState({flop = true})
    --        end
    --      end
    --
    --  Suppressing the action queue only empties the ACTION slot. Which plain
    --  state then runs is stateMachine's choice between petportsFlopState,
    --  idleState and wanderState, and a beached unit that picks idle stands
    --  still exactly as it did before any of this was written.
    --
    --  GUARDED ON stateDesc SO IT IS NOT RE-PICKED EVERY TICK, which would
    --  restart the flop and reset its jump timer forever -- the unit would
    --  twitch instead of hopping.
    --
    --  NIL-GUARDED ON self.state because this file is shared and groundPet.lua
    --  owns that table; a nil here would be a hard error on any host that names
    --  it differently, and the ordering hedge in the scripts list still applies.
    --  FORCE THE STATE, RATHER THAN HOPING THE PICK ORDER FAVOURS IT.
    --
    --  This is vanilla's own pattern -- swimmingMonster.lua does exactly this:
    --
    --      if not mcontroller.liquidMovement() then
    --        if self.state.stateDesc() ~= "flopState" then
    --          self.state.pickState({flop = true})
    --        end
    --      end
    --
    --  Suppressing the action queue only empties the ACTION slot. Which plain
    --  state then runs is stateMachine's choice between petportsFlopState,
    --  idleState and wanderState, and a beached unit that picks idle stands
    --  still exactly as it did before any of this was written.
    --
    --  PASSING PARAMS IS LOAD-BEARING AND IS WHY petportsFlopState DEFINES
    --  enterWith. pickState(params) calls `enterWith` and skips every state
    --  without one, so this reaches the flop and cannot reach idle or wander --
    --  neither of which defines it. Calling pickState() bare here would put the
    --  choice back into list order.
    --
    --  GUARDED ON stateDesc SO IT IS NOT RE-PICKED, which would restart the flop
    --  and reset its jump timer -- the unit would twitch instead of hopping.
    --  stateDesc returns the state NAME when a state defines no description(),
    --  which is why this compares against the name.
    --
    --  NIL-GUARDED ON self.state because this file is shared and groundPet.lua
    --  owns that table.
    --
    --  RUNS ONCE A SECOND, NOT PER TICK. petBehavior.run is called from
    --  groundPet.querySurroundings on querySurroundingsCooldown, which the
    --  monstertypes set to 1. So beaching can take up to a second to be noticed
    --  here -- petportsTaskAction.update yields per tick, so the action slot
    --  empties immediately and only the forced pick waits.
    if self.state ~= nil and self.state.stateDesc() ~= "petportsFlopState" then
      local picked = self.state.pickState({ petportsFlopState = true })

      --  CHANGE-GATED, AND IT REPORTS FAILURE RATHER THAN SUCCESS. A pick that
      --  works announces itself through petportsFlopState.enteringState; a pick
      --  that silently returns false is what happened on 2026-09-01 and took a
      --  round trip and a source read to find.
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

    --  DROP THE WHOLE QUEUE AND STOP. GATING THE TWO SITES BELOW IS NOT ENOUGH.
    --
    --  groundPet.querySurroundings calls behavior.reactTo for EVERY nearby
    --  entity and THEN calls run(), and the reactTo handlers queue actions
    --  themselves -- beg, follow, inspect, eat, play and sleep, at lines far
    --  below this one. So by the time run() starts, the queue is already full of
    --  actions this function never added.
    --
    --  MEASURED 2026-09-01: with only the two sites below gated, a beached unit
    --  re-picked inspectAction roughly every two seconds for the whole beaching.
    --  The flop state was entered and then repeatedly evicted, so it ticked in
    --  bursts -- which is what "flopping, but wrong" looks like from outside.
    --
    --  CLEARING IS WHAT run() DOES AT ITS OWN END ANYWAY, so returning here
    --  leaves exactly the state a normal pass would. The only things skipped are
    --  the queueing, the scoring and the pick, which is the entire point.
    petBehavior.actionQueue = {}
    self.currentActionScore = 0
    return
  end

  if self.petportsTask ~= nil then
    --  Change-gated the other way: one line when suppression lifts, so the log
    --  shows a beginning and an end rather than a beginning and silence.
    --  A NEW EPISODE GETS A NEW NUDGE. Cleared here rather than on entry so a
    --  unit that grazes the same pond twice is helped both times.
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
    --
    --  NO BEACHED GATE HERE ANY MORE. It used to carry `and not beached`, which
    --  was both insufficient -- the reactTo handlers queue actions of their own
    --  before run() is ever called -- and now unreachable, because the beached
    --  branch above clears the queue and returns before this loop.
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
    --  Gated by petports_allowSleep in the monstertype. Scoring zero keeps the
    --  action registered but unwinnable, which is a smaller change than pulling
    --  it out of actionStates.
    if not config.getParameter("petports_allowSleep", true) then return 0 end
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
    --  A pethouse queues sleep by REACTION rather than by score, so the score
    --  gate above does not cover this path on its own.
    if not config.getParameter("petports_allowSleep", true) then return end
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
