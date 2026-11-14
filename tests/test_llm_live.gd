## Live cloud-LLM smoke test (needs a key; skipped otherwise).
## Run: ZAI_API_KEY=... godot --headless --path . --script res://tests/test_llm_live.gd -- --provider=zai_coding
extends SceneTree

const Sim = preload("res://scripts/sim.gd")
const LLM = preload("res://scripts/llm_client.gd")
const I18N = preload("res://scripts/i18n.gd")

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond: print("  PASS ", msg)
	else:
		failures += 1
		print("  FAIL ", msg)

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var provider := "zai_coding"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--provider="): provider = a.trim_prefix("--provider=")
		if a.begins_with("--lang="): I18N.setup(a.trim_prefix("--lang="))
	var sim = Sim.new()
	sim.new_game()
	var llm = LLM.new()
	llm.sim = sim
	root.add_child(llm)
	llm.provider = provider
	llm.base_url = LLM.PRESETS[provider]["base_url"]
	llm.model = LLM.PRESETS[provider]["model"]
	llm.api_key = llm.env_key()
	if llm.api_key == "":
		print("SKIPPED: no key in env %s" % LLM.PRESETS[provider]["env"])
		quit(0)
		return
	print("Provider: ", llm.label())
	var t0 := Time.get_ticks_msec()
	print("  ", await llm.test_connection(), "  (%d ms)" % (Time.get_ticks_msec() - t0))

	for nm in ["Panshi", "Alie"]:
		var u = sim.unit_by_name(nm)
		var ctx: Dictionary = sim.contracts.negotiation_ctx(u, "Establish a settlement across the river", {}, false)
		t0 = Time.get_ticks_msec()
		var r: Dictionary = await llm.negotiate(ctx)
		var ms := Time.get_ticks_msec() - t0
		print("\n[%s] (%s, %d ms) %s" % [nm, r["source"], ms, r["speech"]])
		if r.get("error", "") != "": print("   error: ", r["error"])
		var san: Dictionary = sim.contracts.sanitize(r["blueprint"], ctx["terms"], u)
		print("   steps: ", san["blueprint"]["steps"].map(func(s): return sim.contracts.step_text(s)))
		print("   notes: ", san["notes"])
		check(r["source"] != "offline fallback", "%s negotiated via cloud LLM" % nm)
		check(san["ok"], "%s blueprint valid after sanitize" % nm)
		if nm == "Panshi":
			var c = sim.contracts.create(san["blueprint"], u, "Establish a settlement across the river")
			c.status = "interrupted"
			c.abort_reason = "enemy_attack"
			c.progress = 0.47
			t0 = Time.get_ticks_msec()
			var e: Dictionary = await llm.emergency(sim.contracts.emergency_ctx(c))
			print("\n[Panshi EMERGENCY] (%s, %d ms) %s" % [e["source"], Time.get_ticks_msec() - t0, e["speech"]])
			print("   options: ", e["options"])
			check(e["source"] != "offline fallback", "emergency answered via cloud LLM")
			check(e["options"].size() >= 2, "at least 2 valid emergency options")
	# research contract negotiation, era 2 with tools known
	sim.stock["lore"] = 200
	sim.research("tools")
	sim.research("fire")
	var lu = sim.unit_by_name("Linghe")
	var rctx: Dictionary = sim.contracts.negotiation_ctx(lu, "Find new wisdom for the tribe", {"kind": "research"}, false, "", {}, [], "research")
	t0 = Time.get_ticks_msec()
	var rr: Dictionary = await llm.negotiate(rctx)
	print("\n[Linghe research] (%s, %d ms) %s" % [rr["source"], Time.get_ticks_msec() - t0, rr["speech"]])
	var rs: Dictionary = sim.contracts.sanitize(rr["blueprint"], {"kind": "research"}, lu)
	print("   tech: ", rs["blueprint"].get("tech"), " steps: ", rs["blueprint"].get("steps", []).map(func(s): return sim.contracts.step_text(s)), " notes: ", rs["notes"])
	check(rr["source"] != "offline fallback", "research negotiated via cloud LLM")
	check(rs["ok"], "research blueprint valid")
	check(not ("bronze" in rr["speech"].to_lower()), "persona does not name unknown bronze")
	print("\nLLM calls counted: ", sim.llm_calls)
	print("\n%s (%d failures)" % ["ALL PASSED" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)
