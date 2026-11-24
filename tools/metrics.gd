## Metric runs (docs/make_it_fun.md G1): plays seeded games headless under scripted policies
## and reports whether the game's numbers land in their target bands, and whether they
## differ between policies (if hoarders and feasters fare the same, food decisions are theater).
##
## $GODOT --headless --path . --script res://tools/metrics.gd -- [--runs=4] [--days=12] [--seed=1]
##     [--policies=steward,hoarder,feaster] [--level=normal] [--map=the_ford|standard...] [--dt=0.1] [--out=/path.csv]
##     [--choose=autumn:2,festival:0] (these dilemmas take that option, whatever the policy says)
##     [--winter=white|wolf|lean|mild] (the first winter is that kind: hz.set_winter, as a game master would)
##     [--cap=N] [--decay=N] (G3: the director's tension cap / decay for this run's level, on a copy
##     of director.json: nothing on disk changes)
##     [--baseline=res://tests/balance_baseline.json [--write-baseline]] (G2, the balance canary: compare each
##     policy's summary with the baseline and warn where a metric moved past its tolerance, or write it anew)
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
## Forecast calibration (A0): contracts.forecast() read at sealing (c.forecast) against the
## first abort reason each contract actually met.
extends SceneTree

const Sim = preload("res://scripts/sim.gd")
const D = preload("res://scripts/data.gd")
const MapGen = preload("res://scripts/mapgen.gd")
const Scenarios = preload("res://scripts/scenarios.gd")
const Cultures = preload("res://scripts/cultures.gd")

## The target bands: [low, high] share of runs (or a value), docs/make_it_fun.md G1.
const BANDS := {"near_miss": [0.6, 0.9], "famine": [0.1, 0.25]}
## Share of outposts (settle contracts that ended) interrupted at least once: most should
## be quiet enough that an interrupt is news, some must be hit (make_it_fun G1).
const OUTPOST_BAND := [0.4, 0.7]
## Naturalness (ROADMAP §3.0): do people act like people? Sampled once a game second over
## the grown-ups. Bands are [low, high]; a value outside is a finding to look at by watching.
##   walk       share of working time (a work job) spent walking
##   empty      share of working time spent walking with empty hands
##   switches   changes from one kind of work straight to another, per person-hour of work
##   stuck      times someone with work stood still, hands idle, for STUCK_SECS, per person-day
##   night_up   share of the night grown-ups at home spend awake with nothing to do
##   left_kills kills left with meat on them, nobody at them for a day, per run
const NATURAL_BANDS := {"walk": [0.15, 0.6], "empty": [0.0, 0.4], "switches": [0.0, 1.5], "stuck": [0.0, 0.5], "night_up": [0.0, 0.1], "left_kills": [0.0, 0.5]}
const WORK_JOBS := ["gather", "build", "tend", "art", "ritual", "experiment", "seek", "trade_trip"]
const STUCK_SECS := 15.0

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
		var keys: Array = rows[0].keys().filter(func(k): return not k in ["forecasts", "causes", "challenges"]) if not rows.is_empty() else []
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
	if a.has("cap") or a.has("decay"): # (G3: try the director's numbers without touching the config)
		var dc: Dictionary = sim.director.C.duplicate(true)
		var lv: Dictionary = dc["levels"][sim.hz.level]
		if a.has("cap"): lv["cap"] = float(a["cap"])
		if a.has("decay"): lv["decay"] = float(a["decay"])
		sim.director.C = dc
	sim.new_game()
	if pol.get("steward", true):
		var best = null
		for u in sim.living():
			if u.role == "" and (best == null or u.lv("lore") > best.lv("lore")): best = u
		if best: sim.appoint(best, "steward")
	var r := {"policy": pol["id"], "seed": sd, "days": 0, "alive": 0, "deaths": 0, "deaths_d20": 0, "starved": 0, "killed": 0, "other_deaths": 0, "left": 0,
		"near_miss": false, "sick_wave": false, "hungry_sick": false, "famine": false, "hungry_hours": 0.0, "min_food_frac": 1.0,
		"dilemmas": 0, "feats": 0, "interrupts": 0, "crises": 0, "sealed": 0, "seal_refused": 0,
		"pauses_per_hour": 0.0, "max_gap_days": 0.0, "era2_day": -1, "ranks": 0, "first_rank_day": -1, "craft_gate_day": -1, "causes": [],
		"winter_kind": "", "autumn_pick": "", "winter_deaths": 0, "winter_min_food": 1.0, "winter_hungry_h": 0.0,
		"winter_mood": 0.0, "winter_n": 0, "winter_packs": 0, "winter_blizzards": 0, "winter_held": 0, "winter_cold_hp": 0.0, "winter_bitten": 0, "mood_end": 0.0}
	var meaningful: Array = [0.0] # game times of meaningful events
	sim.feat_added.connect(func(_f): r["feats"] += 1; meaningful.append(sim.time))
	var first_abort := {}
	sim.contract_interrupted.connect(func(c):
		r["interrupts"] += 1
		meaningful.append(sim.time)
		if not first_abort.has(c.id): first_abort[c.id] = c.abort_reason
		r["causes"].append(_cause(sim, c)))
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
	var nat := {"work": 0.0, "walk": 0.0, "empty": 0.0, "switches": 0, "stuck": 0, "night": 0.0, "night_up": 0.0, "person_days": 0.0, "u": {}, "kills": {}}
	while sim.time < end_t and not sim.living().is_empty():
		# the player's seat, played by the policy
		if sim.pending_event != "":
			if sim.pending_event != last_pending:
				r["dilemmas"] += 1
				meaningful.append(sim.time)
			last_pending = sim.pending_event
			var pick := _pick(sim, sim.pending_event, str(pol.get("dilemmas", "first")))
			if sim.pending_event == "autumn" and r["autumn_pick"] == "": r["autumn_pick"] = str(sim.event_def("autumn")["options"][pick]["label"])
			if sim.pending_event == "autumn" and a.has("winter"): sim.hz.set_winter(str(a["winter"]))
			sim.resolve_event(sim.pending_event, pick)
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
			_natural(sim, nat)
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
	r["mood_end"] = roundi(sim.folk.mood)
	var nem: String = sim.rivals.nemesis_id()
	r["nemesis"] = nem
	r["challenges"] = sim.challenges.done.duplicate()
	r["feud_over"] = nem != "" and sim.rivals.clans[nem].get("feud_over", false)
	r["nemesis_raids"] = 0
	r["other_raids"] = 0
	r["successions"] = 0
	for id in sim.rivals.clans:
		var cl: Dictionary = sim.rivals.clans[id]
		var n: int = cl.get("ledger", []).filter(func(e): return e["kind"] == "raided").size()
		if id == nem: r["nemesis_raids"] += n
		else: r["other_raids"] += n
		if float(cl.get("chief_t", 0.0)) > 0.0: r["successions"] += 1
	r["winter_mood"] = roundi(r["winter_mood"] / maxf(1, r["winter_n"]))
	r["winter_cold_hp"] = roundi(r["winter_cold_hp"])
	for k in r.keys():
		if str(k).begins_with("_"): r.erase(k)
	var fcs: Array = []
	for c in sim.contracts.list:
		if c.forecast.is_empty() or (sim.contracts.is_running(c) and not first_abort.has(c.id)): continue # (still under way, no verdict yet)
		var scores := {}
		for x in c.forecast["reasons"]: scores[x["id"]] = x["score"]
		var first: String = first_abort.get(c.id, "")
		fcs.append({"events": c.said.keys().filter(func(k): return str(k).begins_with("ev_") and k != "ev_t").size(), "secs": float(c.said.get("clock", 0.0)), "kind": c.kind, "risk": c.forecast["risk"], "top": c.forecast["reasons"][0]["id"] if not c.forecast["reasons"].is_empty() else "",
			"first": first, "named": first != "" and sim.contracts.foresaw(c, first), "scores": scores})
	r["forecasts"] = fcs
	var left := 0
	for id in nat["kills"]:
		var n = sim.node_by_id(id)
		if n and n.kind == "carcass" and n.amount >= 1 and sim.time - float(nat["kills"][id]) > D.DAY_LEN: left += 1
	var wh := maxf(1.0, nat["work"]) # person-seconds of work
	r["natural"] = {"walk": nat["walk"] / wh, "empty": nat["empty"] / wh, "switches": nat["switches"] / maxf(0.01, nat["work"] / (D.DAY_LEN / 24.0)),
		"stuck": nat["stuck"] / maxf(0.01, nat["person_days"]), "night_up": nat["night_up"] / maxf(1.0, nat["night"]), "left_kills": float(left)}
	sim.dispose()
	return r

func _sample(sim, r: Dictionary, dead_seen: Dictionary) -> void:
	var frac: float = sim.stock["food"] / maxf(1.0, float(sim.food_cap()))
	if sim.hz.winter() and sim.hz.year() == 1:
		r["winter_kind"] = sim.hz.winter_kind
		r["winter_mood"] += sim.folk.mood
		r["winter_n"] += 1
		for p in sim.predators:
			if p.kind == "wolf" and not r.has("_w%d" % p.id): # (a new wolf: count packs by their first member)
				r["_w%d" % p.id] = true
				if not r.has("_pack%d" % int(sim.time / 20.0)): r["winter_packs"] += 1
				r["_pack%d" % int(sim.time / 20.0)] = true
		if sim.hz.weather == "blizzard" and not r.get("_bz", false): r["winter_blizzards"] += 1
		r["_bz"] = sim.hz.weather == "blizzard"
		r["winter_held"] = sim.director.held.filter(func(h): return sim.hz.season_idx() == 3 and sim.time - h["t"] < D.DAY_LEN * sim.hz.SEASON_DAYS).size()
		for u in sim.living():
			r["winter_cold_hp"] += sim.hz.cold_rate(u, sim.near_warmth(u))
			if u.last_hit_t > sim.time - 1.0: r["winter_bitten"] += 1
		r["winter_min_food"] = minf(r["winter_min_food"], frac)
		if frac < 0.02: r["winter_hungry_h"] += 1.0 / (D.DAY_LEN / 24.0)
		for u in sim.units:
			if u.dead and not u.gone and not dead_seen.has(u.id): r["winter_deaths"] += 1
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

## What interrupted a contract, for the report: its kind, the abort reason and, for an
## attack, what was there (the nearest attacker's kind within the abort radius, or "hit").
func _cause(sim, c) -> String:
	var what := ""
	if c.abort_reason == "enemy_attack":
		var near: Array = sim.active_predators_near(c.site, 260)
		near.sort_custom(func(x, y): return x.pos.distance_to(c.site) < y.pos.distance_to(c.site))
		what = (near[0].kind + (":guard" if near[0].guard else "")) if not near.is_empty() else "hit away from the site"
	elif c.abort_reason == "natural_disaster": what = str(sim.flags.get("disaster", "flood")) if sim.flags.get("disaster_t", -1.0) >= sim.flags.get("flood_active", -1.0) else "flood"
	return "%s %s %s (%d%%, n%d)" % [c.kind, c.abort_reason, what, roundi(c.progress * 100), c.interruptions]

## The option a policy takes: the first or last one that can be chosen (or the one
## --choose names for this dilemma, if it can be chosen).
func _pick(sim, id: String, how: String) -> int:
	var opts: Array = sim.event_def(id).get("options", [])
	for kv in str(a.get("choose", "")).split(",", false):
		var p: PackedStringArray = kv.split(":")
		if p.size() == 2 and p[0] == id and int(p[1]) < opts.size() and opts[int(p[1])].get("enabled", true): return int(p[1])
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
	print("\n== G1 metrics (%s days, %s, %s%s) ==" % [a.get("days", "12"), a.get("map", "the_ford"), a.get("level", "normal"), (", director cap %s decay %s" % [a.get("cap", "-"), a.get("decay", "-")]) if a.has("cap") or a.has("decay") else ""])
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
	_calibration(rows)
	_naturalness(rows, pols)
	if a.has("baseline"): _baseline(summ)
	var allc: Array = []
	for r in rows: allc.append_array(r["forecasts"])
	if not allc.is_empty():
		var evn := 0.0
		var secs := 0.0
		for f in allc:
			evn += f["events"]
			secs += f["secs"]
		print("\nContract events (A2/A3): %.1f per contract, one per %.0f s of working time" % [evn / allc.size(), secs / maxf(1.0, evn)])
	var outs: Array = []
	for r in rows: outs.append_array(r["forecasts"].filter(func(f): return f["kind"] == "settle"))
	if not outs.is_empty():
		var sh := outs.filter(func(f): return f["first"] != "").size() / float(outs.size())
		print("\nOutposts interrupted at least once: %d%% of %d (band %d-%d%%) %s" % [roundi(sh * 100), outs.size(), OUTPOST_BAND[0] * 100, OUTPOST_BAND[1] * 100, "in band" if sh >= OUTPOST_BAND[0] and sh <= OUTPOST_BAND[1] else ("BELOW" if sh < OUTPOST_BAND[0] else "ABOVE")])
	var causes := {}
	for r in rows:
		for k in r["causes"]:
			var key: String = k.get_slice(" (", 0)
			causes[key] = causes.get(key, 0) + 1
	print("\nChallenges (met / failed / declined, per run):")
	for r in rows: print("  %s seed %d: %s" % [r["policy"], r["seed"], r["challenges"]])
	print("\nRivals (nemesis, its raids / other clans' raids, feud over, chiefs succeeded):")
	for r in rows: print("  %s seed %d: %-7s %d / %d  over %s  successions %d" % [r["policy"], r["seed"], r["nemesis"], r["nemesis_raids"], r["other_raids"], r["feud_over"], r["successions"]])
	print("\nThe first winter (kind, autumn choice -> winter deaths, min food, empty-store hours):")
	for r in rows:
		if r["winter_kind"] != "": print("  %s seed %d: %-6s %-38s -> deaths %d, min food %d%%, empty %.0fh, mood %d, packs %d, blizzards %d, held %d, cold hp %d, bitten %d" % [r["policy"], r["seed"], r["winter_kind"], r["autumn_pick"], r["winter_deaths"], roundi(r["winter_min_food"] * 100), r["winter_hungry_h"], r["winter_mood"], r["winter_packs"], r["winter_blizzards"], r["winter_held"], r["winter_cold_hp"], r["winter_bitten"]])
	print("\nWhat interrupted contracts (all runs):")
	var ks: Array = causes.keys()
	ks.sort_custom(func(x, y): return causes[x] > causes[y])
	for k in ks: print("  %3d  %s" % [causes[k], k])

## Forecast calibration (A0): of the contracts that were interrupted, how often the
## top-forecast reason was the first abort (the G1 floor: ~60%), and whether the risk read
## at sealing matches how often contracts were interrupted at all (pooled over policies;
## per reason: mean forecast chance vs how often it was the first abort).
func _calibration(rows: Array) -> void:
	var fcs: Array = []
	for r in rows: fcs.append_array(r["forecasts"])
	if fcs.is_empty():
		print("Forecast calibration: no contracts ended")
		return
	var hit: Array = fcs.filter(func(f): return f["first"] != "")
	var top := hit.filter(func(f): return f["top"] == f["first"]).size()
	var named := hit.filter(func(f): return f["named"]).size()
	print("\nForecast calibration (%d contracts ended, %d interrupted):" % [fcs.size(), hit.size()])
	if not hit.is_empty():
		var share := float(top) / hit.size()
		print("  top reason was the abort: %d%%%s; named in the words: %d%%" % [roundi(share * 100), "  <- below the 60% floor" if share < 0.6 else "", roundi(float(named) / hit.size() * 100)])
	for b in [[0.0, 0.3], [0.3, 0.6], [0.6, 1.01]]:
		var fb: Array = fcs.filter(func(f): return f["risk"] >= b[0] and f["risk"] < b[1])
		if fb.is_empty(): continue
		print("  risk %d-%d%%: %d contracts, forecast %d%%, interrupted %d%%" % [b[0] * 100, mini(100, b[1] * 100), fb.size(), roundi(_mean(fb, "risk") * 100), roundi(fb.filter(func(f): return f["first"] != "").size() * 100.0 / fb.size())])
	var kinds := {}
	for f in fcs: kinds[f["kind"]] = true
	for k in kinds:
		var fk: Array = fcs.filter(func(f): return f["kind"] == k)
		var ea: Array = fk.filter(func(f): return f["scores"].has("enemy_attack"))
		var ea_mean := 0.0
		for f in ea: ea_mean += float(f["scores"]["enemy_attack"])
		print("  %-9s %d contracts, forecast %d%%, interrupted %d%%; enemy_attack forecast %d%%, first abort %d%%" % [k, fk.size(), roundi(_mean(fk, "risk") * 100), roundi(fk.filter(func(f): return f["first"] != "").size() * 100.0 / fk.size()),
			roundi(ea_mean / maxf(1, ea.size()) * 100), roundi(ea.filter(func(f): return f["first"] == "enemy_attack").size() * 100.0 / maxf(1, ea.size()))])
	var ids := {}
	for f in fcs:
		for k in f["scores"]: ids[k] = true
	for k in ids:
		var with: Array = fcs.filter(func(f): return f["scores"].has(k))
		var mean := 0.0
		for f in with: mean += float(f["scores"][k])
		print("  %-17s forecast %3d%%, was the first abort %3d%% (%d contracts)" % [k, roundi(mean / with.size() * 100), roundi(with.filter(func(f): return f["first"] == k).size() * 100.0 / with.size()), with.size()])


## How far a metric may move before the canary speaks: shares (0..1) by an absolute step,
## counts by a share of their size (and at least `floor`).
const TOLERANCE := {"share": 0.26, "count": 0.35, "floor": 0.6}
const SHARES := ["near_miss", "famine", "min_food", "era2", "craft_gate"]

## G2, the balance canary: the summaries against a committed baseline (same runs, days,
## policies and map), or written anew with --write-baseline. Moves past TOLERANCE are
## printed and, on CI, raised as GitHub warning annotations. Never fails the run.
func _baseline(summ: Dictionary) -> void:
	var path: String = a["baseline"]
	var key := {"runs": a.get("runs", "4"), "days": a.get("days", "12"), "seed": a.get("seed", "1"), "map": a.get("map", "the_ford")}
	if a.has("write-baseline"):
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(JSON.stringify({"_doc": "The balance canary's baseline (tools/metrics.gd --baseline, make_it_fun G2): per policy, the G1 summary of these runs. Refresh with --write-baseline after a change meant to move the balance.", "args": key, "policies": summ}, " ", false))
		f.close()
		print("\nBaseline written: %s" % path)
		return
	if not FileAccess.file_exists(path):
		print("\nBaseline: none at %s (write one with --write-baseline)" % path)
		return
	var base = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not base is Dictionary or base.get("args", {}) != key:
		print("\nBaseline: made with other runs (%s), not compared" % str(base.get("args", {}) if base is Dictionary else "?"))
		return
	var moved: Array = []
	for pid in summ:
		var b: Dictionary = base["policies"].get(pid, {})
		for k in summ[pid]:
			if not b.has(k): continue
			var now := float(summ[pid][k])
			var was := float(b[k])
			var lim: float = TOLERANCE["share"] if k in SHARES else maxf(float(TOLERANCE["floor"]), absf(was) * float(TOLERANCE["count"]))
			if absf(now - was) > lim: moved.append([pid, k, was, now])
	print("\nBalance canary against %s: %s" % [path, "no metric moved past its tolerance" if moved.is_empty() else "%d moved" % moved.size()])
	for m in moved:
		print("  %s %s: %.2f -> %.2f" % m)
		if OS.get_environment("GITHUB_ACTIONS") == "true": print("::warning title=Balance canary::%s %s moved from %.2f to %.2f" % m)

func _mean(rs: Array, k: String) -> float:
	var t := 0.0
	for r in rs: t += float(r[k])
	return t / maxf(1.0, rs.size())

## One second of the naturalness sample (see NATURAL_BANDS).
func _natural(sim, nat: Dictionary) -> void:
	var night: bool = sim.is_day_part("night")
	var homes: Array = sim.settlements()
	for u in sim.living():
		if u.role == "child": continue
		nat["person_days"] += 1.0 / D.DAY_LEN
		var st: Dictionary = nat["u"].get(u.id, {"pos": u.pos, "type": "", "still": 0.0, "flagged": false})
		var jt: String = u.job.get("type", "")
		var moved: float = u.pos.distance_to(st["pos"])
		if jt in WORK_JOBS and not u.sleeping:
			nat["work"] += 1.0
			if moved > 3.0:
				nat["walk"] += 1.0
				if u.carry_amt == 0: nat["empty"] += 1.0
			if st["type"] in WORK_JOBS and st["type"] != jt: nat["switches"] += 1
			if moved < 2.0 and u.doing == "":
				st["still"] += 1.0
				if st["still"] >= STUCK_SECS and not st["flagged"]:
					st["flagged"] = true
					nat["stuck"] += 1
			else:
				st["still"] = 0.0
				st["flagged"] = false
		else:
			st["still"] = 0.0
			st["flagged"] = false
		if night and u.role == "" and homes.any(func(p): return p.distance_to(u.pos) < 260.0):
			nat["night"] += 1.0
			if not u.sleeping and sim.is_idle(u): nat["night_up"] += 1.0
		if jt != "": st["type"] = jt
		st["pos"] = u.pos
		nat["u"][u.id] = st
	var claimed := {}
	for u in sim.units:
		if not u.dead and u.job.has("node_id"): claimed[u.job["node_id"]] = true
	for n in sim.nodes_of("food"):
		if n.kind == "carcass" and (claimed.has(n.id) or not nat["kills"].has(n.id)): nat["kills"][n.id] = sim.time

## The naturalness report: per policy, the mean of each measure against its band.
func _naturalness(rows: Array, pols: Array) -> void:
	print("\nNaturalness (do people act like people? bands in NATURAL_BANDS):")
	for pid in pols:
		var rs: Array = rows.filter(func(r): return r["policy"] == pid and r.has("natural"))
		if rs.is_empty(): continue
		var parts: Array = []
		for k in NATURAL_BANDS:
			var v := 0.0
			for r in rs: v += float(r["natural"][k])
			v /= rs.size()
			var b: Array = NATURAL_BANDS[k]
			parts.append("%s %.2f%s" % [k, v, "" if v >= b[0] and v <= b[1] else (" LOW" if v < b[0] else " HIGH")])
		print("  %-8s %s" % [pid, ", ".join(parts)])
