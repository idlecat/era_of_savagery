## Careers that emerge as the tribe develops (config/careers.json). Owned by the simulation
## as `sim.careers`.
##
## A small band does everything. Each grown-up's `u.calling` grows from the work their hands
## actually do (tags: doing:<u.doing>, job:<job type>, kind:<the node they gather from>);
## a career opens as the tribe learns and builds (`open`: a story.holds() condition), and the
## tribe has specialist places in proportion to its size and age. When an open career's
## calling is strong and clearly theirs, a person takes it up: from then on they work their
## trade faster, go to it by themselves when idle by day, and the Steward leaves them to it
## while the stores are healthy. A career they stop practising lapses as the calling fades.
## A game master (or the chieftain) can name or release someone with set_career()/release().
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")

var C: Dictionary = preload("res://scripts/config.gd").load_cfg("careers")

var sim
var on := true # (tests switch it off; test_careers switches it on)
var opened := {} # career id -> day it first opened (its open_log was written)
var firsts := {} # career id -> true once someone has held it (the first is a feat)
var next_try := {} # person id -> time they may next go to their trade by themselves
var _t := 0.0
var decay_t := 0.0

func _init(s) -> void:
	sim = s

## The career ids in config order.
func ids() -> Array: return C["careers"].keys()

## A career's config entry, or {}.
func def(id: String) -> Dictionary: return C["careers"].get(id, {})

## Display name of u's career ("" = none).
func title(u: E.Unit) -> String: return str(def(u.career).get("name", "")) if u != null else ""

## The career is open: the tribe has learned or built what it needs.
func is_open(id: String) -> bool:
	var d := def(id)
	return not d.is_empty() and sim.story.holds(d.get("open", {}))

## Grown-ups (not children, not the dead).
func adults() -> Array: return sim.living().filter(func(u): return u.role != "child")

## How many specialists the tribe can spare now (floor(grown-ups x share of the era)).
func places() -> int:
	var n := adults().size()
	if n < int(C["min_pop"]): return 0
	var sh: Dictionary = C["share"]
	var era := str(clampi(sim.evo.era, 1, 3))
	return floori(n * float(sh.get(era, sh.values()[-1])))

## The living who hold career `id`.
func holders(id: String) -> Array: return sim.living().filter(func(u): return u.career == id)

## How many living people hold any career.
func held() -> int: return sim.living().filter(func(u): return u.career != "").size()

## What u's hands are doing now, as tags: doing:<u.doing>, job:<job type>, kind:<node kind>.
func tags(u: E.Unit) -> Array:
	var out: Array = []
	if u.doing != "": out.append("doing:" + u.doing)
	var jt: String = u.job.get("type", "")
	if u.job.has("type"): out.append("job:" + jt)
	if jt == "gather":
		var n = sim.node_by_id(int(u.job.get("node_id", -1)))
		if n: out.append("kind:" + n.kind)
	return out

## True when u is at their own trade right now.
func at_trade(u: E.Unit) -> bool:
	if u == null or u.career == "": return false
	var f: Dictionary = def(u.career).get("from", {})
	for t in tags(u):
		if f.has(t): return true
	return false

## Work speed for u: their trade goes `work_mult` faster (sim.work_mul).
func work_mult(u: E.Unit) -> float:
	return float(C["work_mult"]) if on and at_trade(u) else 1.0

## Fighting strength for u (sim.unit_atk): a career's `atk_mult`.
func atk_mult(u: E.Unit) -> float:
	if not on or u.career == "": return 1.0
	return float(def(u.career).get("atk_mult", 1.0))

## Walking speed for u (sim.unit_speed): a career's `speed_mult` while at their trade.
func speed_mult(u: E.Unit) -> float:
	if not on or u.career == "" or not def(u.career).has("speed_mult") or not at_trade(u): return 1.0
	return float(def(u.career)["speed_mult"])

# ------------------------------------------------------------ the calling
func update(dt: float) -> void:
	if not on: return
	_t += dt
	decay_t += dt
	if _t < 1.0: return
	var step := _t
	_t = 0.0
	var cf: Dictionary = C["careers"]
	for u in adults():
		if u.doing == "" and u.job.get("type", "") != "tend": continue # (hands at work, not walking there)
		if u.job.get("type", "") == "life" and not u.doing in ["spar"]: continue # (idle acts barely count)
		var tg := tags(u)
		for id in cf:
			var best := 0.0
			for t in tg: best = maxf(best, float(cf[id]["from"].get(t, 0.0)))
			if best > 0.0: u.calling[id] = float(u.calling.get(id, 0.0)) + best * step
	if decay_t >= D.DAY_LEN * float(C["decay_every"]):
		decay_t = 0.0
		for u in adults():
			for id in u.calling.keys(): u.calling[id] = float(u.calling[id]) * float(C["decay"])
	for id in cf:
		if not opened.has(id) and is_open(id):
			opened[id] = sim.day()
			if sim.time > D.DAY_LEN * 0.25: sim.add_log(tr(C["open_log"]) % tr(cf[id]["plural"]), "story") # (not for the trades a tribe starts with)
	for u in adults(): _review(u)

## u's strongest calling: [career id, points, the next best's points].
func top_calling(u: E.Unit) -> Array:
	var best := ""
	var a := 0.0
	var b := 0.0
	for id in u.calling:
		var v := float(u.calling[id])
		if v > a:
			b = a
			a = v
			best = id
		elif v > b: b = v
	return [best, a, b]

## Why u can't take up `id` now ("" = they can). Points aside: the career, the person, the places.
func block(u: E.Unit, id: String) -> String:
	var d := def(id)
	if d.is_empty(): return "unknown"
	if u == null or u.dead or u.role == "child": return "child"
	if u.career == id: return "already"
	if not is_open(id): return "closed"
	if u.lv(str(d["skill"])) < int(d.get("min_lv", 0)): return "skill"
	if d.has("max") and holders(id).size() >= sim.story.count(d["max"]): return "full" # (a number, or {base, per_pop})
	if u.career == "" and held() >= places(): return "places"
	return ""

func _review(u: E.Unit) -> void:
	if u.career != "":
		if float(u.calling.get(u.career, 0.0)) < float(C["keep"]): _lapse(u)
		return
	var tc := top_calling(u)
	if tc[0] == "" or tc[1] < float(C["take"]) or tc[1] < tc[2] * float(C["lead"]): return
	if block(u, tc[0]) != "": return
	_take(u, tc[0], false)

func _take(u: E.Unit, id: String, named: bool) -> void:
	var d := def(id)
	u.career = id
	u.calling[id] = maxf(float(u.calling.get(id, 0.0)), float(C["take"])) # (a named career doesn't lapse at once)
	var nm: String = tr(d["name"])
	sim.popup(u.pos + Vector2(0, -40), tr(C["popup"]) % nm, Color("#bfe39a"), true)
	sim.remember(u, tr(C["remember"]) % [nm, sim.day()], 6)
	sim.add_log(tr(C["set_log"] if named else C["log"]) % [tr(u.name), nm], "story", [u])
	if not firsts.has(id):
		firsts[id] = true
		sim.inv.feat("career", tr(C["feat_title"]) % nm, u, {"desc": tr(d.get("desc", ""))})

func _lapse(u: E.Unit) -> void:
	var nm: String = tr(def(u.career).get("name", u.career))
	u.career = ""
	sim.add_log(tr(C["lapse_log"]) % [tr(u.name), nm], "xp", [u])

# ------------------------------------------------------------ going to the trade
## u (idle) goes to their trade by themselves: by day, near home, after `idle_secs` idle.
## Returns true if they set off (sim.unit_idle).
func self_work(u: E.Unit) -> bool:
	if not on or u.career == "" or u.role != "" or sim.rest_time() or u.sick > 0.0: return false
	if u.pos.distance_to(u.home) > float(C["reach"]) * 0.5 or not D.same_side(u.pos, u.home): return false
	var t := float(next_try.get(u.id, -1.0))
	if t < 0.0:
		next_try[u.id] = sim.time + float(C["idle_secs"])
		return false
	if sim.time < t: return false
	next_try.erase(u.id)
	if go_work(u): return true
	next_try[u.id] = sim.time + float(C["idle_secs"]) * 4.0 # (nothing to do at their trade now: try again later)
	return false

## Send u to their trade now (the Steward, self_work, a game master). False if it has no work
## of its own or there is none to be had (no game in reach, no building site...).
func go_work(u: E.Unit) -> bool:
	if u == null or u.dead or u.career == "": return false
	var w: Dictionary = def(u.career).get("work", {})
	if w.has("gather"):
		var res := str(w["gather"])
		var n = sim.find_node(res, u.home, D.region_at(u.home), float(C["reach"]), w.get("kinds", []))
		if n == null: return false
		sim.assign_gather(u, res, {"node_id": n.id, "bank": D.region_at(u.home), "area": u.home, "area_r": float(C["reach"])})
		sim.give_shift(u) # (a stint at the trade, then a look at what the tribe needs)
		return true
	if w.has("work_at"): # a field, a dock: the nearest of that type with a free place
		var f = sim.free_field(u.home, float(C["reach"]), [str(w["work_at"])])
		if f == null: return false
		sim.assign_field(u, f)
		sim.give_shift(u)
		return true
	if w.get("build", false):
		for s in sim.structures:
			if s.paid and sim.ours(s) and (not s.built or s.reno) and sim.settlement_of(s.pos) == sim.settlement_of(u.home):
				sim.assign_build(u, s)
				return true
		return false
	if w.get("ritual", false):
		sim.assign_ritual(u, u.home + Vector2(randf_range(-60, 60), -randf_range(30, 70)))
		sim.give_shift(u)
		return true
	if w.get("art", false) and sim.folk.can_art(u):
		sim.folk.start_art(u)
		return true
	return false

## The career whose holders go first for `duty` (config "preferred"), or "".
func preferred(duty: String) -> String: return str(C["preferred"].get(duty, ""))

## True when u holds the career preferred for `duty`.
func is_preferred(u: E.Unit, duty: String) -> bool:
	return on and u != null and u.career != "" and u.career == preferred(duty)

# ------------------------------------------------------------ a game master's operations
## Name person `uid` to career `id` (the chieftain or a game master). The rules still hold:
## the career must be open, the person grown and skilled enough, a place free. Returns "" or
## why not (a block() reason).
func set_career(uid: int, id: String) -> String:
	var u = sim.unit_by_id(uid)
	if u == null or u.dead: return "unknown"
	var why := block(u, id)
	if why != "": return why
	if u.career != "": _lapse(u)
	_take(u, id, true)
	return ""

## Release `uid` from their career (they go back to doing whatever is asked). False if none.
func release(uid: int) -> bool:
	var u = sim.unit_by_id(uid)
	if u == null or u.dead or u.career == "": return false
	var id: String = u.career
	_lapse(u)
	u.calling[id] = 0.0 # (released: it doesn't come back tomorrow by itself)
	return true

## Careers and callings, for a game master and the LLM prompts.
func summary() -> Dictionary:
	var hold := {}
	var rising := {}
	for u in adults():
		if u.career != "": hold[u.name] = u.career
		else:
			var tc := top_calling(u)
			if tc[0] != "" and tc[1] >= float(C["take"]) * 0.3: rising[u.name] = {"career": tc[0], "pct": roundi(100.0 * minf(1.0, tc[1] / float(C["take"])))}
	var open: Array = ids().filter(func(id): return is_open(id))
	return {"held": hold, "rising": rising, "open": open, "places": places(), "used": held()}

## Who lives by which trade, in words ({name: career name}): for the LLM prompts (evo.world_ctx).
## The trades people live by, for the personas (evo.world_ctx): each holder by name while
## the tribe is small; past C["words_max"] holders, how many live by each trade and its
## most skilled holder, so a city's prompt stays short.
func in_words() -> Dictionary:
	var out := {}
	var holders: Array = adults().filter(func(u): return u.career != "")
	if holders.size() <= int(C.get("words_max", 12)):
		for u in holders: out[tr(u.name)] = tr(title(u))
		return out
	for u in holders:
		var k: String = tr(str(def(u.career)["plural"]))
		var d: Dictionary = out.get(k, {"count": 0, "best": "", "_lv": -1})
		d["count"] += 1
		var lv: int = u.lv(str(def(u.career)["skill"]))
		if lv > int(d["_lv"]):
			d["_lv"] = lv
			d["best"] = tr(u.name)
		out[k] = d
	for k in out: out[k].erase("_lv")
	return out
