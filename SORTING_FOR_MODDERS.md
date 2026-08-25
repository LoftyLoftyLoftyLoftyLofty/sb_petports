# Making your mod's items sort — a guide for modders

Petports deposit beacons sort items into crates by category and tag. This is
what your mod needs to do to work with that.

**Short version: if you tag your items the way vanilla does, you are already
done and there is nothing to read here.** Part 1 is one page and covers almost
everyone. Part 2 is for when you want your own categories in the beacon UI.

---

## Part 1 — The minimum

Petports reads **three fields** off your item or object files. It does not read
anything else, and it does not need a compatibility patch from you.

| Field | Goes on | Looks like |
|---|---|---|
| `category` | items and objects | `"category" : "broadsword"` |
| `itemTags` | items | `"itemTags" : [ "weapon", "melee", "broadsword" ]` |
| `colonyTags` | objects | `"colonyTags" : [ "floran", "floranvillage" ]` |

Use the same values vanilla uses and your things sort automatically.

### The three rules

**1. Set a `category`, and copy the spelling from a vanilla file.**

Categories are matched exactly. `broadsword` works; `Broadsword` and
`broadSword` do not, and they fail *silently* — the item simply never sorts and
nothing tells you why.

Vanilla's list of categories lives in `/items/categories.config`. That is a
label table rather than a rule, so a category not in it still works — but if you
invent one, nothing in petports will know about it unless you also do Part 2.

**2. Tag objects with `colonyTags`, using the vanilla vocabulary.**

Objects are how a colony deed decides which tenant to spawn, and petports reuses
the same tags. A Floran-themed chair wants `"colonyTags" : [ "floran" ]` and it
will sort under Species Themed with no further work.

The full vanilla list is on the wiki at <https://starbounder.org/Tag>. Ignore the
capitalisation there — the wiki capitalises for display and the real tags are
lowercase.

**3. Watch the casing, because the two vocabularies disagree.**

This trips everyone. The same weapon type is spelled differently depending on
which field you are in:

```json
"category" : "assaultRifle",                          // camelCase
"itemTags" : [ "weapon", "ranged", "assaultrifle" ]   // all lowercase
```

Copy from a vanilla file rather than typing from memory.

### Naming conventions that get you sorted for free

Two kinds of item have no file at all — the game generates them — so petports
matches them on the item's **name**:

- **Blueprints** end in `-recipe`.
- **Codex entries** end in `-codex`, and are sorted by species from the start
  of the name. A codex file called `mycoolracehistory1` produces an item called
  `mycoolracehistory1-codex`, and if `mycoolrace` has a subgroup it lands there.

If you add a race and name your codexes `<yourrace>something`, add one subgroup
(Part 2, it is four lines) and the whole set sorts by species. If you do not,
they all land in **Other Codices**, which is the bucket for things nothing
recognises. It works, but a player with two such mods gets them mixed together.

### How to check it worked

There is a scanner in `workbench/` — `petports_tagdump.py` — that reads an asset
tree and prints every category and tag it found, with example item names. Run it
over your own mod:

```
py petports_tagdump.py path\to\your\mod
```

It also prints a **spelling traps** section listing names that differ only by
case from a vanilla one. If your category shows up there, that is your bug.

---

## Part 2 — Adding your own groups and subgroups

Everything above is about fitting into the existing buckets. This part is about
adding your own — a new race, a new class of item, a themed set that deserves
its own crate.

### Where it lives

`/scripts/lofty_petports/petports_filtergroups.config`

**Groups and subgroups are keyed by id, not arrays.** This is on purpose: it
means your patch path names the thing you are patching and never depends on how
many groups anyone else added first.

```json
{
  "groups" : {
    "ores" : {
      "label" : "Ores and Bars",
      "order" : 10,
      "subgroups" : {
        "ore"   : { "label" : "Raw Ore", "order" : 10, "suffixes" : [ "ore" ] },
        "ingot" : { "label" : "Bars",    "order" : 20, "items" : [ "ironbar" ] }
      }
    }
  }
}
```

A **group** is one row in the beacon's picker. A **subgroup** is one tile in the
grid underneath it. The key is the id and must be unique; `label` is what the
player reads.

`order` sets display position, low to high. Ties break on id, so it is stable
rather than merely deterministic. Vanilla numbers in tens — pick a gap.
Omitting it puts you at the end.

**Patch it, do not replace it.** Ship a `petports_filtergroups.config.patch`:

```json
[
  {
    "op" : "add",
    "path" : "/groups/species/subgroups/mycoolrace",
    "value" : { "label" : "My Cool Race", "order" : 115, "tags" : [ "mycoolrace" ] }
  }
]
```

That path says what it means and keeps saying it no matter what else is
installed. Adding a whole new group is the same shape:

```json
[
  {
    "op" : "add",
    "path" : "/groups/mycoolstuff",
    "value" : {
      "label" : "My Cool Stuff",
      "order" : 145,
      "subgroups" : {
        "trinkets" : { "label" : "Trinkets", "order" : 10, "tags" : [ "mycooltrinket" ] }
      }
    }
  }
]
```

Two mods adding the same key collide, last one wins — so prefix your ids with
something of yours unless you are deliberately extending a vanilla group.

### The matchers

A subgroup matches an item if **any** of these hit. They are ORed; you do not
need more than one.

| Field | Matches when |
|---|---|
| `categories` | the item's `category` is exactly one of these |
| `tags` | the item has one of these in `itemTags` **or** `colonyTags` |
| `items` | the item's name is exactly one of these |
| `suffixes` | the item's name ends with one of these |
| `nameParts` | see below |

`tags` deliberately does not care which of the two tag fields a tag came from.
An author writes the tag; which file it lives in is our problem.

### `suffixes`

For generated items that have no file to tag — blueprints and codexes are the
two vanilla cases.

```json
{ "id" : "recipe", "label" : "Blueprints", "suffixes" : [ "-recipe" ] }
```

Suffix, not a pattern. A pattern field would be evaluated per item per scan and
would let a typo cost real performance.

**Careful with short suffixes.** `"bar"` also matches `saloonbar`, which is
furniture. That is why the vanilla Bars subgroup lists eight names instead.

### `nameParts`

The one matcher that is **ANDed**: prefix *and* suffix must both hold.

```json
{
  "id" : "apex",
  "label" : "Apex",
  "nameParts" : [ { "prefix" : "apex", "suffix" : "-codex" } ]
}
```

This exists because codex files carry no category, no tags and no race field —
the only thing identifying an Apex codex is its name. A bare `apex` prefix would
match every Apex chair and door in the game; the `-codex` suffix is what makes
the prefix safe.

Either key may be omitted. An entry with neither matches nothing rather than
everything, because a typo should sort nothing rather than sort the whole game
into one crate.

### `unclassified`

A subgroup marked `"unclassified" : true` catches items that **no other
subgroup in its group can describe**.

```json
{ "id" : "other", "label" : "Other Codices",
  "suffixes" : [ "-codex" ], "unclassified" : true }
```

Read that carefully, because it is not "whatever is left over after the player
unticks things". The test runs against the manifest, not against the player's
choices: if a sibling subgroup *describes* an item, that item is not
unclassified, whether or not the player has that sibling switched on. So
unticking Glitch removes Glitch codexes from the crate — it does not push them
into Other.

It narrows on its own. Patch in a race subgroup and those entries stop being
unclassified immediately.

Use it sparingly. One per group at most, and only where "we could not name this"
is a thing a player would want a crate for.

### Subgroups are stored as EXCLUSIONS, and this matters to you

When a player configures a rule, petports records the subgroups they switched
**off**, not the ones they left on.

The consequence is the whole reason the manifest is patchable: **a subgroup you
add is inside every existing rule immediately.** A player who set a crate to
"Species Themed" six months ago gets your race sorted into it the first time
they load your mod, without touching the beacon.

The flip side is that you cannot quietly add something a player has already
decided against. If that would be surprising — your subgroup is very broad, or
it overlaps something they are likely to have tuned — a new group is the more
honest choice than squeezing into an existing one.

### Do not iterate the manifest yourself

If you are writing Lua against this rather than just patching data, use
`petports_filterGroups()` and `petports_filterSubgroups(group)`. They return
arrays in display order with the id copied onto each entry.

A raw `pairs()` over `groups` or `subgroups` gives a different order every run —
Lua makes no promise about key order — and the beacon UI would shuffle between
openings.

### Things that will not work

**Tags invented by a build script.** Petports reads the base config via
`root.itemConfig`, the same way `root.itemHasTag` does. If your builder adds a
tag at runtime, petports cannot see it. Put it in the file.

**Anything that is not a category, a tag or a name.** Damage types, rarity,
level, parameters on a specific instance — none of it is reachable. Notably this
means capture pods cannot be sorted by the species inside them, and hunting
weapons cannot be told apart from other weapons, because both live in places
this system cannot read.

**Case-insensitive matching.** There is none, anywhere. `==` throughout.

### If it does not work

Turn on filter debug in `petports_filters.lua` and pick the item up. You will
get a line like:

```
facts ironbar: category=craftingMaterial tags=[reagent] (1 item, 0 colony)
```

That is exactly what petports can see. If your category or tag is not on that
line, the problem is in your item file. If it is on the line and the item still
does not sort, the problem is in your subgroup — and it is almost always the
casing.
