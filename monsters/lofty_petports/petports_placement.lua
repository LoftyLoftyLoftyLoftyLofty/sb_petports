-- Finds and validates positions for a unit to stand or rest on.

require "/scripts/util.lua"
require "/scripts/vec2.lua"
require "/scripts/rect.lua"
require "/scripts/pathutil.lua"


local PERCH_TAG = "petports_perch"

local PERCH_OFFSET_PARAM = "petports_perchOffset"

local AVOID_TAGS = {
  ["avoidMe"] = true,
  ["avoidMe-goLeft"] = true,
  ["avoidMe-goRight"] = true
}

local AVOID_CLEARANCE = 4

local PLAYER_CLEARANCE = 3


-- Returns an object's itemTags, or nil.
local function tagsOf(entityId)
  local ok, tags = pcall(world.getObjectParameter, entityId, "itemTags")
  if ok then return tags end
  return nil
end

-- Returns true when an object carries a tag.
local function hasTag(entityId, tag)
  local tags = tagsOf(entityId)
  if tags == nil then return false end
  for _, t in ipairs(tags) do
    if t == tag then return true end
  end
  return false
end

-- Returns true when an object is tagged as a perch.
local function isPerch(entityId)
  return hasTag(entityId, PERCH_TAG)
end

-- Returns true when an object carries one of the avoidance tags.
local function isAvoidMarker(entityId)
  local tags = tagsOf(entityId)
  if tags == nil then return false end
  for _, t in ipairs(tags) do
    if AVOID_TAGS[t] then return true end
  end
  return false
end

-- Returns the unit's bound box translated to a position.
local function footprintAt(position)
  local bounds = mcontroller.boundBox()
  return rect.translate(bounds, position)
end

-- Returns true when a footprint covers any space an object occupies.
local function overlapsObject(footprint, objectId)
  local ok, spaces = pcall(world.objectSpaces, objectId)
  if not ok or spaces == nil then return false end

  local origin = world.entityPosition(objectId)
  if origin == nil then return false end

  for _, space in ipairs(spaces) do
    local tile = {
      math.floor(origin[1]) + space[1],
      math.floor(origin[2]) + space[2]
    }
    if footprint[1] < tile[1] + 1 and footprint[3] > tile[1]
       and footprint[2] < tile[2] + 1 and footprint[4] > tile[2] then
      return true
    end
  end
  return false
end


-- Returns an object's position shifted by its petports_perchOffset.
function petports_perchPosition(objectId)
  local position = world.entityPosition(objectId)
  if position == nil then return nil end

  local ok, offset = pcall(world.getObjectParameter, objectId, PERCH_OFFSET_PARAM, {0, 0})
  if not ok or offset == nil then offset = {0, 0} end

  return {position[1] + offset[1], position[2] + offset[2]}
end

-- Returns whether a position is standable and clear of objects, avoidance markers and players, with the reason when it is not.
function petports_canRestAt(position, options)
  options = options or {}
  if position == nil then return false, "no position" end

  if not validStandingPosition(position) then
    return false, "not standable"
  end

  local footprint = footprintAt(position)
  local radius = options.searchRadius or 8

  local nearby = world.entityQuery(position, radius, {
    includedTypes = { "object" },
    withoutEntityId = entity.id()
  })

  for _, objectId in ipairs(nearby or {}) do
    if objectId ~= options.ignoreEntityId then
      if isAvoidMarker(objectId) then
        local markerPosition = world.entityPosition(objectId)
        if markerPosition and world.magnitude(markerPosition, position) < AVOID_CLEARANCE then
          return false, "inside an avoidance marker"
        end
      elseif not isPerch(objectId) then
        if overlapsObject(footprint, objectId) then
          return false, "on top of an object"
        end
      end
    end
  end

  if not options.ignorePlayers then
    local players = world.entityQuery(position, PLAYER_CLEARANCE, {
      includedTypes = { "player" }
    })
    if players and #players > 0 then
      return false, "too close to a player"
    end
  end

  return true
end

-- Returns a position moved to the horizontal centre of its tile.
local function tileCentre(position)
  return { math.floor(position[1]) + 0.5, position[2] }
end

-- Returns the nearest restable ground position within an offset, or nil.
function petports_findRestPosition(position, maxOffset, options)
  maxOffset = maxOffset or 6

  if petports_canRestAt(position, options) then
    return position
  end

  for offset = 0, maxOffset do
    local directions = (offset == 0) and {0} or {1, -1}

    for _, direction in ipairs(directions) do
      local candidate = findGroundPosition(
        {position[1] + direction * offset, position[2]}, -4, 4,
        petports_avoidLiquid())

      if candidate then
        candidate = tileCentre(candidate)
        if petports_canRestAt(candidate, options) then
          return candidate
        end
      end
    end
  end

  return nil
end

-- Moves the unit onto the nearest rest position and returns whether one was found.
function petports_settleAt(position, options)
  local resting = petports_findRestPosition(position, 6, options)
  if resting == nil then return false end

  local bounds = mcontroller.boundBox()
  mcontroller.setPosition({resting[1], resting[2] - bounds[2]})
  return true
end
