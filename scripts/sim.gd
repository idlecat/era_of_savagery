## Deterministic real-time simulation layer. No LLM calls, no rendering.
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")
const ContractSystem = preload("res://scripts/contract_system.gd")
const Evolution = preload("res://scripts/evolution.gd")
const Hazards = preload("res://scripts/hazards.gd")
const Rivals = preload("res://scripts/rivals.gd")
const Legacy = preload("res://scripts/legacy.gd")
const Nature = preload("res://scripts/nature.gd")
const Folk = preload("res://scripts/folk.gd")

signal contract_interrupted(contract)
signal event_fired(event_id)
signal contract_finished(contract)
signal log_added()
signal alert_raised(alert)
signal envoy_arrived(unit, clan_id)

var next_id := 1
var time := 0.0
var paused := false
var speed := 1.0
var stock := {"food": 45.0, "wood": 35.0, "lore": 0.0, "stone": 0.0, "herbs": 0.0, "copper": 0.0, "tin": 0.0, "goods": 0.0}
var known_finds := {} # find id -> day discovered
var mushroom_loads := 0 # the tribe learns which mushrooms are safe
var find_t := 0.0
var smelter_day := 0
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
var night_alarm := false # something stirs in the dark: the sleepers are up
var alarm_until := -1.0
var was_rest_time := false
var bury_t := 0.0
var resettle_t := 4.0
var rot_warn_day := 0
var oxen := 0 # the tribe's pack oxen, kept in Aurochs Pens
var ox_care := 100.0 # 0 = neglected: they won't carry, and wander off
var ox_hunger := 0.0 # seconds the herd has gone without food
var ox_neglect := 0.0 # seconds of neglect
var herd_t := 0.0
var last_herd_day := 0
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
const MEAL := 3.0 # food per meal
var evo: Evolution
var hz: Hazards
var nat: Nature
var folk: Folk
var cause_hint := "" # how the next death happened (lightning, fire...), set around hurt_unit
var rivals: Rivals
var legacy: Legacy
var alerts: Array = [] # {text, pos, level, t}
# ---- worn paths: foot traffic slowly wears trails into the grass ----
const WEAR_CELL := 30.0
var wear_w := 0
var wear_h := 0
var wear := PackedFloat32Array()
var wear_t := 0.0

func _init() -> void:
	contracts = ContractSystem.new(self)
	evo = Evolution.new(self)
	hz = Hazards.new(self)
	nat = Nature.new(self)
	folk = Folk.new(self)
	rivals = Rivals.new(self)
	legacy = Legacy.new(self)

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
		n.regrow = 0.1
	_wilds()
	_boulders()
	_place_finds()
	for def in D.RIVALS: # clear the rival villages' grounds
		nodes = nodes.filter(func(n): return n.pos.distance_to(def["pos"]) > 230)
	rivals.setup()
	wear_w = ceili(D.W / WEAR_CELL)
	wear_h = ceili(D.H / WEAR_CELL)
	wear.resize(wear_w * wear_h)
	wear.fill(0.0)
	for i in 36: spawn_deer("west", false)
	for i in 34: spawn_deer("east", false)

	var count: int = D.CHARACTERS.size()
	for i in count:
		var a := float(i) / count * TAU
		units.append(make_unit(D.CHARACTERS[i], D.VILLAGE + Vector2(cos(a) * 70, sin(a) * 55)))
	for nm in ["Ah-Lu", "Tala"]: # the tribe's youngest
		var kid: E.Unit = folk.make_child(nm, null)
		kid.born_t = -D.DAY_LEN * randf_range(0.5, 1.5)
		units.append(kid)
	assign_ritual(unit_by_name("Linghe"), D.VILLAGE + Vector2(30, -20))
	assign_gather(unit_by_name("Tuo"), "food")
	assign_gather(unit_by_name("Shan"), "food")
	assign_gather(unit_by_name("Bai"), "wood")
	add_log(tr("The tribe gathers around the bonfire. Saber-tooth tracks have been seen east of the ford."), "story")
	add_log(tr("Beyond the firelight the land is unknown. Send a scout (X) to explore it."), "story")
	_fog_init()
	fog_update()

## Outer wilderness of the big map: random forests and berry patches away from the home area,
## plus the landmarks (and the tiger dens) hidden in the fog.
func _wilds() -> void:
	var home := Rect2(D.VILLAGE - Vector2(700, 600), Vector2(1700, 1200))
	var placed := 0
	var tries := 0
	while placed < 80 and tries < 1200:
		tries += 1
		var c := Vector2(randf_range(120, D.W - 120), randf_range(120, D.H - 120))
		if home.has_point(c) or absf(c.x - D.river_x(c.y)) < 220: continue
		var near_lm := false
		for lm in D.LANDMARKS:
			if c.distance_to(lm["pos"]) < 230: near_lm = true
		if near_lm: continue
		_forest(c, randi_range(10, 24), randf_range(110, 200))
		placed += 1
	for i in 24:
		var c := Vector2(randf_range(150, D.W - 150), randf_range(150, D.H - 150))
		if home.has_point(c) or absf(c.x - D.river_x(c.y)) < 160: continue
		for k in 3:
			var n := _node("bush", "food", c + Vector2(randf_range(-50, 50), randf_range(-40, 40)), 30)
			n.regrow = 0.1
	for def in D.LANDMARKS:
		var lm: Dictionary = def.duplicate(true)
		lm["found"] = false
		landmarks.append(lm)
		if lm["id"] == "grove":
			for k in 6:
				var n := _node("bush", "food", lm["pos"] + Vector2.from_angle(k * TAU / 6) * 60, 40)
				n.regrow = 0.14
		for k in int(lm.get("den", 0)):
			var pr := spawn_predator(lm["pos"] + Vector2(randf_range(-60, 60), randf_range(-40, 40)))
			pr.den = lm["pos"]

## Stone outcrops: only quarryable once the tribe knows Polished Stone Tools.
func _boulders() -> void:
	var spots: Array = [D.VILLAGE + Vector2(-330, 260), D.VILLAGE + Vector2(260, -300)]
	for lm in D.LANDMARKS:
		if lm["id"] in ["flint", "peak", "stones"]: spots.append(lm["pos"] + Vector2(120, 90))
	for i in 40:
		spots.append(Vector2(randf_range(150, D.W - 150), randf_range(150, D.H - 150)))
	for c in spots:
		if absf(c.x - D.river_x(c.y)) < 150 or c.distance_to(D.VILLAGE) < 220: continue
		for k in 3:
			var p: Vector2 = c + Vector2(randf_range(-45, 45), randf_range(-35, 35))
			_node("boulder", "stone", p, 40)

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
## AoE-style alert: a banner the player can click to look at the danger.
func alert(text: String, pos: Vector2, level := "info", who: Array = []) -> void:
	var a := {"text": text, "pos": pos, "level": level, "t": time}
	alerts.append(a)
	if alerts.size() > 20: alerts.pop_front()
	add_log(text, {"danger": "danger", "warn": "story"}.get(level, "info"), who)
	alert_raised.emit(a)

## `who`: the people the line is about. The chronicle turns their names (as written now,
## in the current language) into links that select them.
func add_log(text: String, kind := "info", who: Array = []) -> void:
	var names: Array = []
	for u in who:
		if u != null: names.append({"id": u.id, "name": tr(u.name)})
	log_lines.push_front({"day": day(), "text": text, "kind": kind, "who": names})
	if log_lines.size() > 80: log_lines.pop_back()
	log_added.emit()

func popup(p: Vector2, text: String, color := Color("#ffe08a"), big := false) -> void:
	popups.append({"pos": p, "text": text, "color": color, "t": 0.0, "life": 2.6 if big else 1.6, "big": big})

func day() -> int: return int(time / D.DAY_LEN) + 1
func day_frac() -> float: return fmod(time, D.DAY_LEN) / D.DAY_LEN
func has_tech(t: String) -> bool: return techs.has(t)
## Bronze arms the tribe only while a smelter stands and has copper and tin to work.
func has_bronze() -> bool: return has_tech("bronze") and _struct_exists("smelter") and stock["copper"] >= 1 and stock["tin"] >= 1
func knows_find(id: String) -> bool: return known_finds.has(id)
func _struct_exists(type: String) -> bool:
	for s in structures:
		if s.built and ours(s) and s.type == type: return true
	return false
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

## False for buildings of the rival clans' villages.
func ours(s: E.Structure) -> bool: return not s.owner.begins_with("rival:")

func pop_cap() -> int:
	var c := 0
	for s in structures:
		if s.built and ours(s): c += int(D.STRUCTURES[s.type].get("cap", 0))
	return c

func _nearest_fire(p: Vector2) -> E.Structure:
	var best: E.Structure = null
	for s in structures:
		if s.built and ours(s) and s.type == "bonfire" and (best == null or s.pos.distance_to(p) < best.pos.distance_to(p)): best = s
	return best

func near_warmth(u: E.Unit) -> bool:
	if in_hut(u): return true
	var r := 110.0 * (2.0 if has_tech("fire") else 1.0)
	for s in structures:
		if s.built and ours(s) and s.type == "bonfire" and s.pos.distance_to(u.pos) < r: return true
	return false

func _struct_near(type: String, p: Vector2, r: float) -> bool:
	for s in structures:
		if s.built and ours(s) and s.type == type and s.pos.distance_to(p) < r: return true
	return false

# ------------------------------------------------------------------ stats
func unit_atk(u: E.Unit) -> float:
	var a := u.atk * (1.0 + 0.15 * u.lv("combat"))
	if has_tech("tools"): a += 2
	if evo.has_trad("warrior_initiation"): a += 2
	if has_bronze(): a *= 1.6
	elif knows_find("obsidian"): a *= 1.15 # black-glass blades
	if _struct_near("weapon_rack", u.pos, 160): a *= 1.2
	if u.role == "contract":
		var c = contracts.by_id(u.contract_id)
		if c and c.flags.get("blessed", false): a *= 1.15 # the war dance
	return a

func unit_def(u: E.Unit) -> float:
	var d := u.def * (1.0 + 0.15 * u.lv("combat"))
	if has_tech("hide"): d += 2
	if has_bronze(): d += 3
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
	if evo.has_trad("wayfinders"): s *= 1.1
	s *= hz.speed_mult()
	if u.carry_amt > 0: s *= 0.95 if u.ox else 0.85 # loads slow the walk home
	return s

func work_mul(u: E.Unit) -> float: return (0.9 if u.has_trait("lazy") else 1.0) * (0.6 if u.sick > 0 else 1.0) * hz.work_mult() * folk.work_mult()
func carry_cap(u: E.Unit) -> int: return 15 if u.ox else 10
## Food storage: the village keeps FOOD_STORE_BASE, each Granary FOOD_STORE_GRANARY more;
## anything over that rots at FOOD_ROT per second.
const FOOD_STORE_BASE := 80
const FOOD_STORE_GRANARY := 100
const FOOD_ROT := 0.03
func food_cap() -> int:
	var c := FOOD_STORE_BASE
	for s in structures:
		if s.built and ours(s) and s.type == "granary": c += FOOD_STORE_GRANARY
	return c
## Hunger per unit of distance walked: a villager walking all day gets ~70% hungrier.
const WALK_HUNGER := 0.004

# ------------------------------------------------------------------ XP & memory
func xp_need(lv: int) -> float: return 25.0 + lv * 20.0

func gain_xp(u: E.Unit, skill: String, amt: float) -> void:
	var s: Dictionary = u.skills[skill]
	if s["lv"] >= 10 or u.dead: return
	if skill == "combat" and evo.has_trad("warrior_initiation"): amt *= 1.25
	s["xp"] += amt
	u.xp_acc += amt
	while s["lv"] < 10 and s["xp"] >= xp_need(s["lv"]):
		s["xp"] -= xp_need(s["lv"])
		s["lv"] += 1
		popup(u.pos + Vector2(0, -34), tr("LEVEL UP! %s Lv.%d") % [tr(D.SKILL_NAMES[skill]).split(" ")[0], s["lv"]], Color("#7ff0ff"), true)
		add_log(tr("%s reached %s Lv.%d.") % [tr(u.name), tr(D.SKILL_NAMES[skill]), s["lv"]], "xp", [u])
		if s["lv"] == 5 and not u.unlocked.has(skill):
			u.unlocked[skill] = true
			remember(u, tr("mastered %s and unlocked [%s]") % [tr(D.SKILL_NAMES[skill]).to_lower(), tr(D.SKILL_UNLOCKS[skill])], 7)
			add_log(tr("%s unlocked [%s]!") % [tr(u.name), tr(D.SKILL_UNLOCKS[skill])], "story", [u])

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
		if e is E.Unit: e.walked += d * (1.5 if e.carry_amt > 0 else 1.0)
		e.pos = wp
		e.path.pop_front()
		return e.path.is_empty()
	var np: Vector2 = e.pos + (wp - e.pos) / d * step
	if D.is_water(np) and not D.is_water(e.pos): # slide along the bank
		var rx := D.river_x(np.y)
		np.x = rx - D.RIVER_HALF - 1 if D.bank_of(e.pos) == "west" else rx + D.RIVER_HALF + 1
	if e is E.Unit: e.walked += step * (1.5 if e.carry_amt > 0 else 1.0) # a load is heavier going
	e.pos = np
	if e is E.Unit and wear_w > 0:
		var wi := clampi(int(np.x / WEAR_CELL), 0, wear_w - 1) + clampi(int(np.y / WEAR_CELL), 0, wear_h - 1) * wear_w
		wear[wi] = minf(1.0, wear[wi] + dt * 0.18)
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
	u.job_t = time
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
func assign_experiment(u: E.Unit, p: Vector2, label: String, key := "") -> void: set_job(u, {"type": "experiment", "at": p, "label": label}, key)
## AoE2-DE-style auto-scout: keep walking to the nearest unexplored land.
func assign_explore(u: E.Unit) -> void: set_job(u, {"type": "explore", "to": null})

func find_node(res: String, from: Vector2, bank: String, max_dist: float) -> E.ResNode:
	var best: E.ResNode = null
	var best_score := INF
	for n in nodes:
		if n.res != res or n.amount < 1: continue
		if n.kind == "boulder" and not has_tech("tools"): continue
		if D.FINDS.has(n.kind) and not _can_gather_find(n): continue
		if bank != "" and D.bank_of(n.pos) != bank: continue
		var d: float = n.pos.distance_to(from)
		if d > max_dist: continue
		var claims := 0
		for u in units:
			if not u.dead and u.job.get("node_id", -2) == n.id: claims += 1
		var score := d * 1.4 + claims * 70.0 + (60.0 if n.kind == "deer" else 0.0) + (0.0 if is_explored(n.pos) else 900.0)
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
		popup(u.pos + Vector2(0, -22), tr("+%d EXP") % roundi(u.xp_acc))
		u.xp_acc = 0
		u.xp_flush_t = 1.6

	# Freezing people stop what they are doing and go to the nearest fire.
	if hz.cold_can_kill() and u.hp < u.max_hp * 0.55 and not near_warmth(u) and not u.job.get("warm", false):
		var fire := _nearest_fire(u.pos)
		if fire != null:
			if u.resume_job.is_empty() and not u.job.is_empty() and u.job.get("type", "") != "explore":
				u.resume_job = u.job
				u.resume_key = u.job_key
				u.resume_t = u.job_t
			set_job(u, {"type": "move", "to": fire.pos + Vector2(randf_range(-30, 30), randf_range(10, 40)), "flee": true, "warm": true}, u.job_key)
			popup(u.pos + Vector2(0, -30), tr("Seeking warmth"), Color("#a8d8ff"))
	if u.role == "envoy" and u.job.get("type", "") != "envoy" and u.resume_job.get("type", "") != "envoy":
		u.role = "" # recalled: the mission is off
		# Self-defense or flight when attacked
	if time - u.last_hit_t < 2 and u.attacker_id >= 0:
		var p := pred_by_id(u.attacker_id)
		if p and not p.dead and not p.fleeing:
			var low := u.hp < u.max_hp * 0.22
			var jt: String = u.job.get("type", "")
			if u.role == "child":
				if not u.job.get("flee", false): assign_flee(u)
			elif jt == "explore":
				assign_flee(u)
				popup(u.pos + Vector2(0, -26), tr("Scout retreats!"), Color("#ff9b7a"))
			elif low and not u.has_trait("belligerent") and not u.job.get("flee", false):
				assign_flee(u)
				popup(u.pos + Vector2(0, -26), tr("Flees!"), Color("#ff9b7a"))
			elif not low and jt != "attack" and jt != "move":
				if u.resume_job.is_empty() and not u.job.is_empty():
					u.resume_job = u.job
					u.resume_key = u.job_key
					u.resume_t = u.job_t
				assign_attack(u, p, u.job_key)

	if _night_rest(u, dt): return
	var jt0: String = u.job.get("type", "")
	if folk.festival_on() and u.role in ["", "child"] and u.home.distance_to(D.VILLAGE) < 60 and jt0 != "attack" and not u.job.get("flee", false) and jt0 != "bury":
		folk.dance(u, dt)
		return
	if u.role == "child" and u.job.is_empty():
		folk.play(u, dt)
		return
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
					u.job_t = u.resume_t
				elif j.get("warm", false) and not u.resume_job.is_empty():
					if u.hp < u.max_hp * 0.8:
						u.act = "Warming by the fire"
						return # stay by the fire until warm again
					var rj := u.resume_job
					u.resume_job = {}
					set_job(u, rj, u.resume_key)
					u.job_t = u.resume_t # back to the old job: not a new (night) order
				else:
					set_job(u, {})
		"gather":
			_do_gather(u, j, dt)
		"bury":
			_do_bury(u, j, dt)
		"tend":
			_do_tend(u, j, dt)
		"art":
			folk.do_art(u, j, dt)
		"trade_trip":
			folk.do_trade(u, j, dt)
		"build":
			var s := struct_by_id(j["struct_id"])
			if s == null or (s.built and not s.reno):
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
				var speed := dt * (1.0 + 0.12 * u.lv("craft")) * work_mul(u) * (1.2 if evo.has_trad("makers_pride") else 1.0)
				gain_xp(u, "craft", dt * 0.9)
				evo.practice(u, "build", dt)
				evo.drift("spiritual", -0.005 * dt)
				if s.reno:
					u.act = "Renovating " + sd["name"]
					s.reno_progress += speed
					if s.reno_progress >= s.work * 0.6: _finish_reno(s, u)
				else:
					u.act = "Building " + sd["name"]
					s.progress += speed
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
					u.job_t = u.resume_t # back to the old job: not a new (night) order
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
		"envoy":
			if j.get("parley", false):
				u.act = "Parleying"
				return
			if approach(u, rivals.parley_spot(j["clan"]), 10, dt):
				j["parley"] = true
				u.act = "Parleying"
				rivals.envoy_arrived(u, j["clan"])
			else:
				u.act = "Travelling as envoy"
		"experiment":
			if approach(u, j["at"], 8, dt):
				u.act = "Experimenting: " + j["label"]
				gain_xp(u, "lore", dt * 0.3)
				gain_xp(u, "craft", dt * 0.2)
			else:
				u.act = "Walking to the workshop"
		"explore":
			u.act = "Scouting"
			var threat := active_predators_near(u.pos, 240)
			if not threat.is_empty(): # scouts keep their distance from beasts they can see
				var away: Vector2 = (u.pos - threat[0].pos).normalized()
				j["to"] = null
				set_job(u, {"type": "move", "to": u.pos + away * 260, "flee": true})
				u.resume_job = {"type": "explore", "to": null}
				u.resume_t = u.job_t
				popup(u.pos + Vector2(0, -30), tr("Beast! Scout backs off"), Color("#ff9b7a"))
				return
			var tgt: Variant = j.get("to")
			if tgt == null or is_explored(tgt):
				tgt = explore_target(u)
				if tgt == null:
					set_job(u, {})
					popup(u.pos + Vector2(0, -30), tr("Nothing left to explore"), Color("#9fd0ff"))
					return
				j["to"] = tgt
			if approach(u, tgt, 12, dt): j["to"] = null
			gain_xp(u, "forage", dt * 0.12)
			evo.practice(u, "explore", dt)
			evo.drift("settled", -0.01 * dt)
		"ritual":
			if approach(u, j["at"], 6, dt):
				u.act = "Performing ritual"
				var boost := 1.5 if (_struct_near("totem_shrine", u.pos, 140) or _struct_near("grand_altar", u.pos, 140)) else 1.0
				if evo.has_trad("ancestor_rites"): boost *= 1.3
				stock["lore"] += dt * 0.22 * (1.0 + 0.2 * u.lv("lore")) * boost
				devotion = minf(100.0, devotion + dt * 0.07 * (1.0 + 0.1 * u.lv("lore")) * (1.3 if evo.has_trad("ancestor_rites") else 1.0))
				evo.practice(u, "ritual", dt)
				evo.drift("spiritual", 0.01 * dt)
				gain_xp(u, "lore", dt * 0.6)
				j["elapsed"] = j.get("elapsed", 0.0) + dt
			else:
				u.act = "Walking to ritual ground"

func _dropoff_point(j: Dictionary, u: E.Unit) -> Vector2:
	if j["dropoff"] >= 0:
		var c = contracts.by_id(j["dropoff"])
		if c: return c.site
	var best: Vector2 = D.VILLAGE # the nearest of our settlements takes the load (food: a Granary too)
	for p in settlements():
		if p.distance_to(u.pos) < best.distance_to(u.pos): best = p
	if j["res"] == "food":
		for s in structures:
			if s.built and ours(s) and s.type == "granary" and s.pos.distance_to(u.pos) < best.distance_to(u.pos): best = s.pos
	return best

func _do_gather(u: E.Unit, j: Dictionary, dt: float) -> void:
	var cap := carry_cap(u)
	if j["phase"] == "deliver" or u.carry_amt >= cap:
		j["phase"] = "deliver"
		var dp := _dropoff_point(j, u) + Vector2((u.id * 13) % 30 - 15, (u.id * 7) % 30 - 15)
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
	if n.kind == "boulder" and not has_tech("tools"):
		set_job(u, {})
		popup(u.pos + Vector2(0, -30), tr("Needs Polished Stone Tools"), Color("#ff9b7a"))
		return
	var fd: Dictionary = D.FINDS.get(n.kind, {})
	if not fd.is_empty() and not _can_gather_find(n):
		if u.pos.distance_to(n.pos) < 90 and not knows_find(n.kind) and not can_recognise(u, n.kind):
			set_job(u, {})
			popup(u.pos + Vector2(0, -30), tr("%s doesn't know what to make of it") % tr(u.name), Color("#ff9b7a"))
			return
		if knows_find(n.kind): # known but not workable now (tools, frozen river)
			set_job(u, {})
			popup(u.pos + Vector2(0, -30), tr("Needs Polished Stone Tools") if fd.get("needs", "") == "tools" else tr("The river is frozen"), Color("#ff9b7a"))
			return
	if approach(u, n.pos, {"tree": 16.0, "boulder": 16.0, "fish": 34.0}.get(n.kind, 14.0), dt): # (fish: from the bank)
		if n.kind == "deer": # the hunt
			evo.practice(u, "hunt", 3.0)
			n.kind = "carcass"
			n.from_deer = true
			n.vel = Vector2.ZERO
			gain_xp(u, "forage", 3)
			gain_xp(u, "combat", 1)
			if randf() < 0.05 * u.lv("forage"):
				popup(u.pos + Vector2(0, -30), tr("Lethal strike!"), Color("#ffb36b"))
				n.amount += 5
		u.act = fd["act"] if not fd.is_empty() else {"tree": "Chopping wood", "carcass": "Butchering game", "boulder": "Quarrying stone"}.get(n.kind, "Picking berries")
		var base: float = fd["rate"] if not fd.is_empty() else {"tree": 1.2, "carcass": 1.4, "boulder": 0.6}.get(n.kind, 1.0)
		var rate := base * (1.0 + 0.1 * u.lv("forage")) * (1.3 if has_tech("tools") and n.kind != "bush" else 1.0) * work_mul(u)
		if evo.has_trad("peaceful_ways"): rate *= 1.2
		var activity: String = fd["practice"] if not fd.is_empty() else {"tree": "chop", "carcass": "hunt", "boulder": "quarry"}.get(n.kind, "berry")
		evo.practice(u, activity, dt * fd.get("practice_x", 1.0))
		match activity:
			"hunt", "berry": evo.drift("settled", -0.006 * dt)
			_: evo.drift("spiritual", -0.004 * dt)
		u.gather_t += dt * rate
		while u.gather_t >= 1 and n.amount >= 1:
			u.gather_t -= 1
			n.amount -= 1
			u.carry_type = j["res"]
			u.carry_kind = n.kind
			u.carry_amt += 1
			if n.kind == "honey" and not has_tech("fire") and randf() < 0.06: # no smoke: the bees fight back
				hurt_unit(u, 2.0, null)
				popup(u.pos + Vector2(0, -30), tr("Stung!"), Color("#ffd36b"))
			if u.carry_amt >= cap:
				j["phase"] = "deliver"
				break
		if n.amount < 1: _deplete(n)
	elif n.kind == "boulder":
		u.act = "Walking to the rocks"
	else:
		u.act = "Walking to forest" if n.kind == "tree" else "Walking to food"

func _deplete(n: E.ResNode) -> void:
	if n.kind == "tree":
		n.kind = "stump"
		n.regrow_t = 140
	elif n.kind == "carcass" or n.kind == "boulder" or (D.FINDS.has(n.kind) and D.FINDS[n.kind]["regrow"] <= 0.0):
		nodes.erase(n) # (a worked-out seam is gone; plants grow back)
		if n.from_deer and not hz.winter(): spawn_deer(n.bank, true) # no new herds arrive in winter

func deposit(u: E.Unit, j: Dictionary, amt: int) -> void:
	gain_xp(u, "forage", amt * 0.45)
	_find_effects(u, amt)
	if j["dropoff"] >= 0:
		var c = contracts.by_id(j["dropoff"])
		if c:
			contracts.deposit(c, j["res"], amt, u)
			return
	stock[j["res"]] += amt
	popup(u.pos + Vector2(0, -12), tr("+%d %s") % [amt, tr(j["res"])], {"wood": Color("#d8b483"), "stone": Color("#c8c8d0")}.get(j["res"], Color("#f0a07a")))

func complete_structure(s: E.Structure, u: E.Unit) -> void:
	s.built = true
	s.progress = s.work
	s.style = evo.era
	if s.type in ["farm_plot", "granary", "aurochs_pen", "fishing_dock"]: evo.drift("settled", 5.0)
	if s.type == "aurochs_pen" and ours(s):
		oxen += 1
		ox_care = maxf(ox_care, 80.0)
		last_herd_day = day() # the next calf comes at a later dawn
		add_log(tr("An aurochs calf is tamed and led into the new pen. Feed it and tend it, and it will carry our loads."), "build")
	if s.type in ["totem_shrine", "grand_altar"]: evo.drift("spiritual", 4.0)
	if s.type in ["weapon_rack", "palisade"]: evo.drift("martial", 2.0)
	if s.type == "council_ring": evo.drift("ranked", 6.0)
	var name: String = tr(D.STRUCTURES[s.type]["name"])
	popup(s.pos + Vector2(0, -30), tr("%s complete!") % name, Color("#b6f28a"), true)
	add_log(tr("%s completed%s.") % [name, (tr(" by %s's crew") % tr(u.name)) if u else ""], "build", [u] if u else [])
	if s.type == "grand_altar": summon_guardian(s)

# ------------------------------------------------------------------ natural finds
## Scatter clusters of each find over the map (see D.FINDS "where").
func _place_finds() -> void:
	var trees: Array = nodes.filter(func(n): return n.kind == "tree")
	for id in D.FINDS:
		var fd: Dictionary = D.FINDS[id]
		var made := 0
		var tries := 0
		while made < fd["count"] * 2 and tries < 600: # twice the clusters on the big map
			tries += 1
			var c = _find_spot(fd["where"], trees, made == 0 and fd["group"] != "ore")
			if c == null: continue
			var k_max: int = fd.get("cluster", 2 if fd["group"] == "ore" else 3)
			for k in k_max:
				var p: Vector2 = c + Vector2(randf_range(-30, 30), randf_range(-22, 22)) if k > 0 else c
				if fd["where"] != "river" and absf(p.x - D.river_x(p.y)) < D.RIVER_HALF + 12: continue
				if fd["where"] == "river": p = Vector2(c.x, c.y + randf_range(-40, 40) * k) # a shoal strings along the shallows
				if fd["where"] == "river": p.x = D.river_x(p.y) + signf(c.x - D.river_x(c.y)) * (D.RIVER_HALF - 26.0)
				p = Vector2(clampf(p.x, 30, D.W - 30), clampf(p.y, 30, D.H - 30))
				var n := _node(id, fd["res"], p, fd["amount"])
				n.regrow = fd["regrow"]
				n.bank = D.bank_of(p)
			made += 1

## A spot for a cluster, or null. near_home: the first cluster of a food or medicine stays
## within reach of the village, so the early game has something to find.
func _find_spot(where: String, trees: Array, near_home: bool) -> Variant:
	var lim := 950.0 if near_home else INF
	var p := Vector2.ZERO
	match where:
		"forest", "forest_edge":
			if trees.is_empty(): return null
			var tr_n = trees.pick_random()
			p = tr_n.pos + (Vector2.from_angle(randf() * TAU) * (randf_range(15, 40) if where == "forest" else randf_range(70, 110)))
		"river", "riverbank":
			var y := randf_range(120, D.H - 120)
			if D.is_ford(y) or absf(y - D.FORD_Y0) < 180 or absf(y - D.FORD_Y1) < 180: return null
			var side := -1.0 if randf() < 0.5 else 1.0
			p = Vector2(D.river_x(y) + side * ((D.RIVER_HALF - 26.0) if where == "river" else D.RIVER_HALF + randf_range(45, 95)), y)
		"meadow":
			p = Vector2(randf_range(120, D.W - 120), randf_range(120, D.H - 120))
			if trees.any(func(t): return t.pos.distance_to(p) < 80): return null
		"hills_west":
			p = Vector2(randf_range(120, D.RIVER_BASE_X - 500), randf_range(120, D.H - 120))
			if p.distance_to(D.VILLAGE) < 650: return null
		"hills_east":
			p = Vector2(randf_range(D.RIVER_BASE_X + 450, D.W - 120), randf_range(120, D.H - 120))
	if p.distance_to(D.VILLAGE) < 260 or p.distance_to(D.VILLAGE) > lim: return null
	if where != "river" and absf(p.x - D.river_x(p.y)) < D.RIVER_HALF + 30: return null
	if where == "river" and p.distance_to(D.VILLAGE) < 260: return null
	for def in D.RIVALS:
		if p.distance_to(def["pos"]) < 260: return null
	for lm in D.LANDMARKS:
		if p.distance_to(lm["pos"]) < 100: return null
	return p

## Who can tell what a find is: healing plants need someone with lore; ores, someone who
## knows stone-working (Polished Stone Tools) or has a crafter's eye.
func can_recognise(u: E.Unit, id: String) -> bool:
	match D.FINDS[id].get("needs", ""):
		"lore": return u.lv("lore") >= 1
		"tools": return has_tech("tools") or u.lv("craft") >= 1
	return true

func _can_gather_find(n: E.ResNode) -> bool:
	if not knows_find(n.kind): return false
	if D.FINDS[n.kind].get("needs", "") == "tools" and not has_tech("tools"): return false
	if n.kind == "fish" and hz.winter(): return false # iced over
	return true

## Twice a second: anyone near an unknown find who can recognise it discovers it. Once a day:
## the smelter eats copper and tin.
func _finds_tick(dt: float) -> void:
	find_t -= dt
	if find_t > 0: return
	find_t = 0.5
	for n in nodes:
		if not D.FINDS.has(n.kind) or knows_find(n.kind) or not is_explored(n.pos): continue
		for u in units:
			if u.dead or u.sleeping or u.pos.distance_to(n.pos) > 80 or not can_recognise(u, n.kind): continue
			discover_find(n.kind, u, n.pos)
			break
	if has_tech("bronze") and _struct_exists("smelter") and day() != smelter_day and not rest_time():
		smelter_day = day()
		if stock["copper"] >= 1 and stock["tin"] >= 1:
			stock["copper"] -= 1
			stock["tin"] -= 1
		else:
			alert(tr("The smelter is cold: it needs copper and tin. Without them, no bronze arms the tribe."), D.VILLAGE, "warn")

func discover_find(id: String, u: E.Unit, at: Vector2) -> void:
	if knows_find(id): return
	known_finds[id] = day()
	var fd: Dictionary = D.FINDS[id]
	add_log(tr("Discovery! %s found %s: %s") % [tr(u.name), tr(fd["name"]), tr(fd["desc"])], "story", [u])
	popup(at + Vector2(0, -40), tr("Discovered: %s") % tr(fd["name"]), Color("#ffd36b"), true)
	remember(u, tr("found %s on Day %d") % [tr(fd["name"]), day()], 6)
	gain_xp(u, "lore" if fd["group"] == "medicine" else "forage", 5)
	match id:
		"flint": evo.seed("tools", 0.45, u)
		"grain": evo.seed("farming", 0.25, u)
		"copper", "tin": evo.seed("bronze", 0.12, u)
		"ochre": evo.drift("spiritual", 3.0)
		"willow", "yarrow": stock["lore"] += 5

## What a load does when it reaches the stores, beyond the food or lore it is.
func _find_effects(u: E.Unit, amt: int) -> void:
	var kind := u.carry_kind
	u.carry_kind = ""
	match kind:
		"mushroom":
			mushroom_loads += 1
			if mushroom_loads <= 8 and u.lv("lore") < 2 and randf() < 0.3:
				hurt_unit(u, 10.0, null)
				popup(u.pos + Vector2(0, -30), tr("A bad mushroom!"), Color("#c8a8ff"))
				remember(u, tr("was poisoned by a bad mushroom on Day %d") % day(), 4)
			elif mushroom_loads == 9:
				add_log(tr("The tribe has learned which mushrooms are safe to eat."), "story")
		"honey":
			devotion = minf(100.0, devotion + amt * 0.12)
			popup(u.pos + Vector2(0, -40), tr("Sweet honey!"), Color("#ffd36b"))
		"ochre":
			evo.drift("spiritual", 0.6)

# ------------------------------------------------------------------ settlements
## Where our people live: the home village, plus every outpost a settle contract founded.
func settlements() -> Array:
	var out: Array = [D.VILLAGE]
	for c in contracts.list:
		if c.kind == "settle" and c.status == "done": out.append(c.site)
	return out

func beds_at(p: Vector2) -> int:
	var n := 0
	for s in structures:
		if s.built and ours(s) and s.type in SHELTERS and s.pos.distance_to(p) < 450: n += int(D.STRUCTURES[s.type]["cap"])
	return n

func residents_of(p: Vector2) -> Array:
	return units.filter(func(u): return not u.dead and u.home.distance_to(p) < 60)

func settlement_name(p: Vector2) -> String:
	for c in contracts.list:
		if c.kind == "settle" and c.site == p: return c.plan["plan_id"]
	return tr("the village")

## A crowded village sends someone to a settlement with empty beds (one at a time, by day).
func _resettle(dt: float) -> void:
	resettle_t -= dt
	if resettle_t > 0: return
	resettle_t = 8.0
	if rest_time(): return
	var homes := settlements()
	if homes.size() < 2: return
	var crowded: Array = homes.filter(func(p): return residents_of(p).size() > beds_at(p))
	if crowded.is_empty(): return
	for p in homes:
		if p in crowded or residents_of(p).size() >= beds_at(p): continue
		for from in crowded:
			var movers: Array = residents_of(from).filter(func(u): return u.role == "" and u.title == "" and not u.sleeping and u.job.get("type", "") in ["", "gather"])
			if movers.is_empty(): continue
			movers.sort_custom(func(a, b): return a.job.is_empty() and not b.job.is_empty())
			var u: E.Unit = movers[0]
			u.home = p
			set_job(u, {"type": "move", "to": p + Vector2(randf_range(-40, 40), randf_range(-30, 30))})
			add_log(tr("%s moves to '%s', where there are empty beds.") % [tr(u.name), settlement_name(p)], "story", [u])
			remember(u, tr("moved to '%s' on Day %d") % [settlement_name(p), day()], 6)
			return

# ------------------------------------------------------------------ the herd
const OX_PER_PEN := 2
const OX_EAT := 0.03 # food per second per ox (half again in winter: no grazing)
const OX_MILK := 0.025 # food per second per cared-for ox (milk, less in winter)
const CARE_DECAY := 100.0 / (D.DAY_LEN * 1.5) # untended, care runs out in a day and a half
const TEND_TIME := 6.0

func pens() -> Array:
	return structures.filter(func(s): return s.built and ours(s) and s.type == "aurochs_pen")

func ox_cap() -> int: return pens().size() * OX_PER_PEN
func oxen_working() -> bool: return oxen > 0 and ox_care > 0.0

## Oxen eat, give milk, need tending, and are lent to the gatherers working furthest out.
func _herd(dt: float) -> void:
	var cap := ox_cap()
	if oxen > cap: oxen = cap # a pen was lost
	if oxen > 0:
		var need: float = OX_EAT * oxen * (1.5 if hz.winter() else 1.0) * dt
		if stock["food"] >= need:
			stock["food"] -= need
			ox_hunger = 0.0
		else:
			stock["food"] = 0.0
			ox_hunger += dt
			if ox_hunger > D.DAY_LEN: # a day without fodder: one goes to the pot
				ox_hunger = 0.0
				oxen -= 1
				stock["food"] += 20
				alert(tr("With nothing left to feed them, the tribe slaughters an ox (+20 food)."), D.VILLAGE, "warn")
		if ox_care > 0: stock["food"] += OX_MILK * oxen * hz.food_mult("aurochs_pen") * dt
		ox_care = maxf(0.0, ox_care - CARE_DECAY * dt)
		if ox_care <= 0:
			ox_neglect += dt
			if ox_neglect > D.DAY_LEN:
				ox_neglect = 0.0
				oxen -= 1
				alert(tr("Untended, an ox breaks out of the pen and is gone."), pens()[0].pos if cap > 0 else D.VILLAGE, "warn")
		else:
			ox_neglect = 0.0
	# a new calf at dawn, if there is room, food and care
	if day() != last_herd_day and not rest_time() and day_frac() < 0.2:
		last_herd_day = day()
		if cap > oxen and oxen > 0 and ox_care >= 50 and stock["food"] >= 30:
			oxen += 1
			add_log(tr("A calf is tamed in the Aurochs Pen. The herd is now %d.") % oxen, "build")
	herd_t -= dt
	if herd_t > 0: return
	herd_t = 2.0
	_lend_oxen()
	if oxen > 0 and ox_care < 50 and not rest_time() and not units.any(func(u): return not u.dead and u.job.get("type", "") == "tend"):
		_send_herder()

func _lend_oxen() -> void:
	var gatherers: Array = units.filter(func(u): return not u.dead and not u.sleeping and u.job.get("type", "") == "gather" and D.bank_of(u.pos) == D.bank_of(D.VILLAGE))
	gatherers.sort_custom(func(a, b): return a.pos.distance_to(D.VILLAGE) > b.pos.distance_to(D.VILLAGE))
	var n: int = oxen if oxen_working() else 0
	for u in units: u.ox = false
	for u in gatherers.slice(0, n): u.ox = true

func _send_herder() -> void:
	var ps := pens()
	if ps.is_empty(): return
	var best: E.Unit = null
	for u in units:
		if u.dead or u.role != "" or u.sleeping or u.title == "War Chief": continue
		var jt: String = u.job.get("type", "")
		if jt != "" and jt != "gather": continue
		if best == null or (jt == "" and best.job.get("type", "") != "") or \
			((jt == "") == (best.job.get("type", "") == "") and u.pos.distance_to(ps[0].pos) < best.pos.distance_to(ps[0].pos)): best = u
	if best == null: return
	if not best.job.is_empty():
		best.resume_job = best.job
		best.resume_key = best.job_key
		best.resume_t = best.job_t
	set_job(best, {"type": "tend", "pen_id": ps[0].id, "t": 0.0})

func _do_tend(u: E.Unit, j: Dictionary, dt: float) -> void:
	var pen := struct_by_id(j["pen_id"])
	if pen == null or not pen.built or oxen <= 0:
		_end_errand(u)
		return
	if not approach(u, pen.pos + Vector2(cos(u.id) * 34, sin(u.id) * 20), 8, dt):
		u.act = "Walking to the oxen"
		return
	u.act = "Tending the oxen"
	j["t"] += dt
	if j["t"] >= TEND_TIME:
		ox_care = 100.0
		gain_xp(u, "forage", 2.0)
		evo.practice(u, "hunt", 1.0)
		_end_errand(u) # back to what they were doing

# ------------------------------------------------------------------ burials
const BURY_RANGE := 1500.0 # bodies further out than this are lost to the wild after a day
const GRAVE_DIG := 5.0

func burial_ground() -> E.Structure:
	for s in structures:
		if s.built and ours(s) and s.type == "burial_ground": return s
	return null

## A quiet spot at the edge of the village, clear of everything else.
func _found_burial_ground() -> E.Structure:
	var spot: Vector2 = D.VILLAGE + Vector2(-300, 220)
	var found := false
	for r in [300.0, 380.0, 460.0]:
		for k in 16:
			var p: Vector2 = D.VILLAGE + Vector2.from_angle(2.4 + k * TAU / 16) * r
			if D.in_river(p) or D.bank_of(p) != D.bank_of(D.VILLAGE) or p.x < 80 or p.y < 80 or p.y > D.H - 80: continue
			if structures.any(func(s): return s.pos.distance_to(p) < (D.STRUCTURES[s.type]["r"] + 60 if not D.STRUCTURES[s.type].get("ring", false) else 0.0)): continue
			if nodes.any(func(n): return n.kind in ["tree", "boulder", "bush"] and n.pos.distance_to(p) < 85): continue
			spot = p
			found = true
			break
		if found: break
	var s := add_structure("burial_ground", spot, true)
	add_log(tr("The tribe lays out a burial ground at the edge of the village."), "story")
	return s

func grave_slot(bg: E.Structure, i: int) -> Vector2:
	var col: int = [2, 1, 3, 0, 4][i % 5] # fill each row from the middle out
	var row := i / 5
	# rows run along the screen's horizontal (world (1,-1)), new rows step towards the viewer
	return bg.pos + Vector2(1, -1) * ((col - 2) * 14.0 + (row % 2) * 5.0) + Vector2(1, 1) * (row * 13.0 - 2.0)

## Every second: see that each body is fetched, carried home and buried.
func _burials(dt: float) -> void:
	bury_t -= dt
	if bury_t > 0: return
	bury_t = 1.0
	for b in units:
		if not b.dead or b.buried: continue
		var bg := burial_ground()
		if bg == null: bg = _found_burial_ground()
		if b.carrier_id >= 0:
			var c := unit_by_id(b.carrier_id)
			if c == null or c.dead or c.job.get("type", "") != "bury" or c.job.get("body_id", -1) != b.id: b.carrier_id = -1
			else: continue
		if b.pos.distance_to(bg.pos) > BURY_RANGE:
			if time - b.fell_t > D.DAY_LEN:
				b.buried = true
				bg.graves.append({"id": b.id, "name": b.name, "day": day(), "lost": true, "pos": grave_slot(bg, bg.graves.size())})
				add_log(tr("%s's body was never found. A stone at the burial ground keeps their name.") % tr(b.name), "story", [b])
			continue
		if rest_time() or not active_predators_near(b.pos, 400).is_empty(): continue
		var best: E.Unit = null
		for u in units:
			if u.dead or u.role != "" or u.sleeping or u.title == "War Chief": continue
			var jt: String = u.job.get("type", "")
			if jt != "" and jt != "gather": continue
			if u.pos.distance_to(b.pos) > BURY_RANGE: continue
			if best == null or (jt == "" and best.job.get("type", "") != "") or \
				((jt == "") == (best.job.get("type", "") == "") and u.pos.distance_to(b.pos) < best.pos.distance_to(b.pos)): best = u
		if best == null: continue
		if not best.job.is_empty():
			best.resume_job = best.job
			best.resume_key = best.job_key
			best.resume_t = best.job_t
		set_job(best, {"type": "bury", "body_id": b.id, "phase": "fetch", "t": 0.0})
		b.carrier_id = best.id
		popup(best.pos + Vector2(0, -30), tr("%s goes to fetch %s") % [tr(best.name), tr(b.name)], Color("#d8d0e8"))

func _do_bury(u: E.Unit, j: Dictionary, dt: float) -> void:
	var b := unit_by_id(j["body_id"])
	var bg := burial_ground()
	if b == null or b.buried or bg == null:
		_end_errand(u)
		return
	match j["phase"]:
		"fetch":
			u.act = "Fetching the body of " + b.name
			if approach(u, b.pos, 10, dt):
				j["phase"] = "carry"
				j["slot"] = grave_slot(bg, bg.graves.size() + units.filter(func(o): return o != u and o.job.get("type", "") == "bury" and o.job.has("slot")).size())
				u.path.clear()
				u.dest = null
		"carry":
			u.act = "Carrying the body of " + b.name
			var slot: Vector2 = j["slot"]
			if u.pos.distance_to(slot) <= 14:
				j["phase"] = "dig"
				u.path.clear()
			else:
				go_to(u, slot)
				step_move(u, dt, unit_speed(u) * 0.7)
			b.pos = u.pos + Vector2(-9, 5) # dragged on a hide litter
		"dig":
			u.act = "Burying " + b.name
			j["t"] += dt
			if j["t"] >= GRAVE_DIG:
				b.buried = true
				b.carrier_id = -1
				b.pos = j["slot"]
				bg.graves.append({"id": b.id, "name": b.name, "day": day(), "lost": false, "pos": j["slot"]})
				remember(u, tr("buried %s on Day %d") % [tr(b.name), day()], 6)
				add_log(tr("%s is laid to rest in the burial ground.") % tr(b.name), "story", [b])
				popup(bg.pos + Vector2(0, -40), tr("%s is laid to rest") % tr(b.name), Color("#d8d0e8"), true)
				devotion = minf(100.0, devotion + 1.0)
				evo.drift("spiritual", 1.0)
				_end_errand(u)

func _end_errand(u: E.Unit) -> void:
	if not u.resume_job.is_empty():
		var rj := u.resume_job
		u.resume_job = {}
		set_job(u, rj, u.resume_key)
		u.job_t = u.resume_t
	else:
		set_job(u, {})

# ------------------------------------------------------------------ night rest
const SHELTERS := ["hut", "large_hut", "granary"] # everything that houses people
const BED_FAR := 700.0 # further than this from a bed, people camp where they are

## Sleeping hours: a little inside the dark part of the day.
func rest_time() -> bool:
	var f := day_frac()
	return f >= 0.74 and f < 0.96

## Start of tonight's rest (orders given after this keep people up).
func night_start() -> float:
	var base := floorf(time / D.DAY_LEN) * D.DAY_LEN
	if day_frac() < 0.74: base -= D.DAY_LEN
	return base + D.DAY_LEN * 0.74

func in_hut(u: E.Unit) -> bool: return u.sleeping and u.bed_id >= 0

## Is something stirring that should rouse the camp? Beasts or raiders at the village (the
## War Chief's range), someone hurt in a fight, or the river flooding. A pack prowling the
## woods does not count: people in huts are safe from it, and outdoor sleepers watch for
## themselves (`_night_rest`).
func _danger_near() -> bool:
	if time - flags.get("flood_active", -99.0) < 20.0 or nat.alarm(): return true
	if not active_predators_near(D.VILLAGE, 500).is_empty(): return true
	for u in units:
		if not u.dead and time - u.last_hit_t < 4.0 and u.attacker_id >= 0: return true
	return false

func _night_watch() -> void:
	var rest := rest_time()
	if rest and not was_rest_time: add_log(tr("Night falls. The tribe lies down to sleep."), "info")
	was_rest_time = rest
	if not rest:
		night_alarm = false
		return
	if _danger_near(): alarm_until = time + 6.0
	var alarm := time < alarm_until
	if alarm and not night_alarm and units.any(func(u): return u.sleeping):
		add_log(tr("Danger in the night! The camp is roused."), "danger")
		popup(D.VILLAGE + Vector2(0, -60), tr("The camp wakes!"), Color("#ff9b7a"), true)
	night_alarm = alarm

func _at_war(u: E.Unit) -> bool:
	if u.role != "contract": return false
	var c = contracts.by_id(u.contract_id)
	return c != null and c.kind == "war" and contracts.is_running(c)

## Peaceful Task Contracts stop their clocks while the camp sleeps (an alarm restarts them).
func camp_asleep() -> bool:
	return rest_time() and not night_alarm

## Nothing stirs and everyone is in bed: the night can pass quickly (main.gd fast-forwards).
func night_ff() -> bool:
	if not camp_asleep() or paused: return false
	if contracts.list.any(func(c): return c.kind == "war" and contracts.is_running(c)): return false
	for u in units:
		if not u.dead and not u.sleeping: return false
	return true

func wake(u: E.Unit) -> void:
	if u.sleeping or u.bed_pos != null:
		u.path.clear()
		u.dest = null
	u.sleeping = false
	u.bed_id = -1
	u.bed_pos = null

## People with no orders from tonight go to bed (a hut, else beside a fire, else wherever
## they are) and sleep until dawn, unless an alarm wakes them. The job they had waits.
## Returns true while the unit is resting (its job is not run).
func _night_rest(u: E.Unit, dt: float) -> bool:
	var jt: String = u.job.get("type", "")
	# Contract crews and envoys camp for the night too (their jobs are re-issued by the
	# executor, so job_t says nothing about them); only a war party presses on.
	# During an alarm nobody goes back to the day's work: fighters get attack orders (War
	# Chief, self-defence), people in huts shelter inside, people outdoors keep watch.
	var crew: bool = u.role != ""
	var duty: bool = jt == "attack" or jt == "bury" or u.job.get("flee", false) \
		or (crew and _at_war(u)) or (not crew and not u.job.is_empty() and u.job_t >= night_start())
	if not (rest_time() or nat.panicking()) or duty:
		if u.sleeping or u.bed_pos != null: wake(u)
		return false
	if u.bed_pos == null: _pick_bed(u)
	var outdoors: bool = u.bed_id < 0
	var danger: bool = night_alarm or (outdoors and not active_predators_near(u.pos, 300).is_empty())
	if u.sleeping:
		if danger and outdoors:
			u.sleeping = false
			u.act = "Keeping watch"
		elif not outdoors:
			u.act = "Hiding in a hut" if nat.panicking() else ("Sheltering in a hut" if danger else "Sleeping in a hut")
		else:
			u.act = "Sleeping"
		return true
	if approach(u, u.bed_pos, 5, dt):
		u.path.clear()
		u.dest = null
		if danger and outdoors: u.act = "Keeping watch"
		else: u.sleeping = true
	else:
		u.act = "Going to sleep"
	return true

func _pick_bed(u: E.Unit) -> void:
	var bank := D.bank_of(u.pos)
	var near: Vector2 = u.home if D.bank_of(u.home) == bank and u.home.distance_to(u.pos) < BED_FAR else u.pos
	var best: E.Structure = null
	for s in structures:
		if not s.built or not ours(s) or not s.type in SHELTERS or D.bank_of(s.pos) != bank: continue
		var cap: int = int(D.STRUCTURES[s.type]["cap"])
		var used: int = units.filter(func(o): return not o.dead and o != u and o.bed_id == s.id).size()
		if used >= cap: continue
		if best == null or s.pos.distance_to(near) < best.pos.distance_to(near): best = s # beds at home first
	if best and best.pos.distance_to(u.pos) < BED_FAR:
		u.bed_id = best.id
		u.bed_pos = best.pos + Vector2(0, 6)
		return
	u.bed_id = -1
	var fire := _nearest_fire(u.pos)
	if fire and D.bank_of(fire.pos) == bank and fire.pos.distance_to(u.pos) < BED_FAR:
		var a := float(u.id) * 2.39996 # golden angle: spread the sleepers round the fire
		u.bed_pos = fire.pos + Vector2(cos(a), sin(a)) * (34.0 + float(u.id % 3) * 12.0)
	else:
		u.bed_pos = u.pos # camp in the open

func unit_idle(u: E.Unit, dt: float) -> void:
	u.act = "Resting (sick)" if u.sick > 0 else "Idle"
	if u.has_trait("devout") and u.role != "contract" and D.bank_of(u.pos) == D.bank_of(u.home):
		u.idle_t += dt
		if u.idle_t > 4:
			u.idle_t = 0
			assign_ritual(u, u.home + Vector2(randf_range(-40, 40), randf_range(-50, -20)))
		return
	u.idle_t += dt
	if u.idle_t > 5.0:
		u.idle_t = 0.0
		if folk.can_art(u):
			folk.start_art(u)
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
	var drain := 0.33 * (1.25 if u.has_trait("gluttonous") else 1.0) * (0.8 if evo.has_trad("shared_hearth") else 1.0) * hz.hunger_mult()
	u.hunger -= drain * dt * (0.6 if u.role == "child" else 1.0) + u.walked * WALK_HUNGER # long walks to work cost food
	u.walked = 0.0
	if u.hunger < 40 and stock["food"] >= 1:
		stock["food"] -= minf(stock["food"], MEAL) # a day's eating is a real cost: winter needs stores
		evo.drift("ranked", -0.15) # meals from the common store
		u.hunger = minf(100, u.hunger + (38.0 if has_tech("fire") else 30.0))
	if u.hunger <= 0:
		u.hunger = 0
		hurt_unit(u, 0.5 * dt, null)
	var warm := near_warmth(u)
	if warm and night_amt > 0.5: evo.practice(u, "hearth", dt)
	var cold := hz.cold_rate(u, warm)
	if u.sick > 0:
		if knows_find("willow") and time > u.herb_t and stock["herbs"] >= 1:
			stock["herbs"] -= 1
			u.herb_t = time + 30.0
			popup(u.pos + Vector2(0, -30), tr("Willow-bark tea"), Color("#b6f28a"))
		u.sick -= hz.heal_rate(u, warm) * dt
		if u.sick <= 0:
			u.sick = 0.0
			u.immune_t = time + D.DAY_LEN * 2
			popup(u.pos + Vector2(0, -30), tr("Recovered"), Color("#b6f28a"))
		elif u.hp > u.max_hp * (0.0 if u.hunger < 20 or hz.winter() else 0.3):
			hurt_unit(u, 0.12 * dt, null) # fever
	if cold > 0 and (hz.cold_can_kill() or u.hp > u.max_hp * 0.35):
		hurt_unit(u, cold * dt, null)
		if u.hp < u.max_hp * 0.4 and hz.cold_can_kill() and fmod(time, 6.0) < dt:
			popup(u.pos + Vector2(0, -30), tr("Freezing!"), Color("#a8d8ff"))
	elif u.hunger > 35 and u.sick <= 0 and time - u.last_hit_t > 5:
		if knows_find("yarrow") and u.hp < u.max_hp * 0.7 and time > u.salve_t and stock["herbs"] >= 1 and u.pos.distance_to(D.VILLAGE) < 350:
			stock["herbs"] -= 1
			u.salve_t = time + 30.0
			popup(u.pos + Vector2(0, -30), tr("Yarrow poultice"), Color("#b6f28a"))
		u.hp = minf(u.max_hp, u.hp + (0.7 if warm else 0.15) * (2.0 if time < u.salve_t else 1.0) * dt)

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
	u.fell_t = time
	wake(u)
	var cause: String = (tr("slain by a %s") % tr(killer.name)) if killer else (cause_hint if cause_hint != "" else tr("lost to hunger and cold"))
	u.death_cause = cause
	folk.on_death()
	add_log(tr("%s has fallen - %s.") % [tr(u.name), cause], "danger", [u])
	popup(u.pos + Vector2(0, -30), tr("%s has fallen") % tr(u.name), Color("#ff6b6b"), true)
	for o in units:
		if not o.dead and o != u and o.pos.distance_to(u.pos) < 300:
			remember(o, tr("witnessed %s %s on Day %d") % [tr(u.name), cause, day()], 8)
	evo.on_death(u)
	rivals.on_villager_killed(u, killer)
	if killer: evo.drift("martial", 1.5)
	if killer is E.Predator: # a predator that made its kill drags it away
		if killer.kind == "wolf":
			for w in predators:
				if w.kind == "wolf" and w.pos.distance_to(killer.pos) < 300: w.fleeing = true
		elif killer.raid and killer.clan == "": # (war bands fight on)
			killer.raid = false
			killer.goal = killer.den
			killer.path = []
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
	popup(p.pos + Vector2(randf_range(-8, 8), -20), tr("%s-%d") % [tr("CRIT ") if crit else "", roundi(dmg)], Color("#ffb36b") if crit else Color("#ffd0d0"))
	if p.hp <= 0 and not p.dead:
		p.dead = true
		if u:
			u.kills += 1
			gain_xp(u, "combat", 18)
			if p.clan != "": # a person, not a beast
				remember(u, tr("struck down a %s on Day %d") % [tr(p.name), day()], 8)
				add_log(tr("%s struck down a %s!") % [tr(u.name), tr(p.name)], "combat", [u])
			else:
				remember(u, tr("slew a %s on the %s bank on Day %d") % [tr(p.name), tr(D.bank_of(p.pos)), day()], 8)
				add_log(tr("%s slew a %s!") % [tr(u.name), tr(p.name)], "combat", [u])
			evo.drift("martial", 4.0)
		if p.clan != "": rivals.on_rival_killed(p, u)
		else: _node("carcass", "food", p.pos, 35)
	elif (p.kind == "hunter" or p.kind == "trader") and not p.fleeing: # attacked hunters run home and tell their clan
		p.fleeing = true
		rivals.on_hunter_attacked(p)
	elif p.hp < p.max_hp * 0.2 and not p.fleeing:
		p.fleeing = true
		popup(p.pos + Vector2(0, -30), tr("retreats!"), Color("#ffd0d0"))

func update_predator(p: E.Predator, dt: float) -> void:
	if p.dead or p.fled: return
	p.cd -= dt
	if p.fleeing and p.clan != "": # clan people retreat to their own village
		if not p.homeward:
			p.homeward = true
			p.raid = false
			set_dest(p, p.den)
		if step_move(p, dt, p.spd * 1.05) or p.pos.distance_to(p.den) < 30:
			p.fled = true
			rivals.on_return(p)
		return
	if p.fleeing:
		var out := Vector2(D.W + 40, p.pos.y)
		if p.kind == "wolf": out = Vector2(-40, p.pos.y) if D.bank_of(p.pos) == "west" else out
		p.path = [out]
		step_move(p, dt, p.spd * 1.1)
		if p.pos.x > D.W or p.pos.x < 0: p.fled = true
		return
	if p.kind == "wolf":
		p.raid_t -= dt
		if p.raid_t <= 0: p.fleeing = true
	if p.raid:
		p.raid_t -= dt
		if p.raid_t <= 0 and p.clan != "":
			p.fleeing = true # the war band gives up and goes home
			return
		if p.raid_t <= 0:
			p.raid = false
			p.goal = null
			p.path = []
	if p.kind == "warrior" and not p.raid and p.goal == null and not p.guard: # a war band done with its raid
		p.fleeing = true
		return
	var prey = null
	var best := 280.0
	for u in units:
		if u.dead or p.kind == "hunter" or p.kind == "trader" or in_hut(u): continue
		var d: float = u.pos.distance_to(p.pos)
		if p.kind == "wolf" and not _wolf_target(u): continue
		if d < best and D.bank_of(u.pos) == D.bank_of(p.pos) and (p.den == null or p.raid or u.pos.distance_to(p.den) < 380):
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
				popup(prey.pos + Vector2(0, -20), tr("-%d") % roundi(dmg), Color("#ff8080"))
	elif p.goal != null:
		if p.pos.distance_to(p.goal) > 30:
			if p.raid or p.kind == "wolf" or p.kind == "warrior" or p.kind == "trader": # long trips: route over the ford
				if p.path.is_empty(): set_dest(p, p.goal)
			else:
				p.path = [p.goal]
			step_move(p, dt, p.spd * 0.8)
		elif p.kind == "wolf":
			p.goal = D.VILLAGE + Vector2(randf_range(-260, 260), randf_range(-200, 200))
			p.path = []
		elif p.kind == "warrior" and p.raid: # in the camp and nobody to stop them
			rivals.steal(p)
		elif p.kind == "trader" and not p.arrived:
			p.arrived = true
			rivals.trader_arrived(p)
	else:
		p.prowl_t -= dt
		if p.prowl_t <= 0:
			p.prowl_t = randf_range(3, 6)
			var c: Vector2 = p.den if p.den != null else p.pos
			var r := 220.0 if p.den != null else 120.0
			var west: bool = D.bank_of(c) == "west"
			var rx := D.river_x(c.y)
			var np := Vector2(clampf(c.x + randf_range(-r, r), 30.0 if west else rx + D.RIVER_HALF + 80, rx - D.RIVER_HALF - 80 if west else D.W - 30), clampf(c.y + randf_range(-r, r), 40, D.H - 40))
			p.path = [np]
		step_move(p, dt, p.spd * 0.35)

## Wolves pick off stragglers: never people by a fire, rarely people in a group.
func _wolf_target(u: E.Unit) -> bool:
	if in_hut(u): return false
	if near_warmth(u): return false
	var near := 0
	for o in units:
		if not o.dead and o != u and o.pos.distance_to(u.pos) < 90: near += 1
	return near < 2

func active_predators_near(center: Vector2, r: float) -> Array:
	return predators.filter(func(p): return not p.dead and not p.fled and not p.fleeing and p.kind != "hunter" and p.kind != "trader" and p.pos.distance_to(center) < r)

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
	add_log(tr("The Grand Altar thunders - Yinglong, the winged dragon, answers the tribe's call!"), "story")
	popup(altar.pos + Vector2(0, -60), tr("Yinglong descends!"), Color("#9ff0d0"), true)

func _update_guardian(dt: float) -> void:
	if guardian == null or guardian.dead: return
	var g = guardian
	if g.hp <= 0:
		g.dead = true
		add_log(tr("Yinglong returns to the clouds, wounded."), "story")
		return
	g.cd -= dt
	var target = null
	var best := 900.0
	for p in predators:
		if p.dead or p.fled or p.kind in ["hunter", "trader"]: continue # peaceful clan folk
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
	var target := maxf(1.0 if (f > 0.72 and f < 0.97) else 0.0, nat.darkness())
	night_amt += (target - night_amt) * minf(1.0, dt * 0.8)

	var spoil := 0.0025 * (0.5 if has_tech("pottery") else 1.0) * (0.5 if knows_find("salt") else 1.0) * hz.spoil_mult()
	var cap := food_cap()
	if stock["food"] > 30: stock["food"] -= (minf(stock["food"], cap) - 30) * spoil * dt
	if stock["food"] > cap: # nowhere to keep it: it rots fast
		stock["food"] -= (stock["food"] - cap) * FOOD_ROT * dt
		if day() != rot_warn_day:
			rot_warn_day = day()
			alert(tr("The stores are full and food is rotting on the ground. Build a Granary to keep more."), D.VILLAGE, "warn")
	for s in structures:
		if not s.built or not ours(s): continue
		var sd: Dictionary = D.STRUCTURES[s.type]
		stock["food"] += sd.get("food", 0.0) * dt * (1.3 if evo.has_trad("harvest_festival") else 1.0) * hz.food_mult(s.type) * nat.food_mult(s)
		stock["lore"] += sd.get("lore", 0.0) * dt
	stock["lore"] += 0.03 * dt

	for n in nodes:
		match n.kind:
			"bush":
				n.amount = minf(n.max_amount, n.amount + n.regrow * dt * hz.berry_mult() * nat.grow_mult())
			"mushroom", "tubers", "grain", "honey", "fish", "willow", "yarrow", "salt":
				var fd: Dictionary = D.FINDS[n.kind]
				if fd["winter"] or not hz.winter(): n.amount = minf(n.max_amount, n.amount + fd["regrow"] * dt)
			"stump", "burnt":
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

	_night_watch()
	_burials(dt)
	_herd(dt)
	_resettle(dt)
	_finds_tick(dt)
	for u in units: update_unit(u, dt)
	fog_t -= dt
	if fog_t <= 0:
		fog_t = 0.2
		fog_update()
	for p in predators: update_predator(p, dt)
	predators = predators.filter(func(p): return not p.fled)
	_update_guardian(dt)
	contracts.update(dt)
	evo.update(dt)
	hz.update(dt)
	nat.update(dt)
	folk.update(dt)
	rivals.update(dt)
	legacy.update(dt)
	wear_t -= dt
	if wear_t <= 0:
		wear_t = 1.0
		for k in wear.size():
			if wear[k] > 0.0: wear[k] *= 0.996
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
		if birth_timer > 45:
			birth_timer = 0
			stock["food"] -= 15
			var free: Array = D.BIRTH_NAMES.filter(func(n): return unit_by_name(n) == null)
			var nm: String = free.pick_random() if not free.is_empty() else "Nameless"
			var parents: Array = living().filter(func(o): return o.role == "" and o.home.distance_to(D.VILLAGE) < 60)
			var u: E.Unit = folk.make_child(nm, parents.pick_random() if not parents.is_empty() else null)
			remember(u, tr("was born beside the tribal bonfire on Day %d") % day(), 5)
			folk.lift(5.0)
			units.append(u)
			evo.on_birth(u)
			add_log(tr("%s (%s) was born into the tribe.") % [tr(nm), tr(D.TRAITS[u.traits[0]]["name"])], "story", [u])
			popup(u.pos + Vector2(0, -24), tr("%s is born!") % tr(nm), Color("#ffd6f0"), true)
	else:
		birth_timer = maxf(0, birth_timer - dt)

# ------------------------------------------------------------------ Tier 3: Vice-Chieftains
func vice_slots() -> int: return 1 + (1 if has_tech("code") else 0) + (1 if evo.has_trad("council_of_elders") else 0)

## Why u can't take this Vice-Chieftain role right now ("" = they can). Any free slot
## works for either role; a person moving between roles frees their old slot.
func appoint_block(u: E.Unit, role: String) -> String:
	if u.role == "child": return "child"
	if vice[role] == u.id: return "already"
	var used := 0
	for k in vice:
		if vice[k] >= 0 and k != role and vice[k] != u.id: used += 1
	if used >= vice_slots(): return "no_slot"
	return ""

func appoint(u: E.Unit, role: String) -> bool:
	if appoint_block(u, role) != "": return false
	for k in vice:
		if vice[k] == u.id: vice[k] = -1
	vice[role] = u.id
	u.title = "Steward" if role == "steward" else "War Chief"
	remember(u, tr("was appointed %s of the tribe on Day %d") % [tr(u.title), day()], 7)
	evo.drift("ranked", 8.0)
	add_log(tr("%s appointed as Vice-Chieftain (%s).") % [tr(u.name), tr(u.title)], "vice", [u])
	return true

func _update_vice(dt: float) -> void:
	vice_timer -= dt
	if vice_timer > 0: return
	vice_timer = 3
	var steward := unit_by_id(vice["steward"])
	if steward and not steward.dead and not rest_time(): # no work handed out at night
		var idle := living().filter(func(u): return u.job.is_empty() and u.role == "" and u.id != steward.id and u.pos.distance_to(u.home) < 500)
		var pop := living().size()
		for u in idle:
			var unbuilt = null
			for s in structures:
				if (not s.built or s.reno) and s.paid and s.owner == "village":
					unbuilt = s
					break
			var choice: String
			var settler: bool = u.home.distance_to(D.VILLAGE) > 50
			if settler: unbuilt = null # (the village's building sites are far away)
			if unbuilt and randf() < 0.5: choice = "build"
			elif stock["food"] >= pop * 6 and stock["wood"] >= 40 and randf() < 0.25: choice = "art" # (stores are healthy: time for crafts)
			elif stock["food"] >= food_cap() * 0.95 and steward_policy != "lore": choice = "wood" # the stores are full
			elif stock["food"] < pop * 4 or steward_policy == "food": choice = "food"
			elif steward_policy == "wood" or stock["wood"] < 40: choice = "wood"
			elif steward_policy == "lore": choice = "lore"
			elif steward_policy == "stone" and has_tech("tools"): choice = "stone"
			else: choice = "food" if randf() < 0.5 else "wood"
			match choice:
				"build": assign_build(u, unbuilt)
				"lore": assign_ritual(u, u.home + Vector2(randf_range(-60, 60), -randf_range(30, 70)))
				"art": folk.start_art(u)
				_: assign_gather(u, choice, {"bank": D.bank_of(u.home), "area": u.home, "area_r": 900.0})
			gain_xp(steward, "lore", 0.5)
			evo.practice(steward, "lead", 2.0)
		if not idle.is_empty():
			add_log(tr("Steward %s put %d idle hands to work (%s).") % [tr(steward.name), idle.size(), tr(steward_policy)], "vice", [steward])
	var chief := unit_by_id(vice["warchief"])
	if chief and not chief.dead:
		var threats := active_predators_near(D.VILLAGE, 500)
		if not threats.is_empty():
			var fighters := living().filter(func(u): return u.role == "" and u.job.get("type", "") != "attack")
			fighters.sort_custom(func(a, b): return a.lv("combat") > b.lv("combat"))
			for u in fighters.slice(0, 3): assign_attack(u, threats[0])
			add_log(tr("War Chief %s rallies warriors against the beast!") % tr(chief.name), "vice", [chief])

# ------------------------------------------------------------------ village building (Tier 1)
func can_place(type: String, p: Vector2) -> String:
	var sd: Dictionary = D.STRUCTURES[type]
	if sd.has("tech") and not has_tech(sd["tech"]): return "Requires tech"
	if stock["wood"] < sd["wood"]: return "Not enough wood"
	if stock["stone"] < sd.get("stone", 0): return "Not enough stone"
	if absf(p.x - D.river_x(p.y)) < D.RIVER_HALF + 15: return "Too close to the river"
	return ""

func place_structure(type: String, p: Vector2) -> E.Structure:
	if can_place(type, p) != "": return null
	stock["wood"] -= D.STRUCTURES[type]["wood"]
	stock["stone"] -= D.STRUCTURES[type].get("stone", 0)
	var s := add_structure(type, p, false, "village", true)
	rivals.on_structure_placed(s)
	add_log(tr("Construction site laid out: %s.") % tr(D.STRUCTURES[type]["name"]), "build")
	return s

## Spend lore to finish an idea now. Practice already done makes it cheaper; the tribe's
## best shaman teaches everyone in the village.
func research(tech_id: String) -> String:
	var t: Dictionary = evo.tech_def(tech_id)
	if t.is_empty(): return "Unknown tech"
	if has_tech(tech_id): return "Already known"
	if not evo.prereqs_met(tech_id): return "Requires prior wisdom"
	var cost: int = evo.lore_cost(tech_id)
	if stock["lore"] < cost: return "Not enough lore"
	stock["lore"] -= cost
	evo.breakthrough(tech_id, best_unit("lore", false), "taught")
	return ""

## Bring every outdated home and wall up to the current era's style.
func outdated() -> Array:
	return structures.filter(func(s): return s.built and not s.reno and s.owner == "village" and s.type in D.STYLED and s.style < evo.era)

func reno_cost(list: Array) -> Dictionary:
	var w := 0
	var st := 0
	for s in list:
		w += ceili(D.STRUCTURES[s.type]["wood"] * 0.5)
		if evo.era >= 3: st += 6
	return {"wood": w, "stone": st}

func renovate(helpers: Array) -> String:
	var list := outdated()
	if list.is_empty(): return tr("Nothing to renovate")
	var cost := reno_cost(list)
	if stock["wood"] < cost["wood"] or stock["stone"] < cost["stone"]:
		return tr("Needs %d wood and %d stone") % [cost["wood"], cost["stone"]] if cost["stone"] > 0 else tr("Needs %d wood") % cost["wood"]
	stock["wood"] -= cost["wood"]
	stock["stone"] -= cost["stone"]
	for s in list:
		s.reno = true
		s.reno_progress = 0.0
	if helpers.is_empty():
		helpers = living().filter(func(u): return u.role != "contract" and D.bank_of(u.pos) == "west" and u.job.get("type", "") in ["", "ritual"]).slice(0, 3)
	var i := 0
	for u in helpers:
		assign_build(u, list[i % list.size()])
		i += 1
	add_log(tr("The tribe rebuilds %d homes and walls in the style of the %s.") % [list.size(), tr(D.ERA_NAMES[evo.era])], "build")
	return ""

func _finish_reno(s: E.Structure, u: E.Unit) -> void:
	s.reno = false
	s.style = evo.era
	popup(s.pos + Vector2(0, -30), tr("Renovated"), Color("#b6f28a"))
	gain_xp(u, "craft", 4)
	for o in structures:
		if o.reno and o.owner == "village":
			assign_build(u, o)
			return

# ------------------------------------------------------------------ milestone events
func _check_events() -> void:
	if pending_event != "": return
	if legacy.pending != "": # endings come first
		_fire_event(legacy.pending)
		return
	if not flags.has("flood") and time >= (D.FLOOD_DAY - 1) * D.DAY_LEN + 5:
		flags["flood"] = true
		_fire_event("flood")
	elif not flags.has("overpop") and living().size() >= D.OVERPOP_THRESHOLD:
		flags["overpop"] = true
		_fire_event("overpop")
	elif evo.pending_era > 1 and not flags.has("era%d" % evo.pending_era):
		flags["era%d" % evo.pending_era] = true
		_fire_event("era%d" % evo.pending_era)
		evo.pending_era = 0
	elif not flags.has("chosen") and devotion >= 100:
		flags["chosen"] = true
		_fire_event("chosen")
	elif folk.pending != "":
		folk.pending = ""
		_fire_event("festival")
	elif nat.pending != "":
		var ne: String = nat.pending
		nat.pending = ""
		_fire_event(ne)
	elif not rivals.pending.is_empty():
		_fire_event(rivals.pending.pop_front())

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
			remember(u, tr("survived the Great Flood on Day %d") % day(), 7)
	for s in structures:
		if ours(s) and s.built and s.type != "palisade" and absf(s.pos.x - D.river_x(s.pos.y)) < 220:
			s.built = false
			s.progress = s.work * 0.4
	add_log(tr("The Great Flood strikes! %d food washed away, %d hurt, riverside structures damaged.") % [lost, hurt], "danger")
	flags["flood_active"] = time

func best_unit(skill: String, exclude_contract := true) -> E.Unit:
	var best: E.Unit = null
	for u in living():
		if exclude_contract and u.role == "contract": continue
		if best == null or u.lv(skill) > best.lv(skill): best = u
	return best

## Civilization-style dilemmas. Each option: {label, desc, enabled}.
func event_def(id: String) -> Dictionary:
	if rivals.owns_event(id): return rivals.event_def(id)
	if legacy.owns_event(id): return legacy.event_def(id)
	if nat.owns_event(id): return nat.event_def(id)
	if folk.owns_event(id): return folk.event_def(id)
	var shaman := best_unit("lore", false)
	var sname: String = shaman.name if shaman else "The elders"
	match id:
		"flood":
			var chance := clampf(0.35 + 0.1 * (shaman.lv("lore") if shaman else 0), 0.0, 0.9)
			return {"title": tr("The Great Flood Warning"),
				"text": tr("%s wakes screaming: in the vision, black rains fall for nine nights and the river swallows the low camps. The elders look to you, Great Chieftain.") % sname,
				"options": [
					{"label": tr("The Ark Plan"), "desc": tr("Spend 40 wood on highland rafts and shelters. Everyone and everything is saved."), "enabled": stock["wood"] >= 40},
					{"label": tr("Sacrifice to the River Deity"), "desc": tr("Offer 25 food and relics. %d%% chance (scales with %s's Shamanism).") % [roundi(chance * 100), sname], "enabled": stock["food"] >= 25},
					{"label": tr("Trust the riverbanks"), "desc": tr("Do nothing and hope the vision is false."), "enabled": true},
				]}
		"overpop":
			return {"title": tr("Overpopulation Crisis"),
				"text": tr("The tribe now numbers %d. Game is thinning around the bonfire and quarrels break out over the last berries.") % living().size(),
				"options": [
					{"label": tr("Frontier Colonization"), "desc": tr("Appoint an experienced leader via a Task Contract to found a sister settlement across the river."), "enabled": true},
					{"label": tr("Territorial Conquest"), "desc": tr("Rally your 3 best warriors to raid a rival tribe for food and timber. Risky."), "enabled": living().size() >= 3},
				]}
		"era2", "era3":
			return _era_event_def(id)
		"chosen":
			return {"title": tr("Birth of the Chosen One"),
				"text": tr("Under a sky split by lightning, a child is born bearing the mark of the totem. Which mythic bloodline awakens?"),
				"options": [
					{"label": tr("Hou Yi the Archer"), "desc": tr("A peerless hunter. Foraging 7, Combat 6."), "enabled": true},
					{"label": tr("Yu the Flood-Tamer"), "desc": tr("A builder of levees and canals. Crafting 7, Lore 5."), "enabled": true},
					{"label": tr("Chiyou the Berserker"), "desc": tr("A storm of bronze and fury. Combat 8, 90 HP."), "enabled": true},
				]}
	return {}

## Returns {"text": outcome, "open_contract": bool}
func resolve_event(id: String, idx: int) -> Dictionary:
	pending_event = ""
	if rivals.owns_event(id):
		var txt: String = rivals.resolve(id, idx)
		var ow: String = flags.get("open_war", "")
		flags.erase("open_war")
		return {"text": txt, "open_contract": false, "open_war": ow}
	if nat.owns_event(id): return {"text": nat.resolve(id, idx), "open_contract": false}
	if folk.owns_event(id): return {"text": folk.resolve(id, idx), "open_contract": false}
	if legacy.owns_event(id):
		var lr: Dictionary = legacy.resolve(id, idx)
		return {"text": lr["text"], "open_contract": false, "restart": lr["restart"]}
	var shaman := best_unit("lore", false)
	var out := {"text": tr(""), "open_contract": false}
	match id:
		"flood":
			if idx == 0 and stock["wood"] >= 40:
				stock["wood"] -= 40
				out["text"] = tr("Rafts are lashed and shelters raised on the highland. When the waters come, the tribe watches from safety.")
				for u in living(): remember(u, tr("built highland rafts on the Ark Plan before the Great Flood"), 7)
			elif idx == 1 and stock["food"] >= 25:
				stock["food"] -= 25
				var chance := 0.35 + 0.1 * (shaman.lv("lore") if shaman else 0)
				if randf() < chance:
					out["text"] = tr("The river deity accepts the offering. The rains pass the tribe by.")
					if shaman:
						gain_xp(shaman, "lore", 25)
						remember(shaman, tr("appeased the River Deity and turned aside the Great Flood"), 9)
					devotion = minf(100, devotion + 20)
				else:
					out["text"] = tr("The deity is not appeased. The Great Flood strikes!")
					flood_strike()
			else:
				out["text"] = tr("The tribe ignores the vision. Nine nights later, the river rises.")
				flood_strike()
		"overpop":
			if idx == 0:
				out["text"] = tr("Choose a leader for the frontier. Their Task Contract negotiation begins now.")
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
					out["text"] = tr("%s return victorious, hauling 60 food and 40 timber from the rival camp.") % names
					for u in raiders:
						gain_xp(u, "combat", 30)
						remember(u, tr("raided a rival tribe and returned victorious on Day %d") % day(), 8)
				else:
					out["text"] = tr("The raid fails. %s limp home, bloodied and empty-handed.") % names
					for u in raiders:
						hurt_unit(u, u.max_hp * 0.4, null)
						remember(u, tr("was beaten back in a failed raid on a rival tribe on Day %d") % day(), 8)
		"chosen":
			var heroes := [
				{"name": "Hou Yi", "epithet": "the Archer", "traits": ["belligerent"], "color": Color("#ffd36b"), "hp": 70, "atk": 9, "def": 4, "spd": 1.25, "skills": {"forage": 7, "craft": 1, "combat": 6, "lore": 1}},
				{"name": "Yu", "epithet": "the Flood-Tamer", "traits": ["cautious"], "color": Color("#6bd3ff"), "hp": 65, "atk": 6, "def": 5, "spd": 1.05, "skills": {"forage": 2, "craft": 7, "combat": 2, "lore": 5}},
				{"name": "Chiyou", "epithet": "the Berserker", "traits": ["belligerent"], "color": Color("#ff6b6b"), "hp": 90, "atk": 11, "def": 5, "spd": 1.1, "skills": {"forage": 1, "craft": 1, "combat": 8, "lore": 0}},
			]
			var def: Dictionary = heroes[clampi(idx, 0, 2)]
			def["hero"] = true
			var u := make_unit(def, D.VILLAGE + Vector2(0, 40))
			remember(u, tr("was born under a lightning sky, bearing a mythic bloodline"), 10)
			units.append(u)
			evo.on_birth(u)
			out["text"] = tr("%s %s is born! The whole tribe feels the totem's favor.") % [tr(def["name"]), tr(def["epithet"])]
			popup(u.pos + Vector2(0, -30), tr("%s is born!") % tr(def["name"]), Color("#ffd36b"), true)
		"era2", "era3":
			out["text"] = _era_event_resolve(id, idx)
	add_log(out["text"], "story")
	return out

# ------------------------------------------------------------------ era transitions (culture-defining dilemmas)
const ERA_EVENTS := {
	"era2": {"title": "Dawn of the Tribe & Agrarian Era",
		"text": "New wisdom changes how the tribe lives, and not everyone is glad. %s",
		"voices": {"warrior": "\"Digging in the dirt? We are hunters!\"", "agrarian": "\"Full stores mean no hungry winters.\"",
			"mystic": "\"The forest spirits will not forgive the axe and the flame.\"", "cautious": "\"Walls and stores - that is how a tribe lasts.\"", "lazy": "\"If the food grows by itself, I like it.\""},
		"options": [
			{"label": "Put down roots", "desc": "Fields, pens and stores come first. (Settled +30, Spiritual -10)", "shift": {"settled": 30, "spiritual": -10}},
			{"label": "Honor the hunt", "desc": "The tribe stays hunters at heart. (Roaming +30, Martial +15)", "shift": {"settled": -30, "martial": 15}},
			{"label": "Let the shamans decide", "desc": "Ask the spirits before every change. (Spiritual +30, +15 lore)", "shift": {"spiritual": 30}, "lore": 15},
		]},
	"era3": {"title": "Dawn of the Bronze & Mythic Era",
		"text": "Great works are now within reach, and the elders argue over what the tribe should become. %s",
		"voices": {"warrior": "\"Arm every hand and no beast will trouble us again!\"", "mystic": "\"Raise the great totems so the ancestors see us.\"",
			"cautious": "\"Laws, not spears, keep a people whole.\"", "agrarian": "\"More fields, more mouths fed.\"", "lazy": "\"Whatever needs the least hauling.\""},
		"options": [
			{"label": "The Bronze Oath", "desc": "A warrior people under strong chiefs. (Martial +30, Ranked +15)", "shift": {"martial": 30, "ranked": 15}},
			{"label": "The Totem Covenant", "desc": "A people of the spirits. (Spiritual +30, +20 devotion)", "shift": {"spiritual": 30}, "devotion": 20},
			{"label": "The Elders' Law", "desc": "Rule by council and shared stores. (Ranked +20, Settled +15)", "shift": {"ranked": 20, "settled": 15}},
		]},
}

func _era_event_def(id: String) -> Dictionary:
	var ev: Dictionary = ERA_EVENTS[id]
	var voices: Array = []
	var seen := {}
	for u in living():
		var a := arch(u)
		if seen.has(a) or not ev["voices"].has(a): continue
		seen[a] = true
		voices.append("%s: %s" % [tr(u.name), tr(ev["voices"][a])])
		if voices.size() >= 3: break
	var opts: Array = []
	for o in ev["options"]: opts.append({"label": tr(o["label"]), "desc": tr(o["desc"]), "enabled": true})
	return {"title": tr(ev["title"]), "text": tr(ev["text"]) % "  ".join(voices), "options": opts}

func _era_event_resolve(id: String, idx: int) -> String:
	var o: Dictionary = ERA_EVENTS[id]["options"][clampi(idx, 0, 2)]
	for a in o["shift"]: evo.drift(a, o["shift"][a])
	stock["lore"] += o.get("lore", 0)
	devotion = minf(100.0, devotion + o.get("devotion", 0))
	for u in living(): remember(u, tr("lived through the dawn of the %s, when the tribe chose '%s'") % [tr(D.ERA_NAMES[evo.era]), tr(o["label"])], 6)
	return tr("The tribe chooses '%s'. The %s begins. Homes can now be rebuilt in the new style.") % [tr(o["label"]), tr(D.ERA_NAMES[evo.era])]


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
	return (D.SIGHT_UNIT + 12.0 * u.lv("forage") + (D.SIGHT_SCOUT_BONUS if u.job.get("type", "") == "explore" else 0.0) + (40.0 if evo.has_trad("wayfinders") else 0.0)) * hz.sight_mult() * nat.sight_mult()

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
		if s.built and ours(s): reveal(s.pos, D.SIGHT_BONFIRE if s.type == "bonfire" else D.SIGHT_STRUCT)
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
		parts.append(tr("+%d %s") % [rw[k], tr(k)])
	if lm.has("devotion"):
		devotion = minf(100.0, devotion + lm["devotion"])
		parts.append(tr("+%d devotion") % lm["devotion"])
	if lm.has("reveal"): reveal(lm["pos"], lm["reveal"])
	for tid in lm.get("insight", {}):
		if not has_tech(tid):
			evo.seed(tid, lm["insight"][tid], finder)
			parts.append(tr("inspires %s") % tr(evo.tech_def(tid)["name"]))
	var who: String = tr(finder.name) if finder else tr("The tribe")
	add_log(tr("Discovery! %s %s (%s).") % [who, tr(lm["text"]), ", ".join(parts)], "story" if lm["kind"] != "den" else "danger", [finder])
	popup(lm["pos"] + Vector2(0, -40), tr("Discovered: %s") % tr(lm["name"]), Color("#ffd36b"), true)
	if finder:
		remember(finder, tr("%s on Day %d") % [tr(lm["text"]), day()], 6)
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
