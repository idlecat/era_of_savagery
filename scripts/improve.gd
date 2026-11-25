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
	timer = float(C.get("every", 15))
	if not on or sim.rest_time() or planner() == null: return
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
		if sim.stock["wood"] < sd["wood"] + reserve or sim.stock["stone"] < sd.get("stone", 0): continue
		if sim.structures.any(func(s): return not s.built and s.type == st and sim.ours(s)): continue # one at a time
		if not sim.story.holds(r.get("when", {})): continue
		if spot(st, str(r.get("near", "village"))) == Vector2.INF: continue
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
		for o in sim.upgrades_for(s):
			if o["to"] == to and o["why"] == "" and sim.stock["wood"] >= o["wood"] + reserve and (best == null or s.pos.distance_to(D.VILLAGE) < best.pos.distance_to(D.VILLAGE)): best = s
	return best

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
	var r := _rule(st)
	if r.is_empty() or not wanted().any(func(w): return w["structure"] == st): # (things changed meanwhile)
		var now := wanted()
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
	var p := spot(st, str(r.get("near", "village")))
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

# ------------------------------------------------------------ where to build
## A free spot for `st` near `near` ("village", or a structure type: the one of ours
## nearest the village), on the village's side of the water. Vector2.INF if none.
func spot(st: String, near: String) -> Vector2:
	var anchor: Vector2 = D.VILLAGE
	if near != "village":
		var best = null
		for s in sim.structures:
			if s.built and sim.ours(s) and s.type == near and (best == null or s.pos.distance_to(D.VILLAGE) < best.pos.distance_to(D.VILLAGE)): best = s
		if best and best.pos.distance_to(D.VILLAGE) < reach(): anchor = best.pos
	var r: float = D.STRUCTURES[st]["r"]
	var step := float(C.get("ring_step", 35))
	var region = D.region_at(D.VILLAGE)
	var far := reach()
	var dry: float = sim.nat.flood_band() if int(D.STRUCTURES[st].get("cap", 0)) > 0 else 0.0 # (homes stand clear of the spring flood; fields may take the silt)
	var near_structs: Array = sim.structures.filter(func(s): return s.pos.distance_to(anchor) < far + 200)
	var near_nodes: Array = sim.nodes.filter(func(n): return (n.kind in ["tree", "bush", "boulder"] or n.kind in D.FINDS) and n.pos.distance_to(anchor) < far + 60)
	var d := step * 1.5
	while d <= far:
		var n := maxi(8, int(TAU * d / step))
		var a0 := float(sim.structures.size()) * 0.7 # (varies between sites, deterministic)
		for i in n:
			var p: Vector2 = anchor + Vector2.from_angle(a0 + TAU * i / n) * d
			if p.distance_to(D.VILLAGE) < far and D.region_at(p) == region and _free(p, r, near_structs, near_nodes, dry): return p
		d += step
	return Vector2.INF

func _free(p: Vector2, r: float, structs: Array, obstacles: Array, dry := 0.0) -> bool:
	if p.x < 40 or p.y < 40 or p.x > D.W - 40 or p.y > D.H - 40: return false
	if D.is_water(p) or D.river_dist(p) < maxf(sim.wet_reach(), dry) + r: return false
	var gap := float(C.get("gap", 14))
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
		"wanted": wanted().map(func(r): return r["structure"]), "asking": asking.get("options", []), "last": last}
