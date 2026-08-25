#!/usr/bin/env python3
"""
petports_tagdump -- what categories and tags actually exist in your assets.

Drop this anywhere inside (or beside) an UNPACKED Starbound assets folder and
run it. With no arguments it scans from its own directory downward, so putting
it in assets/ and double-clicking is enough.

    python petports_tagdump.py                  scan from here
    python petports_tagdump.py path/to/assets   scan somewhere else
    python petports_tagdump.py --csv out.csv    also write a per-item table
    python petports_tagdump.py --extensions     just list what file types exist

WHY THIS EXISTS
---------------
The petports filter manifest sorts on three fields, and every one of them has
already been wrong at least once:

  * category    camelCase, from /items/categories.config
  * itemTags    lowercase, on items -- NOT the same spelling as the category
  * colonyTags  lowercase, on OBJECTS only, and the field objects actually use

`subgroupMatches` compares with `==`, so a wrong name is a SILENT no-match:
nothing sorts by it and nothing anywhere says so. Four dead category names sat
in the manifest for weeks that way, and 133 tenant tags matched nothing at all
because they were being looked for in `itemTags`.

Guessing is what costs launches. This reads the assets and reports what is
really there, so a subgroup can be written against evidence.

WHAT IT DOES NOT DO
-------------------
It reads authored files only. It cannot see tags a build script invents at
runtime -- which is fine, because petports_itemFacts reads the base config too
and cannot see them either. If it is invisible here, it is invisible to the
filter, and that is the useful definition.
"""

import json
import os
import re
import sys
from collections import Counter, defaultdict

# Every extension that can carry a category or tags. .object is the one that
# matters for tenant tags; the rest are here so one run answers every question.
EXTS = (
    # objects -- done, and the only source of colonyTags
    ".object",

    # the ones that settle the tags still marked UNVERIFIED in the manifest
    ".item",            # ores, bars, gems: all craftingMaterial, tags only
    ".consumable",      # food, drink, medicine; where "produce" would live

    # weapons and held things
    ".activeitem", ".thrownitem",

    # worn
    ".head", ".chest", ".legs", ".back",

    # blocks and liquids as ITEMS (the .material/.liquid files are the tiles)
    ".matitem", ".liqitem",

    # single-purpose item types
    ".augment", ".currency", ".codex", ".instrument", ".unlock",

    # the tool family -- one subgroup, many extensions, most of them tiny
    ".miningtool", ".beamaxe", ".flashlight", ".wiretool", ".tillingtool",
    ".painttool", ".harvestingtool", ".inspectiontool",
)

#  CONFIRMED BY --extensions AGAINST A REAL ASSET TREE, not recited from memory.
#  Every extension above exists and has files. ".coinitem" and ".grapplinghook"
#  were in this list and do NOT exist; both were guesses and both are removed.
#
#  An extension that does not exist scans as zero files, which is
#  indistinguishable from a category nothing uses -- so run --extensions first
#  against any tree before trusting a zero.
#
#  NOT scanned, deliberately, though they look like they might qualify:
#    .material .liquid   the TILE definitions; .matitem and .liqitem are the
#                        item forms and those are scanned
#    .recipe             what a crafting station makes, not an item
#    .vehicle .tech      definitions; the spawner ITEMS are .activeitem/.item
#    .collection         the bug and fossil collection lists, not items
#    .itemdescription    checked: tooltip text for generated items, the kind of
#                        thing shown in a merchant or crafting list. No category
#                        or tags, so nothing here can read it. Not an open
#                        question -- do not re-add it looking for one.

SKIP_DIRS = {".git", "_metadata", "previews", "user"}


def strip_comments(text):
    """Starbound's parser accepts // comments in JSON. Python's does not.

    Only strips // when it is outside a string, so a path like
    "/interface/x.png" survives.
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
    #  strict=False IS LOAD BEARING, NOT A LOOSENING.
    #
    #  Starbound's JSON parser allows raw control characters inside strings and
    #  vanilla uses that freely -- codex bodies are full of literal newlines and
    #  tabs. Python's default rejects them, and the first run of this tool threw
    #  away 111 of 123 .codex files with "Invalid control character", which
    #  reported as the codex CATEGORY not existing rather than as a read failure.
    #
    #  A parse setting that silently deletes a whole category from the output is
    #  worse than a crash.
    try:
        return json.loads(strip_comments(raw), strict=False), None
    except ValueError as err:
        # Trailing commas are common in hand-edited mod files.
        try:
            return json.loads(re.sub(r",(\s*[}\]])", r"\1", strip_comments(raw)),
                              strict=False), None
        except ValueError:
            return None, str(err)


def scan(root):
    cats = Counter()
    item_tags = Counter()
    colony_tags = Counter()
    races = Counter()
    cat_examples = defaultdict(list)
    tag_examples = defaultdict(list)
    colony_examples = defaultdict(list)
    rows = []
    bad = []
    seen = 0

    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if not name.lower().endswith(EXTS):
                continue
            path = os.path.join(dirpath, name)
            data, err = load(path)
            if data is None:
                bad.append((os.path.relpath(path, root), err))
                continue
            if not isinstance(data, dict):
                continue

            seen += 1
            ident = (data.get("objectName") or data.get("itemName")
                     or os.path.splitext(name)[0])

            cat = data.get("category")
            if isinstance(cat, str):
                cats[cat] += 1
                if len(cat_examples[cat]) < 3:
                    cat_examples[cat].append(ident)

            it = data.get("itemTags")
            it = [t for t in it if isinstance(t, str)] if isinstance(it, list) else []
            for t in it:
                item_tags[t] += 1
                if len(tag_examples[t]) < 3:
                    tag_examples[t].append(ident)

            ct = data.get("colonyTags")
            ct = [t for t in ct if isinstance(t, str)] if isinstance(ct, list) else []
            for t in ct:
                colony_tags[t] += 1
                if len(colony_examples[t]) < 3:
                    colony_examples[t].append(ident)

            race = data.get("race")
            if isinstance(race, str):
                races[race] += 1

            rows.append((ident, os.path.splitext(name)[1], cat or "",
                         " ".join(sorted(it)), " ".join(sorted(ct)),
                         race if isinstance(race, str) else ""))

    return dict(seen=seen, cats=cats, item_tags=item_tags, colony_tags=colony_tags,
                races=races, cat_examples=cat_examples, tag_examples=tag_examples,
                colony_examples=colony_examples, rows=rows, bad=bad)


def section(title, counter, examples, out):
    out.append("")
    out.append("=" * 78)
    out.append("%s  (%d distinct)" % (title, len(counter)))
    out.append("=" * 78)
    width = max([len(k) for k in counter] + [4])
    for name, count in sorted(counter.items(), key=lambda kv: (-kv[1], kv[0])):
        eg = ", ".join(examples.get(name, [])[:3])
        out.append("%-*s  %6d   %s" % (width, name, count, eg))


def list_extensions(root):
    """Every extension present, with counts and how many this tool would read.

    Exists because the alternative is reciting extension names from memory, and
    an extension that does not exist scans silently as zero files -- which is
    indistinguishable from a category nothing uses. Run this first against a
    real asset tree and add whatever turns up that EXTS does not cover.
    """
    found = Counter()
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            ext = os.path.splitext(name)[1].lower()
            if ext:
                found[ext] += 1

    known = set(e.lower() for e in EXTS)
    print("")
    print("=" * 62)
    print("EXTENSIONS PRESENT  (%d distinct)" % len(found))
    print("=" * 62)
    print("%-22s %8s   %s" % ("extension", "files", "scanned?"))
    for ext, count in sorted(found.items(), key=lambda kv: (-kv[1], kv[0])):
        print("%-22s %8d   %s" % (ext, count, "yes" if ext in known else ""))

    missed = sorted(e for e in known if e not in found)
    if missed:
        print("")
        print("In EXTS but not present here (harmless, possibly misremembered):")
        print("  " + ", ".join(missed))
    return 0


def main():
    args = [a for a in sys.argv[1:]]
    if "--extensions" in args:
        args.remove("--extensions")
        root = args[0] if args else os.path.dirname(os.path.abspath(__file__))
        print("scanning %s ..." % root)
        return list_extensions(root)

    csv_path = None
    if "--csv" in args:
        i = args.index("--csv")
        csv_path = args[i + 1] if i + 1 < len(args) else "petports_tagdump.csv"
        del args[i:i + 2]

    root = args[0] if args else os.path.dirname(os.path.abspath(__file__))
    if not os.path.isdir(root):
        print("not a directory: %s" % root)
        return 1

    print("scanning %s ..." % root)
    r = scan(root)

    if r["seen"] == 0:
        print("")
        print("No item or object files found.")
        print("Put this inside your UNPACKED assets folder, or pass the path:")
        print("    python %s path/to/assets" % os.path.basename(__file__))
        return 1

    out = []
    out.append("petports tag dump")
    out.append("root: %s" % root)
    out.append("files read: %d" % r["seen"])
    if r["bad"]:
        out.append("files that would not parse: %d (listed at the end)" % len(r["bad"]))

    section("CATEGORY  (camelCase -- goes in a subgroup's \"categories\")",
            r["cats"], r["cat_examples"], out)
    section("itemTags  (lowercase -- goes in \"tags\"; items carry these)",
            r["item_tags"], r["tag_examples"], out)
    section("colonyTags  (lowercase -- goes in \"tags\"; OBJECTS carry these)",
            r["colony_tags"], r["colony_examples"], out)
    section("race  (not read by the filter today, listed for reference)",
            r["races"], {}, out)

    # The overlap is the interesting part: a name that is BOTH a category and a
    # tag is where a subgroup can be written wrong and still look plausible.
    both = sorted(set(r["cats"]) & (set(r["item_tags"]) | set(r["colony_tags"])))
    lower_cats = {c.lower(): c for c in r["cats"]}
    near = sorted(
        (lower_cats[t], t) for t in set(r["item_tags"]) | set(r["colony_tags"])
        if t in lower_cats and lower_cats[t] != t)

    out.append("")
    out.append("=" * 78)
    out.append("SPELLING TRAPS")
    out.append("=" * 78)
    out.append("")
    out.append("Same name is both a category and a tag (%d).  Either field works," % len(both))
    out.append("which means a subgroup using the wrong one still appears to work:")
    out.append("  " + (", ".join(both) if both else "none"))
    out.append("")
    out.append("Category and tag differ ONLY by case (%d).  This is the one that" % len(near))
    out.append("bites -- the category is camelCase, the tag is not:")
    for cat, tag in near:
        out.append("  category %-24s tag %s" % (cat, tag))
    if not near:
        out.append("  none")

    if r["bad"]:
        out.append("")
        out.append("=" * 78)
        out.append("WOULD NOT PARSE  (%d)" % len(r["bad"]))
        out.append("=" * 78)
        for path, err in r["bad"][:40]:
            out.append("  %s\n      %s" % (path, err))
        if len(r["bad"]) > 40:
            out.append("  ... and %d more" % (len(r["bad"]) - 40))

    text = "\n".join(out)
    report = os.path.join(os.getcwd(), "petports_tagdump.txt")
    open(report, "w", encoding="utf-8").write(text + "\n")

    print(text)
    print("")
    print("written: %s" % report)

    if csv_path:
        import csv as _csv
        with open(csv_path, "w", newline="", encoding="utf-8") as fh:
            w = _csv.writer(fh)
            w.writerow(["name", "ext", "category", "itemTags", "colonyTags", "race"])
            w.writerows(sorted(r["rows"]))
        print("written: %s" % os.path.abspath(csv_path))

    return 0


if __name__ == "__main__":
    sys.exit(main())
