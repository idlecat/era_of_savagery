## Emergency mode: the rare moments the chieftain takes direct command. Owned by the
## simulation as `sim.crisis`. When a beast or raider strikes one of ours (or the chieftain
## takes command of a contract's emergency), a crisis starts at the danger: time slows
## (main.gd asks slow()), the people within reach are the ones the chieftain commands, and
## orders from config/emergency.json tell them what to do. When the danger has passed,
## everyone goes back to their work and remembers the day.
##
## Orders are data: each names a verb coded here and its numbers:
##   fight   - everyone able attacks the nearest threat
##   rally   - gather on the strongest fighter; close together they defend better a while
##   scare   - beasts within scare_radius flee (torches; "of": "beasts" spares raiders)
##   to_fire - run to the nearest bonfire; beasts near it flee once people are there
##   shelter - into the huts (reactions.gd shelter) until the crisis ends
##   aid     - the unhurt dress the badly wounded (reactions.gd aid)
## start(), order() and end() are the operations (the HUD, a game master); summary() reads it.
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")

var C: Dictionary = preload("res://scripts/config.gd").load_cfg("emergency")
const VERBS := ["fight", "rally", "scare", "to_fire", "shelter", "aid"]

var sim
var on := true # (tests and a calm game can switch it off)
var cur := {} # the crisis under way: {kind, at, t0, people, threat_ids, contract, quiet_t, dead0, orders}
var ready_t := 0.0 # no new crisis from an attack before this time
var buff := {} # rally: {"at", "until", "def", "close"}

func _init(s) -> void:
	sim = s

func active() -> bool: return not cur.is_empty()

## How much slower time runs (main.gd multiplies its speed by this).
func slow() -> float: return float(C.get("slow", 0.35)) if active() else 1.0

## Start a crisis of `kind` (a beast kind, "warrior" or "contract") at `at`. `people`:
## who is in it (default: ours within the radius); `contract`: its id for a crew's crisis.
func start(kind: String, at: Vector2, people: Array = [], contract := -1) -> bool:
	if active() or not on: return false
	if people.is_empty(): people = _near(at)
	if people.is_empty(): return false
	cur = {"kind": kind, "at": at, "t0": sim.time, "people": people.map(func(u): return u.id), "contract": contract,
		"quiet_t": 0.0, "dead0": sim.units.filter(func(u): return u.dead).size(), "orders": [], "threats0": threats().size()}
	sim.add_log(sim.tr(str(C.get("start_log", "%s"))) % title(), "danger")
	sim.crisis_started.emit(cur)
	return true

func title() -> String:
	return sim.tr(str(C.get("titles", {}).get(cur.get("kind", ""), C.get("titles", {}).get("warrior", ""))))

## Ours (grown-ups, awake or not) within the radius of a point.
func _near(at: Vector2) -> Array:
	var r := float(C.get("radius", 420))
	return sim.living().filter(func(u): return u.role != "child" and u.pos.distance_to(at) < r and not sim.in_hut(u))

## The people in the crisis, still alive.
func people() -> Array:
	if not active(): return []
	return cur["people"].map(func(id): return sim.unit_by_id(id)).filter(func(u): return u != null and not u.dead)

## The threats around it: beasts and raiders within the radius (and the rally point).
func threats() -> Array:
	if cur.is_empty(): return []
	var r := float(C.get("radius", 420)) * 1.3
	var out: Array = sim.active_predators_near(cur["at"], r)
	for u in people():
		for p in sim.active_predators_near(u.pos, 260.0):
			if not p in out: out.append(p)
	return out.filter(func(p): return p.kind != "trader" and (p.clan == "" or p.kind == "warrior"))

func update(dt: float) -> void:
	if not active():
		_watch()
		return
	# the crisis moves with its people (a beast chasing someone)
	var ps := people()
	var th := threats()
	if not th.is_empty():
		var c := Vector2.ZERO
		for p in th: c += p.pos
		cur["at"] = cur["at"].lerp(c / th.size(), minf(1.0, dt * 0.5))
	cur["quiet_t"] = float(cur["quiet_t"]) + dt if th.is_empty() else 0.0
	fire_check()
	if ps.is_empty(): end("lost")
	elif float(cur["quiet_t"]) >= float(C.get("quiet", 5)): end("won")
	elif sim.time - float(cur["t0"]) > float(C.get("max_secs", 150)): end("handed")
	elif not buff.is_empty() and sim.time > float(buff["until"]): buff = {}

## An attack on one of ours starts a crisis (config "triggers.attack").
func _watch() -> void:
	var tr_: Dictionary = C.get("triggers", {}).get("attack", {})
	if not on or not tr_.get("on", true) or sim.time < ready_t: return
	for u in sim.living():
		if u.role in tr_.get("skip_roles", []) or sim.time - u.last_hit_t > float(tr_.get("hit_ago", 1.5)) or u.attacker_id < 0: continue
		var p = sim.pred_by_id(u.attacker_id)
		if p == null or p.dead or not p.kind in tr_.get("kinds", []): continue
		if not sim.director.allow("crisis"): # (the tribe handles this one itself)
			ready_t = sim.time + sim.director.retry()
			return
		start(p.kind, u.pos)
		return

## End the crisis (outcome: won, lost, handed). Everyone goes back to their work.
func end(outcome := "handed") -> void:
	if not active(): return
	var fell: int = sim.units.filter(func(u): return u.dead).size() - int(cur["dead0"])
	var oc: Dictionary = C.get("outcome", {})
	var how: String = sim.tr(str(oc.get(outcome, outcome)))
	if fell > 0: how += ", " + sim.tr(str(oc.get("lost", "%d fell"))) % fell
	sim.add_log(sim.tr(str(C.get("end_log", "%s"))) % how, "danger")
	var what: String = sim.tr(str(C.get("happened", {}).get(cur["kind"], "")))
	for u in people():
		if C.has("remember"): sim.remember(u, sim.tr(str(C["remember"])) % [what, sim.day()], int(C.get("impact", 4)))
		if u.job.get("crisis", false) or u.job.get("type", "") in ["shelter"]: sim._end_errand(u)
	var done := cur.duplicate()
	done["outcome"] = outcome
	cur = {}
	buff = {}
	ready_t = sim.time + float(C.get("cooldown", 45))
	sim.crisis_ended.emit(done)

# ------------------------------------------------------------ orders
func order_def(id: String) -> Dictionary:
	for o in C.get("orders", []):
		if o.get("id", "") == id: return o
	return {}

## Why order `id` can't be given now ("" = it can).
func order_block(id: String) -> String:
	var o := order_def(id)
	if o.is_empty() or not o.get("verb", "") in VERBS: return "Unknown order"
	if not active(): return "No danger now"
	if not sim.story.holds(o.get("needs", {})): return "Not yet"
	for k in o.get("cost", {}):
		if sim.stock.get(k, 0.0) < float(o["cost"][k]): return sim.tr("Needs %d %s") % [int(o["cost"][k]), sim.tr(k)]
	return ""

## Give order `id` to the people in the crisis. Returns "" or why not.
func order(id: String) -> String:
	var why := order_block(id)
	if why != "": return why
	var o := order_def(id)
	for k in o.get("cost", {}): sim.stock[k] -= float(o["cost"][k])
	var ps := people()
	match o["verb"]:
		"fight":
			var th := threats()
			for u in ps:
				if u.hp < u.max_hp * float(o.get("min_hp", 0.3)) or th.is_empty(): continue
				th.sort_custom(func(a, b): return a.pos.distance_to(u.pos) < b.pos.distance_to(u.pos))
				_command(u, {"type": "attack", "target_id": th[0].id})
		"rally":
			var best = null
			for u in ps:
				if best == null or sim.unit_atk(u) > sim.unit_atk(best): best = u
			if best:
				var at: Vector2 = best.pos
				for u in ps:
					if u != best: _command(u, {"type": "move", "to": at + Vector2.from_angle(u.id * 2.4) * 20.0, "hold": true})
				buff = {"at": at, "until": sim.time + float(o.get("secs", 25)), "def": float(o.get("def", 3)), "close": float(o.get("close", 70))}
		"scare":
			var n := 0
			for p in sim.active_predators_near(cur["at"], float(o.get("scare_radius", 260))):
				if o.get("of", "") == "beasts" and p.clan != "": continue
				p.fleeing = true
				n += 1
			sim.popup(cur["at"] + Vector2(0, -40), sim.tr("%d beasts flee the fire") % n if n > 0 else sim.tr("Nothing fears the fire"), Color("#ffb060"))
		"to_fire":
			var fire = null
			for s in sim.structures:
				if s.built and sim.ours(s) and s.type == "bonfire" and s.pos.distance_to(cur["at"]) < float(o.get("reach", 900)) and (fire == null or s.pos.distance_to(cur["at"]) < fire.pos.distance_to(cur["at"])): fire = s
			if fire == null: return "No fire near"
			for u in ps: _command(u, {"type": "move", "to": fire.pos + Vector2.from_angle(u.id * 2.4) * 28.0, "hold": true})
			cur["fire"] = {"at": fire.pos, "r": float(o.get("scare_radius", 180))}
		"shelter":
			for u in ps: sim.react._start_shelter(o, u, {"until": sim.time + float(C.get("max_secs", 150))})
		"aid":
			for v in ps:
				if v.hp < v.max_hp * float(o.get("below", 0.6)):
					var helpers: Array = ps.filter(func(h): return h != v and h.hp >= h.max_hp * 0.6)
					helpers.sort_custom(func(a, b): return a.pos.distance_to(v.pos) < b.pos.distance_to(v.pos))
					for h in helpers.slice(0, int(o.get("count", 2))): sim.react._start_aid(o, h, {"victim": v})
	cur["orders"].append(id)
	sim.add_log(sim.tr("The Chieftain commands: %s") % sim.tr(o.get("label", id)), "combat")
	return ""

## A crisis order replaces the job for now; the work waits (resume_job) and comes back after.
func _command(u: E.Unit, job: Dictionary) -> void:
	job["crisis"] = true
	sim.react.interrupt(u, job)

## Beasts near the fire the people ran to turn away (once someone stands in its light).
func fire_check() -> void:
	if not cur.has("fire"): return
	var f: Dictionary = cur["fire"]
	if people().any(func(u): return u.pos.distance_to(f["at"]) < 60.0):
		for p in sim.active_predators_near(f["at"], float(f["r"])):
			if p.clan == "": p.fleeing = true

## DEF bonus from a rally (people close to the rally point while it lasts).
func def_bonus(u: E.Unit) -> float:
	if buff.is_empty() or u.pos.distance_to(buff["at"]) > float(buff["close"]): return 0.0
	return float(buff["def"])

func summary() -> Dictionary:
	if not active(): return {"active": false}
	return {"active": true, "kind": cur["kind"], "title": title(), "at": cur["at"], "people": people().map(func(u): return u.name),
		"threats": threats().size(), "secs": roundi(sim.time - float(cur["t0"])), "orders": cur["orders"],
		"can_order": C.get("orders", []).map(func(o): return o["id"]).filter(func(id): return order_block(id) == "")}
