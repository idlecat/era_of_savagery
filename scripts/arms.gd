## Weapons and weapon mastery (config/weapons.json), owned by the simulation as `sim.arms`.
##
## The tribe's weapons open as it invents them (each weapon's `when`). Everyone has a knack
## for each weapon, fixed from birth (`u.knack`), and a mastery level in each that rises with
## use (`u.arms`: {weapon: {"lv", "xp"}}): blows, shots, kills and hunts, times the knack.
## Who carries what: the weapon they are told to (`u.wield`, set with set_wield()) if they
## can use it, otherwise the one they are best with (score()). The wielded weapon shapes the
## fight: its attack (atk_mult(), folded into sim.unit_atk), the time between blows (cd()),
## its reach, its critical blows, and a ranged weapon makes them an archer (hunt.gd shoots).
## summary() is the state for a game master.
extends RefCounted

const E = preload("res://scripts/entities.gd")
const Config = preload("res://scripts/config.gd")

var C: Dictionary = Config.load_cfg("weapons")
var sim
## Weapons someone of the tribe has mastered first (the achievement is given once each).
var mastered := {}

func _init(s) -> void:
	sim = s

## All the weapons, as config dictionaries, in config order.
func weapons() -> Array: return C.get("weapons", [])

## A weapon's config ({} = no such weapon).
func def(id: String) -> Dictionary:
	for w in weapons():
		if w["id"] == id: return w
	return {}

## Whether the tribe has the weapon (its `when` holds).
func open(id: String) -> bool:
	var w := def(id)
	return not w.is_empty() and sim.story.holds(w.get("when", {}))

## The ids of the weapons the tribe has.
func open_ids() -> Array: return weapons().filter(func(w): return open(w["id"])).map(func(w): return w["id"])

## Whether u can fight with the weapon: the tribe has it and u has the skill it needs.
func can_use(u: E.Unit, id: String) -> bool:
	if u.role == "child" or not open(id): return false
	var needs: Dictionary = def(id).get("needs", {})
	for k in needs:
		if not u.skills.has(k) or u.lv(k) < int(needs[k]): return false
	return true

## u's mastery level with a weapon.
func lv(u: E.Unit, id: String) -> int:
	_ensure(u)
	return int(u.arms.get(id, {}).get("lv", 0))

## u's knack for a weapon (1.0 = ordinary).
func knack(u: E.Unit, id: String) -> float:
	_ensure(u)
	return float(u.knack.get(id, 1.0))

## The word the sheet uses for a knack ("gifted", "apt", "fair", "clumsy").
func knack_word(k: float) -> String:
	for w in C["talent"]["words"]:
		if k >= float(w["at"]): return str(w["word"])
	return ""

## How keen u is to carry a weapon: how good it is, how well they know it, their knack.
func score(u: E.Unit, id: String) -> float:
	var m: Dictionary = C["mastery"]
	return float(def(id).get("rating", 1.0)) * (1.0 + float(m["atk_per_lv"]) * lv(u, id)) * sqrt(knack(u, id))

## The weapon u fights with, as its config dictionary.
func wielded(u: E.Unit) -> Dictionary:
	if u.wield != "" and can_use(u, u.wield): return def(u.wield)
	var best: Dictionary = {}
	var best_s := -1.0
	for w in weapons():
		if not can_use(u, w["id"]): continue
		var s := score(u, w["id"])
		if s > best_s:
			best = w
			best_s = s
	return best if not best.is_empty() else def("club")

## The ranged weapon u shoots with ({} = they fight hand to hand).
func ranged(u: E.Unit) -> Dictionary:
	var w := wielded(u)
	return w if w.get("kind", "") == "ranged" else {}

## The wielded weapon's multiplier on u's attack: the weapon, and their mastery of it.
func atk_mult(u: E.Unit) -> float:
	var w := wielded(u)
	if w.is_empty(): return 1.0
	return float(w.get("atk", 1.0)) * (1.0 + float(C["mastery"]["atk_per_lv"]) * lv(u, w["id"]))

## Seconds between u's blows or shots with what they wield.
func cd(u: E.Unit) -> float:
	var w := wielded(u)
	var m: Dictionary = C["mastery"]
	var off := minf(float(m["cd_max"]), float(m["cd_per_lv"]) * lv(u, str(w.get("id", ""))))
	return float(w.get("cd", 1.0)) * (1.0 - off)

## The extra chance of a critical blow from what u wields and how well.
func crit(u: E.Unit) -> float:
	var w := wielded(u)
	return float(w.get("crit", 0.0)) + float(C["mastery"]["crit_per_lv"]) * lv(u, str(w.get("id", "")))

## How close u must be to strike hand to hand.
func reach(u: E.Unit) -> float: return float(wielded(u).get("reach", 24.0))

## The XP a mastery level takes from `level` to the next.
func xp_need(level: int) -> float:
	var m: Dictionary = C["mastery"]
	return float(m["xp_base"]) + float(m["xp_per_lv"]) * level

## Practice with a weapon: `amt` XP times u's knack for it (levels up to max_lv).
func practice(u: E.Unit, id: String, amt: float) -> void:
	if u == null or u.dead or def(id).is_empty() or not (amt > 0.0): return
	_ensure(u)
	var m: Dictionary = C["mastery"]
	var top := int(m["max_lv"])
	if not u.arms.has(id): u.arms[id] = {"lv": 0, "xp": 0.0}
	var a: Dictionary = u.arms[id]
	if int(a["lv"]) >= top: return
	a["xp"] = float(a["xp"]) + amt * knack(u, id)
	while int(a["lv"]) < top and float(a["xp"]) >= xp_need(int(a["lv"])):
		a["xp"] = float(a["xp"]) - xp_need(int(a["lv"]))
		a["lv"] = int(a["lv"]) + 1
		var wname := tr(str(def(id)["name"]))
		sim.popup(u.pos + Vector2(0, -42), tr(str(m["popup"])) % [wname, a["lv"]], Color("#ffcf7f"))
		if int(a["lv"]) == int(m["master_lv"]): _mastered(u, id)
	if int(a["lv"]) >= top: a["xp"] = 0.0

## A blow or shot with what u wields (and a kill: `kill`).
func used(u: E.Unit, kill := false) -> void:
	var id := str(wielded(u).get("id", ""))
	practice(u, id, float(C["mastery"]["kill_xp" if kill else "blow_xp"]))

## A deer brought down: hunting practice with what u carries.
func hunted(u: E.Unit) -> void:
	practice(u, str(wielded(u).get("id", "")), float(C["mastery"]["hunt_xp"]))

## Tells u which weapon to carry ("" = their own choice). False (and nothing changes) for
## an unknown weapon or a bad id: a game master's input is checked here.
func set_wield(u: E.Unit, id: String) -> bool:
	if u == null or (id != "" and def(id).is_empty()): return false
	u.wield = id
	return true

## The weapons u can choose from, for the sheet: "" (their own choice) then each usable one.
func choices(u: E.Unit) -> Array:
	var out: Array = [""]
	for w in weapons():
		if can_use(u, w["id"]): out.append(w["id"])
	return out

## Gives a new person their knacks and first mastery (from the skill a weapon starts from).
func init_unit(u: E.Unit) -> void:
	var t: Dictionary = C["talent"]
	for w in weapons():
		var id: String = w["id"]
		if not u.knack.has(id):
			var rng := RandomNumberGenerator.new() # (the person's own dice: the game's stay untouched)
			rng.seed = hash("%s|%d|%s" % [u.name, u.id, id])
			var k := rng.randf_range(float(t["min"]), float(t["max"]))
			if rng.randf() < float(t["gifted_chance"]): k = float(t["gifted"])
			if not u.traits.is_empty(): k *= float(t["traits"].get(u.traits[0], {}).get(id, 1.0))
			u.knack[id] = snappedf(k, 0.01)
		if not u.arms.has(id):
			var from := str(w.get("start_skill", ""))
			u.arms[id] = {"lv": mini(int(C["mastery"]["max_lv"]), u.lv(from)) if from != "" and u.skills.has(from) else 0, "xp": 0.0}

## Weapons and people's mastery as plain data, for a game master.
func summary() -> Dictionary:
	var people: Array = []
	for u in sim.living():
		if u.role == "child": continue
		var lvls := {}
		for w in weapons(): lvls[w["id"]] = {"lv": lv(u, w["id"]), "knack": knack(u, w["id"])}
		people.append({"id": u.id, "name": u.name, "wields": str(wielded(u).get("id", "")), "told": u.wield, "weapons": lvls})
	return {"weapons": open_ids(), "people": people, "mastered": mastered.keys()}

func _ensure(u: E.Unit) -> void:
	if u.knack.size() < weapons().size(): init_unit(u) # (people from before weapons, or a new weapon)

func _mastered(u: E.Unit, id: String) -> void:
	var m: Dictionary = C["mastery"]
	var wname := tr(str(def(id)["name"]))
	sim.add_log(tr(str(m["log"])) % [tr(u.name), wname], "combat", [u])
	sim.remember(u, tr(str(m["remember"])) % [wname, sim.day()], 6)
	if not mastered.has(id):
		mastered[id] = true
		sim.inv.feat("weapon", tr(str(m["title"])) % wname, u, {"desc": tr(str(def(id).get("desc", "")))})
