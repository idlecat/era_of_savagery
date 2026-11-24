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
	if not bad_keys(w, COND_TYPES).is_empty(): return false # (a malformed condition never holds)
	if w.has("time") and sim.time < float(w["time"]): return false
	if w.has("day") and sim.day() < int(w["day"]): return false
	if w.has("pop") and sim.living().size() < int(w["pop"]): return false
	if w.has("flag") and not sim.flags.has(w["flag"]): return false
	if w.has("found") and not sim.landmarks.any(func(l): return l["id"] == w["found"] and l["found"]): return false
	if w.has("met_any") and bool(w["met_any"]) != sim.rivals.clans.values().any(func(c): return c["met"]): return false
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
	if w.has("food_frac") and sim.stock["food"] < sim.food_cap() * float(w["food_frac"]): return false
	if w.has("homeless") and sim.living().size() - sim.pop_cap() < int(w["homeless"]): return false
	if w.has("wood") and sim.stock["wood"] < float(w["wood"]): return false
	if w.has("fewer"): # fewer than n of a structure of ours, building sites included
		for st in w["fewer"]:
			if sim.structures.filter(func(s): return s.type == st and sim.ours(s)).size() >= int(w["fewer"][st]): return false
	if w.has("deaths") and sim.units.filter(func(u): return u.dead and not u.gone).size() < int(w["deaths"]): return false
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

func _at(where: Variant, c, vars: Dictionary = {}) -> Vector2:
	if where is Vector2: return where
	if where is Array and where.size() == 2: return Vector2(where[0], where[1]) # (from JSON)
	if vars.get(str(where)) is Vector2: return vars[str(where)]
	match str(where):
		"site": return c.site if c else D.VILLAGE
		"village": return D.VILLAGE
	for lm in sim.landmarks:
		if lm["id"] == str(where): return lm["pos"]
	return D.VILLAGE

## Every action run() knows (culture packs may use Cultures.DO_KEYS, a subset; the rule
## configs in config/ may use them all).
const ACTIONS := ["event", "log", "arg", "kind", "alert", "at", "level", "spawn", "offsets", "give", "reveal", "r", "flag",
	"mood", "devotion", "insight", "culture", "invent", "boon", "remember", "who", "impact", "xp", "panic", "weather",
	"react", "feat", "tale", "join", "great_flood", "open", "hurt", "chosen", "festival", "births", "guests",
	"relation", "reason", "clan", "raid", "raid_delay_days", "vassal", "relation_min", "relation_max", "clear_treaties",
	"grudge", "peace_days", "clan_pop", "sound", "morale", "bond", "with", "say", "depart"]

## What each action key and condition key takes. Input from outside (a scenario, a config,
## a game master) is checked against these before it runs: an action with a value of the wrong
## type is skipped, a condition with one never holds. num: a finite number within ±1e6;
## nums: {id: num}; text: a key or [key, var names...]; pos: [x, y], a Vector2 or a place name.
const ACTION_TYPES := {"event": "str", "log": "text", "arg": "str", "kind": "str", "alert": "text", "at": "pos", "level": "str",
	"spawn": "str", "offsets": "positions", "give": "nums", "reveal": "pos", "r": "num", "flag": "str", "mood": "num", "devotion": "num",
	"insight": "nums", "culture": "nums", "invent": "str", "boon": "effects", "remember": "text", "who": "str", "impact": "num", "xp": "nums",
	"panic": "num", "weather": "str", "react": "str", "feat": "str", "tale": "str", "join": "str", "great_flood": "any", "open": "str",
	"hurt": "num", "chosen": "num", "festival": "dict", "births": "num", "guests": "num", "relation": "num", "reason": "text",
	"clan": "str", "raid": "any", "raid_delay_days": "num", "vassal": "num", "relation_min": "num", "relation_max": "num",
	"clear_treaties": "any", "grudge": "text", "peace_days": "num", "clan_pop": "num", "sound": "str", "morale": "num", "bond": "num",
	"with": "str", "say": "text", "depart": "any"}
const COND_TYPES := {"contract": "any", "time": "num", "day": "num", "pop": "num", "flag": "str", "found": "str", "met_any": "bool",
	"met": "str", "tech": "str", "invention": "str", "find": "str", "era": "num", "season": "str", "built": "str", "devotion": "num",
	"mood": "num", "food_frac": "num", "homeless": "num", "wood": "num", "fewer": "nums", "deaths": "num", "culture": "nums",
	"after": "str", "told": "str", "joined": "str", "happened": "str"}

static func _num_ok(v) -> bool:
	return (v is int or v is float) and not is_nan(float(v)) and absf(float(v)) <= 1e6

static func _pos_ok(v) -> bool:
	if v is Vector2: return v.is_finite()
	if v is Array: return v.size() == 2 and _num_ok(v[0]) and _num_ok(v[1])
	return v is String

## Whether `v` is of `kind` (see ACTION_TYPES).
static func type_ok(v, kind: String) -> bool:
	match kind:
		"num": return _num_ok(v)
		"str": return v is String or v is StringName
		"bool": return v is bool
		"dict": return v is Dictionary
		"list": return v is Array
		"nums":
			if not v is Dictionary: return false
			for k in v:
				if not k is String or not _num_ok(v[k]): return false
			return true
		"text": return v is String or (v is Array and not v.is_empty() and v.all(func(x): return x is String))
		"pos": return _pos_ok(v)
		"effects": return v is Array and v.all(func(e): return e is Dictionary and str(e.get("stat", "")) in D.EFFECT_STATS \
			and (e.has("mul") or e.has("add")) and _num_ok(e.get("mul", 1.0)) and _num_ok(e.get("add", 0.0)) and e.get("of", "") is String)
		"positions": return v is Array and v.all(func(x): return _pos_ok(x) and not x is String)
	return true

## The keys of `d` whose values are not of the type `types` gives them (unknown keys are fine:
## they are ignored by whoever reads `d`).
static func bad_keys(d: Dictionary, types: Dictionary) -> Array:
	return d.keys().filter(func(k): return types.has(k) and not type_ok(d[k], types[k]))

## A text: an English key, or [key, var names...] filled from `vars` (GDScript % is
## positional: the names are in the key's placeholder order).
func text(v, vars: Dictionary = {}) -> String:
	if v is Array:
		if v.is_empty(): return ""
		var key: String = tr(str(v[0]))
		var args: Array = v.slice(1).map(func(n): return vars.get(n, ""))
		if args.is_empty() or key.replace("%%", "").count("%") != args.size(): return key # (a key that doesn't fit its names is shown as it is)
		return key % args
	return tr(str(v))

## The people an action is for: "all" (grown-ups), "best:<skill>", "fighters:<n>" (the
## n hardest hitters at home), "name:<name>", "id:<n>" (one person, a child too), or
## "$<var>": the value of a var of the moment (e.g. a dilemma's "who").
func people(who: String, vars: Dictionary = {}) -> Array:
	if who.begins_with("$"):
		who = str(vars.get(who.substr(1), ""))
		if who == "": return [] # (an unknown var is nobody, never everyone)
	if who.begins_with("name:") or who.begins_with("id:"):
		var one = sim.unit_by_name(who.substr(5)) if who.begins_with("name:") else sim.unit_by_id(int(who.substr(3)))
		return [one] if one != null and not one.dead else []
	var out: Array = sim.living().filter(func(u): return u.role != "child")
	if who.begins_with("best:"):
		var b = sim.best_unit(who.substr(5), false)
		return [b] if b else []
	if who.begins_with("fighters:"):
		out = out.filter(func(u): return u.role != "contract")
		out.sort_custom(func(a, b): return sim.unit_atk(a) > sim.unit_atk(b))
		return out.slice(0, int(who.substr(9)))
	return out

## Run actions. `vars` are the named values of the moment (a dilemma's clan, festival...);
## actions may add to them (e.g. "chosen" sets chosen_name for the result text).
func run(actions: Array, c, vars: Dictionary = {}) -> void:
	for a in actions:
		if not a is Dictionary or not bad_keys(a, ACTION_TYPES).is_empty():
			push_warning("story.run: skipped malformed action %s" % str(a).left(200))
			continue
		if a.has("event"):
			if not sim.flags.has(a["event"]): # (also lets a demo switch an event off)
				sim.flags[a["event"]] = true
				pending.append(a["event"])
		if a.has("log"):
			var t: String = text(a["log"], vars)
			if a.get("arg", "") == "plan" and c: t = t % sim.contracts.title(c.plan)
			sim.add_log(t, a.get("kind", "story"))
		if a.has("alert"):
			sim.alert(text(a["alert"], vars), _at(a.get("at", "village"), c, vars), a.get("level", "warn"))
		if a.has("spawn"):
			var base := _at(a.get("at", "village"), c, vars)
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
			if a["give"] is Dictionary: sim.give(a["give"])
		if a.has("reveal"):
			sim.reveal(_at(a["reveal"], c, vars), float(a.get("r", 400.0)))
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
			var mem: String = text(a["remember"], vars)
			if not a["remember"] is Array and mem.contains("%d"): mem = mem % sim.day()
			for u in people(a.get("who", "all"), vars): sim.remember(u, mem, int(a.get("impact", 6)))
		if a.has("xp"):
			for u in people(a.get("who", "all"), vars):
				for k in a["xp"]: sim.gain_xp(u, k, float(a["xp"][k]))
		if a.has("hurt"): # (a fraction of max HP)
			for u in people(a.get("who", "all"), vars): sim.hurt_unit(u, u.max_hp * float(a["hurt"]), null)
		if a.has("morale"): # one family's spirits (the tribe's mood is "mood")
			for u in people(a.get("who", "all"), vars):
				u.morale = clampf(u.morale + float(a["morale"]), 0.0, 100.0)
				u.low_t = 0.0
		if a.has("bond"): # between "who" and "with" (both people specs)
			for u in people(a.get("who", "all"), vars):
				for o in people(str(a.get("with", "all")), vars): sim.life.add_bond(u, o, float(a["bond"]))
		if a.has("say"):
			for u in people(a.get("who", "all"), vars): sim.life.say_text(u, text(a["say"], vars))
		if a.has("depart"):
			for u in people(a.get("who", ""), vars): sim.life.depart(u)
		if a.has("panic"):
			sim.nat.panic_until = maxf(sim.nat.panic_until, sim.time + float(a["panic"]))
			sim.react.trigger("panic", {"at": D.VILLAGE, "until": sim.nat.panic_until})
		if a.has("weather"): sim.hz.set_weather(str(a["weather"]))
		if a.has("react"): sim.react.trigger(str(a["react"]), {"at": _at(a.get("at", "village"), c, vars)})
		if a.has("great_flood"): sim.flood_strike()
		if a.has("open"): vars["open"] = str(a["open"]) # (the caller opens a Task Contract / war plan)
		if a.has("chosen"): vars.merge(sim.birth_chosen(int(a["chosen"])), true)
		if a.has("festival"): sim.folk.hold(a["festival"], vars)
		if a.has("births"): sim.birth_timer += float(a["births"])
		if a.has("guests"): vars["guests_line"] = sim.folk.invite(float(a["guests"]))
		_clan_actions(a, vars)
		if a.has("feat"): sim.inv.feat("story", tr(a["feat"]))
		if a.has("sound"): sim.sound_cue.emit(str(a["sound"]), _at(a["at"], c, vars) if a.has("at") else Vector2.INF)
		if a.has("tale") and sim.cult: sim.cult.tell(a["tale"])
		if a.has("join") and sim.cult: sim.cult.join(a["join"])

## Actions on a rival clan: vars[a.clan] ("clan" by default) is its id.
func _clan_actions(a: Dictionary, vars: Dictionary) -> void:
	var cid: String = str(vars.get(str(a.get("clan", "clan")), ""))
	if cid == "" or not sim.rivals.clans.has(cid): return
	var cl: Dictionary = sim.rivals.clans[cid]
	if a.has("relation_min"): cl["relation"] = maxf(cl["relation"], float(a["relation_min"]))
	if a.has("relation_max"): cl["relation"] = minf(cl["relation"], float(a["relation_max"]))
	if a.has("relation"): sim.rivals.change(cid, float(a["relation"]), text(a["reason"], vars) if a.has("reason") else "")
	if a.has("raid_delay_days"): cl["raid_t"] = D.DAY_LEN * float(a["raid_delay_days"])
	if a.has("raid"): sim.rivals.launch_raid(cl)
	if a.has("clear_treaties"): cl["treaties"].clear()
	if a.has("vassal"): cl["vassal"] = int(a["vassal"])
	if a.has("grudge"): cl["grudges"].append(text(a["grudge"], vars))
	if a.has("peace_days"): cl["treaties"]["peace"] = {"until": sim.time + float(a["peace_days"]) * D.DAY_LEN, "tribute": 0}
	if a.has("clan_pop"): cl["pop"] = maxi(3, cl["pop"] + int(a["clan_pop"]))

# ------------------------------------------------------------ dilemmas (the shared format)
## The speaker of a dilemma ("best:<skill>"), or null.
func speaker(ev: Dictionary) -> Variant:
	var sp: String = str(ev.get("speaker", ""))
	return sim.best_unit(sp.substr(5), false) if sp.begins_with("best:") else null

## The named values a dilemma's texts and costs can use: the caller's, plus speaker,
## pop and day.
func _vars(ev: Dictionary, vars: Dictionary) -> Dictionary:
	var v := vars.duplicate()
	if ev.has("speaker") and not v.has("speaker"):
		var u = speaker(ev)
		v["speaker"] = tr(u.name) if u else tr(ev.get("speaker_default", "The elders"))
	v["pop"] = sim.living().size()
	v["day"] = sim.day()
	if not v.has("fighters"): v["fighters"] = ", ".join(people("fighters:3").map(func(u): return tr(u.name)))
	return v

## A text of a dilemma: [key, vars...], or a key whose lone "%s" is the speaker.
func _say(t, ev: Dictionary, vars: Dictionary = {}) -> String:
	if t is Array: return text(t, vars)
	var s: String = tr(str(t))
	if s.contains("%s") and ev.has("speaker") and s.count("%") == 1: return s % vars.get("speaker", tr("The elders"))
	return s

## A number in a dilemma: a number, the name of a var, or {"per_pop": k}.
## A number in a dilemma: a number, a var's name, or {"per_pop": n}. NAN if it is none of
## these (a price of NAN can't be paid).
func _num(v, vars: Dictionary) -> float:
	if v is String: v = vars.get(v, 0)
	elif v is Dictionary: v = v.get("per_pop", 0) * sim.living().size() if _num_ok(v.get("per_pop", 0)) else NAN
	return float(v) if _num_ok(v) else NAN

func _cost(o: Dictionary, vars: Dictionary) -> Dictionary:
	var out := {}
	var cost = o.get("cost", {})
	if not cost is Dictionary: return {"food": INF} # (a price that makes no sense can't be paid)
	for r in cost: out[r] = _num(cost[r], vars)
	return out

func affords(o: Dictionary, vars: Dictionary = {}) -> bool:
	return sim.can_afford(_cost(o, vars))

## Are an option's "needs" met (else it runs else_do)? {"best": skill, "lv", "or_tech"}
## or {"var": name} (a true value of the caller's).
func needs_met(o: Dictionary, vars: Dictionary = {}) -> bool:
	var nd: Dictionary = o.get("needs", {})
	if nd.is_empty(): return true
	if nd.has("var"): return bool(vars.get(nd["var"], false))
	if nd.has("or_tech") and sim.has_tech(nd["or_tech"]): return true
	var b = sim.best_unit(str(nd.get("best", "lore")), false)
	return b != null and b.lv(str(nd.get("best", "lore"))) >= int(nd.get("lv", 0))

## The chance an option works: {"base", "skill", "per_lv"} (the best at that skill) or
## {"power": "fighters:<n>", "div"} (their summed attack / div), clamped to min..max.
func chance(o: Dictionary) -> float:
	var ch: Dictionary = o.get("chance", {})
	if ch.is_empty(): return 1.0
	var p := float(ch.get("base", 0.0))
	if ch.has("skill"):
		var b = sim.best_unit(ch["skill"], false)
		p += float(ch.get("per_lv", 0.0)) * (b.lv(ch["skill"]) if b else 0)
	if ch.has("power"):
		var pw := 0.0
		for u in people(ch["power"]): pw += sim.unit_atk(u)
		p += pw / maxf(1.0, float(ch.get("div", 40)))
	return clampf(p, float(ch.get("min", 0.0)), float(ch.get("max", 1.0)))

func _opt_desc(o: Dictionary, ev: Dictionary, vars: Dictionary) -> String:
	var parts: Array = []
	if o.has("desc"): parts.append(_say(o["desc"], ev, vars))
	var cost := _cost(o, vars)
	if not cost.is_empty() and o.get("cost_note", true):
		parts.append(tr("Costs %s.") % ", ".join(cost.keys().map(func(r): return "%d %s" % [int(cost[r]), tr(r)])))
	return " ".join(parts)

## The options of a dilemma: its own, or generated ("options_from": "chosen" = the
## mythic bloodlines of D.CHOSEN).
func options(ev: Dictionary) -> Array:
	if ev.get("options_from", "") == "chosen":
		var out: Array = []
		for i in mini(D.CHOSEN.size(), 4):
			out.append({"label": D.CHOSEN[i]["label"], "desc": D.CHOSEN[i]["desc"], "cost_note": false, "do": [{"chosen": i}], "result": ev.get("result", "")})
		return out
	var opts = ev.get("options", [])
	return opts.filter(_option_ok) if opts is Array else []

## A choice that can be offered: a label, and its conditions, needs and actions in the right
## shape (a malformed one from outside is left out rather than offered or run).
func _option_ok(o) -> bool:
	if not o is Dictionary or not type_ok(o.get("label"), "text"): return false
	for k in ["when", "needs"]:
		if o.has(k) and not o[k] is Dictionary: return false
	for k in ["do", "else_do"]:
		if o.has(k) and not o[k] is Array: return false
	return true

## What the HUD shows: {title, text, options: [{label, desc, enabled}]}.
func dilemma_view(ev: Dictionary, vars: Dictionary = {}) -> Dictionary:
	var v := _vars(ev, vars)
	var opts: Array = []
	for o in options(ev):
		var ok := affords(o, v) and holds(o.get("when", {}))
		if o.has("needs") and o["needs"].has("best") and not o["needs"].has("or_tech"): ok = ok and sim.best_unit(str(o["needs"]["best"]), false) != null
		var ov := v.duplicate()
		ov["chance_pct"] = roundi(chance(o) * 100.0)
		opts.append({"label": _say(o["label"], ev, ov), "desc": _opt_desc(o, ev, ov), "enabled": ok})
	return {"title": _say(ev.get("title", ""), ev, v), "text": _say(ev.get("text", ""), ev, v), "options": opts}

## Choose option idx: pay, run its actions (or else_do when its needs or its chance fail),
## and return {"text": result, "option": the option chosen, "vars": the values after}.
func dilemma_choose(ev: Dictionary, idx: int, vars: Dictionary = {}) -> Dictionary:
	var v := _vars(ev, vars)
	var opts: Array = options(ev)
	if opts.is_empty(): return {"text": "", "option": {}, "vars": v}
	var o: Dictionary = opts[clampi(idx, 0, opts.size() - 1)]
	if not affords(o, v) or not holds(o.get("when", {})): o = opts.back() # (can't: the last choice, usually "do nothing")
	sim.spend(_cost(o, v)) # (all or nothing: the fallback choice is free or affordable)
	v["choice"] = _say(o["label"], ev, v)
	var good := needs_met(o, v) and (not o.has("chance") or randf() < chance(o))
	run(o.get("do", []) if good else o.get("else_do", []), null, v)
	var res = o.get("result", "") if good else o.get("else_result", o.get("result", ""))
	var t: String = _say(res, ev, v) if str(res) != "" else tr("The tribe chose: %s.") % v["choice"]
	for k in o.get("result_add", []): t += str(v.get(k, ""))
	return {"text": t, "option": o, "vars": v}

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
