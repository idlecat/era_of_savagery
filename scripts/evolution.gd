## How the tribe's world evolves: knowledge (science & technology), culture, and eras.
##
## Knowledge  - techs are discovered by PRACTICE (insight builds up while people do related
##              work) or finished early by spending lore. The person who contributed most
##              becomes the INVENTOR. Knowledge lives in people: it spreads to those nearby,
##              is taught to children, and - under oral tradition - dies with its last
##              keeper unless the tribe has codified it (Megalithic Totems / Tribal Code).
## Culture    - four values (martial, spiritual, settled, ranked) drift with what the tribe
##              actually does. Crossing a threshold adopts a permanent TRADITION.
## Eras       - the first tech of a new era starts a new age: a culture-defining dilemma,
##              new building styles (renovation) and new things personas can talk about.
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")

var sim
var insight := {}   # tech id -> points (complete at tech cost)
var contrib := {}   # tech id -> {unit id: points}
var knowers := {}   # tech id -> {unit id: true}
var inventors := {} # tech id -> name (discovered by practice or research)
var teachers := {}  # tech id -> name (finished with lore)
var codified := false # true once Totems or Tribal Code exist: knowledge can no longer be lost
var oral_tradition := true
var culture := {"martial": 0.0, "spiritual": 0.0, "settled": 0.0, "ranked": 0.0}
var traditions := {} # id -> day adopted
var era := 1
var pending_era := 0 # era whose dilemma event is waiting to fire
var spread_t := 0.0

func _init(s) -> void:
	sim = s
	for t in D.TECHS:
		insight[t["id"]] = 0.0
		contrib[t["id"]] = {}
		knowers[t["id"]] = {}

# ------------------------------------------------------------ queries
static func tech_def(id: String) -> Dictionary:
	for t in D.TECHS:
		if t["id"] == id: return t
	return {}

func prereqs_met(id: String) -> bool:
	for r in tech_def(id).get("req", []):
		if not sim.has_tech(r): return false
	return true

## Techs the tribe could discover next (prerequisites known, tech itself not).
func candidates() -> Array:
	return D.TECHS.filter(func(t): return not sim.has_tech(t["id"]) and prereqs_met(t["id"])).map(func(t): return t["id"])

func insight_frac(id: String) -> float:
	return clampf(insight[id] / float(tech_def(id)["cost"]), 0.0, 1.0)

## Lore needed to finish an idea now (the practiced part is free).
func lore_cost(id: String) -> int:
	return ceili(tech_def(id)["cost"] * (1.0 - insight_frac(id)))

func knows(u: E.Unit, id: String) -> bool:
	return knowers[id].has(u.id)

func known_by(u: E.Unit) -> Array:
	return D.TECHS.filter(func(t): return knowers[t["id"]].has(u.id)).map(func(t): return t["id"])

func keepers(id: String) -> Array:
	return sim.living().filter(func(u): return knowers[id].has(u.id))

func has_trad(id: String) -> bool:
	return traditions.has(id)

func era_now() -> int:
	var e := 1
	for t in D.TECHS:
		if sim.has_tech(t["id"]): e = maxi(e, t["era"])
	return e

# ------------------------------------------------------------ practice -> insight -> breakthrough
## Called by the simulation whenever someone does work: activity in D.PRACTICE_NAMES,
## amount ~ seconds of work.
func practice(u: E.Unit, activity: String, amount: float) -> void:
	for t in D.TECHS:
		var id: String = t["id"]
		var w: float = t["practice"].get(activity, 0.0)
		if w <= 0.0 or sim.has_tech(id) or not prereqs_met(id): continue
		var pts := amount * w * D.INSIGHT_RATE
		insight[id] += pts
		contrib[id][u.id] = contrib[id].get(u.id, 0.0) + pts
		if insight[id] >= t["cost"]: breakthrough(id, _top_contributor(id, u))

## Landmarks and research seed ideas (fraction of the tech's cost).
func seed(id: String, frac: float, u: E.Unit) -> void:
	if sim.has_tech(id): return
	var pts: float = tech_def(id)["cost"] * frac
	insight[id] = minf(insight[id] + pts, tech_def(id)["cost"] - 0.01) # discovery still needs practice or lore
	if u: contrib[id][u.id] = contrib[id].get(u.id, 0.0) + pts

func _top_contributor(id: String, fallback: E.Unit) -> E.Unit:
	var best: E.Unit = fallback
	var best_pts := -1.0
	for uid in contrib[id]:
		var o: E.Unit = sim.unit_by_id(uid)
		if o and not o.dead and contrib[id][uid] > best_pts:
			best_pts = contrib[id][uid]
			best = o
	return best

## A tech becomes known. how: "invented" (practice/research) or "taught" (lore).
func breakthrough(id: String, inventor: E.Unit, how := "invented") -> void:
	if sim.has_tech(id): return
	var t := tech_def(id)
	sim.techs[id] = true
	insight[id] = float(t["cost"])
	var learners: Array = []
	if how == "taught":
		learners = sim.living().filter(func(o): return o.role != "contract" and D.bank_of(o.pos) == "west")
		if inventor and inventor not in learners: learners.append(inventor)
	else:
		learners = sim.living().filter(func(o): return inventor and o.pos.distance_to(inventor.pos) < 260)
		if inventor and inventor not in learners: learners.append(inventor)
	for o in learners: knowers[id][o.id] = true
	if inventor:
		if how == "invented": inventors[id] = inventor.name
		else: teachers[id] = inventor.name
		if how == "invented":
			sim.remember(inventor, "invented %s on Day %d" % [t["name"], sim.day()], 8)
			sim.gain_xp(inventor, "lore", 12)
			sim.add_log("Breakthrough! %s discovered %s: %s" % [inventor.name, t["name"], t["desc"]], "tech")
			sim.popup(inventor.pos + Vector2(0, -50), "Breakthrough: " + t["name"], Color("#c8a8ff"), true)
		else:
			sim.remember(inventor, "taught the tribe %s on Day %d" % [t["name"], sim.day()], 6)
			sim.add_log("Tribal Wisdom: %s taught %s - %s" % [inventor.name, t["name"], t["desc"]], "tech")
	if id in ["totems", "code"] and not codified:
		codified = true
		sim.add_log("The tribe's knowledge is now %s - it can no longer be lost." % ("carved into the great totems" if id == "totems" else "kept in the Tribal Code"), "tech")
	var e := era_now()
	if e > era:
		era = e
		pending_era = e
		sim.add_log("A new age dawns: the %s." % D.ERA_NAMES[e], "story")
	# ideas that were waiting on this prerequisite
	for o in D.TECHS:
		if not sim.has_tech(o["id"]) and prereqs_met(o["id"]) and insight[o["id"]] >= o["cost"] - 0.01:
			breakthrough(o["id"], _top_contributor(o["id"], inventor))

func learn(u: E.Unit, id: String) -> void:
	knowers[id][u.id] = true

# ------------------------------------------------------------ living knowledge
func on_birth(u: E.Unit) -> void:
	for t in D.TECHS:
		if sim.has_tech(t["id"]): knowers[t["id"]][u.id] = true # children are taught at the fire

func on_death(u: E.Unit) -> void:
	for t in D.TECHS:
		var id: String = t["id"]
		if not knowers[id].has(u.id): continue
		knowers[id].erase(u.id)
		if oral_tradition and not codified and sim.has_tech(id) and keepers(id).is_empty():
			_lose(id, u)

func _lose(id: String, u: E.Unit) -> void:
	var t := tech_def(id)
	sim.techs.erase(id)
	insight[id] = t["cost"] * 0.35 # half-remembered: easier to rediscover
	sim.add_log("The secret of %s died with %s - no one else knew it. (Megalithic Totems or a Tribal Code would preserve knowledge.)" % [t["name"], u.name], "danger")
	sim.popup(u.pos + Vector2(0, -60), "%s is forgotten" % t["name"], Color("#ff8a8a"), true)
	for o in sim.living(): sim.remember(o, "mourned the lost knowledge of %s on Day %d" % [t["name"], sim.day()], 5)

func update(dt: float) -> void:
	spread_t -= dt
	if spread_t > 0: return
	spread_t = 2.0
	# Knowledge spreads between people who spend time together.
	var alive: Array = sim.living()
	for t in D.TECHS:
		var id: String = t["id"]
		if not sim.has_tech(id): continue
		var ks: Array = alive.filter(func(o): return knowers[id].has(o.id))
		if ks.size() == alive.size(): continue
		for o in alive:
			if knowers[id].has(o.id): continue
			for k in ks:
				if k.pos.distance_to(o.pos) < 150 and randf() < 0.2:
					knowers[id][o.id] = true
					break
	drift("martial", -0.004 * 2.0) # quiet days soften the tribe
	_check_traditions()

# ------------------------------------------------------------ culture
func drift(axis: String, amount: float) -> void:
	culture[axis] = clampf(culture[axis] + amount, -100.0, 100.0)

func _check_traditions() -> void:
	for t in D.TRADITIONS:
		if traditions.has(t["id"]): continue
		if culture[t["axis"]] * t["sign"] >= D.TRADITION_THRESHOLD: adopt(t["id"])

func adopt(id: String) -> void:
	var t: Dictionary = {}
	for o in D.TRADITIONS:
		if o["id"] == id: t = o
	if t.is_empty() or traditions.has(id): return
	traditions[id] = sim.day()
	sim.add_log("A new tradition takes hold: %s - %s" % [t["name"], t["desc"]], "story")
	sim.popup(D.VILLAGE + Vector2(0, -90), "Tradition: " + t["name"], Color("#ffd6a0"), true)
	var champion: E.Unit = null
	for u in sim.living():
		if sim.arch(u) == t["arch"] and (champion == null or sim.unit_level(u) > sim.unit_level(champion)): champion = u
	if champion: sim.remember(champion, "championed the tradition of %s on Day %d" % [t["name"], sim.day()], 6)

func pole(axis: String) -> String:
	var v: float = culture[axis]
	if absf(v) < 10: return ""
	var name: String = D.CULTURE_AXES[axis][0 if v > 0 else 1]
	return ("strongly " if absf(v) >= 50 else ("" if absf(v) >= D.TRADITION_THRESHOLD else "somewhat ")) + name.to_lower()

func culture_summary() -> String:
	var parts: Array = []
	for a in D.CULTURE_AXES:
		var p := pole(a)
		if p != "": parts.append(p)
	return ", ".join(parts) if not parts.is_empty() else "still unformed"

## Newborns lean toward the tribe's dominant values.
func birth_trait() -> String:
	var weights := {}
	for k in D.TRAITS: weights[k] = 1.0
	for a in D.CULTURE_TRAIT:
		if culture[a] > 0: weights[D.CULTURE_TRAIT[a]] += culture[a] / 20.0
	if culture["martial"] < 0: weights["cautious"] += -culture["martial"] / 30.0
	var total := 0.0
	for k in weights: total += weights[k]
	var r := randf() * total
	for k in weights:
		r -= weights[k]
		if r <= 0: return k
	return "cautious"

# ------------------------------------------------------------ what personas may talk about
func world_ctx() -> Dictionary:
	var known: Array = []
	var unknown_words: Array = []
	for t in D.TECHS:
		if sim.has_tech(t["id"]):
			known.append(t["name"] + ((" (invented by %s)" % inventors[t["id"]]) if inventors.has(t["id"]) else ""))
		else:
			unknown_words.append_array(t["words"])
	var trads: Array = []
	for t in D.TRADITIONS:
		if traditions.has(t["id"]): trads.append(t["name"])
	return {
		"age": D.ERA_NAMES[era], "known_wisdom": known, "traditions": trads,
		"tribe_culture": culture_summary(), "unknown_things_you_have_no_words_for": unknown_words,
	}
