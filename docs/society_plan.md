# Implementing the society model

Draft 2, 2026-11-26 (brought in line with society.md draft 5: food's two-window weight, the greatest-weight rule, six channels). How `docs/society.md` (the model) becomes code: where each part of
the model lives, what it replaces, and in what order. The model doc says *what*; this doc
says *where and how*. Section numbers like "model §4" point into society.md.

## 1. Ground rules (from CLAUDE.md, applied here)

- **Rules are data.** Every number of the model (c, the method rates, a, k, N₀, l, the
  curve, the floors, the channel values, the wants, the wear) lives in one new config,
  `config/society.json`, read by `Config.load_cfg("society")` (read-only, user override
  in `user://config/`), documented in `docs/CONFIG.md`. Texts get zh.
- **One formula, two users.** The model's pure functions (benefit, demand, ΔB, the two-window food weight, the persistence forecast,
  the production formula's factor product, payback) go in a static script
  `scripts/society_model.gd` used by both the calculator and the game, so the two can't
  drift apart.
- **The sim stays deterministic** and LLM-free; the new subsystem reports through signals
  and is readable as a dictionary.
- **Game-master ready.** Every new change is a named operation with JSON arguments
  (story actions, `soc.*` verbs), whitelisted and clamped at the boundary; every state is
  in `soc.summary()`.
- **Scale.** A city has a thousand people: nothing loops over everyone per person; the
  subsystem recomputes on a slow clock from counts and per-tick caches.
- **Saves.** Config-derived vars UPPERCASE, caches `_cache…`, state lowercase (saved by
  reflection).
- **Switchable.** `soc.on` like `careers.on`/`life.on`; `tests/_new_sim()` sets it off so
  older tests stay deterministic; `test_smoke` plays with it on.
- **Measured.** Every step runs the 12-day metric bands and, for the balance-moving steps,
  three 150-day games; the canary baseline is rewritten after a step meant to move it.

## 2. The new pieces

| Piece | Kind | Role |
|---|---|---|
| `config/society.json` | config | all the model's parameters (model §12), per level where needed |
| `scripts/society_model.gd` | static, pure | the formulas: `benefit(c)`, `gain(c, s, d)`, `demand(a, n, n0, k)`, `alloc_demand(...)`, `factor_product(...)`, `payback(...)` |
| `scripts/society.gd` | sim subsystem `sim.soc` | live needs: demand, supply, coverage (C_now, and C_horizon for food) per need; the six channels as queries; weights for the allocation; wealth, output per head, the standard; `summary()` |
| `tools/society_calc.gd` | tool | the calculator: the periodic year for each level and size (model §12), printing shares, h, R, K, coverage, standard, ceilings; `--fit` to fit the knobs to the share table |
| a Society panel | HUD | needs with coverage bars, hands per need, the standard, wealth |

`sim.soc` is created with the other subsystems in `sim.gd` and disposed with them
(`sim` back-reference, `test_dispose`).

### 2.1 `society.gd` in outline

- **A slow clock**: recompute every `every` s of game time (1 s), not per tick. Between
  recomputes, queries read the last values (`_cache_needs`).
- **One pass over the living** per recompute to count: mouths, workers (d), the sick, who
  works for which need (from the job, §3.3), who knows which method (counts per method
  from `evo.knowers`).
- **Per need**: `demand()`, `supply()`, `coverage()` from those counts, the per-tick
  building indexes (`built_of`, `serving`) and stocks. Each need is a small function
  table keyed by the need id in `society.json`, so a new need is data plus, at most, one
  supply function.
- **Queries for the rules** (the channel hooks, §3.4): `work_mult(u)`, `death_mult(cause)`,
  `hunger_mult()`, `loss_mult(kind)`, `mood_term()`, `incidence_mult()`, `teach_rate()`...
  each `1 - B(C)` scaled by its config.
- **Hardship rates**: `hardship_rate(need)` = 0 above `C_floor`, linear to its max at 0;
  the existing hardships (famine, sickness waves, strife, raids breaking in) read it and
  still ask `director.allow()`.
- **Signals**: `need_short(need, coverage)` when a need crosses its floor (down or up), so
  the HUD and a game master hear it; the log line is data.

## 3. Mapping the model onto the code

### 3.1 People, consumption, the time budget (model §2)

| Model | Now | Change |
|---|---|---|
| N, workers, d | `sim.living()`, `u.role == "child"`, `u.sick`, hp | counted once per recompute in `soc`; d exposed in `summary()` |
| c | `survival.hunger_rate`, `meal`, `meal_fill`, `meal_fill_fire`, `walk_hunger`, `child_hunger`, `hz.hunger_mult()` | read, not duplicated: `society_model.c_per_day(RULES, walked)` derives c from them, at rest (~2.3 with fire) plus the walk's hunger (model §2) |
| the time budget, h | not measured | measured in `tools/metrics.gd` (share of grown-up seconds by state: asleep, meal, life, walking, working, by `u.doing` and path); `soc` estimates h from the same states sampled on its clock |
| the walk | `step_move`, `weigh.trip()` | no change in step 1; its methods (roads, granaries by the fields, workshops at home) shorten it as they do now |

### 3.2 The production formula (model §3)

One function for the rate of every kind of work:

`sim.work_rate(u, work, method) = base(method) × known × products × skill × techniques × culture × land`

times `work_mul(u)` (spirits, fatigue, the sick, weather: unchanged), used everywhere a
rate is computed today:

| Work | Now (sim.gd) | Becomes |
|---|---|---|
| gathering | `base × (1 + 0.1 × lv) × (1.3 if tools) × work_mul × (1.2 if peaceful_ways) × inv.gather_mult(...)` | `work_rate(u, "gather", kind)` |
| fields, docks | `worked.food × (1 + 0.05 × lv) × work_mul × (1.3 if harvest_festival) × season × nat × inv.mul("yield")`, plus the passive `food` | `work_rate(u, "field", type)` × season × nature; **the passive `food` key on `farm_plot` and `fishing_dock` goes** (model §3.2); pens keep milk |
| building | build speed with `inv.mul("build")`, makers' pride | `work_rate(u, "build", …)` |
| crafts, rites, teaching, healing, guarding | each its own | `work_rate(u, <work>, …)` |

- **base(method)**: `society.json methods`: per kind of work, the method ids (a tech or
  an invention that opens it) and their base rate. The best method the person knows is
  used.
- **known**: `evo.knows(u, tech)` → 1, else `unknown` (0.5). Inventions are tribe-wide
  for now (they have no knowers); if needed later, the same table.
- **products**: `soc.coverage_of(good)` for the goods the work `uses` (data), mapped to
  a multiplier `1 + (max - 1) × B(C)`.
- **skill**: `society.json skill_curve`: one table of multipliers by level (×1.0 → ×1.4),
  replacing `0.1 × lv` and `0.05 × lv`.
- **techniques**: `inv.mul(stat, of)`, as now, for the inventions marked technique.
- **culture**: the traditions' bonuses move from `has_trad()` literals in `sim.gd` into
  data effects (`D.TRADITIONS` gain an `effects` list in the shared format), folded by
  `inv._sources()` like policies. This is the CLAUDE.md "move hardcoded tuning to data"
  rule applied on the way.
- **land**: the node's own regrowth and amount (as now), plus diminishing returns on a
  worked structure: the n-th hand's share from `worked.hands_curve` (data), replacing
  the hard `hands` limit's flat rate.

**Tech flags that become products**: `has_tech("tools")` ×1.3 on gathering → the
`tools` good's coverage; pottery's spoilage halving → the `pots` good's coverage
(spoilage is food's losses channel). The tech descriptions (`D.TECHS desc`) are updated
to say what they open, not a flat bonus. Until the goods exist (step 5), the products
factor reads 1.3 for the tribe that knows `tools`, so the balance holds.

**Inventions get a `kind` of use**: `technique` (permanent, `inv.mul` as now) or
`product: <good id>` (the invention lets the tribe make that good; its effects move to
the good). `Cultures.validate()` accepts the new key; `docs/CULTURES.md` describes it.

### 3.3 Needs, and which job serves which (model §4)

Every job type maps to one need, so hands per need are counted from jobs (data:
`society.json jobs`):

| Need | Jobs and careers that supply it | Demand from | Supply from |
|---|---|---|---|
| food | gather (food), field, tend; hunter, gatherer, farmer, fisher, herder; tools made for food work | N × c × season × cooking | workers' rates × h, bounded by land; stores (C_now, C_horizon) |
| shelter | build (homes), renovate; builder | N × (1 + margin) | `pop_cap()` (beds) |
| warmth | gather (wood), the fires' upkeep; woodcutter; cloth | N × cold exposure (season, night, weather: `hz.cold_rate_as`) | warm places of `serving("warmth")` × fuel (`out_of_fuel()`) |
| health | heal (new), aid; healer (new) | incidence (from `events.json sickness`: base, winter, crowding, hunger) × N × care | healers × patients each × medicine |
| safety | guard (new), attack, spar; warrior; weapons made | `max(vigilance × N, rivals.threat())` | standing strength: warriors × arms × skill × walls |
| order | the Steward's and council's work (new: `keep_order`); keeper (new) | `a × N × (N/N₀)^k` past N₀ = 50; institutions needed past 150 | keepers × span (the Code, the Council Ring multiply span) |
| knowledge | teach (new), ritual (lore), experiment; shaman, elder (new) | learners (children, newcomers, people without a known method) × days to teach + keepers wanted per method | teachers × pupils each |
| comfort | craft (goods), cook; artisan, potter, weaver, cook (new) | N × wants(level) × wear | makers' rates |
| spirit | ritual (rites), festivals; shaman | N × wants(level) | shamans × congregation × temple |

New job types join `sim.JOB_TYPES` (`craft`, `heal`, `teach`, `guard`, `keep_order`),
each with its `do_*` function in the subsystem that owns it, and `check_invariants()`
learns their rules.

**Stocks and their upkeep** (model §3.1): the shelter need's hands are builders on homes;
the safety need's are the guards' training and wall upkeep; goods' upkeep (tools wear) is
charged to the need the good serves, through the `serves` of the good in data.

**Safety's threat** comes from a new `rivals.threat()` (the strength of the band most
likely to come over the horizon, from each clan's size, hostility and raid timer, and our
wealth): the pressure stays in `rivals.gd`, as the model says.

### 3.4 The channels: where each hooks in (model §5)

| Channel | Hook | Today's code it scales |
|---|---|---|
| mortality | `soc.death_mult(cause)` | starvation damage, cold damage (`hz.cold_rate`), sickness damage, raid deaths (the defenders' strength) |
| labour | `soc.work_mult(u)` in `sim.work_mul(u)`; `d` through who is sick | order's waste, warmth's chill, the `known` factor is already in `work_rate` |
| consumption | `soc.hunger_mult()` in the hunger rate | the cookhouse's coverage lowers c |
| losses | `soc.loss_mult(kind)` | spoilage (`sim.gd` spoil line), fire spread, raid loot, strife's damage |
| growth | `soc.birth_mult()` in `sim.birth_rate()`; `soc.leave_chance()` in `life.gd discontent`; `soc.comers()` for wanderers | births by the standard and food security (C_horizon), gated by beds; departures and migrants by the standard (§3.8) |
| contentment | `soc.mood_term()` in `folk.mood_target()` | the standard against the wants (model §10); replaces the decor/treasure terms in time |

Crowding is a link (model §4.2): shelter's shortfall raises health's demand through
`incidence_mult()`, read by the sickness roll in `hazards.gd`; it no longer also tapers
births directly (births read the standard and food security instead).

### 3.5 Allocation (model §8)

`sim._update_vice` today: `steward_needs()` (a gap per resource), `_pick_need()`
(weighted by gap² × weight), `careers.go_work()`, the leisure fallback.

Becomes:

- `soc.weights(u)`: for every need (and for each good inside comfort and the products),
  `V_need × N_affected × ΔB`, with ΔB from `society_model.gain(C, s, D)` and s the supply
  this person would add (their `work_rate` × h, in the need's unit). Food sums its two
  windows (model §8): the now term (C_now, s_now, D_today) under V_now, the horizon term
  (C_horizon, s_horizon = the persistence forecast's increment, D_horizon) under
  V_horizon with the δ discount to the forecast's run-out day.
- `_pick_need()` becomes **the greatest weight, recomputed after each hand**: the Steward
  places the idle one by one, each placement lowering its need's ΔB before the next
  (model §8; a random pick in proportion to the weights, today's rule, settles at other
  shares than the calculator predicts). Ties go to the nearest work. Each choice maps to
  its assignment verb (`assign_field`, `assign_gather`, `assign_build`, `assign_craft`,
  `assign_heal`...).
- The **channel values** V come from `society.json values`, scaled by the Steward's
  policy (`steward.policy` today: "food first" becomes a higher value on food's channels).
- **What it replaces**: the `needs` targets and weights of `vice.steward`, the `autumn`
  food target (food's horizon term does it), `leisure_below` (a need covered has 0 weight;
  with every weight 0, people rest or take an idle act), the art/lore fallback.
- **Careers** keep their part: a holder goes to their trade while its need has a weight
  (`careers.go_work`: "while its resource is needed" becomes "while its need's weight is
  above zero").
- **The building plan** (`improve.gd`, the 16 entries of `improvements.list`) moves to
  needs in a later step (§4 step 10): it builds for the need whose capacity gap weighs
  most (beds for shelter, stores for food's C_horizon, fires for warmth, the shrine for
  spirit...), choosing the best type the tribe can make. This is simplify.md §2.

### 3.6 Indoor work (model §2, §8)

- A new job `craft` (and `heal`, `teach` done at a building): the person walks to their
  home (a hut's craft place, `structures.json craft_hands`) or a workshop with a free
  place, and goes **inside**: `u.inside = struct id`, hidden like sleepers in huts
  (`in_hut` generalises to `indoors(u)`), counted as warm (`near_warmth`), ignored by
  beasts, roused by danger as sleepers are (`sim._danger_near()`, `nat.alarm()`).
- **Workshops** are buildings with `craft: {good: rate_mult, hands}` (data): a potter's
  yard, a weaver's hall, a smithy (beside the smelter), a cookhouse (`service: cook`), a
  healer's house. Baked models (`art_baker.gd`, bump `ART_VERSION`), procedural fallback.
- **The day**: indoor work is not in `beds.day_only`; with the clay lamp it may go on
  past dusk (`society.json indoor.lamp_hours`). Night rest still applies otherwise.
- **Winter** needs no rule: fields yield 0, so field weights are 0 and hands go to indoor
  needs.

### 3.7 Goods (model §3.1, §4)

- New resource ids in `D.RESOURCES`: `tools` first; later `pots`, `cloth`, `medicine`;
  comfort keeps `goods`. Each is a word in the HUD stock bar, the trade panel, the
  culture validator and `test_spend`.
- `society.json goods.<id>`: `cost` (inputs, paid with `sim.spend()`), `work` (seconds a
  piece), `wear` (per user per day), `serves` (the need its upkeep counts in), `uses`
  (the kinds of work it multiplies), `max` (the multiplier at full coverage), `per_head`
  (the target), `when` (a `story.holds` condition: the tech or invention that opens it).
- Wear runs on `soc`'s clock: `stock -= users × wear × dt / DAY_LEN`, never below 0.
- Coverage per tribe in the first cut (model, settled); per settlement later.

### 3.8 The standard, people, levels and wealth (model §7, §10)

| Model | Change |
|---|---|
| wants per level | `society.json wants` by tier (camp, village, town, city: `rules.json tiers`) |
| the standard | `soc.standard()`: mean coverage of the wants (basic needs + comfort + spirit) |
| births | `birth_rate()`: `min_food` → food security (C_horizon above the buffer); the rate × a response to the standard (`births.standard`: moderate); beds still gate it; `crowd_taper` stays only as the bed gate |
| departures | `life.gd discontent`: reads the standard below a floor |
| wanderers | `rules.json births.wanderers`: the standard against the neighbours' (rivals' size and mood as a proxy) |
| levels | `rules.json tiers` gain `standard` and `output` conditions (new `story.holds` keys, types in `COND_TYPES`) |
| wealth | `soc.wealth()`: stock and goods at `folk.trade.value`, buildings at cost, knowledge (each tech's cost × share of knowers), treasures; `soc.output_per_head()`: value of what was made per person-day, from `sim.give()` and the crafts' outputs, averaged over a day |
| rivals read wealth | `rivals.threat()` and trade rates take `soc.wealth()` |

### 3.9 For a game master and the LLM

- `soc.summary()`: per need {demand, supply, coverage (now, horizon, alloc), hands,
  weight, floor}, d, h, R, K, the standard, wealth, output per head, the level's binding
  constraint (the need with the lowest coverage relative to its floor). Added to
  `evo.world_ctx()` in words, capped (`words_max`, as careers).
- Story actions (typed in `story.ACTION_TYPES`): `need_value {need, mult, days}` (a
  festival season weighing spirit, a war footing weighing safety), `want {good, per_head}`,
  `give_goods` through `sim.give()`. Conditions: `coverage {need: min}`, `standard`,
  `wealth`, `output`.
- `soc.assign(u, need)`: send one person to a need (the verb the Steward uses), clamped and
  whitelisted like `improve.order`.
- `test_boundaries` throws junk at all of them.

## 4. Order of work

Each step: config, zh texts, tests, a doc note (README, CONFIG, the ROADMAP's log), the
metric bands. The first milestone (steps 0-5) is the economy's core: it makes "fewer
farmers, more makers" real. Steps 6-9 recast the other needs; 10-11 finish the model.

| # | Step | Changes the game? | Done when |
|---|---|---|---|
| 0 | **The calculator** (built 2026-11-26, results in society.md §14): `society.json` (first numbers), `society_model.gd`, `tools/society_calc.gd` with the periodic year and `--fit` | no | it prints the share table (model §6) within a few points at the four sizes, with fitted channel values and wants that look sane (the City row provisional); `test_society_model` checks the pure formulas (benefit, gain bounded and 0 at C ≥ 1, the two-window food weight, the persistence forecast) |
| 1 | **Measure the game**: in `tools/metrics.gd`, the time budget (h), food per worker-day by source, hands per need (jobs mapped by `society.json jobs`), R per run | no | the numbers next to the calculator's for the same size; the gap is the tuning list |
| 2 | **`sim.soc`, read only**: needs, coverage, channels computed but not hooked; `summary()`; the Society panel | no (reads only) | coverage finite and in range in `check_invariants()`; hands sum to the workers; `test_smoke` with it on; the panel in a `--demo` screenshot |
| 3 | **One production formula**: `work_rate()`, the skill curve, traditions as data, the passive field yield gone, field hands' curve; tuned to the R bands | yes | R per era in its band (metrics, 8 seeds); the 12-day bands hold; canary baseline rewritten |
| 4 | **Allocation by the model**: `soc.weights()` replaces `steward_needs()`; food's two windows; the greatest-weight pick; the art/lore fallback gone | yes | winter stores at day 55 as good as now (150-day runs); the autumn rush starts when the harvest window opens; a healthy winter sends the hands indoors; no need pulls more than its share at C ≥ 1 |
| 5 | **Tools, the first good, and indoor work**: the `tools` resource, `craft` job, `indoors(u)`, wear and coverage, the toolmaker career, `has_tech("tools")` → coverage | yes | toolmaker payback 1.5-3× measured; field hands fall to ~0 in winter and craft hands rise; nobody indoors freezes; perf at 1,000 within `test_perf` |
| 6 | **Health, warmth, shelter recast**: healer and `heal` job, medicine (herbs), cloth (hides; the bone needle a product), crowding as incidence, the channel hooks for mortality and labour | yes | deaths by cause no worse; sick days fall where healers stand; the near-miss band holds |
| 7 | **Order and knowledge**: keepers and `keep_order`, span by the Steward/council/Code, order's waste on `work_mul`, the two thresholds; `teach`, the `known` factor, the elder career | yes | a town past 150 without the Code loses work and mood (measured); a method spreads in N days; an oral loss costs measurably |
| 8 | **Comfort, spirit, the standard**: wants per tier, goods consumed, `soc.standard()` into mood, births, departures, wanderers; the potter, weaver, cook; the cookhouse lowers c | yes | the standard 60-90% in steady play; births follow it moderately (no famine bounce); comfort + spirit hands near the share table |
| 9 | **Safety**: `rivals.threat()`, standing strength, vigilance, the `guard` job, the War Chief reading the need | yes | raid deaths per 150 days no worse; a rich town keeps more guards |
| 10 | **The building plan by needs** (simplify.md §2) and the workshops' models | yes | the 16 hand-ordered entries gone; beds, stores and fires keep pace as now |
| 11 | **Wealth and levels as ceilings**: `soc.wealth()`, output per head, tiers that ask for them, the chronicle's words; the long game | yes | three 150-day runs: R climbs through the bands by era, the food share falls to ~25% at 500, walking ~30%, the plateau at each level until its methods arrive |

**The subset first**: steps 0-5 (food, tools, indoor work, allocation) stand on their
own: a tribe that farms with fewer hands and spends the rest making tools indoors, with
the other needs on their current rules. Steps 6-7 (health, order) are the next pair,
since they carry the cost of scale.

## 5. Tests

| Test | Checks |
|---|---|
| `test_society_model` | the pure formulas: B, gain bounded by 1 - B and 0 at C ≥ 1, demand with k and N₀, the two-window food weight (zero with both windows covered), the persistence increment, payback |
| `test_society_needs` | a sim with known people and buildings: each need's demand and supply; hands sum to the workers; coverage in range |
| `test_work_rate` | the factor product for a few people (known vs unknown method, skill levels, tools coverage) |
| `test_allocation` | a covered need gets no hands; a winter field gets none; full granaries in winter send the hands indoors; the horizon term pulls hands in autumn; a tiny need doesn't pull from food; greatest weight with recompute spreads the idle |
| `test_indoor` | a crafter inside is hidden, warm, ignored by a wolf, roused by a raid |
| `test_goods_wear` | tools wear with users, coverage falls, the Steward sends a maker |
| `test_boundaries`, `test_spend`, `test_translations` | the new actions, conditions, config texts |
| `check_invariants()` | coverage finite; no negative goods; `u.inside` points at a standing building; hands per need ≤ workers |
| `test_perf` | 200 people with `soc` on, within budget; `tools/perf.gd` at 1,000 |

## 6. Risks

- **Balance moves a lot at steps 3-5.** Each is measured against the calculator and the
  bands before the next; the canary baseline is rewritten after each, on purpose.
- **The Steward's rule changes twice in a week** (the need rule, 2026-11-25, then this).
  Step 4 keeps the rule's idea (a weighted gap) but derives the weights and picks the
  greatest, recomputed after each hand, so the behaviour the need rule fixed (shortages
  pull hands, plenty releases them) carries over without its randomness.
- **Overlap with the building plan work** (simplify.md §2): step 10 is that work; agree on
  it before starting.
- **The HUD gets a panel**; the top bar gets one word (the standard), no more.
- **Old saves**: new state is lowercase and saved by reflection; a save from before loads
  with `soc` defaults and recomputes on its first clock.
- **Hidden indoor workers** are invisible to the player: the hut shows a craft mark and
  smoke, and the panel lists who is inside.

## 7. Open implementation questions

1. **Coverage per tribe or per settlement** from step 2? Per tribe is the first cut;
   outposts then share the village's healers and tools.
2. **Do inventions get knowers?** Techs have them; inventions don't. The `known` factor
   reads techs only at first.
3. **Where do hides and clay come from?** Hides from butchering (a by-product of the
   carcass), clay as a find (`D.FINDS`); both new resource words.
4. **The Steward or everyone**: today only a Steward hands out work. Should `soc.weights()`
   also guide people with no Steward (each picks their own work by the same weights), so a
   tribe without one still specialises?
5. **How visible is the model?** The Society panel shows coverage per need; does the
   player also see the hands per need and the weights, or only the outcomes?
