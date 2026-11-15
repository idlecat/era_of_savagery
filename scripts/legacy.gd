## Endgames: three ways for the tribe to win its place in legend, and one way to lose it.
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

const PATHS := ["conquest", "unity", "wisdom"]
const TITLES := {"conquest": "Victory by Conquest", "unity": "Victory by Unity", "wisdom": "Victory by Wisdom", "defeat": "The Fire Goes Out"}

var sim
var achieved := {} # path -> day
var pending := ""
var check_t := 0.0

func _init(s) -> void:
	sim = s

## For the Legacy panel: each path with its conditions and whether they are met.
func progress() -> Array:
	var R = sim.rivals
	var ids: Array = R.clans.keys()
	var vassals: int = ids.filter(func(id): return R.clans[id]["vassal"] > 0).size()
	var allied: int = ids.filter(func(id): return R.has_treaty(id, "alliance")).size()
	var known: int = D.TECHS.filter(func(t): return sim.has_tech(t["id"])).size()
	return [
		{"path": "conquest", "title": tr(TITLES["conquest"]), "desc": tr("Every neighbouring clan bends the knee."), "conds": [
			{"text": tr("Clans made our vassals: %d / %d") % [vassals, ids.size()], "done": vassals == ids.size()}]},
		{"path": "unity", "title": tr(TITLES["unity"]), "desc": tr("The clans of the river become one people."), "conds": [
			{"text": tr("Alliances with every clan: %d / %d") % [allied, ids.size()], "done": allied == ids.size()},
			{"text": tr("A Council Ring where the chiefs can meet"), "done": sim._struct_exists("council_ring")}]},
		{"path": "wisdom", "title": tr(TITLES["wisdom"]), "desc": tr("All that can be known, carved in stone."), "conds": [
			{"text": tr("Wisdom known: %d / %d") % [known, D.TECHS.size()], "done": known == D.TECHS.size()},
			{"text": tr("A Grand Altar raised"), "done": sim._struct_exists("grand_altar")}]},
	]

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
		"path": path, "ending": tr(TITLES[path]), "day": sim.day(), "age": tr(D.ERA_NAMES[sim.evo.era]),
		"people_living": sim.living().size(), "people_fallen": sim.units.filter(func(u): return u.dead).size(),
		"wisdom": D.TECHS.filter(func(t): return sim.has_tech(t["id"])).map(func(t): return tr(t["name"])),
		"traditions": sim.evo.world_ctx()["traditions"], "culture": sim.evo.culture_summary(),
		"neighbours": clans, "great_deeds": deeds,
		"storyteller": {"name": tr(teller.name), "epithet": tr(teller.epithet), "fallen": teller.dead} if teller else {},
	}

## Offline saga: stitched from the same facts.
func saga_offline(ctx: Dictionary) -> String:
	var lines: Array = []
	var opening: String = {
		"conquest": tr("Hear how the tribe of the bonfire became lords of the river."),
		"unity": tr("Hear how the clans of the river learned to sit at one fire."),
		"wisdom": tr("Hear how the tribe of the bonfire came to know all that can be known."),
		"defeat": tr("Hear how the last fire of our tribe went out."),
	}[ctx["path"]]
	lines.append(opening)
	for d in ctx["great_deeds"].slice(0, 6):
		lines.append(tr("%s %s.") % [d["who"], d["deed"]])
	var fates: Array = ctx["neighbours"].map(func(n): return tr("the %s (%s)") % [n["clan"], n["fate"]])
	if not fates.is_empty(): lines.append(tr("Our neighbours: %s.") % ", ".join(fates))
	lines.append({
		"defeat": tr("After %d days, no one was left to tend the fire. Only the wind remembers us."),
	}.get(ctx["path"], tr("After %d days, our people still stand, and their tale is told at every fire.")) % ctx["day"])
	return "\n".join(lines)

# ------------------------------------------------------------ events
func event_def(id: String) -> Dictionary:
	var path := path_of(id)
	var lived: int = sim.living().size()
	var text := ""
	match path:
		"conquest": text = tr("The last of the neighbouring chiefs has laid down their weapons at our fire. From the ford to the far hills, the clans pay us tribute.")
		"unity": text = tr("In the Council Ring the chiefs of every clan sit together and share one fire. Where there were three peoples, there is now one.")
		"wisdom": text = tr("Beneath the Grand Altar the elders recite all that our people know - fire, stone, bronze and the law. Nothing will be forgotten.")
		"defeat": text = tr("The last of our people has fallen. The bonfire burns down to ash.")
	var opts: Array = [{"label": tr("Begin anew"), "desc": tr("Start a new chronicle."), "enabled": true}]
	if path != "defeat": opts.push_front({"label": tr("Continue the chronicle"), "desc": tr("Keep playing: %d people still live.") % lived, "enabled": true})
	return {"title": tr(TITLES[path]), "text": text, "options": opts}

## Returns {"text", "restart": bool}
func resolve(id: String, idx: int) -> Dictionary:
	pending = ""
	var path := path_of(id)
	var restart: bool = path == "defeat" or idx == 1
	return {"text": tr("The chronicle goes on.") if not restart else tr("A new tribe gathers around a new fire."), "restart": restart}
