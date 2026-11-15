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
	if sim.evo.era < int(n.get("era", 1)): return false
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
## Effects are data ({"stat", "mul"|"add", "of"}, see D.EFFECT_STATS) on inventions, on
## culture finds (while known) and on the culture's event/tale boons (sim.cult.boons).
## mul() multiplies them up and add() sums them; both cache until something is learned.
var _fx := {}
var _fx_sig := -1

func _sources() -> Array:
	var out: Array = []
	for d in D.INVENTIONS:
		if has(d["id"]): out.append_array(d.get("effects", []))
	for f in sim.known_finds:
		out.append_array(D.FINDS.get(f, {}).get("effects", []))
	out.append_array(sim.cult.boons)
	return out

func _fold(stat: String, of: String) -> Dictionary:
	var sig: int = known.size() + sim.known_finds.size() * 1000 + sim.cult.boons.size() * 1000000
	if sig != _fx_sig:
		_fx = {}
		_fx_sig = sig
	var key := stat + "|" + of
	if not _fx.has(key):
		var m := 1.0
		var a := 0.0
		for e in _sources():
			if e.get("stat", "") != stat: continue
			var o: String = e.get("of", "")
			if o != "" and o != of and not (of.contains("/") and o in of.split("/")): continue
			if e.has("mul"): m *= float(e["mul"])
			if e.has("add"): a += float(e["add"])
		_fx[key] = {"mul": m, "add": a}
	return _fx[key]

## Product of every known "mul" effect on `stat` (narrowed by `of`, "a/b" matches either).
func mul(stat: String, of := "") -> float: return _fold(stat, of)["mul"]
## Sum of every known "add" effect on `stat`.
func add(stat: String, of := "") -> float: return _fold(stat, of)["add"]

func heal_mult() -> float: return mul("heal")
func sick_mult() -> float: return mul("sick")
func gather_mult(kind: String, activity: String) -> float: return mul("gather", activity + "/" + kind)
func atk_bonus() -> float: return add("atk")
func carry_bonus() -> int: return roundi(add("carry"))
func cold_mult() -> float: return mul("cold")
func store_bonus() -> int: return roundi(add("store"))
func spoil_mult() -> float: return mul("spoil")
func mood_bonus() -> float: return add("mood")
func lore_rate() -> float: return add("lore")
