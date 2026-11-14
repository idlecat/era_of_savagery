## 2.5D isometric renderer (Age-of-Empires-style diamond map) + Tier 1 RTS input.
## The simulation stays in flat world coordinates; only drawing and picking are
## projected: ground features are drawn through an isometric transform, upright
## objects (trees, huts, people, beasts) are drawn in screen space at iso(pos) and
## depth-sorted by x+y so nearer things overlap farther ones.
extends Node2D

const D = preload("res://scripts/data.gd")

signal selection_changed()

const IX := 0.75   # iso projection: screen = ((x-y)*IX, (x+y)*IY), 2:1 diamond
const IY := 0.375
const GROUND := Transform2D(Vector2(IX, IY), Vector2(-IX, IY), Vector2.ZERO)
const TEX_SCALE := 3 # terrain texture = world / 3 pixels

var sim
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
var decor: Array = []
var river_l := PackedVector2Array()
var river_r := PackedVector2Array()
var cmd_marker := {}
var guardian_trail: Array = []
var facing := {} # "u12" -> 1 / -1  (screen-space left/right)
var last_pos := {}
var moving := {}
var t := 0.0
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
	font = ThemeDB.fallback_font
	cam = Camera2D.new()
	cam.zoom = Vector2(1.25, 1.25)
	cam.position = iso(Vector2(760, 560))
	add_child(cam)
	cam.make_current()
	night = CanvasModulate.new()
	add_child(night)
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
	var w := int(D.W / TEX_SCALE)
	var h := int(D.H / TEX_SCALE)
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
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
				if D.is_ford(p.y): c = ford.lerp(shallow, 0.3 * k).lerp(Color("#9a9682"), 0.35 * f)
			elif dx < D.RIVER_HALF + 12 + 8 * n:
				c = sand.lerp(Color("#8f8058"), f * 0.6)
			else:
				var east := p.x > D.river_x(p.y)
				c = (g_east_a.lerp(g_east_b, n) if east else g_west_a.lerp(g_west_b, n))
				c = c.lerp(c.darkened(0.18), f * 0.5)
				var dv := p.distance_to(D.VILLAGE)
				if dv < 170:
					c = c.lerp(dirt.lerp(dirt.darkened(0.15), f), clampf((170 - dv) / 110.0, 0, 0.85) * (0.6 + 0.4 * n))
				if not east and n > 0.72: c = c.lerp(Color("#879b4a"), (n - 0.72) * 2.0)
			img.set_pixel(i, j, c)
	terrain_tex = ImageTexture.create_from_image(img)
	for i in 520:
		var p := Vector2(randf() * D.W, randf() * D.H)
		if absf(p.x - D.river_x(p.y)) < D.RIVER_HALF + 14: continue
		var east := D.bank_of(p) == "east"
		var r := randf()
		var kind := "tuft"
		if r < 0.06: kind = "rock"
		elif r < 0.12 and not east: kind = "flower"
		decor.append({"p": p, "east": east, "kind": kind, "tall": east and randf() < 0.7, "c": randf_range(-0.05, 0.05), "s": randf_range(0.7, 1.3)})
	decor.sort_custom(func(a, b): return a["p"].x + a["p"].y < b["p"].x + b["p"].y)

# ------------------------------------------------------------ frame
func _process(delta: float) -> void:
	t += delta
	_pan_keys(delta)
	night.color = Color.WHITE.lerp(Color(0.30, 0.34, 0.55), sim.night_amt * 0.85)
	_sync_lights()
	if sim.guardian and not sim.guardian.dead:
		guardian_trail.push_front(sim.guardian.pos)
		if guardian_trail.size() > 40: guardian_trail.pop_back()
	for u in sim.units: _track("u%d" % u.id, u.pos)
	for p in sim.predators: _track("p%d" % p.id, p.pos)
	for n in sim.nodes:
		if n.kind == "deer": _track("n%d" % n.id, n.pos)
	queue_redraw()

func _track(key: String, p: Vector2) -> void:
	var s := iso(p)
	if last_pos.has(key):
		var dv: Vector2 = s - last_pos[key]
		moving[key] = dv.length() > 0.05
		if absf(dv.x) > 0.05: facing[key] = 1 if dv.x > 0 else -1
	last_pos[key] = s

func _pan_keys(delta: float) -> void:
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or focus is SpinBox: return
	if blocked.is_valid() and blocked.call(): return # map is frozen behind dialogs
	var v := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT): v.x -= 1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT): v.x += 1
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP): v.y -= 1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN): v.y += 1
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
	for id in lights.keys():
		if not alive.has(id):
			lights[id].queue_free()
			lights.erase(id)

# ------------------------------------------------------------ drawing
func _draw() -> void:
	draw_rect(Rect2(-3000, -2000, 7000, 5000), Color("#141210"))
	_draw_slab()
	# ---- ground pass (flat, through the iso transform, world coordinates)
	draw_set_transform_matrix(GROUND)
	draw_texture_rect(terrain_tex, Rect2(0, 0, D.W, D.H), false)
	_draw_water_fx()
	for s in sim.structures: _draw_ground_part(s)
	for c in sim.contracts.list: _draw_site_ring(c)
	if not cmd_marker.is_empty() and t - cmd_marker["t"] < 0.6:
		var k: float = (t - cmd_marker["t"]) / 0.6
		draw_arc(cmd_marker["p"], 6 + 16 * k, 0, TAU, 24, Color(cmd_marker["c"], 1.0 - k), 3)
	var ghost_m := Vector2.ZERO
	var ghost_why := ""
	if build_type != "":
		ghost_m = uniso(get_global_mouse_position())
		ghost_why = sim.can_place(build_type, ghost_m)
		var col := Color(0.4, 1, 0.4, 0.45) if ghost_why == "" else Color(1, 0.3, 0.3, 0.45)
		var r: float = D.STRUCTURES[build_type]["r"]
		draw_circle(ghost_m, minf(r, 30), col)
		if D.STRUCTURES[build_type].get("ring", false): draw_arc(ghost_m, r, 0, TAU, 64, col, 6)
	if sim.flood_fx > 0:
		draw_rect(Rect2(0, 0, D.W, D.H), Color(0.2, 0.4, 0.75, sim.flood_fx * 0.4))
	draw_set_transform_matrix(Transform2D.IDENTITY)

	# ---- small decor (always behind upright objects at the same spot; tiny anyway)
	for d in decor: _draw_decor(d)

	# ---- upright objects, painter's algorithm by depth (x + y)
	var items: Array = []
	for n in sim.nodes: items.append([n.pos.x + n.pos.y, 0, n])
	for s in sim.structures:
		if s.type == "palisade":
			var r: float = D.STRUCTURES["palisade"]["r"]
			var cnt := 64
			var shown: int = cnt if s.built else int(cnt * s.progress / s.work)
			for i in cnt:
				var pp: Vector2 = s.pos + Vector2.from_angle(float(i) / cnt * TAU) * r
				items.append([pp.x + pp.y, 5, [pp, i < shown, s.built]])
		elif s.type != "farm_plot":
			items.append([s.pos.x + s.pos.y, 1, s])
	for u in sim.units: items.append([u.pos.x + u.pos.y, 2, u])
	for p in sim.predators:
		if not p.dead and not p.fled: items.append([p.pos.x + p.pos.y, 3, p])
	if sim.guardian and not sim.guardian.dead: items.append([sim.guardian.pos.x + sim.guardian.pos.y + 200, 4, sim.guardian])
	items.sort_custom(func(a, b): return a[0] < b[0])
	for it in items:
		match it[1]:
			0: _draw_node(it[2])
			1: _draw_structure(it[2])
			2: _draw_unit(it[2])
			3: _draw_pred(it[2])
			4: _draw_guardian(it[2])
			5: _draw_post(iso(it[2][0]), it[2][1], it[2][2])
		draw_set_transform_matrix(Transform2D.IDENTITY)

	# ---- overlay pass: labels, bars, flags (never hidden behind objects)
	_draw_label(iso(Vector2(D.river_x(D.FORD_Y1 + 30), D.FORD_Y1 + 30)) + Vector2(0, 14), "FORD", 13, Color(1, 1, 1, 0.65), true)
	_draw_label(iso(Vector2(1500, 330)), "UNTAMED EAST BANK", 20, Color(1, 1, 1, 0.4), true)
	_draw_label(iso(Vector2(300, 260)), "TRIBAL LANDS", 20, Color(1, 1, 1, 0.4), true)
	for c in sim.contracts.list: _draw_site_flag(c)
	for s in sim.structures: _draw_structure_overlay(s)
	for u in sim.units: _draw_unit_overlay(u)
	for p in sim.predators:
		if not p.dead and not p.fled: _bar(iso(p.pos) + Vector2(0, 8), 32, p.hp / p.max_hp, Color("#ff9b3a"))
	for p in sim.popups:
		var a: float = 1.0 - pow(p["t"] / p["life"], 2)
		var col: Color = p["color"]
		col.a = a
		_draw_label(iso(p["pos"]) - Vector2(0, 26), p["text"], 17 if p["big"] else 13, col, true)
	if drag_start != null:
		var m := get_global_mouse_position()
		var r := Rect2(drag_start, m - drag_start).abs()
		draw_rect(r, Color(1, 1, 0.6, 0.12))
		draw_rect(r, Color(1, 1, 0.6, 0.7), false, 1.5)
	if build_type != "":
		_draw_label(iso(ghost_m) + Vector2(0, -44), D.STRUCTURES[build_type]["name"] + ("" if ghost_why == "" else " - " + ghost_why), 14, Color.WHITE, true)

## Earthen sides of the map diamond, so the world reads as a raised slab.
func _draw_slab() -> void:
	var r := iso(Vector2(D.W, 0))
	var b := iso(Vector2(D.W, D.H))
	var l := iso(Vector2(0, D.H))
	var dn := Vector2(0, 46)
	draw_colored_polygon(PackedVector2Array([r, b, b + dn, r + dn]), Color("#4a3622"))
	draw_colored_polygon(PackedVector2Array([b, l, l + dn, b + dn]), Color("#5e4529"))
	for i in 3:
		var k := 0.3 + i * 0.22
		draw_line(r + dn * k, b + dn * k, Color(0, 0, 0, 0.18), 2)
		draw_line(b + dn * k, l + dn * k, Color(0, 0, 0, 0.18), 2)

func _draw_water_fx() -> void:
	draw_polyline(river_l, Color(0.85, 0.92, 1.0, 0.35), 3)
	draw_polyline(river_r, Color(0.85, 0.92, 1.0, 0.35), 3)
	for i in 9:
		var sy: float = lerpf(D.FORD_Y0 + 10, D.FORD_Y1 - 10, float(i % 3) / 2.0)
		var sx: float = D.river_x(sy) + lerpf(-D.RIVER_HALF + 10, D.RIVER_HALF - 10, float(i / 3) / 2.0)
		draw_circle(Vector2(sx + 2, sy + 2), 7, Color(0, 0, 0, 0.2))
		draw_circle(Vector2(sx, sy), 7, Color("#a5a291"))
	for i in 46:
		var y := fmod(i * 47.0 + t * 26.0, D.H)
		if D.is_ford(y): continue
		var x := D.river_x(y) + sin(i * 12.3) * D.RIVER_HALF * 0.6
		draw_line(Vector2(x, y), Vector2(x + 3, y + 14), Color(0.75, 0.9, 1.0, 0.35), 2)

func _draw_decor(d: Dictionary) -> void:
	var p := iso(d["p"])
	var s: float = d["s"]
	match d["kind"]:
		"rock":
			_ell(p + Vector2(3, 1), 7 * s, 3 * s, SHADOW)
			draw_colored_polygon(PackedVector2Array([p + Vector2(-6, 0) * s, p + Vector2(-4, -5) * s, p + Vector2(2, -7) * s, p + Vector2(6, -2) * s, p + Vector2(5, 1) * s]), Color("#8d8a80"))
			draw_colored_polygon(PackedVector2Array([p + Vector2(-4, -5) * s, p + Vector2(2, -7) * s, p + Vector2(0, -3) * s]), Color("#a9a69b"))
		"flower":
			draw_line(p, p + Vector2(0, -5), Color("#4f7a30"), 1)
			draw_circle(p + Vector2(0, -6), 1.8, Color("#e8d35a") if int(d["p"].x) % 2 == 0 else Color("#d7708a"))
		_:
			var c := (Color("#3f5b2d") if d["east"] else Color("#5f7f38")).lightened(0.12 + d["c"])
			var sway := sin(t * 1.5 + p.x * 0.05) * 1.5
			if d["tall"]:
				draw_line(p, p + Vector2(-3 + sway, -12) * s, c.darkened(0.15), 1.5)
				draw_line(p, p + Vector2(sway, -16) * s, c, 1.5)
				draw_line(p, p + Vector2(3 + sway, -11) * s, c.darkened(0.1), 1.5)
			else:
				draw_line(p, p + Vector2(-2, -5) * s, c, 1.0)
				draw_line(p, p + Vector2(2 + sway * 0.5, -6) * s, c, 1.0)

# ------------------------------------------------------------ primitives
## Scale subsequent drawing by k around screen point b (reset after each sorted item).
func _scale_about(b: Vector2, k: float) -> void:
	draw_set_transform(b * (1.0 - k), 0.0, Vector2(k, k))

func _ell(c: Vector2, rx: float, ry: float, col: Color, seg := 20) -> void:
	var pts := PackedVector2Array()
	for i in seg:
		var a := TAU * i / seg
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	draw_colored_polygon(pts, col)

func _ell_line(c: Vector2, rx: float, ry: float, col: Color, w := 2.0, a0 := 0.0, a1 := TAU) -> void:
	var pts := PackedVector2Array()
	var seg := 28
	for i in seg + 1:
		var a := lerpf(a0, a1, float(i) / seg)
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	draw_polyline(pts, col, w)

## Arc points of a world-space circle of radius r projected to screen (angles in screen-ellipse space).
func _arc_pts(c: Vector2, rx: float, ry: float, a0: float, a1: float, seg: int, lift := 0.0) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in seg + 1:
		var a := lerpf(a0, a1, float(i) / seg)
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry - lift))
	return pts

## Iso box centred on world point c (half-sizes in world units, height in px).
func _box(c: Vector2, hw: float, hd: float, h: float, col: Color) -> void:
	var p1 := iso(c + Vector2(-hw, -hd))
	var p2 := iso(c + Vector2(hw, -hd))
	var p3 := iso(c + Vector2(hw, hd))
	var p4 := iso(c + Vector2(-hw, hd))
	var up := Vector2(0, h)
	draw_colored_polygon(PackedVector2Array([p2, p3, p3 - up, p2 - up]), col.darkened(0.32))
	draw_colored_polygon(PackedVector2Array([p4, p3, p3 - up, p4 - up]), col.darkened(0.12))
	draw_colored_polygon(PackedVector2Array([p1 - up, p2 - up, p3 - up, p4 - up]), col.lightened(0.12))

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
			draw_line(q, q.lerp(apex, clampf(frac * 1.6, 0.2, 1.0)), Color("#7a5530"), 2.5)
		if frac > 0.45:
			var wh := wall_h * clampf((frac - 0.45) / 0.4, 0, 1)
			var pts := _arc_pts(b, rx, ry, 0, PI, 12)
			var top := _arc_pts(b, rx, ry, PI, 0, 12, wh)
			pts.append_array(top)
			if wh > 1: draw_colored_polygon(pts, wall)
		return
	var pts := _arc_pts(b, rx, ry, 0, PI, 14)
	pts.append_array(_arc_pts(b, rx, ry, PI, 0, 14, wall_h))
	draw_colored_polygon(pts, wall)
	var shade := _arc_pts(b, rx, ry, 0, PI * 0.4, 6)
	shade.append_array(_arc_pts(b, rx, ry, PI * 0.4, 0, 6, wall_h))
	draw_colored_polygon(shade, Color(0, 0, 0, 0.22))
	# door
	var dc := b + Vector2(-rx * 0.18, ry * 0.98)
	draw_colored_polygon(PackedVector2Array([dc + Vector2(-4, 0), dc + Vector2(-4, -wall_h * 0.8), dc + Vector2(0, -wall_h * 0.95), dc + Vector2(4, -wall_h * 0.8), dc + Vector2(4, 0)]), Color("#2a1a0e"))
	# roof
	var top := b - Vector2(0, wall_h)
	var apex := top - Vector2(0, roof_h)
	var orx := rx * 1.18
	var ory := ry * 1.18
	var roof_pts := _arc_pts(top, orx, ory, 0, PI, 16)
	roof_pts.append(apex)
	draw_colored_polygon(roof_pts, roof)
	var dark := _arc_pts(top, orx, ory, 0, PI * 0.42, 7)
	dark.append(apex)
	draw_colored_polygon(dark, roof.darkened(0.28))
	for i in 7:
		var q := top + Vector2(cos(PI * (i + 0.5) / 7) * orx, sin(PI * (i + 0.5) / 7) * ory)
		draw_line(q, apex.lerp(q, 0.25), roof.darkened(0.4), 1)
	_ell_line(top, orx, ory, roof.darkened(0.45), 1.5, 0, PI)
	draw_line(apex, apex + Vector2(-3, -5), Color("#5a3d22"), 2)
	draw_line(apex, apex + Vector2(3, -5), Color("#5a3d22"), 2)

func _draw_post(b: Vector2, shown: bool, built: bool) -> void:
	if not shown:
		draw_circle(b, 2, Color(0.5, 0.4, 0.3, 0.35))
		return
	var h := 22.0
	draw_line(b + Vector2(1, 0), b + Vector2(9, 3), Color(0, 0, 0, 0.18), 3)
	draw_rect(Rect2(b.x - 3, b.y - h, 6, h), Color("#7a5530"))
	draw_rect(Rect2(b.x + 0.5, b.y - h, 2.5, h), Color("#5c3f22"))
	draw_colored_polygon(PackedVector2Array([b + Vector2(-3, -h), b + Vector2(3, -h), b + Vector2(0, -h - 6)]), Color("#a57a4a"))
	draw_line(b + Vector2(-4, -h * 0.45), b + Vector2(4, -h * 0.45), Color("#4a3018"), 1.5)

# ------------------------------------------------------------ objects
func _draw_node(n) -> void:
	var b := iso(n.pos)
	match n.kind:
		"tree":
			var s: float = n.sz
			var east: bool = D.bank_of(n.pos) == "east"
			_ell(b + Vector2(12 * s, 4 * s), 18 * s, 7 * s, SHADOW)
			draw_rect(Rect2(b.x - 2.5 * s, b.y - 14 * s, 5 * s, 14 * s), Color("#6b4524"))
			if n.id % 3 != 2:
				var dark := Color("#24452a") if east else Color("#2c5a2e")
				var lite := Color("#2f5c34") if east else Color("#3d7a3a")
				for i in 3:
					var by := b.y - (10 + i * 10) * s
					var hw := (15 - i * 3.5) * s
					var tip := Vector2(b.x, by - 18 * s)
					draw_colored_polygon(PackedVector2Array([Vector2(b.x - hw, by), Vector2(b.x + hw, by), tip]), dark)
					draw_colored_polygon(PackedVector2Array([Vector2(b.x - hw, by), Vector2(b.x - hw * 0.1, by + 2 * s), tip]), lite)
			else:
				var c0 := Color("#2f5a2a") if not east else Color("#29482a")
				draw_circle(b + Vector2(0, -26 * s), 14 * s, c0)
				draw_circle(b + Vector2(-7, -22) * s, 9 * s, c0)
				draw_circle(b + Vector2(7, -21) * s, 9 * s, c0.darkened(0.15))
				draw_circle(b + Vector2(-4, -31) * s, 8 * s, c0.lightened(0.18))
				draw_circle(b + Vector2(-6, -34) * s, 3.5 * s, c0.lightened(0.32))
		"stump":
			_ell(b + Vector2(2, 1), 7, 3.5, SHADOW)
			draw_rect(Rect2(b.x - 5, b.y - 5, 10, 5), Color("#6b4a2a"))
			_ell(b - Vector2(0, 5), 5, 2.5, Color("#b08654"))
		"bush":
			_ell(b + Vector2(4, 2), 13, 5, SHADOW)
			draw_circle(b + Vector2(-5, -6), 8, Color("#3a6a2e"))
			draw_circle(b + Vector2(5, -6), 8, Color("#335f29"))
			draw_circle(b + Vector2(0, -11), 8, Color("#4a7e38"))
			for i in int(n.amount / 5):
				draw_circle(b + Vector2(cos(i * 2.4) * 8, -8 + sin(i * 2.4) * 5), 2, Color("#d23c4b"))
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
				draw_line(Vector2(lx, body.y + 2), Vector2(lx + sw, b.y), Color("#6e4a28"), 1.6)
			_ell(body, 9, 4.5, Color("#9a6a3c"))
			_ell(body + Vector2(0, 1.5), 7, 2.5, Color("#c09a70"))
			var head := body + Vector2(9 * f, -6)
			draw_line(body + Vector2(6 * f, -1), head, Color("#9a6a3c"), 3.5)
			draw_circle(head, 3.2, Color("#a87646"))
			draw_line(head + Vector2(-1 * f, -2), head + Vector2(-4 * f, -9), Color("#e0d0b0"), 1.2)
			draw_line(head + Vector2(1 * f, -2), head + Vector2(3 * f, -9), Color("#e0d0b0"), 1.2)
		"carcass":
			_ell(b, 10, 4.5, Color("#5e2219"))
			_ell(b - Vector2(0, 2), 8, 3.5, Color("#7a2f25"))
			draw_line(b + Vector2(-7, -1), b + Vector2(7, -4), Color("#e8dcc0"), 2)

func _draw_ground_part(s) -> void:
	var p: Vector2 = s.pos
	var a := 1.0 if s.built else 0.5
	match s.type:
		"farm_plot":
			draw_rect(Rect2(p.x - 30, p.y - 20, 60, 40), Color(0.42, 0.3, 0.17, a))
			for i in 6:
				var yy := p.y - 16 + i * 6.5
				draw_line(Vector2(p.x - 26, yy), Vector2(p.x + 26, yy), Color(0.32, 0.22, 0.12, a), 2)
				if s.built:
					var k := 0
					while k < 9:
						draw_circle(Vector2(p.x - 24 + k * 6, yy - 1.5), 1.6, Color("#9cc94a"))
						k += 1
		"fishing_dock":
			var c := Color("#9a7448") if s.built else Color(0.6, 0.45, 0.3, 0.5)
			draw_rect(Rect2(p.x - 52, p.y - 8, 58, 16), Color(0, 0, 0, 0.22))
			draw_rect(Rect2(p.x - 50, p.y - 7, 54, 14), c)
			for i in 7: draw_line(Vector2(p.x - 48 + i * 8, p.y - 7), Vector2(p.x - 48 + i * 8, p.y + 7), c.darkened(0.35), 1.2)
		"bonfire":
			for i in 9:
				draw_circle(p + Vector2.from_angle(i * TAU / 9) * 12, 3.5, Color(0.55, 0.55, 0.5, a))
			draw_circle(p, 8, Color(0.15, 0.1, 0.06, 0.8 * a))
		"grand_altar", "totem_shrine":
			draw_circle(p, D.STRUCTURES[s.type]["r"] + 10, Color(0.55, 0.5, 0.4, 0.35 * a))

func _draw_structure(s) -> void:
	var b := iso(s.pos)
	var frac: float = s.progress / s.work
	var a := 1.0 if s.built else 0.55
	match s.type:
		"hut":
			_round_house(b, 20, 11, 24, Color("#9b7a52"), Color("#c9a24f"), frac, s.built)
		"large_hut":
			_round_house(b, 27, 13, 30, Color("#8f6d48"), Color("#b98f42"), frac, s.built)
		"granary":
			if s.built:
				for i in 4:
					var q := b + Vector2(cos(i * TAU / 4 + 0.6) * 14, sin(i * TAU / 4 + 0.6) * 7)
					draw_line(q, q - Vector2(0, 8), Color("#5a3d22"), 3)
				_round_house(b - Vector2(0, 8), 18, 16, 16, Color("#c08a58"), Color("#a7703f"), frac, true)
			else:
				_round_house(b, 18, 16, 16, Color("#c08a58"), Color("#a7703f"), frac, false)
		"bonfire":
			if not s.built:
				_logs(b, a)
				return
			_logs(b, 1.0)
			var fl := 1.0 + 0.18 * sin(t * 11 + s.id)
			var fl2 := 1.0 + 0.22 * sin(t * 15 + s.id * 2.0)
			_flame(b - Vector2(0, 3), 9 * fl, 26 * fl, Color("#e2541b"))
			_flame(b - Vector2(-1, 4), 6 * fl2, 18 * fl2, Color("#f8a531"))
			_flame(b - Vector2(0, 5), 3 * fl, 10 * fl, Color("#fff1a0"))
			for i in 3:
				var k := fmod(t * 0.9 + i * 0.33, 1.0)
				draw_circle(b + Vector2(sin(t * 3 + i) * 4, -30 - 30 * k), 2.5 + 3 * k, Color(0.5, 0.5, 0.5, 0.3 * (1 - k)))
		"fishing_dock":
			var c := Color("#6b4a2a") if s.built else Color(0.5, 0.35, 0.2, 0.5)
			for q in [s.pos + Vector2(-48, -7), s.pos + Vector2(-48, 7), s.pos + Vector2(-20, -7), s.pos + Vector2(-20, 7)]:
				var sp := iso(q)
				draw_line(sp + Vector2(0, 4), sp - Vector2(0, 6), c, 3)
			if s.built:
				var rod := iso(s.pos + Vector2(-50, 0))
				draw_line(rod - Vector2(0, 4), rod + Vector2(-26, -26), Color("#c8b48a"), 1.5)
				draw_line(rod + Vector2(-26, -26), rod + Vector2(-30, 4 + sin(t * 2) * 2), Color(1, 1, 1, 0.5), 1)
		"weapon_rack":
			_ell(b + Vector2(4, 2), 16, 5, SHADOW)
			var l := iso(s.pos + Vector2(-10, 6))
			var r := iso(s.pos + Vector2(10, -6))
			draw_line(l, l - Vector2(0, 16), Color(C_WOOD, a), 3)
			draw_line(r, r - Vector2(0, 16), Color(C_WOOD, a), 3)
			draw_line(l - Vector2(0, 14), r - Vector2(0, 14), Color(C_WOOD.darkened(0.2), a), 3)
			for i in 4:
				var q := l.lerp(r, 0.15 + i * 0.23)
				draw_line(q + Vector2(-3, 2), q + Vector2(2, -30), Color(0.78, 0.72, 0.6, a), 2)
				draw_colored_polygon(PackedVector2Array([q + Vector2(1, -30), q + Vector2(4, -30), q + Vector2(2.5, -37)]), Color(0.6, 0.6, 0.62, a))
		"totem_shrine":
			_ell(b + Vector2(6, 2), 16, 6, SHADOW)
			for i in 6:
				var q := b + Vector2(cos(i * TAU / 6) * 12, sin(i * TAU / 6) * 6)
				draw_circle(q, 3, Color(0.6, 0.58, 0.52, a))
			_totem(b, 44, 1.0, a)
		"grand_altar":
			_box(s.pos, 30, 30, 8, Color(0.62, 0.6, 0.56, a))
			_box(s.pos, 20, 20, 16, Color(0.66, 0.64, 0.6, a))
			_totem(b - Vector2(0, 16), 54, 1.3, a)

func _logs(b: Vector2, a: float) -> void:
	draw_line(b + Vector2(-9, 2), b + Vector2(7, -5), Color(0.35, 0.22, 0.1, a), 3.5)
	draw_line(b + Vector2(9, 2), b + Vector2(-7, -5), Color(0.42, 0.27, 0.12, a), 3.5)

func _flame(b: Vector2, w: float, h: float, col: Color) -> void:
	var sway := sin(t * 7 + b.x) * w * 0.3
	draw_colored_polygon(PackedVector2Array([b + Vector2(-w, 0), b + Vector2(-w * 0.6, -h * 0.45), b + Vector2(sway, -h), b + Vector2(w * 0.6, -h * 0.45), b + Vector2(w, 0), b + Vector2(0, w * 0.35)]), col)

func _totem(b: Vector2, h: float, s: float, a: float) -> void:
	draw_rect(Rect2(b.x - 4 * s, b.y - h, 8 * s, h), Color(Color("#6b4a2a"), a))
	draw_rect(Rect2(b.x + 1 * s, b.y - h, 3 * s, h), Color(Color("#4f361d"), a))
	var cols := [Color("#c0392b"), Color("#e6b33a"), Color("#2e86ab"), Color("#c0392b")]
	for i in 4:
		var y := b.y - h + 4 + i * h * 0.22
		draw_rect(Rect2(b.x - 5 * s, y, 10 * s, h * 0.12), Color(cols[i], a))
		draw_circle(Vector2(b.x - 2 * s, y + h * 0.06), 1.3 * s, Color(0, 0, 0, a))
		draw_circle(Vector2(b.x + 2 * s, y + h * 0.06), 1.3 * s, Color(0, 0, 0, a))
	var wy := b.y - h + 6
	draw_colored_polygon(PackedVector2Array([Vector2(b.x - 4 * s, wy), Vector2(b.x - 18 * s, wy - 8 * s), Vector2(b.x - 15 * s, wy + 2 * s)]), Color(Color("#e6b33a"), a))
	draw_colored_polygon(PackedVector2Array([Vector2(b.x + 4 * s, wy), Vector2(b.x + 18 * s, wy - 8 * s), Vector2(b.x + 15 * s, wy + 2 * s)]), Color(Color("#d4a02e"), a))

func _draw_structure_overlay(s) -> void:
	if s.built: return
	var sd: Dictionary = D.STRUCTURES[s.type]
	var b := iso(s.pos) if not sd.get("ring", false) else iso(s.pos + Vector2(sd["r"], sd["r"]) * 0.707)
	var by: float = b.y + 10
	_bar(Vector2(b.x, by), 38, s.progress / s.work, Color("#b6f28a"))
	if not s.paid: _draw_label(Vector2(b.x, by + 17), "awaiting wood", 11, Color(1, 0.8, 0.6), true)

func _draw_site_ring(c) -> void:
	var col := _site_col(c)
	if c.status == "done": return
	for i in 32:
		var a0 := float(i) / 32 * TAU + t * 0.2
		draw_arc(c.site, 125, a0, a0 + TAU / 64, 4, Color(col, 0.6), 4)

func _site_col(c) -> Color:
	match c.status:
		"interrupted", "defending": return Color("#ff6b6b")
		"done": return Color("#b6f28a")
		"abandoned", "failed": return Color(0.6, 0.6, 0.6)
	return Color("#ffd36b")

func _draw_site_flag(c) -> void:
	var col := _site_col(c)
	var fp := iso(c.site + Vector2(-100, -100))
	draw_line(fp, fp + Vector2(0, -44), Color("#5a3d22"), 3)
	var wv := sin(t * 4) * 3
	draw_colored_polygon(PackedVector2Array([fp + Vector2(0, -44), fp + Vector2(24, -38 + wv), fp + Vector2(0, -30)]), col)
	var ld = sim.unit_by_id(c.leader_id)
	var label := "%s  [%s %d%%]" % [c.plan["plan_id"], c.status.to_upper(), roundi(c.progress * 100)]
	_draw_label(fp + Vector2(0, -52), label, 14, col, true)
	if ld and c.status not in ["done", "abandoned", "failed"]:
		_draw_label(fp + Vector2(0, -70), "Leader: %s · %s" % [ld.name, c.substate], 12, Color(1, 1, 1, 0.85), true)

func _draw_unit(u) -> void:
	var b := iso(u.pos)
	_scale_about(b, FIG_SCALE)
	if u.dead:
		_ell(b, 9, 4, Color(0.25, 0.1, 0.08, 0.5))
		draw_line(b + Vector2(-8, -1), b + Vector2(8, 1), Color(u.color, 0.6), 4)
		draw_circle(b + Vector2(10, 1), 3, Color(0.85, 0.7, 0.55, 0.6))
		return
	var key := "u%d" % u.id
	var f: float = facing.get(key, 1)
	var walk: bool = moving.get(key, false)
	var sel: bool = u.id in selected
	_ell(b + Vector2(2, 0), 9, 4, SHADOW)
	if u.hero: _ell(b, 15 + sin(t * 4) * 1.5, 7.5, Color(1, 0.85, 0.3, 0.3))
	if sel: _ell_line(b, 14, 7, Color("#ffe066"), 2)
	if u.role == "contract": _ell_line(b, 11, 5.5, Color(0.55, 0.8, 1.0, 0.8), 1.5)
	var busy: bool = u.act in ["Chopping wood", "Picking berries", "Butchering game", "Building", "Fighting"] or u.act.begins_with("Build")
	var bob := absf(sin(t * 12 + u.id)) * 1.5 if walk else 0.0
	var skin := Color("#d9a77c")
	# legs
	var sw := sin(t * 12 + u.id) * 3.0 if walk else 0.0
	draw_line(b + Vector2(-2, -9 - bob), b + Vector2(-2 + sw, 0), skin.darkened(0.25), 2.5)
	draw_line(b + Vector2(2, -9 - bob), b + Vector2(2 - sw, 0), skin.darkened(0.15), 2.5)
	# torso (fur tunic)
	var hip := b + Vector2(0, -8 - bob)
	draw_colored_polygon(PackedVector2Array([hip + Vector2(-5, 1), hip + Vector2(5, 1), hip + Vector2(4, -12), hip + Vector2(-4, -12)]), u.color)
	draw_colored_polygon(PackedVector2Array([hip + Vector2(1.5 * f, 1), hip + Vector2(5 * f, 1), hip + Vector2(4 * f, -12), hip + Vector2(1 * f, -12)]), u.color.darkened(0.25))
	draw_line(hip + Vector2(-5, 1), hip + Vector2(5, 1), u.color.darkened(0.45), 1.5)
	# arms / tool
	var sh := hip + Vector2(0, -10)
	var swing := sin(t * 9 + u.id) * 0.9 if busy else 0.0
	var hand := sh + Vector2(6 * f, 6).rotated(swing * -f * 0.6)
	draw_line(sh + Vector2(3 * f, 0), hand, skin, 2)
	draw_line(sh + Vector2(-3 * f, 0), sh + Vector2(-5 * f, 7 + sw * 0.4), skin.darkened(0.1), 2)
	if u.job.get("type", "") == "attack" or u.act == "Fighting" or u.has_trait("belligerent"):
		var dirv := Vector2(0.35 * f, -1).normalized().rotated(swing * f * 0.5)
		draw_line(hand - dirv * 6, hand + dirv * 18, Color("#b9a27a"), 1.6)
		draw_colored_polygon(PackedVector2Array([hand + dirv * 18 + Vector2(-2, 0), hand + dirv * 18 + Vector2(2, 0), hand + dirv * 24]), Color("#8d8d93"))
	elif busy:
		var tool := Vector2(0.9 * f, -0.4).normalized().rotated(swing * f)
		draw_line(hand, hand + tool * 10, Color("#8a5a32"), 2)
		draw_circle(hand + tool * 10, 2.2, Color("#8d8d93"))
	# head
	var head := sh + Vector2(0, -5)
	draw_circle(head, 4.5, skin)
	draw_colored_polygon(PackedVector2Array([head + Vector2(-5, -1), head + Vector2(-3.5, -5), head + Vector2(3.5, -5.5), head + Vector2(5, -1), head + Vector2(-1 * f, -2.5)]), Color("#2e1d10"))
	draw_circle(head + Vector2(2 * f, 0), 0.9, Color("#1a0f08"))
	if u.title != "":
		draw_colored_polygon(PackedVector2Array([head + Vector2(-4, -5), head + Vector2(-1, -11), head + Vector2(0, -5.5), head + Vector2(2, -12), head + Vector2(4, -5)]), Color("#e8c25a"))
	if u.carry_amt > 0:
		var bk := hip + Vector2(-6 * f, -8)
		if u.carry_type == "wood":
			draw_line(bk + Vector2(-3, 3), bk + Vector2(3, -5), Color("#7a4e28"), 3)
			draw_line(bk + Vector2(-1, 4), bk + Vector2(5, -3), Color("#8a5a32"), 3)
		else:
			draw_circle(bk, 4, Color("#b03a2e"))
	if u.job.get("type", "") == "ritual" and u.act == "Performing ritual":
		_ell_line(b - Vector2(0, 12), 16 + sin(t * 3) * 3, 8, Color(0.75, 0.6, 1.0, 0.6), 1.5)
		for i in 3:
			var k := fmod(t * 0.7 + i / 3.0, 1.0)
			draw_circle(b + Vector2(sin(t * 2 + i * 2) * 10, -10 - 30 * k), 1.8, Color(0.8, 0.7, 1, 1 - k))

func _draw_unit_overlay(u) -> void:
	if u.dead: return
	var b := iso(u.pos) * 1.0
	var sel: bool = u.id in selected
	var title: String = ("★ " if u.title != "" else "") + u.name
	_draw_label(b + Vector2(0, -46), title, 14, Color("#fff4d6") if not sel else Color("#ffe066"), true)
	if u.hp < u.max_hp - 0.5: _bar(b + Vector2(0, 6), 24, u.hp / u.max_hp, Color("#e05050") if u.hp < u.max_hp * 0.35 else Color("#6fd06f"))

func _draw_pred(p) -> void:
	var b := iso(p.pos)
	_scale_about(b, FIG_SCALE)
	var key := "p%d" % p.id
	var f: float = facing.get(key, 1)
	var walk: bool = moving.get(key, false)
	_ell(b + Vector2(3, 1), 18, 6, SHADOW)
	var body := b - Vector2(0, 13)
	for i in 4:
		var lx := body.x + (-10 + i * 6.5) * f
		var sw := sin(t * 13 + i * 1.9) * 3.5 if walk else 0.0
		draw_line(Vector2(lx, body.y + 3), Vector2(lx + sw, b.y), Color("#b86f1f") if i % 2 == 0 else Color("#cf7f26"), 3.5)
	# tail
	var tb := body + Vector2(-13 * f, -1)
	draw_line(tb, tb + Vector2(-8 * f, -6 + sin(t * 3) * 3), Color("#cf7f26"), 2.5)
	_ell(body, 15, 7, Color("#d98a2b"))
	_ell(body + Vector2(0, 3), 11, 3.5, Color("#f2d2a0"))
	for i in 4:
		var sx := body.x + (-9 + i * 5.5) * f
		draw_line(Vector2(sx, body.y - 7), Vector2(sx - 2 * f, body.y + 1), Color("#3a2414"), 2)
	var head := body + Vector2(15 * f, -5)
	draw_circle(head, 7, Color("#e39a35"))
	draw_circle(head + Vector2(3 * f, 3), 4, Color("#f0c890"))
	draw_circle(head + Vector2(-2 * f, -6), 2.5, Color("#c47a20"))
	draw_circle(head + Vector2(2 * f, -2), 1.2, Color("#1a0f08"))
	draw_line(head + Vector2(2 * f, 5), head + Vector2(3 * f, 13), Color.WHITE, 2)
	draw_line(head + Vector2(5 * f, 5), head + Vector2(6 * f, 12), Color.WHITE, 2)

func _draw_guardian(g) -> void:
	var lift := 52.0 + sin(t * 2) * 6
	var b := iso(g.pos)
	_ell(b, 22, 8, Color(0, 0, 0, 0.22))
	for i in range(guardian_trail.size() - 1, -1, -3):
		var k := 1.0 - float(i) / guardian_trail.size()
		draw_circle(iso(guardian_trail[i]) - Vector2(0, lift), 3 + 8 * k, Color(0.4, 0.95, 0.8, 0.2 + 0.45 * k))
	var c := b - Vector2(0, lift)
	var flap := sin(t * 6) * 10
	draw_colored_polygon(PackedVector2Array([c + Vector2(-4, -2), c + Vector2(-32, -16 - flap), c + Vector2(-22, 4)]), Color("#3fbfa0"))
	draw_colored_polygon(PackedVector2Array([c + Vector2(4, -2), c + Vector2(32, -16 - flap), c + Vector2(22, 4)]), Color("#38ad91"))
	_ell(c, 14, 9, Color("#5fe0c0"))
	draw_circle(c + Vector2(12, -6), 6, Color("#6ff0d0"))
	draw_circle(c + Vector2(14, -7), 1.6, Color.WHITE)
	_draw_label(c + Vector2(0, -26), "Yinglong", 13, Color("#9ff0d0"), true)

func _draw_label(p: Vector2, text: String, size: int, col: Color, outline := false) -> void:
	var w := 400.0
	if outline: draw_string_outline(font, p - Vector2(w / 2, 0), text, HORIZONTAL_ALIGNMENT_CENTER, w, size, 4, Color(0, 0, 0, col.a * 0.8))
	draw_string(font, p - Vector2(w / 2, 0), text, HORIZONTAL_ALIGNMENT_CENTER, w, size, col)

func _bar(p: Vector2, w: float, frac: float, col: Color) -> void:
	draw_rect(Rect2(p.x - w / 2, p.y, w, 4), Color(0, 0, 0, 0.6))
	draw_rect(Rect2(p.x - w / 2, p.y, w * clampf(frac, 0, 1), 4), col)

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

func _place(m: Vector2) -> void:
	var s = sim.place_structure(build_type, m)
	if s == null:
		sim.popup(m, sim.can_place(build_type, m), Color("#ff8080"))
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
		sim.popup(m, "Contract crews follow their blueprint", Color("#9fd0ff"))
	if free.is_empty(): return
	cmd_marker = {"p": m, "t": t, "c": Color("#ffe066")}
	for p in sim.predators:
		if not p.dead and not p.fled and _pick_dist(sm, p.pos, 28) < 24:
			for u in free: sim.assign_attack(u, p)
			cmd_marker["c"] = Color("#ff6b6b")
			return
	var node = null
	var bd := 20.0
	for n in sim.nodes:
		if n.amount < 1 or n.kind == "stump": continue
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
