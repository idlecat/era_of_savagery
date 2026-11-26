# Simpler rules: an audit (2026-11-25)

The aim: a few clear rules a player can learn, from which the complex behaviour
emerges. Not ordered lists of special cases, each patching the last measurement.

This audit looked hardest at the layers that changed most in the last days and
collected patches: the Steward's work, the building plan, the cold, the director and
growth. Combat, contracts, culture packs and the HUD were not reviewed for this.

## The pattern to aim for

One rule per concern, stated as **a target and a gap**: each thing the tribe needs has
a target that grows with the tribe (a count: `{base, per_pop}`), and effort goes where
the gap between what there is and the target is largest. Seasons, policies and eras
change targets, never the rule. Special cases become data, or disappear.

## Findings, by how much they would simplify

### 1. The Steward's choice of work: 13 knobs in a fixed order → one need rule

Today (`sim._update_vice`) an idle person's work comes from a chain of special cases,
in order: a build site (`build_chance`, a coin flip), crafts (`art_chance`,
`food_per_head_art`, `art_wood`), `wants` (stone, herbs, copper, tin, each with
`below`/`share`), "stores full → wood" (`full`), "short of food → food"
(`food_per_head`), the harvest rush (`autumn_fill`), `low_wood`, the Council's policy
branches, a 50/50 coin flip, then the `wood_enough` override, `fields_first`, and the
trades' own checks (`careers.steward_food_per_head`, the woodcutter's woodpile check).
Four of these were added this week, each answering one measurement.

**One rule instead:** every resource has a target (`rules.json` needs: food =
a winter's eating ahead, rising in autumn; wood = building plus a winter's fuel; stone,
herbs, lore...). Its need is how far the stock is below the target (0..1). An idle
hand takes the work with the greatest need, building sites counting as a need of their
own; with no need left, crafts and rites (leisure). The Council's policies scale
targets (a "food first" policy doubles the food target), and a trade's holder works
their trade while that trade's resource has a need.

What it replaces: all 13 knobs and their order, the coin flips, the woodpile
overrides, the trades' checks. What emerges: shortages pull hands, plenty releases
them to crafts and lore, the autumn rush comes from the food target rising before
winter, a big town keeps more wood because its fuel target is bigger.

### 2. The building plan: 16 hand-ordered entries → targets per role

Today (`rules.json improvements.list`): sixteen entries, each a building with its own
conditions. The storage rows alone overlap three ways (a granary when nearly full,
a warehouse below a winter's need, a granary below a winter's need), homes three ways
(hut, hut → large hut, large hut → longhouse), fires twice (village, outposts).

**One rule instead:** buildings already say what they serve (`structures.json
serves`, the other session's roles: warmth, gather, haven, sleep). Add the missing
roles (store, food, worship) and give each role a target per head (beds: people + a
margin; store: a winter's eating; warmth: a fire per ~25 people; food: fields for the
food target). The plan builds for the role with the biggest gap, choosing the best
type the tribe can make for it (an upgrade where one stands, else a new building).

What it replaces: the sixteen entries, `beds_free_below`, `store_below`, the duplicate
granary rows. **Caution:** this overlaps the other session's layout work (zones,
retiring outdated buildings); agree on it before starting.

### 3. The cold: four blizzard patches that `weigh` already covers → delete them

`weigh.gd` (the other session's) is exactly the simple rule wanted here: before an
errand a person counts the walk back to warmth against the health a cold that can
kill would cost them, and turns back at the point of no return. On top of it sit four
special cases I added before it existed: no work handed out in a blizzard
(`keep_in`), the blizzard reaction repeating every 5 s (`react_every`, the "exposed"
group), sheltering until the blizzard passes (`while_weather`), and the freezing
person preferring a closer bed. `weigh` already refuses errands into deadly cold
(`find_node`, the Steward), re-weighs a gatherer's node, and turns people back
(`must_head_back`).

**Proposal:** remove the four, keep `weigh`, and replay the two traced blizzard
deaths (seed 2 day 55, seed 1 day 23) to confirm nobody freezes. Low risk, the
smallest change here.

### 4. Smaller: rules that fold into 1

- The famine exception to `rest_below` (the weak from hunger go for food): under the
  need rule, food at a critical gap simply outweighs rest.
- The trades' woodpile check and `steward_food_per_head`: the trade works while its
  resource is needed.
- `wants` (stone, herbs, copper, tin): targets like any other resource.

### 5. Worth a look later

- The director: a tension cap, its growth per head, `hold_while`, winter `signature`
  hardships passing the cap, mercy, `bored`. Each is reasonable, but `hold_while` could
  become "a sickness wave and a famine add tension", which the cap then respects
  without a separate list.

## What is fine as it is

Births (a pace per family lines, tapering as beds fill: two numbers and one shared
crowding threshold), the tiers (data rows checked by one function), worked fields,
the carcass rot, the dilemma spacing (one gap, one urgent flag), level of detail.

## Suggested order

3 first (deletions, quick, measurable), then 1 (the biggest simplification, and the
one most of this week's patches live in), then 2 together with the other session.
Each step: the same 12-day metric bands and a 150-day check, so the simpler rule is
shown to keep (or improve) the behaviour the patches were bought for.
