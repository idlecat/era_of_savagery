## Headless end-to-end test of the Task Contract loop (offline persona engine).
## Run: godot --headless --path . --script res://tests/test_contract.gd
extends SceneTree

const Sim = preload("res://scripts/sim.gd")
const Persona = preload("res://scripts/persona_engine.gd")
const LLM = preload("res://scripts/llm_client.gd")
const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")
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
	test_war_and_trade()
	test_endgames()
	test_night_rest()
	test_burials()
	test_night_contracts()
	test_herd()
	test_finds()
	test_nature()
	test_settling()
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
	for f in ["sim", "contract_system", "evolution", "hazards", "nature", "rivals", "legacy", "hud", "world_view", "persona_engine", "llm_client"]:
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

func test_war_and_trade() -> void:
	print("\n== War contracts, trade caravans, knowledge ==")
	var sim = _new_sim()
	var R = sim.rivals
	for id in R.clans: R.clans[id]["met"] = true
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
	check(abed.size() == sim.living().filter(func(o): return o.role == "").size(), "everyone without a mission sleeps (%d)" % abed.size())
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
	var missing: Array = D.FINDS.keys().filter(func(id): return D.FINDS[id]["count"] > 0 and not sim.nodes.any(func(n): return n.kind == id))
	check(missing.is_empty(), "every kind of find is somewhere on the map (missing: %s)" % ", ".join(missing))
	check(sim.known_finds.is_empty(), "nothing is known at the start")
	var mush = sim.nodes.filter(func(n): return n.kind == "mushroom")[0]
	var picked = sim.find_node("food", mush.pos, "", 60.0)
	check(picked == null or picked.kind != "mushroom", "unknown finds can't be gathered")
	var u = sim.unit_by_name("Tuo")
	sim.set_job(u, {})
	u.pos = mush.pos + Vector2(30, 0)
	sim.reveal(mush.pos, 200)
	for i in 20: sim.tick(0.05)
	check(sim.knows_find("mushroom"), "walking up to one discovers it")
	var line: Dictionary = sim.log_lines.filter(func(e): return "Forest Mushrooms" in e["text"])[0]
	check(line["who"][0]["id"] == u.id, "the finder gets the credit in the chronicle")
	check(sim.find_node("food", mush.pos, "", 60.0) != null, "and the tribe can gather it now")
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
	var tree = sim.nodes.filter(func(n): return n.kind == "tree" and sim.nodes.filter(func(o): return o.kind == "tree" and o.pos.distance_to(n.pos) < 60).size() >= 3)[0]
	nat.ignite(tree)
	check(nat.burning.has(tree.id) and "Wildfire" in nat.status() or nat.status().has(sim.tr("Wildfire")), "a tree catches fire: wildfire")
	var u = sim.unit_by_name("Tuo")
	sim.set_job(u, {})
	u.pos = tree.pos + Vector2(20, 0)
	var hp0: float = u.hp
	for i in 30: sim.tick(0.05)
	check(u.hp < hp0, "people too close to the flames get burned")
	for i in 900:
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
	var dock = sim.add_structure("fishing_dock", Vector2(D.river_x(D.VILLAGE.y) - 60, D.VILLAGE.y), true)
	var r = sim.unit_by_name("Yan")
	sim.set_job(r, {})
	r.pos = Vector2(D.river_x(D.VILLAGE.y + 120) - 150, D.VILLAGE.y + 120)
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
	var farm = sim.add_structure("farm_plot", Vector2(D.river_x(D.VILLAGE.y) - 250, D.VILLAGE.y + 200), true)
	check(nat.food_mult(farm) > 1.3, "the silt makes riverside fields richer afterwards")
	# the Fire Mountain
	var near = sim.unit_by_name("Qiao")
	near.pos = nat.VOLCANO + Vector2(-200, 200)
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
	c.site = D.EAST_SITE
	c.plan = {"plan_id": "test_outpost"}
	sim.contracts.list.append(c)
	sim.add_structure("hut", D.EAST_SITE + Vector2(40, 0), true, "contract:%d" % c.id)
	sim.add_structure("hut", D.EAST_SITE + Vector2(-40, 0), true, "contract:%d" % c.id)
	var huts: Array = sim.structures.filter(func(st): return st.type == "hut" and st.owner == "village")
	huts[0].built = false
	huts[1].built = false
	check(sim.residents_of(D.VILLAGE).size() > sim.beds_at(D.VILLAGE), "(the village is crowded: %d people, %d beds)" % [sim.residents_of(D.VILLAGE).size(), sim.beds_at(D.VILLAGE)])
	sim.time = D.DAY_LEN * 1 + 10.0
	sim.resettle_t = 0.0
	sim.tick(0.05)
	var movers: Array = sim.residents_of(D.EAST_SITE)
	check(movers.size() == 1 and movers[0].job.get("type", "") == "move", "someone moves to the settlement across the river")
	check(sim.log_lines.any(func(e): return "test_outpost" in e["text"]), "and the chronicle tells of it")
	for i in 3:
		sim.resettle_t = 0.0
		sim.tick(0.05)
	check(sim.residents_of(D.EAST_SITE).size() <= sim.beds_at(D.EAST_SITE), "but never more than its beds")

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
	for id in R.clans: R.clans[id]["met"] = true
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
	sim.legacy.check_t = 0.0
	sim.legacy.update(0.1)
	check(sim.legacy.pending == "victory_conquest", "every clan a vassal: victory by conquest")
	sim.pending_event = ""
	sim._check_events()
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
