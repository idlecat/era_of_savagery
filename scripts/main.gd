## Entry point: wires the deterministic sim (60 FPS layer), the renderer/input,
## the HUD, and the async LLM node client.
extends Node2D

const Sim = preload("res://scripts/sim.gd")
const WorldView = preload("res://scripts/world_view.gd")
const HUD = preload("res://scripts/hud.gd")
const LLM = preload("res://scripts/llm_client.gd")
const I = preload("res://scripts/i18n.gd")
const ArtBaker = preload("res://scripts/art_baker.gd")
const D = preload("res://scripts/data.gd")
const MapGen = preload("res://scripts/mapgen.gd")
const Scenarios = preload("res://scripts/scenarios.gd")
const Cultures = preload("res://scripts/cultures.gd")
const NewGameUI = preload("res://scripts/new_game_ui.gd")
const Audio = preload("res://scripts/audio.gd")
const SaveGame = preload("res://scripts/save_game.gd")
var SAVE_CFG: Dictionary = preload("res://scripts/config.gd").load_cfg("save")

## A save to load when the scene restarts (static: survives reload_current_scene).
static var pending_load := ""

const STEP := 0.05
const NIGHT_FF := 12.0 # game-speed multiplier while the whole tribe sleeps

var sim
var world
var hud
var llm
var art
var audio
var settings := {} # what this world was made from (saved with the game)
var autosave_day := 0
var ready_done := false

func _ready() -> void:
	randomize()
	var lang := I.load_pref()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--lang="): lang = arg.trim_prefix("--lang=")
	I.setup(lang)
	get_window().title = tr("Era of Savagery · Clan Chronicles")
	audio = Audio.new() # (renders its sounds while the art bakes)
	add_child(audio)
	art = ArtBaker.new()
	add_child(art)
	var loading := _loading_screen()
	art.progress.connect(func(d, n): loading.get_child(0).text = tr("Forging the world… %d%%  (first launch only)") % (100 * d / n))
	await art.prepare()
	loading.queue_free()
	var data := {}
	if pending_load != "":
		data = SaveGame.read(pending_load)
		pending_load = ""
	if data.is_empty(): settings = await _new_game_settings()
	if settings.has("load"):
		data = SaveGame.read(settings["load"])
		settings = data.get("settings", {"map": Scenarios.DEFAULT, "tribes": 0, "seed": 0, "culture": Scenarios.culture_of(Scenarios.DEFAULT)})
	if not data.is_empty(): settings = data["settings"]
	Cultures.apply(settings.get("culture", "")) # before the map: a random tribe takes the culture's names
	if MapGen.SIZES.has(settings["map"]): # a random map
		MapGen.generate(settings["map"], settings["tribes"], settings["seed"], str(settings.get("land", "random" if not settings.has("load") else "parkland")))
		seed(settings["seed"]) # forests, herds and finds grow the same way for the same seed
	else: # a scenario
		Scenarios.apply(settings["map"])
	loading = _loading_screen()
	await get_tree().process_frame # let "Forging the world…" show while the land is built
	await get_tree().process_frame
	sim = Sim.new()
	sim.new_game()
	if not data.is_empty():
		SaveGame.decode_into(sim, data["sim"])
		sim.paused = true
	autosave_day = sim.day()
	randomize()
	llm = LLM.new()
	llm.sim = sim
	add_child(llm)
	world = WorldView.new()
	add_child(world)
	world.art = art
	world.setup(sim)
	hud = HUD.new()
	add_child(hud)
	hud.audio = audio
	hud.game = self
	hud.setup(sim, world, llm)
	audio.setup(sim, world)
	audio.blocked = hud.modal_open
	if not data.is_empty():
		var ex: Dictionary = data.get("extra", {})
		if ex.get("cam") is Vector2: world.cam.position = ex["cam"]
		if ex.has("zoom"): world.cam.zoom = Vector2.ONE * float(ex["zoom"])
		hud.after_load()
	world.blocked = hud.modal_open
	loading.queue_free()
	ready_done = true

## Map choice: from the command line (--map=<scenario id>|small|standard|large|huge
## [--tribes=N] [--seed=S]; "classic" = the default scenario), the default scenario for
## scripted screenshots, otherwise the New Game screen.
func _new_game_settings() -> Dictionary:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if args.get("demo", "") == "newgame": # debug: screenshot the New Game screen
		var shot_ui := NewGameUI.new()
		add_child(shot_ui)
		if args.has("lang"): I.setup(args["lang"])
		await get_tree().create_timer(float(args.get("delay", "1"))).timeout
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(args["shot"])
		get_tree().quit()
		return {"map": Scenarios.DEFAULT, "tribes": 6, "seed": 0, "culture": Cultures.DEFAULT}
	if args.has("map") or args.has("shot"):
		var m: String = args.get("map", Scenarios.DEFAULT)
		if m == "classic": m = Scenarios.DEFAULT
		if not MapGen.SIZES.has(m) and Scenarios.by_id(m) == null: m = "standard"
		var tribes := int(args.get("tribes", str(MapGen.SIZES[m]["def"]) if MapGen.SIZES.has(m) else "0"))
		var cu: String = args.get("culture", Scenarios.culture_of(m))
		return {"map": m, "tribes": tribes, "seed": int(args.get("seed", str(randi() % 1000000))), "culture": "" if cu == "none" else cu, "land": args.get("land", "random")}
	var ui := NewGameUI.new()
	add_child(ui)
	var s: Dictionary = await ui.chosen
	ui.queue_free()
	return s

func _loading_screen() -> CanvasLayer:
	var cl := CanvasLayer.new()
	var l := Label.new()
	l.text = tr("Forging the world…")
	l.set_anchors_preset(Control.PRESET_CENTER)
	l.add_theme_font_size_override("font_size", 26)
	cl.add_child(l)
	add_child(cl)
	return cl

func _process(delta: float) -> void:
	if not ready_done: return
	_autosave()
	if sim.paused or hud.modal_open(): return
	# A quiet night with the whole tribe asleep passes quickly; any alarm drops back to normal speed.
	var ff: bool = sim.night_ff()
	var dt: float = minf(delta, 0.1) * (maxf(sim.speed, NIGHT_FF) if ff else sim.speed) * sim.crisis.slow() # (emergency mode: slow motion)
	var n := ceili(dt / STEP)
	for i in n:
		sim.tick(dt / n)
		if sim.paused: break # an abort condition or event fired mid-frame
		if ff and not sim.night_ff(): break

func _unhandled_key_input(ev: InputEvent) -> void:
	var k := ev as InputEventKey
	if k == null or not k.pressed or k.echo or not ready_done: return
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
		KEY_P:
			if not hud.modal_open(): hud.open_council()
		KEY_T:
			if not hud.modal_open(): hud._open_tech()
		KEY_ESCAPE:
			world.build_type = ""
			world.select_only(null)
		KEY_C:
			if not hud.modal_open(): hud._start_contract_for_selected()
		KEY_X:
			if not hud.modal_open(): world.scout_selected()
		KEY_F5:
			if not hud.modal_open():
				var err := save_to(str(SAVE_CFG.get("quick_slot", "quicksave")))
				hud.toast(tr("Quick save") if err == "" else tr(err))
		KEY_F9:
			if not hud.modal_open():
				var err := load_from(str(SAVE_CFG.get("quick_slot", "quicksave")))
				if err != "": hud.toast(tr(err))

# ------------------------------------------------------------ saving
## Why the game can't be saved right now ("" = it can): an open decision would be lost.
func save_block() -> String:
	if sim.pending_event != "" or sim.contracts.list.any(func(c): return c.status == "interrupted"):
		return "Decide the open question first."
	return ""

func save_to(slot: String) -> String:
	var why := save_block()
	if why != "": return why
	return SaveGame.write(slot, sim, settings, {"cam": world.cam.position, "zoom": world.cam.zoom.x})

## Load a save: the scene restarts and builds that world.
func load_from(slot: String) -> String:
	if SaveGame.read(slot).is_empty(): return "That save can't be read."
	pending_load = slot
	get_tree().reload_current_scene()
	return ""

func autosave_on() -> bool:
	var cf := ConfigFile.new()
	if cf.load("user://settings.cfg") == OK: return bool(cf.get_value("save", "autosave", true))
	return true

func _autosave() -> void:
	if sim.day() < autosave_day + int(SAVE_CFG.get("autosave_days", 1)): return
	if hud.modal_open() or save_block() != "" or not autosave_on(): return
	autosave_day = sim.day()
	var keep := maxi(1, int(SAVE_CFG.get("autosave_keep", 3)))
	var slot := "autosave%d" % (1 + (sim.day() / maxi(1, int(SAVE_CFG.get("autosave_days", 1)))) % keep)
	var err := SaveGame.write(slot, sim, settings, {"cam": world.cam.position, "zoom": world.cam.zoom.x})
	if err == "": hud.toast(tr("Autosaved (Day %d)") % sim.day())
	else: push_warning("autosave: " + err)

func toggle_fullscreen() -> void:
	var fs := DisplayServer.window_get_mode() in [DisplayServer.WINDOW_MODE_FULLSCREEN, DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN]
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED if fs else DisplayServer.WINDOW_MODE_FULLSCREEN)

# ------------------------------------------------------------ debug: automated screenshots
# godot --path . -- --shot=/tmp/x.png --delay=3 --demo=sheet|negotiate|emergency|life --fast=60 [--place=hut --at=x,y]
func _enter_tree() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if args.has("shot"): _debug_shot.call_deferred(args)

func _debug_shot(args: Dictionary) -> void:
	await get_tree().process_frame
	while not ready_done: await get_tree().process_frame
	hud.feat_popups = args.get("demo", "") == "feat" # (achievement dialogs would cover the scenes)
	hud.feat_queue.clear()
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
			for f in sim.D.FINDS: sim.known_finds[f] = 1
			sim.stock["copper"] = 50
			sim.stock["tin"] = 50
			var order := ["fire", "tools", "hide", "pottery", "domestication", "farming", "bronze", "totems", "code"]
			for id in order.slice(0, {1: 3, 2: 6, 3: 9}[stage]): sim.research(id)
			sim.pending_event = ""
			sim.paused = false
			var V: Vector2 = sim.D.VILLAGE
			if stage >= 2:
				for spec in [["aurochs_pen", Vector2(-230, 60)], ["farm_plot", Vector2(-200, -120)], ["granary", Vector2(170, 150)]]:
					var st = sim.place_structure(spec[0], V + spec[1])
					if st: sim.complete_structure(st, null)
			if stage >= 3:
				for spec in [["smelter", Vector2(200, -60)], ["council_ring", Vector2(20, 190)]]:
					var st = sim.place_structure(spec[0], V + spec[1])
					if st: sim.complete_structure(st, null)
			if args.has("sites"): # unfinished buildings at each construction stage
				var k := 0
				for spec in [["hut", 0.0, false], ["hut", 0.1, true], ["large_hut", 0.35, true], ["granary", 0.8, true], ["smelter", 0.6, true], ["grand_altar", 0.3, true]]:
					var st = sim.add_structure(spec[0], V + Vector2(-260 + (k % 3) * 220, 260 + (k / 3) * 200), false, "village", spec[2])
					st.progress = st.work * spec[1]
					k += 1
			if stage >= 2:
				var fd: Dictionary = sim.D.FORDS[0]
				var dock: Vector2 = sim.D.shore(fd["p"] - fd["t"] * 80.0 + fd["n"] * 10.0, -6.0)
				sim.add_structure("fishing_dock", dock, true)
			sim.renovate([])
			for st in sim.structures:
				if st.reno: sim._finish_reno(st, sim.units[0])
			for i in int(float(args.get("secs", "60")) / STEP):
				sim.tick(STEP)
				if sim.paused:
					sim.pending_event = ""
					sim.paused = false
			if args.has("night"): sim.time = floor(sim.time / 90.0) * 90.0 + 75.0
			if args.has("dusk"): sim.time = floor(sim.time / 90.0) * 90.0 + 60.0
			hud._close_modal()
			world.selected = []
			world.selection_changed.emit()
			world.cam.zoom = Vector2(float(args.get("zoom", "1.3")), float(args.get("zoom", "1.3")))
			world.focus_on(V + Vector2(float(args.get("fx", "0")), float(args.get("fy", "30"))))
			if args.has("tech"): hud._open_tech()
			if args.has("ability"):
				sim.appoint(sim.unit_by_name("Panshi"), "steward") # (shows the marks)
				sim.assign_explore(sim.unit_by_name("Yan"))
				world.select_only(null)
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
				if w.kind == "wolf": w.pos = sim.D.VILLAGE + Vector2(randf_range(-260, -160), randf_range(80, 160))
			sim.unit_by_name("Alie").sick = 1.0
			sim.hz.snow = 1.0
			for i in int(3 / STEP): sim.tick(STEP)
			world.cam.zoom = Vector2(1.2, 1.2)
			world.focus_on(sim.D.VILLAGE + Vector2(-60, 60))
		"clans": # debug: a rival village, met, with a war band setting out (--clan=ochre|heron, --event shows first contact)
			hud._close_modal()
			var cid: String = args.get("clan", "ochre")
			var rc: Dictionary = sim.rivals.clans[cid]
			sim.hz.level = "normal"
			sim.fog_enabled = false
			for i in int(2 / STEP): sim.tick(STEP)
			if not args.has("event"):
				for k in 3:
					if sim.pending_event != "": sim.resolve_event(sim.pending_event, 2)
					sim._check_events()
				hud._close_modal()
				rc["relation"] = -55.0
				rc["raid_t"] = 0.0
				for i in int(float(args.get("secs", "6")) / STEP):
					sim.tick(STEP)
				sim.paused = false
			world.cam.zoom = Vector2(float(args.get("zoom", "1.0")), float(args.get("zoom", "1.0")))
			world.focus_on(rc["pos"] + Vector2(float(args.get("fx", "0")), float(args.get("fy", "0"))))
		"parley": # debug: an envoy reaches a rival village (--clan, --who); --propose makes a first offer
			hud._close_modal()
			sim.fog_enabled = false
			var pid: String = args.get("clan", "heron")
			for id in sim.rivals.clans: sim.rivals.clans[id]["met"] = true
			sim.rivals.pending.clear()
			var envoy = sim.unit_by_name(args.get("who", "Linghe"))
			sim.rivals.send_envoy(envoy, pid)
			var waited := 0.0
			while envoy.job.get("type", "") == "envoy" and not envoy.job.get("parley", false) and waited < 300.0:
				sim.tick(STEP)
				waited += STEP
				if sim.pending_event != "":
					sim.resolve_event(sim.pending_event, 2)
					sim.paused = false
			world.cam.zoom = Vector2(1.1, 1.1)
			world.focus_on(sim.rivals.clans[pid]["pos"])
			if args.has("propose"): hud._par_propose()
		"war": # debug: a war party assaults a rival village (--clan, --who, --secs into the fight, --trader)
			hud._close_modal()
			sim.fog_enabled = false
			var wid: String = args.get("clan", "heron")
			for id in sim.rivals.clans: sim.rivals.clans[id]["met"] = true
			sim.rivals.pending.clear()
			var wl = sim.unit_by_name(args.get("who", "Alie"))
			var wterms := {"kind": "war", "target": wid, "objective": args.get("objective", "burn"), "crew_size": 5}
			var wctx: Dictionary = sim.contracts.negotiation_ctx(wl, "Raid", wterms, true, "", {}, [], "war")
			var wbp: Dictionary = sim.contracts.sanitize(hud.Persona.propose(wctx)["blueprint"], wterms, wl)["blueprint"]
			var wc = sim.contracts.create(wbp, wl, "Raid")
			var into := float(args.get("secs", "3"))
			var fight_t := -1.0
			var tt := 0.0
			while sim.contracts.is_running(wc) and tt < 400.0:
				sim.tick(STEP)
				tt += STEP
				if sim.paused:
					if sim.pending_event != "": sim.resolve_event(sim.pending_event, 2)
					if wc.status == "interrupted": sim.contracts.resolve(wc, "press_on")
					sim.paused = false
				if fight_t < 0 and wc.step_idx < wc.steps.size() and wc.steps[wc.step_idx]["action"] == "assault": fight_t = tt
				if fight_t >= 0 and tt - fight_t > into: break
			world.cam.zoom = Vector2(float(args.get("zoom", "1.3")), float(args.get("zoom", "1.3")))
			world.focus_on(sim.rivals.clans[wid]["pos"] + Vector2(0, 60))
		"ending": # debug: reach an ending (--path=conquest|unity|wisdom|defeat), or --panel for the Legacy panel
			hud._close_modal()
			var ep: String = args.get("path", "conquest")
			for id in sim.rivals.clans: sim.rivals.clans[id]["met"] = true
			sim.rivals.pending.clear()
			for i in int(20 / STEP): sim.tick(STEP)
			# a few deeds worth telling
			sim.remember(sim.unit_by_name("Alie"), "led the war party against the Red Ochre Clan on Day 9 (burned 2 of their huts)", 9)
			sim.remember(sim.unit_by_name("Linghe"), "sealed an agreement with the Heron Clan on Day 4: Peace for 20 days", 7)
			match ep:
				"conquest":
					for id in sim.rivals.clans: sim.rivals.clans[id]["vassal"] = 3
				"unity":
					for id in sim.rivals.clans: sim.rivals.clans[id]["treaties"]["alliance"] = {"until": sim.time + 3000.0, "tribute": 0}
					sim.add_structure("council_ring", sim.D.VILLAGE + Vector2(-200, 160), true)
				"wisdom":
					for t in sim.evo.D.TECHS: sim.techs[t["id"]] = true
					sim.add_structure("grand_altar", sim.D.VILLAGE + Vector2(-200, 160), true)
				"defeat":
					for o in sim.living(): sim.kill_unit(o, null)
			if args.has("panel"):
				sim.legacy.achieved.clear()
				hud._open_legacy()
			else:
				for i in int(1.5 / STEP): sim.tick(STEP)
		"nature": # debug: a force of nature, --what=fire|flood|eruption|ash|eclipse|storm
			hud._close_modal()
			sim.fog_enabled = false
			for p in sim.predators: p.fled = true
			for id in sim.rivals.clans: sim.rivals.clans[id]["met"] = true
			sim.rivals.pending.clear()
			sim.nat.quake_at = INF
			var what: String = args.get("what", "fire")
			var focus: Vector2 = sim.D.VILLAGE
			match what:
				"fire":
					var trees = sim.nodes.filter(func(n): return n.kind == "tree" and n.pos.distance_to(sim.D.VILLAGE) < 700)
					sim.nat.ignite(trees[0])
					focus = trees[0].pos
					for i in int(float(args.get("secs", "8")) / STEP): sim.tick(STEP)
				"flood":
					sim.nat.flood_day = sim.day()
					sim.nat.flood_at = sim.time + 0.1
					sim.nat.flood_warned = true
					for i in int(float(args.get("secs", "3")) / STEP): sim.tick(STEP)
					focus = sim.D.FORDS[0]["p"] if not sim.D.FORDS.is_empty() else sim.D.VILLAGE
				"eruption", "ash":
					sim.nat.erupt()
					var secs := float(args.get("secs", "3" if what == "eruption" else "20"))
					for i in int(secs / STEP): sim.tick(STEP)
					focus = sim.D.VOLCANO + Vector2(-150, 250) if what == "eruption" else sim.D.VILLAGE
				"eclipse":
					sim.time = 90.0 * 2 + 90.0 * 0.35
					sim.nat.eclipse_at = sim.time
					for i in int(float(args.get("secs", "8")) / STEP):
						sim.tick(STEP)
						if sim.paused: break
				"storm":
					sim.hz._start("storm")
					sim.nat.strikes.append({"pos": sim.D.VILLAGE + Vector2(150, -150), "t": 0.05})
			sim.paused = false
			sim.pending_event = sim.pending_event if what == "eclipse" else ""
			if what != "eclipse": hud._close_modal()
			world.cam.zoom = Vector2(float(args.get("zoom", "1.2")), float(args.get("zoom", "1.2")))
			world.focus_on(focus)
		"folk": # debug: village life, --what=festival|kids|trade
			hud._close_modal()
			sim.fog_enabled = false
			for p in sim.predators: p.fled = true
			for id in sim.rivals.clans:
				sim.rivals.clans[id]["met"] = true
				sim.rivals.clans[id]["relation"] = 25.0
			sim.rivals.pending.clear()
			sim.known_finds["ochre"] = 1
			for st in sim.structures:
				if st.type == "hut": st.decor = 1 + st.id % 3
			sim.stock["goods"] = 8
			sim.folk.treasures.append({"name": "Owl Figurine", "maker": "Panshi", "day": 1})
			var fw: String = args.get("what", "festival")
			if fw == "festival":
				sim.folk.season_seen = 999
				sim.folk.festivals = true
				for i in 4: sim.tick(STEP)
				sim.resolve_event("festival", 0)
				sim.paused = false
				hud._close_modal()
			for i in int(float(args.get("secs", "6")) / STEP): sim.tick(STEP)
			sim.pending_event = ""
			sim.paused = false
			hud._close_modal()
			world.cam.zoom = Vector2(float(args.get("zoom", "2.0")), float(args.get("zoom", "2.0")))
			world.focus_on(sim.D.VILLAGE)
			if fw == "trade": hud.open_trade("heron")
		"finds": # debug: look at the natural finds (all known, fog off), --kind=mushroom to centre on one
			hud._close_modal()
			sim.fog_enabled = false
			for id in sim.rivals.clans: sim.rivals.clans[id]["met"] = true
			sim.rivals.pending.clear()
			for f in sim.D.FINDS: sim.known_finds[f] = 1
			sim.stock["herbs"] = 6
			sim.stock["copper"] = 12
			sim.stock["tin"] = 4
			var fk: String = args.get("kind", "mushroom")
			var fn = sim.nodes.filter(func(n): return n.kind == fk)
			world.cam.zoom = Vector2(float(args.get("zoom", "1.6")), float(args.get("zoom", "1.6")))
			if not fn.is_empty(): world.focus_on(fn[0].pos)
			for i in int(1.0 / STEP): sim.tick(STEP)
			sim.pending_event = ""
			sim.paused = false
			hud._close_modal()
			if args.has("tech"):
				sim.known_finds.erase("tin")
				sim.known_finds.erase("salt")
				hud._open_tech()
		"night": # debug: the tribe asleep (--secs into the night; --burial: two buried first)
			hud._close_modal()
			sim.fog_enabled = false
			for p in sim.predators: p.fled = true
			for id in sim.rivals.clans: sim.rivals.clans[id]["met"] = true
			sim.rivals.pending.clear()
			if args.has("burial"):
				for nm in ["Bai", "Shan"]:
					var dd = sim.unit_by_name(nm)
					dd.pos = sim.D.VILLAGE + Vector2(150, 120)
					sim.kill_unit(dd, null)
				sim.kill_unit(sim.unit_by_name("Mo'er"), null)
				sim.unit_by_name("Mo'er").pos = sim.D.VILLAGE + Vector2(2100, 100)
				sim.time = 5.0
				var bt := 0.0
				while sim.living().size() > 0 and bt < 80 and not (sim.unit_by_name("Bai").buried and sim.unit_by_name("Shan").buried):
					sim.tick(STEP)
					bt += STEP
				sim.time += 90.0
				for i in int(1.5 / STEP): sim.tick(STEP)
			if not args.has("day"):
				sim.time = floorf(sim.time / 90.0) * 90.0 + 90.0 * 0.745
				for i in int(float(args.get("secs", "8")) / STEP): sim.tick(STEP)
			else:
				for i in int(float(args.get("secs", "6")) / STEP): sim.tick(STEP)
			sim.paused = false
			sim.pending_event = ""
			hud._close_modal()
			world.cam.zoom = Vector2(float(args.get("zoom", "1.1")), float(args.get("zoom", "1.1")))
			var bg = sim.burial_ground()
			world.focus_on(bg.pos.lerp(sim.D.VILLAGE, 0.5) if bg and args.has("burial") else sim.D.VILLAGE)
			if args.has("graves") and bg: hud.open_graves(bg)
		"achievements": # the Achievements panel with a few inventions and firsts
			hud._close_modal()
			for id in ["moss_dressing", "digging_stick", "baskets", "bone_flute"]: sim.inv.discover(id, sim.living()[randi() % 6])
			sim.discover_find("mushroom", sim.living()[0], sim.living()[0].pos)
			sim.evo.breakthrough("fire", sim.living()[1])
			for i in int(float(args.get("secs", "30")) / STEP): sim.tick(STEP)
			hud.open_achievements()
		"feat": # an achievement dialog: a culture invention (or the first base one) made in the village
			hud._close_modal()
			for i in int(float(args.get("secs", "6")) / STEP): sim.tick(STEP)
			var d: Dictionary = sim.cult.list("inventions")[0] if sim.cult.on() else sim.D.INVENTIONS[0]
			sim.inv.discover(d["id"], sim.living()[0])
		"heritage": # the culture's Heritage panel: a few things made, found, met and told
			hud._close_modal()
			var cu = sim.cult
			var who = sim.living()[0]
			for d in cu.list("inventions").slice(0, 2) + cu.list("foods").slice(0, 1): sim.inv.discover(d["id"], who)
			for f in cu.list("finds").slice(0, 1): sim.discover_find(f["id"], who, who.pos)
			for t in cu.list("tales").slice(0, 2): cu.tell(t["id"])
			for p in cu.list("people"):
				if p.get("as", "") == "wanderer": cu.join(p["id"])
			for e in cu.list("events").slice(0, 1): cu.fired[e["id"]] = sim.day()
			for i in int(float(args.get("secs", "4")) / STEP): sim.tick(STEP)
			sim.pending_event = ""
			hud._close_modal()
			hud.open_heritage()
		"life": # everyday life: --at=<day part> (0.35 the midday meal, 0.62 the evening meal, 0.2 idle acts), --secs to run on
			hud._close_modal()
			var at := float(args.get("at", "0.33"))
			while sim.day_frac() < at or sim.day() < 2:
				sim.tick(STEP)
				if sim.pending_event != "":
					sim.pending_event = ""
					sim.paused = false
			for i in int(float(args.get("secs", "8")) / STEP): sim.tick(STEP)
			sim.paused = false
			hud._close_modal()
			world.cam.zoom = Vector2(float(args.get("zoom", "1.6")), float(args.get("zoom", "1.6")))
			world.focus_on(sim.D.VILLAGE + Vector2(0, 30))
		"overview": # the whole land, no fog: rivers, fords, clans, landmarks
			hud._close_modal()
			sim.fog_enabled = false
			for lm in sim.landmarks: lm["found"] = true
			for id in sim.rivals.clans: sim.rivals.clans[id]["met"] = true
			var z: float = float(args.get("zoom", str(snappedf(minf(1600.0 / ((sim.D.W + sim.D.H) * 0.75), 900.0 / ((sim.D.W + sim.D.H) * 0.375)), 0.01))))
			world.cam.zoom = Vector2(z, z)
			world.focus_on(Vector2(sim.D.W, sim.D.H) / 2.0)
		"explore":
			hud._close_modal()
			for u in sim.living().filter(func(o): return o.role == "").slice(3, 6): sim.assign_explore(u)
			for i in int(float(args.get("secs", "240")) / STEP): sim.tick(STEP)
			sim.paused = false
			hud._close_modal()
			world.selected = []
			world.selection_changed.emit()
			world.cam.zoom = Vector2(0.42, 0.42)
			world.focus_on(sim.D.VILLAGE + Vector2(500, 0))
		"emergency":
			hud._close_modal()
			var u = sim.unit_by_name(args.get("who", "Panshi"))
			var ctx: Dictionary = sim.contracts.negotiation_ctx(u, "Found a new settlement on the frontier", {}, false)
			var san: Dictionary = sim.contracts.sanitize(hud.Persona.propose(ctx)["blueprint"], {}, u)
			var c = sim.contracts.create(san["blueprint"], u, "Found a new settlement on the frontier")
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
	if args.has("place"): # placing a building: its ghost at --at=x,y from the village (default 180,140)
		var off: PackedStringArray = str(args.get("at", "180,140")).split(",")
		var gp: Vector2 = sim.D.VILLAGE + (Vector2(float(off[0]), float(off[1])) if off.size() == 2 else Vector2(180, 140))
		world.build_type = args["place"]
		if args.has("zoom"): world.cam.zoom = Vector2(float(args["zoom"]), float(args["zoom"]))
		world.focus_on(gp)
		await get_tree().process_frame
		get_viewport().warp_mouse(world.get_viewport().get_canvas_transform() * world.iso(gp))
	if args.has("hover"): # put the mouse over the first structure of that type (adds one by the river if none)
		var hs = sim.structures.filter(func(st): return st.type == args["hover"])
		if hs.is_empty():
			var fd2: Dictionary = sim.D.FORDS[0]
			hs = [sim.add_structure(args["hover"], sim.D.shore(fd2["p"] + fd2["t"] * 100.0 + fd2["n"] * 10.0, 24.0), true)]
		world.focus_on(hs[0].pos)
		await get_tree().process_frame
		get_viewport().warp_mouse(world.get_viewport().get_canvas_transform() * world.iso(hs[0].pos))
	await get_tree().create_timer(float(args.get("delay", "2"))).timeout
	get_viewport().get_texture().get_image().save_png(args["shot"])
	get_tree().quit()
