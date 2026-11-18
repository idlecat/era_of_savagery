## Task Contracts (PRD 2.2.2): LLM blueprint -> sanitized plan -> deterministic executor.
## Once a contract is confirmed, NOTHING in this file calls the LLM. Interruptions are
## surfaced via sim.contract_interrupted, and the UI decides whether to wake the LLM.
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")

const SLOTS := [Vector2(-48, -42), Vector2(48, -42), Vector2(-48, 42), Vector2(48, 42), Vector2(0, -72),
	Vector2(0, 72), Vector2(-78, 0), Vector2(78, 0), Vector2(-30, -20), Vector2(30, 20)]
const EFFECTS := {
	"hold": "Crew stands its ground and fights",
	"reinforce": "Send up to 3 warriors from the village, crew holds",
	"retreat": "Abandon the task and flee back to the village",
	"ward": "Totem ritual drives beasts away (costs 10 lore)",
	"rest": "Wounded leader returns to the bonfire; crew carries on",
	"press_on": "Ignore the wound and keep working",
	"shelter": "Take shelter and wait for the danger to pass",
}
const WAR_OBJECTIVES := ["loot", "burn", "break"]
const WAR_OBJECTIVE_TEXT := {
	"loot": "carry off their stores of food and wood",
	"burn": "burn their huts so they are fewer and weaker",
	"break": "break their warriors so they cannot raid for a long time",
}

var sim
var list: Array = []

func _init(s) -> void:
	sim = s

func by_id(id: int) -> E.Contract:
	for c in list:
		if c.id == id: return c
	return null

func active() -> Array:
	return list.filter(func(c): return c.status not in ["done", "abandoned", "failed"])

func is_running(c: E.Contract) -> bool:
	return c.status not in ["done", "abandoned", "failed"]

# ------------------------------------------------------------ context for the LLM
func available_helpers(exclude_id := -1) -> Array:
	return sim.living().filter(func(u): return u.role == "" and u.id != exclude_id and D.home_side(u.pos))

func leader_profile(u: E.Unit) -> Dictionary:
	var skills := {}
	for s in D.SKILLS: skills[tr(D.SKILL_NAMES[s])] = u.lv(s)
	var mem: Array = []
	var sorted_mem: Array = u.memory.duplicate()
	sorted_mem.sort_custom(func(a, b): return a["day"] < b["day"])
	for m in sorted_mem:
		mem.append((tr("Day %d: ") % m["day"] if m["day"] > 0 else tr("Long ago: ")) + tr(m["text"]))
	var traits: Array = []
	for t in u.traits: traits.append("%s (%s)" % [tr(D.TRAITS[t]["name"]), tr(D.TRAITS[t]["desc"])])
	return {
		"name": tr(u.name), "epithet": tr(u.epithet), "personality": traits, "archetype": sim.arch(u),
		"level": sim.unit_level(u), "skills": skills,
		"hp": "%d/%d" % [roundi(u.hp), roundi(u.max_hp)], "hunger": "%d%%" % roundi(u.hunger),
		"memory_stream": mem,
		"knows": sim.evo.known_by(u).map(func(id): return tr(sim.evo.tech_def(id)["name"])),
	}

## What the leader knows about the frontier site: only what the tribe has seen (the fog).
func env_data(site: Vector2) -> Dictionary:
	var trees := 0
	var timber := 0.0
	var food_nodes := 0
	var seen: bool = sim.is_explored(site)
	for n in sim.nodes:
		if n.pos.distance_to(site) > 650 or not D.same_side(n.pos, site) or not sim.is_explored(n.pos): continue
		if n.kind == "tree":
			trees += 1
			timber += n.amount
		elif n.res == "food" and n.amount >= 1:
			food_nodes += 1
	var threats: Array = []
	if sim.landmarks.any(func(l): return l["kind"] == "den" and l["found"] and l["pos"].distance_to(site) < 1600.0): threats.append(tr("fresh saber-tooth tracks in the tall grass"))
	var near: Array = sim.active_predators_near(site, 700).filter(func(p): return sim.is_explored(p.pos))
	var beasts: int = near.filter(func(p): return p.clan == "").size()
	if beasts > 0: threats.append(tr("%d saber-toothed tigers seen prowling") % beasts)
	if near.size() > beasts: threats.append(tr("%d rival warriors seen nearby") % (near.size() - beasts))
	for id in sim.rivals.clans:
		var rc: Dictionary = sim.rivals.clans[id]
		if rc["met"] and rc["relation"] <= -15: threats.append(tr("the %s is hostile and raids for food") % tr(rc["name"]))
	var structs := {}
	for k in D.CONTRACT_STRUCTURES:
		var sd: Dictionary = D.STRUCTURES[k]
		if sd.has("tech") and not sim.has_tech(sd["tech"]): continue
		structs[k] = {"wood": sd["wood"], "houses": sd.get("cap", 0)}
	return {
		"target_area": site_area(site),
		"explored": seen, "river_known": river_known(site),
		"timber": tr("%d trees (~%d wood)") % [trees, timber] if seen else tr("unknown: no one has seen that land yet"),
		"food_sources": food_nodes if seen else tr("unknown"),
		"predator_threat": threats, "river": tr("rich fishing waters along the bank") if river_known(site) else (tr("no river close by") if seen else tr("unknown")),
		"tribe_stockpile": {"food": roundi(sim.stock["food"]), "wood": roundi(sim.stock["wood"]), "lore": roundi(sim.stock["lore"])},
		"population": sim.living().size(), "idle_helpers_available": available_helpers().size(),
		"buildable_structures": structs,
		"season_and_weather": sim.hz.summary(),
		"neighbors": sim.rivals.summary(),
		"day": sim.day(),
	}

## Where the next frontier settlement goes: among the map's sites (D.SITES, nearest first)
## that no outpost has claimed yet, the first one the tribe has seen, else the nearest;
## when all are claimed, beside one of them.
func next_site() -> Vector2:
	var claimed: Array = list.filter(func(o): return o.kind == "settle" and o.status != "abandoned")
	var free: Array = D.SITES.filter(func(s): return not claimed.any(func(o): return o.site.distance_to(s) < 500.0))
	for s in free:
		if sim.is_explored(s): return s
	if not free.is_empty(): return free[0]
	var n := list.size()
	var base: Vector2 = D.SITES[n % D.SITES.size()] if not D.SITES.is_empty() else D.VILLAGE + Vector2(1000, 0)
	var p := base + Vector2(0, 260 * (n % 3) * (1 if n % 2 == 0 else -1))
	return D.shore(p, 60.0)

## Has the tribe seen a river by the site?
func river_known(site: Vector2) -> bool:
	if D.river_dist(site) >= 700.0: return false
	return sim.is_explored(D.river_info(site)["c"])

## Does the tribe know of a river between home and the site, and a ford over it? (The
## way there crosses a river if its route has ford waypoints; a ford is known once seen.)
func crossing(site: Vector2) -> String:
	if D.home_side(site): return "none"
	var known_river := false
	var known_ford := false
	for q in D.route(D.VILLAGE, site):
		for f in D.FORDS:
			if q == f["a"] or q == f["b"]:
				if sim.is_explored(f["p"]): known_ford = true
				if sim.is_explored(f["a"]) or sim.is_explored(f["b"]): known_river = true
	if known_ford: return "ford"
	return "river" if known_river else "unknown"

## The frontier site as the leader hears it described: only what the tribe knows.
func site_area(site: Vector2) -> String:
	var dir: String = tr(D.compass(D.VILLAGE, site))
	if not sim.is_explored(site): return tr("unexplored land to the %s, beyond what our scouts have seen") % dir
	match crossing(site):
		"ford": return tr("untamed land across the river to the %s, reached by a ford") % dir
		"river", "unknown": return tr("land to the %s across the river; no one has found a way over yet") % dir
	return tr("open land to the %s, a long walk from the village") % dir

## "across the river" (once the tribe knows it is) or "to the north", for the log.
func site_where(site: Vector2) -> String:
	return tr("across the river") if crossing(site) == "ford" else tr("to the %s") % tr(D.compass(D.VILLAGE, site))

## Everything injected into the leader's LLM node for Phase 1 negotiation.
func negotiation_ctx(u: E.Unit, directive: String, terms: Dictionary, terms_set: bool,
		player_message := "", previous := {}, history := [], kind := "settle") -> Dictionary:
	var top := ""
	if not u.memory.is_empty(): top = tr(u.memory[0]["text"]) # memory is kept sorted by impact
	var seek_group := str(terms.get("group", ""))
	if kind == "seek" and not seek_group in SEEK_GROUPS: # (left to the leader: what their temperament seeks)
		seek_group = preload("res://scripts/persona_engine.gd").SEEK_TASTE.get(sim.arch(u), "food")
	return {
		"kind": kind, "world": sim.evo.world_ctx(), "candidates": research_candidates(),
		"arch": sim.arch(u), "leader": leader_profile(u), "env": env_data(next_site()) if kind == "settle" else (war_env(terms.get("target", "")) if kind == "war" else (seek_env(seek_group) if kind == "seek" else research_env())),
		"seek_group": seek_group,
		"directive": directive, "terms": terms, "terms_set": terms_set,
		"player_message": player_message, "previous": previous, "history": history,
		"has_farming": sim.has_tech("farming"), "max_crew": mini(6 if kind == "war" else 5, available_helpers(u.id).size() + 1),
		"top_memory": top,
		"objection": _objection_words(sim.policy.objection(u, kind)),
	}

## A leader's objection to the tribe's ways, in words for the persona.
func _objection_words(ob: Dictionary) -> Dictionary:
	if ob.is_empty(): return {}
	return {"way": tr(ob["title"]), "now": tr(ob["now_label"]), "you_want": tr(ob["wants_label"]), "your_complaint": tr(ob["complaint"]), "your_plea": tr(ob["plea"])}

## Ideas a research contract may pursue: prerequisites known, tech itself not.
func research_candidates() -> Array:
	var out: Array = []
	for id in sim.evo.candidates():
		var t: Dictionary = sim.evo.tech_def(id)
		var how: Array = []
		for k in t["practice"]: how.append(tr(D.PRACTICE_NAMES[k]))
		out.append({"id": id, "name": tr(t["name"]), "what_it_gives": tr(t["desc"]), "insight_pct": roundi(sim.evo.insight_frac(id) * 100),
			"learned_by": ", ".join(how)})
	return out

func research_env() -> Dictionary:
	return {
		"target_area": tr("a workshop clearing beside the village bonfire"),
		"tribe_stockpile": {"food": roundi(sim.stock["food"]), "wood": roundi(sim.stock["wood"]), "stone": roundi(sim.stock["stone"]), "lore": roundi(sim.stock["lore"])},
		"population": sim.living().size(), "idle_helpers_available": available_helpers().size(),
		"stone_quarrying_possible": sim.has_tech("tools"), "day": sim.day(),
		"season_and_weather": sim.hz.summary(),
		"neighbors": sim.rivals.summary(),
	}

# ------------------------------------------------------------ search quests (kind "seek")
const SEEK_GROUPS := ["food", "medicine", "ore"]
const SEEK_WORDS := {"food": "new foods", "medicine": "healing plants", "ore": "stones and ores"}
const SEEK_ACTS := {"food": "Searching for new foods", "medicine": "Searching for healing plants", "ore": "Searching for stones and ores"}

func _seek_cfg() -> Dictionary: return sim.DISC.get("seek", {})

## Where a group of finds could be looked for: places of the kinds the config names for it
## (forest, meadow, riverbank, hills, volcano), on any land the tribe can walk to, nearest
## first. [{"kind", "pos", "name"}]. The places say where such things grow, not where they are.
func seek_places(group: String) -> Array:
	var kinds: Array = _seek_cfg().get("groups", {}).get(group, ["forest", "meadow"])
	var out: Array = []
	var home: Vector2 = D.VILLAGE
	var rng := RandomNumberGenerator.new() # (the same places all day: negotiation, plan and contract agree)
	rng.seed = hash(group) + sim.day() * 7919 + int(D.MAP.get("seed", 0))
	for kind in kinds:
		match kind:
			"forest": # the densest woods (coarse cells with the most trees)
				var cells := {}
				for n in sim.nodes:
					if n.kind != "tree": continue
					var key := Vector2i(int(n.pos.x / 600), int(n.pos.y / 600))
					cells[key] = cells.get(key, 0) + 1
				var best: Array = cells.keys()
				best.sort_custom(func(a, b): return cells[a] > cells[b])
				for key in best.slice(0, 2):
					if cells[key] >= 8: out.append({"kind": "forest", "pos": (Vector2(key) + Vector2(0.5, 0.5)) * 600.0})
			"meadow": # open land: few trees around
				for k in 24:
					var p := Vector2(rng.randf_range(200, D.W - 200), rng.randf_range(200, D.H - 200))
					if D.in_river(p) or p.distance_to(home) < 500 or D.river_dist(p) < 200: continue
					if sim.nodes.filter(func(n): return n.kind == "tree" and n.pos.distance_to(p) < 260).size() <= 2:
						out.append({"kind": "meadow", "pos": p})
						break
			"riverbank":
				if not D.RIVERS.is_empty():
					var q: Vector2 = D.nearest_river_point(home + Vector2(rng.randf_range(-900, 900), rng.randf_range(-700, 700)))
					out.append({"kind": "riverbank", "pos": sim._dry(q + (home - q).normalized() * 90.0)})
			"hills": # rocky landmarks
				for lm in sim.landmarks:
					if lm["kind"] in ["peak", "stones", "cave", "flint"]: out.append({"kind": "hills", "pos": lm["pos"] + Vector2(90, 60), "lm": lm})
			"volcano":
				if D.has_volcano(): out.append({"kind": "volcano", "pos": D.VOLCANO + (home - D.VOLCANO).normalized() * 420.0})
	out = out.filter(func(pl): return not D.in_river(pl["pos"]))
	out.sort_custom(func(a, b): return a["pos"].distance_to(home) < b["pos"].distance_to(home))
	out = out.slice(0, int(_seek_cfg().get("places", 4)))
	for pl in out: pl["name"] = _place_name(pl)
	return out

## "the woods to the north-east", "the hills by Flint Ridge"...
func _place_name(pl: Dictionary) -> String:
	var d: Vector2 = pl["pos"] - D.VILLAGE
	var iso_d := Vector2(d.x - d.y, d.x + d.y) # (screen directions: up is north)
	var dir: String = ["east", "south-east", "south", "south-west", "west", "north-west", "north", "north-east"][posmod(roundi(iso_d.angle() / (TAU / 8)), 8)]
	var what: String = {"forest": "the woods to the %s", "meadow": "the open meadows to the %s", "riverbank": "the riverbank to the %s", "hills": "the rocky hills to the %s", "volcano": "the slopes of the Fire Mountain to the %s"}[pl["kind"]]
	if pl.has("lm") and pl["lm"]["found"]: return tr("the rocks by %s") % tr(pl["lm"]["name"])
	return tr(what) % tr(dir)

func seek_env(group: String) -> Dictionary:
	var places: Array = seek_places(group if group in SEEK_GROUPS else "food")
	var known: Array = sim.known_finds.keys().filter(func(id): return D.FINDS[id].get("group", "") == group).map(func(id): return tr(D.FINDS[id]["name"]))
	return {
		"looking_for": tr(SEEK_WORDS.get(group, "new foods")) if group != "" else tr("whatever is new: foods, healing plants, stones"),
		"places_you_could_search": places.map(func(pl): return {"index": places.find(pl), "place": pl["name"], "paces_away": roundi(pl["pos"].distance_to(D.VILLAGE)), "seen_before": sim.is_explored(pl["pos"])}),
		"already_known_to_the_tribe": known,
		"days_you_may_search": _seek_cfg().get("days", [1, 3]),
		"population": sim.living().size(), "season_and_weather": sim.hz.summary(),
	}

func _sanitize_seek(bp: Dictionary, terms: Dictionary, leader: E.Unit) -> Dictionary:
	var notes: Array = []
	var out := {"kind": "seek"}
	var pid := RegEx.create_from_string("[^a-z0-9_]").sub(str(bp.get("plan_id", "")).to_lower().replace(" ", "_"), "", true).left(40)
	out["plan_id"] = pid if pid != "" else "search_%02d" % (list.size() + 1)
	out["leader_id"] = "unit_%d" % leader.id
	out["crew_size"] = clampi(_int(bp.get("crew_size"), terms.get("crew_size", 2)), 1, mini(int(_seek_cfg().get("crew_max", 4)), available_helpers(leader.id).size() + 1))
	var g := str(bp.get("group", "")).to_lower()
	g = {"foods": "food", "plants": "medicine", "herbs": "medicine", "healing": "medicine", "stone": "ore", "stones": "ore", "ores": "ore", "minerals": "ore", "mineral": "ore"}.get(g, g)
	if str(terms.get("group", "")) in SEEK_GROUPS and g != terms["group"]:
		if g != "": notes.append("The Chieftain asked for %s." % SEEK_WORDS[terms["group"]])
		g = terms["group"]
	if not g in SEEK_GROUPS: g = "food"
	out["group"] = g
	var places := seek_places(g)
	if places.is_empty(): return {"ok": false, "blueprint": out, "notes": [tr("There is nowhere to search for that.")]}
	var pi := clampi(_int(bp.get("place"), 0), 0, places.size() - 1)
	out["place"] = pi
	out["place_name"] = places[pi]["name"]
	out["site"] = [places[pi]["pos"].x, places[pi]["pos"].y]
	var dr: Array = _seek_cfg().get("days", [1, 3])
	out["days"] = clampi(_int(bp.get("days"), 2), int(dr[0]), int(dr[1]))
	out["capacity_target"] = 0
	out["focus"] = "seek"
	out["steps"] = [{"action": "seek", "duration_sec": out["days"] * int(_seek_cfg().get("secs_per_day", 45))}]
	out["abort_conditions"] = ["enemy_attack", "hp_below_35%"]
	return {"ok": true, "blueprint": out, "notes": notes}

## Context for Phase 4 emergency awakening.
func emergency_ctx(c: E.Contract) -> Dictionary:
	var u := leader(c)
	return {
		"arch": sim.arch(u), "name": u.name, "leader": leader_profile(u),
		"summary": summary(c), "allowed": allowed_effects(c), "effects": EFFECTS, "world": sim.evo.world_ctx(),
	}

# ------------------------------------------------------------ blueprint sanitizing
## LLM output is untrusted: clamp every number, whitelist every enum. Returns
## {"ok": bool, "blueprint": Dictionary, "notes": Array[String]}.
func sanitize(raw: Variant, terms: Dictionary, leader: E.Unit) -> Dictionary:
	var bp0: Dictionary = raw if raw is Dictionary else {}
	var kind0: String = str(terms.get("kind", bp0.get("kind", "settle")))
	if kind0 == "research": return _sanitize_research(bp0, terms, leader)
	if kind0 == "war": return _sanitize_war(bp0, terms, leader)
	if kind0 == "seek": return _sanitize_seek(bp0, terms, leader)
	var notes: Array = []
	var bp: Dictionary = bp0
	var max_crew := mini(5, available_helpers(leader.id).size() + 1)
	var out := {}
	var pid := str(bp.get("plan_id", "")).to_lower().replace(" ", "_")
	var re := RegEx.create_from_string("[^a-z0-9_]")
	pid = re.sub(pid, "", true).left(40)
	out["plan_id"] = pid if pid != "" else "frontier_outpost_%02d" % (list.size() + 1)
	out["leader_id"] = "unit_%d" % leader.id
	out["crew_size"] = clampi(_int(bp.get("crew_size"), terms.get("crew_size", 3)), 1, max_crew)
	out["capacity_target"] = clampi(_int(bp.get("capacity_target"), terms.get("capacity_target", 6)), 2, 15)
	var focus := str(bp.get("focus", terms.get("focus", "balanced")))
	out["focus"] = focus if focus in D.FOCUSES else "balanced"

	var steps: Array = []
	var seen_once := {}
	var raw_steps: Array = bp.get("steps", []) if bp.get("steps") is Array else []
	for s in raw_steps:
		if not (s is Dictionary): continue
		var action := str(s.get("action", "")).to_lower()
		match action:
			"gather_wood", "gather_food":
				var hi := 120 if action == "gather_wood" else 60
				steps.append({"action": action, "target_amount": clampi(_int(s.get("target_amount"), 30), 5, hi)})
			"build":
				var st := str(s.get("structure", "")).to_lower().replace(" ", "_")
				st = D.STRUCT_ALIASES.get(st, st)
				if st not in D.CONTRACT_STRUCTURES:
					notes.append(tr("Dropped unknown structure '%s'.") % st)
					continue
				var sd: Dictionary = D.STRUCTURES[st]
				var water_known := river_known(next_site())
				if sd.has("tech") and not sim.has_tech(sd["tech"]):
					notes.append(("%s needs unresearched wisdom; replaced with Fishing Dock." if water_known else "%s needs unresearched wisdom; replaced with a Hut.") % sd["name"])
					st = "fishing_dock" if water_known else "hut"
				if st == "fishing_dock" and not water_known:
					notes.append(tr("Dropped the fishing dock: no one has seen water by the site."))
					continue
				var count := clampi(_int(s.get("count"), 1), 1, 4)
				if st in ["palisade", "bonfire", "weapon_rack", "totem_shrine", "fishing_dock"]:
					if seen_once.has(st): continue
					seen_once[st] = true
					count = 1
				steps.append({"action": "build", "structure": st, "count": count})
			"ritual":
				steps.append({"action": "ritual", "duration_sec": clampi(_int(s.get("duration_sec", s.get("duration")), 10), 4, 30)})
			_:
				notes.append(tr("Dropped unknown action '%s'.") % action)
		if steps.size() >= 8: break
	if steps.is_empty():
		return {"ok": false, "blueprint": out, "notes": notes + [tr("Blueprint had no valid steps.")]}
	out["steps"] = steps

	var aborts: Array = []
	var hp_re := RegEx.create_from_string("hp_below_(\\d+)")
	var raw_aborts: Array = bp.get("abort_conditions", []) if bp.get("abort_conditions") is Array else []
	for a in raw_aborts:
		var s := str(a).to_lower()
		if s in ["enemy_attack", "natural_disaster"] and s not in aborts: aborts.append(s)
		var m := hp_re.search(s)
		if m: aborts.append("hp_below_%d%%" % clampi(int(m.get_string(1)), 10, 80))
	if "enemy_attack" not in aborts: aborts.push_front("enemy_attack")
	out["abort_conditions"] = aborts
	return {"ok": true, "blueprint": out, "notes": notes}

func _sanitize_research(bp: Dictionary, terms: Dictionary, leader: E.Unit) -> Dictionary:
	var notes: Array = []
	var out := {"kind": "research"}
	var cands: Array = sim.evo.candidates()
	var pid := RegEx.create_from_string("[^a-z0-9_]").sub(str(bp.get("plan_id", "")).to_lower().replace(" ", "_"), "", true).left(40)
	out["plan_id"] = pid if pid != "" else "seek_wisdom_%02d" % (list.size() + 1)
	out["leader_id"] = "unit_%d" % leader.id
	out["crew_size"] = clampi(_int(bp.get("crew_size"), terms.get("crew_size", 2)), 1, mini(4, available_helpers(leader.id).size() + 1))
	var tech := str(bp.get("tech", terms.get("tech", ""))).to_lower()
	for t in D.TECHS: # accept names as well as ids
		if tech == t["name"].to_lower(): tech = t["id"]
	if terms.get("tech", "") != "" and terms["tech"] in cands and tech != terms["tech"]:
		notes.append("The Chieftain chose %s." % sim.evo.tech_def(terms["tech"])["name"])
		tech = terms["tech"]
	if tech not in cands:
		if cands.is_empty():
			return {"ok": false, "blueprint": out, "notes": [tr("No new wisdom is within reach yet.")]}
		if tech != "": notes.append("'%s' is out of reach; seeking %s instead." % [tech, sim.evo.tech_def(cands[0])["name"]])
		tech = cands[0]
	out["tech"] = tech
	out["capacity_target"] = 0
	out["focus"] = "research"
	var steps: Array = []
	var raw_steps: Array = bp.get("steps", []) if bp.get("steps") is Array else []
	for s in raw_steps:
		if not (s is Dictionary): continue
		var action := str(s.get("action", "")).to_lower()
		match action:
			"gather_wood", "gather_food":
				steps.append({"action": action, "target_amount": clampi(_int(s.get("target_amount"), 20), 5, 60)})
			"gather_stone":
				if sim.has_tech("tools"): steps.append({"action": action, "target_amount": clampi(_int(s.get("target_amount"), 15), 5, 40)})
				else: notes.append("Dropped stone gathering (needs Polished Stone Tools).")
			"experiment":
				steps.append({"action": "experiment", "duration_sec": clampi(_int(s.get("duration_sec", s.get("duration")), 20), 8, 45)})
			"ritual":
				steps.append({"action": "ritual", "duration_sec": clampi(_int(s.get("duration_sec", s.get("duration")), 10), 4, 30)})
			_:
				notes.append("Dropped '%s' (not part of a research plan)." % action)
		if steps.size() >= 6: break
	if not steps.any(func(s): return s["action"] == "experiment"):
		steps.append({"action": "experiment", "duration_sec": 20})
		notes.append("Added an experiment step - wisdom is not found without trying.")
	out["steps"] = steps
	var aborts: Array = ["enemy_attack"]
	for a in (bp.get("abort_conditions", []) if bp.get("abort_conditions") is Array else []):
		var m := RegEx.create_from_string("hp_below_(\\d+)").search(str(a))
		if m: aborts.append("hp_below_%d%%" % clampi(int(m.get_string(1)), 10, 80))
	out["abort_conditions"] = aborts
	return {"ok": true, "blueprint": out, "notes": notes}

## War plans are built from a fixed skeleton: [war dance] -> [scout] -> assault ->
## objective -> return. The LLM chooses the target, objective, crew, the optional
## steps and when to call off the fight; nothing else is understood.
func _sanitize_war(bp: Dictionary, terms: Dictionary, leader: E.Unit) -> Dictionary:
	var notes: Array = []
	var out := {"kind": "war", "focus": "war", "capacity_target": 0}
	var met: Array = sim.rivals.clans.keys().filter(func(id): return sim.rivals.clans[id]["met"])
	if met.is_empty(): return {"ok": false, "blueprint": out, "notes": ["We know of no clan to fight."]}
	var target := str(bp.get("target", terms.get("target", ""))).to_lower()
	for id in sim.rivals.clans: # accept names too
		var nm: String = sim.rivals.clans[id]["name"].to_lower()
		if target == nm or (target != "" and target in nm) or target == tr(sim.rivals.clans[id]["name"]).to_lower(): target = id
	if terms.get("target", "") in met and target != terms["target"]:
		notes.append("The Chieftain named the %s as the enemy." % sim.rivals.clans[terms["target"]]["name"])
		target = terms["target"]
	if target not in met:
		target = met[0]
		notes.append("Unknown enemy; marching on the %s." % sim.rivals.clans[target]["name"])
	out["target"] = target
	var obj := str(bp.get("objective", terms.get("objective", "loot"))).to_lower()
	obj = {"raid": "loot", "plunder": "loot", "steal": "loot", "fire": "burn", "torch": "burn", "slay": "break", "kill": "break", "crush": "break"}.get(obj, obj)
	if terms.get("objective", "") in WAR_OBJECTIVES: obj = terms["objective"]
	out["objective"] = obj if obj in WAR_OBJECTIVES else "loot"
	var pid := RegEx.create_from_string("[^a-z0-9_]").sub(str(bp.get("plan_id", "")).to_lower().replace(" ", "_"), "", true).left(40)
	out["plan_id"] = pid if pid != "" else "war_on_%s_%02d" % [target, list.size() + 1]
	out["leader_id"] = "unit_%d" % leader.id
	out["crew_size"] = clampi(_int(bp.get("crew_size"), terms.get("crew_size", 4)), 2, mini(6, available_helpers(leader.id).size() + 1))
	if available_helpers(leader.id).is_empty(): out["crew_size"] = 1
	var dance := 0
	var scout := 0
	var raw_steps: Array = bp.get("steps", []) if bp.get("steps") is Array else []
	for st in raw_steps:
		if not (st is Dictionary): continue
		var a := str(st.get("action", "")).to_lower()
		match a:
			"war_dance", "ritual": dance = clampi(_int(st.get("duration_sec", st.get("duration")), 8), 4, 20)
			"scout": scout = clampi(_int(st.get("duration_sec", st.get("duration")), 10), 4, 25)
			"loot", "burn", "break":
				if a != out["objective"] and not terms.has("objective"): out["objective"] = a
	var steps: Array = []
	if dance > 0: steps.append({"action": "war_dance", "duration_sec": dance})
	if scout > 0: steps.append({"action": "scout", "duration_sec": scout})
	steps.append({"action": "assault"})
	steps.append({"action": out["objective"], "duration_sec": 10})
	steps.append({"action": "return"})
	out["steps"] = steps
	var aborts: Array = ["heavy_losses"]
	for a in (bp.get("abort_conditions", []) if bp.get("abort_conditions") is Array else []):
		var m := RegEx.create_from_string("hp_below_(\\d+)").search(str(a))
		if m: aborts.append("hp_below_%d%%" % clampi(int(m.get_string(1)), 10, 80))
	out["abort_conditions"] = aborts
	if sim.rivals.has_treaty(target, "peace"): notes.append("We are at peace with them - this attack breaks our oath.")
	return {"ok": true, "blueprint": out, "notes": notes}

## What a war leader knows before the march.
func war_env(target: String) -> Dictionary:
	var out: Array = []
	for id in sim.rivals.clans:
		var c: Dictionary = sim.rivals.clans[id]
		if not c["met"]: continue
		out.append({"id": id, "name": tr(c["name"]), "chieftain": tr(c["chief"]), "stance": tr(sim.rivals.stance(id)),
			"their_ways": tr(c["desc"]), "people": c["pop"], "warriors_at_home_estimate": c["warriors"] + 1,
			"treaties": sim.rivals.treaty_text(id), "behind_a_palisade": c["culture"] == "martial",
			"distance": ("across the river, " if not D.same_side(c["pos"], D.VILLAGE) else "") + "a %s walk to the %s" % ["long" if D.route_len(D.VILLAGE, c["pos"]) > 2500.0 else "short", D.compass(D.VILLAGE, c["pos"])]})
	var fighters: Array = available_helpers().map(func(u): return "%s (combat %d)" % [tr(u.name), u.lv("combat")])
	return {"enemies_known": out, "chieftain_suggests": target, "our_fighters": fighters, "bronze_weapons": sim.has_bronze(),
		"objectives": WAR_OBJECTIVE_TEXT, "season_and_weather": sim.hz.summary(), "tribe_stockpile": {"food": roundi(sim.stock["food"]), "wood": roundi(sim.stock["wood"])}}

func _int(v: Variant, fallback: int) -> int:
	if v is int or v is float: return int(v)
	if v is String and v.is_valid_float(): return int(float(v))
	return fallback

func wood_needed(bp: Dictionary) -> int:
	var w := 0
	for s in bp.get("steps", []):
		if s["action"] == "build": w += D.STRUCTURES[s["structure"]]["wood"] * s["count"]
	return w

func housing(bp: Dictionary) -> int:
	var c := 0
	for s in bp.get("steps", []):
		if s["action"] == "build": c += D.STRUCTURES[s["structure"]].get("cap", 0) * s["count"]
	return c

# ------------------------------------------------------------ creation
func create(bp: Dictionary, leader: E.Unit, directive: String) -> E.Contract:
	var c := E.Contract.new()
	c.id = sim.uid()
	c.plan = bp.duplicate(true)
	c.directive = directive
	c.leader_id = leader.id
	c.kind = bp.get("kind", "settle")
	if c.kind == "war":
		var tp: Vector2 = sim.rivals.clans[bp["target"]]["pos"]
		c.site = tp + (D.VILLAGE - tp).normalized() * 330.0
		if D.is_water(c.site): c.site = D.shore(c.site, 120.0)
	elif c.kind == "seek":
		c.site = Vector2(bp["site"][0], bp["site"][1])
	elif c.kind == "research":
		var n := list.filter(func(o): return o.kind == "research").size()
		c.site = D.VILLAGE + Vector2(-190, 170) + Vector2(70 * (n % 3), -60 * (n % 2))
	else:
		c.site = next_site()
	c.t = sim.time
	for s in bp["steps"]:
		var rs: Dictionary = s.duplicate()
		rs["done"] = 0.0
		rs["ids"] = []
		c.steps.append(rs)
	# Crew: leader + best helpers for the focus.
	var skill := "craft"
	if bp["focus"] in ["hunting", "defense", "war"]: skill = "combat"
	elif bp["focus"] in ["farming", "fishery"]: skill = "forage"
	var helpers := available_helpers(leader.id).filter(func(u): return sim.vice["steward"] != u.id and sim.vice["warchief"] != u.id)
	helpers.sort_custom(func(a, b): return a.lv(skill) + a.lv("craft") * 0.5 > b.lv(skill) + b.lv("craft") * 0.5)
	c.crew_ids = [leader.id]
	for u in helpers.slice(0, bp["crew_size"] - 1): c.crew_ids.append(u.id)
	for id in c.crew_ids:
		var u: E.Unit = sim.unit_by_id(id)
		u.role = "contract"
		u.contract_id = c.id
		sim.set_job(u, {})
	list.append(c)
	var names: Array = c.crew_ids.map(func(id): return tr(sim.unit_by_id(id).name))
	var where: String = site_where(c.site)
	if c.kind == "research": where = tr("to seek %s") % tr(sim.evo.tech_def(bp["tech"])["name"])
	elif c.kind == "seek": where = tr("to search %s for %s") % [bp.get("place_name", ""), tr(SEEK_WORDS[bp["group"]])]
	elif c.kind == "war":
		where = tr("to make war on the %s") % tr(sim.rivals.clans[bp["target"]]["name"])
		sim.evo.drift("martial", 5.0)
	sim.add_log(tr("Task Contract '%s' sealed. %s leads %s %s. The LLM connection is closed.") % [bp["plan_id"], tr(leader.name), ", ".join(names.slice(1)) if names.size() > 1 else tr("no one"), where], "contract", c.crew_ids.map(func(id): return sim.unit_by_id(id)))
	_clog(c, tr("Contract sealed: %d steps, crew of %d.") % [c.steps.size(), c.crew_ids.size()])
	sim.policy.on_contract(c)
	return c

func _clog(c: E.Contract, text: String) -> void:
	c.events.push_front("[Day %d] %s" % [sim.day(), text])
	if c.events.size() > 12: c.events.pop_back()

func crew(c: E.Contract, include_resting := false) -> Array:
	var out: Array = []
	for id in c.crew_ids + c.reinforcement_ids:
		var u: E.Unit = sim.unit_by_id(id)
		if u == null or u.dead: continue
		if not include_resting and id in c.resting_ids: continue
		out.append(u)
	return out

func leader(c: E.Contract) -> E.Unit:
	return sim.unit_by_id(c.leader_id)

func _ensure(u: E.Unit, key: String, assign: Callable) -> void:
	if u.job_key != key or u.job.is_empty():
		assign.call()
		u.job_key = key

# ------------------------------------------------------------ execution (zero LLM calls)
func update(dt: float) -> void:
	for c in list:
		if not is_running(c): continue
		if c.kind != "war" and sim.camp_asleep() and c.status != "interrupted":
			c.substate = tr("Camping for the night")
			continue
		c.state_t += dt
		_manage_wounded(c)
		var ld := leader(c)
		if ld == null or ld.dead:
			_fail(c, tr("%s fell; the expedition lost its leader.") % (tr(ld.name) if ld else tr("The leader")))
			continue
		if crew(c, true).is_empty():
			_fail(c, tr("No crew remain."))
			continue
		match c.status:
			"assembling": _assemble(c)
			"executing":
				if _check_aborts(c): continue
				_run_step(c, dt)
				c.progress = _progress(c) # (a scenario may script an ambush at some progress: story.gd)
			"defending": _defend(c, dt)
			"sheltering":
				for u in crew(c): _ensure(u, "c%d_shelter" % c.id, func(): sim.assign_move(u, c.site + Vector2(randf_range(-30, 30), randf_range(-30, 30))))
				if c.state_t > 8: _set_status(c, "executing")
			"interrupted": pass # waiting on the player / LLM

func _set_status(c: E.Contract, s: String) -> void:
	c.status = s
	c.state_t = 0.0
	c.clear_t = 0.0

func _manage_wounded(c: E.Contract) -> void:
	for u in crew(c, true):
		if u.id in c.resting_ids:
			if u.hp >= u.max_hp * 0.7:
				c.resting_ids.erase(u.id)
				sim.add_log(tr("%s has recovered and rejoins '%s'.") % [tr(u.name), c.plan["plan_id"]], "contract", [u])
			elif u.job.is_empty() and u.pos.distance_to(D.VILLAGE) > 60:
				sim.set_job(u, {"type": "move", "to": D.VILLAGE + Vector2(randf_range(-30, 30), 30), "flee": true})
		elif u.hp < u.max_hp * 0.25 and not u.has_trait("belligerent") and u.id != c.leader_id:
			c.resting_ids.append(u.id)
			sim.set_job(u, {"type": "move", "to": D.VILLAGE + Vector2(randf_range(-30, 30), 30), "flee": true})
			_clog(c, tr("%s is badly hurt and limps home.") % tr(u.name))

func _assemble(c: E.Contract) -> void:
	var all_there := true
	var i := 0
	for u in crew(c):
		i += 1
		var spot: Vector2 = c.site + Vector2(cos(i * 1.7) * 30, sin(i * 1.7) * 30)
		_ensure(u, "c%d_assemble" % c.id, func(): sim.assign_move(u, spot))
		u.act = {"settle": "Crossing the river (contract)", "war": "Marching to war"}.get(c.kind, "Gathering at the workshop")
		if u.pos.distance_to(c.site) > 70: all_there = false
	if all_there or c.state_t > (150 if c.kind == "war" else 45):
		_set_status(c, "executing")
		_clog(c, tr("Crew arrived at the site."))

func _run_step(c: E.Contract, dt: float) -> void:
	if c.step_idx >= c.steps.size():
		_complete(c)
		return
	var step: Dictionary = c.steps[c.step_idx]
	var key := "c%d_s%d" % [c.id, c.step_idx]
	var bank := D.region_at(c.site)
	match step["action"]:
		"gather_wood", "gather_food", "gather_stone":
			var res: String = step["action"].trim_prefix("gather_")
			c.substate = tr("Gathering %s %d/%d") % [tr(res), step["done"], step["target_amount"]]
			for u in crew(c):
				_ensure(u, key, func(): sim.assign_gather(u, res, {"dropoff": c.id, "area": c.site, "area_r": 650.0, "bank": bank}))
			if step["done"] >= step["target_amount"]: _next_step(c)
		"build":
			if step["ids"].is_empty():
				for k in step["count"]:
					var s = sim.add_structure(step["structure"], _slot_for(c, step["structure"]), false, "contract:%d" % c.id)
					step["ids"].append(s.id)
					c.struct_ids.append(s.id)
			var target = null
			for id in step["ids"]:
				var s = sim.struct_by_id(id)
				if s and not s.built:
					target = s
					break
			if target == null:
				_next_step(c)
				return
			var sname: String = D.STRUCTURES[target.type]["name"]
			if not target.paid:
				var cost: int = D.STRUCTURES[target.type]["wood"]
				if c.wood >= cost:
					c.wood -= cost
					target.paid = true
				else:
					c.substate = tr("Gathering timber for %s (%d/%d)") % [tr(sname), c.wood, cost]
					for u in crew(c):
						_ensure(u, key + "_mat", func(): sim.assign_gather(u, "wood", {"dropoff": c.id, "area": c.site, "area_r": 650.0, "bank": bank}))
					return
			c.substate = tr("Building %s (%d%%)") % [tr(sname), roundi(target.progress / target.work * 100)]
			for u in crew(c):
				_ensure(u, key + "_b%d" % target.id, func(): sim.assign_build(u, target))
		"seek": # comb the place: everyone roams around it, keen-eyed for the things sought
			var r := float(_seek_cfg().get("radius", 320))
			var g: String = c.plan["group"]
			var cr := crew(c)
			var there := 0
			for u in cr:
				_ensure(u, key, func(): sim.assign_seek(u, c.site, r, g))
				if u.pos.distance_to(c.site) < r + 60: there += 1
			if there > 0: step["done"] += dt * (0.4 + 0.6 * there / maxf(1, cr.size()))
			c.substate = tr("Searching %s (%ds/%ds)") % [c.plan.get("place_name", ""), step["done"], step["duration_sec"]]
			if step["done"] >= step["duration_sec"]: _next_step(c)
		"experiment":
			var tname: String = sim.evo.tech_def(c.plan["tech"])["name"]
			var cr := crew(c)
			var working := 0
			var i := 0
			for u in cr:
				var spot: Vector2 = c.site + Vector2.from_angle(i * TAU / maxf(1, cr.size())) * 26
				_ensure(u, key, func(): sim.assign_experiment(u, spot, tname))
				if u.act.begins_with("Experimenting"): working += 1
				i += 1
			var ld := leader(c)
			var rate: float = (0.4 + 0.6 * working / maxf(1, cr.size())) * (1.0 + 0.08 * ld.lv("lore") + 0.04 * ld.lv("craft"))
			if working > 0:
				step["done"] += dt * rate
				var total := 0.0
				for s2 in c.steps:
					if s2["action"] == "experiment": total += s2["duration_sec"]
				sim.evo.seed(c.plan["tech"], 0.7 * dt * rate / maxf(1.0, total), ld)
			c.substate = tr("Experimenting on %s (%ds/%ds)") % [tr(tname), step["done"], step["duration_sec"]]
			if step["done"] >= step["duration_sec"]: _next_step(c)
		"war_dance", "scout", "assault", "loot", "burn", "break", "return":
			_run_war_step(c, step, key, dt)
		"ritual":
			var ld := leader(c)
			if c.leader_id in c.resting_ids:
				_next_step(c)
				return
			c.substate = tr("%s performs the ritual (%ds/%ds)") % [tr(ld.name), step["done"], step["duration_sec"]]
			_ensure(ld, key + "_r", func(): sim.assign_ritual(ld, c.site + Vector2(0, -10)))
			if ld.job.get("type", "") == "ritual" and ld.pos.distance_to(c.site + Vector2(0, -10)) < 8:
				step["done"] += dt
			for u in crew(c):
				if u != ld: _ensure(u, key, func(): sim.assign_gather(u, "wood", {"dropoff": c.id, "area": c.site, "area_r": 650.0, "bank": bank}))
			if step["done"] >= step["duration_sec"]:
				sim.devotion = minf(100, sim.devotion + 8)
				sim.gain_xp(ld, "lore", 8)
				_next_step(c)

## War steps. Defenders are real clan people (kind "warrior", guard=true), so the fight
## itself is the ordinary unit-vs-predator combat; the executor only directs it.
func _run_war_step(c: E.Contract, step: Dictionary, key: String, dt: float) -> void:
	var R = sim.rivals
	var id: String = c.plan["target"]
	var rc: Dictionary = R.clans[id]
	var cname: String = tr(rc["name"])
	var vpos: Vector2 = rc["pos"]
	var cr := crew(c)
	match step["action"]:
		"war_dance":
			var ld := leader(c)
			c.substate = tr("War dance before the battle (%ds/%ds)") % [step.get("done", 0), step["duration_sec"]]
			var i := 0
			for u in cr:
				var spot: Vector2 = c.site + Vector2.from_angle(i * TAU / maxf(1, cr.size())) * 34
				_ensure(u, key, func(): sim.assign_ritual(u, spot))
				i += 1
			if ld.job.get("type", "") == "ritual" and ld.act == "Performing ritual": step["done"] = step.get("done", 0.0) + dt
			if step.get("done", 0.0) >= step["duration_sec"]:
				c.flags["blessed"] = true
				for u in cr: sim.gain_xp(u, "combat", 3)
				_next_step(c)
		"scout":
			c.substate = tr("Watching the %s's village (%ds/%ds)") % [cname, step.get("done", 0), step["duration_sec"]]
			var ld := leader(c)
			_ensure(ld, key, func(): sim.assign_move(ld, vpos + (c.site - vpos).normalized() * 200.0))
			for u in cr:
				if u != ld: _ensure(u, key, func(): sim.assign_move(u, c.site + Vector2(randf_range(-30, 30), randf_range(-30, 30))))
			step["done"] = step.get("done", 0.0) + dt
			if step["done"] >= step["duration_sec"]:
				c.flags["scouted"] = true
				_clog(c, tr("Scouts counted about %d warriors in the village.") % (rc["warriors"] + 1))
				_next_step(c)
		"assault":
			if not step.get("started", false):
				step["started"] = true
				var n: int = R.defend(id, c)
				step["total"] = n
				_clog(c, tr("We fall upon the %s! %d defenders come out to meet us.") % [cname, n])
			var guards: Array = sim.predators.filter(func(p): return p.clan == id and p.guard and not p.dead and not p.fled and not p.fleeing)
			c.substate = tr("Assaulting the %s (%d defenders left)") % [cname, guards.size()]
			step["left"] = guards.size()
			if guards.is_empty():
				step["clear"] = step.get("clear", 0.0) + dt
				for u in cr: _ensure(u, key + "_in", func(): sim.assign_move(u, vpos + Vector2(randf_range(-50, 50), randf_range(-40, 40))))
				if step["clear"] > 1.5:
					_clog(c, tr("The defenders of the %s are beaten.") % cname)
					_next_step(c)
				return
			for u in cr:
				if u.job.get("type", "") != "attack":
					var nearest = guards[0]
					for p in guards:
						if p.pos.distance_to(u.pos) < nearest.pos.distance_to(u.pos): nearest = p
					sim.assign_attack(u, nearest, key + "_atk")
		"loot", "burn", "break":
			var verb: String = {"loot": "Plundering", "burn": "Burning", "break": "Hunting down warriors of"}[step["action"]]
			c.substate = tr("%s the %s (%ds/%ds)") % [tr(verb), cname, step.get("done", 0), step["duration_sec"]]
			var i := 0
			for u in cr:
				var spot: Vector2 = vpos + Vector2.from_angle(i * 2.1) * (40 + 10 * i)
				_ensure(u, key, func(): sim.assign_move(u, spot))
				i += 1
			if cr.any(func(u): return u.pos.distance_to(vpos) < 130): step["done"] = step.get("done", 0.0) + dt
			if step.get("done", 0.0) >= step["duration_sec"]:
				c.flags["spoils"] = R.war_spoils(id, step["action"], c)
				_clog(c, tr("Done: %s.") % c.flags["spoils"])
				_next_step(c)
		"return":
			c.substate = tr("Marching home")
			var home_all := true
			for u in cr:
				_ensure(u, key, func(): sim.assign_move(u, D.VILLAGE + Vector2(randf_range(-60, 60), randf_range(-40, 60))))
				u.act = "Marching home"
				if u.pos.distance_to(D.VILLAGE) > 160: home_all = false
			step["done"] = step.get("done", 0.0) + dt
			if home_all or step["done"] > 150: _next_step(c)

func _next_step(c: E.Contract) -> void:
	var step: Dictionary = c.steps[c.step_idx]
	var desc := _step_text(step)
	for u in crew(c):
		var skill: String = {"gather_wood": "forage", "gather_food": "forage", "gather_stone": "forage", "build": "craft", "ritual": "lore", "experiment": "lore"}.get(step["action"], "combat")
		sim.gain_xp(u, skill, 6)
	_clog(c, tr("Step %d done: %s.") % [c.step_idx + 1, desc])
	c.step_idx += 1

func _slot_for(c: E.Contract, type: String) -> Vector2:
	if type == "palisade": return c.site
	if type == "bonfire":
		var has_center := false
		for id in c.struct_ids:
			var s = sim.struct_by_id(id)
			if s and s.type == "bonfire": has_center = true
		if not has_center: return c.site + Vector2(0, 0)
	if type == "fishing_dock":
		var info := D.river_info(c.site + Vector2(0, 60)) # on the near bank of the nearest river
		return info["c"] + info["n"] * (D.RIVER_HALF + 14) if info["d"] < INF else c.site + Vector2(140, 60)
	var p: Vector2 = c.site + SLOTS[c.slot_idx % SLOTS.size()] * (1.0 + 0.6 * (c.slot_idx / SLOTS.size()))
	c.slot_idx += 1
	return p

func deposit(c: E.Contract, res: String, amt: int, u: E.Unit) -> void:
	if res == "wood": c.wood += amt
	elif res == "food": sim.stock["food"] += amt # rations shared with the tribe
	# stone is consumed by the experiments
	if c.step_idx < c.steps.size():
		var step: Dictionary = c.steps[c.step_idx]
		if step["action"] == "gather_" + res: step["done"] += amt
	sim.popup(u.pos + Vector2(0, -12), tr("+%d %s") % [amt, tr(res)], {"wood": Color("#d8b483"), "stone": Color("#c8c8d0")}.get(res, Color("#f0a07a")))

func _progress(c: E.Contract) -> float:
	var total := 0.0
	var done := 0.0
	for i in c.steps.size():
		var s: Dictionary = c.steps[i]
		var w := 0.0
		var d := 0.0
		match s["action"]:
			"gather_wood", "gather_food", "gather_stone":
				w = s["target_amount"]
				d = minf(s["done"], w)
			"experiment", "seek":
				w = s["duration_sec"] * 3.0
				d = minf(s["done"] * 3.0, w)
			"build":
				w = D.STRUCTURES[s["structure"]]["work"] * s["count"]
				for id in s["ids"]:
					var st = sim.struct_by_id(id)
					if st: d += minf(st.progress, st.work)
			"ritual", "war_dance", "scout", "loot", "burn", "break":
				w = s["duration_sec"] * 2.0
				d = minf(s.get("done", 0.0) * 2.0, w)
			"assault":
				w = 40.0
				if s.get("started", false): d = w * (1.0 - float(s.get("left", 0)) / maxf(1.0, s.get("total", 1)))
			"return":
				w = 20.0
				d = minf(s.get("done", 0.0) / 60.0, 1.0) * w
		if i < c.step_idx: d = w
		total += w
		done += d
	return done / total if total > 0 else 1.0

# ------------------------------------------------------------ abort conditions
func _check_aborts(c: E.Contract) -> bool:
	var reason := ""
	for cond in c.plan["abort_conditions"]:
		if cond == "enemy_attack":
			var near: bool = not sim.active_predators_near(c.site, 260).is_empty()
			for u in crew(c):
				if sim.time - u.last_hit_t < 1.0: near = true
			if near: reason = "enemy_attack"
		elif cond == "heavy_losses":
			var total: int = c.crew_ids.size() + c.reinforcement_ids.size()
			if total >= 2 and crew(c).size() * 2 <= total: reason = "heavy_losses" # half the party dead or limping home
		elif cond == "natural_disaster":
			if sim.flags.get("flood_active", -1.0) >= c.t or sim.flags.get("disaster_t", -1.0) >= c.t: reason = "natural_disaster"
		elif cond.begins_with("hp_below_"):
			var pct := float(cond.trim_prefix("hp_below_").trim_suffix("%")) / 100.0
			var ld := leader(c)
			if c.leader_id not in c.resting_ids and ld.hp < ld.max_hp * pct: reason = "leader_wounded"
		if reason != "" and c.abort_cooldowns.get(reason, -1.0) > sim.time: reason = ""
		if reason != "": break
	if reason == "": return false
	c.abort_reason = reason
	c.interruptions += 1
	_set_status(c, "interrupted")
	for u in crew(c): sim.set_job(u, {})
	_clog(c, tr("ABORT CONDITION: %s at %d%% progress.") % [tr(reason), roundi(c.progress * 100)])
	sim.add_log(tr("Contract '%s' interrupted (%s). The leader's LLM node is re-awakening...") % [c.plan["plan_id"], tr(reason)], "danger")
	sim.paused = true
	sim.contract_interrupted.emit(c)
	return true

func allowed_effects(c: E.Contract) -> Array:
	match c.abort_reason:
		"enemy_attack":
			var fx := ["hold", "reinforce", "retreat"]
			if sim.stock["lore"] >= 10: fx.append("ward")
			return fx
		"leader_wounded": return ["rest", "press_on", "retreat"]
		"natural_disaster": return ["shelter", "retreat"]
		"heavy_losses": return ["press_on", "reinforce", "retreat"]
	return ["hold", "retreat"]

func summary(c: E.Contract) -> Dictionary:
	var built: Array = []
	var partial: Array = []
	for id in c.struct_ids:
		var s = sim.struct_by_id(id)
		if s == null: continue
		var n: String = tr(D.STRUCTURES[s.type]["name"])
		if s.built: built.append(n)
		elif s.progress > 0: partial.append("%s (%d%%)" % [n, roundi(s.progress / s.work * 100)])
	var ld := leader(c)
	var crew_state: Array = crew(c, true).map(func(u): return "%s %d/%d HP" % [tr(u.name), roundi(u.hp), roundi(u.max_hp)])
	return {
		"plan_id": c.plan["plan_id"], "progress_pct": roundi(c.progress * 100),
		"current_step": c.substate, "built": built, "half_built": partial,
		"threat": _threat_text(c.site),
		"reason": c.abort_reason, "disaster": sim.flags.get("disaster", "blizzard") if sim.flags.get("disaster_t", -1.0) > sim.flags.get("flood_active", -1.0) else "flood", "leader_hp": "%d/%d" % [roundi(ld.hp), roundi(ld.max_hp)],
		"crew": crew_state, "tribe_lore": roundi(sim.stock["lore"]),
		"idle_warriors_in_village": available_helpers().size(),
	}

func _threat_text(site: Vector2) -> String:
	var near: Array = sim.active_predators_near(site, 500)
	var parts: Array = []
	var beasts: int = near.filter(func(p): return p.clan == "").size()
	if beasts > 0: parts.append(tr("%d saber-toothed tigers") % beasts)
	for id in sim.rivals.clans:
		var n: int = near.filter(func(p): return p.clan == id).size()
		if n > 0: parts.append(tr("%d warriors of the %s") % [n, tr(sim.rivals.clans[id]["name"])])
	return ", ".join(parts) if not parts.is_empty() else tr("none visible")

# ------------------------------------------------------------ resolution
func resolve(c: E.Contract, effect: String, label := "") -> void:
	if effect not in allowed_effects(c): effect = allowed_effects(c)[0]
	var ld := leader(c)
	_clog(c, tr("Chieftain's decision: %s") % (label if label != "" else tr(EFFECTS.get(effect, effect))))
	c.abort_cooldowns[c.abort_reason] = sim.time + 5.0
	match effect:
		"hold":
			_set_status(c, "defending")
		"reinforce":
			var helpers := available_helpers()
			helpers.sort_custom(func(a, b): return a.lv("combat") > b.lv("combat"))
			for u in helpers.slice(0, 3):
				u.role = "contract"
				u.contract_id = c.id
				c.reinforcement_ids.append(u.id)
				sim.set_job(u, {})
			sim.add_log(tr("%d warriors rush out to reinforce '%s'.") % [mini(3, helpers.size()), c.plan["plan_id"]], "contract")
			if c.kind == "war":
				c.abort_cooldowns["heavy_losses"] = sim.time + 60.0
				_set_status(c, "executing")
			else: _set_status(c, "defending")
		"ward":
			sim.stock["lore"] -= 10
			var n: int = sim.scare_predators(c.site, 600)
			sim.gain_xp(ld, "lore", 12)
			sim.remember(ld, tr("drove off %d beasts with a totem ward on Day %d") % [n, sim.day()], 8)
			sim.popup(c.site + Vector2(0, -50), tr("Totem Ward!"), Color("#c8a8ff"), true)
			_set_status(c, "executing")
		"retreat":
			for u in crew(c, true):
				if c.kind == "war": sim.remember(u, tr("fled from the battle with the %s on Day %d") % [tr(sim.rivals.clans[c.plan["target"]]["name"]), sim.day()], 7)
				else: sim.remember(u, tr("abandoned the half-built camp '%s' on Day %d") % [c.plan["plan_id"], sim.day()], 7)
				_release(u)
				sim.assign_flee(u)
			sim.add_log(tr("'%s' abandoned at %d%%. The crew flees for home.") % [c.plan["plan_id"], roundi(c.progress * 100)], "danger")
			c.status = "abandoned"
		"rest":
			c.resting_ids.append(ld.id)
			sim.set_job(ld, {"type": "move", "to": D.VILLAGE, "flee": true})
			c.abort_cooldowns["leader_wounded"] = INF
			_set_status(c, "executing")
		"press_on":
			c.abort_cooldowns[c.abort_reason] = INF if c.abort_reason == "heavy_losses" else sim.time + 45.0
			_set_status(c, "executing")
		"shelter":
			c.abort_cooldowns["natural_disaster"] = INF
			_set_status(c, "sheltering")
	if effect != "shelter" and c.abort_reason == "natural_disaster": c.abort_cooldowns["natural_disaster"] = INF

func _defend(c: E.Contract, dt: float) -> void:
	var threats: Array = sim.active_predators_near(c.site, 450)
	var crew_list := crew(c)
	if threats.is_empty():
		c.clear_t += dt
		if c.clear_t > 2.5:
			for u in crew_list:
				sim.remember(u, tr("held the half-built camp '%s' against saber-tooths on Day %d") % [c.plan["plan_id"], sim.day()], 8)
			_clog(c, tr("The beasts are gone. Resuming the blueprint where we left off."))
			sim.add_log(tr("'%s' secured. The state machine resumes - no LLM needed.") % c.plan["plan_id"], "contract")
			_set_status(c, "executing")
		return
	c.clear_t = 0
	c.substate = tr("Defending the camp")
	for u in crew_list:
		if u.job.get("type", "") != "attack":
			var nearest = threats[0]
			for p in threats:
				if p.pos.distance_to(u.pos) < nearest.pos.distance_to(u.pos): nearest = p
			sim.assign_attack(u, nearest, "c%d_def" % c.id)

func _release(u: E.Unit) -> void:
	u.role = ""
	u.contract_id = -1
	u.job_key = ""

func _complete(c: E.Contract) -> void:
	c.status = "done"
	c.progress = 1.0
	sim.stock["wood"] += c.wood
	c.wood = 0
	if c.kind == "research":
		_complete_research(c)
		return
	if c.kind == "war":
		_complete_war(c)
		return
	if c.kind == "seek":
		_complete_seek(c)
		return
	var built: Array = []
	for id in c.struct_ids:
		var s = sim.struct_by_id(id)
		if s and s.built: built.append(D.STRUCTURES[s.type]["name"])
	var ld := leader(c)
	var what := ", ".join(built)
	for u in crew(c, true):
		if c.reinforcement_ids.has(u.id):
			sim.remember(u, tr("helped defend and finish '%s' on Day %d") % [c.plan["plan_id"], sim.day()], 6)
			u.home = D.VILLAGE
		else:
			var lead: bool = u == ld
			sim.remember(u, (tr("led the founding of '%s' on the frontier on Day %d (%s)") if lead else tr("helped the founding of '%s' on the frontier on Day %d (%s)")) % [c.plan["plan_id"], sim.day(), what], 9 if lead else 7)
			sim.gain_xp(u, "craft", 10)
			if lead: sim.gain_xp(u, "combat", 15) # leadership
			u.home = c.site
		_release(u)
		sim.set_job(u, {})
	sim.popup(c.site + Vector2(0, -80), tr("Outpost founded!"), Color("#b6f28a"), true)
	sim.inv.feat("outpost", tr("Founded the outpost '%s'") % c.plan["plan_id"], ld,
		{"desc": tr("A new settlement on the frontier: %s.") % ", ".join(built.map(func(n): return tr(n))), "at": c.site})
	sim.add_log(tr("Contract '%s' complete! %s. Housing for %d more.") % [c.plan["plan_id"], what, housing(c.plan)], "contract")
	sim.contract_finished.emit(c)

func _complete_war(c: E.Contract) -> void:
	var ld := leader(c)
	var cname: String = tr(sim.rivals.clans[c.plan["target"]]["name"])
	var spoils: String = c.flags.get("spoils", "")
	for u in crew(c, true):
		var lead: bool = u == ld
		sim.remember(u, (tr("led the war party against the %s on Day %d (%s)") if lead else tr("fought in the war party against the %s on Day %d (%s)")) % [cname, sim.day(), spoils], 9 if lead else 7)
		sim.gain_xp(u, "combat", 15 if lead else 10)
		_release(u)
		sim.set_job(u, {})
	sim.popup(D.VILLAGE + Vector2(0, -80), tr("The war party returns!"), Color("#ffb07a"), true)
	sim.add_log(tr("War contract '%s' complete against the %s: %s.") % [c.plan["plan_id"], cname, spoils], "contract")
	sim.contract_finished.emit(c)

func _complete_research(c: E.Contract) -> void:
	var ld := leader(c)
	var id: String = c.plan["tech"]
	var t: Dictionary = sim.evo.tech_def(id)
	var fresh: bool = not sim.has_tech(id)
	if fresh: sim.evo.breakthrough(id, ld, "invented")
	for u in crew(c, true):
		if u != ld:
			sim.remember(u, tr("helped %s %s %s on Day %d") % [tr(ld.name), tr("discover") if fresh else tr("refine"), tr(t["name"]), sim.day()], 6)
		sim.evo.learn(u, id)
		sim.gain_xp(u, "lore", 8)
		_release(u)
		sim.set_job(u, {})
	sim.gain_xp(ld, "combat", 8) # leadership
	if not fresh:
		sim.stock["lore"] += 15
		sim.add_log(tr("'%s' finished, but %s was already known - the work became 15 lore.") % [c.plan["plan_id"], tr(t["name"])], "contract")
	else:
		sim.add_log(tr("Research contract '%s' complete: %s now knows %s.") % [c.plan["plan_id"], tr(ld.name), tr(t["name"])], "contract", [ld])
	sim.contract_finished.emit(c)

## Back from the search: what they found (c.flags["found"], filled by sim.discover_find).
func _complete_seek(c: E.Contract) -> void:
	var ld := leader(c)
	var found: Array = c.flags.get("found", [])
	var names: Array = found.map(func(id): return tr(D.FINDS[id]["name"]))
	var skill: String = str(sim.DISC.get("groups", {}).get(c.plan["group"], {}).get("skill", "forage"))
	for u in crew(c, true):
		sim.remember(u, (tr("searched %s and found %s on Day %d") % [c.plan.get("place_name", ""), ", ".join(names), sim.day()]) if not found.is_empty() else (tr("searched %s and found nothing new on Day %d") % [c.plan.get("place_name", ""), sim.day()]), 5 if not found.is_empty() else 2)
		sim.gain_xp(u, skill, 10 if not found.is_empty() else 4)
		_release(u)
		sim.set_job(u, {})
	if found.is_empty(): sim.add_log(tr("The search '%s' is over: %s found nothing new in %s.") % [c.plan["plan_id"], tr(ld.name), c.plan.get("place_name", "")], "contract", [ld])
	else: sim.add_log(tr("The search '%s' is over: %s's crew found %s.") % [c.plan["plan_id"], tr(ld.name), ", ".join(names)], "contract", [ld])
	sim.contract_finished.emit(c)

func _fail(c: E.Contract, why: String) -> void:
	c.status = "failed"
	for u in crew(c, true): _release(u)
	sim.add_log(tr("Contract '%s' failed: %s") % [c.plan["plan_id"], why], "danger")

func _step_text(s: Dictionary) -> String:
	match s["action"]:
		"gather_wood": return tr("gather %d wood") % s["target_amount"]
		"gather_food": return tr("gather %d food") % s["target_amount"]
		"gather_stone": return tr("quarry %d stone") % s["target_amount"]
		"experiment": return tr("%ds of experiments") % s["duration_sec"]
		"seek": return tr("%ds of searching") % s["duration_sec"]
		"build": return tr("build %s%s") % [("%d x " % s["count"]) if s["count"] > 1 else "", tr(D.STRUCTURES[s["structure"]]["name"])]
		"ritual": return tr("%ds blessing ritual") % s["duration_sec"]
		"war_dance": return tr("%ds war dance") % s["duration_sec"]
		"scout": return tr("watch their village for %ds") % s["duration_sec"]
		"assault": return tr("assault the village")
		"loot": return tr("plunder their stores")
		"burn": return tr("burn their huts")
		"break": return tr("hunt down their warriors")
		"return": return tr("march home")
	return s["action"]

func step_text(s: Dictionary) -> String: return _step_text(s)
