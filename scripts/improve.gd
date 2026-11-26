## The village improves itself: the Steward (or, by config, the tribe on its own) lays out
## building sites when a need comes up, e.g. a Granary when the stores are nearly full or a
## Hut when people sleep in the open. Owned by the simulation as `sim.improve`.
##
## The rules are data (config/rules.json "improvements"): each entry names a structure,
## the conditions under which it is wanted (`when`, story.holds() keys) and the reason the
## tribe gives. Entries are in priority order. Several wanted at once: the planner may ask
## an advisor (the HUD asks the Steward's LLM persona) through `advice_wanted`; the answer
## comes back through choose(), the same operation a game master would call. No advisor,
## no answer in time, or an answer outside the options: the first wanted entry is built.
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")

var C: Dictionary = preload("res://scripts/config.gd").load_cfg("rules")["improvements"]

var sim
var on := true
var timer := 0.0
var sites: Array = [] # ids of the building sites laid out by the planner
var asking := {} # {"options": [ids], "until": time} while the advisor is consulted
var quiet_until := 0.0 # no new advice asked before this time
var last := {} # the last decision: {structure, reason, by, day}
var plans := {} # settlement key "x,y" -> {"fields": angle}: its layout, chosen once (fields_dir())

func _init(s) -> void:
	sim = s
	on = bool(C.get("on", true))

## Who plans: the Steward, or (planner "anyone") the tribe's best at lore without one.
func planner() -> E.Unit:
	var st: E.Unit = sim.unit_by_id(sim.vice["steward"])
	if st and not st.dead: return st
	if str(C.get("planner", "steward")) == "anyone": return sim.best_unit("lore", false)
	return null

func update(dt: float) -> void:
	if not asking.is_empty():
		if sim.time >= float(asking["until"]): choose("", "") # the advisor kept quiet
		return
	timer -= dt
	if timer > 0: return
	var who := planner()
	var st: E.Unit = sim.unit_by_id(sim.vice["steward"])
	timer = float(C.get("every", 15)) * (1.0 if who != null and who == st else float(C.get("anyone_every_mult", 1.0))) # (without a Steward the tribe still builds, more slowly)
	if not on or sim.rest_time() or who == null: return
	if retire_one(): return
	if open_sites() >= maxi(1, sim.story.count(C.get("max_sites", 1))): return # (a number, or {base, per_pop}: a bigger tribe raises more at once)
	var opts := wanted()
	if opts.is_empty(): return
	if opts.size() == 1 or not bool(C.get("ask", true)) or sim.time < quiet_until or sim.advice_wanted.get_connections().is_empty():
		_build(opts[0], "", "")
		return
	asking = {"options": opts.map(func(r): return r["structure"]), "until": sim.time + float(C.get("ask_wait", 20))}
	quiet_until = sim.time + float(C.get("ask_every", 90))
	sim.advice_wanted.emit(advice_ctx())

## How far from the village the planner builds (rules.json improvements.reach: a number,
## or {base, per_pop}: a growing village spreads out).
func reach() -> float: return float(maxi(1, sim.story.count(C.get("reach", 450))))

# ------------------------------------------------------------ outdated buildings (structures.json obsolete)
## Puts out one outdated building of ours by the village whose every role others cover
## (covered()); the one at the village's centre stays (an upgrade path makes it something
## else). Returns whether one was.
func retire_one() -> bool:
	for s in sim.structures:
		if not s.built or s.reno or not sim.ours(s) or not sim.obsolete(s.type): continue
		var d: float = s.pos.distance_to(D.VILLAGE)
		if d < 1.0 or d > reach() or sim.settlement_of(s.pos).distance_to(D.VILLAGE) > 1.0 or not covered(s): continue # (an outpost keeps its fire)
		return retire(s.id) == ""
	return false

## Whether other buildings, not outdated, do all that `s` does (structures.json serves): its
## warmth within their own warm reach, its other roles within its obsolete `cover`.
func covered(s: E.Structure) -> bool:
	var cover := float(D.STRUCTURES[s.type].get("obsolete", {}).get("cover", 600))
	for role in D.STRUCTURES[s.type].get("serves", {}):
		var ok := false
		for o in sim.serving(role):
			if o == s or sim.obsolete(o.type): continue
			var far: float = sim.warm_reach() * sim.serves(o, role) if role == "warmth" else cover
			if o.pos.distance_to(s.pos) < far:
				ok = true
				break
		if not ok: return false
	return true

## Put out outdated building `id` (pulled down, part of its wood back): the planner's and a
## game master's operation. "" or why not.
func retire(id: int) -> String:
	var s: E.Structure = sim.struct_by_id(id)
	if s == null or not sim.ours(s) or not sim.obsolete(s.type): return "Not outdated"
	var st: String = s.type
	var err: String = sim.demolish(id)
	if err == "": last = {"structure": st, "reason": "retired", "by": "", "day": sim.day()}
	return err

## The planner's building sites not finished yet.
func open_sites() -> int:
	sites = sites.filter(func(id): return sim.structures.any(func(s): return s.id == id and (not s.built or s.reno)))
	return sites.size()

## The entries wanted now and possible (known, affordable with the reserve, a spot found),
## in priority order.
func wanted() -> Array:
	var out: Array = []
	var reserve := float(C.get("wood_reserve", 10))
	for r in C.get("list", []):
		if r.has("road"):
			if not _road_cells(r).is_empty() and sim.story.holds(r.get("when", {})): out.append(r)
			continue
		if r.has("upgrade"):
			if _upgrade_target(r) != null and sim.story.holds(r.get("when", {})): out.append(r)
			continue
		var st: String = r.get("structure", "")
		if not D.STRUCTURES.has(st) or not st in D.VILLAGE_BUILDS: continue
		var sd: Dictionary = D.STRUCTURES[st]
		if sim.struct_block(st) != "": continue
		if str(r.get("at", "village")) == "village" and sim.obsolete(st): continue # (outdated: outposts still get theirs)
		if sim.stock["wood"] < sd["wood"] + reserve or sim.stock["stone"] < sd.get("stone", 0): continue
		if sim.structures.any(func(s): return not s.built and s.type == st and sim.ours(s)): continue # one at a time
		if not sim.story.holds(r.get("when", {})): continue
		if site_for(r) == Vector2.INF: continue
		out.append(r)
	return out

## For a road entry ({"road": level id, "cells": n}): the busiest trails near the village to
## make into that road ([] if none worth it, it can't be built or paid for yet, or a road is
## already being built).
func _road_cells(r: Dictionary) -> Array:
	var R = sim.roads
	var lv: int = R.index_of(str(r["road"]))
	if R.build_block(lv) != "" or sim.structures.any(func(s): return s.type == "roadworks"): return []
	var cells: Array = R.busiest_trails(D.VILLAGE, reach() * 1.5, int(r.get("cells", 40)), lv)
	if cells.size() < int(r.get("min_cells", 8)): return []
	var c: Dictionary = R.cost(cells, lv)
	for k in c:
		if sim.stock.get(k, 0.0) < float(c[k]) + float(C.get("wood_reserve", 10)): return []
	return cells

## For an upgrade entry ({"upgrade": from type, "structure": to}): the village's building
## to upgrade (the one nearest the village that can be upgraded now), or null.
func _upgrade_target(r: Dictionary):
	var to: String = r.get("structure", "")
	var from: String = r.get("upgrade", "")
	if sim.structures.any(func(s): return s.reno and s.upgrade == to and sim.ours(s)): return null # one at a time
	var reserve := float(C.get("wood_reserve", 10))
	var best = null
	for s in sim.structures:
		if s.type != from or not sim.ours(s) or s.pos.distance_to(D.VILLAGE) > reach(): continue
		if not room_to_grow(s, to): continue # (in the flood band, or too tight beside its neighbours for the bigger building)
		for o in sim.upgrades_for(s):
			if o["to"] == to and o["why"] == "" and sim.stock["wood"] >= o["wood"] + reserve and (best == null or s.pos.distance_to(D.VILLAGE) < best.pos.distance_to(D.VILLAGE)): best = s
	return best

## Whether building `s` can become a `to` where it stands: a home clear of the spring flood
## (nat.flood_band()), and the bigger footprint keeping the planner's gap from its neighbours.
func room_to_grow(s: E.Structure, to: String) -> bool:
	var r := float(D.STRUCTURES[to]["r"])
	if int(D.STRUCTURES[to].get("cap", 0)) > 0 and D.river_dist(s.pos) < maxf(sim.wet_reach(), sim.nat.flood_band()) + r: return false
	var gap := float(C.get("gap", 14))
	for o in sim.structures:
		if o == s or D.STRUCTURES[o.type].get("ring", false): continue
		if o.pos.distance_to(s.pos) < r + sim.struct_r(o) + gap * 0.5: return false
	return true

func _rule(st: String) -> Dictionary:
	for r in C.get("list", []):
		if r.get("structure", "") == st: return r
	return {}

## What the advisor is told: the planner, the options with their reasons, the tribe's state.
func advice_ctx() -> Dictionary:
	var who := planner()
	var opts: Array = []
	for id in asking.get("options", []):
		var sd: Dictionary = D.STRUCTURES[id]
		var o := {"structure": id, "name": sd["name"], "does": sd["desc"], "wood": sd["wood"], "stone": sd.get("stone", 0), "why": _rule(id).get("reason", "")}
		var t = _upgrade_target(_rule(id)) if _rule(id).has("upgrade") else null
		if t: # (an existing building made bigger: costs only the difference)
			o["upgrade_of"] = D.STRUCTURES[t.type]["name"]
			for u in sim.upgrades_for(t):
				if u["to"] == id:
					o["wood"] = u["wood"]
					o["stone"] = u["stone"]
		opts.append(o)
	return {
		"leader": sim.contracts.leader_profile(who) if who else {},
		"world": sim.evo.world_ctx(), "season": sim.hz.summary(),
		"options": opts, "fallback": asking.get("options", [""])[0],
		"tribe": {"people": sim.living().size(), "beds": sim.pop_cap(), "food": roundi(sim.stock["food"]), "food_storage": sim.food_cap(),
			"wood": roundi(sim.stock["wood"]), "stone": roundi(sim.stock["stone"]), "mood": roundi(sim.folk.mood)},
	}

## Settle the open question: `structure` one of the options (or "wait" to build nothing
## now; anything else = the first option), `speech` the planner's words for the chronicle.
## Untrusted input: only the options asked about can be chosen.
func choose(structure: String, speech: String, by := "") -> void:
	if asking.is_empty(): return
	var opts: Array = asking["options"]
	asking = {}
	if structure == "wait":
		last = {"structure": "", "reason": speech.left(200), "by": by, "day": sim.day()}
		if speech != "": _say(speech)
		return
	var st: String = structure if structure in opts else opts[0]
	var now := wanted()
	var r := {}
	for w in now: # (the first entry for it still wanted: a hut may be for the village or an outpost)
		if w["structure"] == st:
			r = w
			break
	if r.is_empty(): # (things changed meanwhile)
		if now.is_empty(): return
		r = now[0]
		speech = ""
	_build(r, speech, by)

## A game master's order: lay out `structure` now where the planner would (needs the
## tech, the wood and a spot; no conditions). Returns "" or why not.
func order(structure: String, why := "") -> String:
	if not D.STRUCTURES.has(structure) or not structure in D.VILLAGE_BUILDS: return "Unknown structure"
	var r := _rule(structure)
	if r.is_empty(): r = {"structure": structure, "near": "village"}
	var p := spot(structure, str(r.get("near", "village")))
	if p == Vector2.INF: return "No room"
	var err: String = sim.can_place(structure, p)
	if err != "": return err
	_place(structure, p, why if why != "" else str(r.get("reason", "")), "", "order")
	return ""

func _build(r: Dictionary, speech: String, by: String) -> void:
	var st: String = r["structure"]
	if r.has("road"):
		var cells := _road_cells(r)
		if cells.is_empty() or sim.roads.lay_cells(cells, sim.roads.index_of(str(r["road"]))) != "": return
		var rw = sim.structures.filter(func(s): return s.type == "roadworks").back()
		if rw: sites.append(rw.id)
		_note(st, str(r.get("reason", "")), speech, by)
		return
	if r.has("upgrade"):
		var t = _upgrade_target(r)
		if t == null or sim.upgrade(t.id, st) != "": return
		sites.append(t.id)
		_note(st, str(r.get("reason", "")), speech, by, r["upgrade"])
		return
	var p := site_for(r)
	if p == Vector2.INF or sim.can_place(st, p) != "": return
	_place(st, p, str(r.get("reason", "")), speech, by)

func _place(st: String, p: Vector2, reason: String, speech: String, by: String) -> void:
	var s: E.Structure = sim.place_structure(st, p)
	if s == null: return
	sites.append(s.id)
	_note(st, reason, speech, by)

## Tell the chronicle what was planned and why.
func _note(st: String, reason: String, speech: String, by: String, from := "") -> void:
	var who := planner()
	last = {"structure": st, "reason": reason, "by": by, "day": sim.day()}
	if speech != "": _say(speech)
	var name: String = sim.tr(D.STRUCTURES[st]["name"])
	if from != "":
		var was: String = sim.tr(D.STRUCTURES[from]["name"])
		if who: sim.add_log(sim.tr("%s has a %s made into a %s: %s") % [sim.tr(who.name), was, name, sim.tr(reason)], "build", [who])
		else: sim.add_log(sim.tr("The tribe makes a %s into a %s: %s") % [was, name, sim.tr(reason)], "build")
	elif who: sim.add_log(sim.tr("%s lays out a %s: %s") % [sim.tr(who.name), name, sim.tr(reason)], "build", [who])
	else: sim.add_log(sim.tr("The tribe lays out a %s: %s") % [name, sim.tr(reason)], "build")
	if who: sim.gain_xp(who, "lore", 1.0)

func _say(speech: String) -> void:
	var who := planner()
	if who: sim.add_log("%s: \"%s\"" % [sim.tr(who.name), speech.left(200)], "vice", [who])

## Where an entry would build now: by the village, or (`"at": "outpost"`) within
## `outpost_reach` of the outpost that should grow next (outpost_to_grow()). INF if nowhere.
func site_for(r: Dictionary) -> Vector2:
	var st: String = r["structure"]
	if str(r.get("at", "village")) == "outpost":
		var o := outpost_without(st) if bool(r.get("missing", false)) else outpost_to_grow()
		if o == Vector2.INF: return Vector2.INF
		return spot(st, str(r.get("near", "village")), o, float(C.get("outpost_reach", 220)))
	return spot(st, str(r.get("near", "village")))

## The outpost to give the next home: of those crowded (beds.crowd_at) and with fewer people than
## `outpost_share` of the village's, the one with the fewest. Vector2.INF if none.
func outpost_to_grow() -> Vector2:
	var homes: Array = sim.settlements()
	var most := float(sim.residents_of(D.VILLAGE).size()) * float(C.get("outpost_share", 0.5))
	var best := Vector2.INF
	for i in range(1, homes.size()):
		var p: Vector2 = homes[i]
		var n: int = sim.residents_of(p).size()
		if sim.fullness(p) < float(sim.RULES["beds"]["crowd_at"]) or n >= most or not sim.warm_at(p): continue # (room left: people move in first)
		if best == Vector2.INF or n < sim.residents_of(best).size(): best = p
	return best

# ------------------------------------------------------------ where to build
## The outpost with people and no `st` of ours (built or a site) within `outpost_reach`,
## the one with the most people. Vector2.INF if none.
func outpost_without(st: String) -> Vector2:
	var homes: Array = sim.settlements()
	var far := float(C.get("outpost_reach", 220))
	var best := Vector2.INF
	for i in range(1, homes.size()):
		var p: Vector2 = homes[i]
		var n: int = sim.residents_of(p).size()
		if n == 0 or sim.structures.any(func(s): return s.type == st and sim.ours(s) and s.pos.distance_to(p) < far): continue
		if best == Vector2.INF or n > sim.residents_of(best).size(): best = p
	return best

## A free spot for `st` near `near` ("village", or a structure type: the one of ours
## nearest the village), on the village's side of the water. Vector2.INF if none.
func spot(st: String, near: String, center: Vector2 = D.VILLAGE, far := -1.0) -> Vector2:
	if far < 0.0: far = reach()
	var anchor: Vector2 = center
	if near != "village":
		var best = null
		for s in sim.structures:
			if s.built and sim.ours(s) and s.type == near and (best == null or s.pos.distance_to(center) < best.pos.distance_to(center)): best = s
		if best and best.pos.distance_to(center) < far: anchor = best.pos
	var r: float = D.STRUCTURES[st]["r"]
	var step := float(C.get("ring_step", 35))
	var region = D.region_at(center)
	var dry: float = sim.nat.flood_band() if int(D.STRUCTURES[st].get("cap", 0)) > 0 else 0.0 # (homes stand clear of the spring flood; fields may take the silt)
	var near_structs: Array = sim.structures.filter(func(s): return s.pos.distance_to(anchor) < far + 200 or s.pos.distance_to(center) < far + 200)
	var near_nodes: Array = sim.nodes.filter(func(n): return (n.kind in ["tree", "bush", "boulder"] or n.kind in D.FINDS) and (n.pos.distance_to(anchor) < far + 60 or n.pos.distance_to(center) < far + 60))
	if C.has("layout"):
		var ring := placing(st, center) == "ring"
		var g := _ring_spot(st, anchor, center, far, near_structs, near_nodes, dry) if ring else Vector2.INF
		if g == Vector2.INF and zone_of(st) != "plaza": g = _grid_spot(st, anchor, center, far, near_structs, near_nodes, dry) # (a full ring spills onto the grid)
		if g != Vector2.INF: return g
	var d := step * 1.5
	while d <= far:
		var n := maxi(8, int(TAU * d / step))
		var a0 := float(sim.structures.size()) * 0.7 # (varies between sites, deterministic)
		for i in n:
			var p: Vector2 = anchor + Vector2.from_angle(a0 + TAU * i / n) * d
			if p.distance_to(center) < far and D.region_at(p) == region and is_free(p, r, near_structs, near_nodes, dry): return p
		d += step
	return Vector2.INF

# ------------------------------------------------------------ the grid (rules.json improvements.layout)
## How `st` is laid out at settlement `center`: "ring" (round the fire) if its zone is one of
## layout.ring_zones for the tier the settlement has earned, else "grid".
func placing(st: String, center: Vector2) -> String:
	var tier := str(sim.place_of(center).get("tier", "camp"))
	return "ring" if zone_of(st) in C["layout"]["ring_zones"].get(tier, []) else "grid"

## The zone of a structure type (layout.zones: homes, fields or plaza; "homes" if not named).
func zone_of(st: String) -> String:
	return str(C.get("layout", {}).get("zones", {}).get(st, "homes"))

## The lattice of `zone` (homes' for a zone without its own).
func _lattice(zone: String) -> Dictionary:
	var ls: Dictionary = C["layout"]["lattices"]
	return ls.get(zone, ls["homes"])

## The free place on the rings round the fire (layout.ring: the first at `first`, then every
## `step` up to `last`) nearest `anchor`, lots spaced as on the homes lattice; homes keep out
## of the fields wedge, the plaza doesn't. INF if none.
func _ring_spot(st: String, anchor: Vector2, center: Vector2, far: float, structs: Array, obstacles: Array, dry: float) -> Vector2:
	var lay: Dictionary = C["layout"]
	var L := _lattice(zone_of(st))
	var lot := maxf(float(D.STRUCTURES[st]["r"]), float(L["lot"]))
	var wedge := fields_dir(center)
	var half := deg_to_rad(float(lay["fields"]["half_angle"]))
	var region = D.region_at(center)
	var R := float(lay["ring"]["first"])
	var k := 0
	while R <= minf(far, float(lay["ring"]["last"])):
		var n := maxi(6, int(TAU * R / (2.0 * lot + float(L["gap"]))))
		var cells: Array = []
		for i in n:
			var a := wedge + PI + TAU * (i + 0.5 * (k % 2)) / n
			if zone_of(st) != "plaza" and absf(angle_difference(wedge, a)) < half: continue
			var p := center + Vector2.from_angle(a) * R
			cells.append([p.distance_squared_to(anchor), p])
		cells.sort_custom(func(x, y): return x[0] < y[0])
		for c in cells:
			var p: Vector2 = c[1]
			if D.region_at(p) == region and is_free(p, lot, structs, obstacles, dry, float(L["gap"])): return p
		R += float(lay["ring"]["step"])
		k += 1
	return Vector2.INF

## One coordinate of lot `k` (never 0) on a lattice: lots `pitch` apart in blocks of `block`,
## a street of `street` between blocks and down the middle, through the settlement's centre.
static func lot_coord(k: int, L: Dictionary) -> float:
	var m := absi(k) - 1
	var pitch := float(L["pitch"])
	var x := float(L["street"]) / 2.0 + m * pitch + float(m / int(L["block"])) * float(L["street"]) + pitch / 2.0
	return x if k > 0 else -x

## The nearest free lot to `anchor` for `st` on its lattice round `center`, beyond the core,
## within `far`, inside the fields wedge for fields and outside it for the rest; INF if none.
func _grid_spot(st: String, anchor: Vector2, center: Vector2, far: float, structs: Array, obstacles: Array, dry: float) -> Vector2:
	var lay: Dictionary = C["layout"]
	var zone := zone_of(st)
	var L := _lattice(zone)
	var lot := maxf(float(D.STRUCTURES[st]["r"]), float(L["lot"]))
	var core := float(lay.get("core", 0))
	var wedge := fields_dir(center)
	var half := deg_to_rad(float(lay["fields"]["half_angle"]))
	var region = D.region_at(center)
	var n := int(far / float(L["pitch"])) + 2
	var cells: Array = []
	for i in range(-n, n + 1):
		if i == 0: continue
		for j in range(-n, n + 1):
			if j == 0: continue
			var p := center + Vector2(lot_coord(i, L), lot_coord(j, L))
			var d := p.distance_to(center)
			if d < core or d > far: continue
			var inside := absf(angle_difference(wedge, (p - center).angle())) < half
			if inside != (zone == "fields"): continue
			cells.append([p.distance_squared_to(anchor), p])
	cells.sort_custom(func(a, b): return a[0] < b[0])
	for c in cells:
		var p: Vector2 = c[1]
		if D.region_at(p) == region and is_free(p, lot, structs, obstacles, dry, float(L["gap"])): return p
	return Vector2.INF

## The way settlement `center`'s fields lie (an angle), chosen once (saved in `plans`): toward
## the most open land on its own side of the water (layout.fields).
func fields_dir(center: Vector2) -> float:
	var key := "%d,%d" % [roundi(center.x), roundi(center.y)]
	if plans.has(key): return float(plans[key]["fields"])
	var F: Dictionary = C["layout"]["fields"]
	var look: Array = F["look"]
	var clear := float(F["clear"])
	var region = D.region_at(center)
	var wild: Array = sim.nodes.filter(func(n): return n.kind in ["tree", "bush", "boulder"] and n.pos.distance_to(center) < float(look[1]) + clear)
	var best := 0.0
	var best_s := -INF
	for i in 16:
		var a := TAU * i / 16.0
		var sc := 0.0
		var d := float(look[0])
		while d <= float(look[1]):
			var q := center + Vector2.from_angle(a) * d
			if D.is_water(q) or D.region_at(q) != region or q.x < 40 or q.y < 40 or q.x > D.W - 40 or q.y > D.H - 40: sc -= 10.0
			else:
				for nd in wild:
					if nd.pos.distance_to(q) < clear: sc -= 1.0
			d += 50.0
		if sc > best_s:
			best_s = sc
			best = a
	plans[key] = {"fields": best}
	return best

## Whether a building of radius r fits at p: on dry land clear of the water's reach (and
## of `dry` from the river), `gap` from `structs` (on a wall's ring line counts, inside it
## doesn't), clear of `obstacles` (nodes) and landmarks. Rival clans lay out by it too.
func is_free(p: Vector2, r: float, structs: Array, obstacles: Array, dry := 0.0, gap := -1.0) -> bool:
	if p.x < 40 or p.y < 40 or p.x > D.W - 40 or p.y > D.H - 40: return false
	if D.is_water(p) or D.river_dist(p) < maxf(sim.wet_reach(), dry) + r: return false
	if gap < 0.0: gap = float(C.get("gap", 14))
	for s in structs:
		var sr: float = sim.struct_r(s)
		var dist: float = s.pos.distance_to(p)
		if D.STRUCTURES[s.type].get("ring", false):
			if absf(dist - sr) < r + gap: return false # (inside the ring is fine, not on it)
		elif dist < sr + r + gap: return false
	for n in obstacles:
		if n.pos.distance_to(p) < r + 10: return false
	for lm in sim.landmarks:
		if lm["pos"].distance_to(p) < r + 40: return false
	return true

## For a game master: what the planner is doing.
func summary() -> Dictionary:
	return {"on": on, "planner": planner().name if planner() else "", "open_sites": open_sites(),
		"wanted": wanted().map(func(r): return r["structure"]), "asking": asking.get("options", []), "last": last,
		"layout": {"homes": placing("hut", D.VILLAGE), "fields_toward": roundi(rad_to_deg(fields_dir(D.VILLAGE)))},
		"outdated": D.STRUCTURES.keys().filter(func(t): return sim.obsolete(t))}
