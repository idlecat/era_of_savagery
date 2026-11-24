# Weigh before acting: cost, risk and outcome

Written 2026-11-24, after a report: in winter people walk far from the fires, freeze and
die on the way back.

## 1. What happens now

Nothing weighs a trip before it starts. Each piece decides on distance alone:

- **Gathering** (`sim.find_node`): the nearest node from home within `area_r` (Steward
  900, a player's order 2000), scored by distance and claims. Season, cold, the way back
  to a fire and the beasts near the node don't count.
- **The Steward** (`_update_vice`) picks a resource by the stores, then sends people
  for it however cold it is. A career holder (`careers.go_work`) does the same.
- **Scouts** (`explore_target`) walk to the nearest unexplored cell, however far from a
  fire.
- **The way back** is a fixed rule: the `freezing` reaction sends someone to the nearest
  bonfire once their health drops below 55% (`reactions.json`). How far that fire is
  doesn't count. In winter (0.21 hp/s by day, 0.6 at night, +0.9 in a blizzard, against
  70 hp) someone 2,000 units out still has ~38 hp to lose when they turn, and needs 35 s
  to get back: in a blizzard they lose 38 hp on the way and die. The nearest fire is
  picked as the crow flies, ignoring rivers.
- **After warming up** `end_errand` gives back the old job, and the person walks straight
  back out to the same far node.
- **Contracts** quote their odds before sealing (`contracts.forecast`), but the cold of
  the journey isn't one of the reasons.

## 2. The rule

Every errand that takes someone away is weighed on three things before they commit, and
again while it lasts:

- **Cost**: the time out there: the walk there, the work, and the walk back to the
  nearest warmth (`D.route_len`, at the person's speed).
- **Risk**: the health it takes. Cold per second (projected: an announced blizzard counts,
  and so does the night if the trip runs into it) times the time out there; hunger once
  the stores are empty; known beasts and dens near the place.
- **Outcome**: what it is for. Need raises the risk people will take: with the food
  stores nearly empty, people go further for food.

An errand fits when the health it costs, counted `safety` times over, leaves at least
`floor` of the person's health, scaled by temperament (cautious people keep more in
hand, belligerent people less) and by need. While out in the cold, people head back as
soon as what they have left only just covers the way to the nearest warmth (the point of
no return), not at a fixed 55%.

## 3. The pieces

A new sub-system `sim.weigh` (`scripts/weigh.gd`, `config/weigh.json`). All the numbers
are data.

| Function | What it does |
|---|---|
| `plan(u, need)` | A context for many checks in a row (the cold rate, the budget, the fires, the beasts), so `find_node` and `explore_target` loop over thousands of places cheaply |
| `fits(ctx, p, work)` / `penalty(ctx, p)` | Whether a place fits, and its extra score (beasts, dens) |
| `trip(u, to, work, res)` | The full appraisal as a plain dictionary: secs, cold hp, budget, hp left, beasts, ok, why (for a game master and tests) |
| `must_head_back(u)` | The point of no return |
| `nearest_warmth(p)` | The nearest fire by route (fords), not as the crow flies |
| `summary()` | The cold rate now, who is out in the cold and their margin, today's refusals |

Hooks:

1. `find_node(..., who)`: skips places that don't fit and adds the penalty. `_do_gather`
   passes the gatherer, so every gather job (the Steward's, a career, a player's, a
   crew's) is weighed. If nothing fits but something would without the weighing, an
   ordinary person drops the job ("Too cold to go so far", a speech mark) and the Steward
   plans again; a crew member waits.
2. `_do_gather` weighs the node it works again every `recheck` seconds, so a person who
   warmed up doesn't walk back out to a node that no longer fits.
3. The Steward checks the choice with the same weighing and falls back (other resource,
   a building site, the ritual ground near home) instead of sending people out to die.
4. `careers.go_work` passes the person.
5. `explore_target` skips cells that don't fit; a scout with nothing in reach comes home
   ("Too cold to scout further").
6. The `freezing` reaction starts on `below` **or** `weigh.must_head_back(u)`, and goes
   to `weigh.nearest_warmth()`.
7. `contracts.forecast` gets a `cold` reason when the journey in deadly cold costs more
   than the leader's budget, so the chieftain and the persona see it before sealing.

## 4. Verification

- Tests (`test_weigh`): a winter scene with a node far out and one near: the far one is
  refused, the near one taken; with empty stores the far food is taken; a person far out
  heads back in time and reaches the fire alive in a blizzard; nothing weighs in summer;
  `trip()` gives the same numbers as the run.
- `test_boundaries`/`test_smoke` stay green; `sim.check_invariants()` unchanged.
- The balance canary (`tools/metrics.gd --baseline`) for deaths by cold and food.

## 5. Results

`tools/metrics.gd -- --runs=2 --days=8 --policies=steward,feaster` (the same seeded games, with
`weigh.json` `on` false and then true):

| | weighing off | weighing on |
|---|---|---|
| deaths per run (steward / feaster) | 5.5 / 4.5 | 1.5 / 0.0 |
| first-winter deaths, the two white winters | 11 and 9 | 2 and 0 |
| empty-store hours (feaster) | 3.75 | 4.95 |

People stay nearer the fires in winter, and food barely suffers. The baseline was rewritten.

Not done (next): a freezing person could shelter in a nearer hut rather than only at a fire; a
crew far out could light a camp fire; contracts could pause their gathering in a blizzard rather
than just stop for want of a safe place to gather.
