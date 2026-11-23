# Making It Fun — a design plan

The systems are in place; this plan turns them into *dramas*. Everything below fits the
codebase's rules: tuning and texts in `config/*.json` (with zh), no new one-off branches,
an offline path through `persona_engine.gd` for everything (a game master / LLM is an
enhancement, never a requirement), and each item names the systems and configs it touches.

## What the game's fun is

Three stacked sources — every item below feeds at least one:

1. **Negotiation fun** — shaping a plan with a personality (the contract leader: memory,
   temperament, objections via `policy.objection()`).
2. **Anticipation fun** — watching a deterministic contract (`contract_system.update()`,
   zero LLM) meet a non-deterministic world (wolves, floods, raids, the `director`).
3. **Attachment fun** — people as characters (traits, `u.memory`, bonds, `life.gd`,
   feats, the chronicle).
4. **Builder fun** — the camp you raised: watching it grow from huts by a fire into a
   walled village with a temple, where each building was a choice (sections H, I).

Not-goals (identity protection): no more resources, no unit micro, no combat detail,
nothing fun gated on a configured LLM, and no *Civ 6*: no districts, adjacency puzzles,
per-building worker slots, production queues or upkeep juggling.

---

## A. Make contract execution the showpiece (anticipation)

The signature mechanic is currently the least dramatic phase: a progress % and substate
text between interruptions.

### A0. Read the odds before you seal — prerequisite for anticipation
You can only anticipate what you can read. Before sealing, the leader states the risk
in plain words, from data: *"Wolves were seen past the ford. One in four we come back
hurt."* This turns sealing into a bet rather than a click, and makes every later
interruption feel earned ("I knew it").
- A pure query over state the sim already has, built **from the plan's own abort
  conditions** (`_check_aborts`): each condition in `c.plan["abort_conditions"]`
  gets a score from the same predicates that would fire it — `enemy_attack` from known
  predators/raiders near the route corridor (`active_predators_near` along `D.route()`
  waypoints, as `env_data()` already does for the site), `hp_below_N%` from leader/crew
  hp, `natural_disaster` from season and `hz`/`nat` chances, `heavy_losses` from crew
  combat levels — plus season (`hz.summary()`), distance and the director's tension/
  held list (`director.summary()`). Returns `{risk: 0..1, reasons: [...]}`; a
  `contracts.forecast(plan)` that a game master can call too. Building it from the real
  triggers (not a bespoke vibe score) is what makes it calibratable — see G1.
- **Fog of war applies**: only threats the tribe has *seen* count (`is_explored` filter,
  met clans' stances, found dens — the `env_data()` pattern). The leader forecasts from
  tribal knowledge, not omniscience, which quietly makes scouting valuable: better
  maps, better odds.
- Phrasing and thresholds in config (`contract_log.json` `forecast` bands, zh); the
  leader's temperament colours the *words*, never the number (see Decisions: an
  honest, auditable number; a characterful spin on top).
- Shown in the negotiation dialog and fed into `negotiation_ctx()` so the LLM leader
  argues from the same numbers. Size: small. Risk: low (read-only).

### A1. The leader's field log — first to build
Milestone and flavor lines emitted during execution, chosen from data by
**archetype x trigger**:
- `config/rules.json` (or a new `config/contract_log.json`): triggers at 25/50/75%
  progress, first structure completed, crew member leveling, spotting an unexplored
  landmark, weather change, nightfall on site, near-miss (hp threshold), step done.
- Lines are English keys (zh required; `test_translations` checks them).
- Emitted through `add_log(..., "contract")` + a `sim.spoke(unit, text)` bubble at the
  leader occasionally. Target: something to read every ~30 s of contract time.
- Offline by construction (pure data). Size: small. Risk: low.
- Correction after reading the code: the middle is *not* fully silent today — `c.substate`
  updates live, and `_clog` keeps a 12-line ring (`c.events`, top 3 shown in the HUD's
  contracts panel). What's missing is character and reach: the lines are mechanical
  ("Step 2 done: gather wood"), they never reach the chronicle or a speech bubble, and
  there's no archetype flavour. So build A1 **by extending `_clog`** (the ring already
  *is* the budget — keep the cap), and treat the two channels differently: panel lines
  and `sim.spoke` bubbles are cheap (one per trigger per contract, per A2's pool);
  `add_log(..., "contract")` chronicle lines stay scarce (seal, first structure raised,
  interrupt, end) so the chronicle doesn't drown.
- The log should call back to the forecast (A0): "No sign of the wolves yet." / "The
  wolves found us, as I feared." — which only works if A0's scores come from the real
  abort predicates.

### A2. Small interruptions resolve through character
Not every hiccup deserves pausing the player:
- Low-stakes contract events (stung hand, crew argument, spoiled rations, a strange
  track) are decided by the **leader's temperament** (archetype table; optionally
  `llm` if configured), reported in the chronicle.
- Implementation: **no new mechanism.** Each event is a dilemma in the shared format
  (`dilemmas.json` or `contract_log.json`, through `story.dilemma_view/choose`) marked
  `routine`, with a `when` (a `story.holds()` condition, plus contract-scoped keys such
  as `progress`) and a `weight`; `contract_system.update()` rolls one now and then like
  `_check_aborts`. Options are `story.run()` actions, so a game master can pose the
  same event with `story.pose()`. The leader picks the option the way the Steward
  already decides routine matters (`sim._decide_routine`, `steward_routine`),
  weighted by archetype; the player only reads the outcome.
- Two wrinkles from the code: `_decide_routine` only sees `sim.DILEMMAS` and requires a
  Steward, so the contract side uses the *pattern*, not the function — the leader
  resolves the roll inside `contract_system` without ever posing (no pause, no queue);
  a GM-posed copy still needs an owner in `sim.event_def()`'s routing. And
  `story.holds()` reads only sim state, so contract-scoped `when` keys (`progress`)
  are checked by the roller itself — `holds()` and `COND_TYPES` stay untouched.
- Not `reactions.json`: reactions are people's *bodily* responses to a happening
  (cover, flee, aid, firefight); A2's events are *decisions with costs*, which is what
  the dilemma format is. They compose: an outcome may call `react.trigger()` (a snake
  bite → crew `aid`), so the crew visibly responds without A2 owning movement code.

### A3. Crew friction
- Pairing rivals on a crew (`u.bonds < 0`) generates friction events (A2 pool), slower
  work (`work_mul` term), or a bonding arc if they survive a crisis together
  (`life.add_bond` already exists).
- Culture/trait interactions (`devout` leader + `belligerent` helper) seed the event
  weights. Data: `config/life.json` or `contract_log.json` tables.

## B. Winter as a planned boss fight (anticipation)

### B1. The autumn decision (without ice)
One big dilemma when autumn begins (a `story.holds()` trigger on season + day, config in
`dilemmas.json`), posing bets on how bad winter is:
- Slaughter the herd for meat vs. keep the oxen (touches `sim.oxen`, `_herd()`).
- Feast now (mood) vs. bank food.
- Send a winter hunting party now (a contract with a forecast, A0) vs. keep everyone
  home by the fire.
- The `director` controls how bad the winter gets — it picks the winter *kind* when
  autumn begins (see Decisions) — so the bet is real, not theater.

### B2. Winters differ
- Per-year winter *kinds* (blizzard winter, wolf winter, quiet eerie winter) as rows in
  `config/events.json`; **the director picks the kind when autumn begins** (see
  Decisions) and `hz` reads it to weight its winter weather rolls, cold and wolf
  numbers — the per-season data it already reads. The kind stays hidden; B1 quotes 2–3
  **signs** of it ("the geese left early"), and a no-repeat rule on `hz.year()` keeps
  year 3 from equalling year 1.
- The eclipse/festival events show the pattern to copy.

### B3. The frozen river (split out of B1: it is the big one)
While `hz.winter()`, rivers freeze and can be crossed anywhere: new ground, new prey,
thin ice as a real risk. Valuable, but it changes `D.route()`, region logic
(`same_side`, `home_side`) and every caller that assumes water blocks; treat it as its
own item with its own tests, not as a rider on B1. Size: large. Winter already gates
movement (`beds.day_only`, `camp_asleep`, snow speed), so crossing ice must open
*enough* ground to beat those costs: build it only if G1 shows winters lacking.

## C. Rivals as recurring characters (attachment)

### C1. The rival chief is a person
- Chiefs already have a name and epithet, and the LLM chief already sees the last four
  grudges (`rivals.parley_ctx` → `wrongs_remembered`). The real gaps, from the code:
  grudges are **undated** strings ("last spring" is unverifiable), they record only
  **wrongs** (no gifts, kept oaths, parleys — `rivals.change()` appends only below
  `grudge_at`), and the **offline** `chief_reply()` never quotes them. So C1 = a dated,
  typed ledger (`{day, kind, text}` appended in `rivals._deed()`, which already funnels
  every deed) surfaced three ways: quoted in parley dilemma texts
  ("You came with spears last spring"), in `chief_reply()`'s offline speech, and in
  `summary()` for a game master.
- Chiefs age and die: a successor with a different temperament resets the diplomatic
  game mid-run (a `rivals.json` event, offline via `rivals.chief_reply()`); the ledger
  is what the successor *inherits*, which is the drama.

### C2. One horizon threat at a time
Drama needs a face; today all clans roll the same raid dice. Grounding from the code:
clans already carry `era` (it styles their village and prices their stone), raids scale
with relation-driven `_hostility`, each clan has its own `raid_t`, demands precede
raids, and a "break" war buys `no_raids_after_beaten_days`. C2 is a pacing layer over
those knobs, not new mechanics:
- The nemesis is chosen **by data, once**, at **first contact**: the worst relation
  then, `culture == "martial"` weighted. Not "the first clan to raid us": on the
  peaceful setting (`hz.level == "off"`, `rivals.gd` never raids) that would leave C2
  inert, and a face known from the first meeting reads better than one that appears
  with the first raid. On the peaceful setting the nemesis escalates without raids —
  with one code note: demands sleep on that setting *today* too (the demand roll sits
  inside `_raids`, behind its `level == "off"` bail), while trespass anger
  (`_trespass`) and hunter encounters (`_hunters`) still run. So peaceful escalation
  means lifting the demand roll out of that bail, plus new `rivals.json` data for
  parley insults and rival claims on sites. A `nemesis` flag on the
  clan, surfaced in `rivals.summary()`, settable by a game master; it biases *which*
  clan takes the director's allowed raid slots — pacing still decides *whether*.
- Escalation stages in `config/rivals.json` keyed by `evo.era` and hostility: bolder
  demands, bigger raid caps, and by Era 3 a war band that comes for the village itself.
  The other clans get a raid-roll multiplier — background, not switched off (allies,
  trade and parley still matter; a world with one actor is as flat as one with none).
- The arc must close through **existing endings**: break them (war contract `break`),
  buy peace (tribute parley), or befriend/vassalize them. Bookend it with `inv.feat()`
  (first raid survived, the feud ended) — and note C1's ledger is what makes the
  nemesis a *person* who remembers the feud, so C2 lands after C1.
- **Succession is reactive, never automatic** (see Decisions): a befriended or
  vassalized nemesis stays won; a broken one is already benched
  (`no_raids_after_beaten_days`). Only if G1 shows the late game dragging does a
  successor rise, by the same data rule (worst relation then), introduced through C1's
  ledger — the new chief quotes the old feud.
  Size: small–medium.

## D. The first ten minutes (decision fun)

- **D1.** Start with one find half-discovered (the elder remembers mushrooms) and a
  seek-quest contract available from minute one — the signature mechanic shouldn't wait
  for act two. (`D.FINDS` placement + `contracts` kind "seek" already exist.)
- **D2.** A day-1 micro-dilemma (a sick child, a strange trail) via a `story` trigger
  `{day: 1}` so the pause-and-decide rhythm starts immediately.
- **D1/D2 and the pause ceiling** (see Decisions): a day-1 pause is not a
  violation — the first pauses teach the game's language, so the opening day gets a
  front-loaded budget (`min_gap` smaller on day 1, or the ceiling counted from day 2
  on). What D2 must be is *one* pause that teaches a real tradeoff (spend the yarrow
  on the sick child, or save it), and the last scripted pause of its day. D1 isn't a
  pause at all — a seek contract is the signature mechanic running free, which is
  exactly the point of putting it in minute one.

## E. Failure is a story (all three)

- **E1.** ~~Defeat saga~~ — already exists (`legacy.saga_ctx("defeat")`,
  `hud.gd` saga dialog). What's left is making defeat *rarer and later than* a slow
  death: today defeat fires only when the *last* person dies (`legacy.gd`), so the
  typical loss is a long fade. A "last stand" dilemma when the tribe drops below a few
  people, offering flee, merge with a friendly clan (a rivals action), or hold, so the
  ending is a choice. Cheap, with one new condition key: `{pop: N}` in
  `story.holds()` means *at least* N alive (`story.gd`: false when fewer), and `fewer`
  counts structures, so add `pop_below` (and its `COND_TYPES` entry, `test_spend`
  checks it). "Merge" ending the run as a legacy path (`legacy.json`) rather than
  defeat is the interesting part: the tribe lives on inside another clan, which
  feeds E2.
- **E2.** Heritage hook into the next run: the new world remembers them — a landmark,
  ruins of the old village as a find, or a rival clan descended from survivors.
  Cheap because scenarios are data (`scenarios/*.gd` + `D.LANDMARK_KINDS`).

## F. Player-set stakes mid-run (attachment, replay)

- Council-proposed challenges ("no one dies this winter", "befriend a rival before
  Era 2", "settle across the river") built on `inv.feat()`; proposed via
  `policy.council_ctx()`, tracked in the HUD, rewarded with mood/lore.
- Each challenge is data: `{id, when (holds), track (a condition), reward}` — reuse
  `story.holds()` as the checker.

## H. Ranks earned by deeds (attachment, accomplishment)

Levelling exists (`sim.gain_xp`: five skills, Lv 0–10, a Lv-5 unlock from
`D.SKILL_UNLOCKS`), but reaching a level is neither an accomplishment nor a challenge:
- **Time = level.** Of ~40 XP sources most are per-second trickles of ordinary work
  (building `dt * 0.9`, foraging `dt * 0.12`, study `dt * 0.6`): anyone who chops long
  enough reaches Lv 5. Nothing hard is ever required.
- **Every level is the same size.** Each level of each skill of each person gets the
  same "LEVEL UP!" popup and a log line; by the twentieth it is wallpaper.
- **The goal is invisible.** Nobody knows what Lv 5 gives until it happens, and Lv 6–10
  change nothing you can see.
- **It isn't the player's doing.** You never set up anyone's growth.

### H1. Ranks with trials
- Each skill gets **two named ranks**, Proven and Master (e.g. Wolf-Hunter, Master of
  the Hunt; names in config, culture packs rename them). Two, not three: five skills ×
  three ranks is fifteen trials to write, translate and balance, and the player has to
  learn them all; ten is plenty, and a Master stays rare. Routine XP stops at Lv 4;
  the Proven trial opens Lv 5–7, the Master trial Lv 8–10. Each trial is a deed from
  data:
  - forage: lead a hunt that brings down a wolf or bigger;
  - craft: be lead builder of a longhouse (or a masterpiece, `folk` art);
  - lore: heal someone near death, or lead research to a breakthrough;
  - combat: stand in a defence that drives off a raid;
  - trade: seal a treaty or a caravan bargain.
- Trials are usually run **through a contract**, so the player sets them up: pick the
  candidate as leader, read the odds (A0: "with Ama leading, one in three we come back
  hurt"), and accept that a failed trial can cost a wound or worse. The green hunter vs.
  the safe veteran becomes a real choice, and the A1 field log has something worth
  saying ("Ama has never led before. She's holding steady.").
- The sheet shows the next step: "Next rank: Wolf-Hunter — lead a hunt that brings down
  a wolf or bigger (0/1)."
- A failed trial can be tried again; the cost of trying is the risk itself, not a
  lockout. Trials never pause the game (the pause ceiling): the attempt is a contract,
  the result is a log line or, for a rank-up, H2's moment.
- **Fit the existing thresholds.** Rules already read levels: a healer needs lore 3
  (`events.json` `healer_lore`), skilled art craft 3 (`rules.json` `skilled_lv`), a
  master trader trade 5 (`master_lv`), the eclipse's wise one lore 3. With the cap at 4,
  everything at 3 stays reachable by work alone, and trade 5 now needs a Proven trader,
  which is right. As ranks land, those thresholds should name a rank (`"rank":
  "proven"`) instead of a number, so retuning the curve can't silently move them.

### H2. A rank-up is an occasion; a level-up is quiet
- A rank-up gets an initiation by the fire (the `folk` festival/ritual pattern), a title
  and earned epithet (`u.epithet`), a visible mark on the sprite (cloth layer tint or a
  carried item; bump `ART_VERSION`), a memory (`sim.remember`) and an `inv.feat()` — the
  existing paused celebration dialog, for the tribe's *first* of each rank.
- Plain level-ups shrink to a small popup with no log line.

### H3. Ranks unlock things, not multipliers
- A rank lets the person do something new: lead a war party, tame aurochs, teach. Some
  things the tribe wants **need a master** (I4's grand altar needs a Master Builder,
  bronze a master smith), so having one is a goal with a payoff.
- **Know-how lives in the family line** (one person = one family line). A master can
  teach: people working beside them learn that skill faster, and a new line grown from
  theirs starts part-way up it. If a master dies before anyone else holds the rank, it
  is gone — `evo`'s knowledge keepers / oral loss, now for crafts. Protecting and
  teaching masters becomes part of the game; losing a veteran costs something lasting.

### H4. Shape in code
- `config/ranks.json`: per skill, ranks `{cap_lv, title, trial (a condition),
  rewards (effects in the `{stat, mul|add}` format, unlocks)}`; texts with zh.
- New state: a per-person **deed record** (kills by kind, contracts led, masterpieces,
  heals) that trials are checked against — unit-scoped condition keys (new
  `COND_TYPES` entries, checked by a `ranks` helper, like A2's contract-scoped keys).
  Readable in a summary; a game master can pose or grant a trial.
- First, move what `gain_xp` hardcodes (the `xp_need` curve, the cap of 10, the Lv-5
  unlock, the `warrior_initiation` ×1.25) into `rules.json`.

## I. Improving the camp (builder fun)

Today there are 13 buildable types over 3 eras (`D.STRUCTURES`), mostly Era 1 basics;
Era 2 adds the farm plot, granary, aurochs pen and council ring, Era 3 the smelter and
grand altar. The village never *looks* like it advanced much, and the late eras have
little to build. More is wanted — walls, towers, temples — **without becoming Civ**.
And more types alone won't do it: today placement barely matters (`sim.can_place` only
refuses the river bank and overlaps) and neither does timing. A building should matter
in the game, and so should **where** and **when** it goes up (I2, I3).

### I1. Rules for every new building
- **Few, and each one a decision.** About two or three new types per era, ~20 buildable
  in all. Each answers a pressure the game already makes (raids, winter, sickness,
  lore, trade) and has a cost or trade-off: where it stands, what it uses, what it
  excludes. No building that is just "+5% of something".
- **Upgrades before new types.** Palisade → stone wall, totem shrine → temple, large
  hut → longhouse: the camp visibly grows up instead of sprawling (`sim.upgrade(id, to)`
  and `rules.json` "upgrades" exist; era styles via `D.STYLED` exist).
- **No new resources** (the not-goal): costs use wood, stone, copper/tin, goods, lore.
- **No per-building management**: buildings work by being there and by who lives near
  them, as today. No worker slots, no queues, no upkeep menus.
- **Each era has a headline building** the player looks forward to, and each one feeds
  another section: walls and towers meet C2's Era-3 war band, the temple runs H's
  initiations and B's festivals, the master-built grand altar is H3's payoff.

### I2. Where it's built matters
Every spot is a trade-off the player can read, built from the map's real geography
(rivers, fords, flood band, land kind, regions) rather than a hidden bonus grid. The
map has no elevation (the "hills" ores use are only far-off spots), so nothing here may
assume high ground.
A short list of named **site factors** does all of it:
- **The river bank** — fertile and close to fish and water, but inside the spring flood
  band, where floods already knock buildings down. Fields there grow more; huts and
  granaries there are a gamble. The best land is the riskiest. Today the Great Flood
  knocks down whatever is within a hardcoded `river_dist < 220` (`sim.gd`), not the
  band the ghost would show; both must read one flood-band rule in config, or the
  placement warning lies.
- **Inside or outside the wall.** The palisade's size is chosen (`s.size`) and costs
  with it: a big ring is expensive and slow, a tight one leaves the fields, docks and
  pens outside. Raiders go for what's outside first (food in an outer granary, the
  pen's oxen); a wall is a decision about what you're willing to lose. `sim.inside_wall`
  exists; what's new is raid targeting: today a raid marches on `D.VILLAGE` (or an
  outpost), so "outside first" is a rule `rivals.launch_raid` has to learn.
- **Packed or spread.** A tight camp is cheap to wall and quick to walk, and burns
  together; a spread one is safe from fire and hard to defend. This needs one new rule:
  today fire reaches buildings only from burning trees (`nature.gd`, `building_radius`)
  or a lightning strike on one building; a burning building must also set neighbours
  within a config radius alight. That rule, not a placement bonus, is what makes
  spacing a choice.
- **Chokepoints and sight.** Rivers mean raiders come over fords (`D.FORDS`,
  `D.route()`): a lookout or tower at the ford sees them a day early, one in the middle
  of the village sees them at the door.
- **Close to the work.** Distance is already walking time (the granary as a drop-off
  near the fields); keep that the main pull, so where people live and work shapes the
  layout naturally.
- **Near people, not near buildings.** Auras work on the people around them, as the
  bonfire and weapon rack do now — no "+10% next to a temple" adjacency puzzles. A
  temple matters because the village gathers there, not because of its neighbours.

The placement ghost shows the site's value and risk in words, from the same factors
("Fertile river soil: fields grow half again as much. Flood land: about one spring in
three."), the building version of A0's forecast. `improve.gd` scores the same factors,
so the Steward lays out a sensible camp when the player doesn't, and a game master
gets `sim.site_value(type, pos)`.

**The Steward plays it safe.** If the Steward's layout were as good as the best one,
placing buildings yourself would be pointless. So the Steward is sound but cautious: it
never builds in the flood band, always walls the granary in, keeps fire gaps. The bold
layouts — fields on the river bank, a tight camp, a tower out at the ford — are the
player's to choose, and that's where the reward is.

### I3. When it's built matters
- **Seasons.** Building in deep winter is slow (snow, short days, `beds.day_only`);
  a field sown after spring yields little that year; a smokehouse is only worth
  something if it's finished before the frost (B1's autumn bet). Each building's
  "best season" and penalty are config.
- **Builders aren't gatherers.** Every hand on a building site is a hand not bringing
  food or wood; a big project at harvest time is a real cost (`improve.gd`'s
  `wood_reserve` shows the pattern; a food reserve should join it).
- **Races against foreseen threats.** The threats warn ahead: C2's escalation stages,
  B2's winter signs, the A0/tower sightings. The wall has to be up before the war band
  comes; that's a race the player can see and plan, not a surprise.
- **Commitments stick.** Demolishing refunds only part (`rules.json` "demolish"), and
  big works take days, so the order you build in is a real plan.

### I4. Candidates (to be cut to fit, not all built)
| Era | Building | Answers | Where / when it matters |
|-----|----------|---------|-------------------------|
| 1 | Lookout tower | raids, fog | at a ford it warns a day early, alone and exposed; feeds A0's forecast (what the tribe has *seen*) |
| 1 | Drying rack / smokehouse | winter | food keeps longer — only if finished before the frost (B1's bet) |
| 2 | Longhouse (large hut upgrade) | families | homes more, families in it bond (`life`); a big thing to lose to a flood or a fire |
| 2 | Gate (on a palisade) | defence vs. movement | facing the fields or the ford sets everyone's walks; one weak point to defend |
| 2 | Workshop | craft | where masters work and teach (H3); near the stone and the wood shortens every job |
| 2 | Temple (shrine → temple) | lore, morale | rituals, festivals, rank initiations; the centre the village gathers round |
| 3 | Stone wall + towers (palisade upgrade) | Era-3 raids | holds against C2's war band if up in time; how much it encloses is the choice |
| 3 | Trading post | trade | caravans come more often and pay better (`rivals` traders); by the road or ford they arrive on |
| 3 | Grand altar (temple → grand altar; exists today as its own type) | legacy | the era's wonder, already Victory by Wisdom's piece; now an upgrade of the temple that needs a Master Builder (H3) |

No separate megalith: the grand altar already is the Era-3 wonder (Yinglong, Victory
by Wisdom), so a second wonder would compete with it. Making it the end of the
shrine → temple → altar line gives the religious path one building that grows up
through the eras instead of three unrelated ones.

### I5. The village grows a name
- Camp → village → town by what's been built (a rule over `sim.structures`, config),
  each step an `inv.feat()` moment with a snapshot, and the clans' parley texts change
  how they speak of you.

### I6. Shape in code
- Move `D.STRUCTURES` into `config/structures.json` first (it's tuning and texts held in
  a const today), keeping `D.STRUCTURES` as the loaded view; the build menu, placement,
  contracts' allowed structures (`D.CONTRACT_STRUCTURES`) and `improve.gd` read it.
- A building's effect is data (the effect-stat format, auras by radius as the weapon
  rack and bonfire do now), so a new type is mostly config plus a baked model
  (`art_baker.gd`, bump `ART_VERSION`) with the procedural fallback.
- `improve.gd` (the Steward's layouts) learns the new types from config, so the camp
  also grows when the player doesn't micromanage it.
- Site factors are a small set of named verbs in code (`river_bank`, `flood_band`,
  `in_wall`, `crowding`, `near_ford`, `land`, `walk_to`), each building's
  config picks and weights them (`{"site": {"flood_band": {"food": 1.5, "risk": ...}}}`),
  and their texts are config with zh. One function, `sim.site_value(type, pos)`,
  returns `{factors, risks}` for the ghost, the Steward and a game master.
- The building-type lists written into the code (what lightning can strike in
  `nature.gd`, what floods spare in `sim.gd`) become flags in `structures.json`
  (`burns`, `floods`), so a new type behaves without touching those scripts.
- G1 checks that it matters: a policy that places at random must do measurably worse
  than the Steward's scored layout, or the factors are decoration.

---

## G. Tuning fun with the headless harness (engineering advantage)

The sim is deterministic, headless and config-driven with a full test harness — use it.
Targets are **bands with two tails, not one-sided minimums**, and they must respond to
play (that is the measurable form of "decisions matter"):

- **G1. Metric runs**: a test-style script that plays N seeded games per config variant
  under at least two scripted policies (e.g. a hoarding autopilot vs a feasting one) and
  reports:
  - *Skill sensitivity* — the headline: the distributions below must **differ between
    policies**. If hoarders and feasters starve at the same rate, food decisions are
    theater.
  - Food-floor near-misses (food < 15% of cap): 60–90% of runs at least once, **not**
    ~100% — a threat in every single run that never kills is a jump-scare without
    teeth, and it means granaries bought nothing.
  - Real famine consequences (a starvation death, sickness wave, or a family leaving in
    `life`'s discontent) in 10–25% of year-1–2 runs: some runs must actually pay, or
    players learn the floor is safe. Starvation deaths *cluster* in badly-played runs,
    ~0 in well-played ones — that spread is the point.
  - Deaths by day 20 as a band (some runs lose someone early; a game where nobody can
    die before day 20 has no weather), contracts interrupted per run, dilemma/pause
    frequency per game-hour (feeds the pause ceiling), days between meaningful events,
    time-to-era-2.
  - *Forecast calibration* (A0): of contracts that were interrupted, how often was a
    top-scored forecast reason the actual abort reason. Below ~60% and players will
    learn to ignore the forecast — which kills A0 and A1's callbacks with it.
- **The scripted policies are game-master scripts**, as pi suggested, so the harness
  doubles as a smoke test of the GM surface: a policy is a JSON file
  (`tests/policies/*.json`) of rules "when `holds(cond)`, do `story.run(actions)` /
  `improve.order(type)` / `policy.set_choice(id, choice)`", plus a dilemma picker (an
  option index, or the option tagged with the policy's bias, e.g. `hoard`). Three to
  start: **steward** (no player choices: the built-in defaults — the baseline),
  **hoarder**, **feaster**. Skill sensitivity = how far hoarder and feaster land from
  the steward baseline and from each other. If something the policy needs has no verb,
  that is a GM-surface bug to fix, not a harness hack.
- **Policies must also run the signature loop** — seal contracts, answer emergencies —
  or "interrupts per run" and forecast calibration measure nothing. The verbs exist
  but as a chain inside the HUD (`negotiation_ctx` → `llm.negotiate` or
  `Persona.propose` → `sanitize` → `create`; interrupts via `contracts.resolve`;
  dilemmas via `sim.resolve_event(id, idx)`). Make the seal one operation,
  **`contracts.seal(kind, directive, reply := {})`**: with no `reply` it asks
  `Persona.propose()`; with one (the LLM's answer, or a game master's plan) it
  sanitizes that. Not a separate `seal_offline`: the HUD awaits the LLM, then calls the
  same `seal()` with the reply, so there is one path through `sanitize()` and the
  offline fallback is the default rather than a fork. The steward policy calls it bare.
- **G2.** Wire the metric run into CI as a balance canary: config edits that shift the
  distributions show up as diffs.
- **G3.** Tune the director's per-level caps against these curves, not by feel.

Why these bands: ~100% near-misses with ~0 starvation deaths (the first draft) describes
a floor that always triggers and never bites. Scarcity should be *felt* in most runs,
*paid* in some, and escapable by good play. The bands state where the game should be;
the steward baseline measures where it is. A baseline outside a band is a finding (the
distance is the tuning work); only a band *no policy can reach* gets revised.

## Order of work

| # | Item | Size | Feeds |
|---|------|------|-------|
| 0 | G1 skeleton: baseline metrics + steward policy | small | everything (inputs) |
| 1 | A0 forecast + A1 leader's field log | small | anticipation |
| 2 | B1 autumn decision | medium | anticipation |
| 3 | C1 rival chief as a character | medium | attachment |
| 4 | C2 nemesis clan | small–medium | attachment, anticipation |
| 5 | D1/D2 opening minutes | small | decision |
| 6 | B2 varied winters | small–medium | anticipation |
| 7 | A2/A3 leader-judged events, crew friction | medium | anticipation, attachment |
| 8 | H ranks with trials (after A0: trials lean on the forecast) | medium | attachment, accomplishment |
| 9 | I structures to config, then Era-1/2 buildings and upgrades | medium | builder |
| 10 | F player-set challenges | small–medium | attachment, replay |
| 11 | E1 last stand, E2 heritage | medium | all |
| 12 | I Era-3 buildings (walls/towers, trading post, megalith) | medium | builder, C2, H |
| 13 | G1 full harness (hoarder/feaster, calibration) + G2 CI + G3 tuning | medium | everything (tuning) |
| 14 | B3 frozen river — only if G1 shows winters lacking | large | anticipation, exploration |

Row 0 lands before anything that adds a pause: the pause ceiling, the near-miss bands
and the forecast-calibration floor are all *inputs* measured against the steward
baseline, not afterthoughts — the skeleton is just the metric counters plus the
steward policy and its dilemma auto-picker, and item 13 grows it into the full canary
(more policies, calibration, CI, director tuning). 1–5 convert the proudest systems
(contracts, seasons, rivals) from mechanisms into stories; C2 rides on C1's ledger;
B3 waits for evidence. Era-3 buildings come after C2 and H, which give the walls
something to stop and the megalith a master to build it.

## Definition of done per item

- Texts are config entries with Chinese (`test_translations` passes).
- Works fully offline (`persona_engine` / pure data); the LLM only enriches.
- Every way the feature changes the game is a named operation a game master can call,
  and its state is readable from a `summary()`/`world_ctx()`-style view.
- `check_invariants()` grows a rule where a new coupling could drift.
- A test covers the trigger/resolution path (and the metric harness covers balance).

## Decisions made in the brainstorm

- **No new verb between pauses (for now).** A0/A1 give the waiting something to read
  and watch; G1 counts the gap lengths. A Steward-priority verb is the v2 candidate
  (`improve.order()`, `policy.set_choice()` exist); not unit micro.
- **Dilemma spacing.** Dilemmas already queue one at a time through `check_events`
  (`story`, `cult`, `rivals`, `folk`, `nat`, `life` pending), so they never stack;
  what's missing is spacing. A config `min_gap` (game-hours) between posed dilemmas,
  its value picked from the G1 baseline. Urgency is per-dilemma data,
  `"urgent": true`, when *waiting would change the options*: the flood, the last
  stand, endings, an emergency's take-command; not an envoy, festival, the chosen one,
  an era change or a discontented family. A held dilemma keeps its queue place; a
  moment-triggered one (the eclipse) is urgent or its text must read fine hours late.
  Day 1 gets a front-loaded budget (D2).
- **The forecast never lies.** The number comes from the real abort predicates, so G1
  can score it; temperament colours only the words, and the negotiation dialog shows
  the band beside the speech.
- **The merge ending is a legacy path, not a defeat.** A row in `legacy.json`
  `paths` (its own title, saga lines and `inv.feat`), because the saga for "we joined
  the Elk clan" must differ from "the last of us died". One code catch: `legacy.gd`
  tells endings apart by name (`victory_*` or `defeat`), so add a `kind`
  (`victory`/`defeat`/`absorbed`) to each ending in the config and read that instead
  of the prefix, rather than naming it `victory_merge`.
- **The director authors winter.** When autumn begins it picks the winter kind from
  the year's state (tension, deaths, food, last year's kind) — `pick_winter()` in the
  same shape as its mercy gifts: state in, story out, deterministic and testable.
  The kind is decided *before* B1 is posed but stays hidden; the dilemma quotes signs,
  so the bet is against a fixed hidden fact and G1 can score the signs' hit rate the
  way it scores the forecast. Why not roll the kind later and let the director only
  pace within it: then B1's stakes are exactly the theater B1 exists to fix. (The
  director is the documented LLM-GM seat, so choosing ahead of time is a small
  promotion of it; A0's forecast must not leak the choice — it reads current threats
  only.)
- **Nemesis succession is reactive, not automatic.** Replacing a befriended nemesis
  would punish the diplomatic game C1/C2 exist to make matter, so a won feud stays
  won; a broken one is benched by `no_raids_after_beaten_days`. If — only if — G1's
  "days between meaningful events" shows the late game dragging, a successor is
  promoted by the same data rule and introduced through C1's ledger. The mechanism is
  the director gaining a floor to match its cap: the cap stops pile-ups, a `bored()`
  query (tension near zero for N days) stops boredom — the missing twin of `allow()`.

## Open questions

No design forks remain — what's left are numbers the G1 baseline must set, and one
playtest judgment:

- the `min_gap` value (game-hours between posed dilemmas; the day-1 budget aside);
- the final band values (near-miss %, famine-consequence %, the day-20 death band);
- the Era-3 quiet threshold that promotes a successor nemesis — if the late game
  doesn't drag, none is ever promoted;
- whether the winter signs say enough without saying too much: G1 scores their hit
  rate, but only a playtest says if the *words* land.
