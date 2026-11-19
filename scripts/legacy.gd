## Endgames: ways for the tribe to win its place in legend, and one way to lose it
## (config/legacy.json: a path is won when all its conditions are met).
##
##   Conquest - every neighbouring clan bends the knee as our vassal.
##   Unity    - allied with every clan, with a Council Ring where their chiefs can meet.
##   Wisdom   - every piece of wisdom known, and a Grand Altar raised to the sky.
##   Defeat   - no one of the tribe is left alive.
##
## Reaching one fires an event; the HUD then asks the tribe's best storyteller (an LLM
## node, or the offline template) to compose the saga of the whole game from the
## memories of its people. The chronicle can go on afterwards as a sandbox.
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")

## The paths, their conditions and texts: config/legacy.json.
var C: Dictionary = preload("res://scripts/config.gd").load_cfg("legacy")
var PATHS: Array = C["paths"].keys()

var sim
var achieved := {} # path -> day
var pending := ""
var check_t := 0.0

func _init(s) -> void:
	sim = s

## For the Legacy panel: each path with its conditions and whether they are met.
func progress() -> Array:
	var out: Array = []
	for path in C["paths"]:
		var pd: Dictionary = C["paths"][path]
		out.append({"path": path, "title": tr(pd["title"]), "desc": tr(pd["desc"]), "conds": pd["conds"].map(func(c): return _cond(c))})
	return out

## A condition: {count: vassals|allies|techs} (all of them) or {built: structure}.
func _cond(c: Dictionary) -> Dictionary:
	if c.has("built"): return {"text": sim.story.text(c["text"]), "done": sim.struct_exists(c["built"])}
	var R = sim.rivals
	var n := 0
	var of := 0
	match str(c.get("count", "")):
		"vassals":
			of = R.clans.size()
			n = R.clans.keys().filter(func(id): return R.clans[id]["vassal"] > 0).size()
		"allies":
			of = R.clans.size()
			n = R.clans.keys().filter(func(id): return R.has_treaty(id, "alliance")).size()
		"techs":
			of = D.TECHS.size()
			n = D.TECHS.filter(func(t): return sim.has_tech(t["id"])).size()
	return {"text": sim.story.text(c["text"], {"n": n, "of": of}), "done": n == of}

func update(dt: float) -> void:
	check_t -= dt
	if check_t > 0 or pending != "": return
	check_t = 1.0
	if sim.living().is_empty() and not achieved.has("defeat"):
		achieved["defeat"] = sim.day()
		pending = "defeat"
		return
	for p in progress():
		if achieved.has(p["path"]): continue
		if p["conds"].all(func(c): return c["done"]):
			achieved[p["path"]] = sim.day()
			pending = "victory_" + p["path"]
			return

func owns_event(id: String) -> bool:
	return id.begins_with("victory_") or id == "defeat"

func path_of(id: String) -> String:
	return "defeat" if id == "defeat" else id.trim_prefix("victory_")

# ------------------------------------------------------------ the saga
## The storyteller: the living soul with the most lore (or the last one who died).
func storyteller() -> E.Unit:
	var best: E.Unit = null
	for u in sim.units:
		if best == null or (not u.dead and (best.dead or u.lv("lore") > best.lv("lore"))): best = u
	return best

## The tribe's story in facts: for the LLM saga-teller and the offline template.
func saga_ctx(path: String) -> Dictionary:
	var R = sim.rivals
	var deeds: Array = []
	for u in sim.units:
		for m in u.memory:
			if m["day"] > 0 and m["impact"] >= 7: deeds.append({"who": tr(u.name), "day": m["day"], "deed": tr(m["text"]), "impact": m["impact"], "fallen": u.dead})
	deeds.sort_custom(func(a, b): return a["impact"] > b["impact"] or (a["impact"] == b["impact"] and a["day"] < b["day"]))
	deeds = deeds.slice(0, 10)
	deeds.sort_custom(func(a, b): return a["day"] < b["day"])
	var clans: Array = []
	for id in R.clans:
		var c: Dictionary = R.clans[id]
		clans.append({"clan": tr(c["name"]), "chieftain": tr(c["chief"]), "fate": tr(R.stance(id)) if c["met"] else tr("never met")})
	var teller := storyteller()
	return {
		"path": path, "ending": tr((C["defeat"] if path == "defeat" else C["paths"][path])["title"]), "day": sim.day(), "age": tr(D.ERA_NAMES[sim.evo.era]),
		"people_living": sim.living().size(), "people_fallen": sim.units.filter(func(u): return u.dead).size(),
		"wisdom": D.TECHS.filter(func(t): return sim.has_tech(t["id"])).map(func(t): return tr(t["name"])),
		"traditions": sim.evo.world_ctx()["traditions"], "culture": sim.evo.culture_summary(),
		"neighbours": clans, "great_deeds": deeds,
		"treasures": sim.folk.treasures.map(func(t): return tr(t["name"]) + " (" + tr(t["maker"]) + ")"),
		"mood_of_the_tribe": sim.folk.mood_word(),
		"storyteller": {"name": tr(teller.name), "epithet": tr(teller.epithet), "fallen": teller.dead} if teller else {},
	}.merged(sim.cult.ctx()) # (the culture, its tales and great ones, if the game has one)

## Offline saga: stitched from the same facts.
func saga_offline(ctx: Dictionary) -> String:
	var lines: Array = []
	var pd: Dictionary = C["defeat"] if ctx["path"] == "defeat" else C["paths"][ctx["path"]]
	var opening: String = tr(pd["opening"])
	lines.append(opening)
	for d in ctx["great_deeds"].slice(0, 6):
		lines.append(tr("%s %s.") % [d["who"], d["deed"]])
	var fates: Array = ctx["neighbours"].map(func(n): return tr("the %s (%s)") % [n["clan"], n["fate"]])
	if not fates.is_empty(): lines.append(tr("Our neighbours: %s.") % ", ".join(fates))
	lines.append(tr(pd.get("closing", C["closing"])) % ctx["day"])
	return "\n".join(lines)

# ------------------------------------------------------------ events
func event_def(id: String) -> Dictionary:
	var path := path_of(id)
	var pd: Dictionary = C["defeat"] if path == "defeat" else C["paths"][path]
	var co: Dictionary = C["options"]
	var opts: Array = [{"label": tr(co["restart"]["label"]), "desc": tr(co["restart"]["desc"]), "enabled": true}]
	if path != "defeat": opts.push_front({"label": tr(co["continue"]["label"]), "desc": sim.story.text(co["continue"]["desc"], {"n": sim.living().size()}), "enabled": true})
	return {"title": tr(pd["title"]), "text": tr(pd["text"]), "options": opts}

## Returns {"text", "restart": bool}
func resolve(id: String, idx: int) -> Dictionary:
	pending = ""
	var path := path_of(id)
	var restart: bool = path == "defeat" or idx == 1
	return {"text": tr(C["options"]["restart" if restart else "continue"]["result"]), "restart": restart}
