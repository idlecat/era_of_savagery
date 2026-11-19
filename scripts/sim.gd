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
const Improve = preload("res://scripts/improve.gd")
const Policy = preload("res://scripts/policy.gd")
const Crisis = preload("res://scripts/crisis.gd")
const Director = preload("res://scripts/director.gd")
const Names = preload("res://scripts/names.gd")
const Lands = preload("res://scripts/lands.gd")
const Roads = preload("res://scripts/roads.gd")
const Story = preload("res://scripts/story.gd")
const Inventions = preload("res://scripts/inventions.gd")
const Culture = preload("res://scripts/culture.gd")
const Reactions = preload("res://scripts/reactions.gd")
const Life = preload("res://scripts/life.gd")
const Scenarios = preload("res://scripts/scenarios.gd")

signal contract_interrupted(contract)
signal event_fired(event_id)
signal contract_finished(contract)
signal log_added()
signal alert_raised(alert)
signal envoy_arrived(unit, clan_id)
signal advice_wanted(ctx) # improve.gd asks which improvement to build; answer: improve.choose()
signal happened(id) # weather and nature, the ids of `after` conditions (culture.on_event)
signal sound_cue(id, at) # the story action "sound" (audio.gd plays it)
signal crisis_started(crisis) # emergency mode begins (crisis.gd): the HUD shows the orders
signal crisis_ended(crisis)
signal feat_added(feat) # one of the tribe's firsts (inv.feat): the HUD celebrates it
signal spoke(unit, text) # someone says something (a speech mark over their head, life.gd)

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
## Everyday rules (eating, storage, births, herds, burials, beds): config/rules.json.
var RULES: Dictionary = preload("res://scripts/config.gd").load_cfg("rules")
var evo: Evolution
var hz: Hazards
var nat: Nature
var folk: Folk
var improve: Improve # the village lays out improvements itself (improve.gd)
var policy: Policy # the Council's standing policies (policy.gd)
var crisis: Crisis # emergency mode: the chieftain's direct command in a crisis (crisis.gd)
var director: Director # paces the hardships (director.gd)
var roads: Roads # trails that emerge from feet, and the roads the tribe builds (roads.gd)
var story: Story # the scenario's scripted events (none on a random map)
var inv: Inventions # everyday inventions and the tribe's achievements
var cult: Culture # the culture's events, tales and legendary people (culture.gd)
var react: Reactions # how people respond to quakes, fires, the hurt... (reactions.gd)
var life: Life # meals, idle acts, bonds, spirits and weariness, speech (life.gd)
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
	improve = Improve.new(self)
	policy = Policy.new(self)
	crisis = Crisis.new(self)
	director = Director.new(self)
	roads = Roads.new(self)
	Names.install() # (built names are translation keys: a loaded game needs them too)
	story = Story.new(self)
	inv = Inventions.new(self)
	cult = Culture.new(self)
	react = Reactions.new(self)
	life = Life.new(self)
	rivals = Rivals.new(self)
	legacy = Legacy.new(self)

func uid() -> int:
	next_id += 1
	return next_id

# ------------------------------------------------------------------ setup
func new_game() -> void:
	if not D.is_ready(): Scenarios.apply() # (tests and tools that don't pick a map)
	add_structure("bonfire", D.VILLAGE, true)
	for h in D.HOME.get("huts", []): add_structure("hut", h, true)
	for f in D.HOME.get("forests", []): _forest(f[0], f[1], f[2])
	for b in D.HOME.get("bushes", []):
		var n := add_node("bush", "food", b, 30)
		n.regrow = 0.1
	_wilds()
	_boulders()
	_place_finds()
	for def in D.RIVALS: # clear the rival villages' grounds
		nodes = nodes.filter(func(n): return n.pos.distance_to(def["pos"]) > 230)
	rivals.setup()
	wear_w = ceili(D.W / WEAR_CELL)
	wear_h = ceili(D.H / WEAR_CELL)
	roads.setup()
	wear.resize(wear_w * wear_h)
	wear.fill(0.0)
	var herd := herd_sizes(70.0 * D.area_k() * Lands.num(D.LAND, "herds")) # herds in proportion to each stretch of land (and to how open it is)
	for r in herd:
		for i in herd[r]: spawn_deer(r, false)

	var count: int = D.TRIBE.size()
	for i in count:
		var a := float(i) / count * TAU
		units.append(make_unit(D.TRIBE[i], D.VILLAGE + Vector2(cos(a) * 70, sin(a) * 55)))
	for nm in D.CHILDREN: # the tribe's youngest
		var kid: E.Unit = folk.make_child(nm, null)
		kid.born_t = -D.DAY_LEN * randf_range(0.5, 1.5)
		units.append(kid)
	cult.setup() # (a random tribe may be led by the culture's founders)
	life.setup() # (the first friendships and feuds)
	_start_jobs()
	story.setup(D.SCRIPT)
	for line in D.MAP.get("intro", []): add_log(tr(line), "story")
	add_log(tr("Beyond the firelight the land is unknown. Send a scout (X) to explore it."), "story")
	_fog_init()
	fog_update()

## The first morning's work: as the scenario says, or one mystic at the fire, two
## foragers after food and someone on wood.
func _start_jobs() -> void:
	var jobs: Array = D.START_JOBS
	if jobs.is_empty():
		var adults: Array = living().filter(func(u): return u.role == "")
		var mystic = adults.filter(func(u): return u.has_trait("devout")).front() if adults.any(func(u): return u.has_trait("devout")) else null
		if mystic: jobs.append({"who": mystic.name, "job": "ritual"})
		var rest: Array = adults.filter(func(u): return u != mystic)
		rest.sort_custom(func(a, b): return a.lv("forage") > b.lv("forage"))
		for u in rest.slice(0, 2): jobs.append({"who": u.name, "job": "food"})
		rest = rest.slice(2)
		rest.sort_custom(func(a, b): return a.lv("craft") > b.lv("craft"))
		if not rest.is_empty(): jobs.append({"who": rest[0].name, "job": "wood"})
	for j in jobs:
		var u: E.Unit = unit_by_name(j["who"])
		if u == null: continue
		if j["job"] == "ritual": assign_ritual(u, D.VILLAGE + Vector2(30, -20))
		else: assign_gather(u, j["job"])

## How many deer each stretch of land carries, in proportion to its size.
func herd_sizes(total: float) -> Dictionary:
	var cells := 0
	for r in D.REGIONS:
		if D.REGIONS[r] >= 60: cells += D.REGIONS[r]
	var out := {}
	for r in D.REGIONS:
		if D.REGIONS[r] >= 60: out[r] = roundi(total * D.REGIONS[r] / maxf(1.0, cells))
	return out

## Outer wilderness of the big map: random forests and berry patches away from the home area,
## plus the landmarks (and the tiger dens) hidden in the fog.
func _wilds() -> void:
	var home := Rect2(D.VILLAGE - Vector2(700, 600), Vector2(1700, 1200))
	var placed := 0
	var tries := 0
	# how wooded the land is (config/lands.json): forests keep to the wet ground of a woodland
	# map (and near rivers), so woods gather into woodlands with open meadows between
	var wd: Dictionary = D.LAND.get("woods", {})
	var follow := float(wd.get("follow", 0.0))
	var river_k := float(wd.get("river", 1.0))
	var tr_: Array = wd.get("trees", [10, 24])
	var sp: Array = wd.get("spread", [110, 200])
	var wet := FastNoiseLite.new()
	wet.seed = int(D.MAP.get("seed", 0)) + 501
	wet.frequency = 0.0009 / sqrt(maxf(0.3, D.area_k()))
	var n_forests := roundi(80 * D.area_k() * float(wd.get("count", 1.0)))
	while placed < n_forests and tries < n_forests * 15:
		tries += 1
		var c := Vector2(randf_range(120, D.W - 120), randf_range(120, D.H - 120))
		if home.has_point(c) or D.river_dist(c) < 220: continue
		var near_lm := false
		for lm in D.LANDMARKS:
			if c.distance_to(lm["pos"]) < 230: near_lm = true
		if near_lm: continue
		if follow > 0.0: # (on parkland, follow 0: forests fall anywhere, as they always have)
			var w := wet.get_noise_2dv(c) * 0.5 + 0.5 + (river_k - 1.0) * 0.25 * clampf(1.0 - D.river_dist(c) / 700.0, 0.0, 1.0)
			if randf() > lerpf(1.0, smoothstep(0.42, 0.72, w), follow): continue
		_forest(c, randi_range(int(tr_[0]), int(tr_[1])), randf_range(float(sp[0]), float(sp[1])))
		placed += 1
	for i in roundi(24 * D.area_k() * Lands.num(D.LAND, "bushes")):
		var c := Vector2(randf_range(150, D.W - 150), randf_range(150, D.H - 150))
		if home.has_point(c) or D.river_dist(c) < 160: continue
		for k in 3:
			var n := add_node("bush", "food", c + Vector2(randf_range(-50, 50), randf_range(-40, 40)), 30)
			n.regrow = 0.1
	for def in D.LANDMARKS:
		var lm: Dictionary = def.duplicate(true)
		lm["found"] = false
		landmarks.append(lm)
		if lm["kind"] == "grove":
			for k in 6:
				var n := add_node("bush", "food", lm["pos"] + Vector2.from_angle(k * TAU / 6) * 60, 40)
				n.regrow = 0.14
		for k in int(lm.get("den", 0)):
			var pr := spawn_predator(lm["pos"] + Vector2(randf_range(-60, 60), randf_range(-40, 40)))
			pr.den = lm["pos"]

## Stone outcrops: only quarryable once the tribe knows Polished Stone Tools.
func _boulders() -> void:
	var spots: Array = [D.VILLAGE + Vector2(-330, 260), D.VILLAGE + Vector2(260, -300)]
	for lm in D.LANDMARKS:
		if lm["kind"] in ["flint", "peak", "stones"]: spots.append(lm["pos"] + Vector2(120, 90))
	for i in roundi(40 * D.area_k()):
		spots.append(Vector2(randf_range(150, D.W - 150), randf_range(150, D.H - 150)))
	for c in spots:
		if D.river_dist(c) < 150 or c.distance_to(D.VILLAGE) < 220: continue
		for k in 3:
			var p: Vector2 = c + Vector2(randf_range(-45, 45), randf_range(-35, 35))
			add_node("boulder", "stone", p, 40)

func add_node(kind: String, res: String, p: Vector2, amount: float) -> E.ResNode:
	var n := E.ResNode.new()
	n.id = uid(); n.kind = kind; n.res = res; n.pos = p; n.amount = amount; n.max_amount = amount
	nodes.append(n)
	return n

func _forest(c: Vector2, count: int, spread: float) -> void:
	for i in count:
		var a := randf() * TAU
		var r := sqrt(randf()) * spread
		var p := Vector2(clampf(c.x + cos(a) * r, 20, D.W - 20), clampf(c.y + sin(a) * r * 0.8, 20, D.H - 20))
		if D.river_dist(p) < D.RIVER_HALF + 20: continue
		if p.distance_to(D.VILLAGE) < 190 or D.SITES.any(func(s): return p.distance_to(s) < 130): continue
		var blocked := false
		for lm in D.LANDMARKS:
			if p.distance_to(lm["pos"]) < 90: blocked = true
		if blocked: continue
		var n := add_node("tree", "wood", p, 30)
		n.sz = randf_range(0.8, 1.25)

## A deer on the given stretch of land (-1: any); from_edge: wandering in from the map edge.
func spawn_deer(region: int, from_edge: bool) -> void:
	var p := Vector2.ZERO
	for k in 40:
		if from_edge:
			var e := randi() % 4
			var u := randf()
			p = [Vector2(randf_range(30, 120), u * D.H), Vector2(D.W - randf_range(30, 120), u * D.H), Vector2(u * D.W, randf_range(30, 120)), Vector2(u * D.W, D.H - randf_range(30, 120))][e]
		else:
			p = Vector2(randf_range(80, D.W - 80), randf_range(60, D.H - 60))
		p = Vector2(clampf(p.x, 30, D.W - 30), clampf(p.y, 60, D.H - 60))
		if not D.in_river(p) and (region < 0 or D.region_at(p) == region) and p.distance_to(D.VILLAGE) > 220: break
	var n := add_node("deer", "food", p, 25)
	n.bank = D.region_at(p)

func make_unit(def: Dictionary, p: Vector2) -> E.Unit:
	var u := E.Unit.new()
	u.id = uid()
	u.name = def["name"]; u.epithet = def.get("epithet", ""); u.traits = def["traits"].duplicate()
	var col: Variant = def.get("color", Color(0.7, 0.7, 0.7))
	u.color = Color(col) if col is String else col
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
func has_bronze() -> bool: return has_tech("bronze") and struct_exists("smelter") and stock["copper"] >= 1 and stock["tin"] >= 1
func knows_find(id: String) -> bool: return known_finds.has(id)
func struct_exists(type: String) -> bool:
	for s in structures:
		if s.built and ours(s) and s.type == type: return true
	return false
func living() -> Array: return units.filter(func(u): return not u.dead)

## A person by id, through a lookup table (people are only ever added: the dead stay in `units`).
var _cache_units := {}
var _cache_units_key: Array = [] # [the units array, its size] when the table was made
func unit_by_id(id: int) -> E.Unit:
	if id < 0: return null
	if _cache_units_key.size() != 2 or not is_same(_cache_units_key[0], units) or _cache_units_key[1] != units.size():
		_cache_units.clear()
		for u in units: _cache_units[u.id] = u
		_cache_units_key = [units, units.size()]
	return _cache_units.get(id)
func unit_by_name(n: String) -> E.Unit:
	for u in units:
		if u.name == n: return u
	return null
func struct_by_id(id: int) -> E.Structure:
	for s in structures:
		if s.id == id: return s
	return null
## Resource nodes by id and by resource: lookup tables rebuilt whenever the list of nodes
## changes (a node added or removed, or a loaded game's list). With thousands of trees in a
## deep forest, scanning them all for every gatherer was slow. A node's `res` never changes.
var _cache_nodes := {}
var _cache_by_res := {} # res -> [nodes]
var _cache_live: Array = [] # nodes that grow, regrow or move (not trees or boulders), refreshed every second
var _cache_live_t := 0.0
var _cache_nodes_key: Array = [] # [the nodes array, its size, next_id] when the tables were made
func node_by_id(id: int) -> E.ResNode:
	if id < 0: return null
	_index_nodes()
	return _cache_nodes.get(id)

## The nodes that give `res` (food, wood, stone, herbs...), depleted ones included.
func nodes_of(res: String) -> Array:
	_index_nodes()
	return _cache_by_res.get(res, [])

func _index_nodes() -> void:
	if _cache_nodes_key.size() == 3 and is_same(_cache_nodes_key[0], nodes) and _cache_nodes_key[1] == nodes.size() and _cache_nodes_key[2] == next_id: return
	_cache_nodes.clear()
	_cache_by_res.clear()
	for n in nodes:
		_cache_nodes[n.id] = n
		if not _cache_by_res.has(n.res): _cache_by_res[n.res] = []
		_cache_by_res[n.res].append(n)
	_cache_nodes_key = [nodes, nodes.size(), next_id]
	_cache_live_t = 0.0

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

func nearest_fire(p: Vector2) -> E.Structure:
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

## A building's radius: a wall's chosen one, else its type's.
func struct_r(s: E.Structure) -> float:
	return s.size if s.size > 0.0 else float(D.STRUCTURES[s.type]["r"])

## A wall's radius clamped and snapped to the allowed ones (config "buildings.ring"); 0 = default.
func ring_radius(type: String, want: float) -> float:
	var sd: Dictionary = D.STRUCTURES[type]
	if not sd.get("ring", false) or want <= 0.0: return float(sd["r"])
	var rc: Dictionary = BLD["ring"]
	return clampf(snappedf(want, float(rc["step"])), float(rc["min"]), float(rc["max"]))

## What laying out `type` costs (a wall's cost and work scale with its radius).
func place_cost(type: String, size := 0.0) -> Dictionary:
	var sd: Dictionary = D.STRUCTURES[type]
	var k := ring_radius(type, size) / float(sd["r"]) if sd.get("ring", false) else 1.0
	return {"wood": ceili(sd["wood"] * k), "stone": ceili(sd.get("stone", 0) * k), "work": float(sd["work"]) * k}

## Inside one of our walls (people there fight better).
func inside_wall(p: Vector2) -> bool:
	for s in structures:
		if s.built and ours(s) and D.STRUCTURES[s.type].get("ring", false) and s.pos.distance_to(p) < struct_r(s) + 15.0: return true
	return false

func struct_near(type: String, p: Vector2, r: float) -> bool:
	for s in structures:
		if s.built and ours(s) and s.type == type and s.pos.distance_to(p) < r: return true
	return false

# ------------------------------------------------------------------ stats
func unit_atk(u: E.Unit) -> float:
	var a := u.atk * (1.0 + 0.15 * u.lv("combat"))
	if has_tech("tools"): a += 2
	a += inv.atk_bonus() # the sling
	if evo.has_trad("warrior_initiation"): a += 2
	if has_bronze(): a *= 1.6
	elif knows_find("obsidian"): a *= 1.15 # black-glass blades
	if struct_near("weapon_rack", u.pos, 160): a *= 1.2
	if u.role == "contract":
		var c = contracts.by_id(u.contract_id)
		if c and c.flags.get("blessed", false): a *= 1.15 # the war dance
	return a

func unit_def(u: E.Unit) -> float:
	var d := u.def * (1.0 + 0.15 * u.lv("combat"))
	if has_tech("hide"): d += 2
	d += inv.add("def")
	if has_bronze(): d += 3
	if inside_wall(u.pos): d += 3
	d += crisis.def_bonus(u) # (rallied together)
	for o in units: # Centurion Aura
		if not o.dead and o != u and o.lv("combat") >= 5 and o.pos.distance_to(u.pos) < 110:
			d *= 1.2
			break
	return d

func unit_speed(u: E.Unit) -> float:
	var s := 58.0 * u.spd
	if u.hp < u.max_hp * 0.3 and inv.add("steady") <= 0.0: s *= 0.7 # (bone setting)
	if u.job.get("type", "") == "explore": s *= 1.15 # scouts travel light
	if evo.has_trad("wayfinders"): s *= 1.1
	s *= hz.speed_mult() * inv.mul("speed")
	if u.carry_amt > 0: s *= 0.95 if u.ox else 0.85 # loads slow the walk home
	return s * roads.speed_at(u.pos) * life.speed_mult(u) # (trails and roads; weariness, hurry)

func work_mul(u: E.Unit) -> float: return (0.9 if u.has_trait("lazy") else 1.0) * (0.6 if u.sick > 0 else 1.0) * hz.work_mult() * folk.work_mult() * inv.mul("work") * policy.crew_work(u) * life.work_mult(u)
func carry_cap(u: E.Unit) -> int: return (15 if u.ox else 10) + inv.carry_bonus()
## Food storage: the village keeps FOOD_STORE_BASE, each Granary FOOD_STORE_GRANARY more;
## anything over that rots at FOOD_ROT per second (config/rules.json "survival").
var FOOD_STORE_BASE: int = int(RULES["survival"]["store_base"])
var FOOD_STORE_GRANARY: int = int(RULES["survival"]["store_granary"])
var FOOD_ROT: float = float(RULES["survival"]["rot"])
func food_cap() -> int:
	var c := FOOD_STORE_BASE + inv.store_bonus()
	for s in structures:
		if s.built and ours(s) and s.type == "granary": c += FOOD_STORE_GRANARY
	return c
## Hunger per unit of distance walked: a villager walking all day gets ~70% hungrier.
var WALK_HUNGER: float = float(RULES["survival"]["walk_hunger"])

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
		life.praise(u, "level_up")
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
	if D.is_water(t): t = D.shore(t, 8.0)
	e.path = D.route(e.pos, t) # over the fords where rivers lie between
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
		var sh := D.shore(np, 1.0)
		var info := D.river_info(e.pos)
		np = sh if info["d"] >= D.RIVER_HALF else e.pos
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
	u.face = null

func assign_move(u: E.Unit, p: Vector2) -> void: set_job(u, {"type": "move", "to": p})
func assign_flee(u: E.Unit) -> void:
	set_job(u, {"type": "move", "to": u.home + Vector2(randf_range(-30, 30), randf_range(-30, 30)), "flee": true})
func assign_gather(u: E.Unit, res: String, opts := {}) -> void:
	set_job(u, {"type": "gather", "res": res, "node_id": opts.get("node_id", -1),
		"dropoff": opts.get("dropoff", -1), "area": opts.get("area", null), "area_r": opts.get("area_r", 2000.0),
		"bank": opts.get("bank", -1), "phase": "collect"}, opts.get("key", ""))
func assign_build(u: E.Unit, s: E.Structure, key := "") -> void: set_job(u, {"type": "build", "struct_id": s.id}, key)
## Roam around `center` (within r) looking for finds of `group` (a search quest).
func assign_seek(u: E.Unit, center: Vector2, r: float, group: String, key := "") -> void:
	set_job(u, {"type": "seek", "seek": group, "center": center, "r": r, "to": center}, key)

func assign_attack(u: E.Unit, p: E.Predator, key := "") -> void: set_job(u, {"type": "attack", "target_id": p.id}, key)
func assign_ritual(u: E.Unit, p: Vector2, key := "") -> void: set_job(u, {"type": "ritual", "at": p, "elapsed": 0.0}, key)
func assign_experiment(u: E.Unit, p: Vector2, label: String, key := "") -> void: set_job(u, {"type": "experiment", "at": p, "label": label}, key)
## AoE2-DE-style auto-scout: keep walking to the nearest unexplored land.
func assign_explore(u: E.Unit) -> void: set_job(u, {"type": "explore", "to": null})

func find_node(res: String, from: Vector2, bank: int, max_dist: float) -> E.ResNode:
	var best: E.ResNode = null
	var best_score := INF
	var claims_of := {} # node id -> people already working it (counted once, not per node)
	for u in units:
		if not u.dead and u.job.has("node_id"): claims_of[u.job["node_id"]] = claims_of.get(u.job["node_id"], 0) + 1
	var prefer := {} # kind -> the ways' preference (looked up once per kind)
	for n in nodes_of(res):
		if n.amount < 1: continue
		var d: float = n.pos.distance_to(from) # (cheap checks first: thousands of trees in a forest)
		if d > max_dist: continue
		if n.kind == "boulder" and not has_tech("tools"): continue
		if D.FINDS.has(n.kind) and not _can_gather_find(n): continue
		if bank >= 0 and D.region_at(n.pos) != bank: continue
		var claims: int = claims_of.get(n.id, 0)
		if not prefer.has(n.kind): prefer[n.kind] = inv.add("prefer", n.kind)
		var score := d * 1.4 + claims * 70.0 + (60.0 if n.kind == "deer" else 0.0) + (0.0 if is_explored(n.pos) else 900.0) - float(prefer[n.kind])
		if score < best_score:
			best_score = score
			best = n
	return best

# ------------------------------------------------------------------ unit update
func update_unit(u: E.Unit, dt: float) -> void:
	u.doing = ""
	if u.dead: return
	unit_needs(u, dt)
	u.cd -= dt
	u.xp_flush_t -= dt
	if u.xp_acc >= 1 and u.xp_flush_t <= 0:
		popup(u.pos + Vector2(0, -22), tr("+%d EXP") % roundi(u.xp_acc))
		u.xp_acc = 0
		u.xp_flush_t = 1.6

	# Freezing: the "freezing" reactions (go to the nearest fire).
	if hz.cold_can_kill() and u.job.get("type", "") != "warm" and not in_hut(u): react.trigger("freezing", {"victim": u, "at": u.pos})
	if u.role == "envoy" and u.job.get("type", "") != "envoy" and u.resume_job.get("type", "") != "envoy":
		u.role = "" # recalled: the mission is off
		# Self-defense or flight when attacked
	if time - u.last_hit_t < float(RULES["defense"]["hit_secs"]) and u.attacker_id >= 0:
		var p := pred_by_id(u.attacker_id)
		if p and not p.dead and not p.fleeing:
			var low := u.hp < u.max_hp * float(RULES["defense"]["flee_below"])
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
				set_aside(u)
				assign_attack(u, p, u.job_key)

	if _night_rest(u, dt): return
	if life.waking(u): return
	var jt0: String = u.job.get("type", "")
	if folk.festival_on() and u.role in ["", "child"] and u.home.distance_to(D.VILLAGE) < 60 and jt0 != "attack" and not u.job.get("flee", false) and not u.job.get("react", false) and jt0 != "bury":
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
				if j.get("hold", false): u.act = "Standing ready" # (a crisis order: stay until it is over)
				elif u.resume_job.get("type", "") == "explore":
					u.resume_job = {}
					assign_explore(u)
					u.job_t = u.resume_t
				elif j.get("react", false): # (out of danger: back to work)
					end_errand(u)
				else:
					set_job(u, {})
		"gather":
			_do_gather(u, j, dt)
		"bury":
			_do_bury(u, j, dt)
		"tend":
			_do_tend(u, j, dt)
		"cover":
			react.do_cover(u, j, dt)
		"aid":
			react.do_aid(u, j, dt)
		"warm":
			react.do_warm(u, j, dt)
		"shelter":
			react.do_shelter(u, j, dt)
		"firefight":
			react.do_firefight(u, j, dt)
		"look":
			react.do_look(u, j, dt)
		"startle":
			react.do_startle(u, j, dt)
		"life":
			life.do_act(u, j, dt)
		"meal":
			life.do_meal(u, j, dt)
		"depart":
			life.do_depart(u, j, dt)
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
			var tgt: Vector2 = s.pos + Vector2(cos(u.id), sin(u.id)) * struct_r(s) if ring else s.pos
			var near: float = 18.0 if ring else sd["r"] + 10.0
			if s.type == "roadworks": # (a road: work along it, stretch by stretch)
				tgt = roads.next_cell_pos(s) + Vector2(cos(u.id), sin(u.id)) * 8.0
				near = 14.0
			if not s.paid:
				u.act = "Waiting for materials"
				return
			if approach(u, tgt, near, dt):
				var speed := dt * (1.0 + 0.12 * u.lv("craft")) * work_mul(u) * (1.2 if evo.has_trad("makers_pride") else 1.0) * inv.mul("build")
				gain_xp(u, "craft", dt * 0.9)
				evo.practice(u, "build", dt)
				evo.drift("spiritual", -0.005 * dt)
				u.doing = "build"
				if s.reno:
					u.act = ("Upgrading " if s.upgrade != "" else "Renovating ") + sd["name"]
					s.reno_progress += speed
					if s.reno_progress >= reno_need(s): finish_reno(s, u)
				else:
					u.act = "Building " + sd["name"]
					s.progress += speed
					if s.type == "roadworks": roads.progress(s)
					if s.progress >= s.work: complete_structure(s, u)
			else:
				u.act = "Walking to " + sd["name"]
		"seek":
			u.act = {"food": "Searching for new foods", "medicine": "Searching for healing plants", "ore": "Searching for stones and ores"}.get(j["seek"], "Searching for new foods")
			if approach(u, j["to"], 8, dt): # there: on to another likely spot
				var c: Vector2 = j["center"]
				for k in 8:
					var q: Vector2 = c + Vector2.from_angle(randf() * TAU) * sqrt(randf()) * float(j["r"])
					q = Vector2(clampf(q.x, 30, D.W - 30), clampf(q.y, 40, D.H - 40))
					if not D.in_river(q) and D.region_at(q) == D.region_at(c):
						j["to"] = q
						break
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
			u.doing = "fight"
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
				u.doing = "experiment"
				gain_xp(u, "lore", dt * 0.3)
				gain_xp(u, "craft", dt * 0.2)
			else:
				u.act = "Walking to the workshop"
		"explore":
			u.act = "Scouting"
			var threat := active_predators_near(u.pos, react.reach_of("beast_seen"))
			if not threat.is_empty(): # scouts and beasts: the "beast_seen" reactions
				threat.sort_custom(func(a, b): return a.pos.distance_to(u.pos) < b.pos.distance_to(u.pos))
				j["to"] = null # (a fresh scouting target afterwards)
				react.trigger("beast_seen", {"victim": u, "danger": threat[0].pos, "attacker": threat[0]})
				if u.job.get("type", "") != "explore": return
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
				u.doing = "ritual"
				var boost := 1.5 if (struct_near("totem_shrine", u.pos, 140) or struct_near("grand_altar", u.pos, 140)) else 1.0
				if evo.has_trad("ancestor_rites"): boost *= 1.3
				stock["lore"] += dt * 0.22 * (1.0 + 0.2 * u.lv("lore")) * boost
				devotion = minf(100.0, devotion + dt * 0.07 * (1.0 + 0.1 * u.lv("lore")) * (1.3 if evo.has_trad("ancestor_rites") else 1.0) * inv.mul("devotion"))
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
		u.doing = {"tree": "chop", "carcass": "butcher", "boulder": "quarry"}.get(n.kind, "pick")
		var base: float = fd["rate"] if not fd.is_empty() else {"tree": 1.2, "carcass": 1.4, "boulder": 0.6}.get(n.kind, 1.0)
		var rate := base * (1.0 + 0.1 * u.lv("forage")) * (1.3 if has_tech("tools") and n.kind != "bush" else 1.0) * work_mul(u)
		if evo.has_trad("peaceful_ways"): rate *= 1.2
		rate *= inv.gather_mult(n.kind, fd["practice"] if not fd.is_empty() else {"tree": "chop", "carcass": "hunt", "boulder": "quarry"}.get(n.kind, "berry"))
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
		if n.from_deer and not hz.winter(): # no new herds arrive in winter; how many do depends on the hunt
			var hm := inv.mul("herd")
			for i in floori(hm) + (1 if randf() < hm - floorf(hm) else 0): spawn_deer(n.bank, true)

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
	if s.type == "roadworks": # a finished road is part of the ground, not a building
		s.progress = s.work
		roads.progress(s)
		structures.erase(s)
		add_log(tr("The road is finished."), "build", [u] if u else [])
		return
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
	if ours(s): react.trigger("built", {"at": s.pos})
	if s.type == "grand_altar": summon_guardian(s)

# ------------------------------------------------------------------ natural finds
## Scatter clusters of each find over the map (see D.FINDS "where").
func _place_finds() -> void:
	var trees: Array = nodes.filter(func(n): return n.kind == "tree")
	for id in D.FINDS:
		var fd: Dictionary = D.FINDS[id]
		var made := 0
		var tries := 0
		var want := maxi(1, roundi(fd["count"] * 2 * D.area_k())) # twice the clusters of the old 3600x2400 map, scaled by area
		while made < want and tries < want * 300:
			tries += 1
			var c = _find_spot(fd["where"], trees, made == 0 and fd["group"] != "ore")
			if c == null: continue
			var k_max: int = fd.get("cluster", 2 if fd["group"] == "ore" else 3)
			for k in k_max:
				var p: Vector2 = c + Vector2(randf_range(-30, 30), randf_range(-22, 22)) if k > 0 else c
				if fd["where"] != "river" and D.river_dist(p) < D.RIVER_HALF + 12: continue
				if fd["where"] == "river": # a shoal strings along the shallows
					var info := D.river_info(c)
					p = info["c"] + info["t"] * randf_range(-40, 40) * k
					p = D.river_info(p)["c"] + info["n"] * (D.RIVER_HALF - 26.0)
				p = Vector2(clampf(p.x, 30, D.W - 30), clampf(p.y, 30, D.H - 30))
				var n := add_node(id, fd["res"], p, fd["amount"])
				n.regrow = fd["regrow"]
				n.bank = D.region_at(p)
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
			if D.RIVERS.is_empty(): return null
			var pts: PackedVector2Array = D.RIVERS[randi() % D.RIVERS.size()]
			var k := randi_range(1, pts.size() - 2)
			var c: Vector2 = pts[k]
			if c.x < 120 or c.y < 120 or c.x > D.W - 120 or c.y > D.H - 120: return null
			if D.FORDS.any(func(f): return f["p"].distance_to(c) < 225.0): return null
			var tg := (pts[k + 1] - pts[k - 1]).normalized()
			var side := -1.0 if randf() < 0.5 else 1.0
			p = c + Vector2(-tg.y, tg.x) * side * ((D.RIVER_HALF - 26.0) if where == "river" else D.RIVER_HALF + randf_range(45, 95))
		"meadow":
			p = Vector2(randf_range(120, D.W - 120), randf_range(120, D.H - 120))
			if trees.any(func(t): return t.pos.distance_to(p) < 80): return null
		"hills_home": # on the tribe's own side of the water
			p = Vector2(randf_range(120, D.W - 120), randf_range(120, D.H - 120))
			if p.distance_to(D.VILLAGE) < 650 or not D.home_side(p) or D.river_dist(p) < 450: return null
		"hills_far": # across the water (or far off, where no river divides the land)
			p = Vector2(randf_range(120, D.W - 120), randf_range(120, D.H - 120))
			if D.river_dist(p) < 400 or (D.home_side(p) and (D.REGIONS.size() > 1 or p.distance_to(D.VILLAGE) < 1800)): return null
	if p.distance_to(D.VILLAGE) < 260 or p.distance_to(D.VILLAGE) > lim: return null
	if where != "river" and D.river_dist(p) < D.RIVER_HALF + 30: return null
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
	var rng_: float = float(DISC.get("range", 80))
	var seek_rng: float = float(DISC.get("seek_range", 140))
	for n in nodes:
		if not D.FINDS.has(n.kind) or knows_find(n.kind) or not is_explored(n.pos): continue
		for u in units: # (noticed by chance: skill, temperament and what they are doing count)
			if u.dead or u.sleeping or u.role == "child": continue
			var seeking: bool = u.job.get("seek", "") != ""
			if u.pos.distance_to(n.pos) > (seek_rng if seeking else rng_) or not can_recognise(u, n.kind): continue
			if randf() < 1.0 - exp(-find_chance(u, n.kind) * 0.5):
				discover_find(n.kind, u, n.pos)
				break
	if has_tech("bronze") and struct_exists("smelter") and day() != smelter_day and not rest_time():
		smelter_day = day()
		if stock["copper"] >= 1 and stock["tin"] >= 1:
			stock["copper"] -= 1
			stock["tin"] -= 1
		else:
			alert(tr("The smelter is cold: it needs copper and tin. Without them, no bronze arms the tribe."), D.VILLAGE, "warn")

var DISC: Dictionary = preload("res://scripts/config.gd").load_cfg("discovery") # how things are discovered (odds)

## The chance per second that `u` notices find `id` when near it (config/discovery.json):
## the find's group, their skill in it, their temperament, what they are doing, its rarity.
func find_chance(u: E.Unit, id: String) -> float:
	var g: Dictionary = DISC.get("groups", {}).get(str(D.FINDS[id].get("group", "food")), {})
	var p := float(g.get("chance", 0.005)) * (1.0 + float(g.get("per_lv", 0.3)) * u.lv(str(g.get("skill", "forage"))))
	for t in g.get("traits", {}):
		if u.has_trait(t): p *= float(g["traits"][t])
	var act: Dictionary = DISC.get("activity", {})
	var seek: String = str(u.job.get("seek", ""))
	var jt: String = u.job.get("type", "")
	var k := "default"
	if seek != "": k = "seek" if seek == str(D.FINDS[id].get("group", "")) or seek == "any" else "explore" # (looking for something else: still keen-eyed)
	elif jt in ["explore", "gather", "build"]: k = jt
	p *= float(act.get(k, act.get("default", 1.0)))
	return p * float(DISC.get("finds", {}).get(id, 1.0))

func discover_find(id: String, u: E.Unit, at: Vector2) -> void:
	if knows_find(id): return
	known_finds[id] = day()
	if u and u.role == "contract": # a search quest's crew keeps a tally of what it found
		var sc = contracts.by_id(u.contract_id)
		if sc and sc.kind == "seek": sc.flags["found"] = sc.flags.get("found", []) + [id]
	var fd: Dictionary = D.FINDS[id]
	add_log(tr("Discovery! %s found %s: %s") % [tr(u.name), tr(fd["name"]), tr(fd["desc"])], "story", [u])
	popup(at + Vector2(0, -40), tr("Discovered: %s") % tr(fd["name"]), Color("#ffd36b"), true)
	remember(u, tr("found %s on Day %d") % [tr(fd["name"]), day()], 6)
	inv.feat("find", tr("Found %s") % tr(fd["name"]), u, {"desc": tr(fd["desc"]), "source": fd.get("source", ""), "history": fd.get("history", ""), "at": at})
	gain_xp(u, "lore" if fd["group"] == "medicine" else "forage", 5)
	match id:
		"flint": evo.seed("tools", 0.45, u)
		"grain": evo.seed("farming", 0.25, u)
		"copper", "tin": evo.seed("bronze", 0.12, u)
		"ochre": evo.drift("spiritual", 3.0)
		"willow", "yarrow": stock["lore"] += 5
	for t in fd.get("seed", {}): evo.seed(t, float(fd["seed"][t]), u) # a culture find's insight
	for ax in fd.get("culture", {}): evo.drift(ax, float(fd["culture"][ax]))

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
## The aurochs pens (config/rules.json "herds"): oxen per pen, food eaten per ox per second
## (more in winter: no grazing), milk per cared-for ox, days until untended care runs out.
var OX_PER_PEN: int = int(RULES["herds"]["per_pen"])
var OX_EAT: float = float(RULES["herds"]["eat"])
var OX_MILK: float = float(RULES["herds"]["milk"])
var CARE_DECAY: float = 100.0 / (D.DAY_LEN * float(RULES["herds"]["care_days"]))
var TEND_TIME: float = float(RULES["herds"]["tend_time"])

func pens() -> Array:
	return structures.filter(func(s): return s.built and ours(s) and s.type == "aurochs_pen")

func ox_cap() -> int: return pens().size() * OX_PER_PEN
func oxen_working() -> bool: return oxen > 0 and ox_care > 0.0

## Oxen eat, give milk, need tending, and are lent to the gatherers working furthest out.
func _herd(dt: float) -> void:
	var cap := ox_cap()
	if oxen > cap: oxen = cap # a pen was lost
	if oxen > 0:
		var need: float = OX_EAT * oxen * (float(RULES["herds"]["winter_eat"]) if hz.winter() else 1.0) * dt
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
	var gatherers: Array = units.filter(func(u): return not u.dead and not u.sleeping and u.job.get("type", "") == "gather" and D.home_side(u.pos))
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
	set_aside(best)
	set_job(best, {"type": "tend", "pen_id": ps[0].id, "t": 0.0})

func _do_tend(u: E.Unit, j: Dictionary, dt: float) -> void:
	var pen := struct_by_id(j["pen_id"])
	if pen == null or not pen.built or oxen <= 0:
		end_errand(u)
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
		end_errand(u) # back to what they were doing

# ------------------------------------------------------------------ burials
var BURY_RANGE: float = float(RULES["burial"]["range"]) # bodies further out than this are lost to the wild after a day
var GRAVE_DIG: float = float(RULES["burial"]["dig"])

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
			if D.in_river(p) or not D.home_side(p) or p.x < 80 or p.y < 80 or p.y > D.H - 80: continue
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
		set_aside(best)
		set_job(best, {"type": "bury", "body_id": b.id, "phase": "fetch", "t": 0.0})
		b.carrier_id = best.id
		popup(best.pos + Vector2(0, -30), tr("%s goes to fetch %s") % [tr(best.name), tr(b.name)], Color("#d8d0e8"))

func _do_bury(u: E.Unit, j: Dictionary, dt: float) -> void:
	var b := unit_by_id(j["body_id"])
	var bg := burial_ground()
	if b == null or b.buried or bg == null:
		end_errand(u)
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
			b.pos = u.pos + Vector2(1, 1) # across the bearer's shoulders (drawn raised; just in front, so it draws over them)
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
				end_errand(u)

## Put the current work aside, to come back to with end_errand(). What was set aside first
## wins (a meal on top of an errand doesn't make the errand forgotten), and idle acts, flights
## and reactions are not worth coming back to. Every interruption goes through here.
func set_aside(u: E.Unit) -> void:
	if not u.resume_job.is_empty() or u.job.is_empty(): return
	if u.job.get("type", "") == "life" or u.job.get("react", false) or u.job.get("flee", false): return
	u.resume_job = u.job
	u.resume_key = u.job_key
	u.resume_t = u.job_t

func end_errand(u: E.Unit) -> void:
	if not u.resume_job.is_empty():
		var rj := u.resume_job
		u.resume_job = {}
		set_job(u, rj, u.resume_key)
		u.job_t = u.resume_t
	else:
		set_job(u, {})

# ------------------------------------------------------------------ night rest
const SHELTERS := ["hut", "large_hut", "granary"] # everything that houses people
var BED_FAR: float = float(RULES["beds"]["far"]) # further than this from a bed, people camp where they are

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
	var nw: Dictionary = react.C.get("night_watch", {})
	if time - flags.get("flood_active", -99.0) < float(nw.get("flood_recent", 20)) or nat.alarm(): return true
	if not active_predators_near(D.VILLAGE, float(nw.get("beasts_at_village", 500))).is_empty(): return true
	for u in units:
		if not u.dead and time - u.last_hit_t < float(nw.get("hit_recent", 4)) and u.attacker_id >= 0: return true
	return false

func _night_watch() -> void:
	var rest := rest_time()
	if rest and not was_rest_time: add_log(tr("Night falls. The tribe lies down to sleep."), "info")
	was_rest_time = rest
	if not rest:
		night_alarm = false
		return
	if _danger_near(): alarm_until = time + float(react.C.get("night_watch", {}).get("alarm", 6))
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
	var duty: bool = jt == "attack" or jt == "bury" or u.job.get("flee", false) or u.job.get("react", false) \
		or (crew and _at_war(u)) or (not crew and not u.job.is_empty() and u.job_t >= night_start())
	if jt == "shelter": return false # (hiding: the reaction keeps them in the hut)
	if not rest_time() or duty:
		if u.sleeping and not duty: life.woke(u) # (dawn: a moment to stretch)
		if u.sleeping or u.bed_pos != null: wake(u)
		return false
	if u.bed_pos == null: pick_bed(u)
	var outdoors: bool = u.bed_id < 0
	if outdoors and D.river_dist(u.bed_pos) < wet_reach() - 10.0: # the water is rising: move the bed out
		u.sleeping = false
		u.bed_pos = dry_spot(u.bed_pos)
	var danger: bool = night_alarm or (outdoors and not active_predators_near(u.pos, float(react.C.get("night_watch", {}).get("outdoor_beasts", 300))).is_empty())
	if u.sleeping:
		if danger and outdoors:
			u.sleeping = false
			u.act = "Keeping watch"
		elif not outdoors:
			u.act = "Sheltering in a hut" if danger else "Sleeping in a hut"
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

func pick_bed(u: E.Unit) -> void:
	var bank := D.region_at(u.pos)
	var near: Vector2 = u.home if D.region_at(u.home) == bank and u.home.distance_to(u.pos) < BED_FAR else u.pos
	var best: E.Structure = null
	for s in structures:
		if not s.built or not ours(s) or not s.type in SHELTERS or D.region_at(s.pos) != bank: continue
		var cap: int = int(D.STRUCTURES[s.type]["cap"])
		var used: int = units.filter(func(o): return not o.dead and o != u and o.bed_id == s.id).size()
		if used >= cap: continue
		if best == null or s.pos.distance_to(near) < best.pos.distance_to(near): best = s # beds at home first
	if best and best.pos.distance_to(u.pos) < BED_FAR:
		u.bed_id = best.id
		u.bed_pos = best.pos + Vector2(0, 6)
		return
	u.bed_id = -1
	var fire := nearest_fire(u.pos)
	if fire and D.region_at(fire.pos) == bank and fire.pos.distance_to(u.pos) < BED_FAR:
		var a := float(u.id) * 2.39996 # golden angle: spread the sleepers round the fire
		u.bed_pos = dry_spot(fire.pos + Vector2(cos(a), sin(a)) * (34.0 + float(u.id % 3) * 12.0))
	else:
		u.bed_pos = dry_spot(u.pos) # camp in the open, but not at the water's edge

## How far from a river's centreline the ground is wet: the river, a margin of bank, and
## the spring flood while it is up.
func wet_reach() -> float:
	return maxf(nat.flood_half(), D.RIVER_HALF) + 40.0

## A spot near p that is out of the water's reach (on the same side of the river), for
## sleeping in the open.
func dry_spot(p: Vector2) -> Vector2:
	var reach := wet_reach()
	var info := D.river_info(p)
	if info["d"] >= reach or info["n"] == Vector2.ZERO: return p
	var out: Vector2 = info["c"] + info["n"] * (reach + 10.0)
	return out if D.region_at(out) == D.region_at(p) else p

func unit_idle(u: E.Unit, dt: float) -> void:
	if life.on and u.role == "" and D.same_side(u.pos, u.home): # (the idle acts of config/life.json)
		life.idle(u, dt)
		return
	u.act = "Resting (sick)" if u.sick > 0 else "Idle"
	if u.has_trait("devout") and u.role != "contract" and D.same_side(u.pos, u.home):
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
	var sv: Dictionary = RULES["survival"]
	var drain: float = float(sv["hunger_rate"]) * (float(sv["gluttonous"]) if u.has_trait("gluttonous") else 1.0) * (float(sv["shared_hearth"]) if evo.has_trad("shared_hearth") else 1.0) * hz.hunger_mult() * inv.mul("hunger")
	u.hunger -= drain * dt * (float(sv["child_hunger"]) if u.role == "child" else 1.0) + u.walked * WALK_HUNGER # long walks to work cost food
	u.walked = 0.0
	if u.hunger < float(sv["eat_below"]) and stock["food"] >= 1:
		stock["food"] -= minf(stock["food"], float(sv["meal"])) # a day's eating is a real cost: winter needs stores
		evo.drift("ranked", -0.15) # meals from the common store
		u.hunger = minf(100, u.hunger + float(sv["meal_fill_fire"] if has_tech("fire") else sv["meal_fill"]))
	if u.hunger <= 0:
		u.hunger = 0
		hurt_unit(u, float(sv["starving_damage"]) * dt, null)
	var warm := near_warmth(u)
	if warm and night_amt > 0.5: evo.practice(u, "hearth", dt)
	var cold := hz.cold_rate(u, warm)
	var hl: Dictionary = RULES["healing"]
	if u.sick > 0:
		if knows_find("willow") and time > u.herb_t and spend({"herbs": 1}):
			u.herb_t = time + float(hl["herb_secs"])
			popup(u.pos + Vector2(0, -30), tr("Willow-bark tea"), Color("#b6f28a"))
		u.sick -= hz.heal_rate(u, warm) * inv.sick_mult() * dt
		if u.sick <= 0:
			u.sick = 0.0
			u.immune_t = time + D.DAY_LEN * 2
			popup(u.pos + Vector2(0, -30), tr("Recovered"), Color("#b6f28a"))
		elif u.hp > u.max_hp * (0.0 if u.hunger < float(hl["fever_hungry"]) or hz.winter() else float(hl["fever_floor"])):
			hurt_unit(u, float(hl["fever"]) * dt, null) # fever
	if cold > 0 and (hz.cold_can_kill() or u.hp > u.max_hp * float(hl["cold_floor"])):
		hurt_unit(u, cold * dt, null)
		if u.hp < u.max_hp * float(hl["freezing_warn"]) and hz.cold_can_kill() and fmod(time, 6.0) < dt:
			popup(u.pos + Vector2(0, -30), tr("Freezing!"), Color("#a8d8ff"))
	elif u.hunger > float(hl["fed_above"]) and u.sick <= 0 and time - u.last_hit_t > float(hl["calm_secs"]):
		if knows_find("yarrow") and u.hp < u.max_hp * float(hl["poultice_below"]) and time > u.salve_t and u.pos.distance_to(D.VILLAGE) < float(hl["poultice_reach"]) and spend({"herbs": 1}):
			u.salve_t = time + float(hl["herb_secs"])
			popup(u.pos + Vector2(0, -30), tr("Yarrow poultice"), Color("#b6f28a"))
		u.hp = minf(u.max_hp, u.hp + float(hl["warm"] if warm else hl["cold"]) * (float(hl["poultice"]) if time < u.salve_t else 1.0) * inv.heal_mult() * dt)

func hurt_unit(u: E.Unit, dmg: float, attacker) -> void:
	if u.dead: return
	u.hp -= dmg
	if attacker:
		u.last_hit_t = time
		u.attacker_id = attacker.id
	if u.hp <= 0: kill_unit(u, attacker)

func kill_unit(u: E.Unit, killer) -> void:
	director.note("death")
	u.dead = true
	u.hp = 0
	u.job = {}
	u.fell_t = time
	wake(u)
	var cause: String = (tr("slain by a %s") % tr(killer.name)) if killer else (cause_hint if cause_hint != "" else tr("lost to hunger and cold"))
	u.death_cause = cause
	folk.on_death()
	life.on_death(u)
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
				remember(u, tr("slew a %s on Day %d") % [tr(p.name), day()], 8)
				add_log(tr("%s slew a %s!") % [tr(u.name), tr(p.name)], "combat", [u])
				life.praise(u, "kill")
				react.trigger("beast_slain", {"at": p.pos, "victim": u})
			evo.drift("martial", 4.0)
		if p.clan != "": rivals.on_rival_killed(p, u)
		else: add_node("carcass", "food", p.pos, 35)
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
		if p.path.is_empty() or not p.homeward:
			p.homeward = true
			set_dest(p, way_out(p.pos))
			if not p.path.is_empty(): p.path[p.path.size() - 1] = way_out(p.pos, 50.0) # off the map edge
		step_move(p, dt, p.spd * 1.1)
		if p.pos.x >= D.W or p.pos.x <= 0 or p.pos.y >= D.H or p.pos.y <= 0 or p.path.is_empty(): p.fled = true
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
		if d < best and D.same_side(u.pos, p.pos) and (p.den == null or p.raid or u.pos.distance_to(p.den) < 380):
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
				react.trigger("attacked", {"victim": prey, "attacker": p, "at": prey.pos})
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
			react.trigger("visitor", {"at": p.pos})
	else:
		p.prowl_t -= dt
		if p.prowl_t <= 0:
			p.prowl_t = randf_range(3, 6)
			var c: Vector2 = p.den if p.den != null else p.pos
			var r := 220.0 if p.den != null else 120.0
			var side := D.region_at(c)
			for k in 4: # somewhere on the same side, clear of the water
				var np := Vector2(clampf(c.x + randf_range(-r, r), 30, D.W - 30), clampf(c.y + randf_range(-r, r), 40, D.H - 40))
				if D.river_dist(np) > D.RIVER_HALF + 80 and D.region_at(np) == side:
					p.path = [np]
					break
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
	story.tick(dt)
	cult.update(dt)
	inv.update(dt)
	var f := day_frac()
	var target := maxf(1.0 if (f > 0.72 and f < 0.97) else 0.0, nat.darkness())
	night_amt += (target - night_amt) * minf(1.0, dt * 0.8)

	var spoil := 0.0025 * (0.5 if has_tech("pottery") else 1.0) * (0.5 if knows_find("salt") else 1.0) * hz.spoil_mult() * inv.spoil_mult()
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
		stock["food"] += sd.get("food", 0.0) * dt * (1.3 if evo.has_trad("harvest_festival") else 1.0) * hz.food_mult(s.type) * nat.food_mult(s) * inv.mul("yield", s.type)
		stock["lore"] += sd.get("lore", 0.0) * dt
	stock["lore"] += (0.03 + inv.lore_rate()) * dt

	var berry_k: float = hz.berry_mult() * nat.grow_mult() * inv.mul("regrow") # (once per tick, not per node)
	var regrow_k: float = inv.mul("regrow")
	_index_nodes()
	_cache_live_t -= dt
	if _cache_live_t <= 0.0: # (a tree that became a stump a moment ago can wait a second to start regrowing)
		_cache_live_t = 1.0
		_cache_live = nodes.filter(func(n): return n.kind != "tree" and n.kind != "boulder")
	for n in _cache_live:
		match n.kind:
			"bush":
				n.amount = minf(n.max_amount, n.amount + n.regrow * dt * berry_k)
			"mushroom", "tubers", "grain", "honey", "fish", "willow", "yarrow", "salt":
				var fd: Dictionary = D.FINDS[n.kind]
				if fd["winter"] or not hz.winter(): n.amount = minf(n.max_amount, n.amount + fd["regrow"] * dt)
			"stump", "burnt":
				n.regrow_t -= dt * regrow_k
				if n.regrow_t <= 0:
					n.kind = "tree"
					n.amount = n.max_amount
			"deer":
				var half: float = nat.flood_half() # (the spring flood swells the river)
				var info: Dictionary = D.river_info(n.pos) if half > D.RIVER_HALF else {}
				var fleeing: bool = not info.is_empty() and info["d"] < half + 15.0
				if fleeing: # the water is rising around it: bound away from the river
					n.vel = info["n"] * 45.0
					n.wander_t = 1.0
				else:
					n.wander_t -= dt
					if n.wander_t <= 0:
						n.wander_t = randf_range(2, 5)
						n.vel = Vector2.from_angle(randf() * TAU) * 14
				var np: Vector2 = n.pos + n.vel * dt
				var dry: bool = fleeing or half <= D.RIVER_HALF or D.river_dist(np) >= half + 15.0
				if dry and not D.in_river(np) and D.region_at(np) == n.bank and np.x > 20 and np.x < D.W - 20 and np.y > 20 and np.y < D.H - 20 and np.distance_to(D.VILLAGE) > (0.0 if fleeing else 150.0):
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
	react.update(dt)
	folk.update(dt)
	life.update(dt)
	rivals.update(dt)
	legacy.update(dt)
	wear_t -= dt
	if wear_t <= 0:
		wear_t = 1.0
		for k in wear.size():
			if wear[k] > 0.0: wear[k] *= 0.996
	_update_vice(dt)
	improve.update(dt)
	policy.update(dt)
	crisis.update(dt)
	director.update(dt)
	roads.update(dt)
	_update_births(dt)

	for p in popups:
		p["t"] += dt
		p["pos"].y -= dt * (14.0 if p["big"] else 22.0)
	popups = popups.filter(func(p): return p["t"] < p["life"])
	if flood_fx > 0: flood_fx = maxf(0, flood_fx - dt * 0.08)
	check_events()

## Every name already given in this game (the living and the dead).
func _names_taken() -> Dictionary:
	var out := {}
	for u in units: out[u.name] = true
	return out

func _update_births(dt: float) -> void:
	var pop := living().size()
	var cb: Dictionary = RULES["births"]
	if pop < pop_cap() and stock["food"] >= float(cb["min_food"]):
		birth_timer += dt
		if birth_timer > float(cb["every"]):
			birth_timer = 0
			stock["food"] -= float(cb["cost"])
			var free: Array = D.BIRTH_NAMES.filter(func(n): return unit_by_name(n) == null)
			var nm: String = free.pick_random() if not free.is_empty() else Names.pick(_names_taken()) # (the culture's names first, then names built from parts)
			var parents: Array = living().filter(func(o): return o.role == "" and o.home.distance_to(D.VILLAGE) < 60)
			var u: E.Unit = folk.make_child(nm, parents.pick_random() if not parents.is_empty() else null)
			remember(u, tr("was born beside the tribal bonfire on Day %d") % day(), 5)
			folk.lift(float(cb["mood"]))
			units.append(u)
			evo.on_birth(u)
			add_log(tr("%s (%s) was born into the tribe.") % [tr(nm), tr(D.TRAITS[u.traits[0]]["name"])], "story", [u])
			popup(u.pos + Vector2(0, -24), tr("%s is born!") % tr(nm), Color("#ffd6f0"), true)
			react.trigger("birth", {"at": u.pos})
	else:
		birth_timer = maxf(0, birth_timer - dt)

# ------------------------------------------------------------------ Tier 3: Vice-Chieftains
## Vice-Chieftain slots: one, and a second with Tribal Code or the Council of Elders (never
## more than there are offices).
func vice_slots() -> int: return mini(vice.size(), 1 + (1 if has_tech("code") else 0) + (1 if evo.has_trad("council_of_elders") else 0))

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
	var old := unit_by_id(vice[role]) # (the one replaced steps down)
	if old and old != u: old.title = ""
	vice[role] = u.id
	u.title = "Steward" if role == "steward" else "War Chief"
	remember(u, tr("was appointed %s of the tribe on Day %d") % [tr(u.title), day()], 7)
	evo.drift("ranked", 8.0)
	add_log(tr("%s appointed as Vice-Chieftain (%s).") % [tr(u.name), tr(u.title)], "vice", [u])
	return true

## What the Steward sends `u` to gather because the tribe is short of it, whatever the
## policy (rules.json vice "wants": res, below, share, when): "" if nothing. Only what
## can be gathered near home now counts (the tools for stone, a known find for herbs and ore).
func _steward_want(u: E.Unit) -> String:
	for w in RULES["vice"].get("wants", []):
		var res: String = str(w.get("res", ""))
		if res == "" or stock.get(res, 0.0) >= float(w.get("below", 0)) or not story.holds(w.get("when", {})): continue
		if randf() >= float(w.get("share", 0.0)): continue
		if find_node(res, u.home, D.region_at(u.home), float(RULES["vice"].get("want_reach", 900))) != null: return res
	return ""

## Relieve the holder of a Vice-Chieftain role, freeing the slot. Returns false if nobody holds it.
func dismiss(role: String) -> bool:
	var u := unit_by_id(vice.get(role, -1))
	if not vice.has(role) or vice[role] < 0: return false
	vice[role] = -1
	if u == null: return true
	u.title = ""
	add_log(tr("%s steps down as Vice-Chieftain.") % tr(u.name), "vice", [u])
	return true

## Free for other work: no job, or only an idle act of everyday life (life.gd).
func is_idle(u: E.Unit) -> bool: return u.job.is_empty() or u.job.get("type", "") == "life"

## Every job type update_unit() runs (a job of any other type would silently do nothing).
const JOB_TYPES := ["move", "gather", "bury", "tend", "cover", "aid", "warm", "shelter", "firefight", "look", "startle",
	"life", "meal", "depart", "art", "trade_trip", "build", "seek", "attack", "envoy", "experiment", "explore", "ritual"]

## What must always hold in a running game; returns the broken rules ([] when all is well).
## Tests call it after ticking; a game master can call it to sanity-check the world.
func check_invariants() -> Array:
	var bad: Array = []
	for k in stock:
		if is_nan(float(stock[k])) or float(stock[k]) < -0.01: bad.append("stock %s is %s" % [k, str(stock[k])])
	var ids := {}
	for u in units:
		if ids.has(u.id): bad.append("two units share id %d" % u.id)
		ids[u.id] = true
		if u.dead: continue
		for j in [u.job, u.resume_job]:
			if not j.is_empty() and not j.get("type", "") in JOB_TYPES: bad.append("%s has a job of unknown type %s" % [u.name, str(j.get("type"))])
		if u.hp > u.max_hp + 0.01 or is_nan(u.hp): bad.append("%s has hp %.1f of %.1f" % [u.name, u.hp, u.max_hp])
		if u.morale < -0.01 or u.morale > 100.01: bad.append("%s has morale %.1f" % [u.name, u.morale])
		if u.fatigue < -0.01 or u.fatigue > 100.01: bad.append("%s has fatigue %.1f" % [u.name, u.fatigue])
		if u.role == "contract" and contracts.by_id(u.contract_id) == null: bad.append("%s is on missing contract %d" % [u.name, u.contract_id])
		var role := "steward" if u.title == "Steward" else ("warchief" if u.title == "War Chief" else "")
		if u.title != "" and (role == "" or vice[role] != u.id): bad.append("%s is titled %s but holds no such office" % [u.name, u.title])
	for role in vice:
		if vice[role] < 0: continue
		var h := unit_by_id(vice[role])
		if h == null or h.dead: bad.append("the %s office is held by a missing or dead person" % role)
		elif h.title != ("Steward" if role == "steward" else "War Chief"): bad.append("%s holds %s but is titled '%s'" % [h.name, role, h.title])
	return bad

func _update_vice(dt: float) -> void:
	vice_timer -= dt
	if vice_timer > 0: return
	var vc: Dictionary = RULES["vice"]
	vice_timer = float(vc["every"])
	var steward := unit_by_id(vice["steward"])
	if steward and not steward.dead and not rest_time(): # no work handed out at night
		var idle := living().filter(func(u): return is_idle(u) and u.role == "" and u.id != steward.id and u.pos.distance_to(u.home) < float(vc["steward_reach"]))
		var pop := living().size()
		for u in idle:
			var unbuilt = null
			var settler: bool = u.home.distance_to(D.VILLAGE) > 50
			for s in structures: # a site near home: the village's new buildings, or any old home being renovated
				if s.paid and ((not s.built and s.owner == "village" and not settler) or (s.reno and ours(s) and settlement_of(s.pos) == settlement_of(u.home))):
					unbuilt = s
					break
			var choice: String
			var sw: Dictionary = vc["steward"]
			var want := _steward_want(u) if stock["food"] >= pop * float(sw["food_per_head"]) and steward_policy != "lore" else "" # (short of stone, herbs, ore...)
			if unbuilt and randf() < float(sw["build_chance"]): choice = "build"
			elif stock["food"] >= pop * float(sw["food_per_head_art"]) and stock["wood"] >= float(sw["art_wood"]) and randf() < float(sw["art_chance"]): choice = "art" # (stores are healthy: time for crafts)
			elif want != "": choice = want
			elif stock["food"] >= food_cap() * float(sw["full"]) and steward_policy != "lore": choice = "wood" # the stores are full
			elif stock["food"] < pop * float(sw["food_per_head"]) or steward_policy == "food": choice = "food"
			elif steward_policy == "wood" or stock["wood"] < float(sw["low_wood"]): choice = "wood"
			elif steward_policy == "lore": choice = "lore"
			elif steward_policy == "stone" and has_tech("tools"): choice = "stone"
			else: choice = "food" if randf() < 0.5 else "wood"
			match choice:
				"build": assign_build(u, unbuilt)
				"lore": assign_ritual(u, u.home + Vector2(randf_range(-60, 60), -randf_range(30, 70)))
				"art": folk.start_art(u)
				_: assign_gather(u, choice, {"bank": D.region_at(u.home), "area": u.home, "area_r": float(sw["area_r"])})
			gain_xp(steward, "lore", float(sw["xp"]))
			evo.practice(steward, "lead", float(sw["practice"]))
		if not idle.is_empty():
			add_log(tr("Steward %s put %d idle hands to work (%s).") % [tr(steward.name), idle.size(), tr(steward_policy)], "vice", [steward])
	var chief := unit_by_id(vice["warchief"])
	if chief and not chief.dead:
		var threats := active_predators_near(D.VILLAGE, float(vc["warchief_range"]))
		if not threats.is_empty():
			threats.sort_custom(func(a, b): return a.pos.distance_to(D.VILLAGE) < b.pos.distance_to(D.VILLAGE))
			var foe = threats[0]
			# keep `fighters` on it (topped up, not sent again and again): the best fighters nearby
			var on_it := living().filter(func(u): return u.job.get("type", "") == "attack" and u.job.get("target_id", -1) == foe.id).size()
			var need := int(vc["fighters"]) - on_it
			if need > 0:
				var fighters := living().filter(func(u): return u.role == "" and u.job.get("type", "") != "attack" and not in_hut(u) and u.sick <= 0.0 \
					and u.hp >= u.max_hp * float(vc["min_hp"]) and u.pos.distance_to(foe.pos) < float(vc["reach"]) and D.same_side(u.pos, foe.pos))
				fighters.sort_custom(func(a, b): return a.lv("combat") > b.lv("combat"))
				for u in fighters.slice(0, need):
					set_aside(u) # (back to work once the beast is dealt with)
					assign_attack(u, foe, u.job_key)
				if not fighters.is_empty(): add_log(tr("War Chief %s rallies warriors against the beast!") % tr(chief.name), "vice", [chief])

# ------------------------------------------------------------------ village building (Tier 1)
func can_place(type: String, p: Vector2, size := 0.0) -> String:
	var sd: Dictionary = D.STRUCTURES[type]
	var cost := place_cost(type, size)
	if sd.has("tech") and not has_tech(sd["tech"]): return "Requires tech"
	if stock["wood"] < cost["wood"]: return "Not enough wood"
	if stock["stone"] < cost["stone"]: return "Not enough stone"
	if D.river_dist(p) < D.RIVER_HALF + 15: return "Too close to the river"
	if not sd.get("ring", false) and type != "roadworks": # footprints may not overlap (walls ring around them)
		var r: float = float(sd["r"])
		for o in structures:
			if o.type == "roadworks" or D.STRUCTURES[o.type].get("ring", false): continue
			if o.pos.distance_to(p) < r + struct_r(o) - 4.0: return "Too close to another building"
	return ""

## Whether the stores hold `cost` ({resource: amount}).
func can_afford(cost: Dictionary) -> bool:
	for r in cost:
		if float(stock.get(r, 0.0)) < float(cost[r]): return false
	return true

## Pay `cost` from the stores, all or nothing: false (and nothing taken) if it can't be paid.
## Every price the tribe pays goes through here, so check-then-pay can't drift apart.
func spend(cost: Dictionary) -> bool:
	for r in cost: assert(stock.has(r), "spend: '%s' is not a resource" % r)
	if not can_afford(cost): return false
	for r in cost: stock[r] = float(stock.get(r, 0.0)) - float(cost[r])
	return true

## Lay out a building site (`size`: a wall's radius, 0 = the default one).
func place_structure(type: String, p: Vector2, size := 0.0) -> E.Structure:
	if can_place(type, p, size) != "": return null
	var cost := place_cost(type, size)
	if not spend({"wood": cost["wood"], "stone": cost["stone"]}): return null
	var s := add_structure(type, p, false, "village", true)
	if D.STRUCTURES[type].get("ring", false):
		s.size = ring_radius(type, size)
		s.work = cost["work"]
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
	if not spend({"lore": cost}): return "Not enough lore"
	evo.breakthrough(tech_id, best_unit("lore", false), "taught")
	return ""

## Bring every outdated home and wall up to the current era's style.
func outdated() -> Array:
	return structures.filter(func(s): return s.built and not s.reno and ours(s) and s.type in D.STYLED and s.style < evo.era) # (settlements too)

var BLD: Dictionary = RULES["buildings"] # one building at a time: renovate, upgrade, demolish

func reno_cost(list: Array) -> Dictionary:
	var w := 0
	var st := 0
	for s in list:
		w += ceili(place_cost(s.type, s.size)["wood"] * float(BLD["renovate_wood"]))
		if evo.era >= 3: st += int(BLD["stone_era3"])
	return {"wood": w, "stone": st}

## Work it takes to finish a renovation or an upgrade.
func reno_need(s: E.Structure) -> float:
	if s.upgrade != "": return float(D.STRUCTURES[s.upgrade]["work"]) * float(BLD["upgrade_work"])
	return s.work * float(BLD["renovate_work"])

## What a building can be made into: [{to, wood, stone, why}] ("why" = "" when it can be done now).
func upgrades_for(s: E.Structure) -> Array:
	var out: Array = []
	for o in BLD["upgrades"].get(s.type, []):
		var to: String = o.get("to", "")
		if not D.STRUCTURES.has(to): continue
		var a: Dictionary = D.STRUCTURES[s.type]
		var b: Dictionary = D.STRUCTURES[to]
		var k := float(BLD.get("upgrade_cost", 1.0))
		var w := maxi(int(BLD.get("min_wood", 0)), ceili((b["wood"] - a["wood"]) * k))
		var st := maxi(0, ceili((b.get("stone", 0) - a.get("stone", 0)) * k))
		var why := ""
		if b.has("tech") and not has_tech(b["tech"]): why = tr("Requires %s") % tr(evo.tech_def(b["tech"])["name"])
		elif not s.built or s.reno: why = tr("Busy")
		elif stock["wood"] < w or stock["stone"] < st: why = tr("Needs %d wood and %d stone") % [w, st] if st > 0 else tr("Needs %d wood") % w
		out.append({"to": to, "wood": w, "stone": st, "why": why})
	return out

## Rebuild one building into structure type `to` (an upgrade path in config). Returns "" or why not.
func upgrade(id: int, to: String, helpers: Array = []) -> String:
	var s := struct_by_id(id)
	if s == null or not ours(s): return tr("No such building")
	for o in upgrades_for(s):
		if o["to"] != to: continue
		if o["why"] != "": return o["why"]
		if not spend({"wood": o["wood"], "stone": o["stone"]}): return tr("Not enough wood")
		s.reno = true
		s.reno_progress = 0.0
		s.upgrade = to
		_send_renovators([s], helpers)
		add_log(tr("Work begins to make the %s into a %s.") % [tr(D.STRUCTURES[s.type]["name"]), tr(D.STRUCTURES[to]["name"])], "build")
		return ""
	return tr("It can't become that")

## Rebuild one old building in the current era's style. Returns "" or why not.
func renovate_one(id: int, helpers: Array = []) -> String:
	var s := struct_by_id(id)
	if s == null or not s in outdated(): return tr("Nothing to renovate")
	var cost := reno_cost([s])
	if not spend(cost):
		return tr("Needs %d wood and %d stone") % [cost["wood"], cost["stone"]] if cost["stone"] > 0 else tr("Needs %d wood") % cost["wood"]
	s.reno = true
	s.reno_progress = 0.0
	_send_renovators([s], helpers)
	return ""

## Why a building can't be pulled down ("" = it can).
func demolish_block(s: E.Structure) -> String:
	if s == null or not ours(s): return tr("No such building")
	if s.type in BLD["demolish"].get("never", []): return tr("The tribe will not pull this down")
	return ""

## Pull a building down (a building site is cancelled): part of its wood and stone back.
func demolish(id: int) -> String:
	var s := struct_by_id(id)
	var why := demolish_block(s)
	if why != "": return why
	var sd: Dictionary = D.STRUCTURES[s.type]
	var k := float(BLD["demolish"].get("refund", 0.5)) if s.built else (1.0 if s.paid and s.progress <= 0.0 else float(BLD["demolish"].get("refund", 0.5)))
	if s.paid:
		var pc := place_cost(s.type, s.size)
		stock["wood"] += floorf(pc["wood"] * k)
		stock["stone"] += floorf(pc["stone"] * k)
	for u in units:
		if u.bed_id == s.id:
			u.bed_id = -1
			u.bed_pos = null
		if u.job.get("struct_id", -1) == s.id: set_job(u, {})
	if s.type == "aurochs_pen": oxen = mini(oxen, OX_PER_PEN * maxi(0, structures.filter(func(o): return o != s and o.built and ours(o) and o.type == "aurochs_pen").size()))
	structures.erase(s)
	add_log(tr("The %s is pulled down.") % tr(sd["name"]), "build")
	return ""

func renovate(helpers: Array) -> String:
	var list := outdated()
	if list.is_empty(): return tr("Nothing to renovate")
	var cost := reno_cost(list)
	if not spend(cost):
		return tr("Needs %d wood and %d stone") % [cost["wood"], cost["stone"]] if cost["stone"] > 0 else tr("Needs %d wood") % cost["wood"]
	for s in list:
		s.reno = true
		s.reno_progress = 0.0
	_send_renovators(list, helpers)
	add_log(tr("The tribe rebuilds %d homes and walls in the style of the %s.") % [list.size(), tr(D.ERA_NAMES[evo.era])], "build")
	return ""

## Send people to rebuild `list`: the chieftain's picks, else each settlement's own free hands.
func _send_renovators(list: Array, helpers: Array) -> void:
	if not helpers.is_empty(): # (the people the chieftain picked)
		var i := 0
		for u in helpers:
			assign_build(u, list[i % list.size()])
			i += 1
	else: # each settlement's own free hands rebuild its homes
		var taken := {}
		for p in settlements():
			var here: Array = list.filter(func(s): return settlement_of(s.pos) == p)
			if here.is_empty(): continue
			var free: Array = living().filter(func(u): return u.role == "" and not taken.has(u.id) and u.job.get("type", "") in ["", "ritual"] and D.region_at(u.home) == D.region_at(p))
			free.sort_custom(func(a, b): return a.home.distance_to(p) < b.home.distance_to(p))
			var crew: Array = free.filter(func(u): return u.home.distance_to(p) < 450).slice(0, 3)
			if crew.is_empty(): crew = free.slice(0, 1)
			var i := 0
			for u in crew:
				taken[u.id] = true
				assign_build(u, here[i % here.size()])
				i += 1

func finish_reno(s: E.Structure, u: E.Unit) -> void:
	s.reno = false
	s.style = evo.era
	if s.upgrade != "": # it becomes the new building, with everything that brings
		s.type = s.upgrade
		s.upgrade = ""
		s.work = D.STRUCTURES[s.type]["work"]
		complete_structure(s, u)
	else: popup(s.pos + Vector2(0, -30), tr("Renovated"), Color("#b6f28a"))
	gain_xp(u, "craft", 4)
	var next: E.Structure = null # the nearest old home still waiting in this settlement
	for o in structures:
		if o.reno and ours(o) and not _reno_taken(o) and settlement_of(o.pos) == settlement_of(s.pos) and (next == null or o.pos.distance_to(u.pos) < next.pos.distance_to(u.pos)): next = o
	if next == null:
		for o in structures:
			if o.reno and ours(o) and settlement_of(o.pos) == settlement_of(s.pos): next = o
	if next: assign_build(u, next)

## The settlement (from settlements()) a point belongs to: the nearest one.
func settlement_of(p: Vector2) -> Vector2:
	var best: Vector2 = D.VILLAGE
	for q in settlements():
		if q.distance_to(p) < best.distance_to(p): best = q
	return best

func _reno_taken(s: E.Structure) -> bool:
	return living().any(func(w): return w.job.get("type", "") == "build" and w.job.get("struct_id", -1) == s.id)

# ------------------------------------------------------------------ milestone events
func check_events() -> void:
	if pending_event != "": return
	if legacy.pending != "": # endings come first
		_fire_event(legacy.pending)
		return
	if not story.pending.is_empty(): # the scenario's scripted events
		_fire_event(story.pending.pop_front())
	elif not cult.pending.is_empty(): # the culture's dilemmas
		_fire_event(cult.pending.pop_front())
	elif not flags.has("overpop") and story.holds(RULES["triggers"]["overpop"]):
		flags["overpop"] = true
		_fire_event("overpop")
	elif evo.pending_era > 1 and not flags.has("era%d" % evo.pending_era):
		flags["era%d" % evo.pending_era] = true
		_fire_event("era%d" % evo.pending_era)
		evo.pending_era = 0
	elif not flags.has("chosen") and story.holds(RULES["triggers"]["chosen"]):
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
	elif life.pending != "": # a family in despair wants to leave
		var le: String = life.pending
		life.pending = ""
		_fire_event(le)

var steward_routine := true # the Steward decides routine matters (dilemmas with "routine"); a player setting

func _fire_event(id: String) -> void:
	cult.on_event(id)
	if _decide_routine(id): return
	pending_event = id
	paused = true
	event_fired.emit(id)

## A routine dilemma (config "routine": {"prefer": [option indexes]}) is the Steward's to
## decide when one is appointed: the first preferred option that can be chosen, reported in
## the chronicle and as a notice instead of asked. Returns true if it was decided.
func _decide_routine(id: String) -> bool:
	if not steward_routine or not DILEMMAS.has(id) or not DILEMMAS[id].has("routine"): return false
	var st := unit_by_id(vice["steward"])
	if st == null or st.dead: return false
	var view: Dictionary = event_def(id)
	for idx in DILEMMAS[id]["routine"].get("prefer", []):
		var i := int(idx)
		if i < 0 or i >= view.get("options", []).size() or not view["options"][i].get("enabled", true): continue
		var label: String = view["options"][i]["label"]
		pending_event = id
		resolve_event(id, i)
		add_log(tr("Steward %s decided the routine matter of %s: %s.") % [tr(st.name), view.get("title", id), label], "vice", [st])
		alert(tr("Steward %s decided: %s") % [tr(st.name), label], D.VILLAGE, "info", [st])
		return true
	return false

func flood_strike() -> void:
	cult.on_event("great_flood")
	flood_fx = 1.0
	var lost := floori(stock["food"] * 0.5)
	stock["food"] -= lost
	var hurt := 0
	for u in living():
		if D.river_dist(u.pos) < 260:
			hurt_unit(u, u.max_hp * 0.25, null)
			hurt += 1
			remember(u, tr("survived the Great Flood on Day %d") % day(), 7)
	for s in structures:
		if ours(s) and s.built and s.type != "palisade" and D.river_dist(s.pos) < 220:
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
	if life.owns_event(id): return life.event_def(id)
	if cult.owns_event(id): return cult.event_def(id)
	if story.owns_event(id): return story.event_def(id)
	if DILEMMAS.has(id): return story.dilemma_view(DILEMMAS[id], _dilemma_vars(id))
	return {}

## The chieftain's dilemmas from config/dilemmas.json (flood, overpop, chosen, era2, era3;
## folk and rivals read theirs too).
var DILEMMAS: Dictionary = preload("res://scripts/config.gd").load_cfg("dilemmas")

## The named values a built-in dilemma's texts use.
func _dilemma_vars(id: String) -> Dictionary:
	var v := {}
	if id in ["era2", "era3"]:
		v["era"] = tr(D.ERA_NAMES[evo.era])
		var voices: Array = []
		var seen := {}
		for u in living():
			var a := arch(u)
			if seen.has(a) or not DILEMMAS[id]["voices"].has(a): continue
			seen[a] = true
			voices.append("%s: %s" % [tr(u.name), tr(DILEMMAS[id]["voices"][a])])
			if voices.size() >= 3: break
		v["voices"] = "  ".join(voices)
	return v

## A Chosen One of bloodline i (D.CHOSEN) is born: the "chosen" action.
func birth_chosen(i: int) -> Dictionary:
	var def: Dictionary = D.CHOSEN[clampi(i, 0, D.CHOSEN.size() - 1)].duplicate(true)
	def["hero"] = true
	cult.on_chosen(def)
	var u := make_unit(def, D.VILLAGE + Vector2(0, 40))
	remember(u, tr("was born under a lightning sky, bearing a mythic bloodline"), 10)
	units.append(u)
	evo.on_birth(u)
	popup(u.pos + Vector2(0, -30), tr("%s is born!") % tr(def["name"]), Color("#ffd36b"), true)
	return {"chosen_name": tr(def["name"]), "chosen_epithet": tr(def["epithet"])}

## Returns {"text": outcome, "open_contract": bool}
func resolve_event(id: String, idx: int) -> Dictionary:
	pending_event = ""
	if rivals.owns_event(id):
		var txt: String = rivals.resolve(id, idx)
		var ow: String = flags.get("open_war", "")
		flags.erase("open_war")
		return {"text": txt, "open_contract": false, "open_war": ow}
	if nat.owns_event(id): return {"text": nat.resolve(id, idx), "open_contract": false}
	if folk.owns_event(id):
		var ft: String = folk.resolve(id, idx)
		cult.festival() # a tale saved for feasts
		return {"text": ft, "open_contract": false}
	if life.owns_event(id):
		var lt: String = life.resolve(id, idx)
		add_log(lt, "story")
		return {"text": lt, "open_contract": false}
	if cult.owns_event(id):
		var ct: String = cult.resolve(id, idx)
		add_log(ct, "story")
		return {"text": ct, "open_contract": false}
	if story.owns_event(id):
		var st: String = story.resolve(id, idx)
		add_log(st, "story")
		return {"text": st, "open_contract": false}
	if legacy.owns_event(id):
		var lr: Dictionary = legacy.resolve(id, idx)
		return {"text": lr["text"], "open_contract": false, "restart": lr["restart"]}
	var out := {"text": "", "open_contract": false}
	if DILEMMAS.has(id):
		var r: Dictionary = story.dilemma_choose(DILEMMAS[id], idx, _dilemma_vars(id))
		out["text"] = r["text"]
		out["open_contract"] = r["vars"].get("open", "") == "contract"
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
	return (D.SIGHT_UNIT + 12.0 * u.lv("forage") + (D.SIGHT_SCOUT_BONUS if u.job.get("type", "") == "explore" else 0.0) + (40.0 if evo.has_trad("wayfinders") else 0.0) + inv.add("sight")) * hz.sight_mult() * nat.sight_mult()

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
	inv.feat("landmark", tr("Discovered %s") % tr(lm["name"]), finder,
		{"desc": (tr("%s %s.") % [tr(finder.name), tr(lm["text"])]) if finder else "", "at": lm["pos"]})
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

## The nearest point on the map edge (where beasts leave), `out` beyond it (or inside if < 0).
func way_out(p: Vector2, out := -10.0) -> Vector2:
	var best := Vector2(-out, p.y)
	var d := p.x
	if D.W - p.x < d:
		d = D.W - p.x
		best = Vector2(D.W + out, p.y)
	if p.y < d:
		d = p.y
		best = Vector2(p.x, -out)
	if D.H - p.y < d:
		best = Vector2(p.x, D.H + out)
	return best

## Nearest unexplored land cell, preferring the scout's own side of the water (crossing costs a detour)
## and steering clear of known saber-tooth dens.
func explore_target(u: E.Unit) -> Variant:
	var best: Variant = null
	var best_score := INF
	var my_side := D.region_at(u.pos)
	var cross := {} # region -> extra walk to get there over a ford
	for f in D.FORDS:
		for e in [["a", "ra", "b", "rb"], ["b", "rb", "a", "ra"]]:
			if f[e[1]] != my_side: continue
			var extra: float = u.pos.distance_to(f[e[0]]) + 300.0
			if extra < cross.get(f[e[3]], INF): cross[f[e[3]]] = extra
	var dens: Array = landmarks.filter(func(l): return l["found"] and l["kind"] == "den").map(func(l): return l["pos"])
	for j in fog_h:
		for i in fog_w:
			if explored[j * fog_w + i] == 1: continue
			var c := _cell_center(i, j)
			if D.in_river(c): continue
			var score: float = c.distance_to(u.pos)
			var side := D.region_at(c)
			if side != my_side: score += cross.get(side, 4000.0)
			for dp in dens:
				if c.distance_to(dp) < 450: score += 2500.0
			if score < best_score:
				best_score = score
				best = c
	return best
