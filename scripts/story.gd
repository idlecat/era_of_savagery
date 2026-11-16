## Scenario scripts: the triggers a hand-made map brings along (D.SCRIPT). Random maps
## have none. A trigger is {"when": {...}, "do": [...]} and fires once when every test in
## "when" holds; "each": true fires once per matching contract instead; "toggle": "<sim
## var>" skips it while that sim flag is off (e.g. "scripted_ambush").
##   when: time (s), day, pop (living at least), contract (kind) + progress (0..1),
##         found (landmark id), met (clan id), flag (sim.flags key), tech, invention,
##         find (known), era (at least), season ("Spring".."Winter"), built (structure
##         type), devotion / mood (at least), deaths (dead at least), after (an event that
##         has happened: "flood", "eclipse", "eruption", "festival", "chosen", "era2"...),
##         culture {axis: value} (at least, or at most for a negative value),
##         told (tale id), joined (person id), happened (culture event id)
##   do:   {"event": id} a dilemma (sim.event_def), {"log": text, "kind", "arg": "plan"},
##         {"alert": text, "at", "level"}, {"spawn": "tiger"|"wolf", "at", "offsets"},
##         {"give": {res: n}} (negative takes), {"reveal": at, "r"}, {"flag": name},
##         {"mood": n}, {"devotion": n}, {"insight": {tech: fraction}}, {"culture": {axis: n}},
##         {"invent": invention id}, {"boon": [effects]} (lasting, see D.EFFECT_STATS),
##         {"remember": text, "who": "all"|"best:<skill>"} ("%d" in it is the day), {"feat": text},
##         {"xp": {skill: n}, "who"}, {"panic": seconds} (the people hide: reactions "panic"),
##         {"weather": kind} (config/events.json weather.kinds), {"react": event, "at"} (sim.react),
##         {"tale": tale id} (told now), {"join": person id} (a culture's people arrive)
## The culture system (culture.gd) runs its events and tales through holds() and run() too.
##
## Dilemmas share one data format, run by dilemma_view()/dilemma_choose() for culture
## packs, the forces of nature (config/events.json) and anything posed from outside
## (pose(): a game master): {title, text, speaker: "best:<skill>", options: [{label, desc,
## cost: {res: n}, needs: {"best": skill, "lv": n, "or_tech": id}, do: [actions], result,
## else_do, else_result}]}. "%s" in the text, labels and results is the speaker's name. An
## option whose "needs" are not met runs else_do/else_result instead; one the tribe can't
## pay for is disabled (and if chosen anyway, the last option runs).
##   at:   "site" (the contract's), "village", a landmark id, or a Vector2
## Texts are English translation keys, translated when shown.
extends RefCounted

const D = preload("res://scripts/data.gd")

var sim
var triggers: Array = []
var fired := {} # trigger index (or "index:contract id") -> true
var pending: Array = [] # dilemmas waiting for sim._check_events
var posed := {} # "posed:<id>" -> dilemma def (from pose())
var _t := 0.0

func _init(s) -> void:
	sim = s

func setup(list: Array) -> void:
	triggers = list.duplicate(true)
	fired = {}
	pending = []

func tick(dt: float) -> void:
	_t -= dt
	if _t > 0.0 or triggers.is_empty(): return
	_t = 0.5
	for i in triggers.size():
		var tg: Dictionary = triggers[i]
		if tg.has("toggle") and not bool(sim.get(tg["toggle"])): continue
		var w: Dictionary = tg.get("when", {})
		if w.has("contract"):
			for c in sim.contracts.list:
				var key := "%d:%d" % [i, c.id]
				if fired.has(key) or (fired.has(str(i)) and not tg.get("each", false)): continue
				if c.kind != w["contract"] or not sim.contracts.is_running(c) or c.progress < float(w.get("progress", 0.0)): continue
				if not holds(w): continue
				fired[key] = true
				fired[str(i)] = true
				run(tg["do"], c)
		elif not fired.has(str(i)) and holds(w):
			fired[str(i)] = true
			run(tg["do"], null)

func holds(w: Dictionary) -> bool:
	if w.has("time") and sim.time < float(w["time"]): return false
	if w.has("day") and sim.day() < int(w["day"]): return false
	if w.has("pop") and sim.living().size() < int(w["pop"]): return false
	if w.has("flag") and not sim.flags.has(w["flag"]): return false
	if w.has("found") and not sim.landmarks.any(func(l): return l["id"] == w["found"] and l["found"]): return false
	if w.has("met"):
		var c: Dictionary = sim.rivals.clans.get(w["met"], {})
		if c.is_empty() or not c["met"]: return false
	if w.has("tech") and not sim.has_tech(w["tech"]): return false
	if w.has("invention") and not sim.inv.has(w["invention"]): return false
	if w.has("find") and not sim.knows_find(w["find"]): return false
	if w.has("era") and sim.evo.era < int(w["era"]): return false
	if w.has("season") and (not sim.hz.on() or sim.hz.season() != w["season"]): return false
	if w.has("built") and not sim.structures.any(func(st): return st.built and sim.ours(st) and st.type == w["built"]): return false
	if w.has("devotion") and sim.devotion < float(w["devotion"]): return false
	if w.has("mood") and sim.folk.mood < float(w["mood"]): return false
	if w.has("deaths") and sim.units.filter(func(u): return u.dead).size() < int(w["deaths"]): return false
	if w.has("culture"):
		for ax in w["culture"]:
			var v := float(w["culture"][ax])
			var have: float = sim.evo.culture.get(ax, 0.0)
			if (v >= 0.0 and have < v) or (v < 0.0 and have > v): return false
	var cu = sim.cult
	if w.has("after") and not (cu and cu.seen.has(w["after"])): return false
	if w.has("told") and not (cu and cu.told.has(w["told"])): return false
	if w.has("joined") and not (cu and cu.joined.has(w["joined"])): return false
	if w.has("happened") and not (cu and cu.fired.has(w["happened"])): return false
	return true

func _at(where: Variant, c) -> Vector2:
	if where is Vector2: return where
	if where is Array and where.size() == 2: return Vector2(where[0], where[1]) # (from JSON)
	match str(where):
		"site": return c.site if c else D.VILLAGE
		"village": return D.VILLAGE
	for lm in sim.landmarks:
		if lm["id"] == str(where): return lm["pos"]
	return D.VILLAGE

func run(actions: Array, c) -> void:
	for a in actions:
		if a.has("event"):
			if not sim.flags.has(a["event"]): # (also lets a demo switch an event off)
				sim.flags[a["event"]] = true
				pending.append(a["event"])
		if a.has("log"):
			var text: String = tr(a["log"])
			if a.get("arg", "") == "plan" and c: text = text % c.plan["plan_id"]
			sim.add_log(text, a.get("kind", "story"))
		if a.has("alert"):
			sim.alert(tr(a["alert"]), _at(a.get("at", "village"), c), a.get("level", "warn"))
		if a.has("spawn"):
			var base := _at(a.get("at", "village"), c)
			if c: c.ambushed = true
			for off in a.get("offsets", [Vector2.ZERO]):
				var p: Vector2 = base + (Vector2(off[0], off[1]) if off is Array else off) # (JSON gives [x, y])
				p = Vector2(clampf(p.x, 30, D.W - 30), clampf(p.y, 40, D.H - 40))
				if a["spawn"] == "wolf":
					var w = sim.spawn_predator(p, base)
					sim.hz.make_wolf(w)
				else:
					sim.spawn_predator(p, base)
		if a.has("give"):
			for r in a["give"]: sim.stock[r] = maxf(0.0, sim.stock.get(r, 0.0) + float(a["give"][r]))
		if a.has("reveal"):
			sim.reveal(_at(a["reveal"], c), float(a.get("r", 400.0)))
		if a.has("flag"):
			sim.flags[a["flag"]] = true
		if a.has("mood"): sim.folk.lift(float(a["mood"]))
		if a.has("devotion"): sim.devotion = clampf(sim.devotion + float(a["devotion"]), 0.0, 100.0)
		for t in a.get("insight", {}): sim.evo.seed(t, float(a["insight"][t]), sim.best_unit("lore", false))
		for ax in a.get("culture", {}): sim.evo.drift(ax, float(a["culture"][ax]))
		if a.has("invent") and not sim.inv.has(a["invent"]) and not sim.inv.def(a["invent"]).is_empty():
			sim.inv.discover(a["invent"], sim.best_unit("craft", false))
		if a.has("boon") and sim.cult: sim.cult.add_boon(a["boon"])
		if a.has("remember"):
			var who: String = a.get("who", "all")
			var people: Array = sim.living().filter(func(u): return u.role != "child")
			if who.begins_with("best:"):
				var b = sim.best_unit(who.substr(5), false)
				people = [b] if b else []
			var mem: String = tr(a["remember"])
			if mem.contains("%d"): mem = mem % sim.day()
			for u in people: sim.remember(u, mem, int(a.get("impact", 6)))
		if a.has("xp"):
			var who2: String = a.get("who", "all")
			var crew: Array = sim.living().filter(func(u): return u.role != "child")
			if who2.begins_with("best:"):
				var b2 = sim.best_unit(who2.substr(5), false)
				crew = [b2] if b2 else []
			for u in crew:
				for k in a["xp"]: sim.gain_xp(u, k, float(a["xp"][k]))
		if a.has("panic"):
			sim.nat.panic_until = maxf(sim.nat.panic_until, sim.time + float(a["panic"]))
			sim.react.trigger("panic", {"at": D.VILLAGE, "until": sim.nat.panic_until})
		if a.has("weather"): sim.hz.set_weather(str(a["weather"]))
		if a.has("react"): sim.react.trigger(str(a["react"]), {"at": _at(a.get("at", "village"), c)})
		if a.has("feat"): sim.inv.feat("story", tr(a["feat"]))
		if a.has("tale") and sim.cult: sim.cult.tell(a["tale"])
		if a.has("join") and sim.cult: sim.cult.join(a["join"])

# ------------------------------------------------------------ dilemmas (the shared format)
## The speaker of a dilemma ("best:<skill>"), or null.
func speaker(ev: Dictionary) -> Variant:
	var sp: String = str(ev.get("speaker", ""))
	return sim.best_unit(sp.substr(5), false) if sp.begins_with("best:") else null

func _say(text: String, ev: Dictionary) -> String:
	var t: String = tr(text)
	if not t.contains("%s") or not ev.has("speaker"): return t
	var u = speaker(ev)
	return t % (tr(u.name) if u else tr(ev.get("speaker_default", "The elders")))

func affords(o: Dictionary) -> bool:
	for r in o.get("cost", {}):
		if sim.stock.get(r, 0.0) < float(o["cost"][r]): return false
	return true

## Are an option's "needs" met (else it runs else_do)? A need for a "best" person also
## disables the option when there is nobody at all.
func needs_met(o: Dictionary) -> bool:
	var nd: Dictionary = o.get("needs", {})
	if nd.is_empty(): return true
	if nd.has("or_tech") and sim.has_tech(nd["or_tech"]): return true
	var b = sim.best_unit(str(nd.get("best", "lore")), false)
	return b != null and b.lv(str(nd.get("best", "lore"))) >= int(nd.get("lv", 0))

func _opt_desc(o: Dictionary) -> String:
	var parts: Array = []
	if o.has("desc"): parts.append(tr(o["desc"]))
	var cost: Dictionary = o.get("cost", {})
	if not cost.is_empty():
		parts.append(tr("Costs %s.") % ", ".join(cost.keys().map(func(r): return "%d %s" % [int(cost[r]), tr(r)])))
	return " ".join(parts)

## What the HUD shows: {title, text, options: [{label, desc, enabled}]}.
func dilemma_view(ev: Dictionary) -> Dictionary:
	var opts: Array = []
	for o in ev.get("options", []):
		var ok := affords(o)
		if o.has("needs") and not o["needs"].has("or_tech"): ok = ok and sim.best_unit(str(o["needs"].get("best", "lore")), false) != null
		opts.append({"label": _say(o["label"], ev), "desc": _opt_desc(o), "enabled": ok})
	return {"title": _say(ev.get("title", ""), ev), "text": _say(ev.get("text", ""), ev), "options": opts}

## Choose option idx: pay, run its actions, and return {"text": result, "option": the
## option chosen}.
func dilemma_choose(ev: Dictionary, idx: int) -> Dictionary:
	var opts: Array = ev.get("options", [])
	if opts.is_empty(): return {"text": "", "option": {}}
	var o: Dictionary = opts[clampi(idx, 0, opts.size() - 1)]
	if not affords(o): o = opts.back() # (can't pay: the last choice, usually "do nothing")
	for r in o.get("cost", {}): sim.stock[r] -= float(o["cost"][r])
	var good := needs_met(o)
	run(o.get("do", []) if good else o.get("else_do", []), null)
	var res: String = o.get("result", "") if good else o.get("else_result", o.get("result", ""))
	return {"text": _say(res, ev) if res != "" else tr("The tribe chose: %s.") % _say(o["label"], ev), "option": o}

## Pose a dilemma from outside the rules (a game master): it is checked like a culture
## pack's event and queued. Returns the problems found ([] = posed).
func pose(id: String, ev: Dictionary) -> Array:
	var problems: Array = preload("res://scripts/cultures.gd").check_dilemma(ev)
	if not id.is_valid_identifier(): problems.append("id must be a plain identifier")
	if posed.has("posed:" + id): problems.append("a dilemma '%s' was already posed" % id)
	if not problems.is_empty(): return problems
	posed["posed:" + id] = ev.duplicate(true)
	pending.append("posed:" + id)
	return []

func owns_event(id: String) -> bool: return posed.has(id)
func event_def(id: String) -> Dictionary: return dilemma_view(posed[id])
func resolve(id: String, idx: int) -> String:
	var ev: Dictionary = posed[id]
	var out := dilemma_choose(ev, idx)
	sim.inv.feat("story", "%s: %s" % [_say(ev.get("title", ""), ev), _say(out["option"].get("label", ""), ev)], null, {"desc": out["text"]})
	return out["text"]
