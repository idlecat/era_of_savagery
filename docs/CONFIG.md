# Rule configs: events and reactions

The forces of nature, the hardships and how people respond to them are data, in `config/`:

| File | Read by | What it holds |
|---|---|---|
| `config/events.json` | `hazards.gd`, `nature.gd` | seasons, weather, wolves, tiger raids, sickness, famine, lightning, wildfire, flood, Fire Mountain, earthquake, eclipse: when they happen, how strong they are, what the tribe is told |
| `config/reactions.json` | `reactions.gd` (`sim.react`) | for each happening, what people do about it |
| `config/rivals.json` | `rivals.gd` | the rival clans: how our deeds change their feelings, stances, raids and demands, theft, trespass, their people's strength, traders, war spoils, and how a chief weighs a deal at a parley |
| `config/rules.json` | `sim.gd`, `folk.gd` | everyday life: eating and hunger, food storage and rot, births, the aurochs pens, burials, beds, when the overpopulation and Chosen One dilemmas come up, and folk life (children, art and treasures, mood, trade values) |
| `config/legacy.json` | `legacy.gd` | the endgames: each victory path's conditions (`count`: vassals, allies or techs, all of them; `built`: a structure), the event and saga texts, and the defeat |
| `config/audio.json` | `audio.gd`, `synth.gd` | the sounds (recipes rendered in code), what plays on which happening, the sounds of people at work, ambience, and the music's moods |
| `config/save.json` | `main.gd` | autosave interval and how many to keep, the number of save slots, the quick-save slot |
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

A response:

- `do`: the verb, one of `cover` (leave the huts, crouch away from buildings until the shaking stops; `then` triggers another event for the hurt nearby), `aid` (dress a wound: `time`, `heal` as a fraction of max HP), `flee` (run `dist` away from the danger, or to `reach + beyond` from it; with `who: river` away from the water; `resume: false` drops the work instead of going back to it), `firefight` (beat out fires within `near_home` of the village or `near_building` of a building: `count`, `rate`, `stand_off`), `defend` (fight the attacker: `count`, `reach_by_trait`), `warm` (go to the nearest fire when below `below` of max HP, stay until `until`), `shelter` (hide in one's hut until the panic ends).
- `who`: `all`, `able` (fit grown-ups, see `able`), `victim`, `near` (within `reach` of the place), `river` (within `reach` of a river), `helpers` (the nearest able people within `reach` of the victim).
- `roles`, `skip_roles`, `skip_jobs`: narrow it down (`""` is an ordinary villager).
- Texts: `popup`, `remember`, `log`, and `acts` (what the person is shown doing; `%s` is the other person's name).

`night_watch` sets what rouses the sleeping camp (beasts near the village, a fight, a flood) and for how long.

Responses run in order, and someone taken by one is not picked by the next. People go back to their interrupted work afterwards. A new verb or selector needs code in `reactions.gd` (`VERBS`, `WHO`); a new happening needs a `sim.react.trigger()` call where it happens in the rules.

## Operations (for scenarios, packs and a game master)

Everything above can be set off from data or from outside the rules, through the same calls the game uses itself:

| Operation | Does |
|---|---|
| `sim.story.run(actions, null)` | runs a list of actions (the format above) |
| `sim.story.pose(id, dilemma)` | checks a dilemma (`Cultures.check_dilemma`), queues it as `posed:<id>`; returns the problems, `[]` if posed |
| `sim.react.trigger(event, ctx)` | sets off the configured reactions to a happening |
| `sim.hz.set_weather(kind)` | brings that weather now (`"clear"` ends it); false for an unknown kind |

Their input is checked like a culture pack's: unknown ids and malformed actions are refused, not run.

## audio.json

There are no sound files: every sound is a **recipe** in `sounds`, rendered by `synth.gd` into a 22 kHz WAV on a worker thread at startup and cached in `user://sound_cache/` (named by a hash of the recipe, so an edited recipe is rendered again). A recipe is `{"dur", "loop", "gain", "layers": [...]}`; each layer is a `wave` (`sine`, `tri`, `square`, `saw`, `noise`, `crackle`) with `freq` → `to` (a glide), `at`/`len`, an envelope (`attack`, `decay`), `vol`, filters (`lp` → `lp_to`, `hp`), `vib` and `am` (`[Hz, depth]`), `harm` (`[[multiple, vol]...]`) and `density` (crackle).

- `volume`: the default volumes (the Sound dialog saves the player's own in `user://settings.cfg`).
- `on_log` (chronicle kind → sound), `on_alert` (level), `on_signal` (any `sim` signal), `on_happening` (the ids of `after` conditions: weather and nature), `ui_click`.
- `jobs`: the sounds of people near the camera at work, by the start of their activity (`act`), `every` `[min, max]` seconds; at most `max_voices` at once; `beasts` for wild animals.
- `ambience`: loops faded in while `when` holds; `near` a structure type or `river` makes it come from the nearest one.
- `random`: one-shots now and then (`every`, `spread` around the camera, `pitch` range).
- `music.moods`: the first whose `when` holds plays (it changes on the bar): `bpm`, `root` (semitones), a pentatonic `scale`, `drums` (16-step patterns per sound, `x` = hit), the `flute` (a wandering melody: `density`, `octave`, `leap`) and the `drone` level.

`when` takes audio's own keys `night`, `danger`, `festival`, `paused` (true/false), `weather` and `seasons` (lists), and any condition of scenario scripts. Scenario scripts, dilemmas and a game master can play a sound with the story action `{"sound": id, "at": place}`.
