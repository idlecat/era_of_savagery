## Music, ambience and sound effects. Presentation only: it listens to the sim's signals
## and looks at its state, never changes it. Every sound is a recipe in config/audio.json,
## rendered by synth.gd on a worker thread at startup; what plays when is data too.
##
## Buses: Music, SFX, Ambience (all into Master), volumes in user://settings.cfg [audio].
## For a game master or a scenario: the story action {"sound": id} (sim.sound_cue), or
## play(id, at).
extends Node

const Synth = preload("res://scripts/synth.gd")
const D = preload("res://scripts/data.gd")
const WorldView = preload("res://scripts/world_view.gd")
const SETTINGS := "user://settings.cfg"
const BUSES := ["Music", "SFX", "Ambience"]
const CACHE := "user://sound_cache" # rendered recipes, named by a hash of the recipe

var C: Dictionary = preload("res://scripts/config.gd").load_cfg("audio")
var sim
var world
var blocked: Callable # true while a dialog is open (set by main): a dialog's pause keeps the sound going
var _paused := false # the player paused the game: every sound holds still
var vol := {} # master/music/sfx/ambience, 0-1
var muted := false # every sound off (the Sound dialog), remembered in settings.cfg
var _ready_ids := {} # recipe id -> AudioStreamWAV, filled by the worker
var _mutex := Mutex.new()
var _task := -1
var _pool: Array = [] # AudioStreamPlayer (music and global sfx)
var _pool2d: Array = [] # AudioStreamPlayer2D (sounds in the world)
var _amb: Array = [] # [{def, player}]
var _job_next := {} # unit/predator id -> time of its next work sound
var _rand_next: Array = []
var _clock := 0.0
var _state_t := 0.0
var _state := {}
# music
var _mood: Dictionary = {}
var _step := 0
var _step_t := 0.0
var _degree := 5
var _drone: AudioStreamPlayer

func _ready() -> void:
	_buses()
	_load_volumes()
	_task = WorkerThreadPool.add_task(_render_all)
	for i in 14:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_pool.append(p)
	_drone = AudioStreamPlayer.new()
	_drone.bus = "Music"
	_drone.volume_db = -80
	add_child(_drone)
	get_tree().node_added.connect(_on_node_added)

func _exit_tree() -> void:
	if _task >= 0: WorkerThreadPool.wait_for_task_completion(_task)

## Short sounds first, so the first clicks and chops are there at once.
func _render_all() -> void:
	var recipes: Dictionary = C.get("sounds", {})
	var ids: Array = recipes.keys()
	ids.sort_custom(func(a, b): return float(recipes[a].get("dur", 0.5)) < float(recipes[b].get("dur", 0.5)))
	DirAccess.make_dir_recursive_absolute(CACHE)
	for id in ids:
		var path := "%s/%s_%d.res" % [CACHE, id, hash(JSON.stringify(recipes[id])) & 0x7fffffff]
		var w: AudioStreamWAV = ResourceLoader.load(path) if FileAccess.file_exists(path) else null
		if w == null:
			w = Synth.render(recipes[id])
			ResourceSaver.save(w, path)
		_mutex.lock()
		_ready_ids[id] = w
		_mutex.unlock()

func stream(id: String) -> AudioStreamWAV:
	_mutex.lock()
	var w = _ready_ids.get(id)
	_mutex.unlock()
	return w

## Hook the sim and the world in (main.gd, once the game is made).
func setup(s, w) -> void:
	sim = s
	world = w
	sim.log_added.connect(_on_log)
	sim.alert_raised.connect(func(a): _cue(C.get("on_alert", {}).get(a.get("level", ""), ""), a.get("pos", Vector2.INF)))
	sim.happened.connect(func(id): _cue(C.get("on_happening", {}).get(id, "")))
	sim.sound_cue.connect(func(id, at): _cue(id, at))
	for sig in C.get("on_signal", {}):
		if sim.has_signal(sig):
			var argc := 0
			for sg in sim.get_signal_list():
				if sg["name"] == sig: argc = sg["args"].size()
			sim.connect(sig, _cue.bind(str(C["on_signal"][sig])).unbind(argc))
	for a in C.get("ambience", []):
		var p: Node = AudioStreamPlayer2D.new() if a.has("near") else AudioStreamPlayer.new()
		p.bus = "Ambience"
		p.volume_db = -80
		if p is AudioStreamPlayer2D:
			p.max_distance = float(a.get("range", 600)) * 2.0
			p.attenuation = 1.5
			world.add_child(p)
		else: add_child(p)
		_amb.append({"def": a, "player": p, "level": 0.0})
	for r in C.get("random", []): _rand_next.append(_clock + _range(r.get("every", [5, 10])))

func _on_log() -> void:
	if sim.log_lines.is_empty(): return
	_cue(C.get("on_log", {}).get(sim.log_lines[0]["kind"], ""))

func _on_node_added(n: Node) -> void:
	if n is BaseButton and C.has("ui_click"):
		n.pressed.connect(func(): play(C["ui_click"], Vector2.INF, 1.0, randf_range(0.95, 1.05), "SFX", true))

## The player's pause (not a dialog's): everything playing holds still, nothing new starts.
func paused() -> bool:
	return sim != null and sim.paused and not (blocked.is_valid() and blocked.call())

func _hold(on: bool) -> void:
	_paused = on
	for p in _pool + _pool2d + [_drone] + _amb.map(func(a): return a["player"]):
		if on and p.playing: p.stream_paused = true
		elif not on and p.stream_paused: p.stream_paused = false

func _cue(id: String, at := Vector2.INF) -> void:
	if id != "": play(id, at)

## Play sound `id` (at a world point, or everywhere with Vector2.INF). While paused only
## the interface's own sounds (ui) play.
func play(id: String, at := Vector2.INF, gain := 1.0, pitch := 1.0, bus := "SFX", ui := false) -> void:
	if _paused and not ui: return
	var w := stream(id)
	if w == null: return
	var p
	if at != Vector2.INF and world:
		p = _free(_pool2d)
		if p == null:
			if _pool2d.size() >= 16: return
			p = AudioStreamPlayer2D.new()
			p.max_distance = 1400.0
			p.attenuation = 1.2
			world.add_child(p)
			_pool2d.append(p)
		p.position = WorldView.iso(at)
	else:
		p = _free(_pool)
		if p == null: return
	p.bus = bus
	p.stream = w
	p.pitch_scale = clampf(pitch, 0.25, 4.0)
	p.volume_db = linear_to_db(maxf(0.0001, gain))
	p.stream_paused = false
	p.play()

func _free(pool: Array):
	for p in pool:
		if not p.playing and not p.stream_paused: return p
	for p in pool: # (a sound held by the pause that never finished: reuse it)
		if not p.playing: return p
	return null

func _range(v) -> float:
	if v is Array: return randf_range(float(v[0]), float(v[1]))
	return float(v)

# ------------------------------------------------------------ volumes
func _buses() -> void:
	for b in BUSES:
		if AudioServer.get_bus_index(b) >= 0: continue
		AudioServer.add_bus()
		var i := AudioServer.bus_count - 1
		AudioServer.set_bus_name(i, b)
		AudioServer.set_bus_send(i, "Master")

func _load_volumes() -> void:
	vol = C.get("volume", {}).duplicate()
	var cf := ConfigFile.new()
	if cf.load(SETTINGS) == OK:
		for k in ["master", "music", "sfx", "ambience"]: vol[k] = float(cf.get_value("audio", k, vol.get(k, 0.7)))
		muted = bool(cf.get_value("audio", "muted", false))
	_apply_volumes()

## Set a volume (master, music, sfx or ambience; 0-1) and remember it.
func set_volume(k: String, v: float) -> void:
	vol[k] = clampf(v, 0.0, 1.0)
	_apply_volumes()
	var cf := ConfigFile.new()
	cf.load(SETTINGS)
	cf.set_value("audio", k, vol[k])
	cf.save(SETTINGS)

## Mute every sound (or not) and remember it.
func set_muted(on: bool) -> void:
	muted = on
	_apply_volumes()
	var cf := ConfigFile.new()
	cf.load(SETTINGS)
	cf.set_value("audio", "muted", on)
	cf.save(SETTINGS)

func _apply_volumes() -> void:
	var names := {"master": "Master", "music": "Music", "sfx": "SFX", "ambience": "Ambience"}
	for k in names:
		var i := AudioServer.get_bus_index(names[k])
		if i < 0: continue
		var v := float(vol.get(k, 0.7))
		AudioServer.set_bus_volume_db(i, linear_to_db(maxf(0.0001, v)))
		AudioServer.set_bus_mute(i, v <= 0.001 or (muted and k == "master"))

# ------------------------------------------------------------ what is going on
func _update_state() -> void:
	var danger: bool = sim.crisis.active() or sim.nat.alarm() or not sim.active_predators_near(D.VILLAGE, 700).is_empty() \
		or sim.living().any(func(u): return u.job.get("type", "") == "attack")
	_state = {"night": sim.night_amt > 0.5, "danger": danger, "festival": sim.folk.festival_on(), "paused": sim.paused,
		"weather": sim.hz.weather, "season": sim.hz.season()}

## Audio's own conditions (night, danger, festival, paused, weather, seasons) and any of
## scenario scripts (story.holds()).
func holds(w: Dictionary) -> bool:
	var rest := {}
	for k in w:
		match k:
			"night", "danger", "festival", "paused":
				if bool(w[k]) != bool(_state.get(k, false)): return false
			"weather":
				if not _state.get("weather", "clear") in w[k]: return false
			"seasons":
				if not _state.get("season", "") in w[k]: return false
			_: rest[k] = w[k]
	return rest.is_empty() or sim.story.holds(rest)

func _center() -> Vector2:
	return WorldView.uniso(world.cam.position) if world and world.cam else D.VILLAGE

func _process(delta: float) -> void:
	if sim == null: return
	if paused() != _paused: _hold(paused())
	if _paused: return # (music, ambience and the world's sounds wait for the game)
	_clock += delta
	_state_t -= delta
	if _state_t <= 0:
		_state_t = 1.0
		_update_state()
	_music(delta)
	_ambience(delta)
	if not sim.paused:
		_jobs()
		_random()

# ------------------------------------------------------------ ambience
func _ambience(delta: float) -> void:
	var c := _center()
	for a in _amb:
		var def: Dictionary = a["def"]
		var p = a["player"]
		var target := float(def.get("vol", 0.5)) if holds(def.get("when", {})) else 0.0
		if def.has("near"):
			var at := _near(str(def["near"]), c)
			if at == Vector2.INF: target = 0.0
			else: p.position = WorldView.iso(at)
		a["level"] = move_toward(a["level"], target, delta * 0.4)
		if a["level"] <= 0.001:
			if p.playing: p.stop()
			continue
		if not p.playing:
			var w := stream(str(def["sound"]))
			if w == null: continue
			p.stream = w
			p.play(randf() * w.get_length())
		p.volume_db = linear_to_db(a["level"])

func _near(what: String, c: Vector2) -> Vector2:
	if what == "river":
		if D.RIVERS.is_empty(): return Vector2.INF
		return D.nearest_river_point(c)
	var best := Vector2.INF
	for s in sim.structures:
		if s.built and sim.ours(s) and s.type == what and s.pos.distance_to(c) < best.distance_to(c): best = s.pos
	return best

func _random() -> void:
	var list: Array = C.get("random", [])
	for i in mini(list.size(), _rand_next.size()):
		if _clock < _rand_next[i]: continue
		var r: Dictionary = list[i]
		_rand_next[i] = _clock + _range(r.get("every", [5, 10]))
		if not holds(r.get("when", {})): continue
		var sp := float(r.get("spread", 400))
		play(str(r["sound"]), _center() + Vector2(randf_range(-sp, sp), randf_range(-sp, sp)), float(r.get("vol", 0.5)), _range(r.get("pitch", 1.0)), "Ambience")

# ------------------------------------------------------------ people at work
func _jobs() -> void:
	var J: Dictionary = C.get("jobs", {})
	var c := _center()
	var reach := float(J.get("range", 650))
	var near: Array = []
	for u in sim.units:
		if u.dead or sim.in_hut(u) or u.pos.distance_to(c) > reach: continue
		for j in J.get("list", []):
			if u.doing == j["doing"]:
				near.append([u.pos.distance_to(c), u, j])
				break
	var bj: Dictionary = J.get("beasts", {})
	if not bj.is_empty():
		for p in sim.predators:
			if p.clan == "" and not p.dead and p.pos.distance_to(c) < reach and sim.is_explored(p.pos):
				near.append([p.pos.distance_to(c), p, bj])
	near.sort_custom(func(a, b): return a[0] < b[0])
	for e in near.slice(0, int(J.get("max_voices", 6))):
		var who = e[1]
		var j: Dictionary = e[2]
		var key := "%d" % who.id
		if not _job_next.has(key): _job_next[key] = _clock + _range(j.get("every", 1.0)) * randf()
		if _clock < _job_next[key]: continue
		_job_next[key] = _clock + _range(j.get("every", 1.0)) / maxf(0.5, sim.speed)
		play(str(j["sound"]), who.pos, float(j.get("vol", 0.8)), float(j.get("pitch", 1.0)) * randf_range(0.92, 1.08))

# ------------------------------------------------------------ music
## The first mood whose conditions hold sets the beat; it changes on the bar.
func _pick_mood() -> Dictionary:
	for m in C.get("music", {}).get("moods", []):
		if holds(m.get("when", {})): return m
	return {}

func _music(delta: float) -> void:
	var M: Dictionary = C.get("music", {})
	if M.is_empty(): return
	var steps := int(M.get("steps", 16))
	if _mood.is_empty(): _mood = _pick_mood()
	if _mood.is_empty(): return
	# the drone follows the mood
	var dl := float(_mood.get("drone", 0.0))
	if not _drone.playing and dl > 0.0:
		var w := stream("drone")
		if w:
			_drone.stream = w
			_drone.play()
	var cur := db_to_linear(_drone.volume_db) if _drone.playing else 0.0
	cur = move_toward(cur, dl, delta / maxf(0.1, float(M.get("fade", 2.0))))
	_drone.volume_db = linear_to_db(maxf(0.0001, cur))
	_drone.pitch_scale = pow(2.0, float(_mood.get("root", 0)) / 12.0)
	# the beat: sixteenths
	_step_t -= delta
	if _step_t > 0: return
	_step_t += 60.0 / float(_mood.get("bpm", 80)) / 4.0
	if _step_t < 0: _step_t = 0.0
	if _step == 0:
		var m := _pick_mood()
		if not m.is_empty(): _mood = m
	for drum in _mood.get("drums", {}):
		var pat: String = _mood["drums"][drum]
		if _step < pat.length() and pat[_step] == "x":
			play(drum, Vector2.INF, (1.0 if _step % 4 == 0 else 0.75) * randf_range(0.9, 1.0), randf_range(0.98, 1.02), "Music")
	var fl: Dictionary = _mood.get("flute", {})
	if not fl.is_empty() and _step % 2 == 0 and randf() < float(fl.get("density", 0.3)):
		var sc: Array = _mood.get("scale", [0, 2, 4, 7, 9])
		var leap := int(fl.get("leap", 2))
		_degree = clampi(_degree + randi_range(-leap, leap), 0, sc.size() * 2 - 1)
		if _degree == sc.size() * 2 - 1 or _degree == 0: _degree = sc.size() # (drift back to the middle)
		var semis: int = int(_mood.get("root", 0)) + int(sc[_degree % sc.size()]) + 12 * (_degree / sc.size() - 1 + int(fl.get("octave", 0)))
		play("flute", Vector2.INF, randf_range(0.7, 0.9), pow(2.0, semis / 12.0), "Music")
	_step = (_step + 1) % steps
