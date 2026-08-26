#!/usr/bin/env python3
"""
petports_fooddump -- produce, cooked food and crafting materials, with sinks.

Sibling to petports_tagdump.py and run the same way: drop it anywhere inside
(or beside) an UNPACKED Starbound assets folder.

    python petports_fooddump.py                  scan from here
    python petports_fooddump.py path/to/assets   scan somewhere else
    python petports_fooddump.py --all            every category, not just food
                                                 and crafting materials
    python petports_fooddump.py --categories cookingIngredient,fuel
                                                 just these, comma separated
    python petports_fooddump.py --orphans        only items nothing crafts with
    python petports_fooddump.py --max-consumers 1
                                                 trim to items with at most one
                                                 recipe consuming them

Writes petports_fooddump.tsv and petports_fooddump.txt beside itself. The .tsv
is the one to hand over; the .txt is the summary worth reading first.

WHY THIS EXISTS
---------------
The flavour profiles need every accumulating material assigned to a reagent
class, and "accumulating" has been an eyeball judgement so far. It does not
have to be.

A material accumulates when the game hands it to you and nothing takes it
back. That is countable: scan every .recipe, tally how often each item name
appears as an INPUT, and the items sitting at zero are the tail the flavour
system exists to absorb. Scorched cores and cryonic extracts should come out
near the top of that list; iron ore should not, because half the crafting tree
eats it.

Producers are counted too, because the pair is what discriminates. Zero
consumers and zero producers is usually a drop or a reward -- exactly the
shape we want. Zero consumers and many producers is something the player is
being handed deliberately and repeatedly, which is the same shape, louder.

WHAT IT DOES NOT DO
-------------------
It reads authored files only, the same as tagdump, so a build script's runtime
invention is invisible here -- which is fine, because petports_itemFacts
cannot see those either.

It also does not know about non-recipe sinks: quest turn-ins, upgrade module
costs, fuel for the ship, tenant requests. An item with zero recipe consumers
may still have somewhere to go. Read the count as a strong hint, not a verdict.
"""

import json
import os
import re
import sys
from collections import Counter, defaultdict

#  Extensions that can carry an item definition we care about. Deliberately
#  narrower than tagdump's list: this pass is about things that pile up in a
#  crate, so armour, weapons and tools are out.
#
#  RUN tagdump --extensions AGAINST ANY TREE FIRST. An extension that does not
#  exist scans as zero files and looks exactly like a category nothing uses.
ITEM_EXTS = (
    ".item",            # craftingMaterial: ores, bars, cores, extracts
    ".consumable",      # food, preparedFood, drink, medicine -- and seeds
    ".matitem",         # blocks in item form
    ".liqitem",         # liquids in item form
    ".object",          # farmables live here; harmless otherwise
)

RECIPE_EXT = ".recipe"

#  Compared case-INSENSITIVELY, because vanilla uses both cases for the same
#  category and claiming only one silently loses items. tagdump measured
#  Tool/tool, Junk/junk and Other/other all live simultaneously.
DEFAULT_CATEGORIES = {
    "craftingmaterial",
    "food",
    "preparedfood",
    "drink",
    "medicine",
    "seed",
    #  ADDED AFTER THE FIRST RUN CAME BACK MISSING THINGS. Mushroom, sugarcane,
    #  wheat, rice and cocoa all have a seed and a cooked form in the six
    #  categories above and NO produce item, which means their produce uses a
    #  category the filter was excluding. These two are the likely homes;
    #  the excluded-category census in the .txt is what confirms it either way.
    "other",
    "junk",
}

SKIP_DIRS = {".git", "_metadata", "previews", "user"}


def strip_comments(text):
    """Starbound's parser accepts // comments in JSON. Python's does not.

    Only strips // outside a string, so "/interface/x.png" survives.
    """
    out, i, n, in_str = [], 0, len(text), False
    while i < n:
        c = text[i]
        if in_str:
            if c == "\\":
                out.append(text[i:i + 2]); i += 2; continue
            if c == '"':
                in_str = False
            out.append(c); i += 1; continue
        if c == '"':
            in_str = True; out.append(c); i += 1; continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i)
            i = n if j < 0 else j + 2
            continue
        out.append(c); i += 1
    return "".join(out)


def load(path):
    """Best effort. A file that will not parse is reported, never fatal."""
    try:
        raw = open(path, "rb").read().decode("utf-8-sig", errors="replace")
    except OSError as err:
        return None, str(err)
    #  strict=False IS LOAD BEARING. Vanilla puts raw control characters inside
    #  strings freely and Python's default rejects them -- tagdump lost 111 of
    #  123 codex files to this before it was set, and the symptom was a whole
    #  category appearing not to exist rather than a read failure.
    try:
        return json.loads(strip_comments(raw), strict=False), None
    except ValueError as err:
        # Trailing commas are common in hand-edited mod files.
        try:
            return json.loads(re.sub(r",(\s*[}\]])", r"\1", strip_comments(raw)),
                              strict=False), None
        except ValueError:
            return None, str(err)


def recipe_names(entry):
    """An item reference inside a recipe, as a name.

    Recipes name items under "item" in their input list and under "item" again
    in the output object, but a bare string turns up too. Handle both rather
    than assuming, since a miss here undercounts a sink and pushes an item into
    the orphan list it does not belong in.
    """
    if isinstance(entry, str):
        return entry
    if isinstance(entry, dict):
        for key in ("item", "name", "itemName"):
            value = entry.get(key)
            if isinstance(value, str):
                return value
    return None


def scan_recipes(root):
    consumers = Counter()
    producers = Counter()
    consumed_by = defaultdict(list)
    seen = 0
    bad = []

    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if not name.lower().endswith(RECIPE_EXT):
                continue
            path = os.path.join(dirpath, name)
            data, err = load(path)
            if data is None:
                bad.append((os.path.relpath(path, root), err))
                continue
            if not isinstance(data, dict):
                continue

            seen += 1
            output = recipe_names(data.get("output"))

            inputs = data.get("input")
            if isinstance(inputs, list):
                for entry in inputs:
                    item = recipe_names(entry)
                    if item is None:
                        continue
                    consumers[item] += 1
                    if output and len(consumed_by[item]) < 4:
                        consumed_by[item].append(output)

            if output:
                producers[output] += 1

    return consumers, producers, consumed_by, seen, bad


def scan_items(root, categories):
    rows = []
    bad = []
    seen = 0
    own = {}
    excluded = Counter()

    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if not name.lower().endswith(ITEM_EXTS):
                continue
            path = os.path.join(dirpath, name)
            data, err = load(path)
            if data is None:
                bad.append((os.path.relpath(path, root), err))
                continue
            if not isinstance(data, dict):
                continue

            seen += 1
            ident = (data.get("itemName") or data.get("objectName")
                     or os.path.splitext(name)[0])

            cat = data.get("category")
            cat = cat if isinstance(cat, str) else ""

            if categories is not None and cat.lower() not in categories:
                excluded[cat or "(none)"] += 1
                continue

            tags = data.get("itemTags")
            tags = [t for t in tags if isinstance(t, str)] if isinstance(tags, list) else []

            #  foodValue is the vanilla nutrition number. Recorded because it is
            #  the closest thing vanilla has to an existing per-item fuel value,
            #  and worth being able to compare against price before committing
            #  to price as the only axis.
            food = data.get("foodValue")

            #  path -> the item name this file DEFINES, so the reference scan can
            #  drop self-hits without dropping the file.
            own[os.path.abspath(path)] = ident

            rows.append({
                "name": ident,
                "short": data.get("shortdescription") or "",
                "category": cat,
                "ext": os.path.splitext(name)[1],
                "price": data.get("price"),
                "rarity": data.get("rarity") or "",
                "maxstack": data.get("maxStack"),
                "food": food,
                "tags": " ".join(sorted(tags)),
            })

    return rows, seen, bad, own, excluded


#  Text extensions worth searching for a mention of an item name. Deliberately
#  a list rather than "everything that is not a PNG": an unpacked tree is mostly
#  images and audio, and reading those is the difference between a scan that
#  takes a minute and one that takes twenty.
#
#  RUN tagdump --extensions AGAINST YOUR TREE if a subsystem looks suspiciously
#  quiet. An extension missing from this list contributes zero references, which
#  is indistinguishable from an item genuinely having none -- the exact failure
#  shape that made five manifest tags look real for weeks.
REF_EXTS = (
    ".activeitem", ".aimission", ".animation", ".augment", ".beamaxe",
    ".behavior", ".biome", ".chest", ".codex", ".collection", ".config",
    ".consumable", ".currency", ".dance", ".damage", ".dungeon", ".effectsource",
    ".flashlight", ".frames", ".harvestingtool", ".head", ".inspectiontool",
    ".instrument", ".item", ".json", ".legs", ".liqitem", ".liquid", ".lua",
    ".macro", ".material", ".matitem", ".matmod", ".miningtool", ".modularmech",
    ".monstertype", ".monsterpart", ".monsterskill", ".npctype", ".object",
    ".painttool", ".particle", ".patch", ".player", ".projectile", ".questtemplate",
    ".radiomessages", ".recipe", ".species", ".stagehand", ".statuseffect",
    ".techitem", ".tech", ".terrestrial", ".thrownitem", ".tillingtool",
    ".treasurepools", ".unlock", ".vehicle", ".weaponability", ".wiretool",
)

#  A quoted string in a Starbound asset. Item names appear as JSON values and as
#  keys, always quoted, so this is the whole vocabulary of a file in one pass --
#  which is what makes scanning the tree once rather than once per name viable.
QUOTED = re.compile(r'"([A-Za-z0-9_\-]{2,64})"')


def scan_references(root, names, own_files):
    """How many files MENTION each item name, and which subsystems they are.

    WHY THIS IS THE DEPRECATION TEST. Vanilla is full of items that still have
    a definition file and no way to obtain them -- the ship-fuel ores after
    Erchius replaced them, half the robot parts, a scattering of novelties. They
    look identical to live items from the item file alone.

    What separates them is whether anything else in the game refers to them. A
    live item is named by a treasure pool, a monster's drops, a biome, a quest,
    a shop or a recipe. A dead one is named by nothing but itself.

    READ A ZERO AS "NOTHING HANDS THIS TO A PLAYER", NOT AS "THIS DOES NOT
    EXIST". An item can also arrive through a build script or a generated pool
    that names it indirectly, and this cannot see either. It is a strong signal
    and the start of a conversation, not a verdict.

    A FILE IS EXCLUDED FROM ITS OWN COUNT, NOT FROM THE SCAN, AND THE DIFFERENCE
    IS A BUG THAT SHIPPED. The first version skipped every reported item file
    wholesale. Under the default filter that was harmless, because almost no
    .object was in the report. Under --all every .object IS, so every reference
    an object made to an item stopped being counted -- and objects are one of
    the main ways the game hands things over, through breakable drop pools and
    farmable produce.

    Measured, same tree, two runs: `bone` went 53 references to 29, losing
    `objects:24` outright. Ember Coral Fragment and Bug Shell went to ZERO, both
    having been object-sourced entirely. Two live items read as deprecated
    because of the report's own filter setting, which is the precise failure
    this scan exists to prevent.

    So the self-exclusion is now per NAME rather than per FILE: bonechair.object
    still counts as a reference to `bone`, and does not count as a reference to
    `bonechair`.
    """
    refs = Counter()
    where = defaultdict(Counter)
    files = 0

    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]

        rel = os.path.relpath(dirpath, root).replace("\\", "/")
        bucket = rel.split("/")[0] if rel != "." else "(root)"

        for name in filenames:
            if not name.lower().endswith(REF_EXTS):
                continue
            path = os.path.join(dirpath, name)

            try:
                raw = open(path, "rb").read().decode("utf-8-sig", errors="replace")
            except OSError:
                continue

            files += 1

            #  Set, not list: a treasure pool naming an item four times is one
            #  file that hands it over, not four.
            hits = {m for m in QUOTED.findall(raw) if m in names}

            #  An item's own definition is not a reference to itself. Discarding
            #  the one name rather than the whole file -- see the docstring.
            hits.discard(own_files.get(os.path.abspath(path)))

            for hit in hits:
                refs[hit] += 1
                where[hit][bucket] += 1

    return refs, where, files


def flatten(value):
    """A cell for the TSV. Never emits a tab or a newline."""
    if value is None:
        return ""
    text = str(value)
    return text.replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()


def main(argv):
    #  A flag that takes a VALUE means the value is not a path. Without this,
    #  `--categories fuel` scanned a folder called "fuel", found nothing, and
    #  reported zero items -- which reads exactly like a category nothing uses.
    VALUED = {"--max-consumers", "--categories"}

    args, flags, skip = [], [], False
    for i, a in enumerate(argv[1:]):
        if skip:
            skip = False
            continue
        if a.startswith("--"):
            flags.append(a)
            if a in VALUED:
                skip = True
        else:
            args.append(a)

    root = args[0] if args else os.path.dirname(os.path.abspath(__file__))
    root = os.path.abspath(root)

    categories = None if "--all" in flags else DEFAULT_CATEGORIES

    #  --categories IS THE SURGICAL VERSION OF --all. The census at the bottom
    #  of the report names a category and a count; this is how you then look
    #  inside one without pulling every item in the game through the report.
    #  Compared lowercased, because vanilla spells the same category both ways.
    for i, flag in enumerate(argv):
        if flag == "--categories" and i + 1 < len(argv):
            categories = {c.strip().lower()
                          for c in argv[i + 1].split(",") if c.strip()}
    orphans_only = "--orphans" in flags
    skip_refs = "--no-refs" in flags

    max_consumers = None
    for i, flag in enumerate(argv):
        if flag == "--max-consumers" and i + 1 < len(argv):
            try:
                max_consumers = int(argv[i + 1])
            except ValueError:
                pass
    if orphans_only and max_consumers is None:
        max_consumers = 0

    if not os.path.isdir(root):
        print("Not a folder: %s" % root)
        return 1

    print("Scanning %s ..." % root)

    consumers, producers, consumed_by, recipes_seen, recipe_bad = scan_recipes(root)
    rows, items_seen, item_bad, own_files, excluded = scan_items(root, categories)

    names = {r["name"] for r in rows}
    if skip_refs:
        refs, ref_where, ref_files = Counter(), defaultdict(Counter), 0
    else:
        print("Scanning the tree for references to %d item name(s). This is the"
              % len(names))
        print("slow part -- it reads every text asset once. Pass --no-refs to skip.")
        refs, ref_where, ref_files = scan_references(root, names, own_files)
        print("Read %d text file(s)." % ref_files)

    for row in rows:
        row["consumers"] = consumers.get(row["name"], 0)
        row["producers"] = producers.get(row["name"], 0)
        row["refs"] = refs.get(row["name"], 0)
        row["where"] = " ".join(
            "%s:%d" % (folder, count)
            for folder, count in ref_where.get(row["name"], Counter()).most_common(5))
        row["into"] = ", ".join(consumed_by.get(row["name"], [])[:4])

    if max_consumers is not None:
        rows = [r for r in rows if r["consumers"] <= max_consumers]

    #  Sorted so the accumulation candidates come first WITHIN each category:
    #  fewest sinks, then most expensive, then by name. Reading top-down is
    #  reading in order of how badly an item needs somewhere to go.
    rows.sort(key=lambda r: (r["category"].lower(), r["consumers"],
                             -(r["price"] or 0), r["name"]))

    here = os.path.dirname(os.path.abspath(__file__))
    tsv_path = os.path.join(here, "petports_fooddump.tsv")
    txt_path = os.path.join(here, "petports_fooddump.txt")

    columns = ["name", "short", "category", "price", "food", "maxstack",
               "consumers", "producers", "refs", "where", "rarity", "tags", "into"]

    with open(tsv_path, "w", encoding="utf-8") as fh:
        fh.write("\t".join(columns) + "\n")
        for row in rows:
            fh.write("\t".join(flatten(row.get(c)) for c in columns) + "\n")

    out = []
    out.append("petports_fooddump")
    out.append("root: %s" % root)
    out.append("")
    out.append("%d item file(s) read, %d recipe(s) read, %d row(s) reported"
               % (items_seen, recipes_seen, len(rows)))
    if categories is not None:
        out.append("categories: %s" % ", ".join(sorted(categories)))
    if max_consumers is not None:
        out.append("trimmed to items with at most %d recipe consumer(s)"
                   % max_consumers)

    by_cat = Counter(r["category"] for r in rows)
    out.append("")
    out.append("=" * 78)
    out.append("BY CATEGORY  (as spelled in the assets -- casing is not normalised)")
    out.append("=" * 78)
    width = max([len(k) for k in by_cat] + [8])
    for cat, count in sorted(by_cat.items(), key=lambda kv: (-kv[1], kv[0])):
        orphan = sum(1 for r in rows if r["category"] == cat and r["consumers"] == 0)
        out.append("%-*s  %6d   %d with no recipe consumer" % (width, cat, count, orphan))

    if not skip_refs:
        dead = [r for r in rows if r["refs"] == 0]
        dead.sort(key=lambda r: (r["category"].lower(), r["name"]))
        out.append("")
        out.append("=" * 78)
        out.append("NOTHING IN THE GAME MENTIONS THESE  (%d)" % len(dead))
        out.append("=" * 78)
        out.append("Not named by any treasure pool, monster drop, biome, quest,")
        out.append("shop or recipe -- only by their own definition file. These are")
        out.append("the deprecated tail: still in the assets, no way to obtain them.")
        out.append("A reagent class built on one of these would look correct and")
        out.append("never fire.")
        out.append("")
        for row in dead:
            out.append("%-30s %-28s %s"
                       % (row["name"][:30], (row["short"] or "")[:28],
                          row["category"]))

        thin = [r for r in rows if 0 < r["refs"] <= 2]
        thin.sort(key=lambda r: (r["refs"], r["category"].lower(), r["name"]))
        out.append("")
        out.append("=" * 78)
        out.append("BARELY MENTIONED -- ONE OR TWO FILES  (%d)" % len(thin))
        out.append("=" * 78)
        out.append("Obtainable, but from exactly one or two places. Worth a look")
        out.append("before leaning on one as a reagent: a single mention can be a")
        out.append("live drop pool or a leftover reference in a dungeon nobody")
        out.append("generates.")
        out.append("")
        for row in thin:
            out.append("%-30s %-26s %2d ref(s)   %s"
                       % (row["name"][:30], (row["short"] or "")[:26],
                          row["refs"], row["where"]))

    orphans = [r for r in rows if r["consumers"] == 0]
    out.append("")
    out.append("=" * 78)
    out.append("NOTHING CRAFTS WITH THESE  (%d)" % len(orphans))
    out.append("=" * 78)
    out.append("The tail the flavour classes exist to absorb. A high producer")
    out.append("count with zero consumers is the loudest version: the game hands")
    out.append("it over repeatedly and never asks for it back.")
    out.append("")
    orphans.sort(key=lambda r: (-r["producers"], -(r["price"] or 0), r["name"]))
    for row in orphans:
        out.append("%-34s %-28s %8s  price %-6s made by %d recipe(s)"
                   % (row["name"][:34], (row["short"] or "")[:28],
                      row["category"][:8], flatten(row["price"]) or "-",
                      row["producers"]))

    if categories is not None and excluded:
        out.append("")
        out.append("=" * 78)
        out.append("CATEGORIES PRESENT BUT NOT REPORTED  (%d)" % len(excluded))
        out.append("=" * 78)
        out.append("The filter excluded these. Listed because an item missing from")
        out.append("the report reads as an item that does not exist -- mushroom,")
        out.append("sugarcane, wheat, rice and cocoa all went missing from the")
        out.append("first run this way, having a seed and a cooked form in scope")
        out.append("and their produce somewhere out of it. Run --all if something")
        out.append("you expected is not here.")
        out.append("")
        width2 = max([len(k) for k in excluded] + [8])
        for cat, count in sorted(excluded.items(), key=lambda kv: (-kv[1], kv[0])):
            out.append("%-*s  %6d" % (width2, cat, count))

    for label, entries in (("UNREADABLE ITEM FILES", item_bad),
                           ("UNREADABLE RECIPE FILES", recipe_bad)):
        if entries:
            out.append("")
            out.append("=" * 78)
            out.append("%s  (%d)" % (label, len(entries)))
            out.append("=" * 78)
            for path, err in entries[:40]:
                out.append("%s  --  %s" % (path, err))

    text = "\n".join(out)
    open(txt_path, "w", encoding="utf-8").write(text + "\n")

    print(text)
    print("")
    print("Wrote %s" % tsv_path)
    print("Wrote %s" % txt_path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
