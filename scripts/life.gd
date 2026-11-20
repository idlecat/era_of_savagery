## Everyday life of the people (sim.life): the rhythm of the day (meals in a ring at the
## fire, a moment on waking, the evening fire), what people do when nobody needs them
## (idle acts), the bonds between the tribe's families, each person's spirits (morale) and
## weariness (fatigue), and the short things they say (speech marks over their heads).
## Each person stands for one family line; a child starts a new line, kin to its parent's.
##
## Everything tunable is in config/life.json; the verbs of the idle acts are coded here:
##   sit    - go to a spot (the fire, a hut's eaves, a grave, the camp's edge, right here) and stay
##   chat   - find someone idle nearby and talk (the bond grows, or they quarrel)
##   work   - a small chore at home (mend tools, scrape a hide): a pose and a little xp
##   water  - fetch water from the nearest river and carry it home
##   watch  - watch the children play (one's own kin first)
##   gaze   - walk a little way out and look at the land or the water
##   ritual - the devout pray (it lasts until new orders, as it always did)
##   art    - carve, string beads or paint (folk.gd)
##   wander - stroll about the camp
##
## For a game master: summary() reads it all; the story actions "bond", "morale", "say" and
## "depart" change it (story.gd), add_lines() gives people new things to say.
## `on` = false (tests) leaves the old behaviour: no meals, idle wandering, no effects.
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")
const Config = preload("res://scripts/config.gd")

const VERBS := ["sit", "chat", "work", "water", "watch", "gaze", "ritual", "art", "wander"]
const CONDS := ["dusk", "morning", "cold", "wet", "tired", "hurt", "hungry", "grieving", "low_spirits",
	"high_spirits", "children", "kin_child", "can_art"]
const MAX_LINE := 90 # characters in a line added from outside

var C: Dictionary = Config.load_cfg("life")
var sim
var on := true
var pending := "" # "discontent": a family wants to leave (sim._check_events asks the chieftain)
var pending_who := -1
var asked_day := -99
var extra_lines := {} # situation -> [texts] (add_lines: a game master's)
var _t := 0.0

func _init(s) -> void:
	sim = s

## Problems in a life config (unknown verbs or conditions), for tests and modders.
static func problems(cfg: Dictionary) -> Array:
	var out: Array = []
	for a in cfg.get("idle", {}).get("acts", []):
		if not a.get("do", "") in VERBS: out.append("idle act %s: unknown verb '%s'" % [a.get("id", "?"), a.get("do", "")])
		for c in a.get("more", {}).keys() + a.get("needs", []):
			if not (c in CONDS or str(c).begins_with("trait:")): out.append("idle act %s: unknown condition '%s'" % [a.get("id", "?"), c])
	return out

## The first families: a friend or two each, and maybe someone they can't stand.
func setup() -> void:
	var b: Dictionary = C["bonds"]
	var adults: Array = sim.living().filter(func(u): return u.role == "")
	for u in sim.living():
		u.morale = sim.folk.mood
		if u.role == "child" and u.parent_id >= 0: set_bond(u, sim.unit_by_id(u.parent_id), float(b["kin"]))
	for u in adults:
		var others: Array = adults.filter(func(o): return o != u and not u.bonds.has(o.id))
		others.shuffle()
		var nf := maxi(0, int(b["start"]["friends"]) - friends_of(u).size())
		for o in others.slice(0, nf): set_bond(u, o, Config.rand_in(b["start"]["friend"]))
		if randf() < float(b["start"]["rival_chance"]) and others.size() > nf:
			set_bond(u, others[nf], Config.rand_in(b["start"]["rival"]))

# ------------------------------------------------------------ bonds
func bond(a: E.Unit, b: E.Unit) -> float:
	if a == null or b == null: return 0.0
	return float(a.bonds.get(b.id, 0.0))

func set_bond(a: E.Unit, b: E.Unit, v: float) -> void:
	if a == null or b == null or a == b: return
	v = clampf(v, -100.0, 100.0)
	a.bonds[b.id] = v
	b.bonds[a.id] = v

## Change a bond (both ways), and tell the chronicle when a friendship or a feud begins.
func add_bond(a: E.Unit, b: E.Unit, d: float) -> void:
	if a == null or b == null or a == b: return
	var bc: Dictionary = C["bonds"]
	var was := bond(a, b)
	set_bond(a, b, was + d)
	var now := bond(a, b)
	if was < float(bc["friend_at"]) and now >= float(bc["friend_at"]):
		sim.add_log(tr("%s and %s have become friends.") % [tr(a.name), tr(b.name)], "story", [a, b])
		sim.remember(a, tr("became friends with %s on Day %d") % [tr(b.name), sim.day()], 4)
		sim.remember(b, tr("became friends with %s on Day %d") % [tr(a.name), sim.day()], 4)
	elif was > float(bc["rival_at"]) and now <= float(bc["rival_at"]):
		sim.add_log(tr("%s and %s have quarrelled.") % [tr(a.name), tr(b.name)], "story", [a, b])
		sim.remember(a, tr("quarrelled with %s on Day %d") % [tr(b.name), sim.day()], 4)
		sim.remember(b, tr("quarrelled with %s on Day %d") % [tr(a.name), sim.day()], 4)

## A newborn family line is kin to the one it came from.
func on_birth(u: E.Unit) -> void:
	u.morale = sim.folk.mood
	if u.parent_id >= 0: set_bond(u, sim.unit_by_id(u.parent_id), float(C["bonds"]["kin"]))

## Is b of a's kin (one line came from the other)?
func kin(a: E.Unit, b: E.Unit) -> bool:
	return a != null and b != null and (a.parent_id == b.id or b.parent_id == a.id)

func _people(u: E.Unit, test: Callable) -> Array:
	var out: Array = []
	for id in u.bonds:
		var o: E.Unit = sim.unit_by_id(id)
		if o and not o.dead and test.call(float(u.bonds[id]), o): out.append(o)
	return out

func friends_of(u: E.Unit) -> Array: return _people(u, func(v, _o): return v >= float(C["bonds"]["friend_at"]))
func rivals_of(u: E.Unit) -> Array: return _people(u, func(v, _o): return v <= float(C["bonds"]["rival_at"]))
func kin_of(u: E.Unit) -> Array: return sim.living().filter(func(o): return kin(u, o))

# ------------------------------------------------------------ the tick
func update(dt: float) -> void:
	if not on: return
	_t -= dt
	if _t > 0.0: return
	var step := 1.0 - _t # (the second that passed)
	_t = 1.0
	var alive: Array = sim.living()
	for u in alive:
		_fatigue(u, step)
		_morale(u, step)
		_meal_call(u)
		_needs_talk(u)
	_bond_tick(alive, step)
	_watch_passers(alive)

func _fatigue(u: E.Unit, step: float) -> void:
	var f: Dictionary = C["fatigue"]
	if u.role == "child": return
	if u.sleeping: u.fatigue -= float(f["sleep"]) * step
	elif _resting(u): u.fatigue -= float(f["rest"]) * step
	else: u.fatigue += float(f["work"]) * step * (float(f["lazy"]) if u.has_trait("lazy") else 1.0) * (1.0 + (float(f["sick"]) if u.sick > 0 else 0.0))
	u.fatigue = clampf(u.fatigue, 0.0, 100.0)

func _resting(u: E.Unit) -> bool:
	return u.job.get("type", "") in C["fatigue"]["rest_jobs"] or (u.job.is_empty())

func morale_target(u: E.Unit) -> float:
	var m: Dictionary = C["morale"]
	var t: float = sim.folk.mood
	if u.hunger < float(m["hungry_below"]): t += float(m["hungry"])
	if u.sick > 0: t += float(m["sick"])
	if u.hp < u.max_hp * float(m["hurt_below"]): t += float(m["hurt"])
	if u.fatigue >= float(C["fatigue"]["tired_at"]): t += float(m["tired"])
	var nf := friends_of(u).size() + kin_of(u).size()
	t += minf(float(m["friend_max"]), nf * float(m["friend"])) if nf > 0 else float(m["lonely"])
	if u.company < 0: t += float(m["rival_near"])
	t += u.cheer - u.grief
	return clampf(t, 0.0, 100.0)

func _morale(u: E.Unit, step: float) -> void:
	var m: Dictionary = C["morale"]
	u.grief = maxf(0.0, u.grief - float(m["grief_fade"]) * step)
	u.cheer = maxf(0.0, u.cheer - float(m["cheer_fade"]) * step)
	if u.grief <= 0.0: u.mourn_id = -1
	var target := morale_target(u)
	u.morale += clampf(target - u.morale, -float(m["step"]) * step, float(m["step"]) * step)
	# a family that stays in despair may want to leave
	var lv: Dictionary = C["leave"]
	if u.role != "" or u.title != "": return
	if u.morale < float(lv["below"]): u.low_t += step
	else: u.low_t = maxf(0.0, u.low_t - step)
	if u.low_t >= float(lv["days"]) * D.DAY_LEN and pending == "" and sim.day() - asked_day >= int(lv["every_days"]) \
			and sim.living().size() >= int(lv["min_pop"]):
		u.low_t = 0.0
		asked_day = sim.day()
		pending = "discontent"
		pending_who = u.id

func mood_word(u: E.Unit) -> String:
	for w in C["morale"]["words"]:
		if u.morale >= float(w[0]): return tr(w[1])
	return tr(C["morale"]["lowest_word"])

## A person's own deed lifts their spirits for a while ("level_up", "kill", ...).
func praise(u: E.Unit, deed: String) -> void:
	if not on or u == null or u.dead: return
	var p: Dictionary = C["praise"]
	u.cheer = minf(float(C["morale"]["cheer_max"]), u.cheer + float(p.get(deed, 0)))
	if randf() < float(p["talk_chance"]): say(u, "praise")

## Someone died: their friends and kin grieve.
func on_death(dead: E.Unit, mult := 1.0) -> void:
	if not on: return
	var b: Dictionary = C["bonds"]
	for o in sim.living():
		if o == dead: continue
		var v := bond(o, dead)
		var g := 0.0
		if kin(o, dead): g = float(b["kin_grief"])
		if v >= float(b["grieve_at"]): g = maxf(g, float(b["grief"]) + v * float(b["grief_per"]))
		if g <= 0.0: continue
		o.grief = minf(float(C["morale"]["grief_max"]), o.grief + g * mult)
		o.mourn_id = dead.id
		say(o, "grief", tr(dead.name))

## Friends and kin working near each other speed up, rivals slow down; bonds grow from
## shared work, fights and festivals. Once a second.
func _bond_tick(alive: Array, step: float) -> void:
	var b: Dictionary = C["bonds"]
	var near := float(b["near"])
	var workers: Array = alive.filter(func(u): return u.role != "child" and not u.sleeping and not _resting(u))
	for u in alive: u.company = 0
	for i in workers.size():
		var a: E.Unit = workers[i]
		var ja: Dictionary = a.job
		for k in range(i + 1, workers.size()):
			var o: E.Unit = workers[k]
			if a.pos.distance_to(o.pos) > near: continue
			var jo: Dictionary = o.job
			var v := bond(a, o)
			if v >= float(b["friend_at"]) or kin(a, o):
				a.company += 1
				o.company += 1
			elif v <= float(b["rival_at"]):
				a.company -= 10
				o.company -= 10
			var gain := 0.0
			if ja.get("type", "") == jo.get("type", ""): gain = float(b["work"])
			if ja.get("type", "") == "attack" and ja.get("target_id", -1) == jo.get("target_id", -2): gain = float(b["fight"])
			if a.doing == "dance" and o.doing == "dance": gain = float(b["festival"])
			if gain > 0.0: add_bond(a, o, gain * step)

## How much faster (or slower) this person works: spirits, weariness, company.
func work_mult(u: E.Unit) -> float:
	if not on: return 1.0
	var m: Dictionary = C["morale"]
	var f: Dictionary = C["fatigue"]
	var b: Dictionary = C["bonds"]
	var k: float = 1.0 + (u.morale - sim.folk.mood) * float(m["work_per"])
	k *= 1.0 - float(f["work_loss"]) * maxf(0.0, u.fatigue - float(f["work_from"])) / maxf(1.0, 100.0 - float(f["work_from"]))
	if u.company > 0: k *= 1.0 + minf(float(b["work_bonus_max"]), u.company * float(b["work_bonus"]))
	elif u.company < 0: k *= 1.0 + float(b["rival_work"])
	return maxf(0.3, k)

## How fast this person walks: weary and starving people drag, frightened ones hurry.
func speed_mult(u: E.Unit) -> float:
	if not on: return 1.0
	var p: Dictionary = C["pace"]
	var k := 1.0
	var from := float(p["tired_from"])
	if u.fatigue > from: k *= 1.0 - float(p["tired_slow"]) * (u.fatigue - from) / maxf(1.0, 100.0 - from)
	if u.hunger < float(p["hungry_below"]): k *= float(p["hungry"])
	if u.job.get("flee", false) or u.job.get("react", false) or sim.night_alarm or sim.crisis.active(): k *= float(p["hurry"])
	return k

# ------------------------------------------------------------ morning
## Woken at dawn (not by an alarm): a moment to stretch before the day's work.
func woke(u: E.Unit) -> void:
	if not on or sim.night_alarm: return
	var w: Dictionary = C["wake"]
	u.wake_until = sim.time + Config.rand_in(w["time"])
	if randf() < float(w["talk_chance"]): say(u, str(w["talk"]))

## True while someone is still waking up (their job waits).
func waking(u: E.Unit) -> bool:
	if not on or sim.time >= u.wake_until: return false
	if u.job.get("flee", false) or u.job.get("react", false) or u.job.get("type", "") in ["attack", "bury"]:
		u.wake_until = -1.0
		return false
	u.act = C["wake"]["act"]
	return true

# ------------------------------------------------------------ meals
func _meal_slot() -> int:
	var f: float = sim.day_frac()
	var times: Array = C["meals"]["times"]
	for i in times.size():
		if f >= float(times[i][0]) and f < float(times[i][1]): return sim.day() * 10 + i
	return -1

## In a meal time, hungry people at home come to the fire to eat together.
func _meal_call(u: E.Unit) -> void:
	var slot := _meal_slot()
	if slot < 0 or u.meal_slot == slot: return
	var mc: Dictionary = C["meals"]
	if not u.role in mc["roles"] or u.sleeping or sim.folk.festival_on() or sim.crisis.active() or sim.night_alarm: return
	if u.job.get("flee", false) or u.job.get("react", false) or u.job.get("crisis", false): return
	var jt: String = u.job.get("type", "")
	if not jt in mc["jobs"]: return
	if u.role == "child" and not u.job.is_empty(): return
	u.meal_slot = slot # (asked once a meal time)
	if u.hunger >= float(mc["hungry_below"]) or sim.stock["food"] < 1.0: return
	var fire = sim.nearest_fire(u.pos)
	if fire == null or fire.pos.distance_to(u.pos) > float(mc["reach"]) or not D.same_side(fire.pos, u.pos): return
	var a := float(u.id) * 2.39996 + randf_range(-0.2, 0.2) # (round the fire, each at their place)
	var seat: Vector2 = sim.dry_spot(fire.pos + Vector2(cos(a), sin(a) * 0.8) * Config.rand_in(mc["seat"]))
	_take_over(u, {"type": "meal", "to": seat, "face": fire.pos, "t": 0.0, "eat": Config.rand_in(mc["eat_time"]), "pose": mc["pose"]})

## Put work down for a moment (kept in resume_job; idle acts are not worth coming back to).
func _take_over(u: E.Unit, job: Dictionary) -> void:
	sim.set_aside(u)
	var key := u.job_key
	sim.set_job(u, job, key)

func do_meal(u: E.Unit, j: Dictionary, dt: float) -> void:
	var mc: Dictionary = C["meals"]
	if sim.rest_time() or sim.time - u.job_t > float(mc["give_up"]):
		sim.end_errand(u)
		return
	if not sim.approach(u, j["to"], 5, dt):
		u.act = mc["acts"][0]
		return
	u.act = mc["acts"][1]
	u.face = j["face"]
	j["t"] += dt
	if j["t"] < float(j["eat"]): return
	eat(u)
	if randf() < float(mc["talk_chance"]): say(u, str(mc["talk"]))
	for o in sim.living(): # eating together brings families closer
		if o != u and o.job.get("type", "") == "meal" and o.pos.distance_to(u.pos) < float(mc["bond_reach"]): add_bond(u, o, float(mc["bond"]))
	sim.end_errand(u)

## A meal from the common store: up to full, food in proportion to what is eaten.
func eat(u: E.Unit) -> void:
	var sv: Dictionary = sim.RULES["survival"]
	var fill: float = float(sv["meal_fill_fire"] if sim.has_tech("fire") else sv["meal_fill"])
	var want: float = minf(fill, 100.0 - u.hunger)
	var cost: float = minf(sim.stock["food"], float(sv["meal"]) * want / fill)
	if cost <= 0.0: return
	sim.stock["food"] -= cost
	sim.evo.drift("ranked", -0.15 * cost / float(sv["meal"]))
	u.hunger = minf(100.0, u.hunger + fill * cost / float(sv["meal"]))

# ------------------------------------------------------------ idle acts
## A grown-up at home with nothing to do: after a moment, pick something from the idle
## acts (config/life.json "idle").
func idle(u: E.Unit, dt: float) -> void:
	u.act = "Resting (sick)" if u.sick > 0 else "Idle"
	if sim.nat.shake > 0.0 or sim.nat.panicking(): return # (no pastimes while the ground shakes or the tribe panics)
	u.idle_t += dt
	if u.wander_t <= 0.0: u.wander_t = Config.rand_in(C["idle"]["every"])
	if u.idle_t < u.wander_t: return
	u.idle_t = 0.0
	u.wander_t = 0.0
	var a := pick(u)
	if not a.is_empty(): start(u, a)

## The weighted pick of an idle act for u ({} if none fits).
func pick(u: E.Unit) -> Dictionary:
	var total := 0.0
	var opts: Array = []
	for a in C["idle"]["acts"]:
		if a.get("needs", []).any(func(c): return not cond(u, c)): continue
		if a.has("when") and not sim.story.holds(a["when"]): continue
		var w := float(a.get("weight", 1))
		for c in a.get("more", {}):
			if cond(u, c): w += float(a["more"][c])
		if w <= 0.0: continue
		total += w
		opts.append([w, a])
	var r := randf() * total
	for o in opts:
		r -= o[0]
		if r <= 0.0: return o[1]
	return {}

func cond(u: E.Unit, c: String) -> bool:
	if c.begins_with("trait:"): return u.has_trait(c.substr(6))
	match c:
		"dusk", "morning": return sim.is_day_part(c)
		"cold": return sim.hz.winter() or sim.hz.cold_rate(u, false) > 0.0
		"wet": return sim.hz.on() and sim.hz.wet()
		"tired": return u.fatigue >= float(C["fatigue"]["tired_at"])
		"hurt": return u.hp < u.max_hp * 0.6
		"hungry": return u.hunger < float(C["morale"]["hungry_below"])
		"grieving": return u.grief > 1.0 and _grave_of(u.mourn_id) != Vector2.INF
		"low_spirits": return u.morale < float(C["morale"]["low"])
		"high_spirits": return u.morale > float(C["morale"]["high"])
		"children": return sim.living().any(func(o): return o.role == "child" and o.pos.distance_to(u.pos) < 400)
		"kin_child": return sim.living().any(func(o): return o.role == "child" and kin(u, o))
		"can_art": return sim.folk.can_art(u)
	return false

## Where someone lies buried (Vector2.INF if nowhere).
func _grave_of(id: int) -> Vector2:
	if id < 0: return Vector2.INF
	var bg = sim.burial_ground()
	if bg == null: return Vector2.INF
	for i in bg.graves.size():
		if bg.graves[i].get("id", -1) == id: return sim.grave_slot(bg, i)
	return Vector2.INF

## Start an idle act. Returns false if it could not start (nobody to talk to...).
func start(u: E.Unit, a: Dictionary) -> bool:
	var dur := Config.rand_in(a.get("time", [6, 10]))
	var job := {"type": "life", "act": a.get("id", ""), "t": 0.0, "time": dur, "pose": a.get("pose", ""), "phase": 0}
	match a.get("do", ""):
		"ritual":
			sim.assign_ritual(u, u.home + Vector2(randf_range(-40, 40), randf_range(-50, -20)))
			return true
		"art":
			sim.folk.start_art(u)
			return true
		"sit":
			var to: Variant = _spot(u, str(a.get("at", "here")))
			if to == null: return false
			job["to"] = to
			if a.get("at", "") == "fire":
				var fire = sim.nearest_fire(u.pos)
				job["face"] = fire.pos
			if a.get("at", "") == "grave":
				var dead: E.Unit = sim.unit_by_id(u.mourn_id)
				job["who"] = dead.name if dead else ""
				job["face"] = to
				job["to"] = to + Vector2(randf_range(-12, 12), 14)
		"work":
			job["to"] = _home_spot(u)
		"water":
			var c: Vector2 = D.nearest_river_point(u.pos)
			if c == u.pos or c.distance_to(u.pos) > float(a.get("reach", 600)) or not D.same_side(D.shore(c, 10.0), u.pos): return false
			job["to"] = D.shore(c, 10.0)
			job["back"] = _home_spot(u)
		"watch":
			var kids: Array = sim.living().filter(func(o): return o.role == "child" and o.pos.distance_to(u.pos) < float(a.get("reach", 400)))
			if kids.is_empty(): return false
			var mine: Array = kids.filter(func(o): return kin(u, o))
			var k: E.Unit = (mine if not mine.is_empty() else kids).pick_random()
			job["kid"] = k.id
			job["to"] = k.pos + (u.pos - k.pos).normalized() * 50.0 if u.pos.distance_to(k.pos) > 1.0 else k.pos + Vector2(50, 0)
		"gaze":
			var dir := Vector2.from_angle(randf() * TAU)
			var c: Vector2 = D.nearest_river_point(u.home)
			if c != u.home and c.distance_to(u.home) < 450: dir = (c - u.home).normalized() # (out towards the water)
			var to: Vector2 = u.home + dir * Config.rand_in(a.get("dist", [120, 220]))
			to = Vector2(clampf(to.x, 30, D.W - 30), clampf(to.y, 40, D.H - 40))
			if D.region_at(to) != D.region_at(u.home) or D.is_water(to): return false
			job["to"] = sim.dry_spot(to)
			job["face"] = to + dir * 200.0
		"wander":
			job["to"] = u.home + Vector2(randf_range(-80, 80), randf_range(-70, 70))
			job["slow"] = true
		"chat":
			var p = _chat_partner(u, float(a.get("reach", 240)))
			if p == null: return false
			var mid: Vector2 = (u.pos + p.pos) * 0.5
			var side := Vector2(14, 4)
			job["with"] = p.id
			job["who"] = p.name
			job["to"] = mid - side
			job["face"] = mid + side
			job["lead"] = true
			sim.set_job(u, job)
			var pj := job.duplicate()
			pj["with"] = u.id
			pj["who"] = u.name
			pj["to"] = mid + side
			pj["face"] = mid - side
			pj["lead"] = false
			sim.set_job(p, pj)
			p.idle_t = 0.0
			return true
		_:
			return false
	job["acts"] = a.get("acts", [])
	job["xp"] = a.get("xp", {})
	if a.has("talk"):
		job["talk"] = a["talk"]
		job["talk_chance"] = float(a.get("talk_chance", 0.3))
	sim.set_job(u, job)
	return true

func _spot(u: E.Unit, at: String) -> Variant:
	match at:
		"fire":
			var fire = sim.nearest_fire(u.pos)
			if fire == null or not D.same_side(fire.pos, u.pos): return null
			var a := randf() * TAU
			return sim.dry_spot(fire.pos + Vector2(cos(a), sin(a) * 0.8) * randf_range(40, 80))
		"shelter":
			var best = null
			for s in sim.structures:
				if s.built and sim.ours(s) and s.type in ["hut", "large_hut", "granary"] and D.same_side(s.pos, u.pos) and (best == null or s.pos.distance_to(u.pos) < best.pos.distance_to(u.pos)): best = s
			if best == null: return null
			return best.pos + Vector2(randf_range(-18, 18), sim.struct_r(best) + 6)
		"grave":
			var g := _grave_of(u.mourn_id)
			return null if g == Vector2.INF else g
		"edge":
			var dir := Vector2.from_angle(randf() * TAU)
			var to: Vector2 = u.home + dir * randf_range(150, 230)
			if D.region_at(to) != D.region_at(u.home) or D.is_water(to): return null
			return sim.dry_spot(to)
	return u.pos

## A spot by one's own home (a hut, else the fire) to do chores.
func _home_spot(u: E.Unit) -> Vector2:
	return u.home + Vector2(randf_range(-60, 60), randf_range(20, 55))

## Someone idle nearby to talk to (not a rival); friends are sought out first.
func _chat_partner(u: E.Unit, reach: float) -> Variant:
	var best = null
	var bs := -INF
	for o in sim.living():
		if o == u or o.role != "" or o.sleeping or o.pos.distance_to(u.pos) > reach or not D.same_side(o.pos, u.pos): continue
		if not (o.job.is_empty() or (o.job.get("type", "") == "life" and o.job.get("act", "") in ["stroll", "fire"])): continue
		var v := bond(u, o)
		if v <= float(C["bonds"]["rival_at"]): continue
		var score := v + randf() * 40.0
		if score > bs:
			bs = score
			best = o
	return best

func do_act(u: E.Unit, j: Dictionary, dt: float) -> void:
	var acts: Array = j.get("acts", [])
	var label := func(i: int) -> String:
		if acts.is_empty(): return "Idle"
		var s: String = acts[mini(i, acts.size() - 1)]
		return s.replace("%s", j.get("who", "")) if s.contains("%s") else s
	if j.has("with"): # a chat: both meet, face each other, talk; the one who began ends it
		var p: E.Unit = sim.unit_by_id(j["with"])
		if p == null or p.dead or p.job.get("type", "") != "life" or p.job.get("with", -1) != u.id:
			_done(u)
			return
		if not sim.approach(u, j["to"], 5, dt) or p.pos.distance_to(p.job["to"]) > 6:
			u.act = label.call(0)
			return
		u.act = label.call(1)
		u.face = j["face"]
		j["t"] += dt
		if j["t"] >= float(j.get("next_say", 0.0)):
			j["next_say"] = j["t"] + randf_range(2.5, 4.5) + (0.0 if j["lead"] else 1.5)
			if bond(u, p) >= float(C["bonds"]["close_at"]) and randf() < 0.5: say(u, "friend")
			else: say(u, "chat")
		if j["lead"] and j["t"] >= float(j["time"]):
			_end_chat(u, p)
		return
	match j["phase"]:
		0:
			var spd: float = sim.unit_speed(u) * (0.4 if j.get("slow", false) else 1.0)
			if u.pos.distance_to(j["to"]) > 5.0:
				u.act = label.call(0)
				sim.go_to(u, j["to"])
				sim.step_move(u, dt, spd)
				return
			u.path.clear()
			if j.has("back"): # (water: now home with it)
				j["to"] = j["back"]
				j.erase("back")
				j["load"] = "water"
				acts = acts.slice(1)
				j["acts"] = acts
				return
			j["phase"] = 1
			if j.has("talk") and randf() < float(j["talk_chance"]): say(u, str(j["talk"]), tr(j.get("who", "")))
		1:
			u.act = label.call(1)
			u.doing = str(j.get("act", ""))
			if j.has("kid"): # watching a child: keep them in sight
				var k: E.Unit = sim.unit_by_id(j["kid"])
				if k == null or k.dead or k.role != "child":
					_done(u)
					return
				u.face = k.pos
				if u.pos.distance_to(k.pos) > 90.0:
					sim.go_to(u, k.pos + (u.pos - k.pos).normalized() * 50.0)
					sim.step_move(u, dt, sim.unit_speed(u) * 0.6)
			elif j.has("face"): u.face = j["face"]
			for k in j.get("xp", {}): sim.gain_xp(u, k, float(j["xp"][k]) * dt)
			j["t"] += dt
			if j["t"] >= float(j["time"]):
				if j["act"] == "mourn": u.grief *= 0.6 # (it eases the heart)
				_done(u)

func _done(u: E.Unit) -> void:
	sim.set_job(u, {})
	u.idle_t = 0.0

## The end of a talk: closer, or a quarrel.
func _end_chat(u: E.Unit, p: E.Unit) -> void:
	var b: Dictionary = C["bonds"]
	var q: Dictionary = b["quarrel"]
	var ch: float = float(q["base"])
	for x in [u, p]:
		if x.has_trait("belligerent"): ch += float(q["belligerent"])
		if x.morale < float(C["morale"]["low"]): ch += float(q["low_spirits"])
	if bond(u, p) < 0.0: ch += float(q["rival"])
	if randf() < ch:
		add_bond(u, p, -float(q["loss"]))
		for x in [u, p]: x.morale = clampf(x.morale + float(q["morale"]), 0.0, 100.0)
		say(u, "quarrel")
		say(p, "quarrel", "", true)
	else:
		add_bond(u, p, float(b["chat"]))
	_done(u)
	_done(p)

# ------------------------------------------------------------ small things around them
## Idle people standing about look round at a leader walking past.
func _watch_passers(alive: Array) -> void:
	var leaders: Array = alive.filter(func(o): return (o.title != "" or o.hero) and not o.path.is_empty())
	if leaders.is_empty(): return
	for u in alive:
		if not sim.is_idle(u) or u.sleeping or not u.path.is_empty(): continue
		for l in leaders:
			if l != u and l.pos.distance_to(u.pos) < 90.0:
				u.face = l.pos
				break

# ------------------------------------------------------------ speech
## Say a line of `situation` (config "talk" plus lines added by a game master); "%s" in it
## is `arg`. `force` ignores the person's pause between lines (a reply).
func say(u: E.Unit, situation: String, arg := "", force := false) -> bool:
	if not on or u == null or u.dead or u.sleeping: return false
	var sp: Dictionary = C["speech"]
	if not force and sim.time < u.say_t: return false
	var shown := 0
	for o in sim.units:
		if o.say_until > sim.time: shown += 1
	if shown >= int(sp["max_shown"]) and not force: return false
	var lines: Array = []
	for t in u.traits:
		var tl: Array = C["talk"].get(situation + ":" + t, [])
		if not tl.is_empty() and randf() < 0.5: lines = tl
	if lines.is_empty(): lines = C["talk"].get(situation, []) + extra_lines.get(situation, [])
	if lines.is_empty(): return false
	var line: String = tr(str(lines.pick_random()))
	if line.contains("%s"): line = line.replace("%s", arg)
	say_text(u, line)
	return true

## Fall silent at once (danger interrupts whatever they were saying).
func hush(u: E.Unit) -> void:
	u.say = ""
	u.say_until = -1.0

## Put words in someone's mouth (a story action, a game master).
func say_text(u: E.Unit, text: String) -> void:
	var sp: Dictionary = C["speech"]
	u.say = text.substr(0, MAX_LINE)
	u.say_until = sim.time + float(sp["time"])
	u.say_t = sim.time + float(sp["gap"])
	sim.spoke.emit(u, u.say)

## Now and then people say what they need.
func _needs_talk(u: E.Unit) -> void:
	if u.role == "child" or randf() >= float(C["speech"]["need_chance"]): return
	if u.sick > 0: say(u, "sick")
	elif u.hunger < float(C["morale"]["hungry_below"]): say(u, "hungry")
	elif sim.hz.cold_rate(u, sim.near_warmth(u)) > 0.0: say(u, "cold")
	elif u.fatigue >= float(C["fatigue"]["tired_at"]) + 15: say(u, "tired")

## New lines for a situation (a game master's, written in the player's language). The
## input is untrusted: known situations only, strings only, clipped. Returns problems.
func add_lines(situation: String, lines: Array) -> Array:
	var base := situation.split(":")[0]
	if not C["talk"].has(base): return ["unknown situation '%s'" % situation]
	var out: Array = extra_lines.get(situation, [])
	for l in lines:
		if l is String and l.strip_edges() != "" and out.size() < 30: out.append(l.strip_edges().substr(0, MAX_LINE))
	extra_lines[situation] = out
	return []

# ------------------------------------------------------------ a family leaves
func owns_event(id: String) -> bool: return id == "discontent"

func _event_vars() -> Dictionary:
	var u: E.Unit = sim.unit_by_id(pending_who)
	return {"person": tr(u.name) if u else "", "who": "id:%d" % pending_who}

func event_def(_id: String) -> Dictionary:
	return sim.story.dilemma_view(sim.DILEMMAS["discontent"], _event_vars())

func resolve(_id: String, idx: int) -> String:
	var r: Dictionary = sim.story.dilemma_choose(sim.DILEMMAS["discontent"], idx, _event_vars())
	pending_who = -1
	return r["text"]

## A family walks away from the tribe (the "depart" action). Their friends and kin grieve a little.
func depart(u: E.Unit) -> void:
	if u == null or u.dead or u.gone or not u.role in ["", "child"]: return
	u.role = "leaving"
	sim.vacate(u)
	u.resume_job = {}
	sim.wake(u)
	sim.set_job(u, {"type": "depart", "to": sim.way_out(u.pos, 20.0)})
	sim.add_log(tr("The family of %s leaves the tribe. They take their fire and go.") % tr(u.name), "danger", [u])
	sim.popup(u.pos + Vector2(0, -30), tr("%s leaves") % tr(u.name), Color("#d8c0a0"), true)
	if on: on_death(u, float(C["bonds"]["depart_grief"]))

func do_depart(u: E.Unit, j: Dictionary, dt: float) -> void:
	u.act = C["leave"]["act"]
	if not sim.approach(u, j["to"], 30, dt) and sim.time - u.job_t < float(C["leave"]["walk"]): return
	u.gone = true
	u.dead = true
	u.buried = true
	u.hp = 0.0
	u.job = {}
	u.fell_t = sim.time
	u.death_cause = tr("left the tribe")
	sim.evo.on_death(u)

# ------------------------------------------------------------ for a game master
func summary() -> Dictionary:
	var people: Array = []
	for u in sim.living():
		people.append({"name": u.name, "morale": roundi(u.morale), "spirits": mood_word(u), "fatigue": roundi(u.fatigue),
			"friends": friends_of(u).map(func(o): return o.name), "rivals": rivals_of(u).map(func(o): return o.name),
			"kin": kin_of(u).map(func(o): return o.name), "grief": roundi(u.grief),
			"saying": u.say if u.say_until > sim.time else ""})
	var times: Array = C["meals"]["times"]
	return {"people": people, "meal_times": times, "wants_to_leave": tr(sim.unit_by_id(pending_who).name) if pending_who >= 0 and sim.unit_by_id(pending_who) else ""}
