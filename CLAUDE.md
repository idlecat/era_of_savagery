# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Godot 4.7 (GDScript only) prototype of `docs/PRD.md`: a pause-and-play tribe RTS where node-triggered LLM "Task Contracts" are negotiated once and then executed by a deterministic state machine. README.md documents gameplay systems in detail.

## Commands

```sh
GODOT=/Applications/Godot.app/Contents/MacOS/Godot
$GODOT --path .                                                   # run the game
$GODOT --headless --path . --script res://tests/test_contract.gd  # all tests (exit code 1 on failure)
ZAI_API_KEY=... $GODOT --headless --path . --script res://tests/test_llm_live.gd -- --provider=zai_coding [--lang=zh]  # live LLM smoke test (spends real calls)
$GODOT --path . --quit-after 200 2>&1 | grep "SCRIPT ERROR"       # quick compile/startup check of the full game
```

- There is no single-test runner: `tests/test_contract.gd` is a `SceneTree` script whose `_initialize()` calls `test_*()` functions in order. Comment out calls there to run a subset. The suite `preload`s main/hud/world_view only to compile-check them (headless tests never instantiate the UI).
- Screenshot / scenario harness in `scripts/main.gd` (`_debug_shot`): `$GODOT --path . -- --shot=/path.png --delay=2 --demo=sheet|negotiate|emergency|explore|evolve|winter [--who=Name] [--era=1..3] [--secs=N] [--zoom=Z] [--lang=zh] [--tech] [--ability=craft] [--research=Name] [--finish] [--night]`. Move `user://llm_settings.cfg` aside first if you don't want screenshots to spend cloud LLM calls.
- `$GODOT` user data lives in `~/Library/Application Support/Godot/app_userdata/Era of Savagery- Clan Chronicles (POC)/` (LLM settings incl. API key, `settings.cfg` language, `art_cache_v<N>/` baked sprites).

## Architecture

**No `class_name`, no autoloads.** Scripts reference each other via `const X = preload("res://scripts/x.gd")`. `entities.gd` holds the plain data classes as inner classes (`E.Unit`, `E.Predator`, `E.ResNode`, `E.Structure`, `E.Contract`).

**Layering (keep it):**
- `sim.gd` — the whole deterministic simulation, a `RefCounted` with no rendering and no LLM. Ticked at a fixed 0.05 s step from `main.gd`. Talks outward only through signals (`contract_interrupted`, `event_fired`, `contract_finished`, `log_added`, `alert_raised`) and by setting `sim.paused`. It owns sub-systems as plain objects: `contracts` (`contract_system.gd`), `evo` (`evolution.gd`: practice-based tech insight, knowledge keepers/oral loss, culture values → traditions, eras), `hz` (`hazards.gd`: seasons, weather, wolves/raids, sickness, famine). `rivals` (`rivals.gd`: rival clan villages owned `"rival:<id>"` — excluded from pop cap/fog/warmth via `sim.ours(s)` — relations, first-contact events, raids; clan people are `E.Predator` with `kind` `"hunter"`/`"warrior"` and a `clan`, so combat code is shared). Rules query these (e.g. `hz.cold_rate()`, `evo.has_trad()`), so new hardships/bonuses usually mean a query function plus a hook in `sim.gd`.
- `world_view.gd` — isometric renderer + Tier-1 RTS input. `hud.gd` — all UI (built in code, custom Theme, modals pause the sim). `llm_client.gd` — async OpenAI-compatible client. `persona_engine.gd` — static, offline stand-in that returns the same JSON shape as the LLM.

**Task Contract flow (core PRD idea):** `contracts.negotiation_ctx()` → `llm.negotiate()` (or `Persona.propose()` offline / on any failure) → `contracts.sanitize()` (LLM output is untrusted: clamp numbers, whitelist actions/structures/techs, map aliases) → `contracts.create()` → executor in `contract_system.update()` with **zero LLM calls** until an abort condition (`enemy_attack`, `hp_below_N%`, `natural_disaster` — floods and blizzards via `sim.flags["flood_active"/"disaster_t"]`) sets `sim.paused` and emits `contract_interrupted`; HUD then calls `llm.emergency()` and `contracts.resolve(c, effect)`. Contracts have `kind` `"settle"` (east-bank outpost) or `"research"` (experiments → `evo.breakthrough`). Persona prompts include memory, culture/era (`evo.world_ctx()`, with a list of words for techs not yet discovered) and season (`hz.summary()`).

**Coordinates & rendering:** sim works in flat world units (map 3600×2400, river at x≈1960 with one ford; `data.gd` has map geometry helpers). Screen = `iso(p) = ((x−y)·0.75, (x+y)·0.375)`; `uniso()` inverts it for picking. World draw order is a child-node stack: `Ground` (terrain map texture + `shaders/terrain.gdshader`; terrain *type* is encoded in the map texture's alpha) → `GroundFX` (wear paths, seasons, water fx, footprints) → decor chunks → `objects` (`y_sort_enabled`; one cached `Item` canvas item per tree/building/post/unit, positioned at its iso base so y-sort == depth; static items redraw only when their signature changes in `_sync_items/_touch`) → `Overlay` (fog of war, weather, labels). Draw helpers all use the `ci` indirection (`ci.draw_*`) so the same code paints into whichever canvas item is drawing.

**Pre-rendered 3D sprites (`art_baker.gd`):** like AoE2, models are built in code from primitive meshes and rendered once into a transparent `SubViewport` by an orthographic camera matched to the iso projection (yaw 45°, pitch 30°, 1.0607 px/unit, baked at 2×), lit by a sun + SSAO with a `shadow_to_opacity` ground catcher, materials from `shaders/bake.gdshader` (triplanar noise detail + snow). Results cache to `user://art_cache_v<ART_VERSION>` — **bump `ART_VERSION` after changing any model** or old sprites keep loading. Villagers/animals are baked in 8 directions × animation frames; villager clothing is a separate white "_cloth" layer tinted with `u.color` at draw time. `world_view._sprite(key, ...)` draws a baked sprite and returns false if absent, in which case the older procedural drawing runs — keep that fallback (headless runs bake nothing). Rendering method is Forward+ (needed for SSAO in the bake).

**Localization:** English text *is* the translation key. Wrap player-visible strings in `tr("...")` (or `I.t()` in static funcs, `I = preload("res://scripts/i18n.gd")`); Chinese lives in `scripts/lang_zh.gd` (`STRINGS` dict). `test_translations` fails if any `tr()` key lacks Chinese, and placeholders (`%s/%d`) must stay in the same order (GDScript `%` is positional). Internal ids stay English: `u.act` activity strings are compared by logic and only translated at display via `I.act()`; unit names are ids (display via `tr(u.name)`); `u.title` is `"Steward"`/`"War Chief"`. Empty translations count as missing — use `I.plural_s()` for plural suffixes. A Simplified-Chinese system font fallback is installed in `I.install_cjk_font()` (macOS "PingFang SC" resolves to the HK face, which lacks simplified glyphs).

## Gotchas

- GDScript: one-line `for x: if y: z` nesting is invalid; `:=` can't infer types from Variant/ternary-of-Variant expressions; don't name locals `tr`, `log`, or `len` (shadow built-ins); `var x: Material = ...` when a variable may hold either ShaderMaterial or StandardMaterial3D.
- Don't poll `Input.is_key_pressed()` for map controls: macOS input methods can swallow key-ups of letters typed into text boxes. `world_view` tracks pan keys only when their press reached the map (`pan_held`).
- `tests/_new_sim()` sets `hz.level = "off"` so older tests stay deterministic; hardship tests switch it on explicitly.
- LLM: Z.ai GLM Coding Plan keys only work on the `zai_coding` preset (`api.z.ai/api/coding/paas/v4`); requests to Zhipu/Z.ai send `thinking: disabled` for ~2 s responses. Keys are stored only in `user://llm_settings.cfg`, never in the repo.
