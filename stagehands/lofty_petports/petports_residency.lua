require "/scripts/util.lua"
require "/scripts/lofty_petports/petports_work.lua"


function init()
  local wantedId = config.getParameter("residencyUniqueId")
  if wantedId and stagehand.setUniqueId then
    stagehand.setUniqueId(wantedId)
  end

  self.coverageSize = config.getParameter("coverageSize", 64)
  self.portUniqueId = config.getParameter("portUniqueId")
  self.orphanGrace = config.getParameter("orphanGrace", 15.0)

  self.rect = petports_coverageRect(stagehand.position(), self.coverageSize)

  self.orphanTimer = self.orphanGrace
  self.checkTimer = 0

  message.setHandler("petports_residencyStop", function()
    sb.logInfo("PETPORTS residency %s stopping: told to by its port",
      tostring(self.portUniqueId))
    stagehand.die()
  end)

  sb.logInfo("PETPORTS residency up for port %s over %s",
    tostring(self.portUniqueId), sb.printJson(self.rect))
end

local function portPresent()
  if self.portUniqueId == nil then
    return false
  end

  local portId = world.loadUniqueEntity(self.portUniqueId)
  return portId ~= nil and world.entityExists(portId)
end

function update(dt)
  world.loadRegion(self.rect)

  self.checkTimer = self.checkTimer - dt
  if self.checkTimer > 0 then return end
  self.checkTimer = 1.0

  if portPresent() then
    self.orphanTimer = self.orphanGrace
    return
  end

  self.orphanTimer = self.orphanTimer - 1.0
  if self.orphanTimer <= 0 then
    sb.logInfo("PETPORTS residency %s stopping: port not found for %s seconds",
      tostring(self.portUniqueId), sb.printJson(self.orphanGrace))
    stagehand.die()
  end
end
