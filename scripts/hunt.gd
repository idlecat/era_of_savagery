## How people face a dangerous beast (sim.hunt), for the kinds in config/hunt.json (the
## saber-tooth); other kinds are fought straight on.
##
## A band: everyone whose job is "attack" on the same beast. It doesn't trickle in one by
## one: it musters at a rally point out of the beast's reach, charges together, takes
## places in a ring round it (blows from the flanks hit harder) and lets its badly hurt
## step back while the others keep the beast busy. Its archers (good hunters, once the
## tribe has a sling or a bow) keep their distance and shoot from afar.
##
## Nobody faces it alone unless they are a match for it (can_solo): someone alone the beast
## comes for runs to the others and calls for help (the "hunt_help" reactions), and one
## sent against it alone waits for help, and backs off if none comes.
##
## The attack job asks holding() whether the person is busy with the band (mustering,
## shooting, fallen back) instead of striking, spot() for their place in the ring and
## dmg_mult() for the flanking bonus; self-defence asks avoid(). update() runs once a tick
## before the people. summary() is the state for a game master; `shots` are for drawing.
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")
const Config = preload("res://scripts/config.gd")

var C: Dictionary = Config.load_cfg("hunt")
var sim
## beast id -> {"rally": Vector2, "go": bool, "t": seconds mustering, "ids": [melee ids],
## "archers": [archer ids], "called": bool}
var bands := {}
## missiles in flight, for drawing: {"from", "to", "t", "life", "weapon"}
var shots: Array = []
var _notice_t := 0.0

func _init(s) -> void:
	sim = s

## The tactics for a kind of beast ({} = no tactics: straight at it).
func rules_for(kind: String) -> Dictionary:
	return C.get("kinds", {}).get(kind, {})

## The weapon someone shoots with ({} = not an archer): a good enough hunter, with the
## best weapon the tribe has (config "archers").
func weapon(u: E.Unit) -> Dictionary:
	var a: Dictionary = C.get("archers", {})
	if a.is_empty() or u.role == "child" or u.lv(str(a["skill"])) < int(a["min_lv"]): return {}
	for w in a.get("weapons", []):
		if sim.story.holds(w.get("when", {})): return w
	return {}

## Whether someone could kill the beast on their own: they would outlast it by the
## config's solo_margin, blow for blow (from afar, with their weapon, if an archer).
func can_solo(u: E.Unit, p: E.Predator) -> bool:
	var al: Dictionary = C["alone"]
	var w := weapon(u)
	var hit: float = sim.unit_atk(u) * (10.0 / (10.0 + p.def)) * (float(w["mult"]) / float(w["cd"]) if not w.is_empty() else 1.0)
	var bitten: float = p.atk * (10.0 / (10.0 + sim.unit_def(u))) / 1.25
	if hit <= 0.0: return false
	return u.hp / maxf(bitten, 0.01) >= p.hp / hit * float(al["solo_margin"])

## Whether nobody stands by them: no other grown-up within alone_r, nobody fighting the beast.
func alone(u: E.Unit, p: E.Predator) -> bool:
	var r := float(C["alone"]["alone_r"])
	for o in sim.units:
		if o == u or o.dead or o.role == "child" or sim.in_hut(o): continue
		if o.pos.distance_to(u.pos) < r: return false
		if o.job.get("type", "") == "attack" and int(o.job.get("target_id", -1)) == p.id: return false
	return true

## Self-defence: someone hit by the beast while alone and no match for it runs to the
## others instead of fighting back (true = handled). The belligerent stand their ground.
func avoid(u: E.Unit, p: E.Predator) -> bool:
	if rules_for(p.kind).is_empty() or u.has_trait("belligerent"): return false
	if not alone(u, p) or can_solo(u, p): return false
	run_to_others(u, p)
	return true

## Run to the nearest grown-up (or home) and call for help.
func run_to_others(u: E.Unit, p: E.Predator) -> void:
	var al: Dictionary = C["alone"]
	var to: Vector2 = u.home
	var best := float(al["seek_r"])
	for o in sim.units:
		if o == u or o.dead or o.role == "child" or sim.in_hut(o) or o.job.get("flee", false): continue
		var d: float = o.pos.distance_to(u.pos)
		if d < best and D.same_side(o.pos, u.pos) and o.pos.distance_to(p.pos) > float(al["alone_r"]):
			best = d
			to = o.pos
	if u.job.get("type", "") == "attack": sim.end_errand(u) # (off the hunt: back to their work after running)
	sim.react.interrupt(u, {"type": "move", "to": sim.dry_spot(to), "flee": true})
	if al.has("popup"): sim.popup(u.pos + Vector2(0, -26), tr(str(al["popup"])), Color("#ff9b7a"))
	sim.react.trigger(str(al["help_event"]), {"victim": u, "attacker": p, "at": u.pos})

## Once a tick: the bands, the muster, the missiles; now and then, who the beasts are after.
func update(dt: float) -> void:
	for s in shots: s["t"] += dt
	shots = shots.filter(func(s): return s["t"] < s["life"])
	var members := {}
	for u in sim.units:
		if u.dead or u.job.get("type", "") != "attack": continue
		var pid: int = int(u.job.get("target_id", -1))
		if not members.has(pid): members[pid] = []
		members[pid].append(u)
	for pid in bands.keys():
		if not members.has(pid): bands.erase(pid)
	for pid in members:
		var p = sim.pred_by_id(pid)
		if p == null or p.dead or p.fleeing or p.fled: continue
		var cfg := rules_for(p.kind)
		if cfg.is_empty(): continue
		var band: Array = members[pid]
		band.sort_custom(func(a, b): return a.id < b.id)
		if not bands.has(pid): bands[pid] = {"rally": _rally(p, band, cfg), "go": false, "t": 0.0, "ids": [], "archers": [], "called": false}
		var b: Dictionary = bands[pid]
		b["ids"] = band.filter(func(u): return weapon(u).is_empty()).map(func(u): return u.id)
		b["archers"] = band.filter(func(u): return not weapon(u).is_empty()).map(func(u): return u.id)
		if b["go"]: continue
		b["t"] += dt
		if band.size() < int(cfg["band"]): _lone(p, band, b, cfg)
		elif _ready(p, band, b, cfg): _charge(p, band, cfg)
	_notice_t -= dt
	if _notice_t <= 0.0:
		_notice_t = float(C["alone"]["notice_every"])
		_notice()

## Whether the person is busy with the band rather than striking: walking to the rally
## point and waiting there, shooting from afar, or fallen back hurt. Moves them; false = strike.
func holding(u: E.Unit, p: E.Predator, dt: float) -> bool:
	var cfg := rules_for(p.kind)
	if cfg.is_empty() or not bands.has(p.id): return false
	var b: Dictionary = bands[p.id]
	if not b["go"]:
		u.act = str(C["alone"]["act"] if b["ids"].size() + b["archers"].size() < int(cfg["band"]) else cfg["act"])
		if sim.approach(u, b["rally"], float(cfg["gather_r"]) * 0.5, dt): u.face = p.pos
		return true
	if u.hp < u.max_hp * float(cfg["fall_back_below"]) and _fighting(p, b, cfg, u) + _shooting(b, u) > 0:
		u.act = str(cfg["fall_act"])
		var to := _away(u, p, float(cfg["fall_back_dist"]))
		if sim.approach(u, to, 10, dt): u.face = p.pos
		return true
	var w := weapon(u)
	if not w.is_empty():
		_shoot(u, p, b, w, dt)
		return true
	return false

## Where the person stands to strike: their place in the ring round the beast, spread
## evenly from the side the band came from (the beast itself without tactics).
func spot(u: E.Unit, p: E.Predator) -> Vector2:
	var cfg := rules_for(p.kind)
	if cfg.is_empty() or not bands.has(p.id): return p.pos
	var b: Dictionary = bands[p.id]
	var ids: Array = b["ids"]
	var i := ids.find(u.id)
	if i < 0 or ids.size() < 2: return p.pos
	var base: float = (b["rally"] - p.pos).angle()
	var a := base + TAU * float(i) / float(ids.size()) + PI / float(ids.size())
	return p.pos + Vector2.from_angle(a) * float(cfg["ring_r"])

## The flanking bonus on a blow: more for every other fighter close round the beast.
func dmg_mult(u: E.Unit, p: E.Predator) -> float:
	var cfg := rules_for(p.kind)
	if cfg.is_empty() or not bands.has(p.id): return 1.0
	var others := _fighting(p, bands[p.id], cfg, u)
	return 1.0 + minf(float(cfg["flank_max"]), float(cfg["flank"]) * others)

## The bands as plain data, for a game master.
func summary() -> Array:
	var out: Array = []
	for pid in bands:
		var b: Dictionary = bands[pid]
		var p = sim.pred_by_id(pid)
		out.append({"beast": pid, "kind": p.kind if p else "", "charging": b["go"], "rally": [b["rally"].x, b["rally"].y],
			"people": b["ids"].duplicate(), "archers": b["archers"].duplicate()})
	return out

# ------------------------------------------------------------------ private
## A place out of the beast's reach, on the side the band comes from, on dry land.
func _rally(p: E.Predator, band: Array, cfg: Dictionary) -> Vector2:
	var c := Vector2.ZERO
	for u in band: c += u.pos
	c /= float(band.size())
	var dir: Vector2 = c - p.pos
	if dir.length() < 1.0: dir = D.VILLAGE - p.pos
	if dir.length() < 1.0: dir = Vector2(1, 0)
	var at: Vector2 = p.pos + dir.normalized() * float(cfg["rally_dist"])
	at = Vector2(clampf(at.x, 30, D.W - 30), clampf(at.y, 40, D.H - 40))
	if D.is_water(at) or not D.same_side(at, p.pos): at = c
	return at

## A band too small to muster: one who could kill it alone goes in; otherwise they call
## for help and wait, and back off when none comes (or the beast comes at them).
func _lone(p: E.Predator, band: Array, b: Dictionary, cfg: Dictionary) -> void:
	if band.all(func(u): return can_solo(u, p)):
		b["go"] = true
		return
	var al: Dictionary = C["alone"]
	if not b["called"]:
		b["called"] = true
		for u in band: sim.react.trigger(str(al["help_event"]), {"victim": u, "attacker": p, "at": u.pos})
		return
	var near := band.any(func(u): return u.pos.distance_to(p.pos) < float(cfg["engaged_r"]))
	if b["t"] < float(al["lone_wait"]) and not near: return
	for u in band:
		if u.pos.distance_to(p.pos) < float(cfg["engaged_r"]) * 1.5: run_to_others(u, p)
		else:
			sim.end_errand(u)
			if al.has("out_popup"): sim.popup(u.pos + Vector2(0, -26), tr(str(al["out_popup"])), Color("#ff9b7a"))
	bands.erase(p.id)

func _ready(p: E.Predator, band: Array, b: Dictionary, cfg: Dictionary) -> bool:
	if b["t"] >= float(cfg["max_wait"]): return true
	if sim.time - p.struck_t < 1.5 and b["t"] >= float(cfg["wait_hurt"]): return true
	var er := float(cfg["engaged_r"])
	if p.pos.distance_to(b["rally"]) < er: return true
	var hold := float(sim.RULES["defense"]["hit_secs"])
	var gathered := 0
	for u in band:
		if u.pos.distance_to(p.pos) < er or sim.time - u.last_hit_t < hold: return true
		if u.pos.distance_to(b["rally"]) <= float(cfg["gather_r"]): gathered += 1
	return gathered == band.size()

func _charge(p: E.Predator, band: Array, cfg: Dictionary) -> void:
	bands[p.id]["go"] = true
	var lead: E.Unit = band[0]
	for u in band:
		if u.lv("combat") > lead.lv("combat"): lead = u
	var words: Array = cfg.get("words", [])
	if not words.is_empty() and not lead.sleeping: sim.life.say_text(lead, tr(str(words.pick_random())), "hunt")
	if cfg.has("popup"): sim.popup(bands[p.id]["rally"] + Vector2(0, -30), tr(str(cfg["popup"])), Color("#ffd36b"))

## An archer keeps the beast at arm's length plus a spear's throw: stands off on the band's
## side (spread in an arc), steps back when it comes too close, shoots when in range.
func _shoot(u: E.Unit, p: E.Predator, b: Dictionary, w: Dictionary, dt: float) -> void:
	var a: Dictionary = C["archers"]
	u.act = str(w["act"])
	var d: float = u.pos.distance_to(p.pos)
	if d < float(w["keep"]):
		sim.approach(u, _away(u, p, float(w["keep"]) + 30.0), 6, dt)
		return
	var ids: Array = b["archers"]
	var n := maxi(1, ids.size())
	var k := float(maxi(0, ids.find(u.id))) + 0.5
	var spread := float(a["spread"])
	var ang: float = (b["rally"] - p.pos).angle() + (lerpf(-spread, spread, k / float(n)) if n > 1 else 0.0)
	var stand: Vector2 = p.pos + Vector2.from_angle(ang) * float(w["range"]) * 0.8
	if D.is_water(stand) or not D.same_side(stand, p.pos): stand = u.pos
	if d > float(w["range"]) or u.pos.distance_to(stand) > float(w["range"]) * 0.35: sim.approach(u, stand, 8, dt) # (shooting on the way once in range)
	if u.pos.distance_to(p.pos) > float(w["range"]): return
	u.face = p.pos
	u.doing = "fight"
	if u.cd > 0: return
	u.cd = float(w["cd"])
	var dmg: float = sim.unit_atk(u) * float(w["mult"]) * randf_range(0.8, 1.2) * (10.0 / (10.0 + p.def))
	var crit := randf() < 0.04 * u.lv(str(a["skill"]))
	sim.damage_pred(p, dmg * 1.8 if crit else dmg, u, crit)
	shots.append({"from": u.pos, "to": p.pos, "t": 0.0, "life": float(a["flight"]), "weapon": str(w["id"])})
	sim.gain_xp(u, "combat", float(a["xp"]))
	sim.gain_xp(u, str(a["skill"]), float(a["xp"]) * 0.5)

## A point `dist` from the beast, straight away from it from `u` (home if that is water).
func _away(u: E.Unit, p: E.Predator, dist: float) -> Vector2:
	var away: Vector2 = u.pos - p.pos
	if away.length() < 1.0: away = Vector2(1, 0)
	var to: Vector2 = p.pos + away.normalized() * dist
	to = Vector2(clampf(to.x, 30, D.W - 30), clampf(to.y, 40, D.H - 40))
	if not D.same_side(to, u.pos) or D.is_water(to): to = u.home
	return to

## Someone alone that a beast is after (and no match for it) runs to the others.
func _notice() -> void:
	for p in sim.predators:
		if p.dead or p.fled or p.fleeing or p.prey_id < 0 or rules_for(p.kind).is_empty(): continue
		var u = sim.unit_by_id(p.prey_id)
		if u == null or u.dead or u.role == "child" or sim.in_hut(u) or u.has_trait("belligerent"): continue
		if u.job.get("flee", false) or u.job.get("type", "") == "attack": continue
		if u.pos.distance_to(p.pos) > float(C["alone"]["notice_r"]): continue
		if alone(u, p) and not can_solo(u, p): run_to_others(u, p)

## How many of the band's fighters (but `but`) are close round the beast, not fallen back.
func _fighting(p: E.Predator, b: Dictionary, cfg: Dictionary, but: E.Unit) -> int:
	var n := 0
	for id in b["ids"]:
		if id == but.id: continue
		var o = sim.unit_by_id(id)
		if o and not o.dead and o.hp >= o.max_hp * float(cfg["fall_back_below"]) and o.pos.distance_to(p.pos) <= float(cfg["flank_r"]): n += 1
	return n

func _shooting(b: Dictionary, but: E.Unit) -> int:
	return b["archers"].filter(func(id): return id != but.id).size()
