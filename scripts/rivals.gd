## Rival clans: villages on the map, people who walk it, and how they feel about you.
##
## Each clan is a light simulation (population, warriors, relation, raid clock) with a
## real village (structures owned "rival:<id>", never revealing fog for you) and real
## people: peaceful hunters prowling their lands and, when relations sour, war bands.
## Both are E.Predator objects (kind "hunter" / "warrior", with a clan) so combat,
## self-defence, the War Chief and contract ambush wake-ups all work against them.
##
## Relations (-100..100) drift back toward each clan's temperament and move with deeds:
## trespassing on their hunting grounds, building near them, killing their people (or
## them killing yours), gifts at first contact. Hostile clans send raids that steal food
## and slip back home; the bloodier the feud, the bigger and more frequent the raids.
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")

var sim
var clans := {} # id -> state dict
var pending: Array = [] # event ids waiting to be shown ("contact_<id>", "demand_<id>")

const TREATIES := ["none", "peace", "hunting_rights", "alliance"]
const RES := ["food", "wood", "stone"]
const Config = preload("res://scripts/config.gd")

## Every number and text of the clans' behaviour: config/rivals.json.
var C: Dictionary = Config.load_cfg("rivals")

func _init(s) -> void:
	sim = s

## A clan text ([key, vars...] or a key) with the clan's values: clan_name, chief, ...
func _txt(t, c: Dictionary, extra: Dictionary = {}) -> String:
	var v := {"clan_name": tr(c["name"]), "chief": tr(c["chief"]), "epithet": tr(c["epithet"])}
	v.merge(extra, true)
	return sim.story.text(t, v)

## What one of our deeds does to a clan's feelings (config "deeds"): the relation change,
## the grudge they keep, and what we are told (at `at`, or their village).
func _deed(id: String, key: String, at: Variant = null, extra: Dictionary = {}) -> void:
	var dd: Dictionary = C["deeds"][key]
	var c: Dictionary = clans[id]
	change(id, float(dd["relation"]), _txt(dd["reason"], c, extra) if dd.has("reason") else "")
	note(id, key, [extra["kind"]] if extra.has("kind") else [])
	if dd.has("alert"): sim.alert(_txt(dd["alert"], c, extra), at if at is Vector2 else c["pos"], "danger" if key in ["killed", "broke_peace", "unpaid_tribute"] else "warn")

## A [martial, peaceful] pair (or one number for both).
func _mp(v, martial: bool) -> float:
	return float(v[0] if martial else v[1]) if v is Array else float(v)

func setup() -> void:
	for def in D.RIVALS:
		var c: Dictionary = def.duplicate(true)
		c["relation"] = def["start"]
		c["met"] = false
		c["warriors"] = int(def["pop"] / 3)
		c["raid_t"] = D.DAY_LEN * Config.rand_in(C["raids"]["first_days"])
		c["hunter_t"] = 0.0
		c["trespass_warned"] = -999.0
		c["grudges"] = [] # short texts for personas
		_ensure_chief(c)
		c["treaties"] = {} # type -> {"until": sim time, "tribute": food per day}
		c["tribute_day"] = 0
		c["last_demand"] = -999.0
		c["demand"] = 0
		c["envoy"] = -1 # unit id of our envoy on the way / in parley
		c["war_t"] = -9999.0 # when we last attacked their village
		c["trade_t"] = D.DAY_LEN * 1.5
		c["trade_offers"] = []
		c["vassal"] = 0 # food per day they pay us as our vassal (0 = free)
		c["call_t"] = D.DAY_LEN * float(C["alliance"]["first_call_days"])
		c["call_target"] = ""
		c["share_day"] = 0
		clans[c["id"]] = c
		_build_village(c)
		for i in int(C["people"]["hunters"]): _spawn(c, "hunter")

func _build_village(c: Dictionary) -> void:
	var p: Vector2 = c["pos"]
	var owner: String = "rival:" + c["id"]
	var fire = sim.add_structure("bonfire", p, true, owner)
	fire.style = c["era"]
	for i in 4:
		var a := i * TAU / 4 + 0.4
		var h = sim.add_structure("hut" if i % 2 == 0 else "large_hut", p + Vector2(cos(a), sin(a)) * (62.0 if c["culture"] == "martial" else 105.0), true, owner)
		h.style = c["era"]
	if c["culture"] == "martial":
		sim.add_structure("weapon_rack", p + Vector2(40, -40), true, owner)
		var pal = sim.add_structure("palisade", p, true, owner)
		pal.style = c["era"]
	else:
		sim.add_structure("totem_shrine", p + Vector2(-50, 40), true, owner)

## A clan member walking out of the village: a peaceful hunter or a warrior.
func _spawn(c: Dictionary, kind: String, goal: Variant = null) -> E.Predator:
	var p: E.Predator = sim.spawn_predator(c["pos"] + Vector2(randf_range(-60, 60), randf_range(-50, 50)), goal)
	p.kind = kind
	p.clan = c["id"]
	p.den = c["pos"]
	p.name = c["hunter_name"] if kind == "hunter" else c["warrior_name"]
	var cp: Dictionary = C["people"]
	var st: Dictionary = cp.get(kind, cp["hunter"]) if kind != "trader" else cp["hunter"]
	p.hp = float(st["hp"]) * c["strength"]
	p.max_hp = p.hp
	p.atk = float(st["atk"]) * c["strength"]
	p.def = float(cp["def"])
	p.spd = float(cp["spd"])
	return p

# ------------------------------------------------------------ queries
func stance(id: String) -> String:
	if clans[id]["vassal"] > 0: return "Vassal"
	if has_treaty(id, "alliance"): return "Allied"
	var r: float = clans[id]["relation"]
	var sa: Dictionary = C["relations"]["stance_at"]
	if r <= float(sa["blood_feud"]): return "Blood feud"
	if r <= float(sa["hostile"]): return "Hostile"
	if r < float(sa["friendly"]): return "Wary"
	if r < float(sa["trusted"]): return "Friendly"
	return "Trusted"

## No raids, no demands: a peace pact, an alliance, or they are our vassals.
## How many people a clan grows to (rivals.json people.max_pop: a number, or {base,
## per_our_pop}: clans grow as we do, so a raid on a town is not a raid on a camp).
func max_pop() -> int:
	var m = C["people"]["max_pop"]
	if m is Dictionary: return int(float(m.get("base", 14)) + float(m.get("per_our_pop", 0.0)) * sim.living().size())
	return int(m)

func at_peace(id: String) -> bool:
	return has_treaty(id, "peace") or has_treaty(id, "alliance") or clans[id]["vassal"] > 0

func allies() -> Array:
	return clans.keys().filter(func(id): return has_treaty(id, "alliance"))

func has_treaty(id: String, type: String) -> bool:
	var t: Dictionary = clans[id]["treaties"]
	return t.has(type) and t[type]["until"] > sim.time

func treaty_days_left(id: String, type: String) -> int:
	return ceili((clans[id]["treaties"][type]["until"] - sim.time) / D.DAY_LEN) if has_treaty(id, type) else 0

## Short text of the treaties in force, e.g. "Peace (12 days, 2 food/day)".
func treaty_text(id: String) -> String:
	var parts: Array = []
	if has_treaty(id, "peace"):
		var trib: int = clans[id]["treaties"]["peace"].get("tribute", 0)
		parts.append(tr("Peace (%d days)") % treaty_days_left(id, "peace") + ((tr(", tribute %d food/day") % trib) if trib > 0 else ""))
	if has_treaty(id, "hunting_rights"): parts.append(tr("Hunting rights (%d days)") % treaty_days_left(id, "hunting_rights"))
	if has_treaty(id, "alliance"): parts.append(tr("Alliance (%d days)") % treaty_days_left(id, "alliance"))
	if clans[id]["vassal"] > 0: parts.append(tr("Our vassals, paying %d food/day") % clans[id]["vassal"])
	return ", ".join(parts)

func owns_event(ev: String) -> bool:
	return ev.begins_with("contact_") or ev.begins_with("demand_") or ev.begins_with("trade_") or ev.begins_with("call_") or ev.begins_with("submit_")

func owner_clan(owner: String) -> String:
	return owner.trim_prefix("rival:") if owner.begins_with("rival:") else ""

## Known neighbours, for the personas' context.
func summary() -> Array:
	var out: Array = []
	for id in clans:
		var c: Dictionary = clans[id]
		if not c["met"]: continue
		out.append({"clan": tr(c["name"]), "chieftain": tr(c["chief"]), "stance": tr(stance(id)),
			"their_ways": tr(c["desc"]), "wrongs_remembered": c["grudges"].slice(-3), "treaties": treaty_text(id),
			"chief_temper": tr(temper(id).get("word", "")), "remembers": ledger_lines(id, 3),
			"nemesis": c.get("nemesis", false), "feud_over": c.get("feud_over", false)})
	return out

func change(id: String, amount: float, reason := "") -> void:
	var c: Dictionary = clans[id]
	var before := stance(id)
	c["relation"] = clampf(c["relation"] + amount, -100.0, 100.0)
	if reason != "" and amount <= float(C["relations"]["grudge_at"]): c["grudges"].append(reason)
	if stance(id) != before and c["met"]:
		var worse: bool = amount < 0
		sim.alert(_txt(C["relations"]["stance_alert"], c, {"stance": tr(stance(id)).to_lower()}), c["pos"], "warn" if worse else "info")

# ------------------------------------------------------------ hooks from the simulation
func on_rival_killed(p: E.Predator, by) -> void:
	if p.clan == "" or not clans.has(p.clan): return
	var c: Dictionary = clans[p.clan]
	c["pop"] = maxi(2, c["pop"] - 1)
	if p.kind == "warrior": c["warriors"] = maxi(0, c["warriors"] - 1)
	var raiding: bool = p.kind == "warrior" and (p.raid or p.guard) # killed in a fight they chose / in our attack
	if not raiding: _break_peace(p.clan)
	_deed(p.clan, "killed_raider" if raiding else "killed", p.pos, {"kind": tr({"hunter": "hunter", "trader": "trader"}.get(p.kind, "warrior"))})

## A hunter we attacked runs home with the story.
func on_hunter_attacked(p: E.Predator) -> void:
	_break_peace(p.clan)
	_deed(p.clan, "attacked_trader" if p.kind == "trader" else "attacked_hunter", p.pos)

func _break_peace(id: String) -> void:
	if not at_peace(id): return
	clans[id]["treaties"].clear()
	clans[id]["vassal"] = 0
	_deed(id, "broke_peace")

## A clan member got back to the village: warriors rejoin the war band.
func on_return(p: E.Predator) -> void:
	if p.kind == "warrior" and clans.has(p.clan): clans[p.clan]["warriors"] += 1

func on_villager_killed(u, killer) -> void:
	if killer == null or not (killer is E.Predator) or killer.clan == "": return
	var c: Dictionary = clans[killer.clan]
	c["grudges"].append(tr("they killed %s") % tr(u.name))
	note(killer.clan, "killed_ours", [u.name])
	for o in sim.living():
		if o.pos.distance_to(u.pos) < 400 or o.home == u.home:
			sim.remember(o, tr("saw %s killed by the %s on Day %d") % [tr(u.name), tr(c["name"]), sim.day()], 8)

## Food stolen by a raider standing in an undefended village.
func steal(p: E.Predator) -> void:
	var ct: Dictionary = C["theft"]
	var aim = sim.struct_by_id(p.aim_id) if p.aim_id >= 0 else null
	var of: Dictionary = C["raids"].get("outside_first", {})
	if aim and aim.built and aim.type in of.get("torch", []): # (a field outside the wall: put to the torch)
		sim.nat.set_alight(aim, float(of["torch_left"]), _txt(of["torch_alert"], clans[p.clan], {"what": tr(D.STRUCTURES[aim.type]["name"])}))
		note(p.clan, "torched")
	var amount: float = minf(sim.stock["food"], Config.rand_in(ct["food"]))
	sim.stock["food"] -= amount
	p.loot = true
	p.fleeing = true
	sim.popup(p.pos + Vector2(0, -30), tr(ct["popup"]) % roundi(amount), Color("#ff8a7a"), true)
	if sim.flags.get("theft_alert_" + p.clan, -1) != sim.day():
		sim.flags["theft_alert_" + p.clan] = sim.day()
		note(p.clan, "stole", [roundi(amount)])
		sim.alert(_txt(ct["alert"], clans[p.clan]), p.pos, "danger")

# ------------------------------------------------------------ tick
func update(dt: float) -> void:
	for id in clans:
		var c: Dictionary = clans[id]
		_ensure_chief(c)
		_succession(c)
		_feud(c)
		# drift back toward the clan's temperament (slowly)
		var gw: Dictionary = C["relations"]["goodwill"]
		var target: float = c["base"] + float(temper(id).get("base", 0.0)) + sim.inv.add("relation") + (float(gw["peace"]) if has_treaty(id, "peace") else 0.0) + (float(gw["alliance"]) if has_treaty(id, "alliance") else 0.0) + (float(gw["vassal"]) if c["vassal"] > 0 else 0.0)
		c["relation"] += (target - c["relation"]) * dt * float(C["relations"]["drift"])
		_treaties(c)
		_contact(c)
		_trespass(c, dt)
		_raids(c, dt)
		_hunters(c, dt)
		_traders(c, dt)
		_guards_home(c)
		# people and warriors regrow
		var cp: Dictionary = C["people"]
		if randf() < dt / (D.DAY_LEN * float(cp["pop_every_days"])): c["pop"] = mini(max_pop(), c["pop"] + 1)
		c["warriors"] = clampi(c["warriors"], 0, int(c["pop"] / int(cp["max_warrior_share"])))
		if randf() < dt / (D.DAY_LEN * float(cp["warrior_every_days"])) and c["warriors"] < int(c["pop"] / int(cp["warrior_share"])): c["warriors"] += 1
	_pick_nemesis()

## First contact: the first time any of their people or homes is in sight.
func _contact(c: Dictionary) -> void:
	if c["met"]: return
	var seen: bool = sim.is_visible(c["pos"])
	if not seen:
		for p in sim.predators:
			if p.clan == c["id"] and not p.dead and sim.is_visible(p.pos):
				seen = true
				break
	if not seen: return
	c["met"] = true
	var finder = null
	for u in sim.living():
		if finder == null or u.pos.distance_to(c["pos"]) < finder.pos.distance_to(c["pos"]): finder = u
	if finder: sim.remember(finder, tr("was the first to meet the %s on Day %d") % [tr(c["name"]), sim.day()], 7)
	sim.alert(tr("First contact: the %s!") % tr(c["name"]), c["pos"], "warn")
	sim.inv.feat("contact", tr("Met the %s") % tr(c["name"]), finder,
		{"desc": tr("%s Their chief is %s %s.") % [tr(c["desc"]), tr(c["chief"]), tr(c["epithet"])], "at": c["pos"]})
	pending.append("contact_" + c["id"])
	_pick_nemesis(c["id"])

## Daily tribute and treaty expiry.
func _treaties(c: Dictionary) -> void:
	var id: String = c["id"]
	for type in c["treaties"].keys():
		if c["treaties"][type]["until"] <= sim.time:
			c["treaties"].erase(type)
			sim.alert(tr("Our %s with the %s has ended.") % [tr({"peace": "peace", "hunting_rights": "hunting rights", "alliance": "alliance"}[type]), tr(c["name"])], c["pos"], "warn")
	if sim.day() > c["share_day"]:
		c["share_day"] = sim.day()
		_daily_bonds(c)
	if has_treaty(id, "peace") and c["treaties"]["peace"].get("tribute", 0) > 0 and sim.day() > c["tribute_day"]:
		c["tribute_day"] = sim.day()
		var due: int = c["treaties"]["peace"]["tribute"]
		if sim.stock["food"] >= due:
			sim.stock["food"] -= due
			sim.add_log(tr("Tribute of %d food sent to the %s.") % [due, tr(c["name"])], "info")
		else:
			c["treaties"].erase("peace")
			_deed(id, "unpaid_tribute")

## Gathering on their hunting grounds or building near them angers them.
func _trespass(c: Dictionary, dt: float) -> void:
	var n := 0
	for u in sim.living():
		if u.pos.distance_to(c["pos"]) < D.RIVAL_TERRITORY and u.job.get("type", "") in ["gather", "explore"]: n += 1
	if n == 0 or has_treaty(c["id"], "hunting_rights"): return
	if has_treaty(c["id"], "alliance") or c["vassal"] > 0: return
	var tp: Dictionary = C["trespass"]
	c["relation"] = maxf(-100.0, c["relation"] - float(tp["rate"]) * n * dt * (float(tp["peace_mult"]) if has_treaty(c["id"], "peace") else 1.0))
	if c["met"] and sim.time - c["trespass_warned"] > D.DAY_LEN * float(tp["warn_every_days"]):
		c["trespass_warned"] = sim.time
		sim.alert(_txt(tp["alert"], c), c["pos"], "warn")

func on_structure_placed(s) -> void:
	for id in clans:
		var c: Dictionary = clans[id]
		if s.owner == "village" and s.pos.distance_to(c["pos"]) < D.RIVAL_TERRITORY + float(C["deeds"]["built_on_land"]["extra_reach"]):
			_deed(id, "built_on_land")

## Hostile clans raid: a war band marches on the village (or an outpost), steals food
## from an undefended camp and slips home. Bigger feuds mean bigger, more frequent raids.
func _raids(c: Dictionary, dt: float) -> void:
	if sim.hz.level == "off": return # peaceful setting: neighbours never raid
	var cr: Dictionary = C["raids"]
	var N: Dictionary = C["nemesis"]
	var feud := feud_id()
	var ours: bool = feud == c["id"]
	if c["relation"] > (float(N["hostile_at"]) if ours else float(cr["hostile_at"])) or at_peace(c["id"]): return
	c["raid_t"] -= dt
	if c["raid_t"] > 0: return
	var hostility := _hostility(c)
	var pace: float = (float(N["raid_every_mult"]) * float(feud_stage().get("every_mult", 1.0))) if ours else (float(N["others_every_mult"]) if feud != "" else 1.0) # (the nemesis comes more often; the others fall back)
	c["raid_t"] = D.DAY_LEN * lerpf(float(cr["every_days"][0]), float(cr["every_days"][1]), hostility) * Config.rand_in(cr["jitter"]) * (float(cr["winter_mult"]) if sim.hz.winter() else 1.0) * pace
	# a known clan often sends a messenger first: pay, or they come for it
	var cd: Dictionary = C["demands"]
	if not sim.director.allow("clan_raid"): # (the director: the tribe needs a breath)
		c["raid_t"] = sim.director.retry()
		return
	if c["met"] and sim.time - c["last_demand"] > D.DAY_LEN * float(cd["every_days"]) and randf() < float(cd["chance"]) and not ("demand_" + c["id"]) in pending:
		c["last_demand"] = sim.time
		c["demand"] = int((float(cd["food"]["base"]) + hostility * float(cd["food"]["hostility"]) + (float(cd["food"]["winter"]) if sim.hz.winter() else 0.0)) * (float(feud_stage().get("demand_mult", 1.0)) if ours else 1.0))
		pending.append("demand_" + c["id"])
		sim.director.note("demand")
		return
	sim.director.note("clan_raid")
	launch_raid(c)

## 0 (merely hostile) .. 1 (a full blood feud).
func _hostility(c: Dictionary) -> float:
	return clampf(-c["relation"] / float(C["raids"]["full_hostility"]) * float(temper(c["id"]).get("hostility", 1.0)), 0.0, 1.0)

## Raiders go for what's outside the wall first (rivals.json raids.outside_first): with the
## village walled, the building of `types` of ours outside every ring nearest the clan,
## with chance `chance`; null = the village itself.
func outside_target(c: Dictionary):
	var of: Dictionary = C["raids"].get("outside_first", {})
	if of.is_empty() or not sim.inside_wall(D.VILLAGE) or randf() >= float(of["chance"]): return null
	var best = null
	for s in sim.structures:
		if not s.built or not sim.ours(s) or not s.type in of["types"] or sim.inside_wall(s.pos) or s.pos.distance_to(D.VILLAGE) > float(of["reach"]): continue
		if best == null or s.pos.distance_to(c["pos"]) < best.pos.distance_to(c["pos"]): best = s
	return best

## Against a big tribe the clans band together (rivals.json raids.coalition): another clan
## that hates us as much sends a share of its warriors with the raid, to the same target.
func _coalition(c: Dictionary, target: Vector2, aim) -> void:
	var co: Dictionary = C["raids"].get("coalition", {})
	if co.is_empty() or sim.living().size() < int(co["min_pop"]): return
	for id in clans:
		var o: Dictionary = clans[id]
		if id == c["id"] or not o["met"] or at_peace(id) or float(o["relation"]) > float(co["relation"]) or int(o["warriors"]) < 2: continue
		var n := maxi(1, int(int(o["warriors"]) * float(co["share"])))
		for i in n:
			var w := _spawn(o, "warrior", target + Vector2(randf_range(-60, 60), randf_range(-50, 50)))
			w.raid = true
			w.raid_t = float(C["raids"]["give_up_s"])
			w.aim_id = aim.id if aim else -1
		o["warriors"] = maxi(0, int(o["warriors"]) - n)
		note(id, "raided")
		sim.alert(_txt(co["alert"], o, {"with": tr(c["name"]), "n": n}), o["pos"], "danger")
		return # (one clan joins: a coalition, not the whole world at once)

func launch_raid(c: Dictionary) -> void:
	var cr: Dictionary = C["raids"]
	var hostility := _hostility(c)
	var stage_add: int = int(feud_stage().get("size_add", 0)) if feud_id() == c["id"] else 0
	var size := mini(c["warriors"] + stage_add, int(cr["size"]["base"]) + int(hostility * float(cr["size"]["hostility"])) + (int(cr["size"]["winter"]) if sim.hz.winter() else 0) + stage_add \
		+ int(float(cr["size"].get("per_our_pop", 0.0)) * sim.living().size())) # (a bigger tribe draws bigger war bands, if the clan has the warriors)
	if size < 1: return
	if feud_id() == c["id"]: c["raid_live"] = true
	var target: Vector2 = D.VILLAGE
	var outposts: Array = sim.contracts.list.filter(func(k): return k.kind == "settle" and sim.contracts.is_running(k))
	if not outposts.is_empty() and randf() < float(cr["outpost_chance"]): target = outposts[0].site
	var aim = outside_target(c) if target == D.VILLAGE else null
	if aim: target = aim.pos
	for i in size:
		var w := _spawn(c, "warrior", target + Vector2(randf_range(-60, 60), randf_range(-50, 50)))
		w.raid = true
		w.raid_t = float(cr["give_up_s"])
		w.aim_id = aim.id if aim else -1
	c["warriors"] = maxi(0, c["warriors"] - size)
	note(c["id"], "raided")
	_coalition(c, target, aim)
	if not c["met"]:
		c["met"] = true # strangers attack: contact by force
		pending.append("contact_" + c["id"])
	sim.alert(_txt(cr["alert"], c, {"n": size}), c["pos"], "danger")

func _hunters(c: Dictionary, dt: float) -> void:
	var alive: int = sim.predators.filter(func(p): return p.clan == c["id"] and p.kind == "hunter" and not p.dead and not p.fled).size()
	if alive >= int(C["people"]["hunters"]): return
	c["hunter_t"] -= dt
	if c["hunter_t"] > 0: return
	c["hunter_t"] = D.DAY_LEN * float(C["people"]["hunter_every_days"])
	_spawn(c, "hunter")

# ------------------------------------------------------------ the nemesis (make_it_fun C2)
## The clan that has made us its enemy ("" = none yet): one face for the horizon threat.
func nemesis_id() -> String:
	for id in clans:
		if clans[id].get("nemesis", false): return id
	return ""

## The nemesis while the feud runs ("" when there is none or it has ended).
func feud_id() -> String:
	var id := nemesis_id()
	return id if id != "" and not clans[id].get("feud_over", false) else ""

## Make a clan the nemesis (a game master's verb too; "" clears it). Returns false for an
## unknown clan.
func set_nemesis(id: String) -> bool:
	if id != "" and not clans.has(id): return false
	for k in clans: clans[k]["nemesis"] = false
	if id == "": return true
	var c: Dictionary = clans[id]
	c["nemesis"] = true
	c["feud_over"] = false
	note(id, "marked")
	if c["met"]:
		var N: Dictionary = C["nemesis"]
		sim.add_log(_txt(N["marked"], c), "danger")
		sim.alert(_txt(N["marked"], c), c["pos"], "warn")
	return true

## How much a clan wants to be our enemy: the worse the relation, the more; martial clans more.
func nemesis_score(id: String) -> float:
	var c: Dictionary = clans[id]
	return -float(c["relation"]) + (float(C["nemesis"]["pick"]["martial"]) if c["culture"] == "martial" else 0.0)

## Choose the nemesis once: at a first contact the clan met takes the part if its score is at
## least min_score; if none has by by_day, the worst of the clans met.
func _pick_nemesis(just_met := "") -> void:
	if nemesis_id() != "" or not bool(C["nemesis"].get("on", true)): return
	var P: Dictionary = C["nemesis"]["pick"]
	if just_met != "":
		if nemesis_score(just_met) >= float(P["min_score"]): set_nemesis(just_met)
		return
	if sim.day() < int(P["by_day"]): return
	var best := ""
	for id in clans:
		if clans[id]["met"] and clans[id]["vassal"] <= 0 and not has_treaty(id, "alliance") and (best == "" or nemesis_score(id) > nemesis_score(best)): best = id
	if best != "": set_nemesis(best)

## The escalation stage of the feud now (nemesis "stages": the last whose era has come).
func feud_stage() -> Dictionary:
	var out: Dictionary = {}
	for st in C["nemesis"]["stages"]:
		if sim.evo.era >= int(st["era"]): out = st
	return out

## The feud's milestones: their first raid held off, and its end (befriended, at peace,
## vassals, or beaten at home over_defeats times), both achievements.
func _feud(c: Dictionary) -> void:
	if not c.get("nemesis", false) or c.get("feud_over", false): return
	var N: Dictionary = C["nemesis"]
	if c.get("raid_live", false) and not sim.predators.any(func(p): return p.clan == c["id"] and p.raid and not p.dead and not p.fled):
		c["raid_live"] = false
		if not c.get("first_raid_held", false):
			c["first_raid_held"] = true
			sim.inv.feat("feud", tr(N["feats"]["first_raid"]) % tr(c["name"]), null, {"at": D.VILLAGE})
	if stance(c["id"]) in N["over_stances"] or at_peace(c["id"]) or c["vassal"] > 0 or c.get("defeats", 0) >= int(N["over_defeats"]):
		c["feud_over"] = true
		note(c["id"], "feud_over")
		sim.inv.feat("feud", tr(N["feats"]["over"]) % tr(c["name"]), null, {"at": c["pos"]})

# ------------------------------------------------------------ the ledger and the chief (make_it_fun C1)
## Fill in what an older save lacks (the ledger and the chief's temper came later).
func _ensure_chief(c: Dictionary) -> void:
	if c.has("ledger"): return
	c["ledger"] = [] # what passed between us: [{t, kind, args}]
	c["temper"] = str(C["chiefs"]["first"].get(c["culture"], "wary"))
	c["chief_t"] = 0.0 # when the chief took the seat (older entries were their forebear's)
	c["reign"] = Config.rand_in(C["chiefs"]["reign_days"])

## The chief's temper (rivals.json chiefs.tempers): {word, base, hostility, deal}.
func temper(id: String) -> Dictionary:
	return C["chiefs"]["tempers"].get(clans[id].get("temper", "wary"), {})

## Write what happened between us into the clan's ledger: a kind of rivals.json "ledger"
## kinds (or of "deeds", whose reason is then the words), with the vars its text takes. A
## game master's verb too (and the "ledger" story action).
func note(id: String, kind: String, args: Array = []) -> void:
	if not clans.has(id) or not (C["ledger"]["kinds"].has(kind) or C["deeds"].has(kind)): return
	_ensure_chief(clans[id])
	var L: Array = clans[id]["ledger"]
	L.append({"t": sim.time, "kind": kind, "args": args.map(func(x): return str(x))})
	if L.size() > int(C["ledger"]["keep"]): L.pop_front()

## How much a ledger entry weighs (+ good for us, - bad).
func entry_weight(e: Dictionary) -> float:
	var k: Dictionary = C["ledger"]["kinds"].get(e["kind"], {})
	return float(k.get("weight", C["deeds"].get(e["kind"], {}).get("relation", 0.0)))

## A ledger entry in the chief's words ("you attacked our trader").
func entry_text(e: Dictionary) -> String:
	var k: Dictionary = C["ledger"]["kinds"].get(e["kind"], {})
	var t = k.get("text", C["deeds"].get(e["kind"], {}).get("reason", e["kind"]))
	var s: String = tr(str(t[0] if t is Array else t))
	var args: Array = e.get("args", []).map(func(x): return tr(x))
	if s.count("%") == args.size() and not args.is_empty(): s = s % args
	return s

## When it was, as the chief says it: "today", "this spring", "last winter", "in the summer of Year 1".
func when_text(t: float) -> String:
	var W: Dictionary = C["ledger"]["dates"]
	var span: float = D.DAY_LEN * sim.hz.SEASON_DAYS
	var then := int(t / span)
	var now := int(sim.time / span)
	var season: String = tr(sim.hz.SEASONS[then % 4]).to_lower()
	if int(t / D.DAY_LEN) == sim.day() - 1: return tr(W["today"])
	if then == now: return tr(W["this"]) % season
	if then == now - 1: return tr(W["last"]) % season
	return tr(W["long"]) % [season, 1 + then / 4]

## The dated lines of the ledger, newest first (for a game master and the LLM chief).
func ledger_lines(id: String, n := 6) -> Array:
	var L: Array = clans[id].get("ledger", [])
	var out: Array = []
	for i in range(L.size() - 1, maxi(-1, L.size() - 1 - n), -1):
		out.append("%s: %s" % [when_text(L[i]["t"]), entry_text(L[i])])
	return out

## What the chief brings up: the weightiest memory (fading with age, ledger "half_days"),
## in their words with a closing remark, or "" if nothing weighs enough ("quote_min").
func quote(id: String) -> String:
	var c: Dictionary = clans[id]
	var LC: Dictionary = C["ledger"]
	var best = null
	var best_v := 0.0
	for e in c.get("ledger", []):
		var age_days: float = (sim.time - float(e["t"])) / D.DAY_LEN
		var v := absf(entry_weight(e)) / (1.0 + age_days / float(LC["half_days"]))
		if absf(entry_weight(e)) >= float(LC["quote_min"]) and v > best_v:
			best = e
			best_v = v
	if best == null: return ""
	var s: String = tr(LC["quote"]) % [when_text(best["t"]), entry_text(best)]
	s = s.left(1).to_upper() + s.substr(1)
	var tag: String = ("good" if entry_weight(best) > 0 else "bad") + ("_inherited" if float(best["t"]) < float(c.get("chief_t", 0.0)) else "")
	var tags: Array = LC["tags"][tag]
	return s + " " + (tr(tags.pick_random()) % tr(c.get("old_chief", c["chief"])) if tag.ends_with("_inherited") else tr(tags.pick_random()))

## The chief dies and another takes the seat (reign over, or a game master): a new name from
## rivals.json chiefs.names for their culture, another temper, the relation drawn part of the
## way to the new chief's own; the ledger stays: it is what the successor inherits.
func succeed(id: String) -> String:
	if not clans.has(id): return ""
	var c: Dictionary = clans[id]
	_ensure_chief(c)
	var ch: Dictionary = C["chiefs"]
	var pool: Array = ch["names"].get(c["culture"], ch["names"].values()[0]).filter(func(nm): return nm[0] != c["chief"])
	if pool.is_empty(): return ""
	var nm: Array = pool.pick_random()
	var tempers: Array = ch["tempers"].keys().filter(func(k): return k != c["temper"])
	var old: String = c["chief"]
	c["old_chief"] = old
	c["chief"] = nm[0]
	c["epithet"] = nm[1]
	c["temper"] = tempers.pick_random() if not tempers.is_empty() else c["temper"]
	c["chief_t"] = sim.time
	c["reign"] = Config.rand_in(ch["reign_days"])
	var target: float = c["base"] + float(temper(id).get("base", 0.0))
	c["relation"] = lerpf(c["relation"], target, float(ch["reset"]))
	if c["met"]:
		var t: String = tr(ch["log"]) % [tr(old), tr(c["name"]), tr(c["chief"]), tr(c["epithet"]), tr(temper(id)["word"])]
		sim.add_log(t, "story")
		sim.alert(t, c["pos"], "warn")
	return c["chief"]

func _succession(c: Dictionary) -> void:
	if sim.time - float(c["chief_t"]) > float(c["reign"]) * D.DAY_LEN: succeed(c["id"])

# ------------------------------------------------------------ first-contact choice
## The clan dilemmas (contact, demand, call, submit) are config/dilemmas.json, run by the
## shared runner with the clan's values; the trader's offers (computed goods) are coded.
func event_def(ev: String) -> Dictionary:
	if ev.begins_with("trade_"): return _trade_def(ev.trim_prefix("trade_"))
	var d := _dilemma(ev)
	var view: Dictionary = sim.story.dilemma_view(sim.DILEMMAS[d[0]], d[1])
	var q := quote(d[1]["clan"])
	if q != "" and d[0] != "contact": view["text"] = str(view.get("text", "")) + "\n\n" + tr("%s %s says: \"%s\"") % [d[1]["chief"], d[1]["epithet"], q]
	return view

func resolve(ev: String, idx: int) -> String:
	if ev.begins_with("trade_"): return _trade_resolve(ev.trim_prefix("trade_"), idx)
	var d := _dilemma(ev)
	var out: Dictionary = sim.story.dilemma_choose(sim.DILEMMAS[d[0]], idx, d[1])
	if out["vars"].get("open", "") == "war": sim.flags["open_war"] = d[1].get("foe", "")
	return out["text"]

## [dilemma id, vars] for a clan event id ("demand_<clan>", "contact_<clan>"...).
func _dilemma(ev: String) -> Array:
	var kind := "contact"
	for k in ["demand", "call", "submit"]:
		if ev.begins_with(k + "_"): kind = k
	var id := ev.trim_prefix(kind + "_")
	var c: Dictionary = clans[id]
	var v := {"clan": id, "clan_name": tr(c["name"]), "chief": tr(c["chief"]), "epithet": tr(c["epithet"]), "clan_desc": tr(c["desc"]),
		"clan_pos": c["pos"], "demand": c["demand"], "martial": c["culture"] == "martial"}
	if kind == "call":
		v["foe"] = c["call_target"]
		v["foe_name"] = tr(clans[c["call_target"]]["name"])
	if kind == "submit" and not (c["warriors"] <= 1 or c["pop"] <= 7 or c.get("defeats", 0) >= 2): kind = "submit_unbroken"
	return [kind, v]

# ------------------------------------------------------------ envoys and parley
## Why u can't go as envoy to this clan right now ("" = they can).
func envoy_block(u: E.Unit, id: String) -> String:
	if not clans[id]["met"]: return "We have not met them yet"
	if u.dead: return "Dead"
	if u.role != "": return "Busy with a contract"
	var other = sim.unit_by_id(clans[id]["envoy"])
	if other and not other.dead and other.role == "envoy": return "Another envoy is already on the way"
	return ""

func send_envoy(u: E.Unit, id: String) -> String:
	var why := envoy_block(u, id)
	if why != "": return why
	clans[id]["envoy"] = u.id
	u.role = "envoy"
	sim.set_job(u, {"type": "envoy", "clan": id})
	sim.add_log(tr("%s sets out as our envoy to the %s.") % [tr(u.name), tr(clans[id]["name"])], "story", [u])
	return ""

## Where the envoy stops: at the edge of their village, on our side.
func parley_spot(id: String) -> Vector2:
	var p: Vector2 = clans[id]["pos"]
	return p + (D.VILLAGE - p).normalized() * 120.0

func envoy_arrived(u: E.Unit, id: String) -> void:
	var c: Dictionary = clans[id]
	var cpl: Dictionary = C["parley"]
	if stance(id) == "Blood feud" and randf() < float(cpl["blood_feud_beat"]): # no words for enemies of the blood
		sim.hurt_unit(u, u.max_hp * float(cpl["beat_damage"]), null)
		sim.remember(u, tr("was beaten and driven off by the %s when sent as envoy on Day %d") % [tr(c["name"]), sim.day()], 8)
		sim.alert(tr("The %s beat our envoy %s and drove them off. There is blood between us.") % [tr(c["name"]), tr(u.name)], c["pos"], "danger", [u])
		end_parley(u, id)
		return
	sim.paused = true
	sim.envoy_arrived.emit(u, id)

## The parley is over: the envoy walks home.
func end_parley(u: E.Unit, id: String) -> void:
	if clans[id]["envoy"] == u.id: clans[id]["envoy"] = -1
	u.role = ""
	if not u.dead: sim.set_job(u, {"type": "move", "to": u.home + Vector2(randf_range(-20, 20), randf_range(10, 30))})

func empty_terms() -> Dictionary:
	return {"treaty": "none", "days": 15, "tribute": 0, "teach": "", "tribe_gives": {"food": 0, "wood": 0, "stone": 0}, "clan_gives": {"food": 0, "wood": 0, "stone": 0}}

## LLM output is untrusted: whitelist the treaty, clamp every number, and never let
## the tribe promise more than it has.
func sanitize_terms(raw: Variant, fallback: Dictionary, id := "") -> Dictionary:
	if not (raw is Dictionary): return fallback.duplicate(true)
	var t := empty_terms()
	var tr_id := str(raw.get("treaty", "none")).to_lower().replace(" ", "_")
	tr_id = {"peace_pact": "peace", "truce": "peace", "non_aggression": "peace", "hunting": "hunting_rights", "trade": "none", "exchange": "none", "gift": "none",
		"ally": "alliance", "allies": "alliance", "blood_brothers": "alliance", "union": "alliance"}.get(tr_id, tr_id)
	t["treaty"] = tr_id if tr_id in TREATIES else "none"
	t["days"] = clampi(_int(raw.get("days", 15)), 5, 60 if t["treaty"] == "alliance" else 40)
	t["tribute"] = clampi(_int(raw.get("tribute", raw.get("tribute_per_day", 0))), 0, 10) if t["treaty"] == "peace" else 0
	var teach := str(raw.get("teach", raw.get("clan_teaches", ""))).to_lower()
	for td in D.TECHS: # names as well as ids
		if teach == td["name"].to_lower() or teach == tr(td["name"]).to_lower(): teach = td["id"]
	t["teach"] = teach if teach in teachable(id) else ""
	for side in ["tribe_gives", "clan_gives"]:
		var g: Variant = raw.get(side, {})
		if not (g is Dictionary): g = {}
		for r in RES:
			var cap: int = int(sim.stock[r]) if side == "tribe_gives" else 60
			t[side][r] = clampi(_int(g.get(r, 0)), 0, mini(cap, 80))
	return t

static func _int(v: Variant) -> int:
	if v is int or v is float: return int(v)
	if v is String and (v as String).is_valid_float(): return int(float(v))
	return 0

func _weights(c: Dictionary) -> Dictionary:
	var pw: Dictionary = C["parley"]["weights"]
	var cp: Dictionary = C["parley"]
	var food: float = float(pw["food"]) * (float(cp["winter_food"]) if sim.hz.winter() else 1.0) * (float(cp["martial_food"]) if c["culture"] == "martial" else 1.0)
	var stone = pw["stone"]
	return {"food": food, "wood": float(pw["wood"]), "stone": float(stone[0] if c["era"] < 2 else stone[1]) if stone is Array else float(stone)}

## How good the deal is for the clan (>= 0: acceptable). Their mood, the envoy's
## standing with this kind of people, what changes hands and what the treaty costs them.
## The weights are config/rivals.json "parley" ([martial, peaceful] pairs).
func deal_value(id: String, t: Dictionary, envoy: E.Unit, round_i := 0) -> float:
	var c: Dictionary = clans[id]
	var cp: Dictionary = C["parley"]
	var w := _weights(c)
	var martial: bool = c["culture"] == "martial"
	var v: float = c["relation"] * float(cp["relation"]) + round_i * float(cp["per_round"]) + float(temper(id).get("deal", 0.0))
	if envoy:
		v += envoy.lv("lore") * float(cp["envoy_lore"]) + (envoy.lv("combat") * float(cp["envoy_combat_martial"]) if martial else 0.0)
		for trait_id in cp["traits"]:
			if envoy.has_trait(trait_id): v += _mp(cp["traits"][trait_id], martial)
	var given := 0.0
	for r in RES:
		given += t["tribe_gives"][r] * w[r]
		v -= t["clan_gives"][r] * w[r]
	v += given
	if given > 0: v += _mp(cp["gift_bonus"], martial) # (the peaceful honour any gift)
	if t.get("teach", "") != "": v -= _mp(cp["teach"], martial) # secrets are not given lightly
	match t["treaty"]:
		"peace":
			v -= _mp(cp["peace"]["base"], martial) + t["days"] * float(cp["peace"]["per_day"])
			v += t["tribute"] * t["days"] * float(cp["peace"]["tribute"]) * w["food"]
		"hunting_rights":
			v -= _mp(cp["hunting_rights"]["base"], martial) + t["days"] * float(cp["hunting_rights"]["per_day"])
		"alliance": # only between peoples who already trust each other
			if c["relation"] < float(cp["alliance"]["min_relation"]) or c["vassal"] > 0: v -= 200.0
			else: v -= _mp(cp["alliance"]["base"], martial) + t["days"] * float(cp["alliance"]["per_day"])
	return v

func inclination(v: float) -> String:
	if v >= 15: return "pleased - this is a good deal for your clan"
	if v >= 0: return "willing - the deal is fair enough"
	if v >= -40: return "unconvinced - you want more for your clan"
	return "unwilling - the offer insults you"

## What the chief would accept instead: take back what they give, then ask for food
## (and wood) the tribe actually has. Returns {} if nothing could close the gap.
func counter_terms(id: String, t: Dictionary, envoy: E.Unit, round_i: int) -> Dictionary:
	var c: Dictionary = clans[id]
	var w := _weights(c)
	var o: Dictionary = t.duplicate(true)
	var gap := -deal_value(id, o, envoy, round_i) + 2.0
	for r in RES:
		if gap <= 0: break
		var back: int = mini(o["clan_gives"][r], ceili(gap / w[r]))
		o["clan_gives"][r] -= back
		gap -= back * w[r]
	for r in ["food", "wood", "stone"]:
		if gap <= 0: break
		var room: int = mini(80, int(sim.stock[r])) - o["tribe_gives"][r]
		var more: int = mini(room, ceili(gap / w[r]))
		if more > 0:
			o["tribe_gives"][r] += more
			gap -= more * w[r]
	return o if gap <= 0 else {}

func terms_text(t: Dictionary) -> String:
	var parts: Array = []
	match t["treaty"]:
		"peace": parts.append(tr("Peace for %d days") % t["days"] + ((tr(", tribute %d food/day") % t["tribute"]) if t["tribute"] > 0 else ""))
		"hunting_rights": parts.append(tr("Hunting rights for %d days") % t["days"])
		"alliance": parts.append(tr("Alliance for %d days") % t["days"])
	var give: Array = []
	var take: Array = []
	for r in RES:
		if t["tribe_gives"][r] > 0: give.append("%d %s" % [t["tribe_gives"][r], tr(r)])
		if t["clan_gives"][r] > 0: take.append("%d %s" % [t["clan_gives"][r], tr(r)])
	if t.get("teach", "") != "": parts.append(tr("they teach us %s") % tr(sim.evo.tech_def(t["teach"])["name"]))
	if not give.is_empty(): parts.append(tr("we give %s") % ", ".join(give))
	if not take.is_empty(): parts.append(tr("they give %s") % ", ".join(take))
	return " · ".join(parts) if not parts.is_empty() else tr("nothing at all")

## Everything the rival chief's LLM node needs for one round of parley.
func parley_ctx(envoy: E.Unit, id: String, offer: Dictionary, message: String, history: Array, round_i: int) -> Dictionary:
	var c: Dictionary = clans[id]
	var v := deal_value(id, offer, envoy, round_i)
	var trs: Array = []
	for k in envoy.traits: trs.append(tr(D.TRAITS[k]["name"]))
	return {
		"clan_id": id, "round": round_i, "value": v,
		"chief": {"name": tr(c["chief"]), "epithet": tr(c["epithet"]), "clan": tr(c["name"]), "ways": tr(c["desc"]),
			"culture": c["culture"], "stance": tr(stance(id)), "relation": roundi(c["relation"]),
			"wrongs_remembered": c["grudges"].slice(-4), "treaties_in_force": treaty_text(id),
			"temper": tr(temper(id).get("word", "")), "what_passed_between_us": ledger_lines(id, 6), "bring_up": quote(id),
			"people": c["pop"], "warriors": c["warriors"], "season": tr(sim.hz.season()) if sim.hz.on() else ""},
		"envoy": {"name": tr(envoy.name), "epithet": tr(envoy.epithet), "traits": trs, "lore": envoy.lv("lore"), "combat": envoy.lv("combat")},
		"their_tribe": {"people": sim.living().size(), "food": roundi(sim.stock["food"]), "wood": roundi(sim.stock["wood"]), "stone": roundi(sim.stock["stone"]),
			"home": sim.settlement_name(D.VILLAGE), "home_is_a": tr(sim.tier_row(sim.tier_of(D.VILLAGE)).get("name", ""))},
		"offer": offer, "offer_text": terms_text(offer), "envoy_says": message, "history": history,
		"you_could_teach": teachable(id).map(func(tid): return {"id": tid, "name": tr(sim.evo.tech_def(tid)["name"])}),
		"inclination": inclination(v),
	}

## The offline chief: same JSON shape as the LLM reply. Deterministic, culture-flavoured.
func chief_reply(ctx: Dictionary, envoy: E.Unit) -> Dictionary:
	var id: String = ctx["clan_id"]
	var c: Dictionary = clans[id]
	var martial: bool = c["culture"] == "martial"
	var v: float = ctx["value"]
	var offer: Dictionary = ctx["offer"]
	var said: String = (str(ctx.get("chief", {}).get("bring_up", "")) + " ") if int(ctx.get("round", 0)) == 0 and str(ctx.get("chief", {}).get("bring_up", "")) != "" else ""
	var tw: String = str(C.get("tier_words", {}).get(sim.tier_of(D.VILLAGE), "")) # (how a chief speaks of a town or a city)
	if int(ctx.get("round", 0)) == 0 and tw != "": said = (tr(tw) % sim.settlement_name(D.VILLAGE)) + " " + said
	var r := _chief_answer(ctx, envoy, c, martial, v, offer)
	r["speech"] = said + str(r["speech"])
	return r

func _chief_answer(ctx: Dictionary, envoy: E.Unit, c: Dictionary, martial: bool, v: float, offer: Dictionary) -> Dictionary:
	var id: String = ctx["clan_id"]
	if v >= 0:
		return {"verdict": "accept", "terms": offer, "speech": (tr("Ha! %s. Done - and may your spears stay far from ours.") if martial else tr("The water is calm. %s - let it be so between our peoples.")) % terms_text(offer)}
	var ct := counter_terms(id, offer, envoy, ctx["round"])
	if ct.is_empty() or v < -90:
		return {"verdict": "refuse", "terms": offer, "speech": tr("You come to my fire with this? Go home, little envoy, before my warriors lose patience.") if martial else tr("Your words are thin as reeds. There is nothing for us here.")}
	var sp: String = tr("Not enough. %s - that I would take.") % terms_text(ct) if martial \
		else tr("The river does not hurry, and neither do we. %s - then there will be peace on the water.") % terms_text(ct)
	return {"verdict": "counter", "terms": ct, "speech": sp}

## Leeway for the LLM chief: a persona may be swayed by words, but only so far.
func check_reply(id: String, raw: Dictionary, offer: Dictionary, envoy: E.Unit, round_i: int, fallback: Dictionary) -> Dictionary:
	var verdict := str(raw.get("verdict", "")).to_lower()
	if not verdict in ["accept", "counter", "refuse"]: return fallback
	var terms := sanitize_terms(raw.get("terms", offer), offer, id)
	if verdict == "accept": terms = offer.duplicate(true)
	var v := deal_value(id, terms, envoy, round_i)
	if verdict in ["accept", "counter"] and v < -25.0: # too generous for the clan: hold to the engine's terms
		if fallback["verdict"] == "refuse": return {"verdict": "refuse", "terms": offer, "speech": raw.get("speech", fallback["speech"])}
		return {"verdict": "counter", "terms": fallback["terms"], "speech": str(raw.get("speech", "")), "note": "clamped"}
	return {"verdict": verdict, "terms": terms, "speech": str(raw.get("speech", ""))}

## Seal the deal: goods change hands, treaties take force, the clan's mood follows.
func seal(envoy: E.Unit, id: String, t: Dictionary, round_i: int) -> String:
	var c: Dictionary = clans[id]
	var v := deal_value(id, t, envoy, round_i)
	for r in RES:
		var g: int = mini(t["tribe_gives"][r], int(sim.stock[r]))
		sim.stock[r] -= g
		sim.stock[r] += t["clan_gives"][r]
	if t.get("teach", "") != "" and not sim.has_tech(t["teach"]):
		sim.evo.seed(t["teach"], float(C["parley"]["seal"]["teach"]), envoy)
		sim.remember(envoy, tr("was taught the secret of %s by the %s on Day %d") % [tr(sim.evo.tech_def(t["teach"])["name"]), tr(c["name"]), sim.day()], 7)
	if t["treaty"] != "none":
		c["treaties"][t["treaty"]] = {"until": sim.time + t["days"] * sim.ranks.amount("long_treaties", "mult", 1.0, envoy) * D.DAY_LEN, "tribute": t["tribute"]}
		if t["treaty"] == "peace": c["tribute_day"] = sim.day()
		if t["treaty"] == "alliance":
			c["treaties"].erase("hunting_rights") # allies hunt freely anyway
			sim.evo.drift("martial", -4.0) # sworn brothers make a gentler people
	var cs: Dictionary = C["parley"]["seal"]
	change(id, clampf(float(cs["base"]) + v * float(cs["per_value"]), float(cs["min"]), float(cs["max"])) + (float(cs["treaty"]) if t["treaty"] != "none" else 0.0))
	var what := terms_text(t)
	note(id, "allied" if t["treaty"] == "alliance" else "sealed", [what])
	sim.remember(envoy, tr("sealed an agreement with the %s on Day %d: %s") % [tr(c["name"]), sim.day(), what], 7)
	sim.gain_xp(envoy, "lore", 12)
	sim.gain_xp(envoy, "trade", 6) # striking a bargain
	sim.ranks.deed(envoy, "seal_deal")
	if t["treaty"] == "alliance": sim.ranks.deed(envoy, "seal_alliance")
	sim.alert(tr("Agreement with the %s: %s.") % [tr(c["name"]), what], c["pos"], "info")
	return what

# ------------------------------------------------------------ knowledge
## Wisdom this clan has that we lack and could learn now.
func teachable(id: String) -> Array:
	if not clans.has(id): return []
	return clans[id]["knows"].filter(func(tid): return not sim.has_tech(tid) and sim.evo.prereqs_met(tid))

# ------------------------------------------------------------ war: our attack on their village
## Our war party is at the gates: the clan's warriors (and a few more) turn out to defend.
func defend(id: String, contract) -> int:
	var c: Dictionary = clans[id]
	c["met"] = true
	c["war_t"] = sim.time
	if at_peace(id): _break_peace(id)
	else: _deed(id, "attacked_village")
	c["treaties"].erase("hunting_rights")
	var df: Dictionary = C["defence"]
	var n: int = clampi(c["warriors"] + int(df["extra"]) + (0 if contract.flags.get("scouted", false) else int(df["unscouted_extra"])), int(df["min"]), int(df["max"]))
	var friends: Array = allies().filter(func(a): return a != id)
	if not friends.is_empty(): # our allies send spears: fewer defenders dare to come out
		n = maxi(int(df["min"]), n - int(df["allies_fewer"]))
		contract.flags["allies"] = friends[0]
		sim.add_log(_txt(df["allies_log"], clans[friends[0]]), "combat")
	c["warriors"] = 0
	for i in n:
		var g := _spawn(c, "warrior")
		g.guard = true
		g.pos = c["pos"] + Vector2.from_angle(i * TAU / n) * 50.0
	sim.alert(_txt(df["alert"], c), c["pos"], "danger")
	return n

## Guards go back to their huts once no war party of ours is in the field.
func _guards_home(c: Dictionary) -> void:
	if sim.contracts.list.any(func(k): return k.kind == "war" and k.plan.get("target", "") == c["id"] and sim.contracts.is_running(k)): return
	for p in sim.predators:
		if p.clan == c["id"] and p.guard and not p.dead and not p.fleeing:
			p.fleeing = true

## What victory takes from them. Returns a short description for logs and memories.
func war_spoils(id: String, objective: String, contract) -> String:
	var c: Dictionary = clans[id]
	sim.evo.drift("martial", 4.0)
	c["defeats"] = c.get("defeats", 0) + 1
	if not ("submit_" + id) in pending: pending.append("submit_" + id) # beaten at home, they may bend the knee
	var sp: Dictionary = C["spoils"]
	match objective:
		"burn":
			var huts: Array = sim.structures.filter(func(st): return st.owner == "rival:" + id and st.type in ["hut", "large_hut"])
			var n := mini(int(sp["burn_huts"]), huts.size())
			for i in n: sim.structures.erase(huts[i])
			c["pop"] = maxi(2, c["pop"] - int(sp["burn_pop"]))
			_deed(id, "burned")
			sim.popup(c["pos"] + Vector2(0, -60), tr("%d huts burned!") % n, Color("#ff9b5a"), true)
			return tr("burned %d of their huts") % n
		"break":
			c["warriors"] = 0
			c["raid_t"] = maxf(c["raid_t"], D.DAY_LEN * float(C["raids"]["no_raids_after_beaten_days"]))
			_deed(id, "broke_warriors")
			return tr("broke their warriors - no raids from them for many days")
	var pf: Dictionary = sp["plunder_food"]
	var food: int = mini(int(pf["max"]), int(pf["base"]) + c["pop"] * int(pf["per_pop"]))
	var wood := int(sp["plunder_wood"])
	sim.stock["food"] += food
	sim.stock["wood"] += wood
	_deed(id, "plundered")
	sim.popup(c["pos"] + Vector2(0, -60), tr("+%d food, +%d wood") % [food, wood], Color("#ffe08a"), true)
	return tr("carried off %d food and %d wood") % [food, wood]

# ------------------------------------------------------------ trade caravans
func _traders(c: Dictionary, dt: float) -> void:
	var ctr: Dictionary = C["traders"]
	if not c["met"] or c["relation"] < float(ctr["min_relation"]) or sim.time - c["war_t"] < D.DAY_LEN * float(ctr["after_war_days"]): return
	if sim.predators.any(func(p): return p.clan == c["id"] and p.kind == "trader" and not p.dead and not p.fled): return
	c["trade_t"] -= dt
	if c["trade_t"] > 0: return
	c["trade_t"] = D.DAY_LEN * float(ctr["every_days"] if c["relation"] < float(ctr["trusted_at"]) else ctr["every_days_trusted"]) * Config.rand_in(ctr["jitter"]) * sim.struct_mul("trade_every") # (a trading post brings them sooner)
	var tp := _spawn(c, "trader", D.VILLAGE + Vector2(randf_range(60, 120), randf_range(40, 90)))
	tp.name = c["trader_name"]
	tp.atk = float(C["people"]["trader"]["atk"])
	sim.add_log(tr("A trader of the %s sets out for our village.") % tr(c["name"]), "info")

func trader_arrived(p: E.Predator) -> void:
	var c: Dictionary = clans[p.clan]
	var ctr: Dictionary = C["traders"]
	var rate: float = (1.0 + (float(ctr["trusted_bonus"]) if c["relation"] >= float(ctr["trusted_at"]) else 0.0)) * sim.folk.haggle(home_trader()) * sim.struct_mul("trade_rate") # our best trader bargains; a trading post pays
	var sells: String = c["sells"]
	var wants: String = c["wants"]
	var offers: Array = [
		{"give": {wants: int(ctr["small"][0])}, "get": {sells: roundi(float(ctr["small"][1]) * rate)}},
		{"give": {wants: int(ctr["large"][0])}, "get": {sells: roundi(float(ctr["large"][1]) * rate)}},
	]
	var ng: int = int(ctr["goods"])
	if sim.stock["goods"] >= ng: # they prize our crafts
		offers.append({"give": {"goods": ng}, "get": {sells: roundi(ng * float(ctr["goods_value"]) * float(ctr["goods_premium"]) * rate / (float(ctr["stone_mult"]) if sells == "stone" else 1.0))}})
	var tl := teachable(p.clan)
	if not tl.is_empty(): offers.append({"give": {wants: int(ctr["lesson_price"])}, "teach": tl[0]})
	c["trade_offers"] = offers
	sim.alert(tr("A trader of the %s has come to our fire.") % tr(c["name"]), p.pos, "info")
	pending.append("trade_" + p.clan)

## Who meets a visiting trader: the best Trade & Barter at home (not away on a task).
func home_trader() -> E.Unit:
	var best: E.Unit = null
	for u in sim.living():
		if u.role != "" or not D.home_side(u.pos): continue
		if best == null or u.lv("trade") > best.lv("trade"): best = u
	return best

func _offer_text(o: Dictionary) -> String:
	var give: Array = []
	for r in o["give"]: give.append("%d %s" % [o["give"][r], tr(r)])
	if o.has("teach"): return tr("%s for a lesson in %s") % [", ".join(give), tr(sim.evo.tech_def(o["teach"])["name"])]
	var get_: Array = []
	for r in o["get"]: get_.append("%d %s" % [o["get"][r], tr(r)])
	return tr("%s for %s") % [", ".join(give), ", ".join(get_)]

func _trade_def(id: String) -> Dictionary:
	var c: Dictionary = clans[id]
	var opts: Array = []
	for o in c["trade_offers"]:
		var ok := true
		for r in o["give"]: ok = ok and sim.stock[r] >= o["give"][r]
		opts.append({"label": tr("Trade"), "desc": _offer_text(o), "enabled": ok})
	opts.append({"label": tr("Send them home"), "desc": tr("Thank the trader and trade nothing."), "enabled": true})
	return {"title": tr("A Trader of the %s") % tr(c["name"]),
		"text": tr("A trader of the %s lays out goods by our fire. They have %s to spare and want %s.") % [tr(c["name"]), tr(c["sells"]), tr(c["wants"])],
		"options": opts}

func _trade_resolve(id: String, idx: int) -> String:
	var c: Dictionary = clans[id]
	for p in sim.predators:
		if p.clan == id and p.kind == "trader" and p.arrived: p.fleeing = true
	var offers: Array = c["trade_offers"]
	c["trade_offers"] = []
	if idx >= offers.size():
		return tr("The trader shrugs, packs up and heads home.")
	var o: Dictionary = offers[idx]
	if not sim.spend(o["give"]): return tr("We cannot pay what we promised. The trader leaves.")
	change(id, 3.0)
	note(id, "traded")
	if o.has("teach"):
		var tid: String = o["teach"]
		var learner = sim.best_unit("lore", false)
		sim.evo.seed(tid, float(C["traders"]["lesson"]), learner)
		if learner: sim.remember(learner, tr("learned something of %s from a trader of the %s on Day %d") % [tr(sim.evo.tech_def(tid)["name"]), tr(c["name"]), sim.day()], 6)
		return tr("The trader shows us how his people work. We understand more of %s.") % tr(sim.evo.tech_def(tid)["name"])
	sim.give(o["get"])
	var haggler = home_trader()
	if haggler: sim.gain_xp(haggler, "trade", 8)
	var known := teachable(id)
	if not known.is_empty() and randf() < float(C["traders"]["learn_chance"]): # watching strangers work teaches a little
		sim.evo.seed(known[0], float(C["traders"]["learn"]), null)
		return tr("Goods change hands: %s. Watching the trader work, our people learn a little of %s.") % [_offer_text(o), tr(sim.evo.tech_def(known[0])["name"])]
	return tr("Goods change hands: %s.") % _offer_text(o)

# ------------------------------------------------------------ alliances and vassals
## Once a day: allies share what they know and may call us to their wars; vassals pay.
func _daily_bonds(c: Dictionary) -> void:
	var id: String = c["id"]
	if c["vassal"] > 0:
		sim.stock["food"] += c["vassal"]
		sim.add_log(tr("The %s, our vassals, bring %d food.") % [tr(c["name"]), c["vassal"]], "info")
		if c["relation"] < float(C["alliance"]["vassal_revolt_below"]) and c["warriors"] >= int(C["alliance"]["vassal_revolt_warriors"]): # they have had enough
			c["vassal"] = 0
			sim.alert(tr("The %s throw off our yoke and rise against us!") % tr(c["name"]), c["pos"], "danger")
			launch_raid(c)
		return
	if not has_treaty(id, "alliance"): return
	var tl := teachable(id)
	if not tl.is_empty():
		sim.evo.seed(tl[0], float(C["alliance"]["share"]), null)
		if randf() < float(C["alliance"]["share_log_chance"]): sim.add_log(tr("Living beside the %s, our people learn more of %s.") % [tr(c["name"]), tr(sim.evo.tech_def(tl[0])["name"])], "tech")
	if sim.time >= c["call_t"] and pending.filter(func(e): return e.begins_with("call_")).is_empty():
		for other in clans:
			if other == id or not clans[other]["met"] or at_peace(other): continue
			if randf() < float(C["alliance"]["call_chance"]):
				c["call_t"] = sim.time + D.DAY_LEN * float(C["alliance"]["call_every_days"])
				c["call_target"] = other
				pending.append("call_" + id)
				break
