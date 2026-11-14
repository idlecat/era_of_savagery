## Entry point: wires the deterministic sim (60 FPS layer), the renderer/input,
## the HUD, and the async LLM node client.
extends Node2D

const Sim = preload("res://scripts/sim.gd")
const WorldView = preload("res://scripts/world_view.gd")
const HUD = preload("res://scripts/hud.gd")
const LLM = preload("res://scripts/llm_client.gd")
const I = preload("res://scripts/i18n.gd")

const STEP := 0.05

var sim
var world
var hud
var llm

func _ready() -> void:
	randomize()
	var lang := I.load_pref()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--lang="): lang = arg.trim_prefix("--lang=")
	I.setup(lang)
	sim = Sim.new()
	sim.new_game()
	llm = LLM.new()
	llm.sim = sim
	add_child(llm)
	world = WorldView.new()
	add_child(world)
	world.setup(sim)
	hud = HUD.new()
	add_child(hud)
	hud.setup(sim, world, llm)
	world.blocked = hud.modal_open

func _process(delta: float) -> void:
	if sim.paused or hud.modal_open(): return
	var dt: float = minf(delta, 0.1) * sim.speed
	var n := ceili(dt / STEP)
	for i in n:
		sim.tick(dt / n)
		if sim.paused: break # an abort condition or event fired mid-frame

func _unhandled_key_input(ev: InputEvent) -> void:
	var k := ev as InputEventKey
	if k == null or not k.pressed or k.echo: return
	# Fullscreen toggle: F11, Alt+Enter, or the macOS standard Cmd+Ctrl+F
	if k.keycode == KEY_F11 or (k.keycode == KEY_ENTER and k.alt_pressed) or (k.keycode == KEY_F and k.meta_pressed and k.ctrl_pressed):
		toggle_fullscreen()
		get_viewport().set_input_as_handled()
		return
	match k.keycode:
		KEY_SPACE:
			if not hud.modal_open(): sim.paused = not sim.paused
		KEY_1: sim.speed = 1
		KEY_2: sim.speed = 2
		KEY_3, KEY_4: sim.speed = 4
		KEY_T:
			if not hud.modal_open(): hud._open_tech()
		KEY_ESCAPE:
			world.build_type = ""
			world.select_only(null)
		KEY_C:
			if not hud.modal_open(): hud._start_contract_for_selected()
		KEY_X:
			if not hud.modal_open(): world.scout_selected()

func toggle_fullscreen() -> void:
	var fs := DisplayServer.window_get_mode() in [DisplayServer.WINDOW_MODE_FULLSCREEN, DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN]
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED if fs else DisplayServer.WINDOW_MODE_FULLSCREEN)

# ------------------------------------------------------------ debug: automated screenshots
# godot --path . -- --shot=/tmp/x.png --delay=3 --demo=sheet|negotiate|emergency --fast=60
func _enter_tree() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if args.has("shot"): _debug_shot.call_deferred(args)

func _debug_shot(args: Dictionary) -> void:
	await get_tree().process_frame
	var fast := float(args.get("fast", "0"))
	if fast > 0:
		hud._close_modal()
		for i in int(fast / STEP): sim.tick(STEP)
	match args.get("demo", ""):
		"sheet":
			hud._close_modal()
			world.select_only(sim.unit_by_name("Panshi"))
		"negotiate":
			hud._close_modal()
			world.select_only(sim.unit_by_name(args.get("who", "Panshi")))
			hud._start_contract_for_selected()
		"evolve": # debug: fast-forward the tribe through the ages
			hud._close_modal()
			sim.fog_enabled = false
			var stage := int(args.get("era", "3"))
			sim.stock["lore"] = 2000
			sim.stock["wood"] = 2000
			sim.stock["stone"] = 500
			var order := ["fire", "tools", "hide", "pottery", "domestication", "farming", "bronze", "totems", "code"]
			for id in order.slice(0, {1: 3, 2: 6, 3: 9}[stage]): sim.research(id)
			sim.pending_event = ""
			sim.paused = false
			var V: Vector2 = sim.D.VILLAGE if false else Vector2(1300, 1200)
			if stage >= 2:
				for spec in [["aurochs_pen", Vector2(-230, 60)], ["farm_plot", Vector2(-200, -120)], ["granary", Vector2(170, 150)]]:
					var st = sim.place_structure(spec[0], V + spec[1])
					if st: sim.complete_structure(st, null)
			if stage >= 3:
				for spec in [["smelter", Vector2(200, -60)], ["council_ring", Vector2(20, 190)]]:
					var st = sim.place_structure(spec[0], V + spec[1])
					if st: sim.complete_structure(st, null)
			sim.renovate([])
			for st in sim.structures:
				if st.reno: sim._finish_reno(st, sim.units[0])
			for i in int(float(args.get("secs", "60")) / STEP):
				sim.tick(STEP)
				if sim.paused:
					sim.pending_event = ""
					sim.paused = false
			if args.has("night"): sim.time = floor(sim.time / 90.0) * 90.0 + 75.0
			hud._close_modal()
			world.selected = []
			world.selection_changed.emit()
			world.cam.zoom = Vector2(float(args.get("zoom", "1.3")), float(args.get("zoom", "1.3")))
			world.focus_on(V + Vector2(0, 30))
			if args.has("tech"): hud._open_tech()
			if args.has("ability"):
				hud.roster_mode = "ability"
				hud.sort_key = args["ability"]
				hud._refresh_left()
			if args.has("research"):
				world.select_only(sim.unit_by_name(args["research"]))
				hud.open_negotiation(sim.unit_by_name(args["research"]), "research")
		"winter": # debug: a hard winter night
			hud._close_modal()
			sim.fog_enabled = false
			for i in int(30 / STEP): sim.tick(STEP)
			sim.flags["flood"] = true
			sim.time = 90.0 * 6 + float(args.get("at", "60"))
			for i in int(float(args.get("secs", "20")) / STEP):
				sim.tick(STEP)
				if sim.paused:
					sim.pending_event = ""
					sim.paused = false
			sim.hz._start(args.get("weather", "blizzard"))
			sim.hz.spawn_wolf_pack()
			for w in sim.predators:
				if w.kind == "wolf": w.pos = Vector2(1300, 1200) + Vector2(randf_range(-260, -160), randf_range(80, 160))
			sim.unit_by_name("Alie").sick = 1.0
			sim.hz.snow = 1.0
			for i in int(3 / STEP): sim.tick(STEP)
			world.cam.zoom = Vector2(1.2, 1.2)
			world.focus_on(Vector2(1240, 1260))
		"explore":
			hud._close_modal()
			for nm in ["Bai", "Shan", "Mo'er"]: sim.assign_explore(sim.unit_by_name(nm))
			for i in int(float(args.get("secs", "240")) / STEP): sim.tick(STEP)
			sim.paused = false
			hud._close_modal()
			world.selected = []
			world.selection_changed.emit()
			world.cam.zoom = Vector2(0.42, 0.42)
			world.focus_on(Vector2(1800, 1200))
		"emergency":
			hud._close_modal()
			var u = sim.unit_by_name(args.get("who", "Panshi"))
			var ctx: Dictionary = sim.contracts.negotiation_ctx(u, "Establish a settlement across the river", {}, false)
			var san: Dictionary = sim.contracts.sanitize(hud.Persona.propose(ctx)["blueprint"], {}, u)
			var c = sim.contracts.create(san["blueprint"], u, "Establish a settlement across the river")
			var t := 0.0
			while c.status != "interrupted" and t < 400:
				sim.tick(STEP)
				t += STEP
			if args.has("finish"):
				while sim.contracts.is_running(c) and t < 900:
					if c.status == "interrupted":
						sim.contracts.resolve(c, sim.contracts.allowed_effects(c)[0])
						sim.paused = false
					sim.tick(STEP)
					t += STEP
				hud._close_modal()
				world.focus_on(c.site)
	await get_tree().create_timer(float(args.get("delay", "2"))).timeout
	get_viewport().get_texture().get_image().save_png(args["shot"])
	get_tree().quit()
