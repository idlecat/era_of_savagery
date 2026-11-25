## 2.5D isometric renderer (Age-of-Empires-style diamond map) + Tier 1 RTS input.
## The simulation stays in flat world coordinates; only drawing and picking are
## projected: ground features are drawn through an isometric transform, upright
## objects (trees, huts, people, beasts) are drawn in screen space at iso(pos) and
## depth-sorted by x+y so nearer things overlap farther ones.
extends Node2D

const D = preload("res://scripts/data.gd")
const E = preload("res://scripts/entities.gd")
const I = preload("res://scripts/i18n.gd")

signal selection_changed()
signal structure_clicked(s) # a click on a building with something to show (the burial ground)

const IX := 0.75   # iso projection: screen = ((x-y)*IX, (x+y)*IY), 2:1 diamond
const IY := 0.375
const GROUND := Transform2D(Vector2(IX, IY), Vector2(-IX, IY), Vector2.ZERO)
var TEX_SCALE := 4 # terrain texture = world / TEX_SCALE pixels (coarser on the biggest maps)

var sim
var art # ArtBaker (pre-rendered 3D sprites); old procedural drawing is the fallback
var heading := {} # "u12" -> last screen-space movement direction
var attacking := {} # predator keys currently biting someone (attack animation)
var sprite_dirs: Array = [] # screen direction each of the 8 baked facings looks along
var selected: Array = [] # unit ids
const PALISADE_GAP := 8.0 # clearance between a wall's stakes and a building on its line
var selected_struct := -1 # a building picked for the building panel (units unselected)
var hover_unit := -1 # unit under the cursor: a faint white ring invites a click
var hover_struct := -1 # building under the cursor, likewise
var zoom_target := 1.25 # eased zoom: _zoom_by moves the target, _zoom_step glides there
var zoom_last := 1.25 # the zoom _zoom_step last set: anything else was set from outside
var build_type := ""
var build_size := 0.0 # radius for a wall being laid out
var road_start: Variant = null # the Road tool: where the road begins, once clicked
var wall_center: Variant = null # a wall's middle, once picked: the cursor then sets its radius
const WALL_DRAG := 12.0 # (screen px) a press moved this far before release lays the wall out on release
var drag_start: Variant = null # screen-space
var mid_drag := false
var cam: Camera2D
var night: CanvasModulate
var grade_mat: ShaderMaterial # full-screen seasonal colour grade (grade.gdshader)
var grade_sat := 1.0
var grade_con := 1.0
var lights := {} # structure id -> PointLight2D
var light_tex: GradientTexture2D
var font: Font
var terrain_tex: ImageTexture
var minimap_tex: ImageTexture
var fog_tex: ImageTexture
var fog_img: Image
var fog_refresh := 0.0
var wear_tex: ImageTexture
var mask_tex: ImageTexture # where the soil, forest floor and meadows are (terrain.gdshader)
var photo_ground := false # CC0 ground textures loaded (assets/textures/terrain): paths are painted by the shader
const GROUND_TEX := ["grass", "grass2", "meadow", "dry", "dirt", "forest", "road_packed", "road_stone"]
var wear_img: Image
var wear_refresh := 0.0
var view := Rect2() # visible canvas rect (iso space) for culling
var clean := false # pictures (the HUD's achievement snapshots): no labels, bars, rings or popups
var decor: Array = []
var river_banks: Array = [] # per river: [left bank, right bank] polylines
var cmd_marker := {}
var guardian_trail: Array = []
var facing := {} # "u12" -> 1 / -1  (screen-space left/right)
var last_pos := {}
var moving := {}
var t := 0.0
var anim_t := 0.0 # clock for people's and beasts' motions: stops while the game is paused, slows in emergencies
var ci: CanvasItem # canvas currently being drawn (world, an Item, or the Overlay)
var ghost_m := Vector2.ZERO
var ghost_why := ""
var decor_root: Node2D
var ground: Node2D
var ground_fx: Node2D
var objects: Node2D # y-sorted container: iso y == depth (x + y)
var overlay: Node2D
var ghost: Node2D # the building being placed, drawn as itself (green: it fits, red: it doesn't)
var _ghost_s = null # (a stand-in structure for it)
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
	zoom_target = 1.25
	zoom_last = 1.25
	cam.position = iso(D.VILLAGE + Vector2(240, 0))
	add_child(cam)
	cam.make_current()
	night = CanvasModulate.new()
	add_child(night)
	var grade_layer := CanvasLayer.new() # seasonal colour grade, under the vignette and the HUD
	grade_layer.layer = 4
	var grade_rect := ColorRect.new()
	grade_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	grade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grade_mat = ShaderMaterial.new()
	grade_mat.shader = load("res://shaders/grade.gdshader")
	grade_rect.material = grade_mat
	grade_layer.add_child(grade_rect)
	add_child(grade_layer)
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
	_ground_photos(gm)
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
	ghost = Ghost.new() # above the world, below fog and labels
	ghost.wv = self
	add_child(ghost)
	overlay = Overlay.new()
	overlay.wv = self
	add_child(overlay)
	_build_decor_chunks()

# ------------------------------------------------------------ terrain bake
func _build_terrain() -> void:
	river_banks = []
	for pts in D.RIVERS: river_banks.append([_offset_line(pts, -D.RIVER_HALF), _offset_line(pts, D.RIVER_HALF)])
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
	TEX_SCALE = 4 if D.area_k() <= 1.05 else (5 if D.area_k() <= 1.6 else 6)
	var w := int(D.W / TEX_SCALE)
	var h := int(D.H / TEX_SCALE)
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var mask := Image.create(w, h, false, Image.FORMAT_RGB8) # soil, forest floor, meadow (terrain.gdshader)
	var g_west_a := Color("#6f8e3f")
	var g_west_b := Color("#56763a")
	var g_east_a := Color("#4d6a34")
	var g_east_b := Color("#3a5229")
	# the land's moisture (config/lands.json): a steppe's grass is dry and yellow, an old forest's dark and lush
	var moist := float(D.LAND.get("moisture", 0.5))
	var dry_k := clampf((0.5 - moist) * 2.0, 0.0, 1.0)
	var wet_k := clampf((moist - 0.5) * 2.0, 0.0, 1.0)
	var gs: Array = [g_west_a, g_west_b, g_east_a, g_east_b].map(func(c0): return c0.lerp(Color("#9a9a52"), dry_k * 0.55).lerp(Color("#3c6a2c"), wet_k * 0.35))
	g_west_a = gs[0]
	g_west_b = gs[1]
	g_east_a = gs[2]
	g_east_b = gs[3]
	var dirt := Color("#8c7650")
	var sand := Color("#b09c6c")
	var deep := Color("#2b5878")
	var shallow := Color("#4b8aa4")
	var ford := Color("#7fa3a0")
	var water := _water_field(w, h, D.RIVER_HALF + 60.0) # distance to the nearest river per pixel
	for j in h:
		for i in w:
			var p := Vector2(i * TEX_SCALE + 1.5, j * TEX_SCALE + 1.5)
			var n := noise.get_noise_2dv(p) * 0.5 + 0.5
			var f := fine.get_noise_2dv(p) * 0.5 + 0.5
			var dx: float = water[j * w + i]
			var c: Color
			if dx < D.RIVER_HALF:
				var k := dx / D.RIVER_HALF
				c = deep.lerp(shallow, k * k)
				c.a = 0.08 + 0.3 * k
				if D.is_ford_at(p):
					c = ford.lerp(shallow, 0.3 * k).lerp(Color("#9a9682"), 0.35 * f)
					c.a = 0.4
			elif dx < D.RIVER_HALF + 12 + 8 * n:
				c = sand.lerp(Color("#8f8058"), f * 0.6)
				c.a = 0.56
			else:
				var east := not D.home_side(p) # untamed land beyond the water is darker
				c = (g_east_a.lerp(g_east_b, n) if east else g_west_a.lerp(g_west_b, n))
				c = c.lerp(c.darkened(0.18), f * 0.5)
				var dv := p.distance_to(D.VILLAGE)
				var mk := Color(0, 0, 0)
				if dv < 170:
					var k_dirt := clampf((170 - dv) / 110.0, 0, 0.85) * (0.6 + 0.4 * n)
					c = c.lerp(dirt.lerp(dirt.darkened(0.15), f), k_dirt)
					mk.r = k_dirt
				var m := meadow.get_noise_2dv(p) * 0.5 + 0.5
				var so := soil.get_noise_2dv(p) * 0.5 + 0.5
				var fd := _forest_at(p)
				if not east and m > 0.62:
					c = c.lerp(Color("#93a64e"), clampf((m - 0.62) * 3.0, 0, 0.6))
					mk.b = clampf((m - 0.62) * 3.0, 0, 1)
				if so > 0.7:
					c = c.lerp(Color("#7d6a48").lerp(Color("#6a5c40"), f), clampf((so - 0.7) * 4.0, 0, 0.75))
					mk.r = maxf(mk.r, clampf((so - 0.7) * 4.0, 0, 0.75))
				elif so < 0.22: c = c.lerp(Color("#7a7466").lerp(Color("#8a857a"), f), clampf((0.22 - so) * 4.0, 0, 0.6))
				if fd > 0.05:
					c = c.lerp(Color("#3d4a28").lerp(Color("#4a4026"), f), clampf(fd * 0.8, 0, 0.7)) # forest floor and leaf litter
					mk.g = clampf(fd * 0.9, 0, 1)
				mask.set_pixel(i, j, mk)
				if dx < D.RIVER_HALF + 50: c = c.lerp(Color("#4f6a32"), clampf((D.RIVER_HALF + 50 - dx) / 40.0, 0, 0.5)) # lush riverbank
			img.set_pixel(i, j, c)
	terrain_tex = ImageTexture.create_from_image(img)
	mask_tex = ImageTexture.create_from_image(mask)
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

## A river centreline shifted sideways by `off` (negative = left of the flow).
func _offset_line(pts: PackedVector2Array, off: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for k in pts.size():
		var tg := (pts[mini(k + 1, pts.size() - 1)] - pts[maxi(k - 1, 0)]).normalized()
		out.append(pts[k] + Vector2(-tg.y, tg.x) * off)
	return out

## Distance to the nearest river centreline for each terrain pixel (up to `reach`, else INF):
## each river segment stamps the pixels around it, much cheaper than asking per pixel.
func _water_field(w: int, h: int, reach: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(w * h)
	out.fill(INF)
	var sc := float(TEX_SCALE)
	for pts in D.RIVERS:
		for k in pts.size() - 1:
			var a: Vector2 = pts[k]
			var b: Vector2 = pts[k + 1]
			var x0 := maxi(0, int((minf(a.x, b.x) - reach) / sc))
			var x1 := mini(w - 1, int((maxf(a.x, b.x) + reach) / sc))
			var y0 := maxi(0, int((minf(a.y, b.y) - reach) / sc))
			var y1 := mini(h - 1, int((maxf(a.y, b.y) + reach) / sc))
			var ab := b - a
			var l2 := maxf(ab.length_squared(), 0.0001)
			for j in range(y0, y1 + 1):
				for i in range(x0, x1 + 1):
					var p := Vector2(i * sc + 1.5, j * sc + 1.5)
					var d := p.distance_to(a + ab * clampf((p - a).dot(ab) / l2, 0.0, 1.0))
					if d < out[j * w + i]: out[j * w + i] = d
	return out

# ------------------------------------------------------------ frame
func _process(delta: float) -> void:
	t += delta
	if not sim.paused and not (blocked.is_valid() and blocked.call()): anim_t += delta * sim.crisis.slow()
	_pan_keys(delta)
	if sim.nat.shake > 0: # a hard jolt: the ground jumps
		cam.offset = Vector2(randf_range(-1, 1), randf_range(-1, 1)) * 7.0 * minf(1.0, sim.nat.shake)
	elif sim.crisis.on: # an emergency: a slow uneasy sway
		cam.offset = Vector2(sin(t * 0.7), cos(t * 0.9)) * 2.5
	else:
		cam.offset = Vector2.ZERO
	night.color = _sky_tint()
	_grade_step(delta)
	_wet_step(delta)
	_zoom_step(delta)
	_update_hover()
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
	ghost.queue_redraw()
	for u in sim.units:
		var uk := "u%d" % u.id
		_track(uk, u.pos)
		if u.face != null and not moving.get(uk, false): # standing and looking at something (life.gd)
			var dv: Vector2 = iso(u.face) - iso(u.pos)
			if dv.length() > 2.0:
				heading[uk] = dv.normalized()
				facing[uk] = 1 if dv.x > 0 else -1
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
	for pts in D.RIVERS: # reeds along both banks, but not at the fords
		var k := 0
		while k < pts.size() - 1:
			var c: Vector2 = pts[k]
			var tg: Vector2 = (pts[k + 1] - c).normalized()
			k += 1 if randf() < 0.6 else 0
			c += tg * randf_range(0, 30)
			if c.x < 0 or c.y < 0 or c.x > D.W or c.y > D.H: continue
			if D.FORDS.any(func(f): return f["p"].distance_to(c) < D.FORD_LEN + 40.0): continue
			for side in [-1, 1]:
				if randf() < 0.75:
					var p: Vector2 = c + Vector2(-tg.y, tg.x) * side * (D.RIVER_HALF + randf_range(2, 22))
					decor.append({"p": p, "kind": "reeds", "v": randi() % 2, "s": randf_range(0.8, 1.2), "east": not D.home_side(p), "tall": false, "c": 0.0})
	for i in int(2600 * D.W * D.H / (3600.0 * 2400.0)):
		var p := Vector2(randf() * D.W, randf() * D.H)
		if D.river_dist(p) < D.RIVER_HALF + 14: continue
		var east := not D.home_side(p)
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
	var n_out := roundi(36 * D.area_k())
	while outcrops.size() < n_out and tries < n_out * 25:
		tries += 1
		var p := Vector2(randf_range(150, D.W - 150), randf_range(150, D.H - 150))
		if p.distance_to(D.VILLAGE) < 700 or D.SITES.any(func(s): return p.distance_to(s) < 450) or D.river_dist(p) < 250: continue
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

## The photographic ground (CC0, assets/textures/terrain): each texture with mipmaps (for
## any zoom) and its mean colour (the shader tints it toward the map's own colours). Without
## them the shader paints the old procedural ground.
func _ground_photos(gm: ShaderMaterial) -> void:
	gm.set_shader_parameter("mask_tex", mask_tex)
	gm.set_shader_parameter("wear_tex", wear_tex)
	gm.set_shader_parameter("wear_size", Vector2(maxi(sim.wear_w, 1) * sim.WEAR_CELL, maxi(sim.wear_h, 1) * sim.WEAR_CELL))
	gm.set_shader_parameter("cell_size", sim.WEAR_CELL)
	photo_ground = true
	for k in GROUND_TEX:
		var path := "res://assets/textures/terrain/%s.jpg" % k
		var t = load(path) if ResourceLoader.exists(path) else null
		if t == null:
			photo_ground = false
			break
		var img: Image = t.get_image()
		if img.is_compressed(): img.decompress()
		img.convert(Image.FORMAT_RGB8)
		var small := img.duplicate()
		small.resize(1, 1, Image.INTERPOLATE_BILINEAR)
		var mean: Color = small.get_pixel(0, 0)
		img.generate_mipmaps()
		gm.set_shader_parameter("t_" + k, ImageTexture.create_from_image(img))
		gm.set_shader_parameter("m_" + k, Vector3(mean.r, mean.g, mean.b))
	gm.set_shader_parameter("use_photo", 1.0 if photo_ground else 0.0)
	gm.set_shader_parameter("dryness", clampf((0.5 - float(D.LAND.get("moisture", 0.5))) * 2.0, 0.0, 1.0))

## Worn paths: foot traffic tints the grass toward bare earth.
func _refresh_wear() -> void:
	var n: int = sim.wear_w * sim.wear_h
	if n == 0: return
	var data := PackedByteArray()
	data.resize(n * 4)
	var lv: PackedByteArray = sim.roads.level
	var has_roads: bool = photo_ground and lv.size() == n
	for k in n:
		var w: float = sim.wear[k]
		var look: int = int(sim.roads.def_of(lv[k]).get("look", 0)) if has_roads and lv[k] > 0 else 0
		data[k * 4] = look * 80 if photo_ground else 120 # (the photo ground reads the road's look from red)
		data[k * 4 + 1] = 98
		data[k * 4 + 2] = 66
		data[k * 4 + 3] = int(clampf(maxf((w - 0.12) * 1.1, 0.5 if look == 1 else 0.0), 0.0, 0.62) * 255)
	wear_img.set_data(sim.wear_w, sim.wear_h, false, Image.FORMAT_RGBA8, data)
	wear_tex.update(wear_img)

## How far into a part of the day it is, 0..1 (a part may wrap past midnight).
func _part_k(name: String) -> float:
	var w: Array = sim.day_part(name)
	var a := float(w[0])
	var span := fposmod(float(w[1]) - a, 1.0)
	return clampf(fposmod(sim.day_frac() - a, 1.0) / maxf(span, 0.001), 0.0, 1.0)

## Time-of-day colour grading: warm golden dusk, blue night, pink dawn; seasons and
## weather lay a mood over the whole day (fresh spring, amber autumn, gray storms).
func _sky_tint() -> Color:
	var c := Color.WHITE
	if sim.is_day_part("dusk"): c = Color.WHITE.lerp(Color(1.0, 0.88, 0.74), sin(_part_k("dusk") * PI))
	elif sim.is_day_part("dawn"): c = Color.WHITE.lerp(Color(1.0, 0.78, 0.82), sin(_part_k("dawn") * PI) * 0.8)
	if sim.hz.on():
		match sim.hz.season_idx():
			0: c = c.lerp(Color(0.92, 1.0, 0.90), 0.16) # spring: faint fresh green
			2: c = c.lerp(Color(1.0, 0.90, 0.76), 0.14) # autumn: amber
		c = c.lerp(Color(0.86, 0.91, 1.0), sim.hz.snow * 0.4) # snow cover cools the light
	match sim.hz.weather:
		"rain": c = c.lerp(Color(0.80, 0.83, 0.88), 0.35)
		"storm": c = c.lerp(Color(0.68, 0.71, 0.78), 0.5)
		"blizzard": c = c.lerp(Color(0.82, 0.86, 0.94), 0.45)
		"drought": c = c.lerp(Color(1.0, 0.93, 0.78), 0.25)
		"late_frost": c = c.lerp(Color(0.86, 0.92, 1.0), 0.3) # (a hard white morning)
		"blight": c = c.lerp(Color(0.92, 0.90, 0.74), 0.2) # (a sickly yellow over the fields)
	return c.lerp(Color(0.30, 0.34, 0.55), sim.night_amt * 0.85)

## Ease the full-screen grade toward the season's and weather's mood; slow enough
## that a change of weather feels like the sky turning, not a filter switching.
func _grade_step(delta: float) -> void:
	var sat := 1.05
	var con := 1.03
	if sim.hz.on():
		match sim.hz.season_idx():
			0:
				sat = 1.08
				con = 1.02
			1:
				sat = 1.10
				con = 1.05
			2:
				sat = 1.09
				con = 1.05
			3:
				sat = 0.88
				con = 1.02
	match sim.hz.weather:
		"rain":
			sat -= 0.15
		"storm":
			sat -= 0.25
			con -= 0.03
		"blizzard":
			sat -= 0.2
	sat -= sim.night_amt * 0.12
	var k := minf(1.0, delta * 0.5)
	grade_sat = lerpf(grade_sat, sat, k)
	grade_con = lerpf(grade_con, con, k)
	grade_mat.set_shader_parameter("saturation", grade_sat)
	grade_mat.set_shader_parameter("contrast", grade_con)

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
	if k and k.keycode == KEY_ALT: alt_held = k.pressed # (Alt held: every name)

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		pan_held.clear()
		alt_held = false

const PAN_SPEED := 800.0
var pan_vel := Vector2.ZERO # the camera's actual pan velocity, eased toward the input
var cam_tween: Tween # a focus_on glide; user input cancels it

func _pan_keys(delta: float) -> void:
	var v := _pan_input()
	if v != Vector2.ZERO and cam_tween:
		cam_tween.kill() # a nudge takes over from any glide
		cam_tween = null
	# the camera gathers speed while held and glides to a stop when released
	pan_vel = pan_vel.lerp(v * PAN_SPEED / cam.zoom.x, minf(1.0, delta * 8.0))
	if pan_vel.length_squared() > 1.0:
		cam.position += pan_vel * delta
		cam.position = _clamp_target(cam.position)

## Any other camera move (minimap, drag, swipe, zoom) stops a focus glide and the
## leftover pan drift, so the camera stays where it was put.
func cancel_glide() -> void:
	if cam_tween:
		cam_tween.kill()
		cam_tween = null
	pan_vel = Vector2.ZERO

func _pan_input() -> Vector2:
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or focus is SpinBox:
		pan_held.clear()
		return Vector2.ZERO
	if blocked.is_valid() and blocked.call(): # map is frozen behind dialogs
		pan_held.clear()
		return Vector2.ZERO
	var v := Vector2.ZERO
	if pan_held.has(KEY_A) or pan_held.has(KEY_LEFT): v.x -= 1
	if pan_held.has(KEY_D) or pan_held.has(KEY_RIGHT): v.x += 1
	if pan_held.has(KEY_W) or pan_held.has(KEY_UP): v.y -= 1
	if pan_held.has(KEY_S) or pan_held.has(KEY_DOWN): v.y += 1
	v += _edge_dir()
	return v.normalized() if v != Vector2.ZERO else Vector2.ZERO

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

## Zoom by factor k: the target glides there over a few frames (_zoom_step),
## keeping the world point under the cursor fixed while it moves.
func _zoom_by(k: float) -> void:
	cancel_glide()
	zoom_target = clampf(zoom_target * k, 0.45, 2.4)

## A zoom set straight on the camera (a loaded save, a screenshot demo) becomes the target.
func _zoom_step(delta: float) -> void:
	if not is_equal_approx(cam.zoom.x, zoom_last):
		zoom_target = cam.zoom.x
		zoom_last = cam.zoom.x
		return
	if cam.zoom.x == zoom_target: return
	var z: float = lerpf(cam.zoom.x, zoom_target, minf(1.0, delta * 12.0))
	if absf(z - zoom_target) < 0.002: z = zoom_target
	zoom_last = z
	var before := get_global_mouse_position()
	cam.zoom = Vector2(z, z)
	cam.force_update_scroll()
	cam.position += before - get_global_mouse_position()
	_clamp_cam()

func _clamp_cam() -> void:
	cam.position = _clamp_target(cam.position)

func _clamp_target(p: Vector2) -> Vector2:
	return Vector2(clampf(p.x, -D.H * IX, D.W * IX), clampf(p.y, 0, (D.W + D.H) * IY))

## Glide to a place (an alert, an envoy, a new site) instead of teleporting there.
func focus_on(p: Vector2) -> void:
	if cam_tween: cam_tween.kill()
	cam_tween = create_tween()
	cam_tween.tween_property(cam, "position", _clamp_target(iso(p)), 0.5).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

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
	if not photo_ground: ci.draw_texture_rect(wear_tex, Rect2(0, 0, sim.wear_w * sim.WEAR_CELL, sim.wear_h * sim.WEAR_CELL), false)
	_draw_season_ground()
	_draw_water_fx()
	for s in sim.structures: _draw_ground_part(s)
	for c in sim.contracts.list: _draw_site_ring(c)
	if not cmd_marker.is_empty() and t - cmd_marker["t"] < 0.6:
		var k: float = (t - cmd_marker["t"]) / 0.6
		ci.draw_arc(cmd_marker["p"], 6 + 16 * k, 0, TAU, 24, Color(cmd_marker["c"], 1.0 - k), 3)
	ghost_m = Vector2.ZERO
	ghost_why = ""
	if build_type != "road": road_start = null
	if build_type == "road":
		ghost_m = uniso(get_global_mouse_position())
		var lv: int = sim.roads.best_buildable()
		if road_start != null and lv > 0:
			for k in sim.roads.plan(road_start, ghost_m, lv):
				var c: Vector2 = sim.roads.cell_pos(k)
				ci.draw_rect(Rect2(c - Vector2(12, 12), Vector2(24, 24)), Color(0.85, 0.7, 0.4, 0.45))
		ci.draw_circle(ghost_m, 10, Color(0.9, 0.75, 0.45, 0.6))
	elif build_type == "" or not D.STRUCTURES[build_type].get("ring", false): wall_center = null
	if build_type != "" and build_type != "road":
		ghost_m = uniso(get_global_mouse_position())
		var ring: bool = D.STRUCTURES[build_type].get("ring", false)
		if ring: # first the middle, then the cursor's distance from it is the radius
			if wall_center != null:
				build_size = sim.ring_radius(build_type, ghost_m.distance_to(wall_center))
				ghost_m = wall_center
			else: build_size = sim.ring_radius(build_type, 0.0)
		ghost_why = sim.can_place(build_type, ghost_m, build_size if ring else 0.0)
		var col := Color(0.4, 1, 0.4, 0.45) if ghost_why == "" else Color(1, 0.3, 0.3, 0.45)
		var r: float = build_size if ring else D.STRUCTURES[build_type]["r"]
		if ring:
			ci.draw_circle(ghost_m, minf(r, 30), col)
			ci.draw_arc(ghost_m, r, 0, TAU, 64, col, 6)
		else: # (the building itself is drawn above, by the Ghost layer: here only its footprint)
			ci.draw_circle(ghost_m, r, Color(col, 0.22))
			ci.draw_arc(ghost_m, r, 0, TAU, 48, Color(col, 0.7), 2)
	if sim.flood_fx > 0:
		ci.draw_rect(Rect2(0, 0, D.W, D.H), Color(0.2, 0.4, 0.75, sim.flood_fx * 0.4))
	_draw_puddles()
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
## The building being placed, as it will look when finished (AoE-style), at the cursor:
## tinted green where it can go, red where it can't. Walls keep their ring outline.
func draw_ghost() -> void:
	if build_type == "" or build_type == "road" or not D.STRUCTURES.has(build_type) or D.STRUCTURES[build_type].get("ring", false): return
	if _ghost_s == null: _ghost_s = E.Structure.new()
	var g = _ghost_s
	g.id = -1
	g.type = build_type
	g.pos = ghost_m
	g.built = true
	g.work = float(D.STRUCTURES[build_type].get("work", 1.0))
	g.progress = g.work
	g.style = clampi(sim.evo.era, 1, 3)
	ghost.modulate = Color(0.7, 1.0, 0.7, 0.62) if ghost_why == "" else Color(1.0, 0.45, 0.4, 0.62)
	_draw_structure(g)

func draw_overlay() -> void:
	# ---- fog of war over everything in the world (labels below stay readable)
	if sim.fog_enabled:
		ci.draw_set_transform_matrix(GROUND)
		ci.draw_texture_rect(fog_tex, Rect2(0, 0, sim.fog_w * D.FOG_CELL, sim.fog_h * D.FOG_CELL), false)
		ci.draw_set_transform_matrix(Transform2D.IDENTITY)

	_draw_weather()
	_draw_nature()
	if clean: return
	# ---- overlay pass: labels, bars, flags (never hidden behind objects)
	for f in D.FORDS:
		var ford_lbl: Vector2 = f["p"] + f["t"] * (D.FORD_LEN + 30.0)
		if sim.is_explored(ford_lbl): _draw_label(iso(ford_lbl) + Vector2(0, 14), tr("FORD"), 13, Color(1, 1, 1, 0.65), true)
	for lb in D.LABELS: # the scenario's own names for places
		if sim.is_explored(lb["pos"]): _draw_label(iso(lb["pos"]), tr(lb["text"]), int(lb.get("size", 20)), Color(1, 1, 1, 0.4), true)
	if str(sim.place_of(D.VILLAGE).get("name", "")) == "": # (once the village has a name of its own, that is the label)
		_draw_label(iso(D.VILLAGE + Vector2(-220, -300)), tr("TRIBAL LANDS"), 20, Color(1, 1, 1, 0.4), true)
	for at in sim.settlements(): # our settlements by the names they have earned (rules.json tiers)
		var pl: Dictionary = sim.place_of(at)
		if str(pl.get("name", "")) != "" and _in_view(at):
			_draw_label(iso(at) + Vector2(0, -215), tr(pl["name"]).to_upper(), 26, Color("#ffe9b8"), true)
			_draw_label(iso(at) + Vector2(0, -192), tr(sim.tier_row(str(pl["tier"])).get("name", "")), 15, Color(1, 0.95, 0.85, 0.85), true)
	for lm in sim.landmarks:
		if lm["found"] and _in_view(lm["pos"]):
			_draw_label(iso(lm["pos"]) + Vector2(0, 22), tr(lm["name"]), 13, Color("#ffe6a8") if lm["kind"] != "den" else Color("#ff9b8a"), true)
	for id in sim.rivals.clans: _draw_clan_banner(sim.rivals.clans[id])
	for s in sim.structures:
		if _in_view(s.pos):
			_draw_structure_overlay(s)
	_draw_pick_marks()
	_label_rects.clear()
	var every := show_all_names()
	var later: Array = [] # ordinary names: drawn after the popups, where they still fit
	var first: Array = [] # [priority, unit]
	for u in sim.units:
		if u.dead or sim.in_hut(u) or not _in_view(u.pos): continue
		_draw_unit_bar(u)
		var pr := name_priority(u)
		if pr > 0: first.append([pr, u])
		elif every: later.append(u)
	first.sort_custom(func(x, y): return x[0] > y[0])
	for e in first: _draw_unit_name(e[1], e[0] >= NAME_ALWAYS)
	var abed := {} # hut id -> sleepers inside
	for u in sim.units:
		if sim.in_hut(u): abed[u.bed_id] = abed.get(u.bed_id, 0) + 1
	for s in sim.structures:
		if abed.has(s.id) and _in_view(s.pos): _zzz(iso(s.pos) + Vector2(12, -52), s.id)
	for p in sim.predators:
		if p.dead or p.fled or not sim.is_visible(p.pos): continue
		if p.clan != "":
			var cc: Color = sim.rivals.clans[p.clan]["color"]
			_draw_label(iso(p.pos) + Vector2(0, -46), tr(p.name), 12, cc.lightened(0.45), true)
			if p.hp < p.max_hp - 0.5: _bar(iso(p.pos) + Vector2(0, 6), 24, p.hp / p.max_hp, cc.lightened(0.2))
		else:
			_bar(iso(p.pos) + Vector2(0, 8), 32, p.hp / p.max_hp, Color("#ff9b3a"))
	for s in sim.hunt.shots: # arrows and sling stones in flight (hunt.gd)
		if not sim.is_visible(s["to"]): continue
		var k: float = s["t"] / s["life"]
		var a: Vector2 = iso(s["from"]) + Vector2(0, -22)
		var b: Vector2 = iso(s["to"]) + Vector2(0, -12)
		var lift := (a.distance_to(b) * 0.25)
		var at := a.lerp(b, k) - Vector2(0, sin(PI * k) * lift)
		var ahead := a.lerp(b, minf(1.0, k + 0.08)) - Vector2(0, sin(PI * minf(1.0, k + 0.08)) * lift)
		if s["weapon"] == "bow": ci.draw_line(at - (ahead - at).normalized() * 9.0, at, Color("#f3e2c0"), 1.5)
		else: ci.draw_circle(at, 2.2, Color("#9a9184"))
	for p in sim.popups:
		if not sim.is_explored(p["pos"]): continue
		var a: float = 1.0 - pow(p["t"] / p["life"], 2)
		var col: Color = p["color"]
		col.a = a
		var at: Vector2 = iso(p["pos"]) - Vector2(0, 26)
		var size: int = 17 if p["big"] else 13
		if _label_room(at, p["text"], size, p["big"]): _draw_label(at, p["text"], size, col, true)
	for u in later: _draw_unit_name(u, false)
	if not clean: # speech marks last, above names and popups
		for u in sim.units:
			if u.say_until > sim.time and u.say != "" and not u.dead and not sim.in_hut(u) and _in_view(u.pos):
				_speech(iso(u.pos) + Vector2(0, -66 if u.role != "child" else -52), u, u.say_until - sim.time)
	if drag_start != null and wall_center == null: # (a box select, not a wall being sized)
		var m := get_global_mouse_position()
		var r := Rect2(drag_start, m - drag_start).abs()
		ci.draw_rect(r, Color(1, 1, 0.6, 0.12))
		ci.draw_rect(r, Color(1, 1, 0.6, 0.7), false, 1.5)
	if build_type == "road":
		var lv: int = sim.roads.best_buildable()
		var lbl: String = tr(sim.roads.def_of(lv).get("name", "Road"))
		if road_start == null: lbl += "  " + tr("click where it begins")
		else:
			var cells: Array = sim.roads.plan(road_start, ghost_m, lv)
			var cost: Dictionary = sim.roads.cost(cells, lv)
			lbl += "  " + tr("%d paces · %s · click where it ends") % [roundi(cells.size() * sim.WEAR_CELL), ", ".join(cost.keys().map(func(r): return "%d %s" % [cost[r], tr(r)]))]
		_draw_label(iso(ghost_m) + Vector2(0, -30), lbl, 14, Color.WHITE, true)
	elif build_type != "":
		var gname: String = tr(D.STRUCTURES[build_type]["name"])
		if D.STRUCTURES[build_type].get("ring", false):
			if wall_center == null: gname += "  " + tr("click the middle")
			else: gname += "  " + tr("radius %d · %d wood · click to build") % [roundi(build_size), sim.place_cost(build_type, build_size)["wood"]]
		_draw_label(iso(ghost_m) + Vector2(0, -44), gname + ("" if ghost_why == "" else " - " + tr(ghost_why)), 14, Color.WHITE, true)

# ------------------------------------------------------------ seasons & weather
func _draw_season_ground() -> void:
	var hz = sim.hz
	if not hz.on(): return
	var world := Rect2(0, 0, D.W, D.H)
	if hz.snow > 0.01: ci.draw_rect(world, Color(0.93, 0.96, 1.0, 0.6 * hz.snow))
	if hz.season_idx() == 2: ci.draw_rect(world, Color(0.85, 0.5, 0.15, 0.13))
	if hz.dry(): ci.draw_rect(world, Color(0.85, 0.7, 0.35, 0.2))

## How hard the wind blows right now (0..1): a slow gust pattern, much stronger
## in rain, storms and blizzards. Calm air stays below the bend threshold so
## tree items keep their cached draw in fine weather.
func wind_k() -> float:
	var w := 0.15
	if sim.hz.on():
		w = {"rain": 0.45, "storm": 0.9, "blizzard": 1.0}.get(sim.hz.weather, 0.2)
	return w * (0.75 + 0.25 * sin(t * 0.9) * sin(t * 0.53 + 1.7))

const WIND_BEND := 0.28 # how far a full-gale crown leans, as a shear factor

func _bend_matrix(b: Vector2): # null when the air is calm
	var k := wind_k()
	if k < 0.3: return null
	# shear x by -s*(y - b.y), composed with the item's base translate(-b)
	return Transform2D(Vector2(1, 0), Vector2(-WIND_BEND * k, 1), Vector2(-b.x + WIND_BEND * k * b.y, -b.y))

func _bend_dx(sz: float) -> float:
	var k := wind_k()
	return 0.0 if k < 0.3 else WIND_BEND * k * 45.0 * sz

## Rain lays the ground wet; it dries slowly after. Puddles gather where the
## land is flat and away from the village fire.
var wet := 0.0
var _cache_puddles: Array = []

func _wet_step(delta: float) -> void:
	var raining: bool = sim.hz.on() and sim.hz.weather in ["rain", "storm"]
	wet = clampf(wet + delta * (0.09 if raining else -0.025), 0.0, 1.0)

func _puddles() -> Array:
	if _cache_puddles.is_empty():
		var rng := RandomNumberGenerator.new()
		rng.seed = 7 # the same puddles every game, like the land itself
		var step := 120.0
		for gx in range(0, int(D.W / step)):
			for gy in range(0, int(D.H / step)):
				var p := Vector2(gx * step, gy * step) + Vector2(rng.randf_range(20, step - 20), rng.randf_range(20, step - 20))
				if D.is_water(p) or p.distance_to(D.VILLAGE) < 260.0: continue
				if D.river_dist(p) < 220.0: continue # the banks stay muddy, not puddled
				_cache_puddles.append(p)
	return _cache_puddles

func _draw_puddles() -> void:
	if wet < 0.08: return
	var a := (wet - 0.08) / 0.92
	for p in _puddles():
		if not _in_view(p): continue
		var s := iso(p)
		ci.draw_set_transform(s, 0.0, Vector2(1.0, 0.5))
		ci.draw_circle(Vector2.ZERO, 9.0 + fmod(p.x * 0.13 + p.y * 0.07, 6.0), Color(0.25, 0.35, 0.5, 0.28 * a))
		ci.draw_set_transform_matrix(Transform2D.IDENTITY)

## A thunderstorm's flash stutters: two hard pulses, then a fading afterglow.
func _storm_flash() -> float:
	var k := fposmod(t, 7.3)
	if k > 0.55: return 0.0
	if k < 0.08: return 1.0
	if k < 0.16: return 0.12
	if k < 0.34: return 0.55
	return 0.1

## Rain, snow and blizzards are drawn over the visible screen area only.
func _draw_weather() -> void:
	var hz = sim.hz
	if not hz.on(): return
	var w: String = hz.weather
	var snowing: bool = w == "blizzard" or (hz.winter() and w == "clear")
	if w in ["rain", "storm"]:
		var slant := 3.0 + 10.0 * wind_k() # the rain leans with the gusts
		for i in 220:
			var x := view.position.x + fmod(i * 137.71 + t * 60.0, view.size.x)
			var y := view.position.y + fmod(i * 91.37 + t * 620.0, view.size.y)
			ci.draw_line(Vector2(x, y), Vector2(x - slant, y + 16), Color(0.75, 0.85, 1.0, 0.35), 1.2)
		if w == "storm":
			var fl: float = _storm_flash()
			if fl > 0.0: ci.draw_rect(view, Color(1, 1, 0.9, 0.35 * fl))
	if snowing:
		var n := 420 if w == "blizzard" else 140
		var drift := 260.0 if w == "blizzard" else 25.0
		for i in n:
			var x := view.position.x + fmod(i * 137.71 + t * drift + sin(t + i) * 12.0, view.size.x)
			var y := view.position.y + fmod(i * 91.37 + t * (140.0 if w == "blizzard" else 45.0), view.size.y)
			ci.draw_circle(Vector2(x, y), 1.6 + fmod(i * 0.37, 1.6), Color(1, 1, 1, 0.75))
		if w == "blizzard": ci.draw_rect(view, Color(0.9, 0.94, 1.0, 0.25))

## Lightning bolts and flashes, falling ash, the swollen spring river.
func _draw_nature() -> void:
	var nat = sim.nat
	var half: float = nat.flood_half()
	if half > D.RIVER_HALF:
		var k: float = (half - D.RIVER_HALF) / 110.0
		ci.draw_set_transform_matrix(GROUND)
		for pts in D.RIVERS:
			var sparse := PackedVector2Array()
			for i in range(0, pts.size(), 2): sparse.append(pts[i])
			sparse.append(pts[pts.size() - 1])
			var left := _offset_line(sparse, -half)
			var right := _offset_line(sparse, half)
			right.reverse()
			var poly := left + right
			if Geometry2D.triangulate_polygon(poly).is_empty(): # tight bends: draw it as a thick line instead
				ci.draw_polyline(sparse, Color(0.32, 0.5, 0.72, 0.55 * k), half * 2.0)
			else:
				ci.draw_colored_polygon(poly, Color(0.32, 0.5, 0.72, 0.55 * k))
		ci.draw_set_transform_matrix(Transform2D.IDENTITY)
	for s in nat.strikes:
		var a: float = 1.0 - s["t"] / 0.7
		var g := iso(s["pos"])
		if s["t"] < 0.15: ci.draw_rect(view, Color(1, 1, 0.92, 0.3 * (1.0 - s["t"] / 0.15)))
		var pts := PackedVector2Array([g + Vector2(0, -520)])
		var k2 := 0
		while k2 < 8:
			k2 += 1
			pts.append(g + Vector2(sin(k2 * 2.7 + s["pos"].x) * 22.0, -520.0 + k2 * 65.0))
		ci.draw_polyline(pts, Color(1, 1, 0.85, a), 5.0)
		ci.draw_polyline(pts, Color(1, 1, 1, a), 2.0)
		ci.draw_circle(g, 18.0 * a, Color(1, 0.95, 0.7, 0.6 * a))
	if nat.ash > 0.02:
		ci.draw_rect(view, Color(0.3, 0.27, 0.25, 0.42 * nat.ash))
		for i in int(380 * nat.ash):
			var x := view.position.x + fmod(i * 131.3 + t * 18.0 + sin(t * 0.7 + i) * 10.0, view.size.x)
			var y := view.position.y + fmod(i * 77.9 + t * 30.0, view.size.y)
			ci.draw_circle(Vector2(x, y), 1.8 + fmod(i * 0.29, 1.8), Color(0.42, 0.4, 0.38, 0.8))

func _draw_wolf(p) -> void:
	var b := iso(p.pos)
	var key := "p%d" % p.id
	var f: float = facing.get(key, 1)
	var walk: bool = moving.get(key, false)
	_ell(b + Vector2(2, 1), 13, 4.5, SHADOW)
	var body := b - Vector2(0, 10)
	for i in 4:
		var lx := body.x + (-7 + i * 4.5) * f
		var sw := sin(anim_t * 15 + i * 1.9) * 3.0 if walk else 0.0
		ci.draw_line(Vector2(lx, body.y + 2), Vector2(lx + sw, b.y), Color("#4a4a4e"), 2.2)
	ci.draw_line(body + Vector2(-10 * f, -1), body + Vector2(-17 * f, 3 + sin(anim_t * 4) * 2), Color("#6d6d72"), 3)
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
		"volcano":
			var erupting: bool = sim.nat.erupt_left > 0
			_ell(b + Vector2(30, 10), 150, 42, SHADOW)
			ci.draw_colored_polygon(PackedVector2Array([b + Vector2(-150, 14), b + Vector2(-40, -150), b + Vector2(40, -150), b + Vector2(160, 14)]), Color("#4a3e38"))
			ci.draw_colored_polygon(PackedVector2Array([b + Vector2(40, -150), b + Vector2(160, 14), b + Vector2(30, 14)]), Color("#3a302c"))
			_ell(b + Vector2(0, -150), 40, 10, Color("#2a201c"))
			_ell(b + Vector2(0, -150), 28, 6, Color("#ff6a20") if erupting else Color("#8a3a1a"))
			if erupting:
				for k in 3: # lava runs
					var x0 := -20.0 + k * 20.0
					ci.draw_polyline(PackedVector2Array([b + Vector2(x0, -148), b + Vector2(x0 * 1.6 + sin(k) * 10, -90), b + Vector2(x0 * 2.6, -30), b + Vector2(x0 * 3.2, 6)]), Color(1.0, 0.45 + 0.1 * sin(t * 6 + k), 0.1), 5.0)
				for k in 6:
					var kk := fmod(t * 1.4 + k / 6.0, 1.0)
					ci.draw_circle(b + Vector2(sin(k * 1.9) * 40 * kk, -160 - 120 * kk), 3, Color(1, 0.6, 0.2, 1.0 - kk))
			var plume: float = 1.0 if erupting else (0.6 if sim.nat.ash > 0.1 or sim.time >= sim.nat.erupt_at - 30.0 else 0.25)
			for k in 7:
				var kk := fmod(t * 0.12 + k / 7.0, 1.0)
				ci.draw_circle(b + Vector2(-10 + 70 * kk + sin(t * 0.5 + k) * 8, -160 - 220 * kk), (12 + 40 * kk) * plume, Color(0.25, 0.23, 0.22, 0.55 * (1.0 - kk) * plume))
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
	for bk in river_banks:
		ci.draw_polyline(bk[0], Color(0.85, 0.92, 1.0, 0.35), 3)
		ci.draw_polyline(bk[1], Color(0.85, 0.92, 1.0, 0.35), 3)
	for f in D.FORDS: # stepping stones
		for i in 9:
			var sp: Vector2 = f["p"] + f["t"] * lerpf(-D.FORD_LEN + 10, D.FORD_LEN - 10, float(i % 3) / 2.0) + f["n"] * lerpf(-D.RIVER_HALF + 10, D.RIVER_HALF - 10, float(i / 3) / 2.0)
			ci.draw_circle(sp + Vector2(2, 2), 7, Color(0, 0, 0, 0.2))
			ci.draw_circle(sp, 7, Color("#a5a291"))
	for pts in D.RIVERS: # ripples drifting downstream
		var n: int = pts.size()
		for i in mini(110, n / 2):
			var s := fmod(i * 47.3 + t * 0.9, float(n - 1))
			var k := int(s)
			var a: Vector2 = pts[k].lerp(pts[k + 1], s - k)
			var tg: Vector2 = (pts[k + 1] - pts[k]).normalized()
			var p: Vector2 = a + Vector2(-tg.y, tg.x) * sin(i * 12.3) * D.RIVER_HALF * 0.6
			if D.is_ford_at(p) or not _in_view(p): continue
			ci.draw_line(p, p + tg * 14.0 + Vector2(-tg.y, tg.x) * 3.0, Color(0.75, 0.9, 1.0, 0.35), 2)
	# foam curls where the water worries the bank, crawling slowly downstream
	for bk in river_banks:
		for line in bk:
			var n2: int = line.size() - 1
			if n2 < 2: continue
			for i in mini(50, n2):
				var s := fposmod(i * 53.7 + t * 0.55, float(n2))
				var k := int(s)
				var q: Vector2 = line[k].lerp(line[k + 1], s - k)
				if not _in_view(q): continue
				ci.draw_circle(q + Vector2(0, -1), 1.8 + sin(i * 3.1) * 0.6, Color(0.95, 0.98, 1.0, 0.3))
	# low sun and moonlight scatter on the water: twinkling glints
	var glow_amt := 0.0
	if sim.is_day_part("dusk"): glow_amt = sin(_part_k("dusk") * PI)
	elif sim.is_day_part("dawn"): glow_amt = sin(_part_k("dawn") * PI) * 0.8
	glow_amt = maxf(glow_amt, sim.night_amt * 0.5)
	if glow_amt > 0.05:
		for pts in D.RIVERS:
			var n: int = pts.size()
			for i in mini(60, n / 2):
				var s := fposmod(i * 89.1 + t * 0.35, float(n - 1))
				var k := int(s)
				var p: Vector2 = pts[k].lerp(pts[k + 1], s - k)
				if D.is_ford_at(p) or not _in_view(p): continue
				var tw: float = sin(t * 3.0 + i * 2.7)
				if tw < 0.55: continue
				ci.draw_circle(p, 1.6, Color(1.0, 0.95, 0.8, (tw - 0.55) * glow_amt * 0.9))

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
	if sk != "" and _sprite(sk + _snowy(), p, s, _tint(int(d["p"].x + d["p"].y))): return
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

func _draw_post(b: Vector2, shown: bool, built: bool, style := 2, stone := false, tower := false) -> void:
	if not shown:
		ci.draw_circle(b, 2, Color(0.5, 0.4, 0.3, 0.35))
		return
	if stone: # a stone wall's block, or one of its towers
		if _sprite(("wall_tower" if tower else "wall_stone") + _snowy(), b): return
		var h := 30.0 if tower else 14.0
		var w := 9.0 if tower else 7.0
		ci.draw_rect(Rect2(b.x - w, b.y - h, w * 2, h), Color("#8f8b82"))
		ci.draw_rect(Rect2(b.x, b.y - h, w, h), Color("#77736b"))
		for k in int(h / 5): ci.draw_line(b + Vector2(-w, -k * 5 - 2), b + Vector2(w, -k * 5 - 2), Color(0, 0, 0, 0.18), 1)
		if tower: ci.draw_colored_polygon(PackedVector2Array([b + Vector2(-w - 2, -h), b + Vector2(w + 2, -h), b + Vector2(0, -h - 12)]), Color("#a57a4a"))
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

## Every tree is itself: a touch of hue and brightness jitter keyed to its id,
## so a wall of sprites doesn't read as the same tree stamped over and over.
func _tint(id: int) -> Color:
	var v: float = 0.9 + 0.1 * float(id % 211) / 211.0 # brightness
	var r: float = 0.96 + 0.06 * float((id * 7 + 13) % 97) / 97.0 # a little warmer or cooler
	var bl: float = 0.95 + 0.06 * float((id * 13 + 5) % 89) / 89.0
	return Color(v * minf(r, 1.0), v, v * minf(bl, 1.0))

func _draw_node(n) -> void:
	var b := iso(n.pos)
	if sim.nat.burning.has(n.id): # a burning tree, then flames
		if not _sprite(("pine_%d" if n.id % 3 == 2 else "leaf_%d") % (n.id % 4), b, n.sz, Color(0.55, 0.45, 0.4)): _draw_tree_shape(n, b)
		var left: float = sim.nat.burning[n.id]
		var hgt: float = 34.0 * n.sz * clampf(left / 6.0, 0.4, 1.0)
		_flame(b + Vector2(0, -10 * n.sz), 9.0 * n.sz, hgt * (1.0 + 0.2 * sin(t * 12 + n.id)), Color("#ff8a2a"))
		_flame(b + Vector2(-5, -20 * n.sz), 6.0 * n.sz, hgt * 0.7 * (1.0 + 0.2 * sin(t * 15 + n.id * 2)), Color("#ffd040"))
		_smoke(b - Vector2(0, 40 * n.sz), n.id)
		return
	match n.kind:
		"tree": # a baked sprite has no shadow of its own; the hand-drawn fallback casts one
			var tn := ("pine_%d" if n.id % 3 == 2 else "leaf_%d") % (n.id % 4) + _snowy()
			if art != null and art.has(tn): _ell(b + Vector2(12 * n.sz + _bend_dx(n.sz), 4 * n.sz), 18 * n.sz, 7 * n.sz, SHADOW)
			var bend: Variant = _bend_matrix(b) # a gust leans the crown; the roots stay put
			if bend != null: ci.draw_set_transform_matrix(bend)
			if _sprite(tn, b, n.sz, _tint(n.id)): return
			if bend != null: ci.draw_set_transform(-b)
		"bush":
			var bn := ("bush_full" if n.amount >= 5 else "bush_bare") + _snowy()
			if art != null and art.has(bn): _ell(b + Vector2(4, 2), 13, 5, SHADOW)
			if _sprite(bn, b, 1.0, _tint(n.id)): return
		"stump":
			var sn := "stump" + _snowy()
			if art != null and art.has(sn): _ell(b + Vector2(2, 1), 7, 3.5, SHADOW)
			if _sprite(sn, b): return
		"carcass":
			if n.from_deer and _sprite("deer_dead_%d_0" % (n.id % 8), b, 1.1): return
		"deer":
			if _beast_sprite("deer", "n%d" % n.id, b): return
		"boulder":
			var bk := clampf(n.amount / 40.0, 0.45, 1.0)
			var rk := "rock_%d" % (n.id % 3) + _snowy()
			if art != null and art.has(rk): _ell(b + Vector2(8, 3), 22 * bk, 8 * bk, SHADOW)
			if _sprite(rk, b, bk): return
	match n.kind:
		"tree":
			var bend2: Variant = _bend_matrix(b)
			if bend2 != null: ci.draw_set_transform_matrix(bend2)
			_draw_tree_shape(n, b)
			if bend2 != null: ci.draw_set_transform(-b)
		_ when D.FINDS.has(n.kind): # the natural finds, the culture's own among them
			_draw_find(n, b)
		"boulder":
			var k: float = clampf(n.amount / 40.0, 0.35, 1.0)
			_ell(b + Vector2(8, 3), 22 * k, 8 * k, SHADOW)
			for i in 3:
				var q := b + Vector2((i - 1) * 9 * k, (i % 2) * 3)
				var h: float = (14.0 - i * 3.0) * k
				ci.draw_colored_polygon(PackedVector2Array([q + Vector2(-9, 0) * k, q + Vector2(-7 * k, -h), q + Vector2(2 * k, -h - 4 * k), q + Vector2(9 * k, -h * 0.4), q + Vector2(8, 0) * k]), Color("#8e8a80"))
				ci.draw_colored_polygon(PackedVector2Array([q + Vector2(-7 * k, -h), q + Vector2(2 * k, -h - 4 * k), q + Vector2(0, -h * 0.5)]), Color("#b0aca2"))
		"burnt":
			_ell(b + Vector2(2, 1), 8, 3.5, Color(0.1, 0.08, 0.06, 0.5))
			ci.draw_line(b, b + Vector2(1, -22 * n.sz), Color("#2a2420"), 4.0)
			ci.draw_line(b + Vector2(1, -14 * n.sz), b + Vector2(-7, -22 * n.sz), Color("#2a2420"), 2.0)
			ci.draw_line(b + Vector2(1, -18 * n.sz), b + Vector2(7, -26 * n.sz), Color("#2a2420"), 2.0)
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
				var sw := sin(anim_t * 14 + i * 1.7) * 2.5 if walk else 0.0
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
	if s.type == "roadworks": # the stretches still to build, marked out with pegs and string
		var per: float = s.work / maxf(1.0, s.cells.size())
		var done := int(s.progress / per)
		for i in range(done, s.cells.size()):
			var c: Vector2 = sim.roads.cell_pos(int(s.cells[i][0]))
			ci.draw_rect(Rect2(c - Vector2(9, 9), Vector2(18, 18)), Color(0.55, 0.42, 0.25, 0.35))
		return
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
		"grand_altar", "totem_shrine", "temple":
			ci.draw_circle(p, D.STRUCTURES[s.type]["r"] + 10, Color(0.55, 0.5, 0.4, 0.35 * a))
		"burial_ground":
			ci.draw_circle(p, 44, Color(0.36, 0.33, 0.24, 0.3))
			for i in 20:
				ci.draw_circle(p + Vector2.from_angle(i * TAU / 20) * 46, 3.0, Color(0.62, 0.6, 0.55, 0.95))

## Construction sprite for an unbuilt structure: footprint shape and size by type
## (homes follow the current era), stage by progress. False if not baked.
const SITE_SHAPES := {
	"hut": ["round", 20], "large_hut": ["round", 26], "granary": ["round", 20], "smelter": ["round", 14],
	"council_ring": ["round", 26], "totem_shrine": ["round", 14], "grand_altar": ["rect", 26],
	"weapon_rack": ["round", 14], "aurochs_pen": ["round", 26], "bonfire": ["round", 14], "lookout_tower": ["round", 14], "smokehouse": ["round", 18], "longhouse": ["rect", 30], "temple": ["round", 18], "trading_post": ["round", 20],
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
	# contact shadow for baked structure sprites (the hand-drawn fallbacks cast their own):
	# draws the ellipse and reports whether the sprite exists, so the fallback path stays untouched
	var spr_shadow := func(key: String, r: float) -> bool:
		if art == null or not art.has(key): return false
		_ell(b + Vector2(r * 0.3, r * 0.15), r * 1.15, r * 0.5, SHADOW)
		return true
	if s.built and s.type == "farm_plot":
		var season: String = ["spring", "summer", "autumn", "winter"][sim.hz.season_idx()] if sim.hz.on() else "summer"
		if _sprite("farm_" + season, b): return
	var west_dock: bool = s.type == "fishing_dock" and D.river_info(s.pos)["n"].x < 0.0 # on the river's west side
	if s.built and s.type == "fishing_dock":
		var dk := ("dock_w" if west_dock else "dock") + _snowy()
		if art != null and art.has(dk): _ell(b, 46, 14, SHADOW * 0.6)
		if _sprite(dk, b):
			var rod := iso(s.pos + Vector2(60 if west_dock else -60, -4 if west_dock else 4))
			ci.draw_line(rod + Vector2(0, -20), rod + Vector2(-4, 6 + sin(t * 2) * 2), Color(1, 1, 1, 0.45), 1)
			return
	if s.built and s.type in ["granary", "smelter", "council_ring", "totem_shrine", "grand_altar", "weapon_rack", "aurochs_pen", "lookout_tower", "smokehouse", "longhouse", "temple", "trading_post", "warehouse"]:
		if spr_shadow.call(s.type + _snowy(), float(sim.struct_r(s))):
			if _sprite(s.type + _snowy(), b):
				if s.decor > 0: _decor(s, b, 18.0)
				match s.type:
					"smelter": _smoke(b - Vector2(-4, 36), s.id)
					"council_ring": _flame(b - Vector2(0, 2), 4, 11 * (1.0 + 0.15 * sin(t * 10 + s.id)), Color("#f8a531"))
					"smokehouse": _smoke(iso(s.pos + Vector2(-7, -2)) - Vector2(0, 24), s.id)
			_era_dressing(s, b) # the tribe's growing pride shows at the great places
			return
	match s.type:
		"burial_ground": _burial_ground(s, b)
		"hut", "large_hut":
			var big: bool = s.type == "large_hut"
			var r := 27.0 if big else 20.0
			var home_key := "%shome%d%s" % ["large_" if big else "", clampi(s.style, 1, 3), _snowy()]
			if s.built and spr_shadow.call(home_key, r) and _sprite(home_key, b):
				if s.decor > 0: _decor(s, b, r)
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
			_era_dressing(s, b)
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
		"warehouse": # (hand-drawn fallback: a long storehouse on stilts under a pitched roof)
			_ell(b + Vector2(6, 2), 34, 12, SHADOW)
			for dx in [-22.0, -8.0, 8.0, 22.0]: ci.draw_line(b + Vector2(dx, 0), b + Vector2(dx, -8), Color(C_WOOD.darkened(0.2), a), 3)
			ci.draw_colored_polygon(PackedVector2Array([b + Vector2(-26, -8), b + Vector2(26, -8), b + Vector2(26, -24), b + Vector2(-26, -24)]), Color(0.54, 0.38, 0.22, a))
			ci.draw_colored_polygon(PackedVector2Array([b + Vector2(-30, -22), b + Vector2(30, -22), b + Vector2(20, -38), b + Vector2(-20, -38)]), Color(0.65, 0.44, 0.25, a))
		"trading_post": # (hand-drawn fallback: an awning on poles over goods)
			_ell(b + Vector2(4, 2), 22, 8, SHADOW)
			for dx in [-14.0, 14.0]: ci.draw_line(b + Vector2(dx, 0), b + Vector2(dx, -20), Color(C_WOOD, a), 2.5)
			ci.draw_colored_polygon(PackedVector2Array([b + Vector2(-18, -18), b + Vector2(18, -18), b + Vector2(14, -26), b + Vector2(-14, -26)]), Color(0.72, 0.34, 0.22, a))
			for i in 3: ci.draw_circle(b + Vector2(-8 + i * 8, -4), 4, Color(0.66, 0.5, 0.32, a))
		"longhouse": # (hand-drawn fallback)
			_longhouse(s.pos, 34.0)
			if s.built and sim.has_tech("fire"): _smoke(b - Vector2(0, 40), s.id)
		"temple": # (hand-drawn fallback: a clay round hall under a tall cone, a totem by the door)
			_round_house(b, 17, 12, 30, Color("#c79a6a"), Color("#a9884a"), frac, s.built)
			_totem(b + Vector2(-14, 8), 26, 0.6, a)
		"lookout_tower": # (hand-drawn fallback: raked poles, platform, hood)
			_ell(b + Vector2(6, 2), 16, 6, SHADOW)
			var tp := b - Vector2(0, 40)
			for dx in [-9.0, -4.0, 4.0, 9.0]: ci.draw_line(b + Vector2(dx, 0), tp + Vector2(dx * 0.5, 0), Color(C_WOOD, a), 2.5)
			ci.draw_line(tp + Vector2(-9, 0), tp + Vector2(9, 0), Color(C_WOOD.darkened(0.2), a), 4)
			ci.draw_colored_polygon(PackedVector2Array([tp + Vector2(-11, -5), tp + Vector2(11, -5), tp + Vector2(0, -16)]), Color(0.7, 0.57, 0.33, a))
		"smokehouse": # (hand-drawn fallback: a hide cone and a drying rack)
			_ell(b + Vector2(4, 2), 20, 7, SHADOW)
			var hb := b + Vector2(-8, 0)
			ci.draw_colored_polygon(PackedVector2Array([hb + Vector2(-11, 0), hb + Vector2(11, 0), hb + Vector2(0, -20)]), Color(0.56, 0.42, 0.28, a))
			for dx in [4.0, 16.0]: ci.draw_line(b + Vector2(dx, 0), b + Vector2(dx, -14), Color(C_WOOD, a), 2)
			ci.draw_line(b + Vector2(4, -13), b + Vector2(16, -13), Color(C_WOOD, a), 2)
			for i in 4: ci.draw_line(b + Vector2(6 + i * 3, -13), b + Vector2(6 + i * 3, -8), Color(0.54, 0.2, 0.15, a), 2)
			if s.built: _smoke(hb - Vector2(0, 22), s.id)
		"grand_altar":
			_box(s.pos, 30, 30, 8, Color(0.62, 0.6, 0.56, a))
			_box(s.pos, 20, 20, 16, Color(0.66, 0.64, 0.6, a))
			_totem(b - Vector2(0, 16), 54, 1.3, a)

## Painted decorations on a home: a zigzag band, then handprints, then strings of beads
## and feathers by the door. Red once the tribe knows ochre, white clay before.
func _decor(s, b: Vector2, r: float) -> void:
	var paint := Color("#c0402a") if sim.knows_find("ochre") else Color("#ece4d2")
	var y := b.y - 8.0
	var pts := PackedVector2Array()
	for i in 9:
		pts.append(Vector2(b.x - r * 0.7 + i * r * 0.175, y - (4.0 if i % 2 == 0 else 0.0)))
	ci.draw_polyline(pts, paint, 2.0)
	if s.decor >= 2:
		for k in 2:
			var h := b + Vector2(-r * 0.35 + k * r * 0.5, -17)
			ci.draw_circle(h, 2.4, paint)
			for f in 4: ci.draw_line(h, h + Vector2(-2.4 + f * 1.6, -4.2), paint, 1.0)
	if s.decor >= 3:
		for k in 3:
			var top := b + Vector2(r * 0.55 + k * 4.0, -24 + k * 2.0)
			ci.draw_line(top, top + Vector2(0, 10), Color("#7a5a3a"), 1.0)
			ci.draw_circle(top + Vector2(0, 4), 1.5, Color("#e6c46a"))
			ci.draw_circle(top + Vector2(0, 8), 1.5, Color("#4fb0b8"))

## Earth mounds in rows, each with a marker stone; a tall standing stone watches over them.
## A name-stone alone (no mound) for those whose bodies were never found.
func _burial_ground(s, b: Vector2) -> void:
	var back := iso(s.pos + Vector2(-34, -34))
	_ell(back + Vector2(5, 2), 9, 4, SHADOW)
	ci.draw_colored_polygon(PackedVector2Array([back + Vector2(-6, 0), back + Vector2(-4, -30), back + Vector2(1, -36), back + Vector2(5, -29), back + Vector2(6, 0)]), Color("#8c877c"))
	ci.draw_line(back + Vector2(-4, -30), back + Vector2(1, -36), Color("#a9a497"), 2)
	var graves: Array = s.graves.duplicate()
	graves.sort_custom(func(x, y): return (x["pos"] as Vector2).x + (x["pos"] as Vector2).y < (y["pos"] as Vector2).x + (y["pos"] as Vector2).y)
	for g in graves:
		var q := iso(g["pos"])
		if not g["lost"]: # an earth mound, long side along the row
			_ell(q + Vector2(2, 2), 13, 5.5, SHADOW)
			_ell(q, 12, 5.5, Color("#4a3a26"))
			_ell(q - Vector2(0, 2.5), 10, 4.2, Color("#7a6545") if sim.hz.snow < 0.5 else Color("#e8ecf2"))
			for k in 3: ci.draw_circle(q + Vector2(-6 + k * 6, -1 + (k % 2)), 1.6, Color("#8f8a7e"))
		var m := q + Vector2(-11, -2)
		ci.draw_colored_polygon(PackedVector2Array([m + Vector2(-3.5, 0), m + Vector2(-3, -12), m + Vector2(0, -15), m + Vector2(3, -12), m + Vector2(3.5, 0)]), Color("#a29d92") if not g["lost"] else Color("#c2b896"))
		ci.draw_line(m + Vector2(-3, -12), m + Vector2(0, -15), Color("#c8c3b6"), 1.5)

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

## As eras pass, the great places get dressed: banner poles by the council fire,
## pennants at the shrine and altar, carved posts around the bonfire.
func _era_dressing(s, b: Vector2) -> void:
	var era: int = sim.evo.era
	if era < 2 or not s.built: return
	match s.type:
		"council_ring":
			for i in 3:
				var ang := TAU * i / 3.0 + 0.5
				_pennant(b + Vector2(cos(ang) * 40, sin(ang) * 20), 40 + i * 4, s.id + i)
		"bonfire":
			if era >= 3:
				for i in 2:
					var ang := TAU * i / 2.0 + 1.2
					_pennant(b + Vector2(cos(ang) * 18, sin(ang) * 9), 26, s.id + i)
		"totem_shrine", "grand_altar", "temple":
			if era >= 3: _pennant(b + Vector2(-26, 6), 46, s.id)

## A tall pole with a fluttering pennant: the cloth leans with the wind.
func _pennant(b: Vector2, h: float, seed_id: int) -> void:
	_ell(b + Vector2(1, 0), 5, 2, SHADOW)
	ci.draw_line(b, b - Vector2(0, h), Color("#6b4524"), 2.5)
	ci.draw_circle(b - Vector2(0, h), 2, Color("#e8c25a"))
	var sway: float = sin(t * 2.2 + seed_id) * 3.0 - wind_k() * 8.0
	var tip := b - Vector2(0, h - 8)
	ci.draw_colored_polygon(PackedVector2Array([tip, tip + Vector2(14 + sway, -3), tip + Vector2(12 + sway, 5)]), Color("#c0392b"))

func _draw_structure_overlay(s) -> void:
	if s.type == "burial_ground":
		_draw_label(iso(s.pos) + Vector2(0, 40), tr("Burial Ground") + (" (%d)" % s.graves.size() if not s.graves.is_empty() else ""), 12, Color(0.85, 0.82, 0.9, 0.75), true)
		return
	if s.reno:
		var rb := iso(s.pos)
		_bar(Vector2(rb.x, rb.y + 10), 38, s.reno_progress / sim.reno_need(s), Color("#9fd0ff") if s.upgrade != "" else Color("#ffd36b"))
		return
	if s.built: return
	var sd: Dictionary = D.STRUCTURES[s.type]
	var b := iso(s.pos) if not sd.get("ring", false) else iso(s.pos + Vector2.ONE * sim.struct_r(s) * 0.707)
	var by: float = b.y + 10
	_bar(Vector2(b.x, by), 38, s.progress / s.work, Color("#b6f28a"))
	if not s.paid: _draw_label(Vector2(b.x, by + 17), tr("awaiting wood"), 11, Color(1, 0.8, 0.6), true)

func _draw_site_ring(c) -> void:
	if not sim.contracts.is_running(c): return # only live sites are marked on the map
	var col := _site_col(c)
	for i in 32:
		var a0 := float(i) / 32 * TAU + t * 0.2
		ci.draw_arc(c.site, 125, a0, a0 + TAU / 64, 4, Color(col, 0.6), 4)
	if c.status in ["interrupted", "defending"]: # a pulse that says: the crew needs you
		var k: float = fposmod(t * 0.5, 1.0)
		ci.draw_arc(c.site, 30 + 110 * k, 0, TAU, 48, Color(col, 0.7 * (1.0 - k)), 3)

const SEL_COL := Color("#ffe9a0")

## A picked person's mark at their feet: one thin ellipse flat on the iso ground (2:1), with a
## faint glow inside (and a chevron over their head: _draw_pick_marks). A picked building has
## its marker above the roof.
func _sel_ring(b: Vector2, r: float) -> void:
	var rx := r - 3.0
	_ell(b, rx, rx * 0.5, Color(SEL_COL, 0.18), 24)
	_ell_line(b, rx, rx * 0.5, Color(SEL_COL, 0.9), 1.5)

## Who and what is under the cursor (rings only; the HUD tooltip uses hover_info).
func _update_hover() -> void:
	hover_unit = -1
	hover_struct = -1
	if _ui_has_pointer() or build_type != "": return
	var sm := get_global_mouse_position()
	var m := uniso(sm)
	var bd := 16.0
	for u in sim.units:
		if u.dead or u.sleeping or sim.in_hut(u) or not sim.is_visible(u.pos) or not _in_view(u.pos): continue
		var d := _pick_dist(sm, u.pos, 26)
		if d < bd:
			bd = d
			hover_unit = u.id
	if hover_unit >= 0: return
	for s in sim.structures:
		if not sim.is_explored(s.pos) or not _in_view(s.pos) or s.type == "burial_ground": continue
		var r: float = sim.struct_r(s)
		if D.STRUCTURES[s.type].get("ring", false):
			if absf(s.pos.distance_to(m) - r) < 14:
				hover_struct = s.id
				return
		elif s.pos.distance_to(m) < r + 10:
			hover_struct = s.id
			return

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
	var scol: Color = {"Blood feud": Color("#ff5a4a"), "Hostile": Color("#ff8a6a"), "Wary": Color("#ffe08a"), "Friendly": Color("#b6f28a"), "Trusted": Color("#9af0b0"), "Allied": Color("#8af2d0"), "Vassal": Color("#e6c46a")}[st]
	_draw_label(fp + Vector2(12, -72), tr(c["name"]).to_upper(), 15, col.lightened(0.5), true)
	if c["met"]: _draw_label(fp + Vector2(12, -88), tr(st), 12, scol, true)

## A body on its way to the burial ground on someone's shoulders.
func _carried(u) -> bool:
	if u.carrier_id < 0: return false
	var c = sim.unit_by_id(u.carrier_id)
	return c != null and not c.dead and c.job.get("phase", "") in ["carry"] and c.job.get("body_id", -1) == u.id

func _draw_unit(u) -> void:
	var b := iso(u.pos)
	_scale_about(b, FIG_SCALE)
	if u.buried: return
	if u.dead and _carried(u): # across the bearer's shoulders, crosswise to the way they walk
		var cb := b + Vector2(0, -30)
		if art and art.has("man_dead_0_0"):
			var cn := "man_dead_%d_0" % ((_dir_index("u%d" % u.id) + 2) % 8)
			_sprite(cn, cb, 0.8)
			_sprite(cn + "_cloth", cb, 0.8, u.color)
		else:
			ci.draw_line(cb + Vector2(-10, 2), cb + Vector2(8, -2), u.color, 5)
			ci.draw_circle(cb + Vector2(11, -2), 3.5, Color(0.85, 0.7, 0.55))
		return
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
	if sim.in_hut(u): return # asleep indoors: the hut shows the z's
	if u.sleeping:
		_draw_sleeper(u, b)
		return
	var key := "u%d" % u.id
	var f: float = facing.get(key, 1)
	var walk: bool = moving.get(key, false)
	var sel: bool = u.id in selected
	if u.role == "child": _scale_about(b, FIG_SCALE * 0.68) # children are small
	_ell(b + Vector2(2, 0), 9, 4, SHADOW)
	if u.hero: _ell(b, 15 + sin(t * 4) * 1.5, 7.5, Color(1, 0.85, 0.3, 0.3))
	if sel: _sel_ring(b, 14)
	elif u.id == hover_unit: _ell_line(b, 16, 8, Color(1, 1, 1, 0.45), 1.5)
	if u.role == "contract": _ell_line(b, 11, 5.5, Color(0.55, 0.8, 1.0, 0.8), 1.5)
	var busy: bool = DOING_ANIM.has(u.doing)
	if art and art.has("man_idle_0_0"):
		_draw_unit_sprite(u, b, key, walk, busy)
		return
	var bob := absf(sin(anim_t * 12 + u.id)) * 1.5 if walk else 0.0
	var skin := Color("#d9a77c")
	# legs
	var sw := sin(anim_t * 12 + u.id) * 3.0 if walk else 0.0
	ci.draw_line(b + Vector2(-2, -9 - bob), b + Vector2(-2 + sw, 0), skin.darkened(0.25), 2.5)
	ci.draw_line(b + Vector2(2, -9 - bob), b + Vector2(2 - sw, 0), skin.darkened(0.15), 2.5)
	# torso (fur tunic)
	var hip := b + Vector2(0, -8 - bob)
	if u.ox and u.job.get("type", "") == "gather":
		var behind: Vector2 = -heading.get(key, Vector2(0.6, 0.8)) * 18.0
		if not _beast_sprite("packox", key, b + behind, 0.8): _pack_ox(b + Vector2(-17 * f, 3), f, walk)
	if sim.has_tech("hide"): # fur cloak behind the body
		ci.draw_colored_polygon(PackedVector2Array([hip + Vector2(-6, -12), hip + Vector2(6, -12), hip + Vector2(-4 * f + 5 * f, 2), hip + Vector2(-8 * f, 1)]), Color("#7a5a3a"))
	ci.draw_colored_polygon(PackedVector2Array([hip + Vector2(-5, 1), hip + Vector2(5, 1), hip + Vector2(4, -12), hip + Vector2(-4, -12)]), u.color)
	ci.draw_colored_polygon(PackedVector2Array([hip + Vector2(1.5 * f, 1), hip + Vector2(5 * f, 1), hip + Vector2(4 * f, -12), hip + Vector2(1 * f, -12)]), u.color.darkened(0.25))
	ci.draw_line(hip + Vector2(-5, 1), hip + Vector2(5, 1), u.color.darkened(0.45), 1.5)
	# arms / tool
	var sh := hip + Vector2(0, -10)
	var swing := sin(anim_t * 9 + u.id) * 0.9 if busy else 0.0
	var hand := sh + Vector2(6 * f, 6).rotated(swing * -f * 0.6)
	ci.draw_line(sh + Vector2(3 * f, 0), hand, skin, 2)
	ci.draw_line(sh + Vector2(-3 * f, 0), sh + Vector2(-5 * f, 7 + sw * 0.4), skin.darkened(0.1), 2)
	if u.job.get("type", "") == "attack" or u.doing == "fight" or u.has_trait("belligerent"):
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
	_rank_feathers(u, head + Vector2(-3 * f, -3), f)
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
	if u.doing == "ritual":
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
	if moving.get(key, false): name = "%s_walk_%d_%d" % [kind, di, int(anim_t * 10.0 + key.hash() % 7) % 6]
	if attacking.has(key) and art.has("%s_attack_%d_0" % [kind, di]): name = "%s_attack_%d_%d" % [kind, di, int(anim_t * 8.0) % 4]
	if not art.has(name): return false
	_ell(b + Vector2(2, 1), 12, 4.5, SHADOW)
	return _sprite(name, b, sc)

## Pre-rendered villager: 8 facings, idle / walk / work frames, clothes tinted per person.
## Asleep in the open: lying down under a hide, with drifting z's.
func _draw_sleeper(u, b: Vector2) -> void:
	if u.id in selected: _sel_ring(b, 16)
	elif u.id == hover_unit: _ell_line(b, 16, 7, Color(1, 1, 1, 0.45), 1.5)
	_ell(b + Vector2(1, 1), 17, 6.5, Color("#6e5236")) # a hide bedroll
	_ell(b, 15, 5.2, Color("#9a7650"))
	if art and art.has("man_dead_0_0"):
		var dn := "man_dead_%d_0" % _dir_index("u%d" % u.id)
		_sprite(dn, b, 0.95)
		_sprite(dn + "_cloth", b, 0.95, u.color)
	else:
		_ell(b, 10, 4.5, Color(0.2, 0.14, 0.1, 0.5))
		ci.draw_line(b + Vector2(-8, -2), b + Vector2(7, 0), u.color, 5)
		ci.draw_circle(b + Vector2(10, -1), 3.2, Color("#d9a77c"))
	_zzz(b + Vector2(6, -14), u.id)

func _zzz(at: Vector2, seed_: int) -> void:
	for i in 3:
		var k := fmod(t * 0.45 + i / 3.0 + seed_ * 0.17, 1.0)
		var q := at + Vector2(sin(t * 1.5 + i + seed_) * 3.0 + k * 8.0, -k * 22.0)
		_draw_label(q, "z", 12 + int(k * 8), Color(0.88, 0.92, 1.0, 1.0 - k * 0.9), true)

## The animation for what a person's hands are doing (u.doing, set by the sim).
const DOING_ANIM := {"fight": "attack", "ritual": "ritual", "dance": "ritual", "pick": "gather", "craft": "gather", "watch": "gather",
	"till": "chop", "net": "gather", "build": "build", "experiment": "build", "paint": "build", "chop": "chop", "butcher": "chop", "quarry": "chop"}

## The feathers a person's ranks put in their hair (ranks.marks): one per ranked skill,
## fanned out behind the head; a Master's is longer and gold-tipped.
func _rank_feathers(u, at: Vector2, f: float) -> void:
	var ms: Array = sim.ranks.marks(u)
	for i in mini(ms.size(), 3):
		var m: Dictionary = ms[i]
		var ln: float = 10.0 if m["master"] else 7.0
		var dir := Vector2(-0.35 * f - i * 0.3 * f, -1).normalized()
		var tip: Vector2 = at + dir * ln
		var side := Vector2(-dir.y, dir.x) * 1.6
		ci.draw_colored_polygon(PackedVector2Array([at, at + dir * ln * 0.5 + side, tip, at + dir * ln * 0.5 - side]), m["color"])
		ci.draw_line(at, tip, m["color"].darkened(0.35), 0.8)
		if m["master"]: ci.draw_circle(tip, 1.4, Color("#ffd36b"))

func _draw_unit_sprite(u, b: Vector2, key: String, walk: bool, busy: bool) -> void:
	var di := _dir_index(key)
	var anim := "idle"
	if busy: anim = DOING_ANIM[u.doing]
	if walk and (anim == "gather" or anim == "idle"): anim = "walk"
	var pose: String = u.job.get("pose", "") # (life.gd: sitting at the fire, talking, a chore)
	if pose != "" and not walk and art.has("man_%s_0_0" % pose): anim = pose
	if anim in ["chop", "build", "attack"] and (walk and anim != "attack"): anim = "walk"
	var frames: int = {"idle": 1, "walk": 8, "sit": 2}.get(anim, 4)
	var speed := 11.0 if anim == "walk" else 7.0
	var name := "man_%s_%d_%d" % [anim, di, int(anim_t * speed + u.id) % frames]
	if anim == "attack": # (each weapon fights its own way: art_baker WEAPON_ANIMS; the spear is the plain attack)
		var wn := "man_attack_%s_%d_%d" % [str(sim.arms.wielded(u).get("id", "")), di, int(anim_t * speed + u.id) % frames]
		if art.has(wn): name = wn
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
	_rank_feathers(u, head + Vector2(-2.5 * f, -2), f)
	if u.carry_amt > 0:
		var bk := hip + Vector2(-5 * f, -6)
		if u.carry_type == "wood":
			ci.draw_line(bk + Vector2(-3, 3), bk + Vector2(3, -5), Color("#7a4e28"), 3)
			ci.draw_line(bk + Vector2(-1, 4), bk + Vector2(5, -3), Color("#8a5a32"), 3)
		elif u.carry_type == "stone":
			ci.draw_circle(bk, 3.5, Color("#9a968c"))
		else:
			ci.draw_circle(bk, 3.5, Color("#b03a2e"))
	if u.ox and u.job.get("type", "") == "gather":
		var behind: Vector2 = -heading.get(key, Vector2(0.6, 0.8)) * 18.0
		if not _beast_sprite("packox", key, b + behind, 0.8): _pack_ox(b + Vector2(-17 * f, 3), f, walk)
	if u.job.get("load", "") == "water": # a waterskin on the hip
		var ws := hip + Vector2(5 * f, -2)
		_ell(ws, 3.2, 4.2, Color("#7a5232"))
		ci.draw_circle(ws + Vector2(0, -4), 1.2, Color("#4a3020"))
	if _has_torch(u):
		var th := hip + Vector2(-6 * f, -4)
		ci.draw_line(th, th + Vector2(-2 * f, -14), Color("#6b4524"), 2)
		_flame(th + Vector2(-2 * f, -14), 3, 9 * (1.0 + 0.2 * sin(t * 14 + u.id)), Color("#f8a531"))
	if u.doing == "ritual":
		_ell_line(b - Vector2(0, 2), 15 + sin(t * 3) * 3, 7, Color(0.75, 0.6, 1.0, 0.6), 1.5)
		for i in 3:
			var kk := fmod(t * 0.7 + i / 3.0, 1.0)
			ci.draw_circle(b + Vector2(sin(t * 2 + i * 2) * 10, -10 - 30 * kk), 1.8, Color(0.8, 0.7, 1, 1 - kk))

## The procedural tree (also under the flames of a burning one).
func _draw_tree_shape(n, b: Vector2) -> void:
	var s: float = n.sz
	var east: bool = not D.home_side(n.pos)
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

## Natural finds (foods, medicines, ores): small hand-drawn props. Picked-over plants look bare.
func _draw_find(n, b: Vector2) -> void:
	var full: bool = n.amount >= 1
	var a := 1.0 if full else 0.45
	var snow: bool = sim.hz.snow > 0.5
	var look: String = D.FINDS.get(n.kind, {}).get("look", n.kind) # culture finds borrow a look
	match look:
		"mushroom":
			_ell(b + Vector2(2, 1), 10, 3.5, SHADOW)
			for i in (3 if full else 1):
				var q := b + Vector2(-6 + i * 6, (i % 2) * 2.0)
				ci.draw_line(q, q + Vector2(0, -5), Color(0.93, 0.9, 0.82, a), 2)
				_ell(q + Vector2(0, -6), 4.5, 2.6, Color(0.72, 0.2, 0.16, a) if (n.id + i) % 2 == 0 else Color(0.62, 0.42, 0.24, a))
				ci.draw_circle(q + Vector2(-1.5, -7), 0.9, Color(1, 1, 1, a))
		"tubers":
			_ell(b, 11, 4.5, Color(0.42, 0.3, 0.18, 0.85))
			for i in 4:
				var q := b + Vector2(-7 + i * 5, -1 + (i % 2) * 2)
				ci.draw_line(q, q + Vector2(-2 + i, -9), Color(0.3, 0.55, 0.22, a), 2)
				_ell(q + Vector2(-2 + i, -10), 3, 1.6, Color(0.36, 0.64, 0.26, a))
			if full:
				for i in 2: _ell(b + Vector2(-3 + i * 6, 1), 2.6, 1.6, Color("#9a6a3a"))
		"grain":
			for i in 9:
				var q := b + Vector2(-10 + i * 2.5, (i % 3) * 1.5)
				var h := 10.0 + float((n.id + i * 7) % 5)
				var col := Color(0.86, 0.72, 0.34, a) if not snow else Color(0.8, 0.78, 0.7, a)
				ci.draw_line(q, q + Vector2(1, -h), col.darkened(0.2), 1.2)
				if full: _ell(q + Vector2(1.5, -h - 2), 1.4, 3, col)
		"honey":
			_ell(b + Vector2(5, 2), 10, 4, SHADOW)
			ci.draw_rect(Rect2(b.x - 4, b.y - 26, 8, 26), Color("#5e4128"))
			ci.draw_line(b + Vector2(-4, -26), b + Vector2(-9, -34), Color("#5e4128"), 3)
			if full:
				_ell(b + Vector2(5, -16), 5, 7, Color("#d9a33a"))
				for i in 3: ci.draw_line(b + Vector2(1, -20 + i * 4), b + Vector2(9, -20 + i * 4), Color("#8a5a1c"), 1)
				for i in 3: ci.draw_circle(b + Vector2(10 + i * 3, -24 + (i % 2) * 5), 1, Color(0.1, 0.08, 0.02))
		"fish":
			if sim.hz.winter():
				_ell(b, 13, 5, Color(0.86, 0.92, 1.0, 0.75))
			else:
				for i in 2: _ell_line(b + Vector2(0, -1), 7 + i * 5, 2.5 + i * 2, Color(1, 1, 1, 0.35 * a), 1)
				if full:
					for i in 2:
						var q := b + Vector2(-5 + i * 9, -3 - i * 2)
						_ell(q, 4, 1.6, Color("#b8c8d0"))
						ci.draw_colored_polygon(PackedVector2Array([q + Vector2(3.5, 0), q + Vector2(6.5, -2), q + Vector2(6.5, 2)]), Color("#9aaab4"))
		"willow":
			_ell(b + Vector2(5, 2), 10, 4, SHADOW)
			ci.draw_line(b, b + Vector2(1, -20), Color("#6a5236"), 3)
			var top := b + Vector2(1, -22)
			ci.draw_circle(top, 9, Color(0.5, 0.62, 0.3, a))
			for i in 7:
				var x := -9.0 + i * 3.0
				ci.draw_line(top + Vector2(x, -2), top + Vector2(x * 1.2, 14 - absf(x) * 0.6), Color(0.62, 0.72, 0.36, a), 1.3)
		"yarrow":
			for i in 4:
				var q := b + Vector2(-8 + i * 5, (i % 2) * 2)
				ci.draw_line(q, q + Vector2(0, -9), Color(0.36, 0.55, 0.3, a), 1.3)
				if full: ci.draw_circle(q + Vector2(0, -10), 2.4, Color(0.96, 0.95, 0.88))
		"flint":
			_ell(b + Vector2(4, 2), 11, 4, SHADOW)
			for i in 3:
				var q := b + Vector2(-6 + i * 6, (i % 2) * 2)
				ci.draw_colored_polygon(PackedVector2Array([q + Vector2(-4, 0), q + Vector2(-2, -6), q + Vector2(3, -5), q + Vector2(4, 0)]), Color(0.2, 0.2, 0.24, a))
				ci.draw_line(q + Vector2(-2, -6), q + Vector2(3, -5), Color(0.6, 0.62, 0.7, a), 1)
		"copper", "tin":
			var k: float = clampf(n.amount / 40.0, 0.5, 1.0)
			var rock := Color("#7c6e60") if look == "copper" else Color("#4c4c54")
			_ell(b + Vector2(7, 3), 18 * k, 7 * k, SHADOW)
			for i in 2:
				var q := b + Vector2((i * 2 - 1) * 7 * k, i * 2)
				var h := (13.0 - i * 3.0) * k
				ci.draw_colored_polygon(PackedVector2Array([q + Vector2(-8, 0) * k, q + Vector2(-6 * k, -h), q + Vector2(2 * k, -h - 3 * k), q + Vector2(8, 0) * k]), rock)
				if look == "copper":
					ci.draw_line(q + Vector2(-4 * k, -h * 0.4), q + Vector2(3 * k, -h * 0.8), Color("#4fb08a"), 2)
				else:
					ci.draw_circle(q + Vector2(-1, -h * 0.6), 1.3, Color("#e8eef4"))
					ci.draw_circle(q + Vector2(3, -h * 0.3), 1, Color("#e8eef4"))
		"ochre":
			_ell(b, 13, 5, Color(0.66, 0.26, 0.16, 0.8 * a + 0.2))
			for i in 3: _ell(b + Vector2(-6 + i * 6, -2), 3, 2, Color(0.76, 0.32, 0.2, a))
		"obsidian":
			_ell(b + Vector2(4, 2), 12, 4, SHADOW)
			for i in 3:
				var q := b + Vector2(-7 + i * 7, (i % 2) * 2)
				ci.draw_colored_polygon(PackedVector2Array([q + Vector2(-4, 0), q + Vector2(-1, -9 + i), q + Vector2(4, 0)]), Color(0.08, 0.06, 0.1, a))
				ci.draw_line(q + Vector2(-1, -9 + i), q + Vector2(2, -2), Color(0.55, 0.5, 0.75, a), 1.2)
		"salt":
			_ell(b, 13, 5, Color(0.92, 0.92, 0.88, 0.85 * a + 0.15))
			for i in 4: ci.draw_circle(b + Vector2(-8 + i * 5, -1 + (i % 2)), 1.6, Color(1, 1, 1, a))

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

## Name labels. A crowd at the fire would be a heap of names, so by default only the people a
## player is looking for are named (name_priority() > 0); everyone is when show_all_names().
## A label that would cover one already drawn this frame is left out (_label_room), so the
## more important ones go first: picked and hovered people, title holders, the hurt and those
## fighting, then the big popups, the small popups, and ordinary names last.
const NAMES_ZOOM := 1.9 # zoomed in at least this far, everyone is named
const NAME_ALWAYS := 3 # priority from which a name is drawn even over another label
var names_all := false # the player's "Always show names" setting (hud.gd)
var alt_held := false # Alt held over the map: every name, as long as it is held
var _label_rects: Array[Rect2] = [] # the labels drawn this frame (_label_room)

## Whether every person is named now: the setting, Alt held, or zoomed in close.
func show_all_names() -> bool:
	return names_all or alt_held or cam.zoom.x >= NAMES_ZOOM

## How much a person's name matters on the map: 4 picked or under the cursor, 3 a title
## holder, 2 hurt or fighting, 0 anyone else (named only when show_all_names()).
func name_priority(u) -> int:
	if u.id in selected or u.id == hover_unit: return 4
	if u.title != "": return 3
	if u.hp < u.max_hp - 0.5 or u.doing == "fight": return 2
	return 0

## Whether a label at `p` has room (it covers none drawn this frame); if so, or `force`,
## it is counted as drawn.
func _label_room(p: Vector2, text: String, size: int, force := false) -> bool:
	var w: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var r := Rect2(p.x - w / 2 - 2, p.y - size, w + 4, size + 4)
	if not force:
		for o in _label_rects:
			if o.intersects(r): return false
	_label_rects.append(r)
	return true

func _unit_base(u) -> Vector2:
	var b := iso(u.pos) * 1.0
	if u.role == "child": b += Vector2(0, 14) # (smaller figure, lower label)
	return b

func _draw_unit_name(u, force: bool) -> void:
	var at := _unit_base(u) + Vector2(0, -46)
	var title: String = ("★ " if u.title != "" else "") + tr(u.name)
	if not _label_room(at, title, 14, force): return
	_draw_label(at, title, 14, Color("#ffe066") if u.id in selected else Color("#fff4d6"), true)

func _draw_unit_bar(u) -> void:
	if u.hp < u.max_hp - 0.5: _bar(_unit_base(u) + Vector2(0, 6), 24, u.hp / u.max_hp, Color("#e05050") if u.hp < u.max_hp * 0.35 else Color("#6fd06f"))

## Speech situations that have a bubble icon (life.gd talk kinds).
const SAY_ICONS := ["hungry", "cold", "sick", "chat", "friend", "praise", "grief", "quarrel"]

## A speech mark: out at map zoom, a small icon bubble a player can read at a glance;
## up close (or for freeform lines from a game master), the words themselves.
func _speech(at: Vector2, u, left: float) -> void:
	if cam.zoom.x < 1.2 and u.say_kind in SAY_ICONS:
		_icon_bubble(at, u.say_kind, left)
		return
	var text: String = u.say
	var a := clampf(left / 0.4, 0.0, 1.0)
	var size := 12
	var w: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x + 12.0
	var r := Rect2(at.x - w / 2, at.y - 17, w, 19)
	var bg := Color(0.98, 0.95, 0.86, 0.92 * a)
	ci.draw_colored_polygon(PackedVector2Array([at + Vector2(-5, 1), at + Vector2(5, 1), at + Vector2(0, 8)]), bg)
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(7)
	sb.border_color = Color(0.3, 0.22, 0.12, 0.5 * a)
	sb.set_border_width_all(1)
	ci.draw_style_box(sb, r)
	ci.draw_string(font, Vector2(r.position.x + 6, r.position.y + 14), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0.22, 0.15, 0.08, a))

## A round speech bubble with one small pictogram inside, fading out at the end.
func _icon_bubble(at: Vector2, kind: String, left: float) -> void:
	var a := clampf(left / 0.4, 0.0, 1.0)
	var bg := Color(0.98, 0.95, 0.86, 0.92 * a)
	var c := at - Vector2(0, 14)
	ci.draw_colored_polygon(PackedVector2Array([at + Vector2(-4, 1), at + Vector2(4, 1), at + Vector2(0, 8)]), bg)
	ci.draw_circle(c, 10.0, bg)
	ci.draw_arc(c, 9.5, 0, TAU, 24, Color(0.3, 0.22, 0.12, 0.5 * a), 1.0)
	_say_icon(kind, c, a)

## One pictogram per situation, drawn in code (no art needed): what the person means,
## readable even when the words would be a smear.
func _say_icon(kind: String, c: Vector2, a: float) -> void:
	match kind:
		"hungry": # a morsel on a bone
			ci.draw_line(c + Vector2(-4, 4), c + Vector2(3, -3), Color(0.91, 0.86, 0.75, a), 1.6)
			ci.draw_circle(c + Vector2(-4, 4), 1.7, Color(0.91, 0.86, 0.75, a))
			_ell(c + Vector2(3.5, -3.5), 3.2, 2.4, Color(0.69, 0.35, 0.23, a))
		"cold": # a snowflake
			for i in 3:
				var d := Vector2.from_angle(i * TAU / 6.0) * 4.0
				ci.draw_line(c - d, c + d, Color(0.42, 0.68, 0.95, a), 1.4)
		"sick": # a cross
			ci.draw_line(c + Vector2(0, -3.5), c + Vector2(0, 3.5), Color(0.5, 0.8, 0.4, a), 2.2)
			ci.draw_line(c + Vector2(-3.5, 0), c + Vector2(3.5, 0), Color(0.5, 0.8, 0.4, a), 2.2)
		"chat": # three dots
			for i in 3:
				ci.draw_circle(c + Vector2(-4 + i * 4, 0), 1.5, Color(0.35, 0.28, 0.18, a))
		"friend": # a heart
			var red := Color(0.85, 0.3, 0.35, a)
			ci.draw_circle(c + Vector2(-1.8, -1.5), 2.4, red)
			ci.draw_circle(c + Vector2(1.8, -1.5), 2.4, red)
			ci.draw_colored_polygon(PackedVector2Array([c + Vector2(-3.9, -0.6), c + Vector2(3.9, -0.6), c + Vector2(0, 4.5)]), red)
		"praise": # a four-point sparkle
			var gold := Color(0.95, 0.78, 0.25, a)
			ci.draw_line(c + Vector2(0, -5), c + Vector2(0, 5), gold, 1.6)
			ci.draw_line(c + Vector2(-5, 0), c + Vector2(5, 0), gold, 1.6)
			ci.draw_circle(c, 1.4, gold)
		"grief": # a teardrop
			var blue := Color(0.45, 0.62, 0.9, a)
			ci.draw_circle(c + Vector2(0, 1.5), 3.0, blue)
			ci.draw_colored_polygon(PackedVector2Array([c + Vector2(-2.2, -0.2), c + Vector2(2.2, -0.2), c + Vector2(0, -5)]), blue)
		"quarrel": # a sharp red exclamation
			var hot := Color(0.85, 0.25, 0.2, a)
			ci.draw_line(c + Vector2(0, -4.5), c + Vector2(0, 1.5), hot, 2.2)
			ci.draw_circle(c + Vector2(0, 4.2), 1.5, hot)

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
		var name := "man_%s_%d_%d" % [anim, di, int(anim_t * (11.0 if anim == "walk" else 7.0) + p.id) % frames]
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
		_sprite("dragon_%d_%d" % [_dir_index("g"), int(anim_t * 6.0) % 4], c, 1.3)
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
			var ring: bool = build_type != "" and build_type != "road" and D.STRUCTURES[build_type].get("ring", false)
			if mb.pressed and build_type == "road": # a road: its start, then its end
				if road_start == null: road_start = m
				else:
					var err: String = sim.roads.lay(road_start, m, sim.roads.best_buildable(), selected_units().filter(func(u): return u.role != "contract"))
					if err != "": sim.popup(m, tr(err), Color("#ff8080"))
					road_start = null
					if err == "" and not Input.is_key_pressed(KEY_SHIFT): build_type = ""
			elif mb.pressed:
				if ring and wall_center == null: # a wall: first its middle...
					wall_center = m
					drag_start = sm
				elif ring: # ...then a second click at the radius
					_place(wall_center)
					drag_start = null
				elif build_type != "":
					_place(m)
				else:
					drag_start = sm
			elif ring and wall_center != null and drag_start != null: # (or press, drag and let go)
				if (drag_start as Vector2).distance_to(sm) >= WALL_DRAG: _place(wall_center)
				drag_start = null
			elif drag_start != null:
				if (drag_start as Vector2).distance_to(sm) < 6 / cam.zoom.x: _click_select(sm, mb.shift_pressed)
				else: _box_select(Rect2(drag_start, sm - drag_start).abs(), mb.shift_pressed)
				drag_start = null
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if wall_center != null: wall_center = null # (back to picking the middle)
			elif road_start != null: road_start = null # (back to picking the start)
			elif build_type != "": build_type = ""
			else: _command(sm)
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			mid_drag = mb.pressed
		elif mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			_zoom_by(1.1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1 / 1.1)
	elif ev is InputEventPanGesture: # trackpad two-finger swipe (macOS) -> pan
		cancel_glide()
		cam.position += (ev as InputEventPanGesture).delta * PAN_GESTURE_SPEED / cam.zoom.x
		_clamp_cam()
	elif ev is InputEventMagnifyGesture: # trackpad pinch -> zoom
		_zoom_by((ev as InputEventMagnifyGesture).factor)
	elif ev is InputEventMouseMotion and mid_drag:
		cancel_glide()
		cam.position -= (ev as InputEventMouseMotion).relative / cam.zoom.x
		_clamp_cam()

func selected_units() -> Array:
	return selected.map(func(id): return sim.unit_by_id(id)).filter(func(u): return u != null and not u.dead)

func select_only(u) -> void:
	selected = [u.id] if u else []
	selected_struct = -1
	selection_changed.emit()

## Screen-space distance from the cursor to an upright figure (base or body).
func _pick_dist(sm: Vector2, world_pos: Vector2, height: float) -> float:
	var b := iso(world_pos)
	return minf(sm.distance_to(b), minf(sm.distance_to(b - Vector2(0, height * 0.5)), sm.distance_to(b - Vector2(0, height))))

func _click_select(sm: Vector2, add: bool) -> void:
	var best = null
	var bd := 16.0
	for u in sim.units:
		if u.dead or sim.in_hut(u): continue
		var d := _pick_dist(sm, u.pos, 34)
		if d < bd:
			bd = d
			best = u
	if best == null:
		var bs = structure_at(uniso(sm))
		if bs and bs.type == "burial_ground" and bs.built:
			structure_clicked.emit(bs)
			return
		if bs and not add:
			selected = []
			selected_struct = bs.id
			selection_changed.emit()
			return
	selected_struct = -1
	if not add: selected = []
	if best:
		if best.id in selected: selected.erase(best.id)
		else: selected.append(best.id)
	selection_changed.emit()

## The building at world point m (walls only near their ring), or null.
func structure_at(m: Vector2):
	var best = null
	var bd := INF
	for s in sim.structures:
		if not sim.is_explored(s.pos): continue
		var r: float = sim.struct_r(s)
		var d: float = s.pos.distance_to(m)
		if D.STRUCTURES[s.type].get("ring", false):
			d = absf(d - r)
			r = 14.0
		elif d > r + 8.0: continue
		if d < r + 8.0 and d < bd:
			bd = d
			best = s
	return best

func _box_select(r: Rect2, add: bool) -> void:
	selected_struct = -1
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
	var size: float = build_size if D.STRUCTURES[build_type].get("ring", false) else 0.0
	wall_center = null
	var s = sim.place_structure(build_type, m, size)
	if s == null:
		sim.popup(m, tr(sim.can_place(build_type, m, size)), Color("#ff8080"))
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
		var d := _pick_dist(sm, n.pos, {"tree": 40.0, "boulder": 26.0}.get(n.kind, 12.0)) # (a boulder's rocks stand tall)
		if d < bd:
			bd = d
			node = n
	if node:
		for u in free: sim.assign_gather(u, node.res, {"node_id": node.id, "bank": D.region_at(node.pos)})
		return
	for s in sim.structures:
		var r: float = sim.struct_r(s)
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

# ------------------------------------------------------------ hover info
## What is under the cursor, for the HUD's map tooltip: [title, body] or [] for nothing.
func hover_info() -> Array:
	if _ui_has_pointer() or build_type != "": return []
	var sm := get_global_mouse_position()
	var m := uniso(sm)
	for p in sim.predators:
		if not p.dead and not p.fled and sim.is_visible(p.pos) and _pick_dist(sm, p.pos, 28) < 20:
			if p.clan != "":
				var c: Dictionary = sim.rivals.clans[p.clan]
				return [tr(p.name), tr("Of the %s (%s).") % [tr(c["name"]), tr(sim.rivals.stance(p.clan))]]
			return [tr(p.name), tr("A dangerous beast. Fight it with several people, or stay near the fires.")]
	var best = null
	var bd := 18.0
	for n in sim.nodes:
		if not (sim.is_visible(n.pos) if n.kind == "deer" else sim.is_explored(n.pos)): continue
		var d := _pick_dist(sm, n.pos, {"tree": 40.0, "boulder": 26.0}.get(n.kind, 12.0)) # (a boulder's rocks stand tall)
		if d < bd:
			bd = d
			best = n
	if best: return _node_info(best)
	for s in sim.structures:
		if not sim.is_explored(s.pos): continue
		var sd: Dictionary = D.STRUCTURES[s.type]
		var r: float = sim.struct_r(s)
		var hit: bool = absf(s.pos.distance_to(m) - r) < 14 if sd.get("ring", false) else s.pos.distance_to(m) < r + 10
		if hit: return _struct_info(s)
	for lm in sim.landmarks:
		if sim.is_explored(lm["pos"]) and lm["pos"].distance_to(m) < 70:
			return [tr(lm["name"]), tr("Visited by the tribe.") if lm["found"] else tr("Not yet visited: send someone there to see what it holds.")]
	if D.in_river(m) and D.is_ford_at(m): return [tr("The Ford"), tr("A shallow crossing of the river. People and beasts wade across here; elsewhere the river is too deep.")]
	return []

func _node_info(n) -> Array:
	if D.FINDS.has(n.kind):
		var fd: Dictionary = D.FINDS[n.kind]
		if not sim.knows_find(n.kind):
			var hint: String = tr("Walk someone up to it to find out.") # (someone in the tribe can tell what it is)
			if not sim.living().any(func(o): return o.role != "child" and sim.can_recognise(o, n.kind)): # (nobody yet: say who could)
				hint = {"lore": tr("Someone with Lore might know what it is."), "tools": tr("Someone who knows stone-working might know what it is.")}.get(fd.get("needs", ""), hint)
			return [tr("Something unfamiliar"), hint]
		return [tr(fd["name"]), tr(fd["desc"]) + "\n" + (tr("Left: %d") % roundi(n.amount))]
	match n.kind:
		"tree": return [tr("Tree"), tr("Wood: %d left. Felled trees regrow in time.") % roundi(n.amount)]
		"stump", "burnt": return [tr("Stump") if n.kind == "stump" else tr("Burnt tree"), tr("A tree will grow here again.")]
		"bush": return [tr("Berry bush"), tr("Food: %d. Berries regrow, but not in winter.") % roundi(n.amount)]
		"boulder":
			if sim.has_tech("tools"): return [tr("Stone outcrop"), tr("Stone: %d. Right-click with people selected to quarry it.") % roundi(n.amount)]
			return [tr("Stone outcrop"), tr("Stone: %d. Needs Polished Stone Tools to quarry.") % roundi(n.amount)]
		"deer": return [tr("Deer"), tr("Hunt it for food. Half the herds leave in winter.")]
		"carcass": return [tr("Carcass"), tr("Meat to butcher: %d food.") % roundi(n.amount)]
	return []

func _struct_info(s) -> Array:
	var sd: Dictionary = D.STRUCTURES[s.type]
	var title: String = tr(sd["name"])
	if not sim.ours(s):
		var cid: String = s.owner.trim_prefix("rival:")
		return [title, tr("Belongs to the %s.") % tr(sim.rivals.clans[cid]["name"])]
	var body: String = tr(sd.get("desc", ""))
	if not s.built:
		body = (tr("Being built: %d%%.") % roundi(s.progress / s.work * 100.0) if s.paid else tr("Awaiting wood.")) + "\n" + body
	if s.type in sim.SHELTERS and s.built:
		var inside: Array = sim.units.filter(func(u): return not u.dead and u.bed_id == s.id and u.sleeping).map(func(u): return tr(u.name))
		if not inside.is_empty(): body += "\n" + tr("Asleep inside: %s") % ", ".join(inside)
	if s.type == "burial_ground" and not s.graves.is_empty():
		body += "\n" + tr("Here lie: %s") % ", ".join(s.graves.map(func(g): return tr(g["name"])))
	if s.type == "aurochs_pen": body += "\n" + tr("Oxen %d/%d") % [sim.oxen, sim.ox_cap()]
	return [title, body]

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

class Ghost extends Node2D:
	var wv
	func _draw() -> void:
		wv.ci = self
		wv.draw_ghost()
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
		5: _draw_post(iso(obj[0]), obj[1], obj[2], obj[3], obj[4] if obj.size() > 4 else false, obj[5] if obj.size() > 5 else false)
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

## Resource nodes are thousands in a deep forest: all of them are synced every few frames
## (new and gone ones, fog, regrowth), the moving ones (deer, burning trees) every frame.
const NODE_FULL_EVERY := 6
var _node_frame := 0
var _moving_nodes: Array = []

func _sync_items() -> void:
	var seen := {}
	_node_frame += 1
	var full := _node_frame % NODE_FULL_EVERY == 0 or _node_frame < 3
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
	if full: _moving_nodes.clear()
	var wk := wind_k()
	var wind_sig := 1000000 * int(round(wk * 6.0)) if wk >= 0.3 else 0 # gusts re-bend the crowns
	var wind_view := view.grow(200.0) # tall crowns reach in from just off the edge
	for n in (sim.nodes if full else _moving_nodes):
		var key := "n%d" % n.id
		seen[key] = true
		var anim: bool = n.kind == "deer" or sim.nat.burning.has(n.id)
		if full and anim: _moving_nodes.append(n)
		var it := _item(key, 0, n, iso(n.pos), anim)
		if it.dynamic != anim: it.dynamic = anim
		it.visible = sim.is_visible(n.pos) if n.kind == "deer" else sim.is_explored(n.pos)
		var sig: int = n.kind.length() * 1000 + int(n.amount / 5) + (100000 if sim.hz.snow > 0.5 else 0)
		if n.kind == "tree" and wind_sig != 0: # in a wind only trees near the screen re-bend; the rest catch up when seen
			sig = sig + wind_sig if wind_view.has_point(it.position) else it.sig
		_touch(it, sig)
	for lm in sim.landmarks:
		var key: String = "lm_" + lm["id"]
		seen[key] = true
		var it := _item(key, 6, lm, iso(lm["pos"]), lm["kind"] in ["den", "stones", "peak", "spring", "volcano"])
		it.visible = sim.is_explored(lm["pos"])
		_touch(it, 0)
	for st in sim.structures:
		var exp: bool = sim.is_explored(st.pos)
		if D.STRUCTURES[st.type].get("ring", false):
			var sdr: Dictionary = D.STRUCTURES[st.type]
			var r: float = sim.struct_r(st)
			var cnt := maxi(16, roundi(64.0 * r / float(sdr["r"]))) # (stakes as close as ever)
			var stone: bool = sdr.get("stakes", "") == "stone"
			var tower_every: int = int(sdr.get("tower_every", 0))
			var shown: int = cnt if st.built else int(cnt * st.progress / st.work)
			# buildings standing on the wall's line make gates in it (no stakes through a hut)
			var in_way: Array = sim.structures.filter(func(o): return o != st and not D.STRUCTURES[o.type].get("ring", false) \
				and absf(o.pos.distance_to(st.pos) - r) < D.STRUCTURES[o.type]["r"] + PALISADE_GAP)
			for i in cnt:
				var pp: Vector2 = st.pos + Vector2.from_angle(float(i) / cnt * TAU) * r
				var key := "s%d_%d" % [st.id, i]
				seen[key] = true
				var it := _item(key, 5, [pp, i < shown, st.built, st.style, stone, tower_every > 0 and i % tower_every == 0], iso(pp), false)
				it.visible = exp and not in_way.any(func(o): return o.pos.distance_to(pp) < D.STRUCTURES[o.type]["r"] + PALISADE_GAP)
				it.modulate = _pick_glow(st)
				_touch(it, (2 if i < shown else 0) + (1 if st.built else 0) + st.style * 10)
		elif st.type == "roadworks": pass # (drawn on the ground: _draw_ground_part)
		elif st.type != "farm_plot" or (st.built and art != null and art.has("farm_spring")):
			var key := "s%d" % st.id
			seen[key] = true
			var anim: bool = st.type in ["bonfire", "fishing_dock", "aurochs_pen", "smelter", "council_ring"] or not st.built or st.reno \
				or (st.type in ["hut", "large_hut"] and sim.has_tech("fire")) \
				or (st.type in ["totem_shrine", "temple", "grand_altar"] and sim.evo.era >= 3) # (era pennants flutter)
			var it := _item(key, 1, st, iso(st.pos), anim)
			if it.dynamic != anim: it.dynamic = anim
			it.visible = exp
			it.modulate = _pick_glow(st)
			_touch(it, (1 if st.built else 0) + st.style * 10 + st.graves.size() * 10000 + st.decor * 1000000 + (10000000 if sim.knows_find("ochre") else 0) + (sim.hz.season_idx() * 100 if st.type == "farm_plot" else 0) + (1000 if sim.hz.snow > 0.5 else 0))
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
		if key.begins_with("d") or (not full and key.begins_with("n")): continue # (static nodes: checked on full passes)
		if not seen.has(key):
			items[key].queue_free()
			items.erase(key)

## A hovered building lights up a touch (a picked one carries its marker: _draw_pick_marks).
func _pick_glow(st) -> Color:
	if st.id == hover_struct and st.id != selected_struct and st.built: return Color(1.12, 1.12, 1.12)
	return Color.WHITE

## The marks drawn over the scene for a pick: a gold diamond bobbing above a picked building,
## a gold chevron bobbing over each picked person (with the thin ring at their feet, _sel_ring).
func _draw_pick_marks() -> void:
	var st = sim.struct_by_id(selected_struct) if selected_struct >= 0 else null
	if st and _in_view(st.pos):
		var r: float = sim.struct_r(st) + 8.0
		_diamond(iso(st.pos) + Vector2(0, -r * 1.7 - 22.0 + sin(t * 3.0) * 5.0), 9.0)
	for id in selected:
		var u = sim.unit_by_id(id)
		if u == null or u.dead or sim.in_hut(u) or not _in_view(u.pos): continue
		var p := iso(u.pos) + Vector2(0, -72 + sin(t * 4.0 + u.id) * 3.0) # (just above the name label)
		for w in [[5.0, Color(0, 0, 0, 0.4)], [2.6, SEL_COL]]:
			ci.draw_polyline(PackedVector2Array([p + Vector2(-7, -5), p, p + Vector2(7, -5)]), w[1], w[0])

func _diamond(c: Vector2, r: float) -> void:
	var pts := PackedVector2Array([c + Vector2(0, -r * 1.3), c + Vector2(r, 0), c + Vector2(0, r * 1.3), c + Vector2(-r, 0)])
	ci.draw_colored_polygon(pts, SEL_COL)
	pts.append(pts[0])
	ci.draw_polyline(pts, Color(0.25, 0.16, 0.05, 0.8), 1.5)

func _touch(it: Item, sig: int) -> void:
	if it.dynamic:
		if it.visible: it.queue_redraw()
	elif it.sig != sig:
		it.sig = sig
		it.queue_redraw()
