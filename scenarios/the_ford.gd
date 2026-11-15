## "The River Ford": the hand-made scenario. A 6400x4400 land with one river and its
## ford, the original tribe (Panshi, Alie, Linghe...), the Red Ochre and Heron clans close
## by and four more in the far reaches, named landmarks, and scripted events: the Great
## Flood foretold for Day 4 and an ambush on the first frontier camp. The original
## 3600x2400 world sits at SHIFT inside the bigger map (positions are old + SHIFT).
##
## A scenario is a script with INFO and spec(); spec() returns the map for D.load_map():
##   w, h, rivers [PackedVector2Array centrelines], fords [points on a river], village,
##   home {huts, forests [[centre, trees, spread]], bushes}, sites, clans [D.CLANS defs + pos],
##   landmarks, tribe, children, start_jobs, labels, script (story.gd triggers), info.
extends RefCounted

const D = preload("res://scripts/data.gd")

const SHIFT := Vector2(1400, 1000)
const INFO := {"id": "the_ford", "name": "The River Ford", "culture": "huaxia",
	"desc": "The hand-made land of the bonfire: the river and its ford, the Red Ochre and Heron clans close by, four more clans in the far reaches. A flood is foretold, and something stalks the far bank.",
	"brief": "A vision foretells a Great Flood on Day 4. Saber-tooth dens lurk across the ford, where the tribe hopes to found its first sister settlement.",
	"intro": ["The tribe gathers around the bonfire. Saber-tooth tracks have been seen east of the ford."]}

const VILLAGE := Vector2(1300, 1200) + SHIFT
const EAST_SITE := Vector2(2300, 1200) + SHIFT
const FORD := 2200.0 # the ford's y
const CLANS := {"ochre": Vector2(3180, 1300) + SHIFT, "heron": Vector2(360, 2180) + SHIFT,
	"tusk": Vector2(900, 800), "elk": Vector2(5700, 700), "hawk": Vector2(5600, 3800), "willow": Vector2(700, 3900)}

## Scripted events (see story.gd for what a trigger can test and do).
const SCRIPT := [
	{"when": {"time": 275.0}, "do": [{"event": "flood"}]}, # the Great Flood warning, Day 4
	{"when": {"contract": "settle", "progress": 0.45}, "each": true, "toggle": "scripted_ambush",
		"do": [{"spawn": "tiger", "at": "site", "offsets": [Vector2(380, -260), Vector2(400, 240)]},
			{"log": "Something moves in the tall grass near '%s'...", "kind": "danger", "arg": "plan"}]},
]

static func river_x(y: float) -> float:
	return 3360.0 + 40.0 * sin((y - 1000.0) / 170.0)

static func spec() -> Dictionary:
	var river := PackedVector2Array()
	var y := -60.0
	while y <= 4460.0:
		river.append(Vector2(river_x(y), y))
		y += 30.0
	var o := Vector2(780, 640) + SHIFT # the hand-made home area
	var clans: Array = []
	for c in D.CLANS:
		if CLANS.has(c["id"]):
			var def: Dictionary = c.duplicate(true)
			def["pos"] = CLANS[c["id"]]
			clans.append(def)
	return {
		"w": 6400.0, "h": 4400.0, "rivers": [river], "fords": [Vector2(river_x(FORD), FORD)],
		"village": VILLAGE,
		"home": {"huts": [Vector2(430, 470) + o, Vector2(610, 465) + o, Vector2(440, 660) + o, Vector2(620, 665) + o],
			"forests": [[Vector2(230, 230) + o, 22, 170.0], [Vector2(260, 880) + o, 18, 150.0], [Vector2(900, 140) + o, 10, 120.0],
				[Vector2(1620, 250) + o, 22, 170.0], [Vector2(1700, 860) + o, 20, 160.0], [Vector2(1420, 900) + o, 8, 90.0]],
			"bushes": [Vector2(760, 380) + o, Vector2(800, 430) + o, Vector2(720, 760) + o, Vector2(790, 800) + o, Vector2(850, 720) + o, Vector2(1580, 470) + o, Vector2(1660, 640) + o]},
		"sites": [EAST_SITE],
		"clans": clans,
		"landmarks": LANDMARKS.duplicate(true),
		"tribe": TRIBE.duplicate(true),
		"children": ["Ah-Lu", "Tala"],
		"start_jobs": [{"who": "Linghe", "job": "ritual"}, {"who": "Tuo", "job": "food"}, {"who": "Shan", "job": "food"}, {"who": "Bai", "job": "wood"}],
		"labels": [{"text": "UNTAMED EAST BANK", "pos": EAST_SITE + Vector2(250, -330), "size": 20}],
		"script": SCRIPT.duplicate(true),
		"info": {"kind": "scenario", "id": INFO["id"], "name": INFO["name"], "brief": INFO["brief"], "intro": INFO["intro"]},
	}

const LANDMARKS := [
	{"id": "cave", "insight": {"totems": 0.4}, "kind": "cave", "name": "Painted Cave", "pos": Vector2(420, 520) + SHIFT, "reward": {"lore": 40},
		"text": "found the Painted Cave, where the ancestors drew the great hunt"},
	{"id": "stones", "insight": {"totems": 0.3, "code": 0.2}, "kind": "stones", "name": "Standing Stones", "pos": Vector2(620, 2020) + SHIFT, "reward": {"lore": 30}, "devotion": 8.0,
		"text": "found the Standing Stones that hum when the moon is full"},
	{"id": "mammoth", "insight": {"hide": 0.5}, "kind": "bones", "name": "Mammoth Graveyard", "pos": Vector2(1180, 330) + SHIFT, "reward": {"lore": 15, "wood": 25},
		"text": "found the Mammoth Graveyard and hauled home great tusks and ribs"},
	{"id": "flint", "insight": {"tools": 0.6, "bronze": 0.2}, "kind": "flint", "name": "Flint Outcrop", "pos": Vector2(260, 1640) + SHIFT, "reward": {"wood": 40, "lore": 10},
		"text": "found a Flint Outcrop; the tribe's axes bite deeper now"},
	{"id": "grove", "insight": {"farming": 0.5}, "kind": "grove", "name": "Wild Berry Grove", "pos": Vector2(1050, 2080) + SHIFT, "reward": {"food": 40},
		"text": "found a Wild Berry Grove heavy with fruit"},
	{"id": "peak", "insight": {"domestication": 0.4}, "kind": "peak", "name": "Eagle Peak", "pos": Vector2(2860, 300) + SHIFT, "reward": {"lore": 20}, "reveal": 650.0,
		"text": "climbed Eagle Peak and saw the far lands spread below"},
	{"id": "spring", "insight": {"pottery": 0.4}, "kind": "spring", "name": "Hot Spring", "pos": Vector2(3050, 2120) + SHIFT, "reward": {"food": 20, "lore": 15},
		"text": "found a steaming Hot Spring deep in the east"},
	{"id": "volcano", "insight": {"fire": 0.3, "bronze": 0.15}, "kind": "volcano", "name": "Fire Mountain", "pos": Vector2(3380, 250) + SHIFT, "reward": {"lore": 20},
		"text": "climbed toward the smoking Fire Mountain, where the rocks are warm and the ground growls"},
	{"id": "den_n", "insight": {"hide": 0.2}, "kind": "den", "name": "Saber-tooth Den", "pos": Vector2(3260, 760) + SHIFT, "reward": {"lore": 10}, "den": 2,
		"text": "found a Saber-tooth Den littered with bones and lived to tell of it"},
	{"id": "den_s", "insight": {"hide": 0.2}, "kind": "den", "name": "Saber-tooth Den", "pos": Vector2(2620, 2180) + SHIFT, "reward": {"lore": 10}, "den": 1,
		"text": "found another Saber-tooth Den deep in the thickets"},
	# the far reaches of the bigger map
	{"id": "hands", "insight": {"totems": 0.3}, "kind": "cave", "name": "Cave of Hands", "pos": Vector2(450, 2300), "reward": {"lore": 30},
		"text": "found the Cave of Hands, its walls covered in the prints of the long dead"},
	{"id": "wind_peak", "insight": {"domestication": 0.3}, "kind": "peak", "name": "Wind Peak", "pos": Vector2(2500, 380), "reward": {"lore": 20}, "reveal": 650.0,
		"text": "climbed Wind Peak and saw the forests roll away to the sky"},
	{"id": "bison", "insight": {"hide": 0.4}, "kind": "bones", "name": "Bison Bone Pit", "pos": Vector2(2900, 4050), "reward": {"lore": 10, "wood": 20},
		"text": "found the Bison Bone Pit, where a whole herd was once driven over the edge"},
	{"id": "mist", "insight": {"pottery": 0.3}, "kind": "spring", "name": "Mist Spring", "pos": Vector2(6000, 2300), "reward": {"food": 20, "lore": 15},
		"text": "found the Mist Spring, warm water steaming in the cold air"},
	{"id": "ring_w", "insight": {"totems": 0.2, "code": 0.3}, "kind": "stones", "name": "Ring of the Ancients", "pos": Vector2(3700, 380), "reward": {"lore": 25}, "devotion": 6.0,
		"text": "found the Ring of the Ancients, older than any tale the elders know"},
	{"id": "den_w", "insight": {"hide": 0.2}, "kind": "den", "name": "Saber-tooth Den", "pos": Vector2(1400, 3950), "reward": {"lore": 10}, "den": 1,
		"text": "found a Saber-tooth Den among the rocks"},
]

# Memory text must start with a past-tense verb: it is spoken as "the day I <text>".
const TRIBE := [
	{"name": "Panshi", "epithet": "Master Builder", "traits": ["cautious"], "color": Color("#c9a36b"),
	 "hp": 50, "atk": 5, "def": 3, "spd": 0.95, "skills": {"forage": 2, "craft": 4, "combat": 1, "lore": 1},
	 "memory": [{"day": -400, "text": "led the levee reinforcement when the river swelled two winters ago", "impact": 8},
				{"day": -120, "text": "raised the tribe's first longhouse without losing a single beam", "impact": 6}]},
	{"name": "Alie", "epithet": "Spear of the Tribe", "traits": ["belligerent"], "color": Color("#d0603f"),
	 "hp": 60, "atk": 7, "def": 3, "spd": 1.1, "skills": {"forage": 2, "craft": 0, "combat": 4, "lore": 0},
	 "memory": [{"day": -200, "text": "was critically wounded by a saber-toothed tiger on the east bank", "impact": 9},
				{"day": -60, "text": "slew a cave bear with a fire-hardened spear", "impact": 8}]},
	{"name": "Linghe", "epithet": "Voice of the Totem", "traits": ["devout"], "color": Color("#8c7bd6"),
	 "hp": 42, "atk": 4, "def": 2, "spd": 1.0, "skills": {"forage": 1, "craft": 1, "combat": 0, "lore": 4},
	 "memory": [{"day": -300, "text": "dreamed of a white heron circling the eastern bank for three nights", "impact": 7},
				{"day": -90, "text": "calmed a fever spirit that had seized two children", "impact": 6}]},
	{"name": "Tuo", "epithet": "Berry Keeper", "traits": ["gluttonous"], "color": Color("#9bbf5a"),
	 "hp": 52, "atk": 4, "def": 3, "spd": 0.9, "skills": {"forage": 3, "craft": 1, "combat": 1, "lore": 0, "trade": 2},
	 "memory": [{"day": -150, "text": "found the great berry thicket that fed the tribe through the lean moon", "impact": 7}]},
	{"name": "Mo'er", "epithet": "Dozer by the Fire", "traits": ["lazy"], "color": Color("#b7a58f"),
	 "hp": 46, "atk": 4, "def": 2, "spd": 0.9, "skills": {"forage": 1, "craft": 2, "combat": 1, "lore": 1},
	 "memory": [{"day": -50, "text": "slept through the night the wolves circled camp", "impact": 4}]},
	{"name": "Shan", "epithet": "Young Hunter", "traits": ["belligerent"], "color": Color("#c27a4e"),
	 "hp": 50, "atk": 6, "def": 2, "spd": 1.15, "skills": {"forage": 2, "craft": 0, "combat": 2, "lore": 0},
	 "memory": [{"day": -30, "text": "brought down a stag on my first hunt", "impact": 5}]},
	{"name": "Yan", "epithet": "Quiet Tracker", "traits": ["cautious"], "color": Color("#7fa3b8"),
	 "hp": 46, "atk": 5, "def": 2, "spd": 1.05, "skills": {"forage": 3, "craft": 1, "combat": 1, "lore": 1},
	 "memory": [{"day": -80, "text": "spotted the saber-tooth tracks before anyone else", "impact": 6}]},
	{"name": "Qiao", "epithet": "Weaver", "traits": ["devout"], "color": Color("#c68fb3"),
	 "hp": 44, "atk": 3, "def": 2, "spd": 1.0, "skills": {"forage": 1, "craft": 2, "combat": 0, "lore": 2},
	 "memory": [{"day": -100, "text": "wove the totem banner that hangs above the bonfire", "impact": 5}]},
	{"name": "Bai", "epithet": "Stonehand", "traits": ["gluttonous"], "color": Color("#a8a8a0"),
	 "hp": 54, "atk": 5, "def": 3, "spd": 0.95, "skills": {"forage": 1, "craft": 3, "combat": 1, "lore": 0},
	 "memory": [{"day": -70, "text": "knapped forty spearheads in a single moon", "impact": 5}]},
]
