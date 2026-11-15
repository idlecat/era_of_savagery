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

const ART_VERSION := 11
const BAKE_SCALE := 2.0
const PPU := 1.06066 * BAKE_SCALE
const CACHE_DIR := "user://art_cache_v%d" % ART_VERSION
const DIRS := 8
const WALK_FRAMES := 8
const WORK_FRAMES := 4
## Villager animations: name -> frames. Tool animations also bake a bronze variant.
const MAN_ANIMS := {"idle": 1, "walk": 8, "chop": 4, "build": 4, "gather": 4, "attack": 4, "ritual": 4, "dead": 1}
const TOOL_ANIMS := ["chop", "build", "attack"]
const SITE_SIZES := [14, 20, 26] # footprint radius of construction-site sprites

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
	# remove caches from older ART_VERSIONs
	var ud := DirAccess.open("user://")
	if ud:
		for d in ud.get_directories():
			if d.begins_with("art_cache_v") and "user://" + d != CACHE_DIR:
				var old := DirAccess.open("user://" + d)
				if old:
					for fn in old.get_files(): old.remove(fn)
				ud.remove(d)

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
	var r := img.get_used_rect()
	if r.size.x <= 0: return
	r = r.grow(1).intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	img = img.get_region(r)
	img.convert(Image.FORMAT_RGBA8)
	if job.get("mask", false): _to_mask(img)
	var keep := img.duplicate()
	img.generate_mipmaps()
	sprites[job["key"]] = {"tex": ImageTexture.create_from_image(img), "anchor": anchor - Vector2(r.position), "img": keep}

## Tint layer: keep only the white-lit cloth (everything else was rendered black).
func _to_mask(img: Image) -> void:
	var data := img.get_data()
	for i in range(0, data.size(), 4):
		if data[i + 3] < 13: continue
		var l := maxi(data[i], maxi(data[i + 1], data[i + 2]))
		if l < 15:
			data[i + 3] = 0
		else:
			data[i] = l
			data[i + 1] = l
			data[i + 2] = l
	img.set_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8, data)

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

## A round stick from a to b (branches, seams, poles).
func segment(parent: Node3D, a: Vector3, b: Vector3, r: float, m: Material) -> MeshInstance3D:
	var d := b - a
	var n := mi(parent, cyl(r * 0.8, r, d.length(), 6), m, (a + b) / 2)
	var up := d.normalized()
	var axis := Vector3.UP.cross(up)
	if axis.length() > 0.001: n.basis = Basis(axis.normalized(), Vector3.UP.angle_to(up))
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
	# construction sites: round / rectangular footprints, 3 sizes, 4 stages
	for shape in ["round", "rect"]:
		for size in SITE_SIZES:
			for stage in 4:
				jobs.append({"key": "site_%s_%d_%d" % [shape, size, stage], "size": 224, "lift": 14.0, "build": _site.bind(shape, float(size), stage)})
	# animals: 8 directions x (idle + walk)
	for kind in ["deer", "tiger", "wolf", "packox"]:
		for d in DIRS:
			var yaw := d * 360.0 / DIRS
			jobs.append({"key": "%s_idle_%d_0" % [kind, d], "size": 128, "lift": 10.0, "build": _beast.bind(kind, yaw, 0.0, false)})
			for f in 6:
				jobs.append({"key": "%s_walk_%d_%d" % [kind, d, f], "size": 128, "lift": 10.0, "build": _beast.bind(kind, yaw, f / 6.0, true)})
			if kind in ["tiger", "wolf"]:
				for f in 4:
					jobs.append({"key": "%s_attack_%d_%d" % [kind, d, f], "size": 128, "lift": 10.0, "build": _beast.bind(kind, yaw, f / 4.0, false, "attack")})
			if kind != "packox":
				jobs.append({"key": "%s_dead_%d_0" % [kind, d], "size": 128, "lift": 6.0, "build": _beast.bind(kind, yaw, 0.0, false, "dead")})
	# villagers: 8 directions x every animation, plus a cloth layer tinted per person;
	# tool animations again with bronze tools
	for d in DIRS:
		var yaw := d * 360.0 / DIRS
		for anim in MAN_ANIMS:
			var n: int = MAN_ANIMS[anim]
			for f in n:
				for tool in (["stone", "bronze"] if anim in TOOL_ANIMS else ["stone"]):
					var key := "man_%s_%d_%d%s" % [anim, d, f, "_bronze" if tool == "bronze" else ""]
					var ph := float(f) / n
					jobs.append({"key": key, "size": 112, "lift": 13.0, "build": _person.bind(yaw, anim, ph, false, tool)})
					jobs.append({"key": key + "_cloth", "size": 112, "lift": 13.0, "mask": true, "build": _person.bind(yaw, anim, ph, true, tool)})
	return jobs

# ---- nature
func _pine(v: int, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 100 + v
	var bark := mat(Color("#5a3a20"), "streak", 0.14, Vector3(1, 5, 1), 0.55)
	root.rotation_degrees = Vector3(rng.randf_range(-3, 3), 0, rng.randf_range(-3, 3)) # trees lean a little
	mi(root, cyl(1.5, 2.4, 20, 8), bark, Vector3(0, 10, 0))
	mi(root, cyl(2.4, 4.2, 3, 8), bark, Vector3(0, 1.5, 0)) # root flare
	var dark := Color("#24472a") if v % 2 == 0 else Color("#203f2c")
	var lite := Color("#3d6e3a") if v % 2 == 0 else Color("#3a6a40")
	var tiers := 6
	var h := 9.0
	for i in tiers:
		var k := float(i) / (tiers - 1)
		var r := lerpf(15.5, 4.0, k) + rng.randf_range(-1.2, 1.2)
		var ch := lerpf(11.0, 9.0, k)
		var leaf := mat(dark.lerp(lite, k * 0.8), "fine", 0.2, Vector3.ONE, 0.6, 0.85 if snowy else 0.0)
		mi(root, cyl(0.0, r, ch, 7 + (i % 2)), leaf, Vector3(rng.randf_range(-0.9, 0.9), h + ch / 2, rng.randf_range(-0.9, 0.9)),
			Vector3(rng.randf_range(-6, 6), rng.randf_range(0, 50), rng.randf_range(-6, 6)), Vector3(1, 1, rng.randf_range(0.85, 1.1)))
		h += lerpf(6.0, 4.5, k)
	mi(root, cyl(0.0, 1.6, 6, 6), mat(lite, "fine", 0.2, Vector3.ONE, 0.5, 0.85 if snowy else 0.0), Vector3(0, h + 5, 0))
	return root

## Broadleaf: a gnarled, forked trunk with branches and many leaf clusters.
func _leafy(v: int, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 200 + v
	var bark := mat(Color("#654429"), "streak", 0.14, Vector3(1, 5, 1), 0.6)
	mi(root, cyl(2.4, 4.4, 3, 8), bark, Vector3(0, 1.5, 0))
	mi(root, cyl(1.9, 2.6, 12, 8), bark, Vector3(0, 7.5, 0), Vector3(0, 0, rng.randf_range(-6, 6)))
	var tips: Array = []
	for i in 3: # main forks
		var a := i * TAU / 3 + rng.randf()
		var tilt := rng.randf_range(22, 38)
		var lenb := rng.randf_range(11, 15)
		var dir := Vector3(cos(a) * sin(deg_to_rad(tilt)), cos(deg_to_rad(tilt)), sin(a) * sin(deg_to_rad(tilt)))
		var tip := Vector3(0, 13, 0) + dir * lenb
		segment(root, Vector3(0, 12.5, 0), tip, 1.2, bark)
		segment(root, tip - dir * 4.0, tip + Vector3(-dir.z, 0.6, dir.x) * 5.0, 0.6, bark) # a side branch
		tips.append(tip)
	var greens := [Color("#3a7333"), Color("#4a8238"), Color("#356a30"), Color("#55893c")]
	for t in tips:
		for j in 5:
			var r := rng.randf_range(4.5, 7.0)
			var off := Vector3(rng.randf_range(-6, 6), rng.randf_range(-2, 5), rng.randf_range(-6, 6))
			var leaf := mat(greens[(j + v) % 4], "fine", 0.2, Vector3.ONE, 0.6, 0.8 if snowy else 0.0)
			mi(root, sph(r, 9, 6), leaf, t + off, Vector3(rng.randf_range(0, 40), rng.randf_range(0, 360), 0), Vector3(1, rng.randf_range(0.75, 1.0), 1))
	mi(root, sph(8, 10, 6), mat(greens[v % 4], "fine", 0.2, Vector3.ONE, 0.6, 0.8 if snowy else 0.0), Vector3(0, 30, 0), Vector3.ZERO, Vector3(1, 0.8, 1))
	return root

func _bush(full: bool, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 400
	for i in 7:
		var a := i * TAU / 7
		var leaf := mat([Color("#3b6a2e"), Color("#46763a"), Color("#33602a")][i % 3], "fine", 0.22, Vector3.ONE, 0.55, 0.8 if snowy else 0.0)
		mi(root, sph(rng.randf_range(3.5, 5.0), 8, 5), leaf, Vector3(cos(a) * 5, rng.randf_range(3.5, 6.5), sin(a) * 5))
	mi(root, sph(5.5, 9, 6), mat(Color("#41702f"), "fine", 0.22, Vector3.ONE, 0.55, 0.8 if snowy else 0.0), Vector3(0, 7, 0))
	if full:
		var berry := mat(Color("#c8283a"), "fine", 0.3, Vector3.ONE, 0.2)
		for i in 16:
			var a := i * 2.4
			mi(root, sph(1.1, 6, 4), berry, Vector3(cos(a) * rng.randf_range(5.5, 7.5), rng.randf_range(3.5, 10), sin(a) * rng.randf_range(5.5, 7.5)))
	return root

func _stump(snowy: bool) -> Node3D:
	var root := Node3D.new()
	var bark := mat(Color("#6b4a2a"), "streak", 0.2, Vector3(1, 4, 1))
	mi(root, cyl(3.4, 4.0, 5, 9), bark, Vector3(0, 2.5, 0))
	mi(root, cyl(4.0, 5.2, 1.6, 9), bark, Vector3(0, 0.8, 0))
	mi(root, cyl(3.3, 3.3, 0.4, 9), mat(Color("#c09060") if not snowy else Color("#eef2f8"), "fine", 0.5), Vector3(0, 5.1, 0))
	mi(root, cyl(0.25, 0.25, 6, 4), mat(Color("#cfc0a0"), "fine"), Vector3(4, 0.6, 2), Vector3(0, 30, 85)) # a chip of wood
	return root

func _rocks(v: int, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 300 + v
	var stone := mat(Color("#8b877d"), "coarse", 0.15, Vector3.ONE, 0.6, 0.7 if snowy else 0.0)
	var dark := mat(Color("#6f6b62"), "coarse", 0.15, Vector3.ONE, 0.6, 0.7 if snowy else 0.0)
	var moss := mat(Color("#5d7a3a"), "fine", 0.3, Vector3.ONE, 0.5, 0.7 if snowy else 0.0)
	for i in 3 + v:
		var sc := rng.randf_range(4, 8.5)
		var pos := Vector3(rng.randf_range(-9, 9), sc * 0.45, rng.randf_range(-7, 7))
		mi(root, sph(sc, 6, 4), stone if i % 2 == 0 else dark, pos, Vector3(rng.randf_range(0, 60), rng.randf_range(0, 360), 0), Vector3(1.0, rng.randf_range(0.6, 1.0), rng.randf_range(0.7, 1.2)))
		if i % 2 == 1: mi(root, sph(sc * 0.55, 6, 3), moss, pos + Vector3(0, sc * 0.45, 0), Vector3.ZERO, Vector3(1, 0.3, 1))
	for i in 5: # pebbles
		mi(root, sph(rng.randf_range(0.8, 1.6), 5, 3), stone, Vector3(rng.randf_range(-13, 13), 0.4, rng.randf_range(-10, 10)))
	return root

# ---- village props (placed beside homes)
func _woodpile(parent: Node3D, pos: Vector3, yaw := 0.0) -> void:
	var pile := Node3D.new()
	pile.position = pos
	pile.rotation_degrees.y = yaw
	parent.add_child(pile)
	var lg := mat(Color("#6e4b2a"), "streak", 0.25, Vector3(4, 1, 1), 0.5)
	var end := mat(Color("#c8a070"), "fine", 0.4, Vector3.ONE, 0.3)
	for row in 3:
		for i in 4 - row:
			var p := Vector3(-3.6 + i * 2.4 + row * 1.2, 1.1 + row * 2.0, 0)
			mi(pile, cyl(1.1, 1.1, 9, 7), lg, p, Vector3(90, 0, 0))
			mi(pile, cyl(1.0, 1.0, 0.2, 7), end, p + Vector3(0, 0, 4.55), Vector3(90, 0, 0))

func _pot(parent: Node3D, pos: Vector3, sc := 1.0) -> void:
	var clay := mat(Color("#a8623a"), "fine", 0.3, Vector3.ONE, 0.35)
	mi(parent, sph(2.2 * sc, 9, 6), clay, pos + Vector3(0, 2.0 * sc, 0), Vector3.ZERO, Vector3(1, 0.95, 1))
	mi(parent, cyl(1.1 * sc, 1.3 * sc, 1.4 * sc, 9), clay, pos + Vector3(0, 4.2 * sc, 0))
	mi(parent, cyl(1.5 * sc, 1.2 * sc, 0.5 * sc, 9), mat(Color("#8a4a2a"), "fine", 0.3), pos + Vector3(0, 5.0 * sc, 0))

func _drying_rack(parent: Node3D, pos: Vector3, yaw: float) -> void:
	var rack := Node3D.new()
	rack.position = pos
	rack.rotation_degrees.y = yaw
	parent.add_child(rack)
	var wood := mat(Color("#6b4524"), "streak", 0.25, Vector3(1, 4, 1))
	for side in [-1, 1]: mi(rack, cyl(0.45, 0.5, 11, 5), wood, Vector3(side * 5, 5.5, 0))
	mi(rack, cyl(0.4, 0.4, 11, 5), wood, Vector3(0, 10.5, 0), Vector3(0, 0, 90))
	mi(rack, box(Vector3(8, 7, 0.4)), mat(Color("#c09a6a"), "coarse", 0.3, Vector3.ONE, 0.5), Vector3(0, 6.8, 0), Vector3(0, 0, 4)) # a stretched hide

## Thatch tufts hanging round an eave (small downward cones).
func _fringe(parent: Node3D, y: float, r: float, n: int, col: Color, snowy: bool) -> void:
	var m := mat(col.darkened(0.12), "streak", 0.3, Vector3(1, 4, 1), 0.5, 0.4 if snowy else 0.0)
	for i in n:
		var a := (i + 0.5) * TAU / n
		mi(parent, cyl(1.5, 0.0, 4.0, 5), m, Vector3(cos(a) * r, y - 1.5, sin(a) * r), Vector3(0, -rad_to_deg(a), 0))

# ---- homes
func _tent(big: bool, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var r := 22.0 if big else 17.0
	var h := 36.0 if big else 30.0
	var hide := mat(Color("#b48a5c"), "coarse", 0.1, Vector3(1, 3, 1), 0.45, 0.6 if snowy else 0.0)
	var seam := mat(Color("#7a5a38"), "fine", 0.3)
	mi(root, cyl(0.6, r, h, 10), hide, Vector3(0, h / 2, 0))
	for i in 5: # sewn seams running up the hide panels
		var a := (i + 0.5) * TAU / 5
		segment(root, Vector3(cos(a) * (r + 0.3), 0.2, sin(a) * (r + 0.3)), Vector3(0, h - 0.5, 0), 0.35, seam)
	var pole := mat(Color("#5e3d22"), "streak", 0.2, Vector3(1, 4, 1))
	for i in 6:
		var a := i * TAU / 6
		mi(root, cyl(0.5, 0.6, 13, 5), pole, Vector3(cos(a) * 1.6, h + 3.5, sin(a) * 1.6), Vector3(rad_to_deg(sin(a)) * 0.4, 0, -rad_to_deg(cos(a)) * 0.4))
	# open door flap and stones weighing down the hem
	mi(root, box(Vector3(8, h * 0.45, 1.0)), mat(Color("#2a1a0e"), "fine"), Vector3(0, h * 0.22, r * 0.74), Vector3(-30, 0, 0))
	mi(root, box(Vector3(5, h * 0.4, 0.6)), hide, Vector3(5, h * 0.2, r * 0.8), Vector3(-30, 25, -10))
	var stone := mat(Color("#8b877d"), "coarse", 0.25, Vector3.ONE, 0.5, 0.6 if snowy else 0.0)
	for i in 12:
		var a := i * TAU / 12 + 0.2
		if absf(a - PI / 2) < 0.4: continue
		mi(root, sph(1.6, 6, 4), stone, Vector3(cos(a) * (r + 0.6), 0.8, sin(a) * (r + 0.6)), Vector3.ZERO, Vector3(1, 0.7, 1))
	_drying_rack(root, Vector3(-r - 6, 0, 4), 70)
	_woodpile(root, Vector3(r + 2, 0, -8), 20)
	return root

func _round_hut(big: bool, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var r := 25.0 if big else 19.0
	var wall := mat(Color("#9b7a52"), "coarse", 0.12, Vector3.ONE, 0.55)
	var post := mat(Color("#6b4524"), "streak", 0.2, Vector3(1, 4, 1), 0.5)
	var thatch_col := Color("#b8944c")
	var thatch := mat(thatch_col, "streak", 0.2, Vector3(1, 6, 1), 0.65, 0.85 if snowy else 0.0)
	var wh := 13.0 if big else 11.0
	var rh := 31.0 if big else 25.0
	mi(root, cyl(r, r + 0.6, wh, 18), wall, Vector3(0, wh / 2, 0))
	mi(root, cyl(r + 0.8, r + 1.0, 1.4, 18), mat(Color("#7a6040"), "coarse", 0.2), Vector3(0, 0.7, 0)) # plinth
	for i in 10: # wall posts
		var a := i * TAU / 10 + 0.15
		mi(root, cyl(0.8, 0.9, wh + 1, 5), post, Vector3(cos(a) * (r + 0.3), wh / 2, sin(a) * (r + 0.3)))
	# two-layer thatch with a fringe at the eave and a bound knot over the smoke hole
	mi(root, cyl(r * 0.55, r * 1.24, rh * 0.6, 18), thatch, Vector3(0, wh + rh * 0.3, 0))
	mi(root, cyl(0.6, r * 0.62, rh * 0.5, 16), mat(thatch_col.lightened(0.06), "streak", 0.2, Vector3(1, 6, 1), 0.65, 0.85 if snowy else 0.0), Vector3(0, wh + rh * 0.6 + rh * 0.23, 0))
	_fringe(root, wh + 0.2, r * 1.22, 26, thatch_col, snowy)
	var rib := mat(thatch_col.darkened(0.3), "streak", 0.3, Vector3(1, 4, 1), 0.4, 0.5 if snowy else 0.0)
	for i in 16: # bundle ribs down the roof
		var a := (i + 0.5) * TAU / 16
		segment(root, Vector3(cos(a) * r * 1.2, wh + 0.8, sin(a) * r * 1.2), Vector3(cos(a) * 1.0, wh + rh * 0.98, sin(a) * 1.0), 0.45, rib)
	mi(root, cyl(1.2, 1.8, 3.5, 7), mat(Color("#8a6a30"), "streak", 0.3, Vector3(1, 3, 1)), Vector3(0, wh + rh * 1.06, 0))
	mi(root, cyl(1.9, 1.9, 0.8, 7), post, Vector3(0, wh + rh * 1.0, 0))
	# door: posts, lintel and a hide curtain
	var door_a := deg_to_rad(45.0) # faces the camera
	var dpos := Vector3(cos(door_a) * (r + 0.4), 0, sin(door_a) * (r + 0.4))
	var door := Node3D.new()
	door.position = dpos
	door.rotation_degrees.y = -rad_to_deg(door_a) + 90
	root.add_child(door)
	mi(door, box(Vector3(6.5, 9.5, 2.0)), mat(Color("#1e140a"), "fine"), Vector3(0, 4.75, 0.2))
	for side in [-1, 1]: mi(door, cyl(0.6, 0.6, 10, 5), post, Vector3(side * 3.8, 5, 0.6))
	mi(door, cyl(0.55, 0.55, 9, 5), post, Vector3(0, 10, 0.6), Vector3(0, 0, 90))
	mi(door, box(Vector3(3.2, 7.5, 0.3)), mat(Color("#a07a50"), "coarse", 0.3, Vector3.ONE, 0.4), Vector3(-1.4, 5.2, 0.9), Vector3(0, 0, -6))
	_woodpile(root, Vector3(r * 0.85, 0, -r * 0.6), 40)
	_pot(root, Vector3(-r * 0.2, 0, r + 4))
	_pot(root, Vector3(-r * 0.2 - 4.5, 0, r + 2.5), 0.8)
	return root

func _longhouse(big: bool, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var r := 26.0 if big else 20.0
	var length := r * 2.5
	var depth := r * 1.4
	var stone := mat(Color("#8f8b82"), "coarse", 0.2, Vector3.ONE, 0.6, 0.5 if snowy else 0.0)
	var stone2 := mat(Color("#7a766e"), "coarse", 0.2, Vector3.ONE, 0.6, 0.5 if snowy else 0.0)
	var plank_a := mat(Color("#8a5f3a"), "streak", 0.16, Vector3(1, 6, 1), 0.55)
	var plank_b := mat(Color("#7a5232"), "streak", 0.16, Vector3(1, 6, 1), 0.55)
	var beam := mat(Color("#5a3a20"), "streak", 0.16, Vector3(6, 1, 1), 0.5)
	var roof_col := Color("#9c7a3e")
	var roof := mat(roof_col, "streak", 0.18, Vector3(1, 1, 6), 0.6, 0.9 if snowy else 0.0)
	# footing of individual stones
	mi(root, box(Vector3(length + 4, 3, depth + 4)), stone2, Vector3(0, 1.5, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 55
	for side in [-1, 1]:
		for i in int(length / 5.5):
			var x := -length / 2 + 2.5 + i * 5.5
			mi(root, sph(2.8, 6, 4), stone if i % 2 == 0 else stone2, Vector3(x, 3.4, side * (depth / 2 + 2.2)), Vector3(0, rng.randf_range(0, 90), 0), Vector3(1.1, 0.7, 0.9))
	# vertical plank walls with corner posts and a sill beam
	mi(root, box(Vector3(length - 1, 14, depth - 1)), plank_b, Vector3(0, 11.5, 0))
	var n := int(length / 3.4)
	for side in [-1, 1]:
		for i in n:
			var x := -length / 2 + 1.7 + i * 3.4
			mi(root, box(Vector3(3.1, 14, 0.9)), plank_a if i % 2 == 0 else plank_b, Vector3(x, 11.5, side * depth / 2), Vector3(0, 0, rng.randf_range(-0.8, 0.8)))
		mi(root, box(Vector3(length + 1, 1.4, 1.6)), beam, Vector3(0, 5, side * (depth / 2 + 0.3)))
	for sx in [-1, 1]:
		for sz in [-1, 1]: mi(root, box(Vector3(2.4, 16, 2.4)), beam, Vector3(sx * length / 2, 12.5, sz * depth / 2))
	# roof: thatch prism with overhang, ridge beam, fringes along both eaves, crossed gable horns
	var pr := PrismMesh.new()
	pr.size = Vector3(depth + 10, 21, length + 9)
	mi(root, pr, roof, Vector3(0, 29, 0), Vector3(0, 90, 0))
	mi(root, cyl(1.0, 1.0, length + 10, 6), beam, Vector3(0, 39.6, 0), Vector3(0, 0, 90))
	var fringe := mat(roof_col.darkened(0.12), "streak", 0.3, Vector3(1, 4, 1), 0.5, 0.4 if snowy else 0.0)
	for side in [-1, 1]:
		for i in int((length + 8) / 3.0):
			mi(root, cyl(1.4, 0.0, 3.5, 5), fringe, Vector3(-length / 2 - 4 + i * 3.0, 17.5, side * (depth / 2 + 5)))
	var red := mat(Color("#b03a2b"), "fine", 0.2)
	for side in [-1, 1]:
		mi(root, box(Vector3(1.6, 12, 1.6)), red, Vector3(side * (length / 2 + 4), 41, 3), Vector3(30, 0, 0))
		mi(root, box(Vector3(1.6, 12, 1.6)), red, Vector3(side * (length / 2 + 4), 41, -3), Vector3(-30, 0, 0))
	# door with frame, shuttered windows, props
	mi(root, box(Vector3(8, 11, 1.2)), mat(Color("#2a1a0e"), "fine"), Vector3(0, 10, depth / 2 + 0.7))
	for side in [-1, 1]: mi(root, box(Vector3(1.2, 12, 1.4)), beam, Vector3(side * 4.6, 10.5, depth / 2 + 0.9))
	mi(root, box(Vector3(10.4, 1.4, 1.6)), beam, Vector3(0, 16.2, depth / 2 + 0.9))
	for wx in [-length * 0.3, length * 0.3]:
		mi(root, box(Vector3(5, 4, 0.8)), mat(Color("#1e140a"), "fine"), Vector3(wx, 13, depth / 2 + 0.6))
		mi(root, box(Vector3(2.5, 4.2, 0.4)), plank_a, Vector3(wx - 3.6, 13, depth / 2 + 1.1), Vector3(0, 35, 0))
	_woodpile(root, Vector3(length / 2 + 7, 0, 4), 90)
	_pot(root, Vector3(-length * 0.35, 0, depth / 2 + 5), 1.1)
	_pot(root, Vector3(-length * 0.35 + 5, 0, depth / 2 + 6), 0.85)
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

# ---- construction sites
## Stage 0: staked plan; 1: foundation and materials on site; 2: frame (posts, beams,
## rafters); 3: lower walls going up, scaffold and ladder.
func _site(shape: String, r: float, stage: int) -> Node3D:
	var root := Node3D.new()
	var stake := mat(Color("#c8a46a"), "streak", 0.3, Vector3(1, 4, 1), 0.4)
	var string_m := mat(Color("#e8dcc0"), "fine", 0.5, Vector3.ONE, 0.1)
	var post := mat(Color("#6e4a2a"), "streak", 0.2, Vector3(1, 5, 1), 0.5)
	var beam := mat(Color("#5e3e22"), "streak", 0.2, Vector3(5, 1, 1), 0.5)
	var wall := mat(Color("#9b7a52"), "coarse", 0.12, Vector3.ONE, 0.55)
	var plank := mat(Color("#8a5f3a"), "streak", 0.16, Vector3(1, 6, 1), 0.55)
	var wh := 11.0 if r < 22 else 13.0
	var corners: Array = [] # footprint outline points on the ground
	if shape == "round":
		for i in 12:
			var a := i * TAU / 12
			corners.append(Vector3(cos(a) * r, 0, sin(a) * r))
	else:
		var hl := r * 1.25
		var hd := r * 0.7
		corners = [Vector3(-hl, 0, -hd), Vector3(0, 0, -hd), Vector3(hl, 0, -hd), Vector3(hl, 0, hd), Vector3(0, 0, hd), Vector3(-hl, 0, hd)]
	# stakes and string lines (every stage)
	for i in corners.size():
		var c: Vector3 = corners[i]
		mi(root, cyl(0.5, 0.6, 5, 5), stake, c + Vector3(0, 2.5, 0))
		segment(root, c + Vector3(0, 2.6, 0), corners[(i + 1) % corners.size()] + Vector3(0, 2.6, 0), 0.2, string_m)
	if stage >= 1: # levelled ground, timber and stone delivered
		var floor_m := mat(Color("#8c7650"), "coarse", 0.15, Vector3.ONE, 0.5)
		if shape == "round": mi(root, cyl(r * 0.95, r, 0.8, 16), floor_m, Vector3(0, 0.4, 0))
		else: mi(root, box(Vector3(r * 2.4, 0.8, r * 1.3)), floor_m, Vector3(0, 0.4, 0))
		_woodpile(root, Vector3(r + 7, 0, r * 0.4), 80)
		var stone := mat(Color("#8b877d"), "coarse", 0.25, Vector3.ONE, 0.5)
		for i in 6: mi(root, sph(1.8, 6, 4), stone, Vector3(-r * 0.3 + (i % 3) * 3.2, 1.2 + (i / 3) * 2.2, r + 6), Vector3.ZERO, Vector3(1, 0.7, 1))
	if stage >= 2: # frame
		if shape == "round":
			var apex := Vector3(0, wh + r * 1.2, 0)
			var tops: Array = []
			for i in 10:
				var a := i * TAU / 10
				var base := Vector3(cos(a) * r, 0, sin(a) * r)
				mi(root, cyl(1.1, 1.2, wh, 6), post, base + Vector3(0, wh / 2, 0))
				tops.append(base + Vector3(0, wh, 0))
			for i in tops.size():
				segment(root, tops[i], tops[(i + 1) % tops.size()], 0.85, beam)
				if stage == 2 or i % 2 == 0: segment(root, tops[i], apex, 0.75, beam)
		else:
			var hl := r * 1.25
			var hd := r * 0.7
			var ridge := 14.0 + r * 0.9
			for x in [-hl, -hl / 2, 0.0, hl / 2, hl]:
				for z in [-hd, hd]:
					mi(root, cyl(1.2, 1.3, 14, 6), post, Vector3(x, 7, z))
			for z in [-hd, hd]: segment(root, Vector3(-hl, 14, z), Vector3(hl, 14, z), 1.0, beam)
			for x in [-hl, 0.0, hl]:
				segment(root, Vector3(x, 14, -hd), Vector3(x, ridge, 0), 0.8, beam)
				segment(root, Vector3(x, 14, hd), Vector3(x, ridge, 0), 0.8, beam)
			segment(root, Vector3(-hl, ridge, 0), Vector3(hl, ridge, 0), 0.9, beam)
	if stage >= 3: # lower walls, scaffold and a ladder
		if shape == "round":
			var wall_part := cyl(r - 0.2, r, wh * 0.55, 16)
			mi(root, wall_part, wall, Vector3(0, wh * 0.275, 0))
		else:
			var hl := r * 1.25
			var hd := r * 0.7
			for z in [-hd, hd]:
				for i in int(hl * 2 / 3.4):
					var x := -hl + 1.7 + i * 3.4
					mi(root, box(Vector3(3.1, 7.5, 0.9)), plank, Vector3(x, 3.75, z))
		var sx := r + 3.0
		for zz in [-5.0, 5.0]: mi(root, cyl(0.45, 0.5, wh + 2, 5), stake, Vector3(sx, (wh + 2) / 2, zz))
		mi(root, box(Vector3(4, 0.6, 12)), plank, Vector3(sx - 1.5, wh * 0.7, 0))
		segment(root, Vector3(sx + 6, 0, 3), Vector3(sx + 1, wh * 0.7, 3), 0.35, stake)
		segment(root, Vector3(sx + 6, 0, -1), Vector3(sx + 1, wh * 0.7, -1), 0.35, stake)
		for i in 4:
			var k := (i + 1) / 5.0
			segment(root, Vector3(sx + 6 - 5 * k, wh * 0.7 * k, 3), Vector3(sx + 6 - 5 * k, wh * 0.7 * k, -1), 0.25, stake)
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
	var band := mat(Color("#5a3a20"), "streak", 0.3, Vector3(1, 4, 1))
	for y in [12.5, 23.5]: mi(root, cyl(15.3, 15.3, 1.0, 16), band, Vector3(0, y, 0))
	_fringe(root, 25.5, 16.5, 22, Color("#a7703f"), snowy)
	segment(root, Vector3(3, 0, 22), Vector3(1, 12, 16), 0.5, wood) # ladder rails
	segment(root, Vector3(-2, 0, 22), Vector3(-4, 12, 16), 0.5, wood)
	for i in 4: segment(root, Vector3(2.6 - i * 0.5, 2 + i * 2.8, 21.4 - i * 1.4), Vector3(-2.4 - i * 0.5, 2 + i * 2.8, 21.4 - i * 1.4), 0.35, wood)
	_pot(root, Vector3(-16, 0, 8), 1.0)
	_pot(root, Vector3(-19, 0, 3), 0.8)
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
func _beast(kind: String, yaw: float, phase: float, walking: bool, anim := "") -> Node3D:
	var holder := Node3D.new()
	holder.rotation_degrees.y = yaw
	var root := Node3D.new()
	holder.add_child(root)
	var lunge := 0.0
	if anim == "attack": # crouch, then spring forward with forelegs up
		lunge = [0.0, 0.3, 1.0, 0.6][int(phase * 4) % 4]
		root.position.z = lunge * 5.0
		root.rotation_degrees.x = -lunge * 18.0
	elif anim == "dead": # lying on its side
		root.rotation_degrees.z = 88.0
		root.position.y = 1.0
	var spec: Dictionary = {
		"deer": {"col": Color("#9a6a3c"), "belly": Color("#d8c09a"), "blen": 17.0, "r": 4.6, "leg": 11.0, "neck": 7.0, "head": 3.2},
		"tiger": {"col": Color("#d98a2b"), "belly": Color("#f2d6a8"), "blen": 22.0, "r": 6.0, "leg": 9.0, "neck": 3.0, "head": 5.0},
		"wolf": {"col": Color("#7a7a80"), "belly": Color("#b4b4ba"), "blen": 16.0, "r": 4.2, "leg": 8.5, "neck": 3.0, "head": 3.6},
		"aurochs": {"col": Color("#3d2a1c"), "belly": Color("#5a4232"), "blen": 20.0, "r": 6.5, "leg": 8.0, "neck": 2.0, "head": 4.6},
		"packox": {"col": Color("#4a3322"), "belly": Color("#6a5240"), "blen": 16.0, "r": 5.2, "leg": 6.5, "neck": 2.0, "head": 3.8},
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
	if anim == "attack": sw = 0.0
	for i in 4:
		var front := i < 2
		var side := -1 if i % 2 == 0 else 1
		var hip := Node3D.new()
		hip.position = Vector3(side * spec["r"] * 0.55, leg_h, blen * (0.32 if front else -0.32))
		hip.rotation_degrees.x = sw * (1 if (i == 0 or i == 3) else -1)
		if anim == "attack" and front: hip.rotation_degrees.x = -55.0 * lunge
		if anim == "dead": hip.rotation_degrees.x = 25.0 if front else -25.0
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
		"aurochs", "packox":
			var horn := mat(Color("#e8dcc0"), "fine", 0.3)
			for side in [-1, 1]: mi(neck, cyl(0.3, 0.8, 6, 5), horn, head_pos + Vector3(side * 3.5, 2.5, 0), Vector3(0, 0, side * -70))
	if kind == "packox": # bundles slung over its back
		var hide2 := mat(Color("#a0784a"), "coarse", 0.3, Vector3.ONE, 0.5)
		mi(root, box(Vector3(spec["r"] * 2.6, 4.5, blen * 0.45)), hide2, Vector3(0, body_y + spec["r"] * 0.8, -1))
		for side in [-1, 1]: mi(root, cyl(1.6, 1.6, blen * 0.4, 7), mat(Color("#6e4b2a"), "streak", 0.3, Vector3(4, 1, 1)), Vector3(side * spec["r"] * 1.2, body_y + 1, -1), Vector3(90, 0, 0))
	var tail_len := 10.0 if kind == "tiger" else (3.0 if kind == "deer" else 7.0)
	mi(root, cyl(0.5, 1.0, tail_len, 5), hide, Vector3(0, body_y + 1, -blen * 0.5 - tail_len * 0.4), Vector3(-60 + (sin(phase * TAU) * 10.0 if walking else 0.0), 0, 0))
	return holder

# ---- people
## A villager in a pose. cloth_only renders the tunic white and everything else black
## so the game can tint the clothes per person.
func _person(yaw: float, anim: String, phase: float, cloth_only: bool, tool := "stone") -> Node3D:
	var holder := Node3D.new()
	holder.rotation_degrees.y = yaw
	var root := Node3D.new()
	holder.add_child(root)
	var skin: Material = mat(Color("#d29e74"), "fine", 0.4, Vector3.ONE, 0.15)
	var hair: Material = mat(Color("#2b1a0e"), "fine", 0.5, Vector3.ONE, 0.3)
	var cloth: Material = mat(Color("#d8d4cc") if not cloth_only else Color(1, 1, 1), "coarse", 0.4, Vector3.ONE, 0.35)
	var fur: Material = mat(Color("#7a5a3a"), "fine", 0.5, Vector3.ONE, 0.4)
	var wood: Material = mat(Color("#6b4524"), "streak", 0.4, Vector3(1, 4, 1))
	var head_m: Material = mat(Color("#8d8d93"), "coarse", 0.5) if tool == "stone" else mat(Color("#d49a3a"), "fine", 0.4, Vector3.ONE, 0.3)
	if cloth_only:
		var black := flat(Color.BLACK)
		skin = black
		hair = black
		fur = black
		wood = black
		head_m = black
	var k := int(phase * 4) % 4 # frame index for 4-frame actions
	var swing := 0.0 # legs
	var arm_l := 0.0
	var arm_r := 0.0
	var spread := 0.0 # arms out to the sides
	var tilt := 0.0 # upper body leaning forward
	var bob := 0.0
	var held := "" # tool in the right hand
	match anim:
		"walk":
			swing = sin(phase * TAU) * 30.0
			arm_l = -swing * 0.8
			arm_r = swing * 0.8
			bob = absf(sin(phase * TAU)) * 0.8
		"chop": # overhead swing with an axe
			arm_r = [-150.0, -95.0, -10.0, 25.0][k]
			arm_l = -20.0
			tilt = [0.0, 6.0, 16.0, 20.0][k]
			held = "axe"
		"build": # crouched hammering with a mallet
			arm_r = [-100.0, -60.0, -20.0, -45.0][k]
			arm_l = -40.0
			tilt = 25.0
			swing = 12.0
			held = "mallet"
		"gather": # bending low, hands reaching into the bush
			tilt = 38.0
			arm_r = [-40.0, -70.0, -50.0, -25.0][k]
			arm_l = [-70.0, -40.0, -25.0, -50.0][k]
		"attack": # spear: draw back, thrust
			arm_r = [-40.0, -10.0, -95.0, -80.0][k]
			arm_l = -55.0
			tilt = [-5.0, -8.0, 14.0, 10.0][k]
			swing = [8.0, 12.0, -10.0, -6.0][k]
			held = "spear"
		"ritual": # arms raised to the sky, swaying
			arm_r = -165.0 + sin(phase * TAU) * 15.0
			arm_l = -165.0 - sin(phase * TAU) * 15.0
			spread = 18.0
			bob = absf(sin(phase * TAU)) * 1.2
		"dead":
			root.rotation_degrees.x = 86.0 # face down on the ground
			root.position = Vector3(0, 3.5, -12)
			arm_r = -150.0
			arm_l = -120.0
	var body := Node3D.new()
	body.position.y = bob
	root.add_child(body)
	for side in [-1, 1]: # legs swing at the hip
		var hip := Node3D.new()
		hip.position = Vector3(side * 1.8, 11, 0)
		hip.rotation_degrees.x = swing * side if anim != "build" else -swing
		body.add_child(hip)
		mi(hip, cap(1.5, 11), skin, Vector3(0, -5.5, 0))
	mi(body, cyl(3.4, 4.6, 6, 10), cloth, Vector3(0, 10.5, 0)) # skirt
	mi(body, cyl(3.7, 3.7, 1.0, 10), mat(Color("#5a3a20"), "fine") if not cloth_only else flat(Color.BLACK), Vector3(0, 12.8, 0)) # belt
	var upper := Node3D.new() # everything above the hips bends forward
	upper.position.y = 12.0
	upper.rotation_degrees.x = tilt
	body.add_child(upper)
	mi(upper, cap(3.6, 12), cloth, Vector3(0, 4, 0), Vector3.ZERO, Vector3(1.05, 1, 0.8))
	mi(upper, cyl(4.2, 4.6, 2.2, 10), fur, Vector3(0, 9, 0), Vector3.ZERO, Vector3(1, 1, 0.85))
	mi(upper, sph(3.3, 12, 8), skin, Vector3(0, 13.3, 0))
	mi(upper, sph(3.5, 10, 6), hair, Vector3(0, 14.2, -0.6), Vector3(-15, 0, 0), Vector3(1, 0.8, 1))
	for side in [-1, 1]: # arms swing at the shoulder
		var sh := Node3D.new()
		sh.position = Vector3(side * 4.6, 8.5, 0)
		sh.rotation_degrees = Vector3(arm_r if side > 0 else arm_l, 0, side * spread)
		upper.add_child(sh)
		mi(sh, cap(1.2, 9.5), skin, Vector3(0, -4.5, 0))
		if side > 0:
			match held:
				"axe":
					mi(sh, cyl(0.45, 0.45, 9, 5), wood, Vector3(0, -9, 3), Vector3(90, 0, 0))
					mi(sh, box(Vector3(1.2, 2.6, 3.2)), head_m, Vector3(0, -9, 7.2))
				"mallet":
					mi(sh, cyl(0.4, 0.4, 6, 5), wood, Vector3(0, -9, 2), Vector3(90, 0, 0))
					mi(sh, cyl(1.3, 1.3, 3.2, 7), head_m, Vector3(0, -9, 5.2))
				"spear": # counter-rotated so the spear stays level, pointing forward
					var grip := Node3D.new()
					grip.position = Vector3(0, -9, 0)
					grip.rotation_degrees.x = -(arm_r + tilt)
					sh.add_child(grip)
					mi(grip, cyl(0.35, 0.35, 26, 5), wood, Vector3(0, 0, 3), Vector3(90, 0, 0))
					mi(grip, cyl(0.0, 0.9, 3.6, 5), head_m, Vector3(0, 0, 17.5), Vector3(90, 0, 0))
	return holder
