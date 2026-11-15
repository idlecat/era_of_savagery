## 2.5D isometric renderer (Age-of-Empires-style diamond map) + Tier 1 RTS input.
## The simulation stays in flat world coordinates; only drawing and picking are
## projected: ground features are drawn through an isometric transform, upright
## objects (trees, huts, people, beasts) are drawn in screen space at iso(pos) and
## depth-sorted by x+y so nearer things overlap farther ones.
extends Node2D

const D = preload("res://scripts/data.gd")
const I = preload("res://scripts/i18n.gd")

signal selection_changed()

const IX := 0.75   # iso projection: screen = ((x-y)*IX, (x+y)*IY), 2:1 diamond
const IY := 0.375
const GROUND := Transform2D(Vector2(IX, IY), Vector2(-IX, IY), Vector2.ZERO)
const TEX_SCALE := 4 # terrain texture = world / 4 pixels

var sim
var art # ArtBaker (pre-rendered 3D sprites); old procedural drawing is the fallback
var heading := {} # "u12" -> last screen-space movement direction
var attacking := {} # predator keys currently biting someone (attack animation)
var sprite_dirs: Array = [] # screen direction each of the 8 baked facings looks along
var selected: Array = [] # unit ids
var build_type := ""
var drag_start: Variant = null # screen-space
var mid_drag := false
var cam: Camera2D
var night: CanvasModulate
var lights := {} # structure id -> PointLight2D
var light_tex: GradientTexture2D
var font: Font
var terrain_tex: ImageTexture
var minimap_tex: ImageTexture
var fog_tex: ImageTexture
var fog_img: Image
var fog_refresh := 0.0
var wear_tex: ImageTexture
var wear_img: Image
var wear_refresh := 0.0
var view := Rect2() # visible canvas rect (iso space) for culling
var decor: Array = []
var river_l := PackedVector2Array()
var river_r := PackedVector2Array()
var cmd_marker := {}
var guardian_trail: Array = []
var facing := {} # "u12" -> 1 / -1  (screen-space left/right)
var last_pos := {}
var moving := {}
var t := 0.0
var ci: CanvasItem # canvas currently being drawn (world, an Item, or the Overlay)
var ghost_m := Vector2.ZERO
var ghost_why := ""
var decor_root: Node2D
var ground: Node2D
var ground_fx: Node2D
var objects: Node2D # y-sorted container: iso y == depth (x + y)
var overlay: Node2D
var glow: Node2D
var items := {} # key -> Item
var edge_scroll := true
var blocked: Callable # returns true while a modal is open (set by main)

const EDGE_PX := 8.0
const PAN_GESTURE_SPEED := 14.0

const C_WOOD := Color("#8a5a32")
const FIG_SCALE := 1.35 # people & beasts drawn larger than true scale for readability
const SHADOW := Color(0, 0, 0, 0.28)

static func iso(p: Vector2) -> Vector2:
	return Vector2((p.x - p.y) * IX, (p.x + p.y) * IY)

static func uniso(s: Vector2) -> Vector2:
	var a := s.x / IX
	var b := s.y / IY
	return Vector2((a + b) * 0.5, (b - a) * 0.5)

func setup(s) -> void:
	sim = s
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	for d in 8: # a model yawed by d*45 deg faces world (sin, cos)
		var yaw := deg_to_rad(d * 45.0)
		sprite_dirs.append(iso(Vector2(sin(yaw), cos(yaw))).normalized())
	ci = self
	font = ThemeDB.fallback_font
	cam = Camera2D.new()
	cam.zoom = Vector2(1.25, 1.25)
	cam.position = iso(D.VILLAGE + Vector2(240, 0))
	add_child(cam)
	cam.make_current()
	night = CanvasModulate.new()
	add_child(night)
	var vig := CanvasLayer.new()
	vig.layer = 5
	var vr := TextureRect.new()
	vr.set_anchors_preset(Control.PRESET_FULL_RECT)
	vr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vr.stretch_mode = TextureRect.STRETCH_SCALE
	var vg := Gradient.new()
	vg.set_color(0, Color(0, 0, 0, 0))
	vg.add_point(0.62, Color(0, 0, 0, 0))
	vg.set_color(vg.get_point_count() - 1, Color(0.05, 0.03, 0.02, 0.28))
	var vt := GradientTexture2D.new()
	vt.gradient = vg
	vt.fill = GradientTexture2D.FILL_RADIAL
	vt.fill_from = Vector2(0.5, 0.5)
	vt.fill_to = Vector2(1.0, 1.0)
	vr.texture = vt
	vig.add_child(vr)
	add_child(vig)
	var g := Gradient.new()
	g.set_color(0, Color(1.0, 0.82, 0.55, 1.0))
	g.set_color(1, Color(1.0, 0.55, 0.25, 0.0))
	light_tex = GradientTexture2D.new()
	light_tex.gradient = g
	light_tex.fill = GradientTexture2D.FILL_RADIAL
	light_tex.fill_from = Vector2(0.5, 0.5)
	light_tex.fill_to = Vector2(1.0, 0.5)
	light_tex.width = 256
	light_tex.height = 256
	_build_terrain()
	ground = Ground.new()
	ground.wv = self
	var gm := ShaderMaterial.new()
	gm.shader = load("res://shaders/terrain.gdshader")
	gm.set_shader_parameter("grass_tex", _noise_tex(7, 0.012, FastNoiseLite.TYPE_PERLIN, 5))
	gm.set_shader_parameter("grain_tex", _noise_tex(19, 0.06, FastNoiseLite.TYPE_CELLULAR, 1))
	gm.set_shader_parameter("world_size", Vector2(D.W, D.H))
	ground.material = gm
	add_child(ground)
	ground_fx = GroundFX.new()
	ground_fx.wv = self
	add_child(ground_fx)
	decor_root = Node2D.new()
	add_child(decor_root)
	objects = Node2D.new()
	objects.y_sort_enabled = true
	add_child(objects)
	glow = Glow.new() # additive soft light around fires, above objects
	glow.wv = self
	var gmat := CanvasItemMaterial.new()
	gmat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	glow.material = gmat
	add_child(glow)
	overlay = Overlay.new()
	overlay.wv = self
	add_child(overlay)
	_build_decor_chunks()

# ------------------------------------------------------------ terrain bake
func _build_terrain() -> void:
	var y := -20.0
	while y <= D.H + 20:
		river_l.append(Vector2(D.river_x(y) - D.RIVER_HALF, y))
		river_r.append(Vector2(D.river_x(y) + D.RIVER_HALF, y))
		y += 12
	var noise := FastNoiseLite.new()
	noise.seed = 7
	noise.frequency = 0.006
	var fine := FastNoiseLite.new()
	fine.seed = 11
	fine.frequency = 0.05
	var soil := FastNoiseLite.new() # dirt and rocky patches
	soil.seed = 23
	soil.frequency = 0.004
	var meadow := FastNoiseLite.new() # flower meadows
	meadow.seed = 31
	meadow.frequency = 0.003
	forest_map = _forest_density()
	var w := int(D.W / TEX_SCALE)
	var h := int(D.H / TEX_SCALE)
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var g_west_a := Color("#6f8e3f")
	var g_west_b := Color("#56763a")
	var g_east_a := Color("#4d6a34")
	var g_east_b := Color("#3a5229")
	var dirt := Color("#8c7650")
	var sand := Color("#b09c6c")
	var deep := Color("#2b5878")
	var shallow := Color("#4b8aa4")
	var ford := Color("#7fa3a0")
	for j in h:
		for i in w:
			var p := Vector2(i * TEX_SCALE + 1.5, j * TEX_SCALE + 1.5)
			var n := noise.get_noise_2dv(p) * 0.5 + 0.5
			var f := fine.get_noise_2dv(p) * 0.5 + 0.5
			var dx := absf(p.x - D.river_x(p.y))
			var c: Color
			if dx < D.RIVER_HALF:
				var k := dx / D.RIVER_HALF
				c = deep.lerp(shallow, k * k)
				c.a = 0.08 + 0.3 * k
				if D.is_ford(p.y):
					c = ford.lerp(shallow, 0.3 * k).lerp(Color("#9a9682"), 0.35 * f)
					c.a = 0.4
			elif dx < D.RIVER_HALF + 12 + 8 * n:
				c = sand.lerp(Color("#8f8058"), f * 0.6)
				c.a = 0.56
			else:
				var east := p.x > D.river_x(p.y)
				c = (g_east_a.lerp(g_east_b, n) if east else g_west_a.lerp(g_west_b, n))
				c = c.lerp(c.darkened(0.18), f * 0.5)
				var dv := p.distance_to(D.VILLAGE)
				if dv < 170:
					c = c.lerp(dirt.lerp(dirt.darkened(0.15), f), clampf((170 - dv) / 110.0, 0, 0.85) * (0.6 + 0.4 * n))
				var m := meadow.get_noise_2dv(p) * 0.5 + 0.5
				var so := soil.get_noise_2dv(p) * 0.5 + 0.5
				var fd := _forest_at(p)
				if not east and m > 0.62: c = c.lerp(Color("#93a64e"), clampf((m - 0.62) * 3.0, 0, 0.6))
				if so > 0.7: c = c.lerp(Color("#7d6a48").lerp(Color("#6a5c40"), f), clampf((so - 0.7) * 4.0, 0, 0.75))
				elif so < 0.22: c = c.lerp(Color("#7a7466").lerp(Color("#8a857a"), f), clampf((0.22 - so) * 4.0, 0, 0.6))
				if fd > 0.05: c = c.lerp(Color("#3d4a28").lerp(Color("#4a4026"), f), clampf(fd * 0.8, 0, 0.7)) # forest floor and leaf litter
				if dx < D.RIVER_HALF + 50: c = c.lerp(Color("#4f6a32"), clampf((D.RIVER_HALF + 50 - dx) / 40.0, 0, 0.5)) # lush riverbank
			img.set_pixel(i, j, c)
	terrain_tex = ImageTexture.create_from_image(img)
	_place_ground_cover()
	var mini := img.duplicate() # minimap: same colours without the type data in alpha
	mini.convert(Image.FORMAT_RGB8)
	minimap_tex = ImageTexture.create_from_image(mini)
	fog_img = Image.create(maxi(sim.fog_w, 1), maxi(sim.fog_h, 1), false, Image.FORMAT_LA8)
	fog_tex = ImageTexture.create_from_image(fog_img)
	_refresh_fog()
	wear_img = Image.create(maxi(sim.wear_w, 1), maxi(sim.wear_h, 1), false, Image.FORMAT_RGBA8)
	wear_tex = ImageTexture.create_from_image(wear_img)
	decor.sort_custom(func(a, b): return a["p"].x + a["p"].y < b["p"].x + b["p"].y)

# ------------------------------------------------------------ frame
func _process(delta: float) -> void:
	t += delta
	_pan_keys(delta)
	night.color = _sky_tint()
	_sync_lights()
	if sim.guardian and not sim.guardian.dead:
		guardian_trail.push_front(sim.guardian.pos)
		if guardian_trail.size() > 40: guardian_trail.pop_back()
	wear_refresh -= delta
	if wear_refresh <= 0:
		wear_refresh = 1.0
		_refresh_wear()
	fog_refresh -= delta
	if fog_refresh <= 0:
		fog_refresh = 0.1
		_refresh_fog()
	var vs := get_viewport_rect().size / cam.zoom.x
	view = Rect2(cam.get_screen_center_position() - vs / 2, vs).grow(140)
	_sync_items()
	ground_fx.queue_redraw()
	glow.queue_redraw()
	overlay.queue_redraw()
	for u in sim.units: _track("u%d" % u.id, u.pos)
	if sim.guardian and not sim.guardian.dead: _track("g", sim.guardian.pos)
	attacking.clear()
	for p in sim.predators:
		_track("p%d" % p.id, p.pos)
		if p.dead or p.fled or p.fleeing or p.kind == "hunter" or p.kind == "trader": continue
		for u in sim.units:
			if not u.dead and u.pos.distance_to(p.pos) < 26.0:
				attacking["p%d" % p.id] = true
				heading["p%d" % p.id] = (iso(u.pos) - iso(p.pos)).normalized()
				break
	for n in sim.nodes:
		if n.kind == "deer": _track("n%d" % n.id, n.pos)
	queue_redraw()

## Fog of war as a tiny texture (one texel per fog cell), drawn through the iso transform
## with linear filtering so the edges are soft: black = unexplored, dim = explored, clear = in sight.
## Tree density on a coarse grid (0..1), smoothed: darkens forest floors, places ferns.
var forest_map: Image
func _forest_density() -> Image:
	var cell := 60.0
	var gw := ceili(D.W / cell)
	var gh := ceili(D.H / cell)
	var img := Image.create(gw, gh, false, Image.FORMAT_RF)
	var counts := {}
	for n in sim.nodes:
		if n.kind != "tree": continue
		var k := Vector2i(int(n.pos.x / cell), int(n.pos.y / cell))
		counts[k] = counts.get(k, 0) + 1
	for k in counts: img.set_pixel(k.x, k.y, Color(minf(1.0, counts[k] / 3.0), 0, 0))
	img.resize(gw * 4, gh * 4, Image.INTERPOLATE_CUBIC)
	return img

func _forest_at(p: Vector2) -> float:
	var x := clampi(int(p.x / D.W * forest_map.get_width()), 0, forest_map.get_width() - 1)
	var y := clampi(int(p.y / D.H * forest_map.get_height()), 0, forest_map.get_height() - 1)
	return clampf(forest_map.get_pixel(x, y).r, 0.0, 1.0)

## Ground cover chosen by biome: reeds on the banks, ferns in forests, flowers in
## meadows, pebbles on rocky ground, grass everywhere; a few rock outcrops in the wilds.
var outcrops: Array = [] # [{p, v}]
func _place_ground_cover() -> void:
	var meadow := FastNoiseLite.new()
	meadow.seed = 31
	meadow.frequency = 0.003
	var soil := FastNoiseLite.new()
	soil.seed = 23
	soil.frequency = 0.004
	var y := 0.0
	while y < D.H: # reeds along both banks
		y += randf_range(10, 22)
		if D.is_ford(y) or D.is_ford(y + 30) or D.is_ford(y - 30): continue
		for side in [-1, 1]:
			if randf() < 0.75:
				var p := Vector2(D.river_x(y) + side * (D.RIVER_HALF + randf_range(2, 22)), y)
				decor.append({"p": p, "kind": "reeds", "v": randi() % 2, "s": randf_range(0.8, 1.2), "east": side > 0, "tall": false, "c": 0.0})
	for i in 2600:
		var p := Vector2(randf() * D.W, randf() * D.H)
		if absf(p.x - D.river_x(p.y)) < D.RIVER_HALF + 14: continue
		var east := D.bank_of(p) == "east"
		var fd := _forest_at(p)
		var m := meadow.get_noise_2dv(p) * 0.5 + 0.5
		var so := soil.get_noise_2dv(p) * 0.5 + 0.5
		var r := randf()
		var kind := "tuft"
		if fd > 0.35 and r < 0.55: kind = "fern"
		elif so < 0.25 and r < 0.5: kind = "rock"
		elif not east and m > 0.6 and r < 0.4: kind = "flower"
		elif r < 0.04: kind = "rock"
		elif r < 0.08 and not east: kind = "flower"
		decor.append({"p": p, "east": east, "kind": kind, "v": randi() % 3, "tall": east and randf() < 0.7, "c": randf_range(-0.05, 0.05), "s": randf_range(0.75, 1.25)})
	var tries := 0
	while outcrops.size() < 12 and tries < 300:
		tries += 1
		var p := Vector2(randf_range(150, D.W - 150), randf_range(150, D.H - 150))
		if p.distance_to(D.VILLAGE) < 700 or p.distance_to(D.EAST_SITE) < 450 or absf(p.x - D.river_x(p.y)) < 250: continue
		var ok := true
		for lm in D.LANDMARKS:
			if p.distance_to(lm["pos"]) < 260: ok = false
		for o in outcrops:
			if p.distance_to(o["p"]) < 400: ok = false
		if ok: outcrops.append({"p": p, "v": outcrops.size() % 3})

## Seamless noise used as terrain detail (tiles without seams, mipmapped for distance).
func _noise_tex(seed_v: int, freq: float, type: int, octaves: int) -> ImageTexture:
	var n := FastNoiseLite.new()
	n.seed = seed_v
	n.noise_type = type
	n.frequency = freq
	n.fractal_octaves = octaves
	var img := n.get_seamless_image(512, 512)
	img.convert(Image.FORMAT_RGB8)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

func _refresh_fog() -> void:
	var n: int = sim.fog_w * sim.fog_h
	if n == 0: return
	var data := PackedByteArray()
	data.resize(n * 2)
	for k in n:
		data[k * 2] = 0
		data[k * 2 + 1] = 0 if not sim.fog_enabled or sim.visible[k] == 1 else (120 if sim.explored[k] == 1 else 255)
	fog_img.set_data(sim.fog_w, sim.fog_h, false, Image.FORMAT_LA8, data)
	fog_tex.update(fog_img)

## Worn paths: foot traffic tints the grass toward bare earth.
func _refresh_wear() -> void:
	var n: int = sim.wear_w * sim.wear_h
	if n == 0: return
	var data := PackedByteArray()
	data.resize(n * 4)
	for k in n:
		var w: float = sim.wear[k]
		data[k * 4] = 120
		data[k * 4 + 1] = 98
		data[k * 4 + 2] = 66
		data[k * 4 + 3] = int(clampf((w - 0.12) * 1.1, 0.0, 0.62) * 255)
	wear_img.set_data(sim.wear_w, sim.wear_h, false, Image.FORMAT_RGBA8, data)
	wear_tex.update(wear_img)

## Time-of-day colour grading: warm golden dusk, blue night, pink dawn.
func _sky_tint() -> Color:
	var f: float = sim.day_frac()
	var c := Color.WHITE
	if f > 0.58 and f < 0.76: c = Color.WHITE.lerp(Color(1.0, 0.88, 0.74), sin((f - 0.58) / 0.18 * PI))
	elif f > 0.94 or f < 0.06:
		var k := (f - 0.94) / 0.12 if f > 0.94 else (f + 0.06) / 0.12
		c = Color.WHITE.lerp(Color(1.0, 0.78, 0.82), sin(k * PI) * 0.8)
	return c.lerp(Color(0.30, 0.34, 0.55), sim.night_amt * 0.85)

func _track(key: String, p: Vector2) -> void:
	var s := iso(p)
	if last_pos.has(key):
		var dv: Vector2 = s - last_pos[key]
		moving[key] = dv.length() > 0.05
		if absf(dv.x) > 0.05: facing[key] = 1 if dv.x > 0 else -1
		if dv.length() > 0.05: heading[key] = dv.normalized()
	last_pos[key] = s

## Pan keys we saw pressed *on the map*. Polling Input.is_key_pressed() is not safe: an
## input method (e.g. Chinese Pinyin on macOS) can swallow the key-up of letters typed
## into a text box, leaving S/D "held" forever and the camera drifting. A key only
## counts if its press reached the map (not a text field); any release, a dialog or
## losing window focus clears it.
const PAN_KEYS := [KEY_A, KEY_D, KEY_W, KEY_S, KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN]
var pan_held := {}

func _unhandled_key_input(ev: InputEvent) -> void:
	var k := ev as InputEventKey
	if k and k.pressed and k.keycode in PAN_KEYS and not k.ctrl_pressed and not k.meta_pressed:
		pan_held[k.keycode] = true

func _input(ev: InputEvent) -> void:
	var k := ev as InputEventKey
	if k and not k.pressed: pan_held.erase(k.keycode)

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		pan_held.clear()

func _pan_keys(delta: float) -> void:
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or focus is SpinBox:
		pan_held.clear()
		return
	if blocked.is_valid() and blocked.call(): # map is frozen behind dialogs
		pan_held.clear()
		return
	var v := Vector2.ZERO
	if pan_held.has(KEY_A) or pan_held.has(KEY_LEFT): v.x -= 1
	if pan_held.has(KEY_D) or pan_held.has(KEY_RIGHT): v.x += 1
	if pan_held.has(KEY_W) or pan_held.has(KEY_UP): v.y -= 1
	if pan_held.has(KEY_S) or pan_held.has(KEY_DOWN): v.y += 1
	v += _edge_dir()
	if v != Vector2.ZERO:
		cam.position += v.normalized() * 800 * delta / cam.zoom.x
		_clamp_cam()

## AoE-style edge scrolling: push the cursor against a window edge to pan.
func _edge_dir() -> Vector2:
	if not edge_scroll or drag_start == null and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT): return Vector2.ZERO
	if not DisplayServer.window_is_focused() or (blocked.is_valid() and blocked.call()): return Vector2.ZERO
	var vp := get_viewport()
	var r := vp.get_visible_rect()
	var mp := vp.get_mouse_position()
	if not r.grow(1).has_point(mp): return Vector2.ZERO
	var v := Vector2.ZERO
	if mp.x <= r.position.x + EDGE_PX: v.x -= 1
	elif mp.x >= r.end.x - EDGE_PX: v.x += 1
	if mp.y <= r.position.y + EDGE_PX: v.y -= 1
	elif mp.y >= r.end.y - EDGE_PX: v.y += 1
	return v

## Zoom by factor k keeping the world point under the cursor fixed.
func _zoom_by(k: float) -> void:
	var z := clampf(cam.zoom.x * k, 0.45, 2.4)
	var before := get_global_mouse_position()
	cam.zoom = Vector2(z, z)
	cam.force_update_scroll()
	cam.position += before - get_global_mouse_position()
	_clamp_cam()

func _clamp_cam() -> void:
	cam.position = Vector2(clampf(cam.position.x, -D.H * IX, D.W * IX), clampf(cam.position.y, 0, (D.W + D.H) * IY))

func _sync_lights() -> void:
	var alive := {}
	for s in sim.structures:
		if s.type != "bonfire" or not s.built: continue
		alive[s.id] = true
		if not lights.has(s.id):
			var l := PointLight2D.new()
			l.texture = light_tex
			l.position = iso(s.pos) - Vector2(0, 6)
			l.scale = Vector2(1.0, 0.6)
			add_child(l)
			lights[s.id] = l
		var l: PointLight2D = lights[s.id]
		var r := 120.0 * (2.0 if sim.has_tech("fire") else 1.0)
		l.texture_scale = r * 2.6 / 256.0
		l.energy = (0.4 + 0.9 * sim.night_amt) * (1.0 + 0.08 * sin(t * 9 + s.id))
	for u in sim.units:
		if not _has_torch(u): continue
		var key := "t%d" % u.id
		alive[key] = true
		if not lights.has(key):
			var l := PointLight2D.new()
			l.texture = light_tex
			l.scale = Vector2(1.0, 0.6)
			add_child(l)
			lights[key] = l
		var tl: PointLight2D = lights[key]
		tl.position = iso(u.pos) - Vector2(0, 30)
		tl.texture_scale = 140.0 / 256.0
		tl.energy = 0.9 * (1.0 + 0.1 * sin(t * 13 + u.id))
	for id in lights.keys():
		if not alive.has(id):
			lights[id].queue_free()
			lights.erase(id)

## At night, people away from a fire carry torches once the tribe knows Friction Fire.
func _has_torch(u) -> bool:
	return not u.dead and sim.night_amt > 0.4 and sim.has_tech("fire") and not sim.near_warmth(u) and sim.is_visible(u.pos)

# ------------------------------------------------------------ drawing
func _draw() -> void:
	ci.draw_rect(Rect2(-3000, -2000, 7000, 5000), Color("#141210"))
	_draw_slab()


func draw_terrain() -> void:
	ci.draw_set_transform_matrix(GROUND)
	ci.draw_texture_rect(terrain_tex, Rect2(0, 0, D.W, D.H), false)
	ci.draw_set_transform_matrix(Transform2D.IDENTITY)

## Flat things on the ground, above the terrain shader and below everything upright.
func draw_ground_fx() -> void:
	ci.draw_set_transform_matrix(GROUND)
	ci.draw_texture_rect(wear_tex, Rect2(0, 0, sim.wear_w * sim.WEAR_CELL, sim.wear_h * sim.WEAR_CELL), false)
	_draw_season_ground()
	_draw_water_fx()
	for s in sim.structures: _draw_ground_part(s)
	for c in sim.contracts.list: _draw_site_ring(c)
	if not cmd_marker.is_empty() and t - cmd_marker["t"] < 0.6:
		var k: float = (t - cmd_marker["t"]) / 0.6
		ci.draw_arc(cmd_marker["p"], 6 + 16 * k, 0, TAU, 24, Color(cmd_marker["c"], 1.0 - k), 3)
	ghost_m = Vector2.ZERO
	ghost_why = ""
	if build_type != "":
		ghost_m = uniso(get_global_mouse_position())
		ghost_why = sim.can_place(build_type, ghost_m)
		var col := Color(0.4, 1, 0.4, 0.45) if ghost_why == "" else Color(1, 0.3, 0.3, 0.45)
		var r: float = D.STRUCTURES[build_type]["r"]
		ci.draw_circle(ghost_m, minf(r, 30), col)
		if D.STRUCTURES[build_type].get("ring", false): ci.draw_arc(ghost_m, r, 0, TAU, 64, col, 6)
	if sim.flood_fx > 0:
		ci.draw_rect(Rect2(0, 0, D.W, D.H), Color(0.2, 0.4, 0.75, sim.flood_fx * 0.4))
	ci.draw_set_transform_matrix(Transform2D.IDENTITY)

## Fire glow: additive warm halos, stronger at night (bonfires, council fire, smelter, torches).
func draw_glow() -> void:
	var night: float = sim.night_amt
	for st in sim.structures:
		if not st.built or not _in_view(st.pos) or not sim.is_explored(st.pos): continue
		var r := 0.0
		match st.type:
			"bonfire": r = 70.0
			"council_ring": r = 45.0
			"smelter": r = 38.0
		if r > 0: _halo(iso(st.pos) - Vector2(0, 10), r, (0.22 + 0.4 * night) * (1.0 + 0.1 * sin(t * 9 + st.id)))
	for u in sim.units:
		if _has_torch(u) and _in_view(u.pos): _halo(iso(u.pos) - Vector2(0, 30), 26.0, 0.35 + 0.3 * night)

func _halo(c: Vector2, r: float, a: float) -> void:
	ci.draw_texture_rect(light_tex, Rect2(c - Vector2(r, r * 0.75), Vector2(r * 2, r * 1.5)), false, Color(1.0, 0.62, 0.3, a))

## Drawn by the Overlay child (above all objects): fog of war, then labels and bars.
func draw_overlay() -> void:
	# ---- fog of war over everything in the world (labels below stay readable)
	if sim.fog_enabled:
		ci.draw_set_transform_matrix(GROUND)
		ci.draw_texture_rect(fog_tex, Rect2(0, 0, sim.fog_w * D.FOG_CELL, sim.fog_h * D.FOG_CELL), false)
		ci.draw_set_transform_matrix(Transform2D.IDENTITY)

	_draw_weather()
	# ---- overlay pass: labels, bars, flags (never hidden behind objects)
	var ford_lbl := Vector2(D.river_x(D.FORD_Y1 + 30), D.FORD_Y1 + 30)
	if sim.is_explored(ford_lbl): _draw_label(iso(ford_lbl) + Vector2(0, 14), tr("FORD"), 13, Color(1, 1, 1, 0.65), true)
	if sim.is_explored(D.EAST_SITE): _draw_label(iso(D.EAST_SITE + Vector2(250, -330)), tr("UNTAMED EAST BANK"), 20, Color(1, 1, 1, 0.4), true)
	_draw_label(iso(D.VILLAGE + Vector2(-220, -300)), tr("TRIBAL LANDS"), 20, Color(1, 1, 1, 0.4), true)
	for lm in sim.landmarks:
		if lm["found"] and _in_view(lm["pos"]):
			_draw_label(iso(lm["pos"]) + Vector2(0, 22), tr(lm["name"]), 13, Color("#ffe6a8") if lm["kind"] != "den" else Color("#ff9b8a"), true)
	for id in sim.rivals.clans: _draw_clan_banner(sim.rivals.clans[id])
	for c in sim.contracts.list: _draw_site_flag(c)
	for s in sim.structures:
		if _in_view(s.pos): _draw_structure_overlay(s)
	for u in sim.units:
		if _in_view(u.pos): _draw_unit_overlay(u)
	for p in sim.predators:
		if p.dead or p.fled or not sim.is_visible(p.pos): continue
		if p.clan != "":
			var cc: Color = sim.rivals.clans[p.clan]["color"]
			_draw_label(iso(p.pos) + Vector2(0, -46), tr(p.name), 12, cc.lightened(0.45), true)
			if p.hp < p.max_hp - 0.5: _bar(iso(p.pos) + Vector2(0, 6), 24, p.hp / p.max_hp, cc.lightened(0.2))
		else:
			_bar(iso(p.pos) + Vector2(0, 8), 32, p.hp / p.max_hp, Color("#ff9b3a"))
	for p in sim.popups:
		if not sim.is_explored(p["pos"]): continue
		var a: float = 1.0 - pow(p["t"] / p["life"], 2)
		var col: Color = p["color"]
		col.a = a
		_draw_label(iso(p["pos"]) - Vector2(0, 26), p["text"], 17 if p["big"] else 13, col, true)
	if drag_start != null:
		var m := get_global_mouse_position()
		var r := Rect2(drag_start, m - drag_start).abs()
		ci.draw_rect(r, Color(1, 1, 0.6, 0.12))
		ci.draw_rect(r, Color(1, 1, 0.6, 0.7), false, 1.5)
	if build_type != "":
		_draw_label(iso(ghost_m) + Vector2(0, -44), tr(D.STRUCTURES[build_type]["name"]) + ("" if ghost_why == "" else " - " + tr(ghost_why)), 14, Color.WHITE, true)

# ------------------------------------------------------------ seasons & weather
func _draw_season_ground() -> void:
	var hz = sim.hz
	if not hz.on(): return
	var world := Rect2(0, 0, D.W, D.H)
	if hz.snow > 0.01: ci.draw_rect(world, Color(0.93, 0.96, 1.0, 0.6 * hz.snow))
	if hz.season_idx() == 2: ci.draw_rect(world, Color(0.85, 0.5, 0.15, 0.13))
	if hz.weather == "drought": ci.draw_rect(world, Color(0.85, 0.7, 0.35, 0.2))

## Rain, snow and blizzards are drawn over the visible screen area only.
func _draw_weather() -> void:
	var hz = sim.hz
	if not hz.on(): return
	var w: String = hz.weather
	var snowing: bool = w == "blizzard" or (hz.winter() and w == "clear")
	if w in ["rain", "storm"]:
		for i in 220:
			var x := view.position.x + fmod(i * 137.71 + t * 60.0, view.size.x)
			var y := view.position.y + fmod(i * 91.37 + t * 620.0, view.size.y)
			ci.draw_line(Vector2(x, y), Vector2(x - 4, y + 16), Color(0.75, 0.85, 1.0, 0.35), 1.2)
		if w == "storm" and fmod(t, 7.3) < 0.12: ci.draw_rect(view, Color(1, 1, 0.9, 0.35))
	if snowing:
		var n := 420 if w == "blizzard" else 140
		var drift := 260.0 if w == "blizzard" else 25.0
		for i in n:
			var x := view.position.x + fmod(i * 137.71 + t * drift + sin(t + i) * 12.0, view.size.x)
			var y := view.position.y + fmod(i * 91.37 + t * (140.0 if w == "blizzard" else 45.0), view.size.y)
			ci.draw_circle(Vector2(x, y), 1.6 + fmod(i * 0.37, 1.6), Color(1, 1, 1, 0.75))
		if w == "blizzard": ci.draw_rect(view, Color(0.9, 0.94, 1.0, 0.25))

func _draw_wolf(p) -> void:
	var b := iso(p.pos)
	var key := "p%d" % p.id
	var f: float = facing.get(key, 1)
	var walk: bool = moving.get(key, false)
	_ell(b + Vector2(2, 1), 13, 4.5, SHADOW)
	var body := b - Vector2(0, 10)
	for i in 4:
		var lx := body.x + (-7 + i * 4.5) * f
		var sw := sin(t * 15 + i * 1.9) * 3.0 if walk else 0.0
		ci.draw_line(Vector2(lx, body.y + 2), Vector2(lx + sw, b.y), Color("#4a4a4e"), 2.2)
	ci.draw_line(body + Vector2(-10 * f, -1), body + Vector2(-17 * f, 3 + sin(t * 4) * 2), Color("#6d6d72"), 3)
	_ell(body, 11, 5, Color("#76767c"))
	_ell(body + Vector2(0, 2), 8, 2.5, Color("#a4a4aa"))
	var head := body + Vector2(11 * f, -4)
	_ell(head, 5, 4, Color("#808086"))
	ci.draw_colored_polygon(PackedVector2Array([head + Vector2(3 * f, -1), head + Vector2(10 * f, 1), head + Vector2(3 * f, 3)]), Color("#6d6d72"))
	ci.draw_colored_polygon(PackedVector2Array([head + Vector2(-3 * f, -3), head + Vector2(-1 * f, -9), head + Vector2(1 * f, -3)]), Color("#5a5a60"))
	ci.draw_circle(head + Vector2(3 * f, -1), 1.1, Color("#ffd040"))

func _in_view(p: Vector2) -> bool:
	return view.has_point(iso(p))

func _draw_landmark(lm: Dictionary) -> void:
	var b := iso(lm["pos"])
	if lm["kind"] == "spring" and _sprite("spring" + _snowy(), b):
		for i in 4:
			var k := fmod(t * 0.5 + i * 0.25, 1.0)
			ci.draw_circle(b + Vector2(-20 + i * 13 + sin(t + i) * 4, -10 - 40 * k), 4 + 6 * k, Color(1, 1, 1, 0.35 * (1 - k)))
		return
	if lm["kind"] in ["bones", "flint"] and _sprite(lm["kind"] + _snowy(), b): return
	if lm["kind"] in ["den", "cave", "stones", "peak"] and _sprite(lm["kind"] + _snowy(), b):
		if lm["kind"] == "den":
			ci.draw_circle(b + Vector2(-4, -6), 1.6, Color("#ffcf40", 0.6 + 0.4 * sin(t * 3)))
			ci.draw_circle(b + Vector2(4, -6), 1.6, Color("#ffcf40", 0.6 + 0.4 * sin(t * 3)))
		return
	match lm["kind"]:
		"cave", "den":
			var den: bool = lm["kind"] == "den"
			_ell(b + Vector2(10, 4), 50, 16, SHADOW)
			var rock := Color("#7d756a") if not den else Color("#6e6258")
			ci.draw_colored_polygon(PackedVector2Array([b + Vector2(-46, 6), b + Vector2(-38, -22), b + Vector2(-14, -40), b + Vector2(14, -42), b + Vector2(38, -24), b + Vector2(48, 6)]), rock)
			ci.draw_colored_polygon(PackedVector2Array([b + Vector2(14, -42), b + Vector2(38, -24), b + Vector2(48, 6), b + Vector2(10, 6)]), rock.darkened(0.25))
			ci.draw_colored_polygon(PackedVector2Array([b + Vector2(-38, -22), b + Vector2(-14, -40), b + Vector2(-6, -30), b + Vector2(-28, -14)]), rock.lightened(0.15))
			ci.draw_colored_polygon(PackedVector2Array([b + Vector2(-16, 6), b + Vector2(-12, -14), b + Vector2(0, -20), b + Vector2(12, -14), b + Vector2(16, 6)]), Color("#1a1410"))
			if den:
				for i in 4:
					var q := b + Vector2(-30 + i * 18, 10 + (i % 2) * 4)
					ci.draw_line(q, q + Vector2(9, -3), Color("#e8dcc0"), 2.5)
					ci.draw_circle(q, 2, Color("#e8dcc0"))
				ci.draw_circle(b + Vector2(-5, -4), 1.6, Color("#ffcf40", 0.6 + 0.4 * sin(t * 3)))
				ci.draw_circle(b + Vector2(5, -4), 1.6, Color("#ffcf40", 0.6 + 0.4 * sin(t * 3)))
			else:
				ci.draw_line(b + Vector2(-30, -16), b + Vector2(-22, -24), Color("#b8442e"), 2)
				ci.draw_circle(b + Vector2(24, -20), 3, Color("#c0703a"))
				ci.draw_line(b + Vector2(20, -12), b + Vector2(32, -16), Color("#b8442e"), 2)
		"stones":
			for i in 7:
				var a := TAU * i / 7
				var q := b + Vector2(cos(a) * 44, sin(a) * 22)
				if sin(a) < 0: _slab(q)
			_ell(b, 10, 5, Color(0.5, 0.45, 0.6, 0.5 + 0.3 * sin(t * 2)))
			for i in 7:
				var a := TAU * i / 7
				var q := b + Vector2(cos(a) * 44, sin(a) * 22)
				if sin(a) >= 0: _slab(q)
		"bones":
			_ell(b + Vector2(6, 3), 44, 14, SHADOW)
			for i in 6:
				var x := -26 + i * 10
				ci.draw_arc(b + Vector2(x, -4), 14, PI * 1.05, PI * 1.95, 10, Color("#e8dcc0"), 3)
			ci.draw_line(b + Vector2(-34, -2), b + Vector2(30, -2), Color("#d8ccb0"), 4)
			ci.draw_arc(b + Vector2(40, -14), 22, PI * 0.6, PI * 1.4, 14, Color("#f0e6d0"), 5)
			ci.draw_circle(b + Vector2(36, -4), 8, Color("#e0d4b8"))
		"flint":
			_ell(b + Vector2(6, 3), 34, 11, SHADOW)
			var shards := [[-24, 0, 12], [-8, -2, 20], [8, 0, 16], [22, 2, 10], [0, 6, 9]]
			for sh in shards:
				var q := b + Vector2(sh[0], sh[1])
				var h: float = sh[2]
				ci.draw_colored_polygon(PackedVector2Array([q + Vector2(-7, 0), q + Vector2(-3, -h), q + Vector2(4, -h * 0.8), q + Vector2(7, 0)]), Color("#3c3a40"))
				ci.draw_colored_polygon(PackedVector2Array([q + Vector2(-3, -h), q + Vector2(4, -h * 0.8), q + Vector2(0, -h * 0.4)]), Color("#6d6a78"))
		"grove":
			for i in 10:
				var q := b + Vector2(cos(i * 2.4) * 40, sin(i * 2.4) * 18)
				ci.draw_line(q, q + Vector2(0, -7), Color("#4f7a30"), 1.5)
				ci.draw_circle(q + Vector2(0, -8), 2.5, Color("#e85a8a") if i % 2 == 0 else Color("#f0d060"))
		"peak":
			_ell(b + Vector2(20, 6), 90, 26, SHADOW)
			ci.draw_colored_polygon(PackedVector2Array([b + Vector2(-80, 10), b + Vector2(-20, -90), b + Vector2(6, -110), b + Vector2(40, -70), b + Vector2(84, 10)]), Color("#8a8276"))
			ci.draw_colored_polygon(PackedVector2Array([b + Vector2(6, -110), b + Vector2(40, -70), b + Vector2(84, 10), b + Vector2(10, 10)]), Color("#6a6258"))
			ci.draw_colored_polygon(PackedVector2Array([b + Vector2(-20, -90), b + Vector2(6, -110), b + Vector2(22, -88), b + Vector2(4, -80), b + Vector2(-8, -84)]), Color("#eef2f4"))
			var e := b + Vector2(-30 + sin(t * 0.6) * 40, -130 + cos(t * 0.6) * 10)
			ci.draw_line(e, e + Vector2(-8, -4), Color("#2a1d10"), 2)
			ci.draw_line(e, e + Vector2(8, -4), Color("#2a1d10"), 2)
		"spring":
			_ell(b, 46, 20, Color("#b5a88a"))
			_ell(b, 38, 15, Color("#4fb0b8"))
			_ell(b + Vector2(-8, -3), 18, 6, Color("#8fdce0"))
			for i in 4:
				var k := fmod(t * 0.5 + i * 0.25, 1.0)
				ci.draw_circle(b + Vector2(-20 + i * 13 + sin(t + i) * 4, -10 - 40 * k), 4 + 6 * k, Color(1, 1, 1, 0.35 * (1 - k)))

func _slab(q: Vector2) -> void:
	_ell(q + Vector2(4, 1), 7, 3, SHADOW)
	ci.draw_colored_polygon(PackedVector2Array([q + Vector2(-5, 0), q + Vector2(-5, -24), q + Vector2(0, -28), q + Vector2(5, -24), q + Vector2(5, 0)]), Color("#9a968c"))
	ci.draw_colored_polygon(PackedVector2Array([q + Vector2(1, 0), q + Vector2(1, -27), q + Vector2(5, -24), q + Vector2(5, 0)]), Color("#77736a"))

## Earthen sides of the map diamond, so the world reads as a raised slab.
func _draw_slab() -> void:
	var r := iso(Vector2(D.W, 0))
	var b := iso(Vector2(D.W, D.H))
	var l := iso(Vector2(0, D.H))
	var dn := Vector2(0, 46)
	ci.draw_colored_polygon(PackedVector2Array([r, b, b + dn, r + dn]), Color("#4a3622"))
	ci.draw_colored_polygon(PackedVector2Array([b, l, l + dn, b + dn]), Color("#5e4529"))
	for i in 3:
		var k := 0.3 + i * 0.22
		ci.draw_line(r + dn * k, b + dn * k, Color(0, 0, 0, 0.18), 2)
		ci.draw_line(b + dn * k, l + dn * k, Color(0, 0, 0, 0.18), 2)

func _draw_water_fx() -> void:
	ci.draw_polyline(river_l, Color(0.85, 0.92, 1.0, 0.35), 3)
	ci.draw_polyline(river_r, Color(0.85, 0.92, 1.0, 0.35), 3)
	for i in 9:
		var sy: float = lerpf(D.FORD_Y0 + 10, D.FORD_Y1 - 10, float(i % 3) / 2.0)
		var sx: float = D.river_x(sy) + lerpf(-D.RIVER_HALF + 10, D.RIVER_HALF - 10, float(i / 3) / 2.0)
		ci.draw_circle(Vector2(sx + 2, sy + 2), 7, Color(0, 0, 0, 0.2))
		ci.draw_circle(Vector2(sx, sy), 7, Color("#a5a291"))
	for i in 110:
		var y := fmod(i * 47.0 + t * 26.0, D.H)
		if D.is_ford(y): continue
		var x := D.river_x(y) + sin(i * 12.3) * D.RIVER_HALF * 0.6
		ci.draw_line(Vector2(x, y), Vector2(x + 3, y + 14), Color(0.75, 0.9, 1.0, 0.35), 2)

func _draw_decor(d: Dictionary) -> void:
	var p := iso(d["p"])
	var s: float = d["s"]
	var sk := ""
	match d["kind"]:
		"tuft": sk = "grass_%d" % (d.get("v", 0) % 3)
		"flower": sk = "flower_%d" % (d.get("v", 0) % 3)
		"fern": sk = "fern_%d" % (d.get("v", 0) % 2)
		"reeds": sk = "reeds_%d" % (d.get("v", 0) % 2)
		"rock": sk = "pebbles"
	if sk != "" and _sprite(sk + _snowy(), p, s): return
	if d["kind"] in ["fern", "reeds"]: return
	match d["kind"]:
		"rock":
			_ell(p + Vector2(3, 1), 7 * s, 3 * s, SHADOW)
			ci.draw_colored_polygon(PackedVector2Array([p + Vector2(-6, 0) * s, p + Vector2(-4, -5) * s, p + Vector2(2, -7) * s, p + Vector2(6, -2) * s, p + Vector2(5, 1) * s]), Color("#8d8a80"))
			ci.draw_colored_polygon(PackedVector2Array([p + Vector2(-4, -5) * s, p + Vector2(2, -7) * s, p + Vector2(0, -3) * s]), Color("#a9a69b"))
		"flower":
			ci.draw_line(p, p + Vector2(0, -5), Color("#4f7a30"), 1)
			ci.draw_circle(p + Vector2(0, -6), 1.8, Color("#e8d35a") if int(d["p"].x) % 2 == 0 else Color("#d7708a"))
		_:
			var c := (Color("#3f5b2d") if d["east"] else Color("#5f7f38")).lightened(0.12 + d["c"])
			var sway := sin(t * 1.5 + p.x * 0.05) * 1.5
			if d["tall"]:
				ci.draw_line(p, p + Vector2(-3 + sway, -12) * s, c.darkened(0.15), 1.5)
				ci.draw_line(p, p + Vector2(sway, -16) * s, c, 1.5)
				ci.draw_line(p, p + Vector2(3 + sway, -11) * s, c.darkened(0.1), 1.5)
			else:
				ci.draw_line(p, p + Vector2(-2, -5) * s, c, 1.0)
				ci.draw_line(p, p + Vector2(2 + sway * 0.5, -6) * s, c, 1.0)

# ------------------------------------------------------------ primitives
func _org() -> Vector2:
	return (ci as Node2D).position if ci != self else Vector2.ZERO

## Scale subsequent drawing by k around screen point b (reset after each sorted item).
func _scale_about(b: Vector2, k: float) -> void:
	ci.draw_set_transform(b * (1.0 - k) - _org(), 0.0, Vector2(k, k))

func _ell(c: Vector2, rx: float, ry: float, col: Color, seg := 20) -> void:
	var pts := PackedVector2Array()
	for i in seg:
		var a := TAU * i / seg
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	ci.draw_colored_polygon(pts, col)

func _ell_line(c: Vector2, rx: float, ry: float, col: Color, w := 2.0, a0 := 0.0, a1 := TAU) -> void:
	var pts := PackedVector2Array()
	var seg := 28
	for i in seg + 1:
		var a := lerpf(a0, a1, float(i) / seg)
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	ci.draw_polyline(pts, col, w)

## Arc points of a world-space circle of radius r projected to screen (angles in screen-ellipse space).
func _arc_pts(c: Vector2, rx: float, ry: float, a0: float, a1: float, seg: int, lift := 0.0) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in seg + 1:
		var a := lerpf(a0, a1, float(i) / seg)
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry - lift))
	return pts

## Iso box centred on world point c (half-sizes in world units, height in px).
func _box(c: Vector2, hw: float, hd: float, h: float, col: Color, lift := 0.0) -> void:
	var l := Vector2(0, lift)
	var p1 := iso(c + Vector2(-hw, -hd)) - l
	var p2 := iso(c + Vector2(hw, -hd)) - l
	var p3 := iso(c + Vector2(hw, hd)) - l
	var p4 := iso(c + Vector2(-hw, hd)) - l
	var up := Vector2(0, h)
	ci.draw_colored_polygon(PackedVector2Array([p2, p3, p3 - up, p2 - up]), col.darkened(0.32))
	ci.draw_colored_polygon(PackedVector2Array([p4, p3, p3 - up, p4 - up]), col.darkened(0.12))
	ci.draw_colored_polygon(PackedVector2Array([p1 - up, p2 - up, p3 - up, p4 - up]), col.lightened(0.12))

## Round hut: cylinder wall + conical thatch roof. b = screen base, r = world radius.
func _round_house(b: Vector2, r: float, wall_h: float, roof_h: float, wall: Color, roof: Color, frac: float, built: bool) -> void:
	var rx := r * 1.06
	var ry := r * 0.53
	_ell(b + Vector2(rx * 0.35, ry * 0.25), rx * 1.15, ry * 1.1, SHADOW)
	if not built:
		_ell(b, rx, ry, Color(0.42, 0.32, 0.2, 0.75))
		var ph := (wall_h + roof_h) * clampf(frac * 1.4, 0.15, 1.0)
		var apex := b - Vector2(0, ph)
		for i in 8:
			var a := TAU * i / 8 + PI # back poles first
			var q := b + Vector2(cos(a) * rx, sin(a) * ry)
			ci.draw_line(q, q.lerp(apex, clampf(frac * 1.6, 0.2, 1.0)), Color("#7a5530"), 2.5)
		if frac > 0.45:
			var wh := wall_h * clampf((frac - 0.45) / 0.4, 0, 1)
			var pts := _arc_pts(b, rx, ry, 0, PI, 12)
			var top := _arc_pts(b, rx, ry, PI, 0, 12, wh)
			pts.append_array(top)
			if wh > 1: ci.draw_colored_polygon(pts, wall)
		return
	var pts := _arc_pts(b, rx, ry, 0, PI, 14)
	pts.append_array(_arc_pts(b, rx, ry, PI, 0, 14, wall_h))
	ci.draw_colored_polygon(pts, wall)
	var shade := _arc_pts(b, rx, ry, 0, PI * 0.4, 6)
	shade.append_array(_arc_pts(b, rx, ry, PI * 0.4, 0, 6, wall_h))
	ci.draw_colored_polygon(shade, Color(0, 0, 0, 0.22))
	# door
	var dc := b + Vector2(-rx * 0.18, ry * 0.98)
	ci.draw_colored_polygon(PackedVector2Array([dc + Vector2(-4, 0), dc + Vector2(-4, -wall_h * 0.8), dc + Vector2(0, -wall_h * 0.95), dc + Vector2(4, -wall_h * 0.8), dc + Vector2(4, 0)]), Color("#2a1a0e"))
	# roof
	var top := b - Vector2(0, wall_h)
	var apex := top - Vector2(0, roof_h)
	var orx := rx * 1.18
	var ory := ry * 1.18
	var roof_pts := _arc_pts(top, orx, ory, 0, PI, 16)
	roof_pts.append(apex)
	ci.draw_colored_polygon(roof_pts, roof)
	var dark := _arc_pts(top, orx, ory, 0, PI * 0.42, 7)
	dark.append(apex)
	ci.draw_colored_polygon(dark, roof.darkened(0.28))
	for i in 7:
		var q := top + Vector2(cos(PI * (i + 0.5) / 7) * orx, sin(PI * (i + 0.5) / 7) * ory)
		ci.draw_line(q, apex.lerp(q, 0.25), roof.darkened(0.4), 1)
	_ell_line(top, orx, ory, roof.darkened(0.45), 1.5, 0, PI)
	ci.draw_line(apex, apex + Vector2(-3, -5), Color("#5a3d22"), 2)
	ci.draw_line(apex, apex + Vector2(3, -5), Color("#5a3d22"), 2)

func _draw_post(b: Vector2, shown: bool, built: bool, style := 2) -> void:
	if not shown:
		ci.draw_circle(b, 2, Color(0.5, 0.4, 0.3, 0.35))
		return
	if _sprite("post%d%s" % [clampi(style, 1, 3), _snowy()], b): return
	var h := 20.0 + 3.0 * style
	ci.draw_line(b + Vector2(1, 0), b + Vector2(9, 3), Color(0, 0, 0, 0.18), 3)
	if style >= 3:
		_ell(b + Vector2(0, 1), 6, 3, Color("#8a877e"))
		_ell(b + Vector2(-1, 0), 4.5, 2.2, Color("#a3a097"))
	ci.draw_rect(Rect2(b.x - 3, b.y - h, 6, h), Color("#7a5530"))
	ci.draw_rect(Rect2(b.x + 0.5, b.y - h, 2.5, h), Color("#5c3f22"))
	ci.draw_colored_polygon(PackedVector2Array([b + Vector2(-3, -h), b + Vector2(3, -h), b + Vector2(0, -h - 6)]), Color("#a57a4a"))
	if style >= 2: ci.draw_line(b + Vector2(-4, -h * 0.45), b + Vector2(4, -h * 0.45), Color("#4a3018"), 1.5)
	if style >= 3: ci.draw_line(b + Vector2(-4, -h * 0.75), b + Vector2(4, -h * 0.75), Color("#4a3018"), 1.5)

# ------------------------------------------------------------ objects
func _snowy() -> String:
	return "_snow" if sim.hz.snow > 0.5 else ""

## Draw a baked sprite with its ground anchor at screen point b. False if not baked.
func _sprite(key: String, b: Vector2, sc := 1.0, mod := Color.WHITE) -> bool:
	if art == null or not art.has(key): return false
	var sp: Dictionary = art.get_sprite(key)
	var tex: Texture2D = sp["tex"]
	var k: float = sc / art.BAKE_SCALE
	ci.draw_texture_rect(tex, Rect2(b - sp["anchor"] * k, tex.get_size() * k), false, mod)
	return true

func _draw_node(n) -> void:
	var b := iso(n.pos)
	match n.kind:
		"tree":
			if _sprite(("pine_%d" if n.id % 3 != 2 else "leaf_%d") % (n.id % 4) + _snowy(), b, n.sz): return
		"bush":
			if _sprite(("bush_full" if n.amount >= 5 else "bush_bare") + _snowy(), b): return
		"stump":
			if _sprite("stump" + _snowy(), b): return
		"carcass":
			if n.from_deer and _sprite("deer_dead_%d_0" % (n.id % 8), b, 1.1): return
		"deer":
			if _beast_sprite("deer", "n%d" % n.id, b): return
		"boulder":
			if _sprite("rock_%d" % (n.id % 3) + _snowy(), b, clampf(n.amount / 40.0, 0.45, 1.0)): return
	match n.kind:
		"tree":
			var s: float = n.sz
			var east: bool = D.bank_of(n.pos) == "east"
			_ell(b + Vector2(12 * s, 4 * s), 18 * s, 7 * s, SHADOW)
			ci.draw_rect(Rect2(b.x - 2.5 * s, b.y - 14 * s, 5 * s, 14 * s), Color("#6b4524"))
			if n.id % 3 != 2:
				var dark := Color("#24452a") if east else Color("#2c5a2e")
				var lite := Color("#2f5c34") if east else Color("#3d7a3a")
				for i in 3:
					var by := b.y - (10 + i * 10) * s
					var hw := (15 - i * 3.5) * s
					var tip := Vector2(b.x, by - 18 * s)
					ci.draw_colored_polygon(PackedVector2Array([Vector2(b.x - hw, by), Vector2(b.x + hw, by), tip]), dark)
					ci.draw_colored_polygon(PackedVector2Array([Vector2(b.x - hw, by), Vector2(b.x - hw * 0.1, by + 2 * s), tip]), lite)
					if sim.hz.snow > 0.5:
						ci.draw_colored_polygon(PackedVector2Array([tip, tip + Vector2(-hw * 0.45, 8 * s), tip + Vector2(hw * 0.45, 8 * s)]), Color("#f4f8ff"))
			else:
				var c0 := Color("#2f5a2a") if not east else Color("#29482a")
				ci.draw_circle(b + Vector2(0, -26 * s), 14 * s, c0)
				ci.draw_circle(b + Vector2(-7, -22) * s, 9 * s, c0)
				ci.draw_circle(b + Vector2(7, -21) * s, 9 * s, c0.darkened(0.15))
				ci.draw_circle(b + Vector2(-4, -31) * s, 8 * s, c0.lightened(0.18))
				ci.draw_circle(b + Vector2(-6, -34) * s, 3.5 * s, c0.lightened(0.32))
				if sim.hz.snow > 0.5: _ell(b + Vector2(-2, -36) * s, 10 * s, 4 * s, Color("#f4f8ff"))
		"boulder":
			var k: float = clampf(n.amount / 40.0, 0.35, 1.0)
			_ell(b + Vector2(8, 3), 22 * k, 8 * k, SHADOW)
			for i in 3:
				var q := b + Vector2((i - 1) * 9 * k, (i % 2) * 3)
				var h: float = (14.0 - i * 3.0) * k
				ci.draw_colored_polygon(PackedVector2Array([q + Vector2(-9, 0) * k, q + Vector2(-7 * k, -h), q + Vector2(2 * k, -h - 4 * k), q + Vector2(9 * k, -h * 0.4), q + Vector2(8, 0) * k]), Color("#8e8a80"))
				ci.draw_colored_polygon(PackedVector2Array([q + Vector2(-7 * k, -h), q + Vector2(2 * k, -h - 4 * k), q + Vector2(0, -h * 0.5)]), Color("#b0aca2"))
		"stump":
			_ell(b + Vector2(2, 1), 7, 3.5, SHADOW)
			ci.draw_rect(Rect2(b.x - 5, b.y - 5, 10, 5), Color("#6b4a2a"))
			_ell(b - Vector2(0, 5), 5, 2.5, Color("#b08654"))
		"bush":
			_ell(b + Vector2(4, 2), 13, 5, SHADOW)
			ci.draw_circle(b + Vector2(-5, -6), 8, Color("#3a6a2e"))
			ci.draw_circle(b + Vector2(5, -6), 8, Color("#335f29"))
			ci.draw_circle(b + Vector2(0, -11), 8, Color("#4a7e38"))
			for i in int(n.amount / 5):
				ci.draw_circle(b + Vector2(cos(i * 2.4) * 8, -8 + sin(i * 2.4) * 5), 2, Color("#d23c4b"))
		"deer":
			_scale_about(b, FIG_SCALE)
			var key := "n%d" % n.id
			var f: float = facing.get(key, 1)
			var walk: bool = moving.get(key, false)
			_ell(b + Vector2(2, 1), 11, 4, SHADOW)
			var body := b - Vector2(0, 11)
			for i in 4:
				var lx := body.x + (-6 + i * 4) * f
				var sw := sin(t * 14 + i * 1.7) * 2.5 if walk else 0.0
				ci.draw_line(Vector2(lx, body.y + 2), Vector2(lx + sw, b.y), Color("#6e4a28"), 1.6)
			_ell(body, 9, 4.5, Color("#9a6a3c"))
			_ell(body + Vector2(0, 1.5), 7, 2.5, Color("#c09a70"))
			var head := body + Vector2(9 * f, -6)
			ci.draw_line(body + Vector2(6 * f, -1), head, Color("#9a6a3c"), 3.5)
			ci.draw_circle(head, 3.2, Color("#a87646"))
			ci.draw_line(head + Vector2(-1 * f, -2), head + Vector2(-4 * f, -9), Color("#e0d0b0"), 1.2)
			ci.draw_line(head + Vector2(1 * f, -2), head + Vector2(3 * f, -9), Color("#e0d0b0"), 1.2)
		"carcass":
			_ell(b, 10, 4.5, Color("#5e2219"))
			_ell(b - Vector2(0, 2), 8, 3.5, Color("#7a2f25"))
			ci.draw_line(b + Vector2(-7, -1), b + Vector2(7, -4), Color("#e8dcc0"), 2)

func _draw_ground_part(s) -> void:
	var p: Vector2 = s.pos
	var a := 1.0 if s.built else 0.5
	if s.built and art != null and ((s.type == "farm_plot" and art.has("farm_spring")) or (s.type == "fishing_dock" and art.has("dock"))): return
	match s.type:
		"farm_plot":
			ci.draw_rect(Rect2(p.x - 30, p.y - 20, 60, 40), Color(0.42, 0.3, 0.17, a))
			for i in 6:
				var yy := p.y - 16 + i * 6.5
				ci.draw_line(Vector2(p.x - 26, yy), Vector2(p.x + 26, yy), Color(0.32, 0.22, 0.12, a), 2)
				if s.built:
					var k := 0
					while k < 9:
						ci.draw_circle(Vector2(p.x - 24 + k * 6, yy - 1.5), 1.6, Color("#9cc94a"))
						k += 1
		"fishing_dock":
			var c := Color("#9a7448") if s.built else Color(0.6, 0.45, 0.3, 0.5)
			ci.draw_rect(Rect2(p.x - 52, p.y - 8, 58, 16), Color(0, 0, 0, 0.22))
			ci.draw_rect(Rect2(p.x - 50, p.y - 7, 54, 14), c)
			for i in 7: ci.draw_line(Vector2(p.x - 48 + i * 8, p.y - 7), Vector2(p.x - 48 + i * 8, p.y + 7), c.darkened(0.35), 1.2)
		"bonfire":
			for i in 9:
				ci.draw_circle(p + Vector2.from_angle(i * TAU / 9) * 12, 3.5, Color(0.55, 0.55, 0.5, a))
			ci.draw_circle(p, 8, Color(0.15, 0.1, 0.06, 0.8 * a))
		"grand_altar", "totem_shrine":
			ci.draw_circle(p, D.STRUCTURES[s.type]["r"] + 10, Color(0.55, 0.5, 0.4, 0.35 * a))

## Construction sprite for an unbuilt structure: footprint shape and size by type
## (homes follow the current era), stage by progress. False if not baked.
const SITE_SHAPES := {
	"hut": ["round", 20], "large_hut": ["round", 26], "granary": ["round", 20], "smelter": ["round", 14],
	"council_ring": ["round", 26], "totem_shrine": ["round", 14], "grand_altar": ["rect", 26],
	"weapon_rack": ["round", 14], "aurochs_pen": ["round", 26], "bonfire": ["round", 14],
}
func _draw_site_stage(s, b: Vector2) -> bool:
	if not SITE_SHAPES.has(s.type): return false
	var shape: String = SITE_SHAPES[s.type][0]
	var size: int = SITE_SHAPES[s.type][1]
	if s.type in ["hut", "large_hut"] and sim.evo.era >= 3: shape = "rect"
	var frac: float = s.progress / s.work
	var stage := 0
	if s.paid: stage = 1 if frac < 0.2 else (2 if frac < 0.5 else 3)
	return _sprite("site_%s_%d_%d" % [shape, size, stage], b, 1.0, Color(1, 1, 1, 0.75) if not s.paid else Color.WHITE)

func _draw_structure(s) -> void:
	var b := iso(s.pos)
	var frac: float = s.progress / s.work
	var a := 1.0 if s.built else 0.55
	if not s.built and _draw_site_stage(s, b): return
	if s.built and s.type == "farm_plot":
		var season: String = ["spring", "summer", "autumn", "winter"][sim.hz.season_idx()] if sim.hz.on() else "summer"
		if _sprite("farm_" + season, b): return
	var west_dock: bool = s.type == "fishing_dock" and D.bank_of(s.pos) == "west"
	if s.built and s.type == "fishing_dock" and _sprite(("dock_w" if west_dock else "dock") + _snowy(), b):
		var rod := iso(s.pos + Vector2(60 if west_dock else -60, -4 if west_dock else 4))
		ci.draw_line(rod + Vector2(0, -20), rod + Vector2(-4, 6 + sin(t * 2) * 2), Color(1, 1, 1, 0.45), 1)
		return
	if s.built and s.type in ["granary", "smelter", "council_ring", "totem_shrine", "grand_altar", "weapon_rack", "aurochs_pen"]:
		if _sprite(s.type + _snowy(), b):
			match s.type:
				"smelter": _smoke(b - Vector2(-4, 36), s.id)
				"council_ring": _flame(b - Vector2(0, 2), 4, 11 * (1.0 + 0.15 * sin(t * 10 + s.id)), Color("#f8a531"))
			return
	match s.type:
		"hut", "large_hut":
			var big: bool = s.type == "large_hut"
			var r := 27.0 if big else 20.0
			if s.built and _sprite("%shome%d%s" % ["large_" if big else "", clampi(s.style, 1, 3), _snowy()], b):
				if sim.has_tech("fire"): _smoke(b - Vector2(0, (32 if s.style == 1 else 36) + (6 if big else 0)), s.id)
				if s.reno: _scaffold(b, r)
				return
			if not s.built:
				_round_house(b, r, 13 if big else 11, 30 if big else 24, Color("#9b7a52"), Color("#c9a24f"), frac, false)
			elif s.style <= 1:
				_tent(b, r * 0.95, Color("#a8865c") if big else Color("#b8946a"))
			elif s.style == 2:
				_round_house(b, r, 13 if big else 11, 30 if big else 24, Color("#8f6d48") if big else Color("#9b7a52"), Color("#b98f42") if big else Color("#c9a24f"), frac, true)
			else:
				_longhouse(s.pos, r)
			if s.built and sim.has_tech("fire"): _smoke(b - Vector2(0, (30 if s.style == 1 else 34) + (6 if big else 0)), s.id)
			if s.reno: _scaffold(b, r)
		"aurochs_pen":
			_pen(s, b, a)
		"smelter":
			_smelter(s, b, a)
		"council_ring":
			_council(s, b, a)
		"granary":
			if s.built:
				for i in 4:
					var q := b + Vector2(cos(i * TAU / 4 + 0.6) * 14, sin(i * TAU / 4 + 0.6) * 7)
					ci.draw_line(q, q - Vector2(0, 8), Color("#5a3d22"), 3)
				_round_house(b - Vector2(0, 8), 18, 16, 16, Color("#c08a58"), Color("#a7703f"), frac, true)
			else:
				_round_house(b, 18, 16, 16, Color("#c08a58"), Color("#a7703f"), frac, false)
		"bonfire":
			if not s.built:
				_logs(b, a)
				return
			if not _sprite("fire_base" + _snowy(), b): _logs(b, 1.0)
			var fl := 1.0 + 0.18 * sin(t * 11 + s.id)
			var fl2 := 1.0 + 0.22 * sin(t * 15 + s.id * 2.0)
			_flame(b - Vector2(0, 3), 9 * fl, 26 * fl, Color("#e2541b"))
			_flame(b - Vector2(-1, 4), 6 * fl2, 18 * fl2, Color("#f8a531"))
			_flame(b - Vector2(0, 5), 3 * fl, 10 * fl, Color("#fff1a0"))
			for i in 3:
				var k := fmod(t * 0.9 + i * 0.33, 1.0)
				ci.draw_circle(b + Vector2(sin(t * 3 + i) * 4, -30 - 30 * k), 2.5 + 3 * k, Color(0.5, 0.5, 0.5, 0.3 * (1 - k)))
		"fishing_dock":
			var c := Color("#6b4a2a") if s.built else Color(0.5, 0.35, 0.2, 0.5)
			for q in [s.pos + Vector2(-48, -7), s.pos + Vector2(-48, 7), s.pos + Vector2(-20, -7), s.pos + Vector2(-20, 7)]:
				var sp := iso(q)
				ci.draw_line(sp + Vector2(0, 4), sp - Vector2(0, 6), c, 3)
			if s.built:
				var rod := iso(s.pos + Vector2(-50, 0))
				ci.draw_line(rod - Vector2(0, 4), rod + Vector2(-26, -26), Color("#c8b48a"), 1.5)
				ci.draw_line(rod + Vector2(-26, -26), rod + Vector2(-30, 4 + sin(t * 2) * 2), Color(1, 1, 1, 0.5), 1)
		"weapon_rack":
			_ell(b + Vector2(4, 2), 16, 5, SHADOW)
			var l := iso(s.pos + Vector2(-10, 6))
			var r := iso(s.pos + Vector2(10, -6))
			ci.draw_line(l, l - Vector2(0, 16), Color(C_WOOD, a), 3)
			ci.draw_line(r, r - Vector2(0, 16), Color(C_WOOD, a), 3)
			ci.draw_line(l - Vector2(0, 14), r - Vector2(0, 14), Color(C_WOOD.darkened(0.2), a), 3)
			for i in 4:
				var q := l.lerp(r, 0.15 + i * 0.23)
				ci.draw_line(q + Vector2(-3, 2), q + Vector2(2, -30), Color(0.78, 0.72, 0.6, a), 2)
				ci.draw_colored_polygon(PackedVector2Array([q + Vector2(1, -30), q + Vector2(4, -30), q + Vector2(2.5, -37)]), Color(0.6, 0.6, 0.62, a))
		"totem_shrine":
			_ell(b + Vector2(6, 2), 16, 6, SHADOW)
			for i in 6:
				var q := b + Vector2(cos(i * TAU / 6) * 12, sin(i * TAU / 6) * 6)
				ci.draw_circle(q, 3, Color(0.6, 0.58, 0.52, a))
			_totem(b, 44, 1.0, a)
		"grand_altar":
			_box(s.pos, 30, 30, 8, Color(0.62, 0.6, 0.56, a))
			_box(s.pos, 20, 20, 16, Color(0.66, 0.64, 0.6, a))
			_totem(b - Vector2(0, 16), 54, 1.3, a)

# ---- era styles & new buildings
## Era 1 home: a hide tent on leaning poles.
func _tent(b: Vector2, r: float, hide: Color) -> void:
	var rx := r * 1.0
	var ry := r * 0.5
	_ell(b + Vector2(rx * 0.4, ry * 0.3), rx * 1.2, ry * 1.1, SHADOW)
	var apex := b - Vector2(0, r * 1.55)
	var pts := _arc_pts(b, rx, ry, 0, PI, 14)
	pts.append(apex)
	ci.draw_colored_polygon(pts, hide)
	var dark := _arc_pts(b, rx, ry, 0, PI * 0.4, 6)
	dark.append(apex)
	ci.draw_colored_polygon(dark, hide.darkened(0.25))
	for i in 5: # seams
		var q := b + Vector2(cos(PI * (i + 0.5) / 5) * rx, sin(PI * (i + 0.5) / 5) * ry)
		ci.draw_line(q, apex.lerp(q, 0.1), hide.darkened(0.35), 1)
	ci.draw_colored_polygon(PackedVector2Array([b + Vector2(-5, ry * 0.95), b + Vector2(3, ry), b + Vector2(-1, -r * 0.55)]), Color("#3a2414"))
	for d in [-1, 1, 0]:
		ci.draw_line(apex, apex + Vector2(d * 5 - 1, -9), Color("#6b4524"), 2)

## Era 3 home: timber longhouse on a stone footing with a carved gable.
func _longhouse(c: Vector2, r: float) -> void:
	var hw := r * 1.25
	var hd := r * 0.7
	var b := iso(c)
	_ell(b + Vector2(16, 6), hw * 1.4, hd * 0.9, SHADOW)
	_box(c, hw + 4, hd + 4, 5, Color("#8f8b82"))
	_box(c, hw, hd, 14, Color("#8a5f3a"), 5)
	var eave := 19.0
	var rh := 18.0 + r * 0.3
	var ue := Vector2(0, eave)
	var ur := Vector2(0, eave + rh)
	var e1 := iso(c + Vector2(-hw - 3, -hd - 3)) - ue
	var e2 := iso(c + Vector2(hw + 3, -hd - 3)) - ue
	var e3 := iso(c + Vector2(hw + 3, hd + 3)) - ue
	var e4 := iso(c + Vector2(-hw - 3, hd + 3)) - ue
	var rl := iso(c + Vector2(-hw - 3, 0)) - ur
	var rr := iso(c + Vector2(hw + 3, 0)) - ur
	ci.draw_colored_polygon(PackedVector2Array([e1, e2, rr, rl]), Color("#7a5a32"))
	ci.draw_colored_polygon(PackedVector2Array([e2, e3, rr]), Color("#6e4a28"))
	ci.draw_colored_polygon(PackedVector2Array([e4, e3, rr, rl]), Color("#a8823e"))
	for i in 6:
		var k := (i + 0.5) / 6.0
		ci.draw_line(e4.lerp(e3, k), rl.lerp(rr, k), Color("#8a6a30"), 1)
	ci.draw_line(rl, rr, Color("#5a3d22"), 2)
	ci.draw_line(rr, rr + Vector2(-5, -8), Color("#c0392b"), 2.5)
	ci.draw_line(rr, rr + Vector2(5, -8), Color("#c0392b"), 2.5)
	var door := iso(c + Vector2(0, hd)) - Vector2(0, 5)
	ci.draw_colored_polygon(PackedVector2Array([door + Vector2(-5, 0), door + Vector2(-5, -11), door + Vector2(5, -11), door + Vector2(5, 0)]), Color("#2a1a0e"))

func _smoke(p: Vector2, seed_id: int) -> void:
	for i in 3:
		var k := fmod(t * 0.35 + i / 3.0 + seed_id * 0.13, 1.0)
		ci.draw_circle(p + Vector2(sin(t * 1.3 + i + seed_id) * 3 + 6 * k, -24 * k), 2.0 + 4.0 * k, Color(0.75, 0.75, 0.75, 0.32 * (1.0 - k)))

func _scaffold(b: Vector2, r: float) -> void:
	for x in [-r * 0.9, r * 0.9]:
		ci.draw_line(b + Vector2(x, 4), b + Vector2(x, -r * 1.6), Color("#c8a46a"), 2)
	ci.draw_line(b + Vector2(-r, -r * 0.7), b + Vector2(r, -r * 0.7), Color("#c8a46a"), 2)
	ci.draw_line(b + Vector2(-r, -r * 1.3), b + Vector2(r, -r * 1.3), Color("#c8a46a"), 2)

func _pen(s, b: Vector2, a: float) -> void:
	var rx := 32.0
	var ry := 16.0
	var col := Color(Color("#7a5530"), a)
	var back := _arc_pts(b, rx, ry, PI, TAU, 10)
	ci.draw_polyline(back, col, 2)
	for q in back: ci.draw_line(q, q - Vector2(0, 9), col, 2)
	ci.draw_polyline(_arc_pts(b, rx, ry, PI, TAU, 10, 6), col, 1.5)
	if s.built:
		for i in 2:
			var ph: float = t * 0.4 + i * 3.0 + s.id
			var q := b + Vector2(sin(ph) * 14 - 6 + i * 10, cos(ph * 0.7) * 5)
			var f := 1.0 if cos(ph) > 0 else -1.0
			_ell(q + Vector2(2, 1), 9, 3, SHADOW)
			_ell(q - Vector2(0, 7), 9, 5, Color("#3d2a1c"))
			ci.draw_circle(q + Vector2(9 * f, -9), 3.5, Color("#4a3322"))
			ci.draw_line(q + Vector2(9 * f, -12), q + Vector2(13 * f, -16), Color("#e8dcc0"), 1.5)
			ci.draw_line(q + Vector2(7 * f, -12), q + Vector2(5 * f, -16), Color("#e8dcc0"), 1.5)
			for l in [-5, -1, 3, 6]: ci.draw_line(q + Vector2(l, -4), q + Vector2(l, 0), Color("#2a1d10"), 1.5)
	var front := _arc_pts(b, rx, ry, 0, PI, 10)
	ci.draw_polyline(front, col, 2)
	for q in front: ci.draw_line(q, q - Vector2(0, 9), col, 2)
	ci.draw_polyline(_arc_pts(b, rx, ry, 0, PI, 10, 6), col, 1.5)

func _smelter(s, b: Vector2, a: float) -> void:
	_ell(b + Vector2(8, 3), 22, 8, SHADOW)
	var stone := Color(Color("#7d776c"), a)
	ci.draw_colored_polygon(_arc_pts(b, 16, 8, 0, PI, 10) + _arc_pts(b - Vector2(0, 18), 12, 6, PI, 0, 10), stone)
	ci.draw_colored_polygon(_arc_pts(b - Vector2(0, 18), 12, 6, PI, TAU, 10) + _arc_pts(b - Vector2(0, 18), 12, 6, 0, PI, 10), stone.lightened(0.1))
	ci.draw_rect(Rect2(b.x + 2, b.y - 34, 6, 16), stone.darkened(0.15))
	if s.built:
		var glow := 0.75 + 0.25 * sin(t * 6 + s.id)
		ci.draw_colored_polygon(PackedVector2Array([b + Vector2(-6, 6), b + Vector2(-6, -4), b + Vector2(0, -8), b + Vector2(6, -4), b + Vector2(6, 6)]), Color(1.0, 0.45 * glow + 0.2, 0.1, 1.0))
		for i in 3: ci.draw_rect(Rect2(b.x + 14 + i * 4, b.y + 2 - i, 6, 3), Color("#d49a3a"))
		_smoke(b - Vector2(-5, 36), s.id)

func _council(s, b: Vector2, a: float) -> void:
	for i in 10:
		var ang := TAU * i / 10
		var q := b + Vector2(cos(ang) * 34, sin(ang) * 17)
		_ell(q + Vector2(2, 1), 6, 3, SHADOW)
		ci.draw_colored_polygon(PackedVector2Array([q + Vector2(-5, 0), q + Vector2(-4, -6), q + Vector2(4, -7), q + Vector2(5, 0)]), Color(Color("#9a968c"), a))
	if s.built:
		_logs(b, 1.0)
		_flame(b - Vector2(0, 3), 5, 13 * (1.0 + 0.15 * sin(t * 10 + s.id)), Color("#f8a531"))
	_totem(b - Vector2(0, 0) + Vector2(0, -16), 18, 0.6, a)

func _logs(b: Vector2, a: float) -> void:
	ci.draw_line(b + Vector2(-9, 2), b + Vector2(7, -5), Color(0.35, 0.22, 0.1, a), 3.5)
	ci.draw_line(b + Vector2(9, 2), b + Vector2(-7, -5), Color(0.42, 0.27, 0.12, a), 3.5)

func _flame(b: Vector2, w: float, h: float, col: Color) -> void:
	var sway := sin(t * 7 + b.x) * w * 0.3
	ci.draw_colored_polygon(PackedVector2Array([b + Vector2(-w, 0), b + Vector2(-w * 0.6, -h * 0.45), b + Vector2(sway, -h), b + Vector2(w * 0.6, -h * 0.45), b + Vector2(w, 0), b + Vector2(0, w * 0.35)]), col)

func _totem(b: Vector2, h: float, s: float, a: float) -> void:
	ci.draw_rect(Rect2(b.x - 4 * s, b.y - h, 8 * s, h), Color(Color("#6b4a2a"), a))
	ci.draw_rect(Rect2(b.x + 1 * s, b.y - h, 3 * s, h), Color(Color("#4f361d"), a))
	var cols := [Color("#c0392b"), Color("#e6b33a"), Color("#2e86ab"), Color("#c0392b")]
	for i in 4:
		var y := b.y - h + 4 + i * h * 0.22
		ci.draw_rect(Rect2(b.x - 5 * s, y, 10 * s, h * 0.12), Color(cols[i], a))
		ci.draw_circle(Vector2(b.x - 2 * s, y + h * 0.06), 1.3 * s, Color(0, 0, 0, a))
		ci.draw_circle(Vector2(b.x + 2 * s, y + h * 0.06), 1.3 * s, Color(0, 0, 0, a))
	var wy := b.y - h + 6
	ci.draw_colored_polygon(PackedVector2Array([Vector2(b.x - 4 * s, wy), Vector2(b.x - 18 * s, wy - 8 * s), Vector2(b.x - 15 * s, wy + 2 * s)]), Color(Color("#e6b33a"), a))
	ci.draw_colored_polygon(PackedVector2Array([Vector2(b.x + 4 * s, wy), Vector2(b.x + 18 * s, wy - 8 * s), Vector2(b.x + 15 * s, wy + 2 * s)]), Color(Color("#d4a02e"), a))

func _draw_structure_overlay(s) -> void:
	if s.reno:
		var rb := iso(s.pos)
		_bar(Vector2(rb.x, rb.y + 10), 38, s.reno_progress / (s.work * 0.6), Color("#ffd36b"))
		return
	if s.built: return
	var sd: Dictionary = D.STRUCTURES[s.type]
	var b := iso(s.pos) if not sd.get("ring", false) else iso(s.pos + Vector2(sd["r"], sd["r"]) * 0.707)
	var by: float = b.y + 10
	_bar(Vector2(b.x, by), 38, s.progress / s.work, Color("#b6f28a"))
	if not s.paid: _draw_label(Vector2(b.x, by + 17), tr("awaiting wood"), 11, Color(1, 0.8, 0.6), true)

func _draw_site_ring(c) -> void:
	var col := _site_col(c)
	if c.status == "done": return
	for i in 32:
		var a0 := float(i) / 32 * TAU + t * 0.2
		ci.draw_arc(c.site, 125, a0, a0 + TAU / 64, 4, Color(col, 0.6), 4)

func _site_col(c) -> Color:
	match c.status:
		"interrupted", "defending": return Color("#ff6b6b")
		"done": return Color("#b6f28a")
		"abandoned", "failed": return Color(0.6, 0.6, 0.6)
	return Color("#ffd36b")

## A rival village's totem banner with the clan's name and how they feel about us.
func _draw_clan_banner(c: Dictionary) -> void:
	var pos: Vector2 = c["pos"]
	if not sim.is_explored(pos) or not _in_view(pos): return
	var col: Color = c["color"]
	var fp := iso(pos + Vector2(-70, -70))
	ci.draw_line(fp + Vector2(1, 0), fp + Vector2(1, -58), Color(0, 0, 0, 0.4), 4)
	ci.draw_line(fp, fp + Vector2(0, -58), Color("#4a3220"), 3)
	ci.draw_circle(fp + Vector2(0, -60), 3, Color("#e8dcc0"))
	var wv := sin(t * 3.5 + pos.x) * 3
	var top := fp + Vector2(0, -56)
	ci.draw_colored_polygon(PackedVector2Array([top, top + Vector2(26, 2 + wv), top + Vector2(24, 18 + wv), top + Vector2(0, 16)]), col)
	ci.draw_polyline(PackedVector2Array([top + Vector2(0, 16), top + Vector2(24, 18 + wv), top + Vector2(26, 2 + wv)]), col.darkened(0.4), 1.5)
	for i in 3: # feather tassels
		ci.draw_line(top + Vector2(6 + i * 8, 17 + wv * 0.6), top + Vector2(5 + i * 8, 25 + wv * 0.6), Color("#e8dcc0"), 1.2)
	var st: String = sim.rivals.stance(c["id"])
	var scol: Color = {"Blood feud": Color("#ff5a4a"), "Hostile": Color("#ff8a6a"), "Wary": Color("#ffe08a"), "Friendly": Color("#b6f28a"), "Allied": Color("#8af2d0")}[st]
	_draw_label(fp + Vector2(12, -72), tr(c["name"]).to_upper(), 15, col.lightened(0.5), true)
	if c["met"]: _draw_label(fp + Vector2(12, -88), tr(st), 12, scol, true)

func _draw_site_flag(c) -> void:
	var col := _site_col(c)
	var fp := iso(c.site + Vector2(-100, -100))
	ci.draw_line(fp, fp + Vector2(0, -44), Color("#5a3d22"), 3)
	var wv := sin(t * 4) * 3
	ci.draw_colored_polygon(PackedVector2Array([fp + Vector2(0, -44), fp + Vector2(24, -38 + wv), fp + Vector2(0, -30)]), col)
	var ld = sim.unit_by_id(c.leader_id)
	var label := "%s  [%s %d%%]" % [c.plan["plan_id"], tr(c.status).to_upper(), roundi(c.progress * 100)]
	_draw_label(fp + Vector2(0, -52), label, 14, col, true)
	if ld and c.status not in ["done", "abandoned", "failed"]:
		_draw_label(fp + Vector2(0, -70), tr("Leader: %s · %s") % [tr(ld.name), c.substate], 12, Color(1, 1, 1, 0.85), true)

func _draw_unit(u) -> void:
	var b := iso(u.pos)
	_scale_about(b, FIG_SCALE)
	if u.dead and art and art.has("man_dead_0_0"):
		var dn := "man_dead_%d_0" % _dir_index("u%d" % u.id)
		_sprite(dn, b, 0.95, Color(1, 1, 1, 0.85))
		_sprite(dn + "_cloth", b, 0.95, Color(u.color, 0.85))
		return
	if u.dead:
		_ell(b, 9, 4, Color(0.25, 0.1, 0.08, 0.5))
		ci.draw_line(b + Vector2(-8, -1), b + Vector2(8, 1), Color(u.color, 0.6), 4)
		ci.draw_circle(b + Vector2(10, 1), 3, Color(0.85, 0.7, 0.55, 0.6))
		return
	var key := "u%d" % u.id
	var f: float = facing.get(key, 1)
	var walk: bool = moving.get(key, false)
	var sel: bool = u.id in selected
	_ell(b + Vector2(2, 0), 9, 4, SHADOW)
	if u.hero: _ell(b, 15 + sin(t * 4) * 1.5, 7.5, Color(1, 0.85, 0.3, 0.3))
	if sel: _ell_line(b, 14, 7, Color("#ffe066"), 2)
	if u.role == "contract": _ell_line(b, 11, 5.5, Color(0.55, 0.8, 1.0, 0.8), 1.5)
	var busy: bool = u.act in ["Chopping wood", "Picking berries", "Butchering game", "Building", "Fighting", "Quarrying stone"] or u.act.begins_with("Build") or u.act.begins_with("Renovating")
	if art and art.has("man_idle_0_0"):
		_draw_unit_sprite(u, b, key, walk, busy)
		return
	var bob := absf(sin(t * 12 + u.id)) * 1.5 if walk else 0.0
	var skin := Color("#d9a77c")
	# legs
	var sw := sin(t * 12 + u.id) * 3.0 if walk else 0.0
	ci.draw_line(b + Vector2(-2, -9 - bob), b + Vector2(-2 + sw, 0), skin.darkened(0.25), 2.5)
	ci.draw_line(b + Vector2(2, -9 - bob), b + Vector2(2 - sw, 0), skin.darkened(0.15), 2.5)
	# torso (fur tunic)
	var hip := b + Vector2(0, -8 - bob)
	if u.carry_amt > 0 and sim.has_tech("domestication") and u.job.get("type", "") == "gather":
		var behind: Vector2 = -heading.get(key, Vector2(0.6, 0.8)) * 18.0
		if not _beast_sprite("packox", key, b + behind, 0.8): _pack_ox(b + Vector2(-17 * f, 3), f, walk)
	if sim.has_tech("hide"): # fur cloak behind the body
		ci.draw_colored_polygon(PackedVector2Array([hip + Vector2(-6, -12), hip + Vector2(6, -12), hip + Vector2(-4 * f + 5 * f, 2), hip + Vector2(-8 * f, 1)]), Color("#7a5a3a"))
	ci.draw_colored_polygon(PackedVector2Array([hip + Vector2(-5, 1), hip + Vector2(5, 1), hip + Vector2(4, -12), hip + Vector2(-4, -12)]), u.color)
	ci.draw_colored_polygon(PackedVector2Array([hip + Vector2(1.5 * f, 1), hip + Vector2(5 * f, 1), hip + Vector2(4 * f, -12), hip + Vector2(1 * f, -12)]), u.color.darkened(0.25))
	ci.draw_line(hip + Vector2(-5, 1), hip + Vector2(5, 1), u.color.darkened(0.45), 1.5)
	# arms / tool
	var sh := hip + Vector2(0, -10)
	var swing := sin(t * 9 + u.id) * 0.9 if busy else 0.0
	var hand := sh + Vector2(6 * f, 6).rotated(swing * -f * 0.6)
	ci.draw_line(sh + Vector2(3 * f, 0), hand, skin, 2)
	ci.draw_line(sh + Vector2(-3 * f, 0), sh + Vector2(-5 * f, 7 + sw * 0.4), skin.darkened(0.1), 2)
	if u.job.get("type", "") == "attack" or u.act == "Fighting" or u.has_trait("belligerent"):
		var dirv := Vector2(0.35 * f, -1).normalized().rotated(swing * f * 0.5)
		ci.draw_line(hand - dirv * 6, hand + dirv * 18, Color("#b9a27a"), 1.6)
		ci.draw_colored_polygon(PackedVector2Array([hand + dirv * 18 + Vector2(-2, 0), hand + dirv * 18 + Vector2(2, 0), hand + dirv * 24]), _blade_col())
	elif busy:
		var tool := Vector2(0.9 * f, -0.4).normalized().rotated(swing * f)
		ci.draw_line(hand, hand + tool * 10, Color("#8a5a32"), 2)
		ci.draw_circle(hand + tool * 10, 2.2, _blade_col())
	# head
	var head := sh + Vector2(0, -5)
	ci.draw_circle(head, 4.5, skin)
	ci.draw_colored_polygon(PackedVector2Array([head + Vector2(-5, -1), head + Vector2(-3.5, -5), head + Vector2(3.5, -5.5), head + Vector2(5, -1), head + Vector2(-1 * f, -2.5)]), Color("#2e1d10"))
	ci.draw_circle(head + Vector2(2 * f, 0), 0.9, Color("#1a0f08"))
	if sim.has_bronze() and (u.has_trait("belligerent") or u.job.get("type", "") == "attack" or u.title == "War Chief"):
		ci.draw_colored_polygon(_arc_pts(head - Vector2(0, 1), 5.5, 5.5, PI, TAU, 8), Color("#c8902e"))
		ci.draw_circle(hip + Vector2(0, -6), 2.5, Color("#d49a3a"))
	if u.title != "":
		ci.draw_colored_polygon(PackedVector2Array([head + Vector2(-4, -5), head + Vector2(-1, -11), head + Vector2(0, -5.5), head + Vector2(2, -12), head + Vector2(4, -5)]), Color("#e8c25a"))
	if u.sick > 0: # fever: green, sweating
		ci.draw_circle(head + Vector2(-1, -1), 4.6, Color(0.55, 0.85, 0.35, 0.45))
		for i in 2:
			var k := fmod(t * 0.8 + i * 0.5, 1.0)
			ci.draw_circle(head + Vector2(6 - i * 12, -6 - 14 * k), 1.6, Color(0.6, 0.9, 0.4, 1.0 - k))
	if _has_torch(u):
		var th := sh + Vector2(-6 * f, 4)
		ci.draw_line(th, th + Vector2(-2 * f, -14), Color("#6b4524"), 2)
		_flame(th + Vector2(-2 * f, -14), 3, 9 * (1.0 + 0.2 * sin(t * 14 + u.id)), Color("#f8a531"))
	if u.carry_amt > 0:
		var bk := hip + Vector2(-6 * f, -8)
		if u.carry_type == "wood":
			ci.draw_line(bk + Vector2(-3, 3), bk + Vector2(3, -5), Color("#7a4e28"), 3)
			ci.draw_line(bk + Vector2(-1, 4), bk + Vector2(5, -3), Color("#8a5a32"), 3)
		else:
			ci.draw_circle(bk, 4, Color("#b03a2e"))
	if u.job.get("type", "") == "ritual" and u.act == "Performing ritual":
		_ell_line(b - Vector2(0, 12), 16 + sin(t * 3) * 3, 8, Color(0.75, 0.6, 1.0, 0.6), 1.5)
		for i in 3:
			var k := fmod(t * 0.7 + i / 3.0, 1.0)
			ci.draw_circle(b + Vector2(sin(t * 2 + i * 2) * 10, -10 - 30 * k), 1.8, Color(0.8, 0.7, 1, 1 - k))

func _dir_index(key: String) -> int:
	var dir: Vector2 = heading.get(key, Vector2(0.6, 0.8))
	var di := 0
	var best := -2.0
	for i in sprite_dirs.size():
		var dd: float = sprite_dirs[i].dot(dir)
		if dd > best:
			best = dd
			di = i
	return di

## Pre-rendered animal: 8 facings, idle / 6-frame walk.
func _beast_sprite(kind: String, key: String, b: Vector2, sc := 1.1) -> bool:
	if art == null or not art.has(kind + "_idle_0_0"): return false
	var di := _dir_index(key)
	var name := "%s_idle_%d_0" % [kind, di]
	if moving.get(key, false): name = "%s_walk_%d_%d" % [kind, di, int(t * 10.0 + key.hash() % 7) % 6]
	if attacking.has(key) and art.has("%s_attack_%d_0" % [kind, di]): name = "%s_attack_%d_%d" % [kind, di, int(t * 8.0) % 4]
	return _sprite(name, b, sc)

## Pre-rendered villager: 8 facings, idle / walk / work frames, clothes tinted per person.
func _draw_unit_sprite(u, b: Vector2, key: String, walk: bool, busy: bool) -> void:
	var di := _dir_index(key)
	var anim := "idle"
	var act: String = u.act
	if u.job.get("type", "") == "attack" and act == "Fighting": anim = "attack"
	elif act == "Performing ritual": anim = "ritual"
	elif act == "Picking berries": anim = "gather"
	elif act.begins_with("Building") or act.begins_with("Renovating") or act.begins_with("Experimenting"): anim = "build"
	elif busy: anim = "chop"
	elif walk: anim = "walk"
	if anim in ["chop", "build", "attack"] and (walk and anim != "attack"): anim = "walk"
	var frames: int = {"idle": 1, "walk": 8}.get(anim, 4)
	var speed := 11.0 if anim == "walk" else 7.0
	var name := "man_%s_%d_%d" % [anim, di, int(t * speed + u.id) % frames]
	if anim in ["chop", "build", "attack"] and sim.has_bronze() and art.has(name + "_bronze"): name += "_bronze"
	var k := 0.95
	_sprite(name, b, k)
	_sprite(name + "_cloth", b, k, u.color)
	var head := b - Vector2(0, 23.5 * k)
	var hip := b - Vector2(0, 10.0 * k)
	var f: float = facing.get(key, 1)
	if u.sick > 0:
		ci.draw_circle(head, 3.6, Color(0.55, 0.85, 0.35, 0.4))
		for i in 2:
			var kk := fmod(t * 0.8 + i * 0.5, 1.0)
			ci.draw_circle(head + Vector2(5 - i * 10, -5 - 12 * kk), 1.4, Color(0.6, 0.9, 0.4, 1.0 - kk))
	if u.title != "":
		ci.draw_colored_polygon(PackedVector2Array([head + Vector2(-3.5, -3), head + Vector2(-1, -9), head + Vector2(0, -3.5), head + Vector2(2, -10), head + Vector2(3.5, -3)]), Color("#e8c25a"))
	if u.carry_amt > 0:
		var bk := hip + Vector2(-5 * f, -6)
		if u.carry_type == "wood":
			ci.draw_line(bk + Vector2(-3, 3), bk + Vector2(3, -5), Color("#7a4e28"), 3)
			ci.draw_line(bk + Vector2(-1, 4), bk + Vector2(5, -3), Color("#8a5a32"), 3)
		elif u.carry_type == "stone":
			ci.draw_circle(bk, 3.5, Color("#9a968c"))
		else:
			ci.draw_circle(bk, 3.5, Color("#b03a2e"))
	if u.carry_amt > 0 and sim.has_tech("domestication") and u.job.get("type", "") == "gather":
		var behind: Vector2 = -heading.get(key, Vector2(0.6, 0.8)) * 18.0
		if not _beast_sprite("packox", key, b + behind, 0.8): _pack_ox(b + Vector2(-17 * f, 3), f, walk)
	if _has_torch(u):
		var th := hip + Vector2(-6 * f, -4)
		ci.draw_line(th, th + Vector2(-2 * f, -14), Color("#6b4524"), 2)
		_flame(th + Vector2(-2 * f, -14), 3, 9 * (1.0 + 0.2 * sin(t * 14 + u.id)), Color("#f8a531"))
	if u.job.get("type", "") == "ritual" and u.act == "Performing ritual":
		_ell_line(b - Vector2(0, 2), 15 + sin(t * 3) * 3, 7, Color(0.75, 0.6, 1.0, 0.6), 1.5)
		for i in 3:
			var kk := fmod(t * 0.7 + i / 3.0, 1.0)
			ci.draw_circle(b + Vector2(sin(t * 2 + i * 2) * 10, -10 - 30 * kk), 1.8, Color(0.8, 0.7, 1, 1 - kk))

## Stone before Polished Stone Tools is crude grey-brown; bronze once a smelter stands.
func _blade_col() -> Color:
	if sim.has_bronze(): return Color("#d49a3a")
	return Color("#8d8d93") if sim.has_tech("tools") else Color("#8a7458")

func _pack_ox(q: Vector2, f: float, walk: bool) -> void:
	_ell(q + Vector2(2, 1), 10, 3.5, SHADOW)
	for i in 4:
		var lx := q.x + (-6 + i * 4) * f
		ci.draw_line(Vector2(lx, q.y - 6), Vector2(lx + (sin(t * 12 + i) * 2.0 if walk else 0.0), q.y), Color("#2a1d10"), 1.5)
	_ell(q - Vector2(0, 9), 9, 5, Color("#4a3322"))
	ci.draw_circle(q + Vector2(9 * f, -11), 3.2, Color("#3d2a1c"))
	ci.draw_line(q + Vector2(9 * f, -14), q + Vector2(13 * f, -17), Color("#e8dcc0"), 1.3)
	ci.draw_rect(Rect2(q.x - 5, q.y - 18, 10, 5), Color("#8a5a32"))

func _draw_unit_overlay(u) -> void:
	if u.dead: return
	var b := iso(u.pos) * 1.0
	var sel: bool = u.id in selected
	var title: String = ("★ " if u.title != "" else "") + tr(u.name)
	_draw_label(b + Vector2(0, -46), title, 14, Color("#fff4d6") if not sel else Color("#ffe066"), true)
	if u.hp < u.max_hp - 0.5: _bar(b + Vector2(0, 6), 24, u.hp / u.max_hp, Color("#e05050") if u.hp < u.max_hp * 0.35 else Color("#6fd06f"))

func _draw_pred(p) -> void:
	var b := iso(p.pos)
	_scale_about(b, FIG_SCALE)
	if p.raid: _ell_line(b, 20, 8, Color(1, 0.3, 0.2, 0.7), 2)
	if p.clan != "":
		_draw_clansman(p, b)
		return
	if _beast_sprite(p.kind, "p%d" % p.id, b, 1.15 / FIG_SCALE): return
	if p.kind == "wolf":
		_draw_wolf(p)
		return
	var key := "p%d" % p.id
	var f: float = facing.get(key, 1)
	var walk: bool = moving.get(key, false)
	_ell(b + Vector2(3, 1), 18, 6, SHADOW)
	var body := b - Vector2(0, 13)
	for i in 4:
		var lx := body.x + (-10 + i * 6.5) * f
		var sw := sin(t * 13 + i * 1.9) * 3.5 if walk else 0.0
		ci.draw_line(Vector2(lx, body.y + 3), Vector2(lx + sw, b.y), Color("#b86f1f") if i % 2 == 0 else Color("#cf7f26"), 3.5)
	# tail
	var tb := body + Vector2(-13 * f, -1)
	ci.draw_line(tb, tb + Vector2(-8 * f, -6 + sin(t * 3) * 3), Color("#cf7f26"), 2.5)
	_ell(body, 15, 7, Color("#d98a2b"))
	_ell(body + Vector2(0, 3), 11, 3.5, Color("#f2d2a0"))
	for i in 4:
		var sx := body.x + (-9 + i * 5.5) * f
		ci.draw_line(Vector2(sx, body.y - 7), Vector2(sx - 2 * f, body.y + 1), Color("#3a2414"), 2)
	var head := body + Vector2(15 * f, -5)
	ci.draw_circle(head, 7, Color("#e39a35"))
	ci.draw_circle(head + Vector2(3 * f, 3), 4, Color("#f0c890"))
	ci.draw_circle(head + Vector2(-2 * f, -6), 2.5, Color("#c47a20"))
	ci.draw_circle(head + Vector2(2 * f, -2), 1.2, Color("#1a0f08"))
	ci.draw_line(head + Vector2(2 * f, 5), head + Vector2(3 * f, 13), Color.WHITE, 2)
	ci.draw_line(head + Vector2(5 * f, 5), head + Vector2(6 * f, 12), Color.WHITE, 2)

## A person of a rival clan: the villager sprites, clothes in the clan's colour,
## warriors with spears and red war paint, raiders carrying off a bundle of food.
func _draw_clansman(p, b: Vector2) -> void:
	var key := "p%d" % p.id
	var col: Color = sim.rivals.clans[p.clan]["color"]
	var walk: bool = moving.get(key, false)
	var war: bool = p.kind == "warrior"
	if p.kind == "trader": # a pack ox laden with goods walks behind
		var behind: Vector2 = -heading.get(key, Vector2(0.6, 0.8)) * 20.0
		if not _beast_sprite("packox", key, b + behind, 0.8): _pack_ox(b + Vector2(-17 * facing.get(key, 1.0), 3), facing.get(key, 1.0), walk)
	_ell(b + Vector2(2, 0), 9, 4, SHADOW)
	if art and art.has("man_idle_0_0"):
		var di := _dir_index(key)
		var anim := "idle"
		if attacking.has(key): anim = "attack"
		elif walk: anim = "walk"
		var frames: int = {"idle": 1, "walk": 8}.get(anim, 4)
		var name := "man_%s_%d_%d" % [anim, di, int(t * (11.0 if anim == "walk" else 7.0) + p.id) % frames]
		_sprite(name, b, 0.95, Color(0.86, 0.8, 0.76) if war else Color.WHITE)
		_sprite(name + "_cloth", b, 0.95, col.darkened(0.15) if war else col)
	else:
		ci.draw_line(b + Vector2(-2, -9), b + Vector2(-2, 0), Color("#a87a56"), 2.5)
		ci.draw_line(b + Vector2(2, -9), b + Vector2(2, 0), Color("#a87a56"), 2.5)
		ci.draw_colored_polygon(PackedVector2Array([b + Vector2(-5, -7), b + Vector2(5, -7), b + Vector2(4, -20), b + Vector2(-4, -20)]), col)
		ci.draw_circle(b + Vector2(0, -24), 4.5, Color("#c99a70"))
	var head := b - Vector2(0, 23.5 * 0.95)
	var f: float = facing.get(key, 1)
	if war: # feathered war crest in the clan colour
		ci.draw_colored_polygon(PackedVector2Array([head + Vector2(-2, -3), head + Vector2(0, -12), head + Vector2(2, -3)]), col.lightened(0.25))
		if not attacking.has(key): # spear held upright on the march
			var hand := b + Vector2(6 * f, -14)
			ci.draw_line(hand + Vector2(0, 10), hand + Vector2(0, -22), Color("#8a6a42"), 1.6)
			ci.draw_colored_polygon(PackedVector2Array([hand + Vector2(-2, -22), hand + Vector2(2, -22), hand + Vector2(0, -29)]), Color("#8d8d93"))
	elif p.kind == "trader": # a bundle of goods on the back
		var pk := b + Vector2(-5 * f, -17)
		ci.draw_rect(Rect2(pk - Vector2(4, 5), Vector2(8, 9)), Color("#9a7448"))
		ci.draw_line(pk + Vector2(-4, -1), pk + Vector2(4, -1), Color("#5a3d22"), 1.2)
	else: # hunter: bow over the shoulder
		ci.draw_arc(b + Vector2(-4 * f, -16), 8, -PI * 0.5 - 0.9, -PI * 0.5 + 0.9, 8, Color("#6b4524"), 1.4)
	if p.loot:
		var bk := b + Vector2(-5 * f, -16)
		ci.draw_circle(bk, 4.5, Color("#8a5a32"))
		ci.draw_circle(bk + Vector2(1, -1), 2.5, Color("#b03a2e"))

func _draw_guardian(g) -> void:
	var lift := 52.0 + sin(t * 2) * 6
	var b := iso(g.pos)
	_ell(b, 22, 8, Color(0, 0, 0, 0.22))
	for i in range(guardian_trail.size() - 1, -1, -3):
		var k := 1.0 - float(i) / guardian_trail.size()
		ci.draw_circle(iso(guardian_trail[i]) - Vector2(0, lift), 3 + 8 * k, Color(0.4, 0.95, 0.8, 0.2 + 0.45 * k))
	var c := b - Vector2(0, lift)
	if art != null and art.has("dragon_0_0"):
		_sprite("dragon_%d_%d" % [_dir_index("g"), int(t * 6.0) % 4], c, 1.3)
		_draw_label(c + Vector2(0, -34), tr("Yinglong"), 13, Color("#9ff0d0"), true)
		return
	var flap := sin(t * 6) * 10
	ci.draw_colored_polygon(PackedVector2Array([c + Vector2(-4, -2), c + Vector2(-32, -16 - flap), c + Vector2(-22, 4)]), Color("#3fbfa0"))
	ci.draw_colored_polygon(PackedVector2Array([c + Vector2(4, -2), c + Vector2(32, -16 - flap), c + Vector2(22, 4)]), Color("#38ad91"))
	_ell(c, 14, 9, Color("#5fe0c0"))
	ci.draw_circle(c + Vector2(12, -6), 6, Color("#6ff0d0"))
	ci.draw_circle(c + Vector2(14, -7), 1.6, Color.WHITE)
	_draw_label(c + Vector2(0, -26), tr("Yinglong"), 13, Color("#9ff0d0"), true)

func _draw_label(p: Vector2, text: String, size: int, col: Color, outline := false) -> void:
	var w := 400.0
	if outline: ci.draw_string_outline(font, p - Vector2(w / 2, 0), text, HORIZONTAL_ALIGNMENT_CENTER, w, size, 4, Color(0, 0, 0, col.a * 0.8))
	ci.draw_string(font, p - Vector2(w / 2, 0), text, HORIZONTAL_ALIGNMENT_CENTER, w, size, col)

func _bar(p: Vector2, w: float, frac: float, col: Color) -> void:
	ci.draw_rect(Rect2(p.x - w / 2, p.y, w, 4), Color(0, 0, 0, 0.6))
	ci.draw_rect(Rect2(p.x - w / 2, p.y, w * clampf(frac, 0, 1), 4), col)

# ------------------------------------------------------------ input (Tier 1 direct micro)
## True when the cursor is over HUD / dialog UI (or a modal is open): scroll, pinch
## and swipe then belong to the UI and must never leak through to the map.
func _ui_has_pointer() -> bool:
	if blocked.is_valid() and blocked.call(): return true
	return get_viewport().gui_get_hovered_control() != null

func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventGesture and _ui_has_pointer(): return
	if ev is InputEventMouseButton and (ev as InputEventMouseButton).button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT] and _ui_has_pointer(): return
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		var sm := get_global_mouse_position() # screen-space (iso)
		var m := uniso(sm) # world-space
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if build_type != "":
					_place(m)
				else:
					drag_start = sm
			elif drag_start != null:
				if (drag_start as Vector2).distance_to(sm) < 6 / cam.zoom.x: _click_select(sm, mb.shift_pressed)
				else: _box_select(Rect2(drag_start, sm - drag_start).abs(), mb.shift_pressed)
				drag_start = null
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if build_type != "": build_type = ""
			else: _command(sm)
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			mid_drag = mb.pressed
		elif mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			_zoom_by(1.1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1 / 1.1)
	elif ev is InputEventPanGesture: # trackpad two-finger swipe (macOS) -> pan
		cam.position += (ev as InputEventPanGesture).delta * PAN_GESTURE_SPEED / cam.zoom.x
		_clamp_cam()
	elif ev is InputEventMagnifyGesture: # trackpad pinch -> zoom
		_zoom_by((ev as InputEventMagnifyGesture).factor)
	elif ev is InputEventMouseMotion and mid_drag:
		cam.position -= (ev as InputEventMouseMotion).relative / cam.zoom.x
		_clamp_cam()

func selected_units() -> Array:
	return selected.map(func(id): return sim.unit_by_id(id)).filter(func(u): return u != null and not u.dead)

func select_only(u) -> void:
	selected = [u.id] if u else []
	selection_changed.emit()

## p is a world-space point.
func focus_on(p: Vector2) -> void:
	cam.position = iso(p)
	_clamp_cam()

## Screen-space distance from the cursor to an upright figure (base or body).
func _pick_dist(sm: Vector2, world_pos: Vector2, height: float) -> float:
	var b := iso(world_pos)
	return minf(sm.distance_to(b), minf(sm.distance_to(b - Vector2(0, height * 0.5)), sm.distance_to(b - Vector2(0, height))))

func _click_select(sm: Vector2, add: bool) -> void:
	var best = null
	var bd := 16.0
	for u in sim.units:
		if u.dead: continue
		var d := _pick_dist(sm, u.pos, 34)
		if d < bd:
			bd = d
			best = u
	if not add: selected = []
	if best:
		if best.id in selected: selected.erase(best.id)
		else: selected.append(best.id)
	selection_changed.emit()

func _box_select(r: Rect2, add: bool) -> void:
	if not add: selected = []
	for u in sim.units:
		if not u.dead and r.has_point(iso(u.pos) - Vector2(0, 15)) and u.id not in selected: selected.append(u.id)
	selection_changed.emit()

## Send the selected (non-contract) people to auto-explore.
func scout_selected() -> void:
	var n := 0
	for u in selected_units():
		if u.role == "contract": continue
		sim.assign_explore(u)
		n += 1
	if n > 0:
		sim.add_log(tr("%d scout%s set out to explore the unknown.") % [n, "" if n == 1 else I.plural_s()], "story")
		selection_changed.emit()

## Right-click command at a world point (used by the minimap).
func command_at(world_pos: Vector2) -> void:
	_command(iso(world_pos))

func _place(m: Vector2) -> void:
	var s = sim.place_structure(build_type, m)
	if s == null:
		sim.popup(m, tr(sim.can_place(build_type, m)), Color("#ff8080"))
		return
	for u in selected_units():
		if u.role != "contract": sim.assign_build(u, s)
	if not Input.is_key_pressed(KEY_SHIFT): build_type = ""

func _command(sm: Vector2) -> void:
	var m := uniso(sm)
	var units := selected_units()
	if units.is_empty(): return
	var free: Array = units.filter(func(u): return u.role != "contract")
	if free.size() < units.size():
		sim.popup(m, tr("Contract crews follow their blueprint"), Color("#9fd0ff"))
	if free.is_empty(): return
	cmd_marker = {"p": m, "t": t, "c": Color("#ffe066")}
	for p in sim.predators:
		if not p.dead and not p.fled and sim.is_visible(p.pos) and _pick_dist(sm, p.pos, 28) < 24:
			for u in free: sim.assign_attack(u, p)
			cmd_marker["c"] = Color("#ff6b6b")
			return
	var node = null
	var bd := 20.0
	for n in sim.nodes:
		if n.amount < 1 or n.kind == "stump": continue
		if not (sim.is_visible(n.pos) if n.kind == "deer" else sim.is_explored(n.pos)): continue
		var d := _pick_dist(sm, n.pos, 40.0 if n.kind == "tree" else 12.0)
		if d < bd:
			bd = d
			node = n
	if node:
		for u in free: sim.assign_gather(u, node.res, {"node_id": node.id, "bank": D.bank_of(node.pos)})
		return
	for s in sim.structures:
		var r: float = D.STRUCTURES[s.type]["r"]
		var hit: bool = absf(s.pos.distance_to(m) - r) < 16 if D.STRUCTURES[s.type].get("ring", false) else s.pos.distance_to(m) < r + 12
		if not s.built and hit:
			for u in free: sim.assign_build(u, s)
			cmd_marker["c"] = Color("#b6f28a")
			return
	var i := 0
	for u in free:
		var off := Vector2.ZERO if i == 0 else Vector2.from_angle(i * 2.4) * (14 + 5 * i)
		sim.assign_move(u, m + off)
		i += 1

# ------------------------------------------------------------ cached, y-sorted canvas items
## Every upright thing is its own canvas item, positioned at its iso base so Godot's
## y-sort gives the painter's order. Godot caches each item's draw commands, so static
## things (trees, huts, posts, grass) cost nothing per frame; only moving or animated
## items are redrawn. Items draw in absolute iso coordinates (offset by -position).
class Item extends Node2D:
	var wv
	var kind := 0
	var obj
	var sig := -1
	var dynamic := false
	func _draw() -> void:
		wv.ci = self
		draw_set_transform(-position)
		wv.draw_item(kind, obj)
		wv.ci = wv

class Ground extends Node2D:
	var wv
	func _draw() -> void:
		wv.ci = self
		wv.draw_terrain()
		wv.ci = wv

class GroundFX extends Node2D:
	var wv
	func _draw() -> void:
		wv.ci = self
		wv.draw_ground_fx()
		wv.ci = wv

class Glow extends Node2D:
	var wv
	func _draw() -> void:
		wv.ci = self
		wv.draw_glow()
		wv.ci = wv

class Overlay extends Node2D:
	var wv
	func _draw() -> void:
		wv.ci = self
		wv.draw_overlay()
		wv.ci = wv

func draw_item(kind: int, obj) -> void:
	match kind:
		0: _draw_node(obj)
		1: _draw_structure(obj)
		2: _draw_unit(obj)
		3: _draw_pred(obj)
		4: _draw_guardian(obj)
		5: _draw_post(iso(obj[0]), obj[1], obj[2], obj[3])
		6: _draw_landmark(obj)
		7:
			for d in obj: _draw_decor(d)
		8:
			_sprite("outcrop_%d%s" % [obj["v"], _snowy()], iso(obj["p"]))

func _item(key: String, kind: int, obj, pos: Vector2, dynamic: bool, parent: Node2D = null) -> Item:
	var it: Item = items.get(key)
	if it == null:
		it = Item.new()
		it.wv = self
		it.kind = kind
		it.dynamic = dynamic
		(parent if parent else objects).add_child(it)
		items[key] = it
	it.obj = obj
	if it.position != pos: it.position = pos
	return it

## Grass, flowers and rocks never change: bake them into a grid of static chunks.
func _build_decor_chunks() -> void:
	var chunks := {}
	for d in decor:
		var k := Vector2i(int(d["p"].x / 600), int(d["p"].y / 600))
		if not chunks.has(k): chunks[k] = []
		chunks[k].append(d)
	for k in chunks:
		_item("d%d_%d" % [k.x, k.y], 7, chunks[k], Vector2.ZERO, false, decor_root)

func _sync_items() -> void:
	var seen := {}
	var snow_sig := 1 if sim.hz.snow > 0.5 else 0
	for key in items:
		if key.begins_with("d"): _touch(items[key], snow_sig)
	for i in outcrops.size():
		var o: Dictionary = outcrops[i]
		var key := "o%d" % i
		seen[key] = true
		var it := _item(key, 8, o, iso(o["p"]), false)
		it.visible = sim.is_explored(o["p"])
		_touch(it, snow_sig)
	for n in sim.nodes:
		var key := "n%d" % n.id
		seen[key] = true
		var it := _item(key, 0, n, iso(n.pos), n.kind == "deer")
		it.visible = sim.is_visible(n.pos) if n.kind == "deer" else sim.is_explored(n.pos)
		_touch(it, n.kind.length() * 1000 + int(n.amount / 5) + (100000 if sim.hz.snow > 0.5 else 0))
	for lm in sim.landmarks:
		var key: String = "lm_" + lm["id"]
		seen[key] = true
		var it := _item(key, 6, lm, iso(lm["pos"]), lm["kind"] in ["den", "stones", "peak", "spring"])
		it.visible = sim.is_explored(lm["pos"])
		_touch(it, 0)
	for st in sim.structures:
		var exp: bool = sim.is_explored(st.pos)
		if st.type == "palisade":
			var r: float = D.STRUCTURES["palisade"]["r"]
			var cnt := 64
			var shown: int = cnt if st.built else int(cnt * st.progress / st.work)
			for i in cnt:
				var pp: Vector2 = st.pos + Vector2.from_angle(float(i) / cnt * TAU) * r
				var key := "s%d_%d" % [st.id, i]
				seen[key] = true
				var it := _item(key, 5, [pp, i < shown, st.built, st.style], iso(pp), false)
				it.visible = exp
				_touch(it, (2 if i < shown else 0) + (1 if st.built else 0) + st.style * 10)
		elif st.type != "farm_plot" or (st.built and art != null and art.has("farm_spring")):
			var key := "s%d" % st.id
			seen[key] = true
			var anim: bool = st.type in ["bonfire", "fishing_dock", "aurochs_pen", "smelter", "council_ring"] or not st.built or st.reno \
				or (st.type in ["hut", "large_hut"] and sim.has_tech("fire"))
			var it := _item(key, 1, st, iso(st.pos), anim)
			if it.dynamic != anim: it.dynamic = anim
			it.visible = exp
			_touch(it, (1 if st.built else 0) + st.style * 10 + (sim.hz.season_idx() * 100 if st.type == "farm_plot" else 0) + (1000 if sim.hz.snow > 0.5 else 0))
	for u in sim.units:
		var key := "u%d" % u.id
		seen[key] = true
		_touch(_item(key, 2, u, iso(u.pos), true), 0)
	for p in sim.predators:
		var key := "p%d" % p.id
		seen[key] = true
		var it := _item(key, 3, p, iso(p.pos), true)
		it.visible = not p.dead and not p.fled and sim.is_visible(p.pos)
		_touch(it, 0)
	if sim.guardian and not sim.guardian.dead:
		seen["g"] = true
		_touch(_item("g", 4, sim.guardian, iso(sim.guardian.pos) + Vector2(0, 80), true), 0)
	for key in items.keys():
		if key.begins_with("d"): continue
		if not seen.has(key):
			items[key].queue_free()
			items.erase(key)

func _touch(it: Item, sig: int) -> void:
	if it.dynamic:
		if it.visible: it.queue_redraw()
	elif it.sig != sig:
		it.sig = sig
		it.queue_redraw()
