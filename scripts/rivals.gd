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
var pending_contact := ""

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
	var r: float = clans[id]["relation"]
	if r <= -50: return "Blood feud"
	if r <= -15: return "Hostile"
	if r < 15: return "Wary"
	if r < 50: return "Friendly"
	return "Allied"

func owner_clan(owner: String) -> String:
	return owner.trim_prefix("rival:") if owner.begins_with("rival:") else ""

## Known neighbours, for the personas' context.
func summary() -> Array:
	var out: Array = []
	for id in clans:
		var c: Dictionary = clans[id]
		if not c["met"]: continue
		out.append({"clan": tr(c["name"]), "chieftain": tr(c["chief"]), "stance": tr(stance(id)),
			"their_ways": tr(c["desc"]), "wrongs_remembered": c["grudges"].slice(-3)})
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
	var raiding: bool = p.kind == "warrior" and p.raid
	change(p.clan, -6.0 if raiding else -30.0, tr("our %s was slain by your people") % tr("hunter" if p.kind == "hunter" else "warrior"))
	if not raiding:
		sim.alert(tr("We killed one of the %s's people. They will not forget it.") % tr(c["name"]), p.pos, "danger")

## A hunter we attacked runs home with the story.
func on_hunter_attacked(p: E.Predator) -> void:
	var c: Dictionary = clans[p.clan]
	change(p.clan, -12.0, tr("you attacked our hunter"))
	sim.alert(tr("We attacked a hunter of the %s. He runs home to tell his clan.") % tr(c["name"]), p.pos, "warn")

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
	if not sim.flags.get("theft_alert_%s_%d" % [p.clan, sim.day()], false):
		sim.flags["theft_alert_%s_%d" % [p.clan, sim.day()]] = true
		sim.alert(tr("Raiders of the %s are carrying off our food!") % tr(clans[p.clan]["name"]), p.pos, "danger")

# ------------------------------------------------------------ tick
func update(dt: float) -> void:
	for id in clans:
		var c: Dictionary = clans[id]
		# drift back toward the clan's temperament (slowly)
		c["relation"] += (c["base"] - c["relation"]) * dt * 0.0008
		_contact(c)
		_trespass(c, dt)
		_raids(c, dt)
		_hunters(c, dt)
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
	pending_contact = c["id"]

## Gathering on their hunting grounds or building near them angers them.
func _trespass(c: Dictionary, dt: float) -> void:
	var n := 0
	for u in sim.living():
		if u.pos.distance_to(c["pos"]) < D.RIVAL_TERRITORY and u.job.get("type", "") in ["gather", "explore"]: n += 1
	if n == 0: return
	c["relation"] = maxf(-100.0, c["relation"] - 0.05 * n * dt)
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
	if c["relation"] > -15: return
	c["raid_t"] -= dt
	if c["raid_t"] > 0: return
	var hostility := clampf(-c["relation"] / 80.0, 0.0, 1.0)
	c["raid_t"] = D.DAY_LEN * lerpf(5.0, 2.0, hostility) * randf_range(0.8, 1.2) * (0.8 if sim.hz.winter() else 1.0)
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
		pending_contact = c["id"]
	sim.alert(tr("A war band of the %s (%d warriors) is marching on us!") % [tr(c["name"]), size], c["pos"], "danger")

func _hunters(c: Dictionary, dt: float) -> void:
	var alive: int = sim.predators.filter(func(p): return p.clan == c["id"] and p.kind == "hunter" and not p.dead and not p.fled).size()
	if alive >= 2: return
	c["hunter_t"] -= dt
	if c["hunter_t"] > 0: return
	c["hunter_t"] = D.DAY_LEN * 0.8
	_spawn(c, "hunter")

# ------------------------------------------------------------ first-contact choice
func event_def(id: String) -> Dictionary:
	var c: Dictionary = clans[id]
	return {"title": tr("First Contact: the %s") % tr(c["name"]),
		"text": tr("Our scouts have found the %s, led by %s %s. %s What face do we show them?") % [tr(c["name"]), tr(c["chief"]), tr(c["epithet"]), tr(c["desc"])],
		"options": [
			{"label": tr("Offer gifts"), "desc": tr("Send 20 food and fine furs. They will think well of us. (+20 relations)"), "enabled": sim.stock["food"] >= 20},
			{"label": tr("Show our strength"), "desc": tr("Our warriors stand tall at the border. Martial clans respect it; others take it as a threat."), "enabled": true},
			{"label": tr("Keep our distance"), "desc": tr("Watch them, say nothing."), "enabled": true},
		]}

func resolve(id: String, idx: int) -> String:
	var c: Dictionary = clans[id]
	match idx:
		0:
			sim.stock["food"] -= 20
			change(id, 20.0)
			return tr("The %s accept our gifts. %s nods: \"Your people may pass in peace.\"") % [tr(c["name"]), tr(c["chief"])]
		1:
			var martial: bool = c["culture"] == "martial"
			change(id, 8.0 if martial else -12.0, "" if martial else tr("you came to us with spears raised"))
			return tr("%s eyes our warriors. \"Strong. Good.\" The %s will think twice before raiding us.") % [tr(c["chief"]), tr(c["name"])] if martial \
				else tr("The %s take our display as a threat and pull back into their lands.") % tr(c["name"])
	return tr("We watch the %s from afar, and they watch us.") % tr(c["name"])
