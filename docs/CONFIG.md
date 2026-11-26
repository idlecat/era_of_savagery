# Rule configs: events and reactions

The forces of nature, the hardships and how people respond to them are data, in `config/`:

| File | Read by | What it holds |
|---|---|---|
| `config/events.json` | `hazards.gd`, `nature.gd` | seasons, weather, wolves, tiger raids, sickness, famine, lightning, wildfire, house fires leaping between packed buildings (`house_fire`, `nat.set_alight(s)`), flood, Fire Mountain, earthquake, eclipse: when they happen, how strong they are, what the tribe is told; the kinds of winter (`winters`: their signs, their effects in winter, and the stats the tribe can prepare) |
| `config/reactions.json` | `reactions.gd` (`sim.react`) | for each happening, what people do about it |
| `config/hunt.json` | `hunt.gd` (`sim.hunt`) | how a band fights a dangerous beast: muster, charge together, ring it, fall back hurt |
| `config/weigh.json` | `weigh.gd` (`sim.weigh`) | the cost, risk and outcome of an errand, weighed before going and while it lasts (the cold of the way back to a fire, beasts, need) |
| `config/weapons.json` | `arms.gd` (`sim.arms`) | the weapons (club, spear, stone axe, sling, bow): what opens each, how it fights; weapon mastery (levels, XP, what a level gives, masters); each person's knack for each weapon |
| `config/rivals.json` | `rivals.gd` | the rival clans: how our deeds change their feelings, stances, raids and demands, theft, trespass, their people's strength, traders, war spoils, and how a chief weighs a deal at a parley; the ledger of what passed between us (`ledger`: kinds, weights, how a chief brings them up and dates them) and the chiefs as people (`chiefs`: tempers, reigns, successors' names); the nemesis (`nemesis`: how it is picked, how much more it raids, its stages by era, when the feud ends) |
| `config/rules.json` | `sim.gd`, `folk.gd` | everyday life: eating and hunger, skill levels and XP (`skills`: the curve, the cap, the mastery level, the Centurion Aura), food storage and rot, births, the aurochs pens, burials, beds, when the overpopulation and Chosen One dilemmas come up, and folk life (children, art and treasures, mood, trade values) |
| `config/legacy.json` | `legacy.gd` | the endgames: each victory path's conditions (`count`: vassals, allies or techs, all of them; people or `held_winter` (the most kept alive through a whole winter) at least `of`; `built`: a structure; `tier`: a settlement of that tier; `roads_linked`: every settlement joined to the village by road, that share of the way paved with `road` or better, `roads.share_paved()`), the event and saga texts, and the defeat |
| `config/audio.json` | `audio.gd`, `synth.gd` | the sounds (recipes rendered in code), what plays on which happening, the sounds of people at work, ambience, and the music's moods |
| `config/policies.json` | `policy.gd` | the Council's standing policies: their choices, effects, culture drift, unlocks, who likes them and what they say |
| `config/emergency.json` | `crisis.gd` | emergency mode: when it starts, how slow time runs, who is in it, when it ends, the orders and their numbers |
| `config/director.json` | `director.gd` | pacing: what each hardship weighs, how much the tribe can take per challenge level, when it is in distress, and the mercy gifts; which kind of winter comes (`winter`: no easy repeats, gentler in distress, harder for a well-stocked tribe); `hold_while`: hardships held back while a sickness wave or famine is on; `bored`: after days of calm something stirs (a hostile clan's raid, a wolf pack: story actions, `director.bored()`) |
| `config/names.json` | `names.gd` | names for the newborn once the culture's own are used up: the parts (adjectives, animals, plants and things of nature, old Chinese surnames) and how they combine |
| `config/lands.json` | `lands.gd`, `sim.gd`, `world_view.gd` | the kinds of land (steppe, parkland, woodland, old forest): how wooded, and the grass, bushes, herds, weather and wildfire that go with it; which random maps get |
| `config/roads.json` | `roads.gd` | trails that emerge from feet and fade when abandoned; the road levels the tribe can build (packed earth, stone): what they need, cost and take to build, and how much faster people walk on them |
| `config/discovery.json` | `sim.gd`, `inventions.gd`, `contract_system.gd` | the odds of noticing a find (by group, skill, temperament, activity, rarity) and of an invention's breakthrough; the search quests: where each group is looked for, days, radius, crew; the find an elder remembers at the start (`remembered`) |
| `config/notices.json` | `hud.gd` | what interrupts the player: which achievements open a dialog (the rest are banner notices), contract completions and traders as notices, the gap between dialogs |
| `config/save.json` | `main.gd` | autosave interval and how many to keep, the number of save slots, the quick-save slot |
| `config/contract_log.json` | `contract_system.gd` (`forecast`, `field_say`, `_field_log`), `hud.gd` (negotiation dialog), `llm_client.gd`, `tools/metrics.gd` (calibration) | what a Task Contract's leader says: the odds read before sealing (`forecast`: per abort condition the base chances by kind, the weight of seen beasts, warriors, dens, hostile clans and unknown land, season disasters, wounds, war losses; the spoken bands of odds, temperament voices and reason texts) and the field log during the work (`log`: lines per trigger and archetype, bubble and chatter timing, which triggers reach the chronicle); troubles the leader judges in the field (`judged`) and the small happenings the leader settles (`events`: conditions, crew pairs, options weighted by archetype, story actions) |
| `config/challenges.json` | `challenges.gd` (`sim.challenges`), `hud.gd` | the challenges the council proposes: when each may be offered, its goal and what fails it, its time, its reward and penalty, and the texts of the proposal |
| `config/ranks.json` | `ranks.gd` (`sim.ranks`), `sim.gd` (`gain_xp`, the Centurion Aura), `folk.gd` (master trader), `hud.gd` | ranks earned by deeds: the routine level cap, the level bands of each rank (Proven, Master), and per skill each rank's title and trial (the deeds from a person's deed record `u.deeds` that open it); rank-up texts; the gates a rank opens (`ranks.may/tribe_can`: calf taming, bigger pens, upgrades/renovations/bronze, a lore keeper against forgetting, war leaders, War Chief, longer treaties); the naming rite at the fire (`rite`: story actions) and the feather colours (`marks`) |
| `config/careers.json` | `careers.gd` (`sim.careers`), `sim.gd` (`work_mul`, `unit_atk`, `unit_speed`, `unit_idle`, the Steward, the War Chief, the herder), `hud.gd` (sheet) | careers that emerge as the tribe develops: each grown-up's calling grows from the work their hands do (tags `doing:`, `job:`, `kind:`), fades daily; a career opens on a `story.holds()` condition (tools, an invention, a building, population); someone takes it up when its calling is strong and clearly theirs, their skill is high enough and the tribe has a specialist place (grown-ups x `share` of the era). Holders work their trade faster, go to it by themselves when idle by day, the Steward leaves them to it; `preferred` careers go first for a duty (herd, War Chief); texts of opening, taking up and lapsing |
| `config/structures.json` | `data.gd` (`D.STRUCTURES`), `sim.gd`, `nature.gd`, `improve.gd`, `hud.gd` | the buildings: cost, work, footprint, what they house or trickle, the food they store (`store`), how people work them (`worked`: food per hand a second, how many hands, the drawn work: fields and docks; `sim.free_field()`, `sim.assign_field()`), the tech and age they need (and `instead`, what a contract builds before the age), which hazards can knock them down (`sim.hit_by(s, hazard)`), the DEF a wall gives inside it, era styles, decoration, culture drift when finished; the build menu, what a contract may build, and the names an LLM may use for them |
| `config/dilemmas.json` | `sim.gd`, `folk.gd`, `rivals.gd` | the chieftain's choices: the first day's fever, the Great Flood warning, overpopulation, the Chosen One, the dawn of each era, the autumn council (the bet on the coming winter), the festivals, and the rival clans' first contact, demands, calls to war and surrender |

`scripts/config.gd` loads them (`Config.load_cfg("events")`, cached). A file of the same name in `user://config/` is **merged over** the game's one: it only needs the keys it changes. For example, to make wolves tougher and stop anyone fighting fires:

```json
{"wolves": {"hp": 40, "pack": [3, 5]}}
```
saved as `user://config/events.json`, and
```json
{"on": {"wildfire": [{"do": "flee", "who": "near", "reach": 200, "dist": 300}]}}
```
saved as `user://config/reactions.json` (a list replaces the whole list).

Conventions: times are seconds (one day is 90 s) unless the key ends in `_days`; `[a, b]` is a random range; chances are 0-1 per roll; texts are English translation keys, so a new or changed text needs a Chinese line in `scripts/lang_zh.gd` (`test_translations` checks every text in both files, placeholders included).

## events.json

Each section's keys are documented by their names; the ones that shape the game:

- `seasons`: `days` per season, `news` (one alert per season: spring, summer, autumn, winter), and per-season tables `berries`, `yields` (food from each building type), `spoil`, `hunger`.
- `cold`: damage per second away from a fire at night and in winter (with and without furs).
- `weather.kinds.<id>`: when it comes (`chance` per roll by season, `dur`; `warn_ahead` + `warn` announce it first), what it says (`alert`/`level`, `done` when it ends) and what it does: `speed`, `work`, `sight` multipliers, `wet` (fires burn out faster and spread less), `dry` (fires and lightning catch more), `berries`, `crops` (+ `crops_spare`), `cold`/`cold_hide`, `deadly_cold`, `lightning`, `disaster` (interrupts Task Contracts). A new kind needs no code.
- `sickness.recover`: how long a sickness lasts and what speeds or slows recovery (warmth, shrines, healers, the Hot Spring, willow tea, hunger).
- `eclipse`: a dilemma in the shared format (below).

## Dilemmas

Choices put to the chieftain share one format, run by `story.gd` (`dilemma_view()` for the HUD, `dilemma_choose()` to resolve): `config/dilemmas.json`, culture pack events, the eclipse, and dilemmas posed from outside. (Only the rival trader's market, whose choices are the goods he brings, is coded.)

```json
{"title": "...", "text": ["... %s ... %d ...", "clan_name", "demand"], "speaker": "best:lore",
 "options": [{"label": "...", "desc": "...", "cost": {"food": 15}, "cost_note": false,
   "when": {"pop": 3}, "needs": {"best": "lore", "lv": 3, "or_tech": "totems"},
   "chance": {"base": 0.35, "skill": "lore", "per_lv": 0.1, "max": 0.9},
   "do": [actions], "result": "...", "else_do": [actions], "else_result": "...", "result_add": ["guests_line"]}]}
```

- **Texts** are English translation keys, or `[key, var names...]` filled in the key's placeholder order. Vars: `speaker` (with `"speaker": "best:<skill>"`; a lone `%s` in a plain text is the speaker), `pop`, `day`, `choice` (the option chosen), `fighters` (the three hardest hitters), `chance_pct`, and what the rules supply: `era`, `voices` (era2/era3: one line per kind of person, from `voices`), `festival`, `festival_text`, `feast_cost`, `gather_cost`, `clan_name`, `chief`, `epithet`, `clan_desc`, `demand`, `foe_name`, `martial`. Actions can add vars (`chosen_name`/`chosen_epithet`, `guests_line`).
- **cost**: `{resource: number | var name | {"per_pop": k}}`, added to the description unless `cost_note` is false, and disables the option when the tribe can't pay. **when**: conditions (as in scenario scripts) that enable the option.
- **needs** and **chance** decide between `do`/`result` and `else_do`/`else_result`. `needs` is a skilled person (`best`, `lv`, or a tech `or_tech`) or `{"var": name}`. `chance` scales with the best person at a `skill` (`per_lv`) or with the attack of `power: "fighters:<n>"` (`div`), clamped to `min`/`max`.
- `"options_from": "chosen"` builds the options from the culture's mythic bloodlines.
- **Actions** (`story.gd run()`, all listed in `story.ACTIONS`): `log`, `alert` (`at`, `level`), `give`, `spawn`, `reveal`, `mood`, `devotion`, `insight`, `culture`, `invent`, `boon`, `remember` (`%d` is the day; `impact`), `xp`, `hurt` (fraction of max HP), all with `who` = `all`, `best:<skill>` or `fighters:<n>`; `panic`, `weather`, `react`, `great_flood`, `open` (`contract`/`war`: the rules open that planning), `chosen`, `festival` (`length`, `glow_days`), `births`, `guests`; on the rival clan in var `clan` (or the one named by `"clan": "foe"`): `relation` (+`reason`), `relation_min`/`relation_max`, `raid`, `raid_delay_days`, `vassal`, `clear_treaties`, `grudge`, `peace_days`, `clan_pop`, `clan_era` (the clan enters that era: its village takes the style), `absorb` (a beaten clan is taken into the tribe: rivals.absorb); and `feat`, `tale`, `join`, `sound` (a sound from `audio.json`, `at` a place). Culture packs and posed dilemmas may use the subset in `Cultures.DO_KEYS`.

## rivals.json

- `relations`: how fast feelings drift back toward a clan's temperament (`drift`), what treaties add (`goodwill`), the stance thresholds (`stance_at`; the stance names are fixed ids), and from which loss a clan keeps a grudge (`grudge_at`).
- `deeds`: what each of our deeds does (`relation`, the `reason` they remember, the `alert` we get): killing their people, attacking their hunters or traders, breaking a peace, building on their land, an unpaid tribute, attacking, burning or plundering their village.
- `raids`, `demands`, `theft`, `trespass`, `defence`, `spoils`, `traders`, `alliance`, `people`: when and how strongly clans act, all numbers. Clans grow as we do: `people.max_pop` is `{base, per_our_pop}` (`rivals.max_pop()`) and a war band's size gains `raids.size.per_our_pop` per person of ours (if the clan has the warriors). `raids.outside_first`: a walled village's raiders go for a building outside the ring first (`rivals.outside_target()`), and torch fields. `raids.coalition`: against a tribe of `min_pop`, another hostile clan sends a share of its warriors with each raid.
- `parley`: the chief's valuation of a deal. `[martial, peaceful]` pairs give different values for the two kinds of clan; `weights.stone` is `[before era 2, after]`. The checks on what an LLM chief may answer (`sanitize_terms`, `check_reply`) stay in code.

## rules.json

- `survival`: hunger rates, when people eat and how much a meal costs and fills, starving damage, food storage (`store_base`; each building adds its type's `store` in structures.json) and rot.
- `gathering`: `return_to`, the kinds of node a gatherer goes back to after hauling a load (a half-butchered kill); for any other work they pick afresh.
- `dilemmas`: spacing between the chieftain's dilemmas: after one pauses the game, the next waits `min_gap_hours` game hours in its queue unless it is `urgent` (listed here, or `"urgent": true` on the dilemma); day one is exempt.
- `strife`: civil strife: a tribe of `min_pop` or more whose mood stays under `mood` for `days` rises (dilemma `strife`).
- `fuel`: winter fuel: wood the fires burn per head a second (more in the dark); with none left, bonfires give no warmth (`sim.fuel_rate()`, `out_of_fuel()`).
- `lod`: level of detail: people out of danger update every `every`-th tick with that many times the step; fighters, the fleeing, those reacting, in an emergency or hurt within `hot_secs` every tick.
- `tiers`: camp, village, town, city: per settlement, the people, beds, buildings (any of a nested list), food storage and age each needs (`sim.tier_of(at)`, `sim.places_summary()`), the names settlements take and the texts. `contracts.settle_room`: no new outpost while one of ours has this many free beds.
- `births`: the pace per grown family lines, the food a birth needs and costs, slower in winter and gloom; `beds` `crowd_at`/`crowd_k`: past this share of beds taken the camp is crowded (births taper, sickness spreads more). `migration`: families from allies and vassals, wanderers (the `wanderers` dilemma), and what newcomers bring. `herds` (the aurochs pens), `burial`, `beds`.
- `triggers`: the conditions (as in scenario scripts) for the overpopulation and Chosen One dilemmas.
- `vice`: the Vice-Chieftains. Two offices (Steward, War Chief), one slot at first (Tribal Code or the Council of Elders opens the second; `sim.vice_slots()`). Appointing someone to a held office replaces the holder; `sim.dismiss(role)` frees it. `every` (seconds between their rounds), `steward_reach` (how far from home idle people are put to work), `warchief_range` (beasts this close to the village call the War Chief), `fighters` (how many they keep on the nearest one), `reach` and `min_hp` (who may be sent: close enough, healthy enough, not sick). `steward`: the one need rule: `needs` (per resource a `target` count or `of_store`: a share of what the stores hold (food: full granaries), `when` it counts, `weight`: how vital), `build` (a site's need), `leisure_below` (no need above it: crafts, else rites), `starving` (the badly hurt work anyway), `policy` (the Council's way: times a resource's weight), `shift`, `area_r`, `rest_below` (`sim.steward_needs()`, `need_of()`).
- `beds`: `far` (beyond it people camp where they are) and `day_only`: kinds of work (`sim.work_kind()`: a job type, or `renovate` for renovating and upgrading) that wait for the morning even when ordered at night.
- `day`: the parts of the day as `[from, to]` fractions (`night` = the rest hours, `dark`, `dusk`, `dawn`, `morning`; a part may wrap past midnight). Every rule, the sky's colour and the HUD read them through `sim.is_day_part()`.
- `healing`: how wounds heal (near a fire or not, fed and unhurt), yarrow poultices and willow-bark tea (each costs a herb), fever and how far cold hurts.
- `defense`: when someone who is hit fights back or flees (`flee_below` of full health).
- `vice.steward`: the odds and thresholds behind the Steward's choice of work for each idle person (see its `_doc`).
- `research`: `known_gives`, what a research contract's work becomes when its tech was already known.
- `ward`: the totem ward a chieftain may answer beasts with when they attack a contract crew: `cost` (paid with `sim.spend()`, offered only if affordable; its texts show the lore price) and `radius` (how far beasts are scared off).
- `buildings`: one building at a time: `renovate_work`/`renovate_wood`/`stone_era3` (renovation), `upgrades` (`{"hut": [{"to": "large_hut"}]}`: what a building can become; `upgrade_cost`, `min_wood`, `upgrade_work`), `demolish` (`refund`, `never`), `ring` (the radii a wall may have: `min`, `max`, `step`). An `improvements` entry with `"upgrade": <from type>` makes the Steward upgrade one instead of building anew.
- `improvements`: (counts in `fewer` may grow with the tribe: `{"base": 2, "per_pop": 0.05}`) what the village lays out by itself (`improve.gd`, `sim.improve`): `planner` (`steward`: only while a Steward is appointed; `anyone`), how often it looks (`every`), how many unfinished sites it may have (`max_sites`, a count that may grow with the tribe), the wood it keeps back (`wood_reserve`), how far from the village it builds (`reach`), and `list`: in priority order, `{"structure", "when": conditions, "near": a structure type to build beside, "reason"}`. An entry with `"at": "outpost"` builds within `outpost_reach` of the outpost that should grow next: of those crowded (`beds.crowd_at`) and with fewer people than `outpost_share` of the village's, the one with the fewest (`improve.outpost_to_grow()`, only one with a fire); with `"missing": true` it builds at the outpost with people and none of that structure nearby (`improve.outpost_without()`: a bonfire first). The Steward sends people to the sites of their own settlement first, including buildings of a finished contract that a flood, quake or fire damaged (`sim.site_for(u)`); a crowded settlement (`beds.crowd_at`) sends a family to one that is not crowded and has a free bed and a fire of ours within `beds.fire_reach` (`sim.warm_at()`), the most crowded first, every `beds.resettle_every` seconds by day (`sim.move_out(from, to)`; for a game master `sim.move_to(i)`, the story action `move_out`, with `i` the settlement's `index` in `sim.places_summary()`), and children are born where a parent lives and there is a bed. When several are wanted, the Steward's LLM node chooses (`ask`, `ask_wait`, `ask_every`); offline, or with no answer, the first is built. `layout`: where it builds (`improve.spot()`). Each building type has a zone (`zones`: homes by default, fields, plaza). `ring_zones` (by the tier a settlement has earned) are laid out on rings round the fire (`ring`: `first`, `step`, `last`): a camp's huts in a circle, and always the shrines and halls round the plaza. Everything else goes on a grid beyond `core`: `lattices` of lots `pitch` apart, held at radius `lot` (a hut can grow into a longhouse in place), in blocks of `block` lots with a `street` between blocks and through the middle. Fields lie in a wedge (`fields`: `half_angle`) toward the most open land, chosen once per settlement (`improve.fields_dir()`, saved in `improve.plans`); every other zone keeps out of it. Of the free places, the one nearest the anchor (the village, or the `near` building) is taken. `improve.summary()["layout"]` reads it.
- `folk`: `child_days`, `art_time`, `mood` (what lifts and lowers it, how fast it moves, the words for it), `art` (goods, decoration, masterpieces), `treasures` (names by kind of art), `trade` (what goods are worth, rates by stance, haggling).

## hunt.json

`kinds` maps a beast kind (`tiger`) to its tactics; kinds not listed are fought straight on. Everyone with an attack job on the same beast is one band (`sim.hunt.summary()` lists them). A band of at least `band` musters at a rally point `rally_dist` from the beast, on the side it comes from, and charges together once all are within `gather_r` of it, after `max_wait` seconds, after `wait_hurt` seconds once the beast has struck someone, or at once when the beast comes within `engaged_r` of the rally point or of one of them (or one is hit). In the fight each takes a place `ring_r` from the beast, spread evenly round it; every blow does `flank` more for each other fighter within `flank_r` (at most `flank_max`). A fighter below `fall_back_below` of their health steps back `fall_back_dist` while another keeps the fight up. Texts: `act` (mustering), `fall_act`, `popup` and `words` (shouted by the best fighter on the charge).

`alone`: nobody faces such a beast alone unless they are a match for it (blow for blow they'd outlast it `solo_margin` times over: `sim.hunt.can_solo()`). Someone the beast goes for (within `notice_r`, checked every `notice_every` s) or strikes, with no grown-up within `alone_r` and nobody fighting it, runs to the nearest grown-up within `seek_r` (or home) and calls for help: the `help_event` reactions (`hunt_help` in reactions.json). A band smaller than `band` that isn't a match for it calls for help and waits (`act`); after `lone_wait` s without help, or when the beast comes at them, they back off (`out_popup`) or run to the others (`popup`). The belligerent stand their ground.

`archers`: people who carry a ranged weapon (weapons.json) shoot. In a band they muster too, then stand off the weapon's `range` x0.8 spread in an arc (`spread` radians), step back when the beast is within `keep`, and every weapon `cd` s shoot for their attack (which holds the weapon); against any other foe they stand off on their own side. `flight`: how long a missile is drawn; `xp` combat XP per shot (half in `skill`, which also adds 4% a level to critical shots).

## weigh.json

How people weigh an errand before they commit to it and while it lasts (`docs/weigh.md`). The cost is the time out there: the walk there, `work[kind]` seconds at it (`gather`, `seek`, `explore`), the walk back into the warmth of the nearest fire (straight-line distances count `detour` times). The risk is the health that time costs while the cold can kill (winter, a deadly weather, or one announced and coming within that time; the night counts if the time runs into the dark), counted `safety` times. An errand fits when it leaves `floor` of the person's health, times `traits` (cautious keep more) and divided by `need[res].mult` while the store holds less than `per_head` a head. `sim.find_node(..., who)` leaves out the places that don't fit and counts `beasts.penalty` more for a place within `reach` of a hunting beast or `den_reach` of a known den; gathering weighs its node again every `recheck` s; the Steward gives other work (the other of food and wood, a building site, else nothing: in the cold the idle sit by the fire); scouts only go where they can come back from. Out in the cold, someone heads back as soon as what they have above `back_floor` only just covers the way to the nearest fire (`must_head_back`, checked every `check_every` s; the `freezing` reaction). `sim.weigh.trip()`/`appraise(unit_id, x, y, work, res)` give the appraisal as a dictionary, `summary()` the state. While the river is in flood, places across or in it don't fit and walkers wait on the bank (`flood_say_every`); within `beasts.avoid_reach` of a hunting beast with band tactics (hunt.json kinds) nobody goes, nor runs to tend someone hurt (`danger_at`). `refuse` gives per reason (cold, flood, beast) the `act`, `popup`, life.json talk situation (`talk_as`) and the `reason` an envoy or trader can't be sent. `on: false` turns the weighing off.

## weapons.json

`weapons`: each weapon is open to the tribe while its `when` condition holds (usually its invention: Fire-Hardened Spear, Hafted Stone Axe, Hunting Sling, Hunting Bow; the club is always there). `kind` `melee` strikes at `reach` every `cd` s; `ranged` shoots from up to `range`, stepping back inside `keep`. `atk` multiplies the wielder's attack (`sim.unit_atk` folds in the weapon and their mastery), `crit` adds to critical blows, `needs` ({skill: level}) is what it takes to use it (aiming a sling or bow needs Foraging & Hunting 3), `rating` how keen people are to carry it, `start_skill` the skill whose level their first mastery starts at. Who carries what: the weapon they are told to (`u.wield`) if they can use it, otherwise the one with the best `rating` x mastery x the square root of their knack (`arms.wielded()`).

`mastery`: a level from `lv` takes `xp_base` + `xp_per_lv` x `lv` XP, up to `max_lv`. XP comes from blows and shots (`blow_xp`), kills (`kill_xp`), deer brought down (`hunt_xp`) and the `spar` idle act at a Weapon Rack (life.json `arms_xp` a second), all times the person's knack. A level gives `atk_per_lv` attack, `cd_per_lv` quicker blows (at most `cd_max`) and `crit_per_lv` crits. At `master_lv` they are a master (`log`, `remember`; the tribe's first master of each weapon is an achievement, `title`). `talent`: each person's knack per weapon, rolled once from the person (not the game's dice) between `min` and `max`, or `gifted` with `gifted_chance`, times `traits` for their first trait; `words` name it on the sheet. Operations: `arms.set_wield(u, id)`, `arms.practice(u, id, xp)`, the story actions `wield` and `arms_xp`, and `arms.summary()`.

## reactions.json

`on` maps a happening to a list of responses. The rules send these happenings (`sim.react.trigger(event, ctx)`):

| Event | Sent when | ctx |
|---|---|---|
| `earthquake` | the earth shakes | at |
| `hurt` | someone is hurt by lightning or a flood (and after a quake) | victim |
| `burned` | someone is caught by a wildfire | victim, at |
| `attacked` | a beast or raider hits someone | victim, attacker |
| `flood_warning` | the river starts rising | at |
| `volcano_tremor`, `eruption` | the Fire Mountain | danger |
| `wildfire` | every second while trees burn, for each person near a fire | danger, fire |
| `freezing` | someone is out in killing cold, away from a fire | victim |
| `beast_seen` | a scout sees a beast | victim, danger, attacker |
| `hunt_help` | someone alone a dangerous beast comes for (or sent against it alone) calls for help (hunt.gd) | victim, attacker, at |
| `panic` | the tribe panics (the `panic` action) | until |
| `blizzard`, `storm`, `rain`, `drought`, `sickness`, `famine` | they start (no reactions by default) | at, victim |
| `built` | a building of ours is finished | at |
| `masterpiece` | someone makes a treasure | at |
| `birth` | a child is born | at |
| `visitor` | a trader of another clan reaches the village | at |
| `beast_slain` | someone kills a beast | at, victim (the hunter) |
| `thunder` | lightning strikes | at, danger |

A response:

- `do`: the verb, one of `cover` (leave the huts, crouch away from buildings until the shaking stops; `then` triggers another event for the hurt nearby), `aid` (dress a wound: `time`, `heal` as a fraction of max HP), `flee` (run `dist` away from the danger, or to `reach + beyond` from it; with `who: river` away from the water; `resume: false` drops the work instead of going back to it), `firefight` (beat out fires within `near_home` of the village or `near_building` of a building: `count`, `rate`, `stand_off`), `defend` (fight the attacker: `count`, `reach_by_trait`), `warm` (go to the nearest fire when below `below` of max HP, stay until `until`), `shelter` (hide in one's hut until the panic ends), `look` (people standing about come to see: `chance`, `count`, `ring`, `time`, `talk`), `startle` (stop dead for `time` seconds). `look` and `startle` only run while everyday life is on (`life.json`). Any response can have `talk` (a situation of `life.json`'s talk lines, said with `talk_chance` as it starts; `talk_force` lets it past the usual limits, for a panic) and `pose` (`cover`: the drawn pose once there). A danger cuts off whatever people were saying.
- `who`: `all`, `able` (fit grown-ups, see `able`), `victim`, `near` (within `reach` of the place), `river` (within `reach` of a river), `helpers` (the nearest able people within `reach` of the victim; the victim's friends and kin come from `bond_reach` further, and first).
- `roles`, `skip_roles`, `skip_jobs`: narrow it down (`""` is an ordinary villager).
- Texts: `popup`, `remember`, `log`, and `acts` (what the person is shown doing; `%s` is the other person's name).

`night_watch` sets what rouses the sleeping camp (beasts near the village, a fight, a flood) and for how long.

Responses run in order, and someone taken by one is not picked by the next. People go back to their interrupted work afterwards. A new verb or selector needs code in `reactions.gd` (`VERBS`, `WHO`); a new happening needs a `sim.react.trigger()` call where it happens in the rules.

## life.json

Everyday life (`life.gd`, `sim.life`). Each person stands for one family line; a child starts a new line, kin to its parent's.

- `meals`: in each of `times` (day parts), hungry people at home put down the work in `jobs` and eat in a ring at the nearest fire. A meal costs food in proportion to what is eaten (`rules.json` survival `meal` per `meal_fill`), so the food economy is unchanged; people away from home still eat from the stores when very hungry (`eat_below`).
- `wake`: a moment at dawn before work. `pace`: walking speed with weariness, hunger, alarm.
- `fatigue` (weariness) and `morale` (spirits): per person; morale is the tribe's mood plus hunger, sickness, wounds, weariness, grief, praise, friends and rivals nearby. Both change work speed (`sim.work_mul`).
- `praise`: cheer from one's own deeds (level up, kill, masterpiece, coming of age).
- `leave`: a family in despair asks to leave: the `discontent` dilemma in `dilemmas.json`.
- `bonds`: friends, rivals and kin between families: how they start, grow (shared work, fights, festivals, chats, meals), help (work bonus) and grieve.
- `idle`: the acts people pick when nobody needs them: `weight` plus `more` per condition, `needs`, `when` (tribe conditions as in scenario scripts). Verbs: `sit` (at `fire`, `here`, `shelter`, `grave`, `edge`), `chat`, `work`, `water`, `watch`, `gaze`, `ritual`, `art`, `wander`. `pose` is the drawn pose (`sit`, `talk`, `build`, `gather`).
- `speech` and `talk`: speech marks over heads; `talk` holds lines per situation, `<situation>:<trait>` for a trait's own.

With `sim.life.on = false` (tests) none of it runs and the old rules hold.

## Operations (for scenarios, packs and a game master)

Everything above can be set off from data or from outside the rules, through the same calls the game uses itself:

| Operation | Does |
|---|---|
| `sim.story.run(actions, null)` | runs a list of actions (the format above) |
| `sim.story.pose(id, dilemma)` | checks a dilemma (`Cultures.check_dilemma`), queues it as `posed:<id>`; returns the problems, `[]` if posed |
| `sim.react.trigger(event, ctx)` | sets off the configured reactions to a happening |
| `sim.hz.set_weather(kind)` | brings that weather now (`"clear"` ends it); false for an unknown kind |
| `sim.life.add_lines(situation, lines)` | new things people say (known situations, strings only, clipped); returns the problems |
| `sim.life.summary()` | each person's spirits, weariness, friends, rivals, kin, grief and what they are saying |
| `sim.careers.set_career(uid, id)` / `release(uid)` | names someone to an open career (the rules still hold: returns `""` or why not) / releases them |
| `sim.careers.summary()` | who lives by which trade, rising callings, open careers, places used of places |

Actions for people (`who`: `all`, `best:<skill>`, `name:<name>`, `id:<n>`, `$<var>`): `{"morale": n}` (one family's spirits), `{"bond": n, "with": who}`, `{"say": text}`, `{"depart": true}` (the family leaves the tribe), `{"career": id}` (named to a career; `""` releases). Condition `{"career": id}`: someone living holds it.

Their input is checked like a culture pack's: unknown ids and malformed actions are refused, not run.

## audio.json

There are no sound files: every sound is a **recipe** in `sounds`, rendered by `synth.gd` into a 22 kHz WAV on a worker thread at startup and cached in `user://sound_cache/` (named by a hash of the recipe, so an edited recipe is rendered again). A recipe is `{"dur", "loop", "gain", "layers": [...]}`; each layer is a `wave` (`sine`, `tri`, `square`, `saw`, `noise`, `crackle`) with `freq` → `to` (a glide), `at`/`len`, an envelope (`attack`, `decay`), `vol`, filters (`lp` → `lp_to`, `hp`), `vib` and `am` (`[Hz, depth]`), `harm` (`[[multiple, vol]...]`) and `density` (crackle).

- `volume`: the default volumes (the Sound dialog saves the player's own in `user://settings.cfg`).
- `on_log` (chronicle kind → sound), `on_alert` (level), `on_signal` (any `sim` signal), `on_happening` (the ids of `after` conditions: weather and nature), `ui_click`.
- `jobs`: the sounds of people near the camera at work, by what their hands are doing (`doing`: chop, quarry, build, butcher, pick, fight, ritual, dance, craft, paint, experiment, watch, or an idle act id from life.json such as mend, hide), `every` `[min, max]` seconds; at most `max_voices` at once; `beasts` for wild animals.
- `ambience`: loops faded in while `when` holds; `near` a structure type or `river` makes it come from the nearest one.
- `random`: one-shots now and then (`every`, `spread` around the camera, `pitch` range).
- `music.moods`: the first whose `when` holds plays (it changes on the bar): `bpm`, `root` (semitones), a pentatonic `scale`, `drums` (16-step patterns per sound, `x` = hit), the `flute` (a wandering melody: `density`, `octave`, `leap`) and the `drone` level.

`when` takes audio's own keys `night`, `danger`, `festival`, `paused` (true/false), `weather` and `seasons` (lists), and any condition of scenario scripts. Scenario scripts, dilemmas and a game master can play a sound with the story action `{"sound": id, "at": place}`.

## policies.json

The Council's standing policies (`policy.gd`, `sim.policy`; the **Council** button or `P`). Each entry under `policies` has a `title`, `desc`, `unlock` (conditions), a `default` choice (with no effects, so the defaults are the base game) and `choices`. A choice has:

- `label`, `desc`, `unlock` (e.g. `{"tech": "farming"}`).
- `effects`: the shared effect stats (`D.EFFECT_STATS`), folded with the inventions' by `inv.mul()`/`inv.add()`. Added for policies: `regrow` (trees and bushes), `herd` (deer that come back per deer hunted), `wildfire` (spread), `insight` (`of`: tech ids, several as `"a|b"`), `relation` (what the clans' feelings settle toward), `prefer` (`of`: a node kind; how much gatherers favour it).
- `culture`: drift per day on the culture axes while it holds.
- `on_start`: `story.run()` actions when it takes hold.
- `liked_by` / `disliked_by` (personality traits) and `pro` / `con` (their words): who speaks at the Council, and what they say offline.

- `touches` (on the policy): the contract kinds whose leaders care about it. `on_contract` (`{kind: actions}`): run when such a contract is sealed under this choice (var `clan` = a war's target). `warn` (`{kind: text}`): shown while negotiating one.

**Objections:** a leader whose personality dislikes a way in force that touches the task, and likes another choice, says so first in the negotiation (the LLM voices it; offline, the choice's `con` line). The chieftain can change the way on the spot (the usual cost and delay) or let it stand: then the crew works at `objection.sullen_work` speed. Either way the leader remembers (`remember_heard` / `remember_stand`). The engine decides who objects (`sim.policy.objection(u, kind)`); `sim.policy.answer(u, objection, heard, contract)` settles it.

`switch`: the mood a change costs, the days it takes to take hold (`settle_days`; the old way holds until then) and the days before the same policy can be changed again (`cooldown_days`). `council.speakers`: how many elders speak. A game master changes a policy with `sim.policy.set_choice(id, choice, by)` and reads them with `sim.policy.summary()`; every persona prompt lists them (`evo.world_ctx()["the_ways_the_tribe_lives_by"]`).

## emergency.json

Emergency mode (`crisis.gd`, `sim.crisis`). `triggers.attack`: a beast or raider of the listed `kinds` striking one of ours (not `skip_roles`) within `hit_ago` seconds starts a crisis, at most once per `cooldown` seconds. The chieftain can also take command of a contract crew in its emergency dialog. While it lasts, time runs at `slow`, the people within `radius` are the ones commanded, and it ends after `quiet` seconds without a threat (or `max_secs`, or **Hand back**). `titles`, `happened` (for memories, with `remember`), `start_log`, `end_log` and `outcome` are its texts.

`orders`: `{"id", "label", "desc", "verb", "needs": conditions, "cost": {stock: n}, ...}`. The verbs are coded: `fight` (`min_hp`), `rally` (`def`, `close`, `secs`), `scare` (`scare_radius`, `"of": "beasts"`, `popup` with `%d` for how many flee), `to_fire` (`reach`, `scare_radius`), `shelter` (`acts`), `aid` (`below`, `heal`, `time`, `count`, `acts`). An order that would do nothing (no threat, nothing that fears fire, no fire in reach, no one badly hurt) is refused by `order_block()` and costs nothing; the cost is paid once it is carried out. A game master starts one with `sim.crisis.start(kind, at, people, contract)`, gives orders with `sim.crisis.order(id)`, ends it with `end()` and reads it with `summary()`.

## director.json

The director (`director.gd`, `sim.director`) paces the hardships. Everything that goes wrong adds its `weights` entry to a tension score, which eases by the level's `decay` per day (a kind counts once per `same_secs`; every death counts). Before a rolled hardship starts (weather, wolves, tiger raids, sickness, lightning, earthquakes, the volcano, eclipses, clan raids and demands, an emergency) the rule asks `sim.director.allow(kind)`: it may if tension plus its weight stays within the level's `cap`; else it is put off by `retry` seconds or skips its roll. Unrolled hardships (the seasons' floods, scripted events, deaths) always happen and count. A kind without a weight is never held back; with the challenges off the director rests.

`distress` (food under `food_per_head` a person, `deaths` within `death_days`, or mood under `mood`) drops the cap to `mercy.cap`, and every `mercy.cooldown_days` the first `mercy.gifts` entry whose `when` holds runs its `do` actions. `tools/pacing.gd` measures the result (per-day CSV from headless games).

## names.json

Names for people born into the tribe once the culture's `birth_names` are all given (`names.gd`). `patterns` combine two lists of parts: `nature` puts an adjective before an animal, plant or thing of nature (`Little Fox`, 小狐) and `clan` an old Chinese surname before a nature word's pinyin (`Jiang Song`, 姜松); `weight` sets how often each is used. Parts are `[English, Chinese]` (and `given` adds the pinyin). The English form is the name and its translation key: every combination (about 11,000) is registered for Chinese at startup, so built names translate in loaded games too. A name is never given twice.

## lands.json

The kind of land a map is (`lands.gd`, `D.LAND`). Each land has `woods` (`count`: forests, x the base 80 per standard area; `trees` and `spread` per forest; `follow`: how strictly forests keep to the wet ground of a woodland noise map, so woods gather into woodlands with meadows between; `river`: more woods near rivers), `moisture` (0 dry, 1 wet: grass colour and dry patches), `bushes` and `herds` (multipliers), `weather` (chance multipliers per weather kind) and `wildfire` (spread). Random maps pick one by the weights in `random` (or the player's New Game choice) and vary `count`, `bushes`, `herds` and `moisture` by `jitter`, all from the map seed; scenarios name theirs (`"land"` in the map spec), else `default`. The Ford is parkland with `follow` 0, so its woods are as they always were. Personas are told the land (`evo.world_ctx()["the_land"]`).

## roads.json

Roads (`roads.gd`, `sim.roads`): a level for every cell of the foot-wear grid (30 paces). A **trail** (level 1) emerges where foot wear passes `emerge_wear` and fades after `fade_days` with wear under `keep_wear`. Built `levels` (2 and up) have `needs` (conditions; packed earth needs the Road Making invention, stone also Bronze Casting), `cost` per cell (times `trail_discount` over an existing trail or road), `work` per cell, `speed` (how much faster people walk) and `look` (how the terrain shader paints it: 1 worn dirt, 2 packed earth, 3 stone). The Road tool, the Steward (an `improvements` entry with `"road"`) and a game master lay roads with `sim.roads.lay(a, b, level)`: the cells along the route over the fords (at most `max_cells`), built cell by cell on a `roadworks` site; `sim.roads.summary()` reads them.

## discovery.json

Finds are noticed by chance (`sim.find_chance(u, id)`, checked twice a second for everyone within `range`, or `seek_range` when searching): per second `groups[group].chance` x (1 + `per_lv` x their level in the group's `skill`: forage for foods, lore for medicines, craft for ores) x `traits` multipliers x `activity` (`seek` when searching for that group, `explore`, `gather`, `build`, `default`) x the find's rarity (`finds`). The find's own `needs` (lore, tools) still decide whether they can recognise it at all. An invention whose practice is complete breaks through each 2-second check with `inventions.chance` x (1 + `per_lv` x the best contributor's level in the skill for its kind).

`seek`: the **search quest** (a Task Contract of kind `"seek"`): the kinds of place each group is looked for in (`forest`, `meadow`, `riverbank`, `hills`, `volcano`; the game picks up to `places` real places of those kinds, nearest first, and the leader chooses), `days` the search may last (`secs_per_day` of searching each), the `radius` the crew roams, and `crew_max`. The crew's finds are tallied on the contract (`flags.found`) and reported when it ends.

## society.json

The parameters of the society model ([society.md](society.md) §12): the working day's time
budget, the walk, the people (children, the unwell), what the tribe values per channel and
each need's `impact` on it, the food sources (season profiles, rates, which take the level's
method factor), order's, health's and safety's laws, tools as a worn good, and per **level**
(band, camp, village, town, city) the reference size, the productivity factors, the walk,
spoilage, institutions, bought food, land limits (`Y`) and each other need's hands per
head; `work` holds the knobs the game reads (the gathering rate, the skill curve, the Steward's reserve and buffer, food security's ramp `secure_from`/`secure_to`), overridable per challenge level in `work.by_challenge`; `jobs` maps the game's job types to the needs (the metrics' society report); `targets` holds the share of hands per need and the R band the model intends. Read
only by the calculator `tools/society_calc.gd` for now (society_plan.md step 0); no
player-visible texts.

## notices.json

What interrupts the player (`hud.gd`). `feat_dialog`: the kinds of achievement that open a dialog (default: heroes and outposts; a new era and a first contact already open their dilemma); every other first is a banner notice you can click to look there. `contract_done`: `"notice"` or `"dialog"` when a Task Contract finishes. `trader`: a trader's arrival as a `"notice"` (click it to trade; after `trader_wait` game seconds the trader goes home) or a `"dialog"`. `gap`: real seconds after a dialog closes before a waiting achievement dialog opens. Dilemmas and emergencies always ask, except **routine** ones: a dilemma with `"routine": {"prefer": [option indexes]}` in `dilemmas.json` (the seasonal festival) is decided by the Steward, when one is appointed and the player lets it (the checkbox under the Steward policy, `sim.steward_routine`), and only reported.
