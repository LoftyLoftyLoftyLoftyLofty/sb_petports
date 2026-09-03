--  MODULE RULES THE PANE AND THE PORT MUST ANSWER IDENTICALLY.
--
--  WHY THIS FILE EXISTS AT ALL, given that the module machinery already works.
--
--  arch.module.slots earns its safety from one property: the pane performs the
--  swap and the port only commits it, and that is only safe because BOTH SIDES
--  ASK root.itemHasTag ABOUT THE SAME ITEM rather than consulting two
--  hand-written rules. Two predicates that mean to say the same thing are two
--  predicates that can drift, and the failure mode on this path is an item that
--  exists in no inventory.
--
--  "No two modules of the same item" is NOT a root.* query. It is a rule this
--  mod invented, so writing it twice would reintroduce exactly the split that
--  property was protecting. One function, two requires. The pane already loads
--  a shared script from here -- petports_strings.lua -- so the path is proven.
--
--  THE RULE: A UNIT MAY NOT HOLD TWO MODULES OF THE SAME ITEM.
--
--  BLANKET, NOT A PER-ITEM UNIQUENESS FLAG. A flag would have to be authored on
--  every module that wanted it, which means a module that wanted it and did not
--  say so behaves differently from one that did, for no reason a player can
--  see. A blanket rule needs no field, so a module added by anybody gets it for
--  free.
--
--  THIS SUPERSEDES "TWO HYDRATORS ARE ONE HYDRATOR", which arch.module.hydrator
--  records as the honest outcome of moduleFieldUnion deduplicating. It was
--  honest and it was never good: a player who socketed two paid a slot for
--  nothing and the pane told them nothing. Refusing at the slot says so at the
--  moment they try it.
--
--  DEDUPLICATION STAYS. moduleFieldUnion still deduplicates, because this rule
--  guards the SOCKET and the union guards the READ -- a petData written before
--  this shipped, or by anything that is not the pane, can still hold a pair.

--  THE FIRST ITEM NAME HELD BY TWO RECORDS, OR nil.
--
--  TAKES THE WIRE FORMAT, `{ slot = n, item = descriptor }`, because that is
--  what the port receives and what the pane sends. The pane asks about the set
--  it is ABOUT to send rather than about a cursor and a slot, so the two sides
--  are asking one question about one shape of data.
--
--  A RECORD WITH NO USABLE NAME IS SKIPPED, NOT REFUSED. Whether a descriptor
--  is a module at all is petportIsModuleItem's question on the port and the tag
--  check's in the pane; both already refuse. This answers exactly one thing, so
--  that a caller reading `nil` learns "no duplicates" and not "no duplicates,
--  probably, unless the payload was malformed in some other way".
function petports_moduleSetDuplicate(records)
	if type(records) ~= "table" then return nil end

	local seen = {}

	for _, record in ipairs(records) do
		local item = type(record) == "table" and record.item or nil
		local name = type(item) == "table" and item.name or nil

		if type(name) == "string" and name ~= "" then
			if seen[name] then return name end
			seen[name] = true
		end
	end

	return nil
end
