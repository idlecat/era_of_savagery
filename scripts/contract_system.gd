## Task Contracts (PRD 2.2.2): LLM blueprint -> sanitized plan -> deterministic executor.
## Once a contract is confirmed, NOTHING in this file calls the LLM. Interruptions are
## surfaced via sim.contract_interrupted, and the UI decides whether to wake the LLM.
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")
const Config = preload("res://scripts/config.gd")

const SLOTS := [Vector2(-48, -42), Vector2(48, -42), Vector2(-48, 42), Vector2(48, 42), Vector2(0, -72),
	Vector2(0, 72), Vector2(-78, 0), Vector2(78, 0), Vector2(-30, -20), Vector2(30, 20)]
const EFFECTS := {
	"hold": "Crew stands its ground and fights",
	"reinforce": "Send up to 3 warriors from the village, crew holds",
	"retreat": "Abandon the task and flee back to the village",
	"ward": "Totem ritual drives beasts away (costs %d lore)",
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
## Where search quests have combed, newest last: [{"group", "pos", "day", "found": [find ids], "place"}].
var searched: Array = []
## What leaders say: the forecast before sealing and the field log during the work (A0/A1).
var LOG: Dictionary = preload("res://scripts/config.gd").load_cfg("contract_log")

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

## Whether a running contract still builds `s` (its own site): the Steward leaves it to the
## crew. Once the contract is over, its buildings are the settlement's to rebuild.
func works_on(s: E.Structure) -> bool:
	if not s.owner.begins_with("contract:"): return false
	var c := by_id(int(s.owner.trim_prefix("contract:")))
	return c != null and is_running(c)

# ------------------------------------------------------------ context for the LLM
## Who can join a Task Contract: free grown-ups at one of our settlements (sim.at_settlement);
## with `at`, only those on the same land as `at` (a leader's crew comes from where they stand).
func available_helpers(exclude_id := -1, at: Variant = null) -> Array:
	return sim.living().filter(func(u): return u.role == "" and u.id != exclude_id and sim.at_settlement(u.pos) and (not (at is Vector2) or D.same_side(u.pos, at)))

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
		"trade": tr(sim.careers.title(u)) if u.career != "" else tr("none: they do whatever is asked"),
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
		if sd.has("tech") and not sim.has_tech(sd["tech"]) or sim.evo.era < int(sd.get("era", 1)): continue
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

## What players call a settlement: its founder's outpost (translated; the plan id is an id).
func settlement_label(c: E.Contract) -> String:
	var ld: E.Unit = sim.unit_by_id(c.leader_id)
	return tr("%s's Outpost") % tr(ld.name) if ld else tr("Outpost")

## A contract's name as players read it, translated (rules.json contracts.titles by
## kind); plan_id is an internal id the leader picks. Takes a blueprint or plan.
func title(plan: Dictionary) -> String:
	var kind := str(plan.get("kind", "settle"))
	var fmt := str(sim.RULES.get("contracts", {}).get("titles", {}).get(kind, ""))
	var what := ""
	match kind:
		"research":
			var td: Dictionary = sim.evo.tech_def(str(plan.get("tech", "")))
			what = tr(td["name"]) if td.has("name") else ""
		"war":
			var rc: Dictionary = sim.rivals.clans.get(str(plan.get("target", "")), {})
			what = tr(rc["name"]) if rc.has("name") else ""
		"seek": what = tr(SEEK_WORDS.get(str(plan.get("group", "")), ""))
		_:
			var lid := str(plan.get("leader_id", "")).trim_prefix("unit_")
			var ld: E.Unit = sim.unit_by_id(int(lid)) if lid.is_valid_int() else null # (no leader named: nobody, never person #0)
			what = tr(ld.name) if ld else ""
	if fmt == "" or what == "": return str(plan.get("plan_id", ""))
	return tr(fmt) % what

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
	if kind == "seek" and not seek_group in SEEK_GROUPS and sim.rumoured_group() != "": seek_group = sim.rumoured_group() # (the remedy the elder remembers)
	if kind == "seek" and not seek_group in SEEK_GROUPS: # (left to the leader: what their temperament seeks)
		seek_group = preload("res://scripts/persona_engine.gd").SEEK_TASTE.get(sim.arch(u), "food")
	return {
		"kind": kind, "world": sim.evo.world_ctx(), "candidates": research_candidates(),
		"arch": sim.arch(u), "leader": leader_profile(u), "env": env_data(next_site()) if kind == "settle" else (war_env(terms.get("target", "")) if kind == "war" else (seek_env(seek_group, _home(u), u) if kind == "seek" else research_env())),
		"seek_group": seek_group,
		"directive": directive, "terms": terms, "terms_set": terms_set,
		"player_message": player_message, "previous": previous, "history": history,
		"has_farming": sim.has_tech("farming"), "max_crew": mini(6 if kind == "war" else 5, available_helpers(u.id, u.pos).size() + 1),
		"top_memory": top,
		"objection": _objection_words(sim.policy.objection(u, kind)),
		"forecast": ctx_forecast(u, kind, terms, previous),
	}

## The odds for the negotiation (the leader argues from the same numbers the chieftain
## sees): of the plan on the table, else of the kind's usual abort conditions.
func ctx_forecast(u: E.Unit, kind: String, terms: Dictionary, previous: Variant) -> Dictionary:
	var plan: Dictionary = previous if previous is Dictionary and previous.get("abort_conditions") is Array else {}
	if plan.is_empty():
		var home := _home(u)
		plan = {"kind": kind, "target": str(terms.get("target", "")), "abort_conditions": LOG["forecast"]["default_aborts"].get(kind, []), "base": [home.x, home.y]}
		if kind == "seek":
			var pl := seek_places(str(terms.get("group", "food")) if str(terms.get("group", "")) in SEEK_GROUPS else "food", home)
			if not pl.is_empty(): plan["site"] = [pl[0]["pos"].x, pl[0]["pos"].y]
	var fc := forecast(plan, u)
	return {"risk_pct": fc["pct"], "words": fc["words"], "reasons": fc["reasons"].map(func(r): return {"trouble": r["id"], "chance_pct": roundi(float(r["score"]) * 100)})}

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
## `home`: the settlement the search sets out from (nearest first from there).
func seek_places(group: String, home: Vector2 = D.VILLAGE) -> Array:
	var kinds: Array = _seek_cfg().get("groups", {}).get(group, ["forest", "meadow"])
	var out: Array = []
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
				for key in best.slice(0, int(_seek_cfg().get("forest_cells", 3))):
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
					out.append({"kind": "riverbank", "pos": sim.dry_spot(q + (home - q).normalized() * 90.0)})
			"hills": # rocky landmarks
				for lm in sim.landmarks:
					if lm["kind"] in ["peak", "stones", "cave", "flint"]: out.append({"kind": "hills", "pos": lm["pos"] + Vector2(90, 60), "lm": lm})
			"volcano":
				if D.has_volcano(): out.append({"kind": "volcano", "pos": D.VOLCANO + (home - D.VOLCANO).normalized() * 420.0})
	out = out.filter(func(pl): return not D.in_river(pl["pos"]))
	for pl in out: pl["searched"] = last_search(group, pl["pos"])
	out.sort_custom(func(a, b): # (places combed lately come after the fresh ones)
		if a["searched"].is_empty() != b["searched"].is_empty(): return a["searched"].is_empty()
		return a["pos"].distance_to(home) < b["pos"].distance_to(home))
	out = out.slice(0, int(_seek_cfg().get("places", 4)))
	for pl in out: pl["name"] = _place_name(pl, home)
	return out

## The latest search for `group` that combed the ground around `pos` within the last
## `seek.searched.rest_days` days ({"group", "pos", "day", "found", "place"}), else {}.
func last_search(group: String, pos: Vector2) -> Dictionary:
	var cfg: Dictionary = _seek_cfg().get("searched", {})
	var reach := float(_seek_cfg().get("radius", 320)) * float(cfg.get("overlap", 1.0))
	for i in range(searched.size() - 1, -1, -1):
		var r: Dictionary = searched[i]
		if sim.day() - int(r["day"]) > int(cfg.get("rest_days", 6)): break
		if r["group"] == group and r["pos"].distance_to(pos) < reach: return r
	return {}

## A past search in words for the leader: {"on_day", "found": [names], empty if nothing new}.
func _search_words(r: Dictionary) -> Dictionary:
	if r.is_empty(): return {}
	return {"on_day": int(r["day"]), "found": r["found"].map(func(id): return tr(D.FINDS[id]["name"]))}

## "the woods to the north-east", "the hills by Flint Ridge"...
func _place_name(pl: Dictionary, home: Vector2) -> String:
	var d: Vector2 = pl["pos"] - home
	var iso_d := Vector2(d.x - d.y, d.x + d.y) # (screen directions: up is north)
	var dir: String = ["east", "south-east", "south", "south-west", "west", "north-west", "north", "north-east"][posmod(roundi(iso_d.angle() / (TAU / 8)), 8)]
	var what: String = {"forest": "the woods to the %s", "meadow": "the open meadows to the %s", "riverbank": "the riverbank to the %s", "hills": "the rocky hills to the %s", "volcano": "the slopes of the Fire Mountain to the %s"}[pl["kind"]]
	if pl.has("lm") and pl["lm"]["found"]: return tr("the rocks by %s") % tr(pl["lm"]["name"])
	return tr(what) % tr(dir)

## `leader_u`: who would lead it (their crew, best eyes first, is shown as `searchers`).
func seek_env(group: String, home: Vector2 = D.VILLAGE, leader_u: E.Unit = null) -> Dictionary:
	var places: Array = seek_places(group if group in SEEK_GROUPS else "food", home)
	var known: Array = sim.known_finds.keys().filter(func(id): return D.FINDS[id].get("group", "") == group).map(func(id): return tr(D.FINDS[id]["name"]))
	return {
		"looking_for": tr(SEEK_WORDS.get(group, "new foods")) if group != "" else tr("whatever is new: foods, healing plants, stones"),
		"places_you_could_search": places.map(func(pl): return {"index": places.find(pl), "place": pl["name"], "kind": pl["kind"], "paces_away": roundi(pl["pos"].distance_to(home)), "seen_before": sim.is_explored(pl["pos"]), "we_searched_here": _search_words(pl["searched"])}),
		"the_elders_remember": {"grows_in": sim.rumoured_place(group), "what": sim.rumoured.keys().filter(func(id): return D.FINDS[id]["group"] == group).map(func(id): return tr(D.FINDS[id]["name"]))} if sim.rumoured_place(group) != "" else {},
		"already_known_to_the_tribe": known,
		"days_you_may_search": _seek_cfg().get("days", [1, 3]),
		"searchers": _searchers(group, leader_u),
		"population": sim.living().size(), "season_and_weather": sim.hz.summary(),
	}

## Searchers in the order they would be taken: those who can tell all the group's unknown finds
## first, then the keenest eyes (sim.find_eye).
func seek_crew(helpers: Array, group: String) -> Array:
	var out := helpers.duplicate()
	out.sort_custom(func(a, b):
		var ba: int = sim.blind_to(a, group).size()
		var bb: int = sim.blind_to(b, group).size()
		if ba != bb: return ba < bb
		return sim.find_eye(a, group) > sim.find_eye(b, group))
	return out

## Who may go with `leader`: free helpers on their land, not the Steward or the War Chief.
func crew_pool(leader: E.Unit) -> Array:
	return available_helpers(leader.id, leader.pos).filter(func(u): return sim.vice["steward"] != u.id and sim.vice["warchief"] != u.id)

## The leader and the helpers a search would take, in the order they would be taken
## (crew_size n = the first n), each in words.
func _searchers(group: String, leader_u: E.Unit) -> Dictionary:
	if leader_u == null: return {}
	var g := group if group in SEEK_GROUPS else "food"
	return {"you": _seeker_words(leader_u, g),
		"would_go_with_you_in_this_order": seek_crew(crew_pool(leader_u), g).slice(0, int(_seek_cfg().get("crew_max", 4)) - 1).map(func(u): return _seeker_words(u, g))}

## A searcher in words for the leader: skill, telling traits, eye, what they would miss.
func _seeker_words(u: E.Unit, group: String) -> Dictionary:
	var g: Dictionary = sim.DISC.get("groups", {}).get(group, {})
	var sk := str(g.get("skill", "forage"))
	return {"name": tr(u.name), "skill": tr(D.SKILL_NAMES[sk]), "level": u.lv(sk),
		"traits_that_count": g.get("traits", {}).keys().filter(func(t): return u.has_trait(t)).map(func(t): return tr(D.TRAITS[t]["name"])),
		"eye": snappedf(sim.find_eye(u, group), 0.01), "cannot_tell": sim.blind_to(u, group).size()}

func _sanitize_seek(bp: Dictionary, terms: Dictionary, leader: E.Unit) -> Dictionary:
	var notes: Array = []
	var out := {"kind": "seek"}
	var pid := RegEx.create_from_string("[^a-z0-9_]").sub(str(bp.get("plan_id", "")).to_lower().replace(" ", "_"), "", true).left(40)
	out["plan_id"] = pid if pid != "" else "search_%02d" % (list.size() + 1)
	out["leader_id"] = "unit_%d" % leader.id
	out["crew_size"] = clampi(_int(bp.get("crew_size"), terms.get("crew_size", 2)), 1, mini(int(_seek_cfg().get("crew_max", 4)), available_helpers(leader.id, leader.pos).size() + 1))
	var g := str(bp.get("group", "")).to_lower()
	g = {"foods": "food", "plants": "medicine", "herbs": "medicine", "healing": "medicine", "stone": "ore", "stones": "ore", "ores": "ore", "minerals": "ore", "mineral": "ore"}.get(g, g)
	if str(terms.get("group", "")) in SEEK_GROUPS and g != terms["group"]:
		if g != "": notes.append("The Chieftain asked for %s." % SEEK_WORDS[terms["group"]])
		g = terms["group"]
	if not g in SEEK_GROUPS: g = "food"
	out["group"] = g
	var places := seek_places(g, _home(leader))
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
		"summary": summary(c), "allowed": allowed_effects(c), "effects": effect_texts(), "ward_cost": int(sim.RULES["ward"]["cost"].get("lore", 0)), "world": sim.evo.world_ctx(),
	}

# ------------------------------------------------------------ blueprint sanitizing
## LLM output is untrusted: clamp every number, whitelist every enum. Returns
## {"ok": bool, "blueprint": Dictionary, "notes": Array[String]}.
## The settlement `u` would set out from (the home village when they're away from all of ours).
func _home(u: E.Unit) -> Vector2:
	var h: Vector2 = sim.home_of(u.pos)
	return D.VILLAGE if h == Vector2.INF else h

## The plan's "base" is set here from where the leader stands (never from the LLM).
func sanitize(raw: Variant, terms: Dictionary, leader: E.Unit) -> Dictionary:
	var r := _sanitize_kind(raw, terms, leader)
	var home := _home(leader)
	r["blueprint"]["base"] = [home.x, home.y]
	return r

func _sanitize_kind(raw: Variant, terms: Dictionary, leader: E.Unit) -> Dictionary:
	var bp0: Dictionary = raw if raw is Dictionary else {}
	var kind0: String = str(terms.get("kind", bp0.get("kind", "settle")))
	if kind0 == "research": return _sanitize_research(bp0, terms, leader)
	if kind0 == "war": return _sanitize_war(bp0, terms, leader)
	if kind0 == "seek": return _sanitize_seek(bp0, terms, leader)
	var notes: Array = []
	var bp: Dictionary = bp0
	var max_crew := mini(5, available_helpers(leader.id, leader.pos).size() + 1)
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
				if sim.evo.era < int(sd.get("era", 1)) and D.STRUCTURES.has(str(sd.get("instead", ""))): # (an age not reached yet: its stand-in)
					notes.append(tr("%s needs a later age; replaced with a %s.") % [tr(sd["name"]), tr(D.STRUCTURES[sd["instead"]]["name"])])
					st = str(sd["instead"])
					sd = D.STRUCTURES[st]
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
	out["crew_size"] = clampi(_int(bp.get("crew_size"), terms.get("crew_size", 2)), 1, mini(4, available_helpers(leader.id, leader.pos).size() + 1))
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
	out["crew_size"] = clampi(_int(bp.get("crew_size"), terms.get("crew_size", 4)), 2, mini(6, available_helpers(leader.id, leader.pos).size() + 1))
	if available_helpers(leader.id, leader.pos).is_empty(): out["crew_size"] = 1
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
## Seal a contract in one operation (the HUD, a game master and the metric harness all use
## it): `reply` is the plan from the leader's LLM node or a game master; with none, the
## offline persona proposes one. Either way it goes through sanitize(). `terms` are the
## chieftain's terms (crew_size, capacity_target, focus / target, objective / tech / group).
## Returns {ok, contract, notes}.
## Why no new outpost can be founded now ("" = it can): while one of ours still has
## rules.json contracts.settle_room beds or more to spare, people should go there first.
func settle_block() -> String:
	var room := int(sim.RULES["contracts"].get("settle_room", 3))
	for p in sim.settlements():
		if p == D.VILLAGE: continue
		var free: int = sim.beds_at(p) - sim.residents_of(p).size()
		if free >= room: return tr("%s still has %d beds free") % [sim.settlement_name(p), free]
	return ""

func seal(leader: E.Unit, kind := "settle", directive := "", terms := {}, reply: Variant = null) -> Dictionary:
	if leader == null or leader.dead or leader.role != "" or not kind in ["settle", "research", "war", "seek"]:
		return {"ok": false, "contract": null, "notes": [tr("No one free to lead it")]}
	if kind == "settle" and settle_block() != "":
		return {"ok": false, "contract": null, "notes": [settle_block()]}
	if kind == "war" and not sim.ranks.may(leader, "lead_war"):
		return {"ok": false, "contract": null, "notes": [sim.ranks.block("lead_war", leader)]}
	var raw: Variant = reply
	if not raw is Dictionary or raw.is_empty():
		var ctx := negotiation_ctx(leader, directive, terms, not terms.is_empty(), "", {}, [], kind)
		raw = preload("res://scripts/persona_engine.gd").propose(ctx).get("blueprint", {})
	var san := sanitize(raw, terms, leader)
	if not san["ok"]: return {"ok": false, "contract": null, "notes": san["notes"]}
	return {"ok": true, "contract": create(san["blueprint"], leader, directive), "notes": san["notes"]}

# ------------------------------------------------------------ the odds (make_it_fun A0)
## Where a plan's crew would work: the outpost site, the search place, the war camp
## before the clan's village, or the workshop by the fire.
## The settlement a plan sets out from and comes back to (its "base", set by sanitize() from
## where the leader stood; the home village when missing or not one of ours).
func base_of(bp: Dictionary) -> Vector2:
	var b: Variant = bp.get("base")
	if b is Array and b.size() == 2 and (b[0] is float or b[0] is int) and (b[1] is float or b[1] is int):
		var p := Vector2(b[0], b[1])
		if sim.settlements().any(func(q): return q.distance_to(p) < 1.0): return p
	return D.VILLAGE

func plan_site(bp: Dictionary) -> Vector2:
	var home := base_of(bp)
	match str(bp.get("kind", "settle")):
		"war":
			var rc: Dictionary = sim.rivals.clans.get(str(bp.get("target", "")), {})
			if rc.is_empty(): return home
			var tp: Vector2 = rc["pos"]
			var p: Vector2 = tp + (home - tp).normalized() * 330.0
			return D.shore(p, 120.0) if D.is_water(p) else p
		"seek":
			var st: Variant = bp.get("site")
			if st is Array and st.size() == 2 and (st[0] is float or st[0] is int) and (st[1] is float or st[1] is int): return Vector2(st[0], st[1])
			return home
		"research":
			var n := list.filter(func(o): return o.kind == "research").size()
			return home + Vector2(-190, 170) + Vector2(70 * (n % 3), -60 * (n % 2))
	return next_site()

## The odds the leader reads before sealing: for each of the plan's abort conditions, the
## chance it fires, from the same things that would fire it in _check_aborts, as far as the
## tribe knows them (fog of war: only seen beasts, found dens, met clans). The numbers and
## words are config/contract_log.json "forecast". A game master may call it with any plan.
## Returns {risk 0..1, pct, reasons: [{id, score, text}] (most likely first), words}.
func forecast(bp: Variant, leader: E.Unit = null) -> Dictionary:
	var F: Dictionary = LOG["forecast"]
	var plan: Dictionary = bp if bp is Dictionary else {}
	var kind := str(plan.get("kind", "settle"))
	if not kind in ["settle", "research", "war", "seek"]: kind = "settle"
	var conds: Array = plan.get("abort_conditions", []) if plan.get("abort_conditions") is Array else []
	var site := plan_site(plan)
	var mult: float = sim.hz.mult()
	var calm: float = float(F["mercy_mult"]) if sim.time < sim.director.mercy_until else 1.0
	var enemy := _fc_enemy(F["enemy_attack"], kind, plan, site, mult)
	var reasons: Array = []
	for cond in conds:
		var cs := str(cond)
		var r := {}
		if cs == "enemy_attack": r = {"id": "enemy_attack", "score": enemy["score"], "text": enemy["text"]}
		elif cs == "natural_disaster": r = _fc_disaster(F["natural_disaster"], F["days"].get(kind, 1.0), plan, mult)
		elif cs == "heavy_losses": r = _fc_losses(F["heavy_losses"], plan, leader)
		elif cs.begins_with("hp_below_"): r = _fc_wound(F["leader_wounded"], cs, leader, kind, enemy["score"])
		if r.is_empty() or reasons.any(func(o): return o["id"] == r["id"]): continue
		r["score"] = clampf(float(r["score"]) * calm, 0.0, 1.0)
		reasons.append(r)
	if leader != null and kind != "research": # (not an abort condition: the cost of the walk in a cold that kills, weigh.gd)
		var tp: Dictionary = sim.weigh.trip(leader, site, 0.0, "", base_of(plan))
		if tp["why"] == "cold": reasons.append({"id": "cold", "score": clampf(float(F["cold"]["score"]) * calm, 0.0, 1.0), "text": _fc_text("cold")})
	reasons.sort_custom(func(a, b): return a["score"] > b["score"])
	var safe := 1.0
	for r in reasons: safe *= 1.0 - float(r["score"])
	var risk := clampf(1.0 - safe, 0.0, 1.0)
	return {"risk": snappedf(risk, 0.01), "pct": roundi(risk * 100), "reasons": reasons, "words": forecast_words(risk, reasons, leader)}

## The forecast as the leader says it: the main reasons, the odds in words, and a remark in
## their temperament's voice (which colours the words, never the number).
func forecast_words(risk: float, reasons: Array, leader: E.Unit = null) -> String:
	var F: Dictionary = LOG["forecast"]
	var parts: Array = []
	for r in reasons:
		if parts.size() >= int(F["mentions"]) or float(r["score"]) < float(F["mention_at"]): break
		if str(r["text"]) != "": parts.append(r["text"])
	if parts.is_empty() and not reasons.is_empty() and reasons[0].get("quiet", "") != "": parts.append(reasons[0]["quiet"])
	for b in F["bands"]:
		if risk < float(b["below"]):
			parts.append(tr(b["text"]))
			break
	if leader != null:
		var v: String = F["voices"].get("%s:%s" % [sim.arch(leader), "high" if risk >= float(F["high_at"]) else "low"], "")
		if v != "": parts.append(tr(v))
	return " ".join(parts)

func _fc_text(key: String) -> String: return tr(LOG["forecast"]["reasons"][key]["text"])

func _fc_enemy(cf: Dictionary, kind: String, plan: Dictionary, site: Vector2, mult: float) -> Dictionary:
	var score: float = float(cf["base"].get(kind, 0.2)) * mult
	var texts: Array = []
	var near_r := float(cf["near_r"])
	var route_r := float(cf["route_r"])
	var way: Array = [site] if kind == "research" else D.route(base_of(plan), site) + [site]
	var seen: Array = []
	for p in sim.predators:
		if p.dead or p.fled or p.fleeing or p.kind in ["hunter", "trader"] or p.guard or not sim.is_explored(p.pos): continue
		if p.pos.distance_to(site) < near_r or way.any(func(q): return p.pos.distance_to(q) < route_r): seen.append(p)
	var beasts: int = seen.filter(func(p): return p.clan == "").size()
	var warriors: int = seen.size() - beasts
	if beasts > 0:
		score += float(cf["beast"]) * beasts
		texts.append(_fc_text("beasts") % beasts)
	if warriors > 0:
		score += float(cf["warrior"]) * warriors
		texts.append(_fc_text("warriors") % warriors)
	if kind != "research" and sim.landmarks.any(func(l): return l["kind"] == "den" and l["found"] and l["pos"].distance_to(site) < float(cf["den_r"])):
		score += float(cf["den"])
		texts.append(_fc_text("den"))
	if kind in ["settle", "seek"]:
		for id in sim.rivals.clans:
			var rc: Dictionary = sim.rivals.clans[id]
			if rc["met"] and sim.rivals.stance(id) in ["Hostile", "Blood feud"] and D.same_side(rc["pos"], site):
				score += float(cf["hostile"])
				texts.append(_fc_text("hostile") % tr(rc["name"]))
				break
		if not sim.is_explored(site):
			score += float(cf["unknown"])
			texts.append(_fc_text("unknown"))
	if kind == "war": texts.append(_fc_text("war"))
	if kind != "research":
		var dm: Array = cf["dist_mult"]
		score *= clampf(D.route_len(base_of(plan), site) / float(cf["dist_ref"]), float(dm[0]), float(dm[1]))
	return {"score": minf(score, float(cf["max"])), "text": texts[0] if not texts.is_empty() else "", "quiet": _fc_text("quiet") if texts.is_empty() else ""}

func _fc_disaster(cf: Dictionary, days: float, plan: Dictionary, mult: float) -> Dictionary:
	var si: int = sim.hz.season_idx()
	if str(plan.get("kind", "")) == "seek": days = float(plan.get("days", 1)) * float(_seek_cfg().get("secs_per_day", 45)) / D.DAY_LEN
	var safe := 1.0
	var worst := ""
	var rolls := maxf(1.0, float(cf["rolls_per_day"]) * days)
	for w in sim.hz.WEATHER:
		var wd: Dictionary = sim.hz.WEATHER[w]
		if not wd.get("disaster", false): continue
		var ch: float = float(wd["chance"][si]) * mult
		if ch <= 0.0: continue
		safe *= pow(1.0 - minf(ch, 0.99), rolls)
		worst = "blizzard" if w == "blizzard" else "weather"
	var fl: Dictionary = sim.nat.C["flood"]
	if si == int(fl["season"]) and D.river_dist(plan_site(plan)) < float(fl["contract_reach"]) + 650.0: # (the crew roam ~650 round the site)
		safe *= pow(1.0 - minf(float(fl["chance"]) * mult * float(cf["flood_mult"]), 0.99), maxf(1.0, days))
		if worst == "": worst = "flood"
	var p := 1.0 - safe
	var inc: String = sim.hz.incoming
	if (inc != "" and sim.hz.WEATHER.get(inc, {}).get("disaster", false)) or sim.nat.flood_at > 0:
		p = maxf(p, float(cf["incoming"]))
		worst = "incoming"
	return {"id": "natural_disaster", "score": minf(p, float(cf["max"])), "text": _fc_text(worst) if worst != "" else ""}

func _fc_wound(cf: Dictionary, cond: String, leader: E.Unit, kind: String, enemy: float) -> Dictionary:
	var pct := clampf(float(cond.trim_prefix("hp_below_").trim_suffix("%")), 1.0, 99.0)
	var fight: float = 1.0 if kind == "war" else enemy
	var lv: int = leader.lv("combat") if leader else 1
	var p: float = fight * float(cf["wound"]) * pct / float(cf["ref_pct"]) * maxf(0.2, 1.0 - float(cf["per_combat_lv"]) * (lv - 1))
	var text := _fc_text("fight") if p >= 0.05 else ""
	if leader and leader.hp < leader.max_hp * (pct / 100.0 + float(cf["hurt_margin"])):
		p += float(cf["hurt"])
		text = _fc_text("hurt")
	return {"id": "leader_wounded", "score": minf(p, float(cf["max"])), "text": text}

func _fc_losses(cf: Dictionary, plan: Dictionary, leader: E.Unit) -> Dictionary:
	var rc: Dictionary = sim.rivals.clans.get(str(plan.get("target", "")), {})
	var foes: int = int(rc.get("warriors", 2)) + 1
	var n := clampi(_int(plan.get("crew_size"), 3), 1, 6)
	var helpers := available_helpers(leader.id, leader.pos) if leader else available_helpers()
	helpers.sort_custom(func(a, b): return a.lv("combat") > b.lv("combat"))
	var strength := float(leader.lv("combat")) if leader else 1.0
	for u in helpers.slice(0, n - 1): strength += u.lv("combat")
	var p: float = float(cf["base"]) + float(cf["per_defender"]) * foes - float(cf["per_strength"]) * strength
	if sim.has_bronze(): p *= float(cf["bronze"])
	return {"id": "heavy_losses", "score": clampf(p, 0.02, float(cf["max"])), "text": (_fc_text("outnumbered") if foes > n else _fc_text("match")) % [foes, n]}

func create(bp: Dictionary, leader: E.Unit, directive: String) -> E.Contract:
	var c := E.Contract.new()
	c.id = sim.uid()
	c.plan = bp.duplicate(true)
	c.directive = directive
	c.leader_id = leader.id
	c.kind = bp.get("kind", "settle")
	c.site = plan_site(bp)
	c.forecast = forecast(bp, leader)
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
	var helpers := crew_pool(leader)
	if c.kind == "seek": helpers = seek_crew(helpers, str(bp["group"]))
	else: helpers.sort_custom(func(a, b): return a.lv(skill) + a.lv("craft") * 0.5 > b.lv(skill) + b.lv("craft") * 0.5)
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
	sim.add_log(tr("Task Contract '%s' sealed. %s leads %s %s. The LLM connection is closed.") % [title(bp), tr(leader.name), ", ".join(names.slice(1)) if names.size() > 1 else tr("no one"), where], "contract", c.crew_ids.map(func(id): return sim.unit_by_id(id)))
	_clog(c, tr("Contract sealed: %d steps, crew of %d.") % [c.steps.size(), c.crew_ids.size()])
	_clog(c, tr("%s: \"%s\" (risk %d%%)") % [tr(leader.name), c.forecast["words"], c.forecast["pct"]])
	sim.policy.on_contract(c)
	return c

func _clog(c: E.Contract, text: String) -> void:
	c.events.push_front("[Day %d] %s" % [sim.day(), text])
	if c.events.size() > 12: c.events.pop_back()

# ------------------------------------------------------------ the field log (make_it_fun A1)
## The leader says a line for `trigger` (contract_log.json "log" talk; lines for their
## archetype, `<trigger>:<arch>`, are preferred) into the contract's log, aloud now and then
## (`aloud`: always), and into the chronicle for the "chronicle" triggers. `once`: only the
## first time per contract. Returns the line said ("" if none). A game master may call it.
func field_say(c: E.Contract, trigger: String, arg := "", once := true, aloud := false) -> String:
	var L: Dictionary = LOG["log"]
	if c == null or not is_running(c) and trigger != "done" or (once and c.said.has(trigger)): return ""
	var ld := leader(c)
	if ld == null or ld.dead: return ""
	var talk: Dictionary = L["talk"]
	var lines: Array = talk.get("%s:%s" % [trigger, sim.arch(ld)], [])
	var base: Array = talk.get(trigger, [])
	if lines.is_empty() or (not base.is_empty() and randf() >= float(L["arch_chance"])): lines = base
	if lines.is_empty(): return ""
	c.said[trigger] = true
	c.said["t"] = float(c.said.get("clock", 0.0))
	var line: String = tr(str(lines.pick_random()))
	if line.contains("%s"): line = line.replace("%s", arg)
	var quoted: String = tr("%s: \"%s\"") % [tr(ld.name), line]
	_clog(c, quoted)
	if (aloud or randf() < float(L["bubble_chance"])) and not ld.sleeping and not sim.in_hut(ld): sim.life.say_text(ld, line, "contract")
	if trigger.get_slice(":", 0) in L["chronicle"]: sim.add_log(quoted, "contract", [ld])
	return line

## Did the leader name this trouble when they read the odds (among the reasons they spoke)?
func foresaw(c: E.Contract, reason: String) -> bool:
	var F: Dictionary = LOG["forecast"]
	var rs: Array = c.forecast.get("reasons", [])
	for i in mini(rs.size(), int(F["mentions"])):
		if rs[i]["id"] == reason and float(rs[i]["score"]) >= float(F["mention_at"]): return true
	return false

## Each tick of an executing contract: the milestones and happenings worth a line.
func _field_log(c: E.Contract, dt: float) -> void:
	var L: Dictionary = LOG["log"]
	var clock: float = float(c.said.get("clock", 0.0)) + dt
	c.said["clock"] = clock
	for q in [25, 50, 75]:
		var key := "progress_%d" % q
		if c.progress < q / 100.0 or c.said.has(key): continue
		var rs: Array = c.forecast.get("reasons", [])
		if not (q == 50 and c.interruptions == 0 and not rs.is_empty() and field_say(c, "quiet:" + str(rs[0]["id"])) != ""): field_say(c, key)
		c.said[key] = true
		return
	if not c.said.has("first_built"):
		for id in c.struct_ids:
			var s = sim.struct_by_id(id)
			if s and s.built:
				field_say(c, "first_built", tr(D.STRUCTURES[s.type]["name"]), true, true)
				return
	var w: String = sim.hz.weather
	if c.said.get("weather_was", w) != w and w != "clear":
		c.said["weather_was"] = w
		field_say(c, "weather", tr(sim.hz.weather_name()), false)
		return
	c.said["weather_was"] = w
	for u in crew(c, true):
		var nk := "near_%d" % u.id
		if u.hp < u.max_hp * float(L["near_miss_hp"]) and not c.said.has(nk):
			c.said[nk] = true
			field_say(c, "near_miss", tr(u.name), false)
			return
	if clock - float(c.said.get("t", 0.0)) > float(L["chatter_secs"]): field_say(c, "chatter", "", false)

## A crew member grew in a skill (sim.gain_xp): the leader notices, once per person.
func on_level(u: E.Unit) -> void:
	var c := by_id(u.contract_id)
	if c == null or not is_running(c) or u.id == c.leader_id or c.said.has("lv_%d" % u.id): return
	c.said["lv_%d" % u.id] = true
	field_say(c, "level_up", tr(u.name), false)

## A landmark was found (sim._discover): a crew working near it says so.
func on_landmark(lm: Dictionary) -> void:
	for c in list:
		if is_running(c) and crew(c).any(func(u): return u.pos.distance_to(lm["pos"]) < 700.0):
			field_say(c, "landmark", tr(lm["name"]), false, true)

# ------------------------------------------------------------ small happenings the leader settles (make_it_fun A2/A3)
## Now and then (contract_log.json "events": every_secs of working time, with chance) one
## event whose conditions hold happens to an executing contract, once per contract each.
## The leader picks an option by temperament (an option's "arch" weights, else 1), its
## actions run through story.run(), and nothing pauses: the choice is reported in the
## contract log and the chronicle.
func _events(c: E.Contract, dt: float) -> void:
	var EV: Dictionary = LOG["events"]
	c.said["ev_t"] = float(c.said.get("ev_t", Config.rand_in(EV["every_secs"]))) - dt
	if float(c.said["ev_t"]) > 0.0: return
	c.said["ev_t"] = Config.rand_in(EV["every_secs"])
	if randf() >= float(EV["chance"]): return
	var pool: Array = []
	var total := 0.0
	for ev in EV["list"]:
		if c.said.has("ev_" + str(ev["id"])) or event_vars(c, ev).is_empty(): continue
		pool.append(ev)
		total += float(ev.get("weight", 1.0))
	var roll := randf() * total
	for ev in pool:
		roll -= float(ev.get("weight", 1.0))
		if roll <= 0.0:
			happen(c, str(ev["id"]))
			return

## The named values of an event for this contract, or {} if it can't happen now: its "when"
## (kinds, progress [min, max], cond: story conditions) and "pair" ("rivals" / "friends": two
## of the crew bonded that way, a and b). Vars: plan, leader, one (someone of the crew, not
## the leader if possible), a, b, and *_who people specs for actions (crew_who: all of them).
func event_vars(c: E.Contract, ev: Dictionary) -> Dictionary:
	var w: Dictionary = ev.get("when", {}) if ev.get("when") is Dictionary else {}
	if w.has("kinds") and not c.kind in w["kinds"]: return {}
	if w.has("progress") and (c.progress < float(w["progress"][0]) or c.progress > float(w["progress"][1])): return {}
	if w.has("cond") and not sim.story.holds(w["cond"]): return {}
	var cr := crew(c)
	var ld := leader(c)
	if cr.is_empty() or ld == null: return {}
	var others: Array = cr.filter(func(u): return u != ld)
	var one: E.Unit = others.pick_random() if not others.is_empty() else ld
	var v := {"plan": title(c.plan), "leader": tr(ld.name), "leader_who": "id:%d" % ld.id, "one": tr(one.name), "one_who": "id:%d" % one.id,
		"crew_who": "ids:" + ",".join(cr.map(func(u): return str(u.id)))}
	var pair := str(ev.get("pair", ""))
	if pair != "":
		var bc: Dictionary = sim.life.C["bonds"]
		var found := false
		for i in cr.size():
			for j in range(i + 1, cr.size()):
				var b: float = sim.life.bond(cr[i], cr[j])
				if (pair == "rivals" and b <= float(bc["rival_at"])) or (pair == "friends" and b >= float(bc["friend_at"])):
					v.merge({"a": tr(cr[i].name), "a_who": "id:%d" % cr[i].id, "b": tr(cr[j].name), "b_who": "id:%d" % cr[j].id})
					found = true
					break
			if found: break
		if not found: return {}
	return v

## An event happens to a contract now (a game master's verb too): the leader chooses, the
## outcome runs. Returns the line written to the chronicle ("" if it can't happen).
func happen(c: E.Contract, id: String) -> String:
	if c == null or not is_running(c) or c.said.has("ev_" + id): return ""
	var ev: Dictionary = {}
	for e in LOG["events"]["list"]:
		if str(e["id"]) == id: ev = e
	var v := event_vars(c, ev) if not ev.is_empty() else {}
	if v.is_empty(): return ""
	c.said["ev_" + id] = true
	var ld := leader(c)
	var arch: String = sim.arch(ld)
	var opts: Array = ev.get("options", [])
	var total := 0.0
	for o in opts: total += float(o.get("arch", {}).get(arch, 1.0))
	var roll := randf() * total
	var pick: Dictionary = opts[-1] if not opts.is_empty() else {}
	for o in opts:
		roll -= float(o.get("arch", {}).get(arch, 1.0))
		if roll <= 0.0:
			pick = o
			break
	if pick.is_empty(): return ""
	sim.story.run(pick.get("do", []), c, v)
	var what: String = sim.story.text(ev["text"], v)
	var line: String = tr("%s %s decides: %s. %s") % [what, tr(ld.name), sim.story.text(pick["label"], v), sim.story.text(pick.get("result", ""), v)]
	_clog(c, line)
	sim.add_log("'%s': %s" % [title(c.plan), line], "contract", crew(c))
	return line

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
			if c.status == "executing" and c.said.get("night", -1) != sim.day():
				c.said["night"] = sim.day()
				field_say(c, "nightfall", "", false)
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
				if c.status == "executing": _field_log(c, dt)
				if c.status == "executing": _events(c, dt)
			"defending":
				c.flags["fight_t"] = sim.time # (the fight goes on: wounds in it are the leader's to judge)
				_defend(c, dt)
			"sheltering":
				for u in crew(c): _ensure(u, "c%d_shelter" % c.id, func(): sim.assign_move(u, c.site + Vector2(randf_range(-30, 30), randf_range(-30, 30))))
				if c.state_t > 8: _set_status(c, "executing")
			"interrupted": pass # waiting on the player / LLM

func _set_status(c: E.Contract, s: String) -> void:
	c.status = s
	c.state_t = 0.0
	c.clear_t = 0.0

## Where a wounded crew member goes to rest: beside the nearest fire of ours on their side of
## the river (any fire if none is), else the village. The spot round the fire is fixed per person.
func rest_spot(u: E.Unit) -> Vector2:
	var best: E.Structure = null
	var best_side := false
	for s in sim.structures:
		if not s.built or not sim.ours(s) or s.type != "bonfire": continue
		var side := D.same_side(s.pos, u.pos)
		if best == null or (side and not best_side) or (side == best_side and s.pos.distance_to(u.pos) < best.pos.distance_to(u.pos)):
			best = s
			best_side = side
	var a := float(u.id) * 2.39996 # (golden angle: each at their own place round the fire)
	if best == null: return D.VILLAGE + Vector2(cos(a) * 30.0, 30.0)
	return sim.dry_spot(best.pos + Vector2(cos(a), sin(a) * 0.8) * 40.0)

func _manage_wounded(c: E.Contract) -> void:
	for u in crew(c, true):
		if u.id in c.resting_ids:
			if u.hp >= u.max_hp * 0.7:
				c.resting_ids.erase(u.id)
				sim.add_log(tr("%s has recovered and rejoins '%s'.") % [tr(u.name), title(c.plan)], "contract", [u])
			elif u.job.is_empty() and u.pos.distance_to(rest_spot(u)) > 60:
				sim.set_job(u, {"type": "move", "to": rest_spot(u), "flee": true})
		elif u.hp < u.max_hp * 0.25 and not u.has_trait("belligerent") and u.id != c.leader_id:
			c.resting_ids.append(u.id)
			sim.set_job(u, {"type": "move", "to": rest_spot(u), "flee": true})
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
				var price: Dictionary = sim.place_cost(target.type, target.size) # (the one price of a building: wood from the crew's timber, anything else from the stores)
				var cost := int(price["wood"])
				var rest := {"stone": price["stone"]} if price["stone"] > 0 else {}
				if c.wood >= cost and not sim.can_afford(rest):
					c.substate = tr("Needs %d %s") % [rest["stone"], tr("stone")]
					return
				if c.wood >= cost:
					c.wood -= cost
					sim.spend(rest)
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
				if u.doing == "experiment": working += 1
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
			if ld.doing == "ritual": step["done"] = step.get("done", 0.0) + dt
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
				_ensure(u, key, func(): sim.assign_move(u, base_of(c.plan) + Vector2(randf_range(-60, 60), randf_range(-40, 60))))
				u.act = "Marching home"
				if u.pos.distance_to(base_of(c.plan)) > 160: home_all = false
			step["done"] = step.get("done", 0.0) + dt
			if home_all or step["done"] > 150: _next_step(c)

func _next_step(c: E.Contract) -> void:
	var step: Dictionary = c.steps[c.step_idx]
	var desc := _step_text(step)
	for u in crew(c):
		var skill: String = {"gather_wood": "forage", "gather_food": "forage", "gather_stone": "forage", "build": "craft", "ritual": "lore", "experiment": "lore"}.get(step["action"], "combat")
		sim.gain_xp(u, skill, 6)
	_clog(c, tr("Step %d done: %s.") % [c.step_idx + 1, desc])
	if c.step_idx + 1 < c.steps.size(): field_say(c, "step_done", desc, false)
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
	elif res == "food": sim.give({"food": amt}) # rations shared with the tribe
	elif res == "stone": c.stone += amt # (a research crew's material: the experiment works it, nothing reaches the stores)
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
			if flood_reaches(c) or sim.flags.get("disaster_t", -1.0) >= c.t: reason = "natural_disaster"
		elif cond.begins_with("hp_below_"):
			var pct := float(cond.trim_prefix("hp_below_").trim_suffix("%")) / 100.0
			var ld := leader(c)
			if c.leader_id not in c.resting_ids and ld.hp < ld.max_hp * pct: reason = "leader_wounded"
		if reason != "" and c.abort_cooldowns.get(reason, -1.0) > sim.time: reason = ""
		if reason != "": break
	if reason == "": return false
	var jd: Dictionary = LOG["judged"].get(reason, {})
	if not jd.is_empty() and sim.time - float(c.flags.get("fight_t", -1e9)) < float(jd["secs"]):
		var eff: String = jd["by_arch"].get(sim.arch(leader(c)), "")
		c.abort_reason = reason
		if eff in allowed_effects(c): # (in a fight the chieftain already ordered, the leader decides this one)
			resolve(c, eff, "", true)
			field_say(c, "judged:" + eff, "", false, true)
			return false
	c.abort_reason = reason
	c.interruptions += 1
	_set_status(c, "interrupted")
	for u in crew(c): sim.set_job(u, {})
	_clog(c, tr("ABORT CONDITION: %s at %d%% progress.") % [tr(reason), roundi(c.progress * 100)])
	field_say(c, ("foreseen:" + reason) if foresaw(c, reason) else "unforeseen", "", false, true)
	sim.add_log(tr("Contract '%s' interrupted (%s). The leader's LLM node is re-awakening...") % [title(c.plan), tr(reason)], "danger")
	sim.paused = true
	sim.contract_interrupted.emit(c)
	return true

## Is a flood under way (events.json flood "length" since it struck) with some of the crew
## within its reach of a river ("contract_reach")? Only they have to stop for it.
func flood_reaches(c: E.Contract) -> bool:
	var fl: float = sim.flags.get("flood_active", -1.0)
	var cf: Dictionary = sim.nat.C["flood"]
	if fl < c.t or sim.time - fl > float(cf["length"]): return false
	return crew(c).any(func(u): return D.river_dist(u.pos) < float(cf["contract_reach"]))

## What a chieftain's answer to an emergency does, for the player and the LLM (translated).
func effect_text(effect: String) -> String:
	var t: String = tr(EFFECTS.get(effect, effect))
	return t % int(sim.RULES["ward"]["cost"].get("lore", 0)) if effect == "ward" else t

func effect_texts() -> Dictionary:
	var out := {}
	for k in EFFECTS: out[k] = effect_text(k)
	return out

func allowed_effects(c: E.Contract) -> Array:
	match c.abort_reason:
		"enemy_attack":
			var fx := ["hold", "reinforce", "retreat"]
			if sim.can_afford(sim.RULES["ward"]["cost"]): fx.append("ward")
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
		"plan_id": c.plan["plan_id"], "title": title(c.plan), "progress_pct": roundi(c.progress * 100),
		"current_step": c.substate, "built": built, "half_built": partial,
		"threat": _threat_text(c.site),
		"reason": c.abort_reason, "disaster": sim.flags.get("disaster", "blizzard") if sim.flags.get("disaster_t", -1.0) > sim.flags.get("flood_active", -1.0) else "flood", "leader_hp": "%d/%d" % [roundi(ld.hp), roundi(ld.max_hp)],
		"crew": crew_state, "tribe_lore": roundi(sim.stock["lore"]),
		"idle_warriors_in_village": available_helpers().size(),
		"forecast_at_sealing": {"risk_pct": c.forecast.get("pct", 0), "words": c.forecast.get("words", "")},
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
## `by_leader`: the leader decided it in the field (contract_log.json "judged"), not the chieftain.
func resolve(c: E.Contract, effect: String, label := "", by_leader := false) -> void:
	if effect not in allowed_effects(c): effect = allowed_effects(c)[0]
	var ld := leader(c)
	if by_leader: _clog(c, tr("%s decides: %s") % [tr(ld.name), effect_text(effect)])
	else: _clog(c, tr("Chieftain's decision: %s") % (label if label != "" else effect_text(effect)))
	if c.abort_reason == "enemy_attack" and effect != "retreat": c.flags["fight_t"] = sim.time
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
			sim.add_log(tr("%d warriors rush out to reinforce '%s'.") % [mini(3, helpers.size()), title(c.plan)], "contract")
			if c.kind == "war":
				c.abort_cooldowns["heavy_losses"] = sim.time + 60.0
				_set_status(c, "executing")
			else: _set_status(c, "defending")
		"ward":
			sim.spend(sim.RULES["ward"]["cost"]) # (affordable: allowed_effects() checked it)
			var n: int = sim.scare_predators(c.site, float(sim.RULES["ward"]["radius"]))
			sim.gain_xp(ld, "lore", 12)
			sim.remember(ld, tr("drove off %d beasts with a totem ward on Day %d") % [n, sim.day()], 8)
			sim.popup(c.site + Vector2(0, -50), tr("Totem Ward!"), Color("#c8a8ff"), true)
			_set_status(c, "executing")
		"retreat":
			var fleeing := crew(c, true)
			for u in fleeing:
				if c.kind == "war": sim.remember(u, tr("fled from the battle with the %s on Day %d") % [tr(sim.rivals.clans[c.plan["target"]]["name"]), sim.day()], 7)
				else: sim.remember(u, tr("abandoned the half-built camp '%s' on Day %d") % [title(c.plan), sim.day()], 7)
			sim.add_log(tr("'%s' abandoned at %d%%. The crew flees for home.") % [title(c.plan), roundi(c.progress * 100)], "danger")
			c.status = "abandoned"
			_disband(c)
			for u in fleeing: sim.assign_flee(u)
		"rest":
			c.resting_ids.append(ld.id)
			sim.set_job(ld, {"type": "move", "to": rest_spot(ld), "flee": true})
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
				sim.remember(u, tr("held the half-built camp '%s' against saber-tooths on Day %d") % [title(c.plan), sim.day()], 8)
			_clog(c, tr("The beasts are gone. Resuming the blueprint where we left off."))
			sim.add_log(tr("'%s' secured. The state machine resumes - no LLM needed.") % title(c.plan), "contract")
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

## The one way a contract lets its people go (done, failed or abandoned): the crew is
## released and idle, and no one keeps (or comes back to) work that hauls to it.
func _disband(c: E.Contract) -> void:
	var members := crew(c, true).filter(func(u): return u.contract_id == c.id)
	for u in members: _release(u)
	for u in sim.living():
		if int(u.resume_job.get("dropoff", -1)) == c.id: u.resume_job = {}
		if u in members or int(u.job.get("dropoff", -1)) == c.id: sim.set_job(u, {})

func _complete(c: E.Contract) -> void:
	c.status = "done"
	field_say(c, "done", "", true, true)
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
			sim.remember(u, tr("helped defend and finish '%s' on Day %d") % [title(c.plan), sim.day()], 6)
			u.home = D.VILLAGE
		else:
			var lead: bool = u == ld
			sim.remember(u, (tr("led the founding of '%s' on the frontier on Day %d (%s)") if lead else tr("helped the founding of '%s' on the frontier on Day %d (%s)")) % [title(c.plan), sim.day(), what], 9 if lead else 7)
			sim.gain_xp(u, "craft", 10)
			if lead: sim.gain_xp(u, "combat", 15) # leadership
			else: sim.ranks.learned_under(u, ld, "craft")
			u.home = c.site
	sim.ranks.deed(ld, "lead_build")
	_disband(c)
	sim.popup(c.site + Vector2(0, -80), tr("Outpost founded!"), Color("#b6f28a"), true)
	sim.inv.feat("outpost", tr("Founded the outpost '%s'") % settlement_label(c), ld,
		{"desc": tr("A new settlement on the frontier: %s.") % ", ".join(built.map(func(n): return tr(n))), "at": c.site})
	sim.add_log(tr("Contract '%s' complete! %s. Housing for %d more.") % [title(c.plan), what, housing(c.plan)], "contract")
	sim.contract_finished.emit(c)

func _complete_war(c: E.Contract) -> void:
	var ld := leader(c)
	var cname: String = tr(sim.rivals.clans[c.plan["target"]]["name"])
	var spoils: String = c.flags.get("spoils", "")
	for u in crew(c, true):
		var lead: bool = u == ld
		sim.remember(u, (tr("led the war party against the %s on Day %d (%s)") if lead else tr("fought in the war party against the %s on Day %d (%s)")) % [cname, sim.day(), spoils], 9 if lead else 7)
		sim.gain_xp(u, "combat", 15 if lead else 10)
		if not lead: sim.ranks.learned_under(u, ld, "combat")
	_disband(c)
	sim.ranks.deed(ld, "win_war")
	sim.popup(base_of(c.plan) + Vector2(0, -80), tr("The war party returns!"), Color("#ffb07a"), true)
	sim.add_log(tr("War contract '%s' complete against the %s: %s.") % [title(c.plan), cname, spoils], "contract")
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
	_disband(c)
	sim.gain_xp(ld, "combat", 8) # leadership
	if not fresh:
		var gives: Dictionary = sim.RULES["research"]["known_gives"]
		sim.give(gives)
		sim.add_log(tr("'%s' finished, but %s was already known - the work became %d lore.") % [title(c.plan), tr(t["name"]), int(gives.get("lore", 0))], "contract")
	else:
		sim.add_log(tr("Research contract '%s' complete: %s now knows %s.") % [title(c.plan), tr(ld.name), tr(t["name"])], "contract", [ld])
	sim.contract_finished.emit(c)

## Back from the search: what they found (c.flags["found"], filled by sim.discover_find).
func _complete_seek(c: E.Contract) -> void:
	var ld := leader(c)
	var found: Array = c.flags.get("found", [])
	var names: Array = found.map(func(id): return tr(D.FINDS[id]["name"]))
	searched.append({"group": str(c.plan["group"]), "pos": c.site, "day": sim.day(), "found": found.duplicate(), "place": str(c.plan.get("place_name", ""))})
	var keep := int(_seek_cfg().get("searched", {}).get("keep", 40))
	if searched.size() > keep: searched = searched.slice(searched.size() - keep)
	var skill: String = str(sim.DISC.get("groups", {}).get(c.plan["group"], {}).get("skill", "forage"))
	for u in crew(c, true):
		sim.remember(u, (tr("searched %s and found %s on Day %d") % [c.plan.get("place_name", ""), ", ".join(names), sim.day()]) if not found.is_empty() else (tr("searched %s and found nothing new on Day %d") % [c.plan.get("place_name", ""), sim.day()]), 5 if not found.is_empty() else 2)
		sim.gain_xp(u, skill, 10 if not found.is_empty() else 4)
	_disband(c)
	if found.is_empty(): sim.add_log(tr("The search '%s' is over: %s found nothing new in %s.") % [title(c.plan), tr(ld.name), c.plan.get("place_name", "")], "contract", [ld])
	else: sim.add_log(tr("The search '%s' is over: %s's crew found %s.") % [title(c.plan), tr(ld.name), ", ".join(names)], "contract", [ld])
	sim.contract_finished.emit(c)

func _fail(c: E.Contract, why: String) -> void:
	c.status = "failed"
	_disband(c)
	sim.add_log(tr("Contract '%s' failed: %s") % [title(c.plan), why], "danger")

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
