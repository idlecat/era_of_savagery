## Everyday inventions (D.INVENTIONS) - medicines, tools and daily goods - and the tribe's
## list of achievements (its "firsts": inventions, wisdom, finds, landmarks, clans met,
## traditions, ages, masterpieces, outposts) shown in the Achievements panel.
##
## An invention's practice counts up from the work people do (evo.practice() passes it
## on), but only once its needs are met. When every activity has enough, the idea comes
## to whoever practised most of it (a small chance each check, so it doesn't come on cue).
## Effects are queries other code asks: sim.inv.has("fish_hook").
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")

var sim
var known := {}    # invention id -> {"day", "by"}
var progress := {} # invention id -> {activity: points}
var contrib := {}  # invention id -> {unit id: points}
var feats: Array = [] # [{"day", "kind", "text", "who"}], oldest first (texts already translated)
var _t := 0.0

func _init(s) -> void:
	sim = s

static func def(id: String) -> Dictionary:
	for d in D.INVENTIONS:
		if d["id"] == id: return d
	return {}

func has(id: String) -> bool:
	return known.has(id)

func needs_met(d: Dictionary) -> bool:
	var n: Dictionary = d["needs"]
	for t in n.get("techs", []):
		if not sim.has_tech(t): return false
	for f in n.get("finds", []):
		if not sim.knows_find(f): return false
	for i in n.get("inventions", []):
		if not has(i): return false
	return true

## 0..1: how close the tribe is to an invention (the least advanced activity).
func frac(id: String) -> float:
	var d := def(id)
	if has(id): return 1.0
	if not needs_met(d): return 0.0
	var f := 1.0
	for a in d["practice"]:
		f = minf(f, progress.get(id, {}).get(a, 0.0) / float(d["practice"][a]))
	return f

func practice(u: E.Unit, activity: String, amount: float) -> void:
	if u.role == "child": return # children play at the work; ideas come to grown hands
	for d in D.INVENTIONS:
		var id: String = d["id"]
		if has(id) or not d["practice"].has(activity) or not needs_met(d): continue
		var p: Dictionary = progress.get(id, {})
		p[activity] = p.get(activity, 0.0) + amount
		progress[id] = p
		var c: Dictionary = contrib.get(id, {})
		c[u.id] = c.get(u.id, 0.0) + amount
		contrib[id] = c

func update(dt: float) -> void:
	_t -= dt
	if _t > 0: return
	_t = 2.0
	for d in D.INVENTIONS:
		if not has(d["id"]) and frac(d["id"]) >= 1.0 and randf() < 0.15:
			discover(d["id"], _inventor(d["id"]))
			return # one at a time

func _inventor(id: String) -> E.Unit:
	var best: E.Unit = null
	var pts := -1.0
	var c: Dictionary = contrib.get(id, {})
	for uid in c:
		var u: E.Unit = sim.unit_by_id(uid)
		if u and not u.dead and c[uid] > pts:
			pts = c[uid]
			best = u
	return best

func discover(id: String, u: E.Unit) -> void:
	if has(id): return
	var d := def(id)
	known[id] = {"day": sim.day(), "by": u.name if u else ""}
	var nm: String = tr(d["name"])
	if u:
		sim.remember(u, tr("invented the %s on Day %d") % [nm, sim.day()], 7)
		sim.gain_xp(u, "lore" if d["kind"] == "medicine" else "craft", 10)
		sim.popup(u.pos + Vector2(0, -50), tr("New %s: %s") % [tr(D.INVENTION_KINDS[d["kind"]]).to_lower(), nm], Color("#9ff0c8"), true)
	sim.add_log(tr("Invention! %s made the first %s: %s") % [tr(u.name) if u else tr("The tribe"), nm, tr(d["desc"])], "tech", [u] if u else [])
	sim.folk.lift(3.0)
	feat("invention", tr("Invented the %s (%s)") % [nm, tr(D.INVENTION_KINDS[d["kind"]]).to_lower()], u)

## Note one of the tribe's firsts for the Achievements panel.
func feat(kind: String, text: String, who: E.Unit = null) -> void:
	feats.append({"day": sim.day(), "kind": kind, "text": text, "who": who.name if who else ""})

# ------------------------------------------------------------ effects
func heal_mult() -> float: return 1.4 if has("moss_dressing") else 1.0
func sick_mult() -> float: return 1.3 if has("fever_brew") else 1.0
func gather_mult(kind: String, activity: String) -> float:
	var m := 1.0
	if activity == "berry" and has("digging_stick"): m *= 1.25
	if kind == "fish" and has("fish_hook"): m *= 1.4
	return m
func atk_bonus() -> float: return 2.0 if has("sling") else 0.0
func carry_bonus() -> int: return 3 if has("carrying_frame") else 0
func cold_mult() -> float: return 0.7 if has("bone_needle") else 1.0
func store_bonus() -> int: return 30 if has("baskets") else 0
func spoil_mult() -> float: return (0.7 if has("smoking_rack") else 1.0) * (0.8 if has("salt_curing") else 1.0)
func mood_bonus() -> float: return (5.0 if has("bone_flute") else 0.0) + (3.0 if has("fur_bedding") else 0.0)
func lore_rate() -> float: return 0.02 if has("clay_lamp") else 0.0
