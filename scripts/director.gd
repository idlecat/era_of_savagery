## The director: paces the hardships so the tribe gets a breath after a blow, and a hand
## when it is going under. Owned by the simulation as `sim.director`; all numbers are in
## config/director.json.
##
## Tension: everything that goes wrong adds its weight (note()), and it eases by `decay`
## a day. A rolled hardship asks allow(kind) before it starts: it may if tension plus its
## weight stays within the cap of the challenge level (in distress: the mercy cap). Put
## off, the rule retries later (retry()) or skips its roll. Hardships that aren't rolled
## (the seasons' floods, scripted events, deaths) always happen, and count.
## Distress (food nearly gone, deaths, despair) lowers the cap, and now and then a gift
## from mercy.gifts helps (story actions, with conditions).
## This is where an LLM game master would sit: summary() reads it, note()/allow() are the
## same gates for anything it sends.
extends RefCounted

const D = preload("res://scripts/data.gd")

var C: Dictionary = preload("res://scripts/config.gd").load_cfg("director")

var sim
var on := true # (tests switch it off; it also rests when the challenges are off)
var tension := 0.0
var last_note := {} # kind -> time (the same happening counts once per same_secs)
var deaths: Array = [] # times of recent deaths
var distress := false
var mercy_until := -1.0
var mercy_ready := 0.0 # no gift before this time
var held: Array = [] # [{kind, t}] what was put off lately (for summary)
var check_t := 0.0

func _init(s) -> void:
	sim = s
	sim.happened.connect(func(id): note(id))
	sim.crisis_started.connect(func(_c): note("crisis"))

func active() -> bool: return on and sim.hz.on()

func _level() -> Dictionary:
	return C.get("levels", {}).get(sim.hz.level, C.get("levels", {}).get("normal", {"cap": 3.0, "decay": 1.6}))

## How much trouble the tribe can take now.
func cap() -> float:
	if mercy(): return float(C.get("mercy", {}).get("cap", 0.5))
	var lv := _level()
	return float(lv.get("cap", 3.0)) + float(lv.get("cap_per_pop", 0.0)) * maxf(0.0, sim.living().size() - float(lv.get("cap_from_pop", 0.0))) # (a town can take more at once than a camp)

func weight(kind: String) -> float: return float(C.get("weights", {}).get(kind, 0.0))

## In distress or under mercy's breath (the mercy cap holds then).
func mercy() -> bool: return distress or sim.time < mercy_until

## May hardship `kind` start now? (Kinds without a weight always may.) In a calm land
## (no tension at all) even a hardship heavier than the cap may come, but never while
## the tribe is in distress: then the mercy cap holds.
func allow(kind: String) -> bool:
	if not active() or weight(kind) <= 0.0: return true
	if stacking(kind):
		held.append({"kind": kind, "t": sim.time})
		if held.size() > 20: held.pop_front()
		return false
	if sim.hz.signature(kind) and not mercy(): return true # (the director chose this winter: its own hardship comes, unless the tribe is broken)
	if tension + weight(kind) <= cap() or (tension <= 0.0 and not mercy()): return true
	held.append({"kind": kind, "t": sim.time})
	if held.size() > 20: held.pop_front()
	return false

## Whether `kind` would stack on a trouble already under way (director.json hold_while):
## a sickness wave or a famine holds back a raid, so one bad day can't erase ten.
func stacking(kind: String) -> bool:
	var hw: Dictionary = C.get("hold_while", {}).get(kind, {})
	if hw.is_empty(): return false
	if hw.has("sick") and sim.living().filter(func(u): return u.sick > 0).size() >= int(hw["sick"]): return true
	return hw.has("hungry_hours") and sim.hz.hungry_hours() >= float(hw["hungry_hours"])

## allow() and, if so, note it (for hardships that don't report themselves).
func take(kind: String) -> bool:
	if not allow(kind): return false
	note(kind)
	return true

## Something went wrong: tension rises by its weight (once per same_secs per kind).
func note(kind: String) -> void:
	var w := weight(kind)
	if w <= 0.0: return
	if kind == "death": deaths.append(sim.time)
	elif sim.time - float(last_note.get(kind, -1e9)) < float(C.get("same_secs", 30)): return
	last_note[kind] = sim.time
	tension += w

## Seconds to put a held-back hardship off by.
func retry() -> float: return float(C.get("retry", 30))

func update(dt: float) -> void:
	tension = maxf(0.0, tension - float(_level().get("decay", 1.6)) * dt / D.DAY_LEN)
	check_t -= dt
	if check_t > 0: return
	var ds: Dictionary = C.get("distress", {})
	check_t = float(ds.get("check_every", 5))
	deaths = deaths.filter(func(t): return sim.time - t < D.DAY_LEN * float(ds.get("death_days", 2)))
	var pop: int = sim.living().size()
	distress = pop > 0 and (sim.stock["food"] < pop * float(ds.get("food_per_head", 0.5)) or deaths.size() >= int(ds.get("deaths", 2)) or sim.folk.mood < float(ds.get("mood", 20)))
	if distress and active() and sim.time >= mercy_ready: _mercy()

## A gift in the worst of it: the first mercy.gifts entry whose conditions hold.
func _mercy() -> void:
	var M: Dictionary = C.get("mercy", {})
	mercy_until = sim.time + D.DAY_LEN * float(M.get("days", 2))
	mercy_ready = sim.time + D.DAY_LEN * float(M.get("cooldown_days", 5))
	for g in M.get("gifts", []):
		if sim.story.holds(g.get("when", {})):
			sim.story.run(g.get("do", []), null)
			return

## For a game master (and the pacing tool): the director's state.
## The coming winter's kind (config/events.json winters.kinds), picked when autumn begins
## from the year's state: each kind's weight, times "repeat" if it was last winter's, the
## "mercy" multipliers while the tribe is in distress, and the "rich" ones when the stores
## are at least rich_food_at full (a tribe that can afford a hard winter gets one more often).
## Numbers in director.json "winter".
func pick_winter() -> String:
	var W: Dictionary = C["winter"]
	var kinds: Dictionary = sim.hz.winters()["kinds"]
	var last: String = sim.hz.winter_log[-1]["kind"] if not sim.hz.winter_log.is_empty() else ""
	var rich: bool = sim.stock["food"] >= sim.food_cap() * float(W["rich_food_at"])
	var total := 0.0
	var ws := {}
	for k in kinds:
		var w: float = float(kinds[k].get("weight", 1.0))
		if k == last: w *= float(W["repeat"])
		if mercy(): w *= float(W["mercy"].get(k, 1.0))
		elif rich: w *= float(W["rich"].get(k, 1.0))
		ws[k] = w
		total += w
	var roll := randf() * total
	for k in ws:
		roll -= ws[k]
		if roll <= 0.0: return k
	return kinds.keys()[0]

func summary() -> Dictionary:
	return {"active": active(), "tension": snappedf(tension, 0.01), "cap": cap(), "distress": distress,
		"mercy": sim.time < mercy_until, "held_lately": held.slice(-5).map(func(h): return h["kind"])}
