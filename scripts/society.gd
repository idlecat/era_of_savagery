## The society model in the game (docs/society.md, society_plan.md step 4), owned by the
## simulation as `sim.soc`. For now it is the Steward's allocation: where the next idle hand
## goes. Every choice is a need, weighed as the model weighs it (§8):
##   weight = V(need) x N x the actual rise in benefit one more hand gives
## where V is the channels' values times the need's impact (config/society.json values,
## impact) and benefit is concave in coverage (society_model.gd). Needs kept as a stock (food,
## wood, stone, herbs, ore, lore) are covered by the stock plus what the hands already on them
## will bring, against the Steward's target (rules.json vice.steward needs); needs met by hands
## (crafts, rites, building) by the hands on them against the model's hands per head for the
## tribe's level. Food reads two windows: today, and the worst day until the end of the next
## winter (the stores spoiling, today's food hands held there). The Steward places the idle one
## by one, the greatest weight first, each placement counted before the next. Rates per
## hand-day are measured as the game runs (config `work.rates` until then). Pure reads of the
## sim plus its own small state; deterministic (no RNG).
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")
const M = preload("res://scripts/society_model.gd")

var S: Dictionary = preload("res://scripts/config.gd").load_cfg("society")

var sim
var on := true # (tests switch it off: the old need rule; test_society_alloc and test_smoke run it)
var rate := {} # resource -> food (or wood...) a full-time hand brings in a day, measured
var income := {} # resource -> what actually comes in a day, measured (the persistence forecast: today's allocation held)
var _yield := {} # resource -> amount brought in since the last measure
var _hand_s := {} # resource -> hand-seconds spent on it since the last measure
var _measure_t := 0.0
var placed := {} # choice -> hands placed this round (counted before the next)
var avg_hands := {} # choice -> hands on it, averaged over the last avg_secs (short jobs, like a carving, come and go)
var last := {} # choice -> weight, the last round (for a game master and the HUD)

func _init(s) -> void:
	sim = s

## A work knob (config/society.json work) for the challenge level now: work.by_challenge
## [hz.level] overrides the defaults, as director.json's levels do (make_it_fun.md G: the
## designer's knobs, measured against the G1 bands).
func work_val(key: String):
	var by: Dictionary = S["work"].get("by_challenge", {}).get(sim.hz.level, {})
	return by[key] if by.has(key) else S["work"][key]

## A need's value per person: its channels' values times its impact on them (model §8).
func value(need: String) -> float:
	var v := 0.0
	var imp: Dictionary = S["impact"].get(need, {})
	for ch in imp: v += float(S["values"][ch]) * float(imp[ch])
	return v

## What a full-time hand brings in a day of `res` (measured; the config's guess until then).
func rate_of(res: String) -> float:
	return float(rate.get(res, S["work"]["rates"].get(res, 10.0)))

## Booked by the sim where gathered goods reach the stores (and fields add food).
func note_yield(res: String, amt: float) -> void:
	if amt > 0.0: _yield[res] = float(_yield.get(res, 0.0)) + amt

## The model's level for the tribe now (society.json levels): the band below band_below people,
## else the village's tier.
func level() -> String:
	var n: int = sim.living().size()
	if n < int(S["work"]["band_below"]): return "band"
	var t: String = sim.tier_of(D.VILLAGE)
	return t if S["levels"].has(t) else "camp"

## The resource a job brings in ("" for none): gathering its res, a field food.
static func job_res(j: Dictionary) -> String:
	match j.get("type", ""):
		"gather": return str(j.get("res", ""))
		"field": return "food"
	return ""

## Hands on each choice now: gathering by resource, fields as food, crafts, rites, building.
func hands_now() -> Dictionary:
	var out := {}
	for u in sim.living():
		if u.role == "child": continue
		if u.job.get("leisure", false): continue # (pastimes are free time, not hands on a need)
		var c := choice_of(u.job)
		if c != "": out[c] = int(out.get(c, 0)) + 1
	return out

static func choice_of(j: Dictionary) -> String:
	match j.get("type", ""):
		"gather", "field": return job_res(j)
		"art": return "art"
		"ritual": return "rites"
		"build": return "build"
	return ""

## Measure the rates: what came in against the hand-seconds spent, folded into a running mean.
func measure(hands: Dictionary, dt: float) -> void:
	for c in hands:
		if c in ["art", "rites", "build"]: continue
		_hand_s[c] = float(_hand_s.get(c, 0.0)) + float(hands[c]) * dt
	_measure_t += dt
	if _measure_t < float(S["work"]["measure_every"]): return
	var k := float(S["work"]["measure_k"])
	for res in S["work"]["rates"]: # (what came in a day, all sources, against the time measured)
		var got := float(_yield.get(res, 0.0)) / _measure_t * D.DAY_LEN
		income[res] = lerpf(float(income.get(res, got)), got, k)
	_measure_t = 0.0
	for res in _hand_s:
		var hs: float = _hand_s[res]
		if hs < 30.0: continue # (too few hand-seconds to say)
		var per_day: float = float(_yield.get(res, 0.0)) / hs * float(S["work"]["job_secs"])
		rate[res] = lerpf(rate_of(res), per_day, k)
	_hand_s.clear()
	_yield.clear()

# ------------------------------------------------------------------ food's two windows
## Food the tribe eats a day now (from the meals' rule: hunger at rest, plus the walk's).
func food_demand(si: int) -> float:
	var sv: Dictionary = sim.RULES["survival"]
	var fill := float(sv["meal_fill_fire"] if sim.has_tech("fire") else sv["meal_fill"])
	var mouths := 0.0
	for u in sim.living(): mouths += float(sv["child_hunger"]) if u.role == "child" else 1.0
	var hunger := float(sv["hunger_rate"]) * D.DAY_LEN * float(sim.hz.C["seasons"]["hunger"][si])
	return mouths * hunger * float(sv["meal"]) / fill * float(S["work"]["walk_food"])

## The horizon (model §4): days from today through the next winter, at most horizon_max.
func horizon() -> Array:
	var days_per: int = sim.hz.SEASON_DAYS
	var d0: int = sim.hz.day_index()
	var end := (int(d0 / (days_per * 4)) * 4 + 4) * days_per # (the next spring's first day)
	if d0 >= end: end += days_per * 4
	var n := clampi(end - d0, 1, int(S["horizon_max"]))
	var out: Array = []
	for j in n: out.append(int((d0 + j) / days_per) % 4)
	return out

## How much a food job yields in season si, by the game's own tables (events.json seasons:
## a field's or dock's `yields`, the bushes' `berries`; a find yields in winter only if it
## says so; half the herds leave for the winter). Field/dock: the structure type; gather: the
## node kind.
func food_factor(kind: String, si: int) -> float:
	var sz: Dictionary = sim.hz.C["seasons"]
	if sz["yields"].has(kind): return float(sz["yields"][kind][si])
	if kind == "bush": return float(sz["berries"][si])
	if kind in ["deer", "carcass"]: return 0.5 if si == 3 else 1.0
	if D.FINDS.has(kind) and si == 3 and not D.FINDS[kind].get("winter", false): return 0.0
	return 1.0

## A food work's yield today: the game's live yield (weather and all: a blight stops the
## fields, a drought thins the berries) for a field, a dock or the bushes, else its season's.
func food_factor_now(kind: String) -> float:
	if sim.hz.C["seasons"]["yields"].has(kind) or kind in sim.WORKED_TYPES: return sim.hz.food_mult(kind)
	if kind == "bush": return sim.hz.berry_mult()
	return food_factor(kind, sim.hz.season_idx())

## Food security (model §10), 0..1: the look-ahead coverage (today's food hands held) from
## work.secure_from (0) to secure_to (1), a step when they are equal. Births and newcomers
## follow it: a tribe that won't carry its winter with a margin takes in no more mouths. The
## designer's knob between growth and the band's hunger trap (society.md 14.6, open #12).
## Looked at once a second.
var _cache_secure := 1.0
var _cache_secure_t := -10.0
func food_security() -> float:
	if not on: return 1.0
	if sim.time - _cache_secure_t < 1.0 and sim.time >= _cache_secure_t: return _cache_secure
	_cache_secure_t = sim.time
	var seasons := horizon()
	var none: Array = []
	for j in seasons.size(): none.append(0.0)
	var c := c_horizon(float(sim.stock["food"]), food_forecast(seasons), none, seasons)
	var lo := float(work_val("secure_from"))
	var hi := float(work_val("secure_to"))
	_cache_secure = (1.0 if c >= hi else 0.0) if hi <= lo else clampf((c - lo) / (hi - lo), 0.0, 1.0) # (a step when from == to; a ramp brings growth back but lets thin-surplus births tip unlucky bands into a hunger trap: society.md 14.6)
	return _cache_secure

## The food work a new hand would take today: a field or dock with a free place, else the
## wild food that yields most this season (food_factor), "" if nothing yields. The Steward
## sends them to it (sim.set_to_work), so the forecast and the placement agree.
func best_food_kind(si: int) -> String:
	var reach := float(sim.RULES["vice"]["steward"]["area_r"])
	var best := ""
	var bf := 0.05
	var now: bool = si == sim.hz.season_idx()
	for t in sim.WORKED_TYPES:
		var f := food_factor_now(t) if now else food_factor(t, si)
		if f > bf and sim.free_field(D.VILLAGE, reach, [t]) != null:
			bf = f
			best = t
	if best != "": return best
	for k in food_kinds_near():
		var f := food_factor_now(k) if now else food_factor(k, si)
		if f > bf:
			bf = f
			best = k
	return best

## The kinds of wild food there is to gather (once a tick: a deep forest has many nodes).
var _cache_kinds := []
var _cache_kinds_t := -1.0
func food_kinds_near() -> Array:
	if _cache_kinds_t == sim.time: return _cache_kinds
	var seen := {}
	for n in sim.nodes_of("food"):
		if n.amount >= 1.0 and not seen.has(n.kind) and (sim.knows_find(n.kind) or not D.FINDS.has(n.kind)): seen[n.kind] = true
	_cache_kinds = seen.keys()
	_cache_kinds_t = sim.time
	return _cache_kinds

## The wild food kinds worth sending a hand to today (those that yield this season).
func yielding_kinds(si: int) -> Array:
	return food_kinds_near().filter(func(k): return food_factor(k, si) > 0.05)

## The kind of food work a job is (food_factor's key): the field's type, the node's kind.
func food_kind(j: Dictionary) -> String:
	if j.get("type", "") == "field":
		var s = sim.struct_by_id(int(j.get("struct_id", -1)))
		return s.type if s else "farm_plot"
	var n = sim.node_by_id(int(j.get("node_id", -1)))
	return n.kind if n else "bush"

## Food's look-ahead coverage: the worst day's (stores spoiling + supply so far) / demand so far.
## sup and add: food by day of the horizon (today's food hands held where they are; a new hand).
func c_horizon(stores: float, sup: Array, add: Array, seasons: Array) -> float:
	var keep := 1.0 - minf(0.9, sim.spoil_rate() * D.DAY_LEN)
	var safe := float(S["spoil_free"]["food"])
	var have := 0.0
	var need := 0.0
	var worst := INF
	var st := stores
	for j in seasons.size():
		have += float(sup[j]) + float(add[j])
		need += food_demand(seasons[j])
		st = safe + maxf(0.0, st - safe) * keep if st > safe else st
		worst = minf(worst, (st + have) / maxf(1e-6, need))
	return worst

## The persistence forecast, by day of the horizon: every food hand now, held at their work,
## yielding what their work yields in each day's season against today's.
func food_forecast(seasons: Array) -> Array:
	var sup: Array = []
	for j in seasons.size(): sup.append(0.0)
	var r := rate_of("food")
	for u in sim.living():
		if u.role == "child" or u.job.get("leisure", false) or job_res(u.job) != "food": continue
		var k := food_kind(u.job)
		var f0 := food_factor_now(k)
		if f0 <= 0.05: continue
		var fs := food_factor(k, seasons[0])
		for j in seasons.size(): sup[j] += r * (1.0 if j == 0 else food_factor(k, seasons[j]) / maxf(0.05, fs)) # (today at today's yield, weather and all; later days by their season)
	return sup

# ------------------------------------------------------------------ the weights
## Every choice's weight for one more hand now (model §8). `site`: an unfinished site waits.
func weights(site: bool) -> Dictionary:
	var n: float = sim.living().size()
	var hands := hands_now()
	for c in placed: hands[c] = int(hands.get(c, 0)) + int(placed[c])
	var out := {}
	var sw: Dictionary = sim.RULES["vice"]["steward"]
	var pol: Dictionary = sw.get("policy", {}).get(sim.steward_policy, {})
	var targets: Dictionary = sim.steward_needs_targets()
	# food: now and the horizon
	var seasons := horizon()
	var sup := food_forecast(seasons) # (the hands on food now, held where they are: the persistence forecast)
	var placed_f := float(placed.get("food", 0))
	var day_eat := food_demand(seasons[0])
	var f_rate := rate_of("food") # (measured this season)
	var new_kind := best_food_kind(seasons[0]) # (where a new food hand would go: the best food work to be had today)
	var f0 := food_factor_now(new_kind) if new_kind != "" else 0.0
	var s_now := f_rate if f0 > 0.05 else 0.0 # (no delayed payoff: food work that yields nothing today gains nothing)
	var add: Array = []
	for j in seasons.size():
		var fj := 1.0 if j == 0 else food_factor(new_kind, seasons[j]) / maxf(0.05, food_factor(new_kind, seasons[0]))
		add.append(f_rate * fj)
		sup[j] += placed_f * f_rate * fj # (the hands placed this round)
	var flow: float = sup[0]
	if s_now > 0.0:
		var stores: float = sim.stock["food"]
		var c_now := (stores + flow) / maxf(1e-6, day_eat * (1.0 + float(work_val("reserve_days")))) # (today's eating, and a reserve in store: meals and births draw on the stores)
		var buf := float(work_val("food_buffer")) # (food security: births want stores in hand, model §10)
		var none: Array = []
		for j in seasons.size(): none.append(0.0)
		var ch := c_horizon(stores, sup, none, seasons) / buf
		var ch2 := c_horizon(stores, sup, add, seasons) / buf
		var imp: Dictionary = S["impact"]["food_horizon"]
		var v_h := float(S["values"]["growth"]) * float(imp.get("growth", 0.0)) + float(S["values"]["mortality"]) * float(imp.get("mortality", 0.0)) * pow(float(S["delta"]), seasons.size())
		var w := n * (value("food_now") * M.gain(c_now, s_now, day_eat) + v_h * (M.benefit(ch2) - M.benefit(ch)))
		# the granaries as the Steward's target too: a hand's share of filling them (rules.json needs.food)
		out["food"] = w * float(pol.get("food", 1.0))
	# the other stocks: covered by the stock plus the hands on them, against the target
	for res in S["work"]["stock_needs"]:
		if not targets.has(res): continue
		var t := float(targets[res])
		var have: float = float(sim.stock.get(res, 0.0)) + float(hands.get(res, 0)) * rate_of(res)
		var need: String = S["work"]["stock_needs"][res]
		out[res] = value(need) * n * M.gain(have / maxf(1e-6, t), rate_of(res), t) * float(pol.get(res, 1.0))
	# needs met by hands: crafts (comfort), rites (spirit), building (shelter)
	var lv: Dictionary = S["levels"][level()]["hands"]
	for c in S["work"]["hand_needs"]:
		if c == "build" and not site: continue
		var need: String = S["work"]["hand_needs"][c]
		var d := float(lv.get(need, 0.0)) * n
		if d <= 0.0: continue
		var on_it := maxf(float(avg_hands.get(c, 0.0)), float(hands.get(c, 0) - int(placed.get(c, 0)))) + float(placed.get(c, 0))
		out[c] = value(need) * n * M.gain(on_it / d, 1.0, d) * float(pol.get(c, 1.0))
	return out

# ------------------------------------------------------------------ one rule for everyone
## The choice a person's trade works at ("" for a trade with no work of its own: herder,
## warrior, scout), from careers.json `work`.
func trade_choice(u: E.Unit) -> String:
	if u.career == "": return ""
	var w: Dictionary = sim.careers.def(u.career).get("work", {})
	if w.has("gather"): return str(w["gather"])
	if w.has("work_at"): return "food"
	if w.get("ritual", false): return "rites"
	if w.get("art", false): return "art"
	if w.get("build", false): return "build"
	return ""

## How productive u is at a choice: their skill on the one curve, and their trade's edge at
## their own trade (careers.json work_mult).
func productivity(u: E.Unit, choice: String) -> float:
	var skill: String = S["work"]["skills"].get(choice, "forage")
	var p: float = sim.skill_mult(u.lv(skill))
	if choice == trade_choice(u) and sim.careers.on: p *= float(sim.careers.C["work_mult"])
	return p

## The one rule (model §8, the invisible hand): every person works where their hand is worth
## most, the work's price (its weight: what one more hand gains the tribe) times their own
## productivity at it. A good in plenty is worth nothing, so even its masters turn to what is
## wanted; a specialist keeps to their trade while it pays them at least as well as anything
## else (comparative advantage). Returns [choice, value]; "" when nothing is worth a hand.
func best_for(u: E.Unit, w: Dictionary) -> Array:
	var best := ""
	var bw := float(S["work"]["min_weight"])
	for c in w:
		if c == "art" and not sim.folk.can_art(u): continue
		var v := float(w[c]) * productivity(u, c)
		if v > bw:
			bw = v
			best = c
	return [best, bw]

## The Steward's choice for u by the one rule ("" when nothing is worth a hand: rest),
## counted before the next hand is placed. `site`: an unfinished site waits for builders.
func pick(u: E.Unit, site: bool) -> String:
	var w := weights(site)
	last = w
	var best: String = best_for(u, w)[0]
	if best != "": placed[best] = int(placed.get(best, 0)) + 1
	return best

## Send u to the work their hand is worth most at (the one rule), or, if it can't be done (no
## field place, nothing of it within a safe walk), the next best by the same rule, counted
## before the next hand; false when nothing worth a hand can be done (rest). The Steward's and
## the self-placing idle's verb. `unbuilt`: the site waiting for builders, or null.
func place(u: E.Unit, unbuilt) -> bool:
	var w := weights(unbuilt != null)
	last = w
	while true:
		var choice: String = best_for(u, w)[0]
		if choice == "": return false
		var ok := false
		if choice == trade_choice(u) and sim.careers.on: ok = sim.careers.go_work(u, true) # (their own trade, by its own verb)
		if not ok: ok = sim.set_to_work(u, "lore" if choice == "rites" else choice, unbuilt, false)
		if ok:
			placed[choice] = int(placed.get(choice, 0)) + 1
			return true
		w.erase(choice) # (can't be done now: the next best)
	return false

## Whether u, a person with a trade, should go to it by themselves now: only when the one rule
## says their trade is their best work (careers.self_work).
func trade_pays(u: E.Unit) -> bool:
	var tc := trade_choice(u)
	if tc == "": return false
	return best_for(u, weights(sim.site_for(u) != null))[0] == tc

## A new round of the Steward's placements (sim._update_vice): what was placed is now in the
## jobs, so the round's count starts again; the rates are measured on the way.
func round_start(dt: float) -> void:
	placed.clear()
	var h := hands_now()
	measure(h, dt)
	var k := clampf(dt / float(S["work"]["avg_secs"]), 0.0, 1.0)
	for c in S["work"]["hand_needs"]: avg_hands[c] = lerpf(float(avg_hands.get(c, 0.0)), float(h.get(c, 0)), k)

var next_try := {} # person id -> when they next look for work by themselves

## With no Steward to place them, an idle grown-up chooses their own work by the one rule,
## after self_secs of idleness, by day near home (the Steward is quicker and counts each
## placement before the next; without one the tribe still works, a little less well).
## Returns true if they set off (sim.unit_idle).
func self_work(u: E.Unit) -> bool:
	if u.role != "" or u.sick > 0.0 or sim.rest_time() or not D.same_side(u.pos, u.home): return false
	var st = sim.unit_by_id(sim.vice.get("steward", -1))
	if st != null and not st.dead: return false # (the Steward places the idle)
	if u.pos.distance_to(u.home) > float(sim.RULES["vice"]["steward_reach"]): return false
	var t := float(next_try.get(u.id, -1.0))
	if t < 0.0:
		next_try[u.id] = sim.time + float(S["work"]["self_secs"])
		return false
	if sim.time < t: return false
	next_try.erase(u.id)
	if place(u, sim.site_for(u)): return true
	next_try[u.id] = sim.time + float(S["work"]["self_secs"]) * 4.0 # (nothing worth a hand can be done: rest, and look again later)
	return false

## For a game master: the last round's weights, the measured rates, the level.
func summary() -> Dictionary:
	return {"on": on, "level": level(), "weights": last.duplicate(), "rates": rate.duplicate(), "income": income.duplicate(), "horizon_days": horizon().size()}
