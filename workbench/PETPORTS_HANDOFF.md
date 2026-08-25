# PETPORTS — handoff

`lofty_petports`. A deployable spawner ("petport") that houses a utility unit,
plus the unit behaviour that makes one worth having. Split out of the Nicemice
mod on 2025-08-19, before any public release, so that object and monster
identity names were still free to change.

Nicemice remains the intended content layer: unit types, chassis variants and
the encounter/quest loop that unit items drop from. This mod is the machinery.

## Current state

**Working, verified in game.** The petport places, opens, and spawns a unit when
a unit item is socketed. The unit persists, survives world reload, and its state
round-trips through the item — resource levels continue where they left off and
known players survive. Unsocketing despawns it. Socket-cycling does not leak
units. Placement validation is live: a unit that gets sleepy in a doorway walks
clear of it and sleeps beside it, centred in a single-tile gap.

**Filters sort, and storage defragments itself.** Deposit beacons route items to
the right crate by tag and category. Eviction is built on the same predicate:
anything in a crate that fails that crate's own filter is a misfit and gets
hauled to one that wants it. Auto-disperse falls out for free — a dropbox is
just a beacon whose filter accepts nothing, so everything in it is a misfit. A
misfit is never moved unless somewhere both accepts it AND has room, so full
storage postpones tidying rather than parking a unit with an unplaceable stack.

**RESTOCK BEACONS ARE BUILT AND VERIFIED, INCLUDING COMPOUND CRATES.** A restock
beacon names a LIST of items, each with its own min and max, and units keep that
crate stocked out of the network's ordinary storage. Verified end to end: fetch
from a deposit crate, deliver, evict overstock, evict anything unrequested, and
several requests in one crate all serviced. See "Restock beacons — built".

**Storage compacts itself.** One item spread across more slots than it needs is
merged, both after every port-side container mutation (free — the unit is already
standing there) and by a dedicated bottom-priority walk for crates nothing else
visits. Split stacks are bucketed by PARAMETERS, so two copies of one Betabound
music sheet merge and two different songs do not.

**Dropping through platforms works, by placement rather than by holding down.**
The unit is positioned two pixels below the last platform its plan wants passed
and falls from there. Six earlier builds tried to time a `controlDown` hold and
none of them could have worked; see the traps section for why.

**Beacons are `maxStack` 1.** They carry a filter, an on/off state and an icon,
all per-instance. Mixed stacking cannot be expressed: `setInstanceValue(key, nil)`
writes an explicit null rather than removing a key, and `setInventoryIcon` marks
the descriptor permanently — so a beacon stops being blank the first time it is
looked at. Stacking two configured beacons would silently merge two filters.

**Sorting is measured against the whole vanilla asset tree.** 29 groups, 193
subgroups. Every colonyTag and every category on 2879 objects is claimed, and
4931 of 4974 scanned items route somewhere. The manifest is keyed by id so mods
patch by name rather than by index, and there is a written guide for them.

**The beacon pane is functional and ugly.** Rules add in one click, each rule row
carries its own accept/deny checkbox and delete button, and selecting a rule
swaps the lower panel to a grid of its subgroups where each tile is a checkbox.
Tile art is placeholder. 19 groups and 177 subgroups behind it, all 98 vanilla
categories covered.

**Vents link and report it.** One wire links a pair both ways, confirmed by log:
vent A finds B through its OUTPUT node while B finds A through its INPUT node.
The `linked` animation state fires. Two bugs were in the way — a stray patch
hunk header on line 1 of the `.object` breaking JSON parse, and `collectIds`
guessing wrong twice about the node-call return shape. Both are in the traps
section.

**The diagnostic task runs end to end.** The petport scans its coverage rect,
generates a standing point, takes a claim in `world.properties`, dispatches to
its socketed unit, and the unit walks there, dwells, and reports done --
releasing the claim. Eleven consecutive tasks completed clean across a 20-tile
span. Interruption is covered: unsocketing mid-task releases the claim within
the second, and a reload with a task in flight releases on `uninit` and resumes
after.

**TASK 1 -- ITEM DROP COLLECTION WORKS.** The port sweeps its rect with
`world.entityQuery` for itemDrops, skips anything under another owner's live
claim, takes the nearest, and dispatches. The unit resolves a standing position
near the drop, paths to it, calls `world.takeItemDrop`, and reports. The item is
DESTROYED on pickup -- the testing sink. Verified on flat ground, up a platform
staircase, and via a chained route across four platform hops at height.

Getting there took untangling five separate pathfinding problems, all recorded
in the traps section: the inverted `standingBoundBox`, the never-cleared
`aStar`, `findGroundPosition`'s missing arguments, A* never reporting
unreachable, and `exploreRate` starving on server-side fidelity.

**Failure handling is real, not stubbed.** Unreachable work fails in seconds
rather than hanging, and the port backs it off on an escalating schedule (10s,
30s, 120s, 600s) so one stranded item cannot occupy the dispatch slot. Drops get
a settle grace so a falling item is not mistaken for an unreachable one. A
failure while the unit was OUTSIDE its rect does not count against the work --
the unit's position was the problem, not the item.

**NETWORKS AND UNION DISPATCH WORK.** Ports publish into a registry in
`world.properties`, derive their own membership from it, and dispatch across the
whole network's coverage. Verified: a unit from port 1 collected an item 8 tiles
inside port 2's rect, with neither port ever messaging the other.

**Units are leashed to their network, with recall and re-home behind it.** All
three layers verified in game: an idle unit turns back at the network boundary
on its own; a unit outside anyway is dispatched a walk home; a unit that cannot
walk home -- knocked off a ledge with no route back -- is re-homed after two
failed recalls, the whole escalation taking under 30 seconds. The re-home is a
guarantee, not a normal path; a teleporting pet looks lazy and the first two
layers exist to keep it rare.

Confirmed separately that a unit ON TASK paths freely outside the network and
returns inside when idle, which is the distinction the leash is built on.

**Sleep is gated off, not fixed.** `strictPortTethering` in the monstertype
disables wandering for robot units, and `petports_allowSleep` (default false)
disables napping. The sleep gate is enforced in THREE places, because two of
them are individually insufficient: `scoreAction` (score 0), `reactToObject` (a
pethouse queues sleep by REACTION, not by score, so the score gate alone does
not cover it), and `petportsSleepAction.enterWith`. The underlying cause is
unchanged -- when the task state exits, `currentActionScore` resets to 0 and
accumulated `sleepy` wins the gap -- so a biological unit that wants to nap will
still need the dispatch-from-report-handler fix.

(A second one is fixed: `enteringState` used to `emote("happy")` on every
pickup, which at one task per five seconds was a permanent affection loop.
Removed. Any acknowledgement of a new task belongs on a cooldown, or nowhere.)

**MULTI-HOP VENT ROUTING WORKS END TO END.** Verified: a unit with no direct
route planned a two-hop path, walked to the first vent, travelled, walked to the
second, travelled again, and collected the item. Also verified taking a single
hop and then walking the remainder.

Cold-cache cost is the remaining weakness: the first plan from a given port
spends roughly forty seconds probing, because every UNREACHABLE edge must
exhaust A* to answer. Warm, plans resolve in milliseconds -- four edges resolved
in under a second once known.

**Visual debug exists.** `petports_drawRouteDebug` draws vent mouths coloured by
cached reachability, teleport edges, the active probe, the planned route, and
the pathfinder's actual computed edges coloured by move type. Gated behind
`PETPORTS_DRAW_DEBUG`; visible with debug mode on.

**BUILT since: cargo and deposit.** A unit keeps what it picks up and takes it
to a crate. `world.takeItemDrop` returns a descriptor, the unit passes it back on
its task report, and the port appends it to `petData.cargo` -- so it persists
with the unit ITEM through despawn, reload and being carried to another world.
Stacks merge on matching name AND parameters, which keeps two music sheets with
different songs apart. Cargo is written through immediately rather than on
WRITE_INTERVAL, because the world drop is already destroyed by then and the item
exists only in the port's memory until the write lands.

Crates declare themselves: a container holding an item whose config carries
`petports_sortingBeaconBehavior` is a deposit target. See the beacons section.

**BUILT since: crates answer for themselves.** `depositWork` asks
`world.containerItemsCanFit` per carried stack rather than inferring fullness
from a refusal, and `CONTAINER_FULL_BACKOFF` (60s) survives only as the fallback
for when the engine will not answer. The bug that produced it is worth carrying
into the filter work: the old path backed a container off wholesale the moment
ANY stack bounced, so one steak needing a free slot diverted every stackable
item in the load to a second crate. The refusal was about one descriptor and was
applied to all of them.

**BUILT since: the deposit beacon is a real item.**
`petports_beacon_deposit.activeitem`, stackable, carrying its behaviour in its
CONFIG rather than its parameters so every copy works. It is an activeitem
purely so that "use it to configure it" has somewhere to live later; the script
is a no-op stub, because an activeitem with no script errors on activation.

**Animal harvesting is BUILT**: farm animals are discovered by reading
`root.monsterParameters` for the TYPE, and harvested with one
`world.callScriptedEntity` call that spawns the produce and resets the animal's
own timer. See Task 2.

**Farming is BUILT AND VERIFIED end to end**: discovery, harvest, drop
collection, deposit, replant intents, seed withdrawal and replanting of crops of
arbitrary footprint, and watering of dry tilled soil -- all of it surviving vent
traversal in both directions. **The cycle runs with no sprinkler
infrastructure.** Animal produce is the only piece of Task 2 still unspecified.

**Still not built.** Docking, per-item routing, a trash can, and any notion
of cargo capacity -- ANY cargo is treated as a full load, deliberately, and
`findWork` orders deposit above collect so a loaded unit ferries before it
gathers anything else. The participate/ID interface does not exist: networks
derive correctly, but nothing lets a player author a network id or opt a port
out of auto-merge, so half the network design is unreachable from in game.
Sorting and harvesting remain unstarted. Filter beacons, the active provider
beacon and beacon on/off are specified but unbuilt -- see the beacons sections.

The placement-time coverage preview IS built -- `petport_range_preview.png`
stacked through `imageLayers` on both orientations -- and is due to be replaced
outright rather than extended. See "Coverage visuals belong to the player, not
the object".

**Debug flags, currently ON.** `TASK_DEBUG` in `petportsTaskAction.lua`,
`VENT_DEBUG` in `petports_petvent.lua`, `DEBUG` in `petports_petport.lua`. A
verbose logging pass was added deliberately: per-drop dispatch verdicts with
reasons, raw vent node reads labelled by direction, probe start/result/timeout
with tick counts, cache hit vs miss, planRoute expansion, and both vent entry
sites labelled distinctly. Two per-tick pathing lines (`pre-move` / `post-move`)
bracket the mover and are the noisiest thing in the mod -- those come out once
the mover work is finished; the rest should stay.

What stays on unconditionally regardless: dispatch, task outcome, dispatch
rejection reasons, claim abandonment, claim expiry, and residency lifecycle.
Those are the silent-nil guards and must not be flag-gated — see the traps
section.

Everything logs through `sb.logInfo` with `%s` ONLY. Star's logger implements
its own formatter; `%.1f` raises "Improper lua log format specifier" at runtime,
which is a crash in the middle of whatever you were diagnosing. Pre-format with
`string.format` (ordinary Lua, no such limit) or `sb.printJson` and pass one
string.

**BESPOKE ART: the unit and the petport. Placeholder: the vent.**

The unit has its own body — `body_0_lit.png` / `body_0_fullbright.png`, a 24x16
grid of eight `run` frames, split across the world-lit and glow layers the
monsterpart declares. No more borrowed pteropod sprites. What it does NOT have
is any OTHER state's frames: `default.frames` names `run.1`..`run.8` and nothing
else, so every state the animation declares resolves to the same eight frames.
See "The drone is always running" — that is now an art gap in one direction
only, not placeholder art.

The petport has its own art in three independently animated components — hull,
door and interior — each with a lit and a fullbright layer and each driven by
its own stateType. The door cycle is TEN frames, authored once as `opening.1`
..`opening.10` and aliased in reverse for `closing`, so one strip serves both
directions. Plus a dedicated `petports_petporticon.png`. This is what
`setHullAnimationStateIntent` and `setAnimationStateForAllHullComponents` in the
object script exist to drive.

The vent is still a flat tan box, turning red when linked — two visually
distinct frames on a 16x16 grid, deliberately so that a silent linking failure
and a working link do not look identical. Its `linked` state is one frame, with
`cycle` and `mode` left in the `.animation` as a marker for where polish-phase
frames go.

**The monsterpart is still named `drone_placeholder`** — file, and the `name`
field inside it — which no longer describes what it holds. Renaming is free
while there is exactly one variant and expensive once there are several, since
which monsterpart a unit wears follows from its seed over the matching set.
Same argument as the mod split: cheap now, not later.

## Layout

    items/categories.config.patch                      -- petports_unit + petports_beacon
    items/lofty_petports/
      petports_unit_test.item, .png
      beacons/
        petports_beacon_deposit.activeitem, .png
        petports_beacon_restock.activeitem, .png
        petports_beacon.lua        -- pane channel + token; the CONFIG carries the meaning
        petports_beacon.animation
    interface/lofty_petports/
      beaconconfig/    beaconconfig.config, .lua, panewide_* + tile art
      restockconfig/   restockconfig.config, .lua, panesmall_*,
                       slot_backing.png, field_backing.png
    scripts/lofty_petports/
      petports_work.lua          -- claims + coverage rects, shared both sides
    stagehands/lofty_petports/
      petports_residency.stagehand
      petports_residency.lua     -- keepAlive; holds one port's rect resident
    monsters/lofty_petports/
      petports_contract.lua      -- functions the port and vent call ON a unit
      petports_petBehavior.lua   -- FORK of vanilla petBehavior.lua
      petports_placement.lua     -- "is this a polite place to stop?"
      petports_think.lua         -- thinking spinner; ping per tick, no release call
      petportsSleepAction.lua    -- replaces vanilla sleepAction
      petportsTaskAction.lua     -- executes a dispatched task
      drone/
        petports_drone.monstertype, .animation
        body/  drone_placeholder.monsterpart, art, default.frames
      shared/
        spinner/ spinner.png, .frames   -- shared across unit types on purpose
    projectiles/lofty_petports/
      petports_watersprinkle/  .projectile, .png, .frames, icon.png
                               -- EMPTY actionOnReap; filled per cast
    tiles/mods/
      tilleddry.matmod.patch   -- swamp water wets tilled dirt
    objects/lofty_petports/
      petport/  petports_petport.object, .lua, .animation, art, default.frames,
                petport_range_preview.png/.frames  -- placement-time coverage box
      petvent/  petports_petvent.object, .lua, .animation, art, default.frames

Naming convention is `petports_` + the thing's own name, hence
`petports_petport`. The vent's pet-facing API keeps plain verb names
(`petports_ventTravel`, `petports_ventTeleport`) since those are functions, not
assets.

## Open decoupling work

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

## Engine traps

Hard-won, mostly by getting them wrong first. Several are vanilla bugs or
undocumented engine behaviour rather than anything specific to this mod.

**A PANE TOKEN HELD IN `self` DOES NOT SURVIVE.** The beacon mints a token in
`activate()` so a pane can prove which beacon it is editing. Held as runtime
state, it is gone the moment the player moves anything through the cursor: that
re-creates the held item, `init()` runs again, and `activate()` was the only
thing that ever set it. Measured:

    petports beacon: write REFUSED: token=ab5b61a2... mine=nil

The item was RUNNING and ANSWERING — so not the shadowing case below — and had
simply forgotten. The pane could then never write, and the player's edit was lost
every single time. It is now an instance value, `petports_beaconPaneToken`,
restored at the top of `init()`. TYPE-CHECKED, not nil-checked: a cleared token
reads back as an explicit JSON null, which is not a token.

Not in `FIELDS` — it is the item's own bookkeeping and the pane must not reach
it. The old comment claiming a token must never touch item data was
stacking-based reasoning, and beacons are `maxStack` 1.

**THE SWAP SLOT SHADOWS THE HELD ITEM for message routing.**
`world.sendEntityMessage(player.id(), ...)` goes to whatever the player is
HOLDING, and an item on the CURSOR counts — so while a sample is on the cursor,
nothing answers and every write is refused. Writes are HELD and retried on the
first answering heartbeat rather than dropped, because every edit worth making is
made with something on the cursor.

**Distinguishing "shadowed" from "put away" needs the cursor**, since both answer
nil:

    beacon UNREACHABLE (answer=nil, cursor=true)   sampling -- stay open
    beacon UNREACHABLE (answer=nil, cursor=false)  stowed   -- close

and it needs a GRACE, because taking an item onto the cursor and putting it back
leaves a real window where the cursor is already empty and the item is not yet
answering — measured at 0.51s. Four checks at 0.25s is roughly twice that. Too
high lingers harmlessly; too low closes the pane mid-sample and loses any pending
write, so that dial only goes up.

**`root.itemConfig(...).config.maxStack` is ABSENT unless the item declares one.**
The engine applies its default when it builds the Item, not into the config table.
The default lives in `/items/defaultParameters.config` as `defaultMaxStack` and is
**1000**, not 1. Measured across seven items: `nicemice_gentlereminder` answered 1
from config, `oculemon` 1000 from config, everything undeclared 1000 from
defaultParameters.

Reading only the config field and defaulting to 1 silently switches any
stack-size arithmetic OFF, and it presents as "nothing needs doing" rather than
as an error — `no crate has stacks worth merging`, every tick, on crates that had
compacted correctly minutes earlier. Defaulting to 1000 was accidentally right
for the opposite reason. Read the asset.

**A TEXTBOX CALLBACK IS NOT OPTIONAL, and omitting it is a construction-time
crash.** Measured:

    (WidgetParserException) Failed to find textbox callback named: 'tbMin'

Note the NAME — nothing had asked for a callback called `tbMin`; that is the
WIDGET's name. The parser defaults a textbox's callback to the widget's own name
and then requires it to resolve. So vanilla's pixel printer, whose textbox
declares none, must be listing `tbSpinCount` in its `scriptWidgetCallbacks`.

Same failure shape as row callbacks: the pane does not open at all and the client
throws in its main loop.

**`widget.clearListItems` INVOKES THE LIST'S OWN CALLBACK.** Clearing a list is a
selection change, so tearing one down to rebuild it looks exactly like the player
clicking away. Measured:

    commitField(min, 100) -> ... is 100-1000
    requestSelected rowId=nil(nil) -> index=nil
    refreshRequests: 2 row(s)

The callback ran BEFORE the rebuild finished. Typing a number blanked the row
highlight, and the fields then wiped because nothing was selected. Guard the
rebuild with a flag the callback checks, then re-select. This is the same engine
behaviour already recorded for `ListWidget::setSelected`, through a different
door.

**Assigning nil into an ENGINE-BACKED table writes a null rather than removing
the key.** A pane read returned no `filter` at all, the script did
`state.filter = nil`, and the payload went out carrying `"filter":null` — which
is not nil in Lua, so the item's write handler stamped it onto a beacon with no
filter. Build message payloads by naming the fields you own; do not send a table
that came back through a promise.

**`initialStorage` and `initialStatus` do NOT seed a monster's `storage`.**
`petspawner.lua` appears to nest them under `scriptConfig`; it does not —
`Pet:_scriptConfig(parameters)` returns `parameters` unchanged, so the two names
are the same table and those fields land at the TOP LEVEL of what reaches
`world.spawnMonster`. But flattening them there still did not work: a unit
spawned with a fully populated `initialStorage` came up with config-default
`petResources` and an empty `knownPlayers`.

**What does work is spawn parameters as config parameters.** `groundPet.lua`
reads

    storage.petResources = storage.petResources or config.getParameter("petResources")
    storage.knownPlayers = storage.knownPlayers or config.getParameter("knownPlayers", {})
    storage.foodLikings  = storage.foodLikings  or config.getParameter("foodLikings", {})

and a fresh monster's storage is empty, so passing saved values as SPAWN
PARAMETERS under those exact names lands them through the fallback branch. Same
path `level`, `persistent` and `anchorName` already arrive by. Omit a key and the
monstertype's default applies, so a brand new unit is unaffected.

`storage.anchorPosition` has no config fallback and cannot be restored this way —
the petport's direct `setAnchor` call is what establishes it.

**A missing SCRIPT FILE fails loudly; a missing FUNCTION fails silently.** A bad
path in a monstertype's `scripts` list throws `AssetException` and refuses to
spawn the monster at all, logging once per attempt — with `RESPAWN_GRACE` that is
once a second forever, which at least gets noticed. A bare
`world.callScriptedEntity` naming a function the target does not define returns
nil and logs nothing.

**The first `setPet` after a spawn is an echo, not news.** `spawnPet` calls
`setAnchor` immediately and `groundPet.lua` answers by pushing back state it
initialized microseconds earlier. Accepting it means a restore that silently
failed also DESTROYS the values it failed to restore — observed as config
defaults written into the item 23ms after spawn. Ignore that first callback;
`seed` is stable and safe to take from it.

**`groundPet.lua` re-calls `setAnchor` every second** via `updateAnchor`, so
`setPet` runs once per second for the life of the unit. An anchor that marks
itself dirty on every callback performs a container swap per second, forever,
replicated to every client. Compare durable fields (`knownPlayers`,
`foodLikings`, `seed`) and write on change; let resource drift ride a slow timer.

**Action state names are matched by a letters-only pattern, and petBehavior
hardcodes vanilla's.** `groundPet.lua` builds its action list with
`stateMachine.scanScripts(config.getParameter("scripts"), "(%a+Action)%.lua")`
and looks the captured name up in `_ENV`, so the global must match the capture.
`%a` is letters only: `nicemice_sleepAction.lua` captures `sleepAction` and
shadows vanilla's global name. Camel case — `petportsSleepAction.lua` — keeps
the capture whole.

But `petBehavior.actionStates` hardcodes `["sleep"] = "sleepAction"`, and
`petBehavior.run` compares `stateDesc()` against that string to decide whether
the action is already running. A replacement state must therefore expose
`description()` returning vanilla's name — `stateDesc()` prefers `description()`
when present. Without it the behaviour layer thinks sleep is not running and
re-picks it.

**Vanilla `sleepAction` reads a config path that does not exist.**
`config.getParameter("actions.sleep.minSleepy", 65)` — but the monstertype
defines `actionParams.sleep.minSleepy`. There is no top-level `actions` key, so
the lookup always misses and the hardcoded 65 is used. Any tuning of that value
has never taken effect in vanilla or in any mod that inherited the file.

**A resting footprint is centred on the position, so candidates must be snapped
to tile centres.** A unit's `mcontroller.boundBox()` is about a tile wide and
centred, so a candidate at integer x spans `[x-0.5, x+0.5]` and straddles TWO
tile columns — the search then only succeeds where two adjacent tiles are clear.
Candidate x values are inherited from wherever the unit happened to be standing,
so the alignment is arbitrary. Observed as a unit refusing to step out of a
doorway unless it had two tiles of room. `math.floor(x) + 0.5` fixes it, and
offset 0 is worth searching for the same reason: the exact position can fail
where the centre of that same tile passes.

**Declining to rest is not the same as moving away.** Placement validation gates
RESTING only — the idle and wander states are still vanilla and will park a unit
anywhere. A unit that declines to sleep just stands where it was, which looks
identical to sleeping there unless you watch for the emitter.

**`writeBackToItem` cannot run on unsocket.** It needs the item still in the
slot, and by the time `update` notices the removal it is already in the player's
inventory. The final save is a permanent no-op; whatever the item holds is
whatever the last IN-SLOT write put there. So a periodic flush is not a safety
net, it is the persistence granularity — the interval is exactly how much drift
an unsocket discards. World unload is fine: `uninit` runs while the item is
still socketed.

**Frame indexing is 1-based for anything with an `.animation` file, 0-based for
objects without one.** A state declaring `"frames" : 8` and pointing at
`<partImage>:fly.<frame>` resolves `fly.1` through `fly.8`. Vanilla's own frames
files confirm it — `firepteropod`'s grid names `fly.1`..`fly.8`, and
`petbunny.animation` declares `"idle" : { "frames" : 1 }`, which can only ever
resolve one name. Getting this backwards produces an entity with a working
collision box, working scripts and no sprite, which reads as a missing asset
rather than an off-by-one. Furniture objects WITHOUT an `.animation` file are
0-indexed, which is where the confusion comes from.

**An entity that dies on its first update never draws.** Debug bounding boxes
come from the collision system, not the animator, so "hitbox visible, sprite
missing" has two completely different causes — a broken asset chain, or an
entity that was killed before the animator resolved a part. To tell them apart,
strip the monstertype's `scripts` list down to `/scripts/util.lua` and spawn it
inert. If it renders, the assets are fine and the problem is lifecycle. (Do not
strip to an empty list; keep one script in there.)
**`objectType` has a fixed valid set, and `category` is a different key that
takes different words.** Valid `objectType` values are `object`, `container`,
`loungeable`, `farmable`, `teleporter` and `physics`. `"wire"` is NOT among
them, but `"wire"` IS a valid `category` — the item-category string deciding
which crafting tab the object appears under. Setting both keys to the same word
throws on the objectType lookup. Wiring capability does not come from
`objectType` at all; it comes from declaring `inputNodes` / `outputNodes`.

**`flipImages` does NOT flip `spaces`.** Every orientation's occupied tiles must
be authored by hand, mirrored ones included. A symmetric footprint hides this
completely, so it surfaces the first time a shape is asymmetric.

**An orientation image with no frame specifier is measured at FULL SHEET
dimensions.** `example.png` on a two-frame 32x16 sheet previews as 4x2 tiles;
`example.png:idle.1` previews as 2x2. Alias resolution and preview sizing are
separate paths, so a `"default"` alias in the `.frames` file does not save you.
The failure looks like a `spaces` mistake rather than an image one.

**Manual `spaces` is what makes arbitrary placement graphics possible.** Giving
up `spaceScan` and listing occupied tiles explicitly —
`"spaces" : [ [0,0], [0,1], [1,0], [1,1] ]` — means the preview image can carry
anything on top of the footprint, a coverage-range indicator included.
`imageLayers` stacks them.

**`imageLayers` render during PREVIEW ONLY when the object has an animation**,
because the animation takes over on frame 1 once placed. A placement-time
indicator therefore needs no toggle, no cleanup and no state — it is simply gone
after placement.

**A missing `inventoryIcon` is not a crash.** The game places a rarity frame
around a transparent placeholder in the player's inventory. Contrast with a
missing orientation image, which does throw.

**`keepAlive` is available on stagehands and NOT on objects.** This is the whole
reason region residency is stagehand-owned rather than object-owned.

**`uninit` fires on world unload as well as on destruction; `die()` fires only
on destruction.** Anything that should happen when a player breaks an object —
dropping cargo, playing an exit animation, killing an anchored stagehand —
belongs in `die()`. Putting it in `uninit` means it fires on every world reload.

**Entities with a `uniqueId` can be located while unloaded.** Position is
readable from the world API for any uniqueId-assigned entity that has been
loaded at least once, apparently so the quest compass can point at targets in
unloaded chunks. Position is all that is needed, since a `loadRegion` call over
that position brings the entity back. `world.sendEntityMessage` by uniqueId is
believed to require the target to be currently loaded.

**`sb.printJson` STRINGIFIES NUMERIC TABLE KEYS**, because JSON object keys can
only be strings. A Lua table `{[18] = 0}` prints as `{"18":0}`, which reads as a
string key and is not one. KEY TYPE CANNOT BE INFERRED FROM printJson OUTPUT --
use `type()` if it matters. This cost two failed attempts at the vent linking
fix: the first log was read as proving string keys, a fix was written around
that, and it failed in a new way.

**`getOutputNodeIds` / `getInputNodeIds` return a table KEYED BY ENTITY ID**,
whose value is the node index. Entity 18 wired to node 0 is `{[18] = 0}`.
Verified in game twice. Both key and value are numbers, so this shape is
INDISTINGUISHABLE from a plain list of ids by inspecting one entry -- do not
write code that tries to tolerate both. Take the key.

**`sb.logInfo` accepts `%s` and NOTHING ELSE.** Star's formatter has no width or
precision specifiers, so `%.1f` raises "Improper lua log format specifier" and
`%d` is equally invalid. Non-strings go through `sb.printJson` or `tostring`
first. It fails at CALL time, not load time, so a bad specifier in a rarely-hit
branch sits dormant until that branch runs -- ours fired on the first successful
dispatch, meaning the error appeared exactly when the feature started working.

**`config.getParameter("objectName")` is not a reliable way to get an object's
own name; use `object.name()`.** If the parameter lookup returns nil, every
comparison against it is `x == nil`, which is false for everything -- so a
filter built on it silently discards all candidates. That is indistinguishable
from having collected no candidates in the first place, and it masked the vent
linking bug through two separate fix attempts.

**`approachPoint` owns the arrival test; do not hand-roll one.** A target from a
tile scan is the coordinate of the empty tile ABOVE the floor, while a unit's
position is its CENTRE, roughly three quarters of a tile higher (observed:
target y 704, unit y 704.75). A tight `world.magnitude` radius against the raw
target therefore never closes, and the unit stands exactly where it was sent
while timing out. `approachPoint` resolves through `findGroundPosition` and
returns true on arrival.

**A frozen unit and an unreachable target are the same symptom.** Both time out,
both leave `self.pathing.stuck` unset. Accumulated movement distance separates
them: zero means the unit never started (look at the unit's own position --
`groundPet.lua`'s `move()` gates on `validStandingPosition`), non-zero means it
walked as far as it could (look at reachability). Worth noting `stuck` did NOT
fire for a unit that stood motionless for twelve seconds, so it cannot be relied
on as the only guard.

**An early `return` in `update` silently disables everything below it.** The
petport's no-item branch returned before its work tick, so unsocketing an item
stopped the claim sweep and the claim refresh while a claim was still held --
leaving it in `world.properties` until that port's next `init`, or forever if
the port was mined rather than emptied. Unsocketing is the most ordinary
interaction there is, and every symptom of this was on a silent path. Audit
every early return for cleanup it skips.

**`world.loadRegion` is a CONTINUOUS ASSERTION, not a latch.** Vanilla's Glitch
defense mission manager calls it every single update, and so does ours. Calling
it once does not pin a region.

**`world.spawnStagehand` DOES accept `uniqueId` through its override table.**
Verified: a stagehand spawned with one is found by `world.loadUniqueEntity`
afterwards, and survives a world reload with the id intact. The stagehand's own
`stagehand.setUniqueId` is kept as a redundant second path but has not been
observed doing anything.

**A stagehand's `init` runs SYNCHRONOUSLY inside the `spawnStagehand` call**,
before it returns. Its log lines therefore appear BEFORE the caller's line about
having spawned it, which reads as out-of-order and is not.

**A keepAlive stagehand loads BEFORE the objects in its region**, because it is
its own `loadRegion` call that brings them in. Anything that checks for its
anchor object needs a grace period generous enough to cover that window, or it
will terminate itself during the exact moment it is doing its job.

**`standingBoundBox` INVERTS FOR BODIES NARROWER THAN 1.4 TILES.** PathMover
defaults it to `padBoundBox(-0.7, 0)` -- the bound box shrunk by 0.7 on EACH
side, "thinner for standing and landing". Our drone is one tile wide:

    boundBox         = [-0.5, -0.75, 0.5, 0.6]    width  1.0
    standingBoundBox = [ 0.2, -0.75, -0.2, 0.6]   width -0.4

Left edge to the RIGHT of the right edge. Every landing and standing node is
validated against that rectangle, so no Jump, Arc or Drop edge can terminate --
while Walk edges use the normal boundBox and are unaffected. Symptom: flat
ground works perfectly, anything vertical never resolves. Vanilla pets are
wider than a tile so -0.7 leaves them a thin but VALID box.

**`PathFinder:reset()` DOES NOT CLEAR `self.aStar`. THE MOST EXPENSIVE BUG OF
THE PROJECT SO FAR** -- it appeared three separate times in one session wearing
three different disguises. It clears `edges`,
`hasPath` and `currentEdgeIndex` only. So an abandoned search poisons the finder
PERMANENTLY: `find()` checks `not self.hasPath and not self.aStar`, sees a live
aStar, skips the reset-and-start entirely, and keeps grinding the OLD search
toward the OLD target forever. Symptoms it produced: the first task after a world load succeeds and then one
unreachable target breaks every subsequent task; a unit refuses to walk sixteen
tiles along flat ground it crossed minutes earlier, reporting "no path"; a vent
leg never plans because the pather is still grinding the failed search that sent
us to the vent in the first place.

**WHY VANILLA GETS AWAY WITH IT.** NPC behaviours build a PathMover inside a
behaviour node and discard it when the node exits, so a stale aStar never
outlives the search that made it. Ground pets cache the pather on `self` for the
entity's lifetime, which is fine for vanilla's usage -- a pet chases a player or
an item, re-targets constantly within a couple of tiles, and its searches
succeed rather than being abandoned. The bug only bites when a search FAILS and
the target then changes, which vanilla pets essentially never do because nothing
tells them to go somewhere unreachable.

We generate that situation constantly. Anything reusing a long-lived pather
across changing destinations inherits this.

**Rule: rebuild the pather whenever the destination genuinely changes after a
failed search.** Per task, and per vent leg.

**The tell is distinctive**: a unit refusing to walk somewhere it has already
been, with "no path" on screen.

**A* NEVER REPORTS UNREACHABLE within any practical time.** `explore()` returns
false only when A* exhausts its open set, bounded by `maxNodesToSearch = 70000`.
At the default explore rate that takes minutes, so an unreachable target returns
"pathfinding" indefinitely. There is no failure signal to wait for -- a timeout
is the only terminator, which is why work backoff is mandatory rather than nice
to have.

**`PathFinder:exploreRate()` READS `world.fidelity()`, WHICH IS A SERVER-SIDE
LOAD SETTING.** 25 node expansions per update at "minimum", 150 at "high", with
no player-facing control -- it is not a graphics option. MEASURED: a chained
route (deck -> staircase -> four platform hops) took 22.25 SECONDS to solve at
the default rate; the same target from atop the platforms took 0.08s. It was
never unreachable, it was starved.

Overriding it per instance -- `self.pather.finder.exploreRate = function() ...`
-- brought that to 2.25s at 300. This does NOT increase total work for a
solvable path; the same nodes are expanded sooner. It DOES make an unsolvable
search burn its allowance faster, so A* starts returning false honestly.

Worth doing for correctness, not just speed: without it, pathing quality varies
with SERVER LOAD, so a unit reaches a platform on a quiet server and not on a
busy one. That is indistinguishable from a bug and impossible for a player to
diagnose.

**`findGroundPosition(position, minHeight, maxHeight, avoidLiquid, collisionSet,
bounds)` -- minHeight and maxHeight have NO DEFAULTS.** pathutil.lua line 35 does
`math.max(math.abs(minHeight), math.abs(maxHeight))`, so a one-argument call
always errors. It already does the search worth hand-rolling: walks up and down
testing validStandingPosition, aligning feet via
`math.ceil(position[2]) - (bounds[2] % 1)`.

**`pcall` RETURNS THE ERROR MESSAGE IN THE RESULT SLOT.** A caller that checks
only for nil happily indexes a STRING and crashes somewhere else entirely. This
bit twice in one session -- check `type()`, not truthiness. Related: `pcall` does
not protect against a wrong RETURN SHAPE, only against a thrown error.

**`approachPoint` passes a DIRECTION into `findGroundPosition`'s `avoidLiquid`
parameter** -- `util.toDirection(-toTarget[1])`, always truthy. So every approach
runs the liquid rejection and returns nil for ground standing in liquid >= 0.1.
Vanilla bug; ours to work around.

**`self.approachPosition` is never cleared.** approachPoint only UPDATES it when
findGroundPosition succeeds, so a target that fails to resolve leaves the unit
pathing toward wherever it was last going -- which right after a completed task
is where it already stands. Motionless unit, onGround true, `stuck` unset.

**A Lua error in a monster's `update` is a DEATH, and a petport turns any death
into a LOOP.** The unit dies, the port respawns it, the next dispatch crashes it
again. Presents as a spawn problem rather than a script error.

**A `local function` referenced from `init` resolves to a NIL GLOBAL** and only
throws when that path first runs. A message handler registered in `init` that
calls a local declared further down the file loads fine and dies minutes later
on the first message. Nothing at load time flags it. Bit twice this session; the
whole file is worth auditing after any reordering.

**An item drop is discovered the moment it exists, which is MID-AIR.** Resolving
a standing position from a falling drop's position finds nothing and looks
identical to a genuinely unreachable item. Observed: a drop seen at y 719 while
falling to y 704 failed instantly and took a ten-second backoff, then was
collected without incident on retry. Give drops a settle grace.

**A REFUSAL THAT LEAVES THE ASSIGNMENT IN PLACE DEADLOCKS BOTH SIDES.** An
action state's `enterWith` returning nil does not clear the unit's held task,
and the forked petBehavior re-queues a held task EVERY TICK -- so the unit loops
against a `pickState` that keeps failing while the port waits in trackWork for a
report that can never come. Total silence on both sides and the port never
dispatches again. Observed when a player picked up a drop between the port's
sweep and the unit entering the state. Every refusal path must REPORT AND CLEAR
before returning nil.

**Both sides trusting the other to always speak is the underlying fault**, not
that one path forgot. The port now enforces a hard TASK_DEADLINE regardless of
what the unit says, which makes the contract self-healing whichever future path
forgets to report.

**`pairs()` ORDER IS NONDETERMINISTIC**, so a list built from it compares
unequal to itself between ticks. Anything that pushes state only "when it
changed" must sort first, or it pushes every tick forever.

**TWO PATHS CAN END A TASK AND THEY RACE.** The unit reports failure, and
trackWork independently notices the unit is no longer holding the task. Whoever
wins clears `self.task`; the loser's report then hits `if self.task == nil then
return end` and is DISCARDED. Consequence: recall failures were never counted,
re-home never fired, and a stranded unit was recalled forever at one attempt
every six seconds. Failure accounting must be CENTRALISED and called from every
end path -- report, trackWork, and deadline -- never left to whichever message
happens to arrive first.

**`world.platformerPathStart` IS A C++ ENGINE CALL.** `/scripts/pathing.lua` is
only a driver around it. The options table has a fixed schema and there is no
hook for injecting custom edges, so nothing script-side can add traversal types
to A* -- teleports, vents, ladders. Any such routing has to be composed OUTSIDE
the pathfinder from multiple ordinary searches.

**Pathfinding source position is an ARBITRARY ARGUMENT**, not the caller's own
position. `PathFinder:start(sourcePosition, targetPosition)` will happily answer
"is B reachable from A" while the unit stands nowhere near either. This is the
enabler for multi-leg routing without spawning probe entities to survey with.

**POSITION TABLES ARE FRESHLY ALLOCATED EVERY CALL.** `mcontroller.position()`
and `world.entityPosition()` return a NEW table each time, so any
`stored ~= given` identity comparison against a position is ALWAYS true. Caching,
memoising or change-detecting on a position by identity silently never matches.

Cost us an evening: a reachability probe keyed on its source position was
rebuilt from scratch every tick, never accumulated search progress, and so
always hit its timeout -- reporting "unreachable" for edges that were trivially
walkable. It worked while the source was a stable table held in a list, and
broke the moment the source became the unit's own position. Compare by value, or
by a derived key.

**`return` MUST BE THE LAST STATEMENT IN ITS BLOCK.** Leftover code after a
`return` is a COMPILE ERROR in Lua, not unreachable code -- and a brace-counting
checker cannot see it, because the counts still balance. Editing a branch to
return early while leaving the old tail behind produces
`'end' expected (to close 'if' ...)`.

**A script that fails to COMPILE takes the whole monster with it.** The
signature is `Exception while creating lua context` at spawn, and the pet
vanishes instantly rather than misbehaving -- distinct from a runtime error,
which kills the entity mid-update and produces a respawn loop.

**`callScriptedEntity` WITH A NIL ENTITY ID THROWS**, it does not return nil.
`LuaConversionException: Error converting LuaValue to type 'int'`, which kills
the caller's update. Any guard on an entity id must be re-checked after
anything that could despawn it -- a check at the top of a function is stale by
the time a later line runs.

**A CACHED PREDICTION MUST BE MADE UNDER THE SAME ASSUMPTIONS AS THE THING IT
PREDICTS.** A reachability probe built with different path options than the real
pather does not predict the real walk -- and because its answers are cached and
shared, a mismatch poisons routing for every future unit until something
invalidates it. Ours searched with an unpadded `standingBoundBox` while the walk
used a padded one, so it reported "unreachable" for routes that worked.

**A TIMEOUT THAT DOES NOT RECORD ITS ANSWER IS AN INFINITE LOOP.** Cancelling a
long-running probe without writing "unreachable" to the cache means the next
call re-probes the same edge from scratch, forever, learning nothing and logging
nothing. Silence, not an error.

**AN UNREACHABLE ANSWER COSTS FAR MORE THAN A REACHABLE ONE.** A* reports
success as soon as it finds a route -- well under a second in practice -- but
reports failure only by exhausting `maxNodesToSearch`, 70000 nodes, roughly
nineteen seconds at 300 expansions per tick. Any budget must be sized for the
success case and treat everything past it as "no".

**TIME OUT ON LACK OF PROGRESS, NOT ON A CLOCK.** A flat budget punishes
distance: a 35-tile walk is about nine seconds plus search time, so a
twelve-second limit cuts the unit off mid-climb and reports "cannot reach" for
somewhere it was walking to perfectly well. Reset the timer whenever the unit
actually moves; standing still is the real signal.

**`world.debug*` DRAWS PER FRAME.** A one-shot call renders a single frame
nobody sees. Debug drawing must run every update. Path edges expose
`source.position`, `target.position` and `action`, so the route the pathfinder
actually produced can be drawn -- which distinguishes "no path at all" from "a
path it cannot follow", two failures that look identical from outside.

**THE PATHFINDER'S JUMP MODEL IS MORE OPTIMISTIC THAN THE MOVEMENT
CONTROLLER.** It will plan an arc the unit cannot actually fly. The unit jumps,
falls short, `PathFinder:update` trips its stuckTimer and re-plans, and produces
the IDENTICAL arc -- forever.

DISTANCE TRAVELLED CANNOT DETECT THIS, because jumping in place accumulates
plenty of it. Net displacement over a window can: a unit making real progress
moves away from where it was, a unit bouncing off a ledge does not.

**A RADIUS IS THE WRONG TEST FOR "AM I AT THIS OBJECT".** Too small and a unit
that cannot quite reach never triggers; too large and it triggers while walking
PAST the object on the way somewhere else -- which matters as soon as multi-hop
routes exist. Use the object's own footprint: `objectBounds(id)` in pathutil.lua
builds it from `world.objectSpaces` translated to the object's position. Scales
to any object size with no constant to retune.

**Vanilla `wanderState` HAS NO BOUNDS.** An idle unit walks wherever it likes --
observed 25+ tiles outside its coverage rect, onto terrain with no route back.
From out there every target is genuinely unreachable, so the port fails
repeatedly and backs off drops that were never the problem. One stray unit
poisons the whole queue.

**Instrumentation behind a DEBUG flag defaults to useless.** Rejection reasons
were gated behind `DEBUG = false`, so the one code path under test printed
nothing at all. If a log line exists to explain a silent failure, it must not
itself be silent by default.

**`sb` is nil at chunk scope. Any top-level engine call kills the script.** A
build stamp written as a bare `sb.logInfo` beside the local it named raised
`attempt to index global 'sb'` before a single function in the file was defined,
so the unit had no task action at all — and every behaviour observed afterwards
was the previous build with a dead script on top. Root callback tables are bound
AFTER a script's chunk runs. Every engine call in this mod lives inside a
function for this reason; if a stamp is wanted early, put it in a function the
scripts list will call.

**`controlDown` is not a per-tick gate on platform collision. It starts a
fall-through state whose duration script cannot observe.** Measured with the
hold released after a single arming press: the unit still passed through TWO
platform surfaces before landing on a third. Six builds tried to control this by
timing — 0.5, 0.1, 0.034, release-at-the-plan's-floor, release-when-no-platform-
remains — and all six were tuning a release condition for a problem that was
never about the release. The fix is not to press down at all; see the movers
section.

Two mechanism models were tested against four measured drops and each explains
three of them. Neither is the answer. The behaviour is real, reproducible, and
still unexplained.

**`PathMover:move` goes blind for the whole of a drop hold.**

    if self.downHoldTimer ~= nil then
      self:keepDropping(dt)
      return "running"
    end

No `finder:update`, no `edgeMove`, no `mcontroller.controlParameters`. And
vanilla never reaches it for more than a tick, because `timedDrop` assigns the
undeclared global `holdTime` — always 0. Fixing that typo ENABLES a branch no
shipped Starbound has exercised. Worth knowing before trusting anything about
how it behaves.

**The entity script update rate is not reachable from either place it looks like
it should be.** `"scriptDelta"` in a monstertype's `baseParameters` had no
measurable effect: the pre-move sample interval stayed at 0.0820s median — 4.92
engine ticks — across three runs, with the repro drop bit-identical each time.
`primaryScriptDelta` is the status controller and unrelated.

`script.setUpdateDelta(1)` IS accepted in a monster context and logs cleanly
("dt now 0.0166667"), but the cadence does not change. It moves what
`script.updateDt()` REPORTS without moving when `update` is called, which is
strictly worse than doing nothing — every timer in the mod accumulates that dt,
so they all run at a fifth of real time while the world runs at full speed. A
short lap hides it. Backed out. If the update rate is ever worth chasing again,
find a VANILLA monstertype that changes it and copy the key and its placement;
do not infer either.

**Items use `itemTags`; objects use `colonyTags`.** Reading only `itemTags` is
why 133 subgroups of tenant tags matched nothing at all. Measured:

    floranchair     category "furniture"  colonyTags ["floran","floranvillage"]
    tier1switch     category "wire"       colonyTags ["wired","tier1"]
    frogfurnishing  category "other"      colonyTags ["outpost","commerce"]
    retroscifibed   category "furniture"  colonyTags ["retroscifi"]

Not one carries `itemTags`. `petports_itemFacts` now merges both into one set.
Objects also carry a `race` field, unused so far and available if a race-themed
object with no `colonyTags` ever needs to sort.

**Categories are camelCase, item tags are lowercase, and they are not copies of
each other.** From `commonassaultrifle.activeitem`:

    "category" : "assaultRifle"
    "itemTags" : ["weapon","ranged","assaultrifle"]

`subgroupMatches` compares with `==`, so a wrong name is a SILENT no-match.
Auditing the manifest against vanilla's `/items/categories.config` found four
dead entries: `cookingingredient` and `petcollar` mis-cased, `augment` and
`reagent` not categories at all.

**`category` survives the build script, so it is safe to sort weapons by.**
Checked on a generated weapon, a unique weapon and a generated gun: `rarestaff`
and `teslastaff` both report `staff`, `commonassaultrifle` reports
`assaultRifle`. This matters because `petports_itemFacts` reads the BASE config
— the same reason `root.itemHasTag` is a static lookup — so anything a builder
invents at runtime would be invisible. Category is not invented at runtime.

**A widget inside a list row cannot use a `scriptWidgetCallbacks` name.** The
engine throws at CONSTRUCTION, not at click:

    ListWidget::addItem -> ListWidget::constructWidget
      -> WidgetParser::constructImpl -> WidgetParser::buttonHandler
      -> WidgetParserException: Failed to find callback named: ruleRowAction

Those callbacks are registered on the parser that builds the PANE; `ListWidget`
constructs rows with a different one. `addListItem` throws and takes down
whatever called it. This is why vanilla's crafting list writes
`"callback" : "null"` — a name that parser does know.

**Row callbacks are registered at runtime instead, and it must happen before the
first `addListItem`.**

    widget.registerMemberCallback(listName, callbackName, luaFunction)

Added in 1.3, documented as registering a member callback for a ListWidget's
list items. It takes a Lua function directly, so the name appears in the
listTemplate and in the registration call, and deliberately NOT in
`scriptWidgetCallbacks`.

**A `local function` called from ABOVE its own definition is a nil global, and
it can hide for months.** `freshPather` was defined at line 1543 and called at
601. Locals are only in scope after their definition, so from above the name
resolves as a global, that global is nil, and the call throws:

    Exception while invoking lua function 'update'
    attempt to call a nil value (global 'freshPather')
      in upvalue 'tryVentRoute'

That kills `update()` outright — the unit stops running its state machine and
the port eventually re-homes it, which reads as a pathfinding failure and is
not one. It survived because `tryVentRoute` reaches that line on ONE branch.
Now forward-declared, with the definition changed to an assignment; writing
`local function` there again would declare a second local shadowing the first
and put the bug straight back.

**A whole-mod sweep for this shape found exactly one instance.** Worth re-running
after any large reorganisation: strip comments and strings, find every
`^local function NAME`, and look for `NAME(` before it.

**A `checkable` button inside a list row fires its member callback normally.**
That was the last open question about row widgets and the answer is yes — both
the rule rows' accept/deny icon and the subgroup grid's tiles work.

**`ListWidget::setSelected` invokes the list's callback itself.** So code that
calls `widget.setListSelected` and then calls the callback by hand runs it
twice. That was rebuilding the subgroup grid twice per click, and the grid is
explicitly not supposed to rebuild under a click at all — it survived on luck.
The fix was making the handler idempotent rather than deleting the manual call,
which would have left the pane depending on an engine callback firing.

**Python's `json` rejects what Starbound's parser accepts.** Vanilla puts raw
control characters inside strings freely — codex bodies are full of literal
newlines — and `json.loads` throws `Invalid control character` on them. The
first full asset scan silently dropped 111 of 123 `.codex` files, and the
symptom was *the codex category appearing not to exist* rather than a read
failure. `strict=False` fixes it. A parse setting that deletes a whole category
from a report is worse than a crash.

**A NAME SUFFIX IS A BLUNT INSTRUMENT AND VANILLA IS FULL OF NEAR-MISSES.**
Matching ores by names ending in `ore` also caught `signstore` and `neonstore`
(shop signs), `stationbackgroundcore` (station scenery) and three materials —
so shop signs sorted into the ore crate. `bar` likewise catches `saloonbar`.
Both are enumerated by name now. A missing entry sorts nothing, which is
recoverable; a bad suffix sorts the wrong thing and the player has to work out
why.

**VANILLA USES BOTH CASES FOR THE SAME CATEGORY.** `Tool` (33 items) and `tool`
(13). `Junk` (3) and `junk` (2). `Other` (1) and `other` (40). Claiming only the
lowercase silently lost every pickaxe, drill and the matter manipulator. There
is also `Upgrade Component` **with a space** — the display label of
`upgradeComponent` used as a category on ten ship unlocks — plus `Blueprint`
and `Drone`, neither in `categories.config`.

`categories.config` is a LABEL TABLE, not the set of legal categories. An item
can use a category with no label and it still sorts.

**A member callback is handed `(memberLeafName, widgetData)`.** Measured:

    ruleRowRemove fired with [1] string = rowRemove, [2] number = 1

Arg 1 is the LEAF name only — identical on every row in the list — so only arg 2
identifies a row, and every row widget needs `widget.setData`. A first version
resolved by suffix-matching arg 1 against known widget paths and appeared to
work; it only did because that test had one rule. `"rowRemove"` is a suffix of
every row's path, so with three rules the winner was whichever `pairs()` reached
first and the X would have deleted an arbitrary rule.

---

## Two diagnoses that were wrong, and what gave them away

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

## Design direction and architecture

Everything below was §7 of the Nicemice handoff.

The live project. Vanilla ship pets are widely disliked: they shadow the player,
swallow clicks meant for objects behind them, and park in front of the things you
need. The design goal is the opposite — small robotic units that find something
useful to do, inspired by Axiom Verge's ambient drones and Factorio's logistics
bots rather than by a squishy pet that wants attention.

### What this mod is actually FOR

Written down because every feature below reads differently once it is stated,
and because "automate farming" is a description of the mechanism rather than of
the point.

**Vanilla farming is barely a gameplay loop.** Place a seed, leave, come back
later, maybe it is ready. There is no decision in the middle and no skill in the
harvest. Most players meet it once, early, because they need cotton for armour,
and then never look at it again.

**And yet players build large farms anyway.** For the look of the place, or for
the satisfaction of having one, or for no articulated reason at all. The reason
does not matter; the fact does. Those farms are big, and the labour of working
them scales with their size while the interest of working them does not. That is
the actual problem: **effort scales, engagement does not.**

**So automating the harvest is not removing gameplay, it is replacing a loop
that was not one.** "Plant a seed and wait" becomes "you can scale this now, so
manage it properly". The player stops walking up to individual carrots and
starts making decisions about layout, storage, routing, fleet size and upkeep --
decisions that get MORE interesting as the farm grows, where the old loop got
more tedious.

**Upkeep is what keeps it a system rather than a switch.** A fleet consumes fuel
in proportion to its size, so scaling up is a commitment rather than a
one-off purchase. That is the load-bearing constraint under everything in the
investment path below: without it, acquiring pets is the end of the game rather
than the beginning of it.

**And it is an opportunity, not just a brake.** Vanilla has a long tail of items
it uses sparingly, once, or not at all. A fuel economy gives them somewhere to
go:

  - **Robotic units eat AA Batteries**, which come from Robot Hens -- and
    livestock harvesting is already built, so that loop closes with machinery
    that exists today rather than with something hypothetical.
  - **Biological units eat food**: seeds, or the produce the fleet already
    gathers. A farm that feeds the fleet that works it is a self-contained
    system the player assembled, which is a better thing to own than a fuel
    counter.

### The investment path — a pet is a project, not a purchase

PLANNED, NOT BUILT. Acquiring a unit should be the start of its development
rather than the end.

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

### Network control — the two things still missing at the top

Both were specified earlier and neither is built. Recorded here because they are
what makes a LARGE deployment governable, and everything above assumes large
deployments.

**1. Per-task participation, per network.** A petport on a non-default network
needs checkboxes for which tasks it takes part in -- automatic watering being
the obvious first one a player will want to switch off. Without this, joining a
network is all-or-nothing, and the only way to opt a port out of one behaviour
is to opt it out of everything.

**2. Filter beacons, in two families.** Filters apply IN ORDER, using the
container's own slot order as the syntax:

  - **Item filters** -- allow and deny lists over item descriptors, the original
    spec.
  - **Network filters** -- a PARALLEL beacon set governing which networks may
    interact with a container's contents at all.

The second is the one that makes shared bases work. Item filters answer "what
belongs in this crate"; network filters answer "whose crate is this". Those are
different questions and a player will eventually need both.

### Design direction — petports, fuel, and specialization

Design commitments that shape the behavior rewrite. None of this is built yet;
all of it constrains what gets built.

#### Terminology: petport, not pet station

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

#### Fuel, not food

Each unit type accepts a **category** of fuel and, within it, has a per-unit
**preference** that refills more efficiently.

A robotic drone might accept batteries, small batteries, copper wire, RAM sticks
and silicon boards, with a particular unit preferring copper wire. A
squirrel-themed unit accepts seeds broadly and favours one.

**Fuel comes from two places, and preference must never be a requirement.**
Communal feeders carry bulk sustenance; the port's own slots carry that unit's
preferred item. A hungry unit takes the nearest acceptable source, biased toward
preferred when the difference is worth the walk. An empty port slot costs
EFFICIENCY, never function — if a unit ever refuses feeder fuel because its slot
is empty, the per-port topping-up chore is back and the feeder has no purpose.

**This breaks vanilla's food handling and cannot be configured around.**
`groundPet.lua`'s `itemFoodLiking` returns false immediately for anything whose
`root.itemType` is not `"consumable"`. Copper wire and batteries are crafting
materials, so they are rejected before preference is ever consulted. The scoring
function must be replaced with one that checks category membership first and
preference second. Contained change — `eatAction` is its only consumer — but it
is a rewrite, not a parameter.

What survives from vanilla: `foodLikings` as a persisted per-unit map is the
right shape for preference, and the lazy-roll-then-cache pattern gives each unit
stable tastes for its lifetime without authoring them by hand.

#### The pet feeder

**Named a feeder, not a bowl.** A bowl implies kibble. These dispense batteries,
eyeballs, scorched cores, liquid lava — whatever a given monstertype's category
accepts. The rename is free right now for the same reason the petport rename was:
`objectName` is save-game identity and nothing has shipped.

**It reports fullness. That is the entire readout.**

An earlier design had it showing red / yellow / green for incompatible /
compatible / preferred, which forced feeder-to-unit exclusivity — preference is
per-unit, so a communal feeder showing green for one unit shows yellow for
another standing beside it. Binding a feeder to a port by wire was the proposed
fix.

That fix was in conflict with what the feeder is FOR: not making the player top
up every port individually. Requiring a wire per feeder reintroduces the same
per-port effort in a different form.

A later design had the feeder enumerate its network's units, read their
monstertypes' accepted categories, and warn when nothing on the network could
eat its contents. Scrapped as well — a feeder performing network-wide analysis
to justify one light is a lot of machinery for a readout that the petport panel
carries better anyway.

**Fuel information lives on the petport panel**, where the unit is unambiguous:
required food, preferred foods if any, and current level. Preference means more
fuel per unit of food; categorical accept/reject is per MONSTERTYPE and therefore
static and shared by every unit of that type.

**No wire nodes.** With binding gone they have no meaning.

**Feeders consume network identity; they never define it.** A port has a rect and
participates in union-find. A feeder has no rect and can only take the identity
of whatever coverage contains it, so feeders MUST stay out of the adjacency
computation — otherwise dropping one between two networks silently merges them,
invisibly, since a feeder draws no box to explain why.

Feeders may carry the same participate/ID widgets as ports, for players who want
to reserve one for a single network. Same UI, no effect on topology.

#### Any unit can always feed itself

**A feeder is a convenience, never the only way to eat.** If a unit can reach a
crate on its network holding something it accepts, it eats there. No carrying,
no capability check, no help request.

This is the rule that keeps the system from deadlocking, and it is worth
understanding why the obvious alternatives are worse. If eating required a
stocked feeder, then a network whose feeders ran dry could only recover by a unit
hauling fuel to one — which means a monstertype with no transport capability
starves in a network full of food. The two ways out of that were letting a
starving unit queue a "help me" task for another unit to claim (clunky, and
players will not understand what they are looking at) or giving every monstertype
transport capability it otherwise has no reason to have.

Neither is needed, because **fetching your own meal is eating with a longer walk,
not hauling.** The capability never has to exist.

**So the feeder's real job is being NEAR WHERE UNITS WORK.** Stocked feeder,
short trips. Empty feeder, long walk to storage. Restocking it in bulk is an
ordinary sorting-class task that a transport-capable unit claims when convenient,
and if nobody ever claims it, nothing starves — throughput just drops. That is
legible and self-correcting: the player notices units spending their time walking
and stocks the feeder.

**Refuelling is never gated on fuel.** A dry unit can always claim an eat task or
a haul-fuel-to-feeder task; it just cannot claim a drop, a harvest, or a sort.
Same "acquisition, not execution" rule as everywhere else, applied one level up.
Consequence worth stating plainly: a unit at zero is never STUCK, only ever
unproductive.

**Eating is a task, not a mode.** A hungry unit claims it, walks, plays the
emote, the crunch, the like/neutral/dislike particle, and rejoins the pool. Keep
hunger as a task PRIORITY: a unit that switches into seek-food wholesale walks
past claimable work to get there, which reads as broken. A mildly hungry unit
finishes the drop at its feet and eats after.

**A dry unit is routed AROUND, not blocked on.** Fuel is an availability flag
consulted at dispatch, not a gate on a queue. This is why "does a dry unit block
its port's queue?" has no answer: there is nothing to block.

#### Networked storage reading

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

#### Appetites as an inventory sink

Stated rationale, not a side effect.

Starbound accumulates crafting materials that never leave the inventory —
scorched cores, cryonic extracts, and the whole tail of ingredients with one
recipe and no consumer. Species-differentiated appetites consume them at a rate
proportional to how much automation the player is running, which is a real answer
to a real vanilla problem.

It also gives unit types a reason to differ that is not cosmetic: a drone that
eats batteries and a squirrel that eats seeds impose different supply chains, and
the player builds around that.

#### Fed means productive

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

#### Discovery: the petport panel

Preferences are rolled per unit, so they cannot be looked up externally or
carried between units. The petport's interact UI is the answer — the same panel
that holds the unit slot displays known preferences, current fuel level, task
capabilities and status.

This is the strongest argument for a bespoke interface config. The borrowed
`/interface/chests/pettether.config` is a placeholder and cannot carry any of
it.
The panel also holds **dedicated food slots** for that unit's preferred fuel.
This is where per-unit feeding lives, alongside the communal feeders — see "The
pet feeder" above. The panel is also where required and preferred foods are
displayed, since the unit is unambiguous here and nowhere else.

#### Locomotion classes

Three intended, in order:

- **Ground** — what is being built now. `groundPet.lua` and its action states
  assume it throughout: `approachPoint` resolves through `findGroundPosition`,
  `move()` gates on `validStandingPosition`, `sleepAction` teleports onto a
  ground target.
- **Flyer** — deferred until ground units work. Requires `gravityEnabled: false`
  plus a replaced movement layer; flipping the config alone leaves ground-based
  pathing running against a unit that never touches ground.
- **Aquatic** — flyers constrained to fluid volumes. Same movement layer as
  flyers with a containment check.

The unit's art is now its own and it is a ground unit drawn as one, so the old
warning about flying placeholder sprites is retired. The constraint that
survives is the code one below.

`petports_placement.lua` is ground-specific in its position-finding
(`validStandingPosition`, `findGroundPosition` offsets). Its occupancy logic and
allow-list survive a flying unit unchanged; the candidate-position search does
not, and will need a hover-point and perch concept.

#### Vents are infrastructure, not a workaround

Vents stay regardless of locomotion. The original justification — a ground unit
cannot climb ladders — undersells them. They are how units enter and leave
player-built spaces without disturbing door and hatch systems, on ships and in
colony ductwork alike, and they work as cosmetic infrastructure too (a vent lets
bees in and out of a player-built hive). Fast travel is a side benefit, not the
reason they exist.

#### Proliferation is intended

Nothing limits how many petports a player deploys, by design. Full automation
coverage requires several unit types, which is the point: it drives exploration
and questing to acquire unit items that make a permanent base more convenient.

This makes pets a payoff loop for the settlement and encounter work rather than
a self-contained ship feature, and it is the reason the "Low" priority the
roadmap assigns ship pets understates them.

#### Specialization falls out of the asset layer

A task set is a monstertype, a monstertype owns its own `categories` string, and
that string binds its own pool of `.monsterpart` chassis variants. So a unit's
job and its appearance are coupled for free — a sorter cannot accidentally wear
a medic's body, because they draw from different pools. Worth preserving
deliberately: visual legibility is what lets a player glance at a deck and know
which unit is which.

The petport itself stays generic. The unit item carries the type; the port just
holds one.

#### The split, and why it happened when it did

This began inside Nicemice and was separated out on 2025-08-19, the same day the
spawn pipeline first worked end to end. The timing was the whole point:
`objectName`, a monstertype's `type`, `itemName` and a monsterpart `category`
are all save-game identity, and once players have them in worlds they cannot be
renamed without breaking those worlds. Nothing had shipped, so the rename was
free. A week later it would not have been.

The intended relationship is mechanism free, content exclusive. This mod ships
the machinery and an empty ecosystem; Nicemice fills it with unit types, chassis
variants and the encounter/quest loop that unit items drop from. That keeps
reach and exclusivity from fighting each other.

The coupling was shallow enough to make this cheap — nothing in the pet system
ever reached into Nicemice NPC, dialog, ship or species code. The dependency ran
one way. What remains is listed under "Open decoupling work" at the top.

#### Engine constraint: work only happens where a player is

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

#### Coverage rects — the roboport model

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

#### Networks — geography first, ID second

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

#### The residency owner is a stagehand

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

#### Discovery belongs to the port, not the pet

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

#### Work claims

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

Serial numbers for flavour ("unit #4142") derive from `seed`, NOT from a
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

#### Exit paths — three, and they mean different things

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

#### Wiring conventions

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

#### The first two tasks, in order

**A throwaway diagnostic task first.** "Go to this point in the rect, stand
there N seconds, release." No dependencies, deleted afterward. Its purpose is to
isolate the infrastructure from any task's own complications: does the port
discover work inside its rect and refuse it outside, does a claim get taken and
released, does a claim expire when the unit dies mid-task, does work run while
the player is at the far end of the planet, does any of it survive a reload.
Every one of those is currently unanswered, and pairing them with an unproven
item API means debugging two unknowns at once.

DONE, 2025-08-20. It answered every question it was built to ask, and the shape
it proved is the shape the real tasks inherit: claim, path, arrive, act,
release. Only "act" differs.

RETAINED rather than deleted, behind `DIAG_FALLBACK` in the petport (default
off). It exercises dispatch and residency with an empty rect, which is useful
whenever something structural changes and no items are involved.

**Then item drop collection.** See Task 3 below for why it is first among the
real tasks.

**Log every dispatch rejection with a reason.** Out of rect, already claimed,
claim expired, no unit available, unit has no fuel. These failures are all
silent-nil shaped — a unit that does not move looks identical whether the port
never discovered the work, discovered and rejected it, or dispatched it to a pet
that could not path. A reason string collapses that to one line of log and costs
nothing to strip later.

#### Task 1 — sorting

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

#### Task 2 — farming, and crops come in two kinds

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

##### What the tiles actually say

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

##### Replant intents

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

##### The harvest pool, and why the field probably feeds itself

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

##### Aquatic crops collide with locomotion

Some seeds require SUBMERSION, and submerged bases are common because a lot of
players run aquatic species characters. A ground unit cannot service a
submerged farm: locomotion is ground-only, the aquatic class is third in line
behind flyers, and liquid status effects apply from 10% submersion — see "Units
are destructible", where that setting is what kills a unit in lava.

So underwater farming is gated on the aquatic locomotion class. Say it out loud
rather than letting a player discover it as "my farm is being ignored".

##### Modded soils -- SUPERSEDED, see "Modded soil support, mostly arrived early"

Kept because the reasoning was right and the scope call was wrong in a way worth
seeing. What was recorded: modded dirt can declare its own tilled matmods, so
the 31/32 pair is a vanilla fact rather than a universal one; **Alta / Enternia**
is the name attached, popular and full of alien crops wanting specific dirt; and
reading `tillableMod` off the material config instead of hardcoding 32 costs
nothing.

All true. But it was filed as deferred work, and watering delivered most of it
by accident -- because reading the matmod at runtime, which was done for
correctness rather than for compatibility, IS the compatibility. Watering and
replanting both handle modded soils today. Only tilling would need
`tillableMod`, and the mod does not till.

**The general lesson is the one worth keeping:** reading the data instead of
learning the vocabulary tends to deliver mod compatibility as a side effect,
and is often no more expensive at the time.

##### What a farmable declares, and what it does not

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

##### Harvesting is TILE DAMAGE, not an interaction

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

##### The v1 lifecycle, deliberately small

**BUILT AND VERIFIED IN GAME.** One full cycle, timestamped from a single log:

    19:01:15  a crop appears in the scan            stage 0 of 3, harvestAt 2
    19:01:35  it grows                              stage 1 of 3
    19:01:48  a port finds it RIPE and dispatches   claim harvest:142 taken
    19:01:52  the unit arrives and swings           crop at [1203,715]
    19:01:52  the crop is consumed, two drops land
    19:01:52  the same port dispatches collection   drop 169, 1.06 tiles away

Four ports shared the network and the other three skipped the crop on the claim
without a word of coordination between them, which is the registry and the claim
layer doing exactly what they were built for.

**THE PICK-TIME RIPENESS RE-READ IS WHY THIS WORKED AT ALL.** The crop ripened
at roughly 19:01:48, between the 19:01:35 scan that saw stage 1 and the 19:01:51
scan that would have seen stage 2. The cached scan said unripe; the re-read at
selection said ripe, and the harvest went out three seconds earlier than the
cache alone would have allowed. It was added to stop a stale cache sending a
unit at a crop it had just reset — it also turns out to be what makes the port
responsive between sweeps.

**STILL UNTESTED: the crop that SURVIVES harvest.** The verified run used a
three-stage crop with no `resetToStage`, so only the destroyed path has actually
run. The reset path — corn — takes a different route through the verification
(a stage that moves rather than an entity that vanishes) and has never executed.

**V1 IS HARVEST AND NOTHING ELSE. The seed walks back to storage like any other
drop**, and replanting it is a later increment for another unit to pick up.

##### Replanting -- BUILT AND VERIFIED

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

##### Watering -- BUILT AND VERIFIED

**The whole farming cycle now runs with no sprinkler infrastructure.** Crops
will not grow on dry tilled soil at all -- confirmed in game, it is not merely
slower -- so watering was the last piece standing between the mod and
hands-off farming. That is the Blue Ocean claim for this feature, and it is
stronger than "we automate farming", because sprinklers are what every other
answer looks like.

##### The soil describes itself, so `farming.config` is barely needed

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

##### The act is a projectile, and the projectile is a blank

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

##### Three off-by-ones, all in the geometry

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

##### The sweep is the first multi-stop task

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

##### Swamp water, and why the patch needed no code

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

##### Modded soil support, mostly arrived early

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

##### One behaviour change to watch, from the same pass

`replantGroundTilled` used to accept a tilled mod at the anchor tile OR the one
below, hedging an unverified assumption about where `world.entityPosition` sits
for an object. Watering settled it -- `waterRuns` derives the soil tile the same
way, `floor(cropPosition) - 1`, and wets exactly the right tiles -- so the check
is now `y - 1` only.

Strictly better: a crop whose anchor tile happens to be farmland can no longer
mask missing soil beneath it. But it is a change on a path that was working, so
**if replanting ever starts clearing intents as "not farmland", this is the
first suspect.** The log prints both mods and the `tilled` flag.

##### Animal harvesting -- BUILT

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

##### THE PROBE THAT KILLED LIVESTOCK

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

##### Animals move, and nothing chases them

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

#### Task 3 — collecting item drops

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

#### Vent preference

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

#### Combat is out of scope

Healing and other combat-adjacent tasks are dropped. Nicemice NPC medics already
cover player healing for anyone playing the species, and keeping units clear of
combat preserves the line between utility pets and capture-pod monsters.

This is already reflected in the drone's config — `ghostly` damage team, zero
touch damage — and it simplifies the behavior rewrite considerably, since a unit
that never fights never needs targeting.

### Units are destructible, and that is a departure

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

### The behavior layer is a fork, not a patch

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

### The registry: how ports find each other

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

### Union dispatch and the leash

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

### Vent routing

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

### Pathing is vanilla's, with corrections and two replaced movers

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

**`smallJumpMultiplier` is 1.0 and should stay.** It tells A* it may plan hops at
a fraction of full strength, but the actor CANNOT perform a partial jump --
`default_actor_movement.config` sets `jumpInitialPercentage` 1.0 and
`jumpHoldTime` 0.0 and the drone overrides neither, so every jump fires at full
strength. At 0.75 the planner drew arcs for a 33.75 jump the unit answered with a
45 one.

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

### Why not the vanilla pipeline

`/scripts/companions/petspawner.lua` exists to serve CAPTURE PODS, and nearly all
of its complexity is pod-shaped: pods holding several pets at once (a hemogoblin
splits when it dies), collar merging, associate/disassociate handlers, and a JSON
round-trip that keeps a pod item in sync so a pet can be carried between worlds.

None of that applies to a dedicated item. One item is one pet, there are no
collars, and the definition lives in the item's own parameters. Worth keeping
from that file is only the spine: assembling spawn parameters with
`initialStatus` / `initialStorage` (how a pet keeps learned state across a
respawn), a status heartbeat, and collision-aware spawn placement.

### The item IS the pet

`petports_unit_test.item` carries a `petData` block — `monsterType`, display
fields, and the `status` / `storage` the station writes back as the pet lives. A
found item ships with just the monster type; the rest accumulates.

This also enforces the ship-pet/wild-monster boundary **structurally**. Wild
monsters and ship pets use entirely different script stacks and are visually
magnitudes apart, and that separation must hold. A wild monster has no
`petports_unit` item, so it can never be socketed — no runtime type check
needed.

### The petport implements vanilla's anchor contract

`groundPet.lua`'s `findAnchor` calls `status.setResource("health", 0)` — it KILLS
the pet — if it cannot find an anchor object within 5 tiles of its last anchor
position. So `petports_petport.lua` implements the same `hasPet` / `setPet`
contract `techstation.lua` does, and the monstertype's `anchorName` points at it.

**`anchorName` must match the station's `objectName` exactly.** Rename the object
and pets die on the next load.

This is deliberate scaffolding: it lets vanilla's pet scripts run unmodified
while the behavior work happens separately.

### Vents: wires as links, not signals

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

### Placement validation — occupancy, not interactivity

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

### Design decisions already made

- **Follow is the LOWEST priority action, and should be a floor rather than a
  score.** Any constant will occasionally beat a real task. Cleaner: follow only
  enters when nothing else claimed the tick.
- **Interact is a pat, not a dismissal.** "Get out of my way" as the primary
  interaction would be a bandaid on the wrong pillar. Combine affection with a
  politeness window: emote, then keep a wider distance from that player and do
  not pick a resting spot near them for N seconds.
- **Tasks come from objects, not appetites.** `petBehavior.scoreAction` is an
  appetite model — every score is a resource level (hunger, curiosity, playful,
  sleepy). Factorio bots are the inverse: work exists independently and bots
  claim it. The seam already exists: `querySurroundings` sweeps objects and hands
  each to `reactToObject`, which currently only checks for `pethouse`. Objects
  can advertise work there via a scripted call, queued through the existing
  `queueAction`, with appetite scores as the fallback layer beneath.
- **Ambient traversal is nearly free characterisation.** A pet with no task that
  picks a vent and travels LOOKS purposeful. That buys most of the Axiom Verge
  feeling before a single real task exists.

### Vanilla tuning notes

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

## Cargo, beacons and deposit

### The unit carries, the port owns

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

### Beacons: a container declares its own purpose

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

### Filter beacons -- slot order is the syntax

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

### The active provider beacon

SPECIFIED, NOT BUILT. Factorio's active provider chest, stated in this system's
terms: **anything in this container that is not a beacon needs to be somewhere
else.** A unit collects from it and ferries the contents to the network's
deposit targets until it is empty.

It is the natural inverse of deposit and needs no machinery beyond a behaviour
string. The crate is discovered by the same scan, and the resulting work is an
ordinary collect-then-deposit with a container as the source instead of the
ground -- which also means the source needs claiming the same way a drop does,
or two units empty the same crate.

Its interaction with filters is where the design has to be careful: an active
provider that is ALSO filtered means "push out everything except these", which
is a reasonable thing to want and is the same chain read with a different first
beacon.

### Beacons need an off switch

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

### Deposit

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

### Fragmentation is the player's problem, and that is the design

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

### Tidying and auto-disperse — built

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

### Restock beacons — BUILT, and the design that survived contact

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

### Stack compaction — built

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

### The filter vocabulary is measured, not guessed

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

### Five matchers, and what each one is for

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

### `unclassified`, and the two designs that failed first

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

### THE MANIFEST IS KEYED BY ID, NOT AN ARRAY

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

### Order is stated in one table, and a literal has broken three times

Group order lives in an `ORDER` dict in the generator, in HUNDREDS. Tens ran out:
the `Furniture - Tagged` block needs forty consecutive numbers.

`PINNED` renders a group as `parent + 1` rather than as a literal, because a
literal has broken three times now — Filled Capture Pods was 81 when Pets was 80
and silently moved ABOVE Pets when a group was inserted earlier; `Unsorted` was
290 until forty tagged groups grew into it; and the same shape is what made
positional patch paths untenable. **A number that encodes a relationship has to
be computed.**

### The taxonomy: what an item IS versus what it looks like

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

### What is written down for modders

`workbench/SORTING_FOR_MODDERS.md`. Part 1 is the minimum — three fields, the
casing trap, and the fact that following vanilla conventions needs no
cooperation from us. Part 2 covers patching, all five matchers, `unclassified`,
and why exclusion storage means a subgroup you add is inside every existing rule
immediately.

### The audit that started it

The manifest now covers all 98 vanilla categories with none invalid, up from 26
covered with 4 dead. Weapons lead with categories and keep their tags as a
secondary net for modded weapons that set `itemTags` but pick a nonstandard
category. Codexes are their own group rather than a subgroup, because a player
who wants a library wants ONLY codexes and a subgroup cannot express that
without excluding everything around it.

133 tenant-tag subgroups were transcribed from the wiki's Tag page into seven
groups: species, decor themes, object themes, biome themes, locations, crafting
tiers, holidays. Seven of those tags are verified against real object files;
the other 126 are transcription and are marked UNVERIFIED in the manifest.

**Modded species add themselves.** A race mod patches one entry into the species
group's subgroups and its furniture sorts everywhere immediately. That is the
whole reason subgroups are stored as EXCLUSIONS — a beacon already set to
"Species Themed" picks the new race up without being reconfigured.

**Button scope, for the UI work.** 19 groups, 177 subgroups, and the
distribution is lopsided: Biome Themed 37, Object Themes 27, Location Themed 25,
Decor Themes 21, and everything else 11 or fewer. Four groups carry 110 of the
177. The group picker at 19 rows is fine; a 37-row subgroup scroll is not, which
is what the tile grid exists to fix.

---

## Presentation and readout -- specified, unbuilt

None of this is machinery. All of it is how a player finds out what the
machinery is doing, which is the difference between a system that reads as
clever and one that reads as broken.

### The carried-item indicator

A unit carrying something should say so: a small bubble above its head showing
the ITEM ICON of what it holds. The same slot generalises to a TASK icon --
sleeping, wandering, farming, depositing -- which is the cheapest available
answer to "why is that one just standing there".

**It is opt-in per unit, toggled on the petport panel.** A base running a dozen
units with permanent bubbles overhead is visual clutter, and clutter is the
exact vanilla ship-pet failure this mod exists to avoid. Default it off and let
a player turn it on for the unit they are currently wondering about.

This is a second consumer of the petport panel, which does not exist yet.

### The item tooltip is stale

Hovering a unit item in the inventory should describe the unit: what it is
carrying, its fuel level, its serial. It currently says nothing of the sort.
Cargo is already on `petData` on the item, so the data is sitting there and the
tooltip simply does not read it.

Late-project work. It is polish, it will read as unfinished right up until it is
done, and it should follow the systems it describes rather than chase them.

### The drone is always running

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

### The petport door is decoration and should be choreography

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

### Units should sleep in their ports

Vanilla's pet house hides a sleeping pet inside itself, and the mechanism is not
understood -- probably an invisibility flag, possibly a position pin, plausibly
both. Read it before designing anything, because whatever it does is the shape
to copy. `petportsSleepAction` already exists and already gates on
`petports_allowSleep`, so the hook is in place and only the destination is
missing.

---

## Level design constraints

Not bugs. Facts about what vanilla's pathing can and cannot do, established by
measurement, that anyone building for these units needs before they build.

### Horizontal jumps need body width plus about a tile

A jump with any horizontal component sweeps the unit's box along a diagonal, and
the swept volume is wider than the box. The planner's arc collision samples
discrete points along the trajectory rather than sweeping a volume, so a corner
clipped BETWEEN samples is invisible to it -- the same defect that put its own
waypoints through a ceiling.

Measured with a 1.75-wide body: a 2-tile chute with 2-tile tunnels at each end
could not be jumped into. It wanted **3 tiles**. That is body width plus roughly a
tile of sweep.

**Two-tile chutes are walk-only.**

### Vertical jumps only need body width plus margin

`jumpVel [0,45]` sweeps nothing sideways, so the volume is just the box going
straight up and 2 tiles of width is genuinely enough. The same tight turn that
failed as a horizontal jump worked as a vertical one with a platform directly
overhead.

### Landings forgive, entries do not

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

### Ladders are not traversable

There is no Climb edge. A floor reachable only by ladder is unreachable. Platforms
ARE traversable and validStandingPosition counts them as ground, which is why a
platform column looks like a ladder and works where a ladder does not.

---

## The movers are replaced, and why

`PathMover` assumes an actor that arrives on its waypoints and has no recovery
when it does not. Four dead ends were measured, all the same shape: unit
grounded, on an airborne edge, mover issuing no input and never advancing.

Overrides are assigned to the pather INSTANCE in `freshPather`
(`self.pather.moveJump = ...`), so they shadow the class through the metatable
for that pather only. Vanilla stays reachable, nothing is patched globally, no
other entity is affected. Same technique as the `exploreRate` override.

**WATCH THE PARAMETER NAME.** `edgeMove` calls these as `self:moveJump()`, so the
pather arrives as the first argument -- but inside our files `self` is the
monster's script table, a different thing entirely. pathing.lua flags the same
collision above `setMoved`.

`PathMover:move` rebuilds `controlParameters` BEFORE `edgeMove` and applies it
AFTER, so a mover override can clamp speed and have it take effect that tick.

### petportsJumpMover

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

### petportsWalkMover

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

### Homeward targets bias downward

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

### The router and the walker must aim at the same point

approachPoint resolves a raw target to standable ground internally, so
`tryVentRoute` was being handed the RAW one while the walk used the resolved one.
Invisible on flat floor. On a slope: a drop at [1224.71,718.789] resolved to
[1224.5,718.875], the direct A* searched toward the resolved point happily, and
every vent probe ran toward the raw one and was refused as "not a valid standing
position" -- planRoute EXHAUSTED, task failed, unit never moved, drop reachable
the whole time. Now resolved once as `routeTarget` near the top of update and used
by both call sites, so a third caller cannot reintroduce the split.

### Cache entries expire, asymmetrically

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

### The leash: three bugs, and only one of them was the symptom

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

### Dropping through a platform is a PLACEMENT, not a control press

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

## Known problems — probably later

Real, characterised, deliberately not fixed. Each has been seen in a log.

**RESOLVED items are kept here rather than deleted**, marked as such: recall
vent-routing, over-dropping, and the `local function` scoping trap all sit
below. They stay because each one records a wrong hypothesis that was held
confidently for a while, and deleting the resolution loses the reasoning that
made the fix correct -- which is exactly what an inherited handoff is for. A
future session reading "over-dropping" should find out immediately that it is
not a hold-time problem, rather than rediscovering that over two sessions.

### moveLand is still vanilla's, and it is four lines

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

**Confirm it still reproduces before rewriting it.** Every one of those triggered
downstream of a jump that missed its arc, and the takeoff gate, launch-velocity
and walk-slowdown fixes have removed that cause. Grep a fresh log for a Land edge
where the unit is grounded and `srcDist` stays above 1; if absent, leave it.

Shape of the fix if needed: accept on distance in BOTH axes; walk toward the
target when grounded but short; and when landed far off in y, do NOT advance --
that is a broken path and should surface as one.

### Recalls vent-route now, and the refusal that stopped them

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

### The unexplained stall, and why it stopped happening

NOT SOLVED. NO LONGER REPRODUCIBLE. Recorded because the difference matters.

Symptom: a unit stationary for 70+ seconds, `moved 0.0032959` identical every
tick, while these two lines alternated twice a second:

    approach at [1195.07,715.8] ... hasPath false aStar true
    path found after 0.416667 seconds of searching

A path found, and gone again by the next tick. Not a slow search -- something
finding an answer and discarding it. `APPROACH_TIMEOUT` is 20s and the retry
line did not appear once in a 27-second window, which should not be possible
unless `approachTimer` was being reset every tick.

**It stopped reproducing after recalls were allowed to vent-route, and the
honest reading is that its PRECONDITION went away rather than its cause.** Every
capture was a unit that could not get home. That state no longer arises.

Two instruments were left in for it, unconditional:

  - `freshPather` logs every rebuild with a counter and a caller-supplied
    reason. A pather rebuilt once and one rebuilt sixty times a second look
    identical in every other line.
  - "path found" reports edge count and first action. A path with zero edges
    satisfies `hasPath` and moves nobody, and reads exactly like a healthy one.

Leave them until something else needs the noise budget.

### Over-dropping was never about the hold time -- RESOLVED

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

### The two vanilla drop faults underneath it, both still fixed


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

### Four ways to build a silent stall, all of them mine

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

### A `local function` called from above its definition is a nil GLOBAL

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

### moveDrop's hold time is dead code, and the bug is a typo

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

### Two vent entry sites, only one hardened

`petportsTaskAction` calls `petports_ventTravel` from two places -- "already
touching" and "walked to it via approachPoint". The fail-closed hardening went on
the FIRST only. The second, which is the ORDINARY case, still does
`local ok = pcall(...)`, discards the arrival position, does not blacklist a
refusing vent, does not verify the landing against the plan, and does not count
the hop against `MAX_REPEAT_HOPS`. Both are labelled in the log
(`[ENTRY SITE A]` / `[ENTRY SITE B]`).

### Probing is the wrong architecture

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

### Multi-port deferral is arbitration by straight-line distance

`anotherUnitIsCloser` picks a winner by straight-line distance, which the comment
concedes is routinely wrong in a player's base. `DEFER_GRACE` exists to undo it
after 12 seconds, `deferredSince` tracks the grace, and a four-way tally exists to
diagnose it. Observed 21 of 22 drops deferred while the other port was already
busy. Claims already arbitrate correctly and cannot deadlock. Deleting deferral
removes `anotherUnitIsCloser`, `DEFER_GRACE`, `deferredSince`, `entry.hasUnit`,
`publishUnitPosition`, `UNIT_POSITION_THRESHOLD`, and two of the four counters.

### Three overlapping recovery ladders

`RECALL_LIMIT` -> `STRANDED_LIMIT` -> `rehomeUnit`, on top of `TASK_DEADLINE` and
a four-tier `FAILURE_BACKOFF`. rehomeUnit is instant, free and always works.
Worse, `noteFailure` classifies strandedness by SUBSTRING-MATCHING the failure
reason text -- a structured outcome field costs nothing and cannot silently stop
matching when someone rewords a log line.

### Smaller ones

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
- Coverage is 64 now. **Area is what costs, so 32 -> 64 is 4x**, and `gatherVents`
  inflates by a further COVERAGE_SIZE per side -- 96x96 to 192x192. An existing
  residency stagehand keeps the size it was born with until its port respawns it,
  so re-place ports after changing it or work scanning and residency will
  disagree.

---

## Where this goes next

**Two small open items on the restock beacon.**

An `itemslot` inside the request list's `listTemplate`, to show each request's
icon. UNVERIFIED whether one can be constructed there, and the failure shape is
`addListItem` throwing at construction — the pane does not open at all. Worth
trying STANDALONE rather than bundled with anything, so a failed experiment costs
one file revert instead of blocking a feature. It is one widget in the template
plus one `widget.setItemSlotItem(path .. ".rowIcon", { name = ..., count = 1 })`
in `refreshRequests`.

Making the player SAY the hotbar-only refusal instead of opening a notice pane.
`entity.say` belongs to monsters and NPCs; an activeitem has no `player` table at
all, and no channel reachable from a ScriptPane has been verified. The notice
pane is species-keyed via `player.species()` against `hotbarOnlyMessage` and
works, so this is polish.

**A TRASH CAN is the next feature-sized piece of work, and it is designed only.**
Restock beacons are built; see the section under Cargo, beacons and deposit.

The shape, and the reasoning that has to survive into the implementation:

**A beacon, not a self-voiding object.** Nobody drops a beacon into a chest for
looks, so the aesthetic footgun — someone placing a nice-looking bin and losing
their arsenal to it — cannot happen. Ship the pretty object as an ordinary
container if one is wanted; it becomes a void only when a trash beacon is put in
it. That is the mod's standing rule: a container declares its own purpose by its
contents.

**ABSENCE MUST MEAN DENY, and everything else rests on that.**
`petports_filterAccepts` returns true for a nil filter, deliberately, because a
blank DEPOSIT beacon has to behave like the unconditional one that shipped before
filters. Inherit that and a fresh trash beacon eats anything homeless the moment
it is dropped in. The trash predicate must be
`filter ~= nil and petports_filterAccepts(filter, name)` — a blank trash beacon
is INERT until the player names what may be destroyed.

**"Nothing wants it" is not "nowhere has room", and conflating them is the
catastrophic bug.** Full storage is routine and transient; deleting a load
because every crate happened to be full is unrecoverable.
`petports_filterAcceptsNothing` already draws exactly that line for the
loaded-unit case. Trash may only ever be offered an item no deposit beacon's
filter ACCEPTS — a permanent condition needing the player, never one that clears
itself in a minute.

**Two hard-no cases regardless of the filter.** Petports beacons themselves:
`petports_filterMisfits` exempts only the DECIDING beacon's slot, so a spare
configured beacon is ordinary cargo today and a trash can would delete someone's
filter setup. And anything under an active restock quota, since a request is a
claim and destroying what another crate asked for is two systems disagreeing.

**Worth considering: destroy on OVERFLOW, not on arrival.** Let the trash crate
fill normally and void only what will not fit. The void becomes the overflow
rather than the box, so a mis-configured trash can presents as a chest full of
your arsenal before any of it is gone. It does not cover a thousand-item load
pushing earlier contents out, so it is mitigation rather than a guarantee — but
it turns a silent unrecoverable mistake into a visible one.

**Ordering:** below `depositWork`, strictly last resort, and NEVER in
`petports_beaconsFor("deposit")` or the nearest-first loop could pick the void
ahead of a real crate.

**Two scan passes are specified and not built.** Hunting weapons are not
identifiable from any field the manifest can reach — whether a weapon yields
meat rather than shredding the drop is a property of the DAMAGE TYPE on the
projectile it fires. Finding them means scanning `.projectile` for that damage
type, walking back to the weapons that fire them, and listing those by name.
Separately, natural biome formations do not carry their biome's colonyTag the
way crafted furniture does — the geode rocks are listed by hand and the same gap
exists for every other biome. Both want the tag dumper extended rather than new
machinery.

**Superseded, ignore below this line if it contradicts the above.** Verify the 126 unverified tenant tags — a tier-2
workbench settles all ten tiers at once, one Frögg Furnishing purchase settles
the 21-tick decor group, one biome object settles the 37-tick one. Confirm a
`checkable` row button fires its member callback; only `ruleRowRemove` has been
seen firing, and if checkables are inert the subgroup tiles are too. Fold
`race` into `petports_itemFacts` alongside `colonyTags` once tag matching is
confirmed.

**The pane wants the collections treatment.** `columns` + `fillDown` +
`createTooltip` with `widget.inMember` is the whole recipe for an icon grid, and
`radioGroup` with per-button `data` suits 19 groups better than a scrolling
list. Note that anything per-row — reorder arrows, per-rule enable — has to live
outside the list and act on the selection, unless it can be expressed as a
member callback.

**Still open on movement.** `moveLand` is untouched vanilla and is four lines
with no `else`. The arc-skip predicate leaves the unit grounded on an Arc edge
at the port, recovering only when the stall detector fires 0.35s later. The
planner over-estimates jump height by about 7%. All three want their own
session and none of them block content work.


**Pets get a break.** Farming, animal harvesting and item collection all work,
and most of the pathing quirks are solved or sidestepped. The unit layer is in
good enough shape to leave alone for a while.

**The beacons system is next.** It is the natural follow-on for three reasons:
it is entirely unbuilt where the unit layer is mature, it is what the network
control section above is blocked on, and it is the piece that turns a working
fleet into a governable one. Filter beacons, the active provider beacon, beacon
on/off state and the network-filter family all live there.

The module and slot work above depends on the petport panel, which is a larger
and separate undertaking -- worth keeping behind beacons rather than starting
both at once.

## Logging discipline, learned the hard way

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

## Process note

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
  a single edge.**
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
