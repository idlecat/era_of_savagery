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
scripts/llm_client.gd       OpenAI-compatible client (DeepSeek / GLM / Ollama)
scripts/world_view.gd       isometric 2.5D rendering (depth-sorted) + RTS input
scripts/hud.gd              panels and modals (negotiation, emergency, events, tech, settings)
tests/test_contract.gd      headless end-to-end tests
```
