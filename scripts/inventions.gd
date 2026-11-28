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
var _cache_by_activity := {} # activity -> the inventions its work advances (in D.INVENTIONS order)
var _cache_activity_sig: Array = [] # the D.INVENTIONS array the index was made from

func _init(s) -> void:
	sim = s

## The inventions each activity advances, by activity and in D.INVENTIONS order. D.INVENTIONS
## is the culture's (Cultures.apply() replaces it), so the index is made again when it changes.
func _activity_index() -> Dictionary:
	if is_same(_cache_activity_sig, D.INVENTIONS): return _cache_by_activity
	_cache_activity_sig = D.INVENTIONS
	_cache_by_activity = {}
	for d in D.INVENTIONS:
		for a in d.get("practice", {}):
			if not _cache_by_activity.has(a): _cache_by_activity[a] = []
			_cache_by_activity[a].append(d)
	return _cache_by_activity

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
	for d in _activity_index().get(activity, []): # (only the inventions this work advances)
		var id: String = d["id"]
		if has(id) or not needs_met(d): continue
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
	var cf: Dictionary = sim.DISC.get("inventions", {})
	for d in D.INVENTIONS:
		if has(d["id"]) or frac(d["id"]) < 1.0: continue
		# the idea comes by chance; the more skilled the one who worked at it most, the sooner
		var who := _inventor(d["id"])
		var skill: String = str(cf.get("skills", {}).get(str(d.get("kind", "")), "craft"))
		var lv: int = who.lv(skill) if who else 0
		if randf() < float(cf.get("chance", 0.05)) * (1.0 + float(cf.get("per_lv", 0.25)) * lv):
			discover(d["id"], who)
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
	feat("invention", tr("Invented the %s (%s)") % [nm, tr(D.INVENTION_KINDS[d["kind"]]).to_lower()], u,
		{"desc": tr(d["desc"]), "source": d.get("source", ""), "history": d.get("history", "")})

## Note one of the tribe's firsts for the Achievements panel (and the HUD's celebration).
## info: "desc" (what it means, translated), "source" and "history" (culture entries, as
## keys), "at" (where it happened; default: the one who did it, or the village).
func feat(kind: String, text: String, who: E.Unit = null, info := {}) -> void:
	var f := {"day": sim.day(), "kind": kind, "text": text, "who": who.name if who else "",
		"desc": info.get("desc", ""), "source": info.get("source", ""), "history": info.get("history", ""),
		"at": info.get("at", who.pos if who else D.VILLAGE)}
	feats.append(f)
	sim.feat_added.emit(f)

# ------------------------------------------------------------ effects
## Effects are data ({"stat", "mul"|"add", "of"}, see D.EFFECT_STATS) on inventions, on
## culture finds (while known) and on the culture's event/tale boons (sim.cult.boons).
## mul() multiplies them up and add() sums them; both cache until something is learned.
## The folds made so far (stat -> of -> {mul, add}), emptied when the sources change: a memo
## that rebuilds itself, so a _cache (not saved: the first question after loading makes it again).
var _cache_fx := {}
var _cache_fx_sig := -1

func _sources() -> Array:
	var out: Array = []
	for d in D.INVENTIONS:
		if has(d["id"]): out.append_array(d.get("effects", []))
	for f in sim.known_finds:
		out.append_array(D.FINDS.get(f, {}).get("effects", []))
	out.append_array(sim.cult.boons)
	if sim.policy: out.append_array(sim.policy.effects()) # the Council's ways
	return out

func _fold(stat: String, of: String) -> Dictionary:
	var sig: int = known.size() + sim.known_finds.size() * 1000 + sim.cult.boons.size() * 1000000 + (sim.policy.rev * 100000000 if sim.policy else 0)
	if sig != _cache_fx_sig:
		_cache_fx = {}
		_cache_fx_sig = sig
	var by_of: Dictionary = _cache_fx.get(stat, {})
	if not _cache_fx.has(stat): _cache_fx[stat] = by_of
	if not by_of.has(of):
		var m := 1.0
		var a := 0.0
		for e in _sources():
			if e.get("stat", "") != stat: continue
			var o: String = e.get("of", "")
			if o != "" and o != of and not (of.contains("/") and o in of.split("/")) and not (o.contains("|") and of in o.split("|")): continue
			if e.has("mul"): m *= float(e["mul"])
			if e.has("add"): a += float(e["add"])
		by_of[of] = {"mul": m, "add": a}
	return by_of[of]

## Product of every known "mul" effect on `stat` (narrowed by `of`, "a/b" matches either;
## an effect's own `of` may list several: "a|b").
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
