## The culture a game is played in, at play (sim.cult). Its content comes from a culture
## pack (cultures.gd, D.CULTURE); its inventions and finds are merged into the usual
## tables, and this runs the rest:
##   events  - when their conditions hold (story.gd holds(), with an optional chance per
##             day): a chronicle line, or a dilemma (options with costs and actions) that
##             pauses the game like the flood warning
##   tales   - folk tales told by the fire at night (one a night) or at a festival, once
##             each; telling one can run actions (devotion, insight, a lasting boon...)
##   people  - the Chosen One's bloodlines (D.CHOSEN), founders who lead a random tribe,
##             wanderers who come to join, and ancestors who are only spoken of
## It also remembers what has happened (seen) for "after" conditions, and lists everything
## for the Heritage panel (codex()) and the LLM prompts (ctx()).
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")
const Cultures = preload("res://scripts/cultures.gd")

var sim
var def := {}
var enabled := true # tests switch this off
var boons: Array = [] # lasting effects won from events and tales (inventions.gd folds them in)
var fired := {}  # event id -> day it happened
var told := {}   # tale id -> {"day", "by"}
var joined := {} # person id -> day they joined (or were born, for the Chosen One)
var seen := {}   # game event id (flood, eclipse, festival, chosen, era2...) -> day
var pending: Array = [] # dilemma ids ("culture:<event id>") waiting for sim._check_events
var tale_day := -1 # the day of the last fireside tale
var _t := 0.0

func _init(s) -> void:
	sim = s

func on() -> bool: return not def.is_empty()
func list(section: String) -> Array: return def.get(section, [])

func entry(section: String, id: String) -> Dictionary:
	for e in list(section):
		if e["id"] == id: return e
	return {}

## At the start of a game (after the tribe exists): the culture's founders lead a random tribe.
func setup() -> void:
	def = D.CULTURE
	if not on() or D.MAP.get("kind", "") != "random": return
	var adults: Array = sim.units.filter(func(u): return u.role == "" and not u.hero)
	var i := 0
	for p in list("people"):
		if p.get("as", "") != "founder" or i >= adults.size(): continue
		var old: E.Unit = adults[i]
		var u: E.Unit = sim.make_unit(_unit_def(p), old.pos)
		sim.units[sim.units.find(old)] = u
		joined[p["id"]] = 0
		i += 1

func _unit_def(p: Dictionary) -> Dictionary:
	return Cultures.person_def(p)

func update(dt: float) -> void:
	if not on() or not enabled: return
	_t -= dt
	if _t > 0.0: return
	_t = 1.0
	var st = sim.story
	for ev in list("events"):
		var id: String = ev["id"]
		if fired.has(id) or not st.holds(ev.get("when", {})) or not _roll(ev): continue
		fired[id] = sim.day()
		if not ev.get("options", []).is_empty():
			pending.append("culture:" + id)
			return # one dilemma at a time
		_chronicle(ev)
	for p in list("people"):
		if p.get("as", "") == "wanderer" and not joined.has(p["id"]) and st.holds(p.get("when", {})) and _roll(p):
			join(p["id"])
	if sim.rest_time() and tale_day != sim.day():
		for t in list("tales"):
			if t.get("tell", "night") == "night" and not told.has(t["id"]) and st.holds(t.get("when", {})):
				tell(t["id"])
				break

## A per-day chance, checked once a second.
func _roll(e: Dictionary) -> bool:
	if not e.has("chance"): return true
	return randf() < float(e["chance"]) / D.DAY_LEN

func _chronicle(ev: Dictionary) -> void:
	sim.add_log("%s — %s" % [tr(ev["title"]), tr(ev["text"])], "story")
	sim.story.run(ev.get("do", []), null)
	sim.inv.feat("story", tr(ev["title"]), null, {"desc": tr(ev["text"]), "source": ev.get("source", ""), "history": ev.get("history", "")})

## Tell a folk tale now (once per tale). The best keeper of lore tells it.
func tell(id: String) -> void:
	var t := entry("tales", id)
	if t.is_empty() or told.has(id): return
	var teller: E.Unit = sim.best_unit("lore", false)
	if teller and teller.role == "child": teller = null
	told[id] = {"day": sim.day(), "by": teller.name if teller else ""}
	tale_day = sim.day()
	if teller:
		sim.add_log(tr("By the fire, %s tells the tale of %s: %s") % [tr(teller.name), tr(t["name"]), tr(t["text"])], "story", [teller])
		sim.remember(teller, tr("told the tale of %s by the fire") % tr(t["name"]), 4)
		sim.gain_xp(teller, "lore", 4)
	else:
		sim.add_log(tr("By the fire, the elders tell the tale of %s: %s") % [tr(t["name"]), tr(t["text"])], "story")
	sim.folk.lift(1.0)
	sim.story.run(t.get("do", []), null)
	sim.inv.feat("tale", tr("Told the tale of %s") % tr(t["name"]), teller, {"desc": tr(t["text"]), "source": t.get("source", ""), "history": t.get("history", "")})

## A festival: the people ask for a tale saved for feasts (or any untold one).
func festival() -> void:
	if not on(): return
	for t in list("tales"):
		if t.get("tell", "night") == "festival" and not told.has(t["id"]) and sim.story.holds(t.get("when", {})):
			tell(t["id"])
			return

## One of the culture's people comes to the tribe (a wanderer, or by an event).
func join(id: String) -> void:
	var p := entry("people", id)
	if p.is_empty() or joined.has(id): return
	joined[id] = sim.day()
	var d := _unit_def(p)
	d["hero"] = p.get("as", "") in ["chosen", "wanderer"]
	var at: Vector2 = D.VILLAGE + Vector2.from_angle(randf() * TAU) * 220.0
	var u: E.Unit = sim.make_unit(d, at)
	sim.units.append(u)
	sim.evo.on_birth(u)
	var full: String = (tr(p["name"]) + " " + tr(p.get("epithet", ""))).strip_edges()
	sim.add_log(tr("%s comes to the tribe: %s") % [full, tr(p.get("text", p["desc"]))], "story", [u])
	sim.popup(at + Vector2(0, -40), tr("%s joins the tribe!") % tr(p["name"]), Color("#ffd36b"), true)
	sim.remember(u, tr("came to the tribe on Day %d") % sim.day(), 8)
	sim.inv.feat("hero", tr("%s joined the tribe") % full, u, {"desc": tr(p["desc"]), "source": p.get("source", ""), "history": p.get("history", "")})

## The Chosen One was born from bloodline `def` (one of D.CHOSEN).
func on_chosen(d: Dictionary) -> void:
	if d.has("id"): joined[d["id"]] = sim.day()

func add_boon(effects: Array) -> void:
	boons.append_array(effects)

## Called for every game event that fires (sim._fire_event), for "after" conditions.
func on_event(id: String) -> void:
	if not seen.has(id): seen[id] = sim.day()

# ------------------------------------------------------------ dilemmas
func owns_event(id: String) -> bool: return id.begins_with("culture:")

func event_def(id: String) -> Dictionary:
	var ev := entry("events", id.trim_prefix("culture:"))
	if ev.is_empty(): return {}
	return {"title": tr(ev["title"]), "text": tr(ev["text"]),
		"options": ev.get("options", []).map(func(o): return {"label": tr(o["label"]), "desc": _opt_desc(o), "enabled": _affords(o)})}

func _opt_desc(o: Dictionary) -> String:
	var parts: Array = []
	if o.has("desc"): parts.append(tr(o["desc"]))
	var cost: Dictionary = o.get("cost", {})
	if not cost.is_empty():
		parts.append(tr("Costs %s.") % ", ".join(cost.keys().map(func(r): return "%d %s" % [int(cost[r]), tr(r)])))
	return " ".join(parts)

func _affords(o: Dictionary) -> bool:
	for r in o.get("cost", {}):
		if sim.stock.get(r, 0.0) < float(o["cost"][r]): return false
	return true

func resolve(id: String, idx: int) -> String:
	var ev := entry("events", id.trim_prefix("culture:"))
	var opts: Array = ev.get("options", [])
	if opts.is_empty(): return ""
	var o: Dictionary = opts[clampi(idx, 0, opts.size() - 1)]
	if not _affords(o): o = opts.back() # (can't pay: the last choice, usually "do nothing")
	for r in o.get("cost", {}): sim.stock[r] -= float(o["cost"][r])
	sim.story.run(o.get("do", []), null)
	sim.inv.feat("story", "%s: %s" % [tr(ev["title"]), tr(o["label"])], null,
		{"desc": tr(o["result"]) if o.has("result") else tr(ev["text"]), "source": ev.get("source", ""), "history": ev.get("history", "")})
	return tr(o["result"]) if o.has("result") else tr("The tribe chose: %s.") % tr(o["label"])

# ------------------------------------------------------------ what the tribe knows
## Is this culture entry known to the tribe yet? (Ancestors are known from the start.)
func known(section: String, e: Dictionary) -> bool:
	match section:
		"inventions", "foods": return sim.inv.has(e["id"])
		"finds": return sim.knows_find(e["id"])
		"people": return e.get("as", "ancestor") == "ancestor" or joined.has(e["id"])
		"events": return fired.has(e["id"])
		"tales": return told.has(e["id"])
	return false

## For the Heritage panel: [{"section", "title", "entries": [{name, sub, desc, history, source, known}]}].
const SECTIONS := {"inventions": "Tools & crafts", "foods": "Foods", "finds": "From the land", "people": "People",
	"events": "Happenings", "tales": "Folk tales"}
func codex() -> Array:
	var out: Array = []
	for sec in SECTIONS:
		var rows: Array = []
		for e in list(sec):
			if e.get("as", "") == "founder" and D.MAP.get("kind", "") != "random": continue # (a scenario has its own tribe)
			var sub := ""
			match sec:
				"people": sub = tr(e.get("epithet", ""))
				"tales":
					if told.has(e["id"]): sub = tr("told by %s on Day %d") % [tr(told[e["id"]]["by"]) if told[e["id"]]["by"] != "" else tr("the elders"), told[e["id"]]["day"]]
				"events":
					if fired.has(e["id"]): sub = tr("Day %d") % fired[e["id"]]
			rows.append({"name": tr(e.get("name", e.get("title", ""))), "sub": sub,
				"desc": tr(e.get("text", e.get("desc", ""))) if sec in ["tales", "events"] else tr(e.get("desc", "")),
				"history": e.get("history", ""), "source": tr(e["source"]) if e.has("source") else "", "known": known(sec, e)})
		if not rows.is_empty(): out.append({"section": sec, "title": tr(SECTIONS[sec]), "entries": rows})
	return out

## For the LLM prompts (evo.world_ctx()): the culture, the tales told, the great people.
func ctx() -> Dictionary:
	if not on(): return {}
	var tales: Array = []
	for t in list("tales"):
		if told.has(t["id"]): tales.append("%s: %s" % [tr(t["name"]), tr(t.get("moral", t["text"].left(120)))])
	var people: Array = []
	for p in list("people"):
		if known("people", p): people.append((tr(p["name"]) + " " + tr(p.get("epithet", ""))).strip_edges() + ": " + tr(p["desc"]))
	return {"our_people": "%s — %s" % [tr(def["name"]), tr(def["desc"])], "tales_we_tell": tales, "great_ones_we_speak_of": people}
