## Where the time goes: a stand-in for the editor's debugger. It runs the game (or tools/perf.gd)
## with --remote-debug, switches on the engine's script profiler around the measured stretch and
## prints the functions by self time (per tick or per frame, with their calls), and the cost of
## each script. The engine times every GDScript call while the profiler is on, so code that makes
## many small calls looks a little dearer than it is: read the call counts with the times.
## $GODOT --headless --path . --script res://tools/profile.gd -- --pops=200,500 [--secs=10] [--top=40] [--min-calls=1]
##   (the tick by population: the same game as tools/perf.gd)
## $GODOT --headless --path . --script res://tools/profile.gd -- --game [--warmup=5] [--secs=10] [--top=40] -- [--demo=town --people=600 --shot=/tmp/x.png --delay=40]
##   (the whole game, drawn in a window, with the game's own arguments after --; once its frames
##   are steady, --warmup seconds pass, then --secs seconds are profiled: per frame)
extends SceneTree
const PORT := 6011
var a := {} # the profiler's own options (before --game --)
var gargs: Array = [] # the game's arguments (after --)
var game := false
var server := TCPServer.new()
var peer: StreamPeerTCP = null
var tid := -1
var child := 0
var sigs := {} # signature id -> name (the engine sends each once a profiling stretch)
var born := 0 # msec, when the game connected
var steady_at := 0 # msec, when the game's frames first ran steady (its opening scenes done)
var quick_since := 0 # msec, when the last quick second of frames was reported
var started := 0 # msec, when the game was told to profile
var stopping := false
var frames := 0 # frames the game reported while profiling
var frame_ms := 0.0
var done := {} # the profile of the current stretch
var reported := 0
var ticks_total := 0
var finished := false
var seen := {} # (--verbose) the kinds of message seen

func _initialize() -> void:
	var mine := true
	for s in OS.get_cmdline_user_args():
		if s == "--game":
			game = true
			continue
		if s == "--":
			mine = false
			continue
		if not mine:
			gargs.append(s)
			continue
		var kv := s.trim_prefix("--").split("=", true, 1)
		if not a.has(kv[0]): a[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var port := int(a.get("port", PORT))
	server.listen(port, "127.0.0.1")
	var args: Array = ["--path", ProjectSettings.globalize_path("res://"), "--remote-debug", "tcp://127.0.0.1:%d" % port]
	if game:
		args += ["--"]
		args.append_array(gargs)
	else:
		args += ["--headless", "--script", "res://tools/perf.gd", "--", "--profile"]
		for k in a:
			if k in ["port", "top", "min-calls", "verbose"]: continue
			args.append("--%s=%s" % [k, a[k]])
		ticks_total = str(a.get("pops", "50,200,500")).split(",").size()
	child = OS.create_process(OS.get_executable_path(), args)

func _process(delta: float) -> bool:
	if finished: return true
	if peer == null:
		if server.is_connection_available(): peer = server.take_connection()
		elif Time.get_ticks_msec() > 180000 or not OS.is_process_running(child):
			print("The game did not connect to the profiler (is another one running on port %d?)" % int(a.get("port", PORT)))
			finished = true
			return true
		else:
			OS.delay_msec(2)
			return false
	_pump()
	var now := Time.get_ticks_msec()
	if game and tid >= 0 and reported == 0 and steady_at > 0:
		if started == 0 and now - steady_at >= int(float(a.get("warmup", 5.0)) * 1000.0):
			started = now
			_note("profiling from %.1f s" % (now / 1000.0))
			_send("profiler:servers", [true, [16384, false]])
		elif started > 0 and not stopping and now - started >= int(float(a.get("secs", 10.0)) * 1000.0):
			stopping = true
			_send("profiler:servers", [false, []])
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or (not game and reported >= ticks_total and not OS.is_process_running(child)):
		if reported < (1 if game else ticks_total): print("The game ended before its profile arrived (reported %d)." % reported)
		if OS.is_process_running(child): OS.kill(child)
		finished = true
		return true
	OS.delay_msec(1)
	return false

func _note(s: String) -> void:
	if a.has("verbose"): print("profiler: " + s)

func _pump() -> void:
	peer.poll()
	if born == 0: born = Time.get_ticks_msec()
	while peer.get_status() == StreamPeerTCP.STATUS_CONNECTED and peer.get_available_bytes() >= 4:
		var v = peer.get_var(false)
		if not (v is Array) or v.size() != 3: break
		_on_msg(str(v[0]), int(v[1]), v[2])

func _send(cmd: String, data: Array) -> void:
	peer.put_var([cmd, tid, data])

func _on_msg(cmd: String, thread: int, data: Variant) -> void:
	if tid < 0 and thread != 0: tid = thread
	if a.has("verbose") and not seen.has(cmd):
		seen[cmd] = true
		_note("msg %s: %s" % [cmd, str(data).left(160)])
	match cmd:
		"debug_enter": # a script error stopped the game: let it run on
			print("  (the game stopped on a script error: %s)" % str(data[1]))
			_send("continue", [])
		"performance:profile_frame": # once a second: [fps, ...]: the game's frames are steady after two quick seconds in a row
			if float(data[1]) < 0.4:
				if quick_since > 0 and Time.get_ticks_msec() - quick_since < 3000 and steady_at == 0:
					steady_at = Time.get_ticks_msec()
					_note("frames steady at %.1f s" % (steady_at / 1000.0))
				quick_since = Time.get_ticks_msec()
			else:
				quick_since = 0
		"servers:function_signature":
			sigs[int(data[1])] = str(data[0])
		"servers:profile_frame":
			frames += 1
			frame_ms += float(data[1]) * 1000.0
		"servers:profile_total":
			_gather(data)
			if game: _report(0, frames, frame_ms / maxf(1.0, frames))
		"eos:meta":
			_report(int(data[0]), int(data[1]), float(data[2]))
			_send("eos:ack", [])

## profile_total: [frame, frame_time, process, physics, physics_frame, script_time, 0, n*5, (sig, calls, self, total, internal)*n]
func _gather(arr: Array) -> void:
	var out: Array = []
	var n: int = int(arr[7]) / 5
	for i in n:
		var o := 8 + i * 5
		out.append({"name": sigs.get(int(arr[o]), "~%d" % int(arr[o])), "calls": int(arr[o + 1]), "self": float(arr[o + 2]) * 1000.0, "total": float(arr[o + 3]) * 1000.0})
	done = {"funcs": out, "script_ms": float(arr[5]) * 1000.0}

## The table: functions by self time, then the scripts.
func _report(pop: int, ticks: int, ms: float) -> void:
	reported += 1
	var funcs: Array = done.get("funcs", [])
	var unit := "frame" if game else "tick"
	var n := maxi(1, frames if game else ticks)
	var top := int(a.get("top", 40))
	var min_calls := float(a.get("min-calls", 0.5)) * float(n)
	var script_ms: float = done.get("script_ms", 0.0) / n
	var head := "the whole game" if game else "pop %d" % pop
	if game:
		print("\n== %s: %.1f ms a frame over %d frames (%.1f fps); %.2f ms of it in script ==" % [head, frame_ms / maxf(1, frames), frames, frames * 1000.0 / maxf(1.0, frame_ms), script_ms])
	else:
		print("\n== %s: %.2f ms a tick over %d ticks; %.2f ms of it in script ==" % [head, ms, n, script_ms])
	var by_self: Array = funcs.duplicate()
	by_self.sort_custom(func(x, y): return x["self"] > y["self"])
	var sum := 0.0
	for f in funcs: sum += f["self"]
	var row := "  %9.3f  %9.3f  %9.1f  %5.1f%%  %s"
	print("  %9s  %9s  %9s  %5s  %s" % ["self ms", "total ms", "calls", "share", "function, per " + unit])
	var shown := 0
	for f in by_self:
		if shown >= top and f["calls"] < min_calls: continue
		if shown >= top * 4: break
		shown += 1
		print(row % [f["self"] / n, f["total"] / n, f["calls"] / float(n), 100.0 * f["self"] / maxf(sum, 0.001), f["name"]])
	var files := {}
	for f in funcs:
		var file: String = f["name"].get_slice("::", 0)
		if not files.has(file): files[file] = {"name": file, "self": 0.0, "total": 0.0, "calls": 0}
		files[file]["self"] += f["self"]
		files[file]["total"] += f["total"]
		files[file]["calls"] += f["calls"]
	var rows: Array = files.values()
	rows.sort_custom(func(x, y): return x["self"] > y["self"])
	print("  --- by script (self time: its own code and the engine calls it makes; total: with the scripts it calls) ---")
	for r in rows:
		if r["self"] / n < 0.01 and r["total"] / n < 0.02: continue
		print(row % [r["self"] / n, r["total"] / n, r["calls"] / float(n), 100.0 * r["self"] / maxf(sum, 0.001), r["name"]])
	done = {}
	sigs.clear()
	frames = 0
	frame_ms = 0.0
