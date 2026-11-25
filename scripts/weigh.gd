## Weighing an errand before committing to it (sim.weigh; config/weigh.json; docs/weigh.md).
##
## Cost: the time out there (the walk there, the work, the walk back to the nearest fire).
## Risk: the health that time costs in a cold that can kill (by day and by night as the
## trip runs into the dark, an announced blizzard from when it comes: cold_ahead()), and the
## beasts near the place. Outcome: need raises the risk people take (with empty stores they
## go further for food).
##
## plan() makes a context for many checks in a row; fits()/penalty() are cheap per place
## (find_node and explore_target loop over thousands). trip() is the full appraisal as a
## plain dictionary (appraise() for a game master); must_head_back() is the point of no
## return the "freezing" reaction asks; nearest_warmth() the fire to head for, by route.
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")
const Config = preload("res://scripts/config.gd")

var C: Dictionary = Config.load_cfg("weigh")
var sim
var day_seen := -1
var refused := 0     # errands turned down today for the cold
var turned_back := 0 # people who headed back in time today
var _cache_check := {} # unit id -> sim.time of the next point-of-no-return check
var _cache_flood_said := {} # unit id -> when they may next say they wait for the flood

func _init(s) -> void:
	sim = s

func on() -> bool: return bool(C.get("on", true))

# ------------------------------------------------------------ the cold ahead
## Is the day fraction f within the part of the day `name` (rules.json "day")?
func _in_part(name: String, f: float) -> bool:
	var w: Array = sim.day_part(name)
	return (f >= float(w[0]) and f < float(w[1])) if float(w[0]) <= float(w[1]) else (f >= float(w[0]) or f < float(w[1]))

## The cold ahead for u away from a fire, as [[from_secs, rate], ...] in order (the last one
## lasts on): it changes when the dark comes and goes and when an announced weather arrives.
## The rate is 0 while the cold can't kill (outside winter it only weakens).
func cold_ahead(u: E.Unit) -> Array:
	var hz = sim.hz
	var f: float = sim.day_frac()
	var t_in: float = hz.incoming_t if hz.incoming != "" else INF
	var breaks: Array = [0.0]
	for k in 2:
		for edge in sim.day_part("dark"): breaks.append(fposmod(float(edge) - f, 1.0) * D.DAY_LEN + k * D.DAY_LEN)
	if t_in < INF: breaks.append(maxf(0.0, t_in))
	breaks.sort()
	var segs: Array = []
	for t in breaks:
		if not segs.is_empty() and is_equal_approx(float(segs[-1][0]), float(t)): continue
		var w: String = hz.incoming if t >= t_in else hz.weather
		var dark := _in_part("dark", fposmod(f + (float(t) + 0.01) / D.DAY_LEN, 1.0))
		var deadly: bool = hz.winter() or bool(hz.WEATHER.get(w, {}).get("deadly_cold", false))
		segs.append([float(t), hz.cold_rate_as(u, dark, w) if deadly else 0.0])
	return segs

## The health `secs` seconds away from a fire cost, by the cold ahead (cold_ahead()).
func exposure(segs: Array, secs: float) -> float:
	var hp := 0.0
	for i in segs.size():
		var t0: float = segs[i][0]
		if t0 >= secs: break
		var t1: float = minf(secs, float(segs[i + 1][0]) if i + 1 < segs.size() else INF)
		hp += float(segs[i][1]) * (t1 - t0)
	return hp

## Can the cold ahead kill within `secs`?
func _deadly_within(segs: Array, secs: float) -> bool:
	return segs.any(func(sg): return float(sg[0]) < secs and float(sg[1]) > 0.0)

# ------------------------------------------------------------ what a person will risk
## How much more health u keeps in hand than `floor` (temperament; need keeps less).
func keep_mult(u: E.Unit, res := "") -> float:
	var k := 1.0
	for t in u.traits: k *= float(C["traits"].get(t, 1.0))
	var nd: Dictionary = C["need"].get(res, {})
	if not nd.is_empty() and float(sim.stock.get(res, 0.0)) < float(nd["per_head"]) * sim.living().size():
		k /= maxf(0.1, float(nd["mult"]))
	return k

## The health u can spend out there (already divided by `safety`).
func budget(u: E.Unit, res := "") -> float:
	var keep: float = float(C["floor"]) * u.max_hp * keep_mult(u, res)
	return maxf(0.0, u.hp - keep) / float(C["safety"])

# ------------------------------------------------------------ warmth
## Where warmth is: our built fires (the village if there are none).
func warm_points() -> Array:
	var out: Array = []
	for s in sim.serving("warmth"): out.append(s.pos)
	if out.is_empty(): out.append(D.VILLAGE)
	return out

## Straight-line walk from p into the warmth of the nearest of `fires`.
func _warm_d(fires: Array, p: Vector2) -> float:
	var best := INF
	for f in fires: best = minf(best, p.distance_to(f))
	return maxf(0.0, best - sim.warm_reach())

## The nearest fire of ours by the way people walk (over fords), or null. While the river is
## in flood, a fire on p's own side of it first.
func nearest_warmth(p: Vector2) -> E.Structure:
	if sim.nat.flooding():
		var mine := _nearest_fire_by_route(p, true)
		if mine: return mine
	return _nearest_fire_by_route(p, false)

func _nearest_fire_by_route(p: Vector2, same_side: bool) -> E.Structure:
	var best: E.Structure = null
	var best_d := INF
	for s in sim.serving("warmth"):
		if same_side and not D.same_side(p, s.pos): continue
		if p.distance_to(s.pos) >= best_d: continue # (a route is never shorter than the line)
		var d := D.route_len(p, s.pos)
		if d < best_d:
			best_d = d
			best = s
	return best

## The walk from p into the warmth of the nearest fire, by route.
func walk_to_warmth(p: Vector2) -> float:
	var fire := nearest_warmth(p)
	return maxf(0.0, D.route_len(p, fire.pos) - sim.warm_reach()) if fire else p.distance_to(D.VILLAGE)

# ------------------------------------------------------------ weighing places
## A context for weighing many places for u in a row ({} = nothing to weigh: every place fits).
## `res`: what the errand is for (need); `kind`: its work ("gather", "seek", "explore").
func plan(u: E.Unit, res := "", kind := "gather") -> Dictionary:
	if not on() or u == null or u.dead: return {}
	var ctx := {}
	var segs := cold_ahead(u)
	if _deadly_within(segs, float(C["horizon"])):
		ctx = {"segs": segs, "budget": budget(u, res), "fires": warm_points(), "speed": maxf(1.0, sim.unit_speed(u)),
			"from": u.pos, "work": float(C["work"].get(kind, 0.0)), "detour": float(C["detour"])}
	if sim.nat.flooding(): # (the river in flood: nobody crosses it or works in it)
		var side: int = D.region_at(u.pos)
		ctx["flood_side"] = side if side >= 0 else D.region_at(u.home)
	var bc: Dictionary = C["beasts"]
	var hunting: Array = sim.predators.filter(func(p): return not p.dead and not p.fled and not p.fleeing and p.clan == "" and sim.is_explored(p.pos))
	var beasts: Array = hunting.map(func(p): return p.pos)
	var dens: Array = sim.landmarks.filter(func(l): return l["found"] and l["kind"] == "den").map(func(l): return l["pos"])
	if not beasts.is_empty() or not dens.is_empty():
		ctx["beasts"] = beasts
		ctx["dens"] = dens
		ctx["reach"] = float(bc["reach"])
		ctx["den_reach"] = float(bc["den_reach"])
		ctx["penalty"] = float(bc["penalty"])
	var deadly: Array = hunting.filter(func(p): return not sim.hunt.rules_for(p.kind).is_empty()).map(func(p): return p.pos) # (the beasts with band tactics: nobody goes near one alone)
	if not deadly.is_empty():
		ctx["avoid"] = deadly
		ctx["avoid_r"] = float(bc["avoid_reach"])
	return ctx

## The cold health a trip to p (and `work` seconds there, -1 = the plan's) costs, and its seconds.
func cost(ctx: Dictionary, p: Vector2, work := -1.0) -> Vector2:
	if not ctx.has("segs"): return Vector2.ZERO
	var secs: float = (ctx["from"].distance_to(p) + _warm_d(ctx["fires"], p)) * float(ctx["detour"]) / float(ctx["speed"]) + (float(ctx["work"]) if work < 0.0 else work)
	return Vector2(exposure(ctx["segs"], secs), secs)

## Does a trip to p fit the plan (why_not() is "")?
func fits(ctx: Dictionary, p: Vector2, work := -1.0) -> bool:
	if ctx.is_empty(): return true
	return why_not(ctx, p, work) == ""

## Why a trip to p doesn't fit the plan: "flood" (across the river in flood, or in it),
## "beast" (within `avoid_reach` of a hunting beast nobody faces alone), "cold" (the way
## back to a fire costs more than they can spare), or "" when it fits.
func why_not(ctx: Dictionary, p: Vector2, work := -1.0) -> String:
	if ctx.has("flood_side") and (D.in_river(p) or D.region_at(p) != int(ctx["flood_side"])): return "flood"
	if ctx.has("avoid"):
		var r: float = ctx["avoid_r"]
		for b in ctx["avoid"]:
			if p.distance_to(b) < r: return "beast"
	if ctx.has("segs") and cost(ctx, p, work).x > float(ctx["budget"]): return "cold"
	return ""

## What makes the place p dangerous to go to right now: "flood" (in the river while it is
## in flood), "beast" (a hunting beast nobody faces alone within `avoid_reach`), or "".
func danger_at(p: Vector2) -> String:
	if sim.nat.flooding() and D.in_river(p): return "flood"
	var r: float = float(C["beasts"]["avoid_reach"])
	for b in sim.active_predators_near(p, r):
		if b.clan == "" and not sim.hunt.rules_for(b.kind).is_empty(): return "beast"
	return ""

## The texts of a refusal for `why` ({act, popup}), from weigh.json "refuse".
func refusal(why: String) -> Dictionary: return C["refuse"].get(why, C["refuse"]["cold"])

## The extra score of p in a choice of where to go (as if that much further): beasts, dens.
func penalty(ctx: Dictionary, p: Vector2) -> float:
	if not ctx.has("beasts"): return 0.0
	var r: float = ctx["reach"]
	for b in ctx["beasts"]:
		if p.distance_to(b) < r: return float(ctx["penalty"])
	r = ctx["den_reach"]
	for d in ctx["dens"]:
		if p.distance_to(d) < r: return float(ctx["penalty"])
	return 0.0

## The full appraisal of sending u to `to` for `work` seconds (for `res`), by route: what a
## game master or a panel reads. {secs, cold_per_s (on average), cold_hp and budget_hp (both
## counted `safety` times), hp_after, beasts, ok, why}. `from`: the start (null = where u is).
func trip(u: E.Unit, to: Vector2, work := 0.0, res := "", from: Variant = null) -> Dictionary:
	var start: Vector2 = from if from is Vector2 else u.pos
	var secs: float = (D.route_len(start, to) + walk_to_warmth(to)) / maxf(1.0, sim.unit_speed(u)) + maxf(0.0, work)
	var hurt := exposure(cold_ahead(u), secs) if on() else 0.0
	var b := budget(u, res)
	var near: int = sim.active_predators_near(to, float(C["beasts"]["reach"])).filter(func(p): return p.clan == "").size()
	var why := "" if hurt <= b else "cold"
	if on() and sim.nat.flooding() and (D.in_river(to) or not D.same_side(start, to)): why = "flood"
	elif on() and danger_at(to) == "beast": why = "beast"
	var ok := why == ""
	return {"secs": snappedf(secs, 0.1), "cold_per_s": snappedf(hurt / maxf(0.1, secs), 0.01), "cold_hp": snappedf(hurt * float(C["safety"]), 0.1),
		"budget_hp": snappedf(b * float(C["safety"]), 0.1), "hp_after": snappedf(u.hp - hurt, 0.1), "beasts": near,
		"ok": ok, "why": why}

## A game master's appraisal of a trip for a person (by id) to (x, y): trip() or {} for junk.
func appraise(unit_id: Variant, x: Variant, y: Variant, work: Variant = 0.0, res: Variant = "") -> Dictionary:
	if not (unit_id is int or unit_id is float) or not (x is int or x is float) or not (y is int or y is float): return {}
	if is_nan(float(x)) or is_nan(float(y)) or is_nan(float(unit_id)): return {}
	var u: E.Unit = sim.unit_by_id(int(unit_id))
	if u == null or u.dead: return {}
	var w: float = clampf(float(work), 0.0, 600.0) if (work is int or work is float) and not is_nan(float(work)) else 0.0
	var p := Vector2(clampf(float(x), 0.0, float(D.W)), clampf(float(y), 0.0, float(D.H)))
	return trip(u, p, w, str(res) if str(res) in D.RESOURCES else "")

# ------------------------------------------------------------ the way back
## The point of no return: u is out in a deadly cold and what they have left above
## `back_floor` only just covers the way to the nearest fire (counted `safety` times).
## Checked every `check_every` seconds per person (a route is not free).
func must_head_back(u: E.Unit) -> bool:
	if not on() or u.dead or sim.in_hut(u) or not sim.hz.cold_can_kill(): return false
	if sim.time < float(_cache_check.get(u.id, -1.0)): return false
	_cache_check[u.id] = sim.time + float(C["check_every"])
	if sim.near_warmth(u): return false
	var secs: float = walk_to_warmth(u.pos) / maxf(1.0, sim.unit_speed(u))
	var need: float = exposure(cold_ahead(u), secs) * float(C["safety"])
	return u.hp - need <= float(C["back_floor"]) * u.max_hp

## Someone turned an errand down (`why`: cold, flood, beast; counted; they say so).
func note_refused(u: E.Unit, why := "cold") -> void:
	_new_day()
	refused += 1
	sim.life.say(u, str(refusal(why).get("talk_as", "too_far_cold")))

## The river is in flood and u's next step would take them into it: they wait on the bank
## (sim.step_move asks; a popup now and then says so).
func hold_at_flood(u: E.Unit, next: Vector2) -> bool:
	if not on() or not sim.nat.flooding() or D.in_river(u.pos) or not D.in_river(next): return false
	if sim.time >= float(_cache_flood_said.get(u.id, -1.0)):
		_cache_flood_said[u.id] = sim.time + float(C["flood_say_every"])
		sim.popup(u.pos + Vector2(0, -30), tr(refusal("flood")["popup"]), Color("#a8d8ff"))
	return true

## Someone headed back to a fire in time.
func note_turned_back(u: E.Unit) -> void:
	_new_day()
	turned_back += 1
	sim.life.say(u, "turn_back", "", true)

func _new_day() -> void:
	if day_seen != sim.day():
		day_seen = sim.day()
		refused = 0
		turned_back = 0

## The state for a game master: is the cold deadly, who is out in it and how many seconds
## of it they can still take, today's refusals and turnings back.
func summary() -> Dictionary:
	_new_day()
	var out: Array = []
	if sim.hz.cold_can_kill():
		for u in sim.living():
			if sim.in_hut(u) or sim.near_warmth(u): continue
			var r: float = sim.hz.cold_rate(u, false)
			if r <= 0.0: continue
			out.append({"id": u.id, "name": u.name, "hp": snappedf(u.hp, 0.1), "secs_left": snappedf(maxf(0.0, u.hp - float(C["back_floor"]) * u.max_hp) / r, 0.1)})
	return {"on": on(), "deadly": sim.hz.cold_can_kill(), "out_in_cold": out, "refused_today": refused, "turned_back_today": turned_back}
