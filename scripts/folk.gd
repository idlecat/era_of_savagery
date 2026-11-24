## Village life: children, the tribe's mood, arts and decorations, festivals, and trade
## trips to the neighbouring clans. Owned by the simulation like `nat` (nature.gd).
##
## Children  - newborns are children (role "child") for CHILD_DAYS: they do no work, take no
##             orders, and play around the camp (chase, play at hunters, watch the adults work
##             and pick up a little of their skill). Then they come of age.
## Mood      - 0..100. Work speed is 0.9x at 0 and 1.1x at 100. Hunger, sickness and deaths
##             pull it down; festivals, art, painted homes, treasures and new life lift it.
## Arts      - idle adults carve figurines, string beads (both make trade "goods") or paint
##             the huts (decorations). Rarely someone makes a named treasure.
## Festivals - at the start of spring, autumn and winter the chieftain may hold a festival:
##             the tribe dances around the bonfire; mood, devotion and togetherness rise and
##             friendly clans come to share it.
## Trade     - a villager carries goods, food, wood or stone to a clan's village and brings
##             back what they sell, priced by what they want and how they feel about us.
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")

## All the numbers and texts of tribe life: config/rules.json "folk".
var F: Dictionary = preload("res://scripts/config.gd").load_cfg("rules")["folk"]
var CHILD_DAYS: float = float(F["child_days"])
## What things are worth in a trade, in food.
var VALUE: Dictionary = F["trade"]["value"]

var sim
var festivals := true # tests switch this off
var mood := 60.0
var sorrow := 0.0 # recent deaths weigh on the tribe
var glow_until := -1.0 # after a festival
var mood_t := 0.0
var grumble_day := 0
var treasures: Array = [] # [{name, maker, day}]
var season_seen := -1
var pending := ""
var festival_until := -1.0
var festival_name := ""

func _init(s) -> void:
	sim = s

# ------------------------------------------------------------ mood
func work_mult() -> float: return float(F["mood"]["work_base"]) + mood * float(F["mood"]["work_per"])

func mood_word() -> String:
	for w in F["mood"]["words"]:
		if mood >= float(w[0]): return tr(w[1])
	return tr(F["mood"]["lowest_word"])

func lift(amount: float) -> void: mood = clampf(mood + amount, 0.0, 100.0)

func decor_total() -> int:
	var n := 0
	for s in sim.structures:
		if s.built and sim.ours(s): n += s.decor
	return n

func mood_target() -> float:
	var m: Dictionary = F["mood"]
	var t: float = float(m["base"]) + minf(float(m["decor_max"]), decor_total() * float(m["decor"])) + minf(float(m["treasure_max"]), treasures.size() * float(m["treasure"])) + sim.inv.mood_bonus()
	if sim.time < glow_until: t += float(m["glow"])
	var alive: Array = sim.living()
	if sim.stock["food"] < alive.size(): t -= float(m["hungry"])
	t -= minf(float(m["sick_max"]), float(m["sick"]) * alive.filter(func(u): return u.sick > 0).size())
	t -= sorrow
	if sim.nat.panicking(): t -= float(m["panic"])
	return clampf(t, 0.0, 100.0)

func on_death() -> void:
	sorrow = minf(float(F["mood"]["sorrow_max"]), sorrow + float(F["mood"]["death_sorrow"]))
	lift(-float(F["mood"]["death_mood"]))

# ------------------------------------------------------------ tick
func update(dt: float) -> void:
	mood_t -= dt
	if mood_t <= 0:
		mood_t = 1.0
		var m: Dictionary = F["mood"]
		sorrow = maxf(0.0, sorrow - float(m["sorrow_fade"]))
		var target := mood_target()
		mood += clampf(target - mood, -float(m["step"]), float(m["step"]))
		if mood < float(m["grumble_below"]) and sim.day() != grumble_day and not sim.rest_time():
			grumble_day = sim.day()
			sim.add_log(tr(m["grumble"]), "story")
		for u in sim.living():
			if u.role == "child" and sim.time - u.born_t >= CHILD_DAYS * D.DAY_LEN: come_of_age(u)
	if festivals:
		var si: int = int(sim.time / D.DAY_LEN) / sim.hz.SEASON_DAYS
		if si != season_seen:
			var first := season_seen < 0
			season_seen = si
			if not first and _festival_def().has(str(sim.hz.season_idx())): pending = "festival"

# ------------------------------------------------------------ children
## A newborn: a child of the tribe who plays until they come of age.
func make_child(nm: String, parent: E.Unit) -> E.Unit:
	var u: E.Unit = sim.make_unit({"name": nm, "epithet": "Child", "traits": [sim.evo.birth_trait()],
		"color": Color(D.BIRTH_COLORS.pick_random()), "hp": 18, "atk": 1, "def": 1, "spd": randf_range(0.9, 1.05),
		"skills": {"forage": 0, "craft": 0, "combat": 0, "lore": 0}},
		D.VILLAGE + Vector2(randf_range(-30, 30), randf_range(20, 50)))
	u.role = "child"
	u.born_t = sim.time
	u.parent_id = parent.id if parent else -1
	u.hunger = 90.0
	sim.life.on_birth(u) # (a new family line, kin to its parent's)
	return u

func days_to_grow(u: E.Unit) -> int:
	return maxi(0, ceili((CHILD_DAYS * D.DAY_LEN - (sim.time - u.born_t)) / D.DAY_LEN))

func come_of_age(u: E.Unit) -> void:
	u.role = ""
	u.max_hp = randi_range(40, 52)
	u.hp = maxf(u.hp, u.max_hp * 0.8)
	u.atk = randi_range(3, 6)
	u.def = 2
	u.epithet = "Newcomer"
	sim.set_job(u, {})
	if sim.evo.has_trad("warrior_initiation"): u.skills["combat"]["lv"] += 1
	sim.remember(u, tr("came of age before the whole tribe on Day %d") % sim.day(), 7)
	sim.add_log(tr("%s comes of age. The tribe gathers at the fire to welcome a new grown member.") % tr(u.name), "story", [u])
	sim.popup(u.pos + Vector2(0, -30), tr("%s comes of age!") % tr(u.name), Color("#ffd6f0"), true)
	sim.devotion = minf(100.0, sim.devotion + 2)
	lift(5.0)
	sim.life.praise(u, "come_of_age")

## What a child does with no job: chase the others round the fire, play at hunters with a
## stick, or watch a grown-up at work (and learn a little of it).
func play(u: E.Unit, dt: float) -> void:
	u.idle_t -= dt
	if u.idle_t <= 0 or u.wander_to == null:
		u.idle_t = randf_range(7.0, 13.0)
		var roll := randf()
		var adults: Array = sim.living().filter(func(o): return o.role == "" and not o.job.is_empty() and o.pos.distance_to(u.home) < 320 and o.job.get("type", "") in ["gather", "build", "ritual", "art"])
		if roll < 0.35 and not adults.is_empty():
			var a: E.Unit = adults.pick_random()
			u.watch_id = a.id
			u.play = "watch"
			u.act = "Watching " + a.name
		elif roll < 0.7:
			u.watch_id = -1
			u.play = "chase"
			u.act = "Playing chase"
		else:
			u.watch_id = -1
			u.play = "hunters"
			u.act = "Playing at hunters"
		u.wander_to = u.home + Vector2(randf_range(-110, 110), randf_range(-80, 80))
	if u.play == "watch": u.doing = "watch"
	match u.play:
		"chase": # round and round the fire
			var a: float = sim.time * 0.9 + u.id
			u.wander_to = u.home + Vector2(cos(a) * 70.0, sin(a) * 45.0 + 20.0)
			sim.go_to(u, u.wander_to)
			sim.step_move(u, dt, sim.unit_speed(u) * 0.9)
		"hunters":
			if u.pos.distance_to(u.wander_to) < 8: u.wander_to = u.home + Vector2(randf_range(-120, 120), randf_range(-90, 90))
			sim.go_to(u, u.wander_to)
			sim.step_move(u, dt, sim.unit_speed(u) * 0.7)
		_:
			var w: E.Unit = sim.unit_by_id(u.watch_id)
			if w == null or w.dead or w.job.is_empty() or w.pos.distance_to(u.home) > 400:
				u.idle_t = 0.0
				return
			if u.pos.distance_to(w.pos) > 30:
				sim.go_to(u, w.pos + Vector2(18, 10))
				sim.step_move(u, dt, sim.unit_speed(u) * 0.8)
			else:
				var skill: String = {"gather": "forage", "build": "craft", "ritual": "lore", "art": "craft"}.get(w.job.get("type", ""), "forage")
				sim.gain_xp(u, skill, 0.25 * dt)

# ------------------------------------------------------------ arts and decorations
func can_art(u: E.Unit) -> bool:
	return u.role == "" and mood > 20 and not sim.rest_time() and u.pos.distance_to(u.home) < 250 and u.sick <= 0 \
		and sim.stock["food"] >= sim.living().size() * 2 # (no crafts while the stores are thin)

## Start a piece of work: painting goes to a hut that is not yet fully decorated.
func start_art(u: E.Unit) -> void:
	var kind := "carve" if u.lv("craft") >= u.lv("lore") else "paint"
	var ca: Dictionary = F["art"]
	if randf() < float(ca["beads_chance"]): kind = "beads"
	var hut = null
	if kind == "paint":
		for s in sim.structures:
			if s.built and sim.ours(s) and D.STRUCTURES[s.type].get("decor", false) and s.decor < int(ca["max_decor"]) and s.pos.distance_to(u.home) < 350:
				hut = s
				break
		if hut == null: kind = "carve"
	var at: Vector2 = hut.pos + Vector2(14, 16) if hut else u.home + Vector2(randf_range(-50, 50), randf_range(15, 45))
	sim.set_job(u, {"type": "art", "kind": kind, "at": at, "t": 0.0, "hut": hut.id if hut else -1})

func do_art(u: E.Unit, j: Dictionary, dt: float) -> void:
	if not sim.approach(u, j["at"], 6, dt):
		u.act = "Walking to work"
		return
	u.act = {"carve": "Carving a figurine", "beads": "Stringing beads", "paint": "Painting the huts"}[j["kind"]]
	u.doing = "paint" if j["kind"] == "paint" else "craft"
	j["t"] += dt * sim.work_mul(u)
	if j["t"] < float(F["art_time"]): return
	var ca: Dictionary = F["art"]
	var skill := "lore" if j["kind"] == "paint" else "craft"
	sim.gain_xp(u, skill, float(ca["xp"]))
	sim.evo.practice(u, "ritual" if j["kind"] == "paint" else "build", 4.0)
	lift(float(ca["mood"]))
	if j["kind"] == "paint":
		var s = sim.struct_by_id(j["hut"])
		if s and s.built and s.decor < int(ca["max_decor"]):
			s.decor += 1
			sim.evo.drift("spiritual", 0.6)
			sim.popup(s.pos + Vector2(0, -40), tr("Painted!"), Color("#ff9b7a"))
	else:
		var n: int = int(ca["goods_skilled"] if u.lv("craft") >= int(ca["skilled_lv"]) else ca["goods"])
		sim.stock["goods"] += n
		sim.evo.drift("ranked", -0.3) # (shared crafts: more communal)
		sim.popup(u.pos + Vector2(0, -30), tr("+%d goods") % n, Color("#e6c46a"))
	if randf() < float(ca["masterpiece"]["base"]) + float(ca["masterpiece"]["per_lv"]) * u.lv(skill): _masterpiece(u, j["kind"])
	sim.set_job(u, {})

func _masterpiece(u: E.Unit, kind: String) -> void:
	var names: Array = F["treasures"][kind]
	var what: String = names.pick_random()
	treasures.append({"name": what, "maker": u.name, "day": sim.day()})
	lift(float(F["art"]["masterpiece"]["mood"]))
	sim.devotion = minf(100.0, sim.devotion + float(F["art"]["masterpiece"]["devotion"]))
	sim.remember(u, tr("made the %s, a treasure of the tribe, on Day %d") % [tr(what), sim.day()], 8)
	sim.inv.feat("masterpiece", tr("Made a masterpiece: the %s") % tr(what), u,
		{"desc": tr("A treasure of the tribe, made by %s. The whole tribe comes to see it, and its mood rises.") % tr(u.name)})
	sim.alert(tr("%s has made a masterpiece: the %s! The whole tribe comes to see it.") % [tr(u.name), tr(what)], u.pos, "info", [u])
	sim.life.praise(u, "masterpiece")
	sim.ranks.deed(u, "masterpiece")
	sim.react.trigger("masterpiece", {"at": u.pos})

# ------------------------------------------------------------ festivals
func festival_on() -> bool: return sim.time < festival_until

func owns_event(id: String) -> bool: return id == "festival"

## The festival dilemma is config/dilemmas.json "festival"; its "seasons" say which
## seasons have one, its name and the elders' question.
func _festival_def() -> Dictionary: return sim.DILEMMAS["festival"].get("seasons", {})

func _festival_vars() -> Dictionary:
	var f: Dictionary = _festival_def().get(str(sim.hz.season_idx()), _festival_def().values()[0])
	var pop: int = sim.living().size()
	return {"festival": tr(f["name"]), "festival_text": tr(f["text"]), "feast_cost": pop * 2, "gather_cost": pop}

func event_def(_id: String) -> Dictionary: return sim.story.dilemma_view(sim.DILEMMAS["festival"], _festival_vars())

func resolve(_id: String, idx: int) -> String:
	return sim.story.dilemma_choose(sim.DILEMMAS["festival"], idx, _festival_vars())["text"]

## The "festival" action: dancing for `length` s, and the glow of it for `glow_days`.
func hold(cfg: Dictionary, vars: Dictionary) -> void:
	festival_name = str(vars.get("festival", tr("Harvest Festival")))
	festival_until = sim.time + float(cfg.get("length", 30))
	glow_until = sim.time + D.DAY_LEN * float(cfg.get("glow_days", 1))

## The "guests" action: friendly clans we have met come (relations +amount); returns the
## line that says so ("" if none).
func invite(amount: float) -> String:
	var guests: Array = []
	for id in sim.rivals.clans:
		var c: Dictionary = sim.rivals.clans[id]
		if c["met"] and (sim.rivals.at_peace(id) or c["relation"] >= 15):
			sim.rivals.change(id, amount)
			guests.append(tr(c["name"]))
	return (" " + tr("Guests of the %s come to share it.") % ", ".join(guests)) if not guests.is_empty() else ""

## During a festival everyone at the village dances in a ring around the bonfire.
func dance(u: E.Unit, dt: float) -> void:
	var a: float = sim.time * 0.5 + float(u.id) * 0.9
	var r := 70.0 + float(u.id % 3) * 16.0 # (clear of the fire)
	sim.go_to(u, D.VILLAGE + Vector2(cos(a) * r, sin(a) * r * 0.7))
	sim.step_move(u, dt, sim.unit_speed(u) * 0.6)
	u.act = "Dancing at the festival" if u.role != "child" else "Playing at the festival"
	u.doing = "dance"

# ------------------------------------------------------------ trade trips
func trade_block(u: E.Unit, id: String) -> String:
	var c: Dictionary = sim.rivals.clans[id]
	if not c["met"]: return "We have not met them yet"
	if u.role != "": return "Busy elsewhere"
	if sim.rivals.stance(id) in ["Hostile", "Blood feud"]: return "They would rob our trader"
	return ""

func rate(id: String) -> float:
	return float(F["trade"]["stance_rate"].get(sim.rivals.stance(id), F["trade"]["other_rate"]))

## How much better a deal this person strikes: +6% per Trade & Barter level, and the
## Silver Tongue of a trader of rank `master_rank` (ranks.gd) adds another 10%.
func haggle(u: E.Unit) -> float:
	if u == null: return 1.0
	var lv: int = u.lv("trade")
	var ct: Dictionary = F["trade"]
	return 1.0 + float(ct["haggle_per_lv"]) * lv + (float(ct["master"]) if sim.ranks.has(u, "trade", ct["master_rank"]) else 0.0)

## What a clan would give for `amt` of `res`: {their resource: amount}.
## `trader`: who bargains for us (a skilled trader gets more, see haggle()).
func quote(id: String, res: String, amt: int, trader: E.Unit = null) -> Dictionary:
	var c: Dictionary = sim.rivals.clans[id]
	var sells: String = c["sells"]
	if res == sells: return {}
	var v: float = amt * float(VALUE[res]) * (float(F["trade"]["wanted"]) if res == c["wants"] else 1.0) * rate(id) * haggle(trader)
	return {sells: maxi(1, roundi(v / float(VALUE[sells])))}

func send_trader(u: E.Unit, id: String, res: String, amt: int) -> String:
	var why := trade_block(u, id)
	if why != "": return why
	if not sim.can_afford({res: amt}): return "Not enough to trade"
	if quote(id, res, amt).is_empty(): return "They have plenty of that"
	sim.spend({res: amt})
	u.role = "trader"
	u.carry_type = res
	u.carry_amt = mini(amt, 12)
	sim.set_job(u, {"type": "trade_trip", "clan": id, "phase": "go", "give": {res: amt}, "t": 0.0})
	sim.add_log(tr("%s sets out to trade %d %s with the %s.") % [tr(u.name), amt, tr(res), tr(sim.rivals.clans[id]["name"])], "story", [u])
	return ""

func do_trade(u: E.Unit, j: Dictionary, dt: float) -> void:
	var id: String = j["clan"]
	var c: Dictionary = sim.rivals.clans[id]
	match j["phase"]:
		"go":
			u.act = "Going to trade with the " + c["name"]
			if sim.approach(u, sim.rivals.parley_spot(id), 12, dt): j["phase"] = "barter"
		"barter":
			u.act = "Trading with the " + c["name"]
			j["t"] += dt
			if j["t"] < 8.0: return
			var res: String = j["give"].keys()[0]
			var amt: int = j["give"][res]
			if sim.rivals.stance(id) in ["Hostile", "Blood feud"]: # things turned bad while we walked
				sim.hurt_unit(u, u.max_hp * 0.3, null)
				j["get"] = {}
				sim.alert(tr("The %s took our goods and drove %s off empty-handed.") % [tr(c["name"]), tr(u.name)], c["pos"], "danger", [u])
				sim.remember(u, tr("was robbed by the %s when trading on Day %d") % [tr(c["name"]), sim.day()], 6)
				sim.gain_xp(u, "trade", 2.0) # a hard lesson
			else:
				j["get"] = quote(id, res, amt, u)
				sim.rivals.change(id, 4.0 if res == c["wants"] or res == "goods" else 2.0)
				var known: Array = sim.rivals.teachable(id)
				if not known.is_empty() and randf() < 0.35: sim.evo.seed(known[0], 0.08, u)
				sim.gain_xp(u, "trade", 12.0) # bargaining with strangers
				sim.gain_xp(u, "combat", 3.0) # and standing up to their chief (leadership)
			j["phase"] = "back"
			var got: Dictionary = j["get"]
			u.carry_type = got.keys()[0] if not got.is_empty() else ""
			u.carry_amt = mini(int(got.values()[0]), 12) if not got.is_empty() else 0
		"back":
			u.act = "Carrying the trade home"
			if not sim.approach(u, u.home, 20, dt): return
			var got: Dictionary = j.get("get", {})
			sim.give(got)
			u.carry_amt = 0
			u.role = ""
			sim.set_job(u, {})
			if not got.is_empty():
				var res: String = j["give"].keys()[0]
				var what := "%d %s" % [got.values()[0], tr(got.keys()[0])]
				sim.add_log(tr("%s is back from the %s: %d %s traded for %s.") % [tr(u.name), tr(c["name"]), j["give"][res], tr(res), what], "story", [u])
				sim.remember(u, tr("traded with the %s on Day %d") % [tr(c["name"]), sim.day()], 5)
				lift(2.0)

## For the LLM prompts and the saga.
func summary() -> Dictionary:
	return {"mood": "%s (%d)" % [mood_word(), roundi(mood)], "children": sim.living().filter(func(u): return u.role == "child").size(),
		"treasures": treasures.map(func(t): return tr(t["name"]) + " (" + tr(t["maker"]) + ")")}
