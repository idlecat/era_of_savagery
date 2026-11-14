## Deterministic real-time simulation layer. No LLM calls, no rendering.
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")
const ContractSystem = preload("res://scripts/contract_system.gd")

signal contract_interrupted(contract)
signal event_fired(event_id)
signal contract_finished(contract)
signal log_added()

var next_id := 1
var time := 0.0
var paused := false
var speed := 1.0
var stock := {"food": 45.0, "wood": 35.0, "lore": 0.0}
var devotion := 0.0
var units: Array = []
var nodes: Array = []
var predators: Array = []
var structures: Array = []
var popups: Array = [] # {pos, text, color, t, life, big}
var log_lines: Array = [] # {day, text, kind}
var techs := {}
var vice := {"steward": -1, "warchief": -1}
var steward_policy := "balanced"
var flags := {}
var llm_calls := 0
var ticks_since_llm := 0
var night_amt := 0.0
var flood_fx := 0.0
var birth_timer := 0.0
var vice_timer := 0.0
var guardian = null
var pending_event := ""
var scripted_ambush := true
# ---- exploration (fog of war) ----
var fog_enabled := true
var fog_w := 0
var fog_h := 0
var explored := PackedByteArray() # 1 = ever seen
var visible := PackedByteArray()  # 1 = seen right now
var fog_t := 0.0
var explored_cells := 0
var land_cells := 1
var landmarks: Array = [] # copies of D.LANDMARKS + {"found": bool}
var contracts: ContractSystem

func _init() -> void:
	contracts = ContractSystem.new(self)

func uid() -> int:
	next_id += 1
	return next_id

# ------------------------------------------------------------------ setup
func new_game() -> void:
	var o := D.HOME_OFS # the original hand-made home area, placed in the middle of the bigger map
	add_structure("bonfire", D.VILLAGE, true)
	add_structure("hut", Vector2(430, 470) + o, true)
	add_structure("hut", Vector2(610, 465) + o, true)
	add_structure("hut", Vector2(440, 660) + o, true)
	add_structure("hut", Vector2(620, 665) + o, true)

	_forest(Vector2(230, 230) + o, 22, 170)
	_forest(Vector2(260, 880) + o, 18, 150)
	_forest(Vector2(900, 140) + o, 10, 120)
	_forest(Vector2(1620, 250) + o, 22, 170)
	_forest(Vector2(1700, 860) + o, 20, 160)
	_forest(Vector2(1420, 900) + o, 8, 90)
	for b in [Vector2(760, 380), Vector2(800, 430), Vector2(720, 760), Vector2(790, 800), Vector2(850, 720), Vector2(1580, 470), Vector2(1660, 640)]:
		var n := _node("bush", "food", b + o, 30)
		n.regrow = 0.25
	_wilds()
	for i in 14: spawn_deer("west", false)
	for i in 12: spawn_deer("east", false)

	var count: int = D.CHARACTERS.size()
	for i in count:
		var a := float(i) / count * TAU
		units.append(make_unit(D.CHARACTERS[i], D.VILLAGE + Vector2(cos(a) * 70, sin(a) * 55)))
	assign_ritual(unit_by_name("Linghe"), D.VILLAGE + Vector2(30, -20))
	assign_gather(unit_by_name("Tuo"), "food")
	assign_gather(unit_by_name("Shan"), "food")
	assign_gather(unit_by_name("Bai"), "wood")
	add_log("The tribe gathers around the bonfire. Saber-tooth tracks have been seen east of the ford.", "story")
	add_log("Beyond the firelight the land is unknown. Send a scout (X) to explore it.", "story")
	_fog_init()
	fog_update()

## Outer wilderness of the big map: random forests and berry patches away from the home area,
## plus the landmarks (and the tiger dens) hidden in the fog.
func _wilds() -> void:
	var home := Rect2(D.VILLAGE - Vector2(700, 600), Vector2(1700, 1200))
	var placed := 0
	var tries := 0
	while placed < 26 and tries < 400:
		tries += 1
		var c := Vector2(randf_range(120, D.W - 120), randf_range(120, D.H - 120))
		if home.has_point(c) or absf(c.x - D.river_x(c.y)) < 220: continue
		var near_lm := false
		for lm in D.LANDMARKS:
			if c.distance_to(lm["pos"]) < 230: near_lm = true
		if near_lm: continue
		_forest(c, randi_range(10, 24), randf_range(110, 200))
		placed += 1
	for i in 8:
		var c := Vector2(randf_range(150, D.W - 150), randf_range(150, D.H - 150))
		if home.has_point(c) or absf(c.x - D.river_x(c.y)) < 160: continue
		for k in 3:
			var n := _node("bush", "food", c + Vector2(randf_range(-50, 50), randf_range(-40, 40)), 30)
			n.regrow = 0.25
	for def in D.LANDMARKS:
		var lm: Dictionary = def.duplicate(true)
		lm["found"] = false
		landmarks.append(lm)
		if lm["id"] == "grove":
			for k in 6:
				var n := _node("bush", "food", lm["pos"] + Vector2.from_angle(k * TAU / 6) * 60, 40)
				n.regrow = 0.35
		for k in int(lm.get("den", 0)):
			var pr := spawn_predator(lm["pos"] + Vector2(randf_range(-60, 60), randf_range(-40, 40)))
			pr.den = lm["pos"]

func _node(kind: String, res: String, p: Vector2, amount: float) -> E.ResNode:
	var n := E.ResNode.new()
	n.id = uid(); n.kind = kind; n.res = res; n.pos = p; n.amount = amount; n.max_amount = amount
	nodes.append(n)
	return n

func _forest(c: Vector2, count: int, spread: float) -> void:
	for i in count:
		var a := randf() * TAU
		var r := sqrt(randf()) * spread
		var p := Vector2(clampf(c.x + cos(a) * r, 20, D.W - 20), clampf(c.y + sin(a) * r * 0.8, 20, D.H - 20))
		if absf(p.x - D.river_x(p.y)) < D.RIVER_HALF + 20: continue
		if p.distance_to(D.VILLAGE) < 190 or p.distance_to(D.EAST_SITE) < 130: continue
		var blocked := false
		for lm in D.LANDMARKS:
			if p.distance_to(lm["pos"]) < 90: blocked = true
		if blocked: continue
		var n := _node("tree", "wood", p, 30)
		n.sz = randf_range(0.8, 1.25)

func spawn_deer(bank: String, from_edge: bool) -> void:
	var p := Vector2.ZERO
	for k in 30:
		if bank == "west":
			p = Vector2(randf_range(30, 120) if from_edge else randf_range(150, D.RIVER_BASE_X - 150), randf_range(60, D.H - 60))
		else:
			p = Vector2(randf_range(D.RIVER_BASE_X + 150, D.W - 80), randf_range(60, D.H - 60))
		if not D.in_river(p) and D.bank_of(p) == bank and p.distance_to(D.VILLAGE) > 220: break
	var n := _node("deer", "food", p, 25)
	n.bank = bank

func make_unit(def: Dictionary, p: Vector2) -> E.Unit:
	var u := E.Unit.new()
	u.id = uid()
	u.name = def["name"]; u.epithet = def.get("epithet", ""); u.traits = def["traits"].duplicate()
	u.color = def.get("color", Color(0.7, 0.7, 0.7))
	u.pos = p; u.home = D.VILLAGE
	u.max_hp = def["hp"]; u.hp = u.max_hp; u.hunger = randf_range(65, 90)
	u.atk = def["atk"]; u.def = def["def"]; u.spd = def["spd"]
	for s in D.SKILLS:
		u.skills[s] = {"lv": int(def["skills"].get(s, 0)), "xp": 0.0}
	for m in def.get("memory", []):
		u.memory.append(m.duplicate())
	u.wander_t = randf_range(0, 4)
	u.hero = def.get("hero", false)
	return u

func add_structure(type: String, p: Vector2, built := false, owner := "village", paid := false) -> E.Structure:
	var s := E.Structure.new()
	s.id = uid(); s.type = type; s.pos = p; s.built = built
	s.work = D.STRUCTURES[type]["work"]; s.progress = s.work if built else 0.0
	s.paid = built or paid; s.owner = owner
	structures.append(s)
	return s

# ------------------------------------------------------------------ helpers
func add_log(text: String, kind := "info") -> void:
	log_lines.push_front({"day": day(), "text": text, "kind": kind})
	if log_lines.size() > 80: log_lines.pop_back()
	log_added.emit()

func popup(p: Vector2, text: String, color := Color("#ffe08a"), big := false) -> void:
	popups.append({"pos": p, "text": text, "color": color, "t": 0.0, "life": 2.6 if big else 1.6, "big": big})

func day() -> int: return int(time / D.DAY_LEN) + 1
func day_frac() -> float: return fmod(time, D.DAY_LEN) / D.DAY_LEN
func has_tech(t: String) -> bool: return techs.has(t)
func living() -> Array: return units.filter(func(u): return not u.dead)

func unit_by_id(id: int) -> E.Unit:
	for u in units:
		if u.id == id: return u
	return null
func unit_by_name(n: String) -> E.Unit:
	for u in units:
		if u.name == n: return u
	return null
func struct_by_id(id: int) -> E.Structure:
	for s in structures:
		if s.id == id: return s
	return null
func node_by_id(id: int) -> E.ResNode:
	for n in nodes:
		if n.id == id: return n
	return null
func pred_by_id(id: int) -> E.Predator:
	for p in predators:
		if p.id == id: return p
	return null

func arch(u: E.Unit) -> String:
	return D.TRAITS.get(u.traits[0], D.TRAITS["cautious"])["arch"]

func unit_level(u: E.Unit) -> int:
	var s := 0
	for k in D.SKILLS: s += u.lv(k)
	return 1 + s / 2

func pop_cap() -> int:
	var c := 0
	for s in structures:
		if s.built: c += int(D.STRUCTURES[s.type].get("cap", 0))
	return c

func near_warmth(u: E.Unit) -> bool:
	var r := 110.0 * (2.0 if has_tech("fire") else 1.0)
	for s in structures:
		if s.built and s.type == "bonfire" and s.pos.distance_to(u.pos) < r: return true
	return false

func _struct_near(type: String, p: Vector2, r: float) -> bool:
	for s in structures:
		if s.built and s.type == type and s.pos.distance_to(p) < r: return true
	return false

# ------------------------------------------------------------------ stats
func unit_atk(u: E.Unit) -> float:
	var a := u.atk * (1.0 + 0.15 * u.lv("combat"))
	if has_tech("tools"): a += 2
	if has_tech("bronze"): a *= 1.6
	if _struct_near("weapon_rack", u.pos, 160): a *= 1.2
	return a

func unit_def(u: E.Unit) -> float:
	var d := u.def * (1.0 + 0.15 * u.lv("combat"))
	if has_tech("hide"): d += 2
	if has_tech("bronze"): d += 3
	if _struct_near("palisade", u.pos, 115): d += 3
	for o in units: # Centurion Aura
		if not o.dead and o != u and o.lv("combat") >= 5 and o.pos.distance_to(u.pos) < 110:
			d *= 1.2
			break
	return d

func unit_speed(u: E.Unit) -> float:
	var s := 58.0 * u.spd
	if u.hp < u.max_hp * 0.3: s *= 0.7
	if u.job.get("type", "") == "explore": s *= 1.15 # scouts travel light
	return s

func work_mul(u: E.Unit) -> float: return 0.9 if u.has_trait("lazy") else 1.0
func carry_cap(_u: E.Unit) -> int: return 15 if has_tech("domestication") else 10

# ------------------------------------------------------------------ XP & memory
func xp_need(lv: int) -> float: return 25.0 + lv * 20.0

func gain_xp(u: E.Unit, skill: String, amt: float) -> void:
	var s: Dictionary = u.skills[skill]
	if s["lv"] >= 10 or u.dead: return
	s["xp"] += amt
	u.xp_acc += amt
	while s["lv"] < 10 and s["xp"] >= xp_need(s["lv"]):
		s["xp"] -= xp_need(s["lv"])
		s["lv"] += 1
		popup(u.pos + Vector2(0, -34), "LEVEL UP! %s Lv.%d" % [D.SKILL_NAMES[skill].split(" ")[0], s["lv"]], Color("#7ff0ff"), true)
		add_log("%s reached %s Lv.%d." % [u.name, D.SKILL_NAMES[skill], s["lv"]], "xp")
		if s["lv"] == 5 and not u.unlocked.has(skill):
			u.unlocked[skill] = true
			remember(u, "mastered %s and unlocked [%s]" % [D.SKILL_NAMES[skill].to_lower(), D.SKILL_UNLOCKS[skill]], 7)
			add_log("%s unlocked [%s]!" % [u.name, D.SKILL_UNLOCKS[skill]], "story")

## Memory stream: keep the ~10 most impactful events.
func remember(u: E.Unit, text: String, impact: int) -> void:
	u.memory.append({"day": day(), "text": text, "impact": impact, "t": time})
	u.memory.sort_custom(func(a, b):
		if a["impact"] != b["impact"]: return a["impact"] > b["impact"]
		return a.get("t", -1e9) > b.get("t", -1e9))
	if u.memory.size() > 10: u.memory.resize(10)

# ------------------------------------------------------------------ movement
func set_dest(e, target: Vector2) -> void:
	var t := Vector2(clampf(target.x, 10, D.W - 10), clampf(target.y, 10, D.H - 10))
	if D.is_water(t):
		var rx := D.river_x(t.y)
		t.x = rx - D.RIVER_HALF - 8 if t.x < rx else rx + D.RIVER_HALF + 8
	var path: Array = []
	var my_bank := D.bank_of(e.pos)
	var t_bank := D.bank_of(t)
	var fx := D.river_x(D.FORD_Y)
	var w_entry := Vector2(fx - D.RIVER_HALF - 30, D.FORD_Y)
	var e_entry := Vector2(fx + D.RIVER_HALF + 30, D.FORD_Y)
	if D.in_river(e.pos):
		path.append(w_entry if t_bank == "west" else e_entry)
	elif my_bank != t_bank:
		path.append(w_entry if my_bank == "west" else e_entry)
		path.append(e_entry if my_bank == "west" else w_entry)
	path.append(t)
	e.path = path
	if e is E.Unit: e.dest = t

func go_to(u: E.Unit, t: Vector2) -> void:
	if u.dest == null or (u.dest as Vector2).distance_to(t) > 14 or u.path.is_empty():
		set_dest(u, t)

## Moves an entity along its path. Returns true once the path is finished.
func step_move(e, dt: float, spd: float) -> bool:
	if e.path.is_empty(): return true
	var wp: Vector2 = e.path[0]
	var sp := spd * (0.55 if D.in_river(e.pos) else 1.0)
	var d: float = e.pos.distance_to(wp)
	var step := sp * dt
	if d <= step:
		e.pos = wp
		e.path.pop_front()
		return e.path.is_empty()
	var np: Vector2 = e.pos + (wp - e.pos) / d * step
	if D.is_water(np) and not D.is_water(e.pos): # slide along the bank
		var rx := D.river_x(np.y)
		np.x = rx - D.RIVER_HALF - 1 if D.bank_of(e.pos) == "west" else rx + D.RIVER_HALF + 1
	e.pos = np
	return false

func approach(u: E.Unit, t: Vector2, near: float, dt: float) -> bool:
	if u.pos.distance_to(t) <= near:
		u.path.clear()
		return true
	go_to(u, t)
	step_move(u, dt, unit_speed(u))
	return u.pos.distance_to(t) <= near

# ------------------------------------------------------------------ jobs
func set_job(u: E.Unit, job: Dictionary, key := "") -> void:
	u.job = job
	u.job_key = key
	u.path.clear()
	u.dest = null
	u.gather_t = 0.0

func assign_move(u: E.Unit, p: Vector2) -> void: set_job(u, {"type": "move", "to": p})
func assign_flee(u: E.Unit) -> void:
	set_job(u, {"type": "move", "to": u.home + Vector2(randf_range(-30, 30), randf_range(-30, 30)), "flee": true})
func assign_gather(u: E.Unit, res: String, opts := {}) -> void:
	set_job(u, {"type": "gather", "res": res, "node_id": opts.get("node_id", -1),
		"dropoff": opts.get("dropoff", -1), "area": opts.get("area", null), "area_r": opts.get("area_r", 2000.0),
		"bank": opts.get("bank", ""), "phase": "collect"}, opts.get("key", ""))
func assign_build(u: E.Unit, s: E.Structure, key := "") -> void: set_job(u, {"type": "build", "struct_id": s.id}, key)
func assign_attack(u: E.Unit, p: E.Predator, key := "") -> void: set_job(u, {"type": "attack", "target_id": p.id}, key)
func assign_ritual(u: E.Unit, p: Vector2, key := "") -> void: set_job(u, {"type": "ritual", "at": p, "elapsed": 0.0}, key)
## AoE2-DE-style auto-scout: keep walking to the nearest unexplored land.
func assign_explore(u: E.Unit) -> void: set_job(u, {"type": "explore", "to": null})

func find_node(res: String, from: Vector2, bank: String, max_dist: float) -> E.ResNode:
	var best: E.ResNode = null
	var best_score := INF
	for n in nodes:
		if n.res != res or n.amount < 1: continue
		if bank != "" and D.bank_of(n.pos) != bank: continue
		var d: float = n.pos.distance_to(from)
		if d > max_dist: continue
		var claims := 0
		for u in units:
			if not u.dead and u.job.get("node_id", -2) == n.id: claims += 1
		var score := d + claims * 70.0 + (60.0 if n.kind == "deer" else 0.0) + (0.0 if is_explored(n.pos) else 900.0)
		if score < best_score:
			best_score = score
			best = n
	return best

# ------------------------------------------------------------------ unit update
func update_unit(u: E.Unit, dt: float) -> void:
	if u.dead: return
	unit_needs(u, dt)
	u.cd -= dt
	u.xp_flush_t -= dt
	if u.xp_acc >= 1 and u.xp_flush_t <= 0:
		popup(u.pos + Vector2(0, -22), "+%d EXP" % roundi(u.xp_acc))
		u.xp_acc = 0
		u.xp_flush_t = 1.6

	# Self-defense or flight when attacked
	if time - u.last_hit_t < 2 and u.attacker_id >= 0:
		var p := pred_by_id(u.attacker_id)
		if p and not p.dead and not p.fleeing:
			var low := u.hp < u.max_hp * 0.22
			var jt: String = u.job.get("type", "")
			if jt == "explore":
				assign_flee(u)
				popup(u.pos + Vector2(0, -26), "Scout retreats!", Color("#ff9b7a"))
			elif low and not u.has_trait("belligerent") and not u.job.get("flee", false):
				assign_flee(u)
				popup(u.pos + Vector2(0, -26), "Flees!", Color("#ff9b7a"))
			elif not low and jt != "attack" and jt != "move":
				if u.resume_job.is_empty() and not u.job.is_empty():
					u.resume_job = u.job
					u.resume_key = u.job_key
				assign_attack(u, p, u.job_key)

	if u.job.is_empty():
		unit_idle(u, dt)
		return
	var j := u.job
	match j["type"]:
		"move":
			u.act = "Fleeing" if j.get("flee", false) else "Moving"
			if approach(u, j["to"], 4, dt):
				if u.resume_job.get("type", "") == "explore":
					u.resume_job = {}
					assign_explore(u)
				else:
					set_job(u, {})
		"gather":
			_do_gather(u, j, dt)
		"build":
			var s := struct_by_id(j["struct_id"])
			if s == null or s.built:
				set_job(u, {})
				return
			var sd: Dictionary = D.STRUCTURES[s.type]
			var ring: bool = sd.get("ring", false)
			var tgt: Vector2 = s.pos + Vector2(cos(u.id), sin(u.id)) * sd["r"] if ring else s.pos
			var near: float = 18.0 if ring else sd["r"] + 10.0
			if not s.paid:
				u.act = "Waiting for materials"
				return
			if approach(u, tgt, near, dt):
				u.act = "Building " + sd["name"]
				s.progress += dt * (1.0 + 0.12 * u.lv("craft")) * work_mul(u)
				gain_xp(u, "craft", dt * 0.9)
				if s.progress >= s.work: complete_structure(s, u)
			else:
				u.act = "Walking to " + sd["name"]
		"attack":
			var p := pred_by_id(j["target_id"])
			if p == null or p.dead or p.fled or p.fleeing:
				if not u.resume_job.is_empty():
					var rj := u.resume_job
					u.resume_job = {}
					set_job(u, rj, u.resume_key)
				else:
					set_job(u, {})
				return
			u.act = "Fighting"
			if approach(u, p.pos, 22, dt) and u.cd <= 0:
				u.cd = 1.0
				var dmg := unit_atk(u) * randf_range(0.8, 1.2) * (10.0 / (10.0 + p.def))
				var crit := randf() < 0.05 * u.lv("forage")
				damage_pred(p, dmg * 1.8 if crit else dmg, u, crit)
				gain_xp(u, "combat", 1.2)
		"explore":
			u.act = "Scouting"
			var threat := active_predators_near(u.pos, 240)
			if not threat.is_empty(): # scouts keep their distance from beasts they can see
				var away: Vector2 = (u.pos - threat[0].pos).normalized()
				j["to"] = null
				set_job(u, {"type": "move", "to": u.pos + away * 260, "flee": true})
				u.resume_job = {"type": "explore", "to": null}
				popup(u.pos + Vector2(0, -30), "Beast! Scout backs off", Color("#ff9b7a"))
				return
			var tgt: Variant = j.get("to")
			if tgt == null or is_explored(tgt):
				tgt = explore_target(u)
				if tgt == null:
					set_job(u, {})
					popup(u.pos + Vector2(0, -30), "Nothing left to explore", Color("#9fd0ff"))
					return
				j["to"] = tgt
			if approach(u, tgt, 12, dt): j["to"] = null
			gain_xp(u, "forage", dt * 0.12)
		"ritual":
			if approach(u, j["at"], 6, dt):
				u.act = "Performing ritual"
				var boost := 1.5 if (_struct_near("totem_shrine", u.pos, 140) or _struct_near("grand_altar", u.pos, 140)) else 1.0
				stock["lore"] += dt * 0.22 * (1.0 + 0.2 * u.lv("lore")) * boost
				devotion = minf(100.0, devotion + dt * 0.07 * (1.0 + 0.1 * u.lv("lore")))
				gain_xp(u, "lore", dt * 0.6)
				j["elapsed"] = j.get("elapsed", 0.0) + dt
			else:
				u.act = "Walking to ritual ground"

func _dropoff_point(j: Dictionary) -> Vector2:
	if j["dropoff"] >= 0:
		var c = contracts.by_id(j["dropoff"])
		if c: return c.site
	return D.VILLAGE

func _do_gather(u: E.Unit, j: Dictionary, dt: float) -> void:
	var cap := carry_cap(u)
	if j["phase"] == "deliver" or u.carry_amt >= cap:
		j["phase"] = "deliver"
		var dp := _dropoff_point(j) + Vector2((u.id * 13) % 30 - 15, (u.id * 7) % 30 - 15)
		u.act = "Hauling " + j["res"]
		if approach(u, dp, 20, dt):
			if u.carry_amt > 0: deposit(u, j, u.carry_amt)
			u.carry_amt = 0
			j["phase"] = "collect"
			j["node_id"] = -1
		return
	var n := node_by_id(j["node_id"]) if j["node_id"] >= 0 else null
	if n == null or n.amount < 1:
		var from: Vector2 = j["area"] if j["area"] != null else u.pos
		n = find_node(j["res"], from, j["bank"], j["area_r"])
		if n == null:
			if u.carry_amt > 0: j["phase"] = "deliver"
			u.act = "No %s nearby" % j["res"]
			return
		j["node_id"] = n.id
	if approach(u, n.pos, 16.0 if n.kind == "tree" else 14.0, dt):
		if n.kind == "deer": # the hunt
			n.kind = "carcass"
			n.from_deer = true
			n.vel = Vector2.ZERO
			gain_xp(u, "forage", 3)
			gain_xp(u, "combat", 1)
			if randf() < 0.05 * u.lv("forage"):
				popup(u.pos + Vector2(0, -30), "Lethal strike!", Color("#ffb36b"))
				n.amount += 5
		u.act = {"tree": "Chopping wood", "carcass": "Butchering game"}.get(n.kind, "Picking berries")
		var base: float = {"tree": 1.2, "carcass": 1.4}.get(n.kind, 1.0)
		var rate := base * (1.0 + 0.1 * u.lv("forage")) * (1.3 if has_tech("tools") and n.kind != "bush" else 1.0) * work_mul(u)
		u.gather_t += dt * rate
		while u.gather_t >= 1 and n.amount >= 1:
			u.gather_t -= 1
			n.amount -= 1
			u.carry_type = j["res"]
			u.carry_amt += 1
			if u.carry_amt >= cap:
				j["phase"] = "deliver"
				break
		if n.amount < 1: _deplete(n)
	else:
		u.act = "Walking to forest" if n.kind == "tree" else "Walking to food"

func _deplete(n: E.ResNode) -> void:
	if n.kind == "tree":
		n.kind = "stump"
		n.regrow_t = 140
	elif n.kind == "carcass":
		nodes.erase(n)
		if n.from_deer: spawn_deer(n.bank, true)

func deposit(u: E.Unit, j: Dictionary, amt: int) -> void:
	gain_xp(u, "forage", amt * 0.45)
	if j["dropoff"] >= 0:
		var c = contracts.by_id(j["dropoff"])
		if c:
			contracts.deposit(c, j["res"], amt, u)
			return
	stock[j["res"]] += amt
	popup(u.pos + Vector2(0, -12), "+%d %s" % [amt, j["res"]], Color("#d8b483") if j["res"] == "wood" else Color("#f0a07a"))

func complete_structure(s: E.Structure, u: E.Unit) -> void:
	s.built = true
	s.progress = s.work
	var name: String = D.STRUCTURES[s.type]["name"]
	popup(s.pos + Vector2(0, -30), name + " complete!", Color("#b6f28a"), true)
	add_log("%s completed%s." % [name, (" by " + u.name + "'s crew") if u else ""], "build")
	if s.type == "grand_altar": summon_guardian(s)

func unit_idle(u: E.Unit, dt: float) -> void:
	u.act = "Idle"
	if u.has_trait("devout") and u.role != "contract" and D.bank_of(u.pos) == D.bank_of(u.home):
		u.idle_t += dt
		if u.idle_t > 4:
			u.idle_t = 0
			assign_ritual(u, u.home + Vector2(randf_range(-40, 40), randf_range(-50, -20)))
		return
	u.wander_t -= dt
	if u.wander_t <= 0:
		u.wander_t = randf_range(3, 7)
		u.wander_to = u.home + Vector2(randf_range(-80, 80), randf_range(-70, 70))
		u.path.clear()
		u.dest = null
	if u.wander_to != null and u.pos.distance_to(u.wander_to) > 4:
		go_to(u, u.wander_to)
		step_move(u, dt, unit_speed(u) * 0.4)

func unit_needs(u: E.Unit, dt: float) -> void:
	var drain := 0.33 * (1.25 if u.has_trait("gluttonous") else 1.0)
	u.hunger -= drain * dt
	if u.hunger < 40 and stock["food"] >= 1:
		stock["food"] -= 1
		u.hunger = minf(100, u.hunger + (38.0 if has_tech("fire") else 30.0))
	if u.hunger <= 0:
		u.hunger = 0
		hurt_unit(u, 0.5 * dt, null)
	var warm := near_warmth(u)
	if night_amt > 0.5 and not has_tech("hide") and not warm and u.hp > u.max_hp * 0.35:
		u.hp -= 0.3 * dt
	elif u.hunger > 35 and time - u.last_hit_t > 5:
		u.hp = minf(u.max_hp, u.hp + (0.7 if warm else 0.15) * dt)

func hurt_unit(u: E.Unit, dmg: float, attacker) -> void:
	if u.dead: return
	u.hp -= dmg
	if attacker:
		u.last_hit_t = time
		u.attacker_id = attacker.id
	if u.hp <= 0: kill_unit(u, attacker)

func kill_unit(u: E.Unit, killer) -> void:
	u.dead = true
	u.hp = 0
	u.job = {}
	var cause: String = ("slain by a " + killer.name) if killer else "lost to hunger and cold"
	add_log("%s has fallen - %s." % [u.name, cause], "danger")
	popup(u.pos + Vector2(0, -30), u.name + " has fallen", Color("#ff6b6b"), true)
	for o in units:
		if not o.dead and o != u and o.pos.distance_to(u.pos) < 300:
			remember(o, "witnessed %s %s on Day %d" % [u.name, cause, day()], 8)
	if vice["steward"] == u.id: vice["steward"] = -1
	if vice["warchief"] == u.id: vice["warchief"] = -1

# ------------------------------------------------------------------ predators
func spawn_predator(p: Vector2, goal: Variant = null) -> E.Predator:
	var pr := E.Predator.new()
	pr.id = uid(); pr.pos = p; pr.goal = goal
	predators.append(pr)
	return pr

func damage_pred(p: E.Predator, dmg: float, u: E.Unit, crit: bool) -> void:
	p.hp -= dmg
	popup(p.pos + Vector2(randf_range(-8, 8), -20), "%s-%d" % ["CRIT " if crit else "", roundi(dmg)], Color("#ffb36b") if crit else Color("#ffd0d0"))
	if p.hp <= 0 and not p.dead:
		p.dead = true
		if u:
			u.kills += 1
			gain_xp(u, "combat", 18)
			remember(u, "slew a %s on the %s bank on Day %d" % [p.name, D.bank_of(p.pos), day()], 8)
			add_log("%s slew a %s!" % [u.name, p.name], "combat")
		_node("carcass", "food", p.pos, 35)
	elif p.hp < p.max_hp * 0.2 and not p.fleeing:
		p.fleeing = true
		popup(p.pos + Vector2(0, -30), "retreats!", Color("#ffd0d0"))

func update_predator(p: E.Predator, dt: float) -> void:
	if p.dead or p.fled: return
	p.cd -= dt
	if p.fleeing:
		p.path = [Vector2(D.W + 40, p.pos.y)]
		step_move(p, dt, p.spd * 1.1)
		if p.pos.x > D.W: p.fled = true
		return
	var prey = null
	var best := 280.0
	for u in units:
		if u.dead: continue
		var d: float = u.pos.distance_to(p.pos)
		if d < best and D.bank_of(u.pos) == D.bank_of(p.pos) and (p.den == null or u.pos.distance_to(p.den) < 380):
			best = d
			prey = u
	if prey == null and guardian and not guardian.dead and guardian.pos.distance_to(p.pos) < 280:
		prey = guardian
	if prey:
		if prey.pos.distance_to(p.pos) > 20:
			p.path = [prey.pos]
			step_move(p, dt, p.spd)
		elif p.cd <= 0:
			p.cd = 1.25
			if prey == guardian:
				guardian.hp -= p.atk * 0.6
			else:
				var dmg := p.atk * randf_range(0.8, 1.2) * (10.0 / (10.0 + unit_def(prey)))
				hurt_unit(prey, dmg, p)
				popup(prey.pos + Vector2(0, -20), "-%d" % roundi(dmg), Color("#ff8080"))
	elif p.goal != null:
		if p.pos.distance_to(p.goal) > 30:
			p.path = [p.goal]
			step_move(p, dt, p.spd * 0.8)
	else:
		p.prowl_t -= dt
		if p.prowl_t <= 0:
			p.prowl_t = randf_range(3, 6)
			var c: Vector2 = p.den if p.den != null else p.pos
			var r := 220.0 if p.den != null else 120.0
			var np := Vector2(clampf(c.x + randf_range(-r, r), D.river_x(p.pos.y) + D.RIVER_HALF + 80, D.W - 30), clampf(c.y + randf_range(-r, r), 40, D.H - 40))
			p.path = [np]
		step_move(p, dt, p.spd * 0.35)

func active_predators_near(center: Vector2, r: float) -> Array:
	return predators.filter(func(p): return not p.dead and not p.fled and not p.fleeing and p.pos.distance_to(center) < r)

func scare_predators(center: Vector2, r: float) -> int:
	var n := 0
	for p in active_predators_near(center, r):
		p.fleeing = true
		n += 1
	return n

func summon_guardian(altar: E.Structure) -> void:
	guardian = E.Guardian.new()
	guardian.id = uid()
	guardian.pos = altar.pos + Vector2(0, -40)
	add_log("The Grand Altar thunders - Yinglong, the winged dragon, answers the tribe's call!", "story")
	popup(altar.pos + Vector2(0, -60), "Yinglong descends!", Color("#9ff0d0"), true)

func _update_guardian(dt: float) -> void:
	if guardian == null or guardian.dead: return
	var g = guardian
	if g.hp <= 0:
		g.dead = true
		add_log("Yinglong returns to the clouds, wounded.", "story")
		return
	g.cd -= dt
	var target = null
	var best := 900.0
	for p in predators:
		if p.dead or p.fled: continue
		var d: float = p.pos.distance_to(g.pos)
		if d < best:
			best = d
			target = p
	if target:
		if best > 30:
			g.path = [target.pos]
			step_move(g, dt, 130)
		elif g.cd <= 0:
			g.cd = 0.9
			damage_pred(target, 22, null, false)
	else:
		g.t += dt
		g.path = [D.VILLAGE + Vector2(cos(g.t * 0.5) * 140, -60 + sin(g.t * 0.5) * 80)]
		step_move(g, dt, 80)

# ------------------------------------------------------------------ world tick
func tick(dt: float) -> void:
	time += dt
	ticks_since_llm += 1
	var f := day_frac()
	var target := 1.0 if (f > 0.72 and f < 0.97) else 0.0
	night_amt += (target - night_amt) * minf(1.0, dt * 0.8)

	var spoil := 0.0012 * (0.5 if has_tech("pottery") else 1.0)
	if stock["food"] > 30: stock["food"] -= (stock["food"] - 30) * spoil * dt
	for s in structures:
		if not s.built: continue
		var sd: Dictionary = D.STRUCTURES[s.type]
		stock["food"] += sd.get("food", 0.0) * dt
		stock["lore"] += sd.get("lore", 0.0) * dt
	stock["lore"] += 0.03 * dt

	for n in nodes:
		match n.kind:
			"bush":
				n.amount = minf(n.max_amount, n.amount + n.regrow * dt)
			"stump":
				n.regrow_t -= dt
				if n.regrow_t <= 0:
					n.kind = "tree"
					n.amount = n.max_amount
			"deer":
				n.wander_t -= dt
				if n.wander_t <= 0:
					n.wander_t = randf_range(2, 5)
					n.vel = Vector2.from_angle(randf() * TAU) * 14
				var np: Vector2 = n.pos + n.vel * dt
				if not D.in_river(np) and D.bank_of(np) == n.bank and np.x > 20 and np.x < D.W - 20 and np.y > 20 and np.y < D.H - 20 and np.distance_to(D.VILLAGE) > 150:
					n.pos = np
				else:
					n.vel = -n.vel

	for u in units: update_unit(u, dt)
	fog_t -= dt
	if fog_t <= 0:
		fog_t = 0.2
		fog_update()
	for p in predators: update_predator(p, dt)
	predators = predators.filter(func(p): return not p.fled)
	_update_guardian(dt)
	contracts.update(dt)
	_update_vice(dt)
	_update_births(dt)

	for p in popups:
		p["t"] += dt
		p["pos"].y -= dt * (14.0 if p["big"] else 22.0)
	popups = popups.filter(func(p): return p["t"] < p["life"])
	if flood_fx > 0: flood_fx = maxf(0, flood_fx - dt * 0.08)
	_check_events()

func _update_births(dt: float) -> void:
	var pop := living().size()
	if pop < pop_cap() and stock["food"] >= 30:
		birth_timer += dt
		if birth_timer > 32:
			birth_timer = 0
			stock["food"] -= 15
			var free: Array = D.BIRTH_NAMES.filter(func(n): return unit_by_name(n) == null)
			var nm: String = free.pick_random() if not free.is_empty() else "Nameless"
			var u := make_unit({"name": nm, "epithet": "Newcomer", "traits": [D.TRAITS.keys().pick_random()],
				"color": Color(D.BIRTH_COLORS.pick_random()), "hp": randi_range(40, 52), "atk": randi_range(3, 6),
				"def": 2, "spd": randf_range(0.9, 1.1),
				"skills": {"forage": randi_range(0, 2), "craft": randi_range(0, 2), "combat": randi_range(0, 1), "lore": randi_range(0, 1)}},
				D.VILLAGE + Vector2(randf_range(-30, 30), randf_range(20, 50)))
			remember(u, "was born beside the tribal bonfire on Day %d" % day(), 5)
			units.append(u)
			add_log("%s (%s) was born into the tribe." % [nm, D.TRAITS[u.traits[0]]["name"]], "story")
			popup(u.pos + Vector2(0, -24), nm + " is born!", Color("#ffd6f0"), true)
	else:
		birth_timer = maxf(0, birth_timer - dt)

# ------------------------------------------------------------------ Tier 3: Vice-Chieftains
func vice_slots() -> int: return 2 if has_tech("code") else 1

func appoint(u: E.Unit, role: String) -> bool:
	var used := 0
	for k in vice:
		if vice[k] >= 0 and k != role: used += 1
	if used >= vice_slots(): return false
	for k in vice:
		if vice[k] == u.id: vice[k] = -1
	vice[role] = u.id
	u.title = "Steward" if role == "steward" else "War Chief"
	remember(u, "was appointed %s of the tribe on Day %d" % [u.title, day()], 7)
	add_log("%s appointed as Vice-Chieftain (%s)." % [u.name, u.title], "vice")
	return true

func _update_vice(dt: float) -> void:
	vice_timer -= dt
	if vice_timer > 0: return
	vice_timer = 3
	var steward := unit_by_id(vice["steward"])
	if steward and not steward.dead:
		var idle := living().filter(func(u): return u.job.is_empty() and u.role != "contract" and u.id != steward.id and D.bank_of(u.pos) == "west")
		var pop := living().size()
		for u in idle:
			var unbuilt = null
			for s in structures:
				if not s.built and s.paid and s.owner == "village":
					unbuilt = s
					break
			var choice: String
			if unbuilt and randf() < 0.5: choice = "build"
			elif stock["food"] < pop * 4 or steward_policy == "food": choice = "food"
			elif steward_policy == "wood" or stock["wood"] < 40: choice = "wood"
			elif steward_policy == "lore": choice = "lore"
			else: choice = "food" if randf() < 0.5 else "wood"
			match choice:
				"build": assign_build(u, unbuilt)
				"lore": assign_ritual(u, D.VILLAGE + Vector2(randf_range(-60, 60), -randf_range(30, 70)))
				_: assign_gather(u, choice, {"bank": "west"})
			gain_xp(steward, "lore", 0.5)
		if not idle.is_empty():
			add_log("Steward %s put %d idle hands to work (%s)." % [steward.name, idle.size(), steward_policy], "vice")
	var chief := unit_by_id(vice["warchief"])
	if chief and not chief.dead:
		var threats := active_predators_near(D.VILLAGE, 500)
		if not threats.is_empty():
			var fighters := living().filter(func(u): return u.role != "contract" and u.job.get("type", "") != "attack")
			fighters.sort_custom(func(a, b): return a.lv("combat") > b.lv("combat"))
			for u in fighters.slice(0, 3): assign_attack(u, threats[0])
			add_log("War Chief %s rallies warriors against the beast!" % chief.name, "vice")

# ------------------------------------------------------------------ village building (Tier 1)
func can_place(type: String, p: Vector2) -> String:
	var sd: Dictionary = D.STRUCTURES[type]
	if sd.has("tech") and not has_tech(sd["tech"]): return "Requires tech"
	if stock["wood"] < sd["wood"]: return "Not enough wood"
	if absf(p.x - D.river_x(p.y)) < D.RIVER_HALF + 15: return "Too close to the river"
	return ""

func place_structure(type: String, p: Vector2) -> E.Structure:
	if can_place(type, p) != "": return null
	stock["wood"] -= D.STRUCTURES[type]["wood"]
	var s := add_structure(type, p, false, "village", true)
	add_log("Construction site laid out: %s." % D.STRUCTURES[type]["name"], "build")
	return s

func research(tech_id: String) -> String:
	for t in D.TECHS:
		if t["id"] != tech_id: continue
		if has_tech(tech_id): return "Already known"
		for r in t["req"]:
			if not has_tech(r): return "Requires prior wisdom"
		if stock["lore"] < t["cost"]: return "Not enough lore"
		stock["lore"] -= t["cost"]
		techs[tech_id] = true
		add_log("Tribal Wisdom unlocked: %s - %s" % [t["name"], t["desc"]], "tech")
		var shaman = null
		for u in living():
			if shaman == null or u.lv("lore") > shaman.lv("lore"): shaman = u
		if shaman: remember(shaman, "revealed the wisdom of %s to the tribe on Day %d" % [t["name"], day()], 6)
		return ""
	return "Unknown tech"

# ------------------------------------------------------------------ milestone events
func _check_events() -> void:
	if pending_event != "": return
	if not flags.has("flood") and time >= (D.FLOOD_DAY - 1) * D.DAY_LEN + 5:
		flags["flood"] = true
		_fire_event("flood")
	elif not flags.has("overpop") and living().size() >= D.OVERPOP_THRESHOLD:
		flags["overpop"] = true
		_fire_event("overpop")
	elif not flags.has("chosen") and devotion >= 100:
		flags["chosen"] = true
		_fire_event("chosen")

func _fire_event(id: String) -> void:
	pending_event = id
	paused = true
	event_fired.emit(id)

func flood_strike() -> void:
	flood_fx = 1.0
	var lost := floori(stock["food"] * 0.5)
	stock["food"] -= lost
	var hurt := 0
	for u in living():
		if absf(u.pos.x - D.river_x(u.pos.y)) < 260:
			hurt_unit(u, u.max_hp * 0.25, null)
			hurt += 1
			remember(u, "survived the Great Flood on Day %d" % day(), 7)
	for s in structures:
		if s.built and s.type != "palisade" and absf(s.pos.x - D.river_x(s.pos.y)) < 220:
			s.built = false
			s.progress = s.work * 0.4
	add_log("The Great Flood strikes! %d food washed away, %d hurt, riverside structures damaged." % [lost, hurt], "danger")
	flags["flood_active"] = time

func best_unit(skill: String, exclude_contract := true) -> E.Unit:
	var best: E.Unit = null
	for u in living():
		if exclude_contract and u.role == "contract": continue
		if best == null or u.lv(skill) > best.lv(skill): best = u
	return best

## Civilization-style dilemmas. Each option: {label, desc, enabled}.
func event_def(id: String) -> Dictionary:
	var shaman := best_unit("lore", false)
	var sname: String = shaman.name if shaman else "The elders"
	match id:
		"flood":
			var chance := clampf(0.35 + 0.1 * (shaman.lv("lore") if shaman else 0), 0.0, 0.9)
			return {"title": "The Great Flood Warning",
				"text": "%s wakes screaming: in the vision, black rains fall for nine nights and the river swallows the low camps. The elders look to you, Great Chieftain." % sname,
				"options": [
					{"label": "The Ark Plan", "desc": "Spend 40 wood on highland rafts and shelters. Everyone and everything is saved.", "enabled": stock["wood"] >= 40},
					{"label": "Sacrifice to the River Deity", "desc": "Offer 25 food and relics. %d%% chance (scales with %s's Shamanism)." % [roundi(chance * 100), sname], "enabled": stock["food"] >= 25},
					{"label": "Trust the riverbanks", "desc": "Do nothing and hope the vision is false.", "enabled": true},
				]}
		"overpop":
			return {"title": "Overpopulation Crisis",
				"text": "The tribe now numbers %d. Game is thinning around the bonfire and quarrels break out over the last berries." % living().size(),
				"options": [
					{"label": "Frontier Colonization", "desc": "Appoint an experienced leader via a Task Contract to found a sister settlement across the river.", "enabled": true},
					{"label": "Territorial Conquest", "desc": "Rally your 3 best warriors to raid a rival tribe for food and timber. Risky.", "enabled": living().size() >= 3},
				]}
		"chosen":
			return {"title": "Birth of the Chosen One",
				"text": "Under a sky split by lightning, a child is born bearing the mark of the totem. Which mythic bloodline awakens?",
				"options": [
					{"label": "Hou Yi the Archer", "desc": "A peerless hunter. Foraging 7, Combat 6.", "enabled": true},
					{"label": "Yu the Flood-Tamer", "desc": "A builder of levees and canals. Crafting 7, Lore 5.", "enabled": true},
					{"label": "Chiyou the Berserker", "desc": "A storm of bronze and fury. Combat 8, 90 HP.", "enabled": true},
				]}
	return {}

## Returns {"text": outcome, "open_contract": bool}
func resolve_event(id: String, idx: int) -> Dictionary:
	pending_event = ""
	var shaman := best_unit("lore", false)
	var out := {"text": "", "open_contract": false}
	match id:
		"flood":
			if idx == 0 and stock["wood"] >= 40:
				stock["wood"] -= 40
				out["text"] = "Rafts are lashed and shelters raised on the highland. When the waters come, the tribe watches from safety."
				for u in living(): remember(u, "built highland rafts on the Ark Plan before the Great Flood", 7)
			elif idx == 1 and stock["food"] >= 25:
				stock["food"] -= 25
				var chance := 0.35 + 0.1 * (shaman.lv("lore") if shaman else 0)
				if randf() < chance:
					out["text"] = "The river deity accepts the offering. The rains pass the tribe by."
					if shaman:
						gain_xp(shaman, "lore", 25)
						remember(shaman, "appeased the River Deity and turned aside the Great Flood", 9)
					devotion = minf(100, devotion + 20)
				else:
					out["text"] = "The deity is not appeased. The Great Flood strikes!"
					flood_strike()
			else:
				out["text"] = "The tribe ignores the vision. Nine nights later, the river rises."
				flood_strike()
		"overpop":
			if idx == 0:
				out["text"] = "Choose a leader for the frontier. Their Task Contract negotiation begins now."
				out["open_contract"] = true
			else:
				var raiders := living().filter(func(u): return u.role != "contract")
				raiders.sort_custom(func(a, b): return unit_atk(a) > unit_atk(b))
				raiders = raiders.slice(0, 3)
				var power := 0.0
				for u in raiders: power += unit_atk(u)
				var chance := clampf(power / 40.0, 0.2, 0.85)
				var names := ", ".join(raiders.map(func(u): return u.name))
				if randf() < chance:
					stock["food"] += 60
					stock["wood"] += 40
					out["text"] = "%s return victorious, hauling 60 food and 40 timber from the rival camp." % names
					for u in raiders:
						gain_xp(u, "combat", 30)
						remember(u, "raided a rival tribe and returned victorious on Day %d" % day(), 8)
				else:
					out["text"] = "The raid fails. %s limp home, bloodied and empty-handed." % names
					for u in raiders:
						hurt_unit(u, u.max_hp * 0.4, null)
						remember(u, "was beaten back in a failed raid on a rival tribe on Day %d" % day(), 8)
		"chosen":
			var heroes := [
				{"name": "Hou Yi", "epithet": "the Archer", "traits": ["belligerent"], "color": Color("#ffd36b"), "hp": 70, "atk": 9, "def": 4, "spd": 1.25, "skills": {"forage": 7, "craft": 1, "combat": 6, "lore": 1}},
				{"name": "Yu", "epithet": "the Flood-Tamer", "traits": ["cautious"], "color": Color("#6bd3ff"), "hp": 65, "atk": 6, "def": 5, "spd": 1.05, "skills": {"forage": 2, "craft": 7, "combat": 2, "lore": 5}},
				{"name": "Chiyou", "epithet": "the Berserker", "traits": ["belligerent"], "color": Color("#ff6b6b"), "hp": 90, "atk": 11, "def": 5, "spd": 1.1, "skills": {"forage": 1, "craft": 1, "combat": 8, "lore": 0}},
			]
			var def: Dictionary = heroes[clampi(idx, 0, 2)]
			def["hero"] = true
			var u := make_unit(def, D.VILLAGE + Vector2(0, 40))
			remember(u, "was born under a lightning sky, bearing a mythic bloodline", 10)
			units.append(u)
			out["text"] = "%s %s is born! The whole tribe feels the totem's favor." % [def["name"], def["epithet"]]
			popup(u.pos + Vector2(0, -30), "%s is born!" % def["name"], Color("#ffd36b"), true)
	add_log(out["text"], "story")
	return out


# ------------------------------------------------------------------ exploration / fog of war
func _fog_init() -> void:
	fog_w = ceili(D.W / D.FOG_CELL)
	fog_h = ceili(D.H / D.FOG_CELL)
	explored.resize(fog_w * fog_h)
	explored.fill(0)
	visible.resize(fog_w * fog_h)
	visible.fill(0)
	land_cells = 0
	for j in fog_h:
		for i in fog_w:
			if not D.is_water(_cell_center(i, j)): land_cells += 1
	explored_cells = 0

func _cell_center(i: int, j: int) -> Vector2:
	return Vector2((i + 0.5) * D.FOG_CELL, (j + 0.5) * D.FOG_CELL)

func _cell_idx(p: Vector2) -> int:
	var i := clampi(int(p.x / D.FOG_CELL), 0, fog_w - 1)
	var j := clampi(int(p.y / D.FOG_CELL), 0, fog_h - 1)
	return j * fog_w + i

func is_explored(p: Vector2) -> bool:
	return not fog_enabled or fog_w == 0 or explored[_cell_idx(p)] == 1

func is_visible(p: Vector2) -> bool:
	return not fog_enabled or fog_w == 0 or visible[_cell_idx(p)] == 1

func explored_pct() -> float:
	return 100.0 * explored_cells / maxf(1, land_cells)

func sight(u: E.Unit) -> float:
	return D.SIGHT_UNIT + 12.0 * u.lv("forage") + (D.SIGHT_SCOUT_BONUS if u.job.get("type", "") == "explore" else 0.0)

func reveal(p: Vector2, r: float) -> void:
	var i0 := clampi(int((p.x - r) / D.FOG_CELL), 0, fog_w - 1)
	var i1 := clampi(int((p.x + r) / D.FOG_CELL), 0, fog_w - 1)
	var j0 := clampi(int((p.y - r) / D.FOG_CELL), 0, fog_h - 1)
	var j1 := clampi(int((p.y + r) / D.FOG_CELL), 0, fog_h - 1)
	var r2 := r * r
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			if _cell_center(i, j).distance_squared_to(p) > r2: continue
			var k := j * fog_w + i
			visible[k] = 1
			if explored[k] == 0:
				explored[k] = 1
				if not D.is_water(_cell_center(i, j)): explored_cells += 1

func fog_update() -> void:
	if fog_w == 0: return
	visible.fill(0)
	for u in units:
		if not u.dead: reveal(u.pos, sight(u))
	for s in structures:
		if s.built: reveal(s.pos, D.SIGHT_BONFIRE if s.type == "bonfire" else D.SIGHT_STRUCT)
	if guardian and not guardian.dead: reveal(guardian.pos, 260)
	for lm in landmarks:
		if not lm["found"] and visible[_cell_idx(lm["pos"])] == 1: _discover(lm)

func _discover(lm: Dictionary) -> void:
	lm["found"] = true
	var finder: E.Unit = null
	for u in living():
		if finder == null or u.pos.distance_to(lm["pos"]) < finder.pos.distance_to(lm["pos"]): finder = u
	var rw: Dictionary = lm.get("reward", {})
	var parts: Array = []
	for k in rw:
		stock[k] += rw[k]
		parts.append("+%d %s" % [rw[k], k])
	if lm.has("devotion"):
		devotion = minf(100.0, devotion + lm["devotion"])
		parts.append("+%d devotion" % lm["devotion"])
	if lm.has("reveal"): reveal(lm["pos"], lm["reveal"])
	var who: String = finder.name if finder else "The tribe"
	add_log("Discovery! %s %s (%s)." % [who, lm["text"], ", ".join(parts)], "story" if lm["kind"] != "den" else "danger")
	popup(lm["pos"] + Vector2(0, -40), "Discovered: " + lm["name"], Color("#ffd36b"), true)
	if finder:
		remember(finder, "%s on Day %d" % [lm["text"], day()], 6)
		gain_xp(finder, "forage", 15)

## Nearest unexplored land cell, preferring the scout's own bank (crossing costs a detour)
## and steering clear of known saber-tooth dens.
func explore_target(u: E.Unit) -> Variant:
	var best: Variant = null
	var best_score := INF
	var my_bank := D.bank_of(u.pos)
	var dens: Array = landmarks.filter(func(l): return l["found"] and l["kind"] == "den").map(func(l): return l["pos"])
	for j in fog_h:
		for i in fog_w:
			if explored[j * fog_w + i] == 1: continue
			var c := _cell_center(i, j)
			if D.in_river(c): continue
			var score: float = c.distance_to(u.pos)
			if D.bank_of(c) != my_bank: score += 2.0 * absf(c.y - D.FORD_Y) + 300.0
			for dp in dens:
				if c.distance_to(dp) < 450: score += 2500.0
			if score < best_score:
				best_score = score
				best = c
	return best
