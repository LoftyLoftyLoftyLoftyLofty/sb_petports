# PETPORTS -- handoff v2

`lofty_petports`. A deployable spawner ("petport") that houses a utility unit,
plus the unit behaviour that makes one worth having. Split out of the Nicemice
mod on 2025-08-19, before any public release, so that object and monster
identity names were still free to change.

Nicemice remains the intended content layer: unit types, chassis variants and
the encounter/quest loop that unit items drop from. This mod is the machinery.

## How to read this

ORGANISED BY CATEGORY, NOT BY TOPIC. v1 was topic-first, which forced every
category -- status, facts, decisions, war stories -- to be duplicated inside
every topic, and there was no way to prune one without reading all of them.

EVERY ENTRY CARRIES A TAG, `<category>.<topic>.<slug>`, so the document greps in
two directions:

    grep 'dd\.'          every design decision
    grep '\.pathing\.'   everything about pathing, whatever its category

The topic segment is a CLOSED VOCABULARY and must be spelled identically across
categories or that second grep silently stops working. `petports_handoff.py`
enforces it, along with tag uniqueness, section placement and cross-references.

WHAT ROTS, AND HOW FAST, is why the sections are split this way:

    STATUS     every session -- rewritten wholesale, never edited
    ARCH       on refactor
    DD         rarely; supersession must be explicit
    PLAN/NICE  when built (graduates to ARCH) or abandoned
    FACT       only if the engine changes
    DEAD       never
    REF        on retune
    TODO       as things are fixed
    PROC       rarely

ANYTHING THAT IS NONE OF THESE IS NARRATIVE AND DOES NOT BELONG. The durable
residue of a war story is always a fact, a disproven theory, or a process rule.
File it as that, not as the story.

## STATUS

### What is built, as of 2026-08-30 (overnight)
`status.port.inventory`

REWRITTEN WHOLESALE EVERY SESSION. Never edited, never appended to. If a claim
here disagrees with anything below, this is right and that is stale.

CAVEAT ON THIS PASS: this session touched the upcycler object and its pane, the
new shared classifier, the petport object's machine-output scan, both pane
icons, and the unit's ground resolver. Everything outside those carries its
previous session's date and was not re-verified.

**The upcycler's slot behaviour is finished and verified in game.** Rule-row
checkboxes were broken two ways and are fixed (`applyState` stripped both
exclusions; `x and nil or false` cannot yield nil -- `fact.tooling.andnilor`).
The shuttle now runs on one priority, charge before burner, with a weight-aware
fit test that is what makes it terminate -- see `arch.upcycler.shuttlepriority`.
Bulk where the destination rule is a dead end, paced where it is not. The mutual
swap deadlock resolves itself. `consumeReagent` refuses exempt items, and both
the pane and the machine now read ONE refusal ladder
(`arch.upcycler.stateladder`). Non-treats parked in an output slot are collected
by a unit instead of stranding the machine (`arch.upcycler.outputeviction`).
Tested: the loop case, bulk rescue, trickle, exempt in both slots, the deadlock,
and eviction.

**Both panes have title icons and the upcycler has a running light.** The light
flares hard on transition then settles -- off breathes and never fully dims, on
goes steady -- because the problem it solves is a MISSED TRANSITION, not a missed
state: adding a rule deliberately switches the machine off and a whole test round
was run against a stopped machine before anyone noticed. Art is placeholder,
driven entirely by image directive, so real art drops in with no script change.

**A submerged farm animal is now reachable.** This took most of the session and
three wrong fixes -- `fact.pathing.floatingtarget` is the entry, and it is worth
reading before touching any resolver. The short version: underwater every point
is standable, so `findGroundPosition` returned a spot hanging in open water and a
walking chassis cannot finish a path there. It descends now.

**The search state machine reported exhausted searches as successes.** Three
states, two branches: `hasPath false, aStar nil` means the search FINISHED WITH
NO ROUTE and fell into the branch labelled "a path exists now". 37 real failures
read as successes in one run, and the unit waited out the 10 s no-progress
watchdog instead of reporting a conclusive answer immediately. Split into three.
This predates the session and was found by the diagnostics, not by looking.

**Core loop.** A petport places, opens, spawns a unit from a socketed item, and
the unit's state round-trips through that item across despawn, world reload and
being carried to another world. Placement validation, leashing, recall and
re-home are live. Multi-hop vent routing works end to end.

**Four locomotion classes** -- ground, flyer, aquatic, amphibious -- all verified
in game, including the otter case: swimming a flooded tube to reach an air
pocket and farming inside it.

**Sorting, tidying, compaction, restock.** Deposit beacons route by tag and
category; eviction runs the same predicate so a misfit is anything failing its
own crate's filter. Storage compacts itself, bucketed by parameters -- BUT
NEVER A MACHINE, as of this session; see `dd.upcycler.slotsaremeanings`.
Restock beacons handle several requests per crate: fetch, deliver, evict
overstock, evict anything unrequested.

**Farming**, end to end -- discovery, harvest, collection, deposit, replant
intents, seed withdrawal, replanting at arbitrary footprint, watering of dry
tilled soil, all surviving vent traversal both ways with no sprinkler
infrastructure. Animal harvesting is built.

**The upcycler**, including the reagent slot, reagent routing, and NEW THIS
SESSION a per-rule BURN checkbox and a slot shuttle. A rule now carries two
exclusions -- may the item enter the burner, may it route to the reagent slot
-- and the machine shuttles its own stock between those slots as their
consumption rates diverge, including a bulk rescue for burn-denied stock. See
`arch.upcycler.burnbox` and `arch.upcycler.shuttle`. The furnace door itself
refuses a burn-denied hand-drop, with a state line saying why nothing burns.

**The patrol class of bug is closed twice over.** Dispatch and arrival now
share ONE room predicate (`machineRuleRoom`), room is DESCRIPTOR-true rather
than name-true (food rot was the tell -- see `fact.item.descriptorroom`), every
machine offer is capped to measured room before the engine sees it, and the
report handler's done-cleanup runs BEFORE the arrival work so an arrival
failure's backoff survives to escalate (see `arch.port.reporthandler`).
Verified in the closing log: zero delivered-NOTHING lines, a 1000/1000 landing.
THE REORDERED BACKOFF LADDER IS UNEXERCISED -- nothing failed after the fix --
see `todo.port.backoffladder`.

**Metrics.** The port gathers per-unit lifetime stats onto `petData.stats` --
items moved, crops planted, tiles watered, crops harvested, livestock
harvested, tiles traveled, seconds active (task time only), headpats, and the
Tidy Score -- all at existing choke points, persisted with the item. See
`arch.port.metrics`. Tidy is gathered and logged but deliberately displayed
nowhere -- the rank belongs to Maxwell (`dd.dispatch.tidyscore`,
`todo.unit.maidrank`).

**The Stats tab is live**, as a scrolling LIST rather than fixed labels, with
per-block striping and placeholder separators. Steady-state refresh is
text-only and MEASURED not to strobe; rows rebuild only when the line count
changes. See `arch.pane.statslist`. The layout scales for the per-treat
counters the fuel system will want.

**Headpats.** The unit is interactive: a click emotes (vanilla's own behavior,
carried forward) and reports to the port, which counts it. One gate -- vanilla's
3s interaction window -- so the emote and the ledger cannot disagree. See
`arch.unit.headpat`. The handler is the documented future home of the
stuck-cargo drop.

**Constants are globals, as of this session.** The port's main chunk hit Lua's
200-locals-per-scope ceiling -- measured, the file refused to compile -- and 73
UPPER_CASE constants were de-localized to buy the headroom back. 127 file-scope
locals remain. See `arch.port.constantsglobal` and `fact.port.localceiling`.

**Crosshair markers.** Every drop the network has an opinion about carries one,
colour-coded by claim state, one marker per item.

**The petport pane.** 337x335 ContainerPane with a script. Portrait, name,
species-when-renamed, 20-blip fuel bar with a label that follows the chassis,
cargo slot with Take, current task, recency-gated diagnostic icons with working
tooltips, three tabs, five module slots, the port band. Reads one mirrored
object parameter; writes by message.

**Modules** work end to end. Five itemslots against a slot count the unit has
earned; a module socketed grants its declared status effects for as long as it
stays there. One module exists, `petports_module_light`.

**The port band.** Enabled switch, four participation checkboxes, claim markers.

**Tooltips, in the petport pane only.** A ContainerPane gets no script tooltips
from the engine, so this pane draws its own on two canvases. See
`arch.pane.hoverlayer`. THE UPCYCLER WILL NOT GET ONE -- see
`dd.upcycler.bakedindicators`.

**Every visible string in three of four panes** comes from one shared table --
the stats block joined it this session. THE UPCYCLER IS STILL NOT MIGRATED and
is the last pane holding its own strings. See `arch.pane.stringtable`.

**Pet feeder checkboxes** on both beacons and the upcycler. Stored, mirrored,
and READ BY NOTHING -- the fuel system does not exist yet.

**Still not built.** Docking. The fuel system itself -- so treats are made and
harvested but never eaten, and the per-treat metrics have nothing to count.
Vents do not cross a medium boundary. Liquid permissions from pet upgrades.
Rename. Maxwell and any display of the Tidy Score.

**Art.** Bespoke: the unit body, the petport, the crosshairs, the treat
COLOURS, the upcycler's charge bin icon. Placeholder: the vent, the upcycler,
the eight treat sprites, the four chassis colour strips, all petport pane art,
the module icon, and NEW: the stats list stripe fills (generated), the dashed
orange separators, and the two IDENTICAL vanilla checkboxes on an upcycler rule
row -- see `todo.art.statsdressing`. The unit has frames for `run` and nothing
else.

**The monsterpart is still named `drone_placeholder`**, file and `name` field.
Renaming is free while there is one variant and expensive once there are
several.

**THE SHUTTLE NOW RUNS ON ONE PRIORITY: keeping the flavor charge full
outranks burning more items.** Both directions consult `chargeFits`, which is
weight-aware rather than "is the charge full" -- the looser form bounces a
weight-8 reagent against a part-full charge forever, because room only frees by
burning and the item that would do the burning is the one bouncing.

VERIFIED IN GAME 2026-08-30: one move then a stop where the old build bounced;
bulk `RESCUED 21` and `RESCUED 4` on a reagent-denied stack; ~47 single moves
on a charge-full trickle.

**THE MACHINE AND THE PANE EACH DECIDE THIS SEPARATELY, and both had to be
fixed.** The pane computes its own warning text from the same manifest table,
in its own hand-written check order -- so fixing the object changed nothing the
player could see. A unit in the reagent slot still read "not a reagent" from
the pane while the object had already moved on to "exempt". Sharing a lookup
table does not make two check ORDERS agree; the order IS the logic and it lives
in two files. Third instance of this drift shape after `applyState`/
`storedRules` and the twin bulk rescues.

**THE OBJECT SCRIPT NOW CARRIES A BUILD STAMP** (`OBJECT_BUILD_STAMP`, logged
from `init`). It had none while both panes did, and that cost a round on
2026-08-30: a machine-side fix looked inert and there was no way to tell from
the log whether the file had loaded. Object scripts reload on world load, not
on file copy, so a stale one is silent and indistinguishable from a wrong one.

THE EXEMPT CHECK WAS ORDERED WRONG ON ITS FIRST PASS and is fixed. It sat
BELOW the manifest lookup, so treats, modules and pets in slot 1 all reported
"not a reagent" -- none is in the manifest, so `entry == nil` returned before
exempt was consulted. Exempt is a property of the ITEM and does not depend on
the recipe table, so it now asks first, matching the furnace door. The general
lesson: in a ladder of refusals, order by WHAT THE FACT IS ABOUT, not by how
cheap the test is -- the item-level facts have to precede the table lookups or
the specific message loses to the generic one. Bulk where
the destination rule is a dead end, paced where the stack still has a future in
the slot it is in. The old `count >= 2` anti-ping-pong guard is gone; the fit
test subsumes it. `consumeReagent` also refuses exempt items now -- it was the
one path that never checked the tag and it silently destroyed them. NOT YET
VERIFIED IN GAME.

**STILL OPEN: `moveOne` logs every hop, ungated.** MEASURED 2026-08-30: 47
lines in 9 seconds on a normal trickle, and it will do that continuously
against any large reagent backstock. It is the one message stream in this file
that is not change-gated, and sustained trickle is the ordinary case rather
than an event. Gate it or drop it to a counter before release.

**STILL OPEN: the burn-denied / reagent-denied swap deadlock** (was `D3`). Both
halves are now correctly error states under the agreed spec, so nothing is lost
-- but the burner-side branch `return`s first, so only one of the two prints a
line. Batch 2's alert state is where that gets both.

**The reagent slot now has a door and a way out.** `consumeReagent` refuses a
reagent-denied item instead of eating it, and the slot shuttle grew the mirror
of its burn-denied rescue so the stranded stock leaves for the burner. NOT YET
VERIFIED IN GAME.

**The upcycler's rule-row checkboxes were broken in two ways and are fixed.**
`applyState` was stripping `reagent` and `burn` off every rule it read, and
`x and nil or false` cannot produce nil so an untick never cleared. Both
fixed, NOT YET VERIFIED IN GAME -- see `arch.upcycler.burnbox`,
`fact.tooling.andnilor`, `fact.pane.checkedpostoggle`.

**Pathing.** Untouched this session. The jump loop fix is holding.
`smallJumpMultiplier` is 0.70711.

**A CARGO LOSS WAS REPORTED AND NOT REPRODUCED** (previous session). Nothing
recurred. `CARGO_TRACE` is left ON in `petports_petport.lua` to catch it.

**Debug flags, all ON, all wanting review before release.** `TASK_DEBUG`,
`VENT_DEBUG`, `DEBUG` in all four panes, `FLY_POINT_DEBUG`, `DRAW_PLAN`,
`FLY_TELEMETRY`, `DEBUG` in petportconfig, and `CARGO_TRACE` in the petport
object. `PETPORTS_FILTER_DEBUG` is OFF and should stay off. The TIDY +1 line
and the shuttle lines are always-on by design -- both are rare and are the only
verification those systems have until their consumers exist.

## ARCHITECTURE

### Restock beacons — BUILT, and the design that survived contact
`arch.beacon.restock`

Factorio's requester chest names what it wants and the network delivers. Our
deposit beacons never ask for anything: units bring things and the filter says
yes or no. A restock beacon is therefore a genuinely new capability rather than
a filter feature, and it got **its own beacon type**.

**A separate beacon, not a mode on the deposit beacon.** Restocking is per ITEM
and a filter is per CATEGORY; bolting quotas onto subgroups would bend the
schema to do a job it is not for. More importantly it keeps
`petports_filterAccepts(filter, name)` a pure function of its name, which is the
property that lets it be memoised — and "yes, up to a thousand of them" is not a
fact about a name.

**ONE BEACON, MANY REQUESTS.** It shipped as one item per beacon first. The
obvious workaround for "all my building materials in one box" — several beacons
in one crate — fails on exactly that case: twenty materials would need twenty
beacons AND twenty stacks competing for the same chest slots. So the beacon
carries an ARRAY of `{ item, min, max }` under `petports_beaconRequests`.

The three older keys `petports_beaconItem` / `Min` / `Max` are still READ by the
port and still listed in the beacon's `FIELDS`. The port falls back to them, so a
beacon configured under the earlier build keeps working untouched; the pane
migrates it to a one-entry list on open and the same write names the three keys
in its clear list. **A field dropped from `FIELDS` is a field nothing can ever
remove again** — it would sit in the save forever with the port still finding it.

**MIN AND MAX, NOT A SINGLE QUOTA.** One number thrashes: fetch one, drop below,
fetch again. Min is when to start, max is when to stop, and the gap is what
stops a unit making forty one-item trips.

**Min above max is a DEFINED state, not an error.** The fetch computes
`max - have`, which is zero or negative once the crate is at max, so it settles
at max and stops. The pane allows the configuration and says what it will do,
rather than clamping — see "the clamp that needed a timer" below.

**Naming the item: an itemslot that SAMPLES.** Vanilla's mech assembly reads
`player.swapSlotItem()` and genuinely STORES the part. A restock beacon needs a
NAME, not an item, so the slot samples and the player keeps their sample. That
also sidesteps the whole "give it back when the pane dies badly" problem the
deposit beacon needed `dismissed()` plus a heartbeat for — sampling has nothing
to give back. `player.setSwapSlotItem(swap)` is still re-asserted afterwards,
unconditionally, because "vanilla does the swap in Lua so the engine probably
does not" is not verified and the failure it would hide is a player's item
disappearing.

**HOTBAR ONLY, AND THIS IS NOT A CHOICE.** Starbound locks the inventory's
category tabs while anything is on the cursor — the rule that stops a rifle
being parked in a food slot. A beacon held on the CURSOR can therefore only ever
see items in its own category, which rules out most of the game. The pane
detects that case and opens as a refusal notice instead. The test is by name and
has one known hole: one beacon on the hotbar and a second on the cursor is
refused when it should not be. Fixing that needs a way to ask which hotbar slot
is selected, which this mod has not verified exists in retail.

That check lives in the PANE, not in `activate()`, because an activeitem script
has no `player` table and cannot read its own swap slot.

**Two work generators, no changes to `petportsTaskAction.lua` at all.**

`restockDeliverWork` sits ABOVE `depositWork` in `findWork`, for the third time
in this file and the same reason as `replantWork` and `waterWork`: deposit fires
on ANY cargo, so a unit that just fetched 500 hazard blocks for a request crate
would otherwise carry them to the nearest deposit beacon — and then fetch them
straight back out. Every individual task succeeds and nothing in the log looks
wrong. It reuses `type = "deposit"` with an `only` field the report handler
branches on, so the unit's side is the proven walk-and-stand path.

`restockFetchWork` sits at the bottom beside tidy. It reuses `type = "withdraw"`
outright. One request per trip; a crate naming twenty materials produces twenty
sequential trips.

**A restock crate is never a SOURCE.** Only deposit beacons are searched for
stock, so two request crates cannot drain each other — the handoff's old "two
crates with a quota never trade" rule costs no code, it is structural. Eviction
goes out through `depositWork` into ordinary storage, and if a second request
crate wants that item it fetches it from there like anything else.

**Overstock did NOT come for free, and the old note here was wrong.** This
section used to claim above-max costs no new code because `tidyWork` would
already see it. True while restock was a MODE on the deposit beacon; false the
moment it became its own behaviour, because everything in `tidyWork` iterated
`petports_beaconsFor("deposit")` and a request crate is not in that list.
`petports_restockMisfits(requests, items, exemptSlot)` is the sibling predicate:
anything no request names is a misfit outright, and a requested item is a misfit
only in EXCESS of its own max. Duplicates resolve first-wins in array order.

**One beacon decides a container**, still. `scanContainers` takes the first
ENABLED beacon in slot order and breaks, so a crate is a deposit target or a
request crate, never both. That falls out of the existing scan rather than being
enforced anywhere — and it is slot-order dependent if someone puts both in one
crate: no error, no warning, the top one wins.

### Filter beacons -- slot order is the syntax
`arch.beacon.slotorder` -- see also `arch.filter.matchers`

SPECIFIED, NOT BUILT. A container's behaviour should be readable as an ORDERED
CHAIN of beacons rather than a single flag, with the container's own slot order
supplying the sequence:

    slot 0   deposit beacon          this crate is a deposit target
    slot 1   allow-all beacon        default: take anything
    slot 2   deny-specific beacon    ...except these

The result is a crate that accepts everything on a denylist basis. Swap the last
two and it is an allowlist. Rules compose in the order the player arranged them,
which is a thing a player can see and rearrange with a mouse, rather than a
config screen they have to be told exists.

**Nothing blocks this except the filter lists themselves** -- how an allow or
deny beacon acquires the items it names. Candidates, none chosen: dropping an
item onto the beacon, a configure-on-use screen (the beacon is already an
`.activeitem` for exactly this reason), or reading the names off a second
container. To be experimented with rather than designed on paper.

**TWO THINGS IN `scanContainers` HAVE TO CHANGE FIRST, and both are
load-bearing.** It walks `world.containerItems` with `pairs` -- correct for
skipping the holes empty slots leave, WRONG for ordering, and pairs order is
nondeterministic, so slot order is currently not observed at all. Collect the
keys, sort them numerically, then walk. And it `break`s at the FIRST beacon it
finds, which is right while one beacon decides a container and wrong the moment
a chain exists.

**A filter beacon is not a behaviour beacon.** Only the first beacon in the
chain names what a container IS; the rest modify it. If `beaconBehaviorOf`
returns a behaviour for a filter, then a crate holding only a deny beacon
becomes a deposit target by accident. Filters want their own config key, or a
value the container scan recognises as a modifier rather than a role.

### Task 3 — collecting item drops
`arch.cargo.collect`

**This is the first real task, ahead of sorting and harvesting.** It is the only
one of the three that drags no unresolved decision in with it: sorting needs the
empty-graph bootstrap answered and cycle detection built, and farming still owes
a sweep policy for orphaned replant intents. Drops need neither.

(That was written when farming's blocker was believed to be an API spike, then
a farmable-to-seed lookup. It is neither: planting is `world.placeObject`, the
seed and the crop share one name, and whether a crop survives harvest is
readable from its `stages` config. See Task 2.)

Gather item drops across a designated area. Discoverable with a single world
query over the coverage rect, no wiring, and the claim key is the drop's own
entity id. The despawn deadline on item drops exercises claim expiry for free
rather than requiring a contrived test for it.

Motivated by monster farming, which vanilla supports poorly. The only
vanilla-friendly design — a mother poptop pen funnelling offspring into a
one-tile lava channel — requires the player to stand still to benefit, which is
not engaging. Other mods solve this with vacuum objects; a collector unit does
it in a way that fits the rest of this system.

**The sink is staged.** A collection task is "claim, path, pick up, dispose",
and only the last step varies:

1. **Delete the item.** What testing uses. Avoids clutter accumulating in an
   inventory or a box across repeated runs, and the eat path already has the
   code for destroying an item.
2. **Deposit into the petport.** Where it probably lands, since the port UI is
   being rewritten anyway.
3. **Route through crates.** Once sorting exists.

### Stack compaction — built
`arch.cargo.compaction`

One item's worth of something across more slots than it needs is an artifact,
and a bot can fix it. It surfaced from eviction: a crate holding 2 hazard blocks
took a delivery of 1000, the 2 became overstock, and `withdrawMisfit` consumes BY
NAME AND COUNT — so the engine took its 2 off the front of the thousand-stack
and left 998 + 2. Right total, wrong shape.

**Fixing the slot selection would stop one source; compaction stops all of
them**, including the player putting two half stacks in a chest by hand.

**Consume the whole NAME, add back per DESCRIPTOR.** That order is what makes it
safe without knowing how `containerConsume` matches. `Item::matches` takes an
`exactMatch` flag and which way `containerConsume` passes it is unverified. If it
matches by NAME, the single consume takes every stack of that name — exactly what
was intended, since all of it goes back bucket by bucket with its own parameters.
If it matches EXACTLY, a bare descriptor cannot account for parameterised stacks,
the consume fails all-or-nothing, and nothing moved. What is impossible either
way is taking a parameterised stack and handing back a bare one.

**Bucketed by parameters, hashed first.** Betabound's `sb_musicsheet` is one item
name with one parameter block per song, and a collector fills a crate with sixty.
Matching each slot against every bucket is quadratic there, so the parameter
block is serialised once via `sb.printJson` and used as a table key, with a deep
compare consulted only to CONFIRM a hit. Measured: 60 unique songs went from 1770
deep compares to 0; 20 songs across 3 slots each from 610 to 40. Correctness
never rests on the hash — a collision is caught by the deep compare, and two
equal blocks that somehow serialised differently would land in separate buckets
and report the crate as already compact. A missed merge, never a wrong one.

**Key-present-with-null is NOT key-absent**, and the deep compare says so. A
stamped null is stuck, so such an item genuinely will not merge.

**Compaction runs two ways.** After every port-side container mutation, which
costs no trip; and from `compactWork`, the lowest-priority generator in
`findWork`, for crates nothing else visits. One crate per trip, all its
fragmented items merged on arrival.

**`compactWork` has NO `workFailures` backoff**, unlike every other generator
here. If `needed` were ever too low the crate would still read as fragmented
after a merge that could not fix it, and a unit would walk back every idle tick
with each pass logging a success. That is instrumented rather than defended: the
per-group line says `predicted`, and the crate is read back afterwards so a
disagreement names both numbers and what `stackSizeOf` returned.

**A backoff and a learned stack size were both written and both backed out.** The
learned-maxStack version inferred the real number from a post-compaction read —
and that read can catch a crate the PLAYER just edited, which would cache a wrong
small value and silently stop the network compacting that item forever. See the
traps section: the bug it was built for did not exist.

### Deposit
`arch.cargo.deposit`

`findWork` order is **recall -> deposit -> collect**. A unit holding a load has
one job; letting it collect more first is how a unit hoards instead of ferrying.
Below the recall ladder, because a stranded unit cannot reach a crate either.

**Task ids are `deposit:<container>@<port>`.** Keyed by container ALONE first
time round, on the reasoning that serialising deposits into one chest cost
nothing. It cost five units: claims are exclusive, so the first port to claim
`deposit:24` owned the crate outright and every other port was refused. Their
units got no task, fell back to station-keeping, walked a couple of tiles toward
their ports, were re-dispatched, and were refused again -- a two-tile shuffle that
looked exactly like a pathfinding fault. There is nothing to serialise;
containerAddItems returns its own overflow per call.

**Partial deposits are not special-cased.** Whatever the container refuses stays
on cargo, the container goes into `CONTAINER_FULL_BACKOFF` (60s), and the next
dispatch picks a different beacon. Same path as a chest being full outright, so
there is one behaviour to test rather than two.

**The port does the transfer, not the unit.** Cargo has been on petData the whole
time and never needs to exist anywhere else, so there is no second loss window.

**Standing points are resolved BY THE UNIT.** `petports_standingPointNear` in the
contract uses findGroundPosition + validStandingPosition -- the same test the
pathfinder uses. The port cannot answer this: validStandingPosition tests the
unit's BOUNDING BOX, and boundBox comes from mcontroller, which objects do not
have. The port's own findStandingPoint tests a POINT, and the two disagree
systematically: findStandingPoint wants the tile under the point solid,
validStandingPosition wants the tile under the BOX solid, and the box bottom is
boundBox[2] below the point. For boundBox[2] = -0.375 those are contradictory.
Every standing position a unit occupies ends in .375; the port was handing out
integers, so the deposit target was rejected before pathing started and the whole
route failed with it -- reading in the log as a vent failure.

### Task 1 — sorting
`arch.cargo.sorting`

A petport is wired to a crate; that crate is where the unit collects. Crates
wire onward to further crates, forming a directed routing graph. Status lights
on crates report their own routing status; the feeder's light reports fullness
only, and the two are not the same convention.

**Role is positional, not a property.** A crate is a pickup point because a
petport wires into it, and a destination because another crate wires into it.
The object has no mode setting — "output box" is a misnomer, since a crate can
be both. This is why crates chain.

**Routing rule:** an item goes to a downstream crate that already contains that
item and has room. Following Minecraft's copper golem in spirit, diverging in
failure handling — a unit with nowhere to put something chirps to alert the
player rather than standing inert until someone notices.

**Open decision — the empty-graph bootstrap.** "Deliver where the item already
lives" cannot match anything in a freshly built setup, so the first run alerts
on everything and moves nothing. The diagram's bacon routes correctly only
because the destination was pre-seeded. Three ways out, none chosen: a stated
seeding convention, a filter slot on the crate that declares intent without
holding stock, or a last-resort fallback to any downstream crate with space.
Whichever is picked, it needs to be discoverable in-game — a system that works
only if you already know the trick reads as broken.

**Cycles.** A directed graph the player wires by hand will contain loops. Needs
either cycle detection during traversal or a hard hop limit.

### Tidying and auto-disperse — built
`arch.cargo.tidying`

`tidyWork` walks every deposit beacon, asks `petports_filterMisfits` what does
not belong in it, and dispatches a `tidy` task to pull one misfit stack out. The
unit only walks and stands; `withdrawMisfit` on the port does the transfer on
report, the same shape as `withdrawSeed`. It consumes by name and count rather
than slot, because a player rearranging the crate between dispatch and arrival
invalidates the slot; the slot rides along only so the log can say where the
misfit was seen. `depositWork` then routes the stack normally on the next tick.

**Disperse needs no code.** A dropbox is a deposit beacon whose filter accepts
nothing — `base: "deny"`, no allow rules — so every stack in it is a misfit and
it empties outward by tag. It also cannot loop, because its own filter rejects
everything and it can never be its own destination.

**Both halves are checked before anything moves.** Some other beacon's filter
must ACCEPT the stack, and `world.containerItemsCanFit` must say that crate has
ROOM for the actual descriptor. Where the engine will not answer, tidying treats
that as no — deposit falls back to a time-based backoff because it is holding
cargo it must place, and tidying has the luxury of waiting.

**The room check is the player-facing decision, and it is about not wasting a
unit.** Tidying into a full network means the unit picks the stack up,
`depositWork` finds no target, and the cargo guard in `findWork` then blocks
collection, harvest, animals and fetching outright — one misfiled stack takes a
unit out of the working pool and stalls everything it would have done. Someone
mid-reorganisation of their base should not have to think about that, so full
storage simply postpones defragmenting until there is space. It is also the
deadlock `withdrawWork`'s header describes, arrived at from the other direction.

**Lowest priority in `findWork`, below even fetching.** A drop on the ground is
on a despawn timer; a misfiled stack is in a box and will be exactly as misfiled
in a minute. One stack per trip is the standing design, so a crate with forty
misfits produces forty sequential trips rather than forty tasks.

**Known cost:** `tidyWork` calls `world.containerItems` per deposit beacon per
work tick. It only runs when nothing else has work, so an active network rarely
reaches it, but an idle one with many crates scans them every second. The fix if
it ever shows up is a timer like `refreshBeacons` uses, not anything structural.

### The census must count cargo in transit
`arch.dispatch.census`

A census built from CONTAINER contents drops by exactly the amount a unit picks
up. A network holding 6,000 of something reads as 5,000 while a unit carries the
other 1,000 toward a machine — so a 5,000 threshold says "no longer surplus" and
the unit walks the whole way there and carries it back.

Any threshold test evaluated while a unit holds cargo must add the carried stack
back. And deliver only the SURPLUS portion rather than all-or-nothing: a unit
carrying 1,000 into a network 400 over its threshold delivers 400 and keeps 600.

### `petports_claimRelease(workId, nil)` releases regardless of owner
`arch.dispatch.claimrelease`

The owner check is `if ownerId ~= nil and claim.owner ~= ownerId`. Passing nil
skips it. That is what makes priority stealing possible without a new API:
`petports_claimTake` refuses outright when someone else holds a live claim, so
outranking it means releasing first.

`petports_claimRefresh` writes the ENTIRE claim registry to a world property on
every call. Fine for a handful of long-lived work claims; not fine for anything
per-item refreshed on a fast timer. Renew lazily, only near expiry.

### Work claims
`arch.dispatch.claims` -- see also `dd.dispatch.claimscope`, `arch.dispatch.claimrelease`

Units broadcast what they are doing into `world.properties` so that two units
never chase the same job — "collecting 50 lightbulbs from the crate at
(410, 389), these are spoken for."

**Key claims by the WORK ITEM, not by the pet or the port.** A drop's entity id
is naturally unique. This is what makes the pet-swap case work: yanking a
fuelled unit out of one port and socketing it into another mid-task releases and
re-claims cleanly, with nobody tracking which port owned what.

**Nothing durable is keyed on a network.** Cluster identity is derived and
renumbers whenever a port is placed, removed, or re-ranged, so anything
persisted under a cluster key is orphaned the first time a bridge appears. Ports
have stable identity; clusters never will.

**Unit identity is `uniqueId`, and it works because WE assign and persist it.**
Not because the engine preserves anything across a respawn — a respawned monster
is a new entity with a new entity id. Stored on the item alongside `seed` and
reassigned at spawn, a claim survives the round trip. The bounty and quest
systems assign uniqueIds to NPCs the same way.

Serial numbers for character ("unit #4142") derive from `seed`, NOT from a
counter in `world.properties`. A per-world counter renumbers a unit every time
it is carried to a new planet, which destroys the only thing the number is for.

Remaining requirements, none optional:

- **Claims must expire.** A unit that dies, unloads, or is recalled mid-task
  leaves its claim behind. Without a TTL or a heartbeat, one interrupted job
  poisons that item or container permanently. Interruption is the normal case
  here, not the exception.
- **Sweep stale claims on world load**, since a world unload orphans every
  claim held at that moment.
- **Keep the structure small.** This is replicated state written frequently.

### The leash: three bugs, and only one of them was the symptom
`arch.dispatch.leash`

A port had platforms directly beneath it. Removing them made the unit walk to
where the platforms had been, fail, try a vent route, and eventually get
re-homed. Three separate faults, all latent, all needing that terrain edit to
surface — and the one that produced the visible symptom was the last found.

**`freshPather` was a nil global.** See the engine traps section. This is what
produced the re-homing: an exception in `update()` on one branch of
`tryVentRoute`.

**`groundTarget` was cached for the life of a hold task.** Every place that
clears it hangs off a MOVEMENT event — starting a vent leg, exiting a vent,
stepping to the next watering tile. A unit parked at its port triggers none of
them, so a leash held the floor it resolved on arrival forever. Now cleared on
arrival and on push-off, with `onStation` reset too — without that, only the
FIRST arrival would ever clear it.

**`return` was missing from the list of task types that resolve their approach
target, and THAT was the loop.** A leash ran its arrival test against the raw
port position. A port is a 4x4 object and its origin is inside itself; nothing
can stand within `ARRIVAL_DISTANCE` of it unless the floor happens to be close
underneath. Measured: port origin `[1203,708]`, floor `[1203.5,704.8]`, unit
parked at `[1202.9,704.8]` — 0.6 from where it belonged and 3.2 from the port,
against an arrival radius of 1.5. It never arrived, the progress watchdog struck
it for moving 0 of a required 2.5 tiles, and it replanned through the vents 129
times in 11 seconds.

**ROUTING WAS ALWAYS CORRECT, WHICH IS WHY IT LOOKED LIKE A PATHING BUG.**
`routeTarget` already resolved through `approachTargetFor`, so `planRoute` named
the right tile and the unit walked to exactly the right place. Only the question
"are you there yet" was asked about somewhere else. **The giveaway in a log is
`planRoute` naming one position while `approach ... target` names another.**

All three hid for the same reason: with platforms two tiles under the port the
floor sat 1.2 from the origin, inside the arrival radius, and everything worked
by luck.

### Union dispatch and the leash
`arch.dispatch.union`

**Every port scans the whole network's coverage**, not just its own rect. Queues
stay port-owned -- nothing durable is keyed on a cluster, because cluster
identity renumbers -- but a union is a VIEW assembled at dispatch time, and the
scan is that view.

**Distance arbitrates.** Without it, every port with a free unit races for the
same drop and the claim decides arbitrarily. A port skips work when another
member's free unit is nearer. Distance is measured from the UNIT, since it is
the unit that walks.

**Walls are ignored deliberately.** True reachability comparison would mean
pathfinding per candidate per drop, which is enormously more expensive than the
occasional wrong pick -- and a wrong pick self-corrects, because an unreachable
target fails fast and backs off.

**The leash bounds where a unit goes on its OWN INITIATIVE, not where a path may
lead.** A unit executing a claimed task follows wherever the route goes; an idle
unit stays inside its network. That distinction is what makes it cheap: no
inspecting waypoints against rects, no aborting mid-route when a jump arc clips
outside.

The unit never learns that networks exist. It receives a list of rectangles and
its home position, and one rule. Scoring: work 150, leash 120, appetites cap at
100 -- so coming home beats wandering but never interrupts a task.

**Anything asking "is the unit where it belongs?" means NETWORK, not port.** The
port's own rect is correct only for discovering new work and for keeping its
region resident. Testing strays against it marks a unit wayward the moment it
does exactly what union dispatch told it to.

### Animal harvesting -- BUILT
`arch.farming.animals`

Farm animals are far simpler than crops, because they are SCRIPTED MONSTERS
where farmable objects have no script at all.
`/scripts/actions/monsters/farmable.lua` defines `hasMonsterHarvest` and
`dropMonsterHarvest` as plain globals in the monster's environment, and
**neither uses its `args` or `board` parameters** -- they are declared
`(args, board)` and ignore both. So both are callable out of band with no
arguments:

    world.callScriptedEntity(id, "hasMonsterHarvest")   -- false / true
    world.callScriptedEntity(id, "dropMonsterHarvest")  -- spawns AND resets

**`dropMonsterHarvest` calls `resetMonsterHarvest` itself**, which removes the
obvious exploit. Faking the harvest with `world.spawnTreasure` from
`harvestPool` would leave `storage.lastHarvest` untouched and the animal
permanently ready -- infinite produce. We never touch the timer, so we cannot
corrupt it.

Produce lands on the ground at the animal, so collection and deposit take it
from there unchanged, exactly as with crops.

**Verified by asking again, not by the return value.** `callScriptedEntity`
returns nil silently for a missing function, so nil is indistinguishable from a
call that ran and returned nothing. A successful poke flips `hasMonsterHarvest`
to false immediately, and the animal is its own authority.

### Replant intents
`arch.farming.intents`

The mechanism: on harvesting a crop with no `resetToStage`, write a
**replant-this-tile-with-this-seed-if-available** record into `world.properties`
before the farmable disappears. A unit picks it up as ordinary claimable work
whenever a matching seed exists in network storage.

**It self-invalidates on world, not on a clock.** Two conditions clear a record:

  - **any object now occupies that FOOTPRINT.** Farmables are objects too, so a
    successful replant clears its own record by existing — and the same check
    stops a unit trying to plant a potato inside a crate the player set down in
    the middle of their field. One test covers success and interference both,
    which is why it is the right test. Note the footprint is TWO TILES, anchored
    at the bottom: a potato occupies `[0,0]` and `[0,1]`, so checking the anchor
    tile alone will happily plant into something hanging one tile up.
  - **the tile is no longer tilled.** The player dug it up or repurposed it, and
    the intent died with the ground.

**This is deliberately NOT a claim and must not inherit claim TTLs.** Claims
expire because an interrupted unit would otherwise poison a work item forever.
A replant intent is a persisted statement of what the player had growing there,
and it should survive a week of the world being unvisited — a field that
forgets itself because nobody logged in is a worse failure than a stale record.
State invalidates it, time does not.

**It never blocks.** No seed in storage means nothing happens and the tile
waits, the same "routed around, not blocked on" rule fuel already follows. A
player who stops stocking potato seeds gets an empty tile, not a stuck unit.

**What goes in the record is the object's own name**, read off the farmable
before harvesting it. The seed and the crop share a name, so there is no lookup,
no reverse index, and nothing that can go stale. `potatoseed` in, `potatoseed`
out.

### Modded soil support, mostly arrived early
`arch.farming.moddedsoil`

The recorded plan was that modded soils were out of scope for v1, with one line
of discipline to keep them cheap later: read `tillableMod` off the material
config rather than hardcoding 32. Watering overtook that without meaning to.

  - **Watering**: modded soils work today. `soilInfo` reads whatever matmod is
    on the tile.
  - **Replanting**: `replantGroundTilled` used to compare names against
    `"tilled"` and `"tilleddry"` literally. It now asks `soilInfo` for the
    `tilled` flag, so modded soils work there too.
  - **Tilling**: still entirely unbuilt, and the only place `tillableMod` would
    matter. The player tills their own dirt; the mod sustains it.

**DO NOT COPY HARVESTERBEAM'S TILLING TEST.** It gates on `.soil`, which is the
SAPLING flag, where `tillableMod` is the hoe flag. Vanilla dirt declares both so
the mistake is invisible on vanilla and would bite on any modded material
declaring one without the other.

### Replanting -- BUILT AND VERIFIED
`arch.farming.replant`

Storage-first, by explicit decision: the harvest drops its seed, ordinary
collection carries it to a crate, and only then does a unit fetch it back out.
The round trip is the point -- every seed is accounted for in storage, so a
player who wants seeds for food or crafting takes them before the network spends
them on replanting.

Two new task types, one new persisted structure:

    withdraw   unit walks to a deposit crate holding the seed; the PORT calls
               world.containerConsume on arrival and the seed lands on cargo
    replant    unit walks to the intent's tile and calls world.placeObject;
               the port spends the seed and clears the intent on the report

    world.properties["petports_replants"][tileKey] = { name, position, owner,
                                                       created }

**The container call is port-side, matching deposit exactly.** `depositCargo`
already runs on the port when the unit reports arrival, so `withdrawSeed` is its
mirror and the unit needs no container primitive of its own. `withdraw`
therefore needs NO act on the unit at all -- it walks, dwells, reports, and the
existing fallthrough handles it.

**`containerAvailable` for discovery, `containerConsume` to take.** Consume is
all-or-nothing on the full count, which is exactly right for taking one, and
Available asks the same question Consume will ask on arrival rather than
guessing from `containerItems`.

**Seeds come out of DEPOSIT beacons.** Reusing that list means a player who
moves their storage does not also have to tell the replanting system about it.

**FINDWORK ORDER IS NOW:** recall, replant, deposit, collect, harvest,
withdraw.

  - **replant above deposit** is what makes the task possible at all. Deposit
    fires on ANY cargo, so a unit holding a seed would carry it past the tile it
    belongs in. The rule is narrow -- replant wins only when the cargo IS the
    seed an outstanding intent names -- which also makes it self-healing: if an
    intent is invalidated while a unit carries its seed, the match stops
    holding, deposit takes over, and the seed goes back to storage.
  - **withdraw last, below harvest**, because it is the only task that
    MANUFACTURES cargo rather than clearing something. Drops despawn and crops
    occupy space; an empty tile does neither. The visible consequence is that a
    busy base replants slowly, which is correct.

**The intent is written by the PORT, on the harvest report**, gated on
`world.entityExists(target)` coming back false. That single test is the whole
resetToStage distinction without reading any config: a crop that reset is still
there, a crop that was destroyed is not.

**UNVERIFIED AND HEDGED: which tile holds the soil.** The check for "is this
ground still tilled" reads the matmod at `y - 1`, since a crop stands ON tilled
dirt -- but that rests on an assumption about where `world.entityPosition` sits
for an object. Getting it wrong is not a small bug: the sweep would clear every
intent within five seconds as "ground no longer tilled" and replanting would
silently never happen. So the check accepts a tilled mod at EITHER tile and logs
both on failure. One look at a real field settles it, and the wrong guess costs
nothing meanwhile.

**CONTENTION, traced rather than assumed.** Two units, two intents, one seed
crate:

  - **Both legs are claim-checked at SELECTION, not just at dispatch.**
    `dispatchWork` does refuse a claim already held, but that refusal lands
    after selection has committed to an intent -- so a second port would
    propose the same withdraw, be rejected, return no work, and propose it
    again next tick forever, never reaching the other intents in the list. It
    now skips to the next intent instead. **This was a livelock and it is the
    reason a second unit would have looked idle rather than busy.**
  - The two legs have DIFFERENT work ids, so the withdraw check also has to
    look at `replant:<key>`. Otherwise a port fetches a second seed for a tile
    another unit is already walking one to.
  - **`replant` honours the failure backoff, and it is the one work type that
    genuinely needs it.** Every other task has its precondition consumed by the
    attempt -- a drop is taken, a crop is harvested. A failed replant changes
    nothing: the unit still holds the seed, the intent still exists, the match
    still holds, so the port would re-dispatch the identical task on the next
    tick and the unit would retry a refused placement several times a second.
  - **A player emptying the crate mid-walk is recorded as a failure**, despite
    the unit having done exactly what it was asked. It walked there and
    reported done, and done CLEARS the failure record -- so a persistent
    disagreement between `containerAvailable` and `containerConsume` would
    shuttle a unit to an empty crate forever with nothing in the log looking
    wrong. Normally the disagreement is transient and self-resolving; the
    backoff is for when it is not.

**Note corn cannot exercise any of this.** Corn has `resetToStage`, so it never
leaves a hole and never produces an intent. Replanting only ever runs on
one-shot crops -- carrots, potatoes, oculemons.

**VERIFIED IN GAME.** `world.placeObject` does work from a monster script.
Placement is confirmed by querying the footprint afterwards rather than by
trusting the return value -- the same discipline the harvest swing uses, and
for the same reason. Crops of arbitrary width replant correctly, and the
harvest/replant cycle survives vent traversal in both directions.

**FOOTPRINTS COME FROM THE SEED'S OWN CONFIG, not from an assumption.**
`root.itemConfig(seedName).config.orientations[1].spaces`, cached per name. The
first version hardcoded 1 wide by 2 tall, generalised from `potatoseed` -- and
that was wrong for every wide crop AND wrong in both directions at once, which
is why it produced inconsistent symptoms rather than a clean failure:

  - the CLEAR check missed blockers standing in the column it never looked at,
    so a wide crop was dispatched into occupied space and `placeObject` refused
  - the POST-PLANT check looked for the new crop in tiles it might not occupy,
    concluded the planting had failed, and fed the backoff ladder

That second one presented as "it gave up trying to replant the oculemon".

The fallback when the config cannot be read logs loudly, because past that point
occupancy is a guess.

**OCCUPANCY IS EXACT, NOT A BOUNDING-BOX OVERLAP.** `world.entityQuery` returns
anything whose bounds INTERSECT the rect, and a rect drawn tightly around one
tile touches the edge of the next. In a planted row -- crops at x, x+1, x+2 --
every tile reported itself occupied by its neighbour, and MEASURED, nine replant
intents were written and seven destroyed within four seconds as "footprint
occupied". Query wide, then filter with `world.objectSpaces`, which gives an
object's real occupied tiles relative to its position. Vanilla's own
`pathutil.objectBounds` reads them the same way.

**MEASURED: STORAGE-FIRST IS BYPASSED ROUGHLY NINE TIMES IN TEN.** One `withdraw`
for nine replants in a representative run. A seed picked up off the ground
matches an outstanding intent immediately, so replant outranks deposit and the
unit plants it without ever visiting a crate -- the on-the-spot replanting that
was deliberately deferred, arriving for free out of the ordering rule.

That is not obviously wrong; it is a shorter walk and the field still ends up
planted. But the accountability property the storage-first decision was FOR --
seeds land in storage so a player can take them for food or crafting before the
network spends them -- now holds about a tenth of the time, and which case you
get is decided by pickup order.

If strict storage-first is wanted later, the change is small: set a flag when
`withdrawSeed` puts a seed into cargo and require it in `replantWork`, so a seed
that arrived by collection is ordinary cargo and only a deliberately withdrawn
one plants.

That decision is what makes v1 cheap, and it is worth seeing why: once the crop
is harvested, the drops on the ground are ORDINARY DROPS. Collection, cargo,
stack merging and deposit all already exist and are verified working. So the new
code is a discovery pass and one act — everything downstream is a pipeline that
has been running since drop collection landed.

1.  **Find a farmable in coverage at its harvest stage.** `world.farmableStage`
    filters and tests in one call. The stage carrying a `harvestPool` is the one
    to wait for. UNVERIFIED whether stage COUNT varies enough between farmables
    to matter — potato has three stages and corn four, so the check must be "is
    this the harvest stage", never "is this stage N".
2.  **Harvest it** with a `world.damageTiles` call on its tile — see above — and
    allow a beat before anything expects drops to exist.
3.  **Stop.** The existing collect and deposit tasks take it from there,
    including the seed.

Deferred out of v1, and all but one has since landed:

  - **Replanting from storage** — BUILT, see below.
  - **Replanting ON THE SPOT** — arrived for free out of the `findWork`
    ordering, which was not the plan. See the measurement in the replanting
    section.
  - **Re-wetting decayed tiles** — BUILT, see the watering section. The
    consume-item-produce-liquid primitive turned out not to be needed at all.
  - **Animal produce** — still unspecified, still the only piece outstanding.

**WHY ON-THE-SPOT REPLANTING IS NOT FREE, and why it is not in v1.** `findWork`
orders recall, then deposit, then collect, and deposit fires on ANY cargo. A
unit that picks up a seed is a unit with cargo, so the next dispatch sends it to
a crate — it would carry the seed past the hole it came out of. Fixing that
means either the harvest task owning harvest-collect-replant as one uninterrupted
sequence, or a replant branch above deposit in `findWork`. The first is more
consistent with how collect already owns its whole claim-path-act run. Neither
is v1.

**Step 3 collides with the one-slot cargo model.** A harvest can drop several
distinct items and a unit carries what is effectively one load, so either the
harvester takes ONE of them and leaves the rest as ordinary collect work for
whoever comes along next, or the cargo model changes. Taking one is the cheaper
answer and is consistent with the rest of the system: the leftovers are drops
inside coverage, which is a solved problem.

**Animal produce (Fluffalo, Mooshi) is still unspecified** and works differently
from crops.

No longer the least-specified of the three — that is sorting, which still owes
the empty-graph bootstrap and cycle detection. What farming owes is a decision
on sweeping orphaned replant intents, confirmation of the `fill` reading above,
and the animal-produce question. Everything else here is readable from configs
rather than guessed at.

### The act is a projectile, and the projectile is a blank
`arch.farming.sprinkle`

`world.spawnLiquid` needed up to FOURTEEN attempts to saturate one tile. It is
tuned for rain, not gardening. `applySurfaceMod` is exact and lands once, so
watering never spawns liquid at all -- the item is a cost token, consumed, and
the mod is applied directly.

`projectiles/lofty_petports/petports_watersprinkle/` ships with an EMPTY
`actionOnReap`. The caller supplies the transition per cast:

    world.spawnProjectile("petports_watersprinkle", spawn, entity.id(),
      {0, -1}, false, {
        actionOnReap = { { action = "applySurfaceMod",
                           previousMod = <read off the tile>,
                           newMod      = <resolved from transformModId>,
                           radius      = 0 } },
        processing = "?multiply=" .. <tint>
      })

**CONFIRMED: projectile parameters DO override `actionOnReap`.** That was the
one assumption the whole modular approach rested on. One asset covers vanilla
and modded soils; vanilla's own `watersprinkledroplet` hardcodes a single pair
in its config and needs one projectile per soil type.

**The droplet wears the liquid's own colour.** The sprite is transparent white
and `processing` paints it, with the colour read from the liquid config -- so
water is blue and lava would not be, with no table anywhere in this mod. ALPHA
IS FORCED OPAQUE: a liquid's alpha describes how a BODY of it renders (water is
128) and would leave a three-pixel droplet nearly invisible.

### The sweep is the first multi-stop task
`arch.farming.sweep`

Every other task walks to a place and does a thing. Watering walks a LIST, in
order, and **the order is the feature** -- watering a forty-tile row in
discovery order looks like a malfunction rather than gardening.

  - The port expands left and right from the crop, builds an ordered run, picks
    whichever END is nearer the unit, and hands over the list reversed if
    needed. The unit sweeps away from that end and never reverses.
  - The list is capped at `WATER_CARRY`, which is also how many units the unit
    fetches. That bounds the task: a forty-tile row becomes four sweeps rather
    than one task that outlives `TASK_DEADLINE`.
  - The index lives ON THE TASK rather than on `stateData`, because
    `currentTarget` is only handed the task. The task table is the unit's own
    copy, so mutating it is local.
  - Between tiles the unit clears `arrived`, the ground target and the pather,
    so arrival is re-earned per tile. Without that it waters the whole row from
    wherever it happens to be standing.

**ONE ITEM PER TILE, ONE TRIP PER RUN.** Those are separate decisions and
conflating them is how a forty-tile row becomes forty round trips to a crate.

**Discovery is anchored on CROPS, not on bare soil.** A player with a large
fallow field has not asked for it to be watered, and scanning all of coverage
for dry farmland would generate work nobody wanted. A crop on dry ground is an
unambiguous request -- it cannot grow -- and the run expansion then finishes the
row it is part of.

### Watering -- BUILT AND VERIFIED
`arch.farming.watering`

**The whole farming cycle now runs with no sprinkler infrastructure.** Crops
will not grow on dry tilled soil at all -- confirmed in game, it is not merely
slower -- so watering was the last piece standing between the mod and
hands-off farming. That is the Blue Ocean claim for this feature, and it is
stronger than "we automate farming", because sprinklers are what every other
answer looks like.

### A subgroup id that no longer exists is silently ignored
`arch.filter.exceptids` -- see also `dd.filter.groupnotsubgroup`

**SPLIT OUT OF THE ENTRY ABOVE, WHERE IT WAS A "KNOCK-ON" AND IS THE SHARPER
HALF.** A rule stored on a live beacon holds subgroup ids in `except`. An id
that no longer exists matches nothing and is SILENTLY IGNORED, so removing or
renaming a subgroup quietly WIDENS every player rule that excluded it.

Nothing warns. The rule keeps working, keeps looking correct in the pane, and
starts accepting a class of item the player deliberately excluded. This is a
migration hazard on live save data rather than a naming tidiness note, and it
constrains every future manifest edit.

### THE MANIFEST IS KEYED BY ID, NOT AN ARRAY
`arch.filter.manifestkey` -- see also `arch.filter.exceptids`

`groups` and `subgroups` are objects keyed by id. A mod patches
`/groups/species/subgroups/mycoolrace`, never `/groups/20/subgroups/-`. An index
is a promise about everyone else's file that cannot be kept — one group added
upstream silently redirects every positional patch in the ecosystem.

The cost is that Lua key order is meaningless, so display order is stated: every
entry carries `order`, ties break on id. The manifest is normalised once at
load, ids copied onto entries and ordered arrays built. **Nothing may iterate
`group.subgroups` directly** — use `petports_filterGroups()` and
`petports_filterSubgroups(group)`, or the beacon UI reshuffles between openings.

That refactor surfaced a real bug: `subgroupToggled` indexed
`shownGroup.subgroups[index]` numerically to find the clicked tile, which
against a keyed table returns nil and makes every tile click do nothing.

### Five matchers, and what each one is for
`arch.filter.matchers`

A subgroup matches if ANY of these hit — they are ORed, and one is usually
enough.

`categories` — the item's `category`, compared exactly. camelCase.
`tags` — present in `itemTags` OR `colonyTags`; the resolver merges both and
does not care which file a tag came from.
`items` — the item's name, exactly.
`suffixes` — the name ends with this. For GENERATED items that have no file to
tag: blueprints end `-recipe`, codexes end `-codex`, both confirmed in game.
Deliberately a suffix and not a pattern — a pattern field is evaluated per item
per scan and lets a mod author write something expensive into a manifest.
`nameParts` — prefix and suffix, **ANDed**. The only matcher that is not ORed.

**`nameParts` exists because of codexes and nothing else would do.** No codex
file carries a category, a tag or a race field, so the only thing identifying an
Apex codex is its name. A bare `apex` prefix would match every Apex chair in the
game; the `-codex` suffix is what makes the prefix safe. 89 of 123 vanilla
codexes are race-prefixed, so this sorts them by species with no `.patch` files
against vanilla assets — which matters because a mod adding seventy codex
entries would otherwise bury every other species in one bucket.

### A TAG SUBGROUP IS SAFE OR FATAL DEPENDING ON HOW MANY ITEMS CARRY IT
`arch.filter.subgroupor`

Subgroups are ORed. `petports_fuel` is on all eight treats, so a subgroup
carrying it beside seven per-flavor subgroups matches everything and WINS --
unticking Spicy would silently do nothing. That is failure mode 1 from the
`unclassified` header, reached from a new direction.

`petports_flavor_spicy` is on exactly one flavor's items, so the same mechanism
is not merely safe but is the RIGHT answer: it makes the subgroups mutually
exclusive, and a rarity tier added later -- a new item NAME carrying an existing
flavor tag -- sorts into the player's existing crate with no manifest edit.

Same field, same resolver, opposite outcome, entirely because of how many items
carry the tag. Count before choosing between `tags` and `items`.

### Locomotion classes
`arch.locomotion.classes` -- see also `arch.locomotion.liquidpermissions`, `ref.locomotion.chassis`

FOUR, AND ALL FOUR ARE BUILT. The design that made this cheap is that MEDIUM IS
A PERMISSION RATHER THAN A LOCOMOTION CLASS.

- **Ground** — `gravityEnabled` on, `petports_avoidLiquid` true. Vanilla's
  locomotion, with our corrections.
- **Flyer** — `gravityEnabled` false, `canFly`. Free movement in air.
- **Aquatic** — `gravityEnabled` false, `canSwim`. The SAME movement layer as
  the flyer with the opposite permission. There is no swimming code.
- **Amphibious** — `gravityEnabled` on, `avoidLiquid` FALSE. A walker that
  stops refusing water. This is the otter and it needed no transition code.

Two flags, `petports_canFly` and `petports_canSwim`, feed one predicate
(`petports_mediumAllows`) asked at every destination, every path edge and every
string-pull sample. Both false bricks the pet and is permitted -- adding a guard
would mean silently overriding an author's stated intent.

WALKERS ARE GOVERNED BY PHYSICS, NOT PERMISSION. The flags do not apply to them;
their medium is whatever they sink into. `petports_avoidLiquid` is the walker's
equivalent question and it is a different question with a different answer.
`petports_mediumAllows` short-circuits for walkers -- AFTER the forbidden-liquid
test, which applies to everything.

**WHY THE AQUATIC UNIT IS NOT A FISH.** Vanilla's swimming monsters keep gravity
on and float on `liquidBuoyancy`. They also CANNOT PATHFIND: `canPathfind` is
`onGround() or not gravityEnabled`, and a gravity-enabled actor suspended in
water is neither. Vanilla works around this by not pathfinding at all --
`swimmingMonster.lua` steers on whisker sensors and reverses when it bumps
something, which is fine for ambient wildlife and useless for a unit that must
reach a named crate two rooms away.

**WHY THE OTTER NEEDED NOTHING.** The capstone was specified as runtime
`gravityEnabled` toggling with a mode chosen per destination. It turned out the
engine's search already models the boundary -- see the traps section. What
toggling would still buy is neutral buoyancy, so the unit swims mid-water rather
than walking the bottom. That is a feel difference and it is the only reason to
revisit this.

If it is ever built: the toggle must land in BASE parameters via
`applyParameters`, because `PathFinder:start` hands `mcontroller.baseParameters()`
straight to `world.platformerPathStart` and `canPathfind` reads it directly.
`mustEndOnGround` is captured once at `PathMover:new`, which `freshPather`
rebuilds per task -- fine until a unit needs to change medium MID-task.

### Liquid permissions
`arch.locomotion.liquidpermissions` -- see also `arch.locomotion.classes`

A DENY-LIST ON THE CHASSIS, `petports_avoidLiquids`, matched by NAME through
`root.liquidConfig`.

Deny rather than allow, and the reasoning is not the usual one. An allow-list
fails closed, which is normally right -- but there are hundreds of benign modded
liquids and three or four dangerous ones, so an allow-list would break every
liquid mod on contact and demand a patch per mod. The asymmetry runs the other
way here.

INFERRING HARM FROM STATUS EFFECTS WAS CONSIDERED AND REJECTED. Deciding
programmatically whether a modded effect is beneficial is pattern-matching on
names and fails the first time someone writes `moltenimmunity`. A list is
honest about being a list.

**Still to build: permissions from PET UPGRADES.** The intent is a pet
equivalent of a poison block augment -- grant one and the unit works a poison
ocean with no further configuration. That has to live in `petData` on the ITEM,
because that is the only thing surviving despawn, unsocket and world reload, and
it is already where per-unit state like `crosshairColors` lives. The resolved
set is chassis defaults merged with item grants, cached alongside
`petports_media()`.

### Modules live on petData and the slot is a display
`arch.module.slots` -- see also `dd.module.slotsbyrarity`, `fact.pane.itemslotbutton`

A module belongs to the PET, not the port. Unsocket a kitted unit, carry it to
another port, and the modules travel with it -- container slots on the port would
strand them. So the itemslots are display fed by `setItemSlotItem` and the
descriptor lives on `petData`.

This is the one place an itemslot is the right widget rather than a workaround:
vanilla's only real-inventory use of it is the mech assembly station, where every
part is NON-STACKABLE, and a module is the same shape.

**WHICH MAKES `maxStack : 1` A REQUIREMENT ON THE MODULE ITEMS.**
`player.swapSlotItem()` returns the WHOLE cursor stack and mechassemblygui does
not clamp it, because mech parts cannot stack.

The gate is mechassembly's: `not item or <valid for this slot>`. An empty cursor
always succeeds, so removal is never blocked; a full one has to pass.

**THE SWAP IS PERFORMED IN THE PANE, SYNCHRONOUSLY, AND THE PORT ONLY COMMITS.**
A message round trip cannot be made atomic: take the cursor first and a refusal
destroys the item, commit on the port first and a dropped reply duplicates it.
Vanilla never faces the choice because mechassemblygui does not cross the boundary
mid-move. Neither do we -- the pane reads the cursor, writes the old occupant back
to it, repaints, and only then reports the finished set.

That is safe only because both sides ask `root.itemHasTag` about the same item
rather than consulting two hand-written rules, so they cannot disagree about what
a module is. The port's handler is a backstop against a malformed payload, not
the decision.

**STORED AS A LIST OF RECORDS**, `{ slot = n, item = ... }`, not an array indexed
by slot -- see `fact.tooling.sparsejson`.

### Networks — geography first, ID second
`arch.network.membership` -- see also `arch.network.registry`, `arch.port.coverage`

**Membership is proximity, not wiring.** Two rules, computed in two passes:

1. **Union-find over overlapping coverage rects** gives contiguous clusters.
2. **Partition each cluster by network ID** to get the actual networks.

Recomputed only when the registry changes — placement, removal, a range edit, an
ID edit — never on a tick.

**IDs are per-cluster namespaces, not planetary ones.** Network 1 on the east
side of a planet and network 1 on the west side are unrelated, and should be:
they are plausibly two different players. Making a bare label mean something
planet-wide would require chunk-loading infrastructure to make the whole
planetary space traversable, which is absurd scope for what it buys. This is the
single most likely thing in this document to be misremembered, because the UI
shows a bare number and bare numbers read as global.

**Per-port controls, checkbox governing the ID field:**

- **Participate ON** (default): ID is computed, not authored — the port takes
  the union of overlapping participating neighbours. Field greyed out.
- **Participate OFF**: ID is authoritative and the port is invisible to
  auto-merge.

Otherwise `participate: true, id: 1` is a legal state with no coherent meaning,
and it is the state a confused player produces first.

**Non-participation is mutual.** If A participates and B does not, they are not
connected. B's opt-out has to hold regardless of what its neighbours want, or a
single auto port placed beside it defeats the subdivision.

Why not unconditional transitive merge (Factorio's rule): it cannot express
"deliberately separated but overlapping", so it silently eats a subdivision the
moment anything is placed nearby. Factorio gets away with it because its whole
map stays loaded and its bots path in straight lines with no constraints;
neither is true here.

**Bridging is always deliberate.** A port placed so that two same-ID clusters
become contiguous merges them. This is true under any implementation, so it is
assumed rather than special-cased — and it gives players a genuine trick, where
pre-labelled ports merge on contact. Auto-renumbering on collision was rejected:
silently rewriting someone's configuration is worse than merging.

**Adjacency is touch-or-overlap, tested by inflating ONE side.** Factorio's
convention. A 10x10 rect tests as 12x12 against a neighbour's UN-INFLATED 10x10.
Inflating both doubles the tolerance — two rects with a visible one-tile gap
would connect, because each side's inflation eats half the gap. Testing raw
rects with `>=` on the edge comparison is equivalent if carrying a second rect
is not wanted.

**Keep the inflated rect out of everything except adjacency.** `loadRegion` and
work-claim bounds both use the visual rect. If the inflated one leaks into
coverage, units claim work a tile outside the drawn box and the box stops being
authoritative.

### The registry: how ports find each other
`arch.network.registry`

Each port publishes ONE entry into `world.properties` under
`petports_registry` -- rect, position, participate flag, network id, plus its
unit's position and busy flag. A version counter sits alongside.

**No port ever messages another port.** Membership is DERIVED independently by
each port from shared state, so there is no ordering problem and nothing to keep
in sync. A port notices the version moved, re-derives, and acts.

**Writes happen on change, never on a tick.** Placement, removal, an edit --
plus the unit's position, which republishes only when it has moved more than 4
tiles or its busy flag flipped. That threshold is the one place a per-tick write
would have been genuinely expensive.

**Removal belongs in `die()`, never `uninit`.** From uninit it would wipe the
registry on every world unload and every port would come back believing it
stands alone. A lingering entry is the same shape of problem as an orphaned
stagehand: invisible, cumulative, and it creates a phantom coverage zone merging
networks that should be separate with nothing on screen to explain why. A port
publishing at init also clears any entry positioned inside its own rect, which
handles mined-and-replaced.

**Membership derivation** is a flood fill over touch-or-overlap rects, then
partitioned by id, with non-participation mutual. Members come back SORTED --
`pairs()` order is nondeterministic and an unsorted list compares unequal to
itself, which would re-push to the unit every tick.

### The petport pane is a view over one mirrored parameter
`arch.pane.petport` -- see also `fact.pane.threegrids`, `fact.pane.titlestamp`

A ContainerPane WITH A SCRIPT, the same third thing the upcycler is: real
container slots plus arbitrary widgets, addressing an entity id so no token
system is needed.

**READ PATH IS ONE PARAMETER, NOT A MESSAGE ROUND TRIP.** The port mirrors a
summary blob into `petports_paneState` and the pane reads it with
`world.getObjectParameter`. Same transport the upcycler uses for points and
blips, so there is one of these in the mod rather than two.

**THE MIRROR IS CHANGE-GATED AND THAT IS THE WHOLE DESIGN.** A port cannot know
whether anyone has the pane open -- there is deliberately no way to ask -- so
this runs on every port in the world forever. Fuel is therefore QUANTISED TO A
BLIP INDEX BEFORE IT IS WRITTEN: a draining unit costs twenty writes across its
whole bar rather than one per tick. Every other field changes on a task boundary
or slower.

That constraint is also what kept `lastReject` out of it. See
`dd.pane.livenottally`.

**WRITE PATH IS A MESSAGE, AND THE PANE NEVER GUESSES AT AN OUTCOME.** Six
handlers on the port. Each rewrites the mirror; the pane repaints from the
mirror on its next poll. A refused action leaves the pane showing what is
actually true.

**Cargo is a Take BUTTON, not a bound itemgrid, and that is a one-authority
decision.** Cargo lives on `petData`, which is what makes it survive unsocket,
respawn and reload. A grid bound to container slots would be a second store, and
the two diverge exactly when a unit is out in the field: player empties the slot,
unit still believes it is carrying.

**KNOWN GAP.** The port debits before the pane gives, so a player whose
inventory cannot take the stack loses it to the floor -- and a drop in front of a
petport is an item this network collects again. Wants an ack before the debit.

### The router and the walker must aim at the same point
`arch.pathing.aimpoint`

approachPoint resolves a raw target to standable ground internally, so
`tryVentRoute` was being handed the RAW one while the walk used the resolved one.
Invisible on flat floor. On a slope: a drop at [1224.71,718.789] resolved to
[1224.5,718.875], the direct A* searched toward the resolved point happily, and
every vent probe ran toward the raw one and was refused as "not a valid standing
position" -- planRoute EXHAUSTED, task failed, unit never moved, drop reachable
the whole time. Now resolved once as `routeTarget` near the top of update and used
by both call sites, so a third caller cannot reintroduce the split.

### petportsArcMover
`arch.pathing.arcmover` -- see also `fact.pathing.movearcdefects`, `dd.pathing.motionnothealth`

Vanilla's grounded run-up, deleted rather than repaired -- see the trap entry for
the two defects and the six-tile runaway they produce. The airborne branch is
vanilla's, unmodified. The grounded branch keeps vanilla's one useful escape
(on the LAST arc edge, hand over to whatever follows -- which is why the bug
needs two or more arc edges left at touchdown) and otherwise issues NO
horizontal control at all.

Issuing nothing is the point. The unit stands still, the arc skip consumes the
dead arc on the same tick, and if it somehow does not, the grounded-stall check
replans within `AIRBORNE_EDGE_STALL`. Same conclusion `petportsJumpMover`'s
wrong-level branch reached, for the same reason.

### The drop placement, and the two things that make it safe
`arch.pathing.dropplacement`

`scootThroughPlatform` is `setPosition`, so it bypasses the collision sweep
between origin and destination -- `bodyFitsWithFeetAt` checks where the unit
lands, never the path. Two assertions now carry that.

**YOU MAY ONLY SCOOT THROUGH THE SURFACE YOU ARE STANDING ON**
(`DROP_ORIGIN_TOLERANCE`, 0.35). The placement is safe at `DROP_SCOOT` only
because of an invariant nothing was checking: the unit rests on the platform it
passes, so there is nothing in between. `DROP_SCOOT` never changed -- THE ORIGIN
DRIFTED. A unit executing a plan three tiles above the surface it was drawn on
reached a Drop edge and produced:

    pre-move at [3751.8,1029.8]: action Drop edge 24 of 68
      src [3752,1026.8] dst [3752,1025.8] dstDist 4.00499
    UNIT drop SCOOTED 1029.8 -> 1026.55 (through surface 1026)

A 3.25-tile placement through three solid-from-above platform surfaces, into a
tunnel with no route into it. In game it reads as falling through the floor, and
that log line is the only thing that says otherwise. **Feet on a platform read
EXACTLY its surface, so this assertion is free.**

**THE NUDGE POSE IS NOT THE RESTING POSE** (`DROP_SETTLE_MAX`, 1.0). Feet at
`surface - 0.25` puts a 1.6-tall body 1.6 tiles up from there, and under a
two-high ceiling that pose collides even though the resting pose fits:

    refused: Walk edge 28 targets [3753,1023.8], 1.00006 below us:
      solid tiles at feet 1023.75

Feet 1023.75 spans 1023.75..1025.35 and the top tile is the ceiling. Feet 1023.0
spans 1023.0..1024.6 and fits exactly. The placement now steps down in
`DROP_SCOOT` increments and takes the first height that clears -- 1023.25 here,
with gravity finishing the last quarter tile.

**1.0 IS THE CAP AND IT IS DOING REAL WORK.** Platform surfaces land on
integers, so one tile reaches the next standing height and cannot reach the one
past it. Raise it and placements start crossing platforms unchecked, which is
the teleport again -- at which point the destination check has to become a
sweep.

**ONE PLACEMENT PER TICK.** The arc-landing decision and the per-tick ground
guard both call `tryPlanDrop`, and after a landing they run in the same tick.
Observed as a paired "dropped one platform" / "refused" on one timestamp, which
stayed harmless only because the second call found nothing to pass.

### Homeward targets bias downward
`arch.pathing.homewardbias`

findGroundPosition tests UP BEFORE DOWN at every step and `GROUND_SEARCH_UP` is
4, so a standable spot above the target beats one below it and it will climb four
tiles to find one. A port under a shelter has a perfectly good roof.

Measured: port at [1203,728] resolved to **[1203.5,731.875]** -- on its own roof
-- while the floor beneath it was fine. `"return"` tasks (both the unit's leash
and the port's recall) now resolve with `searchUp = 0`; the unbiased search
remains as a fallback and logs when it fires.

**The same bias still applies to COLLECT targets and is not fixed.** An item on
the floor with a ledge two tiles above it would resolve to the ledge, and the unit
would arrive somewhere it cannot reach the item from. Presents as "walks there and
never picks it up".

### petportsJumpMover
`arch.pathing.jumpmover` -- see also `dd.pathing.motionnothealth`

Vanilla's whole body is gated on being within 1.0 of `edge.source.position`, and
there is NO code anywhere that walks the unit to its own jump point. The takeoff
path is vanilla's, unmodified -- the snap to source is what makes the flown arc
match the planned one, the 0.2s jumpTimer is what the arc is computed from, and
the friction zeroing keeps the ascent ballistic. Two additions:

**The missing else.** Outside the radius, walk toward the source -- but only if
the source is within `JUMP_LEVEL_TOLERANCE` (1.0) vertically. Walking changes x,
not what floor you are standing on. A source four tiles down means the unit is
not where its path thinks it is, and the answer is a replan.

**THE OSCILLATION THAT TAUGHT THAT.** A unit stood at [1214.88,711.875] with its
jump source at [1215,707.875]. Horizontal offset 0.12 cleared the epsilon, so it
walked right, overshot to 1215.13, reversed, overshot to 1214.88, forever. And it
DEFEATED THE STALL DETECTOR: displacing a quarter tile per cycle kept stuckAnchor
updating and airborneEdgeStall resetting. **A recovery that produces motion can be
worse than no recovery**, because motion is what the detector reads as health.

**Launch velocity is corrected upward.** The planner over-estimates jump height.
Sorted by required rise: 7.0 ok, 8.0 ok, 9.0 FAILS, against a physics ceiling of
45^2/(2*120) = 8.4375. So moveJump reads the highest point of the arc just
planned -- walking forward through Arc edges and INCLUDING the first non-Arc,
which is the Land whose target is the surface to get on top of -- and launches
with the velocity that reaches it. It only ever RAISES, never lowers, and only
when the plan demands more than nominal, so arcs that already worked are
untouched. Capped at 1.25x.

Scaling `jumpSpeed` does NOT fix this: planner and movement controller both read
`airJumpProfile.jumpSpeed`, so lowering it shrinks both and the percentage error
survives.

### One refusal ladder, read by both the upcycler pane and the machine
`arch.upcycler.stateladder` -- see also `arch.upcycler.burnbox`, `fact.tooling.andnilor`

`petports_upcyclerstate.lua`. BUILT 2026-08-30, after the same drift shape bit
four times in two days:

    applyState (pane) vs storedRules (object)   pane silently stripped both rule
                                                exclusions and wrote them back
    the two bulk rescues                        near-identical pair, now one
    the refusal LADDERS themselves              machine reordered to ask exempt
                                                before the manifest, pane not --
                                                one item, two explanations
    hasTag (pane) vs exempt (object)            same cached itemConfig walk twice

**SHARING THE LOOKUP TABLE WAS NEVER ENOUGH. THE ORDER IS THE LOGIC.** A ladder
of refusals is a sequence of returns, and a sequence written twice is two
programs that happen to agree today.

**IT DECIDES, IT DOES NOT SPEAK.** A verdict is a cause id and a severity, no
sentences and no widget names. The pane turns a cause into player-facing text in
its own voice; the machine turns the same cause into a log line and, later,
indicator lights. Neither can change what counts as broken without changing it
for the other.

**SEVERITY IS THE FIELD THAT MATTERS.** `error` means a human must act -- the
player's own configuration is rejecting something already inside the machine, or
the item can never be processed at all. `waiting` clears itself. Only `error`
lights an alarm; crying wolf on waiting states is how an alert surface becomes
wallpaper.

**ORDER WITHIN A SLOT IS BY WHAT THE FACT IS ABOUT, NOT BY WHAT IS CHEAP TO
TEST.** Item-level facts (exempt) before table lookups (is it in the manifest)
before configuration (what the rule says). Ordered the other way the generic
message wins and the specific one never fires -- every exempt item is also absent
from the reagent manifest, so a manifest-first ladder answers "not a reagent" for
a pet. That shipped once.

### The slot shuttle runs on one priority
`arch.upcycler.shuttlepriority` -- see also `arch.upcycler.stateladder`

**KEEPING THE FLAVOR CHARGE FULL OUTRANKS BURNING MORE ITEMS.** Burning is always
available to a burn-allowed item; being spent as flavor is not, so the scarce
option gets first refusal. Everything else falls out of that read from one side
or the other.

**`chargeFits` IS WHAT MAKES IT TERMINATE, and weight-awareness is load-bearing.**
With an "is the charge full" test instead, a weight-8 reagent facing 3 free blips
is pulled to the reagent slot, cannot be spent, and is pushed back -- one hop per
tick forever, because room only frees by burning and the item that would do the
burning is the one bouncing. Asking whether THIS item fits breaks it. One item's
worth of flavor is lost on a part-full charge and that is the intended trade.
Bounded by construction: heaviest manifest reagent is 8, `BLIP_CAPACITY` is 8.

**BULK WHERE THE SLOT IS A DEAD END, PACED WHERE IT IS NOT.** A stack the
destination rule has closed has no future where it sits, so it leaves at once --
pacing it stranded ~400 milk, measured. A stack merely waiting for room trickles
one at a time, because every blip the burner frees is one more spent as flavor.

**THE MUTUAL SWAP DEADLOCK RESOLVES ITSELF.** Burn-denied stock in the burner
needs the reagent slot; reagent-denied stock in the reagent slot needs the
burner. Each is the other's blocker and it looks exactly like ordinary waiting
from either side alone -- only a check holding both slots at once can tell "wait,
that will clear" from "wait, forever". The predicate that detects it is shared
with the pane, and BOTH CONDITIONS ALREADY PROVE THE SWAP IS LEGAL: each item is
tested for permission to enter the slot the other occupies, so the swap re-checks
nothing and cannot place illegally. It can only arise from an edit to something
already socketed, since nothing delivers into a slot its rule denies.

### Non-treats in a machine output slot are collected, not stranded
`arch.upcycler.outputeviction` -- see also `arch.upcycler.shuttlepriority`

`emitFuel` peeks rather than takes, so a parked non-treat blocks payout without
losing a blip -- but nothing in the world cleared it and the machine stopped
dead. The port's output scan was gated on `isFuelItem`; that gate is now a flag
rather than a gate.

**THE DELIVERY END NEEDED NOTHING.** Destinations are matched with
`petports_filterAccepts` against the item ACTUALLY held, and `"deposit"` is the
general storage set tidy and sort already use, so junk routes by the same filter
rules as anything else a unit carries.

**JUNK SKIPS THE BATCH FLOOR.** The floor exists because treats ACCUMULATE, so
collecting the first one costs a round trip for three items. None of that applies
to a single misplaced item: no more are coming, it can never reach a batch, and
every second it sits there the machine is stopped.

### `standableNear` ranks every column by true distance
`arch.pathing.standablerank` -- see also `arch.pathing.homewardbias`

`COLUMN_SEARCH` is `{ 0, 1, -1, 2, -2, 3, -3 }` and the loop used to return the
FIRST column that resolved. That is nearest BY COLUMN: each column was exhausted
over its full `GROUND_SEARCH_UP` (4) and `GROUND_SEARCH_DOWN` (-6) before the
next was tried, so a spot SIX TILES DOWN in the target's own column beat one a
single tile SIDEWAYS at exactly the right height.

MEASURED, watering coffee against a cliff with sea at its foot:

    UNIT water CAST tile [2499,1152]                        tile 1, from [2499.85,1153.8]
    UNIT standable for [2498.5,1153.5] -> [2498.5,1147.8]   column offset 0
    UNIT reporting failed: arrived but 5.80751 from tile [2498,1152]

The unit had just watered tile 1 from 1.36 tiles away and was then sent 5.7
tiles down into the water. `WATER_REACH` (4.0) refused correctly -- the reach
check was never the problem, the destination was.

**TWO THINGS MUST BOTH HOLD FOR IT TO LAND SOMEWHERE THAT SILLY**, which is why
it reproduced in one place and nowhere else. A WALL kills the target's own
column at every sane height, because a 1.6-wide body centred on the tile
overlaps it. And WATER BELOW makes the deep spot acceptable to an amphibious
chassis, since `petports_avoidLiquid()` is false -- which skips
`findGroundPosition`'s own liquid rejection AND makes `validStandingPosition`
count liquid as standable. A drone refuses it and searches on.

**THIRD INSTANCE OF ONE PATTERN.** `petports_flyPointNear` had this exact bug and
its header carries the lesson -- "in a first-fit search the order IS the answer"
-- but only free movers reach that function.

**WHY RANKING PER-COLUMN BESTS IS EXACT, NOT AN APPROXIMATION.**
`findGroundPosition` walks outward from `position[2]`, so it returns the smallest
`|dy|` in its column. Every other spot in that column shares its `dx` and has a
larger `|dy|`, hence larger true distance. The column's first answer is also the
column's nearest, so the minimum across columns is the genuine global minimum.
The up-before-down bias survives only as a tie-break, and `searchUp = 0` still
disables climbing for homeward tasks.

Cost is seven `findGroundPosition` calls instead of an early exit, once per
resolve, cached on `stateData.groundTarget`.

**STILL UNFIXED AND NOW INCONSISTENT: `petports_standingPointNear` in
`petports_contract.lua` has the identical first-fit loop**, and it is the
resolver the PORT uses at dispatch time via `callScriptedEntity`. Two resolvers
answering one question by different rules is the failure class
`fact.pathing.approachliquid` was written about. On the geometry above the port
would judge reachability from `[2498.5,1147.8]` while the unit walks to
`[2499.5,1153.8]`.

### The origin nudge -- a pre-flight on where the search will START from
`arch.pathing.originnudge` -- see also `fact.pathing.originnode`, `fact.pathing.ongroundtest`, `todo.pathing.nodeformula`

Vanilla checks the TARGET is standable and never checks the origin at all --
there is no such line in `pathing.lua`. `petportsTaskAction` now does, in
`nudgeOrigin`, before anything asks the pathfinder a question.

`originIsPlannable` asks `validStandingPosition` about
`petports_nodePosition(mcontroller.position())` -- the NODE, not the position.
When it says no, `nudgeTargetNear` takes the nearest standable node on the same
row within `ORIGIN_NUDGE_RADIUS` (2), and the unit is steered there with `moveX`
until it is within `ORIGIN_NUDGE_ARRIVE` (0.25). On success the pather is
rebuilt, because whatever plan it holds was drawn from the bad node.

**IT FAILS OPEN, AND IT IS THE ONE THING IN THAT FILE THAT DOES.** A false
negative refuses to plan and bricks a healthy unit; a false positive plans
exactly as the code did before. The worst case of being wrong is the behaviour
we already had. That is also why `fact.pathing.ongroundtest` is tolerable: every
way the Lua predicate differs from the engine's makes it STRICTER, which lands
as a wasted tick rather than a missed trap.

**SAME ROW ONLY.** Walking changes x, not which floor you are standing on --
`petportsJumpMover`'s wrong-level branch is built out of that same fact. A
standable node one row up is not somewhere a walk can deliver the unit, and
offering it would produce motion toward an unreachable place. Motion is what the
stall detector reads as health.

**IT WALKS TO THE NODE CENTRE, NOT TO WHERE THE PREDICATE FLIPS.** The node
boundary is at `x.5`, so the flip leaves the body balanced ON it, where a
fraction of drift breaks it again. Measured: the perch at 2503.39 flips at
2503.5, which is 0.11 tiles of travel and no margin. The centre gives half a
tile either side.

**THE SCOPE IS PER SEARCH, NOT PER TICK, AND GETTING THAT WRONG WAS A REAL
DEFECT.** Build 28a ran it every tick and it fought live plans: a correct
six-edge Walk plan deliberately walked the unit LEFT off a crate toward the
crops, the node went un-standable as it crossed x 2503.5, and the nudge pushed
RIGHT against a plan that was working. It came out right only because momentum
carried the unit off the ledge anyway. It now starts only when `finder.hasPath`
is false. A nudge already under way is exempt, because it exits through the
branches above that gate.

**ABANDONING IS NOT COMPLETING, AND CONFLATING THEM DESTROYED PATHS IN FLIGHT.**
28a put the airborne check inside `originIsPlannable`, which returned
`true, nil` -- indistinguishable to the caller from a nudge succeeding. It
logged `node null is standable` and called `freshPather`, discarding a live path
MID-FLIGHT, which `canPathfind()` cannot then replace until the unit lands.
`node null` in an old log is that bug. The ground gate now lives in the caller,
which has somewhere sensible to put the answer, and abandoning does NOT rebuild
the pather.

**Not run once arrived**, or it walks a waterer off its own soil tile.

**IT DOES NOT ESCALATE.** Timeout is `ORIGIN_NUDGE_TIMEOUT` (1.5s), and both
failure paths -- nowhere to nudge to, or ran out of time -- set
`originNudgeFailed` and fall through to the ordinary failure ladder. That is
deliberate: this exists to give a unit a push before it sticks itself, not to
replace the recovery that catches it when it does.

MEASURED, one geometry, two hops off a one-tile ramp onto a crate one tile
right at the top:

    before   297 refusals, 92 s, zero displacement, ended in a re-home
    28a      1 nudge fixed it in one tick, plus 2 spurious firings
    28b      1 nudge, 1 tick, 0 spurious, 0 `node null`, 0 ABANDONED

### Pathing is vanilla's, with corrections and two replaced movers
`arch.pathing.overview`

Units path with `PathMover` from `/scripts/pathing.lua` via `groundPet.lua`'s
`approachPoint`. It handles Walk, Jump, Drop, Arc, Land, Swim and Fly edges, and
the A* itself is genuinely good -- a unit will chain a staircase climb and four
platform hops to reach a target. NOTE there is no Climb edge: ladders are not
traversable, platforms are.

**The movers are the weak part, not the search.** `PathMover` assumes an actor
that arrives on its waypoints, and has no recovery when it doesn't. That is a
reasonable assumption for a walking humanoid on generated terrain and a poor one
for a small fast unit in a player-built shaft. Four separate dead ends were
measured, all with the same shape: unit grounded, on an airborne edge, mover
issuing no input and never advancing.

#### Corrections applied in petportsTaskAction

1.  **A fresh `PathMover` per task.** `PathFinder:reset()` leaves `aStar` alive,
    so an abandoned search poisons the finder permanently.
2.  **`standingBoundBox` = the real bounds, no padding.** Vanilla's flat -0.7
    INVERTS for anything narrower than 1.4 tiles and silently disables every
    vertical edge -- that is why this is computed rather than defaulted. It was
    then padded to 0.4x half-width for a while, which is a LIE ABOUT THE BODY:
    A* validates clearances with it. Measured result: setting `pad = 0` changed
    the plan not at all (identical edge count, identical waypoints, identical
    collision), so the padding was never the arc problem -- but zero is the
    honest value and it stays. Cost is permissiveness: expect routes occasionally
    refused where one was previously offered and then failed.
3.  **`exploreRate` overridden** to a fixed 300, so pathing quality does not vary
    with server-side `world.fidelity()`.
4.  **The stuck timer measures the wrong thing.** `PathFinder:update` resets
    `stuckTimer` in exactly ONE place -- when `currentEdgeIndex` changes -- so it
    measures TIME SPENT ON ONE EDGE, not being stuck. Any edge lasting over 0.5s
    destroys the whole path. Walk edges are a tile long and advance constantly;
    Arc and Land are airborne waits and always exceed it. It compounds, because
    `canPathfind()` returns `mcontroller.onGround()`, so the path is discarded
    MID-FLIGHT and nothing can replace it until the unit lands -- measured at
    3.9s of a motionless unit that had landed short of its arc. FIX: zero
    `stuckTimer` whenever the unit has actually displaced (anchor + `STUCK_MOVE`
    0.1), which corrects the predicate rather than raising the timeout.
5.  **Unreachable arc waypoints are skipped.** The planner over-estimates jump
    height by roughly 7%, so the final waypoint of an arc sits above what the
    unit can reach. Neither axis can then advance the path: `passedTargetOnAxis`
    axis 2 never sees a sign change because the target y is never reached, and
    axis 1 is killed by its own `edgeDistance[axis] ~= 0` guard on a vertical
    arc. ONCE THE UNIT IS FALLING, ANY WAYPOINT ABOVE IT IS UNREACHABLE -- so
    those edges are declared passed. Descending arcs put waypoints below the
    unit, so normal flight is untouched.
6.  **A grounded-stall detector** replans when the unit is on the ground, on an
    airborne edge, and motionless for `AIRBORNE_EDGE_STALL` (0.35s). Excludes
    `moveJump`'s deliberate 0.2s pre-takeoff pause two ways (`jumpTimer` check
    plus the threshold), and is skipped while `stateData.routing` is set, since
    then `approachPoint` is not being called at all and the unit is motionless
    for reasons that have nothing to do with its edge.

#### moveJump is replaced

Assigned to the pather INSTANCE (`self.pather.moveJump = petportsJumpMover`), so
it shadows `PathMover.moveJump` through the metatable for that pather only.
Vanilla's stays reachable, nothing is patched globally, no other entity is
affected. Same technique as the `exploreRate` override.

**Watch the parameter name.** `edgeMove` calls it as `self:moveJump()`, so the
pather arrives as the first argument -- but inside our files `self` is the
monster's script table, a completely different thing. `pathing.lua` flags the
same collision above `setMoved()`.

Two defects fixed, both additive -- the takeoff path is vanilla's, unmodified:

**The missing else.** Vanilla's entire body is gated on being within 1.0 of
`edge.source.position`, and there is no code anywhere that walks the unit to its
own jump point. The Jump edge only becomes current AFTER the unit crosses the
source, so the usable window is one tile wide; at walkSpeed 8 the script advances
~0.66 tiles per step and the phase decides whether any step lands inside.
Measured: the unit coasted to a dead stop 1.19 tiles past the jump point,
replanned, walked back, overshot by 1.21 the other way, and oscillated forever.
IT GETS WORSE AS SPEED RISES, which is backwards for a unit that should move with
purpose. Fix: outside the radius, walk toward the source.

The radius is still 1.0 and should stay. The body TELEPORTS the unit to the jump
point; a larger radius means a longer snap, and a long enough snap puts the unit
through a wall. Walking is slower and cannot.

**The launch is under-powered relative to the plan.** Sorted by required rise
across one chute run:

    704.375 -> 711.375   7.0 tiles   ok
    711.375 -> 719.375   8.0 tiles   ok
    719.375 -> 728.375   9.0 tiles   FAILS

Physics allows `45^2 / (2 * 120)` = 8.4375. The planner emitted a jump needing
9.0, i.e. it solves with g near 112.5 against a world running 120. The unit
apexed a quarter tile under the ledge, hit its vertical face -- x velocity went
from -12 to -0.003 in one tick -- and dropped three tiles.

SCALING `jumpSpeed` DOES NOT FIX THIS. Planner and movement controller both read
`airJumpProfile.jumpSpeed`, so lowering it shrinks both and the percentage error
survives; jumps just fail at a proportionally lower ledge. Instead, `moveJump`
reads the highest point of the arc the planner just produced (walking forward
through Arc edges and INCLUDING the first non-Arc, which is the Land whose target
is the surface to get on top of), computes the velocity that genuinely reaches
it, and launches with that. It only ever RAISES, never lowers, and only when the
plan demands more than nominal -- so jumps that already worked are bit-for-bit
untouched, and launching weaker than planned (which is what caused the earlier
ceiling collisions) is impossible by construction. Capped at 1.25x.

Verified: 9.0 -> 47.41, 9.348 -> 48.31, `capped false` both times, whole run
clean with zero stalls and zero mid-journey replans.

#### Measured physics, for anyone re-deriving this

g = **120** on the test planet: world gravity 80 x `gravityMultiplier` 1.5,
INHERITED from `default_actor_movement.config` which the drone does not override.
Derived two independent ways from one log -- velocity falling 10 per sample, and
the sample interval taken from x travel at constant vx.

**`movementSettings` are MERGED, not read verbatim.** Proven twice: a vanilla
monster specifies only three of eight `airJumpProfile` keys and still keeps
`jumpControlForce`; and the measured g matches a multiplier the drone never
declares. Sub-object merge is happening.

**`walkSpeed` is not a safe tuning knob.** `moveWalk` reads
`baseParameters().walkSpeed` and `enableWalkSpeedJumps` makes A* consider
walk-speed jumps, so changing it changes edge costs and SILENTLY RE-ROUTES.
Dropping 8 to 4 during testing picked a different and worse takeoff tile.

**`smallJumpMultiplier` WAS 1.0 AND IS NOW 0.5. SUPERSEDED 2026-08-28 -- see
`fact.pathing.smalljump`.** This paragraph used to end "and should stay", on the
grounds that the actor cannot perform a partial jump because
`default_actor_movement.config` sets `jumpInitialPercentage` 1.0 and
`jumpHoldTime` 0.0. Those govern the jump CONTROL and `petportsJumpMover` does
not use it -- it sets velocity directly. The measured failure behind the pin was
real (a 33.75 arc answered with a 45 launch) but it was VANILLA's `moveJump`
doing that, not physics.

The consequence of leaving it at 1.0 was that A* was offered exactly ONE jump
height for the entire life of the mod, and it was the maximum.

#### Targets and unreachability

**Targets must be STANDING POSITIONS, not object positions.** An item drop rests
where the item rests; a unit stands somewhere else. `standableNear` searches by
column -- x snapped to a tile centre, `findGroundPosition` supplying the y -- and
the first column that resolves wins.

Note that `PathMover:move`'s arrival test is
`onGround and targetDistance < 2 and math.abs(toTarget[2]) < 1` -- the VERTICAL
component under one tile is why passing a raw object position (a port sits 3.25
tiles above its floor) never reports arrival.

**The pathfinder cannot tell you a target is unreachable**, so the task layer
decides: a search still running after `SEARCH_LIMIT` is called unreachable, and
the port backs the work off. Measured for calibration: a hard chained route
solves in ~2.25s at explore rate 300, a nearby target in 0.08s. The gap between
"solving" and "never going to solve" is large, so the limit does not need to be
generous.

### Cache entries expire, asymmetrically
`arch.pathing.routecache`

`ROUTE_TTL_FALSE` 60s, `ROUTE_TTL_TRUE` 600s. The two answers fail differently:

- a stale **false** is permanent damage -- it blocks a route that now works and
  nothing re-tests it. `pruneRouteCache` only drops edges naming vents that no
  longer exist, so editing terrain invalidates NOTHING.
- a stale **true** is self-correcting -- the unit walks it, fails, relearns.

**This poisoned an entire debugging session.** After the arena was rebuilt, a
planning cycle answered EVERY edge from cache, declared the route impossible in
milliseconds without probing anything, and only re-placing the port fixed it.
Entries are now `{ r = reachable, t = learned }`; bare booleans from an older save
are treated as expired rather than trusted, since an unknown-age false is exactly
what this exists to stop.

**If a route test says "impossible" after a terrain edit, suspect the cache before
the geometry.**

### petportsWalkMover
`arch.pathing.walkmover`

One thing: slow to `JUMP_APPROACH_SPEED` (3.0) within `JUMP_APPROACH_SLOWDOWN`
(2.5 tiles) of a coming Jump edge's source, via `finder:lookAhead(1)`. Everything
else is vanilla's, called through the class table so there is no copy to
maintain.

**THIS IS THE FIX FOR ONE ROOT CAUSE WITH THREE SYMPTOMS**: script tick
granularity versus moveJump's fixed 1.0 capture radius. At walkSpeed 8 the script
advances the unit ~0.66 tiles per tick, so the window gets one sample and the
phase decides whether it lands inside. That produced the two-tile oscillation on
flat ground, pacing near a jump point, and -- measured -- an EIGHT TILE FALL when
the unit walked off a ledge at full speed and the path advanced to the Jump edge
only after it was already airborne and 1.23 tiles from takeoff. At 3.0 the window
gets three or four samples. The walk-back branch is now a backstop, not the
primary mechanism.

### The petport implements vanilla's anchor contract
`arch.port.anchor`

`groundPet.lua`'s `findAnchor` calls `status.setResource("health", 0)` — it KILLS
the pet — if it cannot find an anchor object within 5 tiles of its last anchor
position. So `petports_petport.lua` implements the same `hasPet` / `setPet`
contract `techstation.lua` does, and the monstertype's `anchorName` points at it.

**`anchorName` must match the station's `objectName` exactly.** Rename the object
and pets die on the next load.

This is deliberate scaffolding: it lets vanilla's pet scripts run unmodified
while the behavior work happens separately.

### Coverage rects — the roboport model
`arch.port.coverage`

**Each petport defines a fixed square coverage rect around itself.** That rect
is simultaneously the region it keeps resident, the area its units may take work
in, and the placement-time visual. One number, three meanings, which is what
makes it comprehensible.

This replaced an earlier design where pets registered their own work areas
dynamically. That made the resident footprint UNBOUNDED — a unit that wandered
somewhere interesting extended the loaded region with it, and the cost was
emergent. A fixed rect per port makes it a known constant times the number of
ports: a cost that can be tuned and communicated rather than discovered from a
bug report.

**An empty port still holds its region.** Ports define a loaded work area that
can queue tasks as part of a network, independently of whether they currently
house a unit.

**Chunk granularity rounds UP, never down.** Sectors load whole, so a rect that
is not chunk-aligned pulls slightly more than it draws. Acceptable in this
direction and only this direction: the drawn rect remains authoritative for what
work may be claimed, and more loaded chunk than advertised is never a
correctness problem.

**Placement preview comes from `imageLayers`, not from a script.** Object
scripts do not run until after placement, so the port cannot draw its own range
box. Manual `spaces` plus stacked image layers does it — see the traps section.
The indicator is free: `imageLayers` render during preview only, and the
animation takes over on frame 1 once placed, so there is nothing to toggle or
clean up.

**Coverage visuals belong to the player, not the object.** The `imageLayers`
preview works, and it is nearly useless, because it can only ever show ONE
port's rect, only while that port is the held item, and never in relation to
what is already placed. Every interesting question about coverage is a question
about neighbours.

The design that answers it runs on the PLAYER rather than on any object: a
script that watches what the player is holding, notices the held item is tagged
as coverage-relevant — holding the item is already required to place furniture,
so the trigger is free — and then draws with `localAnimator`. Existing coverage
comes straight out of `petports_registry` in `world.properties`; a TENTATIVE
rect is inferred from the player's aim position and the held item's own coverage
parameter.

That turns placement into a live question — does this reach the room next door,
and does it merge the two networks I deliberately separated — answered before
the port goes down instead of after. Tinting rects by network id is what makes a
subdivided base readable at a glance, and it is the same overlay doing it.

Nothing new has to be published for this to work: the registry is already the
authority for every placed port. Two complications survive from the earlier
sketch — work ranges would not display inside tile-protected zones, and the
tentative rect is only as good as the aim-position-to-placement-tile mapping,
which is worth verifying against an actual placement rather than assumed.

### Placement validation — occupancy, not interactivity
`arch.port.placement`

`petports_placement.lua` answers "is this a polite place to stop?" Every
resting action needs it.

The obvious approach — "do not stand in front of interactable objects" — DOES NOT
WORK. Interactivity is a RUNTIME property: `/objects/wired/light/light.lua` calls
`object.setInteractive(config.getParameter("interactive", true))`, so a light
switch is interactive by default with nothing in its config saying so. Any
predicate built from config parameters has holes, and the holes look arbitrary to
a player.

So it checks OCCUPANCY: does the pet's footprint overlap the tiles an object
occupies (`world.objectSpaces`)? Slightly over-broad — a pet also declines to nap
in front of a decorative panel — which is a much better failure mode than napping
in front of the one thing the player needed.

**Allow-list, not deny-list.** Objects are off-limits unless tagged
`petports_perch`. A deny-list would mean enumerating every object to avoid,
which is unbounded and grows with every mod installed. An unknown object is
treated as furniture to stay off, which fails safe. Tag the pet house and any
deliberate perch.

`sleepAction` is the acute case and it is not drift: it TELEPORTS the pet onto
its target with `mcontroller.setPosition`. Use `petports_settleAt` instead —
validation that only gates approach will miss it.

UNVERIFIED: whether `world.objectSpaces` returns object-relative coordinates
(assumed, matching how `pathutil.lua`'s `objectBounds` uses it), and whether
trees surface through an `includedTypes = {"object"}` query. The tree case is
"wait for a complaint" — the failure is a pet declining to nap under a tree.

### The residency owner is a stagehand
`arch.port.residency`

**`keepAlive` is not available on objects and is on stagehands.** That is the
decisive constraint. A port anchors a stagehand that owns its `loadRegion` call.

This also dissolves a bootstrap problem the earlier design had. An unloaded port
cannot run a script to load itself, so something already-loaded has to wake it —
which meant chain-init, where each port loads zones around its links so they can
init in turn. That works, but it needs a hop limit and a visited set (A links B
links A re-issues load calls forever), and it makes the footprint "every port in
the network" rather than "ports near the player". A `keepAlive` stagehand needs
none of it.

Stagehands serialize like entities when persistent. Some are temporary (NPC
interaction zones), some permanent (quest location markers). The Glitch defense
mission has a keepAlive stagehand whose entire purpose is holding the map
loaded — a direct 1:1 example to work from.

BUILT AND VERIFIED 2025-08-20. `/stagehands/lofty_petports/petports_residency`.

**The port owns stagehand lifetime, with the stagehand as a backstop.** Kill it
from the object's `die()` callback, which fires only on actual destruction. NOT
from `uninit`, which also fires on world unload and would orphan every port on
the next reload.

The stagehand ALSO watches for its own port by uniqueId and retires if it stays
missing past a grace period. Two independent guards on purpose: an orphaned
keepAlive stagehand is invisible and cumulative — no sprite, holds a region
resident forever, and the only symptom is a world that gets progressively more
expensive. That is the worst failure available here.

**The port re-checks on a slow timer, not just at init.** A spawn that fails is
then visible as a repeating attempt rather than one silent miss, and a stagehand
that dies while its port lives gets replaced.

**Residency does not keep a WORLD alive.** It holds sectors resident within an
already-loaded world. The last player leaving still stops the world, and no
amount of loadRegion changes that — see the engine constraint above.

Give the stagehand a uniqueId derived from the port's tile position, so
replacing a port at the same spot reuses rather than accumulates, and so a sweep
can find orphans by pattern.

### The behavior layer is a fork, not a patch
`arch.unit.behaviorfork`

`petports_petBehavior.lua` is a copy of `/monsters/pets/petBehavior.lua` with our
changes in it. Vanilla's file comes OUT of the monstertype's scripts list; ours
defines the same global, so `groundPet.lua` calls into it unmodified. Vanilla's
file is untouched on disk — nothing is clobbered, ours simply is not vanilla's.

**Why fork rather than wrap.** Registering a new action state means adding to
`petBehavior.actionStates`, which vanilla REBUILDS WHOLESALE inside
`petBehavior.init()`. Adding at load time is overwritten; adding afterwards
means wrapping `init`, and a wrapper is load-order dependent the moment another
mod wraps the same function. Owning the file also keeps another mod's experiment
on vanilla pet behaviour from reaching into our units, which matters more here
than usual — pet behaviour is a popular thing for mods to touch.

`groundPet.lua` is still vanilla. Full isolation eventually means forking that
too, but it is bigger and the anchor contract leans on its exact behaviour.

**THE ACTION QUEUE IS NOT A QUEUE.** The last line of `run()` is
`petBehavior.actionQueue = {}`, and the first thing `run()` does is re-queue
every action state from scratch. It is a PER-TICK SCORING BUCKET. A task queued
once vanishes on the next tick, so the unit holds its assignment in
`self.petportsTask` and re-queues it EVERY TICK. The petport dispatches STATE,
not an event. This is the single most important thing to know before touching
the dispatch path.

**The pick loop `break`s rather than continuing.** Actions are sorted
descending, so the first one failing `score > currentActionScore +
interruptThreshold` stops evaluation entirely. A task scored above the appetites
is therefore also UNINTERRUPTIBLE while it runs, because `currentActionScore`
holds for the life of the state. Correct for the diagnostic task. When real
tasks land, hunger must be able to interrupt work, and `TASK_SCORE` is the knob
that currently prevents it.

**`"starving"` was dropped from `actionStates`.** Vanilla lists it but
`scoreAction` has no branch for it, so it always scores 0 and can never be
picked. Dead in vanilla, dead in every mod that inherited the file.

### Exit paths — three, and they mean different things
`arch.unit.exitpaths`

- **Port destroyed.** Involuntary. The unit drops any carried cargo where it
  stands and plays the mech beam-out fade — fade to white-blue, then out, the
  same aesthetic as a tech transformation. Reads as a system shutting down,
  which is what happened.
- **Unsocketed.** Deliberate; the player pulled the item. A recall, and
  probably instant.
- **World unload.** Not an event at all. No animation, no cargo drop. State
  serializes and the unit resumes from where it stood.

**Getting the third one wrong is the risk.** `uninit` fires on world unload as
well as on destruction, so a despawn routine called from there scatters cargo
across the planet on every reload and plays a farewell nobody sees. Cargo drop
and fade belong on the `die()` path only.

Dropping cargo physically rather than voiding it is deliberate: the dropped
items immediately become discoverable work for the collection task, so any unit
whose coverage reaches that spot cleans up after a destroyed port. Claims
release naturally, since the cargo becomes new items with new ids.

### Recalls vent-route now, and the refusal that stopped them
`arch.vent.recall`

`tryVentRoute` used to refuse `return` tasks outright. Both of its reasons have
since expired, and the refusal was stranding units.

The original reasoning: a walk home is not worth a route search; routing a
recall cost 38 seconds of probing before failing; and worse, it filled the cache
with `t:` keys for recall points CHOSEN AT RANDOM inside the rect, which would
never be asked about again.

**Both halves are dead.** `returnWork` now recalls to a FIXED point --
`findStandingPoint` over a small box around the port, same answer every attempt
-- so a recall produces ONE `t:` key per port rather than a fresh one per try.
And route cache entries carry a TTL, so even a bad key ages out instead of
accumulating.

**What the refusal cost was units that could not get home at all.** A unit that
vent-hopped somewhere to work, finished, and was recalled had no vent available
for the return leg: it went in one way and was permitted to come back only
another. Inside an enclosure with vent-only access that is PERMANENT, because
the leash deliberately never fails -- so the unit retries a walk that cannot
succeed, forever, and never reports.

MEASURED: a unit idle at `[1195.07,715.8]`, directly between vent 15 at
`[1195,721]` and vent 17 at `[1195,712]`, with no walking route home. It needed
exactly the pair it had just used.

**ONLY REPRODUCIBLE WITH MORE THAN ONE UNIT DEPLOYED, and that is the tell.** A
single unit takes every job and is never left idle deep in the network. It takes
a second unit losing the claim race to produce an idle unit somewhere it cannot
walk out of. Any bug that needs an IDLE unit to appear will hide from
single-unit testing.

Fixed by deleting the refusal. Verified: return-home from enclosed cages via
vents works.

**A stale premise was corrected downstream at the same time.** The
station-keeping branch read "station-keeping never vent-routes, so reaching here
means only that the direct walk is hard". Behaviour there is unchanged and still
correct, but the MEANING of reaching it has changed: vents were offered,
considered, and none helped. A unit landing there repeatedly is now genuinely
unreachable rather than merely unrouted.

### Vent routing
`arch.vent.routing`

BUILT AND WORKING for the simple case, verified in game: a unit that cannot
reach a target directly walks to a vent, travels, and completes the task on the
far side. GREEDY and inadequate for real layouts -- see the limitation below.

**How it works now.** The PORT gathers vents inside its network's coverage and
pushes the list to its unit alongside the network rects -- vent id, entry
position, and each partner's exit position. The port cannot evaluate
reachability itself: PATHFINDING NEEDS mcontroller, WHICH OBJECTS DO NOT HAVE.
Only units can answer routing questions.

When a direct path fails -- either the search gives up, or the unit runs out of
approach time -- it picks a vent, walks to the mouth, calls
`petports_ventTravel`, and resets everything stale on the far side: ground
target, search timer, approach timer, arrival flag, and the pather itself.
Bounded at MAX_VENT_HOPS, with tried vents remembered per task.

**PASS THE CHOSEN EXIT.** `petports_ventTravel(entityId, destinationId)` picks a
destination ITSELF when not given one, so evaluating which exit is best and then
not passing it means a multi-partner vent can send a unit somewhere strictly
worse. Currently latent -- every vent tested so far has exactly one partner --
but it is a real bug the moment anyone wires three vents together.

**Vents carry their own residency**, a 12-tile rect via the same stagehand the
ports use, spawned only when the vent is linked and configurable via
`petports_ventResidency`. Without it a hop can deliver a unit into an unloaded
chunk with no vent script running on the far side to catch it.

Destinations outside the network are allowed on purpose: a unit on task already
leaves the network on foot, vents exist precisely to reach out-of-the-way
routes, and an unloaded route fails its pathfinding test anyway -- the
constraint enforces itself without a rule.

#### Why greedy distance is the wrong rule

A hop is currently accepted only when the exit is closer TO THE TARGET than the
unit is right now, in a straight line. That has a fatal property on any layout
where the route is indirect:

Consider two vent pairs, lower-left <-> lower-right and upper-left <->
upper-right, with the item on the far right. The intended route is
lower-right -> lower-left, walk up, upper-left -> upper-right, walk down. The
FIRST leg moves AWAY from the item, so it is rejected and the route is never
started.

Worse, whether it is rejected depends on WHERE THE UNIT HAPPENS TO BE STANDING.
The same vent the unit refuses becomes acceptable once it has wandered further
from the target. Route availability should be a property of the layout the
player built, not of the unit's current position.

**Straight-line distance is a bad proxy for progress in a network with
teleports.** Vents exist to make Euclidean distance meaningless; using it to
decide whether a vent is worth taking undercuts the whole point. It works for
one hop with the exit nearer the goal, and fails exactly where vents matter.

#### Next up on vents

**BUILT: the thinking indicator.** Not an emote in the end. `emote()` is a
one-shot particle burst; a spinner is a STATE WITH DURATION, and world particles
do not follow the entity through a vent hop. It drives a dedicated `thinking`
stateType and `thinkingspinner` part in the drone's `.animation`, from
`petports_think.lua`.

Design points worth keeping. Callers PING every tick and nobody calls a release,
because a heartbeat cannot leak when a code path returns early and `update()`
returns early in half a dozen places. The pump lives in
`petportsTaskAction.update`, NOT `petBehavior.run()` -- run()'s cadence may be
the `querySurroundings` cooldown rather than a tick, and pumping from there
produced a spinner that would not expire. Three constants doing three separate
jobs, learned the hard way: `THINK_DELAY` (2.0, when to show), `THINK_GRACE`
(0.2, what counts as one continuous think), `THINK_MIN_SHOW` (0.75, anti-flash
floor); an earlier version had GRACE doing two of those and got the failure
modes of both. DELAY is 2.0 because measured think durations are BIMODAL --
cold-cache probing runs 45-50s, the post-vent-exit arc solve about 1.0s, and
nothing falls between.

**BUILT: one-way vents.** `exitIds()` reads INPUT nodes, `entryIds()` reads
OUTPUT nodes. A wire from vent A's INPUT to vent B's OUTPUT means A can send a
unit to B -- in at the input, out at the output. Two wires for a two-way vent,
one for a one-way. This deliberately runs against Starbound's usual reading,
where a signal flows output-to-input.

**It was built backwards first, and the failure mode is invisible downstream:**
it presents as routes existing only OPPOSITE to the direction the wiring
describes, which reads as a pathfinding fault. If routes ever only work
reversed, look here before anywhere else.

Supporting changes: `gatherVents` no longer requires a vent to have
destinations, because a terminal vent legitimately has none under directional
wiring and `pruneRouteCache` treats absence from the list as "physically
removed". `planRoute` skips vents with no exits before probing them.

**BUILT: vents fail closed.** `petports_ventTravel` used to fall through to a
RANDOM partner when the named destination was no longer wired, and return that
partner's position as success. It now refuses. The caller was also fixed:
`local ok = pcall(...)` captured only pcall's success flag, so a refusal
returning nil was indistinguishable from a completed hop.

**BUILT: registry-based topology invalidation.** Vents call
`petports_registryTouch()` on an actual link change, riding the same version
counter coverage changes use, so a rewiring in place is a first-class trigger
rather than a passenger on a rect change. `pruneRouteCache` drops only edges
naming vents that no longer exist, NOT a blanket clear -- deliberate asymmetry
with the coverage path, since a rewiring invalidates no walkability fact and a
cold cache costs 45+ seconds.

#### Vent pipes -- making the hop visible

SPECIFIED, NOT BUILT. A wired object that superficially resembles a pipe,
chained between vents. A unit entering a vent wired directly to another vent
travels instantly, as today. A unit entering a vent wired to a PIPE lights each
pipe in the run in sequence, so the player watches it go in one end, follows it
along the wall, and sees it come out the other.

This is characterisation more than mechanism, and it is worth building for that
alone: ambient traversal that LOOKS purposeful is most of the Axiom Verge
feeling, and a teleport that produces a unit out of nowhere gives all of it
back.

**A vent has to classify what is on the end of each wire.** Today `collectIds`
gathers partner ids and `refreshPartners` filters them by comparing
`world.entityName` against its own `objectName`. With pipes in the world a wire
route resolves to one of three things: another vent (a destination), a pipe (one
leg of a route toward a destination), or something else entirely -- a player
wiring a vent to a lightbulb, which that validation already exists to catch.

**A pipe run terminating in a vent is an EDGE**, and it has to enter the route
cache as the same kind of fact a direct vent-to-vent link is, or the planner
never learns the destination is reachable. What differs is the traversal, not
the topology. A pipe run terminating in nothing is not an edge, and should fail
closed the way a mis-wired vent already does rather than silently offering a
route to a dead end.

**Pipes need residency, but only their own tiles.** A vent holds a 12-tile rect
because a unit ARRIVES there and needs a script running to catch it. A pipe holds
a unit in transit and needs only the tiles it occupies to stay loaded, so its
per-object cost is far below a vent's. That distinction matters because a long
decorative run is exactly the thing players will build a lot of -- see the
existing note about vent residency scaling with vent count.

**TASK LIFETIME IMPLICATIONS, and they are the real work here.** Vent travel is
instantaneous today, so nothing in the task layer has any notion of a unit being
in transit. A pipe run has DURATION, and during it:

  - the unit is somewhere that is neither its origin nor its destination, and
    `mcontroller.position()` will say so
  - `TASK_DEADLINE` keeps counting, and a long enough run eats it
  - the leash, the recall ladder and both stall detectors read position and
    motion, and a unit inside a pipe is motionless somewhere unexpected
  - the port's claim needs refreshing throughout, or the trip outlives the claim

The cheapest shape is probably that the unit LEAVES the world for the duration
and the pipe run owns the animation, with the task suspended rather than
running. That is a guess. The alternative -- the unit exists and is moved along
the run -- touches every item on that list and wants measuring before it is
chosen over the other.

#### The route graph

BUILT. Routing is a graph search over VENT MOUTHS.

    nodes           the unit's position, every vent entry, every vent exit
    teleport edges  a vent entry to each of its exits -- free, always known
    walk edges      one node to another on foot -- PROBED, then cached

`petports_planRoute` is a breadth-first search over that graph, so the FEWEST
HOPS wins. It consults the cache first and issues AT MOST ONE PROBE per call,
returning "probing" -- planning is incremental across ticks and the caller keeps
asking until it gets a plan or nil.

**A single-hop question is not enough.** An earlier version asked only "does
this exit reach the target?", which rejects any first hop whose exit reaches
only ANOTHER VENT -- exactly what a multi-room layout looks like. The route
right-lower -> left box -> left-upper -> right-upper -> item needs two hops, and
no single-hop question can find it. Same failure as greedy distance, one level
up: the right question asked of too small a search.

**Probing** drives `PathFinder:start` and `explore` directly. `find()` hardcodes
`mcontroller.position()` as the source, so it cannot answer "is X reachable FROM
somewhere else" -- driving the two calls directly can, because `start` takes an
arbitrary source. No probe entities, no periodic survey.

**Cache keys are edges**, `from>to`, over four node kinds:

    u:<bucket>    the unit's position, bucketed at 16 tiles
    t:<bucket>    a target position, bucketed
    e:<ventId>    a vent entry
    x:<exitId>    a vent exit

`x:` to `e:` edges are pure terrain, so they are cached permanently and shared
with every unit through the port -- observed resolving in MILLISECONDS once
known. Only `u:` and `t:` edges are query-dependent, and bucketing makes those
reusable across every drop in a neighbourhood.

**PLANNING ORIGINATES AT THE PORT, NOT THE UNIT.** A port does not move, so its
`u:` edges are computed ONCE and reused by every unit and every future task.
Planning from the unit re-keys them whenever it drifts a bucket -- observed two
consecutive tasks probing the identical five edges from buckets 74,44 and then
75,44, roughly forty seconds of work discarded.

Slightly less accurate, since the unit is not always at its port. Acceptable:
the leash keeps it nearby, and a direct walk has already failed before routing
is consulted. AFTER a hop the unit genuinely is elsewhere, so the live position
takes over from there.

**RECALL NEVER VENT-ROUTES.** A walk home is not worth a route search -- if the
unit cannot walk back, the port re-homes it, which is instant and always works.
Routing a recall cost 38 seconds of probing before failing, and filled the cache
with `t:` keys for recall points chosen at random inside the rect that will
never be asked about again. Recall also targets a FIXED spot near the port
rather than a random standing point, so the destination stops varying between
attempts.

**A "just walk" answer is valid AFTER a hop.** Planning rejects zero-hop routes
normally, because the caller only asks after a direct walk failed. But once the
unit has hopped it is somewhere new, and walking is a fresh option -- observed a
unit land beside its target, discard exactly that answer, plan a second hop, and
take it.

**The cache is produced by UNITS and stored on PORTS.** Units are the only
entities that can pathfind; ports are resident whenever the network is and
survive reloads, while units respawn and would each rebuild it. Ports clear the
cache whenever coverage changes, since vents may have appeared or vanished.

**Vents are gathered from a rect INFLATED beyond coverage**, because a vent just
outside the boundary is still usable -- units on task leave the network freely.
Gathering only from inside made such a vent silently vanish from routing.

**Corrections applied to plans.** If a mouth turns out to be unreachable when
the unit actually walks it, the unit writes that edge as false -- correcting the
cache that produced the bad plan -- discards the plan and re-plans around it.

### Wiring conventions
`arch.vent.wiring`

**Wires mean exactly one thing in this system: routing between crates.** They
did not always. Vents were wired to link pairs and feeders were wired to bind to
a port; both are gone. Vent linking survives as an implementation but the concept
it belonged to — wiring as membership — was replaced by geography, and feeder
binding was removed with the feeder re-tasking. Keeping one meaning per mechanism
is the reason to resist adding more.

The engine imposes exactly one rule: an output node connects to an input node.
Everything past that is script-defined. A wire carries no inherent meaning, so
each object type decides for itself what a connection signifies.

**Validate what is on the other end.** A player can wire a crate to a lightbulb.
Nothing stops them and nothing warns them. Every wired object in this system
must confirm its partner is a compatible type before acting on the connection —
`petports_petvent.lua` does this by comparing `world.entityName` against its own
`objectName`, and crates need the same filter.

**Use extra nodes for richer topology rather than overloading one.** Vanilla
rail trams are the reference implementation: a centre input node takes call
buttons, while separate upper and lower nodes link stops to each other. Two
distinct meanings, kept apart by living on different nodes rather than by
inference. Crates currently need only one in and one out; a filter or call node
would go on its own node, not into the existing one.

**Direction is available when it matters.** `getOutputNodeIds` and
`getInputNodeIds` report each side separately, so an object can tell upstream
from downstream. Sorter crates depend on it: upstream is where a unit collects,
downstream is where it delivers. Vents ignore it deliberately — one wire links a
pair both ways. Which one an object uses should be stated in its header.

### A jump flies the plan's LANDING, not the plan's stated velocity
`arch.pathing.solvelaunch` -- see also `fact.pathing.eulertick`, `fact.pathing.arcmoverthrottle`, `dead.pathing.jumpescalation`

**A* PUTS A Land ON THE ASCENDING CROSSING.** It emits a Jump edge carrying a
velocity, then draws an arc that stops the first time that trajectory passes the
target height -- while the unit is still going up hard. Measured: `[12,45]`
against a landing three tiles up, crossed at t=0.074s still rising at `vy` 36,
carrying on to 8.44 tiles and coming down 3.66 tiles past the target.

The arc is not wrong about physics. The LAUNCH VELOCITY is the part of the edge
that cannot be honoured, and the TARGET is right -- so `solveLaunch` solves for a
launch that arrives at the plan's landing on the DESCENDING branch.

    branch 1   KEEP the planner's vx and solve vy.
               Its vx comes from {0, +-walkSpeed, +-runSpeed} and is the reach
               the plan counted on, so arrival time is fixed and only vy is free.
               This is what a normal working jump takes.

    branch 2   LOWER vx, pinning the apex just above the landing.
               For a target one tile right and three up, vx 12 crosses the
               column in 0.083s -- far too soon to have risen and fallen. That
               geometry is impossible, not badly tuned.

Both guarantee arriving descending, which is what makes a Land mean what it says.
Never more horizontal reach than planned; raises still capped.

**SOLVED ON THE DISCRETE TRAJECTORY**, per `fact.pathing.eulertick`. The first
version solved the continuous parabola exactly and the unit still arrived half a
tile high and clipped the ledge.

**THE ARC MOVER HAS TO BE TOLD**, twice over. It steers toward the arc edge's own
velocity, so a lowered launch is pushed straight back up to the planned value on
the first airborne tick unless it is handed the launched value -- gated on the
planned velocity matching, so a stale record cannot be applied to another jump.
And it stops the unit on arrival rather than flying it off the landing, per
`fact.pathing.arcmoverthrottle`.

`LAND_BRAKE_REACH` is sized by the MOVER'S CADENCE, not by taste: 0.5 tiles
against 0.67 of travel per look at script delta 5. If the action's delta changes,
that constant moves with it.

### Module effects are pushed as a whole set under one category
`arch.module.effects` -- see also `arch.module.slots`

A module item declares `petports_moduleEffects`, a list. The port unions the
lists across every socketed slot, deduplicates, sorts, and pushes the result to
the unit, which applies it with `status.setPersistentEffects` under a category of
its own.

**setPersistentEffects REPLACES THE CATEGORY WHOLESALE**, which is the entire
reason there is no removal path and no diffing. Everything sent is applied,
anything no longer sent is gone. An add/remove protocol would have to stay in
step with `petData` across respawn, world reload, and the unit being carried to
another port -- three places to silently fall behind.

**PUSHED ON A SIGNATURE THAT INCLUDES THE ENTITY ID**, the same shape as
`ventSignature`, rather than on a dirty flag. A flag has to be set by every site
that mutates modules and is wrong the moment one forgets -- and a respawned unit
is not a mutation at all, so a flag would not cover it.

Sorted before hashing so two modules swapped between slots do not spell the same
set two ways and push a redundant update.

**A STATUS EFFECT RATHER THAN A FLAG THE UNIT'S SCRIPTS READ**, mirroring vanilla
augments: the behaviour is carried by an asset that can be authored, patched or
disabled without touching this mod's Lua.

### The port owns an enabled switch and four participation groups
`arch.port.switches` -- see also `dd.port.participationgroups`

Both are OBJECT parameters, not `petData`: they describe the PORT, survive the
item being taken out and put back, and do not travel with a unit carried
elsewhere. Both default to on when ABSENT, so no port in an existing world
switches itself off on update.

**THE HANDLERS ONLY WRITE. `update` RECONCILES.** One place decides whether a unit
should exist, which also covers the cases no handler sees: a world loading with a
port already off, and an item socketed into a port that is already off. Disabling
writes the item back first, so cargo and resources survive.

**NOT AN EARLY RETURN.** The item write-back, the pane mirror, the module effect
push and `workUpdate`'s housekeeping all keep running while a port is off. An
early return there is how the replant sweep once stopped running for empty ports.

### One string table for every pane
`arch.pane.stringtable` -- see also `arch.pane.hoverlayer`, `todo.pane.tooltipstrings`

EVERY VISIBLE STRING LIVES IN ONE ASSET,
`/interface/lofty_petports/shared/petports_strings.config`, resolved by
`/scripts/lofty_petports/petports_strings.lua`.

**THE PAIR IS SPLIT ACROSS TWO DIRECTORIES ON PURPOSE.** The data is a pane
asset and is read by path, which works from anywhere. The loader is `require`d,
and every proven require path in this mod points at `/scripts/lofty_petports/`.
Whether require resolves out of `/interface` is not known, and finding out costs
a pane that will not open -- MEASURED, that is exactly what a missing require
does: the script does not load, the pane still opens, and nothing in the UI says
so. See `fact.pane.requiresilent`.

**A WIDGET NAMES A KEY, NOT A STRING.** `petportsString` for a label or a button
caption, `petportsTip` for hover text, both dotted keys swept at init. Adding or
rewording a string is the table plus one key and no Lua.

**"--" IS THE FALLBACK AND IT IS DECLARED IN THE PANE, NOT WRITTEN BY THE
LOADER.** Every migrated widget carries `"value" : "--"`, and a key that does not
resolve is simply left alone. A broken load is therefore a pane full of dashes:
unmistakable in testing, and unreachable in a shipped build without the asset
being absent outright. Verified in game by misfiling the loader.

**RUNTIME TEXT IS A FORMAT STRING, NOT CONCATENATION.** `"Allow" .. " " .. name`
bakes English word order into the pane; `"%s %s"` lets a translator move the
pieces, and the verbs are their own keys because they are words rather than
code. `petports_format` applies the fallback on a missing key, a non-string, or
a specifier mismatch.

**PANES NEVER NAME `PETPORTS_STRING_MISSING`.** `petports_stringOr` and
`petports_format` apply it internally. A constant read across a file boundary is
what `petports_paneheck.py` flags as a possible nil global -- correctly, since
that is how it fails -- and four panes writing `or PETPORTS_STRING_MISSING`
would bury a real finding in noise.

**`common` IS FOR WORDING THAT REPEATS.** "Beacon active" was two identical
literals in two panes and is now one key. A string moves there the moment a
second pane needs it, so the two cannot drift.

### Reagent routing into the upcycler -- BUILT
`arch.upcycler.reagentrouting` -- see also `dd.upcycler.reagentdefault`, `todo.upcycler.slotorderdup`

A delivered item the flavor manifest recognises goes to `MACHINE_SLOT_REAGENT`
rather than the burner, and the remainder goes to `MACHINE_SLOT_INPUT` in the
same trip. REVISED THIS SESSION: every offer is now CAPPED to measured,
descriptor-true slot room before the engine sees it, and the burner fallback is
GATED on the rule's burn box -- a denied burner keeps the remainder aboard to
file into ordinary storage. See `arch.upcycler.burnbox` for the predicate both
dispatch and arrival now share, and `fact.item.descriptorroom` for why the cap
exists.

**NO NEW WORK GENERATOR AND NO FETCH LOGIC.** The drain path already brought the
item; the only thing that changed is which slot it lands in. One call site in
`petports_petport.lua` -- the other `MACHINE_SLOT_INPUT` use is a read.

**THE PORT NOW NEEDS THE FLAVOR MANIFEST** for one question, so it requires
`petports_flavors.lua`. That is what lets a modded reagent route without anyone
re-ticking anything.

**MACHINE_SLOT_REAGENT IS A THIRD COPY OF A NUMBER.** Deliberate -- see
`todo.upcycler.slotorderdup`. If a `SLOT_` constant moves in the upcycler, this
moves with it, and the failure is a unit posting surplus into whatever the slot
became.

### The petport pane draws its own tooltips on two canvases
`arch.pane.hoverlayer` -- see also `fact.pane.notooltips`, `fact.pane.canvasocclusion`, `fact.pane.textmeasure`, `fact.pane.paneclip`

The engine will not give a ContainerPane script tooltips, so this pane does what
`/interface/easel/signstoregui.lua` does for its entire interface: reads the
cursor off a canvas and draws the tooltip by hand.

**TWO CANVASES, AND THE SPLIT IS FORCED.** `hoverCanvas` is full-pane at zlevel
-5, beneath the background, never drawn on -- it only answers where the cursor is,
and cannot occlude anything because nothing is under it. `tipCanvas` is small,
topmost and `visible: false` until there is something to say, then moved.

**TOOLTIP TEXT IS A KEY, NOT A STRING.** Declared as `petportsTip` on the widget
it describes and resolved against the shared table -- see
`arch.pane.stringtable`. Dynamic text -- the diagnostics -- still comes from
code, because only its existence is static.

**THE BOX IS SIZED BY MEASUREMENT.** A canvas cannot measure text, but a LABEL
reports the size of the text it laid out. Two hidden labels, one per font size,
are written to and read back with `widget.getSize`; the box is
`TIP_PAD * 2 + titleH + TIP_GAP + bodyH`. `TIP_GAP` is the only authored spacing
left and it is a gap between blocks rather than a guess at either one's size, so
it does not vary with script. See `fact.pane.textmeasure` and
`dead.pane.charwidth`.

**TEXT IS ANCHORED TOP AND FLOWS DOWN.** Both blocks are positioned from the top
edge of the box, so a wrong height can only leave slack or spill below -- it
cannot collide with the title. Bottom anchoring cannot do that: on a canvas a
bottom-anchored wrapped block grows UPWARD from its anchor, which put the body
through the title for three builds. See `fact.pane.canvasanchor`.

**THE BOX IS ANCHORED TO THE WIDGET, NOT THE POINTER.** Its top-left sits on the
hovered widget's top-right, so it opens down and to the right, never covers a
9px checkbox, and does not drift while hovering. Anchoring to the cursor meant
two clamps, and the clamps -- not the engine -- were what pinned every tooltip in
the participation band to one bottom edge.

**IT FLIPS ACROSS THE WIDGET AT THE PANE EDGE, IT DOES NOT SLIDE.** Sliding back
along the edge is what parked the box on top of the checkbox. `TIP_MARGIN` is a
keep-off from a measured clipping boundary: the pane art is 337 wide and a box
reaching exactly 337 was already cut.

A canvas can be moved but NOT RESIZED, so `tipCanvas` is declared at the size of
the largest tooltip and the drawn box shrinks inside it. 80px is a hard ceiling
and exceeding it now logs.

### Metrics -- gathered on the port, stored on the item
`arch.port.metrics` -- see also `dd.dispatch.tidyscore`, `dd.pane.ratesnottotals`, `dd.unit.odometer`

Per-unit lifetime totals live on `petData.stats` and ride `writeBackToItem`
wholesale -- they survive unsocket, reload and respawn, and travel with the
item, which is what an examiner NPC will one day inspect. Keys: `moved`,
`planted`, `watered`, `harvested`, `livestock`, `traveled`, `active`,
`headpats`, `tidy`.

**ONE LOCAL SLOT FOR THE WHOLE LAYER.** Three functions -- `metrics.add`,
`metrics.noteStorageTake`, `metrics.paneStats` -- live on one `metrics` table
because the main chunk sits near Lua's local ceiling; see
`fact.port.localceiling`.

**NO dirty FLAG, EVER.** Every moved/tidy event happens on a path that already
ends in a flush, and `active` ticks every frame -- marking it dirty would turn
the slow write timer into a write-per-tick. At most `WRITE_INTERVAL` of stats
is at risk to a crash, accepted.

**COUNTED AT CHOKE POINTS, NOT SPRINKLED.** `moved` in the three deposit
functions (placed sums only); `planted` and `watered` in the task-report
branches, because only the task type knows what a `spendSeed` MEANT;
`harvested` and `livestock` one per done-report of their task types, whatever
the yield; `tidy` in `metrics.noteStorageTake` after both withdraws; `active`
and `traveled` in `update()`.

**THE MIRROR CARRIES NUMBERS, THE PANE OWNS WORDS AND RATES** -- the bodyKind
split. `activeMinutes` is floored to whole minutes and `traveled` to tens
WHILE ON A TASK (exact at rest), because both would otherwise defeat the
mirror's change gate and sync the blob to clients every interval.

**`tidy` IS GATHERED AND NOT MIRRORED.** The raw number is never displayed
(`dd.dispatch.tidyscore`); each increment logs `TIDY +1`, which is its only
verification until Maxwell exists.

### The Stats tab is a list, and steady state is text-only
`arch.pane.statslist` -- see also `arch.pane.stringtable`

Fixed labels were replaced by `statsScroll.statsList` when the metric set
outgrew eight positions -- and per-treat counters will have no fixed count at
all.

**REBUILD ONLY ON A LINE-COUNT CHANGE; setText OTHERWISE.** MEASURED: text
updates on existing rows do not strobe the widget. `addListItem` still repaints
the whole container, so rebuilds happen only on tab entry and when the rate
line appears at minute six.

**POPULATED ONLY WHILE ITS TAB IS ACTIVE, cleared otherwise.** Whether
`setVisible` on a scrollArea cascades to the list inside is UNMEASURED; an
empty list draws nothing wherever visibility lands, and the rebuild each visit
hides inside the repaint the tab click already causes.

**STRIPES AND SEPARATOR DRESSING ARE SET AT REBUILD ONLY** -- the one moment a
repaint is already paid for. Safe because row meanings cannot change without
the count changing. Parity resets at each separator so alternation reads as
belonging to its block; separators wear the clear art and a dull-orange dashed
placeholder line (`todo.art.statsdressing`).

**SELECTION IS MEANINGLESS AND MADE INVISIBLE, NOT FOUGHT.** Both schema BGs
are the clear art and the callback is a no-op that tolerates being fired
mid-rebuild, because `clearListItems` invokes it and
`setListSelected(list, nil)` throws.

### The burn box, and the one room predicate
`arch.upcycler.burnbox` -- see also `arch.upcycler.reagentrouting`, `dd.upcycler.reagentdefault`

THE RULE SHAPE IS WRITTEN DOWN IN TWO PLACES WITH NOTHING LINKING THEM --
`storedRules()` on the object and `applyState()` in the pane. THEY DRIFTED,
2026-08-29: the pane's copy was never updated when `burn` was added, so it
rebuilt every rule as `{ item, max }` and dropped both exclusions. Not a
display bug -- the pane holds the authoritative copy while open and writes the
WHOLE state on every edit, so opening the pane and touching anything at all
destroyed a stored exclusion on the object. Both files now carry a comment
naming the other. ADDING A FIELD TO A RULE MEANS ADDING IT TWICE.

**BOTH EXCLUSIONS ARE ENFORCED AT THE SLOT, NOT ONLY AT ROUTING, as of
2026-08-29.** The furnace door has always refused a burn-denied hand-drop. The
charge loader had NO equivalent, so a reagent-denied item dropped into the
reagent slot was consumed exactly as if the box were ticked and the box meant
nothing to anyone but the units delivering. `consumeReagent` now refuses one,
which is also what makes the second rescue reachable -- it runs ABOVE
`shuttleSlots` in `update`, so without the refusal the item was spent on the
tick it landed.

**AND THE RESCUE IS A MIRRORED PAIR, sharing one `bulkRescue`.** Burn-denied
stock in the burner goes to the reagent slot; reagent-denied stock in the
reagent slot goes to the burner. Same shape from opposite ends, mutually
exclusive by configuration, and each only reachable because the slot the item
is LEAVING refuses it -- so a rescue never races a consumer for the same item.
Two dead ends state themselves rather than failing quietly: both slots denied,
and denied-plus-exempt. Written as one function on purpose; a near-identical
pair with nothing linking them is the drift recorded immediately below.

A rule is now `{ item, max, reagent, burn }`, both flags EXCLUSIONS: absent
allows, only an explicit `false` closes that slot -- so every pre-checkbox rule
behaves exactly as it did. The pane's `rowBurn` sits left of `rowReagent`
(order: burn, then reagent) and writes only the untick.

**`machineRuleRoom` IS THE ONE PREDICATE.** It sums exactly the slots the
rule's checkboxes leave open, descriptor-true (`machineSlotRoom` compares
parameters whenever the caller has real ones), and it is asked by
`machineWantsAny`, `machineRoomFor` AND drain's per-stack cap. The patrol bug
class is precisely a dispatch that asks a different question than the arrival
answers; any change to which slots a delivery may use happens here and nowhere
else.

**ARRIVAL OFFERS ARE CAPPED TO MEASURED ROOM** before `containerPutItemsAt`
ever runs, so whether the engine splits an oversized offer stops mattering. A
refused remainder with the burner denied stays aboard and files to storage --
a fallback that destroys what the checkbox protects would make the checkbox a
lie.

**THE FURNACE DOOR ENFORCES IT TOO.** A hand-dropped burn-denied item sits in
the burner refusing, with a state line saying why -- a checkbox that only
guards the couriers while the machine eats hand-drops also lies. See
`todo.upcycler.cantburnlight` for making that state visible without a log.

### The slot shuttle
`arch.upcycler.shuttle` -- see also `arch.upcycler.burnbox`

The burner eats items per second, the charge eats one reagent per spend --
left alone, a both-boxes rule either strands reagents idle or runs the reagent
slot dry while good reagents burn. The machine now moves its own stock.

**THE PACED DIRECTIONS: ONE ITEM, ONLY INTO AN EMPTY SLOT.** Self-pacing with
no rates to tune: the burner drains, empties, pulls one from reagent stock
(both boxes, plus the exempt check the furnace door runs); the charge spends
the reagent, the slot empties, pulls one from burner stock (reagent box plus
the manifest). The `>= 2` guard leaves the last both-boxes item to burn rather
than ping-ponging one item between slots forever.

**THE BULK RESCUE, FIRST AND UNPACED.** Burn-denied stock in the burner has
exactly one legal destination, and pacing it stranded a measured ~400 milk
behind one parked reagent the moment the charge filled. Take all, put, put
back what refuses -- the engine sizes the merge, maxStack and rot and all, so
the machine needs no stack math. Two change-gated waiting states: a DIFFERENT
item parked in the reagent slot (no attempt made), and a same-name stack the
engine cannot merge, which cycles a cheap take-and-return until the charge
drains the slot (`todo.upcycler.rescuechurn` for the optional gate).

**RUNS WHERE consumeReagent RUNS -- above the enabled gate** -- and for the
same reason: moving items between a machine's own slots destroys nothing.

### The report handler cleans up before it delivers
`arch.port.reporthandler`

MEASURED 2026-08-29: a unit patrolled an upcycler at three trips a second and
every cycle logged "failure 1" -- the escalating backoff never climbed,
because the `outcome == "done"` cleanup sat BELOW the delivery branches and
erased the failure `noteFailure` had just recorded. "Done" attests the WALK,
not the delivery.

The cleanup now runs ABOVE the arrival work: it clears stale failures from
earlier attempts -- its actual job -- plus the reachability resets that
reaching the target genuinely attests, and anything the arrival work notes
afterwards stands. This protected drain and tidy arrivals too, which carried
the same latent wipe.

### Constants are globals
`arch.port.constantsglobal` -- see also `fact.port.localceiling`

73 of the port's 74 UPPER_CASE constants are declared bare, freeing their
local slots, because DE-LOCALIZING TOUCHES NO READ SITE -- delete the word
`local` and every reference resolves to the global unchanged, which is what
made this safe where a rename to a constants table would not have been.

Globals are CONTEXT-scoped: visible to the scripts this file requires and
nothing else. Checked at conversion: none of the required petports scripts
define or read any of these names. `DEBUG` is the one exception and stays
local -- generic enough that a required script could someday own a global by
that name, and a collision on a debug flag fails silently in the worst
direction.

The local/global split still signals what it always did for FUNCTIONS: global
means "reachable from a handler registered in init". UPPER_CASE already says
"constant" without `local` saying it twice.

### Headpats ride vanilla's interaction
`arch.unit.headpat` -- see also `fact.unit.groundpetinteract`, `dd.unit.headpatgate`

The contract replaces `interact()` and CARRIES VANILLA'S BODY FORWARD -- the
happy emote on `interactCooldown` -- then reports `petports_headpat` to
`self.anchorId`, vanilla's own field, refreshed by vanilla every second. No
`setAnchor` shadow and no `setInteractive` call: vanilla already does both
jobs, and reading its field beats shadowing its function to duplicate it.

The port's handler just counts. It is the documented future home of the
stuck-cargo drop: cargo lives on petData, so the port is the only party that
can ever decide "drop it" versus "pat".

## DESIGN DECISIONS

### The port band splits by what the player SEES, not by what the code owns
`dd.pane.bandsplit`

Left column is invisible functionality: whether the port runs at all, and which
network it belongs to. Nothing there produces anything you can point at in the
world. Right column is the opposite -- tick a box, watch something start
happening on screen.

**CLAIM MARKERS IS ON THE RIGHT AND TECHNICALLY BELONGS ON THE LEFT.** It is a
PORT setting, stored beside enabled and participation, and it gates no work. But
it is the most immediately visible switch in the pane, so it sits with the task
toggles, one row clear of them. Anyone tidying that band by ownership will move
it and make the pane worse.

Both columns share baselines: heading row 296, then 284, 268, and a fourth at
252 that only the checkbox column uses. A checkbox sits 4px under its own label.

### The upcycler explains its reagent checkbox with art, not a tooltip
`dd.upcycler.bakedindicators` -- see also `arch.pane.hoverlayer`, `todo.pane.tooltipstrings`

The reagent checkbox needs explaining and is NOT getting a tooltip. The pane
grows a drawn indicator instead -- a line tracing the checkbox column to the
reagent slot -- so the control explains itself to someone who was never going to
hover it.

**THIS IS WHY THE UPCYCLER HAS NO HOVER LAYER AND IS NOT GETTING ONE.** It is a
ContainerPane, so `createTooltip` is closed to it, and the only control that
needed hover text now has a better answer. A future maintainer finding no
tooltips here is looking at a decision, not a gap -- `createTooltip` has already
been re-added to this pane once on that assumption and deleted again.

### A reagent routes by default, and the tick is an exclusion
`dd.upcycler.reagentdefault` -- see also `arch.upcycler.reagentrouting`

Absent means "ask the flavor manifest"; only `false` is stored. Ticking removes
the field rather than writing `true`.

**SO THE DEFAULT STAYS RIGHT FOR SOMEONE WHO NEVER OPENS THE LIST**, and a rule
written before this feature existed -- or one whose item a MOD later adds to a
flavor -- starts routing without anyone finding it. Same shape as the filter
rules, and for the same reason.

**NOTHING REACHES AN UPCYCLER UNLESS THE PLAYER FILTERED IT IN**, so anything
arriving is already surplus by their own definition. Flavoring it is strictly
better use of it than burning it, which is what makes routing-by-default safe
rather than presumptuous.

### A list row is as wide as its scroll area minus eight
`dd.pane.rowwidth`

MEASURED across every list in the mod: a scroll area leaves 8px for its
scrollbar. Restock's requests and the deposit beacon's rules both do; the
upcycler's two lists were leaving 28 and 12, which is the gap between the row
art and the scrollbar.

The row art is COLUMN-IDENTICAL -- every column is the same pixels -- so a new
width is generated exactly rather than stretched. `row_148` and `row_164` were
made that way from `row_144`.

**TWO LISTS IN ONE PANE CAN NEED TWO WIDTHS**, which is why the upcycler's row
art constants are split by list rather than shared. Sharing them meant widening
one widened both.

### Treat colours survive colour blindness and the sprites do not matter
`dd.art.treatcolours`

The sprites are placeholder squares. THE COLOURS ARE NOT.

The obvious palette does not survive red-green colour blindness: spicy, zesty and
savory all collapse toward the same olive, and a first pass had spicy and zesty
at luminance 0.207 and 0.191 -- indistinguishable.

The seven are spread across LIGHTNESS as well as hue. Four warm flavors in four
brightness bands (sour 0.67, zesty 0.38, spicy 0.21, savory 0.03) and three cool
ones in three (sweet 0.78, sharp 0.30, bitter 0.09). Worst pair is 78 units apart
under simulated deuteranopia and protanopia, up from 44.

Keep that spread when real art lands.

### The active provider beacon needs no new item
`dd.beacon.activeprovider` -- see also `dd.beacon.selfdeclaring`, `arch.cargo.deposit`

Factorio's active provider chest, stated in this system's terms: **anything in
this container that is not a beacon needs to be somewhere else.** A unit
collects from it and ferries the contents to the network's deposit targets until
it is empty.

**IT IS ALREADY REACHABLE AND WAS FILED AS UNBUILT FOR MONTHS.** A deposit
beacon with no filters and accept-everything switched off IS an active provider:
nothing matches, so everything in the crate is a misfit, and eviction already
moves a misfit to wherever both accepts it and has room. No new item, no new
behaviour string, no new work generator.

That is the payoff of eviction running the SAME predicate as deposit rather than
a parallel one -- a feature nobody set out to build fell out of two existing
rules meeting.

**Its interaction with filters is the part worth stating.** An active provider
that is ALSO filtered means "push out everything except these", which is a
reasonable thing to want and is the same chain read with a different first
beacon.

### Beacons need an off switch
`dd.beacon.offswitch`

A beacon should be togglable in place, because the alternative is taking it out
of the chest and finding somewhere to keep it. The current icon carries a GREEN
DOT in its top-right corner for on; off is the same icon with a RED dot.

**The off state is what makes active providers safe.** An active provider empties
its container of everything that is not a beacon, so a player who stored spare
beacons in one would watch them get hauled away. Beacons are ignored by the
purge, and an OFF beacon is still a beacon for that purpose -- switching one off
parks it, it does not turn it into cargo.

**The icon is the hard part, not the state.** `inventoryIcon` is a config field.
Swapping it per instance means either two item definitions with an item swap on
toggle -- which loses stackability and anything per-instance across the swap --
or a parameter override of `inventoryIcon`. UNVERIFIED whether the inventory
renders an instance-parameter icon override at all; check that before designing
around it.

Note the existing beacon is `maxStack` 1000, and its own header already flags
that a CONFIGURED beacon needs `maxStack` 1. On/off is per-instance state, so
the toggle is also the first thing that makes a beacon unstackable.

### Beacons: a container declares its own purpose
`dd.beacon.selfdeclaring`

An item whose config carries `petports_sortingBeaconBehavior` makes the container
holding it a target of that behaviour. Currently one behaviour, `"deposit"`.

**Not a registry of designated containers.** A registry has to be kept in step
with a world where chests are mined, moved and replaced, and it leaks an entry
every time that goes wrong. Reading the container answers the question from the
only authority that cannot disagree with itself, and a player retasks a chest by
dropping an item in it.

The tag lives in the item's CONFIG rather than instance parameters, so every copy
works -- crafted, spawned, admin-given. `beaconBehaviorOf` checks parameters
first and config second, the same precedence petData uses, leaving room for a
configured beacon later without changing how it is found.

Detection is `world.containerSize(id) > 0`, NOT a list of object names -- a name
list misses every modded chest and there are a great many modded chests.
`world.containerItems` is walked with `pairs`, not `ipairs`: it is keyed by slot
and empty slots leave holes that stop ipairs at the first gap.

`root.itemConfig` is called unguarded. An item in a container HAS a config;
Starbound fails world load outright on a missing item definition rather than
degrading, so a world holding one never reaches that line.

Scanned every `BEACON_INTERVAL` (5s), which is slow on purpose -- a beacon goes
into a chest once and sits there, and what churns is the chest's other contents,
which this does not care about.

### Fragmentation is the player's problem, and that is the design
`dd.cargo.fragmentation`

Units deposit into whichever reachable target will take a stack, so a network's
storage fragments -- forty copper bars across three crates rather than one. This
is ACCEPTED AND EXPECTED behaviour, not a defect to engineer around.

Defragmentation is deferred to PLAYER ENGINEERING. The mod's job is to ship the
primitives -- deposit targets, filters, active providers, wired routing between
crates -- and let players assemble their own consolidation pipelines out of them
inside their own builds. A player who wants all their copper in one box wires an
active provider chain that ends there, and that is a thing they built and
understand rather than a thing that happened to them.

Why not solve it centrally: automatic defrag needs a global view of network
storage, a policy for what "consolidated" means, and a way to express
exceptions, and the player is better placed to decide all three. It would also
be constantly running work nobody asked for, on a system whose entire cost model
is "work only happens where a player is".

### The unit carries, the port owns
`dd.cargo.portowns`

`world.takeItemDrop` returns an item descriptor and the unit used to discard it,
which destroyed the pickup. It now travels back on the task report as `cargo`,
and the port appends it to `self.petData.cargo`.

**On petData, not on the monster's storage table.** Storage syncs through
`setAnchor`'s params echo, which whitelists specific fields and IGNORES the first
callback after a spawn to avoid clobbering a restore. That suppression is right
for state the unit re-derives and wrong for an item that exists exactly once.

**Written through immediately.** `flushCargo` calls `writeBackToItem` on the spot
rather than waiting out `WRITE_INTERVAL`. Everything else on petData is
re-derivable, so deferring it costs a stale number; cargo is not, and between the
handover and the write the item exists only in the port's memory. It also zeroes
`workTimer` so the deposit dispatches on the next tick instead of up to a second
later.

**Stacks merge on name AND parameters.** Fifty pickups of one block become one
entry of fifty. Two `sb_musicsheet` with different `music` parameters stay
separate -- merging on name alone would silently duplicate one song and destroy
the other.

**THERE IS A LOSS WINDOW.** takeItemDrop destroys the world drop before the
report is sent, so a port mined in that second loses the item. The port logs
`ITEM LOST` via sb.logError if cargo arrives with no petData.

**No capacity limit, on purpose.** A cap that silently drops items is worse than
no cap; the right shape is the port refusing to DISPATCH collection when full,
and that belongs with whatever capacity model eventually lands. Until then the
stack count in the log is how unbounded growth stays visible. Note nothing
enforces per-item `maxStack` on the way in -- `money` reached 70 in one entry --
which does not matter while cargo is an opaque blob and will matter when it meets
a container.

### Claims: exclusive for TAKES, per-port for PUTS
`dd.dispatch.claimscope`

A claim keyed `work:<id>` is exclusive across the whole network. One keyed
`work:<id>@<portId>` is per-port, so several ports can hold it at once.

**Takes must be exclusive.** The supply is finite, so a per-port key sends every
port's unit after the same items and all but the first arrive to find them gone
and eat a backoff. Measured: three ports each dispatched a unit across the base
for the same THREE Pet Treats.

**Puts are per-port.** `containerAddItems` and `containerPutItemsAt` give every
arrival a truthful leftover, so several units genuinely can share a destination
and serialising them would only reduce throughput.

The exception that proves it: `upcycle` is a put and is nonetheless exclusive,
because when a machine's ROOM is the scarce resource the sharing argument
inverts.

**Ordering decides preference; claims decide availability.** Trying to make
ordering do both produced a real bug — see "Ranking by distance under scarcity"
below.

### Machines are ranked emptiest-first, always
`dd.dispatch.emptiestfirst` -- see also `dead.dispatch.nearestfirst`

**SPLIT OUT OF THE FAILURE THAT PRODUCED IT**, because the reason emptiest-first
exists was only recorded inside the record of what happened when it did not.

**ROOM IS DELIVERY SIZE.** A machine with a thousand free is a thousand-item
trip. Sorting candidates by free room therefore already sorts them by trip
value, and it self-balances with no rule enforcing it: a machine that has been
starved has the most room and wins the next dispatch.

Distance is not consulted at all. See the disproven entry for what happens when
it is -- the short answer is that trips are not small because of scarcity, they
are small because a distance ranking keeps choosing machines that cannot accept
anything.

### Discovery belongs to the port, not the pet
`dd.dispatch.portdiscovery`

Vanilla's seam is `querySurroundings` -> `reactToObject`, which is pet-local: it
scans a radius around wherever the unit happens to be standing. Work discovery
must NOT ride that, because it would never touch the coverage rect — the network
would be built and never exercised.

The port scans its rect, queues work, and dispatches. The pet claims and
executes. The port is the right owner on every count: it already holds the rect,
it is already resident whenever the network is, and it already survives reload.

**Queues stay port-owned even though dispatch is union-wide.** A union is a VIEW
assembled at dispatch time by walking member ports' queues — see "Work claims"
for why nothing durable can be keyed on a cluster.

### Tidy Score counts type-eliminations, not entropy in nats
`dd.dispatch.tidyscore` -- see also `dd.dispatch.emptiestfirst`

The mod's thesis is container entropy: a container costs cognitive effort
proportional to `ln(k!)` where k is distinct item types, and the fleet's real
work is reducing it.

**MEASURING IT PROPERLY WAS CONSIDERED AND DROPPED.** What `ln(k!)` actually
buys is pricing "moved one odd item out of a mixed crate" above "moved five
hundred dirt". Nothing else. Total items moved already carries volume, so the
log earns its place only by being the other axis -- and it costs a unit nobody
can explain, a number with no bounds to compare against, and continuous
measurement.

**SO: WHEN A UNIT REMOVES THE LAST STACK OF A TYPE FROM A CONTAINER, +1.** One
sentence to explain, an integer, an event rather than a differential, and it
keeps the only distinction that mattered.

**THE FLEET CANNOT MAKE IT WORSE, BY CONSTRUCTION.** Every put a unit makes is
filter-approved: deposits go where the filter accepts them, restock delivers to
crates that asked, tidy moves misfits toward where they belong, compaction
merges. There is no path by which a unit adds a type to a container that did not
ask for it. Monotonic without clamping.

**DISPLAYED AS A RANK, NEVER AS THE RAW NUMBER**, because a raw number the player
has no scale for is noise. Ranks are granted by an examiner NPC rather than
assigned automatically -- which puts the thematic naming on a character instead
of on a squirrel, and makes the rank something the player goes and gets.

**GATHERED AS OF 2026-08-29.** `petData.stats.tidy`, +1 in
`metrics.noteStorageTake` when a withdraw leaves `containerAvailable` at zero
for the taken name -- name-level counting is exactly the grain the player's
eye uses, which is the one place that engine quirk helps. MACHINES DO NOT
SCORE (`dd.upcycler.slotsaremeanings`): emptying an output slot eliminates "a
type" every time and would credit routine fuel hauling as housekeeping. Every
increment logs, still displayed nowhere; Maxwell is the display
(`todo.unit.maidrank`).

### The harvest pool, and why the field probably feeds itself
`dd.farming.harvestpool`

Harvest yields come from a treasure pool named by the stage. Potato's:

    "potatoHarvest" : [
      [0, {
        "fill" : [
          {"item" : "potatoseed"}
        ],
        "pool" : [
          {"weight" : 0.89, "item" : "potato"},
          {"weight" : 0.01, "item" : "potatoseed"},
          {"weight" : 0.1,  "item" : "plantfibre"}
        ],
        "poolRounds" : [
          [0.6, 1],
          [0.4, 2]
        ]
      }]
    ]

**Nothing guarantees a crop yields its produce.** The weighted pool draws one or
two rounds (60/40), and a round can come back plant fibre. A unit that harvests
and collects nothing edible is a NORMAL outcome, not a fault, and neither the
task layer nor the log should treat an empty-handed harvest as a failure.

**INFERRED, WORTH CONFIRMING: `fill` is unconditional and `pool` is the random
part.** If that reading is right, every potato harvest returns at least one
`potatoseed` regardless of what the weighted rounds do — and a destroyed crop
becomes effectively perpetual with one extra step, because the thing needed to
replant it is lying on the ground where it died. Worth verifying before leaning
on it, since it is the difference between "the player must stock seeds" and "the
field sustains itself".

**If it holds, replanting should take the seed FIRST.** The natural sequence
becomes harvest, pick up the seed, replant the tile, and leave the produce as an
ordinary drop for whichever unit collects next. That resolves the replant intent
in the same visit rather than on a later pass, which matters given the one-slot
cargo model — a unit can only carry one of the several things a harvest drops
anyway, so choosing the seed costs nothing and closes the loop immediately.

Note this makes the replant intent a fallback rather than the main path: it
covers the harvest that did not return a seed, the seed a player picked up
first, and the field that was harvested before this feature existed.

**Scale is the thing to watch.** The handoff already warns that
`world.properties` is replicated state and should stay small. A player who
harvests a sixty-tile potato field in one pass creates sixty records at once,
and they persist until serviced. Keep each record minimal — tile key plus seed
name — and note `petports_tileKey` already exists in `petports_work.lua` for
exactly this shape of key.

**Orphan risk, same shape as every other durable structure here.** A record on a
tile that later falls outside all coverage is never serviced and never cleared,
because both invalidation conditions require somebody to look at the tile. That
is the orphaned-stagehand problem wearing a different hat, and it wants a sweep
rather than being discovered as a slowly growing world property.

### Promoting a subgroup to a group, and the saved-rule hazard underneath it
`dd.filter.groupnotsubgroup` -- see also `arch.filter.exceptids`, `arch.filter.subgroupor`

Pet Treats began as one subgroup inside Petports and had to become a GROUP.
Picking a group with nothing excluded already means every member, so a subgroup
that also means every member is a second way to say the same thing sitting
beside seven boxes that each mean one thing. Promoting it made the group itself
the "all" and left the subgroups a clean mutually exclusive set.

### The taxonomy: what an item IS versus what it looks like
`dd.filter.taxonomy`

74 groups, 209 subgroups. The organising principle is that those are two
different axes and an object answers both.

**Furniture is its own group, split by category** — furniture, decorative,
lighting, storage, doors, wiring, traps, teleporters, terraformers, spawners,
breakables, ship fittings, uncategorised. It used to be one 19-category tile
buried inside Building Materials, while what an object LOOKED like got a whole
top-level group each. That was backwards.

**Themes are siblings, not subgroups**: Furniture - Species, - Biome,
- Location, - Themed (the twelve purchasable Frögg sets), - Tiered, and forty
`Furniture - Tagged: <tag>` groups.

**Forty single-tag groups is deliberate.** A rule picks a group and unticks
subgroups it does not want — right for "Weapons except whips", useless for "only
the odd things", which would mean unticking thirty. A group per tag makes that
one click, which is what a player filling a crate of lamps or chasing a tenant's
fetch quest actually does. They carry contiguous order numbers and a shared
prefix so they read as a submenu rather than forty scattered rows.

**One subgroup each, and that is load bearing.** `petports_filterAccepts` matches
by walking a group's subgroups; `Unsorted` only survives having none because its
flag short-circuits first. Tagged groups built with no subgroups matched NOTHING,
silently — caught in a dry run against the item scan before launch.

**`fossil` was the one tag that meant two things.** It is a colonyTag on three
display shelves AND an itemTag on 55 pocket fossils, and the matcher does not
care which field a tag came from — so `Furniture - Tagged: fossil` quietly held
both. There is now a `Fossils` group: specimens by size category, uncleaned by
`dirtyfossil`, displays by name. Watch for this if another tag turns up in both
vocabularies.

### Six of seven flavors cost the same by construction, and savory is the exception
`dd.fuel.anchorchoice` -- see also `ref.fuel.anchors`, `dd.fuel.weight`

Using all six augment materials as anchors means six of the seven flavors cost
the same to supply BY CONSTRUCTION rather than by tuning. Nothing has to be
balanced against anything, because vanilla already did it.

**Savory is the exception and it is deliberate.** Its anchor is Raw Steak at
weight 4, not 8, because meat is a trivially common monster drop and an 8 would
make savory far cheaper than every other flavor. It is also the widest class in
the set at 78 of the 252 reagents. Those two partly cancel -- wide but cheap per
unit -- but savory is still the easiest flavor to keep stocked, and a uniform
preference roll will leave a player long on it and short on spicy.

**Bitter's anchor is a weak sensory fit and was taken for a mechanical reason.**
Phase Matter is spectral rather than bitter. It was the unclaimed sixth member
of the balanced set, which is a mechanical argument beating a flavor one.
Mushroom is the better word and IS available -- `shroom`, in
`cookingIngredient`, 22 references and live -- and it sits in the class as a
weight-1 member. Swapping the anchor is cheap until something reads the config.

### Fed means productive
`dd.fuel.fedproductive`

Fuel gates the *acquisition* of work, not the *execution* of it. A unit that
runs dry finishes what it is doing and then stops taking on new tasks; it never
abandons a job halfway or freezes mid-action.

This implies a task queue layered above vanilla's action-state machine, which is
a scoring-and-pick model with no notion of committed work. The queue is a new
component, not a configuration of the existing one.

The framing matters as much as the mechanic. A unit that stops the instant
hunger crosses a threshold is a maintenance chore; a unit that works a solid
shift after a good meal is something the player plans around. Same rule,
opposite feel.

### Fuel and flavor -- SUPERSEDES "fuel, not food"
`dd.fuel.flavor` -- see also `dd.fuel.weight`, `ref.fuel.anchors`, `dd.fuel.anchorchoice`

The design here replaced an earlier one wholesale in Aug 2026, and the earlier
one is gone rather than marked stale because keeping it would leave two
incompatible answers to the same question in one document.

**WHAT WAS THERE BEFORE, so a fragment of it turning up elsewhere is
recognisable as dead:** each monstertype accepted a CATEGORY of fuel -- a
robotic drone eating batteries, copper wire and RAM sticks -- and each unit
rolled a preference for one particular ITEM inside that category. It required
replacing `groundPet.lua`'s `itemFoodLiking`, which rejects anything whose
`root.itemType` is not `"consumable"` before preference is ever consulted.

**A PET TREAT IS THE ONLY FUEL.** Units do not eat crafting materials, produce
or vanilla food. Everything goes through the upcycler, which is what makes the
machine load bearing rather than a convenience, and it collapses the whole
fuel-acquisition problem into one item name that every unit accepts.

**PREFERENCE MOVED UP A LEVEL, FROM INGREDIENT TO FLAVOR.** A unit rolls one
preferred FLAVOR and refills more of its fuel bar eating that one. There are
seven, they are separate item names, and a reagent in the upcycler's reagent
slot is what produces them.

**A WRONG FLAVOR IS EXACTLY AS GOOD AS NO FLAVOR, NEVER WORSE.** A unit that
prefers bitter and eats sour gets what it would have got from an unflavored
treat. That is the rule that keeps the whole system opt-in: a player who ignores
reagents entirely loses a bonus and is never punished, and one who flavors the
wrong thing has wasted a reagent rather than ruined a batch. Every other design
for preference implies a way to feed a unit something bad for it, and there is
no version of that a player enjoys discovering.

**FLAVORING COSTS ENTROPY, AND THAT IS THE POINT.** The upcycler exists to
collapse a hundred junk item types into one -- see the entropy framing, which is
about ITEM TYPES per container rather than item counts. Flavors spend some of
that back: seven types where there was one. So a player stockpiles only the
flavors their fleet's rolled preferences justify and leaves the rest as fodder,
and that self-balances with no rule enforcing it. Seven is the ceiling of the
cost and it is one restock crate wide.

### Hunger drains only while working
`dd.fuel.hungerwhileworking` -- see also `dd.fuel.fedproductive`

**THIS SETTLES THE CLOCK-VERSUS-METER QUESTION.** Vanilla's `petResourceDeltas`
drains hunger at 0.5/sec regardless of activity, which contradicts "upkeep is
proportional to the work the fleet does" -- the load-bearing claim in what this
mod is for.

The answer is to zero the vanilla delta and drive the decrement from
`petportsTaskAction`. Everything downstream keeps reading the real resource, so
`hungerStarvingLevel` and `scoreAction` need no changes.

**CONSEQUENCE, ACCEPTED DELIBERATELY: A PARKED FLEET IS FREE.** A player who
over-builds is not punished for it; the idle units simply cost nothing. That is
more forgiving than the original upkeep framing and it is the right trade.

The rate is per-monstertype config, and an efficiency module multiplies it.

### Pets feed from three sources and there is no feeder object
`dd.fuel.selffeed` -- see also `dd.fuel.hungerwhileworking`, `plan.fuel.storageread`

**THE PET FEEDER OBJECT IS CUT.** It was designed before units could read network
storage, and once they can, a dedicated dispenser is a fourth mechanism that
earns nothing. Its arguments about network identity and adjacency died with it.

Three sources, and no others:

  - **Eligible network containers.** Deposit and restock beacons carry a "pets
    may eat from this container" checkbox, so eligibility is authored where the
    container's purpose already is. The upcycler gets the same checkbox, which
    makes eating straight from its output the shortest possible fuel loop.
  - **Manual feeding through the petport pane.** An itemslot used as a DROP
    ZONE: the treat is consumed on drop if the unit has room, so the slot never
    holds anything and never needs serialising.
  - **Thrown on the ground in front of a starving pet**, below 25% hunger only.
    Inherited from vanilla convention, and the gate is what stops it becoming a
    way to interrupt working units.

### Appetites as an inventory sink -- STILL THE POINT, DIFFERENT MECHANISM
`dd.fuel.sink`

The original claim was that species-differentiated appetites would consume
Starbound's tail of one-recipe-no-consumer crafting materials. The goal survived
the flavor pass; the mechanism did not.

**IT IS THE UPCYCLER THAT EATS THE TAIL, NOT APPETITES.** Anything the player
configures a rule for becomes fuel, so the sink is already as wide as the game
and needs no per-species diet to justify it. Reagent classes are a second,
narrower sink on top: 91 named items that have a use beyond being melted down.

**MEASURED, AND LARGER THAN THE ESSAY ASSUMED.** Of 3,649 items in the game,
291 of the 421 in the food and crafting categories have NO recipe consuming
them, and the biggest single block is cooked food -- 122 of 134 `preparedFood`
entries are terminal, plus all 74 seeds, 25 of 28 drinks and 15 of 16 medicines.
For a mod whose core loop is automated farming, cooked food is the customer,
not crafting materials.

### Weight: the batch length IS the value
`dd.fuel.weight` -- see also `dd.fuel.flavor`, `ref.fuel.anchors`

**WEIGHT IS HOW MANY TREATS ONE REAGENT FLAVORS.** There is no second number,
no efficiency stat, no per-reagent yield. A reagent worth 8 flavors a full run;
one worth 1 flavors a single treat, so using it in bulk means feeding the slot
in bulk.

**IT EXISTS BECAUSE ABUNDANCE AND TASTE ARE DIFFERENT AXES.** Snowflake belongs
in sweet on flavor and accumulates in quantities that dwarf Cryonic Extract;
Bone belongs in savory and arrives by the hundred without anyone trying.
Excluding them for being common loses the flavor; including them at parity
trivialises it. Weight is the third answer, and it arrived from exactly that
observation about Snowflake.

**WEIGHTS ARE AUTHORED, NOT DERIVED, AND PRICE IS WHY.** Price is the axis the
upcycler already values its INPUT on and it fails completely here: Snowflake,
Glow Fibre, Plant Fibre, Toxic Waste, Ember Coral Fragment and every petal are
all price 0, and those are precisely the abundant items the weight exists to
price down. Since the classes are enumerated by name anyway, an integer beside
each entry costs nothing.

The four tiers, in `petports_flavors.config`:

    8   the augment materials, and only those
    4   deliberate acquisition -- a monster part, or something cooked
    2   farmed or gathered on purpose -- most produce
    1   incidental -- picked up while doing something else, uncounted

### Module slot count is authored, with rarity as the fallback
`dd.module.slotsbyrarity` -- see also `arch.module.slots`

Common 1, Uncommon 2, Rare 3, Legendary 4, Essential 5. `petports_moduleSlots` is
read from item parameters first, then item config, and the table is consulted
only when nothing is authored. Clamped to five, which is what the pane declares.

**SUPERSEDES** the earlier numbers (one lower across the board, no Essential) and
the earlier position that rarity must never be derived from. That position was
taken because a modded pet bracketed into the normally-unobtainable Essential
tier would have no way to author around a derivation. The ordering answers it:
the authored field is read FIRST, so authoring IS the way around it, and Essential
is in the table so the underived case lands somewhere sensible instead of at zero.

**ONE SLOT AT THE BOTTOM, NOT ZERO.** A Common pet with no slots renders the
Modules region of the pane empty, which reads as a broken pane rather than as an
unupgraded unit.

Units this mod ships state their count explicitly even where it matches the
derivation, so that retuning a unit's rarity stays a decision about how it drops
rather than a silent grant of another slot.

### Diagnostics are icons with tooltips, not a wrapped label
`dd.pane.diagicons` -- see also `fact.pane.labelgrows`

A fixed row of icons makes the region FIXED-SIZE. A label is bounded by string
length, which is unbounded and grows on every copy edit -- and a wrapped label
grows UPWARD into whatever sits above it.

An icon row is bounded by the number of distinct diagnostic TYPES, which is a
small set we control. Each diagnostic carries two strings: a `short` capped at 26
characters for the one-line label, and a `full` sentence for the tooltip, which
has its own box and cannot push the layout around.

It does not escape translation -- the tooltip is still a string. It escapes
translation PRESSURE ON LAYOUT, which is the part that breaks panes.

Tooltips come from `createTooltip(screenPosition)`, a pane-level global the
engine calls on hover. It is not a widget callback and must not be listed in
`scriptWidgetCallbacks`.

### A diagnostic is a live condition, not a tally
`dd.pane.livenottally` -- see also `arch.pane.petport`

Learned twice in one session, from two different fields, and it is the same
mistake both times: reaching into port internals for a player-facing readout.

**`lastReject` IS THE LOGGER'S REPEAT-SUPPRESSION STATE.** It changes every time
the rejection reason changes, so a port alternating between two reasons flips it
every scan. Putting it on the wire defeated the mirror's change gate AND
displayed developer prose with tile rects in it.

**`unreachableFailures` IS ESCALATION STATE.** It clears only when a task reports
done -- `returnWork` deliberately does not clear it, because a unit that walked
home is no proof it can reach WORK. Correct for STRANDED_LIMIT, wrong as a
readout: a healthy idle unit sat there reporting "2 unreachable" forever, which
a player reads as a fault.

**SO THE COUNT IS UNTOUCHED AND THE DISPLAY IS GATED ON RECENCY.** Each increment
stamps a timestamp; the diagnostic shows for 30 seconds. The status line
carries only what is true now.

**SUPERSEDED IN PART, 2026-08-29: the lifetime tally is NOT a Stats-tab
number.** Ruled out when the tab was built -- unreachable counts are re-homing
machinery, not a readout for the player. The escalation state stays exactly as
above; nothing player-facing counts unreachables anywhere.

### The portrait's facing is normalised against the body
`dd.pane.portraitfacing` -- see also `fact.pane.portrait`

Obeying the matrix directly means the pane mirrors whenever the engine does, so a
unit walking left turns around in its own portrait. Ignoring the matrix entirely
gives a stable facing but cannot tell a body apart from an indicator the engine
mirrored on its own.

**SO THE FIRST DRAWABLE SETS THE REFERENCE AND EVERYTHING ELSE IS MEASURED
AGAINST IT.** The unit always faces the way its art is authored, and an indicator
whose transformation group picked up a mirror the body did not gets un-mirrored.

This also means the pane needs no answer to "does `a` track facing". Either way
the reference moves with the body and the relative result is identical.

The reference is the first drawable AFTER indicator filtering, which assumes body
layers come first. True in every sample so far; worth making explicit if
indicators ever move under their own asset root.

### Rates are shown, totals are stored
`dd.pane.ratesnottotals`

"4,120 items" is not a fleet decision. "4,120 items over 3.2 hours active" is.

Active time is the honest denominator because a unit only exists while a player
is in the sector, so the eight hours spent on another planet are excluded by
construction rather than by a rule.

The corollary, from the upcycler's blip display: never show a raw number the
player has no scale for. Give it a rank, a threshold, or a fleet comparator, or
do not show it.

**REFINED, 2026-08-29: "active" is TASK time, not spawned time.** The clock
runs only while the unit holds work -- a recall or diagnostic filler counts,
idle-with-no-work does not -- which is the same definition of working that
hunger already uses, so the clock and the stomach agree. The odometer is gated
the same way (`dd.unit.odometer`) so the numerator and the denominator measure
one thing.

### A* HAS NO CONCEPT OF MEDIUM, SO COST IS THE ONLY STEERING AVAILABLE
`dd.pathing.coststeering` -- see also `fact.pathing.edgebymedium`

Destinations and string-pull shortcuts were gated and the PLAN ITSELF was not.
Refusing a shortcut only falls back to aiming at the next waypoint, which is
still on the illegal route. Measured: a flyer routed through water on the way to
an air target, ended up submerged, and then A* returned ZERO edges to every
target for 21 seconds -- its own leash, a crate, a machine. Frozen.

Plan edges are now validated once per plan, ASYMMETRICALLY: a unit already
somewhere illegal is allowed any route, because every route out of water begins
with edges in water and refusing those turns a recoverable mistake into a
permanent one.

But validation only refuses. COST is what makes A* hand back an acceptable plan
instead of one we reject, and a refusal produces no motion at all. Vanilla's
defaults -- `swimCost` 5, `liquidJumpCost` 15 -- were applying to every class.
`liquidJumpCost` is the price of a water BOUNDARY, so an amphibious route that
exits, re-enters and exits again pays it four times: 60 of a 400 F-score budget
before one tile of distance is counted. That was the whole cause of "no path
home across multiple crossings".

`maxFScore` bounds a FAILING search, not a succeeding one, so raising it raises
the cost of proving something unreachable -- time spent motionless. It is
cross-referenced with `healthCheck`'s stall limit for that reason.

### A recovery that produces motion is worse than no recovery
`dd.pathing.motionnothealth` -- see also `fact.pathing.movearcdefects`

**SPLIT OUT BECAUSE IT IS THE MOST REUSABLE LINE IN THE PATHING WORK AND IT WAS
A PARENTHETICAL IN A BUG REPORT.**

The `moveArc` run-up defeated EVERY guard, because all of them read motion as
health -- vanilla's `stuckTimer`, our `airborneEdgeStall`, and the `stuckAnchor`
reset that zeroes both. A unit sprinting off a platform in the wrong direction
looks healthier to every one of them than a unit standing still.

The same conclusion was reached independently from the other direction in
`petportsJumpMover`. Two arrivals at one principle is the argument for stating
it once, on its own, where a third arrival can find it first:

**MOTION IS NOT PROGRESS. A GUARD THAT ASKS "IS IT MOVING" WILL PASS THE WORST
FAILURES THIS MOD PRODUCES.** Ask whether the distance to the target is
decreasing.

### Proliferation is intended
`dd.port.proliferation`

Nothing limits how many petports a player deploys, by design. Full automation
coverage requires several unit types, which is the point: it drives exploration
and questing to acquire unit items that make a permanent base more convenient.

This makes pets a payoff loop for the settlement and encounter work rather than
a self-contained ship feature, and it is the reason the "Low" priority the
roadmap assigns ship pets understates them.

### Units are destructible, and that is a departure
`dd.unit.destructible`

Ship pets are effectively invulnerable furniture. These are not: a unit takes
damage and DIES IN LAVA, and can be lost mid-task. Keeping that.

The rationale is that these units work out in the world, around hazards a player
built or a planet supplied, and a unit that strolls through lava unharmed is not
doing logistics, it is cheating at them. Loss is also what makes deploying one a
decision rather than a formality.

What the config actually says, read out of `petports_drone.monstertype`:

    damageTeamType                        "ghostly"
    touchDamage                           0
    appliesEnvironmentStatusEffects       false
    appliesWeatherStatusEffects           false
    minimumLiquidStatusEffectPercentage   0.1
    healthRegen                           0.0
    maxHealth                             72

LIQUID status effects apply from 10% submersion while environment and weather
effects do not, which explains the observed lava deaths on its own, and
`healthRegen` 0 means nothing a unit survives ever heals off.

**UNVERIFIED: whether a hostile monster can damage a ghostly-team unit.** The
intent recorded here is that units can be targeted, damaged and destroyed by
hostiles mid-task -- but `ghostly` is specifically the team that sits outside
damage resolution, and the lava path is fully explained without it, so nothing
observed so far is evidence either way. Test it deliberately (stand a unit in
front of something hostile and watch) before designing around either answer. If
ghostly does exclude monster damage and it should not, the fix is the team type,
not the status settings.

**Consequences that follow either way, none of them currently handled:**

  - a unit that dies mid-task leaves its claim behind, and the TTL is what
    collects it
  - cargo already handed to the port is SAFE, since it lives on `petData` and
    not on the unit -- only the existing loss window applies, between
    `takeItemDrop` and the report landing
  - the port respawns a fresh unit after `RESPAWN_GRACE` as though nothing
    happened, which is arguably wrong. A destroyed unit staying destroyed, with
    the item knowing it, is the other option and is undecided.

### The item IS the pet
`dd.unit.itemispet`

`petports_unit_test.item` carries a `petData` block — `monsterType`, display
fields, and the `status` / `storage` the station writes back as the pet lives. A
found item ships with just the monster type; the rest accumulates.

This also enforces the ship-pet/wild-monster boundary **structurally**. Wild
monsters and ship pets use entirely different script stacks and are visually
magnitudes apart, and that separation must hold. A wild monster has no
`petports_unit` item, so it can never be socketed — no runtime type check
needed.

### Combat is out of scope
`dd.unit.nocombat`

Healing and other combat-adjacent tasks are dropped. Nicemice NPC medics already
cover player healing for anyone playing the species, and keeping units clear of
combat preserves the line between utility pets and capture-pod monsters.

This is already reflected in the drone's config — `ghostly` damage team, zero
touch damage — and it simplifies the behavior rewrite considerably, since a unit
that never fights never needs targeting.

### Why not the vanilla pipeline
`dd.unit.nopipeline`

`/scripts/companions/petspawner.lua` exists to serve CAPTURE PODS, and nearly all
of its complexity is pod-shaped: pods holding several pets at once (a hemogoblin
splits when it dies), collar merging, associate/disassociate handlers, and a JSON
round-trip that keeps a pod item in sync so a pet can be carried between worlds.

None of that applies to a dedicated item. One item is one pet, there are no
collars, and the definition lives in the item's own parameters. Worth keeping
from that file is only the spine: assembling spawn parameters with
`initialStatus` / `initialStorage` (how a pet keeps learned state across a
respawn), a status heartbeat, and collision-aware spawn placement.

### Specialization falls out of the asset layer
`dd.unit.specialization`

A task set is a monstertype, a monstertype owns its own `categories` string, and
that string binds its own pool of `.monsterpart` chassis variants. So a unit's
job and its appearance are coupled for free — a sorter cannot accidentally wear
a medic's body, because they draw from different pools. Worth preserving
deliberately: visual legibility is what lets a player glance at a deck and know
which unit is which.

The petport itself stays generic. The unit item carries the type; the port just
holds one.

### Weight is shown as BLIPS, never as a stack count
`dd.upcycler.blips`

Rendering the weight as an itemslot's count is an ANTI-FEATURE and was rejected
on sight: a number beside an item reads as "you need this many of it", which is
the exact inverse of what a weight means. It does not merely read ambiguously,
it reads backwards.

**The convention is the reagent slot's own 8-cell charge display, reused.** The
same bar shape beside Scorched Core showing eight filled cells teaches itself,
because the player has already watched that bar drain on the machine. Reference
and live state share one vocabulary instead of merely looking alike, and one
9-frame sheet (0..8) serves both.

Currently a plain number, explicitly as a stopgap, and the file says so.

### The flavors tab exists because 252 reagents are otherwise invisible
`dd.upcycler.flavorstab`

Nothing in game says which item makes which flavor. Chilli making Spicy is
guessable from the name; Bio Sample making Zesty, Metal Coated Wood making
Sharp and Phase Matter making Bitter are not. Without a reference the flavor
system is discoverable only by feeding the machine one item at a time and
watching the output slot.

**TWO TABS, FIXED, AND THE EXTENSIBLE AXIS IS THE LIST INSIDE.** A tab strip has
a hard ceiling -- nine tabs is most of the panel width, so the third mod-added
flavor breaks the layout. A picker list does not care how many rows it has. A
mod adds a row, never a tab.

**"How it works" IS THE DEFAULT TAB**, so a player opening the machine cold
lands on the explanation rather than on a wall of icons.

### A non-treat parked in the upcycler's output stalls it, by design
`dd.upcycler.outputstall`

`containerPutItemsAt` refuses, the machine banks points and sets
`storage.blocked`, and the port's fuel scan gates on `isFuelItem(held.name)`
BEFORE it reads that flag -- so the machine is not "blocked and worth a trip",
it is invisible to the scan entirely.

**THE PORT DELIBERATELY WILL NOT CLEAR IT.** Hauling off an ore stack a player
parked in a machine they thought was idle is impossible to diagnose after the
fact, and that reasoning is written into `MACHINE_SLOT_OUTPUT`.

So the resolution is a pane warning rather than automation: the machine
publishes the output slot's item name and the pane says what is blocking it,
second in severity behind the beacon check. The blocked flag still does its
original job for the case the output holds TREATS that will not stack with the
next one.

### The row icon is the flavor's TREAT, and the anchor cannot be derived
`dd.upcycler.rowicon`

`item` in the config names the treat, and the treat colours were spread across
lightness as well as hue precisely so seven of them stay legible side by side.

An ANCHOR icon -- Scorched Core for Spicy -- would be more informative and is
not available: Savory's anchor is Alien Meat at weight 4 while its heaviest
entries are cooked dishes at 8, so "first in the sorted list" shows a random
casserole. That would need an explicit `anchor` field in the config.

### Sorted weight-descending, and the pane must not re-sort
`dd.upcycler.sortorder`

The question a player brings to that panel is "what is the best thing I have for
this flavor", which weight-descending answers reading top-down. Savory is 78
reagents and will always scroll; the heaviest being first means the scroll is
optional for most people.

The order is built in `petports_flavors.lua`, not in the pane. A pane that asked
for a different order than the object uses would eventually get one, and then
the list would be showing something no other part of the mod agrees with.

**Lofty's instinct is that the order is still not right** and could not yet say
how. Left as-is deliberately rather than changed twice.

### Vents are infrastructure, not a workaround
`dd.vent.infrastructure`

Vents stay regardless of locomotion. The original justification — a ground unit
cannot climb ladders — undersells them. They are how units enter and leave
player-built spaces without disturbing door and hatch systems, on ships and in
colony ductwork alike, and they work as cosmetic infrastructure too (a vent lets
bees in and out of a player-built hive). Fast travel is a side benefit, not the
reason they exist.

### Vent preference
`dd.vent.preference`

Units should use vents to reach sealed areas, and prefer them when vent travel
shortens the route.

Two distinct cases, and only one is about preference:

- **No route exists** — the destination is sealed off. Vents are not an
  optimisation here, they are the only way in. This needs a fallback path when
  pathfinding fails, not a cost comparison.
- **A route exists but is long** — compare and prefer. True path costs are
  expensive to compute; comparing straight-line distance direct against
  (distance to vent + distance from partner vent to target) with a threshold is
  almost certainly good enough and is cheap.

### Vents: wires as links, not signals
`dd.vent.wireslinks`

Every other wired object uses wires as a SIGNAL (`setOutputNodeLevel` /
`getInputNodeLevel`). `petports_petvent.lua` uses them as a LINK — what matters
is which object is on the far end, via `getOutputNodeIds` / `getInputNodeIds`.

That buys a nice property: **one wire links a pair both ways.** Wire A's output
to B's input and A finds B through its output while B finds A through its input.
The player never thinks about direction and pulling the wire disconnects both
ends.

Teleporting between vents sidesteps pathfinding entirely, which is the point — a
small ground pet has no good way to climb ladders or cross decks.

`getOutputNodeIds` / `getInputNodeIds` return a MAP OF ENTITY ID AS A STRING KEY
to node index — `{"18":0}` means entity 18, on node 0. Verified in game
2025-08-20 by logging the raw returns from both vents of a linked pair. Neither
of the two shapes `collectIds` originally tolerated was correct, and the
mismatch failed silently in both directions: `value` is `0`, which IS a number,
so the list branch collected entity id `0`; the map branch would have supplied
the key `"18"`, a string, which then failed the `type(id) == "number"` gate.
Empty partner list, no error, no linked animation.

**Discriminate on the KEY type, not the value type.** A map has string keys and
a plain list has numeric ones, which is unambiguous; the values are
indistinguishable between the two shapes.

The same log confirmed the bidirectional property holds: from one wire, 17 found
18 through its INPUT node while 18 found 17 through its OUTPUT node.

Consequence worth knowing: those nodes cannot also carry an on/off level. A vent
a switch can close would need a second input node declared for it.

### Four participation groups, and two generators belong to none
`dd.port.participationgroups` -- see also `arch.port.switches`

Fourteen work generators, four checkboxes. Nobody thinks in generators, and nine
or fourteen boxes do not fit the band. Grouped by what a player SEES happening:

    hauling    collection                      labelled "Item Pickup"
    sorting    restockFetch, restockDeliver, tidy, compact
    farming    replant, water, harvest, animal, withdraw, withdrawWater
    machines   drain, fuel

**THE LINE BETWEEN THE FIRST TWO IS INGRESS.** `hauling` is how a thing ENTERS the
network; `sorting` is everything done to a thing already inside it.

**depositWork IS IN NO GROUP, AND GATING IT BUILDS A DEADLOCK.** `findWork`
returns outright when a unit holds cargo with no dispatchable deposit target --
that guard is what stops a unit hoarding -- so a switched-off deposit strands a
unit that fetched a seed, planted it and kept the remainder, blocked from every
other job including ones whose boxes are still ticked. A unit must always be able
to put down what it is carrying. `returnWork` is exempt for the same class of
reason: it is the leash.

**THE STORED KEY IS `hauling` WHILE THE LABEL READS "Item Pickup".** Ids are
frozen because a stored setting names them; labels are free. Same split the filter
manifest uses, where a subgroup with id `unit` reads "Pets". Renaming the key
would silently opt every configured port back into a group it had switched off,
because an absent key reads as participating.

**A SWITCHED-OFF GROUP IS A REASON IN THE REJECT MESSAGE.** The composite is
assembled from the `no*` reasons, every one of which is nil for a generator that
never ran -- so without this, an opted-out port logs identically to a port that
cannot see the farm. "Why is my pet standing still" is the question this mod's
logging exists to answer, and an unticked box is the easiest answer to forget.

The gates guard the CALL, not the result: several generators scan containers or
the world, and paying for that to discard the answer is a cost that only shows on
a large base. A task already in flight is left to finish.

### A pane write that is in flight must not be repainted from the mirror
`dd.module.writetoken` -- see also `arch.module.slots`, `arch.pane.petport`

**THE BUG THIS EXISTS FOR ATE A MODULE.** The pane's module table is both the
display state AND the source of the wire payload. Repainting it from the mirror
means an unrelated change -- a unit picking up cargo, which moves the same
mirrored blob -- can restore the PRE-SWAP module set while the module is already
out of the cursor. The next click then sends a payload that does not mention it,
the port replaces the whole set with that, and `previous` reads nil so nothing is
handed back to the player either. It exists nowhere.

So the pane stamps every module write, the port records the stamp BEFORE it
validates anything, and the pane treats the mirror's module set as authoritative
only once its own stamp returns.

**STAMPING BEFORE VALIDATION IS WHAT MAKES IT SAFE.** A refusal echoes too, so the
pane stops waiting and repaints from truth instead of sitting forever showing a
phantom. The handler also clears the mirror signature unconditionally, because an
unchanged blob would otherwise be swallowed by the mirror's own change gate and
the echo would never be sent.

A token rather than a timeout: a deadline has to guess how long a commit takes
and is wrong on a loaded server. Only modules are held back -- everything else in
a mid-flight mirror is painted normally, because nothing else is in flight.

### The odometer is wrap-aware, task-gated, and refuses teleports
`dd.unit.odometer` -- see also `dd.pane.ratesnottotals`

`world.magnitude` per tick between successive positions -- raw subtraction
would bank the planet's circumference at the world seam. A step past ten tiles
in one tick is a DISCONTINUITY, not travel: vent hops, recalls and respawns
move by setPosition, and an odometer that credits a teleport measures the
network's shortcuts rather than the unit's legwork -- the step is discarded
and the baseline re-seeded. The ADD is gated on holding a task, same as the
clock; the SAMPLING is not, so the baseline follows the unit through idle and
the first working step is a step, not the whole idle stroll.

On the wire it is floored to tens while working and exact at rest. THERE IS NO
LEFTOVER TO CARRY OR CLEAR -- the raw total always held every tile; only the
mirror rounds, and only for churn.

### Machines do not score, and are never compacted
`dd.upcycler.slotsaremeanings` -- see also `dd.dispatch.tidyscore`

A machine's slots are MEANINGS, not shelf space. Stated on the put side since
`depositCargoToMachine` existed; this session enforced the take side too,
because the FUEL task routes its pickup through `withdrawMisfit`, whose
crate-compaction landed on the MACHINE. Measured consequence: every treat
harvest read burner-milk plus reagent-milk as one item split across two slots,
consumed it all, and `containerAddItems` refilled lowest-slot-first -- the
whole reagent stack migrated into the burner on every pickup. `withdrawMisfit`
now compacts only when `machineAt` says the container is not a machine, and
the Tidy Score has excluded machines since it existed.

### One gate for a headpat
`dd.unit.headpatgate` -- see also `arch.unit.headpat`

The send sits INSIDE vanilla's `interactCooldown` branch, so a pat that emotes
is exactly a pat that counts -- the emote and the ledger cannot disagree, and
mashing E collapses to one of each per window. A second, port-side counting
cooldown was built and removed: two clocks that can drift against each other
is one clock too many for a stat whose whole job is matching what the player
saw.

## DESIGN INTENT -- PLANNED

### The drone is always running
`plan.art.animstates`

The run animation is real and bespoke -- eight frames, lit and fullbright layers
-- and it is the ONLY animation the unit has. `default.frames` names
`run.1`..`run.8` and nothing else, and `petports_drone.animation` declares
`idle`, `run` and the rest as separate states while pointing every one of them
at `<partImage>:run.<frame>`. So a unit plays a running animation while
standing, sleeping and thinking.

That is an ASSET gap rather than a code one, and a narrow one: the states exist,
the state machine drives them correctly, and every hook is already wired. What
is missing is frames behind the other names. When they arrive, the change is
`default.frames` plus the per-state `image` properties -- no script work.

Blocked on art. Worth noting the spinner is already factored out into
`monsters/lofty_petports/shared/`, precisely so unit types can share that layer
without sharing a body.

### Fade the unit in and out like a capture pod
`plan.art.capturepodfade`

Socketing and unsocketing currently pop. Vanilla's capture pod has a release and
recall effect that players already read as "a creature is arriving or leaving",
and mirroring it costs no new vocabulary.

Pairs with the door choreography -- see `plan.art.doorchoreography` -- since both
want the same completion signal, and neither should be built without the other or
the sequencing fights itself.

### The petport door is decoration and should be choreography
`plan.art.doorchoreography`

The port has `closed`, `opening`, `open` and `closing` states across three
stateTypes -- hull, door and interior -- with a real ten-frame cycle behind the
transitions, and all four currently mean nothing more than "is an item
socketed". They should be part of the SPAWN PIPELINE: socket an item, the door
plays `opening`, and the unit spawns at the now-open mouth when that animation
completes, rather than beside the object a tick after the item lands.

**The missing piece is a completion signal, not the animation.** `opening` and
`closing` are declared `"mode" : "transition"` with a `transition` target, so
the animator advances itself into `open` or `closed` without being told. The
script therefore has to either time the cycle itself or poll the animation state
to know when the mouth is actually open -- and a hardcoded duration goes stale
the moment the frame count or `animationCycle` changes, which is exactly the
kind of number that gets retuned during a polish pass.

The reverse is the recall path and is more delicate, since `petports_despawn` is
death with the funeral suppressed and the door has to outlive the unit going
away. Sequencing there is unresolved, and note the port ALSO respawns a unit on
its own after `RESPAWN_GRACE` -- so any spawn choreography has to be reachable
from that path too, not only from a player socketing an item.

### Networked storage reading
`plan.fuel.storageread`

The capability that makes self-feeding work: a unit needs to find food in crates
across its network, not just in feeders.

**Query on demand, never poll.** Enumerating containers in the rect and reading
their contents cannot ride a tick. Run it only when a hunger task is being
scored. Do not cache — containers do not announce changes, and a stale cache
sends a unit to an empty crate, which is the failure that looks like a pathing
bug.

**Claim the source stack**, or two starving units both walk to the last seed.
Same claim machinery as any other work item.

UNVERIFIED, and the open question: what can actually be read from a container the
player is not interacting with, and at what cost. `world.containerItems` and
friends are the obvious candidates, but the constraints on calling them from an
object script against an arbitrary loaded container need checking before this
design leans on them.

**Only when no compatible food exists anywhere on the network** — no feeder, no
crate — does a unit beep. Deduplicate it: that is a NETWORK-level condition, so
every unit discovers it simultaneously. One alert per network per cooldown, not
one per unit.

**Two dead-feeder cases look identical to a working one**, and the fullness light
cannot express either, since it is honestly reporting fullness: a feeder sitting
outside all coverage, and a feeder pinned to an ID that does not exist in its
containing cluster. Probably a job for the range overlay. Recorded here so it is
not rediscovered as "my pets are ignoring the feeder".

### The item tooltip is stale
`plan.item.tooltip`

Hovering a unit item in the inventory should describe the unit: what it is
carrying, its fuel level, its serial. It currently says nothing of the sort.
Cargo is already on `petData` on the item, so the data is sitting there and the
tooltip simply does not read it.

Late-project work. It is polish, it will read as unfinished right up until it is
done, and it should follow the systems it describes rather than chase them.

### The investment path — a pet is a project, not a purchase
`plan.module.investmentpath` -- see also `arch.module.effects`, `dd.module.slotsbyrarity`

**THE MECHANISM IS BUILT; THE CONTENT AND THE GATING ARE NOT.** Modules socket,
persist, and grant status effects -- see `arch.module.effects`. What follows is
still planned: task gating, the upgrade ladder, and every module but the
placeholder lamp.

Acquiring a unit should be the start of its development rather than the end.

**1. Most tasks are gated behind installed MODULES.** "Go milk that Mooshi"
requires a Livestock Harvest Module. Dispatch eligibility per task type is
checked against what the unit has installed, so an unequipped unit is not
broken, it is unspecialised -- it still collects and deposits, which is the
floor.

The petport panel displays installed modules, laid out like the MECH ASSEMBLY
GUI. That is a deliberate borrowing: players already know that interface, it
already means "this is a machine you configure", and it makes the module slots
legible without teaching anything new.

Implementation note for whoever builds it: `findWork` already has exactly one
branch per task type, so gating is one check per branch rather than a new
system. And `petData` already persists per-unit state on the ITEM -- surviving
respawn, unsocket and world reload -- so modules have a home that already works.

**2. Slots are earned.** A unit starts with ONE module slot and is upgraded to
add more. Robotic units want RAM Sticks, biological units want Cell Matter, and
each TIER additionally wants a progression item -- the same ladder the EPP
climbs:

    slot 2    Living Root
    slot 3    Venom Sample
    slot 4    Scorched Core
    slot 5    Cryonic Extract

Riding the EPP progression means fleet capability is pinned to planet-tier
progress the player is already making, without inventing a parallel currency.

**Why gate at all**, since the tasks work without it: because a fleet that can
do everything the moment it exists has no shape. Choosing which units get which
modules is the management decision the whole design is trying to create, and it
only exists if a unit cannot have all of them at once.

### Network control — filter beacons
`plan.network.control` -- see also `arch.port.switches`, `dd.port.participationgroups`

What makes a LARGE deployment governable, and everything above assumes large
deployments.

**PER-TASK PARTICIPATION IS BUILT** and has graduated to `arch.port.switches`.
Four groups rather than the per-task checkboxes described here, because fourteen
work generators do not fit a pane band and nobody thinks in generators. Watering
-- named here as the obvious first thing a player switches off -- is inside the
farming group and cannot be switched off on its own. If that turns out to matter,
splitting farming is the change, not per-task boxes.

**FILTER BEACONS, IN TWO FAMILIES, ARE STILL OUTSTANDING.** Filters apply IN
ORDER, using the
container's own slot order as the syntax:

  - **Item filters** -- allow and deny lists over item descriptors, the original
    spec.
  - **Network filters** -- a PARALLEL beacon set governing which networks may
    interact with a container's contents at all.

The second is the one that makes shared bases work. Item filters answer "what
belongs in this crate"; network filters answer "whose crate is this". Those are
different questions and a player will eventually need both.

### The carried-item indicator
`plan.pane.carriedindicator`

A unit carrying something should say so: a small bubble above its head showing
the ITEM ICON of what it holds. The same slot generalises to a TASK icon --
sleeping, wandering, farming, depositing -- which is the cheapest available
answer to "why is that one just standing there".

**It is opt-in per unit, toggled on the petport panel.** A base running a dozen
units with permanent bubbles overhead is visual clutter, and clutter is the
exact vanilla ship-pet failure this mod exists to avoid. Default it off and let
a player turn it on for the unit they are currently wondering about.

This is a second consumer of the petport panel, which does not exist yet.

### Units should sleep in their ports
`plan.unit.sleep`

Vanilla's pet house hides a sleeping pet inside itself, and the mechanism is not
understood -- probably an invisibility flag, possibly a position pin, plausibly
both. Read it before designing anything, because whatever it does is the shape
to copy. `petportsSleepAction` already exists and already gates on
`petports_allowSleep`, so the hook is in place and only the destination is
missing.

---

## DESIGN INTENT -- NICE TO HAVE

## ENGINE FACTS

### The 19px grid is chest slot shadowing, not a pane constraint
`fact.art.chestslotshadow`

**THE ORIGINAL CLAIM WAS WRONG AND IT CONSTRAINED THREE PANES FOR NOTHING.** It
said pane backgrounds tile on a 19px grid in both axes and therefore had to be
extended by whole tiles -- hence 527 wide rather than 530.

What is actually in the art: `panewide_body.png` is 337x224, and its TOP 145
ROWS ARE A SINGLE UNIFORM ROW REPEATED. The bottom 79 carry four bands of chest
slot shadowing on a 19px repeat, because the art was drawn for a container with
rows of item slots. That shadowing is the only thing with a 19px period, and a
pane with no rows of slots does not want it at all.

**SO PANE ART CAN BE ANY SIZE.** `panetall_body.png` is one uniform row tiled to
height, with no shadow band, and the petport pane is 337x335 -- a height that is
not a multiple of 19 and did not need to be. What DOES still hold is that if you
splice the beacon art, you inherit its shadow bands and must respect them; the
answer is not to splice that part.

Header and footer are flat between their three-pixel borders and widen freely.
That half was always right.

### What a farmable declares, and what it does not
`fact.farming.farmabledecl`

From `potatoseed.object`, verified:

    "objectType" : "farmable"
    "category"   : "seed"
    "orientations" : [ {
      "spaces" : [ [0, 0], [0, 1] ],
      "requireTilledAnchors" : true,
      "anchors" : [ "bottom" ]
    } ]
    "maxImmersion" : 0.25

**`objectType : "farmable"` is the discriminator**, and it is already in the
valid-objectType list in the traps section. A crop is not an ordinary object
with crop-shaped parameters; it is its own engine type.

**A CROP IS TWO TILES TALL, ANCHORED AT THE BOTTOM.** `spaces` covers `[0,0]`
and `[0,1]`. Anything reasoning about "the tile a crop is on" has to mean the
ANCHOR tile and has to check the footprint — see the replant occupancy note,
which needs both tiles clear, not one.

**`requireTilledAnchors` is an ORIENTATION property**, not a top-level one, so
read it there.

**`maxImmersion : 0.25`** — submersion tolerance is declared per farmable and is
therefore READABLE, so the aquatic-crop case does not need a hardcoded list of
which crops want water. Potato tops out at a quarter submerged.

**`category : "seed"`** is a clean test for "is this item in storage plantable",
which the replant-from-storage path wants.

**THERE IS NO `scripts` KEY.** The object runs no Lua at all. That has a hard
consequence for the question below: `world.callScriptedEntity` and
`world.sendEntityMessage` both need a script context on the target, and there
is none, so neither is expected to reach a farmable. Testing one costs a line
and is worth doing rather than assuming, but do not build on either.

### Three off-by-ones, all in the geometry
`fact.farming.geometry`

Recorded individually because each presented differently and none was obvious
from the code.

**1. The cast landed one tile right, every time.** Spawn x was `tile + 0.5`, the
tile centre -- correct if the engine FLOORS a reap position to a tile, one tile
off if it ROUNDS. Sweeping right to left, the first cast spilled off the right
edge and the leftmost tile never got one. Fixed at `tile + 0.25`, which is
inside the target tile under either rule. **Anything in `[x, x + 0.5)` is safe.**
The standing position keeps `+ 0.5` deliberately -- nothing converts it to a
tile.

**2. Radius 1 wet two tiles per cast.** MEASURED: six casts, five skips, ten
tiles for five items. Each droplet caught its neighbour, so the unit reached
every second tile to find it already wet. Cheaper, but not PREDICTABLE, and the
point of one-item-per-tile is that a player can look at a row and know what it
cost. Radius 0 wets exactly one.

Worth noting what kept the accounting honest through that: the unit re-reads the
mod at each tile, skips an already-wet one free, and the port charges from the
count actually wetted rather than the tile list it handed out. Charging from the
list would have billed ten for five.

**3. A run would not form from a crop on wet soil.** `waterRunFrom` required the
tile UNDER the crop to be dry and returned nothing otherwise -- so a crop
standing on already-watered soil aborted before the left/right expansion ran,
and freshly tilled ground right beside it was never seen. Break and re-till a
patch next to a watered crop and nothing would ever water it.

The crop makes the row ELIGIBLE; it does not have to be thirsty itself.
Traversal now runs through FARMLAND and collects the DRY tiles out of it, so a
wet tile mid-row is passed over rather than treated as the end of the row --
which is the common case once a fleet has been working, since rows go patchy
rather than splitting cleanly.

**One soil type per run**, as a consequence: `previousMod` is a single value used
for every cast in the sweep, so a run spanning two kinds of dry soil would aim
the wrong transition at half of it. The run takes its soil from the first dry
tile and keeps only matching tiles. This did not matter while the anchor had to
be dry, because runs were implicitly homogeneous.

### Crops come in two kinds, and which is which is statically readable
`fact.farming.resettostage` -- see also `fact.farming.farmabledecl`, `fact.farming.tiledamage`

Harvest crops across a designated area, and produce from farm animals
(Fluffalo, Mooshi). Output triages through an input crate, which is where this
task composes with sorting.

Motivated by a real pain point: large farms are tedious to work by hand.

**SOME CROPS SURVIVE HARVEST AND SOME ARE DESTROYED BY IT, AND WHICH IS WHICH IS
STATICALLY READABLE.** RESOLVED, from vanilla configs. The farmable's `stages`
array ends in a harvest stage carrying a `harvestPool`; whether that stage also
carries **`resetToStage`** is the entire test.

Corn survives — note the harvest stage resets rather than terminating:

    "stages" : [
      { "duration" : [430, 470] },
      { "duration" : [430, 470] },
      { "alts" : 5, "duration" : [1740, 1860] },
      { "alts" : 5, "harvestPool" : "cornHarvest", "resetToStage" : 2 }
    ]

Potato does not — the harvest stage is terminal:

    "stages" : [
      { "duration" : [1170, 1230] },
      { "duration" : [1170, 1230] },
      { "alts" : 5, "harvestPool" : "potatoHarvest" }
    ]

Carrots behave like the potato; tomatoes reset like the corn. **The two kinds do
not sort by anything visible** — root vegetable versus vine is not the rule, and
neither is anything else guessable from looking at a field, so there is no
shortcut worth taking here.

There is nothing to assume and no experiment to run: look for `resetToStage` on
the stage carrying a `harvestPool`, and the unit knows BEFORE it harvests
whether the tile will be empty afterwards.

**CONFIRMED IN GAME: `world.farmableStage` COUNTS FROM 0.** A three-stage crop
was watched through `stage 0 of 3`, `stage 1 of 3`, `stage 2 of 3`, and
harvested successfully at 2 — so the harvest stage is Lua index `#stages`
reported as `#stages - 1`. `FARMABLE_STAGE_BASE` in the petport is 0 and is
correct. Corn's `"resetToStage" : 2` reads consistently with this: its harvest
stage is the fourth entry, resetting to the third.

**Perpetual crops need no planting at all**, which is the good case: the plant
occupies its tile forever, a unit harvests and waters and never selects a seed,
and the player's choice of crop persists because nothing ever removed it.

**Destroyed crops need replanting, and it must not become a planting POLICY.**
Automated planting is only dangerous when something has to decide WHICH crop
fills an empty tile — every answer to that is a sorting policy the player never
wrote and cannot inspect. Replanting what was just harvested asks no such
question. The answer is inherited from the tile, so the player's intent survives
without the mod ever forming one of its own.

### Swamp water, and why the patch needed no code
`fact.farming.swampwater`

`tiles/mods/tilleddry.matmod.patch` adds liquid 12 to `liquidInteractions`.
Vanilla lets water (1) and healing water (6) wet tilled dirt and stops there;
swamp water is water with a status effect attached and the omission reads as an
oversight.

**Nothing in this mod knows swamp water exists.** `soilInfo` reads
`liquidInteractions` at runtime and resolves each liquid to its `itemDrop`, so
the patch is pure data and is picked up with no code aware of it. That was the
entire argument for reading the matmod instead of hardcoding
`tilleddry -> tilled`, and this is the first thing to prove it.

Guarded on `/liquidInteractions/2` being absent, so a future vanilla patch
adding swamp water itself makes this a no-op rather than a duplicate.

**IF THE PATCH PATH IS WRONG IT SILENTLY DOES NOTHING** -- that is the one part
of it that cannot be verified by reading.

### Harvesting is TILE DAMAGE, not an interaction
`fact.farming.tiledamage`

Recorded plainly because an earlier rewrite of this section LOST the question.
The original draft flagged that "player harvesting goes through interaction
paths that may not be callable from a monster script"; when planting turned out
to be `world.placeObject`, that line was replaced wholesale and the harvesting
half went with it. Planting being solved said nothing about harvesting.

**READING the stage: `world.farmableStage(entityId)`** returns the current
growth stage, or nil when the entity is not a farmable. It does DOUBLE DUTY —
the nil case is also the type test, so discovery does not need a separate
objectType check. One call filters an entityQuery down to crops and tells you
which are ripe.

**TRIGGERING the harvest: `world.damageTiles`.** Source is the Harvester Beam
mod's `HarvesterBeam.lua`, which harvests farmables with

    world.damageTiles({ pos }, "foreground", sourcePos, "plantish", 0.2, 1)

    positions       List<Vec2I> -- INTEGER tile coords, so floor explicitly
                    rather than passing world.entityPosition through
    layerName       "foreground"
    sourcePosition  only sets the direction damage PARTICLES fly; pass the
                    unit's own position and they fly away from it
    damageType      "plantish"
    damageAmount    0.2 -- deliberately tiny, enough to trigger the harvest
                    without breaking the block the crop is rooted in
    harvestLevel    1 -- REQUIRED, this is what makes destroyed things drop

Farmables are objects rather than tiles, so what is happening is that tile
damage propagates to whatever is rooted in the damaged tile, and a farmable
answers "plantish" damage by harvesting itself. That is the same path the
interact action uses; the interaction was never the mechanism, it was one
caller of it.

**CONFIRMED FROM ENGINE SOURCE. `FarmableObject` overrides `damageTiles`, and
the override IS the harvest hook:**

    bool FarmableObject::damageTiles(List<Vec2I> const& position,
        Vec2F const& sourcePosition, TileDamage const& tileDamage) {
      if ((tileDamage.type != TileDamageType::Beamish
           && tileDamage.type != TileDamageType::Blockish
           && tileDamage.type != TileDamageType::Plantish) || !harvest())
        return Object::damageTiles(position, sourcePosition, tileDamage);
      return false;
    }

**READ THE SHORT-CIRCUIT CAREFULLY, because this reads at a glance as the
opposite of what it does.** When the damage type IS one of Beamish, Blockish or
Plantish, the first clause is false, so evaluation proceeds to `!harvest()` —
**which CALLS `harvest()`.** That is the side effect, sitting in a condition. A
successful harvest then returns `false` and never touches `Object::damageTiles`.

So: `plantish` damage does not bypass farmables, it is the DESIGNATED WAY IN.
Three damage types work, not one.

**TRAP: A SUCCESSFUL HARVEST RETURNS FALSE.** `world.damageTiles` documents its
return as true when damage was done — and a harvest is precisely the case where
no tile damage was done, because the object consumed it instead. So the return
value is INVERTED from success here, and a caller writing
`if world.damageTiles(...) then harvested = true end` gets it exactly backwards
every time. **Do not use the return value to detect a harvest.** Re-read
`world.farmableStage` afterwards, or check whether the object still exists.

**TRAP: DAMAGING AN UNRIPE CROP FALLS THROUGH TO ORDINARY OBJECT DAMAGE.**
`harvest()` returns false when there is nothing to harvest, and the `||` then
sends the call to `Object::damageTiles` — real damage, to a crop the player is
waiting on. Only ever fire this at entities `world.farmableStage` has confirmed
are at the harvest stage. The tiny 0.2 amount HarvesterBeam uses limits the
blast radius of getting this wrong, which is probably not an accident.

`resetToStage` is handled inside `harvest()`, engine-side, so the reset-versus-
destroy split costs the caller nothing. That also explains HarvesterBeam's
asymmetry — it re-places only crops whose final stage lacks `resetToStage`,
because those are the only ones the engine leaves a hole for.

**TRAP: THE CROP IS NOT REMOVED WITHIN THE TICK THAT HARVESTED IT.** Measured
to the millisecond: the swing landed at 19:01:52.088 and the same-tick check
read the crop as still present with an unchanged stage; 81ms later the entity
was gone and its two drops were on the ground. **A same-tick check therefore
reports every successful harvest as a failure**, which is not a cosmetic
problem — it feeds the failure backoff ladder, so a crop that regrows would
climb to a ten-minute backoff for succeeding every time.

Swing, set a flag, and verify on LATER ticks. Two outcomes to watch for and they
arrive by different routes: a destroyed crop shows up as the target resolving to
nil, and a reset crop shows up as a stage that moved. Only a swing that produces
neither, within a short budget, is a real failure.

**TRAP: `world.damageTiles`'s RETURN VALUE IS UNRELIABLE IN BOTH DIRECTIONS.**
Reading the engine source suggested it should return FALSE on a successful
harvest, since `FarmableObject::damageTiles` consumes the damage and never
reaches `Object::damageTiles`. Measured, it returned **true** on a harvest that
unambiguously worked. Whatever the world-level call aggregates, it is not the
answer to "did this harvest". Log it; never branch on it.

**Drops are not available on the same tick.** HarvesterBeam waits 0.25s after
the damage before going looking for what fell. Whatever the unit does after
harvesting has to allow for that, and note the existing drop `SETTLE_GRACE`
already encodes the same fact for falling items.

**OPEN, AND IT MATTERS FOR SHIPS: can a MONSTER call `world.damageTiles`, and
does tile protection refuse it?** HarvesterBeam is an activeitem held by a
player, which is the permissive case. A monster in a protected zone is not, and
the existing note about coverage overlays failing inside tile-protected zones is
the same family of problem. Planetside farms are the v1 case and are almost
certainly fine; a farm on a Nicemice ship may not be. Test before promising it.

**The old fallback is retired but worth remembering.** Synthesising the harvest
— read `harvestPool`, generate the drops, reset or clear the object yourself —
is no longer needed. Keep it in mind only if tile protection turns out to block
the real path in the places this needs to work.

### What the tiles actually say
`fact.farming.tilequeries`

Verified from vanilla material configs. Tilling is a SURFACE MOD, applied by the
hoe activeitem to any material whose config says it can take one. Vanilla dirt
declares two separate things:

    "tillableMod" : 32      -- the matmod a hoe applies
    "soil" : true           -- an entirely different capability

**Those are not the same flag and they are easy to conflate.** `soil` governs
whether a SAPLING can be planted — trees. `tillableMod` governs whether a HOE
can till — crops. Tree farming is not planned, so `soil` is not this system's
business; it is recorded only so the wrong one does not get read. Farmable
placement validation is also NOT the same code path as tree placement
validation, so do not test one against the other.

The value is a matmod id: **32 is dry tilled dirt, 31 is wet tilled dirt.**
Watering is the transition between them, and a wet tile DECAYS back toward dry.
So "does this tile need water" is a question about which matmod is currently on
it, not about a timer the mod has to keep.

**DOMESTICATED farmables set `requireTilledAnchors : true`; wild variants do
not** — which is precisely how wild crops spawn on untilled planet surfaces
without a hoe ever touching them. Player-accessible seeds are the domesticated
ones, so anything a unit services is on tilled ground by definition.

**THE SEED IS THE FARMABLE.** Not "seeds behave like objects" — the seed item
and the planted crop are the SAME NAME. `potatoseed` is what sits in the
player's inventory, what `world.placeObject` places, and what the growing plant
is called on the tile. Planting is therefore script-callable with no item lookup
in front of it, and — see replant intents — identifying what to put back in a
tile is just reading the object's name before it is harvested.

This dissolves what looked like the hardest open problem in this section. An
earlier draft budgeted for a reverse index from crop to seed, built by walking
item configs at load. There is no mapping to build; there was never a second
name.

**Watering does not have to mean water.** Matmods carry `liquidInteractions` in
their configs, so the liquid ids a given tilled mod responds to are READABLE AT
RUNTIME. A unit can ask the tile what it wants and then check network storage
for an item that produces it, instead of carrying a hardcoded water assumption.
The query is the same query either way, so this costs nothing now and is most of
what modded-soil support would need later.

**How to read a material's config at runtime**, from HarvesterBeam:

    root.assetJson(root.materialPath(world.material(pos, "foreground")))

That is the route to `tillableMod`, to `soil`, and by the same shape to a
matmod's `liquidInteractions`.

**Mods are named, not numbered, at the script layer.** HarvesterBeam tills with
`world.placeMod(pos, "foreground", "tilled", nil, true)` and tests removability
against a name table containing `"tilleddry"`, comparing `world.mod(pos,
"foreground")` against it. So the 31/32 ids in the material config surface
script-side as `"tilled"` and `"tilleddry"`, and **"has this tile dried out" is
a name comparison** rather than an id lookup. INFERRED from that table matching
at all; confirm the exact return type of `world.mod` before relying on it.

**Note HarvesterBeam gates tilling on `soil`, and that is arguably a bug worth
not copying.** It checks `root.assetJson(...).soil` before placing the tilled
mod — but `soil` is the SAPLING flag and `tillableMod` is the hoe flag, per the
material config above. Vanilla dirt declares both, so the mistake is invisible
on vanilla and would bite on any modded material that declares one without the
other. Read `tillableMod`.

**Watering has a cheap lead: a projectile.** HarvesterBeam waters a crop with

    world.spawnProjectile("watersprinkledroplet",
      vec2.add(world.entityPosition(j), {0, 1}),
      owner, {0, -1}, false, { timeToLive = 0.2 })

which is dramatically less work than instantiating a fluid volume by hand, and
it also supplies the visual for free. Whether it satisfies the matmod's
`liquidInteractions` or merely looks like it does is UNVERIFIED — but if it
does, the whole consume-item-produce-liquid step collapses to spawning a
projectile and decrementing a stack.

The watering step is still what earns the design: carry a CONSUMABLE to a
destination and spend it there, instantiating a fluid at a tile. That verb
recurs — restocking a feeder is the same shape — so building it here delivers a
primitive the rest of the system wants.

### The soil describes itself, so `farming.config` is barely needed
`fact.farming.soilconfig`

The plan was to read `farming.config`'s `wetToDryMods` to decide wet from dry.
That turned out to be unnecessary. The matmod carries everything:

    tilleddry   "tilled" : true                     -> it is farmland
                liquidInteractions[] .liquidId      -> what wets it
                                     .transformModId-> what it becomes
    tilled      "tilled" : true, no liquidInteractions -> farmland, already wet

So "is this dry farmland" is `tilled == true` and at least one
`liquidInteraction` with a `transformModId`. No name comparisons, no hardcoded
pairs, and **modded soils work for free** -- which is most of what
Alta/Enternia compatibility was expected to cost.

`root.modConfig(name)` reads it. Note the API goes ONE WAY ONLY: there is no
`root.modName`, so a numeric `transformModId` cannot be turned back into a name
directly.

**`itemDrop` closes the loop from the other end.** The matmod names liquids by
numeric id; a liquid ITEM names its liquid by string. Matching items against the
mod would need a bridge -- but `root.liquidConfig(id).config.itemDrop` names the
item that yields that liquid, so the chain runs mod -> liquid -> item and
nothing is ever matched by name.

    tilleddry -> liquidId 1  -> liquidwater
              -> liquidId 6  -> liquidhealing

Both resolve and both were verified working in game.

**The one thing `wetToDryMods` IS for: turning `transformModId` into a name.**
`applySurfaceMod` wants `newMod` as a NAME and the matmod gives an id. Inverting
`wetToDryMods` maps the dry name to its wet one, and the result is then VERIFIED
by reading `root.modConfig(candidate).config.modId` and confirming it equals the
`transformModId` the soil asked for. A modded soil whose author patched
`wetToDryMods` correctly passes; one that did not is refused rather than watered
with a droplet naming a mod that does not exist.

That verification matters because the failure it prevents is indistinguishable
in a log from the OTHER silent failure in this path -- a droplet that lands and
does nothing.

### `world.containerAddItems` SILENTLY DESTROYS ANYTHING PAST ONE STACK
`fact.item.addoverflow`

The worst bug found so far, and it was in code that had been shipping for
months. Handed `{ dirtmaterial, count = 8497 }` into a crate with ten free
slots, it filled ONE slot to `maxStack` and **returned no leftover**. From Lua
the call looked like a complete success. 7,497 items ceased to exist.

The guard for exactly this case was already there and never fired, because the
engine reported nothing to guard against.

Two routes reached it. Compaction handed the engine a whole bucket at once — one
descriptor per parameter set, routinely several stacks' worth. And
`receiveCargo` merges cargo stacks with NO maxStack cap by design, so three
1,000-block pickups become one stack of 3,000 and `depositCargo` handed that
over — the ordinary collect-and-file path.

**Never call it directly.** Everything goes through `placeStack`, which loops at
`maxStack` per call and returns what genuinely could not be placed. The one
remaining raw call is the put-back in `takeFromSlot`, where the descriptor came
out of one slot moments earlier and is stack-sized by construction.

The tell was in the log and was misread as something else:

```
compacted 8497 dirtmaterial in 5: 10 slot(s), predicted 9
dirtmaterial in 5 settled at 1 slot(s), not the 9 predicted
```

That second line is the prediction check, written to catch a `stackSizeOf` that
was too LOW. It correctly reported an impossible packing, and its own comment
invited reading it as a bad prediction. Compaction now counts what went in
against what came out and logs an error if they disagree.

### `world.itemDropItem(entityId)` exists and returns the full descriptor
`fact.item.dropdescriptor`

Count and parameters included. This is what makes per-item decisions about a
drop possible BEFORE picking it up — the blocked/unclaimed marker split, and the
cargo top-up merge test both depend on it.

There is no way to read a drop's current AGE. Lifetime can be read and set; time
elapsed cannot. Do not shadow it with a port-side first-seen table — distance is
a good proxy for rescuable anyway, since a far drop is both likelier to expire
and more expensive to reach.

### `world.containerItemAt(id, offset)` FOR ONE SLOT, ALWAYS
`fact.item.itemat`

Never `world.containerItems(id)[offset + 1]`. Observed: with dirt in the input
and a block in the output, pulling the dirt out made the OUTPUT appear to empty
in the pane.

CAUSE NOT ESTABLISHED. That is what indexing a compacted list would do, but
`petports_filterMisfits` treats the same table's keys as slot indices and has
worked for a long time, including comparing them against a beacon's own slot.
Both cannot be true.

What IS certain is that `containerItemAt` takes an offset and answers about that
slot whatever else the container holds, so it cannot be wrong under either
reading. Every slot lookup in the upcycler uses it.

### Two projectiles spawned in the same tick can kill each other
`fact.item.projectiletick`

If projectiles cull duplicates by querying neighbours, the cull runs on the
first UPDATE, not at spawn — so two created in the same tick both scan after
both exist, each finds the other, and each kills it. Nothing is left.

Spawn order is NOT a tie-break for this reason. Compare entity ids so the
relation is antisymmetric, and make the comparison fail toward SURVIVAL: a
duplicate is visible and gets cleaned up by the next spawn, where a mutual kill
leaves nothing to notice the problem.

Also: a radius query returns every projectile nearby, including other mods'.
Only cull entities that ANSWER a "what are you marking" message with a matching
id. Silence must mean leave it alone.

### A projectile's `renderLayer` is a map lookup, and an unknown key is FATAL
`fact.item.renderlayer`

Not ignored, not defaulted:

```
Could not read projectile '...', error: (MapException) Key 'Foreground' not
found in Map::get()
```

The whole asset fails to load and every spawn of it fails, so the symptom is
"the feature does nothing" several steps removed from the cause. `Foreground` is
not in the vocabulary; `ForegroundEntity` is. Same shape as the itemgrid
callback crash — a config string that must be in a vocabulary, with no forgiving
path when it is not.

### `timeToLive` becomes the lifecycle by accident if it is short
`fact.item.timetolive`

A 3-second TTL on a marker meant the owner had to rebuild it every 2 seconds
just to outrun expiry — thirty rebuilds a minute for something nobody had
touched, each leaving a predecessor to clean up. The tell was the same object,
same state, same position, respawning on a metronome.

Make the TTL long enough that renewal is rare and treat it as the orphan
backstop it is meant to be.

### THE ONLY itemTag ON FOOD AND CRAFTING MATERIALS IS `reagent`
`fact.item.reagenttag`

Measured across every `.item`, `.consumable`, `.matitem`, `.liqitem` and
`.object` in the food, produce, crafting-material, seed, drink and medicine
categories -- 421 items. Exactly ONE itemTag exists on any of them, `reagent`,
on 115. Nothing else. Not one.

So there is no tag axis to discriminate on anywhere in that half of the game,
and any grouping of materials or produce has to be enumerated BY NAME. The
filter manifest's five matchers are of no help here; only `items` applies.

This is the same shape as the dead `ore`/`ingot`/`bar`/`gem` tags that were
already found and removed, arrived at from the other direction: those were tags
that did not exist, this is a whole vocabulary that does not exist.

### `controlFly` DOES NOTHING FOR A GRAVITY-ENABLED CHASSIS
`fact.locomotion.controlfly`

Vanilla's `moveSwim` steers with

    mcontroller.controlApproachVelocity(
      vec2.mul(vec2.norm(self.delta), mcontroller.baseParameters().walkSpeed),
      mcontroller.baseParameters().liquidJumpProfile.jumpControlForce)

and NOT with `controlFly`. That is not an accident of style. Measured: a ground
unit standing on a lake bottom, 22 Swim edges planned, target one tile straight
up, y velocity pinned at -1.535 for the whole run, edge 1 never advancing. No
upward force was ever applied.

I had taken vanilla's whole `moveSwim` as broken and replaced all of it,
including the one part that was correct. The mover now branches on
`gravityEnabled` for ACTUATION ONLY -- the look-ahead, the consume loop and the
clearance test are shared, because those were right for both.

The before-and-after is what named it: vanilla's `moveSwim` moved the unit
badly, mine did not move it at all.

### A HARMFUL LIQUID IS HARMFUL AT 0.1 FILL, NOT 0.9
`fact.locomotion.harmfulfill`

`minimumLiquidStatusEffectPercentage` is 0.1 on every chassis, so that is when
the engine starts applying a liquid's status effects. Deep enough to SWIM in is
a much higher bar than deep enough to KILL. Hence two thresholds, and hence a
THIRD medium state: `petports_mediumAt` returns `air`, `swim` or `forbidden`,
because reporting denied liquid as "not submerged" would make a flyer treat a
lava lake as open sky, and "submerged" would let a swimmer treat it as home.

Forbidden outranks every capability, and it is tested BEFORE the walker
short-circuit -- it sat after it at first, which meant an amphibious walker
would have waded into lava for exactly the reason an aquatic unit would have
without a deny-list.

### `root.liquidConfig` RESOLVES NAMES, AND LIQUID IDS ARE NOT GUESSABLE
`fact.locomotion.liquidconfig`

`world.liquidAt` returns `{liquidId, level}` and every check in this mod was
reading only `level[2]` and discarding the id. `root.liquidConfig(id)` returns a
config carrying `itemDrop` (the watering code already relies on it), so a
deny-list can be written as NAMES.

That matters: the only liquid id this mod has ever measured is 12 for
swampwater. Any ordering anyone would guess from memory is wrong.

Matched against the liquid's `name` AND its `itemDrop`, because "lava" and
"liquidlava" are different strings and which one the engine exposes is not
something to assume. Whatever each id resolves to is logged once, so a wrong
entry is a one-cycle fix.

### IMAGE DIRECTIVES COMPOUND -- setImage DOES NOT REPLACE A DECLARED ONE
`fact.pane.directives`

A widget's declared `file` can carry a directive, and `widget.setImage` supplies
a path of its own. BOTH APPLY. The declared one is not replaced.

The blips declared `blip.png?multiply=2a2a2aff` to stop them flashing white
between the pane opening and the first state poll. Every tint set from Lua was
then multiplied by that grey, and sweet at `cfe9f2` came out indistinguishable
from an empty cell.

**IT DOES NOT ERROR AND IT IS NOT OBVIOUS.** Six of seven colours still looked
plausible; only the palest one was destroyed enough to notice. Keep the declared
file BARE on anything Lua re-tints.

The flash is solved by declaring the widgets `"visible" : false` and making them
visible in the same branch that first sets a tint -- absent for a frame rather
than briefly wrong. All of a set must be painted in one pass or the row changes
length as it fills.

### An itemgrid needs BOTH callbacks, and the right-click default is unreachable
`fact.pane.gridcallbacks`

An itemgrid's `callback` defaults to its own widget name, and its
`rightClickCallback` defaults to `<callback>.right`. Both are looked up at
CONSTRUCTION and a missing one is a client crash.

The dot is the trap: a declared callback must be reachable as a Lua global, and
`reagentSlot.right` parses as an index into a table. **Any itemgrid a script
supplies callbacks for must name both explicitly.** That is presumably why every
vanilla container grid is called `itemGrid` and none of them are named anything
descriptive.

### An itemslot is not a button, but it is a fine display widget
`fact.pane.itemslotbutton` -- see also `fact.pane.nullcallback`, `fact.pane.rightclick`

**SCOPED, BECAUSE THE ORIGINAL WAS NOT AND IT POINTED THE WRONG WAY.** This was
measured on a slot sitting ON TOP OF A ROW BUTTON that needed the click, and the
conclusion recorded was "stop using a slot". That conclusion is correct for that
case and wrong as a general rule -- the petport pane's cargo readout wants a slot
that ignores clicks, which is the option this entry originally listed as a
failure.

An itemslot has no hover art, no depressed state and no click sound. Over a
button that needs the click, three fixes each solve a third:

    "callback" : "null"        tooltip, no click
    "mouseTransparent" : true  NO tooltip AND no click
    a real member callback     click, but still silent and flat

**`mouseTransparent` ON A SLOT IS THE WORST OF BOTH.** It removes the automatic
item tooltip and does NOT pass the click through -- a slot swallows input rather
than being transparent to it.

**SO: OVER A BUTTON, USE AN `image` INSTEAD.** An image can be mouseTransparent
for real, so every pixel of the row is the button -- hover art, depress, sound
and selection, with no per-widget wiring. The icon path comes from
`root.itemConfig`'s `directory` plus `config.inventoryIcon`, so a modded item
resolves its own icon. The cost is the slot's automatic tooltip, recoverable
with `createTooltip` over the whole row.

**WHERE NOTHING NEEDS THE CLICK, `"callback" : "null"` IS EXACTLY RIGHT.** It is
a display surface with a free item tooltip. `"null"` is special-cased and never
looks for `null.right`, so no rightClickCallback is needed. Verified on the
petport pane's cargo slot.

**AN ITEMSLOT DOES DRAW ITS STACK COUNT.** An earlier note here said it does
not. It HIDES a count of one, exactly as an inventory slot does, so a
single-item cargo and a broken readout look identical -- which is what produced
the wrong conclusion. A count label beside the slot was added on that basis and
then removed again.

**AND THE WIDGET HAS NO NATIVE INVENTORY BEHAVIOUR AT ALL.** mechassemblygui's
`swapItem` does every part of a move in script: read the cursor with
`player.swapSlotItem()`, write it back with `setSwapSlotItem`, set the display
with `setItemSlotItem`, update its own model. The widget contributes a click
event and a tooltip and nothing else. Vanilla's only real-inventory use of it is
the mech assembly station, where every part is NON-STACKABLE -- which is why the
widget looks general and is not.

### A WRAPPED LABEL GROWS UPWARD FROM ITS POSITION
`fact.pane.labelgrows`

The position is the BOTTOM of the text block. A four-line paragraph placed at
y 206 occupied 206..253 and drew straight through the tab buttons at 226 --
visible as the tabs sitting between line two and line three.

**Adding a sentence pushes the TOP up, not the bottom down**, so a block that
fits today collides the moment the copy grows, with nothing to warn about it.
Position multi-line labels from their last line and leave headroom.

### `addListItem` REPAINTS THE WHOLE CONTAINER
`fact.pane.listrepaint`

So a list cannot be built across frames. This rules out an entire technique
rather than one implementation.

Selecting Savory builds 78 cells in one frame and hitches visibly, so a queue
drained a few cells per `update()` looked like the obvious fix -- and it is the
first thing anyone will think of. Measured in game: every batch STROBED the
entire grid, and the flicker was far worse than the hitch it replaced. Backed
out; the file carries a do-not-re-add block.

What is left, if the hitch ever needs solving: fewer widgets per cell, or fewer
cells. Not fewer per frame.

### `"callback" : "null"` ON A ROW BUTTON IS HOVER ART FOR FREE
`fact.pane.nullcallback`

A list has no hover callback, so hover states have to come from a button. A row
button with `"callback" : "null"` constructs, does nothing, and the LIST's own
callback still fires -- because a row button and a list callback both fire on
one click, which is normally the trap and is exactly what is wanted here.

That gives an existing list hover art and sound without touching its working
selection path. Use the button's own callback only when something else in the
row needs one too.

### Portrait drawables carry a 3x3 transformation, and the mirror is in it
`fact.pane.portrait` -- see also `arch.pane.petport`

`world.entityPortrait(entityId, mode)` returns a list of drawables for a portrait
entity. The mode string is `"Full"` -- measured; the enum also lists Head, Bust,
FullNeutral, FullNude, FullNeutralNude.

Measured off a live amphibious unit:

    body  position [0,  0]  [[-1,0,12],[0,1,-8],[0,0,1]]
    spin  position [0, 12]  [[-1,0, 8],[0,1,-8],[0,0,1]]

**`a` = -1. X IS NEGATED -- the horizontal mirror is IN THE MATRIX**, not baked
into the art and not something a reader has to infer from facing.

**`tx` AND `ty` CENTRE the sprite on its own origin**: tx is half the width, ty
is minus half the height. A drawable is centred on its `position`, not anchored
at its corner.

**`position` IS NOT ALWAYS ZERO.** An earlier reading said it was, on the
strength of a bounds measurement that had already EXCLUDED the spinner -- the one
drawable with a non-zero position. Measuring only what you draw and concluding
something about what you skipped.

`root.imageSize` IS reachable from a container pane script, which is what makes
fitting a portrait to a canvas possible rather than hardcoding a scale per
chassis.

### `rightClickCallback` DEFAULTS TO `<callback>.right` ON ITEMSLOTS TOO
`fact.pane.rightclick`

Already recorded for itemgrids and it applies to slots. Naming only the left
callback threw

    Failed to find itemslot rightClickCallback named: 'flavorIconClicked.right'

out of `ListWidget::addItem`, taking the whole tab down. The dot is the trap:
`x.right` parses as an index into a table, so the default is not reachable as a
name even if something were there.

**`"null"` IS SPECIAL-CASED AND NEVER LOOKS FOR `null.right`.** That is why a
display-only slot survives naming one callback, and why this looked like a
registration problem rather than a construction one. The rule is narrower than
"always name both": **a slot naming a REAL callback must name the right-click
one too.**

### Textbox callbacks do not fire per keystroke — poll instead
`fact.pane.textboxpoll`

A `textbox` widget's `callback` does not fire as the player types. Measured: an
entire editing session produced no callback line at all, while the field visibly
accepted a backspace and then appeared stuck.

`restockconfig` already ran the right way and it was not copied at first: poll
`widget.getText` from `update`, and keep a `shownText` of every script-side
write so the pane's own render does not read back as an edit and commit itself
in a loop. The callback still has to EXIST — a textbox whose callback does not
resolve throws at construction — so it is a stub.

Two related rules for panes generally: repainting a list on every keystroke
destroys focus, so edit ONE row rather than rebuilding; and an empty field is
not zero — clearing "500" to type "250" passes through `""`, and committing that
as 0 on a running machine is destructive.

### A container pane binds THREE itemgrids -- itemGrid, itemGrid2, outputItemGrid
`fact.pane.threegrids` -- see also `dead.pane.slotproxies`

**THIS ENTRY SAID TWO FOR MONTHS AND IT WAS WRONG.** It shaped every layout
decision in this mod and cost an entire session to a workaround that was never
needed. `ContainerPane`'s widget reader registers THREE names, each with its own
`.right`, and all three route through the same `swapSlot` path:

    itemGrid          itemGrid.right
    itemGrid2         itemGrid2.right
    outputItemGrid    outputItemGrid.right

So all three are REAL stacking grids with native drag, right-click and
shift-click. `slotOffset` is honoured on all three -- measured with three
single-cell grids at offsets 0, 1 and 2, each holding stacks correctly.

**IT LOOKED LIKE TWO BECAUSE VANILLA BARELY USES THE THIRD.** The campfire is
the only user in the entire asset tree. Grepping for it finds one hit, which
reads like a dead registration until you try it.

- A grid named anything OUTSIDE those three, with callbacks supplied, constructs
  fine and draws ZERO slots -- silently, nothing in the log.
- `itemGrid3`, with no callbacks, throws
  `(WidgetParserException) Failed to find itemgrid callback named: 'itemGrid3'`
  out of ContainerPane's constructor and takes the CLIENT down.

Three grids is not three slots: a grid spans `dimensions` worth of slots from
`slotOffset`, so the constraint is THREE INDEPENDENTLY POSITIONED GROUPS.
Vanilla's cropshipper covers 40 slots with two of them.

### ContainerPane STAMPS THE TITLE AND SUBTITLE, AND THE ONLY LEVER IS THE CATEGORY
`fact.pane.titlestamp` -- see also `fact.pane.windowicon`

A pane's title widget declares a title and a subtitle. ContainerPane overwrites
both from the object's `shortdescription` and `category`. Four measurements, in
order, each ruling out the obvious fix:

    widget named "title", both strings declared   stamped
    widget renamed to "windowtitle"               stamped -- found BY TYPE
    "titleFromEntity" : false at the top level    stamped
    object declares NO `category` at all          NOTHING stamped

The third is the informative one. `titleFromEntity` comes from
`/interface/crafting/fossilstation.config`, which is a CRAFTING pane -- a
different C++ class with a different schema. ContainerPane does not read it.
**A vanilla crafting pane is not evidence about a container pane** and reading
one as though it were cost two test cycles here.

The fourth is the answer, and vanilla proves it: the FTL fuel hatch declares no
category, its pane declares "FTL Drive Fuel Hatch" / "Erchius fuel repository",
and that is exactly what renders -- a title DIFFERING from the object's own
shortdescription, which is what makes it conclusive rather than coincidence.
Seven species variants, none with a category.

**THE TWO FILES ARE COUPLED WITH NOTHING LINKING THEM.** Putting a category back
on the object silently reverts the pane's subtitle to a category label, and
neither file can express that on its own. Both carry a comment saying so.

**COST: THE TOOLTIP SHOWS "Other".** A missing category is not blank, it renders
as Other. 78 vanilla items ship with no category, so this is well-trodden
ground, but it is a visible cost rather than a free win.

**SORTING SURVIVES ONLY BECAUSE THE SUBGROUP MATCHES A TAG.** The Petports >
Machines subgroup reads `petports_machine` from `itemTags`, deliberately not the
category, on the reasoning that a field doing two jobs will eventually be
changed for one of them and silently break the other. It got changed for one of
them. Nothing broke.

### `hasWindowIcon` -- ContainerPane draws its own header icon
`fact.pane.windowicon`

Undocumented anywhere we had looked, and found on the fuel hatch. ContainerPane
draws a header icon from the object's `inventoryIcon` UNLESS the object sets
`hasWindowIcon : false`.

That explains a result that looked like a partial success: an icon appeared in
the upcycler's header the moment the title widget was touched, and it was
ContainerPane's, not the widget's. Both pointed at the same file, so they were
indistinguishable.

**The bespoke-icon pattern is the fuel hatch's:** set `hasWindowIcon : false` on
the object and supply a DIFFERENT image in the title widget's `icon` child.
Confirmed working on the upcycler.

### `approachPoint`'s ARRIVAL BRANCH IS UNREACHABLE FOR A FREE MOVER
`fact.pathing.approacharrival`

    if self.approachPosition and (targetDistance > stopDistance or not mcontroller.onGround()) then
      ...
      return false
    elseif targetDistance <= stopDistance then
      return true
    end

`not onGround()` is permanently true for a gravity-disabled actor, so the first
branch always wins and the `elseif` can never be reached. The unit flies to its
target, sits on it, and reports not-arrived until `APPROACH_TIMEOUT`.

NOTE WHAT IS NOT THE PROBLEM, because it looks like it should be: `PathMover
:move`'s return value. `approachPoint` never uses it as an arrival signal -- it
only compares against `"running"` to pick an animation state. Arrival is decided
by distance to the RAW target and nothing else. I got this wrong first.

### groundPet's `approachPoint` PASSES A DIRECTION INTO `avoidLiquid`
`fact.pathing.approachliquid`

    findGroundPosition(targetPosition, -20, 1, util.toDirection(-toTarget[1]))

The fourth parameter is `avoidLiquid`. `util.toDirection` returns 1 or -1 and
BOTH ARE TRUTHY IN LUA, so vanilla always avoids liquid here, by accident, with
no way to ask for anything else.

MEASURED COST: our `standableNear` passes `avoidLiquid` false and resolved a
submerged upcycler happily; vanilla's `approachPoint` refused the same point one
line later, left `self.approachPosition` nil, and the unit stood still for 10.7
seconds until two progress strikes failed the task. Two resolvers aiming at the
same point under different rules.

There were FIVE resolvers answering this question and THREE different answers --
`false` hardcoded in three places, a truthy direction in vanilla's, and NO
ARGUMENT AT ALL in `petports_findRestPosition`, which read as nil and therefore
false. They all now call `petports_avoidLiquid()`.

### The two vanilla drop faults underneath it, both still fixed
`fact.pathing.dropfaults`


OBSERVED, MECHANISM IDENTIFIED FROM SOURCE, NOT YET FIXED. Symptom: with
platforms stacked one above another to look like a ladder, a unit heading for a
specific platform drops through one, lands on the next, pauses, drops through
THAT one, overshoots, jumps back up, and loops.

`/scripts/pathing.lua`:

    function PathMover:keepDropping(dt)
      if self.downHoldTimer ~= nil then
        mcontroller.controlDown()

        self.downHoldTimer = self.downHoldTimer - dt
        if self.downHoldTimer <= 0 or mcontroller.onGround() then
          self.downHoldTimer = nil
        end
      end
    end

**IT PRESSES DOWN AND THEN CHECKS WHETHER IT HAS LANDED.** On the tick where the
unit arrives on the platform below, `controlDown()` has ALREADY been issued for
that tick -- so the platform it just landed on is passed through as well. The
timer is cleared afterwards, one platform too late.

With platforms spaced far apart this is invisible: the unit is still airborne on
the tick the timer expires. Stack them adjacently, as a player does to fake a
ladder, and one surplus tick of down is exactly one surplus platform. That
matches the observed "drops, hesitates, drops again" -- the hesitation is the
landing, and the second drop is this.

Compounded by the `timedDrop` typo above, which fixes the hold at roughly a tick
and a half: the surplus tick is a large fraction of the whole drop.

**THE NAIVE FIX RE-BREAKS DROPPING.** Simply testing `onGround` before pressing
down cancels on the FIRST tick, because the unit is still standing on the
platform it is trying to fall through when `moveDrop` fires. The hold has to
survive until the unit has actually left the platform.

Shape of a fix that should not have that failure: record the y at drop start and
only let `onGround` cancel the hold once the unit has DESCENDED past it -- or
require at least one genuinely airborne tick first. Both `timedDrop` and
`keepDropping` would be instance overrides on the pather, the same technique as
`moveJump`, so vanilla stays untouched.

**Fix these two together, and test them together.** They are the same drop, and
separating them means measuring a hold time that is still being cancelled a tick
late.

### THE PATHFINDER PICKS EDGE TYPE BY MEDIUM, NOT BY CHASSIS
`fact.pathing.edgebymedium` -- see also `arch.locomotion.classes`

A gravity-DISABLED actor submerged in water is planned `Swim` edges, not `Fly`.
A gravity-ENABLED ground unit dropped into a lake is planned `Swim` edges too,
and then `Jump` arcs to get out. The chassis does not enter into it.

This is the single most useful fact of the session and the otter fell out of it.
It also means A MOVER BOUND TO THE SLOT THAT "SHOULD" APPLY IS NOT ENOUGH:
`petportsFreeMover` was assigned to `moveFly` only, so underwater it was never
called once and vanilla's `moveSwim` ran instead. The telemetry said so plainly
-- `aim null skip null` on every line, fields nothing else writes.

Bind both slots on every chassis.

### `validStandingPosition` TREATS ANY LIQUID AS STANDABLE WHEN `avoidLiquid` IS FALSE
`fact.pathing.liquidstandable`

    if (world.rectTileCollision(groundRegion, {...})
        or (not avoidLiquid and world.liquidAt(position)))
       and not world.rectTileCollision(boundRegion, collisionSet) then

So for an amphibious walker, `mustEndOnGround` being true does not restrict
underwater targets at all -- a submerged position IS a valid standing position.
This is most of why the otter works without any transition code.

**AND IT IS ALSO WHY A SUBMERGED FARM ANIMAL WAS UNREACHABLE FOR AN ENTIRE
SESSION.** The same permissiveness that lets the otter swim means EVERY point in
the water passes, so `findGroundPosition` stops at the first one it meets rather
than descending to the seabed. A cow's entity position is its CENTRE, floating
above the floor; a dropped item rests ON the floor. Same pond, same resolver,
two tiles apart:

    drop  [2536.42,1142.62] -> [2536.5,1142.8]   reached, collected
    cow   [2534.33,1143.38] -> [2534.5,1143.8]   no route, ever

Exactly one tile, and no bias to blame: from 1143.38 the floating spot is 0.42
away and the seabed 0.58, so the NEARER answer was returned and nothing objected
to it. A walking chassis cannot finish a path in open water, so A* was correct
to find none.

**THE RESOLVER NOW DESCENDS WHEN A CANDIDATE IS WET WITH NO FLOOR BENEATH IT** --
see `fact.pathing.floatingtarget`. This entry stays as the mechanism; that one is
what to do about it.

### A SUBMERGED TARGET RESOLVES TO A FLOATING POINT UNLESS THE RESOLVER DESCENDS
`fact.pathing.floatingtarget` -- see also `fact.pathing.liquidstandable`, `arch.pathing.standablerank`

MEASURED 2026-08-30, and it cost most of a session and three wrong fixes.

`findGroundPosition` returns ONE answer per column, the nearest standable spot
to the y it was given. Underwater that is whatever it meets first, because
`validStandingPosition` calls every submerged point standable. For any target
whose y sits above the floor -- which is every living entity, since an entity
position is its centre -- the answer hangs in open water and a walking chassis
can never finish a path there.

**THE FIX DESCENDS, IT DOES NOT REJECT, AND THAT DISTINCTION IS THE WHOLE
LESSON.** Rejecting the floating answer was tried first and broke every
submerged target: refusing what a column returned discards the COLUMN, it does
not make the column search lower. All seven columns returned the same floating
y, all seven were refused, and the resolver reported no standable position at
all -- 1456 rejections and a unit that never moved. The comment claiming the
search would "continue on its own terms" was wrong and the code inherited it.

So it steps down a tile at a time, re-validating each with the same predicates
the column search uses, stopping at the first solid tile either way. Free movers
are exempt -- a flyer or an aquatic unit is SUPPOSED to finish in open water.
Dry land exits on the first predicate.

**THREE FIXES WERE WRITTEN AND REVERTED BEFORE THE RIGHT LAYER WAS FOUND**, and
all three died to one log each:

    target-node lift        fired 18 times, never once for the cow -- animal
                            work does not call petports_standingPointNear
    maxLandingVelocity      relaxed to -1000: EVERY target began failing,
                            37 exhausted searches, because removing the ceiling
                            adds ruinously many drop edges and the search spends
                            its whole node budget enumerating falls
    reject-not-descend      as above

**WHAT ACTUALLY CRACKED IT WAS A CONTROL, NOT A THEORY.** A pile of dirt dropped
beside the cow was collected without trouble, which killed terrain, descent,
distance and coverage in one action and turned the remaining question into
arithmetic. Reach for the control earlier.

### `moveArc`'s grounded branch has two defects and they compound
`fact.pathing.movearcdefects` -- see also `dd.pathing.motionnothealth`, `arch.pathing.arcmover`

From vanilla's `/scripts/pathing.lua`:

    self.arcDelta = self.arcDelta or self.delta[1]
    moveX(self.arcDelta, run)

**`arcDelta` LATCHES.** Taken once on the first grounded tick, never recomputed.
It is a direction held forever rather than an approach.

**`run` IS AN UNDECLARED GLOBAL.** `moveWalk` opens with `local run = self.run`;
`moveArc` never declares it. So a nil global reaches
`mcontroller.controlMove(direction, run)`, where the run flag DEFAULTS TO TRUE.
The run-up therefore happens at runSpeed, not walkSpeed. Same shape as the
`holdTime` typo in `timedDrop` -- an undeclared global standing in for a
parameter, silently, in the same file.

And nothing terminates it: `passedTarget` cannot advance a vertical arc edge,
because `edgeDistance[1]` is 0 and its own `~= 0` guard rejects that, while the
unit is ABOVE a target it was meant to fall to so axis 2 never changes sign.

MEASURED, from the `dx` field which is the distance to the edge target:

    [3768.2,1026.8]   dx -0.04   velocity   0      arcDelta latched
    [3767.82,1026.8]  dx +0.34   velocity  -7.59
    [3766.88,1026.8]  dx +1.28   velocity -11.8    runSpeed, wrong direction
    [3762.88,1026.21] dx +5.28   velocity -12      off the end of the rung

dx crosses zero on the second tick and the unit keeps accelerating away from it.
Six tiles later it left the platform and fell sixteen.

### moveDrop's hold time is dead code, and the bug is a typo
`fact.pathing.movedrop`

CONFIRMED FROM VANILLA SOURCE, not yet fixed. `/scripts/pathing.lua`:

    function PathMover:timedDrop(time)
      if holdTime == nil then holdTime = 0 end
      holdTime = math.min(holdTime, 0.5)
      mcontroller.controlDown()
      self.downHoldTimer = holdTime
    end

**THE PARAMETER IS `time` AND THE BODY USES `holdTime`.** `holdTime` is not
declared anywhere -- it is an undeclared GLOBAL in the entity's script
environment. So:

  - the argument is ignored completely. `moveDrop` computes
    `math.max(timeToFall(-self.delta[2]), 0.05)` and hands over a genuine fall
    time, and nothing reads it.
  - on the first call the global is nil, so it is set to `0`. `math.min(0, 0.5)`
    is 0, and `downHoldTimer` becomes 0.
  - the global then stays 0 for the life of the entity, so EVERY subsequent drop
    also gets 0.

`update` gates on `self.downHoldTimer ~= nil`, and 0 is not nil, so
`keepDropping` runs once and immediately clears it. **The net hold is one
`controlDown()` in `timedDrop` plus one more on the following tick** -- about a
tick and a half regardless of how far the unit is meant to fall.

**So there is no setting to tune. The knob exists, is computed correctly, and is
thrown away.** Any behaviour that looks like "it does not hold down long enough
to fall through the platform" is this, and no amount of adjusting the value
passed in will change it.

**The fix does not need a parallel `moveDrop`.** Only `timedDrop` is broken, and
the surrounding logic -- the x snap to `nextPathPosition`, `setXVelocity(0)`,
`advancePath` -- is fine. Override the one function on the pather INSTANCE, the
same way `moveJump` and `exploreRate` already are, and vanilla's `moveDrop` will
then work as written:

    self.pather.timedDrop = function(pather, time)
      pather.downHoldTimer = math.min(time or 0, 0.5)
      mcontroller.controlDown()
    end

Watch the parameter name, as with the other movers: `moveDrop` calls it as
`self:timedDrop(...)`, so the pather arrives as the first argument while `self`
inside our files is the monster's script table.

Unfixed deliberately -- harvesting was mid-test when this was found, and the
process note is emphatic about not stacking an unverified change onto one.

### `PathMover:new` DEFAULTS `mustEndOnGround` FROM `gravityEnabled`
`fact.pathing.mustendonground`

    mustEndOnGround = mcontroller.baseParameters().gravityEnabled,

`petports_pathOptions` hardcoded `true`, which overrode that default and gated
every flyer target through `validStandingPosition`. That deletes the entire
locomotion class. It is now derived.

### ONE CONTROL SAMPLE PER EDGE -- THE PLANNER IS AT THE NYQUIST LIMIT
`fact.pathing.nyquist`

Measured on a level run at `flySpeed` 12:

    srcDist 1.11743  dstDist 0.117458   edge 4 -> edge 5
    srcDist 1.11719  dstDist 0.117188   edge 5 -> edge 6
    srcDist 1.11694  dstDist 0.116943   edge 6 -> edge 7

Edges are a tile apart and the unit covers one tile per ~81ms script tick,
landing a constant 0.117 PAST each waypoint and advancing exactly one edge. The
control loop gets ONE SAMPLE PER WAYPOINT and cannot track a path whose
waypoints are spaced at its own per-tick travel distance.

Invisible on level ground -- y holds to within 0.002 for twenty edges. It bites
when a plan puts its whole vertical change on ONE edge: a 45-degree dive held
for two ticks overshot by 0.59 tiles, reversed, overshot back by 0.14. EVERY
excursion measured was edge 1 of a fresh plan; not one was mid-plan.

FIXED BY STRING-PULLING, not by tuning. `petportsFreeMover` aims at the furthest
waypoint with clear line of sight rather than the next one, which turns a
53-degree dive into a 2-degree descent spread over seven ticks. Simulated
against the logged geometry: per-tick vertical commitment fell from 0.778 tiles
to 0.032.

It also kills `passedTarget`'s defect as a side effect. That predicate is

    passedTargetOnAxis(edge, 1) or passedTargetOnAxis(edge, 2)

an OR, so a waypoint is consumed the moment EITHER component is crossed while
the other still carries error. A unit that stays on the line crosses both
together and the OR stops being reachable.

### Over-dropping was never about the hold time -- RESOLVED
`fact.pathing.overdropping`

**THE ACTUAL BUG: the pather executes a Drop edge the unit has already fallen
past.** Reproduced, and the two log lines say it outright:

    post-move at [1207,723.8]: action Drop edge 4 of 26 src [1207,726.8] srcDist 3
    drop hold 0.05 from y 723.8

An Arc overshot and the Land put the unit at y 723.8. Edge 4 is a Drop whose
SOURCE is 726.8 -- three tiles above where the unit actually was. It had already
fallen past that node, and the pather ran the edge anyway. The edge's target was
level with the unit: vanilla asks for `max(timeToFall(-delta[2]), 0.05)` and got
the 0.05 FLOOR, meaning an intended descent of about a tenth of a tile. Pressing
down there put the unit through the platform it had just landed on. The loop
repeated on a six-second cycle.

**This is why tuning the hold duration never worked.** 0.5, 0.158, 0.1 -- any of
them passes a unit through a platform when the press should not have happened at
all. Two sessions went into the number before the reproduction named the edge.

**THE FIX: if the next node is not at least half a tile below, consume the edge
and do not touch the controls.** `advancePath` still runs inside vanilla's
`moveDrop`, so the plan advances -- correct, because the unit is already past
that node. The stale `downHoldTimer` is cleared explicitly on the skip, since a
leftover timer would have `keepDropping` pressing through the skipped edge and
reproduce the same bug by another route.

Verified: no aberrant fallthroughs across several runs, and the skip did not
fire at all in the clean ones -- the paths were genuinely fine rather than being
rescued by the guard.

**WATCH FOR THE INVERSE.** If a unit ever stalls standing on a platform instead
of over-dropping, this guard is refusing a drop it should allow, and
`MIN_DROP_DISTANCE` is the number.

**THERE WAS A SECOND, UNRELATED OVER-DROP, AND THIS SECTION DOES NOT COVER IT.**
Everything above is still true and `MIN_DROP_DISTANCE` is still live — an edge
the unit has already fallen past really was a bug and really is fixed. But a
different one survived it: a drop whose edge was perfectly valid, on a stack of
platforms two tiles apart, missing its target by one platform every time.

That one is not about which edge runs. It is about `controlDown` itself, which
starts a fall-through state script cannot observe or cancel — one press carried
the unit through two platform surfaces. The sentence above, "this is why tuning
the hold duration never worked", was right about the reason it never worked
HERE and wrong as a general claim: four further hold values were tried against
the second bug and none could have worked either, for a completely different
reason. See the `controlDown` trap and "Dropping through a platform is a
PLACEMENT" in the movers section.

### THE ACTOR CAN PERFORM A PARTIAL JUMP. THE OLD CLAIM WAS ABOUT THE WRONG PATH
`fact.pathing.partialjump`

Recorded several places as physics: "the actor CANNOT perform a partial jump --
`jumpInitialPercentage` 1.0 and `jumpHoldTime` 0.0". Those govern the jump
CONTROL, and `petportsJumpMover` does not use it:

    mcontroller.setVelocity({edge.jumpVelocity[1], vy})

Launch velocity is set directly and always has been. It can be lowered just as
easily as raised. **Only ever raising was a POLICY, not a constraint** --

**AND THE POLICY IS GONE.** `solveLaunch` lowers the launch whenever the plan's
Land sits on the ascending crossing, which was 14 of 14 unexecutable takeoffs in
one log. See `arch.pathing.solvelaunch`. The ceiling-collision worry that
justified the policy is bounded rather than argued away: the solver never exceeds
the plan's own apex by more than `JUMP_ARC_CLEARANCE`, and only in the
pathological case, where the real trajectory was going five tiles higher anyway.

Checked against the cage anyway and it does not help there: matching the
planner's apex would launch at ~15.3, rise a tile, and land back on the rung it
left, because the plan's DESCENT through a platform is unexecutable too. The
plan was wrong at both ends.

### THE PATHFINDER AND THE MOVEMENT CONTROLLER DISAGREE ABOUT WHAT IS PASSABLE
`fact.pathing.plannerdisagrees` -- see also `todo.pathing.jumpmodel`

    CollisionSet const CollisionSolid{CollisionKind::Null, CollisionKind::Slippery,
                                      CollisionKind::Block, CollisionKind::Slippery};

`validPosition` tests against that set and PLATFORM IS NOT IN IT, so A* routes
straight down through platforms. The movement controller does not: standing on a
platform, a downward `controlApproachVelocity` does nothing, `onGround` stays
true, and the edge never completes.

MEASURED: an amphibious unit stood on the very crate it was delivering to,
planning a Swim edge one tile below itself, for the full ten seconds until the
progress watchdog fired. `mcontroller.controlDown()` is the opt-in, and it is
the first line of vanilla's `flyInGeneralDirection`.

SECOND INSTANCE OF ONE PATTERN THIS SESSION. The `avoidLiquid` bug was the same
shape: the search and the walker answering one question differently. Both cost
a ten-second stall, neither produced an error. EXPECT A THIRD.

**THE THIRD ARRIVED, 2026-08-28, AND IT IS THE MOST EXPENSIVE OF THE THREE.**
`mcontroller.onGround()` says grounded; the search's rounded start node says
airborne. Same shape again -- two answers to one question, no error raised --
but where the first two cost a ten-second stall this one cost 92 seconds and a
re-home, because nothing in its loop moved and so nothing could break it. See
`fact.pathing.originnode` and `arch.pathing.originnudge`.

EXPECT A FOURTH. Three instances is a pattern, not a coincidence: the Lua and
the C++ hold SEPARATE implementations of walkability, standing and grounding,
and nothing keeps them in step. `fact.pathing.ongroundtest` lists five more
places the two already disagree that have not yet cost anything.

### Dropping through a platform is a PLACEMENT, not a control press
`fact.pathing.platformdrop`

`petportsTimedDrop` no longer calls `controlDown` at all in the ordinary case. It
finds the lowest platform whose surface sits above the Drop edge's floor — the
last one the plan wants passed — and places the feet 0.25 tiles (two pixels)
below it with `mcontroller.setPosition`. Gravity does the rest and no engine
state is left running.

**This is idiomatic here, not a workaround.** `moveJump` already calls
`setPosition(source)` because approaching a takeoff point by velocity is not
precise enough, and vanilla's own `moveDrop` already calls `setPosition` on the x
axis for the same reason. The drop is the third instance of the same pattern.
What got skipped is not physics — gravity, collision and the landing are all
still the controller's job — it is an input whose effect cannot be observed. See
the `controlDown` trap for why no hold length could ever have been correct.

`downHoldTimer` is deliberately left nil on a successful placement, so
`PathMover:move` never takes its blind early-return branch.

**It fails closed.** If the destination overlaps `Null`, `Block` or `Dynamic` the
placement is refused, logged with the reason, and it falls back to `controlDown`.
Platforms are excluded from that check on purpose — being inside one is the
point. A unit that does not drop stalls visibly and replans; a unit placed inside
terrain does not.

**The limit to know about:** a placement bypasses the collision sweep between
origin and destination. `bodyFitsWithFeetAt` checks the destination, not the
path. Fine at 0.25 tiles, not fine at a larger `DROP_SCOOT` — raise that constant
and the check has to become a sweep.

Tile arithmetic here was validated by replaying every drop in a real log against
the new rule before launching. That caught `ceil` instead of `floor` for the
start row, which would have kept down pressed on exactly the tick that has to be
quiet — reproducing the bug through the fix and looking like the rule was wrong.
Keep that habit for any tile-arithmetic change.

**Platform geometry, since it is easy to get off by one.** A platform tile at row
N collides at y = N + 1, and a unit standing on it rests with its feet at N + 1.
Confirmed by probe: a stack reading `P713 P711 P709 P707 P705` puts the unit at
714.8, 712.8, 710.8, 708.8, 706.8.

---

### `PathFinder:find` SEARCHES FROM `mcontroller.position()`, SO REFUSING A PLAN CANNOT LOOP
`fact.pathing.searchorigin`

`find()` calls `start(mcontroller.position(), targetPosition)`. Every search
begins where the unit actually is, so A* cannot keep handing back a route for a
surface the unit is not standing on. Refusing a plan costs one search and never
repeats for the same reason.

This matters because the opposite fear -- refuse, replan, get the same plan,
refuse again -- is the intuition that produced a whole build of over-engineering
here. It is only true when A* genuinely returns the same plan from the same
tile, which is the unexecutable-jump case and nothing else.

**THERE IS A SECOND CASE AND IT IS WORSE.** "Begins where the unit actually is"
is only a guarantee of progress if the unit MOVES. A unit whose start node is
not `onGround` gets a plan opening with a ballistic fall it cannot perform, the
arc-landing guard correctly refuses it, and A* re-runs from a byte-identical
position and returns a byte-identical plan. Measured at 297 refusals over 92
seconds with zero displacement -- see `fact.pathing.originnode`. Read the
sentence above as "refusing a plan does not loop PROVIDED the refusal changes
something", and note that a refusal on its own changes nothing.

Related, and safe: `reset()` does not clear `aStar`, but `explore()` sets
`aStar` to nil on BOTH success and failure. So after a completed path there is
no live search, and calling `reset()` to force a replan is safe. That is why the
stall detector has always been able to do it.

### THE SEARCH STARTS FROM A ROUNDED NODE WITH NO VELOCITY, AND AN AIRBORNE ONE PLANS A FALL
`fact.pathing.originnode` -- see also `arch.pathing.originnudge`, `fact.pathing.searchorigin`, `ref.pathing.nodelattice`

CONFIRMED FROM SOURCE, `StarPlatformerAStar.cpp`. `initAStar` does:

    Vec2F roundedFrom = roundToNode(m_searchFrom);
    m_astar->start(Node{roundedFrom, {}}, Node{roundedTo, {}});

The start node is the ROUNDED position and carries NO velocity. `neighbors()`
then dispatches on that node:

    if (node.velocity.isValid())            getArcNeighbors
    else if (inLiquid(node.position))       getSwimmingNeighbors
    else if (acceleration[1] == 0.0f)       getFlyingNeighbors
    else if (onGround(node.position))       getWalkingNeighbors + Jump (+ Drop)
    else                                    getFallingNeighbors     // Action::Arc

**SO A START NODE THAT IS NOT `onGround` PRODUCES A PLAN BEGINNING WITH Arc
EDGES -- A BALLISTIC FALL.** Not an exhausted search, which is what this looked
like from in game and what was guessed twice. See `dead.pathing.originexhaust`.

THE UNIT AND ITS NODE ARE DIFFERENT PLACES. A body 1.6 wide standing on the
corner of a crate is genuinely `onGround` while its node hangs over the void:

    unit        [2503.39,1166.79]   body 2502.59..2504.19, crate at column 2504
    node        [2503,1166.8]       body 2502.20..2503.80, entirely over air
    carried by a 0.19-tile sliver of crate

    UNIT approach at [2503.39,1166.79] (standable true) ... onGround true
    UNIT path ACQUIRED ... action Arc ... edge 1 of 93

**THE ORIGIN IS THE CONSTANT, NOT THE GOAL.** Three different targets that
session -- [2520.5,1152.8], [2501.5,1163.8], [2549.5,1159.8] -- all produced a
first edge descending from [2503,1166.8]. That is the diagnosis in one line, and
it is the check to run first if this shape ever reappears.

**EVERY RUNG OF THE RECOVERY LADDER BELOW `rehomeUnit` IS BLIND TO IT.** The
recall is a `"return"` task that plans from the same origin and gets the
identical fall, so only the teleport can break the loop. 297 refusals, 92
seconds, `unreachableFailures 3 of 3`, re-home.

**The drop machinery cannot rescue this and refusing is correct.** Two probes
over the same tile row and the same body width settle what the perch is:
`validStandingPosition`'s ground region collides with
`{Null, Block, Dynamic, Platform}` while `lastPlatformToPass` finds nothing
against `{Platform}` alone -- so it is Block or Dynamic, and there is nothing to
fall through. A crate top is not a platform surface.

### `smallJumpMultiplier` IS A SECOND JUMP HEIGHT, AND AT 1.0 THE PLANNER HAS ONLY ONE
`fact.pathing.smalljump` -- see also `fact.pathing.squarestep`, `fact.pathing.partialjump`, `todo.pathing.jumpmodel`

    void PathFinder::getJumpingNeighbors(Node const& node, List<Edge>& n) const {
      if (Maybe<float> jumpSpeed = m_movementParams.airJumpProfile.jumpSpeed) {
        ...
        forEachArcVelocity(*jumpSpeed, addVel);
        forEachArcVelocity(*jumpSpeed * smallJumpMultiplier, addVel);
      }
    }

`forEachArcVelocity` emits five velocities -- `(0,vy)`, `(+-walkSpeed,vy)`,
`(+-runSpeed,vy)` -- so this runs TWICE and A* is offered TWO jump strengths.

**IT IS NOT A MINIMUM, NOT A TOLERANCE, AND NOT A CONSTRAINT THAT JUMPS MUST
MATCH.** Every one of those readings is natural from the name and all are wrong.
It ADDS a set of options; it never removes any. At 1.0 the second call is a
duplicate of the first and **the planner has exactly one jump available, the
maximum**.

**SO EVERY JUMP THIS MOD EVER PLANNED WAS A FULL-STRENGTH LAUNCH.** 45 into
g 120 is an 8.44-tile rise and 6.0 tiles of horizontal travel at walkSpeed. A
unit that needed to get onto a ONE-TILE STEP was planned that, or nothing.

Rise goes with the SQUARE of the multiplier, so the numbers are much smaller
than the name suggests:

    mult      launch    rise    airtime   x @walk8   x @run12
    1.0        45.00    8.438     0.750       6.00       9.00   what we had
    0.75       33.75    4.746     0.562       4.50       6.75   C++ default
    0.70711    31.82    4.219     0.530       4.24       6.36   vanilla Lua, half HEIGHT
    0.5        22.50    2.109     0.375       3.00       4.50   ours now

**0.5 IS NOT VANILLA'S HALF-HEIGHT.** Vanilla's Lua picks `1/sqrt(2)`
deliberately, commented "0.5 multiplier to jump height", because of the square.
0.5 QUARTERS the height. That is a choice about the terrain players build --
one and two tile steps -- not an attempt to match vanilla. `0.70711` is the next
stop if 0.5 proves too small, and the reason to prefer it would be "match
vanilla", not "fix a bug".

**MEASURED IN GAME, AND THE EFFECT IS NOT SUBTLE.** Dramatic overshoots became
measured hops across the board. A large share of what this file catalogues as
MOVER defects was downstream of arcs being four times taller than the terrain
required -- `ref.pathing.horizontaljumps` measuring three tiles of clearance for
a 1.75-wide body, and `todo.pathing.jumpmodel`'s wall-clip cancellation which
"only occurs where an arc touches a wall". A quarter-height arc sweeps a small
fraction of the volume and touches far fewer walls.

**NOTHING BECOMES UNREACHABLE.** The full 8.44 jump is still generated, and
`jumpCost` is FLAT regardless of strength (`DefaultJumpCost` 3.0, or
`liquidJumpCost` from liquid), so A* is not biased toward the small hop -- it
picks on path length. If a high ledge that used to work stops working, that
CONTRADICTS this model and wants a log.

**THE COST TO WATCH IS SEARCH TIME, NOT REACHABILITY.** Branching factor at the
jump nodes doubles from five distinct velocities to ten. `maxFScore` is 1200, so
a long route that previously fit could in principle exhaust. The readout is the
`path found after X s` line.

### THE PATHFINDER CANNOT WALK UP A ONE-TILE SQUARE STEP
`fact.pathing.squarestep` -- see also `fact.pathing.smalljump`, `ref.pathing.landings`

CONFIRMED FROM SOURCE AND FROM A TERRAIN PROBE. `getWalkingNeighborsInDirection`
offers the step-up node only under `slopeUp`:

    if (slopeUp && onGround(forwardAndUp) && validPosition(forwardAndUp))
      addNode(Node{forwardAndUp, {}});           // walk up a slope
    else if (validPosition(forward) && onGround(forward))
      addNode(Node{forward, {}});                // walk along a flat plane

and `slopeUp` can only be set inside a test that requires a DIAGONAL polygon
side:

    if (sideDir[0] != 0 && sideDir[1] != 0 && ...)

**A SQUARE BLOCK HAS ONLY AXIS-ALIGNED SIDES, SO `slopeUp` IS ALWAYS FALSE AND
THE `forwardAndUp` BRANCH IS UNREACHABLE FOR IT.** Meanwhile `forward` fails
`validPosition` because the block is inside the body at the current height. So
walking into a one-tile square step generates **NO NEIGHBOUR AT ALL** in that
direction.

**AND THE NODE IT REFUSES IS PERFECTLY GOOD.** Measured: a `logblock` at x 2502
row 1152, rows 1153 and 1154 empty above it. A body with feet at 1153.0 fits and
is `onGround`. The engine declines to offer it purely because the block is
square.

**SO A ONE-TILE STEP IS JUMP-ONLY**, and with `smallJumpMultiplier` at 1.0 the
only jump available was 8.44 tiles. That combination is what produced the coffee
route: walk the platform, DROP INTO THE SEA, cross underwater, and launch back
out onto the crop bed. It read as a stupid plan and was the ONLY plan -- walking
up was not an edge, and the hop did not exist.

MEASURED, `/entityeval` on row 1152 and the two above it:

    2498:dirt/false/false   2501:dirt/false/false    2504:false/false/false
    2499:dirt/false/false   2502:logblock/false/false
    2500:dirt/false/false   2503:false/false/false

**PLAYERS BUILD SQUARE STEPS CONSTANTLY.** This is not an exotic geometry. A
platform at the step is traversable and fixes it outright; a genuinely sloped
block would too, since that is the only thing `slopeUp` recognises.

### `validStandingPosition` IS NOT THE ENGINE'S `onGround`, AND FIVE THINGS DIFFER
`fact.pathing.ongroundtest` -- see also `arch.pathing.originnudge`, `fact.pathing.plannerdisagrees`

    bool PathFinder::onGround(Vec2F pos, BoundBoxKind boundKind) const {
      auto groundRect = groundCollisionRect(pos, boundKind);
      if (rectTileCollision(boundBox(pos, boundKind), CollisionDynamic))
        return rectTileCollision(groundRect, CollisionFloorOnly);
      return rectTileCollision(groundRect, CollisionAny)
          || rectTileCollision(groundRect.translated(Vec2I(0, 1)), CollisionSolid);
    }

Against `pathutil.lua`'s `validStandingPosition`:

1.  `CollisionAny` includes **Slippery**. The Lua set is
    `{Null, Block, Dynamic, Platform}`. **ICE IS NOT GROUND TO US AND IS TO THE
    ENGINE.**
2.  The `translated(0,1)` clause lets the engine count ground **a full tile
    below** the feet -- "rounded collision polys". The Lua has no equivalent.
3.  Standing INSIDE a Dynamic object switches the engine to `CollisionFloorOnly`.
    No Lua equivalent.
4.  The engine uses `RectI::integral`; the Lua uses float rects.
5.  The engine's `onGround` never checks the body FITS. `validStandingPosition`
    does, via `not rectTileCollision(boundRegion, collisionSet)`.

**EVERY ONE OF THESE MAKES THE LUA STRICTER**, so a disagreement surfaces as a
spurious nudge, never as a missed trap. That is the only reason
`arch.pathing.originnudge` can lean on the wrong predicate safely, and it is
load-bearing -- if the Lua is ever made more permissive, re-derive that argument
before shipping it.

### `moveSwim` HAS NO `while` LOOP, AND THAT IS THE RUBBERBANDING
`fact.pathing.swimnoloop`

`moveFly` drains the whole run of passed edges each tick. `moveSwim` advances at
most ONE. So any overshoot of more than one edge leaves the cursor BEHIND the
unit, and the next command points back at a waypoint already passed. That is the
visible left-right oscillation, and it appeared identically on the aquatic
chassis and then on a ground unit in water.

### Engine constraint: work only happens where a player is
`fact.port.loadedonly`

Starbound ticks loaded chunks only, and a world unloads entirely when its last
player leaves. No pet task runs on an unattended world. This is the hard limit
that shapes every automation design here, and it is not something the mod can
work around.

**State the scope precisely, because it is easy to misremember as more.** The
precondition is at least one active player *on that world*. A colony nobody is
visiting does nothing, chunk-loading or not. The feature buys range within a
world, not persistence across worlds.

What the mod *can* do is keep arbitrary regions of an already-loaded world
resident:

    bool world.loadRegion(RectF region)

Attempts to load all sectors overlapping the region; returns true if all are
fully loaded. That extends automation range across a planet the player is
standing on — a farm at the far end of a colony keeps working while the player
is elsewhere on the same world.

**Within that bound, this is new ground.** Vanilla's own long-range automation
does not attempt it — rail trams die at load distance and will not run a route
while the player is elsewhere on the planet, which is why nobody builds
transport networks that matter. Making pet tasks work reliably offscreen, at
arbitrary range on a loaded world, is the differentiating claim of this system
rather than an implementation detail of it. It is also the part most likely to
be copied, and the part most likely to draw complaints if it performs badly.

Cost is accepted: resident chunks are expensive, and the tradeoff is deliberate.

### A `local function` called from above its definition is a nil GLOBAL
`fact.tooling.nilglobal` -- see also `proc.tooling.silentstall`

The file already warns about this from one direction -- `receiveCargo` and
`writeBackToItem` are globals because the handler that calls them is registered
in `init()`, earlier in the file. **The same trap fires in the other direction
and it is easier to walk into.**

Lua resolves a name at COMPILE time. A call written above the `local function`
that defines it does not see that local at all, so it compiles as a lookup of a
GLOBAL by the same name -- which nothing ever assigns. There is no syntax error.
`loadfile` accepts it. It fails only when that line runs.

MEASURED: `sweepReplants` was called from the bottom of `refreshFarmables`,
which is defined earlier in the file. Every port threw
`attempt to call a nil value (global 'sweepReplants')` on its first sweep, five
seconds after the world loaded, and kept throwing every five seconds after.
**An error in an object's `update` aborts the rest of that update**, so
everything downstream of the failing call -- work selection, dispatch, unit
position publishing -- silently did not run on those ticks.

Three ways out, in order of preference:

  1.  **Call it from `workUpdate`**, which is defined after everything. Removes
      the ordering dependency instead of working around it. What was done here.
  2.  Forward-declare `local name` before the first use, then assign with
      `name = function(...)`.
  3.  Make it a global, like `receiveCargo`. Cheapest, and the reason the file
      already has globals in it -- but it puts a name in a shared environment
      for a scoping reason rather than a design one.

**There is a static check for this in the session tooling** (`scope_audit.py`):
it flags any call to a `local function` on a line above its definition. Expect
false positives for calls inside functions that only RUN later; a call in
straight-line code is not one.

**IT ALSO FIRED FOR REAL.** `sweepReplants` was called from the bottom of
`refreshFarmables`, defined earlier in the file. Every port threw
`attempt to call a nil value (global 'sweepReplants')` on its first sweep, five
seconds after world load, and every five seconds after. An error in an object's
`update` ABORTS THE REST OF THAT UPDATE, so work selection, dispatch and unit
position publishing silently did not run on those ticks. Fixed by calling it
from `workUpdate` -- defined after everything -- which removes the ordering
dependency rather than working around it with a forward declaration.

**AND A SECOND, PRE-EXISTING INSTANCE.**
`petportsTaskAction.lua:433`, inside `tryVentRoute`, calls `freshPather()` --
defined as a `local function` at line 876. Every other one of the dozen-plus
calls to `freshPather` sits below the definition and is fine; this one does not.
It is in the branch that logs "target walkable from here, no further hops
needed", which has never appeared in any log to date, so it has never fired.
**UNFIXED, and it will throw the first time a vent route resolves to a plain
walk.** The fix is one line -- move `freshPather` above `tryVentRoute`, or
forward-declare it.

### `x and nil or y` CAN NEVER YIELD nil, AND IT LOOKS LIKE IT SHOULD
`fact.tooling.andnilor` -- see also `arch.upcycler.burnbox`

`true and nil` is nil, and `nil or false` is false. So BOTH branches of the
expression return the y operand. The idiom works for every value except the
one it is usually reached for.

MEASURED 2026-08-29. `rule.burn = nowAllowed and nil or false` was the whole
mechanism for CLEARING an exclusion, in a design where absent and false are
the two meanings. The field went in on the first click and could never come
back out. Six logged clicks reported "allowed" while storing `false` every
time, because the log printed the intent and the store held the result.

**IT IS SILENT IN EVERY WAY A BUG CAN BE.** It parses, it runs, it type-checks
nowhere, and the failure is a value that is merely wrong rather than missing.
Write the branch:

    if nowAllowed then rule.burn = nil else rule.burn = false end

Both instances in this mod are gone. A grep for `and nil or` should stay
empty.

### `goto` does not exist — Starbound is Lua 5.1
`fact.tooling.lua51`

A `goto continue` idiom is a parse error at load. Use a positive condition
wrapping the block instead. Scan for `goto` and `::label::` before shipping.

### PathFinder:reset() keeps the options it was built with
`fact.pathing.resetkeepsoptions` -- see also `dead.pathing.replannotaloop`

`reset()` clears `edges`, `hasPath` and the cursor. It does NOT clear the
`pathOptions` table the finder was constructed with, and it does not clear
`aStar` either.

**SO A REPLAN THAT GOES THROUGH reset() RE-SEARCHES WITH EVERY VALUE THAT JUST
FAILED**, and from an unchanged position it produces an identical plan. Only
`freshPather` picks up a changed option, because only that constructs a new
finder.

This is why an escalating `smallJumpMultiplier` had to rebuild the pather rather
than reset it, and it is half of why the arc replan loops were byte-identical.

### The movement controller integrates with explicit Euler at 1/60
`fact.pathing.eulertick` -- see also `arch.pathing.solvelaunch`

Position is advanced using the velocity from BEFORE gravity is applied that tick,
so a real trajectory sits ABOVE the ideal parabola:

    y_discrete - y_continuous = g * dt * t / 2

At `g` 120 and `dt` 1/60 that is exactly `t` tiles. Half a tile at half a second
of airtime, and it grows with hang time.

**MEASURED, NOT ASSUMED.** Fitted per flight over every ballistic in-flight
sample in one session's log, using each tick's own vertical velocity as the
clock: **8 of 9 flights, slope 1.0000, sd 0.0024.** The ninth was a ceiling
contact, where `vy` stops being a clock and the fit is meaningless.

**dt IS NOT AVAILABLE FROM ANY API.** `script.updateDt()` is the SCRIPT delta and
is unrelated -- the controller integrates on the engine tick no matter how often
a script runs. It is a constant in `petportsTaskAction.lua` with the measurement
beside it.

Anything solving a trajectory has to use the discrete form. A solver that is
exactly right about continuous physics is wrong on the ground by `t` tiles, which
is the difference between landing on a ledge and clipping its lip.

### The arc mover flies the unit off its own landing
`fact.pathing.arcmoverthrottle` -- see also `arch.pathing.solvelaunch`

Vanilla's `moveArc` airborne branch does two things every tick that are correct
in flight and catastrophic on contact: it sets `groundFriction` to 0, and it
drives horizontal velocity toward the arc edge's own `source.velocity`.

A Land is a separate edge. A unit touching down while still holding an Arc edge
therefore lands **at full flight speed on a frictionless surface with the
throttle open**, and `moveLand` -- whose entire body is
`controlApproachXVelocity(0, groundForce)` -- never gets a tick to brake it.

Measured: a unit arriving exactly on a one-tile ledge slid off it and fell three
tiles back, five identical laps. `ARCMOVER grounded` appeared ZERO times in the
whole log, so the mover never saw itself land at all.

At script delta 5 the mover gets one look every five physics ticks -- 0.67 tiles
of travel at walkSpeed 8. Any correction here has one shot.

### A Lua table with a hole becomes a Json object, not an array
`fact.tooling.sparsejson` -- see also `arch.module.slots`

A table with keys 1 and 3 and nothing at 2 is not contiguous, so the engine
converts it to an OBJECT with the STRING keys "1" and "3". Read back, `t[3]` with
a NUMBER key misses.

**WHICH SILENTLY DELETES ANYTHING SPARSE THAT CROSSES A JSON BOUNDARY** -- item
parameters, object parameters, the pane mirror. Store sparse collections as a
contiguous list of records carrying their own index instead.

BELIEVED FROM READING, not from a log in this mod. The record-list shape is
correct either way, which is why it was taken without waiting for the
measurement.

### A LABEL REPORTS THE SIZE OF THE TEXT IT LAID OUT
`fact.pane.textmeasure` -- see also `dead.pane.charwidth`, `arch.pane.hoverlayer`

A canvas cannot measure text -- `drawText` returns void and there is no measure
call -- but `widget.getSize` on a LABEL hands back the bounds of the text it just
rendered. That is the only measurement route in the UI.

MEASURED, four bodies at a 140px wrap: 133x25, 137x16, 127x25, 139x25. Widths
track the string; heights fit `7 + (n - 1) * 9` exactly.

**A HIDDEN LABEL STILL LAYS OUT.** A visible alpha-zero twin returned identical
numbers on all four, so the measuring labels are simply `visible: false`.

**THERE IS NO FRAME LAG.** Hover order was Farming, Item Pickup, Sorting,
Machines; a lag of one would have given Item Pickup the 25 belonging to Farming,
and it returned its own 16. `setText` then `getSize` in the same frame is safe.

**`widget.setText` SETS A BUTTON'S CAPTION**, not only a label's value. Verified:
three tab captions and a Take button all resolve through the same sweep.

### A PANE CLIPS A CANVAS THAT OVERHANGS IT, AND FLUSH IS ALREADY TOO FAR
`fact.pane.paneclip` -- see also `arch.pane.hoverlayer`

A canvas positioned so that part of it falls outside the pane is cut at the pane
edge. MEASURED: the petport's art is 337 wide, and tooltip boxes reaching
exactly 337 lost their right edge -- all four participation tooltips, not only
the two whose arithmetic obviously overran.

So a keep-off margin has to REJECT the boundary rather than allow it.

### A BOTTOM-ANCHORED WRAPPED BLOCK GROWS UPWARD ON A CANVAS AND DOWNWARD ON A LABEL
`fact.pane.canvasanchor` -- see also `arch.pane.hoverlayer`

Two renderers, two behaviours, and both were established by being wrong first.

**CANVAS `drawText`, `verticalAnchor = "bottom"`:** the position is the bottom of
the WHOLE BLOCK and lines stack upward from it. The tooltip code assumed the
opposite -- first line at the position, stacking down -- and back-offset the body
by `(lines - 1)` to land its last line on the padding. Under that assumption an
overlap is arithmetically impossible at any height, which is exactly what the
observed overlap falsified.

**LABEL WIDGET, `vAnchor = "bottom"` DECLARED:** the position is the TOP of the
block and the text flows down. The declaration does not change it. A modules
hint placed to grow up into a gap grew down over the readout below it instead.

The canvas API takes `horizontalAnchor`/`verticalAnchor`; a label takes
`hAnchor`/`vAnchor`. They are not interchangeable.

### A FAILED `require` IN A PANE SCRIPT IS SILENT IN THE UI
`fact.pane.requiresilent` -- see also `arch.pane.stringtable`

A missing required asset throws during context load and takes the WHOLE script
with it. The pane still opens. It renders every widget from its config defaults
and runs no code at all, which looks like a plausible pane rather than a broken
one -- the tell is that widgets from every tab are drawn at once, because
`showTab` never ran.

The log line is the only signal. MEASURED by misfiling `petports_strings.lua`.

### A ContainerPane does not forward createTooltip to its script
`fact.pane.notooltips` -- see also `arch.pane.hoverlayer`, `fact.pane.canvasocclusion`

MEASURED ACROSS ALL FOUR PANES. The beacons open with `interactAction`
`"ScriptPane"` and their script tooltips work. The petport and the upcycler open
through `uiConfig`, which makes them ContainerPanes, and neither has EVER shown a
script tooltip -- not one, for the whole life of either pane.

**THE COUNTER-EXAMPLE THAT WASTED TWO FIXES.** The upcycler's rule slot does show
a tooltip, which read as proof that the mechanism worked and the fault was ours.
It is not a script tooltip: `ItemSlotWidget` draws item tooltips for itself, and
that is the only kind either ContainerPane produces.

**AND THERE IS NO WIDGET-LEVEL FIELD TO FALL BACK ON.** A grep of the whole asset
tree finds tooltip text only inside `.tooltip` templates, never as a property on a
widget. `createTooltip` is the only route the engine offers a pane script, and it
is closed to a ContainerPane.

Two wrong fixes went in before this was measured -- one guessing at the hit test,
one adding the `tooltipLayout` the config was genuinely missing. Both were real
defects. Neither was the reason.

### `widget.getChecked` IN A CHECKABLE BUTTON'S CALLBACK IS THE POST-TOGGLE STATE
`fact.pane.checkedpostoggle` -- see also `arch.upcycler.burnbox`

The engine flips the box and THEN fires the callback, so the callback never
sees the state the player clicked on. It sees the state they clicked it INTO.

MEASURED 2026-08-29 across six consecutive clicks on one upcycler rule row,
with the box built checked:

    click 1   box checked     reported false
    click 2   box unchecked   reported true
    click 3+  box checked     reported false

**AND THE SAME LOG DISPROVES THE OTHER HALF OF THE OLD HYPOTHESIS.**
`setChecked(false)` DOES land against a `"checked": true` template default --
click 2 could only have read true if click 1's `setChecked(false)` had taken
effect. Both candidate explanations in `todo.upcycler.checkstatelog` were
wrong, and the real faults were elsewhere entirely.

**THIS DOES NOT MAKE getChecked THE RIGHT THING TO READ.** The rule stays the
authority and the widget is still repainted from it. After a list rebuild the
widget's state comes from the rule anyway, and one authority is cheaper to
reason about than two that merely usually agree.

### A canvas on top kills every item tooltip beneath it
`fact.pane.canvasocclusion` -- see also `arch.pane.hoverlayer`

A full-pane canvas at a high zlevel gave the petport working hover text and took
away the item tooltips on the unit socket and every module slot.

**captureMouseEvents WAS ALREADY false, SO CAPTURE IS NOT WHAT DOES IT.** Being on
top is. A canvas occludes hover detection for everything under it whether or not
anything has been drawn on it.

**A BURIED CANVAS STILL REPORTS THE CURSOR.** At zlevel -5, beneath even the
background, `canvas:mousePosition()` returns live coordinates -- and occludes
nothing, because nothing is under it. That is the whole basis of the hover layer.

`widget.setPosition` MOVES A CANVAS, so one small canvas can serve every hover
target instead of one canvas per widget. `config.getParameter("gui")` returns the
whole widget table at runtime, so tooltips can be declared beside the widgets they
describe and swept at init.

This also explains the sign store: its dispenser is a separate container with a
separate UI because its canvas covers the pane, and an item grid under that canvas
would be dead. That is a workaround, not a design.

### THE MAIN CHUNK HAS A 200-LOCAL CEILING, AND THIS FILE FOUND IT
`fact.port.localceiling` -- see also `arch.port.constantsglobal`

MEASURED 2026-08-29, verbatim from the load:

    Error code 3, [string "/objects/lofty_petports/petport/petp..."]:9475:
    too many local variables (limit is 200) in main function near '('

The limit is PER SCOPE, and a file's main chunk is a scope. It is 200 in every
mainline Lua and in OpenStarbound's vendored lparser.c at the pre-edit fork
commit, which is as close to reading retail as it gets without the binary.
Stacked mods never surface it because separate files are separate chunks --
nothing pools.

The port file entered the session at 198 file-scope locals and sits at 127
after the constants conversion. Adding a file-scope `local` costs a slot;
adding a global, or a field on an existing table, costs nothing.

### SAME NAME IS NOT SAME ITEM -- ROOM IS A DESCRIPTOR QUESTION
`fact.item.descriptorroom`

MEASURED 2026-08-29: dispatch computed "room for 1000" by name math; both
`containerPutItemsAt` calls refused all 1000; the target slots held the same
item NAME with different PARAMETERS. Milk is food, food carries rot state in
its parameters, and the engine merges stacks by DESCRIPTOR -- a slot of older
milk offers no room to fresher milk however much headroom the name arithmetic
sees.

Consequence: any room predicate that will feed a PUT must compare parameters
(`compare` from vanilla util.lua, the same test receiveCargo uses), or cap the
offer to measured room, or both -- this mod now does both.

WHETHER `containerPutItemsAt` SPLITS AN OVERSIZED SAME-DESCRIPTOR OFFER IS
UNMEASURED. The refusals above are fully explained by the descriptor mismatch,
and capping every offer to measured room made the question moot. Do not build
on either answer.

### containerAddItems FILLS FROM THE LOWEST SLOT
`fact.item.addorder`

Measured via the machine-compaction migration (`dd.upcycler.slotsaremeanings`):
items consumed from slots 0 and 1 and re-added landed in slot 0 first. Which
is fine for a crate and is exactly why nothing that re-adds by
`containerAddItems` may ever touch a container whose SLOTS HAVE MEANINGS.

### groundPet.lua ALREADY OWNS INTERACTION
`fact.unit.groundpetinteract` -- see also `arch.unit.headpat`

Read from the vanilla source, 2026-08-29. `groundPet.lua` defines
`interact()` -- happy emote gated on `config.getParameter("interactCooldown",
3.0)` via `self.lastInteract`, which its `init()` zeroes -- and its `init()`
calls `monster.setInteractive(true)`. Its `setAnchor(entityId)` stores the
anchor in `self.anchorId` and writes `storage.anchorPosition`;
`updateAnchor()` re-calls it every second. So a later-loaded script that
defines `interact` REPLACES the emote unless it carries the body forward, the
anchor's entity id is already on `self`, and nothing needs to call
setInteractive again.

## DISPROVEN

### SIZING TEXT BY CHARACTER COUNT, IN ANY LANGUAGE
`dead.pane.charwidth` -- see also `fact.pane.textmeasure`

The tooltip box was sized from `#body * TIP_CHAR_W / wrapWidth`, with
`TIP_CHAR_W` back-fitted at 4.3px from a rendered English string.

MEASURED, the same four English bodies divided by their real line counts: 3.89,
4.44, 5.53, 5.53 px per character. The constant could not have been right,
because WRAPPING BREAKS ON WORD BOUNDARIES and a character count does not
predict where those fall. One tooltip was estimated at four lines and renders in
three, which was the visible slack under it.

A translated string makes it worse rather than differently wrong -- a CJK glyph
is roughly twice a Latin one, so the error becomes a factor and it CLIPS instead
of running long -- but this was already unfixable in the language it was fitted
to. Replaced by measurement, not by a better constant.

### THE UNSOCKET CARGO LOSS, WHICH IS NOT REPRODUCIBLE AND MAY NEVER HAVE BEEN REAL
`dead.cargo.unsocketloss` -- see also `status.port.inventory`

Cargo was reported destroyed by an unsocket, "most of the time", with one stack
of dirt surviving. Three theories were proposed and the first two were wrong.

**THE WRITE PATH IS PROVEN SOUND.** A character save was dumped to JSON after an
unsocket: `parameters.petData.cargo` held 100 snowflakes. The item carries cargo
correctly across an unsocket and a full game shutdown.

**THREE TRACED CYCLES AFTERWARDS WERE CLEAN**, including two live
pickup-unsocket-resocket rounds: item to petData to spawn to deposit, cargo
intact at every step, deposited into the crate within seconds.

**NOTHING FUNCTIONAL CHANGED BETWEEN THE FAILING BUILD AND THE CLEAN ONE.** The
only edits in between were the trace calls themselves. So there is no fix to
point at, and two possibilities remain: it is intermittent, or every observation
was the stale pane described in `proc.tooling.earlyreturn` -- which was live
at the time, froze the pane on an unsocket, and would show a cargo slot the port
had already discarded.

The reported symptom "the pet kept picking up items while holding cargo" fits
the stale pane exactly: a unit with cargo takes the deposit path outright and
cannot be dispatched to a pickup, so the port's own view of cargo was empty.

`CARGO_TRACE` is left ON to catch a recurrence. Do not treat this as closed.

### Ranking by distance under scarcity starves the far machines
`dead.dispatch.nearestfirst` -- see also `dd.dispatch.emptiestfirst`

A mistake worth recording because the reasoning sounded good. With storage full,
deliveries to upcyclers become small, so ranking candidate machines by DISTANCE
instead of room looked like the obvious optimisation — small trips, short walks.

The result was worse than the problem: the two machines nearest the fleet stayed
topped up with one- and two-item deliveries while the three furthest starved at
maximum room.

**Room IS delivery size.** A machine with a thousand free is a thousand-item
trip. Trips were never small because of scarcity; they were small because the
ranking kept choosing machines that could not accept anything. Sorting by room
already sorts by trip value, and it is self-balancing for free.

### Probing is the wrong architecture
`dead.dispatch.probing`

**The probe and the walk are the same computation, run twice.** Measured
breakdown of one 37.4s dispatch-to-planned interval: 10.0s direct A* fails, 7.0s
probe timeout, 8.0s probe timeout, 1.7s probe SUCCESS, 6.0s probe timeout, ~2s
mixed. **About 31 of 37 seconds went to proving negatives.** Every success
resolved in under two seconds. A* succeeds fast and fails slow, because failure
means exhausting the connected region first.

`SEARCH_LIMIT` (6.0s) then gates vent routing behind the direct walk, so a unit in
an enclosed space spends six seconds proving something that was never going to
change before it may consider a vent. Measured in a cage: probes resolved in ~1.2s
once started; the wait was the gate.

**Proposed rework: attempt in nearest-first order, and run scenarios in
parallel.** Path to the target; if that fails, sort vents by distance and path to
the nearest. THE PATH ATTEMPT IS THE REACHABILITY TEST, and on success you already
hold the path. Kick off a pathfinder coroutine per known vent rather than
serialising, and do not gate vent routing behind the direct-traversal timeout --
"can the unit reach the item directly" and "can it be reached from any vent"
should run at the same time. The two finders are already independent objects
(`self.pather.finder` and `self.petportsProbe.finder`), so they can run
concurrently without touching each other.

Also: `planRoute` restarts from scratch EVERY TICK and re-asks the same questions
-- 54 cache answers against 5 real probes in one session, the same edge queried 17
times. Once the path attempt IS the reachability test, both the restart and the
memo disappear together.

### THE PROBE THAT KILLED LIVESTOCK
`dead.farming.probe`

Worth the space, because it is the most damaging bug this project has produced
and the shape of it will recur.

Discovery originally called `hasMonsterHarvest` on every monster in coverage to
find out what each one was -- reasoning that a non-farmable monster has no such
global and returns nil harmlessly, which is true of our own drones. **It is not
true of baby livestock.** Babies run the SAME farmable behavior as adults, so
the function exists, but they carry no `harvestTime` in config:

    farmable.lua:34: attempt to compare nil with number

`resetMonsterHarvest` stores nil, the comparison throws, and **a script error
kills the monster.** The `pcall` on our side caught the exception perfectly and
protected nothing: the error had already happened inside the ANIMAL's script
context. The scan was culling baby Fluffalo once every five seconds.

**A `pcall` protects the CALLER. `callScriptedEntity` runs code in someone
else's context, where the consequences are theirs.** That is the generalisable
lesson, and it applies to every cross-entity call in this mod.

**The fix is to ask about the TYPE, not the animal.**
`root.monsterParameters(monsterType)` reads the type's config, so nothing runs
on the entity and nothing can throw. Both `harvestPool` and `harvestTime` are
required -- `harvestTime` is the one that matters for safety, since its absence
is exactly what killed babies. Our own units fall out for free, having neither.

Checked at BOTH `params.harvestTime` and `params.baseParameters.harvestTime`,
because the mooshi `.monstertype` carries these under `baseParameters` and
whether the binding flattens or nests is undocumented. Cached per type.

The unit repeats the same check before poking rather than trusting the
dispatch, because a task can outlive the dispatch that created it and both calls
in the act run inside the animal's script.

**An intermediate fix is worth remembering as a pattern that was NOT good
enough.** Before `root.monsterParameters` was confirmed to exist, the mitigation
was a per-type verdict cached in `world.properties` -- bounding the damage to
one death per type per world rather than per port per scan. It shipped
correctly and was still wrong: bounded harm is not no harm, and a permanent
"unsafe" verdict would have silently disabled harvesting for any species whose
baby was met first. Deleted entirely once the real filter existed. **Note that
worlds which ran that build carry an orphaned `petports_monsterProbes`
property; nothing reads it.**

### `unclassified`, and the two designs that failed first
`dead.filter.unclassified` -- see also `arch.filter.subgroupor`

A subgroup flagged `unclassified` catches what its SIBLINGS cannot describe. A
group flagged `unclassified` catches what the whole MANIFEST cannot describe —
that is the `Unsorted` group, and `petports_isUnclassified` is memoised per name
because it otherwise walks 200-odd subgroups per item per scan.

Both ask the MANIFEST, never the player's rules. That distinction is the entire
design, and it was arrived at by getting it wrong twice:

1. A normal subgroup matching everything. Subgroups are ORed, so it won over its
   siblings and unticking a race silently did nothing.
2. A fallback consulted when nothing else matched THIS TIME. Better, but
   unticking Glitch pushed the Glitch codexes into the bucket, so its contents
   changed depending on which boxes were ticked.

Both made one switch depend on the others. The current test asks whether a
sibling DESCRIBES the item, whether or not the player has that sibling on — so
unticking a race removes those items from the crate instead of relocating them,
and the bucket holds the same things no matter how anyone has configured
anything.

**Vanilla puts one item in `Unsorted`** — `colonymanual`, which has no species
and no description. Everything else is placed. So that bucket is a mod detector.

### WATER IS A CLOSED SET -- A GRAVITY-DISABLED ACTOR CANNOT PATH OUT OF LIQUID
`dead.locomotion.pelagic` -- see also `fact.pathing.edgebymedium`, `ref.locomotion.chassis`

    void PathFinder::getSwimmingNeighbors(Node const& node, List<Edge>& neighbors) const {
      getFlyingNeighbors(node, neighbors);

      // Also allow jumping out of the water if we're at the surface:
      RectF box = boundBox(node.position);
      if (acceleration(node.position)[1] != 0.0f && m_world->liquidLevel(box).level < 1.0f)
        getJumpingNeighbors(node, neighbors);

      neighbors.filter([this](Edge& edge) -> bool {
        return inLiquid(edge.target.position);
      });

EVERY neighbour of a submerged node is discarded unless its target is ALSO in
liquid. Air-to-water plans fine; water-to-air is not merely expensive, it is
UNREACHABLE -- the goal can never enter the open set.

The one escape is that `getJumpingNeighbors` call. A Jump edge's target is
`node.withVelocity(vel)` -- the SAME position -- so it survives the filter, and
the node then carries velocity, goes to `getArcNeighbors`, and can arc clean
out. That is the Swim -> Jump -> Arc the ground and amphibious chassis do.

IT IS GATED ON `acceleration[1] != 0.0f`, AND ACCELERATION IS ZERO IF ANY OF:
`gravityEnabled` false, `gravityMultiplier` 0, or `mass` 0. So a flyer or a
swimmer can never take it. A "gravity on, multiplier 0" chassis was tried
specifically to get Jump edges back and fails for the same reason.

THIS IS WHY THE PELAGIC CHASSIS WAS CUT. A flyer-swimmer would have outclassed
every other locomotion type while being the least reliable of them, and making
it work needs a cached map of liquid-to-air transition points. Not v1.

VANILLA'S OWN ANSWER IS NOT TO FIX IT. `flyapproach.behavior` wires pathfinding
as `optional -> inverter -> moveToPosition`, falling through to
`flyInGeneralDirection` -- straight at the target with a randomised wobble and
no terrain awareness. Flying monsters surface to attack because WHEN THE SEARCH
FAILS THEY STOP ASKING IT. petports_flyapproach.lua now does the same.

### DO NOT USE itemslot PROXIES FOR CONTAINER SLOTS. Two reasons, either fatal.
`dead.pane.slotproxies` -- see also `fact.pane.threegrids`, `fact.pane.itemslotbutton`

Reaching for proxies is the obvious move when three groups is not enough. It was
tried twice in one session and rolled back twice.

**AN itemslot ONLY HANDLES ONE ITEM.** Putting in or taking out works with a
single item and nothing more. Vanilla never exposes this because the only place
it uses itemslots for real inventory is the mech assembly station, where every
part is NON-STACKABLE -- so the widget looks general and is not. Every slot on
the upcycler takes stacks, which rules proxies out on its own.

**AND SPLITTING THE GRID BINDING BREAKS THE MACHINE.** Removing a grid to free
its slots for proxies changed how the container was bound and the upcycler
misbehaved underneath -- not visibly at the pane, but in what the slots actually
contained. If proxies are ever attempted again the grid must STAY and the proxy
sit over it.

`player.swapSlotItem` and `player.setSwapSlotItem` ARE available from a
container pane script, verified by probe -- that was never the obstacle.

**A PROXY MUST DO ITS CONTAINER WRITE THROUGH THE OBJECT**, by message, and must
not take from the cursor until the object answers. It also must not return a raw
descriptor: clamp the count to one stack, because a container slot can hold more
than `maxStack` and an oversized descriptor crossing the wire surfaces as a
`bad_alloc` on the far side naming neither the pane nor the item.

### The crate perch: two wrong theories and a collision type that was not what anyone said
`dead.pathing.originexhaust` -- see also `fact.pathing.originnode`

**"THE SEARCH EXHAUSTS."** Held independently by both the mod author (from
watching it in game) and Claude (from `petports_flyPointNear`'s note about
positions that cannot plan). It was wrong: the search SUCCEEDS in 0.92 s and
returns 93 edges. What is broken is the plan's first edge, not the search.

The reasoning that made it plausible was itself sound and still is -- "no
fallthrough was observed, so there is no Drop edge" is correct, because the plan
uses **Arc** edges, and Arc is what a falling start node produces. Two correct
premises, one wrong conclusion, because nobody had read `neighbors()`.

**"A DROP EDGE WOULD DROP IT THROUGH THE CRATE."** Claude argued the opposite --
that `petportsTimedDrop` would fail closed on a non-platform crate and look
identical to a stall -- from a confident claim that crates are `Dynamic`.
Corrected by the author to Platform. Both were wrong in different directions,
and the log settled it without either: the perch collides with
`{Null, Block, Dynamic, Platform}` but not with `{Platform}` alone. See
`fact.pathing.originnode`.

**THE RULE ALL THREE POINT AT.** Every one of these was a claim about ENGINE
INTERNALS asserted from memory or from watching behaviour. The C++ is public and
takes two minutes to read -- `StarPlatformerAStar.cpp` answered all three
outright and would have answered them before the first repro was requested. Read
the source before theorising about the source.

### Two diagnoses that were wrong, and what gave them away
`dead.pathing.diagnoses`

Both cost a round trip. Both were caught by evidence already in the log.

**"The compaction loop."** Container 120 was compacted twice, ten seconds apart,
with identical numbers — read as a livelock, and a maxStack-learning fix was
written for it. The disproof was 0.2 seconds after the first pass:

    no dispatch: ... no crate has stacks worth merging

The crate WAS compact, stayed compact for seven seconds, and then fragmented
again because the player was splitting stacks by hand with the container open.
The 8-second gap between passes was itself the tell: had it stayed fragmented,
`compactWork` would have re-dispatched on the next work tick, not eight seconds
later. The fix was backed out; it would have cached a wrong stack size from a
read that caught a player mid-edit.

**"maxStack 50."** Chosen in a Python simulation because it reproduced the
observed six slots, then the simulation working was read as confirmation. The log
never contained a 50. Fitting a number to an outcome is not evidence, and the
mod author's "I have 84 of them in a stack" refuted it in one line.

**The rule both point at:** when a log and a hypothesis disagree, the log has
already answered. Grep the quiet intervals as well as the noisy ones — an absence
of dispatches is data.

### Escalating the small jump multiplier on failure
`dead.pathing.jumpescalation` -- see also `arch.pathing.solvelaunch`, `fact.pathing.resetkeepsoptions`

The theory: no fixed `smallJumpMultiplier` suits all terrain, so each
jump-attributable replan should add 0.1 and a rebuilt pather would offer A* a
second jump height it had not tried. Reset on arrival. It was built, measured
over one session, and removed.

**IT COULD NOT REACH THE FAILING JUMPS.** Every unexecutable takeoff in that log
-- 14 of them, a perfect correlation -- launched at the FULL jump, `[12,45]`.
`smallJumpMultiplier` scales only the SECOND height. No value of it touches those
at all, and escalating toward 1.0 converges the small jump ONTO the full one,
removing the 31.82 option that succeeded every time it was used.

**IT NEVER FIRED WHERE THE LOOPS WERE.** All three observed loops replanned
through the airborne-edge stall, not the arc-landing handler where the hooks
were. The two times it did fire, neither was a jump: one was a Land edge 0.57
tiles out against a 0.5 tolerance, the other a body-clearance failure on a
one-edge walk plan. Two firings, two misattributions, zero real catches.

**THE FAULT WAS IN THE PLAN, NOT THE OPTIONS.** See `arch.pathing.solvelaunch`.

It also cost a deliberate probe/walk divergence -- the probe had to be pinned to
the base multiplier to keep a transient recovery state out of the shared route
cache -- which was a real price against a documented invariant, paid for a
benefit that never existed.

### A replan cannot loop, because the search starts from where the unit is
`dead.pathing.replannotaloop` -- see also `fact.pathing.resetkeepsoptions`

The claim, written into the arc replan sites: `PathFinder:find` always searches
from `mcontroller.position()`, so A* cannot keep handing back a route for a
surface the unit is not on, and refusing a plan therefore costs one search and
never repeats for the same reason.

**IT HOLDS ONLY IF THE UNIT ENDS UP SOMEWHERE NEW.** A unit that fails a jump the
same way every time lands in the same place, walks back to the same tile, and
asks the same question from the same position. Measured: ten consecutive
replans, `srcDist 4.72912` to five decimals every one, and two more loops beside
it.

Same position plus unchanged options -- see `fact.pathing.resetkeepsoptions` --
is the same plan. The search origin is not the loop-breaker it was taken for.

## REFERENCE

### The filter vocabulary is measured, not guessed
`ref.filter.vocabulary`

`workbench/petports_tagdump.py` reads an unpacked asset tree and reports every
category and tag with example item names, plus a spelling-traps section listing
names that differ only by case. `--extensions` lists what file types exist and
which the scanner reads; run that FIRST against any tree, because an extension
that does not exist scans as zero files and looks identical to a category
nothing uses. It found two extensions that had been recited from memory and do
not exist.

**Scanned 4974 files across 24 extensions. 4931 items now route somewhere.** The
43 that do not are the tutorial mission's background scenery, which no player
accumulates.

**All five tags that were marked UNVERIFIED were dead.** `ore`, `ingot`, `bar`,
`gem`, `crystal`, `produce` — none exists on anything. What replaced them:

- Ore matches a name SUFFIX, exact across all 26. Bars are listed by NAME,
  because a `bar` suffix also catches `saloonbar`, which is furniture.
- `produce` does not exist but the split does, and it is the category: raw crops
  are `food`, cooked is `preparedFood`.
- Vanilla has essentially one gem, `diamond`, filed as `craftingMaterial` like
  every other input.

**Three matchers exist beyond categories/tags/items, and each earned itself.**

`suffixes` — for GENERATED items that have no file to tag. Blueprints end
`-recipe`, codexes end `-codex`. Both confirmed in game. Deliberately a suffix
and not a pattern: a pattern field is evaluated per item per scan and lets a
mod author write something expensive into a manifest.

`nameParts` — prefix and suffix, **ANDed**, the only matcher that is not ORed.
Codexes carry no category, no tags and no race field, so the only thing
identifying an Apex codex is its name. A bare `apex` prefix would match every
Apex chair in the game; the `-codex` suffix is what makes the prefix safe. 89 of
123 vanilla codexes are race-prefixed, so this sorts them by species with no
`.patch` files against vanilla assets — which matters because a mod adding
seventy codex entries would otherwise bury every other species.

`unclassified` — a subgroup that catches what no sibling can DESCRIBE. Two
earlier designs failed and both are documented in the resolver: a normal
subgroup matching everything won over its siblings so unticking a race did
nothing, and a fallback consulted "when nothing else matched this time" meant
unticking Glitch pushed Glitch codexes into the bucket. The test now runs
against the manifest rather than the player's switches, so what lands there does
not change as a rule is edited, and it narrows automatically when a mod patches
in a new subgroup.

### The six augment materials share one acquisition fingerprint
`ref.fuel.anchors` -- see also `dd.fuel.anchorchoice`

MEASURED, AND IT IS THE FINDING THE WHOLE FLAVOR MAPPING RESTS ON. Scorched
Core, Cryonic Extract, Venom Sample, Static Cell, Living Root and Phase Matter
share an IDENTICAL fingerprint -- `recipes:N treasure:3 interface:2`, price 50,
no other sink. They are one authored set with one acquisition path and one value.

    Spicy   Scorched Core        Sharp   Static Cell
    Sweet   Cryonic Extract      Zesty   Living Root
    Sour    Venom Sample         Bitter  Phase Matter
    Savory  Alien Meat

Weight tiers, in `petports_flavors.config`:

    8   the augment materials, and only those
    4   deliberate acquisition -- a monster part, or something cooked
    2   farmed or gathered on purpose -- most produce
    1   incidental -- picked up while doing something else, uncounted

### THE DEPRECATION TEST IS A REFERENCE COUNT, AND IT WORKS IN ONE DIRECTION
`ref.item.deprecation`

An item is obtainable if SOMETHING names it -- a treasure pool, a monster's
drops, a biome, a quest, a shop, a recipe. If the only file in the tree that
mentions the name is its own definition, nothing hands it to a player.
`petports_fooddump.py` does this by pulling every quoted token out of every text
asset and intersecting with the item-name set, which is one pass over the tree
rather than one per name.

**A ZERO IS TRUSTWORTHY. A NON-ZERO IS NOT.** The scan matches quoted tokens and
several item names are ordinary English words. Measured: `string` reports 402
references, `dungeons:331` of them, which is the WORD. `basic` is literally the
itemName for Pelt. `bolt`, `lead`, `paper`, `crystal`, `metallic`, `thread` and
`gnome` are all suspect the same way.

**`tiles:1` IS A REAL ACQUISITION PATH**, not a leftover -- that is an item
mined out of a block, which is how Uranium Ore, Plutonium Ore, Moonstone Ore,
Trianglium Ore and Metal Coated Wood all still reach a player. `objects:N` is
ambiguous and needs eyes: it can be a breakable's drop pool or a crafted
object's ingredient list.

### PRODUCE HIDES IN `cookingIngredient`
`ref.item.produce`

Wheat, Sugar, Mushroom (`shroom`), Rice, Cocoa Pod, Cactus, Kelp and Crystal
Plant are all `cookingIngredient`, not `food`. Every one of them has a SEED in
the `seed` category and a COOKED FORM in `preparedFood`, so a scan filtered to
the obvious categories finds both ends of the chain and not the middle -- and an
item missing from a report reads as an item that does not exist.

Generic rule: when a filtered scan comes back missing something you know is
there, print a census of what the filter EXCLUDED. That is now a section in the
tool's report.

### 28 OF 117 CRAFTING MATERIALS ARE UNOBTAINABLE, AND ALMOST NOTHING ELSE IS
`ref.item.unobtainable`

Of 3,649 items in the game only 49 are referenced by nothing at all, and 28 of
those are crafting materials. A quarter of that one drawer is dead and the rest
of the game is essentially clean.

Dead, confirmed: Molten Core, Ice Crystal, Ancient Bones, Cell Materia,
Hardened Monster Plate, Alien Wood Sap, Alien Weird Wood, Wild Vines,
Unidentified Fossil, Endomorphic Jelly, Prisilite Star, Uranium Rod, Fill 'Er
Up, Glass Coffee Mug, and the entire hardware drawer -- Processor, Laser Diode,
Lightbulb, Screws, Iron Hinge, Copper Cog -- plus Robot Chest, Head and Legs,
Artificial Brain, Inferior Brain, Space Age Polymer.

**They still have definition files and read as perfectly normal items.** A
feature built on one looks correct, loads correctly, and never fires.

### Chassis capabilities
`ref.locomotion.chassis` -- see also `arch.locomotion.classes`, `arch.locomotion.liquidpermissions`

    chassis      gravity  media                     liquids refused
    drone        on       physics (avoidLiquid)     all liquid
    flyer        off      canFly                    all liquid
    aquatic      off      canSwim                   lava, corelava, poison
    amphibious   on       physics, avoidLiquid off  lava, corelava, poison

Both permission flags false is a bricked pet and is ALLOWED -- a modder who
configures that did it deliberately.

### Horizontal jumps need body width plus about a tile
`ref.pathing.horizontaljumps`

A jump with any horizontal component sweeps the unit's box along a diagonal, and
the swept volume is wider than the box. The planner's arc collision samples
discrete points along the trajectory rather than sweeping a volume, so a corner
clipped BETWEEN samples is invisible to it -- the same defect that put its own
waypoints through a ceiling.

Measured with a 1.75-wide body: a 2-tile chute with 2-tile tunnels at each end
could not be jumped into. It wanted **3 tiles**. That is body width plus roughly a
tile of sweep.

**Two-tile chutes are walk-only.**

### Ladders are not traversable
`ref.pathing.ladders`

There is no Climb edge. A floor reachable only by ladder is unreachable. Platforms
ARE traversable and validStandingPosition counts them as ground, which is why a
platform column looks like a ladder and works where a ladder does not.

---

### Landings forgive, entries do not
`ref.pathing.landings`

This is the general rule the two above are instances of. Land half a tile off and
you are still on the platform; thread half a tile off and you hit a wall.

**A 1.75 box entering a 2.0 gap has 0.125 tiles of clearance per side, on both
axes simultaneously, at one moment mid-arc.** The execution error measured on this
system is an order of magnitude larger: ~0.5 tiles of apex error before the
launch-velocity correction, and one arc landed 2.2 tiles off in x after clipping
geometry the planner routed it through. No tuning closes that gap.

**No planner option can fix it either.** The pathfinder has ONE boundBox for
in-flight collision. Inflating it past 2.0 to refuse such gaps would
simultaneously make every 2-tile walking corridor impassable. A single box cannot
distinguish "walk through a 2-tile gap" (completely reliable) from "fly through a
2-tile gap" (never works). standingBoundBox and droppingBoundBox do not govern
arcs.

So: put a platform where you want a unit to go up, and give horizontal jumps
room.

### THE NODE LATTICE, CONFIRMED
`ref.pathing.nodelattice`

    float bottom = boundBox.yMin();
    float x = round(pos[0] / NodeGranularity) * NodeGranularity;
    float y = round((pos[1] + bottom) / NodeGranularity) * NodeGranularity - bottom;

`NodeGranularity` is 1.0. So nodes are at whole-number x and at
`integer - boundBox.yMin()` in y -- `.8` for a body with `bounds[2]` of -0.8.
Measured first at 120 of 120 edge targets, then confirmed here.

DERIVED FROM `yMin`, NOT FROM HALF THE HEIGHT. They coincide only for a
symmetric poly: a 1.6-tall body with `bounds[2]` of -0.5 needs `.5` and
half-height would say `.8`.

**THE FUNCTION IS `PathFinder::roundToNode`, AND IT TAKES `bottom` FROM
`m_searchParams.boundBox`** -- the pathOptions box, falling back to
`standingPoly`, NOT from the movement controller. They are the same today
(`[-0.8,-0.8,0.8,0.8]` for every chassis) so nothing is wrong, but pad
`boundBox` in `petports_pathOptions` and the lattice moves. Note also that
`roundToNode` reads the box UNSCALED: `BoundBoxRoundingErrorScaling` is applied
in `boundBox()`, not here.

**`petports_nodePosition` DOES NOT MATCH IT, AND THIS SENTENCE USED TO CLAIM IT
DID.** The old wording -- "uses vanilla's own formula" -- conflated two
different vanilla formulas. The Lua uses `findGroundPosition`'s ALIGNMENT line
(`math.ceil(y) - (bounds[2] % 1)`, snap to the tile line above); the engine uses
`roundToNode` (snap to the NEAREST node). Writing y as `N + f`:

    ours     ceil(y) - 0.2        = N + 0.8   for all f > 0
    engine   round(y - 0.8) + 0.8 = N + 0.8   for f >= 0.3
                                  = N - 0.2   for f <  0.3

So they diverge for **frac(y) in (0, 0.3)**, and ours is then exactly one tile
ABOVE the engine's node.

**IT WAS NOT A MISTAKE WHEN IT WAS WRITTEN.** Git has the Lua landing in
`728928f` and the C++ formula recorded in the handoff at `cc3d3c4`, later the
same day. Its only caller was `petports_flyPointNear`, which needs "a
lattice-aligned anchor near this target" and does not care which lattice point,
because candidates are sorted by true distance afterwards. It acquired a second
caller with a stricter requirement and nobody re-derived it.

**DELIBERATELY NOT FIXED -- see `todo.pathing.nodeformula`.** A settled unit
rests at `frac 0.80`, outside the window, so this is only reachable on
transient heights. Measured at 0.97% of grounded samples in a clean log, and
NOT ONE sample in any log discriminates the two formulas.

### NUMBERS WORTH HAVING
`ref.pathing.numbers`

    DefaultSwimCost        40      and swimCost is a MULTIPLIER: edge.cost *= swimCost
    DefaultLiquidJumpCost  10      priced per jump made FROM liquid
    DefaultMaxDistance     50      filters neighbours by distance from the search START
    NodeGranularity        1.0
    BoundBoxRoundingErrorScaling 0.99   every bound box shrinks 1% before collision
    minimumLiquidPercentage 0.5    what `inLiquid` means to the ENGINE

That last one is a live discrepancy: PETPORTS_SUBMERGED_FILL is 0.9, so a tile
between 0.5 and 0.9 is LIQUID to the pathfinder and AIR to us.

The heuristic is Manhattan distance x 2 -- deliberately overestimating, so
searches terminate faster and paths are feasible rather than optimal.

`goalReachedFn` under `mustEndOnGround` refuses any node that is not `onGround`
OR that still carries velocity, and `validateEndFn` additionally refuses
`Action::Jump` as the final edge. A target reachable only mid-arc is
unreachable by construction.

### Vertical jumps only need body width plus margin
`ref.pathing.verticaljumps`

`jumpVel [0,45]` sweeps nothing sideways, so the volume is just the box going
straight up and 2 tiles of width is genuinely enough. The same tight turn that
failed as a horizontal jump worked as a vertical one with a platform directly
overhead.

### A FILE MUST BE EXCLUDED FROM ITS OWN COUNT BY NAME, NOT BY PATH
`ref.tooling.selfcount`

The reference scan first skipped every reported item file wholesale, so an item
could not reference itself. Harmless under a category filter, because almost no
`.object` was in the report. Fatal under `--all`, where every `.object` IS --
and objects are a main way the game hands things over, through breakable drop
pools and farmable produce.

Measured, same tree, two runs: `bone` went 53 references to 29, losing
`objects:24`. Ember Coral Fragment and Bug Shell went to ZERO, both being
object-sourced entirely. Two live items read as deprecated because of the
REPORT'S OWN FILTER SETTING, which is the exact failure the scan exists to
prevent.

Fixed by discarding the one self-name from a file's hits rather than the file:
`bonechair.object` counts as a reference to `bone` and not to `bonechair`.

### Vanilla tuning notes
`ref.unit.vanillatuning`

`metaBoundBox` is the cursor hit-test box. `petbunny`'s is
`[-1.625, -2.375, 1.75, 2.0]` — 3.4 x 4.4 tiles around a creature whose
`collisionPoly` is about 1.5 x 1.5. That is why vanilla ship pets swallow clicks
meant for whatever is behind them. Ours is sized to the body.

Vanilla's follow loop: `curiosity` regenerates at 1/sec against a `minScore` of
35, while `followAction` drains it at only 5/sec and its `boredTimer` does not
start until the pet has ARRIVED. Net effect is a permanent 3-tile tail. The
monstertype raises the bar and shortens the bore time, but that is TUNING, not a
fix — the rewrite is the fix.

---

## BACKLOG

### Multi-port deferral is arbitration by straight-line distance
`todo.dispatch.deferral`

`anotherUnitIsCloser` picks a winner by straight-line distance, which the comment
concedes is routinely wrong in a player's base. `DEFER_GRACE` exists to undo it
after 12 seconds, `deferredSince` tracks the grace, and a four-way tally exists to
diagnose it. Observed 21 of 22 drops deferred while the other port was already
busy. Claims already arbitrate correctly and cannot deadlock. Deleting deferral
removes `anotherUnitIsCloser`, `DEFER_GRACE`, `deferredSince`, `entry.hasUnit`,
`publishUnitPosition`, `UNIT_POSITION_THRESHOLD`, and two of the four counters.

### Animals move, and nothing chases them
`todo.farming.animalsmove`

`ANIMAL_REACH` is 6.0, more generous than the crop reach, because the standable
ground target resolves ONCE and does not re-resolve as the animal ambles. A
Mooshi is slow enough that this does not matter.

Smaller roving livestock may outwalk it. That presents as an arrival out of
reach, and the failure names the distance, the limit and both positions --
deliberately, so the decision about catch-up behaviour comes from a measurement
rather than a guess.

**Known cosmetic:** the animal stays visually interactive for a tick or two
after the poke. The behavior tree normally pairs `dropMonsterHarvest` with
`setInteractive(false)` and calling out of band skips that half; the next
behavior evaluation re-runs `hasMonsterHarvest`, gets false, and clears it.
`behaviorUpdateDelta` is 2, so it is brief and self-correcting.

### One behaviour change to watch, from the same pass
`todo.farming.behaviourwatch`

`replantGroundTilled` used to accept a tilled mod at the anchor tile OR the one
below, hedging an unverified assumption about where `world.entityPosition` sits
for an object. Watering settled it -- `waterRuns` derives the soil tile the same
way, `floor(cropPosition) - 1`, and wets exactly the right tiles -- so the check
is now `y - 1` only.

Strictly better: a crop whose anchor tile happens to be farmland can no longer
mask missing soil beneath it. But it is a change on a path that was working, so
**if replanting ever starts clearing intents as "not farmland", this is the
first suspect.** The log prints both mods and the `tilled` flag.

### Open decoupling work
`todo.item.nicemicelore`

Descriptions still read "M.A.U.S. utility unit" — Nicemice lore in a standalone
mod. All of it is confined to `description` / `shortdescription` fields.

`colonyTags : ["petports"]` is an invented tag and may simply never match
anything tenant-side. Vanilla tags may serve better depending on what tenants
should ask for.

`petports_placement.lua` reads the avoidance marker tags `avoidMe`,
`avoidMe-goLeft` and `avoidMe-goRight`, which are Nicemice-authored objects. This
degrades safely — in a world without them nothing matches — but this mod should
eventually carry its own markers or drop the concept.

---

### The planner cancels jumps the movement controller does not
`todo.pathing.jumpmodel` -- see also `fact.pathing.partialjump`

**THE LAST STRUCTURAL PATHING PROBLEM, AND IT IS UPSTREAM OF ANYTHING THIS FILE
CAN FIX.** A* draws an arc whose velocity DIES on contact with a side wall,
while the movement controller only kills the horizontal component and carries
the vertical through. Measured twice, in two geometries:

    ARCPLAN edge 31 src [3768.03,1023.69] vel [8,29.5809]
                 -> dst [3768.16,1024.65] vel [0,-2.08638]

Both components gone in one edge. At that same point the real unit measured
`[0.0166, 25]` -- x killed, y intact -- and carried on 2.6 tiles past its own
plan. In a platform cage the same signature produced a 7.45-tile error:

    ARCPLAN VERDICT: planner apex 1025.78 is 7.45337 tiles BELOW what a 45
    jump delivers (1033.24). This jump is UNEXECUTABLE as planned and will
    overshoot -- launchVelocity cannot lower it.

**THAT VERDICT TEXT IS OLD AND SO IS ITS CONCLUSION.** `launchVelocity` is gone;
`solveLaunch` lowers the launch to arrive descending at the plan's landing, and
the message now says so. Every normal jump in a clean log reads -0.5 to -0.9 (the
familiar over-estimate); only wall-clipped arcs go positive.

**WHICH MEANS THE CAGE CASE NOW GETS AN AUTOMATIC CORRECTION IT WAS NEVER
MEASURED WITH, AND IT MAY BE WORSE.** The note below this one predicted exactly
what the solver now does -- match the planner's apex, launch at ~15.3, rise a
tile -- and predicted it lands back on the rung it left, because the plan's
DESCENT through a platform is unexecutable too. That prediction is untested
against the current build. **RE-MEASURE A WALL-CLIPPED ARC BEFORE TRUSTING
ANYTHING HERE.** A cancelled arc is a plan that is wrong at both ends, and a
solver that faithfully flies a wrong plan flies it into the floor.

**SURVIVABLE, NOT SOLVED.** The overshoot recovery lands the unit somewhere
real and replans, so this no longer loops -- it costs a wasted arc and a search
each time it happens. It only occurs where an arc touches a wall, which means
narrow shafts and chutes, which is exactly what players build.

**THE UNTRIED EXPERIMENT is `airJumpProfile.collisionCancelled : false`** in the
drone's `movementSettings`, which merge. The argument that it is free on the
controller side: `jumpHoldTime` is 0.0 and `jumpInitialPercentage` is 1.0, so
the jump is a single impulse with no hold phase and there is nothing for a
cancel to cancel -- which is presumably why the controller ignores it and the
planner does not. UNVERIFIED: the drone declares no `airJumpProfile` at all and
the inherited value in `default_actor_movement.config` has not been read.

Read the result off the `ARCPLAN VERDICT` line -- planner apex should rise to
meet physics apex. **Run it alone**, not stacked on a behavioural change.

### moveLand is still vanilla's, and it is four lines
`todo.pathing.moveland` -- see also `fact.pathing.arcmoverthrottle`

**PARTLY OVERTAKEN, NOT FIXED.** The arc mover now stops the unit on arrival, so
the specific failure that kept reaching this -- landing at flight speed and
sliding off -- no longer depends on `moveLand` getting a tick. The three defects
below are still in the function and still reachable by any path that arrives on
a Land edge without an arc in front of it.

    function PathMover:moveLand()
      if (onGround or (liquidMovement and abs(delta[2]) < 1)) and abs(delta[1]) < 1 then
        self:advancePath()
        mcontroller.controlApproachXVelocity(0, groundForce)
      end
      return "running"
    end

Horizontal-only acceptance test, no `else`. Three failures recorded: advances
after landing four tiles off vertically because x was close, onto an edge it
cannot execute; dead stops with no branch to walk toward the landing when x is
beyond 1; and never notices it has sailed past the landing in flight, because it
only checks once grounded.

**IT REPRODUCES. THE INSTRUCTION ABOVE HAS BEEN CARRIED OUT AND THE ANSWER IS
YES.** Measured repeatedly on platform terrain:

    stalled on Land edge 5 of 45: grounded and motionless at [3753.45,1026.8],
      edge source [3752,1023.8] srcDist 3.3342 -- replanning

**It is STILL not rewritten, and that is now a deliberate choice.** The
horizontal-only advance is worked around rather than fixed: the arc-landing
check refuses a plan whose next edge is unreachable, and `tryPlanDrop` descends
to the surface the plan wants, so `moveLand` is rarely reached in a state where
its blindness matters. Rewriting it is still the honest fix and is still
available; the shape is in the next paragraph. It was left alone because the
workarounds were verified and a mover rewrite on top of them would have been an
unmeasured change stacked on a working one.

Shape of the fix if needed: accept on distance in BOTH axes; walk toward the
target when grounded but short; and when landed far off in y, do NOT advance --
that is a broken path and should surface as one.

### The fallback pather in `approachPoint` binds only `moveSwim`
`todo.pathing.fallbackpather` -- see also `fact.pathing.smalljump`

    self.pather = self.pather or PathMover:new({run = running})
    ...
    if self.pather.moveSwim ~= petportsFreeMover then
      self.pather.moveSwim = petportsFreeMover
    end

`freshPather` binds `moveJump`, `moveWalk`, `moveArc`, `moveSwim`, `timedDrop`
and `keepDropping`. This fallback binds ONE of them. **A pather built here runs
VANILLA `moveJump`, which ignores `edge.jumpVelocity` and fires at full
strength.**

**IT BECAME LOAD-BEARING THE MOMENT `smallJumpMultiplier` LEFT 1.0.** While the
planner only ever drew 45s, a mover that always fires 45 agreed with it by
accident. Now the planner draws 22.5 edges, and vanilla's `moveJump` answering
one with a 45 launch is EXACTLY the failure the old pin was written to stop --
"the planner drew arcs for a 33.75 jump the unit answered with a 45 one".

**MEASURED SCOPE, because the reflex is to over-estimate it.** `approachPoint`
has four callers: two in `petportsTaskAction` and two in `petportsSleepAction`.
`freshPather` runs on entering ANY task state, INCLUDING leash, and `self.pather`
persists on the script table afterwards. So the fallback can only fire for a
unit that reaches `petportsSleepAction` before it has ever held a task -- a fresh
spawn that goes straight to rest. Narrow, real, and it will not announce itself:
the symptom is one overshooting jump on a newly placed pet.

The fix is to bind the full set, or better, to have the fallback call
`freshPather` so there is ONE place that knows what a pather needs. It was left
alone deliberately on 2026-08-28 so the multiplier change could be measured
without a second variable.

### The debug colour legend does not match the game
`todo.pathing.debugcolours` -- see also `proc.pathing.debugpath`

`DRAW_PLAN` uses vanilla's `debugPathEdgeColor` from `/scripts/pathing.lua`,
which maps:

    Walk blue   Jump green   Drop cyan   Swim white   Fly magenta
    Land yellow   Arc red (yellow at the apex, where target velocity y is 0)

**IN GAME, WHITE IS WALK AND MAGENTA IS JUMP.** Observed directly by the mod
author against a plan whose actions were independently known from the log.

Two possibilities and they are not equally comfortable:

1.  the colours do not render as named, which is cosmetic; or
2.  **the `pathing.lua` in `workbench/` is not the version the game runs**,
    which is not cosmetic at all -- a whole session's engine reasoning was read
    out of that file.

UNRESOLVED. Settle it by dumping a known plan's actions alongside a screenshot,
or by diffing the workbench copy against the game's unpacked assets. Until then,
**do not read edge ACTIONS off a screenshot** -- get them from the log or from
`/entityeval`, both of which are unambiguous.

### `petports_nodePosition` does not match `roundToNode` -- DELIBERATELY NOT FIXED
`todo.pathing.nodeformula` -- see also `ref.pathing.nodelattice`, `fact.pathing.ongroundtest`

Two known divergences from the engine, both understood, neither fixed, and that
is a decision rather than a backlog item that got missed.

**THE Y FORMULA.** `ceil` where the engine uses `round`; diverges for
`frac(y) in (0, 0.3)`, ours a tile high. Full derivation in
`ref.pathing.nodelattice`.

**THE PREDICATE.** `originIsPlannable` asks `validStandingPosition`, which is
not the engine's `onGround` -- five differences in `fact.pathing.ongroundtest`.

**WHY NOT NOW.** Nothing measurable is broken. A settled unit rests at
`frac 0.80`, outside the divergence window; it was 0.97% of grounded samples in
a clean log, all landing transients. Every difference makes the Lua stricter, so
both faults land as a wasted tick in a mechanism that already fails open. And
critically, **NOT ONE SAMPLE IN ANY LOG DISCRIMINATES THE TWO FORMULAS** -- every
measured `edge 1 src` sat at `frac 0.73` to `0.80`, where they agree. The C++ is
the only evidence, so a fix could not be verified by the change it produced.

**WHAT WOULD MAKE IT URGENT.** A chassis whose `boundBox` bottom is not -0.8; a
`petports_pathOptions` that pads `boundBox`, since `roundToNode` reads the
pathOptions box and not the controller's; ice underfoot, per difference 1;
`petports_flyPointNear` declining targets it should accept, since a shifted
anchor loses the bottom row of its window and its refusals are silent.

**HOW TO MEASURE IT WHEN THAT DAY COMES, FOR FREE.** The engine hands over its
own answer: `edges[1].source.position` on any acquired plan IS
`roundToNode(position)`. Log `petports_nodePosition` beside it and shout on
mismatch. No probing, no re-derivation, data already flowing through the log.

### Three overlapping recovery ladders
`todo.pathing.recoveryladders`

`RECALL_LIMIT` -> `STRANDED_LIMIT` -> `rehomeUnit`, on top of `TASK_DEADLINE` and
a four-tier `FAILURE_BACKOFF`. rehomeUnit is instant, free and always works.
Worse, `noteFailure` classifies strandedness by SUBSTRING-MATCHING the failure
reason text -- a structured outcome field costs nothing and cannot silently stop
matching when someone rewords a log line.

### Smaller ones
`todo.tooling.smaller`

- **Collect targets still bias upward** -- see the homeward section. Same one-line
  fix, not applied.
- **`pad = 0` in pathOptions is unverified for tight corridors.** The evidence for
  removing the padding was an open-air jump arc producing a byte-identical plan,
  which says nothing about a two-high tunnel where vanilla's padding does its job.
  If a corridor a player can walk stops being traversable, restore
  `math.min(0.7, halfWidth * 0.4)` and re-test.
- **`maxFScore` is 400.** Nodes above that cost are discarded, so a long enough
  route can empty the frontier and read as "exhausted" rather than "too far".
- Per-item `maxStack` is not enforced on cargo entry.
- `petports_ventLinked()` has no callers.
- `DIAG_FALLBACK` is false and drop collection works; the diagnostic task can go.
- `destination.position` in the vent publish is derivable from the destination
  vent's own `entry`. Minimum publish is `{ id, entry, exits }`. The catch:
  `petports_ventDestinations` returns wired vents outside the port's gather rect,
  which have no entry in the list.
- Vent residency scales with vent count -- each linked vent spawns a stagehand
  holding a 12-tile region resident forever, plus the port's.
- **The module refusal window loses the item.** The pane performs the swap
  locally, so a payload the port rejects is already out of the player's cursor.
  Both sides ask `root.itemHasTag` about the same item and cannot disagree, so
  reaching it needs an item's tags to change mid-session -- but the port now
  forces a repaint on refusal so the loss is at least VISIBLE rather than a
  phantom that survives until the pane closes.
- **The port switches have the same in-flight race as modules, without the
  teeth.** `portEnabled` and the four participation boxes are painted from the
  mirror every poll, so a toggle followed by a stale mirror flickers the box back
  and then forward within half a second. Self-correcting, no item involved, no
  token. Give them one if the flicker ever annoys.
- **Settings toggles are write-only and unmirrored.** `setCarried` and
  `setCrosshairs` hold whatever was last clicked and reset to their config
  defaults when the pane reopens. Nothing reads them yet, so nothing is wrong --
  but they need mirroring before they mean anything.
- **Group tooltips live on the 9px checkbox, not the label.** The four
  `group*Label` widgets stay `mouseTransparent`, so hovering the word does
  nothing. Dropping that flag on those four makes the label hoverable.
- Coverage is 64 now. **Area is what costs, so 32 -> 64 is 4x**, and `gatherVents`
  inflates by a further COVERAGE_SIZE per side -- 96x96 to 192x192. An existing
  residency stagehand keeps the size it was born with until its port respawns it,
  so re-place ports after changing it or work scanning and residency will
  disagree.

---

### The upcycler's slot order is duplicated in two files with nothing linking them
`todo.upcycler.slotorderdup`

    petports_upcycler.lua   SLOT_INPUT 0   SLOT_REAGENT 1          SLOT_OUTPUT 2
    petports_petport.lua    MACHINE_SLOT_INPUT 0   MACHINE_SLOT_REAGENT 1   MACHINE_SLOT_OUTPUT 2

THE REAGENT COPY IS NEW and the port now WRITES through it -- see
`arch.upcycler.reagentrouting`. Accepted deliberately as the simple
implementation; it doubles the surface of this duplication.

Reordered from input/output/reagent so the pane could draw them in pipeline
order. The port carries its own copies because it reads machine slots directly
when deciding fuel trips, and there is no shared header. **If a SLOT_ constant
moves, the MACHINE_SLOT_ copy has to move with it**, and the failure is a unit
hauling off whatever is in the reagent slot.

**CHANGING THE ORDER RENAMES WHAT IS ALREADY IN A PLACED MACHINE.** Contents do
not move; the meanings of the slots do. Nothing is destroyed and nothing is
wrongly consumed -- a treat is not a reagent, so it is refused -- but a machine
placed under the old numbering looks shuffled and behaves oddly until it is
emptied and re-placed. Seen in game.

### Two vent entry sites, only one hardened
`todo.vent.entrysites`

`petportsTaskAction` calls `petports_ventTravel` from two places -- "already
touching" and "walked to it via approachPoint". The fail-closed hardening went on
the FIRST only. The second, which is the ORDINARY case, still does
`local ok = pcall(...)`, discards the arrival position, does not blacklist a
refusing vent, does not verify the landing against the plan, and does not count
the hop against `MAX_REPEAT_HOPS`. Both are labelled in the log
(`[ENTRY SITE A]` / `[ENTRY SITE B]`).

### The upcycler is the last pane holding its own strings
`todo.pane.tooltipstrings` -- see also `arch.pane.stringtable`, `dd.upcycler.bakedindicators`

MOST OF THIS ENTRY IS CLOSED. Tooltip behaviour is verified across all four
panes, the upcycler's dead `createTooltip` is deleted, and three of four panes
are on the shared string table.

- **Migrate the upcycler onto the string table.** 14 literals still in its
  config: `Upcycler running`, `Pet feeder`, `Upcycle above this many`, `Add a
  rule`, `Keep at most`, `Click holding an item`, `How it works`, `Flavors`,
  `in`, `out`, `reagent`, `Select a flavor`, `Replace Me`, and the instructions
  paragraph. Plus its runtime status line.
- **`Replace Me` is a placeholder that must not ship.**

WHAT IS DELIBERATELY NOT ON THIS LIST ANY MORE: a tooltip on every checkbox.
Nineteen checkboxes exist; five have tips and the rest need none. The three
"enabled" boxes and the three tabs say what they do; "Pet feeder" is simple to
understand; "Accept everything" is simple enough as long as someone understands
that rules beat it. The upcycler's reagent box is answered by
`dd.upcycler.bakedindicators` instead.

`portNetworkLabel` still builds `"id: " .. network` in Lua rather than from a
format string. Left alone deliberately: it becomes a spinner when network
selection is built, and the string goes with it.

### Pane art, and the order it has to happen in
`todo.art.panes` -- see also `dd.upcycler.bakedindicators`

**NEXT SESSION:**

- **Deposit and restock beacons need top-left pane icons.** They have none.
- **Upcycler and petport need proper ones** to replace their placeholders.
- **The upcycler's reagent indicator** -- the drawn line from the checkbox
  column to the reagent slot that replaces a tooltip. Open question: static art
  baked into the pane background, or a widget that only draws when at least one
  rule is ticked. Static is trivial and always correct while neither end moves.

**DEFERRED UNTIL THE LAYOUTS ARE FINAL, AND THE ORDER IS THE POINT:**

- **The diagonal shine layer on all four backgrounds.** It has to be sized
  precisely to each pane, and the panes are going to be COMPRESSED once they are
  feature complete. Doing it first means doing it twice.
- **Slot targeting graphics** are effectively baked into the pane backgrounds,
  so they come after the same compression for the same reason.

### Sinker locomotion -- ground pathing that will not swim
`todo.locomotion.sinker` -- see also `dead.locomotion.pelagic`

Vanilla ground monsters walk into water and keep walking. Whether that is
reachable from this mod's setup is unknown; the pelagic attempt failed because
water is a closed node set for a GRAVITY-DISABLED actor, and a sinker is
gravity-enabled, so it is a different question rather than the same one answered.

### Names for the chassis
`todo.unit.names`

The four locomotion classes need real names rather than their class. "Axolotter"
for the amphibious one. This also settles what the monsterpart files are called --
see `status.port.inventory` on `drone_placeholder`, which is free to rename now and
expensive once there are several variants.

### Finish the petport pane
`todo.pane.statstab` -- see also `arch.pane.hoverlayer`, `arch.pane.statslist`

- **The Stats tab is BUILT** -- a list, striped, with placeholder separators;
  see `arch.pane.statslist`. What remains here is dressing
  (`todo.art.statsdressing`) and the per-treat block once eating exists.
- **Decide whether the unit's HP bar belongs in the pane at all.** A unit that
  cannot be hurt by anything the player builds may not need one.
- **Rename is still `not built`** behind its button on the Settings tab.

### Unit nameplates
`todo.unit.nameplate` -- see also `todo.unit.names`

Work out how names above monsters are driven and whether ours can carry one. Then
a "display unit name" checkbox on the pet Settings tab, ON by default, beside the
rename button -- the two belong together and neither means much without the other.

### Petport spawn choreography
`todo.port.choreography` -- see also `plan.art.capturepodfade`, `plan.art.doorchoreography`

A unit currently appears and disappears instantly. The fade is already specified
in `plan.art.capturepodfade` and the door in `plan.art.doorchoreography`; this is
the note that they are one job and want doing together, since both fire on the
same two events.

### Error state on the petport itself
`todo.port.errorindicator`

Weigh animationState components for error conditions against the cost of driving
them, and decide whether each port wants an indicator light. A player with twenty
ports should be able to see which one is unhappy without opening twenty panes --
the pane's diagnostic row already knows, it just cannot be seen from outside.

### Adversarial platforming for the new jump code
`todo.pathing.adversarialtest` -- see also `arch.pathing.solvelaunch`, `fact.pathing.eulertick`

`solveLaunch` and the arrival brake were verified against one session's logs and a
replay of every takeoff in them. That is not the same as a build designed to break
them. Specifically untested: a wall-clipped arc, where the plan is wrong at both
ends and a solver that faithfully flies it may fly it into the floor. See the
warning in `todo.pathing.jumpmodel`.

### Modules, design and liquids
`todo.module.designpass` -- see also `arch.module.effects`, `plan.module.investmentpath`

- **A design pass on what modules a pet can have.** One placeholder lamp exists;
  the investment path names slots but not contents.
- **Lava and poison immunity modules must also unblock those liquids in the
  pathing deny list.** The status effect alone makes a unit survive the liquid it
  still refuses to path through, which is the wrong half of the feature and the
  reason the lamp was built first.

### Maxwell
`todo.unit.maidrank`

A themed maid NPC who inspects a player's pets and awards maid ranks. He is called
Maxwell. Presenting a pet with a high Tidy Score earns a maid dress cosmetic.

Filed rather than dropped because it is the only thing so far that gives the Tidy
Score a consumer -- it is currently computed, displayed, and read by nothing.

### The upcycler must show it cannot burn
`todo.upcycler.cantburnlight` -- see also `arch.upcycler.burnbox`, `dd.upcycler.bakedindicators`

A status light in the art and animationStates for the state "the burn slot is
occupied but nothing can burn" -- whether because no rule names the item or
because the rule's burn box denies it. WHILE ENABLED, OCCUPIED, AND UNABLE TO
BURN, IT SHOULD BE BEEPING. The machine already knows the state -- the furnace
door logs it -- it just cannot be seen or heard from outside, and a machine
quietly not-burning is indistinguishable from a machine quietly done.

### The backoff ladder reorder is unexercised
`todo.port.backoffladder` -- see also `arch.port.reporthandler`

The fix is in and the patrol it caused is gone, but no arrival failure has
happened SINCE -- the closing log has zero backoff lines. On the next genuine
arrival failure, confirm the counts climb past 1 and the intervals escalate.
If they do, delete this entry.

### Distinct glyphs and real separator art
`todo.art.statsdressing`

Three placeholders from the metrics session, all flagged in code comments: the
burn and reagent checkboxes on an upcycler rule row are IDENTICAL vanilla
checkbox art with different meanings -- the exact misreading the beacon verb
art exists to prevent; the stats list separators are dull-orange dashed rules;
and the stripe fills `row_180_11.png` / `_alt.png` are generated uniform
fills, not designed art.

### The stall watchdog cannot tell "no progress" from "arrived, target moved"
`todo.pathing.arrivedstall`

MEASURED 2026-08-30, on the run that finally milked the cow:

    reporting failed for animal:100: no net progress -- moved 0 in 10s at
    [2530.5,1142.8] heading for [2530.5,1142.8] ... moved 43.8911

The unit walked 43.9 tiles, arrived exactly on its approach position, and was
failed for standing still. It self-corrected on re-dispatch and milked the cow
13.9 tiles later, so this costs a wasted dispatch rather than a task -- but it
reads in the log as a pathing failure and is not one.

Being within the arrival radius of your own approach position is success or a
re-resolve, never a stall. Cheap to separate and worth doing before it masks a
real stall.

### Farm animals move and nothing re-resolves the target
`todo.pathing.movingtarget` -- see also `todo.pathing.arrivedstall`

The approach position is resolved once and cached on `stateData.groundTarget`.
A crop does not move, a drop does not move, a farm animal wanders continuously --
so the cached point is stale before the unit arrives, and the only thing that
corrects it is failing the task and being re-dispatched.

It works, at the cost of one failed dispatch per wander. Re-resolving when the
tracked entity has moved more than some distance from the cached target is the
obvious shape, but it interacts with `arch.pathing.standablerank` caching and
with the probe results pushed to the port -- do not change one without reading
the other.

### Big obvious on/off lights on the pane
`todo.art.runninglights` -- see also `todo.pane.tooltipstrings`

DECORATIVE, and worth it because the switch is load-bearing in a way the
current checkbox does not carry. Adding a rule deliberately switches the
machine off (`sampleSlotClicked: machine was running, switching it off`) so a
half-built ruleset cannot eat something -- correct behaviour, but it means the
machine stops during ordinary editing and the only tell is a small checkbox the
player just clicked past. MEASURED 2026-08-30: a full test round was run
against a switched-off machine before the state was noticed.

Big, unmissable, and on the pane rather than the object -- object-side
indicator lights are a separate art pass. This is the same alert-surface
problem as the stranded-slot states, so build it with those in mind rather than
as a one-off widget.

### Drop the side-by-side toggle logging
`todo.upcycler.checkstatelog` -- see also `fact.pane.checkedpostoggle`

THE SEMANTIC QUESTION THIS ENTRY EXISTED FOR IS ANSWERED -- see
`fact.pane.checkedpostoggle`. Neither branch of the old hypothesis was the
fault; the toggles were broken for two unrelated reasons instead
(`fact.tooling.andnilor`, `arch.upcycler.burnbox`).

What is left is one line of cleanup. Both rule-row toggles still log the
widget's report beside the stored result, kept deliberately for one round to
confirm the two fixes. Once a log shows an untick storing an ABSENT field,
drop the widget half of the message; the rule is the authority and the second
reading has nothing left to settle.

### The rescue retry gate, if the churn ever matters
`todo.upcycler.rescuechurn` -- see also `arch.upcycler.shuttle`

A same-name stack the engine cannot merge (rot) makes the bulk rescue cycle a
take-and-return every few ticks until the charge drains the reagent slot.
Invisible in practice; if it ever shows in a log or profiler, gate re-attempts
on the reagent slot's count changing. Three lines, filed rather than done
because unmeasured cost does not buy code.

## PROCESS

### A correction filed against a decision does not correct the decision
`proc.pathing.supersede`

TWICE IN ONE SESSION, a fact entry recorded that a premise was false while the
decision resting on that premise stayed in force, unchanged, for weeks.

**`smallJumpMultiplier`.** `arch.pathing.overview` said, in bold, that it "is 1.0
and should stay" because the actor cannot perform a partial jump.
`fact.pathing.partialjump` later established that the setting cited governs the
jump CONTROL and `petportsJumpMover` does not use it -- and then said so and
stopped. The pin survived. Cost: every jump the mod ever planned was a
maximum-height launch, and a share of the mover defects catalogued here were
downstream of it.

**`petports_nodePosition`.** `ref.pathing.nodelattice` recorded the C++
`roundToNode` formula and, two paragraphs later, asserted the Lua "uses vanilla's
own formula". It used a different one. The correction and the wrong claim sat in
the SAME ENTRY.

**THE RULE.** When a fact entry falsifies the premise of a decision, EDIT THE
DECISION IN THE SAME PASS -- either change it, or write down why it stands
anyway. A fact filed beside an unchanged decision reads as agreement, and the
next reader will trust the bold sentence over the paragraph five sections away.

**WHERE TO LOOK.** `grep 'should stay'` and `grep 'do not change'` in this file,
then check each against the ENGINE FACTS section. Every superseded claim should
now name its successor tag inline, as the two above do.

### Reach for a CONTROL before a theory
`proc.tooling.controlfirst` -- see also `fact.pathing.floatingtarget`

MEASURED 2026-08-30, at the cost of most of a session.

An unreachable submerged cow produced four hypotheses and three written-and-
reverted fixes -- a target-node lift, a relaxed landing-velocity ceiling, and a
rejection that should have been a descent. Each was defensible, each was
instrumented, and each died to a single log.

What actually cracked it was dropping a pile of dirt beside the cow. The unit
collected it immediately. That one action killed terrain, descent, distance,
coverage and water simultaneously, and reduced the remaining question to
arithmetic between two numbers 0.16 apart.

**A CONTROL IS CHEAPER THAN INSTRUMENTATION AND FAR CHEAPER THAN A FIX.** When
something fails in one specific case, the first move is to construct the nearest
case that SUCCEEDS and diff them -- not to theorise about the failure. Ask what
the working version of this looks like, and make one.

### Read the source before theorising about the source
`proc.pathing.readsource`

THIS SESSION PRODUCED FIVE WRONG THEORIES ABOUT ENGINE BEHAVIOUR, AND
`StarPlatformerAStar.cpp` ANSWERED EVERY ONE OF THEM OUTRIGHT.

    "the search exhausts"                      -> neighbors() dispatches to
                                                  getFallingNeighbors, so it
                                                  plans an Arc. It succeeds.
    "crates are Dynamic" / "crates are Platform"
                                               -> two probes in the log settled
                                                  it and neither guess was needed
    "swimCost makes water attractive"          -> it is a MULTIPLIER; at 5 water
                                                  costs 5x a walk. Backwards.
    "smallJumpMultiplier is a minimum arc"     -> it is a second jump height
    "the planner thinks the unit can fly"      -> acceleration() reads
                                                  airBuoyancy, which is nil, so
                                                  gravity is 120 and never zero

The file is public, it is 540 lines, and it takes minutes to read. **A confident
claim about engine internals with no source or measurement behind it is a guess
wearing a fact's clothes**, and this session shipped several before the source
was opened.

Corollary, learned the same day: `/entityeval` gets structured state out of a
LIVE PAUSED WORLD with no code change and no rebuild -- the plan's edge list,
`mcontroller.baseParameters()`, a row of `world.material` probes. It answered in
three commands what a diagnostic build would have taken a session to answer.
Reach for it before writing instrumentation.

### What is written down for modders
`proc.filter.modders`

`workbench/SORTING_FOR_MODDERS.md`. Part 1 is the minimum — three fields, the
casing trap, and the fact that following vanilla conventions needs no
cooperation from us. Part 2 covers patching, all five matchers, `unclassified`,
and why exclusion storage means a subgroup you add is inside every existing rule
immediately.

### Order is stated in one table, and a literal has broken three times
`proc.filter.orderliteral`

Group order lives in an `ORDER` dict in the generator, in HUNDREDS. Tens ran out:
the `Furniture - Tagged` block needs forty consecutive numbers.

`PINNED` renders a group as `parent + 1` rather than as a literal, because a
literal has broken three times now — Filled Capture Pods was 81 when Pets was 80
and silently moved ABOVE Pets when a group was inserted earlier; `Unsorted` was
290 until forty tagged groups grew into it; and the same shape is what made
positional patch paths untenable. **A number that encodes a relationship has to
be computed.**

### `debugPath` PLOTS BODY-CENTRE POSITIONS, NOT SURFACES
`proc.pathing.debugpath`

Vanilla's overlay draws `edge.target.position` raw. Those are the unit's CENTRE,
so for a 1.6-tall body a node meaning "standing on this dirt" renders 0.8 tiles
above the dirt -- and with a platform a tile up, flush with its top. It reads as
a route drawn on the wrong surface and is not one.

The measurement that settles it: on-plan landings report a y gap of `0` or
`6.10352e-05`. A systematic one-tile offset would make every one of those read
`1.0`.

### REPORTED VELOCITY IS A FRICTION SAMPLING ARTIFACT -- READ POSITIONS
`proc.pathing.velocityartifact`

`mcontroller.velocity()` read from `approachPoint` returns a rigid
`flySpeed x (1 - airFriction/60)`. At `flySpeed` 12 and `airFriction` 24 that is
exactly 7.2, on every sample, to four decimals. Physics runs at 60Hz and takes
friction's cut each engine tick; the script runs every ~5 engine ticks and
happens to sample post-friction, pre-control, every time.

THE UNIT IS ACTUALLY TRAVELLING 12. Logged POSITIONS advance a full tile per
81ms. This is the pre/post-move measurement trap wearing a new hat, and it cost
a wrong theory before the positions settled it.

DISTINGUISHING A REAL LOSS FROM THE ARTIFACT: an aquatic unit reported 3.6 and
its positions confirmed 6.17 tiles/s -- a genuine halving, caused by
`liquidImpedance`, which `default_actor_movement.config` sets and which nothing
here had overridden. Zeroing it makes `flySpeed` mean what it says underwater.
Always check the positions.

### A PROGRESS SIGNAL BELOW A BRANCH THAT RETURNS IS A SIGNAL THAT DOES NOT EXIST
`proc.tooling.deadsignal`

The green "enroute" crosshair lagged by seconds and, on any vent route, never
appeared until the final leg. Three causes, stacked, and only the first is a bug.

**THE CHECK WAS UNREACHABLE FROM THE VENT PATH.** It lived inside the
once-a-second trace block near the bottom of `petportsTaskAction.update`, which
is reached only when the unit is on a direct approach and has not yet arrived.
Three paths return before it: the routing branch (correct to skip, nothing is
moving), the settle branch (correct, a drop is still falling) and the VENT-LEG
branch -- which is real, visible walking to a vent mouth that never counted. So
the marker stayed yellow through the approach, the hop, and every leg after it,
which is precisely the case the green marker was built for.

Fixed by pumping it from the TOP of `update`, above every branch.

**IT MEASURED ACCUMULATED PATH LENGTH, WHICH CANNOT BE SAMPLED FASTER.** A
running total adds every measured wobble, so it creeps upward while a unit
stands still -- slowly at one sample a second, five times faster at five.
Speeding the old test up would have traded a late green for a false one. It now
measures NET DISPLACEMENT from `stateData.startPosition`, which is a single
magnitude against a fixed point, does not creep, and can be taken as often as
wanted. `movedTotal` stays as it was: it is path length and still owns the
"never moved" versus "could not reach" split in the approach-timeout report,
which net displacement cannot answer.

Side effect, and it reads as correct: a vent hop displaces a unit far past the
threshold in one tick, so a routed unit goes green the moment it comes out the
far side.

**THE ANTI-STROBE DWELL WAS CHARGING FULL PRICE ON THE ONE TRANSITION THAT
CANNOT STROBE.** `CROSSHAIR_DWELL` exists for the dispatch-fail-backoff cycle,
which genuinely flaps. `routing -> enroute` cannot: `self.taskMoving` goes false
to true once per task and is cleared only on a new dispatch. And it was the
WORST case for the dwell rather than an incidental one, because a yellow marker
is spawned AT DISPATCH so its `since` is always fresh -- every other transition
happens on a marker that has been up a while. `CROSSHAIR_IMMEDIATE` exempts that
one pair.

**Generic form: an anti-flap timer must be exempted for transitions that are
monotonic within their scope.** Otherwise it taxes exactly the change a user is
watching for.

MEASURED after the fix, across 38 transitions in one session: every one landed
65-78ms after the unit reported moving, i.e. one tick. Before, the direct case
cost 1.5-3s and the vent case cost the whole journey.

### AN EARLY RETURN IN update() KEEPS COSTING THE SAME BUG
`proc.tooling.earlyreturn`

FOURTH INSTANCE NOW, and the fourth is the most expensive so far.

**`mirrorPaneState` WAS NEVER RUNNING ON AN EMPTY PORT.** The no-item branch
returns at line ~9355, inside `update()`; the mirror was called ~190 lines
below it. So an unsocket froze the pane permanently: it went on reading the blob
written while the unit was still socketed -- name, portrait, fuel, and a full
module set with clickable slots. That is the module duplication path, and it is
the prime suspect for `dead.cargo.unsocketloss` as well.

**THE COMMENT JUSTIFYING THE OLD POSITION WAS WRONG, AND WAS TRUSTED.** It said
the no-item return "sits inside workUpdate", so being above `workUpdate` was
sufficient. It is not in workUpdate. A whole timing theory was built on that
sentence, complete with arithmetic off `WORK_INTERVAL`; the arithmetic was fine
and the premise was fiction. **A COMMENT ABOUT CONTROL FLOW IS A CLAIM, NOT A
MEASUREMENT** -- check it against the line numbers before building on it.

Fixed by HOISTING rather than by duplicating the call into the no-item branch,
which is how claims and unit position were fixed the previous two times. A pane
needs telling on every path -- switched off, not a pet item, malformed item --
not just that one. Verified mechanically afterwards: two early returns in
`update()`, both below the mirror.

The consequence is that the mirror now runs BEFORE `self.petData` is cleared
later in the same tick, so it must not trust `petData` -- it asks the container
instead. That check was belt-and-braces when it was added and is load-bearing
now.


PREVIOUSLY: `consumeReagent` sat below `if not storedEnabled() then return end`, so an off
machine ignored its reagent slot entirely. That is not an edge case -- ADDING A
RULE SWITCHES THE MACHINE OFF, so the natural order (add rule, drop reagent in,
set threshold, switch on) put the reagent in during the one window where it was
ignored, with no log line and no warning.

Same shape as the replant sweep sitting below the petport's no-item return, and
as the crosshair progress signal sitting below the vent branch's return.

**THE TEST: for anything in update(), ask which returns are above it and whether
every one of them means "this genuinely should not run".** Housekeeping, state
publication and anything the player can trigger from a UI almost never belong
below a gate.

### AN ASSERT HAS TO CHECK THE SHAPE OF WHAT WAS WRITTEN, NOT THAT THE WORDS APPEAR
`proc.tooling.assertshape` -- see also `proc.tooling.halfedit`, `fact.tooling.nilglobal`

Twice in one session an edit was asserted and shipped broken anyway.

**A FUNCTION WENT IN WITH LITERAL `\t` SEQUENCES** instead of tabs, from a
Python escaping mistake. The assertion pass counted tokens -- every expected name
was present, so it passed. Token counts do not see indentation.
`petports_paneheck.py` caught it on block balance and three phantom calls.

**A NEW CALL SITE WAS CHECKED AGAINST THE WRONG CALLER.** `socketedItem` is a
`local function` defined 550 lines below a message handler that started calling
it. The position check was made against a DIFFERENT call site -- the one below
the definition, which passes -- and the new one was never checked. It threw
`attempt to call a nil value` on the first click. See `fact.tooling.nilglobal`, a
fact this file already carried and this file's own forward declarations already
demonstrate three times over.

**THE RULE: assert the property that would break, not the presence of the
change.** For a rename, count both old and new. For an insert, check every call
site rather than a call site. For anything with indentation, look at the bytes.

### An empty collection is not the same as a negative answer
`proc.tooling.emptyvsno`

`storageWouldTakeAny()` iterated the unit's cargo and returned false when there
was none — so an empty unit read as "storage will not take it". Every drop in
coverage triaged to the alarming marker instead of the quiet one.

Generic form: when a predicate loops over a collection to find a positive, decide
deliberately what the EMPTY collection means. It is rarely the same as "no".

### An undefined global is nil, so a half-applied edit ships
`proc.tooling.halfedit` -- see also `fact.tooling.nilglobal`

Cost two builds in one session, both the same shape.

A constant was renamed with three text replacements. ONE DID NOT MATCH -- a
comment sat between two lines of the search string -- and the surviving reference
became a nil global. Lua does not complain about reading an undefined global, so
the file loaded, the pane opened, and it threw inside `update()` on the first
frame that took that branch. The guard was `assert changed != original`, which
passes if ANY of three replacements lands.

**ASSERT EACH REPLACEMENT ON ITS OWN MATCH COUNT.** One assert over several edits
is not an assert.

**AND DO NOT EDIT LUA BY INDEX SLICING.** Removing a block by searching for its
closing `end` matched a two-tab `end` INSIDE a three-tab one, cut the wrong
terminator, and left an orphan that closed an `if` early and stranded its
`elseif`. `str_replace` fails loudly on a bad match; slicing silently takes
whatever the search lands on.

`petports_paneheck.py` now catches all three shapes -- undefined constants,
undefined calls, and block balance -- and balance is checked FIRST because it is
the only one that catches a file the engine cannot parse.

### Logging discipline, learned the hard way
`proc.tooling.logging`

Game startup with 200 mods is slow enough that a wasted test cycle costs more
than any amount of log volume. **Instrument first; do not reason from absence.**
Three rules, each of which cost a cycle before it was written down.

**LOG AT THE POINT OF DECISION, NOT VIA A RETURNED REASON.** `harvestWork`
computed a perfectly good explanation for declining and handed it to `findWork`,
which returned the DEPOSIT reason ahead of it. A port sitting beside nine ripe
crops and refusing to dispatch said nothing whatsoever about the crops. The
reason existed and never reached the log. Any function that decides not to act
logs that itself.

**LOG THE INPUTS, NOT JUST THE VERDICT.** "generated point outside rect"
identified neither the work nor the position nor the rect. It named a rejection
and nothing that would let anyone act on it. Every rejection now prints the
thing and the values it was measured against.

**CHANGE-GATE, DO NOT SUPPRESS.** A log-once hides a stuck state; a repeating
log buries everything else. The `reject` pattern -- repeat-suppress, then
re-state periodically -- reads as "still refusing" rather than "stopped
running". Use it anywhere the state can persist.

**WHAT IS SAFE TO SILENCE:** anything restating an unchanging fact. Vent node
wiring was ~45% of a 10,000-line log and re-stated identical topology every
refresh, so `VENT_DEBUG` is off and the port emits one change-gated summary
instead. That is the shape to reach for: not less information, the same
information once per change.

**WHAT IS NOT SAFE TO SILENCE:** anything on the path currently being built.
Live work stays verbose even when it is noisy, because the alternative is
guessing, and guessing costs a cycle.

### Terminology: petport, not pet station
`proc.tooling.naming`

"Pet station" collides with an existing vanilla crafting station by name, and it
describes the wrong thing anyway — the object is a spawner and deployment point,
not an appliance the player crafts at. Internally and in future asset names it
is a **petport** (after Factorio's roboport, which occupies the same conceptual
slot: a structure that houses, fuels and dispatches automation units).

Rename touchpoints, all of which must move together: the object's `objectName`,
the monstertype's `anchorName` (groundPet.lua kills the unit outright if these
do not match exactly), the `.object` / `.lua` / `.animation` filenames, and the
object's `scripts` reference. `objectName` is save-game identity, so this is
free now and expensive after anything is placed in a world.

### Pane pre-flight, and what each check has already cost
`proc.tooling.paneheck` -- see also `proc.tooling.halfedit`

`workbench/tools/petports_paneheck.py <pane.lua> <pane.config>`. Run before
delivering any pane. Every check exists because its absence cost a build:

    BLOCK BALANCE    an orphaned `end`; counted exactly (openers are
                     function/if/do, not for/while) so a clean file is 0
    UNDEFINED CONST  a half-applied rename -> nil global
    UNUSED CONST     the other half of the same rename
    UNDEFINED CALL   a helper copied from another pane and left behind
    CALLBACK WIRING  both directions; a missing one throws at CONSTRUCTION,
                     so the pane does not open at all
    UNKNOWN WIDGET   lua touching a name the config does not declare
    LUA 5.3 SYNTAX   \u{}, goto, integer division. Starbound is 5.1
    GEOMETRY         a widget outside the pane's usable band

`workbench/tools/petports_handoff.py` does the same job for this document: tag
uniqueness, closed topic vocabulary, section placement, and dangling
cross-references.

### Process note
`proc.tooling.session`

Several wrong diagnoses have shared one cause: **reasoning from a screenshot or a
partial log instead of asking for the specific line that would settle it.** Every
time a log was actually read, the answer was in it and was unambiguous.

Wrong theories that cost test cycles, recorded so they are not re-run:

- "held accumulates across the journey" -- disproved: `held` started from zero
  after a vent exit.
- "stale ghost units veto dispatch" -- disproved by a `0 deferred` tally.
- "`object.getOutputNodeIds` cannot be passed as a function value" -- disproved:
  probes ran.
- "the planner's apex is 0.75x because `smallJumpMultiplier` is 0.75" -- WRONG and
  instructive. An Arc edge's `dst` is a WAYPOINT, not the summit, and only the
  edge the unit is currently on is logged. Reading a waypoint as an apex produced
  a ratio that happened to look like the multiplier. **Do not derive an apex from
  a single edge.** (The multiplier was nonetheless wrong, for an unrelated
  reason found much later -- `fact.pathing.smalljump`. Being wrong about why a
  number is bad is not evidence the number is good.)
- "moveJump zeroing airFriction explains the overshoot" -- no: the default is
  already 0.0, so it is a no-op.
- "the padded standingBoundBox produces arcs that clip" -- no: `pad = 0` produced
  a byte-identical plan.
- "exhausted after 1 tick means no valid start position" -- no: exploreRate is
  300, so one tick is up to 300 nodes. It means the region is SMALL, which is a
  different problem with a different fix.
- "vent 90 cannot reach the items" -- never tested. The planner only expands a
  vent once it can REACH that vent, so a vent nothing can get to is never
  expanded and its distances are never measured. Absence of a probe is not a
  negative result.

**Wrong theories from the locomotion session**, same discipline:

- "the flyer never reports arrival because `PathMover:move` never returns true"
  -- WRONG. `approachPoint` ignores that return except to pick an animation
  state. The real blocker was `not onGround()` in the arrival gate.
- "`controlFly` takes the displacement as a speed, so the unit crawls near
  waypoints" -- disproved: commanded distance varied 0.45 to 1.24 while measured
  speed was a rigid 7.2. The engine normalises.
- "7.2 is a speed cap" -- no, it is `flySpeed x (1 - airFriction/60)` sampled
  post-friction. Positions showed the unit genuinely travelling 12.
- "A* cannot express a submerged-to-air transition for a gravity-disabled
  actor" -- UNRESOLVED and possibly wrong. Offered as an explanation for a
  frozen flyer; the plan-grouping heuristic used to test it could not tell one
  mixed plan from two consecutive ones, so the result was discarded rather than
  believed. Prevention made the question academic.

**A repeating pair of SUCCESSES is invisible to every failure mechanism.** Three
livelocks this session -- drain/deposit, restock/deposit, and the earlier
withdraw/deposit -- ran at up to 2.4 cycles per second with `done` on every
single line. The reject machinery cannot see them, the failure counters cannot
see them, and the log looks like a busy fleet. THE GENERAL RULE THEY ALL
VIOLATED: any generator whose DESTINATION differs from its SOURCE must validate
both. Checking only the source produces work that completes and accomplishes
nothing.

**A CORRECT FIX CAN MAKE A LATENT BUG LOOK NEW.** The drain livelock existed
before `petports_avoidLiquid` landed; the unit simply accepted the unreachable
machine and stood still for ten seconds per attempt, so the loop ran slowly
enough to pass for ordinary retrying. Making the refusal correct turned a slow
failure loop into a fast success loop and made it visible. Do not assume the
change that revealed a bug caused it.

**REPEAT-SUPPRESSION PLUS A CHATTY GENERATOR HIDES STARVATION.** A port picked
work it could never dispatch, rejected it, and never fell through to anything
else -- for 104 seconds. The reject printed ONCE, correctly, and then eighteen
seconds of `draining dirtmaterial x289, x294, x299` scrolled past looking like a
port hard at work. The reject pattern behaved exactly as designed and still hid
a total starvation.

**BULK TEXT REPLACEMENT DELETES THINGS SILENTLY.** Rewriting a block of
`petports_contract.lua` removed `petports_freeMover` and `petports_avoidLiquid`
-- called from eleven sites across four files -- and a follow-up replace that
matched nothing dropped a third function. Nothing errored until runtime. There
is now a mechanical check (`workbench/tools/`, described below) for two things
that had both already caused crashes: a `local function` called above its
definition, and any `petports_*` call with no definition anywhere in the mod.
Run it before delivering Lua.

**Measurement traps.** The per-tick `post-move` line runs AFTER approachPoint, so
the state a mover saw on a given tick is the PREVIOUS line's end state -- that
alone made an `srcDist` of 0.52 look like a takeoff that should have happened. The
`pre-move` line exists to bracket it. And the registry removal paths were unlogged
for a long time, forcing a diagnosis by elimination that should have been one
grep.

**A recovery that produces motion can be worse than no recovery.** The stall
detector reads displacement as health, so a unit pacing a quarter tile looked
livelier than one wedged solid and was permanently stuck.

**Suspect the cache before the geometry** after any terrain edit. See the TTL
section.

Ask for the log first. It has been faster every single time.

### Four ways to build a silent stall, all of them mine
`proc.tooling.silentstall`

Recorded together because they share a shape: **every task succeeded, nothing
errored, and the log looked healthy while the system did nothing useful.** That
is the failure mode this codebase actually produces, far more than crashes.

**1. An insertion anchored on the wrong line.** The replant branch was written
into `findWork` above `collectionWork()` instead of above `depositWork()` --
while the comment directly above it said "REPLANT SITS ABOVE DEPOSIT". Deposit
fires on ANY cargo, so a unit that picked up a seed carried it straight back to
a crate. The observable behaviour was a unit withdrawing a seed and depositing
it again roughly three times a second, indefinitely, with every individual task
reporting done.

**LESSON: when an ordering IS the feature, assert the ordering.** A comment
claiming position is not position.

**2. A precondition that outlived its reason.** `withdrawWork` opened by
refusing any cargo at all. That deadlocked precisely the case it most needed to
survive -- storage full, unit holding a stack nothing will accept, deposit
unable to place it -- because a unit can then never put anything down, and the
blanket refusal stopped replanting too. Bare tilled ground, seeds in a crate,
and a system that had stopped. Nothing about a full crate should stop a seed
going into the ground.

Now it refuses only if the unit already holds a seed an intent wants.

**3. A shared state key.** A change-gated vent summary was added that wrote
`self.ventSignature` -- which `refreshNetwork` already owned. Each overwrote the
other, so BOTH change-gates fired on every call. The visible symptom was one
extra log line per second. The invisible one was `unitChanged` going true with
it, so the port pushed rects and vents to its unit every tick instead of on
change.

**LESSON: a new `self.<name>` is a namespace claim.** Grep before taking one.

**4. A shape generalised from one sample.** See the crop footprint above:
1 wide by 2 tall, read off `potatoseed`, wrong for every wide crop and quiet in
both directions.

