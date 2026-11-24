## Metric runs (docs/make_it_fun.md G1): plays seeded games headless under scripted policies
## and reports whether the game's numbers land in their target bands, and whether they
## differ between policies (if hoarders and feasters fare the same, food decisions are theater).
##
## $GODOT --headless --path . --script res://tools/metrics.gd -- [--runs=4] [--days=12] [--seed=1]
##     [--policies=steward,hoarder,feaster] [--level=normal] [--map=the_ford|standard...] [--dt=0.1] [--out=/path.csv]
##
## A policy is a game-master script, tests/policies/<id>.json, using only the operations a
## game master has (so the harness is also a smoke test of that surface):
##   steward     appoint a Steward (the best at lore) first
##   dilemmas    "first" | "last": which enabled option of a posed dilemma it takes
##               (routine matters the Steward decides itself)
##   emergency   "first" | "last": which allowed effect it gives an interrupted contract
##   contracts   {every_days, kinds: [settle|research|seek|war], directive}: seals one with
##               contracts.seal() (the offline persona plans it) when none is running
##   rules       [{when: conditions (story.holds), every_days (default 1), once,
##                 do: story actions, order: structure (improve.order), set: {policy: choice}}]
## Forecast calibration (A0) is reported once A0 exists.
extends SceneTree

const Sim = preload("res://scripts/sim.gd")
const D = preload("res://scripts/data.gd")
const MapGen = preload("res://scripts/mapgen.gd")
const Scenarios = preload("res://scripts/scenarios.gd")
const Cultures = preload("res://scripts/cultures.gd")

## The target bands: [low, high] share of runs (or a value), docs/make_it_fun.md G1.
const BANDS := {"near_miss": [0.6, 0.9], "famine": [0.1, 0.25]}

var a := {}

func _initialize() -> void:
	for s in OS.get_cmdline_user_args():
		var kv := s.trim_prefix("--").split("=", true, 1)
		a[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var runs := int(a.get("runs", "4"))
	var seed0 := int(a.get("seed", "1"))
	var pols: Array = str(a.get("policies", "steward,hoarder,feaster")).split(",", false)
	var rows: Array = []
	var t0 := Time.get_ticks_msec()
	for pid in pols:
		var pol := _load_policy(pid)
		if pol.is_empty():
			push_error("no policy tests/policies/%s.json" % pid)
			continue
		for i in runs:
			var r := _play(pol, seed0 + i)
			rows.append(r)
			print("  %s seed %d: %s" % [pid, seed0 + i, _short(r)])
	_report(rows, pols)
	if a.has("out"):
		var keys: Array = rows[0].keys() if not rows.is_empty() else []
		var csv := ",".join(keys) + "\n"
		for r in rows: csv += ",".join(keys.map(func(k): return str(r[k]).replace(",", ";"))) + "\n"
		var f := FileAccess.open(a["out"], FileAccess.WRITE)
		f.store_string(csv)
		f.close()
	print("metrics: %d runs in %.0fs" % [rows.size(), (Time.get_ticks_msec() - t0) / 1000.0])
	quit()

func _load_policy(id: String) -> Dictionary:
	var path := "res://tests/policies/%s.json" % id
	if not FileAccess.file_exists(path): return {}
	var p = JSON.parse_string(FileAccess.get_file_as_string(path))
	return p if p is Dictionary else {}

# ------------------------------------------------------------ one game
func _play(pol: Dictionary, sd: int) -> Dictionary:
	var m: String = a.get("map", "the_ford")
	Cultures.apply(a.get("culture", ""))
	if MapGen.SIZES.has(m): MapGen.generate(m, int(a.get("tribes", "3")), sd, a.get("land", "random"))
	else: Scenarios.apply(m)
	seed(sd)
	var sim = Sim.new()
	sim.hz.level = a.get("level", "normal")
	sim.new_game()
	if pol.get("steward", true):
		var best = null
		for u in sim.living():
			if u.role == "" and (best == null or u.lv("lore") > best.lv("lore")): best = u
		if best: sim.appoint(best, "steward")
	var r := {"policy": pol["id"], "seed": sd, "days": 0, "alive": 0, "deaths": 0, "deaths_d20": 0, "starved": 0, "killed": 0, "other_deaths": 0, "left": 0,
		"near_miss": false, "sick_wave": false, "hungry_sick": false, "famine": false, "hungry_hours": 0.0, "min_food_frac": 1.0,
		"dilemmas": 0, "feats": 0, "interrupts": 0, "crises": 0, "sealed": 0, "seal_refused": 0,
		"pauses_per_hour": 0.0, "max_gap_days": 0.0, "era2_day": -1, "ranks": 0, "first_rank_day": -1, "craft_gate_day": -1}
	var meaningful: Array = [0.0] # game times of meaningful events
	sim.feat_added.connect(func(_f): r["feats"] += 1; meaningful.append(sim.time))
	sim.contract_interrupted.connect(func(_c): r["interrupts"] += 1; meaningful.append(sim.time))
	sim.crisis_started.connect(func(_c): r["crises"] += 1; meaningful.append(sim.time))
	var days := int(a.get("days", "12"))
	var dt := float(a.get("dt", "0.1"))
	var end_t := days * D.DAY_LEN
	var last_pending := ""
	var next_sample := 0.0
	var last_day := -1
	var rule_t := {}
	var last_seal := -1e9
	var dead_seen := {}
	while sim.time < end_t and not sim.living().is_empty():
		# the player's seat, played by the policy
		if sim.pending_event != "":
			if sim.pending_event != last_pending:
				r["dilemmas"] += 1
				meaningful.append(sim.time)
			last_pending = sim.pending_event
			sim.resolve_event(sim.pending_event, _pick(sim, sim.pending_event, str(pol.get("dilemmas", "first"))))
		else: last_pending = ""
		for c in sim.contracts.list:
			if c.status == "interrupted":
				var eff: Array = sim.contracts.allowed_effects(c)
				sim.contracts.resolve(c, eff[0] if pol.get("emergency", "first") == "first" else eff[-1])
		if not sim.improve.asking.is_empty(): sim.improve.choose(sim.improve.asking["options"][0], "")
		if sim.day() != last_day:
			last_day = sim.day()
			_rules(sim, pol, rule_t)
			var cp: Dictionary = pol.get("contracts", {})
			if not cp.is_empty() and sim.time - last_seal >= float(cp.get("every_days", 3)) * D.DAY_LEN and not sim.contracts.list.any(func(c): return sim.contracts.is_running(c)):
				last_seal = sim.time
				var ok := _seal(sim, cp)
				if ok: r["sealed"] += 1
				else: r["seal_refused"] += 1
		sim.paused = false
		sim.tick(dt)
		if sim.time >= next_sample:
			next_sample = sim.time + 1.0
			_sample(sim, r, dead_seen)
	r["days"] = snappedf(sim.time / D.DAY_LEN, 0.1)
	r["alive"] = sim.living().size()
	r["famine"] = r["starved"] > 0 or r["hungry_sick"] or r["left"] > 0 # (a sickness wave counts when it strikes a hungry camp)
	r["hungry_hours"] = snappedf(r["hungry_hours"], 0.1)
	var hours := maxf(1.0, sim.time / (D.DAY_LEN / 24.0))
	r["pauses_per_hour"] = snappedf(float(r["dilemmas"] + r["feats"] + r["interrupts"] + r["crises"]) / hours, 0.01)
	meaningful.append(sim.time)
	meaningful.sort()
	for i in range(1, meaningful.size()): r["max_gap_days"] = maxf(r["max_gap_days"], snappedf((meaningful[i] - meaningful[i - 1]) / D.DAY_LEN, 0.1))
	r["min_food_frac"] = snappedf(r["min_food_frac"], 0.01)
	sim.dispose()
	return r

func _sample(sim, r: Dictionary, dead_seen: Dictionary) -> void:
	var frac: float = sim.stock["food"] / maxf(1.0, float(sim.food_cap()))
	if sim.day() > 1: r["min_food_frac"] = minf(r["min_food_frac"], frac)
	if frac < 0.15 and sim.day() > 1: r["near_miss"] = true
	if frac < 0.02 and sim.day() > 1: r["hungry_hours"] += 1.0 / (D.DAY_LEN / 24.0) # (game hours with empty stores)
	if sim.living().filter(func(u): return u.sick > 0).size() >= 3:
		r["sick_wave"] = true
		if frac < 0.15: r["hungry_sick"] = true
	for u in sim.units:
		if not u.dead or dead_seen.has(u.id): continue
		dead_seen[u.id] = true
		if u.gone:
			r["left"] += 1
			continue
		r["deaths"] += 1
		if sim.day() <= 20: r["deaths_d20"] += 1
		if u.hunger <= 1.0 and u.death_cause == sim.tr("lost to hunger and cold"): r["starved"] += 1
		elif u.death_cause.begins_with(sim.tr("slain by a %s").split("%")[0]): r["killed"] += 1
		else: r["other_deaths"] += 1
	if r["era2_day"] < 0 and sim.evo.era >= 2: r["era2_day"] = sim.day()
	var held := 0
	for u in sim.living():
		for k in D.SKILLS:
			if sim.ranks.rank(u, k) != "": held += 1
	r["ranks"] = held
	if held > 0 and r["first_rank_day"] < 0: r["first_rank_day"] = sim.day()
	if r["craft_gate_day"] < 0 and sim.ranks.tribe_has("fine_craft"): r["craft_gate_day"] = sim.day()

## The option a policy takes: the first or last one that can be chosen.
func _pick(sim, id: String, how: String) -> int:
	var opts: Array = sim.event_def(id).get("options", [])
	var ok: Array = []
	for i in opts.size():
		if opts[i].get("enabled", true): ok.append(i)
	if ok.is_empty(): return 0
	return ok[-1] if how == "last" else ok[0]

func _rules(sim, pol: Dictionary, rule_t: Dictionary) -> void:
	var rules: Array = pol.get("rules", [])
	for i in rules.size():
		var ru: Dictionary = rules[i]
		var last: float = rule_t.get(i, -1e9)
		if ru.get("once", false) and rule_t.has(i): continue
		if sim.time - last < float(ru.get("every_days", 1)) * D.DAY_LEN - 1.0: continue
		if not sim.story.holds(ru.get("when", {})): continue
		rule_t[i] = sim.time
		if ru.has("do"): sim.story.run(ru["do"], null, {})
		if ru.has("order"): sim.improve.order(str(ru["order"]))
		for pid in ru.get("set", {}): sim.policy.set_choice(pid, str(ru["set"][pid]), "policy")

## Seal a contract of the next kind in the list, led by the free person best at it.
func _seal(sim, cp: Dictionary) -> bool:
	var skill := {"settle": "craft", "research": "lore", "seek": "forage", "war": "combat"}
	for kind in cp.get("kinds", ["settle"]):
		if kind == "research" and sim.evo.candidates().is_empty(): continue
		var terms := {}
		if kind == "war":
			var met: Array = sim.rivals.clans.keys().filter(func(id): return sim.rivals.clans[id]["met"])
			if met.is_empty(): continue
			terms = {"kind": "war", "target": met[0], "objective": "loot"}
		var best = null
		for u in sim.contracts.available_helpers():
			if kind == "war" and not sim.ranks.may(u, "lead_war"): continue
			if best == null or u.lv(skill[kind]) > best.lv(skill[kind]): best = u
		if best == null: continue
		var res: Dictionary = sim.contracts.seal(best, kind, str(cp.get("directive", "")), terms)
		if res["ok"]: return true
	return false

# ------------------------------------------------------------ report
func _short(r: Dictionary) -> String:
	return "alive %d, deaths %d (starved %d, killed %d, other %d, left %d), empty stores %.0fh, sick wave %s, min food %d%%, near-miss %s, famine %s, sealed %d, interrupts %d, %.2f pauses/h, max gap %.1fd, era2 d%d, ranks %d (craft gate d%d)" % [
		r["alive"], r["deaths"], r["starved"], r["killed"], r["other_deaths"], r["left"], r["hungry_hours"], r["sick_wave"], roundi(r["min_food_frac"] * 100), r["near_miss"], r["famine"], r["sealed"], r["interrupts"], r["pauses_per_hour"], r["max_gap_days"], r["era2_day"], r["ranks"], r["craft_gate_day"]]

func _report(rows: Array, pols: Array) -> void:
	print("\n== G1 metrics (%s days, %s) ==" % [a.get("days", "12"), a.get("map", "the_ford")])
	print("policy    runs  near-miss  famine  deaths  starved  killed  left  empty-h  min-food  sealed  intr  pause/h  max-gap  era2  ranks  craft-gate")
	var summ := {}
	for pid in pols:
		var rs: Array = rows.filter(func(r): return r["policy"] == pid)
		if rs.is_empty(): continue
		var n := float(rs.size())
		var s := {
			"near_miss": rs.filter(func(r): return r["near_miss"]).size() / n,
			"famine": rs.filter(func(r): return r["famine"]).size() / n,
			"deaths": _mean(rs, "deaths"), "starved": _mean(rs, "starved"), "killed": _mean(rs, "killed"), "left": _mean(rs, "left"), "empty": _mean(rs, "hungry_hours"),
			"min_food": _mean(rs, "min_food_frac"), "sealed": _mean(rs, "sealed"), "interrupts": _mean(rs, "interrupts"),
			"pauses": _mean(rs, "pauses_per_hour"), "gap": _mean(rs, "max_gap_days"),
			"era2": rs.filter(func(r): return r["era2_day"] >= 0).size() / n,
			"ranks": _mean(rs, "ranks"), "craft_gate": rs.filter(func(r): return r["craft_gate_day"] >= 0).size() / n}
		summ[pid] = s
		print("%-9s %4d  %8d%%  %5d%%  %6.1f  %7.1f  %6.1f  %4.1f  %7.0f  %7d%%  %6.1f  %4.1f  %7.2f  %6.1fd  %3d%%  %5.1f  %9d%%" % [pid, rs.size(), roundi(s["near_miss"] * 100), roundi(s["famine"] * 100), s["deaths"], s["starved"], s["killed"], s["left"], s["empty"], roundi(s["min_food"] * 100), s["sealed"], s["interrupts"], s["pauses"], s["gap"], roundi(s["era2"] * 100), s["ranks"], roundi(s["craft_gate"] * 100)])
	print("\nBands (share of runs): near-miss %d-%d%%, famine consequences %d-%d%%." % [BANDS["near_miss"][0] * 100, BANDS["near_miss"][1] * 100, BANDS["famine"][0] * 100, BANDS["famine"][1] * 100])
	for pid in summ:
		for k in BANDS:
			var v: float = summ[pid][k]
			var where := "in band" if v >= BANDS[k][0] and v <= BANDS[k][1] else ("BELOW" if v < BANDS[k][0] else "ABOVE")
			print("  %s %s: %d%% %s" % [pid, k, roundi(v * 100), where])
	if summ.has("hoarder") and summ.has("feaster"):
		var d: float = absf(summ["hoarder"]["min_food"] - summ["feaster"]["min_food"]) + absf(summ["hoarder"]["famine"] - summ["feaster"]["famine"]) + absf(summ["hoarder"]["near_miss"] - summ["feaster"]["near_miss"])
		print("Skill sensitivity (hoarder vs feaster: min food + famine + near-miss gaps): %.2f%s" % [d, "  <- food decisions barely matter" if d < 0.15 else ""])
	print("Forecast calibration: n/a (A0 not built yet)")

func _mean(rs: Array, k: String) -> float:
	var t := 0.0
	for r in rs: t += float(r[k])
	return t / maxf(1.0, rs.size())
