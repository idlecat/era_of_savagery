## Static game data: map geometry, structures, techs, traits, starting tribe.
extends RefCounted

## ---- The map ----
## Map geometry, clans and landmarks are static vars: they start as the hand-made
## "classic" map and mapgen.gd overwrites them for a random map before sim.new_game().
## The original 3600x2400 world (home, river, ford, first two clans and landmarks) sits
## at SHIFT inside the classic map; classic positions are written as old + SHIFT.
const SHIFT := Vector2(1400, 1000)
const DAY_LEN := 90.0 # seconds per in-game day at 1x
const STD_AREA := 6400.0 * 4400.0 # wilderness counts are tuned for this size

static var W := 6400.0
static var H := 4400.0
# ---- River & ford ----
static var RIVER_BASE_X := 1960.0 + 1400.0
static var RIVER_PHASE := 1000.0 # river_x() meanders as sin((y - RIVER_PHASE) / RIVER_PERIOD)
const RIVER_AMP := 40.0
const RIVER_PERIOD := 170.0
const RIVER_HALF := 46.0
static var FORD_Y0 := 1155.0 + 1000.0
static var FORD_Y1 := 1245.0 + 1000.0
static var FORD_Y := 1200.0 + 1000.0

static var VILLAGE := Vector2(1300, 1200) + SHIFT
static var EAST_SITE := Vector2(2300, 1200) + SHIFT
## Where the hand-made starting area (huts, home forests, berry bushes) is laid out.
static var HOME_OFS := Vector2(780, 640) + SHIFT
static var VOLCANO := Vector2(3380, 250) + SHIFT
static var RIVALS: Array = CLASSIC_RIVALS
static var LANDMARKS: Array = CLASSIC_LANDMARKS
static var MAP := {"kind": "classic"} # how this map was made (kind, size, tribes, seed)

## Back to the hand-made map (the default; tests rely on it).
static func use_classic() -> void:
	W = 6400.0
	H = 4400.0
	RIVER_BASE_X = 1960.0 + 1400.0
	RIVER_PHASE = 1000.0
	FORD_Y0 = 1155.0 + 1000.0
	FORD_Y1 = 1245.0 + 1000.0
	FORD_Y = 1200.0 + 1000.0
	VILLAGE = Vector2(1300, 1200) + SHIFT
	EAST_SITE = Vector2(2300, 1200) + SHIFT
	HOME_OFS = Vector2(780, 640) + SHIFT
	VOLCANO = Vector2(3380, 250) + SHIFT
	RIVALS = CLASSIC_RIVALS
	LANDMARKS = CLASSIC_LANDMARKS
	MAP = {"kind": "classic"}

## Map area relative to the standard size: scales forests, herds, finds...
static func area_k() -> float:
	return W * H / STD_AREA

const OVERPOP_THRESHOLD := 12 # PRD says 20; lowered so it fires in a short POC session
const FLOOD_DAY := 4

# ---- Exploration (fog of war) ----
const FOG_CELL := 40.0
const SIGHT_UNIT := 200.0
const SIGHT_SCOUT_BONUS := 30.0 # extra sight while auto-scouting
const SIGHT_STRUCT := 200.0
const SIGHT_BONFIRE := 300.0

# ---- Rival clans: their own villages, people and moods (see rivals.gd) ----
## relation -100 (blood feud) .. +100 (allies); "base" is where it drifts back to.
const CLASSIC_RIVALS := [
	{"id": "ochre", "name": "Red Ochre Clan", "chief": "Gor", "epithet": "the Scarred", "culture": "martial",
		"color": Color("#c8452e"), "pos": Vector2(3180, 1300) + SHIFT, "base": -25.0, "start": -20.0, "pop": 11, "era": 2,
		"strength": 1.2, "hunter_name": "Red Ochre hunter", "warrior_name": "Red Ochre warrior", "trader_name": "Red Ochre trader", "sells": "stone", "wants": "food", "knows": ["fire", "tools", "hide", "domestication"], "desc": "Hunters who paint themselves in red earth. They prize strength and take what they need."},
	{"id": "heron", "name": "Heron Clan", "chief": "Ama", "epithet": "Who Listens to Water", "culture": "spiritual",
		"color": Color("#3e8fc0"), "pos": Vector2(360, 2180) + SHIFT, "base": 10.0, "start": 5.0, "pop": 9, "era": 1,
		"strength": 0.85, "hunter_name": "Heron hunter", "warrior_name": "Heron warrior", "trader_name": "Heron trader", "sells": "food", "wants": "wood", "knows": ["fire", "pottery", "totems"], "desc": "River folk led by a seer. Slow to anger, but they never forget a wrong."},
	# the far reaches of the bigger map
	{"id": "tusk", "name": "Tusk Clan", "chief": "Dun", "epithet": "Broad-Shoulders", "culture": "martial",
		"color": Color("#8a5a2a"), "pos": Vector2(900, 800), "base": -15.0, "start": -10.0, "pop": 10, "era": 2,
		"strength": 1.1, "hunter_name": "Tusk hunter", "warrior_name": "Tusk warrior", "trader_name": "Tusk trader", "sells": "wood", "wants": "stone", "knows": ["fire", "tools", "hide"], "desc": "Forest hunters who wear boar tusks at the throat. Proud, and quick to fight over hunting grounds."},
	{"id": "elk", "name": "Elk Clan", "chief": "Sela", "epithet": "the Antlered Mother", "culture": "spiritual",
		"color": Color("#9a7ac8"), "pos": Vector2(5700, 700), "base": 15.0, "start": 10.0, "pop": 9, "era": 1,
		"strength": 0.8, "hunter_name": "Elk hunter", "warrior_name": "Elk warrior", "trader_name": "Elk trader", "sells": "food", "wants": "stone", "knows": ["fire", "hide", "totems"], "desc": "Herders of the northern meadows who follow the elk. Gentle, generous, and wary of strangers with spears."},
	{"id": "hawk", "name": "Hawk Clan", "chief": "Varo", "epithet": "Sharp-Eye", "culture": "martial",
		"color": Color("#c8a030"), "pos": Vector2(5600, 3800), "base": -5.0, "start": 0.0, "pop": 12, "era": 2,
		"strength": 1.0, "hunter_name": "Hawk hunter", "warrior_name": "Hawk warrior", "trader_name": "Hawk trader", "sells": "stone", "wants": "wood", "knows": ["fire", "tools", "pottery", "domestication"], "desc": "Hill people who watch the plains from their high camp. They trade hard and fight harder."},
	{"id": "willow", "name": "Willow Clan", "chief": "Nao", "epithet": "Who Weaves", "culture": "spiritual",
		"color": Color("#5aa070"), "pos": Vector2(700, 3900), "base": 5.0, "start": 0.0, "pop": 8, "era": 1,
		"strength": 0.75, "hunter_name": "Willow hunter", "warrior_name": "Willow warrior", "trader_name": "Willow trader", "sells": "wood", "wants": "food", "knows": ["fire", "pottery", "farming"], "desc": "Basket-weavers of the southern marshes who grow wild grain. Few, patient, and fond of gifts."},
]
## More clans a random map can draw from (with the six above).
const EXTRA_CLANS := [
	{"id": "bear", "name": "Bear Clan", "chief": "Brak", "epithet": "the Unbowed", "culture": "martial",
		"color": Color("#6a4a3a"), "pos": Vector2.ZERO, "base": -15.0, "start": -10.0, "pop": 10, "era": 2,
		"strength": 1.15, "hunter_name": "Bear hunter", "warrior_name": "Bear warrior", "trader_name": "Bear trader", "sells": "stone", "wants": "food", "knows": ["fire", "tools", "hide"], "desc": "Cave dwellers who wear the skins of the great bears they hunt. Stubborn, and they never back down."},
	{"id": "otter", "name": "Otter Clan", "chief": "Lio", "epithet": "Who Swims Upstream", "culture": "spiritual",
		"color": Color("#4aa0a0"), "pos": Vector2.ZERO, "base": 10.0, "start": 5.0, "pop": 8, "era": 1,
		"strength": 0.8, "hunter_name": "Otter hunter", "warrior_name": "Otter warrior", "trader_name": "Otter trader", "sells": "food", "wants": "wood", "knows": ["fire", "pottery"], "desc": "Fisher folk of the lakes and streams. Playful and curious, they welcome anyone who comes in peace."},
	{"id": "raven", "name": "Raven Clan", "chief": "Morra", "epithet": "the Far-Seeing", "culture": "spiritual",
		"color": Color("#5a5478"), "pos": Vector2.ZERO, "base": 0.0, "start": -5.0, "pop": 9, "era": 2,
		"strength": 0.9, "hunter_name": "Raven hunter", "warrior_name": "Raven warrior", "trader_name": "Raven trader", "sells": "food", "wants": "stone", "knows": ["fire", "totems", "hide"], "desc": "Followers of a seer who reads the flight of birds. Secretive; they trade in omens as much as goods."},
	{"id": "lynx", "name": "Lynx Clan", "chief": "Tok", "epithet": "Stone-Hand", "culture": "martial",
		"color": Color("#c87a50"), "pos": Vector2.ZERO, "base": -10.0, "start": -5.0, "pop": 11, "era": 2,
		"strength": 1.05, "hunter_name": "Lynx hunter", "warrior_name": "Lynx warrior", "trader_name": "Lynx trader", "sells": "stone", "wants": "wood", "knows": ["fire", "tools", "domestication"], "desc": "Silent stalkers of the high woods. They strike from cover and vanish before the cry goes up."},
]
const RIVAL_TERRITORY := 520.0 # gathering or building this close to a clan's village angers them

## Points of interest hidden in the fog. Found when first seen by a tribesperson.
## reward: stock deltas; reveal: extra radius revealed on discovery; den: spawns prowling tigers.
const CLASSIC_LANDMARKS := [
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

static func river_x(y: float) -> float:
	return RIVER_BASE_X + RIVER_AMP * sin((y - RIVER_PHASE) / RIVER_PERIOD)

static func is_ford(y: float) -> bool:
	return y > FORD_Y0 and y < FORD_Y1

static func in_river(p: Vector2) -> bool:
	return absf(p.x - river_x(p.y)) < RIVER_HALF

static func is_water(p: Vector2) -> bool:
	return in_river(p) and not is_ford(p.y)

static func bank_of(p: Vector2) -> String:
	return "west" if p.x < river_x(p.y) else "east"

const SKILLS := ["forage", "craft", "combat", "lore"]
const SKILL_NAMES := {
	"forage": "Foraging & Hunting",
	"craft": "Crafting & Building",
	"combat": "Combat & Leadership",
	"lore": "Shamanism & Lore",
}
const SKILL_UNLOCKS := {
	"forage": "Beast Taming",
	"craft": "Megalithic & Bronze Craft",
	"combat": "Centurion Aura",
	"lore": "Totem Miracles",
}

# Natural finds: foods, medicines and ores scattered over the map. Each kind is unknown (and
# can't be gathered) until a villager who can recognise it comes near one.
#   res      what a load becomes in the stores ("herbs", "copper", "tin" are their own stocks)
#   rate     work speed vs. berries (1.0); needs: "" | "lore" (Lore 1+ to recognise) | "tools"
#   regrow   per second (0 = a seam that runs out); winter: still yields in winter
#   where    world-gen placement; count = clusters
#   act      activity text; practice = evolution activity it counts as
const FINDS := {
	"mushroom": {"name": "Forest Mushrooms", "group": "food", "res": "food", "amount": 18, "rate": 1.0, "regrow": 0.06, "winter": false,
		"where": "forest", "count": 6, "act": "Gathering mushrooms", "practice": "berry",
		"desc": "Food from the forest floor - but a bad one poisons the gatherer until the tribe learns which are safe (or a Lore 2+ gatherer picks)."},
	"tubers": {"name": "Wild Tubers", "group": "food", "res": "food", "amount": 30, "rate": 0.7, "regrow": 0.05, "winter": true,
		"where": "meadow", "count": 5, "act": "Digging tubers", "practice": "berry",
		"desc": "Slow to dig, but they keep in the ground: food even in winter."},
	"grain": {"name": "Wild Grain", "group": "food", "res": "food", "amount": 26, "rate": 0.9, "regrow": 0.08, "winter": false,
		"where": "meadow", "count": 4, "act": "Cutting wild grain", "practice": "berry", "practice_x": 2.0,
		"desc": "Seed-heads of wild grass. Gathering them teaches farming twice as fast."},
	"honey": {"name": "Wild Honey", "group": "food", "res": "food", "amount": 24, "rate": 0.8, "regrow": 0.05, "winter": false, "cluster": 1,
		"where": "forest_edge", "count": 4, "act": "Taking honey", "practice": "hunt",
		"desc": "Sweet food that lifts the spirit (+devotion). The bees sting - unless Friction Fire is known to smoke them out."},
	"fish": {"name": "Fish Shoal", "group": "food", "res": "food", "amount": 24, "rate": 1.2, "regrow": 0.14, "winter": false,
		"where": "river", "count": 6, "act": "Fishing", "practice": "hunt",
		"desc": "Fish in the river shallows: plenty and quick to return - but none while the river is iced over in winter."},
	"willow": {"name": "Willow Bark", "group": "medicine", "res": "herbs", "amount": 14, "rate": 0.8, "regrow": 0.04, "winter": true, "needs": "lore",
		"where": "riverbank", "count": 4, "act": "Stripping willow bark", "practice": "ritual",
		"desc": "Willow-bark tea breaks a fever: the sick recover 2.5x faster while the tribe has herbs."},
	"yarrow": {"name": "Yarrow", "group": "medicine", "res": "herbs", "amount": 14, "rate": 0.9, "regrow": 0.05, "winter": false, "needs": "lore",
		"where": "meadow", "count": 4, "act": "Picking yarrow", "practice": "ritual",
		"desc": "Yarrow staunches wounds: the hurt heal twice as fast at the village while the tribe has herbs."},
	"flint": {"name": "Flint", "group": "ore", "res": "stone", "amount": 30, "rate": 0.8, "regrow": 0.0, "winter": true,
		"where": "riverbank", "count": 3, "act": "Knapping flint", "practice": "chop",
		"desc": "Sharp stone that can be worked by hand (no tools needed). Finding it brings Polished Stone Tools much closer."},
	"copper": {"name": "Copper Ore", "group": "ore", "res": "copper", "amount": 40, "rate": 0.5, "regrow": 0.0, "winter": true, "needs": "tools",
		"where": "hills_west", "count": 3, "act": "Mining copper", "practice": "quarry",
		"desc": "Green-streaked rock. With tin, it makes bronze."},
	"tin": {"name": "Tin Ore", "group": "ore", "res": "tin", "amount": 30, "rate": 0.45, "regrow": 0.0, "winter": true, "needs": "tools",
		"where": "hills_east", "count": 2, "act": "Mining tin", "practice": "quarry",
		"desc": "Heavy dark stones, rare and far. Bronze cannot be made without it."},
	"ochre": {"name": "Red Ochre", "group": "ore", "res": "lore", "amount": 20, "rate": 0.7, "regrow": 0.0, "winter": true,
		"where": "meadow", "count": 2, "act": "Digging red ochre", "practice": "ritual",
		"desc": "Red earth for painting bodies, walls and the dead: each load is lore, and the tribe grows more spiritual."},
	"obsidian": {"name": "Obsidian", "group": "ore", "res": "stone", "amount": 20, "rate": 0.7, "regrow": 0.0, "winter": true,
		"where": "volcano", "count": 0, "act": "Gathering obsidian", "practice": "quarry",
		"desc": "Black glass left on the slopes of the Fire Mountain: blades of it cut deep (+15% ATK until bronze)."},
	"salt": {"name": "Salt Lick", "group": "ore", "res": "food", "amount": 25, "rate": 0.7, "regrow": 0.01, "winter": true,
		"where": "meadow", "count": 2, "act": "Scraping salt", "practice": "hearth",
		"desc": "Salt to cure meat: once found, the stores spoil half as fast."},
}
## Activity text of each find, for translation (kept as literal tr() keys).
const FIND_GROUPS := {"food": "Foods", "medicine": "Medicines", "ore": "Ores & earths"}

# wood = material cost, work = build points, cap = population capacity
const STRUCTURES := {
	"hut":          {"name": "Hut", "desc": "Houses 3 people. At night 3 sleep inside, warm and safe from wolves.", "wood": 15, "work": 30.0, "cap": 3, "r": 20.0},
	"large_hut":    {"name": "Large Hut", "desc": "Houses 5 people, and 5 can sleep inside at night.", "wood": 22, "work": 42.0, "cap": 5, "r": 26.0},
	"palisade":     {"name": "Wooden Palisade", "desc": "A ring of stakes: people inside it get +3 DEF. Floods can't wash it away.", "wood": 20, "work": 36.0, "r": 100.0, "ring": true},
	"fishing_dock": {"name": "Fishing Dock", "desc": "Steady food from the river (less in winter).", "wood": 14, "work": 26.0, "r": 16.0, "food": 0.12},
	"bonfire":      {"name": "Bonfire", "desc": "Warmth: nobody near it freezes, the sick heal faster, and those who don't fit in huts sleep around it. Lights up the land around it.", "wood": 8, "work": 12.0, "r": 12.0},
	"weapon_rack":  {"name": "Weapon Rack", "desc": "People near it fight with +20% ATK.", "wood": 10, "work": 16.0, "r": 12.0},
	"totem_shrine": {"name": "Totem Shrine", "desc": "A trickle of lore. Rituals near it give 50% more lore, and the sick nearby heal faster.", "wood": 18, "work": 30.0, "r": 14.0, "lore": 0.06},
	"farm_plot":    {"name": "Farm Plot", "desc": "Steady food from the field (none in winter, less in drought).", "wood": 12, "work": 24.0, "r": 28.0, "food": 0.1, "tech": "farming"},
	"granary":      {"name": "Granary", "desc": "Stores 100 more food (food over the stores' limit rots fast). Houses 4 people, and gatherers drop food here, so build it near the fields.", "wood": 30, "work": 40.0, "r": 20.0, "cap": 4, "tech": "pottery"},
	"grand_altar":  {"name": "Grand Altar", "desc": "Summons Yinglong the winged dragon to guard the village. Rituals and healing as a shrine. Needed for Victory by Wisdom.", "wood": 60, "stone": 20, "work": 80.0, "r": 24.0, "tech": "totems"},
	"aurochs_pen":  {"name": "Aurochs Pen", "desc": "Home to up to 2 pack oxen. Each ox eats food and needs tending, and lets one gatherer carry 50% more.", "wood": 25, "work": 30.0, "r": 30.0, "tech": "domestication"}, # keeps the herd (sim.oxen)
	"smelter":      {"name": "Bronze Smelter", "desc": "Arms the tribe in bronze (+60% ATK, +3 DEF) while it has copper and tin; it uses one of each per day.", "wood": 20, "stone": 20, "work": 45.0, "r": 16.0, "tech": "bronze"},
	"council_ring": {"name": "Council Ring", "desc": "A trickle of lore. Where the chiefs of the clans can meet: needed for Victory by Unity.", "wood": 15, "stone": 15, "work": 35.0, "r": 30.0, "lore": 0.05, "tech": "code"},
	# laid out by the tribe itself when the first of them dies (not in the build menu)
	"burial_ground": {"name": "Burial Ground", "desc": "Where the tribe lays its dead to rest.", "wood": 0, "work": 1.0, "r": 40.0},
}
## Homes and walls get a new look per era (style = era they were built or renovated in).
const STYLED := ["hut", "large_hut", "palisade", "granary"]
const CONTRACT_STRUCTURES := ["hut", "large_hut", "palisade", "fishing_dock", "bonfire", "weapon_rack", "totem_shrine", "farm_plot"]
const VILLAGE_BUILDS := ["hut", "palisade", "bonfire", "totem_shrine", "farm_plot", "granary", "aurochs_pen", "smelter", "council_ring", "grand_altar"]
const STRUCT_ALIASES := {
	"wooden_palisade": "palisade", "wall": "palisade", "walls": "palisade", "fence": "palisade",
	"dock": "fishing_dock", "fishing_pier": "fishing_dock", "pier": "fishing_dock",
	"big_hut": "large_hut", "longhouse": "large_hut", "grand_hut": "large_hut",
	"fire": "bonfire", "grand_bonfire": "bonfire", "campfire": "bonfire",
	"rack": "weapon_rack", "weapons_rack": "weapon_rack",
	"shrine": "totem_shrine", "totem": "totem_shrine",
	"farm": "farm_plot", "field": "farm_plot", "crop_plot": "farm_plot",
}

## Knowledge evolves two ways: by PRACTICE (people doing related work build up insight;
## "practice" maps activity -> weight) and by spending lore to finish the idea. "words"
## are things personas must not mention before the tech exists.
const INSIGHT_RATE := 0.06
const PRACTICE_NAMES := {"chop": "felling trees", "hunt": "hunting & butchering", "berry": "foraging berries", "build": "building",
	"ritual": "rituals", "quarry": "quarrying stone", "explore": "scouting", "hearth": "nights by the fire", "lead": "leading others"}
const TECHS := [
	{"id": "fire", "era": 1, "name": "Friction Fire", "cost": 15, "req": [], "practice": {"hearth": 1.0, "ritual": 0.5},
		"desc": "Torches light the night and homes get hearths. Bonfire warmth x2; cooked food 25% more nourishing.", "words": ["fire-drills", "torches"]},
	{"id": "tools", "era": 1, "name": "Polished Stone Tools", "cost": 20, "req": [], "practice": {"chop": 1.0, "hunt": 0.6},
		"desc": "+30% hunting & woodcutting, +2 ATK. Lets the tribe quarry stone from boulders.", "words": ["polished axes", "quarrying"]},
	{"id": "hide", "era": 1, "name": "Hide Tailoring", "cost": 20, "req": [], "practice": {"hunt": 1.0},
		"desc": "Fur cloaks: immune to night cold, +2 DEF.", "words": ["sewn furs", "needles"]},
	{"id": "pottery", "era": 2, "name": "Primitive Pottery", "cost": 35, "req": ["fire"], "practice": {"hearth": 0.6, "berry": 0.6},
		"desc": "Unlocks the Granary (+100 food storage, +4 pop cap). Food spoilage -50%.", "words": ["pots", "pottery", "clay jars", "granaries"]},
	{"id": "domestication", "era": 2, "name": "Beast Domestication", "cost": 40, "req": ["tools"], "practice": {"hunt": 0.8, "explore": 0.6},
		"desc": "Unlocks the Aurochs Pen, home to up to 2 pack oxen. Each ox lets one gatherer carry 50% more, but oxen eat food and must be tended.", "words": ["tamed beasts", "oxen", "pens", "riding"]},
	{"id": "farming", "era": 2, "name": "Slash-and-Burn Farming", "cost": 35, "req": ["fire"], "practice": {"berry": 1.0},
		"desc": "Unlocks Farm Plots for steady food.", "words": ["farms", "fields", "planting", "crops"]},
	{"id": "bronze", "era": 3, "name": "Bronze Metallurgy", "cost": 70, "req": ["tools", "domestication"], "finds": ["copper", "tin"], "practice": {"quarry": 1.0, "build": 0.3},
		"desc": "Unlocks the Bronze Smelter; while one stands with copper and tin to work, the tribe is armed in bronze (+60% ATK, +3 DEF).", "words": ["bronze", "metal", "smelting"]},
	{"id": "totems", "era": 3, "name": "Megalithic Totems", "cost": 70, "req": ["pottery"], "practice": {"ritual": 1.0},
		"desc": "Unlocks the Grand Altar (mythic guardian). Carved totems preserve all the tribe's knowledge.", "words": ["great totems", "altars", "megaliths"]},
	{"id": "code", "era": 3, "name": "Tribal Code", "cost": 60, "req": ["farming"], "practice": {"lead": 1.0, "build": 0.3},
		"desc": "+1 Vice-Chieftain slot and the Council Ring. Laws preserve all the tribe's knowledge.", "words": ["laws", "councils"]},
]
const ERA_NAMES := {1: "Stone & Fire Era", 2: "Tribe & Agrarian Era", 3: "Bronze & Mythic Era"}

# ---- Culture: four values that drift with what the tribe actually does ----
const CULTURE_AXES := {
	"martial": ["Martial", "Peaceful"], "spiritual": ["Spiritual", "Practical"],
	"settled": ["Settled", "Roaming"], "ranked": ["Ranked", "Communal"],
}
const TRADITION_THRESHOLD := 35.0
const TRADITIONS := [
	{"id": "warrior_initiation", "axis": "martial", "sign": 1, "name": "Warrior Initiation", "arch": "warrior",
		"desc": "Youths prove themselves on the hunt: +2 ATK for everyone, combat XP +25%."},
	{"id": "peaceful_ways", "axis": "martial", "sign": -1, "name": "Peaceful Ways", "arch": "agrarian",
		"desc": "The tribe sheds no needless blood: +20% gathering speed."},
	{"id": "ancestor_rites", "axis": "spiritual", "sign": 1, "name": "Ancestor Rites", "arch": "mystic",
		"desc": "Nightly rites for the ancestors: rituals give +30% lore and devotion."},
	{"id": "makers_pride", "axis": "spiritual", "sign": -1, "name": "Makers' Pride", "arch": "cautious",
		"desc": "Skill is honored above omens: +20% building speed."},
	{"id": "harvest_festival", "axis": "settled", "sign": 1, "name": "Harvest Festival", "arch": "agrarian",
		"desc": "The tribe feasts on what the land gives: farms, docks and pens yield +30%."},
	{"id": "wayfinders", "axis": "settled", "sign": -1, "name": "Wayfinders", "arch": "warrior",
		"desc": "Born to roam: +40 sight and +10% travel speed."},
	{"id": "council_of_elders", "axis": "ranked", "sign": 1, "name": "Council of Elders", "arch": "cautious",
		"desc": "Rank is respected: +1 Vice-Chieftain slot."},
	{"id": "shared_hearth", "axis": "ranked", "sign": -1, "name": "Shared Hearth", "arch": "lazy",
		"desc": "All eat from one pot: hunger drains 20% slower."},
]
## Which personality newborns lean toward as the culture develops.
const CULTURE_TRAIT := {"martial": "belligerent", "spiritual": "devout", "settled": "gluttonous", "ranked": "cautious"}

const TRAITS := {
	"cautious":    {"name": "Cautious & Pragmatic", "arch": "cautious", "desc": "Safety first. Builds walls before huts."},
	"belligerent": {"name": "Belligerent & Impulsive", "arch": "warrior", "desc": "Bold and loud. Never flees a fight."},
	"gluttonous":  {"name": "Gluttonous & Agrarian", "arch": "agrarian", "desc": "Food before all. Eats more."},
	"devout":      {"name": "Devout & Mystical", "arch": "mystic", "desc": "Reads omens. Performs rituals when idle."},
	"lazy":        {"name": "Slightly Lazy", "arch": "lazy", "desc": "Minimal effort, minimal plans. -10% work speed."},
}

const FOCUSES := ["balanced", "defense", "fishery", "fishery_and_defense", "farming", "hunting", "spiritual"]
const ACTIONS := ["gather_wood", "gather_food", "build", "ritual"]

# Memory text must start with a past-tense verb: it is spoken as "the day I <text>".
const CHARACTERS := [
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
	 "hp": 52, "atk": 4, "def": 3, "spd": 0.9, "skills": {"forage": 3, "craft": 1, "combat": 1, "lore": 0},
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

const BIRTH_NAMES := ["Ah-Lu", "Kesh", "Nuo", "Tala", "Rong", "Wei", "Hua", "Dao", "Lin", "Feng", "Ming", "Yu", "Zhen", "Ke", "Su", "Lan", "Bo", "Jin"]
const BIRTH_COLORS := ["#c9b07a", "#a6c47e", "#b98da8", "#8fb3c4", "#d69a6b", "#a3a3d1", "#c4a4a4"]
