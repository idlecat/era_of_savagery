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

const ART_VERSION := 28
const BAKE_SCALE := 2.0
const PPU := 1.06066 * BAKE_SCALE
const CACHE_DIR := "user://art_cache_v%d" % ART_VERSION
## Villagers (and their clothes) are the sprites drawn many times a frame: a town has hundreds
## of them on screen. Each baked sprite is its own texture, and a texture change ends a 2D batch,
## so they are packed into an atlas (one texture for the lot) and drawn with
## draw_texture_rect_region(): Godot then batches them into a few draw calls. The gutter and the
## cell alignment keep the atlas's mipmaps from mixing one sprite with its neighbour (bleeding):
## every cell starts on an ALIGN-px boundary (mip level 3's 8x8 blocks never straddle cells) and
## each sprite's border pixels are repeated outward into the gutter, so a sample that falls just
## outside a sprite reads that sprite's own edge, not the next one.
const ATLAS_PREFIX := "man_"
const ATLAS_PAD := 8 # gutter px either side (enough for the mip levels a villager is drawn at)
const ATLAS_ALIGN := 8
const ATLAS_MAX := 4096
const ATLAS_INDEX := "atlas_man.json"
const DIRS := 8
const WALK_FRAMES := 8
const WORK_FRAMES := 4
## Villager animations: name -> frames. Tool animations also bake a bronze variant.
const MAN_ANIMS := {"idle": 1, "walk": 8, "chop": 4, "build": 4, "gather": 4, "attack": 4, "ritual": 4, "dead": 1, "sit": 2, "talk": 4}
const TOOL_ANIMS := ["chop", "build", "attack"]
## The attack animation again for each weapon besides the spear (arms.gd ids): keys
## man_attack_<weapon>_<dir>_<frame>; those in BRONZE_WEAPONS also with a bronze head.
const WEAPON_ANIMS := ["club", "axe", "sling", "bow"]
const BRONZE_WEAPONS := ["axe"]
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
	var packed := _load_atlas(idx) # (the villagers' atlas, if there is one: 1088 PNGs not worth reading)
	var man_imgs := {}
	for key in idx:
		if packed and key.begins_with(ATLAS_PREFIX): continue
		var img := Image.load_from_file(CACHE_DIR + "/" + key + ".png")
		if img == null: return false
		if key.begins_with(ATLAS_PREFIX):
			man_imgs[key] = img # (packed below, once all of them are in)
			continue
		img.generate_mipmaps()
		sprites[key] = {"tex": ImageTexture.create_from_image(img), "anchor": Vector2(idx[key][0], idx[key][1])}
	if not packed and not man_imgs.is_empty(): _pack_atlas(man_imgs, idx, true) # (and keep it for the next launch)
	return true

func _save_cache() -> void:
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	var idx := {}
	var man_imgs := {}
	for key in sprites: # (the villagers' images are packed into the atlas below, before they are let go)
		var img: Image = sprites[key]["img"]
		img.save_png(CACHE_DIR + "/" + key + ".png")
		idx[key] = [sprites[key]["anchor"].x, sprites[key]["anchor"].y]
		if key.begins_with(ATLAS_PREFIX): man_imgs[key] = img
		else: sprites[key].erase("img")
	var f := FileAccess.open(CACHE_DIR + "/index.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(idx))
	if not man_imgs.is_empty():
		_pack_atlas(man_imgs, idx, true) # (and keep it for the next launch)
		for key in man_imgs: sprites[key].erase("img")
	# remove caches from older ART_VERSIONs
	var ud := DirAccess.open("user://")
	if ud:
		for d in ud.get_directories():
			if d.begins_with("art_cache_v") and "user://" + d != CACHE_DIR:
				var old := DirAccess.open("user://" + d)
				if old:
					for fn in old.get_files(): old.remove(fn)
				ud.remove(d)

# ------------------------------------------------------------ the villagers' atlas
## The saved atlas, if it holds every villager of this index (its own file, so 1088 PNGs are not
## read at all): {pages: [png names], keys: {key: [page, x, y, w, h]}}.
func _load_atlas(idx: Dictionary) -> bool:
	var f := FileAccess.open(CACHE_DIR + "/" + ATLAS_INDEX, FileAccess.READ)
	if f == null: return false
	var at = JSON.parse_string(f.get_as_text())
	if not (at is Dictionary) or not at.get("keys") is Dictionary: return false
	var keys: Dictionary = at["keys"]
	var have := 0
	for key in idx:
		if not key.begins_with(ATLAS_PREFIX): continue
		have += 1
		if not keys.has(key): return false
	if keys.size() != have: return false
	var pages: Array = []
	for name in at.get("pages", []):
		var img := Image.load_from_file(CACHE_DIR + "/" + str(name))
		if img == null: return false
		img.generate_mipmaps() # (a PNG holds the full image only: the mips are made from the extruded edges)
		pages.append(ImageTexture.create_from_image(img))
	if pages.is_empty(): return false
	for key in keys:
		var e: Array = keys[key]
		sprites[key] = {"tex": pages[int(e[0])], "region": Rect2(float(e[1]), float(e[2]), float(e[3]), float(e[4])), "anchor": Vector2(idx[key][0], idx[key][1])}
	return true

static func _aligned(n: int) -> int: return ceili(float(n) / ATLAS_ALIGN) * ATLAS_ALIGN

## Pack the villagers' images into as few atlas pages as they need (shelves, in the order given),
## each wrapped in its gutter with its border pixels repeated into it, mipmapped, and remember
## where each one lies. With `save`, the pages and their index go to the cache for the next launch.
func _pack_atlas(imgs: Dictionary, idx: Dictionary, save := false) -> void:
	var cells := {}
	var area := 0
	for key in imgs:
		var im: Image = imgs[key]
		var c := [_aligned(im.get_width() + 2 * ATLAS_PAD), _aligned(im.get_height() + 2 * ATLAS_PAD)]
		cells[key] = c
		area += int(c[0]) * int(c[1])
	var width := mini(ATLAS_MAX, maxi(1024, _aligned(ceili(sqrt(float(area))))))
	# shelves: each page has one open shelf {y, h} at its bottom; a cell goes on it if it is narrow
	# enough for the width and short enough for the shelf, else the next shelf (or a new page) is opened
	var pages := [] # [{y: shelf top, h: shelf height, x: next free x, used: filled height}]
	var places := {} # key -> [page, x, y] (the cell's corner, its gutter included)
	for key in imgs:
		var cw: int = cells[key][0]
		var ch: int = cells[key][1]
		var done := false
		while not done:
			if pages.is_empty(): pages.append({"y": 0, "h": ch, "x": 0, "used": 0})
			var pg: Dictionary = pages[-1]
			if pg["h"] == 0: # (a page with no shelf opened yet)
				pg["h"] = ch
				pg["y"] = pg["used"]
			if pg["h"] >= ch and pg["x"] + cw <= width and pg["y"] + pg["h"] <= ATLAS_MAX:
				places[key] = [pages.size() - 1, pg["x"], pg["y"]]
				pg["x"] += cw
				pg["used"] = maxi(int(pg["used"]), int(pg["y"]) + int(pg["h"]))
				done = true
				continue
			var ny: int = pg["y"] + pg["h"] # (close the shelf)
			if ny + ch <= ATLAS_MAX:
				pg["used"] = ny
				pg["y"] = ny
				pg["h"] = ch
				pg["x"] = 0
				continue
			pages.append({"y": 0, "h": ch, "x": 0, "used": 0}) # (this page is full)
	# how tall each page came out, then the images themselves
	for pg in pages: pg["img"] = Image.create(width, maxi(pg["used"], 8), false, Image.FORMAT_RGBA8)
	for key in imgs:
		var im: Image = imgs[key]
		var p: Array = places[key]
		var dst: Image = pages[int(p[0])]["img"]
		var w := im.get_width()
		var h := im.get_height()
		var x: int = p[1] + ATLAS_PAD
		var y: int = p[2] + ATLAS_PAD
		dst.blit_rect(im, Rect2i(0, 0, w, h), Vector2i(x, y))
		for i in ATLAS_PAD: # the border rows and columns, repeated outward (no neighbour bleeds in)
			dst.blit_rect(im, Rect2i(0, 0, w, 1), Vector2i(x, y - 1 - i))
			dst.blit_rect(im, Rect2i(0, h - 1, w, 1), Vector2i(x, y + h + i))
			dst.blit_rect(im, Rect2i(0, 0, 1, h), Vector2i(x - 1 - i, y))
			dst.blit_rect(im, Rect2i(w - 1, 0, 1, h), Vector2i(x + w + i, y))
		var c0 := im.get_pixel(0, 0)
		var c1 := im.get_pixel(w - 1, 0)
		var c2 := im.get_pixel(0, h - 1)
		var c3 := im.get_pixel(w - 1, h - 1)
		for i in ATLAS_PAD:
			for j in ATLAS_PAD:
				dst.set_pixel(x - 1 - i, y - 1 - j, c0)
				dst.set_pixel(x + w + i, y - 1 - j, c1)
				dst.set_pixel(x - 1 - i, y + h + j, c2)
				dst.set_pixel(x + w + i, y + h + j, c3)
	var tex: Array = []
	for pg in pages:
		pg["img"].generate_mipmaps()
		tex.append(ImageTexture.create_from_image(pg["img"]))
	var saved := {}
	for key in imgs:
		var p: Array = places[key]
		var im: Image = imgs[key]
		var x: int = p[1] + ATLAS_PAD
		var y: int = p[2] + ATLAS_PAD
		sprites[key] = {"tex": tex[int(p[0])], "region": Rect2(x, y, im.get_width(), im.get_height()), "anchor": Vector2(idx[key][0], idx[key][1])}
		saved[key] = [int(p[0]), x, y, im.get_width(), im.get_height()]
	if not save: return
	var names: Array = []
	for i in pages.size():
		var pname := "atlas_man_%d.png" % i
		pages[i]["img"].save_png(CACHE_DIR + "/" + pname)
		names.append(pname)
	var f2 := FileAccess.open(CACHE_DIR + "/" + ATLAS_INDEX, FileAccess.WRITE)
	f2.store_string(JSON.stringify({"pages": names, "keys": saved}))
	f2.close()

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
	env.ambient_light_energy = 0.46 # (a little darker: the lights do the modelling)
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
	sun.shadow_opacity = 1.0
	sun.shadow_blur = 1.1
	sun.directional_shadow_max_distance = 600.0
	# sunlight from the upper left of the screen: shadows fall to the right and a little down
	var travel := (Vector3(1, 0, -1).normalized() * 0.75 + Vector3(1, 0, 1).normalized() * 0.35)
	travel.y = -0.62 # (a lowish sun: long shadows across the ground)
	sun.transform = Transform3D(Basis.looking_at(travel.normalized(), Vector3.UP), Vector3.ZERO)
	vp.add_child(sun)
	# a cool fill from the other side: lifts the shadowed face so sprites stay
	# readable at map zoom without flattening the sun's modelling
	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.35
	fill.light_color = Color(0.72, 0.8, 1.0)
	fill.shadow_enabled = false
	var ftravel := (-travel.normalized() * 0.6 + Vector3(0, -0.35, 0))
	fill.transform = Transform3D(Basis.looking_at(ftravel.normalized(), Vector3.UP), Vector3.ZERO)
	vp.add_child(fill)
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
	catcher.visible = not job.get("mask", false) and not job.get("nocatch", false)
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
	elif catcher.visible: _deepen_shadow(img)
	var keep := img.duplicate()
	img.generate_mipmaps()
	sprites[job["key"]] = {"tex": ImageTexture.create_from_image(img), "anchor": anchor - Vector2(r.position), "img": keep}

## The ground shadow comes out pale (soft, partly lit): darken it. Shadow pixels are the
## near-black, partly transparent ones of the invisible catcher; the model is opaque.
const SHADOW_BOOST := 4.0 # (the catcher's shadow comes out ~5-12% opaque; a sunny day's is ~40%)
func _deepen_shadow(img: Image) -> void:
	var data := img.get_data()
	for i in range(0, data.size(), 4):
		var a: int = data[i + 3]
		if a == 0 or a > 247: continue
		if maxi(data[i], maxi(data[i + 1], data[i + 2])) > 60: continue # (a model's soft edge, not shadow)
		data[i + 3] = mini(170, int(a * SHADOW_BOOST))
	img.set_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8, data)

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

func cyl(r_top: float, r_bot: float, h: float, seg := 12, rings := 1) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = r_top
	c.bottom_radius = r_bot
	c.height = h
	c.radial_segments = seg
	c.rings = rings
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

## Set extra shader parameters on a material (countershading, stripes, moss...).
func tune(m: ShaderMaterial, params: Dictionary) -> ShaderMaterial:
	for k in params: m.set_shader_parameter(k, params[k])
	return m

## A smooth lofted tube through rings [center, rx, ry]: rx is the width across, ry the
## depth along `up` (projected square to the tube). Ends are capped. Bodies, necks,
## limbs, tails and branches are all made this way, so they bend smoothly.
func tube(rings: Array, up := Vector3.UP, seg := 10) -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	var n := rings.size()
	for i in n:
		var c: Vector3 = rings[i][0]
		var t: Vector3 = (rings[mini(i + 1, n - 1)][0] - rings[maxi(i - 1, 0)][0]).normalized()
		var u: Vector3 = up - t * up.dot(t)
		if u.length() < 0.05:
			var alt := Vector3(0, 0, 1) if absf(t.z) < 0.9 else Vector3(1, 0, 0)
			u = alt - t * alt.dot(t)
		u = u.normalized()
		var s := t.cross(u).normalized()
		var rx: float = maxf(rings[i][1], 0.02)
		var ry: float = maxf(rings[i][2], 0.02)
		for k in seg:
			var a := k * TAU / seg
			verts.append(c + s * cos(a) * rx + u * sin(a) * ry)
			norms.append((s * cos(a) / rx + u * sin(a) / ry).normalized())
	for i in n - 1:
		for k in seg:
			var a := i * seg + k
			var b := i * seg + (k + 1) % seg
			idx.append_array([a, b, a + seg, b, b + seg, a + seg])
	for end in [0, n - 1]:
		var ci := verts.size()
		var tt: Vector3 = (rings[1][0] - rings[0][0]).normalized() if end == 0 else (rings[n - 1][0] - rings[n - 2][0]).normalized()
		verts.append(rings[end][0] + (-tt if end == 0 else tt) * minf(rings[end][1], rings[end][2]) * 0.6)
		norms.append(-tt if end == 0 else tt)
		for k in seg:
			var a: int = end * seg + k
			var b: int = end * seg + (k + 1) % seg
			if end == 0: idx.append_array([ci, a, b])
			else: idx.append_array([ci, b, a])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m

## A tube placed straight into the parent's space (mesh space == parent space, which the
## countershading and stripes rely on).
func loft(parent: Node3D, rings: Array, m: Material, up := Vector3.UP, seg := 10) -> MeshInstance3D:
	return mi(parent, tube(rings, up, seg), m, Vector3.ZERO)

## Push a primitive's vertices in and out along their normals with noise: lumpy thatch,
## rocks, foliage clumps. faceted = flat-shaded (stone), otherwise smooth (leaves).
func lumpy(src: PrimitiveMesh, amt: float, seed: int, freq := 0.25, faceted := false) -> ArrayMesh:
	var arr := src.get_mesh_arrays()
	var nz := FastNoiseLite.new()
	nz.seed = seed
	nz.frequency = freq
	nz.fractal_octaves = 2
	var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var ns: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	for i in vs.size():
		vs[i] += ns[i] * nz.get_noise_3dv(vs[i]) * amt
	arr[Mesh.ARRAY_VERTEX] = vs
	var st := SurfaceTool.new()
	st.create_from_arrays(arr)
	if faceted: st.deindex()
	st.generate_normals()
	return st.commit()

## A rough boulder of radius r.
func boulder(parent: Node3D, pos: Vector3, r: float, m: Material, seed: int, squash := 0.75, yaw := 0.0) -> MeshInstance3D:
	return mi(parent, lumpy(sph(r, 9, 6), r * 0.35, seed, 0.6 / r, true), m, pos, Vector3(0, yaw, 0), Vector3(1, squash, 1))

## A foliage clump (smooth, knobbly sphere).
func clump(parent: Node3D, pos: Vector3, r: float, m: Material, seed: int, sc := Vector3.ONE) -> MeshInstance3D:
	return mi(parent, lumpy(sph(r, 14, 9), r * 0.45, seed, 0.9 / r), m, pos, Vector3(0, seed * 37 % 360, 0), sc)

## A limb or branch through joint points with matching radii (a tube with rounded joints).
func limb(parent: Node3D, pts: Array, radii: Array, m: Material, seg := 8) -> MeshInstance3D:
	var rings := []
	for i in pts.size(): rings.append([pts[i], radii[i], radii[i]])
	return loft(parent, rings, m, Vector3.UP, seg)

## Joint points down from `top`: each segment has a length and an angle from straight
## down (radians, + = toward +z).
func chain(top: Vector3, lens: Array, angles: Array) -> Array:
	var pts := [top]
	var p := top
	for i in lens.size():
		p += Vector3(0, -cos(angles[i]), sin(angles[i])) * lens[i]
		pts.append(p)
	return pts

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
		jobs.append({"key": "lookout_tower" + sfx, "size": 192, "lift": 34.0, "build": _tower.bind(snowy)})
		jobs.append({"key": "smokehouse" + sfx, "size": 160, "lift": 10.0, "build": _smokehouse.bind(snowy)})
		jobs.append({"key": "cookhouse" + sfx, "size": 192, "lift": 12.0, "build": _cookhouse.bind(snowy)})
		jobs.append({"key": "longhouse" + sfx, "size": 288, "lift": 16.0, "build": _longhall.bind(snowy)})
		jobs.append({"key": "temple" + sfx, "size": 192, "lift": 22.0, "build": _temple.bind(snowy)})
		for d in WALL_DIRS: # (a block turned to follow its ring: d * 180/WALL_DIRS degrees)
			jobs.append({"key": "wall_stone_%d%s" % [d, sfx], "size": 64, "lift": 8.0, "build": _wall_stone.bind(snowy, d * 180.0 / WALL_DIRS)})
		for kind in YARD_PROPS: jobs.append({"key": "yard_%s%s" % [kind, sfx], "size": 64, "lift": 4.0, "build": _yard.bind(kind, snowy)})
		jobs.append({"key": "wall_tower" + sfx, "size": 96, "lift": 18.0, "build": _wall_tower.bind(snowy)})
		jobs.append({"key": "trading_post" + sfx, "size": 160, "lift": 12.0, "build": _trading_post.bind(snowy)})
		jobs.append({"key": "warehouse" + sfx, "size": 256, "lift": 18.0, "build": _warehouse.bind(snowy)})
		jobs.append({"key": "aurochs_pen" + sfx, "size": 192, "lift": 6.0, "build": _pen.bind(snowy)})
		jobs.append({"key": "den" + sfx, "size": 224, "lift": 14.0, "build": _mound.bind(true, snowy)})
		jobs.append({"key": "cave" + sfx, "size": 224, "lift": 14.0, "build": _mound.bind(false, snowy)})
		jobs.append({"key": "stones" + sfx, "size": 224, "lift": 12.0, "build": _stones.bind(snowy)})
		jobs.append({"key": "peak" + sfx, "size": 320, "lift": 45.0, "build": _peak.bind(snowy)})
	# fields by season, dock, remaining landmarks, the dragon guardian
	for season in ["spring", "summer", "autumn", "winter"]:
		jobs.append({"key": "farm_" + season, "size": 192, "lift": 4.0, "build": _farm.bind(season)})
	for snowy in [false, true]:
		var sfx := "_snow" if snowy else ""
		jobs.append({"key": "dock" + sfx, "size": 192, "lift": 4.0, "build": _dock.bind(snowy, false)})
		jobs.append({"key": "dock_w" + sfx, "size": 192, "lift": 4.0, "build": _dock.bind(snowy, true)})
		jobs.append({"key": "spring" + sfx, "size": 192, "lift": 4.0, "build": _hot_spring.bind(snowy)})
		jobs.append({"key": "bones" + sfx, "size": 192, "lift": 8.0, "build": _bones.bind(snowy)})
		jobs.append({"key": "flint" + sfx, "size": 160, "lift": 8.0, "build": _flint.bind(snowy)})
	for d in DIRS:
		for f in 4:
			jobs.append({"key": "dragon_%d_%d" % [d, f], "size": 192, "lift": 0.0, "nocatch": true, "build": _dragon.bind(d * 360.0 / DIRS, f / 4.0)})
	# ground cover
	for snowy in [false, true]:
		var sfx := "_snow" if snowy else ""
		for v in 3: jobs.append({"key": "grass_%d%s" % [v, sfx], "size": 64, "lift": 3.0, "build": _grass.bind(v, snowy)})
		for v in 3: jobs.append({"key": "flower_%d%s" % [v, sfx], "size": 64, "lift": 3.0, "build": _flowers.bind(v, snowy)})
		for v in 2: jobs.append({"key": "fern_%d%s" % [v, sfx], "size": 64, "lift": 3.0, "build": _fern.bind(v, snowy)})
		for v in 2: jobs.append({"key": "reeds_%d%s" % [v, sfx], "size": 80, "lift": 7.0, "build": _reeds.bind(v, snowy)})
		jobs.append({"key": "pebbles" + sfx, "size": 64, "lift": 1.0, "build": _pebbles.bind(snowy)})
		for v in 3: jobs.append({"key": "outcrop_%d%s" % [v, sfx], "size": 288, "lift": 16.0, "build": _outcrop.bind(v, snowy)})
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
		for w in WEAPON_ANIMS: # each weapon's own way of fighting
			for f in 4:
				for tool in (["stone", "bronze"] if w in BRONZE_WEAPONS else ["stone"]):
					var key := "man_attack_%s_%d_%d%s" % [w, d, f, "_bronze" if tool == "bronze" else ""]
					jobs.append({"key": key, "size": 112, "lift": 13.0, "build": _person.bind(yaw, "attack", f / 4.0, false, tool, w)})
					jobs.append({"key": key + "_cloth", "size": 112, "lift": 13.0, "mask": true, "build": _person.bind(yaw, "attack", f / 4.0, true, tool, w)})
	return jobs

# ---- nature
## Conifer: a tapering trunk with whorls of drooping branch sprays (flattened lofts),
## shorter towards the top, each spray a slightly different green.
func _pine(v: int, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 100 + v
	var bark := mat(Color("#57391f"), "streak", 0.14, Vector3(1, 5, 1), 0.6)
	root.rotation_degrees = Vector3(rng.randf_range(-3, 3), 0, rng.randf_range(-3, 3)) # trees lean a little
	limb(root, [Vector3(0, -0.5, 0), Vector3(0, 2, 0), Vector3(0.3, 20, 0.2), Vector3(0, 44, 0)], [4.4, 2.5, 1.7, 0.3], bark, 9)
	for i in 4: # root flare
		var a := i * TAU / 4 + rng.randf()
		limb(root, [Vector3(0, 3.5, 0), Vector3(cos(a) * 4.5, 0.2, sin(a) * 4.5)], [1.6, 0.4], bark, 6)
	var dark := Color("#1f4128") if v % 2 == 0 else Color("#1d3b2c")
	var lite := Color("#40703a") if v % 2 == 0 else Color("#3c6a42")
	var sn := 0.45 if snowy else 0.0
	var tiers := 7
	var h := 8.0
	for i in tiers:
		var t := float(i) / (tiers - 1)
		var r := lerpf(16.0, 4.5, t) + rng.randf_range(-1.0, 1.0)
		var n := 9 - i / 2
		for j in n:
			var a := (j + rng.randf_range(-0.25, 0.25)) * TAU / n + i * 0.5
			var dir := Vector3(cos(a), 0, sin(a))
			var droop := rng.randf_range(3.0, 5.5) * (1.0 - t * 0.5)
			var len := r * rng.randf_range(0.85, 1.1)
			var col := dark.lerp(lite, clampf(t * 0.7 + rng.randf_range(0.0, 0.35), 0.0, 1.0))
			var m := mat(col, "fine", 0.25, Vector3.ONE, 0.65, sn)
			var base := Vector3(0, h + 3.5, 0)
			loft(root, [[base, 1.2, 1.4], [base + dir * len * 0.45 + Vector3(0, -droop * 0.25, 0), len * 0.32, 1.6], [base + dir * len * 0.8 + Vector3(0, -droop * 0.7, 0), len * 0.2, 1.1], [base + dir * len + Vector3(0, -droop, 0), 0.3, 0.3]], m, Vector3.UP, 8)
		mi(root, cyl(r * 0.25, r * 0.55, 5.0, 9), mat(dark.lerp(lite, t * 0.6), "fine", 0.25, Vector3.ONE, 0.6, sn), Vector3(0, h + 3.0, 0))
		h += lerpf(5.6, 4.0, t)
	mi(root, cyl(0.0, 2.2, 7, 7), mat(lite, "fine", 0.25, Vector3.ONE, 0.5, sn), Vector3(0, h + 4.5, 0))
	return root

## Broadleaf: a gnarled, forked trunk with branches and lumpy leaf clumps.
func _leafy(v: int, snowy: bool) -> Node3D:
	# A broadleaf tree: a short trunk forking into branches, each ending in many small leaf
	# clusters; the crown is sunlit yellow-green on top and deep green underneath.
	var root := Node3D.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 200 + v
	var bark := mat(Color("#5e4129"), "streak", 0.14, Vector3(1, 5, 1), 0.6)
	var lean := Vector3(rng.randf_range(-1.5, 1.5), 0, rng.randf_range(-1.5, 1.5))
	var fork := Vector3(0, 11, 0) + lean
	limb(root, [Vector3(0, -0.5, 0), Vector3(0, 2.5, 0), lean * 0.5 + Vector3(0, 7, 0), fork], [4.0, 2.5, 2.0, 1.8], bark, 9)
	for i in 4: # root flare
		var a := i * TAU / 4 + rng.randf()
		limb(root, [Vector3(0, 3.5, 0), Vector3(cos(a) * 5, 0.2, sin(a) * 5)], [1.6, 0.4], bark, 6)
	var tips: Array = []
	for i in 5: # main branches, each splitting twice
		var a := i * TAU / 5 + rng.randf_range(-0.3, 0.3)
		var tilt := deg_to_rad(rng.randf_range(30, 58))
		var dir := Vector3(cos(a) * sin(tilt), cos(tilt), sin(a) * sin(tilt))
		var mid := fork + dir * rng.randf_range(6, 9)
		limb(root, [fork, mid], [1.4, 0.9], bark, 7)
		for k in 2:
			var d2 := (dir + Vector3(rng.randf_range(-0.6, 0.6), rng.randf_range(0.1, 0.5), rng.randf_range(-0.6, 0.6))).normalized()
			var tip := mid + d2 * rng.randf_range(5, 8)
			limb(root, [mid, tip], [0.8, 0.3], bark, 6)
			tips.append(tip)
	tips.append(fork + Vector3(0, 12, 0)) # (the top)
	var lo := Color("#1f4220") # shaded underside
	var mid_c := Color("#3a6527")
	var hi := Color("#7a9a38") # sunlit top
	var sn := 0.8 if snowy else 0.0
	var top_y := fork.y + 16.0
	var n := 0
	for t in tips:
		for j in 6: # small clusters around each branch tip
			var off := Vector3(rng.randf_range(-4.5, 4.5), rng.randf_range(-2.5, 3.5), rng.randf_range(-4.5, 4.5))
			var p: Vector3 = t + off
			var h := clampf((p.y - fork.y) / (top_y - fork.y), 0.0, 1.0)
			var c := lo.lerp(mid_c, smoothstep(0.0, 0.55, h)).lerp(hi, smoothstep(0.7, 1.0, h) * 0.7)
			c = c.lerp(Color("#4d6e2a"), rng.randf() * 0.3) # (a little variety)
			clump(root, p, rng.randf_range(3.0, 4.6), mat(c, "fine", 0.3, Vector3.ONE, 0.8, sn), 200 + v * 97 + n, Vector3(1, rng.randf_range(0.7, 0.95), 1))
			n += 1
	return root

func _bush(full: bool, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 400
	var sn := 0.8 if snowy else 0.0
	for i in 6:
		var a := i * TAU / 6 + rng.randf_range(-0.3, 0.3)
		var leaf := mat([Color("#3b6a2e"), Color("#46763a"), Color("#33602a")][i % 3], "fine", 0.22, Vector3.ONE, 0.6, sn)
		clump(root, Vector3(cos(a) * 4.8, rng.randf_range(3.0, 5.5), sin(a) * 4.8), rng.randf_range(3.4, 4.6), leaf, 400 + i, Vector3(1, 0.85, 1))
	clump(root, Vector3(0, 7, 0), 5.2, mat(Color("#41702f"), "fine", 0.22, Vector3.ONE, 0.6, sn), 410, Vector3(1, 0.85, 1))
	if full:
		var berry := mat(Color("#c42638"), "fine", 0.3, Vector3.ONE, 0.2)
		for i in 18:
			var a := i * 2.4
			var p := Vector3(cos(a) * rng.randf_range(5.5, 7.2), rng.randf_range(3.5, 10), sin(a) * rng.randf_range(5.5, 7.2))
			mi(root, sph(0.85, 6, 4), berry, p)
			mi(root, sph(0.7, 6, 4), berry, p + Vector3(0.9, -0.5, 0.4))
	return root

func _stump(snowy: bool) -> Node3D:
	var root := Node3D.new()
	var bark := mat(Color("#654628"), "streak", 0.2, Vector3(1, 4, 1), 0.6)
	mi(root, lumpy(cyl(3.4, 4.0, 5, 12), 0.35, 5, 0.6), bark, Vector3(0, 2.5, 0))
	for i in 4:
		var a := i * TAU / 4 + 0.4
		limb(root, [Vector3(0, 3, 0), Vector3(cos(a) * 5.5, 0.2, sin(a) * 5.5)], [1.6, 0.4], bark, 6)
	mi(root, cyl(3.2, 3.2, 0.4, 12), mat(Color("#c79868") if not snowy else Color("#eef2f8"), "fine", 0.5, Vector3.ONE, 0.4), Vector3(0, 5.1, 0))
	if not snowy: mi(root, cyl(1.6, 1.6, 0.42, 10), mat(Color("#a87848"), "fine", 0.5), Vector3(0, 5.12, 0))
	mi(root, box(Vector3(0.6, 0.4, 2.6)), mat(Color("#cfc0a0"), "fine"), Vector3(5, 0.3, 2), Vector3(0, 30, 0)) # a chip of wood
	return root

func _rocks(v: int, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 300 + v
	var sn := 0.75 if snowy else 0.45
	var moss_col := Color("#eef2f8") if snowy else Color("#5d7a3a")
	var stone := tune(mat(Color("#8b877d"), "coarse", 0.15, Vector3.ONE, 0.6, sn), {"snow_color": moss_col})
	var dark := tune(mat(Color("#706b62"), "coarse", 0.15, Vector3.ONE, 0.6, sn * 0.6), {"snow_color": moss_col})
	for i in 3 + v:
		var sc := rng.randf_range(4, 8.5)
		var pos := Vector3(rng.randf_range(-9, 9), sc * 0.4, rng.randf_range(-7, 7))
		boulder(root, pos, sc, stone if i % 2 == 0 else dark, 300 + v * 10 + i, rng.randf_range(0.6, 0.9), rng.randf_range(0, 360))
	for i in 6: # pebbles
		boulder(root, Vector3(rng.randf_range(-13, 13), 0.3, rng.randf_range(-10, 10)), rng.randf_range(0.8, 1.6), dark, 350 + i, 0.6)
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
	mi(root, lumpy(cyl(0.6, r, h, 20, 6), 0.3, 34, 0.22), hide, Vector3(0, h / 2, 0))
	for i in 5: # sewn seams running up the hide panels
		var a := (i + 0.5) * TAU / 5
		segment(root, Vector3(cos(a) * (r + 0.3), 0.2, sin(a) * (r + 0.3)), Vector3(0, h - 0.5, 0), 0.35, seam)
	var pole := mat(Color("#5e3d22"), "streak", 0.2, Vector3(1, 4, 1))
	for i in 6:
		var a := i * TAU / 6
		mi(root, cyl(0.5, 0.6, 13, 5), pole, Vector3(cos(a) * 1.6, h + 3.5, sin(a) * 1.6), Vector3(rad_to_deg(sin(a)) * 0.4, 0, -rad_to_deg(cos(a)) * 0.4))
	# open door flap and stones weighing down the hem
	mi(root, box(Vector3(8, h * 0.45, 1.4)), mat(Color("#2a1a0e"), "fine"), Vector3(0, h * 0.22, r * 0.78), Vector3(-30, 0, 0))
	mi(root, box(Vector3(5, h * 0.4, 0.6)), hide, Vector3(5, h * 0.2, r * 0.86), Vector3(-30, 25, -10))
	var stone := mat(Color("#8b877d"), "coarse", 0.25, Vector3.ONE, 0.5, 0.6 if snowy else 0.0)
	for i in 12:
		var a := i * TAU / 12 + 0.2
		if absf(a - PI / 2) < 0.4: continue
		boulder(root, Vector3(cos(a) * (r + 0.6), 0.8, sin(a) * (r + 0.6)), 1.7, stone, 40 + i, 0.7, i * 30)
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
	mi(root, lumpy(cyl(r, r + 0.6, wh, 28, 4), 0.45, 33, 0.3), wall, Vector3(0, wh / 2, 0))
	mi(root, cyl(r + 0.8, r + 1.0, 1.4, 18), mat(Color("#7a6040"), "coarse", 0.2), Vector3(0, 0.7, 0)) # plinth
	for i in 10: # wall posts
		var a := i * TAU / 10 + 0.15
		mi(root, cyl(0.8, 0.9, wh + 1, 5), post, Vector3(cos(a) * (r + 0.3), wh / 2, sin(a) * (r + 0.3)))
	# two-layer thatch with a fringe at the eave and a bound knot over the smoke hole
	mi(root, lumpy(cyl(r * 0.55, r * 1.24, rh * 0.6, 28, 6), 1.1, 31, 0.18), thatch, Vector3(0, wh + rh * 0.3, 0))
	mi(root, lumpy(cyl(0.6, r * 0.62, rh * 0.5, 24, 5), 0.8, 32, 0.2), mat(thatch_col.lightened(0.06), "streak", 0.2, Vector3(1, 6, 1), 0.65, 0.85 if snowy else 0.0), Vector3(0, wh + rh * 0.6 + rh * 0.23, 0))
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
			boulder(root, Vector3(x, 3.4, side * (depth / 2 + 2.2)), 2.9, stone if i % 2 == 0 else stone2, 60 + i * 2 + side, 0.7, rng.randf_range(0, 90))
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
		boulder(root, Vector3(cos(a) * 11, 1.2, sin(a) * 11), 2.7, stone, 80 + i, 0.7, i * 37)
	mi(root, cyl(9, 9, 0.3, 14), mat(Color("#3a3430"), "coarse", 0.3), Vector3(0, 0.15, 0)) # ash bed
	var lg := mat(Color("#4a2e16"), "streak", 0.2, Vector3(4, 1, 1))
	mi(root, cyl(1.4, 1.4, 16, 7), lg, Vector3(0, 2, 0), Vector3(0, 30, 80))
	mi(root, cyl(1.4, 1.4, 16, 7), lg, Vector3(0, 2.6, 0), Vector3(0, -40, 80))
	mi(root, cyl(1.3, 1.3, 14, 7), lg, Vector3(0, 3.2, 0), Vector3(0, 95, 80))
	return root

# ---- fields, dock, landmarks, dragon
func _farm(season: String) -> Node3D:
	var root := Node3D.new()
	var soil := mat(Color("#6e4f30"), "coarse", 0.2, Vector3.ONE, 0.5, 0.85 if season == "winter" else 0.0)
	var ridge := mat(Color("#5a3e24"), "coarse", 0.25, Vector3.ONE, 0.5, 0.85 if season == "winter" else 0.0)
	mi(root, box(Vector3(60, 0.8, 40)), soil, Vector3(0, 0.4, 0))
	for i in 6: mi(root, box(Vector3(56, 1.6, 2.2)), ridge, Vector3(0, 1.0, -16 + i * 6.5))
	if season != "winter":
		var col: Color = {"spring": Color("#8cc24a"), "summer": Color("#5f9a32"), "autumn": Color("#d8b04a")}[season]
		var h: float = {"spring": 2.5, "summer": 6.0, "autumn": 7.0}[season]
		var crop := mat(col, "fine", 0.4, Vector3.ONE, 0.35)
		for i in 6:
			for k in 10:
				var p := Vector3(-25 + k * 5.5, 1.6, -16 + i * 6.5)
				mi(root, cyl(0.0, 1.3, h, 5), crop, p + Vector3(0, h / 2, 0), Vector3(randf_range(-8, 8), 0, randf_range(-8, 8)))
				if season == "autumn": mi(root, cap(0.6, 2.4), mat(Color("#e8c85a"), "fine", 0.4, Vector3.ONE, 0.3), p + Vector3(0, h + 0.5, 0))
	var wicker := mat(Color("#8a6a40"), "streak", 0.3, Vector3(4, 1, 1), 0.5, 0.6 if season == "winter" else 0.0)
	for side in [-1, 1]: # low wicker fence on two sides
		mi(root, box(Vector3(62, 3, 0.8)), wicker, Vector3(0, 1.5, side * 21))
		for k in 7: mi(root, cyl(0.4, 0.4, 4.5, 4), wicker, Vector3(-30 + k * 10, 2.2, side * 21))
	return root

## Pier on posts running out over the water from the anchor point (towards -x).
func _dock(snowy: bool, west_bank: bool) -> Node3D:
	var root := Node3D.new()
	if west_bank: root.rotation_degrees.y = 180.0 # pier runs east into the river
	var plank := mat(Color("#9a7448"), "streak", 0.2, Vector3(1, 1, 5), 0.5, 0.6 if snowy else 0.0)
	var post := mat(Color("#5a3e24"), "streak", 0.2, Vector3(1, 4, 1), 0.5)
	for i in 9: mi(root, box(Vector3(5.6, 0.8, 14)), plank, Vector3(-46 + i * 6, 3, 0), Vector3(0, 0, randf_range(-1.5, 1.5)))
	for x in [-48, -32, -16, 0]:
		for z in [-7, 7]: mi(root, cyl(0.9, 1.0, 9, 6), post, Vector3(x, 0.5, z))
	mi(root, cyl(0.25, 0.3, 24, 4), mat(Color("#c8b48a"), "streak", 0.3, Vector3(1, 4, 1)), Vector3(-50, 12, 4), Vector3(0, 0, 55))
	mi(root, cyl(3.0, 2.4, 4, 9), mat(Color("#a8864e"), "streak", 0.3, Vector3(1, 3, 1), 0.5), Vector3(-6, 5.4, -4)) # fish basket
	for i in 3: mi(root, cap(0.8, 4.0), mat(Color("#9ab0b8"), "fine", 0.4, Vector3.ONE, 0.3), Vector3(-7 + i * 1.2, 7.2, -4), Vector3(0, i * 50, 90))
	return root

func _hot_spring(snowy: bool) -> Node3D:
	var root := Node3D.new()
	var stone := mat(Color("#9a9286"), "coarse", 0.2, Vector3.ONE, 0.55, 0.8 if snowy else 0.0)
	for i in 16:
		var a := i * TAU / 16
		boulder(root, Vector3(cos(a) * 42, 1.5, sin(a) * 26), randf_range(3.5, 5.5), stone, 90 + i, 0.65, randf() * 90)
	mi(root, cyl(40, 40, 1.0, 24), mat(Color("#c2b48e"), "coarse", 0.2, Vector3.ONE, 0.4), Vector3(0, 0.3, 0), Vector3.ZERO, Vector3(1, 1, 0.62))
	mi(root, cyl(36, 36, 1.0, 24), mat(Color("#3fa6b2"), "fine", 0.08, Vector3.ONE, 0.35), Vector3(0, 0.9, 0), Vector3.ZERO, Vector3(1, 1, 0.6))
	mi(root, cyl(16, 16, 1.0, 20), mat(Color("#7fd6dc"), "fine", 0.1, Vector3.ONE, 0.3), Vector3(-6, 1.0, -2), Vector3.ZERO, Vector3(1, 1, 0.6))
	return root

func _bones(snowy: bool) -> Node3D:
	var root := Node3D.new()
	var bone := mat(Color("#e8dcc0"), "fine", 0.3, Vector3.ONE, 0.3, 0.4 if snowy else 0.0)
	segment(root, Vector3(-30, 2, 0), Vector3(22, 3, 0), 1.6, bone) # spine
	for i in 7: # ribs arching over
		var x := -24 + i * 6.5
		for side in [-1, 1]:
			segment(root, Vector3(x, 3, 0), Vector3(x + 1, 11, side * 6), 0.7, bone)
			segment(root, Vector3(x + 1, 11, side * 6), Vector3(x + 2, 1, side * 11), 0.6, bone)
	mi(root, sph(6, 10, 6), bone, Vector3(28, 5, 0), Vector3.ZERO, Vector3(1.3, 1, 1)) # skull
	for side in [-1, 1]: # great curved tusks
		var prev := Vector3(32, 4, side * 3)
		for k in 6:
			var nxt := prev + Vector3(4.5 - k * 0.6, 2.5 - k * 0.9, side * 1.8)
			segment(root, prev, nxt, 1.1 - k * 0.12, bone)
			prev = nxt
	return root

func _flint(snowy: bool) -> Node3D:
	var root := Node3D.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 1001
	for i in 9:
		var h := rng.randf_range(6, 18)
		var col: Color = [Color("#3c3a40"), Color("#4a4852"), Color("#2e2c32")][i % 3]
		var pr := PrismMesh.new()
		pr.size = Vector3(rng.randf_range(5, 9), h, rng.randf_range(4, 7))
		mi(root, pr, mat(col, "fine", 0.3, Vector3.ONE, 0.25, 0.7 if snowy else 0.0), Vector3(rng.randf_range(-22, 22), h / 2, rng.randf_range(-14, 14)), Vector3(rng.randf_range(-12, 12), rng.randf_range(0, 180), rng.randf_range(-12, 12)))
	for i in 10: mi(root, box(Vector3(1.6, 0.5, 1.2)), mat(Color("#6d6a78"), "fine", 0.3), Vector3(rng.randf_range(-26, 26), 0.3, rng.randf_range(-18, 18)), Vector3(0, rng.randf() * 180, 0))
	return root

## Yinglong: a winged, serpentine dragon, baked flying (no ground shadow).
func _dragon(yaw: float, phase: float) -> Node3D:
	var holder := Node3D.new()
	holder.rotation_degrees.y = yaw
	var scale_m := mat(Color("#3fbfa0"), "fine", 0.3, Vector3.ONE, 0.5)
	var belly := mat(Color("#e8c25a"), "fine", 0.3, Vector3.ONE, 0.3)
	var wing_m := mat(Color("#2f9a82"), "coarse", 0.2, Vector3.ONE, 0.4)
	var pts: Array = []
	for i in 8: # S-curved body from tail to neck
		var z := -22.0 + i * 5.5
		pts.append(Vector3(sin(i * 0.9 + phase * TAU) * 3.0, sin(i * 0.6) * 2.0, z))
	for i in pts.size() - 1:
		var r := 1.2 + i * 0.45
		segment(holder, pts[i], pts[i + 1], r, scale_m)
		mi(holder, sph(r * 0.8, 6, 4), belly, pts[i] + Vector3(0, -r * 0.5, 0))
	var head_p: Vector3 = pts[pts.size() - 1] + Vector3(0, 2, 4)
	mi(holder, sph(3.4, 10, 6), scale_m, head_p, Vector3.ZERO, Vector3(0.9, 0.8, 1.4))
	for side in [-1, 1]:
		segment(holder, head_p + Vector3(side * 1.2, 2, -1), head_p + Vector3(side * 3.0, 6, -5), 0.4, belly) # horns
		mi(holder, sph(0.6, 6, 4), flat(Color.WHITE), head_p + Vector3(side * 1.6, 1.0, 2.5))
	var flap := sin(phase * TAU) * 35.0
	for side in [-1, 1]:
		var wing := Node3D.new()
		wing.position = Vector3(side * 2.5, 2, 2)
		wing.rotation_degrees = Vector3(0, 0, side * (10.0 + flap))
		holder.add_child(wing)
		var pr := PrismMesh.new() # membrane lying flat, spread sideways
		pr.size = Vector3(24, 13, 0.6)
		mi(wing, pr, wing_m, Vector3(side * 12, 0, -2), Vector3(90, 0, 0))
		segment(wing, Vector3.ZERO, Vector3(side * 24, 0, 4), 0.5, scale_m) # leading bone
	segment(holder, pts[0], pts[0] + Vector3(0, 1, -6), 0.6, scale_m) # tail tip
	return holder

# ---- ground cover
func _grass(v: int, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 500 + v
	var greens := [Color("#6a8f3a"), Color("#587f33"), Color("#7a9a44")]
	for i in 9 + v * 3:
		var a := rng.randf() * TAU
		var d := rng.randf_range(0, 3.2)
		var h := rng.randf_range(3.5, 7.0)
		var blade := mat(greens[i % 3], "fine", 0.4, Vector3.ONE, 0.3, 0.7 if snowy else 0.0)
		mi(root, cyl(0.0, 0.45, h, 4), blade, Vector3(cos(a) * d, h / 2, sin(a) * d), Vector3(rng.randf_range(-25, 25), 0, rng.randf_range(-25, 25)))
	return root

func _flowers(v: int, snowy: bool) -> Node3D:
	var root := _grass(v + 10, snowy)
	var col: Color = [Color("#f0d24a"), Color("#e07a9a"), Color("#f2f2ee")][v]
	var rng := RandomNumberGenerator.new()
	rng.seed = 600 + v
	for i in 5:
		var p := Vector3(rng.randf_range(-3, 3), rng.randf_range(4.5, 6.5), rng.randf_range(-3, 3))
		mi(root, cyl(0.15, 0.15, p.y, 4), mat(Color("#4f7a30"), "fine"), Vector3(p.x, p.y / 2, p.z))
		mi(root, sph(0.9, 6, 4), mat(col, "fine", 0.4, Vector3.ONE, 0.15), p)
	return root

func _fern(v: int, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var col := Color("#3f6f30") if v == 0 else Color("#4a7a36")
	for i in 7:
		var a := i * TAU / 7 + v * 0.4
		var frond := mi(root, sph(3.2, 6, 4), mat(col, "fine", 0.35, Vector3.ONE, 0.45, 0.7 if snowy else 0.0), Vector3(cos(a) * 3.0, 2.2, sin(a) * 3.0), Vector3(0, -rad_to_deg(a), 0), Vector3(1.8, 0.35, 0.6))
		frond.rotation_degrees.z = 25.0
	return root

func _reeds(v: int, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 700 + v
	var stalk := mat(Color("#6e8a3a"), "streak", 0.4, Vector3(1, 4, 1), 0.3, 0.5 if snowy else 0.0)
	var head := mat(Color("#5a3a22"), "fine", 0.4, Vector3.ONE, 0.3)
	for i in 12:
		var p := Vector3(rng.randf_range(-4, 4), 0, rng.randf_range(-4, 4))
		var h := rng.randf_range(9, 15)
		var tilt := Vector3(rng.randf_range(-8, 8), 0, rng.randf_range(-8, 8))
		mi(root, cyl(0.15, 0.3, h, 4), stalk, p + Vector3(0, h / 2, 0), tilt)
		if i % 3 == 0: mi(root, cap(0.6, 3.2), head, p + Vector3(0, h - 1.0, 0), tilt)
	for i in 5: mi(root, cyl(0.0, 0.5, 7, 4), stalk, Vector3(rng.randf_range(-4, 4), 3, rng.randf_range(-4, 4)), Vector3(rng.randf_range(-30, 30), 0, rng.randf_range(-30, 30)))
	return root

func _pebbles(snowy: bool) -> Node3D:
	var root := Node3D.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 800
	for i in 6:
		mi(root, sph(rng.randf_range(0.8, 1.8), 6, 4), mat([Color("#8b877d"), Color("#9e9a90"), Color("#77736a")][i % 3], "coarse", 0.3, Vector3.ONE, 0.5, 0.6 if snowy else 0.0),
			Vector3(rng.randf_range(-4, 4), 0.5, rng.randf_range(-4, 4)), Vector3.ZERO, Vector3(1, 0.6, 1))
	return root

## Large layered rock formation for the wilds.
func _outcrop(v: int, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 900 + v
	var tones := [Color("#8a8276"), Color("#7a7266"), Color("#968e80")]
	for layer in 4:
		var y := layer * 7.0
		var r := 34.0 - layer * 7.0 + rng.randf_range(-3, 3)
		for i in 3 + layer:
			var a := rng.randf() * TAU
			var off := Vector3(cos(a), 0, sin(a)) * rng.randf_range(0, r * 0.4)
			var sz := Vector3(rng.randf_range(r * 0.7, r * 1.2), 8.0, rng.randf_range(r * 0.5, r * 0.9))
			mi(root, lumpy(box(sz), 1.6, 920 + layer * 10 + i, 0.12, true), mat(tones[(layer + i) % 3], "coarse", 0.08, Vector3(1, 0.3, 1), 0.6, 0.8 if snowy else 0.0), off + Vector3(0, y + 4, 0), Vector3(rng.randf_range(-6, 6), rng.randf_range(0, 180), rng.randf_range(-6, 6)))
	for i in 8: # fallen boulders and scrub at the foot
		var a := rng.randf() * TAU
		boulder(root, Vector3(cos(a) * 38, 1.5, sin(a) * 30), rng.randf_range(2.5, 5), mat(tones[i % 3], "coarse", 0.15, Vector3.ONE, 0.5, 0.6 if snowy else 0.0), 910 + i, 0.7, rng.randf() * 90)
	for i in 5:
		var a := rng.randf() * TAU
		var g := _grass(i, snowy)
		g.position = Vector3(cos(a) * 30, 0, sin(a) * 26)
		root.add_child(g)
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

## Clay bloomery furnace on a stone footing, with bellows, charcoal and ore heaps and
## cast bronze.
func _smelter(snowy: bool) -> Node3D:
	var root := Node3D.new()
	var sn := 0.5 if snowy else 0.0
	var clay := mat(Color("#9a6a48"), "coarse", 0.2, Vector3.ONE, 0.6, sn)
	var stone := mat(Color("#7d776c"), "coarse", 0.2, Vector3.ONE, 0.6, sn)
	for i in 11: # footing stones
		var a := i * TAU / 11
		boulder(root, Vector3(cos(a) * 9.5, 1.6, sin(a) * 9.5), 2.8, stone, 700 + i, 0.75, i * 40)
	mi(root, lumpy(cyl(5.0, 9.5, 16, 14), 0.7, 71, 0.3), clay, Vector3(0, 8, 0))
	mi(root, lumpy(cyl(3.6, 5.0, 8, 12), 0.5, 72, 0.3), clay, Vector3(0, 20, 0))
	mi(root, cyl(3.2, 3.2, 0.6, 12), flat(Color(0.95, 0.45, 0.12)), Vector3(0, 24.0, 0)) # glowing throat
	mi(root, box(Vector3(5, 5.5, 3)), flat(Color(1.0, 0.55, 0.15)), Vector3(0, 3.2, 8.0)) # tapping arch
	mi(root, box(Vector3(6.4, 1.2, 3.2)), stone, Vector3(0, 6.4, 8.2))
	# leather bellows feeding a clay pipe
	var leather := mat(Color("#7a5232"), "coarse", 0.4, Vector3.ONE, 0.5)
	mi(root, lumpy(sph(3.2, 10, 6), 0.4, 73, 0.5), leather, Vector3(-13, 2.6, 4), Vector3.ZERO, Vector3(1.2, 0.7, 1))
	limb(root, [Vector3(-10.5, 3, 3.5), Vector3(-7.5, 4, 2.5)], [0.7, 0.6], clay, 6)
	mi(root, cyl(0.35, 0.35, 7, 5), mat(Color("#6b4524"), "streak", 0.3, Vector3(1, 4, 1)), Vector3(-13, 5.4, 4), Vector3(0, 0, 70))
	var coal := mat(Color("#26221f"), "coarse", 0.3, Vector3.ONE, 0.4)
	var ore := mat(Color("#8a4a32"), "coarse", 0.3, Vector3.ONE, 0.6)
	for i in 7:
		boulder(root, Vector3(10 + (i % 3) * 2.2, 0.8 + (i / 3) * 1.4, -9 + (i % 2) * 2.0), 1.5, coal, 720 + i)
		boulder(root, Vector3(-11 + (i % 3) * 2.2, 0.8 + (i / 3) * 1.4, -8 + (i % 2) * 2.0), 1.4, ore, 740 + i)
	var bronze := mat(Color("#d49a3a"), "fine", 0.3, Vector3.ONE, 0.3)
	for i in 3: mi(root, box(Vector3(5, 1.3, 2.2)), bronze, Vector3(13, 0.7 + i * 1.3, 7 - i * 0.4), Vector3(0, i * 25, 0))
	return root

## Ring of standing stones with log benches round a fire pit and a talking pole.
func _council(snowy: bool) -> Node3D:
	var root := Node3D.new()
	var sn := 0.7 if snowy else 0.35
	var moss := Color("#eef2f8") if snowy else Color("#6a7f45")
	var stone := tune(mat(Color("#9a968c"), "coarse", 0.18, Vector3.ONE, 0.55, sn), {"snow_color": moss})
	for i in 9:
		var a := i * TAU / 9 + 0.2
		var h := 9.0 + (i % 3) * 2.5
		mi(root, lumpy(box(Vector3(5.5, h, 3.6)), 0.8, 800 + i, 0.35, true), stone, Vector3(cos(a) * 31, h / 2 - 0.5, sin(a) * 31), Vector3(randf_range(-4, 4), -rad_to_deg(a) + 90, randf_range(-5, 5)))
	var log_m := mat(Color("#6e4b2a"), "streak", 0.25, Vector3(4, 1, 1), 0.5, sn * 0.6)
	for i in 4: # log benches
		var a := i * TAU / 4 + 0.6
		var c := Vector3(cos(a) * 18, 1.6, sin(a) * 18)
		mi(root, cyl(1.6, 1.6, 12, 8), log_m, c, Vector3(0, -rad_to_deg(a), 90))
	var ring := mat(Color("#7d776c"), "coarse", 0.25, Vector3.ONE, 0.5, sn)
	for i in 9:
		var a := i * TAU / 9
		boulder(root, Vector3(cos(a) * 6, 0.9, sin(a) * 6), 1.8, ring, 820 + i)
	mi(root, cyl(5, 5, 0.3, 12), mat(Color("#3a3430"), "coarse", 0.3), Vector3(0, 0.2, 0))
	var wood := mat(Color("#6b4a2a"), "streak", 0.2, Vector3(1, 4, 1), 0.55)
	limb(root, [Vector3(0, 0, -11), Vector3(0, 17, -11)], [1.4, 1.1], wood, 8)
	mi(root, lumpy(sph(2.4, 10, 6), 0.4, 830, 0.5), mat(Color("#e8dcc0"), "fine", 0.3), Vector3(0, 18.6, -11), Vector3.ZERO, Vector3(1, 0.85, 1.25)) # a skull atop
	for i in 3: limb(root, [Vector3(0, 15.5 - i * 1.2, -10.2), Vector3(0, 11 - i * 1.6, -9.4 + i * 0.3)], [0.25, 0.12], mat([Color("#c0392b"), Color("#e6b33a"), Color("#f0ece0")][i], "fine"), 4)
	return root

## A totem: carved animal faces stacked up a pole, painted, with spread thunderbird
## wings at the top. The grand altar raises a taller one on a stepped stone mound.
func _shrine(grand: bool, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var sn := 0.7 if snowy else 0.0
	var stone := mat(Color("#9a968c"), "coarse", 0.18, Vector3.ONE, 0.55, sn)
	var stone2 := mat(Color("#86827a"), "coarse", 0.18, Vector3.ONE, 0.55, sn)
	var base_h := 0.0
	if grand:
		for tier in 3:
			var hw := 27.0 - tier * 8.0
			var y := 2.4 + tier * 4.6
			var n := int(hw * 8 / 5.5)
			for i in n: # dressed stones around each tier's edge
				var t := float(i) / n * 4.0
				var e := int(t)
				var f := t - e
				var p: Vector3 = [Vector3(-hw + 2 * hw * f, 0, -hw), Vector3(hw, 0, -hw + 2 * hw * f), Vector3(hw - 2 * hw * f, 0, hw), Vector3(-hw, 0, hw - 2 * hw * f)][e]
				boulder(root, p + Vector3(0, y, 0), 3.0, stone if i % 2 == 0 else stone2, 900 + tier * 50 + i, 0.8, i * 23)
			mi(root, box(Vector3(hw * 2 - 1, 4.6, hw * 2 - 1)), stone2, Vector3(0, y, 0))
		base_h = 15.0
		for side in [-1, 1]: # fire bowls on the top tier
			mi(root, cyl(2.4, 1.4, 2.2, 10), mat(Color("#5a5048"), "coarse", 0.3), Vector3(side * 8, base_h + 1, 8))
			mi(root, sph(1.6, 8, 5), flat(Color(1.0, 0.6, 0.2)), Vector3(side * 8, base_h + 2.6, 8), Vector3.ZERO, Vector3(1, 1.4, 1))
	else:
		for i in 7:
			var a := i * TAU / 7
			boulder(root, Vector3(cos(a) * 10.5, 1.4, sin(a) * 10.5), 2.6, stone if i % 2 == 0 else stone2, 950 + i, 0.75, i * 50)
		_pot(root, Vector3(6, 0, 12), 0.8)
		mi(root, lumpy(sph(1.8, 8, 5), 0.3, 960, 0.6), mat(Color("#e8dcc0"), "fine", 0.3), Vector3(-6, 1.2, 12), Vector3.ZERO, Vector3(1, 0.8, 1.3))
	var h := 58.0 if grand else 44.0
	var wood := mat(Color("#6b4a2a"), "streak", 0.2, Vector3(1, 4, 1), 0.55)
	var paints := [Color("#b03a2b"), Color("#e0aa36"), Color("#2e7a9b"), Color("#2a1c12")]
	var faces := 4 if grand else 3
	var seg_h := (h - 10.0) / faces
	mi(root, cyl(3.4, 4.0, h, 10), wood, Vector3(0, base_h + h / 2, 0))
	for i in faces: # one carved face per block: brow, big eyes, a beak or snout, teeth
		var y := base_h + 2.0 + i * seg_h + seg_h / 2
		var r := 4.6 - i * 0.25
		mi(root, lumpy(cyl(r, r + 0.3, seg_h - 0.8, 12), 0.3, 970 + i, 0.4), wood, Vector3(0, y, 0))
		var paint := mat(paints[(i + 1) % 3], "fine", 0.3, Vector3.ONE, 0.3)
		mi(root, cyl(r + 0.35, r + 0.35, 1.2, 12), paint, Vector3(0, y + seg_h / 2 - 1.4, 0))
		mi(root, box(Vector3(r * 1.6, 1.1, 1.6)), paint, Vector3(0, y + 1.8, r - 0.2))
		for side in [-1, 1]:
			mi(root, sph(1.25, 8, 5), mat(Color("#f0ece0"), "fine"), Vector3(side * r * 0.42, y + 0.6, r - 0.3), Vector3.ZERO, Vector3(1, 1, 0.5))
			mi(root, sph(0.6, 6, 4), mat(paints[3], "fine"), Vector3(side * r * 0.42, y + 0.6, r + 0.15))
		if i % 2 == 0: # beak
			loft(root, [[Vector3(0, y - 0.6, r - 0.5), 1.2, 1.3], [Vector3(0, y - 1.4, r + 2.2), 0.8, 0.8], [Vector3(0, y - 2.8, r + 3.0), 0.15, 0.15]], mat(paints[1], "fine", 0.3), Vector3.UP, 7)
		else: # snout with teeth
			mi(root, box(Vector3(r * 1.0, 1.8, 2.4)), wood, Vector3(0, y - 1.4, r + 0.6))
			for t in 4: mi(root, box(Vector3(0.45, 0.8, 0.4)), mat(Color("#f0ece0"), "fine"), Vector3(-1.2 + t * 0.8, y - 2.5, r + 1.7))
	# thunderbird on top: head, spread wings (flattened lofts), painted feather tips
	var top := base_h + h
	var wing_m := mat(paints[0], "fine", 0.3, Vector3.ONE, 0.3, sn)
	var tip_m := mat(paints[3], "fine", 0.3, Vector3.ONE, 0.3, sn)
	var span := 16.0 if grand else 12.0
	for side in [-1, 1]:
		loft(root, [[Vector3(0, top - 2, 0), 1.5, 2.5], [Vector3(side * span * 0.4, top - 0.5, 0), 0.8, 3.4], [Vector3(side * span * 0.8, top + 1.5, 0), 0.6, 3.0], [Vector3(side * span, top + 3.0, 0), 0.3, 1.0]], wing_m, Vector3(0, 0, 1), 8)
		loft(root, [[Vector3(side * span * 0.75, top + 1.2, 0), 0.7, 3.1], [Vector3(side * span * 1.02, top + 3.1, 0), 0.25, 0.9]], tip_m, Vector3(0, 0, 1), 6)
	mi(root, sph(2.6, 10, 6), wood, Vector3(0, top + 1.2, 0.6))
	loft(root, [[Vector3(0, top + 1.2, 2.4), 0.9, 0.9], [Vector3(0, top + 0.6, 4.6), 0.6, 0.7], [Vector3(0, top - 0.6, 5.2), 0.1, 0.1]], mat(paints[1], "fine"), Vector3.UP, 6)
	return root

## A lookout tower: four raked poles lashed with braces, a plank platform with a rail, a
## thatched hood against the weather, a ladder and a red hide pennant.
func _tower(snowy: bool) -> Node3D:
	var root := Node3D.new()
	var sn := 0.6 if snowy else 0.0
	var wood := mat(Color("#7a5530"), "streak", 0.2, Vector3(1, 4, 1), 0.5, sn * 0.5)
	var lash := mat(Color("#c8b48a"), "fine", 0.3)
	var top := 34.0
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			segment(root, Vector3(sx * 9, 0, sz * 9), Vector3(sx * 5, top + 6, sz * 5), 0.9, wood)
	for h in [10.0, 22.0]: # cross braces on two faces
		var w: float = 9.0 - (h / top) * 4.0
		segment(root, Vector3(-w, h, w), Vector3(w, h + 7, w), 0.45, wood)
		segment(root, Vector3(w, h, -w), Vector3(w, h + 7, w), 0.45, wood)
		mi(root, cyl(1.1, 1.1, 1.2, 6), lash, Vector3(-w, h, w))
	mi(root, box(Vector3(14, 1.4, 14)), mat(Color("#8a6238"), "streak", 0.25, Vector3(4, 1, 1), 0.5, sn), Vector3(0, top, 0))
	for sx in [-1, 1]: # the rail
		mi(root, box(Vector3(0.6, 0.6, 13)), wood, Vector3(sx * 6.6, top + 4, 0))
		mi(root, box(Vector3(13, 0.6, 0.6)), wood, Vector3(0, top + 4, sx * 6.6))
	var thatch := mat(Color("#b39255"), "streak", 0.3, Vector3(1, 5, 1), 0.55, 0.85 if snowy else 0.0)
	mi(root, cyl(0.5, 10.5, 8, 12), thatch, Vector3(0, top + 11, 0))
	_fringe(root, top + 7.5, 10.2, 14, Color("#b39255"), snowy)
	segment(root, Vector3(3, 0, 13), Vector3(2, top, 7), 0.45, wood) # ladder rails
	segment(root, Vector3(-2, 0, 13), Vector3(-2.5, top, 7), 0.45, wood)
	for i in 8: segment(root, Vector3(2.9 - i * 0.12, 3 + i * 4, 12.4 - i * 0.75), Vector3(-2.1 - i * 0.06, 3 + i * 4, 12.4 - i * 0.75), 0.3, wood)
	segment(root, Vector3(5, top, -5), Vector3(5, top + 20, -5), 0.35, wood) # the pennant
	mi(root, box(Vector3(0.3, 4, 7)), mat(Color("#b8402a"), "fine", 0.2), Vector3(5, top + 17, -1.5))
	return root

## A smokehouse: a hide-covered smoke hut with a smoke hole, and a drying rack of poles
## hung with strips of meat and fish, beside a ringed fire pit.
func _smokehouse(snowy: bool) -> Node3D:
	var root := Node3D.new()
	var sn := 0.6 if snowy else 0.0
	var hide := mat(Color("#8f6c48"), "coarse", 0.1, Vector3(1, 3, 1), 0.5, sn)
	mi(root, lumpy(cyl(2.0, 11, 18, 16, 5), 0.3, 91, 0.2), hide, Vector3(-7, 9, -2))
	mi(root, cyl(2.2, 2.2, 1.2, 10), flat(Color("#2a1d12")), Vector3(-7, 18.4, -2)) # the smoke hole
	mi(root, box(Vector3(4.5, 7, 1)), mat(Color("#2a1a0e"), "fine"), Vector3(-7, 3.6, 8.6)) # the door flap
	var wood := mat(Color("#6e4b2a"), "streak", 0.2, Vector3(1, 4, 1), 0.5, sn * 0.5)
	for x in [5.0, 17.0]: # two A-frames
		segment(root, Vector3(x, 0, -6), Vector3(x, 14, 0), 0.6, wood)
		segment(root, Vector3(x, 0, 6), Vector3(x, 14, 0), 0.6, wood)
	segment(root, Vector3(4, 13, 0), Vector3(18, 13, 0), 0.5, wood)
	segment(root, Vector3(4, 9, 0), Vector3(18, 9, 0), 0.45, wood)
	var meat := mat(Color("#8a3426"), "coarse", 0.3, Vector3.ONE, 0.5)
	var fish := mat(Color("#b9b2a0"), "fine", 0.3)
	for i in 6:
		var x := 6.0 + i * 2.2
		mi(root, box(Vector3(1.0, 4.5, 0.6)), meat if i % 3 != 2 else fish, Vector3(x, 10.6 - (i % 2) * 0.6, 0.4), Vector3(0, 0, randf_range(-6, 6)))
		if i % 2 == 0: mi(root, box(Vector3(1.0, 3.5, 0.6)), meat, Vector3(x + 1, 6.6, -0.4))
	var stone := mat(Color("#7d776c"), "coarse", 0.25, Vector3.ONE, 0.5, sn)
	for i in 7:
		var a := i * TAU / 7
		boulder(root, Vector3(11 + cos(a) * 4.5, 0.8, 9 + sin(a) * 3.5), 1.4, stone, 900 + i)
	mi(root, cyl(3, 3, 0.4, 10), mat(Color("#2e2620"), "coarse", 0.3), Vector3(11, 0.3, 9))
	return root

## The cookhouse: a low clay-walled hall under a thatched roof with a smoke hole, its big
## cooking pot on a hearth of stones by the open door, pots stacked and firewood piled.
func _cookhouse(snowy: bool) -> Node3D:
	var root := Node3D.new()
	var sn := 0.6 if snowy else 0.0
	var clay := mat(Color("#a8825a"), "coarse", 0.2, Vector3.ONE, 0.5, sn * 0.3)
	mi(root, lumpy(box(Vector3(30, 10, 20)), 0.25, 61, 0.2), clay, Vector3(0, 5, -2)) # the walls
	var thatch := mat(Color("#a7703f"), "streak", 0.16, Vector3(1, 5, 1), 0.55, 0.85 if snowy else 0.0)
	for side in [-1.0, 1.0]: mi(root, box(Vector3(34, 1.6, 13)), thatch, Vector3(0, 13.5, side * 5.0 - 2.0), Vector3(side * 32.0, 0, 0))
	mi(root, cyl(2.0, 2.4, 2.0, 10), flat(Color("#2a1d12")), Vector3(-6, 17.0, -2)) # the smoke hole
	mi(root, box(Vector3(8, 7, 0.8)), mat(Color("#2a1a0e"), "fine"), Vector3(4, 3.6, 8.2)) # the open door
	var stone := mat(Color("#7d776c"), "coarse", 0.25, Vector3.ONE, 0.5, sn)
	for i in 8:
		var a := i * TAU / 8
		boulder(root, Vector3(-8 + cos(a) * 4.2, 0.7, 13 + sin(a) * 3.2), 1.3, stone, 1700 + i)
	mi(root, cyl(3.0, 3.0, 0.4, 10), mat(Color("#2e2620"), "coarse", 0.3), Vector3(-8, 0.3, 13)) # the embers
	var pot := mat(Color("#7a4a2c"), "fine", 0.25)
	mi(root, lumpy(sph(3.2, 12, 8), 0.1, 1710, 0.2), pot, Vector3(-8, 3.6, 13), Vector3.ZERO, Vector3(1.1, 0.85, 1.1)) # the big pot
	var wood := mat(Color("#6e4b2a"), "streak", 0.2, Vector3(1, 4, 1), 0.5, sn * 0.5)
	segment(root, Vector3(-12, 0, 13), Vector3(-8, 9, 13), 0.4, wood) # the tripod
	segment(root, Vector3(-4, 0, 13), Vector3(-8, 9, 13), 0.4, wood)
	for i in 5: mi(root, cyl(0.8, 0.8, 9, 6), wood, Vector3(13 + (i % 3) * 1.6, 0.9 + int(i / 3) * 1.5, 10), Vector3(0, 0, 90)) # firewood
	_pot(root, Vector3(10, 0, 14), 0.8)
	_pot(root, Vector3(13, 0, 15.5), 0.6)
	return root

## The Longhouse building (an upgrade of the large hut): the era-3 longhouse home, stretched
## into a long hall.
func _longhall(snowy: bool) -> Node3D:
	var root := Node3D.new()
	var lh := _longhouse(true, snowy)
	lh.scale = Vector3(1.3, 1.0, 1.05)
	root.add_child(lh)
	return root

## A temple: a round clay hall on a ring of stones, painted with ochre bands, under a tall
## thatched cone with a feathered spire, and a small totem by its door.
func _temple(snowy: bool) -> Node3D:
	var root := Node3D.new()
	var sn := 0.6 if snowy else 0.0
	var stone := mat(Color("#8f8b82"), "coarse", 0.2, Vector3.ONE, 0.6, sn)
	for i in 14:
		var a := i * TAU / 14
		boulder(root, Vector3(cos(a) * 17, 1.2, sin(a) * 17), 2.4, stone, 980 + i, 0.7, i * 30)
	mi(root, cyl(16.5, 17, 1.6, 20), mat(Color("#9a7a58"), "coarse", 0.2, Vector3.ONE, 0.5), Vector3(0, 0.8, 0))
	var clay := mat(Color("#c79a6a"), "coarse", 0.14, Vector3.ONE, 0.5)
	mi(root, lumpy(cyl(13, 13.5, 13, 20, 3), 0.25, 990, 0.2), clay, Vector3(0, 8, 0))
	for y in [5.0, 11.0]: mi(root, cyl(13.3, 13.3, 1.1, 20), mat(Color("#a8432c") if y < 8.0 else Color("#e0aa36"), "fine", 0.3), Vector3(0, y, 0))
	mi(root, box(Vector3(6, 9, 1.2)), mat(Color("#2a1a0e"), "fine"), Vector3(0, 6, 13.2))
	var thatch := mat(Color("#a9884a"), "streak", 0.3, Vector3(1, 5, 1), 0.55, 0.85 if snowy else 0.0)
	mi(root, lumpy(cyl(0.8, 17, 24, 20, 5), 0.3, 991, 0.18), thatch, Vector3(0, 26.5, 0))
	_fringe(root, 15.2, 16.6, 26, Color("#a9884a"), snowy)
	var wood := mat(Color("#5e3d22"), "streak", 0.2, Vector3(1, 4, 1))
	segment(root, Vector3(0, 37, 0), Vector3(0, 47, 0), 0.5, wood)
	for i in 3:
		mi(root, box(Vector3(0.4, 4.0, 1.4)), mat([Color("#b03a2b"), Color("#f0ece0"), Color("#2e7a9b")][i], "fine"), Vector3(0, 44.5 - i * 1.5, 0.8), Vector3(0, i * 60, 25))
	var t := _shrine(false, snowy)
	t.scale = Vector3.ONE * 0.5
	t.position = Vector3(-12, 0, 16)
	root.add_child(t)
	return root

## How many turns a stone wall block is baked in (over half a circle: a block is the same
## either way round), so a ring of them follows its curve. world_view picks the nearest.
const WALL_DIRS := 8
## The things in a home's yard, more of them as the settlement grows (world_view._yard_props).
const YARD_PROPS := ["wood", "pots", "rack", "baskets", "block"]

## One block of a stone wall: fitted stones in courses, a coping of flat stones. `yaw` turns
## it (its length runs along model x, which is world (cos yaw, -sin yaw)).
func _wall_stone(snowy: bool, yaw := 0.0) -> Node3D:
	var holder := Node3D.new()
	var root := Node3D.new()
	root.rotation_degrees.y = yaw
	holder.add_child(root)
	var sn := 0.6 if snowy else 0.0
	var s1 := mat(Color("#8f8b82"), "coarse", 0.2, Vector3.ONE, 0.6, sn * 0.4)
	var s2 := mat(Color("#7a766e"), "coarse", 0.2, Vector3.ONE, 0.6, sn * 0.4)
	for course in 3:
		for i in 3:
			var x := -6.0 + i * 6.0 + (3.0 if course % 2 == 1 else 0.0) - 1.5
			mi(root, lumpy(box(Vector3(5.6, 4.2, 6)), 0.35, 1100 + course * 7 + i, 0.3, true), s1 if (i + course) % 2 == 0 else s2, Vector3(x, 2.1 + course * 4.2, 0))
	mi(root, box(Vector3(17, 1.6, 7.4)), mat(Color("#9a968c"), "coarse", 0.2, Vector3.ONE, 0.55, sn), Vector3(0, 13.4, 0))
	return holder

## A yard prop by a home: a woodpile, pots, a hide on a drying frame, baskets of grain, a
## chopping block with its axe.
func _yard(kind: String, snowy: bool) -> Node3D:
	var root := Node3D.new()
	var sn := 0.6 if snowy else 0.0
	match kind:
		"wood": _woodpile(root, Vector3.ZERO, 30.0)
		"pots":
			_pot(root, Vector3(-2.2, 0, 0.5), 1.0)
			_pot(root, Vector3(2.0, 0, -0.8), 0.8)
			_pot(root, Vector3(0.6, 0, 2.6), 0.65)
		"rack": _drying_rack(root, Vector3.ZERO, 20.0)
		"baskets":
			var weave := mat(Color("#a8844e"), "streak", 0.3, Vector3(1, 3, 1), 0.5, sn * 0.5)
			var grain := mat(Color("#d8b860"), "coarse", 0.5, Vector3.ONE, 0.4, sn)
			for i in 3:
				var q := Vector3(-3.0 + i * 3.0, 0, (i % 2) * 2.0 - 1.0)
				var h := 3.6 - (i % 2) * 0.8
				mi(root, cyl(1.7, 1.3, h, 9), weave, q + Vector3(0, h / 2, 0))
				mi(root, sph(1.5, 8, 4), grain, q + Vector3(0, h, 0), Vector3.ZERO, Vector3(1, 0.45, 1))
		"block":
			var wood := mat(Color("#7a5530"), "streak", 0.25, Vector3(1, 3, 1), 0.5, sn * 0.5)
			mi(root, cyl(2.4, 2.6, 3.2, 10), wood, Vector3(0, 1.6, 0))
			mi(root, cyl(2.3, 2.3, 0.15, 10), mat(Color("#c8a070"), "fine", 0.4, Vector3.ONE, 0.3, sn), Vector3(0, 3.25, 0))
			segment(root, Vector3(0.3, 3.3, 0), Vector3(3.6, 6.4, 0.8), 0.3, mat(Color("#5c3f22"), "streak", 0.2))
			mi(root, box(Vector3(1.8, 1.4, 0.4)), mat(Color("#8a877e"), "fine", 0.3), Vector3(0.6, 3.6, 0.2), Vector3(0, 0, 40))
			for i in 3: mi(root, cyl(0.7, 0.7, 4.5, 6), mat(Color("#6e4b2a"), "streak", 0.25), Vector3(-3.6 + i * 0.4, 0.7, 1.6 - i * 1.2), Vector3(90, 20 * i, 0))
	return root

## A tower in a stone wall: a round stone drum with a wooden fighting platform and a
## thatched hood.
func _wall_tower(snowy: bool) -> Node3D:
	var root := Node3D.new()
	var sn := 0.6 if snowy else 0.0
	var st := mat(Color("#8a867d"), "coarse", 0.2, Vector3.ONE, 0.6, sn * 0.4)
	mi(root, lumpy(cyl(8, 9, 24, 14, 4), 0.4, 1200, 0.25), st, Vector3(0, 12, 0))
	for i in 8: # crenellations
		var a := i * TAU / 8
		mi(root, box(Vector3(3, 3.5, 3)), st, Vector3(cos(a) * 7.6, 25.6, sin(a) * 7.6), Vector3(0, -rad_to_deg(a), 0))
	mi(root, box(Vector3(2.5, 4, 0.8)), mat(Color("#1e140a"), "fine"), Vector3(0, 16, 8.6))
	var thatch := mat(Color("#a9884a"), "streak", 0.3, Vector3(1, 5, 1), 0.55, 0.85 if snowy else 0.0)
	mi(root, cyl(0.5, 9.5, 9, 12), thatch, Vector3(0, 32, 0))
	_fringe(root, 27.8, 9.2, 14, Color("#a9884a"), snowy)
	return root

## A trading post: a hide awning on poles over a plank counter laid with goods, bundles,
## pots and a rack of furs.
func _trading_post(snowy: bool) -> Node3D:
	var root := Node3D.new()
	var sn := 0.6 if snowy else 0.0
	var wood := mat(Color("#7a5530"), "streak", 0.2, Vector3(1, 4, 1), 0.5, sn * 0.5)
	for x in [-14.0, 14.0]:
		for z in [-8.0, 8.0]: segment(root, Vector3(x, 0, z), Vector3(x, 20 + (z * 0.25), z), 0.8, wood)
	var awning := mat(Color("#b8573a"), "coarse", 0.12, Vector3(1, 3, 1), 0.5, sn)
	mi(root, box(Vector3(32, 1.0, 20)), awning, Vector3(0, 21, 0), Vector3(-10, 0, 0))
	for i in 5: mi(root, box(Vector3(6, 0.4, 0.3)), mat(Color("#e6c27a"), "fine"), Vector3(-13 + i * 6.5, 21.2, 10.4), Vector3(-10, 0, 0)) # a painted hem
	mi(root, box(Vector3(26, 1.2, 6)), mat(Color("#8a6238"), "streak", 0.25, Vector3(4, 1, 1), 0.5), Vector3(0, 7, 5)) # the counter
	for x in [-11.0, 11.0]: mi(root, box(Vector3(1.4, 7, 1.4)), wood, Vector3(x, 3.5, 5))
	for i in 4: _pot(root, Vector3(-9 + i * 5.5, 7.6, 5.5), 0.55)
	var fur := mat(Color("#9a7a54"), "coarse", 0.3, Vector3.ONE, 0.5)
	for i in 3: mi(root, lumpy(sph(3.2, 10, 6), 0.4, 1300 + i, 0.5), fur, Vector3(-16 + i * 3, 2.4, -4 + i * 2), Vector3.ZERO, Vector3(1.3, 0.7, 1))
	mi(root, lumpy(box(Vector3(6, 5, 5)), 0.3, 1310, 0.3), mat(Color("#c4a26a"), "coarse", 0.3), Vector3(16, 2.5, -3)) # a bundle
	return root

## The warehouse: a long timber storehouse raised on stilts over stone footings (dry and out
## of the mice's reach), plank walls, a pitched thatch roof, a ramp to its door, and sacks
## and jars stacked beside it.
func _warehouse(snowy: bool) -> Node3D:
	var root := Node3D.new()
	var sn := 0.6 if snowy else 0.0
	var wood := mat(Color("#6e4b2a"), "streak", 0.2, Vector3(1, 4, 1), 0.5, sn * 0.4)
	var plank := mat(Color("#8a6238"), "streak", 0.22, Vector3(4, 1, 1), 0.5, sn * 0.3)
	var stone := mat(Color("#7d776c"), "coarse", 0.25, Vector3.ONE, 0.5, sn)
	for x in [-16.0, -5.5, 5.5, 16.0]: # stilts on footing stones
		for z in [-8.0, 8.0]:
			boulder(root, Vector3(x, 0.8, z), 2.0, stone, 1400 + int(x * 3 + z))
			mi(root, cyl(1.0, 1.1, 6, 6), wood, Vector3(x, 3.5, z))
	mi(root, box(Vector3(38, 1.4, 20)), plank, Vector3(0, 7, 0)) # the floor
	mi(root, box(Vector3(36, 11, 18)), plank, Vector3(0, 13, 0)) # the walls
	var post := mat(Color("#5a3a20"), "streak", 0.3, Vector3(1, 4, 1))
	for x in [-18.0, 18.0]:
		for z in [-9.0, 9.0]: mi(root, box(Vector3(1.6, 12, 1.6)), post, Vector3(x, 13, z))
	var thatch := mat(Color("#a7703f"), "streak", 0.16, Vector3(1, 5, 1), 0.55, 0.85 if snowy else 0.0)
	for side in [-1.0, 1.0]: # the pitched roof, eaves overhanging
		mi(root, box(Vector3(42, 1.6, 14.5)), thatch, Vector3(0, 23.5, side * 5.6), Vector3(side * 38.0, 0, 0))
	mi(root, box(Vector3(42, 1.2, 1.6)), mat(Color("#5a3a20"), "streak", 0.3, Vector3(4, 1, 1)), Vector3(0, 27.6, 0)) # the ridge
	mi(root, box(Vector3(6, 8, 0.8)), mat(Color("#2a1a0e"), "fine"), Vector3(0, 12, 9.2)) # the door
	segment(root, Vector3(-2.5, 0, 22), Vector3(-2.5, 7, 10), 0.5, wood) # the ramp
	segment(root, Vector3(2.5, 0, 22), Vector3(2.5, 7, 10), 0.5, wood)
	for i in 5: mi(root, box(Vector3(5.6, 0.5, 1.6)), plank, Vector3(0, 1.4 + i * 1.4, 20 - i * 2.4), Vector3(-30, 0, 0))
	var sack := mat(Color("#c8b083"), "coarse", 0.3, Vector3.ONE, 0.5, sn * 0.5)
	for i in 4: mi(root, lumpy(sph(2.6, 10, 6), 0.35, 1450 + i, 0.4), sack, Vector3(-14 + (i % 2) * 4.5, 2.0 + int(i / 2) * 3.2, 14 + (i % 2)), Vector3.ZERO, Vector3(1.2, 0.8, 1))
	_pot(root, Vector3(12, 0, 14), 0.9)
	_pot(root, Vector3(16, 0, 12), 0.7)
	_pot(root, Vector3(14.5, 0, 16.5), 0.6)
	root.scale = Vector3.ONE * 1.35 # (it holds five granaries' worth: it should look it)
	var holder := Node3D.new()
	holder.add_child(root)
	return holder

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
		ox.scale = Vector3.ONE * 0.85
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
## Body plans: torso / neck / head are rings [z, y, half-width, half-depth] along the
## spine (+z = forward); legs are joint chains from the hip (lengths, rest angles from
## straight down, radii at each joint).
const BEASTS := {
	"deer": {"col": "#94653a", "under": "#e6d6b6", "under_y": 14.2, "leg_col": "#7a522e", "sock": "#3e2a18", "sock_y": 3.5,
		"torso": [[-11.6, 16.8, 0.6, 0.6], [-10.6, 16.8, 3.0, 3.5], [-7.5, 16.9, 3.9, 4.4], [-3, 16.4, 3.4, 3.9], [2, 16.5, 3.6, 4.5], [6, 17.0, 3.4, 4.5], [8.6, 18.2, 2.5, 3.4], [9.6, 19.3, 1.0, 1.0]],
		"neck": [[7.0, 18.4, 2.2, 2.8], [8.8, 21.5, 1.7, 2.1], [10.2, 24.6, 1.45, 1.8], [11.0, 26.6, 1.3, 1.5]],
		"head": [[10.0, 27.6, 0.7, 0.7], [10.8, 27.6, 1.8, 1.95], [12.6, 27.0, 1.55, 1.6], [14.4, 25.9, 0.95, 1.05], [15.6, 25.2, 0.55, 0.55]],
		"front": [Vector3(2.0, 15.0, 6.2), [5.6, 5.4, 4.6], [0.06, -0.04, 0.0], [1.6, 0.85, 0.55, 0.45]],
		"hind": [Vector3(2.2, 15.4, -7.4), [6.0, 5.8, 5.6], [0.42, -0.55, -0.04], [2.5, 1.2, 0.6, 0.45]],
		"foot": "hoof", "foot_r": 0.55,
		"tail": [[-10.8, 18.0, 0.9, 0.6], [-11.9, 17.2, 1.1, 0.8], [-12.4, 15.6, 0.7, 0.5]], "tail_col": "#f0e6d0",
		"ears": "leaf", "eye_r": 0.42},
	"wolf": {"col": "#7b7b80", "under": "#cfccc4", "under_y": 11.6, "leg_col": "#8c8a86", "sock": "#b8b4ac", "sock_y": 2.5, "back": "#4e4e54",
		"torso": [[-9.6, 13.2, 0.6, 0.6], [-8.6, 13.2, 2.8, 3.0], [-5.6, 13.4, 3.1, 3.3], [-1, 13.0, 2.7, 2.9], [3.4, 12.8, 3.3, 4.4], [6.8, 13.4, 3.4, 4.4], [8.8, 14.8, 2.6, 3.2], [9.6, 15.8, 1.0, 1.0]],
		"neck": [[6.8, 14.6, 3.1, 3.8], [9.2, 16.6, 2.7, 3.1], [10.8, 18.0, 2.2, 2.4]],
		"head": [[9.6, 19.0, 0.8, 0.8], [10.6, 19.0, 2.3, 2.2], [12.4, 18.5, 1.9, 1.8], [14.0, 17.7, 1.0, 1.0], [15.6, 17.3, 0.72, 0.65], [16.3, 17.1, 0.3, 0.3]],
		"front": [Vector3(1.7, 11.8, 6.0), [4.6, 4.3, 2.8], [0.08, -0.05, 0.16], [1.5, 0.85, 0.6, 0.55]],
		"hind": [Vector3(1.9, 12.4, -6.0), [4.9, 4.7, 3.7], [0.5, -0.62, 0.0], [2.2, 1.15, 0.6, 0.55]],
		"foot": "paw", "foot_r": 0.85,
		"tail": [[-9.0, 14.2, 0.9, 0.9], [-10.8, 13.0, 1.6, 1.7], [-12.6, 10.6, 1.9, 1.9], [-13.8, 8.2, 1.4, 1.4], [-14.3, 6.8, 0.35, 0.35]], "tail_col": "#5e5e64",
		"ears": "point", "eye_r": 0.36, "eye_col": "#d8a030"},
	"tiger": {"col": "#d6832a", "under": "#f3e9d4", "under_y": 10.6, "leg_col": "#d6832a", "sock": "#f3e9d4", "sock_y": 2.6, "stripes": true,
		"torso": [[-12.2, 12.8, 0.7, 0.7], [-11.2, 12.8, 3.9, 4.2], [-7.2, 12.8, 4.5, 4.8], [-1.2, 12.3, 4.1, 4.3], [4.8, 12.7, 4.7, 5.3], [8.8, 13.5, 4.5, 5.1], [11.2, 14.6, 3.4, 3.8], [12.2, 15.4, 1.2, 1.2]],
		"neck": [[9.4, 14.6, 3.6, 4.2], [11.8, 15.6, 3.2, 3.4], [13.2, 16.1, 2.8, 2.8]],
		"head": [[12.6, 17.0, 1.0, 1.0], [13.4, 17.0, 3.4, 3.1], [15.3, 16.5, 3.0, 2.7], [17.0, 15.6, 1.8, 1.6], [18.1, 15.2, 1.0, 0.9], [18.6, 15.1, 0.4, 0.4]],
		"front": [Vector3(2.6, 10.8, 7.6), [4.1, 3.9, 2.4], [0.1, -0.05, 0.25], [2.3, 1.5, 1.2, 1.1]],
		"hind": [Vector3(2.8, 11.4, -7.6), [4.6, 4.3, 3.1], [0.45, -0.58, 0.05], [3.1, 1.7, 1.1, 1.0]],
		"foot": "paw", "foot_r": 1.5,
		"tail": [[-12.0, 13.6, 1.1, 1.1], [-15.0, 12.6, 1.0, 1.0], [-18.0, 10.2, 0.9, 0.9], [-20.2, 8.8, 0.8, 0.8], [-22.2, 9.4, 0.7, 0.7], [-23.2, 11.0, 0.5, 0.5]], "tail_col": "#d6832a",
		"ears": "round", "eye_r": 0.5, "eye_col": "#e8c040"},
	"packox": {"col": "#5c3e28", "under": "#7d6048", "under_y": 9.0, "leg_col": "#4e3420", "sock": "#2e1e12", "sock_y": 2.0,
		"torso": [[-10.2, 12.2, 0.8, 0.8], [-9.2, 12.3, 4.6, 4.8], [-5, 12.4, 5.4, 5.6], [0, 12.2, 5.4, 5.8], [4.6, 13.2, 5.6, 6.6], [7.8, 14.0, 4.8, 5.8], [9.8, 15.0, 3.0, 3.6], [10.6, 15.6, 1.2, 1.2]],
		"neck": [[7.8, 13.6, 3.6, 4.6], [10.4, 13.0, 3.0, 3.7], [11.8, 12.6, 2.6, 3.0]],
		"head": [[11.2, 14.0, 1.2, 1.2], [12.0, 13.6, 2.8, 3.0], [13.8, 12.6, 2.4, 2.6], [15.4, 11.3, 2.0, 1.9], [16.2, 10.7, 1.45, 1.35], [16.6, 10.4, 0.6, 0.6]],
		"front": [Vector3(3.0, 9.4, 6.0), [3.3, 3.3, 2.4], [0.05, -0.03, 0.0], [2.6, 1.5, 1.1, 1.0]],
		"hind": [Vector3(3.2, 9.8, -6.4), [3.7, 3.5, 2.7], [0.35, -0.45, 0.0], [3.2, 1.6, 1.1, 1.0]],
		"foot": "hoof", "foot_r": 1.1,
		"tail": [[-10.0, 13.6, 0.6, 0.6], [-10.8, 10.0, 0.5, 0.5], [-11.0, 6.2, 0.45, 0.45], [-11.0, 4.6, 0.95, 0.95], [-11.0, 3.2, 0.2, 0.2]], "tail_col": "#2e1e12",
		"ears": "flat", "eye_r": 0.4},
	"aurochs": {"col": "#33241a", "under": "#4a3626", "under_y": 10.0, "leg_col": "#2c1f15", "sock": "#cfc2a8", "sock_y": 2.6, "back": "#8a6a44",
		"torso": [[-11.4, 13.4, 0.8, 0.8], [-10.4, 13.5, 5.0, 5.2], [-6, 13.6, 5.8, 6.0], [0, 13.4, 5.8, 6.2], [5.2, 14.6, 6.2, 7.2], [8.8, 15.4, 5.2, 6.2], [11.0, 16.4, 3.2, 3.8], [11.8, 17.0, 1.2, 1.2]],
		"neck": [[8.8, 15.0, 3.9, 5.0], [11.6, 14.2, 3.2, 4.0], [13.2, 13.8, 2.8, 3.2]],
		"head": [[12.6, 15.4, 1.2, 1.2], [13.4, 15.0, 3.0, 3.2], [15.2, 14.0, 2.6, 2.8], [16.9, 12.6, 2.1, 2.0], [17.7, 12.0, 1.5, 1.4], [18.1, 11.7, 0.6, 0.6]],
		"front": [Vector3(3.3, 10.6, 6.6), [3.8, 3.7, 2.6], [0.05, -0.03, 0.0], [2.8, 1.6, 1.15, 1.05]],
		"hind": [Vector3(3.5, 11.0, -7.0), [4.2, 3.9, 3.0], [0.35, -0.45, 0.0], [3.4, 1.7, 1.15, 1.05]],
		"foot": "hoof", "foot_r": 1.15,
		"tail": [[-11.2, 15.0, 0.6, 0.6], [-12.0, 11.0, 0.5, 0.5], [-12.2, 6.8, 0.45, 0.45], [-12.2, 5.0, 1.0, 1.0], [-12.2, 3.6, 0.2, 0.2]], "tail_col": "#1a120c",
		"ears": "flat", "eye_r": 0.42},
}

func _beast(kind: String, yaw: float, phase: float, walking: bool, anim := "") -> Node3D:
	var holder := Node3D.new()
	holder.rotation_degrees.y = yaw
	var root := Node3D.new()
	holder.add_child(root)
	var sp: Dictionary = BEASTS[kind]
	var lunge := 0.0
	if anim == "attack": # crouch, then spring forward with forelegs up
		lunge = [0.0, 0.3, 1.0, 0.6][int(phase * 4) % 4]
		root.position.z = lunge * 5.0
		root.rotation_degrees.x = -lunge * 16.0
	elif anim == "dead": # lying on its side
		root.rotation_degrees.z = 86.0
		root.position = Vector3(sp["torso"][3][1] * 0.98, sp["torso"][3][2] * 0.95, 0)
	var stripes: bool = sp.get("stripes", false)
	var hide := tune(mat(Color(sp["col"]), "fine", 0.25, Vector3.ONE, 0.3), {"under_color": Color(sp["under"]), "under_amt": 1.0, "under_y": sp["under_y"], "under_soft": 1.6})
	if stripes: tune(hide, {"stripe_color": Color("#1c1009"), "stripe_amt": 0.95, "stripe_axis": Vector3(0, 0.25, 1), "stripe_freq": 1.15})
	var legm := tune(mat(Color(sp["leg_col"]), "fine", 0.25, Vector3.ONE, 0.3), {"under_color": Color(sp["sock"]), "under_amt": 1.0, "under_y": sp["sock_y"], "under_soft": 1.2})
	if stripes: tune(legm, {"stripe_color": Color("#1c1009"), "stripe_amt": 0.8, "stripe_axis": Vector3(0, 1, 0), "stripe_freq": 1.3})
	var dark := mat(Color("#1a1410"), "fine", 0.3, Vector3.ONE, 0.2)
	var plain := mat(Color(sp["col"]), "fine", 0.25, Vector3.ONE, 0.3) # small primitives (their mesh space is local)
	# head bobs with the stride; a grazing deer lowers it when idle
	var bobz := sin(phase * TAU * 2.0) * 0.4 if walking else 0.0
	var _ring := func(r: Array, dy := 0.0, dz := 0.0) -> Array: return [Vector3(0, r[1] + dy, r[0] + dz), r[2], r[3]]
	var rings := []
	for r in sp["torso"]: rings.append(_ring.call(r, bobz * 0.3))
	loft(root, rings, hide, Vector3.UP, 14)
	if sp.has("back"): # darker saddle along the spine
		var saddle := []
		for r in sp["torso"].slice(1, 6): saddle.append([Vector3(0, r[1] + r[3] * 0.55 + bobz * 0.3, r[0]), r[2] * 0.62, r[3] * 0.42])
		loft(root, saddle, mat(Color(sp["back"]), "fine", 0.25, Vector3.ONE, 0.35), Vector3.UP, 10)
	var head_drop := 0.0
	var neck := []
	for r in sp["neck"]: neck.append(_ring.call(r, bobz - head_drop * 0.5))
	loft(root, neck, hide, Vector3.UP, 12)
	var head := []
	for r in sp["head"]: head.append(_ring.call(r, bobz - head_drop))
	loft(root, head, hide, Vector3.UP, 12)
	var hd: Array = sp["head"]
	var skull := Vector3(0, hd[1][1] + bobz - head_drop, hd[1][0])
	var nose := Vector3(0, hd[hd.size() - 1][1] + bobz - head_drop, hd[hd.size() - 1][0])
	mi(root, sph(maxf(0.5, hd[hd.size() - 2][2] * 0.55), 8, 5), dark, nose + Vector3(0, 0.2, -0.1))
	var eye_m := mat(Color(sp.get("eye_col", "#140e0a")), "fine", 0.3, Vector3.ONE, 0.1)
	for side in [-1, 1]:
		mi(root, sph(sp["eye_r"], 6, 4), eye_m, skull + Vector3(side * hd[1][2] * 0.78, hd[1][3] * 0.35, hd[1][2] * 0.6))
		var ear_base := skull + Vector3(side * hd[1][2] * 0.7, hd[1][3] * 0.75, -0.6)
		match sp["ears"]:
			"leaf": loft(root, [[ear_base, 0.5, 0.3], [ear_base + Vector3(side * 1.6, 1.4, -0.6), 1.1, 0.35], [ear_base + Vector3(side * 3.2, 2.4, -1.0), 0.15, 0.1]], hide, Vector3(0, 0, 1), 6)
			"point": loft(root, [[ear_base, 0.9, 0.5], [ear_base + Vector3(side * 0.5, 1.5, -0.2), 0.6, 0.35], [ear_base + Vector3(side * 0.7, 3.0, -0.4), 0.08, 0.08]], hide, Vector3(0, 0, 1), 6)
			"round": mi(root, sph(1.1, 8, 5), plain, ear_base + Vector3(side * 0.3, 0.5, -0.4), Vector3.ZERO, Vector3(1, 1, 0.5))
			"flat": loft(root, [[ear_base + Vector3(0, -1.0, 0), 0.5, 0.3], [ear_base + Vector3(side * 1.6, -0.9, -0.2), 0.8, 0.3], [ear_base + Vector3(side * 2.8, -1.2, -0.3), 0.1, 0.1]], hide, Vector3(0, 0, 1), 6)
	match kind:
		"deer": # branching antlers
			var antler := mat(Color("#e2d3b2"), "fine", 0.3, Vector3.ONE, 0.25)
			for side in [-1, 1]:
				var a0 := skull + Vector3(side * 0.9, hd[1][3] * 0.85, -0.2)
				var a1 := a0 + Vector3(side * 1.6, 3.2, -0.8)
				var a2 := a1 + Vector3(side * 1.2, 3.0, 0.4)
				var a3 := a2 + Vector3(side * 0.4, 2.2, 1.2)
				limb(root, [a0, a1, a2, a3], [0.45, 0.38, 0.3, 0.12], antler, 5)
				limb(root, [a1, a1 + Vector3(side * 0.2, 1.4, 1.6)], [0.3, 0.08], antler, 5)
				limb(root, [a2, a2 + Vector3(side * 1.6, 1.2, -0.6)], [0.25, 0.07], antler, 5)
		"tiger": # white cheek ruff and muzzle
			var white := mat(Color("#f3e9d4"), "fine", 0.25, Vector3.ONE, 0.2)
			for side in [-1, 1]: mi(root, sph(1.5, 8, 5), white, skull + Vector3(side * 2.2, -1.0, 1.6), Vector3.ZERO, Vector3(0.8, 1, 1.1))
			mi(root, sph(1.4, 8, 5), white, Vector3(0, hd[3][1] - 0.5 + bobz, hd[3][0] + 0.3), Vector3.ZERO, Vector3(1.1, 0.7, 1))
			for side in [-1, 1]: mi(root, cyl(0.12, 0.4, 2.0, 4), mat(Color.WHITE, "fine"), Vector3(side * 0.7, hd[4][1] - 1.4 + bobz, hd[4][0] - 0.1), Vector3(180, 0, 0))
		"wolf": # pale muzzle
			mi(root, sph(1.0, 8, 5), mat(Color("#cfccc4"), "fine", 0.25), Vector3(0, hd[3][1] - 0.4 + bobz, hd[3][0] + 0.6), Vector3.ZERO, Vector3(1, 0.6, 1.8))
		"aurochs": # great lyre horns swept forward
			var horn := tune(mat(Color("#e6dac0"), "fine", 0.3, Vector3.ONE, 0.25), {"under_color": Color("#2a2018"), "under_amt": 1.0, "under_y": skull.y + 3.5, "under_soft": 1.5})
			for side in [-1, 1]:
				var h0 := skull + Vector3(side * 2.2, hd[1][3] * 0.6, -0.4)
				limb(root, [h0, h0 + Vector3(side * 3.4, 0.8, 0.0), h0 + Vector3(side * 5.6, 3.2, 1.6), h0 + Vector3(side * 5.4, 6.0, 4.0)], [1.0, 0.75, 0.45, 0.1], horn, 6)
		"packox": # curved horns, a hump blanket and panniers
			var horn := mat(Color("#e6dac0"), "fine", 0.3, Vector3.ONE, 0.25)
			for side in [-1, 1]:
				var h0 := skull + Vector3(side * 2.0, hd[1][3] * 0.6, -0.4)
				limb(root, [h0, h0 + Vector3(side * 2.4, 0.6, 0.2), h0 + Vector3(side * 3.8, 2.2, 0.8), h0 + Vector3(side * 4.0, 3.8, 1.4)], [0.8, 0.6, 0.38, 0.1], horn, 6)
			var blanket := mat(Color("#a8323a"), "coarse", 0.3, Vector3.ONE, 0.4)
			var top_y: float = 13.2 + 6.6
			loft(root, [[Vector3(0, top_y - 2.6, -4), 5.9, 2.8], [Vector3(0, top_y - 2.2, 0), 6.1, 3.0], [Vector3(0, top_y - 2.4, 3.5), 6.0, 2.9]], blanket, Vector3.UP, 12)
			var bundle := mat(Color("#a0784a"), "coarse", 0.3, Vector3.ONE, 0.5)
			var rope := mat(Color("#d8c8a0"), "fine", 0.4)
			for side in [-1, 1]:
				var c := Vector3(side * 6.4, 12.6, -0.5)
				mi(root, lumpy(cap(2.6, 8.0), 0.5, 7 + side), bundle, c, Vector3(90, 0, 0))
				mi(root, cyl(2.75, 2.75, 0.6, 10), rope, c, Vector3(90, 0, 0))
			mi(root, cyl(1.5, 1.5, 9.0, 8), mat(Color("#6e4b2a"), "streak", 0.3, Vector3(4, 1, 1)), Vector3(0, top_y + 0.8, -0.5), Vector3(0, 0, 90))
	# legs: diagonal pairs move together; the lower joints fold on the forward swing
	var hips := [[sp["front"], 1, 0.0], [sp["front"], -1, 0.5], [sp["hind"], 1, 0.5], [sp["hind"], -1, 0.0]]
	var foot_r: float = sp["foot_r"]
	for h in hips:
		var spec: Array = h[0]
		var side: int = h[1]
		var front: bool = spec == sp["front"]
		var ph: float = (phase + h[2]) * TAU
		var angles: Array = spec[2].duplicate()
		if walking:
			var sw := sin(ph) * 0.42
			var flex := maxf(0.0, cos(ph)) * 0.7
			angles[0] += sw
			if front:
				angles[1] += sw - flex * 0.2
				angles[2] += sw - flex * 1.1
			else:
				angles[1] += sw - flex * 0.6
				angles[2] += sw + flex * 0.3
		if anim == "attack" and front:
			angles = [spec[2][0] + 1.4 * lunge, spec[2][1] + 0.6 * lunge, spec[2][2] + 0.1 * lunge]
		if anim == "attack" and not front:
			angles = [spec[2][0] - 0.3 * lunge, spec[2][1] - 0.2 * lunge, spec[2][2] - 0.4 * lunge]
		if anim == "dead": angles = [spec[2][0] * 0.4 + (0.35 if front else -0.35), 0.1, 0.0]
		var top: Vector3 = spec[0]
		# scale the rest pose so standing feet reach the ground
		var lens: Array = spec[1]
		var reach := 0.0
		for i in lens.size(): reach += lens[i] * cos(spec[2][i])
		var k: float = (top.y + bobz * 0.3) / reach
		var sl := []
		for l in lens: sl.append(l * k)
		var pts := chain(Vector3(side * top.x, top.y + bobz * 0.3, top.z), sl, angles)
		limb(root, pts, spec[3], legm, 8)
		var foot: Vector3 = pts[pts.size() - 1]
		if sp["foot"] == "hoof":
			mi(root, cyl(foot_r * 0.8, foot_r * 1.1, 1.3, 7), dark, foot + Vector3(0, 0.45, 0.15))
		else:
			mi(root, sph(foot_r, 8, 5), legm, foot + Vector3(0, foot_r * 0.45, foot_r * 0.4), Vector3.ZERO, Vector3(1, 0.6, 1.3))
	# tail sways while walking
	var tail := []
	var wag := sin(phase * TAU) * 1.2 if walking else 0.0
	var tl: Array = sp["tail"]
	for i in tl.size():
		var r: Array = tl[i]
		tail.append([Vector3(wag * i / tl.size(), r[1], r[0]), r[2], r[3]])
	var tail_m: Material = hide if kind == "tiger" else tune(mat(Color(sp["col"]), "fine", 0.25, Vector3.ONE, 0.3), {"under_color": Color(sp["tail_col"]), "under_amt": 1.0, "under_y": tl[1][1] + 0.4, "under_soft": 1.2})
	loft(root, tail, tail_m, Vector3.UP, 8)
	if kind == "tiger": mi(root, sph(0.6, 6, 4), dark, tail[tail.size() - 1][0])
	return holder

# ---- people
## A villager in a pose. cloth_only renders the tunic white and everything else black
## so the game can tint the clothes per person. Legs bend at the knee (feet stay on the
## ground: the body drops to the lowest standing leg), arms bend at the elbow.
## A villager in a pose. `weapon` (attack only): which weapon they fight with (arms.gd ids).
func _person(yaw: float, anim: String, phase: float, cloth_only: bool, tool := "stone", weapon := "spear") -> Node3D:
	var holder := Node3D.new()
	holder.rotation_degrees.y = yaw
	var root := Node3D.new()
	holder.add_child(root)
	var skin: Material = mat(Color("#cf9a70"), "fine", 0.4, Vector3.ONE, 0.12)
	var hair: Material = mat(Color("#24160c"), "streak", 0.5, Vector3(1, 3, 1), 0.35)
	var cloth: Material = mat(Color("#d8d0c0") if not cloth_only else Color(1, 1, 1), "coarse", 0.4, Vector3.ONE, 0.35)
	var fur: Material = mat(Color("#7a5a3a"), "fine", 0.6, Vector3(1, 2, 1), 0.7)
	var leather: Material = mat(Color("#5a3a22"), "coarse", 0.5, Vector3.ONE, 0.4)
	var wood: Material = mat(Color("#6b4524"), "streak", 0.4, Vector3(1, 4, 1))
	var head_m: Material = mat(Color("#7d7d86"), "coarse", 0.5, Vector3.ONE, 0.6) if tool == "stone" else mat(Color("#d49a3a"), "fine", 0.4, Vector3.ONE, 0.3)
	var dark: Material = mat(Color("#140c08"), "fine", 0.3, Vector3.ONE, 0.1)
	if cloth_only:
		var black := flat(Color.BLACK)
		skin = black
		hair = black
		fur = black
		leather = black
		wood = black
		head_m = black
		dark = black
	var k := int(phase * 4) % 4 # frame index for 4-frame actions
	var s := sin(phase * TAU)
	var c := cos(phase * TAU)
	var legs := {-1: [0.0, 0.05], 1: [0.0, 0.05]} # side -> [thigh angle fwd, knee flex] (radians)
	var arm := {-1: 4.0, 1: 4.0} # shoulder pitch, degrees (- = forward/up)
	var elbow := {-1: -12.0, 1: -12.0} # - = forearm forward
	var spread := 4.0 # arms out to the sides
	var tilt := 0.0 # upper body leaning forward
	var bob := 0.0
	var held := "" # tool in the right hand
	var draw := 0.0 # bow: how far the string is drawn (0..1)
	match anim:
		"walk":
			legs = {1: [s * 0.48, maxf(0.0, c) * 0.95 + 0.05], -1: [-s * 0.48, maxf(0.0, -c) * 0.95 + 0.05]}
			arm = {1: s * 26.0, -1: -s * 26.0}
			elbow = {1: -18.0 - maxf(0.0, -s) * 20.0, -1: -18.0 - maxf(0.0, s) * 20.0}
			tilt = 4.0
		"chop": # overhead swing with an axe
			arm = {1: [-150.0, -95.0, -10.0, 25.0][k], -1: -30.0}
			elbow = {1: [-25.0, -10.0, 0.0, -8.0][k], -1: -60.0}
			tilt = [0.0, 6.0, 16.0, 20.0][k]
			legs = {1: [0.22, 0.2], -1: [-0.22, 0.12]}
			held = "axe"
		"build": # crouched hammering with a mallet
			arm = {1: [-100.0, -60.0, -20.0, -45.0][k], -1: -45.0}
			elbow = {1: -30.0, -1: -45.0}
			tilt = 25.0
			legs = {1: [0.85, 1.35], -1: [0.6, 1.25]}
			held = "mallet"
		"gather": # bending low, hands reaching into the bush
			tilt = 38.0
			arm = {1: [-40.0, -70.0, -50.0, -25.0][k], -1: [-70.0, -40.0, -25.0, -50.0][k]}
			elbow = {1: -20.0, -1: -20.0}
			legs = {1: [0.3, 0.45], -1: [0.1, 0.35]}
		"attack":
			match weapon:
				"club", "axe": # overhead blow
					arm = {1: [-160.0, -120.0, -20.0, 10.0][k], -1: -40.0}
					elbow = {1: [-30.0, -15.0, 0.0, -10.0][k], -1: -55.0}
					tilt = [-4.0, 2.0, 18.0, 16.0][k]
					legs = {1: [0.3, 0.3], -1: [-0.25, 0.12]}
					held = weapon
				"sling": # whirl overhead, then let fly
					arm = {1: [-170.0, -150.0, -175.0, -70.0][k], -1: -30.0}
					elbow = {1: [-20.0, -45.0, -10.0, -5.0][k], -1: -40.0}
					spread = [10.0, 16.0, 6.0, 4.0][k]
					tilt = [-4.0, -2.0, 2.0, 12.0][k]
					legs = {1: [0.2, 0.2], -1: [-0.2, 0.1]}
					held = "sling_loaded" if k < 3 else "sling"
				"bow": # left arm out with the bow, right hand draws the string back
					arm = {1: [-80.0, -85.0, -88.0, -70.0][k], -1: -88.0}
					elbow = {1: [-70.0, -115.0, -130.0, -40.0][k], -1: 0.0}
					spread = 2.0
					tilt = 2.0
					legs = {1: [0.15, 0.12], -1: [-0.2, 0.1]}
					draw = [0.3, 0.75, 1.0, 0.0][k]
					held = "bow"
				_: # spear: draw back, thrust
					arm = {1: [-40.0, -10.0, -95.0, -80.0][k], -1: -55.0}
					elbow = {1: [-60.0, -75.0, -5.0, -15.0][k], -1: -45.0}
					tilt = [-5.0, -8.0, 14.0, 10.0][k]
					legs = {1: [[0.25, 0.3, 0.55, 0.45][k], 0.35], -1: [[-0.25, -0.3, -0.4, -0.35][k], 0.1]}
					held = "spear"
		"ritual": # arms raised to the sky, swaying, stamping
			arm = {1: -165.0 + s * 15.0, -1: -165.0 - s * 15.0}
			elbow = {1: -15.0, -1: -15.0}
			spread = 18.0
			legs = {1: [maxf(0.0, s) * 0.5, maxf(0.0, s) * 0.9 + 0.1], -1: [maxf(0.0, -s) * 0.5, maxf(0.0, -s) * 0.9 + 0.1]}
			bob = absf(s) * 0.6
		"sit": # on the ground, knees up, a hand going to the mouth and back (eating, resting)
			legs = {1: [1.95, 2.65], -1: [1.8, 2.5]}
			arm = {1: [-55.0, -115.0][k / 2], -1: -20.0}
			elbow = {1: [-55.0, -120.0][k / 2], -1: -70.0}
			tilt = 10.0
		"talk": # standing, talking with the hands
			arm = {1: [-25.0, -50.0, -35.0, -15.0][k], -1: [5.0, -10.0, 0.0, 10.0][k]}
			elbow = {1: [-55.0, -80.0, -65.0, -45.0][k], -1: -25.0}
			spread = 9.0
			tilt = [2.0, 4.0, 3.0, 1.0][k]
		"dead":
			root.rotation_degrees.x = 86.0 # face down on the ground
			root.position = Vector3(0, 3.2, -12)
			arm = {1: -150.0, -1: -120.0}
			elbow = {1: -20.0, -1: -40.0}
			legs = {1: [0.0, 0.15], -1: [0.15, 0.4]}
	var hip_y := 11.2
	var l1 := 5.6
	var l2 := 5.5
	var reach := 0.0 # hips sit at the height of the longest standing leg
	for side in [-1, 1]:
		var a: float = legs[side][0]
		reach = maxf(reach, l1 * cos(a) + l2 * cos(a - legs[side][1]) + 0.4)
	var body := Node3D.new()
	body.position.y = (reach - hip_y) + bob if anim != "dead" else 0.0
	root.add_child(body)
	for side in [-1, 1]:
		var a: float = legs[side][0]
		var pts := chain(Vector3(side * 1.75, hip_y, 0), [l1, l2], [a, a - legs[side][1]])
		limb(body, pts, [1.6, 1.15, 0.85], skin, 8)
		var ankle: Vector3 = pts[2]
		var knee: Vector3 = pts[1]
		limb(body, [knee.lerp(ankle, 0.45), ankle], [1.12, 1.0], fur, 8) # fur leg wraps
		mi(body, sph(1.0, 8, 5), leather, ankle + Vector3(0, 0.15, 0.85), Vector3(-rad_to_deg(a - legs[side][1]) * 0.5, 0, 0), Vector3(0.95, 0.6, 1.75))
	# tunic skirt, belt and pouch
	loft(body, [[Vector3(0, 14.4, 0), 3.3, 2.5], [Vector3(0, 12.2, 0.05), 3.7, 2.9], [Vector3(0, 9.6, 0.2), 4.3, 3.5], [Vector3(0, 7.6, 0.3), 4.7, 3.9]], cloth, Vector3(0, 0, 1), 14)
	mi(body, cyl(3.6, 3.75, 1.0, 14), leather, Vector3(0, 13.2, 0), Vector3.ZERO, Vector3(1, 1, 0.8))
	mi(body, sph(1.1, 7, 5), leather, Vector3(3.4, 12.0, 0.9), Vector3.ZERO, Vector3(0.7, 1.1, 1))
	var upper := Node3D.new() # everything above the hips bends forward
	upper.position.y = 12.0
	upper.rotation_degrees.x = tilt
	body.add_child(upper)
	loft(upper, [[Vector3(0, 0.6, 0), 3.35, 2.5], [Vector3(0, 3.2, 0.1), 3.1, 2.3], [Vector3(0, 6.2, 0.25), 3.8, 2.7], [Vector3(0, 8.4, 0.05), 4.15, 2.55], [Vector3(0, 9.7, -0.1), 3.0, 2.1], [Vector3(0, 10.3, -0.1), 1.8, 1.5]], cloth, Vector3(0, 0, 1), 14)
	# fur mantle over the shoulders
	loft(upper, [[Vector3(0, 6.6, -0.25), 4.3, 3.0], [Vector3(0, 8.4, -0.25), 4.95, 3.3], [Vector3(0, 9.8, -0.25), 4.0, 2.9], [Vector3(0, 10.5, -0.15), 2.3, 2.0]], fur, Vector3(0, 0, 1), 12)
	limb(upper, [Vector3(0, 9.6, 0), Vector3(0, 12.2, 0.25)], [1.3, 1.15], skin, 8) # neck
	# head: skull, jaw, nose, ears, eyes and brows, hair with a knot at the back
	var hc := Vector3(0, 13.9, 0.25)
	mi(upper, sph(2.85, 14, 9), skin, hc, Vector3.ZERO, Vector3(0.94, 1.06, 1.0))
	mi(upper, sph(2.1, 10, 6), skin, hc + Vector3(0, -1.35, 0.7), Vector3.ZERO, Vector3(0.95, 0.8, 1.0))
	mi(upper, cyl(0.15, 0.55, 1.4, 6), skin, hc + Vector3(0, -0.2, 2.85), Vector3(75, 0, 0))
	for side in [-1, 1]:
		mi(upper, sph(0.7, 6, 4), skin, hc + Vector3(side * 2.65, 0.0, -0.1), Vector3.ZERO, Vector3(0.5, 1.0, 0.8))
		mi(upper, sph(0.32, 6, 4), dark, hc + Vector3(side * 0.95, 0.35, 2.45))
		mi(upper, box(Vector3(1.3, 0.35, 0.5)), hair, hc + Vector3(side * 0.95, 0.95, 2.45), Vector3(0, 0, side * -8))
	mi(upper, sph(3.1, 14, 8), hair, hc + Vector3(0, 0.55, -0.5), Vector3(-12, 0, 0), Vector3(1.0, 0.92, 1.04))
	loft(upper, [[hc + Vector3(0, 0.4, -2.4), 2.3, 1.1], [hc + Vector3(0, -1.6, -2.8), 2.0, 1.0], [hc + Vector3(0, -3.6, -2.7), 1.4, 0.8]], hair, Vector3(0, 0, 1), 8)
	mi(upper, sph(1.15, 8, 5), hair, hc + Vector3(0, 2.4, -1.9))
	for side in [-1, 1]: # arms swing at the shoulder and bend at the elbow
		var sh := Node3D.new()
		sh.position = Vector3(side * 4.1, 8.9, 0)
		sh.rotation_degrees = Vector3(arm[side], 0, side * spread)
		upper.add_child(sh)
		limb(sh, [Vector3.ZERO, Vector3(0, -4.8, 0)], [1.35, 1.0], skin, 8)
		var el := Node3D.new()
		el.position = Vector3(0, -4.8, 0)
		el.rotation_degrees.x = elbow[side]
		sh.add_child(el)
		limb(el, [Vector3.ZERO, Vector3(0, -4.3, 0)], [1.0, 0.78], skin, 8)
		mi(el, cyl(0.9, 0.9, 1.0, 8), leather, Vector3(0, -3.6, 0)) # wrist wrap
		mi(el, sph(0.95, 8, 5), skin, Vector3(0, -5.0, 0.15), Vector3.ZERO, Vector3(0.8, 1.0, 0.95))
		if side < 0 and held == "bow": # the bow, upright in the left fist, its string drawn back
			var bg := Node3D.new()
			bg.position = Vector3(0, -5.0, 0)
			bg.rotation_degrees.x = -(arm[-1] + elbow[-1] + tilt)
			el.add_child(bg)
			var bow_pts := []
			for i in 7:
				var a := lerpf(-1.0, 1.0, i / 6.0)
				bow_pts.append(Vector3(0, a * 9.0, 1.6 - a * a * 3.2))
			limb(bg, bow_pts, [0.22, 0.32, 0.42, 0.5, 0.42, 0.32, 0.22], wood, 6)
			mi(bg, cyl(0.6, 0.6, 1.6, 6), leather, Vector3(0, 0, 1.6))
			var nock := Vector3(0, 0, -1.6 - draw * 6.5)
			var strg: Material = mat(Color("#e8dcc0"), "fine", 0.2, Vector3.ONE, 0.1) if not cloth_only else flat(Color.BLACK)
			limb(bg, [Vector3(0, 9.0, -1.6), nock, Vector3(0, -9.0, -1.6)], [0.1, 0.1, 0.1], strg, 4)
			if draw > 0.0: # the arrow on the string
				limb(bg, [nock, Vector3(0, 0, 4.0)], [0.14, 0.14], wood, 4)
				mi(bg, cyl(0.0, 0.45, 1.4, 5), head_m, Vector3(0, 0, 4.6), Vector3(90, 0, 0))
		if side > 0:
			var hand := Vector3(0, -5.0, 0)
			match held:
				"club":
					mi(el, cyl(0.85, 0.45, 9.5, 6), wood, hand + Vector3(0, 0, 3.6), Vector3(90, 0, 0))
					mi(el, lumpy(sph(1.5, 8, 5), 0.35, 7, 0.7, true), wood, hand + Vector3(0, 0, 8.6))
				"sling", "sling_loaded": # a cord hanging from the fist, a stone in its pouch
					var cord: Material = mat(Color("#8a6a42"), "fine", 0.3, Vector3.ONE, 0.2) if not cloth_only else flat(Color.BLACK)
					limb(el, [hand, hand + Vector3(0, -3.5, 0.6), hand + Vector3(0, -6.5, 0.2)], [0.12, 0.12, 0.12], cord, 4)
					if held == "sling_loaded":
						mi(el, sph(0.9, 6, 4), leather, hand + Vector3(0, -7.0, 0.2))
						mi(el, sph(0.6, 6, 4), head_m, hand + Vector3(0, -7.3, 0.6))
				"axe":
					mi(el, cyl(0.45, 0.5, 10, 6), wood, hand + Vector3(0, 0, 3.4), Vector3(90, 0, 0))
					mi(el, lumpy(box(Vector3(1.2, 3.0, 3.6)), 0.25, 11, 0.6, true) if tool == "stone" else box(Vector3(0.8, 3.4, 3.2)), head_m, hand + Vector3(0, 0.2, 7.6))
					mi(el, cyl(0.7, 0.7, 1.2, 6), leather, hand + Vector3(0, 0, 7.6), Vector3(90, 0, 0))
				"mallet":
					mi(el, cyl(0.4, 0.45, 6.5, 6), wood, hand + Vector3(0, 0, 2.2), Vector3(90, 0, 0))
					mi(el, cyl(1.35, 1.35, 3.4, 8), head_m, hand + Vector3(0, 0, 5.4))
				"spear": # counter-rotated so the spear stays level, pointing forward
					var grip := Node3D.new()
					grip.position = hand
					grip.rotation_degrees.x = -(arm[1] + elbow[1] + tilt)
					el.add_child(grip)
					mi(grip, cyl(0.35, 0.38, 26, 6), wood, Vector3(0, 0, 3), Vector3(90, 0, 0))
					mi(grip, cyl(0.0, 1.0, 3.8, 6), head_m, Vector3(0, 0, 17.8), Vector3(90, 0, 0), Vector3(1, 1, 0.45))
					mi(grip, cyl(0.55, 0.55, 1.2, 6), leather, Vector3(0, 0, 15.6), Vector3(90, 0, 0))
	return holder
