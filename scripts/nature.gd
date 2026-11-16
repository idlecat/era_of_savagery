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
const Config = preload("res://scripts/config.gd")

## Numbers and texts come from config/events.json (lightning, wildfire, flood, volcano,
## earthquake, eclipse); the reactions of the people from config/reactions.json.
var C: Dictionary = Config.load_cfg("events")
var LAVA_R: float = float(C["volcano"]["lava_radius"])
var ECLIPSE_LEN: float = float(C["eclipse"]["length"])

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
	if sim.hz.WEATHER.get(sim.hz.weather, {}).get("lightning", false):
		strike_t -= dt
		if strike_t <= 0:
			strike_t = Config.rand_in(C["lightning"]["every"])
			strike()
	_flood_tick(dt)
	_volcano_tick(dt)
	if eclipse_t < 0 and sim.time >= eclipse_at and not sim.rest_time(): _start_eclipse()
	if sim.time >= quake_at:
		quake_at = sim.time + D.DAY_LEN * Config.rand_in(C["earthquake"]["every_days"])
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
	var cl: Dictionary = C["lightning"]
	var r := randf()
	var at := Vector2.ZERO
	if r < float(cl["hit_person"]):
		var open: Array = sim.living().filter(func(u): return not _in_shelter(u))
		if not open.is_empty():
			var u: E.Unit = open.pick_random()
			at = u.pos
			_flash(at)
			_hit_person(u)
			return
	if r < float(cl["hit_person"]) + float(cl["hit_building"]):
		var targets: Array = sim.structures.filter(func(s): return s.built and sim.ours(s) and s.type in ["hut", "large_hut", "granary", "totem_shrine", "weapon_rack", "aurochs_pen", "council_ring", "smelter"])
		if not targets.is_empty():
			var s: E.Structure = targets.pick_random()
			_flash(s.pos)
			s.built = false
			s.progress = s.work * 0.5
			sim.alert(tr(cl["building_alert"]) % tr(D.STRUCTURES[s.type]["name"]), s.pos, "danger")
			_sky_fire(s.pos)
			return
	var reach: float = float(cl["tree_range"])
	var trees: Array = sim.nodes.filter(func(n): return n.kind == "tree" and (n.pos.distance_to(D.VILLAGE) < reach or sim.living().any(func(u): return u.pos.distance_to(n.pos) < reach * 0.5)))
	if trees.is_empty(): return
	var n = trees.pick_random()
	_flash(n.pos)
	var dry: bool = sim.hz.weather == "drought" or sim.hz.season_idx() == 1
	if randf() < float(cl["ignite_dry"] if dry else cl["ignite_wet"]):
		ignite(n)
	else:
		n.kind = "stump"
		n.regrow_t = float(cl["stump_regrow"])
		sim.popup(n.pos + Vector2(0, -40), tr(cl["popup"]), Color("#fff6a0"), true)
	_sky_fire(n.pos)

func _flash(at: Vector2) -> void:
	strikes.append({"pos": at, "t": 0.0})
	sim.devotion = minf(100.0, sim.devotion + float(C["lightning"]["devotion"]))

func _hit_person(u: E.Unit) -> void:
	var cl: Dictionary = C["lightning"]
	sim.cult.on_event("lightning")
	_hurt(u, u.max_hp * float(cl["person_damage"]), tr("struck by lightning"))
	if u.dead: return
	sim.popup(u.pos + Vector2(0, -36), tr(cl["hit_popup"]), Color("#fff6a0"), true)
	sim.alert(tr(cl["hit_alert"]) % tr(u.name), u.pos, "warn", [u])
	sim.remember(u, tr(cl["hit_remember"]) % sim.day(), 9)
	sim.gain_xp(u, "lore", 20)
	sim.react.trigger("hurt", {"victim": u, "cause": "lightning", "at": u.pos})

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
	var cw: Dictionary = C["wildfire"]
	if burning.is_empty():
		fire_size = 0
		scorched.clear()
		sim.alert(tr(cw["alert"]), n.pos, "danger")
		_disaster("wildfire", n.pos, 600.0)
	burning[n.id] = float(cw["burn_time"])
	fire_size += 1

func _fire_tick(dt: float) -> void:
	if burning.is_empty(): return
	var cw: Dictionary = C["wildfire"]
	var wet: bool = sim.hz.weather in ["rain", "storm", "blizzard"]
	for id in burning.keys():
		burning[id] -= dt * (float(cw["wet_burn_mult"]) if wet else 1.0)
		if burning[id] <= 0:
			burning.erase(id)
			var n = sim.node_by_id(id)
			if n:
				n.kind = "burnt"
				n.regrow_t = float(cw["regrow"])
				if randf() < float(cw["berry_chance"]): # berries sprout in the ashes
					var b = sim._node("bush", "food", n.pos + Vector2(randf_range(-20, 20), randf_range(-14, 14)), 30)
					b.amount = 0.0
					b.regrow = 0.14
	spread_t -= dt
	if spread_t <= 0 and fire_size < int(cw["max_trees"]):
		spread_t = float(cw["spread_every"])
		var p: float = float(cw["spread_chance"]) * (float(cw["drought_mult"]) if sim.hz.weather == "drought" else 1.0) * (float(cw["wet_mult"]) if wet or sim.hz.winter() else 1.0)
		var fresh: float = float(cw["burn_time"]) * 0.75
		for id in burning.keys():
			if burning[id] > fresh: continue # just caught
			var src = sim.node_by_id(id)
			if src == null: continue
			for o in sim.nodes:
				if o.kind == "tree" and not burning.has(o.id) and o.pos.distance_to(src.pos) < float(cw["spread_radius"]) and randf() < p: ignite(o)
	burn_tick -= dt
	if burn_tick <= 0:
		burn_tick = 1.0
		for id in burning:
			var n = sim.node_by_id(id)
			if n == null: continue
			for u in sim.living():
				if u.pos.distance_to(n.pos) < float(cw["burn_radius"]):
					_hurt(u, float(cw["burn_damage"]), tr("burned in the wildfire"))
					if not u.dead: sim.react.trigger("burned", {"victim": u, "cause": "wildfire", "at": n.pos})
			for s in sim.structures:
				if s.built and sim.ours(s) and not scorched.has(s.id) and not (s.type in ["burial_ground", "farm_plot", "bonfire"]) and s.pos.distance_to(n.pos) < float(cw["building_radius"]):
					scorched[s.id] = true
					s.built = false
					s.progress = s.work * 0.4
					sim.alert(tr(cw["building_alert"]) % tr(D.STRUCTURES[s.type]["name"]), s.pos, "danger")
	if burning.is_empty():
		sim.add_log(tr(cw["log"]) % fire_size, "story")

# ------------------------------------------------------------ river flood (spring)
func _flood_tick(dt: float) -> void:
	var cf: Dictionary = C["flood"]
	var warn: float = float(cf["warn_ahead"])
	if sim.hz.season_idx() == int(cf["season"]) and sim.day() != flood_day:
		flood_day = sim.day()
		if randf() < float(cf["chance"]) * sim.hz.mult():
			flood_at = sim.time + randf_range(warn + 5.0, D.DAY_LEN * 0.6)
			flood_warned = false
	if flood_at > 0 and not flood_warned and sim.time >= flood_at - warn:
		flood_warned = true
		sim.alert(tr(cf["warn"]), river_near_home(), "danger")
		sim.react.trigger("flood_warning", {"at": river_near_home()})
	if flood_at > 0 and sim.time >= flood_at:
		flood_at = -1.0
		_flood_strike()
	if flood_left > 0:
		flood_left -= dt
		for u in sim.living():
			if D.in_river(u.pos): _hurt(u, float(cf["drown_rate"]) * dt, tr("swept away by the river"))
		if flood_left <= 0:
			silt_until = sim.time + D.DAY_LEN * float(cf["silt_days"])
			for n in sim.nodes:
				if n.kind == "fish": n.amount = n.max_amount
			sim.add_log(tr(cf["log"]), "story")

func _flood_strike() -> void:
	var cf: Dictionary = C["flood"]
	sim.cult.on_event("spring_flood")
	flood_left = float(cf["length"])
	sim.flood_fx = maxf(sim.flood_fx, 0.5)
	sim.flags["flood_active"] = sim.time
	_disaster("flood", river_near_home(), -1.0)
	var hurt := 0
	for u in sim.living():
		if D.river_dist(u.pos) < float(cf["hit_radius"]):
			_hurt(u, u.max_hp * float(cf["hit_damage"]), tr("swept away by the river"))
			hurt += 1
			if not u.dead: sim.react.trigger("hurt", {"victim": u, "cause": "flood", "at": u.pos})
	var damaged: Array = []
	for s in sim.structures:
		if sim.ours(s) and s.built and s.type != "palisade" and D.river_dist(s.pos) < float(cf["building_radius"]):
			s.built = false
			s.progress = s.work * 0.5
			damaged.append(tr(D.STRUCTURES[s.type]["name"]))
	for n in sim.nodes:
		if n.kind in ["bush", "willow", "yarrow", "tubers", "grain"] and D.river_dist(n.pos) < float(cf["crop_radius"]): n.amount = 0.0
	var what := (tr(" Damaged: %s.") % ", ".join(damaged)) if not damaged.is_empty() else ""
	var caught := (tr(" %d caught by the water.") % hurt) if hurt > 0 else ""
	sim.alert(tr(cf["alert"]) % [caught, what], river_near_home(), "danger")
	for u in sim.living(): sim.remember(u, tr(cf["remember"]) % sim.hz.year(), 3)

## How far from a river's centreline the water reaches now: wider while the spring flood
## rises, peaks and falls back (as drawn; deer keep out of it).
func flood_half() -> float:
	var k := 0.0
	var warn: float = float(C["flood"]["warn_ahead"])
	if flood_left > 0: k = 1.0 if flood_left >= 8.0 else flood_left / 8.0
	elif flood_at > 0 and sim.time >= flood_at - warn: k = clampf(1.0 - (flood_at - sim.time) / warn, 0.0, 1.0) * 0.5
	return D.RIVER_HALF + float(C["flood"]["extra_width"]) * k

## The stretch of river nearest the village (where flood alerts point).
func river_near_home() -> Vector2:
	return D.nearest_river_point(D.VILLAGE) if not D.RIVERS.is_empty() else D.VILLAGE

# ------------------------------------------------------------ Fire Mountain
func _volcano_tick(dt: float) -> void:
	if not D.has_volcano(): return
	if erupt_left > 0:
		erupt_left -= dt
		shake = maxf(shake, 0.6)
	var cv: Dictionary = C["volcano"]
	if not tremor_warned and sim.time >= erupt_at - float(cv["tremor_lead"]):
		tremor_warned = true
		shake = 3.0
		sim.alert(tr(cv["warn"]), D.VOLCANO, "warn")
		sim.react.trigger("volcano_tremor", {"at": D.VOLCANO, "danger": D.VOLCANO})
	if sim.time >= erupt_at:
		erupt_at = sim.time + D.DAY_LEN * Config.rand_in(cv["every_days"])
		tremor_warned = false
		erupt()

func erupt() -> void:
	sim.cult.on_event("eruption")
	if not D.has_volcano(): return
	var cv: Dictionary = C["volcano"]
	erupt_left = float(cv["length"])
	shake = 4.0
	ash_until = sim.time + D.DAY_LEN * float(cv["ash_days"])
	fertile_until = sim.time + D.DAY_LEN * float(cv["fertile_days"])
	sim.reveal(D.VOLCANO, 300)
	sim.alert(tr(cv["alert"]), D.VOLCANO, "danger")
	_disaster("eruption", D.VOLCANO, 1000.0)
	var near: Array = sim.nodes.filter(func(n): return n.kind == "tree" and n.pos.distance_to(D.VOLCANO) < LAVA_R)
	near.shuffle()
	for n in near.slice(0, int(cv["trees_ignited"])): ignite(n)
	for u in sim.living():
		if u.pos.distance_to(D.VOLCANO) < LAVA_R: _hurt(u, u.max_hp * float(cv["lava_damage"]), tr("burned by the Fire Mountain"))
	sim.react.trigger("eruption", {"at": D.VOLCANO, "danger": D.VOLCANO})
	for n in sim.nodes:
		if n.kind == "deer" and n.pos.distance_to(D.VOLCANO) < LAVA_R * 1.5: n.vel = (n.pos - D.VOLCANO).normalized() * 30.0
	# black glass on the slopes
	var have: int = sim.nodes.filter(func(n): return n.kind == "obsidian").size()
	for k in maxi(0, int(cv["obsidian"]) - have):
		var p: Vector2 = D.VOLCANO + Vector2.from_angle(randf_range(1.6, 3.4)) * randf_range(220, 380)
		p = Vector2(clampf(p.x, 40, D.W - 40), clampf(p.y, 40, D.H - 40))
		var o = sim._node("obsidian", "stone", p, D.FINDS["obsidian"]["amount"])
		o.bank = D.region_at(p)
	for u in sim.living(): sim.remember(u, tr(cv["remember"]) % sim.day(), 5)

func _ash_tick(dt: float) -> void:
	if sim.time < ash_until: ash = minf(1.0, ash + dt * 0.08)
	else: ash = maxf(0.0, ash - dt * 0.02)

# ------------------------------------------------------------ eclipse
func _start_eclipse() -> void:
	eclipse_t = 0.0
	eclipse_asked = false
	sim.add_log(tr(C["eclipse"]["start_log"]), "story")

func _eclipse_tick(dt: float) -> void:
	eclipse_t += dt
	if not eclipse_asked and eclipse_t >= float(C["eclipse"]["ask_after"]):
		eclipse_asked = true
		pending = "eclipse"
	if eclipse_t >= ECLIPSE_LEN:
		eclipse_t = -1.0
		eclipse_at = _midday(sim.time + D.DAY_LEN * Config.rand_in(C["eclipse"]["every_days"]))
		sim.add_log(tr(C["eclipse"]["end_log"]), "story")

func owns_event(id: String) -> bool: return id == "eclipse"

## The eclipse dilemma comes from config/events.json "eclipse": options with a cost, the
## actions they run (story.gd run()) and the result; an option with "shaman" needs the
## best keeper of lore at that level (or the tech in "or_tech"), else "else_do" runs.
## "%s" in an option's label and results is the shaman's name.
func event_def(_id: String) -> Dictionary:
	var ce: Dictionary = C["eclipse"]
	var shaman: E.Unit = sim.best_unit("lore", false)
	var sname: String = tr(shaman.name) if shaman else tr("The elders")
	var opts: Array = []
	for o in ce["options"]:
		var label: String = tr(o["label"])
		if label.contains("%s"): label = label % sname
		var ok := true
		for r in o.get("cost", {}): ok = ok and sim.stock.get(r, 0.0) >= float(o["cost"][r])
		if o.has("shaman"): ok = ok and shaman != null
		opts.append({"label": label, "desc": tr(o["desc"]), "enabled": ok})
	return {"title": tr(ce["title"]), "text": tr(ce["text"]), "options": opts}

func _shaman_ok(o: Dictionary) -> bool:
	var need: Dictionary = o["shaman"]
	var shaman: E.Unit = sim.best_unit("lore", false)
	return (shaman != null and shaman.lv("lore") >= int(need.get("lore", 0))) or (need.has("or_tech") and sim.has_tech(need["or_tech"]))

func resolve(_id: String, idx: int) -> String:
	var opts: Array = C["eclipse"]["options"]
	var o: Dictionary = opts[clampi(idx, 0, opts.size() - 1)]
	var shaman: E.Unit = sim.best_unit("lore", false)
	var sname: String = tr(shaman.name) if shaman else tr("The shaman")
	for r in o.get("cost", {}): sim.stock[r] -= float(o["cost"][r])
	var good: bool = not o.has("shaman") or _shaman_ok(o)
	sim.story.run(o["do"] if good else o.get("else_do", []), null)
	var res: String = tr(o["result"] if good else o.get("else_result", o["result"]))
	return res % sname if res.contains("%s") else res

# ------------------------------------------------------------ earthquake
func quake() -> void:
	var cq: Dictionary = C["earthquake"]
	sim.cult.on_event("earthquake")
	shake = float(cq["shake"])
	sim.react.trigger("earthquake", {"at": D.VILLAGE}) # (they tend the hurt once it stops)
	var cands: Array = sim.structures.filter(func(s): return s.built and sim.ours(s) and not (s.type in ["bonfire", "burial_ground", "farm_plot", "palisade"]))
	cands.shuffle()
	var fallen: Array = []
	for s in cands.slice(0, randi_range(int(cq["collapse"][0]), int(cq["collapse"][1]))):
		s.built = false
		s.progress = s.work * 0.5
		fallen.append(tr(D.STRUCTURES[s.type]["name"]))
		for u in sim.living():
			if u.pos.distance_to(s.pos) < float(cq["crush_radius"]): _hurt(u, u.max_hp * float(cq["crush_damage"]), tr("crushed when the earth shook"))
	# a rockslide bares new stone
	var c := D.VILLAGE + Vector2.from_angle(randf() * TAU) * Config.rand_in(cq["rockslide_dist"])
	c = Vector2(clampf(c.x, 200, D.W - 200), clampf(c.y, 200, D.H - 200))
	if c.distance_to(D.VILLAGE) > 400 and D.home_side(c) and D.river_dist(c) > 120:
		for k in 3: sim._node("boulder", "stone", c + Vector2(randf_range(-40, 40), randf_range(-30, 30)), 40)
	_disaster("earthquake", D.VILLAGE, -1.0)
	var what := (tr(" Fallen: %s.") % ", ".join(fallen)) if not fallen.is_empty() else ""
	sim.alert(tr(cq["alert"]) % what, D.VILLAGE, "danger")
	for u in sim.living(): sim.remember(u, tr(cq["remember"]) % sim.day(), 4)

func summary() -> Array: return status()
