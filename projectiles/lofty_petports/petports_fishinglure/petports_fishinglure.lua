--  PETPORTS -- FISHING LURE
--
--  A FORK OF VANILLA'S /projectiles/fishing/fishinglure.lua. Read that file
--  alongside this one; the spawner half is nearly line-for-line and only the
--  differences are commented here.
--
--  THE LURE IS THE SPAWNER. The spawner lives here, not on the rod and not on
--  the port, and it spawns a fish every few seconds for as long as the lure is
--  in liquid. Everything the port has to decide is "should a lure exist";
--  everything after that is this file.
--
--  PetportsFishingSpawner, NOT VANILLA'S. Ours merges vanilla's biome pools with
--  Irisil-style liquid-id zones and takes a bias override -- see that file's
--  header. Vanilla's would work but can never produce anything above a common
--  fish for a lure with this lifetime, and cannot be configured by a zone.
--
--  WHAT WAS REMOVED FROM VANILLA'S, AND WHY
--
--    rod controls      reel / down / left / right and the line-length maths.
--                      There is no rod. The lure is placed and patrols.
--    fleeFromLure      vanilla broadcasts it to every monster within 9 tiles
--                      every second, to scare ambient wildlife off a player's
--                      fishing spot. `world.monsterQuery` returns OUR UNITS
--                      too, and a lure that shouts at the fleet is not
--                      something this mod wants even while nothing answers it.
--    rotation          vanilla points the lure at the rod. There is no rod, and
--                      the placeholder sprite is a square.
--    linePosition      the rod's rope endpoint. No rope.
--
--  WHAT WAS ADDED
--
--    one fish at a time      the port's budget, enforced here because this is
--                            what knows whether its fish is still alive
--    patrol                  horizontal drift, reversing at walls, dry water
--                            and the edge of network coverage
--    teleport                move away from a fish that has closed in -- see
--                            TELEPORT below, this is the one that matters
--    coverage                a rect the lure may not leave, so its fish are
--                            dispatchable by the port that spawned it
--
--  SPAWNED WITH THE PORT AS SOURCE ENTITY, which buys teardown for free:
--  vanilla's update already ends with `else projectile.die()` when the source
--  is gone, so breaking or unloading a port kills the lure, which nils the
--  fish's `lureId`, which lets the fish despawn itself. The chain unwinds with
--  nothing holding a reference to anything.

require "/scripts/vec2.lua"
require "/scripts/util.lua"
require "/scripts/rect.lua"
require "/scripts/lofty_petports/petports_fishingspawner.lua"

--  Vanilla's own numbers, read from vanilla's own file. The distance range, the
--  clearance region and the liquid threshold a spawn point must satisfy all live
--  here, and re-deriving them would be a second source of truth that goes stale
--  the day Chucklefish changes theirs.
LURE_SPAWNER_CONFIG = "/scripts/fishing/fishingspawner.config"

function init()
  --  THE PORT, not a player. Vanilla reads the rod's holder here.
  self.ownerId = projectile.sourceEntity()

  self.spawnTimeRange = config.getParameter("spawnTimeRange", {2, 6})
  self.spawnTimer = util.randomInRange(self.spawnTimeRange)

  self.teleportRange = config.getParameter("petports_teleportRange", 4.0)

  --  HOW FAR OFF A LURKER'S OWN ROW A TELEPORT MAY LAND. 1.0 after watching it:
  --  2.0 was still enough tilt to read as looking up or down, and there is no
  --  shortage of candidates at one tile because the relaxed second pass catches
  --  the cases where a level spot genuinely does not exist.
  self.levelTolerance = config.getParameter("petports_levelTolerance", 1.25)

  --  ATTEMPTS PER PASS. High because the constrained pass is REJECTION SAMPLING
  --  on a circle: candidates are drawn 8-14 tiles out at a uniform angle, and
  --  only the few that happen to land near the fish's row survive the level
  --  test -- at tolerance 1.25 and distance 8-14 that is roughly one in
  --  twenty-five.
  --
  --  CHEAP DESPITE THE NUMBER, because the level test is pure arithmetic and
  --  sits FIRST in the `and` chain: a candidate at the wrong height costs one
  --  subtraction and is discarded before any world call. Only survivors pay for
  --  liquidAt, lineTileCollision and rectCollision.
  self.teleportAttempts = config.getParameter("petports_teleportAttempts", 100)
  self.patrolSpeed = config.getParameter("petports_patrolSpeed", 2.5)
  self.patrolCheck = config.getParameter("petports_patrolCheck", 0.25)
  self.patrolTimer = 0

  --  THE RECT THE LURE MAY NOT LEAVE, so every fish it spawns is inside the
  --  coverage of the port that spawned it and can actually be dispatched to.
  --
  --  ABSENT MEANS UNBOUNDED, deliberately: it makes the lure testable by hand
  --  with /spawnprojectile before any port code exists to pass one.
  self.coverage = config.getParameter("petports_coverage")

  --  PASSED STRAIGHT THROUGH TO EVERY FISH THIS LURE SPAWNS.
  --
  --  `hookDistance` 0 is the load-bearing one and belongs to the caller rather
  --  than to this file, because it is a statement about how the mod wants fish
  --  to behave rather than about how a lure works. A fish spawned with 0 can
  --  never satisfy `lureDist < hookDistance`, so it never hooks, never enters
  --  hookedState -- which has no timer and would hold it forever -- and times
  --  out on its own approach window instead.
  self.fishParameters = config.getParameter("petports_fishParameters", {})

  self.direction = util.randomDirection()
  self.fishId = nil

  --  THE ROW THE LURE HOLDS. Set from where the port placed it and updated only
  --  by a teleport, so the depth the port chose -- far enough under the ocean
  --  level for getSpawn to accept the neighbourhood -- is the depth it keeps.
  self.holdY = mcontroller.position()[2]

  self.fishingSpawner = PetportsFishingSpawner()

  --  ZERO BIAS, WHICH IS THE WHOLE POINT OF THE FORK.
  --
  --  Upstream seeds the rarity roll with initialBias 0.2 and drops it 0.1 per
  --  successful spawn, so the first two catches are forced common. That is an
  --  anti-frontload measure for a player casting repeatedly, and it is wrong for
  --  a lure that lives 150 seconds, holds one fish at a time and is replaced by
  --  a fresh spawner afterwards -- it would reset the bias faster than it could
  --  decay, and could never roll rare or legendary at all.
  --
  --  0 MEANS THE PUBLISHED ODDS APPLY FROM THE FIRST FISH: roughly 80 percent
  --  common, 16 uncommon, 3.9 rare, 0.1 legendary. Improbable, not impossible.
  self.fishingSpawner.setBias(config.getParameter("petports_spawnBias", 0))

  --  WHICH LURE A ZONE THINKS WE ARE. Irisil's zones list eligibleLureTypes and
  --  match on this string, so a zone that has never heard of petports simply
  --  finds no match and spawns nothing -- which is the correct failure, not an
  --  error. A zone author who wants petport lures to work in their pool adds
  --  this name to it.
  self.fishingSpawner.setLureType(
    config.getParameter("petports_lureType", "petports_fishinglure"))

  --  FISHING ZONES CONFIGURE US; WE DO NOT GO LOOKING FOR THEM.
  --
  --  A Project Irisil fishing zone is a stagehand that runs
  --  broadcastAreaQuery({includedTypes = {"projectile"}}) every update and
  --  messages every projectile it finds. Our lure IS a projectile, so a zone
  --  finds it without this mod knowing zones exist -- no dependency, no search,
  --  no name check. If Irisil is not installed nothing ever sends this and the
  --  spawner stays in vanilla mode.
  --
  --  KEYED ON THE SENDER SO A LURE CAN CHANGE ZONES. Irisil's own lure keys on
  --  `params.sender`, which the zone never sets -- it sends `id` -- so the first
  --  message applies, the key becomes nil, and every later message fails
  --  `nil ~= nil`. A lure that drifts from one zone into another never picks up
  --  the second. Reading `id` here fixes that for our copy.
  message.setHandler("lofty_irisil_setFishingZoneParameters",
    function(_, _, params)
      if type(params) ~= "table" then return end

      local sender = params.id or params.sender
      if self.fishingZone == sender then return end
      self.fishingZone = sender

      if self.fishingSpawner.setParams(params.args) then
        sb.logInfo("petports: lure %s took fishing zone parameters from %s -- "
          .. "spawner is now in %s mode",
          sb.printJson(entity.id()), sb.printJson(sender),
          tostring(self.fishingSpawner.mode()))
      end
    end)

  local ok, data = pcall(root.assetJson, LURE_SPAWNER_CONFIG)
  self.spawnerConfig = ok and data or nil
  if self.spawnerConfig == nil then
    sb.logError("petports: fishing lure could not read %s -- it will patrol but "
      .. "never reposition", LURE_SPAWNER_CONFIG)
  end

  --  SHOULD NEVER FIRE, AND SAYS SO IF IT DOES. With hookDistance 0 no fish can
  --  reach the branch that sends this. If one ever does, the assumption above is
  --  wrong somewhere and that is worth knowing loudly rather than silently
  --  handing the fish to a port that has no idea what to do with it.
  message.setHandler("fishOn", function(_, _, fishId)
      sb.logError("petports: fishing lure got fishOn from %s -- hookDistance 0 "
        .. "should make this unreachable. The fish is being released.",
        tostring(fishId))
      world.sendEntityMessage(fishId, "unhook")
      return nil
    end)

  --  How the port asks what this lure has caught the attention of, without
  --  having to track the fish itself.
  message.setHandler("petports_lureFish", function()
      if self.fishId ~= nil and world.entityExists(self.fishId) then
        return self.fishId
      end
      return nil
    end)

  sb.logInfo("petports: fishing lure %s up at %s, owner %s, ttl %s",
    sb.printJson(entity.id()), sb.printJson(mcontroller.position()),
    sb.printJson(self.ownerId), sb.printJson(projectile.timeToLive()))
end

--  IS THIS POINT INSIDE THE NETWORK'S COVERAGE?
--
--  A LIST OF RECTS, NOT ONE. Coverage is per-port, and a network is several
--  ports -- so every generator in the port that reasons about reach walks
--  `self.networkRects` and falls back to a single-element list of its own rect.
--  The first build of this took one rect and clamped the lure to the port that
--  spawned it, which is visibly wrong the moment two ports share a body of
--  water: fish could only ever appear in one of them.
--
--  WRITTEN OUT RATHER THAN CALLED FROM rect.lua. `rect.translate` is the only
--  rect helper this mod uses anywhere, and the port tests coverage by indexing
--  corners directly into world.entityQuery, so there is no established
--  containment helper to reuse and no evidence vanilla's rect.lua exposes one.
--
--  RECT ORDER IS {x1, y1, x2, y2}, matching every other rect in this mod.
--
--  AN EMPTY OR ABSENT LIST MEANS UNBOUNDED, which is what makes the lure
--  testable by hand with /spawnprojectile before any port passes one.
local function insideCoverage(boxes, point)
  if boxes == nil or #boxes == 0 then return true end

  for _, box in ipairs(boxes) do
    if point[1] >= box[1] and point[1] <= box[3]
       and point[2] >= box[2] and point[2] <= box[4] then
      return true
    end
  end

  return false
end

--  IS THIS FISH A LURKER OR AN APPROACHER?
--
--  THE TWO ARE COMPETING STATES, NOT A PARAMETER. `approachState.enter` and
--  `lurkState.enter` BOTH gate on `storage.stateStage == "approach"`, so which
--  one a fish uses is decided entirely by which script its monstertype lists.
--  fishingchuckle lists approachState and no lurkState; a lurker is the other
--  way round. Nothing else distinguishes them.
--
--  WHY THE LURE CARES: a lurker outside its biteDistance idles and FACES the
--  lure -- `setBodyDirection(self.toLure)` -- so a lure sitting well above or
--  below it leaves the fish permanently angled at the sky or the seabed. An
--  approacher swims toward the lure instead and its facing follows its travel,
--  so the same offset reads as normal swimming.
--
--  READ ONCE PER FISH AND CACHED. root.monsterParameters reads the type's
--  config off disk, which is cheap but not free, and the answer cannot change
--  for a given type.
local function typeIsLurker(monsterType)
  local ok, params = pcall(root.monsterParameters, monsterType)
  if not ok or type(params) ~= "table" then return false end

  --  The scripts list lives under baseParameters on a monstertype, and the same
  --  belt-and-braces both-levels read the animal harvest check uses.
  local base = type(params.baseParameters) == "table" and params.baseParameters or {}
  local scripts = params.scripts or base.scripts
  if type(scripts) ~= "table" then return false end

  for _, path in ipairs(scripts) do
    if type(path) == "string" and string.find(path, "lurkState", 1, true) then
      return true
    end
  end

  return false
end

--  IS THIS POSITION SOMEWHERE A LURE MAY SIT?
--
--  Mirrors the tests inside vanilla's `spawnPositionNear`, which is a LOCAL
--  inside FishingSpawner and cannot be called from here. The numbers are read
--  from vanilla's config rather than copied, so only the fifteen lines of logic
--  are duplicated and none of the tuning is.
local function lureSpotValid(from, candidate)
  local cfg = self.spawnerConfig
  if cfg == nil then return false end

  if not world.liquidAt(candidate) then return false end
  if world.lineTileCollision(from, candidate) then return false end

  local region = rect.translate(cfg.checkRegion, candidate)
  if world.rectCollision(region) then return false end

  local liquid = world.liquidAt(region)
  if not liquid or liquid[2] < cfg.liquidThreshold then return false end

  --  OURS, NOT VANILLA'S. A lure outside the port's rect spawns fish the port
  --  cannot dispatch to.
  if not insideCoverage(self.coverage, candidate) then
    return false
  end

  return true
end

--  MOVE THE LURE AWAY FROM A FISH THAT HAS CLOSED IN.
--
--  THIS IS THE WHOLE REASON THE FILE IS NOT JUST VANILLA'S. See
--  petports_teleportRange in the .projectile for why a fish that cannot hook
--  will otherwise dart at the lure forever.
--
--  LINE OF SIGHT TO THE FISH IS CHECKED, AND IT IS NOT OPTIONAL. The fish's own
--  `updateLure` despawns it outright when `world.lineTileCollision(fishPos,
--  lurePos)` is true, so a teleport that lands behind terrain does not move the
--  lure away from the fish -- it KILLS the fish. Every candidate is tested from
--  the fish's position for exactly that reason.
--
--  FAILING MEANS STAYING PUT, which is the safe direction: an oscillating fish
--  looks bad, and a fish deleted by its own lure is worse.
local function teleportFrom(fishPosition, why)
  local cfg = self.spawnerConfig
  if cfg == nil then return false end

  local here = mcontroller.position()

  --  A LURKER WANTS THE LURE ON ITS OWN LEVEL, AN APPROACHER DOES NOT CARE.
  --
  --  See typeIsLurker: a lurker idles facing the lure, so a teleport that lands
  --  six tiles above it leaves the fish staring at the sky for the rest of its
  --  life. Two passes -- the first insists on staying level, the second drops
  --  the constraint -- so a lurker gets a level spot when one exists and still
  --  gets moved off its nose when one does not. An approacher skips the first
  --  pass entirely and takes whatever is valid.
  --
  --  RELAXING BEATS REFUSING. A silly-looking angle is a smaller problem than a
  --  fish oscillating on the spot, which is what not moving at all produces.
  --
  --  math.huge IS THE "NO CONSTRAINT" SENTINEL, AND IT REPLACES A nil THAT
  --  BROKE THIS ENTIRELY. The first version built these lists with a trailing
  --  nil -- `{tolerance, nil}` for a lurker, `{nil}` for an approacher -- and a
  --  table constructor DROPS a trailing nil, so their lengths were 1 and ZERO.
  --  ipairs never entered the loop for an approacher, which could therefore
  --  never teleport at all, and a lurker never got the relaxed second pass this
  --  comment claims it does. Measured: lurkers repositioned, approachers never
  --  did, and nothing in the log said why.
  local passes = self.fishIsLurker
    and { self.levelTolerance, math.huge }
    or { math.huge }

  for _, tolerance in ipairs(passes) do
    for _ = 1, self.teleportAttempts do
      local candidate = vec2.add(here, vec2.withAngle(
        math.random() * 2 * math.pi,
        util.randomInRange(cfg.distanceRange)))

      local levelEnough =
        math.abs(candidate[2] - fishPosition[2]) <= tolerance

      if levelEnough
         and lureSpotValid(here, candidate)
         and not world.lineTileCollision(fishPosition, candidate)
         and world.magnitude(fishPosition, candidate) > self.teleportRange then

        --  setPosition, NOT a velocity command. The lure has to be somewhere
        --  else NOW; accelerating away would keep it inside the fish's bite
        --  radius for the whole trip, which is the state this exists to leave.
        mcontroller.setPosition(candidate)
        mcontroller.setVelocity({0, 0})

        --  AND THE HELD ROW MOVES WITH IT, or patrol would drag the lure
        --  straight back to the depth it started at on the very next tick.
        self.holdY = candidate[2]

        --  AND THE PATROL NOW HEADS AWAY FROM THE FISH.
        --
        --  The teleport picks a candidate at a UNIFORM ANGLE, so half the time
        --  it lands on the far side and the patrol -- whose direction survived
        --  the jump -- immediately walks it back toward the fish it just left.
        --  On an approacher that halves the distance bought by the teleport
        --  before the fish has even turned; on a lurker it can put the lure back
        --  inside biteDistance within a couple of seconds and start the whole
        --  cycle again.
        --
        --  A TIE KEEPS THE CURRENT HEADING. Exactly equal x is possible after a
        --  level-constrained jump, and there is no "away" to point at -- picking
        --  arbitrarily would be a coin flip dressed as a decision.
        local awayX = candidate[1] - fishPosition[1]
        if awayX > 0 then
          self.direction = 1
        elseif awayX < 0 then
          self.direction = -1
        end

        sb.logInfo("petports: lure %s moved from %s to %s -- %s, fish %s was %s "
          .. "away (lurker %s, dy now %s, level pass %s)",
          sb.printJson(entity.id()), sb.printJson(here), sb.printJson(candidate),
          tostring(why or "fish closed in"),
          sb.printJson(self.fishId),
          sb.printJson(world.magnitude(fishPosition, here)),
          tostring(self.fishIsLurker == true),
          sb.printJson(math.abs(candidate[2] - fishPosition[2])),
          tolerance == math.huge and "relaxed" or sb.printJson(tolerance))

        sb.logInfo("petports: lure %s now patrolling %s, away from fish %s",
          sb.printJson(entity.id()),
          self.direction > 0 and "east" or "west",
          sb.printJson(self.fishId))

        return true
      end
    end
  end

  --  A FAILED TELEPORT SAYS SO, CHANGE-GATED ON THE FISH.
  --
  --  This function used to return false silently, which cost a whole test round:
  --  a log with no teleport line in it could mean the fish never came close, or
  --  that it came close and every candidate was refused, and there was no way to
  --  tell those apart. One line per fish, not per tick -- the check runs every
  --  update while a fish is inside teleportRange.
  if self.teleportFailedFor ~= self.fishId then
    self.teleportFailedFor = self.fishId
    sb.logInfo("petports: lure %s could not move for fish %s at %s (%s) -- no "
      .. "candidate in %s attempt(s) was clear, in coverage, in sight of the "
      .. "fish and more than %s away",
      sb.printJson(entity.id()), sb.printJson(self.fishId),
      sb.printJson(here), tostring(why or "fish closed in"),
      sb.printJson(#passes * self.teleportAttempts),
      sb.printJson(self.teleportRange))
  end

  return false
end

--  HORIZONTAL DRIFT, DRIVEN BY POSITION RATHER THAN BY VELOCITY.
--
--  THE LURE IS A MARKER, NOT A BODY, AND THIS IS WHY IT DOES NOT SINK.
--
--  The first build patrolled with `approachVelocity({dir * speed, 0}, force)`,
--  which does target a y velocity of zero -- but it is a FORCE fighting the
--  fishinglure physics profile's gravity every tick, and at force 20 it loses
--  slowly. Measured: the lure drifted downward the whole time it was alive.
--
--  ZEROING GRAVITY WOULD ALSO WORK AND IS NOT WHAT THIS DOES. mcontroller
--  parameter calls are unproven on a projectile in this mod -- nothing here has
--  ever made one -- whereas petports_crosshair.lua pins itself with
--  mcontroller.setPosition every time it moves, so that call is known good on
--  this entity type. Driving position directly removes gravity, buoyancy and
--  force tuning from the problem at once rather than counteracting one of them.
--
--  THE DEPTH IS HELD EXACTLY, at whatever y the port or the last teleport chose.
--  A marker that bobs is a marker whose fish spawn positions drift with it, and
--  the port picked that row because it is far enough below the ocean level for
--  getSpawn to accept its neighbourhood.
--
--  setVelocity({0,0}) ALONGSIDE, so the physics profile has no residual motion
--  to carry into the next tick and fight the next setPosition with.
local function patrol(dt)
  local here = mcontroller.position()

  self.patrolTimer = self.patrolTimer - dt
  if self.patrolTimer <= 0 then
    self.patrolTimer = self.patrolCheck

    local ahead = { here[1] + (self.direction * 2), self.holdY }

    local blocked = world.lineTileCollision({ here[1], self.holdY }, ahead)
      or not world.liquidAt(ahead)
      or not insideCoverage(self.coverage, ahead)

    if blocked then self.direction = -self.direction end
  end

  mcontroller.setPosition({
    here[1] + (self.direction * self.patrolSpeed * dt),
    self.holdY
  })
  mcontroller.setVelocity({ 0, 0 })
end

function update(dt)
  --  VANILLA'S OWN GUARD, AND OUR TEARDOWN. The port going away takes the lure
  --  with it, which takes the fish with it.
  if not self.ownerId or not world.entityExists(self.ownerId) then
    projectile.die()
    return
  end

  local here = mcontroller.position()
  local inLiquid = world.liquidAt(here)

  if not inLiquid then
    --  Vanilla resets the spawner's rarity bias whenever the lure leaves the
    --  water, so a lure that bobs out cannot bank luck. Kept exactly.
    self.fishingSpawner.reset()
    patrol(dt)
    return
  end

  --  ONE FISH AT A TIME, AND THIS IS WHERE THAT IS ENFORCED. The lure is the
  --  only thing that knows both that it spawned a fish and whether that fish is
  --  still alive; a port polling for it would be a second source of truth on a
  --  one-tick-accurate fact.
  if self.fishId ~= nil and not world.entityExists(self.fishId) then
    --  TIMED OUT, CAUGHT, OR DESPAWNED FOR LOST SIGHT -- the lure cannot tell
    --  which and does not need to. The port is told the id is dead so it can
    --  release a claim rather than waiting for its own next poll.
    world.sendEntityMessage(self.ownerId, "petports_fishGone", self.fishId)
    self.fishId = nil
    self.fishIsLurker = false
    self.teleportFailedFor = nil
  end

  if self.fishId ~= nil then
    local fishPosition = world.entityPosition(self.fishId)

    if fishPosition ~= nil
       and world.magnitude(fishPosition, here) < self.teleportRange then
      teleportFrom(fishPosition)
    end

    patrol(dt)
    return
  end

  --  NO FISH: SPAWN ONE. Vanilla's timer and vanilla's spawner, unchanged.
  self.spawnTimer = self.spawnTimer - dt
  if self.spawnTimer <= 0 then
    self.spawnTimer = util.randomInRange(self.spawnTimeRange)

    local spawnType, spawnPosition = self.fishingSpawner.getSpawn(here)

    if spawnType and spawnPosition then
      --  OUR PARAMETERS FIRST, THEN THE THREE THE FISH CANNOT WORK WITHOUT, so
      --  a caller cannot accidentally override the wiring by passing lureId.
      local parameters = {}
      for key, value in pairs(self.fishParameters) do parameters[key] = value end

      parameters.lureId = entity.id()
      parameters.ownerId = self.ownerId
      parameters.level = math.max(1, world.threatLevel())

      local ok, spawned = pcall(world.spawnMonster,
        spawnType, spawnPosition, parameters)

      if ok and spawned then
        self.fishId = spawned
        self.fishIsLurker = typeIsLurker(spawnType)

        --  TELL THE PORT AT ONCE RATHER THAN LETTING IT POLL. The port's own
        --  timer is five seconds and a fish lives well under two minutes, so a
        --  poll would spend a twentieth of the fish's life just noticing it.
        --  petports_lureFish stays as a reconcile for a port that reloaded.
        world.sendEntityMessage(self.ownerId, "petports_fishSpawned",
          spawned, spawnType)

        sb.logInfo("petports: lure %s spawned %s (%s) at %s, level %s, lurker %s "
          .. "(%s mode, bias now %s)",
          sb.printJson(entity.id()), sb.printJson(spawned), tostring(spawnType),
          sb.printJson(spawnPosition), sb.printJson(parameters.level),
          tostring(self.fishIsLurker),
          tostring(self.fishingSpawner.mode()),
          sb.printJson(self.fishingSpawner.bias()))

        --  LEVEL WITH IT IMMEDIATELY, BEFORE IT HAS LOOKED AT ANYTHING.
        --
        --  getSpawn places a fish 8-14 tiles out at a UNIFORM ANGLE, so it is
        --  as likely to arrive well below or above the lure as beside it. A
        --  lurker that spawns underneath spends its whole life angled at the
        --  ceiling, because it idles facing the lure and never closes far
        --  enough to trigger the ordinary teleport.
        --
        --  THE ORDINARY TRIGGER CANNOT COVER THIS. That one fires on the fish
        --  coming INSIDE teleportRange; a fish that spawned ten tiles below and
        --  simply sits there is never close enough to qualify, so without this
        --  the level constraint would only ever apply to fish that had already
        --  approached.
        --
        --  FAILING IS FINE AND IS NOT RETRIED. If no level spot exists the fish
        --  is no worse off than it would have been, and teleportFrom logs its
        --  own refusal.
        teleportFrom(spawnPosition, "levelling with a new fish")
      else
        sb.logInfo("petports: lure %s failed to spawn %s at %s: %s",
          sb.printJson(entity.id()), tostring(spawnType),
          sb.printJson(spawnPosition), tostring(spawned))
      end
    end
  end

  patrol(dt)
end

--  Vanilla's, kept: the rod calls this to cancel a cast, and a port tearing a
--  lure down early wants the same door.
function kill()
  projectile.die()
end
