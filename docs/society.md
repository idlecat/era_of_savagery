# A model of the tribe as a society: needs, capital and levels

Draft 3, 2026-11-25. A model to get right before any code. Draft 1 (`economy.md`)
modelled the food economy; draft 2 made food one case of a general model; draft 3 fixes
its units, removes double counting, and settles the questions a review answered (§13).

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
          five CHANNELS: mortality, labour, consumption, losses, contentment
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
   walk is the cost of distance, counted there and nowhere else (§2).
3. **Every need has the same shape**, in its own unit: demand, supply, coverage, benefit
   (§4, with the unit table in §4.1).
4. **Every effect goes through five channels**, each counted once (§5).
5. **Some demand grows faster than people** (§6): the cost of scale.
6. **A level is a regime with one binding constraint** that the next level's methods
   relax (§7). Between levels the tribe meets a ceiling, not a timer.

## 2. Labour, time and consumption

- **Consumption**: a grown-up eats **c ≈ 3 food a day** (hunger 0.33/s, 3 food per 30
  hunger, a 90 s day), ×1.25 in winter; a child 0.6 of that. ~25 food a year (8 days).
- **Dependants**: children, the sick and the badly hurt eat and don't work. **d** =
  mouths / workers (~1.2-1.4 in a growing tribe). Health and safety move d.
- **The time budget of a working day** (seconds of a 90 s day):

  `H_awake = 90 - rest` (~70) → `H_work = H_awake - meals - life` (~55) → `h = H_work - walk`

  **h** (time actually at work) is an **output**, not a parameter. **Base rates are per
  second at work**, so they never include walking, and h changes only through the walk
  (or a longer working day: lamps for indoor work). Today the walk is 58-65% of working
  time (measured): h ≈ 20-25 s.
- **The walk** = trips × distance / speed. Distance grows with the settlement's spread
  (radius ∝ √ of its built area, so ∝ √N) and with how far out the work is (the nearest
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

**The productivity budget.** From band to town, food output per worker-day rises ~×3
(§7). The sources share it: methods ×1.6-1.8, products ×1.3-1.5, skill ×1.2-1.3,
techniques ×1.1, culture ×1.0-1.2, and the walk (h) what roads and granaries win back.
Each source is capped at its share.

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
factor is capped (×1.5 at most) and one maker supplies many users (payback > 1, §8);
the calculator solves it by iteration.

**A building is one of two things, never both**: the **capacity** of a stock need (beds
in huts, the stores of a granary, a fire's warm places) or a **multiplier** in the
production of a flow need (a wall multiplies each guard, a temple each shaman, a
workshop each maker).

### 3.2 Land: why one farm feeds only so many

- **The labour limit**: a worker makes F food a day (rate × h), so feeds
  **R = F / (c × d)** people.
- **The land limit**: a source yields at most **Y** food a day however many work it (a
  bush regrows only so fast, a field holds only so much soil). The land within reach of a
  settlement holds at most **K = ΣY / c** people: its **carrying capacity**.
- **Diminishing returns** on the same patch: the n-th hand adds less than the one
  before, approaching Y. And the nearest land is worked first, so each new field or patch
  is farther out (the walk, §2).
- **Depletion**: over-harvest past regrowth degrades the patch (game thins, soil tires)
  until it is rested (fallow) or left. Bounded: a patch recovers when rested.

**The farm.** How many people live on one field with one farmer has two numbers:
`min(F, Y_field) / (c × d)`. With the design's numbers one farmer on one family plot
feeds **R** people: ~2 at the camp level, ~3 in a village, ~4-5 in a town (§7). More
hands on a field get closer to Y_field, at less each.

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
4. **Labour cost l**: person-days per unit of supply (for a stock: per unit built and
   kept). **Hands for a need = S × l** (per day). This is the one conversion between a
   need's unit and person-days.
5. **Coverage C = S / D**, a pure number. Above 1 is surplus, with no further gain.
   **Storable needs look ahead**: food's coverage is
   `(stores + expected supply over the horizon) / demand over the horizon`, the horizon
   reaching to the next harvest season, so coverage drops in late summer when the winter
   comes into view, not in winter when fields yield nothing.
6. **Benefit B(C) = 1 - (1 - C)²** for C < 1, 1 above: concave, the first healer matters
   most. **Each channel the need feeds takes the shortfall `1 - B(C)` smoothly**: no
   cliff anywhere in the rules.
7. **Hardships** (famine, an epidemic, strife, a raid that breaks in) are discrete
   events: their rate is 0 above a floor **C_floor** and rises linearly to its maximum
   at C = 0, and the director paces them as now. The smooth channel effect and the event
   rate are the only two ways a shortfall acts. Food's mechanical starvation (stores at 0)
   is the event of the food need; stores make it a forecast, not a surprise.

### 4.1 The unit table

| Need | Kind | Unit | Demand D | Supply S | Labour cost l | Channels |
|---|---|---|---|---|---|---|
| **Food** | flow, storable | food / day | N_mouths × c × season × cooking (the cookhouse lowers c) | Σ food workers × rate × h, bounded by land (Y) | 1 / F | mortality (starving), consumption (cooking), losses (spoilage: pots, granaries), contentment |
| **Shelter** | stock | beds | N × (1 + margin) | Σ `cap` of homes standing | build + upkeep per bed | people (births need beds), health (crowding raises sickness incidence), contentment |
| **Warmth** | flow, seasonal | warm person-hours / day in the cold | N × hours of cold exposure × cloth (cloth lowers exposure) | warm places of fires and hearths × hours; fuel | wood per warm hour / wood rate | mortality (freezing), labour (the cold slows) |
| **Health** | flow | care-days / day | cases (incidence × N, raised by density, hunger, cold) × care per case | healers × patients per healer-day × medicine | 1 / patients per healer-day | mortality, labour (sick days, and d) |
| **Safety** | stock (vs a threat) | defence strength | expected threat: raiders drawn by wealth and size, beasts | guards × arms × skill × walls (a multiplier) | training + upkeep per strength | losses (raids), mortality |
| **Order** | flow | disputes / day | a × N × (N / N₀)^k beyond the face-to-face band (§6) | keepers × span (the Steward, council, chiefs; the Code multiplies span) | 1 / span | labour (waste), losses (strife), contentment |
| **Knowledge** | flow | teaching-days / day | learners (children, newcomers, new methods × people to learn them) × days to teach, plus keepers wanted per method | teachers × pupils each; codification ends the keepers' part | 1 / pupils per teacher-day | labour (the `known` factor), losses (a method lost) |
| **Comfort** | flow (goods wear) | wanted goods / day | N × the level's wants × wear | makers × rate | 1 / F_maker | contentment |
| **Spirit** | flow | rite-hours / day | N × the level's wants | shamans × congregation × temple | 1 / congregation per rite | contentment (and devotion) |

### 4.2 Counting each effect once

The rules that keep the model from double counting:

1. **Each supply serves one need.** The cookhouse is food (it lowers c); pots and
   granaries are food (losses: spoilage, capacity); cloth is warmth (it lowers exposure);
   tools serve the need whose work uses them. **Comfort** holds only goods whose sole
   effect is contentment (ornaments, decor, fine wares), so a cooked meal is not also a
   comfort.
2. **Capital upkeep is charged to the need it serves** (§3.1).
3. **Walking is counted once**, in h (§2).
4. **A shortfall acts only through its need's listed channels** (§4.1), smoothly by
   1 - B(C), plus its hardship's event rate.
5. **Crowding is a link, not a double cost**: shelter's shortfall raises health's
   *demand* (incidence); it doesn't also hit mortality directly.

## 5. The five channels and the end state

| Channel | What it changes | Fed by |
|---|---|---|
| **Mortality** | deaths a day | food, warmth, health, safety |
| **Labour** | hands (sick days, d) × how well they work (`work_mul`) | health, warmth, order, knowledge |
| **Consumption** | food and goods used per head | food (cooking, spoilage) |
| **Losses** | capital destroyed: raids, fires, strife, rot, a method forgotten | safety, order, knowledge, food (spoilage) |
| **Contentment** | mood: the standard against what is wanted (§10) | food, shelter, order, comfort, spirit |

The end state is three numbers: **people** (births, deaths, comers, leavers), **output
per head** (the value of a person-day, at trade prices), and **the standard** (§10). The
channels make needs comparable: their values are what the tribe weighs (§8).

## 6. Scale: demand that grows faster than people

Each need's demand per head can rise with size:

`D(N) = a × N × (N / N₀)^k`

**a**: the need per head at the reference size N₀; **k**: its scale exponent (0 = in
step with people).

| Need | k | Why |
|---|---|---|
| Food, shelter, warmth, comfort, spirit | 0 | each mouth, bed, warm place the same |
| Health | ~0.3 | incidence rises with density; a big settlement is denser |
| Order | 0 below ~50; ~0.5 past it; formal institutions needed past ~150 | two thresholds (§13): below ~50 everyone knows everyone; 50-150 an elder or the Steward can keep it (an informal keeper); past ~150 only institutions (council, Code) keep it at a reasonable span |
| Safety | ~0.3 on wealth | a richer tribe draws more raiders and coalitions |
| Knowledge | ~0 on N | grows with methods held and learners, not with size itself |
| (the walk, in h) | ~0.5 | radius ∝ √N: every trip lengthens |

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
| **Village** | health and the walk, as density and spread grow | fevers in the crowd, fields far out, the day spent walking | healers and medicine, oxen and the plough, roads, the cookhouse | 2.8-3.5 |
| **Town** | order (past ~150) and safety | waste, strife, raids on a rich town | the Council and the Code, walls, bronze, the warehouse, trade | 4-5 |
| **City** | (beyond the first cut) | | | |

- **Growth is bounded per level**, not by a timer: under a rising ceiling for a tribe that
  learns, at a ceiling for one that doesn't.
- **Climbing is the game**: which constraint to relax next, and how to carry the cost of
  scale meanwhile.

## 8. Allocation: where the next hand goes

The Steward's rule (a weighted gap) stays; the model derives its weights.

- **One more hand on a need** adds s units of supply (its rate × h, in the need's unit).
- **Its gain is the actual rise in benefit**, not the slope:
  `ΔB = B(min(1, C + s/D)) - B(C)`, which is bounded by `1 - B(C)` (a tiny need can't
  pull more than what it lacks) and is **0 once C ≥ 1** (no negative weights, no
  over-investing).
- **Its worth scales with the people it affects**:
  `weight = V_need × N_affected × ΔB`, where V_need is the sum of the values of the
  channels the need feeds (per person). A need of 5 people weighs as 5 people's, so a
  small D can't yank hands from food or safety.
- **The channel values** are what the tribe values: lives first, then output,
  contentment... The Council's policies set them (a war footing weighs losses and
  mortality from raids; a feasting tribe weighs contentment).
- The next hand goes to the greatest weight. Concave B spreads hands across needs, and a
  shortfall pulls in proportion to how bad it is.
- **Payback**: a trade (a need's worker whose output is a multiplier, such as a
  toolmaker) is worth having when its hands free more hands elsewhere than it takes. The
  design band: **1.5-3×** at the trade's typical skill. Below 1 the trade loses hands;
  far above 3 one maker carries the town.

**Seasons move the allocation through s and D.** In winter a field's s is 0, so no hand
goes there; the hands flow to what yields indoors (tools, cloth, teaching, rites). Food's
look-ahead coverage (§4) falls in late summer as winter comes into the horizon, so the
autumn rush begins before the cold. No seasonal rule of its own.

## 9. Knowledge, inventions and skills, in one place

- **Knowledge = methods.** A tech sets a base rate (§3); per person, `known` (1 or 0.5).
  Teaching is the knowledge need; codification (totems, the Code) ends the risk of loss.
- **Inventions are techniques or products.** A technique is a permanent factor; a product
  (digging stick, fish hook, baskets, carrying frame, bone needle, the tools of the
  `tools` and `bronze` techs) is the know-how to make a good, whose effect comes from its
  coverage and which wears, so its making is upkeep (§3.1).
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
stability and accumulation instead of bouncing off famine and epidemic ceilings.

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
| c, d | food a day, dependants | 3, 1.3 |
| the time budget: rest, meals, life; trips, distance, speed | h | from the day's parts; the walk from geometry |
| base(method) per kind of work, per level | the steps | from each level's R band |
| productivity budget shares | each source's part of the climb | §3 |
| known (unknown method) | learning | 0.5 |
| skill curve | the specialist's edge | ×1.0 → ×1.4 |
| Y and regrowth per source; depletion and rest | carrying capacity | foraging K ~30-40 per band's reach |
| a, k, N₀ per need | need per head; cost of scale; thresholds | §6 |
| l per need, per level | labour cost of a unit (methods lower it) | from the share table |
| B(C), C_floor per need | concavity; where hardships start | `1 - (1 - C)²`; floors per need |
| channel values | what the tribe values | from the Council's policies |
| wants per level | the standard's bar | to be set |
| birth response to the standard | more people vs better lives | moderate |
| goods wear | how much upkeep capital takes | a tool lasts a few days |
| payback band | what a multiplying trade must earn | 1.5-3× |

**The calculator comes first**: a small script that takes this table and, for each level
and size (Band 20, Camp 50, Village 150, Town 500), solves the steady state (the
allocation of §8 to a fixed point, the tool fixed point of §3.1) and prints the share of
hands per need, h, R, K, every need's coverage, the standard, and where the ceiling is. The
share table (§6) is its first test. Only once its numbers look right does the game get
measured against it.

## 13. Settled, and still open

**Settled by review:**

- The overhead split (~29% on health, safety, order at the town) stays: growth should feel
  like building a state. Labelled a gameplay curve.
- **Order has two thresholds**: ~50 (informal leadership breaks down: the Steward's role)
  and ~150 (formal institutions are needed: council, Code); this is the village → town
  step.
- **Births respond moderately** to the standard, gated by beds and food security.
- **Land**: both diminishing returns per hand on a patch and bounded depletion (recovering
  when rested).
- **Skill ×1.0 → ×1.4**; an unknown method at **0.5**.
- **One communal store first**; households later.
- **Nine needs**: transport became the walk term of the time budget (§2); water folds
  into health, trade into exchange and prices, law into order.

**Still open:**

1. **C_floor per need**: where each hardship begins (food: when look-ahead coverage falls
   under the stores' safety margin? order: ~0.6?).
2. **The channel values**: what a life is worth against output and contentment, and how
   the Council's policies shift them.
3. **The wants per level**: what a camp, a village, a town expect of comfort and spirit.
4. **The horizon for food**: to the next harvest, or a fixed season ahead?
5. **Safety as a stock against a threat**: the expected threat is itself a model (clans,
   their size and mood, our wealth). How much of that model belongs here, and how much stays
   with `rivals.gd`?
6. **The one-family-line rule**: a person is a family line, so a household's trade fits it,
   and births and departures by the standard need no ageing or mates.
