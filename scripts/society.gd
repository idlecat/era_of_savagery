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
var GOODS: Dictionary = S["goods"].duplicate() # good id -> its config (the _doc key left out)

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
	GOODS.erase("_doc")

## A work knob (config/society.json work) for the challenge level now: work.by_challenge
## [hz.level] overrides the defaults, as director.json's levels do (make_it_fun.md G: the
## designer's knobs, measured against the G1 bands).
func work_val(key: String):
	var by: Dictionary = S["work"].get("by_challenge", {}).get(sim.hz.level, {})
	return by[key] if by.has(key) else S["work"][key]

## How well u knows the method a kind of work needs (model §3: `known`): 1 if they know it
## (evo.knows), else work.known while they learn; 1 for work with no method listed.
func known_mult(u: E.Unit, work: String) -> float:
	if not on: return 1.0
	var m: Dictionary = S["work"]["methods"]
	if not m.has(work) or work == "_doc" or not sim.has_tech(str(m[work])): return 1.0
	return 1.0 if sim.evo.knows(u, str(m[work])) else float(S["work"]["known"])

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
## else the village's tier. The Steward's round asks for it for every hand placed, so it is
## kept for the tick (a town's tier_of() walks the village's buildings).
var _cache_level := ""
var _cache_level_t := -1.0
func level() -> String:
	if sim.in_tick() and _cache_level_t == sim.time: return _cache_level
	var n: int = sim.living().size()
	var lv := "band"
	if n >= int(S["work"]["band_below"]):
		var t: String = sim.tier_of(D.VILLAGE)
		lv = t if S["levels"].has(t) else "camp"
	_cache_level = lv
	_cache_level_t = sim.time if sim.in_tick() else -1.0
	return lv

## The resource a job brings in ("" for none): gathering its res, a field food.
static func job_res(j: Dictionary) -> String:
	match j.get("type", ""):
		"gather": return str(j.get("res", ""))
		"field": return "food"
	return ""

## Hands on each choice now: gathering by resource, fields as food, crafts, rites, building.
## Asked for a few times a tick, and it must be fresh each time: the Steward hands out work
## as it goes, so who is at what changes within the tick.
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
		"craft": return str(j.get("good", ""))
		"heal": return "heal"
		"keep_order": return "order"
		"train": return "train"
		"art": return "art"
		"ritual": return "rites"
		"build": return "build"
	return ""

## Measure the rates: what came in against the hand-seconds spent, folded into a running mean.
func measure(hands: Dictionary, dt: float) -> void:
	for c in hands:
		if c in ["art", "rites", "build", "food"]: continue
		_hand_s[c] = float(_hand_s.get(c, 0.0)) + float(hands[c]) * dt
	# food's hand-seconds weighed by what each hand's work yields now (a field in winter: 0), so the
	# rate is a hand's day at a season's yield of 1: winter can't teach that food work is worthless
	for u in sim.living():
		if u.role == "child" or u.job.get("leisure", false) or job_res(u.job) != "food": continue
		_hand_s["food"] = float(_hand_s.get("food", 0.0)) + food_factor_now(food_kind(u.job)) * dt
	_measure_t += dt
	if _measure_t < float(S["work"]["measure_every"]): return
	var k := float(S["work"]["measure_k"])
	for res in S["work"]["rates"]: # (what came in a day, all sources, against the time measured)
		var got := float(_yield.get(res, 0.0)) / _measure_t * D.DAY_LEN
		income[res] = lerpf(float(income.get(res, got)), got, k)
	_measure_t = 0.0
	var prior: Dictionary = S["work"]["rates"]
	for res in prior:
		var hs := float(_hand_s.get(res, 0.0))
		var guess := float(prior[res])
		if hs < 30.0: # (too few hand-seconds to say: drift back toward the guess, so a rate nobody measures can't stay at nothing)
			if rate.has(res): rate[res] = lerpf(float(rate[res]), guess, k * 0.5)
			continue
		var per_day: float = float(_yield.get(res, 0.0)) / hs * float(S["work"]["job_secs"])
		rate[res] = maxf(guess * float(S["work"]["rate_floor"]), lerpf(rate_of(res), per_day, k)) # (and never below a share of it: a bad season can't shut a kind of work for good)
	_hand_s.clear()
	_yield.clear()

# ------------------------------------------------------------------ food's two windows
## Food the tribe eats a day now (from the meals' rule: hunger at rest, plus the walk's).
var _cache_demand := {} # season -> what the tribe eats a day in it, this tick
var _cache_demand_t := -1.0
func food_demand(si: int) -> float:
	if sim.in_tick() and _cache_demand_t == sim.time and _cache_demand.has(si): return _cache_demand[si]
	if _cache_demand_t != sim.time:
		_cache_demand = {}
		_cache_demand_t = sim.time if sim.in_tick() else -1.0
	var sv: Dictionary = sim.RULES["survival"]
	var fill := float(sv["meal_fill_fire"] if sim.has_tech("fire") else sv["meal_fill"])
	var mouths := 0.0
	for u in sim.living(): mouths += float(sv["child_hunger"]) if u.role == "child" else 1.0
	var hunger := float(sv["hunger_rate"]) * D.DAY_LEN * float(sim.hz.C["seasons"]["hunger"][si])
	var d := mouths * hunger * float(sv["meal"]) / fill * float(S["work"]["walk_food"])
	if sim.in_tick(): _cache_demand[si] = d
	return d

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
var _cache_factor := {} # kind -> [the season's factor] (the game's own tables: fixed while it runs)
func food_factor(kind: String, si: int) -> float:
	var arr: Array = _cache_factor.get(kind, [])
	if arr.is_empty():
		arr = [null, null, null, null]
		_cache_factor[kind] = arr
	if arr[si] == null: arr[si] = _food_factor(kind, si)
	return float(arr[si])
func _food_factor(kind: String, si: int) -> float:
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
	var r := rate_of("food") # (a hand's day at a season's yield of 1)
	for u in sim.living():
		if u.role == "child" or u.job.get("leisure", false) or job_res(u.job) != "food": continue
		var k := food_kind(u.job)
		var f0 := food_factor_now(k)
		if f0 <= 0.05: continue
		for j in seasons.size(): sup[j] += r * (f0 if j == 0 else food_factor(k, seasons[j])) # (today at today's yield, weather and all; later days by their season)
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
	var f_rate := rate_of("food") # (a hand's day at a season's yield of 1, measured)
	var new_kind := best_food_kind(seasons[0]) # (where a new food hand would go: the best food work to be had today)
	var f0 := food_factor_now(new_kind) if new_kind != "" else 0.0
	var s_now := f_rate * f0 if f0 > 0.05 else 0.0 # (no delayed payoff: food work that yields nothing today gains nothing)
	var add: Array = []
	for j in seasons.size():
		var fj := f0 if j == 0 else (food_factor(new_kind, seasons[j]) if new_kind != "" else 0.0)
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
	# goods that wear: what one more maker saves (after the others: it reads their weights)
	for g in GOODS:
		var gw := good_weight(g, out, hands)
		if gw > 0.0: out[g] = gw
	# order: disputes and coordination over the keepers' span (the Steward keeps order too)
	var od := order_demand_hands()
	if od > 0.0:
		var keepers := float(hands.get("order", 0)) + _steward_keeps()
		out["order"] = value("order") * n * M.gain(keepers / od, 1.0, od)
	# safety: the hands to be ready for the band a clan could send (the trained stand by)
	var sc := safety_coverage()
	if sc < 1.0: # (training raises the tribe's standing strength: worth it only while it falls short of the band to be ready for)
		var trainees := float(hands.get("train", 0))
		var g := float(S["work"]["train"]["gain"])
		out["train"] = value("safety") * n * M.gain(sc * (1.0 + g * trainees), sc * g, 1.0)
	# health, a service: the sick over the patients a healer tends
	var sick := 0
	for u in sim.living():
		if u.sick > 0.0: sick += 1
	if sick > 0:
		var hd := float(sick) / float(S["work"]["heal"]["patients"])
		out["heal"] = value("health") * n * M.gain(float(hands.get("heal", 0)) / hd, 1.0, hd)
	# comfort: the daily goods in use against what the level wants (crafts make them)
	if sim.folk.mood > 0.0:
		var cw := comfort_want()
		var cm: Dictionary = S["comfort"]
		var dcm := float(S["work"]["job_secs"]) / float(cm["art_secs"]) * float(cm["per_piece"]) / maxf(1.0, cw)
		out["art"] = value("comfort") * n * M.gain(comfort_coverage(), dcm, 1.0)
	# needs met by hands: rites (spirit), building (shelter)
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
	if w.has("craft"): return str(w["craft"])
	if w.get("heal", false): return "heal"
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
		if c == "heal" and u.lv("lore") < int(sim.hz.C["sickness"]["recover"]["healer_lore"]): continue # (only those who know the healing)
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
	# daily goods are used up: wear of what is wanted, a day
	var g := str(S["comfort"]["good"])
	if float(sim.stock.get(g, 0.0)) > 0.0:
		sim.stock[g] = maxf(0.0, float(sim.stock[g]) - comfort_want() * float(S["comfort"]["wear"]) * dt / D.DAY_LEN)

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

# ------------------------------------------------------------------ goods that wear (model §3.1)
## Whether the tribe can make `good` now (its `when`).
func can_make(good: String) -> bool:
	return GOODS.has(good) and sim.story.holds(GOODS[good].get("when", {}))

## How many of `good` the tribe wants: per_worker for each grown-up. The count is kept for
## the tick: the Steward's round asks for it for every good and every hand placed.
var _cache_grown := 0
var _cache_grown_t := -1.0
func _grown_ups() -> int:
	if sim.in_tick() and _cache_grown_t == sim.time: return _cache_grown
	var n := 0
	for u in sim.living():
		if u.role != "child": n += 1
	_cache_grown = n
	_cache_grown_t = sim.time if sim.in_tick() else -1.0
	return n
func good_target(good: String) -> float:
	var n: float = float(sim.living().size()) if GOODS[good].get("for", "") == "all" else float(_grown_ups()) # (a good for all is wanted by children too)
	return maxf(1.0, n * float(GOODS[good]["per_worker"]))

## A good's coverage: what is in store against what the tribe wants.
func coverage_of(good: String) -> float:
	return clampf(float(sim.stock.get(good, 0.0)) / good_target(good), 0.0, 1.0)

## How much faster the goods make the work on `res` go: 1 + (max - 1) x B(coverage), for each
## good that `uses` it (tools: gathering, the fields). 1 for a good the tribe can't make yet.
func tool_mult(res: String) -> float:
	var m := 1.0
	for g in GOODS:
		if res in GOODS[g].get("uses", []) and can_make(g): m *= 1.0 + (float(GOODS[g]["max"]) - 1.0) * M.benefit(coverage_of(g))
	return m

## How hard the cold bites, by the goods worn against it (cloth): 1 - (1 - cold) x B(coverage).
func cold_mult() -> float:
	if not on: return 1.0
	var m := 1.0
	for g in GOODS:
		if GOODS[g].has("cold") and can_make(g): m *= 1.0 - (1.0 - float(GOODS[g]["cold"])) * M.benefit(coverage_of(g))
	return m

## Goods wear with use: each hand at the work a good serves wears `wear` of it a day.
var _wear_t := 0.0
var _round_t := 0.0
func tick(dt: float) -> void:
	if not on: return
	_round_t += dt # (the round of placements, with or without a Steward: what was placed is in the jobs now, and the rates are measured)
	if _round_t >= float(sim.RULES["vice"]["every"]):
		round_start(_round_t)
		_round_t = 0.0
	_wear_t += dt
	if _wear_t < 1.0: return
	var step := _wear_t
	_wear_t = 0.0
	var h := hands_now()
	for g in GOODS:
		if float(sim.stock.get(g, 0.0)) <= 0.0: continue
		var users := 0
		if GOODS[g].get("for", "") == "all": users = sim.living().size() # (worn by everyone)
		for res in GOODS[g].get("uses", []): users += int(h.get(res, 0))
		sim.stock[g] = maxf(0.0, float(sim.stock[g]) - users * float(GOODS[g]["wear"]) * step / D.DAY_LEN)

## The price of making `good` (the one rule): what one more maker's day saves, the rise in the
## multiplier times the hands on the work it serves, each valued at the best use of a hand
## (the greatest of the other weights), every day the goods last (1 / wear): a tool is worth
## the time it gives back over its life. With hands to spare (nothing else weighs), nothing.
func good_weight(good: String, w: Dictionary, hands: Dictionary) -> float:
	if not can_make(good) or not sim.can_afford(GOODS[good]["cost"]): return 0.0
	var gd: Dictionary = GOODS[good]
	var c := coverage_of(good)
	var made := float(S["work"]["job_secs"]) / float(gd["work"]) # (a full-time maker's day)
	var dc := made / good_target(good)
	if gd.has("cold"): # (worn against the cold: warmth's value, the more so with a winter ahead)
		var winter_ahead := 1.0 if 3 in horizon() else 0.5
		return value("warmth") * float(sim.living().size()) * (M.benefit(c + dc) - M.benefit(c)) * winter_ahead
	var dm := (float(gd["max"]) - 1.0) * (M.benefit(c + dc) - M.benefit(c))
	var best := 0.0
	for k in w: best = maxf(best, float(w[k]))
	var users := 0.0
	for res in gd.get("uses", []): users += float(hands.get(res, 0))
	var life := 1.0 / maxf(0.01, float(gd["wear"])) # (a good saves time every day it lasts: its worth is the stream, days of use until worn out)
	return dm * users * best * life

## Send u to make `good` at home, indoors (their own hut, else the nearest of ours). False if
## it can't be made now (unknown, or the stores can't pay its cost).
func assign_craft(u: E.Unit, good: String) -> bool:
	if not can_make(good) or not sim.can_afford(GOODS[good]["cost"]): return false
	var hut = sim.own_hut(u)
	if hut == null: return false
	sim.set_job(u, {"type": "craft", "good": good, "struct_id": hut.id, "t": 0.0})
	sim.give_shift(u)
	return true

## The craft job: walk home, go inside, work the piece; when it is done, pay its cost and
## the good is in store; then the next piece, until the stint ends.
func do_craft(u: E.Unit, j: Dictionary, dt: float) -> void:
	var hut = sim.struct_by_id(int(j.get("struct_id", -1)))
	var gd: Dictionary = GOODS.get(str(j.get("good", "")), {})
	if hut == null or not hut.built or gd.is_empty():
		u.inside = -1
		sim.set_job(u, {})
		return
	if u.inside < 0 and not sim.approach(u, hut.pos, 10, dt):
		u.act = "Walking to work"
		return
	u.inside = hut.id
	u.pos = hut.pos
	u.act = str(gd["act"])
	u.doing = str(gd["doing"])
	j["t"] = float(j.get("t", 0.0)) + dt * sim.work_mul(u) * sim.skill_mult(u.lv(str(gd["skill"]))) * known_mult(u, str(j.get("good", "")))
	if float(j["t"]) < float(gd["work"]): return
	j["t"] = 0.0
	if not sim.spend(gd["cost"]):
		u.inside = -1
		sim.set_job(u, {}) # (nothing left to make it from)
		return
	var g: String = str(j["good"])
	sim.stock[g] = float(sim.stock.get(g, 0.0)) + 1.0
	note_yield(g, 1.0)
	sim.gain_xp(u, str(gd["skill"]), 1.0)
	if float(j.get("shift_end", INF)) <= sim.time:
		u.inside = -1
		sim.set_job(u, {}) # (the stint is over: a new look at what is needed)

# ------------------------------------------------------------------ health, a service (model §4)
## Send u to tend the sick: to the sick person nearest home that no healer tends yet. False
## when nobody is sick.
func assign_heal(u: E.Unit) -> bool:
	var best = null
	for o in sim.living():
		if o.sick > 0.0 and o != u and sim.time >= o.tended_t and (best == null or o.pos.distance_to(u.home) < best.pos.distance_to(u.home)): best = o
	if best == null: return false
	sim.set_job(u, {"type": "heal", "patient_id": best.id, "until": sim.time + float(S["work"]["heal"]["stint"])})
	return true

## The heal job: go to the patient, and tend them and the sick round them (up to `patients`,
## within the healer's radius) until the stint ends or nobody near is sick.
func do_heal(u: E.Unit, j: Dictionary, dt: float) -> void:
	var p = sim.unit_by_id(int(j.get("patient_id", -1)))
	if p == null or p.dead or p.sick <= 0.0 or sim.time >= float(j.get("until", 0.0)):
		sim.set_job(u, {}) # (well again, gone, or the stint is over: a new look at what is needed)
		return
	var rr := float(sim.hz.C["sickness"]["recover"]["healer_radius"])
	if not sim.approach(u, p.pos, rr * 0.4, dt):
		u.act = "Walking to work"
		return
	u.act = str(S["work"]["heal"]["act"])
	u.doing = "heal"
	var n := 0
	for o in sim.units_near(u.pos, rr):
		if o.dead or o.sick <= 0.0 or n >= int(S["work"]["heal"]["patients"]): continue
		o.tended_t = sim.time + 1.0
		n += 1
	sim.gain_xp(u, "lore", dt * 0.05)

# ------------------------------------------------------------------ safety (model §4.1)
## Safety's coverage, a stock against a pressure: the standing strength of everyone able to
## fight (threat.gd's force: their health and blows, weapons and mastery folded in) against
## the force wanted for the biggest band a clan that may raid us could send now
## (rivals.expected_band, threat.need). 1 with no such clan. Once a second.
var _cache_safety := 1.0
var _cache_safety_t := -10.0
func safety_coverage() -> float:
	if sim.time - _cache_safety_t < 1.0 and sim.time >= _cache_safety_t: return _cache_safety
	_cache_safety_t = sim.time
	var band: Array = sim.rivals.expected_band()
	if band.is_empty():
		_cache_safety = 1.0
		return 1.0
	var able: Array = sim.living().filter(func(u): return sim.threat.able(u) or u.job.get("type", "") == "train")
	var want: float = sim.threat.need(band)
	_cache_safety = 1.0 if want <= 0.0 else clampf(sim.threat.force(able, band) / want, 0.0, 1.0)
	return _cache_safety

## Safety's demand in hands, for a game master: the squad threat.gd would send against that band.
func safety_need_hands() -> float:
	var band: Array = sim.rivals.expected_band()
	return 0.0 if band.is_empty() else float(sim.threat.squad(band, sim.living().filter(func(u): return sim.threat.able(u))).size())

## Send u to train for war: sparring at the weapon rack (else by the fire) for a stint.
func assign_train(u: E.Unit) -> bool:
	var rack = null
	for s in sim.built_of("weapon_rack"):
		if rack == null or s.pos.distance_to(u.home) < rack.pos.distance_to(u.home): rack = s
	var at: Vector2 = rack.pos if rack else u.home
	if rack == null:
		var fire = sim.nearest_serving("gather", u.home)
		if fire: at = fire.pos
	sim.set_job(u, {"type": "train", "at": at + Vector2(randf_range(-30, 30), randf_range(20, 40)), "until": sim.time + float(S["work"]["train"]["stint"])})
	return true

func do_train(u: E.Unit, j: Dictionary, dt: float) -> void:
	if sim.time >= float(j.get("until", 0.0)):
		sim.set_job(u, {})
		return
	if not sim.approach(u, j["at"], 8, dt):
		u.act = "Walking to work"
		return
	u.act = str(S["work"]["train"]["act"])
	u.doing = "spar"
	sim.arms.practice(u, str(sim.arms.wielded(u).get("id", "")), float(S["work"]["train"]["arms_xp"]) * dt)
	sim.gain_xp(u, "combat", dt * 0.05)

# ------------------------------------------------------------------ order (model §6)
## Whether the tribe has an institution of order (the Council Ring, the Tribal Code).
func has_institutions() -> bool:
	for c in S["order"]["institutions"]:
		if sim.story.holds(c): return true
	return false

## 1 if a Steward stands (they keep order as well as placing hands), else 0.
func _steward_keeps() -> float:
	var st = sim.unit_by_id(sim.vice.get("steward", -1))
	return 1.0 if st != null and not st.dead else 0.0

## Order's demand in keepers' hands now (model §6): coordination from the first Steward on and
## disputes past the face-to-face limit, over a keeper's span (an informal keeper's shrinks
## past n1, an institution's doesn't).
func order_demand_hands() -> float:
	var o: Dictionary = S["order"]
	var n: float = sim.living().size()
	return M.order_demand(n, float(o["a_c"]), float(o["a_d"]), float(o["n0"]), float(o["k"]), _steward_keeps() > 0.0) / M.order_span(n, float(o["n1"]), has_institutions(), float(o["code_mult"]))

## Order's coverage: the keepers (the Steward, those at keep_order) against its demand.
var _cache_order := 1.0
var _cache_order_t := -10.0
func order_coverage() -> float:
	if sim.time - _cache_order_t < 1.0 and sim.time >= _cache_order_t: return _cache_order
	_cache_order_t = sim.time
	var d := order_demand_hands()
	var k := _steward_keeps()
	for u in sim.living():
		if u.job.get("type", "") == "keep_order": k += 1.0
	_cache_order = 1.0 if d <= 0.0 else clampf(k / d, 0.0, 1.0)
	return _cache_order

## How fast work goes for order's sake (the labour channel, model §5): disputes nobody settles
## waste `waste` of the work at worst, 1 - waste x (1 - B(coverage)).
func order_mult() -> float:
	if not on: return 1.0
	return 1.0 - float(S["order"]["waste"]) * (1.0 - M.benefit(order_coverage()))

## Send u to keep the peace by the fire for a stint.
func assign_keep_order(u: E.Unit) -> bool:
	var fire = sim.nearest_serving("gather", u.home)
	var at: Vector2 = fire.pos if fire else u.home
	sim.set_job(u, {"type": "keep_order", "at": at + Vector2(randf_range(-30, 30), randf_range(20, 40)), "until": sim.time + float(S["order"]["stint"])})
	return true

func do_keep_order(u: E.Unit, j: Dictionary, dt: float) -> void:
	if sim.time >= float(j.get("until", 0.0)):
		sim.set_job(u, {})
		return
	if not sim.approach(u, j["at"], 8, dt):
		u.act = "Walking to work"
		return
	u.act = str(S["order"]["act"])
	u.doing = "council"
	sim.gain_xp(u, "lore", dt * 0.03)
	sim.evo.practice(u, "lead", dt * 0.2)

# ------------------------------------------------------------------ comfort and the standard (model §10)
## The daily goods the tribe wants in use now: the level's wants per head.
func comfort_want() -> float:
	var cm: Dictionary = S["comfort"]
	return float(sim.living().size()) * float(cm["wants"].get(level(), cm["wants"]["camp"]))

## Comfort's coverage: the goods in store against what is wanted.
func comfort_coverage() -> float:
	var w := comfort_want()
	return 1.0 if w <= 0.0 else clampf(float(sim.stock.get(str(S["comfort"]["good"]), 0.0)) / w, 0.0, 1.0)

## Spirit's coverage: the hands at the rites (averaged) against the level's hands per head.
func spirit_coverage() -> float:
	var d := float(S["levels"][level()]["hands"].get("spirit", 0.0)) * float(sim.living().size())
	return 1.0 if d <= 0.0 else clampf(float(avg_hands.get("rites", 0.0)) / d, 0.0, 1.0)

## The standard of living, 0..1 (model §10): the mean benefit of the needs society.json
## comfort.standard names (food today, beds, comfort, spirit, health, order). Once a second.
var _cache_standard := 1.0
var _cache_standard_t := -10.0
func standard() -> float:
	if sim.time - _cache_standard_t < 1.0 and sim.time >= _cache_standard_t: return _cache_standard
	_cache_standard_t = sim.time
	var n: float = maxf(1.0, sim.living().size())
	var sick := 0.0
	for u in sim.living():
		if u.sick > 0.0: sick += 1.0
	var c := {"food": clampf(float(sim.stock["food"]) / maxf(1.0, food_demand(sim.hz.season_idx())), 0.0, 1.0),
		"shelter": clampf(float(sim.pop_cap()) / n, 0.0, 1.0), "comfort": comfort_coverage(), "spirit": spirit_coverage(),
		"health": 1.0 - sick / n, "order": order_coverage()}
	var t := 0.0
	var k := 0
	for need in S["comfort"]["standard"]:
		t += M.benefit(float(c.get(need, 1.0)))
		k += 1
	_cache_standard = t / maxf(1.0, k)
	return _cache_standard

## The standard's sway on the tribe's mood (folk.mood_target), with the society model on.
func mood_term() -> float:
	var cm: Dictionary = S["comfort"]
	return float(cm["mood"]) * (standard() - float(cm["ref"])) * 2.0

# ------------------------------------------------------------------ the building plan (step 10)
## The price of raising what a plan entry builds (improve.gd sorts what it wants by it): the
## value of the need the building serves times how short that need is, 1 - B(coverage).
func build_price(r: Dictionary) -> float:
	var b: Dictionary = S["build"]
	if r.has("road"): return float(S["values"]["labour"]) * float(S["levels"][level()].get("walk", 0.3)) # (the walk: labour's value times the share of the work spent walking)
	var t: String = str(r.get("structure", r.get("upgrade", "")))
	var sd: Dictionary = D.STRUCTURES.get(t, {})
	var n: float = maxf(1.0, sim.living().size())
	if int(sd.get("cap", 0)) > 0 and int(sd.get("store", 0)) == 0:
		return value("shelter") * (1.0 - M.benefit(float(sim.pop_cap()) / (n * float(b["shelter_margin"]))))
	if int(sd.get("store", 0)) > 0:
		var want := food_demand(3) * float(b["winter_days"])
		return (value("food_now") * 0.5) * (1.0 - M.benefit(float(sim.food_cap()) / maxf(1.0, want)))
	if sd.has("serves") and sd["serves"].has("warmth") and t != "council_ring":
		var fires := 0.0
		for st in sim.serving("warmth"): fires += 1.0
		return value("warmth") * (1.0 - M.benefit(fires * float(b["per_fire"]) / n))
	if sd.has("worked"):
		var free = sim.free_field(D.VILLAGE, float(sim.RULES["vice"]["steward"]["area_r"]), [t])
		return 0.0 if free != null else value("food_now") * (1.0 - M.benefit(clampf(float(sim.stock["food"]) / maxf(1.0, food_demand(sim.hz.season_idx()) * 3.0), 0.0, 1.0)))
	if t == "council_ring": return value("order") * (1.0 - M.benefit(order_coverage()))
	if sd.has("ritual_mult") or sd.has("lore"): return value("spirit") * (1.0 - M.benefit(spirit_coverage()))
	if sd.has("ring") or sd.has("inside_def") or sd.get("lookout", false) or t == "weapon_rack": return value("safety") * (1.0 - M.benefit(safety_coverage()))
	return float(b["other"])

# ------------------------------------------------------------------ wealth (model §10)
## The price of one unit of res: the trade's (rules.json folk.trade.value), else wealth.prices.
func price_of(res: String) -> float:
	var tv: Dictionary = sim.RULES["folk"]["trade"]["value"]
	if tv.has(res): return float(tv[res])
	return float(S["wealth"]["prices"].get(res, 1.0))

## What the tribe has: stores and goods at their prices, buildings at their cost, treasures, and
## knowledge (each known tech's cost times the share who know it).
func wealth() -> float:
	var W: Dictionary = S["wealth"]
	var v := 0.0
	for r in sim.stock: v += float(sim.stock[r]) * price_of(r)
	for s in sim.structures:
		if s.built and sim.ours(s):
			var sd: Dictionary = D.STRUCTURES.get(s.type, {})
			v += float(sd.get("wood", 0)) * float(W["building"]["wood"]) + float(sd.get("stone", 0)) * float(W["building"]["stone"])
	v += sim.folk.treasures.size() * float(W["treasure"])
	var n: float = maxf(1.0, sim.living().size())
	for t in D.TECHS:
		if sim.has_tech(t["id"]): v += float(t["cost"]) * float(W["knowledge"]) * minf(1.0, sim.evo.keepers(t["id"]).size() / n)
	return v

## What comes in a day per head, at the same prices (the measured income).
func output_per_head() -> float:
	var v := 0.0
	for r in income: v += float(income[r]) * price_of(r)
	return v / maxf(1.0, sim.living().size())

## For a game master: the last round's weights, the measured rates, the level.
func summary() -> Dictionary:
	return {"on": on, "level": level(), "weights": last.duplicate(), "rates": rate.duplicate(), "income": income.duplicate(), "horizon_days": horizon().size(),
		"standard": standard(), "wealth": wealth(), "output_per_head": output_per_head(),
		"coverage": {"comfort": comfort_coverage(), "spirit": spirit_coverage(), "order": order_coverage(), "safety": safety_coverage(), "tools": coverage_of("tools"), "cloth": coverage_of("cloth")},
		"food_security": food_security()}
