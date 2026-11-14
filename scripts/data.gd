## Static game data: map geometry, structures, techs, traits, starting tribe.
extends RefCounted

const W := 1920.0
const H := 1080.0
const DAY_LEN := 90.0 # seconds per in-game day at 1x

# ---- River & ford ----
const RIVER_BASE_X := 1180.0
const RIVER_AMP := 40.0
const RIVER_PERIOD := 170.0
const RIVER_HALF := 46.0
const FORD_Y0 := 495.0
const FORD_Y1 := 585.0
const FORD_Y := 540.0

const VILLAGE := Vector2(520, 560)
const EAST_SITE := Vector2(1520, 560)

const OVERPOP_THRESHOLD := 12 # PRD says 20; lowered so it fires in a short POC session
const FLOOD_DAY := 4

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
	"grand_altar":  {"name": "Grand Altar", "wood": 60, "work": 80.0, "r": 24.0, "tech": "totems"},
}
const CONTRACT_STRUCTURES := ["hut", "large_hut", "palisade", "fishing_dock", "bonfire", "weapon_rack", "totem_shrine", "farm_plot"]
const VILLAGE_BUILDS := ["hut", "palisade", "bonfire", "totem_shrine", "farm_plot", "granary", "grand_altar"]
const STRUCT_ALIASES := {
	"wooden_palisade": "palisade", "wall": "palisade", "walls": "palisade", "fence": "palisade",
	"dock": "fishing_dock", "fishing_pier": "fishing_dock", "pier": "fishing_dock",
	"big_hut": "large_hut", "longhouse": "large_hut", "grand_hut": "large_hut",
	"fire": "bonfire", "grand_bonfire": "bonfire", "campfire": "bonfire",
	"rack": "weapon_rack", "weapons_rack": "weapon_rack",
	"shrine": "totem_shrine", "totem": "totem_shrine",
	"farm": "farm_plot", "field": "farm_plot", "crop_plot": "farm_plot",
}

const TECHS := [
	{"id": "fire", "era": 1, "name": "Friction Fire", "cost": 15, "req": [], "desc": "Bonfire warmth radius x2. Cooked food is 25% more nourishing."},
	{"id": "tools", "era": 1, "name": "Polished Stone Tools", "cost": 20, "req": [], "desc": "+30% hunting & woodcutting speed. +2 ATK."},
	{"id": "hide", "era": 1, "name": "Hide Tailoring", "cost": 20, "req": [], "desc": "Immune to night cold. +2 DEF."},
	{"id": "pottery", "era": 2, "name": "Primitive Pottery", "cost": 35, "req": ["fire"], "desc": "Unlocks Granary (+4 pop cap). Food spoilage -50%."},
	{"id": "domestication", "era": 2, "name": "Beast Domestication", "cost": 40, "req": ["tools"], "desc": "Tamed aurochs haul loads: +50% carry capacity."},
	{"id": "farming", "era": 2, "name": "Slash-and-Burn Farming", "cost": 35, "req": ["fire"], "desc": "Unlocks Farm Plots for steady food."},
	{"id": "bronze", "era": 3, "name": "Bronze Metallurgy", "cost": 70, "req": ["tools", "domestication"], "desc": "+60% ATK, +3 DEF for all tribespeople."},
	{"id": "totems", "era": 3, "name": "Megalithic Totems", "cost": 70, "req": ["pottery"], "desc": "Unlocks the Grand Altar, which summons a mythic guardian beast."},
	{"id": "code", "era": 3, "name": "Tribal Code", "cost": 60, "req": ["farming"], "desc": "+1 Vice-Chieftain slot (War Chief)."},
]
const ERA_NAMES := {1: "Stone & Fire Era", 2: "Tribe & Agrarian Era", 3: "Bronze & Mythic Era"}

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
