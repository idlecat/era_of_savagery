## Pacing report: plays whole games headless on autopilot and writes, per in-game day, how
## much went wrong (hardships, deaths) and how the tribe stood (food, people, mood). Used to
## see whether the game has long dead stretches or pile-ups of trouble (a director's job).
##
## $GODOT --headless --path . --script res://tools/pacing.gd -- --days=20 --seed=1 --level=normal [--map=the_ford|standard...] [--out=/path.csv] [--dt=0.1]
##
## Autopilot: a Steward is appointed (the economy runs), dilemmas take their first option,
## contract emergencies their first allowed effect, and emergency mode runs with no orders.
extends SceneTree

const Sim = preload("res://scripts/sim.gd")
const D = preload("res://scripts/data.gd")
const MapGen = preload("res://scripts/mapgen.gd")
const Scenarios = preload("res://scripts/scenarios.gd")
const Cultures = preload("res://scripts/cultures.gd")

var day_rows: Array = []
var cur := {}

func _initialize() -> void:
	var a := {}
	for s in OS.get_cmdline_user_args():
		var kv := s.trim_prefix("--").split("=", true, 1)
		a[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var days := int(a.get("days", "20"))
	var sd := int(a.get("seed", "1"))
	var dt := float(a.get("dt", "0.1"))
	var m: String = a.get("map", "the_ford")
	Cultures.apply(a.get("culture", ""))
	if MapGen.SIZES.has(m): MapGen.generate(m, int(a.get("tribes", "3")), sd, a.get("land", "random"))
	else: Scenarios.apply(m)
	seed(sd)
	var sim = Sim.new()
	sim.hz.level = a.get("level", "normal")
	sim.new_game()
	var best = null
	for u in sim.living():
		if u.role == "" and (best == null or u.lv("lore") > best.lv("lore")): best = u
	if best: sim.appoint(best, "steward")
	_new_day(sim)
	sim.event_fired.connect(func(id): cur["events"] += 1; cur["what"].append("event:" + id))
	sim.alert_raised.connect(func(al):
		if al["level"] == "danger": cur["danger"] += 1
		elif al["level"] == "warn": cur["warn"] += 1)
	sim.happened.connect(func(id): if not id.begins_with("policy:"): cur["nature"] += 1; cur["what"].append(id))
	sim.crisis_started.connect(func(c): cur["crises"] += 1; cur["what"].append("crisis:" + c["kind"]))
	var t0 := Time.get_ticks_msec()
	var end_t := days * D.DAY_LEN
	var last_day := sim.day()
	while sim.time < end_t:
		if sim.pending_event != "": sim.resolve_event(sim.pending_event, 0)
		for c in sim.contracts.list:
			if c.status == "interrupted": sim.contracts.resolve(c, sim.contracts.allowed_effects(c)[0])
		sim.paused = false
		sim.tick(dt)
		if sim.is_day_part("morning") or not sim.rest_time(): # (field hands by day)
			cur["hands_sum"] = float(cur.get("hands_sum", 0.0)) + sim.living().filter(func(u): return u.job.get("type", "") == "field").size()
			cur["hands_n"] = int(cur.get("hands_n", 0)) + 1
		if sim.day() != last_day:
			_close_day(sim)
			last_day = sim.day()
			if sim.living().is_empty(): break
			_new_day(sim)
	if not cur.is_empty() and int(cur["day"]) <= days and sim.time >= end_t: _close_day(sim)
	var out: String = a.get("out", "")
	var csv := "seed,level,day,events,danger,warn,nature,crises,deaths,food,food_cap,pop,pop_cap,wood,fields,field_hands,mood,rivals_pop,rival_max,rival_cap,rival_warriors,rival_homes,rival_era,rivals_left,what\n"
	for r in day_rows:
		csv += "%d,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%.1f,%d,%d,%d,%d,%d,%d,%.1f,%d,%s\n" % [sd, sim.hz.level, r["day"], r["events"], r["danger"], r["warn"], r["nature"], r["crises"], r["deaths"], r["food"], r["food_cap"], r["pop"], r["pop_cap"], r["wood"], r["fields"], r["field_hands"], r["mood"], r["rivals_pop"], r["rival_max"], r["rival_cap"], r["rival_warriors"], r["rival_homes"], r["rival_era"], r["rivals_left"], " ".join(r["what"]).replace(",", ";")]
	if out != "":
		var f := FileAccess.open(out, FileAccess.WRITE)
		f.store_string(csv)
		f.close()
	else: print(csv)
	print("pacing: seed %d %s, %d days in %.1fs, %d alive" % [sd, sim.hz.level, day_rows.size(), (Time.get_ticks_msec() - t0) / 1000.0, sim.living().size()])
	quit()

func _new_day(sim) -> void:
	cur = {"day": sim.day(), "events": 0, "danger": 0, "warn": 0, "nature": 0, "crises": 0, "what": [],
		"dead0": sim.units.filter(func(u): return u.dead).size()}

func _close_day(sim) -> void:
	cur["deaths"] = sim.units.filter(func(u): return u.dead).size() - int(cur["dead0"])
	cur["food"] = roundi(sim.stock["food"])
	cur["food_cap"] = sim.food_cap()
	cur["pop"] = sim.living().size()
	cur["pop_cap"] = sim.pop_cap()
	cur["wood"] = roundi(sim.stock["wood"])
	cur["fields"] = sim.structures.filter(func(s): return s.built and sim.ours(s) and s.type == "farm_plot").size()
	cur["field_hands"] = float(cur.get("hands_sum", 0.0)) / maxf(1.0, float(cur.get("hands_n", 0))) # (the day's mean, by day)
	cur["mood"] = roundi(sim.folk.mood)
	# the rival clans: do they keep pace? (people in all, the largest, the cap they grow to,
	# warriors, their homes, mean era, clans still standing)
	var rp := 0
	var rmax := 0
	var rw := 0
	var re := 0.0
	var left := 0
	for id in sim.rivals.clans:
		if sim.rivals.gone(id): continue
		var c: Dictionary = sim.rivals.clans[id]
		left += 1
		rp += int(c["pop"])
		rmax = maxi(rmax, int(c["pop"]))
		rw += int(c["warriors"])
		re += float(c["era"])
	cur["rivals_pop"] = rp
	cur["rival_max"] = rmax
	cur["rival_cap"] = sim.rivals.max_pop()
	cur["rival_warriors"] = rw
	cur["rival_homes"] = sim.structures.filter(func(s): return s.built and not sim.ours(s) and s.type in ["hut", "large_hut", "longhouse"]).size()
	cur["rival_era"] = re / maxf(1.0, float(left))
	cur["rivals_left"] = left
	day_rows.append(cur)
