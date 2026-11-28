# Making It Fun — a design plan

The systems are in place; this plan turns them into *dramas*. Everything below fits the
codebase's rules: tuning and texts in `config/*.json` (with zh), no new one-off branches,
an offline path through `persona_engine.gd` for everything (a game master / LLM is an
enhancement, never a requirement), and each item names the systems and configs it touches.

## Status (2026-11-24)

Every row of the order of work has landed except B3 (conditional, not needed yet) and
the numbers G3 measured but left for the designer to choose. The section notes below
("**Built:**", "**Not built:**", "Measured") give the detail; this is the summary.

### Done

| Item | What landed | Commit |
|---|---|---|
| G1 | metric runs under game-master policies (steward, hoarder, feaster), `contracts.seal()`, bands, forecast calibration, interrupt causes, winter, rivals, challenge and event reports | b816bce and later |
| G1 fixes | sickness hits hungry camps; a stay-at-home craft trial | 4840ae4 |
| H1–H3 | ranks earned by deeds, gates as data, the naming rite and feathers | 6ab4aa0, fe7dbfe, 7a67754 |
| A0/A1 | the odds before sealing (calibrated), the leader's field log with callbacks | d621267 |
| A tuning | outposts interrupted 94% → 50% (Ford ambush once, floods only near the river, the leader judges a wound in an ordered fight) | df9b972 |
| B1 (+ most of B2) | the autumn council, winter kinds picked by the director, signs; winters with teeth (signature hardships pass the cap) | 327e5cc, 8a28aaa |
| C1 | dated ledger of what passed between the clans, quoted by chiefs; chiefs reign, die and are succeeded | ed23007 |
| C2 | the nemesis: one hostile clan with a face, stages by era, an ending | 0a3a3b8 |
| D1/D2 | a remembered find (rumoured until found) and a first-day fever; overpop moved to day 3 | 48983c8 |
| A2/A3 | small contract events settled by the leader in character; quarrels and songs between crew | 91c95e6 |
| I (Era 1) | Lookout Tower, Smokehouse; building `effects` | 18fe442 |
| I (Era 2) | Longhouse, Temple (shrine → temple → altar); `era`, `ritual_mult`, one `struct_block()` | a52e346 |
| F | the council's challenges | b8c7766 |
| E1/E2 | the last stand (hold, or join a friendly clan: the merged ending); heritage remembered by the next game | 5e53363 |
| I (Era 3) | Stone Wall, Trading Post; the grand altar needs a Master Builder | 0956e11 |
| G2 | balance canary in CI against `tests/balance_baseline.json` (warns, never fails) | 552f03d |
| G3 | director cap and decay measured (`--cap`, `--decay`); nothing changed | 5158eae |

### Left

**Built since (with the city plan, `ROADMAP.md` §5):** I2's two rules (raids go for
what's outside the wall first and torch the fields; house fires leap between packed
buildings), I5 (camp → village → town → city, named, an achievement, the clans speak
of it), and the food economy the bands below asked for (worked fields, the harvest
rush).

**Not built (designed):**
- **I2, site factors:** the one river-band width shared by ghost, spring and Great
  Flood; a bloodied band turning home; the ghost's site words; `sim.site_value()`;
  the Steward scoring sites; the G1 check that random placement does worse.
- **I3, timing:** a best season per building, a food reserve beside `wood_reserve`.
- **The reactive successor nemesis** (only if G1 shows the late game dragging; the
  director's `bored()` itself is built: after days of calm a hostile clan raids or a
  wolf pack comes, `director.json` `bored`).
- **B3, the frozen river** (only if winters prove lacking).

**Partial (gaps noted in the sections):**
- A0: the lookout tower helps the forecast only through what it reveals.
- A3: trait-pair weights for friction events.
- B2: the no-repeat rule looks back one winter, not two years.
- C2: no escalation on the peaceful setting.
- E1: no "flee to new land" (it would move the village itself). The merged ending is
  its own config entry (`legacy.json` `merged`), not a `kind` field on the paths.
- F: challenges are proposed by the built-in rules; the Council's LLM does not propose
  them yet.
- H: trials set up through contracts with the forecast; a mercy if the last Proven
  crafter dies.
- I: the temple's part in rank initiations and festivals; stone wall blocks all face
  one way.

**Tuning and measurement (open):**
- Food near-misses stay at 75–100% for every policy (band 60–90%), and normal games see
  no starvation deaths; the director can't fix this, the food economy must.
- The nemesis is quiet: 0–1 raids in 20 days under the steward.
- "No one dies this winter" failed in every steward and feaster run.
- G3's numbers are the designer's call: decay is the lever on normal (0.8–1.0 softer,
  ~2.5 harder); harsh is set by its multipliers, not its cap. Any change needs a new
  canary baseline (`--write-baseline`).
- **Growth against the band's hunger trap** (the society model, `society.md` §14.6): a
  designer's knob, not decided. `config/society.json work`: `secure_from`/`secure_to` (births
  and newcomers by food security: a step at 1.2 today, halving growth; a ramp 1.0 → 1.2
  brings it back but let 2 of 5 60-day bands die out), `gather.food` (0.25), `reserve_days`
  (2), each overridable per challenge level (`work.by_challenge`, as `director.json`'s
  levels). Measure with G1 (famine band, hours under half a day's food: the metrics'
  society report) and `tools/pacing.gd` (people at day 60, bands that die out).
- Most measurements used 4–8 seeds; the food bands and the winter-choice table want
  16–20.
- Linux CI reproduces macOS runs exactly (same per-seed numbers, 2026-11-24). The canary's
  first CI run fired: 8 metrics moved after the baseline, mostly the steward's food
  (near-miss and famine 0% → 100%), but 8 seeds showed it was noise: a 2-run canary
  warns on any change to the random draws (`ROADMAP.md` §4).
- What comes next is in `ROADMAP.md`: most items left here fold into the steps of
  `city_proposal.md` (I5 is its tiers, I2's raid targeting and fire spread its town
  challenges, and its worked fields are the food-economy fix the bands above call for).
- Playtest judgments (Open questions): the words of the winter signs, whether the
  site factors read without a tutorial.

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
- **Built:** `contracts.forecast(plan, leader)` → `{risk, pct, reasons, words}`, numbers and
  words in `config/contract_log.json` `forecast`; kept on the contract as `c.forecast`,
  shown in the dialog ("The odds: …"), in `negotiation_ctx()["forecast"]` (the LLM is told
  not to claim another number) and in `summary(c)`. Calibrated with the G1 harness (see G1).
  The director's tension is not used (the leader can't know it); only its mercy lowers the odds.

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
- **Built:** `contracts.field_say(c, trigger, arg)` (a GM verb too) and `_field_log()` per
  tick: progress 25/50/75, first building, step done, crew level-up, landmark, weather,
  nightfall, near miss, chatter after 30 s of silence, done; callbacks `quiet:<reason>` at
  50%, `foreseen:<reason>` / `unforeseen` on an interrupt (`contracts.foresaw()`). Lines by
  `trigger:archetype` in `contract_log.json` `log`; panel always, bubble by chance, chronicle
  only for the first building and the callbacks.

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

- **Built** (A2 with A3's events): `contract_log.json` `events` — wasps, spoiled rations,
  strange tracks, a white raven, a spring, and the friction pair: a quarrel between two
  rivals on the crew (`pair: rivals`) or a song between two friends (`pair: friends`).
  Rolled in `contract_system._events()` every 30–55 s of working time (chance 0.75), once
  each per contract; the leader picks by archetype weights per option (`arch`); outcomes
  are `story.run()` actions (morale, hurt, give, xp, bond, devotion, remember) on new
  people vars (`one_who`, `a_who`, `crew_who`: the new `ids:` people spec). Reported in the
  contract log and the chronicle; nothing pauses. `contracts.happen(c, id)` is the game
  master's verb. Not the dilemma format's `story.pose()` path (the leader decides, nobody
  is asked, so a pose would have no one to answer it). Measured: 1.2 events per steward
  contract (about one a minute of work), outposts still 50% interrupted.

### A3. Crew friction
- Pairing rivals on a crew (`u.bonds < 0`) generates friction events (A2 pool), slower
  work (`work_mul` term), or a bonding arc if they survive a crisis together
  (`life.add_bond` already exists).
- Culture/trait interactions (`devout` leader + `belligerent` helper) seed the event
  weights. Data: `config/life.json` or `contract_log.json` tables.
- **State:** rivals nearby already slow work and friends speed it (`life.json` bonds
  `work_bonus`), and fighting side by side builds bonds; the friction *events* landed with
  A2 above. Trait-pair weights are not built.

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

- **Built** (with the part of B2 it needs): `director.pick_winter()` picks the kind when
  autumn begins (`director.json` `winter`: no easy repeats, mild more often in distress,
  harsher for a well-stocked tribe); `hz` reads it in winter (`events.json` `winters`:
  blizzard chance, cold, wolves, spoil, yields, herds leaving). The council is
  `dilemmas.json` `autumn` and replaces the autumn Harvest Festival while challenges are on:
  feast (mild), smoke the meat (`prepare` spoil x0.4: lean), firewood (`prepare` cold x0.6:
  white), slaughter the oxen (`slaughter`), the last hunt (a skill chance). Two signs are
  quoted, each true with chance 0.75; the kind is named when winter comes and kept in
  `hz.winter_log` (`hz.winter_summary()` for a game master; hidden from `hz.summary()` and
  the forecast). The hunting party is a skill-chance option, not a contract: a contract
  would outlive the dilemma and needs a leader picked, which the council doesn't do.
- **First measurement** (`tools/metrics.gd --choose=autumn:N`, steward, 4 seeds × 10 days;
  the same seed gets the same winter whatever is chosen, so the choices pair up): in the
  lean winter (seed 3) the lowest stores were feast 33%, hunt 21%, firewood 62%,
  **smoke 79%**, and the feast's winter cost 6 lives against 0 for smoke and firewood. The
  bets are real, but two gaps: **the feast never paid** in these measures (its gain is mood,
  which G1 doesn't score yet), and **winter rarely kills by cold or hunger**: winter deaths
  were all beasts and contracts, and the wolf winter took at most one. Next: more seeds, a
  mood/morale measure, and a wolf winter with teeth before B2's variety is tuned.
- **Winter given teeth** (`--winter=<kind>` forces the first winter; the report now shows
  winter mood, packs, blizzards, director holds, cold damage): the cause was the director.
  It held 8–11 hardships every winter, so a white winter had **0 blizzards** and a wolf
  winter 0–1 packs: the chosen kind was erased by pacing, exactly the theater the
  decision above rules out. Now a kind's `signature` hardships (white: blizzard, wolf:
  wolves) pass the director's cap unless the tribe is in distress; every white winter has
  its blizzard and wolf winters their packs (one wolf bigger). The firewood option also
  fences the camp (`prepare` wolves x0.5): the bet against white *and* wolf winters. The
  feast's glow now lasts through winter, against a new winter gloom (`rules.json` mood
  `winter` 12): winter mood ~73 after a feast against ~63 after any other choice.
  Paired runs (8 seeds, same winter per seed): white winters cost 2 lives after a feast,
  0–1 after smoke or firewood; the lean winter 6 after a feast, 0 after smoke or
  firewood. Still one or two seeds per kind: suggestive, not settled. Winter still rarely
  kills by cold alone (fires are close); that is fine while hunger and beasts do the work.

### B2. Winters differ
- **Mostly built with B1** (the kinds, the director's pick with no easy repeats, the signs,
  their effects on weather, cold, wolves, spoil, yields and herds, `signature` hardships).
  The no-repeat rule weighs last winter only, not the last two years.
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
- **Built:** `c["ledger"]` of `{t, kind, args}` (`rivals.note()`, called from `_deed()` and
  from raids, thefts, kills, seals, trades, feasts; dilemma options write theirs with the
  new `ledger` story action), kinds and weights in `rivals.json` `ledger`. Quoted
  (`rivals.quote()`: the weightiest, fading over `half_days`, dated "this spring / last
  winter") in the demand, call and submit dilemmas and as the offline chief's opening line;
  the LLM chief gets `what_passed_between_us` and `bring_up`; `summary()` shows
  `remembers` and `chief_temper`. Chiefs reign `reign_days` and are succeeded
  (`rivals.succeed()`) by a chief of another temper (`chiefs.tempers`: the relation the
  clan drifts to, raid hostility, parley value); the relation is drawn halfway to the new
  chief's, the ledger stays, and the new chief quotes their forebear. The first chiefs are
  all "wary" (neutral) so the existing balance holds until a succession.

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
- **Built:** `rivals.json` `nemesis`; picked at first contact by `nemesis_score()`
  (-relation, +15 if martial, at least 15) or by day 6 the worst clan met;
  `rivals.set_nemesis()` for a game master; `feud_id()` while the feud runs. The nemesis
  raids from relation -5 (others from -15), on a 0.75x timer, the others on 1.5x; stages by
  era add warriors (+1, +3), demand more (x1.3, x1.7) and come sooner. Achievements for its
  first raid held off and for the feud's end (Friendly or better, peace, vassal, or beaten
  at home twice); the ledger records "marked" and "feud_over". **Not built:** escalation on
  the peaceful setting (demands there would need the refused demand's raid made
  level-aware, which other paths rely on). **Measured** (20 days, 4 seeds): on The Ford the
  nemesis is always the Red Ochre; it raided 0–1 times under the steward, 1–3 under the
  feaster, other clans 0; 1–3 chiefs succeeded per run; no feud ended in 20 days.

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
- **Built.** D1: `sim.remember_find()` at the start (`discovery.json` `remembered`: the
  elder best at lore remembers the first of willow, yarrow, mushroom, tubers that grows on
  the map, and where it grows). It is *rumoured* (`sim.rumoured`): noticed 3x as easily,
  a search quest goes for its group unless the chieftain says otherwise, and the offline
  leader searches the kind of place it grows in (the LLM leader sees `the_elders_remember`).
  Search quests were already open from minute one. D2: the `first_day` dilemma
  (`rules.json` triggers `first_day`: 50 s in): someone who is not the elder falls ill, and
  the elder names the old cure. Search for it (opens a search contract: the HUD's
  `open_seek`), rest and broth (10 food, morale), or keep working (mood). On The Ford the
  remembered find is Willow Bark, which breaks fevers. Found while building it: the
  overpopulation dilemma fired at 45 s in every game (the tribe counts 12 with its
  children), a second day-1 pause with an absurd text ("game is thinning"); it now waits
  for day 3 (`triggers.overpop.day`), so the fever is the day's one teaching pause.
  `--demo=opening` screenshots it.

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
- **Built.** E1: `rules.json` triggers `last_stand` (`pop_below` 4, from day 3; the new
  condition key), the `last_stand` dilemma: hold the fire (morale, mood, a sworn memory)
  or join the friendliest clan that would take us in (`legacy.refuge()`; the option `needs`
  it). Joining is the new `merge` story action → `legacy.merge(clan)` → the `merged`
  ending in `legacy.json` (its own title, text, saga opening and closing; restart only).
  Not built: "flee to new land" (moving the village itself touches every system keyed on
  `D.VILLAGE`). E2: when a chronicle ends and a new one begins, the HUD writes
  `legacy.heritage()` (the most renowned person, the ending, the clan joined) to
  `user://heritage.json` (`SaveGame.write_heritage`); `main.gd` gives it to the next fresh
  game as `sim.heritage` (not to loads or screenshots), and `sim._remember_heritage()`
  places "The Old Fire of <name>" (a stones landmark with lore and devotion) on our side of
  the water, has the elders tell of them, and makes a clan they joined start friendlier
  with a `kin` ledger entry (`legacy.json` `heritage`).

## F. Player-set stakes mid-run (attachment, replay)

- Council-proposed challenges ("no one dies this winter", "befriend a rival before
  Era 2", "settle across the river") built on `inv.feat()`; proposed via
  `policy.council_ctx()`, tracked in the HUD, rewarded with mood/lore.
- Each challenge is data: `{id, when (holds), track (a condition), reward}` — reuse
  `story.holds()` as the checker.
- **Built:** `challenges.gd` (`sim.challenges`), `config/challenges.json`: five challenges
  (no one dies this winter, a friend among the clans before the second age, an outpost
  within 4 days, full stores before the frost, a temple before the third age). From day 2,
  every 2.5 days with none running, the first whose `when` holds is put to the chieftain as
  a dilemma (accept / not now). Goal and fail are `story.holds()` conditions (new
  `friend_any`, `outposts`) plus measures counted from acceptance (`deaths_since`,
  `outposts_since`), with `days` or `until` a season and `hold` (the goal must still stand
  at the end). Met: `inv.feat("challenge")` and `reward` actions; failed: `penalty`. The HUD
  shows the challenge under way; `offer()`, `accept()`, `summary()` for a game master.
  Proposed offline (the speaker is the Steward or the best at lore); the Council's LLM
  (`policy.council_ctx()`) does not propose them yet. Measured (3 runs x 14 days): the
  steward meets the outpost and full-stores challenges, fails "no one dies this winter"
  every time (contract and beast deaths count) and "befriend"; worth tuning once more seeds
  are in.

## H. Ranks earned by deeds (attachment, accomplishment)

> **Status (first slice landed):** `config/ranks.json` + `ranks.gd` (`sim.ranks`). A rank
> is a band of levels (Proven 5–7, Master 8–10), so it is read from the level and old
> saves, heroes and culture-pack people starting above Lv 4 simply hold their rank.
> Routine XP stops full at the top of a band; the trial's deed (`u.deeds`, recorded by
> `ranks.deed()`) steps them in. Deeds done before the trial opens count. Trials as
> built: kills are credited to the killer (not yet "lead a hunt"); the craft Proven trial
> is "lead an outpost to completion, or a masterpiece" (no longhouse, which fixes the
> loop with the upgrade gate); lore Proven is any breakthrough (heal near death not
> yet); combat Proven is being in an emergency that ends with a war band driven off.
> Craft and combat Masters teach through `u.mentors` (contract crews). The Centurion
> Aura and the master trader read a rank; `D.SKILL_UNLOCKS` is gone; level-ups are a
> small popup only; rank-ups log, remember, and the tribe's first of each is a feat.
> `ranks.grant()` and `ranks.summary()` for a game master.
> **Second slice:** H3's gates are data (`ranks.json` `gates`): taming, bigger pens, the
> craft gate (upgrades, renovations, bronze), the lore keeper, war leaders and War Chief,
> longer treaties. Deviation: War Chief needs a *Proven* warrior, not a Master — a Master
> needs a war won, which would leave most runs without a War Chief. The lore Proven row
> (healer, wise one) stays at lore 3 as H1 says (reachable by work).
> **Third slice (H2):** the naming rite — at the next dusk the person is home, the
> tribe dances in a ring by the fire (`ranks.json` `rite`: story actions), the person's
> spirits lift and an empty epithet takes the title; one feather per ranked skill in
> the hair (drawn over the sprite, colours in `marks`; a Master's is long and
> gold-tipped), so no rebake. **Not yet:** trials set up through contracts with the A0
> forecast; a director mercy if the last Proven crafter dies (watch it in G1).

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
  the Proven trial opens Lv 5–7, the Master trial Lv 8–10. A trial opens only when
  routine XP has filled to its ceiling (the sheet says so), so the deed is the door,
  not a clock. Each trial is a deed from data — Proven is *you proved yourself under
  pressure*, Master is *you changed the tribe*:
  - forage: Proven — lead a hunt that brings down a wolf or bigger; Master — lead one
    that brings down a saber-tooth tiger.
  - craft: Proven — be lead builder of a longhouse, or make a masterpiece (`folk`
    already rolls them); Master — teach: one of their past crew members finishes a
    Proven craft trial of their own. Not *during* the master's build (a crew member
    leads nothing); later, on their own contract — the crew lists in `contracts`
    already record who worked under whom, so this is a lookup, not new state, and
    H3's teaching reads the same lists.
  - lore: Proven — heal someone near death, or lead research to a breakthrough;
    Master — lead the research that opens a new era.
  - combat: Proven — stand in a defence that drives off a raid (present and fighting
    when the war band gives up and flees); Master — lead a war contract to victory.
  - trade: Proven — seal a treaty or a caravan bargain; Master — bring a clan to an
    alliance or vassalage.
- One trial per rank is enough, and no more gates above Master: a Master's continuing
  game is teaching (H3), not more trials, and past Master the levels stay quiet
  numbers feeding the per-level effects that already exist (combat DEF, the trader's
  haggle, masterpiece odds) — no third rank, no new curve to tune.
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
  "proven"`) instead of a number, so retuning the curve can't silently move them —
  including `unit_def`'s Centurion Aura (a hardcoded `combat >= 5`) and the two HUD
  reads of Lv 5 (the unlock text and the blue column tint).

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
- **What each rank unlocks** (replacing `D.SKILL_UNLOCKS`; every entry is a gate on
  something that exists, so each is one check, not a new system — and no gate may
  block its own trial: what a trial requires, an earlier rank or no rank provides).
  This is also an audit of today's Lv-5 "unlocks": only the Centurion Aura has a hook
  in the rules — "Beast Taming", "Megalithic & Bronze Craft" and "Totem Miracles"
  are labels on a log line. The rank table either makes them real (the forage and
  craft rows do) or they go: one honest system instead of two promises that disagree.

  | Skill | Proven | Master |
  |-------|--------|--------|
  | forage | a calf is tamed at dawn only while a Proven forager tends the herd (the `_herd` roll; the first ox still comes with the pen) | each pen holds one more ox while a Master forager lives (`ox_cap`) |
  | craft | upgrades, renovations and the smelter run while a Proven crafter lives (one check, the way `has_bronze` reads state) | the stone wall and the grand altar need a Master Builder |
  | lore | heals as a healer (`healer_lore`) and is the eclipse's wise one (both lore-3 checks today) | a living lore Master is a keeper of every tech: one check in `evo`'s oral-loss rule |
  | combat | the Centurion Aura (exists, `sim.gd`) and may lead a war contract | may be appointed War Chief (`sim.appoint`) |
  | trade | the master trader's prices (`master_lv` in `folk.haggle` becomes a rank) | treaties they seal hold longer (their seal sets the days) |

  The craft row is the stake H3 wants: if the tribe's only Proven crafter dies, bronze
  stops until someone else proves themselves. Combat is why the no-blocking rule
  exists: leading a war contract sits at Proven because winning one is the Master
  trial — gate it at Master and no one could ever qualify.
- **Know-how lives in the family line** (one person = one family line). A master can
  teach: people working beside them learn that skill faster, and a new line grown from
  theirs starts part-way up it. If a master dies before anyone else holds the rank, it
  is gone — `evo`'s knowledge keepers / oral loss, now for crafts. Protecting and
  teaching masters becomes part of the game; losing a veteran costs something lasting.

### H4. Shape in code
- `config/ranks.json`: per skill, ranks `{cap_lv, title, trial (a condition),
  rewards (effects in the `{stat, mul|add}` format, unlocks)}`; texts with zh.
  `D.SKILL_UNLOCKS` folds into these rows (one unlock list per rank, no second
  table), and the rules that read a level (`healer_lore`, `skilled_lv`, `master_lv`,
  the Centurion Aura) read a `sim.rank(u, skill)` query instead of a number.
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
- **Upgrades before new types.** Palisade → stone wall, totem shrine → temple → grand
  altar, large hut → longhouse: the camp visibly grows up instead of sprawling
  (`sim.upgrade(id, to)` and `rules.json` "upgrades" exist — hut → large hut and
  shrine → altar are already rows there, so the temple slots into a chain that
  exists; era styles via `D.STYLED` exist).
- **No new resources** (the not-goal): costs use wood, stone, copper/tin, goods, lore.
- **No per-building management**: buildings work by being there and by who lives near
  them, as today. No worker slots, no queues, no upkeep menus.
- **Each era has a headline building** the player looks forward to, and each one feeds
  another section: walls and towers meet C2's Era-3 war band, the temple runs H's
  initiations and B's festivals, the master-built grand altar is H3's payoff.

### I2. Where it's built matters
Every spot is a trade-off the player can read, built from the map's real geography
(rivers, fords, the flood band, the wall) rather than a hidden bonus grid. The
map has no elevation (the "hills" ores use are only far-off spots), so nothing here may
assume high ground.
**Four site factors** are all a player ever has to learn (the eight-factor draft was a
syllabus, not a choice); each shows one face in the ghost's words:
- **The river band** — one factor, two faces. Inside the spring flood band, fields
  grow more and fish and water are close, but floods knock buildings down (the silt
  feed `nat.food_mult` and the flood damage already exist). The best land is the
  riskiest. Today the band is six numbers that can disagree: the drawn `flood_half()`
  (peaks at river 46 + 110), the spring flood's damage radii (170 buildings, 160 wild
  plants, 130 people) and the Great Flood's hardcoded 220/260 (`sim.gd`). One band
  width in config — ghost, spring flood and Great Flood all derive from it — or the
  placement warning lies.
- **Inside or outside the wall.** The palisade's size is chosen (`s.size`) and costs
  with it: a big ring is expensive and slow, a tight one leaves the fields, docks and
  pens outside. Raiders go for what's outside first (food in an outer granary, the
  pen's oxen); a wall is a decision about what you're willing to lose. `sim.inside_wall`
  exists; what's new is raid targeting: today a raid marches on `D.VILLAGE` (or an
  outpost), so "outside first" is a rule `rivals.launch_raid` has to learn — and it
  stays one target choice, because walls block no one's feet today (`inside_wall` is a
  DEF bonus, not a fence): raiders *prefer* the undefended granary outside, take it
  (`rivals.steal` already exists, and the thief turns home) and usually leave; only
  C2's big war band goes for the village itself. No pathing, no gate AI — where the
  defenders stand is the player's call (crisis `hold`), not a door's.
- *Is that enough Era-2 payoff for a wall?* Yes, if what's behind it is *defended*: a
  raider engaged by anyone fights instead of stealing (`update_predator` only loots
  when nobody is in reach), so a camp where everyone lives inside the ring is a camp
  of +3-DEF defenders — and the second half of the rule is a war band that is bloodied
  and still lootless turning home: the thief's turn-home (`steal` → `fleeing`),
  triggered by losses instead of loot. One honest limit: with nobody home, walls stop
  nothing (they block no feet) — which is why the tower's day-early warning, calling
  people back, matters as much as the stone. Measurable: food lost per raid, walled
  vs. unwalled, in G1.
- **Packed or spread.** A tight camp is cheap to wall and quick to walk, and burns
  together; a spread one is safe from fire and hard to defend. This needs one new rule:
  today fire reaches buildings only from burning trees (`nature.gd`, `building_radius`)
  or a lightning strike on one building; a burning building must also set neighbours
  within a config radius alight. That rule, not a placement bonus, is what makes
  spacing a choice — and it is cheap because its answers exist: a burning building is
  the wildfire state on a structure (the `firefight` reaction already has
  `near_building` and knows to run and beat out flames), and the `burns` flag (I6)
  says which types catch.
- **Close to the work and the ford.** Distance is already walking time (the granary as
  a drop-off near the fields) — keep that the main pull, so where people live and work
  shapes the layout naturally. Fords fold into the same measure (`D.FORDS`,
  `D.route()`): raiders cross there, and a tower near one is the single building whose
  whole value is its place — it sees them a day early and feeds A0's forecast; a tower
  in the middle of the village sees them at the door.

Keep both new rules (fire spread and raid targeting): each is one rule, and each makes
a *different* factor real — spacing and the wall. If one must go, fire spread goes
first: fire already reaches buildings from burning trees, while raid targeting carries
the bigger Era-2/3 payoff and C2 leans on it.

Two non-factors keep it honest: auras work on the **people around them**, as the
bonfire and weapon rack do now — no "+10% next to a temple" adjacency puzzles; a
temple matters because the village gathers there. And land kind stays about the wild
(herds, weather, wildfire chances) — the fertility story belongs to the river band, so
no per-tile soil bonus.

The placement ghost shows the site's value and risk in words, from the same factors
("Fertile river soil: fields grow half again as much. Flood land: about one spring in
three."), the building version of A0's forecast. `improve.gd` scores the same factors,
so the Steward lays out a sensible camp when the player doesn't, and a game master
gets `sim.site_value(type, pos)`.

**The Steward plays it safe.** If the Steward's layout were as good as the best one,
placing buildings yourself would be pointless. Today it already is cautious by
construction: `improve.spot()` searches rings around the village, keeps a `gap` between
buildings and never comes within `wet_reach()` of the river — and it never builds a
palisade at all (walls are not in the improvements list; they are the player's move or
a settle contract's). Keep that shape: sound but never bold — no river-band fields,
no tower out at the ford. The bold layouts are the player's to choose, and that's
where the reward is.

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
| 2 | Temple (shrine → temple) | lore, morale | rituals, festivals, rank initiations; the centre the village gathers round |
| 3 | Stone wall + towers (palisade upgrade) | Era-3 raids | holds against C2's war band if up in time; how much it encloses is the choice |
| 3 | Trading post | trade | caravans come more often and pay better (`rivals` traders); by the road or ford they arrive on |
| 3 | Grand altar (temple → grand altar) | legacy | the era's wonder, already Victory by Wisdom's piece; the shrine → altar upgrade is already a `rules.json` row, so the temple slots into a chain that exists — the new part is the Master Builder requirement (H3) |

No separate megalith: the grand altar already is the Era-3 wonder (Yinglong, Victory
by Wisdom), so a second wonder would compete with it. Making it the end of the
shrine → temple → altar line gives the religious path one building that grows up
through the eras instead of three unrelated ones.

Cut with the megalith, for honesty's sake: the **Gate** (walls block no feet, so a
gate that "sets everyone's walks" is a door the game can't back; a rally point is
already the player's choice in a crisis) and the **Workshop** (teaching reads the
contract crews, H1; "near the stone and wood shortens every job" is the walk-to
factor, free). Seven candidates stand; Era 2 keeps the longhouse and the temple.

- **First slice built: the two Era-1 candidates.** *Lookout Tower* (`structures.json`:
  `sight` 560, `lookout`): reveals the land far round it (what it sees feeds the A0
  forecast through the fog) and calls out a war band or a wolf pack the moment it comes
  into sight (`sim._lookouts()`, once per band; `spots` texts). *Smokehouse* (`tech` fire,
  `effects` spoil x0.6 through the new `sim.struct_mul()`: the effect-stat format on a
  building, one per type counts): the Steward lays one out in autumn; it only pays if it
  stands before the frost. Both have baked models (`art_baker` `_tower`, `_smokehouse`,
  `ART_VERSION` 21) and hand-drawn fallbacks. Not yet: the tower feeding the forecast
  directly (beyond the fog), site factors (I2), the village's name (I5).
- **Second slice: the Era-2 upgrades.** *Longhouse* (large hut → longhouse, houses 8,
  `hearth_bond`: those asleep under its roof grow closer, `sim._hearths()`) and *Temple*
  (totem shrine → temple → grand altar: the religious line now grows up through the ages;
  more lore, `ritual_mult` 2.0). New building keys: `era` (the age a type needs, checked
  with `tech` by the one `sim.struct_block()` that placement, upgrades, the build menu and
  the Steward now share) and `ritual_mult` (replaces the shrine/altar list in the ritual
  rule). Baked models `_longhall`, `_temple` (`ART_VERSION` bumped). The temple's part in
  rank initiations and festivals is not built.
- **Third slice: the Era-3 buildings.** *Stone Wall* (palisade → stone wall, third age:
  +6 DEF inside, only quakes knock it down; drawn as stone blocks with a tower every 8th,
  `stakes`/`tower_every`; the ring code and its drawing now key on `ring`, not on the
  palisade's id; an upgrade of a ring costs by its size). *Trading Post* (third age;
  `effects` `trade_every` x0.65 and `trade_rate` x1.25, read by `rivals._traders` and
  `trader_arrived`). The grand altar now needs a Master Builder (`gate` great_works in
  `ranks.json`, checked by `struct_block`). Baked models `_wall_stone`, `_wall_tower`,
  `_trading_post`. Not built: raid targeting by the wall (raiders going for what's outside
  first) and the war band turning home when bloodied, both I2's; wall blocks all face one
  way rather than following the ring.

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
- Site factors are a small set of named verbs in code (`river_band`, `in_wall`,
  `crowding`, `near_ford`, `walk_to` — one per factor above, `near_ford` used by
  towers), each building's config picks and weights them
  (`{"site": {"river_band": {"food": 1.5, "risk": ...}}}`),
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
  - Food-floor near-misses (the stores under half a day's eating; until 2026-11-27 food < 15%
    of cap, which read a camp with days of food as a close call once the granaries held a
    winter, `society.md` §14.5): 60–90% of runs at least once, **not**
    ~100% — a threat in every single run that never kills is a jump-scare without
    teeth, and it means granaries bought nothing.
  - Real famine consequences (a starvation death, a sickness wave while the stores are under
    half a day's eating, or a family leaving in
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
- **G1 skeleton built** (`tools/metrics.gd`, policies in `tests/policies/`, contracts
  sealed with the new `contracts.seal()`). **First baseline** (The Ford, 4 seeds × 12
  days, normal hardships; a game day is 90 s at 1x):

  | policy | near-miss | famine | deaths | starved | killed | empty-store hours | contracts | interrupts | pauses/h | max gap | era 2 | craft gate open |
  |---|---|---|---|---|---|---|---|---|---|---|---|---|
  | steward | 100% | 0% | 2.5 | 0 | 1.2 | 11 | 4.0 | 7.8 | 0.13 | 1.5 d | 100% (d4–5) | 100% (d2) |
  | hoarder | 75% | 0% | 0.2 | 0 | 0 | 0 | 3.0 | 0.2 | 0.09 | 2.4 d | 100% | 0% |
  | feaster | 100% | 0% | 4.8 | 0 | 2.8 | 12 | 5.2 | 9.5 | 0.13 | 1.3 d | 100% | 75% |

  Findings, to tune against (none tuned yet):
  1. **The food floor never bites.** Stores run empty in almost every steward/feaster
     run (up to 28 game hours empty) and nobody starves, sickens from hunger or leaves:
     famine consequences 0% for every policy (band 10–25%). Exactly the "always
     triggers, never bites" floor this section warns about. Skill sensitivity shows in
     deaths and empty hours, but not in consequences.
  2. **Deaths come from contracts, not hunger:** feasters seal more contracts and lose
     more people to beasts and raids on the way.
  3. **The hoarder never opens the craft gate** in 12 days: its trials are "lead an
     outpost" or "a masterpiece", and a tribe that sends no outposts has neither. A
     second craft trial that a stay-at-home tribe can do (the brainstorm's "the first
     granary or council ring", built with them leading) would fix it.
  4. Pacing: ~3 pauses per game day (one per ~30 s at 1x), and the longest quiet
     stretch is 1.3–2.4 days (2–3.5 min at 1x). Era 2 always arrives on day 4–5.
  **After the first fixes** (same runs): findings 1 and 3 addressed. Sickness now grows
  with how long the camp has gone hungry (`events.json` sickness `hungry_*`: risk climbs
  per hungry hour, the hungriest fall ill first, it spreads faster among the hungry, and
  after 6 hungry hours the director can't hold it back; the hunger clock eases back
  slowly once fed, since stores bounce between empty and a few berries). The craft
  Proven trial gained "raise the tribe's first granary or council ring". Result:
  famine consequences steward 25%, feaster 25% (in band), hoarder 0% (good play
  escapes, as intended); skill sensitivity 0.29 → 0.54; the hoarder's craft gate opens
  in 75% of runs (day 6–10). Still open: near-misses at 100% for steward and feaster
  (band 60–90%), still no starvation deaths, and feaster ≈ steward on famine at 4 seeds
  (run more seeds before tuning further).
  **Forecast calibration** (A0, same runs, 47 contracts): per reason the forecast now
  matches what happened (enemy_attack 50% forecast / 49% first abort, natural_disaster
  30 / 31, leader_wounded 10 / 6); the top-forecast reason was the actual abort in 61% of
  interrupted contracts (floor 60%; 81% before tuning, when the numbers were off by 2–3x
  but beasts ranked lower). New finding: **outpost contracts were interrupted in 94% of
  runs** (research 25%): every outpost paused at least once, so an interrupt was no
  surprise. The harness's cause list showed why: The Ford's scripted ambush fired on
  *every* outpost at 45% (meant as the first one's set-piece), every flood stopped every
  contract on the map wherever it worked, and each tiger fight paused twice (the attack,
  then the leader's wound from the same fight). **Tuned:** the ambush is the first
  outpost's only; a flood stops a contract only while some of its crew are within
  `contract_reach` of a river; a wound taken in a fight the chieftain already ordered is
  the leader's call by temperament (`contract_log.json` `judged`, no pause, said aloud).
  Result: outposts interrupted 94% → **50%** (new band 40–70%), interrupts per run
  steward 6.8 → 2.8, feaster 8.8 → 2.5, contract deaths down. Forecast re-tuned against
  it: risk 0–30% → 9% interrupted, 30–60% → 50%, 60–100% → 71%; top reason 68%.
  5. Found while building it: requiring full XP at Lv 4 on top of the deed kept the
     craft gate shut in every run (the leader moves to the outpost and stops building);
     the trial now opens on reaching Lv 4 and the deed is the door.
- **G2.** Wire the metric run into CI as a balance canary: config edits that shift the
  distributions show up as diffs.
  **Built:** `tools/metrics.gd --baseline=<file> [--write-baseline]` compares each policy's
  G1 summary with `tests/balance_baseline.json` (2 runs x 8 days, steward and feaster, The
  Ford; about 75 s) and reports every metric that moved past `TOLERANCE` (shares by 0.26,
  counts by 35% or at least 0.6), as GitHub `::warning` annotations on CI. The CI step is
  `continue-on-error` and the tool never fails: a canary, not a gate, since every gameplay
  change moves a deterministic run. Not yet known: whether Linux CI reproduces the macOS
  baseline exactly; the first CI run will show it (small float drift stays inside the
  tolerances).
- **G3.** Tune the director's per-level caps against these curves, not by feel.
  **Measured, not tuned** (`tools/metrics.gd --cap=N --decay=N`: overrides on a copy of
  `director.json`; 8 seeds x 12 days, steward / feaster, The Ford):

  | normal level | deaths | killed | famine | interrupts | pauses/h |
  |---|---|---|---|---|---|
  | cap 2.0 | 4.4 / 4.0 | 0.9 / 0.6 | 0% / 0% | 2.5 / 2.4 | 0.15 |
  | cap 3.0 (now) | 4.0 / 3.1 | 1.5 / 0.9 | 13% / 13% | 2.5 / 2.1 | 0.15 |
  | cap 4.5 | 4.0 / 3.9 | 1.5 / 0.4 | 0% / 13% | 2.4 / 2.5 | 0.16 |
  | decay 0.4 | 3.4 / 1.1 | 0.4 / 0.1 | 13% / 0% | 1.6 / 1.8 | 0.15 |
  | decay 1.6 (now) | as cap 3.0 | | | | |
  | decay 4.0 | 5.5 / 3.2 | 1.4 / 0.4 | 13% / 25% | 3.2 / 2.9 | 0.16 |
  | harsh, cap 5 (now) | 9.1 / 5.1 | 2.8 / 1.1 | 63% / 38% | 2.5 / 2.5 | 0.15 |
  | harsh, cap 7 | 9.5 / 5.5 | 2.4 / 1.4 | 50% / 38% | 2.8 / 2.4 | 0.15 |

  Findings: on normal the **cap barely binds** (2.0 to 4.5 changes little); **decay is the
  lever** (slower easing holds more back: fewer deaths and contract interrupts, the
  feaster's deaths 3.1 → 1.1 at decay 0.4; faster easing the reverse). **Harsh is set by
  its multipliers, not its cap** (5 vs 7 the same): it is a much harder game (famine
  38–63%, the first starvation deaths). **Pauses per hour don't move** with either knob
  (~0.15): the pause rhythm comes from dilemmas and contracts, not hardships. Near-misses
  stay 75–100% everywhere: the food floor is not the director's to fix. Choosing the
  numbers is the designer's call (how harsh normal should be); none are changed yet.

Why these bands: ~100% near-misses with ~0 starvation deaths (the first draft) describes
a floor that always triggers and never bites. Scarcity should be *felt* in most runs,
*paid* in some, and escapable by good play. The bands state where the game should be;
the steward baseline measures where it is. A baseline outside a band is a finding (the
distance is the tuning work); only a band *no policy can reach* gets revised.

## Order of work

| # | Item | Size | Feeds | Status |
|---|------|------|-------|--------|
| 0 | G1 skeleton: baseline metrics + steward policy | small | everything (inputs) | done |
| 1 | A0 forecast + A1 leader's field log | small | anticipation | done |
| 2 | B1 autumn decision | medium | anticipation | done |
| 3 | C1 rival chief as a character | medium | attachment | done |
| 4 | C2 nemesis clan | small–medium | attachment, anticipation | done (no peaceful escalation) |
| 5 | D1/D2 opening minutes | small | decision | done |
| 6 | B2 varied winters | small–medium | anticipation | mostly done with B1 |
| 7 | A2/A3 leader-judged events, crew friction | medium | anticipation, attachment | done (trait pairs not built) |
| 8 | H ranks with trials (after A0: trials lean on the forecast) | medium | attachment, accomplishment | done |
| 9 | I structures to config, then Era-1/2 buildings and upgrades | medium | builder | done (I2, I3, I5 not built) |
| 10 | F player-set challenges | small–medium | attachment, replay | done (offline proposals only) |
| 11 | E1 last stand, E2 heritage | medium | all | done (no "flee") |
| 12 | I Era-3 buildings (walls/towers, trading post, temple → grand altar line) | medium | builder, C2, H | done |
| 13 | G1 full harness (hoarder/feaster, calibration) + G2 CI + G3 tuning | medium | everything (tuning) | done; G3 measured, numbers not chosen |
| 14 | B3 frozen river — only if G1 shows winters lacking | large | anticipation, exploration | not built (conditional) |

Row 0 lands before anything that adds a pause: the pause ceiling, the near-miss bands
and the forecast-calibration floor are all *inputs* measured against the steward
baseline, not afterthoughts — the skeleton is just the metric counters plus the
steward policy and its dilemma auto-picker, and item 13 grows it into the full canary
(more policies, calibration, CI, director tuning). 1–5 convert the proudest systems
(contracts, seasons, rivals) from mechanisms into stories; C2 rides on C1's ledger;
B3 waits for evidence. Era-3 buildings come after C2 and H, which give the walls
something to stop and the grand altar a master to build it.

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

No design forks remain — what's left are numbers the G1 baseline must set, and two
playtest judgments:

- the `min_gap` value (game-hours between posed dilemmas; the day-1 budget aside);
- the final band values (near-miss %, famine-consequence %, the day-20 death band);
- the Era-3 quiet threshold that promotes a successor nemesis — if the late game
  doesn't drag, none is ever promoted;
- whether the winter signs say enough without saying too much: G1 scores their hit
  rate, but only a playtest says if the *words* land;
- whether four site factors read on the ghost without a tutorial — the fire gap is the
  candidate to cut if not (its rule is invisible until the first burn).
