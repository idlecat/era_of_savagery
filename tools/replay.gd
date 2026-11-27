## Does a change to the sim alter the games it plays? Plays scripted games from fixed seeds with
## every system on, and prints a fingerprint of the whole state now and then (save_game.gd's
## encoding of the sim, hashed): the same lines before and after a change mean the same games,
## bit for bit. Run it on both builds and diff the output.
## $GODOT --headless --path . --script res://tools/replay.gd -- [--days=3] [--games=ford,town,winter,random,culture] [--dump=/path/dir] [--out=/path.txt]
##   (--dump also writes the full state at the end of each game, to diff field by field)
extends SceneTree
const Sim = preload("res://scripts/sim.gd")
const D = preload("res://scripts/data.gd")
const Scenarios = preload("res://scripts/scenarios.gd")
const MapGen = preload("res://scripts/mapgen.gd")
const Cultures = preload("res://scripts/cultures.gd")
const SaveGame = preload("res://scripts/save_game.gd")
const STEP := 0.05
const PRINT_EVERY := 1800 # ticks: a day

func _initialize() -> void:
	var a := {}
	for s in OS.get_cmdline_user_args():
		var kv := s.trim_prefix("--").split("=", true, 1)
		a[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var days := float(a.get("days", 3.0))
	var out := ""
	for g in str(a.get("games", "ford,town,winter,random,culture")).split(",", false):
		out += play(g, days, str(a.get("dump", "")))
	if a.has("out"):
		var f := FileAccess.open(str(a["out"]), FileAccess.WRITE)
		f.store_string(out)
		f.close()
	quit()

## A game as the game starts it: map, culture, every system on.
func _game(map: String, culture: String, tribes := 4, map_seed := 269472) -> Sim:
	Cultures.apply(culture)
	if MapGen.SIZES.has(map):
		MapGen.generate(map, tribes, map_seed)
		seed(map_seed)
	else:
		Scenarios.apply(map)
	var sim = Sim.new()
	sim.new_game()
	return sim

func play(name: String, days: float, dump: String) -> String:
	seed(42)
	var sim: Sim
	match name:
		"ford": sim = _game("the_ford", Cultures.DEFAULT, 0)
		"town": # the village grown to 300 people (tools/perf.gd's game)
			sim = _game("the_ford", Cultures.DEFAULT, 0)
			sim.appoint(sim.living()[0], "steward")
			sim.stock["food"] = 5000.0
			sim.stock["wood"] = 5000.0
			sim.research("farming")
			sim.research("pottery")
			var i := 0
			while sim.pop_cap() < 320 and i < 400:
				sim.complete_structure(sim.add_structure("longhouse", sim.dry_spot(D.VILLAGE + Vector2.from_angle(i * 0.7) * (160.0 + i * 3.0))), null)
				i += 1
			while sim.living().size() < 300: sim.folk.add_family(6)
			sim.time = D.DAY_LEN * 0.3
		"winter": # a random map, mid-winter: the cold, the fuel, the hunger
			sim = _game("standard", Cultures.DEFAULT, 4)
			sim.time = D.DAY_LEN * sim.hz.SEASON_DAYS * 3 + 5.0
			while sim.living().size() < 80: sim.folk.add_family(6)
			sim.appoint(sim.living()[0], "steward")
		"random": sim = _game("large", "none", 6, 777)
		"culture": sim = _game("standard", "sumer", 4, 1234)
		_:
			return "unknown game %s\n" % name
	var out := ""
	var total := int(days * D.DAY_LEN / STEP)
	var bad: Array = []
	for k in range(1, total + 1):
		sim.tick(STEP)
		if sim.paused:
			if sim.pending_event != "": sim.resolve_event(sim.pending_event, 0)
			for c in sim.contracts.list:
				if c.status == "interrupted": sim.contracts.resolve(c, sim.contracts.allowed_effects(c)[0])
			sim.paused = false
		if k % 100 == 0:
			if sim.crisis.active(): sim.crisis.end()
			for b in sim.check_invariants(): bad.append("day %d: %s" % [sim.day(), b])
		if k % PRINT_EVERY == 0 or k == total:
			var enc: Dictionary = SaveGame.encode(sim)
			var inv: Dictionary = enc.get("inv", {}) # (builds before the effect memo was named _cache_fx saved it: only derived values)
			inv.erase("_fx")
			inv.erase("_fx_sig")
			var ctx := HashingContext.new()
			ctx.start(HashingContext.HASH_SHA256)
			ctx.update(var_to_bytes(enc))
			var line := "%-8s day %6.3f  pop %4d  units %4d  nodes %5d  %s" % [name, k * STEP / D.DAY_LEN, sim.living().size(), sim.units.size(), sim.nodes.size(), ctx.finish().hex_encode().substr(0, 24)]
			print(line)
			out += line + "\n"
			if dump != "" and k == total:
				DirAccess.make_dir_recursive_absolute(dump)
				var f := FileAccess.open("%s/%s.txt" % [dump, name], FileAccess.WRITE)
				f.store_string(var_to_str(enc))
				f.close()
	if not bad.is_empty(): out += "%s: BROKEN INVARIANTS %s\n" % [name, str(bad.slice(0, 5))]
	sim.dispose()
	Cultures.reset()
	return out
