# Culture packs

A **culture pack** adds a people to the game: the tools they made, what they ate, what
they found in the land, their heroes and ancestors, the things that happened to them, and
the tales they told. A pack is plain data. You don't need to write any code.

The player picks a culture on the New Game screen. Scenarios have a default culture of
their own, and random maps default to `huaxia`. Everything in the pack then turns up in
the game:

| Section | In the game |
|---|---|
| `inventions` | Everyday inventions that grow out of practice: a log line, an achievement, an effect, the inventor's memory |
| `foods` | The same, in the **Foods** group |
| `finds` | Resources placed on the map, unknown until someone recognises them |
| `people` | The Chosen One's bloodlines, the founders of a random tribe, wanderers who come to join, ancestors who are spoken of |
| `events` | A chronicle line, or a dilemma that pauses the game and lets the player choose |
| `tales` | Folk tales told by the fire, one a night (or at a festival, or when an event calls for one) |

Everything is listed in the **Heritage** panel. Each entry shows a *Historical*, *Legend*
or *Imagined* badge and its source. The LLM personas know the tales that have been told
and the great people of their culture.

48 packs ship with the game, from `huaxia` (Chinese legend, the default) to `lapita`
(Pacific voyagers); `ls cultures/` lists them. `order` sorts them in the New Game list
by region: 1–3 the first three, 10s Near East, 30s Africa, 40s Aegean, 50s South Asia
and the steppe, 60s East Asia, 70s Americas, 80s other Neolithic peoples. Read any of
them as an example; `yangshao` and `natufian` are short and typical.

## Files

```
cultures/<id>/culture.json   the pack, in English
cultures/<id>/zh.json        Simplified Chinese: {"English text": "中文", ...}
```

Packs in `user://cultures/<id>/` load too, for mods without rebuilding the game.

Check a pack after every change. The checker prints each error with its location
(`events[2].options[0].do[1]: unknown tech 'iron'`) and each text that has no Chinese yet:

```sh
$GODOT --headless --path . --script res://tools/check_culture.gd                     # every pack
$GODOT --headless --path . --script res://tools/check_culture.gd -- --pack=res://cultures/yangshao --skeleton
```

`--skeleton` prints a `zh.json` fragment with every untranslated text, ready to fill in.
The test suite runs the same checks (`test_translations`, `test_cultures`). A pack with
errors is left out of the game, with a warning.

To see a pack in the game:

```sh
$GODOT --path . -- --map=standard --culture=yangshao                  # a random map, the culture's tribe
$GODOT --path . -- --shot=/tmp/h.png --demo=heritage --culture=natufian
```

## The top level

(The `//` comments in these examples are explanations only: JSON allows none.)

```json
{
  "id": "yangshao",              // plain identifier, also the folder name
  "order": 2,                    // position in the New Game list
  "name": "Yangshao Villagers",
  "period": "c. 5000–3000 BCE",
  "place": "the loess lands of the middle Yellow River",
  "desc": "One or two sentences shown on the New Game screen and the Heritage panel.",
  "history": "real",             // real | legend | invented
  "source": "Where this comes from",
  "tribe_names": [...],          // optional, at least 12: replaces a random tribe's names
  "birth_names": [...],          // optional, at least 8: names for newborns
  "epithets": {"cautious": [...]},   // added to the random tribe's pools, by temperament
  "memories": {"devout": [...]},     //   (cautious, belligerent, devout, gluttonous, lazy)
  "inventions": [], "foods": [], "finds": [], "people": [], "events": [], "tales": []
}
```

Every entry has an `id` (a plain identifier, unique in the game), a `name` (or a `title`
for events), a `desc`, and optionally a `history` and a `source`. **Write the source.** It
is what lets players tell the real past from the legend.

Text rules (the same as the rest of the game): English is the translation key. A memory
starts with a past-tense verb, because it is spoken as "the day I *tamed the flood*". Keep
`%s`/`%d` out of pack texts.

## Effects

Inventions, foods, finds, boons and tales change the rules through a fixed set of stats
(`D.EFFECT_STATS` in `scripts/data.gd`):

| stat | op | meaning |
|---|---|---|
| `heal` | mul | how fast the hurt heal |
| `sick` | mul | how fast the sick recover |
| `gather` | mul | gathering speed; `of`: an activity (`chop`, `hunt`, `berry`, `quarry`, `ritual`) or a find id (`fish`, `grain`, `wild_barley`...) |
| `yield` | mul | food from structures; `of`: a structure type (`farm_plot`, `fishing_dock`, `aurochs_pen`) |
| `atk`, `def` | add | attack and defence of everyone |
| `carry` | add | load each person carries |
| `cold` | mul | how hard the cold bites (below 1 is warmer) |
| `store` | add | food the stores hold |
| `spoil` | mul | how fast food spoils (below 1 keeps longer) |
| `mood` | add | the tribe's mood |
| `lore` | add | lore per second (0.02 is a lot) |
| `hunger` | mul | how fast hunger grows |
| `build`, `work`, `speed` | mul | building, work and walking speed |
| `sight` | add | how far people see |
| `devotion` | mul | devotion from rituals |
| `steady` | add | 1: the badly hurt are not slowed |

`{"stat": "gather", "of": "fish", "mul": 1.3}` · `{"stat": "mood", "add": 3}`. A `mul` must
be in (0, 3]. Keep effects modest: base inventions give 1.2–1.4× or +2 to +5. Say in
`desc` what an effect does, in numbers. A new kind of effect needs a code hook: add the
stat to `D.EFFECT_STATS`, then call `inv.mul()`/`inv.add()` where the rule lives.

## inventions and foods

```json
{"id": "net_sinkers", "kind": "tool", "name": "Net Sinkers", "history": "real", "source": "...",
 "practice": {"hunt": 120},
 "needs": {"techs": ["pottery"], "finds": ["fish"], "inventions": ["..."], "era": 2},
 "effects": [{"stat": "gather", "of": "fish", "mul": 1.25}],
 "desc": "What it is: what it does, in numbers.",
 "hint": "Shown before it is invented: what it needs.",
 "words": ["nets"]}
```

- `kind`: `tool`, `goods` or `medicine`. Foods have no `kind`.
- `practice`: points of work, per activity, that the tribe must do once the needs are
  met: `chop`, `hunt`, `berry`, `build`, `ritual`, `quarry`, `explore`, `hearth` (nights
  by the fire), `lead`. Base inventions take 60–800.
- `needs`: techs (`fire`, `tools`, `hide`, `pottery`, `domestication`, `farming`, `bronze`,
  `totems`, `code`), finds (base or this pack's), inventions (base or this pack's), and
  the lowest era.
- `words`: words the LLM personas must not use before the invention exists.

## finds

```json
{"id": "wild_barley", "name": "Wild Barley Stands", "group": "food", "res": "food",
 "amount": 28, "rate": 0.9, "regrow": 0.08, "winter": false, "needs": "",
 "where": "meadow", "count": 4, "practice": "berry", "practice_x": 1.5,
 "look": "grain", "act": "Reaping wild barley",
 "seed": {"farming": 0.2}, "culture": {"settled": 2}, "effects": [],
 "desc": "..."}
```

- `group`: `food`, `medicine` or `ore`. `res`: what a load becomes (`food`, `wood`,
  `lore`, `stone`, `herbs`, `copper`, `tin`, `goods`).
- `rate`: work speed (berries are 1.0). `regrow`: per second (0 means it runs out).
  `winter`: still yields in winter.
- `needs`: `""`, `"lore"` (a Lore 1+ person recognises it) or `"tools"`.
- `where`: `forest`, `forest_edge`, `meadow`, `river`, `riverbank`, `hills_home`,
  `hills_far`. `count`: clusters on a standard map, 8 at most.
- `look`: which base find it is drawn as (`mushroom`, `tubers`, `grain`, `honey`, `fish`,
  `willow`, `yarrow`, `flint`, `copper`, `tin`, `ochre`, `salt`, `obsidian`).
- `seed`: insight into techs on discovery (a fraction of the cost). `culture`: culture
  drift on discovery. `gives`: resources added on discovery (`{"lore": 5}`). `effects`:
  apply while the find is known.

## people

```json
{"id": "ba", "as": "wanderer", "name": "Ba", "epithet": "Carrier of Jade", "history": "invented",
 "when": {"era": 2, "pop": 11}, "chance": 0.4,
 "text": "a traveller from the cold north-east who carries...",   // "Ba Carrier of Jade comes to the tribe: <text>"
 "stats": {"traits": ["devout"], "hp": 46, "atk": 4, "def": 2, "spd": 1.1, "color": "#7fbf9a",
           "skills": {"forage": 2, "craft": 3, "lore": 3, "trade": 4}},
 "memory": ["walked a whole summer south from the land of the jade-carvers"],
 "desc": "Who they are."}
```

`as` decides what the person does:

- **`ancestor`** (the default): is only spoken of. Listed in the Heritage panel and known
  to the personas from the start.
- **`founder`**: on a random map, leads the tribe in place of one random adult.
- **`wanderer`**: arrives and joins when `when` holds (with `chance` per day).
- **`chosen`**: one of the bloodlines offered when the Chosen One is born (up to 4). Give
  it a `label` ("Yu the Flood-Tamer") and put skills in `desc`. Without any, the base
  three (Hou Yi, Yu, Chiyou) are offered.

Traits: `cautious`, `belligerent`, `gluttonous`, `devout`, `lazy`. Skills: `forage`,
`craft`, `combat`, `lore`, `trade` (0–9). The name of anyone who can appear must not be
in the name pools (two units would share a name), and the checker enforces this.

## events

A **chronicle event** (no options) writes "Title — text" in the log and runs `do`. A
**dilemma** (2–4 options) pauses the game:

```json
{"id": "the_ditch", "title": "The Ditch Around the Village", "history": "real", "source": "...",
 "when": {"pop": 11, "day": 5}, "chance": 0.5,
 "text": "What is happening, and what the choice is.",
 "options": [
   {"label": "Dig the ditch", "desc": "optional", "cost": {"wood": 25, "food": 15},
    "do": [{"boon": [{"stat": "def", "add": 1}]}, {"culture": {"settled": 6}}],
    "result": "What came of it."},
   {"label": "Not now", "result": "..."}
 ]}
```

An option the tribe can't pay for is greyed out. Each event happens once.

## tales

```json
{"id": "houji_birth", "name": "Lord Millet Is Born", "history": "legend", "source": "Shijing, the ode Shengmin",
 "when": {"tech": "farming"}, "tell": "night",
 "text": "The tale itself, three to five sentences, told aloud by the fire.",
 "moral": "a short line the personas remember it by",
 "do": [{"boon": [{"stat": "yield", "of": "farm_plot", "mul": 1.05}]}]}
```

`tell`: `night` (one a night, by the best keeper of lore, the first one in the list whose
`when` holds), `festival` (at a festival) or `event` (only when an event's
`{"tale": id}` calls it).

## Conditions (`when`)

All conditions must hold. `time` (seconds), `day`, `pop` (living, at least), `era`, `tech`,
`invention`, `find` (known), `season` (`Spring`…`Winter`), `built` (a structure type),
`devotion`, `mood` (at least), `deaths` (at least), `food_frac` (food at least this share of the storage), `homeless` (people without a bed, at least), `village_full` (at least this share of the village's beds taken), `beds_free_below` (fewer beds to spare than this count: build ahead of the births), `can_settle` (true: a new outpost may be founded, none of ours stands half empty), `wood` (at least), `fewer` (`{"granary": 3}`: fewer of ours, building sites included; a count may grow with the tribe: `{"farm_plot": {"base": 1, "per_pop": 0.05}}` = fewer than 1 + one per 20 people), `culture` (`{"martial": 20}` at least,
`{"martial": -20}` at most), `found` (landmark id), `met` (clan id), `flag`, and the
culture's own: `told` (tale id), `joined` (person id), `happened` (event id of this pack),
`after` (something that has happened in the game: `drought`, `rain`, `blizzard`, `storm`,
`great_flood`, `spring_flood`, `eruption`, `earthquake`, `wildfire`, `lightning`,
`eclipse`, `festival`, `chosen`, `era2`, `era3`, `overpop`, or a pack event).

`chance` (on events and wanderers) is the chance per day once the conditions hold.

## Actions (`do`)

`{"log": text, "kind": "story"}` · `{"alert": text}` · `{"give": {"food": 20, "wood": -10}}`
· `{"mood": 3}` · `{"devotion": 10}` · `{"insight": {"farming": 0.2}}` (a fraction of the
tech's cost) · `{"culture": {"spiritual": 5}}` · `{"invent": id}` · `{"boon": [effects]}`
(lasting) · `{"remember": text, "who": "all" | "best:lore", "impact": 6}` · `{"feat":
text}` (an achievement) · `{"tale": id}` (tell it now) · `{"join": person id}` ·
`{"spawn": "wolf" | "tiger", "at": "village", "offsets": [[260, -180]]}` (a beast for each offset from `at`) · `{"reveal": "village", "r": 400}` ·
`{"flag": name}` · `{"newcomers": 2, "from": clan id}` (families come to live with the
tribe) · `{"lay_out": "hut", "reason": text}` (a building site where the Steward would put it).

## Drafting a pack with an LLM

The schema is strict, so an LLM can draft most of a pack and the checker catches the
mistakes. Something like:

> Write `cultures/<id>/culture.json` for the game Era of Savagery, following
> docs/CULTURES.md exactly. The culture: **<culture, place, period>**. Include 4–5
> inventions and 2 foods that the archaeology supports, 2 finds, 2 founders, 2–3
> ancestors (real burials or legendary figures), 1 wanderer, 3 Chosen One bloodlines,
> 3–4 events (at least two dilemmas) and 3–4 folk tales. Mark each entry real, legend or
> invented, and give a specific source (site, date, publication) for everything real.
> Use only the listed stats, practices, techs, conditions and actions. Keep effects
> modest. Then write zh.json translating every text.

Then run `tools/check_culture.gd` and fix what it reports. Check the facts yourself: the
`source` fields are there so that you can.
