## Static game data: map geometry, structures, techs, traits, starting tribe.
extends RefCounted

const W := 3600.0
const H := 2400.0
const DAY_LEN := 90.0 # seconds per in-game day at 1x

# ---- River & ford ----
const RIVER_BASE_X := 1960.0
const RIVER_AMP := 40.0
const RIVER_PERIOD := 170.0
const RIVER_HALF := 46.0
const FORD_Y0 := 1155.0
const FORD_Y1 := 1245.0
const FORD_Y := 1200.0

const VILLAGE := Vector2(1300, 1200)
const EAST_SITE := Vector2(2300, 1200)
## Offset used to place the original hand-made starting area inside the bigger map.
const HOME_OFS := Vector2(780, 640)

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
const RIVALS := [
	{"id": "ochre", "name": "Red Ochre Clan", "chief": "Gor", "epithet": "the Scarred", "culture": "martial",
		"color": Color("#c8452e"), "pos": Vector2(3180, 1300), "base": -25.0, "start": -20.0, "pop": 11, "era": 2,
		"strength": 1.2, "hunter_name": "Red Ochre hunter", "warrior_name": "Red Ochre warrior", "desc": "Hunters who paint themselves in red earth. They prize strength and take what they need."},
	{"id": "heron", "name": "Heron Clan", "chief": "Ama", "epithet": "Who Listens to Water", "culture": "spiritual",
		"color": Color("#3e8fc0"), "pos": Vector2(360, 2180), "base": 10.0, "start": 5.0, "pop": 9, "era": 1,
		"strength": 0.85, "hunter_name": "Heron hunter", "warrior_name": "Heron warrior", "desc": "River folk led by a seer. Slow to anger, but they never forget a wrong."},
]
const RIVAL_TERRITORY := 520.0 # gathering or building this close to a clan's village angers them

## Points of interest hidden in the fog. Found when first seen by a tribesperson.
## reward: stock deltas; reveal: extra radius revealed on discovery; den: spawns prowling tigers.
const LANDMARKS := [
	{"id": "cave", "insight": {"totems": 0.4}, "kind": "cave", "name": "Painted Cave", "pos": Vector2(420, 520), "reward": {"lore": 40},
		"text": "found the Painted Cave, where the ancestors drew the great hunt"},
	{"id": "stones", "insight": {"totems": 0.3, "code": 0.2}, "kind": "stones", "name": "Standing Stones", "pos": Vector2(620, 2020), "reward": {"lore": 30}, "devotion": 8.0,
		"text": "found the Standing Stones that hum when the moon is full"},
	{"id": "mammoth", "insight": {"hide": 0.5}, "kind": "bones", "name": "Mammoth Graveyard", "pos": Vector2(1180, 330), "reward": {"lore": 15, "wood": 25},
		"text": "found the Mammoth Graveyard and hauled home great tusks and ribs"},
	{"id": "flint", "insight": {"tools": 0.6, "bronze": 0.2}, "kind": "flint", "name": "Flint Outcrop", "pos": Vector2(260, 1640), "reward": {"wood": 40, "lore": 10},
		"text": "found a Flint Outcrop; the tribe's axes bite deeper now"},
	{"id": "grove", "insight": {"farming": 0.5}, "kind": "grove", "name": "Wild Berry Grove", "pos": Vector2(1050, 2080), "reward": {"food": 40},
		"text": "found a Wild Berry Grove heavy with fruit"},
	{"id": "peak", "insight": {"domestication": 0.4}, "kind": "peak", "name": "Eagle Peak", "pos": Vector2(2860, 300), "reward": {"lore": 20}, "reveal": 650.0,
		"text": "climbed Eagle Peak and saw the whole east bank spread below"},
	{"id": "spring", "insight": {"pottery": 0.4}, "kind": "spring", "name": "Hot Spring", "pos": Vector2(3050, 2120), "reward": {"food": 20, "lore": 15},
		"text": "found a steaming Hot Spring deep in the east"},
	{"id": "den_n", "insight": {"hide": 0.2}, "kind": "den", "name": "Saber-tooth Den", "pos": Vector2(3260, 760), "reward": {"lore": 10}, "den": 2,
		"text": "found a Saber-tooth Den littered with bones and lived to tell of it"},
	{"id": "den_s", "insight": {"hide": 0.2}, "kind": "den", "name": "Saber-tooth Den", "pos": Vector2(2620, 2180), "reward": {"lore": 10}, "den": 1,
		"text": "found a second Saber-tooth Den in the southern thickets"},
]

static func river_x(y: float) -> float:
	return RIVER_BASE_X + RIVER_AMP * sin(y / RIVER_PERIOD)

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

# wood = material cost, work = build points, cap = population capacity
const STRUCTURES := {
	"hut":          {"name": "Hut", "wood": 15, "work": 30.0, "cap": 3, "r": 20.0},
	"large_hut":    {"name": "Large Hut", "wood": 22, "work": 42.0, "cap": 5, "r": 26.0},
	"palisade":     {"name": "Wooden Palisade", "wood": 20, "work": 36.0, "r": 100.0, "ring": true},
	"fishing_dock": {"name": "Fishing Dock", "wood": 14, "work": 26.0, "r": 16.0, "food": 0.12},
	"bonfire":      {"name": "Bonfire", "wood": 8, "work": 12.0, "r": 12.0},
	"weapon_rack":  {"name": "Weapon Rack", "wood": 10, "work": 16.0, "r": 12.0},
	"totem_shrine": {"name": "Totem Shrine", "wood": 18, "work": 30.0, "r": 14.0, "lore": 0.06},
	"farm_plot":    {"name": "Farm Plot", "wood": 12, "work": 24.0, "r": 28.0, "food": 0.1, "tech": "farming"},
	"granary":      {"name": "Granary", "wood": 30, "work": 40.0, "r": 20.0, "cap": 4, "tech": "pottery"},
	"grand_altar":  {"name": "Grand Altar", "wood": 60, "stone": 20, "work": 80.0, "r": 24.0, "tech": "totems"},
	"aurochs_pen":  {"name": "Aurochs Pen", "wood": 25, "work": 30.0, "r": 30.0, "food": 0.05, "tech": "domestication"},
	"smelter":      {"name": "Bronze Smelter", "wood": 20, "stone": 20, "work": 45.0, "r": 16.0, "tech": "bronze"},
	"council_ring": {"name": "Council Ring", "wood": 15, "stone": 15, "work": 35.0, "r": 30.0, "lore": 0.05, "tech": "code"},
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
		"desc": "Unlocks the Granary (+4 pop cap). Food spoilage -50%.", "words": ["pots", "pottery", "clay jars", "granaries"]},
	{"id": "domestication", "era": 2, "name": "Beast Domestication", "cost": 40, "req": ["tools"], "practice": {"hunt": 0.8, "explore": 0.6},
		"desc": "Unlocks the Aurochs Pen. Pack oxen: +50% carry capacity.", "words": ["tamed beasts", "oxen", "pens", "riding"]},
	{"id": "farming", "era": 2, "name": "Slash-and-Burn Farming", "cost": 35, "req": ["fire"], "practice": {"berry": 1.0},
		"desc": "Unlocks Farm Plots for steady food.", "words": ["farms", "fields", "planting", "crops"]},
	{"id": "bronze", "era": 3, "name": "Bronze Metallurgy", "cost": 70, "req": ["tools", "domestication"], "practice": {"quarry": 1.0, "build": 0.3},
		"desc": "Unlocks the Bronze Smelter; once one stands, the tribe is armed in bronze (+60% ATK, +3 DEF).", "words": ["bronze", "metal", "smelting"]},
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
