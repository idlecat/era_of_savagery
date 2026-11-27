## How the tribe sizes up a threat and picks who meets it (sim.threat, config/threat.json).
##
## A threat is the beasts or raiders that are one problem: wolves (or the warriors of one
## clan) within `group_r` of each other are met as one pack, a saber-tooth stands alone.
## Its `power` is what it takes to bring it down times what it deals out: the health of all
## of them times the blows they deal a second between them, through a defender of `def`
## (the same reckoning as sim.hunt.can_solo). Ours is the same for the people sent: all
## their health times all the blows they deal a second, the weapons they carry, their skill
## and their trades folded in. The tribe wants `margin` times the threat's power in hands,
## at least `min` and at most `most` - a pack of wolves takes a couple of people, a
## saber-tooth one or two, a war band a handful - and takes them from the best it has
## (score(): what they can do, how hale and well armed they are, how far they would have to
## walk; warriors by trade and the belligerent first, friends and kin of the person the
## threat is after).
##
## The War Chief dispatches by this every few seconds (dispatch(), rules.json "vice"); when
## someone is attacked, the `defend` responses take the best `count` of the hands the
## threat still needs (squad(), reactions.gd). A threat that is already met gets no more
## hands, however many people it strikes - that is what keeps a pack of wolves, or a war
## band that strikes four people at once, from pulling the whole village off its work.
##
## assess(), squad(), dispatch() and summary() are the operations, readable as plain data
## where they return it, so a game master can ask what the tribe makes of a threat.
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")
const Config = preload("res://scripts/config.gd")

var C: Dictionary = Config.load_cfg("threat")
var sim

func _init(s) -> void:
	sim = s

## Whether a beast or raider is one people are sent against at all: not a clan's peaceful
## hunter or trader, nor one already driven off.
func threatening(p: E.Predator) -> bool:
	return p != null and not p.dead and not p.fled and not p.fleeing and not p.kind in C.get("skip_kinds", [])

## The threats within `r` of `center`, gathered into the groups the tribe meets as one
## (the nearest group first). Each group is an Array of E.Predator.
func assess(center: Vector2, r: float) -> Array:
	var left: Array = sim.active_predators_near(center, r).filter(func(p): return threatening(p))
	var out: Array = []
	while not left.is_empty():
		var g: Array = [left.pop_front()]
		var grew := true
		while grew:
			grew = false
			for p in left.duplicate():
				for q in g:
					if _same_threat(p, q) and p.pos.distance_to(q.pos) < float(C["group_r"]):
						g.append(p)
						left.erase(p)
						grew = true
						break
		out.append(g)
	out.sort_custom(func(a, b): return _closest_to(a, center) < _closest_to(b, center))
	return out

## The group `p` belongs to and is met with (a lone beast: [p]).
func group_of(p: E.Predator) -> Array:
	if not threatening(p): return []
	var r := float(C["group_r"]) * 2.0
	for g in assess(p.pos, r):
		if g.has(p): return g
	return [p]

## What it takes to bring the group down times what it deals out: the health of all of
## them times the blows they deal a second between them (how long a fight lasts vs how
## much of us it wears down).
func power(ps: Array) -> float:
	var v: Dictionary = C["value"]
	var hp := 0.0
	var dps := 0.0
	for p in ps:
		if not threatening(p): continue
		hp += maxf(0.0, p.hp)
		dps += p.atk * (10.0 / (10.0 + float(v["def"]))) / float(v["blow_cd"]) * float(v["weight"].get(p.kind, 1.0))
	return hp * dps

## One of ours in the same reckoning: their health times the damage they deal a second
## against this group (the weapon they wield, its mastery and their trade included).
func fighter_power(u: E.Unit, ps: Array) -> float:
	var d := _hp_dps(u, ps)
	return d[0] * d[1]

## The force `people` make against the group: all their health times all their blows.
func force(people: Array, ps: Array) -> float:
	var hp := 0.0
	var dps := 0.0
	for u in people:
		var d := _hp_dps(u, ps)
		hp += d[0]
		dps += d[1]
	return hp * dps

## The force the tribe wants against the group: `margin` times its power.
func need(ps: Array) -> float:
	return power(ps) * float(C["margin"])

## How good a choice `u` is to meet this group: what they can do, how healthy they are,
## their temperament and trade, and how far they would have to walk.
func score(u: E.Unit, ps: Array, victim = null) -> float:
	var sc: Dictionary = C["score"]
	var s: float = fighter_power(u, ps) * lerpf(float(sc["wounded"]), 1.0, clampf(u.hp / maxf(1.0, u.max_hp), 0.0, 1.0))
	if u.has_trait("belligerent"): s *= 1.0 + float(sc["belligerent"])
	if sim.careers.is_preferred(u, "warchief"): s *= 1.0 + float(sc["preferred"])
	if victim is E.Unit and not victim.dead:
		if sim.life.kin(u, victim) or (sim.life.on and sim.life.bond(u, victim) >= float(sim.life.C["bonds"]["friend_at"])):
			s *= 1.0 + float(sc["bond"])
	return s / (1.0 + _near_dist(u, ps) / float(sc["distance"]))

## Whether `u` can be sent at all: a grown-up of the village, not sick or badly hurt, not
## already in a fight, an errand or a flight. `min_hp`: the share of health they must have.
func able(u: E.Unit, min_hp := -1.0) -> bool:
	var ca: Dictionary = C["able"]
	if u == null or u.dead or u.role != "" or sim.in_hut(u) or u.sick > 0.0: return false
	if u.hp < u.max_hp * (float(ca["min_hp"]) if min_hp < 0.0 else min_hp): return false
	return not u.job.get("flee", false) and not u.job.get("type", "") in ca["busy"]

## The people already fighting this group.
func engaged(ps: Array) -> Array:
	var ids := {}
	for p in ps: ids[p.id] = true
	return sim.living().filter(func(u): return u.job.get("type", "") == "attack" and ids.has(int(u.job.get("target_id", -1))))

## The people to send against the group: the best of `pool` (default: the able grown-ups
## within `reach` of it), strongest first, until the tribe's force reaches the group's need
## - at most `cap` (`most` when -1) and at least `min`. Those already fighting the group
## count towards it, so a threat that is met gets no more hands. The pool is filtered by
## able(); `victim` (whose friends come from further) only shapes the score.
func squad(ps: Array, pool: Variant = null, cap := -1, victim = null) -> Array:
	if ps.is_empty(): return []
	if pool == null:
		var at := _center(ps)
		pool = sim.living().filter(func(u):
			return able(u) and u.pos.distance_to(at) < float(C["reach"]) and D.same_side(u.pos, at))
	var taken := {}
	var fighting: Array = engaged(ps)
	for u in fighting: taken[u.id] = true
	var have: float = force(fighting, ps)
	var limit: int = maxi(0, (int(C["most"]) if cap < 0 else mini(cap, int(C["most"]))) - fighting.size())
	var want: float = need(ps)
	var cands: Array = pool.filter(func(u): return able(u) and not taken.has(u.id))
	cands.sort_custom(func(a, b):
		var sa := score(a, ps, victim)
		var sb := score(b, ps, victim)
		return sa > sb if sa != sb else a.id < b.id) # (ties by id: the same game plays the same)
	var out: Array = []
	if have >= want and not fighting.is_empty(): return out # (the threat is met already)
	for u in cands:
		if out.size() >= limit: break
		if out.size() >= int(C["min"]) and have >= want: break
		if fighter_power(u, ps) <= 0.0: continue
		out.append(u)
		have = force(fighting + out, ps)
	return out

## The War Chief's answer to the threats round `center`: every group within `range` of it,
## met by the best of the able people within `reach` of it (with at least `min_hp` of their
## health), at most `cap` hands to a group. Sends them (nearest beast of their group each)
## and returns them.
func dispatch(center: Vector2, range: float, reach: float, min_hp := 0.4, cap := -1) -> Array:
	var sent: Array = []
	for ps in assess(center, range):
		var at := _closest_pos(ps, center)
		var pool: Array = sim.living().filter(func(u):
			return able(u, min_hp) and u.pos.distance_to(at) < reach and D.same_side(u.pos, at))
		for u in squad(ps, pool, cap):
			sim.set_aside(u)
			sim.assign_attack(u, _nearest(u, ps), u.job_key)
			sent.append(u)
	return sent

## The threats round the village and the tribe's reckoning of them, for a game master.
func summary() -> Dictionary:
	var out: Array = []
	for ps in assess(D.VILLAGE, float(sim.RULES["vice"].get("warchief_range", 500))):
		var p: E.Predator = ps[0]
		var at := _closest_pos(ps, D.VILLAGE)
		out.append({"kind": p.kind, "clan": p.clan, "beasts": ps.size(), "at": [at.x, at.y],
			"power": snappedf(power(ps), 0.1), "need": snappedf(need(ps), 0.1), "engaged": engaged(ps).size()})
	return {"threats": out, "margin": float(C["margin"]), "most": int(C["most"])}

# ------------------------------------------------------------------ private
## Whether two beasts are the same problem: the same kind of beast, of the same clan.
func _same_threat(a: E.Predator, b: E.Predator) -> bool:
	return a.kind == b.kind and a.clan == b.clan

## How far the group is from a point: its nearest beast.
func _closest_to(ps: Array, at: Vector2) -> float:
	var d := INF
	for p in ps: d = minf(d, p.pos.distance_to(at))
	return d

## The middle of the group.
func _center(ps: Array) -> Vector2:
	var c := Vector2.ZERO
	var n := 0
	for p in ps:
		c += p.pos
		n += 1
	return c / float(maxi(1, n))

## The group's beast nearest to a point.
func _closest_pos(ps: Array, at: Vector2) -> Vector2:
	var best: Vector2 = at
	var d := INF
	for p in ps:
		if p.pos.distance_to(at) < d:
			d = p.pos.distance_to(at)
			best = p.pos
	return best

## A person's health and the damage they deal a second against this group.
func _hp_dps(u: E.Unit, ps: Array) -> Array:
	var def := 0.0
	var n := 0
	for p in ps:
		if not threatening(p): continue
		def += p.def
		n += 1
	def = def / float(maxi(1, n))
	var dps: float = sim.unit_atk(u) * (10.0 / (10.0 + def)) / maxf(0.1, sim.arms.cd(u))
	return [maxf(0.0, u.hp), dps]

## The group's beast nearest to `u` (who should meet the closest threat).
func _nearest(u: E.Unit, ps: Array) -> E.Predator:
	var best: E.Predator = null
	var d := INF
	for p in ps:
		if p.pos.distance_to(u.pos) < d:
			d = p.pos.distance_to(u.pos)
			best = p
	return best

## How far `u` is from the nearest beast of the group.
func _near_dist(u: E.Unit, ps: Array) -> float:
	return _closest_to(ps, u.pos)
