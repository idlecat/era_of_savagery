## How a band fights a dangerous beast (sim.hunt). Everyone whose job is "attack" on the
## same beast is one band. For the kinds in config/hunt.json (the saber-tooth) the band
## doesn't trickle in one by one: it musters at a rally point out of the beast's reach,
## charges together, takes places in a ring round it (blows from the flanks hit harder),
## and lets its badly hurt step back while the others keep the beast busy. Kinds not in
## the config fight as before: straight at it.
##
## The attack job asks holding() whether the person is busy with the band (mustering or
## fallen back) instead of fighting, spot() for their place in the ring and dmg_mult() for
## the flanking bonus. update() runs once a tick before the people and keeps the bands.
## summary() is the state for a game master.
extends RefCounted

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")
const Config = preload("res://scripts/config.gd")

var C: Dictionary = Config.load_cfg("hunt")
var sim
## beast id -> {"rally": Vector2, "go": bool, "t": seconds mustering, "ids": [person ids]}
var bands := {}

func _init(s) -> void:
	sim = s

## The tactics for a kind of beast ({} = no tactics: straight at it).
func rules_for(kind: String) -> Dictionary:
	return C.get("kinds", {}).get(kind, {})

## Once a tick: who is in which band, whether the muster is over.
func update(dt: float) -> void:
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
		if not bands.has(pid): bands[pid] = {"rally": _rally(p, band, cfg), "go": band.size() < int(cfg["band"]), "t": 0.0, "ids": []}
		var b: Dictionary = bands[pid]
		b["ids"] = band.map(func(u): return u.id)
		if b["go"]: continue
		b["t"] += dt
		if _ready(p, band, b, cfg): _charge(p, band, cfg)

## Whether the person is busy with the band rather than striking: walking to the rally
## point and waiting there, or fallen back hurt. Moves them; false = fight.
func holding(u: E.Unit, p: E.Predator, dt: float) -> bool:
	var cfg := rules_for(p.kind)
	if cfg.is_empty() or not bands.has(p.id): return false
	var b: Dictionary = bands[p.id]
	if not b["go"]:
		u.act = str(cfg["act"])
		if sim.approach(u, b["rally"], float(cfg["gather_r"]) * 0.5, dt): u.face = p.pos
		return true
	if u.hp < u.max_hp * float(cfg["fall_back_below"]) and _fighting(p, b, cfg, u) > 0:
		u.act = str(cfg["fall_act"])
		var away: Vector2 = u.pos - p.pos
		if away.length() < 1.0: away = Vector2(1, 0)
		var to: Vector2 = p.pos + away.normalized() * float(cfg["fall_back_dist"])
		if not D.same_side(to, u.pos) or D.is_water(to): to = u.home
		if sim.approach(u, to, 10, dt): u.face = p.pos
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
		out.append({"beast": pid, "kind": p.kind if p else "", "charging": b["go"], "rally": [b["rally"].x, b["rally"].y], "people": b["ids"].duplicate()})
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

## How many of the band (but `but`) are close round the beast, not fallen back.
func _fighting(p: E.Predator, b: Dictionary, cfg: Dictionary, but: E.Unit) -> int:
	var n := 0
	for id in b["ids"]:
		if id == but.id: continue
		var o = sim.unit_by_id(id)
		if o and not o.dead and o.hp >= o.max_hp * float(cfg["fall_back_below"]) and o.pos.distance_to(p.pos) <= float(cfg["flank_r"]): n += 1
	return n
