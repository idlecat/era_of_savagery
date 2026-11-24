## Player-set stakes (docs/make_it_fun.md F): now and then the council proposes a challenge
## from config/challenges.json; the chieftain takes it up or lets it pass. One runs at a time.
## A challenge is data: when it may be offered (`when`, story conditions), its goal and what
## fails it (`goal`, `fail`: story conditions, plus the measures counted from when it was
## taken up: deaths_since, outposts_since), its time (`days`, or `until` a season begins),
## and what it brings (`reward` / `penalty`: story actions). Met: an achievement (inv.feat).
extends RefCounted

const D = preload("res://scripts/data.gd")
const Config = preload("res://scripts/config.gd")

var C: Dictionary = Config.load_cfg("challenges")
var sim
var on := true # (tests switch it off; test_challenges switches it on)
var active := {} # {id, t, deaths, outposts, season}: the challenge taken up, and the measures at that moment
var offered := "" # a challenge waiting for the chieftain's answer
var done := {} # id -> "met" | "failed" | "declined"
var offer_t := 0.0 # time of the last offer
var posed := false # the offer has been put to the chieftain (sim.check_events)
var check_t := 0.0

func _init(s) -> void:
	sim = s

func def(id: String) -> Dictionary:
	for c in C["list"]:
		if str(c["id"]) == id: return c
	return {}

func owns_event(id: String) -> bool: return id == "challenge"

func update(dt: float) -> void:
	if not on: return
	check_t -= dt
	if check_t > 0.0: return
	check_t = 1.0
	if not active.is_empty():
		_track()
	elif offered == "" and sim.time - offer_t >= D.DAY_LEN * float(C["offer_every_days"]) and sim.day() >= int(C["from_day"]):
		for c in C["list"]:
			if not done.has(c["id"]) and sim.story.holds(c.get("when", {})):
				offer(str(c["id"]))
				break

## The council proposes challenge `id` (a game master's verb too): a dilemma "challenge".
## Returns false if it can't be offered now.
func offer(id: String) -> bool:
	if def(id).is_empty() or not active.is_empty() or offered != "": return false
	offered = id
	offer_t = sim.time
	posed = false
	return true

## Take up challenge `id` now (the dilemma's first option, or a game master).
func accept(id: String) -> bool:
	var c := def(id)
	if c.is_empty() or not active.is_empty(): return false
	offered = ""
	active = {"id": id, "t": sim.time, "deaths": _deaths(), "outposts": _outposts(), "season": sim.hz.season_idx()}
	sim.add_log(tr(C["taken_log"]) % tr(c["title"]), "story")
	return true

func _deaths() -> int: return sim.units.filter(func(u): return u.dead and not u.gone).size()
func _outposts() -> int: return sim.contracts.list.filter(func(k): return k.kind == "settle" and k.status == "done").size()

## Is the goal (or a fail) met: story conditions plus the measures since it was taken up.
func _holds(w: Dictionary) -> bool:
	if w.is_empty(): return false
	var base := w.duplicate()
	for k in ["deaths_since", "outposts_since"]: base.erase(k)
	if w.has("deaths_since") and _deaths() - int(active["deaths"]) < int(w["deaths_since"]): return false
	if w.has("outposts_since") and _outposts() - int(active["outposts"]) < int(w["outposts_since"]): return false
	return base.is_empty() or sim.story.holds(base)

## The time is up: `days` since it was taken up, or the first day of season `until`.
func _time_up(c: Dictionary) -> bool:
	if c.has("days"): return sim.time - float(active["t"]) >= D.DAY_LEN * float(c["days"])
	if c.has("until"): return sim.hz.season() == str(c["until"]) and sim.hz.season_idx() != int(active["season"])
	return false

func _track() -> void:
	var c := def(active["id"])
	if c.is_empty():
		active = {}
		return
	var keep_until: bool = bool(c.get("hold", false)) # (met only if the goal still holds when time is up: "no one dies this winter")
	if _holds(c.get("fail", {})): _end(c, false)
	elif not keep_until and _holds(c.get("goal", {})): _end(c, true)
	elif _time_up(c): _end(c, keep_until and (c.get("goal", {}).is_empty() or _holds(c["goal"])))

func _end(c: Dictionary, met: bool) -> void:
	done[c["id"]] = "met" if met else "failed"
	active = {}
	sim.story.run(c.get("reward" if met else "penalty", []), null, {})
	if met:
		sim.inv.feat("challenge", tr(C["met_feat"]) % tr(c["title"]), null, {"desc": tr(c["desc"])})
	else:
		sim.add_log(tr(C["failed_log"]) % tr(c["title"]), "story")
		sim.alert(tr(C["failed_log"]) % tr(c["title"]), D.VILLAGE, "warn")

## The council's proposal, in the shared dilemma format.
func event_def(_id: String) -> Dictionary:
	var c := def(offered)
	if c.is_empty(): return {}
	var sp = sim.unit_by_id(int(sim.vice.get("steward", -1)))
	if sp == null or sp.dead: sp = sim.best_unit("lore", false)
	var who: String = tr(sp.name) if sp else tr("The elders")
	return {"title": tr(C["title"]), "text": tr(C["text"]) % [who, tr(c["say"]), tr(c["desc"]), tr(c["reward_text"])],
		"options": [{"label": tr(C["accept"]), "desc": tr(c["desc"]), "enabled": true}, {"label": tr(C["decline"]), "desc": tr(C["decline_desc"]), "enabled": true}]}

func resolve(_id: String, idx: int) -> String:
	var id := offered
	if idx == 0 and accept(id): return tr(C["taken_log"]) % tr(def(id)["title"])
	offered = ""
	done[id] = "declined"
	return tr(C["declined_log"])

## What a game master (and the HUD) reads: the challenge under way and how long is left.
func summary() -> Dictionary:
	if active.is_empty(): return {"active": "", "offered": offered, "done": done.duplicate()}
	var c := def(active["id"])
	var left := -1.0
	if c.has("days"): left = snappedf(float(c["days"]) - (sim.time - float(active["t"])) / D.DAY_LEN, 0.1)
	return {"active": active["id"], "title": tr(c["title"]), "desc": tr(c["desc"]), "days_left": left, "until": tr(str(c.get("until", ""))), "offered": offered, "done": done.duplicate()}
