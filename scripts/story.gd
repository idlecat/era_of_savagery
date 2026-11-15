## Scenario scripts: the triggers a hand-made map brings along (D.SCRIPT). Random maps
## have none. A trigger is {"when": {...}, "do": [...]} and fires once when every test in
## "when" holds; "each": true fires once per matching contract instead; "toggle": "<sim
## var>" skips it while that sim flag is off (e.g. "scripted_ambush").
##   when: time (s), day, pop (living at least), contract (kind) + progress (0..1),
##         found (landmark id), met (clan id), flag (sim.flags key)
##   do:   {"event": id} a dilemma (sim.event_def), {"log": text, "kind", "arg": "plan"},
##         {"alert": text, "at", "level"}, {"spawn": "tiger"|"wolf", "at", "offsets"},
##         {"give": {res: n}}, {"reveal": at, "r"}, {"flag": name}
##   at:   "site" (the contract's), "village", a landmark id, or a Vector2
## Texts are English translation keys, translated when shown.
extends RefCounted

const D = preload("res://scripts/data.gd")

var sim
var triggers: Array = []
var fired := {} # trigger index (or "index:contract id") -> true
var pending: Array = [] # dilemmas waiting for sim._check_events
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
				if not _holds(w): continue
				fired[key] = true
				fired[str(i)] = true
				_run(tg["do"], c)
		elif not fired.has(str(i)) and _holds(w):
			fired[str(i)] = true
			_run(tg["do"], null)

func _holds(w: Dictionary) -> bool:
	if w.has("time") and sim.time < float(w["time"]): return false
	if w.has("day") and sim.day() < int(w["day"]): return false
	if w.has("pop") and sim.living().size() < int(w["pop"]): return false
	if w.has("flag") and not sim.flags.has(w["flag"]): return false
	if w.has("found") and not sim.landmarks.any(func(l): return l["id"] == w["found"] and l["found"]): return false
	if w.has("met"):
		var c: Dictionary = sim.rivals.clans.get(w["met"], {})
		if c.is_empty() or not c["met"]: return false
	return true

func _at(where: Variant, c) -> Vector2:
	if where is Vector2: return where
	match str(where):
		"site": return c.site if c else D.VILLAGE
		"village": return D.VILLAGE
	for lm in sim.landmarks:
		if lm["id"] == str(where): return lm["pos"]
	return D.VILLAGE

func _run(actions: Array, c) -> void:
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
				var p: Vector2 = base + off
				p = Vector2(clampf(p.x, 30, D.W - 30), clampf(p.y, 40, D.H - 40))
				if a["spawn"] == "wolf":
					var w = sim.spawn_predator(p, base)
					sim.hz.make_wolf(w)
				else:
					sim.spawn_predator(p, base)
		if a.has("give"):
			for r in a["give"]: sim.stock[r] = sim.stock.get(r, 0.0) + float(a["give"][r])
		if a.has("reveal"):
			sim.reveal(_at(a["reveal"], c), float(a.get("r", 400.0)))
		if a.has("flag"):
			sim.flags[a["flag"]] = true
