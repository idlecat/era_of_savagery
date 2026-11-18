## Random maps, with nothing pre-configured: the land, the tribe and its neighbours are
## all drawn from the seed. Lays one to three meandering rivers (tributaries join the main
## one), puts fords on them until every stretch of land can be reached, settles the
## village near water, then scatters the rival clans (drawn from D.CLANS), landmarks made
## from D.LANDMARK_KINDS, sites for frontier settlements, and a starting tribe with random
## names, temperaments and memories. Builds a map spec and hands it to D.load_map();
## sim.new_game() then grows forests, herds and finds to fit. Same size + clans + seed =
## same map. No scripted events.
extends RefCounted

const D = preload("res://scripts/data.gd")

## size id -> world size, how many clans fit, and the default.
const SIZES := {
	"small": {"name": "Small", "w": 4400.0, "h": 3000.0, "max": 3, "def": 2, "rivers": [1, 1, 2]},
	"standard": {"name": "Standard", "w": 6400.0, "h": 4400.0, "max": 6, "def": 4, "rivers": [1, 2]},
	"large": {"name": "Large", "w": 8000.0, "h": 5400.0, "max": 8, "def": 6, "rivers": [2, 2, 3]},
	"huge": {"name": "Huge", "w": 9600.0, "h": 6400.0, "max": 10, "def": 8, "rivers": [2, 3]},
}
const SIZE_ORDER := ["small", "standard", "large", "huge"]
const EARLY := ["grove", "flint", "cave"] # one of each within a scout's first trips
const FILL_KINDS := ["cave", "stones", "bones", "peak", "spring", "cave", "stones", "bones", "peak", "spring", "grove", "flint"]
const HUTS := [Vector2(-90, -90), Vector2(90, -95), Vector2(-80, 100), Vector2(100, 105)]

static func clan_pool() -> Array:
	return D.CLANS

## Most clans a map of this size can host (also capped by the clan pool).
static func max_tribes(size: String) -> int:
	return mini(SIZES[size]["max"], clan_pool().size())

## Build a random map into data.gd's static vars.
static func generate(size: String, tribes: int, seed_v: int, land := "random") -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var sz: Dictionary = SIZES[size]
	tribes = clampi(tribes, 1, max_tribes(size))
	D.W = sz["w"]
	D.H = sz["h"]
	var counts: Array = sz["rivers"]
	var rivers := _rivers(rng, counts[rng.randi() % counts.size()])
	var fords := _fords(rng, rivers)
	D.set_water(rivers, fords)
	_connect(rivers, fords)
	D.VILLAGE = _village(rng)
	D.HOME_REGION = D.region_at(D.VILLAGE)
	var taken: Array = [D.VILLAGE]
	# rival clans: drawn from the pool, spread out, away from home and the water
	var pool: Array = clan_pool().duplicate(true)
	_shuffle(pool, rng)
	var clans: Array = []
	var sep := clampf(sqrt(D.W * D.H / (tribes + 1)) * 0.6, 800.0, 1800.0)
	for i in tribes:
		var c: Dictionary = pool[i]
		c["pos"] = _spot(rng, taken, sep, 1100.0, INF, 350.0, 420.0)
		taken.append(c["pos"])
		clans.append(c)
	var lms := _landmarks(rng, size, taken)
	var spots: Array = taken.duplicate()
	for lm in lms: spots.append(lm["pos"])
	var sites := _sites(rng, clans, spots)
	D.load_map({
		"w": D.W, "h": D.H, "water_ready": true, "rivers": rivers, "fords": fords,
		"village": D.VILLAGE, "home": _home(rng), "sites": sites, "clans": clans, "landmarks": lms,
		"land": preload("res://scripts/lands.gd").resolve(land, seed_v, true),
		"tribe": _tribe(rng), "children": _children(rng), "start_jobs": [], "labels": [], "script": [],
		"info": {"kind": "random", "size": size, "tribes": tribes, "seed": seed_v, "name": "Random · %s" % sz["name"], "brief": "",
			"intro": ["The tribe gathers around the bonfire, in a land no one has walked before."]},
	})

# ------------------------------------------------------------ rivers and fords
static func _rivers(rng: RandomNumberGenerator, n: int) -> Array:
	var out: Array = []
	var vertical := rng.randf() < 0.65 # the main river runs north-south (else west-east)
	var a: Vector2
	var b: Vector2
	if vertical:
		a = Vector2(D.W * rng.randf_range(0.3, 0.7), -80)
		b = Vector2(D.W * rng.randf_range(0.3, 0.7), D.H + 80)
	else:
		a = Vector2(-80, D.H * rng.randf_range(0.3, 0.7))
		b = Vector2(D.W + 80, D.H * rng.randf_range(0.3, 0.7))
	var main := _path(rng, a, b, (D.W if vertical else D.H) * 0.07, false)
	out.append(main)
	# tributaries flow in from the side edges, alternating sides
	var side := 1.0 if rng.randf() < 0.5 else -1.0
	var used: Array = []
	for k in n - 1:
		var start := Vector2.ZERO
		for _try in 20:
			var f := rng.randf_range(0.18, 0.82)
			if used.any(func(u): return absf(u - f) < 0.3): continue
			used.append(f)
			start = Vector2(-80 if side < 0 else D.W + 80, D.H * f) if vertical else Vector2(D.W * f, -80 if side < 0 else D.H + 80)
			break
		if start == Vector2.ZERO: break
		# join the main river at the point nearest to straight across, nudged downstream
		var best := main[0]
		for p in main:
			if p.x < -20 or p.y < -20 or p.x > D.W + 20 or p.y > D.H + 20: continue
			var along := p.y if vertical else p.x
			var want := (start.y if vertical else start.x) + rng.randf_range(-0.12, 0.2) * (D.H if vertical else D.W)
			if absf(along - want) < absf((best.y if vertical else best.x) - want): best = p
		out.append(_path(rng, start, best, start.distance_to(best) * 0.06, true))
		side = -side
	return out

## A meandering river from a to b: a smoothed line through jittered control points, plus
## the small sway of a lowland river. `join`: b lies on another river (no sway there).
static func _path(rng: RandomNumberGenerator, a: Vector2, b: Vector2, wiggle: float, join: bool) -> PackedVector2Array:
	var n := 6
	var dir := b - a
	var nrm := Vector2(-dir.y, dir.x).normalized()
	var ctrl: Array = [a]
	for i in range(1, n):
		var taper := 1.0 if not join or i < n - 1 else 0.3
		ctrl.append(a + dir * (float(i) / n) + nrm * rng.randf_range(-wiggle, wiggle) * taper)
	ctrl.append(b)
	var raw := PackedVector2Array()
	for i in ctrl.size() - 1:
		var p0: Vector2 = ctrl[maxi(i - 1, 0)]
		var p1: Vector2 = ctrl[i]
		var p2: Vector2 = ctrl[i + 1]
		var p3: Vector2 = ctrl[mini(i + 2, ctrl.size() - 1)]
		var steps := maxi(2, ceili(p1.distance_to(p2) / 30.0))
		for k in steps:
			var t := float(k) / steps
			var t2 := t * t
			var t3 := t2 * t
			raw.append(0.5 * ((2.0 * p1) + (p2 - p0) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (3.0 * p1 - p0 - 3.0 * p2 + p3) * t3))
	raw.append(b)
	var out := PackedVector2Array()
	var phase := rng.randf() * TAU
	var s := 0.0
	var total := 0.0
	for i in raw.size() - 1: total += raw[i].distance_to(raw[i + 1])
	for i in raw.size():
		if i > 0: s += raw[i].distance_to(raw[i - 1])
		var tg := (raw[mini(i + 1, raw.size() - 1)] - raw[maxi(i - 1, 0)]).normalized()
		var amp := 38.0 * (clampf((total - s) / 250.0, 0.0, 1.0) if join else 1.0)
		out.append(raw[i] + Vector2(-tg.y, tg.x) * amp * sin(s / 170.0 + phase))
	return out

static func _on_map(p: Vector2, m: float) -> bool:
	return p.x > m and p.y > m and p.x < D.W - m and p.y < D.H - m

## One to three fords per river, spread along it, away from the map edges and junctions.
static func _fords(rng: RandomNumberGenerator, rivers: Array) -> Array:
	var out: Array = []
	for ri in rivers.size():
		var pts: PackedVector2Array = rivers[ri]
		var inside: Array = []
		for p in pts:
			if _on_map(p, 350.0): inside.append(p)
		if inside.is_empty(): continue
		var length := 30.0 * inside.size()
		var want := clampi(roundi(length / 3000.0), 1, 3)
		for k in want:
			for _try in 30:
				var p: Vector2 = inside[rng.randi_range(inside.size() / 8, inside.size() - 1 - inside.size() / 8)]
				if out.any(func(f): return f.distance_to(p) < 1300.0): continue
				if _near_other_river(p, rivers, ri, 400.0): continue
				out.append(p)
				break
	return out

static func _near_other_river(p: Vector2, rivers: Array, ri: int, r: float) -> bool:
	for rj in rivers.size():
		if rj == ri: continue
		for q in rivers[rj]:
			if q.distance_to(p) < r: return true
	return false

## Add fords until every sizeable stretch of land can be reached from the largest one.
static func _connect(rivers: Array, fords: Array) -> void:
	for _round in 6:
		var big := -1
		for r in D.REGIONS:
			if big < 0 or D.REGIONS[r] > D.REGIONS[big]: big = r
		var reached := {big: true}
		var grew := true
		while grew:
			grew = false
			for f in D.FORDS:
				if reached.has(f["ra"]) != reached.has(f["rb"]) and f["ra"] >= 0 and f["rb"] >= 0:
					reached[f["ra"]] = true
					reached[f["rb"]] = true
					grew = true
		var added := false
		for ri in rivers.size():
			if added: break
			var pts: PackedVector2Array = rivers[ri]
			for k in range(0, pts.size(), 7):
				var p: Vector2 = pts[k]
				if not _on_map(p, 350.0) or _near_other_river(p, rivers, ri, 400.0): continue
				if fords.any(func(f): return f.distance_to(p) < 700.0): continue
				var tg := (pts[mini(k + 1, pts.size() - 1)] - pts[maxi(k - 1, 0)]).normalized()
				var nr := Vector2(-tg.y, tg.x)
				var ra := D.region_at(p - nr * (D.RIVER_HALF + 60.0))
				var rb := D.region_at(p + nr * (D.RIVER_HALF + 60.0))
				if ra < 0 or rb < 0 or reached.has(ra) == reached.has(rb): continue
				var lost: int = rb if reached.has(ra) else ra
				if D.REGIONS.get(lost, 0) < 60: continue
				fords.append(p)
				added = true
				break
		if not added: return
		D.set_water(rivers, fords)

# ------------------------------------------------------------ the village and its land
## Near the water (fish, a ford to cross) but not on the bank, well inside the map.
static func _village(rng: RandomNumberGenerator) -> Vector2:
	var edge := minf(900.0, minf(D.W, D.H) * 0.22)
	var total := 0
	for r in D.REGIONS: total += D.REGIONS[r]
	var best := Vector2(D.W / 2, D.H / 2)
	var best_s := INF
	for k in 400:
		var p := Vector2(rng.randf_range(edge, D.W - edge), rng.randf_range(edge, D.H - edge))
		var rd := D.river_dist(p)
		if rd < 420.0 or rd > 1000.0: continue
		var r := D.region_at(p)
		if r < 0 or D.REGIONS.get(r, 0) < total * 0.18: continue
		var fd := INF
		for f in D.FORDS: fd = minf(fd, p.distance_to(f["p"]))
		var s := absf(rd - 620.0) + 0.25 * minf(fd, 4000.0) + rng.randf_range(0.0, 250.0)
		if s < best_s:
			best_s = s
			best = p
	return best.round()

## Huts round the bonfire, home forests and berry bushes on the village's side of the water.
static func _home(rng: RandomNumberGenerator) -> Dictionary:
	var huts: Array = HUTS.map(func(o): return D.VILLAGE + o)
	var forests: Array = []
	var a0 := rng.randf() * TAU
	for i in 7:
		var near := i < 4
		for _try in 30:
			var p: Vector2 = D.VILLAGE + Vector2.from_angle(a0 + i * TAU / 7 + rng.randf_range(-0.4, 0.4)) * rng.randf_range(380, 650 if near else 1250)
			if not _on_map(p, 150.0) or D.river_dist(p) < 220.0: continue
			if near and not D.home_side(p): continue
			forests.append([p.round(), rng.randi_range(14, 22), rng.randf_range(120, 170)])
			break
	var bushes: Array = []
	for i in 7:
		for _try in 30:
			var p: Vector2 = D.VILLAGE + Vector2.from_angle(rng.randf() * TAU) * (rng.randf_range(220, 330) if i < 5 else rng.randf_range(600, 800))
			if D.river_dist(p) < 90.0 or not D.home_side(p) or huts.any(func(h): return h.distance_to(p) < 70): continue
			bushes.append(p.round())
			break
	return {"huts": huts, "forests": forests, "bushes": bushes}

## Landmarks made from the templates: one each of the early kinds near home, saber-tooth
## dens and a Fire Mountain farther out, and as many more as the land has room for.
static func _landmarks(rng: RandomNumberGenerator, size: String, taken: Array) -> Array:
	var n := clampi(roundi(16.0 * D.area_k()), 8, 30)
	var kinds: Array = EARLY.duplicate()
	if size != "small" or rng.randf() < 0.5: kinds.append("volcano")
	for k in clampi(roundi(3.0 * D.area_k()), 1, 6): kinds.append("den")
	while kinds.size() < n: kinds.append(FILL_KINDS[rng.randi() % FILL_KINDS.size()])
	var names := {}
	for k in D.LANDMARK_KINDS:
		var l: Array = D.LANDMARK_KINDS[k]["names"].duplicate()
		_shuffle(l, rng)
		names[k] = l
	var used := {}
	var spots: Array = taken.duplicate() # keep clear of villages too
	var out: Array = []
	var early_done := {}
	for kind in kinds:
		var tpl: Dictionary = D.LANDMARK_KINDS[kind]
		var idx: int = used.get(kind, 0)
		used[kind] = idx + 1
		var lm := {"id": "%s_%d" % [kind, idx + 1], "kind": kind, "name": names[kind][idx % names[kind].size()],
			"text": tpl["texts"][rng.randi() % tpl["texts"].size()], "insight": tpl["insight"].duplicate(), "reward": tpl["reward"].duplicate()}
		for f in ["reveal", "devotion"]:
			if tpl.has(f): lm[f] = tpl[f]
		if kind == "den": lm["den"] = rng.randi_range(1, 2)
		var near := 900.0
		var far := INF
		if kind in EARLY and not early_done.has(kind):
			early_done[kind] = true
			near = 650.0
			far = 1500.0
		elif kind == "den":
			near = 1300.0
		elif kind == "volcano":
			near = 1800.0
		lm["pos"] = _spot(rng, spots, 520.0, near, far, 260.0, 260.0)
		spots.append(lm["pos"])
		out.append(lm)
	return out

## Good places for a frontier settlement: open land near water, a long walk from home and
## clear of the clans, ordered by how far the walk is (across the water first if close).
static func _sites(rng: RandomNumberGenerator, clans: Array, spots: Array) -> Array:
	var cands: Array = []
	for k in 500:
		var p := Vector2(rng.randf_range(350, D.W - 350), rng.randf_range(350, D.H - 350))
		var rd := D.river_dist(p)
		if rd < 200.0 or rd > 650.0: continue
		var r := D.region_at(p)
		if r < 0 or D.REGIONS.get(r, 0) < 60: continue
		var dv := p.distance_to(D.VILLAGE)
		if dv < 950.0 or dv > 2800.0: continue
		if clans.any(func(c): return c["pos"].distance_to(p) < 750.0): continue
		if spots.any(func(s): return s.distance_to(p) < 300.0): continue
		if cands.any(func(c): return c[0].distance_to(p) < 900.0): continue
		cands.append([p.round(), D.route_len(D.VILLAGE, p) - (300.0 if not D.home_side(p) else 0.0)])
		if cands.size() >= 5: break
	cands.sort_custom(func(a, b): return a[1] < b[1])
	var out: Array = cands.map(func(c): return c[0])
	if out.is_empty(): out.append(D.random_land(-1, 300.0, rng))
	return out

# ------------------------------------------------------------ the tribe
## Nine adults with random names and temperaments (the first three a builder, a fighter
## and a mystic, so every kind of contract has a leader), skills to match, a memory or two.
static func _tribe(rng: RandomNumberGenerator) -> Array:
	var names: Array = D.TRIBE_NAMES.duplicate()
	_shuffle(names, rng)
	var colors: Array = D.TRIBE_COLORS.duplicate()
	_shuffle(colors, rng)
	var temps: Array = ["cautious", "belligerent", "devout"]
	var lazy := false
	while temps.size() < 9:
		var t: String = D.TEMPERAMENTS.keys()[rng.randi() % D.TEMPERAMENTS.size()]
		if t == "lazy":
			if lazy: continue
			lazy = true
		temps.append(t)
	var epithets_used := {}
	var mem_used := {}
	var out: Array = []
	for i in 9:
		var t: String = temps[i]
		var tm: Dictionary = D.TEMPERAMENTS[t]
		var skills := {}
		for s in D.SKILLS: skills[s] = rng.randi_range(0, 1)
		skills[tm["skill"]] += rng.randi_range(2, 3)
		var other: String = D.SKILLS[rng.randi() % D.SKILLS.size()]
		skills[other] = mini(4, skills[other] + 1)
		skills[tm["skill"]] = mini(4, skills[tm["skill"]])
		var ep: String = tm["epithets"][rng.randi() % tm["epithets"].size()]
		for e in tm["epithets"]:
			if not epithets_used.has(ep): break
			ep = e
		epithets_used[ep] = true
		var mems: Array = []
		for k in rng.randi_range(1, 2):
			var m: String = tm["memories"][rng.randi() % tm["memories"].size()]
			if mem_used.has(m): continue
			mem_used[m] = true
			mems.append({"day": -rng.randi_range(30, 400), "text": m, "impact": rng.randi_range(4, 9)})
		out.append({"name": names[i], "epithet": ep, "traits": [t], "color": Color(colors[i % colors.size()]),
			"hp": 42 + skills["combat"] * 3 + rng.randi_range(0, 6), "atk": 3 + skills["combat"] + rng.randi_range(0, 1),
			"def": 2 + rng.randi_range(0, 1), "spd": 0.9 if t == "lazy" else snappedf(rng.randf_range(0.92, 1.15), 0.05),
			"skills": skills, "memory": mems})
	return out

static func _children(rng: RandomNumberGenerator) -> Array:
	var pool: Array = D.BIRTH_NAMES.filter(func(n): return not n in D.TRIBE_NAMES)
	_shuffle(pool, rng)
	return pool.slice(0, 2)

# ------------------------------------------------------------ helpers
## A random spot at least `sep` from every point in `taken`, between `near` and `far`
## from the village, clear of the water by `river` and of the map edge by `edge`, on land
## that can be reached. Spacing relaxes a little after each run of failures.
static func _spot(rng: RandomNumberGenerator, taken: Array, sep: float, near: float, far: float, river: float, edge: float) -> Vector2:
	var best := Vector2(edge, edge)
	for k in 1200:
		var relax := pow(0.93, k / 60)
		var p := Vector2(rng.randf_range(edge, D.W - edge), rng.randf_range(edge, D.H - edge))
		var dv := p.distance_to(D.VILLAGE)
		if dv < near * relax or dv > far / relax: continue
		if D.river_dist(p) < river: continue
		var r := D.region_at(p)
		if r < 0 or D.REGIONS.get(r, 0) < 60: continue
		var ok := true
		for t in taken:
			if p.distance_to(t) < sep * relax:
				ok = false
				break
		if ok: return p.round()
		best = p
	return best.round()

static func _shuffle(a: Array, rng: RandomNumberGenerator) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t = a[i]
		a[i] = a[j]
		a[j] = t
