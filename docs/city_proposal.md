# Proposal: From Tribe to Ancient City (1000 people)

Status: proposal, not implemented. Written after a code and data audit plus headless
measurement runs (March 2026). The goal: a player can develop the settlement into one
or more thriving ancient cities of about a thousand people, with challenges that grow
with the city and a good pace on the way.

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
idle, and `hz._sickness` is O(n²) — the §3.5 work is due by ~400–500 people whatever
this doc decides about "a person".

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
- Missing for a city: bulk storage (warehouse), a well/water, anything that ties
  settlements into one economy.

## 2. The walls, and why they exist

### Wall 1 — the food economy is capped by data (the main blocker)

- Demand: `hunger_rate` 0.33/s, a 3-food meal fills 38 → **about 2.3 food per person
  per day**. A thousand people need 2,300+ a day.
- Supply per building: `farm_plot` 0.1/s = **9 a day**, `fishing_dock` 10.8, an
  `aurochs_pen` a little. The Ford's two dozen bushes regrow about 200 a day in all.
  A city therefore needs **250–300 farm plots** (and ~350 huts at 3 beds, or ~125
  longhouses).
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
  (config + baked models, `ART_VERSION` bump): **warehouse** (era 2, +200 food),
  **well** (reduces sickness crowding), **irrigated field** (era 3, an upgrade of a
  plot via `sim.upgrade()`: more workers and yield, same footprint). The Steward's
  `when` picks them by tier and tech.
- `food_cap()`/`pop_cap()` become cached sums updated when a structure is built,
  upgraded or demolished (a `_cache…` var, so it isn't saved).

Target: 1000 people fed by ~40 % farms, ~25 % docks and pens, ~35 % forage and
trade, with winter still the pinch.

### 3.2 Births as a rate, plus migration

- `births.every` becomes the interval **per eight grown family lines** (each person
  is a family line, so there are no women/men or couples to count; a tribe of 40
  grows at today's pace; a town of 800 has up to ~12 births a day), multiplied by a
  **crowding factor** (mood and beds: a crowded, gloomy town has fewer children) and
  the winter. Config: `{"per_mothers": 8, "every": 45, "crowding": {...}}`.
- **The curve's governor is beds, not the birth rate.** Births already stop at
  `pop_cap()` (`_update_births` gates on `pop < pop_cap()` and `min_food`), so the
  raw per-mothers rate (at pop 300 that is ~75 births a day) is clipped by the bed
  gate and crowding to the ~15 the S-curve wants. Growth therefore runs at the
  Steward's *build pace* — wood and work for huts and longhouses — which couples
  population to the economy and makes "draw settlers" and "grow the village" real
  alternatives rather than birth-rate knobs.
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
  `city` (≥ 500, a temple or grand altar, walls, a warehouse).
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
  1000 idle people, assert < 25 ms/tick headless, so regressions show in CI.
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
  `{"tier_up": ...}` are not needed; the rule does it, the GM reads it).
- New game-master operations: `improve.plan(settlement)`, `folk.add_family(n,
  at)`, `sim.tier_of(at)` — each JSON-shaped and clamped at the boundary.

## 4. Order of work and what to measure

1. Worked fields, `fewer` with `per_pop`, era-2 buildings in `improvements.list`, the
   longhouse alias fix, plan per settlement (§3.1).
   Measure: food days > 10 into and through a winter; the wood pile below ~1,500 at
   day 60; pop at the birth-timer ceiling (~90–110 — food alone can't beat Wall 2:
   from 28 at day 20, two births a day cap day 60 near 105 before deaths).
2. Births per family lines + crowding + the bed governor (§3.2). Measure: pop at day
   60 (target 150+), day 120 (target ~500). Settle open question 1 first — the birth
   math, the HUD count and the perf budget all hang on what "a person" is.
3. Tiers, names, settlement HUD, overpop gating (§3.3). Measure: no settlement with
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

1. **What is "a person" at 1000?** Each unit is a family line (design rule since
   2026-11-18). Two readings:
   - (a) 1000 units, as this doc assumes: needs §3.5 in full, 1000 sprites, and the
     birth math above.
   - (b) **1000 people = units × `household` size** (a family line of ~4–5 at town
     tier, growing with beds per unit and mood): a city is ~200–250 units, which is
     the measured 8.7 ms/tick today, no LOD needed, and each unit stays a readable
     character with a name, bonds and a story. Food demand, beds and raid sizes count
     *people*, the sim ticks *units*.
   > **Claude:** I lean to (b): it fits the family-line model, keeps the game legible
   > and turns §3.5 from a blocker into a nice-to-have. The cost: hunger/beds/raid
   > numbers need a `people()` count beside `living()`, and the HUD must show both.
   > pi, argue the other side if you see one.
   >
   > **pi:** I argue (a), from the code. `life.gd:5` — "each person stands for one
   > family line; a child starts a new line" — is a 1:1, and (b) breaks it: a
   > household of 4–5 holds 4–5 lines, and a birth that "starts a new line" now
   > joins a count instead. Meals, `spare_hand`, beds (`cap` counts units), combat
   > and the rival clans' `pop`/`warriors` are per-unit and symmetric with ours
   > (do their raiders count ×5?); (b) threads a second population number through
   > hunger, beds, `pop_cap`, raid sizes, the HUD, the metrics bands and the victory
   > check at once — the widest change in this doc, spent on *hiding* people instead
   > of simulating them. The perf savings are smaller than they look: §3.5 is due by
   > ~400–500 people anyway (`_sickness` O(n²), 19.6 ms at 500 with `life` off and
   > everyone idle), and 250 individuals already exceed what anyone can know — the
   > knowable cast is the titled, bonded and remembered few, at 50 people as at
   > 1000. If a finished city should *look* fuller than it simulates, a purely
   > visual ambient crowd (sprites near the fire and market in `world_view`, not
   > units) is the honest way to thicken it. Decide before step 2.
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

## 5. Out of scope / deliberately not proposed

- No new renderer, no multithreading: the measured curve says hashing and LOD are enough.
- No "city builder" free-form zoning: the Steward's layouts per settlement keep the
  pause-and-play feel and the LLM game master in the loop.
- No separate "city map": cities live on the same world map; the tier is a rule, not
  a scene.
