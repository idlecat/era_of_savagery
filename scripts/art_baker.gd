## Pre-rendered sprite pipeline (how Age of Empires II was made: model in 3D, render
## to sprites). Low-poly models are built in code, lit by a sun with soft shadows and
## ambient occlusion, and rendered from the exact isometric angle the map uses. The
## sprites are cached in user://, so baking happens once per ART_VERSION.
##
## Camera maths: the map projects world (x, y) to screen ((x-y)*0.75, (x+y)*0.375). An
## orthographic camera yawed 45 deg and pitched 30 deg down gives the same 2:1 diamond at
## 1.0607 px per world unit; heights come out at 0.918 px per unit. Sprites are baked at
## 2x (BAKE_SCALE) and drawn at 0.5 so they stay crisp when zoomed in.
extends Node

signal progress(done: int, total: int)

const ART_VERSION := 5
const BAKE_SCALE := 2.0
const PPU := 1.06066 * BAKE_SCALE
const CACHE_DIR := "user://art_cache_v%d" % ART_VERSION
const DIRS := 8
const WALK_FRAMES := 8
const WORK_FRAMES := 4

var sprites := {} # key -> {"tex": Texture2D, "anchor": Vector2}  (anchor = ground point in sprite px)
var vp: SubViewport
var cam: Camera3D
var stage: Node3D
var catcher: MeshInstance3D
var noise := {}
var bake_shader: Shader

# ------------------------------------------------------------ public
func has(key: String) -> bool: return sprites.has(key)
func get_sprite(key: String) -> Dictionary: return sprites[key]

## Load cached sprites, or bake them (first launch / new ART_VERSION).
func prepare() -> void:
	if DisplayServer.get_name() == "headless": return
	if _load_cache(): return
	_setup()
	var jobs := _jobs()
	var vs: int = DisplayServer.window_get_vsync_mode()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var i := 0
	for job in jobs:
		await _bake(job)
		i += 1
		if i % 6 == 0: progress.emit(i, jobs.size())
	DisplayServer.window_set_vsync_mode(vs)
	_save_cache()
	vp.queue_free()

# ------------------------------------------------------------ cache
func _load_cache() -> bool:
	var f := FileAccess.open(CACHE_DIR + "/index.json", FileAccess.READ)
	if f == null: return false
	var idx = JSON.parse_string(f.get_as_text())
	if not (idx is Dictionary): return false
	for key in idx:
		var img := Image.load_from_file(CACHE_DIR + "/" + key + ".png")
		if img == null: return false
		img.generate_mipmaps()
		sprites[key] = {"tex": ImageTexture.create_from_image(img), "anchor": Vector2(idx[key][0], idx[key][1])}
	return true

func _save_cache() -> void:
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	var idx := {}
	for key in sprites:
		var img: Image = sprites[key]["img"]
		img.save_png(CACHE_DIR + "/" + key + ".png")
		idx[key] = [sprites[key]["anchor"].x, sprites[key]["anchor"].y]
		sprites[key].erase("img")
	var f := FileAccess.open(CACHE_DIR + "/index.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(idx))

# ------------------------------------------------------------ studio
func _setup() -> void:
	vp = SubViewport.new()
	vp.size = Vector2i(320, 320)
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.68, 0.8)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.05
	env.ssao_enabled = true
	env.ssao_radius = 2.0
	env.ssao_intensity = 2.5
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	cam = Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	vp.add_child(cam)
	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.45
	sun.light_color = Color(1.0, 0.95, 0.85)
	sun.shadow_enabled = true
	sun.shadow_opacity = 0.85
	sun.shadow_blur = 1.6
	sun.directional_shadow_max_distance = 600.0
	# sunlight from the upper left of the screen: shadows fall to the right and a little down
	var travel := (Vector3(1, 0, -1).normalized() * 0.75 + Vector3(1, 0, 1).normalized() * 0.35)
	travel.y = -0.85
	sun.transform = Transform3D(Basis.looking_at(travel.normalized(), Vector3.UP), Vector3.ZERO)
	vp.add_child(sun)
	catcher = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(500, 500)
	catcher.mesh = pm
	var cm := ShaderMaterial.new()
	cm.shader = load("res://shaders/shadow_catcher.gdshader")
	catcher.material_override = cm
	vp.add_child(catcher)
	stage = Node3D.new()
	vp.add_child(stage)
	bake_shader = load("res://shaders/bake.gdshader")
	for k in ["fine", "coarse", "streak"]:
		var n := FastNoiseLite.new()
		n.seed = {"fine": 3, "coarse": 9, "streak": 21}[k]
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH if k != "fine" else FastNoiseLite.TYPE_CELLULAR
		n.frequency = {"fine": 0.08, "coarse": 0.02, "streak": 0.05}[k]
		n.fractal_octaves = 3
		var img := n.get_seamless_image(256, 256)
		img.generate_mipmaps()
		noise[k] = ImageTexture.create_from_image(img)

## Frame the camera on a spot `lift` world units above the ground for a viewport of
## `size` px; returns the screen position of the ground origin.
func _frame(size: int, lift: float) -> Vector2:
	vp.size = Vector2i(size, size)
	cam.size = size / PPU
	var target := Vector3(0, lift, 0)
	var back := Vector3(1, 0, 1).normalized() * cos(deg_to_rad(30.0)) + Vector3(0, sin(deg_to_rad(30.0)), 0)
	cam.transform = Transform3D(Basis.looking_at(-back, Vector3.UP), target + back * 400.0)
	# ground origin is `lift` units below the target: height maps to cos(30) * PPU px
	return Vector2(size / 2.0, size / 2.0 + lift * cos(deg_to_rad(30.0)) * PPU)

func _bake(job: Dictionary) -> void:
	var anchor := _frame(job.get("size", 256), job.get("lift", 12.0))
	var model: Node3D = job["build"].call()
	stage.add_child(model)
	catcher.visible = not job.get("mask", false)
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	model.free()
	if job.get("mask", false): _to_mask(img)
	var r := img.get_used_rect()
	if r.size.x <= 0: return
	r = r.grow(1).intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	img = img.get_region(r)
	img.convert(Image.FORMAT_RGBA8)
	var keep := img.duplicate()
	img.generate_mipmaps()
	sprites[job["key"]] = {"tex": ImageTexture.create_from_image(img), "anchor": anchor - Vector2(r.position), "img": keep}

## Tint layer: keep only the white-lit cloth (everything else was rendered black).
func _to_mask(img: Image) -> void:
	img.convert(Image.FORMAT_RGBA8)
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.a < 0.05: continue
			var l := maxf(c.r, maxf(c.g, c.b))
			if l < 0.06: img.set_pixel(x, y, Color(0, 0, 0, 0))
			else: img.set_pixel(x, y, Color(l, l, l, c.a))

# ------------------------------------------------------------ materials & primitives
func mat(col: Color, tex := "coarse", sc := 0.08, stretch := Vector3.ONE, contrast := 0.45, snow := 0.0) -> ShaderMaterial:
	contrast = minf(1.0, contrast * 1.6) # surface detail must survive the downscale
	var m := ShaderMaterial.new()
	m.shader = bake_shader
	m.set_shader_parameter("base_color", col) # Color => converted from sRGB to linear
	m.set_shader_parameter("detail", noise[tex])
	m.set_shader_parameter("scale", sc)
	m.set_shader_parameter("stretch", stretch)
	m.set_shader_parameter("contrast", contrast)
	m.set_shader_parameter("snow", snow)
	return m

func flat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m

func mi(parent: Node3D, mesh: Mesh, m: Material, pos: Vector3, rot := Vector3.ZERO, sc := Vector3.ONE) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	n.mesh = mesh
	n.material_override = m
	n.position = pos
	n.rotation_degrees = rot
	n.scale = sc
	parent.add_child(n)
	return n

func cyl(r_top: float, r_bot: float, h: float, seg := 12) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = r_top
	c.bottom_radius = r_bot
	c.height = h
	c.radial_segments = seg
	c.rings = 1
	return c

func sph(r: float, seg := 12, rings := 7) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2
	s.radial_segments = seg
	s.rings = rings
	return s

func box(sz: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = sz
	return b

func cap(r: float, h: float) -> CapsuleMesh:
	var c := CapsuleMesh.new()
	c.radius = r
	c.height = h
	c.radial_segments = 10
	c.rings = 3
	return c

# ------------------------------------------------------------ the catalogue
func _jobs() -> Array:
	var jobs: Array = []
	for v in 4:
		for snowy in [false, true]:
			var sfx := "_snow" if snowy else ""
			jobs.append({"key": "pine_%d%s" % [v, sfx], "size": 192, "lift": 26.0, "build": _pine.bind(v, snowy)})
			jobs.append({"key": "leaf_%d%s" % [v, sfx], "size": 192, "lift": 24.0, "build": _leafy.bind(v, snowy)})
	for snowy in [false, true]:
		var sfx := "_snow" if snowy else ""
		jobs.append({"key": "bush_full" + sfx, "size": 96, "lift": 4.0, "build": _bush.bind(true, snowy)})
		jobs.append({"key": "bush_bare" + sfx, "size": 96, "lift": 4.0, "build": _bush.bind(false, snowy)})
		jobs.append({"key": "stump" + sfx, "size": 64, "lift": 2.0, "build": _stump.bind(snowy)})
		for v in 3: jobs.append({"key": "rock_%d%s" % [v, sfx], "size": 128, "lift": 6.0, "build": _rocks.bind(v, snowy)})
		for big in [false, true]:
			var b := "large_" if big else ""
			jobs.append({"key": "%shome1%s" % [b, sfx], "size": 192, "lift": 18.0, "build": _tent.bind(big, snowy)})
			jobs.append({"key": "%shome2%s" % [b, sfx], "size": 192, "lift": 18.0, "build": _round_hut.bind(big, snowy)})
			jobs.append({"key": "%shome3%s" % [b, sfx], "size": 224, "lift": 16.0, "build": _longhouse.bind(big, snowy)})
		for st in [1, 2, 3]: jobs.append({"key": "post%d%s" % [st, sfx], "size": 64, "lift": 11.0, "build": _post.bind(st, snowy)})
		jobs.append({"key": "fire_base" + sfx, "size": 96, "lift": 2.0, "build": _fire_base.bind(snowy)})
	for snowy in [false, true]:
		var sfx := "_snow" if snowy else ""
		jobs.append({"key": "granary" + sfx, "size": 160, "lift": 18.0, "build": _granary.bind(snowy)})
		jobs.append({"key": "smelter" + sfx, "size": 128, "lift": 14.0, "build": _smelter.bind(snowy)})
		jobs.append({"key": "council_ring" + sfx, "size": 192, "lift": 8.0, "build": _council.bind(snowy)})
		jobs.append({"key": "totem_shrine" + sfx, "size": 128, "lift": 22.0, "build": _shrine.bind(false, snowy)})
		jobs.append({"key": "grand_altar" + sfx, "size": 192, "lift": 26.0, "build": _shrine.bind(true, snowy)})
		jobs.append({"key": "weapon_rack" + sfx, "size": 96, "lift": 12.0, "build": _rack.bind(snowy)})
		jobs.append({"key": "aurochs_pen" + sfx, "size": 192, "lift": 6.0, "build": _pen.bind(snowy)})
		jobs.append({"key": "den" + sfx, "size": 224, "lift": 14.0, "build": _mound.bind(true, snowy)})
		jobs.append({"key": "cave" + sfx, "size": 224, "lift": 14.0, "build": _mound.bind(false, snowy)})
		jobs.append({"key": "stones" + sfx, "size": 224, "lift": 12.0, "build": _stones.bind(snowy)})
		jobs.append({"key": "peak" + sfx, "size": 320, "lift": 45.0, "build": _peak.bind(snowy)})
	# animals: 8 directions x (idle + walk)
	for kind in ["deer", "tiger", "wolf"]:
		for d in DIRS:
			jobs.append({"key": "%s_idle_%d_0" % [kind, d], "size": 128, "lift": 10.0, "build": _beast.bind(kind, d * 360.0 / DIRS, 0.0, false)})
			for f in 6:
				jobs.append({"key": "%s_walk_%d_%d" % [kind, d, f], "size": 128, "lift": 10.0, "build": _beast.bind(kind, d * 360.0 / DIRS, f / 6.0, true)})
	# villagers: 8 directions x (idle + walk + work), plus a cloth layer tinted per person
	for d in DIRS:
		var yaw := d * 360.0 / DIRS
		var poses: Array = [["idle", 0, 0.0]]
		for f in WALK_FRAMES: poses.append(["walk", f, float(f) / WALK_FRAMES])
		for f in WORK_FRAMES: poses.append(["work", f, float(f) / WORK_FRAMES])
		for p in poses:
			var key := "man_%s_%d_%d" % [p[0], d, p[1]]
			jobs.append({"key": key, "size": 96, "lift": 13.0, "build": _person.bind(yaw, p[0], p[2], false)})
			jobs.append({"key": key + "_cloth", "size": 96, "lift": 13.0, "mask": true, "build": _person.bind(yaw, p[0], p[2], true)})
	return jobs

# ---- nature
func _pine(v: int, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 100 + v
	var bark := mat(Color("#5e3d22"), "streak", 0.12, Vector3(1, 5, 1))
	var leaf := mat(Color("#2f5a2e") if v % 2 == 0 else Color("#2a5232"), "fine", 0.18, Vector3.ONE, 0.5, 0.85 if snowy else 0.0)
	mi(root, cyl(1.6, 2.6, 18, 8), bark, Vector3(0, 9, 0))
	var h := 12.0
	for i in 4:
		var r := 15.0 - i * 3.2 + rng.randf_range(-1, 1)
		var ch := 15.0 - i * 1.5
		mi(root, cyl(0.0, r, ch, 9), leaf, Vector3(rng.randf_range(-0.8, 0.8), h + ch / 2, rng.randf_range(-0.8, 0.8)), Vector3(rng.randf_range(-4, 4), rng.randf_range(0, 40), rng.randf_range(-4, 4)))
		h += 8.5
	return root

func _leafy(v: int, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 200 + v
	var bark := mat(Color("#6b4a2c"), "streak", 0.12, Vector3(1, 5, 1))
	var leaf := mat(Color("#3e7a35") if v % 2 == 0 else Color("#4a8038"), "fine", 0.16, Vector3.ONE, 0.55, 0.8 if snowy else 0.0)
	mi(root, cyl(1.8, 2.8, 22, 8), bark, Vector3(0, 11, 0))
	mi(root, cyl(0.8, 1.2, 10, 6), bark, Vector3(3, 19, 1), Vector3(0, 0, -35))
	for i in 7:
		var a := i * TAU / 7.0 + rng.randf()
		var r := rng.randf_range(7.5, 10.5)
		mi(root, sph(r, 10, 6), leaf, Vector3(cos(a) * 7.0, 27 + rng.randf_range(-3, 5), sin(a) * 7.0))
	mi(root, sph(11, 10, 6), leaf, Vector3(0, 33, 0))
	return root

func _bush(full: bool, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var leaf := mat(Color("#3b6a2e"), "fine", 0.2, Vector3.ONE, 0.5, 0.8 if snowy else 0.0)
	for p in [Vector3(-4, 5, 2), Vector3(4, 5, -1), Vector3(0, 8, 0), Vector3(1, 5, 4)]:
		mi(root, sph(6.5, 9, 6), leaf, p)
	if full:
		var berry := mat(Color("#c8283a"), "fine", 0.3, Vector3.ONE, 0.2)
		for i in 12:
			var a := i * 2.4
			mi(root, sph(1.2, 6, 4), berry, Vector3(cos(a) * 6.5, 5 + (i % 3) * 2.5, sin(a) * 6.5))
	return root

func _stump(snowy: bool) -> Node3D:
	var root := Node3D.new()
	mi(root, cyl(3.4, 4.0, 5, 9), mat(Color("#6b4a2a"), "streak", 0.2, Vector3(1, 4, 1)), Vector3(0, 2.5, 0))
	mi(root, cyl(3.4, 3.4, 0.4, 9), mat(Color("#c09060") if not snowy else Color("#eef2f8"), "fine", 0.4), Vector3(0, 5.1, 0))
	return root

func _rocks(v: int, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 300 + v
	var stone: Material = mat(Color("#8b877d"), "coarse", 0.15, Vector3.ONE, 0.6, 0.7 if snowy else 0.0)
	for i in 3 + v:
		var s := rng.randf_range(4, 8.5)
		mi(root, sph(s, 7, 5), stone, Vector3(rng.randf_range(-9, 9), s * 0.45, rng.randf_range(-7, 7)), Vector3(rng.randf_range(0, 60), rng.randf_range(0, 360), 0), Vector3(1.0, rng.randf_range(0.6, 1.0), rng.randf_range(0.7, 1.2)))
	return root

# ---- homes
func _tent(big: bool, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var r := 22.0 if big else 17.0
	var h := 36.0 if big else 30.0
	var hide := mat(Color("#b48a5c"), "coarse", 0.1, Vector3(1, 3, 1), 0.4, 0.6 if snowy else 0.0)
	mi(root, cyl(0.6, r, h, 10), hide, Vector3(0, h / 2, 0))
	var pole := mat(Color("#5e3d22"), "streak", 0.2, Vector3(1, 4, 1))
	for i in 5:
		var a := i * TAU / 5
		mi(root, cyl(0.5, 0.6, 12, 5), pole, Vector3(cos(a) * 1.5, h + 3, sin(a) * 1.5), Vector3(rad_to_deg(sin(a)) * 0.35, 0, -rad_to_deg(cos(a)) * 0.35))
	mi(root, box(Vector3(7, h * 0.5, 1.0)), mat(Color("#3a2414"), "fine"), Vector3(0, h * 0.24, r * 0.72), Vector3(-28, 0, 0))
	return root

func _round_hut(big: bool, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var r := 25.0 if big else 19.0
	var wall := mat(Color("#9b7a52"), "coarse", 0.12, Vector3.ONE, 0.5)
	var thatch := mat(Color("#c9a24f"), "streak", 0.18, Vector3(1, 6, 1), 0.6, 0.85 if snowy else 0.0)
	var wh := 13.0 if big else 11.0
	mi(root, cyl(r, r, wh, 16), wall, Vector3(0, wh / 2, 0))
	mi(root, cyl(0.5, r * 1.22, (31.0 if big else 25.0), 16), thatch, Vector3(0, wh + (15.5 if big else 12.5), 0))
	mi(root, box(Vector3(7, 9, 2)), mat(Color("#2a1a0e"), "fine"), Vector3(-r * 0.2, 4.5, r * 0.95), Vector3(0, -12, 0))
	return root

func _longhouse(big: bool, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var r := 26.0 if big else 20.0
	var length := r * 2.5
	var depth := r * 1.4
	var stone := mat(Color("#8f8b82"), "coarse", 0.18, Vector3.ONE, 0.6)
	var timber := mat(Color("#8a5f3a"), "streak", 0.14, Vector3(6, 1, 1), 0.5)
	var roof := mat(Color("#a8823e"), "streak", 0.16, Vector3(1, 1, 6), 0.55, 0.9 if snowy else 0.0)
	mi(root, box(Vector3(length + 6, 5, depth + 6)), stone, Vector3(0, 2.5, 0))
	mi(root, box(Vector3(length, 14, depth)), timber, Vector3(0, 12, 0))
	var pr := PrismMesh.new()
	pr.size = Vector3(depth + 8, 20, length + 8)
	mi(root, pr, roof, Vector3(0, 29, 0), Vector3(0, 90, 0))
	var red := mat(Color("#b03a2b"), "fine", 0.2)
	for side in [-1, 1]:
		mi(root, box(Vector3(1.6, 12, 1.6)), red, Vector3(side * (length / 2 + 4), 40, 3), Vector3(30, 0, 0))
		mi(root, box(Vector3(1.6, 12, 1.6)), red, Vector3(side * (length / 2 + 4), 40, -3), Vector3(-30, 0, 0))
	mi(root, box(Vector3(9, 11, 1.5)), mat(Color("#2a1a0e"), "fine"), Vector3(0, 10, depth / 2 + 0.6))
	return root

func _post(style: int, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var h := 20.0 + style * 3.0
	var wood: Material = mat(Color("#7a5530"), "streak", 0.2, Vector3(1, 5, 1), 0.5)
	if style >= 3: mi(root, sph(4.5, 7, 4), mat(Color("#8f8b82"), "coarse", 0.2), Vector3(0, 1.2, 0), Vector3.ZERO, Vector3(1, 0.5, 1))
	mi(root, cyl(2.6, 2.8, h, 7), wood, Vector3(0, h / 2, 0))
	mi(root, cyl(0.0, 2.6, 5, 7), mat(Color("#a57a4a"), "streak", 0.2, Vector3(1, 3, 1), 0.4, 0.8 if snowy else 0.0), Vector3(0, h + 2.5, 0))
	if style >= 2:
		mi(root, cyl(2.9, 2.9, 1.2, 7), mat(Color("#4a3018"), "fine"), Vector3(0, h * 0.45, 0))
	return root

func _fire_base(snowy: bool) -> Node3D:
	var root := Node3D.new()
	var stone := mat(Color("#8b877d"), "coarse", 0.25, Vector3.ONE, 0.5, 0.6 if snowy else 0.0)
	for i in 10:
		var a := i * TAU / 10
		mi(root, sph(2.6, 7, 4), stone, Vector3(cos(a) * 11, 1.2, sin(a) * 11), Vector3.ZERO, Vector3(1, 0.7, 1))
	var lg := mat(Color("#4a2e16"), "streak", 0.2, Vector3(4, 1, 1))
	mi(root, cyl(1.4, 1.4, 16, 7), lg, Vector3(0, 2, 0), Vector3(0, 30, 80))
	mi(root, cyl(1.4, 1.4, 16, 7), lg, Vector3(0, 2.6, 0), Vector3(0, -40, 80))
	mi(root, cyl(1.3, 1.3, 14, 7), lg, Vector3(0, 3.2, 0), Vector3(0, 95, 80))
	return root

# ---- more buildings
func _granary(snowy: bool) -> Node3D:
	var root := Node3D.new()
	var wood := mat(Color("#6b4a2a"), "streak", 0.2, Vector3(1, 4, 1))
	for i in 4:
		var a := i * TAU / 4 + 0.6
		mi(root, cyl(1.2, 1.4, 9, 6), wood, Vector3(cos(a) * 12, 4.5, sin(a) * 12))
	mi(root, cyl(16, 16, 2, 14), wood, Vector3(0, 9.5, 0))
	mi(root, cyl(14.5, 15, 15, 16), mat(Color("#c08a58"), "coarse", 0.14, Vector3.ONE, 0.5), Vector3(0, 18, 0))
	mi(root, sph(17, 16, 8), mat(Color("#a7703f"), "streak", 0.16, Vector3(1, 5, 1), 0.55, 0.85 if snowy else 0.0), Vector3(0, 25.5, 0), Vector3.ZERO, Vector3(1, 0.65, 1))
	mi(root, box(Vector3(5, 7, 1.4)), mat(Color("#2a1a0e"), "fine"), Vector3(0, 17, 14.5))
	return root

func _smelter(snowy: bool) -> Node3D:
	var root := Node3D.new()
	var stone := mat(Color("#7d776c"), "coarse", 0.2, Vector3.ONE, 0.6, 0.5 if snowy else 0.0)
	mi(root, sph(13, 12, 7), stone, Vector3(0, 6, 0), Vector3.ZERO, Vector3(1, 1.1, 1))
	mi(root, cyl(3.2, 4.2, 16, 8), stone, Vector3(4, 20, -3))
	mi(root, box(Vector3(7, 7, 4)), flat(Color(1.0, 0.55, 0.15)), Vector3(0, 4.5, 11))
	var bronze := mat(Color("#d49a3a"), "fine", 0.3, Vector3.ONE, 0.3)
	for i in 3: mi(root, box(Vector3(6, 1.6, 2.6)), bronze, Vector3(15 + i * 1.5, 0.8 + i * 1.6, 6 - i))
	return root

func _council(snowy: bool) -> Node3D:
	var root := Node3D.new()
	var stone := mat(Color("#9a968c"), "coarse", 0.2, Vector3.ONE, 0.55, 0.7 if snowy else 0.0)
	for i in 10:
		var a := i * TAU / 10
		mi(root, box(Vector3(8, 5, 4)), stone, Vector3(cos(a) * 30, 2.5, sin(a) * 30), Vector3(0, -rad_to_deg(a) + 90, 0))
	mi(root, cyl(1.5, 1.8, 18, 6), mat(Color("#6b4a2a"), "streak", 0.2, Vector3(1, 4, 1)), Vector3(0, 9, 0))
	mi(root, box(Vector3(5, 3, 5)), mat(Color("#c0392b"), "fine", 0.3), Vector3(0, 16, 0))
	return root

func _shrine(grand: bool, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var stone := mat(Color("#9a968c"), "coarse", 0.2, Vector3.ONE, 0.55, 0.7 if snowy else 0.0)
	var base_h := 0.0
	if grand:
		mi(root, box(Vector3(56, 7, 56)), stone, Vector3(0, 3.5, 0))
		mi(root, box(Vector3(38, 8, 38)), stone, Vector3(0, 11, 0))
		base_h = 15.0
	else:
		for i in 6:
			var a := i * TAU / 6
			mi(root, sph(2.6, 7, 4), stone, Vector3(cos(a) * 11, 1.2, sin(a) * 11))
	var h := 58.0 if grand else 44.0
	var wood := mat(Color("#6b4a2a"), "streak", 0.2, Vector3(1, 4, 1))
	mi(root, cyl(3.6, 4.2, h, 8), wood, Vector3(0, base_h + h / 2, 0))
	var cols := [Color("#c0392b"), Color("#e6b33a"), Color("#2e86ab"), Color("#c0392b")]
	for i in 4:
		mi(root, cyl(4.6, 4.6, h * 0.12, 8), mat(cols[i], "fine", 0.3, Vector3.ONE, 0.3), Vector3(0, base_h + h - 5 - i * h * 0.22, 0))
	var wing := mat(Color("#e6b33a"), "fine", 0.3, Vector3.ONE, 0.3, 0.6 if snowy else 0.0)
	mi(root, box(Vector3(26 if grand else 20, 1.2, 6)), wing, Vector3(0, base_h + h - 3, 0), Vector3(0, 0, 0))
	return root

func _rack(snowy: bool) -> Node3D:
	var root := Node3D.new()
	var wood := mat(Color("#8a5a32"), "streak", 0.2, Vector3(1, 4, 1), 0.5, 0.6 if snowy else 0.0)
	for side in [-1, 1]: mi(root, cyl(0.9, 1.0, 16, 6), wood, Vector3(side * 9, 8, 0))
	mi(root, cyl(0.8, 0.8, 20, 6), wood, Vector3(0, 14, 0), Vector3(0, 0, 90))
	for i in 4:
		mi(root, cyl(0.45, 0.45, 26, 5), mat(Color("#c8b48a"), "streak", 0.3, Vector3(1, 4, 1)), Vector3(-6 + i * 4, 13, 1.5), Vector3(-12, 0, 0))
		mi(root, cyl(0.0, 1.0, 4, 5), mat(Color("#8d8d93"), "coarse", 0.4), Vector3(-6 + i * 4, 27.5, 4.2), Vector3(-12, 0, 0))
	return root

func _pen(snowy: bool) -> Node3D:
	var root := Node3D.new()
	var wood := mat(Color("#7a5530"), "streak", 0.2, Vector3(1, 4, 1), 0.5, 0.6 if snowy else 0.0)
	for i in 18:
		var a := i * TAU / 18
		mi(root, cyl(0.8, 0.9, 9, 5), wood, Vector3(cos(a) * 30, 4.5, sin(a) * 30))
	for h in [4.0, 7.5]:
		for i in 18:
			var a := (i + 0.5) * TAU / 18
			mi(root, cyl(0.45, 0.45, 10.5, 4), wood, Vector3(cos(a) * 30, h, sin(a) * 30), Vector3(90, -rad_to_deg(a), 0))
	for p in [Vector3(-8, 0, 4), Vector3(9, 0, -5)]:
		var ox := _beast("aurochs", 30.0 + p.x * 9, 0.0, false)
		ox.position = p
		root.add_child(ox)
	return root

func _mound(den: bool, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 77 if den else 78
	var rock := mat(Color("#6e6258") if den else Color("#7d756a"), "coarse", 0.12, Vector3.ONE, 0.6, 0.75 if snowy else 0.0)
	for i in 7:
		var r := rng.randf_range(12, 24)
		mi(root, sph(r, 8, 5), rock, Vector3(rng.randf_range(-24, 24), r * 0.5, rng.randf_range(-20, 6)), Vector3(rng.randf_range(0, 40), rng.randf_range(0, 360), 0), Vector3(1, rng.randf_range(0.7, 1.1), 1))
	mi(root, sph(11, 10, 6), flat(Color("#120d0a")), Vector3(0, 6, 15), Vector3.ZERO, Vector3(1, 0.9, 0.5))
	if den:
		var bone := mat(Color("#e8dcc0"), "fine", 0.3, Vector3.ONE, 0.2)
		for i in 5:
			mi(root, cyl(0.7, 0.7, 9, 5), bone, Vector3(-16 + i * 8, 0.8, 22 + (i % 2) * 4), Vector3(0, i * 37, 90))
	return root

func _stones(snowy: bool) -> Node3D:
	var root := Node3D.new()
	var stone := mat(Color("#9a968c"), "coarse", 0.16, Vector3.ONE, 0.55, 0.7 if snowy else 0.0)
	for i in 7:
		var a := i * TAU / 7
		mi(root, box(Vector3(7, 26, 4)), stone, Vector3(cos(a) * 34, 13, sin(a) * 34), Vector3(0, -rad_to_deg(a) + 90, 0))
	mi(root, box(Vector3(30, 3, 5)), stone, Vector3(0, 27.5, -34), Vector3.ZERO)
	return root

func _peak(snowy: bool) -> Node3D:
	var root := Node3D.new()
	var rock := mat(Color("#8a8276"), "coarse", 0.07, Vector3.ONE, 0.6)
	mi(root, cyl(4, 70, 100, 9), rock, Vector3(0, 50, 0), Vector3(0, 20, 0))
	mi(root, cyl(2, 40, 60, 8), rock, Vector3(45, 30, 20), Vector3(0, 50, 0))
	mi(root, cyl(0.0, 14, 22, 9), mat(Color("#eef2f4"), "fine", 0.2, Vector3.ONE, 0.3), Vector3(0, 90, 0), Vector3(0, 20, 0))
	return root

# ---- animals
## A four-legged animal (deer, tiger, wolf, aurochs) yawed to face `yaw`, legs mid-stride.
func _beast(kind: String, yaw: float, phase: float, walking: bool) -> Node3D:
	var root := Node3D.new()
	root.rotation_degrees.y = yaw
	var spec: Dictionary = {
		"deer": {"col": Color("#9a6a3c"), "belly": Color("#d8c09a"), "blen": 17.0, "r": 4.6, "leg": 11.0, "neck": 7.0, "head": 3.2},
		"tiger": {"col": Color("#d98a2b"), "belly": Color("#f2d6a8"), "blen": 22.0, "r": 6.0, "leg": 9.0, "neck": 3.0, "head": 5.0},
		"wolf": {"col": Color("#7a7a80"), "belly": Color("#b4b4ba"), "blen": 16.0, "r": 4.2, "leg": 8.5, "neck": 3.0, "head": 3.6},
		"aurochs": {"col": Color("#3d2a1c"), "belly": Color("#5a4232"), "blen": 20.0, "r": 6.5, "leg": 8.0, "neck": 2.0, "head": 4.6},
	}[kind]
	var hide := mat(spec["col"], "fine", 0.25, Vector3.ONE, 0.35)
	var blen: float = spec["blen"]
	var leg_h: float = spec["leg"]
	var body_y: float = leg_h + spec["r"] * 0.6
	var body := mi(root, cap(spec["r"], blen), hide, Vector3(0, body_y, 0), Vector3(90, 0, 0))
	mi(root, cap(spec["r"] * 0.7, blen * 0.8), mat(spec["belly"], "fine", 0.25, Vector3.ONE, 0.3), Vector3(0, body_y - spec["r"] * 0.35, 0), Vector3(90, 0, 0))
	if kind == "tiger":
		var stripe := flat(Color("#2a1608"))
		for i in 5: mi(root, box(Vector3(spec["r"] * 2.05, 1.1, 1.2)), stripe, Vector3(0, body_y + 0.8, -blen * 0.35 + i * blen * 0.17), Vector3(0, 0, 0), Vector3(1, 1, 1))
	var sw := sin(phase * TAU) * 28.0 if walking else 0.0
	for i in 4:
		var front := i < 2
		var side := -1 if i % 2 == 0 else 1
		var hip := Node3D.new()
		hip.position = Vector3(side * spec["r"] * 0.55, leg_h, blen * (0.32 if front else -0.32))
		hip.rotation_degrees.x = sw * (1 if (i == 0 or i == 3) else -1)
		root.add_child(hip)
		mi(hip, cyl(spec["r"] * 0.22, spec["r"] * 0.16, leg_h, 6), hide, Vector3(0, -leg_h / 2, 0))
	var neck := Node3D.new()
	neck.position = Vector3(0, body_y + spec["r"] * 0.4, blen * 0.5)
	root.add_child(neck)
	if spec["neck"] > 4.0: mi(neck, cyl(1.6, 2.2, spec["neck"], 6), hide, Vector3(0, spec["neck"] * 0.4, 1.5), Vector3(30, 0, 0))
	var head_pos := Vector3(0, spec["neck"] * 0.8, 3.0 + spec["head"] * 0.4)
	mi(neck, sph(spec["head"], 10, 6), hide, head_pos, Vector3.ZERO, Vector3(0.9, 0.9, 1.3))
	match kind:
		"deer":
			var antler := mat(Color("#e0d0b0"), "fine", 0.3)
			for side in [-1, 1]:
				mi(neck, cyl(0.3, 0.45, 7, 4), antler, head_pos + Vector3(side * 1.4, 4, -0.5), Vector3(-15, 0, side * 25))
				mi(neck, cyl(0.25, 0.35, 4, 4), antler, head_pos + Vector3(side * 2.8, 6.5, 1), Vector3(30, 0, side * 50))
		"tiger":
			var fang := mat(Color("#ffffff"), "fine", 0.3, Vector3.ONE, 0.1)
			for side in [-1, 1]: mi(neck, cyl(0.25, 0.5, 4, 4), fang, head_pos + Vector3(side * 1.4, -3.2, 4.2), Vector3(180, 0, 0))
		"wolf":
			mi(neck, cyl(0.6, 1.6, 4, 6), hide, head_pos + Vector3(0, -0.6, 4.2), Vector3(90, 0, 0))
			for side in [-1, 1]: mi(neck, cyl(0.0, 1.1, 3, 4), hide, head_pos + Vector3(side * 1.6, 3.4, -0.5))
		"aurochs":
			var horn := mat(Color("#e8dcc0"), "fine", 0.3)
			for side in [-1, 1]: mi(neck, cyl(0.3, 0.8, 6, 5), horn, head_pos + Vector3(side * 3.5, 2.5, 0), Vector3(0, 0, side * -70))
	var tail_len := 10.0 if kind == "tiger" else (3.0 if kind == "deer" else 7.0)
	mi(root, cyl(0.5, 1.0, tail_len, 5), hide, Vector3(0, body_y + 1, -blen * 0.5 - tail_len * 0.4), Vector3(-60 + (sin(phase * TAU) * 10.0 if walking else 0.0), 0, 0))
	return root

# ---- people
## A villager in a pose. cloth_only renders the tunic white and everything else black
## so the game can tint the clothes per person.
func _person(yaw: float, anim: String, phase: float, cloth_only: bool) -> Node3D:
	var root := Node3D.new()
	root.rotation_degrees.y = yaw
	var skin: Material = mat(Color("#d29e74"), "fine", 0.4, Vector3.ONE, 0.15)
	var hair: Material = mat(Color("#2b1a0e"), "fine", 0.5, Vector3.ONE, 0.3)
	var cloth: Material = mat(Color("#d8d4cc") if not cloth_only else Color(1, 1, 1), "coarse", 0.4, Vector3.ONE, 0.35)
	var fur: Material = mat(Color("#7a5a3a"), "fine", 0.5, Vector3.ONE, 0.4)
	var wood: Material = mat(Color("#6b4524"), "streak", 0.4, Vector3(1, 4, 1))
	var stone: Material = mat(Color("#8d8d93"), "coarse", 0.5)
	if cloth_only:
		var black := flat(Color.BLACK)
		skin = black
		hair = black
		fur = black
		wood = black
		stone = black
	var swing := 0.0
	var arm_l := 0.0
	var arm_r := 0.0
	var bob := 0.0
	match anim:
		"walk":
			swing = sin(phase * TAU) * 30.0
			arm_l = -swing * 0.8
			arm_r = swing * 0.8
			bob = absf(sin(phase * TAU)) * 0.8
		"work":
			arm_r = lerpf(-150.0, 25.0, [0.0, 0.35, 0.85, 1.0][int(phase * WORK_FRAMES) % WORK_FRAMES])
			arm_l = -20.0
	var body := Node3D.new()
	body.position.y = bob
	root.add_child(body)
	for side in [-1, 1]: # legs swing at the hip
		var hip := Node3D.new()
		hip.position = Vector3(side * 1.8, 11, 0)
		hip.rotation_degrees.x = swing * side
		body.add_child(hip)
		mi(hip, cap(1.5, 11), skin, Vector3(0, -5.5, 0))
	mi(body, cap(3.6, 12), cloth, Vector3(0, 16, 0), Vector3.ZERO, Vector3(1.05, 1, 0.8))
	mi(body, cyl(3.4, 4.6, 6, 10), cloth, Vector3(0, 10.5, 0))
	mi(body, cyl(4.2, 4.6, 2.2, 10), fur, Vector3(0, 21, 0), Vector3.ZERO, Vector3(1, 1, 0.85))
	mi(body, sph(3.3, 12, 8), skin, Vector3(0, 25.3, 0))
	mi(body, sph(3.5, 10, 6), hair, Vector3(0, 26.2, -0.6), Vector3(-15, 0, 0), Vector3(1, 0.8, 1))
	for side in [-1, 1]: # arms swing at the shoulder
		var sh := Node3D.new()
		sh.position = Vector3(side * 4.6, 20.5, 0)
		sh.rotation_degrees.x = arm_r if side > 0 else arm_l
		body.add_child(sh)
		mi(sh, cap(1.2, 9.5), skin, Vector3(0, -4.5, 0))
		if side > 0 and anim == "work": # stone axe
			mi(sh, cyl(0.45, 0.45, 9, 5), wood, Vector3(0, -9, 3), Vector3(90, 0, 0))
			mi(sh, box(Vector3(1.2, 2.6, 3.2)), stone, Vector3(0, -9, 7.2))
	return root
