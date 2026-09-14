require "/scripts/rect.lua"
require "/scripts/util.lua"
require "/scripts/vec2.lua"

PETPORTS_VANILLA_SPAWNER_CONFIG = "/scripts/fishing/fishingspawner.config"

function PetportsFishingSpawner()
  local spawner = {}

  local vanillaConfig = nil
  local zoneConfig = nil
  local lureType = nil
  local spawnBias = 0

  local biasOverride = nil

  local function initialBias()
    if biasOverride ~= nil then return biasOverride end
    local source = zoneConfig or vanillaConfig
    return (source and source.initialBias) or 0
  end

  local function vanilla()
    if vanillaConfig == nil then
      local ok, data = pcall(root.assetJson, PETPORTS_VANILLA_SPAWNER_CONFIG)
      vanillaConfig = (ok and type(data) == "table") and data or false
    end
    return vanillaConfig or nil
  end

  local function geometry()
    local zone = zoneConfig
    local base = vanilla()

    return {
      distanceRange = (zone and zone.distanceRange) or (base and base.distanceRange) or {8, 14},
      checkRegion = (zone and zone.checkRegion) or (base and base.checkRegion) or {-3, -2, 3, 2},
      liquidThreshold = (zone and zone.liquidThreshold) or (base and base.liquidThreshold) or 0.9,
      biasDropPerSpawn = (zone and zone.biasDropPerSpawn)
        or (base and base.biasDropPerSpawn) or 0.1,
      dayRange = (zone and zone.dayRange) or (base and base.dayRange) or {0, 0.5},
      nightRange = (zone and zone.nightRange) or (base and base.nightRange) or {0.5, 1.0}
    }
  end

  local function spawnPositionNear(pos)
    local geo = geometry()
    if not world.liquidAt(pos) then return nil end

    for _ = 1, 10 do
      local candidate = vec2.add(pos, vec2.withAngle(
        math.random() * 2 * math.pi, util.randomInRange(geo.distanceRange)))

      local backgroundOk = zoneConfig ~= nil
        or not world.material(candidate, "background")

      if world.liquidAt(candidate) and backgroundOk
         and not world.lineTileCollision(pos, candidate) then

        local region = rect.translate(geo.checkRegion, candidate)
        if not world.rectCollision(region) then
          local liquid = world.liquidAt(region)
          if liquid and liquid[2] >= geo.liquidThreshold then
            return candidate
          end
        end
      end
    end

    return nil
  end

  local function isDay(geo)
    local t = world.timeOfDay()
    return t >= geo.dayRange[1] and t <= geo.dayRange[2]
  end

  local function isNight(geo)
    local t = world.timeOfDay()
    return t >= geo.nightRange[1] and t <= geo.nightRange[2]
  end

  local function pickFromTiers(rarities, tiers, geo, extraFilter)
    local day, night = isDay(geo), isNight(geo)
    local roll = math.random() + spawnBias

    for _, rarity in ipairs(rarities) do
      if roll <= rarity[1] then
        local pool = tiers[rarity[2]]

        if type(pool) == "table" and #pool > 0 then
          shuffle(pool)

          for _, entry in ipairs(pool) do
            local timeOk = (day and entry.day) or (night and entry.night)
            if timeOk and (extraFilter == nil or extraFilter(entry)) then
              return entry.monster, rarity[2]
            end
          end
        end
      end
    end

    return nil
  end

  local function zoneSpawnType(pos, geo)
    local liquidHere = world.liquidAt(pos)
    if not liquidHere then return nil end

    for _, entry in ipairs(zoneConfig.liquidIds or {}) do
      if tostring(liquidHere[1]) == tostring(entry.liquidId) then
        for _, lure in ipairs(entry.eligibleLureTypes or {}) do
          if lureType == lure.lureType then
            local picked, rarity = pickFromTiers(
              lure.rarities or {}, lure.availableFish or {}, geo, nil)
            if picked then return picked, rarity end
          end
        end
      end
    end

    return nil
  end

  local function vanillaSpawnType(pos, geo)
    local cfg = vanilla()
    if cfg == nil then return nil end

    local depth = world.oceanLevel(pos) - pos[2]
    if depth < (cfg.minDepth or 8) then return nil end

    local shallow, deep
    if depth >= (cfg.deepDepth or 25) then
      shallow, deep = false, true
    else
      shallow, deep = true, false
    end

    local pools = cfg.pools[world.type()]
    if pools == nil then return nil end

    return pickFromTiers(cfg.rarities or {}, pools, geo, function(entry)
      return (shallow and entry.shallow) or (deep and entry.deep)
    end)
  end

  function spawner.getSpawn(pos)
    local position = spawnPositionNear(pos)
    if position == nil then return nil end

    local geo = geometry()
    local kind, rarity
    if zoneConfig ~= nil then
      kind, rarity = zoneSpawnType(position, geo)
    else
      kind, rarity = vanillaSpawnType(position, geo)
    end

    if kind == nil then return nil end

    spawnBias = math.max(0, spawnBias - geo.biasDropPerSpawn)
    return kind, position, rarity
  end

  function spawner.reset()
    spawnBias = initialBias()
  end

  function spawner.setParams(params)
    if type(params) ~= "table" then return false end
    zoneConfig = params
    spawner.reset()
    return true
  end

  function spawner.setLureType(kind)
    lureType = kind
  end

  function spawner.setBias(value)
    biasOverride = value
    spawner.reset()
  end

  function spawner.mode()
    return zoneConfig ~= nil and "zone" or "vanilla"
  end

  function spawner.bias()
    return spawnBias
  end

  spawner.reset()
  return spawner
end
