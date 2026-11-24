# Rule configs: events and reactions

The forces of nature, the hardships and how people respond to them are data, in `config/`:

| File | Read by | What it holds |
|---|---|---|
| `config/events.json` | `hazards.gd`, `nature.gd` | seasons, weather, wolves, tiger raids, sickness, famine, lightning, wildfire, flood, Fire Mountain, earthquake, eclipse: when they happen, how strong they are, what the tribe is told |
| `config/reactions.json` | `reactions.gd` (`sim.react`) | for each happening, what people do about it |
| `config/rivals.json` | `rivals.gd` | the rival clans: how our deeds change their feelings, stances, raids and demands, theft, trespass, their people's strength, traders, war spoils, and how a chief weighs a deal at a parley |
| `config/rules.json` | `sim.gd`, `folk.gd` | everyday life: eating and hunger, skill levels and XP (`skills`: the curve, the cap, the mastery level, the Centurion Aura), food storage and rot, births, the aurochs pens, burials, beds, when the overpopulation and Chosen One dilemmas come up, and folk life (children, art and treasures, mood, trade values) |
| `config/legacy.json` | `legacy.gd` | the endgames: each victory path's conditions (`count`: vassals, allies or techs, all of them; `built`: a structure), the event and saga texts, and the defeat |
| `config/audio.json` | `audio.gd`, `synth.gd` | the sounds (recipes rendered in code), what plays on which happening, the sounds of people at work, ambience, and the music's moods |
| `config/policies.json` | `policy.gd` | the Council's standing policies: their choices, effects, culture drift, unlocks, who likes them and what they say |
| `config/emergency.json` | `crisis.gd` | emergency mode: when it starts, how slow time runs, who is in it, when it ends, the orders and their numbers |
| `config/director.json` | `director.gd` | pacing: what each hardship weighs, how much the tribe can take per challenge level, when it is in distress, and the mercy gifts |
| `config/names.json` | `names.gd` | names for the newborn once the culture's own are used up: the parts (adjectives, animals, plants and things of nature, old Chinese surnames) and how they combine |
| `config/lands.json` | `lands.gd`, `sim.gd`, `world_view.gd` | the kinds of land (steppe, parkland, woodland, old forest): how wooded, and the grass, bushes, herds, weather and wildfire that go with it; which random maps get |
| `config/roads.json` | `roads.gd` | trails that emerge from feet and fade when abandoned; the road levels the tribe can build (packed earth, stone): what they need, cost and take to build, and how much faster people walk on them |
| `config/discovery.json` | `sim.gd`, `inventions.gd`, `contract_system.gd` | the odds of noticing a find (by group, skill, temperament, activity, rarity) and of an invention's breakthrough; the search quests: where each group is looked for, days, radius, crew |
| `config/notices.json` | `hud.gd` | what interrupts the player: which achievements open a dialog (the rest are banner notices), contract completions and traders as notices, the gap between dialogs |
| `config/save.json` | `main.gd` | autosave interval and how many to keep, the number of save slots, the quick-save slot |
| `config/ranks.json` | `ranks.gd` (`sim.ranks`), `sim.gd` (`gain_xp`, the Centurion Aura), `folk.gd` (master trader), `hud.gd` | ranks earned by deeds: the routine level cap, the level bands of each rank (Proven, Master), and per skill each rank's title and trial (the deeds from a person's deed record `u.deeds` that open it); rank-up texts |
| `config/structures.json` | `data.gd` (`D.STRUCTURES`), `sim.gd`, `nature.gd`, `improve.gd`, `hud.gd` | the buildings: cost, work, footprint, what they house or trickle, the tech they need, which hazards can knock them down (`sim.hit_by(s, hazard)`), the DEF a wall gives inside it, era styles, decoration, culture drift when finished; the build menu, what a contract may build, and the names an LLM may use for them |
| `config/dilemmas.json` | `sim.gd`, `folk.gd`, `rivals.gd` | the chieftain's choices: the Great Flood warning, overpopulation, the Chosen One, the dawn of each era, the festivals, and the rival clans' first contact, demands, calls to war and surrender |

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
- **Actions** (`story.gd run()`, all listed in `story.ACTIONS`): `log`, `alert` (`at`, `level`), `give`, `spawn`, `reveal`, `mood`, `devotion`, `insight`, `culture`, `invent`, `boon`, `remember` (`%d` is the day; `impact`), `xp`, `hurt` (fraction of max HP), all with `who` = `all`, `best:<skill>` or `fighters:<n>`; `panic`, `weather`, `react`, `great_flood`, `open` (`contract`/`war`: the rules open that planning), `chosen`, `festival` (`length`, `glow_days`), `births`, `guests`; on the rival clan in var `clan` (or the one named by `"clan": "foe"`): `relation` (+`reason`), `relation_min`/`relation_max`, `raid`, `raid_delay_days`, `vassal`, `clear_treaties`, `grudge`, `peace_days`, `clan_pop`; and `feat`, `tale`, `join`, `sound` (a sound from `audio.json`, `at` a place). Culture packs and posed dilemmas may use the subset in `Cultures.DO_KEYS`.

## rivals.json

- `relations`: how fast feelings drift back toward a clan's temperament (`drift`), what treaties add (`goodwill`), the stance thresholds (`stance_at`; the stance names are fixed ids), and from which loss a clan keeps a grudge (`grudge_at`).
- `deeds`: what each of our deeds does (`relation`, the `reason` they remember, the `alert` we get): killing their people, attacking their hunters or traders, breaking a peace, building on their land, an unpaid tribute, attacking, burning or plundering their village.
- `raids`, `demands`, `theft`, `trespass`, `defence`, `spoils`, `traders`, `alliance`, `people`: when and how strongly clans act, all numbers.
- `parley`: the chief's valuation of a deal. `[martial, peaceful]` pairs give different values for the two kinds of clan; `weights.stone` is `[before era 2, after]`. The checks on what an LLM chief may answer (`sanitize_terms`, `check_reply`) stay in code.

## rules.json

- `survival`: hunger rates, when people eat and how much a meal costs and fills, starving damage, food storage and rot.
- `births`, `herds` (the aurochs pens), `burial`, `beds`.
- `triggers`: the conditions (as in scenario scripts) for the overpopulation and Chosen One dilemmas.
- `vice`: the Vice-Chieftains. Two offices (Steward, War Chief), one slot at first (Tribal Code or the Council of Elders opens the second; `sim.vice_slots()`). Appointing someone to a held office replaces the holder; `sim.dismiss(role)` frees it. `every` (seconds between their rounds), `steward_reach` (how far from home idle people are put to work), `warchief_range` (beasts this close to the village call the War Chief), `fighters` (how many they keep on the nearest one), `reach` and `min_hp` (who may be sent: close enough, healthy enough, not sick). `wants`: what the Steward has gathered whenever the store runs low, whatever the policy (except lore): `{"res", "below", "share", "when"}`, only if some can be gathered within `want_reach` of home.
- `beds`: `far` (beyond it people camp where they are) and `day_only`: kinds of work (`sim.work_kind()`: a job type, or `renovate` for renovating and upgrading) that wait for the morning even when ordered at night.
- `day`: the parts of the day as `[from, to]` fractions (`night` = the rest hours, `dark`, `dusk`, `dawn`, `morning`; a part may wrap past midnight). Every rule, the sky's colour and the HUD read them through `sim.is_day_part()`.
- `healing`: how wounds heal (near a fire or not, fed and unhurt), yarrow poultices and willow-bark tea (each costs a herb), fever and how far cold hurts.
- `defense`: when someone who is hit fights back or flees (`flee_below` of full health).
- `vice.steward`: the odds and thresholds behind the Steward's choice of work for each idle person (see its `_doc`).
- `research`: `known_gives`, what a research contract's work becomes when its tech was already known.
- `ward`: the totem ward a chieftain may answer beasts with when they attack a contract crew: `cost` (paid with `sim.spend()`, offered only if affordable; its texts show the lore price) and `radius` (how far beasts are scared off).
- `buildings`: one building at a time: `renovate_work`/`renovate_wood`/`stone_era3` (renovation), `upgrades` (`{"hut": [{"to": "large_hut"}]}`: what a building can become; `upgrade_cost`, `min_wood`, `upgrade_work`), `demolish` (`refund`, `never`), `ring` (the radii a wall may have: `min`, `max`, `step`). An `improvements` entry with `"upgrade": <from type>` makes the Steward upgrade one instead of building anew.
- `improvements`: what the village lays out by itself (`improve.gd`, `sim.improve`): `planner` (`steward`: only while a Steward is appointed; `anyone`), how often it looks (`every`), how many unfinished sites it may have (`max_sites`), the wood it keeps back (`wood_reserve`), how far from the village it builds (`reach`), and `list`: in priority order, `{"structure", "when": conditions, "near": a structure type to build beside, "reason"}`. When several are wanted, the Steward's LLM node chooses (`ask`, `ask_wait`, `ask_every`); offline, or with no answer, the first is built.
- `folk`: `child_days`, `art_time`, `mood` (what lifts and lowers it, how fast it moves, the words for it), `art` (goods, decoration, masterpieces), `treasures` (names by kind of art), `trade` (what goods are worth, rates by stance, haggling).

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

Actions for people (`who`: `all`, `best:<skill>`, `name:<name>`, `id:<n>`, `$<var>`): `{"morale": n}` (one family's spirits), `{"bond": n, "with": who}`, `{"say": text}`, `{"depart": true}` (the family leaves the tribe).

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

## notices.json

What interrupts the player (`hud.gd`). `feat_dialog`: the kinds of achievement that open a dialog (default: heroes and outposts; a new era and a first contact already open their dilemma); every other first is a banner notice you can click to look there. `contract_done`: `"notice"` or `"dialog"` when a Task Contract finishes. `trader`: a trader's arrival as a `"notice"` (click it to trade; after `trader_wait` game seconds the trader goes home) or a `"dialog"`. `gap`: real seconds after a dialog closes before a waiting achievement dialog opens. Dilemmas and emergencies always ask, except **routine** ones: a dilemma with `"routine": {"prefer": [option indexes]}` in `dilemmas.json` (the seasonal festival) is decided by the Steward, when one is appointed and the player lets it (the checkbox under the Steward policy, `sim.steward_routine`), and only reported.
