--  BEACHED. FLOP.
--
--  BUILT 2026-09-01 against vanilla's /monsters/flopState.lua and the caught-fish
--  /monsters/fishing/landedState.lua, both read the same day. This is the "save
--  me" behaviour for an aquatic unit that has ended up out of water. It is NOT
--  the rescue -- see THE RESCUE ALREADY EXISTS below.
--
--  WHY A UNIT FLOPS AT ALL, GIVEN THAT THE PORT WILL FETCH IT.
--
--  Two reasons, and the second is the mechanical one:
--
--    1. A stranded unit that stands perfectly still looks broken. It reads as a
--       bug even when the rescue is seconds away, and this mod has spent whole
--       sessions distinguishing "stalled" from "working slowly".
--    2. A flopping unit CAN RESCUE ITSELF. Random hops plus platform
--       drop-through genuinely find water, and self-rescue costs the port
--       nothing and loses no task. The rehome is the floor, not the plan.
--
--  THE DETECTOR IS petports_outOfMedium AND THAT IS DELIBERATE.
--
--  The port already polls exactly that function on its environment timer and
--  re-homes on repeated strikes. Sharing it means the flop and the rescue can
--  never disagree about what "beached" means -- which is the thing the backlog
--  entry asked for, because PETPORTS_SUBMERGED_FILL already defines "in water"
--  for the pathing side and a second threshold here would let a unit flop its
--  way into a puddle and stop.
--
--  It also gets the chassis question right for free. `out` is true for an
--  aquatic in air and FALSE for a flyer in air, because the answer is built from
--  petports_canFly / petports_canSwim rather than from gravity. A check written
--  against gravityEnabled would have caught the flyer too, and the amphibious
--  chassis -- which walks on land BY DESIGN -- returns `checked = false`, so it
--  can never enter this state at all.
--
--  GRAVITY HAS TO BE TURNED ON, AND THIS IS THE ONE PLACE THAT IS SAFE.
--
--  The aquatic chassis is gravityEnabled FALSE. Every part of a flop needs
--  gravity: onGround() never becomes true without it, controlJump has nothing to
--  push against, bounceFactor has no impact to modify, and controlDown has no
--  fall to pass through a platform. A gravity-disabled unit out of water simply
--  hovers.
--
--  dd.locomotion.otter refused runtime gravity switching because PathFinder:start
--  reads baseParameters and mustEndOnGround is captured at PathMover:new, so
--  flipping it mid-route corrupts a live plan. THAT OBJECTION DOES NOT APPLY
--  HERE: a beached unit has yielded its task and has no route. This is the only
--  state in the mod where the toggle is free.
--
--  VIA controlParameters, NOT applyParameters, WHICH IS THE WHOLE REASON THERE
--  IS NO RESTORE CODE BELOW. controlParameters is re-asserted per tick and
--  lapses on its own the moment this state stops running, so there is no
--  persistent override to leak and no leavingState cleanup that could be missed
--  on an abnormal exit. Vanilla's flopState drives bounceFactor exactly this way.
--
--  THE RESCUE ALREADY EXISTS AND THIS STATE DOES NOT DUPLICATE IT.
--
--  petports_petport.lua's mediumCheck polls petports_outOfMedium on
--  ENVIRONMENT_INTERVAL and calls rehomeUnit once the strikes run out. So there
--  is no suffocation timer here, no death, and no teleport -- vanilla's fish die
--  on a timer and ours must not. This state ENDS ITSELF the moment the unit is
--  back in an acceptable medium, exactly as vanilla's does, and otherwise runs
--  until the port collects it.

require "/scripts/util.lua"

petportsFlopState = {}

--  Re-asserted every tick while flopping. 0.6 is vanilla's, unchanged: it is
--  what makes a hop read as a flop rather than a jump.
FLOP_BOUNCE_FACTOR = 0.6

--  THE FLOP PHYSICS, TAKEN FROM /monsters/fishing/fishingchuckle.monstertype.
--
--  These are a real vanilla fish's movementSettings, which is the closest thing
--  to a reference implementation of "what a flopping body should feel like".
--  Reading them off a shipped monster beats tuning by eye, and it is why they
--  are recorded here with their source rather than as bare numbers.
--
--  WHY NOT JUST PUT THEM ON THE AQUATIC CHASSIS. They are wanted ONLY while
--  flopping. airFriction 24 on the chassis is correct for a free mover -- it is
--  what makes a swimming unit stop crisply when it stops thrusting -- and
--  lowering it there would change every piece of aquatic movement to fix a
--  state that runs for thirty seconds. controlParameters lapses on its own, so
--  this borrows the fish's physics for exactly as long as the flop lasts.
--
--  jumpSpeed 15 IS THE FIX FOR THE RICOCHET, AND THE NUMBER MATTERS A LOT.
--  The aquatic chassis declares NO airJumpProfile, so it inherited
--  default_actor_movement.config's -- which is the 45 seen throughout the
--  sinker's Jump edges. Rise scales with the SQUARE of launch speed, so 45
--  against 15 is nine times the height. Measured 2026-09-01: a beached unit
--  bouncing between y 1128.8 and y 1134.2, over five tiles a hop.
--
--  THE WHOLE PROFILE IS GIVEN, NOT JUST jumpSpeed, so there is no question about
--  how a partial JumpProfile merges. Every field is the fish's.
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

--  The fish's flopJumpInterval, used when a chassis does not override it. Wider
--  and slower than the {0.4, 0.9} this file first guessed at, which is part of
--  why the first version read as twitching rather than flopping.
FLOP_JUMP_INTERVAL = {0.3, 1.5}

--  BUILD STAMP, REPORTED ON THE BEACHING LINE. Neither this file nor
--  petports_petBehavior.lua had one, so a run could not be told apart from the
--  previous run's build -- and this state has now been wrong in three different
--  ways across three logs. Same convention as petportsTaskAction's.
FLOP_BUILD_STAMP = "2026-09-01b fish physics: jumpSpeed 15, friction 0.5/1.5"

function petportsFlopState.enter()
  local report = petports_outOfMedium()

  --  `checked` false means the question does not apply to this chassis -- a
  --  walker, whose medium is physics rather than permission. Not beached, and
  --  it can never be. See petports_outOfMedium's own header on why a bare
  --  boolean could not express this.
  if not report.checked or not report.out then return nil end

  return {
    jumpTimer = 0,
    jumpDirection = util.randomDirection(),
    flopTime = 0,
    reported = false
  }
end

--  BOTH ENTRY POINTS ARE REQUIRED, AND MISSING THIS ONE COST A TEST ROUND.
--
--  /scripts/stateMachine.lua picks by name:
--
--      local enterFunctionName = "enter"
--      if params ~= nil then enterFunctionName = "enterWith" end
--
--  So pickState() with NO params calls `enter`, and pickState(params) calls
--  `enterWith` and SILENTLY SKIPS any state that does not define one. The first
--  version of this file had only `enter`, so petBehavior's forced
--  pickState({petportsFlopState = true}) iterated every state, found no
--  enterWith anywhere -- idleState and wanderState are vanilla and have none
--  either -- returned false, and did nothing. Measured: the suppression fired,
--  the yield fired, and this state never entered once.
--
--  WHICH MAKES THE FORCED PICK DETERMINISTIC RATHER THAN ORDER-DEPENDENT. With
--  params, ONLY states implementing enterWith are considered, and this is the
--  only plain state in the mod that does. Position in the scripts list stops
--  mattering for the forced path -- it still decides the auto-pick path below.
--
--  `enter` IS KEPT because groundPet.lua's update calls the argless form every
--  tick when no state is held:
--
--      if self.actionState.stateDesc() == "" and not self.state.update(dt) then
--        self.state.pickState()
--
--  That is the path taken when a beached unit's idle or wander state expires on
--  its own, and it is what makes being listed ahead of them worth doing.
--
--  ARGS ARE IGNORED ON PURPOSE. The caller names this state to say "you, now",
--  but whether the unit is ACTUALLY beached is not the caller's to assert --
--  petports_outOfMedium is the single answer to that question and it is asked
--  here as well, so a mistaken forced pick refuses itself.
function petportsFlopState.enterWith(args)
  return petportsFlopState.enter()
end

function petportsFlopState.enteringState(stateData)
  animator.setAnimationState("movement", "flopping")

  sb.logInfo("UNIT BEACHED at %s -- flopping (flop build %s). The port's medium "
    .. "check will re-home this unit if it cannot get itself back into water "
    .. "first.",
    sb.printJson(mcontroller.position()), FLOP_BUILD_STAMP)
end

function petportsFlopState.update(dt, stateData)
  local report = petports_outOfMedium()

  --  BACK IN THE WATER. The state ends itself rather than being cancelled from
  --  outside, which is vanilla's shape and the reason no other file needs to
  --  know this state exists.
  if not report.checked or not report.out then
    sb.logInfo("UNIT un-beached at %s after %ss of flopping -- self-rescued, "
      .. "no re-home needed", sb.printJson(mcontroller.position()),
      sb.printJson(math.floor(stateData.flopTime * 10) / 10))
    return true
  end

  stateData.flopTime = stateData.flopTime + dt

  --  GRAVITY, BOUNCE, THE FISH'S FRICTION AND THE FISH'S JUMP, EVERY TICK. All
  --  of it lapses by itself when the state stops -- see the header on why
  --  controlParameters rather than applyParameters.
  --
  --  FRICTION IS LOWERED, NOT ZEROED, AND THAT DISTINCTION WAS THE LAST BUG.
  --  The chassis declares airFriction 24 and liquidFriction 24, high on purpose
  --  so a free mover stops crisply when it stops thrusting. The first build left
  --  those alone and every hop was braked before it started -- 4 tiles in 17
  --  seconds. The second build zeroed them outright, copying petportsArcMover,
  --  and with an inherited 45 jump that produced a unit ricocheting five tiles a
  --  hop. The fish uses 0.5 and 1.5: enough drag to settle a body, not enough to
  --  stop one.
  --
  --  groundFriction IS DELIBERATELY LEFT ALONE. A flopping unit should land and
  --  stay landed until it hops again; zeroing it as the arc mover does would
  --  have it skating across the floor between hops.
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
      --  DROP-THROUGH IS WANTED HERE, WHICH REVERSES WHAT THE BACKLOG ENTRY SAID.
      --
      --  todo.locomotion.beached said "COPY THE JUMP, NOT THE controlDown",
      --  citing fact.pathing.dropfaults: controlDown presses down and then
      --  checks whether it has landed, so the tick a unit arrives has already
      --  had a down issued and it falls through the surface it just reached.
      --
      --  THAT IS THE POINT FOR A BEACHED UNIT. Water is almost always DOWN from
      --  wherever a fish has been stranded, and a platform between the two is
      --  the common case on a player's base. A flopper that cannot pass a
      --  platform is a flopper that cannot save itself.
      --
      --  THE RISK IS BOUNDED BY THE RESCUE. The entry's worry was a unit
      --  dropping through a player's floor -- which can still happen, and ends
      --  with the port re-homing it within seconds. Falling somewhere wrong is
      --  strictly better than hovering somewhere wrong, because only one of the
      --  two can end in water.
      mcontroller.controlDown()
    end
  end

  if stateData.jumpTimer <= 0 then
    stateData.jumpTimer = util.randomInRange(
      config.getParameter("petports_flopJumpInterval", FLOP_JUMP_INTERVAL))
  end

  return false
end

function petportsFlopState.leavingState(stateData)
  --  NOTHING TO UNDO. controlParameters lapses on its own -- see the header on
  --  why that was chosen over applyParameters. The animation state is set by
  --  whatever runs next.
end
