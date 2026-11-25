## Sim cost by population (city_proposal step 4): seeds The Ford, adds people (newcomers),
## lets them work a while with everything on, then times the tick.
## $GODOT --headless --path . --script res://tools/perf.gd -- [--pops=50,200,500,1000] [--secs=20]
extends SceneTree
const Sim = preload("res://scripts/sim.gd")
const D = preload("res://scripts/data.gd")
const Scenarios = preload("res://scripts/scenarios.gd")
func _initialize() -> void:
	var a := {}
	for s in OS.get_cmdline_user_args():
		var kv := s.trim_prefix("--").split("=", true, 1)
		a[kv[0]] = kv[1] if kv.size() > 1 else "1"
	for ps in str(a.get("pops", "50,200,500")).split(","):
		print("pop %5d: %6.2f ms/tick" % [int(ps), measure(int(ps), float(a.get("secs", "20")))])
	quit()

## Mean ms of a 0.05 s tick with `pop` people at work (a warm-up first).
func measure(pop: int, secs: float) -> float:
	Scenarios.apply("the_ford")
	seed(7)
	var sim = Sim.new()
	sim.hz.level = "normal"
	sim.new_game()
	var st = sim.living()[0]
	sim.appoint(st, "steward")
	sim.stock["food"] = 5000.0
	sim.stock["wood"] = 5000.0
	sim.research("farming")
	sim.research("pottery")
	var i := 0
	while sim.pop_cap() < pop + 20 and i < 400: # (beds for them)
		var p: Vector2 = sim.dry_spot(D.VILLAGE + Vector2.from_angle(i * 0.7) * (160.0 + i * 3.0))
		var h = sim.add_structure("longhouse", p)
		sim.complete_structure(h, null)
		i += 1
	while sim.living().size() < pop: sim.folk.add_family(6)
	sim.time = D.DAY_LEN * 0.3
	for k in 200: sim.tick(0.05) # (warm up: the Steward hands out work)
	var t0 := Time.get_ticks_usec()
	var n := int(secs / 0.05)
	for k in n:
		sim.paused = false
		if sim.pending_event != "": sim.resolve_event(sim.pending_event, 0)
		sim.tick(0.05)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0 / n
	sim.dispose()
	return ms
