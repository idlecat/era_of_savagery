## Plain data classes for simulated entities.
extends RefCounted

class Unit:
	var id: int
	var name: String
	var epithet: String
	var traits: Array = []
	var color: Color
	var pos: Vector2
	var home: Vector2
	var max_hp: float
	var hp: float
	var hunger: float = 80.0
	var atk: float
	var def: float
	var spd: float
	var skills: Dictionary = {} # skill -> {"lv": int, "xp": float}
	var arms: Dictionary = {} # weapon -> {"lv": int, "xp": float}: mastery (arms.gd)
	var knack: Dictionary = {} # weapon -> talent for it, fixed from birth (1.0 = ordinary)
	var wield: String = "" # the weapon they are told to carry ("" = their own choice)
	var memory: Array = [] # [{day, text, impact, t}]
	var job: Dictionary = {} # empty = idle
	var job_key: String = ""
	var path: Array = [] # Array[Vector2]
	var dest: Variant = null
	var carry_type: String = ""
	var carry_amt: int = 0
	var gather_t: float = 0.0
	var cd: float = 0.0
	var role: String = "" # "", "contract"
	var contract_id: int = -1
	var title: String = ""
	var last_hit_t: float = -99.0
	var attacker_id: int = -1
	var dead: bool = false
	var act: String = "Idle" # shown to the player (translated by I.act()); never compare it in logic
	var doing: String = "" # what the hands are busy with right now (chop, build, fight, ritual, dance...): logic, poses and sounds read this; update_unit clears it each tick
	var play: String = "" # a child's game (folk.play): chase, hunters, watch
	var xp_acc: float = 0.0
	var xp_flush_t: float = 0.0
	var wander_t: float = 0.0
	var wander_to: Variant = null
	var idle_t: float = 0.0
	var job_t: float = 0.0 # when the current job was given (night orders keep people up)
	var sleeping: bool = false
	var bed_id: int = -1 # the hut someone sleeps in tonight (-1 = by a fire or in the open)
	var bed_pos: Variant = null
	var fell_t: float = 0.0 # when they died
	var buried: bool = false
	var death_cause: String = "" # how they fell (already translated)
	var carrier_id: int = -1 # who is carrying the body to the burial ground
	var carry_kind: String = "" # node kind of the load being carried (mushroom, honey...)
	var herb_t: float = -1.0 # willow-bark tea working until
	var salve_t: float = -1.0 # yarrow poultice working until
	var walked: float = 0.0 # distance walked since the last meal tick (walking makes people hungry)
	var born_t: float = -9999.0 # (children)
	var parent_id: int = -1
	var watch_id: int = -1 # the grown-up a child is watching
	var ox: bool = false # leads one of the tribe's pack oxen while gathering (+50% load)
	var kills: int = 0
	var deeds: Dictionary = {} # deed -> count: the record rank trials are checked against (ranks.gd)
	var mentors: Dictionary = {} # skill -> ids of the leaders they worked under (ranks.learned_under)
	var career: String = "" # the trade they live by (careers.gd; "" = none, they do whatever is asked)
	var calling: Dictionary = {} # career id -> points from the work they have done (careers.gd)
	var resume_job: Dictionary = {}
	var resume_key: String = ""
	var resume_t: float = 0.0
	var hero: bool = false
	var sick: float = 0.0 # 1 = just fell ill, 0 = healthy
	var immune_t: float = 0.0
	# everyday life (life.gd, config/life.json); each person stands for one family line
	var morale: float = 60.0 # spirits, 0..100
	var fatigue: float = 0.0 # weariness, 0..100 (sleep clears it)
	var bonds: Dictionary = {} # other person's id -> -100..100 (friends above, rivals below)
	var company: int = 0 # friends (+) or rivals (-) working nearby, this second
	var grief: float = 0.0
	var mourn_id: int = -1 # whose grave they visit
	var cheer: float = 0.0 # lift from their own deeds, fading
	var low_t: float = 0.0 # seconds in despair (the family may want to leave)
	var meal_slot: int = -1 # the last meal time they were called to (day * 10 + meal)
	var wake_until: float = -1.0
	var face: Variant = null # where they look while standing (the fire, the one they talk to)
	var say: String = "" # a speech mark over their head (already translated)
	var say_kind: String = "" # the situation it came from (life.gd "talk"): picks the bubble icon
	var say_until: float = -1.0
	var say_t: float = 0.0 # when they may speak again
	var gone: bool = false # left the tribe (also dead + buried: out of every count)

	func lv(skill: String) -> int:
		return skills[skill]["lv"]

	func has_trait(t: String) -> bool:
		return traits.has(t)

class Predator:
	var id: int
	var spotted: bool = false # a lookout tower has called it out
	var name: String = "saber-toothed tiger"
	var pos: Vector2
	var hp: float = 70.0
	var max_hp: float = 70.0
	var atk: float = 8.0
	var def: float = 3.0
	var spd: float = 70.0
	var cd: float = 0.0
	var path: Array = []
	var goal: Variant = null
	var dead: bool = false
	var fled: bool = false
	var fleeing: bool = false
	var prowl_t: float = 0.0
	var den: Variant = null # home lair (prowls around it)
	var kind: String = "tiger" # "tiger", "wolf", "warrior" (rival war band) or "hunter" (rival, peaceful)
	var clan: String = "" # rival clan id for warriors and hunters
	var loot: bool = false # a raider carrying stolen food home
	var homeward: bool = false # a clan member routing back to its village
	var guard: bool = false # defending its own village against our war party
	var arrived: bool = false # a trader who has reached our village
	var raid: bool = false # a den tiger out hunting in the village
	var raid_t: float = 0.0
	var prey_id: int = -1 # the person it is going for (-1: nobody)
	var struck_t: float = -100.0 # sim time of its last blow (hunt.gd: a band waits less while it mauls someone)

class ResNode:
	var id: int
	var kind: String # tree, stump, bush, deer, carcass
	var res: String # wood, food
	var pos: Vector2
	var amount: float
	var max_amount: float
	var regrow: float = 0.0
	var regrow_t: float = 0.0
	var vel: Vector2 = Vector2.ZERO
	var wander_t: float = 0.0
	var bank: int = -1 # the stretch of land (D.region_at) a deer keeps to
	var from_deer: bool = false
	var sz: float = 1.0

class Structure:
	var id: int
	var type: String
	var pos: Vector2
	var built: bool = false
	var progress: float = 0.0
	var work: float = 1.0
	var paid: bool = false
	var owner: String = "village" # "village" or "contract:<id>"
	var style: int = 1 # era look (1 hide & branch, 2 mud & thatch, 3 timber & stone)
	var reno: bool = false # being renovated to the current era's style
	var reno_progress: float = 0.0
	var upgrade: String = "" # being rebuilt into this structure type (with reno = true)
	var size: float = 0.0 # a wall's chosen radius (0 = the type's own r)
	var cells: Array = [] # road works: [[wear cell, road level]...] in building order (roads.gd)
	var decor: int = 0 # painted decorations, 0..3
	var graves: Array = [] # burial ground: [{name, day, lost, pos}]

class Guardian:
	var id: int
	var name: String = "Yinglong"
	var pos: Vector2
	var hp: float = 400.0
	var max_hp: float = 400.0
	var cd: float = 0.0
	var path: Array = []
	var dead: bool = false
	var t: float = 0.0

class Contract:
	var id: int
	var plan: Dictionary # the confirmed JSON blueprint
	var leader_id: int
	var crew_ids: Array = []
	var reinforcement_ids: Array = []
	var resting_ids: Array = []
	var site: Vector2
	var directive: String
	var status: String = "assembling" # assembling, executing, interrupted, defending, sheltering, done, abandoned, failed
	var steps: Array = [] # runtime copies of blueprint steps
	var step_idx: int = 0
	var wood: float = 0.0 # timber the crew has gathered for its buildings
	var stone: float = 0.0 # stone a research crew has quarried for its experiments (used up by them)
	var struct_ids: Array = []
	var slot_idx: int = 0
	var progress: float = 0.0
	var ambushed: bool = false
	var abort_reason: String = ""
	var abort_cooldowns: Dictionary = {}
	var interruptions: int = 0
	var llm_calls: int = 0
	var t: float = 0.0
	var state_t: float = 0.0
	var clear_t: float = 0.0
	var events: Array = []
	var substate: String = ""
	var kind: String = "settle" # "settle" (a frontier outpost), "research" (seek new wisdom) or "war" (raid a rival clan)
	var flags: Dictionary = {} # war: blessed, scouted, spoils
	var forecast: Dictionary = {} # the odds read at sealing (contracts.forecast): {risk, pct, reasons, words}
	var said: Dictionary = {} # field-log triggers already spoken (contract_log.json), and the clocks behind them
