## The Council's standing policies: the tribe's Way of life, how it treats the forest and
## the herds, which spirits it honours, what it seeks to learn and how it meets the clans.
## Owned by the simulation as `sim.policy`. Everything is data (config/policies.json);
## this is the machinery:
##   - choices give effects (the shared effect stats, folded by inv.mul()/inv.add() like
##     inventions), drift the culture axes every day, and run on_start actions;
##   - a change costs mood and takes some days to take hold; meanwhile the old choice holds;
##   - council(id, choice) says who would speak for and against it (the HUD asks the LLM
##     to voice them, or uses their lines from the config);
##   - set_choice() is the one operation that changes a policy (the HUD, a game master).
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")

var C: Dictionary = preload("res://scripts/config.gd").load_cfg("policies")

var sim
var chosen := {} # policy id -> choice id in force
var pending := {} # policy id -> {"choice", "at"} (takes hold at time `at`)
var changed_day := {} # policy id -> day it last changed (cooldown)
var history: Array = [] # [{day, policy, choice, by}]
var rev := 0 # bumps when the effects in force change (inv caches them)
var _day := -1

func _init(s) -> void:
	sim = s
	for id in C.get("policies", {}): chosen[id] = str(C["policies"][id].get("default", ""))

func defs() -> Dictionary: return C.get("policies", {})

func choice_def(id: String, choice: String) -> Dictionary:
	return defs().get(id, {}).get("choices", {}).get(choice, {})

## The policies the tribe can decide on now (their unlock conditions hold).
func open_ids() -> Array:
	return defs().keys().filter(func(id): return sim.story.holds(defs()[id].get("unlock", {})))

## Why `choice` can't be chosen for policy `id` now ("" = it can).
func block(id: String, choice: String) -> String:
	var cd := choice_def(id, choice)
	if cd.is_empty(): return "Unknown choice"
	if not id in open_ids(): return "Not yet"
	if chosen.get(id, "") == choice and not pending.has(id): return "Already the way"
	if pending.get(id, {}).get("choice", "") == choice: return "Already decided"
	if not sim.story.holds(cd.get("unlock", {})): return _unlock_text(cd.get("unlock", {}))
	var cool := int(C.get("switch", {}).get("cooldown_days", 0))
	if changed_day.has(id) and sim.day() < int(changed_day[id]) + cool: return "The Council has just decided this"
	return ""

func _unlock_text(w: Dictionary) -> String:
	if w.has("tech"): return sim.tr("Requires %s") % sim.tr(sim.evo.tech_def(w["tech"])["name"])
	return "Not yet"

## Change a policy (the Council's decision). Untrusted input: ids are checked. `by`
## names who decided (the chieftain, a game master...). Returns "" or why not.
func set_choice(id: String, choice: String, by := "") -> String:
	var why := block(id, choice)
	if why != "": return why
	var sw: Dictionary = C.get("switch", {})
	if choice == chosen.get(id, ""): # (changing back before the new way took hold)
		pending.erase(id)
	else:
		pending[id] = {"choice": choice, "at": sim.time + float(sw.get("settle_days", 1)) * D.DAY_LEN}
		sim.folk.lift(float(sw.get("mood", 0)))
	changed_day[id] = sim.day()
	history.append({"day": sim.day(), "policy": id, "choice": choice, "by": by})
	var cd := choice_def(id, choice)
	sim.add_log(sim.tr("The Council decides: %s - %s.") % [sim.tr(defs()[id]["title"]), sim.tr(cd["label"])], "vice")
	sim.cult.on_event("policy:%s:%s" % [id, choice])
	return ""

func update(_dt: float) -> void:
	for id in pending.keys():
		if sim.time >= float(pending[id]["at"]): _take_hold(id, pending[id]["choice"])
	if sim.day() != _day: # culture drifts with the ways the tribe lives by
		_day = sim.day()
		for id in chosen:
			for ax in choice_def(id, chosen[id]).get("culture", {}):
				if sim.evo.culture.has(ax): sim.evo.drift(ax, float(choice_def(id, chosen[id])["culture"][ax]))

func _take_hold(id: String, choice: String) -> void:
	pending.erase(id)
	chosen[id] = choice
	rev += 1
	var cd := choice_def(id, choice)
	sim.add_log(sim.tr("A new way takes hold: %s.") % sim.tr(cd["label"]), "vice")
	sim.story.run(cd.get("on_start", []), null)

## Every effect of the choices in force (inventions.gd folds them with the others).
func effects() -> Array:
	var out: Array = []
	for id in chosen: out.append_array(choice_def(id, chosen[id]).get("effects", []))
	return out

## Who speaks at the Council about choosing `choice`: [{who (unit), side "pro"|"con", line}].
## The most fitting elders by personality; lines from the config (the HUD may ask the LLM).
func council(id: String, choice: String) -> Array:
	var cd := choice_def(id, choice)
	var old := choice_def(id, chosen.get(id, ""))
	var people: Array = sim.living().filter(func(u): return u.role != "child")
	var scored: Array = []
	for u in people:
		var like := 0
		for t in u.traits:
			if t in cd.get("liked_by", []) or t in old.get("disliked_by", []): like += 1
			if t in cd.get("disliked_by", []) or t in old.get("liked_by", []): like -= 1
		scored.append([like, sim.unit_level(u) + (3 if u.title != "" else 0), u])
	var out: Array = []
	var n := int(C.get("council", {}).get("speakers", 3))
	var pros: Array = scored.filter(func(e): return e[0] > 0)
	var cons: Array = scored.filter(func(e): return e[0] < 0)
	pros.sort_custom(func(a, b): return a[0] * 10 + a[1] > b[0] * 10 + b[1])
	cons.sort_custom(func(a, b): return -a[0] * 10 + a[1] > -b[0] * 10 + b[1])
	var i := 0
	while out.size() < n and (i < pros.size() or i < cons.size()):
		if i < pros.size(): out.append({"who": pros[i][2], "side": "pro", "line": cd.get("pro", "")})
		if i < cons.size() and out.size() < n: out.append({"who": cons[i][2], "side": "con", "line": cd.get("con", "")})
		i += 1
	if out.is_empty() and not people.is_empty(): # nobody minds either way: the eldest says so
		people.sort_custom(func(a, b): return sim.unit_level(a) > sim.unit_level(b))
		out.append({"who": people[0], "side": "pro", "line": cd.get("pro", "")})
	return out

## What the LLM is told for a Council debate.
func council_ctx(id: String, choice: String) -> Dictionary:
	var cd := choice_def(id, choice)
	var old := choice_def(id, chosen.get(id, ""))
	return {"policy": defs()[id]["title"], "about": defs()[id].get("desc", ""), "now": old.get("label", ""), "now_means": old.get("desc", ""),
		"proposed": cd.get("label", ""), "proposed_means": cd.get("desc", ""), "world": sim.evo.world_ctx(),
		"speakers": council(id, choice).map(func(s): return {"name": sim.tr(s["who"].name), "side": s["side"], "profile": sim.contracts.leader_profile(s["who"]), "would_say": s["line"]})}

## For a game master and the LLM personas: the ways the tribe lives by.
func summary() -> Dictionary:
	var out := {}
	for id in chosen:
		var e := {"choice": chosen[id], "label": choice_def(id, chosen[id]).get("label", "")}
		if pending.has(id): e["changing_to"] = pending[id]["choice"]
		out[id] = e
	return out

## The policies in words (for persona prompts): ["Way of life: Hunters", ...].
func in_words() -> Array:
	var out: Array = []
	for id in open_ids(): out.append("%s: %s" % [sim.tr(defs()[id]["title"]), sim.tr(choice_def(id, chosen[id]).get("label", ""))])
	return out
