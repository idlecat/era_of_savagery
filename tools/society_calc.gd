## The society model's calculator (docs/society.md §12, society_plan.md step 0). For each
## level of config/society.json it solves a periodic year at a fixed size: the 8-day year
## day by day (each season's yields and hunger, the allocation of model §8 with food's two
## windows, the stores carried over and spoiling), repeated until the stores at the start
## of spring come round the same. It prints the year-averaged share of hands per need
## against the model's share table, R, h, the walk, the coverage of every need and the
## standard; per season, the rhythm; and with --sweep, the size at which each level meets
## its ceiling. Nothing here touches the game.
##
## $GODOT --headless --path . --script res://tools/society_calc.gd -- [--level=all|band,camp,...]
##     [--n=N] (another size than the level's own) [--seasons] (the per-season table)
##     [--sweep] (sizes from half to three times the level's: where coverage falls)
##     [--fit] (what the fitted knobs would need to be to land the share table)
##     [--no-institutions] (town and city without the Council and the Code)
##     [--delta=D] [--base=B] (try another horizon discount or food base rate, nothing written)
extends SceneTree

const M = preload("res://scripts/society_model.gd")
const Config = preload("res://scripts/config.gd")

const NEEDS := ["shelter", "warmth", "health", "safety", "order", "knowledge", "comfort", "spirit"]
const COLS := ["food", "shelter_warmth", "health", "safety", "order", "knowledge", "comfort_spirit"]
const SEASONS := ["spring", "summer", "autumn", "winter"]

var S: Dictionary # config/society.json
var RULES: Dictionary
var EVENTS: Dictionary
var args := {}

func _initialize() -> void:
	for s in OS.get_cmdline_user_args():
		var kv := s.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	S = Config.load_cfg("society")
	RULES = Config.load_cfg("rules")
	EVENTS = Config.load_cfg("events")
	var names: Array = []
	for k in S["levels"]:
		if k != "_doc": names.append(k)
	if args.get("level", "all") != "all": names = names.filter(func(n): return n in str(args["level"]).split(","))
	var fits := {}
	for lv in names:
		var L: Dictionary = S["levels"][lv]
		var n := float(args.get("n", L["N"]))
		var inst = null if not args.has("no-institutions") else false
		var r := solve(L, n, inst)
		report(lv, L, n, r)
		if args.has("seasons"): report_seasons(r)
		if args.has("sweep"): sweep(lv, L, inst)
		if args.has("fit"): fits[lv] = fit(lv, L, n, r)
	if args.has("fit"):
		print("\n== Fitted (paste into config/society.json levels.<level>.hands, then rerun) ==")
		print(JSON.stringify(fits, " "))
	quit(0)

# ------------------------------------------------------------------ the year
## The periodic year for level L at size n; inst overrides the level's institutions.
func solve(L: Dictionary, n: float, inst = null) -> Dictionary:
	var P: Dictionary = S["people"]
	var kids := n * float(P["children"])
	var adults := n - kids
	var workers := adults * (1.0 - float(P["unwell"]))
	var dps := int(EVENTS["seasons"]["days"])
	var days := dps * 4
	var h_work := float(S["day"]["awake"]) - float(S["day"]["meals_life"])
	var walk := clampf(float(L["walk"]) * sqrt(n / float(L["N"])), 0.02, float(S["walk"]["cap"]))
	var h_food := h_work * (1.0 - walk)
	var sv: Dictionary = RULES["survival"]
	var speed := float(S["walk"]["speed"])
	var paces_food := h_work * walk * speed
	var paces_in := h_work * float(S["walk"]["indoor"]) * speed
	var fill := float(sv["meal_fill_fire"])
	var hunger_s: Array = EVENTS["seasons"]["hunger"]
	var F: Dictionary = L["factors"]
	var non_method := float(F["products"]) * float(F["skill"]) * float(F["techniques"]) * float(F["culture"])
	var tools: Dictionary = S["tools"]
	var t_share := 0.0 if float(F["products"]) <= 1.0 else 1.0 / (float(tools["wear_days"]) * float(tools["make_per_day"])) # (toolmakers per food hand)
	var srcs: Array = L["sources"]
	# a hand's food a day on each source in each season (toolmakers' share folded in)
	var rate := {}
	for src in srcs:
		var sd: Dictionary = S["food"]["sources"][src]
		rate[src] = []
		for si in 4:
			var f := float(args.get("base", S["food"]["base"])) * (float(F["method"]) if sd["method"] else 1.0) * non_method * float(sd["rel"]) * float(sd["season"][si]) * h_food
			rate[src].append(f / (1.0 + t_share))
	var harvest := _harvest_season(srcs)
	# the other needs' demand, in hands at full coverage, and their values
	var D := {}
	var hands: Dictionary = L["hands"]
	var institutions: bool = L["institutions"] if inst == null else bool(inst)
	for need in NEEDS:
		match need:
			"health": D[need] = float(hands["health"]) * n * pow(n / float(S["health"]["n_ref"]), float(S["health"]["density_k"]))
			"safety": D[need] = maxf(float(S["safety"]["vigilance"]), float(hands["safety"]) * pow(n / float(S["safety"]["n_ref"]), float(S["safety"]["wealth_k"]))) * n
			"order":
				var o: Dictionary = S["order"]
				D[need] = float(hands["order"]) * M.order_demand(n, float(o["a_c"]), float(o["a_d"]), float(o["n0"]), float(o["k"]), L["steward"]) / M.order_span(n, float(o["n1"]), institutions, float(o["code_mult"]))
			_: D[need] = float(hands[need]) * n
	var vals: Dictionary = S["values"]
	var V := {}
	for need in NEEDS: V[need] = _value(need)
	var v_now := _value("food_now")
	var imp_h: Dictionary = S["impact"]["food_horizon"]
	var step := maxf(0.25, workers / 400.0) # (a quarter of a working day: small tribes split their days)
	var food_hands_prev := workers * 0.5
	var stores := 0.0
	var spring_prev := -1.0
	var rec: Array = []
	var days_ahead_prev := float(S["horizon_max"])
	var years := 0
	var year_food := 1.0
	for y in 60:
		years = y + 1
		rec = []
		var spring := stores
		for t in days:
			var si := int(t / dps)
			var d_day := func(si2: int, fh: float) -> float:
				var hd := float(sv["hunger_rate"]) * 90.0 * float(hunger_s[si2])
				return float(sv["meal"]) / fill * (hd * (adults + float(P["child_eats"]) * kids) + fh * paces_food * float(sv["walk_hunger"]) + (workers - fh) * paces_in * float(sv["walk_hunger"]))
			var d_today: float = d_day.call(si, food_hands_prev)
			var hz := _horizon(t, si, dps, days, harvest)
			var keep := 1.0 - float(L["spoil"])
			var imp := float(L["import"])
			var h_seasons: Array = []
			var dem: Array = [] # the horizon's demand, day by day
			var sup: Array = [] # its forecast supply: today's allocation held (persistence), with the import
			for j in hz:
				var sj := int(((t + j) % days) / dps)
				h_seasons.append(sj)
				dem.append(d_day.call(sj, food_hands_prev))
				sup.append(imp * dem[j])
			var s_today := imp * d_today
			var nsrc := {}
			for src in srcs: nsrc[src] = 0.0
			var nneed := {}
			for need in NEEDS: nneed[need] = 0.0
			var left := workers
			var v_h := float(vals["growth"]) * float(imp_h.get("growth", 0.0)) + float(vals["mortality"]) * float(imp_h.get("mortality", 0.0)) * pow(float(args.get("delta", S["delta"])), days_ahead_prev)
			var zero: Array = []
			for j in hz: zero.append(0.0)
			while left > 0.0:
				var q := minf(step, left)
				var best := ""
				var bw := 1e-9
				var c_now := (stores + s_today) / (d_today * (1.0 + float(S["work"]["reserve_days"]))) # (today's eating and a reserve in store, as the game's Steward: society.gd)
				var c_h: float = _c_horizon(stores, keep, sup, dem, zero)[0]
				for src in srcs:
					var s_now := _added(src, nsrc[src], q, rate, si, L)
					if s_now <= 0.0: continue # (no delayed payoff: work that yields nothing today is credited nothing)
					var add: Array = []
					for sj in h_seasons: add.append(_added(src, nsrc[src], q, rate, sj, L))
					var c_h2: float = _c_horizon(stores, keep, sup, dem, add)[0]
					var w := n * (v_now * M.gain(c_now, s_now, d_today) + v_h * (M.benefit(c_h2) - M.benefit(c_h)))
					if w > bw:
						bw = w
						best = "food:" + src
				for need in NEEDS:
					var w2: float = float(V[need]) * n * M.gain(nneed[need] / maxf(1e-6, D[need]), q, D[need])
					if w2 > bw:
						bw = w2
						best = need
				if best == "": break # (every need covered: the rest is leisure)
				if best.begins_with("food:"):
					var src2 := best.trim_prefix("food:")
					s_today += _added(src2, nsrc[src2], q, rate, si, L)
					for jj in hz: sup[jj] += _added(src2, nsrc[src2], q, rate, h_seasons[jj], L)
					nsrc[src2] += q
				else: nneed[best] += q
				left -= q
			var fh := 0.0
			for src in srcs: fh += nsrc[src]
			food_hands_prev = fh
			var eaten: float = d_day.call(si, fh)
			var c_now_day := minf(1.0, (stores + s_today) / eaten)
			var hr: Array = _c_horizon(stores, keep, sup, dem, zero)
			var c_h_day: float = hr[0]
			days_ahead_prev = float(hr[1]) if c_h_day < 1.0 else float(hz) # (the horizon's discount runs to the worst day)
			stores = maxf(0.0, stores + s_today - eaten)
			var safe := float(S["spoil_free"]["food"])
			if stores > safe: stores = safe + (stores - safe) * keep # (the first 30 keep, as in the game)
			var cov := {}
			for need in NEEDS: cov[need] = 1.0 if D[need] <= 1e-6 else minf(1.0, nneed[need] / D[need]) # (no demand: covered)
			rec.append({"si": si, "src": nsrc.duplicate(), "need": nneed.duplicate(), "idle": left, "food_hands": fh, "tools": fh * t_share / (1.0 + t_share),
				"own": s_today - imp * d_today, "made": s_today, "eaten": eaten, "stores": stores, "c_now": c_now_day, "c_h": c_h_day, "cov": cov, "hz": hz, "worst": hr[1]})
		year_food = 0.0
		for d in rec: year_food += d["eaten"]
		if spring_prev >= 0.0 and absf(spring - spring_prev) < 0.005 * year_food: break
		spring_prev = spring
	return {"rec": rec, "workers": workers, "n": n, "kids": kids, "adults": adults, "walk": walk, "h_food": h_food, "D": D, "days": days, "years": years,
		"t_share": t_share, "products": float(F["products"]), "year_food": year_food, "institutions": institutions}

## Food's look-ahead coverage (model §4): the lowest running coverage over the horizon,
## (the stores, spoiling, plus the supply so far) / (the demand so far), at its worst day;
## returns [coverage, the worst day's index]. `add` is a candidate hand's supply by day.
func _c_horizon(stores: float, keep: float, sup: Array, dem: Array, add: Array) -> Array:
	var have := 0.0
	var need := 0.0
	var worst := INF
	var at := 0
	for j in dem.size():
		have += float(sup[j]) + float(add[j])
		need += float(dem[j])
		var r := (stores * pow(keep, j + 1) + have) / maxf(1e-6, need)
		if r < worst:
			worst = r
			at = j
	return [worst, at]

## A need's value per person (model §8): each channel's value times how much of it the need
## moves when uncovered (society.json impact).
func _value(need: String) -> float:
	var v := 0.0
	var imp: Dictionary = S["impact"][need]
	for ch in imp: v += float(S["values"][ch]) * float(imp[ch])
	return v

## Food one more q hands add on src in season si (land-limited, model §3.2).
func _added(src: String, have: float, q: float, rate: Dictionary, si: int, L: Dictionary) -> float:
	var f: float = rate[src][si]
	if f <= 0.0: return 0.0
	var sd: Dictionary = S["food"]["sources"][src]
	var y := float(L["Y"].get(src, 0)) * float(sd["season"][si])
	return M.land_output(have + q, f, y) - M.land_output(have, f, y)

## The harvest window: the last season in which the fields and the wild yield before one in
## which they don't (model §4).
func _harvest_season(srcs: Array) -> int:
	for si in 4:
		var now := 0.0
		var nxt := 0.0
		for src in ["wild", "field"]:
			if not src in srcs: continue
			now += float(S["food"]["sources"][src]["season"][si])
			nxt += float(S["food"]["sources"][src]["season"][(si + 1) % 4])
		if now > 0.0 and nxt <= 0.0: return si
	return 2

## Days in the horizon from day t: through the next lean season, to its end (the day after
## the season that follows the harvest window), clamped to horizon_max (model §4).
func _horizon(t: int, si: int, dps: int, days: int, harvest: int) -> int:
	var end := ((harvest + 2) % 4) * dps # (the first day after the lean season)
	if end <= t: end += days
	return clampi(end - t, 1, int(S["horizon_max"]))

# ------------------------------------------------------------------ reading the year
func _shares(r: Dictionary, which := -1) -> Dictionary:
	var out := {}
	for c in COLS: out[c] = 0.0
	out["idle"] = 0.0
	var nd := 0
	for d in r["rec"]:
		if which >= 0 and d["si"] != which: continue
		nd += 1
		out["food"] += d["food_hands"]
		out["shelter_warmth"] += d["need"]["shelter"] + d["need"]["warmth"]
		out["comfort_spirit"] += d["need"]["comfort"] + d["need"]["spirit"]
		for k in ["health", "safety", "order", "knowledge"]: out[k] += d["need"][k]
		out["idle"] += d["idle"]
	for k in out: out[k] /= maxf(1.0, nd) * r["workers"]
	return out

func _stats(r: Dictionary) -> Dictionary:
	var own := 0.0
	var fhd := 0.0
	var eaten := 0.0
	var own_a := 0.0
	var fhd_a := 0.0
	var eat_a := 0.0
	var cov := {}
	for need in NEEDS: cov[need] = 0.0
	var c_now_min := 1.0
	var stores_max := 0.0
	var intake := 0.0
	var prev = null
	for d in r["rec"]:
		own += d["own"]
		fhd += d["food_hands"]
		eaten += d["eaten"]
		if d["si"] <= 1:
			own_a += d["own"]
			fhd_a += d["food_hands"]
			eat_a += d["eaten"]
		for need in NEEDS: cov[need] += d["cov"][need]
		c_now_min = minf(c_now_min, d["c_now"])
		stores_max = maxf(stores_max, d["stores"])
		if prev != null:
			intake = maxf(intake, d["food_hands"] - prev["food_hands"])
			for need in NEEDS: intake = maxf(intake, d["need"][need] - prev["need"][need])
		prev = d
	var nd: int = r["rec"].size()
	for need in NEEDS: cov[need] /= nd
	var w: float = r["workers"]
	# R = food a food hand makes a day over what a worker and their dependants eat a day
	var r_year := (own / maxf(1e-6, fhd)) / (eaten / (w * nd))
	var r_act := (own_a / maxf(1e-6, fhd_a)) / (eat_a / (w * 2.0 * (nd / 4.0)))
	var std := 0.0
	for need in ["shelter", "warmth", "comfort", "spirit"]: std += cov[need]
	std = (std + 1.0) / 5.0 # (food: the year's C_now is 1 unless the stores ran out, below)
	if c_now_min < 1.0: std -= (1.0 - c_now_min) / 5.0
	var d_mouths: float = (r["adults"] + float(S["people"]["child_eats"]) * r["kids"]) / w
	return {"R": r_year, "R_active": r_act, "cov": cov, "c_now_min": c_now_min, "stores_max": stores_max, "intake": intake / w, "standard": std, "d": d_mouths,
		"c": eaten / nd / (r["adults"] + float(S["people"]["child_eats"]) * r["kids"]),
		"tools_share": r["t_share"] / (1.0 + r["t_share"]),
		"payback": M.payback(float(r["products"]) - 1.0 - r["t_share"], r["t_share"]) if r["t_share"] > 0.0 else 0.0}

func report(lv: String, L: Dictionary, n: float, r: Dictionary) -> void:
	var st := _stats(r)
	var sh := _shares(r)
	var T: Dictionary = S["targets"].get(lv, {})
	print("\n== %s, %d people (%d workers, d %.2f), %d years to settle%s ==" % [lv, int(n), int(r["workers"]), st["d"], r["years"], "" if r["institutions"] else ", no institutions"])
	var budget := M.factor_product(L["factors"])
	print("  R %.2f over the year (band %s), %.2f in spring and summer; food share %.0f%% (1/R %.0f%%); c %.2f food a day; walk %.0f%% of a food hand's work (h %.0f s)" %
		[st["R"], str(T.get("R", "?")), st["R_active"], sh["food"] * 100.0, 100.0 / st["R"], st["c"], r["walk"] * 100.0, r["h_food"]])
	print("  productivity factors x%.2f; toolmakers %.1f%% of food hands, payback %.1f" % [budget, st["tools_share"] * 100.0, st["payback"]])
	var line := "  %-15s" % "share"
	for c in COLS: line += " %14s" % c
	print(line + " %8s" % "idle")
	line = "  %-15s" % "model"
	for c in COLS: line += " %13.0f%%" % (sh[c] * 100.0)
	print(line + " %7.0f%%" % (sh["idle"] * 100.0))
	if not T.is_empty():
		line = "  %-15s" % "target"
		for c in COLS: line += " %13.0f%%" % (float(T[c]) * 100.0)
		print(line)
	line = "  %-15s" % "coverage"
	for need in NEEDS: line += " %s %.2f" % [need, st["cov"][need]]
	print(line)
	print("  food: C_now lowest %.2f; the stores peak at %.0f (%.1f days of eating); standard %.2f; the largest one-day intake on a need %.0f%% of the hands" %
		[st["c_now_min"], st["stores_max"], st["stores_max"] / (r["year_food"] / r["days"]), st["standard"], st["intake"] * 100.0])

func report_seasons(r: Dictionary) -> void:
	print("  per season:")
	for si in 4:
		var sh := _shares(r, si)
		var cn := 1.0
		var ch := 0.0
		var nd := 0
		for d in r["rec"]:
			if d["si"] != si: continue
			cn = minf(cn, d["c_now"])
			ch += d["c_h"]
			nd += 1
		var line := "    %-8s" % SEASONS[si]
		for c in COLS: line += " %s %.0f%%" % [c, sh[c] * 100.0]
		print(line + " idle %.0f%%  C_now %.2f C_horizon %.2f" % [sh["idle"] * 100.0, cn, ch / maxf(1, nd)])

func sweep(lv: String, L: Dictionary, inst) -> void:
	var n0 := float(L["N"])
	print("  sweep (the level's methods at other sizes):")
	var ceiling := -1.0
	for m in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0]:
		var r := solve(L, n0 * m, inst)
		var st := _stats(r)
		var sh := _shares(r)
		var low := ""
		var lowc := 2.0
		for need in NEEDS:
			if st["cov"][need] < lowc:
				lowc = st["cov"][need]
				low = need
		print("    %5d people: R %.2f, food %.0f%%, order %.0f%%, health %.0f%%, comfort+spirit %.0f%%, idle %.0f%%, standard %.2f, lowest %s %.2f, C_now min %.2f" %
			[int(n0 * m), st["R"], sh["food"] * 100.0, sh["order"] * 100.0, sh["health"] * 100.0, sh["comfort_spirit"] * 100.0, sh["idle"] * 100.0, st["standard"], low, lowc, st["c_now_min"]])
		if ceiling < 0.0 and (lowc < float(S["c_floor"]) or st["c_now_min"] < float(S["c_floor"])): ceiling = n0 * m
	print("    ceiling: %s" % ("none below %d" % int(n0 * 3.0) if ceiling < 0.0 else "about %d people (a need's coverage under its floor %.1f)" % [int(ceiling), float(S["c_floor"])]))

## What the level's hands per head would need to be to land its target shares, given the
## food share the year actually gave (model §12's fitted knobs).
func fit(lv: String, L: Dictionary, n: float, r: Dictionary) -> Dictionary:
	var T: Dictionary = S["targets"][lv]
	var sh := _shares(r)
	var w: float = r["workers"]
	var out := {}
	var hands: Dictionary = L["hands"]
	for need in ["health", "safety", "order", "knowledge"]:
		var want := float(T[need]) * w
		var have: float = r["D"][need]
		out[need] = snappedf(float(hands[need]) * (want / have if have > 0.0 else 1.0), 0.0001)
	var sw := float(T["shelter_warmth"]) * w / n
	out["shelter"] = snappedf(sw / 2.0, 0.0001)
	out["warmth"] = snappedf(sw / 2.0, 0.0001)
	var others := 0.0
	for c in ["shelter_warmth", "health", "safety", "order", "knowledge"]: others += float(T[c])
	var cs := maxf(0.0, 1.0 - sh["food"] - others) * w / n # (comfort and spirit take what food and the rest leave)
	out["comfort"] = snappedf(cs * 0.6, 0.0001)
	out["spirit"] = snappedf(cs * 0.4, 0.0001)
	var st := _stats(r)
	var mid := (float(T["R"][0]) + float(T["R"][1])) / 2.0
	print("  fit: comfort+spirit would take %.0f%% (target %.0f%%) after food's %.0f%%; R %.2f against the band's middle %.2f (food base x%.2f would land it)" %
		[cs * n / w * 100.0, float(T["comfort_spirit"]) * 100.0, sh["food"] * 100.0, st["R"], mid, mid / st["R"]])
	return out
