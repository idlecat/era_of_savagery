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

Not-goals (identity protection): no more resources, no unit micro, no combat detail,
nothing fun gated on a configured LLM.

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
  leader's temperament colours the *words*, never the number (see Open questions —
  resolved there: an honest, auditable number; a characterful spin on top).
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
- Answering pi's question: not `reactions.json`. Reactions are people's *bodily*
  responses to a happening (cover, flee, aid, firefight), sharing one verb set; A2's
  events are *decisions with costs*, which is what the dilemma format is. They
  compose: an A2 outcome may call `react.trigger()` (a snake bite → crew `aid`), so the
  crew visibly responds without A2 owning any movement code.

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
- The `director` controls how bad the winter gets, so the bet is real, not theater.

### B2. Winters differ
- Per-year winter *kinds* (blizzard winter, wolf winter, quiet eerie winter) drawn from
  `config/events.json` with the director pacing them; year 3 must not equal year 1.
- The eclipse/festival events show the pattern to copy.

### B3. The frozen river (split out of B1: it is the big one)
While `hz.winter()`, rivers freeze and can be crossed anywhere: new ground, new prey,
thin ice as a real risk. Valuable, but it changes `D.route()`, region logic
(`same_side`, `home_side`) and every caller that assumes water blocks; treat it as its
own item with its own tests, not as a rider on B1. Size: large.

> **pi:** agreed on the split, with one addition: winter already gates movement today
> (`beds.day_only`, `camp_asleep`, snow speed), so B3's payoff should be measured
> against those costs — crossing ice must open *enough* new ground to be worth its
> size, or it stays a v2 nicety. Do B1/B2 first; B3 only if G1 shows winters lacking.

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
- Let one clan escalate across eras (raids grow, then demands, then war) while the
  others stay background — drama needs a face. Config: a "nemesis" flag in
  `config/rivals.json` with escalation stages gated by `evo.era` and relation.

## D. The first ten minutes (decision fun)

- **D1.** Start with one find half-discovered (the elder remembers mushrooms) and a
  seek-quest contract available from minute one — the signature mechanic shouldn't wait
  for act two. (`D.FINDS` placement + `contracts` kind "seek" already exist.)
- **D2.** A day-1 micro-dilemma (a sick child, a strange trail) via a `story` trigger
  `{day: 1}` so the pause-and-decide rhythm starts immediately.

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
- **G2.** Wire the metric run into CI as a balance canary: config edits that shift the
  distributions show up as diffs.
- **G3.** Tune the director's per-level caps against these curves, not by feel.

> **pi:** Claude asked whether "near-misses in ~100% of runs" is the right bar — no,
> and the original G1 was internally strained: 100% near-misses *plus* ~0 starvation
> deaths describes a floor that always triggers and never bites. Replaced with the
> two-tail bands above; the honest goal is that scarcity is *felt* in most runs, *paid*
> in some, and escapable by good play.

## Order of work

| # | Item | Size | Feeds |
|---|------|------|-------|
| 1 | A0 forecast + A1 leader's field log | small | anticipation |
| 2 | B1 autumn decision | medium | anticipation |
| 3 | C1 rival chief as a character | medium | attachment |
| 4 | D1/D2 opening minutes | small | decision |
| 5 | B2 varied winters | small–medium | anticipation |
| 6 | A2/A3 leader-judged events, crew friction | medium | anticipation, attachment |
| 7 | G1–G3 metric harness | medium | everything (tuning) |
| 8 | F player-set challenges | small–medium | attachment, replay |
| 9 | E1 last stand, E2 heritage | medium | all |
| 10 | B3 frozen river | large | anticipation, exploration |

1–4 convert the proudest systems (contracts, seasons, rivals) from mechanisms into
stories; do those first. But land the **G1 skeleton early** (a minimal version: pauses
per game-hour, interrupts per run, near-miss counts) *before* the pause-adding items
arrive — the pause ceiling and the near-miss bands are inputs to B1/D2/F/C1/E1, not
afterthoughts, and the full harness (item 7) then only grows the metric list.

## Definition of done per item

- Texts are config entries with Chinese (`test_translations` passes).
- Works fully offline (`persona_engine` / pure data); the LLM only enriches.
- Every way the feature changes the game is a named operation a game master can call,
  and its state is readable from a `summary()`/`world_ctx()`-style view.
- `check_invariants()` grows a rule where a new coupling could drift.
- A test covers the trigger/resolution path (and the metric harness covers balance).

## Open questions

- ~~**Pacing between pauses.**~~ **Resolved: no new verb now** (pi's position; A0/A1
  give the waiting something to read, G1 counts the gaps). The game is pause-and-decide; what does the player *do*
  in the minutes between decisions? A1/A0 give them something to read and watch, but
  is that enough, or do we need a light, optional verb while time runs (e.g. pointing
  the Steward at a priority)? Not unit micro — that's a not-goal.
  > **pi:** my instinct: ship A0/A1 and *then* judge — watching a crew you chose, led
  > by a character who narrates, is what AoE2 spectators already do. A Steward-priority
  > verb is the right v2 candidate because `improve.order()` and `policy.set_choice()`
  > already exist as verbs; don't build it speculatively.
- **How many dilemmas is too many?** B1, D2, F, C1 and E1 all add pauses.
  > **pi (proposed resolution):** from the code — dilemmas already FIFO-queue
  > (`story.pending`, `cult.pending`, `rivals.pending`, `folk.pending`, `nat.pending`,
  > `life.pending`, drained one at a time by `_check_events`), so they never stack; what's missing is
  > spacing. Proposal: a config `min_gap` (game-hours) between *posed* dilemmas in
  > `_check_events`, with an urgent class that bypasses it (defeat, last stand, a
  > crisis); the director's tension cap keeps pacing *hardships* as today. Pick the
  > number from the G1 baseline measurement, not by feel — hence G1's skeleton lands
  > first (see Order of work).
  > **Claude:** agreed, and urgency is data, not a list in code: a dilemma gets
  > `"urgent": true` in its config when *waiting would change its options* — the
  > flood (the water is rising now), the last stand, endings, an emergency's take-
  > command. By that test the flood is urgent; an envoy (they can wait at the fire), a
  > festival, the chosen one, an era change, a family thinking of leaving are not.
  > Two more rules so `min_gap` doesn't break things: a held dilemma keeps its place
  > in its queue (no dropping), and anything whose trigger is a moment (the eclipse)
  > is either urgent or its texts must read fine a few hours late.
- **Should the forecast lie?** ~~A temperament-coloured forecast is a fun tell, but a
  forecast that's wrong too often teaches players to ignore it.~~
  > **pi (resolved):** the *number* never lies — it's computed from the real abort
  > predicates, so it's auditable and G1 can score its calibration. Temperament
  > colours the *words* (a boastful leader's "a quiet road" over a 0.3), and the LLM
  > leader may spin `negotiation_ctx`'s numbers, but the negotiation dialog shows the
  > band beside the speech. The tell is in the prose; the bet is on solid ground.
