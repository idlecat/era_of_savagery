## Ranks earned by deeds (config/ranks.json; docs/make_it_fun.md H). Owned by the simulation
## as `sim.ranks`.
##
## Routine XP raises a skill to `routine_cap`; past it the levels come in bands, one per rank
## (Proven Lv 5-7, Master Lv 8-10 by default), so a person's rank is read from the level and
## needs no state of its own. Crossing into a band takes a trial: a deed from the person's
## deed record (`u.deeds`, counters filled through deed()). gain_xp() stops at the top of a
## band; from there the trial is open (the deed is the door, not more XP), checked when
## they get there and whenever a new deed is done.
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")

var C: Dictionary = preload("res://scripts/config.gd").load_cfg("ranks")

var sim
## The rank gates are enforced (tests switch them off to keep older rules; C["gates"]).
var gates := true
## Rank-ups waiting for their naming rite at the fire: [{id, skill, rank}].
var rites: Array = []

func _init(s) -> void:
	sim = s

## The rank ids, lowest first.
func rank_ids() -> Array: return C["bands"].map(func(b): return b["id"])

## The lowest level of a rank ("" = no rank: level 0).
func min_lv(rank: String) -> int:
	var lo := int(C["routine_cap"])
	for b in C["bands"]:
		if b["id"] == rank: return lo + 1
		lo = int(b["cap_lv"])
	return 0

## The rank a level falls in ("" below the first band).
func rank_of(lv: int) -> String:
	var r := ""
	for b in C["bands"]:
		if lv >= min_lv(b["id"]): r = b["id"]
	return r

## u's rank in a skill ("" = none yet).
func rank(u: E.Unit, skill: String) -> String: return rank_of(u.lv(skill))

## True when u holds `rank` (or a higher one) in `skill`.
func has(u: E.Unit, skill: String, rank_id: String) -> bool:
	return u != null and u.skills.has(skill) and u.lv(skill) >= min_lv(rank_id)

## The highest level routine XP can bring u to in `skill` now: the top of their band.
func cap(u: E.Unit, skill: String) -> int:
	var r := rank(u, skill)
	if r == "": return int(C["routine_cap"])
	for b in C["bands"]:
		if b["id"] == r: return int(b["cap_lv"])
	return sim.MAX_LV

## The next rank u can earn in `skill` ("" = none left).
func next_rank(u: E.Unit, skill: String) -> String:
	var ids := rank_ids()
	var i := ids.find(rank(u, skill))
	return ids[i + 1] if i + 1 < ids.size() else ""

## The rank's entry for a skill ({title, desc, trial}), or {}.
func def(skill: String, rank_id: String) -> Dictionary: return C["skills"].get(skill, {}).get(rank_id, {})

## Display title of u's rank in `skill` ("" = none).
func title(u: E.Unit, skill: String) -> String: return str(def(skill, rank(u, skill)).get("title", ""))

## The trial is open: XP is full at the top of the band and a next rank exists.
func trial_open(u: E.Unit, skill: String) -> bool:
	return next_rank(u, skill) != "" and u.lv(skill) >= cap(u, skill)

## How far u is toward the next rank's trial: the closest of its deeds (any one will do).
func trial_progress(u: E.Unit, skill: String) -> Dictionary:
	var t: Dictionary = def(skill, next_rank(u, skill)).get("trial", {})
	var out := {"done": 0, "need": 1, "met": false}
	var best := -1.0
	for k in t:
		var need := maxi(1, int(t[k]))
		var done := mini(need, int(u.deeds.get(k, 0)))
		if float(done) / need > best:
			best = float(done) / need
			out = {"done": done, "need": need, "met": done >= need}
	return out

## Record a deed for u (deed ids in config/ranks.json _doc). A game master may grant one.
func deed(u: E.Unit, key: String, n := 1) -> void:
	if u == null or u.dead or key == "" or n <= 0: return
	u.deeds[key] = int(u.deeds.get(key, 0)) + n
	for skill in D.SKILLS: check(u, skill)

## Step u into the next band of `skill` if the trial is open and its deed is done.
func check(u: E.Unit, skill: String) -> bool:
	if u == null or u.dead or not u.skills.has(skill) or not trial_open(u, skill): return false
	if not trial_progress(u, skill)["met"]: return false
	_rank_up(u, skill)
	return true

## Called by gain_xp when a skill reaches the top of its band: the trial is open.
func on_full(u: E.Unit, skill: String) -> void:
	if check(u, skill) or u.role == "child": return
	var nd := def(skill, next_rank(u, skill))
	if nd.is_empty(): return
	sim.add_log(tr(C["ready_log"]) % [tr(u.name), tr(nd["desc"]).to_lower()], "xp", [u])

func _rank_up(u: E.Unit, skill: String) -> void:
	var s: Dictionary = u.skills[skill]
	s["xp"] = 0.0
	s["lv"] += 1
	var r := rank(u, skill)
	var t: String = tr(def(skill, r).get("title", r))
	sim.popup(u.pos + Vector2(0, -40), tr(C["popup"]) % t, Color("#ffd36b"), true)
	sim.remember(u, tr(C["remember"]) % [t, sim.day()], 8)
	sim.add_log(tr(C["log"]) % [tr(u.name), t], "story", [u])
	sim.life.praise(u, "level_up")
	if C.has("rite") and u.role != "child": rites.append({"id": u.id, "skill": skill, "rank": r})
	if C.get("first_feat", true) and not _held_by_other(u, skill, r):
		sim.inv.feat("rank", tr("The first %s") % t, u, {"desc": tr(def(skill, r).get("desc", ""))})
	if r == rank_ids()[0]: # their first rank: whoever they learned under taught them
		for id in u.mentors.get(skill, []):
			var m = sim.unit_by_id(id)
			if m and not m.dead and m != u and has(m, skill, r):
				sim.add_log(tr(C["taught_log"]) % [tr(u.name), tr(m.name)], "xp", [u, m])
				deed(m, "taught_" + skill)

func _held_by_other(u: E.Unit, skill: String, r: String) -> bool:
	for o in sim.units:
		if o != u and has(o, skill, r): return true
	for f in sim.inv.feats:
		if f["kind"] == "rank" and f["text"] == tr("The first %s") % tr(def(skill, r).get("title", r)): return true
	return false

## u worked under `leader` on `skill` work (a contract crew): u's first rank in that skill
## counts as the leader's teaching.
func learned_under(u: E.Unit, leader: E.Unit, skill: String) -> void:
	if u == null or leader == null or u == leader: return
	if not u.mentors.has(skill): u.mentors[skill] = []
	if not leader.id in u.mentors[skill]: u.mentors[skill].append(leader.id)

# ------------------------------------------------------------ the naming rite
## Hold the next waiting rite at dusk, once its person is home (config "rite").
func update(_dt: float) -> void:
	if rites.is_empty() or not sim.is_day_part("dusk") or sim.crisis.active() or sim.folk.festival_on(): return
	for i in rites.size():
		var u = sim.unit_by_id(int(rites[i]["id"]))
		if u == null or u.dead:
			rites.remove_at(i)
			return
		if u.role != "" or u.pos.distance_to(D.VILLAGE) > float(C["rite"].get("reach", 420)): continue
		var r: Dictionary = rites[i]
		rites.remove_at(i)
		hold_rite(u, r["skill"], r["rank"])
		return

## The naming rite for u's rank in `skill` (also a game master's operation).
func hold_rite(u: E.Unit, skill: String, rank_id: String) -> void:
	if u == null or u.dead or not C.has("rite"): return
	var t: String = tr(def(skill, rank_id).get("title", rank_id))
	if C["rite"].get("epithet", true) and u.epithet == "": u.epithet = def(skill, rank_id).get("title", "")
	sim.story.run(C["rite"]["actions"], null, {"who": "id:%d" % u.id, "name": tr(u.name), "title": t, "festival": tr(C["rite"]["name"])})

## The feather colours of u's ranks, highest first: [{color, master}] (world_view draws them).
func marks(u: E.Unit) -> Array:
	var out: Array = []
	var top: String = rank_ids()[-1]
	for skill in D.SKILLS:
		var r := rank(u, skill)
		if r != "": out.append({"color": Color(str(C.get("marks", {}).get(skill, "#e8d8b0"))), "master": r == top})
	out.sort_custom(func(a, b): return a["master"] and not b["master"])
	return out

# ------------------------------------------------------------ what ranks unlock
## A gate's entry in config ({skill, rank, desc, ...}), or {}.
func gate(id: String) -> Dictionary: return C.get("gates", {}).get(id, {})

## True when someone living holds the gate's rank (whatever the `gates` switch says: for bonuses).
var _cache_has := {} # gate id -> whether someone living holds it, this tick
var _cache_has_t := -1.0
func tribe_has(id: String) -> bool:
	if not sim.in_tick(): _cache_has_t = -1.0 # (outside a tick, a grant or a test may have changed it: look fresh)
	if _cache_has_t != sim.time: # (asked every tick by the herd and the gates: look at everyone once a tick)
		_cache_has_t = sim.time
		_cache_has = {}
	if _cache_has.has(id): return _cache_has[id]
	var g := gate(id)
	var found := false
	if not g.is_empty():
		for u in sim.units:
			if not u.dead and has(u, g["skill"], g["rank"]):
				found = true
				break
	_cache_has[id] = found
	return found

## The tribe may do what the gate allows (someone living holds its rank, or gates are off).
func tribe_can(id: String) -> bool: return not gates or gate(id).is_empty() or tribe_has(id)

## u may do what the gate allows.
func may(u: E.Unit, id: String) -> bool:
	var g := gate(id)
	return not gates or g.is_empty() or has(u, g["skill"], g["rank"])

## Why a gate is shut ("Needs a Builder"); "" when it is open (for u, or for the tribe if u is null).
func block(id: String, u: E.Unit = null) -> String:
	if (u != null and may(u, id)) or (u == null and tribe_can(id)): return ""
	var g := gate(id)
	return tr(C["blocked"]) % tr(def(g["skill"], g["rank"]).get("title", g["rank"]))

## A gate's number (`add`, `mult`) while it holds for the tribe (u null) or for u; else `none`.
func amount(id: String, key: String, none: float, u: E.Unit = null) -> float:
	var g := gate(id)
	if g.is_empty() or not g.has(key): return none
	var holds := tribe_has(id) if u == null else has(u, g["skill"], g["rank"])
	return float(g[key]) if holds else none

## What a rank in a skill unlocks: the descs of its gates.
func unlocks(skill: String, rank_id: String) -> Array:
	var out: Array = []
	var gs: Dictionary = C.get("gates", {})
	for id in gs:
		if gs[id]["skill"] == skill and gs[id]["rank"] == rank_id: out.append(gs[id]["desc"])
	return out

## A game master's grant: give u the deeds of the next trial in `skill` and its full XP, so
## the rank comes now. Returns false if there is no next rank.
func grant(uid: int, skill: String) -> bool:
	var u = sim.unit_by_id(uid)
	if u == null or u.dead or not skill in D.SKILLS or next_rank(u, skill) == "": return false
	var s: Dictionary = u.skills[skill]
	s["lv"] = maxi(s["lv"], cap(u, skill))
	s["xp"] = sim.xp_need(s["lv"])
	var t: Dictionary = def(skill, next_rank(u, skill)).get("trial", {})
	if not t.is_empty() and not trial_progress(u, skill)["met"]: u.deeds[t.keys()[0]] = int(u.deeds.get(t.keys()[0], 0)) + int(t.values()[0])
	return check(u, skill)

## Who holds which rank, and who is ready for a trial: for a game master and the LLM prompts.
func summary() -> Dictionary:
	var held := {}
	var ready := []
	for u in sim.living():
		for skill in D.SKILLS:
			var r := rank(u, skill)
			if r != "": held[u.name + ":" + skill] = r
			if trial_open(u, skill): ready.append({"who": u.name, "skill": skill, "rank": next_rank(u, skill), "trial": def(skill, next_rank(u, skill)).get("desc", "")})
	var open := {}
	for id in C.get("gates", {}): open[id] = tribe_has(id)
	return {"held": held, "ready": ready, "gates": open, "rites_waiting": rites.size()}
