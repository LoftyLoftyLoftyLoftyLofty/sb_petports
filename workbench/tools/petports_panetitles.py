#!/usr/bin/env python3
"""
petports_panetitles -- does ANY vanilla container pane keep its own subtitle?

Drop beside petports_fooddump.py inside an UNPACKED Starbound assets folder.

    python petports_panetitles.py                 scan from here
    python petports_panetitles.py path/to/assets  scan somewhere else

WHY THIS EXISTS
---------------
ContainerPane stamps a pane's title and subtitle from the object's
`shortdescription` and `category`, over whatever the title widget declares.
Measured three ways and it won every time:

  * declaring both strings in a widget named "title"       -> stamped
  * renaming that widget to "windowtitle"                  -> stamped
  * setting "titleFromEntity" : false at the top level     -> stamped

The third is the informative failure. `titleFromEntity` comes from
/interface/crafting/fossilstation.config, which is a CRAFTING pane -- a
different C++ class with a different config schema. There is no reason
ContainerPane should read that key, and the evidence says it does not.

So the question is not "which key turns the stamp off". It is: DOES ANY VANILLA
CONTAINER SHOW A SUBTITLE THAT IS NOT ITS CATEGORY LABEL? If one does, whatever
that object or config does differently is the answer. If none does across every
container in the game, the stamp is unconditional and the only lever is the
object's own fields -- which is a real answer too, and worth having rather than
suspecting.

WHAT IT REPORTS
---------------
Every object that is a container AND names a uiConfig, paired with what its
pane declares and what the object would stamp over it. The interesting rows are
the DISAGREEMENTS: a config that bothers to declare a subtitle different from
its own category label was written by someone who expected it to show.
"""

import json
import os
import re
import sys
from collections import Counter

SKIP_DIRS = {".git", "_metadata", "previews", "user"}


def strip_comments(text):
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
        if c == "/" and text[i + 1:i + 2] == "/":
            j = text.find("\n", i); i = n if j < 0 else j; continue
        if c == "/" and text[i + 1:i + 2] == "*":
            j = text.find("*/", i); i = n if j < 0 else j + 2; continue
        out.append(c); i += 1
    return "".join(out)


def load(path):
    try:
        raw = open(path, "rb").read().decode("utf-8-sig", errors="replace")
    except OSError:
        return None
    for attempt in (raw, re.sub(r",(\s*[}\]])", r"\1", raw)):
        try:
            return json.loads(strip_comments(attempt), strict=False)
        except ValueError:
            continue
    return None


def find_title(gui):
    """The title widget, wherever it sits and whatever it is called.

    Searched by TYPE rather than by name, because that is how ContainerPane
    finds it -- renaming ours to "windowtitle" changed nothing, which is the
    measurement that established this.
    """
    if not isinstance(gui, dict):
        return None, None
    for name, w in gui.items():
        if isinstance(w, dict) and w.get("type") == "title":
            return name, w
    return None, None


def main(argv):
    root = os.path.abspath(argv[1] if len(argv) > 1
                           else os.path.dirname(os.path.abspath(__file__)))
    if not os.path.isdir(root):
        print("Not a folder: %s" % root); return 1
    print("Scanning %s ...\n" % root)

    labels = {}
    cats = os.path.join(root, "items", "categories.config")
    data = load(cats)
    if isinstance(data, dict):
        labels = data.get("labels", {}) or {}
    print("categories.config: %d labels\n" % len(labels))

    rows, missing_cfg = [], []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if not fn.lower().endswith(".object"):
                continue
            obj = load(os.path.join(dirpath, fn))
            if not isinstance(obj, dict):
                continue
            if obj.get("objectType") != "container":
                continue
            ui = obj.get("uiConfig")
            if not isinstance(ui, str):
                continue

            cfg = load(os.path.join(root, ui.lstrip("/")))
            if cfg is None:
                missing_cfg.append((obj.get("objectName"), ui)); continue

            #  A container pane's widgets can sit under "gui" or "paneLayout"
            #  depending on which class the config was written for. Check both
            #  rather than assuming, since assuming is what put titleFromEntity
            #  in our file.
            wname, w = find_title(cfg.get("gui"))
            if w is None:
                wname, w = find_title(cfg.get("paneLayout"))

            cat = obj.get("category")
            rows.append({
                "object": obj.get("objectName"),
                "ui": ui,
                "short": obj.get("shortdescription") or "",
                "category": cat or "",
                "stamped": labels.get(cat, cat or ""),
                "widget": wname or "",
                "title": (w or {}).get("title", ""),
                "subtitle": (w or {}).get("subtitle", ""),
                "hasIcon": bool((w or {}).get("icon")),
                "fromEntity": cfg.get("titleFromEntity", "(absent)"),
            })

    print("%d container object(s) with a uiConfig\n" % len(rows))

    def clean(s):
        #  Strip colour escapes so a declared subtitle compares against a label
        #  on its text rather than on its formatting.
        return re.sub(r"\^[^;]*;", "", str(s)).strip()

    interesting = [r for r in rows
                   if r["subtitle"] and clean(r["subtitle"]) != clean(r["stamped"])]

    print("=" * 78)
    print("DECLARES A SUBTITLE THAT IS NOT ITS CATEGORY LABEL  (%d)" % len(interesting))
    print("=" * 78)
    print("These are the ones to look at in game. Whatever a pane here does")
    print("differently is the answer -- and if this list is empty, or every entry")
    print("renders its category anyway, the stamp is unconditional.")
    print("")
    for r in interesting:
        print("%s" % r["object"])
        print("   ui          %s" % r["ui"])
        print("   declares    %r / %r" % (r["title"], r["subtitle"]))
        print("   would stamp %r / %r" % (r["short"], r["stamped"]))
        print("   widget %-14s icon %-5s titleFromEntity %s"
              % (r["widget"], r["hasIcon"], r["fromEntity"]))
        print("")

    print("=" * 78)
    print("EVERY CONTAINER WITH A uiConfig")
    print("=" * 78)
    w = max([len(r["object"] or "") for r in rows] + [8])
    for r in sorted(rows, key=lambda r: r["object"] or ""):
        flag = " <<<" if r in interesting else ""
        print("%-*s  cat %-20s widget %-12s sub %r%s"
              % (w, r["object"], r["category"], r["widget"] or "-",
                 clean(r["subtitle"]), flag))

    print("")
    print("titleFromEntity across these configs: %s"
          % dict(Counter(str(r["fromEntity"]) for r in rows)))
    if missing_cfg:
        print("\nuiConfig files that could not be read (%d):" % len(missing_cfg))
        for name, ui in missing_cfg[:20]:
            print("   %-24s %s" % (name, ui))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
