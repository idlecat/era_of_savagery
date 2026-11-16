## Culture packs: the peoples a game can be played as, each described by data files
## instead of code. A pack is a folder cultures/<id>/ (or user://cultures/<id>/ for mods)
## holding culture.json (English) and zh.json (Simplified Chinese, English text -> Chinese).
## docs/CULTURES.md documents the format; validate() checks a pack against it.
##
## A pack brings its own inventions (tools, goods, medicine), foods (inventions of kind
## "food"), natural finds, people (the Chosen One's bloodlines, founders of a random
## tribe, wanderers who join, ancestors spoken of), events (chronicle lines or dilemmas)
## and folk tales told by the fire. apply() merges the content into data.gd's tables for
## one game; the culture system (culture.gd, sim.cult) runs the events, tales and people.
## A game with no culture (tests) uses only the base content.
extends RefCounted

const D = preload("res://scripts/data.gd")
const I = preload("res://scripts/i18n.gd")

const DIRS := ["res://cultures", "user://cultures"]
const DEFAULT := "huaxia"
const HISTORY := ["real", "legend", "invented"]

static var packs := {} # id -> definition (parsed culture.json, with "zh" from zh.json)
static var problems := {} # pack folder -> [error text] (packs with errors are not offered)
static var _loaded := false

# ------------------------------------------------------------ loading
## Read every pack (once). Their Chinese texts go to the translation table at once, so
## names show translated in the New Game screen.
static func load_all(force := false) -> void:
	if _loaded and not force: return
	_loaded = true
	packs = {}
	problems = {}
	for dir in DIRS:
		if not DirAccess.dir_exists_absolute(dir): continue
		for sub in DirAccess.get_directories_at(dir):
			var path: String = dir + "/" + sub
			var r := load_pack(path)
			if not r["errors"].is_empty():
				problems[path] = r["errors"]
				for e in r["errors"]: push_warning("culture %s: %s" % [path, e])
				continue
			packs[r["def"]["id"]] = r["def"]
			I.add_strings(r["def"].get("zh", {}))

## Parse and validate one pack folder. Returns {"def", "errors"}.
static func load_pack(path: String) -> Dictionary:
	var f := path + "/culture.json"
	if not FileAccess.file_exists(f): return {"def": {}, "errors": ["no culture.json in " + path]}
	var j := JSON.new()
	if j.parse(FileAccess.get_file_as_string(f)) != OK:
		return {"def": {}, "errors": ["culture.json line %d: %s" % [j.get_error_line(), j.get_error_message()]]}
	if not j.data is Dictionary: return {"def": {}, "errors": ["culture.json must hold one {...} object"]}
	var def: Dictionary = j.data
	var zh := {}
	if FileAccess.file_exists(path + "/zh.json"):
		var jz := JSON.new()
		if jz.parse(FileAccess.get_file_as_string(path + "/zh.json")) != OK:
			return {"def": {}, "errors": ["zh.json line %d: %s" % [jz.get_error_line(), jz.get_error_message()]]}
		if jz.data is Dictionary: zh = jz.data
	def["zh"] = zh
	def["path"] = path
	return {"def": def, "errors": validate(def)}

static func ids() -> Array:
	load_all()
	var out: Array = packs.keys()
	out.sort_custom(func(a, b):
		var oa := int(packs[a].get("order", 100))
		var ob := int(packs[b].get("order", 100))
		return oa < ob if oa != ob else str(a) < str(b))
	return out

static func by_id(id: String) -> Dictionary:
	load_all()
	return packs.get(id, {})

# ------------------------------------------------------------ applying
## Back to the base content only (no culture).
static func reset() -> void:
	D.INVENTIONS = D.BASE_INVENTIONS.duplicate(true)
	D.FINDS = D.BASE_FINDS.duplicate(true)
	D.TRIBE_NAMES = D.BASE_TRIBE_NAMES.duplicate()
	D.BIRTH_NAMES = D.BASE_BIRTH_NAMES.duplicate()
	D.TEMPERAMENTS = D.BASE_TEMPERAMENTS.duplicate(true)
	D.CHOSEN = D.BASE_CHOSEN.duplicate(true)
	D.CULTURE = {}

## Play this game as culture `id` ("" or unknown: base content only). Call before the map
## is made: a random tribe takes its names from the culture.
static func apply(id: String) -> void:
	reset()
	var c := by_id(id)
	if c.is_empty(): return
	D.CULTURE = c
	for d in c.get("inventions", []): D.INVENTIONS.append(_invention(d, d.get("kind", "tool")))
	for d in c.get("foods", []): D.INVENTIONS.append(_invention(d, "food"))
	for d in c.get("finds", []): D.FINDS[d["id"]] = _find(d)
	if c.has("tribe_names"): D.TRIBE_NAMES = c["tribe_names"].duplicate()
	if c.has("birth_names"): D.BIRTH_NAMES = c["birth_names"].duplicate()
	for k in ["epithets", "memories"]:
		for t in c.get(k, {}):
			D.TEMPERAMENTS[t][k] = D.TEMPERAMENTS[t][k] + c[k][t]
	var chosen: Array = c.get("people", []).filter(func(p): return p.get("as", "") == "chosen")
	if not chosen.is_empty(): D.CHOSEN = chosen.map(func(p): return person_def(p))

static func _invention(d: Dictionary, kind: String) -> Dictionary:
	var o := d.duplicate(true)
	o["kind"] = kind
	o["from_culture"] = true
	for k in ["practice", "needs"]:
		if not o.has(k): o[k] = {}
	for k in ["effects", "words"]:
		if not o.has(k): o[k] = []
	if not o.has("hint"): o["hint"] = ""
	return o

static func _find(d: Dictionary) -> Dictionary:
	var o := {"group": "food", "res": "food", "amount": 20, "rate": 0.8, "regrow": 0.05, "winter": false, "needs": "",
		"where": "meadow", "count": 3, "practice": "berry", "look": "grain", "effects": [], "from_culture": true}
	o.merge(d.duplicate(true), true)
	if not o.has("act"): o["act"] = "Gathering " + str(o["name"]).to_lower() # (see texts(): a translation key)
	return o

## A person entry -> a unit definition for sim.make_unit (plus label/desc for the Chosen One).
static func person_def(p: Dictionary) -> Dictionary:
	var st: Dictionary = p.get("stats", {})
	var skills: Dictionary = st.get("skills", {"forage": 2, "craft": 2, "combat": 2, "lore": 2})
	return {"id": p["id"], "name": p["name"], "epithet": p.get("epithet", ""), "traits": st.get("traits", ["cautious"]).duplicate(),
		"color": st.get("color", "#e0c080"), "hp": float(st.get("hp", 55)), "atk": float(st.get("atk", 6)),
		"def": float(st.get("def", 3)), "spd": float(st.get("spd", 1.0)), "skills": skills.duplicate(),
		"memory": p.get("memory", []).map(func(t): return {"day": -100, "text": t, "impact": 8}),
		"label": p.get("label", p["name"] + " " + p.get("epithet", "")).strip_edges(), "desc": p.get("desc", "")}

# ------------------------------------------------------------ validation
const TOP_KEYS := ["id", "name", "desc", "place", "period", "history", "source", "order", "tribe_names", "birth_names",
	"epithets", "memories", "inventions", "foods", "finds", "people", "events", "tales"]
const COMMON := ["id", "name", "desc", "history", "source"]
const INVENTION_KEYS := ["kind", "practice", "needs", "effects", "hint", "words"]
const FIND_KEYS := ["group", "res", "amount", "rate", "regrow", "winter", "needs", "where", "count", "cluster", "act",
	"practice", "practice_x", "look", "effects", "seed", "culture"]
const PERSON_KEYS := ["epithet", "as", "stats", "memory", "when", "label", "chance", "text"]
const EVENT_KEYS := ["title", "text", "when", "chance", "options", "do"]
const OPTION_KEYS := ["label", "desc", "cost", "needs", "do", "result", "else_do", "else_result"]
const TALE_KEYS := ["text", "when", "tell", "do", "moral"]
const WHEN_KEYS := ["time", "day", "pop", "flag", "found", "met", "tech", "invention", "find", "era", "season", "built",
	"devotion", "mood", "deaths", "culture", "after", "told", "joined", "happened"]
const DO_KEYS := ["log", "kind", "alert", "at", "level", "give", "reveal", "r", "flag", "mood", "devotion", "insight", "spawn", "offsets",
	"culture", "invent", "boon", "remember", "who", "impact", "feat", "tale", "join", "xp", "panic", "weather", "react"]
const PERSON_AS := ["chosen", "founder", "wanderer", "ancestor"]
const RESOURCES := ["food", "wood", "lore", "stone", "herbs", "copper", "tin", "goods"]
const WHERE := ["forest", "forest_edge", "meadow", "river", "riverbank", "hills_home", "hills_far"]
const SEASONS := ["Spring", "Summer", "Autumn", "Winter"]

## Every problem with a pack definition, as readable lines ("inventions[2].effects[0]: ...").
static func validate(c: Dictionary) -> Array:
	var errs: Array = []
	var err := func(where: String, msg: String): errs.append("%s: %s" % [where, msg])
	for k in c:
		if k not in TOP_KEYS and k not in ["zh", "path"]: err.call("top", "unknown key '%s'" % k)
	for k in ["id", "name", "desc"]:
		if not c.get(k) is String or c[k] == "": err.call("top", "'%s' (text) is required" % k)
	if not str(c.get("id", "")).is_valid_identifier(): err.call("top", "id must be a plain identifier like 'yangshao'")
	# ids known to this pack, for references
	var inv_ids: Array = D.BASE_INVENTIONS.map(func(d): return d["id"])
	var find_ids: Array = D.BASE_FINDS.keys()
	var tech_ids: Array = D.TECHS.map(func(t): return t["id"])
	var ids := {}
	for sec in ["inventions", "foods", "finds", "people", "events", "tales"]:
		if c.has(sec) and not c[sec] is Array:
			err.call(sec, "must be a list [...]")
			c[sec] = []
		for i in c.get(sec, []).size():
			var e = c[sec][i]
			var w := "%s[%d]" % [sec, i]
			if not e is Dictionary:
				err.call(w, "must be an object {...}")
				continue
			var eid: String = str(e.get("id", ""))
			if not eid.is_valid_identifier(): err.call(w, "needs an 'id' like 'painted_pottery'")
			elif ids.has(eid) or (sec in ["inventions", "foods"] and eid in inv_ids) or (sec == "finds" and eid in find_ids):
				err.call(w, "id '%s' is already used" % eid)
			ids[eid] = sec
			if sec in ["inventions", "foods"]: inv_ids.append(eid)
			if sec == "finds": find_ids.append(eid)
	var tale_ids: Array = c.get("tales", []).filter(func(e): return e is Dictionary).map(func(e): return str(e.get("id", "")))
	var people_ids: Array = c.get("people", []).filter(func(e): return e is Dictionary).map(func(e): return str(e.get("id", "")))
	var event_ids: Array = c.get("events", []).filter(func(e): return e is Dictionary).map(func(e): return str(e.get("id", "")))
	var refs := {"inv": inv_ids, "find": find_ids, "tech": tech_ids, "tale": tale_ids, "person": people_ids, "event": event_ids}

	for k in ["tribe_names", "birth_names"]:
		if c.has(k) and (not c[k] is Array or c[k].size() < (12 if k == "tribe_names" else 8) or c[k].any(func(n): return not n is String)):
			err.call(k, "must be a list of at least %d names" % (12 if k == "tribe_names" else 8))
	if c.has("tribe_names") and c.has("birth_names") and c["birth_names"] is Array and c["tribe_names"] is Array:
		if c["birth_names"].filter(func(n): return n not in c["tribe_names"]).size() < 6:
			err.call("birth_names", "needs at least 6 names that are not also in tribe_names")
	for k in ["epithets", "memories"]:
		if not c.has(k): continue
		if not c[k] is Dictionary:
			err.call(k, "must map a temperament to a list of texts")
			continue
		for t in c[k]:
			if not D.BASE_TEMPERAMENTS.has(t): err.call(k, "unknown temperament '%s' (one of %s)" % [t, ", ".join(D.BASE_TEMPERAMENTS.keys())])
			elif not c[k][t] is Array: err.call(k + "." + t, "must be a list of texts")
	var pool: Array = (c.get("tribe_names", []) if c.get("tribe_names") is Array else []) + (c.get("birth_names", []) if c.get("birth_names") is Array else [])
	if pool.is_empty(): pool = D.BASE_TRIBE_NAMES + D.BASE_BIRTH_NAMES
	for i in c.get("people", []).size():
		var pe = c["people"][i]
		if pe is Dictionary and pe.get("as", "ancestor") != "ancestor" and pe.get("name", "") in pool:
			err.call("people[%d]" % i, "'%s' is also in the name pools: two people would share a name" % pe["name"])
	for i in c.get("inventions", []).size(): _check_invention(c["inventions"][i], "inventions[%d]" % i, false, refs, err)
	for i in c.get("foods", []).size(): _check_invention(c["foods"][i], "foods[%d]" % i, true, refs, err)
	for i in c.get("finds", []).size(): _check_find(c["finds"][i], "finds[%d]" % i, refs, err)
	for i in c.get("people", []).size(): _check_person(c["people"][i], "people[%d]" % i, refs, err)
	for i in c.get("events", []).size(): _check_event(c["events"][i], "events[%d]" % i, refs, err)
	for i in c.get("tales", []).size(): _check_tale(c["tales"][i], "tales[%d]" % i, refs, err)
	return errs

static func _keys(e: Dictionary, allowed: Array, w: String, err: Callable) -> void:
	for k in e:
		if k not in COMMON and k not in allowed: err.call(w, "unknown key '%s'" % k)
	if not e.get("name", e.get("title", "")) is String or str(e.get("name", e.get("title", ""))) == "":
		err.call(w, "needs a 'name'" if not e.has("title") else "needs a 'title'")
	if e.has("history") and e["history"] not in HISTORY: err.call(w, "history must be one of %s" % ", ".join(HISTORY))

static func _check_invention(e, w: String, food: bool, refs: Dictionary, err: Callable) -> void:
	if not e is Dictionary: return
	_keys(e, INVENTION_KEYS, w, err)
	if not e.has("desc"): err.call(w, "needs a 'desc' saying what it does")
	if not food and e.get("kind", "tool") not in ["tool", "goods", "medicine"]: err.call(w, "kind must be tool, goods or medicine (foods go in 'foods')")
	if food and e.has("kind"): err.call(w, "foods have no 'kind'")
	var pr = e.get("practice", {})
	if not pr is Dictionary or pr.is_empty(): err.call(w, "needs 'practice': {activity: points}, e.g. {\"berry\": 200}")
	else:
		for a in pr:
			if not D.PRACTICE_NAMES.has(a): err.call(w, "unknown practice '%s' (one of %s)" % [a, ", ".join(D.PRACTICE_NAMES.keys())])
			elif not (pr[a] is float or pr[a] is int) or pr[a] <= 0: err.call(w, "practice '%s' must be a positive number" % a)
	var nd = e.get("needs", {})
	if not nd is Dictionary: err.call(w, "'needs' must be {\"techs\": [...], \"finds\": [...], \"inventions\": [...], \"era\": n}")
	else:
		for k in nd:
			match k:
				"techs": _refs(nd[k], refs["tech"], w + ".needs.techs", err)
				"finds": _refs(nd[k], refs["find"], w + ".needs.finds", err)
				"inventions": _refs(nd[k], refs["inv"], w + ".needs.inventions", err)
				"era":
					if not (nd[k] is float or nd[k] is int) or nd[k] < 1 or nd[k] > 3: err.call(w, "needs.era must be 1, 2 or 3")
				_: err.call(w, "unknown need '%s'" % k)
	_check_effects(e.get("effects", []), w + ".effects", err)
	if e.has("words") and (not e["words"] is Array): err.call(w, "'words' must be a list of words")

static func _check_find(e, w: String, refs: Dictionary, err: Callable) -> void:
	if not e is Dictionary: return
	_keys(e, FIND_KEYS, w, err)
	if not e.has("desc"): err.call(w, "needs a 'desc'")
	if e.get("group", "food") not in D.FIND_GROUPS: err.call(w, "group must be one of %s" % ", ".join(D.FIND_GROUPS.keys()))
	if e.get("res", "food") not in RESOURCES: err.call(w, "res must be one of %s" % ", ".join(RESOURCES))
	if e.get("where", "meadow") not in WHERE: err.call(w, "where must be one of %s" % ", ".join(WHERE))
	if e.get("needs", "") not in ["", "lore", "tools"]: err.call(w, "needs must be \"\", \"lore\" or \"tools\"")
	if not D.PRACTICE_NAMES.has(e.get("practice", "berry")): err.call(w, "unknown practice '%s'" % e.get("practice"))
	if not D.BASE_FINDS.has(e.get("look", "grain")): err.call(w, "look must be a base find (%s)" % ", ".join(D.BASE_FINDS.keys()))
	for k in ["amount", "rate", "regrow", "count", "practice_x", "cluster"]:
		if e.has(k) and (not (e[k] is float or e[k] is int) or e[k] < 0): err.call(w, "'%s' must be a number >= 0" % k)
	if int(e.get("count", 3)) > 8: err.call(w, "count above 8 floods the map")
	for t in e.get("seed", {}):
		if t not in refs["tech"]: err.call(w + ".seed", "unknown tech '%s'" % t)
	_check_axes(e.get("culture", {}), w + ".culture", err)
	_check_effects(e.get("effects", []), w + ".effects", err)

static func _check_person(e, w: String, refs: Dictionary, err: Callable) -> void:
	if not e is Dictionary: return
	_keys(e, PERSON_KEYS, w, err)
	if not e.has("desc"): err.call(w, "needs a 'desc' (who they were)")
	var a: String = e.get("as", "ancestor")
	if a not in PERSON_AS: err.call(w, "as must be one of %s" % ", ".join(PERSON_AS))
	if a == "wanderer" and not e.has("when"): err.call(w, "a wanderer needs 'when' (the conditions for arriving)")
	var st = e.get("stats", {})
	if not st is Dictionary: err.call(w, "'stats' must be an object")
	else:
		for k in st:
			match k:
				"traits":
					if not st[k] is Array or st[k].is_empty(): err.call(w, "stats.traits must be a list")
					else:
						for t in st[k]:
							if not D.TRAITS.has(t): err.call(w, "unknown trait '%s' (one of %s)" % [t, ", ".join(D.TRAITS.keys())])
				"skills":
					if not st[k] is Dictionary: err.call(w, "stats.skills must be {skill: level}")
					else:
						for s in st[k]:
							if s not in D.SKILLS: err.call(w, "unknown skill '%s' (one of %s)" % [s, ", ".join(D.SKILLS)])
							elif not (st[k][s] is float or st[k][s] is int) or st[k][s] < 0 or st[k][s] > 9: err.call(w, "skill '%s' must be 0..9" % s)
				"hp", "atk", "def", "spd":
					if not (st[k] is float or st[k] is int) or st[k] <= 0: err.call(w, "stats.%s must be a positive number" % k)
				"color":
					if not st[k] is String or not Color.html_is_valid(st[k]): err.call(w, "stats.color must be like \"#c9a36b\"")
				_: err.call(w, "unknown stat '%s'" % k)
	if e.has("memory") and (not e["memory"] is Array or e["memory"].any(func(m): return not m is String)):
		err.call(w, "'memory' must be a list of texts (each starts with a past-tense verb: \"tamed the flood\")")
	_check_when(e.get("when", {}), w + ".when", refs, err)

static func _check_event(e, w: String, refs: Dictionary, err: Callable) -> void:
	if not e is Dictionary: return
	_keys(e, EVENT_KEYS, w, err)
	if not e.get("text") is String: err.call(w, "needs a 'text'")
	if not e.has("when"): err.call(w, "needs 'when' (the conditions for it to happen)")
	_check_when(e.get("when", {}), w + ".when", refs, err)
	_check_chance(e, w, err)
	_check_options(e.get("options", []), w, refs, err)
	_check_do(e.get("do", []), w + ".do", refs, err)

static func _check_options(opts, w: String, refs: Dictionary, err: Callable) -> void:
	if not opts is Array or opts.size() > 4: err.call(w, "'options' must be a list of up to 4 choices")
	elif opts.size() == 1: err.call(w, "a dilemma needs at least 2 options (or none for a chronicle event)")
	else:
		for i in opts.size():
			var o = opts[i]
			var ow := "%s.options[%d]" % [w, i]
			if not o is Dictionary or not o.get("label") is String:
				err.call(ow, "needs a 'label'")
				continue
			for k in o:
				if k not in OPTION_KEYS: err.call(ow, "unknown key '%s'" % k)
			for r in o.get("cost", {}):
				if r not in RESOURCES: err.call(ow, "cost: unknown resource '%s'" % r)
			var nd = o.get("needs", {})
			if not nd is Dictionary or (nd.has("best") and nd["best"] not in D.SKILLS) or (nd.has("or_tech") and nd["or_tech"] not in refs["tech"]):
				err.call(ow, "needs must be {\"best\": skill, \"lv\": n, \"or_tech\": tech}")
			_check_do(o.get("do", []), ow + ".do", refs, err)
			_check_do(o.get("else_do", []), ow + ".else_do", refs, err)

## Problems in a dilemma posed from outside (story.pose()), against what the game has now.
static func check_dilemma(e) -> Array:
	var errs: Array = []
	var err := func(where: String, msg: String): errs.append("%s: %s" % [where, msg])
	if not e is Dictionary: return ["the dilemma must be an object"]
	var cult: Dictionary = D.CULTURE if D.CULTURE is Dictionary else {}
	var ids := func(sec): return cult.get(sec, []).map(func(x): return str(x.get("id", "")))
	var refs := {"inv": D.INVENTIONS.map(func(d): return d["id"]), "find": D.FINDS.keys(), "tech": D.TECHS.map(func(t): return t["id"]),
		"tale": ids.call("tales"), "person": ids.call("people"), "event": ids.call("events")}
	_keys(e, ["title", "text", "speaker", "speaker_default", "options"], "dilemma", err)
	if not e.get("title") is String or not e.get("text") is String: err.call("dilemma", "needs a 'title' and a 'text'")
	if str(e.get("speaker", "best:lore")).trim_prefix("best:") not in D.SKILLS: err.call("dilemma", "speaker must be \"best:<skill>\"")
	if e.get("options", []).is_empty(): err.call("dilemma", "needs 'options'")
	else: _check_options(e["options"], "dilemma", refs, err)
	return errs

static func _check_tale(e, w: String, refs: Dictionary, err: Callable) -> void:
	if not e is Dictionary: return
	_keys(e, TALE_KEYS, w, err)
	if not e.get("text") is String or e["text"].length() < 20: err.call(w, "needs the tale's 'text'")
	if e.get("tell", "night") not in ["night", "festival", "event"]: err.call(w, "tell must be night, festival or event")
	_check_when(e.get("when", {}), w + ".when", refs, err)
	_check_do(e.get("do", []), w + ".do", refs, err)

static func _check_chance(e: Dictionary, w: String, err: Callable) -> void:
	if e.has("chance") and (not (e["chance"] is float or e["chance"] is int) or e["chance"] <= 0 or e["chance"] > 1):
		err.call(w, "chance (per day) must be in (0, 1]")

static func _check_when(wd, w: String, refs: Dictionary, err: Callable) -> void:
	if not wd is Dictionary:
		err.call(w, "must be an object of conditions")
		return
	for k in wd:
		if k not in WHEN_KEYS:
			err.call(w, "unknown condition '%s' (one of %s)" % [k, ", ".join(WHEN_KEYS)])
			continue
		var v = wd[k]
		match k:
			"tech":
				if v not in refs["tech"]: err.call(w, "unknown tech '%s'" % v)
			"invention":
				if v not in refs["inv"]: err.call(w, "unknown invention '%s'" % v)
			"find":
				if v not in refs["find"]: err.call(w, "unknown find '%s'" % v)
			"told":
				if v not in refs["tale"]: err.call(w, "unknown tale '%s'" % v)
			"joined":
				if v not in refs["person"]: err.call(w, "unknown person '%s'" % v)
			"happened":
				if v not in refs["event"]: err.call(w, "unknown event '%s'" % v)
			"season":
				if v not in SEASONS: err.call(w, "season must be one of %s" % ", ".join(SEASONS))
			"built":
				if not D.STRUCTURES.has(v): err.call(w, "unknown structure '%s'" % v)
			"culture": _check_axes(v, w + ".culture", err)
			"time", "day", "pop", "era", "devotion", "mood", "deaths":
				if not (v is float or v is int): err.call(w, "'%s' must be a number" % k)

static func _check_do(list, w: String, refs: Dictionary, err: Callable) -> void:
	if not list is Array:
		err.call(w, "must be a list of actions")
		return
	for i in list.size():
		var a = list[i]
		var aw := "%s[%d]" % [w, i]
		if not a is Dictionary:
			err.call(aw, "must be an object")
			continue
		for k in a:
			if k not in DO_KEYS: err.call(aw, "unknown action '%s' (one of %s)" % [k, ", ".join(DO_KEYS)])
		if a.has("event"): err.call(aw, "culture actions can't start built-in events")
		if a.has("weather") and not preload("res://scripts/config.gd").load_cfg("events")["weather"]["kinds"].has(a["weather"]): err.call(aw, "unknown weather '%s'" % a["weather"])
		if a.has("react") and not preload("res://scripts/config.gd").load_cfg("reactions")["on"].has(a["react"]): err.call(aw, "unknown reaction event '%s'" % a["react"])
		if a.has("panic") and not (a["panic"] is float or a["panic"] is int): err.call(aw, "panic must be a number of seconds")
		if a.has("spawn") and a["spawn"] not in ["wolf", "tiger"]: err.call(aw, "spawn must be \"wolf\" or \"tiger\"")
		for off in a.get("offsets", []):
			if not off is Array or off.size() != 2: err.call(aw, "offsets must be a list of [x, y] pairs")
		for r in a.get("give", {}):
			if r not in RESOURCES: err.call(aw, "give: unknown resource '%s'" % r)
		for t in a.get("insight", {}):
			if t not in refs["tech"]: err.call(aw, "insight: unknown tech '%s'" % t)
		_check_axes(a.get("culture", {}), aw + ".culture", err)
		if a.has("invent") and a["invent"] not in refs["inv"]: err.call(aw, "unknown invention '%s'" % a["invent"])
		if a.has("tale") and a["tale"] not in refs["tale"]: err.call(aw, "unknown tale '%s'" % a["tale"])
		if a.has("join") and a["join"] not in refs["person"]: err.call(aw, "unknown person '%s'" % a["join"])
		if a.has("boon"): _check_effects(a["boon"], aw + ".boon", err)
		var who: String = str(a.get("who", "all"))
		if who != "all" and not (who.begins_with("best:") and who.substr(5) in D.SKILLS): err.call(aw, "who must be \"all\" or \"best:<skill>\"")

static func _check_axes(v, w: String, err: Callable) -> void:
	if not v is Dictionary:
		err.call(w, "must be {axis: amount}")
		return
	for ax in v:
		if not D.CULTURE_AXES.has(ax): err.call(w, "unknown culture axis '%s' (one of %s)" % [ax, ", ".join(D.CULTURE_AXES.keys())])

static func _check_effects(list, w: String, err: Callable) -> void:
	if not list is Array:
		err.call(w, "must be a list of effects")
		return
	for i in list.size():
		var e = list[i]
		var ew := "%s[%d]" % [w, i]
		if not e is Dictionary or not D.EFFECT_STATS.has(e.get("stat", "")):
			err.call(ew, "unknown stat '%s' (one of %s)" % [e.get("stat", "") if e is Dictionary else "", ", ".join(D.EFFECT_STATS.keys())])
			continue
		var op: String = D.EFFECT_STATS[e["stat"]][0]
		if not e.has(op) or not (e[op] is float or e[op] is int): err.call(ew, "'%s' takes \"%s\": <number>" % [e["stat"], op])
		for k in e:
			if k not in ["stat", op, "of"]: err.call(ew, "unknown key '%s'" % k)
		if op == "mul" and e.has("mul") and (e["mul"] <= 0 or e["mul"] > 3): err.call(ew, "mul must be in (0, 3]")

static func _refs(v, known: Array, w: String, err: Callable) -> void:
	if not v is Array:
		err.call(w, "must be a list")
		return
	for x in v:
		if x not in known: err.call(w, "unknown id '%s'" % x)

# ------------------------------------------------------------ texts (for translation)
## Every player-visible text of a pack (English keys that zh.json must translate).
static func texts(c: Dictionary) -> Array:
	var out: Array = []
	var add := func(s):
		if s is String and s != "" and s not in out: out.append(s)
	for k in ["name", "desc", "place", "period", "source"]: add.call(c.get(k, ""))
	for k in ["tribe_names", "birth_names"]:
		for n in c.get(k, []): add.call(n)
	for k in ["epithets", "memories"]:
		for t in c.get(k, {}):
			for s in c[k][t]: add.call(s)
	for sec in ["inventions", "foods", "finds", "people", "events", "tales"]:
		for e in c.get(sec, []):
			for k in ["name", "title", "desc", "hint", "source", "text", "epithet", "label", "moral"]: add.call(e.get(k, ""))
			if sec == "finds": add.call(_find(e)["act"])
			if sec == "people":
				for m in e.get("memory", []): add.call(m)
				if e.get("as", "") == "chosen": add.call(person_def(e)["label"])
			for a in e.get("do", []): _do_texts(a, add)
			for o in e.get("options", []):
				for k in ["label", "desc", "result"]: add.call(o.get(k, ""))
				for a in o.get("do", []): _do_texts(a, add)
	return out

static func _do_texts(a: Dictionary, add: Callable) -> void:
	for k in ["log", "alert", "remember", "feat"]: add.call(a.get(k, ""))

## The texts of a pack that neither zh.json nor the game's table translates (or translates with the %s/%d
## placeholders out of order).
static func missing_zh(c: Dictionary) -> Array:
	var zh: Dictionary = c.get("zh", {})
	var ph := RegEx.create_from_string("%[-+0-9.]*[dsf]")
	var out: Array = []
	for t in texts(c):
		if I.ZH.STRINGS.has(t): continue # (the game's own table already has it)
		if not zh.has(t) or str(zh[t]) == "": out.append(t)
		elif ph.search_all(t).map(func(m): return m.get_string()) != ph.search_all(str(zh[t])).map(func(m): return m.get_string()):
			out.append(t + "  (placeholders differ)")
	return out
