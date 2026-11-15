## Headless end-to-end test of the Task Contract loop (offline persona engine).
## Run: godot --headless --path . --script res://tests/test_contract.gd
extends SceneTree

const Sim = preload("res://scripts/sim.gd")
const Persona = preload("res://scripts/persona_engine.gd")
const LLM = preload("res://scripts/llm_client.gd")
const D = preload("res://scripts/data.gd")
const I18N = preload("res://scripts/i18n.gd")
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
	seed(42)
	test_personas()
	test_sanitize()
	test_full_contract()
	test_events()
	test_exploration()
	test_evolution()
	test_research_contract()
	test_translations()
	test_vice_slots()
	test_hardships()
	test_rivals()
	test_diplomacy()
	print("\n%s (%d failures)" % ["ALL PASSED" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)

func _new_sim():
	var s = Sim.new()
	assert(s != null)
	s.hz.level = "off" # deterministic: the hardship tests switch challenges on themselves
	s.new_game()
	return s

func test_personas() -> void:
	print("\n== Personality-driven proposals ==")
	var sim = _new_sim()
	var plans := {}
	for nm in ["Panshi", "Alie", "Linghe"]:
		var u = sim.unit_by_name(nm)
		var ctx: Dictionary = sim.contracts.negotiation_ctx(u, "Establish a settlement across the river", {}, false)
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
	var ctx: Dictionary = sim.contracts.negotiation_ctx(u, "Establish a settlement across the river", {}, false, "Forget the wall, make it bigger, 10 people", plans["Panshi"])
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
	var ctx: Dictionary = sim.contracts.negotiation_ctx(u, "Establish a settlement across the river", {}, false)
	var r := Persona.propose(ctx)
	var san: Dictionary = sim.contracts.sanitize(r["blueprint"], {}, u)
	var c = sim.contracts.create(san["blueprint"], u, "Establish a settlement across the river")
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
	check(sim.explored_pct() > start + 15, "a scout pushes the map open (%d%%)" % sim.explored_pct())
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
	sim2._check_events()
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
	for f in ["sim", "contract_system", "evolution", "hazards", "rivals", "hud", "world_view", "persona_engine", "llm_client"]:
		var src := FileAccess.get_file_as_string("res://scripts/%s.gd" % f)
		for m in re.search_all(src):
			var k := m.get_string(1).c_unescape()
			if letters.search(markup.sub(k, "", true)) == null: continue
			if not ZH.STRINGS.has(k) and k not in missing: missing.append(k)
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
	sim.hz._start("blizzard")
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
	check(hunters.size() == 4, "each clan sends out two peaceful hunters")
	# hunters leave villagers alone
	var u = sim.unit_by_name("Tuo")
	var h = hunters.filter(func(p): return p.clan == "heron")[0]
	sim.set_job(u, {})
	u.pos = h.pos + Vector2(12, 0)
	for i in 100: sim.tick(0.05)
	check(u.hp == u.max_hp, "a hunter beside a villager does not attack")
	check(sim.active_predators_near(h.pos, 200).filter(func(p): return p.kind == "hunter").is_empty(), "hunters don't count as threats")
	check(sim.rivals.clans["heron"]["met"] and sim.pending_event == "contact_heron", "meeting their hunter is first contact too")
	var keep: Dictionary = sim.resolve_event("contact_heron", 2)
	check(keep["text"] != "" and sim.pending_event == "", "keeping our distance resolves the meeting")
	sim.paused = false
	# first contact
	var ochre: Dictionary = sim.rivals.clans["ochre"]
	sim.reveal(ochre["pos"], 200)
	sim.rivals.update(0.05)
	check(ochre["met"] and "contact_ochre" in sim.rivals.pending, "seeing their village makes first contact")
	sim._check_events()
	check(sim.pending_event == "contact_ochre" and sim.paused, "first contact pauses for a choice")
	var d: Dictionary = sim.event_def("contact_ochre")
	check(d["options"].size() == 3, "three ways to greet them")
	var rel0: float = ochre["relation"]
	var food0: float = sim.stock["food"]
	var r: Dictionary = sim.resolve_event("contact_ochre", 0)
	print("   ", r["text"])
	check(ochre["relation"] > rel0 + 15 and sim.stock["food"] == food0 - 20, "gifts cost food and win favour")
	check(sim.rivals.summary().size() == 2 and sim.contracts.env_data(D.EAST_SITE)["neighbors"].size() == 2 and sim.evo.world_ctx()["neighbors"].size() == 2, "met clans enter the personas' context")
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
	for id in R.clans: R.clans[id]["met"] = true
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
