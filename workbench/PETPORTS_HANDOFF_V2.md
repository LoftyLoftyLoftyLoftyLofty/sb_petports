# PETPORTS -- handoff v2

`lofty_petports`. A deployable spawner ("petport") that houses a utility unit,
plus the unit behaviour that makes one worth having. Split out of the Nicemice
mod on 2025-08-19, before any public release, so that object and monster
identity names were still free to change.

**PETPORTS IS STANDALONE, AND THAT CHANGED ON 2026-09-01.** The v1 framing put
the content layer in Nicemice -- unit types, chassis variants and the
encounter/quest loop that unit items drop from -- with this mod as the machinery.
It no longer holds. Petports ships its own species, its own acquisition and its
own release, because the machinery is too useful to gate behind a race mod.

Nicemice T6+ ships use petports as a replacement for the vanilla ship pet system,
and Nicemice ships an update alongside carrying its OWN themed units. Those are
not on this list and do not belong on it. **A DESIGN THAT ONLY MAKES SENSE FOR A
SHORTSTACK SPACE MOUSE IS A NICEMICE ENTRY; EVERYTHING ELSE IS OURS.**

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

### What is built, as of 2026-09-03 (one pond, every lure, and fewer of them)
`status.port.inventory`

REWRITTEN WHOLESALE EVERY SESSION. Never edited, never appended to. If a claim
here disagrees with anything below, this is right and that is stale.

ONE FEATURE, THREE RUNS, AND THE SECOND AND THIRD ARE WHERE THE VALUE IS.

---

**A FISH BELONGS TO THE NETWORK NOW, NOT TO THE LURE THAT SPAWNED IT.**
`arch.fishing.network`. `fishWork` read `self.fishId` and nothing else, so a unit
could only be sent at a fish its OWN port's lure reported -- two ports on one
pond ignored each other's catchable fish.

**IT WAS A MISSING VIEW, NOT A MISSING CAPABILITY.** The lure was ALREADY placed
across `fishingRects()` and already clamped its patrol to the whole network, so
the fish was network-wide in POSITION and port-local only in OWNERSHIP. The last
generator that had never had the `arch.dispatch.union` treatment.

`petports_fish` is a world property keyed by port. A property and not a message,
because no port ever messages another; and not in the REGISTRY, because every
registry write bumps a version that re-derives every network on the planet.
Withdrawn at `uninit` and NOT at `die()` -- the opposite of the registry entry
four lines away, because a fish entry names an entity id.

---

**RUN 1 FOUND A DISPATCH THE UNIT WAS GUARANTEED TO REFUSE.**
`todo.fishing.outofcover`. The unit bails a fish task the moment the fish leaves
network coverage, checked EVERY TICK; the port never checked once. 6 of 24
dispatches, every one failing at `moved 0` inside 200ms. **Not a regression** --
both halves shipped together in `fishing ix part 2` and the committed `fishWork`
had no rect test at all. Fixed; `fishWork` walks `fishingRects()` before ranking.

**RUN 2 CONFIRMED IT AND FOUND THE REAL PROBLEM.**

    dispatches   24 -> 54      catches   14 -> 48
    success     58% -> 89%     out-of-coverage dispatches   6 -> 0

Zero coverage bails. Cross-port is half of all dispatches. The 4 remaining
failures are `fact.fishing.despawnwindow` at an unchanged rate, accepted under
`dd.fishing.catchwindow`.

**RUN 3 IS WHERE THE SESSION EARNED ITS KEEP, AND IT WAS NOT MY CATCH.**
Upcyclers filled and were never emptied. I diagnosed it twice and was wrong
twice -- first as a filter fault, from a log message that could not say which of
two things it meant. **A control test settled it: two more units, and the work
got done.** See `fact.tooling.mergedrefusal` for the reading failure, which is
the durable half.

**THE MECHANISM.** `dd.fishing.supply`. Fish ranks high because its target
EXPIRES; upcycler output ranks low because a treat waits forever. Both correct
per task. Under saturation the ranking stops being a preference and becomes a
permanent exclusion. Network-wide fish multiplied the fish visible per port by
the number of lures on the water and **moved the saturation point without anyone
deciding to move it.**

**THE LADDER IS NOT THE THING TO CHANGE.** Ranking an expiring target above a
waiting one is right; the alternative is dropping catches. The supply was wrong,
not the ordering.

  - `spawnTimeRange` `[4, 12]` -> `[8, 24]`, a quarter of vanilla's.
  - `FISHING_LURE_LIFETIME` `150` -> `{ 120, 300 }`, drawn per lure. A flat
    lifetime made every lure in a base die and respawn IN THE SAME SECOND, and
    the replacement kept the phase, so the alignment never decayed. Its **max**
    is what the fish entry's TTL reads, and it must be the max.
  - `drainWork`'s refusal now names WHICH test failed. "No beacon's filter
    accepts this" and "every crate that accepts it is full" want opposite
    responses from the player and were one string.

---

**KNOWN IMPERFECT, AND DELIBERATELY LEFT:**

- **THE RETUNE IS UNMEASURED.** The three run-3 changes have not been run. What
  to watch: whether `drain` and `tidy` get dispatched with a two-unit fleet, and
  whether lure placements scatter in the log instead of arriving together.
- **THE MODULE STILL GATES CATCHING**, so network-wide fish bites only when two
  or more ports carry modules. One line removes it and lets any submersible unit
  fish off a single module -- a balance change, not a dispatch change.
- **A RESTOCK REQUEST IS NOT A REASON TO EMPTY A MACHINE.** `drainWork` builds
  its destinations from `petports_beaconsFor("deposit")` only. A base with two
  restock beacons asking for all eight treat flavors still refuses to drain
  treats if no DEPOSIT beacon takes them. Not filed as a todo -- it never
  triggered, and the observed fault was throughput.
- **THE CROSSHAIR SYSTEM HAS NO ARCHITECTURE ENTRY.** Found by chasing a
  reference. Second such gap found that way rather than by any check.
- **A UNIT CAN STILL BE DISPATCHED INTO MAGMA.** `todo.fishing.medium`.
  Pre-existing; one `targetSuits` call.
- **BACKOFF IS PORT-LOCAL**, so a fish that beat one port starts every other at
  failure 1. `todo.fishing.backoffshared`, out of scope for 1.0.
- **TWO PAIRS OF NUMBERS MUST AGREE AND NOTHING ENFORCES EITHER.**
  `PANE_FUEL_MAX` against `petports_fuel.maxValue`, `MUNCH_LOW` against
  `PETPORTS_FUEL_LOW`. Wants a linter check rather than a third comment.
- **`petports_petport.lua` IS AT 159 CHUNK-LEVEL LOCALS AGAINST LUA 5.1'S 200.**
  This session added none: the new shared functions are prefixed globals, the
  coverage predicate is nested inside `fishWork`, and `FISHING_LURE_LIFETIME` is
  a global. The failure when it lands is at load.
- **The feed slot is invisible**, a 16x16 hitbox on bare background at
  `[240, 116]` on the Details tab.
- **The trap age lock is detected, not fixed.** `todo.farming.trapagelock`.
- **`petports_amphibious.monstertype` has mixed line endings**, and
  `todo.tooling.crlfdrift` still undercounts.
- **`petports_petBehavior.lua` has never had a build stamp.**
- **`PETPORTS_DIVE_DEBUG`, `FLY_POINT_DEBUG`, `PETPORTS_DRAW_DEBUG`,
  `TASK_DEBUG` and `THINK_DEBUG` are all still on.** Turn them off before
  shipping.

**NEXT.** Run the retune. Then medic dispatch across whole-network coverage
(`todo.dispatch` carry-forward, named the priority three sessions running and
still not touched), the flying-unit partially-submerged check, and the
`coverageRect()` vs `self.networkRects` grep across every generator -- still not
done, and this session is the second reminder of it.

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

### Harvestable traps -- BUILT AND VERIFIED
`arch.farming.traps` -- see also `fact.farming.harvestable`, `dead.farming.trapinteractive`, `todo.farming.trapagelock`, `dead.farming.probe`

Moth traps and their modded cousins. Built 2026-09-03 and confirmed in game the
same session: `traps: 1 found, 1 ripe -- mothtrap#35 age 4002 of 190 RIPE`,
followed by a dispatch and a harvest.

**A TRAP IS NOT A CROP AND SHARES NO CODE WITH ONE.** `arch.farming.animals`
made the same split for livestock and this is the third kind. A farmable is a
`FarmableObject` running no script; a trap is a plain `Object` running
`/objects/scripts/harvestable.lua`. Discovery, ripeness, the act and the
verification are all different, which is why it got its own class rather than
being folded into harvesting.

**THE FIFTH FARMING CLASS.** `FARMING_CLASSES` gains `traps`, which plumbs the
`petports_setFarming` handler, the pane row and the opt-out reason list with no
other edit. Player-facing label "Moth Traps, etc." -- vanilla ships exactly one
member and the modded population is the reason the box exists.

**DISCOVERY RIDES THE EXISTING FARMABLE SWEEP.** `scanFarmables` already queries
every object in the network rects, so the trap branch hangs off the ELSE of its
`world.farmableStage` test. That is deliberate: `HARVEST_INTERVAL` already
records the second full object sweep as an unpaid cost and a third would be
worse. It also means the crop path is untouched -- a trap cannot change what
that function decides about any crop.

**CLASSIFICATION IS BEHAVIOURAL AND STATIC.** "Has `stages`, the last of which
carries a `harvestPool`" -- two `getObjectParameter` reads and no call into the
object's script at all. Keying on the SCRIPT PATH would catch the one vanilla
member and miss every modded object shipping its own copy at its own path.
Memoised per object NAME, which is `dead.farming.probe`'s rule about asking the
type rather than the entity, and without it this walks every crate and lamp in
coverage on every sweep.

**RIPENESS IS A THRESHOLD ON `activeAge()`, AND THAT IS A CONSEQUENCE OF
`dead.farming.trapinteractive`.** `setStage` maintains an exact ripeness bit via
`object.setInteractive`, and retail cannot read it. `activeAge` is what is left:
a pure function that mutates nothing and reads only values `init()` sets before
the one call in that script able to throw.

**THE THRESHOLD IS THE SUM OF THE DURATION UPPER BOUNDS.** The per-object rolls
live in the trap's own `storage` and cannot be read, so the upper-bound sum is
the only threshold that can never claim ripe EARLY. For a moth trap that is 190
against an earliest-possible 170. The measured age was 4002, which settles that
the lateness costs nothing: nothing in `harvestable.lua` advances past the
harvest stage, so a ripe trap stays ripe and the age simply accumulates.

**THE ACT IS AN INTERACTION AND MUST NEVER BE A SWING.** `world.damageTiles` on
a plain object is ordinary object damage -- there is no
`FarmableObject::damageTiles` to intercept it -- and `harvestable.lua`'s `die()`
calls `dropHarvest`. So a swing breaks the trap into an item AND spills its
produce, which reads as a clean success in every line we would log about it.
The player's trap is gone and nothing says so. This is the single most important
sentence in the entry.

`world.callScriptedEntity(id, "dropHarvest")` instead, which is
`arch.farming.animals` exactly: it spawns the treasure and resets the object's
own age in the same function, so we never touch the timer and cannot corrupt it.
It is also SAFE WHEN WRONG -- it guards on `self.stage.harvestPool` and returns
-- so a false positive costs a wasted visit where the crop swing's false
positive damages the crop.

**VERIFICATION SETTLES IN ONE TICK, unlike the crop.** `dropHarvest` calls
`setStage` synchronously before returning, so `activeAge` has already collapsed
to roughly zero by the next line. No `swung` flag and no verify timer.

**NO REPLANT INTENT, which is the one place the report handler diverges from the
crop one.** `arch.farming.intents` writes an intent when `world.entityExists`
comes back false on a harvested crop. A trap resets in place and never stops
existing, so there is nothing to distinguish -- a trap is always the reset case.

**FINDWORK: below harvest and animals.** All three are non-perishable, so the
ordering among them is precedence rather than urgency, and traps are newest.

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

**WHY THE OTTER NEEDED NOTHING -- SUPERSEDED 2026-09-02 BY
`dd.locomotion.otterswitch` AND `arch.locomotion.swimmode`.** The capstone was
specified as runtime `gravityEnabled` toggling with a mode chosen per
destination, and this entry said the engine's search already modelled the
boundary so none was needed. That holds for walking a seabed and does NOT hold
for a fish, which is never on the floor. The toggle was built.

**THE PRESCRIPTION BELOW WAS ALSO WRONG AND IS KEPT AS A WARNING.** It said the
toggle must land in BASE parameters via `applyParameters`. There is no
`applyParameters` on an ActorMovementController -- see
`fact.unit.movementparams` -- and a `controlParameters` override is invisible to
`baseParameters()`, so no write can make that accessor agree. What was true is
the reasoning about `PathFinder:start` and `canPathfind` reading it directly;
`fact.pathing.canpathfind` records how that was worked around, by shadowing both
on the pather instance rather than by changing what the accessor says.

`mustEndOnGround` is captured once at `PathMover:new`, which `freshPather`
rebuilds per task. That remains the constraint, and it is why the mode is chosen
at `freshPather` and nowhere else.

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

**BUILT 2026-08-30 -- see `arch.module.liquids`.** Poison block and lava block
both ship. The prediction recorded here was half right and the half it got wrong
is worth keeping.

RIGHT: the grant lives on the ITEM, via a module on `petData`, because that is
the only thing surviving despawn, unsocket and world reload.

WRONG: "the resolved set is chassis defaults merged with item grants, cached
alongside `petports_media()`" put the merge on the UNIT. It could not go there.
The petport has to answer the same question with no unit in the world, because
its habitat gate decides whether to spawn one at all -- so the PORT resolves the
set and pushes it, and the unit consumes what it is given.

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

**AN ENTRY'S `id` IS THE NETWORK ID, NOT THE PORT'S, AND THAT MISTAKE RETURNS A
NUMBER RATHER THAN A nil.** It is the pinned value two non-participating ports
must share to be connected, and it is `0` on every port that never touched the
setting -- so a lookup keyed on it in a table keyed by port silently finds
nothing on every port at once, which reads as "the feature does not work" rather
than as a wrong key. `petports_networkMembers` returns ENTRIES and drops the ids
it sorted by; `petports_networkMemberIds` was added beside it for callers that
need the key, and the flood fill was extracted into a shared local so the pair
cannot diverge. It takes the map it already has rather than calling its sibling,
because `anotherUnitIsCloser` calls it once per candidate and a second fill per
call would be paid in the innermost loop in dispatch.

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
`arch.pathing.originnudge` -- see also `fact.pathing.originnode`, `fact.pathing.ongroundtest`, `dd.pathing.nodeformula`

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

### Spawn and despawn are choreographed, and the door gates the spawn
`arch.port.choreography` -- see also `fact.unit.spawnrender`, `todo.art.invisibleframe`

BUILT 2026-08-30, GRADUATED FROM PLAN 2026-08-31. Replaces two plan entries,
plan.art.capturepodfade and plan.art.doorchoreography (both retired), which
described this as intent. It shipped whole -- the fade, the door gating, and the
ordering between them -- so the intent entries were removed rather than left to
read as outstanding work.

**THE COMPLETION SIGNAL IS A POLL, NOT A TIMER.** The plan named this as the one
unsolved piece: `opening` and `closing` are `"mode" : "transition"` with a
`transition` target, so the animator advances itself and tells nobody. Both
options were on the table and the timed one was rejected for the reason the plan
gave -- a hardcoded duration goes stale the moment the frame count or
`animationCycle` is retuned. The spawn block tests the TERMINAL state instead:

    if animator.animationState("hullState") ~= "open" then
      self.spawnTimer = DOOR_POLL

**A PORT WHOSE DOOR NEVER REACHES `open` NEVER SPAWNS, AND THAT IS CORRECT** --
that is a port that is closed. The environment gate rides the same fact: an
unsuitable port's hull never opens, so the spawn branch below is unreachable
while the verdict stands rather than being separately guarded.

**`DOOR_POLL` IS 0.0 AND IS NOT `RESPAWN_GRACE`.** They answer different
questions. RESPAWN_GRACE is a backoff against a port that cannot spawn retrying
in a tight loop; a door still moving is not a failure and needs no backoff, only
a wait of known short duration. Sharing the grace was MEASURED AS A PALPABLE
DELAY -- a ten-frame transition finishes somewhere inside the window and the
remainder is dead time, so the hatch visibly opened and then the port sat there.
Polling every tick is affordable only because the door test is the FIRST thing in
the block, so a not-yet-open door costs one string compare.

**THE THREE STATE TYPES MOVE TOGETHER.** `setAnimationStateForAllHullComponents`
drives `hullState`, `doorState` and `interiorState` from one call; `hullState` is
the one the spawn gate reads.

**THE DESPAWN SIDE WAS THE DELICATE HALF AND IT RESOLVED INTO A HOLD.** The hull
is held open by `unitPresent` while a retired unit fades, so the door outlives
the unit going away. That window is also why the spawn branch still tests
`self.envUnsuitable`: `self.petId` is already nil while the fade runs, so a port
whose terrain just retired a unit would otherwise deploy a replacement into it.

**THE FADE ITSELF IS `fact.unit.spawnrender`** -- three attempts, and the
finding that `animator.setAnimationState` is the only thing reachable from a
monster's init that is guaranteed in place before a frame is drawn. That entry
is the technical record and is not repeated here.

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

**THE `plannedVx ~= 0` GUARD ON THE REACH CLAMP WAS REMOVED 2026-09-01, AND ITS
REMOVAL IS A FIX RATHER THAN A TIDY-UP.** The clamp read

    if plannedVx ~= 0 and math.abs(vx) > math.abs(plannedVx) then

so it skipped the one case where the plan asked for ZERO horizontal reach at
launch, and branch 2's `vx = dx / time` ran free. **"NEVER MORE HORIZONTAL REACH
THAN PLANNED" WAS FALSE IN EXACTLY THE CASE IT MATTERED**, and the comment
claiming it had been sitting three lines above the guard that broke it.

**WHY IT MATTERED IS GEOMETRY, NOT ARITHMETIC.** A* plans a vertical launch
precisely when something is in the way: it rises in a clear column to above the
obstruction and THEN moves sideways. Turning that into a parabola sends the unit
diagonally from the first tick, through the obstruction the column existed to
avoid. Measured, four identical laps, then fixed and re-measured clean:

    before   plan [0,31.82] -> [2.29436,34.3286]   swept path BLOCKED at
             [2532.23,1141.53], sample 6 of 20, still rising, 1.25 tiles
             below a lip the plan cleared by a full tile
    after    plan [0,31.82] -> [0,34.3286]         swept path clear

vy IS STILL SOLVED and that half was always right -- 34.33 for a plan apex of
1143.8, reaching 1143.996. Only the invented horizontal is gone, and the
horizontal now comes from the plan's own schedule via `arch.pathing.climbsteer`.
**THE TWO ARE ONE CHANGE**: a vertical launch never given horizontal velocity
rises and falls in its own column forever.

**BRANCH 1 CAN FLY WELL ABOVE THE PLAN'S OWN APEX, AND THIS ENTRY USED TO DENY
IT.** The claim was "this exceeds the plan's own apex by at most
`JUMP_ARC_CLEARANCE`, and only in the pathological case". That is true of branch
2, which PINS the apex. Branch 1 pins nothing -- it fixes arrival time from the
planner's vx and solves whatever vy that demands. Measured on the death course:

    launch kept vx: plan [-8,45] -> [-8,54.9286], landing [2520,1177.8] (dx -7 dy 3),
                    apex 13.0292 vs plan 8.9469

A three-tile rise flown four tiles higher than the planner drew. The only ceiling
is `JUMP_VELOCITY_CAP` at 1.25x the planned velocity, which is 1.5625x the rise.

NOT CHANGED, DELIBERATELY. The extra height is what buys a descending arrival at
the planner's own horizontal reach, and every alternative is worse: capping the
rise reintroduces the ascending-crossing arrival this function exists to remove,
and lowering vx instead is branch 2, which is already what happens when branch 1
cannot solve. Recorded because A CEILING WILL FIND THIS -- the unit passes
through space the planner validated for a lower arc, per
`fact.pathing.plannervxdrop`. If units start wedging into tunnel roofs, read this
line first.

**SOLVED ON THE DISCRETE TRAJECTORY**, per `fact.pathing.eulertick`. The first
version solved the continuous parabola exactly and the unit still arrived half a
tile high and clipped the ledge.

**THE ARC MOVER HAS TO BE TOLD**, twice over. It steers toward the arc edge's own
velocity, so a lowered launch is pushed straight back up to the planned value on
the first airborne tick unless it is handed the launched value. And it stops the
unit on arrival rather than flying it off the landing, per
`fact.pathing.arcmoverthrottle`.

**THE HANDOVER WAS ONCE GATED ON THE PLANNED VELOCITY MATCHING, AND THAT WAS
WRONG.** SUPERSEDED 2026-08-30: the launched velocity now holds for the whole
arc, with the record's LIFETIME carrying the ownership guarantee the comparison
used to be asked for. The old gate silently lapsed on any edge where A* had
changed its own vx, which is nearly every arc -- see `fact.pathing.plannervxdrop`
for the frequency and `fact.pathing.arcmoverthrottle` for what it cost.

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

### A module has two channels, and a liquid permission cannot use the first
`arch.module.liquids` -- see also `arch.module.effects`, `arch.locomotion.liquidpermissions`, `dd.port.envpresence`

    petports_moduleEffects   pushed to a LIVE unit as status effects
    petports_moduleLiquids   read off the ITEM by the port, with no unit

**THE SECOND FIELD EXISTS BECAUSE THE FIRST CANNOT ANSWER IN TIME.** "Poison
immunity" is two different things wearing one name. Surviving poison is a
property of a unit that exists, and a status effect carries it. Being ALLOWED
into poison is a property the PORT has to know BEFORE it opens its door -- the
habitat gate refuses to deploy a chassis into a liquid its monstertype avoids,
and it decides that with no entity in the world. A permission living in a status
effect would grant immunity to a unit that was never spawned.

**SUBTRACTIVE ONLY, ON BOTH SIDES.** A module removes entries from the chassis
avoid list and can never add one. So a malformed or hostile module can widen
where a unit will go and can never strand one by forbidding the water it lives
in.

**THE PERMISSION SET RIDES THE EXISTING PUSH** rather than getting a call of its
own, and `pushModuleEffects`'s signature covers both sets. That gives one
computation for two consumers -- the port needs it for its own gate, the unit for
pathing and target selection -- and it makes cache invalidation free. The arrival
of `petports_setModuleEffects` IS the change event; there is no other hook that
fires on a module swap.

**TWO CACHES MUST CLEAR ON RECEIPT AND ONE IS EASY TO MISS.**
`petportsAvoidLiquids` is the set. `petportsLiquidVerdict` is a memo of per-id
ANSWERS derived from it, so leaving it would keep returning "denied" for poison
from a set that no longer contains poison. The symptom is a unit that survives a
liquid perfectly well and refuses to path in it -- which is why swim pathing
inside corelava was the test that proved this, not survival.

**THE TYPE CAPABILITY CACHE IS SPLIT FOR THE SAME REASON.** The
`root.monsterParameters` read stays cached per type; the module overlay is
recomputed per call. A combined cache keyed on type alone would hand two units of
one chassis with different modules whichever answer was computed first, and the
symptom is a module that does nothing until it is re-socketed.

**REACH DIFFERS BY MODULE AND IS NOT OBVIOUS.** The permission half only matters
for the aquatic and amphibious chassis; the flyer and drone declare no avoid list
because `canSwim` false already refuses all liquid, and subtracting from an empty
set subtracts nothing. The IMMUNITY half of poison block matters for all four,
because toxic rain arrives through the weather path. Lava block's does not --
lava is only ever a liquid.

### A module that changes a number, and the accessor that keeps two legs honest
`arch.module.hydrator` -- see also `arch.module.effects`, `arch.farming.sweep`, `arch.dispatch.twolegs`, `todo.module.hydratordeadline`

**BUILT 2026-09-01.** The Hydrator raises a unit's water capacity from
`WATER_CARRY` 10 to `WATER_CARRY_HYDRATED` 30. It is the first module that
changes a MAGNITUDE rather than adding a behaviour, removing one, or widening
where a unit may go.

**IT NEEDED NO NEW CHANNEL AND NO UNIT-SIDE CODE.** Capacity is a DISPATCH
property: the port decides how long a run to hand over and how much liquid to
send the unit to fetch. The unit sweeps whatever list it is given and has no
opinion about its length, so `petports_moduleFlags` carries it, nothing is
pushed, and there is no status effect to author. Second module after medic with
no `petports_moduleEffects` at all.

**THE MAGNITUDE LIVES IN THE PORT, NOT ON THE ITEM.** A module declaring its own
number would force the port to decide what two of them meant, and would split one
economy decision across two files. The flag says WHICH ceiling; the port owns
what the ceiling is.

**BOTH LEGS READ ONE ACCESSOR, AND THAT IS THE ONLY LOAD-BEARING PART.**
`waterWork` sizes the sweep and `withdrawWaterWork` sizes the fetch. They are
separate generators that happened to share a constant, so a module that moved one
and not the other sends a unit to a crate for thirty and has it put ten down --
`arch.dispatch.twolegs` in miniature. `petportWaterCarry()` exists so there is
only one place to ask.

**TWO HYDRATORS ARE ONE HYDRATOR**, free, because `moduleFieldUnion`
deduplicates. Same honest outcome two lamp modules get.

**SUPERSEDED 2026-09-03 BY `dd.module.oneofakind`.** A second module of the same
item is now REFUSED at the slot rather than absorbed, so the sentence above
describes a state a player can no longer reach through the pane. It is left
standing because the union still deduplicates and still has to: that rule guards
the socket, this one guards the read, and a petData written before the refusal
shipped can hold a pair.

**NOTHING IN THE PANE DISPLAYS CAPACITY**, so the item description is the only
place a player learns the number, and it states it.

### What counts as a patient, and why no engine field alone can say
`arch.dispatch.medicpatients` -- see also `fact.unit.damageteams`, `arch.module.liquids`

Five accept classes and three reject reasons, all observed 2026-08-30:

    petports_unit true                     -> unit
    teamType ~= "friendly"                 -> reject (enemy, passive, ghostly)
    entityType player                      -> player
    entityType npc                         -> npc
    friendly monster, team 0               -> podpet
    friendly monster, otherwise            -> animal

**THE MARKER IS TESTED FIRST AND THAT ORDER IS LOAD-BEARING.** A unit whose team
somehow reads `ghostly` -- a modder copying old files, a spawn parameter creeping
back -- is still recognised as ours rather than silently classed as a FISH, which
is what `ghostly` means to everything else. The ordering was luck the first time
and is deliberate now.

**`petports_unit` EXISTS BECAUSE NO ENGINE FIELD DRAWS THE LINE.** Once units run
on the friendly damage team they are byte-identical to a farm animal on every
engine field -- `monster`, `friendly`, team 2 describes a Mooshi exactly as well.
Without the marker every medic treats every other unit as livestock.

**A NAME PREFIX WAS REJECTED.** Every chassis shipped here is called
`petports_something` and the prefix would work today and stop working the moment
somebody builds their own chassis on this, which is the intended path rather than
an edge case. None of the existing chassis fields can substitute either:
`petports_canFly`, `petports_canSwim` and `petports_avoidLiquid` all have
DEFAULTS, so a plain vanilla monster answers them the way a chassis that omitted
them would. Only a field with no meaning outside this mod distinguishes absence
from default.

**THE SIGHT TEST DOES NOT TRANSFER FROM NICEMICE.** `nicemice_hasSightOf` uses
`entity.entityInSight`, which an object cannot call about two other entities, and
`entity.position()` sits at a humanoid's FEET so a naive `lineTileCollision`
between two things on one floor grazes it. Use `world.lineTileCollision` from the
port with that offset in mind.

**NICEMICE IS NOT A DEPENDENCY AND CANNOT BE CALLED.** Nicemice includes petports,
not the reverse, so every `nicemice_*` helper has to be reimplemented in the
petports namespace. What transfers is the REASONING, not the code -- and not all
of it: `nicemice_isAlly` compares team NUMBER, which `fact.unit.damageteams`
shows would be wrong here.

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

### Dispatch eligibility -- one predicate, seventeen call sites
`arch.dispatch.eligibility` -- see also `arch.dispatch.anytile`, `arch.pathing.mediumenforcement`, `dd.port.envpresence`

**BUILT AND VERIFIED IN GAME 2026-08-31.** Closes todo.dispatch.eligibility
(retired), which was priority 1.

The port used to filter candidates on ripeness, claims, backoff and existence and
never ask whether THIS CHASSIS could service one. Nine of fifteen work types had
a reach test; six had nothing at all.

**THE QUESTION IS ASKED PORT-SIDE, AT NO CROSS-ENTITY COST.**
`petports_habitatCapabilitiesForType` caches on `root.monsterParameters` per
monsterType, so eligibility costs one `world.liquidAt` per sampled tile and no
`callScriptedEntity`. That is what makes it affordable INSIDE the candidate loop
rather than on the winner -- which matters, because refusing the winner declines
the whole rung and a swimmer with one dry crop nearest and four submerged behind
it would harvest nothing.

**IT READS THE ITEM, NOT THE UNIT.** A port whose environment refuses the spawn
still holds the item and still knows the chassis, which is the same argument that
moved the habitat ladder into `petports_habitat.lua` in the first place. Modules
are part of the question -- `petportModuleLiquids` is threaded exactly as
`environmentCheck` threads it, or a poison-immune unit lives at a poison pool and
is refused every target in it.

**OBJECTS ARE SAMPLED BY `world.objectSpaces`; EVERYTHING ELSE BY ONE TILE.**
Crops, crates and machines are all objects, so one call answers for all of them.
Item drops, livestock and patients are points, and a point cannot straddle
anything.

**MOVING TARGETS GET THE REACH TEST AND NOT THE MEDIUM TEST.** A patient or a
Mooshi has moved by the time the unit arrives, so a medium verdict about the
dispatch-time position buys nothing. `standingPointNear` already answers
per-chassis for free -- free movers resolve through `petports_flyPointNear`,
walkers through the ground search. `animalWork` was the only moving-target
generator without it.

**`return` AND `diag` ARE EXEMPT.** A medium gate on the leash strands a
displaced unit, which is the failure `dead.pathing.escapeclause` closed by
re-homing instead.

**THE TILE ABOVE THE SOIL, FOR TILE WORK.** Tilled soil is solid foreground, so
`world.liquidAt` over it always reads zero and a check aimed there passes every
chassis every time -- and worse, reports "air", which is a REFUSAL for an aquatic
unit. Watering and replanting both sample `+1.5`. Replanting originally sampled
`+0.5` and would have turned away the only chassis that could work a submerged
farm.

**IT IS A VISIBLE BEHAVIOUR CHANGE AND THE PANE STILL DOES NOT SAY SO.** A unit
that used to fail noisily at a dry farm now ignores it silently. Until the pane
explains it, the `SKIPPING` log line is the only place a player chasing a still
pet can find out why.

### A target needs ANY tile; a body needs EVERY tile
`arch.dispatch.anytile` -- see also `arch.dispatch.eligibility`, `arch.pathing.mediummixed`, `dd.port.envuniform`

**THE SINGLE MOST USEFUL SENTENCE FROM 2026-08-31.** Two bugs that look unrelated
are this one sentence with the quantifier flipped, and both shipped in the same
session because the distinction had never been named.

**RUNNING THE BODY RULE OVER A TARGET.** `petports_habitatVerdict` asks "can this
chassis LIVE in all of this", which is right for a port -- the unit must occupy
its whole footprint, and `MIXED_MEDIUM` is a real refusal there. Applied to a
half-submerged shipping container it refused the crate outright to the aquatic
unit AND the flyer, while the amphibious one carried the whole base. A crate does
not have to be lived in. It has to be TOUCHED, and each of them could touch an
end. `petports_habitatAnyPointSuits` runs the verdict per tile and accepts on the
first yes.

**RUNNING THE TARGET RULE OVER A BODY.** `petports_flyPointNear` vetoes on
`petports_targetAllowed`, which samples ONE point. For a straddling object that
point is the origin tile, which sits in the flooded half, so it refused the flyer
and said "no position near it can help" while five open air tiles sat directly
above it inside the search radius.

**THE TELL IS WHICH THING THE QUESTION IS ABOUT.** A position the unit's body
will occupy needs every tile to agree. A thing in the world the unit will reach
toward needs one tile to agree. Both ladders exist and both are correct; picking
the wrong one produces a refusal that is a correct answer to a question nobody
asked.

**IT IS NOT SYMMETRIC BETWEEN HOME AND WORK.** The port's environment gate still
runs the whole-footprint ladder unchanged, and must -- see `dd.port.envuniform`,
whose reasoning is untouched and now explicitly scoped to a home.

### The port vouches for a footprint the unit cannot see
`arch.dispatch.vouch` -- see also `arch.dispatch.anytile`, `arch.pathing.oneanchor`

**THE VETO WAS NOT DELETED, AND THE AUTHOR'S FIRST INSTRUCTION WAS TO DELETE IT.**
Its header records the bug it exists for: a unit that hovered under a crate it
could not reach and reported the work done. Removing it hands that bug back to
`medicWork` and `animalWork`, which call the same resolver deliberately WITHOUT a
port-side medium check because their targets move.

**THE INFORMATION IS ON THE WRONG SIDE OF THE ENTITY BOUNDARY.** The veto cannot
be made correct from a position alone -- it needs the target's extent, and only
the port has that. So the port passes `mediumVerified` through
`world.callScriptedEntity`, and the veto stands down for it:

    servicePointNear  ->  standingPointNear  ->  petports_standingPointNear
                      ->  petports_standablePoint / standableNear
                      ->  petports_flyPointNear

**EXACTLY ONE CALLER VOUCHES**, and only because `targetSuits` has just run the
footprint ladder on the line above. Passing true anywhere else is a lie that
costs a hovering unit. A pre-flight check asserts the chain is intact end to end
and that the count of vouching callers is one.

**THE VOUCH ALSO RIDES ON THE TASK, AND THAT IS A SECOND HALF THE FIRST ROUND
MISSED.** The port vouches on ITS OWN query and then dispatches a raw position;
the unit re-resolves that on arrival through `approachTargetFor` with no vouch,
so the veto refused the crate the port had just cleared. Measured: **1122**
unit-side `flypoint DECLINED [2553,1147] outright` in one session against one
container. `mediumVerified` is now set by the generator that ran the ladder and
read by `approachTargetFor`, so it is absent on exactly the four types that never
ran one -- `animal`, `medic`, `return`, `diag` -- and those keep the veto.

**AND A THIRD HALF, WHICH IS THE ONE WORTH REMEMBERING.** Making the resolve
SUCCEED did not make anything USE it. `withdraw` was not in the list of task
types that take a resolved approach point, because that list was written when
every raw-position task was a drop or a crop; the four withdraw generators
dispatch `world.entityPosition(containerId)`, an ORIGIN, which for a
half-submerged crate is in the flooded half. So the flyer approached a position
it cannot occupy and the progress watchdog struck it. **BOTH EDITS WERE NEEDED
AND EITHER ALONE LOOKS LIKE A COMPLETE FIX**, which is why the verification pass
that found this asked "is it applied to the medic fetch too" rather than "does it
work".

**THE MEDIC FETCH WAS THE QUESTION THAT FOUND IT.** Its fetch leg routes through
`containerWithSeed`, so it was covered port-side from the start -- and it shares
the unit-side gap with every other withdraw, which is what the question exposed.

### The medium at a body is three-valued
`arch.pathing.mediummixed` -- see also `arch.dispatch.anytile`, `arch.pathing.mediumenforcement`

`petports_mediumAt` walks the body's tile rows and used to AND them into a single
`submerged` flag, so it answered "is ALL of me in water" and reported everything
else as `air`. A body straddling a waterline is not air.

**MEASURED AT THE CONTAINER, 2026-08-31.** A 1.6-tall body centred at y 1149.8
spans rows 1149 and 1150. The flyer's own search proves row 1149 is flooded and
row 1150 is not:

    #2  grid [2553,1147.8]  rows 1147+1148  -> submerged, refused
    #10 grid [2553,1148.8]  rows 1148+1149  -> submerged, refused
    #24 grid [2553,1149.8]  rows 1149+1150  -> ACCEPTED

It parked there with half of itself under water, took buoyancy on the wet half
and none on the dry, and slid under. After: `#24` is refused as `mixed` and the
search accepts `[2553,1150.8]`, a full tile clear.

**`mixed` IS REFUSED BEFORE THE FLY/SWIM SPLIT.** There is no chassis a waterline
is right for -- a flyer sinks and a swimmer hauls itself against the surface.

**WALKERS ARE UNAFFECTED.** `petports_mediumAllows` returns early for a gravity
chassis, and that early return sits below the `forbidden` check. Wading stays
legal.

**TWO SAMPLERS DISAGREEING ABOUT ONE COORDINATE WAS THE VISIBLE SYMPTOM.** The
box test accepted `[2553,1149.8]` and forty lines later the point test declined
the same coordinate. Both were self-consistent; between them they cleared a
position neither would have picked alone.

**THE THRESHOLD IS STILL `PETPORTS_SUBMERGED_FILL`.** A row at half fill counts
as dry, so a body in shallow water still reads as air. Unchanged, and NOT known
to be right -- widening it to "any liquid at all" would ground a flyer in rain.
If a unit is seen dragging through shallows, that is the line.

### A two-leg job must ask one question
`arch.dispatch.twolegs` -- see also `arch.dispatch.eligibility`, `todo.dispatch.sourcebackoff`

**THREE INSTANCES FOUND IN ONE SESSION, ALL THE SAME SHAPE.** A fetch leg and a
place leg carry different work ids, therefore different claims and different
backoff entries, so a place leg that refuses leaves its fetch leg fully eligible.
The unit hauls cargo it cannot put down, deposits it back where it came from, and
starts over.

    withdrawWork      / replantWork        seed
    medicWork fetch   / medicWork deliver  dose
    withdrawWaterWork / waterWork          liquid

**MEASURED ON THE SEED, 2026-08-31.** Nine withdraws and twelve deposits of one
`oculemonseed` into the crate it came from, one cycle every three seconds, until
another port took the intent.

**BACKOFF COUPLING IS NOT ENOUGH ON ITS OWN.** `withdrawWork` now reads the
replant leg's `workFailures`, which it could always have done -- it already
consulted `"replant:"..key` for CLAIMS and not for failures, asking the sibling
leg half a question. But a leg refused on MEDIUM records no failure at all, so
watering needed the stronger form: `waterRunWorkable` is one function BOTH legs
call, and the fetch leg asks it before it scans crates.

**REPLANT GOT THE BACKOFF HALF AND NOT THE MEDIUM HALF, AND THIS ENTRY SAID SO
FOR A DAY BEFORE ANYONE ACTED ON IT.** The paragraph above already named the
weakness in the abstract; `waterRunWorkable`'s own header already spelled out the
conclusion -- *a run refused on MEDIUM records no failure, so the backoff
coupling added for replant cannot see it, and the only thing that stops it is
asking the same question before fetching.* Watering acted on that. Replanting
did not, and the bug survived a session that believed it had fixed all three
instances.

**MEASURED AGAIN 2026-09-01, ON AN AQUATIC UNIT.** 147 `withdraw:2540,1184` and
308 `deposit:152`, one cycle every 3.3 seconds, the unit never leaving
`[2552.56,1147.81]`. The replant tile is dry land, so `replantWork` refused it on
medium and wrote no failure; `withdrawWork` checked coverage, backoff and claims
and never asked the medium question at all. The same port was refusing water runs
and item drops correctly and out loud in the same log -- `SKIPPING water run ...
is out of the water` -- which is what made the absence of any equivalent replant
line the diagnosis.

**FIXED BY GIVING withdrawWork THE PLACE LEG'S QUESTION.** `targetEligible` over
`{x + 0.5, y + 1.5}` -- ABOVE the tile, the expression copied from `replantWork`
deliberately, because a tilled tile is solid foreground and sampling it reads
zero liquid for every chassis. The two legs must sample the same point or this is
the same bug wearing different coordinates. It shares the place leg's
`targetRefused` label so the change-gate reports the tile once, and the tail
diagnostic counts medium refusals rather than blaming storage for them.

**THE GENERAL RULE, STATED SO THE FOURTH INSTANCE IS CHEAPER:** a fetch leg must
ask its place leg's ELIGIBILITY question, not merely observe its FAILURES. Backoff
sees a leg that tried and failed. It cannot see one that was never offered.

**THE MEDIC'S FETCH LEG WAS UNCHECKED WHILE ITS DELIVERY LEG WAS CHECKED**, in
the same generator, on the same trip. A medic could verify it could reach a
patient and then be sent to a crate it could not. Both legs now route through
`containerWithSeed`, which skips a source it cannot reach and keeps looking.

**A REASON STRING IS PART OF THE FIX.** `containerWithSeed` returning nil no
longer means "the network has none"; it means "none this unit can get to", and
the medic's decline text had to stop asserting the stronger claim.

### Renaming a unit, and the tag that is a separate question
`arch.pane.rename` -- see also `arch.pane.petport`, `arch.port.pushsignature`, `fact.unit.entityname`, `fact.pane.textboxcallback`

**BUILT 2026-09-01.** A text field and a Rename button on the Settings tab, plus
a `nametag` display toggle in the settings list. The field sits left of the
button; the pair spans `settingsScroll`'s width and both centre on y 89.

**THE NAME AND THE TAG ARE TWO SETTINGS, NOT ONE.** Keying the tag on "does this
unit have a custom name" does not work, because EVERY unit item ships a default
`petName` -- Diver, Wader, Flyer, Unit. A name always exists, so the tag would
always be on and the only way to silence it would be clearing a name the player
wanted. `petData.toggles.nametag` is the switch; the field only sets the name.

**THE BUTTON ALSO RELEASES THE FIELD, ADDED 2026-09-03.** A focused textbox
captures the keyboard including Enter, and nothing in this pane blurred anything
until the colour rows made that obvious -- so this field had been swallowing the
chat key since it shipped. See `arch.pane.rowfocus`.

**THE BUTTON IS THE ONLY COMMIT PATH, AND THAT IS A SAFETY DECISION.** A textbox
callback fires on ENTER, and a half-typed name reaching a server's chat-politeness
plugin is how somebody gets banned for a rename they never finished. The callback
exists because the parser demands one -- see `fact.pane.textboxcallback` -- and is
empty.

**THE FIELD CANNOT BE REPAINTED ON EVERY REFRESH.** `refresh` runs on a mirror
that changes for fuel, cargo, task and diagnostics, so writing the field each time
would delete whatever was being typed and make renaming impossible on a working
unit. It follows a new `petNameRaw` and rewrites only when the STORED name moves.
The sentinel for "nothing seen yet" is `false`, not `nil`, because `nil` is a
legitimate value it can hold.

**`petNameRaw` IS SEPARATE FROM `petName` BECAUSE THEY ANSWER DIFFERENT
QUESTIONS.** The header must never be blank and falls back to the species; the
field must be blank when unnamed, or the first click of Rename would store the
literal name "Utility Unit".

**24 CHARACTERS IN THE REGEX AND IN `PET_NAME_MAX`**, the same decision written
twice because the engine has no way to say so -- the restock quota field's rule,
everything typeable is valid. Re-clamped port-side because a message handler is
reachable by more than the pane. NO CHARACTER FILTERING: what a name may contain
is a server's policy, not this mod's.

**COLOUR ESCAPES PASS THROUGH.** `^cyan;Fuwafuwa` renders coloured on the tag.
Accidental rather than designed, and the cap counts the escape, so `^cyan;` costs
six of the twenty-four.

### The search is sized to the target when the target is an object
`arch.pathing.objectsearch` -- see also `arch.pathing.oneanchor`, `fact.pathing.collisionkinds`, `arch.dispatch.anytile`

**BUILT 2026-09-01.** `standableNear` is anchored on an entity position and
reaches `GROUND_SEARCH_UP` 4 tiles up. An object's entity position sits near its
BASE, so anything taller than four tiles has a roof the resolver cannot see.

**THE SUBMERGED SHIPPING CONTAINER IS WHERE IT SHOWED, AND THE BUG IS GENERAL.**
A ground unit could walk a platform to the container and be told there was nowhere
to stand. Every tall object had this; the container merely made it visible,
because a short object's roof happens to fall inside the default reach.

**THE FOOTPRINT BOX PLUS TWO TILES ON EVERY SIDE.** `petports_habitatObjectBounds`
derives the box from `petports_habitatObjectPoints`, so the search and the medium
test read one source. The buffer is what makes the roof REACHABLE rather than
merely included -- the top row is inside the object and the standable tile is the
one above it -- and two rather than one because the same margin serves the sides.

**IT WIDENS THE SEARCH AND RELAXES NOTHING.** Eligibility was already settled by
`targetSuits` over the same footprint, and every candidate still passes
`validStandingPosition`, `petports_mediumAllows` and the descend guard.

**NO COLLISION KIND IS CONSULTED, DELIBERATELY.** The feature was requested as
"if the container has platform collision"; it is not gated on that, because
`STANDABLE_TILE_SET` holds both Block and Platform and `validStandingPosition`
accepts either. Gating on Platform would have EXCLUDED the case
`fact.pathing.collisionkinds` says is true -- a crate top is Block -- and fixed
nothing.

**`searchDown` IS A TRAILING PARAMETER, AND THE POSITION IS THE POINT.** An
argument in the middle would have meant a nil mid-`callScriptedEntity` list, which
this mod has never measured. Same reasoning that gave `petports_homePointNear` its
own function. `petports_objectPointNear` lives in `petportsTaskAction.lua` rather
than beside the other two entry points in `petports_contract.lua`, because
`GROUND_SEARCH_UP`, `GROUND_SEARCH_DOWN` and `COLUMN_RADIUS` are locals of that
file -- written in the contract first, it would have read three nil globals
silently.

**NEVER TIGHTER THAN THE DEFAULTS.** A one-tile crate or a crop would otherwise
come out with a SMALLER search than before, which is a regression wearing a fix's
clothes.

### Anything pushed to a live unit needs a signature and a tick, not a call site
`arch.port.pushsignature` -- see also `arch.module.effects`, `arch.pane.rename`

**THE RULE, GENERALISED FROM TWO INSTANCES.** State the port holds and the unit
must WEAR has to be pushed from `update` behind a signature that includes the
ENTITY ID. Pushing it from the sites that mutate it is not enough, because a
respawn is not a mutation and no mutation site fires for it.

**`pushModuleEffects` GOT THIS RIGHT AND ITS COMMENT SAYS WHY.** `pushPetName`
was written directly beneath it and did not, firing only from the rename handler
and the toggles handler -- so correctness rested entirely on the spawn parameters
being right.

**OBSERVED 2026-09-01.** Units whose spawn parameters predated
`petports_showNametag` -- which is every unit in an existing save -- came back
with an unmanaged tag and stayed that way until somebody opened the pane.
Resocketing "fixed" them because that is a fresh spawn with fresh parameters,
which is the shape of a report that should point straight at this rule.

**THE ENTITY ID MUST BE IN THE SIGNATURE, NOT JUST THE VALUE.** A unit that died
and came back to the same name would otherwise match its predecessor's signature
and never be pushed to at all.

**THE MUTATION SITES STILL CALL IT**, so a rename lands on the click rather than
the next tick. The signature makes that free: whichever runs first writes it and
the other returns immediately.

### Medium enforcement -- four gates, and validation must model the mover
`arch.pathing.mediumenforcement` -- see also `dd.pathing.coststeering`, `fact.pathing.edgespan`, `dead.pathing.escapeclause`, `arch.unit.exitpaths`

A* HAS NO CONCEPT OF MEDIUM, so every place a route can be chosen has to be
asked separately whether this chassis may be there. There are FOUR, and the
2026-08-31 session proved that a hole in any one of them is a unit in the wrong
medium regardless of the other three.

  - **the destination**, `petports_flyPointNear`, which declines a target
    outright when no position near it is in a medium this chassis may occupy
  - **the plan**, `planMediumValid`, once per plan behind `petportsPlanSig`
  - **the string-pull shortcut**, `flyPathClear`, which samples geometry AND
    medium along every candidate line at 0.8 intervals
  - **the blind-steer fallback**, which runs when A* returns no route at all

**THE FALLBACK WAS THE HOLE AND IT TOOK TWO SESSIONS TO SEE**, because it was
the one gate nobody had counted. It read

    local legal = clear or petports_mediumAllows(targetPosition)

-- geometry and medium together in `clear`, and then an `or` that re-asked the
medium question AT THE DESTINATION ONLY. A line whose two ends are both wet was
approved however dry its middle was. It now sweeps with `flyMediumClear`, which
is `flyPathClear` minus the collision test: BLOCKED GEOMETRY IS STILL WORTH
APPROACHING, because the unit slides along an obstacle and may get round it,
which is the whole value of the fallback. AN ILLEGAL MEDIUM IS NOT, because a
unit does not slide off water into air, it simply leaves.

**AND THEN THE PLAN CHECK WAS TOO STRICT, FOR THE MIRROR-IMAGE REASON.** Sweeping
the RAW waypoint chain validates a route the unit does not fly. A* contours the
ground, so a plan crossing a shallow bar rises to follow it and BRUSHES THE
SURFACE going over -- one or two waypoints reading air in an otherwise entirely
submerged crossing. The mover skips exactly those. Observed in game: a good plan
refused over a detour that would never have happened.

**SO `aimAhead` IS SHARED AND THE VALIDATOR WALKS THE MOVER'S WALK.** Where a
shortcut exists the leg IS the shortcut, and `flyPathClear` has already tested
its geometry and its medium together -- the waypoints it skips need no check at
all, BECAUSE THE UNIT NEVER GOES TO THEM. Where no shortcut exists the mover aims
at the next waypoint, so that waypoint and the leg into it must both be legal.

**IT IS AN APPROXIMATION IN ONE DIRECTION AND THE MOVER COVERS IT.** The
validator steps waypoint to waypoint; the mover asks from the LIVE position,
which sits a measured 0.35 past each waypoint and drifts off the line under
`airFriction`. So a shortcut validation accepted can fail at runtime, and the
fallback would be to aim at the very contour waypoint validation was relying on
skipping -- which on a surface-grazing plan is in AIR. The mover HOLDS FOR A TICK
in that case rather than flying it: no shortcut AND an illegal next waypoint.
Costs one tick of acceleration; the next tick re-asks from a new position. A plan
with no shortcut and a LEGAL next waypoint is the ordinary case -- clutter, tight
corridors, the first tick of any plan -- and moves exactly as before.

**COST.** The walk is bounded by `FLY_LOOKAHEAD` sweeps per step and skips whole
runs of edges on success, so it is cheaper than the per-edge sweep it replaced.
It is affordable only because it runs ONCE PER PLAN. The `petportsPlanSig` gate
has to stay.

### One resolver owns "where does a unit stand", and the port asks it
`arch.pathing.oneanchor` -- see also `arch.pathing.aimpoint`, `fact.pathing.platformfloor`, `todo.pathing.standpointchoice`, `arch.port.tetherlocation`

**RAISED BY THE AUTHOR 2026-08-31 FROM THE RIGHT QUESTION: if the port already
computes where an idle unit stands, why is the leash computing it again?** The
answer was worse than two. There were THREE, and no two agreed:

    standableNear                 petportsTaskAction, on the UNIT
                                  columns ranked by true distance, DESCENDS to a
                                  floor under a floating submerged point, knows
                                  platforms are floor

    petports_standingPointNear    petports_contract, on the UNIT, called BY THE
                                  PORT -- first-fit by column, NO descend step,
                                  so underwater it returned a floating point

    findStandingPoint             petports_petport, on the PORT
                                  random column, descends from the TOP of the
                                  rect, cannot see platforms at all

**AND TWO LEASHES CHOOSING BETWEEN THEM.** The unit's own tether runs constantly
under `strictPortTethering`, carries the raw port position, and resolves with
`standableNear`. The port's `returnWork` fires only when the unit is stranded or
outside the network, and resolved with `findStandingPoint`. So a unit walking
home on its own initiative and the same unit being recalled aimed at different
points, computed by different code, with different bugs.

**THE DOCTRINE ALREADY EXISTED.** `arch.pathing.aimpoint` is "the router and the
walker must aim at the same point", and the header above `standingPointNear` in
`petports_petport.lua` said outright that anything dispatched to a unit should go
through it rather than `findStandingPoint`. `returnWork` was the one caller
violating its own file's rule.

**WHAT IT IS NOW.** `standableNear` is the single implementation, exported as
`petports_standablePoint`. `petports_standingPointNear` is a delegate.
`petports_homePointNear` is a second delegate that pins `searchUp` to 0. The
port's `homePosition` asks the unit and only falls back to `findStandingPoint`
when NO UNIT EXISTS -- which is what that function's own header always claimed it
was for.

**THE HOMEWARD BIAS LIVES ON THE UNIT, NOT IN THE ARGUMENTS.** `findGroundPosition`
tests UP BEFORE DOWN at every step, so an unbiased resolve puts a unit on its
port's roof -- measured, a port at `[1203,728]` resolving to `[1203.5,731.875]`.
Both home paths now reach `petports_standablePoint(portPosition, 0)` and cannot
diverge.

**A DEDICATED FUNCTION RATHER THAN AN ARGUMENT, AND THE REASON IS THE BOUNDARY.**
The obvious shape was `petports_standingPointNear(position, radius, searchUp)`
with the port passing `(position, nil, 0)` -- a nil in the MIDDLE of a
`world.callScriptedEntity` argument list. Whether that boundary preserves an
embedded nil or truncates there is NOT MEASURED, and a truncation would silently
drop the homeward bias and put the unit on the roof: the exact bug being fixed,
arriving by a route nobody would look at. `petports_homePointNear` takes one
argument and asks the question the port actually has.

**THE COLUMN RANGE IS A PARAMETER NOW.** `COLUMN_SEARCH` was a fixed
`{0,1,-1,2,-2,3,-3}`; the port asks wider for machines and wider still for
patients (`MEDIC_REACH`), so `columnsFor(radius)` builds and memoises the ordered
set. MEMOISED FOR THE ORDER, NOT THE ALLOCATION -- in a first-fit search the order
IS the answer, and building it in one place stops a caller handing over a
differently ordered set and getting a differently biased result from the same
function.

**VERIFIED IN GAME 2026-08-31, AND THE VERIFICATION IS THE ONE THING STATIC
ANALYSIS COULD NOT PRODUCE.** The port's recall fired in a clean run and
dispatched to `[2535.5,1148.8]` -- the exact point the unit's own tether resolves
to from the same `[2535,1152]`, twelve times over in the same log. Before this
change that recall was a random column and the highest ledge in it. Twenty-eight
tasks completed across eight types, with `no standable column`, `could not
resolve a home point` and `no standing point in rect` all at zero.

**THE MEDIC PATH REMAINS UNEXERCISED.** `MEDIC_REACH` is 6 and is the only caller
asking for a range wider than `COLUMN_RADIUS`, so it is the only one whose
behaviour depends on `columnsFor` building a correct set rather than on the
default falling through. No patients existed in the verifying session. If
patients stop being reached, look there first.

**WHAT IT CLOSED.** The backlog entry this replaced, and the port-side half of
`fact.pathing.platformfloor` -- no live unit reaches the platform-blind resolver
any more. `todo.pathing.standpointchoice` and `todo.port.nostandpoint` survive but
shrink: both are properties of `findStandingPoint`, which is now only reachable
with no unit socketed.

### Where a chassis tethers is authored, not inferred
`arch.port.tetherlocation` -- see also `dd.port.envuniform`, `todo.pathing.standpointchoice`

`strictPortTethering` decides WHETHER a unit comes home and holds.
`petports_portTetheringLocationType` decides WHERE home is. They were one
question only while every chassis walked, and home could not be expressed as
anything but "the floor under the port".

A CLOSED SET -- `port`, `floor`, `ceiling` -- named in `petports_habitat.lua`
beside the habitat causes, for the same reason those are named: a literal at a
call site is a value nobody can grep for. Read from the TYPE by
`petports_habitatTether`, because the port asks while deciding where to recall
something to and the answer must not depend on a unit existing.

**MEASURED, AND IT IS WHY THIS EXISTS.** `returnWork` resolved the recall target
with `findStandingPoint`, which requires a solid tile below the candidate and
picks its column with `math.random` across the coverage rect. With the port at
`[2525,1145]` and an AQUATIC unit in the water beneath it, six recalls in four
minutes aimed at `[2500.5,1163]`, `[2523.5,1158]`, `[2529.5,1158]`,
`[2553.5,1174]`, `[2554.5,1174]`, `[2556.5,1175]` -- seabed and ledges, three of
them thirty tiles away. Every one is a VALID standing point. Not one is where a
swimmer lives.

**`port` RETURNS THE PORT'S OWN POSITION UNRESOLVED**, and does not nudge it to a
legal body position. The unit does that itself: `approachTargetFor` hands a
return task's raw position to `standableNear`, which for a free mover is
`petports_flyPointNear`. Resolving on both sides is the router-and-walker split
this document already records costing a session.

**THE DEFAULT IS `floor`, AND THAT IS NOT A PREFERENCE.** An absent parameter
must mean "carry on as before", so a monstertype nobody has touched -- including
one from a mod that has never heard of the field -- keeps the ground search it
was written against. An unrecognised value logs and falls back, because the
symptom of a typo would otherwise be "a unit recalled somewhere odd", which is
the exact symptom the field exists to fix.

**`ceiling` IS DECLARED AND NOT BUILT.** It is in the vocabulary because a
ceiling-dwelling flyer is planned; its branch logs once and falls back to the
PORT rather than the floor, since anything asking for a ceiling is a free mover
and the floor is the answer least likely to suit it. When that chassis exists it
declares `"ceiling"` and the only thing to write is the resolver.

### A swimmer cannot walk back to its jump point, so it sinks
`arch.unit.swimjump` -- see also `fact.locomotion.buoyancy`, `arch.pathing.mediummixed`, `dd.pathing.motionnothealth`

**BUILT 2026-09-01, TWO HALVES OF ONE FAILURE.** An amphibious unit swimming a
waterline toward a Jump edge overshot its own jump point and fell 21 tiles to the
lakebed, then spent 4.2 seconds getting back.

**THE HANDOVER IS A PHASE LOTTERY.** `moveJump` fires only within
`JUMP_TAKEOFF_REACH` 1.0 of its source, the Jump edge does not become current
until the unit has CROSSED that source, and the mover does not run until the tick
AFTER the handover -- so the usable window is about 0.36 tiles, sampled every
0.64. Measured, four Swim -> Jump handovers at one waterline:

    gap at handover   gap when moveJump ran   outcome
    0.119             0.728                   takeoff
    0.023             0.681                   takeoff
    0.497             0.836                   takeoff
    0.557             1.194                   REFUSED, unit fell 21 tiles

Nothing distinguishes the fourth except phase.

**HALF ONE: THE SWIM MOVER BRAKES FOR A JUMP.** `petportsWalkMover` had done this
on land since the same failure was measured there; `petportsFreeMover` had no
equivalent. At `JUMP_APPROACH_SPEED` 3.0 the run-in covers 0.25 per look and the
handover lands inside a quarter tile. `JUMP_APPROACH_SLOWDOWN` and
`JUMP_APPROACH_SPEED` are context-globals now so both files can read them.

**AND THE AIM WAS ALREADY THE JUMP SOURCE, WHICH IS WHY A SPEED IS ENOUGH.**
`aimAhead` returns Fly and Swim edges only and a Jump is always followed by Arcs,
so on the run-in it finds no shortcut and falls through to the current edge's
target -- which IS the jump source. The unit was steering at the right point all
along, at eight tiles a second, and `controlApproachVelocity` commands a VELOCITY
rather than a stopping place.

**HALF TWO: THE JUMP MOVER'S RECOVERY WAS SWITCHED OFF IN LIQUID.** The walk-back
branch is gated on `onGround`, never true for a swimmer at a waterline, so the
mover issued NOTHING -- and an amphibious chassis declares no `liquidBuoyancy`
and runs `gravityMultiplier` 1.5, so its surface hold is produced ENTIRELY by the
swim mover's thrust. The first tick with no thrust is the first tick of a fall.

The liquid arm accepts `mixed` as well as `swim`, because the measured body was a
1.6-tall box centred at 1149.81 straddling one wet row and one dry one.
`JUMP_LEVEL_TOLERANCE` deliberately does NOT apply -- it exists because walking
cannot change what floor you are on, and swimming changes both axes.

**BEYOND `JUMP_SWIM_CHASE` 4.0 THE UNIT IS LEFT TO SINK, AND THAT IS DELIBERATE.**
The grounded-stall check is the only thing that can replan a unit parked on a
Jump edge and it requires `onGround`, so holding station in open water would wait
forever on a detector that cannot fire. Sinking terminates in a floor, a stall
and a replan.

**VERIFIED: 5 of 5 takeoffs, gaps 0.14 to 0.55, zero sinks.** The liquid arm has
never fired in game -- the brake gets there first every time, which is the
intended division of labour and also means the arm is UNTESTED.

### A latch that outlives its arc stops the NEXT flight, silently
`arch.pathing.brakelatch` -- see also `arch.pathing.arrivalsign`, `fact.pathing.arcmoverthrottle`, `dead.pathing.waterdrag`

**THE WORST BUG OF THE 2026-09-01 SESSION, AND IT WAS INTRODUCED BY THE FIX TWO
BUILDS EARLIER.** `petportsLanding` is the arrival brake's latch. It was cleared
inside `if self.pather.petportsLaunch ~= nil then`, on the reasoning that the two
flags have the same lifetime. THEY DO. But only one of them is only ever SET on a
jump.

The arrival brake fires on ANY arc, including a walk-off fall, which has no
takeoff and therefore no launch record. So a fall that ended in the brake latched
the flag and then failed its own clear, because the guard above it asked about a
record that was never written.

**WHAT A STUCK LATCH DOES.** Every airborne tick of every LATER flight hits

    if pather.petportsLanding then
      mcontroller.controlApproachXVelocity(0, mcontroller.baseParameters().groundForce)
      return "running"
    end

-- horizontal velocity driven to zero, and a return ABOVE the friction zeroing.

**MEASURED.**

    45.516  arrived at landing [2494,1164.8] (ahead -0.713623)   walk-off,
            no launch record, NO "launch record cleared" line follows
    47.63   next flight, first tick the arc mover runs:
            [2510.02,1161.97]  vx 8.00 -> 3.07 -> 0.00, medium AIR
    47.96   grounded at [2510.02,1152.8] after nine tiles of vertical drop,
            1.98 short of its Land, stalled, replanned

**IT IS INVISIBLE, AND THAT IS THE REUSABLE PART.** The brake logs once when it
fires and never again; the hold logs never. The symptom is a unit stopping dead
in mid-air on a later, unrelated flight, with nothing in the log joining the two.
It cost TWO confident wrong diagnoses -- see `dead.pathing.plannersteer` and
`dead.pathing.waterdrag` -- before a per-tick trace showed the same collapse in
dry air nine tiles above any liquid.

**THE RULE.** LATCHED STATE NEEDS ITS OWN CLEAR AND ITS OWN LOG. Sharing a guard
with a neighbouring flag couples two lifetimes that are only equal until one of
them has a narrower setter. The clear is unconditional now, ahead of the launch
record's, and logs `ARCMOVER landing latch cleared` whenever it actually had
something to clear -- so a stuck latch can never again be silent.

**VERIFIED 2026-09-01.** 25 brake firings, 25 latch clears, paired exactly, over
38 takeoffs and 38 landings. Zero dry-air horizontal collapses across 178
airborne Arc ticks that had horizontal motion in the plan.

### Arrival is a sign test, not a distance
`arch.pathing.arrivalsign` -- see also `todo.pathing.brakefloor`, `fact.pathing.arcmoverthrottle`, `arch.pathing.brakelatch`

**BUILT 2026-09-01, REPLACING `LAND_BRAKE_REACH` 0.5.** The old gate was
`math.abs(here[1] - landing[1]) <= 0.5`, which asks AM I NEAR THE LANDING'S
COLUMN and not HAVE I GOT THERE. Those differ in exactly the case that matters: a
unit still travelling TOWARD its landing is near it, and braking then removes the
only velocity that could finish the crossing.

`ahead` is the distance to the landing measured ALONG THE DIRECTION OF TRAVEL --
positive while it is still in front, zero at it, negative once past. The brake
fires only at or past zero, bounded on the far side by `LAND_BRAKE_OVERRUN` 1.5
because the near-side bound is gone and a fast arc covers a tile between looks.

**MEASURED, THREE FAILURES AND ONE SUCCESS THAT SEPARATE THE TWO TESTS:**

    here [2535.59,1150.56]  landing [2536,1149.8]   0.41 short, 0.76 high
    here [2523.40,1160.80]  landing [2523,1160.8]   0.40 short, level
    here [2523.40,1160.80]  landing [2523,1160.8]   0.40 short, level
    here [2531.00,1152.80]  landing [2531,1152.8]   dead on -- CORRECT to brake

All four pass the distance test. Only the fourth passes the sign test.

**A MOTIONLESS UNIT IS TREATED AS ARRIVED, AND THAT IS A BRANCH RATHER THAN A
CONSEQUENCE.** Signing by `vel[1] >= 0` calls a landing to the RIGHT of a
stationary unit "still ahead" and refuses to brake forever, on the strength of a
velocity that is not going to close anything. `LAND_BRAKE_STATIONARY` 0.1 is a
band, not a comparison against zero, because a resting unit reads `[0,-1.5353]`.

**A TOUCHDOWN STOP WAS TRIED AND REMOVED.** A hard `setVelocity` in the arc
mover's grounded branch, as a backstop. It fired ZERO times in a session with 35
takeoffs, and so did every other line in that branch: the ARC SKIP IN `update()`
GETS THERE FIRST, EVERY TIME, using the same predicate and consuming the arc
before the mover runs. The branch is a fallback, not the landing path, and a
guarantee on a path that never executes reads as cover and is not. If a slide-off
is ever measured, the place to stop it is the GROUNDED branch of that skip.

**`LAND_BRAKE_OVERRUN` IS EXERCISED NOW.** It decided nothing for two sessions
and then caught two firings at -0.38 and -0.61 -- units already past their column
that the old near-side reach would have refused outright.

### Nothing steers x during a flight
`arch.pathing.nosteer` -- see also `fact.pathing.plannervxdrop`, `fact.pathing.arcmoverthrottle`, `dead.pathing.plannersteer`, `fact.pathing.airauthority`, `arch.pathing.climbsteer`

**QUALIFIED 2026-09-01 BY `arch.pathing.climbsteer`, AND THE RULE STILL HOLDS FOR
EVERY BALLISTIC ARC.** One narrow exception now commands horizontal velocity:
an arc whose PLANNED LAUNCH vx WAS ZERO, which is how A* draws a climb past an
obstruction. Read that entry for the three gates that keep it from being the
thing deleted below.

**AND ITS OPEN MEASUREMENT IS ANSWERED -- SEE `fact.pathing.airauthority`.** This
entry asked whether `groundForce` simply has no airborne authority in the
ACCELERATING direction. It does not, and `airForce` does, at exactly its stated
value. The old command was the wrong quantity rather than a doomed idea.

**BUILT 2026-09-01 BY DELETION.** The airborne branch of `petportsArcMover` used
to end in `controlApproachXVelocity(wantVx, groundForce)`, where `wantVx` was
`launch.vx` on a jump and `velocity[1]` -- THE PLANNER'S PER-EDGE VELOCITY -- on
anything else. Both halves are gone, along with the substitution block, the stale
record check and `petportsArcSubstituted`.

**THE FRICTION ZEROING FOUR LINES ABOVE IS THE WHOLE MECHANISM.** With
`airFriction` at 0 and no command, horizontal velocity persists. That IS a
ballistic arc.

**THE SUBSTITUTION WAS A NARROWER BUG, NOT A FIX.** Holding `launch.vx` and
issuing nothing produce the same trajectory whenever the command is correct. They
differ only where it is WRONG, and there the command wins. See
`fact.pathing.arcmoverthrottle` for the accidental control that proved it a
session early: unguided the unit hit its landing 0.22 over, guided it missed by
1.83.

**A WALK-OFF FALL HAD NO COVER AT ALL**, because it has no takeoff and so no
launch record, and A* models a walk-off as a short forward hop followed by a
VERTICAL DROP whose stored vx is zero. That looked like the ledge defect and was
not -- see `dead.pathing.plannersteer`.

**`velocity` SURVIVES** because the liquid branch below still reads
`velocity[2]`. Only the horizontal half was removed.

### One exception to nosteer: an arc whose planned launch vx was zero
`arch.pathing.climbsteer` -- see also `arch.pathing.nosteer`, `arch.pathing.solvelaunch`, `fact.pathing.airauthority`, `fact.pathing.plannervxdrop`

**BUILT AND VERIFIED IN GAME 2026-09-01.** The airborne branch of
`petportsArcMover` commands horizontal velocity again, in one narrow case, after
`arch.pathing.nosteer` deleted all of it. This is the other half of the guard
removal in `arch.pathing.solvelaunch` and neither is testable alone.

**A* MODELS AIR CONTROL AND WE DID NOT.** Its edge list changes vx mid-flight
with no force behind it, because its actor model can steer:

    edge 6  [2532,1142.3] -> [2532,1143.3]   vel [0,14.6963]
    edge 7  [2532,1143.3] -> [2532,1143.8]   vel [0,4.96] -> [12,0]
    edge 8  [2532,1143.8] -> [2532.5,1143.8] vel [12,-5]

That is a climb-then-traverse: rise in a clear column to a full tile above the
landing, then go sideways. **THE PLAN IS NOT A PARABOLA AND WAS NEVER MEANT TO
BE ONE.** After the deletion the horizontal half of every such plan was simply
never flown.

**THREE GATES, AND THE THIRD IS THE ONE THAT MAKES IT SAFE.**

    launch record required   a WALK-OFF has no takeoff and so cannot reach this
                             at all -- excluded by construction, which is the
                             half the old launch-record substitution could never
                             cover and the source of dead.pathing.plannersteer
    plannedVx == 0           every ballistic arc is untouched
    acquire only             command ONLY when the plan's magnitude EXCEEDS the
                             current one

**ACQUIRE-ONLY IS WHAT PREVENTS A RERUN OF THE FAILURE THAT JUSTIFIED THE
DELETION.** That failure was a BRAKE -- A* dropped its own vx from 12 to 1 at an
apex, the mover obeyed in one look, and the unit crossed its landing altitude
1.83 tiles short and fell twelve tiles. A planner vx that DROPS is now ignored,
so the launched velocity still holds for the whole arc exactly as
`fact.pathing.plannervxdrop` requires.

**MEASURED, THE WHOLE CLIMB:**

    [2531,   1132.90]  vel [0,       47.30]   launch, vx clamped to 0
    [2531,   1141.23]  vel [0,       17.30]   x pinned at 2531, rising clear
    [2531,   1142.34]  vel [0,        7.30]   steering fires
    [2531.21,1142.61]  vel [4.16667, -2.70]
    [2531.76,1142.05]  vel [8.33333,-12.70]
    [2532.2, 1140.66]  vel [0.00488,-22.70]   landed

Covered the 1.0 tile it needed in three ticks. **ZERO STALLS across five
takeoffs and 27 tiles of climb, against four-plus identical laps on one ledge
before.**

**`airForce`, NOT `groundForce` -- see `fact.pathing.airauthority`.** Using the
landing brake's quantity for an airborne command is what made the previous
attempt look like it had no authority.

**IT LOGS ONCE PER PATHER, NOT ONCE PER ARC.** Change-gated on the target vx,
which is 12 every time, so a run with four steered arcs shows one line. Do not
read the count as attempts.

### A beached aquatic unit flops, and four things had to change for it to
`arch.locomotion.beached` -- see also `fact.unit.statemachine`, `arch.pathing.climbsteer`, `fact.pathing.dropfaults`, `arch.locomotion.classes`, `todo.unit.species`

**BUILT AND VERIFIED IN GAME 2026-09-01**, replacing the backlog entry of the
same name. An aquatic unit stranded out of water now hops, drops through
platforms, and either finds water on its own or is collected by its port after
thirty seconds. **THE FLOP ITSELF WAS TWENTY LINES AND EVERYTHING ELSE WAS THE
WORK**, exactly as the backlog entry predicted -- it just named the wrong
obstacle.

**FOUR MECHANISMS, AND EVERY ONE OF THEM WAS FOUND BY A FAILED RUN.**

    detector       petports_outOfMedium, the SAME call the port polls
    yield          petportsTaskAction.update returns true when beached
    suppression    petBehavior.run clears the action queue and returns
    forced pick    self.state.pickState({petportsFlopState = true})

**THE DETECTOR IS SHARED ON PURPOSE.** `petports_outOfMedium` is what the port's
`mediumCheck` already polls, so the flop and the rescue cannot disagree about
what beached means. It also settles the chassis question for free: `out` is true
for an aquatic in air and FALSE for a flyer in air, because the answer is built
from `petports_canFly` / `petports_canSwim` rather than from gravity. A walker
returns `checked = false` and can never enter the state at all.

**"mixed" IS THE COMMON READING, NOT "air".** Draining water around a unit leaves
it straddling the waterline. The first build gated the 30-second window on `air`
alone and would have given a drained unit the ordinary 10.

**THE YIELD ALONE DOES NOTHING.** `petBehavior.run` re-queues the held task every
tick, so yielding just ends the action and the next tick re-enters it. Measured:
**91 yields in 8 seconds, 80ms apart, flop never reached.**

**AND SUPPRESSING THE QUEUEING INSIDE run() IS ALSO NOT ENOUGH.**
`groundPet.querySurroundings` calls `reactTo` for every nearby entity and THEN
calls `run()`, and the reactTo handlers queue beg, follow, inspect, eat, play and
sleep themselves. The queue is already full before `run()` starts. Measured:
**inspectAction re-picked every two seconds through the whole beaching**, so the
flop ticked in bursts. The fix is to clear `petBehavior.actionQueue` outright.

**AND AN ACTION ALREADY IN FLIGHT HOLDS THE SLOT REGARDLESS.**
`groundPet.update` only ticks the plain-state machine when `actionState` is
empty, and vanilla's inspect, follow, beg, eat and pounce have no idea beaching
exists. `self.actionState.endState()` is the catch-all; it runs the state's own
`leavingState`, so a held task still reports through the ordinary path.

**THE PHYSICS ARE A VANILLA FISH'S, READ OFF
`/monsters/fishing/fishingchuckle.monstertype`.**

    airJumpProfile.jumpSpeed   15.0     the chassis inherits 45
    airFriction                0.5      the chassis declares 24
    liquidFriction             1.5      the chassis declares 24
    flopJumpInterval           0.3-1.5
    bounceFactor               0.6      from vanilla flopState

**THIS LANDED ON THE THIRD ATTEMPT AND BOTH MISSES ARE WORTH KEEPING.** Leaving
the chassis friction alone braked every hop before it started -- 4 tiles in 17
seconds. Zeroing it outright, copying `petportsArcMover`, let the inherited 45
launch fly free and the unit ricocheted **five tiles a hop, between y 1128.8 and
1134.2**. Rise scales with the SQUARE of launch speed, so 45 against 15 is nine
times the height. The fish's numbers sit between the two misses.

**THE WHOLE airJumpProfile IS PASSED, NOT JUST jumpSpeed**, so no question about
how a partial JumpProfile merges. **controlParameters, NOT applyParameters** --
it re-asserts per tick and lapses when the state stops, so there is no persistent
override to leak and no cleanup to miss on an abnormal exit.

**GRAVITY IS TURNED ON, AND THIS IS THE ONE PLACE THAT IS SAFE.** The aquatic
chassis is `gravityEnabled` false, and every part of a flop needs gravity.
The amphibious chassis is described in `arch.locomotion.classes` as "the otter",
and at the time it needed no transition code precisely because it never switched
gravity at runtime -- it does now, see `dd.locomotion.otterswitch`, under exactly
the timing constraint this paragraph goes on to state -- `PathFinder:start` reads `baseParameters` and `mustEndOnGround` is
captured at `PathMover:new`, so flipping it mid-route corrupts a live plan.
**THAT OBJECTION DOES NOT APPLY HERE:** a beached unit has yielded its task and
has no route.

**`controlDown` IS KEPT, REVERSING WHAT THE BACKLOG ENTRY SAID.** That entry said
"COPY THE JUMP, NOT THE `controlDown`", citing the drop-through fault. Water is
almost always DOWN from wherever a unit is stranded and a platform between the
two is the common case on a base, so a flopper that cannot pass a platform cannot
save itself. The risk is bounded by the rescue: falling somewhere wrong ends in a
re-home, and only one of falling and hovering can end in water.

**THE RESCUE WAS ALREADY BUILT.** `mediumCheck` polls and re-homes; this adds
`MEDIUM_STRIKE_LIMIT_BEACHED` 6 against the ordinary 2, selected on `air` or
`mixed`. The split is SELF-RESCUE, not severity -- a unit wedged in terrain or
sitting in a forbidden liquid has no way out, so making it wait three times as
long buys nothing. **VERIFIED: poll 1 of 6 through poll 6 of 6, re-home at
thirty seconds, unit back at its port and pathing.**

**STILL PLACEHOLDER:** the `flopping` animation state exists in all five sheets
but aliases the same run strip as everything else, so it reads as walking until
real art lands.

### The flight trace, and what it is for
`arch.tooling.flighttrace` -- see also `proc.tooling.instrument`, `arch.pathing.brakelatch`

**BUILT 2026-09-01 BECAUSE 12 Hz RECONSTRUCTION RAN OUT.** `FLIGHT_TRACE` in
`petportsTaskAction.lua`, one line per tick for the whole of every flight,
numbered `#flight.tick` so several falls sort without matching timestamps by
hand. OFF BY DEFAULT -- it is the densest logging in this mod.

**IT FIRES REGARDLESS OF EDGE ACTION, AND THAT IS THE POINT.** The first airborne
tick of a walk-off is still on the WALK edge; the pather does not advance to the
Arc until the following tick. Anything gated on `action == "Arc"` misses the
handover, which was the interval under suspicion. The call sits ahead of the arc
block in `update()` for the same reason.

**THE FOUR FIELDS THAT EARNED IT.**

  - `moved` and `dt` -- real displacement over the real interval. The only honest
    velocity in the line. `mcontroller.velocity()` sits beside it deliberately so
    the size of the sampling artifact is on the record rather than in a comment;
    it reads round planner numbers like `[8,-10]` while `moved/dt` reads 3.07.
  - `liquidMovement` -- the ENGINE'S OWN verdict on whether it is moving this
    body as a swimmer. Beats inferring a waterline from where a swimmer floats,
    and is what killed `dead.pathing.waterdrag` in one run.
  - `medium` -- ours, from `petports_mediumAt`, which reports `mixed` a tick
    before the engine flips `liquidMovement`. The disagreement is useful.
  - `planX` and `off` -- where the plan says the unit should be at its current
    altitude. Turns "it looks like it leaves the arc" into a number.

Plus one chassis line per flight -- `liquidFriction`, `liquidImpedance`,
`airFriction`, `groundFriction`, `gravityMultiplier` -- so a measured decay can
be checked against the numbers it is supposedly overriding rather than against a
guess at engine defaults. `groundFriction` reads null; the other four report
exactly what the monstertype says.

### Swim mode: one chassis that changes what kind of mover it is
`arch.locomotion.swimmode` -- see also `dd.locomotion.otterswitch`, `fact.unit.movementparams`, `fact.pathing.canpathfind`, `arch.locomotion.dive`, `arch.locomotion.classes`

**BUILT 2026-09-02.** The amphibious chassis holds one of four modes and every
resolver in the mod branches on it rather than on physics:

    land      gravity on,  chassis buoyancy   an ordinary walker
    aquatic   gravity off                     the aquatic chassis
    exiting   gravity on,  buoyancy 1.0       gravity, but afloat
    diving    gravity on,  controlDown held   committed to a trajectory

**THE PROBLEM IT SOLVES.** Every walker resolver answers "where can a body
stand", so asking one about a fish returns the seabed beneath it. Measured: unit
at [2493.18,1128.8], fish at [2493.97,1136.25], gap 7.45 against `FISH_REACH`
5.0. Over real water there is no seabed in the search box at all and the task
fails at dispatch without the unit moving.

**petports_freeMover READS THE MODE, NOT THE PHYSICS**, and it has to -- see
`fact.unit.movementparams`. Six other places used to read
`baseParameters().gravityEnabled` directly and now call it instead, because with
a mode in play those two questions have different answers.

**THE THRESHOLDS ARE ASYMMETRIC.** A water mode is entered only at `swim` and
left only at `air`; `mixed` holds the current mode. Symmetric thresholds produced
a LIMIT CYCLE at the surface -- `exiting` floats on buoyancy 1.0, `land` sinks on
the chassis value, so each drove the unit into the other's territory, y bouncing
1146 to 1149 on a one-second period for a whole log. A rate limit cannot fix
that; it only sets the period. `mixed` carries no information about DIRECTION,
and the current mode is the only record of it.

**ENTRY IS GATED ON THE TASK, EXIT IS NOT.** Only a fish task turns a walker into
a swimmer -- every other submerged behaviour was already correct with gravity on,
and a harvest route crossing a puddle used to throw away a working plan and spend
two seconds rebuilding. But once a unit IS a swimmer it must get out regardless
of what it does next, or it floats in deep water with a harvest to do.

**AND THAT GATE NEEDED A FLOOR UNDER IT, ADDED 2026-09-03.** A walker crossing a
shin-deep pool and a walker that has just fallen into open ocean report the same
medium and hold the same kind of task; only a FISH task could make a swimmer, so
the second one stayed a walker and sank. Measured: a missed exit jump, an upcycle
task in hand, 54 tiles down over 17 seconds at a steady 3 tiles a second, ending
only when the task failed on its own. `wadeableBottom` is the discriminator --
solid or platform within `PETPORTS_WADE_DEPTH` of the feet. With a bottom it is a
pool being crossed; without one the destination decides, which for such a task
means `exiting`. See `todo.unit.progressdirection` for why nothing caught it.

**FOUR THINGS HANG OFF petports_outOfMedium AND ALL FOUR ARE WRONG HERE**, so a
gravity-switchable chassis reports `checked = false`: the port's 30s re-home,
`petportsFlopState`, the task-action yield, and petBehavior's beached
suppression. The forbidden-liquid deny-list is unaffected -- it is tested above
every short-circuit in `petports_mediumAllows`.

**THE MODE IS RE-ASKED EVERY TICK AND A CHANGE FORCES A PATHER REBUILD.** Getting
wet is not an event anything reports; it is a position, one tick after another.
The rebuild is mandatory rather than tidy -- `mustEndOnGround` is captured at
`PathMover:new`, so a live plan built under one mode is invalid under the other.

### The dive: finding a hole, a board, and getting wet
`arch.locomotion.dive` -- see also `arch.locomotion.swimmode`, `fact.unit.platformdrop`, `dead.locomotion.oceanlevel`, `todo.locomotion.dropthroughrise`

**BUILT 2026-09-02, IN FOUR PARTS.**

**ONE. TRACE THE SURFACE.** A flood from the fish that prefers up -- liquid
settles downward, so the top of a connected body is where its air boundary is --
branching sideways only where the ceiling is solid, which is the capped-tank case
that makes it necessary. It collects EVERY opening the body fits through, not the
first. Platforms are absent from `PETPORTS_DIVE_SOLID_SET` because a dive goes
straight through one.

**THE HOLE IS WIDTH-CHECKED INSIDE THE TRACE, NOT AFTER IT.** The body is 1.6
wide, deliberately above 1.5 so the pathfinder rejects one-tile tunnels, and a
too-narrow opening is not a failure -- the trace keeps spreading and may find a
wider one in the same pool.

**TWO. PAIR A BOARD WITH A HOLE.** Neither is meaningful alone, and choosing them
in sequence was a real bug: an unlucky first opening discarded every board in the
pool, and the nearest footing won even behind a wall. One `diveSighted` ray per
pair, scored `(aligned and 0 or 1000) + walk + dx + drop*0.1`.

**ALIGNMENT IS THE QUALITY METRIC AND IT IS MEASURED, NOT INVENTED.** An aligned
pair writes no horizontal velocity at all -- no drag to fight, nothing to solve
wrong, no swept flight across terrain. Every aligned dive in every log has landed.
The walk term outranks `dx` within the aligned class because every aligned pair
already works, so a tile of offset is not worth twenty tiles of walking; without
it, aligned pairs tied exactly and the scan order decided, which read as a
standing preference for the left.

**THERE ARE TWO SEARCH WINDOWS, AND THEY ARE NOT THE SAME SHAPE.** Boards are
hunted over a narrow window spanning the fish and the unit -- the unit's own
column is the one column it is known to be able to reach, and both halves used to
orbit the fish, so a unit parked on a platform directly over the water was never
considered. Boards are seeded at the WATERLINE, from the nearest opening in x,
never at the fish's own depth.

**THE TRACE GETS A MUCH WIDER ONE, ADDED 2026-09-03.** It is not looking for
footing; it is looking for the EDGE OF A LID, and a lid is as wide as whatever
the player built. Measured on an islet with the port on top and the fish directly
beneath: "no surface within 400 tiles ... sealed, or a pool larger than the
budget", where the budget was NOT the constraint -- the flood was filling a boxed
region it had been told to stay inside. Simulated, a 12-tile window fails on any
islet wider than about twenty tiles while 48 solves all of them inside the SAME
budget. The board window is then derived from the openings that survived, because
a hole at an islet's edge needs a board at that edge.

**OPENINGS ARE CAPPED BY COUNT, NOT BY DISTANCE.** A 20-tile bound from the fish
was retired: against a wide trace it discards precisely the openings the widening
exists to find. A count also bounds the pairing cost, which distance does not --
pairing is columns times openings rays, and a wide trace can return seventy-six.

**THREE. LAUNCH.** Aligned pairs hop and drop; offset pairs get horizontal
velocity re-asserted per tick, because `airFriction` decays a one-shot launch and
the solve has no drag term. The path is swept with the same `bodyFitsAt` the
trace used on the hole, because after launch there is no steering. A refused
sweep retries once with no hop -- the hop is the only part that goes UP, so under
a low ceiling it is the hop that is refused -- and that retry requires a real
platform underfoot (`fact.unit.platformdrop`).

**FOUR. LAND, OR FAIL.** Submerged is success. Solid ground while still dry is
failure. Past the arc's own prediction plus three seconds is failure. Both
failures strike the board off so the trace stops re-offering it, and drop the
plan so the port can re-dispatch.

**THE BOARD IS ABANDONED IF THE FISH BECOMES SWIMMABLE ON THE WAY.** Submerged
AND a body-width clear run to the fish, both. Crossing the pool is often the
shortest path to the board above it, and at that moment the board has nothing
left to offer. "Am I inside the traced tiles" was the other candidate and is
weaker: the trace floods contiguously, so two nearly separate pools joined at one
tile read as one body. A swept BODY answers what a ray only approximates.

### A module that grants a setting, and the colour that could not ride the effect
`arch.module.rgblight` -- see also `arch.module.effects`, `arch.port.pushsignature`, `dd.pane.fieldbooks`, `fact.unit.effectanimator`

**BUILT 2026-09-03.** The RGB Lamp Module is the plain lamp with the colour
handed to the player: three rows in the petport pane's settings list, each a
label, a spinner and a numeric field, while the module is socketed.

**IT IS THE FIRST MODULE THAT GRANTS UI**, and that needed no new mirror field.
The item declares `petports_moduleFlags ["rgblight"]`, the port unions the flags
and mirrors them as it already did, and the pane's settings rows key on the flag
that reveals them -- so a module that adds settings costs a flag and a row entry.

**THE COLOUR LIVES ON petData, NOT ON THE ITEM.** Two reasons and the second is
the one that decided it. It travels with the pet like the medic and farming
settings, and it SURVIVES THE MODULE COMING OUT -- a player unsocketing to
rearrange slots gets their colour back rather than a reset. And a colour on the
item would have to be merged by `moduleFieldUnion`, which unions lists of strings
and has no answer for two colours; storing it on the pet means the question never
arises, because there is only ever one colour and it belongs to neither module.

**THREE CLAMPS, AND THEY ARE NOT REDUNDANT.** The pane clamps for the player.
The port clamps because a message handler is reachable by anything that can send
an entity message. `petports_setLightColor` clamps because it is a global on a
scripted entity and `world.callScriptedEntity` reaches it from anywhere.

**THE COLOUR CANNOT TRAVEL WITH THE EFFECT THAT USES IT.**
`status.setPersistentEffects` carries effect NAMES and no payload -- the same
wall `arch.module.liquids` hit and answered with a second field. So the colour
goes down its own wire and is WAITING on the unit when the effect looks:

    petData.light            the port's copy, persisted with the pet
    petports_setLightColor   port -> unit, sets a status property
    petports_lightColor      the status property the effect script reads

**ITS OWN PUSH RATHER THAN RIDING pushModuleEffects.** That signature covers the
module SET; a colour changes when a spinner moves, not when anything is socketed,
so folding it in would re-push effects, liquid permissions and flags every time a
channel ticked by one. `pushUnitLight` is signature-gated from `update` with the
entity id in the signature -- `arch.port.pushsignature`'s third instance, and for
the reason that entry already gives: a respawn is not a mutation, so a unit that
died holding an RGB lamp would wear its default until somebody opened the pane.

**THE PROPERTY IS WRITTEN WHETHER OR NOT THE MODULE IS SOCKETED**, so a module
socketed onto a unit that already has a colour lights correctly on its first
frame instead of waiting for the next push to change something.

**IT DOES NOT REPLACE THE PLAIN LAMP.** That is a common drop and this is a rare
one; two separate items, two separate effects, and a unit carrying both gets two
lights. Both default to vanilla's [140,140,140], so an untouched RGB module is
indistinguishable from the lamp it upgrades -- which makes "did the module work"
answerable before any value is moved.

### A third lamp, and how little a module can be
`arch.module.huelight` -- see also `arch.module.rgblight`, `arch.module.effects`, `fact.unit.effectanimator`

**BUILT 2026-09-03, THE SAME DAY AS THE RGB LAMP AND IN A FRACTION OF THE
WORK.** Opened as todo.module.huecycle (retired). The Prismatic Lamp walks the
hue wheel on a timer: four new files, nothing existing touched.

**IT IS THE FLOOR OF WHAT A MODULE COSTS, AND THAT IS WHY IT IS WORTH AN ENTRY.**
No pane rows, no `petData`, no mirror field, no port handler, no push, no flag.
An item naming an effect, and an effect with a script and an animation. Every
module that grants a pure capability can be this small; the RGB lamp is large
because it grants a SETTING, and the difference between those two is the whole
cost.

**A THIRD LAMP RATHER THAN A MODE OF THE SECOND.** A mode would need a fourth
settings row and a rule for what the three colour rows mean while it is on. As
a separate item there is nothing to rule on -- and `dd.module.oneofakind` does
not object to owning all three at once, because that rule refuses two of the
SAME item, which is the case where the second one does nothing. Three lamps is
three lights and three slots spent, which is a player's business.

**IT IS A SIDEGRADE, NOT AN UPGRADE.** The RGB lamp can be any colour including
all of this one's, one at a time; this one cannot be made to hold still. Same
rarity for that reason.

**EVERY KNOB IS IN `effectConfig`**, read once at init, so retuning is an asset
edit and a resocket with no Lua touched -- `huePeriod`, `saturation`,
`intensity`.

**THE SIGN OF `huePeriod` IS THE DIRECTION, AND ONLY ZERO IS REFUSED.** It was
guarded against negatives too, on the reasoning that a backwards sweep looked
like a typo; it was wanted on the first day the module existed, and the shipped
default is now negative. Nothing downstream needed changing -- a negative period
makes the accumulator count down, and Lua's `%` returns a non-negative result
for a positive divisor, so the wheel simply turns the other way.

**BRIGHTNESS IS ONE KNOB IN 0..255, NOT TWO.** It was briefly both -- a `value`
in 0..1 in the config and an intensity in 0..255 scaling the finished colour --
which multiplied together and gave two ways to say one thing. 0..255 survived
because it is the unit the other two lamps already state their colour in.

**IT IS APPLIED BEFORE THE ROUNDING, NOT AFTER, AND THAT IS THE LOAD-BEARING
HALF.** Scaling the finished colour undoes the rounding `hueColor` just did and
hands `setLightColor` three floats -- 128 * 80/255 is 40.156 -- and what the
engine does with a fractional channel is not something this mod has measured.
Passing the intensity as `hueColor`'s own `val` is the same multiply one step
earlier, and everything that leaves is an integer. Verified against the
post-scaled version across 20,001 sample points: the two agree to within 0.65 of
one channel level, which is the rounding itself.

**THE COLOUR MATHS IS A TRIANGLE WAVE SAMPLED AT THREE OFFSETS**, ported from a
supplied LSL routine rather than written fresh. No sector switch and no min/max
search: the whole conversion is nine comparisons and no branch on which sixth of
the wheel it is in. **DIFFED AGAINST THE ORIGINAL ACROSS 20,001 HUES** before
shipping, agreeing to within the rounding the port adds.

**THAT DIFF CAUGHT THE ONE THING NOBODY WOULD HAVE PREDICTED.** `wave(0)` is 0,
so at hue 0 the RED channel is the one switched off -- the wheel starts on CYAN
and runs cyan, green, yellow, red, magenta, blue. The comments and the
animation's seed colour had both been written claiming red, from expectation
rather than from the arithmetic. Every hue is still covered; it simply starts
somewhere nobody guesses, and the animation is seeded to match so that the first
frame is not a jump.

**NOTHING IS LOGGED PER COLOUR CHANGE, DELIBERATELY.** `arch.module.rgblight`
logs every change because those are a player moving a control, a handful per
session. These are continuous -- several hundred lines a minute per lit unit.
The init line reports the tuning and nothing else does.

**THE ZERO GUARD ON `huePeriod` ALSO REFUSES A NEGATIVE ONE, AND THAT MAY BE
WRONG NOW.** It was written when a backwards sweep looked like a typo. Reversing
the direction turned out to be a thing somebody wanted on the first day, and a
negative period is the obvious way to ask for it -- so the guard should probably
refuse zero only. Left as it is until somebody decides.

### A textbox inside a list row, and the click it never receives
`arch.pane.rowfocus` -- see also `fact.pane.rowdispatch`, `dead.pane.rowzlevel`, `dd.pane.fieldbooks`

**BUILT 2026-09-03, AND IT IS THE FIRST TEXTBOX THIS MOD HAS PUT IN A LIST ROW.**
It constructs, which was the open question -- two rules collide and the answer
was only ever inferred. A textbox's callback must resolve at CONSTRUCTION, and a
row widget's callback resolves only against names registered with
`widget.registerMemberCallback` before the first `addListItem`. Register first
and it builds; get it wrong and the pane does not open at all.

**THE CALLBACK IS A NO-OP AND THAT IS DELIBERATE.** A member callback is handed
the leaf name, identical on every row, so a row textbox cannot identify itself.
Reading is done by a poll from `update` that walks the rows and already knows
each one's channel -- which also avoids `widget.setData` on a textbox, unverified
here.

**THE FIELD NEVER GETS THE LEFT CLICK, AND NO CONFIG CHANGE FIXES THAT** -- see
`fact.pane.rowdispatch` for what the source says and `dead.pane.rowzlevel` for
the two attempts that failed. `rowButton` takes the press and hands focus over:

    settingsRowClicked -> widget.focus(path .. ".settingField")

That keeps the hover the button exists for -- a list row has no hover of its own
-- and makes the WHOLE ROW a target for the field rather than a 26-pixel strip.

**AND NOTHING EVER LET GO.** A focused textbox captures the keyboard, Enter
included, so with a colour field focused the chat key stopped working. Blurring
happens on a click on any other row, separators included, and on any tab change
-- before `activeTab` moves, so the rows it walks are still the ones on screen.
Enter is NOT a way out; see `fact.pane.textboxpoll` for why that route is closed.

**IT COVERS THE RENAME FIELD TOO, WHICH HAD THE FAULT FIRST.** `tbPetName` has
shipped since 2026-09-01 holding the keyboard the same way; the colour rows only
made it noticeable. `blurPaneFields` releases both kinds, and the Rename button
releases its own field after committing -- pressing a commit button is the least
ambiguous "done with this" in the pane, so the caret should not survive it.


### Fuel burns while working, and only while working
`arch.fuel.burn` -- see also `dd.fuel.hungerwhileworking`, `dd.fuel.fedproductive`, `arch.fuel.eat`

**BUILT 2026-09-03.** `petports_fuel` is a resource of the mod's own, declared in
every monstertype at `maxValue 900, defaultPercentage 100`, and burned by
`burnFuel` at the head of `petportsTaskAction.update`.

**IT IS NOT VANILLA'S `hunger`, AND THAT SUPERSEDES `dd.fuel.hungerwhileworking`.**
That entry chose to reuse the real resource because "everything downstream keeps
reading it, so `hungerStarvingLevel` and `scoreAction` need no changes". True
while hunger counted UP. The bar counts DOWN -- 900 full, 0 empty -- so the
premise is gone, and redefining `hunger` to mean fullness would leave
`status.resource("hunger")` returning its own opposite forever to save one
declaration.

**900 AT 1.0/SEC IS FIFTEEN MINUTES OF UPTIME.** The rate is
`petports_fuelDrain`, per chassis, and an efficiency module divides it -- the
hook is marked in `burnFuel` and the divisor is 1 until those items exist.

**`petResourceDeltas.hunger` IS PINNED TO 0, NOT DELETED.** Absent means
`groundPet.lua`'s `tickResources` never touches it, which is the same result by
accident rather than on purpose, and a zero is where a reader looks when asking
why hunger never moves.

**STATION-KEEPING IS NOT WORK.** The burn is gated on `task.port ~= nil`, which
is the line the file already drew between dispatched work and a leash task. A
parked fleet is free and so is a unit walking home, both verified in game.

**MIGRATION IS NOT DECORATION.** `groundPet.lua` seeds `storage.petResources`
once with `or config.getParameter`, so a unit predating this has no such key.
The resource is fine -- `defaultPercentage` fills it -- but `petResources()`
enumerates that table to build the sync the port mirrors, so `burnFuel` writes
the key on the first worked tick or the pane draws an empty bar forever.

**`eatAction.lua` AND `begAction.lua` ARE OUT OF ALL FIVE SCRIPTS LISTS.** Safe
because `performAction` guards with `if petBehavior.actions[action.type]`, so
`reactToItemDrop` and `reactToPlayer` still queue `eat` and `beg`, find nothing
registered, and short-circuit before touching `actionCooldowns`. Vanilla's
`itemFoodLiking` rejects any item whose type is not `consumable`, and treats are
plain items, so that path could never have eaten one anyway.

**THE FIRST AND LAST BLIP ARE WORTH HALF OF THE OTHER EIGHTEEN.**
`paneFuelBlips` ROUNDS rather than floors -- `floor(fuel / 900 * 20 + 0.5)` --
so the count falls from 20 to 19 at 877.5 fuel, after 22.5 spent, not 45.
Timing the first blip to measure a burn rate therefore reads roughly half the
true interval, which is how a correct tier-3 module looked wrong on a
stopwatch. MEASURE THE RESOURCE, NOT THE BAR: set it to 900, work for a
measured minute, read `status.resource("petports_fuel")` -- about 840 bare
against about 864 at tier 3. The rounding is defensible, since a lit blip
meaning "at least half a blip left" keeps the bar off empty while a unit still
has fuel; it is just not uniform and nothing in the pane says so.

**`PANE_FUEL_MAX = 900` IN THE PORT IS THE ONE NUMBER WRITTEN DOWN TWICE.** It
must equal `petports_fuel.maxValue` in every monstertype. `paneFuelBlips` runs
off cached `petData` with no unit present -- the whole point of the mirror --
and the sync carries values, not ceilings. If they disagree the bar is wrong and
nothing errors.

### One treat, one call, and the unit decides what it is worth
`arch.fuel.eat` -- see also `arch.fuel.preference`, `dd.fuel.selffeed`, `dd.fuel.flavor`

**BUILT 2026-09-03. MANUAL AND AUTOMATIC.** `petports_feedFuel(descriptor,
sparing)` refuses anything without the `petports_fuel` tag and returns ONE
TABLE -- `{ amount, flavor }`, or nil. 60 plain, 120 preferred.

**ALL THREE SOURCES NOW EXIST.** This entry said for one day that the
thrown-on-the-ground source in `dd.fuel.selffeed` was still unbuilt; it landed
on 2026-09-03 -- see `arch.fuel.groundfeed`, which is also where the reason
nothing had looked at the ground since `eatAction.lua` was removed is recorded.

**ONE TABLE BECAUSE `callScriptedEntity` DOES NOT CARRY A SECOND RETURN.** It
returned `amount, flavor` for one build and the port saw the amount and never
the flavor: totals counted, every per-flavor row stayed at zero. Every other
call site in the mod binds `ok, oneValue`, so there was no working example to
copy and the assumption went in untested. DO NOT GO BACK TO MULTIPLE RETURNS.

**THE PORT FORWARDS AND DECIDES NOTHING.** What a treat is worth depends on the
unit's seed and its chassis's eligibility list, both of which live unit-side.
Resolving it in the port would be a second copy of `petports_preferredFlavor`
answering the same question -- the split `arch.pathing.oneanchor` exists to warn
about.

**A PARTIAL SWALLOW IS A FULL TREAT WHEN A PLAYER CHOSE IT, AND A REFUSAL WHEN
NOBODY DID.** The `sparing` argument is what tells them apart, and the
automatic path passes it.

Manual: a unit at 899 of 900 eats a preferred treat, gains 1, and the rest is
lost. Refusing would mean a nearly-full unit cannot be topped up before a long
job, and with a refusal sound wired the player reads that as a broken slot.

**THE AUTOMATIC PATH SHIPPED DOING THE MANUAL THING AND IT WAS MEASURED.** A
fetched meal from 217.98 took five clean 120s and then a sixth treat that
delivered 82.02 -- 37.98 burned, every meal, by a unit nobody was watching.
`dd.fuel.autoeat` had said not to do this before the code existed; the headroom
check went into the GENERATOR, which decides whether a trip is worth making,
and not into the meal, which feeds until the unit refuses. The unit only
refuses when completely full.

**THE TEST IS UNIT-SIDE BECAUSE NOTHING ELSE HAS A LIVE NUMBER.** The port
mirrors fuel on the anchor tick, stale after the first bite of a loop that eats
six. CONSEQUENCE: an automatic meal now ends a little UNDER the cap rather than
exactly at it, which is correct and is not a failed top-up.

**THE CURSOR IS DEBITED ON THE ANSWER, NOT ON THE CLICK.** `tell` discards what
`world.sendEntityMessage` returns, so the first version fed one treat forever:
the pane read the cursor and never took anything. `feedSlotClicked` now holds
the promise and `pollFeed` debits exactly ONE on a confirmed true, mirroring
`pendingTake`. It re-reads the cursor rather than trusting the remembered stack,
because a player can move it while the message is in flight.

**IT EATS A MEAL, NOT A BITE.** The first version ate the single treat it walked
for, left at 285 of 900, was then above the 25% mark and never came back -- a
unit topped itself up by one treat, forever. `feedFromCrate` now drains the
crate in preference order until the unit refuses, sharing `fuelTreatOrder` with
the generator so the trip and the meal cannot disagree about which flavor is
better. `FUEL_MEAL_LIMIT` is a bug-stop, not a balance number.

**TREATS ARE COUNTED BY FLAVOR, THE SAME WAY FISH ARE COUNTED BY TIER.** `fed`
plus a `fed_<flavor>` key each, walked out of `stats` into `fedFlavors`. The
pane takes its baseline from the flavor MANIFEST rather than a hardcoded list
the way `FISH_RARITIES` must, because flavors are ours. `countFed` logs loudly
on a missing flavor, because a total that climbs while the rows stay at zero is
indistinguishable from a player who never made one -- which is exactly how the
two-return bug hid.

**EVERY REFUSAL SOUNDS THE SAME, DELIBERATELY.** Not a treat, full unit and
despawned unit all mean "that did not happen". Telling them apart needs a reason
string over the wire for a distinction the player does not act on differently.

**THE SLOT IS INVISIBLE AND THAT IS NOT A BUG YET.** `feedSlot` sits on the
Details tab at `[240, 116]`, and an empty `itemslot` draws no art of its own, so
it is a 16x16 hitbox on bare background. It needs a backing image -- see
`todo.art.panes`.

### Feeding from the ground and from its own hands -- BUILT AND VERIFIED
`arch.fuel.groundfeed` -- see also `arch.fuel.eat`, `dd.fuel.selffeed`, `dd.fuel.autoeat`, `dd.fuel.nibblerestock`, `dead.fuel.eataction`

`dd.fuel.selffeed`'s third source. Built 2026-09-03, verified the same day.

**TWO MECHANISMS, AND THE COMPOSITION IS THE DESIGN.** Neither is a new task
type; between them there is no new act and no unit-side change at all.

  - **`nibbleFromCargo()`** -- a FEEDER, not a generator. Runs on the work tick
    before the scans and before `findWork`. Under the mark and holding a treat
    means it eats where it stands; no dispatch, no walking.
  - **`fuelGroundWork()`** -- a generator that dispatches an ORDINARY `collect`
    at a treat drop. The unit takes it as it takes any drop, cargo receives it,
    the feeder eats it on the next tick, the remainder deposits normally.

**"EAT WHAT YOU PICK UP, DEPOSIT THE REST" IS AN EMERGENT PROPERTY**, not a
third thing that does both. MEASURED: a unit at zero took a stack of 203 plain
treats, ate 15 and deposited 188. 15 x 60 is exactly 900, so `sparing` stopped
it precisely at the cap with nothing wasted and `FUEL_MEAL_LIMIT` was never
approached.

**BEING A FEEDER RATHER THAN A GENERATOR IS WHY THE UPCYCLER PATH CAME FREE.**
`nibbleFromCargo` catches a treat arriving in cargo from ANY source. MEASURED:
the machine-output generator tidied a savory out of an upcycler's slot 3 at
15:38:31.360 and the unit ate it 69ms later -- `ate petports_petfuel_savory
(savory) for 120 fuel (prefers savory), now 199.83`. Nothing was written for
that case and nothing needs to be.

**THE GROUND RUNG SITS ABOVE `fuelFetchWork` AND BOTH SIT ABOVE THE FUEL GATE.**
Above the crate on perishability -- a treat on the floor is free and on a
despawn timer where a crate is neither, the same argument that puts collect
above harvest. Above the gate because that placement is what makes zero
recoverable, and it is inherited from `fuelFetchWork` rather than restated.

**NO PARTICIPATION GROUP.** Eating is not hauling. A player who unticks Item
Pickup has said nothing about whether their pet may feed itself.

**NO DEFERRAL TO A CLOSER UNIT, unlike `collectionWork`.** Deferral asks whether
somebody else would do this better; a hungry unit is asking for itself.

**EMPTY CARGO ONLY on the ground rung**, which is the ordering working rather
than a limitation: a unit already holding a treat has had it eaten by the
feeder, and a unit holding anything else deposits first, since deposit is also
above the gate. What that leaves uncovered is a starving unit holding a rock
with NO deposit beacon anywhere -- which belongs to the opportunistic unit-side
grab and is why that mechanism is worth building separately. That grab is now
built: `arch.fuel.runandmunch`.

**ELIGIBILITY IS THE `petports_fuel` TAG, NOT A NAME LIST.** `isTreat` asks
exactly what `petports_feedFuel` asks, so the port's idea of a treat and the
unit's cannot drift, and a third party's treat works with no entry anywhere.
`fuelTreatOrder` is still right for choosing a CRATE, because that needs names
to hand to `containerAvailable`.

**KNOWN AND ACCEPTED: the mirror is one tick stale after a bite.** The feeder
moves the unit's real resource; `petportFuelled()` reads the mirror. Observed
twice in 12,876 lines -- a unit ate at 15:35:08.760 and the port said "out of
fuel" 10ms later, correcting on the next work tick. Ruled cosmetic 2026-09-03:
a starving unit missing one dispatch tick because it is busy eating is fine.

### Run and munch -- BUILT AND VERIFIED
`arch.fuel.runandmunch` -- see also `arch.fuel.groundfeed`, `dd.fuel.selffeed`, `dead.fuel.eataction`, `arch.fuel.eat`

The emergency food ingress, and the half of `dd.fuel.selffeed` that
`arch.fuel.groundfeed` cannot cover. Built and verified 2026-09-03.

**IT EXISTS BECAUSE THE DISPATCHED HALF CANNOT HELP A BUSY UNIT.**
`fuelGroundWork` sends a unit at a treat, which means taking on a task -- and a
unit already carrying one must not, and the rung refuses outright while the
unit holds cargo. A treat thrown in front of a working unit was therefore
invisible to the entire fuel system.

**IT INTERRUPTS NOTHING, AND THAT IS THE WHOLE DESIGN.** A radius check on a
timer: no state machine, no queued action, no yield, no change to where the unit
is walking. It sits beside `burnFuel` at the top of `petportsTaskAction.update`
for the same stated reason -- it must run on every tick the state holds the
unit, whichever branch that tick leaves through, and nothing it does can change
what that branch decides.

**IT IS IN update() AND NOT IN petBehavior.run FOR A RECORDED REASON.**
`petports_petBehavior.lua` says of `run()`: CADENCE IS UNVERIFIED -- DO NOT HANG
TIMERS OFF THIS. It may be called on the querySurroundings cooldown rather than
per tick, and a one-second timer built on it would run at some unknown multiple.
`update()`'s dt is verified, and it always runs, because `petports_leashTask`
never returns nil for a tethered unit.

`MUNCH_INTERVAL` 1.0, `MUNCH_RADIUS` 3.0 -- vanilla's inert eat action declared
distance 2; three tiles catches a treat thrown at a moving unit and stays "food
in front of me" rather than a collection mechanic that outcompetes the
dispatched one.

**IT READS THE UNIT'S OWN RESOURCE**, which makes it the one place in the fuel
system with a live number and no staleness -- see the mirror-lag note in
`arch.fuel.groundfeed`.

**THE REMAINDER RULE IS INVERTED FROM HOW IT WAS ASKED FOR, DELIBERATELY.** The
brief was "spit it out if we are on our way to acquire an item". Written
literally that is a list of the acquiring task types -- collect, withdraw, fuel,
drain, tidy, fish -- which whoever writes the NEXT generator has to remember to
extend, and forgetting is SILENT: the unit fills its one cargo slot and the
errand fails on arrival with nothing in the log pointing here. So `munchMayHold`
tests the opposite and only an IDLE unit keeps the remainder -- no task, no
port, or the leash's hold task. Everything else puts it on the floor, where it
is an ordinary drop that collection or `fuelGroundWork` takes later. Wrong that
way costs a walk; wrong the other way blocks an errand.

**A CLAIMED DROP IS LEFT ALONE.** `petports_work.lua` is in every chassis's
scripts list and loads before the task action, so `petports_claimGet` is
readable unit-side. Snatching a drop another unit was dispatched at WORKS, and
leaves that unit arriving at nothing and taking a backoff on a drop that no
longer exists.

**CARGO ARRIVES OUTSIDE A TASK REPORT FOR THE FIRST TIME.** Every other route
into cargo is a task completing, because every other pickup was dispatched.
`petports_cargoHandoff` on the port is the ingress for a pickup nobody ordered;
it calls `receiveCargo` rather than writing `petData`, so the stack merge, the
`flushCargo` persist and the ITEM LOST error all come along unchanged. The unit
addresses it with `self.anchorId`, which is VANILLA'S field -- `groundPet`'s
`setAnchor` sets it and `updateAnchor` re-verifies it every second, and the
headpat send already uses it.

**MEASURED, BOTH BRANCHES:**

    took 188 petports_petfuel, ate 14, 174 left (task upcycle:32)

14 x 60 is 840 and it refused the fifteenth, so `sparing` stopped it one treat
short of overflowing the 900 cap rather than burning ~780 of a treat for
partial value. `upcycle:32` is a dispatched task, so the 174 went to the floor
rather than into the cargo slot that delivery needed. The holding branch is the
203-treat run recorded in `arch.fuel.groundfeed`.

**THE SPAT STACK MOVES, AND THIS IS NOT A BUG.** The unit takes it where it
finds it and puts the remainder at its own feet a fraction of a second later, so
it ends up slightly along the unit's path with a fresh despawn timer. It cannot
drag repeatedly: the unit is full by the time it puts the remainder down, and
the 25% gate stops the next pass.

**`MUNCH_LOW` IS 0.25 WRITTEN DOWN A SECOND TIME.** `PETPORTS_FUEL_LOW` is a
port global and this is the monster's environment. Exactly the `PANE_FUEL_MAX`
hazard: nothing errors if they disagree. If one moves, move both.

### Preferred flavor, derived from the seed, resolved in one place
`arch.fuel.preference` -- see also `arch.fuel.eat`, `dd.fuel.flavor`, `arch.pathing.oneanchor`

**BUILT 2026-09-03.** `petports_preferredFlavor(seed, eligible)` and
`petports_flavorEligible` live in `petports_flavors.lua`; `petports_unitFlavor`
in the contract latches the answer in unit `storage`.

**ELIGIBILITY IS THE CHASSIS'S, NOT THE SEED'S.** A monstertype may declare
`petports_fuelFlavors` to narrow what it can ever crave -- "ants enjoy sugar",
and a dog-shaped unit never rolls a seeded craving for chocolate. Absent or
empty means all flavors, which is what every chassis ships with today. A
specialised fleet juggles fewer flavors but competes harder for them.

**MODULO OVER THE ELIGIBLE LIST, NOT OVER SEVEN.** A modlist that removes a
flavor shortens the list and the modulo lands elsewhere, so no unit is left
preferring an item that can no longer be made.

**LATCHED, AND RE-ROLLED ONLY ON INVALIDATION.** Deriving live would reshuffle
every unit's favourite whenever the eligible set changed, including when it
GREW and the old answer was still perfectly valid. The latch means a modlist
change moves one unit's favourite rather than all of them.

**KNOWN LIMIT: THE LATCH IS UNIT `storage`, WHICH DIES WITH THE UNIT.** A recall
and redeploy re-derives from the same seed, so the answer is identical unless
eligibility changed in between -- in which case a redeploy reshuffles where a
live unit would not have. Small, and worth knowing before it is reported as a
bug.

**`petports_flavors.lua` HAD TO BE ADDED TO ALL FIVE SCRIPTS LISTS.** Only the
port, the upcycler and the two panes required it, because until eating existed
nothing unit-side asked a flavor question. Safe to load there: no requires, no
top-level work, manifest lazy behind a `pcall`.

**THE READOUT IS LIVE, AND IT TOOK THREE HOOKS AND A DUPLICATE KEY TO GET
THERE.** `detailsFlavorValue`, the pane's setter and `mirrorPaneState`'s
`flavor` key were all laid down in advance for a feature that did not exist,
and all three had been sitting on a value nobody produced.

**WIRING IT ADDED A SECOND `flavor` KEY TO THE SAME TABLE INSTEAD OF FINDING
THE FIRST**, and a later key overwrites an earlier one -- so the value was
computed correctly on every mirror write and thrown away one line later. The
readout kept showing `--` through three builds that all looked right in the
log. ONE KEY PER FIELD IN THAT CONSTRUCTOR; it now holds 26 and no duplicates.

**THE PANE RESOLVES THE WORDING, THE PORT SENDS THE ID.** `flavorLabel` reads
`label` from the manifest, so the Details readout and the stats rows match the
upcycler. The capitalise fallback is not dead code: `plain` has no manifest
entry at all.

### Modules can declare a family, and two from one family cannot be socketed
`arch.module.exclusivity` -- see also `arch.module.hydrator`, `arch.fuel.efficiency`

**BUILT 2026-09-03, VERIFIED IN GAME.** An item may carry
`mutualExclusivityCategories`, a list of names. The three lamps all say
`light`; the three efficiency tiers all say `fuelEfficiency`.

**`petports_moduleSetDuplicate` GREW A SECOND RETURN AND KEPT ITS FIRST.** It
still answers with the offending item name, and now optionally the category, so
a caller that ignores the second value behaves exactly as before -- neither call
site HAD to change. Both did, only to tell the two cases apart in the log. The
player sees one refusal either way: the cursor keeps the item, the slot does not
change, the refuse sound plays.

**IT DOES NOT CONTRADICT THAT FILE'S REJECTION OF A UNIQUENESS FLAG**, and the
header records why. That argument was that a module wanting uniqueness and not
SAYING so would behave differently from one that did, for no visible reason --
true, because uniqueness is a property every module either has or has not. A
category is not like that: a module is in a family or in none, and absent
genuinely means none. There is nothing to forget.

**READ WITH `root.itemConfig`, NOT FROM A TABLE.** A third party can put a
module in the `light` family without being listed anywhere, and the pane and the
port ask the same question of the same asset -- the property the whole file
exists for.

### Fuel Efficiency I, II and III
`arch.fuel.efficiency` -- see also `arch.fuel.burn`, `arch.module.exclusivity`, `arch.module.hydrator`

**BUILT 2026-09-03.** Three items, Common / Uncommon / Rare, carrying flags
`fuelefficiency1..3` and nothing else. `FUEL_EFFICIENCY_BONUS` in the port holds
120 / 300 / 600 seconds; `petportFuelScale` returns `900 / (900 + bonus)`.

**AUTHORED AS UPTIME SECONDS, NOT AS MULTIPLIERS.** The decision was "+2, +5 and
+10 minutes on a full tank". Tier 1's multiplier is 0.88235..., which nobody can
read, check or retune with confidence, so the table holds the number that was
actually decided and the rate is derived from it.

**SLOWER BURN, NOT A BIGGER TANK, AND THE DIFFERENCE IS THE POINT.** Both reach
17 / 20 / 25 minutes on a full tank. Only slower burn makes a TREAT worth more:
at tier 3 a 60-fuel plain treat buys 100 seconds of work instead of 60, which is
what the roster means by "more work per food".

**THE SCALE RIDES ON THE EXISTING MODULE PUSH.** It is derived entirely from the
flags, which are already in that push's signature, so a module swap re-pushes it
and nothing else can change it. No new message and no new hook.

**THE UNIT'S FALLBACK IS 1.0 AND MUST STAY 1.0.** `self.petportsFuelScale` is
nil until the port has pushed once. A nil read as zero would make every unit
that has not yet had a module push burn nothing and run forever.

**BEST TIER, NOT SUM, EVEN THOUGH THE CATEGORY MAKES TWO IMPOSSIBLE.** A rule
that leans on another rule holding is one refactor from being wrong, and two
tiers stacking to 25 minutes would be a silent balance change rather than an
error.

**THE ICONS DO NOT EXIST.** All three point at `petports_module_light.png` so
they load and can be tested, which is what the RGB item's own comment
recommends.

### The fishing spawner is a merge of two forks, not a copy of either
`arch.fishing.spawner` -- see also `arch.fishing.lure`, `arch.fishing.dispatch`

**BUILT 2026-09-01, SHIPPED, AND UNDOCUMENTED UNTIL 2026-09-03** -- see
`proc.tooling.gapcheck` for how a whole subsystem went unwritten.

`petports_fishingspawner.lua` merges vanilla's `/scripts/fishing/
fishingspawner.lua` with Project Irisil's `lofty_irisil_fancyfishingspawner.lua`.
Vanilla picks fish by BIOME -- `world.type()` must have a pool, the position must
be minDepth below ocean level, split shallow/deep and day/night. Irisil picks by
LIQUID ID and lure type from parameters a zone stagehand pushes in, with no biome
or depth test at all.

**WHY BOTH.** Vanilla alone means fishing works only on ocean, toxic, arctic and
magma worlds -- a base pond on a forest world is unfishable however deep it is
dug, because `world.type()` decides before position is consulted. That is a
severe restriction for a base-automation mod. Irisil alone works only inside a
hand-placed dungeon zone, which is right for a content mod shipping those
dungeons and useless for a port dropped in open sea.

**IT STARTS IN VANILLA MODE AND NEVER SWITCHES BACK.** Zone parameters arrive by
message or never arrive; `setParams` switches it, and a lure told about a zone is
in that zone.

**NO DEPENDENCY IN EITHER DIRECTION.** It reads vanilla's config for its own mode
and accepts a zone table for the other; it never requires Irisil's files. If
Irisil is installed its zones push parameters at our lure because they broadcast
to every projectile in range -- WE DO NOT GO LOOKING, THEY FIND US.

**THE GLOBAL IS `PetportsFishingSpawner` ON PURPOSE.** Vanilla and Irisil BOTH
define `FishingSpawner` and already collide silently, last require winning.
Adding a third would break rod fishing for anyone running both.

**THE BIAS OVERRIDE IS WHY THE FORK EXISTS AT ALL.** Both upstreams seed
`spawnBias` from `initialBias` (0.2 in vanilla's) and drop it per successful
spawn. The roll is `math.random() + spawnBias` against 0.001 / 0.04 / 0.2 / 100,
so at bias 0.2 legendary, rare and uncommon are not improbable -- they are
UNREACHABLE. Fine for a rod, wrong for a port: a player burns the bias off in two
catches, while a petport lure lives two to five minutes, holds one fish, and is replaced
by a fresh lure with a fresh spawner -- resetting the bias faster than it could
decay. The lure passes 0. `nil` means "use the config's", so an indifferent
caller gets upstream behaviour.

**THE BACKGROUND-MATERIAL TEST APPLIES IN VANILLA MODE ONLY.** Vanilla refuses a
spawn point in front of background blocks, keeping fish out of the walls of a
build. A hand-placed dungeon pool is background-walled BY CONSTRUCTION, so
applying it in zone mode would refuse every position in the zone -- which is why
Irisil dropped it, not because it is wrong.

**THE TIER NAME COMES BACK WITH THE FISH**, because it is knowable only inside
the pick: nothing downstream can recover "rare" from a monster type without
re-deriving the whole table. The port wants it for per-rarity statistics.

### The lure is the spawner, and the teleport is why it is not vanilla's
`arch.fishing.lure` -- see also `arch.fishing.spawner`, `arch.fishing.dispatch`

**BUILT 2026-09-01.** A fork of `/projectiles/fishing/fishinglure.lua`. The
spawner lives on the LURE -- not the rod, not the port -- and spawns a fish every
few seconds for as long as it sits in liquid.

**REMOVED FROM VANILLA'S:** rod controls and line maths (there is no rod);
`rotation` and `linePosition` (no rod, no rope); and `fleeFromLure`, which
vanilla broadcasts to every monster within 9 tiles every second to scare wildlife
off a fishing spot -- `world.monsterQuery` RETURNS OUR OWN UNITS, and a lure that
shouts at the fleet is not wanted even while nothing answers it.

**ADDED:** one fish at a time (enforced here because this is what knows whether
its fish is still alive); horizontal patrol reversing at walls, dry water and the
edge of coverage; a coverage rect it may not leave; and the teleport.

**THE TELEPORT IS THE WHOLE REASON THE FILE EXISTS.** A fish that cannot hook
darts at the lure forever, so the lure moves away from one that has closed in.
**LINE OF SIGHT IS CHECKED AND IT IS NOT OPTIONAL**: the fish's own `updateLure`
despawns it outright when `world.lineTileCollision(fishPos, lurePos)` is true, so
a teleport landing behind terrain does not move the lure away from the fish, it
KILLS the fish. Every candidate is tested from the FISH'S position. Failing means
staying put, which is the safe direction -- an oscillating fish looks bad, a fish
deleted by its own lure is worse.

**LURKER VERSUS APPROACHER IS DECIDED BY WHICH SCRIPT THE MONSTERTYPE LISTS**,
not by a parameter: `approachState.enter` and `lurkState.enter` both gate on
`storage.stateStage == "approach"`. It matters because a lurker outside
biteDistance idles FACING the lure via `setBodyDirection(self.toLure)`, so a lure
well above or below leaves it angled at the sky or the seabed. An approacher's
facing follows its travel and the same offset reads as normal swimming. Read once
per fish and cached -- `root.monsterParameters` is cheap but not free and the
answer cannot change for a type.

**PATROL DRIVES POSITION, NOT VELOCITY.** A force fighting the fishinglure
physics profile's gravity lost slowly and the lure sank the entire time it was
alive; `petports_patrolForce` was removed with that approach.

**COVERAGE IS A LIST OF RECTS, NOT ONE.** The first build took a single rect and
clamped the lure to the port that spawned it, which is visibly wrong the moment
two ports share water -- fish could only appear in one of them. Empty or absent
means unbounded, which is what makes the lure testable by hand with
`/spawnprojectile`.

**THE PORT IS THE SOURCE ENTITY, WHICH BUYS TEARDOWN FOR FREE.** Vanilla's update
already ends with `else projectile.die()` when the source is gone, so breaking or
unloading a port kills the lure, which nils its fish's `lureId`, which lets the
fish despawn itself. Nothing holds a reference to anything.

### One lure per port, and the port never chooses the fish
`arch.fishing.dispatch` -- see also `arch.fishing.lure`, `arch.fishing.network`, `arch.dispatch.eligibility`

**BUILT 2026-09-01.** `lureWork` keeps exactly one lure alive while the socketed
unit can fish; `fishWork` dispatches at whatever the lure reports.

**THE MODULE IS THE ONLY SWITCH.** No participation group, no port checkbox: a
player who does not want fish unsockets the module.

**ONE LURE, NOT ONE FISH.** The lure enforces its own budget because it is the
only thing that knows both that it spawned a fish and whether that fish is still
alive. The port never asks.

**NOTHING IS PERSISTED.** `self.lureId` dies with the chunk, which is correct --
the lure is spawned with the port as source entity and vanilla kills a lure whose
source is gone. A reloaded port finds no lure and makes a new one; there is no
stale id to reconcile and no cleanup pass to write.

**IT SITS ABOVE HARVEST IN THE LADDER BECAUSE ITS TARGET EXPIRES ON ITS OWN.**
Every other generator names a crop, crate, drop or animal, all of which wait
indefinitely. A fish times out on its approach window, swims out of coverage, or
loses sight of its lure and despawns -- so a dispatch that is merely slow is a
dispatch that produces nothing.

**~~NO CLAIM, DELIBERATELY.~~ SUPERSEDED 2026-09-03 by `arch.fishing.network`.**
It read: two ports sharing water each run their own lure, and there is only ever
one candidate and one reason -- which is also why there is no reject-reason tally
like `animalWork`'s.

That was true of the REPORT and was never true of the WATER. The lure was
already placed anywhere in the network, so two ports on one pond were already
spawning fish into each other's coverage; only the report was port-local, and
what looked like an absence of contention was an absence of VISIBILITY. There is
now a claim, a rank and a reject tally, and this entry's own condition for
needing one -- "the day a fish is visible to a port that did not spawn it" --
turned out to have been met on the day it was written.

**SPAWN RATE IS A QUARTER OF VANILLA'S, AND THE LURE'S LIFE IS NOW A RANGE.**
Retuned 2026-09-03 -- see `dd.fishing.supply` for why, which is the more useful
entry. `spawnTimeRange` is `[8, 24]` and `FISHING_LURE_LIFETIME` is
`{ 120, 300 }`, drawn once per lure. The original reasoning, written when it was
`[4, 12]` against
vanilla's `{2, 6}`: a rod assumes a player casting, reeling and walking away,
while a petport lure sits for minutes and a unit catches in one to four. At
vanilla's rate the loop filled crates in minutes. It was never the only limiter
-- the lure holds one fish and the port refuses a carrying unit -- so lengthening
it stretches the first term only and does not scale throughput one for one.

**STATS ARE PER RARITY, ALWAYS SHOWN INCLUDING AT ZERO.** `fished` plus
`fishedTiers`, walked out of the stats table. `FISH_RARITIES` is hardcoded in the
pane because the tiers are NOT ours -- a zone declares its own -- which is the
one way the treat rows in `arch.fuel.eat` improve on this.

### A fish belongs to the network, not to the lure that spawned it
`arch.fishing.network` -- see also `arch.fishing.dispatch`, `arch.dispatch.union`, `arch.network.registry`, `todo.fishing.outofcover`, `dd.fishing.catchwindow`, `todo.fishing.medium`

**BUILT AND VERIFIED IN GAME 2026-09-03.** Two ports, one pond, one 3-minute
log: 24 dispatches, 14 catches, cross-port in BOTH directions, no double-catch,
backoff escalating correctly, no expired entries and no errors. The three things
it found are `todo.fishing.outofcover` (fixed), `fact.fishing.despawnwindow`
with `dd.fishing.catchwindow` (accepted), and `todo.fishing.backoffshared`
(deferred past 1.0).

`fishWork` walked `self.fishId` and
nothing else, so a unit could only ever be sent at a fish its OWN port's lure had
reported. Two ports on one pond fished past each other: each ignored a catchable
fish four tiles away and waited on its own lure to produce another.

**IT WAS THE LAST GENERATOR THAT HAD NEVER HAD THE UNION TREATMENT.**
`arch.dispatch.union` says every port scans the whole network's coverage and that
a union is a VIEW assembled at dispatch time. Every other generator walks
`self.networkRects`; the LURE is placed across `fishingRects()` and clamps its
patrol to the same list. So the fish was ALREADY network-wide in position and
port-local only in ownership -- which is why this reads as a missing view rather
than a missing capability.

**A WORLD PROPERTY, KEYED BY PORT.** `petports_fish[portUniqueId] =
{ id, type, rarity, expires }`. One entry per port because one lure holds one
fish, and the lure enforces that budget itself -- this is the publication of a
rule kept elsewhere, not a second copy of it.

**A PROPERTY AND NOT A MESSAGE**, for the reason `arch.network.registry` already
gives: no port ever messages another port, because membership derived from shared
state has no ordering problem and nothing to keep in sync. A fish is the same
shape of fact as a coverage rect -- one port knows it, every member needs it.

**AND NOT IN THE REGISTRY, WHICH IS THAT SAME ARGUMENT FROM THE OTHER END.** The
registry is written on change and NEVER on a tick, and every write bumps a
version that makes every port re-derive its network and re-gather its vents. A
lure produces a fish every few seconds. Putting one inside the other would turn a
change notification into a heartbeat, and that is a MEASURED failure in this file
already -- one empty port drove the version 788 times in sixty-five seconds.

**IT HOLDS AN ENTITY ID, WHICH IS WHY IT EXPIRES.** Ids are reassigned on load,
so a survivor from the last session names whatever now holds that number. Three
defences, and they are the ones claims already use: the owner withdraws its own
at `uninit`, again on its first update, and `petports_fishSweep` drops whatever
is left on the same slow timer as `petports_claimsSweep`.

**`uninit`, NOT `die()` -- THE OPPOSITE OF THE REGISTRY ENTRY, ON PURPOSE.** A
registry entry MUST survive a world unload or the network rebuilds itself from
nothing every reload. A fish entry must NOT: the lure and its fish die with the
chunk, so anything that survives is a dead id another member would dispatch at.
The two sit four lines apart in the same file and want opposite hooks.

**THE TTL IS THE LURE'S LIFETIME, AND THAT IS A CONSEQUENCE RATHER THAN A
TUNING.** A fish cannot outlive its lure -- the lure dying nils the fish's
`lureId`, which lets the fish despawn itself -- so an entry older than one lure
describes something that cannot exist. No refresh write, and one number instead
of two.

**THE CLAIM ARBITRATES, AND IT IS CHECKED INSIDE THE WALK.** That is what makes
two ports spread across two fish rather than race for one: a fish another member
holds is skipped and the ranking moves on. Testing it AFTER picking a winner
would refuse the whole tick instead, which is the starvation `dispatchable()`
exists to prevent.

**NO DISTANCE VETO, AND THAT IS A DELIBERATE DEPARTURE FROM
`anotherUnitIsCloser`.** Drops can afford one because `DEFER_GRACE` lets a
deferred drop be taken anyway after twelve seconds -- the work WAITS. A fish does
not. Standing aside for a unit that turns out to be walled off does not cost this
rung a delay, it costs the catch outright, and a caged unit permanently nearest
the water would mean the network never fishes again. Ranking by distance from the
UNIT and letting the claim settle the tie is the same arbitration with no way to
deadlock: the loser skips to the next fish, and a bad pick times out and backs
off on its own.

**THE TASK READS `fishType` AND `fishRarity` OFF THE ENTRY, NOT OFF `self`.**
Those two agree only while the fish came from our own lure, which is exactly what
stopped being true. A cross-port dispatch reading `self.fishType` would roll the
wrong `landedTreasurePool` and bank the catch under the wrong tier -- the bug
this change was most likely to ship with, and invisible in play because both
still produce loot.

**THE MODULE STILL GATES CATCHING, AND THAT IS A BALANCE DECISION LEFT ALONE.**
`petportCanFish` still asks `petportFishing()` first, so this bites when two or
more ports carry modules. Dropping that one line would let any submersible unit
in the network fish off a single module, which devalues the item and breaks
`arch.fishing.dispatch`'s "the module is the only switch" -- a balance change
rather than a dispatch one, so it was not made here.

**ONE THING CAME FREE.** A port holding a drone AND a fishing module places a
lure whose fish it can never reach itself. Before this, that was simply wasted;
now a neighbouring aquatic unit catches them.

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

### The automatic path must not waste treats, and must not graze
`dd.fuel.autoeat` -- see also `arch.fuel.eat`, `dd.fuel.selffeed`, `plan.fuel.storageread`

**DECIDED 2026-09-03, BEFORE THE WORK GENERATOR EXISTS**, because it is a
constraint ON that generator and the shape of it is already settled.

`arch.fuel.eat` lets a unit at 899 of 900 eat a 120 treat and throw away 119.
That is fine when a PLAYER does it -- they chose to, and refusing would mean a
nearly-full unit cannot be topped up before a long job. **A UNIT DOING IT TO
ITSELF, UNSUPERVISED, IS A DIFFERENT THING**: nobody chose it, it happens
repeatedly, and it burns a resource the player farmed.

**TWO RULES, AND NEITHER IS SUFFICIENT ALONE.**

- **A PER-TREAT HEADROOM CHECK.** The automatic path picks the treat, so it can
  compare that treat's value against the unit's real headroom and skip one it
  would waste. Manual feeding keeps its current behaviour.
- **A LOW-WATER MARK, or units graze.** Headroom alone means a unit eats
  whenever 60 fits -- so it stops and fetches roughly once a minute, forever.
  It must not go looking until it is BELOW the mark, then fill as far as it can.

**THE MARK IS 25%, REUSED RATHER THAN INVENTED.** `dd.fuel.selffeed` already
gates the thrown-on-the-ground source at "below 25% hunger only". One threshold
in the design beats two that drift. At 900 that is 225 -- comfortably more than
a preferred treat, so a unit that decides to eat can always take at least one
with no waste at all.

**CONSEQUENCE FOR `dd.fuel.fedproductive`, AND IT IS THE POINT.** Once this
exists, a fleet with treats in reach never reaches zero, so the `findWork` fuel
gate stops being ordinary behaviour and becomes the backstop for a network that
is genuinely out of food. The dry-unit behaviour verified on 2026-09-03 is the
FAILURE MODE, not the steady state.

### Hunger drains only while working
`dd.fuel.hungerwhileworking` -- see also `dd.fuel.fedproductive`

**PARTLY SUPERSEDED 2026-09-03 BY `arch.fuel.burn`.** The clock-versus-meter
answer below is BUILT and unchanged: the vanilla delta is zeroed and the
decrement is driven from `petportsTaskAction`. What did not survive is the
choice of resource. This entry reused vanilla `hunger` on the reasoning that
everything downstream keeps reading the real one -- which held only while hunger
counted UP. The bar counts DOWN, so `petports_fuel` is its own resource and the
sentence below about `hungerStarvingLevel` and `scoreAction` needing no changes
is now moot rather than wrong: both actions are out of the scripts lists.

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

### A hungry unit eats restock stock, and that is the feature
`dd.fuel.nibblerestock` -- see also `arch.fuel.groundfeed`, `dd.fuel.selffeed`

`nibbleFromCargo` runs before `findWork`, so a unit carrying treats to fill a
restock request eats them en route. OBSERVED 2026-09-03 against a live beacon
requesting all eight treat items at 100-1000 each.

**DECIDED KEPT.** A restock box for pet treats is where they would be going to
eat anyway, so the trip is not wasted so much as short-circuited. It also
incentivises a player, gently, to keep the fleet topped up.

**THE ARGUMENT AGAINST WAS CONSIDERED AND REJECTED:** that a restock
destination NOT marked as a pet feeder should be immune, so a player can stage
treats somewhere units will not raid. Coherent, and it would need the feeder
flag threaded from the destination beacon into a generator that does not
currently know which beacon its cargo is for. Not worth that for a case nobody
has wanted yet.

**THE CONSEQUENCE IS SHARP AND UNDOCUMENTED ANYWHERE A PLAYER LOOKS:** a treat
restock request can be starved indefinitely by a hungry fleet, and no log line
says that is why the crate never fills. Reopen as a pane hint rather than as a
behaviour change if anyone reports it.

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

### A settings row declares what ABSENT means, because it is not one answer
`dd.pane.settingdefault` -- see also `arch.pane.rename`, `arch.module.effects`

**MEASURED 2026-09-01 ON THREE LEGACY PETS.** The `nametag` box drew TICKED while
the port pushed `tag false` on the same tick. The checkbox was never wrong about
its own value; the two sides disagreed about what a MISSING value meant.

    pane   settingValue        store[key] ~= false   absent -> ON
    port   petportNametag()    toggles.nametag == true   absent -> OFF

**BOTH DEFAULTS ARE CORRECT FOR THEIR OWN ROWS, WHICH IS WHY THIS IS A DESIGN
DECISION AND NOT SIMPLY A BUG.** Medic and farming rows default ON so a freshly
socketed module works immediately instead of looking broken until six boxes are
ticked. Display toggles default OFF so shipping one does not label an entire base.
One shared `settingValue` could express only the first.

**DECLARED PER ROW, NOT INFERRED FROM THE OWNER.** Every `toggles` row wants false
today, so keying on owner would work and would be a COINCIDENCE -- the next module
setting that wants off-by-default sits under its own owner and would quietly get
the wrong answer.

**ONLY `nil` CONSULTS THE DEFAULT.** A present value reads exactly as before, so
nothing with a stored setting shifts.

**`carried` CARRIED THE IDENTICAL MISMATCH AND WAS INVISIBLE**, because nothing
reads that setting yet. It would have surfaced the day speech bubbles land. Fixed
at the same time.

**THE GENERAL TRAP:** a pane-side default and a port-side accessor are two
spellings of one rule, and they are written in different files by different
reflexes -- `~= false` reads as permissive, `== true` reads as careful. Adding a
setting means choosing the default ONCE and writing it on both sides deliberately.

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

### Some pathing faults are not ours to fix, and the line is the node graph
`dd.pathing.enginelimits` -- see also `dd.pathing.coststeering`, `dead.locomotion.pelagic`, `arch.pathing.mediumenforcement`, `proc.pathing.readsource`

**A SCOPE DECISION MADE 2026-08-31, AFTER A SESSION SPENT ALMOST ENTIRELY ON
PATHING.** Recorded because the alternative is rediscovering it one bug at a
time, each of which looks locally tractable.

**WHAT THIS MOD CAN DO.** Everything that sits AROUND the search. Which
destination is offered (`petports_flyPointNear`), whether a returned plan is
acceptable (`planMediumValid`), how a plan is executed (the replaced movers),
what a search costs (`petports_pathOptions`), and what happens when it returns
nothing (the fallback). All of that is Lua, all of it is ours, and every fix this
session landed in one of those places.

**WHAT IT CANNOT DO.** Change which nodes the search considers. The engine's A*
is C++, `world.platformerPathStart` takes movement parameters and hands back
edges, and there is no seam between those two points. So a fault that is a
property of the NODE GRAPH ITSELF cannot be fixed from here -- only detected,
priced, or refused after the fact.

**THE WORKED EXAMPLE, AND IT IS THE ONE THAT SETTLED THIS.** A clump of poison
inside a larger body of water. A swimmer should route around the poison and
through the water. Cost cannot express it: `swimCost` is a scalar over liquid,
not per liquid, so there is no way to make one liquid expensive and another
cheap. Validation can only REFUSE the route the search returns, and refusing
produces no motion -- see `dd.pathing.coststeering`, where the same asymmetry is
recorded for air. Routing around it ourselves means building a node graph, a
search over it, and an execution layer for its edges: rebuilding the pathfinder
to work around the pathfinder.

**THE RULE THAT FALLS OUT.** A pathing fault gets fixed when it is RELIABLY
REPRODUCIBLE in the test environment AND the lever is on our side of the C++
boundary. Otherwise it is recorded and left. Refusing to act is cheap here
because every refusal path already ends somewhere safe: the progress watchdog
fails the task, the port backs the target off, and `rehomeUnit` is the floor
under all of it.

**WHY THIS IS NOT DEFEATISM.** Every pathing bug closed in this session --
`fact.pathing.watercrossed`, `fact.pathing.platformfloor`,
`arch.pathing.mediumenforcement`, `arch.pathing.oneanchor` -- turned out to be
OUR code, not the engine's, in each case after an engine cause had been
suspected. The prior should stay "we broke it". This entry is about the residue
after that prior is exhausted, not a first resort.

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

### The door does not open until the port knows a unit can live there
`dd.port.envpresence` -- see also `dd.port.envuniform`, `fact.port.typecapabilities`, `arch.module.liquids`, `arch.unit.exitpaths`

**SUPERSEDES A DECISION THAT ONLY EVER EXISTED IN A CODE COMMENT**, at the socket
branch of `petports_petport.lua`:

    An unsuitable unit socketed into an unsuitable port still spawns and is
    retired within ENVIRONMENT_INTERVAL. That flicker is deliberate -- it is once
    per player action, and the retirement line says why, which is worth more than
    a silent refusal to spawn.

THE REASONING DID NOT BECOME WRONG. ITS INPUT CHANGED. That was written when a
spawn was a one-frame pop and a despawn was an instant kill, and a flicker was a
fair price for a log line explaining itself. The choreography made the flicker a
PERFORMANCE: door opens, unit materialises, several seconds pass, unit
dematerialises, door closes, forever, ending in nothing.

**THE HALF THAT WAS RIGHT SURVIVES.** The refusal still says why -- one log line
on the transition, and a pane diagnostic. `self.envRetired` is latched at the
moment the verdict is set so the pane can tell "retired" from "never deployed";
written unconditionally it would be true on the tick a unit is retired and false
five seconds later, quietly rewriting a retirement as a refusal.

**THREE THINGS HAD TO MOVE OR THE GATE BRICKS THE PORT:**

  - the re-measure that cleared `envUnsuitable` lived INSIDE the `hullState ==
    "open"` branch. Gate the door on the verdict and that code is unreachable
    exactly when it is needed, so a flooded port would never recover. Recovery
    moved onto the environment timer, which is where it belongs now that the
    check needs no unit.
  - the check moved ABOVE the door intent. Reading the verdict one line before
    writing it made a fresh placement into bad terrain twitch the hull open and
    shut.
  - `self.environmentTimer` is zeroed on socket alongside `spawnTimer`. A verdict
    arriving up to `ENVIRONMENT_INTERVAL` after the socket arrives after the door
    has opened -- the same bug, moved rather than fixed.

**A CONSEQUENCE NOBODY ASKED FOR, KEPT ON PURPOSE: FLOODING AN OCCUPIED PORT
EVACUATES ITS UNIT.** Emergent rather than designed -- it exists only because the
verdict is re-asked on a timer instead of at spawn. It is recorded here rather
than as a `plan` entry because it was never intended and is not being promised;
but a future change that makes the gate spawn-time-only would remove it without
anything noticing, which is the sort of loss this document exists to prevent.

Distinct from the module-pull case, which LOOKS the same and is not: a unit
withdrawn when its liquid permission is removed is the ordinary recall of
`arch.unit.exitpaths` reached through a new trigger, and that one was always the
intent.

**THE SPAWN GUARD STAYS EVEN THOUGH THE DOOR GATE MAKES IT NEARLY UNREACHABLE.**
During a dematerialise the hull is held open by `unitPresent` while `self.petId`
is already nil, which is exactly the shape the spawn block tests. Without its own
`envUnsuitable` check it would deploy a replacement into the terrain that just
retired the last one.

### A free mover needs its whole footprint to be one medium
`dd.port.envuniform` -- see also `dd.port.envpresence`, `dead.locomotion.pelagic`

`portMedia` reports `wet` and `dry` as "at least one tile of the footprint is
like this", so a port straddling a waterline reports BOTH. The ladder used to
read that as suitable for either chassis, justified in a comment duplicated
VERBATIM in two files:

    A port half in the water offers BOTH, and that is the right answer for both
    chassis -- a swimmer can sit in the flooded half, a flyer in the dry half,
    and neither has to be told which.

**NOBODY WAS EVER TOLD WHICH.** `spawnPet` spawns at `petSpawnOffset`, which is
`[0, 0]` -- the middle of a 4x4 footprint. Liquid fills bottom-up, so at a
half-flooded port the centre tile is under the waterline and the flyer
materialised submerged, into a closed node set it cannot path out of. The
sentence described a placement the code did not perform.

**MEASURED IN GAME 2026-08-30**, and not caught after the fact either:
`environmentCheck` asked the live unit the same footprint-level question, got
`wet true, dry true, fly true` back, and returned ok. The unit was stuck and
nothing retired it.

**ITS PREMISE WAS CHALLENGED 2026-08-30 AND IS RESTORED 2026-08-31 -- SEE
`fact.pathing.watercrossed`.** A gravity-disabled unit was observed crossing the
water boundary, which is the traversal "a closed node set it cannot path out of"
says is impossible. It was not the pathfinder: our own blind-steer fallback put
the unit in the air first, and every crossing plan started there. The closed-set
claim stands and this entry's reason is sound.

**UNIFORMITY WAS CHOSEN OVER A POSITION SEARCH.** Picking a suitable tile and
spawning there would have preserved the original intent, but it turns the verdict
into a position search and gives every caller a point to keep in step with.
Refusing a mixed footprint costs a port that is fifteen-sixteenths dry and buys a
rule with no gap in it.

**A CHASSIS THAT BOTH FLIES AND SWIMS IS TESTED FIRST** so uniformity never
refuses one. None of the four is both; the ladder must not encode an accident of
the current roster.

**THE THRESHOLD IS INHERITED, NOT CHOSEN.** `wet` means fill at or above
`ENVIRONMENT_SUBMERGED_FILL`, so a tile at 0.85 still reads dry and a flyer
accepts it. That matches `PETPORTS_SUBMERGED_FILL` on the unit at the same 0.9,
and the two agreeing is the property that matters.

**THE DUPLICATED COMMENT IS THE LESSON.** The false premise was written out in
full in `petports_habitat.lua` AND `petports_contract.lua`. Correcting one would
have left the disproven version standing above a function that no longer did it
-- prose drifting exactly the way the shared module exists to stop code drifting.
Only the module states the rule now.

**SCOPED 2026-08-31, NOT SUPERSEDED. THIS IS A RULE ABOUT A HOME.** Everything
above stands for a port, where the unit MUST occupy the whole footprint. It was
then applied to dispatch targets, where it is wrong -- a crate is touched, not
inhabited -- and it refused a half-submerged shipping container to both the
swimmer and the flyer. Targets run `petports_habitatAnyPointSuits` instead. See
`arch.dispatch.anytile`, which is the distinction this entry was missing rather
than a correction to it.

### Proliferation is intended
`dd.port.proliferation`

Nothing limits how many petports a player deploys, by design. Full automation
coverage requires several unit types, which is the point: it drives exploration
and questing to acquire unit items that make a permanent base more convenient.

This makes pets a payoff loop for the settlement and encounter work rather than
a self-contained ship feature, and it is the reason the "Low" priority the
roadmap assigns ship pets understates them.

### Units are destructible, and that is a departure
`dd.unit.destructible` -- see also `fact.unit.spawnoverride`, `fact.unit.damageteams`

**RESOLVED 2026-08-30: THE TEAM IS NOW `friendly`, NOT `ghostly`.** The
"UNVERIFIED" question below was answered by changing the answer. Ghostly sits
outside damage resolution entirely -- useful while the fleet was being brought up
and wrong once it matured. Ally detection also forced it: a ghostly unit's team
matches nothing, so every medic candidate would have failed.

**THE CONSEQUENCES LISTED BELOW ARE LIVE NOW, NOT HYPOTHETICAL.** In particular
the port still respawns a replacement after `RESPAWN_GRACE` as though nothing
happened, which this entry calls arguably wrong and which remains undecided.

**IT TOOK THREE ROUNDS TO LAND** because `spawnPet` was overriding the
monstertype -- see `fact.unit.spawnoverride`.


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
    appliesWeatherStatusEffects           true     (was false until 2026-08-30)
    minimumLiquidStatusEffectPercentage   0.1
    healthRegen                           0.0
    maxHealth                             72

LIQUID status effects apply from 10% submersion, which explains the observed
lava deaths on its own, and `healthRegen` 0 means nothing a unit survives ever
heals off.

**THE WEATHER FLAG CHANGED 2026-08-30 and the environment one did not.** Weather
effects now reach these units; environment effects still do not. The three gates
are independent -- see `fact.unit.weatherflag`.

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

### The otter switches gravity after all
`dd.locomotion.otterswitch` -- see also `arch.locomotion.swimmode`, `fact.unit.movementparams`, `fact.pathing.canpathfind`, `arch.locomotion.classes`

**DECIDED 2026-09-02, AND IT REVERSES A POSITION THIS DOCUMENT HELD IN THREE
PLACES.** `arch.locomotion.classes` calls the amphibious chassis "the otter" and
says it needed no transition code precisely because it never switches gravity at
runtime. `arch.locomotion.beached` repeats the objection: `PathFinder:start`
reads `baseParameters` and `mustEndOnGround` is captured at `PathMover:new`, so
flipping mid-route corrupts a live plan. Retired as a blanket rule: opened as
dd.locomotion.otter (retired).

**THE OBJECTION WAS CORRECT AND IS NOT A BAN, IT IS A CONSTRAINT ON TIMING.** A
flip underneath a live plan corrupts it; a flip immediately before the pather is
built has no live plan to corrupt. So the mode is chosen at exactly one place --
`freshPather` -- and anything wanting a mode change asks for a rebuild and gets
both, in that order. That is the same exemption `arch.locomotion.beached` already
claimed for a unit that has yielded its task.

**WHAT FORCED IT.** There is no seabed under a fish in open water, and every
walker resolver in the mod answers "where can a body stand". No amount of tuning
a walker gets it to a target that is not on the floor. The alternatives were a
second chassis or a mode; a mode reuses the entire free-mover stack that already
exists and is keyed off one boolean.

**WHAT IT COST, AND THIS IS THE PART WORTH REMEMBERING.** The flip alone was two
lines. Everything else was consequences of it: the permission flags had to be
declared, capabilities had to stop reporting the mode (`fact.port.capabilitiesstatic`),
the medium check had to be exempted, the flop state had to be locked out, two
`PathFinder` methods had to be shadowed, and the thresholds had to gain
hysteresis. A cheap switch with an expensive blast radius is still an expensive
switch.

### One module of a kind per unit, refused at the slot
`dd.module.oneofakind` -- see also `arch.module.slots`, `arch.module.hydrator`, `dd.module.writetoken`

**DECIDED AND BUILT 2026-09-03. THIS SUPERSEDES "TWO HYDRATORS ARE ONE
HYDRATOR"**, which `arch.module.hydrator` records as the honest outcome of
`moduleFieldUnion` deduplicating. It was honest and it was never good: a player
who socketed two paid a slot for nothing and the pane told them nothing.

**BLANKET, NOT A PER-ITEM UNIQUENESS FLAG.** A flag would have to be authored on
every module that wanted the rule, so a module that wanted it and did not say so
would behave differently for no reason a player could see. A blanket rule needs
no field, so a module added by anybody gets it free.

**REFUSED IN THE PANE, BEFORE THE CURSOR IS TAKEN.** `moduleSlotClicked` reads
the cursor with `player.swapSlotItem()` but does not take it until
`setSwapSlotItem`, so a refusal there is a bare return with the item where the
player left it. The port refuses too, but the port CANNOT refuse without
stranding a module the pane has already lifted -- that is the loss window
`dd.module.writetoken` describes, and it is why the pane holds the decision.

**ONE PREDICATE, TWO REQUIRES.** `arch.module.slots` earns its safety from both
sides asking `root.itemHasTag` about the same item rather than keeping two
hand-written rules. "No two modules of the same item" is not a `root.*` query --
it is a rule this mod invented -- so writing it twice would reintroduce exactly
the split that property protects. `petports_moduleSetDuplicate` lives in
`/scripts/lofty_petports/petports_modules.lua` and both sides require it.

**IT TAKES THE WIRE FORMAT.** The pane asks about the set it is ABOUT to send,
not about a cursor against the other slots, so the two sides ask one question of
one shape of data. `moduleRecords` grew an override pair for that -- building the
prospective set rather than mutating `paneModules` and rolling back keeps a
half-applied swap out of the table `dd.module.writetoken` exists to protect.

**DEDUPLICATION STAYS.** The union still deduplicates, because this rule guards
the SOCKET and the union guards the READ: a petData written before this shipped,
or by anything that is not the pane, can still hold a pair.

**SAME NAME IS ALSO WHAT THE SWAP SOUND TESTS**, and the two must move together.
If "same module" ever stops being name equality -- two lamps carrying different
parameters, the upgrade hook `moduleFieldOf` anticipates -- then the sound will
claim a swap was invisible when it was not.

### A field that survives typing needs three books, not one
`dd.pane.fieldbooks` -- see also `fact.pane.textboxpoll`, `arch.pane.rowfocus`, `dd.module.writetoken`

**THREE SEPARATE BUGS, THREE SESSIONS APART IN CHARACTER, ONE CAUSE EACH.** A
text field fed by a polled remote mirror needs three pieces of bookkeeping and
each one exists because leaving it out produced a specific, visible fault.

    lightShown     the TEXT the script last wrote into the box
    lightPainted   the VALUE the box is known to be displaying
    lightSent      the value last sent, until the echo agrees

**`lightShown` -- SO THE SCRIPT'S OWN WRITE IS NOT READ BACK AS AN EDIT.** This
is `restockconfig`'s `shownText` and its comment already says the bookkeeping is
the point. Without it a render commits itself in a loop.

**`lightPainted` -- SO AN EMPTY BOX IS UNFINISHED, NOT STALE.** Observed
2026-09-03, backspacing 140 away one character at a time:

        light g -> 14
        light g -> 1
        light g -> 10      the "0" typed, on the end of a "1" nobody typed

An empty box commits nothing, correctly, so the stored value stayed at 1 -- and
the paint, comparing the stored value against the TEXT, found "1" against "",
called the field stale and wrote the 1 back one poll after it was deleted. THE
PAINT MUST BE DRIVEN BY A CHANGE IN TRUTH, NOT BY DISAGREEMENT WITH THE WIDGET.

**`lightSent` -- SO A STALE ECHO LOSES TO A NEWER EDIT.** Observed the same day:

        light g -> 14
        light g -> 1
        light g -> 1       committed twice, nothing in between

Every edit sends immediately, so two messages are in flight when the first echo
lands carrying a value that was true when written and stale on arrival. Testing
only whether it differed from the local value accepted it -- a stale echo and a
genuine external change look identical that way. THE PANE OWNS A CHANNEL WHILE
ITS WRITE IS OUTSTANDING; a mirror value is accepted only once it AGREES with
what was last sent, which is the moment the port has caught up.

**A VALUE, NOT A TOKEN, AND THAT IS THE DIFFERENCE FROM dd.module.writetoken.**
Modules needed a stamp because a dropped reply could destroy an ITEM, so the pane
had to recognise its own write specifically. A colour cannot be lost or
duplicated -- both ends clamp identically and the pane sends all three channels
every time -- so "the port now says what I said" is a complete answer and needs
nothing on the wire to carry it.

**ALL THREE CHANNELS ARE MARKED OUTSTANDING, NOT THE ONE THAT MOVED**, because
the payload carries all three; marking only the edited one leaves the other two
open to a stale echo carrying their older values.

**OUT OF RANGE IS CLAMPED, AND THAT REVERSED THE FIRST DRAFT.** It was refused,
to protect the caret. What that produced:

        typing 999 then clicking the up spinner set the value to 100
        typing 256 then clicking the up spinner set the value to 26

Both correct given a refusal, both indistinguishable from a bug. 999 passes
through 9 and 99, each of which commits; 999 is refused, so the unit held 99
while the box said 999, and a spinner acting on the stored truth could only look
like it had invented a number. THE BOX AND THE VALUE MUST NOT BE ALLOWED TO
DISAGREE. The caret cost is paid only when the clamp bites, so a valid entry is
still never written back and "0100" still does not snap to "100".

### The debug colour legend does not match the game
`dd.pathing.debugcolours` -- see also `proc.pathing.debugpath`

**DECIDED 2026-08-30, MOVED OUT OF THE BACKLOG 2026-09-03.** A legend that
disagrees with the game costs a moment of confusion to one reader who already
has the source open, and is not worth a change to shipping code. That is a
decision and not a task nobody got to, which is why it no longer sits in a list
of things to do.

**THE DECISION COVERS THE LEGEND ONLY. POSSIBILITY 2 BELOW IS STILL OPEN** and
is a different question -- if the `workbench/` copy of `pathing.lua` is not the
version the game runs, a whole session of engine reasoning was read out of the
wrong file. Nothing has been done about it. Do not let this entry's WILL NOT FIX
be read as covering that.


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
`dd.pathing.nodeformula` -- see also `ref.pathing.nodelattice`, `fact.pathing.ongroundtest`

**DECIDED 2026-08-30, MOVED OUT OF THE BACKLOG 2026-09-03.** The divergences are
understood, nothing has been traced to them, and a MEASURED failure attributable
to the formula is the only thing that reopens this. A standing decision with a
named reopening condition is not a backlog item waiting for its turn, and
leaving it in the backlog implied work that nobody intends to do.


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


### Fish supply is tuned against the ladder, not against how fast a unit catches
`dd.fishing.supply` -- see also `arch.fishing.network`, `arch.dispatch.union`, `fact.tooling.mergedrefusal`

**RETUNED 2026-09-03 AFTER A MEASURED SATURATION, AND THE DIAGNOSIS TOOK TWO
WRONG TURNS BEFORE IT LANDED.**

Observed: upcyclers filling and never being emptied, with `drainWork` refusing
every time it was asked. Read first as fish starving the low rungs of the ladder,
then -- wrongly, from a log message that could not say -- as a beacon filter
fault. **Settled by a control test: two more units, and the work got done.**

**THE MECHANISM IS THE LADDER MEETING A SUPPLY THAT NEVER RUNS DRY.** Fish sits
high because its target EXPIRES; upcycler output sits low because a treat waits
indefinitely. Both are correct per task. Under saturation the ranking stops being
a preference and becomes a permanent exclusion: a rung that is always outranked
by something always available is never reached.

**NETWORK-WIDE FISH MOVED THE SATURATION POINT WITHOUT ANYONE DECIDING TO.**
`arch.fishing.network` let every port see every member's fish, which multiplied
the fish visible per port by the number of lures on the water. Nothing about the
per-lure rate changed; the demand on each unit did. Two units on a two-lure pond
turned out to be below the new line.

**THE LADDER IS NOT THE THING TO CHANGE, AND THAT IS THE DECISION.** Ranking an
expiring target above a waiting one is right, and the alternative is dropping
catches. Priority ageing, a starvation floor or a round-robin would all buy the
upcycler its trip by making the fleet worse at the one task that has a deadline.
**The supply was wrong, not the ordering.** `spawnTimeRange` is now `[8, 24]`,
a quarter of vanilla's.

**AND THE LURES NO LONGER EXPIRE IN LOCKSTEP.** `FISHING_LURE_LIFETIME` was a
flat 150, and every port on a network places its first lure within a tick or two
of the others, so every lure in a base died and respawned in the same second --
and the replacement kept the phase, so the alignment survived indefinitely.
Fishing arrived in a pulse. It is now `{ 120, 300 }`, drawn per lure.

**ITS MAX IS LOAD-BEARING ELSEWHERE.** The fish entry's TTL reads
`FISHING_LURE_LIFETIME[2]` and must read the max rather than a fresh draw, or an
entry would expire out from under a fish whose lure rolled long. See
`arch.fishing.network`.

**"MORE THROUGHPUT MEANS MORE UNITS" SURVIVES THIS INTACT.** The fleet being
under-provisioned for its work is the design working. What was wrong was that
nothing SAID so -- see `fact.tooling.mergedrefusal`, which is the durable half of
this whole episode.

### A fish caught twice is a risk we take rather than fork vanilla for
`dd.fishing.catchwindow` -- see also `fact.fishing.despawnwindow`, `arch.fishing.network`

**DECIDED 2026-09-03, WITH THE HAZARD MEASURED AND UNDERSTOOD.**
`fact.fishing.despawnwindow` means a caught fish stays dispatchable for over a
second. Nothing sits between a second unit arriving inside that window and
`root.createTreasure` rolling the same fish's pool again.

**THE OLD DESIGN WAS ACCIDENTALLY IMMUNE AND NOBODY KNEW.** Only the owning port
could dispatch at its own fish, and after a catch that port's unit is CARRYING,
which `fishWork`'s start-empty rule refuses. Network-wide fish removed a guard
that was never written down as one -- which is the interesting part of this entry
and the reason it exists.

**NOT FIXED, AND THE REASON IS THE COST OF THE FIX.** Closing it properly means
patching vanilla's fish so the entity goes away when it is caught, and this mod
does not fork vanilla assets to close a hole this size. The alternatives
considered inside our own code -- re-keying `petports_fish` by fish id so any
port can withdraw a caught fish, or a short tombstone -- all buy a narrower
window rather than none, because the fish is alive either way.

**THE ODDS ARE WHAT MAKE IT ACCEPTABLE, NOT THE SEVERITY.** A second unit must
be dispatched at that exact fish inside the window AND be close enough to arrive
before it dies. Twice observed, zero double-catches: both second units lost the
target first, one of them after 10.5 tiles of travel. If a duplicate is ever seen
in play, this entry is where to start and `fact.fishing.despawnwindow` has the
timings.

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

### Networked storage reading
`plan.fuel.storageread`

**CORRECTED 2026-09-03, IN BOTH DIRECTIONS, AND NOT YET REWRITTEN.**

THE OPEN QUESTION BELOW IS ANSWERED. It calls it UNVERIFIED whether
`world.containerItems` can be read from an object script against an arbitrary
loaded container. The port calls it 43 times, and the comment at
`petports_petport.lua` line 2755 says the loop already does it for every
container in the network. The design may lean on it.

THE LAST TWO PARAGRAPHS ARE ABOUT FEEDER OBJECTS, WHICH `dd.fuel.selffeed`
CUT. The dead-feeder cases and the fullness light describe a device that does
not exist. Kept until this is rewritten, because the DEDUPLICATION point --
one network-level alert rather than one per unit -- survives the cut and is
the part worth carrying forward.

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

### Network control — segregation
`plan.network.control` -- see also `arch.port.switches`, `dd.port.participationgroups`

What makes a LARGE deployment governable, and everything above assumes large
deployments.

**PER-TASK PARTICIPATION IS BUILT** and has graduated to `arch.port.switches`.
Four groups rather than the per-task checkboxes described here, because fourteen
work generators do not fit a pane band and nobody thinks in generators. Watering
-- named here as the obvious first thing a player switches off -- is inside the
farming group and cannot be switched off on its own. If that turns out to matter,
splitting farming is the change, not per-task boxes.

**ITEM FILTERING IS BUILT AND IS NOT A BEACON.** A filter lives on the beacon
that is already there, as `petports_beaconFilter` on the item, edited in that
beacon's own pane, with the matchers and last-match-wins ordering in
`petports_filters.lua`. See `arch.filter.matchers`.

**WHAT REMAINS IS NETWORK SEGREGATION, AND IT IS A UI ADDITION TO THE TWO PANES
THAT EXIST.** The deposit and restock beacon panes gain a network id widget when
segregation is implemented. That is what answers "whose crate is this" -- a crate
is claimed by naming a network on the beacon already in it, not by adding a
second beacon beside it.

**THERE ARE TWO BEACONS, DEPOSIT AND RESTOCK, AND THERE WILL NOT BE MORE.** An
earlier design proposed a family of filter beacons chained by container slot
order, which is why `scanContainers` sorts its slot keys. That sort is worth
keeping for the reason recorded in `arch.beacon.restock` -- two behaviour
beacons in one crate must not swap roles between scans -- but the chain it was
written for is not coming. Recorded because the design outlived its own
supersession once already.

### Vent pipes -- making the hop visible
`plan.vent.pipes` -- see also `arch.vent.routing`, `todo.vent.entrysites`

**MOVED OUT OF `arch.vent.routing` ON 2026-08-31.** It was a `#### ` subsection
inside the vent ARCHITECTURE entry while declaring itself unbuilt, which is the
same filing error that let a superseded beacon design sit in ARCHITECTURE for
eight days. The vents that work stay in `arch.vent.routing`; this is the part
that does not exist yet. Content unchanged by the move.

A wired object that superficially resembles a pipe,
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

### What `harvestable.lua` exposes, and the arithmetic that locks it
`fact.farming.harvestable` -- see also `fact.farming.farmabledecl`, `arch.farming.traps`, `todo.farming.trapagelock`

From `/objects/scripts/harvestable.lua` and `mothtrap.object`, read 2026-09-03.
The script vanilla attaches to stage-growing objects that are NOT farmables.
Moth trap is its only vanilla user; the modded population is much larger.

**A HARVESTABLE DECLARES NO `objectType`.** It is a plain `Object` with
`stages`, a `scripts` list and an `itemDropOffset`. `world.farmableStage`
therefore returns nil for it, which is why anything gating on that call --
`scanFarmables` did -- cannot see one at all. That is the entire reason a moth
trap was invisible to the network.

**THE USEFUL GLOBALS, both plain and both callable out of band:**

    world.callScriptedEntity(id, "activeAge")     -- number, pure
    world.callScriptedEntity(id, "dropHarvest")   -- spawns AND resets

**`activeAge` IS SAFE TO CALL IN ANY STATE, AND THAT IS BY INSPECTION.** It
reads `self.timeRange`, `storage.created` and `storage.startDayTime`, and
`init()` sets all three UNCONDITIONALLY before the `setStage()` call that is the
only thing in the script able to throw. So it answers correctly even on an
object whose `init` died on a malformed `stages` array -- which is exactly the
shape that killed baby livestock in `dead.farming.probe`.

**`dropHarvest` GUARDS ON `self.stage.harvestPool` AND IS A NO-OP WHEN UNRIPE.**
It also does its own reset -- `storage.created = world.time()`, durations
cleared, `setStage()` -- synchronously before returning. So the harvest is
verifiable in the same tick by asking `activeAge` again and watching it collapse.

**`die()` ALSO CALLS `dropHarvest`.** Breaking the object drops its produce, so
a destructive "harvest" looks like a successful one in the log. See
`arch.farming.traps`.

**RIPENESS IS `object.setInteractive(true)`, AND IT IS UNREADABLE.** `setStage`
ends by setting interactivity to exactly whether the current stage carries a
`harvestPool`. Perfect signal, no binding to read it -- see
`dead.farming.trapinteractive`.

**THE STAGE WALK, which is what makes a threshold computable:** `setStage`
subtracts `util.randomInRange(stage.duration)` from `activeAge()` per stage and
breaks when it goes negative. The harvest stage carries no `duration`, and that
absence is what stops the walk there. The rolls live in the object's own
`storage` and cannot be read, so the sum of the duration UPPER bounds is the
only threshold that cannot fire early.

**TWO WAYS A HARVESTABLE LOCKS PERMANENTLY, and both are config, not state:**

  - **A degenerate `activeTimeRange`.** The script defaults the key to `{0, 1}`
    and then takes the span as `(range[2] - range[1]) % 1.0`, which for `{0, 1}`
    is **ZERO**. `activeAge` multiplies by that span and returns 0 forever. So
    OMITTING the key -- the natural way to write "always active" -- means
    "never". Traced through all three consumers: the object sticks on stage one,
    never becomes interactive, and shows its INACTIVE animation states. A PLAYER
    cannot harvest it either. It is inert in vanilla, not merely invisible to us.
  - **A pre-harvest stage with no `duration`.** `util.randomInRange(nil)` leaves
    `storage.durations[i]` unset and the `if not storage.durations[i] then
    break end` line halts the walk there permanently.

Both are detected statically in `trapProfile` and reported by cause. The second
matters most as a THRESHOLD bug: summing zero for that stage would put the
threshold below anything the object can reach, and the network would dispatch
forever at a trap that can never be ready.

**`itemDropOffset` IS REAL AND CAN BE LARGE.** Moth trap's is `[0.5, 2.5]`, so
produce appears two and a half tiles above the object and falls. Ordinary
collection handles it, the same way it handles a falling item drop.

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

### A TEXTBOX MUST NAME A CALLBACK, AND THE PANE DIES AT CONSTRUCTION IF IT DOES NOT
`fact.pane.textboxcallback` -- see also `fact.pane.nullcallback`, `arch.pane.rename`

**MEASURED 2026-09-01, BY CRASHING THE CLIENT TO THE MAIN MENU.**

    (WidgetParserException) Failed to find textbox callback named: 'tbPetName'
    Star::WidgetParser::textboxHandler
    Star::ContainerPane::ContainerPane

With no `callback` key, `WidgetParser::textboxHandler` FALLS BACK TO THE WIDGET'S
OWN NAME and throws when no function of that name is registered. The throw is
inside the `ContainerPane` CONSTRUCTOR, so the pane does not fail to work -- it
fails to EXIST, and interacting with the object drops the player out of the world.

**THE CALLBACK MUST ALSO BE IN `scriptWidgetCallbacks`.** Both halves are
required. `tbMin`, `tbMax` and `tbThreshold` all do it, in two panes, and were
sitting in the tree as three working examples while the assumption "no callback
means no Enter handler" was written instead.

**THIS IS THE EXACT INVERSE OF THE ROW-CALLBACK RULE AND BOTH FAIL THE SAME WAY.**
A ROW callback must NOT appear in `scriptWidgetCallbacks` or `addListItem` throws
at construction; a TEXTBOX callback MUST appear there or `ContainerPane` throws at
construction. Two opposite rules, one symptom, and the pane pre-flight currently
sees neither.

**COMMITTING ON ENTER IS A SEPARATE QUESTION FROM SATISFYING THE PARSER.** The
callback fires on ENTER, so where Enter must not commit, the answer is a
registered EMPTY function, not a missing one. `"callback" : "null"` may also work
-- `fact.pane.nullcallback` records it constructing and doing nothing on a row
BUTTON -- but it is UNTESTED on a textbox and the empty named function is what
shipped.

### A UNIT IS ALREADY NAMED; WHAT IT LACKS IS THE TAG
`fact.unit.entityname` -- see also `arch.pane.rename`, `fact.unit.damageteams`

**MEASURED 2026-09-01 BY `/entityeval` ON A DEPLOYED UNIT:**

    type(monster.setName)            "function"
    type(monster.setDisplayNametag)  "function"
    type(monster.setUniqueId)        "function"
    world.entityName(entity.id())    "Utility Unit"

**`world.entityName` IS NOT EMPTY BEFORE ANYTHING OF OURS RUNS.** The engine takes
the monstertype's `shortdescription` as the entity name. So a unit has always had
a name; what it never had was a VISIBLE tag.

**NOTHING SWITCHES THE TAG ON FOR A PORT-SPAWNED UNIT.** Vanilla calls
`monster.setDisplayNametag(true)` from `capturable.update` only under
`capturable.ownerUuid()` -- `config.getParameter("ownerUuid")` -- and a unit
spawned by a petport has no pod owner. Asserting it ourselves is therefore not
redundant.

**`petName` IN SPAWN PARAMETERS DID NOTHING FOR YEARS.** Neither `monster.lua`
nor `capturable.lua` reads a `petName` config parameter -- `capturable.optName`
goes to `world.entityName` instead. The port had been passing it since the file
was written and nothing consumed it; `petports_setUnitName`, called from the
contract's `init`, is what made that parameter mean something.

**THE `"Pet"` BRANCH IS REAL BUT CURRENTLY UNREACHABLE FOR US.**
`capturable.update` calls `monster.setName("Pet")` every tick when
`world.entityName` reads empty -- gated on that same `ownerUuid`. Both halves are
vanilla's to change, so an empty name is never sent: a unit with no stored name is
pushed its SPECIES with the tag off.

### `liquidBuoyancy` DOES SOMETHING ON A GRAVITY-DISABLED ACTOR
`fact.locomotion.buoyancy` -- see also `arch.locomotion.classes`, `proc.pathing.readsource`

**OBSERVED 2026-09-01, AND IT CONTRADICTS A COMMENT THIS MOD SHIPPED.**
`petports_aquatic.monstertype` pins `liquidBuoyancy` to 0 and explains why:
*buoyancy is a force opposing gravity and there is no gravity here, so it should
compute to nothing -- but "should" is doing work in that sentence.* It was right
to hedge.

Setting `liquidBuoyancy` to 0.25 on the FLYER -- also `gravityEnabled` false --
produced the intended effect: a flyer barely straddling a waterline is nudged
clear instead of holding a mixed-medium position until plan validation refuses it
and re-homes.

**THE MECHANISM IS NOT ESTABLISHED AND THIS ENTRY DOES NOT CLAIM ONE.** If
buoyancy were purely a gravity multiplier it would multiply zero and do nothing.
It did something. Whether the engine applies a buoyant force independently of the
gravity term, or something else moved, has NOT been measured -- `/entityeval`
against a straddling flyer with the field at 0 and at 0.25 would settle it and
has not been run.

**WHAT IS SAFE TO RELY ON TODAY:** the field is not inert on a gravity-disabled
chassis, so the aquatic chassis's pinned `0.0` is LOAD-BEARING rather than
defensive documentation. Do not delete it as a no-op.

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

### Do not trust a textbox callback's timing — poll instead
`fact.pane.textboxpoll` -- see also `dd.pane.fieldbooks`, `arch.pane.rowfocus`

**THIS ENTRY SAID CALLBACKS DO NOT FIRE PER KEYSTROKE AND THAT IS CONTRADICTED.**
It read: "an entire editing session produced no callback line at all, while the
field visibly accepted a backspace and then appeared stuck." Instrumented
directly on 2026-09-03 -- one log line inside the callback, nothing else --
a colour field in the petport pane fired it **105 times** across a handful of
short edits, interleaved one per character between the commits:

        settingsFieldChanged fired
        settingsFieldChanged fired
        light r -> 9
        settingsFieldChanged fired
        light r -> 99

**THE POST-MORTEM: THE TWO MEASUREMENTS WERE NOT OF THE SAME THING, AND NEITHER
IS SAFE TO GENERALISE FROM.** The original was inferred from a pane that appeared
stuck for other reasons, and it logged in the function the callback CALLED rather
than in the callback. The new one is direct and unambiguous but is one row
textbox in one ContainerPane. **THE DURABLE RULE IS THE ONE THE CONCLUSION
ALWAYS WAS: DO NOT BUILD ON WHEN IT FIRES.** Poll, whatever it does.

**IT COST A FEATURE, AND CHEAPLY.** Blurring the field on Enter is the
conventional way to finish with one, and would have been a single line -- and
with a per-keystroke callback it makes the field impossible to type more than one
character into. The instrumentation was added instead of the blur, precisely
because this entry's claim was the thing being relied on. `arch.pane.rename` also
cites "a textbox callback fires on ENTER" as part of why the rename button is the
only commit path; that conclusion survives on its own merits -- a half-typed name
must not reach a server -- but the reason behind it is now unreliable.

The original observation, kept because it is what the poll was built from: a
field visibly accepted a backspace and then appeared stuck, with no callback line
anywhere in the log.

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

### A status effect is not applied before the spawning tick renders
`fact.unit.spawnrender` -- see also `arch.port.anchor`, `todo.art.invisibleframe`

Applying a materialise effect to a freshly spawned unit produced a visible
full-size unit for ONE TICK, and only sometimes. Three attempts, each fixing a
real problem and each leaving the pop:

    port calls world.callScriptedEntity after spawnMonster   pop every time
    spawn parameter, effect applied in the monster's init    pop ~1 in 3
    the above plus a synchronous animation state             gone

**A callScriptedEntity IS ALWAYS AT LEAST A TICK LATE.** The monster has
initialised and rendered once before the call lands. Vanilla never does it that
way: `capturable.lua` reads the SPAWN PARAMETER `wasRelocated` inside the
monster's own init and applies `monsterrelocatespawn` there.

**BUT init IS NOT LATE ENOUGH EITHER.** `status.addEphemeralEffect` hands off to
the STATUS CONTROLLER, and whether that controller's first update lands before
or after the render for that tick is not deterministic -- which is exactly the
shape of an intermittent one-in-three. VANILLA HAS THE SAME HOLE. The relocator
covers it with a beam projectile drawn over the spawn point; there is nothing to
see because something is in front of it.

**animator.setAnimationState IS SYNCHRONOUS**, and is the only thing reachable
from a monster's init that is guaranteed in place before a frame can be drawn.
Hiding the unit there and letting the effect take over whenever the status
controller arrives closes it.

**SELF-HEALING IS WHAT MAKES THAT SAFE.** groundPet writes `movement` every
update out of setMovementState / setIdleState, so the hidden state survives
exactly one tick and needs nothing to clear it. If the effect fails entirely the
unit is invisible for one tick rather than visible for one -- the better failure,
and still self-correcting.

### `pane.setTitleIcon` is the only route to a pane's header icon
`fact.pane.titleicon` -- see also `fact.pane.windowicon`, `fact.pane.titlepadding`

    void pane.setTitleIcon(String image)

CONFIRMED 2026-08-30 on both beacon panes. The `icon` block under a title widget
is read AT CONSTRUCTION and the resulting icon is owned by the Pane, not placed
in the addressable widget tree -- the same ownership `fact.pane.windowicon`
describes for ContainerPane's header icon. The config block still owns the
icon's POSITION; `setTitleIcon` only swaps the image.

**`widget.setImage("title.icon", path)` DOES NOT WORK, AND DOES NOT SAY SO.** It
was tried first, wrapped in a pcall, and it neither threw nor changed anything.
Four `applied` lines per pane, on screen nothing. Starbound's widget bindings
commonly no-op on a name that does not resolve, so the guard reported a
successful NO-OP as a success. See `proc.tooling.guardedcall` -- the general
lesson is worth more than this instance.

**HOW IT WAS SETTLED WITHOUT ANOTHER GUESS.** `type(pane.setTitleIcon)` is a
fact available at runtime: an absent binding is nil and says so on the first
line of the log. Probing the two candidate routes and NAMING THE ONE TAKEN in
every subsequent line turned an open question into one test round. Ask the
engine what it has rather than asserting what it should have.

### The gap between a pane's icon and its title is STRING PADDING
`fact.pane.titlepadding` -- see also `fact.pane.titleicon`

There is no offset field for this. The space between a header icon and the title
text is LEADING SPACES INSIDE THE TITLE STRING, and there is no other lever:

    "title"    : "  Petport",
    "subtitle" : "  ^#b9b5b2;Configure and deploy pets",

The title widget's own `position` moves the icon and the text TOGETHER, so it
cannot change the distance between them. The icon's `position` can, but all four
panes already sat at x -4; the visible inconsistency was entirely padding --
2 spaces on the petport, 3 on the upcycler, NONE on either beacon.

**THE PETPORT IS THE REFERENCE**, being the one checked against a vanilla
crafting station and found correct. Two spaces on both title and subtitle, in
all four panes, as of 2026-08-30.

**NOT DISCOVERABLE EXCEPT BY READING A PANE THAT LOOKS RIGHT.** Nothing errors,
nothing logs, and a pane with no padding renders perfectly happily with its text
jammed against its icon.

STILL INCONSISTENT AND LEFT ALONE: the upcycler's icon sits at y -24 where the
other three sit at -4, and the two beacon subtitles have no `^#b9b5b2;` colour
code where the petport and upcycler both do.

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

### `root.monsterParameters` answers chassis capability with no entity
`fact.port.typecapabilities` -- see also `dd.port.envpresence`, `arch.locomotion.classes`

An OBJECT script can read a monstertype's parameters. `petports_petport.lua`
already did it twice, for `paneBodyKind` and `animalHarvestable`; the habitat
gate is the third caller and the one that made it load-bearing.

    root.monsterParameters(typeName)   ->  the monstertype's parameter table

**CHECK BOTH LEVELS.** Whether the call returns `baseParameters` flattened or
nested is not documented, and looking in both costs one index. The existing two
callers already did this.

**`movementSettings.gravityEnabled` ABSENT MEANS WALKER, WHICH MAKES THE TEST
MATTER.** The unit asks `mcontroller.baseParameters().gravityEnabled`, which is
not reachable from an object, but it is the same authored value. Verified across
all four chassis: the two free movers set it `false` explicitly and the two
walkers OMIT IT ENTIRELY.

    freeMover = (movement.gravityEnabled == false)     correct
    freeMover = not movement.gravityEnabled            reads a walker as a flyer

**CACHE IT PER TYPE.** These are authored constants and nothing can change them
for the life of the world. Do NOT cache anything overlaid on top of them keyed by
type alone -- see `arch.module.liquids`.

### A spawn parameter BEATS the monstertype, and makes a correct file inert
`fact.unit.spawnoverride` -- see also `dd.unit.destructible`, `fact.unit.damageteams`

`spawnPet` builds a parameter table for `world.spawnMonster`. Anything in it
OVERRIDES the same key in the monstertype, silently and permanently.

**MEASURED 2026-08-30, AT THE COST OF THREE TEST ROUNDS.** All four chassis were
moved from `damageTeamType: "ghostly"` to `"friendly"` and nothing changed --
because `spawnPet` was also passing `damageTeamType = "ghostly"` and overwrote
the file on every spawn. The files were correct the whole time.

**WHAT SEPARATED THE TWO WAS AN ACCIDENT WORTH REPEATING ON PURPOSE.** A brand
new field, `petports_unit`, was added in the same session. It resolved through
`root.monsterParameters` -- which reads the FILE -- while `world.entityDamageTeam`
reported the ENTITY. One said the new asset was loaded; the other said the value
was old. That contradiction is what pointed at spawn parameters instead of at
the asset. A TYPE-LEVEL READ AND AN ENTITY-LEVEL READ OF THE SAME FIELD ARE A
FREE DIAGNOSTIC and should be reached for whenever an asset edit appears not to
take.

**`persistent = true` HIDES IT FURTHER.** Units are spawned persistent, so they
are SAVED INTO THE WORLD CHUNK and RESTORED rather than respawned when the player
returns to a planet. A restored entity keeps its spawn-time values, so "drop onto
the planet and look" does not re-run `spawnPet` at all. Only an unsocket/socket
produces a genuinely new unit.

**AND THE BUILD STAMP DOES NOT DISTINGUISH THEM.** A restored entity re-creates
its script context and runs `init`, so it logs the CURRENT contract stamp. The
stamp proves the SCRIPT is current; it says nothing about when the ENTITY was
created. That is a real hole in the stamp as a diagnostic.

**THE FIX WAS TO DELETE THE LINE, NOT CORRECT IT.** The value belongs to the
chassis. Stating it in two places is how the two disagree, and a third-party
chassis should be able to declare its own team without the spawner having an
opinion. `initialStatus` / `initialStorage` are the other known instance of a
spawn parameter that does not mean what it looks like -- see
`dd.unit.itemispet`.

### Damage teams, measured across every entity class that matters
`fact.unit.damageteams` -- see also `arch.dispatch.medicpatients`, `fact.unit.spawnoverride`

MEASURED 2026-08-30 by a census logging `world.entityType`, `world.entityDamageTeam`
and `world.entityHealth` for everything in a coverage rect. Every row observed,
none inferred:

    entity           type      teamType    team
    player           player    friendly    0
    crew member      npc       friendly    0
    villager NPC     npc       friendly    1
    hostile NPC      npc       enemy       2
    capture-pod pet  monster   friendly    0
    farm animal      monster   friendly    2
    hostile monster  monster   enemy       2
    ambient critter  monster   passive     2
    FISHING FISH     monster   ghostly     2
    our units        monster   friendly    2

**`damageTeamType` IS THE DISCRIMINATOR AND TEAM NUMBER IS NOT.** All five
friendly classes span teams 0, 1 and 2, so any test comparing NUMBERS -- including
the obvious "same team as our unit" -- catches at most one of them. A hostile
monster and a farm animal are both team 2 and differ only in type.

**A HOSTILE AND A FRIENDLY GUARD SHARE A TEAM NUMBER.** Breaking objects flips a
guard's `damageTeamType` to hostile and leaves it on team 1. The friendly/hostile
distinction works because the PLAYER is team 0 -- `damageTeamType` describes the
relationship to team 0, not a general friend/foe label.

**TEAM NUMBER CARRIES SIGNAL IN EXACTLY ONE PLACE:** among friendly MONSTERS, 0
is a capture-pod pet inheriting its owner's team and 2 is a farm animal on the
monster default.

**FISHING FISH ARE `ghostly`**, which nobody predicted -- guesses were `passive`
or `enemy`. It is the same value units carried until this session, so a stale
ghostly unit would have been rejected as a fish, and the reason would have looked
like a broken classifier rather than a stale team.

**AMBIENT CRITTERS ARE `passive`** and exclude themselves by class rather than by
luck, which was the specific outcome wanted -- nobody should be healing
butterflies.

### `appliesWeatherStatusEffects` was false on every chassis, and that was accidental immunity
`fact.unit.weatherflag` -- see also `dd.unit.destructible`, `arch.module.liquids`

All four petport monstertypes shipped with:

    appliesEnvironmentStatusEffects   false
    appliesWeatherStatusEffects       false
    minimumLiquidStatusEffectPercentage   0.1

**THE THREE ARE INDEPENDENT GATES AND THAT IS THE FACT WORTH KEEPING.** Liquid
harm reaches an entity with BOTH flags false -- vanilla's smoglin carries
`appliesEnvironmentStatusEffects false` and still needs an explicit
`lavaImmunity` stat, which would be dead weight otherwise. So liquid damage was
always landing on our units while weather never was.

**THE CONSEQUENCE WAS AN ACCIDENTAL IMMUNITY NOBODY CHOSE.** Toxic rain did
nothing to a petport unit, with or without a poison module, which made the module
liquid-only and the toxic-planet deploy route protected for a reason that was
never a decision and was recorded nowhere.

**THE FLAG IS TRUE ON ALL FOUR NOW, AND IT IS ALL OR NOTHING.** There is no
per-effect gate, so blizzards, electrical storms and ember fall reach these units
too, and only poison has a module answering it. That surface is accepted
deliberately. The alternative considered and not taken was a baseline immunity
stats block on all four chassis, which reads as arbitrary the moment the
reasoning is lost.

**PREDICTED, NOT MEASURED: which weather effects actually hurt.** The flag was
flipped and poison rain confirmed; nothing else was tested.

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
`fact.pathing.edgebymedium` -- see also `arch.locomotion.classes`, `fact.pathing.liquidthreshold`

A gravity-DISABLED actor submerged in water is planned `Swim` edges, not `Fly`.
A gravity-ENABLED ground unit dropped into a lake is planned `Swim` edges too,
and then `Jump` arcs to get out. The chassis does not enter into it.

**QUALIFIED 2026-09-01 BY `fact.pathing.liquidthreshold`, AND THE HEADLINE IS
STILL TRUE.** Edge type is picked by medium, not by chassis -- but WHAT COUNTS
AS A MEDIUM is itself a per-chassis movement parameter. A chassis that declares
`minimumLiquidPercentage` above 1.0 is never in liquid as far as the search is
concerned, and is planned Walk edges along the seabed. Everything above holds
for every chassis that leaves that parameter alone, which is all four shipping
ones.

This is the single most useful fact of the session and the otter fell out of it.
It also means A MOVER BOUND TO THE SLOT THAT "SHOULD" APPLY IS NOT ENOUGH:
`petportsFreeMover` was assigned to `moveFly` only, so underwater it was never
called once and vanilla's `moveSwim` ran instead. The telemetry said so plainly
-- `aim null skip null` on every line, fields nothing else writes.

Bind both slots on every chassis.

### `airForce` STEERS AN AIRBORNE UNIT AT EXACTLY ITS STATED VALUE; `groundForce` DOES NOT
`fact.pathing.airauthority` -- see also `arch.pathing.climbsteer`, `arch.pathing.nosteer`

**MEASURED 2026-09-01, AND IT CLOSES A QUESTION `arch.pathing.nosteer` LEFT
OPEN.** That entry recorded an asymmetry it could not explain: the same
`controlApproachXVelocity` call, with `groundForce`, closed a gap in two ticks
when DECELERATING (commanding 0 against an actual 8) and never closed it in five
when ACCELERATING (commanding -12 against an actual -10.8). It asked whether
`groundForce` simply has no airborne authority in the accelerating direction and
left it unmeasured.

**IT DOES NOT, AND `airForce` DOES.** Commanding vx 12 with `airForce` against a
unit at 0:

    [2531,   1142.34]  vel [0,        7.30]
    [2531.21,1142.61]  vel [4.16667, -2.70]
    [2531.76,1142.05]  vel [8.33333,-12.70]

+4.16667 per 0.0833s tick is **50.0 exactly** -- `airForce` 50 against mass 1,
to the digit. Full authority, no deficit, nothing asymmetric.

**SO THE OLD FAILURE WAS THE WRONG QUANTITY, NOT A DOOMED IDEA.** `groundForce`
is what the landing brake uses on a grounded unit. Reaching for it while the unit
is in the air is the mistake, and it made airborne steering look impossible for a
session and a half. **USE `airForce` FOR ANY AIRBORNE HORIZONTAL COMMAND.**

**THE DECELERATING CASE STILL WORKED WITH `groundForce`**, which is why this took
so long to see: half the calls behaved and half did not, and a quantity that
works in one direction reads as a tuning problem rather than a wrong constant.

### THE PET STATE MACHINE, AS IT ACTUALLY BEHAVES
`fact.unit.statemachine` -- see also `arch.locomotion.beached`

READ FROM `/scripts/stateMachine.lua` AND `/monsters/pets/groundPet.lua`,
2026-09-01, after three failed runs guessing at it. Every line here cost a test
round.

**`pickState(params)` CALLS `enterWith`. `pickState()` CALLS `enter`.**

    local enterFunctionName = "enter"
    if params ~= nil then enterFunctionName = "enterWith" end

A state that defines only one of them is SILENTLY SKIPPED by the other call
shape. Passing params to select a state that implements only `enter` iterates
every state, matches nothing, and returns false with no error. **A state meant to
be reachable both ways must define both**, which is why `petportsFlopState` does.

**WHICH MAKES A FORCED PICK DETERMINISTIC.** With params, ONLY states
implementing `enterWith` are considered -- and the vanilla pet states, `idleState`
and `wanderState`, define only `enter`. So naming a state with params bypasses
list order entirely. Without params, order decides, and order is the scripts list
order that `scanScripts` walks.

**`scanScripts` REQUIRES THE GLOBAL TO EXIST AND TO LOOK RIGHT:**

    (state["enter"] ~= nil or state["enterWith"] ~= nil) and state["update"] ~= nil

A state table missing `update` is dropped from the list with no complaint.

**TWO MACHINES, AND THE PLAIN ONE ONLY RUNS WHEN THE ACTION ONE IS EMPTY:**

    if self.actionState.stateDesc() == "" and not self.state.update(dt) then
      self.state.pickState()

`(%a+State)%.lua` builds `self.state`, `(%a+Action)%.lua` builds
`self.actionState`. **An action already in flight blocks every plain state**, and
`endState()` is the only way to take the slot back from outside.

**`petBehavior.run()` IS CALLED ONCE A SECOND, NOT PER TICK.** It comes from
`groundPet.querySurroundings` on `querySurroundingsCooldown`, which the
monstertypes set to 1. Anything that must react faster than a second cannot live
in `run()`.

**AND reactTo QUEUES ACTIONS BEFORE run() IS EVER CALLED.**
`querySurroundings` calls `behavior.reactTo` for every nearby entity first, and
the reactTo handlers call `queueAction` themselves. So `petBehavior.actionQueue`
is ALREADY POPULATED when `run()` starts, and gating the queueing sites inside
`run()` does not suppress anything. Clearing the queue is the only complete
suppression.

**`self.autoPickState = false` IN groundPet.init IS A VANILLA TYPO.** It sets a
field on the script context, not on `self.actionState`, so the action machine's
auto-pick stays enabled. Harmless TODAY only because auto-pick uses `enter` and
every action state in this mod defines `enterWith` alone -- so it finds nothing.
**ADDING AN `enter` TO ANY ACTION STATE WOULD MAKE IT FIRE UNBIDDEN.**

**`approachPoint` IS CALLED BY VANILLA ACTION STATES**, not only by ours.
`inspectAction.lua:33` calls it, and follow, beg and pounce are the same shape.
See `todo.pathing.fallbackpather`, whose scope claim this falsifies.

### `inLiquid` IS TESTED BEFORE `onGround`, AND ITS THRESHOLD IS A CHASSIS PARAMETER
`fact.pathing.liquidthreshold` -- see also `fact.pathing.edgebymedium`, `todo.locomotion.sinker`, `dd.pathing.coststeering`

READ FROM `StarPlatformerAStar.cpp` AND **VERIFIED IN GAME 2026-09-01** by a
purpose-built test chassis. This is the fact that made the sinker possible, and
it was reached by reading the source rather than by testing -- see
`proc.pathing.readsource`.

**`neighbors()` IS AN ELSE-IF CHAIN AND LIQUID WINS.**

    if (node.velocity.isValid())            getArcNeighbors
    else if (inLiquid(node.position))       getSwimmingNeighbors
    else if (acceleration[1] == 0.0f)       getFlyingNeighbors
    else if (onGround(node.position))       getWalkingNeighbors
    else                                    getFallingNeighbors

A submerged node NEVER REACHES `getWalkingNeighbors` no matter what solid ground
sits beneath it. The floor is never consulted, because the chain has already
left. `getSwimmingNeighbors` then closes the door behind it: it calls
`getFlyingNeighbors`, filters every edge down to targets that are themselves
`inLiquid`, and relabels `Fly` to `Swim`.

**NO COST SETTING CAN PRODUCE A WALK EDGE UNDERWATER.** `swimCost` is applied in
that same `transform`, AFTER the edge type is decided -- `edge.cost *= swimCost`.
Cost prices what was offered and cannot change what is offered. A whole test plan
was built on raising `swimCost` before the source was read, and it would have
measured nothing.

**THE THRESHOLD IS THE LEVER.**

    bool PathFinder::inLiquid(Vec2F pos) const {
      RectF box = boundBox(pos);
      return m_world->liquidLevel(box).level
             >= m_movementParams.minimumLiquidPercentage.value(0.5f);
    }

`minimumLiquidPercentage` is an **ActorMovementParameters** field, so it comes off
the monstertype's `movementSettings` and NOT off `petports_pathOptions`. Above
1.0 it is unsatisfiable at any fill level, `inLiquid` is never true, and a
gravity-enabled chassis falls through to `onGround` -- which is pure tile
collision and knows nothing about water.

**IT IS ALSO READ BY THE MOVEMENT CONTROLLER, ON THE EVIDENCE OF THE RESULT.**
The test chassis both PLANNED walk routes underwater and EXECUTED them, walking
the bottom rather than swimming. That was the open question when the variant was
built and it is answered by the outcome. **NOT SEPARATELY CONFIRMED IN
`StarActorMovementController.cpp`**, so the mechanism is inferred from behaviour;
`liquidBuoyancy` 0.0 was set in the same change and some of the effect may belong
to it.

**TWO PARAMETERS, AND THE SECOND IS NOT OPTIONAL.** `liquidBuoyancy` must be 0.0
or the unit floats and there is nothing to see -- the default in
`default_actor_movement.config` is what the aquatic chassis overrides rather than
accepts. `liquidImpedance` was deliberately left alone.

**WHAT ELSE STOPS APPLYING.** `liquidJumpCost` is consulted only inside
`if (inLiquid(...))`, so it goes dead too. And in `simulateArc` the landing test
is `onGround(rounded, Stand) || inLiquid(rounded)` -- losing the liquid branch
means an arc into water no longer registers a landing on the surface and must
reach real ground. For something that sinks, that reads correct.

**THE MOD'S OWN LUA STILL BELIEVES IN WATER, AND MUST.** `petports_avoidLiquid`
has to stay FALSE on such a chassis or every resolver refuses submerged targets.
The engine and our validation now disagree about whether the unit is wet, and
that disagreement is the design rather than a bug.

**AND A* WILL ROUTE THROUGH LAVA.** `getSwimmingNeighbors` opens with
`// TODO avoid damaging liquids, e.g. lava`. That is direct source confirmation
of why medium validation exists on our side, previously inferred.

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

### A* CHANGES ITS OWN vx PARTWAY THROUGH AN ARC, AND ALMOST EVERY ARC DOES IT
`fact.pathing.plannervxdrop` -- see also `arch.pathing.solvelaunch`, `fact.pathing.arcmoverthrottle`

MEASURED 2026-08-30. A Jump edge carries one velocity, but the Arc edges the
planner draws from it do not all carry that velocity. Near the apex it
substitutes a near-stationary one:

    edge 62 Arc src [2515.10,1179.67] vel [12,14.03] -> dst [2515.79,1180.38] vel [12,7.06]
    edge 63 Arc src [2515.79,1180.38] vel [12,7.06]  -> dst [2516.71,1180.75] vel [1,0]
    edge 64 Arc src [2516.71,1180.75] vel [1,0]      -> dst [2516.93,1180.25] vel [1,-26.5]
    edge 66 Arc src [2516.97,1179.25] vel [1,-30.8]  -> dst [2517,1177.8]     vel [1,-34.6]

12 to 1, and it stays at 1 for the whole descent. The values seen are 1, -1 and
0 -- and once, 12 on an arc launched at 0.

**THIS IS THE ORDINARY CASE, NOT AN EDGE CASE.** Seven of eight jumps on the
platform course did it, and seven of seven on the death course. Every jump this
mod has ever planned has probably contained one.

**IT WAS INVISIBLE ON SOLID TERRAIN FOR AS LONG AS IT EXISTED**, because the
mover's response to it cost only a fraction of a tile near the ground and a solid
surface forgives that -- see `ref.pathing.landings`. On platforms it costs the
whole jump. What the mover did with it is `fact.pathing.arcmoverthrottle`.

**THE WAYPOINTS ARE AS WRONG AS THE VELOCITY.** Once `solveLaunch` has committed,
the arc the unit flies diverges from the arc A* drew, beginning at the vx change.
That region was validated by the planner for the SLOW trajectory and is not
validated for the flown one. Harmless in the open; the reason tight-corridor
behaviour is worth re-testing after any change here.

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

**THE SECOND DEFECT, FOUND 2026-08-30 AND FIXED: THE MOVER STEERS x TOWARD THE
PLANNER'S PER-EDGE VELOCITY, AND THE PLANNER CHANGES IT MID-ARC.** See
`fact.pathing.plannervxdrop`. The substitution that hands the mover the launched
vx was gated on `launch.plannedVx == velocity[1]` -- matching the takeoff's
planned vx was taken as proof that the edge belonged to this jump. It is not, and
it fails on precisely the edges where the planner has changed its mind:

    25.607  [2514.65,1180.89]  vel [7.95553, 6.256]   edge 62, gate passes
    25.690  [2514.92,1181.07]  vel [1, -3.744]        edge 64, gate FAILS

One look, at the apex, with a quarter second of descent left. The unit crossed
its landing altitude 1.83 tiles short in x and fell twelve tiles. Three identical
attempts.

**THE CONTROL THAT SETTLED IT WAS AN ACCIDENT.** On a fourth attempt the water
task failed on vents at the apex and the pather was discarded mid-flight. With
nothing calling this mover the unit kept its launched vx, flew pure ballistics,
and touched down at `[2517.22,1177.8]` -- its planned landing, 0.22 over. Guided
it missed by 1.83 tiles; UNGUIDED IT HIT. That is the whole indictment: on the
descent this mover was strictly worse than not running.

**OWNERSHIP WAS MADE A STATE INVARIANT, NOT A VELOCITY COMPARISON.** The launch
record exists exactly as long as the pather is on an Arc edge -- cleared every
tick it is not -- so `launch ~= nil` became the whole test. Stated as a per-tick
state check rather than hooked onto each exit because there are at least four
ways off an arc: the mover's grounded last-edge branch, its advance loop running
past the last Arc, the skip loop stopping on a Land, and a path lost in flight.
ONLY THE FIRST EVER CLEARED ANYTHING, and the failing jump took the third, so the
record outlived its arc on every attempt. One rule covers exits not yet written.

VERIFIED IN GAME 2026-08-30 across three courses -- 3-wide platforms, single-wide
death course, and the original block course. Every jump landed. Worst error 0.49,
one clear per jump, zero stale-record warnings.

**SUPERSEDED 2026-09-01: THE SUBSTITUTION IS GONE, NOT MERELY GATED.** Nothing
steers x during a flight now -- see `arch.pathing.nosteer`. The gate above was
the right diagnosis of the wrong scope: holding `launch.vx` and issuing NOTHING
produce the same trajectory whenever the command is correct, because
`airFriction` is zeroed four lines up and an unforced horizontal velocity simply
persists. They differ only where the command is wrong. The accidental control in
this entry -- unguided it hit, guided it missed by 1.83 -- was already the
argument for deleting rather than gating, a session before anyone read it that
way.

**THE LAUNCH RECORD SURVIVES AS AN INSTRUMENT.** Nothing reads `launch.vx` for
control; the clear-time log line is the only place the log states what a flight
actually launched with, which is the quantity ballistics is now trusted to
preserve. Deleting the instrument in the same change that starts relying on what
it measures is how a regression goes unnoticed.

**AND THE BRAKE'S WINDOW IS CLOSED.** The arrival test used to be a distance --
0.5 in x, 1.0 in y -- which asks "am I near" and not "have I got there". It is a
sign test now: see `arch.pathing.arrivalsign`. The +-0.33 to +0.49 residual this
entry called harmless was not, and `todo.pathing.brakefloor`'s reasoning for why
had a hole in it. Measured after: 25 firings in one session, every one between 0
and 0.0017 except a single -0.61 caught by the far-side bound.

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

### The unit that crossed the water boundary was put in the air by our own code
`fact.pathing.watercrossed` -- see also `dead.locomotion.pelagic`, `dd.port.envuniform`, `arch.pathing.mediumenforcement`

**OPENED 2026-08-30 AS A CONTRADICTION. RESOLVED 2026-08-31 IN FAVOUR OF THE
RECORD.** Kept as a FACT rather than deleted, because two entries lean on the
finding it appeared to disprove and the next person to see a swimmer in the air
will reach for this first.

**WHAT WAS OBSERVED.** An AQUATIC unit -- gravity-disabled, `canSwim` true,
`canFly` false -- pathed OUT of one body of water, through AIR, and into another.
`dead.locomotion.pelagic` says that is impossible: `getSwimmingNeighbors` filters
every neighbour of a submerged node to targets that are ALSO in liquid, so
water-to-air is not expensive, it is unreachable.

**BOTH THINGS WERE TRUE.** The plan did not start in the water. The
`UNIT PLAN accepted ... (medium N)` line was added specifically to tell these
apart, and across the gap-crossing session it read:

    10 plans  medium air     every crossing
    15 plans  medium swim    none of them crossed
     0 refusals

An air start is `getFlyingNeighbors`, and AIR-TO-WATER PLANS FINE -- the C++ in
`dead.locomotion.pelagic` says so in the same breath. The unit got into the air
by BLIND STEER, which is not the pathfinder at all: A* had returned no route, the
fallback aimed straight at a submerged destination across a dry gap, and its
medium test only looked at the endpoint. See `arch.pathing.mediumenforcement`.

**THE ZERO REFUSALS ARE THE PROOF, NOT THE COUNTS.** Under the prefix escape
clause then in force, a plan starting submerged with an air waypoint would have
been REFUSED. None was. So no plan ever started in water and ended in air, and
the closed-set finding stands exactly as written.

**WHAT THIS RESTORES.** `dd.port.envuniform` refuses to deploy a free mover into
a mixed footprint, and its whole stated reason is that a submerged flyer would be
permanently stuck. That reason was under challenge and is now sound again.
`todo.locomotion.sinker` asked whether the closed-set claim was narrower than
written; it was not.

**THE LESSON IS ABOUT ATTRIBUTION.** A contradiction between an observation and a
recorded engine fact was, both times it has happened in this mod, our own code
producing a state the engine never produced. Suspect the mod before the record.

### `world.pointTileCollision` DOES NOT SEE PLATFORMS BY DEFAULT
`fact.pathing.platformfloor` -- see also `fact.pathing.collisionkinds`, `fact.pathing.liquidstandable`, `arch.pathing.oneanchor`

**OPENED 2026-08-30 AS todo.pathing.submergedplatform (retired). RESOLVED
2026-08-31, AND
THE MECHANISM WAS NEITHER OF THE TWO HYPOTHESES THE ENTRY RECORDED.** It was not
`validStandingPosition` being too permissive underwater, and it was not the
home-point resolver. It was TWO PREDICATES DISAGREEING ABOUT WHAT FLOOR IS.

**THE SYMPTOM.** An amphibious unit leashing to a submerged port at
`[2535,1152]`, with platforms about two tiles beneath it, stalled in place
forever:

    ground spot [2532.5,1149.8] is floating and no floor below it
    ... all seven columns, 27090 rejections in one log
    UNIT no floor beneath [2535,1152] -- falling back to an unbiased search

**BOTH HALVES WERE WORKING AS DESIGNED.** `findGroundPosition` FOUND the
platforms -- `1149.8` in every column is the platform row -- because
`validStandingPosition` accepts a platform as ground. The descend guard in
`standableNear` then threw all seven away, because it asked
`world.pointTileCollision` whether there was floor below and that call, with its
default collision kinds, DOES NOT REPORT PLATFORMS.

**THE PROOF THAT THE DEFAULT EXCLUDES THEM IS INDIRECT AND SUFFICIENT.** There is
no measurement of what the default set IS -- `findStandingPoint` in
`petports_petport.lua` still carries an "UNVERIFIED" note on exactly that
question. But `petportsTaskAction` passes `{"Platform"}` explicitly to
`world.rectTileCollision` in three places for the drop-through logic, and every
one of those would be redundant if platforms came back by default.

**THE FIX IS A NAMED SET, NOT A DEFAULT.** `STANDABLE_TILE_SET` is
`{ "Block", "Slippery", "Platform" }`, passed to BOTH `pointTileCollision` calls
in the guard -- the one deciding whether to descend and the one deciding where to
stop. They have to move together; disagreeing about what floor is would be a new
bug rather than a fix. `Dynamic` is excluded because it is doors, `Null` because
an unloaded chunk is an absence rather than a surface.

**VERIFIED IN GAME 2026-08-31.** One resolve, no retries, twenty-four tiles in
3.6 seconds:

    entering task state for leash at [2511.67,1152.8]
    standable for [2535,1152] -> [2535.5,1148.8] (column offset 0, dist 3.24)
    on station at [2535.53,1148.8] (port [2535,1152])

Columns `2532`, `2537` and `2538` still report no floor. That is CORRECT and not
residual: the platform run is `2533`-`2536` and those three are past its ends.

**THE GENERAL LESSON, WHICH IS WHY THIS IS A FACT AND NOT A CHANGELOG.** Two
predicates that both answer "is there ground here" and disagree will not fail
loudly -- the stricter one silently discards what the looser one found, and the
symptom appears at neither. `fact.pathing.ongroundtest` records the same shape
between `validStandingPosition` and the engine's `onGround`. When a resolver
finds candidates and something downstream rejects all of them, suspect the pair
before either half.

### DYNAMIC COLLISION IS DOORS. IT IS NOT CRATES, AND THIS MOD HAS GUESSED OTHERWISE THREE TIMES
`fact.pathing.collisionkinds` -- see also `fact.pathing.originnode`, `proc.pathing.readsource`, `fact.pathing.liquidstandable`

**AUTHORITATIVE, FROM THE AUTHOR, 2026-08-31.** The only objects in Starbound
with `Dynamic` collision are DOORS. Not crates, not containers, not objects in
general.

**RECORDED AS A FACT BECAUSE THE CORRECTION KEEPS NOT STICKING.** "Crates are
Dynamic" has been asserted three separate times in this project -- twice in
reasoning that reached the author, once written straight into a code comment as
settled fact hours after the entry warning about it was read. Each time it was
plausible, each time it was wrong, and each time the argument built on it looked
sound. `proc.pathing.readsource` already lists it among five wrong engine
theories; that entry evidently is not where anyone looks. This is.

**THE COLLISION KINDS, AND WHAT USES THEM HERE:**

    Block       terrain, and crate tops -- see below
    Slippery    ice
    Platform    platforms, which support from above and can be dropped through
    Dynamic     DOORS
    Null        unloaded or out of world; an absence, not a surface

**IT SETTLES AN AMBIGUITY THIS DOCUMENT WAS ALREADY CARRYING.**
`fact.pathing.originnode` measured a crate perch with two probes: it collides
with `{Null, Block, Dynamic, Platform}` and NOT with `{Platform}` alone, and
concluded "so it is Block or Dynamic". WITH DYNAMIC RULED OUT THAT RESOLVES TO
**BLOCK**. A crate top is a solid surface: a unit stands on it, and nothing drops
through it.

**AND IT CONTRADICTS A CODE COMMENT THAT IS NOW MARKED.**
`petports_flyapproach.lua`, above the conditional `controlDown`, attributed a
measured stall -- amphibious unit on a crate, planning one tile below itself,
velocity pinned for ten seconds -- to "the crate is a platform". If the crate is
Block, `controlDown` could not have cleared that stall, because nothing drops
through a Block. THE HOLD IS STILL CORRECT FOR REAL PLATFORMS, which is what
vanilla holds it for; the attribution is wrong, and the crate stall is therefore
UNEXPLAINED rather than fixed. The comment says so now.

**WHY THE GUESS IS SO ATTRACTIVE, so it can be recognised next time.** "Dynamic"
reads as "an object rather than terrain", and a crate is obviously an object. The
word describes COLLISION THAT CHANGES AT RUNTIME -- which is a door opening --
and not object-ness. Anything reasoning from the name will land on the same wrong
answer.

**THE CHEAP PROBE, since the argument is never worth having twice.** Two
`world.rectTileCollision` calls over the same region, one with the full set and
one with `{Platform}` alone. That is what settled the perch, it needs no repro,
and it is faster than the sentence asserting the guess.

### A* PLAN EDGES ARE NOT ONE TILE APART, AND THE CODE SAID BOTH
`fact.pathing.edgespan` -- see also `arch.pathing.mediumenforcement`, `fact.pathing.nyquist`

`planMediumValid` validated waypoint ENDPOINTS, justified in its own header:

    Plan edges are a tile apart, so a route cannot cross a medium boundary
    between two consecutive waypoints without one of them landing in it.

FORTY LINES ABOVE IT, in the same file, `FLY_AIM_RANGE` exists because "an edge
is not guaranteed to be one tile". Two statements about the same objects, one of
them load-bearing for a safety check, and only one of them true.

**THE PRACTICAL SHAPE.** A* contours terrain, so edge LENGTH is roughly a tile on
open ground and edge DIRECTION changes constantly -- which means the chain of
waypoints is longer and wigglier than the route actually flown, and a validator
walking it is strictly stricter than the mover. Endpoint validation is
simultaneously too weak (a long leg can skip a boundary) and too strong (a
contour detour is validated but never travelled).

**HOW TO CHECK IT AGAIN CHEAPLY.** The `post-move` line already carries `src` and
`dst` for the current edge. Their separation is the edge span, per edge, free, in
every log this mod has ever produced.

### There is no applyParameters on a monster, and a control override is invisible
`fact.unit.movementparams` -- see also `arch.locomotion.swimmode`, `proc.pathing.readsource`

**MEASURED 2026-09-02, TWICE, AND THE SECOND HALF IS THE SURPRISING ONE.**

**THERE ARE TWO mcontroller TABLES AND THE WIKI DOCUMENTS THEM SEPARATELY.**
MovementController -- projectiles and vehicles -- has `applyParameters` and
`resetParameters`. ActorMovementController -- monsters, npcs, tech, status
effects, active items -- HAS NEITHER. It exposes `baseParameters()` to read and
`controlParameters()` to write, and nothing else. Calling `applyParameters` threw
`attempt to call a nil value` on every pather build, killed the unit script, and
the port respawned it about sixty times in one log.

**A controlParameters OVERRIDE CHANGES THE PHYSICS AND baseParameters CANNOT SEE
IT.** This is the fact everything else was built around:

    UNIT swim mode land -> aquatic ... asked gravity false,
    baseParameters now reports gravityEnabled true, onGround false,
    liquidMovement true, freeMover false

The unit was floating -- `onGround` false, plainly not sinking -- and the
accessor still said gravity was on. With no `applyParameters` to write the base
with, NOTHING CAN EVER MAKE THAT ACCESSOR AGREE WITH THE OVERRIDE. Any code that
needs to know "is this thing flying" must be told, not ask the physics.

**IT COST 1684 FAILED RESOLVES IN 44 SECONDS** before that was understood: the
unit floated correctly while every resolver still treated it as a walker and hunted
for a seabed under a submerged port, forever.

**setAutoClearControls(false) WOULD MAKE CONTROLS PERSIST AND IS NOT USED.** It is
global to every control, so `controlFly` and `controlApproachVelocity` would
persist too and the last movement command would repeat forever.

**dd.locomotion.otter's PLAN TO USE applyParameters WAS NEVER EXECUTED**, so the
call had never once been proven in this mod. It was inherited from a design note
as though it had been. `petportsFlopState`'s header names `applyParameters` too,
and only ever as the thing it chose NOT to use.

### controlJump is a press, controlDown is a hold, and neither drops a unit from rest
`fact.unit.platformdrop` -- see also `arch.locomotion.dive`, `todo.locomotion.dropthroughrise`

**MEASURED 2026-09-02, THREE SEPARATE WAYS, AND THEY ARE THREE DIFFERENT FAULTS.**

**FROM REST, controlDown DOES NOTHING.** Held from a standing start it reads as a
crouch and the unit stays put. The fault already recorded against
`petportsTimedDrop` is that the fall-through state's duration is not observable,
so no release condition can be right -- that is about not knowing when it ENDS.
This is that from rest it does not BEGIN.

**HELD, controlJump IS A POGO STICK.** It is a press, not a state: every tick it
is asserted is another jump the moment the feet touch anything. A drop-through
launched from [2493.15,1152.8] was at [2493.8,1156.32] two seconds later -- three
and a half tiles ABOVE the board it was trying to fall off. The platform
drop-through is ONE press of jump while down is HELD; the asymmetry is the whole
mechanism.

**ON SOLID GROUND, THE PAIR IS JUST A JUMP.** With no platform to release, jump
plus down is an ordinary jump, and this chassis's `airJumpProfile` jumpSpeed of
45 at g 120 is an 8.44 tile apex. Logged: `rose 8.00378 tiles above the board,
drop-through`, on a dive solved for none. A drop-through must verify a platform
underfoot first, testing solid BEFORE platform so a tile that is both refuses.

**THIS HYPOTHESIS WAS MARKED DISPROVEN AND WAS RIGHT.** Three drop-throughs
rising 0.2, 0.99 and 1.06 tiles were taken as evidence against a full jump; they
had platforms and released. One clean repro at 8.00 against a predicted 8.44
revived it. Rises are only comparable between launches of the same KIND.

### canPathfind is two gates, and a floating gravity chassis fails both
`fact.pathing.canpathfind` -- see also `arch.locomotion.swimmode`, `proc.pathing.readsource`, `fact.unit.movementparams`

**READ FROM /scripts/pathing.lua 2026-09-02, after weeks of being quoted
second-hand in this mod's comments. The quotes were right.**

    function PathFinder:canPathfind()
      return mcontroller.onGround() or not mcontroller.baseParameters().gravityEnabled
    end

For a swim-mode unit the second half is FALSE -- the override is invisible to the
accessor -- so the gate reduces to `onGround()`. The unit plans when it happens
to touch terrain and sits still when it does not, which presents as
intermittency: "occasionally swims to the target, most of the time just sits".

**IT IS TWO GATES AND THE SECOND IS THE NASTY ONE.** `PathFinder:explore`
re-asks on completion -- `if result == true and self:canPathfind()` -- so a
search that FINISHES while floating has its result thrown away, and because that
branch does not clear `self.aStar` the finder re-explores the same search forever
without ever latching. A unit can fail having started legally, by drifting off
the ground mid-search.

**PathFinder:start TAKES A SCRATCH COPY, WHICH IS THE SEAM.** It reads
`mcontroller.baseParameters()` into a local and MUTATES it -- setting
`airJumpProfile.jumpSpeed` -- before handing it to `world.platformerPathStart`.
Writing one more field into that table is the same kind of act, and it is the
only way to reach edge-type selection, because the parameters argument comes from
an accessor no control override can touch.

**BOTH ARE SHADOWED ON THE INSTANCE**, the same technique `freshPather` already
used for `finder.exploreRate` and the movers, so `PathFinder` itself is untouched
and no other entity is affected.

### A unit's capabilities are a property of the chassis, never of what it is doing
`fact.port.capabilitiesstatic` -- see also `fact.port.typecapabilities`, `arch.locomotion.swimmode`, `dd.port.envpresence`

**MEASURED 2026-09-02, THREE TENTHS OF A SECOND APART:**

    UNIT swim mode diving -> aquatic ... freeMover true
    PETPORT RETIRING unit: the port is out of the water and this chassis
        cannot leave it (footprint wet false, dry true)

`petports_capabilities` read `petports_freeMover()`, which had just become
mode-aware. A unit that happened to be mid-dive told the port it was a free mover
that swims and cannot fly, so the port saw a fish in a dry socket and retired it
-- state and cargo written back, door shut, on a pet doing exactly what it had
been dispatched to do.

**THE PORT POLLS ON ITS OWN CLOCK AND THE MODE CHANGES ON THE UNIT'S.** Any
answer assembled from transient state will eventually be sampled at the wrong
moment; the interval only decides how often. A gravity-switchable chassis
therefore reports as a WALKER for this question always, and expresses "can be in
water" through `avoidLiquid` being false, which earns it the amphibious verdict.

**THE SINKER WAS NEVER EXPOSED TO THIS** -- `avoidLiquid` false and gravity
enabled means it never reports as a free mover at all, so it already took the
walker branch. Worth stating because the symptom invites relaxing the habitat
rules, and the habitat rules were correct.

### Where a pane's sounds come from, and the two routes that do not exist
`fact.pane.panesound` -- see also `arch.pane.petport`, `fact.pane.notooltips`

**MEASURED 2026-09-03, AFTER TWO WRONG ANSWERS SHIPPED.**

    pane.playSound        DOES NOT EXIST on a ContainerPane
    localAnimator         nil in a pane script
    widget.playSound      WORKS, and takes an ASSET PATH

**A ContainerPane's `pane` TABLE IS THREE FUNCTIONS** -- `containerEntityId`,
`playerEntityId`, `dismiss` -- and none is audio. The petport and the upcycler
open through `uiConfig` and are ContainerPanes; the beacon panes open with
interactAction "ScriptPane" and would have it. Same split as
`fact.pane.notooltips`, and this time the docs said so before it cost a round.

**`localAnimator` IS NOT BOUND IN A PANE SCRIPT.** Probed at init and again on a
click:

        petportpane: localAnimator nil, playAudio n/a
        attempt to index a nil value (global 'localAnimator')

The wiki lists that table for client-side animation scripts and names objects and
active items; a pane is neither.

**`widget.playSound(audio, [loops], [volume])` IS THE ANSWER AND ITS ARGUMENT IS
THE TRAP.** Every other function in the widget table takes a WIDGET NAME first.
This one takes an asset path and nothing else, so a call that looks exactly like
the rest of the file is wrong.

**THE OBJECT CAN PLAY THEM AND IT IS THE WRONG SHAPE.** It was built that way
first -- a `sounds` block on the port's animation and a message handler -- and it
works, at the cost of a round trip and positional audio for anyone standing
nearby. Kept only as a fallback while the local route was unproven.

### A status effect gets an animator only if it declares one
`fact.unit.effectanimator` -- see also `arch.module.rgblight`, `arch.module.effects`

**THE `animator` TABLE IS ABSENT IN A STATUS EFFECT SCRIPT UNLESS THE
`.statuseffect` SETS `animationConfig`.** Documented, and load-bearing rather than
incidental: a light and the script that recolours it must be declared in the same
effect file, or the script has nothing to talk to.

**THE animator IS THE EFFECT'S OWN, NOT THE WEARER'S.** `animator.setLightColor`
addresses a light named in the effect's animation, so the name is spelled in the
animation and in the script and nowhere else.

**A STATUS PROPERTY IS THE ONLY SHARED SURFACE BETWEEN AN EFFECT SCRIPT AND THE
UNIT SCRIPT.** They run in separate contexts -- the effect cannot see the unit's
`self` and the unit cannot see the effect's animator -- but both can see the
status controller. `status.setStatusProperty` on one side and
`status.statusProperty` on the other is how a value crosses.

**READ DEFENSIVELY. THE NAMESPACE IS FLAT AND SHARED.** Anything may write a
status property, and a table of the wrong shape reaching `animator.setLightColor`
is a throw inside an update loop -- which takes the effect down and leaves the
unit dark with no obvious cause.

### Who gets a click inside a list row, and it is not who the config says
`fact.pane.rowdispatch` -- see also `arch.pane.rowfocus`, `dead.pane.rowzlevel`, `fact.pane.itemslotbutton`

**READ FROM `StarWidget.cpp`, 2026-09-03**, after two config-level fixes failed:

        bool Widget::sendEvent(InputEvent const& event) {
          for (auto child : reverseIterate(m_members))
            if (child->sendEvent(event)) return true;
          return false;
        }

**CHILDREN ARE OFFERED THE EVENT IN REVERSE ORDER AND THE FIRST TO CONSUME IT
WINS**, so a later-declared sibling should take precedence. IT DOES NOT INSIDE A
LIST ROW. A textbox declared after a full-row button lost the left click anyway,
and declaring it FIRST changed nothing -- the same answer from both ends.
Whatever order a row's `m_members` ends up in, it is not the order written in the
`listTemplate`; a template is a JSON object and nothing promises to preserve it.

**THE RIGHT CLICK IS WHAT DIAGNOSED IT.** A right click falls through the row
button and focuses the field perfectly, because a ButtonWidget handles the LEFT
button only and declines the other. So the field is under the cursor, its bounds
are right, and it works -- it simply never receives the press that matters.
That also rules out hit area, `maxWidth` and backing art as explanations.

**A BUTTON CAN ACT WITHOUT WINNING FOCUS.** The spinner arrows are buttons in the
same rows and they fire with the row button present; only the field, which needs
the press to take FOCUS rather than merely to act, is blocked.

**SO HAND FOCUS OVER RATHER THAN COMPETING FOR IT.** `widget.focus(widgetName)`
resolves by member path -- `Widget::focus` sets the flag and calls
`window()->setFocus(this)` -- so the button that took the click can give it away.


### `landedTreasurePool` has four shapes and the one that ships is a damage-kind map
`fact.fishing.treasurepool` -- see also `arch.fishing.dispatch`

**MEASURED 2026-09-01.** `fishingchuckle` declares a bare string,
`"landedTreasurePool" : "fishinglegendary"`, and the first build assumed that was
the shape. `fishingjerk` declares a TABLE, and handing it to
`root.createTreasure` threw `LuaConversionException: Error converting LuaValue` --
a caught fish that produced nothing and was despawned anyway.

**THE FOUR SHAPES:** a bare name; a flat list `{ "poolName" }`; a map KEYED BY
DAMAGE KIND; and level-keyed pairs `{ { 1, "poolName" } }`.

**THE THIRD IS WHAT ACTUALLY SHIPS**, measured on `fishingjerk`:
`{"default":"fishingcommon","fire":"lofty_crispy_fishingcommon", ...}`. A
monster's pool can vary by the damage kind that killed it, and other mods patch
entries into that map.

**`ipairs` FINDS NOTHING IN IT.** The first version walked the value with
`ipairs`, which yields nothing on a string-keyed table, so it concluded the fish
had no pool and reported a catch with no loot -- a silent failure, not a throw.
The type test has to come BEFORE the array walk.

**`default` IS THE RIGHT KEY FOR US.** A unit does not kill a fish -- it rolls the
pool and despawns it -- so there is no damage kind to key on.

### A refusal that names two causes is worse than one that names the wrong cause
`fact.tooling.mergedrefusal` -- see also `dd.fishing.supply`, `proc.tooling.instrument`, `proc.tooling.session`

**COST 2026-09-03: ONE CONFIDENT WRONG DIAGNOSIS, CORRECTED ONLY BY A CONTROL
TEST.** `drainWork` refused with

    N machine(s) with output, but no deposit crate accepts X or has room

thirty-eight times in one log. Those are two different faults wearing one
sentence. **"No crate accepts X" is a CONFIGURATION error** -- nothing in the
network will ever store the item, and it is still true in an hour with ten more
units; the player ticks a box. **"No crate has room" is a THROUGHPUT signal** --
the filters are right and the fleet is behind; the player adds a unit, or waits.
Opposite responses, one string.

**IT WAS NOT HEDGING -- IT COULD NOT KNOW.** `refusedNames` was built ABOVE the
destination loop, so the message was assembled before either test it described
had run. The word "or" was structural, not cautious.

**THE READING FAILURE IS THE PART TO CARRY.** The ambiguity WAS noticed and then
reasoned past: "the log can't distinguish those two" was written down, and a
conclusion that only holds on the first branch was built anyway. Noticing an
ambiguity and not letting it stop you is worse than missing it, because it
launders a guess as an analysis.

**AND A REPEATED REFUSAL IS NOT A STANDING ONE.** Thirty-eight identical lines
over seven minutes read as a permanent condition. They were thirty-eight samples
of a transient state that never got the capacity to clear. Frequency is evidence
of sampling rate, not of permanence.

**FIXED BY SPLITTING THE TALLY**, decided inside the loop and classified after
it, with a fallback string that fires only if an item is refused and classified
as neither -- which would be a bug in the function rather than a state of the
base.

**GREP FOR THE SHAPE, NOT THE FUNCTION.** Any refusal joining two causes with
"or" is a candidate for the same failure.

### A despawned fish keeps existing, and keeps swimming, for over a second
`fact.fishing.despawnwindow` -- see also `arch.fishing.dispatch`, `dd.fishing.catchwindow`, `arch.fishing.network`

**MEASURED 2026-09-03, TWICE IN ONE 24-DISPATCH LOG.** `despawn` is a plain
global in vanilla's `fishingMonster.lua` and it is a STATE TRANSITION, not a
delete: it routes the fish into `disappearState`, which clears the death sound
and particle burst before killing. The entity therefore survives the call.

**HOW LONG, AND IT IS NOT A FRAME.** `fish 1280` was caught at `19:59:46.079`
and its port did not report it gone until `19:59:47.732` -- **1.65 seconds**.
Throughout that window `world.entityExists` returned true, `world.entityPosition`
returned a position, and the fish MOVED: 11 tiles west of where it was caught.

**SO A CAUGHT FISH IS STILL A VALID TARGET TO ANYTHING THAT ASKS THE OBVIOUS
QUESTIONS.** Both existence tests in `fishWork` pass on a fish that has already
been rolled. Measured on `fish:570` as well, where a second unit travelled 10.5
tiles before the target blinked out.

**THE FAILURE IT PRODUCES IS LABELLED `drop is gone`**, because the target-gone
path is shared and names the common case. Cosmetic, and noted only so the next
reader greping fish failures knows that string is one of them.

## DISPROVEN

### Sinker jumping underwater was never a liquid problem
`dead.locomotion.sinkerjump` -- see also `arch.pathing.climbsteer`, `arch.pathing.solvelaunch`, `fact.pathing.airauthority`, `dead.pathing.waterdrag`

**FILED AND RESOLVED 2026-09-01. THE PREMISE WAS WRONG.** Filed as "a sinker
walks the seabed correctly and struggles with JUMPS while submerged", with
`liquidImpedance` and liquid friction as the standing suspects. Neither was
involved. **NOTHING ABOUT THE FAILURE WAS SPECIFIC TO THE SINKER, TO WATER, OR
TO THE CHASSIS.**

**WHAT KILLED THE LIQUID THEORY, IN ONE READING OF THE FIRST LOG.** The unit's
airborne vy decayed by exactly -10.0000 a tick with no terminal velocity,
reaching -42.7 and still accelerating -- g 120, which is vanilla's 80 times
`gravityMultiplier` 1.5. Dry-air physics to four decimals, nine tiles under the
waterline. The amphibious unit in the SAME log at the SAME moment was capped at
-1.83. Two chassis, one water, one drag-limited and one in free fall.

**IT ALSO CONFIRMED `minimumLiquidPercentage` REACHES THE MOVEMENT CONTROLLER**,
which `fact.pathing.liquidthreshold` had inferred from behaviour rather than
measured. And the arc mover zeroes `liquidImpedance` every airborne tick anyway,
so the prime suspect was never reachable from an arc in the first place.

**THE REAL CAUSE WAS `arch.pathing.solvelaunch`'s REACH CLAMP SKIPPING PLANS
WHOSE LAUNCH vx WAS ZERO**, flattening a climb-then-traverse into a diagonal that
flew through the ledge the climb existed to clear. Fixed by deleting the guard
and adding `arch.pathing.climbsteer`. **A GROUND OR AMPHIBIOUS UNIT WOULD HAVE
FAILED IDENTICALLY** -- an earlier log has the same jump shape succeeding from
one tile over, before the terrain changed.

**THE LESSON IS THE ONE `dead.pathing.waterdrag` ALREADY TAUGHT AND THIS ENTRY
RE-LEARNED.** "It is in water and it moves badly" has now pointed at liquid twice
and been wrong twice. Both times the per-tick trace settled it immediately. The
entry was written with that warning in its own body and the warning was correct.

### THE LEDGE FALL WAS THE PLANNER'S vx STEERING THE MOVER
`dead.pathing.plannersteer` -- see also `arch.pathing.brakelatch`, `arch.pathing.nosteer`, `proc.tooling.instrument`

**BELIEVED 2026-09-01, WRONG, AND THE REASONING WAS GOOD.** A unit walking off a
ledge above `[2536,1149.8]` lost all horizontal velocity mid-fall and landed a
tile low and 1.09 short, six times identically. The theory: the arc mover steers
x toward `pather.edge.source.velocity[1]`, a walk-off has no launch record to
substitute, and A* stores vx 0 on the vertical part of a walk-off arc. Deceleration
profile matched a velocity command; the planner really does store zeroes there.

**WHAT KILLED IT.** The steering was deleted and the positions came back
IDENTICAL TO THE DECIMAL -- `2534.65 -> 2534.91 -> 2534.91 -> 2534.91` before and
after. A change that removes the only horizontal command in the mover and alters
nothing was never the cause.

**THE REAL ONE IS `arch.pathing.brakelatch`.** Two mechanisms producing the same
curve, and only one sample per script tick to tell them apart.

**THE DELETION STANDS ANYWAY**, for the reason it was made rather than the one it
was sold on -- see `arch.pathing.nosteer`. A correct change argued from a wrong
diagnosis is still a wrong diagnosis, and shipping it as "the fix" is what made
the next round of evidence harder to read.

### LIQUID DRAG WAS BRAKING THE UNIT AT THE WATERLINE
`dead.pathing.waterdrag` -- see also `arch.pathing.brakelatch`, `arch.tooling.flighttrace`, `proc.tooling.instrument`

**BELIEVED 2026-09-01, IMMEDIATELY AFTER `dead.pathing.plannersteer`, AND WRONG
FOR THE SAME UNDERLYING REASON.** Three walk-off falls sorted perfectly by one
variable: one through open air held vx 8.17 for four tiles, two that ended in
water decayed. The waterline at the ledge was independently confirmed -- a
swimmer floats at y 1149.79 there -- and the decaying tick was the one where the
body first straddled it. `liquidFriction` 5.0 and `liquidImpedance` 0.5 are the
chassis defaults and are large enough to do it.

**WHAT KILLED IT.** A per-tick trace, in one run. The same collapse -- vx 8.00 ->
3.07 -> 0.00 -- occurred at `[2510.02,1161.97]` with `medium air`,
`liquidMovement false`, NINE TILES ABOVE ANY LIQUID, and stayed at exactly zero
for four more ticks of dry fall.

**THE CORRELATION WAS REAL AND MEANT NOTHING.** The latch bites on the FIRST
ARC-MOVER TICK of a flight; on the ledge route that tick happened to be the one
the body touched water. Two of three falls "entering water" is the sort of
agreement a single sample per tick will hand you.

**THE COST OF ASSUMING RATHER THAN MEASURING WAS A CONFIG CHANGE THAT PROVED
NOTHING.** `liquidFriction` and `liquidImpedance` were written explicitly into
the monstertype at their defaults, as a control. The trace's own chassis line
showed `baseParameters()` already reported exactly those values, so the control
could not have discriminated anything. Reverted.

### THE SHORTFALL WAS A LATE WALK -> ARC HANDOVER
`dead.pathing.latehandover` -- see also `arch.tooling.flighttrace`, `arch.pathing.brakelatch`

**BELIEVED 2026-09-01, AND IT IS REAL BUT AN ORDER OF MAGNITUDE SMALLER THAN
CLAIMED.** The unit does stay on the Walk edge for one or two airborne script
ticks before the pather advances to the Arc -- measured, two ticks at the 2533.8
lip -- so it enters the trajectory already falling, with no equivalent of
`moveJump`'s `setPosition` snap onto the plan's initial conditions.

The estimate was 0.57 tiles of the 1.09 shortfall, reconstructed from a departure
0.31 below the plan's arc source.

**MEASURED WITH `planX`, IT IS ABOUT 0.2.** The trace reports `off` at every
tick, and on a clean fall it reads 0.22, 0.23, 0.13 -- the unit is very nearly on
the planned arc when the Arc edge takes over, because the walk mover's continued
horizontal drive happens to match what the arc wanted.

**WHAT IS LEFT OF IT.** The unit reaches its planned COLUMN and arrives roughly
0.6 too low, so on a shoreline block it clips the lip instead of landing on it.
Costs nothing on every route measured -- the plan continues into Swim edges and
the unit swims off at a clean 8.00 -- and would matter where the tile below the
landing is a drop rather than water. NOT WORTH A SESSION at 1 off-plan landing in
38 jumps. If it becomes worth one, `arch.tooling.flighttrace` already logs the
number.

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

### Putting `eatAction.lua` back
`dead.fuel.eataction` -- see also `arch.fuel.groundfeed`, `dd.fuel.selffeed`

The obvious fix for "pets no longer eat food thrown at them", and it could
never have worked.

Vanilla did the job with `eatAction.lua` and `begAction.lua`, and both left all
five scripts lists when `petports_fuel` replaced hunger. That IS why nothing had
looked at the ground since -- the diagnosis is right as far as it goes. The
monstertypes still carry `hungerStarvingLevel` and the `eat` / `beg` /
`starving` `actionParams`, left in place as vanilla's shape, and they are inert.

**RESTORING THEM WOULD CHANGE NOTHING, because the appetite cannot be PICKED.**
The monstertypes already record it: with `strictPortTethering` on,
`petports_leashTask` never returns nil for a tethered unit and queues at
`LEASH_SCORE` 120, while every appetite caps at 100. `petBehavior.run`'s pick
loop breaks rather than continues, so a leashed unit never reaches an appetite
branch at all.

So this had to be a work generator, like everything else here. It is worth
recording as a dead end rather than as an obvious non-option, because the
scripts-list line is the first thing anyone will find when asking why pets stop
eating, and it looks like a complete answer.

**A SECOND ATTRACTION THAT IS ALSO WRONG:** lowering `LEASH_SCORE` or raising
the appetite cap so hunger CAN interrupt. That reopens the exact behaviour
`strictPortTethering` exists to suppress, for a mechanism the work ladder
already expresses better -- and the ladder version can be ordered against
deposit and collection, which an appetite score cannot.

### Reading another entity's interactivity
`dead.farming.trapinteractive` -- see also `fact.farming.harvestable`, `arch.farming.traps`

The first design for trap ripeness, and the better one had it existed.

`harvestable.lua`'s `setStage` ends by calling `object.setInteractive(true)`
exactly when the current stage carries a `harvestPool`. That is a precise
ripeness bit, maintained by the object itself every `update()`, costing no call
into its script and no arithmetic on our side -- the direct equivalent of what
`world.farmableStage` is for a crop.

**RETAIL EXPOSES NO BINDING TO READ IT.** Confirmed against the docs and the
source 2026-09-03. There is no `world.isEntityInteractive`, no
`world.entityInteractive`, and no object-side getter reachable cross-entity.
Interactivity is set and never asked.

**The fallback is `activeAge` against a computed threshold** -- see
`arch.farming.traps`. It works and is verified, but it is strictly worse in two
ways worth recording, because if a binding ever appears both go away: the
threshold is a reconstruction of arithmetic the object already did, so it is
late by up to the spread of the duration rolls; and it can be wrong about
modded configs in ways the object itself never is, which is the whole reason
`todo.farming.trapagelock` and the stall check exist.

**WORTH NOTING WHAT WAS NOT TRIED: speculative dispatch.** `dropHarvest` is a
guaranteed no-op when unripe, so ripeness could have been skipped entirely and
every known trap visited on a slow cadence. Rejected because it spends walks and
puts working traps on the failure backoff ladder for something that is not a
fault. One `callScriptedEntity` per candidate is cheaper than mislabelling.

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

### AN ESCAPE CLAUSE FOR A DISPLACED UNIT -- TWO VERSIONS, BOTH A LICENCE TO LEAVE
`dead.pathing.escapeclause` -- see also `arch.pathing.mediumenforcement`, `dead.locomotion.pelagic`, `arch.unit.exitpaths`

`planMediumValid` used to relax its rule when the unit was ALREADY somewhere it
may not be. The reasoning was sound and stated in the file: "do not ENTER a
medium you are not allowed in" is not "never be in one", every route out of water
begins with edges in water, and refusing those turns a recoverable mistake into a
permanent one.

**V1, A BLANKET PASS.** While the unit was out of medium, EVERY plan was accepted.
That latches -- a unit that has left the water is out of medium, so the next plan
is unconditional, so it need never come back.

**V2, A BOUNDED PREFIX.** The licence covered the leading run of illegal waypoints
and ended at the first legal one. Strictly better, and still wrong, because ANY
water ends the escape -- INCLUDING A DIFFERENT POOL. Measured 2026-08-31 on a
drain-held air gap: an aquatic unit blind-steered into the gap was handed a
25-edge plan, five Fly edges across and then Swim, licensed end to end as "a
route out". It crossed. A 17-edge plan later did the same over a pool rim.

**THE PREMISE WAS THE ERROR, NOT EITHER BOUND.** Both versions assume the unit is
the right thing to ask for a rescue plan. It is not. A displaced pet wants to be
AT ITS PORT; the port can put it there instantly, for free, with no pathing at
all; and `rehomeUnit` is the rescue every recovery ladder in this mod already
ends with. Letting the pather improvise a way back is strictly worse than a
teleport and, measured twice, is a licence to go somewhere else entirely.

**WHAT REPLACED IT.** The rule is unconditional -- no chassis plans a route
through a medium it may not occupy, including out of one -- and the unit's own
position is checked as edge zero. A displaced unit issues no control and holds
still; `petports_outOfMedium` reports the condition and the port's `mediumCheck`
re-homes it after two consecutive polls of `ENVIRONMENT_INTERVAL`.

**A UNIT THAT CANNOT MOVE IS NOT STRANDED, AND THAT IS WHAT MAKES THE
UNCONDITIONAL RULE SAFE.** Standing still is the SIGNAL. It was only ever unsafe
while nothing was watching for it.

**TWO POLLS AND NOT ONE.** `petports_mediumAt` requires EVERY row the body
overlaps to be at or above `PETPORTS_SUBMERGED_FILL`, so a swimmer riding just
under a surface can read "air" without having gone anywhere. Ten seconds of a
genuinely beached unit costs nothing; teleporting a working one off a job because
it bobbed is a visible bug.

### world.oceanLevel cannot find the surface of a pool
`dead.locomotion.oceanlevel` -- see also `arch.locomotion.dive`, `todo.module.fishing`

**PROPOSED AND REFUSED 2026-09-02, BEFORE ANY CODE WAS WRITTEN.** The dive needs
the surface of the water a fish is in. `world.oceanLevel(position)` returns a
surface, is already used twice in this mod -- `fishingSpot` computes its depth
band from it -- and would replace a bounded flood search with one call.

**IT ANSWERS A DIFFERENT QUESTION.** It reports the WORLD's ocean level, which
says nothing about the particular body of water a fish happens to be in. A
player-built tank thirty tiles up has a surface `oceanLevel` has never heard of;
so does a cave pool below sea level. The premise of the whole feature is
adversarial player terrain, and on an ocean world it would look correct in every
test right up until someone built a fish tank.

**THE ONLY TRUSTWORTHY SURFACE IS ONE REACHED CONTIGUOUSLY FROM THE FISH**, which
is what `arch.locomotion.dive` traces. The cost turned out not to matter -- real
traces measured four to seven tiles on open pools -- so this was never a speed
trade, just a correctness one.

**KEPT AS A DEAD ENTRY BECAUSE IT IS THE OBVIOUS OPTIMISATION.** Anyone looking
at a 400-tile trace budget will reach for `oceanLevel` within a minute, and the
reason it fails is invisible on the test world where it works.

### zlevel and declaration order do not decide who takes a row's click
`dead.pane.rowzlevel` -- see also `fact.pane.rowdispatch`, `arch.pane.rowfocus`

**TWO THEORIES, TWO BUILDS, BOTH WRONG, 2026-09-03.** The symptom throughout: a
textbox in a list row would not take focus while a full-row button was present.

**THEORY ONE -- RAISE THE FIELD'S zlevel.** Shipped at `zlevel 5` against the
button's -1, together with hiding the button. Focus worked, and because two
changes landed at once neither was proven. Restoring the button broke focus again
with the zlevel untouched, which retires the theory: zlevel orders RENDERING and
does not order who receives the press.

**THEORY TWO -- DECLARE THE FIELD FIRST IN THE listTemplate.** Argued from
`Widget::sendEvent`'s `reverseIterate`, which does mean a later sibling wins.
Shipped, and changed nothing. The field had already been declared after the
button from the start and lost anyway, so both orderings lose -- which is the
same answer twice and says the config's order never reaches `m_members`.

**A THIRD, KILLED BEFORE IT SHIPPED -- THE FIELD HAS NO BACKING SO ITS HIT AREA
IS TINY.** Plausible, and the right click disproved it before the build was
tested: a right click reaches the field and focuses it from the same pixel. The
backing was kept anyway, as decoration, which is all it ever was.

**WHAT ACTUALLY WORKS IS IN `arch.pane.rowfocus`** -- the button takes the click
and calls `widget.focus` on the field. THE DURABLE LESSON IS NARROWER THAN THE
THREE THEORIES: the input a widget RECEIVES and the input it CONSUMES are
different questions, and only the second is visible from a config file.


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

**DELIBERATELY NOT FIXED -- see `dd.pathing.nodeformula`.** A settled unit
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

### The OpenStarbound repo's first commit is unmodified retail source
`ref.tooling.osbaseline` -- see also `proc.tooling.controlfirst`, `fact.pane.rowdispatch`

**WHICH TURNS "IS THIS VANILLA OR OPENSTARBOUND?" INTO A DIFF.** The oldest
commit in the repo is the 1.4.4 source as shipped, with no edits. So for any
engine behaviour this mod relies on:

        git log --oneline --reverse | head -1
        git diff <first-sha> HEAD -- source/windowing/StarTextBoxWidget.cpp

An addition is OpenStarbound's and may be configurable, may be recent, and is
not something a player on retail has. An unchanged line is vanilla's and has
been true since 1.4.4.

**IT IS ALSO THE ANSWER TO A QUESTION THIS DOCUMENT KEEPS ASKING FROM MEMORY.**
Recalling what vanilla did, and stating it as though it were read, is how three
widget theories in one session were argued from things nobody had looked at --
see `dead.pane.rowzlevel`. The baseline removes the excuse: there is no case
where vanilla's behaviour has to be remembered.

**TWO DIFFS WORTH RUNNING WHEN SOMEBODY IS NEXT IN THERE.**
`StarTextBoxWidget` -- whether `KeyboardCaptureMode` is an OpenStarbound
addition, which would suggest a config key selecting whether a focused field
swallows key BINDINGS as well as text, and that is what decides whether Enter
can reach chat. And `StarListWidget` -- whether a row's `m_members` order comes
from the template, which `fact.pane.rowdispatch` concludes it does not, from two
failed experiments rather than from reading it.


## BACKLOG

### Harvestables with a degenerate `activeTimeRange` are inert, and we only say so
`todo.farming.trapagelock` -- see also `fact.farming.harvestable`, `arch.farming.traps`

**OPENED 2026-09-03, DELIBERATELY NOT FIXED.**

`harvestable.lua` reads an omitted `activeTimeRange` as a span of ZERO, so an
object whose author meant "always active" never ripens for anybody -- us or the
player. `fact.farming.harvestable` has the full trace.

**THE FIX IS TWO LINES AND THE COST IS NOT.** Normalising the degenerate range
in `init()` covers every consumer at once, ripening and animation state
together, and fixes every modded harvestable rather than ones we know about:

    if (self.timeRange[2] - self.timeRange[1]) % 1.0 == 0 then
      self.timeRange = { 0, 0.9999 }
    end

**BUT JSON PATCHES DO NOT APPLY TO `.lua`.** Shipping that means OVERWRITING a
vanilla asset outright -- inheriting the file across game updates and
hard-conflicting with any other mod that does the same. For a mod whose whole
posture is that vanilla is a fixed constraint, that is a real departure, and not
one to make during a 1.0 push. `groundPet.lua` was deferred on the same
reasoning at a larger scale.

**SO WE DETECT AND REPORT.** `trapProfile` classifies both lock kinds from
config and `reportTraps` says so ONCE PER ENTITY PER SESSION, naming the cause
in terms a player can hand to whoever ships the object. `self` is a fresh table
per script context, so the set empties on beam-out.

**PER PORT, WHICH IS THE ONE COMPROMISE.** Two ports with overlapping coverage
each warn once about the same broken trap. Deduplicating needs shared state that
does NOT persist, and the only shared state available is `world.properties`,
which does -- a permanent record of a transient complaint is the worse failure.

**REOPEN IF** a modded harvestable with this bug turns out to be common enough
that players hit it in practice, or if an upstream fix lands in OpenStarbound
and the overwrite becomes a patch against something narrower.

### Animals move, and nothing chases them
`todo.farming.animalsmove`

**TRIAGED 2026-08-30 -- FOLDS INTO `todo.pathing.movingtarget`.** Same root cause at a different altitude: a ground target resolved once against an entity that wanders. The `ANIMAL_REACH` measurement stays here as evidence; the fix belongs there.

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

**TRIAGED 2026-08-30 -- CLOSED, NOT OBSERVED.** The behaviour it asked us to watch for has not appeared at any point in testing since the change landed. Marked as not happening rather than left open indefinitely.

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

**TRIAGED 2026-08-30 -- DEFERRED, AND THE ORDER IS DELIBERATE.** The whole petports system exists to furnish the Nicemice M.A.U.S. T6 ship, so PETPORTS HAS TO BE PRODUCTION-READY BEFORE the Nicemice pet is built. The colonyTag sweep happens when we get there.

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

### The arrival brake has no floor and only one look to use it
`todo.pathing.brakefloor` -- see also `fact.pathing.arcmoverthrottle`, `arch.pathing.arrivalsign`, `arch.pathing.solvelaunch`

**CLOSED 2026-09-01 BY `arch.pathing.arrivalsign`.** Kept because the triage below was WRONG in a way worth preserving, not because the defect survives.

**TRIAGED 2026-08-30 -- PRIORITY 2, AND THAT WAS THE ERROR.** "Nothing is failing on it; it is a note about why the current margin exists rather than a defect." It was a defect, it was failing, and the reasoning that said otherwise named two conditions that would break it -- a narrower chassis, a larger `LAND_BRAKE_REACH` -- and missed a third. OVERLAP ONLY SAVES A LANDING WHOSE NEIGHBOURING TILE IS AT THE SAME HEIGHT. Onto a step up, half a tile short means falling down the side of it, and the body being 1.6 wide buys nothing. Measured three times on 2026-09-01 at two sites before anyone re-read this entry.

The gate in `petportsArcMover`:

    if landing ~= nil and not pather.petportsLanding and vel[2] < 0
      and math.abs(here[1] - landing[1]) <= LAND_BRAKE_REACH
      and here[2] <= landing[2] + LAND_BRAKE_CEILING then

Descending, within 0.5 of the landing's column, and not more than 1.0 above it.
TWO PROBLEMS, both measured 2026-08-30, neither currently causing a failure.

**NO FLOOR.** `here[2] <= landing[2] + 1.0` is satisfied by every y beneath the
landing, without limit, so "arrived" means "near the column" and not "at the
landing". A unit still half a tile short and half a tile high has its horizontal
velocity zeroed and drops the rest of the way vertically:

    ARCMOVER arrived at landing [2505,1166.8] from [2504.67,1167.3] vel [8,-10.5]

That is the whole of the residual -0.33 seen on the death course.

**ONE LOOK, AND THE GROUNDED BRANCH RETURNS ABOVE IT.** The test is airborne-only
and the window is 0.5 x 1.0, while a fast descent covers up to 1.9 tiles per look
at script delta 5. It missed three of eight jumps on the platform course. Jump
four missed by 0.15 tiles of ceiling and was caught by `moveLand` instead:

    02.489  [2516.64,1178.95]  vel [7.95553,-23.74]  onGround false   1178.95 > 1178.8
    02.569  [2517.29,1177.8]   vel [5.8424,-1.5353]  onGround true

**WHY THIS IS NOT URGENT.** A 1.6-wide body braked half a tile short of a node
still overlaps that node's tile, so single-wide platforms survive it. That is the
body size doing the work, not a margin anyone chose, and it stops being true if
the chassis ever gets narrower or `LAND_BRAKE_REACH` ever grows.

### The planner cancels jumps the movement controller does not
`todo.pathing.jumpmodel` -- see also `fact.pathing.partialjump`

**DEFERRED 2026-09-03 -- ONLY IF IT BECOMES AN ISSUE.** No emergent pathing
fault in the field points at this, and the unit roster has grown a great deal
since it was last measured. It reopens on an OBSERVED wall-clip or ceiling
overshoot in play, not on a re-read of the reasoning below.

**TRIAGED 2026-08-30 -- PRIORITY 3.** THE WALL-CLIP CASE NOW LIVES HERE ALONE. A separate adversarial-testing entry was struck on 2026-08-30 once the courses passed, and the one scenario it still named -- an arc whose plan is wrong at both ends -- belongs here. Still unmeasured against the current solver, and now joined by branch 1's ceiling overshoot from `arch.pathing.solvelaunch`.

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

**DEFERRED 2026-09-03 -- ONLY IF IT BECOMES AN ISSUE.** `moveLand` is still
vanilla's four lines, confirmed by grep: there is no override anywhere in the
tree. Nothing in the field has been traced to it, and the arrival brake already
took away the failure that used to reach it. It reopens on an OBSERVED landing
fault, and nothing else.

**THE 2026-08-30 GAP IS NOW ANSWERED.** Every other backlog entry was given a
priority or a decision that day and this one was not raised, so its absence was
a GAP rather than a judgement. This deferral is the judgement it never got.

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
`todo.pathing.fallbackpather` -- see also `fact.pathing.smalljump`, `fact.unit.statemachine`

**ATTEMPTED 2026-09-01, SHIPPED A CRASH, AND IS STILL NOT VERIFIED IN ITS OWN
PATH.** Both fallback sites in `petports_flyapproach.lua` now build through
`petports_freshPather` instead of a bare `PathMover:new`, and the ground site's
`moveSwim` re-assertion was deleted as dead. The fly site's `moveFly` block
SURVIVED, because `freshPather` binds `moveJump`, `moveWalk`, `moveArc`,
`moveSwim`, `timedDrop` and `keepDropping` but NOT `moveFly`.

**THE CRASH: `freshPather` IS A FILE-LOCAL, NOT A GLOBAL.** It is forward-declared
`local freshPather` in `petportsTaskAction.lua` so `tryVentRoute` can call it
above its own definition, and that declaration's own header says it must stay an
assignment. A local is invisible across files, so the first version's bare call
from `petports_flyapproach.lua` resolved to a nil global:

    attempt to call a nil value
      [C]: in global 'freshPather'
      petports_flyapproach...:1328: in global 'approachPoint'
      /monsters/pets/actions/inspectAction.lua:33: in field 'update'

It killed the unit one tick after a beaching. `petports_freshPather` is the
wrapper that file now exposes; a wrapper rather than promoting the local, because
the forward declaration is load-bearing and two names for one function with
different visibility is how this recurs.

**AND THIS ENTRY'S MEASURED SCOPE WAS WRONG.** It said `approachPoint` has four
callers, two in `petportsTaskAction` and two in `petportsSleepAction`, and
concluded only a fresh spawn going straight to rest could reach the fallback.
**VANILLA'S OWN ACTION STATES CALL `approachPoint`** -- the traceback above is
`inspectAction` doing it, and follow, beg and pounce are the same shape. So the
original wrong-jump was far more live than recorded, and the fix now sits on a
hot path rather than a rare one.

**WHY IT IS STILL OPEN.** The intended path -- a fresh spawn reaching
`petportsSleepAction` before it has ever held a task -- remains unexercised,
because every chassis carries `petports_allowSleep: false` and sleep is
unreachable by configuration. What proved the code runs at all was a vanilla
action hitting it by accident.

**TRIAGED 2026-08-30 -- PRIORITY 6.** The highest-priority pathing item on the list. It is narrow but it is a REAL wrong-jump on a real path, and the fix -- have the fallback call `freshPather` -- is small.

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

### Three overlapping recovery ladders
`todo.pathing.recoveryladders`

**CLOSED 2026-09-03 -- THE LADDERS SERVE THEIR PURPOSES WELL ENOUGH.** All
three are still present and verified in place; the overlap was never the
problem the entry assumed it might become, and by 2026-09-03 the stuck-unit
cases they were built for had closed to the point where consolidating them
would be a change with nothing to gain. Kept, not deleted, because the
substring match below is a real fragility and this is where it is written
down: reopen if a reworded log line ever silently stops matching.

`RECALL_LIMIT` -> `STRANDED_LIMIT` -> `rehomeUnit`, on top of `TASK_DEADLINE` and
a four-tier `FAILURE_BACKOFF`. rehomeUnit is instant, free and always works.
Worse, `noteFailure` classifies strandedness by SUBSTRING-MATCHING the failure
reason text -- a structured outcome field costs nothing and cannot silently stop
matching when someone rewords a log line.

### Smaller ones
`todo.tooling.smaller`

**TRIAGED 2026-08-30 -- THE `pad = 0` LINE IS ANSWERED.** Tight corridors are working, tested this session alongside the arc mover fix. The other items in this list are untouched.

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

**TRIAGED 2026-08-30 -- WILL NOT FIX.** The upcycler is essentially complete and the duplicated slot order has not moved. Linking the two files now buys nothing on a machine nobody is still changing.

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

**TRIAGED 2026-08-30 -- PRIORITY 7, BUT DEFERRED UNTIL PIPES.** The highest-priority item on the backlog and still not next: both entry sites should run the SAME validation rather than site A being hardened alone, and vent pipes rewrite what a hop IS -- see `plan.vent.pipes`. Hardening entry site B against the current instantaneous model would be work done twice.

`petportsTaskAction` calls `petports_ventTravel` from two places -- "already
touching" and "walked to it via approachPoint". The fail-closed hardening went on
the FIRST only. The second, which is the ORDINARY case, still does
`local ok = pcall(...)`, discards the arrival position, does not blacklist a
refusing vent, does not verify the landing against the plan, and does not count
the hop against `MAX_REPEAT_HOPS`. Both are labelled in the log
(`[ENTRY SITE A]` / `[ENTRY SITE B]`).

### The upcycler is the last pane holding its own strings
`todo.pane.tooltipstrings` -- see also `arch.pane.stringtable`, `dd.upcycler.bakedindicators`

**DONE 2026-08-30.** The upcycler is migrated and all four panes are on the shared string table. `Replace Me` is gone. Kept rather than deleted because `todo.art.runninglights` names it.

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

**TRIAGED 2026-08-30 -- SHINE LAYERS ARE THE REMAINING WORK, AND THEY SPLIT.** All four panes need one. THE TWO BEACONS ARE READY FOR THEIRS; the petport and the upcycler are NOT, because their layouts are still moving. Deferred until the rest of the petport's UI is complete -- sizing a shine layer to a pane that is about to be compressed means doing it twice, which is the same reasoning the entry already gives below.

**NEXT SESSION:**

- **The upcycler's reagent indicator** -- the drawn line from the checkbox
  column to the reagent slot that replaces a tooltip. Open question: static art
  baked into the pane background, or a widget that only draws when at least one
  rule is ticked. Static is trivial and always correct while neither end moves.

**DONE 2026-08-30 -- ALL FOUR PANES NOW CARRY FINISHED TITLE ICONS.** The
upcycler's and the petport's landed overnight, replacing their placeholders; the
two beacons landed in the session after.

THE BEACON PAIR ARE STATE-DRIVEN rather than static -- an on and an off variant,
swapped when the enabled box is ticked and seeded from the beacon's real state at
init. One shared implementation in `petports_paneicon.lua` rather than six lines
copied into two panes. The route is `pane.setTitleIcon`, per
`fact.pane.titleicon`.

ALSO DONE, AND IT WAS THE PART THAT LOOKED WRONG ON SCREEN: all four panes now
agree on the gap between the header icon and the title text. See
`fact.pane.titlepadding` -- it is string padding, and nothing else reaches it.

**DEFERRED UNTIL THE LAYOUTS ARE FINAL, AND THE ORDER IS THE POINT:**

- **The diagonal shine layer on all four backgrounds.** It has to be sized
  precisely to each pane, and the panes are going to be COMPRESSED once they are
  feature complete. Doing it first means doing it twice.
- **Slot targeting graphics** are effectively baked into the pane backgrounds,
  so they come after the same compression for the same reason.

### Sinker locomotion -- ground pathing that will not swim
`todo.locomotion.sinker` -- see also `fact.pathing.liquidthreshold`, `dead.locomotion.pelagic`, `todo.unit.species`

**PROVEN VIABLE AND VERIFIED IN GAME 2026-09-01. THE QUESTION THIS ENTRY ASKED
IS ANSWERED YES.** A test chassis walked the seabed, planned and executed. What
remains is not research -- it is building the thing as a real chassis.

**THE MECHANISM IS `fact.pathing.liquidthreshold`** and lives there rather than
here. Two parameters on `movementSettings`:

    minimumLiquidPercentage   2.0   the search stops believing water exists
    liquidBuoyancy            0.0   or it bobs and there is nothing to see

**THE TEST ARTEFACTS ARE IN THE TREE AND ARE NOT A CHASSIS.**
`monsters/lofty_petports/amphibious/petports_sinkertest.monstertype` and
`items/lofty_petports/units/petports_unit_sinkertest.item`, both copies of the
amphibious pair. They deliberately SHARE the amphibious category so they wear
the axolotter's body with no new art. **DELETE THEM WHEN THE REAL CHASSIS
LANDS** -- a test variant left in the tree becomes a shipping one by accident,
and this one is indistinguishable from a Wader on sight.

**WHAT A REAL SINKER STILL NEEDS**, none of it engine research:

- Its own type, categories, monsterpart and animation, per the rule the test
  variant deliberately breaks.
- A creature design. **IT IS THE CRAB** -- see `todo.unit.species`.
- A decision on `liquidImpedance`, left untouched during the test on purpose. If
  the unit walks the bottom at half pace, that is `default_actor_movement.config`
  doing its job and it is a tuning question, not a defect.
- Its own deny list. It inherits the amphibious lava / corelava / poison list
  today, and a chassis that cannot perceive water is exactly the one that most
  needs the forbidden-liquid test to keep working.

**THE ORIGINAL FRAMING WAS RIGHT ABOUT VANILLA AND WRONG ABOUT WHY IT MATTERED.**
Vanilla ground monsters do walk into water and keep walking -- but `groundMovement.lua`
contains no pathfinder at all, so that behaviour is reactive steering and not
ground pathing that will not swim. Copying it would have meant giving up dispatch
to specific targets. The route that worked came from the threshold instead.

**THE PELAGIC CLAIM SURVIVES UNCHANGED -- SEE `fact.pathing.watercrossed`.** The
aquatic unit seen leaving the water had been put there by our own blind-steer
fallback, not by a plan. That was always a gravity-DISABLED question and this was
always a gravity-ENABLED one.

### The species roster
`todo.unit.species` -- see also `todo.item.acquisition`, `todo.locomotion.sinker`, `todo.unit.recolour`, `dd.unit.specialization`, `todo.art.invisibleframe`

**FILED 2026-09-01, ABSORBING todo.unit.names.** That entry said "Axolotter is
the only settled species" and deferred the rest until art existed. Four more are
settled now, so the deferral is spent and the naming question was never separable
from the creature design anyway -- a name is the last line of a design, not a task
of its own.

**ONE ENTRY, NOT FIVE.** Five thin per-creature entries would rot as a block and
be pruned as a block. They also share every dependency: the same monsterpart
files, the same art pass, the same rename window.

**THE ROSTER, AS SETTLED 2026-09-01.**

    amphibious   Axolotter          settled, name and creature
    aquatic 1    dumbo octopus      creature settled, unnamed
    aquatic 2    marimo mossball    creature settled, "marimomo" tentative
    ground       alien ant          creature settled, unnamed
    flyer        bat-adjacent       direction settled, details open
    sinker       crab               creature settled, unnamed

**THE SINKER IS A REAL CLASS NOW, NOT A MAYBE.** It was listed here as "no
design" while the locomotion was an open question. That question was answered
2026-09-01 -- see `todo.locomotion.sinker` -- and the crab is its creature. Six
species across five locomotion classes.

**AQUATIC HAS TWO AND THAT IS THE STRUCTURAL FACT ON THIS LIST.** Every piece of
naming and asset machinery written so far assumed one species per locomotion
class. It is not one-to-one, so `drone_placeholder` and its siblings cannot be
renamed to their locomotion class -- the rename has to go to the SPECIES, and the
aquatic sheet has to split before it is named. This is the thing that gets missed.

**THE BAT IS THE ONLY ONE THAT CANNOT BE DRAWN YET.** The other four have enough
design to start art against. A flyer needs its silhouette settled before the
`flopping` and `invisible` states are authored, so it gates its own animation
work and nothing else's.

**THE RENAME WINDOW IS STILL OPEN AND STILL CLOSES HARD.** `drone_placeholder` is
free to rename now and expensive once there are several variants in the wild --
unchanged from the absorbed entry, and now more urgent because five names arrive
at once rather than one.

**THE ALIEN ANT CARRIES AN ACQUISITION CLAIM**, not just a design: it appears in
hive and shroom biomes. That is the only species so far whose design says where a
player finds it, and it belongs to `todo.item.acquisition` as much as here.

**BATCH THE ANIMATION WORK.** The `flopping` state is already in all five sheets
(`arch.locomotion.beached`), the
per-sheet `invisible` blank (`todo.art.invisibleframe`) and this rename all touch
the same four animation files. Opening them once is the whole reason to sequence
these together.

### Where a player finds a petport unit
`todo.item.acquisition` -- see also `todo.unit.species`, `plan.module.investmentpath`, `dd.port.proliferation`

**FILED 2026-09-01. TWO SCALES OF ONE QUESTION**, kept together because the
answer to either constrains the other: what structure holds a unit, and where
that structure is placed.

**THE TILED PIECES ARE THE UNIT OF WORK.** Deploy areas for petport microdungeons
and surface dungeons need designing as Tiled pieces. **POISON OCEAN PLANETS GET A
LARGER STRUCTURE** rather than a microdungeon -- decided, and the only sizing
decision made so far.

**THE TENTACLE PLANET IS AN OPEN INVESTIGATION AND MAY SIMPLY BE NO.** Whether
microdungeons can be inserted into it at all is unknown; if they can, a
tentacle-themed unit found there is worth having. **ESTABLISH THE ENGINE ANSWER
BEFORE DESIGNING THE CREATURE** -- a settled design against a planet that cannot
host it is the expensive order.

**ONE SPECIES ALREADY CARRIES AN ACQUISITION CLAIM.** The alien ant appears in
hive and shroom biomes (`todo.unit.species`). That is the first entry on this
list that came out of a creature design rather than a placement pass, and the
pattern is probably right: the biome should fall out of what the creature IS.

**THIS IS NOW THIS MOD'S PROBLEM, NOT NICEMICE'S.** The v1 framing put the
encounter loop that unit items drop from in Nicemice. Petports ships standalone,
so it has to answer this itself or the machinery arrives with nothing to find.

### A fishing module
`todo.module.fishing` -- see also `arch.module.effects`, `todo.module.designpass`

**CLOSED 2026-09-03. IT WAS BUILT ON 2026-09-01, THE SAME DAY THIS WAS FILED,
AND THIS ENTRY WAS WRONG FOR TWO DAYS.** See `arch.fishing.spawner`,
`arch.fishing.lure`, `arch.fishing.dispatch` and `fact.fishing.treasurepool`.

**KEPT RATHER THAN DELETED, BECAUSE THE ANALYSIS BELOW WAS RIGHT.** It called
fishing a TASK rather than a CAPABILITY -- needing a work generator, a claim, a
target class and a deadline instead of a status effect -- and that is exactly
what got built. The investigation reached the correct answer; only the status
line went stale, and `proc.tooling.gapcheck` records why nothing caught it.

**FILED 2026-09-01 -- AN INVESTIGATION, NOT A COMMITMENT.** Whether a fishing
module is reasonable to build is the question; nothing is decided.

**WHAT MAKES IT DIFFERENT FROM EVERY MODULE SO FAR.** The three built modules --
light, lava block, poison block -- and the two port-side ones grant a
CAPABILITY. Fishing would be a TASK, which means a work generator, a claim, a
target class and a deadline, not a status effect. It belongs to
`arch.module.effects`'s machinery only at the socket; everything downstream is
dispatch work.

**THE FIRST THING TO SETTLE IS WHAT IT FISHES.** Vanilla fishing is a minigame
driven by a rod item; there may be no headless path to a catch at all. Read that
before costing anything else -- see `fact.unit.damageteams`, which is the only
thing this document currently knows about fishing, and it is a damage-team
measurement rather than a mechanism.

### Recolouring a unit, and the part that is not technical
`todo.unit.recolour` -- see also `todo.unit.species`, `dd.unit.specialization`

**FILED 2026-09-01. THE TECHNICAL HALF IS EASY AND IS NOT THE PROBLEM.**
Directives on a monsterpart are well understood and the mod already composes
them. What is undecided is the PLAYER-FACING system: how a recolour is accessed,
and what it costs.

**THE OPEN QUESTIONS, NONE ANSWERED.**

    access   a dye item consumed at the port? a pane control? a Maxwell-style
             NPC service? something else
    cost     free, a consumable, or a currency -- and whether cost exists at all
    scope    per unit, per species, or a palette unlocked once

**A DYE SYSTEM IS THE OBVIOUS ANSWER AND SHOULD STILL BE ARGUED FOR.** Vanilla
dyes exist and players know them, which is most of a case on its own. The reason
to not just take it: dyes are consumed per application, and a player who
recolours a unit and dislikes it has paid twice for one decision.

**IT INTERACTS WITH THE ROSTER.** Five species arriving at once
(`todo.unit.species`) is the moment a palette either exists or does not, and
retrofitting one across finished sheets is the expensive order.

### A capture pod thrown at a unit should say why it did nothing
`todo.unit.capturepod` -- see also `dd.unit.nopipeline`, `fact.unit.spawnrender`, `dd.unit.itemispet`

**FILED 2026-09-01. A PLAYER'S FIRST INSTINCT WITH ANY MONSTER IS THE POD**, and
this mod's units are not pod-shaped -- `dd.unit.nopipeline` is the decision that
made them so, deliberately. The failure is therefore GUARANTEED to be met by
every player, and it currently produces silence.

**S.A.I.L. SHOULD INTERCEPT IT** and say the creature came from a petport. Same
for the relocator, which this document already knows about from a different
angle (`fact.unit.spawnrender`).

**WHAT IS UNKNOWN IS WHETHER THE ATTEMPT IS OBSERVABLE.** Both are projectiles
that act on a monster; whether a monster script can see and refuse one, or
whether the interaction has to be blocked at the monstertype, has not been
looked at. **SETTLE THAT BEFORE WRITING ANY MESSAGE TEXT** -- if the pod simply
fails silently at the engine level there may be no hook to speak from.

**AN UNCAPTURABLE MONSTER MUST NOT EAT THE POD.** Whatever the mechanism, a
player who throws a pod gets the pod back. A consumed pod plus no capture is the
one outcome worse than silence.

### Finish the petport pane
`todo.pane.statstab` -- see also `arch.pane.hoverlayer`, `arch.pane.statslist`

**UPDATED 2026-09-03 -- A FISHING BLOCK LANDED IN THIS TAB AND THIS ENTRY DID
NOT KNOW.** The Stats tab now carries one row per rarity tier, in a fixed
order, shown even at zero, with a zone free to declare its own tier and have it
appended after -- `petportconfig.lua` around line 1658, one block per activity
with farming, healing and fishing separated. The entry below was written on
2026-08-30 and listed the only remainders as dressing and a per-treat block,
which was true of the tab as it stood and stopped being true two days later.

**TRIAGED 2026-08-30 -- BOTH REMAINDERS ARE BLOCKED ON SOMETHING ELSE.** The dressing goes with the art pass; the per-treat block cannot exist until food consumption works. Note that `todo.unit.maidrank` owns icons that render here, so part of THAT entry gates this one being called complete.

- **The Stats tab is BUILT** -- a list, striped, with placeholder separators;
  see `arch.pane.statslist`. What remains here is dressing
  (`todo.art.statsdressing`) and the per-treat block once eating exists.
- **Decide whether the unit's HP bar belongs in the pane at all.** A unit that
  cannot be hurt by anything the player builds may not need one.
- **Rename is BUILT** -- the button on the Settings tab works and the name is
  pushed to a live unit by `pushPetName`. The claim that it was `not built`
  survived here for a session after it shipped.

### Error state on the petport itself
`todo.port.errorindicator`

**TRIAGED 2026-08-30 -- NEEDS RE-EVALUATION BEFORE ANY WORK.** Most of the stuck-unit cases this was meant to surface have since been fixed, so the per-port indicator light may no longer earn its cost. The surviving need may be nothing more than an appropriate warning in the pane when something is wrong with the port.

Weigh animationState components for error conditions against the cost of driving
them, and decide whether each port wants an indicator light. A player with twenty
ports should be able to see which one is unhappy without opening twenty panes --
the pane's diagnostic row already knows, it just cannot be seen from outside.

### Modules, design and liquids
`todo.module.designpass` -- see also `arch.module.effects`, `plan.module.investmentpath`

**UNBLOCKED 2026-09-01, AND HALF OF IT IS ALREADY DONE.** It was gated on the
upcycler string migration, which closed 2026-08-30 -- so this sat blocked on
nothing for a session. The second bullet below shipped as `arch.module.liquids`
and the first is all that remains.

- **A design pass on what modules a pet can have** -- THE WHOLE OF WHAT IS LEFT.
  The investment path names slots but not contents. Five modules now exist, not
  one: light, lava block and poison block as status effects, plus medic and
  hydrator on the port side. `todo.module.fishing` is the first candidate for a
  module that is a TASK rather than a capability, and the design pass should
  settle whether that class belongs at all.
- **DONE -- lava and poison immunity also unblock those liquids in the pathing
  deny list.** Built as `arch.module.liquids`: `petports_moduleLiquids` is read
  off the item by the port with no unit in the world, subtractive only, and both
  `petportsAvoidLiquids` and the `petportsLiquidVerdict` memo clear on receipt.
  Swim pathing inside corelava was the test that proved it.

### A hydrated sweep is three times longer, against an unchanged deadline
`todo.module.hydratordeadline` -- see also `arch.module.hydrator`, `arch.farming.sweep`

**FILED 2026-09-01 -- UNTESTED, AND THE ONE THING THE HYDRATOR MIGHT COST.**

`WATER_CARRY`'s own comment says the cap exists partly to bound a watering task
against `TASK_DEADLINE`: a forty-tile row becomes four sweeps rather than one task
that outlives it. `WATER_CARRY_HYDRATED` triples the longest sweep and
`TASK_DEADLINE` was deliberately NOT raised to match.

`self.taskAge` resets on dispatch only -- the unit's progress message is read for
a colour, never for a reset -- so a thirty-tile hydrated run gets the same flat
150 seconds a ten-tile one did. Between tiles the sweep clears `arrived`, the
ground target and the pather, so arrival is re-earned per tile at a fresh pather's
price. Warm, that is milliseconds; cold, it is the case `TASK_DEADLINE` was raised
from 60 to 150 for in the first place.

**NOT PRE-EMPTIVELY PADDED, BECAUSE THE FAILURE IS LEGIBLE AND SELF-HEALING.** An
abandoned run logs `deadline -- no report in 150s` against a `water:` work id, the
tiles already wetted stay wet, and the remaining cargo comes home through
`depositWork`. So it converges across retries rather than deadlocking, and the log
line names the work id -- which makes this measurable rather than guessable.

**THE FIX, IF IT IS NEEDED, IS NOT A BIGGER GLOBAL DEADLINE.** Raising
`TASK_DEADLINE` for every task to accommodate one module is the wrong shape. The
candidates in order: scale the deadline by the length of the dispatched tile list,
or let the sweep's per-tile progress push `taskAge` out the way a claim refresh
does. The second is closer to what the deadline is actually for -- it exists to
catch a unit that reports NOTHING, and a unit watering tile nineteen is not that.

### The pane pre-flight cannot see either callback-registration rule
`todo.tooling.paneflightcallbacks` -- see also `fact.pane.textboxcallback`, `arch.pane.rename`

**FILED 2026-09-01, AFTER THE RULE IT WOULD HAVE CAUGHT DROPPED THE CLIENT TO THE
MAIN MENU.**

Two opposite rules govern whether a widget's callback belongs in
`scriptWidgetCallbacks`, and BOTH failures throw at pane CONSTRUCTION rather than
at click, so the pane does not exist rather than misbehaving:

    textbox   MUST name a callback AND register it   or ContainerPane throws
    list row  MUST NOT be registered                 or addListItem throws

The tool already knows the second -- it reports `settingsRowClicked` as UNWIRED
and the config carries a note saying the report is wrong there. It knows nothing
of the first.

**HALF DONE, 2026-09-01.** `CALLBACK MISSING` now fires on a pane-level widget
whose type is in `REQUIRES_CALLBACK` and which declares no `callback`. The
existing `CALLBACK UNWIRED` check could not see this: it compares callbacks that
ARE named against `scriptWidgetCallbacks`, and a widget with no `callback` key
never enters that set.

**BOTH CONTROLS RUN.** Silent on all four working panes; reintroducing the exact
crash -- deleting `tbPetName`'s callback -- produces the finding by name.

**`REQUIRES_CALLBACK` HOLDS ONLY `textbox`, BECAUSE THAT IS ALL THAT WAS
MEASURED.** Adding a type means crashing a pane on purpose first. A guessed entry
would fail working panes and get the whole check switched off, which is worse than
not having it.

**STILL OPEN:** row widgets are skipped entirely, since the opposite registration
rule applies inside a `listTemplate` and whether a row textbox must name a
callback is untested. And nothing yet checks that a name in `scriptWidgetCallbacks`
has a matching function in the Lua -- plausible as a third failure mode, not
observed, so not asserted.

### Coverage is the dispatch radius, and a large network outruns the pathfinder
`todo.dispatch.reachbudget` -- see also `todo.dispatch.sourcebackoff`, `arch.dispatch.eligibility`, `arch.port.coverage`

**FILED 2026-09-01, WITH MEASUREMENTS, AND DELIBERATELY NOT FOUGHT THAT NIGHT.**
It is a design question with several defensible answers and no cheap one.

**A UNIT IS OFFERED ANY WORK IN NETWORK COVERAGE, AND NOTHING ASKS WHAT IT COSTS
TO GET THERE.** Eligibility asks about MEDIUM (`arch.dispatch.eligibility`) and,
for objects, about FOOTING. Neither asks about distance, and networks are
explicitly designed to grow into sprawling multi-port complexes.

**MEASURED.** A ground unit on a shipping container was dispatched to crops it
could theoretically reach -- around a pond, up two ladders, over a cliff. Every
attempt failed at 5.95 to 5.97 seconds, which is `SEARCH_LIMIT` 6.0 exactly. The
unit was not walled in and the target was not unreachable: **the search was
starved**, which is the same failure `SEARCH_LIMIT`'s own note records from
2025-08-20 -- *"a chained route took 22.25 SECONDS to solve; the same target from
atop the platforms took 0.08s. It was never unreachable, it was starved."*

**IT IS A PROPERTY OF THE PAIR, NOT OF THE TARGET.** The same crop is likely
solvable in milliseconds from the port. That is what makes it different from
ordinary unreachability and what every current mechanism gets wrong:
`workFailures` is keyed by work id, so a verdict earned at one end of the
network is applied at the other. `todo.dispatch.sourcebackoff` is the same
observation about crates; this is the third instance of one shape.

**THE STOPGAP SHIPPED THAT NIGHT IS `UNROUTABLE_BACKOFF_FLOOR`**, which stops
the stutter -- six seconds of search buying one second of backoff, with two
targets alternating, left a unit advancing 0.7 tiles per twelve seconds. It does
NOT address this entry, and it carries this entry's flaw: a crop unreachable from
the far end of the network stays suppressed for thirty seconds after the unit
walks home, where it would have been trivially reachable.

**CANDIDATE DIRECTIONS, NONE CHOSEN AND NONE COSTED:**

- A DISTANCE OR COST BUDGET AT DISPATCH -- cheap to write, and the hard part is
  that straight-line distance is a poor proxy for path cost, which is the whole
  problem restated.
- DISPATCH RADIUS SEPARATE FROM COVERAGE -- coverage decides what a network
  OWNS; a second, smaller number decides what one unit is offered. Player-facing
  and explainable, and it makes a big base want more pets, which is the answer
  this mod gives everywhere else.
- RAISING `SEARCH_LIMIT` OR `EXPLORE_RATE` -- treats the symptom, moves the wall
  rather than removing it, and costs CPU on every failing search.
- CACHING THE VERDICT PER REGION rather than per work id, so "cannot get there
  from this end" is remembered as a fact about geography and cleared when the
  unit moves. This is the one that would also close
  `todo.dispatch.sourcebackoff`.
- **SEGMENTED PATHFINDING OVER A SPATIAL INDEX -- quadtree or similar.** THE
  AUTHOR'S PROPOSAL, 2026-09-01, and the only candidate here that attacks the
  cause rather than the symptom. Solve coarse region-to-region connectivity once,
  and let A* do fine pathing only within a segment. It answers "can this unit get
  there at all" without a six-second search, which is the question every other
  entry on this list is trying to approximate. It is also by far the largest, and
  it wants its own session and its own design pass rather than being grown out of
  a bug fix.

**THE BACKOFF FLOOR IS BETTER THAN "A STOPGAP" AND IT IS WORTH SAYING WHY.**
Observed by the author the same night: pushing a failed target out of the way for
thirty seconds does not merely stop the thrash, it lets the unit ATTEMPT OTHER
CROPS -- and a different target may be solvable from where the unit is standing.
So the backoff turns a stall into a cheap search ACROSS targets, using work the
unit was going to do anyway. That is a real mitigation and not just noise
suppression, and any replacement for it should keep the property.

**WHOEVER PICKS THIS UP SHOULD READ `EXPLORE_RATE`'S NOTE FIRST.** It records
that the same search starved at vanilla's rate and solved at 300, so the
boundary between "far" and "unreachable" in this mod is a tuning constant rather
than a fact about the world.

### Maxwell
`todo.unit.maidrank`

**TRIAGED 2026-08-30 -- A MINI-PROJECT IN ITS OWN RIGHT, AND PARTLY BLOCKING.** It needs a maid dress reward item, an Outpost shop area, universe flag patches to spawn it, and the surrounding overhead. BUT IT ALSO OWNS ICONS THAT RENDER ON THE PETPORT UI, so working prototypes of those are required BEFORE the petport pane can be called feature complete -- which makes a piece of this a dependency of `todo.pane.statstab` rather than a pure nice-to-have.

A themed maid NPC who inspects a player's pets and awards maid ranks. He is called
Maxwell. Presenting a pet with a high Tidy Score earns a maid dress cosmetic.

Filed rather than dropped because it is the only thing so far that gives the Tidy
Score a consumer -- it is currently computed, displayed, and read by nothing.

### The upcycler must show it cannot burn
`todo.upcycler.cantburnlight` -- see also `arch.upcycler.burnbox`, `dd.upcycler.bakedindicators`

**TRIAGED 2026-08-30 -- SPECIFIED, AND IT IS AN ART TASK.** Not a status light beside the machine: an INDICATOR OUTLINE AROUND EACH OF THE THREE SLOTS, coloured by whether that slot works for whatever item is currently in it. Belongs to the upcycler's art pass alongside `todo.art.statsdressing`.

A status light in the art and animationStates for the state "the burn slot is
occupied but nothing can burn" -- whether because no rule names the item or
because the rule's burn box denies it. WHILE ENABLED, OCCUPIED, AND UNABLE TO
BURN, IT SHOULD BE BEEPING. The machine already knows the state -- the furnace
door logs it -- it just cannot be seen or heard from outside, and a machine
quietly not-burning is indistinguishable from a machine quietly done.

### A recall with nowhere to stand says nothing to the player
`todo.port.nostandpoint` -- see also `todo.pathing.standpointchoice`, `todo.unit.complaints`, `arch.port.reporthandler`

**CLOSED 2026-09-03 -- THE MECHANISM BELOW IS OUT OF DATE AND THE BRANCH IS
BELIEVED UNREACHABLE.** `returnWork` no longer calls `findStandingPoint` twice;
that pair moved into `homePosition` and now sits behind `homePointNear`.
`returnWork` calls `homePosition()` once, and the comment above the surviving
`rehomeUnit` call says the branch is unreachable for a port-tethered chassis,
which always has an answer.

**THE PLAYER-FACING COMPLAINT WAS NEVER WRONG**, and is preserved below: a
teleport is the loudest thing the port does and it happens silently. If a
silent rehome is ever seen in the wild, this entry is the design for the fix
and `todo.port.errorindicator` is where the pane-side work lives.

`returnWork` calls `findStandingPoint` twice -- an 8x8 box on the port, then the
full coverage rect -- and when BOTH return nil it calls `rehomeUnit("no standing
point in rect to recall to")`. That is a log line and a teleport. The pane says
nothing.

**A TELEPORT IS THE LOUDEST THING THE PORT DOES AND IT IS CURRENTLY SILENT.** A
player watching a unit blink home has no way to learn that its port is somewhere
a unit cannot stand, which is a placement problem they could fix in ten seconds
if anyone told them. The machinery exists -- `paneDiagnostics` and `paneDiag`,
with an `info` / `warn` / `error` tint -- so this is a condition to track and one
insert, not new plumbing.

**IT MUST BE A LIVE CONDITION, NOT A TALLY**, per the note above
`paneDiagnostics`: it has to clear when a standing point becomes findable again,
or filling in a floor leaves the warning up forever.

### `findStandingPoint` returns the highest point in a random column
`todo.pathing.standpointchoice` -- see also `todo.port.nostandpoint`, `fact.pathing.floatingtarget`, `arch.port.coverage`

**CLOSED 2026-09-03 -- THE FUNCTION HAS BEEN DEMOTED OUT OF THE WAY.**
`homePointNear` asks the unit first, and the comment above the fallback now
says outright that `findStandingPoint` "is no longer on the path any live unit
takes home". Its two surviving callers are `diagnosticWork` and a last-ditch
branch in `homePosition` that only runs for a port with nothing socketed. The
defects below are all still real; none is reachable by a unit doing its job.

**THE CODE NAMES A THIRD DEFECT THIS ENTRY NEVER DID.** The fallback comment in
`petports_petport.lua` lists random column, descends from the top, AND cannot
see platforms. Only the first two were ever written down here. Recorded on
closing so the count does not shrink again if anyone reopens it.

    for y = rect[4], rect[2], -1
      if world.pointTileCollision(below) and not world.pointTileCollision(here)

Two properties, both fine in the case it was written for and neither obviously
right in general:

  - **it descends from the TOP**, so it returns the highest ledge in the column
    rather than the floor nearest the port
  - **the column x is `math.random()` across the whole rect**, which for the
    64-wide coverage fallback is anywhere within 32 tiles

So for a port in a deep pool sunk into terrain, the coverage fallback resolves to
the dry surface off to one side rather than the seabed underneath. That is a
VALID standing point -- it is simply the wrong one.

**IT IS SAFE IN THE DIRECTION THAT MATTERS, WHICH IS WHY THIS IS NOT URGENT.**
The test requires `pointTileCollision(below)`, which liquid never satisfies, so
this can never return a free-floating point in open water -- `fact.pathing.liquidstandable`
does not reach here, because this is the PORT's own resolver and not
`validStandingPosition`. It is stricter than the pathfinder, so it can only fail
to find a point the pathfinder would have accepted, never invent one it would
reject.

**DEPTH IS NOT THE TRIGGER, AND THE OBVIOUS FIX IS ALREADY IN PLACE.** "Search
network coverage" was the first proposed answer; the coverage rect IS the
existing fallback and reaches 32 tiles vertically, so a pool 20 or 30 deep is
already within reach. The defect is which point gets chosen, not how far it
looks.

**WHY NOTHING HAS BEEN SEEN IN GAME:** `returnWork` returns nil for a unit that
is `inside` coverage and not `stranded`, so an amphibious unit floating in its
own pool is never recalled and never asks for a standing point at all. Verified
2026-08-30 with a port under twelve tiles of water. The resolver only runs on the
leash and the diagnostic filler.

### A unit that cannot find somewhere to stand should say so itself
`todo.unit.complaints` -- see also `plan.pane.carriedindicator`, `todo.port.nostandpoint`

**TRIAGED 2026-08-30 -- BACKLOG, NO PRIORITY SET. BLOCKED ON THE BUBBLE.**

`plan.pane.carriedindicator` describes a bubble above a unit showing a carried
ITEM icon, generalising to a TASK icon. This is a third consumer: a COMPLAINT.
"I have nowhere to stand" is the first one worth saying, because it is a
condition the unit discovers and the port only infers.

**THE PORT DIAGNOSTIC AND THE BUBBLE ARE NOT THE SAME FEATURE**, and building one
does not close the other. The pane tells a player who has already opened the
port; the bubble tells a player walking past a unit doing nothing. The second is
how you find out WHICH of a dozen units is the unhappy one.

**INHERITS THE OPT-IN RULE** from `plan.pane.carriedindicator` -- a base running a
dozen units with permanent bubbles overhead is the vanilla ship-pet clutter this
mod exists to avoid. A complaint may deserve different defaults from a carried
item, since a complaint is rare and actionable where a carried icon is constant;
undecided.

### The unit's invisibility is borrowed from the spinner sheet
`todo.art.invisibleframe` -- see also `todo.art.panes`, `todo.unit.species`

**TRIAGED 2026-08-30 -- GOES WITH THE NEXT ART PASS.** No work until each chassis sheet gains its own blank frame. Until then the constraint below is the whole point of the entry: `spinner.png:blank` cannot be removed or renamed.

**A LANDMINE, AND IT IS LOAD-BEARING IN THREE PLACES.** All four chassis
animations declare an `invisible` movement state, and its image now points at

    /monsters/lofty_petports/shared/spinner/spinner.png:blank

-- the deliberately empty frame on the THINKING SPINNER'S sheet. A body layer
resolving its image out of an unrelated part's spritesheet works and is wrong.

**WHAT DEPENDS ON IT.** `petportsSleepAction` sets `invisible` when a unit
sleeps inside a target; vent travel sets it for the hop (see the note in
`petports_think.lua` about a spinner orphaned over an invisible unit); and
`petports_contract`'s init wrapper sets it for one tick so a materialising unit
cannot be seen at full size before the fade effect starts -- see
`fact.unit.spawnrender`.

**IT WAS A NO-OP UNTIL 2026-08-30.** The state was declared in all four
animations and aliased to `<partImage>:run.<frame>`, so every one of those three
call sites was showing a fully visible unit while believing otherwise. Nothing
errored, nothing logged, and two of the three had been wrong since they were
written. A DECLARED STATE ALIASED TO ANOTHER STATE'S IMAGE IS INDISTINGUISHABLE
FROM A WORKING ONE until something depends on the difference.

**THE FIX AT THE NEXT ART PASS:** a blank frame on each chassis sheet, and the
`invisible` state pointed at its OWN sheet. Then the spinner can be redesigned,
renamed or deleted -- which `todo.art.panes` and the speech-bubble rework both
make likely -- without silently un-hiding sleeping units, units in transit, and
every spawn.

**UNTIL THEN, `spinner.png:blank` MAY NOT BE REMOVED OR RENAMED.** Its own
.frames file marks it "deliberately empty", which reads as decorative and is
not.

### Distinct glyphs and real separator art
`todo.art.statsdressing`

**TRIAGED 2026-08-30 -- THE CHECKBOXES ARE PROBABLY FINE.** Once the pane draws the lines showing what each column does, two identical checkboxes stop being ambiguous -- the line is the disambiguator, not the art. That leaves the separators and stripe fills, both cosmetic.

Three placeholders from the metrics session, all flagged in code comments: the
burn and reagent checkboxes on an upcycler rule row are IDENTICAL vanilla
checkbox art with different meanings -- the exact misreading the beacon verb
art exists to prevent; the stats list separators are dull-orange dashed rules;
and the stripe fills `row_180_11.png` / `_alt.png` are generated uniform
fills, not designed art.

### The stall watchdog cannot tell "no progress" from "arrived, target moved"
`todo.pathing.arrivedstall` -- see also `todo.unit.progressdirection`

**DEFERRED 2026-09-03 -- NOT WORTH ACTING ON AT PRESENT.** The wasted dispatch
it costs has not become a problem, and `todo.pathing.movingtarget` is itself
deferred, so the prerequisite has nothing waiting behind it.

**THIS IS ONE HALF OF A PROBLEM AND `todo.unit.progressdirection` IS THE OTHER.**
Filed three days apart, both about the same watchdog, and until 2026-09-03
neither referenced the other: this one says it cannot tell arrival from a
stall, and that one says it counts motion rather than progress, which is how a
unit sank 54 tiles and read as healthy. Anyone rebuilding the watchdog should
read both, because fixing either alone leaves the measure wrong.

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
`todo.pathing.movingtarget` -- see also `todo.pathing.arrivedstall`, `todo.farming.animalsmove`

**DEFERRED 2026-09-03 -- SHIPS AS IT IS, AND FINE-TUNED LATER IF IT IS EVER
HIT.** The impact fell out on its own: terrestrial targets move far slower than
the fish that made this urgent, so a stale `groundTarget` on a ground chassis
costs very little. The fast case that motivated the entry belongs to the
chassis that chase fish, and those already have string-pull. If a terrestrial
case ever does bite, the paragraph below is still the design and the layering
requirement in it still stands.

**THE COW FIX IS THE PLAYER FIX, AND THAT IS THE POINT OF THIS PARAGRAPH.** The
medic task targets a WOUNDED ALLY -- a player, a tenant, a crew member -- and
those are cows that move faster. Nothing about the re-resolve is
animal-specific; the cached `stateData.groundTarget` goes stale for exactly the
same reason and is corrected by exactly the same mechanism. So when this is
built for animals it must be built at the TARGET-TRACKING layer and not inside
the animal work generator, or the medic path will need it written a second time.

**THE MEDIC PATIENT IS THE WORST CASE OF IT AND SHIPS ANYWAY.** A wounded player
is specifically someone who is probably running, so the accepted cost -- one
failed dispatch per wander -- lands harder there than anywhere else. That was
accepted deliberately 2026-08-30 rather than blocking medic behind this entry:
partial delivery beats no delivery, and a failed dispatch is already a
self-correcting state. Do not read a high medic failure rate as a medic bug.

**THE SPLASH SOFTENS IT MORE THAN IT LOOKS.** Delivery is an area projectile
(see `ragestatusprojectile` as the pattern), not a touch, so the unit does not
have to reach the patient's exact tile -- only close enough for the damagePoly to
cover it. That widens the arrival tolerance for this task specifically and is a
reason the failure rate may be tolerable here even before this entry is done.

**TRIAGED 2026-08-30 -- WANTED, ESTIMATED 6 / 10.** The re-resolve itself is a 3; the cost is that a rebuild mid-flight discards the launch record and nothing steers the descent (`fact.pathing.arcmoverthrottle`), so THE RE-RESOLVE MUST NOT FIRE WHILE AIRBORNE and that gate has to be deliberate rather than emergent. The rest is the interaction with `arch.pathing.standablerank` caching and the probe results pushed to the port.

ACCEPTED AS IMPERFECT, DELIBERATELY: there is no clean solution, "do not replan in the air" is good enough, and replanning periodically at all still beats vanilla's monsters standing against walls doing nothing. `todo.farming.animalsmove` folds into this.

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

**TRIAGED 2026-08-30 -- DEFERRED UNTIL THE OBJECT ART EXISTS.** The pane already has a blinking light that wants fine-tuning; the rest arrives with the object and pane art passes, and the pane's lights should match the object's aesthetically rather than being designed against a placeholder.

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

**TRIAGED 2026-08-30 -- DEFERRED TO RELEASE PREFLIGHT.** Debug gating is being handled as ONE pass over every flag before shipping rather than trimmed stream by stream, so this waits with the rest. See the debug flag list in `status.port.inventory`.

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

**TRIAGED 2026-08-30 -- CLOSED, THE PREMISE IS FALSE.** Food does not rot inside the upcycler: its decay rate is 0, so the same-name stack the engine cannot merge never appears. No churn to gate.

A same-name stack the engine cannot merge (rot) makes the bulk rescue cycle a
take-and-return every few ticks until the charge drains the reagent slot.
Invisible in practice; if it ever shows in a log or profiler, gate re-attempts
on the reagent slot's count changing. Three lines, filed rather than done
because unmeasured cost does not buy code.

### An unreachable source is backed off per work item, not per source
`todo.dispatch.sourcebackoff` -- see also `arch.dispatch.twolegs`, `arch.dispatch.eligibility`

**MEASURED 2026-08-31 -- BACKLOG, LOW PRIORITY. It self-limits as runs get
served, so it costs trips and not correctness.**

Nine `fetchwater` failures in one session, every one `no net progress`, every one
heading for `[2553,1147]` -- one crate -- across five distinct work ids:

    fetchwater:2500,1183   fetchwater:2524,1183   fetchwater:2500,1162
    fetchwater:2500,1157   fetchwater:2500,1152

`self.workFailures` is keyed by work id, but "this crate cannot be reached" is a
property of the CRATE. Each dry run therefore gets its own ladder against the
same unreachable source, and with a dozen runs outstanding the ladder never
bites. Same shape as `arch.dispatch.twolegs` one level up: the thing that failed
and the thing being backed off are not the same object.

**ELIGIBILITY CANNOT CLOSE THIS.** `servicePointNear` passed the crate -- medium
fine, standing point fine. What failed was the route, which
`arch.dispatch.union` deliberately does not pay for per candidate. The lever is
the backoff key, not the filter.

**THE ATTRIBUTION ABOVE WAS WRONG AND IS CORRECTED HERE.** This entry first
blamed the amphibious ledge fault. It was not that: ALL NINE failures belong to
the FLYER's port and none to the amphibious one, and the cause was
`arch.dispatch.vouch`'s second half -- the unit was approaching the container's
raw submerged origin because `withdraw` did not resolve an approach point. The
nine failures are therefore already fixed, and this entry now has NO measurement
behind it. **IT IS KEPT AS A REASONED CONCERN, NOT AN OBSERVED FAULT**, and
should be closed if the next log does not reproduce it.

**THE LESSON IS THE ATTRIBUTION, NOT THE ENTRY.** Two faults were live in the
same log -- a ledge fault the author had seen with his own eyes, and this one --
and the seen one absorbed the blame for failures it had nothing to do with. The
per-port split was one `grep -o | awk | sort | uniq -c` away and was not run
until the next session asked a different question.

### The leash re-searches the whole way home on every resumption
`todo.pathing.leashreplan` -- see also `arch.dispatch.eligibility`, `arch.pathing.originnudge`

**OBSERVED 2026-08-31 -- BACKLOG, NO PRIORITY SET. Recorded separately from
todo.dispatch.eligibility (retired, built as `arch.dispatch.eligibility`) because
fixing that one HIDES this one rather than fixing it.**

**STILL OPEN AFTER ELIGIBILITY SHIPPED, AS PREDICTED.** The interruptions are
gone, so the symptom is gone and the cost is not. Nothing here has been
measured since.

Every entry into the task state calls `freshPather`, which builds a new
`PathMover` and starts a cold A* search. That is correct and deliberate --
`PathFinder:reset()` does not clear `aStar`, so a pather cannot be reused across
tasks. The consequence is that an INTERRUPTED leash pays a full cold search for
the remaining distance every time it resumes: six searches for one journey home
in the measured session, at 57, 48, 36, 25, 14 and 3 edges.

**REMOVING THE INTERRUPTIONS REMOVES THE SYMPTOM AND NOT THE COST.** Any
legitimate interruption -- a real dispatch mid-return, a recall, a vent leg --
still pays it. Whether that matters is unmeasured: a 57-edge search completed
inside one tick here, so the cost may be entirely acceptable and this entry may
close as "measured, fine".

**WHAT WOULD MAKE IT URGENT.** A leash across a long or heavily obstructed route,
where the search does not complete in a tick and the unit stands still through
it. `maxFScore` is 1200 and an unreachable search can run to `maxNodesToSearch`
70000, so the ceiling here is seconds, not milliseconds.

### Hand an abandoned board straight to string-pull
`todo.locomotion.stringpullhandoff` -- see also `arch.locomotion.dive`, `arch.locomotion.swimmode`

**FILED 2026-09-02.** When a unit abandons its diving board it has just proven a
body-width clear run to the fish -- that IS the abandon condition. It then drops
the cached target and lets the pather replan from scratch, which is visible as a
short stall.

**THE PROOF IS ALREADY IN HAND AT THAT MOMENT**, so the replan is redundant work
answering a question `swimReachable` just answered. Handing directly to the
string-pull mover would skip it.

**NOT DONE BECAUSE IT IS AN OPTIMISATION AND WAS COMPETING WITH A BUG.** The
stall had two causes stacked -- a stale approach target, then an abandoned plan
re-supplying the board -- and adding a shortcut while either was live would have
made neither attributable. Worth doing now that the abandon produces a
fish-targeted plan cleanly.

### A drop-through rises about a tile when it should rise nothing
`todo.locomotion.dropthroughrise` -- see also `fact.unit.platformdrop`, `arch.locomotion.dive`

**FILED 2026-09-02.** A no-hop drop-through writes `vy0 = 0` and should not rise
at all. Measured rises of 0.20, 0.99 and 1.06 tiles on genuine drop-throughs
where the platform did release: `controlJump` imparts real upward velocity before
the release truncates it.

**COSMETIC, AND NOW RARE.** The aligned-pair bias in `arch.locomotion.dive`
prefers boards that hop, so drop-throughs are chosen only where a low ceiling
refuses the hop. It reads as a small unwanted bounce.

**THE LIKELY FIX IS THE ONE petportsTaskAction ALREADY USES**, placing the body
through with `setPosition` -- see `scootThroughPlatform`. It was not used here
because a dive wants to leave the board with some authority anyway, and that
reasoning is weaker for the no-hop case, which by definition does not.

### The lure left coverage on patrol, not on teleport
`todo.dispatch.lureescape` -- see also `todo.module.fishing`, `arch.dispatch.union`

**FILED AND FIXED 2026-09-03. KEPT BECAUSE THE OBVIOUS DIAGNOSIS WAS WRONG.**
Reported as the lure escaping when it chose a teleport point, and the fix was
assumed to be clamping the teleport pick. `lureSpotValid` was already testing
`insideCoverage` on every candidate; the teleport had never been the problem.

**IT WAS THE PATROL, AND THE ASYMMETRY IS THE WHOLE BUG.** Coverage was tested
inside the TIMED terrain lookahead -- every `petports_patrolCheck` seconds,
against a point two tiles ahead -- while `setPosition` ran EVERY TICK. Between
checks the lure moved `patrolSpeed * patrolCheck` unverified, so a teleport
landing just inside an edge could cross it before the next check fired.
Simulated against the measured tuning: 0.325 tiles outside from a start 0.3
inside an edge, and exactly zero from mid-rect -- which is why it read as
"occasionally" and why the logs that were looked at showed nothing.

**BRIEF EXCURSIONS ARE NOT HARMLESS HERE.** `getSpawn` picks a neighbourhood
around the lure, so a lure a fraction outside spawns a fish the port cannot
dispatch to, and a fish holds a 150-second tracking slot -- the consequence
outlives the excursion by two orders of magnitude.

**THE FIX SPLITS THE TWO TESTS BY COST.** The terrain queries stay on their
timer; `insideCoverage` is arithmetic over a handful of rects with no world call
in it and now runs every tick, against the position actually being written
rather than a point two tiles ahead. A teleport also zeroes the patrol timer,
because a jump invalidates a lookahead measured around the old position.

**AND THE LURE HAD NO BUILD STAMP**, so a stale copy was indistinguishable from a
current one in a log. Added to the line every lure prints on spawn.

### The progress watchdog counts motion, not progress
`todo.unit.progressdirection` -- see also `arch.locomotion.swimmode`, `arch.dispatch.leash`, `todo.pathing.arrivedstall`

**FILED 2026-09-03, AND IT IS A GAP IN A GENERAL SAFETY NET RATHER THAN A
SWIMMING BUG.** A unit that missed its exit jump fell back into deep water and
sank 54 tiles over 17 seconds at a steady 3 tiles a second. The watchdog never
fired, because it measures distance MOVED over a window -- 15 tiles per
five-second window against the 2.5 it needs -- and a unit falling is moving. The
one safeguard that could have caught it read the plunge as healthy progress.

**THE SINK ITSELF IS FIXED** by the wade test in `arch.locomotion.swimmode`, so
this is not currently reachable by that route. It is filed because the watchdog
will miss ANY future failure that involves motion in the wrong direction, and
that class is not small: anything falling, drifting, or circling satisfies it.

**THE OBVIOUS FIX IS TO MEASURE CLOSING DISTANCE TO THE TARGET** rather than
path length travelled, which is a different quantity and is already available at
every call site that has a target. The reason to be careful is that legitimate
routes go AWAY from a target -- around terrain, through a vent -- so a naive
closing-distance test would fail the units it is meant to protect. That is
presumably why it counts motion, and it is why this is filed rather than
changed.

### The petvent's sound pool is empty and always has been
`todo.vent.silentsound` -- see also `fact.pane.panesound`

**FOUND 2026-09-03 while copying the vent's pattern for the port.**
`petports_petvent.animation` reads:

        "sounds" : { "vent" : [ ] }

An empty pool. `animator.playSound("vent")` fires at BOTH ends of every teleport
-- departure and arrival, which is deliberate and commented -- and plays nothing.
The call shape is proven; a sound coming out of it never was.

Cheap: one path in one file. It has been silent since vents shipped, so nothing
depends on the silence.

### The port's sound handler is now a fallback nothing uses
`todo.pane.portsound` -- see also `fact.pane.panesound`

**FILED 2026-09-03, AND IT IS A DELETION.** The pane played its sounds through
the port while `widget.playSound` was unproven. It is proven -- a full test
session logged zero fallbacks -- so `petports_paneSound`, its `PANE_SOUNDS` table
on the port, and the `sounds` block in `petports_petport.animation` are all dead
weight, along with the fallback branch in the pane's `paneSound`.

Left in for one build deliberately: that build also landed the colour wire and
the light effect, and a sound that silently vanished would have been one more
thing to rule out while reading a log about a light.

### Mixed line endings in petports_petport.lua
`todo.tooling.crlfdrift` -- see also `proc.tooling.halfedit`

**FOUND 2026-09-03.** The file is CRLF and carries THREE bare-LF lines, 9815 to
9817, inside the medic patient generator -- the `if #patients == 0 then` block.
That is a `str_replace` writing LF into a CRLF file, which this document already
warns about, having already landed once unnoticed.

Harmless to Lua and invisible in game. It matters because it is the residue of a
class of edit that CAN do damage, and because a second one is easier to miss
beside a first. Every edit to that file since has asserted the count stayed at
three rather than quietly adding to it.

### A unit can be dispatched into magma at a fish it is not equipped for
`todo.fishing.medium` -- see also `arch.fishing.network`, `arch.dispatch.eligibility`, `arch.fishing.lure`

**FOUND 2026-09-03 while building `arch.fishing.network`, AND IT PREDATES IT.**
Not caused by network-wide fish; made likelier by them, because a network now
spans more bodies of water than one port's rect did.

`petportCanFish` asks a CHASSIS question -- may this body be submerged -- and
nothing asks the TILE question. `fishingSpot`'s tier one accepts any biome with a
pool in vanilla's config, and that list includes **magma**. A magma world
therefore places a lure in lava, spawns fish in it, and dispatches a plain
aquatic unit at one with no liquid-specific test anywhere in the path.

**THE FIX IS ONE CALL AND IT IS THE MEDIUM HALF ONLY.** `targetSuits(position,
nil)` is the medium ladder without the standing search, and it already takes a
nil entity id -- the soil path passes one. **DO NOT REACH FOR `targetEligible`
HERE.** It is the pair, and the standing half is wrong for a moving target:
`GROUND_SEARCH_DOWN` is -6, the seabed under an open-water fish is deeper than
that, so `standableNear` returns nil and a walker dispatched at a fish deadlocks
on arrival. `animalWork` already takes the reach test alone for the same reason.

**NOT DONE IN THE SESSION THAT FOUND IT**, deliberately: it is an unrelated fix
and stacking it would have cost the one clean log the fishing change gets. See
`proc.tooling.onechange`.

### A cross-port fish has no target marker, and now it needs one
`todo.fishing.marker` -- see also `arch.fishing.network`, `arch.dispatch.claims`, `dd.pane.bandsplit`

**FILED 2026-09-03. THE CODE POINTED AT A BACKLOG ENTRY THAT DID NOT EXIST.**
`fishWork`'s header said a claim and a marker both become necessary "the day a
fish is visible to a port that did not spawn it -- see the backlog entry for
both". There was no such entry. The claim half is built; this is the other half,
filed properly this time.

**IT MATTERS MORE THAN IT DID.** A unit swimming out of its own rect at a fish
another port's lure spawned is INDISTINGUISHABLE ON SCREEN from the leash
failing. That is the exact reading that costs a session -- the observer measures
the wrong thing, because the correct behaviour and the known bug look the same.
The dispatch log names the owning port for this reason, but a log is not what a
player is looking at.

**A FISH IS NOT A DROP AND THE EXISTING MARKER MAY NOT SUIT.** Drops sit still;
a fish moves at swimSpeed 3 and darts at 30, so a marker pinned at dispatch
position is wrong within a second. Whether it should track, blink at a fixed
point, or not exist has not been decided -- settle that before writing any of it.

**AND THE CROSSHAIR SYSTEM ITSELF HAS NO ARCHITECTURE ENTRY.** Found while
filing this: `crosshairRefresh`, `crosshairClaimId`, `CROSSHAIR_CLAIM_TTL`, a
projectile and a player-facing toggle, and the document mentions markers only in
passing inside `dd.pane.bandsplit`. That is the SAME SHAPE as the fishing gap
`proc.tooling.gapcheck` was written for -- a built subsystem with no entry -- and
it is the second one found by walking references rather than by any check.

### The port never asked whether a fish was still in coverage
`todo.fishing.outofcover` -- see also `arch.fishing.network`, `arch.fishing.dispatch`, `arch.dispatch.union`

**FILED AND FIXED 2026-09-03, AND KEPT BECAUSE THE OBVIOUS DIAGNOSIS WAS WRONG
AGAIN.** Read at first as a regression from network-wide fish. It is not: both
halves of the asymmetry shipped together in `fishing ix part 2`, and the
committed `fishWork` has no rect test of any kind.

**THE ASYMMETRY.** `petportsTaskAction.update` bails a fish task the moment
`petports_inNetwork(fishAt)` is false, checked EVERY TICK because a fish covers
ground fast. The port checked it NEVER: `RECT_CHECKED_TYPES` holds only `diag`,
so `dispatchable()` waves fish through, and the generator returned a position
without looking at it. So the port could hand out a task the unit was guaranteed
to refuse on its first tick.

**MEASURED: 6 OF 24 DISPATCHES, EVERY ONE FAILING AT `moved 0` INSIDE 200ms.**
Replayed against the four published rects, the fix refuses exactly those six and
none of the eighteen that produced the log's fourteen catches. Two of the refused
fish were caught anyway on a LATER dispatch once they drifted back in, so
refusing costs nothing -- the fish returns and the backoff has expired.

**WHAT MADE IT VISIBLE WAS VOLUME, NOT CROSS-PORT DISPATCH.** The first fish
dispatch in the log that found it is the pre-change path exactly: a port at its
OWN lure's fish, one offered, outside coverage.

**THE PREDICATE WALKS `fishingRects()`, NOT `coverageRect()`.** Union dispatch
means a unit may work anywhere in the network, so testing our own rect would
refuse a fish sitting perfectly reachable in a member's water. Same list the lure
is clamped to and the same list the unit was handed, so all three now agree by
construction. Nested inside `fishWork` rather than made a chunk-level local --
that file is at 159 of Lua 5.1's 200 and the failure when it lands is at load.

### A fish that beat one port gets a fresh retry budget from every other
`todo.fishing.backoffshared` -- see also `arch.fishing.network`, `arch.dispatch.claims`, `todo.dispatch.sourcebackoff`

**FILED 2026-09-03. OUT OF SCOPE FOR 1.0, DECIDED RATHER THAN DEFERRED.**

`self.workFailures` is PORT-LOCAL, which was correct while the work was. It no
longer is. Measured on one fish:

    19:59:45.570  b94de  backing off fish:1343 for 1 seconds (failure 1)
    19:59:47.823  b94de  backing off fish:1343 for 2 seconds (failure 2)
    19:59:53.636  4f9b   backing off fish:1343 for 1 seconds (failure 1)

The escalation works perfectly and then resets, because the second port has never
heard of this fish. With four ports that is four ladders on one doomed target.

**IT IS BOUNDED, WHICH IS WHY IT CAN WAIT.** A fish dies inside 150 seconds
whatever anyone does, so the waste is capped and self-clearing -- unlike a drop,
which waits forever and is the case `todo.dispatch.sourcebackoff` covers.

**THE FIX IS NOT SMALL.** Failures would have to move into shared state beside
claims, which means an expiry policy, a sweep, and a decision about whether a
failure recorded by one port should bind a port whose unit is somewhere else
entirely -- the same reachability argument that killed the distance veto in
`arch.fishing.network`. Not a 1.0 change.

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

### A LOG SAMPLED AT 12 Hz WILL CONFIRM ANY THEORY YOU BRING IT
`proc.tooling.instrument` -- see also `proc.tooling.controlfirst`, `arch.tooling.flighttrace`, `dead.pathing.plannersteer`, `dead.pathing.waterdrag`, `proc.pathing.velocityartifact`

**COST: MOST OF 2026-09-01, AND TWO CONFIDENT WRONG ANSWERS SHIPPED AS FIXES.**

The `pre-move` line runs once per script tick -- 0.082s, 4.92 engine ticks. A
collapse from full speed to zero takes TWO of those. Every theory about it is
therefore fitted to ONE interior sample, and one sample cannot distinguish
mechanisms that produce the same curve.

**IT DOES NOT FAIL BY LOOKING UNCERTAIN. IT FAILS BY AGREEING WITH YOU.**

    theory 1  the planner's vx steers the mover   deceleration profile matched a
              velocity command, and A* really does store zeroes there
    theory 2  liquid drag at the waterline        three falls sorted perfectly by
              whether they ended in water, and the waterline was independently
              confirmed

Both were coherent, both cited real measurements, both were wrong, and the actual
cause -- `arch.pathing.brakelatch` -- was a stuck flag from a PREVIOUS flight,
which no reading of a single flight could have found.

**THE AUTHOR SEEING IT AT 60 fps BEAT EVERY RECONSTRUCTION.** "The unit stops
following its arc before it hits the waterline" was correct, was not derivable
from the log as it stood, and was the observation that forced the instrument.
When someone watching the game and the log disagree about ordering, THE LOG IS
THE ONE MISSING SAMPLES.

**THE RULE.** WHEN TWO EXPLANATIONS FIT THE SAME EVIDENCE, STOP REASONING AND
INSTRUMENT. A per-tick trace behind a flag cost about an hour and separated three
hypotheses in ONE RUN, after two rounds of inference had spent a session getting
it wrong twice. `proc.tooling.controlfirst` says reach for a control before a
theory; this is the same rule when the control cannot be built without better
resolution first.

**AND A CORRECT CHANGE ARGUED FROM A WRONG DIAGNOSIS IS STILL A WRONG
DIAGNOSIS.** Deleting the planner-vx steering was right on its own merits and was
presented as the fix for the ledge. It fixed nothing there, and shipping it as
though it had made the next round of evidence harder to read -- the next log was
scanned for whether the fix worked rather than for what was actually happening.
Say what a change is expected to do BEFORE the run, and say plainly when it did
not do it.

### Reach for a CONTROL before a theory
`proc.tooling.controlfirst` -- see also `fact.pathing.floatingtarget`, `proc.tooling.instrument`

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
`proc.pathing.readsource` -- see also `fact.pathing.collisionkinds`

THIS SESSION PRODUCED FIVE WRONG THEORIES ABOUT ENGINE BEHAVIOUR, AND
`StarPlatformerAStar.cpp` ANSWERED EVERY ONE OF THEM OUTRIGHT.

    "the search exhausts"                      -> neighbors() dispatches to
                                                  getFallingNeighbors, so it
                                                  plans an Arc. It succeeds.
    "crates are Dynamic" / "crates are Platform"
                                               -> two probes in the log settled
                                                  it and neither guess was needed.
                                                  ASSERTED AGAIN 2026-08-31, in a
                                                  code comment, which is why it
                                                  now has its own entry:
                                                  fact.pathing.collisionkinds
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

### A GUARDED CALL PROVES THE CALL RAN, NEVER THAT IT DID ANYTHING
`proc.tooling.guardedcall` -- see also `proc.tooling.assertshape`, `fact.pane.titleicon`

`widget.setImage("title.icon", path)` was wrapped in a pcall, and the module
logged `applied` on `ok`. It printed four times per pane. THE ICON NEVER CHANGED.
Starbound's widget bindings commonly no-op on a name that does not resolve, so
`ok` meant only "did not raise" -- and the log asserted something it had no way
to know, in confident language, which is worse than logging nothing.

**THE RULE: a probe's success condition must be an OBSERVABLE EFFECT, not the
absence of an exception.** If the effect cannot be observed from inside the
script, the log must say what was ATTEMPTED and by what route, and leave the
verdict to the screen. Write `set via pane.setTitleIcon <- x` and not `applied`.

**AND PREFER A CAPABILITY TEST TO A GUARD WHERE ONE EXISTS.**
`type(pane.setTitleIcon) == "function"` is a fact the engine will answer
directly; a pcall around a call that might silently do nothing is not. The
second attempt probed both candidate routes, named the one taken in every line,
and settled a question the first attempt had made LOOK settled.

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

**AND THE CHECKER IS AS LIKELY TO BE WRONG AS THE FILE.** Twice on 2026-08-30 a
pre-flight assertion failed and the fault was in the assertion:

- **A regex pass split the file on `'\r\n'` after opening it in text mode**,
  which had already translated CRLF to LF. The split found nothing, the whole
  file became ONE line, and every `re.M` anchored pattern then matched or missed
  for reasons having nothing to do with the code. A shape check that cannot see
  line boundaries is not a shape check.
- **A top-level comma counter did not skip string literals**, so the comma in
  `"the pather is on %s, not an Arc "` read as an argument separator and a
  correct `sb.logInfo` call was reported as an arity mismatch.

Both were caught only because the failure was investigated instead of the code
being edited to satisfy it. **A RED CHECK IS A QUESTION, NOT A VERDICT** -- find
out which of the two is lying before changing either. The cost of getting this
backwards is a working file edited into a broken one to please a broken test.

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

**SECOND INSTANCE 2026-08-31, AND THE RULE WAS ALREADY WRITTEN HERE.** Moving a
helper above its first caller by index slicing landed one character inside a
comment marker and ate a dash from two lines. One became `---  CAN THIS...`,
which is silent. The other became `-  Sweep a dry run...`, **which is a parse
error, not a comment** -- that file would not have loaded. Block balance does not
catch it, and neither did any check in place at the time.

**A LINE STARTING WITH A SINGLE DASH IS NOW A PRE-FLIGHT FINDING.** Cheap, exact,
and it catches both halves of that failure -- the fatal one and the silent one.
Worth folding into `petports_luacheck.py`.

**THE SHAPE TO NOTICE: A SLICE THAT LANDS OFF BY ONE IS NOT A BAD MATCH, IT IS A
GOOD MATCH AT THE WRONG OFFSET.** `str_replace` has no offset to be wrong about.
Every rule in this entry has now been learned twice.

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

### A change-gated log needs its reset beside the event that makes it stale
`proc.tooling.gatereset` -- see also `proc.tooling.silentstall`, `arch.pathing.mediumenforcement`

The logging discipline in this mod is to store the last thing said and only log
on change. THE GATE IS THE EASY HALF. WHERE IT IS CLEARED IS THE HALF THAT GOES
WRONG, and it went wrong in BOTH DIRECTIONS within one session.

**TOO STICKY -- A SESSION-LIFETIME LATCH.** `petportsSteerBlind` was cleared only
on the path where the fallback declined to move, and never in the branch where a
plan was running. So the first blind steer of a unit's life latched the value and
every later one was SILENT for as long as that unit lived. Measured: 72
`FLY path ended with false` and ZERO steering lines in one session, while the
unit was demonstrably being driven at `flySpeed` with no plan. The session before
logged exactly three lines -- one per re-home, because a respawn was the only
thing resetting it. That is how the blind-steer fallback stayed unattributed
through two rounds of testing.

**TOO LOOSE -- CLEARED ON THE SAME TICK IT WAS SET.** Fixing the above added a
REFUSAL outcome to the same gate, and the old reset was still sitting at the
bottom of the branch. The refusal set the gate, fell past the movement block, and
cleared it again on the same tick. 1871 identical lines in four minutes.

**THE RULE.** Clear a change gate at the event that makes the previous statement
stale -- not on the failure path, and not at the end of the function. For this
one that event is "a plan is running", so the reset sits beside
`petportsFlyPathEnd`, which is reset for exactly the same reason.

**THE TELL, IN EITHER DIRECTION.** Count the gated line against an ungated line
that must accompany it. 72 path-end lines and 0 steering lines is a latch; 1871
steering lines against a handful of plans is a same-tick clear. Neither is
visible by reading the log; both are obvious the moment two counts are compared.

### An aborted edit batch writes nothing, so re-read the file
`proc.tooling.batchedits` -- see also `proc.pathing.readsource`, `proc.tooling.instrument`

**LEARNED 2026-09-02, AND IT SHIPPED A CRASH.** Edits are applied by a script
that performs several exact-string replacements and writes the file ONCE at the
end, with an assertion per replacement. One assertion failed. The exception
aborted the script before the write, so EVERY replacement in that batch was
discarded -- including the ones that had already succeeded and reported OK.

**THE FAILURE WAS NOT THE ABORT, IT WAS WHAT WAS CONCLUDED FROM IT.** A failed
anchor was read as "that particular edit is not needed" and the session moved on
with a follow-up script covering the remaining steps. The correct reading is
"THE FILE IS NOT IN THE STATE YOU THINK IT IS". The net result was a function
that declared a list, returned that list, and never filled it, with the old
single-value return still in place.

**IT PRESENTED AS SOMETHING ELSE ENTIRELY.** `ipairs` walked a `{x,y}` point as
two numbers, every tick died indexing a number, the unit script was killed, and
the port respawned it -- which reads from outside as a failed media check, not as
a Lua fault.

**THE RULE. After any aborted batch, re-read the function and verify every
return path before running anything else.** Not the diff, not the remaining
edits: the function.

**AND `#t` ON A POINT IS 2**, so a length check cannot tell a list of openings
from a single opening. Guards on shape must test `type(t[1])`, not `#t`. That is
what made the bad value survive one build undetected.

### A new helper goes below every local it calls, and this was hit twice
`proc.tooling.localorder` -- see also `fact.tooling.nilglobal`, `proc.tooling.paneheck`

**TWICE IN TWO CONSECUTIVE BUILDS, 2026-09-03, BOTH IN THE SAME FILE.** A helper
added near the top of `petportconfig.lua` called `dbg`, a `local` defined 330
lines below it. The next build's helper called `tell`, a `local` 44 lines below
it. Both resolve as GLOBALS at that point, both are nil, and both throw -- not at
load, but on the one path that calls them, which in both cases was a refused
click nobody exercises often.

**THE FILE ALREADY WARNS ABOUT THIS IN ITS OWN COMMENTS** -- "a `local` further
down the file is a nil global to everything before it" -- beside `activeTab`,
which was moved for exactly this reason. Knowing the rule did not prevent it
twice, which is what makes it a process entry rather than a fact.

**THE CHECK IS MECHANICAL AND TAKES SECONDS.** For every name a new helper
touches, compare the line of its definition against the line of its first use.
Both faults were caught that way, before delivery, after the second one made the
pattern obvious.

**THE PANE PRE-FLIGHT CANNOT SEE IT.** From the linter's side a forward
reference to a `local` is indistinguishable from a reference to a legitimate
global, which is the same blind spot `proc.tooling.paneheck` records for
callback registration -- and a candidate for it to grow.


### The handoff linter reads git, because the gap is not visible in the text
`proc.tooling.gapcheck` -- see also `proc.tooling.session`, `arch.fuel.burn`

**ADDED 2026-09-03, AFTER THE DOCUMENT LOST A WHOLE SUBSYSTEM.**

**WHAT HAPPENED.** The fishing system was built across seven commits between
2026-09-01 17:33 and 2026-09-02 01:11. The handoff was last written at 16:05 on
2026-09-01 -- before any of them -- and the entry it filed that day,
`todo.module.fishing`, calls fishing an investigation nobody has committed to.
The next handoff write was 2026-09-02 16:32, by which point the session had
moved to diving, and its STATUS recorded diving. Four more writes followed and
each recorded the session in front of it. Nothing in checks 1 to 9 could see it:
every entry was well formed, and the one that was wrong was wrong about the
WORLD.

**THE ROOT CAUSE IS THAT STATUS IS DESTRUCTIVE BY DESIGN.** It is rewritten
wholesale and never appended to, which is correct -- it is the one section that
must not accumulate. The cost is that it is also the only place a
finished-but-unwritten system would have been mentioned, so a rewrite takes that
mention with it. `todo.locomotion.sinker` failed the same way in the other
direction: it was authored FOUR HOURS AFTER the chassis it asks for was
committed, from the session's memory of where things stood rather than from the
tree.

**THE OBVIOUS CHECK WAS MEASURED AND REJECTED.** "Flag files that changed since
the handoff was written and that no entry mentions" sounds right and is not: the
document names 37 of 128 source files, because it describes SYSTEMS and not
files. That check fires on 91 things on its first run, and `proc.tooling.paneheck`
already records what happens to a check that gets cleared rather than read.

**SO IT MEASURES THE GAP INSTEAD.** `git log <last commit that touched the
handoff>..HEAD` needs no vocabulary and cannot drift. It PRINTS on every run,
and becomes a FINDING only when the working copy's STATUS heading differs from
the committed one -- a rewrite in progress, which is the exact moment the
previous STATUS is destroyed. Check 11 closes the escape hatch by flagging a
STATUS body that changed under an unchanged heading, which is either the
wholesale-rewrite rule being broken or a rewrite check 10 cannot see.

**TESTED AGAINST THE REAL EVENT.** A worktree at `4cfe870` with the handoff
replaced by the version `c94c55e` was about to commit reports 11 commits since
`bf8f266` and names `fishing ix part 1`, `fishing ix part 2` and
`fishing kinda sorta working now` among them.

**WORK COMMITTED IN THE SAME COMMIT AS THE HANDOFF IS INVISIBLE, BY DESIGN** --
it is being written up as it lands. Both checks degrade to SILENCE, never to an
error, if git cannot answer, so the linter still runs on a loose copy.

**IT DOES NOT COVER FORWARD REFERENCES FROM CODE.** Twice on 2026-09-03 a tag
was cited in a `.lua` comment before the entry existed -- `arch.fuel.burn` and
friends, written into the build and only filed afterwards. Check 9 catches that
inside the document and nothing catches it outside. WRITE THE ENTRY OR DO NOT
CITE THE TAG.

### One change, one log
`proc.tooling.onechange` -- see also `proc.tooling.instrument`, `proc.tooling.controlfirst`, `proc.tooling.batchedits`

**FILED 2026-09-03, AND IT IS OLDER THAN ITS TAG.** The rule has been operated
by for weeks and cited in at least two entries -- `fact.pathing.movedrop` leaves
a bug unfixed because "the process note is emphatic about not stacking an
unverified change onto one" -- while having no entry to be emphatic in. A rule
that everything defers to and nothing states is one bad session from being
forgotten.

**DO NOT STACK CHANGES WITHOUT A CLEAN TEST BETWEEN THEM.** Two changes and one
log means the log cannot attribute the outcome to either. The failure mode is not
ambiguity, it is CONFIDENCE: a session that improved is read as both changes
being right, and a session that regressed is read as both being wrong. Measured
cost -- a session went from "almost working" to "the whole thing broken" and
neither change could be individually reverted, because nothing knew which one had
done what.

**IT APPLIES TO CORRECT FIXES TOO, AND THAT IS THE PART THAT GETS ARGUED WITH.**
The temptation is always a fix that is OBVIOUSLY right and costs one line -- an
adjacent bug noticed while building something else. It still spends the log. On
2026-09-03 a magma-fish medium check was left out of the network-fishing session
for exactly this reason and filed as `todo.fishing.medium` instead; the fix is
one call and it was still not worth the measurement.

**THE TEST BETWEEN THEM IS THE POINT, NOT THE COUNTING.** Two changes to
unrelated subsystems that produce independent log lines are one change each. Two
changes on the same code path are one change even if they are one line apart.
Ask what a single log could and could not attribute.

