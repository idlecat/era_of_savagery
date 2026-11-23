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
- A pure query over state the sim already has: known predators/raiders near the route
  (`D.route()` waypoints), season and weather (`hz.summary()`), crew hp/skill, distance,
  the `director`'s current tension cap. Returns `{risk: 0..1, reasons: [...]}`; a
  `contracts.forecast(plan)` that a game master can call too.
- Phrasing and thresholds in config (`contract_log.json` `forecast` bands, zh); the
  leader's temperament colours it (a boastful leader understates the risk, a cautious
  one overstates it — a tell the player learns).
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
- Today the contract writes ~13 log lines in its whole life, almost all at seal,
  interrupt and end (`contract_system.gd`); the middle is silent. Budget the lines:
  at most one per trigger per contract, and a cooldown, or the chronicle drowns.
- The log should call back to the forecast (A0): "No sign of the wolves yet." / "The
  wolves found us, as I feared."

### A2. Small interruptions resolve through character
Not every hiccup deserves pausing the player:
- Low-stakes contract events (stung hand, crew argument, spoiled rations, a strange
  track) are decided by the **leader's temperament** (archetype table; optionally
  `llm` if configured), reported in the chronicle.
- Implementation: a config list of events `{when, weight}` sampled by
  `contract_system.update()` like `_check_aborts`; resolution via `story.run()` actions
  so a game master can also fire them. Extend the Steward's routine-matter idea
  (`sim._decide_routine`) to contract leaders.

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

### B3. The frozen river (split out of B1: it is the big one)
While `hz.winter()`, rivers freeze and can be crossed anywhere: new ground, new prey,
thin ice as a real risk. Valuable, but it changes `D.route()`, region logic
(`same_side`, `home_side`) and every caller that assumes water blocks; treat it as its
own item with its own tests, not as a rider on B1. Size: large.

### B2. Winters differ
- Per-year winter *kinds* (blizzard winter, wolf winter, quiet eerie winter) drawn from
  `config/events.json` with the director pacing them; year 3 must not equal year 1.
- The eclipse/festival events show the pattern to copy.

## C. Rivals as recurring characters (attachment)

### C1. The rival chief is a person
- Chiefs already have a name and epithet (`rivals.json`, `rivals.parley_ctx`). What's
  missing is memory: a list of every parley, raid, gift and slight (surface the
  existing `grudges`), quoted back in parley ("You came with spears last spring"); the chief appears with a voice in parley dilemmas
  (`rivals` events already run through `story.dilemma_view()`).
- Chiefs age and die: a successor with a different temperament resets the diplomatic
  game mid-run (a `rivals.json` event, offline via `rivals.chief_reply()`).

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
  death: a "last stand" dilemma when the tribe drops below a few people (flee, merge
  with a friendly clan, hold), so the ending is a choice.
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

The sim is deterministic, headless and config-driven with a full test harness — use it:

- **G1. Metric runs**: a test-style script that plays N seeded games per config variant
  and reports: deaths by day 20, food-floor near-misses (food < 15% of cap at least
  twice per run — target ~100% of runs), starvation deaths in year 1 (target ~0),
  contracts interrupted per run, dilemma frequency, days between meaningful events
  (hard ceiling via the director's tension cap), time-to-era-2.
- **G2.** Wire the metric run into CI as a balance canary: config edits that shift the
  distributions show up as diffs.
- **G3.** Tune the director's per-level caps against these curves, not by feel.

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
stories; do those first.

## Definition of done per item

- Texts are config entries with Chinese (`test_translations` passes).
- Works fully offline (`persona_engine` / pure data); the LLM only enriches.
- Every way the feature changes the game is a named operation a game master can call,
  and its state is readable from a `summary()`/`world_ctx()`-style view.
- `check_invariants()` grows a rule where a new coupling could drift.
- A test covers the trigger/resolution path (and the metric harness covers balance).

## Open questions

- **Pacing between pauses.** The game is pause-and-decide; what does the player *do*
  in the minutes between decisions? A1/A0 give them something to read and watch, but
  is that enough, or do we need a light, optional verb while time runs (e.g. pointing
  the Steward at a priority)? Not unit micro — that's a not-goal.
- **How many dilemmas is too many?** B1, D2, F, C1 and E1 all add pauses. G1 should
  measure pauses per game-hour and we should pick a ceiling before building them.
- **Should the forecast lie?** A temperament-coloured forecast (A0) is a fun tell, but
  a forecast that's wrong too often teaches players to ignore it.
