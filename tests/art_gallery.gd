## Contact sheet of baked sprites, for iterating on the 3D models without rebaking the
## whole cache: godot --path . --script res://tests/art_gallery.gd -- --out=/path.png
##   [--keys=man_walk_1_0,deer_idle_1_0,...] [--match=pine_] [--scale=1.0] [--cols=8]
extends SceneTree

const ArtBaker = preload("res://scripts/art_baker.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var art = ArtBaker.new()
	root.add_child(art)
	art._setup()
	var want: PackedStringArray = args.get("keys", "").split(",", false)
	var pat: String = args.get("match", "")
	var jobs: Array = []
	for j in art._jobs():
		if j["key"] in want or (pat != "" and j["key"].match(pat)): jobs.append(j)
	if want.size() > 0: # keep the requested order
		jobs.sort_custom(func(a, b): return want.find(a["key"]) < want.find(b["key"]))
	for j in jobs: await art._bake(j)
	var sc := float(args.get("scale", "1.0"))
	var cols := int(args.get("cols", "8"))
	var cell := 0
	for j in jobs:
		if art.sprites.has(j["key"]):
			var im: Image = art.sprites[j["key"]]["img"]
			cell = maxi(cell, maxi(im.get_width(), im.get_height()))
	cell = int(cell * sc) + 8
	var rows := ceili(float(jobs.size()) / cols)
	var sheet := Image.create(cell * mini(cols, jobs.size()), cell * rows, false, Image.FORMAT_RGBA8)
	sheet.fill(Color("#6f7d4a"))
	var i := 0
	for j in jobs:
		if not art.sprites.has(j["key"]): continue
		var im: Image = art.sprites[j["key"]]["img"].duplicate()
		if sc != 1.0: im.resize(int(im.get_width() * sc), int(im.get_height() * sc), Image.INTERPOLATE_LANCZOS)
		var o := Vector2i((i % cols) * cell + (cell - im.get_width()) / 2, (i / cols) * cell + (cell - im.get_height()) / 2)
		sheet.blend_rect(im, Rect2i(Vector2i.ZERO, im.get_size()), o)
		i += 1
	sheet.save_png(args.get("out", "user://gallery.png"))
	print("gallery: %d sprites" % i)
	quit()
