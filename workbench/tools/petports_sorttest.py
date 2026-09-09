#!/usr/bin/env python3
"""Does the mover loop actually finish a container?

NOT a restatement of intent. The container below is a stand-in for the ENGINE --
it holds items at 0-based offsets and knows nothing about the plan -- and the
loop is transliterated line for line from sortContainer, offset arithmetic and
lift guard included. If the loop is wrong, the container disagrees and the final
arrangement is not the sorted one.

Run with --old to reinstate the record.key lift and confirm the test catches it.
"""
import random
import sys

SLOT_KEY_TO_OFFSET = -1
SORT_MOVE_CAP = 64


class Container:
	"""Slots at 0-based offsets. Refuses exactly what the engine refuses."""

	def __init__(self, contents):
		self.slots = dict(contents)  # offset -> (name, count)
		self.takes = 0
		self.puts = 0

	def containerItems(self):
		"""1-based keys, holes where slots are empty -- like the binding."""
		return {off + 1: item for off, item in self.slots.items()}

	def containerTakeNumItemsAt(self, offset, count):
		self.takes += 1
		item = self.slots.get(offset)
		if item is None:
			return None
		assert item[1] == count, "partial takes are not what the sort does"
		del self.slots[offset]
		return item

	def containerPutItemsAt(self, item, offset):
		self.puts += 1
		if offset in self.slots:
			return item  # refused whole; the sort treats this as a failure
		self.slots[offset] = item
		return None


def sort_less(a, b):
	return (a["type"], a["rarity"], a["name"], -a["count"], a["pkey"], a["key"]) \
		< (b["type"], b["rarity"], b["name"], -b["count"], b["pkey"], b["key"])


def sort_plan(items):
	loose = []
	for key in sorted(items):
		name, count = items[key]
		loose.append({
			"key": key,
			"stack": (name, count),
			"name": name,
			"count": count,
			"type": TYPE[name],
			"rarity": RARITY[name],
			"pkey": "",
		})

	import functools
	loose.sort(key=functools.cmp_to_key(
		lambda a, b: -1 if sort_less(a, b) else (1 if sort_less(b, a) else 0)))

	order = loose
	disorder = sum(1 for i, r in enumerate(order, 1) if r["key"] != i)
	return order, disorder


def sort_lift(box, record, key):
	offset = key + SLOT_KEY_TO_OFFSET
	taken = box.containerTakeNumItemsAt(offset, record["stack"][1])

	if taken is None or taken[1] < 1:
		return None

	if taken[0] != record["stack"][0]:
		print("    LIFT REFUSED: slot key %s held %s, not the %s the plan expected"
			% (key, taken[0], record["stack"][0]))
		return None

	return taken


def sort_lay(box, stack, key):
	offset = key + SLOT_KEY_TO_OFFSET
	leftover = box.containerPutItemsAt(stack, offset)
	if leftover is not None:
		print("    LAY REFUSED at slot key %s" % key)
		return False
	return True


def sort_container(box, use_original_key):
	items = box.containerItems()
	order, disorder = sort_plan(items)

	at, where = {}, {}
	for record in order:
		at[record["key"]] = record
		where[id(record)] = record["key"]

	moved, aborted = 0, None

	for target in range(1, len(order) + 1):
		if moved >= SORT_MOVE_CAP:
			break

		record = order[target - 1]
		source = where[id(record)]

		if source != target:
			liftFrom = record["key"] if use_original_key else source
			hand = sort_lift(box, record, liftFrom)

			if hand is None:
				aborted = "lift refused"
				break

			evicted = at.get(target)
			carried = None

			if evicted is not None:
				evictFrom = evicted["key"] if use_original_key else target
				carried = sort_lift(box, evicted, evictFrom)

				if carried is None:
					sort_lay(box, hand, source)
					aborted = "second lift refused"
					break

			if not sort_lay(box, hand, target):
				if carried is not None:
					sort_lay(box, carried, source)
				aborted = "destination refused"
				break

			at[target] = record
			where[id(record)] = target
			at.pop(source, None)

			if carried is not None:
				if not sort_lay(box, carried, source):
					aborted = "return refused"
					break
				at[source] = evicted
				where[id(evicted)] = source

			moved += 1

	return order, disorder, moved, aborted


# ---------------------------------------------------------------------------

NAMES = ["dirtmaterial", "cobblestonematerial", "copperbar", "ironbar",
	"milk", "cotton", "banana", "sb_musicsheet", "commonshortsword",
	"woodenchair", "silkfibre", "money"]

TYPE = {n: (3 if n.endswith("material") else 1) for n in NAMES}
TYPE["commonshortsword"] = 24
TYPE["woodenchair"] = 4
TYPE["money"] = 5
RARITY = {n: 5 for n in NAMES}
RARITY["commonshortsword"] = 3

use_original_key = "--old" in sys.argv
print("lifting from %s\n" % ("record.key (the 'r' build)" if use_original_key
	else "where[record] (the 's' build)"))

random.seed(20260908)
failures = 0

for trial in range(1, 41):
	size = random.randint(8, 40)
	occupied = random.sample(range(size), random.randint(4, size))
	contents = {off: (random.choice(NAMES), random.randint(1, 900))
		for off in occupied}

	box = Container(contents)
	before = sorted((n, c) for n, c in box.slots.values())

	trips = 0
	while trips < 12:
		trips += 1
		order, disorder, moved, aborted = sort_container(box, use_original_key)
		if disorder < 2:
			break
		if moved == 0 and aborted is not None:
			break

	items = box.containerItems()
	order, disorder = sort_plan(items)
	after = sorted((n, c) for n, c in box.slots.values())

	dense = sorted(items) == list(range(1, len(items) + 1))
	ok = disorder == 0 and dense and before == after

	if not ok or trial <= 3 or trips > 1:
		print("trial %2d: %2d stacks in %2d slots -- %d trip(s), "
			"final disorder %d, dense %s, contents intact %s%s"
			% (trial, len(before), size, trips, disorder, dense,
				before == after, "" if ok else "   <-- FAIL"))

	if not ok:
		failures += 1

print("\n%d/40 containers fully sorted, holes closed, nothing lost"
	% (40 - failures))
sys.exit(1 if failures else 0)
