## The great forces of nature: lightning, wildfire, river floods, the Fire Mountain,
## eclipses and earthquakes. Owned by the simulation like `hz` (hazards.gd) and ticked
## with it; pure rules, no rendering (world_view reads the state to draw bolts, flames,
## ash, a swollen river and a shaking camera).
##
## Lightning   - strikes during thunderstorms: splits trees (and can start a wildfire),
##               sets a building on fire, or rarely hits someone in the open. Before
##               Friction Fire is known, it can give the tribe its first fire.
## Wildfire    - spreads from tree to tree (faster in drought, slower in rain); burns people
##               and buildings in its path; berries sprout in the ashes afterwards.
## River flood - in spring the river can rise after a warning: people near the banks run for
##               high ground, riverside buildings are damaged; the silt feeds the fields.
## Fire Mountain - a volcano (D.VOLCANO) erupts every 9-14 days after tremors: lava
##               burns the land around it, ash darkens the sky for most of a day (slower
##               growth, shorter sight, more fever); obsidian is left on its slopes and the
##               ash makes the fields rich for days.
## Eclipse     - the sun is devoured at midday: the chieftain decides how the tribe meets it.
## Earthquake  - buildings collapse (and must be rebuilt); a rockslide uncovers new stone.
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")

const LAVA_R := 460.0
const ECLIPSE_LEN := 30.0

var sim
var pending := "" # an event for the chieftain ("eclipse")
# lightning
var strike_t := 6.0
var strikes: Array = [] # [{pos, t}] for the bolt and flash on screen
var sky_fire_given := false
# wildfire
var burning := {} # tree node id -> seconds left
var spread_t := 0.0
var burn_tick := 0.0
var fire_size := 0
var scorched := {} # structure ids already burned by this fire
# river flood
var flood_day := -1
var flood_at := -1.0
var flood_warned := false
var flood_left := 0.0
var silt_until := -1.0
# Fire Mountain
var erupt_at := 0.0
var tremor_warned := false
var erupt_left := 0.0
var ash := 0.0
var ash_until := -1.0
var fertile_until := -1.0
# eclipse
var eclipse_at := 0.0
var eclipse_t := -1.0
var eclipse_asked := false
var panic_until := -1.0
# earthquake
var quake_at := 0.0
var shake := 0.0

func _init(s) -> void:
	sim = s
	erupt_at = D.DAY_LEN * randf_range(7.0, 10.0)
	eclipse_at = _midday(D.DAY_LEN * randf_range(5.0, 9.0))
	quake_at = D.DAY_LEN * randf_range(9.0, 14.0)

func _midday(t: float) -> float:
	return floorf(t / D.DAY_LEN) * D.DAY_LEN + D.DAY_LEN * randf_range(0.3, 0.45)

func on() -> bool: return sim.hz.on()

# ------------------------------------------------------------ queries used by the sim
## 0..1 extra darkness (eclipse; a little under thick ash).
func darkness() -> float:
	var d := ash * 0.3
	if eclipse_t >= 0:
		d = maxf(d, clampf(minf(eclipse_t / 5.0, (ECLIPSE_LEN - eclipse_t) / 5.0), 0.0, 1.0))
	return d

## Growth of berries and crops (ash smothers them).
func grow_mult() -> float: return 1.0 - 0.5 * ash

## Food from a building: rich silt by the river after a flood, fertile ash after an eruption.
func food_mult(s: E.Structure) -> float:
	var m := grow_mult()
	if s.type == "farm_plot":
		if sim.time < silt_until and D.river_dist(s.pos) < 500: m *= 1.4
		if sim.time < fertile_until and ash < 0.2: m *= 1.3
	return m

func sight_mult() -> float: return 1.0 - 0.3 * ash
func sick_risk() -> float: return 0.08 * ash
func panicking() -> bool: return sim.time < panic_until
func flooding() -> bool: return flood_left > 0.0

## Something that should wake the sleeping camp.
func alarm() -> bool:
	if flood_left > 0 or (flood_at > 0 and sim.time >= flood_at - 15.0): return true
	if erupt_left > 0 or shake > 0.5: return true
	for id in burning:
		var n = sim.node_by_id(id)
		if n and n.pos.distance_to(D.VILLAGE) < 650: return true
	return false

## For the top bar and the LLM prompts.
func status() -> Array:
	var out: Array = []
	if eclipse_t >= 0: out.append(tr("Eclipse"))
	if flood_left > 0: out.append(tr("River in flood"))
	elif flood_at > 0 and sim.time >= flood_at - 15.0: out.append(tr("River rising"))
	if erupt_left > 0: out.append(tr("Eruption"))
	if ash > 0.15: out.append(tr("Ashfall"))
	if not burning.is_empty(): out.append(tr("Wildfire"))
	return out

# ------------------------------------------------------------ tick
func update(dt: float) -> void:
	shake = maxf(0.0, shake - dt)
	for s in strikes: s["t"] += dt
	strikes = strikes.filter(func(s): return s["t"] < 0.7)
	_fire_tick(dt) # a fire already burning goes on even if the challenges are switched off
	_ash_tick(dt)
	if eclipse_t >= 0: _eclipse_tick(dt)
	if not on(): return
	if sim.hz.weather == "storm":
		strike_t -= dt
		if strike_t <= 0:
			strike_t = randf_range(10.0, 22.0)
			strike()
	_flood_tick(dt)
	_volcano_tick(dt)
	if eclipse_t < 0 and sim.time >= eclipse_at and not sim.rest_time(): _start_eclipse()
	if sim.time >= quake_at:
		quake_at = sim.time + D.DAY_LEN * randf_range(10.0, 16.0)
		if erupt_left <= 0: quake()

## Mark a natural disaster for Task Contracts working within `r` of `at` (r < 0: everywhere).
func _disaster(kind: String, at: Vector2, r: float) -> void:
	for c in sim.contracts.list:
		if sim.contracts.is_running(c) and (r < 0 or c.site.distance_to(at) < r):
			sim.flags["disaster_t"] = sim.time
			sim.flags["disaster"] = kind
			return

func _hurt(u: E.Unit, dmg: float, cause: String) -> void:
	sim.cause_hint = cause
	sim.hurt_unit(u, dmg, null)
	sim.cause_hint = ""

func _in_shelter(u: E.Unit) -> bool:
	if sim.in_hut(u): return true
	for s in sim.structures:
		if s.built and sim.ours(s) and s.pos.distance_to(u.pos) < 150: return true
	return false

# ------------------------------------------------------------ lightning
func strike() -> void:
	var r := randf()
	var at := Vector2.ZERO
	if r < 0.12:
		var open: Array = sim.living().filter(func(u): return not _in_shelter(u))
		if not open.is_empty():
			var u: E.Unit = open.pick_random()
			at = u.pos
			_flash(at)
			_hit_person(u)
			return
	if r < 0.3:
		var targets: Array = sim.structures.filter(func(s): return s.built and sim.ours(s) and s.type in ["hut", "large_hut", "granary", "totem_shrine", "weapon_rack", "aurochs_pen", "council_ring", "smelter"])
		if not targets.is_empty():
			var s: E.Structure = targets.pick_random()
			_flash(s.pos)
			s.built = false
			s.progress = s.work * 0.5
			sim.alert(tr("Lightning sets the %s on fire! It must be rebuilt.") % tr(D.STRUCTURES[s.type]["name"]), s.pos, "danger")
			_sky_fire(s.pos)
			return
	var trees: Array = sim.nodes.filter(func(n): return n.kind == "tree" and (n.pos.distance_to(D.VILLAGE) < 1000 or sim.living().any(func(u): return u.pos.distance_to(n.pos) < 500)))
	if trees.is_empty(): return
	var n = trees.pick_random()
	_flash(n.pos)
	var dry: bool = sim.hz.weather == "drought" or sim.hz.season_idx() == 1
	if randf() < (0.6 if dry else 0.25):
		ignite(n)
	else:
		n.kind = "stump"
		n.regrow_t = 200
		sim.popup(n.pos + Vector2(0, -40), tr("Lightning!"), Color("#fff6a0"), true)
	_sky_fire(n.pos)

func _flash(at: Vector2) -> void:
	strikes.append({"pos": at, "t": 0.0})
	sim.devotion = minf(100.0, sim.devotion + 2)

func _hit_person(u: E.Unit) -> void:
	sim.cult.on_event("lightning")
	_hurt(u, u.max_hp * 0.6, tr("struck by lightning"))
	if u.dead: return
	sim.popup(u.pos + Vector2(0, -36), tr("Struck by lightning!"), Color("#fff6a0"), true)
	sim.alert(tr("Lightning strikes %s - and they live! The sky has touched them.") % tr(u.name), u.pos, "warn", [u])
	sim.remember(u, tr("was struck by lightning on Day %d and lived - touched by the sky") % sim.day(), 9)
	sim.gain_xp(u, "lore", 20)

## Before the tribe can make fire, a strike near people hands it to them.
func _sky_fire(at: Vector2) -> void:
	if sky_fire_given or sim.has_tech("fire"): return
	var best: E.Unit = null
	for u in sim.living():
		if u.pos.distance_to(at) < 600 and (best == null or u.pos.distance_to(at) < best.pos.distance_to(at)): best = u
	if best == null: return
	sky_fire_given = true
	sim.evo.seed("fire", 0.5, best)
	sim.add_log(tr("Fire from the sky! %s carries a burning branch home. The tribe has seen how fire lives.") % tr(best.name), "tech", [best])
	sim.remember(best, tr("carried fire from a lightning-struck tree on Day %d") % sim.day(), 8)

# ------------------------------------------------------------ wildfire
func ignite(n) -> void:
	sim.cult.on_event("wildfire")
	if n == null or n.kind != "tree" or burning.has(n.id): return
	if burning.is_empty():
		fire_size = 0
		scorched.clear()
		sim.alert(tr("Wildfire! The forest is burning."), n.pos, "danger")
		_disaster("wildfire", n.pos, 600.0)
	burning[n.id] = 12.0
	fire_size += 1

func _fire_tick(dt: float) -> void:
	if burning.is_empty(): return
	var wet: bool = sim.hz.weather in ["rain", "storm", "blizzard"]
	for id in burning.keys():
		burning[id] -= dt * (1.8 if wet else 1.0)
		if burning[id] <= 0:
			burning.erase(id)
			var n = sim.node_by_id(id)
			if n:
				n.kind = "burnt"
				n.regrow_t = 420
				if randf() < 0.25: # berries sprout in the ashes
					var b = sim._node("bush", "food", n.pos + Vector2(randf_range(-20, 20), randf_range(-14, 14)), 30)
					b.amount = 0.0
					b.regrow = 0.14
	spread_t -= dt
	if spread_t <= 0 and fire_size < 70:
		spread_t = 2.0
		var p := 0.35 * (1.6 if sim.hz.weather == "drought" else 1.0) * (0.3 if wet or sim.hz.winter() else 1.0)
		for id in burning.keys():
			if burning[id] > 9.0: continue # just caught
			var src = sim.node_by_id(id)
			if src == null: continue
			for o in sim.nodes:
				if o.kind == "tree" and not burning.has(o.id) and o.pos.distance_to(src.pos) < 75 and randf() < p: ignite(o)
	burn_tick -= dt
	if burn_tick <= 0:
		burn_tick = 1.0
		for id in burning:
			var n = sim.node_by_id(id)
			if n == null: continue
			for u in sim.living():
				if u.pos.distance_to(n.pos) < 55:
					_hurt(u, 4.0, tr("burned in the wildfire"))
					if not u.dead and not u.job.get("flee", false) and u.role == "": sim.assign_flee(u)
			for s in sim.structures:
				if s.built and sim.ours(s) and not scorched.has(s.id) and not (s.type in ["burial_ground", "farm_plot", "bonfire"]) and s.pos.distance_to(n.pos) < 70:
					scorched[s.id] = true
					s.built = false
					s.progress = s.work * 0.4
					sim.alert(tr("The wildfire burns the %s!") % tr(D.STRUCTURES[s.type]["name"]), s.pos, "danger")
	if burning.is_empty():
		sim.add_log(tr("The wildfire burns out: %d trees are lost. In time, berries will sprout in the ashes.") % fire_size, "story")

# ------------------------------------------------------------ river flood (spring)
func _flood_tick(dt: float) -> void:
	if sim.hz.season_idx() == 0 and sim.day() != flood_day:
		flood_day = sim.day()
		if randf() < 0.45 * sim.hz.mult():
			flood_at = sim.time + randf_range(20.0, D.DAY_LEN * 0.6)
			flood_warned = false
	if flood_at > 0 and not flood_warned and sim.time >= flood_at - 15.0:
		flood_warned = true
		sim.alert(tr("The river is rising! Get away from the banks."), river_near_home(), "danger")
		for u in sim.living():
			var info := D.river_info(u.pos)
			if info["d"] < 240 and u.job.get("type", "") != "attack":
				sim.set_job(u, {"type": "move", "to": info["c"] + info["n"] * 380.0, "flee": true})
	if flood_at > 0 and sim.time >= flood_at:
		flood_at = -1.0
		_flood_strike()
	if flood_left > 0:
		flood_left -= dt
		for u in sim.living():
			if D.in_river(u.pos): _hurt(u, 3.0 * dt, tr("swept away by the river"))
		if flood_left <= 0:
			silt_until = sim.time + D.DAY_LEN * 2.0
			for n in sim.nodes:
				if n.kind == "fish": n.amount = n.max_amount
			sim.add_log(tr("The river falls back. The silt it left will feed the riverside fields."), "story")

func _flood_strike() -> void:
	sim.cult.on_event("spring_flood")
	flood_left = 45.0
	sim.flood_fx = maxf(sim.flood_fx, 0.5)
	sim.flags["flood_active"] = sim.time
	_disaster("flood", river_near_home(), -1.0)
	var hurt := 0
	for u in sim.living():
		if D.river_dist(u.pos) < 130:
			_hurt(u, u.max_hp * 0.2, tr("swept away by the river"))
			hurt += 1
	var damaged: Array = []
	for s in sim.structures:
		if sim.ours(s) and s.built and s.type != "palisade" and D.river_dist(s.pos) < 170:
			s.built = false
			s.progress = s.work * 0.5
			damaged.append(tr(D.STRUCTURES[s.type]["name"]))
	for n in sim.nodes:
		if n.kind in ["bush", "willow", "yarrow", "tubers", "grain"] and D.river_dist(n.pos) < 160: n.amount = 0.0
	var what := (tr(" Damaged: %s.") % ", ".join(damaged)) if not damaged.is_empty() else ""
	var caught := (tr(" %d caught by the water.") % hurt) if hurt > 0 else ""
	sim.alert(tr("The river floods its banks!%s%s") % [caught, what], river_near_home(), "danger")
	for u in sim.living(): sim.remember(u, tr("saw the river flood in the spring of Year %d") % sim.hz.year(), 3)

## The stretch of river nearest the village (where flood alerts point).
func river_near_home() -> Vector2:
	return D.nearest_river_point(D.VILLAGE) if not D.RIVERS.is_empty() else D.VILLAGE

# ------------------------------------------------------------ Fire Mountain
func _volcano_tick(dt: float) -> void:
	if not D.has_volcano(): return
	if erupt_left > 0:
		erupt_left -= dt
		shake = maxf(shake, 0.6)
	if not tremor_warned and sim.time >= erupt_at - 30.0:
		tremor_warned = true
		shake = 3.0
		sim.alert(tr("The ground trembles. Black smoke pours from the Fire Mountain."), D.VOLCANO, "warn")
	if sim.time >= erupt_at:
		erupt_at = sim.time + D.DAY_LEN * randf_range(9.0, 14.0)
		tremor_warned = false
		erupt()

func erupt() -> void:
	sim.cult.on_event("eruption")
	if not D.has_volcano(): return
	erupt_left = 25.0
	shake = 4.0
	ash_until = sim.time + D.DAY_LEN * 0.8
	fertile_until = sim.time + D.DAY_LEN * 3.5
	sim.reveal(D.VOLCANO, 300)
	sim.alert(tr("The Fire Mountain erupts! Fire runs down its slopes and ash darkens the sky."), D.VOLCANO, "danger")
	_disaster("eruption", D.VOLCANO, 1000.0)
	var near: Array = sim.nodes.filter(func(n): return n.kind == "tree" and n.pos.distance_to(D.VOLCANO) < LAVA_R)
	near.shuffle()
	for n in near.slice(0, 6): ignite(n)
	for u in sim.living():
		if u.pos.distance_to(D.VOLCANO) < LAVA_R: _hurt(u, u.max_hp * 0.5, tr("burned by the Fire Mountain"))
	for n in sim.nodes:
		if n.kind == "deer" and n.pos.distance_to(D.VOLCANO) < LAVA_R * 1.5: n.vel = (n.pos - D.VOLCANO).normalized() * 30.0
	# black glass on the slopes
	var have: int = sim.nodes.filter(func(n): return n.kind == "obsidian").size()
	for k in maxi(0, 4 - have):
		var p: Vector2 = D.VOLCANO + Vector2.from_angle(randf_range(1.6, 3.4)) * randf_range(220, 380)
		p = Vector2(clampf(p.x, 40, D.W - 40), clampf(p.y, 40, D.H - 40))
		var o = sim._node("obsidian", "stone", p, D.FINDS["obsidian"]["amount"])
		o.bank = D.region_at(p)
	for u in sim.living(): sim.remember(u, tr("saw the Fire Mountain erupt on Day %d") % sim.day(), 5)

func _ash_tick(dt: float) -> void:
	if sim.time < ash_until: ash = minf(1.0, ash + dt * 0.08)
	else: ash = maxf(0.0, ash - dt * 0.02)

# ------------------------------------------------------------ eclipse
func _start_eclipse() -> void:
	eclipse_t = 0.0
	eclipse_asked = false
	sim.add_log(tr("A shadow bites into the sun..."), "story")

func _eclipse_tick(dt: float) -> void:
	eclipse_t += dt
	if not eclipse_asked and eclipse_t >= 5.0:
		eclipse_asked = true
		pending = "eclipse"
	if eclipse_t >= ECLIPSE_LEN:
		eclipse_t = -1.0
		eclipse_at = _midday(sim.time + D.DAY_LEN * randf_range(12.0, 20.0))
		sim.add_log(tr("The sun returns."), "story")

func owns_event(id: String) -> bool: return id == "eclipse"

func event_def(_id: String) -> Dictionary:
	var shaman: E.Unit = sim.best_unit("lore", false)
	var sname: String = tr(shaman.name) if shaman else tr("The elders")
	return {"title": tr("The Sun Is Devoured"),
		"text": tr("At midday a black mouth eats the sun. Birds fall silent, the air turns cold, and stars come out in the day. The people cry out and look to you."),
		"options": [
			{"label": tr("Beat the drums"), "desc": tr("Drive off the sky-beast with drums and shouting. (+devotion, the tribe grows more martial)"), "enabled": true},
			{"label": tr("Offer food to the sky"), "desc": tr("Give 15 food to the hungry sky. (+devotion, the tribe grows more spiritual)"), "enabled": sim.stock["food"] >= 15},
			{"label": tr("Let %s read the omen") % sname, "desc": tr("Only a wise shaman (Lore 3+) or the knowledge of the Megalithic Totems can calm the people - otherwise they panic."), "enabled": shaman != null},
		]}

func resolve(_id: String, idx: int) -> String:
	var shaman: E.Unit = sim.best_unit("lore", false)
	match idx:
		0:
			sim.devotion = minf(100.0, sim.devotion + 4)
			sim.evo.drift("martial", 4.0)
			for u in sim.living(): sim.remember(u, tr("beat the drums to drive the sky-beast from the sun on Day %d") % sim.day(), 5)
			return tr("The drums thunder and the people howl at the sky. Slowly, the beast spits out the sun.")
		1:
			sim.stock["food"] -= 15
			sim.devotion = minf(100.0, sim.devotion + 12)
			sim.evo.drift("spiritual", 5.0)
			for u in sim.living(): sim.remember(u, tr("offered food to the devoured sun on Day %d") % sim.day(), 5)
			return tr("The offering burns on the fire. The sky is fed, and gives the sun back.")
	if shaman and (shaman.lv("lore") >= 3 or sim.has_tech("totems")):
		sim.stock["lore"] += 20
		sim.gain_xp(shaman, "lore", 15)
		sim.remember(shaman, tr("read the omen of the devoured sun and calmed the tribe on Day %d") % sim.day(), 8)
		return tr("%s points to the old marks on the totems: \"The sun has been eaten before, and always it returns.\" The people grow calm, and learn.") % tr(shaman.name)
	panic_until = sim.time + 25.0
	sim.devotion = maxf(0.0, sim.devotion - 5)
	for u in sim.living(): sim.remember(u, tr("hid in terror when the sun was devoured on Day %d") % sim.day(), 5)
	return tr("%s has no answer. Panic! The people drop their work and hide in their huts until the light returns.") % (tr(shaman.name) if shaman else tr("The shaman"))

# ------------------------------------------------------------ earthquake
func quake() -> void:
	sim.cult.on_event("earthquake")
	shake = 3.0
	var cands: Array = sim.structures.filter(func(s): return s.built and sim.ours(s) and not (s.type in ["bonfire", "burial_ground", "farm_plot", "palisade"]))
	cands.shuffle()
	var fallen: Array = []
	for s in cands.slice(0, randi_range(1, 2)):
		s.built = false
		s.progress = s.work * 0.5
		fallen.append(tr(D.STRUCTURES[s.type]["name"]))
		for u in sim.living():
			if u.pos.distance_to(s.pos) < 40: _hurt(u, u.max_hp * 0.2, tr("crushed when the earth shook"))
	# a rockslide bares new stone
	var c := D.VILLAGE + Vector2.from_angle(randf() * TAU) * randf_range(400, 1600)
	c = Vector2(clampf(c.x, 200, D.W - 200), clampf(c.y, 200, D.H - 200))
	if c.distance_to(D.VILLAGE) > 400 and D.home_side(c) and D.river_dist(c) > 120:
		for k in 3: sim._node("boulder", "stone", c + Vector2(randf_range(-40, 40), randf_range(-30, 30)), 40)
	_disaster("earthquake", D.VILLAGE, -1.0)
	var what := (tr(" Fallen: %s.") % ", ".join(fallen)) if not fallen.is_empty() else ""
	sim.alert(tr("The earth shakes!%s A rockslide bares new stone in the hills.") % what, D.VILLAGE, "danger")
	for u in sim.living(): sim.remember(u, tr("felt the earth shake on Day %d") % sim.day(), 4)

func summary() -> Array: return status()
