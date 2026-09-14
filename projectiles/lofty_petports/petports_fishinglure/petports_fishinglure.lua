-- Lure projectile that spawns fish nearby and keeps out of their reach.

require "/scripts/vec2.lua"
require "/scripts/util.lua"
require "/scripts/rect.lua"
require "/scripts/lofty_petports/petports_fishingspawner.lua"

LURE_SPAWNER_CONFIG = "/scripts/fishing/fishingspawner.config"

-- Reads the lure parameters, builds the spawner and installs the zone, fish and hook handlers.
function init()
  self.ownerId = projectile.sourceEntity()

  self.spawnTimeRange = config.getParameter("spawnTimeRange", {2, 6})
  self.spawnTimer = util.randomInRange(self.spawnTimeRange)

  self.teleportRange = config.getParameter("petports_teleportRange", 4.0)

  self.levelTolerance = config.getParameter("petports_levelTolerance", 1.25)

  self.teleportAttempts = config.getParameter("petports_teleportAttempts", 100)
  self.patrolSpeed = config.getParameter("petports_patrolSpeed", 2.5)
  self.patrolCheck = config.getParameter("petports_patrolCheck", 0.25)
  self.patrolTimer = 0

  self.coverage = config.getParameter("petports_coverage")

  self.fishParameters = config.getParameter("petports_fishParameters", {})

  self.direction = util.randomDirection()
  self.fishId = nil

  self.holdY = mcontroller.position()[2]

  self.fishingSpawner = PetportsFishingSpawner()

  self.fishingSpawner.setBias(config.getParameter("petports_spawnBias", 0))

  self.fishingSpawner.setLureType(
    config.getParameter("petports_lureType", "petports_fishinglure"))

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

  message.setHandler("fishOn", function(_, _, fishId)
      sb.logError("petports: fishing lure got fishOn from %s -- hookDistance 0 "
        .. "should make this unreachable. The fish is being released.",
        tostring(fishId))
      world.sendEntityMessage(fishId, "unhook")
      return nil
    end)

  message.setHandler("petports_lureFish", function()
      if self.fishId ~= nil and world.entityExists(self.fishId) then
        return self.fishId
      end
      return nil
    end)

  sb.logInfo("petports: fishing lure %s up at %s, owner %s, ttl %s "
    .. "(build 2026-09-03a coverage checked per tick)",
    sb.printJson(entity.id()), sb.printJson(mcontroller.position()),
    sb.printJson(self.ownerId), sb.printJson(projectile.timeToLive()))
end

-- Returns whether a point falls in any of the coverage boxes.
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

-- Returns whether a monster type runs a lurk state script.
local function typeIsLurker(monsterType)
  local ok, params = pcall(root.monsterParameters, monsterType)
  if not ok or type(params) ~= "table" then return false end

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

-- Returns whether a candidate position is deep enough, clear, in sight and inside coverage.
local function lureSpotValid(from, candidate)
  local cfg = self.spawnerConfig
  if cfg == nil then return false end

  if not world.liquidAt(candidate) then return false end
  if world.lineTileCollision(from, candidate) then return false end

  local region = rect.translate(cfg.checkRegion, candidate)
  if world.rectCollision(region) then return false end

  local liquid = world.liquidAt(region)
  if not liquid or liquid[2] < cfg.liquidThreshold then return false end

  if not insideCoverage(self.coverage, candidate) then
    return false
  end

  return true
end

-- Moves the lure to a valid spot out of the fish's reach and turns it away.
local function teleportFrom(fishPosition, why)
  local cfg = self.spawnerConfig
  if cfg == nil then return false end

  local here = mcontroller.position()

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

        mcontroller.setPosition(candidate)
        mcontroller.setVelocity({0, 0})

        self.holdY = candidate[2]

        self.patrolTimer = 0

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

-- Slides the lure along its hold level, reversing at collisions, dry tiles and the coverage edge.
local function patrol(dt)
  local here = mcontroller.position()

  self.patrolTimer = self.patrolTimer - dt
  if self.patrolTimer <= 0 then
    self.patrolTimer = self.patrolCheck

    local ahead = { here[1] + (self.direction * 2), self.holdY }

    if world.lineTileCollision({ here[1], self.holdY }, ahead)
       or not world.liquidAt(ahead) then
      self.direction = -self.direction
    end
  end

  local step = self.direction * self.patrolSpeed * dt
  local destination = { here[1] + step, self.holdY }

  if not insideCoverage(self.coverage, destination) then
    self.direction = -self.direction
    mcontroller.setVelocity({ 0, 0 })
    return
  end

  mcontroller.setPosition(destination)
  mcontroller.setVelocity({ 0, 0 })
end

-- Dies with its owner, patrols, moves away from the current fish, and spawns a new one on a timer.
function update(dt)
  if not self.ownerId or not world.entityExists(self.ownerId) then
    projectile.die()
    return
  end

  local here = mcontroller.position()
  local inLiquid = world.liquidAt(here)

  if not inLiquid then
    self.fishingSpawner.reset()
    patrol(dt)
    return
  end

  if self.fishId ~= nil and not world.entityExists(self.fishId) then
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

  self.spawnTimer = self.spawnTimer - dt
  if self.spawnTimer <= 0 then
    self.spawnTimer = util.randomInRange(self.spawnTimeRange)

    local spawnType, spawnPosition, rarity = self.fishingSpawner.getSpawn(here)

    if spawnType and spawnPosition then
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

        world.sendEntityMessage(self.ownerId, "petports_fishSpawned",
          spawned, spawnType, rarity)

        sb.logInfo("petports: lure %s spawned %s (%s) at %s, level %s, lurker %s "
          .. "(%s mode, bias now %s)",
          sb.printJson(entity.id()), sb.printJson(spawned), tostring(spawnType),
          sb.printJson(spawnPosition), sb.printJson(parameters.level),
          tostring(self.fishIsLurker),
          tostring(self.fishingSpawner.mode()),
          sb.printJson(self.fishingSpawner.bias()))

        if rarity ~= nil then
          sb.logInfo("petports: lure %s fish %s is %s",
            sb.printJson(entity.id()), sb.printJson(spawned), tostring(rarity))
        end

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

-- Kills the projectile.
function kill()
  projectile.die()
end
