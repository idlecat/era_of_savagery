## Random maps: picks the map size, lays a meandering river with one ford, puts the
## home village on its west bank, then scatters the chosen number of rival clans (drawn
## at random from the clan pool) and the landmarks across the land, keeping everything
## spaced out. It only writes the static map vars in data.gd; sim.new_game() then
## grows forests, herds and finds to fit. Same size + clans + seed = same map.
extends RefCounted

const D = preload("res://scripts/data.gd")

## size id -> world size, how many clans fit, and the default.
const SIZES := {
	"small": {"name": "Small", "w": 4400.0, "h": 3000.0, "max": 3, "def": 2},
	"standard": {"name": "Standard", "w": 6400.0, "h": 4400.0, "max": 6, "def": 4},
	"large": {"name": "Large", "w": 8000.0, "h": 5400.0, "max": 8, "def": 6},
	"huge": {"name": "Huge", "w": 9600.0, "h": 6400.0, "max": 10, "def": 8},
}
const SIZE_ORDER := ["small", "standard", "large", "huge"]
## Landmarks in order of importance: small maps keep the first ones.
const LANDMARK_ORDER := ["volcano", "grove", "flint", "cave", "spring", "stones", "peak", "mammoth", "den_n", "den_s", "hands", "bison", "wind_peak", "mist", "ring_w", "den_w"]
const EARLY := ["grove", "flint", "cave"] # within a scout's first trips

static func clan_pool() -> Array:
	return D.CLASSIC_RIVALS + D.EXTRA_CLANS

## Most clans a map of this size can host (also capped by the clan pool).
static func max_tribes(size: String) -> int:
	return mini(SIZES[size]["max"], clan_pool().size())

## Build a random map into data.gd's static vars.
static func generate(size: String, tribes: int, seed_v: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var sz: Dictionary = SIZES[size]
	tribes = clampi(tribes, 1, max_tribes(size))
	D.W = sz["w"]
	D.H = sz["h"]
	# river and ford; the village sits on the west bank by the ford, as on the classic map
	D.RIVER_BASE_X = roundf(D.W * rng.randf_range(0.46, 0.6))
	D.RIVER_PHASE = rng.randf_range(0.0, 1000.0)
	var fy := roundf(D.H * rng.randf_range(0.36, 0.64))
	D.FORD_Y = fy
	D.FORD_Y0 = fy - 45.0
	D.FORD_Y1 = fy + 45.0
	var rx := D.river_x(fy)
	D.VILLAGE = Vector2(roundf(rx - 660.0), fy)
	D.EAST_SITE = Vector2(roundf(rx + 340.0), fy)
	D.HOME_OFS = D.VILLAGE - Vector2(520, 560)
	# rival clans: drawn from the pool, spread out, away from home and the river
	var pool: Array = clan_pool().duplicate(true)
	_shuffle(pool, rng)
	var taken: Array = [D.VILLAGE, D.EAST_SITE]
	var clans: Array = []
	var sep := clampf(sqrt(D.W * D.H / (tribes + 1)) * 0.6, 800.0, 1800.0)
	for i in tribes:
		var c: Dictionary = pool[i]
		c["pos"] = _spot(rng, taken, sep, 1100.0, INF, 350.0, 420.0)
		taken.append(c["pos"])
		clans.append(c)
	D.RIVALS = clans
	# landmarks: as many as the map has room for, the most useful first
	var by_id := {}
	for lm in D.CLASSIC_LANDMARKS: by_id[lm["id"]] = lm
	var n_lm := clampi(roundi(16.0 * D.area_k()), 7, LANDMARK_ORDER.size())
	var lms: Array = []
	var spots: Array = taken.duplicate() # keep clear of villages too
	for i in n_lm:
		var lm: Dictionary = by_id[LANDMARK_ORDER[i]].duplicate(true)
		var id: String = lm["id"]
		var near := 900.0
		var far := INF
		if id in EARLY:
			near = 650.0
			far = 1500.0
		elif lm["kind"] == "den":
			near = 1300.0
		elif id == "volcano":
			near = 1800.0
		lm["pos"] = _spot(rng, spots, 520.0, near, far, 260.0, 260.0)
		spots.append(lm["pos"])
		if id == "volcano": D.VOLCANO = lm["pos"]
		lms.append(lm)
	D.LANDMARKS = lms
	D.MAP = {"kind": "random", "size": size, "tribes": tribes, "seed": seed_v}

## A random spot at least `sep` from every point in `taken`, between `near` and `far`
## from the village, clear of the river by `river` and of the map edge by `edge`.
## Spacing relaxes a little after each run of failures, so it always finds a place.
static func _spot(rng: RandomNumberGenerator, taken: Array, sep: float, near: float, far: float, river: float, edge: float) -> Vector2:
	var best := Vector2(edge, edge)
	for k in 1200:
		var relax := pow(0.93, k / 60)
		var p := Vector2(rng.randf_range(edge, D.W - edge), rng.randf_range(edge, D.H - edge))
		var dv := p.distance_to(D.VILLAGE)
		if dv < near * relax or dv > far / relax: continue
		if absf(p.x - D.river_x(p.y)) < river: continue
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
