## Task Contracts (PRD 2.2.2): LLM blueprint -> sanitized plan -> deterministic executor.
## Once a contract is confirmed, NOTHING in this file calls the LLM. Interruptions are
## surfaced via sim.contract_interrupted, and the UI decides whether to wake the LLM.
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")

const SLOTS := [Vector2(-48, -42), Vector2(48, -42), Vector2(-48, 42), Vector2(48, 42), Vector2(0, -72),
	Vector2(0, 72), Vector2(-78, 0), Vector2(78, 0), Vector2(-30, -20), Vector2(30, 20)]
const EFFECTS := {
	"hold": "Crew stands its ground and fights",
	"reinforce": "Send up to 3 warriors from the village, crew holds",
	"retreat": "Abandon the task and flee back across the river",
	"ward": "Totem ritual drives beasts away (costs 10 lore)",
	"rest": "Wounded leader returns to the bonfire; crew carries on",
	"press_on": "Ignore the wound and keep working",
	"shelter": "Take shelter and wait for the danger to pass",
}

var sim
var list: Array = []

func _init(s) -> void:
	sim = s

func by_id(id: int) -> E.Contract:
	for c in list:
		if c.id == id: return c
	return null

func active() -> Array:
	return list.filter(func(c): return c.status not in ["done", "abandoned", "failed"])

func is_running(c: E.Contract) -> bool:
	return c.status not in ["done", "abandoned", "failed"]

# ------------------------------------------------------------ context for the LLM
func available_helpers(exclude_id := -1) -> Array:
	return sim.living().filter(func(u): return u.role != "contract" and u.id != exclude_id and D.bank_of(u.pos) == "west")

func leader_profile(u: E.Unit) -> Dictionary:
	var skills := {}
	for s in D.SKILLS: skills[D.SKILL_NAMES[s]] = u.lv(s)
	var mem: Array = []
	var sorted_mem: Array = u.memory.duplicate()
	sorted_mem.sort_custom(func(a, b): return a["day"] < b["day"])
	for m in sorted_mem:
		mem.append(("Day %d: " % m["day"] if m["day"] > 0 else "Long ago: ") + m["text"])
	var traits: Array = []
	for t in u.traits: traits.append("%s (%s)" % [D.TRAITS[t]["name"], D.TRAITS[t]["desc"]])
	return {
		"name": u.name, "epithet": u.epithet, "personality": traits, "archetype": sim.arch(u),
		"level": sim.unit_level(u), "skills": skills,
		"hp": "%d/%d" % [roundi(u.hp), roundi(u.max_hp)], "hunger": "%d%%" % roundi(u.hunger),
		"memory_stream": mem,
		"knows": sim.evo.known_by(u).map(func(id): return sim.evo.tech_def(id)["name"]),
	}

func env_data(site: Vector2) -> Dictionary:
	var trees := 0
	var timber := 0.0
	var food_nodes := 0
	for n in sim.nodes:
		if n.pos.distance_to(site) > 650 or D.bank_of(n.pos) != D.bank_of(site): continue
		if n.kind == "tree":
			trees += 1
			timber += n.amount
		elif n.res == "food" and n.amount >= 1:
			food_nodes += 1
	var threats: Array = ["fresh saber-tooth tracks in the tall grass east of the ford"]
	var visible: int = sim.active_predators_near(site, 700).size()
	if visible > 0: threats.append("%d saber-toothed tigers seen prowling" % visible)
	var structs := {}
	for k in D.CONTRACT_STRUCTURES:
		var sd: Dictionary = D.STRUCTURES[k]
		if sd.has("tech") and not sim.has_tech(sd["tech"]): continue
		structs[k] = {"wood": sd["wood"], "houses": sd.get("cap", 0)}
	return {
		"target_area": "untamed east bank, across the river ford",
		"timber": "%d trees (~%d wood)" % [trees, timber], "food_sources": food_nodes,
		"predator_threat": threats, "river": "rich fishing waters along the bank",
		"tribe_stockpile": {"food": roundi(sim.stock["food"]), "wood": roundi(sim.stock["wood"]), "lore": roundi(sim.stock["lore"])},
		"population": sim.living().size(), "idle_helpers_available": available_helpers().size(),
		"buildable_structures": structs,
		"day": sim.day(),
	}

## Everything injected into the leader's LLM node for Phase 1 negotiation.
func negotiation_ctx(u: E.Unit, directive: String, terms: Dictionary, terms_set: bool,
		player_message := "", previous := {}, history := [], kind := "settle") -> Dictionary:
	var top := ""
	if not u.memory.is_empty(): top = u.memory[0]["text"] # memory is kept sorted by impact
	return {
		"kind": kind, "world": sim.evo.world_ctx(), "candidates": research_candidates(),
		"arch": sim.arch(u), "leader": leader_profile(u), "env": env_data(D.EAST_SITE) if kind == "settle" else research_env(),
		"directive": directive, "terms": terms, "terms_set": terms_set,
		"player_message": player_message, "previous": previous, "history": history,
		"has_farming": sim.has_tech("farming"), "max_crew": mini(5, available_helpers(u.id).size() + 1),
		"top_memory": top,
	}

## Ideas a research contract may pursue: prerequisites known, tech itself not.
func research_candidates() -> Array:
	var out: Array = []
	for id in sim.evo.candidates():
		var t: Dictionary = sim.evo.tech_def(id)
		var how: Array = []
		for k in t["practice"]: how.append(D.PRACTICE_NAMES[k])
		out.append({"id": id, "name": t["name"], "what_it_gives": t["desc"], "insight_pct": roundi(sim.evo.insight_frac(id) * 100),
			"learned_by": ", ".join(how)})
	return out

func research_env() -> Dictionary:
	return {
		"target_area": "a workshop clearing beside the village bonfire",
		"tribe_stockpile": {"food": roundi(sim.stock["food"]), "wood": roundi(sim.stock["wood"]), "stone": roundi(sim.stock["stone"]), "lore": roundi(sim.stock["lore"])},
		"population": sim.living().size(), "idle_helpers_available": available_helpers().size(),
		"stone_quarrying_possible": sim.has_tech("tools"), "day": sim.day(),
	}

## Context for Phase 4 emergency awakening.
func emergency_ctx(c: E.Contract) -> Dictionary:
	var u := leader(c)
	return {
		"arch": sim.arch(u), "name": u.name, "leader": leader_profile(u),
		"summary": summary(c), "allowed": allowed_effects(c), "effects": EFFECTS, "world": sim.evo.world_ctx(),
	}

# ------------------------------------------------------------ blueprint sanitizing
## LLM output is untrusted: clamp every number, whitelist every enum. Returns
## {"ok": bool, "blueprint": Dictionary, "notes": Array[String]}.
func sanitize(raw: Variant, terms: Dictionary, leader: E.Unit) -> Dictionary:
	var bp0: Dictionary = raw if raw is Dictionary else {}
	if terms.get("kind", bp0.get("kind", "settle")) == "research": return _sanitize_research(bp0, terms, leader)
	var notes: Array = []
	var bp: Dictionary = bp0
	var max_crew := mini(5, available_helpers(leader.id).size() + 1)
	var out := {}
	var pid := str(bp.get("plan_id", "")).to_lower().replace(" ", "_")
	var re := RegEx.create_from_string("[^a-z0-9_]")
	pid = re.sub(pid, "", true).left(40)
	out["plan_id"] = pid if pid != "" else "east_river_outpost_%02d" % (list.size() + 1)
	out["leader_id"] = "unit_%d" % leader.id
	out["crew_size"] = clampi(_int(bp.get("crew_size"), terms.get("crew_size", 3)), 1, max_crew)
	out["capacity_target"] = clampi(_int(bp.get("capacity_target"), terms.get("capacity_target", 6)), 2, 15)
	var focus := str(bp.get("focus", terms.get("focus", "balanced")))
	out["focus"] = focus if focus in D.FOCUSES else "balanced"

	var steps: Array = []
	var seen_once := {}
	var raw_steps: Array = bp.get("steps", []) if bp.get("steps") is Array else []
	for s in raw_steps:
		if not (s is Dictionary): continue
		var action := str(s.get("action", "")).to_lower()
		match action:
			"gather_wood", "gather_food":
				var hi := 120 if action == "gather_wood" else 60
				steps.append({"action": action, "target_amount": clampi(_int(s.get("target_amount"), 30), 5, hi)})
			"build":
				var st := str(s.get("structure", "")).to_lower().replace(" ", "_")
				st = D.STRUCT_ALIASES.get(st, st)
				if st not in D.CONTRACT_STRUCTURES:
					notes.append("Dropped unknown structure '%s'." % st)
					continue
				var sd: Dictionary = D.STRUCTURES[st]
				if sd.has("tech") and not sim.has_tech(sd["tech"]):
					notes.append("%s needs unresearched wisdom; replaced with Fishing Dock." % sd["name"])
					st = "fishing_dock"
				var count := clampi(_int(s.get("count"), 1), 1, 4)
				if st in ["palisade", "bonfire", "weapon_rack", "totem_shrine", "fishing_dock"]:
					if seen_once.has(st): continue
					seen_once[st] = true
					count = 1
				steps.append({"action": "build", "structure": st, "count": count})
			"ritual":
				steps.append({"action": "ritual", "duration_sec": clampi(_int(s.get("duration_sec", s.get("duration")), 10), 4, 30)})
			_:
				notes.append("Dropped unknown action '%s'." % action)
		if steps.size() >= 8: break
	if steps.is_empty():
		return {"ok": false, "blueprint": out, "notes": notes + ["Blueprint had no valid steps."]}
	out["steps"] = steps

	var aborts: Array = []
	var hp_re := RegEx.create_from_string("hp_below_(\\d+)")
	var raw_aborts: Array = bp.get("abort_conditions", []) if bp.get("abort_conditions") is Array else []
	for a in raw_aborts:
		var s := str(a).to_lower()
		if s in ["enemy_attack", "natural_disaster"] and s not in aborts: aborts.append(s)
		var m := hp_re.search(s)
		if m: aborts.append("hp_below_%d%%" % clampi(int(m.get_string(1)), 10, 80))
	if "enemy_attack" not in aborts: aborts.push_front("enemy_attack")
	out["abort_conditions"] = aborts
	return {"ok": true, "blueprint": out, "notes": notes}

func _sanitize_research(bp: Dictionary, terms: Dictionary, leader: E.Unit) -> Dictionary:
	var notes: Array = []
	var out := {"kind": "research"}
	var cands: Array = sim.evo.candidates()
	var pid := RegEx.create_from_string("[^a-z0-9_]").sub(str(bp.get("plan_id", "")).to_lower().replace(" ", "_"), "", true).left(40)
	out["plan_id"] = pid if pid != "" else "seek_wisdom_%02d" % (list.size() + 1)
	out["leader_id"] = "unit_%d" % leader.id
	out["crew_size"] = clampi(_int(bp.get("crew_size"), terms.get("crew_size", 2)), 1, mini(4, available_helpers(leader.id).size() + 1))
	var tech := str(bp.get("tech", terms.get("tech", ""))).to_lower()
	for t in D.TECHS: # accept names as well as ids
		if tech == t["name"].to_lower(): tech = t["id"]
	if terms.get("tech", "") != "" and terms["tech"] in cands and tech != terms["tech"]:
		notes.append("The Chieftain chose %s." % sim.evo.tech_def(terms["tech"])["name"])
		tech = terms["tech"]
	if tech not in cands:
		if cands.is_empty():
			return {"ok": false, "blueprint": out, "notes": ["No new wisdom is within reach yet."]}
		if tech != "": notes.append("'%s' is out of reach; seeking %s instead." % [tech, sim.evo.tech_def(cands[0])["name"]])
		tech = cands[0]
	out["tech"] = tech
	out["capacity_target"] = 0
	out["focus"] = "research"
	var steps: Array = []
	var raw_steps: Array = bp.get("steps", []) if bp.get("steps") is Array else []
	for s in raw_steps:
		if not (s is Dictionary): continue
		var action := str(s.get("action", "")).to_lower()
		match action:
			"gather_wood", "gather_food":
				steps.append({"action": action, "target_amount": clampi(_int(s.get("target_amount"), 20), 5, 60)})
			"gather_stone":
				if sim.has_tech("tools"): steps.append({"action": action, "target_amount": clampi(_int(s.get("target_amount"), 15), 5, 40)})
				else: notes.append("Dropped stone gathering (needs Polished Stone Tools).")
			"experiment":
				steps.append({"action": "experiment", "duration_sec": clampi(_int(s.get("duration_sec", s.get("duration")), 20), 8, 45)})
			"ritual":
				steps.append({"action": "ritual", "duration_sec": clampi(_int(s.get("duration_sec", s.get("duration")), 10), 4, 30)})
			_:
				notes.append("Dropped '%s' (not part of a research plan)." % action)
		if steps.size() >= 6: break
	if not steps.any(func(s): return s["action"] == "experiment"):
		steps.append({"action": "experiment", "duration_sec": 20})
		notes.append("Added an experiment step - wisdom is not found without trying.")
	out["steps"] = steps
	var aborts: Array = ["enemy_attack"]
	for a in (bp.get("abort_conditions", []) if bp.get("abort_conditions") is Array else []):
		var m := RegEx.create_from_string("hp_below_(\\d+)").search(str(a))
		if m: aborts.append("hp_below_%d%%" % clampi(int(m.get_string(1)), 10, 80))
	out["abort_conditions"] = aborts
	return {"ok": true, "blueprint": out, "notes": notes}

func _int(v: Variant, fallback: int) -> int:
	if v is int or v is float: return int(v)
	if v is String and v.is_valid_float(): return int(float(v))
	return fallback

func wood_needed(bp: Dictionary) -> int:
	var w := 0
	for s in bp.get("steps", []):
		if s["action"] == "build": w += D.STRUCTURES[s["structure"]]["wood"] * s["count"]
	return w

func housing(bp: Dictionary) -> int:
	var c := 0
	for s in bp.get("steps", []):
		if s["action"] == "build": c += D.STRUCTURES[s["structure"]].get("cap", 0) * s["count"]
	return c

# ------------------------------------------------------------ creation
func create(bp: Dictionary, leader: E.Unit, directive: String) -> E.Contract:
	var c := E.Contract.new()
	c.id = sim.uid()
	c.plan = bp.duplicate(true)
	c.directive = directive
	c.leader_id = leader.id
	c.kind = bp.get("kind", "settle")
	if c.kind == "research":
		var n := list.filter(func(o): return o.kind == "research").size()
		c.site = D.VILLAGE + Vector2(-190, 170) + Vector2(70 * (n % 3), -60 * (n % 2))
	else:
		c.site = D.EAST_SITE + Vector2(0, 260 * (list.size() % 3) * (1 if list.size() % 2 == 0 else -1))
	c.t = sim.time
	for s in bp["steps"]:
		var rs: Dictionary = s.duplicate()
		rs["done"] = 0.0
		rs["ids"] = []
		c.steps.append(rs)
	# Crew: leader + best helpers for the focus.
	var skill := "craft"
	if bp["focus"] in ["hunting", "defense"]: skill = "combat"
	elif bp["focus"] in ["farming", "fishery"]: skill = "forage"
	var helpers := available_helpers(leader.id).filter(func(u): return sim.vice["steward"] != u.id and sim.vice["warchief"] != u.id)
	helpers.sort_custom(func(a, b): return a.lv(skill) + a.lv("craft") * 0.5 > b.lv(skill) + b.lv("craft") * 0.5)
	c.crew_ids = [leader.id]
	for u in helpers.slice(0, bp["crew_size"] - 1): c.crew_ids.append(u.id)
	for id in c.crew_ids:
		var u: E.Unit = sim.unit_by_id(id)
		u.role = "contract"
		u.contract_id = c.id
		sim.set_job(u, {})
	list.append(c)
	var names: Array = c.crew_ids.map(func(id): return sim.unit_by_id(id).name)
	var where := "across the river" if c.kind == "settle" else "to seek %s" % sim.evo.tech_def(bp["tech"])["name"]
	sim.add_log("Task Contract '%s' sealed. %s leads %s %s. The LLM connection is closed." % [bp["plan_id"], leader.name, ", ".join(names.slice(1)) if names.size() > 1 else "no one", where], "contract")
	_clog(c, "Contract sealed: %d steps, crew of %d." % [c.steps.size(), c.crew_ids.size()])
	return c

func _clog(c: E.Contract, text: String) -> void:
	c.events.push_front("[Day %d] %s" % [sim.day(), text])
	if c.events.size() > 12: c.events.pop_back()

func crew(c: E.Contract, include_resting := false) -> Array:
	var out: Array = []
	for id in c.crew_ids + c.reinforcement_ids:
		var u: E.Unit = sim.unit_by_id(id)
		if u == null or u.dead: continue
		if not include_resting and id in c.resting_ids: continue
		out.append(u)
	return out

func leader(c: E.Contract) -> E.Unit:
	return sim.unit_by_id(c.leader_id)

func _ensure(u: E.Unit, key: String, assign: Callable) -> void:
	if u.job_key != key or u.job.is_empty():
		assign.call()
		u.job_key = key

# ------------------------------------------------------------ execution (zero LLM calls)
func update(dt: float) -> void:
	for c in list:
		if not is_running(c): continue
		c.state_t += dt
		_manage_wounded(c)
		var ld := leader(c)
		if ld == null or ld.dead:
			_fail(c, "%s fell; the expedition lost its leader." % (ld.name if ld else "The leader"))
			continue
		if crew(c, true).is_empty():
			_fail(c, "No crew remain.")
			continue
		match c.status:
			"assembling": _assemble(c)
			"executing":
				if _check_aborts(c): continue
				_run_step(c, dt)
				c.progress = _progress(c)
				_maybe_ambush(c)
			"defending": _defend(c, dt)
			"sheltering":
				for u in crew(c): _ensure(u, "c%d_shelter" % c.id, func(): sim.assign_move(u, c.site + Vector2(randf_range(-30, 30), randf_range(-30, 30))))
				if c.state_t > 8: _set_status(c, "executing")
			"interrupted": pass # waiting on the player / LLM

func _set_status(c: E.Contract, s: String) -> void:
	c.status = s
	c.state_t = 0.0
	c.clear_t = 0.0

func _manage_wounded(c: E.Contract) -> void:
	for u in crew(c, true):
		if u.id in c.resting_ids:
			if u.hp >= u.max_hp * 0.7:
				c.resting_ids.erase(u.id)
				sim.add_log("%s has recovered and rejoins '%s'." % [u.name, c.plan["plan_id"]], "contract")
			elif u.job.is_empty() and u.pos.distance_to(D.VILLAGE) > 60:
				sim.set_job(u, {"type": "move", "to": D.VILLAGE + Vector2(randf_range(-30, 30), 30), "flee": true})
		elif u.hp < u.max_hp * 0.25 and not u.has_trait("belligerent") and u.id != c.leader_id:
			c.resting_ids.append(u.id)
			sim.set_job(u, {"type": "move", "to": D.VILLAGE + Vector2(randf_range(-30, 30), 30), "flee": true})
			_clog(c, "%s is badly hurt and limps home." % u.name)

func _assemble(c: E.Contract) -> void:
	var all_there := true
	var i := 0
	for u in crew(c):
		i += 1
		var spot: Vector2 = c.site + Vector2(cos(i * 1.7) * 30, sin(i * 1.7) * 30)
		_ensure(u, "c%d_assemble" % c.id, func(): sim.assign_move(u, spot))
		u.act = "Crossing the river (contract)" if c.kind == "settle" else "Gathering at the workshop"
		if u.pos.distance_to(c.site) > 70: all_there = false
	if all_there or c.state_t > 45:
		_set_status(c, "executing")
		_clog(c, "Crew arrived at the site.")

func _run_step(c: E.Contract, dt: float) -> void:
	if c.step_idx >= c.steps.size():
		_complete(c)
		return
	var step: Dictionary = c.steps[c.step_idx]
	var key := "c%d_s%d" % [c.id, c.step_idx]
	var bank := D.bank_of(c.site)
	match step["action"]:
		"gather_wood", "gather_food", "gather_stone":
			var res: String = step["action"].trim_prefix("gather_")
			c.substate = "Gathering %s %d/%d" % [res, step["done"], step["target_amount"]]
			for u in crew(c):
				_ensure(u, key, func(): sim.assign_gather(u, res, {"dropoff": c.id, "area": c.site, "area_r": 650.0, "bank": bank}))
			if step["done"] >= step["target_amount"]: _next_step(c)
		"build":
			if step["ids"].is_empty():
				for k in step["count"]:
					var s = sim.add_structure(step["structure"], _slot_for(c, step["structure"]), false, "contract:%d" % c.id)
					step["ids"].append(s.id)
					c.struct_ids.append(s.id)
			var target = null
			for id in step["ids"]:
				var s = sim.struct_by_id(id)
				if s and not s.built:
					target = s
					break
			if target == null:
				_next_step(c)
				return
			var sname: String = D.STRUCTURES[target.type]["name"]
			if not target.paid:
				var cost: int = D.STRUCTURES[target.type]["wood"]
				if c.wood >= cost:
					c.wood -= cost
					target.paid = true
				else:
					c.substate = "Gathering timber for %s (%d/%d)" % [sname, c.wood, cost]
					for u in crew(c):
						_ensure(u, key + "_mat", func(): sim.assign_gather(u, "wood", {"dropoff": c.id, "area": c.site, "area_r": 650.0, "bank": bank}))
					return
			c.substate = "Building %s (%d%%)" % [sname, roundi(target.progress / target.work * 100)]
			for u in crew(c):
				_ensure(u, key + "_b%d" % target.id, func(): sim.assign_build(u, target))
		"experiment":
			var tname: String = sim.evo.tech_def(c.plan["tech"])["name"]
			var cr := crew(c)
			var working := 0
			var i := 0
			for u in cr:
				var spot: Vector2 = c.site + Vector2.from_angle(i * TAU / maxf(1, cr.size())) * 26
				_ensure(u, key, func(): sim.assign_experiment(u, spot, tname))
				if u.act.begins_with("Experimenting"): working += 1
				i += 1
			var ld := leader(c)
			var rate: float = (0.4 + 0.6 * working / maxf(1, cr.size())) * (1.0 + 0.08 * ld.lv("lore") + 0.04 * ld.lv("craft"))
			if working > 0:
				step["done"] += dt * rate
				var total := 0.0
				for s2 in c.steps:
					if s2["action"] == "experiment": total += s2["duration_sec"]
				sim.evo.seed(c.plan["tech"], 0.7 * dt * rate / maxf(1.0, total), ld)
			c.substate = "Experimenting on %s (%ds/%ds)" % [tname, step["done"], step["duration_sec"]]
			if step["done"] >= step["duration_sec"]: _next_step(c)
		"ritual":
			var ld := leader(c)
			if c.leader_id in c.resting_ids:
				_next_step(c)
				return
			c.substate = "%s performs the ritual (%ds/%ds)" % [ld.name, step["done"], step["duration_sec"]]
			_ensure(ld, key + "_r", func(): sim.assign_ritual(ld, c.site + Vector2(0, -10)))
			if ld.job.get("type", "") == "ritual" and ld.pos.distance_to(c.site + Vector2(0, -10)) < 8:
				step["done"] += dt
			for u in crew(c):
				if u != ld: _ensure(u, key, func(): sim.assign_gather(u, "wood", {"dropoff": c.id, "area": c.site, "area_r": 650.0, "bank": bank}))
			if step["done"] >= step["duration_sec"]:
				sim.devotion = minf(100, sim.devotion + 8)
				sim.gain_xp(ld, "lore", 8)
				_next_step(c)

func _next_step(c: E.Contract) -> void:
	var step: Dictionary = c.steps[c.step_idx]
	var desc := _step_text(step)
	for u in crew(c):
		var skill: String = {"gather_wood": "forage", "gather_food": "forage", "gather_stone": "forage", "build": "craft", "ritual": "lore", "experiment": "lore"}[step["action"]]
		sim.gain_xp(u, skill, 6)
	_clog(c, "Step %d done: %s." % [c.step_idx + 1, desc])
	c.step_idx += 1

func _slot_for(c: E.Contract, type: String) -> Vector2:
	if type == "palisade": return c.site
	if type == "bonfire":
		var has_center := false
		for id in c.struct_ids:
			var s = sim.struct_by_id(id)
			if s and s.type == "bonfire": has_center = true
		if not has_center: return c.site + Vector2(0, 0)
	if type == "fishing_dock":
		var y := c.site.y + 60
		return Vector2(D.river_x(y) + D.RIVER_HALF + 14, y)
	var p: Vector2 = c.site + SLOTS[c.slot_idx % SLOTS.size()] * (1.0 + 0.6 * (c.slot_idx / SLOTS.size()))
	c.slot_idx += 1
	return p

func deposit(c: E.Contract, res: String, amt: int, u: E.Unit) -> void:
	if res == "wood": c.wood += amt
	elif res == "food": sim.stock["food"] += amt # rations shared with the tribe
	# stone is consumed by the experiments
	if c.step_idx < c.steps.size():
		var step: Dictionary = c.steps[c.step_idx]
		if step["action"] == "gather_" + res: step["done"] += amt
	sim.popup(u.pos + Vector2(0, -12), "+%d %s" % [amt, res], {"wood": Color("#d8b483"), "stone": Color("#c8c8d0")}.get(res, Color("#f0a07a")))

func _progress(c: E.Contract) -> float:
	var total := 0.0
	var done := 0.0
	for i in c.steps.size():
		var s: Dictionary = c.steps[i]
		var w := 0.0
		var d := 0.0
		match s["action"]:
			"gather_wood", "gather_food", "gather_stone":
				w = s["target_amount"]
				d = minf(s["done"], w)
			"experiment":
				w = s["duration_sec"] * 3.0
				d = minf(s["done"] * 3.0, w)
			"build":
				w = D.STRUCTURES[s["structure"]]["work"] * s["count"]
				for id in s["ids"]:
					var st = sim.struct_by_id(id)
					if st: d += minf(st.progress, st.work)
			"ritual":
				w = s["duration_sec"] * 2.0
				d = minf(s["done"] * 2.0, w)
		if i < c.step_idx: d = w
		total += w
		done += d
	return done / total if total > 0 else 1.0

func _maybe_ambush(c: E.Contract) -> void:
	if not sim.scripted_ambush or c.kind != "settle" or c.ambushed or c.progress < 0.45: return
	c.ambushed = true
	for off in [Vector2(380, -260), Vector2(400, 240)]:
		var p: Vector2 = c.site + off
		p.x = minf(p.x, D.W - 30)
		p.y = clampf(p.y, 40, D.H - 40)
		sim.spawn_predator(p, c.site)
	sim.add_log("Something moves in the tall grass near '%s'..." % c.plan["plan_id"], "danger")

# ------------------------------------------------------------ abort conditions
func _check_aborts(c: E.Contract) -> bool:
	var reason := ""
	for cond in c.plan["abort_conditions"]:
		if cond == "enemy_attack":
			var near: bool = not sim.active_predators_near(c.site, 260).is_empty()
			for u in crew(c):
				if sim.time - u.last_hit_t < 1.0: near = true
			if near: reason = "enemy_attack"
		elif cond == "natural_disaster":
			if sim.flags.get("flood_active", -1.0) >= c.t: reason = "natural_disaster"
		elif cond.begins_with("hp_below_"):
			var pct := float(cond.trim_prefix("hp_below_").trim_suffix("%")) / 100.0
			var ld := leader(c)
			if c.leader_id not in c.resting_ids and ld.hp < ld.max_hp * pct: reason = "leader_wounded"
		if reason != "" and c.abort_cooldowns.get(reason, -1.0) > sim.time: reason = ""
		if reason != "": break
	if reason == "": return false
	c.abort_reason = reason
	c.interruptions += 1
	_set_status(c, "interrupted")
	for u in crew(c): sim.set_job(u, {})
	_clog(c, "ABORT CONDITION: %s at %d%% progress." % [reason, roundi(c.progress * 100)])
	sim.add_log("Contract '%s' interrupted (%s). The leader's LLM node is re-awakening..." % [c.plan["plan_id"], reason], "danger")
	sim.paused = true
	sim.contract_interrupted.emit(c)
	return true

func allowed_effects(c: E.Contract) -> Array:
	match c.abort_reason:
		"enemy_attack":
			var fx := ["hold", "reinforce", "retreat"]
			if sim.stock["lore"] >= 10: fx.append("ward")
			return fx
		"leader_wounded": return ["rest", "press_on", "retreat"]
		"natural_disaster": return ["shelter", "retreat"]
	return ["hold", "retreat"]

func summary(c: E.Contract) -> Dictionary:
	var built: Array = []
	var partial: Array = []
	for id in c.struct_ids:
		var s = sim.struct_by_id(id)
		if s == null: continue
		var n: String = D.STRUCTURES[s.type]["name"]
		if s.built: built.append(n)
		elif s.progress > 0: partial.append("%s (%d%%)" % [n, roundi(s.progress / s.work * 100)])
	var preds: int = sim.active_predators_near(c.site, 500).size()
	var ld := leader(c)
	var crew_state: Array = crew(c, true).map(func(u): return "%s %d/%d HP" % [u.name, roundi(u.hp), roundi(u.max_hp)])
	return {
		"plan_id": c.plan["plan_id"], "progress_pct": roundi(c.progress * 100),
		"current_step": c.substate, "built": built, "half_built": partial,
		"threat": "%d saber-toothed tigers" % preds if preds > 0 else "none visible",
		"reason": c.abort_reason, "leader_hp": "%d/%d" % [roundi(ld.hp), roundi(ld.max_hp)],
		"crew": crew_state, "tribe_lore": roundi(sim.stock["lore"]),
		"idle_warriors_in_village": available_helpers().size(),
	}

# ------------------------------------------------------------ resolution
func resolve(c: E.Contract, effect: String, label := "") -> void:
	if effect not in allowed_effects(c): effect = allowed_effects(c)[0]
	var ld := leader(c)
	_clog(c, "Chieftain's decision: %s" % (label if label != "" else effect))
	c.abort_cooldowns[c.abort_reason] = sim.time + 5.0
	match effect:
		"hold":
			_set_status(c, "defending")
		"reinforce":
			var helpers := available_helpers()
			helpers.sort_custom(func(a, b): return a.lv("combat") > b.lv("combat"))
			for u in helpers.slice(0, 3):
				u.role = "contract"
				u.contract_id = c.id
				c.reinforcement_ids.append(u.id)
				sim.set_job(u, {})
			sim.add_log("%d warriors rush across the ford to reinforce '%s'." % [mini(3, helpers.size()), c.plan["plan_id"]], "contract")
			_set_status(c, "defending")
		"ward":
			sim.stock["lore"] -= 10
			var n: int = sim.scare_predators(c.site, 600)
			sim.gain_xp(ld, "lore", 12)
			sim.remember(ld, "drove off %d beasts with a totem ward on Day %d" % [n, sim.day()], 8)
			sim.popup(c.site + Vector2(0, -50), "Totem Ward!", Color("#c8a8ff"), true)
			_set_status(c, "executing")
		"retreat":
			for u in crew(c, true):
				sim.remember(u, "abandoned the half-built camp '%s' on the east bank on Day %d" % [c.plan["plan_id"], sim.day()], 7)
				_release(u)
				sim.assign_flee(u)
			sim.add_log("'%s' abandoned at %d%%. The crew flees across the river." % [c.plan["plan_id"], roundi(c.progress * 100)], "danger")
			c.status = "abandoned"
		"rest":
			c.resting_ids.append(ld.id)
			sim.set_job(ld, {"type": "move", "to": D.VILLAGE, "flee": true})
			c.abort_cooldowns["leader_wounded"] = INF
			_set_status(c, "executing")
		"press_on":
			c.abort_cooldowns["leader_wounded"] = sim.time + 45.0
			_set_status(c, "executing")
		"shelter":
			c.abort_cooldowns["natural_disaster"] = INF
			_set_status(c, "sheltering")
	if effect != "shelter" and c.abort_reason == "natural_disaster": c.abort_cooldowns["natural_disaster"] = INF

func _defend(c: E.Contract, dt: float) -> void:
	var threats: Array = sim.active_predators_near(c.site, 450)
	var crew_list := crew(c)
	if threats.is_empty():
		c.clear_t += dt
		if c.clear_t > 2.5:
			for u in crew_list:
				sim.remember(u, "held the half-built camp '%s' against saber-tooths on Day %d" % [c.plan["plan_id"], sim.day()], 8)
			_clog(c, "The beasts are gone. Resuming the blueprint where we left off.")
			sim.add_log("'%s' secured. The state machine resumes - no LLM needed." % c.plan["plan_id"], "contract")
			_set_status(c, "executing")
		return
	c.clear_t = 0
	c.substate = "Defending the camp"
	for u in crew_list:
		if u.job.get("type", "") != "attack":
			var nearest = threats[0]
			for p in threats:
				if p.pos.distance_to(u.pos) < nearest.pos.distance_to(u.pos): nearest = p
			sim.assign_attack(u, nearest, "c%d_def" % c.id)

func _release(u: E.Unit) -> void:
	u.role = ""
	u.contract_id = -1
	u.job_key = ""

func _complete(c: E.Contract) -> void:
	c.status = "done"
	c.progress = 1.0
	sim.stock["wood"] += c.wood
	c.wood = 0
	if c.kind == "research":
		_complete_research(c)
		return
	var built: Array = []
	for id in c.struct_ids:
		var s = sim.struct_by_id(id)
		if s and s.built: built.append(D.STRUCTURES[s.type]["name"])
	var ld := leader(c)
	var what := ", ".join(built)
	for u in crew(c, true):
		if c.reinforcement_ids.has(u.id):
			sim.remember(u, "helped defend and finish '%s' on Day %d" % [c.plan["plan_id"], sim.day()], 6)
			u.home = D.VILLAGE
		else:
			var lead: bool = u == ld
			sim.remember(u, ("led" if lead else "helped") + " the founding of '%s' across the river on Day %d (%s)" % [c.plan["plan_id"], sim.day(), what], 9 if lead else 7)
			sim.gain_xp(u, "craft", 10)
			if lead: sim.gain_xp(u, "combat", 15) # leadership
			u.home = c.site
		_release(u)
		sim.set_job(u, {})
	sim.popup(c.site + Vector2(0, -80), "Outpost founded!", Color("#b6f28a"), true)
	sim.add_log("Contract '%s' complete! %s. Housing for %d more." % [c.plan["plan_id"], what, housing(c.plan)], "contract")
	sim.contract_finished.emit(c)

func _complete_research(c: E.Contract) -> void:
	var ld := leader(c)
	var id: String = c.plan["tech"]
	var t: Dictionary = sim.evo.tech_def(id)
	var fresh: bool = not sim.has_tech(id)
	if fresh: sim.evo.breakthrough(id, ld, "invented")
	for u in crew(c, true):
		if u != ld:
			sim.remember(u, "helped %s %s %s on Day %d" % [ld.name, "discover" if fresh else "refine", t["name"], sim.day()], 6)
		sim.evo.learn(u, id)
		sim.gain_xp(u, "lore", 8)
		_release(u)
		sim.set_job(u, {})
	sim.gain_xp(ld, "combat", 8) # leadership
	if not fresh:
		sim.stock["lore"] += 15
		sim.add_log("'%s' finished, but %s was already known - the work became 15 lore." % [c.plan["plan_id"], t["name"]], "contract")
	else:
		sim.add_log("Research contract '%s' complete: %s now knows %s." % [c.plan["plan_id"], ld.name, t["name"]], "contract")
	sim.contract_finished.emit(c)

func _fail(c: E.Contract, why: String) -> void:
	c.status = "failed"
	for u in crew(c, true): _release(u)
	sim.add_log("Contract '%s' failed: %s" % [c.plan["plan_id"], why], "danger")

func _step_text(s: Dictionary) -> String:
	match s["action"]:
		"gather_wood": return "gather %d wood" % s["target_amount"]
		"gather_food": return "gather %d food" % s["target_amount"]
		"gather_stone": return "quarry %d stone" % s["target_amount"]
		"experiment": return "%ds of experiments" % s["duration_sec"]
		"build": return "build %s%s" % [("%d x " % s["count"]) if s["count"] > 1 else "", D.STRUCTURES[s["structure"]]["name"]]
		"ritual": return "%ds blessing ritual" % s["duration_sec"]
	return s["action"]

func step_text(s: Dictionary) -> String: return _step_text(s)
