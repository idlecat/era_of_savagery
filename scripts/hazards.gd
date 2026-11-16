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
const Config = preload("res://scripts/config.gd")

const SEASONS := ["Spring", "Summer", "Autumn", "Winter"]
const LEVELS := ["off", "normal", "harsh"]
## All the numbers and texts come from config/events.json (seasons, weather, wolves,
## tiger_raids, sickness, famine); WEATHER is its "weather.kinds": weather -> {name,
## chance per roll by season [spring, summer, autumn, winter], dur range (s), texts}.
var C: Dictionary = Config.load_cfg("events")
var SEASON_DAYS: int = int(C["seasons"]["days"])
var WEATHER: Dictionary = C["weather"]["kinds"]

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
	return r * (mult() if on() else 1.0) * sim.inv.cold_mult()

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
	var news: Dictionary = C["seasons"]["news"][season_idx()]
	sim.alert(tr(news["alert"]), Vector2.ZERO, news.get("level", "info"))
	match season_idx():
		0: _herds_return()
		3:
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
			if WEATHER[weather].has("done"): sim.alert(tr(WEATHER[weather]["done"]), Vector2.ZERO, "info")
			weather = "clear"
		return
	weather_roll -= dt
	if weather_roll > 0: return
	weather_roll = Config.rand_in(C["weather"]["roll_every"])
	for w in WEATHER:
		var wk: Dictionary = WEATHER[w]
		if randf() < float(wk["chance"][season_idx()]) * mult():
			if wk.has("warn_ahead"): # announced before it arrives
				incoming = w
				incoming_t = float(wk["warn_ahead"])
				sim.alert(tr(wk["warn"]), Vector2.ZERO, "danger")
			else:
				_start(w)
			return

func _start(w: String) -> void:
	sim.cult.on_event(w) # (weather: blizzard, storm, drought...)
	incoming = ""
	weather = w
	var wk: Dictionary = WEATHER[w]
	weather_left = Config.rand_in(wk["dur"])
	if wk.get("disaster", false): # (Task Contracts out in it are interrupted)
		sim.flags["disaster_t"] = sim.time
		sim.flags["disaster"] = w
	if wk.has("alert"): sim.alert(tr(wk["alert"]), Vector2.ZERO, wk.get("level", "info"))
	if wk.get("lightning", false): sim.nat.strike()
	sim.react.trigger(w, {"at": D.VILLAGE})

# ------------------------------------------------------------ wild animals
func _wolves() -> void:
	var night: bool = sim.night_amt > 0.5
	var cw: Dictionary = C["wolves"]
	if night and not last_night:
		var chance: float = float(cw["chance_by_season"][season_idx()]) * mult()
		if sim.day() >= int(cw["from_day"]) and randf() < chance: spawn_wolf_pack()
	if not night and last_night and cw.get("leave_at_dawn", true): # dawn: wolves slink away (except in winter)
		for p in sim.predators:
			if p.kind == "wolf" and not winter(): p.fleeing = true
	last_night = night

func spawn_wolf_pack() -> void:
	var cw: Dictionary = C["wolves"]
	var size := randi_range(int(cw["pack"][0]), int(cw["pack"][1])) + (int(cw["harsh_extra"]) if level == "harsh" else 0) \
		+ (1 if winter() and randf() < float(cw["winter_extra_chance"]) else 0)
	var c := Vector2.ZERO
	var near: float = float(cw["spawn_dist"][0])
	for k in 40: # somewhere on the tribe's side of the water, away from the village
		c = D.VILLAGE + Vector2.from_angle(randf() * TAU) * Config.rand_in(cw["spawn_dist"])
		c = Vector2(clampf(c.x, 150, D.W - 150), clampf(c.y, 150, D.H - 150))
		if D.home_side(c) and not D.in_river(c) and c.distance_to(D.VILLAGE) > near: break
	for i in size:
		var w = sim.spawn_predator(c + Vector2(randf_range(-40, 40), randf_range(-40, 40)), D.VILLAGE + Vector2(randf_range(-200, 200), randf_range(-150, 150)))
		make_wolf(w)
	sim.alert(tr(cw["alert"]) % size, c, "danger")

## Turn a freshly spawned predator into a wolf of this season's pack.
func make_wolf(w) -> void:
	var cw: Dictionary = C["wolves"]
	w.kind = "wolf"
	w.name = "wolf"
	w.hp = float(cw["hp"]) * (float(cw["harsh_hp_mult"]) if level == "harsh" else 1.0)
	w.max_hp = w.hp
	w.atk = float(cw["atk"])
	w.def = float(cw["def"])
	w.spd = float(cw["spd"])
	w.raid_t = float(cw["give_up"]) # the pack gives up after a while

func _raids(dt: float) -> void:
	var ct: Dictionary = C["tiger_raids"]
	if sim.day() < int(ct["from_day"]): return
	raid_t -= dt * mult()
	if raid_t > 0: return
	raid_t = D.DAY_LEN * Config.rand_in(ct["every_days"]) * (float(ct["winter_mult"]) if winter() else 1.0)
	var tigers: Array = sim.predators.filter(func(p): return p.kind == "tiger" and p.den != null and not p.dead and not p.fleeing)
	if tigers.is_empty(): return
	var t = tigers.pick_random()
	t.raid = true
	t.raid_t = float(ct["length"])
	t.goal = D.VILLAGE + Vector2(randf_range(-120, 120), randf_range(-100, 100))
	t.path = []
	sim.alert(tr(ct["alert"]), t.pos, "danger")

# ------------------------------------------------------------ sickness
func _sickness(dt: float) -> void:
	var cs: Dictionary = C["sickness"]
	sick_roll -= dt
	if sick_roll <= 0:
		sick_roll = float(cs["roll_every"])
		var alive: Array = sim.living()
		var crowd: float = maxf(0.0, float(alive.size()) / maxf(1.0, sim.pop_cap()) - 0.8)
		var risk: float = float(cs["base"]) + (float(cs["winter"]) if winter() else 0.0) + (float(cs["hungry"]) if sim.stock["food"] < alive.size() else 0.0) \
			+ crowd * float(cs["crowding"]) + sim.nat.sick_risk()
		if randf() < risk * mult():
			var cands: Array = alive.filter(func(u): return u.sick <= 0 and sim.time > u.immune_t and u.role != "contract")
			if not cands.is_empty():
				var p0 = cands.pick_random()
				p0.sick = 1.0
				sim.alert(tr(cs["alert"]) % tr(p0.name), p0.pos, "warn", [p0])
				sim.react.trigger("sickness", {"victim": p0, "at": p0.pos})
	spread_t -= dt
	if spread_t > 0: return
	spread_t = float(cs["spread_every"])
	var alive2: Array = sim.living()
	for u in alive2:
		if u.sick <= 0: continue
		for o in alive2:
			if o == u or o.sick > 0 or sim.time < o.immune_t: continue
			if o.pos.distance_to(u.pos) < float(cs["spread_radius"]) and randf() < float(cs["spread_chance"]) * mult():
				o.sick = 1.0
				sim.popup(o.pos + Vector2(0, -30), tr(cs["popup"]), Color("#a8e07a"))

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
		sim.alert(tr(C["famine"]["alert"]), Vector2.ZERO, "danger")
		for u in sim.living(): sim.remember(u, tr(C["famine"]["remember"]) % year(), 5)
		sim.react.trigger("famine", {"at": D.VILLAGE})
	elif sim.stock["food"] < pop * 2:
		famine_t = D.DAY_LEN * 0.75
		sim.alert(tr(C["famine"]["warn"]) % pop, Vector2.ZERO, "warn")
	else:
		famine_t = 10.0

## For LLM personas and the HUD.
func summary() -> Dictionary:
	return {"season": tr(season()), "year": year(), "weather": tr(weather_name()), "omens": sim.nat.status(),
		"days_of_food": snappedf(sim.stock["food"] / maxf(1.0, sim.living().size() * 0.9), 0.1),
		"food_storage": "%d/%d" % [sim.stock["food"], sim.food_cap()], "tribe": sim.folk.summary()}
