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

func _init(s) -> void:
	sim = s

func setup() -> void:
	for def in D.RIVALS:
		var c: Dictionary = def.duplicate(true)
		c["relation"] = def["start"]
		c["met"] = false
		c["warriors"] = int(def["pop"] / 3)
		c["raid_t"] = D.DAY_LEN * randf_range(4.5, 6.0)
		c["hunter_t"] = 0.0
		c["trespass_warned"] = -999.0
		c["grudges"] = [] # short texts for personas
		c["treaties"] = {} # type -> {"until": sim time, "tribute": food per day}
		c["tribute_day"] = 0
		c["last_demand"] = -999.0
		c["demand"] = 0
		c["envoy"] = -1 # unit id of our envoy on the way / in parley
		c["war_t"] = -9999.0 # when we last attacked their village
		c["trade_t"] = D.DAY_LEN * 1.5
		c["trade_offers"] = []
		c["vassal"] = 0 # food per day they pay us as our vassal (0 = free)
		c["call_t"] = D.DAY_LEN * 3.0
		c["call_target"] = ""
		c["share_day"] = 0
		clans[c["id"]] = c
		_build_village(c)
		for i in 2: _spawn(c, "hunter")

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
	p.hp = (32.0 if kind == "hunter" else 42.0) * c["strength"]
	p.max_hp = p.hp
	p.atk = (3.0 if kind == "hunter" else 5.5) * c["strength"]
	p.def = 2.5
	p.spd = 60.0
	return p

# ------------------------------------------------------------ queries
func stance(id: String) -> String:
	if clans[id]["vassal"] > 0: return "Vassal"
	if has_treaty(id, "alliance"): return "Allied"
	var r: float = clans[id]["relation"]
	if r <= -50: return "Blood feud"
	if r <= -15: return "Hostile"
	if r < 15: return "Wary"
	if r < 50: return "Friendly"
	return "Trusted"

## No raids, no demands: a peace pact, an alliance, or they are our vassals.
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
			"their_ways": tr(c["desc"]), "wrongs_remembered": c["grudges"].slice(-3), "treaties": treaty_text(id)})
	return out

func change(id: String, amount: float, reason := "") -> void:
	var c: Dictionary = clans[id]
	var before := stance(id)
	c["relation"] = clampf(c["relation"] + amount, -100.0, 100.0)
	if reason != "" and amount <= -10: c["grudges"].append(reason)
	if stance(id) != before and c["met"]:
		var worse: bool = amount < 0
		sim.alert(tr("The %s is now %s toward us.") % [tr(c["name"]), tr(stance(id)).to_lower()], c["pos"], "warn" if worse else "info")

# ------------------------------------------------------------ hooks from the simulation
func on_rival_killed(p: E.Predator, by) -> void:
	if p.clan == "" or not clans.has(p.clan): return
	var c: Dictionary = clans[p.clan]
	c["pop"] = maxi(2, c["pop"] - 1)
	if p.kind == "warrior": c["warriors"] = maxi(0, c["warriors"] - 1)
	var raiding: bool = p.kind == "warrior" and (p.raid or p.guard) # killed in a fight they chose / in our attack
	if not raiding: _break_peace(p.clan)
	change(p.clan, -6.0 if raiding else -30.0, tr("our %s was slain by your people") % tr({"hunter": "hunter", "trader": "trader"}.get(p.kind, "warrior")))
	if not raiding:
		sim.alert(tr("We killed one of the %s's people. They will not forget it.") % tr(c["name"]), p.pos, "danger")

## A hunter we attacked runs home with the story.
func on_hunter_attacked(p: E.Predator) -> void:
	var c: Dictionary = clans[p.clan]
	_break_peace(p.clan)
	if p.kind == "trader":
		change(p.clan, -20.0, tr("you attacked our trader"))
		sim.alert(tr("We attacked a trader of the %s. He flees home with his goods.") % tr(c["name"]), p.pos, "warn")
		return
	change(p.clan, -12.0, tr("you attacked our hunter"))
	sim.alert(tr("We attacked a hunter of the %s. He runs home to tell his clan.") % tr(c["name"]), p.pos, "warn")

func _break_peace(id: String) -> void:
	if not at_peace(id): return
	clans[id]["treaties"].clear()
	clans[id]["vassal"] = 0
	change(id, -30.0, tr("you broke the peace you swore"))
	sim.alert(tr("We have broken the peace with the %s! They will remember us as oath-breakers.") % tr(clans[id]["name"]), clans[id]["pos"], "danger")

## A clan member got back to the village: warriors rejoin the war band.
func on_return(p: E.Predator) -> void:
	if p.kind == "warrior" and clans.has(p.clan): clans[p.clan]["warriors"] += 1

func on_villager_killed(u, killer) -> void:
	if killer == null or not (killer is E.Predator) or killer.clan == "": return
	var c: Dictionary = clans[killer.clan]
	c["grudges"].append(tr("they killed %s") % tr(u.name))
	for o in sim.living():
		if o.pos.distance_to(u.pos) < 400 or o.home == u.home:
			sim.remember(o, tr("saw %s killed by the %s on Day %d") % [tr(u.name), tr(c["name"]), sim.day()], 8)

## Food stolen by a raider standing in an undefended village.
func steal(p: E.Predator) -> void:
	var amount: float = minf(sim.stock["food"], 12.0 + 6.0 * randf())
	sim.stock["food"] -= amount
	p.loot = true
	p.fleeing = true
	sim.popup(p.pos + Vector2(0, -30), tr("Food stolen! -%d") % roundi(amount), Color("#ff8a7a"), true)
	if sim.flags.get("theft_alert_" + p.clan, -1) != sim.day():
		sim.flags["theft_alert_" + p.clan] = sim.day()
		sim.alert(tr("Raiders of the %s are carrying off our food!") % tr(clans[p.clan]["name"]), p.pos, "danger")

# ------------------------------------------------------------ tick
func update(dt: float) -> void:
	for id in clans:
		var c: Dictionary = clans[id]
		# drift back toward the clan's temperament (slowly)
		var target: float = c["base"] + (25.0 if has_treaty(id, "peace") else 0.0) + (45.0 if has_treaty(id, "alliance") else 0.0) + (20.0 if c["vassal"] > 0 else 0.0)
		c["relation"] += (target - c["relation"]) * dt * 0.0008
		_treaties(c)
		_contact(c)
		_trespass(c, dt)
		_raids(c, dt)
		_hunters(c, dt)
		_traders(c, dt)
		_guards_home(c)
		# people and warriors regrow
		if randf() < dt / (D.DAY_LEN * 2.0): c["pop"] = mini(14, c["pop"] + 1)
		c["warriors"] = clampi(c["warriors"], 0, int(c["pop"] / 2))
		if randf() < dt / D.DAY_LEN and c["warriors"] < int(c["pop"] / 3): c["warriors"] += 1

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
	pending.append("contact_" + c["id"])

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
			change(id, -20.0, tr("you did not pay the tribute you promised"))
			sim.alert(tr("We could not pay our tribute. The peace with the %s is over!") % tr(c["name"]), c["pos"], "danger")

## Gathering on their hunting grounds or building near them angers them.
func _trespass(c: Dictionary, dt: float) -> void:
	var n := 0
	for u in sim.living():
		if u.pos.distance_to(c["pos"]) < D.RIVAL_TERRITORY and u.job.get("type", "") in ["gather", "explore"]: n += 1
	if n == 0 or has_treaty(c["id"], "hunting_rights"): return
	if has_treaty(c["id"], "alliance") or c["vassal"] > 0: return
	c["relation"] = maxf(-100.0, c["relation"] - 0.05 * n * dt * (0.5 if has_treaty(c["id"], "peace") else 1.0))
	if c["met"] and sim.time - c["trespass_warned"] > D.DAY_LEN:
		c["trespass_warned"] = sim.time
		sim.alert(tr("The %s warns us off their hunting grounds.") % tr(c["name"]), c["pos"], "warn")

func on_structure_placed(s) -> void:
	for id in clans:
		var c: Dictionary = clans[id]
		if s.owner == "village" and s.pos.distance_to(c["pos"]) < D.RIVAL_TERRITORY + 200:
			change(id, -15.0, tr("you built on our land"))

## Hostile clans raid: a war band marches on the village (or an outpost), steals food
## from an undefended camp and slips home. Bigger feuds mean bigger, more frequent raids.
func _raids(c: Dictionary, dt: float) -> void:
	if sim.hz.level == "off": return # peaceful setting: neighbours never raid
	if c["relation"] > -15 or at_peace(c["id"]): return
	c["raid_t"] -= dt
	if c["raid_t"] > 0: return
	var hostility := clampf(-c["relation"] / 80.0, 0.0, 1.0)
	c["raid_t"] = D.DAY_LEN * lerpf(5.0, 2.0, hostility) * randf_range(0.8, 1.2) * (0.8 if sim.hz.winter() else 1.0)
	# a known clan often sends a messenger first: pay, or they come for it
	if c["met"] and sim.time - c["last_demand"] > D.DAY_LEN * 3 and randf() < 0.5 and not ("demand_" + c["id"]) in pending:
		c["last_demand"] = sim.time
		c["demand"] = int(15 + hostility * 25) + (10 if sim.hz.winter() else 0)
		pending.append("demand_" + c["id"])
		return
	launch_raid(c)

func launch_raid(c: Dictionary) -> void:
	var hostility := clampf(-c["relation"] / 80.0, 0.0, 1.0)
	var size := mini(c["warriors"], 2 + int(hostility * 3) + (1 if sim.hz.winter() else 0))
	if size < 1: return
	var target: Vector2 = D.VILLAGE
	var outposts: Array = sim.contracts.list.filter(func(k): return k.kind == "settle" and sim.contracts.is_running(k))
	if not outposts.is_empty() and randf() < 0.4: target = outposts[0].site
	for i in size:
		var w := _spawn(c, "warrior", target + Vector2(randf_range(-60, 60), randf_range(-50, 50)))
		w.raid = true
		w.raid_t = 160.0
	c["warriors"] -= size
	if not c["met"]:
		c["met"] = true # strangers attack: contact by force
		pending.append("contact_" + c["id"])
	sim.alert(tr("A war band of the %s (%d warriors) is marching on us!") % [tr(c["name"]), size], c["pos"], "danger")

func _hunters(c: Dictionary, dt: float) -> void:
	var alive: int = sim.predators.filter(func(p): return p.clan == c["id"] and p.kind == "hunter" and not p.dead and not p.fled).size()
	if alive >= 2: return
	c["hunter_t"] -= dt
	if c["hunter_t"] > 0: return
	c["hunter_t"] = D.DAY_LEN * 0.8
	_spawn(c, "hunter")

# ------------------------------------------------------------ first-contact choice
func event_def(ev: String) -> Dictionary:
	if ev.begins_with("demand_"): return _demand_def(ev.trim_prefix("demand_"))
	if ev.begins_with("trade_"): return _trade_def(ev.trim_prefix("trade_"))
	if ev.begins_with("call_"): return _call_def(ev.trim_prefix("call_"))
	if ev.begins_with("submit_"): return _submit_def(ev.trim_prefix("submit_"))
	var id := ev.trim_prefix("contact_")
	var c: Dictionary = clans[id]
	return {"title": tr("First Contact: the %s") % tr(c["name"]),
		"text": tr("Our scouts have found the %s, led by %s %s. %s What face do we show them?") % [tr(c["name"]), tr(c["chief"]), tr(c["epithet"]), tr(c["desc"])],
		"options": [
			{"label": tr("Offer gifts"), "desc": tr("Send 20 food and fine furs. They will think well of us. (+20 relations)"), "enabled": sim.stock["food"] >= 20},
			{"label": tr("Show our strength"), "desc": tr("Our warriors stand tall at the border. Martial clans respect it; others take it as a threat."), "enabled": true},
			{"label": tr("Keep our distance"), "desc": tr("Watch them, say nothing."), "enabled": true},
		]}

func resolve(ev: String, idx: int) -> String:
	if ev.begins_with("demand_"): return _demand_resolve(ev.trim_prefix("demand_"), idx)
	if ev.begins_with("trade_"): return _trade_resolve(ev.trim_prefix("trade_"), idx)
	if ev.begins_with("call_"): return _call_resolve(ev.trim_prefix("call_"), idx)
	if ev.begins_with("submit_"): return _submit_resolve(ev.trim_prefix("submit_"), idx)
	var id := ev.trim_prefix("contact_")
	var c: Dictionary = clans[id]
	match idx:
		0:
			if sim.stock["food"] < 20: return tr("We have no food to spare for gifts. We watch the %s from afar.") % tr(c["name"])
			sim.stock["food"] -= 20
			change(id, 20.0)
			return tr("The %s accept our gifts. %s nods: \"Your people may pass in peace.\"") % [tr(c["name"]), tr(c["chief"])]
		1:
			var martial: bool = c["culture"] == "martial"
			change(id, 8.0 if martial else -12.0, "" if martial else tr("you came to us with spears raised"))
			return tr("%s eyes our warriors. \"Strong. Good.\" The %s will think twice before raiding us.") % [tr(c["chief"]), tr(c["name"])] if martial \
				else tr("The %s take our display as a threat and pull back into their lands.") % tr(c["name"])
	return tr("We watch the %s from afar, and they watch us.") % tr(c["name"])

# ------------------------------------------------------------ demands (a messenger before a raid)
func _demand_def(id: String) -> Dictionary:
	var c: Dictionary = clans[id]
	var amt: int = c["demand"]
	return {"title": tr("A Messenger from the %s") % tr(c["name"]),
		"text": tr("A painted runner stops at the edge of the firelight. \"%s %s says: give us %d food, or our spears will come and take it.\"") % [tr(c["chief"]), tr(c["epithet"]), amt],
		"options": [
			{"label": tr("Pay"), "desc": tr("Hand over %d food. No raid for now (+5 relations).") % amt, "enabled": sim.stock["food"] >= amt},
			{"label": tr("Refuse"), "desc": tr("Send the runner away. Their war band will come."), "enabled": true},
		]}

func _demand_resolve(id: String, idx: int) -> String:
	var c: Dictionary = clans[id]
	if idx == 0 and sim.stock["food"] >= c["demand"]:
		sim.stock["food"] -= c["demand"]
		change(id, 5.0)
		c["raid_t"] = D.DAY_LEN * 4.0
		return tr("The runner leaves with our food. %s is satisfied - for now.") % tr(c["chief"])
	change(id, -5.0, tr("you sent our messenger away empty-handed"))
	launch_raid(c)
	return tr("The runner spits at our fire and is gone. The %s are coming.") % tr(c["name"])

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
	if stance(id) == "Blood feud" and randf() < 0.5: # no words for enemies of the blood
		sim.hurt_unit(u, u.max_hp * 0.35, null)
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
	var food := 1.0 * (1.4 if sim.hz.winter() else 1.0) * (1.2 if c["culture"] == "martial" else 1.0)
	return {"food": food, "wood": 0.7, "stone": 0.9 if c["era"] < 2 else 1.1}

## How good the deal is for the clan (>= 0: acceptable). Their mood, the envoy's
## standing with this kind of people, what changes hands and what the treaty costs them.
func deal_value(id: String, t: Dictionary, envoy: E.Unit, round_i := 0) -> float:
	var c: Dictionary = clans[id]
	var w := _weights(c)
	var martial: bool = c["culture"] == "martial"
	var v: float = c["relation"] * 0.5 - round_i * 3.0
	if envoy:
		v += envoy.lv("lore") * 2.0 + (envoy.lv("combat") * 1.5 if martial else 0.0)
		if envoy.has_trait("belligerent"): v += 4.0 if martial else -8.0
		if envoy.has_trait("devout") and not martial: v += 8.0
		if envoy.has_trait("cautious"): v += 2.0
	var given := 0.0
	for r in RES:
		given += t["tribe_gives"][r] * w[r]
		v -= t["clan_gives"][r] * w[r]
	v += given
	if given > 0 and not martial: v += 5.0 # the Heron honour any gift
	if t.get("teach", "") != "": v -= 28.0 if martial else 16.0 # secrets are not given lightly
	match t["treaty"]:
		"peace":
			v -= (30.0 if martial else 12.0) + t["days"] * 0.6
			v += t["tribute"] * t["days"] * 0.9 * w["food"]
		"hunting_rights":
			v -= 18.0 + t["days"] * 0.5
		"alliance": # only between peoples who already trust each other
			if c["relation"] < 30 or c["vassal"] > 0: v -= 200.0
			else: v -= (25.0 if martial else 15.0) + t["days"] * 0.3
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
			"people": c["pop"], "warriors": c["warriors"], "season": tr(sim.hz.season()) if sim.hz.on() else ""},
		"envoy": {"name": tr(envoy.name), "epithet": tr(envoy.epithet), "traits": trs, "lore": envoy.lv("lore"), "combat": envoy.lv("combat")},
		"their_tribe": {"people": sim.living().size(), "food": roundi(sim.stock["food"]), "wood": roundi(sim.stock["wood"]), "stone": roundi(sim.stock["stone"])},
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
		sim.evo.seed(t["teach"], 0.6, envoy)
		sim.remember(envoy, tr("was taught the secret of %s by the %s on Day %d") % [tr(sim.evo.tech_def(t["teach"])["name"]), tr(c["name"]), sim.day()], 7)
	if t["treaty"] != "none":
		c["treaties"][t["treaty"]] = {"until": sim.time + t["days"] * D.DAY_LEN, "tribute": t["tribute"]}
		if t["treaty"] == "peace": c["tribute_day"] = sim.day()
		if t["treaty"] == "alliance":
			c["treaties"].erase("hunting_rights") # allies hunt freely anyway
			sim.evo.drift("martial", -4.0) # sworn brothers make a gentler people
	change(id, clampf(5.0 + v * 0.4, 3.0, 25.0) + (8.0 if t["treaty"] != "none" else 0.0))
	var what := terms_text(t)
	sim.remember(envoy, tr("sealed an agreement with the %s on Day %d: %s") % [tr(c["name"]), sim.day(), what], 7)
	sim.gain_xp(envoy, "lore", 12)
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
	else: change(id, -35.0, tr("you attacked our village"))
	c["treaties"].erase("hunting_rights")
	var n: int = clampi(c["warriors"] + 2 + (0 if contract.flags.get("scouted", false) else 1), 2, 8)
	var friends: Array = allies().filter(func(a): return a != id)
	if not friends.is_empty(): # our allies send spears: fewer defenders dare to come out
		n = maxi(2, n - 2)
		contract.flags["allies"] = friends[0]
		sim.add_log(tr("Warriors of the %s fight beside our war party!") % tr(clans[friends[0]]["name"]), "combat")
	c["warriors"] = 0
	for i in n:
		var g := _spawn(c, "warrior")
		g.guard = true
		g.pos = c["pos"] + Vector2.from_angle(i * TAU / n) * 50.0
	sim.alert(tr("Our war party attacks the village of the %s!") % tr(c["name"]), c["pos"], "danger")
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
	match objective:
		"burn":
			var huts: Array = sim.structures.filter(func(st): return st.owner == "rival:" + id and st.type in ["hut", "large_hut"])
			var n := mini(2, huts.size())
			for i in n: sim.structures.erase(huts[i])
			c["pop"] = maxi(2, c["pop"] - 3)
			change(id, -25.0, tr("you burned our homes"))
			sim.popup(c["pos"] + Vector2(0, -60), tr("%d huts burned!") % n, Color("#ff9b5a"), true)
			return tr("burned %d of their huts") % n
		"break":
			c["warriors"] = 0
			c["raid_t"] = maxf(c["raid_t"], D.DAY_LEN * 6.0)
			change(id, -15.0, tr("you hunted down our warriors"))
			return tr("broke their warriors - no raids from them for many days")
	var food: int = mini(60, 20 + c["pop"] * 3)
	var wood := 15
	sim.stock["food"] += food
	sim.stock["wood"] += wood
	change(id, -10.0, tr("you plundered our stores"))
	sim.popup(c["pos"] + Vector2(0, -60), tr("+%d food, +%d wood") % [food, wood], Color("#ffe08a"), true)
	return tr("carried off %d food and %d wood") % [food, wood]

# ------------------------------------------------------------ trade caravans
func _traders(c: Dictionary, dt: float) -> void:
	if not c["met"] or c["relation"] < 15 or sim.time - c["war_t"] < D.DAY_LEN * 5: return
	if sim.predators.any(func(p): return p.clan == c["id"] and p.kind == "trader" and not p.dead and not p.fled): return
	c["trade_t"] -= dt
	if c["trade_t"] > 0: return
	c["trade_t"] = D.DAY_LEN * (2.5 if c["relation"] < 50 else 1.6) * randf_range(0.85, 1.15)
	var tp := _spawn(c, "trader", D.VILLAGE + Vector2(randf_range(60, 120), randf_range(40, 90)))
	tp.name = c["trader_name"]
	tp.atk = 1.5
	sim.add_log(tr("A trader of the %s sets out for our village.") % tr(c["name"]), "info")

func trader_arrived(p: E.Predator) -> void:
	var c: Dictionary = clans[p.clan]
	var rate := 1.0 + (0.3 if c["relation"] >= 50 else 0.0)
	var sells: String = c["sells"]
	var wants: String = c["wants"]
	var offers: Array = [
		{"give": {wants: 15}, "get": {sells: roundi(12 * rate)}},
		{"give": {wants: 30}, "get": {sells: roundi(26 * rate)}},
	]
	if sim.stock["goods"] >= 3: # they prize our crafts
		offers.append({"give": {"goods": 3}, "get": {sells: roundi(3 * 6.0 * 1.2 * rate / (1.5 if sells == "stone" else 1.0))}})
	var tl := teachable(p.clan)
	if not tl.is_empty(): offers.append({"give": {wants: 20}, "teach": tl[0]})
	c["trade_offers"] = offers
	sim.alert(tr("A trader of the %s has come to our fire.") % tr(c["name"]), p.pos, "info")
	pending.append("trade_" + p.clan)

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
	for r in o["give"]:
		if sim.stock[r] < o["give"][r]: return tr("We cannot pay what we promised. The trader leaves.")
	for r in o["give"]: sim.stock[r] -= o["give"][r]
	change(id, 3.0)
	if o.has("teach"):
		var tid: String = o["teach"]
		var learner = sim.best_unit("lore", false)
		sim.evo.seed(tid, 0.35, learner)
		if learner: sim.remember(learner, tr("learned something of %s from a trader of the %s on Day %d") % [tr(sim.evo.tech_def(tid)["name"]), tr(c["name"]), sim.day()], 6)
		return tr("The trader shows us how his people work. We understand more of %s.") % tr(sim.evo.tech_def(tid)["name"])
	for r in o["get"]: sim.stock[r] += o["get"][r]
	var known := teachable(id)
	if not known.is_empty() and randf() < 0.3: # watching strangers work teaches a little
		sim.evo.seed(known[0], 0.1, null)
		return tr("Goods change hands: %s. Watching the trader work, our people learn a little of %s.") % [_offer_text(o), tr(sim.evo.tech_def(known[0])["name"])]
	return tr("Goods change hands: %s.") % _offer_text(o)

# ------------------------------------------------------------ alliances and vassals
## Once a day: allies share what they know and may call us to their wars; vassals pay.
func _daily_bonds(c: Dictionary) -> void:
	var id: String = c["id"]
	if c["vassal"] > 0:
		sim.stock["food"] += c["vassal"]
		sim.add_log(tr("The %s, our vassals, bring %d food.") % [tr(c["name"]), c["vassal"]], "info")
		if c["relation"] < -80 and c["warriors"] >= 3: # they have had enough
			c["vassal"] = 0
			sim.alert(tr("The %s throw off our yoke and rise against us!") % tr(c["name"]), c["pos"], "danger")
			launch_raid(c)
		return
	if not has_treaty(id, "alliance"): return
	var tl := teachable(id)
	if not tl.is_empty():
		sim.evo.seed(tl[0], 0.08, null)
		if randf() < 0.3: sim.add_log(tr("Living beside the %s, our people learn more of %s.") % [tr(c["name"]), tr(sim.evo.tech_def(tl[0])["name"])], "tech")
	if sim.time >= c["call_t"] and pending.filter(func(e): return e.begins_with("call_")).is_empty():
		for other in clans:
			if other == id or not clans[other]["met"] or at_peace(other): continue
			if randf() < 0.35:
				c["call_t"] = sim.time + D.DAY_LEN * 4.0
				c["call_target"] = other
				pending.append("call_" + id)
				break

func _call_def(id: String) -> Dictionary:
	var c: Dictionary = clans[id]
	var foe: Dictionary = clans[c["call_target"]]
	return {"title": tr("The %s Call Us to War") % tr(c["name"]),
		"text": tr("A runner of our allies the %s arrives breathless: \"%s %s asks: will our brothers send spears against the %s?\"") % [tr(c["name"]), tr(c["chief"]), tr(c["epithet"]), tr(foe["name"])],
		"options": [
			{"label": tr("Send a war party"), "desc": tr("Choose a leader to plan a raid on the %s (+10 with our allies).") % tr(foe["name"]), "enabled": true},
			{"label": tr("Send gifts instead"), "desc": tr("15 food for their warriors; they go alone (+3).") , "enabled": sim.stock["food"] >= 15},
			{"label": tr("Refuse"), "desc": tr("This is not our fight (-12 with our allies)."), "enabled": true},
		]}

func _call_resolve(id: String, idx: int) -> String:
	var c: Dictionary = clans[id]
	var foe: Dictionary = clans[c["call_target"]]
	match idx:
		0:
			change(id, 10.0)
			sim.flags["open_war"] = c["call_target"]
			return tr("We will march with the %s against the %s. Choose who leads our spears.") % [tr(c["name"]), tr(foe["name"])]
		1:
			sim.stock["food"] -= 15
			change(id, 3.0)
			foe["pop"] = maxi(3, foe["pop"] - 1)
			change(foe["id"], -5.0)
			return tr("The %s raid the %s alone, fed by our food.") % [tr(c["name"]), tr(foe["name"])]
	change(id, -12.0, tr("you left us to fight alone"))
	return tr("The runner leaves without a word. The %s will remember.") % tr(c["name"])

func _submit_def(id: String) -> Dictionary:
	var c: Dictionary = clans[id]
	var broken: bool = c["warriors"] <= 1 or c["pop"] <= 7 or c.get("defeats", 0) >= 2
	var opts: Array = []
	if broken:
		opts = [
			{"label": tr("Accept their submission"), "desc": tr("They become our vassals: 3 food a day, no more raids."), "enabled": true},
			{"label": tr("Demand a heavy tribute"), "desc": tr("6 food a day - but they will hate us, and may rise again."), "enabled": true},
			{"label": tr("Spare them freely"), "desc": tr("Make peace with no tribute (+20 relations, 20 days of peace)."), "enabled": true},
		]
	else:
		opts = [{"label": tr("Let them lick their wounds"), "desc": tr("They are beaten, but not yet broken."), "enabled": true}]
	return {"title": tr("The %s After the Battle") % tr(c["name"]),
		"text": (tr("%s %s comes out of the smoke, unarmed. \"Enough. The %s will bow to your fire, if you let our children live.\"") % [tr(c["chief"]), tr(c["epithet"]), tr(c["name"])]) if broken
			else tr("The %s pull back behind their huts, bloodied but still defiant.") % tr(c["name"]),
		"options": opts}

func _submit_resolve(id: String, idx: int) -> String:
	var c: Dictionary = clans[id]
	if _submit_def(id)["options"].size() == 1: return tr("We leave them to mourn.")
	match idx:
		0:
			c["vassal"] = 3
			c["relation"] = maxf(c["relation"], -30.0)
			c["treaties"].clear()
			sim.evo.drift("ranked", 6.0) # lords over another people
			sim.alert(tr("The %s are now our vassals.") % tr(c["name"]), c["pos"], "info")
			return tr("%s lays down their weapons at our fire. The %s are ours.") % [tr(c["chief"]), tr(c["name"])]
		1:
			c["vassal"] = 6
			c["relation"] = minf(c["relation"], -60.0)
			c["grudges"].append(tr("you crushed us under a heavy tribute"))
			sim.alert(tr("The %s are now our vassals.") % tr(c["name"]), c["pos"], "info")
			return tr("They will pay, and they will hate us for it.")
	c["relation"] = maxf(c["relation"], -10.0) + 20.0
	c["treaties"]["peace"] = {"until": sim.time + 20 * D.DAY_LEN, "tribute": 0}
	return tr("We let them go in peace. The tale of our mercy will travel far.")
