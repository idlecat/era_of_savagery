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

### B1. The autumn decision
One big dilemma when autumn begins (a `story.holds()` trigger on season + day, config in
`dilemmas.json`), posing bets on how bad winter is:
- Slaughter the herd for meat vs. keep the oxen (touches `sim.oxen`, `_herd()`).
- Feast now (mood) vs. bank food.
- A winter hunt across the **frozen river**: while `hz.winter()`, fords become
  crossable anywhere (`D.route()` gains an ice mode) — new ground, new prey, thin ice
  as a real risk (a `hz` hazard keyed to crossing events).
- The `director` controls how bad the winter gets, so the bet is real, not theater.

### B2. Winters differ
- Per-year winter *kinds* (blizzard winter, wolf winter, quiet eerie winter) drawn from
  `config/events.json` with the director pacing them; year 3 must not equal year 1.
- The eclipse/festival events show the pattern to copy.

## C. Rivals as recurring characters (attachment)

### C1. The rival chief is a person
- Give each clan's chief a name, archetype and a memory of every parley, raid and slight
  (surface the existing `grudges`); the chief appears with a voice in parley dilemmas
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

- **E1.** On defeat, `llm.saga()` (offline: persona) tells the tribe's legend from the
  feat list and chronicle.
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
| 1 | A1 leader's field log | small | anticipation |
| 2 | B1 autumn decision (+ ford-ice mode) | medium | anticipation |
| 3 | C1 rival chief as a character | medium | attachment |
| 4 | D1/D2 opening minutes | small | decision |
| 5 | B2 varied winters | small–medium | anticipation |
| 6 | A2/A3 leader-judged events, crew friction | medium | anticipation, attachment |
| 7 | G1–G3 metric harness | medium | everything (tuning) |
| 8 | F player-set challenges | small–medium | attachment, replay |
| 9 | E1/E2 defeat legend + heritage | medium | all |

1–4 convert the proudest systems (contracts, seasons, rivals) from mechanisms into
stories; do those first.

## Definition of done per item

- Texts are config entries with Chinese (`test_translations` passes).
- Works fully offline (`persona_engine` / pure data); the LLM only enriches.
- Every way the feature changes the game is a named operation a game master can call,
  and its state is readable from a `summary()`/`world_ctx()`-style view.
- `check_invariants()` grows a rule where a new coupling could drift.
- A test covers the trigger/resolution path (and the metric harness covers balance).
