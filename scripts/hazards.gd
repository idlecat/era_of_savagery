## The hardships of the ancient world: seasons, weather, wild animals, sickness and famine.
## Owned by the simulation and ticked with it; pure rules, no rendering.
##
## Seasons   - 2 days each (spring, summer, autumn, winter). Winter stops berries and
##             farms, makes people hungrier and makes the cold deadly.
## Weather   - rolled per season: spring rain, summer drought, autumn storms, winter
##             blizzards. Blizzards are announced, slow everyone, blind scouts and freeze
##             anyone far from a fire; they also count as a natural disaster for contracts.
## Animals   - wolf packs come out at night (mostly autumn/winter); tigers leave their
##             dens to raid the village every few days.
## Sickness  - outbreaks start in hard times (winter, hunger, crowding) and spread between
##             people who live close together; fire, shrines, shamans and the Hot Spring heal.
## Famine    - the tribe is warned when food runs low.
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")

const SEASON_DAYS := 2
const SEASONS := ["Spring", "Summer", "Autumn", "Winter"]
const LEVELS := ["off", "normal", "harsh"]
## weather -> {name, chance per roll by season [spring, summer, autumn, winter], duration range (s)}
const WEATHER := {
	"rain":     {"name": "Rain", "chance": [0.35, 0.10, 0.25, 0.0], "dur": [40.0, 80.0]},
	"storm":    {"name": "Thunderstorm", "chance": [0.08, 0.10, 0.15, 0.0], "dur": [25.0, 45.0]},
	"drought":  {"name": "Drought", "chance": [0.0, 0.30, 0.05, 0.0], "dur": [120.0, 200.0]},
	"blizzard": {"name": "Blizzard", "chance": [0.0, 0.0, 0.04, 0.40], "dur": [35.0, 65.0]},
}

var sim
var level := "normal"
var weather := "clear"
var weather_left := 0.0
var weather_roll := 20.0
var incoming := ""       # announced weather that has not arrived yet
var incoming_t := 0.0
var snow := 0.0          # 0..1 snow cover on the ground (eases in/out)
var last_night := false
var raid_t := 0.0
var sick_roll := 30.0
var spread_t := 0.0
var famine_t := 0.0
var season_seen := -1

func _init(s) -> void:
	sim = s
	raid_t = D.DAY_LEN * 3.0

func on() -> bool:
	return level != "off"

func mult() -> float:
	return {"off": 0.0, "normal": 1.0, "harsh": 1.35}[level]

# ------------------------------------------------------------ calendar
func day_index() -> int: return int(sim.time / D.DAY_LEN)
func season_idx() -> int: return int(day_index() / SEASON_DAYS) % 4
func season() -> String: return SEASONS[season_idx()]
func year() -> int: return 1 + int(day_index() / (SEASON_DAYS * 4))
func winter() -> bool: return on() and season_idx() == 3

## Seconds until the next season starts.
func season_left() -> float:
	var span := D.DAY_LEN * SEASON_DAYS
	return span - fmod(sim.time, span)

func weather_name() -> String:
	if weather == "clear": return "Snow" if winter() else "Clear"
	return WEATHER[weather]["name"]

# ------------------------------------------------------------ effects queried by the simulation
func berry_mult() -> float:
	if not on(): return 1.0
	if season_idx() == 3: return 0.0
	if weather == "drought": return 0.15
	return [1.5, 1.0, 1.2, 0.0][season_idx()]

func food_mult(type: String) -> float:
	if not on(): return 1.0
	var m := 1.0
	match type:
		"farm_plot": m = [1.0, 1.2, 1.5, 0.0][season_idx()]
		"fishing_dock": m = [1.0, 1.0, 1.0, 0.5][season_idx()]
		"aurochs_pen": m = [1.0, 1.0, 1.0, 0.7][season_idx()]
	if weather == "drought" and type != "aurochs_pen": m *= 0.5
	return m

func spoil_mult() -> float:
	return 1.5 if on() and season_idx() == 1 else 1.0

func hunger_mult() -> float:
	return 1.25 if winter() else 1.0

func speed_mult() -> float:
	return {"blizzard": 0.7, "rain": 0.9, "storm": 0.85}.get(weather, 1.0) if on() else 1.0

func work_mult() -> float:
	return {"rain": 0.85, "storm": 0.75, "blizzard": 0.6}.get(weather, 1.0) if on() else 1.0

func sight_mult() -> float:
	return {"blizzard": 0.55, "rain": 0.85, "storm": 0.75}.get(weather, 1.0) if on() else 1.0

## Cold damage per second for someone (0 = fine). Away from a fire, without furs, nights
## sting; in winter they can kill, and a blizzard freezes even the well-dressed.
func cold_rate(u: E.Unit, warm: bool) -> float:
	if warm: return 0.0
	var hide: bool = sim.has_tech("hide")
	var night: bool = sim.night_amt > 0.5
	var r := 0.0
	if night and not hide: r += 0.3
	if winter():
		r += (0.25 if hide else 0.6) * (1.0 if night else 0.35)
	if weather == "blizzard": r += 0.55 if hide else 0.9
	return r * (mult() if on() else 1.0)

## Outside winter and blizzards the cold only weakens (never below 35% HP).
func cold_can_kill() -> bool:
	return winter() or weather == "blizzard"

# ------------------------------------------------------------ tick
func update(dt: float) -> void:
	var target := 1.0 if winter() else 0.0
	snow += (target - snow) * minf(1.0, dt * 0.05)
	if not on():
		weather = "clear"
		return
	_season_news()
	_weather(dt)
	_wolves()
	_raids(dt)
	_sickness(dt)
	_famine(dt)

func _season_news() -> void:
	var si := season_idx() + day_index() / (SEASON_DAYS * 4) * 4
	if si == season_seen: return
	var first := season_seen < 0
	season_seen = si
	if first: return
	match season_idx():
		0:
			sim.alert(tr("Spring returns. The berries ripen again, and the herds come back."), Vector2.ZERO, "info")
			_herds_return()
		1: sim.alert(tr("Summer. Watch the food stores - they spoil faster in the heat."), Vector2.ZERO, "info")
		2: sim.alert(tr("Autumn. Winter comes in two days: gather food and wood, and keep the fires lit."), Vector2.ZERO, "warn")
		3:
			sim.alert(tr("Winter has come! No berries, no harvest, the herds have moved south, and the cold can kill."), Vector2.ZERO, "danger")
			_herds_leave()
			for u in sim.living(): sim.remember(u, tr("faced the winter of Year %d") % year(), 3)

## Half the deer migrate away for the winter and come back in spring.
func _herds_leave() -> void:
	var deer: Array = sim.nodes.filter(func(n): return n.kind == "deer")
	deer.shuffle()
	for n in deer.slice(0, deer.size() / 2): sim.nodes.erase(n)

func _herds_return() -> void:
	var want: Dictionary = sim.herd_sizes(26.0 * D.area_k())
	var counts := {}
	for n in sim.nodes:
		if n.kind == "deer": counts[n.bank] = counts.get(n.bank, 0) + 1
	for r in want:
		for i in maxi(0, want[r] - counts.get(r, 0)): sim.spawn_deer(r, true)

func _weather(dt: float) -> void:
	if incoming != "":
		incoming_t -= dt
		if incoming_t <= 0: _start(incoming)
		return
	if weather != "clear":
		weather_left -= dt
		if weather_left <= 0:
			if weather == "drought": sim.alert(tr("The drought breaks."), Vector2.ZERO, "info")
			weather = "clear"
		return
	weather_roll -= dt
	if weather_roll > 0: return
	weather_roll = randf_range(35.0, 60.0)
	for w in WEATHER:
		if randf() < WEATHER[w]["chance"][season_idx()] * mult():
			if w == "blizzard":
				incoming = w
				incoming_t = 15.0
				sim.alert(tr("The sky turns white-grey - a blizzard is coming! Get everyone to the fires."), Vector2.ZERO, "danger")
			else:
				_start(w)
			return

func _start(w: String) -> void:
	incoming = ""
	weather = w
	weather_left = randf_range(WEATHER[w]["dur"][0], WEATHER[w]["dur"][1])
	match w:
		"blizzard":
			sim.flags["disaster_t"] = sim.time
			sim.flags["disaster"] = "blizzard"
			sim.alert(tr("Blizzard! Anyone far from a fire will freeze."), Vector2.ZERO, "danger")
		"drought":
			sim.alert(tr("Drought: berries wither and the fields go dry."), Vector2.ZERO, "warn")
		"storm":
			sim.alert(tr("A thunderstorm rolls over the land."), Vector2.ZERO, "warn")
			sim.nat.strike()
		"rain":
			sim.alert(tr("Rain. Work outdoors goes slower."), Vector2.ZERO, "info")

# ------------------------------------------------------------ wild animals
func _wolves() -> void:
	var night: bool = sim.night_amt > 0.5
	if night and not last_night:
		var chance: float = [0.15, 0.10, 0.45, 0.8][season_idx()] * mult()
		if sim.day() >= 2 and randf() < chance: spawn_wolf_pack()
	if not night and last_night: # dawn: wolves slink away (except in winter)
		for p in sim.predators:
			if p.kind == "wolf" and not winter(): p.fleeing = true
	last_night = night

func spawn_wolf_pack() -> void:
	var size := 2 + randi() % 2 + (1 if level == "harsh" else 0) + (1 if winter() and randf() < 0.5 else 0)
	var c := Vector2.ZERO
	for k in 40: # somewhere on the tribe's side of the water, away from the village
		c = D.VILLAGE + Vector2.from_angle(randf() * TAU) * randf_range(650, 1800)
		c = Vector2(clampf(c.x, 150, D.W - 150), clampf(c.y, 150, D.H - 150))
		if D.home_side(c) and not D.in_river(c) and c.distance_to(D.VILLAGE) > 650: break
	for i in size:
		var w = sim.spawn_predator(c + Vector2(randf_range(-40, 40), randf_range(-40, 40)), D.VILLAGE + Vector2(randf_range(-200, 200), randf_range(-150, 150)))
		make_wolf(w)
	sim.alert(tr("Wolves howl in the dark - a pack of %d is hunting near the village!") % size, c, "danger")

## Turn a freshly spawned predator into a wolf of this season's pack.
func make_wolf(w) -> void:
	w.kind = "wolf"
	w.name = "wolf"
	w.hp = 28.0 * (1.2 if level == "harsh" else 1.0)
	w.max_hp = w.hp
	w.atk = 3.5
	w.def = 1.0
	w.spd = 82.0
	w.raid_t = 160.0 # the pack gives up after a while

func _raids(dt: float) -> void:
	if sim.day() < 3: return
	raid_t -= dt * mult()
	if raid_t > 0: return
	raid_t = D.DAY_LEN * randf_range(2.5, 4.0) * (0.8 if winter() else 1.0)
	var tigers: Array = sim.predators.filter(func(p): return p.kind == "tiger" and p.den != null and not p.dead and not p.fleeing)
	if tigers.is_empty(): return
	var t = tigers.pick_random()
	t.raid = true
	t.raid_t = 90.0
	t.goal = D.VILLAGE + Vector2(randf_range(-120, 120), randf_range(-100, 100))
	t.path = []
	sim.alert(tr("A hungry saber-tooth has left its den and is stalking toward the village!"), t.pos, "danger")

# ------------------------------------------------------------ sickness
func _sickness(dt: float) -> void:
	sick_roll -= dt
	if sick_roll <= 0:
		sick_roll = 45.0
		var alive: Array = sim.living()
		var crowd: float = maxf(0.0, float(alive.size()) / maxf(1.0, sim.pop_cap()) - 0.8)
		var risk: float = 0.03 + (0.10 if winter() else 0.0) + (0.08 if sim.stock["food"] < alive.size() else 0.0) + crowd * 0.4 + sim.nat.sick_risk()
		if randf() < risk * mult():
			var cands: Array = alive.filter(func(u): return u.sick <= 0 and sim.time > u.immune_t and u.role != "contract")
			if not cands.is_empty():
				var p0 = cands.pick_random()
				p0.sick = 1.0
				sim.alert(tr("%s has fallen ill with a coughing fever. Keep the sick warm - it spreads.") % tr(p0.name), p0.pos, "warn", [p0])
	spread_t -= dt
	if spread_t > 0: return
	spread_t = 2.0
	var alive2: Array = sim.living()
	for u in alive2:
		if u.sick <= 0: continue
		for o in alive2:
			if o == u or o.sick > 0 or sim.time < o.immune_t: continue
			if o.pos.distance_to(u.pos) < 70 and randf() < 0.035 * mult():
				o.sick = 1.0
				sim.popup(o.pos + Vector2(0, -30), tr("Sick!"), Color("#a8e07a"))

## Recovery per second for a sick person (sickness runs from 1 down to 0).
func heal_rate(u: E.Unit, warm: bool) -> float:
	var r := 1.0 / 70.0
	if warm: r *= 1.5
	if sim._struct_near("totem_shrine", u.pos, 160) or sim._struct_near("grand_altar", u.pos, 160): r *= 1.4
	for o in sim.living():
		if o != u and o.lv("lore") >= 3 and o.pos.distance_to(u.pos) < 140:
			r *= 1.5
			break
	for lm in sim.landmarks:
		if lm["kind"] == "spring" and lm["found"]: r *= 1.3
	if sim.time < u.herb_t: r *= 2.5 # willow-bark tea
	if u.hunger < 20: r *= 0.5
	return r

# ------------------------------------------------------------ famine
func _famine(dt: float) -> void:
	famine_t -= dt
	if famine_t > 0: return
	var pop: int = sim.living().size()
	if sim.stock["food"] < 1 and sim.living().any(func(u): return u.hunger < 15):
		famine_t = 45.0
		sim.alert(tr("FAMINE! The stores are empty and the tribe is starving. Hunt, fish, forage - now."), Vector2.ZERO, "danger")
		for u in sim.living(): sim.remember(u, tr("went hungry in the famine of Year %d") % year(), 5)
	elif sim.stock["food"] < pop * 2:
		famine_t = D.DAY_LEN * 0.75
		sim.alert(tr("Food is running low - about a day's worth left for %d mouths.") % pop, Vector2.ZERO, "warn")
	else:
		famine_t = 10.0

## For LLM personas and the HUD.
func summary() -> Dictionary:
	return {"season": tr(season()), "year": year(), "weather": tr(weather_name()), "omens": sim.nat.status(),
		"days_of_food": snappedf(sim.stock["food"] / maxf(1.0, sim.living().size() * 0.9), 0.1),
		"food_storage": "%d/%d" % [sim.stock["food"], sim.food_cap()], "tribe": sim.folk.summary()}
