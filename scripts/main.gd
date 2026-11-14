## Entry point: wires the deterministic sim (60 FPS layer), the renderer/input,
## the HUD, and the async LLM node client.
extends Node2D

const Sim = preload("res://scripts/sim.gd")
const WorldView = preload("res://scripts/world_view.gd")
const HUD = preload("res://scripts/hud.gd")
const LLM = preload("res://scripts/llm_client.gd")

const STEP := 0.05

var sim
var world
var hud
var llm

func _ready() -> void:
	randomize()
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
