## How people react to what happens around them (sim.react). The rules report a happening
## with trigger(event, ctx) (ctx: "at" place, "victim" person, "danger" place, "attacker"
## beast, "cause"); config/reactions.json says, per event, which responses follow, who
## takes part and all the numbers and texts. A response drops the person's work for a
## moment (interrupt: kept in u.resume_job, restored by sim._end_errand) to do one of the
## verbs coded here:
##
##   cover     - out of the huts and away from buildings, crouch until the shaking stops
##               ("then": trigger another event afterwards, e.g. tend the hurt)
##   aid       - run to someone hurt and dress the wound
##   flee      - run directly away from the danger (or from the river)
##   firefight - beat out a fire threatening home (a tree put out in time survives)
##   defend    - come and fight a beast or raider that attacks someone
##   warm      - someone freezing goes to the nearest fire and stays until warm again
##   shelter   - hide in one's hut (or cower outdoors) until ctx "until"
##
## Wildfire is not a one-off: while anything burns, update() runs the "wildfire" responses
## once a second for everyone near a fire (the first one that takes a person wins).
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")
const Config = preload("res://scripts/config.gd")

const VERBS := ["cover", "aid", "flee", "firefight", "defend", "warm", "shelter"]
const WHO := ["all", "able", "victim", "near", "river", "helpers"]

var C: Dictionary = Config.load_cfg("reactions")
var sim
var _t := 0.0

func _init(s) -> void:
	sim = s

## Problems in a reactions config (unknown verbs or selectors), for tests and modders.
static func problems(cfg: Dictionary) -> Array:
	var out: Array = []
	for ev in cfg.get("on", {}):
		for r in cfg["on"][ev]:
			if not r is Dictionary or not r.get("do", "") in VERBS: out.append("%s: unknown response %s" % [ev, str(r)])
			elif not r.get("who", "all") in WHO: out.append("%s: unknown who '%s'" % [ev, r["who"]])
	return out

## The farthest "reach" of an event's responses (0 if none): how far the rules need look.
func reach_of(event: String) -> float:
	var m := 0.0
	for r in responses(event): m = maxf(m, float(r.get("reach", 0)))
	return m

## The responses configured for an event ([] if none).
func responses(event: String) -> Array:
	return C.get("on", {}).get(event, [])

## Who can drop their work to help: able grown-ups of the village (not crews, scouts,
## envoys or traders), not hurt or sick, not busy with something that matters more.
func able(u: E.Unit) -> bool:
	var ca: Dictionary = C.get("able", {})
	if u.dead or u.role != "" or sim.in_hut(u) or u.sick > 0 or u.hp < u.max_hp * float(ca.get("min_hp", 0.5)): return false
	return not (u.job.get("type", "") in ca.get("busy", [])) and not u.job.get("flee", false)

## Drop the current work for `job` (marked as a reaction), keeping the work to come back to.
func interrupt(u: E.Unit, job: Dictionary) -> void:
	if u.resume_job.is_empty() and not u.job.is_empty() and not u.job.get("react", false) and not u.job.get("flee", false):
		u.resume_job = u.job
		u.resume_key = u.job_key
		u.resume_t = u.job_t
	job["react"] = true
	sim.set_job(u, job, u.job_key)
	u.sleeping = false

# ------------------------------------------------------------ dispatch
## Something happened: run its configured responses. A person taken by one response is
## not picked by the next.
func trigger(event: String, ctx: Dictionary = {}) -> void:
	var taken := {}
	for r in responses(event):
		for u in _pick(r, ctx):
			if taken.has(u.id): continue
			if _respond(r, u, ctx): taken[u.id] = true

## The people a response applies to.
func _pick(r: Dictionary, ctx: Dictionary) -> Array:
	var at: Vector2 = ctx.get("danger", ctx.get("at", D.VILLAGE))
	var reach: float = float(r.get("reach", INF))
	var out: Array = []
	match r.get("who", "all"):
		"victim": # (within "reach" of the danger, if both are given)
			var v = ctx.get("victim")
			if v != null and not v.dead and (not ctx.has("danger") or v.pos.distance_to(ctx["danger"]) < reach): out = [v]
		"near": out = sim.living().filter(func(u): return u.pos.distance_to(at) < reach)
		"river": out = sim.living().filter(func(u): return D.river_dist(u.pos) < reach)
		"able": out = sim.living().filter(func(u): return able(u) and u.pos.distance_to(at) < reach)
		"helpers": out = _helpers(r, ctx)
		_: out = sim.living()
	return out.filter(func(u): return _fits(r, u))

func _fits(r: Dictionary, u: E.Unit) -> bool:
	if r.has("roles") and not (u.role in r["roles"]): return false
	if u.role in r.get("skip_roles", []) and not sim.in_hut(u): return false
	if u.job.get("type", "") in r.get("skip_jobs", []): return false
	return true

## The nearest able people on the victim's side of the water, minus those already helping.
func _helpers(r: Dictionary, ctx: Dictionary) -> Array:
	var v = ctx.get("victim")
	if v == null: return []
	var near: Array = []
	for o in sim.living():
		if o == v or not able(o) or (o.role == "child"): continue
		var reach: float = float(r.get("reach", 300))
		for t in r.get("reach_by_trait", {}):
			if o.has_trait(t): reach = float(r["reach_by_trait"][t])
		var d: float = o.pos.distance_to(v.pos)
		if d < reach and D.same_side(o.pos, v.pos): near.append([d, o])
	near.sort_custom(func(a, b): return a[0] < b[0])
	return near.map(func(e): return e[1])

func _respond(r: Dictionary, u: E.Unit, ctx: Dictionary) -> bool:
	match r.get("do", ""):
		"cover": return _start_cover(r, u)
		"aid": return _start_aid(r, u, ctx)
		"flee": return _start_flee(r, u, ctx)
		"firefight": return _start_firefight(r, u, ctx)
		"defend": return _start_defend(r, u, ctx)
		"warm": return _start_warm(r, u)
		"shelter": return _start_shelter(r, u, ctx)
	push_warning("reactions.json: unknown response '%s'" % r.get("do", ""))
	return false

func _act(r: Dictionary, i: int, who: String = "") -> String:
	var acts: Array = r.get("acts", [])
	if i >= acts.size(): return ""
	var a: String = acts[i]
	return a.replace("%s", who) if a.contains("%s") else a

# ------------------------------------------------------------ cover (earthquake)
func _start_cover(r: Dictionary, u: E.Unit) -> bool:
	if u.job.get("type", "") == "cover": return false
	var spot := open_spot(u.pos, float(r.get("clear", 110)), float(r.get("max_move", 160)))
	if sim.in_hut(u):
		if not r.get("wake", true): return false
		var hut = sim.struct_by_id(u.bed_id)
		if hut: u.pos = hut.pos + Vector2(0, 14) # out of the door
		u.bed_pos = null
	interrupt(u, {"type": "cover", "to": spot, "t": 0.0, "r": r})
	return true

## Somewhere close to p, at least `clear` from buildings (moving at most `max_move`), on
## the same side of the water and out of it.
func open_spot(p: Vector2, clear := 110.0, max_move := 160.0) -> Vector2:
	var away := Vector2.ZERO
	for s in sim.structures:
		if not s.built or s.type in ["farm_plot", "burial_ground", "bonfire"]: continue
		var d: float = s.pos.distance_to(p)
		if d < clear: away += (p - s.pos).normalized() * (clear - d) if d > 1.0 else Vector2(1, 0) * clear
	var q := p + away.limit_length(max_move)
	q = Vector2(clampf(q.x, 30, D.W - 30), clampf(q.y, 40, D.H - 40))
	if D.region_at(q) != D.region_at(p): q = p
	return sim._dry(q)

func do_cover(u: E.Unit, j: Dictionary, dt: float) -> void:
	var r: Dictionary = j.get("r", {})
	if not sim.approach(u, j["to"], 6, dt):
		u.act = _act(r, 0)
		return
	u.act = _act(r, 1)
	j["t"] += dt
	if j["t"] >= float(r.get("time", 7)) and sim.nat.shake <= float(r.get("until_shake", 0.3)):
		sim._end_errand(u)
		if r.has("then"): # the shaking is over: now see to anyone who was hurt
			for v in sim.living():
				if v.hp < v.max_hp * float(r.get("then_below", 0.8)) and v.pos.distance_to(u.pos) < float(r.get("then_reach", 320)):
					trigger(r["then"], {"victim": v, "at": v.pos})

# ------------------------------------------------------------ aid (the wounded)
func _start_aid(r: Dictionary, u: E.Unit, ctx: Dictionary) -> bool:
	var v = ctx.get("victim")
	if v == null or v.dead or v.hp >= v.max_hp * float(r.get("below", 0.9)): return false
	var tending: int = sim.units.filter(func(o): return not o.dead and o.job.get("type", "") == "aid" and o.job.get("victim", -1) == v.id).size()
	if tending >= int(r.get("count", 2)): return false
	interrupt(u, {"type": "aid", "victim": v.id, "t": 0.0, "r": r})
	if r.has("popup"): sim.popup(u.pos + Vector2(0, -26), tr(r["popup"]) % tr(v.name), Color("#9ad88a"))
	return true

func do_aid(u: E.Unit, j: Dictionary, dt: float) -> void:
	var r: Dictionary = j.get("r", {})
	var v: E.Unit = sim.unit_by_id(j["victim"])
	if v == null or v.dead or v.hp >= v.max_hp * 0.95:
		sim._end_errand(u)
		return
	if not sim.approach(u, v.pos + Vector2(14, 6), 10, dt):
		u.act = _act(r, 0, v.name)
		return
	u.act = _act(r, 1, v.name)
	j["t"] += dt
	if j["t"] >= float(r.get("time", 5)):
		v.hp = minf(v.max_hp, v.hp + v.max_hp * float(r.get("heal", 0.2)) * sim.inv.heal_mult())
		for k in r.get("xp", {}): sim.gain_xp(u, k, float(r["xp"][k]))
		if r.has("remember"): sim.remember(v, tr(r["remember"]) % [tr(u.name), sim.day()], 4)
		sim._end_errand(u)

# ------------------------------------------------------------ flee
## Run directly away from the danger (not toward a home that may lie beyond it). "dist" is
## how far; "beyond" runs to `reach + beyond` from the danger instead; who: "river" runs
## away from the nearest river ("resume": false drops the work instead of going back to it).
func _start_flee(r: Dictionary, u: E.Unit, ctx: Dictionary) -> bool:
	if u.job.get("flee", false) or u.job.get("type", "") in ["cover", "firefight"]: return false
	if r.get("who", "") == "river":
		var info := D.river_info(u.pos)
		var to: Vector2 = sim._dry(info["c"] + info["n"] * float(r.get("dist", 380)))
		if r.get("resume", true): interrupt(u, {"type": "move", "to": to, "flee": true})
		else: sim.set_job(u, {"type": "move", "to": to, "flee": true}) # (the work is by the water: drop it)
		return true
	var danger: Vector2 = ctx.get("danger", ctx.get("at", u.pos))
	var dist: float = float(r.get("dist", 260))
	if r.has("beyond"): dist = float(r.get("reach", 0)) - u.pos.distance_to(danger) + float(r["beyond"])
	flee_from(u, danger, dist)
	if r.has("popup"): sim.popup(u.pos + Vector2(0, -30), tr(r["popup"]), Color("#ff9b7a"))
	return true

func flee_from(u: E.Unit, danger: Vector2, dist: float) -> void:
	var dir := (u.pos - danger).normalized() if u.pos.distance_to(danger) > 1.0 else Vector2(1, 0)
	var to := u.pos + dir * dist
	to = Vector2(clampf(to.x, 30, D.W - 30), clampf(to.y, 40, D.H - 40))
	if D.region_at(to) != D.region_at(u.pos): to = u.home
	interrupt(u, {"type": "move", "to": sim._dry(to), "flee": true})

# ------------------------------------------------------------ defend (beasts, raiders)
func _start_defend(r: Dictionary, u: E.Unit, ctx: Dictionary) -> bool:
	var p = ctx.get("attacker")
	var v = ctx.get("victim")
	if p == null or v == null or p.dead or p.kind in r.get("skip_attackers", []): return false
	var fighting: int = sim.units.filter(func(o): return not o.dead and o.job.get("type", "") == "attack" and o.job.get("target_id", -1) == p.id).size()
	if fighting >= int(r.get("count", 3)) + 1: return false # (the victim fights back too)
	if u.resume_job.is_empty() and not u.job.is_empty():
		u.resume_job = u.job
		u.resume_key = u.job_key
		u.resume_t = u.job_t
	sim.assign_attack(u, p, u.job_key)
	u.sleeping = false
	if r.has("popup"): sim.popup(u.pos + Vector2(0, -26), tr(r["popup"]) % tr(v.name), Color("#ffd36b"))
	return true

# ------------------------------------------------------------ wildfire
## Once a second while something burns: the "wildfire" responses for everyone near a fire.
func update(dt: float) -> void:
	_t -= dt
	if _t > 0.0: return
	_t = 1.0
	var nat = sim.nat
	if nat.burning.is_empty(): return
	var fires: Array = []
	for id in nat.burning:
		var n = sim.node_by_id(id)
		if n: fires.append(n)
	if fires.is_empty(): return
	for u in sim.living():
		if sim.in_hut(u) or u.job.get("type", "") in ["attack", "firefight"]: continue
		var near = null
		var nd := INF
		for n in fires:
			var d: float = n.pos.distance_to(u.pos)
			if d < nd and D.same_side(n.pos, u.pos):
				nd = d
				near = n
		if near == null: continue
		var ctx := {"at": near.pos, "danger": near.pos, "fire": near}
		for r in responses("wildfire"):
			if nd < float(r.get("reach", INF)) and _fits(r, u) and (r.get("who", "") != "able" or able(u)) and _respond(r, u, ctx): break

func _start_firefight(r: Dictionary, u: E.Unit, ctx: Dictionary) -> bool:
	var fire = ctx.get("fire")
	if fire == null: return false
	var threat: bool = fire.pos.distance_to(D.VILLAGE) < float(r.get("near_home", 700)) \
		or sim.structures.any(func(s): return s.built and sim.ours(s) and s.pos.distance_to(fire.pos) < float(r.get("near_building", 200)))
	if not threat: return false
	var fighting: int = sim.units.filter(func(o): return not o.dead and o.job.get("type", "") == "firefight").size()
	if fighting >= int(r.get("count", 6)): return false
	interrupt(u, {"type": "firefight", "r": r})
	if r.has("popup"): sim.popup(u.pos + Vector2(0, -26), tr(r["popup"]), Color("#ffb070"))
	return true

func do_firefight(u: E.Unit, j: Dictionary, dt: float) -> void:
	var r: Dictionary = j.get("r", {})
	var nat = sim.nat
	var best = null
	var bd := INF
	for id in nat.burning:
		var n = sim.node_by_id(id)
		if n and D.same_side(n.pos, u.pos) and n.pos.distance_to(u.pos) < bd:
			bd = n.pos.distance_to(u.pos)
			best = n
	if best == null or bd > float(r.get("give_up", 630)):
		sim._end_errand(u)
		return
	# beat at the flames from the edge, not from inside them
	var off: float = float(r.get("stand_off", 62))
	var stand: Vector2 = best.pos + (u.pos - best.pos).normalized() * off if u.pos.distance_to(best.pos) > 1.0 else best.pos + Vector2(off, 0)
	if not sim.approach(u, stand, 8, dt):
		u.act = _act(r, 0)
		return
	u.act = _act(r, 1)
	nat.burning[best.id] -= dt * float(r.get("rate", 1.6))
	if nat.burning[best.id] <= 0.0:
		nat.burning.erase(best.id) # put out in time: the tree survives, scorched
		for k in r.get("xp", {}): sim.gain_xp(u, k, float(r["xp"][k]))
		if r.has("out_popup"): sim.popup(best.pos + Vector2(0, -40), tr(r["out_popup"]), Color("#a8d8ff"))
		if nat.burning.is_empty() and r.has("log"): sim.add_log(tr(r["log"]), "story")

# ------------------------------------------------------------ warm (freezing)
func _start_warm(r: Dictionary, u: E.Unit) -> bool:
	if u.job.get("type", "") == "warm" or u.hp >= u.max_hp * float(r.get("below", 0.55)) or sim.near_warmth(u): return false
	var fire = sim._nearest_fire(u.pos)
	if fire == null: return false
	interrupt(u, {"type": "warm", "to": fire.pos + Vector2(randf_range(-30, 30), randf_range(10, 40)), "r": r})
	if r.has("popup"): sim.popup(u.pos + Vector2(0, -30), tr(r["popup"]), Color("#a8d8ff"))
	return true

func do_warm(u: E.Unit, j: Dictionary, dt: float) -> void:
	var r: Dictionary = j.get("r", {})
	if u.hp >= u.max_hp * float(r.get("until", 0.8)) or not sim.hz.cold_can_kill():
		sim._end_errand(u) # (warm again, or the cold is over)
		return
	if not sim.approach(u, j["to"], 4, dt):
		u.act = _act(r, 0)
		return
	u.act = _act(r, 1)

# ------------------------------------------------------------ shelter (panic)
func _start_shelter(r: Dictionary, u: E.Unit, ctx: Dictionary) -> bool:
	var jt: String = u.job.get("type", "")
	if jt == "shelter" or u.job.get("react", false) or u.job.get("flee", false): return false
	interrupt(u, {"type": "shelter", "until": float(ctx.get("until", sim.time + float(r.get("time", 25)))), "r": r})
	return true

func do_shelter(u: E.Unit, j: Dictionary, dt: float) -> void:
	var r: Dictionary = j.get("r", {})
	if sim.time >= float(j["until"]):
		sim.wake(u)
		sim._end_errand(u)
		return
	if u.sleeping: return
	if u.bed_pos == null: sim._pick_bed(u)
	if not sim.approach(u, u.bed_pos, 5, dt):
		u.act = _act(r, 0)
		return
	if u.bed_id >= 0:
		u.sleeping = true # (in_hut: hidden, out of reach of beasts)
		u.act = _act(r, 1)
	else:
		u.act = _act(r, 2)
