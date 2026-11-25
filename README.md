# Era of Savagery: Clan Chronicles

A Godot 4 game built from the MVP scope in [docs/PRD.md](docs/PRD.md). It uses a 2.5D isometric view (an Age-of-Empires-style diamond map). People, animals, plants and buildings are 3D models built in code and pre-rendered to sprites, so there are no external art assets. The simulation runs in flat world coordinates, and only rendering and mouse picking are projected.

## Download

| Platform | Download |
|---|---|
| Windows (64-bit) | [EraOfSavagery-windows.zip](https://github.com/idlecat/era_of_savagery/releases/latest/download/EraOfSavagery-windows.zip) |
| macOS (Apple Silicon and Intel) | [EraOfSavagery-macos.zip](https://github.com/idlecat/era_of_savagery/releases/latest/download/EraOfSavagery-macos.zip) |

All versions are on the [Releases page](https://github.com/idlecat/era_of_savagery/releases). The game isn't signed by a paid developer account, so the first launch shows a warning. On Windows, click **More info → Run anyway**. On macOS, right-click the app and choose **Open**. The first start takes about a minute while the game builds its art; after that it starts quickly. It plays fully offline; to have the tribespeople speak through a cloud LLM, enter your own API key in **LLM Settings**.

### Building the downloads yourself

Install Godot 4.7.2 and its export templates (Editor → Manage Export Templates, or unpack `Godot_v4.7.2-stable_export_templates.tpz` into `~/Library/Application Support/Godot/export_templates/4.7.2.stable/`). Then run `tools/build.sh`. It writes `export/EraOfSavagery-windows.zip` and `export/EraOfSavagery-macos.zip` using the presets in `export_presets.cfg`. To publish a release, run `tools/release.sh vX.Y.Z` (needs `gh` logged in with write access). It sets the version, builds both zips and uploads them with `tools/release_notes.md` as the notes; run again with the same tag to replace the files.


## Run

```sh
/Applications/Godot.app/Contents/MacOS/Godot --path .          # play
/Applications/Godot.app/Contents/MacOS/Godot -e --path .       # open in editor
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tests/test_contract.gd   # tests
```

## Controls

- **Select:** left-click, or drag a box. Shift adds to the selection.
- **Command:** right-click a tree, bush or deer to gather, a tiger to attack, a construction site to build, or ground to move.
- **Pan:** WASD or the arrow keys, push the cursor against a screen edge, drag with the middle mouse button, or swipe two fingers on a trackpad.
- **Zoom:** mouse wheel, or pinch on a trackpad.
- **Explore:** select people and press X (or *Scout the unknown*) to auto-scout. Right-click recalls them.
- **Minimap** (bottom left): left-click or drag to move the view, right-click to send the selected people there.
- **Roster:** two views.
  - *By quest* (default): people are grouped under each running Task Contract (leader first), then scouts, then the village. Click a group header to select the whole group.
  - *By ability*: a table of level and the five skills (Foraging, Crafting, Combat & Leadership, Lore, Trade & Barter). Click a column to sort by it; click it again to reverse. Hover a row to see HP, ATK, DEF and what the person is doing.
  - In both views, Shift-click adds a person to the selection or removes them.
- **Hover the map:** point at a building, plant, ore, animal, landmark or the ford to see what it is and what it does (and, for huts and the burial ground, who is inside).
- **Burial Ground:** click it to see everyone laid to rest there, how and when they fell, and the deed they are remembered for.
- **Chronicle:** names of our people are links. Click one to select that person and centre the view on them (for the dead, the view goes to where they lie).
- **Keys:** Space pauses, 1/2/3 set the speed, T opens the Wisdom Tree, C assigns a Task Contract, Esc cancels. F11 (or Cmd+Ctrl+F, or Alt+Enter) toggles fullscreen.

## Design docs

[docs/ROADMAP.md](docs/ROADMAP.md) reviews where the game stands and sets what comes next; [docs/make_it_fun.md](docs/make_it_fun.md) is the fun plan and the record of what landed; [docs/city_proposal.md](docs/city_proposal.md) is the next big plan (from a tribe to cities of a thousand); [docs/CONFIG.md](docs/CONFIG.md) and [docs/CULTURES.md](docs/CULTURES.md) describe the data formats.

## LLM setup (DeepSeek / GLM)

The game runs out of the box with the **offline persona engine** (no API needed). To use a cloud LLM:

- In game: **LLM Settings** → pick *DeepSeek*, *GLM – Zhipu (CN)*, *GLM – Z.ai (intl)* or *GLM – Z.ai Coding Plan* → paste your key → *Test connection* → *Save*.
  The key is saved to Godot's user-data folder (`~/Library/Application Support/Godot/app_userdata/...`), never inside the project.
- Or use env vars: `DEEPSEEK_API_KEY`, `ZHIPU_API_KEY`, `ZAI_API_KEY`, or `LLM_API_KEY`.

Default models are `deepseek-chat`, `glm-4-flash`, `glm-4.5-flash` and `glm-5.3` (Coding Plan), and you can edit them in settings.
A **GLM Coding Plan** key (the same one Claude Code uses via `api.z.ai/api/anthropic`) only works on the *Coding Plan* preset (`api.z.ai/api/coding/paas/v4`). The general `paas/v4` endpoint answers "Insufficient balance".
On Zhipu/Z.ai endpoints the game turns GLM thinking off, so a contract call takes about 2–3 s instead of about 10 s.

Live smoke test: `ZAI_API_KEY=... godot --headless --path . --script res://tests/test_llm_live.gd -- --provider=zai_coding` Any OpenAI-compatible `/chat/completions` endpoint works, including local Ollama.
If a cloud call fails or returns invalid JSON, the game falls back to the offline persona and says so in the dialog.

## What's implemented (PRD §4 MVP)

| PRD item | Where |
|---|---|
| Map: rivers, fords and the land regions between them, routing over fords | `data.gd` |
| Everyday inventions (medicine, tools, daily goods) and the Achievements panel | `inventions.gd`, `hud.gd` |
| Culture packs: peoples described in data files (inventions, foods, finds, people, events, folk tales), the Heritage panel | `cultures/`, `cultures.gd`, `culture.gd`, [docs/CULTURES.md](docs/CULTURES.md) |
| Game modes: random maps (`mapgen.gd`), scenarios with scripted events (`scenarios/*.gd`, `story.gd`), New Game screen | `mapgen.gd`, `scenarios.gd`, `story.gd`, `new_game_ui.gd` |
| Forests, berries, deer, bonfire, huts, palisades | `sim.gd`, `world_view.gd` |
| Tier 1 direct micro (select, drag-box, right-click gather/attack/build/move) | `world_view.gd` |
| Tier 2 Task Contract: LLM negotiation → JSON blueprint → deterministic executor → abort conditions → emergency awakening → resume | `contract_system.gd`, `llm_client.gd`, `hud.gd` |
| Personality-driven proposals (Panshi cautious, Alie belligerent, Linghe mystic, …) | `persona_engine.gd` (offline) / prompts in `llm_client.gd` |
| Blueprint sanitizing (clamps, whitelists, aliases, untrusted-JSON extraction) | `contract_system.gd::sanitize` |
| XP in 5 specializations; routine work stops at Lv4, past it ranks earned by deeds (Proven Lv5-7, Master Lv8-10: a trial such as slaying a wolf, sealing a treaty or teaching a pupil; `config/ranks.json`, `ranks.gd`). Ranks open things: upgrades, renovations and bronze need a living Proven crafter, calves need a Proven forager, a war party and the War Chief a Blooded Warrior; a Master forager enlarges the pens, a lore Master keeps secrets from dying out, a Master trader's treaties last longer, floating +EXP, Memory Archive (top 10 by impact) fed back into prompts. Careers emerge as the tribe develops (`config/careers.json`, `careers.gd`): a calling grows from the work each person does, and once the tribe has the know-how (tools, the spear, pottery, a pen...) and enough people to spare, the one most drawn to a trade takes it up: Woodcutter, Hunter, Shaman, Artisan, Warrior and more; they work it faster and go to it by themselves | `sim.gd` |
| Tribal Wisdom Tree (9 techs, 3 eras) with real stat effects | `data.gd`, `sim.gd::research` |
| Events: Great Flood, Overpopulation (→ contract or raid), Birth of the Chosen One | `sim.gd::event_def/resolve_event` |
| Tier 3 Vice-Chieftains: Steward (policy-driven auto-assign, lays out improvements), War Chief (needs Tribal Code) | `sim.gd::_update_vice`, `improve.gd` |
| Night cold, hunger, births, food spoilage, Yinglong guardian from the Grand Altar | `sim.gd` |

The top bar's **LLM calls** counter shows that a sealed contract runs with zero calls until an abort condition fires.

**The odds and the field log.** Before you seal, the leader reads the odds aloud from what the tribe knows: beasts and warriors seen near the way, a found den, hostile clans, unexplored land, the season's blizzards and floods, their own wounds, and for a war, the enemy's warriors against yours (*"No one has seen that land. Anything may wait there. One time in three, trouble finds us."*). Only what the tribe has seen counts, so scouting gives better odds. The number comes from the plan's own abort conditions and is the same for every leader; their temperament only colours the words. The LLM leader is given the same numbers. During the work the leader keeps a field log in the contracts panel and now and then says it aloud: milestones, the first building raised, nightfall, weather, someone hurt or growing in skill, a landmark found, and callbacks to the forecast ("No sign of the beasts yet." / "They found us, as I feared."). Lines are in `config/contract_log.json`. Small happenings come up during the work and the leader settles them in character without pausing the game: wasps in the timber, spoiled rations, strange tracks, a white raven, a spring of clear water, and between two of the crew who can't stand each other, a quarrel (set them apart, let them fight it out, or make them carry logs together) or, between friends, a song. A cautious leader smokes out the wasps; a warrior works through the stings. A wound the leader takes in a fight you already ordered doesn't pause the game again: the leader decides by temperament whether to rest or press on, and says so.

## Graphics pipeline (pre-rendered 3D sprites)

Like Age of Empires II, objects are modelled in 3D and rendered to sprites. On first launch, `scripts/art_baker.gd` builds low-poly models in code and renders them through an orthographic camera that exactly matches the map's 2:1 isometric projection. Each render gets:
- a sun with soft shadows caught on an invisible ground plane;
- ambient occlusion;
- textured materials (`shaders/bake.gdshader`): triplanar noise for bark, thatch, hide and stone, plus snow on upward-facing surfaces.

About 500 sprites take a few seconds to bake and are cached in `user://art_cache_v<N>`. Bump `ART_VERSION` after changing a model.
- **Baked so far:** trees (pine and broadleaf, each with a snowy version), bushes, stumps, rocks; homes for all three eras in two sizes; palisade posts; bonfire, granary, smelter, council ring, totem shrine, Grand Altar, weapon rack, aurochs pen; Lookout Tower, Smokehouse, Longhouse, Temple, Stone Wall (blocks and towers) and Trading Post; cave, den, standing stones and Eagle Peak landmarks.
- **Animated in 8 directions:** villagers (idle, walk, work; clothing tinted per person) and animals (deer, tiger, wolf).
- **Terrain:** drawn by `shaders/terrain.gdshader` (grass detail, sand grain, rippling water, shoreline foam).
- **Fallback:** anything not yet baked falls back to the old drawn art, which is also used when running headless.
- **Also baked:** construction stages (staked plan, materials, frame, walls with a scaffold); animation sets (gather, build, spear attack, ritual and death for villagers; pounce and death for beasts; stone or bronze tools); ground cover and rock outcrops; seasonal crop fields, the dock, Hot Spring, bones, flint and Yinglong.
- **Lighting:** a time-of-day tint (golden dusk, blue night, pink dawn), additive fire and torch glow, and a soft vignette.
- **Colour grade:** every bake gets a light final grade in `bake.gdshader` (saturation, a filmic S-curve, warm crowns over cool depths); on screen `shaders/grade.gdshader` eases saturation and contrast with the season, the weather and the night, and the sky tint layers season and weather moods over the time of day. Baked sprites cast a soft contact shadow; trees vary a little in hue.
- **Weather and water:** wind bends tree crowns and rain, puddles come with the rain and dry after, storm flashes stutter; the river gets bank foam and low-sun glints.
- **The village grows prouder:** banner poles round the council fire from the second age, pennants and carved posts in the third; each weapon is baked with its own attack (overhead club and axe blows, a whirled sling, a drawn bow).
- **Feel:** eased panning and zoom, a camera that glides to alerts and sways uneasily in a crisis, a rotating selection ring and hover rings on what can be clicked, pulsing contract sites that need a decision, softer panels with animated dialogs, icon speech bubbles at map zoom, and achievement pictures shot like a film still (letterbox, a slow push out).

## The Council (`policy.gd`)

The **Council** button (or `P`) sets the tribe's standing policies: **Way of life** (a little of everything, foragers, hunters, tillers, herders), **The forest** (dead wood only, fell freely, burn to clear), **The hunt** (spare the mothers, hunt what comes, hunt everything), **The spirits we honour** (all, the ancestors, the sky, the beast spirits), **What to seek** (which ideas grow faster from practice) and **Stance toward clans** (peace first, wary, warlike). Each choice has trade-offs: hunters seek out deer and hunt better but face more danger, burning the forest gives wood fast but troubles the spirits and lets fires spread, a peaceful tribe is liked but its warriors grow soft. A change costs a little mood and takes a day to take hold, and the ways the tribe lives by drift its culture every day. Choosing one calls the elders to the fire: those whose personality likes or dislikes it argue for and against (in character, with an LLM node), then you decide. Every leader's persona knows the tribe's ways, and a contract leader who dislikes one that touches the task says so before proposing a plan: you can change it on the spot, or let it stand and have a sullen crew that works a little slower (they remember either way). Some ways also weigh on contracts: a war party sent out under *Peace first* troubles the tribe and the clan remembers the broken word, while a *Warlike* tribe cheers it on. All of it is data in `config/policies.json`.

## Emergency mode (`crisis.gd`)

When a beast or raider strikes one of your people, the game drops into **emergency mode**: time slows to a third, the camera jumps to the danger, the people within reach are selected, and a red bar offers orders. **Fight!** (everyone able goes for the nearest threat), **Rally to me** (gather on the strongest fighter for +3 DEF), **Torches!** (with Friction Fire, 6 wood: beasts flee; raiders don't), **To the fire** (run to the bonfire; no beast follows into its light), **Fall back** (into the huts) and **Tend the wounded**. When the danger has passed, everyone goes back to the work they left and remembers the day; **Hand back** returns control to the tribe at any time. In a contract's emergency dialog, **Take command** leads the crew this way instead of picking an option. The orders and numbers are in `config/emergency.json`.

## The director (`director.gd`)

The hardships are paced. Everything that goes wrong (a blizzard, a raid, a death) raises a tension score that eases day by day, and a new storm, raid, sickness or quake waits while the tribe is still reeling from the last ones: Normal lets about two hardships pile up, Harsh nearly twice that. A tribe in distress (out of food, losing people, in despair) gets a breath, and now and then a hand: a friendly clan sends food. Raids, tiger raids and wolf packs also wait while a sickness wave or a famine is on, so troubles don't stack into one day that erases ten (`hold_while`). The numbers are in `config/director.json`; `tools/pacing.gd` plays headless games and reports the rhythm.

## Saving

**Save / Load** in the top bar lists the save slots, the quick save (**F5** saves, **F9** loads) and the autosaves. The game autosaves at the start of every day into three rotating slots; you can switch that off in the dialog. The New Game screen has **Continue** (the newest save) and a list of all saves. A save holds the settings the world was made from and the whole simulation, so a loaded game plays on exactly as it would have. You can't save while a decision (a dilemma or an emergency) is waiting. Saves are in `user://saves/`.

## The land (`lands.gd`)

A random map is one of four kinds of land, picked from its seed or on the New Game screen: **Steppe** (open grassland, a few copses by the water, big herds, dry grass, droughts and fast fires), **Parkland** (meadows and scattered woods, the classic map), **Woodland** (large woods with meadows between them, fewer deer, more rain) or **Old forest** (deep forest with a few clearings, damp, little game). Forests gather where a hidden moisture map is wet and along the rivers, and the grass colour, berry bushes, herds, weather and wildfire all follow the land; within a kind, each map varies a little. The numbers are in `config/lands.json`.

## Fewer interruptions (`config/notices.json`)

Only what needs a decision stops the game: dilemmas, emergencies, and the rare great first (a hero, an outpost). Every other achievement, a finished Task Contract and a trader's arrival show as banners you can click (a trader leaves after a while if no one comes to trade). With a Steward appointed, routine matters such as the seasonal festival are decided by the Steward and only reported; untick *Steward decides routine matters* to be asked again. Measured on autopilot with scouts: about 4 dialogs per game day before, about one every few days now.

## Discoveries (`config/discovery.json`)

New foods, healing plants and stones are noticed by chance, not by simply walking past: a skilled forager spots new foods sooner, someone with lore knows healing plants, a crafter sees useful stones, and temperament and what a person is doing count too. Inventions break through by chance as well once their practice is done, sooner with a skilled hand. To find things on purpose, send a **search** (*Search for new finds…* on the character sheet): pick foods, healing plants or stones and ores (or let the leader choose by temperament), and the leader proposes where to look among the kinds of place such things grow, the forest, meadows, riverbanks, rocky hills, the Fire Mountain, and for how many days. The crew combs the place with much keener eyes, and reports what it found when it comes home.

## Trails and roads (`roads.gd`)

Where people walk again and again, a **trail** appears by itself (they walk 10% faster on it) and fades if no one uses it for days. Once the tribe has stone tools and enough building and walking behind it, it discovers **Road Making**, and the **Road** tool lays a **packed-earth road** (25% faster; a little wood a stretch, half over a trail): click where it begins and where it ends, and the workers build it stretch by stretch along the route, over the fords. In the Bronze Age the same tool lays **stone roads** (40% faster, stone). The Steward also makes the most trodden trails near the village into roads. The levels and numbers are in `config/roads.json`.

## Sound and music (`audio.gd`, `synth.gd`)

Every sound is made in code from a recipe in `config/audio.json`; there are no sound files. The music is drums, a bone flute that wanders over a pentatonic scale, and a drone, and it changes mood with the day, night, winter, danger and festivals. People near the camera can be heard at work (chopping, quarrying, building, fighting), wild beasts growl, and the land has wind, rain, storms, crickets at night, the crackle of bonfires and the river. Alerts, discoveries, finished buildings, dilemmas and achievements each have their cue. The **Sound** button sets the master, music, effects and ambience volumes, or mutes everything (remembered between games).

## Day and night

- **Night rest:** at nightfall everyone without a mission walks to bed and sleeps until dawn. A hut holds as many sleepers as it houses (3, or 5 for a Large Hut) and keeps them warm and hidden from wolves. The rest sleep around a bonfire, and anyone far from both camps where they stand. The job they had waits for them in the morning.
- **Who stays up:** a war party on the march, people fighting, fleeing or freezing, gravediggers, and anyone you give an order to during the night. Task Contract crews (settlers and wisdom seekers) and envoys sleep too. A peaceful contract's clock stops overnight ("Camping for the night").
- **Fast-forward:** once the whole tribe is in bed and nothing is stirring, the night passes at 12× speed (the top bar says "Night, all asleep"). Any alarm drops back to normal speed at once.
- **Alarms:** beasts or raiders at the village (within the War Chief's 500-unit range), someone being hit, or a flood rouse the camp ("Danger in the night! The camp is roused."). Fighters answer the War Chief or defend themselves. Everyone in a hut stays inside ("Sheltering in a hut"), and outdoor sleepers get up and keep watch. Nobody goes back to the day's work, and once the danger is gone they sleep on. A wolf pack prowling the woods doesn't wake the village: hut sleepers are safe from it, and someone sleeping in the open keeps watch only if a beast comes within 300 units.
- **The Steward** hands out no work during sleeping hours.
- **Stints of work:** what the Steward (or a trade) gives someone is a stint of most of a morning; then they bring their load home and are given what is needed then (a building site, a field, wood or food), so the village's work follows its needs. Your own orders last until you change them (`config/rules.json` vice.steward `shift`).
- **Worked fields:** a Farm Plot or a Fishing Dock gives a little food by itself, and much more while people work it (three hands a field, two a dock; each adds about as much as the plot alone gives). When food runs short the Steward sends idle hands to a field with a free place before the wild, and once the tribe has fields, families who keep coming back to them become **Farmers** and go there by themselves. Nothing grows in winter, so the fields stand empty then and the stores must carry the tribe (`config/structures.json` `worked`).
- **Improvements:** the Steward also lays out new buildings when the village needs them and pays for them from the stockpile, keeping some wood back: a Granary when the stores are nearly full (beside the fields), a Hut when people sleep in the open, a Bonfire if there is none, Farm Plots (more as the tribe grows), a Totem Shrine, an Aurochs Pen, and in the second age Longhouses and a Temple (as upgrades). One site at a time, in that order of priority (`config/rules.json` "improvements"). When several are wanted and an LLM node is set, the Steward's persona chooses between them (or waits) and says why in the chronicle. A checkbox under the Steward policy turns it off.

## Village life (`folk.gd`)

- **Children:** newborns are children for 3 days, and the tribe starts with two.
  - They do no work, take no orders and are never picked for a crew. They play around the camp: chasing each other round the fire, playing at hunters with stick spears, or watching a grown-up at work, which slowly teaches them that skill.
  - They're drawn smaller, eat less, sleep in the huts, and run from danger instead of fighting.
  - Then they **come of age** before the whole tribe: a chronicle line, a memory, and +1 Combat with the warrior-initiation tradition. The roster lists them under **CHILDREN**.
  - Births come while there are beds free and food in the stores: one every 45 s for a small band, faster as the tribe has more grown family lines (one more for every 16), fewer as the beds fill past four in five, half as many in winter and fewer in gloom. So growth follows the beds: the Steward builds huts, large huts and (in the second age) longhouses before the beds run out (`config/rules.json` births, beds).
  - **Unrest:** a town of a hundred and more that stays in low spirits for a day rises against its leaders: hold a feast, hear the families at the council, or stand firm (`config/rules.json` strife).
  - **Newcomers:** families of a clan allied to us or our vassal may move to us while we have beds to spare, and wanderers come out of the wild to a camp that eats well and is in good heart, asking to stay (a routine matter for the Steward, or your decision). They are grown family lines, new to the tribe's ways (`config/rules.json` migration).
- **Mood** (top bar) runs from 0 to 100, and work speed is 0.9× at 0 and 1.1× at 100.
  - It drifts toward a target: about 55, plus painted homes (up to +15), treasures (up to +15) and a recent festival (+15); minus hunger, sickness, recent deaths and panic.
  - Births, comings of age, art, trade and festivals also lift it directly. Under 25 the people grumble.
- **Arts:** idle adults (when the stores hold at least 2 food a head), and the Steward when stores are healthy, take up crafts.
  - **Carving figurines** and **stringing beads** make **goods**, a trade stock.
  - **Painting the huts** decorates a building up to three levels (zigzags, then handprints, then strings of beads), in red once ochre is known.
  - Rarely a piece becomes a named **treasure** (an Owl Figurine, a Red Hand Wall…). Treasures lift mood for good, appear in Wisdom & Culture, and are told in the saga.
- **The last stand, and the tribe that came before.** When only three are left (from day 3), the survivors ask what will become of the tribe: hold the fire and fight on, or walk to the fires of a friendly clan and live on among them. Joining ends the chronicle with its own ending and saga, not a defeat. When a chronicle ends and you begin anew, the next one remembers it: the old camp of that people stands somewhere on the map as a landmark named after its most renowned person, the elders tell of them, and if they joined a clan, that clan starts friendlier and remembers the kinship. (Kept in `user://heritage.json`.)
- **The council's challenges.** Now and then the council proposes a challenge: no one dies this winter, win a friend among the clans before the second age, found an outpost within four days, fill the stores before the frost, raise a temple before the third age. Take it up or let it pass; the one under way shows above the clans panel. Meeting it is an achievement with a reward (mood, lore, wood, devotion); failing it costs some mood. The challenges are data in `config/challenges.json`.
- **Stone Wall and Trading Post (third age).** A palisade can be rebuilt in stone (stone by the size of the ring): +6 DEF for everyone inside, towers along it, and fire can't touch it. A trading post makes the clans' traders come more often and pay a quarter more. The grand altar now needs a Master Builder in the tribe.
- **Longhouse and Temple (second age).** A large hut can be rebuilt into a longhouse: it houses 8, and those who sleep under its roof grow closer night by night (and it is a big thing to lose to a flood or a fire). A totem shrine can become a temple, with more lore and rituals near it giving twice the lore, and a temple in turn becomes the grand altar: the shrine, temple and altar are one line that grows up with the tribe.
- **Lookout Tower and Smokehouse.** A lookout tower sees far (it reveals the land around it and what it sees counts for a leader's odds) and calls out a war band or wolf pack as soon as one comes into sight; built by a ford it sees raiders long before they reach the village, but alone out there it is the first thing they find. A smokehouse (needs Friction Fire) makes stored food rot at 60% of the speed; one is enough, and it is worth most if it stands before the winter. The Steward lays one out in autumn.
- **The opening:** at the start an elder remembers a find from long ago (on The Ford, willow bark, which breaks fevers) and where it grows. Until someone finds it, it is easier to notice, and a search quest goes looking for it where the elders say it grows. On the first afternoon someone falls ill with a fever, and the elder names the old cure: send a search party for it, nurse them by the fire with broth (10 food), or keep everyone working.
- **The autumn council:** when autumn begins, the elders read two signs of the coming winter ("The geese flew south early, and low.") and the chieftain decides how to meet it: hold the Harvest Feast (a bet on a mild winter), smoke and store the meat (stored food keeps far longer: a bet on a lean winter), cut firewood and fence the camp (the cold bites less and fewer wolf packs come: a bet on a hard white or a wolf winter), slaughter the oxen for meat, or send the hunters out before the snow. The kind of winter (hard white, wolf, lean or mild) is already decided when the signs are read: the director picks it from the year (no easy repeats, gentler for a tribe in distress, harder for a well-stocked one). A white winter's blizzards and a wolf winter's packs come even when the director would otherwise hold hardships back (unless the tribe is in distress). The signs are right about three times in four, and the tribe learns which winter it was when the snow comes. Numbers and signs: `config/events.json` `winters`; the council: `config/dilemmas.json` `autumn`.
- **Festivals:** at the start of spring (Festival of Renewal) and winter (Long Night Fire) the chieftain chooses (with Challenges off, the Harvest Festival in autumn too):
  - **a great festival** (2 food a head; mood +25 and +15 for 2 days, devotion +8, more communal, births come sooner, friendly clans join in for +4 relations);
  - **a small gathering** (1 food a head);
  - **none** (mood −10).
  - During a festival everyone at the village dances in a ring around the bonfire.
- **Trade trips:** "Trade with <clan>…" sends someone with 5–10 goods, 20 food, 20 wood, 15 stone or 5 herbs to that clan's village.
  - They come back with the clan's own produce. Goods are worth 6 food each, the clan pays 1.5× for what it wants, and friendlier clans pay more (×0.85 Wary up to ×1.3 for vassals).
  - Each trip improves relations and sometimes teaches a little of their wisdom. Hostile clans won't trade, and a clan that turns hostile mid-trip robs the trader.
  - **Trade & Barter skill:** each trip gives the trader Trade & Barter XP (+12) and a little Combat & Leadership (+3); envoys who seal an agreement also gain some. Every Trade level gets +6% more in return, and a Proven trader (*Silver Tongue*: sealed an agreement with a clan) another +10%. The trader picker lists the best traders first, with what each would bring home. When a clan caravan visits, the best trader at home bargains: the offers improve the same way and that person gains XP.
  - Visiting clan traders now also offer to buy 3 goods.

## Distance and settlements

- **Kills don't keep:** a hunter goes back to a half-butchered kill after hauling a load home, but meat left out keeps only about a day, then rots away (slower in the cold). A deer taken, eaten or rotted, brings the herds back in time (`config/rules.json` gathering).
- **Distance costs:** every step burns food, half again while carrying a load (`WALK_HUNGER`): a villager walking all day gets about 70% hungrier. Loads also slow the walk home (−15%, or −5% with a pack ox). Gatherers weigh distance more heavily when choosing a tree, bush or seam.
- **Drop-off points:** loads go to the nearest of our settlements, and food also to a Granary, so building near the work pays off.
- **Settlements:** every finished settlement contract becomes a home. Its crew live there, take local jobs from the Steward, and sleep in its huts. When a settlement is crowded (four in five of its beds taken) and another has room, someone moves across (one at a time, by day), and the chronicle records it. People sleep in a bed near their own home first. No new outpost can be founded while one of ours still has three beds or more to spare: the people go there first.
- **Camp, village, town, city:** each settlement grows through tiers by its people, beds and buildings: a **village** has 20 people, 16 beds, a field and a fire; a **town** 150 people, a longhouse, a granary and a shrine in the second age; a **city** 500 people, a temple, a stone wall and a trading post in the third. The first time a settlement rises a tier it takes a name of its own (Willow Ford, Ash Hollow...) and it is an achievement; the clans' and leaders' words use the name. The top bar's tooltip lists the settlements and what each still needs (`config/rules.json` tiers).
- **Shelters:** huts, large huts, longhouses and granaries all hold sleepers up to their housing size. Whoever doesn't fit sleeps on a hide bedroll by the fire.

## The dead

- When the first person dies, the tribe lays out a **Burial Ground** at a quiet edge of the village. A free villager (idle first, else a gatherer) fetches each body, drags it home on a hide litter and buries it under a mound with a marker stone. The gravedigger remembers it, and each burial adds devotion and a little spiritual culture.
- A body more than 1500 units away is never fetched. After a day it is counted lost, and a paler name-stone is raised for them instead.
- Nobody is sent for a body while beasts are near it or at night.

## Hardships (Challenges: Off / Normal / Harsh in LLM Settings)

- **Seasons:** each lasts 2 days. Spring has fast berries, summer spoils food faster, autumn brings the harvest and a warning. In winter there are no berries or crops, half the herds migrate, people eat 25% more and the cold can kill. You need stores, fires and Hide Tailoring.
- **Weather:** spring rain and now and then a late frost that kills the young crops, summer drought and blight, autumn thunderstorms (lightning splits trees), and announced winter blizzards. Blizzards slow work and travel, shrink sight, freeze anyone far from a fire, and count as a natural disaster for Task Contracts, which wakes the leader's LLM. In winter the fires burn wood, more for a bigger tribe and more by night; if the woodpile runs out, the bonfires give no warmth until there is wood again (`config/rules.json` fuel). When a blizzard comes, those out in the open put down their work and head in to the nearest warmth, and stay there until it has passed; nobody is sent out while it rages. Freezing people head for the nearer warmth on their own (a bonfire, or their own bed under a roof), then go back to work.
- **Wild animals:**
  - Wolf packs come out at night, mostly in autumn and winter. They pick off stragglers away from fires and groups, and leave after a kill or at dawn.
  - Saber-tooths leave their dens every few days to raid the village; a raider leaves with one victim.
  - The War Chief rallies fighters against both.
- **Sickness:** a coughing fever breaks out in hard times (winter, hunger, crowding) and spreads between people close together. Fire, shrines, a nearby shaman (Lore 3+) and the discovered Hot Spring speed recovery, and survivors are immune for a while.
- **Food storage:** the village keeps 80 food, and each Granary 100 more. The top bar shows `Food 44/80`, red when over. Food over the limit rots fast (3% of the excess a second), with a daily "build a Granary" warning, and the Steward switches to wood when the stores are full. Within the limit, food above 30 still spoils slowly (Primitive Pottery and salt each halve that).
- **Famine:** you're warned when the stores drop below about a day's food, then again when people are starving. A meal costs 3 food and stores spoil, so you can't hoard forever.
- **Alerts:** dangers appear as AoE-style banners at the top of the screen; click one to look. Season and weather show in the top bar. LLM personas are told the season, the weather and how many days of food remain.

## Natural finds

Twelve kinds of finds are scattered over the map, clustered where they belong: forests, meadows, riverbanks, the shallows, and the hills on each bank. Each kind is unknown, and can't be gathered, until someone who can recognise it walks near one. Healing plants need someone with Lore 1+. Ores need Polished Stone Tools or someone with Craft. The finder gets the credit in the chronicle, plus a memory and a little insight. The Wisdom & Culture panel lists them under **Discoveries**.

| Group | Find | What it does |
|---|---|---|
| Food | Forest Mushrooms | Food. A gatherer below Lore 2 may be poisoned by a bad one, until the tribe has eaten enough to know the safe ones. |
| | Wild Tubers | Slow to dig, but they **still yield in winter**. |
| | Wild Grain | Food, and gathering it teaches Slash-and-Burn Farming twice as fast. |
| | Wild Honey | Food plus devotion. Bees sting unless Friction Fire is known. |
| | Fish Shoal | Fished from the bank: plentiful and quick to return, but iced over in winter. |
| Medicine | Willow Bark | Fills the **herbs** stock. A fevered person drinks willow-bark tea and recovers 2.5× faster. |
| | Yarrow | Uses the same herbs. The wounded heal twice as fast at the village. |
| Ore and earth | Flint | Worked by hand (no tools needed), and brings Polished Stone Tools much closer. |
| | Copper Ore, Tin Ore | Their own stocks. **Bronze can only be researched once both have been found.** A smelter only arms people while it has copper and tin, and uses one of each per day. |
| | Red Ochre | Each load becomes lore, and the tribe grows more spiritual. |
| | Salt Lick | Once found, the stores spoil half as fast. |
| | Obsidian | Appears only after the Fire Mountain erupts. Black-glass blades give +15% ATK until bronze. |

## Forces of nature (`nature.gd`; none of them happen with Challenges set to Off)

- **Lightning** strikes 1–3 times per thunderstorm.
  - Most strikes split a tree, or set it alight: a 60% chance in summer or drought, 25% otherwise.
  - Some set a building on fire, so it has to be rebuilt.
  - Rarely it hits someone in the open. A survivor is "touched by the sky" (+lore and a strong memory).
  - Before Friction Fire is known, a strike near people gives the tribe its first fire (+50% insight).
- **Wildfire** spreads from tree to tree: faster in drought, slower in rain or winter. It burns people and buildings in its path and leaves charred trunks that take a long time to regrow. Berries sprout in the ashes.
- **House fires:** a building that catches fire (lightning, wildfire, a raider's torch) can set the ones packed close beside it alight, and those the next: a tight camp is cheap to wall and quick to walk, and burns together (`config/events.json` house_fire).
- **Raids on what's outside:** once the village is walled, war bands go first for what lies outside the ring: a granary, a pen, a dock, the fields, which they put to the torch. How much the wall encloses is the choice (`config/rivals.json` raids.outside_first). The clans grow as the tribe does, war bands grow with it, and against a city of hundreds the clans that hate it band together: another sends warriors with each raid (raids.coalition).
- **River floods** (spring) start with a warning: people near the banks run for high ground. Then riverside buildings are damaged, anyone near the water is hurt, and riverside plants are washed out. Afterwards the silt gives farms near the river +40% food for 2 days, and the fish return.
- **The Fire Mountain**, a volcano in the far north-east, is also a landmark scouts can find.
  - It erupts every 9–14 days, with tremors 30 s before. Lava burns everything within about 460 units, and obsidian is left on the slopes.
  - Ash falls for most of a day: berries and farms grow at half speed, sight is 30% shorter, and coughing fever is more likely.
  - Afterwards the fields are fertile: +30% farm food for a few days.
- **Eclipse:** every 12–20 days, at midday, the sun is devoured. The chieftain chooses:
  - beat the drums (+devotion, martial);
  - offer 15 food (+devotion, spiritual);
  - let the shaman read the omen. Only Lore 3+ or Megalithic Totems calms the tribe (+20 lore); otherwise the people panic and hide in their huts until the light returns.
- **Earthquakes:** every 10–16 days, a building or two collapse, and people beside them are hurt. A rockslide bares a new stone outcrop.
- **Effects on the rest of the game:**
  - Any of these near the village wakes a sleeping camp.
  - Floods, eruptions, earthquakes and nearby wildfires count as natural disasters for Task Contracts (abort `natural_disaster`), and the leader's emergency speech names the disaster. A flood only stops a contract while some of its crew work within reach of a river (events.json flood `contract_reach`).
  - The top bar shows what is happening, e.g. *River in flood · Ashfall*, and LLM prompts receive it as `omens`.

## How people react

People drop their work when something happens around them, and go back to it afterwards:

- **A beast or raider attacks someone:** up to three able grown-ups nearby run to fight it (the bold come from farther away); children, the hurt and the sick keep away.
- **Hunting a saber-tooth:** a band sent against one (by the War Chief, by you, or by the alarm) doesn't trickle in one by one. It musters out of the beast's reach and charges together when all are there (sooner if the beast comes at them or is mauling someone), surrounds it so blows land from the flanks and hit harder, and the badly hurt step back while the others keep it busy. Those who carry a sling or a bow (see **Weapons**) keep their distance and shoot. Nobody takes one on alone unless they are a match for it: someone alone that a saber-tooth comes for runs to the others and calls for help, and one sent against it alone waits for help and backs off if none comes (`config/hunt.json`).
- **Weapons:** everyone starts with a club; the tribe invents better ones: the Fire-Hardened Spear (strikes from farther and harder), the Hafted Stone Axe (after stone tools and the spear: slow, heavy blows), the Hunting Sling and the Hunting Bow (good hunters, Foraging & Hunting 3+, shoot from afar at any foe). Each person has a knack for each weapon from birth (clumsy, fair, apt or gifted; the bold lean to clubs, spears and axes, the cautious to slings and bows) and a mastery level in each, which rises with blows, kills, hunts and sparring at a Weapon Rack, faster with a knack for it. Higher mastery hits harder, quicker and more often critically; the tribe's first master of each weapon is an achievement. People carry the weapon they are best with, or the one you name on their character sheet (**Carry:**) (`config/weapons.json`).
- **Earthquake:** everyone runs out of the huts and away from buildings and crouches in the open until the shaking stops, then sees to anyone who was hurt.
- **Hurt by lightning, a falling building or other forces of nature:** one or two neighbours come and dress the wound.
- **Wildfire near the village:** grown-ups beat out the flames (a tree put out in time is saved); children and anyone close to the fire run away from it.
- **The Fire Mountain trembles or erupts:** everyone on its slopes flees.
- **The dead** are carried across a bearer's shoulders to the burial ground.

The weather, the hardships, the forces of nature and these reactions are all data in `config/events.json` and `config/reactions.json`; a file of the same name in the game's user folder (`user://config/`) overrides any part of them. See [docs/CONFIG.md](docs/CONFIG.md).

## Rival clans

In the *River Ford* scenario six clans share the map (a random map draws its clans from a pool of ten, adding the Bear, Otter, Raven and Lynx clans). Near home are the martial **Red Ochre Clan** (east bank, behind a palisade) and the spiritual **Heron Clan** (south-west). Farther out live the martial **Tusk Clan** (north-west forests) and **Hawk Clan** (south-east hills), and the spiritual **Elk Clan** (north-east meadows) and **Willow Clan** (southern marshes). Their villages and peaceful hunters start hidden in the fog. Conquest and Unity victories need every clan.

- **First contact.** The first time you see their people or homes, the game pauses for a choice: offer gifts (20 food, +20 relations), show strength (martial clans respect it, others take it as a threat) or keep your distance.
- **Relations** run from -100 to 100 (Blood feud · Hostile · Wary · Friendly · Allied) and drift back toward each clan's temperament. They drop when you gather or scout on their hunting grounds, build near them, or attack or kill their people. Clans remember grudges.
- **Raids.** Hostile clans send war bands (bigger and more often the deeper the feud, worse in winter) to the village or a running outpost. Raiders who reach an undefended camp steal food and carry it home over the fords. Defenders, the War Chief and contract `enemy_attack` aborts all treat them like beasts. With Challenges set to Off, there are no raids or demands.
- **Envoys and parley.** Send someone as envoy (person sheet → *Send as envoy…*, or *Envoy to …* in the clans panel). They walk to the clan's village, and when they arrive a parley opens with the rival chieftain's own LLM node.
  - You offer a treaty (exchange of goods only, a peace pact, or hunting rights on their land), how many days it lasts, a daily food tribute, and what each side hands over. You can also say something in the envoy's voice.
  - The chieftain accepts, refuses or counters, in character, for up to 5 rounds, and remembers grudges and treaties.
  - The envoy matters: lore persuades everyone, martial clans respect combat skill, and the Heron welcome the devout.
  - In a blood feud, the envoy may be beaten and driven off.
  - The chieftain's reply is untrusted, just like contract blueprints. The treaty type is whitelisted, numbers are clamped, the tribe can't promise more than it has, and a deal that is far too generous for the clan is held to the deterministic engine's counter-offer.
  - The offline chieftain uses the same valuation, so it plays fine without a cloud LLM.
- **Treaties.** A peace pact stops raids and demands and halves trespass anger. Hunting rights remove trespass anger entirely. A daily tribute is paid from stores: miss one and the peace ends. Attacking or killing their people during a peace breaks it; they remember you as oath-breakers (-30 on top of the usual penalty).
- **War contracts.** Select someone and press *Lead a war party…*. It's a Task Contract like the others: the leader's LLM persona plans the raid, then the deterministic executor runs it with zero LLM calls.
  - The plan picks the enemy, an objective (*loot*: carry off food and wood; *burn*: destroy huts, so the clan shrinks; *break*: kill their warriors so they can't raid for days), crew of 2–6, an optional war dance (+15% attack) and an optional scouting step (one fewer defender comes out). The steps always run in this order: war dance (if any), scouting (if any), assault, objective, return.
  - The clan's warriors turn out as real defenders, and the fight is ordinary unit combat.
  - Abort conditions are `heavy_losses` (half the party dead or wounded) and the leader's HP threshold. Either one wakes the leader's LLM node to offer: press on, send reinforcements, or retreat.
  - Attacking their village breaks any peace with them and makes them hate you.
- **Trade caravans.** Friendly or Allied clans send a trader with a pack ox. The Red Ochre sell stone for food; the Heron sell food for wood. Each visit offers two trades, a lesson in one of their crafts, or no deal. Allied clans give better rates, and watching their traders work sometimes teaches a little.
- **Knowledge.** Each clan knows some wisdom: the Red Ochre know fire, tools, hide working and domestication; the Heron know fire, pottery and totems. At a parley you can ask them to *teach us* one thing you're ready to learn. It's a costly term, especially to the martial Red Ochre, and it brings the tech most of the way to discovery.
- **The nemesis.** One clan makes your tribe its enemy: at first contact a hostile, warlike clan takes the part, or by day 6 the worst clan you have met. Its chief swears it, it raids and demands sooner and from milder grudges than the others (who fall back but don't fall silent), and each new age makes it bolder: bigger war bands, heavier demands. Holding off its first raid is an achievement; so is ending the feud, by winning them over, making peace, taking them as vassals, or beating them at home twice. A won feud stays won. Numbers in `config/rivals.json` `nemesis`; `rivals.set_nemesis(id)` for a game master.
- **Chiefs remember.** Each clan keeps a dated ledger of what passed between you, good and bad: our attacks, broken oaths and building on their land, their raids and thefts, deals sealed, fair trades, shared feasts, gifts, demands paid or refused, calls to war answered or not. A chief brings up the weightiest memory in their dilemmas and when your envoy arrives ("Last spring, you attacked our hunter. We have not forgotten."), and older memories fade. Chiefs reign for a few weeks of game time; then a successor takes the seat with another temper (wary, proud and quick to anger, or open-handed), which shifts the clan's feelings, how hard they raid and how they bargain. The ledger is inherited: the new chief quotes the old one ("Gor told me of it before the end."). A game master reads it in `rivals.summary()` and writes in it with `rivals.note()` or the `ledger` story action; `rivals.succeed(id)` crowns a successor.
- **Alliances.** A parley can seal an *alliance*, but only with a clan that already trusts you (relation 30 or higher). Allies never raid you. They share their wisdom day by day, send warriors to fight beside your war parties (fewer defenders come out), and sometimes call you to war against their enemies: send a war party, send gifts, or refuse.
- **Vassals.** A clan beaten at home may submit. Accept for 3 food a day, demand 6 (they may rise again if they hate you enough), or spare them.
- **Endgames** (*Legacy* button): *Conquest* (every clan your vassal), *Unity* (allied with every clan, plus a Council Ring), *Wisdom* (every tech known, plus a Grand Altar), *the City* (a settlement grown into a city, a thousand people kept alive through a whole winter, and a Grand Altar). If everyone dies, you lose. At the end, the tribe's best storyteller composes the saga of your game from its people's great deeds (an LLM node, or an offline template), and you can keep playing after a victory.
- **Demands.** Before a raid, a known clan often sends a runner demanding food. Pay, and they leave you alone for a while; refuse, and the war band comes now.
- The **NEIGHBORING CLANS** panel shows each clan's stance and any war bands on the march. Personas know the clans you've met (stance, ways and grudges), in both negotiation and emergency prompts.

## Language

English and Simplified Chinese (简体中文). Switch with the **中文 / English** button in the top bar. The choice is saved, and the default follows your system language.
- Translations live in `scripts/lang_zh.gd`, keyed by the English text, and are registered with Godot's `TranslationServer`. `tr()` and auto-translated controls switch live; chronicle lines already written keep their original language.
- In Chinese mode, both the offline persona engine and cloud LLM personas speak Chinese. The LLM writes speech and option labels in Chinese while JSON keys and ids stay English. Chinese replies like 不要墙 or 大一点 are understood.
- A Simplified Chinese system font (Hiragino Sans GB / Microsoft YaHei / Noto Sans CJK SC…) is added as a fallback, because macOS's default fallback picks a face that lacks some simplified characters.
- The test suite fails if any `tr()` key has no Chinese text.

## Map & exploration

- **Two game modes** (chosen on the New Game screen; it appears again after Restart):
  - **Random map**, with nothing set in advance. Pick Small (4400×3000, up to 3 clans), Standard (6400×4400, up to 6), Large (8000×5400, up to 8) or Huge (9600×6400, up to 10), how many neighbouring clans, and a seed (the same size, clan count and seed make the same world). One to three meandering rivers (tributaries join the main one) split the land into regions; fords are added until every region can be reached. The village sits near water, the clans come from the pool of ten, landmarks are made from templates (as many as the land has room for: groves, flint, caves, standing stones, bone pits, peaks, springs, dens, perhaps a Fire Mountain), frontier settlement sites are picked near water, and the starting tribe gets random names, temperaments, skills and memories. There are no scripted events.
  - **Scenario**: a hand-made map with its own tribe, clans, landmarks, labels and scripted events. *The River Ford* (6400×4400) is the original map: one river and its ford, Panshi, Alie, Linghe and the rest, the Red Ochre and Heron clans close by and four more in the far reaches, the Great Flood foretold for Day 4 and an ambush on the first frontier camp. A scenario is a script in `scenarios/` (see `the_ford.gd`) listed in `scripts/scenarios.gd`; its triggers (`story.gd`) can test time, day, population, a contract's progress, a landmark found or a clan met, and can fire a dilemma, write to the chronicle, raise an alert, spawn beasts, give stock or reveal land.
- **Rivers and fords are general.** People and beasts route over whichever fords connect the regions between them (`D.route`); beasts keep to their own side; scouts weigh the detour. A Task Contract's settlement goes to the map's next free frontier site, wherever it is (across a river or far along the same bank), and the leader hears it described with only what the tribe has seen: "unexplored land to the east, beyond what our scouts have seen" until scouts find the river, then "untamed land across the river to the north-east, reached by a ford" once a ford is found. Timber, food, beasts and fishing are reported only for explored land, and no fishing dock is planned on water no one has seen. Floods, docks, reeds and riverbank finds follow every river.
- Fog of war works like AoE2:
  - **Black:** never seen.
  - **Dimmed:** explored. Terrain, trees and buildings are remembered, but animals and beasts are hidden.
  - **Clear:** currently in sight of people, buildings, bonfires or Yinglong.
- Nine landmarks are hidden in the fog: Painted Cave, Standing Stones, Mammoth Graveyard, Flint Outcrop, Wild Berry Grove, Eagle Peak (reveals a wide area), Hot Spring, and two Saber-tooth Dens with resident tigers.
- The first person to see a landmark earns its reward (lore, food or wood), Foraging XP and a memory, which later feeds their LLM negotiations.
- Auto-scouts walk to the nearest unexplored land. They avoid known dens and back off from beasts they can see.
- Gatherers prefer resources the tribe already knows about.
- Fog can be turned off in *LLM Settings*.

## How the world evolves

**Knowledge.** Each tech is discovered by *practice*: insight builds while people do related work.
- Felling trees and hunting lead to Polished Stone Tools.
- Nights by the fire lead to Friction Fire.
- Rituals lead to Megalithic Totems.

Landmarks seed ideas too (the Flint Outcrop inspires tools). Lore finishes an idea early; the cost is only the part not yet practiced. A **research Task Contract** (*Seek new wisdom…* on the character sheet) lets a leader's persona choose an idea and plan experiments.

Whoever contributed most becomes the **inventor** and remembers it. Knowledge lives in people:
- It spreads to those nearby, and children learn it at the fire.
- With **oral tradition** on, a tech is lost if its last keeper dies before Megalithic Totems or a Tribal Code preserve it. This can be toggled in settings.

**What each tech changes:**
- **Actions:** stone tools let people quarry stone; torches at night.
- **Hover a build button** to see the building's cost and what it does.
- **Pack oxen** (Beast Domestication):
  - **Where they live:** the herd lives in Aurochs Pens, up to 2 per pen. Finishing a pen tames the first calf, and another comes at a later dawn while there's room, at least 30 food and good care.
  - **What they do:** each ox goes with one gatherer, starting with whoever works furthest from the village, and lets them carry 15 instead of 10. The top bar shows `Oxen n/max`.
  - **Food:** each ox eats 0.03 food a second (half again in winter) and gives milk while cared for. A herd left without fodder for a day loses an ox to the pot (+20 food).
  - **Care:** care runs out in a day and a half. When it drops below 50%, a villager goes to tend them in daytime. Neglected oxen won't carry, and after a day of neglect one breaks out and is gone.
- **Buildings:** Aurochs Pen, Bronze Smelter (bronze gear only works while one stands), Council Ring, Grand Altar (needs stone).
- **Appearance:** fur cloaks, stone or bronze blades, bronze helmets, hearth smoke.

**Eras.** The first tech of a new era starts a new age. It brings a culture-defining dilemma, in which leaders argue in character, and a new building style:
- Era 1: hide tents
- Era 2: mud-and-thatch huts
- Era 3: timber longhouses on stone footings

**Click a building** to open its panel: what it does, who sleeps there, its style and any work under way, with **Renovate** (just this one), **Upgrade** (a Hut into a Large Hut, a Totem Shrine into the Grand Altar: it costs the difference and the building keeps working meanwhile) and **Demolish** (half the wood back; a building site not started gives it all back). A **Palisade** can be any size: click its middle, then click again (or drag) to set its radius; right-click goes back a step (a bigger ring costs more wood and work), and buildings standing on its line make gates in it. *Renovate* (right panel) rebuilds old homes in the new style, in the village and every settlement; each settlement's own people rebuild its homes (or the people you have selected), and the Steward sends idle hands to the old homes near where they live. Foot traffic wears visible paths into the grass.

**Culture.** Four values drift with what the tribe does: Martial/Peaceful, Spiritual/Practical, Settled/Roaming and Ranked/Communal. At ±35, a value adopts a permanent **tradition** with a bonus (e.g. Ancestor Rites, Wayfinders, Shared Hearth). Culture also shapes newborns' personalities.

**LLM.** Persona prompts include the current age, culture, traditions and known wisdom, plus a list of words for undiscovered things the tribe doesn't have. A Bronze-age word won't come out of a Stone-age mouth. See *Wisdom & Culture* (T).

## Known simplifications
- Overpopulation fires at 12 people instead of PRD's 20, so it shows up in a short session. In The River Ford scenario the Great Flood is foretold for Day 4 for the same reason.
- The River Ford scenario scripts an ambush on frontier camps at ~45% progress (toggle it in LLM Settings). Random maps have no scripted ambush.
- Pathfinding is waypoint-based (it routes over the fords between land regions) rather than a navmesh.

## Layout
```
scripts/data.gd             static data (structures, techs, traits, starting tribe)
scripts/entities.gd         Unit / Predator / ResNode / Structure / Contract
scripts/sim.gd              deterministic 20 Hz simulation (no LLM, no rendering)
scripts/contract_system.gd  task contracts: context, sanitize, executor, aborts, resolve
scripts/persona_engine.gd   offline stand-in for the LLM
scripts/evolution.gd        knowledge (practice, inventors, oral tradition), culture & traditions, eras
scripts/i18n.gd             language switching, CJK font fallback, activity text
scripts/lang_zh.gd          Simplified Chinese strings (keys = English text)
scripts/hazards.gd          seasons, weather, wolves & raids, sickness, famine, alerts
scripts/art_baker.gd        3D models -> cached isometric sprites (lighting, shadows, AO)
shaders/                    terrain, bake material, shadow catcher
scripts/llm_client.gd       OpenAI-compatible client (DeepSeek / GLM / Ollama)
scripts/world_view.gd       isometric 2.5D rendering (cached y-sorted canvas items), fog of war, RTS input
scripts/hud.gd              panels and modals (negotiation, emergency, events, tech, settings)
scripts/cultures.gd         culture packs: loading, validation, merging into the game's tables
scripts/culture.gd          the culture at play: its events, folk tales and people (sim.cult)
cultures/<id>/              culture packs (culture.json + zh.json), see docs/CULTURES.md
tools/check_culture.gd      checks culture packs (schema and Chinese text)
tests/test_contract.gd      headless end-to-end tests
```

## Everyday inventions & achievements

Beyond the Wisdom Tree, the tribe makes smaller inventions out of what it does every day. Each invention's progress grows with tribe-wide practice of particular activities, such as hunting, foraging, chopping, rites and evenings by the fire. Progress starts counting once the invention's needs are met (a technology, a find, or an earlier invention). The adult who practised most becomes the inventor, gains XP and a memory, and the tribe's mood lifts.

| Kind | Inventions |
|---|---|
| Medicine | Moss Dressings (hurt heal 40% faster), Fever Brew (needs willow; the sick recover 30% faster), Bone Setting (after Moss Dressings; the badly hurt are no longer slowed) |
| Tools | Fire-Hardened Digging Stick (+25% foraging), Bone Fishhook (needs fish; +40% fishing), Fire-Hardened Spear, Hunting Sling, Hunting Bow, Hafted Stone Axe (weapons: see above), Carrying Frame (carry 3 more), Bone Needle (needs Hide Tailoring; cold 30% weaker) |
| Daily goods | Woven Baskets (+30 food storage), Smoking Rack (needs fire; food spoils 30% slower), Salt-Cured Meat (needs salt; another 20%), Bone Flute (mood +5), Fur Bedding (needs Hide Tailoring; mood +3), Clay Lamp (needs Pottery; more lore) |

The **Achievements** button (top bar) lists the inventions made, with who and when, and a hint and progress for each one still to come. It also lists **the tribe's firsts** in order: inventions, wisdom discovered or learned, natural finds, landmarks, clans met, traditions, new ages, masterpieces and outposts. The personas know the tribe's inventions too. Each new first also pauses the game for a moment of celebration: a dialog with a picture of the place where it happened, what it means, who did it, and (for a culture's entries) whether it is history or legend and its source. Several in a row queue up; a checkbox in the dialog turns them off.

## Cultures

On the New Game screen the player picks the **culture** the tribe belongs to (or none, for the base game). A culture is a pack of data files in `cultures/<id>/`, with no code, so a new people can be added by writing one JSON file and its Chinese translation ([docs/CULTURES.md](docs/CULTURES.md) has the format and a checker). 48 ship with the game, each with founders and a name pool, inventions and foods, natural finds, ancestors, a wanderer, Chosen One bloodlines, events and folk tales, every entry marked real, legend or invented with its source:

| Region | Cultures |
|---|---|
| China | **Legends of Huaxia** (default), Yangshao, Hongshan, Liangzhu, Hemudu, Erlitou and the Xia, Sanxingdui and ancient Shu, Shang, Zhou |
| Japan and the Pacific | Jōmon, Lapita voyagers |
| Near East | Natufians, Göbekli Tepe, Çatalhöyük, Sumerians, Akkadians, Elamites, Babylonians, Assyrians, Hittites, Mitanni, Phoenicians, Urartians, Lydians, Medes, Sabaeans, Persians |
| Africa | Egyptians, Kerma, Kushites, Carthaginians, Nok |
| Europe and the Aegean | Cucuteni–Trypillia, Stone Circle Builders (Neolithic Britain), Minoans, Mycenaeans, Archaic Greeks |
| South and Central Asia, the steppe | Indus Valley, Vedic peoples, Yamnaya, Oxus oases (BMAC), Sintashta–Andronovo, Scythians |
| Americas | Caral-Supe, Olmec, Chavín, Maya, Zapotec |

A culture brings everyday inventions and **foods** (with effects such as +25% farm yield or slower hunger), **natural finds** placed on the map, **people** (the Chosen One's bloodlines, founders who lead a random tribe, wanderers who come to join, and ancestors), **events** (chronicle entries or dilemmas that pause the game) and **folk tales**, told by the best keeper of lore by the fire at night, one a night, or at festivals. Tales can leave lasting boons. The **Heritage** button lists everything the tribe has made, found, met, lived through and been told, each marked *Historical*, *Legend* or *Imagined* with its source. The personas know the tales that were told and the great people of their culture.

