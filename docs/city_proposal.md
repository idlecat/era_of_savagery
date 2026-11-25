# Proposal: From Tribe to Ancient City (1000 people)

Status: steps 1–6 largely built (2026-11-24; `ROADMAP.md` §5 records what landed, what
was found on the way and what is left); the plan (`ROADMAP.md` §3 sets its order with
the open make_it_fun items folded in). Written after a code and data audit plus headless
measurement runs (2026-11-24). The goal: a player can develop the settlement into one
or more thriving ancient cities of about a thousand people, with challenges that grow
with the city and a good pace on the way. Code references were checked at 5e53363;
main has since gained the era-3 **Stone Wall** and **Trading Post** (0956e11) and
**careers** (`careers.gd`, `config/careers.json`), which this doc now builds on.

## 1. Where the game stands today

### 1.1 A measured 60-day autopilot game

`tools/metrics.gd`-style run (steward policy, `the_ford`, seed 1, challenges normal),
per day:

```
day  pop  pop_cap  food  wood   huts farms docks settlements
 1    11     12      45     35     4    0     0      1
20    28     48      80   1390    16    2     0      7
31    40     62      14   3704    18    2     0      8
47    46     98     170   3267    24    2     0     12
60    47    104      93   6059    32    2     0     16
```

- Population plateaus at **45–60**. The stock metrics run of the same seed ends at 62.
- **Wood piles up to 6000 and is never used**: labour is not the limit, **food is**.
  "Food is running low" is raised almost every day.
- **16 outposts for 47 people** (2 huts and a bonfire each), almost all empty.
- Deaths come in spikes: one run lost 24 of 41 people across a winter day (hunger,
  a sickness wave and a 7-warrior raid stacking), another lost 2.

### 1.2 Sim cost by population (headless, idle people, `life` off, `the_ford`)

| pop | ms / tick | CPU per game-second at 1x (20 ticks/s) |
|----:|----------:|----------------------------------------:|
|   50 |      3.0  |  6 % |
|  200 |      8.7  | 17 % |
|  500 |     19.6  | 39 % |
| 1000 |     37.5  | **75 %** |

Linear, no cliff, but 1000 *working* people, a few hundred buildings (§3.1's design;
the plot carpet would make it ~600) and 1000 sprites on screen will sit at the edge
of 1x, and the 2x/4x speed keys will be unusable, which a long game needs. The cost
is real well before 1000: 19.6 ms at 500 is measured with `life` off and everyone
idle, and `hz._sickness` is O(n²) — the §3.5 work is due by ~400–500 people, and
with a person = a unit (open question 1) it is required work, not an option.

### 1.3 Nothing in the game is a city

- `docs/make_it_fun.md` I5 ("camp → village → town by what's been built") is not
  implemented; there is no town or city concept in any script or config.
- `config/legacy.json` has conquest, unity and wisdom; no population or city path.
- Era-2 buildings exist since a52e346/18fe442: **Longhouse** (8 beds, `hearth_bond`),
  **Temple**, **Smokehouse** (`spoil × 0.6`), **Lookout Tower**, and the palisade ring.
  The Steward barely uses them: the smokehouse is `improvements.list`'s *first* entry
  (autumn only), the Longhouse and Temple are `rules.json → buildings.upgrades` rows
  (large_hut → longhouse, totem_shrine → temple) the list never includes — it stops at
  hut → large hut — and the Lookout Tower is never laid out at all. And
  `structures.json → aliases` still maps `"longhouse"` to `large_hut` (an LLM contract
  asking for a longhouse gets a large hut; a bug to fix in step 1).
- Era 3 adds the **Stone Wall** (a ring, `inside_def` 6, only quakes harm it) and the
  **Trading Post** (`trade_every × 0.65`, `trade_rate × 1.25`): the city tier's
  "walls" and the trade share of §3.1 have their buildings already.
- **Careers** exist: families come to live by one trade (`u.calling` grows from what
  the hands do; holders `self_work()` at it when idle and the Steward leaves them
  to it). There is no farmer career yet, and specialist `max` values are small
  fixed numbers (builder 3, warrior 4) — sized for a band, not a city. And
  `careers.in_words()` — every holder, name → trade — now feeds `evo.world_ctx()`
  (`trades_people_live_by`): the LLM context this doc's open question 1 called
  people-free no longer is; it needs the same cap as `treasures`.
- Missing for a city: bulk storage (warehouse), a well/water, anything that ties
  settlements into one economy.

## 2. The walls, and why they exist

### Wall 1 — the food economy is capped by data (the main blocker)

- Demand: `hunger_rate` 0.33/s, a 3-food meal fills 38 → **about 2.3 food per person
  per day**. A thousand people need 2,300+ a day.
- Supply per building: `farm_plot` 0.1/s = **9 a day**, `fishing_dock` 10.8, an
  `aurochs_pen` a little. The Ford's two dozen bushes regrow about 200 a day in all.
  At today's passive yield a city would need **250–300 farm plots** (and ~350 huts at
  3 beds, or ~125 longhouses) — the case against scaling by count, below.
- `config/rules.json → improvements.list` (what the Steward lays out) has
  `farm_plot: fewer 2`, `hut: fewer 12`, no `fishing_dock` at all. After two farms the
  Steward never builds food again.
- `improve.gd:spot()` only places within `reach: 450` of `D.VILLAGE`, one site at a
  time (`max_sites: 1`). Outposts get no Steward layouts at all.
- Granaries are the only food storage (+100 each).
- **The deeper cause: food buildings are passive trickles.** `farm_plot.food` and
  `fishing_dock.food` are per-second constants; nobody works them. That is why wood
  piles to 6000 while people starve: labour has no way to become food except foraging
  bushes. More people do not mean more food, only more mouths.
- **250 plots don't fit.** A plot is r 28 plus `gap` 14; 250 of them need ~1.4 M
  units², the whole 450-reach disc is 0.64 M. Even spread over five settlements the
  map turns into a carpet of fields with 250 static sprites. Scaling by *count* alone
  is the wrong lever; yield per plot must grow too (worked fields, tech, irrigation).

### Wall 2 — births are a timer, not a population curve

- `rules.json → births: every 45 s`, one child, regardless of population; a day is
  90 s → **at most 2 births a day**, ~1.3 net after deaths. 8 → 1000 takes 500+ days
  even with nobody dying: ten real hours at 1x.
- No migration: vassalised or allied clans' people never join the tribe, wanderers
  don't arrive at a prosperous place.

### Wall 3 — challenges don't scale with size

- Raid size = base + hostility × k + winter (`rivals.gd` `launch_raid`); wolf packs
  are a fixed range; rival clans *do* regrow (pop +1 per ~2 days, warriors with it)
  but only to `rivals.json → people.max_pop` **14** — a ceiling that never scales with
  us. Seven raiders are a threat at 40 people and a rounding error at 1000.
- The director's tension cap (`director.json`) is not a function of tribe size.
- Sickness crowding (over 80 % of beds) is the one mechanic that worsens with
  density, which is the right idea.

### Wall 4 — performance

- `hz._sickness` spread is O(n²) every 2 s (a million distance checks at 1000).
- `living()` is re-filtered in many places per tick; `pop_cap()`, `food_cap()`,
  `nearest_fire()` loop all structures.
- No level-of-detail: asleep, idle and far-away people tick as often as workers.

### Experience problems on the way

- **Ghost outposts**: a Steward policy seals a new settlement contract every three
  days while earlier ones stand empty ("Housing for 6 more", sixteen times).
- **Spike deaths** erase ten days of growth in a day at small populations.
- **No mid-game goal** between "survive the winter" and the victory panels.

## 3. The proposal

In priority order. Items 1–3 make a city reachable; 4–6 make getting there a game.
Everything is data-first (`config/*.json`, `story.holds()`/`story.run()` verbs) and
exposed as game-master operations, per `CLAUDE.md`.

### 3.1 Let the food economy scale (data + two small verbs)

- **Worked fields (the main change).** A farm plot, dock and pen keep a small passive
  trickle (today's number, so a camp plays as now) and can be **worked**: a person on
  the job adds `food_per_worker` while they work it. Labour turns into food, and the
  wood surplus becomes a choice (build vs. farm). The mechanism already exists — it
  is the aurochs pen's own pattern, generalized: `_send_herder()` sends a **spare
  hand** (`spare_hand()`: idle or gathering, no office, awake — never a contract
  crew, a crisis fighter or the War Chief) on a `tend` job carrying `pen_id`, and
  `ox_care` decays when nobody does. So: the job carries a `struct_id`, "who works
  this plot" is a query over jobs, and there is no per-building worker state to
  save. The worker's bonus flows through the trickle line's own chain —
  `hz.food_mult(type)` (farm ×1.5 autumn, ×0 winter, weather `crops`),
  `nat.food_mult`, and the existing effect stat `inv.mul("yield", type)` — so
  seasons, inventions and culture finds already multiply it. New job type →
  `JOB_TYPES` (or widen `tend`).
  > **pi:** written to keep make_it_fun I1's not-goal ("no worker slots, no queues,
  > no upkeep menus") intact: the player never touches a slot. Staffing is the
  > Steward's existing job picker (`_update_vice`: idle hands → build / food / wood /
  > stone / lore / art) gaining a `farm` choice, taken ahead of wood when food days
  > fall under N (a `rules.json` number); a game master gets the same verb.
- **Two staffing sources, one job.** The Steward's picker is the fallback; the
  steady hands are a **`farmer` career** in `config/careers.json`, so the families
  who keep coming back to the fields become farmers and go there by themselves.
  Checked against `careers.gd`: `open: {"built": "farm_plot"}` and
  `from: {"job:farm": 1.5}` are pure data (an `open` is a `story.holds()`
  condition; `from` tags are `job:<type>` for any job type — the herder already
  grows from `job:tend`), but **`work` is a verb, and `go_work()` knows four:
  `gather`, `build`, `ritual`, `art`** — `{"farm": true}` would be a fifth. Make
  it one parameterized verb instead: `work: {"work_at": "farm_plot"}` → the
  nearest worked structure of that type with a free hand-place, the same "who
  works this plot" query §3.1 already defines, shared with the picker. The
  `fisher` career takes `work_at: fishing_dock` (today it gathers from fish
  *nodes*; the dock becomes its workplace) and the `herder` `work_at:
  aurochs_pen` (today it has no `work` at all, only the `preferred: tend` call).
  One small branch in `go_work()`, three career entries in data —
  machinery-light, but not machinery-free.
- **Career places must scale with the city.** `max` becomes the number shape the
  doc already uses (`{"base": 3, "per_pop": 0.03}`): 3 builders at 40 people, ~30
  at 1000 (`block()` reads it as a flat int today, so it widens to the shape —
  one line). The reason is not a stall: career `max` caps nobody's *labour* (the
  Steward can still send any idle hand to a site); it caps the *specialist layer* —
  the self-starting, 1.25×-fast, preferred-for-duty hands. A city of 1000 with
  three builders still raises longhouses, but on whichever idle hands the Steward
  catches; ~30 builders is what makes the city's building a trade, and lets the
  bed governor (§3.2) ride on specialists instead of casual labour.
- **Numbers that must agree** (the previous draft's didn't: ~3× the trickle per
  worker on 80–100 plots is ~3× a city's whole demand). Demand ≈ 2.3 food per person
  per day (≈ 3 in winter, hunger ×1.25); a plot's trickle is 9/day; set
  `food_per_worker` ≈ 10/day (a good gatherer: working a field beats idling, but the
  woods don't retire) and `workers` ≈ 3 → a fully worked plot ≈ 39/day. The farm
  share of a 1000-person city is then **~25–35 plots and ~75–105 farm workers
  (≈ 8–10 % of the people)** — a field district, not a carpet. These two numbers are
  the tuning guard: per-worker too high and farming is a checkbox with idle hands
  left over; too low and the 250-plot carpet returns. The freed hands are the arc's
  point: craft, trade, roads and great works (§3.4) are what a city does with people
  who no longer dig.
- **Winter is the storage system.** Farm ×0, dock ×0.5, pen ×0.7 in winter
  (`events.json → seasons.yields`), ~3 food per person per day: a 2-day winter at
  1000 people burns ~6,000 food. The autumn ×1.5 harvest, granaries + warehouses,
  the smokehouse's rot ×0.6 and trade caravans are not city decoration — they are
  how the city survives the season that shaped the tribe.
  - **Storage must scale with it.** A season is 2 days (`events.json → seasons.days`),
    so a year is 8 days and a 150-day campaign sees ~19 winters: a city needs a
    `food_cap` of ~7,000. Today `food_cap()` adds a hardcoded `FOOD_STORE_GRANARY`
    (100) per granary — 60+ granaries. Move it to data: a `store` key on any type in
    `structures.json` (granary 100, warehouse 500, a smokehouse or cellar on a
    longhouse adding some), summed by the cached `food_cap()`. ~10 warehouses then
    hold a city's winter, and losing one to a fire is a real blow.
    > **pi:** checked — it is that small. `food_cap()` is one function, and every
    > other reader (the director's `rich_food_at`, `story`'s `food_frac`, the
    > Steward's "stores are full" switch, spoil, the HUD numbers) calls it as a
    > number. Two touch points beyond it: the HUD tooltip string hardcodes "each
    > Granary %d more" (`hud.gd`), and `inv.store_bonus()` inventions stay additive.
    > Arithmetic check: ~6,000 burn − ~700 still produced in winter (docks ×0.5,
    > pens ×0.7, tribute) ≈ 5,300 must be stored; a 6,000–7,000 cap leaves the
    > autumn margin.
  - With a winter every 8 days, the "pinch" is a heartbeat, not an event. That is
    good for the rhythm (build up, hold, build up) but it means a *bad* winter
    (long, early, blizzard) must be the escalation, not winter itself — an
    `events.json` chance that a winter runs a third day, rising with era. Make the
    bad winter **weather, not a longer season**: a spring "late frost" (a new
    `events.json` weather kind: `crops × 0`, `berries × 0`, cold) does everything a
    third winter day would, through the multipliers weather already applies,
    without touching `seasons.days` or the season clock every seasonal rule reads.
- Let `fewer` take the **number shape `story` already has** for dilemmas
  (`{"per_pop": k}`, `story` line ~351): `"fewer": {"farm_plot": {"per_pop": 0.05}}` =
  fewer than one field per 20 mouths — 2 fields at pop 40 (as now), a ceiling of ~50
  at 1000 that the picker only reaches when other food runs short (the count is a
  ceiling, not a quota). No new condition key, only `fewer` accepting a
  number-or-`per_pop` value; `COND_TYPES` and `test_spend` cover it.
- `improvements.list` becomes a growing plan: fields per 20 mouths (`per_pop` above),
  a dock wherever a
  settlement stands near water and fish are known, a pen per 40, huts per homeless 3
  (upgraded to large huts in era 2), a granary per 100 food of demand, workshops and
  the era-3 buildings of `make_it_fun.md` H3 as they land.
- **Plan per settlement**: `improve.gd` anchors on every point of `sim.settlements()`
  with its own `reach`, which grows with the settlement's tier (§3.3). `max_sites`
  becomes per settlement.
- Put the **existing** era-2 buildings in the plan first (Longhouse when homeless and
  era 2, Temple at town tier, Smokehouse already there). Then new types for scale
  (config + baked models, `ART_VERSION` bump): **warehouse** (era 2, `store` 500),
  **well** (reduces sickness crowding), **irrigated field** (era 3, an upgrade of a
  plot via `sim.upgrade()`: more workers and yield, same footprint). The Steward's
  `when` picks them by tier and tech.
- `food_cap()`/`pop_cap()` become cached sums updated when a structure is built,
  upgraded or demolished (a `_cache…` var, so it isn't saved).

Target mix for 1000 people (~2,300 a day, more in winter), made to agree with the
numbers above: **~50 % worked fields** (25–35 plots), **~25 % docks and pens**,
**~10–15 % tribute and trade**, **≤ 10 % forage and hunt** (the Ford's bushes
regrow ~200 a day in all; forage can't be more than a camp's living). Winter still
the pinch. Today tribute and trade cannot carry even that share: vassal tribute is
a flat 3–6 food a day (`dilemmas.json → submit`) and a caravan's lots are 12–26
food (`rivals.json → traders`). They must scale with the clans' own growth (§3.4):
tribute per clan pop, lot size per clan pop, and caravans that come more often to
a city — the surplus wood (the 6,000 pile) is what a city buys food with, and the
era-3 Trading Post's `trade_every`/`trade_rate` multipliers are the building that
turns the share on at city tier (the post is era 3, like the wall the city tier
requires). That is the diplomacy dividend the rival growth pays for; it is not a
second farm.

### 3.2 Births as a rate, plus migration

- `births.every` becomes the interval **per eight grown family lines** (each person
  is a family line, so there are no women/men or couples to count; a tribe of 40
  grows at today's pace; a town of 800 has up to ~12 births a day), multiplied by a
  **crowding factor** (mood and beds: a crowded, gloomy town has fewer children) and
  the winter. Config: `{"per_lines": 8, "every": 45, "crowd_at": 0.8, "crowd_k": 2}`
  (`crowd_at` shared with sickness crowding, below).
- **The curve's governor is beds, not the birth rate.** Births already stop at
  `pop_cap()` (`_update_births` gates on `pop < pop_cap()` and `min_food`), so the
  raw per-mothers rate (at pop 300 that is ~75 births a day) is clipped by the bed
  gate and crowding to the ~15 the S-curve wants. Growth therefore runs at the
  Steward's *build pace* — wood and work for huts and longhouses — which couples
  population to the economy and makes "draw settlers" and "grow the village" real
  alternatives rather than birth-rate knobs.
  - So the build pace has to be able to keep up: ~300 beds between day 50 and 90 is
    ~37 longhouses (or a hut mix) in 40 days, plus fields and stores. One site at a
    time per settlement every 15 s (`improve.every`, `max_sites: 1`) will be the next
    wall. `max_sites` should grow with tier (1 camp, 2 village, 3 town, 4 city) and
    the builders come from the same spare pool as the farmers — the labour market
    again. Checked against the build job: a builder's rate is already
    `dt × (1 + 0.12 × craft) × work_mul × inv.mul("build")` — craft levels, mood,
    weather, the `makers_pride` tradition and inventions all scale it — and a
    3-hand crew finishes a longhouse (60 work) in ~15–20 s of work, faster than one
    `improve.every` cycle. The limiter is layout cadence, wood flow and the
    one-unbuilt-at-a-time-per-type rule, not work rate: `max_sites` by tier plus the
    upgrade rows should be enough (settles open question 4).
  - The bed gate makes births a cliff (full rate, then zero). Crowding should taper
    it instead: rate × (1 − beds_used/beds)^k past ~80 % full, the same threshold the
    sickness crowding already uses, so one number in data drives both (checked:
    `hazards.gd` computes `living()/pop_cap() − 0.8`; one `crowd_at` key can feed
    both).
- **Migration** as the second growth path, tied to diplomacy and reputation:
  - vassals and allies send **families** (a new `rivals.json → people.join` key),
    one a day while there are empty beds;
  - **wanderers** arrive at any settlement of tier ≥ village in good times
    (`config/life.json`), a dilemma: take them in (mood, skills, a stranger's tale)
    or turn them away;
  - a **"Draw settlers" policy** (`config/policies.json`) trades food for arrivals.
- Children stay at 3 days; a town's school/lore buildings shorten it a little.
- **Growth S-curve**: ~30 people by day 20 (as now — the run in §1.1 is at 28), ~200
  by day 50, ~500 by day 90, ~1000 by day 150–180. At 2x–4x that is a 2–3 hour
  campaign to a city. The *season* of the crossing matters: a city that reaches 1000
  at winter's door without full stores loses a fifth and falls back — a story beat,
  not a failure — so §3.6's victory is "a thousand held through a winter", and the
  endgame is the autumn rush: harvest ×1.5, the granaries filling, first snow.

### 3.3 Settlement tiers: camp → village → town → city (make_it_fun I5)

- A rule over `sim.structures` and `sim.living()` per settlement in
  `config/rules.json → tiers`:
  `camp` (an outpost: 2 huts), `village` (≥ 20 people, ≥ 8 beds, a farm),
  `town` (≥ 150, a longhouse, a granary, a shrine, a road to the village),
  `city` (≥ 500, a temple or grand altar, a stone wall, a warehouse, a trading post).
  Tier rules are `story.holds()` conditions (`pop` per settlement, `built`, `era`),
  so a culture pack or scenario can rename or re-gate them.
- **Pacing check against the S-curve** (§3.2): village ~day 15, town ~day 45–50,
  city ~day 90. Era 2 (farming, cost 35, `berry` practice) arrives well before the
  150 mark, so the longhouse is not the binding gate — the headcount is. The city
  tier is the opposite: it needs the era-3 Stone Wall, so its timing follows the
  bronze age, and pop 500 will usually be waiting on the tech — the name arrives
  with the age, which is the right story. Town lands at the growth spurt's peak,
  when beds (the governor) are fullest, so the
  first town plague or fire is exactly the "villagehood ends" beat — good drama,
  but the director's spike-death softening (§3.4's `while` list) is a few lines and
  should land with this step, not wait for step 5. The city row then carries the
  last ~60 days (500 → 1000); if the metrics show tension going flat there, split
  the row at ~800 ("the crowded city": fuel, rot and strife together) rather than
  adding a fifth tier.
- Each step is an `inv.feat("settlement", …)` moment with a snapshot, the
  chronicle, and a **name**: the settlement loses "'Panshi's Outpost'" for a proper
  place name (`D.PLACE_NAMES`, translated), which the clans' parley texts use.
- A settlement of tier ≥ village gets its own **Steward layouts** (§3.1), can
  **start contracts** (`at_settlement` already exists), and its own festival.
- The **overpop** dilemma's "Frontier Colonization" option is only offered while no
  outpost of ours has empty beds, and gains a "Grow the village" option (build
  beds): this alone ends the ghost towns. `_resettle` moves a family a day, not a
  person.
- The HUD gets a **settlement list** (name, tier, people/beds, food, what it
  lacks), and the New Game / map screen shows the sites.

### 3.4 Challenges that grow with the city

All data (`events.json`, `rivals.json`, `director.json`) with a few pop/era hooks:

| size | what bites | where |
|---|---|---|
| camp (as today) | wolves, winter, hunger, sickness, a first raid | `events.json`, `hazards.gd` |
| village | raids sized to our fighters, feud, flood by the river | `rivals.json size`: `base` + `share_of_fighters` |
| town | **plague** (crowding spreads radius with density), **urban fire** hopping hut to hut, **raiders torching the fields** (worked fields live outside any wall — make_it_fun I2's "raiders go for what's outside first": `launch_raid`'s target choice plus the wildfire state on a structure), **blight** (the `crops` weather multiplier already runs in `hz.food_mult`; a blight is a data entry that zeroes farm yield for days), earthquake toppling big buildings, **winter fuel** (fires burn nothing today; a wood-per-second drain in `rules.json` is the one new upkeep — no menu, just the wood counter falling), **food rot** in big stores, thieves and feuds | new entries in `events.json`; `nat.pending`; `roads.gd` for fire spread; a `fuel` rule in `rules.json day/night` |
| city | **rival coalitions** (clans ally against the big tribe), **civil strife** (a town with low morale rises: a crisis of `emergency.json`), **the sprawl** (homes and fields creep past the wall and the fords; distance already costs — walked hunger, walking time — so roads are the answer, not a new yield rule), a **great works** obligation (the temple wants the same spare hands the fields want: the labour market *is* the dilemma) | `rivals.json`, `life.json discontent` → `crisis.gd`, `legacy.json` |

- **The rivals must grow too, or the table is fiction.** A clan capped at
  `max_pop: 14` cannot send a raid "sized to our fighters" at 300 people. Three
  data-driven ways, in order of preference:
  1. `people.max_pop` becomes `{"base": 14, "per_our_pop": 0.08}`: a clan grows
     toward ~8 % of us (≈ 80 at our 1000), regrowing at its own rate; the raid share
     stays a fraction of *their* warriors, so a raid is still a decision of theirs.
  2. **Coalitions** (city tier): clans with a shared grudge join raids, so the
     threat grows by diplomacy, not by inflating one village.
  3. **Newcomers**: a new clan (from `D.CLANS`) arrives at an empty site in a later
     era — a "the people from beyond the hills" beat, with first contact again.
  Vassals and allies grow the same way, and that is also what makes their tribute
  (the 10–15 % above) and their families (§3.2 migration) scale.
  Checked: the cap is computed in exactly one place (`_update`:
  `mini(int(cp["max_pop"]), c["pop"] + 1)`), the warrior clamps scale with pop on
  their own, and a clan's walking people stay few (2 hunters, home guards, the raid
  party — `max_pop` is a ledger number, not a spawn count, so §3.5 owes nothing to
  this). The regrow rate already fits, too: +1 per 2 days ≈ the cap's own growth at
  the S-curve's slope (0.08 × ~6 people/day), so clans ride their cap without a
  rate change. Their village's huts don't grow with pop — acceptable behind the
  fog; a hut per 10 pop in `_build_village` is the cheap fix if it ever shows. For
  the tribute and trade to be worth anything at scale, their flat numbers must
  become per-pop too (see the target mix: 3–6 food/day and 12–26-food lots today).
- The **director's cap** becomes a function of population (`director.json levels.*.cap_per_pop`)
  so big tribes still get quiet stretches.
- **Spike deaths** are softened: the director holds a raid while a sickness wave or
  famine is on (`director.allow` already exists; add a `while` list).

### 3.5 Performance to 1000 (and 4x speed)

- **Spatial hash** (`sim._grid`, rebuilt lazily) for sickness spread, `find_node`
  and "people near" queries; `_sickness` becomes O(n × neighbours).
- **Level of detail**: people asleep, idle or far from any threat tick every 2nd–4th
  step; the Steward's and War Chief's scans run on the same schedule as today but
  over the hash.
- Cache `living()`, `pop_cap()`, `food_cap()` per tick / on change.
- A **perf test** (`tests/test_contract.gd → test_perf_1000`): seed a game, add
  1000 people, assert < 25 ms/tick headless, so regressions show in CI. Measure it
  with people *working* (a seeded day with jobs, `life` on, as `test_smoke` plays),
  not idle: the 37.5 ms in §1.2 is the floor, pathing and job scans are the rest.
  Keep a 200-person variant as the fast CI check and run the 1000 one in
  `tools/metrics.gd`.
- Rendering: `world_view` already caches static items; units at 1000 are 1000
  sprite draws, fine. The HUD must stop looping `living()` per frame.

### 3.6 A city victory path and the story around it

- `config/legacy.json → paths.city`: a **city** (tier 4) that has held ~1000 people
  through a winter, the Grand Altar, and roads linking every settlement. Text: "Hear
  how the tribe of the bonfire raised the first city of the river — and kept a
  thousand warm through the hungry dark."
- The chronicle and the LLM personas (`evo.world_ctx()`) speak of "our village", "the
  town of X", "the city": `hz.summary()`/`evo.world_ctx()` gain a `settlements` list
  with tiers, so a game master can drive it too (`story.run()` actions
  `{"tier_up": ...}` are not needed; the rule does it, the GM reads it). With
  careers on main, `world_ctx()` also carries `careers.in_words()` — cap it here
  (open question 1), or every prompt lists the whole city by name.
- New game-master operations: `improve.plan(settlement)`, `folk.add_family(n,
  at)`, `sim.tier_of(at)` — each JSON-shaped and clamped at the boundary.

## 4. Order of work and what to measure

1. Worked fields (`farm` job + `farmer` career), `fewer` with `per_pop`, the `store`
   key and cached `food_cap()`, era-2/3 buildings in `improvements.list`, the
   longhouse alias fix, plan per settlement (§3.1).
   Measure: food days > 10 into and through a winter; the wood pile below ~1,500 at
   day 60; pop at the birth-timer ceiling (~90–110 — food alone can't beat Wall 2:
   from 28 at day 20, two births a day cap day 60 near 105 before deaths).
2. Births per family lines + crowding taper + `max_sites` by tier + career `max` per
   pop (§3.2, §3.1). Measure: pop at day
   60 (target 150+), day 120 (target ~500), beds built per day vs. births, share of
   spare hands building vs. farming. (Open question 1 is settled: a person is a unit.)
3. Tiers, names, settlement HUD, overpop gating, and the director's `while` list
   (§3.3, §3.4: it lands here because town tier is where the stacking starts).
   Measure: no settlement with
   empty beds older than 5 days when a new outpost is sealed; the ghost-town count is 0.
4. Spatial hash + LOD + perf test (§3.5). Measure: ms/tick at 1000 (target < 25).
5. Scaling challenges and the director cap (§3.4). Measure: `tools/metrics.gd` at
   120 days with pop bands; share of days with a real threat 40–70 % (the G1 bands,
   extended to the long game).
6. City path, personas, chronicle (§3.6).

After each step the metric runs (`tools/metrics.gd --days=120`, `tools/pacing.gd`)
and `test_smoke` with every system on tell whether the curve is a story: growth,
a pinch, a crisis, growth.

## Open questions

1. **What is "a person" at 1000? — settled: a person is a unit** (one family line,
   the design rule since 2026-11-18). The alternative, people = units × a household
   size (~200–250 units for a city), was argued and dropped: it breaks `life.gd`'s
   one-person-one-line rule, threads a second population count through hunger, beds,
   `pop_cap`, raids, the HUD, the metric bands and the victory check, and breaks the
   symmetry with the rival clans' per-unit `pop`/`warriors`. Its perf saving is
   smaller than it looks, since §3.5 is due by ~500 anyway. Consequences: §3.5 is
   required; the LLM contexts must *stay* small — checked at this branch's commit
   they were (`folk.summary()` a children count, `rivals.summary()` capped
   slices), but main's careers have since added `trades_people_live_by:
   careers.in_words()` (every holder, name → trade) to `evo.world_ctx()`, which
   would be ~500 names at city scale: cap it — counts per trade plus each trade's
   notable holder — the same treatment `treasures` gets (wonders first, then the
   last 8); a purely visual ambient crowd in `world_view` is out of scope until a
   city exists to look at.
2. **Job priority vs contracts and the War Chief — settled, no fight.** Field
   staffing draws only from the spare pool (`spare_hand()`: idle or gathering, no
   office, awake — the pen's herder comes from the same pool), so it can never take a
   contract crew (role `"contract"`), a crisis fighter or the titled: they hold
   their people, or take them by *interrupt* (`set_aside`/`end_errand` — the field
   work resumes after). The only order to write down is inside the spare pool: the
   Steward's picker (`_update_vice`) tries farm before wood when food days fall
   under N; night sends farm hands to bed like any day-only work (`beds.day_only`).
3. **Outposts before tier village — keep them, as farmsteads.** The land is the
   point: the village's 450-reach disc can't hold the city's longhouses *and* its
   fields, so outposts are where the fields go (`contracts.next_site()` already
   picks frontier sites; `D.route()` walks them home over the fords). Gate new ones
   on "no empty beds in any outpost of ours" (§3.3) and village tier, and give the
   settle contract a farm-first plan — a field, a hut, a granary, not two huts and a
   bonfire. Far fields already pay in walked distance (walk hunger), which is the
   pressure that earns roads.
4. **Build throughput — settled: cadence, not rate.** `max_sites` by tier plus the
   upgrade rows should be enough: a builder's rate already scales with craft, mood
   and inventions (`inv.mul("build")`), and a 3-hand crew finishes a longhouse
   faster than one `improve.every` cycle (§3.2). What step 2's metrics must watch
   is wood flow and the one-unbuilt-per-type rule, not work speed.
5. **Winter cadence — settled: keep the 8-day year.** A winter every 8 days is
   rhythm, not nagging, because what the player experiences is decisions, not
   clock: at 4x a year is 3 real minutes, and winter prep is one choice (the
   autumn dilemma) plus a passive harvest. The escalation is the *bad* winter —
   the late frost as weather (§3.1), rising with era. Don't grow `seasons.days`:
   it moves every seasonal number in the game (berry regrow, spoil, the winter
   picker, this doc's arithmetic). Revisit only if playtests at 4x call it nagging.

## 5. Out of scope / deliberately not proposed

- No new renderer, no multithreading: the measured curve says hashing and LOD are enough.
- No "city builder" free-form zoning: the Steward's layouts per settlement keep the
  pause-and-play feel and the LLM game master in the loop.
- No separate "city map": cities live on the same world map; the tier is a rule, not
  a scene.
