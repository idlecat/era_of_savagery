# Roadmap: where the game stands and what comes next

Written 2026-11-24, after three days (11-23 and 11-24, ~70 commits, ~8,900 lines) spent
on three questions: is the game fun, does it look good, and do the people act like
people. This doc reviews that work as a whole and sets the order for what comes next.
The detail lives in the design docs it points to:

- [make_it_fun.md](make_it_fun.md): the fun plan (A–I, G). Its status table is the
  record of what landed.
- [city_proposal.md](city_proposal.md): from a tribe of 50 to cities of 1,000. The next
  big plan.
- [CONFIG.md](CONFIG.md), [CULTURES.md](CULTURES.md): data formats. [PRD.md](PRD.md):
  the original product idea.

## 1. What the three days did

### 1.1 Fun: mechanisms became stories (make_it_fun.md)

Every row of make_it_fun's order of work landed, except the frozen river (B3, which
waits for evidence). Grouped by the kind of fun each one feeds:

- **Anticipation.** Contracts read their odds before sealing (A0, calibrated against
  real aborts: the top reason was the actual abort in 68% of interrupted contracts), keep
  a field log in the leader's voice (A1) and settle small happenings in character
  without pausing (A2/A3). Outposts are interrupted half the time instead of 94%. Winter
  is a planned bet: the director picks the winter's kind at autumn, the autumn council
  quotes signs of it, and a white or wolf winter now always shows its teeth (B1/B2).
- **Attachment.** Rival chiefs keep a dated ledger, quote it and are succeeded by
  chiefs of another temper (C1); one clan is the nemesis, with stages by era and an
  ending (C2). Ranks are earned by deeds, open real things and are marked by a naming
  rite and feathers (H). Endings are chosen (the last stand, joining a friendly clan)
  and the next game remembers the last (E1/E2). The council proposes challenges (F).
- **Decision fun from minute one.** A find the elders half remember and a first-day
  fever that teaches the pause-and-decide rhythm (D1/D2).
- **Builder fun.** Six new buildings over three eras (lookout tower, smokehouse,
  longhouse, temple, stone wall, trading post), the grand altar gated on a Master
  Builder, building `effects` and `era` as data (I).
- **Measured, not guessed.** `tools/metrics.gd` plays seeded games under game-master
  policies (steward, hoarder, feaster) and reports against bands (G1); a balance canary
  runs on every push (G2); the director's cap and decay were measured (G3). This
  harness is the most valuable thing the three days built: every finding below came
  from it.

### 1.2 Looks: a polish pass over the whole picture

Pure presentation, no rule touched (`world_view.gd`, `hud.gd`, the bake shader):

- **Light and colour.** A final grade in the bake shader (saturation, S-curve,
  warm/cool split), a full-screen grade eased by season, weather and night, contact
  shadows under every baked sprite, per-tree hue jitter, a cooler fill light.
- **Weather you can see.** Wind that bends tree crowns and rain, puddles that come and
  dry, a stuttering storm flash, bank foam and low-sun glints on the water.
- **The village grows prouder.** Banner poles from era 2, pennants and carved posts in
  era 3, baked models for all six new buildings, weapons that each fight their own way
  (overhead blows, a whirled sling, a drawn bow).
- **Feel.** Eased pan and zoom, a gliding camera focus, an uneasy sway in a crisis, a
  rotating selection ring and hover hints, pulsing sites that need a decision, softer
  panels and animated modals, icon speech bubbles at map zoom, feat dialogs shot like a
  film still.

### 1.3 People: from units to families with trades

Built on the everyday life of 11-18 (meals at the fire, idle acts, bonds, speech,
reactions), the three days made people act on what they are and what they know:

- **Careers emerge** (`careers.gd`): a calling grows from what the hands do, and the
  most drawn takes up a trade once the tribe has the know-how and people to spare.
- **Hunting as a band** (`hunt.gd`): against a saber-tooth they muster, charge
  together, ring it, and the hurt fall back; archers shoot from afar; nobody faces one
  alone.
- **Weapons by knack and mastery** (`arms.gd`), visible in how each one fights.
- **Small sensible things**: a wounded crew member rests at the nearest fire, not back
  home; a gatherer goes back to the carcass they were butchering, not to the bush by
  home; search crews are the keenest eyes for what is sought, and a search remembers
  where it combed.
- **Ranks as occasions**: the tribe dances by the fire for a rank, and the epithet stays.

### 1.4 How the work was done, and what to keep

- **Brainstorm in turns, then build, then measure.** make_it_fun and city_proposal were
  argued with a second model before any code; most of their corrections came from
  checking claims against the code ("the middle is not silent", "the cap is computed in
  one place"). Building then took one item per commit, each with its config, zh texts,
  a test and a doc note. Keep this loop.
- **Measurement changed decisions.** The director was erasing the winters the autumn
  council bets on; the Ford's ambush fired on every outpost; a stay-at-home tribe could
  never open the craft gate. None of these were visible from reading the code.
- **The gap: nobody has played it.** Every number above is headless. The playtest
  questions in make_it_fun (do the winter signs read, does the pace feel right at 2x,
  is three pauses a game day too many) are still open, and the visual pass was judged
  from screenshots, not a session.

## 2. Where it stands: the open problems

In order of how much they hold the game back:

1. **The food economy is the bottleneck of both the fun and the growth.** Near-misses
   sit at 75–100% for every policy (band 60–90%) and nobody starves on normal; wood
   piles to 6,000 while people go hungry; the tribe plateaus at 45–60. make_it_fun G3
   found the director can't fix this. The cause (city_proposal Wall 1): food buildings
   are passive trickles, so labour can't become food.
2. **Growth is a timer** (two births a day at most) and **challenges don't grow with
   the tribe** (rival clans capped at 14 people). Both are city_proposal walls 2 and 3.
3. **The late game is unmeasured.** Metric runs stop at 12–20 days; the nemesis raids
   0–1 times in 20 days under the steward; nothing tells whether days 30–150 drag.
4. **Playtest debt** (§1.4).
5. **Built but partial** (make_it_fun's "Left" list): site factors (I2), timing (I3),
   the village's name (I5), dilemma spacing, the director's `bored()`, trait-pair
   friction, the temple's part in rites.
6. **Natural behaviour has no measure.** The gatherer bug (walking home past a
   half-butchered kill) was found by watching, not by a test. At 50 people a player
   spots oddities; at 500 nobody will.

## 3. What comes next

The city proposal is the next plan, and it is also the fix for problems 1 and 2: its
step 1 (worked fields) is exactly the food lever make_it_fun's measurements asked for.
So the order below is the city proposal's, with the open fun items folded into the
step where they belong and two small items in front.

### 3.0 Before the city (small, now)

- **Push** the local commits and **settle the canary**: done, see §4 (it was noise).
- **Pick the G3 numbers** (the designer's call: decay is the lever on normal) and
  commit a baseline after it, so city step 1 is measured from a settled start.
- **A first playtest**: one session at 2x on The Ford through era 2 (~day 20), noting
  pauses that annoyed, things people did that looked wrong, and what was unreadable.
  It costs an hour and answers make_it_fun's open playtest questions before the city
  work changes the pace under them.
- **A naturalness report** in `tools/metrics.gd` (problem 6; built, first numbers in
  §4): per run, the share of
  walking that carried nothing, job changes per person-hour, people left standing in
  the open at night, people stuck (no progress for N s), nodes abandoned with food
  left. Bands like G1's. Cheap, and it guards every later step: worked fields, more
  careers and a thousand people are where behaviour goes wrong unseen.

### 3.1 The city, step by step (city_proposal.md §4)

| # | Step | Folds in from make_it_fun | Measure |
|---|------|---------------------------|---------|
| 1 | Worked fields, `farmer` career, `fewer` per pop, `store` key, cached `food_cap()`, era-2/3 buildings in the Steward's plan, the longhouse alias fix, plan per settlement | I3's food reserve beside `wood_reserve` | food days > 10 through a winter; wood < 1,500 at day 60; near-misses back in the 60–90% band |
| 2 | Births per family lines, crowding taper, `max_sites` by tier, career `max` per pop, migration | | pop 150+ at day 60, ~500 at day 120 |
| 3 | Tiers and names, settlement HUD, overpop gating, the director's `while` list | I5 (it *is* this step); dilemma spacing (`min_gap`), since a town poses more | no ghost outposts |
| 4 | Spatial hash, LOD, perf test | | < 25 ms/tick at 1,000 working people |
| 5 | Challenges that grow: rivals per our pop, coalitions, urban fire, raids on what's outside | I2's raid targeting and fire spread (the town tier's fires and field raids *are* them); the director's `bored()` for the long game; C2's peaceful escalation | real threat on 40–70% of days at 120 days |
| 6 | City victory, personas, chronicle | the temple's part in rites and festivals | a campaign to 1,000 in 2–3 hours at 2x–4x |

Two things carry through every step:

- **Looks keep pace.** Each step that adds a building adds its baked model (warehouse,
  well, irrigated field; `ART_VERSION` bump) and step 3 needs settlement names on the
  map. Two known visual gaps belong here: stone wall blocks that follow the ring, and
  a town that *looks* denser than a camp (more dressing by tier, as the era dressing
  does by age). Rendering 1,000 people is step 4's to prove.
- **People keep acting like people at scale.** Careers are the city's division of
  labour (farmers, fishers, builders by the dozen); the naturalness report (§3.0) is
  run after every step; the LLM contexts stay capped as the city grows
  (city_proposal open question 1: `careers.in_words()` gets the `treasures` treatment).

### 3.2 Not next

- **B3, the frozen river**: still waits for evidence that winters lack.
- **The LLM game master over MCP**: the design rule (every change a named operation,
  every state a summary) is kept by each step, but the MCP server itself waits until the
  city plan has settled the operations it would expose.
- **More culture packs, more eras**: the city is the depth the game lacks; breadth can
  wait.

## 4. Housekeeping found in this review

- `city_proposal.md` dated its audit "March 2026"; it was written on 2026-11-24.
  Fixed.
- **Linux CI reproduces the macOS runs exactly**: the canary on CI (run 45476386129,
  efb140c) and a local macOS run at 87b34a5 printed the same per-seed numbers. The
  baseline is portable.
- **The canary fired: 8 metrics moved** since the baseline (552f03d), and with c92075a
  (a gatherer goes back to the node they were working) reverted nothing moved, which
  looked like that commit moving the food balance. **8 seeds say otherwise**: without
  it, with it, and with the refined rule (only a half-butchered kill is gone back to,
  `rules.json` `gathering`) the steward lands at near-miss 63/63/63%, min food
  12/10/13%; the feaster 63/50/88%, 11/13/7%. All within noise. A 2-run, 8-day canary
  flips on any change to the sim's random draws, so its warnings are a prompt to run
  more seeds, not a verdict; its tolerances are set for that.
- **First naturalness numbers** (4 seeds x 8 days, The Ford): 59–62% of working time
  is spent walking (21–22% with empty hands), switching straight from one work to
  another and standing stuck are rare (0.02–0.03 per work-hour, 0.05 per person-day),
  nobody idles awake at night, and 0.25–1 kills a run are left with meat on them. The
  walking share is the finding: hauling round trips eat most of a gatherer's day, which
  is the walk that granaries by the fields, worked fields and roads should cut.

## 5. Progress log

- **2026-11-24, city step 1 begun.** Found while measuring it: **the Steward's work
  never ended.** A gather job (and a rite) runs until it is replaced, and the Steward
  only gives work to the idle, so after the first morning nobody was ever idle again:
  a building site laid out on day 5 stood paid and untouched for 55 days, beds fell as
  huts aged, and The Ford's tribe sat at 12–13 people for 60 days with 9,500 wood
  unused (seed 1, normal). The "wood piles up while people starve" of city_proposal
  §1.1 is this more than the food trickle, and its "32 huts by day 60" were the settle
  contracts' outposts, not the village. **Fix: shifts.** Work the Steward or a trade
  hands out is a stint (`rules.json` vice.steward `shift`, 40–75 s); then the person
  hauls their load home and comes back idle, to be given what is needed then. The
  chieftain's own orders have no shift. Same seed, 13 days: 20 people and 23 beds
  instead of 12 and 12.
- Built with it: worked fields and docks (`structures.json` `worked`, the `field` job,
  `sim.free_field()`/`assign_field()`, the Steward fills fields first when food runs
  short, the `farmer` career with the `work_at` verb), counts that grow with the tribe
  (`{base, per_pop}` for `fewer`, career `max`, `max_sites`), food stores as a `store`
  key on buildings, the Steward's plan growing with the tribe (fields, huts, granaries
  per pop; longhouses and the temple as era-2 upgrades), and contracts may build a
  longhouse from the second age (`instead`: a large hut before it).
- Not yet in step 1: the plan per settlement (it needs settlement-scoped conditions,
  which step 3's tiers define, so it moves there), cached `food_cap()`/`pop_cap()`
  (step 4), the Steward placing docks on the shore.
