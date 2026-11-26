# A model of the tribe as a society: needs, capital and levels

Draft 5, 2026-11-26. A model to get right before any code. Draft 1 (`economy.md`)
modelled the food economy; draft 2 made food one case of a general model; drafts 3 and 4
fixed its units and double counting after two reviews; draft 5 is a two-model brainstorm
(claude and pi, three rounds): R as the food share, a budget that multiplies
to ×3, order's two thresholds, a growth channel, food's two-window allocation weight,
health's climb as care; then a pass against the other docs (walking's hunger, the City
row, culture packs and the budget). §13 lists what is settled and what is open.

The question: as the tribe learns, fewer hands are needed for food, and the freed hands
make the tribe richer, healthier, safer, better kept. How much richer, at what cost, and
what makes a tribe climb from a band to a town instead of only growing bigger? One set of
parameters, from which the levels emerge.

**This is a gameplay curve, not history.** Pre-industrial societies kept 60-80% or more
of their labour on food even in early towns. The model lets productivity climb faster
(one food worker feeds ~1.5 people in a band, ~4-5 in a town) so progression is visible.

## 1. The shape of the model

```
   LAND (natural)   CAPITAL (buildings, goods)   KNOWLEDGE (methods)   SKILLS   ORDER (social)
          \                    |                        |                /          /
   LABOUR (hands) --> TIME BUDGET (a day: rest, meals, walking, WORK) --> production formula
                                               |
          supply to nine NEEDS: food, shelter, warmth, health, safety, order,
                               knowledge, comfort, spirit
                                               |
                         COVERAGE of each need: C = S / D (no units)
                                               |
          six CHANNELS: mortality, growth, labour, consumption, losses, contentment
                                               |
          END STATE: people (born, dead, come, gone), output per head, standard
                                               |
     feeds back: people are hands and demand; some demand grows faster than people
     (scale); output builds capital; the standard drives births and migration
```

Six ideas carry it:

1. **Labour is the one scarce input**, counted in person-days. Every need is met by
   hands, directly (a healer) or through what hands made and keep up (a hut, a tool).
2. **A day is a time budget.** Work is what is left after rest, meals and walking; the
   walk is the cost of distance, paid in time (h) and in hunger (c), and nowhere else (§2).
3. **Every need has the same shape**, in its own unit: demand, supply, coverage, benefit
   (§4, with the unit table in §4.1).
4. **Every effect goes through six channels**, each counted once (§5).
5. **Some demand grows faster than people** (§6): the cost of scale.
6. **A level is a regime with one binding constraint** that the next level's methods
   relax (§7). Between levels the tribe meets a ceiling, not a timer.

## 2. Labour, time and consumption

- **N, the people.** A person in the simulation stands for a family line (one unit; no
  ageing, no mates). **N always counts these units**, children included, and every "per
  head" in the model is per unit. Workers are the units of working age who are not sick,
  badly hurt or away; **d** is computed inside the simulation from those counts, not an
  abstract demographic multiplier.
- **Consumption**: hunger falls 0.33 a second (~30 a 90 s day) and a 3-food meal fills 30,
  or 38 once the tribe has fire, so **a grown-up at rest eats ~2.3 food a day** (~3 before
  fire). **Walking adds hunger** (`survival.walk_hunger`, 0.004 a pace at ~58 paces a
  second): a working grown-up who walks ~60% of their working time eats ~25% more. So the
  working figure is **c ≈ 3 food a day** (to be measured, §12), ×1.25 in winter; a child
  eats 0.6 of the hunger at rest. ~25 food a year (8 days). (city_proposal.md's "2.3 food
  per person per day" is the at-rest figure.)
- **Dependants**: children, the sick and the badly hurt eat and don't work. **d** =
  adult-equivalent mouths per worker — (grown-ups + 0.6 × children) / workers — ~1.2-1.4
  in a growing tribe (a child's mouth is 0.6, so d sits a little under people-per-worker).
  Health and safety move d. Workers are counted directly (above); d is for eating —
  food's demand, R and the stores (§3.2, §4.1) — never for the worker count.
- **The time budget of a working day** (seconds of a 90 s day):

  `H_awake = 90 - rest` (~70) → `H_work = H_awake - meals - life` (~55) → `h = H_work - walk`

  **h** (time actually at work) is an **output**, not a parameter. **Base rates are per
  second at work**, so they never include walking, and h changes only through the walk
  (or a longer working day: lamps for indoor work). Today the walk is 58-65% of working
  time (measured): h ≈ 20-25 s.
- **The walk** = trips × distance / speed. Distance grows with the settlement's spread
  (radius ∝ √ of its built area, ∝ N^0.35 under §6's density assumption) and with how far
  out the work is: the worked land grows with people, so its radius ∝ √N (the nearest
  land is worked first). Roads (speed), oxen and carrying frames (load, so fewer trips),
  granaries by the fields and workshops at home (distance) shorten it. **Transport is
  not a need**: it is the walk term of every kind of work, and its methods raise h.
- **Every need is reckoned in person-days of work** through its labour cost (§4.1), so a
  town's economy is one budget of hands: the share of them that goes to each need (§8).

## 3. The factors: capital and labour

Five kinds of capital multiply what a second at work yields. Each grows and decays,
which is what makes it a stock worth building and keeping.

| Capital | What it is | Grows by | Decays by |
|---|---|---|---|
| **Natural** | wild food, game, forest, soil, fish, finds, within reach of home | regrowth (bushes, herds) | harvest (diminishing returns), over-harvest (depletion), clearing |
| **Physical** | buildings, goods in use (tools, pots, cloth, weapons) | building, making | age, wear with use, fire, raids |
| **Knowledge** | methods (techs) and techniques (inventions), held by people | practice → insight, teaching, lore | the death of its last keeper, unless codified |
| **Human** | skills (levels, ranks) | practice, a trade done all day, teaching | death, departure |
| **Social** | order, trust, bonds | keepers of order, festivals, shared hardship | crowding, strife, unfairness |

**One production formula for every kind of work** (food, building, making, healing,
guarding, teaching), per second at work:

`rate = base(method) × known × products × skill × techniques × culture × land`

and output per person-day = `rate × h`.

- **base(method)**: knowledge opens a way of working and sets its rate: the steps between
  levels (gathering → fields → the plough → irrigation).
- **known**: 1 for a worker who knows the method (`evo.knows`), **0.5** for one who
  doesn't: they pitch in clumsily while they learn (§13).
- **products**: the coverage of the goods this work uses (tools for fields and building,
  weapons for guarding, medicine for healing), capped by its budget share.
- **skill**: one concave curve for all work, **×1.0 at level 0 to ×1.4 at level 10**.
  Specialists sit near the top: the gain from the division of labour.
- **techniques**: know-how inventions (smoking meat, bone setting), small and permanent.
- **culture**: a tradition's leaning, ×1.0-1.2 on one kind of work.
- **land**: the natural capital drawn on, with diminishing returns (§3.2).

**The productivity budget.** From band to town, food output per worker-day rises ×3
(R 1.5 → 4.5, §7), so **the sources must multiply to 3**, not each be tuned on its own.
The central allocation:

| Source | Band → town | Note |
|---|---|---|
| methods | ×1.6 | fields, the plough, irrigation |
| products | ×1.3 | stone then bronze tools at full coverage |
| skill | ×1.2 | the typical food hand's factor rising ~×1.08 → ~×1.28: a band generalist to a town hand at its trade (specialists sit higher still) |
| techniques | ×1.05 | small, many |
| culture | ×1.0 on average | a tradition is a *leaning* (×1.2 on one kind of work, nothing on the others), not a general gain |
| the walk (h) | ×1.15 | walking from ~35% to ~25% of work time (§6) |
| **product** | **×3.0** | |

Each source is capped at its share; a config whose product drifts from ×3 by more
than ±0.3 is a config error the calculator reports. (Draft 3's ranges multiplied to
×2.7-4.6, ×3.6 in the middle: too loose to tune by.)

**Culture packs draw on the same budget.** A pack's inventions, foods, finds, boons and
tales change work rates through the shared effects (`docs/CULTURES.md`: `gather`,
`yield`, `work`, `build`...), and CULTURES.md asks for 1.2-1.4× per invention. Five such
gathering inventions would multiply to ~×3 on their own, the whole climb. So a pack's
effects are counted in the share they belong to: an invention that is a product (§9) in
the products share, a technique in the techniques share, a boon or a tale in culture.
The calculator reads the pack as well as the base game and reports a pack whose effects
push a share past its cap, as `check_culture.gd` reports a malformed one. Packs keep
their character (a fishing people's hooks are strong) because the cap is on the share,
not on each entry: one strong fish hook fits, five gathering bonuses don't.

**known and land are not sources of the climb.** The budget assumes known = 1 (the
level's food hands know its methods) and the land factor held constant, not depleted.
Both are ways to *lose* the climb — an unknown method works at 0.5, tired land at less —
and the calculator reports them as shortfalls, never as productivity.

### 3.1 Capital is not a need: its upkeep is charged to the need it serves

Tools, pots, huts and walls are not needs of their own. Each capital stock has a
**derived demand**: what keeping it at its target takes,

`upkeep hands = (stock × decay + growth of the target) / make rate`

and those hands are **counted in the need the capital serves**: knappers making farm
tools are food hands, builders of huts are shelter hands, smiths making spears are
safety hands. So every hand belongs to exactly one need, and the share table (§6) adds
up.

**Tools that make tools.** Toolmakers use tools too, so the tool economy is a fixed
point: more tools → faster toolmaking → more tools. It is bounded because the products
factor is capped at its budget share (×1.3 for farm tools at full coverage) and one
maker supplies many users (payback > 1, §8);
the calculator solves it by iteration.

**A building is one of two things, never both**: the **capacity** of a stock need (beds
in huts, the stores of a granary, a fire's warm places) or a **multiplier** in the
production of a flow need (a wall multiplies each guard, a temple each shaman, a
workshop each maker).

### 3.2 Land: why one farm feeds only so many

- **The labour limit**: a worker makes F food a day (rate × h), enough for **F / c
  mouths**. Since each worker comes with d mouths (themself and their share of the
  dependants), one food worker carries **R = F / (c × d)** workers with their families.
  R is the inverse of the food share: **food share of the hands = (1 + m) / R**, where m
  is the margin for spoilage and the winter store (~0.05-0.1). The share table (§6) and
  the R bands (§7) are the same numbers read two ways: R 1.5 → ~70%, 2 → ~53%,
  3 → ~36%, 4.5 → ~24%.
- **The land limit**: a source yields at most **Y** food a day however many work it (a
  bush regrows only so fast, a field holds only so much soil). The land within reach of a
  settlement holds at most **K = ΣY / c** people: its **carrying capacity**.
- **Diminishing returns** on the same patch: the n-th hand adds less than the one
  before, approaching Y. And the nearest land is worked first, so each new field or patch
  is farther out (the walk, §2).
- **Depletion**: over-harvest past regrowth degrades the patch (game thins, soil tires)
  until it is rested (fallow) or left. Bounded: a patch recovers when rested.

**The farm.** How many people live on one field with one farmer has two numbers:
`min(F, Y_field) / c` mouths, or R families' workers. With the design's numbers
(c = 3, d ≈ 1.25) one farmer on one family plot feeds ~2.6 mouths at the camp level
(F ≈ 8; R ≈ 2.1), ~3.9 in a village (F ≈ 12; R ≈ 3.2), ~5.9 in a town (F ≈ 18; R ≈ 4.8),
mouths counted with the farmer's own family among them (§7). More hands on a field get
closer to Y_field, at less each.

Today a field yields food on its own, worked or not (~3 people fed per field with no
hands). In the model that goes: food is work on land, under both limits.

**Foraging has a low K.** Wild food regrows slowly; the band strips what is near, walks
grow, output falls. That is what pushes a growing band to fields, and what makes moving
on or farming a real choice.

## 4. A need

Nine needs, each with the same parts:

1. **Unit**: each need has its own (§4.1). It is either a **flow** (food a day, care-days
   a day) or a **stock** (beds, warm places, defence strength).
2. **Demand D** in that unit, growing with the people it serves, for some needs faster
   than people (§6), and with the level's wants (§10).
3. **Supply S** in the same unit, from workers (a service), goods (that wear) or
   buildings (capacity, or a multiplier on workers: §3.1). A stock need's supply is the
   capacity standing; its labour is building and upkeep.
4. **Labour cost l**, in **person-days per unit of supply**: `l = 1 / (output of one
   person-day)` = `1 / (rate × h)` for a worker's own output (in the need's unit per
   second at work, times seconds at work a day). For a service, a person-day's output is
   the people it serves a day (`span`, patients, pupils, congregation); for a stock, it is
   the units a person-day builds and keeps up. A flow's S is per day, so **hands for a need
   = S × l** is in person-days per day = workers; a stock's hands are its upkeep and growth
   (§3.1) × l. Summed over needs, the hands are the workers of §2 — the 100% of the share
   table (d is mouths for eating, not the worker count). This is the one conversion
   between a need's unit and person-days, and h lives only inside it.
5. **Coverage C = S / D**, a pure number. Above 1 is surplus, with no further gain.
   **A storable need has two coverages**:
   - **C_now** = `(stores + S_today) / D_today`: what is there to eat now. It drives the
     channels (mortality, contentment) and the hardship (famine).
   - **C_horizon** = the **lowest running coverage over the horizon**: for each day ahead,
     (the stores, spoiling, + the expected supply up to that day) / (the demand up to that
     day), at its worst day. A ratio over the whole window would hide a gap in the middle
     (the fields' spring yield counted against the winter before it), and the stores
     spoil while they wait (§14). It is an **anticipation signal
     only**: it drives no channel and no hardship — it enters food's allocation weight as
     the horizon window's term (§8) and sets the food security that births need (§10).
     The **harvest window** is the last season in which the fields and the wild yield
     before one in which they don't (autumn, with the seasons as they are; the hunt,
     fishing and the pens yield through the winter, which is what makes them the
     winter's sources, §8). The horizon rolls **through the next lean season, to its end**
     (the first day after the season that follows the harvest window), clamped to 6 days:
     from summer it sees the coming winter, in winter it reaches only to spring. Because
     C_horizon is the worst day's coverage and credits the harvest to come, summer pulls
     hands to food only when the harvest won't carry the winter; an earlier horizon that
     ended at the harvest left summer hands idle while winter went short (§14).
6. **Benefit B(C) = 1 - (1 - C)²** for C < 1, 1 above: concave, the first healer matters
   most. **Each channel the need feeds takes the shortfall `1 - B(C)` smoothly**: no
   cliff anywhere in the rules.
7. **Hardships** (famine, an epidemic, strife, a raid that breaks in) are discrete
   events, in two tiers:
   - **Friction**: the smooth channel penalty `1 - B(C)` begins as soon as C < 1. A
     minor deficit is felt, never a disaster.
   - **Hardship**: an event becomes possible only below **C_floor ≈ 0.6** (0.5-0.7 per
     need); its rate rises linearly from 0 there to its maximum at C = 0, and the director
     paces it as now. For food, famine needs C_now < C_floor, and its warning (an alert, the
     council) comes when C_horizon falls below a safety buffer.

   The channel penalty and the event rate are the only two ways a shortfall acts.

### 4.1 The unit table

| Need | Kind | Unit | Demand D | Supply S | Labour cost l | Channels |
|---|---|---|---|---|---|---|
| **Food** | flow, storable (C_now, C_horizon) | food / day | c × d × workers × season × cooking (the cookhouse lowers c; a child's mouth is 0.6 of c, folded into d, §2) | Σ food workers × rate × h, bounded by land (Y) | 1 / F, F = rate × h | mortality (starving), growth (births' food security: C_horizon), consumption (cooking), losses (spoilage: pots, granaries), contentment |
| **Shelter** | stock | beds | N × (1 + margin) | Σ `cap` of homes standing | build + upkeep per bed | growth (births need beds), health (crowding raises sickness incidence), contentment |
| **Warmth** | flow, seasonal | warm person-hours / day in the cold | N × hours of cold exposure × cloth (cloth lowers exposure) | warm places of fires and hearths × hours; fuel | wood per warm hour / wood rate | mortality (freezing), labour (the cold slows) |
| **Health** | flow | care-days / day | cases (incidence × N, raised by density, crowding, hunger, cold) × care per case (a level's want, §6) | healers × patients per healer-day × medicine | 1 / patients per healer-day | mortality, labour (sick days, and d) |
| **Safety** | stock against a pressure | defence strength (the same unit as a war band's strength) | max(vigilance, expected threat): the strength of the band likely to come over the horizon (`rivals.gd`'s threat query), and never below a vigilance floor per head | strength standing: guards on hand × arms × skill × walls (a multiplier), decaying (training lapses, walls age) | 1 / strength a person-day trains and keeps up | losses (raids), mortality |
| **Order** | flow | order-work / day (disputes, coordination) | coordination `a_c × N` once a Steward exists (camp and up; the band shares the role) + disputes `a × max(0, N - N₀) × (N / N₀)^k` past the face-to-face limit (§6) | whole keepers × span — an informal keeper's span shrinks past N₁ ≈ 150, an institution's doesn't; the Code multiplies span (§6) | 1 / span | labour (waste), losses (strife), contentment |
| **Knowledge** | flow | teaching-days / day | learners (children, newcomers, new methods × people to learn them) × days to teach, plus keepers wanted per method | teachers × pupils each; codification ends the keepers' part | 1 / pupils per teacher-day | labour (the `known` factor), losses (a method lost) |
| **Comfort** | flow (goods wear) | wanted goods / day | N × the level's wants × wear | makers × rate | 1 / F_maker | contentment |
| **Spirit** | flow | rite-hours / day | N × the level's wants | shamans × congregation × temple | 1 / congregation per rite | contentment (and devotion) |

**Safety: a stock against a pressure.** Its C compares two strengths in the same unit:
the defence standing now (S, a stock that decays without upkeep) against the strength of
the threat expected over the horizon (D, a pressure that rises with our wealth and the
clans' state). So C = S / D is a ratio of strengths, not of rates. Two things keep a safe
town vigilant: D never falls below a **vigilance floor** per head (a watch is kept even in
peace), and S decays, so upkeep goes on at C ≥ 1; and as raiders grow, D rises and C
falls, pulling hands back before the raid comes. **The boundary**: the threat pressure
(how often and how strong raids come, from our wealth and the rivals' state) stays in
`rivals.gd` as a threat query; this model owns how the tribe prepares for and absorbs
it (guards, walls, weapons, coverage, raid losses).

### 4.2 Counting each effect once

The rules that keep the model from double counting:

1. **Each supply serves one need.** The cookhouse is food (it lowers c); pots and
   granaries are food (losses: spoilage, capacity); cloth is warmth (it lowers exposure);
   tools serve the need whose work uses them. **Comfort** holds only goods whose sole
   effect is contentment (ornaments, decor, fine wares), so a cooked meal is not also a
   comfort.
2. **Capital upkeep is charged to the need it serves** (§3.1).
3. **Walking has two costs, each counted once**: the time it takes, in h (§2), and the
   hunger it adds, in c (§2). They are different effects (a working day lost, food eaten),
   so a road that shortens the walk pays twice, once in each. Nothing else charges for
   distance.
4. **A shortfall acts only through its need's listed channels** (§4.1), smoothly by
   1 - B(C), plus its hardship's event rate.
5. **Crowding is a link, not a double cost**: shelter's shortfall raises health's
   *demand* (incidence); it doesn't also hit mortality directly.

## 5. The six channels and the end state

| Channel | What it changes | Fed by |
|---|---|---|
| **Mortality** | deaths a day | food, warmth, health, safety |
| **Growth** | births, families who leave, migrants who come | shelter (births need a bed), food (security: C_horizon), the standard (§10) |
| **Labour** | hands (sick days, d) × how well they work (`work_mul`) | health, warmth, order, knowledge |
| **Consumption** | food and goods used per head | food (cooking, spoilage) |
| **Losses** | capital destroyed: raids, fires, strife, rot, a method forgotten | safety, order, knowledge, food (spoilage) |
| **Contentment** | mood: the standard against what is wanted (§10) | food, shelter, order, comfort, spirit |

The end state is three numbers: **people** (moved by mortality and growth), **output
per head** (the value of a person-day, at trade prices; moved by labour, consumption and
losses), and **the standard** (§10; moved by contentment). The channels make needs
comparable: their values are what the tribe weighs (§8).

**Growth is a channel of its own** (draft 3 had five): beds gate births, food security
and the standard set their pace, and none of those is a death, a loss of work or a mood.
Without it, shelter's effect on the end state had nowhere to go but "contentment", and
the birth response (§10) had no place in the allocation's values.

## 6. Scale: demand that grows faster than people

Each need's demand per head can rise with size:

`D(N) = a × N × (N / N₀)^k`

**a**: the need per head at the reference size N₀; **k**: its scale exponent (0 = in
step with people). Three rows swap N for what the need really scales on — order: people
past the face-to-face limit; health: density; safety: wealth — but the shape
a × X × (X / X₀)^k is the same.

| Need | k | Why |
|---|---|---|
| Food, shelter, warmth, comfort, spirit | 0 | each mouth, bed, warm place the same |
| Health | 0 on N; ~0.5 on **density** | incidence rises with residents per settled area, not with N itself. Density comes from the layout (and rises past the beds as crowding, §4.2), so a town that spreads out pays in the walk instead of in fevers. The calculator assumes settled area ∝ N^0.7 (density ∝ N^0.3) until the layout is measured. Composed: per-head incidence ∝ density^0.5 ∝ N^0.15 — only ~×1.6 from band to town, so health's cost of scale is mild while the beds keep up (crowding, §4.2, is what makes a village feverish) and the walk carries the rest |
| Order | see below | the face-to-face limit |
| Safety | ~0.3 on wealth | a richer tribe draws more raiders and coalitions |
| Knowledge | ~0 on N | grows with methods held and learners, not with size itself |
| (the walk, in h) | ~0.5 | the trip to work lengthens with the worked land's radius (∝ √N: each person needs constant land); trips inside the settlement grow slower, ∝ √(built area) ≈ N^0.35 under the assumption above |

**Order: one threshold on demand, one on supply.** The two thresholds of §13 are
different things and sit on different sides:

- **Demand** begins at the face-to-face limit N₀ ≈ 50 and grows faster than people past
  it: `D_order = a × max(0, N - N₀) × (N / N₀)^k`, k ≈ 0.5. It is continuous at N₀ (no
  jump in disputes when the 51st person is born).
- **Supply** is keepers × span, and **span depends on the kind of keeper**: an
  informal keeper (an elder, the Steward) keeps order among those who know them, so their
  span shrinks past N₁ ≈ 150 (`span_informal × (N₁ / N)` above N₁); an institution (the
  Council Ring, the Tribal Code) has a span that doesn't shrink. So past ~150 a tribe
  without institutions needs ever more keepers for the same order: the village → town
  step is a change of method on the supply side, as every level's step is.

  Keepers are whole hands: the band has none (order is shared), and the first is the
  Steward, whose one hand in ~38 workers is the camp's ~2%. That hand is not outside the
  needs (every hand belongs to one, §3.1): order's demand has a second, small term,
  **coordination**, `a_c × N` from the first Steward on (laying out work and sites,
  advising: the allocation's own running cost), beside the dispute term that starts at
  N₀. At the camp coordination is all of order; past it the dispute term grows past the
  coordination one (where exactly is a fit). The Council
  and the Code must multiply an informal keeper's span about ×1.4 to hold the town near
  9%; without institutions the order share passes 3× the village's by N ≈ 300 and 8× by
  N ≈ 500: the ceiling.

**Why health's share still climbs ×9 when its incidence climbs ×1.6.** Health's hands go
from ~1% to ~9% (the share table below) while per-head incidence rises only ~×1.6 with
density. The rest is not scale but **care becoming possible and wanted**: a band has no
healer's method (its sick rest and recover or die, coverage near 0, its cost paid in
mortality), and **care per case** is a level's want like comfort's (a band expects rest
by the fire, a town a healer's days). So health's demand is
`incidence(density, crowding) × N × care_per_case(level)`, and care per case rises ~×5
band → town. This keeps density mild, as the brainstorm found, and puts health's climb
where it belongs: in what the tribe has learned to do for its sick. The mortality
channel's rate is fitted so the band's near-zero coverage is a slow cost in lives, not a
collapse — its sick mostly rest and recover — and the share table's 1% is the gathering
of simples and tending.

**Methods lower a (or lengthen span, or raise speed), never k.** The Code lets each
keeper serve more; a wall makes each guard worth more; roads make each trip quicker. A
tribe that grows without its level's methods is bigger and worse off.

**The share of hands per need** (design intent, the calculator's first target; every
hand in exactly one need, capital upkeep included):

| Level (size) | Food | Shelter, warmth | Health | Safety | Order | Knowledge | Comfort, spirit | Time walking (of work time) |
|---|---|---|---|---|---|---|---|---|
| Band (~20) | 72% | 15% | 1% | 5% | 0% | 3% | 4% | ~35% (foraging walks) |
| Camp (~50) | 53% | 16% | 3% | 7% | 2% | 5% | 14% | ~30% |
| Village (~150) | 36% | 13% | 7% | 10% | 5% | 7% | 22% | ~35% (spread, before roads) |
| Town (~500) | 25% | 12% | 9% | 11% | 9% | 7% | 27% | ~25% (roads, granaries) |
| City (~1,000, provisional) | 20% | 11% | 10% | 12% | 10% | 7% | 30% | ~25% (outposts' fields far out, roads) |

(The city's food share is below 1/R because ~10-15% of its food is bought or paid in
tribute, §7.)

The freed food hands become partly overhead (health, safety and order from 6% to 29%) and
partly a rising standard (comfort and spirit from 4% to 27%), while the walk first grows
with the spread and then falls with roads. That split is a design choice the calculator
will test (§12). Today's camp walks 58-65% of its working time: the model's target asks
the walk to fall by half through granaries, fields near home and roads.

## 7. Levels: regimes and their binding constraint

A level is the set of methods in use. In each one constraint binds first; the tribe grows
until it meets it (a **ceiling**: carrying capacity, or a need whose coverage falls toward
its floor), and the next level's methods relax it.

| Level | Binding constraint | The ceiling looks like | Methods that relax it | Food R |
|---|---|---|---|---|
| **Band** | wild food in reach (land, K) | walks grow, gatherers come back light, a lean season hungry | fields, fishing, stone tools | 1.3-1.6 |
| **Camp** | the winter (stored food) and food hands | an autumn rush, empty stores by late winter | pottery, granaries, smoking, the bone needle | 1.8-2.2 |
| **Village** | the walk, as the worked land spreads; health where the beds lag | fields far out, the day spent walking; fevers once crowding sets in | healers and medicine, oxen and the plough, roads, the cookhouse | 2.8-3.5 |
| **Town** | order (past ~150) and safety | waste, strife, raids on a rich town | the Council and the Code, walls, bronze, the warehouse, trade | 4-5 |
| **City** (~1,000) | the land in reach (K) again, now for fields, and the winter at scale | fields far past the wall, a winter that burns ~6,000 food, fires and plague in the crowd | outposts as farmsteads, roads, warehouses, trade and tribute (food bought with surplus, `city_proposal.md` §3.1), irrigation | ~5 |

The city is the game's goal (`city_proposal.md`, the City victory), so the model must
reach it, but its row is provisional: the first cut is tuned to the town, and the city
row is checked once the town's numbers hold. At the city the land limit returns: a
thousand people need more fields than the village's reach holds, so food comes from
outposts and from outside (trade, tribute), and that share is food the tribe's own hands
don't make (R counts only the tribe's food workers; bought food lowers the food share
without raising R).

- **Growth is bounded per level**, not by a timer: under a rising ceiling for a tribe that
  learns, at a ceiling for one that doesn't.
- **Climbing is the game**: which constraint to relax next, and how to carry the cost of
  scale meanwhile.

## 8. Allocation: where the next hand goes

**One rule for everyone, the invisible hand.** A need's weight per hand is its **price**:
what one more hand's work there gains the tribe. It falls smoothly to 0 as the need is
covered, so a good in plenty is worth nothing. **Every person works where their hand is
worth most: the price times their own productivity at it** (their skill, and their trade's
edge at their own trade). There are no special cases for a woodpile or a craft: a master
woodcutter turns to food when wood is piled high (wood is worth nothing, food a lot), and
keeps to the trees while wood pays them at least as well as anything else (comparative
advantage). The Steward places the idle by this rule, quickly and counting each placement
before the next; a person with a trade goes to it by themselves only when it is their best
work; and with no Steward the idle choose their own work by it (more slowly). Wanted
behaviour comes from prices, never from a rule for one case.

The Steward's rule (a weighted gap) stays; the model derives its weights.

- **One more hand on a need** adds s units of supply (its rate × h, in the need's unit).
- **Its gain is the actual rise in benefit**, not the slope:
  `ΔB = B(min(1, C + s/D)) - B(C)`, which is bounded by `1 - B(C)` (a tiny need can't
  pull more than what it lacks) and is **0 once C ≥ 1** (no negative weights, no
  over-investing). Food sums two such terms, one per window (below).
- **Its worth scales with the people it affects and with how much the need matters**:
  `weight = V_need × N_affected × ΔB`, where **V_need = Σ value(channel) × impact(need,
  channel)** over the channels the need feeds (per person; food's V splits by window,
  below). The **impact** is how much of the channel the need moves when wholly uncovered,
  against food's: no food kills everyone (mortality 1), untreated sickness far fewer
  (~0.15). Without it a need that merely *feeds* mortality weighs like food, and since a
  small need's per-hand gain is large, healers pulled hands from a starving band (§14).
- **The channel values** are what the tribe values: lives first, then output,
  contentment... The Council's policies set them (a war footing weighs losses and
  mortality from raids; a feasting tribe weighs contentment).
- The next hand goes to the greatest weight, recomputed after each hand (below). Concave
  B spreads hands across needs, and a shortfall pulls in proportion to how bad it is.
- **Payback**: a trade (a need's worker whose output is a multiplier, such as a
  toolmaker) is worth having when its hands free more hands elsewhere than it takes. The
  design band: **1.5-3×** at the trade's typical skill. Below 1 the trade loses hands;
  far above 3 one maker carries the town.

**Which windows the allocation reads.** Every weight is per day, and every need but food
has one window: today. Food has two (§4), and its weight is the **sum over its windows**,
each window pairing its own demand with its own supply — no window's demand is ever set
against another window's supply:

`ΔB_food = [B(min(1, C_now + s_now/D_today)) - B(C_now)] + [B(min(1, C_horizon + s_horizon/D_horizon)) - B(C_horizon)]`

**s_now** is what one more hand yields today (its rate × h). **s_horizon** is what
assigning it there adds to the horizon's supply — the persistence forecast's own
increment: the source's yield for every yielding day the hand would be held there (the
hunt held through the winter; a field through its harvest window, nothing past it). A
delayed payoff — work today, food months off — exists only under a crop cycle (below).
The four behaviours the design asks for:

- **A healthy winter**: both coverages ≥ 1, ΔB = 0, and the hands flow indoors (the
  winter workshop, §12) even though the flow S_today < D_today *by design* — the stores
  are for that gap, and a planned draw-down is not a shortfall.
- **The autumn rush**: C_now ≈ 1 while C_horizon falls as the winter comes into the
  horizon — the horizon term pulls hands to whatever will fill the stores, hardest where
  B is steepest (short coverage).
- **Famine**: C_now < 1 — the now term pulls every source that yields.
- **Short stores in winter**: only the horizon term is live, and only sources yielding
  today gain — the hunt, the fishing, the pens, never the idle fields.

C_now still drives food's channels and famine; C_horizon the births and the horizon
term's pull. There is no storage term, no "productive days left", and no case that
divides by zero.

**Each window carries its own channels, so food is not counted twice.** Summing two ΔB
terms under one V_food would weigh food double against every other need whenever both
windows are short (a famine in autumn). So V splits by window: the **now** term carries
the channels a shortfall today acts through (mortality from starving, contentment); the
**horizon** term carries what a shortfall ahead acts through (growth: births' food
security, and the winter's mortality, discounted by how far off it is: `δ^(days ahead)`,
δ fitted). `weight_food = N × (V_now × ΔB_now + V_horizon × ΔB_horizon)`, and each
channel's value is used once. The horizon term's mortality is **anticipation, not a
second firing**: the channel itself fires once, later, on C_now, when the shortfall
arrives; the horizon weight only forecasts it, and **days ahead** is the days until the
forecast's stores first run dry — the horizon's end if they never do (a shortfall that
never empties the stores is a ration, not a famine). As the run-out day nears, the
discount lifts and the pull strengthens. Births are a rate, not a death, so growth
enters undiscounted. Consumption and
losses sit in neither V: they act through c, the margin m and the stores, not
through either window's ΔB.

**The expected supply inside C_horizon is a persistence forecast**: the food hands
assigned now, held at their current sources to the horizon, with each source's seasonal
yield applied (fields 0 in winter). The calculator and the game both use it, so neither
needs to know its own future plan; the calculator's periodic year then checks that the
forecast and the year it actually runs agree.

**No delayed payoff in the first cut.** Every food source pays as it is worked (fields
yield per worked second, times the season), so s_horizon is the persistence increment
above — s times the source's yielding days left in the horizon — and nothing more: a
field past its window, in winter, is credited nothing, however short the stores. A
**crop cycle** (sow in spring, tend in summer, harvest in autumn, the labour credited at
the harvest) is what a delayed payoff would be for; it is open (§13), not part of the
first cut.

**Why the credit is the whole increment.** The forecast counts a newly assigned hand
at its source for the whole horizon, so the hand's credit must too: at one day's s the
horizon term would be weaker, by the number of yielding days, than the C_horizon it moves,
and the autumn rush would under-fire against the daily needs. With the whole increment
the two windows' per-hand credits sit on one scale (s × days / D_horizon ≈ s / D_today).
The winter workshop does not depend on it: the coverage gate keeps hands indoors; the
credit only sets how hard the hunt pulls when the horizon is short. Holding a hand at its
source is the forecast's assumption, not the game's: hands are re-placed each stint, and
the calculator's drift report (§12) shows what the assumption costs.

**The next hand goes to the greatest weight, recomputed after each hand.** Not a random
pick in proportion to the weights (today's Steward): a proportional pick never equalizes
the hands' marginal gains, so the game settles at shares the model does not predict, and
the calculator would describe a society the game does not play. Spread comes from B's
concavity and the recompute (each hand lowers its need's ΔB before the next is placed),
not from chance; ties break by the nearest work. The calculator and the game use the
same rule. Herding is bounded by the recompute — a need takes hands only until its ΔB
falls level with the next-greatest weight — so a big single-day intake on one need means
a real crisis (a correct stampede), and the calculator reports the largest intake as a
check that it stays rare at the steady sizes.

**Why not a storage term.** An earlier draft folded anticipation into a daily demand
(`D_today` plus the stores' shortfall spread over the productive days left). It read the
stores' planned winter draw-down as a shortfall, so a tribe with full granaries kept
fishing to its land cap instead of working indoors, and it divided by zero when no
productive days were left. The two windows say the intent directly: no pull when both
are covered, a pull in proportion to the gap of the window that is short.

**Seasons move the allocation through s and D.** With the fields idle in winter, the
hands flow to what yields indoors (tools, cloth, teaching, rites). C_horizon falls as the
harvest window opens and the winter enters the horizon, so the rush begins before the cold.
No seasonal rule of its own.

## 9. Knowledge, inventions and skills, in one place

- **Knowledge = methods.** A tech sets a base rate (§3); per person, `known` (1 or 0.5).
  Teaching is the knowledge need; codification (totems, the Code) ends the risk of loss.
- **Inventions are techniques or products.** A technique is a permanent factor; a product
  (digging stick, fish hook, baskets, carrying frame, bone needle, the tools of the
  `tools` and `bronze` techs) is the know-how to make a good, whose effect comes from its
  coverage and which wears, so its making is upkeep (§3.1). The `kind` the game and the
  culture packs already use (`tool`, `goods`, `medicine`, and foods) says what an
  invention is *about*, not how it acts: a `tool` or `goods` invention is usually a
  product, a `medicine` is a product of the health need (medicine, made from herbs) or a
  technique (bone setting), a food (a way of preparing it) a technique. Each entry is
  marked one or the other; the kinds stay as they are.
- **Skills** follow one curve (×1.0 → ×1.4); a trade done all day climbs it fastest.
  Ranks cap it and open fine work (bronze needs `fine_craft`).

## 10. Wealth and the standard of living

- **Wealth** = the value of the tribe's capital: buildings at cost, goods in use, stores,
  knowledge (each method's value × the share who know it), skills, treasures, at the trade
  prices that exist. What the tribe *has*.
- **Output per head** = the value a person-day yields, over the tribe. What it *makes*;
  the best measure of its level.
- **The standard** = the coverage of the level's **wants**: the basic needs (food,
  shelter, warmth) and comfort and spirit. What life is *like*.

**Wants rise with the level**, so contentment is the standard against expectation: a town
living as a camp lived is unhappy. Rising wants are what keep freed hands busy.

**People respond to the standard, moderately**: births above subsistence, departures below
a floor, migrants when above the neighbours'; births also need beds and food security
(look-ahead food coverage). A moderate response lets the tribe enjoy stretches of
stability and accumulation instead of bouncing off famine and epidemic ceilings. The
growth channel's value is fitted to the same shape: births clear deaths by a little
while the ceiling is far, and sit level with them at it (§13).

**Ownership**: one communal store in the first cut; households keeping part of their
trade's output (a ranked culture: an incentive, and inequality as a cost on order) later.

**Neighbours read wealth**: trade grows with it, and so do raids (safety's demand).

## 11. Feedback loops the model should produce

Without a rule of their own:

- **Growth**: surplus → standard → births → more hands and mouths → back toward the
  ceiling.
- **The poverty trap**: hunger → sickness → fewer hands (labour, d) → less food. Ways out:
  stores, a healer, help from outside.
- **Overshoot**: a fast-growing tribe meets winter or a fever above its ceiling and loses
  people back to it (kept rare by the moderate birth response).
- **The scale squeeze**: more people → more overhead → less for comfort → standard falls →
  mood and strife, until the next level's methods.
- **Over-harvest**: a band strips its reach → longer walks, depleted patches → farm or move.
- **Knowledge fragility**: few keepers → a death loses a method → its work at the
  unknown fraction, until taught again or codified.
- **The rich target**: wealth → raids → losses and a larger safety need.

## 12. The parameters, and the calculator

| Parameter | What it sets | Proposed |
|---|---|---|
| c, child eating, d | food a day (grown-up; child 0.6 of c); adult-equivalent mouths per worker | 3; 0.6; d ≈ 1.25 (children ~25%) |
| m, the food margin | spoilage and the store's buffer: the R ↔ share conversion (§3.2) | 0.06 to start (0.05-0.1) |
| the shelter margin | beds above N (guests, growth) | ~0.1 |
| the time budget: rest, meals, life; trips, distance, speed | h | from the day's parts; the walk from geometry |
| settled area ∝ N^0.7 (the density assumption) | health's density; the walk's settlement term | N^0.7 to start (open #4) |
| base(method) per kind of work, per level | the steps | from each level's R band |
| productivity budget shares | each source's part of the climb | §3 |
| known (unknown method) | learning | 0.5 |
| skill curve | the specialist's edge | ×1.0 → ×1.4 |
| Y and regrowth per source; depletion and rest | carrying capacity | foraging K ~30-40 per band's reach |
| a, k, N₀ per need | need per head; cost of scale; thresholds | §6 |
| order demand and supply: a_c, spans, N₁, the Code's multiplier | order's two terms (§6) | a_c fitted to the camp's 2%; N₁ = 150; the Code ×~1.4; spans to 5% / 9% |
| l per need, per level | labour cost of a unit (methods lower it) | from the share table |
| B(C), C_floor per need | concavity; where hardships start | `1 - (1 - C)²`; C_floor ≈ 0.6 |
| food horizon, food safety buffer | anticipation; when food is "secure" | to the next harvest window, ≤ 4 days; buffer ~1.2 over the horizon to start (open #2) |
| δ, the horizon's daily discount | how much less a death ahead weighs than one today (§8) | fitted, ~0.7 to start (open #6) |
| vigilance floor per head | safety's minimum demand | to be set |
| the expected threat at each size | safety's demand beyond the vigilance floor | fitted to the share table's safety column; the game reads `rivals.gd`'s threat query |
| channel values | what the tribe values | mortality > labour, losses > contentment; fitted by the calculator; shifted by the Council's policies |
| wants per level (comfort, spirit; health's care per case) | the standard's bar, and health's care (§6) | 1.0 at the band, rising; comfort + spirit fitted to 4% → 27%, care per case to health's 1% → 9% |
| birth response to the standard | more people vs better lives | moderate |
| goods wear | how much upkeep capital takes | a tool lasts a few days |
| payback band | what a multiplying trade must earn | 1.5-3× |

**The calculator comes first**: a small script that takes this table and, for each level
and size (Band 20, Camp 50, Village 150, Town 500, and the provisional City 1,000 —
children ~25% at each, which sets d),
solves a **periodic steady state over
the year**: it runs the 8-day year season by season (each season's yields, hunger and
cold; the allocation of §8 within it; the tool fixed point of §3.1; the stores carried from
one season to the next) and repeats the year until it comes round the same (the stores
at the start of spring equal those of the year before). It prints:

- **year-averaged** shares of hands per need, h, R, K, coverage and the standard: what the
  §6 share table and the R bands are about (R is a year average, §2);
- **per season**: the same, so the rhythm shows (the autumn rush, the winter workshop,
  0% field hands in winter by design, not by error);
- **active-season R**: R in spring and summer alone, to check each food method's rate;
- where the ceiling is: the size at which a need's coverage falls to its floor;
- the largest single-need intake in a day (§8's herding check: with the recompute a big
  intake is a crisis response, not a bug — it should stay rare at the steady sizes);
- the persistence forecast's drift: where its C_horizon and the year actually run
  disagree, season by season (§8).

The share table (§6) is its first test. Growth is the game's channel, not the
calculator's: every solve holds N fixed, and the growth value fitted in §13 is checked
in play. Only once its numbers look right does the game
get measured against it.

## 13. Settled, and still open

What three reviews and a two-model brainstorm settled, by topic (the reasoning is in the
section named; `git log -p -- docs/society.md` has the argument):

**Scope and shape**

- **A gameplay curve**: R climbs 1.5 → 4.5 and the overhead (health, safety, order) takes
  ~29% of a town's hands, so growth feels like building a state (§6).
- **Nine needs**: transport is the walk term of the time budget (§2); water folds into
  health, trade into exchange and prices, law into order.
- **Six channels**: mortality, growth, labour, consumption, losses, contentment (§5).
  Growth (births, leavers, comers) is its own channel; its value is fitted so births
  clear deaths by a little while the ceiling is far and sit level with them at it; a
  culture that values numbers raises it, a leaning like §3's culture factor.
- **One communal store first**; households later.

**Units and counting**

- **N counts units** (each a family line, children included); **d is adult-equivalent
  mouths per worker** (a child 0.6 of c); food's demand is c × d × workers (§2, §4.1).
- **l is person-days per unit**, `1 / (rate × h)`, so S × l sums to the workers (§4).
- **R is the inverse of the food share**: share = (1 + m) / R (§3.2).
- **The productivity budget multiplies to ×3 ± 0.3** with a central allocation per
  source; known and land only lose the climb, never make it (§3).
- **Every effect is counted once** (§4.2); capital upkeep is charged to the need it
  serves (§3.1); a building is a capacity or a multiplier, never both.

**Shortfalls**

- **Concave B** and **two tiers**: friction from C < 1, hardship events below
  C_floor ≈ 0.6 (0.5-0.7 per need), linear to their maximum at 0 (§4).
- **Safety** is a stock against a pressure with a vigilance floor; the threat pressure
  stays in `rivals.gd` (§4.1).

**Scale**

- **Order**: demand = coordination (from the first Steward) + disputes past N₀ ≈ 50;
  supply in whole keepers, an informal keeper's span shrinking past N₁ ≈ 150, an
  institution's not (§6).
- **Health** scales on density (mildly, ~×1.6 band → town); its share climbs through care
  per case, a level's want (§6). The village binds on the walk, and on health where the
  beds lag (§7).
- **The walk has two distances**: to the worked land (∝ √N) and inside the settlement
  (∝ N^0.35 under the density assumption) (§2, §6).
- **Land**: diminishing returns per hand on a patch and bounded depletion (§3.2).
- **Skill ×1.0 → ×1.4**; an unknown method at **0.5** (§3).

**Allocation and food**

- **Food has two coverages**: C_now drives the channels and famine; C_horizon (rolling to
  the next harvest window, clamped to 4 days) drives births' food security and the
  horizon term of the allocation (§4).
- **Food's weight is the sum of its two windows**, each pairing its own demand and supply
  and carrying its own channels (now: mortality, contentment; horizon: growth and the
  winter's mortality discounted by δ) (§8).
- **The horizon's supply is a persistence forecast**, and a hand's horizon credit is that
  forecast's own increment; no delayed payoff until a crop cycle exists (§8).
- **The next hand goes to the greatest weight, recomputed after each hand**, in the
  calculator and the game alike (§8).
- **Births respond moderately** to the standard, gated by beds and food security (§10).

**The calculator**

- **A periodic year**, season by season with stores carried over, reporting year-averaged
  and per-season shares, active-season R, ceilings, the largest single-need intake and
  the forecast's drift (§12). Channel values, wants per level, care per case, δ, the
  spans, a_c and the threat at each size are its fitted knobs.

**Other docs**

- `city_proposal.md` is the record of the city steps as built. Where it gives the food
  economy's numbers (fields that keep a passive trickle, ~10 food a day per field worker,
  farm workers 8-10% of a city), the Steward's picker, births governed by beds with a
  crowding taper, and tiers by headcount and buildings, this model replaces them when it
  lands; its walls, its target mix of food sources, the rivals' growth and the 8-day
  year stand, and the City row of §7 is built on them.
- `CULTURES.md` describes the effects packs can use today; under this model their work-rate
  effects count against the productivity budget (§3) and inventions are marked technique
  or product (§9).
- `simplify.md`'s need rule (§1) and targets per role (§2) are the first form of §8's
  allocation and of the needs' capacities; `society_plan.md` says how this model becomes
  code.

**Still open:**

1. **The fitted values**: the channel values and the wants per level that the calculator
   finds. Do they look like a society we recognise (is a life worth a sensible amount of
   output)?
2. **The safety buffer for food**: how many days of eating ahead is "secure" (for the
   warning and for births)?
3. **C_floor per need**: one value (0.6) for all at first, or per need from the start?
4. **The density assumption** (§6): settled area ∝ N^0.7 is a guess; the layout's real
   growth (rings, then the grid) decides how much health costs a town.
5. **A crop cycle** (§8): sow in spring, tend in summer, harvest in autumn, the labour
   credited at the harvest. With the persistence credit, pay-as-worked fields already
   give the autumn rush its strength, so its remaining value is making sowing a decision
   (and the harvest a labour peak). **Recommendation**: leave it out of the first cut and
   decide after the calculator, on whether the year's rhythm reads in play without it.
6. **The horizon's discount δ** (§8): its value (~0.7 a day to start). Days ahead is the
   days until the forecast's stores run dry (the horizon's end if they never do), so δ
   is how much less a death at the run-out day weighs than one today. If V_horizon
   cannot fill the stores in one autumn at a sane δ, the Council's policies are the
   lever, not a steeper δ.
7. **Culture packs and the budget** (§3): checked per pack against the shares, or with
   some headroom for a pack's character (a share may run ×1.1 over its cap)?

## 14. What the calculator found (step 0, 2026-11-26)

`tools/society_calc.gd` solves the periodic year for each level of `config/society.json`
(`-- --seasons --sweep --fit --no-institutions`, ~1 s). Its first runs corrected the model
in four places (now in the sections above) and set the first parameters:

1. **A need's value needs its impact** (§8). With V the plain sum of channel values,
   health weighed like food (both feed mortality) and, being small, won every hand: the
   band put 7% on health and starved. V = value × impact fixed it.
2. **C_horizon is the worst day's coverage, with spoilage** (§4). The window's average
   credited the spring yield against the winter before it, so autumn read covered and
   winter starved (lowest C_now 0.5-0.7 at every level).
3. **The horizon runs through the lean season** (§4). Ending at the harvest left 4-15%
   of the hands idle in summer while the winter went short; δ (0.7-1.0) changed nothing.
4. **Small tribes split their days**: the calculator places hands in quarter days, or a
   band's single healer is 7% of its hands.

The first parameters (`config/society.json`), year averages:

| Level | R (band) | Food share (target) | Lowest C_now | Ceiling | Notes |
|---|---|---|---|---|---|
| Band 20 | 1.37 (1.3-1.6) | 69% (72%) | 0.51 | ~20 | a band without pottery loses 22% of its stores a day and lives on the winter hunt: at its ceiling at 20 |
| Camp 50 | 2.31 (1.8-2.2) | 46% (53%) | 1.00 | ~100 | R a little high: the food base or the camp's factors may come down |
| Village 150 | 2.94 (2.8-3.5) | 36% (36%) | 1.00 | ~300 | order rises from 5% to 12% by 300 without institutions: the step to the town |
| Town 500 | 5.09 (4.0-5.0) | 20% (25%) | 1.00 | above 1,500 | the winter workshop shows (winter: food 13%, 13% free); order 7% (target 9%: the Code's ×1.4 is generous) |
| City 1,000 | 4.34 (4.5-5.5) | 21% (20%) | 1.00 | ~2,000 | the fields' land limit binds, as the City row says |
| Town without the Council and the Code | | | 0.86 | ~625 | order takes up to 26% of the hands, then is abandoned (coverage 0.08): strife |

Also found:

- **Tools pay only from a ×1.25 factor up.** A tool lasts 4 days and a toolmaker makes 2.5
  a day, so tools cost 0.1 of a hand per food hand; at the camp's ×1.1 the payback is 0,
  at the village's ×1.2 it is 1.0, at the town's ×1.3 it is 2.0 (the band 1.5-3). So a
  worn good is worth having only where its factor clears ~1.25: either the stone tools
  stay a flag at the camp (a worn good from the village or the town), or the camp's
  products share is raised. Open #8.
- **Spoilage before pottery is the band's limit**, more than land: at 22% a day no band
  carries stores through a winter, so the winter sources (the hunt, fishing) must feed
  it; the game keeps the first 30 food from spoiling, which the calculator now does too.
- **The budget holds**: band → town multiplies the food worker's day ×2.99 (test_society_model).

**Still open (from the calculator):**

8. **Tools as a worn good**: from which level (open above)?
9. **The band's winter**: accept that a band of 20 is at its ceiling (the push to
   pottery and fields), or give it winter sources enough to sit below it?
10. **The fit**: `--fit` prints the hands per head that land the share table; the
   camp's and the town's comfort+spirit come out above their targets (21% vs 14%, 32% vs
   27%) because their R runs high. Tune R first, then fit.

### 14.1 The game measured (step 1, 2026-11-26)

`tools/metrics.gd` now prints a society report (a grown-up's day, the share of hands per
need by `config/society.json jobs`, food in and out by source from the sim's new food
ledger, `sim.food_summary()`). Two steward games, 12 days, The Ford (~19 people, 15
grown-ups):

| | The game | The model's band |
|---|---|---|
| A grown-up's day (s of 90) | asleep 15, meals 10, idle 4, walking at work 34, at work 28 | at work ~36 |
| The walk, of work time | 55% | 35% |
| Food a hand-day | bushes 24, mushrooms 20, tubers 22, a kill 54, a worked field 15.5, a dock 6.9 | ~6 |
| R | ~6 | 1.3-1.6 |
| Food share of hands | 43% | 72% |
| Where the food goes | eaten 1,383, births 450, spoiled and rotted 224, feasts and gifts 178 | eaten, spoiled |
| c, a person-day | 3.2 | 2.6-2.7 |

What it says:

- **The game is a land of plenty per hand.** One gatherer brings in four times what the
  model's band assumes. The hands are not scarce at the camp; food is spent on growth
  (a birth costs 15 food: a third as much as all the meals) and on filling the granaries
  the Steward now aims for (90fbad3). So the game's food "pinch" is the stores, not labour.
- **Fields lose to the wild.** A worked field makes 15.5 a hand-day against 24 from
  bushes, a dock 6.9; the fields' and docks' own yield (no hands) is ~10% of the food.
  In the model the fields are the step up from the band; in the game they are a step
  down, kept up only by their free yield and the bushes' limit.
- **The walk is longer than the model's**, 55% against 35%, and h is 28 s, not 36.

**Decided (2026-11-26): the game comes down to the model (#1 below).** The calculator,
run at the game's productivity (`--base=0.6`, R ~6 at the band), leaves 47% of a band's
hands idle, 41% of a camp's, 28% of a village's, and the whole climb from band to city
frees only 15% of the hands (food 20% → 5%): there is nothing to free, and a band would
spend its days on crafts (as the game's measured band already does: 23% on crafts and
rites, 25% on wood and stone). At the model's numbers idle stays at 0-6% and food falls
from 69% to 21%. Bringing gathering down to ~1/4 also puts the fields above the wild at
the camp without touching them, and lengthens a stint at the bush, so the walk's share of
work time falls toward the model's. The cost: slower growth and a hungry pre-pottery
band, which step 3 tunes against the calculator and the 150-day games.

**Open #11 (as it was asked):** either the game's gathering comes down to the
model's band (×~1/4: R 1.5, most hands on food, the levels' climb visible in the share of
hands), or the model's band moves up to the game (R ~6 at the band, the climb ×3 from
there: a town at R ~18 with ~6% of its hands on food), so that scarcity lives in the stores
and the walk rather than in hands. Either way the fields must out-yield the wild at the
camp level, or farming is no step.

### 14.2 Step 3, first cut: the game's gathering down to the model (2026-11-26)

`config/society.json work`: food gathering ×0.25 (`gather`), one skill curve for gathering
and fields (`skill_curve`, ×1.0 → ×1.4, instead of +10% and +5% a level); fields and docks
lose their own yield (food only when worked); a worked field 0.07 food a second a hand
(was 0.11).

| | Before (§14.1) | After |
|---|---|---|
| Food a hand-day (12 days, 3 policies) | bushes 24, a kill 54, a field 15.5 | bushes 12-15, a kill 12-24, a field 5.5-9.8 |
| R | ~6 | 3.2-4.1 |
| Food share of hands | 43% | 46-59% |
| The walk, of work time | 55% | 43-49% |
| Food decisions (hoarder vs feaster gap) | "barely matter" | 0.50 |
| 60 days (seeds 1, 2) | 141-176 people (ROADMAP §5) | 78-86 people, no deaths; 28-30 field hands on 11-12 fields by day 60 |

A food hand-day fell ~40%, not to a quarter: the walk to the bushes and back is the same,
so the cut only lengthens the stint at the bush. R is still above the model's band
(1.3-1.6), and the Steward still puts ~21% of the hands on crafts and rites while food is
short (the need rule's lore and crafts): step 4, the allocation by the model, is the next
lever, before cutting rates further. The 12-day bands overshoot (near-miss 100%, as before
this change; famine 50-100%, band 10-25%), and growth halved: both are for step 4 and the
tuning after it. The balance baseline is rewritten.

### 14.3 Step 4: the Steward places hands by the model (2026-11-26)

`scripts/society.gd` (`sim.soc`) is the Steward's allocation: every choice is a need, weighed
V × N × the rise in benefit one more hand gives, the greatest first, each placement counted
before the next; nothing gains = rest (§8). Stocks (wood, stone, herbs, ore, lore) are covered
by the stock and the hands on them against the Steward's targets; crafts, rites and building
by the hands on them (averaged over 30 s) against the level's hands per head; food by its two
windows. Rates per hand-day are measured as the game runs. The old need rule stays for the
tests (`soc.on = false` in `_new_sim()`).

Three things the game taught on the way (now in the code and config):

1. **Food's today window keeps a reserve.** "Today's eating against today's flow" let the
   tribe live hand to mouth (stores at 6-14 while food weighed nothing), but the game's
   meals and births draw on the stores: the window now asks for a day's eating in store
   besides (`work.reserve_days`), and the look-ahead for 20% over (`food_buffer`, open #2).
2. **The forecast is the hands on food now**, not the measured income: the income lags a
   day, so the Steward trusted food that had gone and the stores swung to 0.
3. **Pastimes are free time.** Crafts and rites taken up idly (everyday-life acts, a devout
   person's rites, the idle carving) were real jobs the Steward could not take back, and
   held 19-28% of the hands while the stores ran empty; they are now marked `leisure`, count
   as idle (`sim.is_idle`) and as free time in the society report.

| 12 days, 3 policies | Step 3 (the old rule) | Step 4 |
|---|---|---|
| Food share of hands | 46-59% | 49-64% |
| Crafts and rites (work) | 21-22% | 9-11% |
| Famine (band 10-25%) | steward 50%, hoarder 50%, feaster 100% | 50%, 0%, 50% |
| Hoarder vs feaster gap | 0.50 | 0.55 |
| 60 days (seeds 1, 2) | 78-86 people, no deaths | 100-102 people, 0-1 deaths; 34 field hands on 13 fields |

Still: near-miss 100% (the band is 60-90%), R 3.5-3.7 (the model's band 1.3-1.6), wood piles
to ~2,900 by day 60 (woodcutters by trade keep cutting past the target: careers still read the
old need rule, `need_of()`). The balance baseline is rewritten.

### 14.4 One rule for everyone (2026-11-26)

After step 4, careers still went by the old need rule, so woodcutters cut past the target
(wood ~2,900 by day 60). Rather than a rule for the woodpile, everyone now follows the
model's price (§8, `society.gd best_for`): the Steward places by it, a trade is worked by
itself only while it is its holder's best work (`trade_pays`), and with no Steward the
idle choose their own work by it (`self_work`; one seed lost its Steward to a blizzard on
day 40 and, with nobody placing hands, starved from 60 to 13 people: now it holds at 73).
60 days, seeds 1-3: 73-100 people, 0-7 deaths, wood 536-1,501 at day 60. Open: food
decisions again barely separate the hoarder from the feaster (gap 0.01), and the famine
band overshoots (50%); without a Steward nobody lays out buildings (improvements.planner),
so a tribe that loses its Steward stops growing.

### 14.5 The tribe builds without a Steward; the stores run thin (2026-11-26)

- **The planner, too, follows the principle**: `rules.json improvements.planner` is
  `anyone` (the tribe's best at lore plans when no Steward is appointed, at half the pace:
  `anyone_every_mult` 2). The seed that lost its Steward on day 40 grows to 105 by day 60
  (it stopped at 73). 60 days, seeds 1-3: 95-105 people, 0-7 deaths, wood 536-1,172.
- **The near-miss is real, not the measure.** Near-miss and famine count stores under 15%
  of the granaries' capacity, which since 90fbad3 is large, so they were suspected of
  reading a full camp as a close call. Counted in days of eating instead (the metrics'
  society report now prints both), the stores fall to 0.01 days at their lowest and stay
  under half a day's food 28-71 hours of a 12-day game (10-25% of the time): the hoarder 28,
  the steward 53, the feaster 71. Food decisions matter (the days show it better than the
  old gap's 0.35), but the tribe lives too near the edge.
- **Next, by the principle: food's price.** With the stores half covered, food weighs about
  as much as a waiting building site (~22-26 for a tribe of 13: shelter's impact 0.5 on
  growth and contentment against food's), so builders are taken off the food. The fix is
  the impact values (`society.json impact`, the calculator's fitted knobs, open #1), not a
  rule for the stores.

### 14.6 Food's price, by the principle (2026-11-26)

The thin stores of §14.5 were not building's fault (lowering shelter's impact changed
nothing: 52 hours short against 53). Measured one lever at a time, five fixes, each a price
or a forecast made honest rather than a rule for one case:

1. **Two days of eating in store** (`work.reserve_days` 2; three were no better): the hours
   under half a day's food halved. The calculator uses the same reserve; with it the band
   carries its winter (lowest C_now 1.00, from 0.51) and its food share lands on target (72%).
2. **The next best by price**: when a person's best work can't be done (nothing within a
   safe walk), they take the next best by the same rule (`soc.place()`), not the old rule's
   "the other of food and wood", which had piled wood to ~4,300 again.
3. **The forecast reads the game's own seasons**: each food hand yields what their work
   yields by `events.json` (fields and docks by `yields`, bushes by `berries`, a find by its
   winter flag, half the herds gone in winter), not a guessed 30% in winter that hid the
   winter gap (32 starved on one seed's first spring).
4. **...and today's weather**: a field in blight yields nothing today (`hz.food_mult`), so a
   new food hand goes to the best food to be had today (`best_food_kind`), and the Steward
   sends them there; in winter that is the hunt, fishing and tubers (food had dropped out
   of the choices altogether in winter).
5. **Births and newcomers need food security** (model §10): only while the look-ahead
   coverage, today's food hands held, is at least the buffer (1.2). A seed whose tribe took
   in 15 wanderers in the last days before a blighted winter lost 51.

| | §14.5 | Now |
|---|---|---|
| Hours under half a day's food (12 days: steward, hoarder, feaster) | 53, 28, 71 | 11, 3, 19 |
| Famine (band 10-25%) | 33%, 33%, 67% | 0%, 0%, 33% |
| 60 days, 5 seeds | 95-105 people, 0-7 deaths (3 seeds); one later seed lost 33 to hunger | 46-60 people, 0-1 deaths, wood 371-798 |

**The cost is growth, and it is a design choice.** Food security as a gate halves the
growth (46-60 people at day 60, against ~100). A smooth ramp (births from coverage 1.0 to
1.2) brought growth back in three seeds but let two unlucky bands breed into a hunger trap
and die out (12 and 1 people): since step 3 a band without fields lives near subsistence,
which is the model's band ceiling. Open #12: how fast should a tribe grow (the city plan's
curve, ~150 by day 60, assumed the old abundance), and is the band's poverty trap a
challenge to keep (the push to fields) or to soften (more winter food for the band)?

