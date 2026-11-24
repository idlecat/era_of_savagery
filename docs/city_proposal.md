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

Linear, no cliff, but 1000 *working* people, 600 buildings and 1000 sprites on
screen will sit at the edge of 1x, and the 2x/4x speed keys will be unusable, which a
long game needs.

### 1.3 Nothing in the game is a city

- `docs/make_it_fun.md` I5 ("camp → village → town by what's been built") is not
  implemented; there is no town or city concept in any script or config.
- `config/legacy.json` has conquest, unity and wisdom; no population or city path.
- Era-2 buildings exist since a52e346/18fe442: **Longhouse** (8 beds, `hearth_bond`),
  **Temple**, **Smokehouse** (`spoil × 0.6`), **Lookout Tower**, and the palisade ring.
  None of them is in `improvements.list`, so the Steward never builds them, and
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
  A city therefore needs **250–300 farm plots** (and 350+ huts at 3 beds each).
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

- Raid size = base + hostility × k + winter (`rivals.gd:342`); wolf packs are a fixed
  range; rival clans have a fixed `pop` and `warriors = pop / 3` and never grow. Seven
  raiders are a threat at 40 people and a rounding error at 1000.
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
  trickle (today's number, so a camp plays as now) and gain a **work slot**: a person
  on a `farm` job adds `food_per_worker` (data per type, ~3× the trickle per worker,
  `workers` max 2–3, season and `inv.mul("farm")` applied). Labour now turns into
  food, the wood surplus becomes a choice (build vs. farm), and 1000 people need
  ~80–100 worked plots, not 250. The Steward's job picker staffs fields before
  chopping when food days < N (a `rules.json` number). New job type → `JOB_TYPES`.
- Let `fewer` take the **number shape `story` already has** for dilemmas
  (`{"per_pop": k}`, `story` line ~351): `"fewer": {"farm_plot": {"per_pop": 0.1}}` =
  fewer than one plot per 10 mouths. No new condition key, only `fewer` accepting a
  number-or-`per_pop` value; `COND_TYPES` and `test_spend` cover it.
- `improvements.list` becomes a growing plan: farms per 12 mouths, a dock wherever a
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
- **Migration** as the second growth path, tied to diplomacy and reputation:
  - vassals and allies send **families** (`rivals.json → people.join`), one a day
    while there are empty beds;
  - **wanderers** arrive at any settlement of tier ≥ village in good times
    (`config/life.json`), a dilemma: take them in (mood, skills, a stranger's tale)
    or turn them away;
  - a **"Draw settlers" policy** (`config/policies.json`) trades food for arrivals.
- Children stay at 3 days; a town's school/lore buildings shorten it a little.
- **Growth S-curve**: ~60 people by day 20 (as now), ~200 by day 50, ~500 by day
  90, ~1000 by day 150–180. At 2x–4x that is a 2–3 hour campaign to a city.

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
| town | **plague** (crowding spreads radius with density), **urban fire** hopping hut to hut, earthquake toppling big buildings, **winter fuel** (1000 people need wood, not just food), **food rot** in big stores, thieves and feuds | new entries in `events.json`; `nat.pending`; `roads.gd` for fire spread; a `fuel` rule in `rules.json day/night` |
| city | **rival coalitions** (clans ally against the big tribe), **civil strife** (a town with low morale rises: a crisis of `emergency.json`), **the frontier** (far farms need roads, else yields fall), a **great works** obligation (the temple demands labour) | `rivals.json`, `life.json discontent` → `crisis.gd`, `legacy.json` |

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

- `config/legacy.json → paths.city`: a **city** (tier 4) of 1000 people, the Grand
  Altar, and roads linking every settlement. Text: "Hear how the tribe of the bonfire
  raised the first city of the river."
- The chronicle and the LLM personas (`evo.world_ctx()`) speak of "our village", "the
  town of X", "the city": `hz.summary()`/`evo.world_ctx()` gain a `settlements` list
  with tiers, so a game master can drive it too (`story.run()` actions
  `{"tier_up": ...}` are not needed; the rule does it, the GM reads it).
- New game-master operations: `improve.plan(settlement)`, `folk.add_family(n,
  at)`, `sim.tier_of(at)` — each JSON-shaped and clamped at the boundary.

## 4. Order of work and what to measure

1. Worked fields, `fewer` with `per_pop`, era-2 buildings in `improvements.list`, the
   longhouse alias fix, plan per settlement (§3.1).
   Measure: pop at day 60 under the steward policy (target 150+), food days (target < 5).
2. Births per mothers + crowding (§3.2). Measure: pop at day 120 (target ~500).
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
2. Worked fields change how the Steward assigns jobs; does that fight the contract
   executor (contract crews are taken off work) or the War Chief? Needs a priority
   order written down.
3. Are outposts worth keeping as separate settlements at all before tier village, or
   should the overpop dilemma only ever offer "grow the village" until a road exists?

## 5. Out of scope / deliberately not proposed

- No new renderer, no multithreading: the measured curve says hashing and LOD are enough.
- No "city builder" free-form zoning: the Steward's layouts per settlement keep the
  pause-and-play feel and the LLM game master in the loop.
- No separate "city map": cities live on the same world map; the tier is a rule, not
  a scene.
