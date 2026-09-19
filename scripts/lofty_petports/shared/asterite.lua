-- Shared side of asterite mining: the constants both sides read and the world-wide store of known deposits.

PETPORTS_CONSTANTS = PETPORTS_CONSTANTS or {}
PETPORTS_CONSTANTS.asterite = PETPORTS_CONSTANTS.asterite or {}

PETPORTS_CONSTANTS.asterite.mod = "asterite"
PETPORTS_CONSTANTS.asterite.cleared = "petports_cleared"
PETPORTS_CONSTANTS.asterite.storeKey = "petports_asterite"
PETPORTS_CONSTANTS.asterite.cap = 2000

-- Returns the cap on stored asterite deposits.
function petports_asteriteCap()
	return PETPORTS_CONSTANTS.asterite.cap
end

-- Returns every noted asterite deposit.
function petports_asteriteAll()
	return world.getProperty(PETPORTS_CONSTANTS.asterite.storeKey) or {}
end

-- Returns the deposit at a tile key.
function petports_asteriteGet(tileKey)
	return petports_asteriteAll()[tileKey]
end

-- Returns how many deposits are stored.
function petports_asteriteCount()
	local n = 0
	for _ in pairs(petports_asteriteAll()) do n = n + 1 end
	return n
end

-- Notes a deposit at a position, returning whether it was added, the count, and whether the cap stopped it.
function petports_asteriteNote(position, modName, ownerId)
	if type(position) ~= "table" or type(modName) ~= "string" then
		return false, 0, false
	end

	local key = petports_tileKey(position)
	local deposits = petports_asteriteAll()

	local count = 0
	for _ in pairs(deposits) do count = count + 1 end

	if deposits[key] ~= nil then return false, count, false end
	if count >= PETPORTS_CONSTANTS.asterite.cap then return false, count, true end

	deposits[key] = {
		position = { math.floor(position[1]), math.floor(position[2]) },
		mod = modName,
		found = world.time(),
		finder = ownerId
	}

	world.setProperty(PETPORTS_CONSTANTS.asterite.storeKey, deposits)
	return true, count + 1, false
end

-- Drops the deposit at a tile key.
function petports_asteriteClear(tileKey)
	if tileKey == nil then return false end

	local deposits = petports_asteriteAll()
	if deposits[tileKey] == nil then return false end

	deposits[tileKey] = nil
	world.setProperty(PETPORTS_CONSTANTS.asterite.storeKey, deposits)
	return true
end

-- Empties the deposit store and returns how many went.
function petports_asteriteWipe()
	local n = petports_asteriteCount()
	world.setProperty(PETPORTS_CONSTANTS.asterite.storeKey, {})
	sb.logInfo("PETPORTS asterite store WIPED, %s deposit(s) dropped",
		sb.printJson(n))
	return n
end
