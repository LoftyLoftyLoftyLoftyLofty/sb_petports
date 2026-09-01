--  PETPORTS -- FISHING SPAWNER
--
--  A MERGE OF TWO FORKS, NOT A COPY OF EITHER.
--
--      /scripts/fishing/fishingspawner.lua                  vanilla
--      /scripts/fishing/lofty_irisil_fancyfishingspawner.lua  Project Irisil
--
--  Vanilla picks fish by BIOME: world.type() must have a pool, the position must
--  be at least minDepth below the ocean level, and the pool is split by
--  shallow/deep and day/night. Irisil's picks by LIQUID ID and lure type, from
--  parameters a fishing-zone stagehand pushes into the lure, and has no biome or
--  depth test at all.
--
--  THIS DOES BOTH, AND STARTS IN VANILLA MODE. Zone parameters arrive by message
--  or they never arrive; a lure in open ocean must work either way. setParams
--  switches it, and nothing switches it back -- a lure that has been told about a
--  zone is in that zone.
--
--  WHY BOTH RATHER THAN PICKING ONE
--
--  Vanilla alone means fishing works ONLY on ocean, toxic, arctic and magma
--  worlds. A player's base pond on a forest world is unfishable no matter how
--  deep they dig it, because world.type() decides before position is consulted.
--  For a base-automation mod that is a severe restriction.
--
--  Irisil alone means fishing works ONLY inside a hand-placed dungeon zone,
--  which is correct for a content mod shipping those dungeons and useless for a
--  port dropped in the open sea.
--
--  NO DEPENDENCY IN EITHER DIRECTION. This file reads vanilla's config for its
--  own mode and accepts a zone table for the other; it never requires Irisil's
--  files and never calls into them. If Irisil is installed its zones will push
--  parameters at our lure because they broadcast to every projectile in range --
--  we do not go looking for them, they find us. If it is not installed, nothing
--  ever calls setParams and this is vanilla's spawner with a bias knob.
--
--  THE GLOBAL IS NAMED PetportsFishingSpawner ON PURPOSE. Vanilla and Irisil
--  BOTH define `FishingSpawner`, so they already collide with each other -- the
--  last file required wins, silently. Adding a third would make that worse and
--  would break rod fishing for anyone running both mods.

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

  --  THE BIAS OVERRIDE, AND THE REASON THIS FORK EXISTS AT ALL.
  --
  --  Both upstream spawners seed spawnBias from their config's initialBias, 0.2
  --  in vanilla's, and drop it by biasDropPerSpawn on each SUCCESSFUL spawn. The
  --  roll is `math.random() + spawnBias` tested against 0.001 / 0.04 / 0.2 / 100,
  --  so at bias 0.2 the roll can never fall to or below 0.2 and legendary, rare
  --  and uncommon are not improbable -- they are UNREACHABLE.
  --
  --  THAT IS FINE FOR A ROD AND WRONG FOR A PORT. A player casts repeatedly and
  --  burns the bias off in two catches. A petport lure lives two and a half
  --  minutes, holds one fish at a time, and is replaced by a fresh lure with a
  --  fresh spawner afterwards -- so it would reset the bias faster than it could
  --  ever decay it, and could never produce anything above common.
  --
  --  nil MEANS "USE THE CONFIG'S", so a caller that does not care gets upstream
  --  behaviour. The lure passes 0.
  local biasOverride = nil

  local function initialBias()
    if biasOverride ~= nil then return biasOverride end
    local source = zoneConfig or vanillaConfig
    return (source and source.initialBias) or 0
  end

  --  Vanilla's config is loaded once, lazily, and kept even in zone mode: a zone
  --  table is not required to carry distanceRange, checkRegion or
  --  liquidThreshold, and falling back to vanilla's numbers for those is better
  --  than inventing a second set.
  local function vanilla()
    if vanillaConfig == nil then
      local ok, data = pcall(root.assetJson, PETPORTS_VANILLA_SPAWNER_CONFIG)
      vanillaConfig = (ok and type(data) == "table") and data or false
    end
    return vanillaConfig or nil
  end

  --  Whichever config governs the SEARCH GEOMETRY -- how far out to look, how
  --  much clearance a spawn point needs, how full the liquid must be. Separate
  --  from the question of which fish, which is mode-specific below.
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

  --  WHERE A FISH COULD APPEAR NEAR `pos`.
  --
  --  Vanilla's spawnPositionNear, with ONE difference taken from Irisil's fork:
  --  the background-material test is applied only in vanilla mode. Vanilla
  --  refuses a spawn point that sits in front of background blocks, which keeps
  --  fish out of the walls of a player's build in open water. A hand-placed
  --  dungeon pool is background-walled BY CONSTRUCTION, so applying it in zone
  --  mode would refuse every position in the zone -- which is exactly why Irisil
  --  dropped the test rather than because it is wrong.
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

  --  Shared by both modes: roll a rarity, then take the first entry in that
  --  tier whose day/night flags admit the current time.
  --
  --  THE SHUFFLE IS UPSTREAM'S AND IS LOAD-BEARING. Without it the first
  --  eligible entry in a tier wins every time and the rest of the tier never
  --  appears at all.
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
              --  THE TIER NAME COMES BACK WITH THE FISH. It is knowable only
              --  here -- nothing downstream can recover "rare" from a monster
              --  type without re-deriving the whole table -- and the port wants
              --  it for per-rarity catch statistics.
              return entry.monster, rarity[2]
            end
          end
        end
      end
    end

    return nil
  end

  --  ZONE MODE: liquid id, then lure type, then rarity. No biome, no depth.
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

  --  VANILLA MODE: biome pool, depth band, shallow/deep, day/night.
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

  --  Called by a fishing-zone stagehand's broadcast. Switches this spawner to
  --  zone mode permanently -- see the header on why nothing switches it back.
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

  --  For logging: which mode is live, without exposing the tables.
  function spawner.mode()
    return zoneConfig ~= nil and "zone" or "vanilla"
  end

  function spawner.bias()
    return spawnBias
  end

  spawner.reset()
  return spawner
end
