require "/scripts/util.lua"
require "/scripts/lofty_petports/petports_work.lua"

--  PETPORTS -- RESIDENCY STAGEHAND
--
--  One of these per petport. Keeps that port's coverage rect resident, and
--  removes itself when the port is gone.
--
--  LIFETIME IS OWNED BY THE PETPORT, with this as a backstop.
--
--  The port kills this from its die() callback -- destruction only, NOT uninit,
--  which also fires on world unload and would orphan every port's stagehand on
--  the next reload. But die() is not guaranteed to reach us (the port may be
--  removed by something that does not run it, or the message may not land), so
--  this also watches for its own port and terminates if it stays missing.
--
--  Belt and braces on purpose: an orphaned keepAlive stagehand is INVISIBLE and
--  CUMULATIVE. It has no sprite, holds a region resident forever, and the only
--  symptom is a world that gets progressively more expensive. That is the worst
--  failure mode available here, so it gets two independent guards.

function init()
  --  Set our own uniqueId if the spawn override did not take. UNVERIFIED which
  --  of the two mechanisms actually works; doing both is harmless, and without
  --  an id the petport can never find us again and would spawn a replacement.
  local wantedId = config.getParameter("residencyUniqueId")
  if wantedId and stagehand.setUniqueId then
    stagehand.setUniqueId(wantedId)
  end

  self.coverageSize = config.getParameter("coverageSize", 32)
  self.portUniqueId = config.getParameter("portUniqueId")
  self.orphanGrace = config.getParameter("orphanGrace", 15.0)

  --  Rect is computed ONCE from our own position. The stagehand is spawned at
  --  the port's position and neither moves, so this never needs recomputing.
  --
  --  This is the VISUAL rect. Sectors load whole, so more chunk than this ends
  --  up resident -- acceptable in that direction only, and the drawn rect stays
  --  authoritative for what work may be claimed.
  self.rect = petports_coverageRect(stagehand.position(), self.coverageSize)

  self.orphanTimer = self.orphanGrace
  self.checkTimer = 0

  --  Explicit shutdown from the port.
  message.setHandler("petports_residencyStop", function()
    sb.logInfo("PETPORTS residency %s stopping: told to by its port",
      tostring(self.portUniqueId))
    stagehand.die()
  end)

  sb.logInfo("PETPORTS residency up for port %s over %s",
    tostring(self.portUniqueId), sb.printJson(self.rect))
end

--  Is our petport still there?
--
--  Deliberately checked by uniqueId rather than by scanning for an object at a
--  position: a port that was mined and replaced is a DIFFERENT port with its
--  own stagehand, and this one should retire rather than adopt it.
local function portPresent()
  if self.portUniqueId == nil then
    --  Spawned without an owner. Nothing can ever claim it, so do not linger.
    return false
  end

  local portId = world.loadUniqueEntity(self.portUniqueId)
  return portId ~= nil and world.entityExists(portId)
end

function update(dt)
  --  EVERY update, not once. Residency is a continuous assertion -- vanilla's
  --  mission manager does the same thing for the same reason.
  world.loadRegion(self.rect)

  --  Orphan watch, on a slow timer. The region call above is what brings the
  --  port back into memory, so this cannot run before it.
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
