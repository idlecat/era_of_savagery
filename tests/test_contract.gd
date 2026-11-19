## Headless end-to-end test of the Task Contract loop (offline persona engine).
## Run: godot --headless --path . --script res://tests/test_contract.gd
extends SceneTree

const Sim = preload("res://scripts/sim.gd")
const Persona = preload("res://scripts/persona_engine.gd")
const LLM = preload("res://scripts/llm_client.gd")
const D = preload("res://scripts/data.gd")
const MapGen = preload("res://scripts/mapgen.gd")
const Scenarios = preload("res://scripts/scenarios.gd")
const _Story = preload("res://scripts/story.gd")
const _NewGame = preload("res://scripts/new_game_ui.gd")
const E = preload("res://scripts/entities.gd")
const I18N = preload("res://scripts/i18n.gd")
const Cultures = preload("res://scripts/cultures.gd")
# Compile-check the UI scripts too (a parse error in any of them fails this test run).
const _Main = preload("res://scripts/main.gd")
const _HUD = preload("res://scripts/hud.gd")
const _World = preload("res://scripts/world_view.gd")

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond: print("  PASS ", msg)
	else:
		failures += 1
		print("  FAIL ", msg)

func _initialize() -> void:
	# Each test starts from its own fixed seed, so adding or changing one test never shifts
	# the random draws (and the outcome) of the tests after it.
	var all: Array = [test_personas, test_sanitize, test_full_contract, test_events, test_exploration, test_evolution, test_research_contract, test_translations, test_vice_slots, test_hardships, test_rivals, test_diplomacy, test_war_and_trade, test_endgames, test_night_rest, test_burials, test_night_contracts, test_herd, test_finds, test_nature, test_settling, test_folk, test_mapgen, test_water, test_inventions, test_cultures, test_flood_deer, test_dry_beds, test_feat_details, test_help_and_carry, test_reactions, test_config, test_gm_operations, test_dilemma_config, test_improvements, test_audio, test_save_load, test_renovate_settlements, test_building_panel, test_wall_radius, test_policies, test_leaders_and_the_ways, test_crisis, test_director, test_names, test_lands, test_roads, test_discovery_odds, test_routine_matters, test_life, test_spend, test_smoke]
	# --only=test_life,test_smoke (or a part of a name: --only=life) runs just those tests
	var only: Array = []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="): only = a.trim_prefix("--only=").split(",", false)
	var listed: Array = all.map(func(t): return t.get_method())
	var unlisted: Array = get_script().get_script_method_list().map(func(m): return m["name"]).filter(func(n): return n.begins_with("test_") and not n in listed)
	check(unlisted.is_empty(), "every test_* function is in the list above (missing: %s)" % ", ".join(unlisted))
	for t in all:
		if not only.is_empty() and not only.any(func(o): return o in t.get_method()): continue
		seed(42)
		t.call()
	print("\n%s (%d failures)" % ["ALL PASSED" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)

func _new_sim():
	var s = Sim.new()
	assert(s != null)
	s.hz.level = "off" # deterministic: the hardship tests switch challenges on themselves
	s.folk.festivals = false # (no festival events popping up mid-test)
	s.crisis.on = false # (no emergency mode either; test_crisis switches it on)
	s.director.on = false # (nor pacing: hardship tests roll their own; test_director switches it on)
	s.life.on = false # (nor everyday life: meals, idle acts, spirits, speech; test_life switches it on)
	s.new_game()
	return s

## A point `off` from the river on the village's side, level with the village (+dy).
func _by_river(dy: float, off: float) -> Vector2:
	var c := D.nearest_river_point(D.VILLAGE + Vector2(0, dy))
	return c + (D.VILLAGE + Vector2(0, dy) - c).normalized() * off

func test_personas() -> void:
	print("\n== Personality-driven proposals ==")
	var sim = _new_sim()
	var plans := {}
	for nm in ["Panshi", "Alie", "Linghe"]:
		var u = sim.unit_by_name(nm)
		var ctx: Dictionary = sim.contracts.negotiation_ctx(u, "Found a new settlement on the frontier", {}, false)
		var r := Persona.propose(ctx)
		var san: Dictionary = sim.contracts.sanitize(r["blueprint"], ctx["terms"], u)
		plans[nm] = san["blueprint"]
		print("\n[%s] %s" % [nm, r["speech"]])
		print("   steps: ", san["blueprint"]["steps"].map(func(s): return sim.contracts.step_text(s)))
		check(san["ok"], "%s blueprint is valid" % nm)
	var first = func(p): return p["steps"].filter(func(s): return s["action"] == "build")[0]["structure"]
	check(first.call(plans["Panshi"]) == "palisade", "cautious Panshi builds the palisade first")
	check(not plans["Alie"]["steps"].any(func(s): return s.get("structure", "") == "palisade"), "belligerent Alie skips walls")
	check(plans["Linghe"]["steps"].any(func(s): return s["action"] == "ritual"), "mystic Linghe includes a ritual")

	# Negotiation: ask the cautious builder to skip walls -> pushback, keeps palisade
	var u = sim.unit_by_name("Panshi")
	var ctx: Dictionary = sim.contracts.negotiation_ctx(u, "Found a new settlement on the frontier", {}, false, "Forget the wall, make it bigger, 10 people", plans["Panshi"])
	var r := Persona.propose(ctx)
	print("\n[Panshi revises] ", r["speech"])
	check(r["blueprint"]["capacity_target"] == 10, "revision honored capacity 10")
	check(r["blueprint"]["steps"].any(func(s): return s.get("structure", "") == "palisade"), "Panshi pushes back and keeps the palisade")

func test_sanitize() -> void:
	print("\n== Sanitizing messy LLM output ==")
	var sim = _new_sim()
	var u = sim.unit_by_name("Alie")
	var raw = LLM.extract_json("Sure! ```json\n{\"speech\":\"Hah!\",\"blueprint\":{\"plan_id\":\"War Camp!!\",\"crew_size\":99,\"capacity_target\":\"8\",\"focus\":\"glory\",\"steps\":[{\"action\":\"build\",\"structure\":\"Wooden Palisade\"},{\"action\":\"build\",\"structure\":\"castle\"},{\"action\":\"dance\"},{\"action\":\"gather_wood\",\"target_amount\":9999},{\"action\":\"build\",\"structure\":\"longhouse\",\"count\":2}],\"abort_conditions\":[\"hp_below_25%\",\"meteor\"]}}\n```")
	check(raw is Dictionary, "extracted JSON from fenced, chatty content")
	var san: Dictionary = sim.contracts.sanitize(raw["blueprint"], {}, u)
	var bp: Dictionary = san["blueprint"]
	print("   ", JSON.stringify(bp))
	print("   notes: ", san["notes"])
	check(bp["plan_id"] == "war_camp", "plan_id normalized")
	check(bp["crew_size"] <= 5, "crew clamped")
	check(bp["capacity_target"] == 8, "string number parsed")
	check(bp["focus"] == "balanced", "unknown focus replaced")
	check(bp["steps"].size() == 3, "unknown actions/structures dropped")
	check(bp["steps"][0]["structure"] == "palisade" and bp["steps"][2]["structure"] == "large_hut", "aliases mapped")
	check(bp["steps"][1]["target_amount"] == 120, "amount clamped")
	check(bp["abort_conditions"] == ["enemy_attack", "hp_below_25%"], "aborts whitelisted, enemy_attack forced")

func test_full_contract() -> void:
	print("\n== Full contract lifecycle (Panshi, offline) ==")
	var sim = _new_sim()
	var u = sim.unit_by_name("Panshi")
	var llm_calls := 1 # Phase 1 negotiation
	var ctx: Dictionary = sim.contracts.negotiation_ctx(u, "Found a new settlement on the frontier", {}, false)
	var r := Persona.propose(ctx)
	var san: Dictionary = sim.contracts.sanitize(r["blueprint"], {}, u)
	var c = sim.contracts.create(san["blueprint"], u, "Found a new settlement on the frontier")
	var interrupts := []
	sim.contract_interrupted.connect(func(cc): interrupts.append(cc.abort_reason))
	sim.event_fired.connect(func(id): pass)
	var t := 0.0
	var dt := 0.05
	var calls_during_exec := 0
	while t < 1800 and sim.contracts.is_running(c):
		if sim.paused:
			if sim.pending_event != "":
				sim.resolve_event(sim.pending_event, 0)
			elif c.status == "interrupted":
				llm_calls += 1 # Phase 4 emergency awakening
				var e := Persona.emergency(sim.contracts.emergency_ctx(c))
				print("   [t=%ds, %d%%] EMERGENCY (%s): %s" % [t, roundi(c.progress * 100), c.abort_reason, e["speech"]])
				print("      options: ", e["options"].map(func(o): return o["effect"]))
				var eff: String = "reinforce" if c.abort_reason == "enemy_attack" else e["options"][0]["effect"]
				sim.contracts.resolve(c, eff)
			sim.paused = false
		sim.tick(dt)
		t += dt
	print("   finished at t=%ds status=%s progress=%d%% interruptions=%d" % [t, c.status, roundi(c.progress * 100), c.interruptions])
	print("   contract log: ", c.events)
	check(c.status == "done", "contract completed")
	check(c.ambushed and interrupts.has("enemy_attack"), "mid-task ambush triggered an emergency awakening")
	check(llm_calls == 1 + c.interruptions, "LLM only at negotiation + interruptions (%d calls total)" % llm_calls)
	var built: int = sim.structures.filter(func(s): return s.owner == "contract:%d" % c.id and s.built).size()
	check(built >= 3, "%d outpost structures built" % built)
	print("   Panshi memory: ", u.memory.map(func(m): return m["text"]))
	check(u.memory.any(func(m): return "founding" in m["text"]), "contract archived in leader's memory")
	check(u.lv("craft") > 4 or u.skills["craft"]["xp"] > 0, "leader gained crafting XP (Lv.%d, %d xp)" % [u.lv("craft"), u.skills["craft"]["xp"]])
	check(sim.pop_cap() > 12, "pop cap increased to %d" % sim.pop_cap())

func test_events() -> void:
	print("\n== Milestone events ==")
	var sim = _new_sim()
	sim.stock["wood"] = 50
	var d: Dictionary = sim.event_def("flood")
	check(d["options"][0]["enabled"], "Ark Plan affordable")
	var r: Dictionary = sim.resolve_event("flood", 0)
	check(sim.stock["wood"] == 10, "Ark plan cost 40 wood")
	r = sim.resolve_event("chosen", 2)
	check(sim.unit_by_name("Chiyou") != null, "Chosen One spawned: " + r["text"])
	sim.stock["lore"] = 100
	check(sim.research("fire") == "", "research Friction Fire")
	check(sim.research("bronze") != "", "bronze blocked by prereqs")

func test_exploration() -> void:
	print("\n== Exploration / fog of war ==")
	var sim = _new_sim()
	sim.scripted_ambush = false
	check(sim.is_explored(D.VILLAGE) and sim.is_visible(D.VILLAGE), "village starts explored and in sight")
	check(not sim.is_explored(Vector2(D.W - 100, 100)), "far corner starts hidden")
	var start: float = sim.explored_pct()
	check(start < 15, "only the home area is known at start (%d%%)" % start)
	var u = sim.unit_by_name("Shan")
	sim.assign_explore(u)
	var lore0: float = sim.stock["lore"]
	var t := 0.0
	while t < D.DAY_LEN:
		sim.tick(0.05)
		if sim.paused:
			if sim.pending_event != "": sim.resolve_event(sim.pending_event, 2)
			sim.paused = false
		t += 0.05
	var found: Array = sim.landmarks.filter(func(l): return l["found"])
	print("   after 1 day: explored %d%%, found %s" % [sim.explored_pct(), found.map(func(l): return l["name"])])
	check(sim.explored_pct() > start + 5, "a scout pushes the map open (%d%%)" % sim.explored_pct())
	check(not found.is_empty(), "scouting discovers landmarks")
	check(sim.stock["lore"] > lore0, "discoveries pay out")
	check(u.memory.any(func(m): return "found" in m["text"]), "discovery archived in the scout's memory")
	check(u.job.get("type", "") == "explore" or u.dead or u.job.get("flee", false), "scout keeps exploring until recalled")

func _run(sim, secs: float) -> void:
	var t := 0.0
	while t < secs:
		sim.tick(0.05)
		if sim.paused:
			if sim.pending_event != "": sim.resolve_event(sim.pending_event, 0)
			for c in sim.contracts.list:
				if c.status == "interrupted": sim.contracts.resolve(c, sim.contracts.allowed_effects(c)[0])
			sim.paused = false
		t += 0.05

func test_evolution() -> void:
	print("\n== Evolution: practice, inventors, oral tradition, culture, eras ==")
	var sim = _new_sim()
	sim.scripted_ambush = false
	var evo = sim.evo
	# practice: woodcutters work out Polished Stone Tools by themselves
	for nm in ["Bai", "Shan", "Tuo", "Mo'er"]: sim.assign_gather(sim.unit_by_name(nm), "wood")
	var t := 0.0
	while t < 600 and not sim.has_tech("tools"):
		_run(sim, 1.0)
		t += 1.0
	print("   tools after %ds of chopping, inventor: %s" % [t, evo.inventors.get("tools", "-")])
	check(sim.has_tech("tools"), "chopping wood leads to Polished Stone Tools by practice")
	var inv = sim.unit_by_name(evo.inventors.get("tools", ""))
	check(inv != null and inv.memory.any(func(m): return "invented Polished Stone Tools" in m["text"]), "the inventor remembers the breakthrough")
	# stone: only quarryable with tools
	var q = sim.unit_by_name("Yan")
	sim.assign_gather(q, "stone")
	_run(sim, 60)
	print("   stone after a minute of quarrying: %d" % sim.stock["stone"])
	check(sim.stock["stone"] > 0, "stone tools open up quarrying")
	# lore cost shrinks with practice
	check(evo.lore_cost("hide") <= 20, "practice makes teaching cheaper (hide: %d lore)" % evo.lore_cost("hide"))
	# oral tradition: kill everyone who knows a tech
	sim.stock["lore"] = 500
	check(sim.research("hide") == "", "teach Hide Tailoring with lore")
	for u in evo.keepers("hide"): sim.kill_unit(u, null)
	check(not sim.has_tech("hide"), "oral tradition: Hide Tailoring died with its last keeper")
	check(evo.insight_frac("hide") > 0.3, "...but is half-remembered (%d%%)" % roundi(evo.insight_frac("hide") * 100))

	# culture -> tradition
	var sim2 = _new_sim()
	for i in 5: sim2.evo.drift("spiritual", 8.0)
	sim2.evo.update(2.1)
	check(sim2.evo.has_trad("ancestor_rites"), "a spiritual tribe adopts Ancestor Rites")
	check("spiritual" in sim2.evo.culture_summary(), "culture summary: %s" % sim2.evo.culture_summary())
	# era transition + dilemma + renovation
	sim2.stock["lore"] = 500
	sim2.stock["wood"] = 300
	sim2.research("fire")
	sim2.research("pottery")
	check(sim2.evo.era == 2, "first Era-2 tech starts the Tribe & Agrarian Era")
	sim2.check_events()
	check(sim2.pending_event == "era2", "the new age opens a culture-defining dilemma")
	var d: Dictionary = sim2.event_def("era2")
	print("   ", d["text"])
	var settled0: float = sim2.evo.culture["settled"]
	sim2.resolve_event("era2", 0)
	check(sim2.evo.culture["settled"] > settled0, "'Put down roots' settles the tribe")
	var old: Array = sim2.outdated()
	check(old.size() >= 4, "old hide tents are now outdated (%d)" % old.size())
	check(sim2.renovate([]) == "", "renovation starts")
	_run(sim2, 120)
	check(sim2.structures.filter(func(s): return s.type == "hut" and s.style == 2).size() >= 2, "huts rebuilt in mud & thatch")
	var ctx: Dictionary = sim2.contracts.negotiation_ctx(sim2.unit_by_name("Alie"), "x", {}, false)
	check("bronze" in ctx["world"]["unknown_things_you_have_no_words_for"], "personas have no words for bronze yet")
	check(ctx["world"]["age"] == D.ERA_NAMES[2], "personas know which age they live in")

func test_research_contract() -> void:
	print("\n== Research contract (offline persona) ==")
	var sim = _new_sim()
	sim.scripted_ambush = false
	var u = sim.unit_by_name("Linghe")
	var ctx: Dictionary = sim.contracts.negotiation_ctx(u, "Find new wisdom", {"kind": "research"}, false, "", {}, [], "research")
	var r := Persona.propose(ctx)
	print("   [Linghe] ", r["speech"])
	var san: Dictionary = sim.contracts.sanitize(r["blueprint"], {"kind": "research"}, u)
	check(san["ok"] and san["blueprint"]["tech"] == "fire", "mystic Linghe seeks Friction Fire")
	var bad: Dictionary = sim.contracts.sanitize({"kind": "research", "tech": "bronze", "steps": [{"action": "build", "structure": "hut"}]}, {"kind": "research"}, u)
	check(bad["ok"] and bad["blueprint"]["tech"] != "bronze" and bad["blueprint"]["steps"].any(func(s): return s["action"] == "experiment"), "out-of-reach idea replaced, experiment step enforced")
	var c = sim.contracts.create(san["blueprint"], u, "Find new wisdom")
	var t := 0.0
	while sim.contracts.is_running(c) and t < 400:
		_run(sim, 1.0)
		t += 1.0
	print("   finished at t=%ds status=%s, log: %s" % [t, c.status, c.events.slice(0, 3)])
	check(c.status == "done" and sim.has_tech("fire"), "research contract discovers Friction Fire")
	check(sim.evo.inventors.get("fire", "") == "Linghe", "the leader is credited as inventor")

## Every tr("...") / I.t("...") key used in the code must have a Chinese translation.
func test_translations() -> void:
	print("\n== Chinese translation coverage ==")
	var ZH = load("res://scripts/lang_zh.gd")
	var re := RegEx.create_from_string("(?:\\btr|I\\.t)\\(\\s*\"((?:[^\"\\\\\\n]|\\\\.)*)\"")
	var letters := RegEx.create_from_string("[A-Za-z]{2}")
	var markup := RegEx.create_from_string("\\[/?[a-z_]+(=[^\\]]*)?\\]|%[-+0-9.]*[dsf]")
	var missing: Array = []
	for f in ["sim", "contract_system", "evolution", "hazards", "nature", "folk", "rivals", "legacy", "hud", "world_view", "persona_engine", "llm_client", "new_game_ui", "story", "mapgen", "culture", "cultures", "inventions", "life"]:
		var src := FileAccess.get_file_as_string("res://scripts/%s.gd" % f)
		for m in re.search_all(src):
			var k := m.get_string(1).c_unescape()
			if letters.search(markup.sub(k, "", true)) == null: continue
			if not ZH.STRINGS.has(k) and k not in missing: missing.append(k)
	# map data shown to the player: landmark templates, the random tribe's pools, scenarios
	var data_keys: Array = ["east", "west", "north", "south", "north-east", "north-west", "south-east", "south-west",
		"The tribe gathers around the bonfire, in a land no one has walked before."]
	for k in D.LANDMARK_KINDS: data_keys += D.LANDMARK_KINDS[k]["names"] + D.LANDMARK_KINDS[k]["texts"]
	for k in D.BASE_TEMPERAMENTS: data_keys += D.BASE_TEMPERAMENTS[k]["epithets"] + D.BASE_TEMPERAMENTS[k]["memories"]
	data_keys += D.BASE_TRIBE_NAMES + D.BASE_BIRTH_NAMES
	for h in D.BASE_CHOSEN: data_keys += [h["name"], h["epithet"], h["label"], h["desc"]]
	# culture packs carry their own Chinese (zh.json)
	for id in Cultures.ids():
		for k in Cultures.missing_zh(Cultures.by_id(id)): missing.append("[%s] %s" % [id, k])
	for cfg in ["events", "reactions", "dilemmas", "rivals", "rules", "legacy", "policies", "emergency", "director", "lands", "roads", "discovery", "life"]: # the rule configs' texts
		for k in preload("res://scripts/config.gd").texts(preload("res://scripts/config.gd").load_cfg(cfg)):
			if not ZH.STRINGS.has(k) or ZH.STRINGS[k] == "": missing.append("[config/%s] %s" % [cfg, k])
			elif ZH.STRINGS[k].count("%") != k.count("%"): missing.append("[config/%s] placeholders: %s" % [cfg, k])
	for s in Scenarios.LIST:
		var sp: Dictionary = s.spec()
		data_keys += [s.INFO["name"], s.INFO["desc"], s.INFO["brief"]] + s.INFO["intro"]
		for lm in sp["landmarks"]: data_keys += [lm["name"], lm["text"]]
		for c in sp["tribe"]: data_keys += [c["name"], c["epithet"]] + c["memory"].map(func(m): return m["text"])
		for lb in sp["labels"]: data_keys.append(lb["text"])
		for tg in sp["script"]:
			for act in tg["do"]:
				if act.has("log"): data_keys.append(act["log"])
				if act.has("alert"): data_keys.append(act["alert"])
	for k in data_keys:
		if k != "" and not ZH.STRINGS.has(k) and k not in missing: missing.append(k)
	for k in missing: print("   missing: ", k)
	check(missing.is_empty(), "all %d-ish UI/game strings have Chinese text (%d missing)" % [ZH.STRINGS.size(), missing.size()])
	I18N.setup("zh")
	check(I18N.t("Wooden Palisade") == "木栅栏", "TranslationServer switches to Chinese")
	check(I18N.act("Building Hut") == "建造小屋", "activity strings translate for display")
	var sim = _new_sim()
	var u = sim.unit_by_name("Panshi")
	var ctx: Dictionary = sim.contracts.negotiation_ctx(u, "x", {}, false)
	var r := Persona.propose(ctx)
	print("   [盘石] ", r["speech"])
	check(r["speech"].contains("栅栏") and not r["speech"].contains("palisade"), "offline persona speaks Chinese")
	var ctx2: Dictionary = sim.contracts.negotiation_ctx(u, "x", {}, false, "不要墙，大一点", r["blueprint"])
	var r2 := Persona.propose(ctx2)
	print("   [盘石 回应] ", r2["speech"])
	check(r2["blueprint"]["capacity_target"] > r["blueprint"]["capacity_target"], "Chinese reply '大一点' is understood")
	I18N.setup("en")

func test_vice_slots() -> void:
	print("\n== Vice-Chieftain slots ==")
	var sim = _new_sim()
	var a = sim.unit_by_name("Alie")
	var p = sim.unit_by_name("Panshi")
	check(sim.appoint_block(a, "warchief") == "", "with one free slot, a War Chief can be appointed (no Tribal Code needed)")
	check(sim.appoint(a, "warchief"), "Alie becomes War Chief")
	check(sim.appoint_block(p, "steward") == "no_slot", "the single slot is now taken")
	check(sim.appoint_block(a, "steward") == "", "Alie can switch roles (her own slot is freed)")
	sim.stock["lore"] = 500
	for id in ["fire", "farming", "tools", "pottery", "domestication"]: sim.research(id)
	sim.research("code")
	check(sim.appoint(p, "steward"), "Tribal Code adds a second slot: Panshi becomes Steward")
	var b = sim.unit_by_name("Bai")
	check(sim.appoint(b, "steward") and b.title == "Steward" and p.title == "", "a new Steward takes over: the old one steps down (no two Stewards)")
	check(sim.dismiss("warchief") and a.title == "" and sim.vice["warchief"] == -1 and sim.appoint_block(p, "warchief") == "", "an office holder can be relieved, freeing the slot")
	sim.evo.traditions["council_of_elders"] = 1 # (with Tribal Code too)
	check(sim.vice_slots() <= 2, "never more slots than the two offices (%d)" % sim.vice_slots())
	# with little stone in store, the Steward sends some quarrying, whatever the policy
	var q = _new_sim()
	q.techs["tools"] = true
	q.stock["food"] = 200
	q.stock["stone"] = 0
	q.steward_policy = "wood"
	q.appoint(q.unit_by_name("Panshi"), "steward")
	q.time = D.DAY_LEN * 0.2
	for k in 6:
		for o in q.living():
			if o.role == "" and o.title == "": q.set_job(o, {})
		q.vice_timer = 0.0
		q._update_vice(0.1)
	check(q.living().any(func(o): return o.job.get("res", "") == "stone"), "with no stone in store, the Steward sends someone quarrying (even on the wood policy)")
	# buildings can't be placed on top of each other
	sim.stock["wood"] = 200
	check(sim.can_place("hut", D.VILLAGE) == "Too close to another building" and sim.can_place("hut", D.VILLAGE + Vector2(200, 150)) == "", "a new building may not overlap another")
	# the War Chief keeps a few on a beast at the village: the best fighters nearby, not everyone
	var w = _new_sim()
	w.time = D.DAY_LEN * 0.2
	w.appoint(w.unit_by_name("Alie"), "warchief")
	var far = w.unit_by_name("Bai")
	far.pos = D.VILLAGE + Vector2(-1800, 0)
	w.set_job(far, {})
	var beast = w.spawn_predator(D.VILLAGE + Vector2(250, 0), D.VILLAGE)
	beast.max_hp = 5000
	beast.hp = 5000
	for k in 4:
		w.vice_timer = 0.0
		w._update_vice(0.05)
	var att: Array = w.living().filter(func(u): return u.job.get("type", "") == "attack")
	check(att.size() == int(w.RULES["vice"]["fighters"]) and not far in att, "the War Chief keeps %d on the beast and calls no one from afar (%d)" % [int(w.RULES["vice"]["fighters"]), att.size()])
	# with everyday life on, people busy with an idle act still count as idle hands for the Steward
	var s2 = _new_sim()
	s2.life.on = true
	var st = s2.unit_by_name("Panshi")
	s2.appoint(st, "steward")
	var y = s2.unit_by_name("Yan")
	y.pos = D.VILLAGE + Vector2(40, 40)
	s2.set_job(y, {"type": "life", "act": "stroll", "t": 0.0, "time": 99.0, "phase": 0, "to": y.pos})
	s2.time = D.DAY_LEN * 0.2
	s2.vice_timer = 0.0
	s2._update_vice(0.1)
	check(y.job.get("type", "") != "life", "the Steward puts people at their idle pastimes to work (%s)" % y.job.get("type", ""))


func test_hardships() -> void:
	print("\n== Hardships: seasons, weather, wolves, sickness, famine ==")
	var sim = _new_sim()
	sim.hz.level = "normal"
	sim.scripted_ambush = false
	var alerts: Array = []
	sim.alert_raised.connect(func(a): alerts.append(a["text"]))
	check(sim.hz.season() == "Spring" and sim.hz.year() == 1, "the game starts in spring of Year 1")
	sim.tick(0.05)
	sim.time = D.DAY_LEN * 6 + 1.0 # first day of winter
	sim.tick(0.05)
	check(sim.hz.season() == "Winter", "Day 7 is winter")
	check(alerts.any(func(t): return "Winter has come" in t), "winter is announced")
	check(sim.hz.berry_mult() == 0.0 and sim.hz.food_mult("farm_plot") == 0.0, "no berries or harvest in winter")
	var u = sim.unit_by_name("Shan")
	u.pos = D.VILLAGE + Vector2(-700, 300) # far from any fire
	sim.night_amt = 1.0
	check(sim.hz.cold_rate(u, false) > 0.5 and sim.hz.cold_can_kill(), "a winter night away from the fire can kill")
	sim.techs["hide"] = true
	check(sim.hz.cold_rate(u, false) < 0.5, "fur cloaks (Hide Tailoring) cut the cold")
	check(sim.hz.cold_rate(u, true) == 0.0, "a fire keeps everyone warm")
	# blizzard -> natural disaster for contracts
	sim.hz.start_weather("blizzard")
	check(sim.hz.speed_mult() < 1.0 and sim.hz.sight_mult() < 1.0, "blizzards slow and blind")
	check(sim.flags.get("disaster_t", -1.0) == sim.time, "a blizzard counts as a natural disaster")
	# wolves
	var before: int = sim.predators.size()
	sim.hz.spawn_wolf_pack()
	var wolves: Array = sim.predators.filter(func(p): return p.kind == "wolf")
	check(wolves.size() >= 2 and sim.predators.size() > before, "a wolf pack of %d spawns" % wolves.size())
	check(alerts.any(func(t): return "Wolves howl" in t), "the pack is announced with an alert")
	# sickness spreads and heals
	var sim2 = _new_sim()
	sim2.hz.level = "normal"
	var a = sim2.unit_by_name("Alie")
	a.sick = 1.0
	var t := 0.0
	var spread := false
	var b2 = sim2.unit_by_name("Tuo")
	b2.pos = a.pos + Vector2(18, 0)
	for k in 200: # each 2 s check is a small chance; give it plenty of contact
		a.sick = 1.0
		sim2.hz.spread_t = 0.0
		sim2.hz._sickness(0.05)
		if b2.sick > 0:
			spread = true
			break
	b2.sick = 0.0
	while t < 120.0: # and the fever runs its course
		sim2.tick(0.05)
		if sim2.paused:
			sim2.pending_event = ""
			sim2.paused = false
		t += 0.05
	check(spread, "sickness spreads between people living close together")
	check(a.sick == 0.0 and a.immune_t > sim2.time, "the sick recover and are immune for a while")
	# famine warning
	var sim3 = _new_sim()
	sim3.hz.level = "normal"
	var msgs: Array = []
	sim3.alert_raised.connect(func(al): msgs.append(al["text"]))
	sim3.stock["food"] = 3
	sim3.hz._famine(11.0)
	check(msgs.any(func(m2): return "running low" in m2), "low food stores raise a warning")

func test_rivals() -> void:
	print("\n== Rival clans ==")
	var sim = _new_sim()
	var ours_cap := 0
	for st in sim.structures:
		if st.owner == "village" and st.built: ours_cap += int(D.STRUCTURES[st.type].get("cap", 0))
	check(sim.structures.any(func(st): return st.owner == "rival:ochre") and sim.structures.any(func(st): return st.owner == "rival:heron"), "both rival villages stand on the map")
	check(sim.pop_cap() == ours_cap, "rival huts don't house our people (cap %d)" % sim.pop_cap())
	check(not sim.is_explored(D.RIVALS[0]["pos"]), "rival villages start hidden in the fog")
	var hunters: Array = sim.predators.filter(func(p): return p.kind == "hunter")
	check(hunters.size() == 2 * D.RIVALS.size(), "each clan sends out two peaceful hunters")
	# hunters leave villagers alone
	var u = sim.unit_by_name("Tuo")
	var h = hunters.filter(func(p): return p.clan == "heron")[0]
	sim.set_job(u, {})
	u.pos = h.pos + Vector2(12, 0)
	for i in 100: sim.tick(0.05)
	check(u.hp == u.max_hp, "a hunter beside a villager does not attack")
	check(sim.active_predators_near(h.pos, 200).filter(func(p): return p.kind == "hunter").is_empty(), "hunters don't count as threats")
	# Yinglong leaves peaceful clan hunters alone
	sim.guardian = E.Guardian.new()
	sim.guardian.pos = h.pos + Vector2(20, 0)
	var h_hp: float = h.hp
	for i in 40: sim._update_guardian(0.05)
	check(h.hp == h_hp and not h.dead, "the guardian dragon does not hunt peaceful clan hunters")
	sim.guardian = null
	check(sim.rivals.clans["heron"]["met"] and sim.pending_event == "contact_heron", "meeting their hunter is first contact too")
	var keep: Dictionary = sim.resolve_event("contact_heron", 2)
	check(keep["text"] != "" and sim.pending_event == "", "keeping our distance resolves the meeting")
	sim.paused = false
	# first contact
	var ochre: Dictionary = sim.rivals.clans["ochre"]
	sim.reveal(ochre["pos"], 200)
	sim.rivals.update(0.05)
	check(ochre["met"] and "contact_ochre" in sim.rivals.pending, "seeing their village makes first contact")
	sim.check_events()
	check(sim.pending_event == "contact_ochre" and sim.paused, "first contact pauses for a choice")
	var d: Dictionary = sim.event_def("contact_ochre")
	check(d["options"].size() == 3, "three ways to greet them")
	var rel0: float = ochre["relation"]
	var food0: float = sim.stock["food"]
	var r: Dictionary = sim.resolve_event("contact_ochre", 0)
	print("   ", r["text"])
	check(ochre["relation"] > rel0 + 15 and sim.stock["food"] == food0 - 20, "gifts cost food and win favour")
	check(sim.rivals.summary().size() == 2 and sim.contracts.env_data(D.SITES[0])["neighbors"].size() == 2 and sim.evo.world_ctx()["neighbors"].size() == 2, "met clans enter the personas' context")
	# killing a hunter angers the clan
	var rel1: float = ochre["relation"]
	var oh = sim.predators.filter(func(p): return p.clan == "ochre" and p.kind == "hunter")[0]
	sim.damage_pred(oh, 999, u, false)
	check(ochre["relation"] < rel1 - 25 and not ochre["grudges"].is_empty(), "killing their hunter brings a grudge")
	check(not sim.nodes.any(func(n): return n.kind == "carcass" and n.pos == oh.pos), "slain people leave no carcass")
	# raids
	sim.hz.level = "normal"
	ochre["relation"] = -60.0
	ochre["warriors"] = 4
	ochre["raid_t"] = 0.0
	ochre["last_demand"] = sim.time # (no messenger this time)
	sim.rivals.update(0.05)
	var band: Array = sim.predators.filter(func(p): return p.kind == "warrior" and p.clan == "ochre")
	check(band.size() >= 2 and band.all(func(p): return p.raid), "a hostile clan sends a war band of %d" % band.size())
	check(sim.active_predators_near(band[0].pos, 100).size() >= 1, "raiders are threats")
	for o in sim.living(): o.pos = D.VILLAGE + Vector2(-900, 600) # nobody home
	var w = band[0]
	w.pos = D.VILLAGE + Vector2(5, 5)
	w.goal = D.VILLAGE
	w.path = []
	sim.stock["food"] = 50.0
	for i in 20: sim.update_predator(w, 0.05)
	check(sim.stock["food"] < 50.0 and w.loot and w.fleeing, "raiders in an empty camp steal food and run")
	var steps := 0
	while not w.fled and steps < 4000:
		sim.update_predator(w, 0.05)
		steps += 1
	check(w.fled and w.pos.distance_to(ochre["pos"]) < 40, "the raider carries the loot home over the ford")
	# peaceful setting: no raids
	var sim2 = _new_sim()
	sim2.rivals.clans["ochre"]["relation"] = -80.0
	sim2.rivals.clans["ochre"]["raid_t"] = 0.0
	sim2.rivals.update(0.05)
	check(not sim2.predators.any(func(p): return p.kind == "warrior"), "with hardships off, neighbours never raid")

func test_diplomacy() -> void:
	print("\n== Diplomacy: envoys, parley, treaties ==")
	var sim = _new_sim()
	var R = sim.rivals
	for id in ["ochre", "heron"]: R.clans[id]["met"] = true
	var heron: Dictionary = R.clans["heron"]
	var u = sim.unit_by_name("Linghe")
	var arrived := []
	sim.envoy_arrived.connect(func(who, cid): arrived.append([who, cid]))
	check(R.send_envoy(u, "heron") == "" and u.role == "envoy", "an envoy sets out")
	check(R.envoy_block(sim.unit_by_name("Bai"), "heron") != "", "one envoy per clan at a time")
	check(not sim.contracts.available_helpers().has(u), "envoys can't be drafted into contracts")
	var t := 0.0
	while arrived.is_empty() and t < 240.0:
		sim.tick(0.05)
		if sim.paused and arrived.is_empty():
			sim.pending_event = ""
			sim.paused = false
		t += 0.05
	check(not arrived.is_empty() and arrived[0][1] == "heron" and sim.paused, "the envoy reaches their village and the parley begins (%.0fs)" % t)
	check(u.pos.distance_to(heron["pos"]) < 160, "the envoy stands at their village")
	# an offer of bare peace is not enough: the chief counters
	var offer: Dictionary = R.empty_terms()
	offer["treaty"] = "peace"
	var ctx: Dictionary = R.parley_ctx(u, "heron", offer, "Let our peoples live in peace.", [], 0)
	check(ctx["chief"]["name"] != "" and ctx["inclination"] != "", "the chief's node gets mood, grudges and the offer")
	var rep: Dictionary = R.chief_reply(ctx, u)
	print("   [Ama] ", rep["speech"])
	check(rep["verdict"] == "counter" and rep["terms"]["tribe_gives"]["food"] > 0, "the offline chief counters, asking for food")
	check(R.deal_value("heron", rep["terms"], u, 0) >= 0, "the counter-offer is one the clan would accept")
	# untrusted LLM terms
	var junk: Dictionary = R.sanitize_terms({"treaty": "Eternal Alliance", "days": 999, "tribute": "50", "tribe_gives": {"food": 9999, "gold": 5}, "clan_gives": {"wood": -4}}, offer)
	check(junk["treaty"] == "none" and junk["days"] == 40 and junk["tribe_gives"]["food"] <= int(sim.stock["food"]) and junk["clan_gives"]["wood"] == 0 and not junk["tribe_gives"].has("gold"), "LLM terms are whitelisted and clamped")
	var greedy: Dictionary = R.empty_terms()
	greedy["treaty"] = "peace"
	greedy["clan_gives"]["food"] = 60
	var held: Dictionary = R.check_reply("heron", {"verdict": "accept", "speech": "Yes, all of it!", "terms": greedy}, greedy, u, 0, R.chief_reply(R.parley_ctx(u, "heron", greedy, "", [], 0), u))
	check(held["verdict"] != "accept", "an LLM chief can't give the clan away (%s)" % held["verdict"])
	# seal the counter-offer
	var food0: float = sim.stock["food"]
	var rel0: float = heron["relation"]
	var what: String = R.seal(u, "heron", rep["terms"], 1)
	print("   sealed: ", what)
	check(R.has_treaty("heron", "peace") and heron["relation"] > rel0, "peace is sealed and the Heron warm to us")
	check(sim.stock["food"] < food0, "the agreed food changes hands")
	check(u.memory.any(func(m): return "sealed an agreement" in m["text"]), "the envoy remembers the treaty")
	R.end_parley(u, "heron")
	check(u.role == "" and u.job.get("type", "") == "move", "after the parley the envoy walks home")
	# peace stops raids
	sim.hz.level = "normal"
	heron["relation"] = -60.0
	heron["raid_t"] = 0.0
	heron["warriors"] = 4
	R.update(0.05)
	check(not sim.predators.any(func(p): return p.clan == "heron" and p.kind == "warrior"), "no raids while the peace holds")
	# breaking the peace
	var hh = sim.predators.filter(func(p): return p.clan == "heron" and p.kind == "hunter")[0]
	heron["relation"] = 0.0
	var rel1: float = heron["relation"]
	sim.damage_pred(hh, 999, sim.unit_by_name("Alie"), false)
	check(not R.has_treaty("heron", "peace") and heron["relation"] <= rel1 - 55 and heron["grudges"].any(func(g): return "broke the peace" in g), "killing their people breaks the peace")
	# tribute
	var ochre: Dictionary = R.clans["ochre"]
	var trib: Dictionary = R.empty_terms()
	trib["treaty"] = "peace"
	trib["tribute"] = 3
	R.seal(sim.unit_by_name("Alie"), "ochre", trib, 0)
	sim.stock["food"] = 40.0
	sim.time += D.DAY_LEN
	R.update(0.05)
	check(absf(sim.stock["food"] - 37.0) < 0.01, "tribute is paid each day (%.1f food left)" % sim.stock["food"])
	sim.stock["food"] = 1.0
	sim.time += D.DAY_LEN
	R.update(0.05)
	check(not R.has_treaty("ochre", "peace"), "an unpaid tribute ends the peace")
	# demands
	ochre["demand"] = 20
	sim.stock["food"] = 50.0
	var d: Dictionary = sim.event_def("demand_ochre")
	check(d["options"].size() == 2 and "20" in d["text"], "a messenger demands food")
	sim.resolve_event("demand_ochre", 0)
	check(sim.stock["food"] == 30.0 and ochre["raid_t"] > D.DAY_LEN, "paying buys time")
	ochre["warriors"] = 4
	ochre["relation"] = -40.0
	sim.resolve_event("demand_ochre", 1)
	check(sim.predators.any(func(p): return p.clan == "ochre" and p.kind == "warrior" and p.raid), "refusing brings the war band")
	# peace expires
	var hr: Dictionary = R.empty_terms()
	hr["treaty"] = "hunting_rights"
	hr["days"] = 5
	R.seal(u, "ochre", hr, 0)
	check(R.has_treaty("ochre", "hunting_rights") and R.treaty_text("ochre") != "", "hunting rights are granted")
	sim.time += D.DAY_LEN * 6
	R.update(0.05)
	check(not R.has_treaty("ochre", "hunting_rights"), "treaties expire")

func test_war_and_trade() -> void:
	print("\n== War contracts, trade caravans, knowledge ==")
	var sim = _new_sim()
	var R = sim.rivals
	for id in ["ochre", "heron"]: R.clans[id]["met"] = true
	R.pending.clear()
	var u = sim.unit_by_name("Alie")
	var terms := {"kind": "war", "target": "heron", "objective": "loot", "crew_size": 5}
	var ctx: Dictionary = sim.contracts.negotiation_ctx(u, "Raid the Heron Clan", terms, true, "", {}, [], "war")
	check(ctx["env"]["enemies_known"].size() == 2 and ctx["max_crew"] >= 5, "the war leader knows the enemies and our fighters")
	var r := Persona.propose(ctx)
	print("   [Alie] ", r["speech"])
	var san: Dictionary = sim.contracts.sanitize(r["blueprint"], terms, u)
	var acts: Array = san["blueprint"]["steps"].map(func(st): return st["action"])
	check(san["ok"] and san["blueprint"]["target"] == "heron" and san["blueprint"]["objective"] == "loot", "the war plan honours the Chieftain's terms")
	check(acts.slice(-3) == ["assault", "loot", "return"] and "heavy_losses" in san["blueprint"]["abort_conditions"], "war plans follow the fixed skeleton (%s)" % ", ".join(acts))
	var junk: Dictionary = sim.contracts.sanitize({"kind": "war", "target": "Atlantis", "objective": "nuke", "crew_size": 99, "steps": [{"action": "build", "structure": "hut"}, {"action": "scout", "duration_sec": 999}]}, {"kind": "war"}, u)
	check(junk["ok"] and junk["blueprint"]["target"] in R.clans and junk["blueprint"]["objective"] == "loot" and junk["blueprint"]["crew_size"] <= 6 and junk["blueprint"]["steps"][0]["duration_sec"] == 25, "LLM war plans are whitelisted and clamped")
	# fight it out
	var c = sim.contracts.create(san["blueprint"], u, "Raid the Heron Clan")
	check(c.kind == "war" and c.crew_ids.size() == 5, "a war party of %d sets out" % c.crew_ids.size())
	var food0: float = sim.stock["food"]
	var rel0: float = R.clans["heron"]["relation"]
	var t := 0.0
	var saw_guards := false
	while sim.contracts.is_running(c) and t < 500.0:
		sim.tick(0.05)
		t += 0.05
		if sim.predators.any(func(p): return p.guard and not p.dead): saw_guards = true
		if c.status == "interrupted": sim.contracts.resolve(c, "press_on")
		if sim.paused:
			if sim.pending_event != "": sim.resolve_event(sim.pending_event, 0 if sim.pending_event.begins_with("demand_") else (1 if sim.pending_event.begins_with("submit_") else 2)) # (sparing a beaten clan would undo the feud)
			sim.paused = false
	print("   status %s after %.0fs: %s" % [c.status, t, c.flags.get("spoils", "-")])
	check(saw_guards, "their warriors turn out to defend the village")
	check(c.status == "done" and c.flags.get("spoils", "") != "", "the war party wins and comes home")
	check(sim.stock["food"] > food0 - 20 and R.clans["heron"]["relation"] < rel0 - 30, "loot taken; the Heron now hate us (%d)" % R.clans["heron"]["relation"])
	check(sim.living().filter(func(o): return o.memory.any(func(m): return "war party" in m["text"])).size() >= 1, "the warriors remember the war")
	# burning and breaking
	var huts0: int = sim.structures.filter(func(st): return st.owner == "rival:ochre" and st.type in ["hut", "large_hut"]).size()
	R.war_spoils("ochre", "burn", c)
	check(sim.structures.filter(func(st): return st.owner == "rival:ochre" and st.type in ["hut", "large_hut"]).size() == huts0 - 2, "burning destroys their huts")
	R.war_spoils("ochre", "break", c)
	check(R.clans["ochre"]["warriors"] == 0 and R.clans["ochre"]["raid_t"] >= D.DAY_LEN * 6, "breaking their warriors stops raids for days")
	# heavy losses wake the leader
	var sim2 = _new_sim()
	for id in sim2.rivals.clans: sim2.rivals.clans[id]["met"] = true
	var u2 = sim2.unit_by_name("Panshi")
	var bp2: Dictionary = sim2.contracts.sanitize({"kind": "war", "target": "ochre", "objective": "break", "crew_size": 4}, {"kind": "war"}, u2)["blueprint"]
	var c2 = sim2.contracts.create(bp2, u2, "war")
	c2.status = "executing"
	for id in c2.crew_ids.slice(1, 3): sim2.kill_unit(sim2.unit_by_id(id), null)
	sim2.contracts.update(0.05)
	check(c2.status == "interrupted" and c2.abort_reason == "heavy_losses" and "retreat" in sim2.contracts.allowed_effects(c2), "heavy losses wake the war leader's LLM node")
	var em := Persona.emergency(sim2.contracts.emergency_ctx(c2))
	check(em["options"].size() >= 2, "the leader offers choices after heavy losses")
	# trade caravans
	var sim3 = _new_sim()
	var heron: Dictionary = sim3.rivals.clans["heron"]
	heron["met"] = true
	heron["relation"] = 40.0
	heron["trade_t"] = 0.0
	sim3.rivals.update(0.05)
	var tr_ = sim3.predators.filter(func(p): return p.kind == "trader")
	check(tr_.size() == 1 and tr_[0].clan == "heron", "a friendly clan sends a trader")
	check(sim3.active_predators_near(tr_[0].pos, 100).is_empty(), "traders are not threats")
	tr_[0].pos = tr_[0].goal + Vector2(5, 0)
	tr_[0].path = []
	sim3.update_predator(tr_[0], 0.05)
	check(tr_[0].arrived and "trade_heron" in sim3.rivals.pending, "the trader reaches our fire and offers goods")
	var d: Dictionary = sim3.event_def("trade_heron")
	check(d["options"].size() == 4, "two trades, a lesson in their craft, or no deal")
	var wood0: float = sim3.stock["wood"]
	var food1: float = sim3.stock["food"]
	sim3.resolve_event("trade_heron", 0)
	check(sim3.stock["wood"] == wood0 - 15 and sim3.stock["food"] > food1 and tr_[0].fleeing, "goods change hands and the trader heads home")
	# knowledge from the parley table
	sim3.techs["fire"] = true
	var tl: Array = sim3.rivals.teachable("heron")
	check("pottery" in tl and not "totems" in tl, "they can teach what we're ready to learn (%s)" % ", ".join(tl))
	var ins0: float = sim3.evo.insight_frac("pottery")
	var lesson: Dictionary = sim3.rivals.empty_terms()
	lesson["teach"] = "pottery"
	check(sim3.rivals.deal_value("heron", lesson, sim3.unit_by_name("Linghe")) < sim3.rivals.deal_value("heron", sim3.rivals.empty_terms(), sim3.unit_by_name("Linghe")), "secrets cost more at the parley")
	var bad: Dictionary = sim3.rivals.sanitize_terms({"teach": "bronze"}, sim3.rivals.empty_terms(), "heron")
	check(bad["teach"] == "", "a clan can't teach what it doesn't know")
	sim3.rivals.seal(sim3.unit_by_name("Linghe"), "heron", lesson, 0)
	check(sim3.evo.insight_frac("pottery") > ins0 + 0.5, "being taught a secret brings it within reach (%d%%)" % roundi(sim3.evo.insight_frac("pottery") * 100))

func test_night_rest() -> void:
	print("\n== Night rest ==")
	var sim = _new_sim()
	for p in sim.predators: p.fled = true # no clan folk or beasts about
	var u = sim.unit_by_name("Tuo")
	sim.assign_gather(u, "wood")
	var job: Dictionary = u.job
	sim.time = D.DAY_LEN * 0.745 # nights are short: keep this test inside one
	for i in 120: sim.tick(0.05)
	check(u.sleeping and u.job == job, "at night a worker goes to bed and keeps the day's job waiting (%s)" % u.act)
	var abed: Array = sim.living().filter(func(o): return o.sleeping)
	check(abed.size() == sim.living().filter(func(o): return o.role in ["", "child"]).size(), "everyone without a mission sleeps, children too (%d)" % abed.size())
	var in_huts: Array = abed.filter(func(o): return sim.in_hut(o))
	check(in_huts.all(func(o): return sim.near_warmth(o)), "a hut keeps its sleepers warm")
	var caps := {}
	for o in in_huts: caps[o.bed_id] = caps.get(o.bed_id, 0) + 1
	check(caps.keys().all(func(id): return caps[id] <= int(D.STRUCTURES[sim.struct_by_id(id).type]["cap"])), "huts hold no more sleepers than they house")
	check(not in_huts.is_empty(), "the huts are used (%d inside, %d by the fire)" % [in_huts.size(), abed.size() - in_huts.size()])
	check(sim.night_ff(), "with the whole tribe asleep and nothing stirring, the night can fast-forward")
	# the Steward hands out no work at night
	sim.appoint(sim.unit_by_name("Panshi"), "steward")
	sim.vice_timer = 0
	sim.tick(0.05)
	check(sim.living().all(func(o): return o.sleeping or o.act == "Going to sleep"), "the Steward doesn't put sleepers to work")
	# a night order keeps someone up
	var w = sim.unit_by_name("Alie")
	sim.assign_gather(w, "wood")
	for i in 40: sim.tick(0.05)
	check(not w.sleeping and w.act != "Going to sleep", "an order given at night is carried out (%s)" % w.act)
	# danger wakes the camp
	var wolf = sim.spawn_predator(D.VILLAGE + Vector2(300, 0))
	wolf.kind = "wolf"
	wolf.raid_t = 60.0
	sim.tick(0.05)
	sim.tick(0.05)
	check(sim.night_alarm, "a beast at the village rouses the camp")
	check(u.sleeping and u.act == "Sheltering in a hut" and u.job.get("type", "") == "gather", "people in huts shelter inside instead of going back to work (%s)" % u.act)
	wolf.dead = true
	for i in 180: sim.tick(0.05)
	check(not sim.night_alarm and u.act == "Sleeping in a hut", "with the danger gone they sleep on (%s)" % u.act)
	# a pack in the woods doesn't wake the village; an outdoor sleeper near it keeps watch
	var far = sim.spawn_predator(D.VILLAGE + Vector2(-900, 0))
	far.kind = "wolf"
	far.raid_t = 60.0
	sim.tick(0.05)
	check(not sim.night_alarm, "a wolf far out in the woods does not rouse the camp")
	var camper = sim.unit_by_name("Yan")
	sim.wake(camper)
	sim.set_job(camper, {})
	camper.pos = far.pos + Vector2(120, 0)
	camper.bed_id = -1
	camper.bed_pos = camper.pos
	camper.sleeping = true
	sim.tick(0.05)
	check(not camper.sleeping and camper.act == "Keeping watch", "someone sleeping in the open wakes and keeps watch when a beast is near (%s)" % camper.act)
	far.dead = true
	# dawn
	sim.time = D.DAY_LEN * 0.97
	sim.tick(0.05)
	check(not u.sleeping and u.job.get("type", "") == "gather", "at dawn the worker gets back to work")

func test_night_contracts() -> void:
	print("\n== Contracts at night ==")
	var sim = _new_sim()
	sim.scripted_ambush = false
	for p in sim.predators: p.fled = true
	var u = sim.unit_by_name("Linghe")
	var ctx: Dictionary = sim.contracts.negotiation_ctx(u, "Find new wisdom", {"kind": "research"}, false, "", {}, [], "research")
	var san: Dictionary = sim.contracts.sanitize(Persona.propose(ctx)["blueprint"], {"kind": "research"}, u)
	var c = sim.contracts.create(san["blueprint"], u, "Find new wisdom")
	for i in 200: sim.tick(0.05)
	sim.time = D.DAY_LEN * 0.745
	for i in 200: sim.tick(0.05)
	check(u.sleeping, "wisdom seekers sleep at night too (%s)" % u.act)
	var st: float = c.state_t
	var pr: float = c.progress
	for i in 40: sim.tick(0.05)
	check(c.state_t == st and c.progress == pr and c.substate == "Camping for the night", "a peaceful contract's clock stops while its camp sleeps")
	sim.time = D.DAY_LEN * 0.97
	for i in 40: sim.tick(0.05)
	check(not u.sleeping and c.state_t > st, "at dawn the experiment goes on")

func test_herd() -> void:
	print("\n== Pack oxen ==")
	var sim = _new_sim()
	for p in sim.predators: p.fled = true
	sim.research("domestication")
	check(sim.oxen == 0 and sim.carry_cap(sim.unit_by_name("Tuo")) == 10, "knowing domestication alone gives no oxen")
	var pen = sim.add_structure("aurochs_pen", D.VILLAGE + Vector2(-200, 150))
	sim.complete_structure(pen, null)
	check(sim.oxen == 1 and sim.ox_cap() == 2, "a new pen comes with its first calf (room for 2)")
	var g: Array = ["Tuo", "Shan", "Bai"].map(func(nm): return sim.unit_by_name(nm))
	for u in g: sim.assign_gather(u, "wood")
	for i in 60: sim.tick(0.05)
	var led: Array = sim.living().filter(func(u): return u.ox)
	check(led.size() == 1 and led[0].job.get("type", "") == "gather" and sim.carry_cap(led[0]) == 15, "one ox, one gatherer with a bigger load")
	check(sim.living().filter(func(u): return sim.carry_cap(u) == 10).size() == sim.living().size() - 1, "everyone else carries the usual load")
	# oxen eat; with nothing to eat, one is slaughtered
	sim.stock["food"] = 0.0
	sim.oxen = 2
	pen.built = true
	for i in 95: sim._herd(1.0)
	check(sim.oxen == 1 and sim.stock["food"] >= 19.0, "a starving herd loses an ox to the pot (+20 food)")
	sim.stock["food"] = 100.0
	var f0: float = sim.stock["food"]
	sim.ox_care = 0.0
	for i in 10: sim._herd(1.0)
	check(sim.stock["food"] < f0, "oxen eat from the stores, and neglected ones give no milk")
	check(not sim.oxen_working(), "neglected oxen won't carry")
	sim._lend_oxen()
	check(g.all(func(u): return not u.ox), "so no gatherer gets one")
	# someone goes to tend them
	sim.ox_care = 40.0
	sim.herd_t = 0.0
	sim.time = D.DAY_LEN * 2 + 10.0
	sim.tick(0.05)
	var herder: Array = sim.living().filter(func(u): return u.job.get("type", "") == "tend")
	check(herder.size() == 1, "a villager is sent to tend the oxen")
	for i in 600:
		sim.tick(0.05)
		if sim.ox_care >= 99.0: break
	check(sim.ox_care >= 99.0 and herder[0].job.get("type", "") != "tend", "tending restores their care, then back to work (%s)" % herder[0].act)
	# a calf at dawn when there is room, food and care
	sim.stock["food"] = 100.0
	sim.time = D.DAY_LEN * 3 + 2.0
	sim._herd(0.05)
	check(sim.oxen == 2, "a calf is tamed at dawn while the pen has room")
	sim.time = D.DAY_LEN * 4 + 2.0
	sim._herd(0.05)
	check(sim.oxen == 2, "but never beyond 2 per pen")

func test_finds() -> void:
	print("\n== Natural finds ==")
	var sim = _new_sim()
	for p in sim.predators: p.fled = true
	sim.DISC = sim.DISC.duplicate(true) # (this test checks who can recognise what, not luck: make noticing certain)
	for g in sim.DISC["groups"]: sim.DISC["groups"][g]["chance"] = 50.0
	var missing: Array = D.FINDS.keys().filter(func(id): return D.FINDS[id]["count"] > 0 and not sim.nodes.any(func(n): return n.kind == id))
	check(missing.is_empty(), "every kind of find is somewhere on the map (missing: %s)" % ", ".join(missing))
	check(sim.known_finds.is_empty(), "nothing is known at the start")
	var mush = sim.nodes.filter(func(n): return n.kind == "mushroom")[0]
	var picked = sim.find_node("food", mush.pos, -1, 60.0)
	check(picked == null or picked.kind != "mushroom", "unknown finds can't be gathered")
	var u = sim.unit_by_name("Tuo")
	sim.set_job(u, {})
	u.pos = mush.pos + Vector2(30, 0)
	sim.reveal(mush.pos, 200)
	for i in 20: sim.tick(0.05)
	check(sim.knows_find("mushroom"), "walking up to one discovers it")
	var line: Dictionary = sim.log_lines.filter(func(e): return "Forest Mushrooms" in e["text"])[0]
	check(line["who"][0]["id"] == u.id, "the finder gets the credit in the chronicle")
	check(sim.find_node("food", mush.pos, -1, 60.0) != null, "and the tribe can gather it now")
	# healing plants need someone with lore to recognise them
	var willow = sim.nodes.filter(func(n): return n.kind == "willow")[0]
	sim.reveal(willow.pos, 200)
	var plain: Array = sim.living().filter(func(o): return o.lv("lore") == 0)
	var wise: Array = sim.living().filter(func(o): return o.lv("lore") >= 1)
	for o in sim.living():
		sim.set_job(o, {})
		o.pos = D.VILLAGE
	plain[0].pos = willow.pos + Vector2(20, 0)
	for i in 20: sim.tick(0.05)
	check(not sim.knows_find("willow"), "someone without lore walks past willow bark")
	wise[0].pos = willow.pos + Vector2(20, 0)
	for i in 20: sim.tick(0.05)
	check(sim.knows_find("willow"), "a person with lore recognises it")
	# willow-bark tea
	var sick = sim.unit_by_name("Shan")
	sick.sick = 1.0
	sim.stock["herbs"] = 3.0
	sim.unit_needs(sick, 0.05)
	check(sim.stock["herbs"] == 2.0 and sim.time < sick.herb_t, "a fevered person drinks willow-bark tea from the herbs")
	var r_tea: float = sim.hz.heal_rate(sick, false)
	sick.herb_t = -1.0
	check(r_tea > sim.hz.heal_rate(sick, false) * 2.0, "and recovers faster")
	# bronze needs copper and tin
	for id in ["fire", "tools", "domestication"]: sim.techs[id] = true
	check(not sim.evo.prereqs_met("bronze"), "Bronze can't be reached before copper and tin are found")
	sim.known_finds["copper"] = 1
	sim.known_finds["tin"] = 1
	check(sim.evo.prereqs_met("bronze"), "with both ores found it can")
	sim.techs["bronze"] = true
	sim.add_structure("smelter", D.VILLAGE + Vector2(150, 150), true)
	sim.stock["copper"] = 0.0
	sim.stock["tin"] = 0.0
	check(not sim.has_bronze(), "a smelter without ore arms no one")
	sim.stock["copper"] = 3.0
	sim.stock["tin"] = 2.0
	check(sim.has_bronze(), "with copper and tin it does")
	# honey lifts the spirit; fish are iced over in winter
	sim.devotion = 0.0
	u.carry_kind = "honey"
	sim._find_effects(u, 10)
	check(sim.devotion > 0.0, "a load of honey raises devotion")
	sim.known_finds["fish"] = 1
	var fish = sim.nodes.filter(func(n): return n.kind == "fish")[0]
	check(sim._can_gather_find(fish), "fish can be caught in the warm seasons")
	sim.hz.level = "normal"
	sim.time = D.DAY_LEN * sim.hz.SEASON_DAYS * 3 + 10.0
	check(sim.hz.winter() and not sim._can_gather_find(fish), "but not through winter ice")

func test_nature() -> void:
	print("\n== Forces of nature ==")
	var sim = _new_sim()
	for p in sim.predators: p.fled = true
	var nat = sim.nat
	# wildfire
	# (far from home: nobody comes to fight it, so it burns out by itself)
	var tree = sim.nodes.filter(func(n): return n.kind == "tree" and n.pos.distance_to(D.VILLAGE) > 1000 and sim.nodes.filter(func(o): return o.kind == "tree" and o.pos.distance_to(n.pos) < 60).size() >= 3)[0]
	nat.ignite(tree)
	check(nat.burning.has(tree.id) and "Wildfire" in nat.status() or nat.status().has(sim.tr("Wildfire")), "a tree catches fire: wildfire")
	var u = sim.unit_by_name("Tuo")
	sim.set_job(u, {})
	u.pos = tree.pos + Vector2(20, 0)
	var hp0: float = u.hp
	for i in 30: sim.tick(0.05)
	check(u.hp < hp0, "people too close to the flames get burned")
	for i in 4000:
		sim.tick(0.05)
		if nat.burning.is_empty(): break
	check(nat.burning.is_empty() and tree.kind == "burnt" and nat.fire_size >= 1, "the fire burns out and leaves burnt trees (%d)" % nat.fire_size)
	# lightning on a person
	var v = sim.unit_by_name("Shan")
	v.hp = v.max_hp
	nat._hit_person(v)
	check(not v.dead and v.memory.any(func(m): return "lightning" in m["text"]), "someone struck by lightning can live, touched by the sky")
	var w = sim.unit_by_name("Bai")
	w.hp = 5.0
	nat._hit_person(w)
	check(w.dead and sim.log_lines.any(func(e): return "struck by lightning" in e["text"]), "or die of it, and the chronicle says how")
	# fire from the sky before Friction Fire
	check(not sim.has_tech("fire"), "(no fire yet)")
	var before: float = sim.evo.insight["fire"]
	nat._sky_fire(sim.unit_by_name("Linghe").pos + Vector2(50, 0))
	check(nat.sky_fire_given and sim.evo.insight["fire"] > before, "lightning near people gives the tribe its first fire")
	# spring flood
	sim.hz.level = "normal"
	var dock = sim.add_structure("fishing_dock", _by_river(0, 60), true)
	var r = sim.unit_by_name("Yan")
	sim.set_job(r, {})
	r.pos = _by_river(120, 150)
	nat.flood_day = sim.day()
	nat.flood_at = sim.time + 14.0
	nat.flood_warned = false
	sim.tick(0.05)
	sim.tick(0.05)
	check(nat.flood_warned and r.job.get("flee", false), "when the river rises, people near the banks run for high ground")
	check(nat.alarm(), "a rising river wakes the camp")
	for i in 300: sim.tick(0.05)
	check(nat.flooding() and not dock.built, "the flood damages riverside buildings")
	for i in 1000:
		sim.tick(0.05)
		if not nat.flooding(): break
	var farm = sim.add_structure("farm_plot", _by_river(200, 250), true)
	check(nat.food_mult(farm) > 1.3, "the silt makes riverside fields richer afterwards")
	# the Fire Mountain
	var near = sim.unit_by_name("Qiao")
	near.pos = D.VOLCANO + Vector2(-200, 200)
	near.hp = near.max_hp
	nat.erupt()
	check(near.hp < near.max_hp, "the eruption burns anyone near the mountain")
	check(sim.nodes.any(func(n): return n.kind == "obsidian"), "and leaves obsidian on its slopes")
	for i in 400: sim.tick(0.05)
	check(nat.ash > 0.5 and nat.grow_mult() < 0.8 and nat.sight_mult() < 0.9, "ash darkens the sky, slows growth and shortens sight")
	# eclipse
	var sim2 = _new_sim()
	sim2.hz.level = "normal"
	sim2.time = D.DAY_LEN * 2 + D.DAY_LEN * 0.35
	sim2.nat.eclipse_at = sim2.time
	sim2.nat.quake_at = INF
	sim2.nat.erupt_at = INF
	for i in 140:
		sim2.tick(0.05)
		if sim2.pending_event != "": break
	check(sim2.pending_event == "eclipse" and sim2.nat.darkness() > 0.9, "the sun is devoured at midday, and the chieftain must answer")
	for o in sim2.living(): o.skills["lore"]["lv"] = 0
	var res: Dictionary = sim2.resolve_event("eclipse", 2)
	sim2.paused = false
	check(sim2.nat.panicking(), "a shaman with no answer: the people panic")
	for i in 120: sim2.tick(0.05)
	check(sim2.living().any(func(o): return o.act == "Hiding in a hut"), "and hide in their huts")
	sim2.techs["totems"] = true
	sim2.nat.panic_until = -1.0
	var lore0: float = sim2.stock["lore"]
	sim2.nat.resolve("eclipse", 2)
	check(sim2.stock["lore"] >= lore0 + 20 and not sim2.nat.panicking(), "with the totems' knowledge the omen calms the tribe and teaches it")
	# earthquake
	var built: int = sim2.structures.filter(func(st): return st.built and sim2.ours(st)).size()
	sim2.nat.quake()
	check(sim2.structures.filter(func(st): return st.built and sim2.ours(st)).size() < built, "an earthquake brings buildings down")

func test_settling() -> void:
	print("\n== Distance and settlements ==")
	var sim = _new_sim()
	for p in sim.predators: p.fled = true
	# walking far costs food; loads slow the walk
	var a = sim.unit_by_name("Tuo")
	var b = sim.unit_by_name("Shan")
	for u in [a, b]:
		sim.set_job(u, {})
		u.hunger = 80.0
	a.pos = D.VILLAGE
	sim.go_to(a, D.VILLAGE + Vector2(-600, 0))
	for i in 100:
		sim.step_move(a, 0.05, 58.0)
		sim.unit_needs(a, 0.05)
		sim.unit_needs(b, 0.05)
	check(a.hunger < b.hunger - 0.8, "walking far makes people hungrier (%.1f vs %.1f)" % [a.hunger, b.hunger])
	var v0: float = sim.unit_speed(a)
	a.carry_amt = 8
	check(sim.unit_speed(a) < v0 * 0.9, "a load slows the walk home")
	a.carry_amt = 0
	# a Granary takes food in closer to the fields
	var gran = sim.add_structure("granary", D.VILLAGE + Vector2(-500, 0), true)
	a.pos = gran.pos + Vector2(-100, 0)
	var dp: Vector2 = sim._dropoff_point({"dropoff": -1, "res": "food"}, a)
	check(dp == gran.pos, "food is dropped at the nearest Granary")
	check(sim._dropoff_point({"dropoff": -1, "res": "wood"}, a) == D.VILLAGE, "wood still goes to the village")
	# food storage: the village keeps 80, each Granary 100 more; the rest rots fast
	gran.built = false
	check(sim.food_cap() == 80, "the village alone stores 80 food")
	gran.built = true
	check(sim.food_cap() == 180, "a Granary stores 100 more")
	gran.built = false
	sim.stock["food"] = 200.0
	sim.tick(1.0)
	var lost_over: float = 200.0 - sim.stock["food"]
	sim.stock["food"] = 80.0
	sim.tick(1.0)
	var lost_in: float = 80.0 - sim.stock["food"]
	check(lost_over > lost_in * 5.0, "food over the limit rots fast (%.1f vs %.2f a second)" % [lost_over, lost_in])
	check(sim.alerts.any(func(a): return "Granary" in a["text"]), "and the tribe is told to build a Granary")
	# a crowded village sends people to a settlement with empty beds
	var c = E.Contract.new()
	c.id = sim.uid()
	c.kind = "settle"
	c.status = "done"
	c.site = D.SITES[0]
	c.plan = {"plan_id": "test_outpost"}
	sim.contracts.list.append(c)
	sim.add_structure("hut", D.SITES[0] + Vector2(40, 0), true, "contract:%d" % c.id)
	sim.add_structure("hut", D.SITES[0] + Vector2(-40, 0), true, "contract:%d" % c.id)
	var huts: Array = sim.structures.filter(func(st): return st.type == "hut" and st.owner == "village")
	huts[0].built = false
	huts[1].built = false
	check(sim.residents_of(D.VILLAGE).size() > sim.beds_at(D.VILLAGE), "(the village is crowded: %d people, %d beds)" % [sim.residents_of(D.VILLAGE).size(), sim.beds_at(D.VILLAGE)])
	sim.time = D.DAY_LEN * 1 + 10.0
	sim.resettle_t = 0.0
	sim.tick(0.05)
	var movers: Array = sim.residents_of(D.SITES[0])
	check(movers.size() == 1 and movers[0].job.get("type", "") == "move", "someone moves to the settlement across the river")
	check(sim.log_lines.any(func(e): return "test_outpost" in e["text"]), "and the chronicle tells of it")
	for i in 3:
		sim.resettle_t = 0.0
		sim.tick(0.05)
	check(sim.residents_of(D.SITES[0]).size() <= sim.beds_at(D.SITES[0]), "but never more than its beds")

func test_folk() -> void:
	print("\n== Village life ==")
	var sim = _new_sim()
	for p in sim.predators: p.fled = true
	var F = sim.folk
	var kids: Array = sim.living().filter(func(u): return u.role == "child")
	check(kids.size() == 2, "the tribe starts with two children")
	for i in 100: sim.tick(0.05)
	check(kids.all(func(k): return k.job.is_empty() and k.act in ["Playing chase", "Playing at hunters"] or k.act.begins_with("Watching")), "children play instead of working (%s)" % ", ".join(kids.map(func(k): return k.act)))
	check(not sim.contracts.available_helpers(sim.unit_by_name("Panshi").id).any(func(o): return o.role == "child"), "children are never picked for a crew")
	# watching the grown-ups teaches a little
	var kid = kids[0]
	var w = sim.unit_by_name("Bai")
	sim.assign_gather(w, "wood")
	kid.watch_id = w.id
	kid.play = "watch"
	kid.idle_t = 50.0
	kid.pos = w.pos + Vector2(10, 5)
	var xp0: float = kid.skills["forage"]["xp"] + kid.skills["forage"]["lv"] * 1000
	for i in 40: F.play(kid, 0.05)
	check(kid.skills["forage"]["xp"] + kid.skills["forage"]["lv"] * 1000 > xp0, "a child watching someone gather learns a little foraging")
	# coming of age
	kid.born_t = sim.time - sim.folk.CHILD_DAYS * D.DAY_LEN - 1.0
	F.mood_t = 0.0
	F.update(0.05)
	check(kid.role == "" and kid.max_hp >= 40 and kid.memory.any(func(m): return "came of age" in m["text"]), "after %d days a child comes of age" % int(sim.folk.CHILD_DAYS))
	# mood sets the pace of work
	var u = sim.unit_by_name("Tuo")
	F.mood = 100.0
	var fast: float = sim.work_mul(u)
	F.mood = 0.0
	check(fast > sim.work_mul(u) * 1.15, "a joyful tribe works faster than a despairing one")
	F.mood = 60.0
	F.on_death()
	check(F.mood < 60.0 and F.sorrow > 0, "a death saddens the tribe")
	# arts: goods, painted homes, treasures
	var artist = sim.unit_by_name("Panshi")
	sim.set_job(artist, {})
	artist.pos = D.VILLAGE + Vector2(20, 20)
	var g0: float = sim.stock["goods"]
	var d0: int = F.decor_total()
	for k in 3:
		F.start_art(artist)
		for i in 600:
			sim.update_unit(artist, 0.05)
			if artist.job.is_empty(): break
	check(sim.stock["goods"] > g0 or F.decor_total() > d0, "idle hands make goods or paint the huts (goods %d, decorations %d)" % [sim.stock["goods"], F.decor_total()])
	var t0: int = F.treasures.size()
	var m0: float = F.mood_target()
	F._masterpiece(artist, "carve")
	check(F.treasures.size() == t0 + 1 and F.mood_target() > m0, "a masterpiece becomes a treasure of the tribe and lifts its mood")
	# festivals
	F.festivals = true
	F.season_seen = 999 # (as if the season just turned)
	F.update(0.05)
	sim.tick(0.05)
	check(sim.pending_event == "festival", "the season's turn brings a festival")
	var heron: Dictionary = sim.rivals.clans["heron"]
	heron["met"] = true
	heron["relation"] = 20.0
	var food0: float = sim.stock["food"]
	F.mood = 40.0
	sim.resolve_event("festival", 0)
	sim.paused = false
	check(sim.stock["food"] < food0 and F.festival_on() and F.mood >= 64.0, "a great festival costs food and lifts the mood")
	check(heron["relation"] > 20.0, "and friendly neighbours come to share it")
	for i in 20: sim.tick(0.05)
	check(sim.living().filter(func(o): return o.act == "Dancing at the festival").size() >= 4, "the tribe dances around the bonfire")
	F.festival_until = -1.0
	# trade trips
	var sim2 = _new_sim()
	for p in sim2.predators: p.fled = true
	var H: Dictionary = sim2.rivals.clans["heron"]
	H["met"] = true
	H["relation"] = 20.0
	sim2.stock["goods"] = 6.0
	var t = sim2.unit_by_name("Yan")
	sim2.set_job(t, {})
	var q: Dictionary = sim2.folk.quote("heron", "goods", 5)
	check(not q.is_empty() and q.values()[0] > sim2.folk.quote("heron", "wood", 5).get(q.keys()[0], 0), "crafted goods fetch more than plain wood")
	check(sim2.folk.send_trader(t, "heron", "goods", 5) == "" and t.role == "trader" and sim2.stock["goods"] == 1.0, "a trader sets out with our goods")
	var sells: String = H["sells"]
	var before: float = sim2.stock[sells]
	var rel0: float = H["relation"]
	var txp0: float = t.skills["trade"]["xp"] + t.lv("trade") * 1000.0
	var lead0: float = t.skills["combat"]["xp"] + t.lv("combat") * 1000.0
	sim2.time = D.DAY_LEN + 1.0
	for i in 2400:
		sim2.tick(0.05)
		if t.role == "": break
	check(t.role == "" and sim2.stock[sells] >= before + q.values()[0] and H["relation"] > rel0, "and comes home with their %s (relations %d → %d)" % [sells, rel0, H["relation"]])
	check(t.skills["trade"]["xp"] + t.lv("trade") * 1000.0 > txp0 and t.skills["combat"]["xp"] + t.lv("combat") * 1000.0 > lead0, "trading teaches Trade & Barter, and a little leadership")
	var novice = sim2.unit_by_name("Bai")
	var master = sim2.unit_by_name("Qiao")
	novice.skills["trade"]["lv"] = 0
	master.skills["trade"]["lv"] = 5
	var qn: int = sim2.folk.quote("heron", "wood", 20, novice).values()[0]
	var qm: int = sim2.folk.quote("heron", "wood", 20, master).values()[0]
	check(qm > qn, "a master trader (Silver Tongue) brings home more: %d vs %d" % [qm, qn])
	H["relation"] = -40.0
	check(sim2.folk.send_trader(t, "heron", "food", 20) != "", "no trading with a hostile clan")

func test_burials() -> void:
	print("\n== Burials ==")
	var sim = _new_sim()
	for p in sim.predators: p.fled = true
	check(sim.burial_ground() == null, "no burial ground before anyone dies")
	var d = sim.unit_by_name("Tuo")
	d.pos = D.VILLAGE + Vector2(120, 80)
	sim.kill_unit(d, null)
	sim.tick(0.05)
	var bg = sim.burial_ground()
	check(bg != null and bg.pos.distance_to(D.VILLAGE) > 250, "the first death lays out a burial ground at the village edge")
	sim.time = 5.0
	for i in 30: sim.tick(0.05)
	var carrier = sim.unit_by_id(d.carrier_id)
	check(carrier != null and carrier.job.get("type", "") == "bury", "someone goes to fetch the body")
	for i in 1200:
		sim.tick(0.05)
		if d.buried: break
	check(d.buried and bg.graves.size() == 1 and not bg.graves[0]["lost"], "the body is carried to the burial ground and buried (%s)" % (carrier.act if carrier else "-"))
	check(d.pos.distance_to(bg.pos) < 60, "the grave lies inside the burial ground")
	check(carrier.memory.any(func(m): return "Tuo" in m["text"]), "the gravedigger remembers it")
	check(carrier.job.get("type", "") != "bury", "and goes back to their day")
	var line: Dictionary = sim.log_lines.filter(func(e): return "laid to rest" in e["text"])[0]
	check(line["who"].size() == 1 and line["who"][0]["id"] == d.id and line["who"][0]["name"] in line["text"], "the chronicle line knows who it is about (its name becomes a link)")
	# far from home, a body is lost to the wild after a day
	var f = sim.unit_by_name("Alie")
	f.pos = Vector2(D.W - 100, D.H - 100)
	sim.kill_unit(f, null)
	for i in 40: sim.tick(0.05)
	check(not f.buried and f.carrier_id < 0, "nobody walks to the far end of the land for a body")
	sim.time += D.DAY_LEN
	for i in 40: sim.tick(0.05)
	check(f.buried and bg.graves.size() == 2 and bg.graves[1]["lost"], "after a day the lost one gets a name-stone")

func test_endgames() -> void:
	print("\n== Alliances, vassals, endings ==")
	var sim = _new_sim()
	var R = sim.rivals
	for id in ["ochre", "heron"]: R.clans[id]["met"] = true
	R.pending.clear()
	sim.techs["fire"] = true
	var heron: Dictionary = R.clans["heron"]
	var ochre: Dictionary = R.clans["ochre"]
	var envoy = sim.unit_by_name("Linghe")
	var ally: Dictionary = R.empty_terms()
	ally["treaty"] = "alliance"
	ally["days"] = 40
	heron["relation"] = 10.0
	check(R.deal_value("heron", ally, envoy) < -100, "strangers won't swear an alliance")
	heron["relation"] = 45.0
	check(R.deal_value("heron", ally, envoy) > -60, "trusted neighbours will consider it")
	R.seal(envoy, "heron", ally, 0)
	check(R.stance("heron") == "Allied" and R.at_peace("heron") and R.allies() == ["heron"], "an alliance is sworn")
	var ins0: float = sim.evo.insight_frac("pottery")
	heron["share_day"] = 0
	R._treaties(heron)
	check(sim.evo.insight_frac("pottery") > ins0, "allies share what they know")
	# call to arms
	var called := false
	for i in 40:
		heron["call_t"] = 0.0
		heron["share_day"] = 0
		R._daily_bonds(heron)
		if "call_heron" in R.pending:
			called = true
			break
	check(called and heron["call_target"] == "ochre", "allies call us to war against their enemies")
	R.pending.clear()
	sim._fire_event("call_heron")
	var d: Dictionary = sim.event_def("call_heron")
	check(d["options"].size() == 3, "join, send gifts, or refuse")
	var res: Dictionary = sim.resolve_event("call_heron", 0)
	check(res.get("open_war", "") == "ochre", "joining opens a war contract against their enemy")
	# allies fight beside us
	var u = sim.unit_by_name("Alie")
	var bp: Dictionary = sim.contracts.sanitize({"kind": "war", "target": "ochre", "objective": "break", "crew_size": 3}, {"kind": "war"}, u)["blueprint"]
	var c = sim.contracts.create(bp, u, "war")
	ochre["warriors"] = 4
	var n: int = R.defend("ochre", c)
	check(c.flags.get("allies", "") == "heron" and n == 5, "allied spears mean fewer defenders (%d)" % n)
	# submission
	ochre["warriors"] = 0
	R.war_spoils("ochre", "break", c)
	check("submit_ochre" in R.pending, "a beaten clan may bend the knee")
	R.pending.clear()
	d = sim.event_def("submit_ochre")
	check(d["options"].size() == 3, "accept, demand more, or spare them")
	sim.resolve_event("submit_ochre", 0)
	check(R.stance("ochre") == "Vassal" and R.at_peace("ochre"), "the Red Ochre become our vassals")
	var food0: float = sim.stock["food"]
	ochre["share_day"] = 0
	R._treaties(ochre)
	check(sim.stock["food"] == food0 + 3, "vassals pay tribute every day")
	# conquest needs every clan
	sim.legacy.update(1.1)
	check(sim.legacy.pending == "", "no victory while a clan is free")
	heron["treaties"].clear()
	heron["vassal"] = 3
	for id in R.clans: # the far clans too
		if R.clans[id]["vassal"] == 0: R.clans[id]["vassal"] = 1
	sim.legacy.check_t = 0.0
	sim.legacy.update(0.1)
	check(sim.legacy.pending == "victory_conquest", "every clan a vassal: victory by conquest")
	sim.pending_event = ""
	sim.check_events()
	check(sim.pending_event == "victory_conquest" and sim.paused, "the ending pauses the game")
	var ctx: Dictionary = sim.legacy.saga_ctx("conquest")
	var saga: String = sim.legacy.saga_offline(ctx)
	print("   ", saga.replace("\n", " / ").left(300))
	check(not ctx["great_deeds"].is_empty() and saga.length() > 80, "the storyteller has deeds to tell")
	var end: Dictionary = sim.resolve_event("victory_conquest", 0)
	check(not end["restart"] and sim.legacy.achieved.has("conquest"), "the chronicle can go on after victory")
	var unity: Dictionary = sim.legacy.progress()[1]
	check(not unity["conds"][0]["done"], "unity needs alliances, not vassals")
	# defeat
	var sim2 = _new_sim()
	for o in sim2.living(): sim2.kill_unit(o, null)
	sim2.legacy.update(1.1)
	check(sim2.legacy.pending == "defeat", "when the last of us dies, the chronicle ends")
	check(sim2.event_def("defeat")["options"].size() == 1 and sim2.resolve_event("defeat", 0)["restart"], "defeat can only begin anew")

func test_mapgen() -> void:
	print("\n== Random maps ==")
	for size in MapGen.SIZE_ORDER:
		var n: int = MapGen.max_tribes(size)
		var t0 := Time.get_ticks_msec()
		MapGen.generate(size, n, 4242)
		var sz: Dictionary = MapGen.SIZES[size]
		check(D.W == sz["w"] and D.H == sz["h"] and D.RIVALS.size() == n and D.MAP["kind"] == "random", "%s map: %dx%d with %d clans, %d rivers, %d fords (%d ms)" % [size, D.W, D.H, n, D.RIVERS.size(), D.FORDS.size(), Time.get_ticks_msec() - t0])
		var ok := true
		for c in D.RIVALS:
			var p: Vector2 = c["pos"]
			if p.x < 300 or p.y < 300 or p.x > D.W - 300 or p.y > D.H - 300 or p.distance_to(D.VILLAGE) < 700 or D.river_dist(p) < 250: ok = false
			for o in D.RIVALS:
				if o != c and p.distance_to(o["pos"]) < 500: ok = false
		check(ok, "%s map: clans spread out, inside the map, clear of home and the water" % size)
		# every clan, landmark and site can be walked to from the village, over the fords
		var reach := true
		for p in D.RIVALS.map(func(c): return c["pos"]) + D.LANDMARKS.map(func(l): return l["pos"]) + D.SITES:
			var path: Array = D.route(D.VILLAGE, p)
			var at := D.VILLAGE
			for q in path:
				if not D.same_side(at, q) and D.ford_at((at + q) / 2.0) < 0 and D.ford_at(at) < 0: reach = false
				at = q
		check(reach, "%s map: every clan, landmark and site is reachable over the fords" % size)
		check(D.LANDMARKS.size() >= 8 and D.LANDMARKS.any(func(l): return l["kind"] == "den") and D.LANDMARKS.any(func(l): return l["kind"] == "grove" and l["pos"].distance_to(D.VILLAGE) < 1600), "%s map: %d landmarks from the templates, dens and an early grove" % [size, D.LANDMARKS.size()])
		check(D.TRIBE.size() == 9 and D.SCRIPT.is_empty() and not D.SITES.is_empty() and D.river_dist(D.VILLAGE) > 400 and D.river_dist(D.VILLAGE) < 1100, "%s map: a random tribe by the water, no scripted events, %d frontier sites" % [size, D.SITES.size()])
	var many := 0
	for s in 6:
		MapGen.generate("huge", 8, 900 + s)
		if D.RIVERS.size() > 1 and D.REGIONS.size() > 2: many += 1
	check(many > 0, "huge maps can have several rivers dividing the land (%d of 6)" % many)
	MapGen.generate("standard", 4, 77)
	var first: Array = D.RIVALS.map(func(c): return [c["id"], c["pos"]])
	var lm1: Array = D.LANDMARKS.map(func(l): return l["pos"])
	var tribe1: Array = D.TRIBE.map(func(u): return u["name"])
	MapGen.generate("standard", 4, 77)
	check(first == D.RIVALS.map(func(c): return [c["id"], c["pos"]]) and lm1 == D.LANDMARKS.map(func(l): return l["pos"]) and tribe1 == D.TRIBE.map(func(u): return u["name"]), "the same seed makes the same map and tribe")
	MapGen.generate("standard", 4, 78)
	check(first != D.RIVALS.map(func(c): return [c["id"], c["pos"]]), "another seed makes another map")
	MapGen.generate("small", 2, 5)
	var sim = _new_sim()
	var owners := {}
	for st in sim.structures: owners[st.owner] = true
	check(owners.size() == 3 and sim.units.size() >= 10 and sim.landmarks.size() == D.LANDMARKS.size(), "a game starts on a random map (2 clan villages)")
	check(sim.nodes.filter(func(n): return n.kind == "tree").size() > 150, "the random land is forested")
	check(sim.units.any(func(u): return u.job.get("type", "") == "ritual") and sim.units.any(func(u): return u.job.get("type", "") == "gather"), "the random tribe gets to work by temperament")
	for i in 400: sim.tick(0.05)
	check(sim.story.triggers.is_empty() and not sim.flags.has("flood"), "the random map runs, with no scripted events")
	# a settlement contract on a random map goes to one of its sites, wherever that is
	sim.scripted_ambush = false
	var u = sim.living().filter(func(o): return o.role == "")[0]
	var ctx: Dictionary = sim.contracts.negotiation_ctx(u, "Found a new settlement on the frontier", {}, false)
	var san: Dictionary = sim.contracts.sanitize(Persona.propose(ctx)["blueprint"], {}, u)
	var c = sim.contracts.create(san["blueprint"], u, "Found a new settlement on the frontier")
	check(c.site == D.SITES[0] and ctx["env"]["target_area"] != "", "the frontier site comes from the map: %s" % ctx["env"]["target_area"])
	# the leader only knows what the tribe has seen: no river or ford they never found
	var sim3 = _new_sim()
	var far_site: Vector2 = D.SITES.filter(func(s): return not sim3.is_explored(s)).front() if D.SITES.any(func(s): return not sim3.is_explored(s)) else D.SITES[0]
	var env3: Dictionary = sim3.contracts.env_data(far_site)
	var said: String = str(env3["target_area"]) + str(env3["river"]) + str(env3["timber"])
	check(not sim3.is_explored(far_site) and not said.contains("river") and not said.contains("ford") and not env3["explored"], "an unseen site is described as unknown land: %s" % env3["target_area"])
	var u3 = sim3.living().filter(func(o): return o.role == "")[0]
	var ctx3: Dictionary = sim3.contracts.negotiation_ctx(u3, "Found a new settlement on the frontier", {}, false)
	var speech: String = Persona.propose(ctx3)["speech"]
	print("   ", speech)
	check(not speech.contains("river") and not speech.contains("ford") and not speech.contains("across"), "and the leader doesn't talk of crossing it")
	sim3.fog_enabled = false # once the land is known, the crossing is too
	var across: Array = D.SITES.filter(func(s): return not D.home_side(s))
	if not across.is_empty():
		check(sim3.contracts.site_area(across[0]).contains("ford"), "a known site over known water says how to get there: %s" % sim3.contracts.site_area(across[0]))
	Scenarios.apply()
	check(D.W == 6400.0 and D.RIVALS.size() == 6 and D.MAP["kind"] == "scenario", "back to the scenario map")

func test_water() -> void:
	print("\n== Rivers, fords and routes ==")
	Scenarios.apply()
	var f: Dictionary = D.FORDS[0]
	var east: Vector2 = D.SITES[0]
	check(D.REGIONS.size() == 2 and not D.same_side(D.VILLAGE, east), "one river splits the scenario map in two")
	var path: Array = D.route(D.VILLAGE, east)
	check(path.size() == 3 and path[0].distance_to(f["p"]) < 120 and path[1].distance_to(f["p"]) < 120, "the way across goes over the ford")
	check(D.route(D.VILLAGE, D.VILLAGE + Vector2(-300, 100)).size() == 1, "on the same side, walk straight")
	check(D.is_water(f["p"] + f["t"] * 200.0) and not D.is_water(f["p"]) and D.in_river(f["p"]), "the ford is shallow, the rest deep")
	var sh: Vector2 = D.shore(f["p"] + f["t"] * 200.0, 8.0)
	check(not D.in_river(sh) and D.river_dist(sh) > D.RIVER_HALF, "shore() steps out of deep water")
	# a two-river map: a tributary splits one side, and there is a way everywhere
	D.W = 4000.0
	D.H = 3000.0
	var main := PackedVector2Array()
	var trib := PackedVector2Array()
	for k in 112: main.append(Vector2(2000, -80 + k * 30))
	for k in 70: trib.append(Vector2(-80 + k * 30, 1500))
	D.set_water([main, trib], [Vector2(2000, 700), Vector2(2000, 2300), Vector2(1000, 1500)])
	check(D.REGIONS.size() == 3, "a main river and a tributary make three stretches of land")
	var p2: Array = D.route(Vector2(500, 500), Vector2(3500, 2500))
	check(p2.size() == 3, "routes find the ford to the far side")
	var p3: Array = D.route(Vector2(500, 500), Vector2(500, 2500))
	check(p3.size() == 3 and p3[0].distance_to(Vector2(1000, 1500)) < 120, "the tributary ford joins the two western lands")
	D.set_water([main, trib], [Vector2(2000, 700), Vector2(2000, 2300)])
	var p4: Array = D.route(Vector2(500, 500), Vector2(500, 2500))
	check(p4.size() == 5, "without it, the way goes round over both main fords (%d legs)" % p4.size())
	Scenarios.apply()


func test_inventions() -> void:
	print("\n== Everyday inventions and achievements ==")
	var sim = _new_sim()
	var inv = sim.inv
	var u = sim.unit_by_name("Tuo")
	var cap0: int = sim.food_cap()
	for i in 300: sim.evo.practice(u, "berry", 1.0)
	check(inv.frac("digging_stick") >= 1.0 and not inv.has("digging_stick"), "foraging builds toward the digging stick")
	for i in 200:
		sim.tick(0.05)
		if inv.has("digging_stick"): break
	for i in 400:
		inv.update(2.1)
		if inv.has("digging_stick"): break
	check(inv.has("digging_stick") and inv.known["digging_stick"]["by"] == "Tuo", "the forager who practised most invents it")
	check(inv.gather_mult("bush", "berry") > 1.2, "berries are gathered faster with it")
	check(u.memory.any(func(m): return m["text"].contains("Digging Stick")), "the inventor remembers it")
	# needs gate the practice: no fishhook before fish is found
	for i in 100: sim.evo.practice(u, "hunt", 1.0)
	check(inv.frac("fish_hook") == 0.0 and inv.frac("moss_dressing") > 0.9, "a fishhook needs a fishing ground first")
	inv.discover("baskets", u)
	inv.discover("carrying_frame", u)
	inv.discover("bone_needle", u)
	check(sim.food_cap() == cap0 + 30 and sim.carry_cap(u) == 13, "baskets store more food, carrying frames carry more")
	sim.hz.level = "normal"
	check(inv.cold_mult() < 1.0, "bone needles make warmer clothes")
	var kinds: Array = inv.feats.map(func(f): return f["kind"])
	check(kinds.count("invention") == 4, "each invention is an achievement")
	sim.discover_find("fish", u, u.pos)
	sim.evo.breakthrough("fire", u)
	kinds = inv.feats.map(func(f): return f["kind"])
	check(kinds.has("find") and kinds.has("wisdom"), "finds and wisdom are achievements too")
	check(sim.evo.world_ctx()["everyday_inventions"].size() == 4, "the personas know the tribe's inventions")

func test_cultures() -> void:
	print("\n== Culture packs ==")
	Cultures.load_all(true)
	check(Cultures.problems.is_empty(), "every culture pack loads without errors %s" % str(Cultures.problems))
	check(Cultures.ids().has("huaxia") and Cultures.ids().size() >= 3, "the packs are found: %s" % ", ".join(Cultures.ids()))
	for id in Cultures.ids():
		var errs: Array = Cultures.validate(Cultures.by_id(id))
		check(errs.is_empty(), "%s passes validation %s" % [id, str(errs)])
	# the validator explains what is wrong
	var bad := {"id": "bad pack", "name": "X", "desc": "Y", "colour": 1,
		"inventions": [{"id": "axe", "name": "Axe", "desc": "d", "practice": {"juggling": 5}, "effects": [{"stat": "luck", "mul": 2}]},
			{"id": "moss_dressing", "name": "Dup", "desc": "d", "practice": {"hunt": 5}, "needs": {"techs": ["steam"]}}],
		"events": [{"id": "e", "title": "T", "text": "t", "when": {"moon": 1}, "options": [{"label": "a"}], "do": [{"invent": "nothing"}]}],
		"people": [{"id": "p", "name": "P", "desc": "d", "as": "god"}]}
	var errs: Array = Cultures.validate(bad)
	var all := "\n".join(errs)
	for want in ["unknown key 'colour'", "plain identifier", "unknown practice 'juggling'", "unknown stat 'luck'", "id 'moss_dressing' is already used",
			"unknown id 'steam'", "unknown condition 'moon'", "at least 2 options", "unknown invention 'nothing'", "as must be one of"]:
		check(all.contains(want), "the validator reports: " + want)
	# base effects are unchanged by the data-driven refactor
	Cultures.reset()
	var sim = _new_sim()
	var u = sim.unit_by_name("Tuo")
	check(not sim.cult.on() and sim.inv.mul("heal") == 1.0, "no culture: the base game")
	sim.inv.discover("moss_dressing", u)
	sim.inv.discover("smoking_rack", u)
	sim.inv.discover("salt_curing", u)
	check(is_equal_approx(sim.inv.heal_mult(), 1.4) and is_equal_approx(sim.inv.spoil_mult(), 0.56), "invention effects come from data (heal x1.4, spoil x0.7x0.8)")
	var spd0: float = sim.unit_speed(u)
	u.hp = u.max_hp * 0.2
	var slow: float = sim.unit_speed(u)
	sim.inv.discover("bone_setting", u)
	check(slow < spd0 and is_equal_approx(sim.unit_speed(u), spd0), "bone setting: the badly hurt are not slowed (steady)")
	# a culture adds its inventions, foods, finds and bloodlines
	Cultures.apply("huaxia")
	check(D.CULTURE["id"] == "huaxia" and D.INVENTIONS.any(func(d): return d["id"] == "leisi") and D.INVENTIONS.any(func(d): return d["kind"] == "food"), "Huaxia brings its inventions and foods")
	check(D.FINDS.has("mulberry") and D.FINDS["mulberry"]["look"] == "yarrow", "and its finds (drawn like a base find)")
	check(D.CHOSEN.size() == 3 and D.CHOSEN[0]["label"] == "Hou Yi the Archer", "and the Chosen One's bloodlines")
	sim = _new_sim()
	var cu = sim.cult
	check(cu.on() and sim.nodes.any(func(n): return n.kind == "mulberry"), "the culture's finds are placed on the map")
	u = sim.unit_by_name("Linghe")
	sim.inv.discover("leisi", u)
	sim.inv.discover("fuxi_net", u)
	sim.inv.discover("fish_hook", u)
	check(is_equal_approx(sim.inv.mul("yield", "farm_plot"), 1.25) and is_equal_approx(sim.inv.mul("yield", "fishing_dock"), 1.0), "yield effects apply to their structure only")
	check(is_equal_approx(sim.inv.gather_mult("fish", "hunt"), 1.3 * 1.4) and is_equal_approx(sim.inv.gather_mult("bush", "berry"), 1.0), "gather effects stack on their kind only")
	# a chronicle event: tracks in the mud
	sim.inv.discover("knotted_cords", u)
	sim.evo.era = 2
	while sim.living().size() < 10: sim.units.append(sim.folk.make_child("Kesh", null))
	var ins0: float = sim.evo.insight["code"]
	cu.update(1.1)
	check(cu.fired.has("bird_tracks") and sim.evo.insight["code"] > ins0, "a chronicle event fires when its conditions hold (insight into Tribal Code)")
	check(sim.log_lines.any(func(l): return l["text"].contains("Tracks in the Mud")), "and is written in the log")
	# a dilemma: ten suns, after a drought
	cu.on_event("drought")
	sim.time = D.DAY_LEN * 4.0 + 5.0
	for i in 3000:
		cu.update(1.1)
		if not cu.pending.is_empty(): break
	check(cu.pending.has("culture:ten_suns"), "a dilemma waits once its conditions hold and its chance comes up")
	sim.check_events()
	check(sim.pending_event == "culture:ten_suns" and sim.paused, "it pauses the game like any event")
	var ev: Dictionary = sim.event_def(sim.pending_event)
	check(ev["options"].size() == 3 and ev["options"][0]["desc"].contains("20"), "its options show their costs")
	sim.stock["food"] = 50.0
	var dev0: float = sim.devotion
	var res: Dictionary = sim.resolve_event("culture:ten_suns", 0)
	check(sim.stock["food"] == 30.0 and sim.devotion > dev0 and res["text"].contains("gentle sun"), "choosing pays the cost, runs the actions and tells the outcome")
	# folk tales: told by the fire at night, once each
	sim.time = floor(sim.time / D.DAY_LEN) * D.DAY_LEN + D.DAY_LEN * 0.8
	cu.tale_day = -1
	cu.update(1.1)
	check(cu.told.size() == 1, "a tale is told at night")
	var first: String = cu.told.keys()[0]
	cu.update(1.1)
	check(cu.told.size() == 1, "only one tale a night")
	check(cu.told[first]["by"] == sim.best_unit("lore", false).name, "the best keeper of lore tells it")
	check(sim.evo.world_ctx().has("tales_we_tell") and sim.evo.world_ctx()["tales_we_tell"].size() == 1, "personas know the tales that were told")
	cu.on_event("earthquake")
	cu.update(1.1)
	check(cu.told.has("nuwa_sky"), "an event can tell a tale (an earthquake: Nüwa mends the sky)")
	var b0: int = cu.boons.size()
	cu.tell("shennong_herbs")
	check(cu.boons.size() == b0 + 1 and sim.inv.mul("sick") > 1.0, "a tale can leave a lasting boon")
	# people: a wanderer joins, the chosen one comes from the culture
	var n0: int = sim.living().size()
	cu.join("yidi")
	check(sim.living().size() == n0 + 1 and sim.unit_by_name("Yi Di") != null and cu.joined.has("yidi"), "a wanderer joins the tribe")
	check(sim.event_def("chosen")["options"][1]["label"] == "Yu the Flood-Tamer", "the Chosen One's bloodlines come from the culture")
	sim.resolve_event("chosen", 0)
	check(cu.joined.has("houyi") and sim.unit_by_name("Hou Yi").hero, "and the one born is known to the Heritage panel")
	var codex: Array = cu.codex()
	var people: Dictionary = codex.filter(func(sec): return sec["section"] == "people")[0]
	check(people["entries"].filter(func(e): return e["known"]).size() >= 8, "the Heritage panel lists ancestors, the joined and the chosen")
	check(codex.any(func(sec): return sec["entries"].any(func(e): return e["history"] == "legend" and e["source"] != "")), "entries carry their history and source")
	# a random map: the tribe takes the culture's names, led by its founders
	for id in Cultures.ids():
		var c: Dictionary = Cultures.by_id(id)
		if not c.has("tribe_names") or not c.get("people", []).any(func(p): return p.get("as", "") == "founder"): continue
		Cultures.apply(id)
		MapGen.generate("small", 2, 7)
		var rs = _new_sim()
		var founders: Array = c["people"].filter(func(p): return p.get("as", "") == "founder")
		check(founders.all(func(p): return rs.unit_by_name(p["name"]) != null), "%s: the founders lead the random tribe" % id)
		check(rs.living().filter(func(x): return x.role == "").all(func(x): return x.name in c["tribe_names"] or founders.any(func(p): return p["name"] == x.name)), "%s: the others bear the culture's names" % id)
		break
	Cultures.reset()
	Scenarios.apply()

func test_flood_deer() -> void:
	print("\n== Deer and the spring flood ==")
	var sim = _new_sim()
	var deer: Array = sim.nodes.filter(func(n): return n.kind == "deer")
	var d = deer[0]
	var c: Vector2 = D.nearest_river_point(D.VILLAGE + Vector2(0, 600))
	var out: Vector2 = (D.VILLAGE + Vector2(0, 600) - c).normalized()
	d.pos = c + out * (D.RIVER_HALF + 50.0)
	d.bank = D.region_at(d.pos)
	check(sim.nat.flood_half() == D.RIVER_HALF, "no flood: the river is its usual width")
	sim.nat.flood_left = 40.0
	check(D.river_dist(d.pos) < sim.nat.flood_half(), "the flood covers the deer's meadow")
	for i in 100: sim.tick(0.05)
	check(D.river_dist(d.pos) >= sim.nat.flood_half(), "the deer bounds out of the floodwater (%d from the river, water to %d)" % [D.river_dist(d.pos), sim.nat.flood_half()])
	var far: Array = sim.nodes.filter(func(n): return n.kind == "deer" and D.river_dist(n.pos) < INF)
	for i in 200: sim.tick(0.05)
	check(far.all(func(n): return D.river_dist(n.pos) >= sim.nat.flood_half() - 1.0), "no deer wades into the flood")

func test_dry_beds() -> void:
	print("\n== Nobody sleeps in the water ==")
	var sim = _new_sim()
	sim.structures = sim.structures.filter(func(st): return not st.type in sim.SHELTERS and st.type != "bonfire") # (no beds: camp in the open)
	var u = sim.unit_by_name("Tuo")
	var c: Vector2 = D.nearest_river_point(D.VILLAGE + Vector2(0, 400))
	var out: Vector2 = (D.VILLAGE + Vector2(0, 400) - c).normalized()
	u.pos = c + out * (D.RIVER_HALF + 8.0)
	u.job = {}
	sim.time = floor(sim.time / D.DAY_LEN) * D.DAY_LEN + D.DAY_LEN * 0.8
	for i in 200: sim.update_unit(u, 0.05)
	check(D.river_dist(u.pos) >= D.RIVER_HALF + 30.0, "someone caught at the riverbank at night beds down away from the water (%d)" % D.river_dist(u.pos))
	sim.nat.flood_left = 40.0
	for i in 400: sim.update_unit(u, 0.05)
	check(D.river_dist(u.pos) >= sim.nat.flood_half(), "when the flood rises, the sleeper gets up and moves out of it (%d, water to %d)" % [D.river_dist(u.pos), sim.nat.flood_half()])
	check(u.sleeping or u.act == "Keeping watch" or u.act == "Going to sleep", "and settles down again (%s)" % u.act)

func test_feat_details() -> void:
	print("\n== Achievements carry their story ==")
	var sim = _new_sim()
	var got: Array = []
	sim.feat_added.connect(func(f): got.append(f))
	var u = sim.unit_by_name("Tuo")
	sim.inv.discover("moss_dressing", u)
	check(got.size() == 1 and got[0]["kind"] == "invention", "a new first is announced (for the HUD to celebrate)")
	check(got[0]["desc"].contains("40%") and got[0]["at"] == u.pos and got[0]["who"] == "Tuo", "with what it means, who did it and where")
	sim.discover_find("salt", u, u.pos + Vector2(30, 0))
	check(got.back()["kind"] == "find" and got.back()["at"] == u.pos + Vector2(30, 0) and got.back()["desc"] != "", "a find is pictured where it was found")
	sim.evo.adopt("peaceful_ways")
	check(got.back()["kind"] == "tradition" and got.back()["at"] == D.VILLAGE and got.back()["desc"] != "", "a tribe-wide first is pictured at the village")
	check(sim.inv.feats.size() == got.size(), "and every one is kept for the Achievements panel")

func test_help_and_carry() -> void:
	print("\n== Neighbours help; the dead are carried ==")
	var sim = _new_sim()
	var v = sim.unit_by_name("Tuo")
	var helpers: Array = sim.living().filter(func(o): return o != v and o.role == "")
	for i in helpers.size(): helpers[i].pos = v.pos + Vector2(60 + i * 15, 30)
	var t = sim.spawn_predator(v.pos + Vector2(12, 0), v.pos)
	for i in 60:
		sim.tick(0.05)
		if t.dead or t.fleeing: break
	var on_it: Array = sim.units.filter(func(o): return o != v and o.job.get("type", "") == "attack" and o.job.get("target_id", -1) == t.id)
	check(on_it.size() >= 2 or t.dead or t.fleeing, "when a beast attacks, the people nearby come to help (%d came)" % on_it.size())
	check(on_it.size() <= int(sim.react.responses("attacked")[0]["count"]) + 1, "but not the whole tribe")
	check(sim.living().filter(func(o): return o.role == "child" and o.job.get("type", "") == "attack").is_empty(), "children stay out of it")
	for i in 600:
		sim.tick(0.05)
		if t.dead or t.fled: break
	check(t.dead or t.fleeing or t.fled, "together they drive it off or kill it")
	# a burial: the body rides on the bearer's shoulders
	var sim2 = _new_sim()
	var dead = sim2.unit_by_name("Mo'er")
	sim2.kill_unit(dead, null)
	var carried := false
	for i in 4000:
		sim2.tick(0.05)
		var c = sim2.unit_by_id(dead.carrier_id) if dead.carrier_id >= 0 else null
		if c and c.job.get("phase", "") == "carry":
			for k in 10: sim2.tick(0.05) # (on its way)
			carried = c.job.get("phase", "") != "carry" or dead.pos.distance_to(c.pos) < 3.0
			break
	check(carried, "the body is carried by the bearer, not dragged behind")

func test_reactions() -> void:
	print("\n== People react to the world around them ==")
	# an earthquake: out from under the roofs, crouch, then back to work
	var sim = _new_sim()
	var u = sim.unit_by_name("Bai")
	var hut = sim.structures.filter(func(s): return s.type == "hut")[0]
	u.pos = hut.pos + Vector2(10, 10)
	sim.assign_gather(u, "wood")
	sim.nat.quake()
	check(u.job.get("type", "") == "cover" and u.resume_job.get("type", "") == "gather", "when the earth shakes, work stops: everyone takes cover (and remembers the work)")
	for i in 80: sim.tick(0.05)
	var clear: bool = sim.structures.filter(func(s): return s.built and s.type in sim.SHELTERS).all(func(s): return s.pos.distance_to(u.pos) > 60)
	check(clear and u.act == "Crouching in the open", "they run into the open, away from the huts (%s)" % u.act)
	for i in 300: sim.tick(0.05)
	check(u.job.get("type", "") == "gather", "when the shaking stops they go back to work (%s)" % u.job.get("type", ""))
	# lightning hurts someone: a neighbour comes to tend them
	var sim2 = _new_sim()
	var v = sim2.unit_by_name("Yan")
	for o in sim2.living():
		if o != v and o.role == "": o.pos = v.pos + Vector2(80, 40)
	sim2.nat._hit_person(v)
	var aiders: Array = sim2.units.filter(func(o): return o.job.get("type", "") == "aid" and o.job.get("victim", -1) == v.id)
	check(aiders.size() >= 1 and aiders.size() <= 2, "someone struck by lightning gets help (%d come)" % aiders.size())
	var hp0: float = v.hp
	for i in 300: sim2.tick(0.05)
	check(v.hp > hp0 + v.max_hp * 0.1, "and their wound is dressed")
	# a wildfire near the village: grown-ups fight it, children run from it
	var sim3 = _new_sim()
	var trees: Array = sim3.nodes.filter(func(n): return n.kind == "tree")
	trees.sort_custom(func(a, b): return a.pos.distance_to(D.VILLAGE) < b.pos.distance_to(D.VILLAGE))
	var t = trees[0]
	var kid = sim3.living().filter(func(o): return o.role == "child")[0]
	kid.pos = t.pos + Vector2(50, 20)
	sim3.nat.ignite(t)
	for i in 30: sim3.tick(0.05)
	check(sim3.units.any(func(o): return o.job.get("type", "") == "firefight"), "a fire near home brings people running to beat it out")
	check(kid.job.get("type", "") != "firefight" and kid.job.get("flee", false), "children run away from it")
	for i in 400:
		sim3.tick(0.05)
		if sim3.nat.burning.is_empty(): break
	check(sim3.nat.burning.is_empty() and sim3.nat.fire_size < 20, "the fire is beaten out before it spreads far (%d trees caught)" % sim3.nat.fire_size)

func test_config() -> void:
	print("\n== Events and reactions come from config ==")
	var Config = preload("res://scripts/config.gd")
	# every data file parses (a broken one is silently skipped in the game: notices.json once was)
	var broken: Array = []
	for dir in ["res://config"] + Array(DirAccess.get_directories_at("res://cultures")).map(func(d): return "res://cultures/" + d):
		for f in DirAccess.get_files_at(dir):
			if f.ends_with(".json") and not JSON.parse_string(FileAccess.get_file_as_string(dir + "/" + f)) is Dictionary: broken.append(dir + "/" + f)
	check(broken.is_empty(), "every config and culture file is valid JSON (%s)" % ", ".join(broken))
	var R = preload("res://scripts/reactions.gd")
	var ev: Dictionary = Config.load_cfg("events")
	var re: Dictionary = Config.load_cfg("reactions")
	check(not ev.is_empty() and not re.is_empty(), "config/events.json and config/reactions.json load")
	check(R.problems(re).is_empty(), "every reaction names a known response and who (%s)" % str(R.problems(re)))
	var sim = _new_sim()
	check(sim.hz.WEATHER.has("blizzard") and sim.hz.SEASON_DAYS == int(ev["seasons"]["days"]), "the weather and seasons are read from the config")
	# the numbers in the file are the ones the rules use
	var w = sim.spawn_predator(D.VILLAGE + Vector2(900, 0), D.VILLAGE)
	sim.hz.make_wolf(w)
	check(is_equal_approx(w.max_hp, float(ev["wolves"]["hp"])) and is_equal_approx(w.spd, float(ev["wolves"]["spd"])), "a wolf's strength comes from the config")
	# a user override merges over the game's file
	var base := {"a": {"x": 1, "y": 2}, "b": [1]}
	Config._merge(base, {"a": {"y": 5}, "c": true})
	check(base["a"]["x"] == 1 and base["a"]["y"] == 5 and base["c"] == true, "a user://config file overrides only the keys it has")
	# change the data, change the behaviour: with no earthquake reactions nobody takes cover
	var saved: Array = re["on"]["earthquake"]
	re["on"]["earthquake"] = []
	var u = sim.unit_by_name("Bai")
	sim.assign_gather(u, "wood")
	sim.nat.quake()
	check(u.job.get("type", "") == "gather", "an event with no reactions configured leaves people at their work")
	re["on"]["earthquake"] = [{"do": "flee", "who": "all", "dist": 200}]
	sim.nat.quake()
	check(u.job.get("flee", false), "and a different reaction in the config is what they do")
	re["on"]["earthquake"] = saved
	# a rival clan's grudges are data too
	var rv: Dictionary = sim.rivals.C
	var cid: String = sim.rivals.clans.keys()[0]
	var rel0: float = sim.rivals.clans[cid]["relation"]
	sim.rivals._deed(cid, "built_on_land")
	check(is_equal_approx(sim.rivals.clans[cid]["relation"], maxf(-100.0, rel0 + float(rv["deeds"]["built_on_land"]["relation"]))), "what our deeds do to a clan's feelings comes from config/rivals.json")

func test_gm_operations() -> void:
	print("\n== Reactions, weather and dilemmas as operations ==")
	var sim = _new_sim()
	for p in sim.predators: p.fled = true
	# freezing: the "freezing" reaction sends them to the fire, then back to work
	sim.hz.level = "normal"
	sim.hz.set_weather("blizzard")
	var u = sim.unit_by_name("Bai")
	sim.assign_gather(u, "wood")
	u.pos = D.VILLAGE + Vector2(700, 300)
	u.hp = u.max_hp * 0.4
	sim.tick(0.05)
	check(u.job.get("type", "") == "warm" and u.resume_job.get("type", "") == "gather", "someone freezing in a blizzard goes to the fire (and keeps their work)")
	sim.hz.set_weather("clear")
	u.hp = u.max_hp
	for i in 400:
		sim.tick(0.05)
		if u.job.get("type", "") == "gather": break
	check(u.job.get("type", "") == "gather", "warm again, they go back to work")
	# weather effects are data
	sim.hz.set_weather("rain")
	var rain: Dictionary = sim.hz.WEATHER["rain"]
	check(is_equal_approx(sim.hz.speed_mult(), float(rain["speed"])) and sim.hz.wet(), "rain slows walking by its configured amount, and is wet")
	var old: float = rain["speed"]
	rain["speed"] = 0.5
	check(is_equal_approx(sim.hz.speed_mult(), 0.5), "change the config and the rain changes")
	rain["speed"] = old
	sim.hz.set_weather("clear")
	check(not sim.hz.set_weather("hailstorm"), "an unknown weather is refused")
	# a scout backs off from a beast, then scouts on
	var sim2 = _new_sim()
	var sc = sim2.unit_by_name("Tuo")
	sim2.assign_explore(sc)
	var tiger = sim2.predators.filter(func(p): return p.kind == "tiger")[0]
	tiger.fled = false
	tiger.fleeing = false
	tiger.pos = sc.pos + Vector2(150, 0)
	sim2.tick(0.05)
	check(sc.job.get("flee", false) and sc.resume_job.get("type", "") == "explore", "a scout who sees a beast backs away (beast_seen)")
	# panic: people hide in their huts until it passes
	var sim3 = _new_sim()
	var w = sim3.unit_by_name("Yan")
	sim3.assign_gather(w, "wood")
	sim3.story.run([{"panic": 8}], null)
	check(w.job.get("type", "") == "shelter", "a panic sends people to hide (reaction \"panic\")")
	for i in 120: sim3.tick(0.05)
	check(sim3.living().any(func(o): return o.act == "Hiding in a hut" and sim3.in_hut(o)), "they hide inside the huts")
	for i in 200: sim3.tick(0.05)
	check(w.job.get("type", "") == "gather" and not sim3.in_hut(w), "when the panic is over they come out and go back to work")
	# weather and reactions are actions too (scenarios, packs, a game master)
	sim3.hz.level = "normal"
	sim3.story.run([{"weather": "storm"}], null)
	check(sim3.hz.weather == "storm", "an action can bring a storm")
	sim3.story.run([{"react": "earthquake"}], null)
	check(sim3.living().any(func(o): return o.job.get("type", "") == "cover"), "and an action can set off a reaction")
	# posing a dilemma from outside: checked, then queued and run like any other
	var bad: Array = sim3.story.pose("x", {"title": "T", "text": "t", "options": [{"label": "a", "do": [{"spawn": "dragon"}]}, {"label": "b"}]})
	check(not bad.is_empty(), "a bad dilemma is refused with the reasons (%s)" % (bad[0] if bad else ""))
	var food0: float = sim3.stock["food"]
	var ok: Array = sim3.story.pose("gift", {"title": "A Gift", "text": "Strangers leave a basket at the fire.", "speaker": "best:lore",
		"options": [{"label": "Keep it", "do": [{"give": {"food": 10}}], "result": "%s shares out the food."}, {"label": "Leave it", "result": "The basket stays."}]})
	check(ok.is_empty() and "posed:gift" in sim3.story.pending, "a good one is queued (%s)" % str(ok))
	sim3.check_events()
	check(sim3.pending_event == "posed:gift" and sim3.event_def("posed:gift")["options"].size() == 2, "it comes up as a dilemma")
	var res: Dictionary = sim3.resolve_event("posed:gift", 0)
	check(sim3.stock["food"] >= food0 + 10 and res["text"].ends_with("shares out the food."), "and choosing runs its actions (%s)" % res["text"])

func test_dilemma_config() -> void:
	print("\n== The chieftain's dilemmas come from config ==")
	var Story = preload("res://scripts/story.gd")
	var sim = _new_sim()
	var dl: Dictionary = sim.DILEMMAS
	var bad: Array = []
	for id in dl:
		if id.begins_with("_"): continue
		for o in sim.story.options(dl[id]):
			for k in o:
				if not k in ["label", "desc", "cost", "cost_note", "needs", "chance", "when", "do", "result", "result_add", "else_do", "else_result"]: bad.append("%s: option key %s" % [id, k])
			for a in o.get("do", []) + o.get("else_do", []):
				for k in a:
					if not k in Story.ACTIONS: bad.append("%s: action %s" % [id, k])
	check(bad.is_empty(), "every dilemma uses known option keys and actions (%s)" % str(bad))
	# every one renders with its values filled in
	var cid: String = sim.rivals.clans.keys()[0]
	var other: String = sim.rivals.clans.keys()[-1]
	sim.rivals.clans[cid]["call_target"] = other
	sim.rivals.clans[cid]["demand"] = 20
	var ids := ["flood", "overpop", "chosen", "era2", "era3", "festival", "contact_" + cid, "demand_" + cid, "call_" + cid, "submit_" + cid]
	var leftover: Array = []
	for id in ids:
		var d: Dictionary = sim.event_def(id)
		var all: String = d.get("title", "") + d.get("text", "")
		for o in d.get("options", []): all += o["label"] + o["desc"]
		if d.get("options", []).is_empty() or all.contains("%s") or all.contains("%d"): leftover.append(id)
	check(leftover.is_empty(), "all of them render, with every value filled in (%s)" % str(leftover))
	var fl: Dictionary = sim.event_def("flood")
	check(fl["options"][1]["desc"].contains("%"), "the offering's chance is shown (%s)" % fl["options"][1]["desc"])
	# the festival's cost scales with the tribe
	sim.stock["food"] = 1000
	var food0: float = sim.stock["food"]
	sim.resolve_event("festival", 0)
	check(is_equal_approx(food0 - sim.stock["food"], sim.living().size() * 2) and sim.folk.festival_on(), "a great festival costs 2 food a head and starts the dancing")
	# a demand: pay, and the raid waits; refuse, and it comes
	var c: Dictionary = sim.rivals.clans[cid]
	c["met"] = true
	food0 = sim.stock["food"]
	sim.resolve_event("demand_" + cid, 0)
	check(is_equal_approx(food0 - sim.stock["food"], 20.0) and c["raid_t"] >= D.DAY_LEN * 3.9, "paying a demand hands over the food and puts off the raid")
	var war0: int = sim.predators.filter(func(p): return p.clan == cid and p.kind == "warrior").size()
	sim.resolve_event("demand_" + cid, 1)
	check(sim.predators.filter(func(p): return p.clan == cid and p.kind == "warrior").size() > war0, "refusing it brings their war band")
	# change the data, change the dilemma
	var old: String = dl["overpop"]["options"][0]["label"]
	dl["overpop"]["options"][0]["label"] = "Found a colony"
	check(sim.event_def("overpop")["options"][0]["label"] == "Found a colony", "editing config/dilemmas.json changes the dilemma")
	dl["overpop"]["options"][0]["label"] = old

func test_improvements() -> void:
	print("\n== The village lays out improvements ==")
	var sim = _new_sim()
	var imp = sim.improve
	sim.time = D.DAY_LEN * 0.3 # (by day)
	sim.stock["wood"] = 200
	sim.techs["pottery"] = true
	sim.stock["food"] = sim.food_cap()
	imp.update(100.0)
	check(imp.open_sites() == 0, "without a Steward nobody plans (planner steward)")
	var st = sim.living().filter(func(u): return u.role == "")[0]
	sim.appoint(st, "steward")
	check(imp.wanted().size() >= 1 and imp.wanted()[0]["structure"] == "granary", "full stores make a Granary the first want (%s)" % str(imp.wanted().map(func(r): return r["structure"])))
	var n0: int = sim.structures.size()
	var wood0: float = sim.stock["wood"]
	imp.update(100.0) # no advisor connected: builds the first want at once
	var g = sim.structures.back()
	check(sim.structures.size() == n0 + 1 and g.type == "granary" and not g.built and g.paid, "the Steward lays out a paid Granary site")
	check(is_equal_approx(wood0 - sim.stock["wood"], D.STRUCTURES["granary"]["wood"]), "its wood comes from the stockpile")
	check(D.region_at(g.pos) == D.region_at(D.VILLAGE) and not D.is_water(g.pos) and g.pos.distance_to(D.VILLAGE) < 450, "on dry land by the village (%s)" % str(g.pos))
	var clash: bool = sim.structures.any(func(s): return s != g and not D.STRUCTURES[s.type].get("ring", false) and s.pos.distance_to(g.pos) < D.STRUCTURES[s.type]["r"] + D.STRUCTURES["granary"]["r"])
	check(not clash, "not on top of another building")
	imp.update(100.0)
	check(sim.structures.size() == n0 + 1, "one site at a time (max_sites 1)")
	# finish it: a second Granary only when the stores fill up again
	g.built = true
	g.progress = g.work
	sim.stock["food"] = 10
	imp.update(100.0)
	check(not sim.structures.any(func(s): return s.type == "granary" and not s.built), "no new Granary while the stores have room")
	for s in sim.structures: s.built = true # (whatever else was laid out meanwhile)
	# several wants: the advisor is asked, and only its options can be chosen
	sim.stock["food"] = sim.food_cap()
	sim.stock["wood"] = 200
	sim.techs["farming"] = true
	var asked := []
	sim.advice_wanted.connect(func(ctx): asked.append(ctx))
	var opts: Array = imp.wanted().map(func(r): return r["structure"])
	imp.update(100.0)
	if opts.size() > 1:
		check(asked.size() == 1 and asked[0]["options"].size() == opts.size() and not asked[0]["leader"].is_empty(), "with several wants the Steward's node is asked (%s)" % str(opts))
		var n1: int = sim.structures.size()
		imp.choose("smelter", "Bronze!") # not an option: the first one is built
		check(sim.structures.size() == n1 + 1 and sim.structures.back().type == opts[0], "an answer outside the options falls back to the first want")
	else:
		check(false, "expected several wants, got %s" % str(opts))
	# a game master's order and the summary
	sim.structures.back().built = true
	var why: String = imp.order("hut")
	check(why == "", "a game master can order an improvement (no conditions) %s" % why)
	check(imp.order("castle") == "Unknown structure", "unknown structures are refused")
	var sm: Dictionary = imp.summary()
	check(sm["on"] and sm["planner"] == st.name and sm.has("wanted"), "the planner's state is readable (%s)" % str(sm))
	check("granary" in D.CONTRACT_STRUCTURES, "settlement contracts may build a Granary")

func test_audio() -> void:
	print("\n== Sound and music (config/audio.json, synth.gd) ==")
	var C: Dictionary = preload("res://scripts/config.gd").load_cfg("audio")
	var sounds: Dictionary = C["sounds"]
	var silent: Array = []
	for id in ["chop", "flute", "wind", "drum_low"]:
		var w: AudioStreamWAV = preload("res://scripts/synth.gd").render(sounds[id])
		var pk := 0
		for i in range(0, w.data.size(), 2): pk = maxi(pk, absi(w.data.decode_s16(i)))
		if pk < 1000 or w.get_length() <= 0.0: silent.append(id)
	check(silent.is_empty(), "recipes render to audible sounds (%s)" % str(silent))
	var w2: AudioStreamWAV = preload("res://scripts/synth.gd").render(sounds["wind"])
	check(w2.loop_mode == AudioStreamWAV.LOOP_FORWARD, "loops loop")
	# every sound the rules name exists
	var used: Array = []
	for k in ["on_log", "on_alert", "on_signal", "on_happening"]: used += C[k].values()
	used.append(C["ui_click"])
	for j in C["jobs"]["list"]: used.append(j["sound"])
	used.append(C["jobs"]["beasts"]["sound"])
	for a in C["ambience"] + C["random"]: used.append(a["sound"])
	for m in C["music"]["moods"]: used += m["drums"].keys()
	used += ["flute", "drone"]
	var missing: Array = used.filter(func(id): return not sounds.has(id))
	check(missing.is_empty(), "every sound named in the rules has a recipe (%s)" % str(missing))
	var sim = _new_sim()
	var bad: Array = C["on_signal"].keys().filter(func(sg): return not sim.has_signal(sg))
	check(bad.is_empty(), "on_signal names real sim signals (%s)" % str(bad))
	var cues := []
	sim.sound_cue.connect(func(id, at): cues.append([id, at]))
	sim.story.run([{"sound": "horn", "at": "village"}], null)
	check(cues.size() == 1 and cues[0][0] == "horn" and cues[0][1] == D.VILLAGE, "the story action \"sound\" cues a sound at a place")
	var heard := []
	sim.happened.connect(func(id): heard.append(id))
	sim.cult.on_event("lightning")
	check(heard == ["lightning"], "nature's happenings reach the sound (sim.happened)")

func test_save_load() -> void:
	print("\n== Save and load ==")
	var SG = preload("res://scripts/save_game.gd")
	var a = _new_sim()
	a.appoint(a.living()[0], "steward")
	var u = a.unit_by_name("Panshi")
	var r := Persona.propose(a.contracts.negotiation_ctx(u, "Found a new settlement on the frontier", {}, false))
	a.contracts.create(a.contracts.sanitize(r["blueprint"], {}, u)["blueprint"], u, "Found a new settlement on the frontier")
	for i in 600: a.tick(0.05)
	var settings := {"map": "the_ford", "tribes": 0, "seed": 1, "culture": ""}
	check(SG.write("test_slot", a, settings, {"cam": Vector2(1, 2)}) == "", "the game is written to a slot")
	var data: Dictionary = SG.read("test_slot")
	check(not data.is_empty() and data["settings"]["map"] == "the_ford" and data["extra"]["cam"] == Vector2(1, 2), "and read back with its settings")
	check(SG.slots().any(func(h): return h["slot"] == "test_slot" and h["day"] == a.day()), "the save list shows it (day %d)" % a.day())
	var b = _new_sim()
	SG.decode_into(b, data["sim"])
	check(is_equal_approx(b.time, a.time) and b.units.size() == a.units.size() and b.structures.size() == a.structures.size() and b.nodes.size() == a.nodes.size(), "time, people, buildings and nature come back")
	var same := true
	for i in a.units.size():
		if a.units[i].pos != b.units[i].pos or a.units[i].name != b.units[i].name or a.units[i].job != b.units[i].job: same = false
	check(same, "everyone is where they were, doing what they did")
	check(b.stock == a.stock and b.techs == a.techs and b.vice == a.vice and b.explored == a.explored, "stocks, wisdom, roles and the explored land")
	check(b.evo.sim == b and b.improve.sim == b and b.contracts.list.size() == a.contracts.list.size(), "the sub-systems point at the loaded game")
	check(b.unit_by_id(a.living()[0].id).title == "Steward", "the Steward is still the Steward")
	# the same future: both games run on from the same random seed
	seed(99)
	for i in 400: a.tick(0.05)
	seed(99)
	for i in 400: b.tick(0.05)
	var drift: Array = []
	for i in mini(a.units.size(), b.units.size()):
		if a.units[i].pos.distance_to(b.units[i].pos) > 0.01: drift.append(a.units[i].name)
	check(drift.is_empty() and a.units.size() == b.units.size() and is_equal_approx(a.stock["food"], b.stock["food"]), "a loaded game plays on exactly as the saved one would (%s)" % str(drift))
	check(SG.read("../evil") .is_empty() and SG.write("a/b", a, settings) != "", "slot names can't leave the saves folder")
	SG.remove("test_slot")
	check(SG.read("test_slot").is_empty(), "a save can be removed")

func test_renovate_settlements() -> void:
	print("\n== Renovating the settlements too ==")
	var sim = _new_sim()
	for p in sim.predators: p.fled = true
	var site: Vector2 = sim.contracts.next_site()
	var c := E.Contract.new()
	c.id = sim.uid(); c.kind = "settle"; c.status = "done"; c.site = site
	sim.contracts.list.append(c)
	var huts: Array = []
	for i in 2: huts.append(sim.add_structure("hut", site + Vector2(60 * i - 30, 40), true, "contract:%d" % c.id))
	var settlers: Array = sim.living().slice(0, 2)
	for u in settlers:
		u.home = site
		u.pos = site + Vector2(10, 0)
		sim.set_job(u, {})
	sim.techs["fire"] = true
	sim.techs["pottery"] = true
	sim.evo.era = 2
	var old: Array = sim.outdated()
	check(huts.all(func(h): return h in old), "a settlement's old huts are outdated too (%d in all)" % old.size())
	sim.stock["wood"] = 300
	check(sim.renovate([]) == "", "renovation starts")
	check(settlers.any(func(u): return u.job.get("type", "") == "build" and huts.any(func(h): return h.id == u.job.get("struct_id", -1))), "the settlers rebuild their own huts")
	check(not sim.living().any(func(u): return u.home.distance_to(D.VILLAGE) < 60 and huts.any(func(h): return h.id == u.job.get("struct_id", -1))), "the village's people stay home")
	_run(sim, 120)
	check(huts.all(func(h): return h.style == 2 and not h.reno), "the settlement's huts are rebuilt in mud & thatch")
	check(sim.structures.filter(func(s): return s.owner == "village" and s.type == "hut" and s.style == 2).size() >= 2, "and the village's too")

func test_building_panel() -> void:
	print("\n== One building at a time: renovate, upgrade, demolish ==")
	var sim = _new_sim()
	for p in sim.predators: p.fled = true
	var hut = sim.structures.filter(func(s): return s.type == "hut" and s.built)[0]
	sim.stock["wood"] = 100
	var ups: Array = sim.upgrades_for(hut)
	check(ups.size() == 1 and ups[0]["to"] == "large_hut" and ups[0]["why"] == "", "a Hut can become a Large Hut (%s)" % str(ups))
	var diff: int = ups[0]["wood"]
	check(diff == D.STRUCTURES["large_hut"]["wood"] - D.STRUCTURES["hut"]["wood"], "for the difference in wood (%d)" % diff)
	var shrine = sim.add_structure("totem_shrine", D.VILLAGE + Vector2(-150, 120), true)
	check(sim.upgrades_for(shrine)[0]["why"] != "", "a Grand Altar needs its wisdom first")
	check(sim.upgrade(hut.id, "palisade") != "", "only the upgrade paths in config")
	var w0: float = sim.stock["wood"]
	check(sim.upgrade(hut.id, "large_hut") == "" and is_equal_approx(w0 - sim.stock["wood"], diff), "the upgrade starts and is paid")
	check(hut.reno and hut.upgrade == "large_hut" and hut.built, "the hut stays a home while it is rebuilt")
	check(sim.living().any(func(u): return u.job.get("struct_id", -1) == hut.id), "someone goes to do the work")
	check(sim.upgrades_for(hut)[0]["why"] != "", "no second upgrade while one is going")
	var data: Dictionary = preload("res://scripts/save_game.gd").encode(sim)
	var sim2 = _new_sim()
	preload("res://scripts/save_game.gd").decode_into(sim2, data)
	check(sim2.struct_by_id(hut.id).upgrade == "large_hut", "an upgrade under way is saved")
	_run(sim, 90)
	check(hut.type == "large_hut" and not hut.reno and hut.upgrade == "" and hut.work == D.STRUCTURES["large_hut"]["work"], "it becomes a Large Hut")
	# renovate one
	sim.techs["fire"] = true
	sim.techs["pottery"] = true
	sim.evo.era = 2
	var other = sim.structures.filter(func(s): return s.type == "hut" and s.built and s.style == 1)[0]
	var n_old: int = sim.outdated().size()
	check(sim.renovate_one(other.id) == "" and other.reno and sim.outdated().size() == n_old - 1, "one old hut can be renovated on its own")
	# demolish
	var bonfire = sim.add_structure("bonfire", D.VILLAGE + Vector2(200, 200), true)
	w0 = sim.stock["wood"]
	check(sim.demolish(bonfire.id) == "" and sim.struct_by_id(bonfire.id) == null, "a building can be pulled down")
	check(is_equal_approx(sim.stock["wood"] - w0, floorf(D.STRUCTURES["bonfire"]["wood"] * 0.5)), "giving back half its wood")
	var site = sim.place_structure("hut", D.VILLAGE + Vector2(260, -200))
	w0 = sim.stock["wood"]
	sim.demolish(site.id)
	check(is_equal_approx(sim.stock["wood"] - w0, D.STRUCTURES["hut"]["wood"]), "a cancelled building site gives all its wood back")
	var sleeper = sim.living()[0]
	sleeper.bed_id = other.id
	sim.demolish(other.id)
	check(sleeper.bed_id == -1, "whoever slept there needs a new bed")
	var bg = sim.add_structure("burial_ground", D.VILLAGE + Vector2(-300, -300), true)
	check(sim.demolish(bg.id) != "" and sim.struct_by_id(bg.id) != null, "the burial ground is never pulled down")
	# the Steward upgrades a hut when beds run short
	var s3 = _new_sim()
	s3.time = D.DAY_LEN * 0.3
	s3.stock["wood"] = 200
	s3.appoint(s3.living()[0], "steward")
	var kid := 0
	while s3.living().size() <= s3.pop_cap():
		kid += 1
		s3.units.append(s3.folk.make_child("Kid%d" % kid, null))
	var wants: Array = s3.improve.wanted().map(func(r): return r["structure"])
	check("large_hut" in wants, "with people sleeping out, a bigger hut is wanted (%s; %d people, %d beds)" % [str(wants), s3.living().size(), s3.pop_cap()])
	s3.improve.choose("", "") # (nothing asked: no-op)
	s3.improve.update(100.0)
	check(s3.structures.any(func(s): return s.upgrade == "large_hut"), "and the Steward has one made bigger")

func test_wall_radius() -> void:
	print("\n== A palisade of the size you choose ==")
	var sim = _new_sim()
	sim.stock["wood"] = 200
	var base: Dictionary = D.STRUCTURES["palisade"]
	check(sim.ring_radius("palisade", 0.0) == base["r"] and sim.ring_radius("palisade", 1000.0) == 300.0 and sim.ring_radius("palisade", 7.0) == 60.0 and sim.ring_radius("palisade", 173.0) == 170.0, "radii are clamped and snapped (config buildings.ring)")
	var w0: float = sim.stock["wood"]
	var p = sim.place_structure("palisade", D.VILLAGE, 200.0)
	check(p != null and p.size == 200.0, "a wall is laid out at the chosen radius")
	check(is_equal_approx(w0 - sim.stock["wood"], base["wood"] * 2) and is_equal_approx(p.work, base["work"] * 2), "twice the ring, twice the wood and work")
	check(sim.place_structure("palisade", D.VILLAGE, 300.0) == null or sim.stock["wood"] >= 0, "and it must be affordable")
	p.built = true
	var u = sim.living()[0]
	u.pos = D.VILLAGE + Vector2(190, 0)
	check(sim.inside_wall(u.pos), "someone 190 from the middle is inside a 200 ring")
	var d_in: float = sim.unit_def(u)
	u.pos = D.VILLAGE + Vector2(260, 0)
	check(not sim.inside_wall(u.pos) and sim.unit_def(u) < d_in, "and outside it loses the wall's defence")
	var small = sim.place_structure("palisade", D.VILLAGE + Vector2(600, 0))
	check(small and small.size == base["r"], "without a choice it is the usual size")
	var data: Dictionary = preload("res://scripts/save_game.gd").encode(sim)
	var s2 = _new_sim()
	preload("res://scripts/save_game.gd").decode_into(s2, data)
	check(s2.struct_by_id(p.id).size == 200.0, "the chosen size is saved")

func test_policies() -> void:
	print("\n== The Council's policies (config/policies.json) ==")
	var sim = _new_sim()
	var P = sim.policy
	check(P.open_ids().size() == 6 and P.chosen["way_of_life"] == "mixed" and P.chosen["clans"] == "wary", "six policies, each with its default way (%s)" % str(P.summary()))
	check(P.effects().is_empty(), "the default ways change nothing: the base game")
	check(P.block("way_of_life", "tillers") != "", "Tillers need Farming first")
	check(P.set_choice("nonsense", "x") != "" and P.set_choice("forest", "nonsense") != "", "unknown policies and choices are refused")
	var mood0: float = sim.folk.mood
	var hunt0: float = sim.inv.mul("gather", "hunt/deer")
	check(P.set_choice("way_of_life", "hunters", "test") == "", "the Council decides: Hunters")
	check(sim.folk.mood < mood0 and P.pending.has("way_of_life") and P.chosen["way_of_life"] == "mixed", "it costs a little mood and takes time to take hold")
	check(P.block("way_of_life", "foragers") != "", "and can't be changed again right away")
	sim.time += D.DAY_LEN * 1.1
	P.update(0.1)
	check(P.chosen["way_of_life"] == "hunters" and sim.inv.mul("gather", "hunt/deer") > hunt0, "once it holds, hunting goes better (x%.2f)" % sim.inv.mul("gather", "hunt/deer"))
	# hunters go for deer first
	var deer = null
	for n in sim.nodes:
		if n.kind == "deer" and deer == null: deer = n
	var mid: Vector2 = deer.pos + Vector2(60, 0) # a deer and a bush equally far from here, nothing else near
	sim.nodes = sim.nodes.filter(func(n): return n == deer or n.res != "food" or n.pos.distance_to(mid) > 200)
	var bush = sim.add_node("bush", "food", mid + Vector2(60, 0), 30)
	var pick = sim.find_node("food", mid, -1, 150.0)
	check(pick == deer, "the hunters' way: gatherers seek deer before berries (picked %s)" % (pick.kind if pick else "nothing"))
	# the forest grows back faster when only dead wood is taken
	sim.time += D.DAY_LEN * 3
	P.set_choice("forest", "dead_wood")
	sim.time += D.DAY_LEN * 1.1
	P.update(0.1)
	check(is_equal_approx(sim.inv.mul("regrow"), 1.8) and sim.inv.mul("gather", "chop/tree") < 1.0, "dead wood only: the forest regrows x1.8, wood comes slower")
	# what to seek: insight on the chosen ideas grows faster
	var s2 = _new_sim()
	var u2 = s2.living()[0]
	s2.evo.practice(u2, "chop", 10.0)
	var plain: float = s2.evo.insight["tools"]
	var s3 = _new_sim()
	s3.policy.chosen["seek"] = "craft"
	s3.policy.rev += 1
	s3.evo.practice(s3.living()[0], "chop", 10.0)
	check(s3.evo.insight["tools"] > plain * 1.5, "seeking Craft: Polished Stone Tools comes faster (%.2f vs %.2f)" % [s3.evo.insight["tools"], plain])
	# the clans warm to a peaceful tribe
	var s4 = _new_sim()
	var s5 = _new_sim()
	s5.policy.chosen["clans"] = "peace"
	s5.policy.rev += 1
	for i in 2000:
		s4.rivals.update(0.5)
		s5.rivals.update(0.5)
	var cid: String = s4.rivals.clans.keys()[0]
	check(s5.rivals.clans[cid]["relation"] > s4.rivals.clans[cid]["relation"] + 3, "Peace first: the clans' feelings settle warmer (%.1f vs %.1f)" % [s5.rivals.clans[cid]["relation"], s4.rivals.clans[cid]["relation"]])
	# culture drifts with the ways, and a new way may run its on_start actions
	var s6 = _new_sim()
	s6.techs["fire"] = true
	var dev0: float = s6.devotion + 20.0
	s6.devotion = dev0
	s6.policy.set_choice("forest", "burn")
	s6.time += D.DAY_LEN * 1.1
	s6.policy.update(0.1)
	check(s6.devotion < dev0, "burning the forest troubles the spirits (devotion %.0f -> %.0f)" % [dev0, s6.devotion])
	var mart0: float = s6.evo.culture["martial"]
	s6.policy.chosen["clans"] = "warlike"
	s6.time += D.DAY_LEN
	s6.policy.update(0.1)
	check(s6.evo.culture["martial"] > mart0, "a warlike tribe grows more martial every day")
	# the Council: those who like and dislike it speak
	var talk: Array = s6.policy.council("hunt", "all")
	check(not talk.is_empty() and talk.all(func(t): return t["side"] in ["pro", "con"] and t["line"] != ""), "the elders speak for and against (%s)" % str(talk.map(func(t): return "%s:%s" % [t["who"].name, t["side"]])))
	var bel: Array = talk.filter(func(t): return "belligerent" in t["who"].traits)
	check(bel.all(func(t): return t["side"] == "pro"), "the belligerent want to hunt everything")
	check(not s6.policy.council_ctx("hunt", "all")["speakers"].is_empty(), "the LLM gets the speakers and their profiles")
	check("the_ways_the_tribe_lives_by" in s6.evo.world_ctx() and not s6.evo.world_ctx()["the_ways_the_tribe_lives_by"].is_empty(), "every persona knows the tribe's ways")
	# saved with the game
	var data: Dictionary = preload("res://scripts/save_game.gd").encode(sim)
	var s7 = _new_sim()
	preload("res://scripts/save_game.gd").decode_into(s7, data)
	check(s7.policy.chosen["way_of_life"] == "hunters" and s7.policy.chosen["forest"] == "dead_wood" and is_equal_approx(s7.inv.mul("regrow"), 1.8), "the ways are saved")

func test_leaders_and_the_ways() -> void:
	print("\n== Leaders push back on the tribe's ways ==")
	var sim = _new_sim()
	var devout = null
	for u in sim.living():
		if "devout" in u.traits and u.role == "": devout = u
	check(devout != null, "the tribe has a devout leader")
	if devout == null: return
	check(sim.policy.objection(devout, "settle").is_empty(), "under the default ways nobody objects")
	sim.techs["fire"] = true
	sim.policy.chosen["forest"] = "burn"
	sim.policy.rev += 1
	var ob: Dictionary = sim.policy.objection(devout, "settle")
	check(ob.get("policy", "") == "forest" and ob.get("wants", "") == "dead_wood", "a devout leader objects to burning the forest and wants dead wood only (%s)" % str(ob))
	check(sim.policy.objection(devout, "research").is_empty(), "but only for tasks the way touches")
	var ctx: Dictionary = sim.contracts.negotiation_ctx(devout, "Found a new settlement on the frontier", {}, false)
	check(not ctx["objection"].is_empty(), "the negotiation tells the persona")
	var r := Persona.propose(ctx)
	check(tr(sim.policy.choice_def("forest", "burn")["con"]) in r["speech"], "the offline persona voices it first (%s)" % r["speech"].left(120))
	# the ways stand: a sullen crew
	var san: Dictionary = sim.contracts.sanitize(r["blueprint"], {}, devout)
	var c = sim.contracts.create(san["blueprint"], devout, "x")
	var w0: float = sim.work_mul(devout)
	sim.policy.answer(devout, ob, false, c)
	check(c.flags.get("sullen", false) and sim.work_mul(devout) < w0, "if the ways stand, the crew works slower (%.2f -> %.2f)" % [w0, sim.work_mul(devout)])
	check(devout.memory.any(func(m): return "not heard" in m["text"]), "and the leader remembers")
	# heard: the way changes
	var s2 = _new_sim()
	var d2 = s2.unit_by_name(devout.name)
	s2.techs["fire"] = true
	s2.policy.chosen["forest"] = "burn"
	check(s2.policy.answer(d2, s2.policy.objection(d2, "settle"), true) == "" and s2.policy.pending.get("forest", {}).get("choice", "") == "dead_wood", "hearing them out changes the way (after a day)")
	check(d2.memory.any(func(m): return "was heard" in m["text"]), "and they remember being heard")
	# a war party under Peace first
	var s3 = _new_sim()
	s3.policy.chosen["clans"] = "peace"
	check(not s3.policy.warnings("war").is_empty() and s3.policy.warnings("settle").is_empty(), "the negotiation warns of war under Peace first")
	for id in ["ochre", "heron"]: s3.rivals.clans[id]["met"] = true
	s3.rivals.pending.clear()
	var wl = s3.unit_by_name("Alie")
	var wterms := {"kind": "war", "target": "heron", "objective": "loot", "crew_size": 4}
	var wctx: Dictionary = s3.contracts.negotiation_ctx(wl, "Raid", wterms, true, "", {}, [], "war")
	var wsan: Dictionary = s3.contracts.sanitize(Persona.propose(wctx)["blueprint"], wterms, wl)
	var mood0: float = s3.folk.mood
	var rel0: float = s3.rivals.clans[wsan["blueprint"]["target"]]["relation"]
	s3.contracts.create(wsan["blueprint"], wl, "Raid")
	check(s3.folk.mood < mood0 and s3.rivals.clans[wsan["blueprint"]["target"]]["relation"] < rel0, "a war party under Peace first troubles the tribe and the clan remembers")

func test_crisis() -> void:
	print("\n== Emergency mode (config/emergency.json) ==")
	var sim = _new_sim()
	var K = sim.crisis
	K.on = true
	for p in sim.predators: p.fled = true
	var v = sim.unit_by_name("Tuo")
	v.pos = D.VILLAGE + Vector2(160, 60)
	sim.assign_gather(v, "wood")
	var job0: Dictionary = v.job.duplicate()
	var tiger = sim.spawn_predator(v.pos + Vector2(30, 0), v.pos)
	v.last_hit_t = sim.time
	v.attacker_id = tiger.id
	K.update(0.05)
	check(K.active() and v in K.people() and K.title() != "", "a beast striking one of ours starts a crisis (%s, %d people)" % [K.title(), K.people().size()])
	check(K.slow() < 1.0, "and time slows (x%.2f)" % K.slow())
	check(K.order_block("torches") != "", "torches need fire first")
	check(K.order("fight") == "" and v.job.get("type", "") == "attack" and v.job.get("crisis", false) and v.resume_job.get("type", "") == job0["type"], "Fight!: they go for the beast, and their work waits")
	var d0: float = sim.unit_def(v)
	check(K.order("rally") == "" and not K.buff.is_empty(), "Rally to me")
	var best = null
	for u in K.people():
		if best == null or sim.unit_atk(u) > sim.unit_atk(best): best = u
	check(sim.crisis.def_bonus(best) > 0.0 and sim.unit_def(best) > sim.unit_def(best) - 0.01, "close to the rally point, everyone defends better (+%.0f)" % sim.crisis.def_bonus(best))
	sim.techs["fire"] = true
	sim.stock["wood"] = 50
	check(K.order("torches") == "" and tiger.fleeing and is_equal_approx(sim.stock["wood"], 44.0), "Torches!: the beast flees, for 6 wood")
	var s0: int = K.summary()["threats"]
	check(s0 == 0, "no threat left once it flees")
	check(K.order("torches") != "" and is_equal_approx(sim.stock["wood"], 44.0), "with nothing left to scare, torches are refused and cost nothing")
	check(K.order_block("fight") != "", "and with no threat there is nothing to fight")
	for u in K.people(): u.hp = u.max_hp
	check(K.order_block("wounded") != "", "nobody badly hurt: no one to tend")
	# it ends when all is quiet: everyone back to work, and they remember
	for i in 140: K.update(0.05)
	check(not K.active(), "when it is quiet, the crisis ends")
	check(v.memory.any(func(m): return "stood together" in m["text"]), "the people in it remember it")
	check(v.job.get("type", "") == job0["type"] and not v.job.get("crisis", false), "and go back to their work (%s)" % v.job.get("type", ""))
	# no new crisis right away
	var wolf = sim.spawn_predator(v.pos + Vector2(20, 0), v.pos)
	wolf.kind = "wolf"
	v.last_hit_t = sim.time
	v.attacker_id = wolf.id
	K.update(0.05)
	check(not K.active(), "a cooldown before the next one")
	sim.time += 60
	v.last_hit_t = sim.time
	K.update(0.05)
	check(K.active() and K.cur["kind"] == "wolf", "then wolves start one of their own")
	check(K.order("fall_back") == "" and K.people().all(func(u): return u.job.get("type", "") == "shelter"), "Fall back: everyone runs for the huts")
	K.end("handed")
	check(not K.active() and K.slow() == 1.0 and K.people().is_empty(), "the chieftain can hand it back")
	check(v.job.get("type", "") != "shelter", "and the people come out again")
	# taking command of a contract's crew
	var s2 = _new_sim()
	s2.crisis.on = true
	var crew: Array = s2.living().slice(0, 3)
	check(s2.crisis.start("contract", D.VILLAGE + Vector2(500, 0), crew, 7) and s2.crisis.people().size() == 3, "a contract's crew can be taken in hand")
	check(s2.crisis.order("ring_fire") == "" and crew.all(func(u): return u.job.get("hold", false)), "To the fire: they run to the bonfire and stay")
	check(s2.crisis.summary()["active"] and s2.crisis.summary()["people"].size() == 3, "a game master can read it")
	var data: Dictionary = preload("res://scripts/save_game.gd").encode(s2)
	var s3 = _new_sim()
	preload("res://scripts/save_game.gd").decode_into(s3, data)
	check(s3.crisis.active() and s3.crisis.cur["kind"] == "contract", "a crisis under way is saved")

func test_director() -> void:
	print("\n== The director paces the hardships (config/director.json) ==")
	var sim = _new_sim()
	var Dr = sim.director
	Dr.on = true
	check(not Dr.active() and Dr.allow("blizzard"), "with the challenges off it rests")
	sim.hz.level = "normal"
	check(Dr.active() and Dr.cap() == 3.0, "on Normal it allows up to 3 tension")
	Dr.note("blizzard")
	Dr.note("blizzard")
	check(is_equal_approx(Dr.tension, 1.5), "a blizzard counts once, however often it is reported")
	Dr.note("clan_raid")
	check(not Dr.allow("eruption") and not Dr.allow("lightning") and Dr.allow("rain"), "after a blizzard and a raid (3.0): no eruption, not even lightning; rain still may (%.1f)" % Dr.tension)
	Dr.note("death")
	Dr.note("death")
	check(is_equal_approx(Dr.tension, 6.0), "every death counts")
	var t0: float = Dr.tension
	Dr.update(D.DAY_LEN)
	check(is_equal_approx(Dr.tension, t0 - 1.6), "tension eases by 1.6 a day")
	# a held-back hardship waits: a tiger raid comes back later
	sim.time = D.DAY_LEN * 10
	sim.hz.raid_t = 0.0
	sim.hz._raids(0.1)
	check(is_equal_approx(sim.hz.raid_t, Dr.retry()), "a tiger raid is put off (retry in %ds)" % Dr.retry())
	var cid: String = sim.rivals.clans.keys()[0]
	var c: Dictionary = sim.rivals.clans[cid]
	c["relation"] = -80.0
	c["raid_t"] = 0.0
	var preds0: int = sim.predators.size()
	sim.rivals._raids(c, 0.1)
	check(sim.predators.size() == preds0 and is_equal_approx(c["raid_t"], Dr.retry()), "a clan raid too")
	Dr.tension = 0.0
	Dr.deaths.clear() # (and out of distress: the deaths above put the tribe under mercy's cap)
	Dr.distress = false
	c["raid_t"] = 0.0
	sim.rivals._raids(c, 0.1)
	check(sim.predators.size() > preds0 or "demand_" + cid in sim.rivals.pending, "once the tribe has breathed, it comes")
	check(Dr.tension > 0.0, "and counts")
	# harsh allows more
	Dr.deaths.clear()
	Dr.distress = false
	sim.hz.level = "harsh"
	check(Dr.cap() == 5.0, "Harsh allows up to 5")
	# mercy: a tribe going under gets a breath and a gift
	var s2 = _new_sim()
	s2.director.on = true
	s2.hz.level = "normal"
	s2.stock["food"] = 1.0
	s2.director.update(10.0)
	check(s2.director.distress and s2.director.cap() == 0.5, "with the food gone the tribe is in distress: hardly anything more may come")
	s2.director.tension = 0.0
	check(not s2.director.allow("earthquake") and s2.director.allow("lightning"), "even with no tension, a tribe in distress is spared heavy blows")
	check(s2.stock["food"] >= 20.0, "and a gift helps it through (food %d)" % s2.stock["food"])
	var f1: float = s2.stock["food"]
	s2.stock["food"] = 1.0
	s2.director.update(10.0)
	check(s2.stock["food"] < 2.0, "not every time: the next gift waits days")
	check(s2.director.summary()["distress"] and s2.director.summary().has("tension"), "a game master can read it")
	var data: Dictionary = preload("res://scripts/save_game.gd").encode(s2)
	var s3 = _new_sim()
	preload("res://scripts/save_game.gd").decode_into(s3, data)
	check(s3.director.mercy_ready == s2.director.mercy_ready, "the director's state is saved")

func test_names() -> void:
	print("\n== Names for the newborn (config/names.json) ==")
	var N = preload("res://scripts/names.gd")
	check(N.count() > 5000, "the parts make thousands of names (%d)" % N.count())
	var sim = _new_sim()
	var taken := {}
	for u in sim.units: taken[u.name] = true
	var made: Array = []
	for i in 400:
		var nm: String = N.pick(taken)
		taken[nm] = true
		made.append(nm)
	var uniq := {}
	for nm in made: uniq[nm] = true
	check(uniq.size() == 400 and not made.has("Nameless"), "400 newborns, 400 different names (%s...)" % ", ".join(made.slice(0, 6)))
	var Ncfg: Dictionary = preload("res://scripts/config.gd").load_cfg("names")
	var surnames: Array = Ncfg["surnames"].map(func(s): return s[0] + " ")
	var adjs: Array = Ncfg["adjectives"].map(func(a): return a[0] + " ")
	var clan: int = made.filter(func(n): return surnames.any(func(s): return n.begins_with(s))).size()
	var nature: int = made.filter(func(n): return adjs.any(func(a): return n.begins_with(a))).size()
	check(clan > 50 and nature > 150, "both nature names (%d) and clan names (%d)" % [nature, clan])
	I18N.setup("zh")
	var bad: Array = made.filter(func(n): return I18N.t(n) == n or I18N.t(n).length() != 2)
	check(bad.is_empty(), "every one has a two-character Chinese name (%s; bad: %s)" % [", ".join(made.slice(0, 6).map(func(n): return I18N.t(n))), ", ".join(bad.map(func(n): return "%s=%s" % [n, I18N.t(n)]))])
	I18N.setup("en")
	# when the culture's names run out, the tribe still names its children
	D.BIRTH_NAMES = []
	sim.stock["food"] = 500
	sim.birth_timer = 9999.0
	var n0: int = sim.units.size()
	for i in 3:
		sim.birth_timer = 9999.0
		sim._update_births(0.1)
	var kids: Array = sim.units.slice(n0)
	check(kids.size() >= 1 and kids.all(func(u): return u.name != "Nameless" and u.name != ""), "newborns get built names (%s)" % ", ".join(kids.map(func(u): return u.name)))
	D.BIRTH_NAMES = D.BASE_BIRTH_NAMES.duplicate()

func test_lands() -> void:
	print("\n== The kind of land (config/lands.json) ==")
	var Lands = preload("res://scripts/lands.gd")
	Scenarios.apply()
	check(D.LAND.get("id", "") == "parkland" and float(D.LAND["woods"]["follow"]) == 0.0, "The Ford is parkland, its woods as they always were")
	var trees := {}
	var deer := {}
	var lands := {}
	for land in ["steppe", "parkland", "woodland", "old_forest"]:
		MapGen.generate("standard", 3, 4242, land)
		seed(4242)
		var sim = _new_sim()
		trees[land] = sim.nodes.filter(func(n): return n.kind == "tree").size()
		deer[land] = sim.nodes.filter(func(n): return n.kind == "deer").size()
		lands[land] = D.LAND.duplicate(true)
	print("   trees: ", trees, "  deer: ", deer)
	check(trees["steppe"] < trees["parkland"] and trees["parkland"] < trees["woodland"] and trees["woodland"] < trees["old_forest"], "the steppe has the fewest trees, the old forest the most")
	check(deer["steppe"] > deer["parkland"] and deer["old_forest"] < deer["parkland"], "open land carries more deer, deep forest fewer")
	check(Lands.weather(lands["steppe"], "drought") > 1.0 and Lands.weather(lands["old_forest"], "drought") < 1.0 and Lands.weather(lands["parkland"], "drought") == 1.0, "a steppe has more droughts, a forest fewer")
	check(float(lands["steppe"]["moisture"]) < 0.35 and float(lands["old_forest"]["moisture"]) > 0.7, "and the grass follows: dry steppe, damp forest")
	# the same seed makes the same land; random picks vary between seeds
	var a: Dictionary = Lands.resolve("random", 123)
	var b: Dictionary = Lands.resolve("random", 123)
	check(a == b, "the same seed, the same land")
	var seen := {}
	for s in 60: seen[Lands.resolve("random", s)["id"]] = true
	check(seen.size() >= 3, "random maps get different lands (%s)" % str(seen.keys()))
	var base: float = Lands.cfg()["lands"]["woodland"]["woods"]["count"]
	var j: float = Lands.cfg()["jitter"]
	var counts: Array = range(30).map(func(s): return Lands.resolve("woodland", s)["woods"]["count"])
	check(counts.all(func(c): return c >= base * (1.0 - j) - 0.001 and c <= base * (1.0 + j) + 0.001) and counts.max() - counts.min() > base * j * 0.5, "a land's numbers vary a little from map to map, within its bounds")
	MapGen.generate("standard", 3, 4242, "steppe")
	var sim2 = _new_sim()
	check(sim2.evo.world_ctx().get("the_land", "").contains("Steppe"), "the personas know the land they live on")
	Scenarios.apply()

func test_roads() -> void:
	print("\n== Trails and roads (config/roads.json) ==")
	var sim = _new_sim()
	var R = sim.roads
	check(R.level.size() == sim.wear.size() and R.summary()["cells"].is_empty(), "the land starts without roads")
	# feet make a trail
	var p: Vector2 = D.VILLAGE + Vector2(200, 0)
	var k: int = R.cell(p)
	sim.wear[k] = 0.7
	R._t = 0.0
	R.update(0.1)
	check(R.level[k] == 1 and R.speed_at(p) > 1.0, "where people walk again and again, a trail appears (x%.2f speed)" % R.speed_at(p))
	var u = sim.living()[0]
	u.pos = p
	var on_trail: float = sim.unit_speed(u)
	u.pos = D.VILLAGE + Vector2(-600, 300)
	check(on_trail > sim.unit_speed(u), "and people walk faster on it")
	sim.wear[k] = 0.05
	for i in int(R.C["fade_days"] * D.DAY_LEN) + 5:
		R._t = 0.0
		R.update(0.1)
	check(R.level[k] == 0, "an abandoned trail fades back into grass")
	# roads must be learned
	check(R.build_block(2) != "" and R.lay(D.VILLAGE, D.VILLAGE + Vector2(300, 0), "packed") != "", "roads can't be built before Road Making")
	sim.techs["tools"] = true
	sim.inv.discover("road_making", u)
	check(R.build_block(2) == "" and R.build_block(3) != "", "Road Making allows packed-earth roads; stone needs bronze")
	# a trail makes the road cheaper
	var a: Vector2 = D.VILLAGE + Vector2(60, 200)
	var b: Vector2 = D.VILLAGE + Vector2(420, 200)
	var cells: Array = R.plan(a, b, 2)
	var full: Dictionary = R.cost(cells, 2)
	for c in cells.slice(0, cells.size() / 2): R.level[c] = 1
	check(R.cost(cells, 2)["wood"] < full["wood"], "over a trail a road costs less (%d vs %d wood)" % [R.cost(cells, 2)["wood"], full["wood"]])
	sim.stock["wood"] = 200
	var w0: float = sim.stock["wood"]
	var workers: Array = sim.living().filter(func(x): return x.role == "").slice(0, 3)
	check(R.lay(a, b, "packed", workers) == "" and sim.stock["wood"] < w0, "a packed-earth road is laid out and paid for")
	var rw = sim.structures.filter(func(s): return s.type == "roadworks")
	check(rw.size() == 1 and rw[0].cells.size() == cells.size() and workers.all(func(x): return x.job.get("struct_id", -1) == rw[0].id), "the workers set out to build it")
	_run(sim, 200)
	check(cells.all(func(c): return R.level[c] == 2) and not sim.structures.any(func(s): return s.type == "roadworks"), "they build it stretch by stretch, and the site is gone when it is done")
	u.pos = R.cell_pos(cells[2])
	check(R.speed_at(u.pos) >= 1.25, "on the road people walk a quarter faster")
	# the Steward makes the busiest trails a road
	var s2 = _new_sim()
	s2.time = D.DAY_LEN * 0.3
	s2.techs["tools"] = true
	s2.inv.discover("road_making", s2.living()[0])
	s2.stock["wood"] = 300
	for i in 20:
		var kk: int = s2.roads.cell(D.VILLAGE + Vector2(80 + i * 25, 120))
		s2.roads.level[kk] = 1
		s2.wear[kk] = 0.9
	s2.appoint(s2.living()[0], "steward")
	var road_rule := {}
	for r in s2.improve.C["list"]:
		if r.has("road"): road_rule = r
	check(not s2.improve._road_cells(road_rule).is_empty(), "the Steward sees trails worth making a road")
	s2.improve._build(road_rule, "", "")
	check(s2.structures.any(func(s): return s.type == "roadworks"), "and has them made one")
	# saved with the game
	var data: Dictionary = preload("res://scripts/save_game.gd").encode(sim)
	var s3 = _new_sim()
	preload("res://scripts/save_game.gd").decode_into(s3, data)
	check(cells.all(func(c): return s3.roads.level[c] == 2), "roads are saved")

func test_discovery_odds() -> void:
	print("\n== Discovery by chance, and search quests (config/discovery.json) ==")
	var sim = _new_sim()
	for p in sim.predators: p.fled = true
	var a = sim.living().filter(func(u): return u.role == "")[0]
	var b = sim.living().filter(func(u): return u.role == "")[1]
	a.skills["forage"]["lv"] = 0
	b.skills["forage"]["lv"] = 4
	for t in ["gluttonous", "lazy"]:
		a.traits.erase(t)
		b.traits.erase(t)
	sim.set_job(a, {})
	sim.set_job(b, {})
	check(sim.find_chance(b, "mushroom") > sim.find_chance(a, "mushroom") * 2.0, "a skilled forager notices new foods more readily (%.4f vs %.4f per second)" % [sim.find_chance(b, "mushroom"), sim.find_chance(a, "mushroom")])
	a.skills["craft"]["lv"] = 0
	check(sim.find_chance(a, "copper") < sim.find_chance(a, "mushroom"), "with no skill in either, ores are harder to notice than foods")
	var idle: float = sim.find_chance(a, "mushroom")
	sim.assign_seek(a, a.pos, 200.0, "food")
	check(sim.find_chance(a, "mushroom") > idle * 4.0, "someone searching for foods is far keener (x%.1f)" % (sim.find_chance(a, "mushroom") / idle))
	# passing by is no longer enough
	var mush = sim.nodes.filter(func(n): return n.kind == "mushroom")[0]
	sim.reveal(mush.pos, 200)
	sim.set_job(a, {})
	a.pos = mush.pos + Vector2(30, 0)
	for i in 20: sim.tick(0.05)
	check(not sim.knows_find("mushroom"), "a moment beside a find is not enough to notice it")
	# a search quest
	var s2 = _new_sim()
	for p in s2.predators: p.fled = true
	var ld = s2.unit_by_name("Panshi")
	var ctx: Dictionary = s2.contracts.negotiation_ctx(ld, "Find something new", {"kind": "seek", "group": "food", "crew_size": 2}, true, "", {}, [], "seek")
	check(not ctx["env"]["places_you_could_search"].is_empty(), "the leader is told where foods might be found (%s)" % ", ".join(ctx["env"]["places_you_could_search"].map(func(p): return p["place"])))
	var r := Persona.propose(ctx)
	check(r["blueprint"].get("kind", "") == "seek" and r["speech"] != "", "the leader proposes a search: %s" % r["speech"])
	var san: Dictionary = s2.contracts.sanitize(r["blueprint"], {"kind": "seek", "group": "food", "crew_size": 2}, ld)
	check(san["ok"] and san["blueprint"]["group"] == "food" and san["blueprint"]["steps"][0]["action"] == "seek", "the plan is checked: foods, a place, days")
	var junk: Dictionary = s2.contracts.sanitize({"group": "gold", "place": 99, "days": 40, "crew_size": 30}, {"kind": "seek"}, ld)
	check(junk["ok"] and junk["blueprint"]["group"] == "food" and junk["blueprint"]["days"] <= 3 and junk["blueprint"]["crew_size"] <= 4, "an LLM's wild plan is clamped")
	var c = s2.contracts.create(san["blueprint"], ld, "Find something new")
	check(c.kind == "seek" and c.site.distance_to(D.VILLAGE) > 100, "the crew sets out for %s" % san["blueprint"]["place_name"])
	var searching := false
	for i in 600:
		s2.tick(0.1)
		if s2.contracts.crew(c).any(func(u): return u.job.get("type", "") == "seek" and u.pos.distance_to(c.site) < 400): searching = true
		if searching: break
	check(searching, "and searches there, roaming the place")
	var crewman = s2.contracts.crew(c)[0]
	s2.discover_find("honey", crewman, crewman.pos)
	check("honey" in c.flags.get("found", []), "what they find is credited to the search")
	for i in 3000:
		s2.tick(0.1)
		if c.status == "done": break
	check(c.status == "done" and not s2.living().any(func(u): return u.role == "contract" and u.contract_id == c.id), "the search ends and the crew comes home")
	check(s2.log_lines.any(func(e): return "The search" in e["text"] and "Wild Honey" in e["text"]), "the chronicle tells what they found")

func test_routine_matters() -> void:
	print("\n== The Steward decides routine matters ==")
	var sim = _new_sim()
	sim.stock["food"] = 200
	var asked := []
	sim.event_fired.connect(func(id): asked.append(id))
	sim._fire_event("festival")
	check(asked == ["festival"] and sim.pending_event == "festival", "without a Steward, the festival is asked")
	sim.resolve_event("festival", 2)
	sim.paused = false # (the HUD unpauses after a choice)
	sim.appoint(sim.living()[0], "steward")
	asked.clear()
	var food0: float = sim.stock["food"]
	sim._fire_event("festival")
	check(asked.is_empty() and sim.pending_event == "" and not sim.paused, "with a Steward it is decided, not asked")
	check(sim.stock["food"] < food0 and sim.log_lines.any(func(e): return "routine matter" in e["text"]), "a small gathering, reported in the chronicle")
	sim.stock["food"] = 0
	sim._fire_event("festival")
	check(asked.is_empty() and sim.log_lines[0]["text"].contains("No festival"), "with no food to spare, no festival this time")
	sim.steward_routine = false
	sim._fire_event("festival")
	check(asked == ["festival"], "and the player can take routine matters back")
	sim.resolve_event("festival", 2)
	sim._fire_event("overpop")
	check(sim.pending_event == "overpop", "matters that are not routine are always asked")

## A sim with everyday life switched on (as in the game), at day part `f` of day 1.
func _life_sim(f: float):
	var sim = _new_sim()
	sim.life.on = true
	sim.crisis.on = true # (as in the game: emergency mode is on, but no crisis is under way)
	sim.life.setup()
	sim.time = D.DAY_LEN * f
	return sim

func test_life() -> void:
	print("\n== Everyday life: meals, idle acts, bonds, spirits, speech ==")
	var Life = preload("res://scripts/life.gd")
	var Rx = preload("res://scripts/reactions.gd")
	check(Life.problems(Life.new(null).C).is_empty() and Rx.problems(preload("res://scripts/config.gd").load_cfg("reactions")).is_empty(),
		"config/life.json and reactions.json use only known verbs and conditions (%s)" % str(Life.problems(Life.new(null).C)))
	# the first families each have a friend; children are kin to their parent's line
	var sim = _life_sim(0.2)
	var adults: Array = sim.living().filter(func(u): return u.role == "")
	check(adults.all(func(u): return not sim.life.friends_of(u).is_empty()), "every family starts with a friend")
	var a = adults[0]
	var kid = sim.folk.make_child("Testkid", a)
	sim.units.append(kid)
	check(sim.life.kin(kid, a) and sim.life.bond(kid, a) >= 40.0, "a child is a new family line, kin to its parent's")
	# a meal: work is put down, people eat in a ring at the fire, then go back to work
	sim = _life_sim(0.3)
	var u = sim.unit_by_name("Bai")
	u.pos = D.VILLAGE + Vector2(120, 60)
	u.hunger = 50.0
	sim.assign_gather(u, "wood")
	sim.stock["food"] = 100.0
	sim.time = D.DAY_LEN * 0.345 # (the midday meal)
	var food0: float = sim.stock["food"]
	for i in 40: sim.tick(0.05)
	check(u.job.get("type", "") == "meal" and u.resume_job.get("type", "") == "gather", "at mealtime the hungry put down their work and come to eat (%s)" % u.job.get("type", ""))
	for i in 400:
		sim.tick(0.05)
		if u.job.get("type", "") != "meal": break
	check(u.hunger > 70.0 and sim.stock["food"] < food0, "they eat their fill from the stores (hunger %d, food %.1f -> %.1f)" % [u.hunger, food0, sim.stock["food"]])
	check(u.job.get("type", "") == "gather", "then go back to work")
	u.hunger = 90.0
	food0 = sim.stock["food"]
	sim.life.eat(u)
	var sv: Dictionary = sim.RULES["survival"]
	var fill: float = float(sv["meal_fill_fire"] if sim.has_tech("fire") else sv["meal_fill"])
	check(is_equal_approx(food0 - sim.stock["food"], float(sv["meal"]) * 10.0 / fill) and is_equal_approx(u.hunger, 100.0),
		"a meal costs food in proportion to what is eaten (%.2f for the last 10)" % (food0 - sim.stock["food"]))
	# idle acts: nobody just stands about for long
	sim = _life_sim(0.2)
	u = sim.unit_by_name("Yan")
	sim.set_job(u, {})
	u.pos = D.VILLAGE + Vector2(40, 40)
	for i in 120: sim.tick(0.05)
	check(u.job.get("type", "") in ["life", "art", "ritual"], "someone with nothing to do finds something to do (%s, %s)" % [u.job.get("type", ""), u.act])
	# a chat: they meet, face each other, talk; the bond grows (or they quarrel)
	sim = _life_sim(0.2)
	var p1 = sim.unit_by_name("Bai")
	var p2 = sim.unit_by_name("Yan")
	for o in sim.living():
		o.pos = D.VILLAGE + Vector2(-900, 0) # (everyone else is out of reach)
	for o in [p1, p2]:
		sim.set_job(o, {})
		o.pos = D.VILLAGE + Vector2(60, 60)
	sim.life.set_bond(p1, p2, 10.0)
	var chat: Dictionary = sim.life.C["idle"]["acts"].filter(func(x): return x["id"] == "chat")[0]
	check(sim.life.start(p1, chat) and p2.job.get("with", -1) == p1.id, "two people idle near each other can sit down to talk")
	var spoke := false
	for i in 300:
		sim.tick(0.05)
		if p1.say_until > sim.time: spoke = true
		if p1.job.is_empty() or p1.job.get("type", "") != "life": break
	check(spoke and absf(sim.life.bond(p1, p2) - 10.0) >= 5.0, "they talk (speech marks) and the bond changes (%.0f)" % sim.life.bond(p1, p2))
	# an earthquake ends the talk at once: they run into the open, crying out
	sim.life.start(p1, chat)
	for i in 40: sim.tick(0.05)
	p1.say = "Saw deer tracks by the water."
	p1.say_until = sim.time + 3.0
	sim.nat.quake()
	sim.tick(0.05)
	var cries: Array = sim.life.C["talk"]["quake"]
	check(p1.job.get("type", "") == "cover" and p2.job.get("type", "") == "cover", "when the earth shakes, the talk stops: both run for the open")
	check(p1.say == "" or p1.say in cries, "and their idle words are cut off (now: '%s')" % p1.say)
	sim.set_job(p1, {})
	p1.idle_t = 99.0
	sim.life.idle(p1, 0.1)
	check(p1.job.is_empty(), "nobody starts a pastime while the ground shakes")
	# weariness: work tires, sleep restores, and the weary work slower
	sim = _life_sim(0.05)
	u = sim.unit_by_name("Bai")
	sim.assign_gather(u, "wood")
	for i in 400: sim.tick(0.05)
	check(u.fatigue > 10.0, "work makes people weary (%d)" % roundi(u.fatigue))
	var w0: float = sim.work_mul(u)
	u.fatigue = 100.0
	check(sim.work_mul(u) < w0 * 0.9 and sim.life.speed_mult(u) < 0.9, "the weary work and walk slower")
	u.sleeping = true
	sim.life._fatigue(u, 10.0)
	check(u.fatigue < 70.0, "and sleep restores them")
	# grief: a friend dies, the living grieve and their spirits fall
	sim = _life_sim(0.2)
	p1 = sim.unit_by_name("Bai")
	p2 = sim.unit_by_name("Yan")
	sim.life.set_bond(p1, p2, 70.0)
	var t0: float = sim.life.morale_target(p1)
	sim.kill_unit(p2, null)
	check(p1.grief > 10.0 and p1.mourn_id == p2.id and sim.life.morale_target(p1) < t0, "losing a friend brings grief (%.0f) and low spirits" % p1.grief)
	# friends come from further to help the hurt
	sim = _life_sim(0.2)
	var v = sim.unit_by_name("Yan")
	var fr = sim.unit_by_name("Bai")
	for o in sim.living():
		if o != v: o.pos = v.pos + Vector2(2000, 0) if o != fr else v.pos + Vector2(430, 0)
	fr.pos = sim.dry_spot(fr.pos)
	sim.life.set_bond(v, fr, 70.0)
	v.hp = v.max_hp * 0.5
	sim.react.trigger("hurt", {"victim": v, "at": v.pos})
	check(D.same_side(fr.pos, v.pos) and fr.job.get("type", "") == "aid", "a friend comes from further away to tend the wounded")
	# something to see: a finished building draws the idle
	sim = _life_sim(0.2)
	for o in sim.living():
		if o.role == "":
			sim.set_job(o, {})
			o.pos = D.VILLAGE + Vector2(randf_range(-60, 60), randf_range(-60, 60))
	var site = sim.add_structure("hut", D.VILLAGE + Vector2(150, 120))
	sim.complete_structure(site, null)
	check(sim.units.any(func(o): return o.job.get("type", "") == "look"), "a new building draws people to come and see")
	# speech: lines from config, a cap on how many speak at once, lines from a game master
	sim = _life_sim(0.2)
	var ppl: Array = sim.living()
	var n := 0
	for o in ppl:
		if sim.life.say(o, "chat"): n += 1
	check(n == mini(ppl.size(), int(sim.life.C["speech"]["max_shown"])), "at most a few speak at once (%d)" % n)
	check(sim.life.add_lines("nonsense", ["x"]).size() == 1 and sim.life.add_lines("chat", ["Hello there", 7, ""]).is_empty() and sim.life.extra_lines["chat"] == ["Hello there"],
		"a game master's new lines are checked (known situations, strings only)")
	# the story actions a game master can use
	sim = _life_sim(0.2)
	p1 = sim.unit_by_name("Bai")
	p2 = sim.unit_by_name("Yan")
	sim.life.set_bond(p1, p2, 0.0)
	sim.story.run([{"bond": 45, "who": "name:Bai", "with": "name:Yan"}, {"say": "The river is high.", "who": "name:Bai"}, {"morale": -30, "who": "name:Yan"}], null)
	check(p2 in sim.life.friends_of(p1) and p1.say == "The river is high." and p2.morale < sim.folk.mood - 20, "story actions set bonds, words and spirits")
	check(sim.story.people("$nobody", {}).is_empty(), "an unknown person var means nobody, never everyone")
	# a family in despair asks to leave; letting them go sends them away
	sim = _life_sim(0.2)
	u = sim.unit_by_name("Yan")
	u.morale = 5.0
	u.low_t = D.DAY_LEN * 2.0
	sim.folk.mood = 5.0
	sim.life.update(1.0)
	sim.tick(0.05)
	check(sim.pending_event == "discontent", "a family that stays in despair wants to leave: the chieftain is asked (%s)" % sim.pending_event)
	var d: Dictionary = sim.event_def("discontent")
	check(d["text"].contains("Yan") and d["options"].size() == 3, "the question names the family")
	var pop0: int = sim.living().size()
	sim.resolve_event("discontent", 2)
	sim.paused = false
	for i in 1000:
		sim.tick(0.05)
		if u.gone: break
	check(u.gone and u.dead and u.buried and sim.living().size() == pop0 - 1, "letting them go: the family walks away and is gone")
	check(not sim.story.holds({"deaths": 1}), "a family that left is not counted among the dead")
	# switched off: the old ways (tests)
	var off = _new_sim()
	u = off.unit_by_name("Bai")
	u.fatigue = 100.0
	check(off.life.work_mult(u) == 1.0 and off.life.speed_mult(u) == 1.0, "with everyday life off, nothing changes the old rules")

func test_spend() -> void:
	print("\n== Paying: all or nothing ==")
	var sim = _new_sim()
	sim.stock["wood"] = 10.0
	sim.stock["stone"] = 2.0
	check(not sim.spend({"wood": 5, "stone": 3}) and sim.stock["wood"] == 10.0 and sim.stock["stone"] == 2.0, "a price that can't be paid in full takes nothing")
	check(sim.spend({"wood": 5, "stone": 2}) and sim.stock["wood"] == 5.0 and sim.stock["stone"] == 0.0, "a price that can be paid is paid in full")
	sim.stock["lore"] = 0.0
	check(sim.contracts.effect_text("ward").contains(str(int(sim.RULES["ward"]["cost"]["lore"]))), "the ward's text names its price from rules.json (%s)" % sim.contracts.effect_text("ward"))

## A game as the player gets it: every system on (hardships, festivals, crisis, director,
## everyday life), on the default map and on a random one, ticked for days while the world's
## invariants (sim.check_invariants) are checked. Catches what tests with features off miss.
func _game_sim():
	var sim = Sim.new()
	sim.new_game()
	return sim

func _smoke(sim, days: float) -> Array:
	var bad: Array = []
	var t := 0.0
	while t < days * D.DAY_LEN and bad.is_empty():
		_run(sim, 5.0)
		if sim.crisis.active(): sim.crisis.end()
		t += 5.0
		for b in sim.check_invariants(): bad.append("day %d: %s" % [sim.day(), b])
	return bad

func test_smoke() -> void:
	print("\n== Smoke: a whole game with every system on ==")
	var sim = _game_sim()
	check(sim.check_invariants().is_empty(), "a new game breaks no invariant (%s)" % str(sim.check_invariants()))
	var u = sim.living()[0]
	u.title = "Steward"
	sim.stock["wood"] = -5.0
	u.job = {"type": "gahter"}
	check(sim.check_invariants().size() == 3, "the checker catches a false title, a debt and an unknown job (%s)" % str(sim.check_invariants()))
	sim = _game_sim()
	var bad := _smoke(sim, 4.0)
	check(bad.is_empty(), "4 days on the default map break no invariant %s" % str(bad))
	check(sim.living().size() > 0, "the tribe lives through 4 days")
	MapGen.generate("standard", 4, 269472)
	sim = _game_sim()
	bad = _smoke(sim, 3.0)
	check(bad.is_empty(), "3 days on a random map break no invariant %s" % str(bad))
	Scenarios.apply("the_ford")
