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
	var act: String = "Idle"
	var xp_acc: float = 0.0
	var xp_flush_t: float = 0.0
	var wander_t: float = 0.0
	var wander_to: Variant = null
	var idle_t: float = 0.0
	var kills: int = 0
	var unlocked: Dictionary = {}
	var resume_job: Dictionary = {}
	var resume_key: String = ""
	var hero: bool = false

	func lv(skill: String) -> int:
		return skills[skill]["lv"]

	func has_trait(t: String) -> bool:
		return traits.has(t)

class Predator:
	var id: int
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
	var bank: String = ""
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
	var wood: float = 0.0
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
