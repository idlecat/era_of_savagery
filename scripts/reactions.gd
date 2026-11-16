## How people react to what happens around them (sim.react): they drop what they are doing
## for a moment, do the sensible thing, and then go back to their work (the interrupted job
## is kept in u.resume_job and restored by sim._end_errand).
##
##   Earthquake   - people run out of huts and away from buildings, and crouch in the open
##                  until the shaking stops.
##   Hurt by nature (lightning, a falling building, fire, flood, lava) - one or two able
##                  grown-ups close by come and tend them: the wound is dressed.
##   Wildfire     - near the village, able grown-ups beat out the flames (a tree put out in
##                  time is saved); children and anyone too close run away from the fire.
##   Fire Mountain - when it trembles or erupts, people on its slopes flee from it.
## (Beasts and raiders: the people nearby come to fight, sim._call_for_help. Floods: the
## warning sends people away from the banks, nature._flood_tick.)
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")

const COVER_TIME := 7.0   # crouching in the open while the earth shakes
const AID_TIME := 5.0     # dressing a wound
const AID_HEAL := 0.2     # of max HP
const AID_REACH := 320.0
const FIRE_REACH := 420.0 # how far people come to fight a fire
const FIRE_NEAR_HOME := 700.0 # fires this close to the village (or a building) are fought
const FIREFIGHTERS := 6
const BEAT_RATE := 1.6    # seconds of fire beaten out per second of work

var sim
var _t := 0.0

func _init(s) -> void:
	sim = s

## Who can drop their work to help: able grown-ups of the village (not crews, scouts,
## envoys or traders), not hurt or sick, not already fighting, fleeing or helping.
func able(u: E.Unit) -> bool:
	if u.dead or u.role != "" or sim.in_hut(u) or u.sick > 0 or u.hp < u.max_hp * 0.5: return false
	var jt: String = u.job.get("type", "")
	return not (jt in ["attack", "bury", "explore", "trade_trip", "aid", "firefight", "cover"]) and not u.job.get("flee", false)

## Drop the current work for `job` (marked as a reaction), keeping the work to come back to.
func interrupt(u: E.Unit, job: Dictionary) -> void:
	if u.resume_job.is_empty() and not u.job.is_empty() and not u.job.get("react", false) and not u.job.get("flee", false):
		u.resume_job = u.job
		u.resume_key = u.job_key
		u.resume_t = u.job_t
	job["react"] = true
	sim.set_job(u, job, u.job_key)
	u.sleeping = false

# ------------------------------------------------------------ earthquake
## The ground shakes: everyone gets out from under roofs and walls and crouches in the open.
func on_quake() -> void:
	for u in sim.living():
		if u.role in ["contract", "envoy", "trader"] and not sim.in_hut(u): continue # (crews keep their own discipline)
		if u.job.get("type", "") == "attack": continue
		var spot := open_spot(u.pos)
		if sim.in_hut(u):
			var hut = sim.struct_by_id(u.bed_id)
			if hut: u.pos = hut.pos + Vector2(0, 14) # out of the door
			u.bed_pos = null
		interrupt(u, {"type": "cover", "to": spot, "t": 0.0})

## Somewhere close to p, away from buildings and out of the water.
func open_spot(p: Vector2) -> Vector2:
	var away := Vector2.ZERO
	for s in sim.structures:
		if not s.built or s.type in ["farm_plot", "burial_ground", "bonfire"]: continue
		var d: float = s.pos.distance_to(p)
		if d < 110.0: away += (p - s.pos).normalized() * (110.0 - d) if d > 1.0 else Vector2(1, 0) * 110.0
	var q := p + away.limit_length(160.0)
	q = Vector2(clampf(q.x, 30, D.W - 30), clampf(q.y, 40, D.H - 40))
	if D.region_at(q) != D.region_at(p): q = p
	return sim._dry(q)

func do_cover(u: E.Unit, j: Dictionary, dt: float) -> void:
	if not sim.approach(u, j["to"], 6, dt):
		u.act = "Running into the open"
		return
	u.act = "Crouching in the open"
	j["t"] += dt
	if j["t"] >= COVER_TIME and sim.nat.shake <= 0.3:
		sim._end_errand(u)
		for v in sim.living(): # the shaking is over: now see to anyone who was hurt
			if v.hp < v.max_hp * 0.8 and v.pos.distance_to(u.pos) < AID_REACH: on_hurt(v)

# ------------------------------------------------------------ the wounded
## Someone was hurt by nature (not killed): the nearest able grown-ups come to tend them.
func on_hurt(victim: E.Unit) -> void:
	if victim.dead or victim.hp >= victim.max_hp * 0.9: return
	var tending: int = sim.units.filter(func(o): return not o.dead and o.job.get("type", "") == "aid" and o.job.get("victim", -1) == victim.id).size()
	if tending >= 2: return
	var near: Array = []
	for o in sim.living():
		if o == victim or not able(o): continue
		var d: float = o.pos.distance_to(victim.pos)
		if d < AID_REACH and D.same_side(o.pos, victim.pos): near.append([d, o])
	near.sort_custom(func(a, b): return a[0] < b[0])
	for e in near.slice(0, 2 - tending):
		var o: E.Unit = e[1]
		interrupt(o, {"type": "aid", "victim": victim.id, "t": 0.0})
		sim.popup(o.pos + Vector2(0, -26), tr("Runs to help %s") % tr(victim.name), Color("#9ad88a"))

func do_aid(u: E.Unit, j: Dictionary, dt: float) -> void:
	var v: E.Unit = sim.unit_by_id(j["victim"])
	if v == null or v.dead or v.hp >= v.max_hp * 0.95:
		sim._end_errand(u)
		return
	if not sim.approach(u, v.pos + Vector2(14, 6), 10, dt):
		u.act = "Running to help " + v.name
		return
	u.act = "Tending " + v.name
	j["t"] += dt
	if j["t"] >= AID_TIME:
		v.hp = minf(v.max_hp, v.hp + v.max_hp * AID_HEAL * sim.inv.heal_mult())
		sim.gain_xp(u, "lore", 3.0)
		sim.remember(v, tr("was tended by %s after being hurt on Day %d") % [tr(u.name), sim.day()], 4)
		sim._end_errand(u)

# ------------------------------------------------------------ wildfire
## Once a second while something burns: who runs from it, and who fights it.
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
	var fighting: int = sim.units.filter(func(o): return not o.dead and o.job.get("type", "") == "firefight").size()
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
		var threat: bool = near.pos.distance_to(D.VILLAGE) < FIRE_NEAR_HOME or sim.structures.any(func(s): return s.built and sim.ours(s) and s.pos.distance_to(near.pos) < 200)
		if threat and fighting < FIREFIGHTERS and nd < FIRE_REACH and able(u):
			interrupt(u, {"type": "firefight"})
			sim.popup(u.pos + Vector2(0, -26), tr("Fights the fire!"), Color("#ffb070"))
			fighting += 1
		elif nd < 120.0 and not u.job.get("flee", false) and u.job.get("type", "") != "cover":
			flee_from(u, near.pos, 260.0)

func do_firefight(u: E.Unit, j: Dictionary, dt: float) -> void:
	var nat = sim.nat
	var best = null
	var bd := INF
	for id in nat.burning:
		var n = sim.node_by_id(id)
		if n and D.same_side(n.pos, u.pos) and n.pos.distance_to(u.pos) < bd:
			bd = n.pos.distance_to(u.pos)
			best = n
	if best == null or bd > FIRE_REACH * 1.5:
		sim._end_errand(u)
		return
	# beat at the flames from the edge, not from inside them
	var stand: Vector2 = best.pos + (u.pos - best.pos).normalized() * 62.0 if u.pos.distance_to(best.pos) > 1.0 else best.pos + Vector2(62, 0)
	if not sim.approach(u, stand, 8, dt):
		u.act = "Running to the fire"
		return
	u.act = "Beating out the flames"
	nat.burning[best.id] -= dt * BEAT_RATE
	if nat.burning[best.id] <= 0.0:
		nat.burning.erase(best.id) # put out in time: the tree survives, scorched
		sim.gain_xp(u, "combat", 1.0)
		sim.popup(best.pos + Vector2(0, -40), tr("Put out!"), Color("#a8d8ff"))
		if nat.burning.is_empty():
			sim.add_log(tr("The fire is beaten out. The tribe saved what it could."), "story")

## Run directly away from a danger (not toward a home that may lie beyond it).
func flee_from(u: E.Unit, danger: Vector2, dist: float) -> void:
	var dir := (u.pos - danger).normalized() if u.pos.distance_to(danger) > 1.0 else Vector2(1, 0)
	var to := u.pos + dir * dist
	to = Vector2(clampf(to.x, 30, D.W - 30), clampf(to.y, 40, D.H - 40))
	if D.region_at(to) != D.region_at(u.pos): to = u.home
	interrupt(u, {"type": "move", "to": sim._dry(to), "flee": true})

# ------------------------------------------------------------ Fire Mountain
## Tremors or an eruption: everyone on the mountain's slopes runs from it.
func on_volcano(reach: float) -> void:
	if not D.has_volcano(): return
	for u in sim.living():
		if u.pos.distance_to(D.VOLCANO) < reach and not u.job.get("flee", false):
			flee_from(u, D.VOLCANO, reach - u.pos.distance_to(D.VOLCANO) + 200.0)
