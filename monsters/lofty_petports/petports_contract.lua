-- Unit-side contract: naming, modules, media and swim mode, dives, vent routing and fuel.

local CONTRACT_BUILD_STAMP = "2026-09-17e no drop once the task has arrived"

local contractStamped = false

-- Logs the contract build stamp once.
local function stampOnce()
  if contractStamped then
    return
  end
  contractStamped = true

  sb.logInfo("PETPORTS contract build: %s (unit %s)",
    CONTRACT_BUILD_STAMP, tostring(entity.id()))
end

-- Returns a copy of the unit's storage for the port to hold.
function petports_store()
  storage.petResources = petResources()

  return {
    storage = copy(storage)
  }
end

PETPORTS_CULL_TICKS = 60

local petportsBaseUpdate = update

-- Counts update ticks and calls the base update.
function update(dt)
  self.petportsTicks = (self.petportsTicks or 0) + 1
  if petportsBaseUpdate then
    return petportsBaseUpdate(dt)
  end
end

-- Kills the unit outright, or starts its fade-out, without dropping cargo.
function petports_despawn(instant)
  stampOnce()
  self.petportsNoDrop = true

  storage.petportsNoDrop = true
  monster.setDeathParticleBurst(nil)
  monster.setDeathSound(nil)

  if instant then
    sb.logInfo("UNIT %s culled at %s -- world unloading, no fade",
      tostring(entity.id()), sb.printJson(mcontroller.position()))

    status.setResource("health", 0)
    return true
  end

  if self.petportsFading then
    return true
  end
  self.petportsFading = true

  status.addEphemeralEffect("petports_unitfadeout")
  return true
end

-- Asks the port to spill the load, unless the death was a recall or the unload cull.
function die()
  if self.petportsNoDrop then
    sb.logInfo("UNIT %s died on a recall at %s -- cargo stays with the port",
      tostring(entity.id()), sb.printJson(mcontroller.position()))
    return
  end

  local ticks = self.petportsTicks or 0
  if storage.petportsNoDrop then
    storage.petportsNoDrop = nil
    if ticks < PETPORTS_CULL_TICKS then
      sb.logInfo("UNIT %s died %s update(s) after init with the unload latch in storage -- "
        .. "the unload cull completing, cargo stays with the port",
        tostring(entity.id()), sb.printJson(ticks))
      return
    end
    sb.logInfo("UNIT %s died %s update(s) after init with a stale unload latch -- a real death, reporting it",
      tostring(entity.id()), sb.printJson(ticks))
  end

  if self.anchorId == nil or not world.entityExists(self.anchorId) then
    sb.logInfo("UNIT %s died at %s with no live port to tell",
      tostring(entity.id()), sb.printJson(mcontroller.position()))
    return
  end

  sb.logInfo("UNIT %s died at %s -- asking port %s to spill the load",
    tostring(entity.id()), sb.printJson(mcontroller.position()),
    tostring(self.anchorId))

  world.sendEntityMessage(self.anchorId, "petports_unitDied", {
    position = mcontroller.position(),
    id = entity.id(),
    unit = entity.uniqueId()
  })
end

local petportsBaseInit = init

-- Calls the base init, applies the spawn name, and fades the unit in when it was materialised.
function init()
  if petportsBaseInit then
    petportsBaseInit()
  end

  stampOnce()

  local spawnName = config.getParameter("petName")

  if type(spawnName) == "string" and spawnName ~= "" then
    petports_setUnitName(spawnName, config.getParameter("petports_showNametag", false))
  end

  if not config.getParameter("petports_materialise", false) then
    return
  end

  animator.setAnimationState("movement", "invisible")

  local ok, err = pcall(status.addEphemeralEffect, "petports_unitfadein")

  if not ok then
    sb.logError("PETPORTS unit %s could not apply petports_unitfadein: %s",
      tostring(entity.id()), tostring(err))
  end
end

-- Sets the unit's name and whether its nametag shows.
function petports_setUnitName(name, show)
  if type(name) ~= "string" or name == "" then
    sb.logInfo("UNIT setUnitName REFUSED: %s is not a usable name",
      sb.printJson(name))
    return false
  end

  local ok, err = pcall(monster.setName, name)

  if not ok then
    sb.logInfo("UNIT setUnitName FAILED for %s: %s", tostring(name), tostring(err))
    return false
  end

  local okTag, errTag = pcall(monster.setDisplayNametag, show == true)

  if not okTag then
    sb.logInfo("UNIT setDisplayNametag FAILED: %s", tostring(errTag))
  end

  sb.logInfo("UNIT name set to %s, tag %s", tostring(name), tostring(show == true))
  return true
end

-- Stores a clamped colour triple, lamp intensity, sweep speed and sweep direction in the light status properties.
function petports_setLightColor(r, g, b, intensity, speed, reverse)
  -- Returns a value as a whole number clamped to 0-255, or the default.
  local function channel(value, default)
    value = tonumber(value)
    if value == nil then return default end

    value = math.floor(value)
    if value < 0 then return 0 end
    if value > 255 then return 255 end

    return value
  end

  local color = { channel(r, 140), channel(g, 140), channel(b, 140) }
  local level = channel(intensity, 80)

  local rate = channel(speed, 8)
  if rate < 1 then rate = 1 end
  if rate > 16 then rate = 16 end

  local ok, err = pcall(status.setStatusProperty, "petports_lightColor", color)

  if not ok then
    sb.logInfo("UNIT setLightColor FAILED: %s", tostring(err))
    return false
  end

  local okLevel, errLevel = pcall(status.setStatusProperty, "petports_lightIntensity", level)

  if not okLevel then
    sb.logInfo("UNIT setLightIntensity FAILED: %s", tostring(errLevel))
    return false
  end

  local okRate, errRate = pcall(status.setStatusProperty, "petports_lightSpeed", rate)

  if not okRate then
    sb.logInfo("UNIT setLightSpeed FAILED: %s", tostring(errRate))
    return false
  end

  local okDir, errDir = pcall(status.setStatusProperty, "petports_lightReverse", reverse == true)

  if not okDir then
    sb.logInfo("UNIT setLightReverse FAILED: %s", tostring(errDir))
    return false
  end

  sb.logInfo("UNIT light colour set to %s, intensity %s, speed %s, reverse %s",
    sb.printJson(color), tostring(level), tostring(rate), tostring(reverse == true))
  return true
end

-- Applies the module effects, flags, liquid permissions and the fuel and speed scales.
function petports_setModuleEffects(effects, category, liquids, flags, baseTeam,
                                   fuelScale, speedScale)
  category = category or "petports_modules"
  effects = effects or {}

  petports_applyModuleFlags(flags or {}, baseTeam)

  self.petportsFuelScale = tonumber(fuelScale) or 1.0

  self.petportsSpeedScale = tonumber(speedScale) or 1.0

  self.petportsModuleLiquids = petports_habitatPermittedSet(liquids or {})
  self.petportsAvoidLiquids = nil
  self.petportsLiquidVerdict = nil

  local ok, err = pcall(status.setPersistentEffects, category, effects)

  if not ok then
    sb.logInfo("UNIT setModuleEffects FAILED for category %s: %s",
      tostring(category), tostring(err))
    return false
  end

  sb.logInfo("UNIT module effects applied under %s: %s -- liquid permissions %s",
    tostring(category), sb.printJson(effects), sb.printJson(liquids or {}))
  return true
end


-- Moves the unit to a position and stops it.
function petports_ventTeleport(position)
  if position == nil then
    sb.logInfo("UNIT ventTeleport called with nil position")
    return false
  end

  local before = mcontroller.position()

  mcontroller.setPosition(position)
  mcontroller.setVelocity({0, 0})

  sb.logInfo("UNIT teleported: from %s asked %s ended at %s",
    sb.printJson(before), sb.printJson(position),
    sb.printJson(mcontroller.position()))

  return true
end


-- Accepts a task unless one is already held.
function petports_assignTask(task)
  if task == nil or task.id == nil then
    sb.logInfo("UNIT refusing assignment: malformed task %s", sb.printJson(task))
    return false
  end

  if self.petportsTask ~= nil then
    sb.logInfo("UNIT refusing assignment %s: already holding %s",
      tostring(task.id), tostring(self.petportsTask.id))
    return false
  end

  sb.logInfo("UNIT accepted task %s type %s target %s at %s",
    tostring(task.id), tostring(task.type),
    sb.printJson(task.target), sb.printJson(task.position))

  self.petportsTask = task
  return true
end

-- Returns the held task's id.
function petports_taskId()
  return self.petportsTask and self.petportsTask.id or nil
end

-- Drops the held task.
function petports_clearTask()
  sb.logInfo("UNIT task cleared by port (was %s)",
    self.petportsTask and tostring(self.petportsTask.id) or "none")
  self.petportsTask = nil
  return true
end

-- Stores the network rects, the home position and the unit count.
function petports_setNetwork(rects, home, units)
  self.petportsNetwork = rects
  self.petportsHome = home
  self.petportsNetworkUnits = tonumber(units)
  return true
end

local TETHER_SLACK = 3.0

-- Returns the task that walks the unit home, or nil while it is inside the network.
function petports_leashTask()
  if self.petportsHome == nil then return nil end

  local tethered = config.getParameter("strictPortTethering", false)

  if tethered then
    local distance = world.magnitude(mcontroller.position(), self.petportsHome)
    if distance <= TETHER_SLACK and self.petportsLeashTask ~= nil
       and self.petportsLeashTask.arrivedHome then
      return self.petportsLeashTask
    end
  elseif petports_inNetwork(mcontroller.position()) then
    self.petportsLeashTask = nil
    return nil
  end

  self.petportsLeashTask = self.petportsLeashTask or {
    id = "leash",
    type = "return",
    position = self.petportsHome,
    dwell = 0
  }

  self.petportsLeashTask.position = self.petportsHome
  self.petportsLeashTask.hold = tethered
  self.petportsLeashTask.slack = TETHER_SLACK

  return self.petportsLeashTask
end

-- Returns whether a position falls inside any network rect.
function petports_inNetwork(position)
  if self.petportsNetwork == nil or #self.petportsNetwork == 0 then return true end

  for _, rect in ipairs(self.petportsNetwork) do
    if position[1] >= rect[1] and position[1] <= rect[3]
       and position[2] >= rect[2] and position[2] <= rect[4] then
      return true
    end
  end
  return false
end


local PETPORTS_SUBMERGED_FILL = 0.9

local PETPORTS_HARMFUL_FILL = 0.1

PETPORTS_WALL_MARGIN = 0

-- Returns whether this chassis keeps out of liquid.
function petports_avoidLiquid()
  if petports_freeMover() then return false end
  return config.getParameter("petports_avoidLiquid", true)
end


-- Returns whether a plan can be started in a swim mode.
function petports_canPathfindIn(mode)
	if mode == PETPORTS_SWIM_MODE_AQUATIC then return true end
	if mode == PETPORTS_SWIM_MODE_EXITING then return true end
	return mcontroller.onGround() or not mcontroller.baseParameters().gravityEnabled
end

-- Returns whether a plan can be started in the current swim mode.
function petportsCanPathfind(finder)
	return petports_canPathfindIn(petports_swimMode())
end

-- Returns a speed multiplied by the module speed scale.
function petports_scaledSpeed(base)
	local value = tonumber(base)

	if value == nil then
		if self.petportsSpeedScaleComplaint ~= true then
			self.petportsSpeedScaleComplaint = true
			sb.logInfo("UNIT petports_scaledSpeed got a non-number (%s) -- "
				.. "the caller is reading a field that does not exist, and this "
				.. "scaling is doing nothing", tostring(base))
		end

		return base
	end

	self.petportsSpeedScaleComplaint = nil

	return value * (tonumber(self.petportsSpeedScale) or 1.0)
end

-- Starts the A* search with this chassis's jump, speed and gravity parameters.
function petportsPathStart(finder, sourcePosition, targetPosition)
	finder.target = targetPosition

	local baseParameters = mcontroller.baseParameters()
	local jumpSpeed = baseParameters.airJumpProfile.jumpSpeed
	jumpSpeed = jumpSpeed + (jumpSpeed * status.stat("jumpModifier"))
	baseParameters.airJumpProfile.jumpSpeed = jumpSpeed

	baseParameters.walkSpeed = petports_scaledSpeed(baseParameters.walkSpeed)
	baseParameters.runSpeed  = petports_scaledSpeed(baseParameters.runSpeed)
	baseParameters.flySpeed  = petports_scaledSpeed(baseParameters.flySpeed)

	if petports_freeMover() then
		baseParameters.gravityEnabled = false
	end

	finder.aStar = world.platformerPathStart(sourcePosition, finder.target,
		baseParameters, finder.options)
end

-- Returns whether the unit moves without gravity.
function petports_freeMover()
  if self.petportsNavSurveyFree ~= nil then return self.petportsNavSurveyFree end
  if petports_swimMode() == PETPORTS_SWIM_MODE_AQUATIC then return true end
  return not mcontroller.baseParameters().gravityEnabled
end

-- Returns the avoided liquid name set with module permissions taken out, cached.
local function avoidedLiquids()
  if self.petportsAvoidLiquids ~= nil then return self.petportsAvoidLiquids end

  local avoided =
    petports_habitatAvoidedSet(config.getParameter("petports_avoidLiquids", {}))

  local permitted = self.petportsModuleLiquids
  if permitted ~= nil and next(permitted) ~= nil then
    for name in pairs(permitted) do
      if avoided[name] then
        avoided[name] = nil
        sb.logInfo("UNIT module permission unlocks liquid %s -- it is no longer avoided",
          tostring(name))
      end
    end
  end

  self.petportsAvoidLiquids = avoided
  return avoided
end

-- Returns whether a liquid name is avoided.
function petports_liquidNameDenied(name)
  if name == nil then return false end
  return avoidedLiquids()[string.lower(tostring(name))] == true
end

-- Returns whether a liquid id is avoided, cached.
function petports_liquidDenied(liquidId)
  if liquidId == nil then return false end

  self.petportsLiquidVerdict = self.petportsLiquidVerdict or {}
  local cached = self.petportsLiquidVerdict[liquidId]
  if cached ~= nil then return cached end

  local names = avoidedLiquids()
  local denied = petports_habitatLiquidDenied(names, liquidId)

  if next(names) ~= nil then
    sb.logInfo("UNIT liquid %s resolves to %s -- %s",
      sb.printJson(liquidId), sb.printJson(petports_habitatLiquidNames(liquidId)),
      denied and "DENIED, this chassis will not enter it" or "allowed")
  end

  self.petportsLiquidVerdict[liquidId] = denied
  return denied
end

-- Returns the medium a body occupies at a position: forbidden, swim, mixed or air.
function petports_mediumAt(position, bounds)
  if position == nil then return "air" end
  bounds = bounds or mcontroller.boundBox()

  local x = position[1]
  local bottom = math.floor(position[2] + bounds[2])
  local top = math.ceil(position[2] + bounds[4]) - 1

  local submerged, anySubmerged = true, false

  local margin = PETPORTS_WALL_MARGIN or 0
  local leftCol = math.floor(position[1] + (bounds[1] or -0.5) - margin + 0.01)
  local rightCol = math.floor(position[1] + (bounds[3] or 0.5) + margin - 0.01)
  local wallBottom = math.floor(position[2] + (bounds[2] or -0.5) - margin + 0.01)
  local wallTop = math.floor(position[2] + (bounds[4] or 0.5) + margin - 0.01)

  for row = wallBottom, wallTop do
    for col = leftCol, rightCol do
      local side = world.liquidAt({ col + 0.5, row + 0.5 })
      local sideFill = (side ~= nil) and (side[2] or 0) or 0

      if sideFill >= PETPORTS_HARMFUL_FILL and petports_liquidDenied(side[1]) then
        return "forbidden"
      end
    end
  end

  for row = bottom, top do
    local level = world.liquidAt({ x, row + 0.5 })

    local fill = (level ~= nil) and (level[2] or 0) or 0

    if fill >= PETPORTS_HARMFUL_FILL and petports_liquidDenied(level[1]) then
      return "forbidden"
    end

    if fill < PETPORTS_SUBMERGED_FILL then
      submerged = false
    else
      anySubmerged = true
    end
  end

  if submerged then return "swim" end
  if anySubmerged then return "mixed" end
  return "air"
end

-- Returns the medium at a single point: forbidden, swim or air.
function petports_mediumAtPoint(position)
  if position == nil then return "air" end

  local level = world.liquidAt(position)
  local fill = (level ~= nil) and (level[2] or 0) or 0

  if fill >= PETPORTS_HARMFUL_FILL and petports_liquidDenied(level[1]) then
    return "forbidden"
  end

  return (fill >= PETPORTS_SUBMERGED_FILL) and "swim" or "air"
end

-- Returns whether a body at a position is fully submerged.
function petports_submergedAt(position, bounds)
  return petports_mediumAt(position, bounds) == "swim"
end

-- Returns whether this chassis can fly and swim, cached.
function petports_media()
  if self.petportsMedia == nil then
    self.petportsMedia = {
      fly = config.getParameter("petports_canFly", true),
      swim = config.getParameter("petports_canSwim", false)
    }

    sb.logInfo("UNIT locomotion media: canFly %s, canSwim %s%s",
      tostring(self.petportsMedia.fly), tostring(self.petportsMedia.swim),
      (not self.petportsMedia.fly and not self.petportsMedia.swim)
        and " -- NEITHER, this chassis can legally occupy nothing and will refuse every target"
        or "")
  end

  return self.petportsMedia
end

-- Returns the chassis's damage team, storing one the port sent.
local function baseTeam(sent)
  if type(sent) == "table" and sent.type ~= nil then
    self.petportsBaseTeam = sent
  end

  if self.petportsBaseTeam ~= nil then return self.petportsBaseTeam end

  return entity.damageTeam()
end

-- Records the door-opening flag, and sets the damage team to ghostly while a camouflage module is socketed, otherwise back to the chassis default.
function petports_applyModuleFlags(flags, sentBaseTeam)
  local set = {}
  for _, flag in ipairs(flags or {}) do set[flag] = true end

  self.petportsOpenDoors = set.openDoors == true

  local base = baseTeam(sentBaseTeam)

  local want = set.camouflage and { type = "ghostly", team = 0 } or base
  local have = entity.damageTeam()

  if have ~= nil and want ~= nil
     and tostring(have.type) == tostring(want.type)
     and have.team == want.team then
    return
  end

  local ok, err = pcall(monster.setDamageTeam, want)

  if not ok then
    sb.logInfo("UNIT setDamageTeam FAILED for %s: %s", sb.printJson(want), tostring(err))
    return
  end

  sb.logInfo("UNIT damage team %s -> %s (%s)",
    have and (tostring(have.type) .. "/" .. tostring(have.team)) or "nil",
    tostring(want.type) .. "/" .. tostring(want.team),
    set.camouflage and "camouflage module socketed" or "chassis default restored")
end

-- Returns this chassis's movement and liquid capabilities.
function petports_capabilities()
  local freeMover = petports_freeMover()

  if petports_gravitySwitchable() then freeMover = false end

  local media = freeMover and petports_media() or {}

  return
  {
    freeMover = freeMover,
    fly = media.fly,
    swim = media.swim,
    avoidLiquid = petports_avoidLiquid(),
    avoided = avoidedLiquids()
  }
end

-- Returns the habitat verdict for a footprint, with its reason text.
function petports_canInhabit(wet, dry, liquids)
  local verdict = petports_habitatVerdict(petports_capabilities(), wet, dry, liquids)

  if verdict == nil then return nil end

  verdict.reason = petports_habitatReason(verdict.cause)
  return verdict
end

-- Returns whether the unit may work at a point, with the reason.
function petports_targetAllowed(position)
  local media = petports_media()
  local medium = petports_mediumAtPoint(position)

  if medium == "forbidden" then
    return false, "target sits in a liquid this chassis will not enter"
  end

  if medium == "swim" then
    if media.swim then return true, "target is submerged" end
    return false, "target is submerged and this chassis cannot swim"
  end

  if media.fly then return true, "target is in air" end
  return false, "target is not submerged and this chassis cannot leave the water"
end

-- Returns whether the unit may occupy a footprint, with the reason.
function petports_mediumAllows(position, bounds)
  local medium = petports_mediumAt(position, bounds)

  if medium == "forbidden" then
    return false, "a liquid this chassis will not enter"
  end

  if not petports_freeMover() then
    return true, "walking chassis, medium is physics"
  end

  local media = petports_media()

  if medium == "swim" then
    if media.swim then return true, "submerged" end
    return false, "submerged and this chassis cannot swim"
  end

  if medium == "mixed" then
    if media.fly and media.swim then return true, "either medium, the waterline is nothing" end
    return false, "straddling the waterline, which no free-moving chassis can hold"
  end

  if media.fly then return true, "air" end
  return false, "not submerged and this chassis cannot fly"
end

PETPORTS_SWIM_MODE_LAND = "land"
PETPORTS_SWIM_MODE_AQUATIC = "aquatic"
PETPORTS_SWIM_MODE_EXITING = "exiting"

PETPORTS_SWIM_MODE_DIVING = "diving"

PETPORTS_DIVE_DROP_ALIGN = 1.5

PETPORTS_DIVE_GRACE = 3.0

PETPORTS_DIVE_SWEEP_SAMPLES = 12

PETPORTS_DIVE_HOP = 12.0

PETPORTS_DIVE_BOARD_FOOT = 0.4

PETPORTS_DIVE_SHUFFLE_TIMEOUT = 1.5

-- Returns whether this chassis switches gravity, cached.
function petports_gravitySwitchable()
	if self.petportsGravitySwitchable == nil then
		self.petportsGravitySwitchable =
			config.getParameter("petports_gravitySwitchable", false) and true or false
	end

	return self.petportsGravitySwitchable
end

-- Returns the current swim mode.
function petports_swimMode()
	return self.petportsSwimMode or PETPORTS_SWIM_MODE_LAND
end

PETPORTS_DIVE_SOLID_SET = { "Null", "Block", "Slippery", "Dynamic" }

-- Drops the dive flight, plan and entry.
function petports_diveForget()
	self.petportsDiveFlight = nil

	self.petportsDivePlan = nil
	self.petportsDiveEntry = nil
	self.petportsDivePuddleNoted = nil

	self.petportsDiveRetarget = nil
end

-- Returns whether the tile under the feet is a platform and not solid.
local function platformUnderfoot()
	local position = mcontroller.position()
	local bounds = mcontroller.boundBox()

	local probe = { position[1], position[2] + bounds[2] - 0.5 }

	if world.pointTileCollision(probe, PETPORTS_DIVE_SOLID_SET) then return false end

	return world.pointTileCollision(probe, { "Platform" })
end

PETPORTS_DROP_LIQUID_DEPTH = 4

-- Returns whether liquid lies within drop depth under the tile beneath the feet.
local function liquidUnderPlatform()
	local position = mcontroller.position()
	local bounds = mcontroller.boundBox()

	local feet = position[2] + bounds[2]

	for row = math.floor(feet) - 2, math.floor(feet) - 1 - PETPORTS_DROP_LIQUID_DEPTH, -1 do
		if petports_mediumAtPoint({ position[1], row + 0.5 }) == "swim" then return true end
	end

	return false
end

-- Scoots a grounded walker through the platform underfoot when its destination is liquid below it.
local function dropIntoLiquid(destination)
	if type(destination) ~= "table" then return end
	if self.petportsArrived then return end
	if petports_swimMode() ~= PETPORTS_SWIM_MODE_LAND or petports_diving() then return end
	if not mcontroller.onGround() then return end
	if petports_scootThroughPlatform == nil then return end

	local position = mcontroller.position()
	local bounds = mcontroller.boundBox()
	local feet = position[2] + bounds[2]

	if destination[2] >= feet then return end
	if petports_mediumAt(position, bounds) == "swim" then return end
	if petports_mediumAt(destination, bounds) ~= "swim" then return end
	if not platformUnderfoot() then return end

	local key = string.format("%s,%s>%s,%s", math.floor(position[1]), math.floor(feet),
		math.floor(destination[1]), math.floor(destination[2]))

	if not liquidUnderPlatform() then
		if self.petportsDropNoted ~= key then
			self.petportsDropNoted = key
			sb.logInfo("UNIT DROP refused at %s: destination %s is liquid below, a platform is underfoot, "
				.. "but no liquid within %s tiles under it",
				sb.printJson(position), sb.printJson(destination),
				sb.printJson(PETPORTS_DROP_LIQUID_DEPTH))
		end
		return
	end

	local dropped, why = petports_scootThroughPlatform(self.pather, feet - 0.5)

	if dropped then
		self.petportsDropNoted = nil
		self.petportsSwimModeRebuiltAt = nil
		sb.logInfo("UNIT DROP through the platform at %s toward %s: %s | below: %s",
			sb.printJson(position), sb.printJson(destination), tostring(why),
			petports_probeBelow(mcontroller.position()))
	elseif self.petportsDropNoted ~= key then
		self.petportsDropNoted = key
		sb.logInfo("UNIT DROP refused at %s toward %s: %s | below: %s",
			sb.printJson(position), sb.printJson(destination), tostring(why),
			petports_probeBelow(position))
	end
end

-- Returns whether the body's collision poly, or its bound box, hits a collision set at a position.
function petports_bodyHitsAt(position, collisionSet)
	local okPoly, poly = pcall(mcontroller.collisionPoly)

	if okPoly and type(poly) == "table" and #poly >= 3 then
		local ok, hit = pcall(world.polyCollision, poly, position, collisionSet)
		if ok then return hit == true end
	end

	local box = rect.translate(mcontroller.boundBox(), position)
	return world.rectTileCollision(box, collisionSet) == true
end

-- Returns whether the body clears solid tiles at a position.
local function bodyFitsAt(position)
	return not petports_bodyHitsAt(position, PETPORTS_DIVE_SOLID_SET)
end

PETPORTS_DIVE_SWIM_SAMPLES = 14

-- Returns whether the body clears every sample along a line.
function petports_bodyFitsAlong(from, to)
	if from == nil or to == nil then return false end

	local length = world.magnitude(from, to)
	local samples = math.max(PETPORTS_DIVE_SWIM_SAMPLES, math.ceil(length / 0.5))

	for i = 0, samples do
		local t = i / samples
		local at = {
			from[1] + ((to[1] - from[1]) * t),
			from[2] + ((to[2] - from[2]) * t)
		}

		if not bodyFitsAt(at) then return false end
	end

	return true
end

-- Returns whether the body fits along the line from here to a target.
local function swimReachable(target)
	if target == nil then return false end
	return petports_bodyFitsAlong(mcontroller.position(), target)
end

-- Logs why a dive launch point was refused.
function petports_diveRefuse(point, why)
	if point == nil then return end

	sb.logInfo("UNIT DIVE REFUSED from %s: %s", sb.printJson(point), tostring(why))
end

PETPORTS_DIVE_BOARD_ARRIVAL = 1.5

-- Returns whether a dive flight is in progress.
function petports_diving()
	return self.petportsDiveFlight ~= nil
end

-- Throws the unit at the entry hole when the arc is clear, and enters diving mode.
function petports_diveLaunch(plan, hop)
	local source = mcontroller.position()
	local entry = plan.entry

	local dx = entry[1] - source[1]
	local dy = entry[2] - source[2]

	if dy >= 0 then
		return false, string.format("the hole at %s is not below the board at %s",
			sb.printJson(entry), sb.printJson(source))
	end

	local parameters = mcontroller.baseParameters()
	local gravity = world.gravity(source) * (parameters.gravityMultiplier or 1.0)

	if gravity <= 0 then return false, "no gravity to fall with" end

	local vy0 = hop or PETPORTS_DIVE_HOP
	local disc = (vy0 * vy0) - (2 * gravity * dy)
	if disc < 0 then return false, "no descending solution" end

	local time = (vy0 + math.sqrt(disc)) / gravity
	if time <= 0 then return false, "degenerate fall time" end

	local aligned = math.abs(dx) <= PETPORTS_DIVE_DROP_ALIGN
	local vx = aligned and 0 or (dx / time)

	for i = 1, PETPORTS_DIVE_SWEEP_SAMPLES do
		local t = (time * i) / PETPORTS_DIVE_SWEEP_SAMPLES
		local at = {
			source[1] + (vx * t),
			source[2] + (vy0 * t) - ((gravity * t * t) / 2)
		}

		if not bodyFitsAt(at) then
			return false, string.format("the flight is blocked at %s (sample %s of %s)",
				sb.printJson(at), sb.printJson(i),
				sb.printJson(PETPORTS_DIVE_SWEEP_SAMPLES))
		end
	end

	mcontroller.setVelocity({ vx, vy0 })

	self.petportsDiveFlight = {
		startedAt = world.time(),
		startY = source[2],
		peak = 0,
		deadline = world.time() + time + PETPORTS_DIVE_GRACE,
		entry = { entry[1], entry[2] },
		aligned = aligned,
		vx = vx,

		dropThrough = vy0 <= 0
	}

	petports_setSwimMode(PETPORTS_SWIM_MODE_DIVING, "dive launched")

	sb.logInfo("UNIT DIVE launched from %s toward %s: %s, dx %s dy %s, "
		.. "vx %s, predicted %s s, deadline +%s s",
		sb.printJson(source), sb.printJson(entry),
		aligned and (vy0 > 0 and "aligned hop-and-drop" or "aligned drop-through, no hop")
			or "hopped off with horizontal velocity",
		sb.printJson(dx), sb.printJson(dy), sb.printJson(vx),
		sb.printJson(time), sb.printJson(time + PETPORTS_DIVE_GRACE))

	return true
end

-- Returns landed once submerged, a failure reason, or nil while still in the air.
function petports_diveOutcome()
	local flight = self.petportsDiveFlight
	if flight == nil then return nil end

	local height = mcontroller.position()[2] - flight.startY

	if height > (flight.peak or 0) then flight.peak = height end

	local medium = petports_mediumAt(mcontroller.position(), mcontroller.boundBox())

	if medium == "swim" then return "landed" end

	if not flight.airborne then
		if not mcontroller.onGround() then flight.airborne = true end
		return nil
	end

	if mcontroller.onGround() then
		return "hit solid ground without reaching the water"
	end

	if world.time() >= flight.deadline then
		return string.format("still airborne %s s after launch",
			sb.printJson(world.time() - flight.startedAt))
	end

	return nil
end

PETPORTS_SWIM_TASK_TYPES = {
	fish = true
}

-- Returns whether the held task is one that swims.
local function taskWantsSwimming()
	if self.petportsLegSide == 1 then return true end

	local task = self.petportsTask

	return type(task) == "table" and task.type ~= nil
		and PETPORTS_SWIM_TASK_TYPES[task.type] == true
end

-- Returns the swim mode the current position, task and destination call for.
function petports_desiredSwimMode(destination)
	if not petports_gravitySwitchable() then return PETPORTS_SWIM_MODE_LAND end

	if petports_diving() then return PETPORTS_SWIM_MODE_DIVING end

	local medium = petports_mediumAt(mcontroller.position(), mcontroller.boundBox())

	if medium == "air" then return PETPORTS_SWIM_MODE_LAND end

	if petports_swimMode() == PETPORTS_SWIM_MODE_LAND then
		if medium ~= "swim" then return PETPORTS_SWIM_MODE_LAND end

		if self.petportsTask ~= nil and taskWantsSwimming() then
			local plan = self.petportsDivePlan

			if plan ~= nil and not plan.reached and not plan.abandoned then
				if not self.petportsDivePuddleNoted then
					self.petportsDivePuddleNoted = true
					sb.logInfo("UNIT submerged at %s but has not reached its board at %s "
						.. "(%s tiles away) -- not diving yet, staying a walker",
						sb.printJson(mcontroller.position()), sb.printJson(plan.launch),
						sb.printJson(world.magnitude(mcontroller.position(), plan.launch)))
				end

				return PETPORTS_SWIM_MODE_LAND
			end

			self.petportsDivePuddleNoted = nil
		end
	end

	if destination == nil then return PETPORTS_SWIM_MODE_AQUATIC end

	if petports_mediumAt(destination, mcontroller.boundBox()) == "swim" then
		return PETPORTS_SWIM_MODE_AQUATIC
	end

	return PETPORTS_SWIM_MODE_EXITING
end

-- Returns the current leg waypoint, the last leg, or the task's own position.
function petports_currentTaskDestination()
	if type(self.petportsLegWaypoint) == "table" then
		return self.petportsLegWaypoint
	end

	return petports_taskDestinationRaw()
end

-- Returns the held task's position, or the leash task's.
function petports_taskDestinationRaw()
	local task = self.petportsTask

	if type(task) == "table" and type(task.position) == "table" then
		return task.position
	end

	local leash = self.petportsLeashTask

	if type(leash) == "table" and type(leash.position) == "table" then
		return leash.position
	end

	return nil
end

PETPORTS_SWIM_MODE_REBUILD_INTERVAL = 1.0

PETPORTS_MEDIA_TRACE = true

-- Logs the inputs behind the desired swim mode whenever any of them changes.
local function swimModeNote(desired, destination)
	local here = mcontroller.position()
	local medium = petports_mediumAt(here, mcontroller.boundBox())
	local source = "none"
	if destination ~= nil then
		if destination == self.petportsLegWaypoint then
			source = "leg waypoint"
		else
			source = "task"
		end
	end
	local destMedium = destination ~= nil and petports_mediumAt(destination, mcontroller.boundBox()) or "n/a"
	local plan = self.petportsDivePlan
	local planState = plan == nil and "none"
		or (plan.abandoned and "abandoned" or (plan.reached and "reached" or "to board"))
	local key = tostring(desired) .. "|" .. tostring(petports_swimMode()) .. "|" .. tostring(medium)
		.. "|" .. source .. "|" .. tostring(destMedium) .. "|" .. tostring(self.petportsLegSide)
		.. "|" .. planState .. "|" .. tostring(petports_diving())
	if self.petportsSwimModeNoted == key then return end
	self.petportsSwimModeNoted = key
	sb.logInfo("UNIT swim mode wants %s (now %s) at %s: medium %s, destination %s from the %s reads %s, "
		.. "leg side %s, task swims %s, dive plan %s, diving %s, onGround %s",
		tostring(desired), tostring(petports_swimMode()), sb.printJson(here), tostring(medium),
		sb.printJson(destination), source, tostring(destMedium), tostring(self.petportsLegSide),
		tostring(taskWantsSwimming()), planState, tostring(petports_diving()),
		tostring(mcontroller.onGround()))
end

-- Rebuilds the pather on a mode change, runs the wade and dive steps, and applies the mode.
function petports_swimModeTick()
	if not petports_gravitySwitchable() then return end

	if not self.petportsSwimModeRebuilding then
		local destination = petports_currentTaskDestination()
		local desired = petports_desiredSwimMode(destination)
		if PETPORTS_MEDIA_TRACE then swimModeNote(desired, destination) end

		if desired ~= petports_swimMode() then
			if not petports_canPathfindIn(desired) then
				if self.petportsSwimModeDeferred ~= desired then
					self.petportsSwimModeDeferred = desired
					sb.logInfo("UNIT swim mode rebuild to %s DEFERRED at %s: "
						.. "cannot plan from here (onGround %s) -- holding the live plan",
						tostring(desired), sb.printJson(mcontroller.position()),
						tostring(mcontroller.onGround()))
				end
			else
				self.petportsSwimModeDeferred = nil

				local now = world.time()
				local last = self.petportsSwimModeRebuiltAt or -math.huge

				if now - last >= PETPORTS_SWIM_MODE_REBUILD_INTERVAL then
					self.petportsSwimModeRebuiltAt = now
					self.petportsSwimModeRebuilding = true
					self.petportsSwimModeThrottled = nil

					local ok, err = pcall(petports_freshPather,
						"swim mode wants " .. tostring(desired))

					self.petportsSwimModeRebuilding = false

					if not ok then
						sb.logInfo("UNIT swim mode rebuild to %s FAILED: %s",
							tostring(desired), tostring(err))
					end
				elseif PETPORTS_MEDIA_TRACE and self.petportsSwimModeThrottled ~= desired then
					self.petportsSwimModeThrottled = desired
					sb.logInfo("UNIT swim mode rebuild to %s THROTTLED at %s: last rebuild %s s ago "
						.. "(interval %s), mode stays %s",
						tostring(desired), sb.printJson(mcontroller.position()), sb.printJson(now - last),
						sb.printJson(PETPORTS_SWIM_MODE_REBUILD_INTERVAL), tostring(petports_swimMode()))
				end
			end
		end
	end

	if not taskWantsSwimming()
	   and self.petportsDivePlan ~= nil then
		petports_diveForget()
	end

	local wade = self.petportsLegBridge
	if type(wade) == "table" and wade.k == "wade"
	   and petports_swimMode() == PETPORTS_SWIM_MODE_LAND
	   and type(self.petportsLegWaypoint) == "table" then
		local here = mcontroller.position()
		if petports_mediumAt(here, mcontroller.boundBox()) ~= "swim" then
			local direction = self.petportsLegWaypoint[1] > here[1] and 1 or -1
			mcontroller.controlMove(direction, false)
			mcontroller.controlFace(direction)
			if self.petportsWadeNoted ~= wade then
				self.petportsWadeNoted = wade
				sb.logInfo("UNIT WADE walking %s into the water toward %s from %s",
					direction > 0 and "right" or "left",
					sb.printJson(self.petportsLegWaypoint), sb.printJson(here))
			end
		end
	end

	dropIntoLiquid(petports_currentTaskDestination())

	local plan = self.petportsDivePlan

	if plan ~= nil and not plan.reached and not plan.abandoned
	   and plan.launch ~= nil then
		local gap = world.magnitude(mcontroller.position(), plan.launch)

		if gap <= PETPORTS_DIVE_BOARD_ARRIVAL then
			plan.reached = true

			sb.logInfo("UNIT DIVE reached its board at %s (%s from %s) -- clear to enter the water",
				sb.printJson(plan.launch), sb.printJson(gap),
				sb.printJson(mcontroller.position()))
		end
	end

	local medium = petports_mediumAt(mcontroller.position(), mcontroller.boundBox())

	if plan ~= nil and not plan.reached and not plan.abandoned
	   and medium == "swim" then

		local fish = petports_taskDestinationRaw()

		if swimReachable(fish) then
			plan.abandoned = true

			self.petportsDiveRetarget = true

			sb.logInfo("UNIT DIVE abandoning its board at %s: already submerged at %s "
				.. "with a clear body-width run to the fish at %s -- swimming instead",
				sb.printJson(plan.launch), sb.printJson(mcontroller.position()),
				sb.printJson(fish))
		end
	end

	if plan ~= nil and plan.reached and not petports_diving()
	   and petports_swimMode() == PETPORTS_SWIM_MODE_LAND
	   and (medium == "air" or medium == "mixed") and mcontroller.onGround() then

		local foot = world.magnitude(mcontroller.position(), plan.launch)

		if foot > PETPORTS_DIVE_BOARD_FOOT and medium == "air" then
			plan.shuffleUntil = plan.shuffleUntil
				or (world.time() + PETPORTS_DIVE_SHUFFLE_TIMEOUT)

			if world.time() < plan.shuffleUntil then
				local direction = plan.launch[1] > mcontroller.position()[1] and 1 or -1

				mcontroller.controlMove(direction, false)
				mcontroller.controlFace(direction)

				petports_assertSwimMode()
				return
			end

			if not plan.shuffleGaveUp then
				plan.shuffleGaveUp = true
				sb.logInfo("UNIT DIVE could not close the last %s tiles to its board "
					.. "at %s -- launching from %s anyway",
					sb.printJson(foot), sb.printJson(plan.launch),
					sb.printJson(mcontroller.position()))
			end
		end

		local launched, why = petports_diveLaunch(plan)

		if not launched then
			local dropped, dropWhy = false, "there is no platform under the feet to drop through"

			if platformUnderfoot() then
				dropped, dropWhy = petports_diveLaunch(plan, 0)
			end

			if not dropped then
				petports_diveRefuse(plan.launch,
					string.format("%s; and with no hop, %s",
						tostring(why), tostring(dropWhy)))
				petports_diveForget()
			end
		end
	end

	local outcome = petports_diveOutcome()

	if outcome ~= nil then
		local landed = outcome == "landed"

		sb.logInfo("UNIT DIVE %s at %s: %s (rose %s tiles above the board, %s)",
			landed and "SUCCEEDED" or "FAILED",
			sb.printJson(mcontroller.position()), tostring(outcome),
			sb.printJson(self.petportsDiveFlight.peak or 0),
			self.petportsDiveFlight.dropThrough and "drop-through" or "hop")

		self.petportsDiveFlight = nil

		self.petportsSwimModeRebuiltAt = nil

		if not landed then
			if plan ~= nil then petports_diveRefuse(plan.launch, outcome) end
			petports_diveForget()
		end
	end

	local spent = self.petportsDivePlan
	if spent ~= nil and spent.reached and not petports_diving()
	   and petports_mediumAt(mcontroller.position(), mcontroller.boundBox()) == "swim" then
		sb.logInfo("UNIT DIVE plan consumed at %s: in the water past its board at %s",
			sb.printJson(mcontroller.position()), sb.printJson(spent.launch))
		petports_diveForget()
	end

	petports_assertSwimMode()
end

-- Applies the gravity and buoyancy control parameters for the current swim mode.
function petports_assertSwimMode()
	if not petports_gravitySwitchable() then return end

	local mode = petports_swimMode()

	if mode == PETPORTS_SWIM_MODE_DIVING then
		mcontroller.controlParameters({ gravityEnabled = true })
		mcontroller.controlDown()

		local flight = self.petportsDiveFlight

		if flight ~= nil and flight.dropThrough and not flight.jumped then
			flight.jumped = true
			mcontroller.controlJump()
		end

		if flight ~= nil and flight.airborne and not flight.aligned
		   and flight.vx ~= nil then
			mcontroller.setVelocity({ flight.vx, mcontroller.velocity()[2] })
		end

		return
	end

	if mode == PETPORTS_SWIM_MODE_LAND then return end

	mcontroller.controlParameters({
		gravityEnabled = mode ~= PETPORTS_SWIM_MODE_AQUATIC,
		liquidBuoyancy = (mode == PETPORTS_SWIM_MODE_EXITING) and 1.0 or 0.0
	})
end

-- Switches the swim mode and logs the change.
function petports_setSwimMode(mode, why)
	if not petports_gravitySwitchable() then return PETPORTS_SWIM_MODE_LAND end

	local current = petports_swimMode()
	if mode == current then return current end

	self.petportsSwimMode = mode
	petports_assertSwimMode()

	sb.logInfo("UNIT swim mode %s -> %s at %s (medium %s): asked gravity %s, "
		.. "baseParameters now reports gravityEnabled %s, onGround %s, "
		.. "liquidMovement %s, freeMover %s -- %s",
		tostring(current), tostring(mode),
		sb.printJson(mcontroller.position()),
		tostring(petports_mediumAt(mcontroller.position(), mcontroller.boundBox())),
		tostring(mode ~= PETPORTS_SWIM_MODE_AQUATIC),
		tostring(mcontroller.baseParameters().gravityEnabled),
		tostring(mcontroller.onGround()),
		tostring(mcontroller.liquidMovement()),
		tostring(petports_freeMover()),
		tostring(why or "no reason given"))

	return mode
end

-- Returns whether the unit is outside the medium it can occupy, and which way off denied liquid lies.
function petports_outOfMedium()
  if not petports_freeMover() then
    return { checked = false, out = false, medium = "physics" }
  end

  if petports_gravitySwitchable() then
    return { checked = false, out = false, medium = "managed" }
  end

  local bounds = mcontroller.boundBox()
  local position = mcontroller.position()

  local medium = petports_mediumAt(position, bounds)

  if medium == "forbidden" then
    local away = { 0, 0 }
    local best = nil

    for dy = -2, 2 do
      for dx = -2, 2 do
        local tile = { math.floor(position[1]) + dx, math.floor(position[2]) + dy }
        local okLevel, level = pcall(world.liquidAt, { tile[1] + 0.5, tile[2] + 0.5 })
        local fill = (okLevel and level ~= nil) and (level[2] or 0) or 0

        if fill >= PETPORTS_HARMFUL_FILL and petports_liquidDenied(level[1]) then
          local d = dx * dx + dy * dy
          if best == nil or d < best then
            best = d
            away = { position[1] - (tile[1] + 0.5), position[2] - (tile[2] + 0.5) }
          end
        end
      end
    end

    return {
      checked = true,
      out = false,
      brush = true,
      away = away,
      medium = medium,
      position = position
    }
  end

  return {
    checked = true,
    out = not petports_mediumAllows(position, bounds),
    medium = medium,
    position = position
  }
end


-- Returns the path node position for a position and bound box.
function petports_nodePosition(position, bounds)
  bounds = bounds or mcontroller.boundBox()

  return {
    math.floor(position[1] + 0.5),
    math.ceil(position[2]) - (bounds[2] % 1)
  }
end

local FLY_SEARCH_RADIUS = 4

local FLY_POINT_DEBUG = true

local FLY_SPAN_PROBE = 6

-- Returns whether the bound box clears tiles at a position.
local function flyBodyFits(x, y, bounds)
  return not world.rectTileCollision({
    x + bounds[1], y + bounds[2],
    x + bounds[3], y + bounds[4]
  }, FLY_TILE_SET)
end

-- Returns whether the body both fits and may occupy the medium at a position.
local function flyBodyUsable(x, y, bounds)
  if not flyBodyFits(x, y, bounds) then return false, "body does not fit" end

  local ok, why = petports_mediumAllows({ x, y }, bounds)
  if not ok then return false, why end

  return true
end

-- Returns whether a point can see a target, counting a target inside a tile as seen.
local function flySighted(point, target)
  if world.pointTileCollision(target, FLY_TILE_SET) then return true end
  return not world.lineTileCollision(point, target, FLY_TILE_SET)
end

-- Logs the open row and column runs around a position and whether any tile centre fits the body.
local function logFlySpan(position, bounds)
  local width = bounds[3] - bounds[1]
  local height = bounds[4] - bounds[2]

  local x = math.floor(position[1]) + 0.5
  local y = math.floor(position[2]) + 0.5
  local row = math.floor(position[2])
  local col = math.floor(position[1])

  -- Returns whether a row is clear across the body's width.
  local function rowOpen(r)
    return not world.rectTileCollision(
      { x + bounds[1], r + 0.05, x + bounds[3], r + 0.95 }, FLY_TILE_SET)
  end

  -- Returns whether a column is clear across the body's height.
  local function colOpen(c)
    return not world.rectTileCollision(
      { c + 0.05, y + bounds[2], c + 0.95, y + bounds[4] }, FLY_TILE_SET)
  end

  -- Logs one axis's open run and the centre window inside it.
  local function report(axis, here, openHere, lowIndex, highIndex, size)
    if not openHere then
      sb.logInfo("UNIT flypoint span %s at %s: the target's own %s %s is already blocked "
        .. "for this body at the tile centre -- only a nudge can help on this axis",
        axis, sb.printJson(position), axis, sb.printJson(here))
      return
    end

    local low = lowIndex + size / 2
    local high = (highIndex + 1) - size / 2

    local hits = {}
    for i = lowIndex, highIndex do
      if (i + 0.5) >= low and (i + 0.5) <= high then table.insert(hits, i + 0.5) end
    end

    sb.logInfo("UNIT flypoint span %s at %s: open %s..%s (%s tiles), body %s %s, "
      .. "centre window %s..%s%s -- tile centres inside it: %s",
      axis, sb.printJson(position),
      sb.printJson(lowIndex), sb.printJson(highIndex),
      sb.printJson((highIndex + 1) - lowIndex),
      sb.printJson(size), (axis == "Y") and "tall" or "wide",
      sb.printJson(low), sb.printJson(high),
      (high < low) and " (EMPTY -- body does not fit this run at all)" or "",
      (#hits == 0) and "NONE, so no tile centre can ever be chosen here" or sb.printJson(hits))
  end

  local openRow = rowOpen(row)
  local bottom, top = row, row
  if openRow then
    for _ = 1, FLY_SPAN_PROBE do
      if not rowOpen(bottom - 1) then break end
      bottom = bottom - 1
    end
    for _ = 1, FLY_SPAN_PROBE do
      if not rowOpen(top + 1) then break end
      top = top + 1
    end
  end
  report("Y", row, openRow, bottom, top, height)

  local openCol = colOpen(col)
  local left, right = col, col
  if openCol then
    for _ = 1, FLY_SPAN_PROBE do
      if not colOpen(left - 1) then break end
      left = left - 1
    end
    for _ = 1, FLY_SPAN_PROBE do
      if not colOpen(right + 1) then break end
      right = right + 1
    end
  end
  report("X", col, openCol, left, right, width)
end

-- Returns the nearest tile centre where the body fits, may occupy the medium, and can see the target.
function petports_flyPointNear(position, radius, mediumVerified)
  if position == nil then return nil end

  if not petports_freeMover() then return nil end

  radius = radius or 4

  local bounds = mcontroller.boundBox()
  local originX = math.floor(position[1]) + 0.5
  local originY = math.floor(position[2]) + 0.5

  local targetOk, targetWhy = petports_targetAllowed(position)

  if mediumVerified then
    targetOk = true
    targetWhy = (targetWhy or "medium") .. ", and the caller vouched for the footprint"
  end

  if not targetOk then
    if FLY_POINT_DEBUG then
      sb.logInfo("UNIT flypoint DECLINED %s outright: %s -- no position near it can help, "
        .. "so this target is not workable by this chassis",
        sb.printJson(position), tostring(targetWhy))
    end

    return nil
  end

  if FLY_POINT_DEBUG then
    sb.logInfo("UNIT flypoint SEARCH for %s (%s): origin tile centre %s, radius %s, boundBox %s",
      sb.printJson(position), tostring(targetWhy), sb.printJson({ originX, originY }),
      sb.printJson(radius), sb.printJson(bounds))
    logFlySpan(position, bounds)
  end

  local origin = petports_nodePosition(position, bounds)

  local candidates = {}
  for dx = -radius, radius do
    for dy = -radius, radius do
      local x = origin[1] + dx
      local y = origin[2] + dy
      table.insert(candidates, { x, y, world.magnitude({ x, y }, position) })
    end
  end
  table.sort(candidates, function(a, b) return a[3] < b[3] end)

  local examined = 0

  for _, candidate in ipairs(candidates) do
    local cx, cy = candidate[1], candidate[2]
    examined = examined + 1

    local usable, why = flyBodyUsable(cx, cy, bounds)
    local reason = why

    if usable then
      if flySighted({ cx, cy }, position) then
        if FLY_POINT_DEBUG then
          sb.logInfo("UNIT flypoint ACCEPTED %s for %s after %s grid point(s): dist %s",
            sb.printJson({ cx, cy }), sb.printJson(position),
            sb.printJson(examined), sb.printJson(candidate[3]))
        end

        return { cx, cy }
      end

      reason = "fits but cannot see the target"
    end

    if FLY_POINT_DEBUG then
      sb.logInfo("UNIT flypoint  #%s grid %s dist %s: %s",
        sb.printJson(examined), sb.printJson({ cx, cy }),
        sb.printJson(candidate[3]), tostring(reason))
    end
  end

  if FLY_POINT_DEBUG then
    sb.logInfo("UNIT flypoint NO POINT for %s after %s grid point(s) out to radius %s -- "
      .. "nothing within reach fits this body, sits in a medium it may occupy, and can "
      .. "see the target, so this target will be DECLINED (media: canFly %s canSwim %s)",
      sb.printJson(position), sb.printJson(examined), sb.printJson(radius),
      tostring(petports_media().fly), tostring(petports_media().swim))
  end

  return nil
end

-- Returns a standable point near a position.
function petports_standingPointNear(position, radius, mediumVerified)
  if position == nil then return nil end
  return petports_standablePoint(position, nil, radius, mediumVerified)
end

-- Returns a standable point at a position with no search radius.
function petports_homePointNear(position)
  if position == nil then return nil end
  return petports_standablePoint(position, 0)
end


-- Stores the vent list and logs each vent's entry and exits.
function petports_setVents(vents)
  local summary = {}
  for _, vent in ipairs(vents or {}) do
    local exits = {}
    for _, destination in ipairs(vent.destinations or {}) do
      table.insert(exits, destination.id)
    end
    table.insert(summary, {id = vent.id, entry = vent.entry, exits = exits})
  end

  sb.logInfo("UNIT received %s vents: %s",
    sb.printJson(#(vents or {})), sb.printJson(summary))

  self.petportsVents = vents
  return true
end




-- Stores the route cache.
function petports_setRouteCache(cache)
  local count = 0
  for _ in pairs(cache or {}) do count = count + 1 end

  sb.logInfo("UNIT received route cache with %s edges", sb.printJson(count))

  self.petportsRoutes = cache or {}
  return true
end

-- Returns the route key for the unit at a position.
function petports_unitKey(position)
  return "u:" .. petports_tileKey(position)
end

-- Returns the route key for a target position.
function petports_targetKey(position)
  return "t:" .. petports_tileKey(position)
end

-- Returns the route key for a vent entry.
function petports_entryKey(ventId)
  return "e:" .. tostring(ventId)
end

-- Returns the route key for a vent exit.
function petports_exitKey(exitId)
  return "x:" .. tostring(exitId)
end

-- Returns the cache key for the edge between two keys.
local function edgeKey(fromKey, toKey)
  return fromKey .. ">" .. toKey
end

local ROUTE_TTL_FALSE = 60.0
local ROUTE_TTL_TRUE = 600.0

-- Returns a cached edge verdict, dropping it once its time to live has passed.
function petports_routeKnown(fromKey, toKey)
  if self.petportsRoutes == nil then return nil end

  local entry = self.petportsRoutes[edgeKey(fromKey, toKey)]
  if entry == nil then return nil end

  if type(entry) ~= "table" then return nil end

  local age = world.time() - (entry.t or 0)
  local ttl = entry.r and ROUTE_TTL_TRUE or ROUTE_TTL_FALSE

  if age > ttl then
    sb.logInfo("UNIT cache EXPIRED for %s (%s, age %s of %s) -- will re-probe",
      edgeKey(fromKey, toKey), tostring(entry.r),
      sb.printJson(age), sb.printJson(ttl))
    self.petportsRoutes[edgeKey(fromKey, toKey)] = nil
    return nil
  end

  return entry.r
end

-- Records an edge verdict and tells the port about it.
function petports_learnRoute(fromKey, toKey, reachable, portUniqueId)
  self.petportsRoutes = self.petportsRoutes or {}
  local key = edgeKey(fromKey, toKey)

  local previous = self.petportsRoutes[key]
  local was = type(previous) == "table" and previous.r or previous

  if previous ~= nil and was ~= reachable then
    sb.logInfo("UNIT cache CONTRADICTED for %s: was %s, now %s",
      key, tostring(was), tostring(reachable))
  end

  local at = world.time()
  self.petportsRoutes[key] = { r = reachable, t = at }

  if portUniqueId then
    world.sendEntityMessage(portUniqueId, "petports_learnedRoute", {
      key = key,
      reachable = reachable,
      at = at
    })
  end
end



-- Returns the pathfinder options for this chassis.
function petports_pathOptions()
  local bounds = mcontroller.boundBox()

  local pad = 0

  local flying = petports_freeMover()

  return {
    returnBest = false,
    mustEndOnGround = not flying,
    boundBox = bounds,
    standingBoundBox = { bounds[1] + pad, bounds[2], bounds[3] - pad, bounds[4] },
    droppingBoundBox = { bounds[1] + pad, bounds[2], bounds[3] - pad, bounds[4] },
    smallJumpMultiplier = config.getParameter("petports_smallJumpMultiplier", 0.70711),
    jumpDropXMultiplier = 0.125,
    enableWalkSpeedJumps = true,
    enableVerticalJumpAirControl = true,
    swimCost = config.getParameter("petports_swimCost", 5),
    liquidJumpCost = config.getParameter("petports_liquidJumpCost", 15),
    dropCost = config.getParameter("petports_dropCost", 2),

    maxFScore = config.getParameter("petports_maxFScore", 1200),
    maxDistance = config.getParameter("petports_maxDistance", 200),
    maxNodesToSearch = 70000,
    maxLandingVelocity = -10.0
  }
end

-- Runs one slice of an A* probe between two points, returning the verdict or searching.
function petports_probeStep(from, to, fromKey, toKey, exploreRate)
  if self.petportsProbe == nil
     or self.petportsProbe.fromKey ~= fromKey
     or self.petportsProbe.toKey ~= toKey then

    if self.petportsProbe ~= nil then
      sb.logInfo("UNIT probe RESTART: was %s -> %s, now %s -> %s (previous progress discarded)",
        tostring(self.petportsProbe.fromKey), tostring(self.petportsProbe.toKey),
        tostring(fromKey), tostring(toKey))
    end

    if not validStandingPosition(to, false) then
      sb.logInfo("UNIT probe %s -> %s skipped: %s is not a valid standing position",
        tostring(fromKey), tostring(toKey), sb.printJson(to))
      self.petportsProbe = nil
      return false
    end

    local finder = PathFinder:new(petports_pathOptions())
    -- Returns the probe's explore rate.
    finder.exploreRate = function() return exploreRate or 300 end
    finder:start(from, to)

    local fromValid = validStandingPosition(from, false)
    local fromGround = findGroundPosition(from, -4, 4, petports_avoidLiquid())

    sb.logInfo("UNIT probe START %s -> %s: from %s (standable %s, ground %s) to %s rate %s",
      tostring(fromKey), tostring(toKey), sb.printJson(from),
      tostring(fromValid), sb.printJson(fromGround),
      sb.printJson(to), sb.printJson(exploreRate or 300))

    self.petportsProbe = {
      finder = finder,
      from = from, to = to,
      fromKey = fromKey, toKey = toKey,
      ticks = 0
    }
  end

  self.petportsProbe.ticks = self.petportsProbe.ticks + 1

  local result = self.petportsProbe.finder.aStar:explore(exploreRate or 300)
  if result == true then
    sb.logInfo("UNIT probe %s -> %s REACHABLE after %s ticks",
      tostring(fromKey), tostring(toKey), sb.printJson(self.petportsProbe.ticks))
    self.petportsProbe = nil
    return true
  elseif result == false then
    sb.logInfo("UNIT probe %s -> %s UNREACHABLE after %s ticks (A* exhausted)",
      tostring(fromKey), tostring(toKey), sb.printJson(self.petportsProbe.ticks))
    self.petportsProbe = nil
    return false
  end

  return "searching"
end

-- Returns an edge's cached verdict, or probes for one and records it.
local function edgeReachable(fromPos, fromKey, toPos, toKey, portId, exploreRate)
  local known = petports_routeKnown(fromKey, toKey)
  if known ~= nil then
    sb.logInfo("UNIT edge %s -> %s answered FROM CACHE: %s",
      tostring(fromKey), tostring(toKey), tostring(known))
    return known
  end

  local result = petports_probeStep(fromPos, toPos, fromKey, toKey, exploreRate)
  if result == "searching" then return "searching" end

  petports_learnRoute(fromKey, toKey, result, portId)
  sb.logInfo("UNIT probed %s -> %s : %s", fromKey, toKey, tostring(result))
  return result
end

-- Searches outward through the vents for a leg list that reaches a target, returning walk, probing or nil.
function petports_planRoute(target, maxHops, portId, exploreRate, allowWalk, origin, avoid)
  local vents = self.petportsVents
  if vents == nil or #vents == 0 then
    sb.logInfo("UNIT planRoute impossible: vent list is %s",
      vents == nil and "nil (port never pushed one)" or "empty")
    return nil
  end

  local here = origin or mcontroller.position()
  local targetKey = petports_targetKey(target)

  sb.logInfo("UNIT planRoute to %s from %s (frozen origin %s), %s vents, maxHops %s, allowWalk %s",
    sb.printJson(target), sb.printJson(here), tostring(origin ~= nil),
    sb.printJson(#vents), sb.printJson(maxHops), tostring(allowWalk))

  local queue = {{
    position = here,
    key = petports_unitKey(here),
    legs = {}
  }}
  local visited = { [petports_unitKey(here)] = true }

  while #queue > 0 do
    local node = table.remove(queue, 1)

    sb.logInfo("UNIT planRoute expanding node %s at %s (%s legs so far, %s queued)",
      tostring(node.key), sb.printJson(node.position),
      sb.printJson(#node.legs), sb.printJson(#queue))

    local finishes = edgeReachable(node.position, node.key, target, targetKey,
      portId, exploreRate)
    if finishes == "searching" then return "probing" end
    if finishes == true then
      if #node.legs > 0 then
        sb.logInfo("UNIT planRoute FOUND a %s-hop route to %s",
          sb.printJson(#node.legs), sb.printJson(target))
        return node.legs
      end

      if allowWalk then
        sb.logInfo("UNIT planRoute: target walkable from %s, no hops needed",
          sb.printJson(node.position))
        return "walk"
      end

      sb.logInfo("UNIT planRoute: target walkable from %s but allowWalk is false -- continuing into vents",
        sb.printJson(node.position))
    end

    if #node.legs < maxHops then
      for _, vent in ipairs(vents) do
        local entryKey = petports_entryKey(vent.id)

        local traversable = vent.destinations ~= nil and #vent.destinations > 0
        local excluded = avoid ~= nil and avoid[vent.id] == true

        if not traversable or excluded or visited[entryKey] then
          sb.logInfo("UNIT planRoute skipping vent %s: %s",
            sb.printJson(vent.id),
            (not traversable) and "no exits wired (terminal)"
              or (excluded and "blacklisted this task" or "already visited"))
        end

        if traversable and not excluded and not visited[entryKey] then
          local canReach = edgeReachable(node.position, node.key,
            vent.entry, entryKey, portId, exploreRate)
          if canReach == "searching" then return "probing" end

          if canReach == true then
            visited[entryKey] = true

            for _, destination in ipairs(vent.destinations or {}) do
              local exitKey = petports_exitKey(destination.id)
              if not visited[exitKey] then
                visited[exitKey] = true

                local legs = {}
                for _, leg in ipairs(node.legs) do table.insert(legs, leg) end
                table.insert(legs, {
                  id = vent.id,
                  entry = vent.entry,
                  destinationId = destination.id,
                  destinationPosition = destination.position
                })

                table.insert(queue, {
                  position = destination.position,
                  key = exitKey,
                  legs = legs
                })
              end
            end
          end
        end
      end
    end
  end

  sb.logInfo("UNIT planRoute EXHAUSTED: no route to %s through %s vents within %s hops",
    sb.printJson(target), sb.printJson(#vents), sb.printJson(maxHops))
  return nil
end

-- Records the running probe as unreachable and drops it.
function petports_probeTimeout(portId)
  if self.petportsProbe == nil then return end

  if self.petportsProbe.fromKey and self.petportsProbe.toKey then
    petports_learnRoute(self.petportsProbe.fromKey, self.petportsProbe.toKey,
      false, portId)
    sb.logInfo("UNIT probe %s -> %s TIMED OUT after %s ticks, recording unreachable (this is a guess, not an answer)",
      self.petportsProbe.fromKey, self.petportsProbe.toKey,
      sb.printJson(self.petportsProbe.ticks or 0))
  end

  self.petportsProbe = nil
end

-- Drops the running probe without recording anything.
function petports_cancelProbe()
  if self.petportsProbe ~= nil then
    sb.logInfo("UNIT probe %s -> %s CANCELLED, nothing recorded",
      tostring(self.petportsProbe.fromKey), tostring(self.petportsProbe.toKey))
  end
  self.petportsProbe = nil
end


PETPORTS_DRAW_DEBUG = true

-- Returns the debug colour for a reachable, unreachable or unknown edge.
local function reachColour(known)
  if known == true then return "green" end
  if known == false then return "red" end
  return "yellow"
end

-- Returns the debug colour for an edge action.
local function actionColour(action)
  if action == "Jump" then return "orange" end
  if action == "Arc" then return "magenta" end
  if action == "Drop" then return "cyan" end
  if action == "Land" then return "blue" end
  return "white"
end

-- Draws the vents, the running probe, the task, the leg plan and the current path.
function petports_drawRouteDebug(stateData)
  if not PETPORTS_DRAW_DEBUG then return end

  local here = mcontroller.position()
  local unitKey = petports_unitKey(here)

  for _, vent in ipairs(self.petportsVents or {}) do
    local known = petports_routeKnown(unitKey, petports_entryKey(vent.id))
    local colour = reachColour(known)

    world.debugPoint(vent.entry, colour)
    world.debugText("vent %s", vent.id, {vent.entry[1], vent.entry[2] + 1.5}, colour)

    for _, destination in ipairs(vent.destinations or {}) do
      world.debugLine(vent.entry, destination.position, "blue")
      world.debugPoint(destination.position, "blue")
    end
  end

  if self.petportsProbe ~= nil then
    world.debugLine(self.petportsProbe.from, self.petportsProbe.to, "magenta")
    world.debugPoint(self.petportsProbe.from, "magenta")
    world.debugText("probing %s -> %s",
      tostring(self.petportsProbe.fromKey), tostring(self.petportsProbe.toKey),
      {here[1], here[2] + 4}, "magenta")
  end

  if stateData == nil then return end

  local task = stateData.task

  if task ~= nil then
    local phase = "walking"
    if stateData.arrived then phase = "arrived"
    elseif stateData.viaVent ~= nil then phase = "to vent " .. tostring(stateData.viaVent.id)
    elseif stateData.routing then phase = "routing"
    end

    world.debugText("%s [%s]", tostring(task.id), phase,
      {here[1], here[2] + 5}, "yellow")

    if (stateData.ventHops or 0) > 0 then
      world.debugText("hop %s", tostring(stateData.ventHops),
        {here[1], here[2] + 5.75}, "yellow")
    end

    local offset = 6.5
    for _, entry in ipairs(task.cargo or {}) do
      world.debugText("%s", entry, {here[1], here[2] + offset}, "orange")
      offset = offset + 0.75
    end

    if task.type == "deposit" and task.containerPosition ~= nil then
      world.debugLine(here, task.containerPosition, "orange")
      world.debugPoint(task.containerPosition, "orange")
      world.debugText("deposit -> %s", tostring(task.target),
        {task.containerPosition[1], task.containerPosition[2] + 1.5}, "orange")
    end

    if task.type == "upcycle" and task.containerPosition ~= nil then
      world.debugLine(here, task.containerPosition, "red")
      world.debugPoint(task.containerPosition, "red")
      world.debugText("UPCYCLE -> %s", tostring(task.target),
        {task.containerPosition[1], task.containerPosition[2] + 1.5}, "red")
    end
  end

  if stateData.plan ~= nil then
    local from = here
    for index, leg in ipairs(stateData.plan) do
      local colour = (index < stateData.planIndex) and "gray" or "green"
      world.debugLine(from, leg.entry, colour)
      world.debugText("leg %s", index, {leg.entry[1], leg.entry[2] + 2.5}, colour)
      from = leg.destinationPosition
    end
  end

  local walkingTo = (stateData.viaVent and stateData.viaVent.entry)
    or stateData.groundTarget
  if walkingTo ~= nil then
    world.debugLine(here, walkingTo, "white")
    world.debugPoint(walkingTo, "white")
  end

  local finder = self.pather and self.pather.finder
  if finder ~= nil and finder.edges ~= nil then
    for index, edge in ipairs(finder.edges) do
      if edge.source and edge.target then
        local colour = (index == finder.currentEdgeIndex)
          and "white" or actionColour(edge.action)
        world.debugLine(edge.source.position, edge.target.position, colour)
        world.debugPoint(edge.target.position, colour)
      end
    end

    if finder.hasPath and #finder.edges > 0 then
      world.debugText("edge %s of %s",
        tostring(finder.currentEdgeIndex), tostring(#finder.edges),
        {here[1], here[2] + 3}, "white")
    else
      world.debugText("no path (searching)", {here[1], here[2] + 3}, "gray")
    end
  end
end

-- Emotes and tells the port a headpat landed, on a cooldown.
function interact()
  if world.time() - self.lastInteract > config.getParameter("interactCooldown", 3.0) then
    emote("happy")
    self.lastInteract = world.time()

    if self.anchorId ~= nil and world.entityExists(self.anchorId) then
      world.sendEntityMessage(self.anchorId, "petports_headpat")
    end
  end

  return nil
end

PETPORTS_FUEL_PLAIN     = 60
PETPORTS_FUEL_PREFERRED = 120

-- Returns this unit's preferred flavor, rolling one from its seed when it has none.
function petports_unitFlavor()
  local eligible = config.getParameter("petports_fuelFlavors", nil)

  if storage.petportsFlavor ~= nil
     and petports_flavorEligible(storage.petportsFlavor, eligible) then
    return storage.petportsFlavor
  end

  storage.petportsFlavor = petports_preferredFlavor(monster.seed(), eligible)

  sb.logInfo("UNIT rolled preferred flavor %s from seed %s",
    tostring(storage.petportsFlavor), tostring(monster.seed()))

  return storage.petportsFlavor
end

-- Adds fuel for a treat, doubled when it matches the preferred flavor, and returns the amount and flavor.
function petports_feedFuel(descriptor, sparing)
  if type(descriptor) ~= "table" or type(descriptor.name) ~= "string" then
    return nil
  end

  if not root.itemHasTag(descriptor.name, "petports_fuel") then return nil end

  local maximum = status.resourceMax("petports_fuel")
  local current = status.resource("petports_fuel")
  if maximum == nil or current == nil or current >= maximum then return nil end

  local preferred = petports_unitFlavor()
  local amount    = PETPORTS_FUEL_PLAIN
  local eaten     = nil

  for _, flavor in ipairs(petports_flavors()) do
    if root.itemHasTag(descriptor.name, "petports_flavor_" .. flavor.id) then
      eaten = flavor.id
      break
    end
  end

  if eaten == nil and root.itemHasTag(descriptor.name, "petports_flavor_plain") then
    eaten = "plain"
  end

  if preferred ~= nil and eaten == preferred then
    amount = PETPORTS_FUEL_PREFERRED
  end

  if sparing == true and amount > (maximum - current) then
    return nil
  end

  status.modifyResource("petports_fuel", amount)

  if storage.petResources ~= nil then
    storage.petResources.petports_fuel = status.resource("petports_fuel")
  end

  sb.logInfo("UNIT ate %s (%s) for %s fuel (prefers %s), now %s",
    tostring(descriptor.name), tostring(eaten), tostring(amount),
    tostring(preferred), tostring(status.resource("petports_fuel")))

  return { amount = amount, flavor = eaten }
end

-- Sets the fuel level for testing: /entityeval <unitId> petports_setFuel(0)
function petports_setFuel(amount)
	local was = status.resource("petports_fuel")

	status.setResource("petports_fuel", tonumber(amount) or 0)

	if storage.petResources ~= nil then
		storage.petResources.petports_fuel = status.resource("petports_fuel")
	end

	sb.logInfo("UNIT fuel set %s -> %s of %s by entityeval",
		tostring(was), tostring(status.resource("petports_fuel")),
		tostring(status.resourceMax("petports_fuel")))

	return status.resource("petports_fuel")
end
