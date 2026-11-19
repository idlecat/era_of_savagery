## Roads: a level for every cell of the foot-wear grid (sim.wear, WEAR_CELL paces). Owned
## by the simulation as `sim.roads`; config/roads.json holds the levels and numbers.
##   0     open ground
##   1     a trail: emerges where people walk again and again (foot wear above emerge_wear),
##         fades after fade_days without enough feet
##   2+    built roads (packed earth, stone): laid out with lay() along a route (over the
##         fords), paid per cell, built cell by cell by workers on a "roadworks" site;
##         they never fade
## People walk faster on them (speed_at()). The terrain shader paints them from the wear
## texture's red channel (world_view), so a road is part of the ground.
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")

var C: Dictionary = preload("res://scripts/config.gd").load_cfg("roads")

var sim
var level := PackedByteArray() # per wear cell
var life := PackedFloat32Array() # a trail's hold on the ground: 1 fresh .. 0 gone
var _t := 0.0

func _init(s) -> void:
	sim = s

func setup() -> void:
	var n: int = sim.wear_w * sim.wear_h
	level.resize(n)
	level.fill(0)
	life.resize(n)
	life.fill(0.0)

## The levels as configured (index + 1 = level: 1 is the trail).
func defs() -> Array: return C.get("levels", [])
func def_of(lv: int) -> Dictionary: return defs()[lv - 1] if lv >= 1 and lv <= defs().size() else {}
func index_of(id: String) -> int:
	for i in defs().size():
		if defs()[i].get("id", "") == id: return i + 1
	return 0

func cell(p: Vector2) -> int:
	return clampi(int(p.x / sim.WEAR_CELL), 0, sim.wear_w - 1) + clampi(int(p.y / sim.WEAR_CELL), 0, sim.wear_h - 1) * sim.wear_w
func cell_pos(k: int) -> Vector2:
	return Vector2((k % sim.wear_w + 0.5) * sim.WEAR_CELL, (k / sim.wear_w + 0.5) * sim.WEAR_CELL)
func level_at(p: Vector2) -> int: return level[cell(p)] if level.size() > 0 else 0

## How much faster people walk here.
func speed_at(p: Vector2) -> float:
	var lv := level_at(p)
	return float(def_of(lv).get("speed", 1.0)) if lv > 0 else 1.0

## Once a second: trails emerge where feet wear the ground, and fade where they no longer do.
func update(dt: float) -> void:
	_t -= dt
	if _t > 0 or level.size() != sim.wear.size(): return
	_t = 1.0
	var emerge := float(C.get("emerge_wear", 0.5))
	var keep := float(C.get("keep_wear", 0.12))
	var fade := 1.0 / maxf(1.0, float(C.get("fade_days", 4)) * D.DAY_LEN)
	for k in level.size():
		var w: float = sim.wear[k]
		if w >= emerge:
			if level[k] == 0: level[k] = 1
			if level[k] == 1: life[k] = 1.0
		elif level[k] == 1 and w < keep:
			life[k] -= fade
			if life[k] <= 0.0: level[k] = 0

## Why roads of level `lv` can't be built now ("" = they can).
func build_block(lv: int) -> String:
	var d := def_of(lv)
	if d.is_empty() or lv < 2: return "Unknown road"
	if not sim.story.holds(d.get("needs", {})):
		var nd: Dictionary = d.get("needs", {})
		if nd.has("invention") and not sim.inv.has(nd["invention"]): return sim.tr("Requires %s") % sim.tr(sim.inv.def(nd["invention"]).get("name", ""))
		if nd.has("tech") and not sim.has_tech(nd["tech"]): return sim.tr("Requires %s") % sim.tr(sim.evo.tech_def(nd["tech"]).get("name", ""))
		return "Not yet"
	return ""

## The best road level the tribe can build now (0 if none).
func best_buildable() -> int:
	var best := 0
	for i in range(2, defs().size() + 1):
		if build_block(i) == "": best = i
	return best

## The cells a road of level `lv` from a to b would lay (along the route over the fords;
## cells under water and those already as good are left out), in order from a.
func plan(a: Vector2, b: Vector2, lv: int) -> Array:
	var out: Array = []
	var seen := {}
	var pts: Array = [a] + D.route(a, b)
	for i in pts.size() - 1:
		var p0: Vector2 = pts[i]
		var p1: Vector2 = pts[i + 1]
		var steps := maxi(1, int(p0.distance_to(p1) / (sim.WEAR_CELL * 0.5)))
		for s in steps + 1:
			var p: Vector2 = p0.lerp(p1, float(s) / steps)
			var k := cell(p)
			if seen.has(k): continue
			seen[k] = true
			if D.in_river(cell_pos(k)) or level[k] >= lv: continue
			out.append(k)
	return out.slice(0, int(C.get("max_cells", 160)))

## What laying `cells` at level `lv` costs (cheaper over a trail or road already there).
func cost(cells: Array, lv: int) -> Dictionary:
	var d := def_of(lv)
	var out := {}
	var disc := float(C.get("trail_discount", 0.5))
	for k in cells:
		var f := disc if level[k] >= 1 else 1.0
		for r in d.get("cost", {}): out[r] = out.get(r, 0.0) + float(d["cost"][r]) * f
	for r in out: out[r] = ceili(out[r])
	return out

## Lay out a road of level `lv` (an id or a number) from a to b: paid now, built by
## `helpers` (else the Steward's idle hands). Returns "" or why not. For the Road tool,
## the Steward and a game master.
func lay(a: Vector2, b: Vector2, lv_id, helpers: Array = []) -> String:
	var lv: int = index_of(lv_id) if lv_id is String else int(lv_id)
	var why := build_block(lv)
	if why != "": return why
	var cells := plan(a, b, lv)
	return lay_cells(cells, lv, helpers)

func lay_cells(cells: Array, lv: int, helpers: Array = []) -> String:
	if cells.is_empty(): return "Nothing to build there"
	var c := cost(cells, lv)
	for r in c:
		if sim.stock.get(r, 0.0) < c[r]: return sim.tr("Needs %d %s") % [c[r], sim.tr(r)]
	sim.spend(c)
	var mid: Vector2 = cell_pos(cells[cells.size() / 2])
	var s: E.Structure = sim.add_structure("roadworks", mid, false, "village", true)
	s.cells = cells.map(func(k): return [k, lv])
	s.work = float(def_of(lv).get("work", 2.5)) * cells.size()
	for u in helpers: sim.assign_build(u, s)
	sim.add_log(sim.tr("A %s is laid out: %d paces of it.") % [sim.tr(def_of(lv)["name"]), roundi(cells.size() * sim.WEAR_CELL)], "build")
	return ""

## Road works: where the next cell to build is, and the cells finished as work goes on.
func next_cell_pos(s: E.Structure) -> Vector2:
	var per: float = s.work / maxf(1.0, s.cells.size())
	var i := clampi(int(s.progress / per), 0, s.cells.size() - 1)
	return cell_pos(int(s.cells[i][0]))

func progress(s: E.Structure) -> void:
	var per: float = s.work / maxf(1.0, s.cells.size())
	var done := mini(s.cells.size(), int(s.progress / per))
	for i in done:
		var k: int = s.cells[i][0]
		var lv: int = s.cells[i][1]
		if level[k] < lv: level[k] = lv

## The busiest trails near `at` (most foot wear first), for the Steward to upgrade.
func busiest_trails(at: Vector2, reach: float, n: int, below: int) -> Array:
	var cand: Array = []
	for k in level.size():
		if level[k] < 1 or level[k] >= below: continue
		var p := cell_pos(k)
		if p.distance_to(at) > reach or D.in_river(p): continue
		cand.append([sim.wear[k], k])
	cand.sort_custom(func(x, y): return x[0] > y[0])
	var ks: Array = cand.slice(0, n).map(func(e): return e[1])
	ks.sort_custom(func(x, y): return cell_pos(x).distance_to(at) < cell_pos(y).distance_to(at))
	return ks

## For a game master: how much of each level there is.
func summary() -> Dictionary:
	var counts := {}
	for k in level.size():
		if level[k] > 0:
			var id: String = def_of(level[k]).get("id", str(level[k]))
			counts[id] = counts.get(id, 0) + 1
	return {"cells": counts, "cell_paces": sim.WEAR_CELL, "can_build": def_of(best_buildable()).get("id", "")}
