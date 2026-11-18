## The kind of land a map is (config/lands.json): how wooded, and what goes with it
## (grass, berry bushes, herds, weather, wildfire). A map's land is resolved once into a
## plain Dictionary (D.LAND) when the map is made: random maps pick it from the seed and
## vary its numbers a little; scenarios name theirs. The same seed always makes the same land.
extends RefCounted

static func cfg() -> Dictionary: return preload("res://scripts/config.gd").load_cfg("lands")

static func ids() -> Array: return cfg().get("lands", {}).keys()

## The land `id` ("random": picked by weight), with its numbers varied by +-jitter
## (vary=false: exactly as configured, for scenarios). Includes its id.
static func resolve(id: String, seed_v: int, vary := true) -> Dictionary:
	var C := cfg()
	var lands: Dictionary = C.get("lands", {})
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v * 7919 + 13
	if id == "random" or not lands.has(id):
		if id == "random":
			var w: Dictionary = C.get("random", {})
			var total := 0.0
			for k in w: total += float(w[k])
			var r := rng.randf() * total
			id = str(C.get("default", "parkland"))
			for k in w:
				r -= float(w[k])
				if r <= 0.0 and lands.has(k):
					id = k
					break
		else: id = str(C.get("default", "parkland"))
	var L: Dictionary = lands.get(id, {}).duplicate(true)
	L["id"] = id
	if vary:
		var j := float(C.get("jitter", 0.15))
		var wd: Dictionary = L.get("woods", {})
		wd["count"] = float(wd.get("count", 1.0)) * rng.randf_range(1.0 - j, 1.0 + j)
		for k in ["bushes", "herds"]: L[k] = float(L.get(k, 1.0)) * rng.randf_range(1.0 - j, 1.0 + j)
		L["moisture"] = clampf(float(L.get("moisture", 0.5)) + rng.randf_range(-j, j) * 0.6, 0.0, 1.0)
	return L

## A number of the map's land (D.LAND) with a default.
static func num(L: Dictionary, key: String, def := 1.0) -> float:
	return float(L.get(key, def))

## A weather kind's chance multiplier on this land.
static func weather(L: Dictionary, kind: String) -> float:
	return float(L.get("weather", {}).get(kind, 1.0))
