# Rule configs: events and reactions

The forces of nature, the hardships and how people respond to them are data, in `config/`:

| File | Read by | What it holds |
|---|---|---|
| `config/events.json` | `hazards.gd`, `nature.gd` | seasons, weather, wolves, tiger raids, sickness, famine, lightning, wildfire, flood, Fire Mountain, earthquake, eclipse: when they happen, how strong they are, what the tribe is told |
| `config/reactions.json` | `reactions.gd` (`sim.react`) | for each happening, what people do about it |

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

Choices put to the chieftain share one format, run by `story.gd` (`dilemma_view()` for the HUD, `dilemma_choose()` to resolve): culture pack events, the eclipse, and dilemmas posed from outside.

```json
{"title": "...", "text": "...", "speaker": "best:lore", "speaker_default": "The elders",
 "options": [{"label": "...", "desc": "...", "cost": {"food": 15},
   "needs": {"best": "lore", "lv": 3, "or_tech": "totems"},
   "do": [actions], "result": "...", "else_do": [actions], "else_result": "..."}]}
```

`%s` in the title, text, labels and results is the speaker's name. A cost is added to the description and disables the option when the tribe can't pay. An option whose `needs` are not met runs `else_do`/`else_result`. Actions are those of scenario scripts (`story.gd run()`): `log`, `alert`, `give`, `spawn`, `reveal`, `mood`, `devotion`, `insight`, `culture`, `invent`, `boon`, `remember` (`%d` is the day; `who` = `all` or `best:<skill>`), `xp`, `panic`, `weather`, `react`, `feat`, `tale`, `join`.

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
