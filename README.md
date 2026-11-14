# Era of Savagery: Clan Chronicles — POC

A Godot 4 prototype of the MVP scope in [docs/PRD.md](docs/PRD.md). It uses a 2.5D isometric view (an Age-of-Empires-style diamond map), drawn procedurally with no art assets. The simulation runs in flat world coordinates, and only rendering and mouse picking are projected.

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
  - *By ability*: a table of level and the four skills. Click a column to sort by it; click it again to reverse. Hover a row to see HP, ATK, DEF and what the person is doing.
  - In both views, Shift-click adds a person to the selection or removes them.
- **Keys:** Space pauses, 1/2/3 set the speed, T opens the Wisdom Tree, C assigns a Task Contract, Esc cancels. F11 (or Cmd+Ctrl+F, or Alt+Enter) toggles fullscreen.

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
| Map: forests, berries, deer, river + ford, untamed east bank, bonfire, huts, palisades | `sim.gd`, `world_view.gd` |
| Tier 1 direct micro (select, drag-box, right-click gather/attack/build/move) | `world_view.gd` |
| Tier 2 Task Contract: LLM negotiation → JSON blueprint → deterministic executor → abort conditions → emergency awakening → resume | `contract_system.gd`, `llm_client.gd`, `hud.gd` |
| Personality-driven proposals (Panshi cautious, Alie belligerent, Linghe mystic, …) | `persona_engine.gd` (offline) / prompts in `llm_client.gd` |
| Blueprint sanitizing (clamps, whitelists, aliases, untrusted-JSON extraction) | `contract_system.gd::sanitize` |
| XP in 4 specializations, Lv5 unlocks, floating +EXP, Memory Archive (top 10 by impact) fed back into prompts | `sim.gd` |
| Tribal Wisdom Tree (9 techs, 3 eras) with real stat effects | `data.gd`, `sim.gd::research` |
| Events: Great Flood, Overpopulation (→ contract or raid), Birth of the Chosen One | `sim.gd::event_def/resolve_event` |
| Tier 3 Vice-Chieftains: Steward (policy-driven auto-assign), War Chief (needs Tribal Code) | `sim.gd::_update_vice` |
| Night cold, hunger, births, food spoilage, Yinglong guardian from the Grand Altar | `sim.gd` |

The top bar's **LLM calls** counter shows that a sealed contract runs with zero calls until an abort condition fires.

## Hardships (Challenges: Off / Normal / Harsh in LLM Settings)

- **Seasons:** each lasts 2 days. Spring has fast berries, summer spoils food faster, autumn brings the harvest and a warning. In winter there are no berries or crops, half the herds migrate, people eat 25% more and the cold can kill. You need stores, fires and Hide Tailoring.
- **Weather:** spring rain, summer drought, autumn thunderstorms (lightning splits trees), and announced winter blizzards. Blizzards slow work and travel, shrink sight, freeze anyone far from a fire, and count as a natural disaster for Task Contracts, which wakes the leader's LLM. Freezing people head to the nearest bonfire on their own, then go back to work.
- **Wild animals:**
  - Wolf packs come out at night, mostly in autumn and winter. They pick off stragglers away from fires and groups, and leave after a kill or at dawn.
  - Saber-tooths leave their dens every few days to raid the village; a raider leaves with one victim.
  - The War Chief rallies fighters against both.
- **Sickness:** a coughing fever breaks out in hard times (winter, hunger, crowding) and spreads between people close together. Fire, shrines, a nearby shaman (Lore 3+) and the discovered Hot Spring speed recovery, and survivors are immune for a while.
- **Famine:** you're warned when the stores drop below about a day's food, then again when people are starving. A meal costs 3 food and stores spoil, so you can't hoard forever.
- **Alerts:** dangers appear as AoE-style banners at the top of the screen; click one to look. Season and weather show in the top bar. LLM personas are told the season, the weather and how many days of food remain.

## Language

English and Simplified Chinese (简体中文). Switch with the **中文 / English** button in the top bar. The choice is saved, and the default follows your system language.
- Translations live in `scripts/lang_zh.gd`, keyed by the English text, and are registered with Godot's `TranslationServer`. `tr()` and auto-translated controls switch live; chronicle lines already written keep their original language.
- In Chinese mode, both the offline persona engine and cloud LLM personas speak Chinese. The LLM writes speech and option labels in Chinese while JSON keys and ids stay English. Chinese replies like 不要墙 or 大一点 are understood.
- A Simplified Chinese system font (Hiragino Sans GB / Microsoft YaHei / Noto Sans CJK SC…) is added as a fallback, because macOS's default fallback picks a face that lacks some simplified characters.
- The test suite fails if any `tr()` key has no Chinese text.

## Map & exploration

- The map is 3600×2400 world units, about 4× the original area. The home village and ford sit in the middle, with wilderness all around.
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
- **Actions:** stone tools let people quarry stone; pack oxen haul goods; torches at night.
- **Buildings:** Aurochs Pen, Bronze Smelter (bronze gear only works while one stands), Council Ring, Grand Altar (needs stone).
- **Appearance:** fur cloaks, stone or bronze blades, bronze helmets, hearth smoke.

**Eras.** The first tech of a new era starts a new age. It brings a culture-defining dilemma, in which leaders argue in character, and a new building style:
- Era 1: hide tents
- Era 2: mud-and-thatch huts
- Era 3: timber longhouses on stone footings

*Renovate* (right panel) rebuilds old homes in the new style. Foot traffic wears visible paths into the grass.

**Culture.** Four values drift with what the tribe does: Martial/Peaceful, Spiritual/Practical, Settled/Roaming and Ranked/Communal. At ±35, a value adopts a permanent **tradition** with a bonus (e.g. Ancestor Rites, Wayfinders, Shared Hearth). Culture also shapes newborns' personalities.

**LLM.** Persona prompts include the current age, culture, traditions and known wisdom, plus a list of words for undiscovered things the tribe doesn't have. A Bronze-age word won't come out of a Stone-age mouth. See *Wisdom & Culture* (T).

## POC simplifications
- Overpopulation fires at 12 people instead of PRD's 20, and the flood comes on Day 4, so both show up in a short session.
- The mid-contract ambush is scripted at ~45% progress (toggle it in LLM Settings).
- Pathfinding is waypoint-based (it routes through the ford) rather than a navmesh.

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
scripts/llm_client.gd       OpenAI-compatible client (DeepSeek / GLM / Ollama)
scripts/world_view.gd       isometric 2.5D rendering (cached y-sorted canvas items), fog of war, RTS input
scripts/hud.gd              panels and modals (negotiation, emergency, events, tech, settings)
tests/test_contract.gd      headless end-to-end tests
```
