## Static game data: map geometry, structures, techs, traits, name pools.
extends RefCounted

## ---- The map ----
## The map is a set of static vars filled by load_map(): either from a scenario
## (scenarios/*.gd: a hand-made map with its own tribe, clans, landmarks and scripted
## events) or by mapgen.gd (a random map with nothing pre-configured). Rivers are
## polylines; fords are shallow crossings on them; rivers split the land into regions
## that are joined only by fords, and route() finds the way across.
const DAY_LEN := 90.0 # seconds per in-game day at 1x
const STD_AREA := 6400.0 * 4400.0 # wilderness counts are tuned for this size

static var W := 6400.0
static var H := 4400.0
static var VILLAGE := Vector2(2700, 2200)
## The home layout: huts (offsets from the bonfire), forests [centre, trees, spread], berry bushes.
static var HOME := {"huts": [], "forests": [], "bushes": []}
static var SITES: Array = [] # where frontier settlements can be founded, best first
static var VOLCANO := Vector2.INF # the Fire Mountain, if this land has one
static var RIVALS: Array = [] # clan defs + "pos"
static var LANDMARKS: Array = [] # {id, kind, name, pos, text, reward, insight, ...}
static var TRIBE: Array = [] # starting adults (character defs)
static var CHILDREN: Array = [] # names of the starting children
static var START_JOBS: Array = [] # [{"who", "job": "ritual"|"food"|"wood"}]; empty = chosen by trait
static var LABELS: Array = [] # extra map labels [{"text", "pos", "size"}]
static var SCRIPT: Array = [] # scenario triggers (story.gd); random maps have none
static var MAP := {} # how this map was made: {"kind": "scenario"|"random", "id", "name", "brief", "intro", ...}

## Fill the map from a spec (see scenarios/the_ford.gd for the fields).
static func load_map(spec: Dictionary) -> void:
	W = spec["w"]
	H = spec["h"]
	if not spec.get("water_ready", false): set_water(spec.get("rivers", []), spec.get("fords", []))
	VILLAGE = spec["village"]
	HOME = spec.get("home", {"huts": [], "forests": [], "bushes": []})
	SITES = spec.get("sites", [])
	RIVALS = spec.get("clans", [])
	LANDMARKS = spec.get("landmarks", [])
	VOLCANO = Vector2.INF
	for lm in LANDMARKS:
		if lm["kind"] == "volcano": VOLCANO = lm["pos"]
	TRIBE = spec.get("tribe", [])
	CHILDREN = spec.get("children", [])
	START_JOBS = spec.get("start_jobs", [])
	LABELS = spec.get("labels", [])
	SCRIPT = spec.get("script", [])
	MAP = spec.get("info", {})
	HOME_REGION = region_at(VILLAGE)

static func is_ready() -> bool: return not MAP.is_empty()
static func has_volcano() -> bool: return VOLCANO != Vector2.INF

## Map area relative to the standard size: scales forests, herds, finds...
static func area_k() -> float:
	return W * H / STD_AREA

const OVERPOP_THRESHOLD := 12 # PRD says 20; lowered so it fires in a short POC session

# ---- Water: rivers, fords and the land regions between them ----
const RIVER_HALF := 46.0
const FORD_LEN := 45.0 # half-length of a ford along the river
const GRID := 40.0 # water/region lookup grid
const REACH := 640.0 # river_dist() is exact up to here; farther away it is INF
static var RIVERS: Array = [] # [PackedVector2Array] centrelines (they run off the map edges)
static var FORDS: Array = [] # [{"p", "t" along, "n" across, "a", "b" land either side, "ra", "rb" their regions}]
static var REGIONS := {} # region id -> size in grid cells
static var HOME_REGION := 0
static var _sa := PackedVector2Array() # river segments
static var _sb := PackedVector2Array()
static var _sr := PackedInt32Array() # river of each segment
static var _gw := 0
static var _gh := 0
static var _gseg := PackedInt32Array() # nearest segment per cell (-1: no river in reach)
static var _greg := PackedInt32Array() # region per cell (-1: deep water)

## Lay the rivers and fords (ford points are on a river centreline) and work out the regions.
static func set_water(rivers: Array, ford_pts: Array) -> void:
	RIVERS = rivers
	_sa = PackedVector2Array()
	_sb = PackedVector2Array()
	_sr = PackedInt32Array()
	for ri in rivers.size():
		var pts: PackedVector2Array = rivers[ri]
		for k in pts.size() - 1:
			_sa.append(pts[k])
			_sb.append(pts[k + 1])
			_sr.append(ri)
	_gw = ceili(W / GRID)
	_gh = ceili(H / GRID)
	_gseg = PackedInt32Array()
	_gseg.resize(_gw * _gh)
	_gseg.fill(-1)
	var best := PackedFloat32Array()
	best.resize(_gw * _gh)
	best.fill(INF)
	for s in _sa.size():
		var a := _sa[s]
		var b := _sb[s]
		var x0 := maxi(0, int((minf(a.x, b.x) - REACH) / GRID))
		var x1 := mini(_gw - 1, int((maxf(a.x, b.x) + REACH) / GRID))
		var y0 := maxi(0, int((minf(a.y, b.y) - REACH) / GRID))
		var y1 := mini(_gh - 1, int((maxf(a.y, b.y) + REACH) / GRID))
		for gy in range(y0, y1 + 1):
			for gx in range(x0, x1 + 1):
				var d := _seg_d(Vector2((gx + 0.5) * GRID, (gy + 0.5) * GRID), a, b)
				var i := gy * _gw + gx
				if d < best[i] and d < REACH + GRID:
					best[i] = d
					_gseg[i] = s
	FORDS = []
	for fp in ford_pts:
		var info := river_info(fp)
		var tg: Vector2 = info["t"] if info["t"] != Vector2.ZERO else Vector2.DOWN
		var nr := Vector2(-tg.y, tg.x)
		var c: Vector2 = info["c"] if info["d"] < RIVER_HALF else fp
		FORDS.append({"p": c, "t": tg, "n": nr, "a": c - nr * (RIVER_HALF + 30.0), "b": c + nr * (RIVER_HALF + 30.0), "ra": -1, "rb": -1})
	_find_regions()
	for f in FORDS:
		f["ra"] = region_at(f["a"])
		f["rb"] = region_at(f["b"])

## Land cells joined without crossing deep water get the same region id (flood fill).
static func _find_regions() -> void:
	_greg = PackedInt32Array()
	_greg.resize(_gw * _gh)
	_greg.fill(-2) # -2 unvisited, -1 water
	REGIONS = {}
	for i in _gw * _gh:
		if river_dist(Vector2((i % _gw + 0.5) * GRID, (i / _gw + 0.5) * GRID)) < RIVER_HALF: _greg[i] = -1
	var next := 0
	for start in _gw * _gh:
		if _greg[start] != -2: continue
		var stack := PackedInt32Array([start])
		_greg[start] = next
		var n := 0
		while not stack.is_empty():
			var i: int = stack[stack.size() - 1]
			stack.resize(stack.size() - 1)
			n += 1
			var x := i % _gw
			var y := i / _gw
			for nb in [i - 1 if x > 0 else -1, i + 1 if x < _gw - 1 else -1, i - _gw if y > 0 else -1, i + _gw if y < _gh - 1 else -1]:
				if nb >= 0 and _greg[nb] == -2:
					_greg[nb] = next
					stack.append(nb)
		REGIONS[next] = n
		next += 1

static func _seg_d(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	var t := 0.0 if l2 == 0.0 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)

static func _seg_at(p: Vector2) -> int:
	if _gw == 0: return -1
	var gx := clampi(int(p.x / GRID), 0, _gw - 1)
	var gy := clampi(int(p.y / GRID), 0, _gh - 1)
	return _gseg[gy * _gw + gx]

## Distance from the nearest river's centreline (INF when none is within REACH).
static func river_dist(p: Vector2) -> float:
	var s := _seg_at(p)
	if s < 0: return INF
	var d := INF
	for k in range(maxi(0, s - 2), mini(_sa.size(), s + 3)):
		if _sr[k] == _sr[s]: d = minf(d, _seg_d(p, _sa[k], _sb[k]))
	return d

## The nearest river point: {"d" distance, "c" closest centreline point, "n" unit normal
## from the river toward p, "t" unit tangent, "river" index}; d = INF when none is in reach.
static func river_info(p: Vector2) -> Dictionary:
	var s := _seg_at(p)
	if s < 0: return {"d": INF, "c": p, "n": Vector2.ZERO, "t": Vector2.ZERO, "river": -1}
	var bd := INF
	var bc := p
	var bt := Vector2.ZERO
	for k in range(maxi(0, s - 2), mini(_sa.size(), s + 3)):
		if _sr[k] != _sr[s]: continue
		var a := _sa[k]
		var ab := _sb[k] - a
		var l2 := ab.length_squared()
		var t := 0.0 if l2 == 0.0 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
		var c := a + ab * t
		var d := p.distance_to(c)
		if d < bd:
			bd = d
			bc = c
			bt = ab.normalized()
	var nr := (p - bc).normalized() if bd > 0.01 else Vector2(-bt.y, bt.x)
	return {"d": bd, "c": bc, "n": nr, "t": bt, "river": _sr[s]}

## The nearest point on any river centreline, however far (slow: a full scan; for rare use).
static func nearest_river_point(p: Vector2) -> Vector2:
	var best := INF
	var out := p
	for s in _sa.size():
		var ab := _sb[s] - _sa[s]
		var l2 := maxf(ab.length_squared(), 0.0001)
		var c := _sa[s] + ab * clampf((p - _sa[s]).dot(ab) / l2, 0.0, 1.0)
		if p.distance_to(c) < best:
			best = p.distance_to(c)
			out = c
	return out

static func in_river(p: Vector2) -> bool:
	return river_dist(p) < RIVER_HALF

## The ford p stands on, or -1.
static func ford_at(p: Vector2) -> int:
	for i in FORDS.size():
		var f: Dictionary = FORDS[i]
		var q: Vector2 = p - f["p"]
		if absf(q.dot(f["t"])) < FORD_LEN and absf(q.dot(f["n"])) < RIVER_HALF + 24.0: return i
	return -1

static func is_ford_at(p: Vector2) -> bool:
	return ford_at(p) >= 0

## Deep water: river, but not a ford.
static func is_water(p: Vector2) -> bool:
	return in_river(p) and ford_at(p) < 0

## The nearest land point beyond the water's edge (margin past the bank) on p's side.
static func shore(p: Vector2, margin := 8.0) -> Vector2:
	var info := river_info(p)
	if info["d"] >= RIVER_HALF + margin: return p
	return info["c"] + info["n"] * (RIVER_HALF + margin)

## Which stretch of land p is on: rivers split the land, only fords join it.
static func region_at(p: Vector2) -> int:
	if _gw == 0: return 0
	var gx := clampi(int(p.x / GRID), 0, _gw - 1)
	var gy := clampi(int(p.y / GRID), 0, _gh - 1)
	var r := _greg[gy * _gw + gx]
	if r >= 0: return r
	var info := river_info(p) # in or by the water: the bank on p's side
	for k in [1.0, 2.0, 3.0]:
		var q: Vector2 = info["c"] + info["n"] * (RIVER_HALF + GRID * k)
		var r2 := _greg[clampi(int(q.y / GRID), 0, _gh - 1) * _gw + clampi(int(q.x / GRID), 0, _gw - 1)]
		if r2 >= 0: return r2
	return -1

static func home_side(p: Vector2) -> bool:
	return region_at(p) == HOME_REGION

static func same_side(a: Vector2, b: Vector2) -> bool:
	return region_at(a) == region_at(b)

## Waypoints from `from` to `to`, over fords where rivers lie between (ends with `to`).
static func route(from: Vector2, to: Vector2) -> Array:
	var rs := region_at(from)
	var re := region_at(to)
	var on_ford := ford_at(from)
	if (rs == re and on_ford < 0) or FORDS.is_empty(): return [to]
	# nodes: 0 = from, then each ford's two banks
	var pos: Array = [from]
	var reg: Array = [rs]
	for f in FORDS:
		pos.append(f["a"])
		reg.append(f["ra"])
		pos.append(f["b"])
		reg.append(f["rb"])
	var n := pos.size()
	var dist: Array = []
	var prev: Array = []
	var done: Array = []
	for i in n:
		dist.append(INF)
		prev.append(-1)
		done.append(false)
	dist[0] = 0.0
	if on_ford >= 0: # standing in a ford: either bank is a step away
		for k in [1 + on_ford * 2, 2 + on_ford * 2]:
			dist[k] = from.distance_to(pos[k])
			prev[k] = 0
	var best_end := INF
	var best_node := -1
	for _it in n:
		var u := -1
		for i in n:
			if not done[i] and dist[i] < INF and (u < 0 or dist[i] < dist[u]): u = i
		if u < 0: break
		done[u] = true
		if reg[u] == re and (u > 0 or on_ford < 0):
			var c: float = dist[u] + pos[u].distance_to(to)
			if c < best_end:
				best_end = c
				best_node = u
		for v in n:
			if done[v]: continue
			var w := INF
			if reg[v] == reg[u] and (u > 0 or on_ford < 0): w = pos[u].distance_to(pos[v])
			if u > 0 and v > 0 and (u - 1) / 2 == (v - 1) / 2: w = pos[u].distance_to(pos[v]) # across the ford
			if dist[u] + w < dist[v]:
				dist[v] = dist[u] + w
				prev[v] = u
	if best_node < 0: return [to] # no way across: walk along the bank
	var path: Array = [to]
	var k := best_node
	while k > 0:
		path.push_front(pos[k])
		k = prev[k]
	return path

## How far the walk from `from` to `to` is, fords included.
static func route_len(from: Vector2, to: Vector2) -> float:
	var l := 0.0
	var p := from
	for q in route(from, to):
		l += p.distance_to(q)
		p = q
	return l

## A random land point (in `region` unless -1), at least `margin` from the edges and the water.
static func random_land(region := -1, margin := 120.0, rng: RandomNumberGenerator = null) -> Vector2:
	var p := VILLAGE
	for k in 200:
		p = Vector2(rng.randf_range(margin, W - margin), rng.randf_range(margin, H - margin)) if rng else Vector2(randf_range(margin, W - margin), randf_range(margin, H - margin))
		if river_dist(p) < RIVER_HALF + 40.0: continue
		if region < 0 or region_at(p) == region: return p
	return p

## Rough compass direction from a to b, for descriptions ("north-east"...).
static func compass(a: Vector2, b: Vector2) -> String:
	var v := b - a
	var i := posmod(roundi(atan2(v.y, v.x) / (PI / 4.0)), 8)
	return ["east", "south-east", "south", "south-west", "west", "north-west", "north", "north-east"][i]

# ---- Exploration (fog of war) ----
const FOG_CELL := 40.0
const SIGHT_UNIT := 200.0
const SIGHT_SCOUT_BONUS := 30.0 # extra sight while auto-scouting
const SIGHT_STRUCT := 200.0
const SIGHT_BONFIRE := 300.0

# ---- Rival clans: their own villages, people and moods (see rivals.gd) ----
## relation -100 (blood feud) .. +100 (allies); "base" is where it drifts back to.
## The clan pool: scenarios place some by id, random maps draw from all of them.
const CLANS := [
	{"id": "ochre", "name": "Red Ochre Clan", "chief": "Gor", "epithet": "the Scarred", "culture": "martial",
		"color": Color("#c8452e"), "base": -25.0, "start": -20.0, "pop": 11, "era": 2,
		"strength": 1.2, "hunter_name": "Red Ochre hunter", "warrior_name": "Red Ochre warrior", "trader_name": "Red Ochre trader", "sells": "stone", "wants": "food", "knows": ["fire", "tools", "hide", "domestication"], "desc": "Hunters who paint themselves in red earth. They prize strength and take what they need."},
	{"id": "heron", "name": "Heron Clan", "chief": "Ama", "epithet": "Who Listens to Water", "culture": "spiritual",
		"color": Color("#3e8fc0"), "base": 10.0, "start": 5.0, "pop": 9, "era": 1,
		"strength": 0.85, "hunter_name": "Heron hunter", "warrior_name": "Heron warrior", "trader_name": "Heron trader", "sells": "food", "wants": "wood", "knows": ["fire", "pottery", "totems"], "desc": "River folk led by a seer. Slow to anger, but they never forget a wrong."},
	{"id": "tusk", "name": "Tusk Clan", "chief": "Dun", "epithet": "Broad-Shoulders", "culture": "martial",
		"color": Color("#8a5a2a"), "base": -15.0, "start": -10.0, "pop": 10, "era": 2,
		"strength": 1.1, "hunter_name": "Tusk hunter", "warrior_name": "Tusk warrior", "trader_name": "Tusk trader", "sells": "wood", "wants": "stone", "knows": ["fire", "tools", "hide"], "desc": "Forest hunters who wear boar tusks at the throat. Proud, and quick to fight over hunting grounds."},
	{"id": "elk", "name": "Elk Clan", "chief": "Sela", "epithet": "the Antlered Mother", "culture": "spiritual",
		"color": Color("#9a7ac8"), "base": 15.0, "start": 10.0, "pop": 9, "era": 1,
		"strength": 0.8, "hunter_name": "Elk hunter", "warrior_name": "Elk warrior", "trader_name": "Elk trader", "sells": "food", "wants": "stone", "knows": ["fire", "hide", "totems"], "desc": "Herders of the northern meadows who follow the elk. Gentle, generous, and wary of strangers with spears."},
	{"id": "hawk", "name": "Hawk Clan", "chief": "Varo", "epithet": "Sharp-Eye", "culture": "martial",
		"color": Color("#c8a030"), "base": -5.0, "start": 0.0, "pop": 12, "era": 2,
		"strength": 1.0, "hunter_name": "Hawk hunter", "warrior_name": "Hawk warrior", "trader_name": "Hawk trader", "sells": "stone", "wants": "wood", "knows": ["fire", "tools", "pottery", "domestication"], "desc": "Hill people who watch the plains from their high camp. They trade hard and fight harder."},
	{"id": "willow", "name": "Willow Clan", "chief": "Nao", "epithet": "Who Weaves", "culture": "spiritual",
		"color": Color("#5aa070"), "base": 5.0, "start": 0.0, "pop": 8, "era": 1,
		"strength": 0.75, "hunter_name": "Willow hunter", "warrior_name": "Willow warrior", "trader_name": "Willow trader", "sells": "wood", "wants": "food", "knows": ["fire", "pottery", "farming"], "desc": "Basket-weavers of the southern marshes who grow wild grain. Few, patient, and fond of gifts."},
	{"id": "bear", "name": "Bear Clan", "chief": "Brak", "epithet": "the Unbowed", "culture": "martial",
		"color": Color("#6a4a3a"), "base": -15.0, "start": -10.0, "pop": 10, "era": 2,
		"strength": 1.15, "hunter_name": "Bear hunter", "warrior_name": "Bear warrior", "trader_name": "Bear trader", "sells": "stone", "wants": "food", "knows": ["fire", "tools", "hide"], "desc": "Cave dwellers who wear the skins of the great bears they hunt. Stubborn, and they never back down."},
	{"id": "otter", "name": "Otter Clan", "chief": "Lio", "epithet": "Who Swims Upstream", "culture": "spiritual",
		"color": Color("#4aa0a0"), "base": 10.0, "start": 5.0, "pop": 8, "era": 1,
		"strength": 0.8, "hunter_name": "Otter hunter", "warrior_name": "Otter warrior", "trader_name": "Otter trader", "sells": "food", "wants": "wood", "knows": ["fire", "pottery"], "desc": "Fisher folk of the lakes and streams. Playful and curious, they welcome anyone who comes in peace."},
	{"id": "raven", "name": "Raven Clan", "chief": "Morra", "epithet": "the Far-Seeing", "culture": "spiritual",
		"color": Color("#5a5478"), "base": 0.0, "start": -5.0, "pop": 9, "era": 2,
		"strength": 0.9, "hunter_name": "Raven hunter", "warrior_name": "Raven warrior", "trader_name": "Raven trader", "sells": "food", "wants": "stone", "knows": ["fire", "totems", "hide"], "desc": "Followers of a seer who reads the flight of birds. Secretive; they trade in omens as much as goods."},
	{"id": "lynx", "name": "Lynx Clan", "chief": "Tok", "epithet": "Stone-Hand", "culture": "martial",
		"color": Color("#c87a50"), "base": -10.0, "start": -5.0, "pop": 11, "era": 2,
		"strength": 1.05, "hunter_name": "Lynx hunter", "warrior_name": "Lynx warrior", "trader_name": "Lynx trader", "sells": "stone", "wants": "wood", "knows": ["fire", "tools", "domestication"], "desc": "Silent stalkers of the high woods. They strike from cover and vanish before the cry goes up."},
]
const RIVAL_TERRITORY := 520.0 # gathering or building this close to a clan's village angers them

## Kinds of landmark (points of interest hidden in the fog, found when first seen).
## A scenario places its own; a random map makes them from these templates: names and
## finder's-memory texts are picked from the lists. reward: stock deltas; reveal: extra
## radius revealed on discovery; den: prowling tigers; devotion: added on discovery.
const LANDMARK_KINDS := {
	"grove": {"insight": {"farming": 0.5}, "reward": {"food": 40},
		"names": ["Wild Berry Grove", "Honey Grove", "Sweet Plum Grove"],
		"texts": ["found a wild grove heavy with fruit", "found a grove where the bushes bend under their berries"]},
	"flint": {"insight": {"tools": 0.6, "bronze": 0.2}, "reward": {"wood": 40, "lore": 10},
		"names": ["Flint Outcrop", "Knapper's Ledge", "Sharpstone Ridge"],
		"texts": ["found a flint outcrop; the tribe's axes bite deeper now", "found a ledge of fine flint that splits clean and sharp"]},
	"cave": {"insight": {"totems": 0.4}, "reward": {"lore": 35},
		"names": ["Painted Cave", "Cave of Hands", "Cave of Echoes", "Owl Cave", "Cave of the First Fire"],
		"texts": ["found a painted cave, where the ancestors drew the great hunt", "found a cave whose walls hold the hand-prints of the long dead"]},
	"stones": {"insight": {"totems": 0.3, "code": 0.2}, "reward": {"lore": 28}, "devotion": 7.0,
		"names": ["Standing Stones", "Ring of the Ancients", "Moon Stones", "Stones of the Sleepers"],
		"texts": ["found standing stones that hum when the moon is full", "found a ring of stones older than any tale the elders know"]},
	"bones": {"insight": {"hide": 0.45}, "reward": {"lore": 12, "wood": 22},
		"names": ["Mammoth Graveyard", "Bison Bone Pit", "Valley of Tusks"],
		"texts": ["found a graveyard of mammoths and hauled home great tusks and ribs", "found a pit where a whole herd was once driven over the edge"]},
	"peak": {"insight": {"domestication": 0.35}, "reward": {"lore": 20}, "reveal": 650.0,
		"names": ["Eagle Peak", "Wind Peak", "Cloud Peak", "Grey Horn"],
		"texts": ["climbed a high peak and saw the far lands spread below", "climbed a peak and saw the forests roll away to the sky"]},
	"spring": {"insight": {"pottery": 0.4}, "reward": {"food": 20, "lore": 15},
		"names": ["Hot Spring", "Mist Spring", "Steaming Pools"],
		"texts": ["found a steaming hot spring among the rocks", "found a spring of warm water steaming in the cold air"]},
	"den": {"insight": {"hide": 0.2}, "reward": {"lore": 10}, "den": 1,
		"names": ["Saber-tooth Den"],
		"texts": ["found a Saber-tooth Den littered with bones and lived to tell of it", "found a Saber-tooth Den among the rocks"]},
	"volcano": {"insight": {"fire": 0.3, "bronze": 0.15}, "reward": {"lore": 20},
		"names": ["Fire Mountain"],
		"texts": ["climbed toward the smoking Fire Mountain, where the rocks are warm and the ground growls"]},
}

const SKILLS := ["forage", "craft", "combat", "lore", "trade"]
const SKILL_NAMES := {
	"forage": "Foraging & Hunting",
	"craft": "Crafting & Building",
	"combat": "Combat & Leadership",
	"lore": "Shamanism & Lore",
	"trade": "Trade & Barter",
}
const SKILL_UNLOCKS := {
	"forage": "Beast Taming",
	"craft": "Megalithic & Bronze Craft",
	"combat": "Centurion Aura",
	"lore": "Totem Miracles",
	"trade": "Silver Tongue",
}

# Natural finds: foods, medicines and ores scattered over the map. Each kind is unknown (and
# can't be gathered) until a villager who can recognise it comes near one.
#   res      what a load becomes in the stores ("herbs", "copper", "tin" are their own stocks)
#   rate     work speed vs. berries (1.0); needs: "" | "lore" (Lore 1+ to recognise) | "tools"
#   regrow   per second (0 = a seam that runs out); winter: still yields in winter
#   where    world-gen placement; count = clusters
#   act      activity text; practice = evolution activity it counts as
const FINDS := {
	"mushroom": {"name": "Forest Mushrooms", "group": "food", "res": "food", "amount": 18, "rate": 1.0, "regrow": 0.06, "winter": false,
		"where": "forest", "count": 6, "act": "Gathering mushrooms", "practice": "berry",
		"desc": "Food from the forest floor - but a bad one poisons the gatherer until the tribe learns which are safe (or a Lore 2+ gatherer picks)."},
	"tubers": {"name": "Wild Tubers", "group": "food", "res": "food", "amount": 30, "rate": 0.7, "regrow": 0.05, "winter": true,
		"where": "meadow", "count": 5, "act": "Digging tubers", "practice": "berry",
		"desc": "Slow to dig, but they keep in the ground: food even in winter."},
	"grain": {"name": "Wild Grain", "group": "food", "res": "food", "amount": 26, "rate": 0.9, "regrow": 0.08, "winter": false,
		"where": "meadow", "count": 4, "act": "Cutting wild grain", "practice": "berry", "practice_x": 2.0,
		"desc": "Seed-heads of wild grass. Gathering them teaches farming twice as fast."},
	"honey": {"name": "Wild Honey", "group": "food", "res": "food", "amount": 24, "rate": 0.8, "regrow": 0.05, "winter": false, "cluster": 1,
		"where": "forest_edge", "count": 4, "act": "Taking honey", "practice": "hunt",
		"desc": "Sweet food that lifts the spirit (+devotion). The bees sting - unless Friction Fire is known to smoke them out."},
	"fish": {"name": "Fish Shoal", "group": "food", "res": "food", "amount": 24, "rate": 1.2, "regrow": 0.14, "winter": false,
		"where": "river", "count": 6, "act": "Fishing", "practice": "hunt",
		"desc": "Fish in the river shallows: plenty and quick to return - but none while the river is iced over in winter."},
	"willow": {"name": "Willow Bark", "group": "medicine", "res": "herbs", "amount": 14, "rate": 0.8, "regrow": 0.04, "winter": true, "needs": "lore",
		"where": "riverbank", "count": 4, "act": "Stripping willow bark", "practice": "ritual",
		"desc": "Willow-bark tea breaks a fever: the sick recover 2.5x faster while the tribe has herbs."},
	"yarrow": {"name": "Yarrow", "group": "medicine", "res": "herbs", "amount": 14, "rate": 0.9, "regrow": 0.05, "winter": false, "needs": "lore",
		"where": "meadow", "count": 4, "act": "Picking yarrow", "practice": "ritual",
		"desc": "Yarrow staunches wounds: the hurt heal twice as fast at the village while the tribe has herbs."},
	"flint": {"name": "Flint", "group": "ore", "res": "stone", "amount": 30, "rate": 0.8, "regrow": 0.0, "winter": true,
		"where": "riverbank", "count": 3, "act": "Knapping flint", "practice": "chop",
		"desc": "Sharp stone that can be worked by hand (no tools needed). Finding it brings Polished Stone Tools much closer."},
	"copper": {"name": "Copper Ore", "group": "ore", "res": "copper", "amount": 40, "rate": 0.5, "regrow": 0.0, "winter": true, "needs": "tools",
		"where": "hills_home", "count": 3, "act": "Mining copper", "practice": "quarry",
		"desc": "Green-streaked rock. With tin, it makes bronze."},
	"tin": {"name": "Tin Ore", "group": "ore", "res": "tin", "amount": 30, "rate": 0.45, "regrow": 0.0, "winter": true, "needs": "tools",
		"where": "hills_far", "count": 2, "act": "Mining tin", "practice": "quarry",
		"desc": "Heavy dark stones, rare and far. Bronze cannot be made without it."},
	"ochre": {"name": "Red Ochre", "group": "ore", "res": "lore", "amount": 20, "rate": 0.7, "regrow": 0.0, "winter": true,
		"where": "meadow", "count": 2, "act": "Digging red ochre", "practice": "ritual",
		"desc": "Red earth for painting bodies, walls and the dead: each load is lore, and the tribe grows more spiritual."},
	"obsidian": {"name": "Obsidian", "group": "ore", "res": "stone", "amount": 20, "rate": 0.7, "regrow": 0.0, "winter": true,
		"where": "volcano", "count": 0, "act": "Gathering obsidian", "practice": "quarry",
		"desc": "Black glass left on the slopes of the Fire Mountain: blades of it cut deep (+15% ATK until bronze)."},
	"salt": {"name": "Salt Lick", "group": "ore", "res": "food", "amount": 25, "rate": 0.7, "regrow": 0.01, "winter": true,
		"where": "meadow", "count": 2, "act": "Scraping salt", "practice": "hearth",
		"desc": "Salt to cure meat: once found, the stores spoil half as fast."},
}
## Activity text of each find, for translation (kept as literal tr() keys).
const FIND_GROUPS := {"food": "Foods", "medicine": "Medicines", "ore": "Ores & earths"}

# wood = material cost, work = build points, cap = population capacity
const STRUCTURES := {
	"hut":          {"name": "Hut", "desc": "Houses 3 people. At night 3 sleep inside, warm and safe from wolves.", "wood": 15, "work": 30.0, "cap": 3, "r": 20.0},
	"large_hut":    {"name": "Large Hut", "desc": "Houses 5 people, and 5 can sleep inside at night.", "wood": 22, "work": 42.0, "cap": 5, "r": 26.0},
	"palisade":     {"name": "Wooden Palisade", "desc": "A ring of stakes: people inside it get +3 DEF. Floods can't wash it away.", "wood": 20, "work": 36.0, "r": 100.0, "ring": true},
	"fishing_dock": {"name": "Fishing Dock", "desc": "Steady food from the river (less in winter).", "wood": 14, "work": 26.0, "r": 16.0, "food": 0.12},
	"bonfire":      {"name": "Bonfire", "desc": "Warmth: nobody near it freezes, the sick heal faster, and those who don't fit in huts sleep around it. Lights up the land around it.", "wood": 8, "work": 12.0, "r": 12.0},
	"weapon_rack":  {"name": "Weapon Rack", "desc": "People near it fight with +20% ATK.", "wood": 10, "work": 16.0, "r": 12.0},
	"totem_shrine": {"name": "Totem Shrine", "desc": "A trickle of lore. Rituals near it give 50% more lore, and the sick nearby heal faster.", "wood": 18, "work": 30.0, "r": 14.0, "lore": 0.06},
	"farm_plot":    {"name": "Farm Plot", "desc": "Steady food from the field (none in winter, less in drought).", "wood": 12, "work": 24.0, "r": 28.0, "food": 0.1, "tech": "farming"},
	"granary":      {"name": "Granary", "desc": "Stores 100 more food (food over the stores' limit rots fast). Houses 4 people, and gatherers drop food here, so build it near the fields.", "wood": 30, "work": 40.0, "r": 20.0, "cap": 4, "tech": "pottery"},
	"grand_altar":  {"name": "Grand Altar", "desc": "Summons Yinglong the winged dragon to guard the village. Rituals and healing as a shrine. Needed for Victory by Wisdom.", "wood": 60, "stone": 20, "work": 80.0, "r": 24.0, "tech": "totems"},
	"aurochs_pen":  {"name": "Aurochs Pen", "desc": "Home to up to 2 pack oxen. Each ox eats food and needs tending, and lets one gatherer carry 50% more.", "wood": 25, "work": 30.0, "r": 30.0, "tech": "domestication"}, # keeps the herd (sim.oxen)
	"smelter":      {"name": "Bronze Smelter", "desc": "Arms the tribe in bronze (+60% ATK, +3 DEF) while it has copper and tin; it uses one of each per day.", "wood": 20, "stone": 20, "work": 45.0, "r": 16.0, "tech": "bronze"},
	"council_ring": {"name": "Council Ring", "desc": "A trickle of lore. Where the chiefs of the clans can meet: needed for Victory by Unity.", "wood": 15, "stone": 15, "work": 35.0, "r": 30.0, "lore": 0.05, "tech": "code"},
	# laid out by the tribe itself when the first of them dies (not in the build menu)
	"burial_ground": {"name": "Burial Ground", "desc": "Where the tribe lays its dead to rest.", "wood": 0, "work": 1.0, "r": 40.0},
}
## Homes and walls get a new look per era (style = era they were built or renovated in).
const STYLED := ["hut", "large_hut", "palisade", "granary"]
const CONTRACT_STRUCTURES := ["hut", "large_hut", "palisade", "fishing_dock", "bonfire", "weapon_rack", "totem_shrine", "farm_plot"]
const VILLAGE_BUILDS := ["hut", "palisade", "bonfire", "totem_shrine", "farm_plot", "granary", "aurochs_pen", "smelter", "council_ring", "grand_altar"]
const STRUCT_ALIASES := {
	"wooden_palisade": "palisade", "wall": "palisade", "walls": "palisade", "fence": "palisade",
	"dock": "fishing_dock", "fishing_pier": "fishing_dock", "pier": "fishing_dock",
	"big_hut": "large_hut", "longhouse": "large_hut", "grand_hut": "large_hut",
	"fire": "bonfire", "grand_bonfire": "bonfire", "campfire": "bonfire",
	"rack": "weapon_rack", "weapons_rack": "weapon_rack",
	"shrine": "totem_shrine", "totem": "totem_shrine",
	"farm": "farm_plot", "field": "farm_plot", "crop_plot": "farm_plot",
}

## Knowledge evolves two ways: by PRACTICE (people doing related work build up insight;
## "practice" maps activity -> weight) and by spending lore to finish the idea. "words"
## are things personas must not mention before the tech exists.
const INSIGHT_RATE := 0.06
const PRACTICE_NAMES := {"chop": "felling trees", "hunt": "hunting & butchering", "berry": "foraging berries", "build": "building",
	"ritual": "rituals", "quarry": "quarrying stone", "explore": "scouting", "hearth": "nights by the fire", "lead": "leading others"}
const TECHS := [
	{"id": "fire", "era": 1, "name": "Friction Fire", "cost": 15, "req": [], "practice": {"hearth": 1.0, "ritual": 0.5},
		"desc": "Torches light the night and homes get hearths. Bonfire warmth x2; cooked food 25% more nourishing.", "words": ["fire-drills", "torches"]},
	{"id": "tools", "era": 1, "name": "Polished Stone Tools", "cost": 20, "req": [], "practice": {"chop": 1.0, "hunt": 0.6},
		"desc": "+30% hunting & woodcutting, +2 ATK. Lets the tribe quarry stone from boulders.", "words": ["polished axes", "quarrying"]},
	{"id": "hide", "era": 1, "name": "Hide Tailoring", "cost": 20, "req": [], "practice": {"hunt": 1.0},
		"desc": "Fur cloaks: immune to night cold, +2 DEF.", "words": ["sewn furs", "needles"]},
	{"id": "pottery", "era": 2, "name": "Primitive Pottery", "cost": 35, "req": ["fire"], "practice": {"hearth": 0.6, "berry": 0.6},
		"desc": "Unlocks the Granary (+100 food storage, +4 pop cap). Food spoilage -50%.", "words": ["pots", "pottery", "clay jars", "granaries"]},
	{"id": "domestication", "era": 2, "name": "Beast Domestication", "cost": 40, "req": ["tools"], "practice": {"hunt": 0.8, "explore": 0.6},
		"desc": "Unlocks the Aurochs Pen, home to up to 2 pack oxen. Each ox lets one gatherer carry 50% more, but oxen eat food and must be tended.", "words": ["tamed beasts", "oxen", "pens", "riding"]},
	{"id": "farming", "era": 2, "name": "Slash-and-Burn Farming", "cost": 35, "req": ["fire"], "practice": {"berry": 1.0},
		"desc": "Unlocks Farm Plots for steady food.", "words": ["farms", "fields", "planting", "crops"]},
	{"id": "bronze", "era": 3, "name": "Bronze Metallurgy", "cost": 70, "req": ["tools", "domestication"], "finds": ["copper", "tin"], "practice": {"quarry": 1.0, "build": 0.3},
		"desc": "Unlocks the Bronze Smelter; while one stands with copper and tin to work, the tribe is armed in bronze (+60% ATK, +3 DEF).", "words": ["bronze", "metal", "smelting"]},
	{"id": "totems", "era": 3, "name": "Megalithic Totems", "cost": 70, "req": ["pottery"], "practice": {"ritual": 1.0},
		"desc": "Unlocks the Grand Altar (mythic guardian). Carved totems preserve all the tribe's knowledge.", "words": ["great totems", "altars", "megaliths"]},
	{"id": "code", "era": 3, "name": "Tribal Code", "cost": 60, "req": ["farming"], "practice": {"lead": 1.0, "build": 0.3},
		"desc": "+1 Vice-Chieftain slot and the Council Ring. Laws preserve all the tribe's knowledge.", "words": ["laws", "councils"]},
]
const ERA_NAMES := {1: "Stone & Fire Era", 2: "Tribe & Agrarian Era", 3: "Bronze & Mythic Era"}

# ---- Culture: four values that drift with what the tribe actually does ----
const CULTURE_AXES := {
	"martial": ["Martial", "Peaceful"], "spiritual": ["Spiritual", "Practical"],
	"settled": ["Settled", "Roaming"], "ranked": ["Ranked", "Communal"],
}
const TRADITION_THRESHOLD := 35.0
const TRADITIONS := [
	{"id": "warrior_initiation", "axis": "martial", "sign": 1, "name": "Warrior Initiation", "arch": "warrior",
		"desc": "Youths prove themselves on the hunt: +2 ATK for everyone, combat XP +25%."},
	{"id": "peaceful_ways", "axis": "martial", "sign": -1, "name": "Peaceful Ways", "arch": "agrarian",
		"desc": "The tribe sheds no needless blood: +20% gathering speed."},
	{"id": "ancestor_rites", "axis": "spiritual", "sign": 1, "name": "Ancestor Rites", "arch": "mystic",
		"desc": "Nightly rites for the ancestors: rituals give +30% lore and devotion."},
	{"id": "makers_pride", "axis": "spiritual", "sign": -1, "name": "Makers' Pride", "arch": "cautious",
		"desc": "Skill is honored above omens: +20% building speed."},
	{"id": "harvest_festival", "axis": "settled", "sign": 1, "name": "Harvest Festival", "arch": "agrarian",
		"desc": "The tribe feasts on what the land gives: farms, docks and pens yield +30%."},
	{"id": "wayfinders", "axis": "settled", "sign": -1, "name": "Wayfinders", "arch": "warrior",
		"desc": "Born to roam: +40 sight and +10% travel speed."},
	{"id": "council_of_elders", "axis": "ranked", "sign": 1, "name": "Council of Elders", "arch": "cautious",
		"desc": "Rank is respected: +1 Vice-Chieftain slot."},
	{"id": "shared_hearth", "axis": "ranked", "sign": -1, "name": "Shared Hearth", "arch": "lazy",
		"desc": "All eat from one pot: hunger drains 20% slower."},
]
## Which personality newborns lean toward as the culture develops.
const CULTURE_TRAIT := {"martial": "belligerent", "spiritual": "devout", "settled": "gluttonous", "ranked": "cautious"}

const TRAITS := {
	"cautious":    {"name": "Cautious & Pragmatic", "arch": "cautious", "desc": "Safety first. Builds walls before huts."},
	"belligerent": {"name": "Belligerent & Impulsive", "arch": "warrior", "desc": "Bold and loud. Never flees a fight."},
	"gluttonous":  {"name": "Gluttonous & Agrarian", "arch": "agrarian", "desc": "Food before all. Eats more."},
	"devout":      {"name": "Devout & Mystical", "arch": "mystic", "desc": "Reads omens. Performs rituals when idle."},
	"lazy":        {"name": "Slightly Lazy", "arch": "lazy", "desc": "Minimal effort, minimal plans. -10% work speed."},
}

const FOCUSES := ["balanced", "defense", "fishery", "fishery_and_defense", "farming", "hunting", "spiritual"]
const ACTIONS := ["gather_wood", "gather_food", "build", "ritual"]


# ---- A random tribe (random maps): names, epithets and memories by temperament ----
const TRIBE_NAMES := ["Panshi", "Alie", "Linghe", "Tuo", "Mo'er", "Shan", "Yan", "Qiao", "Bai", "Hu", "Lei", "Yun", "Kang", "Mei", "Xi", "Gu", "Duo", "Qing", "Ning", "Hong"]
const TRIBE_COLORS := ["#c9a36b", "#d0603f", "#8c7bd6", "#9bbf5a", "#b7a58f", "#c27a4e", "#7fa3b8", "#c68fb3", "#a8a8a0", "#b8945a", "#6fa58a", "#c9806b"]
## trait -> the skill it leans on, epithets and memories (memory text starts with a past-tense verb).
const TEMPERAMENTS := {
	"cautious": {"skill": "craft", "epithets": ["Master Builder", "Quiet Tracker", "Hut-Raiser", "Keeper of the Walls"],
		"memories": ["held the roofs down when the great storm came two winters ago", "raised a longhouse without losing a single beam", "spotted the saber-tooth tracks before anyone else", "kept the fire alive through the longest night of winter"]},
	"belligerent": {"skill": "combat", "epithets": ["Spear of the Tribe", "Young Hunter", "Bear-Slayer", "Swift Spear"],
		"memories": ["was critically wounded by a saber-toothed tiger", "slew a cave bear with a fire-hardened spear", "brought down a stag on my first hunt", "drove off a wolf pack with a burning branch"]},
	"devout": {"skill": "lore", "epithets": ["Voice of the Totem", "Weaver", "Dream-Walker", "Keeper of Tales"],
		"memories": ["dreamed of a white heron circling the camp for three nights", "calmed a fever spirit that had seized two children", "wove the totem banner that hangs above the bonfire", "heard the ancestors speak in the crackle of the fire"]},
	"gluttonous": {"skill": "forage", "epithets": ["Berry Keeper", "Stonehand", "Root-Finder", "Keen Nose"],
		"memories": ["found the great berry thicket that fed the tribe through the lean moon", "knapped forty spearheads in a single moon", "dug up a feast of roots when the snows came early", "smoked a whole deer for the winter stores"]},
	"lazy": {"skill": "craft", "epithets": ["Dozer by the Fire", "Slow Paddle"],
		"memories": ["slept through the night the wolves circled camp", "napped in the sun while the others hauled timber"]},
}


const BIRTH_NAMES := ["Ah-Lu", "Kesh", "Nuo", "Tala", "Rong", "Wei", "Hua", "Dao", "Lin", "Feng", "Ming", "Yu", "Zhen", "Ke", "Su", "Lan", "Bo", "Jin"]
const BIRTH_COLORS := ["#c9b07a", "#a6c47e", "#b98da8", "#8fb3c4", "#d69a6b", "#a3a3d1", "#c4a4a4"]

